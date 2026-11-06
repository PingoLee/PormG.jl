"""
A function's recorded interval kind keeps the calendar part it may hold (#1621).

#1583 gave `CInterval` a `calendar::Bool`: `CInterval(true)` is an interval that may hold a month or a
year. The type walk (`_expression_kind`) carries the flag through functions. The kind the build records
for a projection (`projection_kinds`) did not, for `Max`, `Min` and `Coalesce` at the top of a
projection. Their render returned a bare `interval::Bool`, and the two call sites (`build_select.jl`'s
`_read_kind(…; rendered = …)` and `_render_operand_kind`, the expression-kind matrix's `render` channel)
rebuilt it as `CInterval()`, which says no month. `_render_function_typed` now returns the kind itself,
as `_set_update_query_typed` does for `F` arithmetic.

`Case`, `Cast(…, "interval")` and `Lag` were already right: the render keeps no kind for them, so the
recorded kind is the walk's. They are here as guards.

No SQL changes, and no read or refusal reads the flag from `projection_kinds` yet, so no call returns a
different value. Everything renders through mock connections — no live database.

julia --project=test/integration test/unit/test_function_interval_calendar_1621.jl
"""

using Test
using PormG
using PormG.Models
using PormG.QueryBuilder: F, Max, Min, Coalesce, Case, When, Cast, Lag, WindowOver, inspect_query
using Dates
import PormG.QueryBuilder as QB

# Dedicated config keys + mock types: `runtests.jl` includes every unit file into one `Main`.
struct Fi1621MockPostgres <: PormG.PormGPostgres end
struct Fi1621MockSQLite <: PormG.PormGSQLite end
const _FI_PG = Fi1621MockPostgres()
const _FI_SL = Fi1621MockSQLite()
PormG.backend_sqlite_version(::Fi1621MockSQLite) = 3045000

PormG.config["fi1621_pg"] = PormG.Configuration.Settings(
  connections = _FI_PG, change_data = true, db_def_folder = "fi1621_pg",
)
PormG.config["fi1621_sl"] = PormG.Configuration.Settings(
  connections = _FI_SL, change_data = true, db_def_folder = "fi1621_sl",
)

module Fi1621PgModels
import PormG
import PormG.Models
Result = Models.Model("result",
  resultid       = Models.IDField(),
  grid           = Models.IntegerField(null = true),
  fastestlaptime = Models.DurationField(null = true),
)
PormG.Models.set_models(@__MODULE__, "fi1621_pg")
end

module Fi1621SlModels
import PormG
import PormG.Models
Result = Models.Model("result",
  resultid       = Models.IDField(),
  grid           = Models.IntegerField(null = true),
  fastestlaptime = Models.DurationField(null = true),
)
PormG.Models.set_models(@__MODULE__, "fi1621_sl")
end

const _FI_MONTH = F("grid") * Month(1)
const _FI_MONTH_SQL = "(\"Tb\".\"grid\" * make_interval(months => \$1::integer))"

# The six functions the issue names, over `x`; the other operand is a `DurationField` column.
_fi_functions(x) = [
  "Max"      => Max(x),
  "Min"      => Min(x),
  "Coalesce" => Coalesce(x, F("fastestlaptime")),
  "Case"     => Case([When("grid" => 1, then = x)], default = F("fastestlaptime")),
  "Cast"     => Cast(x, "interval"),
  "Lag"      => Lag(x, over = WindowOver(order_by = ["resultid"])),
]

_fi_query(M, expr) = (q = M.Result.objects; q.values("x" => expr); q)
_fi_sql(M, expr, conn) = inspect_query(_fi_query(M, expr); connection = conn)[:sql_text]
# The kind the build records for the projection `x`.
_fi_recorded(M, expr, conn) =
  get(QB.build(_fi_query(M, expr).object; connection = conn).projection_kinds, :x, nothing)
# An instruction built over the same model, on which the walk and the render are asked.
_fi_instruction(M, conn) = QB.build(_fi_query(M, F("grid")).object; connection = conn)
_fi_walk(M, expr, conn) = QB._expression_kind(expr, _fi_instruction(M, conn))
_fi_render(M, expr, conn) = last(QB._render_operand_kind(expr, _fi_instruction(M, conn); _as = "fi_probe"))

