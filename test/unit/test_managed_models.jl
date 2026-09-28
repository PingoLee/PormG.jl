"""
UNIT TESTS: `managed = false` — a model PormG queries but never migrates (#741)

Django's `Meta.managed = False`: a model mapped onto a view, or onto a table another system owns.
Before #741 there was no such model. A declared model over a view planned `CREATE TABLE IF NOT
EXISTS` on every `makemigrations` (views are invisible to introspection, so the table never "exists"),
and an external table was either declared — and then altered and, on SQLite, rebuilt — or left
undeclared, and then planned as a `DROP TABLE`.

What the option guarantees, and what each testset below proves against the unpatched code:

  * the planner never creates, alters, renames or drops an unmanaged model's table, and never offers
    it as a rename candidate (`_exclude_unmanaged_models!`);
  * a managed model's foreign key into an unmanaged one must say `db_constraint = false` — refused at
    `set_models` AND at `makemigrations`, which never calls `set_models`;
  * an auto many-to-many join table is unmanaged only when both ends are (Django's rule);
  * queries, joins and `__` traversal through an unmanaged model are unchanged;
  * `Model_to_str` and the Django importer carry the option.

Hermetic: temp or in-memory SQLite, plus a PostgreSQL stand-in for plan-shape checks. The live
PostgreSQL half (a real view) is in `test/integration/test_importers_introspection.jl`.

`_mm`-prefixed throughout: `runtests.jl` includes every unit file into ONE module.
"""

using Test
using Logging
using DataFrames
using PormG
using PormG.Models
using PormG.Migrations
import PormG: PormGModel, PormGPostgres, model_table_name, model_is_managed
isdefined(Main, :SQLite) || include(joinpath(@__DIR__, "..", "load_drivers.jl"))
import PormG.ConnectionPool: SQLiteConnectionPool, fetch, close_pool!
import PormG.Migrations: LiveTable, read_live_schema, get_migration_plan

# ─────────────────────────────────────────────────────────────────────────────
# Harness
# ─────────────────────────────────────────────────────────────────────────────

# PostgreSQL stand-in: no catalog, so every planner lookup answers "nothing there".
struct ManagedMockPg741 <: PormGPostgres end
const MM_PG = ManagedMockPg741()
fetch(::ManagedMockPg741, sql::String; conn = nothing, params = nothing, ignore_tx::Bool = false) = DataFrame()
PormG.config["mm_mock_pg741"] = PormG.Configuration.Settings(
  connections = MM_PG, change_data = true, db_def_folder = "mm_mock_pg741")

function _mm_schema(models::PormGModel...)
  schema = Dict{Symbol, Dict{Symbol, Union{Bool, PormGModel}}}()
  for m in models
    schema[Symbol(model_table_name(m))] = Dict{Symbol, Union{Bool, PormGModel}}(:model => m, :exist => false)
  end
  return schema
end

function _mm_settings()
  settings = PormG.Configuration.Settings()
  settings.change_db = true
  return settings
end

# Plan `declared` against `live`. With `answers`, the rename prompts read them from stdin and the
# prompt text lands in `transcript` (a file, since `redirect_stdout` needs one).
function _mm_plan(conn, live, declared::PormGModel...; answers::Union{String, Nothing} = nothing,
                  transcript::Union{String, Nothing} = nothing)
  schema = _mm_schema(declared...)
  answers === nothing && return get_migration_plan(live, schema, conn, _mm_settings(); interactive = false)
  path, io = mktemp(); write(io, answers); close(io)
  out = transcript === nothing ? devnull : transcript
  return open(path) do f
    redirect_stdin(f) do
      open(out, "w") do o
        redirect_stdout(o) do
          get_migration_plan(live, schema, conn, _mm_settings(); interactive = true)
        end
      end
    end
  end
end

_mm_live(pool) = read_live_schema(pool)

# Apply a plan in `migrate`'s order. Naive `;` splitting is safe: DDL over identifiers this file chose.
function _mm_apply!(pool, plan)
  ordered, _ = Migrations._order_statements(collect(values(plan)))
  for sql in ordered, stmt in split(sql, ";")
    s = strip(stmt)
    isempty(s) || fetch(pool, s * ";")
  end
  return nothing
