# =============================================================================
# The typed read end to end: the row decoder runs where the driver's result is concrete (#1605)
#
# Before #1605 a typed read came back from `fetch` as the driver's result, typed `Any`, and was decoded
# by a call on that `Any`, with each column's parser kept as a `Function` in a `Dict`. Under the JIT that
# is a function barrier. A trimmed build (`juliac --trim`) has no compiled target for either call (round
# 1 of #1600, row 10), and SQLite's result was a `Tables.rowtable` whose `NamedTuple` types are decided
# by each row's cells at run time.
#
# Now `list(T)` hands a `_RowDecoder{T,P}` to `fetch`. Its parsers are one concrete `ReadParser` per
# field, read from the slot-3 table `read_parser`, which `value_parser` is derived from. SQLite decodes
# on its worker, stepping the statement straight into `T` (`backend_execute_rows`). PostgreSQL and MySQL
# decode the result their handle delivers. The row-by-row Dict path (`_list_raw`, then `_typed_rows`
# over its Dicts) is the oracle: same rows, same values.
#
# Hermetic: an in-memory SQLite database with an inline model module, and a mock PostgreSQL pool for
# the handle-side decode. No live database.
# =============================================================================
# julia --project=test/integration test/unit/test_typed_read_decoder_1605.jl

using Test
using Dates
using TimeZones
using PormG
isdefined(Main, :SQLite) || include(joinpath(@__DIR__, "..", "load_drivers.jl"))
import PormG: Configuration, Dialect, Models, InvalidValueError
import PormG: CanonicalType, CDate, CDateTime, CTime, CInterval, CBool, CDecimal, CFloat64, CArray, CInt32
import PormG.ConnectionPool: fetch, SQLiteConnectionPool

const _DC_QB = PormG.QueryBuilder
const _DC_D = PormG.QueryBuilder.Decimals
const _DC_KEY = normpath(joinpath(@__DIR__, "pormg1605_decoder"))
const _DC_POOL = SQLiteConnectionPool(":memory:"; pool_size = 1)
PormG.config[_DC_KEY] = Configuration.Settings(
    connections = _DC_POOL, change_data = true, db_def_folder = _DC_KEY)

# F1-shaped: a result row with every storage class SQLite has and every SQLite read parser the typed
# read applies — a date, a timestamp, a time, a boolean, a declared decimal — plus NULLs.
PormG.@models_module Decoder1605 "pormg1605_decoder" begin
    Result::Models.ModelType = Models.Model("dc1605_result",
        resultid    = Models.IDField(),
        points      = Models.FloatField(),
        position    = Models.IntegerField(null = true),
        positiontext = Models.CharField(max_length = 4),
        fastestspeed = Models.DecimalField(max_digits = 7, decimal_places = 3, null = true),
        finished    = Models.BooleanField(),
        racedate    = Models.DateField(null = true),
        recorded    = Models.DateTimeField(null = true),
        fastesttime = Models.TimeField(null = true),
        telemetry   = Models.BinaryField(null = true))
end
import .Decoder1605 as DC

fetch(_DC_POOL, Dialect.create_table(_DC_POOL, DC.Result))
DC.Result.objects.create("resultid" => 1, "points" => 25.0, "position" => 1, "positiontext" => "1",
    "fastestspeed" => "218.300", "finished" => true, "racedate" => Date(1991, 3, 10),
    "recorded" => ZonedDateTime(1991, 3, 10, 15, 30, tz"UTC"), "fastesttime" => Time(1, 22, 3),
    "telemetry" => UInt8[0x01, 0x02, 0xff])
DC.Result.objects.create("resultid" => 2, "points" => 0.0, "position" => nothing, "positiontext" => "R",
    "fastestspeed" => nothing, "finished" => false, "racedate" => nothing, "recorded" => nothing,
    "fastesttime" => nothing)
