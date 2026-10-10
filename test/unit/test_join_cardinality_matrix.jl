# ==============================================================================
# UNIT TESTS: the join-cardinality matrix (#1002)
#
# Does a join change how many times a base row appears? Every way a query can introduce a join × every
# kind of relation it can cross × both engines, recorded as DATA: the statement PormG renders, or the
# error it raises and at which stage. The expected values live in
# `fixtures/join_cardinality_matrix_expected.jl`, so a change in this area shows up as a diff to that
# file — `test_join_condition_matrix.jl`'s arrangement (#977), asked a different question: that matrix
# records which row a condition names, this one whether a join repeats the base row.
#
# Introducers: a projection, a filter, an ordering, an `on()` path, a `cjoin_on` condition; the
# terminals that read the rows (`count()`, `exists()`, a scalar `Subquery`) and the ones that only ask
# whether a row matches (`exists()` without an offset, `Exists(...)`, an `__@in` subquery, `update()`,
# `delete()`); `distinct()`. Relations: forward (nullable), reverse, reverse OneToOne, ManyToMany, and a
# `cjoin(field = …)` link to a unique and to a non-unique column.
#
# Regenerating: `PORMG_JCARD_RECORD=1 julia --project=test/integration test/unit/test_join_cardinality_matrix.jl`
# rewrites the fixture from the current code. Only do that for a change you intend, and read the diff:
# it IS the review of that change.
# DB-free: mock connections, SQL inspected through `inspect_query` and `show_query = :sql`.
# ==============================================================================

using Test
using PormG
using PormG.QueryBuilder: inspect_query, F, Q, Qor, Subquery, OuterRef, Exists, Joined, Case, When
using PormG.Functions: Count, Max, RowNumber, WindowOver

struct JcardMockPostgres <: PormG.PormGPostgres end
struct JcardMockSQLite <: PormG.PormGSQLite end
PormG.backend_sqlite_version(::JcardMockSQLite) = 3045000

PormG.config["jcard_pg"] = PormG.Configuration.Settings(
  connections = JcardMockPostgres(), change_data = true, db_def_folder = "jcard_pg")
PormG.config["jcard_sl"] = PormG.Configuration.Settings(
  connections = JcardMockSQLite(), change_data = true, db_def_folder = "jcard_sl")

# One model set per engine, identical. From `Driver`: `teamid` is a nullable forward relation, `results`
# a reverse one, `profile` a reverse OneToOne (to-one: the child's key is unique), `sponsors` a
# ManyToMany. `Result` is a leaf — nothing references it, so its `delete()` cascades nowhere — and
# carries two plain columns a `cjoin` can link to `Driver`: `code` to the unique `Driver.code`, `grid` to
# the non-unique `Driver.number` — and `carno`, a model ForeignKey whose `pk_field` names that same
# non-unique column, so a forward hop that repeats rows without any `cjoin` declaring it.
for (modname, key) in ((:JcardPGModels, "jcard_pg"), (:JcardSLModels, "jcard_sl"))
  @eval module $modname
  import PormG
  import PormG.Models
  Team = Models.Model("team",
    teamid = Models.IDField(),
    name = Models.CharField(),
  )
  Sponsor = Models.Model("sponsor",
    sponsorid = Models.IDField(),
    name = Models.CharField(),
  )
  Driver = Models.Model("driver",
    driverid = Models.IDField(),
    code = Models.CharField(unique = true),
    number = Models.IntegerField(),
    nationality = Models.CharField(),
    teamid = Models.ForeignKey(Team, on_delete = "CASCADE", null = true, related_name = "drivers"),
    sponsors = Models.ManyToManyField(Sponsor, related_name = "drivers"),
  )
  Profile = Models.Model("profile",
    profileid = Models.IDField(),
    bio = Models.CharField(),
    driverid = Models.OneToOneField(Driver, on_delete = "CASCADE", related_name = "profile"),
  )
  Result = Models.Model("result",
    resultid = Models.IDField(),
    code = Models.CharField(),
    grid = Models.IntegerField(),
    number = Models.IntegerField(),
    points = Models.IntegerField(),
    driverid = Models.ForeignKey(Driver, on_delete = "CASCADE", related_name = "results"),
    carno = Models.ForeignKey(Driver, pk_field = "number", on_delete = "CASCADE", null = true,
                              related_name = "numbered_results"),
  )
  PormG.Models.set_models(@__MODULE__, $key)
  end
