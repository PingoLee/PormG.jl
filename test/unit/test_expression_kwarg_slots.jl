"""
A column expression in a value slot — `When`'s `then`, `Case`'s `default`, `Lag`/`Lead`'s
`default` — and in a fixed-shape filter lookup (#808).

`==` on an `FExpression` or a `JoinedReference` builds a SQL predicate by design (#457/#536; the
contract is #541's), so a builder that asks `val == "NULL"` of a user value gets a node back, not a
`Bool`. Two NULL-sentinel checks did exactly that before dispatching on the value's type, and the
usual conditional-aggregation spelling died before any SQL existed:

    Sum(Case([When("positionorder" => 1, then = F("points"))], default = 0))
    # TypeError: non-boolean (PormG.QueryBuilder.FExpression) used in boolean context

Pinned here, on mock PostgreSQL and SQLite connections (no live database):

  1. **A column expression renders as SQL in every value slot** — `then`, `default`, `otherwise`,
     the window `default` — and a binding one (`F("points") * 2`) files its value in SQL text order,
     after the WHEN condition's, which is what a positional (SQLite) backend binds by.
  2. **`missing` in a CASE slot renders `NULL`.** It used to reach the dialect verbatim as the text
     `missing` — `ELSE missing`, which no engine parses.
  3. **Plain values still bind, and the string `"NULL"` is still the SQL literal** — the fix narrows
     a check, it must not move the values that already worked.
  4. **`@isnull` / `@range` refuse a column expression by name.** The shape check lived only on the
     scalar arm, so `"points__@isnull" => F("grid")` rendered `ISNULL "Tb"."grid"`, `@range` a
     one-sided `BETWEEN`, and on a JSON path `@isnull` hit the same `==`-builds-a-node `TypeError`.
  5. **#798's mixed-grouping guard reaches the new slot** — a `then = F(...)` column beside an
     aggregate is checked for grouping like any other column.

julia --project=test/integration test/unit/test_expression_kwarg_slots.jl
"""

using Test
using PormG
using PormG.Models
using PormG.QueryBuilder: inspect_query, F
using PormG.Functions: Sum, Case, When, Lag, Lead, WindowOver, Lower
using PormG: Joined

# Dedicated config key + mock types: `runtests.jl` includes every unit file into one `Main`, so a
# shared key would let another file's settings decide this file's dialect.
struct EksMockSQLite <: PormG.PormGSQLite end
struct EksMockPostgres <: PormG.PormGPostgres end
const _EKS_SL = EksMockSQLite()
const _EKS_PG = EksMockPostgres()
PormG.backend_sqlite_version(::EksMockSQLite) = 3045000

PormG.config["eks_mock"] = PormG.Configuration.Settings(
  connections = _EKS_SL, change_data = true, db_def_folder = "eks_mock",
)

# A result row with the F1 columns the issue's examples read, a driver to join as a `Joined` copy,
# and a JSON column for the JSON-path `@isnull` arm, which renders through its own function.
module EksModels
import PormG
import PormG.Models

Eks_driver = Models.Model("eks_driver",
  id      = Models.IDField(),
  surname = Models.CharField(),
  points  = Models.IntegerField(null = true),
)

Eks_result = Models.Model("eks_result",
  id            = Models.IDField(),
  driver        = Models.ForeignKey(Eks_driver, on_delete = "CASCADE", related_name = "eks_results", null = true),
  points        = Models.IntegerField(null = true),
  grid          = Models.IntegerField(null = true),
  positionorder = Models.IntegerField(null = true),
  payload       = Models.JSONField(null = true),
)

PormG.Models.set_models(@__MODULE__, "eks_mock")
end

const EKS = EksModels
const _EKS_BACKENDS = (("PostgreSQL", _EKS_PG), ("SQLite", _EKS_SL))

_eks_inspect(q, conn) = inspect_query(q; connection = conn)
# The SQL on one line, and without PostgreSQL's `::type` bind casts, so one needle serves both engines.
_eks_sql(q, conn) = replace(replace(_eks_inspect(q, conn)[:sql_text], r"\s+" => " "), r"::\w+" => "")
_eks_params(q, conn) = _eks_inspect(q, conn)[:parameters]

# Build AND render, returning the exception or `nothing`: the #808 crash happened at render time,
# so construction alone proves nothing.
function _eks_err(build, conn)
  try
    _eks_inspect(build(), conn)
    nothing
  catch e
    e
  end
end

_eks_query() = EKS.Eks_result.objects
function _eks_joined_query()
  q = EKS.Eks_result.objects
  q.cjoin_on("Eks_driver", alias = "d", on = [Joined("d", "id") == F("driver")])
  q
end

