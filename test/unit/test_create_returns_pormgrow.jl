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
    @test e isa PormGError && occursin("no single-column primary key", e.msg)
  end

  # Edge: pk column absent from the row's data — distinct "missing column" throw / default behavior.
  missing_pk = PormG.QueryBuilder.PormGRow(Dict{Symbol, Any}(:name => "x"), CreateRowModel)
  @test pk(missing_pk, nothing) === nothing
  try
    pk(missing_pk); @test false
  catch e
    @test e isa PormGError && occursin("missing its primary-key column", e.msg)
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# #800 — the row a write hands back goes through the #564 read table, as `list()` does.
#
# Postgres.jl delivers a one-component INTERVAL as a bare `Period` (`Second(23)` for a 23-second pit
# stop); the same column read through a query is a `Dates.CompoundPeriod` (#581). Before #800 the
# `RETURNING *` row skipped the table, so `create()` and a re-read disagreed on the type. The mock
# hands back exactly what Postgres.jl does, so this fails on the unpatched call sites.
# ─────────────────────────────────────────────────────────────────────────────

using Dates
using PormG.Models: DurationField, DateField

DurRowModel = Model("durrow", id = IDField(), label = CharField(), dur = DurationField(), day = DateField())
DurRowModel.connect_key = "create_pormgrow_dur"

struct MockPgDuration <: PormG.PormGPostgres end

function fetch(connection::MockPgDuration, sql::String;
  conn = nothing, params = nothing, ignore_tx::Bool = false)
  occursin("INSERT INTO", sql) && occursin("RETURNING", sql) || return DataFrame()
  row = DataFrame(id = [9], label = ["pit"], dur = [Second(23)], day = [Date(2011, 4, 10)])
  occursin("__pormg_created", sql) && (row.__pormg_created = [true])
  return row
end

PormG.config["create_pormgrow_dur"] =
  PormG.Configuration.Settings(connections = MockPgDuration(), change_data = true)

@testset "a written row's INTERVAL reads back as a CompoundPeriod (#800)" begin
  row = DurRowModel.objects.create("label" => "pit", "dur" => Second(23), "day" => Date(2011, 4, 10))
  @test row.dur isa Dates.CompoundPeriod
  @test row.dur == Second(23)
  # A kind whose PostgreSQL value is already typed has no parser, and is handed back untouched.
  @test row.day === Date(2011, 4, 10)
  @test row.label == "pit"

  urow, created = DurRowModel.objects.update_or_create("label" => "pit";
    defaults = ["dur" => Second(23), "day" => Date(2011, 4, 10)])
  @test created
  @test urow.dur isa Dates.CompoundPeriod
  @test urow.dur == Second(23)
  # The sentinel column is not a field: stripped, never parsed.
  @test !haskey(getfield(urow, :_data), :__pormg_created)

  # get_or_create's miss: the lookup finds nothing (the mock answers every SELECT with no rows), so
  # it inserts and hands back the `RETURNING *` row — the third call site.
  grow, gcreated = DurRowModel.objects.get_or_create("label" => "pit";
    defaults = ["dur" => Second(23), "day" => Date(2011, 4, 10)])
  @test gcreated
  @test grow.dur isa Dates.CompoundPeriod
  @test grow.dur == Second(23)
end
