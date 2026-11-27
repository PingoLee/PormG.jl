# ============================================================
# test/unit/test_m2m_recorded_model_1689.jl
#
# CONTRACT being tested:
#   The query builder reads the model a relation recorded at registration, never a model found by name in a module
#   (#1689, #1599 layer 5):
#     - the reverse many-to-many hop joins the owner model the relation recorded, for a relation declared across two
#       modules (it raised `QueryBuildError`) and when the target's module binds another model under the owner's name
#       (it joined that model's table);
#     - the models `_from_column_names` takes from the base model's module are the ones its model set declares, the
#       same models the old scan of the module's names found, for every module registered in this process.
#
# Hermetic: mock connections, no database.
#
# Run: julia --project=test/integration test/unit/test_m2m_recorded_model_1689.jl
# ============================================================

using Test
isdefined(Main, :SQLite) || include(joinpath(@__DIR__, "..", "load_drivers.jl"))
using PormG

const _MR_QB = PormG.QueryBuilder

struct MrMockPostgres <: PormG.PormGPostgres end
struct MrMockSQLite <: PormG.PormGSQLite end
PormG.backend_sqlite_version(::MrMockSQLite) = 3045000
PormG.config["mr1689"] = PormG.Configuration.Settings(connections = MrMockPostgres(), change_data = true,
                                                      db_def_folder = "mr1689")

# The drivers' module, registered first. It also binds a model named `Race` of its own (another table), the shape where
# the by-name lookup found the wrong model.
module Mr1689People
import PormG
import PormG.Models
Driver::Models.ModelType = Models.Model("mr1689_driver",
  driverid = Models.IDField(),
  surname  = Models.CharField(max_length = 40),
)
Race::Models.ModelType = Models.Model("mr1689_people_race",
  raceid = Models.IDField(),
  label  = Models.CharField(max_length = 40),
)
Models.@models Driver Race
PormG.Models.set_models(@__MODULE__, "mr1689")
end

# The races' module: `Race` declares its drivers across the module boundary.
module Mr1689Races
import PormG
import PormG.Models
import ..Mr1689People
Circuit::Models.ModelType = Models.Model("mr1689_circuit",
  circuitid = Models.IDField(),
  name      = Models.CharField(max_length = 80),
)
Race::Models.ModelType = Models.Model("mr1689_race",
  raceid    = Models.IDField(),
  year      = Models.IntegerField(),
  name      = Models.CharField(max_length = 80),
  circuitid = Models.ForeignKey(Circuit, pk_field = "circuitid"),
  drivers   = Models.ManyToManyField(Mr1689People.Driver, related_name = "races"),
)
Models.@models Circuit Race
PormG.Models.set_models(@__MODULE__, "mr1689")
end

const _MR_CONNS = (MrMockPostgres(), MrMockSQLite())
_mr_sql(q, conn) = _MR_QB.query(q; connection = conn, show_query = :sql)

