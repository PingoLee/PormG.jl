# 1. Load the common environment (env, config, pool, models, shared helpers)
# julia -t auto  --project=. test/integration/runtests.jl
include("common_setup.jl")

# 1b. Load delete scratch modules at top level (module expressions are forbidden
#     inside @testset / macro-wrapped bodies in Julia).
include("common_delete_setup.jl")
include("common_bulk_scratch_setup.jl")

# 2. Include individual test files
# Each file now focuses only on test logic, without setup
@testset "PormG Test Suite ($(PORMG_DB_FOLDER))" begin

    # ── Phase 0: Migration Preflight + Schema Bootstrap ──────────────
    # Validates the migration engine on the selected DB starting from
    # empty, then bootstraps the real schema so fixture seeding can proceed.
    @testset "Migration Bootstrap"          begin include("test_migration_bootstrap.jl") end

    # ── Phase 1: Fixture Seeding ─────────────────────────────────────
    # test_inserts.jl runs first: it exercises insert-specific behavioral
    # logic (schema evolution, error recovery, create() return semantics)
    # before test_database_setup.jl clears all tables and seeds the F1 data.
    @testset "Inserts and Schema"           begin
        include("test_inserts.jl")
        include("test_database_setup.jl")
    end

    # ── Phase 2: Behavioral Tests (reads, filters, expressions) ──────
    @testset "Selection and Filters"        begin include("test_selection.jl")          end # TODO: split this into multiple files (selection, filters, expressions)
    @testset "PormGRow and get()"           begin include("test_row_and_get.jl")        end
    @testset "PormGRow Mutation"            begin include("test_row_mutation.jl")       end
    @testset "Field-name Case Preservation" begin include("test_field_name_case_db.jl") end
    @testset "db_column Authoritative"       begin include("test_db_column_db.jl")       end
    @testset "Field Expressions"            begin include("test_field_expressions.jl")  end
    @testset "Updates"                      begin include("test_updates.jl")            end
    @testset "Deletes"                      begin include("test_deletes.jl")            end
    @testset "Bulk copy"                    begin include("test_bulk_copy.jl")          end
    @testset "SQL Functions"                begin include("test_sql_functions.jl")      end
    @testset "Window Functions"             begin include("test_window_functions.jl")   end
    @testset "Unaccent Extension"           begin include("test_unaccent_extension.jl") end

    # ── Phase 3: Advanced Features ───────────────────────────────────
    @testset "Reverse Joins & on()"         begin include("test_reverse_joins.jl")      end
    @testset "Many-to-Many"                 begin include("test_many_to_many.jl")       end
    @testset "CTEs (with)"                  begin include("test_cte.jl")                end
    @testset "Subqueries"                   begin include("test_subqueries.jl")         end
    @testset "Correlated EXISTS"            begin include("test_exists_correlated.jl")  end
    @testset "Custom Joins (cjoin)"         begin include("test_cjoin.jl")              end    
    @testset "Cached Joins"                 begin include("test_cache_join.jl")         end
    @testset "Transactions"                 begin include("test_transactions.jl")       end
    @testset "Async Task Concurrency (#198)" begin include("test_async_tasks.jl")       end
    @testset "Connection Pool (#37)"        begin include("test_connection_pool.jl")    end
    @testset "Manual Params raw SQL (#218)" begin include("test_manual_params.jl")       end
    @testset "Advisory Locks"               begin include("test_advisorylock.jl")       end
    @testset "Having (Aggregates)"          begin include("test_having.jl")             end
    @testset "Field Validation DB Tests"    begin include("test_field_validation_db_roundtrip.jl") end
    @testset "JSON/JSONB Lookups (#27)"      begin include("test_json_fields.jl")         end
    @testset "Django Data-Type Contracts"   begin include("test_django_contract.jl")    end
    @testset "Importer / Introspection"     begin include("test_importers_introspection.jl") end
    # ── Phase 4: Internals & Security ────────────────────────────────
    @testset "Internals & Security"         begin include("test_internals.jl")          end

end

PormG.Configuration.__cleanup__()