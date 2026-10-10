"""
Unit coverage for #1138: an `order_by()` expression term orders by its expression, whatever its name.

An expression reaches `order_by` wrapped in `SQLOrder(SQLField(expr, name))`. The name is a label:
ORDER BY never prints it. `get_order_query` still matched it against the projection's output names,
and a function projection's chosen name is its `_as`, so its memo key `(:base, "best")` is the key of
every term labelled `"best"`:

    values("constructorid", "best" => Max("points")).
      order_by(SQLOrder(SQLField(F("grid") + Max("points"), "best")))
    # … GROUP BY 1 ORDER BY "best" ASC NULLS LAST        <- sorts by MAX(points); the expression is gone

The #1004 check, which sends an expression term to its own render when the memo keys differ, never saw
it: the keys are equal. Two sibling routes landed on the same alias — a `custom_as` projection
(`values("best" => "points")`), matched before that check runs, and the #587 branch, which looks a
term up by memo key and so found `values("y" => "grid")` for a term labelled `"grid"`.

A path can be labelled the same way (`SQLField("grid", "best")`), and was keyed by the label too, so
the memo handed it the aggregate's entry.

A labelled term now skips every name match and is rendered like an unlabelled one, which is Django's
`order_by(expr)`. Rendered, the issue's own term reads `grid` outside its aggregate, so the #798
mixed-grouping guard refuses it. A term that is the projection's own expression renders that
expression a second time — the same rows, a different statement.

All assertions render through mock PostgreSQL/SQLite connections — no live database. The execution
half lives in `test/integration/test_having.jl`.
"""

using Test
using PormG
using PormG.QueryBuilder: SQLOrder, SQLField, inspect_query, Max, Count, Sum
using PormG.Functions: Case, When

# Dedicated mock connections + config keys: `runtests.jl` includes every unit file into one `Main`.
struct OrderNamedExprMockPostgres <: PormG.PormGPostgres end
struct OrderNamedExprMockSQLite <: PormG.PormGSQLite end
# ORDER BY renders NULL placement via a library-version probe (#75); pin a modern one.
PormG.backend_sqlite_version(::OrderNamedExprMockSQLite) = 3045000

PormG.config["order_named_expr_pg"] = PormG.Configuration.Settings(
  connections = OrderNamedExprMockPostgres(), change_data = true, db_def_folder = "order_named_expr_pg",
)
PormG.config["order_named_expr_sl"] = PormG.Configuration.Settings(
  connections = OrderNamedExprMockSQLite(), change_data = true, db_def_folder = "order_named_expr_sl",
)

# One F1 `result` table per engine. Plain columns, so no join renders; `date` carries the transform
# control at the bottom.
module OrderNamedExprPg
import PormG
import PormG.Models
Result = Models.Model("result",
  resultid      = Models.IDField(),
  raceid        = Models.IntegerField(),
  constructorid = Models.IntegerField(),
  grid          = Models.IntegerField(null = true),
  points        = Models.FloatField(),
  date          = Models.DateField(null = true),
)
PormG.Models.set_models(@__MODULE__, "order_named_expr_pg")
end

module OrderNamedExprSl
import PormG
import PormG.Models
Result = Models.Model("result",
  resultid      = Models.IDField(),
  raceid        = Models.IntegerField(),
  constructorid = Models.IntegerField(),
  grid          = Models.IntegerField(null = true),
  points        = Models.FloatField(),
  date          = Models.DateField(null = true),
)
PormG.Models.set_models(@__MODULE__, "order_named_expr_sl")
end

const _ONE_ENGINES = (("PostgreSQL", OrderNamedExprPg.Result), ("SQLite", OrderNamedExprSl.Result))

# The issue's query, over F1 results: each constructor's best single-race score.
_one_best(Result) = Result.objects.values("constructorid", "best" => Max("points"))

# An expression term labelled `name` — the way `order_by` accepts an expression.
_one_term(expr, name; desc = false) = SQLOrder(SQLField(expr, name); orientation = desc ? "DESC" : "ASC")

_one_sql(q) = replace(inspect_query(q)[:sql_text], r"\s+" => " ")

