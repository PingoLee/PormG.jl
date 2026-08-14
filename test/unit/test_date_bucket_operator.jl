"""
Unit tests for the `__@yyyy_mm` date-bucket filter operator.

`field__@yyyy_mm` is the month-bucket operator, normalising the comparison value via
`Models.format_yyyy_mm` (constants.jl: "yyyy_mm" => "Y_M";
functions.jl: `Y_M(x) = ToChar(x, "YYYY-MM", formatter = Models.format_yyyy_mm)`).

#352: on a bare `DateField` column, a comparison (`=`/`@gte`/`@gt`/`@lte`/`@lt`) against a
`__@yyyy_mm` bucket is rewritten to a sargable range directly on the column — `happened >= \$1 AND
happened < \$2` — instead of `to_char(happened,'YYYY-MM') = \$1`, so an index on `happened` applies
and the planner can estimate selectivity. See `_render_sargable_date_range` in
`build_helpers.jl` and the cross-cutting contract (asymmetry, TIMESTAMPTZ/joined-field exclusion)
in `test_sargable_date_range.jl`. The rendering here only changes for the *filter* path — a bare
`to_char(...)` still appears when the column is projected via `.values("field__@yyyy_mm")`, or
when the filter target is a `DateTimeField`/joined column (out of scope for the rewrite).

Why a dedicated file?
  - `test_operators.jl` covers the comparison / string / null suffixes but not the
    date-bucket transforms.
  - This operator carries a *custom value normaliser* (`format_yyyy_mm`) with its own
    accept/reject contract, and it is heavily used by downstream consumers
    (e.g. "competencia"/"periodo" month filters). A silent change to the value
    normalisation, or to the rendered range boundaries, would break those queries with
    no other failing test — so the contract is pinned here, with no live DB required
    (`show_query=:dict`).
"""

using Test
using PormG
using PormG.Models: Model, IDField, DateField, DateTimeField, format_yyyy_mm

# ---------------------------------------------------------------------------
# Minimal mock-Postgres fixture (no live database).
# ---------------------------------------------------------------------------
if !isdefined(Main, :_YmTestEvent)
  _YmTestEvent = Model("events",
    id        = IDField(),
    happened  = DateField(),
    logged_at = DateTimeField(),
  )
  _YmTestEvent.connect_key = "default"

  struct _MockPostgresYm <: PormG.PormGPostgres end
  PormG.config["default"] = PormG.Configuration.Settings(
    connections = _MockPostgresYm(),
    change_data = true,
  )
end

const _Ev = _YmTestEvent