# What: a filter through the reverse many-to-many accessor (`Driver` → `races`) of a relation `Race` declares in another
#   module, on each engine, and the same through the forward accessor.
#   An `on()` join path through the reverse accessor and on to the race's circuit.
# Expected: the statement joins `mr1689_race`, the table of the model the relation recorded, through the link table; never
#   `mr1689_people_race`, the table of the other `Race` bound in the drivers' module. The hop's answer is the recorded model,
#   so `on("races__circuitid", …)` meets the many-to-many refusal (#977), not the other model. The forward hop joins the
#   drivers.
# Why: the hop looked the owner up by its binding name in the target's module: in `Mr1689People`, `Race` is the other
#   model, so every walk over the path continued from it (`on("races__circuitid", …)` raised "not a relation on model
#   'mr1689_people_race'"), and with no such binding the hop raised `QueryBuildError` (#1689).
@testset "a reverse many-to-many hop joins the model the relation recorded (#1689)" begin
  rel = Mr1689People.Driver.related_objects["races"]
  @test rel isa PormG.Models.ManyToManyRelation && rel.related_model_resolved === Mr1689Races.Race
  @test _MR_QB._relation_step(getfield(Mr1689People.Driver.objects, :object), Mr1689People.Driver, "races", true)[2] ===
        Mr1689Races.Race
  # `on()` across a many-to-many is refused by design (#977); the refusal now names the relation, where the walk from the
  # wrong model refused the circuit as "not a relation on model 'mr1689_people_race'".
  msg = try
    _mr_sql(Mr1689People.Driver.objects.on("races__circuitid", "name" => "Circuit de Monaco").
              values("surname", "cn" => "races__circuitid__name"), _MR_CONNS[1]); ""
  catch e
    e isa PormG.QueryBuildError || rethrow()
    sprint(showerror, e)
  end
  @test (occursin("ManyToMany relation 'races'", msg), occursin("mr1689_people_race", msg)) == (true, false)
  for conn in _MR_CONNS
    sql = _mr_sql(Mr1689People.Driver.objects.filter("races__year" => 2009).values("surname").distinct(), conn)
    @test (typeof(conn), occursin("mr1689_race", sql), occursin("mr1689_people_race", sql)) ==
          (typeof(conn), true, false)
    fwd = _mr_sql(Mr1689Races.Race.objects.filter("drivers__surname" => "Button").values("name").distinct(), conn)
    @test (typeof(conn), occursin("mr1689_driver", fwd)) == (typeof(conn), true)
  end
end

# What: the same reverse hop when the drivers' module binds no `Race` at all (a module of its own, registered first).
# Expected: the statement renders and joins the recorded owner's table.
# Why: the by-name lookup raised `QueryBuildError` ("No model is bound as `Race2` …") for a relation registration had
#   accepted (#1689).
module Mr1689Teams
import PormG
import PormG.Models
Team::Models.ModelType = Models.Model("mr1689_team", teamid = Models.IDField(), name = Models.CharField(max_length = 40))
Models.@models Team
PormG.Models.set_models(@__MODULE__, "mr1689")
end
module Mr1689Seasons
import PormG
import PormG.Models
import ..Mr1689Teams
Race2::Models.ModelType = Models.Model("mr1689_race2", raceid = Models.IDField(), year = Models.IntegerField(),
  teams = Models.ManyToManyField(Mr1689Teams.Team, related_name = "races"))
Models.@models Race2
PormG.Models.set_models(@__MODULE__, "mr1689")
end
@testset "a reverse many-to-many hop across modules renders (#1689)" begin
  for conn in _MR_CONNS
    sql = _mr_sql(Mr1689Teams.Team.objects.filter("races__year" => 2009).values("name").distinct(), conn)
    @test (typeof(conn), occursin("mr1689_race2", sql)) == (typeof(conn), true)
  end
end

# The models the old `_from_column_names` scan found in a module: every binding of a model (base `a9255fc05`).
function _mr_old_module_models(mod::Module)
  out = Base.IdSet{PormG.PormGModel}()
  for n in names(mod; all = true)
    isdefined(mod, n) && (m = getfield(mod, n)) isa PormG.PormGModel && push!(out, m)
  end
  return out
end
function _mr_new_module_models(mod::Module)
  out = Base.IdSet{PormG.PormGModel}()
  set = PormG.Models._model_set(mod)
  set === nothing && return out
  for (_, m) in PormG.Models._declared_models(set)
    push!(out, m)
  end
  return out
end

# What: for every module registered in this process (in the full unit suite, every test's models), the models its set
#   declares against the models the old scan of its names found.
# Expected: the same models, so `_from_column_names` takes the same candidates and returns the same columns.
# Why: the scan looked each name up in the module at run time, which a trimmed image cannot follow (#1689); the set is
#   what registration recorded, and every model binding must be declared in it.
@testset "a module's declared models are the ones its names held (#1689)" begin
  mods = collect(keys(PormG.Models.REGISTERED_SETS))
  @test length(mods) >= 4
  for mod in mods
    old, new = _mr_old_module_models(mod), _mr_new_module_models(mod)
    @test (nameof(mod), length(new), all(m -> m in old, new) && all(m -> m in new, old)) ==
          (nameof(mod), length(old), true)
  end
end
