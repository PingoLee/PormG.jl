"""
PormG's internal reads use rows, not a `DataFrame` (#1344 phase 2).

`fetch` returns the driver's Tables.jl source. Migrations, introspection and a handful of query-builder
helpers used to turn it into a `DataFrame` only to index it (`nrow`, `df[1, :n]`, `eachrow`). Since
#1344 phase 2 they read `fetch(...) |> Tables.rowtable`, the idiom the write path already used, so
`DataFrames` and `CSV` are left to the bulk writes and can then leave `[deps]` (phases 3 to 6).

Two things are checked here:
1. A ratchet on where `DataFrames` and `CSV` may still be named in `src/` and `ext/`. Every file is
   parsed, so a comment or a docstring never counts, and a name that resolved implicitly through
   `using DataFrames` is caught as a symbol. A file outside the allow-list fails. A file whose set
   shrinks fails too, until the list is shrunk with it, so each later phase records its progress.
2. The one exported function that took a DataFrames type: `convertSQLToModel(row)` takes a row of the
   PostgreSQL schema dump. That dump is now a row vector, so the function reads any Tables.jl row, and
   a `NamedTuple` and a `DataFrameRow` give the same model. (`check`'s walk over the same rows is
   tested in `test_generated_columns.jl`.)

Hermetic: no database.

julia --project=test/integration test/unit/test_internal_rows_1344.jl
"""

using Test
using PormG
using PormG.Migrations: convertSQLToModel
import DataFrames: DataFrame
import JSON

const _IR_ROOT = pkgdir(PormG)

# The names that mean "this file uses DataFrames or CSV". A `QuoteNode` (`:nrow`) is data, not a
# binding, and is skipped, except as the right side of a dot: `PormG.DataFrames.DataFrame` parses as
# `DataFrame` quoted.
const _IR_NAMES = Set([:DataFrame, :DataFrames, :DataFrameRow, :AbstractDataFrame,
                       :nrow, :ncol, :eachrow, :eachcol, :CSV])

# The reviewed list. Each later phase of #1344 shrinks it, and phase 6 (DataFrames and CSV leave
# `[deps]`) deletes it with this testset.
const _IR_ALLOWED = Dict{String, Set{Symbol}}(
  # Since phase 3 the bulk writes take any Tables.jl table, and since phase 4 `returning=` answers in
  # the caller's kind. What is left: `bulk_copy` writes through CSV (phase 5).
  "src/querybuilder/execution_bulk.jl" => Set([:CSV]),
  # The module imports DataFrames and CSV are reached through (phase 6).
  "src/PormG.jl"                       => Set([:DataFrames]),
  "src/QueryBuilder.jl"                => Set([:DataFrames, :CSV]),
)

_ir_collect!(found, x) = found
_ir_collect!(found, x::Symbol) = (x in _IR_NAMES && push!(found, x); found)
function _ir_collect!(found, x::Expr)
  x.head === :. && length(x.args) == 2 && x.args[2] isa QuoteNode && _ir_collect!(found, x.args[2].value)
  foreach(a -> _ir_collect!(found, a), x.args)
  return found
end

function _ir_scan()
  out = Dict{String, Set{Symbol}}()
  for top in ("src", "ext"), (dir, _, files) in walkdir(joinpath(_IR_ROOT, top)), f in files
    endswith(f, ".jl") || continue
    path = joinpath(dir, f)
    found = _ir_collect!(Set{Symbol}(), Meta.parseall(read(path, String); filename = path))
    isempty(found) || (out[replace(relpath(path, _IR_ROOT), '\\' => '/')] = found)
  end
  return out
end

@testset "Internal reads use rows, not a DataFrame (#1344 phase 2)" begin

  # Expected: exactly the allow-list. Why it matters: a new `fetch(...) |> DataFrame` anywhere else
  # would put DataFrames back on a path that phase 6 takes it off, and nothing else would notice until
  # `using PormG` failed without it.
  @testset "DataFrames and CSV are named only where the bulk writes need them" begin
    found = _ir_scan()
    extra = sort([f => sort(collect(syms)) for (f, syms) in found if !haskey(_IR_ALLOWED, f)]; by = first)
    @test isempty(extra)
    isempty(extra) || @info "Read with `fetch(...) |> Tables.rowtable` instead of a DataFrame" extra
    for (f, allowed) in _IR_ALLOWED
      # A shrink fails too: shrink `_IR_ALLOWED` with it, so the next phase starts from the truth.
      @test get(found, f, Set{Symbol}()) == allowed
    end
  end

  # One row of the PostgreSQL schema dump, as the reader receives it now (a `NamedTuple`) and as
  # `convertSQLToModel` received it before (a `DataFrameRow`). Expected: the same model source.
  # Why it matters: `convertSQLToModel(row)` is exported, and a caller's own frame must keep working.
  col(name, type; notnull = false) =
    Dict{String, Any}("name" => name, "type" => type, "notnull" => notnull, "default" => nothing,
                      "identity" => "", "unique" => false, "non_negative_check" => false,
                      "byte_limit" => nothing)
  columns = JSON.json([col("driverid", "integer"; notnull = true), col("surname", "varchar(40)"),
                       col("dob", "date")])
  primary_keys = JSON.json(["driverid"])
  indexes = JSON.json([Dict("column" => "surname", "name" => "driver_surname_idx")])

  @testset "convertSQLToModel reads any Tables.jl row" begin
    nt = (table_name = "driver", columns = columns, primary_keys = primary_keys,
          foreign_keys = missing, indexes = indexes)
    dfrow = DataFrame([nt])[1, :]
    from_nt = convertSQLToModel(nt)
    @test PormG.Models.Model_to_str(from_nt) == PormG.Models.Model_to_str(convertSQLToModel(dfrow))
    @test from_nt.fields["dob"] isa PormG.Models.sDateField
    @test from_nt.fields["surname"].db_index
    # A column the row does not carry degrades to "none", as a `missing` one does (the reader's
    # "degrade, never abort" policy): no `indexes` and no `foreign_keys` at all.
    bare = convertSQLToModel((table_name = "driver", columns = columns, primary_keys = primary_keys))
    @test !bare.fields["surname"].db_index
  end
end
