"""
Unit coverage for #1115: an `order_by()` term that holds an aggregate or a window does not join
`GROUP BY`.

In an aggregating query, `get_order_query` adds every ORDER BY term the projection does not name to
`GROUP BY`. That is right for a column — ordering by an unprojected `grid` splits each group by it, as
Django does — and wrong for an aggregate, which is evaluated per group already:

    values("constructorid", "best" => Max("points")).order_by(SQLOrder(SQLField(Max("points"), "o")))
    # GROUP BY 1, MAX("Tb"."points")      <- both engines refuse an aggregate in GROUP BY

A window term was pushed the same way (`GROUP BY 1, RANK() OVER (…)`, refused as well). The render
of the term already knew both answers (#932 keeps such a term out of the GROUP BY-key phase); the push
never asked. Django's `get_group_by_cols` is the reference: an aggregate contributes nothing, a window
contributes its OVER terms — which #789's `_group_window_terms!` already groups.

Leaving the term out has one consequence that is pinned here too. A MIXED term (`F("grid") +
Max("points")`) reads a column outside its aggregate; pushed whole it was refused by the engines, left
out it would sort by an arbitrary row's `grid` on SQLite. The #798 mixed-grouping guard, which refuses
that shape in `values()`, now walks such order terms as well, and the same holds for a window term's
plain argument (#809).

All assertions render through mock PostgreSQL/SQLite connections — no live database. The execution
half lives in `test/integration/test_having.jl`.
"""

using Test
using PormG
using PormG.QueryBuilder: SQLOrder, SQLField, inspect_query, Rank, Lag, WindowOver, Max, Sum
using PormG.Functions: Case, When

# Dedicated mock connections + config keys: `runtests.jl` includes every unit file into one `Main`.
struct OrderAggGroupMockPostgres <: PormG.PormGPostgres end
struct OrderAggGroupMockSQLite <: PormG.PormGSQLite end
# ORDER BY renders NULL placement via a library-version probe (#75); pin a modern one.
PormG.backend_sqlite_version(::OrderAggGroupMockSQLite) = 3045000

PormG.config["order_agg_group_pg"] = PormG.Configuration.Settings(
  connections = OrderAggGroupMockPostgres(), change_data = true, db_def_folder = "order_agg_group_pg",
)
PormG.config["order_agg_group_sl"] = PormG.Configuration.Settings(
  connections = OrderAggGroupMockSQLite(), change_data = true, db_def_folder = "order_agg_group_sl",
)

# One F1 `result` table per engine. Plain integer columns, so no join renders.
module OrderAggGroupPg
import PormG
import PormG.Models
Result = Models.Model("result",
  resultid      = Models.IDField(),
  raceid        = Models.IntegerField(),
  constructorid = Models.IntegerField(),
  grid          = Models.IntegerField(null = true),
  points        = Models.FloatField(),
)
PormG.Models.set_models(@__MODULE__, "order_agg_group_pg")
end

module OrderAggGroupSl
import PormG
import PormG.Models
Result = Models.Model("result",
  resultid      = Models.IDField(),
  raceid        = Models.IntegerField(),
  constructorid = Models.IntegerField(),
  grid          = Models.IntegerField(null = true),
  points        = Models.FloatField(),
)
PormG.Models.set_models(@__MODULE__, "order_agg_group_sl")
end

const _OAG_ENGINES = (("PostgreSQL", OrderAggGroupPg.Result), ("SQLite", OrderAggGroupSl.Result))

# The query the issue reports, over F1 results: each constructor's best single-race score.
_oag_best(Result) = Result.objects.values("constructorid", "best" => Max("points"))

# An ordering term the way `order_by` accepts an expression: wrapped in `SQLOrder(SQLField(…))`.
_oag_term(expr; desc = false) = SQLOrder(SQLField(expr, "o"); orientation = desc ? "DESC" : "ASC")

_oag_sql(q) = replace(inspect_query(q)[:sql_text], r"\s+" => " ")

# The text between GROUP BY and the next clause: what the statement groups by, nothing else.
function _oag_group_by(sql::AbstractString)
  m = match(r"GROUP BY (.*?)\s+(?:HAVING|ORDER BY|LIMIT|$)", sql)
  return m === nothing ? nothing : strip(m.captures[1])
end

