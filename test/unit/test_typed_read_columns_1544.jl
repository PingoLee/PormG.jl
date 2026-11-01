# =============================================================================
# The typed read decodes the driver's columns straight into T (#1544, step 2 of #1352)
#
# Step 1 built `Vector{T}` from the `Dict{Symbol,Any}` rows `_list_raw` reads; on PostgreSQL those
# Dicts were ~86% of a `list(T)` call and ~2.3M allocations for 100k five-column rows. Step 2 reads
# `Tables.columntable(result)` and builds each `T` from typed columns, row by row, with the same cell
# rules (`_typed_value`). The step-1 path is the ORACLE here: for the same result, step 2 must return
# the same rows and raise the same refusal.
#
# Hermetic: the column tables are built by hand in the shapes the drivers deliver — a PostgreSQL
# result (LibPQ, Postgres.jl, MySQL are column sources; an `IntegerField` arrives as `Int32`, a
# nullable as `Union{Missing,…}`) and SQLite's materialized `Vector{NamedTuple}`. SQLite never
# reaches the column path, so a hand-built table is the only hermetic way in. No database.
# =============================================================================
# julia --project=test/integration test/unit/test_typed_read_columns_1544.jl

using Test
using PormG
import PormG: InvalidValueError

const _QB1544 = PormG.QueryBuilder
const _SITE1544 = _QB1544._TypedReadSite("a typed read into Tc1544Row", "Lap_times")

struct Tc1544Row              # mixed field types, as #1352's allocation test
    raceid::Int64
    points::Float64
    surname::String
    position::Union{Nothing,Int64}
    milliseconds::Int64
end
struct Tc1544MissingRow
    raceid::Int64
    position::Union{Missing,Int32}
end
struct Tc1544StrictRow        # `position` admits no NULL
    raceid::Int64
    position::Int64
end
struct Tc1544NarrowRow        # `milliseconds` does not fit an Int8
    raceid::Int64
    milliseconds::Int8
end
struct Tc1544TwoDefects       # row 3's raceid overflows Int8; row 2's position is NULL
    raceid::Int8
    position::Int64
end
const _Tc1544NT = NamedTuple{(:surname, :raceid), Tuple{String, Int64}}

# A PostgreSQL-shaped result: typed columns, `Int32` integers, a nullable column.
_pg_cols1544(n) = (
    raceid       = Int64[k for k in 1:n],
    points       = Float64[1.5 * k for k in 1:n],
    surname      = String["Senna" for _ in 1:n],
    position     = Union{Missing,Int32}[isodd(k) ? Int32(k) : missing for k in 1:n],
    milliseconds = Int32[90_000 + k for k in 1:n])

# SQLite's shape: materialized rows, each its own NamedTuple type (a NULL makes a different one).
_sl_rows1544(n) = NamedTuple[(raceid = k, points = 1.5 * k, surname = "Senna",
                              position = isodd(k) ? k : missing, milliseconds = 90_000 + k) for k in 1:n]

# The step-1 path over the same result: the oracle.
_dict_path1544(T, result, parsers) = _QB1544._typed_rows(T, _QB1544._rows_from_result(result, parsers), _SITE1544)
_step2_1544(T, result, parsers) = _QB1544._typed_rows(T, result, parsers, _SITE1544)
_caught1544(f) = try; f(); nothing; catch e; e; end
_refusal1544(e) = e isa InvalidValueError ? (e.kind, e.field, e.row, e.field_type, e.msg) : e

# ─────────────────────────────────────────────────────────────────────────────
# Step 2 reads the same rows as step 1 (#1544)
# Expected: for a PostgreSQL-shaped column table and for SQLite's NamedTuple rows, the rows step 2
# builds equal the rows step 1 builds from `_rows_from_result`'s Dicts — a struct, a NamedTuple `T`
# reading a subset of the columns in another order, `nothing` and `missing` for NULL, `Int32` widened.
# Matters: step 2 changes how a row is read, never what it reads; step 1 is the oracle.
# ─────────────────────────────────────────────────────────────────────────────
@testset "step 2 reads the same rows as the step-1 Dict path (#1544)" begin
    for result in (_pg_cols1544(7), _sl_rows1544(7))
        for T in (Tc1544Row, Tc1544MissingRow, _Tc1544NT)
            @test _step2_1544(T, result, nothing) == _dict_path1544(T, result, nothing)
        end
    end
    rows = _step2_1544(Tc1544Row, _pg_cols1544(2), nothing)
    @test rows[1] == Tc1544Row(1, 1.5, "Senna", 1, 90_001)
    @test rows[2].position === nothing
    @test _step2_1544(Tc1544MissingRow, _pg_cols1544(2), nothing)[2].position === missing
