"""
Unit tests for the sargable date-bucket range rewrite (#352).

`_render_sargable_date_range` (`build_helpers.jl`) rewrites a comparison against a date-bucket
transform (`__@yyyy_mm`, `__@date`, `__@year`) on a bare `DateField` column into a plain
range/comparison directly on the column — `col >= \$1 AND col < \$2` instead of
`to_char(col,'YYYY-MM') = \$1` — so an index on the column applies and the planner can estimate
selectivity (issue #352: a 193x row-count misestimate cascaded into an 18+ minute plan on one
production query).

#373 extended the rewrite to a JOINED path (`teamid__founded__@yyyy_mm__@lte`), which #352 had
excluded because the terminal field's type is not readable before the join renders. The resolution
is now delegated to `_build_row_join` itself (it writes the terminal field into `tab_field_cache`
as it walks), so forward FK, reverse-relation, multi-hop and many-to-many paths all resolve through
the SAME code that renders the column — there is no second resolver able to disagree with it.

This file pins the cross-cutting contract shared by all three bucket types — the asymmetric
boundary mapping (`@lt`/`@lte` and `@gt`/`@gte` bind DIFFERENT bounds), the `@date` "no range
needed" simplification, the joined-path coverage, and the one deliberate exclusion
(TIMESTAMPTZ/TIMESTAMP columns) — with no live DB (`show_query=:dict`). The
`__@yyyy_mm`-specific value-normalisation contract (`format_yyyy_mm` accept/reject shapes) and that
bucket's own asymmetry-boundary assertions are already pinned in the sibling
`test_date_bucket_operator.jl`; this file focuses on `@year`, `@date`, the joined paths, and the
negative gates that apply across all three.
"""

using Test
using PormG
using PormG.Models: Model, IDField, DateField, DateTimeField, CharField, ForeignKey, ManyToManyField
using PormG.Functions: ToChar
import Decimals

# ---------------------------------------------------------------------------
# Mock fixture (no live database). The shapes the rewrite has to tell apart:
#   _SdrTeam    — the join TARGET: a DateField (`founded`) plus a DateTimeField (`audited_at`), so
#                 the TIMESTAMPTZ exclusion is exercised THROUGH a join, not only on a bare column.
#   _SdrEvent   — the queried model: bare DateField/DateTimeField, an FK to _SdrTeam, and an M2M.
#                 Its reverse accessor on _SdrTeam is named `events` (#373 reverse-path coverage).
#   _SdrTag     — the M2M target, reached through a synthesized through-table.
#   _SdrLog     — one hop further out, for the MULTI-HOP path `eventid__teamid__founded`.
# Every model's date column is spelled DIFFERENTLY (`founded` / `happened` / `tagged` / `noted`) on
# purpose: a mis-resolution that lands on the wrong model's date column is then visible in the
# rendered SQL, instead of silently matching a same-named column on the wrong table.
# ---------------------------------------------------------------------------
#
# The models live in their own submodule so `set_models` can run: reverse accessors
# (`related_objects`) are wired by that call, not by `Model(...)`, and calling it against `Main`
# would sweep in every other unit file's models when runtests.jl includes them all together.
# Same isolation pattern as `test_reverse_join_mixed_case_binding.jl`.
struct _MockPostgresSargable <: PormG.PormGPostgres end
PormG.config["sargable_mock"] = PormG.Configuration.Settings(
  connections = _MockPostgresSargable(),
  change_data = true,
  db_def_folder = "sargable_mock",
)

module SargableDateModels
import PormG
import PormG.Models
using PormG.Models: Model, IDField, DateField, DateTimeField, CharField, ForeignKey, ManyToManyField

_SdrTeam = Model("sdr_teams",
  id         = IDField(),
  founded    = DateField(),
  audited_at = DateTimeField(),
)

_SdrTag = Model("sdr_tags",
  id      = IDField(),
  label   = CharField(),
  tagged  = DateField(),
  seen_at = DateTimeField(),   # the M2M-reachable TIMESTAMPTZ, for the double-render dedup check
)

_SdrEvent = Model("sdr_events",
  id        = IDField(),
  happened  = DateField(),
  logged_at = DateTimeField(),
  teamid    = ForeignKey(_SdrTeam, pk_field="id", related_name="events"),
  tags      = ManyToManyField(_SdrTag, related_name="events"),
)

_SdrLog = Model("sdr_logs",
  id      = IDField(),
  noted   = DateField(),
  eventid = ForeignKey(_SdrEvent, pk_field="id", related_name="logs"),
)

PormG.Models.set_models(@__MODULE__, "sargable_mock")
end

const _SdrEv   = SargableDateModels._SdrEvent
const _SdrTeam = SargableDateModels._SdrTeam
const _SdrLog  = SargableDateModels._SdrLog

