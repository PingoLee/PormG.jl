# ==============================================================================
# UNIT TESTS: a scalar Subquery(...) as a filter value (#926)
#
# `filter("grid" => Subquery(…))` raised a raw `MethodError` naming `_get_pair_to_oper`, on every pair
# spelling — `filter`, `Q`, `When`, `on()`, `cjoin_on` — while `F("grid") == Subquery(…)` raised a
# `QueryBuildError` saying the operand was unsupported. Both now render Django's
# `filter(grid=Subquery(…))`: `WHERE "grid" = (SELECT …)`.
#
# The risk in admitting it is the subquery's own bound values: they must land in the bucket of the
# clause the comparison sits in (`:where`, `:join`, `:having`), in text order. So every rendering case
# asserts the values IN TEXT ORDER on both engines — read off `$N` on PostgreSQL, off the flattened
# vector on SQLite — with a value bound before the subquery, inside it and after it. That is the
# cross-backend differential: neither engine's answer is taken from the other.
#
# DB-free: mock connections, SQL inspected through `inspect_query`.
# ==============================================================================

using Test
using PormG
using PormG.QueryBuilder: inspect_query, F, Q, Qor, Joined, Subquery, OuterRef
using PormG.Functions: Count, Max, Min, Lower, Case, When
using PormG: QueryBuildError, FilterError
using PormG.Functions: Greatest
import Logging

include("helper_marker_alignment.jl")

struct SqFilterMockPostgres <: PormG.PormGPostgres end
struct SqFilterMockSQLite <: PormG.PormGSQLite end
PormG.backend_sqlite_version(::SqFilterMockSQLite) = 3045000

PormG.config["sq_filter_pg"] = PormG.Configuration.Settings(
  connections = SqFilterMockPostgres(), change_data = true, db_def_folder = "sq_filter_pg")
PormG.config["sq_filter_sl"] = PormG.Configuration.Settings(
  connections = SqFilterMockSQLite(), change_data = true, db_def_folder = "sq_filter_sl")

# A result with a ForeignKey to its driver, under each backend, so `on()` has a join to decorate.
module SqFilterPGModels
import PormG
import PormG.Models
Driver = Models.Model("driver",
  driverid = Models.IDField(),
  code = Models.CharField(),
  number = Models.IntegerField(),
)
Result = Models.Model("result",
  resultid = Models.IDField(),
  raceid = Models.IntegerField(),
  grid = Models.IntegerField(),
  chassis = Models.CharField(),
  driverid = Models.ForeignKey(Driver, on_delete = "CASCADE", related_name = "results"),
)
PormG.Models.set_models(@__MODULE__, "sq_filter_pg")
end

module SqFilterSLModels
import PormG
import PormG.Models
Driver = Models.Model("driver",
  driverid = Models.IDField(),
  code = Models.CharField(),
  number = Models.IntegerField(),
)
Result = Models.Model("result",
  resultid = Models.IDField(),
  raceid = Models.IntegerField(),
  grid = Models.IntegerField(),
  chassis = Models.CharField(),
  driverid = Models.ForeignKey(Driver, on_delete = "CASCADE", related_name = "results"),
)
PormG.Models.set_models(@__MODULE__, "sq_filter_sl")
end

const _SQ_MODELS = ((:postgres, SqFilterPGModels), (:sqlite, SqFilterSLModels))

# The race's best grid among the results run on chassis `tag`: one value per outer row, correlated on
# `raceid`, binding one value of its own.
_sq_best(mod, tag = "IN") =
  Subquery(mod.Result.objects.filter("raceid" => OuterRef("raceid"), "chassis" => tag).values("m" => Min("grid")))

# The bound values in the order their markers appear in the text, on either engine.
function _sq_text_order(insp::Dict, backend::Symbol)
  backend === :sqlite && return insp[:parameters]
  return Any[insp[:parameters][parse(Int, m.captures[1])] for m in eachmatch(r"\$(\d+)", insp[:sql_text])]
end

_sq_flat(sql) = replace(sql, r"\s+" => " ")

