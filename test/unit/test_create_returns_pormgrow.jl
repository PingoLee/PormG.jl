using Test
using DataFrames
using PormG
using PormG.Models: Model, CharField, IDField
import PormG.ConnectionPool: fetch

# ─────────────────────────────────────────────────────────────────────────────
# create()/insert() return a PormGRow (#166)
#
# DB-free: a mock PG connection answers the INSERT ... RETURNING <declared columns> with a full row, so create()
# on the :execute path wraps it into a PormGRow (the same object get()/first()/list() return).
# The show_query=:dict path must still return the inspection Dict — the dual contract is unchanged.
# (SQLite's INSERT + read-back path is covered end-to-end in test/integration/test_inserts.jl.)
# ─────────────────────────────────────────────────────────────────────────────

CreateRowModel = Model("crow", id = IDField(), name = CharField())
CreateRowModel.connect_key = "create_pormgrow"

struct MockPgCreate <: PormG.PormGPostgres end

# create() PG path issues `INSERT ... RETURNING <declared columns>` (#1490); hand back a full row to wrap.
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
  # A freshly-created row starts clean — .save() is a no-op until mutated. Since #1591 the dirty set
  # is not allocated until the first assignment, so the slot is `nothing`.
  @test getfield(row, :_dirty) === nothing
end

# #1591: a terminal hands its row `Dict` over to the `PormGRow` it returns instead of having it copied,
# and the dirty set `save` reads is allocated on the first assignment rather than for every row. No SQL
# is involved beyond the mocked INSERT ... RETURNING above. It matters because `list()` builds one row
# per result row, and the copy plus an empty `Set` were two of its three containers per row (#41). The
# behaviour a caller sees must not move: the public constructor still copies the caller's `Dict`,
# `row._dirty` is still a live `Set`, and a clean row's `.save()` still issues nothing.
@testset "a terminal's row owns its Dict and allocates its dirty set lazily (#1591)" begin
  QB = PormG.QueryBuilder

  # The public constructor copies: the caller's Dict and the row's are independent.
  source = Dict{Symbol,Any}(:id => 7, :name => "Senna")
  row = PormG.PormGRow(source, CreateRowModel)
  @test getfield(row, :_data) !== source
  source[:name] = "Prost"
  @test row.name == "Senna"
  # A narrower value type is widened by the same copy.
  narrow = PormG.PormGRow(Dict(:id => 7, :name => "Senna"), CreateRowModel)
  @test getfield(narrow, :_data) isa Dict{Symbol,Any}

  # The terminals' constructor takes ownership: no copy.
  owned_data = Dict{Symbol,Any}(:id => 7, :name => "Senna")
  owned = QB._owned_row(owned_data, CreateRowModel)
  @test getfield(owned, :_data) === owned_data
  @test getfield(owned, :_dirty) === nothing

  # A clean row saves nothing and stays unallocated.
  @test owned.save() === owned
  @test getfield(owned, :_dirty) === nothing

  # `row._dirty` is a live Set: reading it allocates the slot, and what is pushed into it is kept.
  live = owned._dirty
  @test live isa Set{Symbol} && isempty(live)
  @test getfield(owned, :_dirty) === live
  push!(owned._dirty, :name)
  @test :name in getfield(owned, :_dirty)

  # The first assignment allocates the set and records the field.
  fresh = QB._owned_row(Dict{Symbol,Any}(:id => 7, :name => "Senna"), CreateRowModel)
  fresh.name = "Prost"
  @test getfield(fresh, :_dirty) == Set([:name])
  @test fresh[:name] == "Prost"

  # A created row's dirty slot is unset.
  created = CreateRowModel.objects.create("name" => "Senna")
  @test getfield(created, :_dirty) === nothing
end

# #1591: which constructor a terminal calls cannot be observed through the row it returns — an owned
# `Dict` and a copied one read the same — so the ownership is pinned at the source. Every `src/` and
# `ext/` call that builds a `PormGRow` goes through `_owned_row`; the copying public constructor is
# called only from `types.jl`, where both are defined. A terminal written later with `PormGRow(dict,
# model)` would copy every row again, and nothing else would notice. No SQL is involved.
@testset "every src/ terminal builds its row with _owned_row (#1591)" begin
  root = pkgdir(PormG)
  copying_calls = String[]
  owned_calls = 0
  for dir in ("src", "ext"), (path, _, files) in walkdir(joinpath(root, dir)), file in files
    endswith(file, ".jl") || continue
    full = joinpath(path, file)
    rel = relpath(full, root)
    for (n, line) in enumerate(eachline(full))
      startswith(strip(line), "#") && continue             # a whole-line comment
      code = strip(first(split(line, '#'; limit = 2)))     # a trailing comment cut off
      owned_calls += count(r"\b_owned_row\(", code)
      rel == joinpath("src", "querybuilder", "types.jl") && continue
      occursin(r"\bPormGRow\(", code) && push!(copying_calls, "$rel:$n")
    end
  end
  @test isempty(copying_calls)
  # `list()` and the seven write-terminal sites (#1591), plus the definition itself.
  @test owned_calls >= 9
end

@testset "create(show_query=:dict) still returns the inspection Dict (dual contract)" begin
  d = CreateRowModel.objects.create("name" => "Prost", show_query = :dict)
  @test d isa Dict
  @test !(d isa PormG.QueryBuilder.PormGRow)
  @test haskey(d, :sql_text)
end

@testset "pk accessor, .pk property, and honest reflection" begin
  row = CreateRowModel.objects.create("name" => "Senna")   # RETURNING → id = 7

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
  # it inserts and hands back the `RETURNING` row — the third call site.
  grow, gcreated = DurRowModel.objects.get_or_create("label" => "pit";
    defaults = ["dur" => Second(23), "day" => Date(2011, 4, 10)])
  @test gcreated
  @test grow.dur isa Dates.CompoundPeriod
  @test grow.dur == Second(23)
end
