"""
Comprehensive test suite for complex query scenarios and API coverage.
Tests show_query return values, parameter handling, and execution modes.

These tests use show_query mode to inspect SQL/parameters without requiring
a live database connection. Some complex join tests are deferred for integration tests.
"""

using Test
using PormG
using PormG.Models: Model, CharField, IDField, IntegerField
using PormG.QueryBuilder: Q, Qor, F
import DataFrames

# Initialize test models - kept simple to focus on query generation
DriverModel = Model("drivers",
  id = IDField(),
  forename = CharField(),
  surname = CharField(),
  nationality = CharField()
)
DriverModel.connect_key = "default"

RaceModel = Model("races",
  id = IDField(),
  name = CharField(),
  year = IntegerField()
)
RaceModel.connect_key = "default"

# Mock settings for test mode (no DB connection needed when using show_query)
struct MockPostgres <: PormG.PormGPostgres end
MockSettings = PormG.Configuration.Settings(
    connections = MockPostgres(),
    change_data = true
)
PormG.config["default"] = MockSettings

@testset "Complex Query Coverage" begin

  # ===== Section 1: Basic Filters with Operators =====
  @testset "Filter Operators" begin
    # Test: Greater than operator
    q = RaceModel.objects
    q.filter("year__@gt" => 2020)
    res = q |> list(show_query=:dict)
    
    @test res isa Dict
    @test haskey(res, :sql_text)
    @test haskey(res, :parameters)
    @test res[:parameters] == [2020]
    @test contains(res[:sql_text], ">")
    
    # Test: Less than or equal operator
    q2 = RaceModel.objects
    q2.filter("year__@lte" => 1990)
    res2 = q2 |> list(show_query=:dict)
    
    @test res2[:parameters] == [1990]
    @test contains(res2[:sql_text], "<=")
    
    # Test: Not equal operator
    q3 = RaceModel.objects
    q3.filter("year__@neq" => 2021)
    res3 = q3 |> list(show_query=:dict)
    
    @test res3[:parameters] == [2021]
  end
  
  # ===== Section 2: String Pattern Matching =====
  @testset "String Pattern Matching" begin
    # Test: contains/icontains for LIKE
    q = DriverModel.objects
    q.filter("forename__@contains" => "lew")
    res = q |> list(show_query=:dict)
    
    @test res isa Dict
    @test contains(res[:sql_text], "LIKE") || contains(res[:sql_text], "LOWER")
    
    # Test: Multiple string filters
    q2 = DriverModel.objects
    q2.filter("nationality" => "British")
    q2.filter("forename__@contains" => "lewis")
    res2 = q2 |> list(show_query=:dict)
    
    @test length(res2[:parameters]) >= 2
    @test contains(res2[:sql_text], "WHERE")
  end
  
  # ===== Section 3: Ordering + Limiting + Offset =====
  @testset "Pagination and Ordering" begin
    # Test: ORDER BY with LIMIT and OFFSET
    q = DriverModel.objects
    q.order_by("forename")  # ascending order
    q.limit(10)
    q.offset(5)
    res = q |> list(show_query=:dict)
    
    @test res isa Dict
    @test contains(res[:sql_text], "ORDER BY")
    @test contains(res[:sql_text], "LIMIT 10")
    @test contains(res[:sql_text], "OFFSET 5")
  end
  
  # ===== Section 4: Multiple Filters =====
  @testset "Multiple Filters" begin
    # Test: Multiple filter conditions (AND logic)
    q = DriverModel.objects
    q.filter("nationality" => "British")
    q.filter("forename__@contains" => "lewis")
    res = q |> list(show_query=:dict)
    
    @test res isa Dict
    @test contains(res[:sql_text], "WHERE")
    @test contains(res[:sql_text], "AND")
    @test length(res[:parameters]) >= 2
  end
  
  # ===== Section 5: DISTINCT Queries =====
  @testset "Distinct Queries" begin
    # Test: DISTINCT to eliminate duplicates
    q = DriverModel.objects
    q.distinct(true)
    q.filter("nationality" => "Italian")
    res = q |> list(show_query=:dict)
    
    @test res isa Dict
    @test contains(res[:sql_text], "DISTINCT")
    @test res[:parameters] == ["Italian"]
  end
  
  # ===== Section 6: Value Selection =====
  @testset "Value Selection" begin
    # Test: Selecting specific fields (projection)
    q = DriverModel.objects
    q.values("forename", "surname", "nationality")
    res = q |> list(show_query=:dict)
    
    @test res isa Dict
    @test contains(res[:sql_text], "SELECT")
    @test contains(res[:sql_text], "forename")
    @test contains(res[:sql_text], "surname")
    @test contains(res[:sql_text], "nationality")
  end
  
  # ===== Section 7: show_query API Modes =====
  @testset "show_query Return Modes" begin
    q = DriverModel.objects
    q.filter("nationality" => "German")
    
    # Mode: :dict (default structured format)
    res_dict = q |> list(show_query=:dict)
    @test res_dict isa Dict
    @test haskey(res_dict, :sql_text)
    @test haskey(res_dict, :parameters)
    
    # Mode: :sql_text (only SQL string)
    res_sql = q |> list(show_query=:sql_text)
    @test res_sql isa String
    @test contains(res_sql, "SELECT")
    @test contains(res_sql, "drivers")
    
    # Mode: :params (only parameters array)
    res_params = q |> list(show_query=:params)
    @test res_params isa Vector
    @test res_params == ["German"]
    
    # Mode: :inspection (should behave like :dict)
    res_inspection = q |> list(show_query=:inspection)
    @test res_inspection isa Dict
    @test haskey(res_inspection, :sql_text)
  end
  
  # ===== Section 8: Terminal Methods with show_query =====
  @testset "Terminal Query Methods with show_query" begin
    # Test: list() returns different formats based on show_query
    q = DriverModel.objects
    q.filter("nationality" => "Spanish")
    
    # Test with :dict
    res_dict = q |> list(show_query=:dict)
    @test res_dict isa Dict
    @test haskey(res_dict, :sql_text)
    
    # Test: list_json returns dict when show_query=:dict
    res_json = q |> list_json(show_query=:dict)
    @test res_json isa Dict
  end
  
  # ===== Section 9: Bulk Insert with show_query =====
  @testset "Bulk Operations" begin
    # Test: bulk_insert with show_query returns structured data
    df_insert = DataFrames.DataFrame(
      forename=["Max", "Charles", "Lewis"],
      surname=["Verstappen", "Leclerc", "Hamilton"],
      nationality=["Dutch", "Monegasque", "British"]
    )
    
    res_insert = DriverModel |> PormG.QueryBuilder.bulk_insert(df_insert, show_query=:dict)
    @test res_insert isa Dict
    @test haskey(res_insert, :sql_text)
    @test haskey(res_insert, :parameters)
    @test contains(res_insert[:sql_text], "INSERT")
    @test length(res_insert[:parameters]) >= 9  # 3 rows × 3 fields
    
    # Test: bulk_insert with :sql_text mode
    res_sql = DriverModel |> PormG.QueryBuilder.bulk_insert(df_insert, show_query=:sql_text)
    @test res_sql isa String
    @test contains(res_sql, "INSERT")
    
    # Test: bulk_insert with :params mode
    res_params = DriverModel |> PormG.QueryBuilder.bulk_insert(df_insert, show_query=:params)
    @test res_params isa Vector
  end
  
  # ===== Section 10: Multiple Chained Operations =====
  @testset "Chained Method Calls" begin
    # Test: Multiple chained operations in sequence
    q = DriverModel.objects
    q.filter("nationality" => "Dutch")
    q.order_by("forename")
    q.limit(5)
    
    res = q |> list(show_query=:dict)
    
    @test res isa Dict
    @test contains(res[:sql_text], "WHERE")
    @test contains(res[:sql_text], "ORDER BY")
    @test contains(res[:sql_text], "LIMIT 5")
    @test res[:parameters] == ["Dutch"]
  end
  
  # ===== Section 11: Complex Filter Combinations =====
  @testset "Filter Combinations" begin
    # Test: Q object with multiple conditions
    q = DriverModel.objects
    q.filter(Q("nationality" => "British", "forename__@contains" => "lew"))
    res = q |> list(show_query=:dict)
    
    @test res isa Dict
    @test contains(res[:sql_text], "WHERE")
    @test length(res[:parameters]) >= 2
    
    # Test: Multiple filters with different operators
    q2 = RaceModel.objects
    q2.filter("year__@gte" => 2010)
    q2.filter("year__@lte" => 2020)
    res2 = q2 |> list(show_query=:dict)
    
    @test contains(res2[:sql_text], "AND")
    @test length(res2[:parameters]) == 2
  end
  
  # ===== Section 12: Query Inspection Without Execution =====
  @testset "Query Inspection" begin
    # Test: Can inspect query without executing it
    q = DriverModel.objects
    q.filter("nationality" => "Italian")
    q.order_by("surname")
    q.limit(20)
    q.offset(10)
    
    # Get just the SQL text
    sql = q |> list(show_query=:sql_text)
    @test sql isa String
    @test contains(sql, "SELECT")
    @test contains(sql, "ORDER BY")
    @test contains(sql, "LIMIT 20")
    @test contains(sql, "OFFSET 10")
    
    # Get just the parameters
    params = q |> list(show_query=:params)
    @test params == ["Italian"]
    
    # Get full structure
    full = q |> list(show_query=:dict)
    @test full[:sql_text] == sql
    @test full[:parameters] == params
  end

end

