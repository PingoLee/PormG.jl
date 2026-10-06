# ==============================================================================
# UNIT TESTS: every column on the left side of a join condition names the joined row (#961)
#
# In `on(path, …)` and `cjoin(filters = …)` a condition's key / left side is prefixed with the join path,
# so it names the joined row (#958 fixed the RIGHT side). Three left-side shapes were only half
# prefixed and silently named the BASE row instead:
#
#   1. a key inside `Q(...)`/`Qor(...)` when `values()` selects a base column of the same name — the
#      `OperObject` carried its old `_as` ("number"), which the renderer resolved against the `values()`
#      aliases, where the base row's `number` won;
#   2. a key inside `Q(...)` that carries a transform (`"dob__@year"`) — its column is a function
#      object, and only a `String` column was rewritten;
#   3. a function or a bare column string on the left of an `F` comparison (`Abs(F("number")) > 0`,
#      `F("number") + "number"`) — the `FExpression` arm recursed into nested `FExpression`s only; and
#      the `then`/`else` of a `Case`/`When` there, which live in `kwargs`.
#
# The oracle is a spelling that was already correct before #961: the same condition with the join path
# written out (`Q("driverid__number" => 5)`). Its key needs no rewriting and its `_as` already carries
# the path, so it names the joined row by construction. Each test asserts the auto-prefixed spelling
# renders byte-identical SQL to it, and checks the alias directly so a shared regression in both cannot
# pass silently.
#
# `Result` and `Driver` both carry `number` and `dob`, so a predicate on the wrong row renders instead of
# throwing. DB-free: mock connections, SQL inspected through `inspect_query`.
# ==============================================================================

using Test
using PormG
using PormG.QueryBuilder: inspect_query, F, Q, Qor, Abs, Case, When

struct JoinLhsMockPostgres <: PormG.PormGPostgres end
struct JoinLhsMockSQLite <: PormG.PormGSQLite end
PormG.backend_sqlite_version(::JoinLhsMockSQLite) = 3045000

PormG.config["join_lhs_pg"] = PormG.Configuration.Settings(
  connections = JoinLhsMockPostgres(), change_data = true, db_def_folder = "join_lhs_pg")
PormG.config["join_lhs_sl"] = PormG.Configuration.Settings(
  connections = JoinLhsMockSQLite(), change_data = true, db_def_folder = "join_lhs_sl")

module JoinLhsPGModels
import PormG
import PormG.Models
Driver = Models.Model("driver",
  driverid = Models.IDField(),
  code = Models.CharField(),
  number = Models.IntegerField(),
  dob = Models.DateField(),
)
Result = Models.Model("result",
  resultid = Models.IDField(),
  number = Models.IntegerField(),
  grid = Models.IntegerField(),
  dob = Models.DateField(),
  driverid = Models.ForeignKey(Driver, on_delete = "CASCADE", related_name = "results"),
)
PormG.Models.set_models(@__MODULE__, "join_lhs_pg")
end

module JoinLhsSLModels
import PormG
import PormG.Models
Driver = Models.Model("driver",
  driverid = Models.IDField(),
  code = Models.CharField(),
  number = Models.IntegerField(),
  dob = Models.DateField(),
)
Result = Models.Model("result",
  resultid = Models.IDField(),
  number = Models.IntegerField(),
  grid = Models.IntegerField(),
  dob = Models.DateField(),
  driverid = Models.ForeignKey(Driver, on_delete = "CASCADE", related_name = "results"),
)
PormG.Models.set_models(@__MODULE__, "join_lhs_sl")
end

const _LHS_MODELS = ((:postgres, JoinLhsPGModels), (:sqlite, JoinLhsSLModels))

# Whitespace-flattened SQL, so a fragment can span the line breaks the renderer inserts.
_lhs_sql(q) = replace(inspect_query(q)[:sql_text], r"\s+" => " ")

# Each route: the join path, the alias the joined row renders under, and how to attach a condition.
# `values()` always selects the base `number`, the column whose alias stole the predicate in case 1;
# the deep hop `driverid__results` goes Result → Driver → Result and targets the second Result.
const _LHS_ROUTES = (
  ("on(), first hop", "driverid", "Tb_1",
   (q, cond) -> (q.on("driverid", cond); q.values("resultid", "number", "driverid__code"))),
  ("on(), deep hop", "driverid__results", "Tb_2",
   (q, cond) -> (q.on("driverid__results", cond); q.values("resultid", "number", "driverid__results__grid"))),
  ("cjoin(filters = …)", "driverid", "Tb_1",
   (q, cond) -> (q.cjoin("driverid" => "Driver", warn = false, filters = [cond]);
                 q.values("resultid", "number", "driverid__code"))),
)

# Render `cond(prefix)` on `route` twice: with the bare spelling (`prefix = ""`) and with the join path
# written out (the oracle). Returns both SQL strings.
function _lhs_pair(mod, attach, path, cond)
  q_bare = mod.Result.objects
  attach(q_bare, cond(""))
  q_oracle = mod.Result.objects
  attach(q_oracle, cond(path * "__"))
  return _lhs_sql(q_bare), _lhs_sql(q_oracle)
end