end

const _JCARD_MODELS = ((:postgres, JcardPGModels), (:sqlite, JcardSLModels))

# The two `cjoin(field = …)` links: `code` to a unique column, `grid` to a non-unique one.
_jcard_link(mod, pk) = PormG.Models.ForeignKey(mod.Driver, pk_field = pk, on_delete = "RESTRICT", null = true)

# What a cell's last step returns: rendered SQL, read through whichever form the terminal answers in.
_jcard_read(q) = inspect_query(q)[:sql_text]
_jcard_sql(x::AbstractString) = x
_jcard_sql(x::AbstractDict) = x[:sql_text]
_jcard_sql(x) = repr(x)

# ---------------------------------------------------------------------------
# Relations — each `(name, path, value)` from `Driver`. The path's last segment is a column of the model
# the relation reaches, so the same path serves a projection, a filter and an ordering.
# ---------------------------------------------------------------------------
const _JCARD_RELATIONS = (
  ("forward nullable", "teamid__name", "X"),
  ("reverse", "results__grid", 1),
  ("reverse OneToOne", "profile__bio", "X"),
  ("ManyToMany", "sponsors__name", "X"),
)

# ---------------------------------------------------------------------------
# Introducers — each a function of the relation's path and value, returning `(setup, run)`: `setup(mod)`
# builds the handler (a refusal there is stage `:call`), `run(q)` renders it (stage `:build`).
# ---------------------------------------------------------------------------
const _JCARD_INTRODUCERS = (
  ("values", (p, v) -> (mod -> mod.Driver.objects.values("driverid", p), _jcard_read)),
  ("filter", (p, v) -> (mod -> mod.Driver.objects.filter(p => v).values("driverid"), _jcard_read)),
  ("order_by", (p, v) -> (mod -> mod.Driver.objects.order_by(p).values("driverid"), _jcard_read)),
  ("filter + distinct()", (p, v) -> (mod -> mod.Driver.objects.filter(p => v).values("driverid").distinct(), _jcard_read)),
  # The same path projected and filtered: one join, which the projection asked for.
  ("filter + values same path", (p, v) -> (mod -> mod.Driver.objects.filter(p => v).values("driverid", p), _jcard_read)),
  ("filter + Qor", (p, v) -> (mod -> mod.Driver.objects.filter(Qor(p => v, "number" => 7)).values("driverid"), _jcard_read)),
  ("filter + limit", (p, v) -> (mod -> mod.Driver.objects.filter(p => v).values("driverid").limit(5), _jcard_read)),
  ("count()", (p, v) -> (mod -> mod.Driver.objects.filter(p => v), q -> q.count(show_query = :sql))),
  ("count(distinct = true)", (p, v) -> (mod -> mod.Driver.objects.filter(p => v).values("driverid"),
                                        q -> q.count(distinct = true, show_query = :sql))),
  ("count() over values same path", (p, v) -> (mod -> mod.Driver.objects.filter(p => v).values("driverid", p),
                                               q -> q.count(show_query = :sql))),
  ("exists()", (p, v) -> (mod -> mod.Driver.objects.filter(p => v), q -> q.exists(show_query = :sql))),
  ("exists() with offset", (p, v) -> (mod -> mod.Driver.objects.filter(p => v).offset(2), q -> q.exists(show_query = :sql))),
  ("aggregate()", (p, v) -> (mod -> mod.Driver.objects.filter(p => v), q -> q.aggregate("n" => Max("number"), show_query = :sql))),
  ("aggregate() Count", (p, v) -> (mod -> mod.Driver.objects.filter(p => v), q -> q.aggregate("n" => Count("driverid"), show_query = :sql))),
  ("count(column, distinct = true)", (p, v) -> (mod -> mod.Driver.objects.filter(p => v),
                                                q -> q.count("driverid", distinct = true, show_query = :sql))),
  ("grouped Count", (p, v) -> (mod -> mod.Driver.objects.filter(p => v).values("teamid", "n" => Count("driverid")), _jcard_read)),
  ("grouped Max", (p, v) -> (mod -> mod.Driver.objects.filter(p => v).values("teamid", "n" => Max("number")), _jcard_read)),
  ("Exists() subquery", (p, v) -> (mod -> mod.Team.objects.filter(Exists(mod.Driver.objects.filter("teamid" => OuterRef("teamid"), p => v))).values("teamid"), _jcard_read)),
  ("Exists() subquery with offset", (p, v) -> (mod -> mod.Team.objects.filter(Exists(mod.Driver.objects.filter("teamid" => OuterRef("teamid"), p => v).offset(2))).values("teamid"), _jcard_read)),
  ("__@in subquery", (p, v) -> (mod -> mod.Team.objects.filter("teamid__@in" => mod.Driver.objects.filter(p => v).values("teamid")).values("teamid"), _jcard_read)),
  ("__@in subquery, sliced", (p, v) -> (mod -> mod.Team.objects.filter("teamid__@in" => mod.Driver.objects.filter(p => v).values("teamid").limit(5)).values("teamid"), _jcard_read)),
  ("scalar Subquery", (p, v) -> (mod -> mod.Team.objects.values("teamid",
                                   "c" => Subquery(mod.Driver.objects.filter("teamid" => OuterRef("teamid"), p => v).values("code").limit(1))), _jcard_read)),
  ("cjoin_on condition", (p, v) -> (mod -> mod.Driver.objects.cjoin_on("Team", alias = "t2",
                                      on = [Joined("t2", "teamid") == F("teamid"), p => v]).values("driverid"), _jcard_read)),
  # Mutations run from `Result`, one forward hop below `Driver`, so `delete()` cascades nowhere.
  ("update()", (p, v) -> (mod -> mod.Result.objects.filter("driverid__$(p)" => v), q -> q.update("number" => 1, show_query = :sql))),
  ("update() SET from a join", (p, v) -> (mod -> mod.Result.objects.filter("driverid__$(p)" => v),
                                          q -> q.update("number" => F("driverid__number"), show_query = :sql))),
  ("delete()", (p, v) -> (mod -> mod.Result.objects.filter("driverid__$(p)" => v), q -> q.delete(show_query = :sql))),
)

