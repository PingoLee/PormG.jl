# ==============================================================================
# UNIT TESTS: the join-condition matrix (#977)
#
# Every spelling of a join condition × every position it can be declared in × both engines, recorded as
# DATA: the statement PormG renders and its parameters, or the error it raises and at which stage (at the
# fluent call, or at build). The expected values live in `fixtures/join_condition_matrix_expected.jl`, so a
# behaviour change in this area shows up as a diff to that file — the record of which cells a change
# moved, and the place a new spelling is added as a row rather than an arm.
#
# Positions: `on()` on a first hop and on a deep hop; `cjoin(filters = …)`; `cjoin` on a plain column with
# a custom link (`field = …`), and `on()` against such a link in both declaration orders (#974, #434); an
# `on()` whose path nothing else in the query reaches; an `on()` across a ManyToMany hop; `cjoin_on`. Spellings: bare and already-prefixed
# pairs, a lookup, `Q`/`Qor`/`OP`, `F` comparisons and arithmetic, a function and a `Case` on the left, a
# right side naming the base row / the hop / an ancestor / a relation off the path (#962), subqueries and
# `Exists` with `OuterRef`s, handles, and a left-side key reaching past the hop (#973).
#
# Every cell that renders also carries the #421 differential: the order PostgreSQL's `$N` markers appear
# in the text, applied to its parameter vector, must equal SQLite's positional vector.
#
# Regenerating: `PORMG_JCM_RECORD=1 julia --project=test/integration test/unit/test_join_condition_matrix.jl`
# rewrites the fixture from the current code. Only do that for a change you intend, and read the diff:
# it IS the review of that change.
# DB-free: mock connections, SQL inspected through `inspect_query`.
# ==============================================================================

using Test
using PormG
using PormG.QueryBuilder: inspect_query, F, Q, Qor, OP, Case, When, Subquery, OuterRef, Exists, CTE, Joined
using PormG.Functions: Max, Abs

struct JcmMockPostgres <: PormG.PormGPostgres end
struct JcmMockSQLite <: PormG.PormGSQLite end
PormG.backend_sqlite_version(::JcmMockSQLite) = 3045000

PormG.config["jcm_pg"] = PormG.Configuration.Settings(
  connections = JcmMockPostgres(), change_data = true, db_def_folder = "jcm_pg")
PormG.config["jcm_sl"] = PormG.Configuration.Settings(
  connections = JcmMockSQLite(), change_data = true, db_def_folder = "jcm_sl")

# One model set per engine, identical. `Result` and `Driver` both carry `number`, so a column landing on
# the wrong row is visible in the SQL. `Driver → Team` is a forward relation one hop past `driverid`
# (#973's forward shape), `Driver.results` the reverse one (#973's own repro), `Driver.sponsors` a
# ManyToMany one. `status_id` is spelled
# with the `_id` suffix so the FK short form `status__…` exists. `grid` is a plain column a `cjoin` can
# link to `Driver.number` (#974).
for (modname, key) in ((:JcmPGModels, "jcm_pg"), (:JcmSLModels, "jcm_sl"))
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
    code = Models.CharField(),
    number = Models.IntegerField(),
    nationality = Models.CharField(),
    teamid = Models.ForeignKey(Team, on_delete = "CASCADE", null = true, related_name = "drivers"),
    sponsors = Models.ManyToManyField(Sponsor, related_name = "drivers"),
  )
  Constructor = Models.Model("constructor",
    constructorid = Models.IDField(),
    name = Models.CharField(),
  )
  Status = Models.Model("status",
    statusid = Models.IDField(),
    name = Models.CharField(),
  )
  Result = Models.Model("result",
    resultid = Models.IDField(),
    raceid = Models.IntegerField(),
    number = Models.IntegerField(),
    grid = Models.IntegerField(),
    driverid = Models.ForeignKey(Driver, on_delete = "CASCADE", related_name = "results"),
    constructorid = Models.ForeignKey(Constructor, on_delete = "CASCADE", null = true, related_name = "results"),
    status_id = Models.ForeignKey(Status, on_delete = "CASCADE", null = true, related_name = "results"),
  )
  PormG.Models.set_models(@__MODULE__, $key)
  end