# ─────────────────────────────────────────────────────────────────────────────
# Every pair spelling renders the subquery, and binds its value between its neighbours
# ─────────────────────────────────────────────────────────────────────────────
@testset "#926: a scalar Subquery renders as a filter value" begin
  for (backend, mod) in _SQ_MODELS
    cases = (
      ("filter pair",
       q -> q.filter("chassis" => "BEFORE", "grid" => _sq_best(mod), "raceid__@gt" => 5),
       "WHERE \"Tb\".\"chassis\" = \\S+ AND \"Tb\".\"grid\" = \\(SELECT MIN\\(\"R1\"\\.\"grid\"\\) as \"m\" FROM " *
       "\"result\" as \"R1\" WHERE \"R1\"\\.\"raceid\" = \"Tb\"\\.\"raceid\" AND \"R1\"\\.\"chassis\" = \\S+ \\) " *
       "AND \"Tb\"\\.\"raceid\" > \\S+",
       Any["BEFORE", "IN", 5]),
      ("lookup pair (@lte)",
       q -> q.filter("grid__@lte" => _sq_best(mod), "raceid" => 7),
       "WHERE \"Tb\".\"grid\" <= \\(SELECT ", Any["IN", 7]),
      ("inside Q",
       q -> q.filter(Q("chassis" => "BEFORE", "grid" => _sq_best(mod)), "raceid" => 7),
       "WHERE \\(\"Tb\".\"chassis\" = \\S+ AND \"Tb\".\"grid\" = \\(SELECT ", Any["BEFORE", "IN", 7]),
      ("inside Qor",
       q -> q.filter(Qor("grid" => _sq_best(mod), "chassis" => "AFTER")),
       "WHERE \\(\"Tb\".\"grid\" = \\(SELECT .+\\) OR \"Tb\".\"chassis\" = \\S+\\)", Any["IN", "AFTER"]),
      ("F comparison",
       q -> q.filter("chassis" => "BEFORE", F("grid") == _sq_best(mod), "raceid" => 7),
       "WHERE \"Tb\".\"chassis\" = \\S+ AND \\(\"Tb\".\"grid\" = \\(SELECT ", Any["BEFORE", "IN", 7]),
      ("function on the left",
       q -> q.filter(Lower("chassis") != _sq_best(mod)),
       "WHERE \\(LOWER\\(\"Tb\".\"chassis\"\\) != \\(SELECT ", Any["IN"]),
      ("When condition in a projection",
       q -> q.values("raceid", "c" => Case([When("grid" => _sq_best(mod), then = 1)], default = 0)),
       "CASE WHEN \"Tb\".\"grid\" = \\(SELECT ", Any["IN", 1, 0]),
    )
    @testset "$backend: $label" for (label, setup, shape, in_text_order) in cases
      q = mod.Result.objects
      setup(q)
      insp = inspect_query(q)
      @test occursin(Regex(shape), _sq_flat(insp[:sql_text]))
      assert_marker_count(insp, backend)
      @test _sq_text_order(insp, backend) == in_text_order
    end
  end
end