# `on()` declares its path. Not on a ManyToMany hop, which it refuses (#977) — the matrix records that.
_jcard_on_cells() = [
  ("on() path/$(name)", (mod -> mod.Driver.objects.on(String(first(split(p, "__"))), String(last(split(p, "__"))) => v).values("driverid"), _jcard_read))
  for (name, p, v) in _JCARD_RELATIONS]

# ---------------------------------------------------------------------------
# Single cells — shapes that only make sense once.
# ---------------------------------------------------------------------------
const _JCARD_SINGLE_CELLS = (
  # Declared means the same join alias, not another path to the same table.
  ("same alias, another column projected",
   (mod -> mod.Driver.objects.filter("results__grid" => 1).values("driverid", "results__points"), _jcard_read)),
  ("another path to the same table projected",
   (mod -> mod.Driver.objects.filter("results__driverid__results__grid" => 1).values("driverid", "results__points"), _jcard_read)),
  ("order_by on a projected to-many path",
   (mod -> mod.Driver.objects.order_by("-results__grid").values("driverid", "results__grid"), _jcard_read)),
  # A forward hop past a reverse one: the reverse hop is still the one that repeats.
  ("filter, reverse then forward",
   (mod -> mod.Team.objects.filter("drivers__teamid__name" => "X").values("teamid"), _jcard_read)),
  # #1112: a reverse hop after the first, followed by another relation. The loop's reverse arm checked
  # the next segment against the child's columns only, so a reverse accessor or a ManyToMany field there
  # was refused; an unknown column now reports through the same funnel as at the first hop.
  ("values, forward then reverse then reverse (#1112)",
   (mod -> mod.Driver.objects.values("driverid", "teamid__drivers__results__grid"), _jcard_read)),
  ("filter, forward then reverse then reverse (#1112)",
   (mod -> mod.Driver.objects.filter("teamid__drivers__results__grid" => 1).values("driverid"), _jcard_read)),
  ("values, forward then reverse then ManyToMany (#1112)",
   (mod -> mod.Driver.objects.values("driverid", "teamid__drivers__sponsors__name"), _jcard_read)),
  ("values, forward then reverse then an unknown column (#1112)",
   (mod -> mod.Driver.objects.values("driverid", "teamid__drivers__nope"), _jcard_read)),
  # The reverse ManyToMany arm (`Sponsor.drivers`) after a loop reverse hop, and an `on()` path through one.
  ("values, forward then reverse then ManyToMany then reverse ManyToMany (#1112)",
   (mod -> mod.Driver.objects.values("driverid", "teamid__drivers__sponsors__drivers__code"), _jcard_read)),
  ("on() path through a reverse hop after the first (#1112)",
   (mod -> mod.Driver.objects.on("teamid__drivers__results", "grid" => 1).values("driverid", "teamid__drivers__results__points"), _jcard_read)),
  ("filter, forward not null from Result",
   (mod -> mod.Result.objects.filter("driverid__code" => "X").values("resultid"), _jcard_read)),
  # An `OuterRef` across a to-many path joins the OUTER query.
  ("OuterRef across a reverse path",
   (mod -> mod.Team.objects.values("teamid",
      "c" => Subquery(mod.Driver.objects.filter("code" => OuterRef("drivers__code")).values("number").limit(1))), _jcard_read)),
  # #973: an `on()` condition reaching past its hop.
  ("on() condition past the hop, reverse (#973)",
   (mod -> mod.Result.objects.on("driverid", "results__grid" => 1).values("resultid"), _jcard_read)),
  # `cjoin(field = …)` links: to a unique column (to-one) and to a non-unique one (to-many).
  ("cjoin link unique/values",
   (mod -> mod.Result.objects.cjoin("code" => "Driver", field = _jcard_link(mod, "code"), warn = false).values("resultid", "code__nationality"), _jcard_read)),
  ("cjoin link unique/filter",
   (mod -> mod.Result.objects.cjoin("code" => "Driver", field = _jcard_link(mod, "code"), warn = false).filter("code__nationality" => "X").values("resultid"), _jcard_read)),
  ("cjoin link unique/grouped Count",
   (mod -> mod.Result.objects.cjoin("code" => "Driver", field = _jcard_link(mod, "code"), warn = false).values("code__nationality", "n" => Count("resultid")), _jcard_read)),
  ("cjoin link non-unique/values",
   (mod -> mod.Result.objects.cjoin("grid" => "Driver", field = _jcard_link(mod, "number"), warn = false).values("resultid", "grid__nationality"), _jcard_read)),
  ("cjoin link non-unique/filter",
   (mod -> mod.Result.objects.cjoin("grid" => "Driver", field = _jcard_link(mod, "number"), warn = false).filter("grid__nationality" => "X").values("resultid"), _jcard_read)),
  ("cjoin link non-unique/grouped Count",
   (mod -> mod.Result.objects.cjoin("grid" => "Driver", field = _jcard_link(mod, "number"), warn = false).values("grid__nationality", "n" => Count("resultid")), _jcard_read)),
  # A model ForeignKey whose `pk_field` is not unique is to-many with no `cjoin` declaring it.
  ("ForeignKey pk_field non-unique/filter",
   (mod -> mod.Result.objects.filter("carno__code" => "X").values("resultid"), _jcard_read)),
  ("ForeignKey pk_field non-unique/values",
   (mod -> mod.Result.objects.values("resultid", "carno__code"), _jcard_read)),
  # `count()` clears a plain projection, and the joins it declared must stay declared: a `When` and a
  # window's PARTITION BY are projections too (review of #1002).
  ("count() over a Case projection of the same path",
   (mod -> mod.Driver.objects.filter("results__grid" => 1).values("driverid",
      "c" => Case(When("results__points__@gt" => 0, then = 1), default = 0)), q -> q.count(show_query = :sql))),
  ("count() over a window partitioned by the same path",
   (mod -> mod.Driver.objects.filter("results__grid" => 1).values("driverid",
      "rn" => RowNumber(over = WindowOver(partition_by = ["results__points"]))), q -> q.count(show_query = :sql))),
  # An ordering in an aggregating query joins GROUP BY, so a to-many path there splits every group;
  # `distinct()` cannot undo that.
  ("grouped Max ordered by a to-many path",
   (mod -> mod.Driver.objects.values("teamid", "n" => Max("number")).order_by("results__grid"), _jcard_read)),
  ("grouped Max ordered by a to-many path, distinct",
   (mod -> mod.Driver.objects.values("teamid", "n" => Max("number")).order_by("results__grid").distinct(), _jcard_read)),
  ("grouped Max filtered and ordered by the same to-many path",
   (mod -> mod.Driver.objects.filter("results__grid" => 1).values("teamid", "n" => Max("number")).order_by("results__grid"), _jcard_read)),
  ("cjoin link non-unique/cjoin_on condition",
   (mod -> mod.Result.objects.cjoin("grid" => "Driver", field = _jcard_link(mod, "number"), warn = false).
      cjoin_on("Driver", alias = "d2", on = [Joined("d2", "driverid") == F("driverid"), "grid__nationality" => "X"]).values("resultid"), _jcard_read)),
)

