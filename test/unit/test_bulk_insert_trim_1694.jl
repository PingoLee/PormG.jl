# ============================================================
# test/unit/test_bulk_insert_trim_1694.jl
#
# CONTRACT being tested:
#   The typed forms `bulk_insert` reads its frame through (#1599 layer 7, #1694) return what the forms they
#   replaced returned, value for value and type for type, and refuse what they refused with the same error:
#     - `_bulk_cell(column, i)` is `column[i]`;
#     - `_fill_bulk_column(value, n)` is `fill(value, n)`;
#     - `_store_bulk_column!(columns, name, column)` stores `column` itself;
#     - `_bulk_count_total(results)` is `sum(results; init = 0)`;
#     - `_bulk_frame(src, op)` builds the frame the old body built (its row count read each column back out of
#       the frame);
#     - `_validate_bulk_cell` (through `_validate_field_value_at`) raises what the direct
#       `_validate_field_value` call raised, or returns what it returned.
#   Each was written so a `juliac --trim` image can run it; the old form is the oracle. What `bulk_insert` sends
#   (its SQL, parameters, counts and refusals) is pinned by the bulk suite (test_bulk_*.jl), unchanged.
#
# Hermetic: no database.
#
# Run: julia --project=test/integration test/unit/test_bulk_insert_trim_1694.jl
# ============================================================

using Test
isdefined(Main, :SQLite) || include(joinpath(@__DIR__, "..", "load_drivers.jl"))
using PormG
using Dates
using DataFrames

const _BIT_QB = PormG.QueryBuilder
const _BIT_M = PormG.Models
const _BIT_Tables = _BIT_QB.Tables   # through PormG: Tables is not a direct test dependency

_bit_same(a, b) = typeof(a) === typeof(b) && isequal(a, b)

# The columns a table hands over: each arm of the walks, and columns that take the open arm (a narrower integer,
# a range, a view, a union the walk does not name).
_bit_columns() = Any[
  Int64[1, 2], ["Monaco", "Monza"], [1.5, 2.25], [true, false], [Date(2010, 5, 16), Date(2011, 5, 29)],
  [DateTime(2010, 5, 16, 14), DateTime(2011, 5, 29, 14)], [Time(14), Time(15, 30)],
  [_BIT_M.ZonedDateTime(2010, 5, 16, 14, _BIT_M.TimeZone("UTC"))], [_BIT_M.Decimals.Decimal(0, 150, -2)],
  [_BIT_M.UUIDs.UUID("550e8400-e29b-41d4-a716-446655440000")], Int32[6, 7], [nothing, nothing],
  Any[1, "a", nothing, missing], Union{Missing, Int64}[1, missing], Union{Missing, String}["a", missing],
  Union{Missing, Float64}[missing, 2.5], Union{Missing, Bool}[true, missing],
  Union{Missing, Date}[Date(2010, 5, 16), missing], Union{Missing, DateTime}[missing, DateTime(2010, 1, 1)],
  Union{Nothing, Int64}[1, nothing], Union{Nothing, String}[nothing, "a"],
  Int16[1, 2], 1:3, view([10, 20, 30], 2:3), Union{Missing, Int32}[Int32(1), missing], Symbol[:a, :b],
]