# The two spellings are one predicate: the pair and the `F` comparison render the same subquery and
# bind the same values. The `F` form adds only the parentheses every `F` comparison carries.
@testset "#926: the pair and F(...) == Subquery(...) agree" begin
  for (backend, mod) in _SQ_MODELS
    pair = mod.Result.objects
    pair.filter("grid" => _sq_best(mod))
    fcmp = mod.Result.objects
    fcmp.filter(F("grid") == _sq_best(mod))
    p, f = inspect_query(pair), inspect_query(fcmp)
    @test p[:parameters] == f[:parameters]
    where_of = insp -> strip(_sq_flat(split(insp[:sql_text], "WHERE "; limit = 2)[2]))
    @test where_of(f) == "(" * where_of(p) * ")"
    @test occursin("= (SELECT MIN(", where_of(p))
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# Join conditions: the subquery's value binds in the ON clause's bucket
# On SQLite `:join` flattens BEFORE `:where`, which is exactly where a value bound into the wrong bucket
# would overtake the WHERE value (#432). The ON value must come first in the text and in the vector.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#926: a scalar Subquery in a join condition" begin
  for (backend, mod) in _SQ_MODELS
    cases = (
      ("cjoin_on pair",
       q -> (q.cjoin_on(mod.Result; alias = "r2",
                        on = [Joined("r2", "raceid") == F("raceid"), "grid" => _sq_best(mod, "ON")]);
             q.values("raceid", "x" => Joined("r2", "grid")); q.filter("chassis" => "WHERE")),
       "ON \\(\"r2\"\\.\"raceid\" = \"Tb\"\\.\"raceid\"\\) AND \"Tb\"\\.\"grid\" = \\(SELECT "),
      ("cjoin_on F comparison",
       q -> (q.cjoin_on(mod.Result; alias = "r2",
                        on = [Joined("r2", "raceid") == F("raceid"), Joined("r2", "grid") == _sq_best(mod, "ON")]);
             q.values("raceid", "x" => Joined("r2", "grid")); q.filter("chassis" => "WHERE")),
       "AND \\(\"r2\"\\.\"grid\" = \\(SELECT "),
      ("on()",
       q -> (q.on("driverid", "number" => _sq_best(mod, "ON")); q.values("resultid", "driverid__code");
             q.filter("chassis" => "WHERE")),
       "AND \"Tb_1\"\\.\"number\" = \\(SELECT "),
      ("cjoin(filters = …)",
       q -> (q.cjoin("driverid" => "Driver", warn = false, filters = ["number" => _sq_best(mod, "ON")]);
             q.values("resultid", "driverid__code"); q.filter("chassis" => "WHERE")),
       "\"number\" = \\(SELECT "),
    )
    @testset "$backend: $label" for (label, setup, shape) in cases
      q = mod.Result.objects
      setup(q)
      insp = inspect_query(q)
      @test occursin(Regex(shape), _sq_flat(insp[:sql_text]))
      assert_marker_count(insp, backend)
      @test _sq_text_order(insp, backend) == Any["ON", "WHERE"]
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# An alias compared with a subquery: an expression, not a value to type
# The typed alias binder handed the node to the alias's value formatter (`format_number_sql`), a raw
# `MethodError`. It takes the expression route instead, as `F(...)` and `Max(...)` on the right do.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#926: an alias compared with a Subquery" begin
  for (backend, mod) in _SQ_MODELS
    @testset "$backend: aggregate alias → HAVING" begin
      q = mod.Result.objects
      q.values("raceid", "best" => Max("grid"))
      q.filter("best__@gt" => _sq_best(mod))
      insp = inspect_query(q)
      @test occursin(r"HAVING MAX\(\"Tb\"\.\"grid\"\) > \(SELECT ", _sq_flat(insp[:sql_text]))
      assert_marker_count(insp, backend)
      @test _sq_text_order(insp, backend) == Any["IN"]
    end
    @testset "$backend: row alias → WHERE" begin
      q = mod.Result.objects
      q.values("raceid", "g" => F("grid"))
      q.filter("g" => _sq_best(mod), "chassis" => "AFTER")
      insp = inspect_query(q)
      @test occursin(r"WHERE .*\"Tb\"\.\"grid\" = \(SELECT ", _sq_flat(insp[:sql_text]))
      assert_marker_count(insp, backend)
      @test _sq_text_order(insp, backend) == Any["IN", "AFTER"]
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# A filter-position subquery is not a projected correlation (#194)
# A WHERE predicate is evaluated before GROUP BY, so correlating it on an ungrouped column is legal on
# both engines — the rule `Exists(…)` in `filter` already follows. The same subquery PROJECTED in that
# grouped query is still refused: that half of #194 is unchanged.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#926: a filter-position Subquery is outside the #194 guard" begin
  for (backend, mod) in _SQ_MODELS
    @testset "$backend: grouped query, WHERE subquery correlated on an ungrouped column" begin
      q = mod.Result.objects
      q.values("chassis", "n" => Count("resultid"))
      q.filter("grid" => _sq_best(mod))
      insp = inspect_query(q)
      @test occursin(r"WHERE \"Tb\"\.\"grid\" = \(SELECT .+\) GROUP BY 1", _sq_flat(insp[:sql_text]))
    end
    @testset "$backend: the same subquery projected is still refused" begin
      q = mod.Result.objects
      q.values("chassis", "n" => Count("resultid"), "best" => _sq_best(mod))
      err = try; inspect_query(q); nothing; catch e; e; end
      @test err isa QueryBuildError
      @test occursin("raceid", sprint(showerror, err))
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# Refusals stay typed
# A subquery is one value, so the lookups that need a list, a text fragment or a Bool refuse it as they
# refuse a column expression. `@in` names the spelling it does take — the query itself, unwrapped.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#926: lookups a scalar Subquery cannot serve are refused" begin
  for (backend, mod) in _SQ_MODELS
    two_cols = Subquery(mod.Result.objects.filter("raceid" => OuterRef("raceid")).values("grid", "raceid"))
    nested_cte = begin
      inner = mod.Result.objects
      inner.with("ev" => mod.Result.objects.values("raceid", "grid"), join_field = "raceid" => "raceid")
      inner.values("m" => Min("grid"))
      Subquery(inner)
    end
    cases = (
      ("@in", q -> q.filter("grid__@in" => _sq_best(mod)), FilterError,
       "'in' takes the query itself, not a scalar Subquery(...)"),
      ("@nin", q -> q.filter(Q("grid__@nin" => _sq_best(mod))), FilterError,
       "'nin' takes the query itself, not a scalar Subquery(...)"),
      ("@contains", q -> q.filter("chassis__@contains" => _sq_best(mod)), FilterError,
       "'contains' matches a text value, not a column expression"),
      ("@isnull", q -> q.filter("grid__@isnull" => _sq_best(mod)), FilterError,
       "'isnull' takes true or false, got a column expression"),
      ("@range", q -> q.filter("grid__@range" => _sq_best(mod)), FilterError,
       "'range' operator requires exactly 2 values, got 1"),
      ("two projected columns", q -> q.filter("grid" => two_cols), QueryBuildError,
       "Subquery(...) must project exactly one column; it currently projects 2"),
      ("a subquery declaring its own CTE", q -> q.filter("grid" => nested_cte), QueryBuildError,
       "does not support a subquery that declares its own"),
    )
    @testset "$backend: $label" for (label, setup, T, needle) in cases
      err = try
        q = mod.Result.objects
        setup(q)
        inspect_query(q)
        nothing
      catch e
        e
      end
      @test err isa T
      @test occursin(needle, sprint(showerror, err))
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# A subquery compared in HAVING IS a grouped correlation (#194; review of #926)
# HAVING is evaluated after GROUP BY, like a projection, so the WHERE reasoning above does not carry
# over: `HAVING MAX(grid) > (SELECT … WHERE "R1"."raceid" = "Tb"."raceid")` with `raceid` ungrouped is
# refused by PostgreSQL and answered from an arbitrary row by SQLite. Both alias spellings — top-level
# and inside `Q` — go through the guard; correlating on a grouped column still builds.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#926: a Subquery in HAVING is checked by the #194 guard" begin
  for (backend, mod) in _SQ_MODELS
    @testset "$backend: $label" for (label, filt) in (("top-level alias", s -> s),
                                                     ("inside Q", s -> Q(s)))
      q = mod.Result.objects
      q.values("chassis", "best" => Max("grid"))
      q.filter(filt("best__@gt" => _sq_best(mod)))
      err = try; inspect_query(q); nothing; catch e; e; end
      @test err isa QueryBuildError
      msg = replace(sprint(showerror, err), r"\e\[[0-9;]*m" => "")
      @test occursin("grouped-correlation guard (#194)", msg)
      @test occursin("Subquery(…) in the HAVING filter on \"best\"", msg)
      @test occursin("correlates on raceid", msg)
    end
    @testset "$backend: grouped on the correlated column, it builds" begin
      q = mod.Result.objects
      q.values("raceid", "best" => Max("grid"))
      q.filter(Q("best__@gt" => _sq_best(mod)))
      insp = inspect_query(q)
      @test occursin(r"GROUP BY 1 HAVING \(MAX\(\"Tb\"\.\"grid\"\) > \(SELECT ", _sq_flat(insp[:sql_text]))
      @test _sq_text_order(insp, backend) == Any["IN"]
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# Buckets that flatten AHEAD of :where (review of #926)
# A CTE body binds in `:cte` and an UPDATE's SET in `:update`, both flattened before `:where` on
# SQLite. A subquery value in the body, and one in the WHERE of an UPDATE, must still bind in text order.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#926: a Subquery value in a CTE body and in an UPDATE" begin
  for (backend, mod) in _SQ_MODELS
    @testset "$backend: CTE body" begin
      body = mod.Result.objects
      body.filter("chassis" => "BODY", "grid" => _sq_best(mod))
      body.values("raceid", "grid")
      q = mod.Result.objects
      q.with("ev" => body, join_field = "raceid" => "raceid")
      q.values("raceid", "ev__grid")
      q.filter("chassis" => "OUTER")
      insp = inspect_query(q)
      @test occursin(r"WITH \"ev\" AS \( SELECT .+ WHERE \"Tb\"\.\"chassis\" = \S+ AND \"Tb\"\.\"grid\" = \(SELECT ",
                     _sq_flat(insp[:sql_text]))
      assert_marker_count(insp, backend)
      @test _sq_text_order(insp, backend) == Any["BODY", "IN", "OUTER"]
    end
    @testset "$backend: UPDATE … WHERE" begin
      q = mod.Result.objects
      q.filter("chassis" => "BEFORE", "grid" => _sq_best(mod))
      res = q.update("chassis" => "SET", show_query = :dict)
      sql = _sq_flat(res[:sql_text])
      @test occursin(r"UPDATE .+ SET .+ WHERE .+\(SELECT MIN", sql)
      @test _sq_text_order(res, backend) == Any["SET", "BEFORE", "IN"]
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# A subquery compared in a projection's `When` condition is checked too (review of #926)
# The SELECT list is evaluated after GROUP BY, so the condition's correlation needs a grouped column,
# as an `Exists(…)` leaf of a projected `When` already did. Both spellings, pair and `F`, are recorded;
# grouping on the correlated column builds.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#926: a Subquery in a projected When condition is checked by the #194 guard" begin
  for (backend, mod) in _SQ_MODELS
    conds = (("pair", () -> "grid" => _sq_best(mod)), ("F comparison", () -> F("grid") == _sq_best(mod)))
    @testset "$backend: $label, ungrouped" for (label, cond) in conds
      q = mod.Result.objects
      # `grid` is projected, so the one ungrouped column left is the subquery's `raceid` (#798 aside).
      q.values("chassis", "grid", "n" => Case([When(cond(), then = Count("resultid"))], default = 0))
      err = try; inspect_query(q); nothing; catch e; e; end
      @test err isa QueryBuildError
      msg = replace(sprint(showerror, err), r"\e\[[0-9;]*m" => "")
      # #932: the label is the projection the condition sits in, as for every projected correlation —
      # the column the user named — where it was a generic "Subquery(…) compared in a projection".
      @test occursin("correlated column n correlates on raceid", msg)
    end
    @testset "$backend: grouped on the correlated column" begin
      q = mod.Result.objects
      q.values("raceid", "grid", "n" => Case([When("grid" => _sq_best(mod), then = Count("resultid"))], default = 0))
      insp = inspect_query(q)
      @test occursin(r"CASE WHEN \"Tb\"\.\"grid\" = \(SELECT .+ GROUP BY 1, 2", _sq_flat(insp[:sql_text]))
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# #194 decides by EVALUATION PHASE, not by render entry point (#932)
# The guard needs one fact: is the outer column read before GROUP BY (per row) or after it (per
# group)? It used to answer a different question — which render entry point the subquery reached —
# and every disagreement became a patch. Now only clauses set the phase: WHERE, ON and a grouping
# aggregate's argument are per row; the SELECT list, HAVING and ORDER BY are per group; an expression
# that is itself a GROUP BY key is grouped whole. Every rendered OuterRef is recorded with that phase.
#
# One matrix, clause × spelling, each cell built or refused, so the next spelling of a subquery is a
# new ROW here rather than a new branch in the guard. The outer query groups by `chassis` and every
# subquery correlates on the UNGROUPED `raceid`, so a cell builds only when the phase makes it legal.
# ─────────────────────────────────────────────────────────────────────────────
using PormG.QueryBuilder: Exists
using PormG.Functions: Coalesce, Sum, Lag, WindowOver, Value
using PormG.QueryBuilder: SQLOrder, SQLField