# Every cell, flattened: (id, (setup, run)).
const _JCARD_CELLS = vcat(
  [("$(intro)/$(name)", make(p, v)) for (intro, make) in _JCARD_INTRODUCERS for (name, p, v) in _JCARD_RELATIONS],
  _jcard_on_cells(),
  collect(_JCARD_SINGLE_CELLS),
)

# The first line of an error, ANSI-stripped and cut to a stable length: the identity of a refusal, without
# pinning every word of its remedy text (that is what each issue's own test does).
function _jcard_message(e)
  msg = replace(sprint(showerror, e), r"\e\[[0-9;]*m" => "")
  line = first(split(msg, '\n'))
  return length(line) > 120 ? first(line, 120) : String(line)
end

# What one cell does on one engine: the rendered statement, or the error and the stage it fired at.
function _jcard_observe(mod, cell)
  setup, run = cell
  q = try
    setup(mod)
  catch e
    return (stage = :call, error = string(nameof(typeof(e))), message = _jcard_message(e))
  end
  try
    sql = replace(_jcard_sql(run(q)), r"\s+" => " ")
    return (stage = :ok, sql = String(strip(sql)))
  catch e
    return (stage = :build, error = string(nameof(typeof(e))), message = _jcard_message(e))
  end
end

const _JCARD_FIXTURE = joinpath(@__DIR__, "fixtures", "join_cardinality_matrix_expected.jl")