end

const _JCM_MODELS = ((:postgres, JcmPGModels), (:sqlite, JcmSLModels))

# The custom link `cjoin("grid" => "Driver", field = …)` uses: `grid` joins `Driver.number`.
_jcm_link(mod) = PormG.Models.ForeignKey(mod.Driver, pk_field = "number", on_delete = "RESTRICT", null = true)

# ---------------------------------------------------------------------------
# Positions — how a condition is attached, and what the query projects so the join is (or is not) reached.
# `p` is the join path the condition's left side belongs to; the already-prefixed spelling uses it.
# ---------------------------------------------------------------------------
const _JCM_GRID_POSITIONS = (
  ("P1 on first hop", "driverid",
   (q, mod, c) -> (q.on("driverid", c); q.values("resultid", "driverid__code"))),
  # `driverid__results` hops Result → Driver → Result: the condition belongs to the second Result.
  ("P2 on deep hop", "driverid__results",
   (q, mod, c) -> (q.on("driverid__results", c); q.values("resultid", "driverid__results__grid"))),
  ("P3 cjoin filters", "driverid",
   (q, mod, c) -> (q.cjoin("driverid" => "Driver", warn = false, filters = [c]); q.values("resultid", "driverid__code"))),
)

# ---------------------------------------------------------------------------
# Spellings — each a function of the hop path `p` and the model module, crossed with every grid position.
# Every column is one both `Driver` and `Result` carry, so the same spelling is valid on either hop.
# ---------------------------------------------------------------------------
const _JCM_GRID_SPELLINGS = (
  ("bare pair",           (p, mod) -> "number" => 5),
  ("already-prefixed",    (p, mod) -> "$(p)__number" => 5),
  ("lookup",              (p, mod) -> "number__@gte" => 5),
  ("Q",                   (p, mod) -> Q("number" => 5, "number__@lt" => 9)),
  ("Qor",                 (p, mod) -> Qor("number" => 5, "number" => 7)),
  ("OP",                  (p, mod) -> OP("number", ">", 5)),
  ("pair, F base rhs",    (p, mod) -> "number" => F("number")),
  ("F == F",              (p, mod) -> F("number") == F("number")),
  ("F arithmetic",        (p, mod) -> (F("number") + 1) > 3),
  ("function lhs",        (p, mod) -> Abs(F("number")) > 0),
  ("Case lhs",            (p, mod) -> Case(When("number__@gt" => 5, then = F("number")), default = F("number")) > 1),
  ("rhs own path",        (p, mod) -> "number" => F("$(p)__number")),
  ("Subquery, base OuterRef",
   (p, mod) -> "number" => Subquery(mod.Driver.objects.filter("driverid" => OuterRef("driverid")).values("mx" => Max("number")))),
  ("Exists, base OuterRef",
   (p, mod) -> Q(Exists(mod.Constructor.objects.filter("constructorid" => OuterRef("constructorid"))))),
)

