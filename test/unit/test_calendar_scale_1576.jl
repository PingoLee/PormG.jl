"""
A month or a year as an interval value is multiplied by a whole number only, and never divided (#1576).

#1553 made a Dates duration an interval value: `F("grid") * Month(1)` is `make_interval(months => …)` on
PostgreSQL, the one engine whose `interval` keeps months apart (SQLite and MySQL refuse a month value as
the `calendar_intervals` capability). PostgreSQL also built a month scaled by a fraction or divided, and
spread the fraction at 30 days a month: `interval '1 month' * 1.5` is `1 mon 15 days`. That is its
convention, not what a month means. A month has 28 to 31 days, so 1.5 months has no single answer.

Decided on the issue: refused on every engine. The factor's TYPE decides, through the walk. An integer,
or a decimal of scale 0 (#1087, #1550), builds. A float, a decimal with places, and a side the walk
cannot name are refused whatever the value. A division of a month is always refused. The walk names no
kind for what the render refuses.

Literals alone (`1.5 * Month(1)`, `Month(3) / 2`) never reach PormG: Julia's `Dates` computes them
first.

#1583 moved the month into the interval's kind (`CInterval(true)`: the value may hold a calendar part),
so the rule sees it through every value that is one of its operands' — a function, a cast, a window
function, a CTE column — and not only through `F` arithmetic, which a second tree walk searched before.

Everything renders through mock connections — no live database.

julia --project=test/integration test/unit/test_calendar_scale_1576.jl
"""

using Test
using PormG
using PormG.Models
using PormG.QueryBuilder: F, inspect_query
using Dates
import PormG.QueryBuilder as QB

# Dedicated config key + mock types: `runtests.jl` includes every unit file into one `Main`.
struct Cs1576MockSQLite <: PormG.PormGSQLite end
struct Cs1576MockPostgres <: PormG.PormGPostgres end
struct Cs1576MockMySQL <: PormG.PormGMySQL end
const _CS_PG = Cs1576MockPostgres()
const _CS_SL = Cs1576MockSQLite()
const _CS_MY = Cs1576MockMySQL()
PormG.backend_sqlite_version(::Cs1576MockSQLite) = 3045000

PormG.config["cs1576_mock"] = PormG.Configuration.Settings(
  connections = _CS_SL, change_data = true, db_def_folder = "cs1576_mock",
)

module Cs1576Models
import PormG
import PormG.Models

Cs_result = Models.Model("cs_result",
  id     = Models.IDField(),
  grid   = Models.IntegerField(null = true),
  laps   = Models.BigIntegerField(null = true),
  points = Models.FloatField(null = true),
  whole  = Models.DecimalField(max_digits = 4, decimal_places = 0, null = true),
  money  = Models.DecimalField(max_digits = 6, decimal_places = 2, null = true),
  time   = Models.DurationField(null = true),
  at     = Models.DateTimeField(null = true),
)

PormG.Models.set_models(@__MODULE__, "cs1576_mock")
end

const CS = Cs1576Models
_cs_query(expr) = (q = CS.Cs_result.objects; q.values("x" => expr); q)
_cs_sql(expr, conn) = inspect_query(_cs_query(expr); connection = conn)[:sql_text]
_cs_err(f) = try f(); nothing catch e; e end
_cs_plain(e) = replace(sprint(showerror, e), r"\e\[[0-9;]*m" => "")
# The walk's kind for `expr`, asked on an instruction built over the same model.
function _cs_walk(expr, conn)
  q = CS.Cs_result.objects
  q.values("x" => F("grid"))
  return QB._expression_kind(expr, QB.build(q.object; connection = conn))
end