end

_mm_text(plan) = join((join(values(steps), "\n") for steps in values(plan)), "\n")
_mm_converged(pool, declared...) = all(isempty, values(_mm_plan(pool, _mm_live(pool), declared...)))

# Evaluate a generated model declaration in a throwaway module and hand back the model.
function _mm_reload(src::AbstractString)
  mod = Module()
  Core.eval(mod, :(import PormG.Models))
  return Core.eval(mod, Meta.parse(src))
end

# The F1 shapes the testsets share.
_mm_driver() = Models.Model("driver"; driverid = Models.IDField(), surname = Models.CharField(max_length = 40))
_mm_result(driver) = Models.Model("result"; resultid = Models.IDField(),
  driverid = Models.ForeignKey(driver, pk_field = "driverid"), points = Models.FloatField())

# ─────────────────────────────────────────────────────────────────────────────
# managed: the option is a Bool, peeled before the field slurp (#741)
# `managed` joins MODEL_OPTION_KWARGS, so it is read as the option, never as a column — and a column
# of that name must move to `db_column`, failing loudly and naming the fix. Anything but a Bool is
# refused: a truthy stand-in would read as the opposite of what was meant, and the cost of that is
# the planner dropping a table another system owns.
# ─────────────────────────────────────────────────────────────────────────────
@testset "managed: the option is a Bool, peeled before the field slurp (#741)" begin
  # Unset, a model is managed — every model declared before the option existed stays so.
  @test model_is_managed(_mm_driver())
  @test "managed" in PormG.MODEL_OPTION_KWARGS

  # Both constructor forms take it, and `true` is accepted explicitly.
  view_model = Models.Model("driver_points_v"; managed = false, id = Models.IDField())
  @test !model_is_managed(view_model)
  @test !model_is_managed(Models.Model(; managed = false, id = Models.IDField()))
  @test model_is_managed(Models.Model("driver"; managed = true, id = Models.IDField()))

  # Not a Bool: refused — an integer, a string, a symbol all read as something other than meant.
  for bad in (0, "false", :no)
    err = try Models.Model("feed"; managed = bad, id = Models.IDField()) catch e; e end
    @test err isa PormG.ModelDefinitionError
    @test occursin("true or false", sprint(showerror, err))
  end

  # A COLUMN named `managed` is read as the option — a field struct is not a Bool — and the error
  # names the escape hatch, which does declare the column.
  err = try Models.Model("contract"; id = Models.IDField(), managed = Models.BooleanField()) catch e; e end
  @test err isa PormG.ModelDefinitionError
  @test occursin("db_column", sprint(showerror, err))
  ok = Models.Model("contract"; id = Models.IDField(), is_managed = Models.BooleanField(db_column = "managed"))
  @test Models.field_db_column(ok.fields["is_managed"], "is_managed") == "managed"
  @test model_is_managed(ok)
end

# ─────────────────────────────────────────────────────────────────────────────
# managed: Model_to_str round-trips `managed = false` (#741)
# A generated models file reloads through the kwargs constructor, so an unmanaged model that lost the
# option on the way out would come back managed — and its view would be planned as a table. A managed
# model's line must stay byte-identical to before the option existed.
# ─────────────────────────────────────────────────────────────────────────────
@testset "managed: Model_to_str round-trips managed = false (#741)" begin
  unmanaged = Models.Model("driver_points_v"; managed = false,
    id = Models.IDField(), points = Models.FloatField())
  src = Models.Model_to_str(unmanaged)
  @test occursin("Models.Model(\"driver_points_v\", managed = false,", src)
  @test !model_is_managed(_mm_reload(src))

  # Beside db_table, and still after it.
  pinned = Models.Model("driver_points_v"; managed = false, db_table = "Driver_Points_V",
    id = Models.IDField())
  @test occursin("db_table = \"Driver_Points_V\", managed = false,", Models.Model_to_str(pinned))

  # A managed model never mentions the option.
  @test !occursin("managed", Models.Model_to_str(_mm_driver()))
end