# What: each typed walk against the call it replaces, over every arm and over columns and values that take the
#   open arm.
# Expected: the same value at the same type (`isequal`, so `missing` compares), and for the store the column
#   itself (`===`).
# Why: the walks exist so a trimmed image can run them; under the JIT they must be invisible. A walk arm that
#   converted (a `Vector{Int32}` cell read as `Int64`, a fill that widened) would change what is bound.
@testset "the bulk walks return what the calls they replace returned (#1599 layer 7, #1694)" begin
  for col in _bit_columns(), i in eachindex(col)
    @test (typeof(col), i, _bit_same(_BIT_QB._bulk_cell(col, i), col[i])) == (typeof(col), i, true)
  end
  for v in Any["Monaco", Date(2010, 5, 16), 2010, 1.5, true, nothing, missing, Int16(3), :sym,
               _BIT_M.ZonedDateTime(2010, 5, 16, 14, _BIT_M.TimeZone("UTC")), _BIT_M.Decimals.Decimal(0, 150, -2)],
      n in (0, 1, 3)
    @test (repr(v), n, _bit_same(_BIT_QB._fill_bulk_column(v, n), fill(v, n))) == (repr(v), n, true)
  end
  for col in _bit_columns()
    store = Dict{String, AbstractVector}()
    _BIT_QB._store_bulk_column!(store, "c", col)
    @test store["c"] === col
  end
  for r in (Any[], Any[2], Any[2, 3], Any[Int32(2), 3], Any[big(2), 3], Any[Int8(1)], Any[0, 0, 5])
    @test (r, _bit_same(_BIT_QB._bulk_count_total(r), sum(r; init = 0))) == (r, true)
  end
end

# The frame as the old `_bulk_frame` built it: the row count read each column back out of the store.
function _bit_old_frame(src, op::AbstractString)
  _BIT_QB._refuse_non_table(src, op)
  _BIT_Tables.schema(src) === nothing && _BIT_Tables.rowaccess(src) && return _BIT_QB._schemaless_row_frame(src, op)
  cols = _BIT_Tables.columns(src)
  names = String[]
  columns = Dict{String, AbstractVector}()
  for name in _BIT_Tables.columnnames(cols)
    column = _BIT_Tables.getcolumn(cols, name)
    push!(names, String(name))
    columns[String(name)] = column isa AbstractVector ? column : collect(column)
  end
  if isempty(names)
    src isa AbstractVector && !isempty(src) &&
      throw(_BIT_QB.QueryBuildError("Error in $(op), the table has rows but no columns"))
    return _BIT_QB._BulkFrame(names, columns, 0)
  end
  row_count = length(columns[names[1]])
  all(name -> length(columns[name]) == row_count, names) ||
    throw(_BIT_QB.QueryBuildError("Error in $(op), the table's columns have different lengths"))
  return _BIT_QB._BulkFrame(names, columns, row_count)
end

_bit_frame_outcome(f) = try
  fr = f()
  (:ok, fr.names, Dict(k => (typeof(v), collect(v)) for (k, v) in fr.columns), fr.row_count)
catch e
  (:err, typeof(e), sprint(showerror, e))
end

# A column table whose names repeat, with columns of different lengths: legal for Tables.jl's interface, and the
# case that tells "the lengths of the columns the store kept" (the old read-back) from "every column seen".
struct _BITDupCols
  served::Base.RefValue{Int}
end
_BIT_Tables.istable(::Type{_BITDupCols}) = true
_BIT_Tables.columnaccess(::Type{_BITDupCols}) = true
_BIT_Tables.columns(x::_BITDupCols) = x
_BIT_Tables.schema(::_BITDupCols) = _BIT_Tables.Schema((:year, :year), (Int, Int))
_BIT_Tables.columnnames(::_BITDupCols) = (:year, :year)
const _BIT_DUP = ([2010, 2011], [2010, 2011, 2012])
_BIT_Tables.getcolumn(x::_BITDupCols, ::Symbol) = (x.served[] = x.served[] % 2 + 1; _BIT_DUP[x.served[]])

