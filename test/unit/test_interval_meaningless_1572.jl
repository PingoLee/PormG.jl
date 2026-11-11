"""
Interval arithmetic with no meaning is refused at build on every engine (#1572).

#881 refused, on SQLite, the interval arithmetic PostgreSQL has no operator for: an interval plus or
minus a number, an interval times or divided by something that is not a number, a number plus, minus or
divided by an interval, and a date times or divided by an interval. MySQL inherited the refusals
(#1130). PostgreSQL kept rendering them (`interval + bigint`, `interval * interval`,
`double precision / interval`), so the query built and then failed when the statement ran, with a
driver `StatementError` (measured on `db_2` while verifying #1553).

By the engines rule these have no meaning on any engine, so PostgreSQL refuses them at build too, with
the same `QueryBuildError` text, naming itself. A date times a stored `DurationField` column was also
let through on SQLite and MySQL: the refusal tested for an interval held as milliseconds, which a
stored column is not until it is computed on.

A comparison of a number with an interval is not arithmetic and is unchanged here.

Everything renders through mock connections — no live database.

julia --project=test/integration test/unit/test_interval_meaningless_1572.jl
"""

using Test
using PormG
using PormG.Models
using PormG.QueryBuilder: F, inspect_query
using Dates
isdefined(Main, :SQLite) || include(joinpath(@__DIR__, "..", "load_drivers.jl"))

# Dedicated config key + mock types: `runtests.jl` includes every unit file into one `Main`.
struct Im1572MockSQLite <: PormG.PormGSQLite end
struct Im1572MockPostgres <: PormG.PormGPostgres end
struct Im1572MockMySQL <: PormG.PormGMySQL end
const _IM_ENGINES = (
  (Im1572MockPostgres(), "PostgreSQL"),
  (Im1572MockSQLite(), "SQLite"),
  (Im1572MockMySQL(), "MySQL"),
)
PormG.backend_sqlite_version(::Im1572MockSQLite) = 3045000

PormG.config["im1572_mock"] = PormG.Configuration.Settings(
  connections = Im1572MockSQLite(), change_data = true, db_def_folder = "im1572_mock",
)

module Im1572Models
import PormG
import PormG.Models

Im_lap = Models.Model("im_lap",
  id        = Models.IDField(),
  grid      = Models.IntegerField(null = true),
  points    = Models.FloatField(null = true),
  lap       = Models.DurationField(null = true),
  seen      = Models.DateField(null = true),
  logged_at = Models.DateTimeField(null = true),
  code      = Models.CharField(null = true),
)

Models.@models Im_lap
PormG.Models.set_models(@__MODULE__, "im1572_mock")
end

const IM = Im1572Models
_im_sql(expr, conn) = (q = IM.Im_lap.objects; q.values("x" => expr); inspect_query(q; connection = conn)[:sql_text])
_im_err(f) = try f(); nothing catch e; e end
_im_plain(e) = replace(sprint(showerror, e), r"\e\[[0-9;]*m" => "")

# ─────────────────────────────────────────────────────────────────────────────
# #1572: every interval arithmetic shape with no meaning raises at build, on every engine.
# Expected: `QueryBuildError` on PostgreSQL, SQLite and MySQL, its text naming the engine at hand
# ("… is not supported on PostgreSQL"), before any SQL is written. PostgreSQL rendered each of these
# (`("Tb"."lap" + $1::bigint)`, `("Tb"."lap" * "Tb"."lap")`, `("Tb"."points" / "Tb"."lap")`,
# `("Tb"."seen" * "Tb"."lap")`) and failed when the statement ran.
# Why it matters: an error that only one engine raises at run time is a query that type-checks, ships,
# and fails in production; the engines that answer agree it has no meaning.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1572: interval arithmetic with no meaning is refused at build on every engine" begin
  shapes = (
    # an interval on the left
    "interval + integer literal" => () -> F("lap") + 5,
    "interval - integer column"  => () -> F("lap") - F("grid"),
    "interval + float column"    => () -> F("lap") + F("points"),
    "interval * interval"        => () -> F("lap") * F("lap"),
    "interval / interval"        => () -> F("lap") / F("lap"),
    "interval * text column"     => () -> F("lap") * F("code"),
    "timestamp difference + 5"   => () -> (F("logged_at") - F("logged_at")) + 5,
    # an interval on the right
    "integer column + interval"  => () -> F("grid") + F("lap"),
    "integer column - interval"  => () -> F("grid") - F("lap"),
    "float column + interval"    => () -> F("points") + F("lap"),
    "float column - interval"    => () -> F("points") - F("lap"),
    "float column / interval"    => () -> F("points") / F("lap"),
    # a date beside an interval under `*` and `/`
    "date * interval"            => () -> F("seen") * F("lap"),
    "date / interval"            => () -> F("seen") / F("lap"),
    "timestamp * interval"       => () -> F("logged_at") * F("lap"),
  )
  for (label, mk) in shapes, (conn, name) in _IM_ENGINES
    @testset "$label on $name" begin
      err = _im_err(() -> _im_sql(mk(), conn))
      @test err isa PormG.QueryBuildError
      @test occursin("is not supported on $(name)", _im_plain(err))
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# #1572: an interval PormG cannot type, nested under a duration value, is refused where it is built.
# Expected: `(F("lap") + 5) * Hour(1)` and `Hour(1) / (F("lap") / F("lap"))` raise `QueryBuildError` on
# every engine. The side the type walk cannot name is taken as a number by #1553's checks, so the
# refusal comes from the inner arithmetic, which renders first. PostgreSQL rendered both.
# Why it matters: the #1553 checks alone let these through on PostgreSQL; the inner refusal is what
# makes them unreachable, and this pins it.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1572: an untyped interval under a duration value is refused" begin
  for (conn, name) in _IM_ENGINES
    for (expr, inner) in ((() -> (F("lap") + 5) * Hour(1), "`+` between an interval and a number"),
                          (() -> Hour(1) / (F("lap") / F("lap")), "`/` between an interval and a date or an interval"))
      err = _im_err(() -> _im_sql(expr(), conn))
      @test err isa PormG.QueryBuildError
      @test occursin("$(inner) is not supported on $(name)", _im_plain(err))   # the inner arithmetic's refusal
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# #1572: what has a meaning keeps its SQL, on PostgreSQL.
# Expected: an interval scaled or divided by a number, two intervals added, a date shifted by one, and
# a number compared with an interval render the PostgreSQL SQL they rendered before.
# Why it matters: the refusals are the meaningless shapes only — a native `interval * bigint` must not
# become a refusal by accident.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1572: interval arithmetic with a meaning still builds on PostgreSQL" begin
  pg = first(first(_IM_ENGINES))
  @test occursin("(\"Tb\".\"lap\" * \$1::bigint)", _im_sql(F("lap") * 2, pg))
  @test occursin("(\"Tb\".\"grid\" * \"Tb\".\"lap\")", _im_sql(F("grid") * F("lap"), pg))
  @test occursin("(\"Tb\".\"lap\" + \"Tb\".\"lap\")", _im_sql(F("lap") + F("lap"), pg))
  @test occursin("(\"Tb\".\"seen\" + \"Tb\".\"lap\")", _im_sql(F("seen") + F("lap"), pg))
  q = IM.Im_lap.objects
  q.filter(F("points") > F("lap"))
  @test occursin("(\"Tb\".\"points\" > \"Tb\".\"lap\")", inspect_query(q; connection = pg)[:sql_text])
end