# The text after ORDER BY: what the statement sorts by, nothing else.
function _one_order_by(sql::AbstractString)
  m = match(r"ORDER BY (.*?)\s*(?:LIMIT|OFFSET|$)", sql)
  return m === nothing ? nothing : strip(m.captures[1])
end

function _one_group_by(sql::AbstractString)
  m = match(r"GROUP BY (.*?)\s+(?:HAVING|ORDER BY|LIMIT|$)", sql)
  return m === nothing ? nothing : strip(m.captures[1])
end

# Colour is on under CI and stripped off a TTY, so assert against the plain text either way.
function _one_refusal(q)
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
# Named expression over a projected column: ordered by the expression (#1138)
# `F("constructorid") + Max("points")` labelled `"best"`, beside `"best" => Max("points")`, renders
# `ORDER BY ("Tb"."constructorid" + MAX("Tb"."points")) ASC` and `GROUP BY 1`. It used to render
# `ORDER BY "best"` — a sort by `MAX(points)` alone, with the `constructorid` term silently dropped.
# ─────────────────────────────────────────────────────────────────────────────
@testset "a named expression term orders by its expression (#1138)" begin
  for (backend, Result) in _ONE_ENGINES
    @testset "$backend" begin
      sql = _one_sql(_one_best(Result).order_by(_one_term(PormG.F("constructorid") + Max("points"), "best")))
      @test startswith(_one_order_by(sql), "(\"Tb\".\"constructorid\" + MAX(\"Tb\".\"points\")) ASC")
      # The projection's alias is not what the statement sorts by.
      @test !occursin("ORDER BY \"best\"", sql)
      # The aggregate term joins no GROUP BY (#1115); the projected column groups as before.
      @test _one_group_by(sql) == "1"
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# The issue's own term: rendered, it meets the #798 guard (#1138)
# `F("grid") + Max("points")` labelled `"best"` reads `grid` outside its aggregate, and nothing groups
# `grid`. Rendered at last, it is refused exactly as the same term labelled `"o"` is (#1115) — where
# it used to build `ORDER BY "best"` and never look at `grid` at all.
# ─────────────────────────────────────────────────────────────────────────────
@testset "the issue's mixed term is refused by the #798 guard (#1138)" begin
  for (backend, Result) in _ONE_ENGINES
    @testset "$backend" begin
      msg = _one_refusal(_one_best(Result).order_by(_one_term(PormG.F("grid") + Max("points"), "best")))
      @test occursin("mixed-grouping guard (#798): the order_by term best reads the column \"grid\"", msg)
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# The projection's own expression under its own name: rendered again (#1138)
# `Max("points")` labelled `"best"` beside `"best" => Max("points")` renders `ORDER BY
# MAX("Tb"."points") DESC` — the same rows the alias gave. Pinned because it is the one shape whose
# SQL text moves without its answer moving: the name no longer picks the projection, even when the
# expression happens to be the same one.
# ─────────────────────────────────────────────────────────────────────────────
@testset "a term that repeats the projection's expression renders it (#1138)" begin
  for (backend, Result) in _ONE_ENGINES
    @testset "$backend" begin
      sql = _one_sql(_one_best(Result).order_by(_one_term(Max("points"), "best"; desc = true)))
      @test startswith(_one_order_by(sql), "MAX(\"Tb\".\"points\") DESC")
      @test _one_group_by(sql) == "1"
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# Sibling routes: a `custom_as` projection and the #587 memo-key lookup (#1138)
# `values("best" => "points")` stores its name in `custom_as`, which matched before the #1004 check ran;
# `values("y" => "grid")` is keyed `(:base, "grid")`, which the #587 branch found for a term labelled
# `"grid"`. Both now render the term: `ORDER BY ("Tb"."grid" * $1)` / `("Tb"."points" * $1)`, where
# they rendered `ORDER BY "best"` and `ORDER BY "y"` — sorts by `points` and by `grid`.
# ─────────────────────────────────────────────────────────────────────────────
@testset "an aliased path projection does not capture a named expression (#1138)" begin
  for (backend, Result) in _ONE_ENGINES
    @testset "$backend — custom_as" begin
      insp = inspect_query(Result.objects.values("best" => "points").
        order_by(_one_term(PormG.F("grid") * 2, "best")))
      sql = replace(insp[:sql_text], r"\s+" => " ")
      @test startswith(_one_order_by(sql), "(\"Tb\".\"grid\" * ")
      # The literal is bound once, for the ORDER BY term.
      @test insp[:parameters] == Any[2]
    end
    @testset "$backend — memo key (#587 branch)" begin
      insp = inspect_query(Result.objects.values("y" => "grid").
        order_by(_one_term(PormG.F("points") * 2, "grid")))
      sql = replace(insp[:sql_text], r"\s+" => " ")
      @test startswith(_one_order_by(sql), "(\"Tb\".\"points\" * ")
      @test insp[:parameters] == Any[2]
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# A labelled PATH: ordered by its column, grouped like `order_by("grid")` (#1138, #1115)
# `SQLField("grid", "best")` is keyed by its label, so the memo branch handed it the aggregate's
# entry and the scan matched the alias: it rendered `ORDER BY "best"`. Now it orders by `"Tb"."grid"`,
# and in the aggregating query the unprojected column joins GROUP BY (`GROUP BY 1, "Tb"."grid"`), as
# the String spelling `order_by("grid")` does.
# ─────────────────────────────────────────────────────────────────────────────
@testset "a labelled path orders by its column, not the projection of that name (#1138)" begin
  for (backend, Result) in _ONE_ENGINES
    @testset "$backend — aggregating query" begin
      sql = _one_sql(_one_best(Result).order_by(_one_term("grid", "best")))
      @test startswith(_one_order_by(sql), "\"Tb\".\"grid\" ASC")
      @test _one_group_by(sql) == "1, \"Tb\".\"grid\""
      # The same statement the plain String spelling builds.
      @test sql == _one_sql(_one_best(Result).order_by("grid"))
    end
    @testset "$backend — aliased path projection" begin
      sql = _one_sql(Result.objects.values("best" => "points").order_by(_one_term("grid", "best")))
      @test startswith(_one_order_by(sql), "\"Tb\".\"grid\" ASC")
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# Binding named expression term: its values bound once, in text order (#1138, #587)
# `Sum(Case([When("grid__@gt" => 10, then = 1)], default = 0))` labelled `"best"` binds three values.
# Rendered rather than aliased, it carries them under `:order`: the marker count equals the bound
# count (3) and the values are 10, 1, 0 — the alias bound nothing, so a misaligned copy would show.
# ─────────────────────────────────────────────────────────────────────────────
@testset "a binding named expression term binds its values once (#1138)" begin
  for (backend, Result) in _ONE_ENGINES
    @testset "$backend" begin
      late_starts = Sum(Case([When("grid__@gt" => 10, then = 1)], default = 0))
      insp = inspect_query(_one_best(Result).order_by(_one_term(late_starts, "best")))
      sql = replace(insp[:sql_text], r"\s+" => " ")
      @test startswith(_one_order_by(sql), "SUM(CASE WHEN")
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
# DISTINCT over the projection's own expression still builds (#1138, #76)
# The rendered `MAX("Tb"."points")` is text-identical to the projection's, which is what the #76 guard
# compares, so `values(…).distinct().order_by(<Max("points") labelled "best">)` builds and orders by
# the expression rather than refusing it as unprojected.
# ─────────────────────────────────────────────────────────────────────────────
@testset "DISTINCT accepts a named term that repeats a projected expression (#1138)" begin
  for (backend, Result) in _ONE_ENGINES
    @testset "$backend" begin
      sql = _one_sql(_one_best(Result).distinct().order_by(_one_term(Max("points"), "best")))
      @test startswith(_one_order_by(sql), "MAX(\"Tb\".\"points\") ASC")
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# DISTINCT over a BINDING projected expression: refused on PostgreSQL only (#1138, #76, #1061)
# `values("constructorid", "x" => F("points") * 2).distinct()` ordered by `F("points") * 2` labelled
# "x". The second render binds `2` again: PostgreSQL numbers it `$2` against the projection's `$1`, so
# the term is not in the DISTINCT list and the #76 guard refuses it, as PostgreSQL itself would. SQLite
# prints `?` for both, the guard matches, and the statement binds `[2, 2]` — what the query means. An
# error on one engine only (#1061, case 4). `order_by("x")` is the spelling that builds on both.
# ─────────────────────────────────────────────────────────────────────────────
@testset "DISTINCT over a repeated binding expression: PostgreSQL refuses, SQLite runs (#1138)" begin
  doubled(Result) = Result.objects.values("constructorid", "x" => PormG.F("points") * 2).distinct()
  @testset "PostgreSQL — refused by the #76 guard" begin
    msg = _one_refusal(doubled(OrderNamedExprPg.Result).order_by(_one_term(PormG.F("points") * 2, "x")))
    @test occursin("DISTINCT query cannot ORDER BY x", msg)
  end
  @testset "SQLite — builds, the value bound once per marker" begin
    insp = inspect_query(doubled(OrderNamedExprSl.Result).order_by(_one_term(PormG.F("points") * 2, "x")))
    sql = replace(insp[:sql_text], r"\s+" => " ")
    @test startswith(_one_order_by(sql), "(\"Tb\".\"points\" * ?) ASC")
    @test count(==('?'), sql) == 2
    @test insp[:parameters] == Any[2, 2]
  end
  @testset "$backend — the alias builds on both" for (backend, Result) in _ONE_ENGINES
    sql = _one_sql(doubled(Result).order_by("x"))
    @test startswith(_one_order_by(sql), "\"x\" ASC")
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# A labelled term leaves no memo entry under its label (#1138)
# `order_by(<F("points") * 2 labelled "grid">, "grid")`: the first term used to be cached under
# `(:base, "grid")`, and the String term `"grid"` read it back — `ORDER BY (points * $1), (points * $1)`,
# and on SQLite two `?` against one bound value. Now the second term is the column: `"Tb"."grid"`, one
# value bound. Same for a labelled path (`SQLField("grid", "points")` then `"points"`).
# ─────────────────────────────────────────────────────────────────────────────
@testset "a labelled term does not poison a later String term of its label (#1138)" begin
  for (backend, Result) in _ONE_ENGINES
    @testset "$backend — labelled expression" begin
      insp = inspect_query(Result.objects.values("constructorid").
        order_by(_one_term(PormG.F("points") * 2, "grid"), "grid"))
      sql = replace(insp[:sql_text], r"\s+" => " ")
      @test endswith(_one_order_by(sql), ", \"Tb\".\"grid\" ASC NULLS LAST")
      @test insp[:parameters] == Any[2]
      backend == "SQLite" && @test count(==('?'), sql) == 1
    end
    @testset "$backend — labelled path" begin
      sql = _one_sql(Result.objects.values("constructorid").order_by(_one_term("grid", "points"), "points"))
      @test _one_order_by(sql) == "\"Tb\".\"grid\" ASC NULLS LAST, \"Tb\".\"points\" ASC NULLS LAST"
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# Controls: what #1138 must not move
# A String term still names the projection: `order_by("-best")` renders `ORDER BY "best" DESC`. A
# transform term is keyed by its path, not a label, so `values("y" => "date__@year")` ordered by
# `"date__@year"` still orders by the projection's name `"y"` (#587), and `values("date__@year")`
# by its generated name `"date__year"`.
# ─────────────────────────────────────────────────────────────────────────────
@testset "String and transform terms still match their projection (#1138 controls)" begin
  for (backend, Result) in _ONE_ENGINES
    @testset "$backend — alias string" begin
      sql = _one_sql(_one_best(Result).order_by("-best"))
      @test startswith(_one_order_by(sql), "\"best\" DESC")
    end
    @testset "$backend — transform projected under a name" begin
      sql = _one_sql(Result.objects.values("y" => "date__@year").order_by("date__@year"))
      @test startswith(_one_order_by(sql), "\"y\" ASC")
    end
    @testset "$backend — transform projected under its generated name" begin
      sql = _one_sql(Result.objects.values("date__@year").order_by("date__@year"))
      @test startswith(_one_order_by(sql), "\"date__year\" ASC")
    end
  end
end