DC.Result.objects.create("resultid" => 3, "points" => 18.5, "position" => 2, "positiontext" => "2",
    "fastestspeed" => "217.995", "finished" => true, "racedate" => Date(1991, 3, 24),
    "recorded" => ZonedDateTime(1991, 3, 24, 14, 0, 30, tz"UTC"), "fastesttime" => Time(1, 20, 59, 250))

struct DcResultRow
    resultid::Int64
    points::Float64
    position::Union{Nothing,Int64}
    positiontext::String
    fastestspeed::Union{Nothing,_DC_D.Decimal}
    finished::Bool
    racedate::Union{Nothing,Date}
    recorded::Union{Nothing,ZonedDateTime}
    fastesttime::Union{Nothing,Time}
    telemetry::Union{Nothing,Vector{UInt8}}
end
struct DcStrictRow            # `position` admits no NULL: row 2 is refused
    resultid::Int64
    position::Int64
end
struct DcCheckedRow           # its own constructor refuses a negative grid slot, with a Julia error
    resultid::Int64
    points::Float64
    DcCheckedRow(resultid::Int64, points::Float64) =
        points > 20 ? throw(ArgumentError("points above 20 are not this row type's")) : new(resultid, points)
end

_dc_q() = DC.Result.objects.order_by("resultid")
_dc_same(a, b) = all(getfield(a, k) == getfield(b, k) || (getfield(a, k) === nothing && getfield(b, k) === nothing)
                     for k in fieldnames(typeof(a)))

# ─────────────────────────────────────────────────────────────────────────────
# Tests: `list(T)` on SQLite, through the stepping decoder, against the step-1 oracle (`_list_raw`'s
# Dict rows, each parsed by `value_parser`, then `_typed_rows`).
# Expected: the same nine fields on all three rows: NULL → `nothing`, the SQLite timestamp → its
# `ZonedDateTime`, the 0/1 → `Bool`, the decimal text → its `Decimal`.
# Matters: the SQLite path no longer builds `Tables.rowtable`; the rows it builds must be the old ones.
# ─────────────────────────────────────────────────────────────────────────────
@testset "SQLite list(T) through the stepping decoder equals the Dict-row oracle (#1605)" begin
    typed = _dc_q().list(DcResultRow)
    oracle_q = _dc_q().values(String.(fieldnames(DcResultRow))...)
    oracle = _DC_QB._typed_rows(DcResultRow, _DC_QB._list_raw(oracle_q),
                                _DC_QB._TypedReadSite("oracle", "dc1605_result"))
    @test typed isa Vector{DcResultRow}
    @test length(typed) == 3
    @test all(_dc_same(a, b) for (a, b) in zip(typed, oracle))
    @test typed[1].recorded == ZonedDateTime(1991, 3, 10, 15, 30, tz"UTC")
    @test typed[1].fastestspeed == parse(_DC_D.Decimal, "218.300")
    @test typed[2].position === nothing && typed[2].racedate === nothing && typed[2].finished === false
    @test typed[3].fastesttime == Time(1, 20, 59, 250)
    @test typed[1].telemetry == UInt8[0x01, 0x02, 0xff]    # a BLOB cell, read as the oracle reads it
    @test typed[2].telemetry === nothing
    # A `values(...)` projection in another order reads by name, not by position.
    reordered = _dc_q().values("fastesttime", "resultid", "racedate", "points", "finished", "recorded",
                               "positiontext", "position", "fastestspeed", "telemetry").list(DcResultRow)
    @test all(_dc_same(a, b) for (a, b) in zip(reordered, typed))
end