# The WHERE clause of a single-filter query. Used for the baseline-equality assertions below: the
# rewritten bucket comparison must render the SAME predicate text as an ordinary comparison against
# the equivalent plain date, so alias, column, operator and bound are all pinned in one shot —
# against a rendering that never routes through `_render_sargable_date_range` at all.
_sdr_where(res) = strip(split(res[:sql_text], " WHERE ")[end])

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
  # 4. #373 — a DateField reached THROUGH A JOIN is rewritten too. This is the larger half of the
  #    exposure: a joined date filter sits on a fact table reached through a join, which is exactly
  #    where a row-count misestimate does the most damage to the plan above it.
  # =========================================================================
  @testset "Joined DateField is rewritten (#373)" begin
    # Same asymmetric boundary mapping as the bare column, asserted the same way: the FULL
    # space-delimited predicate, never a bare occursin("<", …) — that also matches "<=" and would
    # let a strict/non-strict slip pass silently.
    res_lte = _SdrEv.objects.filter("teamid__founded__@yyyy_mm__@lte" => "1991-10").list(show_query=:dict)
    @test !occursin("to_char", lowercase(res_lte[:sql_text]))
    @test occursin(" < \$1", res_lte[:sql_text]) && !occursin(" <= \$1", res_lte[:sql_text])
    @test res_lte[:parameters] == ["1991-11-01"]
    # The join is still emitted — the rewritten predicate lives on the joined table's alias, so the
    # rewrite never removes the join it needs.
    @test occursin("JOIN", uppercase(res_lte[:sql_text]))
    # …and it targets the TARGET model's date column (`founded`), not the queried model's own
    # same-typed `happened`. A mis-resolution would silently range on the wrong table.
    @test occursin("\"founded\"", res_lte[:sql_text]) && !occursin("\"happened\"", res_lte[:sql_text])

    res_lt = _SdrEv.objects.filter("teamid__founded__@yyyy_mm__@lt" => "1991-10").list(show_query=:dict)
    @test occursin(" < \$1", res_lt[:sql_text]) && !occursin(" <= \$1", res_lt[:sql_text])
    @test res_lt[:parameters] == ["1991-10-01"]

    res_gte = _SdrEv.objects.filter("teamid__founded__@yyyy_mm__@gte" => "1991-10").list(show_query=:dict)
    @test occursin(" >= \$1", res_gte[:sql_text]) && !occursin(" > \$1", res_gte[:sql_text])
    @test res_gte[:parameters] == ["1991-10-01"]

    res_gt = _SdrEv.objects.filter("teamid__founded__@yyyy_mm__@gt" => "1991-10").list(show_query=:dict)
    @test occursin(" >= \$1", res_gt[:sql_text]) && !occursin(" > \$1", res_gt[:sql_text])
    @test res_gt[:parameters] == ["1991-11-01"]

    res_eq = _SdrEv.objects.filter("teamid__founded__@yyyy_mm" => "1991-10").list(show_query=:dict)
    @test res_eq[:parameters] == ["1991-10-01", "1991-11-01"]
    @test occursin(" >= \$1", res_eq[:sql_text]) && occursin(" < \$2", res_eq[:sql_text])
    @test !occursin(" <= \$2", res_eq[:sql_text])

    # @year and @date over the same joined path.
    res_year = _SdrEv.objects.filter("teamid__founded__@year__@gte" => 1991).list(show_query=:dict)
    @test !occursin("extract", lowercase(res_year[:sql_text]))
    @test res_year[:parameters] == ["1991-01-01"]

    res_date = _SdrEv.objects.filter("teamid__founded__@date__@lt" => "1991-10-20").list(show_query=:dict)
    @test !occursin("to_char", lowercase(res_date[:sql_text]))
    @test occursin(" < \$1", res_date[:sql_text]) && !occursin(" <= \$1", res_date[:sql_text])
    @test res_date[:parameters] == ["1991-10-20"]
  end

  # =========================================================================
  # 4b. #373 — the strongest "does not mis-resolve" guard: the rewritten predicate must be
  #     TEXTUALLY IDENTICAL to the same comparison written as an ordinary plain-date filter, which
  #     never routes through `_render_sargable_date_range` at all. One assertion pins the alias, the
  #     column, the operator AND the bound — a walker that resolved the wrong table, the wrong
  #     column, or a stale alias fails here even if every occursin() above still passed.
  # =========================================================================
  @testset "Joined rewrite renders the same predicate as the plain-date baseline (#373)" begin
    for (path, model) in [
          ("teamid__founded",          _SdrEv),   # forward FK, one hop
          ("eventid__teamid__founded", _SdrLog),  # forward FK, MULTI-HOP
          ("events__happened",         _SdrTeam), # REVERSE relation (related_name = "events")
          ("tags__tagged",             _SdrEv),   # MANY-TO-MANY (through-table pair)
        ]
      rewritten = model.objects.filter("$(path)__@year__@gte" => 1991).list(show_query=:dict)
      baseline  = model.objects.filter("$(path)__@gte" => "1991-01-01").list(show_query=:dict)
      @test _sdr_where(rewritten) == _sdr_where(baseline)
      @test rewritten[:parameters] == baseline[:parameters] == ["1991-01-01"]
      @test !occursin("extract", lowercase(rewritten[:sql_text]))
    end
  end

  # =========================================================================
  # 4c. #373 negative gate — the DATE-only restriction survives the join. `to_char` on a
  #     TIMESTAMPTZ renders in the session TimeZone, so computing the bucket boundary in UTC would
  #     shift it around midnight; that reasoning is unchanged by how the column is reached.
  # =========================================================================
  @testset "Joined DateTimeField is still excluded (#373)" begin
    res = _SdrEv.objects.filter("teamid__audited_at__@yyyy_mm__@lte" => "1991-10").list(show_query=:dict)
    @test occursin("to_char", lowercase(res[:sql_text]))
    @test res[:parameters] == ["1991-10"]

    res_year = _SdrEv.objects.filter("teamid__audited_at__@year__@gte" => 1991).list(show_query=:dict)
    @test occursin("extract", lowercase(res_year[:sql_text]))

    # THE load-bearing assumption of the #373 design, pinned here because nothing else would catch
    # it: this is the path that renders the join TWICE — once by the rewrite (to read the terminal
    # field's type out of `tab_field_cache`) and again by the fall-through rendering. `_insert_join`
    # dedups on (a, b, key_a, key_b, alias_a), so exactly one join must survive. If that dedup ever
    # stopped holding, every joined bucket filter on a TIMESTAMPTZ column would silently self-join
    # — inflating row counts with no error, which is the worst failure mode this change could have.
    @test length(collect(eachmatch(r"JOIN", res[:sql_text]))) == 1
    @test length(collect(eachmatch(r"JOIN", res_year[:sql_text]))) == 1

    # The dedup has to hold on EVERY alias-allocating path, not just the one-hop forward FK above.
    # Reverse relations and many-to-many do not reach `_insert_join` the same way: the M2M branch
    # goes through `_insert_many_to_many_joins`, which calls `_get_alias_name` TWICE (through-table
    # + related table) before either row is deduped. A rejected TIMESTAMPTZ terminal on each of
    # those shapes is what forces the double render.
    for (path, model, joins) in [
          ("eventid__teamid__audited_at", _SdrLog,  2),  # multi-hop forward FK
          ("events__logged_at",           _SdrTeam, 1),  # reverse relation
          ("tags__seen_at",               _SdrEv,   2),  # M2M: through-table + related table
        ]
      r = model.objects.filter("$(path)__@yyyy_mm__@lte" => "1991-10").list(show_query=:dict)
      @test occursin("to_char", lowercase(r[:sql_text]))          # rejected → rendered twice
      @test length(collect(eachmatch(r"JOIN", r[:sql_text]))) == joins
      @test r[:parameters] == ["1991-10"]
    end

    # Same guarantee where the rewrite DOES fire, twice over the same path in one query.
    res_two = _SdrEv.objects.filter("teamid__founded__@yyyy_mm__@gte" => "1991-01",
                                    "teamid__founded__@yyyy_mm__@lte" => "1991-12").list(show_query=:dict)
    @test length(collect(eachmatch(r"JOIN", res_two[:sql_text]))) == 1
    @test res_two[:parameters] == ["1991-01-01", "1992-01-01"]
  end

  # =========================================================================
  # 4d. #373 — a CTE-projected DateField is rewritten too, and that needs no special case, which is
  #     worth pinning because it is not obvious. A CTE model's column types are INFERRED
  #     (`_set_field_from_sql_function`), so the question is whether one can be typed DATE while
  #     holding something else. It cannot: a plain-column projection reads the real field, COUNT/SUM
  #     give IntegerField, CASE/WHEN route through `_infer_case_output_type` (Integer/Float/Char
  #     only), MIN/MAX carry the base DateField and do produce a date — and every other function is
  #     REJECTED when the CTE model is built. The last assertion pins that rejection, because it is
  #     what rules out the one shape that would matter here: a `ToChar` projection, whose column
  #     really would be TEXT holding "1991-10".
  # =========================================================================
  @testset "CTE-projected DateField is rewritten; ToChar cannot reach it (#373)" begin
    inner = _SdrEv.objects.values("teamid", "happened")
    res = _SdrEv.objects.
      with("ev" => inner, join_field = "teamid" => "teamid").
      filter("ev__happened__@yyyy_mm__@lte" => "1991-10").
      list(show_query=:dict)
    @test !occursin("to_char", lowercase(res[:sql_text]))
    @test "1991-11-01" in res[:parameters]

    # A ToChar projection never becomes a CTE column at all, so no DATE-typed CTE column can ever
    # hold a formatted string. If this rejection is ever relaxed, the rewrite needs a CTE gate.
    bad = _SdrEv.objects.values("teamid", "bucket" => ToChar("happened", "YYYY-MM"))
    @test_throws PormG.QueryBuildError _SdrEv.objects.
      with("evb" => bad, join_field = "teamid" => "teamid").
      filter("evb__bucket__@yyyy_mm__@lte" => "1991-10").
      list(show_query=:dict)
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
