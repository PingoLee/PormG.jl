using Test
using DataFrames
using PormG
using PormG.Models: Model, CharField, IDField
import PormG.ConnectionPool: fetch

# ─────────────────────────────────────────────────────────────────────────────
# create()/insert() return a PormGRow (#166)
#
# DB-free: a mock PG connection answers the INSERT ... RETURNING * with a full row, so create()
# on the :execute path wraps it into a PormGRow (the same object get()/first()/list() return).
# The show_query=:dict path must still return the inspection Dict — the dual contract is unchanged.
# (SQLite's INSERT + read-back path is covered end-to-end in test/integration/test_inserts.jl.)
# ─────────────────────────────────────────────────────────────────────────────

CreateRowModel = Model("crow", id = IDField(), name = CharField())
CreateRowModel.connect_key = "create_pormgrow"

struct MockPgCreate <: PormG.PormGPostgres end

# create() PG path issues `INSERT ... RETURNING *`; hand back a full row to wrap.
function fetch(connection::MockPgCreate, sql::String;
  conn = nothing, params = nothing, ignore_tx::Bool = false)
  if occursin("INSERT INTO", sql) && occursin("RETURNING", sql)
    return DataFrame(id = [7], name = ["Senna"])
  end
  return DataFrame()
end

PormG.config["create_pormgrow"] =
  PormG.Configuration.Settings(connections = MockPgCreate(), change_data = true)

@testset "create() returns a PormGRow on execute (#166)" begin
  row = CreateRowModel.objects.create("name" => "Senna")

  @test row isa PormG.QueryBuilder.PormGRow
  @test !(row isa Dict)                 # no longer a bare Dict
  @test row[:id] == 7                   # delegated indexing still works
  @test row[:name] == "Senna"
  @test row.name == "Senna"             # PormGRow dot-access
  @test haskey(row, :id)
  # A freshly-created row starts clean (empty dirty set) — .save() is a no-op until mutated.
  @test isempty(getfield(row, :_dirty))
end

@testset "create(show_query=:dict) still returns the inspection Dict (dual contract)" begin
  d = CreateRowModel.objects.create("name" => "Prost", show_query = :dict)
  @test d isa Dict
  @test !(d isa PormG.QueryBuilder.PormGRow)
  @test haskey(d, :sql_text)
end
