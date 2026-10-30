"""
A query is a Tables.jl source (#1344 phase 1).

Until #1344, `query |> DataFrame` worked through a PormG method on `DataFrames.DataFrame`, and nothing else
could read a query as a table. Phase 1 deletes that method and implements the Tables.jl interface on
`SQLObjectHandler`, so DataFrames' generic `DataFrame(table)`, `CSV.write` and `Tables.rowtable` read a
query with no PormG method. That is the first step to taking `DataFrames` and `CSV` out of `[deps]`.

This file checks the interface and the one piece of logic behind it, `_parsed_columns`. That function
applies the #564 read parsers to a driver's columns, passes the other columns through uncopied, and keeps
Tables.jl's `CopiedColumns` marker so a sink does not copy SQLite's columns a second time. The frames
themselves (names, element types and values on every engine, before and after the change) are checked
by `test/integration/test_tables_source.jl` against a recording made before the change.

Hermetic: an in-memory SQLite database and stand-in column tables.

julia --project=test/integration test/unit/test_tables_source.jl
"""

using Test
using PormG
using PormG.Models
using Dates
import DataFrames
import DataFrames: DataFrame
import CSV

include(joinpath(@__DIR__, "..", "load_drivers.jl"))

const Tables = PormG.QueryBuilder.Tables
const _TS_QB = PormG.QueryBuilder
const _TS_CP = PormG.ConnectionPool

const _TS_KEY = normpath(joinpath(@__DIR__, "pormg1344_tables"))
const _TS_POOL = _TS_CP.SQLiteConnectionPool(":memory:"; pool_size = 1)
PormG.config[_TS_KEY] = PormG.Configuration.Settings(
    connections = _TS_POOL, change_data = true, db_def_folder = _TS_KEY)

PormG.@models_module Tables1344 "pormg1344_tables" begin
  Driver = Models.Model("tables1344_driver",
    driverid = Models.IDField(),
    surname  = Models.CharField(max_length = 40),
    dob      = Models.DateField(null = true),
    fastest  = Models.DurationField(null = true),
  )
end
import .Tables1344 as TSM

_TS_CP.fetch(_TS_POOL, PormG.Dialect.create_table(_TS_POOL, TSM.Driver))
TSM.Driver.objects.create("surname" => "Senna", "dob" => Date(1960, 3, 21), "fastest" => Millisecond(83_456))
TSM.Driver.objects.create("surname" => "Prost")   # no date of birth, no lap: the parsers pass `missing` through

_ts_query() = TSM.Driver.objects.values("driverid", "surname", "dob", "fastest").order_by("driverid")

@testset "A query is a Tables.jl source (#1344)" begin

  # The query declares itself a column-access table, and the declaration needs no database: a sink asks
  # `istable` before it reads anything. Before #1344 both were `false`, so no sink but PormG's own
  # `DataFrame` method could read a query. Expected: `true`, `true`.
  @testset "the query declares the Tables.jl interface" begin
    q = _ts_query()
    @test Tables.istable(q)
    @test Tables.columnaccess(q)
  end

  # `Tables.columns(query)` executes the query and returns its columns, with the #564 read parsers applied:
  # on SQLite a DATE is stored as text and must come back as a `Date`, an INTERVAL as a `CompoundPeriod`.
  # Expected: the projection's names in order, a `Date`, a `CompoundPeriod`, and `missing` kept. Why it
  # matters: this is the typing `list()` gives, and the table path must not lose it (#582).
  @testset "Tables.columns(query) carries the parsed values" begin
    cols = Tables.columns(_ts_query())
    @test collect(Tables.columnnames(cols)) == [:driverid, :surname, :dob, :fastest]
    dob = Tables.getcolumn(cols, :dob)
    @test dob[1] == Date(1960, 3, 21)
    @test ismissing(dob[2])
    @test Tables.getcolumn(cols, :fastest)[1] isa Dates.CompoundPeriod
    @test Tables.getcolumn(cols, :surname) == ["Senna", "Prost"]
  end

  # DataFrames reads the query through its own generic constructor; PormG defines no method. Expected:
  # the method `DataFrame(query)` dispatches to belongs to DataFrames, `PormG.QueryBuilder` has no
  # `DataFrame` binding, the frame holds a `Date`, and a keyword the old one-argument PormG method
  # refused with a `MethodError` (`copycols = false`) now works.
  @testset "DataFrame(query) is DataFrames' own constructor" begin
    @test parentmodule(which(DataFrame, Tuple{typeof(_ts_query())})) === DataFrames
    @test !isdefined(_TS_QB, :DataFrame)
    df = _ts_query() |> DataFrame
    @test DataFrames.nrow(df) == 2
    @test df.dob[1] == Date(1960, 3, 21)
    @test df.surname == ["Senna", "Prost"]
    nocopy = DataFrame(_ts_query(); copycols = false)
    @test isequal(Matrix(nocopy), Matrix(df))
  end

  # Any other sink reads the same query: a row table, and CSV. Expected: two rows with the parsed `Date`,
  # and a CSV text with the date in ISO form and the second row's empty cells. Why it matters: these were
  # not possible before #1344, and `CSV.write` is how a user exports a query without a DataFrame.
  @testset "other sinks read the query: Tables.rowtable and CSV.write" begin
    rows = Tables.rowtable(_ts_query())
    @test length(rows) == 2
    @test rows[1].dob == Date(1960, 3, 21)
    io = IOBuffer()
    CSV.write(io, _ts_query())
    text = String(take!(io))
    @test startswith(text, "driverid,surname,dob,fastest\n")
    @test occursin("1,Senna,1960-03-21,", text)
    @test occursin("2,Prost,,\n", text)
  end

  # `_parsed_columns` maps each parsed column and passes the others through as the same object (no copy).
  # A parser whose name is not a column is ignored, because the wildcard recorder registers both a field's
  # name and its `db_column`. Columns Tables.jl already copied stay marked `CopiedColumns`, so DataFrames
  # does not copy them again. A driver's own columns stay unmarked, so it does copy those. Expected: the
  # stand-in tables and the real SQLite query both keep the mark. Why it matters: losing it costs SQLite a
  # second copy of every column, which no frame comparison can see.
  @testset "_parsed_columns: maps parsed columns, passes the rest, keeps CopiedColumns" begin
    surname = ["Senna", "Prost"]
    raw = (surname = surname, dob = Union{Missing,String}["1960-03-21", missing])
    parsers = Dict{Symbol,Function}(:dob => (v -> v === missing ? missing : Date(v)),
                                    :dob_column => (v -> error("a parser for an absent column must not run")))

    plain = _TS_QB._parsed_columns(raw, parsers)
    @test plain isa NamedTuple{(:surname, :dob)}
    @test plain.surname === surname                       # passed through, not copied
    @test isequal(plain.dob, [Date(1960, 3, 21), missing])

    copied = _TS_QB._parsed_columns(Tables.CopiedColumns(raw), parsers)
    @test copied isa Tables.CopiedColumns
    @test Tables.getcolumn(copied, :surname) === surname
    @test isequal(Tables.getcolumn(copied, :dob), [Date(1960, 3, 21), missing])

    # And on the real path: SQLite's result is rows, so Tables.jl builds its columns and marks them
    # copied; the query keeps the mark with a parser (`dob`) and without one (`surname` alone).
    @test Tables.columns(_ts_query()) isa Tables.CopiedColumns
    @test Tables.columns(TSM.Driver.objects.values("surname").order_by("driverid")) isa Tables.CopiedColumns
  end
end
