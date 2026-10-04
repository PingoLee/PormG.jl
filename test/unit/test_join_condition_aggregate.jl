# ==============================================================================
# UNIT TESTS: an aggregate or window function in a join's ON clause is refused (#917)
#
# A join's ON conditions render through their own loop in `build_row_join_sql_text`, which never met
# the `filter()` refusals (#537, #895). So `cjoin_on(…; on = [Count("resultid") > 1])` rendered
# `ON … AND (COUNT("Tb"."resultid") > ?)`, and `on(…)` / `cjoin(…; filters = …)` did the same on a
# foreign-key join. Both engines reject that at execution. It is now a `QueryBuildError` at build
# time, worded for a join rather than for WHERE: the WHERE refusals advise an alias filter (HAVING),
# which cannot help an ON clause.
#
# DB-free: mock connections, SQL inspected through `inspect_query`. Every testset runs on both mock
# backends, because the defect rendered the same on both.
# ==============================================================================

using Test
using PormG
using PormG.QueryBuilder: inspect_query, F, Q, Qor, OP, Joined, Exists, OuterRef
using PormG.Functions: Count, Max, Lower, Rank, WindowOver
using PormG: QueryBuildError

struct JoinAggMockPostgres <: PormG.PormGPostgres end
struct JoinAggMockSQLite <: PormG.PormGSQLite end
# The window cases ask the backend for its version; answer like the other mocks.
PormG.backend_sqlite_version(::JoinAggMockSQLite) = 3045000

PormG.config["join_agg_pg"] = PormG.Configuration.Settings(
  connections = JoinAggMockPostgres(), change_data = true, db_def_folder = "join_agg_pg")
PormG.config["join_agg_sl"] = PormG.Configuration.Settings(
  connections = JoinAggMockSQLite(), change_data = true, db_def_folder = "join_agg_sl")

# Identical F1-flavored models under each backend: a result with a ForeignKey to its driver, so the
# three join spellings — `cjoin_on`, `on()` and a keyed `cjoin` — all have something to join.
module JoinAggPGModels
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
  driverid = Models.ForeignKey(Driver, on_delete = "CASCADE", related_name = "results"),
)
PormG.Models.set_models(@__MODULE__, "join_agg_pg")
end

module JoinAggSLModels
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
  driverid = Models.ForeignKey(Driver, on_delete = "CASCADE", related_name = "results"),
)
PormG.Models.set_models(@__MODULE__, "join_agg_sl")
end

const _JOIN_AGG_MODELS = ((:postgres, JoinAggPGModels), (:sqlite, JoinAggSLModels))

# Build the query `setup` declares over `Result`. Returns the exception the build raised, or the
# rendered SQL when it built. Built through `inspect_query`, which is where the joins render — the
# refusal must come from the build, never from the driver.
function _join_agg_build(mod, setup)
  q = mod.Result.objects
  try
    setup(q, mod)
    return inspect_query(q)[:sql_text]
  catch e
    return e
  end
end

_ja_rank() = Rank(over = WindowOver(order_by = ["grid"]))

# A `cjoin_on` self-join correlated on the race, with `term` as its second ON predicate. The
# correlation is legal on its own, so whatever refuses is `term`.
_ja_self_join(term) = (q, mod) -> (q.cjoin_on(mod.Result; alias = "r2",
                                              on = [Joined("r2", "raceid") == F("raceid"), term]);
                                   q.values("resultid"))