# ─────────────────────────────────────────────────────────────────────────────
# SQLite: an unmanaged model's table is never altered, and never dropped (#741)
# The table another system owns: its live columns differ from the declaration (a model need only
# declare the columns it reads). Declared unmanaged, it plans nothing — not the column diff, not its
# composites. The two controls run the same database through the planner without the option, and
# prove the testset would fail unpatched: declared managed, the table is altered; undeclared, it is
# dropped.
# ─────────────────────────────────────────────────────────────────────────────
@testset "SQLite: an unmanaged model's table is never altered, and never dropped (#741)" begin
  mktempdir() do dir
    pool = SQLiteConnectionPool(joinpath(dir, "mm_external.sqlite"); pool_size = 1)
    try
      # Owned by another system: an extra column and a wider shape than the model reads.
      fetch(pool, "CREATE TABLE \"feed_standings\" (\"id\" INTEGER PRIMARY KEY, \"driverid\" INTEGER, " *
                  "\"points\" REAL, \"source_batch\" TEXT);")
      driver = _mm_driver()
      declared(; managed) = Models.Model("feed_standings"; managed = managed,
        id = Models.IDField(), points = Models.FloatField(null = true),
        constraints = [Models.UniqueConstraint(fields = ("points",))])

      # Unmanaged: only the managed model is planned, and the external table is untouched by it.
      plan = _mm_plan(pool, _mm_live(pool), driver, declared(managed = false))
      @test collect(keys(plan)) == [:driver]
      _mm_apply!(pool, plan)
      @test _mm_converged(pool, driver, declared(managed = false))
      cols = Set(String(r.name) for r in eachrow(DataFrame(fetch(pool, "SELECT name FROM pragma_table_info('feed_standings');"))))
      @test cols == Set(["id", "driverid", "points", "source_batch"])

      # Control 1 — declared MANAGED, the same table is diffed: its extra columns are dropped and its
      # composite created. This is what the option switches off.
      managed_plan = _mm_plan(pool, _mm_live(pool), driver, declared(managed = true))
      @test haskey(managed_plan, :feed_standings)
      @test !isempty(managed_plan[:feed_standings])

      # Control 2 — undeclared, the table is dropped.
      undeclared_plan = _mm_plan(pool, _mm_live(pool), driver)
      @test occursin("DROP TABLE", _mm_text(undeclared_plan))
      @test !occursin("DROP TABLE", _mm_text(plan))
    finally
      close_pool!(pool)
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# SQLite: an unmanaged table is never offered as a rename candidate (#741)
# A managed model with no table asks which vanished table it was renamed from. The unmanaged table
# sorts FIRST in the live catalog, so were it still a candidate it would be number 1 and the scripted
# answer "1" would rename the external table into `result`. It is not: the only candidate is the
# genuinely renamed `results_old`.
# ─────────────────────────────────────────────────────────────────────────────
@testset "SQLite: an unmanaged table is never offered as a rename candidate (#741)" begin
  mktempdir() do dir
    pool = SQLiteConnectionPool(joinpath(dir, "mm_rename.sqlite"); pool_size = 1)
    try
      driver = _mm_driver()
      _mm_apply!(pool, _mm_plan(pool, LiveTable[], driver))
      fetch(pool, "CREATE TABLE \"a_feed\" (\"id\" INTEGER PRIMARY KEY, \"points\" REAL);")
      fetch(pool, "CREATE TABLE \"results_old\" (\"resultid\" INTEGER PRIMARY KEY, " *
                  "\"driverid_id\" INTEGER, \"points\" REAL NOT NULL);")
      feed = Models.Model("a_feed"; managed = false, id = Models.IDField(), points = Models.FloatField())
      result = Models.Model("result"; resultid = Models.IDField(), driverid_id = Models.IntegerField(null = true),
                            points = Models.FloatField())

      transcript = joinpath(dir, "prompt.txt")
      plan = _mm_plan(pool, _mm_live(pool), driver, feed, result; answers = "1\n", transcript = transcript)
      prompt = read(transcript, String)
      # The candidate list names the renamed table and never the unmanaged one.
      @test occursin("results_old", prompt)
      @test !occursin("a_feed", prompt)
      @test occursin("ALTER TABLE \"results_old\" RENAME TO \"result\"", _mm_text(plan))
      @test !occursin("a_feed", _mm_text(plan))
    finally
      close_pool!(pool)
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# SQLite: an index name an unmanaged table holds is still refused (#741)
# The planner filters unmanaged tables out of the live list it CLASSIFIES, but the whole-plan checks
# must still see them: an index name is unique per database, so a managed model declaring the name an
# unmanaged table's index already holds must be refused at plan time, not fail at `migrate`. The
# database holds ONLY the unmanaged table, so this also takes the full path rather than the
# empty-database shortcut — which runs none of the whole-plan checks.
# ─────────────────────────────────────────────────────────────────────────────
@testset "SQLite: an index name an unmanaged table holds is still refused (#741)" begin
  mktempdir() do dir
    pool = SQLiteConnectionPool(joinpath(dir, "mm_names.sqlite"); pool_size = 1)
    try
      fetch(pool, "CREATE TABLE \"a_feed\" (\"id\" INTEGER PRIMARY KEY, \"points\" REAL, \"grid\" INTEGER);")
      fetch(pool, "CREATE INDEX \"shared_idx\" ON \"a_feed\" (\"points\", \"grid\");")
      feed = Models.Model("a_feed"; managed = false, id = Models.IDField(), points = Models.FloatField())
      result = Models.Model("result"; resultid = Models.IDField(), points = Models.FloatField(),
        grid = Models.IntegerField(), indexes = [Models.Index(fields = ("points", "grid"), name = "shared_idx")])
      err = try _mm_plan(pool, _mm_live(pool), feed, result); nothing catch e; e end
      @test err isa PormG.InvalidMigrationError
      @test occursin("shared_idx", sprint(showerror, err))
      @test occursin("a_feed", sprint(showerror, err))
    finally
      close_pool!(pool)
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# SQLite: a model over a view — planned as nothing, queried like any model (#741)
# The case the issue opens with. A view is not in the live table list, so a MANAGED model over it
# plans `CREATE TABLE` on every run (the control). Unmanaged, it plans nothing — and the query side
# is unchanged: a filter across its `db_constraint = false` key into a managed model, and a `__`
# traversal, return the view's rows.
# ─────────────────────────────────────────────────────────────────────────────
const _MM_VIEW_KEY = normpath(joinpath(@__DIR__, "pormg741_managed"))
const _MM_VIEW_POOL = SQLiteConnectionPool(":memory:"; pool_size = 1)
PormG.config[_MM_VIEW_KEY] = PormG.Configuration.Settings(
  connections = _MM_VIEW_POOL, change_data = true, db_def_folder = _MM_VIEW_KEY)

