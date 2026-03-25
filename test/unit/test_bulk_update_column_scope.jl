# ============================================================
# test/unit/test_bulk_update_column_scope.jl
#
# Regression suite for bulk operation column-scope and default-injection
# contracts across bulk_update, bulk_insert, and bulk_copy.
#
# CONTRACTS being tested:
#
#   bulk_update with explicit columns=:
#     Only the listed fields (plus dynamic filter columns) may appear in
#     SET and the VALUES source list.  Fields with a static `default` in
#     the model must NOT leak — that would silently overwrite live data.
#     The ONLY intentional exception is auto_now, which must always inject
#     to keep timestamps current.
#
#   bulk_insert / bulk_copy with explicit columns=:
#     Static `default` fields absent from the DataFrame MUST still be
#     auto-populated — otherwise NOT NULL constraints would be violated.
#     The bulk_update fix must not regress this insert/copy behavior.
# ============================================================

using Test
using PormG
using PormG.Models: Model, CharField, IDField, IntegerField, DecimalField, DateTimeField, BigIntegerField
using PormG.QueryBuilder: bulk_copy, bulk_insert, bulk_update
import DataFrames

# ------------------------------------------------------------------
# Reproduce the exact production model shape:
#   - two requested update targets:  weight (IntegerField), score (DecimalField)
#   - three fields carrying a static default that must NOT leak: denominator, numerator, result_value
#   - city_id used as a static filter (Pair{String,<:Any})
#   - id used as a dynamic row-key filter (String)
# ------------------------------------------------------------------
Metric = Model("metrics",
    id           = IDField(),
    city_id      = BigIntegerField(null=true),
    weight       = IntegerField(null=true),
    score        = DecimalField(max_digits=10, decimal_places=2, null=true),
    denominator  = IntegerField(default=0),           # has a static default → the leaker
    numerator    = IntegerField(default=0),           # has a static default → the leaker
    result_value = DecimalField(max_digits=10, decimal_places=2, default="0"),  # the leaker
)
Metric.connect_key = "default"

# Mock PostgreSQL settings — no live DB needed; show_query=:dict
# exits before any network call.
struct MockPgScope <: PormG.PormGPostgres end
PormG.config["default"] = PormG.Configuration.Settings(
    connections = MockPgScope(),
    change_data = true
)

# 1-row DataFrame that mirrors the production case.
# The DataFrame intentionally contains all columns of the model so we can
# verify the ORM selects only what was listed in columns=.
df_upd = DataFrames.DataFrame(
    id           = [4606],
    city_id      = [141341324],
    weight       = [1],
    score        = ["0.75"],
    denominator  = [570],    # present in DF but must NOT be in SET
    numerator    = [30675],  # present in DF but must NOT be in SET
    result_value = ["53.8"], # present in DF but must NOT be in SET
)

