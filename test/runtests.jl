using Test
using PormG

const HAS_AQUA = let available = false
    try
        @eval using Aqua
        available = true
    catch
        available = false
    end
    available
end

# Ensure environment is set for unit tests
if !haskey(ENV, "PORMG_ENV")
    ENV["PORMG_ENV"] = "test"
end

@testset "PormG Unit Tests" begin
    if HAS_AQUA
        @testset "Aqua Quality Checks" begin
            # We bypass stale_deps because the profiling tools (SnoopCompile, etc)
            # are in Project.toml Extras but not used in the main library code.
            Aqua.test_all(PormG; stale_deps=false)
        end
    end

    # Unit tests that don't require a live database
    @testset "Contextual Buckets (SQLite)" include("unit/test_parameters.jl")
    @testset "Execution Returns (show_query)" include("unit/test_execution_show.jl")
    @testset "Complex Query Patterns" include("unit/test_complex_queries.jl")
    @testset "Operator SQL Generation" include("unit/test_operators.jl")
    @testset "Window Function SQL Generation" include("unit/test_window_functions.jl")
    @testset "Dedicated Inspection API" include("unit/test_inspect_query.jl")
    @testset "SQLite Alignment Verification" include("unit/test_alignment_sqlite.jl")
    @testset "Field Validation and Operations" include("unit/test_field_validation_and_operations.jl")
    @testset "Reload Regressions" include("unit/test_reload.jl")
    @testset "Configuration API" include("unit/test_configuration_api.jl")
    @testset "bulk_update Column Scope" include("unit/test_bulk_update_column_scope.jl")
    @testset "Postgres Sequence Sync" include("unit/test_sequence_sync.jl")
    @testset "New Field Types (UUID, URL, Slug, JSON)" include("unit/test_new_field_types.jl")
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