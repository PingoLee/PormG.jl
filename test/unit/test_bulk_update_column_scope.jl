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
            match_on   = ["id"],
            filters    = ["city_id" => 141341324],
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
            match_on   = ["id"],
            filters    = ["city_id" => 141341324],
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
            match_on   = ["id"],
            filters    = ["city_id" => 141341324],
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
            match_on   = ["id"],
            filters    = ["city_id" => 141341324],
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
            match_on   = ["id"],
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
            match_on   = ["id"],
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

# ------------------------------------------------------------------
# match_on / filters separation contract (#107 "one border crossing").
#
#   columns  = participating fields + the ONLY place a df column is
#              mapped to a model field ("df_col" => "model_field").
#   match_on = per-row merge keys, bare MODEL FIELD names, always
#              dynamic; a field listed in both is matched, never SET.
#   filters  = constant predicates (model_field => value), always static.
#
# The legacy single-`filters` dynamic usage and the pre-#107
# `match_on` pair grammar are rejected with migration errors so call
# sites move loudly rather than silently misbehaving.
# ------------------------------------------------------------------
@testset "bulk_update: match_on / filters separation" begin

    # The #107 motivating golden: every df→field mapping is declared in columns=;
    # match_on selects the merge key by field name. The match key ("id", sourced from
    # df "record_id") appears in the source list and WHERE, but never in SET.
    @testset "columns= carries the mapping; bare match_on selects the merge key" begin
        custom_df = DataFrames.DataFrame(
            record_id = [4606],
            new_w     = [9],
        )
        res = bulk_update(
            Metric.objects, custom_df,
            columns    = ["new_w" => "weight", "record_id" => "id"],
            match_on   = ["id"],
            show_query = :dict
        )
        sql = res[:sql_text]

        # WHERE merges on the model field id against the mapped source column.
        @test occursin("\"Tb\".\"id\" = source.\"id\"", sql)
        set_text = match(r"SET(.*?)FROM"s, sql).captures[1]
        @test occursin("\"weight\"", set_text)
        @test !occursin("\"id\" =", set_text)   # match key is not SET
        # Source order: update column first, then the match key.
        @test res[:parameters] == Any[9, 4606]
    end

    # The pre-#107 pair grammar must fail loudly with the rewrite, not silently
    # remap — the migration error is the deprecation shim's whole point.
    @testset "match_on pair form raises the migration error" begin
        custom_df = DataFrames.DataFrame(record_id = [4606], new_w = [9])
        err = try
            bulk_update(
                Metric.objects, custom_df,
                columns    = ["new_w" => "weight"],
                match_on   = ["record_id" => "id"],
                show_query = :dict
            )
            nothing
        catch e
            e
        end
        @test err isa PormGError
        msg = sprint(showerror, err)
        # The message must show the exact rewrite: mapping moves to columns=,
        # match_on keeps the bare field name.
        @test occursin("no longer accepts", msg)
        @test occursin("columns  = [..., \"record_id\" => \"id\"]", msg)
        @test occursin("match_on = [\"id\"]", msg)
    end

    # Mapping-first resolution: when columns= maps a field AND the df also carries a
    # column with the field's own name, the declared mapping is authoritative and the
    # same-named column is ignored — loudly (@warn), so the ambiguity is visible.
    @testset "columns= mapping wins over a same-named df column (with @warn)" begin
        conflict_df = DataFrames.DataFrame(
            record_id = [4606],   # the declared source for field id
            id        = [999],    # same-named column that must be IGNORED
            new_w     = [9],
        )
        res = @test_logs (:warn, r"same-named DataFrame column is ignored") bulk_update(
            Metric.objects, conflict_df,
            columns    = ["new_w" => "weight", "record_id" => "id"],
            match_on   = ["id"],
            show_query = :dict
        )
        # Params prove the mapping won: 4606 (df.record_id), not 999 (df.id).
        @test res[:parameters] == Any[9, 4606]
    end

    # When match_on is given, filters are ALWAYS static — no content heuristic.
    @testset "filters is static-only when match_on is provided" begin
        res = bulk_update(
            Metric.objects, df_upd,
            columns    = ["weight"],
            match_on   = ["id"],
            filters    = ["city_id" => 141341324],
            show_query = :dict
        )
        @test occursin(r"AND\s+\"Tb\"\.\"city_id\"\s*=\s*\$1", res[:sql_text])
    end

    # A bare string in filters cannot be a constant predicate once match_on is set.
    @testset "bare-string filter with match_on is rejected" begin
        @test_throws PormGError bulk_update(
            Metric.objects, df_upd,
            columns    = ["weight"],
            match_on   = ["id"],
            filters    = ["city_id"],
            show_query = :dict
        )
    end

    # Legacy dynamic-in-filters usage (no match_on) must raise a migration error,
    # and that error must actually guide the caller to `match_on=` — the whole
    # point of the temporary deprecation shim is an actionable message.
    @testset "legacy bare-string filter raises migration error" begin
        err = try
            bulk_update(
                Metric.objects, df_upd,
                columns    = ["weight"],
                filters    = ["id"],
                show_query = :dict
            )
            nothing
        catch e
            e
        end
        @test err isa PormGError
        @test occursin("match_on", sprint(showerror, err))
    end

    # The advice for a PAIR must be the #107 two-part rewrite (mapping → columns=,
    # bare field → match_on=) — recommending `match_on = [pair]` would send the
    # caller straight into the match_on pair error.
    @testset "legacy df_col => field filter raises migration error" begin
        custom_df = DataFrames.DataFrame(record_id = [4606], weight = [1])
        err = try
            bulk_update(
                Metric.objects, custom_df,
                columns    = ["weight"],
                filters    = ["record_id" => "id"],
                show_query = :dict
            )
            nothing
        catch e
            e
        end
        @test err isa PormGError
        msg = sprint(showerror, err)
        @test occursin("columns  = [..., \"record_id\" => \"id\"]", msg)
        @test occursin("match_on = [\"id\"]", msg)
        @test !occursin("match_on = [\"record_id\" => \"id\"]", msg)   # the stale advice
    end

    # A match key with no source — no columns= mapping for the field and no df column
    # with the field's own name — is a hard error, never a silent fall-through.
    @testset "match_on field without any source column raises" begin
        custom_df = DataFrames.DataFrame(record_id = [4606], new_w = [9])
        err = try
            bulk_update(
                Metric.objects, custom_df,
                columns    = ["new_w" => "weight"],
                match_on   = ["id"],   # field id: unmapped, and no "id" df column
                show_query = :dict
            )
            nothing
        catch e
            e
        end
        @test err isa PormGError
        msg = sprint(showerror, err)
        # Assert the error CLASS and SUBJECT, not just substrings: a bare
        # occursin("id", msg) also matches "record_id" in the column dump, so it
        # cannot discriminate. The \S* tolerates ANSI codes around the field name.
        @test occursin(r"match_on column \S*id\S* not found", msg)
        @test occursin("no columns= mapping targets that field", msg)
    end

    # No match_on and no filters => fall back to the model primary key.
    @testset "no match_on falls back to primary key" begin
        res = bulk_update(
            Metric.objects, df_upd,
            columns    = ["weight"],
            show_query = :dict
        )
        @test occursin("\"Tb\".\"id\" = source.\"id\"", res[:sql_text])
    end

    # Composite match keys produce one merge condition per key, AND'd together,
    # and the source column list includes every key in SET-fields-then-keys order.
    @testset "composite match_on builds multiple AND'd merge conditions" begin
        res = bulk_update(
            Metric.objects, df_upd,
            columns    = ["weight"],
            match_on   = ["id", "city_id"],
            show_query = :dict
        )
        sql = res[:sql_text]
        @test occursin("\"Tb\".\"id\" = source.\"id\"", sql)
        @test occursin("\"Tb\".\"city_id\" = source.\"city_id\"", sql)
        # The two key conditions are AND'd, not OR'd or comma-joined.
        @test occursin(r"source\.\"id\".*AND.*source\.\"city_id\""s, sql) ||
              occursin(r"source\.\"city_id\".*AND.*source\.\"id\""s, sql)
        # Source column list: SET field first, then both keys.
        source_cols = match(r"AS source \(([^)]+)\)", sql).captures[1]
        @test occursin("\"weight\"", source_cols)
        @test occursin("\"id\"", source_cols)
        @test occursin("\"city_id\"", source_cols)
        # Params follow the source order: weight, id, city_id.
        @test res[:parameters] == Any[1, 4606, 141341324]
    end

    # Duplicate detection must consider the full composite key tuple, not just one.
    @testset "composite match_on rejects duplicate key tuples" begin
        dup_df = DataFrames.DataFrame(
            id      = [1, 1],
            city_id = [5, 5],
            weight  = [10, 20],
        )
        @test_throws PormGError bulk_update(
            Metric.objects, dup_df,
            columns    = ["weight"],
            match_on   = ["id", "city_id"],
            show_query = :dict
        )
        # Distinct tuples on the same first key must NOT be rejected.
        ok_df = DataFrames.DataFrame(
            id      = [1, 1],
            city_id = [5, 6],
            weight  = [10, 20],
        )
        res = bulk_update(
            Metric.objects, ok_df,
            columns    = ["weight"],
            match_on   = ["id", "city_id"],
            show_query = :dict
        )
        @test res isa Dict || res isa Vector
    end

    # A match_on key that is not a model field is a hard error.
    @testset "match_on referencing a non-field raises" begin
        @test_throws PormGError bulk_update(
            Metric.objects, df_upd,
            columns    = ["weight"],
            match_on   = ["not_a_field"],
            show_query = :dict
        )
    end

    # ─────────────────────────────────────────────────────────────────────────────
    # Case-sensitive matching: bare match_on key (Site C)
    # Bulk column matching is exact/case-sensitive. A bare match key whose identity
    # source column exists only in a different case must FAIL LOUDLY — naming the
    # candidate and the columns= mapping fix — rather than silently case-fold (the
    # pre-9958a16 risk of mapping the wrong mixed-case column).
    # ─────────────────────────────────────────────────────────────────────────────
    @testset "bare match_on with case-only source mismatch raises" begin
        # field "id" is unmapped; the df only carries "ID" — same name, wrong case.
        ci_df = DataFrames.DataFrame(ID = [4606], new_w = [9])
        err = try
            bulk_update(
                Metric.objects, ci_df,
                columns    = ["new_w" => "weight"],
                match_on   = ["id"],
                show_query = :dict
            )
            nothing
        catch e
            e
        end
        @test err isa PormGError
        msg = sprint(showerror, err)
        # The error must name the case-only candidate and point at the case-sensitivity,
        # and the suggested fix is a columns= mapping (the single border crossing).
        @test occursin("ID", msg)
        @test occursin("case", msg)
        @test occursin("columns = [..., \"ID\" => \"id\"]", msg)
    end

    # ─────────────────────────────────────────────────────────────────────────────
    # Case-sensitive matching: explicit columns= string (Site A)
    # A bare string in columns= names both the model field and the expected DataFrame
    # column. When the DataFrame carries the same name in a different case, that is a
    # loud error (rename or map explicitly), not a silent fold.
    # ─────────────────────────────────────────────────────────────────────────────
    @testset "explicit columns= string with case-only mismatch raises" begin
        # field "weight" requested; DataFrame only has "Weight".
        df_case = DataFrames.DataFrame(id = [4606], Weight = [9])
        err = try
            bulk_update(
                Metric.objects, df_case,
                columns    = ["weight"],
                match_on   = ["id"],
                show_query = :dict
            )
            nothing
        catch e
            e
        end
        @test err isa PormGError
        msg = sprint(showerror, err)
        @test occursin("Weight", msg)
        @test occursin("case", msg)
    end

    # ─────────────────────────────────────────────────────────────────────────────
    # Case-sensitive matching: auto-detect path, columns=nothing (Site B)
    # With no columns= the path auto-detects DataFrame columns against model fields by
    # EXACT name. A column differing only in case from a model field is a likely-intended
    # typo and must raise rather than be silently folded or ignored.
    # ─────────────────────────────────────────────────────────────────────────────
    @testset "auto-detect rejects a column differing only in case" begin
        # "id" matches exactly; "Weight" differs only in case from field "weight".
        df_auto_case = DataFrames.DataFrame(id = [4606], Weight = [9])
        err = try
            bulk_update(
                Metric.objects, df_auto_case,
                match_on   = ["id"],   # columns=nothing → auto-detect
                show_query = :dict
            )
            nothing
        catch e
            e
        end
        @test err isa PormGError
        msg = sprint(showerror, err)
        # Auto-detect names the DataFrame column and the case-only model field it shadows.
        @test occursin("Weight", msg)
        @test occursin("weight", msg)
        @test occursin("case", msg)
    end

    # ─────────────────────────────────────────────────────────────────────────────
    # Case-sensitive matching: an EXPLICIT columns= mapping is authoritative (#107)
    # A bare match_on key resolves through the mapping established by columns=, even
    # when the mapped DataFrame column differs in case from the field name. The user
    # already spelled out the mapping, so no case error fires — mapping-first
    # resolution checks columns= before looking for a same-named df column.
    # ─────────────────────────────────────────────────────────────────────────────
    @testset "bare match_on resolves through an explicit columns= mapping across case" begin
        # "ID" => "id" explicitly maps the mixed-case DataFrame column to field id.
        df_reuse = DataFrames.DataFrame(ID = [4606], weight = [9])
        res = bulk_update(
            Metric.objects, df_reuse,
            columns    = ["weight", "ID" => "id"],
            match_on   = ["id"],   # bare key reuses the columns= mapping (df "ID")
            show_query = :dict
        )
        @test occursin("\"Tb\".\"id\" = source.\"id\"", res[:sql_text])
        @test res[:parameters] == Any[9, 4606]
    end

    # ─────────────────────────────────────────────────────────────────────────────
    # Case-sensitive matching: explicit columns= Pair (the fourth bulk path)
    # An explicit "df_col" => "field" mapping naming a source column that differs only
    # in case from a real DataFrame column raises the same case hint as the other paths
    # — it must not silently bind a non-existent column.
    # ─────────────────────────────────────────────────────────────────────────────
    @testset "explicit columns= pair with case-only mismatch raises" begin
        # df has "weight"; the mapping names "Weight" — same name, wrong case.
        df_pair_case = DataFrames.DataFrame(id = [4606], weight = [9])
        err = try
            bulk_update(
                Metric.objects, df_pair_case,
                columns    = ["Weight" => "weight"],   # differs only in case from "weight"
                match_on   = ["id"],
                show_query = :dict
            )
            nothing
        catch e
            e
        end
        @test err isa PormGError
        msg = sprint(showerror, err)
        @test occursin("weight", msg)
        @test occursin("case", msg)
    end

    # ─────────────────────────────────────────────────────────────────────────────
    # Case-sensitive matching: explicit columns= Pair naming an absent column
    # A Pair whose source column is genuinely missing (no case near-miss) must raise a
    # clean ArgumentError, not merely log and bind a bad mapping that crashes later.
    # ─────────────────────────────────────────────────────────────────────────────
    @testset "explicit columns= pair naming an absent column raises" begin
        df_pair_missing = DataFrames.DataFrame(id = [4606], weight = [9])
        err = try
            bulk_update(
                Metric.objects, df_pair_missing,
                columns    = ["totally_absent" => "weight"],
                match_on   = ["id"],
                show_query = :dict
            )
            nothing
        catch e
            e
        end
        @test err isa PormGError
        @test occursin("totally_absent", sprint(showerror, err))
    end

    # Constant filters work with the PK fallback when no match_on is supplied.
    @testset "static filters combine with PK fallback (no match_on)" begin
        res = bulk_update(
            Metric.objects, df_upd,
            columns    = ["weight"],
            filters    = ["city_id" => 141341324],
            show_query = :dict
        )
        sql = res[:sql_text]
        @test occursin("\"Tb\".\"id\" = source.\"id\"", sql)            # PK merge
        @test occursin(r"AND\s+\"Tb\"\.\"city_id\"\s*=\s*\$1", sql)     # static guard
        @test res[:parameters] == Any[141341324, 1, 4606]
    end

    # A model with no primary key and no match_on cannot identify rows: hard error.
    @testset "no match_on and no primary key raises" begin
        NoPk = PormG.Models.Model_Type(
            name = "no_pk_scope_model",
            fields = Dict(
                "a" => IntegerField(),
                "b" => IntegerField(),
            ),
            field_names = ["a", "b"],
            connect_key = "default",
        )
        nopk_df = DataFrames.DataFrame(a = [1], b = [2])
        err = try
            bulk_update(NoPk.objects, nopk_df, columns = ["b"], show_query = :dict)
            nothing
        catch e
            e
        end
        @test err isa PormGError
        @test occursin("primary key", lowercase(sprint(showerror, err)))
    end

    # ─────────────────────────────────────────────────────────────────────────────
    # Issue #380: columns= duplicate target field collision contract
    #
    # A model field may not be claimed from two different source columns.
    # When two entries target the same model field from different sources (whether
    # via Pair => Pair or bare-string => Pair), PormG must reject the ambiguity
    # with QueryBuildError rather than silently letting the last entry win.
    # Unambiguous repeats (same source) and absent bare strings (no source claimed)
    # must NOT raise.
    # ─────────────────────────────────────────────────────────────────────────────
    @testset "explicit columns= duplicate target field collision (#380)" begin
        # 1. Pair + Pair from different source columns: MUST raise QueryBuildError
        @testset "Pair + Pair mapping different source columns to same field raises" begin
            df_conflict = DataFrames.DataFrame(id = [4606], c1 = [10], c2 = [20])
            for (op_name, bulk_op) in [("bulk_update", (obj, df; kw...) -> bulk_update(obj, df; match_on = ["id"], kw...)),
                                       ("bulk_insert", (obj, df; kw...) -> bulk_insert(obj, df; kw...)),
                                       ("bulk_copy",   (obj, df; kw...) -> bulk_copy(obj, df; kw...))]
                # Named sub-testset so a failure reports WHICH of the three operations broke —
                # the guard lives in the shared _prepare_bulk_df!, so a regression could hit
                # one path only if a caller ever stopped routing through it.
                @testset "$op_name" begin
                    err = try
                        bulk_op(
                            Metric.objects, df_conflict,
                            columns    = ["c1" => "weight", "c2" => "weight"],
                            show_query = :dict
                        )
                        nothing
                    catch e
                        e
                    end
                    @test err isa PormG.QueryBuildError
                    msg = sprint(showerror, err)
                    @test occursin("weight", msg)
                    @test occursin("c1", msg)
                    @test occursin("c2", msg)
                    @test occursin("mapped from two different columns", msg)
                    # The message must name the operation it came from, and must render clean
                    # off-TTY — QueryBuildError's constructor runs _emsg, so no raw ANSI leaks.
                    @test occursin("Error in $(op_name),", msg)
                    @test !occursin("\e[", msg)
                end
            end
        end

        # 2. Pair + Pair from same source column: unambiguous repeat MUST succeed
        @testset "Pair + Pair mapping same source column to same field is allowed" begin
            df_repeat = DataFrames.DataFrame(id = [4606], c1 = [10])
            res = bulk_update(
                Metric.objects, df_repeat,
                columns    = ["c1" => "weight", "c1" => "weight"],
                match_on   = ["id"],
                show_query = :dict
            )
            @test occursin("\"weight\"", res[:sql_text])
            # The repeat pushes "weight" into fields_df TWICE. Only the final `|> unique` keeps
            # that from emitting `SET "weight" = ..., "weight" = ...`, which PostgreSQL rejects
            # with "multiple assignments to same column". Pin the exact SET clause and the bound
            # values (10 from c1, then the match key) — an occursin alone passes either way.
            @test occursin("SET \"weight\" = source.\"weight\"::integer\n", res[:sql_text])
            @test res[:parameters] == Any[10, 4606]
        end

        # 3. Bare string + Pair from different source column when field ∈ names(df): MUST raise
        @testset "bare string + Pair targeting same field when field is in df raises" begin
            df_str_conflict = DataFrames.DataFrame(id = [4606], weight = [10], c2 = [20])

            # Order: [bare_string, Pair]
            err1 = try
                bulk_update(
                    Metric.objects, df_str_conflict,
                    columns    = ["weight", "c2" => "weight"],
                    match_on   = ["id"],
                    show_query = :dict
                )
                nothing
            catch e
                e
            end
            @test err1 isa PormG.QueryBuildError
            msg1 = sprint(showerror, err1)
            @test occursin("weight", msg1)
            @test occursin("c2", msg1)
            @test occursin("mapped from two different columns", msg1)

            # Reverse order: [Pair, bare_string]
            err2 = try
                bulk_update(
                    Metric.objects, df_str_conflict,
                    columns    = ["c2" => "weight", "weight"],
                    match_on   = ["id"],
                    show_query = :dict
                )
                nothing
            catch e
                e
            end
            @test err2 isa PormG.QueryBuildError
            msg2 = sprint(showerror, err2)
            @test occursin("weight", msg2)
            @test occursin("c2", msg2)
            @test occursin("mapped from two different columns", msg2)
        end

        # 4. Bare string + Bare string when field ∈ names(df): unambiguous repeat MUST succeed
        @testset "bare string repeat when field is in df is allowed" begin
            df_str_repeat = DataFrames.DataFrame(id = [4606], weight = [10])
            res = bulk_update(
                Metric.objects, df_str_repeat,
                columns    = ["weight", "weight"],
                match_on   = ["id"],
                show_query = :dict
            )
            @test occursin("\"weight\"", res[:sql_text])
            # Same de-duplication contract as the Pair repeat above, via the bare-string branch.
            @test occursin("SET \"weight\" = source.\"weight\"::integer\n", res[:sql_text])
            @test res[:parameters] == Any[10, 4606]
        end

        # 5. Bare string + Pair when bare string ∉ names(df): MUST succeed
        # When a bare string names a field the frame has no column for, the string branch does NOT
        # write to mapping (it is the auto-populated field branch). The Pair is the sole claim on df data.
        @testset "bare string absent from df + Pair mapping is allowed (both orders)" begin
            # Model with a defaulted field `laps` that is absent from DataFrame
            StintModel = PormG.Models.Model_Type(
                name = "stint_col_collision_model",
                fields = Dict(
                    "id"   => IDField(),
                    "laps" => IntegerField(default = 0),
                ),
                field_names = ["id", "laps"],
                connect_key = "default",
            )
            df_stint = DataFrames.DataFrame(id = [1], c2 = [45])

            # Order 1: ["laps", "c2" => "laps"]
            res1 = bulk_insert(
                StintModel.objects, df_stint,
                columns    = ["laps", "c2" => "laps"],
                show_query = :dict
            )
            @test occursin("\"laps\"", res1[:sql_text])
            @test res1[:parameters] == Any[45]

            # Order 2: ["c2" => "laps", "laps"]
            res2 = bulk_insert(
                StintModel.objects, df_stint,
                columns    = ["c2" => "laps", "laps"],
                show_query = :dict
            )
            @test occursin("\"laps\"", res2[:sql_text])
            @test res2[:parameters] == Any[45]
        end
    end

end
