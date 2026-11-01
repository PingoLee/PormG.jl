"""
PormG names neither DataFrames nor CSV (#1344), and its internal reads use rows, not a `DataFrame`.

`fetch` returns the driver's Tables.jl source. Migrations, introspection and a handful of query-builder
helpers used to turn it into a `DataFrame` only to index it (`nrow`, `df[1, :n]`, `eachrow`). Since
#1344 phase 2 they read `fetch(...) |> Tables.rowtable`; phases 3 to 5 took the bulk writes off both
packages, and phase 6 took them out of `[deps]`.

Two things are checked here:
1. Neither package is in `Project.toml`'s `[deps]`, and no file in `src/` or `ext/` names either.
   Every file is parsed, so a comment or a docstring never counts, and a name that would have resolved
   through `using DataFrames` (`nrow`, `eachrow`) is caught as a symbol. Precompilation already fails
   on an `import DataFrames`; a bare `nrow` on a path the suite never runs would fail only there.
2. The one exported function that took a DataFrames type: `convertSQLToModel(row)` takes a row of the
   PostgreSQL schema dump. That dump is now a row vector, so the function reads any Tables.jl row, and
   a `NamedTuple` and a `DataFrameRow` give the same model. (`check`'s walk over the same rows is
   tested in `test_generated_columns.jl`.) DataFrames is a test-only dependency here.

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

# A `[deps]` entry, read section-aware without a TOML dependency (the `test` target does not carry the
# TOML stdlib; `test_compat_guards.jl` reads `[compat]` the same way).
function _ir_deps()
  names = Set{String}()
  section = ""
  for raw in eachline(joinpath(_IR_ROOT, "Project.toml"))
    line = strip(raw)
    startswith(line, "[") && (section = line; continue)
    section == "[deps]" || continue
    m = match(r"^([A-Za-z0-9_]+)\s*=", line)
    m === nothing || push!(names, String(m.captures[1]))
  end
  return names
end

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

@testset "PormG names neither DataFrames nor CSV; internal reads use rows (#1344)" begin

  # Expected: neither package in `[deps]`. Why it matters: every app that loads PormG would load both
  # again, 43% of `using PormG`'s import time when #1344 measured it.
  # Not on CI's `floor-resolve` job: its `julia-downgrade-compat` step rewrites `Project.toml` and
  # promotes every `[targets].test` name, CSV and DataFrames included, into `[deps]` (the reason Aqua's
  # `stale_deps` is off there too; see `test/runtests.jl`). The subprocess check below still runs there.
  # `ENV` is read here, not `runtests.jl`'s constant, because this file also runs on its own.
  @testset "DataFrames and CSV are not in [deps]" begin
    if get(ENV, "PORMG_FLOOR_RESOLVE", "0") == "1"
      @test_skip "PORMG_FLOOR_RESOLVE=1: Project.toml is the downgrade action's rewrite"
    else
      deps = _ir_deps()
      @test "Tables" in deps   # the reader works: it found the section
      @test !("DataFrames" in deps)
      @test !("CSV" in deps)
    end
  end

  # Expected: a fresh process that runs `using PormG`, in this same environment (which has both
  # packages installed, for the tests), has loaded neither. Why it matters: the `[deps]` check above
  # sees direct dependencies only; a new dependency that pulls DataFrames in would bring the cost back
  # with nothing in `src/` naming it.
  @testset "using PormG loads neither DataFrames nor CSV" begin
    probe = "using PormG; print(join(sort([p.name for p in keys(Base.loaded_modules) " *
            "if p.name in (\"DataFrames\", \"CSV\")]), \",\"))"
    cmd = `$(Base.julia_cmd()) --startup-file=no --project=$(Base.active_project()) -e $probe`
    @test readchomp(cmd) == ""
  end

  # Expected: no file in `src/` or `ext/` names either package or a DataFrames verb. Why it matters:
  # a `fetch(...) |> DataFrame` or an `nrow` would raise `UndefVarError` at run time, on whichever path
  # the unit suite does not reach.
  @testset "src/ and ext/ name neither DataFrames nor CSV" begin
    found = sort([f => sort(collect(syms)) for (f, syms) in _ir_scan()]; by = first)
    @test isempty(found)
    isempty(found) || @info "Read with `fetch(...) |> Tables.rowtable` instead of a DataFrame" found
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