# ─────────────────────────────────────────────────────────────────────────────
# cjoin_on: an aggregate in an ON predicate is refused
# Each spelling rendered `ON … AND (COUNT(…) …)` or `= MAX(…)`: the four rows of the issue's table
# that are aggregates, the right-hand side of a pair, and the same predicate wrapped in `Q`/`Qor`.
# The message names the join the caller declared and the CTE route, not the WHERE advice.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#917: cjoin_on refuses an aggregate in an ON predicate" begin
  cases = (
    ("bare aggregate > number", () -> Count("resultid") > 1),
    ("arithmetic over an aggregate", () -> (Count("resultid") + 0) > 1),
    ("OP over an aggregate", () -> OP(Count("resultid"), ">", 1)),
    ("aggregate on the right of a pair", () -> "grid" => Max("grid")),
    ("inside Q", () -> Q(OP(Count("resultid"), ">", 1))),
    ("inside a mixed Qor", () -> Qor(Count("resultid") > 1, "grid" => 1)),
  )
  for (backend, mod) in _JOIN_AGG_MODELS
    @testset "$backend: $label" for (label, term) in cases
      err = _join_agg_build(mod, _ja_self_join(term()))
      @test err isa QueryBuildError
      msg = sprint(showerror, err)
      # Which join, what is wrong, and where the predicate can go instead.
      @test occursin("cjoin_on(alias = \"r2\")", msg)
      @test occursin("an aggregate cannot appear in a join's ON clause", msg)
      @test occursin("Compute it in a CTE and join on its column", msg)
      # Not the WHERE wording, whose HAVING advice would mislead here.
      @test !occursin("WHERE predicate", msg)
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# cjoin_on: a window function in an ON predicate is refused with the window wording
# `(Rank() + 0) > 1` rendered `ON … AND ((RANK() OVER (…) + ?) > ?)`. A window is not an aggregate
# (`_is_agg` is false for one), so it needs its own check, and it runs first: a window over an
# aggregate would otherwise be reported as an aggregate.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#917: cjoin_on refuses a window function in an ON predicate" begin
  cases = (
    ("arithmetic over a window", () -> (_ja_rank() + 0) > 1),
    ("OP over a window", () -> OP(_ja_rank(), ">", 1)),
    ("window on the right of a pair", () -> "grid" => _ja_rank()),
    ("window over an aggregate", () -> OP(Rank(over = WindowOver(partition_by = [Count("resultid")])), ">", 1)),
  )
  for (backend, mod) in _JOIN_AGG_MODELS
    @testset "$backend: $label" for (label, term) in cases
      err = _join_agg_build(mod, _ja_self_join(term()))
      @test err isa QueryBuildError
      msg = sprint(showerror, err)
      @test occursin("cjoin_on(alias = \"r2\")", msg)
      @test occursin("a window function cannot appear in a join's ON clause", msg)
      @test occursin("Compute it in a CTE and join on its column", msg)
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# cjoin_on: a predicate keyed on an aggregate or window projection alias is refused
# A plain key that names a projection alias renders the projected expression, so `"n" => 1` over
# `"n" => Count("resultid")` rendered `ON … AND COUNT("Tb"."resultid") = ?`. The pair's own key is
# what reads the alias, so the guard asks the whole pair, not only its two operands. `on()` and a
# keyed `cjoin` prefix the key onto the joined model, so only `cjoin_on` can spell this.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#917: cjoin_on refuses a predicate keyed on an aggregate or window alias" begin
  agg_alias = q -> q.values("raceid", "n" => Count("resultid"))
  win_alias = q -> q.values("raceid", "r" => _ja_rank())
  on_term(q, mod, term) = q.cjoin_on(mod.Result; alias = "r2",
                                     on = [Joined("r2", "raceid") == F("raceid"), term])
  cases = (
    ("aggregate alias", agg_alias, () -> "n" => 1, "an aggregate"),
    ("aggregate alias with a lookup", agg_alias, () -> "n__@gt" => 1, "an aggregate"),
    ("aggregate alias inside Q", agg_alias, () -> Q("n" => 1), "an aggregate"),
    ("aggregate alias inside a mixed Qor", agg_alias, () -> Qor("n" => 1, "grid" => 2), "an aggregate"),
    ("window alias", win_alias, () -> "r" => 1, "a window function"),
  )
  for (backend, mod) in _JOIN_AGG_MODELS
    @testset "$backend: $label" for (label, project, term, kind) in cases
      err = _join_agg_build(mod, (q, m) -> (project(q); on_term(q, m, term())))
      @test err isa QueryBuildError
      msg = sprint(showerror, err)
      @test occursin("cjoin_on(alias = \"r2\")", msg)
      @test occursin("$kind cannot appear in a join's ON clause", msg)
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# on() and a keyed cjoin: the same refusal on a foreign-key join
# Their predicates ride a `ModelJoin`'s `on_conditions` into the same render loop, and rendered
# `ON "Tb"."driverid" = "Tb_1"."driverid" AND COUNT("Tb"."grid") > ?`. Projecting
# `driverid__code` is what builds the join `on()` decorates.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#917: on() and cjoin(filters = …) refuse an aggregate or window" begin
  cases = (
    ("on(): OP over an aggregate", (q, mod) -> q.on("driverid", OP(Count("grid"), ">", 1)), "an aggregate"),
    ("on(): aggregate on the right of a pair", (q, mod) -> q.on("driverid", "number" => Max("grid")), "an aggregate"),
    ("on(): inside Q", (q, mod) -> q.on("driverid", Q(OP(Count("grid"), ">", 1))), "an aggregate"),
    ("on(): OP over a window", (q, mod) -> q.on("driverid", OP(_ja_rank(), ">", 1)), "a window function"),
    ("cjoin: OP over an aggregate",
     (q, mod) -> q.cjoin("driverid" => "Driver", warn = false, filters = [OP(Count("grid"), ">", 1)]), "an aggregate"),
    ("cjoin: aggregate on the right of a pair",
     (q, mod) -> q.cjoin("driverid" => "Driver", warn = false, filters = ["number" => Max("grid")]), "an aggregate"),
  )
  for (backend, mod) in _JOIN_AGG_MODELS
    @testset "$backend: $label" for (label, setup, kind) in cases
      err = _join_agg_build(mod, (q, m) -> (setup(q, m); q.values("resultid", "driverid__code")))
      @test err isa QueryBuildError
      msg = sprint(showerror, err)
      # A ModelJoin keeps the table it reaches, not the path the caller wrote, so that is named.
      @test occursin("on the join to \"driver\"", msg)
      @test occursin("$kind cannot appear in a join's ON clause", msg)
      @test occursin("Compute it in a CTE and join on its column", msg)
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# Legal ON predicates still render
# The guard runs on every ON condition, so a false positive would break ordinary joins. A scalar
# function, row arithmetic, an `@in` subquery and an `Exists(…)` whose inner query aggregates (its
# aggregate belongs to the inner statement), and a plain `on()` value — all keep rendering.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#917: legal ON predicates are not refused" begin
  cases = (
    ("scalar function", _ja_self_join(Lower("resultid") == "x"), "AND (LOWER(\"Tb\".\"resultid\") = "),
    ("row arithmetic", _ja_self_join(Joined("r2", "grid") == F("grid") + 1), "(\"r2\".\"grid\" = (\"Tb\".\"grid\" + "),
    ("@in over an aggregating subquery",
     (q, mod) -> _ja_self_join("grid__@in" => mod.Result.objects.values("m" => Max("grid")))(q, mod),
     "AND \"Tb\".\"grid\" IN (SELECT"),
    ("Exists over an aggregating subquery",
     (q, mod) -> _ja_self_join(Exists(mod.Result.objects.filter("raceid" => OuterRef("raceid")).
                                        values("raceid", "n" => Count("resultid"))))(q, mod),
     "AND EXISTS (SELECT 1"),
    ("on() value", (q, mod) -> (q.on("driverid", "code" => "SEN"); q.values("resultid", "driverid__code")),
     "AND \"Tb_1\".\"code\" = "),
  )
  for (backend, mod) in _JOIN_AGG_MODELS
    @testset "$backend: $label" for (label, setup, fragment) in cases
      sql = _join_agg_build(mod, setup)
      @test sql isa String
      sql isa String && @test occursin(fragment, sql)
    end
  end
end
