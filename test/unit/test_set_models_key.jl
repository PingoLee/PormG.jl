"""
`set_models(mod; key)` binds a models module to a connection key, with no folder (#1606, proposal 1
of #1599).

The folder form (`set_models(mod, "db")`) finds the key by matching the folder against the loaded
configurations, and a `register_connection` entry has no folder to match — so an application that
built its connection in code (no `connection.yml`, which a `juliac --trim` binary cannot read) could
not bind models at all. The key form takes the key directly; the record it leaves in the module's
`ModelSet` lets the self-heal and a restored image rebind by key, a dynamic entry included.

Write flags: `register_connection` builds its entry read-only and does not yet take
`change_db`/`change_data` (the configuration session adds them). Until it does, the testset that
writes sets the two fields on the entry directly, through `get_settings`.

Hermetic: an offline key, and a SQLite file in a temporary directory.

    julia --project=test/integration test/unit/test_set_models_key.jl
"""

using Test
using PormG
import PormG.Models
import PormG.Configuration
isdefined(Main, :SQLite) || include(joinpath(@__DIR__, "..", "load_drivers.jl"))

function _smk_models(name::Symbol)
  mod = Module(name)
  Core.eval(mod, quote
    import PormG.Models
    Circuit::Models.ModelType = Models.Model("smk_circuit", circuitid = Models.IDField(),
      country = Models.CharField(max_length = 50))
    Race::Models.ModelType = Models.Model("smk_race", raceid = Models.IDField(),
      year = Models.IntegerField(),
      circuitid = Models.ForeignKey(Circuit, pk_field = "circuitid", on_delete = "CASCADE"))
  end)
  Core.eval(mod, :(Models.@models Circuit Race))
  return mod
end