end

# ─────────────────────────────────────────────────────────────────────────────
# A read-side parser is applied to its column (#564, #1544)
# Expected: with a parser registered for `points` (the #564 table's shape, a `Dict{Symbol,Function}`),
# every row reads the parsed value, as step 1 does; a parser for a name no field reads never fires.
# Matters: SQLite's DateTime/Decimal reads and PostgreSQL's INTERVAL/ARRAY reads go through a parser.
# ─────────────────────────────────────────────────────────────────────────────
@testset "a projection parser is applied to its column (#1544)" begin
    parsers = Dict{Symbol,Function}(:points => (v -> v === missing ? missing : 2 * v),
                                    :drv_code => (v -> error("never called")))
    for result in (_pg_cols1544(5), _sl_rows1544(5))
        got = _step2_1544(Tc1544Row, result, parsers)
        @test got == _dict_path1544(Tc1544Row, result, parsers)
        @test [r.points for r in got] == [3.0 * k for k in 1:5]
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# Refusals are step 1's, cell for cell (#1352, #1544)
# Expected: a NULL into a non-null field (:type, row 2, `position`), an `Int32` that does not fit an
# `Int8` (:range, row 1), and — with a defect in row 3 of the first column and another in row 2 of the
# second — the row-2 refusal, because rows are read in order and fields in declaration order. Each is
# the same exception, message included, as the step-1 path raises.
# Matters: the refusal tests of #1352 are the oracle, and a column-by-column read would report row 3.
# ─────────────────────────────────────────────────────────────────────────────
@testset "a refusal is the step-1 refusal, in row order (#1544)" begin
    two = (raceid = Int64[1, 2, 300], position = Union{Missing,Int32}[1, missing, 3])
    two_rows = NamedTuple[(raceid = 1, position = 1), (raceid = 2, position = missing), (raceid = 300, position = 3)]
    cases = ((Tc1544StrictRow, _pg_cols1544(3), :type, "position", 2),
             (Tc1544NarrowRow, _pg_cols1544(3), :range, "milliseconds", 1),
             (Tc1544TwoDefects, two, :type, "position", 2),
             (Tc1544StrictRow, _sl_rows1544(3), :type, "position", 2),
             (Tc1544TwoDefects, two_rows, :type, "position", 2))
    for (T, result, kind, field, row) in cases
        e = _caught1544(() -> _step2_1544(T, result, nothing))
        @test e isa InvalidValueError && e.kind === kind && e.field == field && e.row == row
        @test _refusal1544(e) == _refusal1544(_caught1544(() -> _dict_path1544(T, result, nothing)))
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# An empty result is an empty Vector{T} (#1544)
# Expected: `T[]` for typed columns of length zero and for a result with no columns at all (an empty
# materialized result names none). Matters: the column path reads the columns by name, and an empty
# result may not carry them.
# ─────────────────────────────────────────────────────────────────────────────
@testset "an empty result reads as an empty Vector{T} (#1544)" begin
    @test _step2_1544(Tc1544Row, _pg_cols1544(0), nothing) == Tc1544Row[]
    @test _step2_1544(Tc1544Row, NamedTuple(), nothing) isa Vector{Tc1544Row}
    @test isempty(_step2_1544(Tc1544Row, NamedTuple[], nothing))
end

