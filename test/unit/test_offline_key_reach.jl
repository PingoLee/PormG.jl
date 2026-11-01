# ==============================================================================
# What an offline key can reach (#1466)
#
# A `register_offline` key holds a REAL `PostgresConnectionPool` / `SQLiteConnectionPool`, built on a
# placeholder connection string (#1229). So any code that decides "can this pool read?" by the pool's
# type treats an offline key as live unless it also asks the offline predicate
# (`Configuration._is_offline_key` / `_is_offline_pool`). #1451, #1452 and #1453 were three such paths
# at once (fixed in #1463).
#
# #1466 weighed a dedicated offline pool type that would make that impossible to write, and kept the
# predicate (maintainer's call, 2026-10-31): such a type would subtype the engine markers and fall into
# the ~40 lifecycle methods typed on them (`acquire_connection(::PormGSQLite)`, `fetch(::_SQLEngine)`,
# `atomic`, …) with a `FieldError`, not a `MethodError`, and a field-less one would be a singleton, so
# two offline keys would be one pool by identity. What made the predicate fragile was that forgetting
# it failed nothing. This file is what fails now:
#
#   1. every public entry point that would run a statement refuses an offline key on both adapters,
#      before any connection is opened, and the paths that only render still render;
#   2. the code that branches on a CONCRETE pool type is a reviewed list. Each entry says why an offline
#      key reaching it is safe. A new entry fails until its author answers that; a removed one fails
#      until it is struck, so the list stays exact.
#
# No database; the drivers are loaded only so the live-pool code is the code under test.
#
# Run: julia --project=test/integration test/unit/test_offline_key_reach.jl
# ==============================================================================

using Test
using PormG
import PormG: Configuration, Models
using SQLite
using DataFrames: DataFrame

const _OKR_CP = PormG.ConnectionPool

# A throwaway models module with one F1 model, bound to `key`, as `@import_models` would build it.
function _okr_driver(key::String)
  mod = Module(Symbol("OfflineKeyReach_", key))
  Core.eval(mod, :(import PormG.Models))
  Core.eval(mod, :(Driver = Models.Model("drivers",
                                         driverid = Models.IDField(),
                                         surname  = Models.CharField(max_length = 50))))
  Base.invokelatest(Models.set_models, mod, key)
  return Base.invokelatest(getfield, mod, :Driver)
end

# The error a call raises, or `nothing`. Logs are dropped: a write path `@error`-logs its failure with a
# backtrace before rethrowing it, and the refusal is what is asserted here.
_okr_raised(f) = try Base.CoreLogging.with_logger(f, Base.CoreLogging.NullLogger()); nothing catch e; e end

# ─────────────────────────────────────────────────────────────────────────────
# every entry point that runs a statement refuses an offline key
# What it tests: for an offline key on each adapter (SQLite with `server_version = 3_045_000`, so the
#   #1452 version refusal is not what answers), each of these raises `InvalidConfigurationError`
#   saying the key was "registered with `register_offline`":
#     ORM:  list, create, update, delete, bulk_insert
#     pool: fetch, fetch_async, acquire_connection, atomic, run_in_transaction, with_transaction
#   and afterwards the pool holds no open connection. The render paths still answer:
#   `inspect_query` → the dialect's SELECT, `delete(show_query = :dict)` → its plan (#1453),
#   `bulk_insert(show_query = :dict)` → its statement, `close_pool!(key)` → nothing, entry kept.
#   The offline PostgreSQL pool names the LibPQ driver, whatever `PORMG_POSTGRES_DRIVER` says.
# Why it matters: the #1229 refusal lives in one place (`ensure_before_connect!`); every one of these
#   paths reaches it only because it acquires through the shared funnel. A new path that leases a
#   connection another way, or decides by the pool's type that it may read, would reach the
#   placeholder connection string, or read nothing and report it as data, and nothing else fails.
# ─────────────────────────────────────────────────────────────────────────────
@testset "every entry point that runs a statement refuses an offline key (#1466)" begin
  for adapter in (:postgres, :sqlite)
    key = "okr1466_$(adapter)"
    try
      if adapter === :sqlite
        Configuration.register_offline(key; adapter = :sqlite, server_version = 3_045_000)
      else
        Configuration.register_offline(key; adapter = :postgres)
      end
      driver = _okr_driver(key)
      pool = PormG.config[key].connections
      rows = DataFrame(surname = ["Senna", "Prost"])

      refusals = (
        "list"               => () -> driver.objects.filter("surname" => "Senna").list(),
        "create"             => () -> driver.objects.create("surname" => "Senna"),
        "update"             => () -> driver.objects.filter("driverid" => 1).update("surname" => "Prost"),
        "delete"             => () -> driver.objects.filter("driverid" => 1).delete(),
        "bulk_insert"        => () -> PormG.bulk_insert(driver.objects, rows),
        "fetch"              => () -> _OKR_CP.fetch(pool, "SELECT 1"),
        "fetch_async"        => () -> _OKR_CP.fetch_async(pool, "SELECT 1"),
        "acquire_connection" => () -> _OKR_CP.acquire_connection(pool),
        "atomic"             => () -> _OKR_CP.atomic(() -> nothing, key),
        "run_in_transaction" => () -> _OKR_CP.run_in_transaction(() -> nothing, key),
        "with_transaction"   => () -> _OKR_CP.with_transaction(pool, "SELECT 1"),
      )
      for (name, f) in refusals
        err = _okr_raised(f)
        ok = err isa PormG.InvalidConfigurationError &&
             occursin("registered with `register_offline`", sprint(showerror, err))
        ok || @info "offline key reached past the refusal" adapter entry = name err
        @test ok
      end
      @test all(isnothing, pool.connections)   # no slot was ever opened

      # The render paths answer without a connection.
      @test occursin("FROM \"drivers\" as \"Tb\"",
                     PormG.inspect_query(driver.objects.filter("surname" => "Senna"))[:sql_text])
      @test driver.objects.filter("driverid" => 1).delete(show_query = :dict) isa Union{Dict, Vector}
      @test PormG.bulk_insert(driver.objects, rows; show_query = :dict) isa Union{Dict, Vector}
      adapter === :postgres && @test _OKR_CP.postgres_driver(pool) === :libpq
      @test all(isnothing, pool.connections)

      @test Configuration.close_pool!(key) === nothing
      @test Configuration.is_loaded(key)
    finally
      Configuration.unregister_connection(key)
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# the code that branches on a concrete pool type is a reviewed list
# What it tests: a scan of src/ and ext/ for (a) a method whose signature names
#   `PostgresConnectionPool` / `SQLiteConnectionPool` / `MySQLConnectionPool`, (b) an `isa` check
#   against one, and (c) a `const` alias of one (an extension's `_Pool`, which types every method under
#   it) equals `_OKR_REVIEWED` exactly, per (file, name) with its count.
# Why it matters: these are the places where an offline key looks live by its type alone. Each entry
#   records why reaching it with an offline key is safe; the next one has to say so before it lands,
#   which is the check #1451/#1452/#1453 never had.
# ─────────────────────────────────────────────────────────────────────────────
const _OKR_POOL = raw"(?:[\w.]+\.)?(?:Postgres|SQLite|MySQL)ConnectionPool\b"
const _OKR_METHOD = Regex(raw"^\s*(?:function\s+)?([\w.!]+)\s*\([^)]*::(?:Type\{<:|Union\{[^}]*)?" * _OKR_POOL)
const _OKR_ISA = Regex(raw"isa\s+" * _OKR_POOL)
const _OKR_ALIAS = Regex(raw"^\s*const\s+(\w+)\s*=\s*" * _OKR_POOL)

