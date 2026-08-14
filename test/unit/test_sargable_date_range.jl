"""
Unit tests for the sargable date-bucket range rewrite (#352).

`_render_sargable_date_range` (`build_helpers.jl`) rewrites a comparison against a date-bucket
transform (`__@yyyy_mm`, `__@date`, `__@year`) on a bare `DateField` column into a plain
range/comparison directly on the column — `col >= \$1 AND col < \$2` instead of
`to_char(col,'YYYY-MM') = \$1` — so an index on the column applies and the planner can estimate
selectivity (issue #352: a 193x row-count misestimate cascaded into an 18+ minute plan on one
production query).

This file pins the cross-cutting contract shared by all three bucket types — the asymmetric
boundary mapping (`@lt`/`@lte` and `@gt`/`@gte` bind DIFFERENT bounds), the `@date` "no range
needed" simplification, and the two deliberate v1 exclusions (TIMESTAMPTZ/TIMESTAMP columns,
joined/dotted fields) — with no live DB (`show_query=:dict`). The `__@yyyy_mm`-specific
value-normalisation contract (`format_yyyy_mm` accept/reject shapes) and that bucket's own
asymmetry-boundary assertions are already pinned in the sibling `test_date_bucket_operator.jl`;
this file focuses on `@year`, `@date`, and the negative gates that apply across all three.
"""

using Test
using PormG
using PormG.Models: Model, IDField, DateField, DateTimeField, ForeignKey
import Decimals

# ---------------------------------------------------------------------------
# Mock fixture (no live database): a bare DateField, a DateTimeField (TIMESTAMPTZ — must be
# excluded from the rewrite), and an FK to a related model with its own DateField (joined path —
# also must be excluded from the rewrite in v1).
# ---------------------------------------------------------------------------
if !isdefined(Main, :_SdrTeam)
  _SdrTeam = Model("sdr_teams",
    id      = IDField(),
    founded = DateField(),
  )
  _SdrTeam.connect_key = "default"; _SdrTeam._module = Main

  _SdrEvent = Model("sdr_events",
    id        = IDField(),
    happened  = DateField(),
    logged_at = DateTimeField(),
    teamid    = ForeignKey(_SdrTeam, pk_field="id"),
  )
  _SdrEvent.connect_key = "default"; _SdrEvent._module = Main

  struct _MockPostgresSargable <: PormG.PormGPostgres end
  PormG.config["default"] = PormG.Configuration.Settings(
    connections = _MockPostgresSargable(),
    change_data = true,
  )
end

const _SdrEv = _SdrEvent

