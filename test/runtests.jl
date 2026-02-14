using Test
using PormG

@testset "PormG Unit Tests" begin
    # Unit tests that don't require a live database
    include("unit/test_migration_planner.jl")
end

# Check for PORMG_INTEGRATION_TESTS environment variable
if get(ENV, "PORMG_INTEGRATION_TESTS", "false") == "true"
    @testset "PormG Integration Tests" begin
        # These require a real database (Postgres/SQLite)
        # include("integration/runtests.jl")
    end
end