# ─────────────────────────────────────────────────────────────────────────────
# Join conditions: a key inside Q/Qor is not claimed by a selected base column
# `values()` selects the base `number`; the condition's `number` must still be the joined row's. Before
# #961 the Q/Qor spellings rendered `"Tb"."number" = $1` here, while the bare pair rendered the joined
# alias, so the predicate silently moved from the joined row to the base row.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#961: a Q/Qor key names the joined row whatever values() selects" begin
  spellings = (
    ("Q", p -> Q("$(p)number" => 5)),
    # A second branch keeps the Qor from collapsing to its single element.
    ("Qor", p -> Qor("$(p)number" => 5, "$(p)number" => 6)),
  )
  for (backend, mod) in _LHS_MODELS
    @testset "$backend: $route_label, $label" for (route_label, path, joined, attach) in _LHS_ROUTES, (label, cond) in spellings
      sql, oracle = _lhs_pair(mod, attach, path, cond)
      # Same SQL as the explicitly prefixed key...
      @test sql == oracle
      # ...which compares the joined row's `number`, never the base row's.
      @test occursin("\"$(joined)\".\"number\" = ", sql)
      @test !occursin("\"Tb\".\"number\" = ", sql)
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# Join conditions: a transform key inside Q/Qor is prefixed
# A transform turns the key's column into a function object (`EXTRACT(dob)`), which the old `String`-only
# rewrite let through onto the base row — here the base `result` also has `dob`, so it rendered instead
# of throwing. `@yyyy_q` is the composite transform (Concat over Cast/Extract/Case-When): every column
# inside it is the joined row's, and its `"-Q"` separator literal must come through untouched.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#961: a transform key inside Q/Qor names the joined row" begin
  spellings = (
    ("Q, @year", p -> Q("$(p)dob__@year" => 1990)),
    ("Qor, @year", p -> Qor("$(p)dob__@year" => 1990, "$(p)number" => 5)),
    ("Q, @yyyy_q", p -> Q("$(p)dob__@yyyy_q" => "1990-Q1")),
    # `@in` keeps the `@yyyy_mm` transform from being rewritten into a date range, so its `ToChar`
    # format — held in `kwargs`, which the walk must never descend — reaches the SQL.
    ("Q, @yyyy_mm__@in", p -> Q("$(p)dob__@yyyy_mm__@in" => ["1990-05", "1990-06"])),
  )
  for (backend, mod) in _LHS_MODELS
    @testset "$backend: $route_label, $label" for (route_label, path, joined, attach) in _LHS_ROUTES, (label, cond) in spellings
      sql, oracle = _lhs_pair(mod, attach, path, cond)
      @test sql == oracle
      # Every reference to `dob` is the joined row's.
      @test occursin("\"$(joined)\".\"dob\"", sql)
      @test !occursin("\"Tb\".\"dob\"", sql)
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# Join conditions: functions and column operands on the left of an F comparison
# The whole left side of `lhs > rhs` names the joined row: a function as the left side, a function as an
# arithmetic operand, and a bare column string as an arithmetic operand. The comparison's right side
# still names the base row (#958) — the last case pins that the walk did not spread across the `>`.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#961: every column on the left of an F comparison names the joined row" begin
  spellings = (
    ("function as the left side", p -> Abs(F("$(p)number")) > 0),
    ("function as an arithmetic operand", p -> (F("$(p)number") + Abs(F("$(p)number"))) > 0),
    ("column string as an arithmetic operand", p -> (F("$(p)number") + "$(p)number") > 0),
    # `Case`/`When` keep `then`/`else` in `kwargs`; both are part of the left side too.
    ("Case/When then= and default=",
     p -> Case(When("$(p)number__@gt" => 5, then = F("$(p)number")), default = F("$(p)number")) > 1),
  )
  for (backend, mod) in _LHS_MODELS
    @testset "$backend: $route_label, $label" for (route_label, path, joined, attach) in _LHS_ROUTES, (label, cond) in spellings
      sql, oracle = _lhs_pair(mod, attach, path, cond)
      @test sql == oracle
      @test occursin("\"$(joined)\".\"number\"", sql)
      # The base `number` appears only in the SELECT list, never inside the ON clause.
      on_clause = split(sql, " ON ")[end]
      @test !occursin("\"Tb\".\"number\"", on_clause)
    end
  end

  for (backend, mod) in _LHS_MODELS
    @testset "$backend: the right side keeps naming the base row" begin
      q = mod.Result.objects
      q.on("driverid", Abs(F("number")) > F("number"))
      q.values("resultid", "driverid__code")
      sql = _lhs_sql(q)
      @test occursin(r"ABS\(\(?\"Tb_1\"\.\"number\"", sql)
      @test occursin(r"> \"Tb\"\.\"number\"", sql)
    end

    # A string operand that names no column at all keeps its literal reading — it is bound as a
    # parameter, not turned into an "Invalid cjoin filter field" error.
    @testset "$backend: a literal string operand stays a literal" begin
      q = mod.Result.objects
      q.on("driverid", (F("number") + "7") > 0)
      q.values("resultid", "driverid__code")
      sql = _lhs_sql(q)
      @test occursin("\"Tb_1\".\"number\" + ", sql)
      @test !occursin("\"7\"", sql)
    end

    # A string operand naming a column of the BASE model only is a column on the left side, so it is
    # refused exactly like `F("grid")` — the driver has no `grid`. It used to render `"Tb"."grid"`.
    @testset "$backend: a base-only column string operand is refused" begin
      q = mod.Result.objects
      @test_throws FilterError q.on("driverid", (F("number") + "grid") > 0)
      @test_throws FilterError mod.Result.objects.on("driverid", (F("number") + F("grid")) > 0)
    end

    # A literal `then=` value stays a bound literal — only an expression in `kwargs` is walked.
    @testset "$backend: a literal then= stays a literal" begin
      q = mod.Result.objects
      q.on("driverid", "code" => Case(When("number__@gt" => 5, then = "grid"), default = "x"))
      q.values("resultid", "driverid__code")
      sql = _lhs_sql(q)
      @test !occursin("\"grid\"", sql)
    end
  end
end
