using Test
using PormG

# Ensure environment is set for unit tests
if !haskey(ENV, "PORMG_ENV")
    ENV["PORMG_ENV"] = "test"
end

@testset "PormG Unit Tests" begin
    # Unit tests that don't require a live database
    @time @testset "Contextual Buckets (SQLite)" include("unit/test_parameters.jl")
    @time @testset "Execution Returns (show_query)" include("unit/test_execution_show.jl")
    @time @testset "Complex Query Patterns" include("unit/test_complex_queries.jl")
    @time @testset "Dedicated Inspection API" include("unit/test_inspect_query.jl")
    @time @testset "SQLite Alignment Verification" include("unit/test_alignment_sqlite.jl")
    # include("unit/test_migration_planner.jl")
end

# # Check for PORMG_INTEGRATION_TESTS environment variable
# if get(ENV, "PORMG_INTEGRATION_TESTS", "false") == "true"
#     @testset "PormG Integration Tests" begin
#         # These require a real database (Postgres/SQLite)
#         # include("integration/runtests.jl")
#     end
# end


# julia -t auto --project=. test/runtests.jl