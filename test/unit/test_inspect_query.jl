"""
Comprehensive test suite for the dedicated inspect_query() API.

The inspect_query() API provides explicit, type-safe query inspection without
the ambiguity of show_query's Union{Bool, Symbol} signature. It returns a 
rich dictionary with SQL, parameters, and comprehensive metadata.

All tests use mock PostgreSQL connections (no live database required).
"""

using Test
using PormG
using PormG.Models: Model, CharField, IDField, IntegerField
using PormG.QueryBuilder: Q, Qor, F, inspect_query, list, update, delete, bulk_insert, bulk_update
import DataFrames

# Initialize test models
DriverModel = Model("drivers",
  id = IDField(),
  forename = CharField(),
  surname = CharField(),
  nationality = CharField(null=true) # Allow null for easy testing
)
DriverModel.connect_key = "default"

RaceModel = Model("races",
  id = IDField(),
  name = CharField(),
  year = IntegerField(null=true) # Allow null for easy testing
)
RaceModel.connect_key = "default"

# Mock settings for test mode (no DB connection needed)
struct MockPostgres <: PormG.PormGPostgres end
MockSettings = PormG.Configuration.Settings(
    connections = MockPostgres(),
    change_data = true
)
PormG.config["default"] = MockSettings

@testset "Dedicated Inspection API (inspect_query)" begin

  # ===== Section 1: Basic Inspection Structure =====
  @testset "Inspection Result Structure" begin
    # Test: inspect_query returns a Dict with all required fields
    q = DriverModel.objects
    q.filter("nationality" => "British")
    
    result = inspect_query(q)
    
    @test result isa Dict
    # Check for required fields
    @test haskey(result, :sql_text)
    @test haskey(result, :parameters)
    @test haskey(result, :dialect)
    @test haskey(result, :model)
    @test haskey(result, :operation)
    @test haskey(result, :bucketing)
    @test haskey(result, :parameter_count)
    @test haskey(result, :parameter_buckets)
  end

  # ===== Section 2: Operation Detection Metadata =====
  @testset "Operation Type Detection" begin
    # Test: list(show_query=:dict) returns :operation => :select
    q = DriverModel.objects
    q.filter("nationality" => "British")
    
    res_select = list(q, show_query=:dict)
    @test res_select[:operation] === :select
    @test res_select[:model] == "drivers"
    
    # Test: update(show_query=:dict) returns :operation => :update
    # We mock the return as it wouldn't connect but show_query handles cases before fetch
    res_update = q.update("forename" => "Lewis", show_query=:dict)
    @test res_update[:operation] === :update
    @test res_update[:model] == "drivers"
    @test contains(res_update[:sql_text], "UPDATE")
    
    # Test: delete(show_query=:dict) returns :operation => :delete
    res_delete = delete(q, show_query=:dict)
    @test res_delete[:operation] === :delete
    @test res_delete[:model] == "drivers"
    @test contains(res_delete[:sql_text], "DELETE")

    # Test: bulk_insert(show_query=:dict) returns :operation => :insert
    df = DataFrames.DataFrame(forename=["Lewis", "Valtteri"], surname=["Hamilton", "Bottas"])
    res_bulk_insert = bulk_insert(DriverModel.objects, df, show_query=:dict)
    @test res_bulk_insert[:operation] === :insert
    @test res_bulk_insert[:model] == "drivers"
    @test contains(res_bulk_insert[:sql_text], "INSERT")

    # Test: bulk_update(show_query=:dict) returns :operation => :update
    res_bulk_update = bulk_update(DriverModel.objects, df, columns=["forename"], filters=["surname"], show_query=:dict)
    @test res_bulk_update[:operation] === :update
    @test res_bulk_update[:model] == "drivers"
    @test contains(res_bulk_update[:sql_text], "UPDATE")

    # Test: inspect_query(operation=:delete) returns :operation => :delete (explicitly requested)
    res_inspect_delete = inspect_query(q, operation=:delete)
    @test res_inspect_delete[:operation] === :delete
  end

  # ===== Section 3: Operation Auto-Detection Heuristic =====
  @testset "Heuristic Operation Detection" begin
    # Test: Auto-detect :select (default)
    q = DriverModel.objects.filter("id" => 1)
    res = inspect_query(q)
    @test res[:operation] === :select
    
    # Test: Auto-detect :update (has insert data + filters)
    q_up = DriverModel.objects.filter("id" => 1)
    # Manually populate insert field for the test
    q_up.object.insert = Dict("forename" => "Ayrton")
    res_up = inspect_query(q_up)
    @test res_up[:operation] === :update
    
    # Test: Auto-detect :insert (has insert data, no filters)
    q_in = DriverModel.objects.copy()
    q_in.object.insert = Dict("forename" => "Ayrton", "surname" => "Senna")
    res_in = inspect_query(q_in)
    @test res_in[:operation] === :insert
    
    # Reset for following tests
  end

  # ===== Section 4: SQL and Parameter Correctness =====
  @testset "SQL Generation and Parameters" begin
    # Test: Simple filter generates correct SQL
    q = DriverModel.objects
    q.filter("nationality" => "Italian")
    res = inspect_query(q)
    
    @test res[:sql_text] isa String
    @test contains(res[:sql_text], "SELECT")
    @test contains(res[:sql_text], "drivers")  # May be quoted as "drivers"
    @test contains(res[:sql_text], "WHERE")
    @test res[:parameters] == ["Italian"]
    @test res[:parameter_count] == 1
    
    # Test: Multiple filters
    q2 = RaceModel.objects
    q2.filter("year__@gte" => 2010)
    q2.filter("year__@lte" => 2020)
    res2 = inspect_query(q2)
    
    @test contains(res2[:sql_text], "AND")
    @test length(res2[:parameters]) == 2
    @test res2[:parameter_count] == 2
    @test res2[:parameters] == [2010, 2020]
  end

  # ===== Section 3: Metadata Fields =====
  @testset "Metadata Accuracy" begin
    # Test: Model name is correctly reported
    q = DriverModel.objects
    q.filter("forename" => "Lewis")
    res = inspect_query(q)
    
    @test res[:model] == "drivers"
    @test res[:operation] == :select
    
    # Test: Operation type detection (all read queries are :select in current implementation)
    q2 = RaceModel.objects
    q2.limit(5)
    res2 = inspect_query(q2)
    
    @test res2[:model] == "races"
    @test res2[:operation] == :select
  end

  # ===== Section 4: Dialect Detection =====
  @testset "Dialect Detection" begin
    # Test: PostgreSQL dialect is detected from mock connection
    q = DriverModel.objects
    res = inspect_query(q)
    
    @test res[:dialect] == :postgresql
    @test res[:bucketing] == :numbered
  end

  # ===== Section 5: Complex Query Inspection =====
  @testset "Complex Queries" begin
    # Test: Chained operations all reflected in inspection
    q = DriverModel.objects
    q.filter("nationality" => "Dutch")
    q.order_by("forename")
    q.limit(10)
    q.offset(5)
    q.distinct(true)
    
    res = inspect_query(q)
    
    @test res[:sql_text] isa String
    @test contains(res[:sql_text], "DISTINCT")
    @test contains(res[:sql_text], "ORDER BY")
    @test contains(res[:sql_text], "LIMIT 10")
    @test contains(res[:sql_text], "OFFSET 5")
    @test res[:parameters] == ["Dutch"]
    @test res[:parameter_count] == 1
  end

  # ===== Section 6: Query Projection (Values) =====
  @testset "Value Selection Inspection" begin
    # Test: Selected fields are reflected in SQL
    q = DriverModel.objects
    q.values("forename", "surname", "nationality")
    q.filter("nationality" => "German")
    
    res = inspect_query(q)
    
    @test contains(res[:sql_text], "forename")
    @test contains(res[:sql_text], "surname")
    @test contains(res[:sql_text], "nationality")
    @test res[:parameters] == ["German"]
  end

  # ===== Section 7: Multiple Filter Types =====
  @testset "Operator Inspection" begin
    # Test: Various operators generate expected SQL
    q = RaceModel.objects
    q.filter("year__@gt" => 2000)
    res = inspect_query(q)
    
    @test contains(res[:sql_text], ">")
    @test res[:parameters] == [2000]
    
    # Test: Contains operator
    q2 = DriverModel.objects
    q2.filter("forename__@contains" => "lew")
    res2 = inspect_query(q2)
    
    @test contains(res2[:sql_text], "LIKE") || contains(res2[:sql_text], "LOWER")
  end

  # ===== Section 8: Parameter Ordering Verification =====
  @testset "Parameter Ordering" begin
    # Test: Parameters appear in the order they're added
    q = DriverModel.objects
    q.filter("nationality" => "British")
    q.filter("forename__@contains" => "lewis")
    q.order_by("surname")  # ordering adds no parameters
    
    res = inspect_query(q)
    
    # Parameters should be in the order: WHERE clauses (British), then WHERE clauses (escaped for LIKE)
    @test length(res[:parameters]) == 2
    @test res[:parameters][1] == "British"
    # LIKE operator adds % for pattern matching, so check for that pattern
    @test contains(res[:parameters][2], "lewis")
  end

  # ===== Section 9: Curried API =====
  @testset "Curried Method Syntax" begin
    # Test: Pipe syntax works with curried inspect_query
    q = DriverModel.objects
    q.filter("nationality" => "Spanish")
    
    res = q |> inspect_query()
    
    @test res isa Dict
    @test haskey(res, :sql_text)
    @test res[:model] == "drivers"
  end

  # ===== Section 10: Empty Query Inspection =====
  @testset "Empty Query" begin
    # Test: Query without filters still inspects correctly
    q = RaceModel.objects
    
    res = inspect_query(q)
    
    @test res[:sql_text] isa String
    @test contains(res[:sql_text], "SELECT")
    @test contains(res[:sql_text], "races")  # May be quoted as "races"
    @test isempty(res[:parameters])
    @test res[:parameter_count] == 0
  end

  # ===== Section 11: Distinct Inspection =====
  @testset "Distinct Queries" begin
    # Test: DISTINCT modifier is visible in inspection
    q = DriverModel.objects
    q.distinct(true)
    q.filter("nationality" => "French")
    
    res = inspect_query(q)
    
    @test contains(res[:sql_text], "DISTINCT")
    @test res[:parameters] == ["French"]
  end

  # ===== Section 12: Deep Copy Safety =====
  @testset "Query Immutability" begin
    # Test: Inspecting a query doesn't modify it
    q = DriverModel.objects
    q.filter("nationality" => "Swedish")
    
    # First inspection
    res1 = inspect_query(q)
    params1 = deepcopy(res1[:parameters])
    
    # Modify the query after inspection
    q.filter("forename" => "Valtteri")
    
    # Second inspection should reflect the new filter
    res2 = inspect_query(q)
    
    @test res1[:parameter_count] == 1
    @test res2[:parameter_count] == 2
    @test res2[:parameters] == ["Swedish", "Valtteri"]
  end

  # ===== Section 13: show_query Validation =====
  @testset "show_query Mode Validation" begin
    # Test: Invalid show_query modes throw error
    q = DriverModel.objects
    
    # Valid modes should work (using show_query to avoid actual DB execution with MockPostgres)
    @test (q |> PormG.QueryBuilder.list(show_query=:dict)) isa Dict
    # @test (q |> PormG.QueryBuilder.list(show_query=:sql_text)) isa String # REMOVED
    @test (q |> PormG.QueryBuilder.list(show_query=:params)) isa Vector
    @test (q |> PormG.QueryBuilder.list(show_query=true)) isa String # NOW RETURNS STRING
    
    # Invalid mode should throw
    @test_throws ArgumentError (q |> PormG.QueryBuilder.list(show_query=:invalid))
  end

  # ===== Section 14: Comparison: inspect_query vs show_query =====
  @testset "API Consistency" begin
    # Test: inspect_query and show_query=:dict return same core data
    q1 = DriverModel.objects
    q1.filter("nationality" => "Monaco")
    
    q2 = DriverModel.objects
    q2.filter("nationality" => "Monaco")
    
    # Using dedicated API
    inspection = inspect_query(q1)
    
    # Using show_query (for backward compatibility)
    show_result = q2 |> PormG.QueryBuilder.list(show_query=:dict)
    
    # Core SQL and parameters should match
    @test inspection[:sql_text] == show_result[:sql_text]
    @test inspection[:parameters] == show_result[:parameters]
    
    # But inspection has richer metadata
    @test haskey(inspection, :dialect)
    @test haskey(inspection, :bucketing)
    @test haskey(inspection, :parameter_buckets)
  end

  # ===== Section 15: Q Object Filters =====
  @testset "Q Object Inspection" begin
    # Test: Q objects with multiple conditions
    q = DriverModel.objects
    q.filter(Q("nationality" => "British", "forename__@contains" => "lew"))
    
    res = inspect_query(q)
    
    @test res isa Dict
    @test length(res[:parameters]) >= 2
    @test contains(res[:sql_text], "WHERE")
  end

  # ===== Section 16: Parameter Bucket Visibility (SQLite Focus) =====
  @testset "Parameter Buckets" begin
    # Test: Inspection reveals bucket structure (PostgreSQL shows empty since not positional)
    q = DriverModel.objects
    q.filter("nationality" => "Canadian")
    
    res = inspect_query(q)
    
    # For PostgreSQL, bucket_breakdown should be empty
    @test res[:parameter_buckets] isa Dict
    # For positional databases, it would show the breakdown
  end

end