# ─────────────────────────────────────────────────────────────────────────────
# #808: `then = F(...)` inside `Case`, inside `Sum` — the issue's own conditional-aggregation example.
# The branch renders as the bare column with no placeholder; the WHEN condition's `1` and the
# `default = 0` are still bound, in that order. Before the fix this raised `TypeError: non-boolean`.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#808: then = F(...) renders the column inside Case and Sum" begin
  for (backend, conn) in _EKS_BACKENDS
    @testset "$backend" begin
      q = _eks_query()
      q.values("driver__surname",
        "win_pts" => Sum(Case([When("positionorder" => 1, then = F("points"))], default = 0)))
      sql = _eks_sql(q, conn)
      # A placeholder after THEN would mean the column was bound as a value.
      @test occursin("THEN \"Tb\".\"points\" ELSE", sql)
      @test occursin("SUM(CASE WHEN \"Tb\".\"positionorder\" = ", sql)
      # Condition value, then the ELSE value; nothing for the THEN branch.
      @test _eks_params(q, conn) == [1, 0]
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# #808: a BINDING expression in `then`. `F("points") * 2` carries a value of its own, and a
# positional backend reads placeholders in text order: condition → the `2` inside THEN → ELSE. This
# is the parameter-ordering half of the fix; the rendering half alone would pass with any order.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#808: a binding then-expression files its value in SQL text order" begin
  for (backend, conn) in _EKS_BACKENDS
    @testset "$backend" begin
      q = _eks_query()
      q.values("id", "x" => Case([When("positionorder" => 3, then = F("points") * 2)], default = 7))
      @test occursin("THEN (\"Tb\".\"points\" * ", _eks_sql(q, conn))
      @test _eks_params(q, conn) == [3, 2, 7]
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# #808: the ELSE slot, reached two ways — `Case(...; default = F(...))` and the standalone
# `When(...; otherwise = F(...))`, which wraps itself in a CASE whose `else` is `otherwise`. Both went
# through the same `val == "NULL"` check as `then`.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#808: default = F(...) and otherwise = F(...) render the column in ELSE" begin
  for (backend, conn) in _EKS_BACKENDS
    @testset "$backend" begin
      for x in (Case([When("positionorder" => 1, then = 1)], default = F("grid")),
                When("positionorder" => 1, then = 1, otherwise = F("grid")))
        q = _eks_query()
        q.values("id", "x" => x)
        @test occursin("ELSE \"Tb\".\"grid\" END", _eks_sql(q, conn))
        @test _eks_params(q, conn) == [1, 1]
      end
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# #808: a `Joined(...)` handle in `then`. `JoinedReference` overloads `==` the same way `FExpression`
# does (#481), so it crashed identically; it renders as the joined copy's column.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#808: then = Joined(...) renders the joined column" begin
  for (backend, conn) in _EKS_BACKENDS
    @testset "$backend" begin
      q = _eks_joined_query()
      q.values("id", "x" => Case([When("positionorder" => 1, then = Joined("d", "points"))], default = 0))
      @test occursin("THEN \"d\".\"points\" ELSE", _eks_sql(q, conn))
      @test _eks_params(q, conn) == [1, 0]
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# #808: `Lag`/`Lead` `default = F(...)`. `_resolve_window_kwarg` asked `value == "NULL"` first. The
# default renders as a column in LAG's third argument; the offset is still bound. The `Lead` case
# binds in three places — the column expression, the offset, the default expression — and must keep
# that text order.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#808: Lag/Lead default = F(...) renders the column" begin
  for (backend, conn) in _EKS_BACKENDS
    @testset "$backend" begin
      q = _eks_query()
      q.values("id", "prev" => Lag("points", over = WindowOver(order_by = ["id"]), default = F("grid")))
      sql = _eks_sql(q, conn)
      @test occursin("LAG(\"Tb\".\"points\", ", sql)
      @test occursin(", \"Tb\".\"grid\") OVER", sql)
      @test _eks_params(q, conn) == [1]

      q = _eks_query()
      q.values("id", "nxt" => Lead(F("points") + 1, offset = 2,
        over = WindowOver(order_by = ["id"]), default = F("grid") * 5))
      @test occursin(", (\"Tb\".\"grid\" * ", _eks_sql(q, conn))
      @test _eks_params(q, conn) == [1, 2, 5]
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# #808: `missing` in a CASE value slot renders SQL `NULL`. The branch that recognised it stored the
# raw `missing`, and `Dialect.CASE`/`WHEN` interpolate the slot as text — `ELSE missing` /
# `THEN missing`, a column name no table has. The window slot already mapped it to `NULL`.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#808: missing / nothing in then / default renders NULL" begin
  for (backend, conn) in _EKS_BACKENDS
    @testset "$backend" begin
      q = _eks_query()
      q.values("id", "x" => Case([When("positionorder" => 1, then = 1)], default = missing))
      sql = _eks_sql(q, conn)
      @test occursin("ELSE NULL END", sql)
      @test !occursin("missing", sql)

      q = _eks_query()
      q.values("id", "x" => Case([When("positionorder" => 1, then = missing)], default = 0))
      sql = _eks_sql(q, conn)
      @test occursin("THEN NULL ELSE", sql)
      @test !occursin("missing", sql)
      @test _eks_params(q, conn) == [1, 0]

      # `nothing` is the same literal now. It used to be deferred and BOUND as an untyped
      # `nothing` parameter (`THEN $2`, params `[1, nothing, 0]`) — the same result, by a riskier
      # route, since PostgreSQL had to infer the placeholder's type from its neighbours.
      q = _eks_query()
      q.values("id", "x" => Case([When("positionorder" => 1, then = nothing)], default = 0))
      @test occursin("THEN NULL ELSE", _eks_sql(q, conn))
      @test _eks_params(q, conn) == [1, 0]
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# Regression anchors: what already worked must not move. The string `"NULL"` — `Case`'s documented
# default — stays the SQL literal (not bound); a plain value stays bound; a `Lag` with a value
# default binds it after the offset.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#808: plain values still bind and \"NULL\" stays literal" begin
  for (backend, conn) in _EKS_BACKENDS
    @testset "$backend" begin
      q = _eks_query()
      q.values("id", "x" => Case([When("positionorder" => 1, then = "NULL")]))
      sql = _eks_sql(q, conn)
      @test occursin("THEN NULL ELSE NULL END", sql)
      @test _eks_params(q, conn) == [1]

      q = _eks_query()
      q.values("id", "x" => Case([When("positionorder" => 1, then = 25)], default = 0))
      @test _eks_params(q, conn) == [1, 25, 0]

      q = _eks_query()
      q.values("id", "prev" => Lag("points", over = WindowOver(order_by = ["id"]), default = 0))
      @test _eks_params(q, conn) == [1, 0]
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# #808 sibling: `@isnull` takes `true`/`false`, and `@range` two values — the #654 shape check. It
# ran only on the scalar filter arm, so every column-reference arm (`F`, a function, `Joined`, `CTE`)
# skipped it: on a plain column `ISNULL "Tb"."grid"` / `BETWEEN "Tb"."grid"` reached the database as
# invalid SQL, and on a JSON path `@isnull` evaluated `v.values == true` on the expression and raised
# the same `TypeError: non-boolean`. All now raise the scalar arm's `FilterError`, at the call.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#808: @isnull / @range refuse a column expression" begin
  for (backend, conn) in _EKS_BACKENDS
    @testset "$backend" begin
      for (label, build) in (
          ("F, plain column",     () -> (q = _eks_query(); q.filter("points__@isnull" => F("grid")); q)),
          ("F, JSON path",        () -> (q = _eks_query(); q.filter("payload__kind__@isnull" => F("grid")); q)),
          ("function",            () -> (q = _eks_query(); q.filter("points__@isnull" => Lower("grid")); q)),
          ("Joined",              () -> (q = _eks_joined_query(); q.filter("points__@isnull" => Joined("d", "points")); q)),
          ("CTE",                 () -> (q = _eks_query(); q.filter("points__@isnull" => PormG.CTE("c", "x")); q)),
        )
        err = _eks_err(build, conn)
        @test err isa PormG.FilterError
        @test occursin("'isnull' takes true or false, got a column expression", PormG.error_message(err))
      end

      err = _eks_err(() -> (q = _eks_query(); q.filter("points__@range" => F("grid")); q), conn)
      @test err isa PormG.FilterError
      @test occursin("'range' operator requires exactly 2 values", PormG.error_message(err))

      # The Bool forms still render, on both arms the refusal now covers.
      q = _eks_query()
      q.filter("payload__kind__@isnull" => true)
      @test occursin("IS NULL", _eks_sql(q, conn))
      q = _eks_query()
      q.filter("points__@isnull" => false)
      @test _eks_err(() -> q, conn) === nothing
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# #808 → #798 hand-off: the column in a `then` slot is a projected column, so #798's mixed-grouping
# guard must see it. Here the branch reads `grid` outside any aggregate, beside `Sum`: refused while
# `grid` is ungrouped, accepted once `values()` groups it. Before #808 this never got that far.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#808: #798's grouping guard walks a then = F(...) column" begin
  for (backend, conn) in _EKS_BACKENDS
    @testset "$backend" begin
      mixed = () -> Case([When("positionorder" => 1, then = F("grid"))], default = 0) + Sum("points")

      err = _eks_err(() -> (q = _eks_query(); q.values("positionorder", "x" => mixed()); q), conn)
      @test err isa PormG.QueryBuildError
      @test occursin("\"grid\"", PormG.error_message(err))

      q = _eks_query()
      q.values("positionorder", "grid", "x" => mixed())
      @test _eks_err(() -> q, conn) === nothing
      @test occursin("THEN \"Tb\".\"grid\" ELSE", _eks_sql(q, conn))
    end
  end
end
