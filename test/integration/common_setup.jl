using Pkg
Pkg.activate(".") # Or the correct relative path
ENV["PORMG_ENV"] = "dev"

using Revise
using PormG
using DataFrames
using CSV
using Test, SafeTestsets
using Dates
using JSON
using UUIDs
using Base.Threads: Atomic, atomic_add!
using Infiltrator: @infiltrate

import PormG: with_transaction, Models, Dialect
import PormG.Configuration: with_tx_context, get_tx_connection
import PormG.ConnectionPool: fetch_async, await_result
import PormG.QueryBuilder: Sum, Avg, Case, When, Count, Q, Qor, F, page, do_count, do_exists, Max, Min, With
import PormG.QueryBuilder: quote_identifier, safe_table_identifier, escape_like_pattern
import PormG.QueryBuilder: cjoin

cd(@__DIR__)  # Ensure we're in the test/integration directory

# Load configurations once
PormG.Configuration.load("db_2")

# Load the models and expose the alias `M`
# Using the new @import_models macro which handles registration automatically
PormG.@import_models "db_2/models.jl" models
import .models as M

# If you have custom test macros, define or include them here
# include("utils/custom_macros.jl")

# julia -t auto --project=. -i test/integration/common_setup.jl
# julia -t auto --project=. test/integration/test_reload.jl
# include("test_bulk_copy.jl")