# ─────────────────────────────────────────────────────────────────────────────
# The column path allocates O(columns), not O(rows × columns) (#1544)
# Expected: `_typed_rows` over a PostgreSQL-shaped table allocates the same COUNT at 1 000 and 10 000
# rows, with and without a parser, and at most a handful (the output vector, the parser tuple).
# Matters: this is the issue's acceptance criterion; step 1 allocated ~23 per row on this shape
# (`test/performance/read_path_list.jl`), and an `Int32` or nullable cell boxed is how it regresses.
# ─────────────────────────────────────────────────────────────────────────────
# Measured inside a function: at testset scope the timing itself allocates through globals.
function _alloc_count1544(cols, parsers)
    _step2_1544(Tc1544Row, cols, parsers)        # compile
    return Base.gc_alloc_count(@timed(_step2_1544(Tc1544Row, cols, parsers)).gcstats)
end

@testset "the column path allocates O(columns) (#1544)" begin
    cols = _pg_cols1544(1_000)
    small, large = _alloc_count1544(cols, nothing), _alloc_count1544(_pg_cols1544(10_000), nothing)
    @test small == large
    @test large <= 5
    parsers = Dict{Symbol,Function}(:points => (v -> v === missing ? missing : 2 * v))
    @test _alloc_count1544(cols, parsers) == _alloc_count1544(_pg_cols1544(10_000), parsers)
end

isdefined(Main, :SQLite) || include(joinpath(@__DIR__, "..", "load_drivers.jl"))
import PormG: Configuration, Dialect, Models
import PormG.ConnectionPool: fetch, SQLiteConnectionPool

const _TC_KEY = normpath(joinpath(@__DIR__, "pormg1544_typed"))
const _TC_POOL = SQLiteConnectionPool(":memory:"; pool_size = 1)
PormG.config[_TC_KEY] = Configuration.Settings(connections = _TC_POOL, change_data = true, db_def_folder = _TC_KEY)

PormG.@models_module Typed1544 "pormg1544_typed" begin
    Lap = Models.Model("tc1544_lap",
        id           = Models.IDField(),
        raceid       = Models.IntegerField(),
        driverid     = Models.IntegerField(),
        lap          = Models.IntegerField(),
        position     = Models.IntegerField(null = true),
        milliseconds = Models.IntegerField(null = true))
end
import .Typed1544 as TC
fetch(_TC_POOL, Dialect.create_table(_TC_POOL, TC.Lap))
PormG.bulk_insert(TC.Lap.objects, (
    id = collect(1:1_000), raceid = fill(1, 1_000), driverid = fill(1, 1_000), lap = collect(1:1_000),
    position = Union{Missing,Int}[isodd(k) ? k : missing for k in 1:1_000],
    milliseconds = collect(90_001:91_000)))

struct Tc1544LapRow
    raceid::Int64
    driverid::Int64
    lap::Int64
    position::Union{Nothing,Int64}
    milliseconds::Union{Nothing,Int64}
end
_tc_q() = TC.Lap.objects.values("raceid", "driverid", "lap", "position", "milliseconds").order_by("lap")

function _terminal_allocs1544(f)
    f()                                          # compile
    return Base.gc_alloc_count(@timed(f()).gcstats)
end

# ─────────────────────────────────────────────────────────────────────────────
# list(T) reads through step 2, end to end (#1544)
# Expected: on an in-memory SQLite database, `list(T)` over 1 000 `Lap_times`-shaped rows returns the
# rows `list(:dict)` holds, and allocates FEWER times than `list(:dict)` — both run the same query, and
# only `list(:dict)` builds a Dict per row. Step 1 built `list(T)` on top of those Dicts, so it
# allocated more (`read_path_list.jl`: 18 235 against 18 094 at 1 000 rows).
# Matters: the tests above call the decode directly; this one fails if the terminal stops using it.
# ─────────────────────────────────────────────────────────────────────────────
@testset "list(T) reads through the step-2 decode (#1544)" begin
    typed = _tc_q().list(Tc1544LapRow)
    dicts = _tc_q().list(:dict)
    @test length(typed) == 1_000
    @test all(t.lap == d[:lap] && t.milliseconds == d[:milliseconds] &&
              (d[:position] === missing ? t.position === nothing : t.position == d[:position])
              for (t, d) in zip(typed, dicts))
    @test _terminal_allocs1544(() -> _tc_q().list(Tc1544LapRow)) < _terminal_allocs1544(() -> _tc_q().list(:dict))
end
