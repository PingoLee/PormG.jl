"""
Unit coverage for the connection registry's public names (#1229): `Configuration.loaded_keys`,
`Configuration.register_offline`, `Models.connection_key` and `Configuration.close_all!`.

Before these, the registry had no public names: asking which keys are loaded meant iterating
`PormG.config`, rendering SQL with no database meant defining a backend type and building a
`Settings` by hand, and asking which connection a model uses meant reading a struct field. Those
were the layout of `Settings` and `Model_Type`, not an API. No live database; every connection here is offline or SQLite `:memory:`.
"""

using Test
using PormG
import PormG: Configuration, Models
import JSON

# A throwaway models module with one F1 model, exactly what `@import_models` would evaluate.
function _reg1229_models(name::Symbol)
  mod = Module(name)
  Core.eval(mod, :(import PormG.Models))
  Core.eval(mod, :(Driver = Models.Model("drivers",
                                         driverid = Models.IDField(),
                                         surname  = Models.CharField(max_length = 50))))
  return mod, Base.invokelatest(getfield, mod, :Driver)
end

# ─────────────────────────────────────────────────────────────────────────────
# register_offline renders SQL on each dialect and never connects
# What it tests: an offline key binds models like a loaded folder (`set_models(mod, key)`),
#   `inspect_query` renders the dialect's SQL — PostgreSQL:
#     SELECT\n    *\nFROM "drivers" as "Tb"\nWHERE "Tb"."surname" = $1\n
#   SQLite: the same with `?` — and running the query raises `InvalidConfigurationError` naming
#   `register_offline` before any driver sees the placeholder connection string.
#   `Models.connection_key` reads the binding: `nothing` before, the key after.
# Why it matters: rendering SQL with no database otherwise means defining a backend type and
#   writing a hand-built `Settings` into `PormG.config`.
# ─────────────────────────────────────────────────────────────────────────────
@testset "register_offline renders SQL and never connects (#1229)" begin
  expected = Dict(
    :postgres => "SELECT\n    *\nFROM \"drivers\" as \"Tb\"\nWHERE \"Tb\".\"surname\" = \$1\n",
    :sqlite   => "SELECT\n    *\nFROM \"drivers\" as \"Tb\"\nWHERE \"Tb\".\"surname\" = ?\n",
  )
  for adapter in (:postgres, :sqlite)
    key = "reg1229_offline_$(adapter)"
    try
      @test Configuration.register_offline(key; adapter = adapter) == key
      mod, driver = _reg1229_models(Symbol("Reg1229Offline", adapter))
      @test Models.connection_key(driver) === nothing
      Base.invokelatest(Models.set_models, mod, key)
      @test Models.connection_key(driver) == key

      q = driver.objects
      q.filter("surname" => "Senna")
      info = PormG.inspect_query(q)
      @test info[:sql_text] == expected[adapter]
      @test info[:parameters] == Any["Senna"]

      q2 = driver.objects
      q2.filter("surname" => "Senna")
      err = try
        q2.list()
        nothing
      catch e
        e
      end
      @test err isa PormG.InvalidConfigurationError
      @test occursin("registered with `register_offline`", sprint(showerror, err))
    finally
      Configuration.unregister_connection(key)
    end
    @test !Configuration.is_loaded(key)
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# register_offline: arguments, replacing, and refusing a live key
# What it tests: `adapter` other than :postgres/:sqlite is refused; `django_prefix`/`change_data`
#   land on the entry; registering the same key again replaces the offline entry; a key that
#   `register_connection` (or `load`) registered is refused, not overwritten. The offline entry's
#   2-arg `show` and JSON form stay small (the #534/#643 bounds) and carry no connection string.
# Why it matters: an offline helper that could silently replace a live connection would turn a test
#   helper into a way to lose the application's database binding.
# ─────────────────────────────────────────────────────────────────────────────
@testset "register_offline: arguments, replace, refuse a live key (#1229)" begin
  key = "reg1229_args"
  live = "reg1229_live"
  try
    @test_throws PormG.InvalidConfigurationError Configuration.register_offline(key; adapter = :mysql)
    Configuration.register_offline(key; adapter = :sqlite, django_prefix = "f1_", change_data = false)
    s = PormG.config[key]
    @test s.django_prefix == "f1_"
    @test s.change_data == false
    @test s.connections isa PormG.PormGSQLite

    Configuration.register_offline(key)                    # replaces the offline entry
    @test PormG.config[key].connections isa PormG.PormGPostgres
    @test PormG.config[key].django_prefix === nothing

    @test length(sprint(show, PormG.config[key])) < 200
    @test length(JSON.json(PormG.config[key])) < 1000
    @test !occursin("pormg-offline", JSON.json(PormG.config[key]))

    Configuration.register_connection(live, ":memory:"; adapter = "SQLite")
    err = try
      Configuration.register_offline(live)
      nothing
    catch e
      e
    end
    @test err isa PormG.InvalidConfigurationError
    @test occursin("already registered as a live connection", sprint(showerror, err))
    @test !(PormG.config[live].connections isa PormG.PormGPostgres)   # untouched
  finally
    Configuration.unregister_connection(key)
    Configuration.unregister_connection(live)
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# loaded_keys and close_all!
# What it tests: `loaded_keys()` lists static and dynamic entries, sorted; `close_all!()` closes
#   every pool and keeps every entry registered, returning `nothing`.
# Why it matters: "which keys are loaded?" was `for (k, s) in PormG.config`, in Dict order; the
#   atexit cleanup scripts called was `__cleanup__()`, an internal name.
# ─────────────────────────────────────────────────────────────────────────────
@testset "loaded_keys and close_all! (#1229)" begin
  saved = copy(PormG.config)
  try
    empty!(PormG.config)
    @test Configuration.loaded_keys() == String[]
    Configuration.register_offline("reg1229_b")
    Configuration.register_connection("reg1229_a", ":memory:"; adapter = "SQLite")
    @test Configuration.loaded_keys() == ["reg1229_a", "reg1229_b"]

    pool = PormG.config["reg1229_a"].connections
    conn = PormG.ConnectionPool.acquire_connection(pool)        # open a physical connection
    PormG.ConnectionPool.release_connection(pool, conn)
    @test any(!isnothing, pool.connections)
    @test Configuration.close_all!() === nothing
    @test all(isnothing, pool.connections)
    @test Configuration.loaded_keys() == ["reg1229_a", "reg1229_b"]   # entries stay
  finally
    for k in collect(keys(PormG.config))
      try Configuration.unregister_connection(k) catch end
    end
    empty!(PormG.config)
    merge!(PormG.config, saved)
  end
end
