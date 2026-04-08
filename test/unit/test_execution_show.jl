using Test
using PormG: object, Q
using PormG.Models: Model, CharField, IDField
import PormG
import DataFrames

# Initialize a dummy model for testing
TestDriver = Model("drivers",
  id=IDField(),
  forename=CharField(),
  surname=CharField()
)
TestDriver.connect_key = "default"

# Setup a default connection mock
# We don't need a real working connection because we'll only use show_query=:dict
# which returns before any actual database call.
struct MockPostgres <: PormG.PormGPostgres end
MockSettings = PormG.Configuration.Settings(
  connections=MockPostgres(),
  change_data=true
)
PormG.config["default"] = MockSettings

@testset "Execution show_query return values" begin
  q = TestDriver.objects.filter("forename" => "Lewis")

  # query with :dict
  res = q.list(show_query=:dict)
  @test res isa Dict
  @test haskey(res, :sql_text)
  @test haskey(res, :parameters)
  @test res[:parameters] == ["Lewis"]

  # query with :sql
  sql = q.list(show_query=:sql)
  @test sql isa String
  @test contains(sql, "drivers")
  @test contains(sql, "WHERE")

  # query with :params
  params = q.list(show_query=:params)
  @test params == ["Lewis"]

  # bulk_insert with :dict
  df = DataFrames.DataFrame(forename=["Max", "Fernando"], surname=["Verstappen", "Alonso"])
  res_bulk = TestDriver |> PormG.QueryBuilder.bulk_insert(df, show_query=:dict)
  @test res_bulk isa Dict
  @test haskey(res_bulk, :sql_text)
  @test res_bulk[:parameters] == ["Max", "Verstappen", "Fernando", "Alonso"]

  # bulk_update with :dict
  df_update = DataFrames.DataFrame(id=[1, 2], forename=["Max", "Fernando"], surname=["Verstappen", "Alonso"])
  res_update = TestDriver |> PormG.QueryBuilder.bulk_update(df_update, show_query=:dict)
  @test res_update isa Dict
  @test haskey(res_update, :sql_text)
  # bulk_update for postgres involves JOIN or WHERE source.id = table.id
  # We just care if it returns the dict and some params
  @test !isempty(res_update[:parameters])
end