# ─────────────────────────────────────────────────────────────────────────────
# The key form binds by key, and refuses a key nothing registered
# What it tests: on an offline key, `set_models(mod; key)` binds both models, installs the reverse
#   accessor (`smk_race` on Circuit), records the key with no folder in the module's model set, and
#   registers the module under the key; `Race.objects` renders
#   `SELECT … FROM "smk_race" … WHERE "Tb"."year" = $1`. An unknown key raises
#   `InvalidConfigurationError` naming it and registers nothing.
# Why it matters: the folder form cannot reach a key with no folder; this is the form for a
#   configuration built in code.
# ─────────────────────────────────────────────────────────────────────────────
@testset "set_models(mod; key) binds by key and refuses an unknown key (#1606)" begin
  key = "smk_offline"
  Configuration.register_offline(key)
  try
    mod = _smk_models(:SmkOffline)
    Base.invokelatest(Models.set_models, mod; key = key)
    race = Base.invokelatest(getglobal, mod, :Race)
    circuit = Base.invokelatest(getglobal, mod, :Circuit)
    @test Models.connection_key(race) == key && Models.connection_key(circuit) == key
    @test haskey(circuit.related_objects, "smk_race")
    record = Base.invokelatest(Models._model_set, mod)
    @test (record.key, record.folder) == (key, nothing)
    @test Models.REGISTERED_MODULES[mod] == key
    @test occursin("FROM \"smk_race\"", PormG.inspect_query(race.objects.filter("year" => 2009))[:sql_text])

    # The trimmed-binary form (#1606): the application passes the set itself.
    again = _smk_models(:SmkOfflineBySet)
    set = Base.invokelatest(getglobal, again, :MODEL_SET)
    @test set isa Models.ModelSet && set.mod === again
    Models.set_models(set; key = key)
    @test Models.connection_key(Base.invokelatest(getglobal, again, :Race)) == key
    @test Models.REGISTERED_SETS[again] === set

    stray = _smk_models(:SmkUnknownKey)
    err = try Base.invokelatest(Models.set_models, stray; key = "smk_never_registered"); nothing catch e; e end
    @test err isa PormG.InvalidConfigurationError
    @test occursin("smk_never_registered", err.msg)
    @test !haskey(Models.REGISTERED_MODULES, stray)
  finally
    Configuration.unregister_connection(key)
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# A connection built in code: bind, write, read, and rebind after the entry is replaced
# What it tests: a `register_connection` SQLite entry (no `connection.yml`) binds the models by key;
#   with its write flags set (directly — see the header), `ensure_table!` creates both tables, a
#   `create` inserts a Monaco race, and `filter("circuitid__country" => "Monaco")` reads it back
#   through the join. Then the entry is unregistered and registered again (a restored image, or a
#   reconnect), the model's binding is cleared, and the first `.objects` rebinds to the same key from
#   the record — a dynamic entry, which the folder-keyed rebind refused (#683). `_register_again!`,
#   the reload's and self-heal 2a's entry point, also rebinds by key.
# Why it matters: proposal 1 settles the three sites that refused a dynamic key
#   (`_rebind_from_record`, `_bind_if_loaded`, self-heal case 2a).
# ─────────────────────────────────────────────────────────────────────────────
@testset "a register_connection key binds, writes, reads and rebinds by key (#1606)" begin
  key = "smk_sqlite"
  file = joinpath(mktempdir(), "smk.sqlite")
  Configuration.register_connection(key, file; adapter = "SQLite", env = "test", pool_size = 1)
  try
    # The write flags `register_connection` does not take yet (the configuration session's).
    settings = PormG.get_settings(key)
    settings.change_db = true
    settings.change_data = true

    mod = _smk_models(:SmkSqlite)
    Base.invokelatest(Models.set_models, mod; key = key)
    circuit = Base.invokelatest(getglobal, mod, :Circuit)
    race = Base.invokelatest(getglobal, mod, :Race)
    PormG.Migrations.ensure_table!(circuit, key)
    PormG.Migrations.ensure_table!(race, key)
    circuit.objects.create("country" => "Monaco")
    race.objects.create("year" => 2009, "circuitid" => 1)
    rows = race.objects.filter("circuitid__country" => "Monaco").values("raceid", "year").list()
    @test length(rows) == 1 && rows[1]["year"] == 2009

    # The entry replaced: unregistered and registered again under the same key.
    Configuration.unregister_connection(key)
    Configuration.register_connection(key, file; adapter = "SQLite", env = "test", pool_size = 1)
    race.connect_key = nothing
    @test Base.invokelatest(Models.ensure_model_initialized, race) === true
    @test Models.connection_key(race) == key

    circuit.connect_key = nothing
    Base.invokelatest(Models._register_again!, mod, key)
    @test Models.connection_key(circuit) == key
  finally
    Configuration.unregister_connection(key)
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# A Revise reload of a module registered by key keeps the key (review fix)
# What it tests: a models file registered with `set_models(mod; key)`, edited (a field added) and
#   reloaded the way the Revise callback does it — `reload_module_contents!` then `_register_again!` —
#   is bound to the same key with the new field. The re-run `@models` line builds a new set, which
#   carries the previous registration record. No SQL.
# Why it matters: the new set used to have an empty record, so `_register_again!` treated the key as
#   a folder and refused: after one edit the models stayed unbound for the session.
# ─────────────────────────────────────────────────────────────────────────────
@testset "a reload of a key-registered module rebinds to its key (#1606)" begin
  key = "smk_reload"
  Configuration.register_offline(key)
  dir = mktempdir()
  file = joinpath(dir, "smk_reload_models.jl")
  src(extra) = """
  module smk_reload_models
  import PormG.Models
  Circuit::Models.ModelType = Models.Model("smk_reload_circuit", circuitid = Models.IDField()$(extra))
  Models.@models Circuit
  end
  """
  write(file, src(""))
  try
    mod = Base.include(Models._with_model_set, Module(:SmkReloadHost), file)
    Base.invokelatest(Models.set_models, mod; key = key)
    write(file, src(", country = Models.CharField(null = true)"))
    @test Base.invokelatest(PormG.Utils.reload_module_contents!, mod, file)
    Base.invokelatest(Models._register_again!, mod, key)
    circuit = Base.invokelatest(getglobal, mod, :Circuit)
    @test haskey(circuit.fields, "country")
    @test Models.connection_key(circuit) == key
    record = Base.invokelatest(Models._model_set, mod)
    @test (record.key, record.folder) == (key, nothing)
  finally
    Configuration.unregister_connection(key)
  end
end