# ─────────────────────────────────────────────────────────────────────────────
# #1576: a month or a year multiplied by a whole number builds on PostgreSQL.
# Expected: an integer column, a `BigIntegerField`, a `DecimalField(4, 0)` and whole arithmetic over them
# render `(<factor> * make_interval(months|years => $1::integer))`, and the walk names an interval that
# may hold a calendar part, `CInterval(true)` (#1583).
# Why it matters: a whole number of months is exact, and is the shape #1553 shipped. The rule must not
# take it away.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1576: a month or a year times a whole number builds on PostgreSQL" begin
  for (expr, factor, unit) in (
      (F("grid") * Month(1), "\"Tb\".\"grid\"", "months"),
      (F("laps") * Year(1), "\"Tb\".\"laps\"", "years"),
      (F("whole") * Month(1), "\"Tb\".\"whole\"", "months"),
      (Month(1) * F("grid"), "\"Tb\".\"grid\"", "months"),
      ((F("grid") + F("laps")) * Month(1), "(\"Tb\".\"grid\" + \"Tb\".\"laps\")", "months"),
      ((F("whole") + 1) * Month(1), "(\"Tb\".\"whole\" + \$1::bigint)", "months"),
    )
    @test occursin("($(factor) * make_interval($(unit) => \$", _cs_sql(expr, _CS_PG))
    @test _cs_walk(expr, _CS_PG) == PormG.CInterval(true)
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# #1576: a month or a year times a factor that is not whole, or divided, raises on PostgreSQL.
# Expected: `QueryBuildError` saying a month has no fixed length and naming the spellings that build
# (an integer column, a CTE column cast to an integer, a duration in days), for a float column, a
# `DecimalField(6, 2)`, fractional arithmetic, a compound period with a month, a quarter, and any
# division of a month or a year. The walk names no kind for any of them. PostgreSQL built every one and
# spread the fraction at 30 days a month.
# The month is found inside interval arithmetic too: `(F("grid") * Month(1)) * 1.5`, a month halved,
# and a month added to an interval then scaled are refused like the bare product.
# Why it matters: a silent different value — "1.5 months after 31 January" has no single answer, and
# PostgreSQL's answer is its own convention.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1576: a month or a year times a fraction, or divided, is refused on PostgreSQL" begin
  for expr in (
      F("points") * Month(1),
      Month(1) * F("points"),
      F("money") * Month(1),
      (F("grid") * 1.5) * Month(1),
      F("points") * (Month(1) + Day(2)),
      F("points") * Dates.Quarter(1),
      Year(1) / F("grid"),
      Month(3) / F("points"),
      Year(1) / F("whole"),
      # The month inside interval arithmetic, then scaled or divided (review of #1576).
      (F("grid") * Month(1)) * 1.5,
      (F("grid") * Month(1)) / 2,
      (F("grid") * Month(1)) * F("points"),
      (F("grid") * Month(1)) / F("grid"),
      F("points") * (F("grid") * Month(1)),
      (Month(1) - F("time")) / 2,
      (F("time") + Month(1)) * 1.5,
      ((F("time") + Month(1)) - F("time")) * F("money"),
    )
    err = _cs_err(() -> _cs_sql(expr, _CS_PG))
    @test err isa PormG.QueryBuildError
    msg = _cs_plain(err)
    @test occursin("A month or a year has no fixed length", msg)
    @test occursin("F(\"grid\") * Month(1)", msg) && occursin("Day(45) * F(\"points\")", msg)
    @test _cs_walk(expr, _CS_PG) === nothing
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# #1576: what the rule does not reach is unchanged.
# Expected, on PostgreSQL, each renders the SQL below:
#  - a duration with no month or year scaled by a float (`F("points") * Day(1)`, `Day(3) / F("points")`);
#  - a zero-length month (`Month(0)` has no calendar part, so it is `make_interval()`);
#  - a month beside an interval (`Month(1) - F("time")`, `F("time") + Month(1)`);
#  - an interval that carries a month, scaled by a whole number (`(F("grid") * Month(1)) * 2`);
#  - a month shifted into a timestamp and subtracted again, which is a difference of two instants and
#    carries no month (`((F("at") + Month(1)) - F("at")) * 1.5`);
#  - a stored `DurationField` scaled by a float (`F("time") * 1.5`): its type says nothing about months.
# On SQLite and MySQL, every month value keeps the `calendar_intervals` `BackendCapabilityError`, whole
# factor or not.
# Why it matters: the refusal is for a fraction of a month PormG can see. A fixed-length duration is
# exact scaled by anything, and the capability is still what SQLite and MySQL report first.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1576: fixed-length durations and other engines are unchanged" begin
  for (expr, sql) in (
      (F("points") * Day(1), "(\"Tb\".\"points\" * make_interval(days => \$1::integer))"),
      (Day(3) / F("points"), "(make_interval(days => \$1::integer) / \"Tb\".\"points\")"),
      (F("points") * Month(0), "(\"Tb\".\"points\" * make_interval())"),
      (Month(1) - F("time"), "(make_interval(months => \$1::integer) - \"Tb\".\"time\")"),
      (F("time") + Month(1), "(\"Tb\".\"time\" + make_interval(months => \$1::integer))"),
      ((F("grid") * Month(1)) * 2, "((\"Tb\".\"grid\" * make_interval(months => \$1::integer)) * \$2::bigint)"),
      (((F("at") + Month(1)) - F("at")) * 1.5, " * \$2::double precision)"),
      (F("time") * 1.5, "(\"Tb\".\"time\" * \$1::double precision)"),
    )
    @test occursin(sql, _cs_sql(expr, _CS_PG))
  end
  # The walk still names the interval where the render builds a month the rule does not refuse, and
  # says whether it may hold one (#1583): a difference of two instants and a stored column do not.
  for (expr, calendar) in (((F("grid") * Month(1)) * 2, true), (((F("at") + Month(1)) - F("at")) * 1.5, false),
                           ((F("time") + Month(1)) * F("whole"), true), (F("time") * 1.5, false))
    @test _cs_walk(expr, _CS_PG) == PormG.CInterval(calendar)
  end
  for conn in (_CS_SL, _CS_MY),
      expr in (F("grid") * Month(1), F("points") * Month(1), Year(1) / F("grid"))
    @test _cs_err(() -> _cs_sql(expr, conn)) isa PormG.BackendCapabilityError
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# #1583: the interval's kind carries "may hold a calendar part", so the rule sees a month through a
# function, a cast, a window function and a CTE column.
# Expected on PostgreSQL: `QueryBuildError` (the #1576 text) for a month product under `Max`, `Min`,
# `Sum`, `Coalesce`, `Greatest`, `NullIf`, `Case`, `Cast(…, "interval")` and `Lag`, scaled by a fraction or
# divided, on either side of the factor, and for a CTE column whose body projects one. The walk names
# each function `CInterval(true)`. Before, each built and PostgreSQL spread the fraction at 30 days a
# month: `(MAX(("Tb"."grid" * make_interval(months => $1::integer))) * $2::double precision)`. The rule
# found the month through `F` arithmetic only, by a second tree walk (`_carries_calendar_part`).
# Why it matters: the same silent 30-day value #1576 refused, one function away.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1583: a month is seen through a function, a cast, a window and a CTE column" begin
  m() = F("grid") * Month(1)
  over = QB.WindowOver(order_by = ["id"])
  wrapped = (
    "Max"      => () -> QB.Max(m()),
    "Min"      => () -> QB.Min(m()),
    "Sum"      => () -> QB.Sum(m()),
    "Coalesce" => () -> QB.Coalesce(m(), F("time")),
    "Greatest" => () -> QB.Greatest(F("time"), m()),
    "NullIf"   => () -> QB.NullIf(m(), F("time")),
    "Case"     => () -> QB.Case(QB.When("grid" => 1, then = m()), default = F("time")),
    "Cast"     => () -> QB.Cast(m(), "interval"),
    "Lag"      => () -> QB.Lag(m(), over = over),
  )
  for (name, w) in wrapped
    @testset "$name" begin
      @test _cs_walk(w(), _CS_PG) == PormG.CInterval(true)
      for expr in (w() * 1.5, w() / 2, w() * F("points"), F("points") * w())
        err = _cs_err(() -> _cs_sql(expr, _CS_PG))
        @test err isa PormG.QueryBuildError
        @test occursin("A month or a year has no fixed length", _cs_plain(err))
      end
      # A whole factor scales a month exactly, so it still builds.
      @test occursin(" * \$", _cs_sql(w() * 2, _CS_PG))
    end
  end
  # A CTE column whose body projects a month product carries it (the maintainer's decision on #1583).
  function cte(node)
    body = CS.Cs_result.objects
    body.values("id", "m" => m(), "t" => "time")
    q = CS.Cs_result.objects
    q.with("c" => body, join_field = "id" => "id", join_type = "INNER")
    q.values("id", "v" => node)
    return inspect_query(q; connection = _CS_PG)[:sql_text]
  end
  for expr in (PormG.CTE("c", "m") * 1.5, F("points") * PormG.CTE("c", "m"), PormG.CTE("c", "m") / 2)
    err = _cs_err(() -> cte(expr))
    @test err isa PormG.QueryBuildError
    @test occursin("A month or a year has no fixed length", _cs_plain(err))
  end
  @test occursin("(\"R1_1\".\"m\" * \$", cte(PormG.CTE("c", "m") * 2))
