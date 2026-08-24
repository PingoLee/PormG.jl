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
            # stale_deps is ON: every [deps]/[weakdeps] entry is genuinely used by the
            # package. Profiling tools (SnoopCompile, etc.) live in [extras], which Aqua's
            # stale_deps never inspects — so they need no exemption here (#209).
            Aqua.test_all(PormG)
        end
    end

    # Unit tests that don't require a live database
    @testset "Contextual Buckets (SQLite)" include("unit/test_parameters.jl")
    @testset "Execution Returns (show_query)" include("unit/test_execution_show.jl")
    @testset "Complex Query Patterns" include("unit/test_complex_queries.jl")
    @testset "Many-to-Many Relationships" include("unit/test_many_to_many.jl")
    @testset "Composite Uniqueness (unique_together #19)" include("unit/test_unique_constraints.jl")
    @testset "Composite Indexes (Meta.indexes #347)" include("unit/test_indexes.jl")
    @testset "Shared-state Read/Copy Path (#43)" include("unit/test_shared_state_readpath.jl")
    @testset "custom_join Copy Isolation (#112)" include("unit/test_custom_join_copy.jl")
    @testset "Model_Type deepcopy Shares (#157)" include("unit/test_model_deepcopy.jl")
    @testset "cjoin_on Anchor-less Joins (#45)" include("unit/test_cjoin_on.jl")
    @testset "Operator SQL Generation" include("unit/test_operators.jl")
    @testset "pormg_lower UDF (#78)" include("unit/test_pormg_lower_udf.jl")
    @testset "Aggregate Fan-out Guard (#74)" include("unit/test_aggregate_fanout.jl")
    @testset "Date Bucket Operator (yyyy_mm)" include("unit/test_date_bucket_operator.jl")
    @testset "Sargable Date Range Rewrite (#352)" include("unit/test_sargable_date_range.jl")
    @testset "Date/Time Function SQL Parity (#25)" include("unit/test_date_functions_sql.jl")
    @testset "Deep FK Traversal (3 hops)" include("unit/test_deep_fk_traversal.jl")
    @testset "Window Function SQL Generation" include("unit/test_window_functions.jl")
    @testset "Dedicated Inspection API" include("unit/test_inspect_query.jl")
    @testset "Reserved-word Columns via db_column (#317)" include("unit/test_reserved_word_fields.jl")
    @testset "Model_to_str Identifier Sanitizing (#317)" include("unit/test_model_to_str_identifiers.jl")
    @testset "Field-name Case Preservation (#57)" include("unit/test_field_name_case.jl")
    @testset "Model-name Case (#300)" include("unit/test_model_name_case.jl")
    @testset "Mixed-case Model Binding in Reverse Joins (#343)" include("unit/test_reverse_join_mixed_case_binding.jl")
    @testset "db_column Authoritative (#50)" include("unit/test_db_column.jl")
    @testset "db_table Authoritative (#59)" include("unit/test_db_table.jl")
    @testset "Unresolved ForeignKey Target Is Never Guessed (#388)" include("unit/test_fk_unresolved_target.jl")
    @testset "SQLite Alignment Verification" include("unit/test_alignment_sqlite.jl")
    @testset "CTE Ergonomics F() Reference (#44)" include("unit/test_cte_ergonomics.jl")
    @testset "CTE Columns Are Projection Aliases (#376)" include("unit/test_cte_db_column.jl")
    @testset "JSON Path Lookups (#27)" include("unit/test_json_lookups.jl")
    @testset "JSON Containment Operators (#27)" include("unit/test_json_operators.jl")
    @testset "Field Validation and Operations" include("unit/test_field_validation_and_operations.jl")
    @testset "Typed Exceptions on Query Surface (#197)" include("unit/test_typed_exceptions.jl")
    @testset "Semantic Error Taxonomy (#231)" include("unit/test_error_taxonomy.jl")
    @testset "Database-error Boundary (#268)" include("unit/test_database_error_boundary.jl")
    @testset "Error-contract Drift Guard (#239)" include("unit/test_docs_error_type_drift.jl")
    @testset "Documented Error Types (#239)" include("unit/test_docs_error_types.jl")
    @testset "Kernel Layering" include("unit/test_kernel_layering.jl")
    @testset "DateTime UTC Canonicalization (#79)" include("unit/test_datetime_canonicalization.jl")
    @testset "Reload Regressions" include("unit/test_reload.jl")
    @testset "Configuration API" include("unit/test_configuration_api.jl")
    @testset "bulk_update Column Scope" include("unit/test_bulk_update_column_scope.jl")
    @testset "Bulk Default-Fill Scope (#331)" include("unit/test_bulk_default_fill_scope.jl")
    @testset "Bulk Fill-Column Collision (#335)" include("unit/test_bulk_fill_column_collision.jl")
    @testset "Bulk No-Mutation Contract (#132)" include("unit/test_bulk_no_mutation.jl")
    @testset "Bulk Parameter-Limit Chunking (#84)" include("unit/test_bulk_param_limit.jl")
    @testset "bulk_insert ON CONFLICT (#123)" include("unit/test_bulk_on_conflict.jl")
    @testset "update_or_create (#30)" include("unit/test_update_or_create.jl")
    @testset "Fluent parity: get_or_create/last/aggregate/page (#208, #272)" include("unit/test_fluent_parity_208.jl")
    @testset "create() returns PormGRow (#166)" include("unit/test_create_returns_pormgrow.jl")
    @testset "ORDER BY NULL Placement (#75)" include("unit/test_order_by_nulls.jl")
    @testset "SQLOrder Orientation Whitelist (#77)" include("unit/test_sqlorder_orientation.jl")
    @testset "PG Migration Fixture Isolated + Credential-free (#36)" include("unit/test_migration_pg_fixture.jl")
    @testset "Pool Exhaustion Typed Error (#37)" include("unit/test_connection_pool_timeout.jl")
    @testset "Connect-Failure Fast-Fail Typed Error (#72)" include("unit/test_connection_pool_connect_error.jl")
    @testset "close_pool! Skips Non-pool Mocks (#147)" include("unit/test_close_pool_mock_skip.jl")
    @testset "Module Init & atexit Cleanup (#203)" include("unit/test_module_init.jl")
    @testset "Failed Rollback → Connection Renewed/Discarded (#71)" include("unit/test_transaction_rollback_renewal.jl")
    @testset "No Lost-Connection Retry Inside Transactions (#138)" include("unit/test_fetch_retry_transaction.jl")
    @testset "Abandoned Await Never Releases a Dirty Connection (#315)" include("unit/test_await_result_interrupt.jl")
    @testset "Interrupted Transaction / Advisory Lock Recovers Its Connection (#322)" include("unit/test_transaction_interrupt.jl")
    @testset "Failed COMMIT Holds Conn Until Rollback (#139)" include("unit/test_commit_failure_release.jl")
    @testset "Direct-Handoff Pool Wait (#124)" include("unit/test_connection_pool_handoff.jl")
    @testset "Idle-Reaping + Max-Lifetime Pool (#125)" include("unit/test_connection_pool_reaping.jl")
    @testset "Pool Stats Snapshot (#127)" include("unit/test_connection_pool_stats.jl")
    @testset "Connection-Leak Detection (#127)" include("unit/test_connection_pool_leak.jl")
    @testset "Savepoint Naming (#26)" include("unit/test_savepoint_naming.jl")
    @testset "Sequence Sync (Postgres + SQLite)" include("unit/test_sequence_sync.jl")
    @testset "Sequence Resync as an Operation (#358)" include("unit/test_resync_sequences.jl")
    @testset "Introspection PK Guards" include("unit/test_introspection_guards.jl")
    @testset "Physical-column Identity (#325)" include("unit/test_column_equivalence.jl")
    @testset "Key Type Round Trip (#408/#409)" include("unit/test_key_type_round_trip.jl")
    @testset "Self-Heal Key Inference" include("unit/test_self_heal_inference.jl")
    @testset "Ignore-Tables Registry" include("unit/test_ignore_tables_registry.jl")
    @testset "New Field Types (UUID, URL, Slug, JSON)" include("unit/test_new_field_types.jl")
    @testset "Field Kwargs Equivalence (#260)" include("unit/test_field_kwargs_equivalence.jl")
    @testset "Django Model Importer" include("unit/test_import_django_models.jl")
    @testset "Django Multi-App Project Importer (#346)" include("unit/test_import_django_project.jl")
    @testset "Schema Importers (key resolution)" include("unit/test_importers.jl")
    @testset "Discard Pending Migration" include("unit/test_discard_pending_migration.jl")
    @testset "Positive Integer Fields CHECK" include("unit/test_positive_small_integer_check.jl")
    @testset "BinaryField Byte Storage (#296)" include("unit/test_binary_field_bytes.jl")
    @testset "alter_field Constraint DROPs (#283, #284)" include("unit/test_alter_field_constraint_drops.jl")
    @testset "Error Message ANSI (TTY-aware)" include("unit/test_error_message_ansi.jl")
    @testset "SQLite Advisory-Lock Signalling (#277)" include("unit/test_advisory_lock_sqlite.jl")
    @testset "Migration Runner (checksum, guardrails)" include("unit/test_migrations_runner.jl")
    @testset "SQLite Rebuild Index Filter (#116)" include("unit/test_sqlite_index_filter.jl")
    @testset "FK Rename Rebuild Gate (#150)" include("unit/test_fk_rename_rebuild.jl")
    @testset "Migration Diff Fail-Safe (#69)" include("unit/test_migration_diff_failsafe.jl")
    @testset "Migration Diff: auto_add is not schema drift (#334)" include("unit/test_migration_planner_auto_add.jl")
    @testset "Migration Diff: FK to_table is not schema drift (#360)" include("unit/test_fk_to_table_planner.jl")
    @testset "Model_to_str Render Failure (#70/#134)" include("unit/test_model_to_str_render_failure.jl")
    @testset "Migration Format Stability (v1)" include("unit/test_migration_format_v1.jl")
    @testset "Schema Conventions Freeze (#33)" include("unit/test_schema_conventions.jl")
    @testset "Public Export Surface (#35)" include("unit/test_public_exports.jl")
    @testset "Docstring Coverage (#212)" include("unit/test_docstring_coverage.jl")
    @testset "Upgrade Guide Emitter (#216)" include("unit/test_upgrade_guide.jl")
    @testset "AI Skill Installer (#206)" include("unit/test_install_ai_skills.jl")
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
