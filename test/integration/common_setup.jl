using Pkg
Pkg.activate(".") # Or the correct relative path
ENV["PORMG_ENV"] = "dev"

using Revise
using PormG
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
# Sqlite doesn't work well with -t auto, so we can run it without threads for now
# julia -t auto --project=. -i test/integration/common_setup.jl
# julia -t auto --project=. test/integration/test_database_setup.jl
# julia -t auto --project=. test/integration/test_bulk_copy.jl
# julia -t auto --project=. test/integration/test_field_validation_db_roundtrip.jl
# julia -t auto --project=. test/integration/runtests.jl
# $env:PORMG_DB="db_sl"; julia -t 1 --project=. test/integration/runtests.jl
# include("test_bulk_copy.jl")
