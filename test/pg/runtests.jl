# 1. Load the common environment
# julia -t auto  --project=. test/pg/runtests.jl
include("common_setup.jl")

@info "Starting PormG Test Suite (PostgreSQL)"

# 2. Include individual test files
# Each file now focuses only on test logic, without setup
@testset "PormG Test Suite" begin

  @testset "Insertions and General Queries" begin
    include("test.jl")
  end
  
  @testset "Transactions" begin
    include("test_transactions.jl")
  end  

  # Add new files here as the project grows
end