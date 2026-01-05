# 1. Load the common environment
# julia -t auto  --project=. test/pg/runtests.jl
include("common_setup.jl")

@info "Starting PormG Test Suite (PostgreSQL)"

# 2. Include individual test files
# Each file now focuses only on test logic, without setup
@testset "Bateria de Testes PormG (PostgreSQL)" begin

    # CRUD Básico
    @testset "Inserções e Schema" begin include("test_database_setup.jl") end
    @testset "Seleção e Filtros"  begin include("test_selection.jl") end
    @testset "Atualizações (Updates)" begin include("test_updates.jl") end

    # Funcionalidades Avançadas
    @testset "Joins e CTEs"       begin include("test_joins_cte.jl") end
    @testset "Transações"         begin include("test_transactions.jl") end

    # Internos e Segurança
    @testset "Internals & Security" begin include("test_internals.jl") end

end

PormG.Configuration.__cleanup__()