# ---------------------------------------------------------------------------
# Single cells — shapes that only make sense in one position.
# ---------------------------------------------------------------------------
const _JCM_SINGLE_CELLS = (
  # A right side naming an ancestor of a deep hop: allowed by #962.
  ("P2 on deep hop/rhs ancestor",
   (q, mod) -> (q.on("driverid__results", "number" => F("driverid__number")); q.values("resultid", "driverid__results__grid"))),
  # #962: a right side naming a relation off the join path.
  ("P1 on first hop/rhs off-path (#962)",
   (q, mod) -> (q.on("driverid", "number" => F("constructorid__constructorid")); q.values("resultid", "driverid__code"))),
  # The two #962 gaps: an `Exists` whose `OuterRef` names an off-path relation, and the FK short form.
  ("P1 on first hop/Exists, off-path OuterRef",
   (q, mod) -> (q.on("driverid", Q(Exists(mod.Constructor.objects.filter("name" => OuterRef("constructorid__name")))));
                q.values("resultid", "driverid__code"))),
  ("P1 on first hop/rhs off-path, FK short form",
   (q, mod) -> (q.on("driverid", "code" => F("status__name")); q.values("resultid", "driverid__code"))),
  # Two more right sides #962's walk missed (review of #977): a `When` over a `Q` naming an off-path
  # relation, and a subquery's off-path `OuterRef` in a `Case` branch. Both used to land in the
  # constructor's join.
  ("P1 on first hop/rhs off-path in a When over Q",
   (q, mod) -> (q.on("driverid", "number" => Case(When(Q("constructorid__name" => "x"), then = 1), default = 0));
                q.values("resultid", "driverid__code"))),
  ("P1 on first hop/rhs off-path OuterRef in a Case branch",
   (q, mod) -> (q.on("driverid", "number" => Case(When("grid" => 1,
                  then = Subquery(mod.Constructor.objects.filter("name" => OuterRef("constructorid__name")).values("constructorid"))),
                  default = 0));
                q.values("resultid", "driverid__code"))),
  # Handles are refused at the call (#444, #481).
  ("P1 on first hop/CTE handle",
   (q, mod) -> (q.on("driverid", "number" => CTE("ev", "sku")); q.values("resultid", "driverid__code"))),
  ("P1 on first hop/Joined handle",
   (q, mod) -> (q.on("driverid", "number" => Joined("d2", "number")); q.values("resultid", "driverid__code"))),
  # #973: a left-side key whose relation part reaches past the hop — reverse (the issue's repro) and forward.
  ("P1 on first hop/lhs past hop, reverse (#973)",
   (q, mod) -> (q.on("driverid", "results__grid" => 1); q.values("resultid", "driverid__code"))),
  ("P1 on first hop/lhs past hop, reverse in Q (#973)",
   (q, mod) -> (q.on("driverid", Q("results__grid" => 1)); q.values("resultid", "driverid__code"))),
  ("P1 on first hop/lhs past hop, forward (#973)",
   (q, mod) -> (q.on("driverid", "teamid__name" => "X"); q.values("resultid", "driverid__code"))),
  ("P3 cjoin filters/lhs past hop, forward (#973)",
   (q, mod) -> (q.cjoin("driverid" => "Driver", warn = false, filters = ["teamid__name" => "X"]); q.values("resultid"))),
  # #421's shape: the deeper key listed FIRST, so binding order and emission order used to differ.
  ("P3 cjoin filters/two depths, deep first (#421)",
   (q, mod) -> (q.cjoin("driverid" => "Driver", warn = false, join_type = "INNER",
                        filters = ["teamid__name" => "ZZZ", "code" => "SSS"]); q.values("resultid"))),
  # The explicit spelling of the same restriction: one `on()` per hop.
  ("P1 on first hop/two depths, one on() per hop",
   (q, mod) -> (q.cjoin("driverid" => "Driver", warn = false, join_type = "INNER", filters = ["code" => "SSS"]);
                q.on("driverid__teamid", "name" => "ZZZ"); q.values("resultid", "driverid__teamid__name"))),
  # #974: a `cjoin` on a plain column with a custom link, and `on()` against it in both orders.
  ("P4 cjoin plain column/bare pair",
   (q, mod) -> (q.cjoin("grid" => "Driver", warn = false, field = _jcm_link(mod), filters = ["code" => "X"]);
                q.values("resultid", "grid__code"))),
  ("P5a cjoin then on()/bare pair (#974)",
   (q, mod) -> (q.cjoin("grid" => "Driver", warn = false, field = _jcm_link(mod)); q.on("grid", "code" => "X");
                q.values("resultid", "grid__code"))),
  ("P5b on() then cjoin/bare pair (#974)",
   (q, mod) -> (q.on("grid", "code" => "X"); q.cjoin("grid" => "Driver", warn = false, field = _jcm_link(mod));
                q.values("resultid", "grid__code"))),
  # A plain column no `cjoin` ever links: not a relation, refused — at build, since a later `cjoin`
  # could have linked it (#974).
  ("P5c on() plain column, no cjoin/bare pair",
   (q, mod) -> (q.on("grid", "code" => "X"); q.values("resultid"))),
  # An `on()` on a path nothing else in the query reaches.
  ("P6 on() unreached path/bare pair",
   (q, mod) -> (q.on("constructorid", "name" => "X"); q.values("resultid"))),
  ("P6 on() unreached path/INNER",
   (q, mod) -> (q.on("constructorid", "name" => "X", join_type = "INNER"); q.values("resultid"))),
  # The FK short form and the field name are one path: an `on()` in one spelling decorates the join a
  # traversal built in the other (review of #977: the predicate was dropped, INNER included).
  ("P9 on() short form, traversed by field name/INNER",
   (q, mod) -> (q.on("status", "name" => "X", join_type = "INNER"); q.values("resultid", "status_id__name"))),
  ("P9 on() field name, traversed by short form/bare pair",
   (q, mod) -> (q.on("status_id", "name" => "X"); q.values("resultid", "status__name"))),
  # The same, with a `cjoin` keyed on the FK field: its filters, and an `on()` in the short form, must
  # reach the join a short-form traversal builds, in either declaration order.
  ("P9 cjoin on FK field, traversed by short form/filters",
   (q, mod) -> (q.cjoin("status_id" => "Status", warn = false, join_type = "INNER", filters = ["name" => "X"]);
                q.values("resultid", "status__name"))),
  ("P9 cjoin on FK field, then on() short form/both conditions",
   (q, mod) -> (q.cjoin("status_id" => "Status", warn = false, filters = ["name" => "Y"]);
                q.on("status", "statusid" => 3); q.values("resultid", "status__name"))),
  ("P9 on() short form, then cjoin on FK field/both conditions",
   (q, mod) -> (q.on("status", "statusid" => 3);
                q.cjoin("status_id" => "Status", warn = false, filters = ["name" => "Y"]); q.values("resultid", "status__name"))),
  # A ManyToMany hop: its join goes through a link table the ON predicate was never attached to.
  ("P8 on() ManyToMany hop/traversed",
   (q, mod) -> (q.on("driverid__sponsors", "name" => "X"); q.values("resultid", "driverid__sponsors__name"))),
  ("P8 on() ManyToMany hop/unreached",
   (q, mod) -> (q.on("driverid__sponsors", "name" => "X"); q.values("resultid"))),
  # `cjoin_on` is recorded, not changed, by #977.
  ("P7 cjoin_on/Joined anchor + predicate",
   (q, mod) -> (q.cjoin_on("Driver", alias = "d2", on = [Joined("d2", "driverid") == F("driverid"), Joined("d2", "code") => "X"]);
                q.values("resultid"))),
  # #982: the shapes the relocation pass existed for. A `cjoin_on` condition may name the base row, a
  # path join, or another `cjoin_on` alias, and where each lands is recorded here.
  ("P7 cjoin_on/base column against Joined",
   (q, mod) -> (q.cjoin_on("Driver", alias = "d2", on = [Joined("d2", "number") == F("number")]); q.values("resultid"))),
  # A path nothing else reaches: its join is built while the ON renders, after `d2`.
  ("P7 cjoin_on/deep path predicate, unreached",
   (q, mod) -> (q.cjoin_on("Driver", alias = "d2", on = [Joined("d2", "driverid") == F("driverid"), "driverid__code" => "X"]);
                q.values("resultid"))),
  # The same path, already projected: its join exists before `d2`.
  ("P7 cjoin_on/deep path predicate, projected",
   (q, mod) -> (q.cjoin_on("Driver", alias = "d2", on = [Joined("d2", "driverid") == F("driverid"), "driverid__code" => "X"]);
                q.values("resultid", "driverid__code"))),
  ("P7 cjoin_on/deep path predicate, LEFT",
   (q, mod) -> (q.cjoin_on("Driver", alias = "d2", join_type = "LEFT",
                           on = [Joined("d2", "driverid") == F("driverid"), "driverid__code" => "X"]);
                q.values("resultid"))),
  # #992: a to-many hop on the path. Built first, it would repeat every base row once per related row
  # under any join type, so it is refused; the forward cells above stay as they render.
  ("P7 cjoin_on/reverse path predicate (#992)",
   (q, mod) -> (q.cjoin_on("Driver", alias = "d2", join_type = "LEFT",
                           on = [Joined("d2", "driverid") == F("driverid"), "driverid__results__grid" => 1]);
                q.values("resultid"))),
  ("P7 cjoin_on/ManyToMany path predicate (#992)",
   (q, mod) -> (q.cjoin_on("Driver", alias = "d2", join_type = "LEFT",
                           on = [Joined("d2", "driverid") == F("driverid"), "driverid__sponsors__name" => "X"]);
                q.values("resultid"))),
  # The only predicate correlates the alias with a path join (#435's shape).
  ("P7 cjoin_on/Joined against deep path F",
   (q, mod) -> (q.cjoin_on("Driver", alias = "d2", on = [Joined("d2", "code") == F("driverid__code")]); q.values("resultid"))),
  # #421's shape for `cjoin_on`: literals on the alias and on a path join, the path one listed first.
  ("P7 cjoin_on/two rows bind, path first (#421)",
   (q, mod) -> (q.cjoin_on("Driver", alias = "d2",
                           on = ["driverid__code" => "A", Joined("d2", "driverid") == F("driverid"), Joined("d2", "code") => "B"]);
                q.values("resultid"))),
  # Two aliases, the second naming the first: declaration order is dependency order (#449).
  ("P7 cjoin_on/second alias names the first",
   (q, mod) -> (q.cjoin_on("Driver", alias = "d1", on = [Joined("d1", "driverid") == F("driverid")]);
                q.cjoin_on("Driver", alias = "d2", on = [Joined("d2", "number") == Joined("d1", "number")]);
                q.values("resultid"))),
  # The forward reference: the first alias names the second.
  ("P7 cjoin_on/first alias names the second",
   (q, mod) -> (q.cjoin_on("Driver", alias = "d1", on = [Joined("d1", "number") == Joined("d2", "number")]);
                q.cjoin_on("Driver", alias = "d2", on = [Joined("d2", "driverid") == F("driverid")]);
                q.values("resultid"))),
  # Each alias names the other: no order emits both.
  ("P7 cjoin_on/alias cycle",
   (q, mod) -> (q.cjoin_on("Driver", alias = "d1", on = [Joined("d1", "number") == Joined("d2", "number")]);
                q.cjoin_on("Driver", alias = "d2", on = [Joined("d2", "code") == Joined("d1", "code")]);
                q.values("resultid"))),
  # #448: no predicate names the alias's own row.
  ("P7 cjoin_on/no reference to its own alias (#448)",
   (q, mod) -> (q.cjoin_on("Driver", alias = "d2", on = ["number" => 5]); q.values("resultid"))),
)