PormG.@models_module Managed741 "pormg741_managed" begin
  Driver = Models.Model("driver"; driverid = Models.IDField(), surname = Models.CharField(max_length = 40))
  Result = Models.Model("result"; resultid = Models.IDField(),
    driverid = Models.ForeignKey(Driver, pk_field = "driverid"), points = Models.FloatField())
  # The view exposes `driverid` twice: as its key, and as the reference traversed below.
  Driver_points = Models.Model("driver_points_v"; managed = false,
    id = Models.IDField(),
    driverid = Models.ForeignKey(Driver, pk_field = "driverid", db_constraint = false),
    points = Models.FloatField())
end
import .Managed741 as MMV

@testset "SQLite: a model over a view — planned as nothing, queried like any model (#741)" begin
  _mm_apply!(_MM_VIEW_POOL, _mm_plan(_MM_VIEW_POOL, LiveTable[], MMV.Driver, MMV.Result))
  fetch(_MM_VIEW_POOL, "CREATE VIEW \"driver_points_v\" AS SELECT \"driverid\" AS \"id\", \"driverid\", " *
                       "SUM(\"points\") AS \"points\" FROM \"result\" GROUP BY \"driverid\";")

  # Unmanaged: nothing to do, and nothing to do again.
  live = _mm_live(_MM_VIEW_POOL)
  @test all(isempty, values(_mm_plan(_MM_VIEW_POOL, live, MMV.Driver, MMV.Result, MMV.Driver_points)))

  # Control: the same view under a MANAGED twin is planned as a table, every run.
  twin = Models.Model("driver_points_v"; id = Models.IDField(), points = Models.FloatField())
  @test occursin("CREATE TABLE", _mm_text(_mm_plan(_MM_VIEW_POOL, live, MMV.Driver, MMV.Result, twin)))

  # The query side does not know the option exists.
  senna = MMV.Driver.objects.create("surname" => "Senna")
  prost = MMV.Driver.objects.create("surname" => "Prost")
  MMV.Result.objects.create("driverid" => senna["driverid"], "points" => 9.0)
  MMV.Result.objects.create("driverid" => senna["driverid"], "points" => 6.0)
  MMV.Result.objects.create("driverid" => prost["driverid"], "points" => 4.0)

  rows = MMV.Driver_points.objects.
    filter("driverid__surname" => "Senna").
    values("points", "driverid__surname").
    list()
  @test length(rows) == 1
  @test rows[1][:points] == 15.0
  @test rows[1][:driverid__surname] == "Senna"
  @test MMV.Driver_points.objects.filter("points__@gte" => 5).count() == 1