@testset "bulk_update: explicit columns scope enforcement" begin

    # ------------------------------------------------------------------
    # Sub-test 1: SET clause must contain only the requested columns.
    #
    # Why this matters: silently updating columns the caller did not list
    # is a data-integrity violation — it overwrites live data with stale
    # or wrong values from the DataFrame.
    # ------------------------------------------------------------------
    @testset "SET clause is restricted to explicit columns" begin
        res = bulk_update(
            Metric.objects, df_upd,
            columns    = ["weight", "score"],
            filters    = ["id", "city_id" => 141341324],
            show_query = :dict
        )
        sql = res[:sql_text]

        # Extract the text between SET and FROM to isolate the assignment list.
        set_match = match(r"SET(.*?)FROM"s, sql)
        @test set_match !== nothing  # sanity: SQL has expected shape
        set_text = set_match.captures[1]

        # The static filter passed as `"city_id" => 141341324` must remain in the
        # WHERE clause and be combined with the dynamic `id` filter.
        @test occursin(r"AND\s+\"Tb\"\.\"city_id\"\s*=\s*\$1", sql)

        # Requested columns MUST appear in SET.
        @test occursin("\"weight\"", set_text)
        @test occursin("\"score\"",  set_text)

        # Default-bearing columns must NOT appear in SET.
        @test !occursin("denominator",  set_text)
        @test !occursin("numerator",    set_text)
        @test !occursin("result_value", set_text)
    end

    # ------------------------------------------------------------------
    # Sub-test 2: VALUES source column list must be equally constrained.
    #
    # Even if a field is not in SET, a leaking default can still cause it
    # to appear in AS source (col1, col2, ...) — which shifts all positional
    # parameters and corrupts WHERE-clause matching for every row.
    # ------------------------------------------------------------------
    @testset "VALUES source column list matches explicit columns + filters" begin
        res = bulk_update(
            Metric.objects, df_upd,
            columns    = ["weight", "score"],
            filters    = ["id", "city_id" => 141341324],
            show_query = :dict
        )
        sql = res[:sql_text]

        source_match = match(r"AS source \(([^)]+)\)", sql)
        @test source_match !== nothing
        source_cols = source_match.captures[1]

        # The dynamic filter column ("id") must be in source so the ON
        # condition can reference it.  The two update columns must be there too.
        @test occursin("\"weight\"", source_cols)
        @test occursin("\"score\"",  source_cols)
        @test occursin("\"id\"",     source_cols)

        # Default-bearing columns must NOT appear in source.
        @test !occursin("denominator",  source_cols)
        @test !occursin("numerator",    source_cols)
        @test !occursin("result_value", source_cols)
    end

    # ------------------------------------------------------------------
    # Sub-test 3: Parameter count must match the restricted column set.
    #
    # BUG produced 7 parameters; the correct count is 4:
    #   $1  → city_id static filter value (141341324)
    #   $2  → weight  (row value, lands in VALUES)
    #   $3  → score   (row value, lands in VALUES)
    #   $4  → id      (row value, lands in VALUES as WHERE key)  ← wait, not $4?
    #
    # Actually for PostgreSQL the static filter pre-pends:
    #   $1 = 141341324 (static WHERE from objct.filter)
    # Then the VALUES row:
    #   $2 = weight, $3 = score, $4 = id (dynamic filter col in source)
    # Total = 4, not 7.
    # ------------------------------------------------------------------
    @testset "Parameter count equals columns + filters, not model field count" begin
        res = bulk_update(
            Metric.objects, df_upd,
            columns    = ["weight", "score"],
            filters    = ["id", "city_id" => 141341324],
            show_query = :dict
        )
        # The exact parameter order matters:
        #   1. static filter value for city_id
        #   2. weight
        #   3. score
        #   4. id (dynamic filter column in the VALUES source)
        @test res[:parameter_count] == 4

        params = res[:parameters]

        @test params == Any[141341324, 1, "0.75", 4606]
    end

    # ------------------------------------------------------------------
    # Sub-test 3b: even if the caller explicitly names a default-bearing
    # field in columns=, the ORM must not synthesize it for UPDATE when the
    # DataFrame does not provide the column.
    #
    # Why this matters: otherwise an explicit update can still overwrite live
    # database data with the model's static default merely because the DF is
    # missing that column.
    # ------------------------------------------------------------------
    @testset "Requested default-bearing field is not synthesized for explicit update" begin
        df_missing_requested = DataFrames.DataFrame(
            id      = [4606],
            city_id = [141341324],
            weight  = [1],
        )

        res_missing_requested = bulk_update(
            Metric.objects, df_missing_requested,
            columns    = ["weight", "result_value"],
            filters    = ["id", "city_id" => 141341324],
            show_query = :dict
        )
        sql_missing_requested = res_missing_requested[:sql_text]

        set_match_missing = match(r"SET(.*?)FROM"s, sql_missing_requested)
        @test set_match_missing !== nothing
        set_missing = set_match_missing.captures[1]

        source_match_missing = match(r"AS source \(([^)]+)\)", sql_missing_requested)
        @test source_match_missing !== nothing
        source_cols_missing = source_match_missing.captures[1]

        @test occursin("\"weight\"", set_missing)
        @test !occursin("result_value", set_missing)
        @test occursin("\"weight\"", source_cols_missing)
        @test !occursin("result_value", source_cols_missing)
        @test res_missing_requested[:parameter_count] == 3
        @test res_missing_requested[:parameters] == Any[141341324, 1, 4606]
    end

end

