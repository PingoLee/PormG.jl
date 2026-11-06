"""
A CTE interval column on the right of a value, and a bitwise operator on an interval (#1581).

#1572 refused, on every engine, interval arithmetic with no meaning. Two shapes in the same class still
built, both older than #1572:

1. A `CTE(...)` column holding a duration on the RIGHT of a column that is not an interval:
   `F("points") + CTE("c", "u")`, `F("points") / CTE("c", "u")`, `F("code") + CTE("c", "u")`. The right
   side of F arithmetic is typed only when `_typed_right_operand` accepts it, and it did not accept a
   handle, so the render never sent these to the interval-on-the-right arm (`_render_interval_right`).
   PostgreSQL rendered `double precision + interval`, which fails when the statement runs; SQLite added
   the number to the `HH:MM:SS` text and MySQL to the stored microseconds, a wrong value with no error.
   The same miss made `F("grid") * CTE("c", "u")` multiply the text on SQLite (`'00:01:30' * 2` is `0`)
   where `F("grid") * F("lap")` multiplies the milliseconds. A handle is typed now, as its column.
2. A bitwise operator with an interval on either side (`F("lap") & 1`, `F("grid") | F("lap")`). The last
   arm of `_render_interval_left` kept "the interval is its text", so PostgreSQL rendered `interval &
   bigint`, which fails when the statement runs, and SQLite and MySQL computed on the text or the integer.
   A bitwise operator has no interval meaning on any engine, so it is refused at build on every engine.

Everything renders through mock connections — no live database.

julia --project=test/integration test/unit/test_interval_cte_bitwise_1581.jl
"""

using Test
using PormG
using PormG.Models
using PormG.QueryBuilder: F, inspect_query, CTE, Max
using Dates

# Dedicated config key + mock types: `runtests.jl` includes every unit file into one `Main`.
struct Ib1581MockSQLite <: PormG.PormGSQLite end
struct Ib1581MockPostgres <: PormG.PormGPostgres end
struct Ib1581MockMySQL <: PormG.PormGMySQL end
const _IB_PG = Ib1581MockPostgres()
const _IB_SL = Ib1581MockSQLite()
const _IB_MY = Ib1581MockMySQL()
const _IB_ENGINES = ((_IB_PG, "PostgreSQL"), (_IB_SL, "SQLite"), (_IB_MY, "MySQL"))
PormG.backend_sqlite_version(::Ib1581MockSQLite) = 3045000

PormG.config["ib1581_mock"] = PormG.Configuration.Settings(
  connections = _IB_PG, change_data = true, db_def_folder = "ib1581_mock",
)

module Ib1581Models
import PormG
import PormG.Models

# F1-shaped: a lap with its grid slot, points, lap time, race date and driver code.
Models.@models Ib_lap
Ib_lap = Models.Model("ib_lap",
  id        = Models.IDField(),
  grid      = Models.IntegerField(null = true),
  points    = Models.FloatField(null = true),
  lap       = Models.DurationField(null = true),
  seen      = Models.DateField(null = true),
  logged_at = Models.DateTimeField(null = true),
  code      = Models.CharField(null = true),
)

PormG.Models.set_models(@__MODULE__, "ib1581_mock")
end

const IB = Ib1581Models
_ib_err(f) = try f(); nothing catch e; e end
_ib_plain(e) = replace(sprint(showerror, e), r"\e\[[0-9;]*m" => "")
_ib_sql(expr, conn) = (q = IB.Ib_lap.objects; q.values("v" => expr); inspect_query(q; connection = conn)[:sql_text])
# A query over the CTE `c`, whose column `u` is the lap time and `n` the grid slot; `node` is projected
# as `v`, or filtered on with `filter`.
function _ib_cte(node; filter = nothing)
  body = IB.Ib_lap.objects
  body.values("id", "u" => "lap", "n" => "grid")
  q = IB.Ib_lap.objects
  q.with("c" => body, join_field = "id" => "id", join_type = "INNER")
  if filter === nothing
    q.values("id", "v" => node)
  else
    q.values("id")
    q.filter(filter)
  end
  return q
