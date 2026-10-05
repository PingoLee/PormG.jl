# ==============================================================================
# UNIT TESTS: what a right-side F names in a join condition (#958)
#
# In `on(path, …)` and `cjoin(filters = …)` the KEY / left side of a condition is prefixed with the join
# path, so it names the joined row. The right side was prefixed in some spellings and not in others: a
# bare pair `"number" => F("number")` named the base row, while the same pair inside `Q(...)`/`Qor(...)`,
# `OP(...)` and `F("number") == F("number")` all named the JOINED row — `"Tb_1"."number" =
# "Tb_1"."number"`, true on every row, so the predicate was silently dropped.
#
# Decision (#958): a right-side `F` names the BASE row in every spelling, at every hop depth. That is
# what the bare pair already did, what Django's `FilteredRelation` condition does, and the only reading
# under which a join condition can compare the two tables. The joined side stays reachable through its
# path (`F("driverid__number")`).
#
# `Result` and `Driver` both carry `number`, as in the F1 schema, so a wrong side is visible in the SQL.
# DB-free: mock connections, SQL inspected through `inspect_query`.
# ==============================================================================

using Test
using PormG
using PormG.QueryBuilder: inspect_query, F, Q, Qor, OP

struct JoinRhsFMockPostgres <: PormG.PormGPostgres end
struct JoinRhsFMockSQLite <: PormG.PormGSQLite end
PormG.backend_sqlite_version(::JoinRhsFMockSQLite) = 3045000

PormG.config["join_rhs_f_pg"] = PormG.Configuration.Settings(
  connections = JoinRhsFMockPostgres(), change_data = true, db_def_folder = "join_rhs_f_pg")
PormG.config["join_rhs_f_sl"] = PormG.Configuration.Settings(
  connections = JoinRhsFMockSQLite(), change_data = true, db_def_folder = "join_rhs_f_sl")

module JoinRhsFPGModels
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
  number = Models.IntegerField(),
  grid = Models.IntegerField(),
  driverid = Models.ForeignKey(Driver, on_delete = "CASCADE", related_name = "results"),
)
PormG.Models.set_models(@__MODULE__, "join_rhs_f_pg")
end

module JoinRhsFSLModels
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
  number = Models.IntegerField(),
  grid = Models.IntegerField(),
  driverid = Models.ForeignKey(Driver, on_delete = "CASCADE", related_name = "results"),
)
PormG.Models.set_models(@__MODULE__, "join_rhs_f_sl")
end

const _RHS_F_MODELS = ((:postgres, JoinRhsFPGModels), (:sqlite, JoinRhsFSLModels))

# Whitespace-flattened SQL, so a fragment can span the line breaks the renderer inserts.
_rhs_f_sql(q) = replace(inspect_query(q)[:sql_text], r"\s+" => " ")

# The tautology's shape: one alias compared with itself on `number`.
const _RHS_F_SELF_COMPARISON = r"\"(Tb_\d+)\"\.\"number\" = \"\1\"\.\"number\""

# ─────────────────────────────────────────────────────────────────────────────
# Join conditions: every spelling of `number = F("number")` names the same two rows
# Five spellings × three routes (first-hop `on()`, deep-hop `on()`, `cjoin(filters = …)`), each expected
# to render `<joined>."number" = "Tb"."number"` and never the self-comparison. Before #958 the `Q`, `Qor`,
# `OP` and `F == F` rows rendered the tautology on every route.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#958: a right-side F names the base row in every spelling" begin
  spellings = (
    ("bare pair", "number" => F("number")),
    ("Q", Q("number" => F("number"))),
    # A second branch keeps the Qor from collapsing to its single element; `number` because the deep
    # hop's target is a `Result`, which has no `code`.
    ("Qor", Qor("number" => F("number"), "number" => 0)),
    ("OP", OP("number", F("number"))),
    ("F == F", F("number") == F("number")),
  )
  # Each route: how to attach the condition, and the alias the joined row renders under.
  routes = (
    ("on(), first hop", "Tb_1",
     (q, cond) -> (q.on("driverid", cond); q.values("resultid", "driverid__code"))),
    # `driverid__results` hops Result → Driver → Result; the condition targets the second Result.
    ("on(), deep hop", "Tb_2",
     (q, cond) -> (q.on("driverid__results", cond); q.values("resultid", "driverid__results__grid"))),
    ("cjoin(filters = …)", "Tb_1",
     (q, cond) -> (q.cjoin("driverid" => "Driver", warn = false, filters = [cond]);
                   q.values("resultid", "driverid__code"))),
  )
  for (backend, mod) in _RHS_F_MODELS
    @testset "$backend: $route_label, $label" for (route_label, joined, attach) in routes, (label, cond) in spellings
      q = mod.Result.objects
      attach(q, cond)
      sql = _rhs_f_sql(q)
      # Left side on the joined row, right side on the base row.
      @test occursin("\"$(joined)\".\"number\" = \"Tb\".\"number\"", sql)
      # ...and never the always-true self-comparison.
      @test !occursin(_RHS_F_SELF_COMPARISON, sql)
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# Join conditions: expressions on either side of the comparison
# An expression on the RIGHT (`F("number") + 1`) is still the right side — base row — inside `Q`. An
# expression on the LEFT (`F("number") + F("number")`) is all left side — joined row — and used to throw
# "Invalid cjoin filter field ''", because the placeholder column of the nested comparison was prefixed.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#958: expressions keep their side" begin
  for (backend, mod) in _RHS_F_MODELS
    @testset "$backend: right-side arithmetic inside Q" begin
      q = mod.Result.objects
      q.on("driverid", Q("number__@gt" => F("number") + 1))
      q.values("resultid", "driverid__code")
      sql = _rhs_f_sql(q)
      @test occursin(r"\"Tb_1\"\.\"number\" > \(\"Tb\"\.\"number\" \+ ", sql)
    end
    @testset "$backend: left-side arithmetic" begin
      q = mod.Result.objects
      q.on("driverid", (F("number") + F("number")) > F("number"))
      q.values("resultid", "driverid__code")
      sql = _rhs_f_sql(q)
      # Both arithmetic operands are the joined row; only the comparison's right side is the base row.
      @test occursin("(\"Tb_1\".\"number\" + \"Tb_1\".\"number\") > \"Tb\".\"number\"", sql)
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# Join conditions: a path-qualified right-side F reaches a joined row
# The base-row rule does not lose the other tables: a right-side `F` with a path resolves from the base
# model like any `F`. On the deep hop `driverid__results`, `F("driverid__number")` names the hop's left
# table (the driver), inside `Q` exactly as bare.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#958: a path-qualified right-side F" begin
  for (backend, mod) in _RHS_F_MODELS
    @testset "$backend: $label" for (label, cond) in (
        ("bare pair", "grid" => F("driverid__number")),
        ("Q", Q("grid" => F("driverid__number"))),
      )
      q = mod.Result.objects
      q.on("driverid__results", cond)
      q.values("resultid", "driverid__results__grid")
      sql = _rhs_f_sql(q)
      @test occursin("\"Tb_2\".\"grid\" = \"Tb_1\".\"number\"", sql)
    end
  end
end