# Colour is on under CI and stripped off a TTY, so assert against the plain text either way.
function _oag_refusal(q)
  err = try
    inspect_query(q)
    nothing
  catch e
    e
  end
  @test err isa PormG.QueryBuildError
  return err === nothing ? "" : replace(sprint(showerror, err), r"\e\[[0-9;]*m" => "")
end

# ─────────────────────────────────────────────────────────────────────────────
# Aggregate order term: left out of GROUP BY (#1115)
# `values("constructorid", "best" => Max("points"))` ordered by `Max("points")` renders `GROUP BY 1`
# and orders by `MAX("Tb"."points")`. It used to render `GROUP BY 1, MAX("Tb"."points")`, which
# PostgreSQL and SQLite both refuse — the issue's report, in F1 terms.
# ─────────────────────────────────────────────────────────────────────────────
@testset "an aggregate order_by term is not grouped (#1115)" begin
  for (backend, Result) in _OAG_ENGINES
    @testset "$backend" begin
      sql = _oag_sql(_oag_best(Result).order_by(_oag_term(Max("points"); desc = true)))
      # Exactly the projection's own grouping — the aggregate term adds nothing.
      @test _oag_group_by(sql) == "1"
      # The ordering itself is untouched: still the aggregate expression, still descending.
      @test occursin("ORDER BY MAX(\"Tb\".\"points\") DESC", sql)
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# Binding aggregate order term: no GROUP BY copy of its values (#1115, #587)
# `Sum(Case([When("grid__@gt" => 10, then = 1)], default = 0))` binds three values. It used to be
# printed in GROUP BY too, and on SQLite its values were copied under `:group` — six values bound.
# Now GROUP BY is `1`, the `?` count equals the bound count (3), and the values are 10, 1, 0 in text
# order. The push and the copy move together: one without the other misaligns every later value.
# ─────────────────────────────────────────────────────────────────────────────
@testset "a binding aggregate order_by term binds its values once (#1115)" begin
  for (backend, Result) in _OAG_ENGINES
    @testset "$backend" begin
      late_starts = Sum(Case([When("grid__@gt" => 10, then = 1)], default = 0))
      insp = inspect_query(_oag_best(Result).order_by(_oag_term(late_starts)))
      sql = replace(insp[:sql_text], r"\s+" => " ")
      @test _oag_group_by(sql) == "1"
      # Three values, bound once, in the order their markers appear in the ORDER BY text.
      @test insp[:parameters] == Any[10, 1, 0]
      if backend == "SQLite"
        @test count(==('?'), sql) == 3
      else
        @test Set(m.match for m in eachmatch(r"\$\d+", sql)) == Set(["\$1", "\$2", "\$3"])
      end
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# Window order term: the window is not grouped, its OVER column is (#1115, #789)
# Ordering by `Rank(over = WindowOver(order_by = ["grid"]))` beside `Max("points")` renders
# `GROUP BY 1, "Tb"."grid"`: `grid` is what the window reads, grouped by #789, and `RANK() OVER (…)`
# itself — which both engines refuse in GROUP BY — is not.
# ─────────────────────────────────────────────────────────────────────────────
@testset "a window order_by term is not grouped; its OVER column is (#1115)" begin
  for (backend, Result) in _OAG_ENGINES
    @testset "$backend" begin
      sql = _oag_sql(_oag_best(Result).order_by(_oag_term(Rank(over = WindowOver(order_by = ["grid"])))))
      @test _oag_group_by(sql) == "1, \"Tb\".\"grid\""
      @test occursin("ORDER BY RANK() OVER (ORDER BY \"Tb\".\"grid\" ASC)", sql)
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# Window through an alias: resolved like the aggregate half (#1115)
# `Case([When("r" => 1, then = 1)])` over `"r" => Rank(…)` renders `CASE WHEN RANK() OVER (…) = …`.
# The window test is resolved through aliases, as the aggregate test is, so the term stays out of
# GROUP BY (`GROUP BY 1`) and binds its three values once. With `then = F("grid")` the term reads
# `grid` beside the window, which nothing groups: refused, naming `grid`.
# ─────────────────────────────────────────────────────────────────────────────
@testset "a window reached through an alias is not grouped (#1115)" begin
  for (backend, Result) in _OAG_ENGINES
    ranked = () -> Result.objects.values("constructorid", "best" => Max("points"),
                                         "r" => Rank(over = WindowOver(order_by = ["constructorid"])))
    @testset "$backend — not grouped" begin
      insp = inspect_query(ranked().order_by(_oag_term(Case([When("r" => 1, then = 1)], default = 0))))
      sql = replace(insp[:sql_text], r"\s+" => " ")
      @test _oag_group_by(sql) == "1"
      @test occursin("ORDER BY CASE WHEN RANK() OVER", sql)
      @test insp[:parameters] == Any[1, 1, 0]
    end
    @testset "$backend — refused: a bare column beside it" begin
      msg = _oag_refusal(ranked().order_by(_oag_term(Case([When("r" => 1, then = PormG.F("grid"))], default = 0))))
      @test occursin("the order_by term o reads the column \"grid\"", msg)
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# Mixed order term: the #798 guard reaches order_by (#1115)
# `F("grid") + Max("points")` reads `grid` outside its aggregate. Left out of GROUP BY, an unprojected
# `grid` would be one arbitrary row's value per group on SQLite, so the build refuses it, naming the
# term and the column. Over the projected `constructorid` the same shape builds, `GROUP BY 1`.
# ─────────────────────────────────────────────────────────────────────────────
@testset "a mixed order_by term is held to the #798 rule (#1115)" begin
  for (backend, Result) in _OAG_ENGINES
    @testset "$backend — refused over an unprojected column" begin
      msg = _oag_refusal(_oag_best(Result).order_by(_oag_term(PormG.F("grid") + Max("points"))))
      @test occursin("mixed-grouping guard (#798): the order_by term o reads the column \"grid\"", msg)
      @test occursin("(in its expression)", msg)
    end
    @testset "$backend — builds over a projected column" begin
      sql = _oag_sql(_oag_best(Result).order_by(_oag_term(PormG.F("constructorid") + Max("points"))))
      @test _oag_group_by(sql) == "1"
      @test occursin("ORDER BY (\"Tb\".\"constructorid\" + MAX(\"Tb\".\"points\")) ASC", sql)
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# Window argument in an order term: #809's rule reaches order_by (#1115)
# `Lag("grid")` beside `Max("points")` reads `grid` once per group, which nothing groups: refused,
# naming the window argument. `Lag(Max("points"))` reads nothing outside its aggregate and builds with
# `GROUP BY 1` (its OVER column `constructorid` is the projection's).
# ─────────────────────────────────────────────────────────────────────────────
@testset "an order_by window's argument is held to the #809 rule (#1115)" begin
  by_team = () -> WindowOver(order_by = ["constructorid"])
  for (backend, Result) in _OAG_ENGINES
    @testset "$backend — refused: a plain argument" begin
      msg = _oag_refusal(_oag_best(Result).order_by(_oag_term(Lag("grid", over = by_team()))))
      @test occursin("the order_by term o reads the column \"grid\"", msg)
      @test occursin("(in its window function's argument)", msg)
    end
    @testset "$backend — builds: an aggregated argument" begin
      sql = _oag_sql(_oag_best(Result).order_by(_oag_term(Lag(Max("points"), over = by_team()))))
      @test _oag_group_by(sql) == "1"
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# Controls: what #1115 must not move
# A plain column order term still joins GROUP BY — `order_by("grid")` renders `GROUP BY 1,
# "Tb"."grid"`, Django's behavior and #932's. And DISTINCT still refuses an unprojected aggregate
# order term (#76): the grouping is skipped, the DISTINCT check is not.
# ─────────────────────────────────────────────────────────────────────────────
@testset "a column order term is still grouped; DISTINCT still refuses (#1115 controls)" begin
  for (backend, Result) in _OAG_ENGINES
    @testset "$backend — column term grouped" begin
      sql = _oag_sql(_oag_best(Result).order_by("grid"))
      @test _oag_group_by(sql) == "1, \"Tb\".\"grid\""
    end
    @testset "$backend — DISTINCT refuses an unprojected aggregate term" begin
      msg = _oag_refusal(_oag_best(Result).distinct().order_by(_oag_term(Sum("points"))))
      @test occursin("DISTINCT query cannot ORDER BY o", msg)
    end
    # A term named like a projection orders by that alias — its expression never reaches the
    # statement, so the #798 guard has nothing to judge and the query builds as it did before.
    @testset "$backend — a term named like a projection orders by the alias" begin
      term = SQLOrder(SQLField(PormG.F("grid") + Max("points"), "best"))
      sql = _oag_sql(_oag_best(Result).order_by(term))
      @test _oag_group_by(sql) == "1"
      @test occursin("ORDER BY \"best\" ASC", sql)
    end
  end
end