@testset "Sargable date-bucket range rewrite (#352)" begin

  # =========================================================================
  # 1. @year — asymmetric boundary mapping: F = Jan 1 of year, N = Jan 1 of year+1.
  #    @gte/@lt bind F; @gt/@lte bind N. Swapping @lt/@lte shifts the window a whole year.
  # =========================================================================
  @testset "@year comparison suffixes bind the correct boundary" begin
    # Operator assertions use the full space-delimited predicate (" < \$1", not "<"): a bare
    # `occursin("<", sql)` is also true for "<=", so it cannot distinguish a strict upper bound
    # from a non-strict one, and a `<` → `<=` mutation would pass it unnoticed.
    res_gte = _SdrEv.objects.filter("happened__@year__@gte" => 1991).list(show_query=:dict)
    @test !occursin("extract", lowercase(res_gte[:sql_text]))
    @test occursin(" >= \$1", res_gte[:sql_text]) && !occursin(" > \$1", res_gte[:sql_text])
    @test res_gte[:parameters] == ["1991-01-01"]

    res_lt = _SdrEv.objects.filter("happened__@year__@lt" => 1991).list(show_query=:dict)
    @test !occursin("extract", lowercase(res_lt[:sql_text]))
    @test occursin(" < \$1", res_lt[:sql_text]) && !occursin(" <= \$1", res_lt[:sql_text])
    @test res_lt[:parameters] == ["1991-01-01"]

    res_gt = _SdrEv.objects.filter("happened__@year__@gt" => 1991).list(show_query=:dict)
    @test occursin(" >= \$1", res_gt[:sql_text]) && !occursin(" > \$1", res_gt[:sql_text])
    @test res_gt[:parameters] == ["1992-01-01"]

    res_lte = _SdrEv.objects.filter("happened__@year__@lte" => 1991).list(show_query=:dict)
    @test occursin(" < \$1", res_lte[:sql_text]) && !occursin(" <= \$1", res_lte[:sql_text])
    @test res_lte[:parameters] == ["1992-01-01"]

    # Bare `=` is a 2-parameter half-open range, parenthesised: >= F AND < N (upper bound STRICT).
    res_eq = _SdrEv.objects.filter("happened__@year" => 1991).list(show_query=:dict)
    @test res_eq[:parameters] == ["1991-01-01", "1992-01-01"]
    @test occursin(" >= \$1", res_eq[:sql_text]) && occursin(" < \$2", res_eq[:sql_text])
    @test !occursin(" <= \$2", res_eq[:sql_text])
    @test occursin("(", res_eq[:sql_text]) && occursin(")", res_eq[:sql_text])
  end

  # =========================================================================
  # 1b. @year value contract — every shape the pre-#352 rendering accepted via
  #     Models.format_number_sql still works, so the rewrite is not a breaking change for
  #     consuming apps (an ETL app reading a year out of a Float64 DataFrame column is the
  #     common case). What IS rejected is what a single date bound cannot express.
  # =========================================================================
  @testset "@year accepts every numeric shape the old rendering accepted" begin
    # `Decimals.Decimal(1991)`, not `Decimals.decimal(1991)` — the lowercase helper was REMOVED in
    # Decimals 0.5, which `[compat]` allows and a fresh CI resolve lands on. The type constructor
    # exists in both 0.4 and 0.5.
    for v in (1991, "1991", 1991.0, Int32(1991), Decimals.Decimal(1991))
      res = _SdrEv.objects.filter("happened__@year__@gte" => v).list(show_query=:dict)
      @test res[:parameters] == ["1991-01-01"]
    end
  end

  @testset "@year rejects values no date bound can express" begin
    # Non-numeric string.
    @test_throws PormG.FilterError _SdrEv.objects.filter("happened__@year__@gte" => "abc").list(show_query=:dict)
    # Hex-looking string: tryparse(Int, "0x10") is 16 in Julia, so base=10 must be explicit or
    # this silently becomes year 16.
    @test_throws PormG.FilterError _SdrEv.objects.filter("happened__@year__@gte" => "0x10").list(show_query=:dict)
    # Bool — `Bool <: Integer` in Julia, so `false` would silently become year 0.
    @test_throws PormG.FilterError _SdrEv.objects.filter("happened__@year__@gte" => false).list(show_query=:dict)
    @test_throws PormG.FilterError _SdrEv.objects.filter("happened__@year__@gte" => true).list(show_query=:dict)
    # Fractional year — no single date bound represents it.
    @test_throws PormG.FilterError _SdrEv.objects.filter("happened__@year__@gte" => 1991.7).list(show_query=:dict)
    # Out of the range a rendered date literal can express: Dates.Date(0,1,1) stringifies to
    # "0000-01-01" and Date(-5,1,1) to "-0005-01-01", which both backends reject at execution.
    @test_throws PormG.FilterError _SdrEv.objects.filter("happened__@year__@gte" => 0).list(show_query=:dict)
    @test_throws PormG.FilterError _SdrEv.objects.filter("happened__@year__@gte" => -5).list(show_query=:dict)
    @test_throws PormG.FilterError _SdrEv.objects.filter("happened__@year__@gte" => 999999).list(show_query=:dict)
    # Values too large for Int64: the range check must run BEFORE `Int(...)` narrowing, or these
    # escape as a raw InexactError (not a PormGError, and its message never mentions a year).
    # `isinteger(1e30)` is true, so the whole-year guard alone does not catch that one.
    @test_throws PormG.FilterError _SdrEv.objects.filter("happened__@year__@gte" => big(10)^20).list(show_query=:dict)
    @test_throws PormG.FilterError _SdrEv.objects.filter("happened__@year__@gte" => 1e30).list(show_query=:dict)
    @test_throws PormG.FilterError _SdrEv.objects.filter("happened__@year__@gte" => typemax(UInt64)).list(show_query=:dict)
    # Same guard on the yyyy_mm path — "0000-01" clears format_yyyy_mm's regex.
    @test_throws PormG.FilterError _SdrEv.objects.filter("happened__@yyyy_mm__@gte" => "0000-01").list(show_query=:dict)
  end

  # =========================================================================
  # 2. @date — same granularity as the column: no range, just drop the to_char, operator as-is.
  # =========================================================================
  @testset "@date drops the to_char entirely — operator passes through unchanged" begin
    # The operator is matched space-delimited (" < \$1", not "<"). Substring-matching a bare
    # operator does not discriminate — occursin("<", "… <= \$1") and occursin("=", "… >= \$1")
    # are both true — so a branch hardcoding the wrong operator would pass 3 of these 5.
    for (suffix, op) in [("", "="), ("__@gte", ">="), ("__@gt", ">"), ("__@lte", "<="), ("__@lt", "<")]
      res = _SdrEv.objects.filter("happened__@date$(suffix)" => "1991-10-20").list(show_query=:dict)
      @test !occursin("to_char", lowercase(res[:sql_text]))
      @test occursin(" $(op) \$1", res[:sql_text])
      @test res[:parameters] == ["1991-10-20"]
    end
  end

  # =========================================================================
  # 3. Negative gate — TIMESTAMPTZ/TIMESTAMP columns keep the existing to_char/EXTRACT
  #    rendering: to_char on a timestamptz renders in the session TimeZone, so naively computing
  #    a month/year boundary would shift it around midnight. Deliberately excluded, not a gap.
  # =========================================================================
  @testset "DateTimeField (TIMESTAMPTZ) is excluded from the rewrite" begin
    res = _SdrEv.objects.filter("logged_at__@yyyy_mm__@lte" => "1991-10").list(show_query=:dict)
    @test occursin("to_char", lowercase(res[:sql_text]))
    @test res[:parameters] == ["1991-10"]

    res_year = _SdrEv.objects.filter("logged_at__@year__@gte" => 1991).list(show_query=:dict)
    @test occursin("extract", lowercase(res_year[:sql_text]))
  end

  # =========================================================================
  # 4. Negative gate — a joined/dotted field keeps the existing rendering. A joined path only
  #    resolves its field TYPE after the join renders, which this rewrite runs before — v1 scope
  #    is bare fields only; the joined case falls through to the existing (correct, just
  #    non-sargable) rendering rather than risk resolving the wrong alias mid-render.
  # =========================================================================
  @testset "Joined field is excluded from the rewrite" begin
    res = _SdrEv.objects.filter("teamid__founded__@yyyy_mm__@lte" => "1991-10").list(show_query=:dict)
    @test occursin("to_char", lowercase(res[:sql_text]))
    @test res[:parameters] == ["1991-10"]
  end

  # =========================================================================
  # 5. Invalid bounds raise FilterError, not a bare Dates.jl ArgumentError.
  # =========================================================================
  @testset "Invalid calendar bounds raise FilterError" begin
    # "2026-13" passes format_yyyy_mm's regex shape but is not a real calendar month.
    @test_throws PormG.FilterError _SdrEv.objects.filter("happened__@yyyy_mm__@lte" => "2026-13").list(show_query=:dict)
  end

  # =========================================================================
  # 6. Qor composition — the compound range renders parenthesised and groups correctly when
  #    OR-combined with a sibling filter.
  # =========================================================================
  @testset "Compound range groups correctly inside a Qor" begin
    res = _SdrEv.objects.filter(
      Qor("id__@gte" => 1000, "happened__@yyyy_mm" => "1991-10")
    ).list(show_query=:dict)
    @test occursin(" OR ", res[:sql_text])
    @test !occursin("to_char", lowercase(res[:sql_text]))
    @test 1000 in res[:parameters]
    @test "1991-10-01" in res[:parameters]
    @test "1991-11-01" in res[:parameters]
  end

end