# ─────────────────────────────────────────────────────────────────────────────
# #1621: a function over a month product records `CInterval(true)` on PostgreSQL.
# Expected: `projection_kinds[:x] == CInterval(true)`, equal to the walk's kind, for `Max`, `Min`,
# `Coalesce`, `Case`, `Cast(…, "interval")` and `Lag` over `F("grid") * Month(1)`. The SQL is the SQL
# `main` rendered before the change, e.g. `MAX(("Tb"."grid" * make_interval(months => $1::integer)))`.
# Why it matters: `Max`, `Min` and `Coalesce` recorded `CInterval()`, which says the value holds no
# month. The next reader that decides something about months from the recorded kind (#1576's rule
# reads the walk today) would have concluded there is none.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1621: a function over a month product records CInterval(true) on PostgreSQL" begin
  expected_sql = Dict(
    "Max"      => "MAX($(_FI_MONTH_SQL)) as \"x\"",
    "Min"      => "MIN($(_FI_MONTH_SQL)) as \"x\"",
    "Coalesce" => "COALESCE($(_FI_MONTH_SQL), \"Tb\".\"fastestlaptime\") as \"x\"",
    "Case"     => "CASE\nWHEN \"Tb\".\"grid\" = \$1 THEN (\"Tb\".\"grid\" * make_interval(months => \$2::integer))\n" *
                  "ELSE \"Tb\".\"fastestlaptime\"\nEND\n as \"x\"",
    "Cast"     => "($(_FI_MONTH_SQL))::interval as \"x\"",
    "Lag"      => "LAG($(_FI_MONTH_SQL), \$2::integer) OVER (ORDER BY \"Tb\".\"resultid\" ASC) as \"x\"",
  )
  for (name, expr) in _fi_functions(_FI_MONTH)
    @testset "$(name)" begin
      @test _fi_recorded(Fi1621PgModels, expr, _FI_PG) == PormG.CInterval(true)
      @test _fi_recorded(Fi1621PgModels, expr, _FI_PG) == _fi_walk(Fi1621PgModels, expr, _FI_PG)
      @test _fi_sql(Fi1621PgModels, expr, _FI_PG) ==
            "SELECT\n    $(expected_sql[name])\nFROM \"result\" as \"Tb\"\n"
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# #1621: the same functions over a `DurationField` record `CInterval()` on PostgreSQL.
# Expected: `projection_kinds[:x] == CInterval()` for all six over `F("fastestlaptime")`, and the SQL
# `main` rendered, e.g. `MAX("Tb"."fastestlaptime")`.
# Why it matters: a stored interval holds no month PormG can see (`CInterval`'s docstring), so the flag
# must not be raised for every interval function, only for one over a calendar part.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1621: the same functions over a DurationField record CInterval() on PostgreSQL" begin
  col = "\"Tb\".\"fastestlaptime\""
  expected_sql = Dict(
    "Max"      => "MAX($(col)) as \"x\"",
    "Min"      => "MIN($(col)) as \"x\"",
    "Coalesce" => "COALESCE($(col), $(col)) as \"x\"",
    "Case"     => "CASE\nWHEN \"Tb\".\"grid\" = \$1 THEN $(col)\nELSE $(col)\nEND\n as \"x\"",
    "Cast"     => "($(col))::interval as \"x\"",
    "Lag"      => "LAG($(col), \$1::integer) OVER (ORDER BY \"Tb\".\"resultid\" ASC) as \"x\"",
  )
  for (name, expr) in _fi_functions(F("fastestlaptime"))
    @testset "$(name)" begin
      @test _fi_recorded(Fi1621PgModels, expr, _FI_PG) == PormG.CInterval()
      @test _fi_sql(Fi1621PgModels, expr, _FI_PG) ==
            "SELECT\n    $(expected_sql[name])\nFROM \"result\" as \"Tb\"\n"
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# #1621: the render's own answer (`_render_operand_kind`, the matrix's `render` channel).
# Expected: `CInterval(true)` for `Max`, `Min` and `Coalesce` over the month product, `CInterval()` over
# the `DurationField`, and `nothing` for `Case`, `Cast` and `Lag`, whose render keeps no kind (their
# recorded kind is the walk's, above).
# Why it matters: the channel records what the render computed, apart from the walk. It answered
# `CInterval()` over a month. The fix passes the render's kind through; reading the walk here instead
# would have made the two channels one.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1621: the render channel keeps the calendar part" begin
  for (operand, interval) in ((_FI_MONTH, PormG.CInterval(true)), (F("fastestlaptime"), PormG.CInterval()))
    for (name, expr) in _fi_functions(operand)
      expected = name in ("Max", "Min", "Coalesce") ? interval : nothing
      @test _fi_render(Fi1621PgModels, expr, _FI_PG) == expected
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# #1621: SQLite's millisecond arms still record `CInterval()`.
# Expected: `Max`, `Min` and `Coalesce` over a `DurationField` record `CInterval()` and render through
# the milliseconds, e.g. `(SELECT CASE WHEN _pormg_ms IS NULL … FROM (SELECT MAX(((CASE WHEN substr(…`
# (#894, #900), as on `main`. A month has no millisecond form, and SQLite refuses one (#1553).
# Why it matters: these are the arms whose `true` became a kind; a millisecond form is never a month.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1621: SQLite's millisecond arms still record CInterval()" begin
  ms = "((CASE WHEN substr(\"Tb\".\"fastestlaptime\", 1, 1) = '-' THEN -1 ELSE 1 END) * " *
       "(CAST(ltrim(\"Tb\".\"fastestlaptime\", '+-') AS INTEGER) * 3600000"
  for (name, expr) in _fi_functions(F("fastestlaptime"))[1:3]
    @testset "$(name)" begin
      @test _fi_recorded(Fi1621SlModels, expr, _FI_SL) == PormG.CInterval()
      @test _fi_render(Fi1621SlModels, expr, _FI_SL) == PormG.CInterval()
      sql = _fi_sql(Fi1621SlModels, expr, _FI_SL)
      @test startswith(sql, "SELECT\n    (SELECT CASE WHEN _pormg_ms IS NULL THEN NULL")
      @test occursin("FROM (SELECT $(uppercase(name))($(ms)", sql)
    end
  end
end