# Every cell, flattened: (id, build). The grid is generated, so a new spelling or position is one row.
const _JCM_CELLS = vcat(
  [("$(pos)/$(sp)", (q, mod) -> attach(q, mod, cond(p, mod)))
   for (pos, p, attach) in _JCM_GRID_POSITIONS for (sp, cond) in _JCM_GRID_SPELLINGS],
  collect(_JCM_SINGLE_CELLS),
)

# The first line of an error, ANSI-stripped and cut to a stable length: the identity of a refusal, without
# pinning every word of its remedy text (that is what each issue's own test file does).
function _jcm_message(e)
  msg = replace(sprint(showerror, e), r"\e\[[0-9;]*m" => "")
  line = first(split(msg, '\n'))
  return length(line) > 120 ? first(line, 120) : String(line)
end

# What one cell does on one engine: rendered SQL + parameters, or the error and the stage it fired at.
function _jcm_observe(mod, build)
  q = mod.Result.objects
  try
    build(q, mod)
  catch e
    return (stage = :call, error = string(nameof(typeof(e))), message = _jcm_message(e))
  end
  try
    insp = inspect_query(q)
    sql = replace(insp[:sql_text], r"\s+" => " ")
    buckets = get(insp, :parameter_buckets, nothing)
    join_bucket = buckets === nothing ? nothing : get(buckets, :join, nothing)
    return (stage = :ok, sql = strip(sql), params = Any[insp[:parameters]...],
            join = join_bucket === nothing ? nothing : Any[join_bucket...])
  catch e
    return (stage = :build, error = string(nameof(typeof(e))), message = _jcm_message(e))
  end
