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

@testset "pk accessor, .pk property, and honest reflection" begin
  row = CreateRowModel.objects.create("name" => "Senna")   # RETURNING * → id = 7

  @test pk(row) == 7
  @test row.pk == 7                       # virtual `.pk` property
  @test pk(row, nothing) == 7

  # hasproperty/propertynames now reflect the stored columns (regression: was false).
  @test hasproperty(row, :id) && hasproperty(row, :name)
  @test !hasproperty(row, :nope)
  @test :id in propertynames(row) && :name in propertynames(row) && :save in propertynames(row)
  @test :_data ∉ propertynames(row)            # internals hidden by default
  @test :_data in propertynames(row, true)     # …shown when private=true

  # Edge: a row over a pk-less model — 1-arg throws, 2-arg returns the default.
  # Assert the message so this input is pinned to the "no pk" branch, not the "missing column" one.
  pkless = Model("nopk", label = CharField())
  bare = PormG.QueryBuilder.PormGRow(Dict{Symbol, Any}(:label => "x"), pkless)
  @test pk(bare, :none) === :none
  try
    pk(bare); @test false
  catch e
    @test e isa ArgumentError && occursin("no single-column primary key", e.msg)
  end

  # Edge: pk column absent from the row's data — distinct "missing column" throw / default behavior.
  missing_pk = PormG.QueryBuilder.PormGRow(Dict{Symbol, Any}(:name => "x"), CreateRowModel)
  @test pk(missing_pk, nothing) === nothing
  try
    pk(missing_pk); @test false
  catch e
    @test e isa ArgumentError && occursin("missing its primary-key column", e.msg)
  end
end