@testset "#932: the #194 guard decides by evaluation phase" begin
  for (backend, mod) in _SQ_MODELS
    sq = () -> _sq_best(mod)
    ex = () -> Exists(mod.Result.objects.filter("raceid" => OuterRef("raceid"), "chassis" => "IN"))
    inq = () -> mod.Result.objects.filter("raceid" => OuterRef("raceid")).values("grid")
    # Condition spellings: what a `filter`, a `When` or an `on` takes.
    conds = (
      ("pair = Subquery", () -> "grid" => sq()),
      ("F(...) == Subquery", () -> F("grid") == sq()),
      ("pair = Coalesce(Subquery)", () -> "grid" => Coalesce(sq(), 0)),
      ("Q(Exists)", () -> Q(ex())),
    )
    # Value spellings: what a projection or the right of an alias filter takes.
    vals = (
      ("bare Subquery", sq),
      ("Coalesce(Subquery)", () -> Coalesce(sq(), 0)),
    )
    grouped = q -> q.values("chassis", "n" => Count("resultid"))
    cells = Tuple{String,Function,Symbol}[]
    for (cl, c) in conds
      # Before GROUP BY: legal on both engines.
      push!(cells, ("WHERE / $cl", q -> (grouped(q); q.filter(c())), :builds))
      push!(cells, ("inside Max(Case) / $cl",
                    q -> q.values("chassis", "m" => Max(Case([When(c(), then = 1)], default = 0))), :builds))   # item 1
      push!(cells, ("aggregate(Sum(Case)) / $cl",
                    q -> q.aggregate("m" => Sum(Case([When(c(), then = 1)], default = 0)), show_query = :dict), :builds))   # item 4
      # A non-aggregate `Case` is a GROUP BY key whole, subquery and all (item 3).
      push!(cells, ("projected Case, grouped / $cl",
                    q -> q.values("chassis", "n" => Count("resultid"),
                                  "lbl" => Case([When(c(), then = Value("a"))], default = Value("b"))), :builds))
      # After GROUP BY and not grouped: a mixed term, evaluated per group — refused.
      push!(cells, ("projected Case, mixed / $cl",
                    q -> q.values("chassis", "grid", "n" => Case([When(c(), then = Count("resultid"))], default = 0)),
                    :refused))
    end
    for (vl, v) in vals
      push!(cells, ("WHERE value / $vl", q -> (grouped(q); q.filter("grid" => v())), :builds))   # item 2
      push!(cells, ("HAVING value / $vl",
                    q -> (q.values("chassis", "best" => Max("grid")); q.filter("best__@gt" => v())), :refused))
      push!(cells, ("HAVING value inside Q / $vl",
                    q -> (q.values("chassis", "best" => Max("grid")); q.filter(Q("best__@gt" => v()))), :refused))
      push!(cells, ("inside a window / $vl",
                    q -> q.values("chassis", "n" => Count("resultid"),
                                  "w" => Lag(v(), over = WindowOver(order_by = ["chassis"]))), :refused))
    end
    # Projected values: a bare subquery is never grouped (it is one value per row), so it is checked.
    push!(cells, ("projected / bare Subquery", q -> q.values("chassis", "n" => Count("resultid"), "s" => sq()), :refused))
    push!(cells, ("projected / Exists", q -> q.values("chassis", "n" => Count("resultid"), "e" => ex()), :refused))
    # A wrapped one is grouped by position, so it is a GROUP BY key whole.
    push!(cells, ("projected, grouped / Coalesce(Subquery)",
                  q -> q.values("chassis", "n" => Count("resultid"), "s" => Coalesce(sq(), 0)), :builds))
    push!(cells, ("inside Max / Coalesce(Subquery)",
                  q -> q.values("chassis", "m" => Max(Coalesce(sq(), 0))), :builds))
    # ORDER BY: a term not projected is pushed into GROUP BY whole.
    push!(cells, ("ORDER BY / Coalesce(Subquery)",
                  q -> (grouped(q); q.order_by(SQLOrder(SQLField(Coalesce(sq(), 0), "o")))), :builds))
    # …but only while the grouping is real (review of #932). A `"*"` ahead of the projection expands
    # before the ordinals resolve, so `GROUP BY 3` names a model column, not `s`; and an ORDER BY term
    # holding an aggregate is no valid grouping key at all. Both stay checked.
    push!(cells, ("projected after a \"*\" / Coalesce(Subquery)",
                  q -> q.values("*", "n" => Count("resultid"), "s" => Coalesce(sq(), 0)), :refused))
    push!(cells, ("ORDER BY with an aggregate / Coalesce(Subquery)",
                  q -> (grouped(q); q.order_by(SQLOrder(SQLField(Max("grid") + Coalesce(sq(), 0), "o")))), :refused))
    push!(cells, ("ORDER BY reading an aggregate alias / Coalesce(Subquery)",
                  q -> (grouped(q); q.order_by(SQLOrder(SQLField(
                        Case([When("n__@gt" => 1, then = Coalesce(sq(), 0))], default = 0), "o")))), :refused))
    # ON is per row.
    push!(cells, ("ON / pair = Subquery",
                  q -> (q.on("driverid", "number" => sq()); q.values("driverid__code", "n" => Count("resultid"))), :builds))
    # `__@in` in a projected `When` is refused by the #798 guard first; in WHERE it builds.
    push!(cells, ("WHERE / grid__@in subquery", q -> (grouped(q); q.filter("grid__@in" => inq())), :builds))

    @testset "$backend: $label" for (label, setup, want) in cells
      err = try
        q = mod.Result.objects
        r = setup(q)
        r isa Dict || inspect_query(q)
        nothing
      catch e
        e
      end
      if want === :builds
        @test err === nothing
      else
        @test err isa QueryBuildError
        @test occursin("grouped-correlation guard (#194)", sprint(showerror, err))
      end
    end
  end
