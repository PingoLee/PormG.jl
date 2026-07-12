using Test
using PormG
# Activate the LibPQ/SQLite weakdep extensions (the unit suite runs against SQLite
# `:memory:`). See test/load_drivers.jl for why this is robust across env types.
include(joinpath(@__DIR__, "load_drivers.jl"))

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
    @testset "Many-to-Many Relationships" include("unit/test_many_to_many.jl")
    @testset "Shared-state Read/Copy Path (#43)" include("unit/test_shared_state_readpath.jl")
    @testset "Operator SQL Generation" include("unit/test_operators.jl")
    @testset "Aggregate Fan-out Guard (#74)" include("unit/test_aggregate_fanout.jl")
    @testset "Date Bucket Operator (yyyy_mm)" include("unit/test_date_bucket_operator.jl")
    @testset "Deep FK Traversal (3 hops)" include("unit/test_deep_fk_traversal.jl")
    @testset "Window Function SQL Generation" include("unit/test_window_functions.jl")
    @testset "Dedicated Inspection API" include("unit/test_inspect_query.jl")
    @testset "Reserved-word / Underscore Field Names" include("unit/test_reserved_word_fields.jl")
    @testset "Field-name Case Preservation (#57)" include("unit/test_field_name_case.jl")
    @testset "db_column Authoritative (#50)" include("unit/test_db_column.jl")
    @testset "SQLite Alignment Verification" include("unit/test_alignment_sqlite.jl")
    @testset "Field Validation and Operations" include("unit/test_field_validation_and_operations.jl")
    @testset "Reload Regressions" include("unit/test_reload.jl")
    @testset "Configuration API" include("unit/test_configuration_api.jl")
    @testset "bulk_update Column Scope" include("unit/test_bulk_update_column_scope.jl")
    @testset "Bulk Parameter-Limit Chunking (#84)" include("unit/test_bulk_param_limit.jl")
    @testset "ORDER BY NULL Placement (#75)" include("unit/test_order_by_nulls.jl")
    @testset "PG Migration Fixture Isolated + Credential-free (#36)" include("unit/test_migration_pg_fixture.jl")
    @testset "Pool Exhaustion Typed Error (#37)" include("unit/test_connection_pool_timeout.jl")
    @testset "Sequence Sync (Postgres + SQLite)" include("unit/test_sequence_sync.jl")
    @testset "Introspection PK Guards" include("unit/test_introspection_guards.jl")
    @testset "Self-Heal Key Inference" include("unit/test_self_heal_inference.jl")
    @testset "Ignore-Tables Registry" include("unit/test_ignore_tables_registry.jl")
    @testset "New Field Types (UUID, URL, Slug, JSON)" include("unit/test_new_field_types.jl")
    @testset "Django Model Importer" include("unit/test_import_django_models.jl")
    @testset "Schema Importers (key resolution)" include("unit/test_importers.jl")
    @testset "Discard Pending Migration" include("unit/test_discard_pending_migration.jl")
    @testset "Positive Integer Fields CHECK" include("unit/test_positive_small_integer_check.jl")
    @testset "Error Message ANSI (TTY-aware)" include("unit/test_error_message_ansi.jl")
    @testset "Migration Runner (checksum, guardrails)" include("unit/test_migrations_runner.jl")
    @testset "Migration Diff Fail-Safe (#69)" include("unit/test_migration_diff_failsafe.jl")
    @testset "Migration Format Stability (v1)" include("unit/test_migration_format_v1.jl")
    @testset "Schema Conventions Freeze (#33)" include("unit/test_schema_conventions.jl")
    @testset "Public Export Surface (#35)" include("unit/test_public_exports.jl")
    # include("unit/test_migration_planner.jl")
end

# Integration tests require a live database (Postgres/SQLite) and are opt-in:
# default `Pkg.test()` / CI runs (env var unset) skip this block, so behaviour there
# is unchanged. Run them with a configured DB to exercise the runtime-only contracts
# the unit suite cannot reach — e.g. run_in_transaction commit/rollback semantics
# (test/integration/test_transactions.jl).
#
#     PORMG_INTEGRATION_TESTS=true julia -t auto --project=. test/runtests.jl
if get(ENV, "PORMG_INTEGRATION_TESTS", "false") == "true"
    @testset "PormG Integration Tests" begin
        # These require a real database (Postgres/SQLite)
        include("integration/runtests.jl")
    end
end


# julia -t auto --project=. test/runtests.jl