@testset "Date bucket operator (__@yyyy_mm)" begin

  # =========================================================================
  # 1. String value already in YYYY-MM form
  # =========================================================================
  @testset "YYYY-MM string → sargable range (happened >= \$1 AND happened < \$2)" begin
    res = _Ev.objects.filter("happened__@yyyy_mm" => "1991-10").list(show_query=:dict)

    # #352: bare `=` on a DateField bucket rewrites to a range on the raw column — no to_char.
    @test !occursin("to_char", lowercase(res[:sql_text]))
    @test contains(res[:sql_text], "happened")
    # Half-open interval: the lower bound is inclusive, the upper bound STRICT. Asserted as the
    # full space-delimited predicate so a `<` → `<=` mutation (which would wrongly include the
    # following month's first day) fails here — `occursin("<", …)` alone is true for "<=" too.
    @test occursin(" >= \$1", res[:sql_text]) && occursin(" < \$2", res[:sql_text])
    @test !occursin(" <= \$2", res[:sql_text])
    # Bounds are bound as parameters, never interpolated into the SQL text.
    @test res[:parameters] == ["1991-10-01", "1991-11-01"]
    @test !contains(res[:sql_text], "1991-10-01")
  end

  # =========================================================================
  # 2. Integer YYYYMM is normalised to a "YYYY-MM" bound parameter
  # =========================================================================
  @testset "Integer YYYYMM is normalised to a YYYY-MM-DD range" begin
    res = _Ev.objects.filter("happened__@yyyy_mm" => 202501).list(show_query=:dict)

    @test !occursin("to_char", lowercase(res[:sql_text]))
    # 202501 → "2025-01" (the dash is inserted by format_yyyy_mm) → [2025-01-01, 2025-02-01).
    @test res[:parameters] == ["2025-01-01", "2025-02-01"]

    # The normaliser itself, pinned directly:
    @test format_yyyy_mm(202501) == "2025-01"
    @test format_yyyy_mm("1991-10") == "1991-10"
  end

  # =========================================================================
  # 3. Reject malformed values (the accept/reject contract)
  # =========================================================================
  @testset "Malformed bucket values throw InvalidValueError" begin
    # 4-digit string (year only) — missing the month component.
    @test_throws PormG.InvalidValueError _Ev.objects.filter("happened__@yyyy_mm" => "2025").list(show_query=:dict)
    # Bare 6-digit *string* is NOT accepted (only the dashed string or a 6-digit Integer).
    @test_throws PormG.InvalidValueError _Ev.objects.filter("happened__@yyyy_mm" => "202501").list(show_query=:dict)
    # 4-digit integer is not a YYYYMM bucket.
    @test_throws PormG.InvalidValueError format_yyyy_mm(2025)
    # Non String/Integer value.
    @test_throws PormG.InvalidValueError format_yyyy_mm(2025.0)
  end

  # =========================================================================
  # 4. Combined with another filter — parameter ordering is preserved
  # =========================================================================
  @testset "Bucket filter composes with other filters in order" begin
    res = _Ev.objects.filter(
      "happened__@yyyy_mm" => "2025-01",
      "id__@gte"           => 10,
    ).list(show_query=:dict)

    @test !occursin("to_char", lowercase(res[:sql_text]))
    @test contains(res[:sql_text], ">=")
    @test "2025-01-01" in res[:parameters]
    @test "2025-02-01" in res[:parameters]
    @test 10 in res[:parameters]
    @test length(res[:parameters]) == 3
  end

  # =========================================================================
  # 5. #352 — comparison suffixes rewrite to the asymmetric range boundaries
  # =========================================================================
  @testset "Comparison suffixes bind the correct boundary (asymmetry trap)" begin
    # The operator assertions are deliberately written as `" < \$1"` / `" >= \$1"` — the full
    # rendered predicate, space-delimited. A bare `occursin("<", sql)` is ALSO true for "<=",
    # so it cannot tell a strict bound from a non-strict one: a `<` → `<=` mutation (which would
    # wrongly include the following period's first day) passes it. The rendering is
    # `string(column_sql, " ", op, " ", ph)`, so " < \$1" does not match " <= \$1".

    # @gte / @lt bind the FIRST day of the bucket (F).
    res_gte = _Ev.objects.filter("happened__@yyyy_mm__@gte" => "1991-10").list(show_query=:dict)
    @test !occursin("to_char", lowercase(res_gte[:sql_text]))
    @test occursin(" >= \$1", res_gte[:sql_text]) && !occursin(" > \$1", res_gte[:sql_text])
    @test res_gte[:parameters] == ["1991-10-01"]

    res_lt = _Ev.objects.filter("happened__@yyyy_mm__@lt" => "1991-10").list(show_query=:dict)
    @test !occursin("to_char", lowercase(res_lt[:sql_text]))
    @test occursin(" < \$1", res_lt[:sql_text]) && !occursin(" <= \$1", res_lt[:sql_text])
    @test res_lt[:parameters] == ["1991-10-01"]

    # @gt / @lte bind the NEXT period's first day (N) — NOT the same bound as @gte/@lt.
    res_gt = _Ev.objects.filter("happened__@yyyy_mm__@gt" => "1991-10").list(show_query=:dict)
    @test !occursin("to_char", lowercase(res_gt[:sql_text]))
    @test occursin(" >= \$1", res_gt[:sql_text]) && !occursin(" > \$1", res_gt[:sql_text])
    @test res_gt[:parameters] == ["1991-11-01"]

    res_lte = _Ev.objects.filter("happened__@yyyy_mm__@lte" => "1991-10").list(show_query=:dict)
    @test !occursin("to_char", lowercase(res_lte[:sql_text]))
    @test occursin(" < \$1", res_lte[:sql_text]) && !occursin(" <= \$1", res_lte[:sql_text])
    @test res_lte[:parameters] == ["1991-11-01"]
  end

end
