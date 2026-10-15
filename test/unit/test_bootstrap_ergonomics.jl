"""
Unit coverage for the bootstrap ergonomics of #1232: `load` fails at boot when the adapter's driver
extension is not loaded, a per-key `before_connect` hook, the function form `PormG.import_models`,
and the positional `Configuration.connection(key)`. (The fifth item, a blank `PORMG_ENV` read as
unset, landed with #1228 and is pinned in `test_configuration_api.jl`.)

No live database: SQLite `:memory:` pools, a subprocess that never loads a driver, and mock pools.
"""

using Test
using PormG
import PormG: Configuration, Models

function _boot1232_folder(root::AbstractString, name::AbstractString = "boot1232_db")
  db = joinpath(root, name)
  mkpath(db)
  write(joinpath(db, "connection.yml"),
        "test:\n  adapter: SQLite\n  database: \":memory:\"\n  config:\n    change_db: true\n    change_data: true\n")
  return db
end

# ─────────────────────────────────────────────────────────────────────────────
# load fails at boot without the driver extension
# What it tests: in a process that never ran `using SQLite`, `load` of a SQLite configuration raises
#   `MissingConfigurationError` naming `using SQLite`, and leaves the registry as it was — an entry
#   already under that key survives; after `using SQLite` the same call loads. `_peek_driver` reads
#   the driver from the file (the Postgres.jl driver included) and `_driver_hint` names its package.
#   A subprocess, because this process has every driver loaded.
# Why it matters: the missing driver surfaced on the FIRST QUERY, far from the boot that forgot the
#   `using`; and a check after the old entry was replaced would have lost that entry.
# ─────────────────────────────────────────────────────────────────────────────
@testset "load fails at boot without the driver extension (#1232)" begin
  mktempdir() do dir
    yml = joinpath(dir, "connection.yml")
    write(yml, "lite:\n  adapter: SQLite\n  database: \":memory:\"\n" *
               "pq:\n  adapter: PostgreSQL\n  host: localhost\n" *
               "pg:\n  adapter: PostgreSQL\n  host: localhost\n  postgres_driver: Postgres\n" *
               "odd:\n  adapter: Oracle\n")
    withenv("PORMG_POSTGRES_DRIVER" => nothing) do
      @test Configuration._peek_driver(yml, "lite") === :sqlite
      @test Configuration._peek_driver(yml, "pq") === :libpq
      @test Configuration._peek_driver(yml, "pg") === :postgres
      @test Configuration._peek_driver(yml, "odd") === nothing        # refused later, by its reader
      @test Configuration._peek_driver(yml, "absent") === nothing
    end
  end
  @test PormG._DRIVER_EXTENSIONS == (sqlite = :PormGSQLiteExt, libpq = :PormGLibPQExt, postgres = :PormGPostgresExt)
  @test occursin("using Postgres", PormG._driver_hint(:postgres))
  @test occursin("using LibPQ", PormG._driver_hint(:libpq))
  @test occursin("using SQLite", PormG._driver_hint(:sqlite))

  mktempdir() do root
    _boot1232_folder(root)
    script = """
    using PormG
    PormG.Configuration.register_offline("boot1232_db"; adapter = :sqlite)   # an entry to keep
    err = try
        PormG.Configuration.load("boot1232_db"; root = $(repr(root)), env = "test")
        nothing
    catch e
        e
    end
    println("ERR_TYPE:", typeof(err))
    println("ERR_HINT:", err === nothing ? "" : occursin("using SQLite", sprint(showerror, err)))
    println("KEPT_PRIOR:", PormG.Configuration._is_offline(PormG.config["boot1232_db"]))
    PormG.Configuration.unregister_connection("boot1232_db")
    using SQLite
    key = PormG.Configuration.load("boot1232_db"; root = $(repr(root)), env = "test")
    println("LOADED_WITH_DRIVER:", PormG.Configuration.is_loaded(key))
    """
    cmd = `$(Base.julia_cmd()) --startup-file=no --project=$(Base.active_project()) -e $script`
    output = read(pipeline(addenv(cmd, "PORMG_ENV" => "test"); stderr = devnull), String)
    @test occursin("ERR_TYPE:PormG.Configuration.MissingConfigurationError", output)
    @test occursin("ERR_HINT:true", output)
    @test occursin("KEPT_PRIOR:true", output)
    @test occursin("LOADED_WITH_DRIVER:true", output)
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# A per-key before_connect hook
# What it tests: `load(key; before_connect = f)` runs `f(key, settings)` before a physical connection
#   for that key, in place of the process-wide hook, which still serves a key with none; a per-key
#   hook returning `false` aborts with `PoolConnectError`; a repeated `load` (the #1225 no-op) with a
#   new hook replaces it without rebuilding the pool, and a forced rebuild that omits the hook keeps
#   the key's own. No SQL beyond opening `:memory:`.
# Why it matters: with one `Ref` per process, a hook meant for one connection had to test the key
#   itself, and be registered from both the module body and `__init__`.
# ─────────────────────────────────────────────────────────────────────────────
@testset "a per-key before_connect hook (#1232)" begin
  CP = PormG.ConnectionPool
  previous_global = Configuration._BEFORE_CONNECT_HOOK[]
  calls = Tuple{Symbol, String}[]
  mktempdir() do root
    _boot1232_folder(root, "boot1232_own")
    _boot1232_folder(root, "boot1232_shared")
    try
      Configuration.set_before_connect_hook((k, s) -> (push!(calls, (:global, k)); true))
      own = Configuration.load("boot1232_own"; root = root, env = "test",
                               before_connect = (k, s) -> (push!(calls, (:own, k)); true))
      shared = Configuration.load("boot1232_shared"; root = root, env = "test")

      for key in (own, shared)
        pool = Configuration.connection(key)
        CP.release_connection(pool, CP.acquire_connection(pool))
      end
      @test calls == [(:own, "boot1232_own"), (:global, "boot1232_shared")]

      # A repeated load keeps the pool and takes the new hook.
      pool_before = Configuration.connection(own)
      Configuration.close_pool!(own)
      Configuration.load("boot1232_own"; root = root, env = "test", before_connect = (k, s) -> false)
      @test Configuration.connection(own) === pool_before
      @test_throws PormG.PoolConnectError CP.acquire_connection(Configuration.connection(own))

      # A rebuild that omits the hook (`force`, as an `__init__` might) keeps the key's own hook.
      Configuration.load("boot1232_own"; root = root, env = "test", force = true)
      @test Configuration.connection(own) !== pool_before                       # rebuilt
      @test_throws PormG.PoolConnectError CP.acquire_connection(Configuration.connection(own))
    finally
      Configuration._BEFORE_CONNECT_HOOK[] = previous_global
      Configuration.unregister_connection("boot1232_own")
      Configuration.unregister_connection("boot1232_shared")
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# PormG.import_models — the function form of @import_models
# What it tests: it includes a models file into the given module, registers its models against the
#   loaded folder exactly as the macro does, and returns the models module; a file that defines no
#   module raises `InvalidConfigurationError`. No SQL.
# Why it matters: the macro needs a string literal and a module context, so a script comparing two
#   databases fell back to `Base.include` plus a manual `set_models`.
# ─────────────────────────────────────────────────────────────────────────────
@testset "PormG.import_models, the function form (#1232)" begin
  mktempdir() do root
    db = _boot1232_folder(root, "boot1232_fn")
    write(joinpath(db, "models.jl"), """
    module boot1232_models
    import PormG.Models
    Driver = Models.Model("drivers", driverid = Models.IDField(), surname = Models.CharField(max_length = 50))
    end
    """)
    write(joinpath(root, "not_a_module.jl"), "x = 1\n")
    try
      key = Configuration.load("boot1232_fn"; root = root, env = "test")
      into = Module(:Boot1232Into)
      M = PormG.import_models(joinpath(db, "models.jl"); into = into)
      @test M isa Module
      @test nameof(M) === :boot1232_models
      @test Base.invokelatest(getfield, into, :boot1232_models) === M
      @test Models.connection_key(Base.invokelatest(getfield, M, :Driver)) == key

      @test_throws PormG.InvalidConfigurationError PormG.import_models(joinpath(root, "not_a_module.jl");
                                                                       into = Module(:Boot1232Bad))
    finally
      Configuration.unregister_connection("boot1232_fn")
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# Configuration.connection takes the key positionally
# What it tests: `connection(key)` returns the same pool as the legacy `connection(; key)`. No SQL.
# Why it matters: `get_settings(key)`, `ping(key)` and `status(key)` take it positionally; this was
#   the one call in the family that did not.
# ─────────────────────────────────────────────────────────────────────────────
@testset "Configuration.connection(key) (#1232)" begin
  try
    Configuration.register_offline("boot1232_conn")
    @test Configuration.connection("boot1232_conn") === Configuration.connection(; key = "boot1232_conn")
    @test Configuration.connection("boot1232_conn") === PormG.config["boot1232_conn"].connections
  finally
    Configuration.unregister_connection("boot1232_conn")
  end
end