end
_ib_cte_sql(node, conn; filter = nothing) = inspect_query(_ib_cte(node; filter = filter); connection = conn)
# The projected `v` of the outer query, whitespace collapsed (SQLite's millisecond form spans lines).
_ib_proj(sql) = replace(strip(match(r".*as [\"`]id[\"`],\s*(.*?) as [\"`]v[\"`]\s*\nFROM"s, sql)[1]), r"\s+" => " ")
_ib_where(sql) = replace(strip(split(sql, "WHERE ")[end]), r"\s+" => " ")
# The CTE column, read as the model column it projects, so the same arithmetic on the column is the
# oracle for the handle.
_ib_as_column(s) = replace(s, "\"R1_1\".\"u\"" => "\"R1\".\"lap\"", "`R1_1`.`u`" => "`R1`.`lap`",
                              "\"R1_1\".\"n\"" => "\"R1\".\"grid\"", "`R1_1`.`n`" => "`R1`.`grid`")

# ─────────────────────────────────────────────────────────────────────────────
# #1581: a CTE interval column on the right of a value that is not a number is refused at build.
# Expected: `QueryBuildError` on PostgreSQL, SQLite and MySQL, naming the engine at hand ("… is not
# supported on SQLite"), with #1572's text: `+`/`-` give "between a number and an interval" beside an
# integer, and "with an interval on the right of a value that is not one" beside a float or text. Before,
# each built: `("R1"."points" + "R1_1"."u")` on every engine.
# Why it matters: on SQLite and MySQL that SQL answers, with a number added to the `HH:MM:SS` text or to
# the stored microseconds, so the wrong value reached the caller with no error. The same shapes with an
# `F` column, or with the CTE column on the left, were already refused.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1581: a CTE interval column on the right of a non-number raises on every engine" begin
  shapes = (
    "float column + CTE interval"   => () -> F("points") + CTE("c", "u"),
    "float column - CTE interval"   => () -> F("points") - CTE("c", "u"),
    "float column / CTE interval"   => () -> F("points") / CTE("c", "u"),
    "text column + CTE interval"    => () -> F("code") + CTE("c", "u"),
    "text column * CTE interval"    => () -> F("code") * CTE("c", "u"),
    "integer column / CTE interval" => () -> F("grid") / CTE("c", "u"),
    "integer column + CTE interval" => () -> F("grid") + CTE("c", "u"),
    "date * CTE interval"           => () -> F("seen") * CTE("c", "u"),
  )
  for (label, mk) in shapes, (conn, name) in _IB_ENGINES
    @testset "$label on $name" begin
      err = _ib_err(() -> _ib_cte_sql(mk(), conn))
      @test err isa PormG.QueryBuildError
      @test occursin("is not supported on $(name)", _ib_plain(err))
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# #1581: a number times a CTE interval column is the interval scaled, as it is with the model column.
# Expected: `F("grid") * CTE("c", "u")` renders, on each engine, exactly what `F("grid") * F("lap")`
# renders once `"R1_1"."u"` reads `"R1"."lap"`: `("R1"."grid" * "R1_1"."u")` on PostgreSQL, the rounded
# product of the milliseconds on SQLite and of the microseconds on MySQL. The walk names it an interval.
# Before, SQLite rendered `("R1"."grid" * "R1_1"."u")` too, multiplying the `HH:MM:SS` text.
# Why it matters: the scaling is the one shape here with a meaning, and the handle took the untyped arm
# while the column took the interval one; the two spellings of one value must render the same.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1581: a number times a CTE interval column renders as the column does" begin
  for (conn, name) in _IB_ENGINES
    @testset "$name" begin
      got = _ib_cte_sql(F("grid") * CTE("c", "u"), conn)
      ref = _ib_cte_sql(F("grid") * F("lap"), conn)
      @test _ib_as_column(_ib_proj(got[:sql_text])) == _ib_proj(ref[:sql_text])
      @test got[:parameters] == ref[:parameters]
    end
  end
  @test _ib_proj(_ib_cte_sql(F("grid") * CTE("c", "u"), _IB_PG)[:sql_text]) == "(\"R1\".\"grid\" * \"R1_1\".\"u\")"
  @test !occursin("(\"R1\".\"grid\" * \"R1_1\".\"u\")", _ib_proj(_ib_cte_sql(F("grid") * CTE("c", "u"), _IB_SL)[:sql_text]))
  # The build records it as an interval, so it reads back as one (it was untyped: MySQL read the
  # microseconds as an integer).
  for (conn, _) in _IB_ENGINES
    q = _ib_cte(F("grid") * CTE("c", "u"))
    q_kinds = PormG.QueryBuilder._render_select(q; show_query = :sql, connection = conn).instruction.projection_kinds
    @test get(q_kinds, :v, nothing) isa PormG.CInterval
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# #1581: a CTE column that is not an interval, on the right, keeps the SQL it had.
# Expected: `F("points") + CTE("c", "n")` renders `("R1"."points" + "R1_1"."n")` and a comparison of a
# column with the CTE interval column keeps its SQL on PostgreSQL (`("R1"."points" > "R1_1"."u")`) and
# SQLite (the stored text, as `F("points") > F("lap")` does); MySQL, which compares a count with
# microseconds there, refuses it as before.
# Why it matters: typing the handle routes every CTE right side through the typed arm; only the interval
# shapes may change.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1581: non-interval CTE right sides and comparisons are unchanged" begin
  for (conn, name) in _IB_ENGINES
    got = _ib_cte_sql(F("points") + CTE("c", "n"), conn)
    ref = _ib_cte_sql(F("points") + F("grid"), conn)
    @test _ib_as_column(_ib_proj(got[:sql_text])) == _ib_proj(ref[:sql_text])
  end
  @test _ib_where(_ib_cte_sql(nothing, _IB_PG; filter = F("points") > CTE("c", "u"))[:sql_text]) ==
        "(\"R1\".\"points\" > \"R1_1\".\"u\")"
  @test _ib_where(_ib_cte_sql(nothing, _IB_SL; filter = F("points") > CTE("c", "u"))[:sql_text]) ==
        "(\"R1\".\"points\" > \"R1_1\".\"u\")"
  err = _ib_err(() -> _ib_cte_sql(nothing, _IB_MY; filter = F("points") > CTE("c", "u")))
  @test err isa PormG.QueryBuildError
  @test occursin("is not supported on MySQL", _ib_plain(err))