end

# ─────────────────────────────────────────────────────────────────────────────
# managed: a constrained foreign key into an unmanaged model is refused (#741)
# The target may be a view, which a foreign key cannot reference, so a managed model must spell
# `db_constraint = false`. One predicate, two raise sites: `set_models` at registration, and the
# planner, because `makemigrations` loads models without ever calling `set_models`. A key FROM an
# unmanaged model is never checked — its table is never migrated.
# ─────────────────────────────────────────────────────────────────────────────
@testset "managed: a constrained foreign key into an unmanaged model is refused (#741)" begin
  standings = Models.Model("driver_points_v"; managed = false, id = Models.IDField(), points = Models.FloatField())
  constrained = Models.Model("award"; id = Models.IDField(),
    standing = Models.ForeignKey(standings, pk_field = "id"))
  loose = Models.Model("award"; id = Models.IDField(),
    standing = Models.ForeignKey(standings, pk_field = "id", db_constraint = false))

  # The planner refuses it — before the empty-database shortcut, so a brand-new table is covered —
  # naming the field and the fix.
  err = try _mm_plan(MM_PG, LiveTable[], standings, constrained) catch e; e end
  @test err isa PormG.InvalidMigrationError
  msg = sprint(showerror, err)
  @test occursin("award.standing", msg)
  @test occursin("db_constraint = false", msg)

  # `db_constraint = false` plans the table and no REFERENCES into the view; the view is not planned.
  plan = _mm_plan(MM_PG, LiveTable[], standings, loose)
  @test collect(keys(plan)) == [:award]
  @test !occursin("REFERENCES", _mm_text(plan))

  # set_models refuses the same declaration, as a collected contradiction.
  mod = Module(:ManagedFkRule741)
  Core.eval(mod, :(import PormG, PormG.Models))
  Core.eval(mod, :(Driver_points = $standings))
  Core.eval(mod, :(Award = $(Models.Model(; id = Models.IDField(),
    standing = Models.ForeignKey(standings, pk_field = "id")))))
  err = try PormG.Models.set_models(mod, "mm_mock_pg741") catch e; e end
  @test err isa PormG.ModelDefinitionError
  @test occursin("unmanaged model 'driver_points_v'", sprint(showerror, err))

  # A key FROM the unmanaged model is fine: nothing of that table is ever rendered.
  back = Models.Model("driver_points_v"; managed = false, id = Models.IDField(),
    driverid = Models.ForeignKey(_mm_driver(), pk_field = "driverid"))
  @test collect(keys(_mm_plan(MM_PG, LiveTable[], _mm_driver(), back))) == [:driver]
end