end

const _JCM_FIXTURE = joinpath(@__DIR__, "fixtures", "join_condition_matrix_expected.jl")

if get(ENV, "PORMG_JCM_RECORD", "") == "1"
  # Record mode: write the fixture from the current code and stop. Not a test run.
  open(_JCM_FIXTURE, "w") do io
    println(io, "# GENERATED by test/unit/test_join_condition_matrix.jl with PORMG_JCM_RECORD=1 — do not edit by hand.")
    println(io, "# One entry per (cell, engine): what PormG renders or refuses. A diff here is a behaviour change (#977).")
    println(io, "const _JCM_EXPECTED = Dict{Tuple{String,Symbol},Any}(")
    for (id, build) in _JCM_CELLS, (backend, mod) in _JCM_MODELS
      println(io, "  ", repr((id, backend)), " =>\n    ", repr(_jcm_observe(mod, build)), ",")
    end
    println(io, ")")
  end
  @info "join-condition matrix recorded" path = _JCM_FIXTURE cells = length(_JCM_CELLS)
else
  include(_JCM_FIXTURE)

  # ─────────────────────────────────────────────────────────────────────────────
  # Join-condition matrix: every cell matches its recorded outcome, on both engines
  # Each (cell, engine) pair renders the recorded statement and parameters, or raises the recorded error
  # at the recorded stage. The fixture holds exactly the cells this file defines — no stale rows, none
  # missing — so a deleted cell cannot leave its expectation behind unchecked.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "#977: join-condition matrix" begin
    defined = Set((id, backend) for (id, _) in _JCM_CELLS for (backend, _) in _JCM_MODELS)
    @test defined == Set(keys(_JCM_EXPECTED))

    for (id, build) in _JCM_CELLS, (backend, mod) in _JCM_MODELS
      @testset "$backend: $id" begin
        expected = _JCM_EXPECTED[(id, backend)]
        got = _jcm_observe(mod, build)
        # Field by field, so a failure names the part that moved (stage, SQL, parameters, message).
        @test got.stage == expected.stage
        for k in keys(expected)
          @test get(got, k, missing) == expected[k]
        end
      end
    end
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # Join conditions: a correlated UPDATE ... FROM refuses one rather than dropping it (#977)
  # Setting a column from a joined table renders the join in the WHERE clause, key columns only. An
  # `on()` condition there was dropped (main: the UPDATE ignored it; with `on()` building its join, the
  # values outnumbered the markers). Refused, as `cjoin_on` (#45) and a CTE (#394) already are.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "#977: a correlated UPDATE ... FROM refuses a join condition" begin
    for (backend, mod) in _JCM_MODELS
      q = mod.Result.objects
      q.on("driverid", "code" => "X")
      q.filter("grid" => 3)
      err = try q.update("number" => F("driverid__number"), show_query = :inspection); nothing catch e; e end
      @test err isa QueryBuildError
      @test occursin("correlated UPDATE ... FROM", _jcm_message(err))
      # Control: the same update with no join condition still renders.
      ok = mod.Result.objects
      ok.filter("grid" => 3)
      @test ok.update("number" => F("driverid__number"), show_query = :inspection) isa AbstractDict
    end
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # Join-condition matrix: SQLite binds in the order PostgreSQL numbers (#421)
  # For every cell that renders, the PostgreSQL `$N` markers read in text order, applied to its parameter
  # vector, give the order SQLite's positional `?` markers must bind in. A relocated ON fragment that
  # bound its neighbour's value (#421) breaks exactly this.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "#977: join-condition matrix, #421 differential" begin
    for (id, build) in _JCM_CELLS
      pg = _jcm_observe(JcmPGModels, build)
      sl = _jcm_observe(JcmSLModels, build)
      # Only rendering cells carry parameters; a refusal must refuse on both engines alike.
      @test pg.stage == sl.stage
      pg.stage == :ok || continue
      @testset "$id" begin
        text_order = [parse(Int, m[1]) for m in eachmatch(r"\$(\d+)", pg.sql)]
        @test pg.params[text_order] == sl.params
        @test count(==('?'), sl.sql) == length(sl.params)
      end
    end
  end
end