const _OKR_REVIEWED = Dict(
  # Reads the type parameter only. An offline pool is always `{:libpq}`: `register_offline` builds it
  # with the constructor's default driver, never `PORMG_POSTGRES_DRIVER` (asserted above).
  ("src/ConnectionPool.jl", "postgres_driver") => 1,
  # Consults the predicate: an offline SQLite key answers the version it stated, or refuses (#1452).
  ("src/ConnectionPool.jl", "_server_version") => 1,
  # Consults the predicate: an offline key's refusal names the version it stated (#1467).
  ("src/ConnectionPool.jl", "_version_at_hand") => 1,
  # Pool settings read while acquiring. Acquiring an offline key is refused in `ensure_before_connect!`
  # before a driver sees the placeholder string (#1229; the testset above). No offline MySQL key exists.
  ("src/ConnectionPool.jl", "_pool_timeout") => 3,
  ("src/ConnectionPool.jl", "_fail_fast_on_connect") => 3,
  # Closes the slots a pool opened. An offline pool opens none, so it closes nothing; `register_offline`
  # calls it when it replaces an offline entry (the testset above).
  ("src/ConnectionPool.jl", "close_pool!") => 3,
  # `_is_live_pool`: the type check, then `!_is_offline_pool(pool)` (#1453).
  ("src/querybuilder/deletion.jl", "isa") => 3,
  # `{:postgres}` (Postgres.jl). An offline pool is `{:libpq}`, so no method under it matches one.
  ("ext/PormGPostgresExt.jl", "_Pool") => 1,
  # MySQL. `register_offline` accepts `:postgres` and `:sqlite` only.
  ("ext/PormGMySQLExt.jl", "_Pool") => 1,
)

function _okr_scan(root::String)
  found = Dict{Tuple{String, String}, Int}()
  for dir in ("src", "ext"), (path, _, files) in walkdir(joinpath(root, dir)), file in files
    endswith(file, ".jl") || continue
    rel = replace(relpath(joinpath(path, file), root), '\\' => '/')
    for line in eachline(joinpath(path, file))
      startswith(lstrip(line), "#") && continue
      m = match(_OKR_METHOD, line)
      if m !== nothing
        name = String(last(split(m.captures[1], '.')))
        found[(rel, name)] = get(found, (rel, name), 0) + 1
      end
      a = match(_OKR_ALIAS, line)
      a === nothing || (found[(rel, String(a.captures[1]))] = get(found, (rel, String(a.captures[1])), 0) + 1)
      n = length(collect(eachmatch(_OKR_ISA, line)))
      n == 0 || (found[(rel, "isa")] = get(found, (rel, "isa"), 0) + n)
    end
  end
  return found
end

@testset "the code that branches on a concrete pool type is a reviewed list (#1466)" begin
  found = _okr_scan(pkgdir(PormG))
  for (k, n) in found
    reviewed = get(_OKR_REVIEWED, k, 0)
    reviewed == n || @info "unreviewed concrete-pool branch: say in `_OKR_REVIEWED` why an offline key reaching it is safe" file = k[1] name = k[2] found = n reviewed
    @test reviewed == n
  end
  for (k, n) in _OKR_REVIEWED
    haskey(found, k) || @info "reviewed entry no longer in the source: strike it" file = k[1] name = k[2] reviewed = n
    @test haskey(found, k)
  end
end