# ------------------------------------------------------------------
# Tests for behaviors that intentionally bypass the explicit-columns scope:
#   • auto_now timestamps must always inject, even when columns= is set.
#   • columns=nothing must auto-detect from the DataFrame as before.
# ------------------------------------------------------------------
@testset "bulk_update: bypass and auto-detect behaviors" begin

    # ------------------------------------------------------------------
    # auto_now fields ARE still allowed to propagate even when columns=
    # is explicit.
    #
    # auto_now is an intentional side-effect — the ORM must always keep
    # timestamps current.  The fix must preserve this behavior.
    # ------------------------------------------------------------------
    @testset "auto_now field is still injected when columns= is explicit" begin
        Metric_ts = Model("metrics_ts",
            id         = IDField(),
            weight     = IntegerField(null=true),
            updated_at = DateTimeField(auto_now=true, null=true),
        )
        Metric_ts.connect_key = "default"

        df_ts = DataFrames.DataFrame(id=[1], weight=[5])
        res_ts = bulk_update(
            Metric_ts.objects, df_ts,
            columns    = ["weight"],
            filters    = ["id"],
            show_query = :dict
        )
        sql_ts = res_ts[:sql_text]
        # @info sql_ts
        set_match_ts = match(r"SET(.*?)FROM"s, sql_ts)
        @test set_match_ts !== nothing
        # auto_now field MUST appear in SET (intentional exception to the scope rule).
        @test occursin("updated_at", set_match_ts.captures[1])
    end

    # ------------------------------------------------------------------
    # Sub-test 5: columns=nothing (auto-detect) still updates all
    #             DF-present columns (the pre-existing behavior must
    #             remain intact after the fix).
    # ------------------------------------------------------------------
    @testset "columns=nothing still auto-detects all DataFrame columns" begin
        res_auto = bulk_update(
            Metric.objects, df_upd,
            # no columns= argument → all DF columns that match model fields
            filters    = ["id"],
            show_query = :dict
        )
        sql_auto = res_auto[:sql_text]
        set_match_auto = match(r"SET(.*?)FROM"s, sql_auto)
        @test set_match_auto !== nothing
        set_auto = set_match_auto.captures[1]

        source_match_auto = match(r"AS source \(([^)]+)\)", sql_auto)
        @test source_match_auto !== nothing
        source_cols_auto = source_match_auto.captures[1]

        # With auto-detect, every non-filter, non-PK DF column that maps to a
        # model field should appear in SET.
        @test occursin("weight",       set_auto)
        @test occursin("score",        set_auto)
        @test occursin("denominator",  set_auto)
        @test occursin("numerator",    set_auto)
        @test occursin("result_value", set_auto)

        # The source column order should match the DataFrame/model mapping.
        @test source_cols_auto == "\"id\",\"city_id\",\"weight\",\"score\",\"denominator\",\"numerator\",\"result_value\""

        # The parameter vector should follow the same order as the VALUES source.
        @test res_auto[:parameter_count] == 7
        @test res_auto[:parameters] == Any[4606, 141341324, 1, "0.75", 570, 30675, "53.8"]
    end

end

# ------------------------------------------------------------------
# bulk_insert: the fix must NOT suppress static-default injection for
# INSERT — a NOT NULL field absent from the DF must still be filled
# from the model default to avoid a constraint violation.
# ------------------------------------------------------------------
@testset "bulk_insert: explicit-column default injection" begin
    df_insert = DataFrames.DataFrame(
        weight = [1],
        score  = ["0.75"],
    )

    res_insert = bulk_insert(
        Metric.objects, df_insert,
        columns    = ["weight", "score"],
        show_query = :dict
    )
    sql_insert = res_insert[:sql_text]

    @test occursin("INSERT INTO", sql_insert)
    @test occursin("\"weight\"", sql_insert)
    @test occursin("\"score\"", sql_insert)
    @test occursin("\"denominator\"", sql_insert)
    @test occursin("\"numerator\"", sql_insert)
    @test occursin("\"result_value\"", sql_insert)
    @test res_insert[:parameter_count] == 5
    @test res_insert[:parameters] == Any[1, "0.75", 0, 0, "0"]
end

# ------------------------------------------------------------------
# bulk_copy: same contract as bulk_insert through the PostgreSQL COPY
# protocol.  COPY streams raw data — parameters are not used (count == 0).
# ------------------------------------------------------------------
@testset "bulk_copy: explicit-column default injection" begin
    df_copy = DataFrames.DataFrame(
        weight = [1],
        score  = ["0.75"],
    )

    res_copy = bulk_copy(
        Metric.objects, df_copy,
        columns    = ["weight", "score"],
        show_query = :dict
    )
    sql_copy = res_copy[:sql_text]

    @test occursin("COPY", sql_copy)
    @test occursin("\"weight\"", sql_copy)
    @test occursin("\"score\"", sql_copy)
    @test occursin("\"denominator\"", sql_copy)
    @test occursin("\"numerator\"", sql_copy)
    @test occursin("\"result_value\"", sql_copy)
    @test res_copy[:parameter_count] == 0
    @test isempty(res_copy[:parameters])
end
