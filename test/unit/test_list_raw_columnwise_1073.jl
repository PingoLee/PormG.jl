"""
The row terminals read a driver result column-wise and give the rows they gave before (#1073).

`list()`, `list(:dict)` and `list(:json)` build their rows in `_rows_from_result`. It used to walk the
result with `Tables.rowtable` and build a `Dict` per row, then apply the #564 read parsers per cell;
on LibPQ that row walk was 39% of a `list()` call. It now reads a column-access result (LibPQ,
Postgres.jl, MySQL) with `Tables.columntable`, the way `DataFrame(query)` does, and applies each
parser once per column. A result that is already rows (SQLite's `Vector` of `NamedTuple`s, whose
element type is abstract) keeps the row walk, which is faster on that shape.

The change is only worth having if nothing a caller sees moves, so every case here runs the same
result through the row-wise code this replaced (kept below as `_rowwise_reference`) and asserts the
rows are equal value for value, type for type, and key order for key order (the order `list(:json)`
writes). No database: the inputs are stand-ins for each driver's result shape.

julia --project=test/integration test/unit/test_list_raw_columnwise_1073.jl
"""

using Test
using PormG
using Dates
const Tables = PormG.QueryBuilder.Tables

const _CW_QB = PormG.QueryBuilder

struct CwMockPostgres <: PormG.PormGPostgres end
struct CwMockSQLite <: PormG.PormGSQLite end
PormG.backend_sqlite_version(::CwMockSQLite) = 3045000

# The code `_rows_from_result` replaced, verbatim apart from taking the parsers as an argument.
function _rowwise_reference(result, parsers)
  rows = [Dict{Symbol,Any}(Symbol(k) => v for (k, v) in pairs(row)) for row in Tables.rowtable(result)]
  parsers === nothing && return rows
  for row in rows, (name, parser) in parsers
    haskey(row, name) && (row[name] = parser(row[name]))
  end
  return rows
end

# A column-access result whose columns are produced on demand, as a `LibPQ.Result`'s are — the shape
# whose row walk #1073 measured. `Tables.columntable` reads it through `getcolumn`, never by row.
struct CwLazyColumns
  names::Vector{Symbol}
  columns::Vector{AbstractVector}
end
Tables.istable(::Type{CwLazyColumns}) = true
Tables.columnaccess(::Type{CwLazyColumns}) = true
Tables.columns(r::CwLazyColumns) = r
Tables.columnnames(r::CwLazyColumns) = r.names
Tables.getcolumn(r::CwLazyColumns, i::Int) = r.columns[i]
Tables.getcolumn(r::CwLazyColumns, name::Symbol) = r.columns[findfirst(==(name), r.names)]
Tables.schema(r::CwLazyColumns) = Tables.Schema(r.names, Tuple(eltype(c) for c in r.columns))

function _assert_same_rows(got, expected)
  @test got isa Vector{Dict{Symbol,Any}}
  @test length(got) == length(expected)
  for (g, e) in zip(got, expected)
    @test collect(keys(g)) == collect(keys(e))       # iteration order, which list(:json) writes
    for k in keys(e)
      @test isequal(g[k], e[k])                      # `isequal`: `missing` compares equal to itself
      @test typeof(g[k]) === typeof(e[k])
    end
  end
end

const _CW_PG_INTERVAL = PormG.value_parser(PormG.CInterval(), CwMockPostgres())
const _CW_SL_TIMESTAMP = PormG.value_parser(PormG.CDateTime(true), CwMockSQLite())
const _CW_SL_INTERVAL = PormG.value_parser(PormG.CInterval(), CwMockSQLite())

# ─────────────────────────────────────────────────────────────────────────────
# Row read: the SQLite shape, a `Vector{NamedTuple}` with a `missing` and two parsed columns
# The SQLite extension hands core an already-materialized rowtable, and because a `missing` changes a
# row's `NamedTuple` type its element type is abstract, as SQLite.jl's is. A timestamp and an interval column
# are SQLite text the #564 parsers turn into a timestamp / `CompoundPeriod`; the `missing` in each
# must pass through unparsed, and a plain column must come back as the driver gave it.
# ─────────────────────────────────────────────────────────────────────────────
@testset "SQLite rowtable: parsed and missing cells match the row-wise read" begin
  result = [
    (driverid = 1,  surname = "Senna",  created = "2021-03-28 15:00:00", lap = "00:01:23.456"),
    (driverid = 2,  surname = missing,  created = missing,               lap = missing),
    (driverid = 3,  surname = "Prost",  created = "2021-04-18 13:00:00", lap = "00:01:25.000"),
  ]
  parsers = Dict{Symbol,Function}(:created => _CW_SL_TIMESTAMP, :lap => _CW_SL_INTERVAL)
  got = _CW_QB._rows_from_result(result, parsers)
  _assert_same_rows(got, _rowwise_reference(result, parsers))
  @test !(got[1][:created] isa AbstractString)          # the parser fired
  @test got[1][:lap] isa Dates.CompoundPeriod
  @test got[2][:created] === missing