# ─────────────────────────────────────────────────────────────────────────────
# Tests: the SQLite typed read is decoded by the extension's `backend_execute_rows`, on the worker.
# Expected: the method `fetch` reaches for (SQLite pool, `SQLite.DB`, …, `_RowDecoder`) is
# PormGSQLiteExt's, and `fetch(…; _decode)` returns the decoder's `Vector{T}`.
# Matters: the equality above would pass through the materialized fallback too; this pins which path
# runs.
# ─────────────────────────────────────────────────────────────────────────────
@testset "SQLite decodes in the extension's backend_execute_rows (#1605)" begin
    D = _DC_QB._RowDecoder{DcStrictRow, NTuple{2, PormG.ReadParser}}
    m = which(PormG.backend_execute_rows, Tuple{SQLiteConnectionPool, SQLite.DB, String, Nothing, D})
    @test nameof(m.module) === :PormGSQLiteExt
    dec = _DC_QB._RowDecoder{Tuple{}}((), _DC_QB._TypedReadSite("x", "y"))   # constructor arity
    @test dec isa _DC_QB._RowDecoder{Tuple{}, Tuple{}}
    # The pass-through `fetch` the terminal makes, by hand: the decoder's rows come back.
    nt = NamedTuple{(:resultid, :points), Tuple{Int64, Float64}}
    decoder = _DC_QB._RowDecoder{nt}((PormG.NO_READ_PARSER, PormG.NO_READ_PARSER),
                                     _DC_QB._TypedReadSite("a typed read into nt", "dc1605_result"))
    rows = fetch(_DC_POOL, "SELECT resultid, points FROM dc1605_result ORDER BY resultid"; _decode = decoder)
    @test rows isa Vector{nt}
    @test rows == [nt((1, 25.0)), nt((2, 0.0)), nt((3, 18.5))]
end

# ─────────────────────────────────────────────────────────────────────────────
# Tests: a refusal raised by the stepping decoder.
# Expected: `InvalidValueError` naming the field, its type and row 2, the same text the Dict-row path
# raises for the same cell. The refusal reaches the caller through the worker.
# Matters: the worker's exception transport must not change the error a caller gets.
# ─────────────────────────────────────────────────────────────────────────────
@testset "a NULL into a non-null field is refused on the stepping path, as on the Dict path (#1605)" begin
    stepped = try _dc_q().list(DcStrictRow); nothing catch e; e end
    oracle = try
        _DC_QB._typed_rows(DcStrictRow, _DC_QB._list_raw(_dc_q().values("resultid", "position")),
                           _DC_QB._TypedReadSite("a typed read into DcStrictRow", "dc1605_result"))
        nothing
    catch e
        e
    end
    @test stepped isa InvalidValueError
    @test oracle isa InvalidValueError
    @test sprint(showerror, stepped) == sprint(showerror, oracle)
    @test occursin("position", sprint(showerror, stepped))
end

# ─────────────────────────────────────────────────────────────────────────────
# Tests: the decoder's parsers, and the slot-3 table they come from.
# Expected: `_typed_read_parsers` infers `NTuple{N,ReadParser}`; `read_parser` infers `ReadParser` on
# each backend; `value_parser` still answers the named `Dialect` functions (identity), derived from it.
# Matters: a parser typed by the run-time kind is the dynamic call #1605 removes. Two tables would
# drift apart (#474), so `value_parser` must stay derived.
# ─────────────────────────────────────────────────────────────────────────────
@testset "the decoder's parsers are concrete; value_parser is derived from read_parser (#1605)" begin
    q = _dc_q()
    rendered = _DC_QB._render_select(_DC_QB._typed_query(q, DcResultRow), connection = _DC_POOL, show_query = :execute)
    parsers = @inferred _DC_QB._typed_read_parsers(DcResultRow, rendered.instruction, _DC_POOL)
    @test parsers isa NTuple{10, PormG.ReadParser}
    @test [PormG.has_parser(p) for p in parsers] == [false, false, false, false, true, true, true, true, true, false]
    for B in (SQLiteConnectionPool, PormG.ConnectionPool.MySQLConnectionPool,
              PormG.ConnectionPool.PostgresConnectionPool{:libpq})
        @test only(Base.return_types(PormG.read_parser, (CanonicalType, B, Symbol))) === PormG.ReadParser
    end
    @test PormG.value_parser(CDate(), _DC_POOL) === Dialect._parse_sqlite_date
    @test PormG.value_parser(CDateTime(true), _DC_POOL) === Dialect._parse_sqlite_timestamp
    @test PormG.value_parser(CBool(), _DC_POOL) === Dialect._parse_sqlite_bool
    @test PormG.value_parser(CInt32(), _DC_POOL) === nothing
    @test PormG.read_parser(CInt32(), _DC_POOL) === PormG.NO_READ_PARSER
    # A declared decimal carries its width and label, as the closure did (#1110).
    p = PormG.read_parser(CDecimal(2, 0), _DC_POOL, :pts)
    @test (p.precision, p.scale, p.label) == (2, 0, "pts")
    @test sprint(showerror, try p(100) catch e; e end) == sprint(showerror, try PormG.value_parser(CDecimal(2, 0), _DC_POOL, :pts)(100) catch e; e end)