if get(ENV, "PORMG_JCARD_RECORD", "") == "1"
  # Record mode: write the fixture from the current code and stop. Not a test run.
  open(_JCARD_FIXTURE, "w") do io
    println(io, "# GENERATED by test/unit/test_join_cardinality_matrix.jl with PORMG_JCARD_RECORD=1 — do not edit by hand.")
    println(io, "# One entry per (cell, engine): what PormG renders or refuses. A diff here is a behaviour change (#1002).")
    println(io, "const _JCARD_EXPECTED = Dict{Tuple{String,Symbol},Any}(")
    for (id, cell) in _JCARD_CELLS, (backend, mod) in _JCARD_MODELS
      println(io, "  ", repr((id, backend)), " =>\n    ", repr(_jcard_observe(mod, cell)), ",")
    end
    println(io, ")")
  end
  @info "join-cardinality matrix recorded" path = _JCARD_FIXTURE cells = length(_JCARD_CELLS)
else
  include(_JCARD_FIXTURE)

  # ─────────────────────────────────────────────────────────────────────────────
  # Join-cardinality matrix: every cell matches its recorded outcome, on both engines
  # Each (cell, engine) pair renders the recorded statement, or raises the recorded error at the
  # recorded stage. The fixture holds exactly the cells this file defines, so a deleted cell cannot
  # leave its expectation behind unchecked.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "#1002: join-cardinality matrix" begin
    defined = Set((id, backend) for (id, _) in _JCARD_CELLS for (backend, _) in _JCARD_MODELS)
    @test defined == Set(keys(_JCARD_EXPECTED))

    for (id, cell) in _JCARD_CELLS, (backend, mod) in _JCARD_MODELS
      @testset "$backend: $id" begin
        expected = _JCARD_EXPECTED[(id, backend)]
        got = _jcard_observe(mod, cell)
        # Field by field, so a failure names the part that moved (stage, SQL, message).
        @test got.stage == expected.stage
        for k in keys(expected)
          @test get(got, k, missing) == expected[k]
        end
      end
    end
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # Join-cardinality matrix: a refusal refuses on both engines alike
  # Cardinality is a property of the relation, not of the engine, so no cell may render on one engine
  # and refuse on the other.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "#1002: join-cardinality matrix, engines agree" begin
    for (id, cell) in _JCARD_CELLS
      pg = _jcard_observe(JcardPGModels, cell)
      sl = _jcard_observe(JcardSLModels, cell)
      @test (id, pg.stage) == (id, sl.stage)
    end
  end
end
