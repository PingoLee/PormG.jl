using Test
using PormG
using Infiltrator

# Ensure environment is set for unit tests
if !haskey(ENV, "PORMG_ENV")
    ENV["PORMG_ENV"] = "test"
end

@testset "PormG Unit Tests" begin
    # Unit tests that don't require a live database
    @testset "Contextual Buckets (SQLite)" include("unit/test_parameters.jl")
    @testset "Execution Returns (show_query)" include("unit/test_execution_show.jl")
    @testset "Complex Query Patterns" include("unit/test_complex_queries.jl")
    @testset "Operator SQL Generation" include("unit/test_operators.jl")
    @testset "Dedicated Inspection API" include("unit/test_inspect_query.jl")
    @testset "SQLite Alignment Verification" include("unit/test_alignment_sqlite.jl")
    @testset "Field Validation and Operations" include("unit/test_field_validation_and_operations.jl")
    @testset "Reload Regressions" include("unit/test_reload.jl")
    @testset "Configuration API" include("unit/test_configuration_api.jl")
    @testset "Password Encoding" include("unit/test_password.jl")
    @testset "Password Validation i18n" include("unit/test_password_i18n.jl")
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