# ─────────────────────────────────────────────────────────────────────────────
# managed: an auto many-to-many join table is unmanaged only when both ends are (#741)
# Django's rule. Between two unmanaged models there is no join table to create. With one managed end
# the table is created, and its key into the unmanaged end carries no constraint — so the table
# plans at all, instead of tripping the rule above.
# ─────────────────────────────────────────────────────────────────────────────
@testset "managed: an auto many-to-many join table is unmanaged only when both ends are (#741)" begin
  circuits = Models.Model("circuit_feed"; managed = false, id = Models.IDField(), name = Models.CharField(max_length = 40))

  both = Models.Model("race_feed"; managed = false, id = Models.IDField(),
    circuits = Models.ManyToManyField(circuits))
  @test isempty(_mm_plan(MM_PG, LiveTable[], circuits, both))

  one = Models.Model("race"; id = Models.IDField(), circuits = Models.ManyToManyField(circuits))
  plan = _mm_plan(MM_PG, LiveTable[], circuits, one)
  @test Set(keys(plan)) == Set([:race, :race_circuits])
  through = join(values(plan[:race_circuits]), "\n")
  @test occursin("CREATE TABLE", through)
  # The key into the managed end is constrained; the key into the unmanaged end is not.
  @test occursin("REFERENCES \"race\"", through)
  @test !occursin("REFERENCES \"circuit_feed\"", through)
end

# ─────────────────────────────────────────────────────────────────────────────
# Django importer: Meta.managed = False becomes managed = false (#741)
# Before #741 the option was dropped as "no PormG equivalent", so an imported unmanaged Django model
# became a managed PormG one — and its view or external table was planned as PormG's own. It is
# inherited from an abstract base, as in Django; a value that is not a literal cannot be decided, so
# it is reported and the model stays managed.
# ─────────────────────────────────────────────────────────────────────────────
@testset "Django importer: Meta.managed = False becomes managed = false (#741)" begin
  source = """
  from django.db import models

  class LegacyBase(models.Model):
      class Meta:
          abstract = True
          managed = False

  class DriverPoints(models.Model):
      points = models.FloatField()

      class Meta:
          managed = False
          db_table = "driver_points_v"

  class FeedRow(LegacyBase):
      payload = models.CharField(max_length=40)

  class Award(models.Model):
      label = models.CharField(max_length=40)
      standing = models.ForeignKey(DriverPoints, on_delete=models.CASCADE)

  class Circuit(models.Model):
      name = models.CharField(max_length=40)

      class Meta:
          managed = True

  class Lap(models.Model):
      lap = models.IntegerField()

      class Meta:
          managed = settings.LAPS_MANAGED
  """
  config_key = mktempdir()
  db_dir_existed = isdir(PormG.MODEL_PATH)
  PormG.config[config_key] = PormG.Configuration.Settings(db_def_folder = config_key)
  try
    logs, _ = Test.collect_test_logs() do
      import_models_from_django(source; db = config_key, file = "managed741.jl", force_replace = true)
    end
    generated = read(joinpath(config_key, "managed741.jl"), String)

    @test occursin("Models.Model(\"driverpoints\", db_table = \"driver_points_v\", managed = false,", generated)
    @test occursin("Models.Model(\"feedrow\", managed = false,", generated)   # inherited
    @test occursin("Models.Model(\"circuit\",", generated)
    @test !occursin("Models.Model(\"circuit\", managed", generated)
    # Not a literal: the model stays managed, and both the log and the file say so.
    @test !occursin("Models.Model(\"lap\", managed", generated)
    @test occursin("# PormG: Meta.managed on 'Lap' is not True or False", generated)
    @test any(r -> r.level == Logging.Warn && occursin("Meta.managed", string(r.message)), logs)
    # A managed model's key into an unmanaged one: Django allows the constraint, PormG does not (the
    # target may be a view), so it is imported without it — or the generated file would not load.
    standing = only(filter(l -> occursin("Models.ForeignKey", l) && occursin("standing", l), split(generated, '\n')))
    @test occursin("db_constraint=false", standing)
    @test occursin("# PormG: 'Award.standing_id' points at the unmanaged 'DriverPoints'", generated)
    @test any(r -> r.level == Logging.Warn && occursin("unmanaged model is imported without", string(r.message)), logs)
    # Consumed, so never reported as a dropped option.
    dropped = [get(Dict(r.kwargs), :option, nothing) for r in logs
               if r.level == Logging.Warn && occursin("Meta option", string(r.message))]
    @test !("managed" in dropped)
  finally
    delete!(PormG.config, config_key)
    isdir(config_key) && rm(config_key; recursive = true)
    if !db_dir_existed && isdir(PormG.MODEL_PATH) && isempty(readdir(PormG.MODEL_PATH))
      rm(PormG.MODEL_PATH)
    end
  end
end