end

# ─────────────────────────────────────────────────────────────────────────────
# #1583: an interval PormG sees no month in is not refused, through a function either.
# Expected on PostgreSQL: a stored `DurationField` under `Max`, `Coalesce` or a `Cast` to interval, a
# CTE column over a stored duration, and a `Coalesce` of a month product with a column scaled by a whole
# number render; the walk names the stored ones `CInterval()`, and a `Coalesce` of a month product
# with a column `CInterval(true)` (either value may be the row's).
# Why it matters: the rule is for the month PormG can see. A stored interval's type says nothing about
# months, and refusing it would make `Max(F("time")) * 1.5` an error.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1583: a stored interval is not refused, through a function either" begin
  for expr in (QB.Max(F("time")) * 1.5, QB.Coalesce(F("time"), F("time")) / 2,
               QB.Cast(F("time"), "interval") * 1.5, QB.Coalesce(F("grid") * Month(1), F("time")) * 2)
    @test _cs_sql(expr, _CS_PG) isa String
  end
  @test _cs_walk(QB.Max(F("time")), _CS_PG) == PormG.CInterval()
  @test _cs_walk(QB.Cast(F("time"), "interval"), _CS_PG) == PormG.CInterval()
  @test _cs_walk(QB.Coalesce(F("grid") * Month(1), F("time")), _CS_PG) == PormG.CInterval(true)
  body = CS.Cs_result.objects
  body.values("id", "t" => "time")
  q = CS.Cs_result.objects
  q.with("c" => body, join_field = "id" => "id", join_type = "INNER")
  q.values("id", "v" => PormG.CTE("c", "t") * 1.5)
  @test occursin("(\"R1_1\".\"t\" * \$", inspect_query(q; connection = _CS_PG)[:sql_text])
  # The flag is a fact about an expression, never a column's: `CInterval()` is still the column kind,
  # and shows as it always did, so recorded kinds read the same.
  @test PormG.CInterval() == PormG.CInterval(false)
  @test repr(PormG.CInterval()) == "CInterval()" && repr(PormG.CInterval(true)) == "CInterval(true)"
end
