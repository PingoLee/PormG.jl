# 1. Load the common environment (env, config, pool, models, shared helpers)
# julia -t auto  --project=. test/integration/runtests.jl
include("common_setup.jl")

# 2. Include individual test files
# Each file now focuses only on test logic, without setup
@testset "Bateria de Testes PormG ($(PORMG_DB_FOLDER))" begin

    # ── Phase 0: Migration Preflight + Schema Bootstrap ──────────────
    # Validates the migration engine on the selected DB starting from
    # empty, then bootstraps the real schema so fixture seeding can proceed.
    @testset "Migration Bootstrap"          begin include("test_migration_bootstrap.jl") end

    # ── Phase 1: Fixture Seeding ─────────────────────────────────────
    # Deletes any residual rows and loads the F1 CSV fixtures.
    @testset "Inserções e Schema"           begin include("test_database_setup.jl")     end

    # ── Phase 2: Behavioral Tests (reads, filters, expressions) ──────
    @testset "Seleção e Filtros"            begin include("test_selection.jl")          end
    @testset "Field Expressions"            begin include("test_field_expressions.jl")  end
    @testset "Atualizações (Updates)"       begin include("test_updates.jl")            end
    @testset "Bulk copy"                    begin include("test_bulk_copy.jl")          end
    @testset "Functions SQL"                begin include("test_sql_functions.jl")      end  

    # ── Phase 3: Advanced Features ───────────────────────────────────
    @testset "Joins e CTEs"                 begin include("test_joins_cte.jl")          end
    @testset "Joins com Cache"              begin include("test_cache_join.jl")         end
    @testset "Transações"                   begin include("test_transactions.jl")       end
    @testset "Advisory Locks"               begin include("test_advisorylock.jl")       end
    @testset "Having (Aggregates)"          begin include("test_having.jl")             end

    # ── Phase 4: Internals & Security ────────────────────────────────
    @testset "Internals & Security"         begin include("test_internals.jl")          end

end

PormG.Configuration.__cleanup__()