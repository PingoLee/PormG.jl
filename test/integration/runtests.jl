# 1. Load the common environment
# julia -t auto  --project=. test/integration/runtests.jl
include("common_setup.jl")

@info "Starting PormG Test Suite (PostgreSQL)"

# 2. Include individual test files
# Each file now focuses only on test logic, without setup
@testset "Bateria de Testes PormG (PostgreSQL)" begin

    # CRUD Básico
    @testset "Inserções e Schema"       begin include("test_database_setup.jl") end
    @testset "Seleção e Filtros"        begin include("test_selection.jl") end
    @testset "Atualizações (Updates)"   begin include("test_updates.jl") end
    @testset "Bulk copy"                begin include("test_bulk_copy.jl") end
    @testset "Functions SQL"            begin include("test_sql_functions.jl") end

    # Funcionalidades Avançadas
    @testset "Joins e CTEs"             begin include("test_joins_cte.jl") end
    @testset "Joins com Cache"          begin include("test_cache_join.jl") end
    @testset "Transações"               begin include("test_transactions.jl") end
    @testset "Advisory Locks"           begin include("test_advisorylock.jl") end

    # Internos e Segurança
    @testset "Internals & Security"     begin include("test_internals.jl") end
    @testset "Test Password"            begin include("test_password.jl") end
    @testset "Test Password i18n"       begin include("test_password_i18n.jl") end

    # Hot-Reloading e Desenvolvimento
    @testset "Hot-Reloading"            begin include("test_reload.jl") end

end

PormG.Configuration.__cleanup__()