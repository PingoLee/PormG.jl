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
# `Constructor` (#962) is a second relation off `Result`, for a right side that names neither the base
# row nor the hop's own path.
# DB-free: mock connections, SQL inspected through `inspect_query`.
# ==============================================================================

using Test
using PormG
using PormG.QueryBuilder: inspect_query, F, Q, Qor, OP, Lower, Case, When, Subquery, OuterRef
using PormG.Functions: Max, Coalesce

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
  nationality = Models.CharField(),
)
# #962: a second relation off `Result`, nullable so its join is a LEFT JOIN beside the driver's INNER.
Constructor = Models.Model("constructor",
  constructorid = Models.IDField(),
  name = Models.CharField(),
  nationality = Models.CharField(),
)
Result = Models.Model("result",
  resultid = Models.IDField(),
  raceid = Models.IntegerField(),
  number = Models.IntegerField(),
  grid = Models.IntegerField(),
  payload = Models.JSONField(null = true),
  driverid = Models.ForeignKey(Driver, on_delete = "CASCADE", related_name = "results"),
  constructorid = Models.ForeignKey(Constructor, on_delete = "CASCADE", null = true, related_name = "results"),
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
  nationality = Models.CharField(),
)
# #962: a second relation off `Result`, nullable so its join is a LEFT JOIN beside the driver's INNER.
Constructor = Models.Model("constructor",
  constructorid = Models.IDField(),
  name = Models.CharField(),
  nationality = Models.CharField(),
)
Result = Models.Model("result",
  resultid = Models.IDField(),
  raceid = Models.IntegerField(),
  number = Models.IntegerField(),
  grid = Models.IntegerField(),
  payload = Models.JSONField(null = true),
  driverid = Models.ForeignKey(Driver, on_delete = "CASCADE", related_name = "results"),
  constructorid = Models.ForeignKey(Constructor, on_delete = "CASCADE", null = true, related_name = "results"),
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

# Build `q` and return the exception it raises, or `nothing` when it renders.
_rhs_f_build_error(q) = try inspect_query(q); nothing catch e; e end

# ─────────────────────────────────────────────────────────────────────────────
# Join conditions: a right side naming a relation off the hop's path is refused (#962)
# `F("driverid__nationality")` in a condition on the CONSTRUCTOR join names neither the base row nor a
# table on the constructor's path. It used to land in whichever join came later in FROM — the driver's
# INNER JOIN when `values()` built the constructor first, its own LEFT JOIN otherwise — so the rows
# returned depended on `values()` order. Both orders must now raise the same `FilterError`, in every
# spelling and on every route; the error is raised at build, so a declaration alone does not throw.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#962: a right side naming a relation off the hop's path is refused" begin
  # (label, mod -> condition, the token the message must show — the one the caller wrote).
  f_token = "F(\"driverid__nationality\")"
  spellings = (
    ("bare pair", _ -> "nationality" => F("driverid__nationality"), f_token),
    ("Q", _ -> Q("nationality" => F("driverid__nationality")), f_token),
    ("Qor", _ -> Qor("nationality" => F("driverid__nationality"), "name" => "x"), f_token),
    ("OP", _ -> OP("nationality", F("driverid__nationality")), f_token),
    ("F == F", _ -> F("nationality") == F("driverid__nationality"), f_token),
    # Inside a function on the right side: still a column of the driver.
    ("function on the right", _ -> "nationality" => Lower(F("driverid__nationality")), f_token),
    # `Case`/`When` keep `then`/`else` in `kwargs`, which the walk must read.
    ("Case then=", _ -> "nationality" => Case(When("number__@gt" => 1, then = F("driverid__nationality")), default = "x"), f_token),
    ("Case default=", _ -> "nationality" => Case(When("number__@gt" => 1, then = "x"), default = F("driverid__nationality")), f_token),
    # A bare string on the right of an `F` comparison is read as a column first; shown as written.
    ("bare string column", _ -> F("nationality") == "driverid__nationality", "\"driverid__nationality\""),
    # A subquery's `OuterRef` resolves in THIS statement, so it is a right-side column like any other.
    ("Subquery with an OuterRef",
     mod -> "name" => Subquery(mod.Driver.objects.
                filter("nationality" => OuterRef("driverid__nationality")).
                values("mx" => Max("code"))),
     "OuterRef(\"driverid__nationality\")"),
  )
  attach = (
    ("on()", (q, cond) -> q.on("constructorid", cond)),
    ("cjoin(filters = …)", (q, cond) -> q.cjoin("constructorid" => "Constructor", warn = false, filters = [cond])),
  )
  # Both FROM orders: the constructor join built first, and the driver join built first.
  orders = (
    ("constructor first", q -> q.values("resultid", "constructorid__name")),
    ("driver first", q -> q.values("resultid", "driverid__code", "constructorid__name")),
  )
  for (backend, mod) in _RHS_F_MODELS
    @testset "$backend: $route, $label, $order" for (route, on_) in attach, (label, cond, token) in spellings, (order, project) in orders
      q = mod.Result.objects
      on_(q, cond(mod))
      project(q)
      err = _rhs_f_build_error(q)
      @test err isa FilterError
      msg = replace(sprint(showerror, err), r"\e\[[0-9;]*m" => "")
      # Names the offending column as written, the relation it reaches, and the join it was written on.
      @test occursin(token * " reaches", msg)
      # A bare token is a substring of its `F(...)` spelling, so pin that it is NOT shown wrapped.
      startswith(token, "\"") && @test !occursin("F(" * token, msg)
      @test occursin("reaches 'driverid'", msg)
      @test occursin("outside the join path 'constructorid'", msg)
      @test occursin(".filter(...)", msg)
    end

    # A deep hop: `driverid__results` is Result → Driver → Result, and the constructor is not on it.
    @testset "$backend: deep hop, a relation off the path" begin
      q = mod.Result.objects
      q.on("driverid__results", "grid" => F("constructorid__nationality"))
      q.values("resultid", "driverid__results__grid")
      err = _rhs_f_build_error(q)
      @test err isa FilterError
      @test occursin("outside the join path 'driverid__results'", sprint(showerror, err))
    end

    # A relation that a `cjoin` declares AFTER the `on()` is still a relation: the check runs at
    # build, when every join is declared, so call order does not decide the outcome.
    @testset "$backend: a cjoin relation, declared before or after the on()" for cjoin_first in (true, false)
      link = PormG.Models.ForeignKey(mod.Driver, pk_field = "number", on_delete = "RESTRICT", null = true)
      q = mod.Result.objects
      add_cjoin = () -> q.cjoin("grid" => "Driver", warn = false, field = link)
      cjoin_first && add_cjoin()
      q.on("constructorid", "nationality" => F("grid__nationality"))
      cjoin_first || add_cjoin()
      q.values("resultid", "grid__code", "constructorid__name")
      err = _rhs_f_build_error(q)
      @test err isa FilterError
      @test occursin("reaches 'grid'", sprint(showerror, err))
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# Join conditions: right sides on the hop's own path still render (#962)
# The refusal is for relations OFF the path. These stay legal: the base row, the joined row itself
# through its path, a table earlier on a deep hop, a ForeignKey column of the base row, a JSON key path
# on the base row (a column, not a relation), and a plain string value, which is a bound literal even
# when it contains `__`.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#962: right sides on the hop's own path still render" begin
  cases = (
    ("the base row", q -> q.on("driverid", "number" => F("number")),
     q -> q.values("resultid", "driverid__code"), "\"Tb_1\".\"number\" = \"Tb\".\"number\""),
    ("the joined row through its path", q -> q.on("driverid", "number" => F("driverid__number")),
     q -> q.values("resultid", "driverid__code"), "\"Tb_1\".\"number\" = \"Tb_1\".\"number\""),
    ("an ancestor on a deep hop", q -> q.on("driverid__results", "grid" => F("driverid__number")),
     q -> q.values("resultid", "driverid__results__grid"), "\"Tb_2\".\"grid\" = \"Tb_1\".\"number\""),
    ("a ForeignKey column of the base row", q -> q.on("driverid", "driverid" => F("driverid")),
     q -> q.values("resultid", "driverid__code"), "\"Tb_1\".\"driverid\" = \"Tb\".\"driverid\""),
    ("a JSON key path on the base row", q -> q.on("driverid", "code" => F("payload__code")),
     q -> q.values("resultid", "driverid__code"), "\"Tb_1\".\"code\" = "),
    # Spelled like an off-path column on purpose: read as a column it would be refused.
    ("a literal containing __", q -> q.on("driverid", "code" => "constructorid__name"),
     q -> q.values("resultid", "driverid__code"), "\"Tb_1\".\"code\" = "),
    # Same, as a `then=` value: a String kwarg is a literal, only an expression in `kwargs` is walked.
    ("a literal then= containing __",
     q -> q.on("driverid", "code" => Case(When("number__@gt" => 1, then = "constructorid__name"), default = "x")),
     q -> q.values("resultid", "driverid__code"), "\"Tb_1\".\"code\" = CASE"),
    ("a then= naming the base row",
     q -> q.on("driverid", "number" => Case(When("number__@gt" => 1, then = F("grid")), default = 0)),
     q -> q.values("resultid", "driverid__code"), "THEN \"Tb\".\"grid\""),
  )
  for (backend, mod) in _RHS_F_MODELS
    @testset "$backend: $label" for (label, on_, project, fragment) in cases
      q = mod.Result.objects
      on_(q)
      project(q)
      @test _rhs_f_build_error(q) === nothing
      @test occursin(fragment, _rhs_f_sql(q))
    end

    # A subquery whose `OuterRef` names the base row: the correlation the right side is for.
    @testset "$backend: a subquery correlated to the base row" begin
      sub = mod.Driver.objects.
        filter("driverid" => OuterRef("driverid")).
        values("mx" => Max("number"))
      q = mod.Result.objects
      q.on("driverid", "number" => Subquery(sub))
      q.values("resultid", "driverid__code")
      @test _rhs_f_build_error(q) === nothing
      @test occursin("= \"Tb\".\"driverid\"", _rhs_f_sql(q))
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# Join conditions: a right side nested inside the left side is checked too (#962)
# A comparison nested in the left side — a `When` condition, `When(F("number") > F(…))` — keeps the #958
# rule (its right side names the base row), and a subquery's `OuterRef` resolves in this statement, so
# either can reach an off-path relation and was relocated like a top-level right side. Refused in both
# `values()` orders; a nested right side that names the base row still renders.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#962: a right side nested inside the left side" begin
  nested = (
    ("a When condition's pair", _ ->
      Case(When("number" => F("constructorid__constructorid"), then = 1), default = 0) > 0,
     "F(\"constructorid__constructorid\")"),
    ("a When condition's F comparison", _ ->
      Case(When(F("number") > F("constructorid__constructorid"), then = 1), default = 0) > 0,
     "F(\"constructorid__constructorid\")"),
    ("a subquery's OuterRef on the left", mod ->
      Coalesce(Subquery(mod.Constructor.objects.
                 filter("name" => OuterRef("constructorid__name")).
                 values("mx" => Max("constructorid"))), 0) > 1,
     "OuterRef(\"constructorid__name\")"),
  )
  orders = (
    ("driver first", q -> q.values("resultid", "driverid__code", "constructorid__name")),
    ("constructor first", q -> q.values("resultid", "constructorid__name", "driverid__code")),
  )
  for (backend, mod) in _RHS_F_MODELS
    @testset "$backend: $label, $order" for (label, cond, token) in nested, (order, project) in orders
      q = mod.Result.objects
      q.on("driverid", cond(mod))
      project(q)
      err = _rhs_f_build_error(q)
      @test err isa FilterError
      msg = replace(sprint(showerror, err), r"\e\[[0-9;]*m" => "")
      @test occursin(token * " reaches", msg)
      @test occursin("outside the join path 'driverid'", msg)
    end

    @testset "$backend: a nested right side naming the base row still renders" begin
      q = mod.Result.objects
      q.on("driverid", Case(When(F("number") > F("grid"), then = 1), default = 0) > 0)
      q.values("resultid", "driverid__code", "constructorid__name")
      @test _rhs_f_build_error(q) === nothing
      @test occursin("\"Tb_1\".\"number\" > \"Tb\".\"grid\"", _rhs_f_sql(q))
    end
  end
end
