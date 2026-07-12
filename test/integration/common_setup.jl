using Pkg
Pkg.activate(".") # Or the correct relative path
ENV["PORMG_ENV"] = "dev"

using Revise
using PormG
# SQL function library (Sum, Count, Lower, Greatest, Floor, Extract, Abs, Concat, …) is
# namespaced under PormG.Functions since #35 (no longer flooded into Main by `using PormG`).
# Bring the whole library into scope so the integration tests can use the bare constructors —
# this models the documented `using PormG, PormG.Functions` pattern (docs/src/api.md).
using PormG.Functions
# Activate the LibPQ/SQLite weakdep extensions (#34) before any DB work — without these
# every backend operation raises the "load the driver" error. Robust across env types;
# see test/load_drivers.jl.
include(joinpath(@__DIR__, "..", "load_drivers.jl"))
using DataFrames
using CSV
using Test#, SafeTestsets
using Dates
using JSON
using UUIDs
using Base.Threads: Atomic, atomic_add!

# Optional Infiltrator support — re-wires @pormg_debug to real breakpoints when available.
# Infiltrator is a test-only dep (see [extras] in Project.toml); it is never loaded in production.
if !isinteractive()
    # Non-interactive (CI / Pkg.test): keep @pormg_debug as a no-op — do nothing.
elseif !isnothing(get(ENV, "PORMG_INFILTRATOR", nothing))
    try
        @eval using Infiltrator
        PormG.eval(:(macro pormg_debug(ex); :(Infiltrator.@infiltrate($(esc(ex)))); end))
        @info "Infiltrator loaded — @pormg_debug is live"
    catch e
        @warn "Could not load Infiltrator" exception=e
    end
end

import PormG: with_transaction, Models, Dialect
import PormG.Configuration: with_tx_context, get_tx_connection
import PormG.ConnectionPool: fetch_async, await_result
import PormG.QueryBuilder: Sum, Avg, Case, When, Count, Q, Qor, F, page, Max, Min, With, Value, Round
import PormG.QueryBuilder: quote_identifier, safe_table_identifier, escape_like_pattern
import PormG.QueryBuilder: cjoin

cd(@__DIR__)  # Ensure we're in the test/integration directory

# Select database folder from environment variable, falling back to db_2 (PostgreSQL)
const PORMG_DB_FOLDER = get(ENV, "PORMG_DB", "db_2")

# Load configurations once
PormG.Configuration.load(PORMG_DB_FOLDER)

# #37: the async integration suite (`-t auto`, heavy fan-out) saturates a small PostgreSQL pool
# against a possibly-remote DB. Size the pool to the run's concurrency for this run only
# (env-overridable) and rebuild so the initial slots are pre-sized instead of grown via the
# expansion path. We cannot use `db_2/connection.yml` (git-ignored), so this is the code-level
# equivalent of bumping the pool in the test environment. Keep PORMG_TEST_POOL_SIZE modest:
# with the ×10 ceiling a value of 20 means a max of 200 connections — far above the suite's real
# peak (~20-30) but a high value could exhaust the PostgreSQL server's max_connections.
let s = PormG.config[PORMG_DB_FOLDER]
    if s.connections isa PormG.PormGPostgres
        pool_n = parse(Int, get(ENV, "PORMG_TEST_POOL_SIZE", "20"))
        if pool_n != s.connections.pool_size
            s.db_config_settings["pool_size"] = pool_n
            PormG.Configuration.close_pool!(s.connections)   # close the size-3 pool; config[key] still → s
            PormG.Configuration._build_connection_pool!(s, PORMG_DB_FOLDER)
        end
    end
end

# Load the models and expose the alias `M`
# Using the new @import_models macro which handles registration automatically
if PORMG_DB_FOLDER == "db_sl"
    PormG.@import_models "db_sl/models.jl" models
else
    PormG.@import_models "db_2/models.jl" models
end
import .models as M


# Identificar o adapter carregado para o log
adapter_name = haskey(PormG.config, PORMG_DB_FOLDER) ?
               PormG.config[PORMG_DB_FOLDER].db_config_settings["adapter"] :
               "Unknown"

@info "🚀 Starting PormG integration tests" folder = PORMG_DB_FOLDER adapter = adapter_name


# $env:PORMG_DB="db_sl"; 
# export PORMG_DB=db_sl
# Sqlite doesn't work well with -t auto, so we can run it without threads for now
# julia -t auto --project=. -i test/integration/common_setup.jl
# julia -t auto --project=. test/integration/test_database_setup.jl
# julia -t auto --project=. test/integration/test_migration_bootstrap.jl
# julia -t auto --project=. test/integration/test_many_to_many.jl
# julia -t auto --project=. test/integration/runtests.jl
# $env:PORMG_DB="db_sl"; julia -t 1 --project=. test/integration/runtests.jl
# 2>&1 | Tee-Object -FilePath "test_sf_out.txt"