end

# ─────────────────────────────────────────────────────────────────────────────
# Tests: `fetch`'s handle-side decode, for the engines whose driver hands back a materialized result.
# Expected: on a PostgreSQL pool `_decoded` applies the decoder to the result (a column table here,
# the shape LibPQ's result reads as); with no decoder the result passes through; on SQLite the
# worker's rows pass through untouched.
# Matters: PostgreSQL and MySQL reach the decoder here, not on a worker.
# ─────────────────────────────────────────────────────────────────────────────
@testset "fetch decodes a materialized result on PostgreSQL and MySQL, not again on SQLite (#1605)" begin
    nt = NamedTuple{(:resultid, :position), Tuple{Int64, Union{Nothing,Int64}}}
    decoder = _DC_QB._RowDecoder{nt}((PormG.NO_READ_PARSER, PormG.NO_READ_PARSER),
                                     _DC_QB._TypedReadSite("a typed read into nt", "dc1605_result"))
    cols = (resultid = Int64[1, 2], position = Union{Missing,Int32}[Int32(1), missing])
    pg = PormG.ConnectionPool.PostgresConnectionPool("host=offline"; pool_size = 1)
    my = PormG.ConnectionPool.MySQLConnectionPool("host=offline"; pool_size = 1)
    for pool in (pg, my)
        @test PormG.ConnectionPool._decoded(pool, cols, decoder) == [nt((1, 1)), nt((2, nothing))]
        @test PormG.ConnectionPool._decoded(pool, cols, nothing) === cols
    end
    done = [nt((1, 1))]
    @test PormG.ConnectionPool._decoded(_DC_POOL, done, decoder) === done
end

# ─────────────────────────────────────────────────────────────────────────────
# Tests: an error that is not a PormG refusal, raised while a row is built (here the row type's own
# constructor), on SQLite (where the decode runs on the worker) and on the handle-side decode.
# Expected: the `ArgumentError` itself reaches the caller, not a `StatementError` wrapping it.
# Matters: before #1605 the decode ran after `fetch` returned, so its errors were never wrapped as the
# statement's; decoding inside `fetch` must not change the error a caller catches.
# ─────────────────────────────────────────────────────────────────────────────
@testset "an error building a row reaches the caller unwrapped (#1605)" begin
    err = try _dc_q().list(DcCheckedRow); nothing catch e; e end
    @test err isa ArgumentError
    @test occursin("points above 20", sprint(showerror, err))
    @test length(_dc_q().filter("points__@lte" => 20).list(DcCheckedRow)) == 2   # the pool is fine after it
    decoder = _DC_QB._RowDecoder{DcCheckedRow}((PormG.NO_READ_PARSER, PormG.NO_READ_PARSER),
                                               _DC_QB._TypedReadSite("a typed read into DcCheckedRow", "dc1605_result"))
    pg = PormG.ConnectionPool.PostgresConnectionPool("host=offline"; pool_size = 1)
    cols = (resultid = Int64[1], points = Float64[25.0])
    @test_throws ArgumentError PormG.ConnectionPool._decoded(pg, cols, decoder)
end