end

# ─────────────────────────────────────────────────────────────────────────────
# #1581: a bitwise operator with an interval on either side is refused at build on every engine.
# Expected: `QueryBuildError` naming the operator and the engine at hand ("`&` (a bitwise operator) on
# an interval is not supported on PostgreSQL"). Before, each built: `("Tb"."lap" & $1::bigint)` on
# PostgreSQL, which fails when the statement runs, and `("Tb"."lap" & ?)` on SQLite and MySQL, which
# compute on the text or the stored integer.
# Why it matters: an interval has no bits; the SQLite and MySQL answers were values with no meaning,
# returned without an error.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1581: a bitwise operator on an interval raises on every engine" begin
  shapes = (
    "interval & 1"                => ("&",  () -> F("lap") & 1),
    "1 & interval"                => ("&",  () -> 1 & F("lap")),
    "interval | integer column"   => ("|",  () -> F("lap") | F("grid")),
    "integer column | interval"   => ("|",  () -> F("grid") | F("lap")),
    "interval << 1"               => ("<<", () -> F("lap") << 1),
    "integer column >> interval"  => (">>", () -> F("grid") >> F("lap")),
    "timestamp difference & 1"    => ("&",  () -> (F("logged_at") - F("logged_at")) & 1),
    "Max(interval) & 1"           => ("&",  () -> Max("lap") & 1),
    "integer column & Max(interval)" => ("&", () -> F("grid") & Max("lap")),
    "~interval"                   => ("~",  () -> ~F("lap")),
    "xor(interval, 1)"            => ("xor", () -> xor(F("lap"), 1)),
    "xor(integer column, interval)" => ("xor", () -> xor(F("grid"), F("lap"))),
  )
  for (label, (op, mk)) in shapes, (conn, name) in _IB_ENGINES
    @testset "$label on $name" begin
      err = _ib_err(() -> _ib_sql(mk(), conn))
      @test err isa PormG.QueryBuildError
      @test occursin("`$(op)` (a bitwise operator) on an interval is not supported on $(name)", _ib_plain(err))
    end
  end
  # Integers keep their bitwise SQL, and so does a difference of two dates, a whole number of days.
  @test occursin("(\"Tb\".\"grid\" & \$1::bigint)", _ib_sql(F("grid") & 1, _IB_PG))
  for (conn, _) in _IB_ENGINES
    @test _ib_sql((F("seen") - F("seen")) & 1, conn) isa String
  end
end