end

# The legal shapes the guard used to refuse (#932 items 1–4, and the two GROUP BY keys), rendered:
# the subquery sits where the phase says it does — inside the aggregate call, in WHERE, inside a
# GROUP BY key.
@testset "#932: the newly built shapes render the subquery where the phase says" begin
  for (backend, mod) in _SQ_MODELS
    sq = () -> _sq_best(mod)
    sub = "\\(SELECT MIN\\(\"R1\"\\.\"grid\"\\) as \"m\" FROM \"result\" as \"R1\" WHERE \"R1\"\\.\"raceid\" = \"Tb\"\\.\"raceid\""
    @testset "$backend: item 1 — inside the aggregate call" begin
      q = mod.Result.objects
      q.values("chassis", "m" => Max(Case([When("grid" => sq(), then = 1)], default = 0)))
      @test occursin(Regex("MAX\\(CASE WHEN \"Tb\"\\.\"grid\" = $sub.+ GROUP BY 1\\s*\$"), _sq_flat(inspect_query(q)[:sql_text]))
    end
    @testset "$backend: item 2 — Coalesce(Subquery) in WHERE" begin
      q = mod.Result.objects
      q.values("chassis", "n" => Count("resultid"))
      q.filter("grid" => Coalesce(sq(), 0))
      @test occursin(Regex("WHERE \"Tb\"\\.\"grid\" = COALESCE\\($sub.+ GROUP BY 1\\s*\$"), _sq_flat(inspect_query(q)[:sql_text]))
    end
    @testset "$backend: item 3 — a non-aggregate Case is grouped by position" begin
      q = mod.Result.objects
      q.values("chassis", "n" => Count("resultid"), "lbl" => Case([When("grid" => sq(), then = Value("a"))], default = Value("b")))
      @test occursin(Regex("CASE WHEN \"Tb\"\\.\"grid\" = $sub.+ as \"lbl\" FROM .+ GROUP BY 1, 3\\s*\$"), _sq_flat(inspect_query(q)[:sql_text]))
    end
    @testset "$backend: item 4 — aggregate() over a conditional sum" begin
      q = mod.Result.objects
      res = q.aggregate("m" => Sum(Case([When("grid" => sq(), then = 1)], default = 0)), show_query = :dict)
      sql = _sq_flat(res[:sql_text])
      @test occursin(Regex("^SELECT SUM\\(CASE WHEN \"Tb\"\\.\"grid\" = $sub"), sql)
      @test !occursin("GROUP BY", sql)
    end
    @testset "$backend: an ORDER BY term is grouped whole" begin
      q = mod.Result.objects
      q.values("chassis", "n" => Count("resultid"))
      q.order_by(SQLOrder(SQLField(Coalesce(sq(), 0), "o")))
      @test occursin(Regex("GROUP BY 1, COALESCE\\($sub.+ ORDER BY COALESCE\\($sub"), _sq_flat(inspect_query(q)[:sql_text]))
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# A Subquery / Exists nested inside another subquery builds in every position (#938)
# The #92 guard refused a nested subquery only when it reached the PROJECTED render entry point, so
# `Coalesce(Subquery(…))` in a nested WHERE was refused while the bare `Subquery(…)` built. Neither
# can mis-correlate: an `OuterRef` binds the IMMEDIATELY enclosing query (Django's rule) and each
# level has its own alias. Three levels below: the outer driver (`Tb`), a correlated result count
# (`R1`, bound to `"Tb"."driverid"`), and inside it the race's best grid (`R2`, bound to
# `"R1"."raceid"` — never to `"Tb"`). Every position is asked on both engines, with a value bound at
# each level, so the SQLite vector is checked against PostgreSQL's text order (#432's differential).
# ─────────────────────────────────────────────────────────────────────────────
@testset "#938: a subquery nested inside another subquery builds in every position" begin
  # The race's best grid among chassis "IN": correlated to whichever result row encloses it.
  best(mod) = Subquery(mod.Result.objects.filter("raceid" => OuterRef("raceid"), "chassis" => "IN").values("m" => Min("grid")))
  same_race(mod) = mod.Result.objects.filter("raceid" => OuterRef("raceid"), "chassis" => "IN")
  count_rows(q) = q.values("n" => Count("resultid"))
  # (position, how the middle query uses the innermost one, text order on PostgreSQL / on SQLite)
  positions = (
    ("filter pair", (q, m) -> count_rows(q.filter("grid" => best(m))), Any["MID", "IN", "OUT"]),
    ("Coalesce in WHERE", (q, m) -> count_rows(q.filter("grid" => Coalesce(best(m), 0))), Any["MID", "IN", 0, "OUT"]),
    # SQLite emulates GREATEST as MAX(COALESCE(a, b), COALESCE(b, a)), so each operand renders twice.
    ("Greatest in WHERE", (q, m) -> count_rows(q.filter("grid" => Greatest(best(m), 0))),
      (postgres = Any["MID", "IN", 0, "OUT"], sqlite = Any["MID", "IN", 0, 0, "IN", "OUT"])),
    ("Q", (q, m) -> count_rows(q.filter(Q("grid" => best(m)))), Any["MID", "IN", "OUT"]),
    ("Exists in WHERE", (q, m) -> count_rows(q.filter(Q(Exists(same_race(m))))), Any["MID", "IN", "OUT"]),
    ("__@in", (q, m) -> count_rows(q.filter("resultid__@in" => same_race(m).values("resultid"))), Any["MID", "IN", "OUT"]),
    ("When condition", (q, m) -> q.values("n" => Sum(Case([When("grid" => best(m), then = 1)], default = 0))),
      Any["IN", 1, 0, "MID", "OUT"]),
    ("When then", (q, m) -> q.values("n" => Sum(Case([When("grid__@gt" => 0, then = best(m))], default = 0))),
      Any[0, "IN", 0, "MID", "OUT"]),
    ("projected Subquery", (q, m) -> q.values("n" => Max(Coalesce(best(m), 0))), Any["IN", 0, "MID", "OUT"]),
    ("projected Exists", (q, m) -> q.values("n" => Exists(same_race(m))), Any["IN", "MID", "OUT"]),
    # A join condition: the ON value renders (and binds) ahead of the middle query's WHERE. The WHERE
    # term on the joined driver is what materializes the join `on()` decorates.
    ("on() condition", (q, m) -> count_rows(q.on("driverid", "code" => Subquery(same_race(m).values("c" => Min("chassis")))).
                                              filter("driverid__number__@gte" => 0)), Any["IN", "MID", 0, "OUT"]),
  )
  for (backend, mod) in _SQ_MODELS
    @testset "$backend: $label" for (label, use, order) in positions
      middle = mod.Result.objects
      middle.filter("driverid" => OuterRef("driverid"), "chassis" => "MID")
      use(middle, mod)
      q = mod.Driver.objects
      q.filter("code" => "OUT")
      q.values("driverid", "x" => Subquery(middle))
      # `projected Exists` is a non-aggregate column with no LIMIT: its soft warning is not under test.
      insp = Logging.with_logger(Logging.NullLogger()) do
        inspect_query(q)
      end
      sql = _sq_flat(insp[:sql_text])
      # Each OuterRef binds the query immediately around it: the innermost to the middle, the middle
      # to the outer driver. No reference skips a level.
      @test occursin("\"R2\".\"raceid\" = \"R1\".\"raceid\"", sql)
      @test occursin("\"R1\".\"driverid\" = \"Tb\".\"driverid\"", sql)
      @test !occursin("\"R2\".\"raceid\" = \"Tb\"", sql)
      assert_marker_count(insp, backend)
      @test _sq_text_order(insp, backend) == (order isa NamedTuple ? order[backend] : order)
    end
  end

  # The same WHERE-side positions with the middle query held by an `Exists(...)` and by a
  # `"col__@in"` subquery instead of a `Subquery(...)`. The oracle here is the differential itself:
  # SQLite's vector must equal PostgreSQL's text order (GREATEST's SQLite text differs, so it is left
  # to the marker count).
  containers = (
    ("Exists", (q, middle) -> q.filter(Q(Exists(middle)))),
    ("__@in", (q, middle) -> q.filter("driverid__@in" => middle.values("driverid"))),
  )
  where_positions = [(label, use) for (label, use, _) in positions if !occursin(r"When|projected", label)]
  @testset "inside $clabel: $label" for (clabel, hold) in containers, (label, use) in where_positions
    insp = Dict{Symbol, Any}()
    for (backend, mod) in _SQ_MODELS
      middle = mod.Result.objects
      middle.filter("driverid" => OuterRef("driverid"), "chassis" => "MID")
      # The position's own projection is dropped: these containers need no single scalar column.
      use(middle, mod)
      middle.object.values = empty(middle.object.values)
      q = mod.Driver.objects
      q.filter("code" => "OUT")
      hold(q, middle)
      q.values("driverid")
      insp[backend] = inspect_query(q)
      sql = _sq_flat(insp[backend][:sql_text])
      @test occursin("\"R2\".\"raceid\" = \"R1\".\"raceid\"", sql)
      @test occursin("\"R1\".\"driverid\" = \"Tb\".\"driverid\"", sql)
      assert_marker_count(insp[backend], backend)
    end
    occursin("Greatest", label) ||
      @test insp[:sqlite][:parameters] == _sq_text_order(insp[:postgres], :postgres)
  end
end

# Django's two-levels-up spelling is named in the docs, so it raises a message rather than a raw
# `MethodError` (review of #938): an `OuterRef` binds the immediately enclosing query only.
@testset "#938: OuterRef(OuterRef(…)) is refused with a message" begin
  err = try; OuterRef(OuterRef("driverid")); nothing; catch e; e; end
  @test err isa QueryBuildError
  @test occursin("immediately enclosing query", sprint(showerror, err))
end