end

# ─────────────────────────────────────────────────────────────────────────────
# Row read: the LibPQ shape, columns read through `getcolumn`, an INTERVAL parser that fires
# On PostgreSQL the INTERVAL parser is the one most queries meet (#581): a bare `Period` becomes a
# `CompoundPeriod`. The result is read without ever walking it by row, which is the cost #1073 removes;
# the rows must still equal the row-wise read of the same result.
# ─────────────────────────────────────────────────────────────────────────────
@testset "LibPQ-shaped column access: INTERVAL parser applied per column" begin
  result = CwLazyColumns([:points, :year, :gap],
                         AbstractVector[Union{Missing,Float64}[25.0, missing, 18.0],
                                        Int32[1988, 1988, 1989],
                                        Union{Missing,Dates.Period}[Minute(5), missing, Second(3)]])
  parsers = Dict{Symbol,Function}(:gap => _CW_PG_INTERVAL)
  got = _CW_QB._rows_from_result(result, parsers)
  _assert_same_rows(got, _rowwise_reference(result, parsers))
  @test got[1][:gap] == Dates.CompoundPeriod(Minute(5))
  @test got[1][:year] isa Int32
end

# ─────────────────────────────────────────────────────────────────────────────
# Row read: the MySQL shape (a `NamedTuple` of vectors) with no parser at all
# MySQL's result is column-access already, and `parsers === nothing` is the common PostgreSQL case
# (no INTERVAL, ARRAY or computed float projected). The rows are the driver's values, unchanged.
# ─────────────────────────────────────────────────────────────────────────────
@testset "Column table with no parsers: values pass through unchanged" begin
  result = (raceid = [18, 19], name = ["Australian Grand Prix", "Malaysian Grand Prix"])
  got = _CW_QB._rows_from_result(result, nothing)
  _assert_same_rows(got, _rowwise_reference(result, nothing))
  @test got[2][:name] == "Malaysian Grand Prix"
end

# ─────────────────────────────────────────────────────────────────────────────
# Row read: a parser keyed by a name the result does not carry is skipped, not added
# The wildcard recorder registers both a field's name and its `db_column`, and only one of them is a
# result column. The absent name must not appear as a key, or `list(:dict)` would grow a column.
# ─────────────────────────────────────────────────────────────────────────────
@testset "Wildcard double registration: the absent name never becomes a key" begin
  parsers = Dict{Symbol,Function}(:date => _CW_SL_TIMESTAMP, :race_date => _CW_SL_TIMESTAMP)
  for result in ([(race_date = "2021-03-28 15:00:00", raceid = 1052)],          # read as rows
                 (race_date = ["2021-03-28 15:00:00"], raceid = [1052]))         # read as columns
    got = _CW_QB._rows_from_result(result, parsers)
    _assert_same_rows(got, _rowwise_reference(result, parsers))
    @test !haskey(got[1], :date)
    @test !(got[1][:race_date] isa AbstractString)      # the present name is parsed
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# Row read: an empty result is an empty `Vector{Dict{Symbol,Any}}`
# A filter that matches nothing must give `[]` of the same element type as a non-empty read, so a
# caller's `isempty` and its typed loop behave the same either way.
# ─────────────────────────────────────────────────────────────────────────────
@testset "Empty result: zero rows of the same element type" begin
  result = CwLazyColumns([:points], AbstractVector[Float64[]])
  got = _CW_QB._rows_from_result(result, Dict{Symbol,Function}(:points => _CW_PG_INTERVAL))
  @test got isa Vector{Dict{Symbol,Any}}
  @test isempty(got)
end

# ─────────────────────────────────────────────────────────────────────────────
# Row read: a wide projection keeps the row-wise key order, read as rows and read as columns
# A `Dict`'s iteration order depends on its slot layout, so the column read holds it only if each row is
# sized and filled exactly as the row walk did (a `sizehint!` to the column count, keys in column order).
# Twenty columns make enough slots for a layout difference to show; it did, without the `sizehint!`.
# ─────────────────────────────────────────────────────────────────────────────
@testset "Wide projection: key iteration order matches the row-wise read" begin
  names = Tuple(Symbol("col_", i) for i in 1:20)
  as_rows = [NamedTuple{names}(Tuple(i * j for i in 1:20)) for j in 1:3]
  as_columns = Tables.columntable(as_rows)
  for result in (as_rows, as_columns)
    _assert_same_rows(_CW_QB._rows_from_result(result, nothing), _rowwise_reference(result, nothing))
  end
end