# What: `_bulk_frame` against the old body, over a row table, a row table with six column types, a column table,
#   a DataFrame, an empty table, a schemaless row table, columns of different lengths, a column table whose names
#   repeat, and a value that is no table.
# Expected: the same names, the same columns (type and values; a row table is copied into fresh columns by
#   `Tables.columns` on every call, old and new alike), the same row count; or the same error type and message.
#   A column table's vectors are the caller's own, uncopied (#132).
# Why: the new body measures each length as it stores the column, so a trimmed image never reads a length back
#   out of the `AbstractVector` store; the frame it builds must be the old one.
@testset "the bulk frame is the frame the old body built (#1599 layer 7, #1694)" begin
  rows = [(year = 2010, round = 6, name = "Monaco Grand Prix"), (year = 2011, round = 6, name = "Monaco Grand Prix")]
  coltab = (year = [2010, 2011], name = ["Monaco Grand Prix", "Monaco Grand Prix"])
  wide = [(year = 2010, name = "Monaco Grand Prix", date = Date(2010, 5, 16), points = 25.0, sprint = false, round = Int32(6))]
  srcs = Any[rows, wide, coltab, DataFrame(year = [2010, 2011], name = ["Monaco Grand Prix", "Monaco Grand Prix"]),
             NamedTuple{(:year,), Tuple{Int}}[], Any[(year = 2010,), (year = 2011,)],
             (year = [2010, 2011], name = ["Monaco Grand Prix"]), 2010, NamedTuple()]
  for src in srcs
    @test (repr(src), _bit_frame_outcome(() -> _BIT_QB._bulk_frame(src, "bulk_insert"))) ==
          (repr(src), _bit_frame_outcome(() -> _bit_old_frame(src, "bulk_insert")))
  end
  # The repeated names: each body gets a fresh source, served the same way (the first `getcolumn` call returns the
  # 2-row column, the second the 3-row one).
  @test _bit_frame_outcome(() -> _BIT_QB._bulk_frame(_BITDupCols(Ref(0)), "bulk_insert")) ==
        _bit_frame_outcome(() -> _bit_old_frame(_BITDupCols(Ref(0)), "bulk_insert"))
  fr = _BIT_QB._bulk_frame(coltab, "bulk_insert")
  @test fr.columns["year"] === coltab.year && fr.columns["name"] === coltab.name
end

_bit_validate_outcome(f) = try
  (:ok, f())
catch e
  (:err, typeof(e), sprint(showerror, e))
end

# What: `_validate_bulk_cell` against the direct `_validate_field_value` call it made, wrapped the way it wrapped
#   it, over F1 fields of each kind and values that pass, fail and are NULL.
# Expected: the same return value, or the same error type and message.
# Why: it now validates through `_validate_field_value_at`, `create`'s typed walk, so a trimmed image has a
#   compiled call for an untyped cell; the checks and their messages must be the ones a bulk caller saw.
@testset "a bulk cell is validated as it was (#1599 layer 7, #1694)" begin
  model = _BIT_M.Model("bit_race",
    raceid = _BIT_M.IDField(), year = _BIT_M.IntegerField(), name = _BIT_M.CharField(max_length = 20),
    date = _BIT_M.DateField(), round = _BIT_M.IntegerField(null = true),
    created_at = _BIT_M.DateTimeField(), token = _BIT_M.UUIDField(), points = _BIT_M.DecimalField(max_digits = 4, decimal_places = 1))
  old(field, value) = begin
    f_meta = model.fields[field]
    try
      _BIT_QB._validate_field_value(model, field, f_meta, value, "bulk_insert")
    catch e
      e isa PormG.InvalidValueError && throw(_BIT_QB._bulk_cell_error(e, "bulk_insert", model, field, 3))
      rethrow()
    end
  end
  values = Any[2010, Int32(6), "2010", "Monaco Grand Prix", "a name longer than twenty", true, 1.5, nothing, missing,
               Date(2010, 5, 16), "2010-05-16", "2010-02-30", DateTime(2010, 5, 16, 14),
               _BIT_M.ZonedDateTime(2010, 5, 16, 14, _BIT_M.TimeZone("UTC")), "2010-05-16T14:00:00.000+00:00",
               _BIT_M.UUIDs.UUID("550e8400-e29b-41d4-a716-446655440000"), "not-a-uuid",
               _BIT_M.Decimals.Decimal(0, 150, -1), _BIT_M.Decimals.Decimal(0, 123456, -1), [1, 2], :sym]
  for field in ("year", "name", "date", "round", "created_at", "token", "points"), v in values
    f_meta = model.fields[field]
    @test (field, repr(v), _bit_validate_outcome(() -> _BIT_QB._validate_bulk_cell(model, field, f_meta, v, "bulk_insert", 3))) ==
          (field, repr(v), _bit_validate_outcome(() -> old(field, v)))
  end
end
