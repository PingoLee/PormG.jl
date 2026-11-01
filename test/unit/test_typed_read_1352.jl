# =============================================================================
# The typed read: list(T) / first(T) / get(T, …) build rows into a declared type (#1352)
#
# Every other read terminal returns `Any`-valued rows (`PormGRow`, `list(:dict)`), so the code a query
# feeds is dynamic. `list(T)` returns `Vector{T}` for a struct or `NamedTuple` type the caller
# declares. The rules the maintainer chose, each pinned below:
#   * columns ↔ fields: no `values()` projects `fieldnames(T)`; with `values()` the projected names
#     must be exactly `fieldnames(T)` — a missing field AND an extra column are `QueryBuildError`s,
#     raised before any SQL runs;
#   * NULL: the field's declared type decides (`nothing` / `missing` / refused);
#   * conversion: by the types, never by the data — integer widths (range-checked), integer → float or
#     Decimal when exact, float widening; anything else is refused whatever the value.
#
# Hermetic: an in-memory SQLite database with an inline model module. No live database.
# =============================================================================
# julia --project=test/integration test/unit/test_typed_read_1352.jl

using Test
using Dates
using PormG
isdefined(Main, :SQLite) || include(joinpath(@__DIR__, "..", "load_drivers.jl"))
import PormG: Configuration, Dialect, Models, QueryBuildError, InvalidValueError, UnknownFieldError,
              DoesNotExist, MultipleObjectsReturned
import PormG.ConnectionPool: fetch, SQLiteConnectionPool

const _TR_D = PormG.QueryBuilder.Decimals   # through PormG: `Decimals` is not in `[targets].test`
const _TR_KEY = normpath(joinpath(@__DIR__, "pormg1352_typed"))
const _TR_POOL = SQLiteConnectionPool(":memory:"; pool_size = 1)
PormG.config[_TR_KEY] = Configuration.Settings(
    connections = _TR_POOL, change_data = true, db_def_folder = _TR_KEY)

# F1-shaped: a constructor and its drivers. `code` carries a `db_column`, so the key a typed read
# looks for (the field name) differs from the physical column a bare `SELECT *` would return.
PormG.@models_module Typed1352 "pormg1352_typed" begin
    Constructor = Models.Model("tr1352_constructor",
        constructorid = Models.IDField(),
        name          = Models.CharField(max_length = 40))
    Driver = Models.Model("tr1352_driver",
        driverid      = Models.IDField(),
        surname       = Models.CharField(max_length = 40),
        code          = Models.CharField(max_length = 3, null = true, db_column = "drv_code"),
        number        = Models.IntegerField(null = true),
        wins          = Models.BigIntegerField(),
        points        = Models.FloatField(),
        salary        = Models.DecimalField(max_digits = 10, decimal_places = 2, null = true),
        active        = Models.BooleanField(),
        dob           = Models.DateField(null = true),
        constructorid = Models.ForeignKey(Constructor, on_delete = "CASCADE"))
end
import .Typed1352 as TR

fetch(_TR_POOL, Dialect.create_table(_TR_POOL, TR.Constructor))
fetch(_TR_POOL, Dialect.create_table(_TR_POOL, TR.Driver))
TR.Constructor.objects.create("constructorid" => 1, "name" => "McLaren")
TR.Constructor.objects.create("constructorid" => 2, "name" => "Williams")
TR.Driver.objects.create("driverid" => 1, "surname" => "Senna", "code" => "SEN", "number" => 12,
    "wins" => 41, "points" => 614.0, "salary" => "1000.50", "active" => true,
    "dob" => Date(1960, 3, 21), "constructorid" => 1)
TR.Driver.objects.create("driverid" => 2, "surname" => "Prost", "code" => nothing, "number" => nothing,
    "wins" => 51, "points" => 798.5, "salary" => nothing, "active" => false,
    "dob" => nothing, "constructorid" => 1)
TR.Driver.objects.create("driverid" => 3, "surname" => "Mansell", "code" => "MAN", "number" => 5,
    "wins" => 31, "points" => 482.0, "salary" => "250.00", "active" => true,
    "dob" => Date(1953, 8, 8), "constructorid" => 2)

# The row types under test. Declared at top level: a struct cannot be declared inside a testset.
struct TrDriverRow
    driverid::Int64
    surname::String
    code::Union{Nothing,String}
    dob::Union{Nothing,Date}
end
struct TrMissingRow
    driverid::Int64
    code::Union{Missing,String}
end
struct TrStrictRow            # `code` admits no NULL
    driverid::Int64
    code::String
end
struct TrWideRow              # every conversion the table allows
    number::Union{Nothing,Int16}   # integer width: IntegerField, range-checked
    wins::Float64                  # integer -> float, exact
    salary::Union{Nothing,_TR_D.Decimal}
    points::Float64
    active::Bool
end
struct TrTeamRow              # a joined alias and an aggregate
    team::String
    drivers::Int64
end
struct TrFloatToInt; points::Int64; end
struct TrDecToFloat; salary::Union{Nothing,Float64}; end
struct TrFloatNarrow; points::Float32; end
struct TrBoolToInt; active::Int64; end
struct TrIntToBool; wins::Bool; end
struct TrRangeRow; wins::Int8; end
struct TrUnknownField; driverid::Int64; nosuch::String; end
struct TrCustomCtor
    driverid::Int64
    surname::String
    TrCustomCtor(driverid::Int64) = new(driverid, "x")
end
abstract type TrAbstract end
struct TrIntegerField; active::Integer; end            # abstract: would take a Bool past the rules
struct TrRealField; salary::Union{Nothing,Real}; end   # abstract: would take a Decimal or a Float64
struct TrAnyField; surname::Any; end
struct TrIntUnionField; number::Union{Nothing,Int8,Int16}; end
struct TrIntToDecimal; wins::_TR_D.Decimal; end
struct TrNullableMismatch; dob::Union{Nothing,String}; end

const _TrNT = NamedTuple{(:driverid, :surname), Tuple{Int64, String}}
struct TrMixedRow             # mixed field types: the shape an ntuple closure failed to specialize
    raceid::Int64
    points::Float64
    surname::String
    position::Union{Nothing,Int64}
    milliseconds::Int64
end

_tr_q() = TR.Driver.objects.order_by("driverid")

# Run `f` and return what it threw, or `nothing`.
_tr_caught(f) = try; f(); nothing; catch e; e; end

# ─────────────────────────────────────────────────────────────────────────────
# list(T) projects fieldnames(T) and returns Vector{T} (#1352)
# Expected SQL: SELECT of exactly driverid, surname, the `drv_code` column aliased `code`, and dob —
# no other column. Matters: the read reads only what T needs, and a `db_column` field comes back under
# its FIELD name, which is the key `T` is built from (`SELECT *` would key it `drv_code`).
# ─────────────────────────────────────────────────────────────────────────────
@testset "list(T) projects exactly fieldnames(T) and returns Vector{T} (#1352)" begin
    sql = _tr_q().list(TrDriverRow; show_query = :sql)
    @test occursin("\"drv_code\"", sql)
    @test !occursin("\"wins\"", sql) && !occursin("\"points\"", sql) && !occursin("*", sql)

    rows = _tr_q().list(TrDriverRow)
    @test rows isa Vector{TrDriverRow}
    @test [r.surname for r in rows] == ["Senna", "Prost", "Mansell"]
    @test rows[1].code == "SEN" && rows[1].dob == Date(1960, 3, 21)

    # The handler is not written to: no projection leaks back into the caller's query.
    q = _tr_q()
    q.list(TrDriverRow)
    @test isempty(q.object.values)

    # A NamedTuple type is a row type too.
    nts = _tr_q().list(_TrNT)
    @test nts isa Vector{_TrNT} && nts[2] == (driverid = 2, surname = "Prost")

    # The functional form is the same terminal.
    @test PormG.QueryBuilder.list(_tr_q(), TrDriverRow) == rows
end

# ─────────────────────────────────────────────────────────────────────────────
# The typed terminals infer their declared return types (#1352)
# Expected: `list(q, T)` infers `Vector{T}`, `first(q, T)` `Union{Nothing,T}`, `get(q, T, …)` `T`.
# Matters: type stability past the query is the whole point of the feature — an `Any` here would
# hand the caller the same dynamic container `list()` does.
# ─────────────────────────────────────────────────────────────────────────────
@testset "typed terminals are inferred: Vector{T}, Union{Nothing,T}, T (#1352)" begin
    q = _tr_q()
    QB = PormG.QueryBuilder
    @test (@inferred QB.list(q, TrDriverRow)) isa Vector{TrDriverRow}
    @test (@inferred Union{Nothing,TrDriverRow} QB.first(q, TrDriverRow)) isa TrDriverRow
    @test (@inferred QB.get(q, TrDriverRow, "driverid" => 3)) isa TrDriverRow
    @test (@inferred Union{Nothing,TrDriverRow} QB.last(q, TrDriverRow)) isa TrDriverRow
    # The fluent spelling infers too: `getproperty(q, :list)` folds on the constant symbol, and the
    # terminals are `@constprop :aggressive` so the `show_query` inspection arm folds away.
    fluent_list(q) = q.list(TrDriverRow)
    fluent_first(q) = q.first(TrDriverRow)
    fluent_get(q) = q.get(TrDriverRow, "driverid" => 3)
    @test (@inferred fluent_list(q)) isa Vector{TrDriverRow}
    @test (@inferred Union{Nothing,TrDriverRow} fluent_first(q)) isa TrDriverRow
    @test (@inferred fluent_get(q)) isa TrDriverRow
end

# ─────────────────────────────────────────────────────────────────────────────
# values(...) with aliases, a joined column and an aggregate (#1352)
# Expected SQL: SELECT the joined constructor name AS team and COUNT(driverid) AS drivers, grouped.
# Matters: computed and joined columns reach T through the aliases values() already takes.
# ─────────────────────────────────────────────────────────────────────────────
@testset "values(...) aliases, joins and aggregates read into T (#1352)" begin
    rows = TR.Driver.objects.
        values("team" => "constructorid__name", "drivers" => PormG.QueryBuilder.Count("driverid")).
        order_by("team").list(TrTeamRow)
    @test rows == [TrTeamRow("McLaren", 2), TrTeamRow("Williams", 1)]
end

# ─────────────────────────────────────────────────────────────────────────────
# A field with no column, a column with no field, values("*"): refused before SQL (#1352)
# Expected: QueryBuildError naming the fields / columns, raised even under `show_query = :sql` —
# i.e. at build, before anything executes. Matters: a misspelled alias must not pass silently in
# either direction (the maintainer's "refuse" decision).
# ─────────────────────────────────────────────────────────────────────────────
@testset "projection mismatches are QueryBuildErrors before SQL (#1352)" begin
    e = _tr_caught(() -> _tr_q().values("driverid", "surname").list(TrDriverRow; show_query = :sql))
    @test e isa QueryBuildError && occursin("code", e.msg) && occursin("dob", e.msg)

    e = _tr_caught(() -> _tr_q().values("driverid", "surname", "wins").list(_TrNT; show_query = :sql))
    @test e isa QueryBuildError && occursin("wins", e.msg) && occursin("no field", e.msg)

    e = _tr_caught(() -> _tr_q().values("*").list(TrDriverRow; show_query = :sql))
    @test e isa QueryBuildError && occursin("values(\"*\")", e.msg)

    # A field that is no column of the model: the existing field-resolution refusal, at build.
    @test _tr_caught(() -> _tr_q().list(TrUnknownField; show_query = :sql)) isa UnknownFieldError
end

# ─────────────────────────────────────────────────────────────────────────────
# Types a row cannot be built into are refused up front (#1352)
# Expected: QueryBuildError for an abstract type, a Dict, PormGRow, a Tuple and a struct whose inner
# constructor replaced the positional one. Matters: the failure names the declaration, not a
# MethodError from deep inside row construction.
# ─────────────────────────────────────────────────────────────────────────────
@testset "a type a row cannot be built into is refused (#1352)" begin
    # Each refusal names its own cause, so deleting one guard cannot pass by falling through to another.
    for (T, cause) in ((TrAbstract, "concrete struct"), (Dict{Symbol,Any}, "list(:dict)"),
                       (PormG.PormGRow, "without a type"), (Tuple{Int64,String}, "field names are the columns"),
                       (Int64, "field names are the columns"), (TrCustomCtor, "no such constructor"))
        e = _tr_caught(() -> _tr_q().list(T; show_query = :sql))
        @test e isa QueryBuildError && occursin(cause, e.msg)
    end
    # An abstract field type would take values the conversion rules refuse (a Bool into `::Integer`,
    # a Float64 or a Decimal into `::Real`), and its row would not be concretely typed: refused up front.
    for (T, field) in ((TrIntegerField, "active"), (TrRealField, "salary"), (TrAnyField, "surname"),
                       (TrIntUnionField, "number"))
        e = _tr_caught(() -> _tr_q().list(T; show_query = :sql))
        @test e isa QueryBuildError && occursin("concrete type for every field", e.msg) && occursin(field, e.msg)
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# NULL: the declared type decides (#1352)
# Expected: Union{Nothing,X} reads `nothing`, Union{Missing,X} reads `missing`, a plain X refuses the
# row with InvalidValueError naming the field and row. Matters: the maintainer's NULL decision, and a
# NULL must never be coerced into a non-nullable field.
# ─────────────────────────────────────────────────────────────────────────────
@testset "NULL reads as nothing or missing by the declared type, or is refused (#1352)" begin
    prost = _tr_q().filter("driverid" => 2)
    @test prost.first(TrDriverRow).code === nothing
    @test prost.first(TrDriverRow).dob === nothing
    @test prost.first(TrMissingRow).code === missing

    e = _tr_caught(() -> prost.list(TrStrictRow))
    @test e isa InvalidValueError && e.kind === :type
    @test e.field == "code" && e.row == 1 && occursin("NULL", e.msg)
end

# ─────────────────────────────────────────────────────────────────────────────
# The conversion table: decided by the types, never by the value (#1352)
# Expected: integer widths convert (out of range = :range), integer -> float exact, float widening —
# and Float->Int, Decimal->Float, Float narrowing, Bool<->Int refused :type even when THIS value would
# fit (25.0, 1000.5…). Matters: a query cannot pass in a test and fail on one production row by type.
# ─────────────────────────────────────────────────────────────────────────────
@testset "conversions are decided by the types (#1352)" begin
    rows = _tr_q().list(TrWideRow)
    @test rows[1].number === Int16(12) && rows[2].number === nothing
    @test rows[1].wins === 41.0
    @test rows[1].salary isa _TR_D.Decimal && rows[1].salary == _TR_D.Decimal(0, 100050, -2)
    @test rows[1].active === true && rows[2].active === false

    # Refused by type — `points` is 614.0 on row 1, a whole number, and still refused.
    for (T, field) in ((TrFloatToInt, "points"), (TrDecToFloat, "salary"), (TrFloatNarrow, "points"),
                       (TrBoolToInt, "active"), (TrIntToBool, "wins"))
        e = _tr_caught(() -> _tr_q().filter("driverid" => 1).list(T))
        @test e isa InvalidValueError && e.kind === :type && e.field == field
    end

    # An integer into a Decimal converts (exactly); the isa path does not reach this, `wins` is an integer.
    @test _tr_q().first(TrIntToDecimal).wins == _TR_D.Decimal(0, 41, 0)

    # A float widens; nothing in SQLite stores a Float32, so the rule is asserted on the cell function.
    site = PormG.QueryBuilder._TypedReadSite("test", "Driver")
    @test PormG.QueryBuilder._typed_value(Float64, Float32(1.5), :points, 1, site) === 1.5
    @test PormG.QueryBuilder._typed_value(Union{Nothing,Float64}, Float32(1.5), :points, 1, site) === 1.5

    # Range: 41 fits an Int8, so the first row reads; widen the check to a value that does not.
    @test _tr_q().filter("driverid" => 1).first(TrRangeRow).wins === Int8(41)
    TR.Driver.objects.filter("driverid" => 3).update("wins" => 300)
    try
        e = _tr_caught(() -> _tr_q().list(TrRangeRow))
        @test e isa InvalidValueError && e.kind === :range && e.row == 3 && e.field == "wins"
        @test !occursin("300", e.msg)     # #971: the range refusal does not carry the value either
    finally
        TR.Driver.objects.filter("driverid" => 3).update("wins" => 31)
    end

    # Integer -> float is exact or refused: 2^53 + 1 has no Float64.
    TR.Driver.objects.filter("driverid" => 3).update("wins" => 2^53 + 1)
    try
        e = _tr_caught(() -> _tr_q().list(TrWideRow))
        @test e isa InvalidValueError && e.kind === :range && e.row == 3 && e.field == "wins"
    finally
        TR.Driver.objects.filter("driverid" => 3).update("wins" => 31)
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# A refusal names the field and both types, never the value (#971, #1352)
# Expected: the message carries `points`, Float64 and Int64, and not the text "614".
# Matters: a cell can be a secret, and an app may hand `e.msg` to a client.
# ─────────────────────────────────────────────────────────────────────────────
@testset "a typed-read refusal never contains the value (#1352)" begin
    e = _tr_caught(() -> _tr_q().filter("driverid" => 1).list(TrFloatToInt))
    @test occursin("points", e.msg) && occursin("Float64", e.msg) && occursin("Int64", e.msg)
    @test !occursin("614", e.msg)
    # The location names the read and the row type, whichever terminal ran it.
    @test occursin("a typed read into TrFloatToInt", _tr_caught(() -> _tr_q().first(TrFloatToInt)).msg)

    # A nullable field names its DECLARED type, and the advice keeps the `Nothing`: a bare `Date`
    # would be refused by the next NULL.
    e = _tr_caught(() -> _tr_q().filter("driverid" => 1).list(TrNullableMismatch))
    @test e isa InvalidValueError && e.kind === :type
    @test e.field_type == "Union{Nothing, String}" && occursin("Union{Nothing, Date}", e.msg)
end

# ─────────────────────────────────────────────────────────────────────────────
# first / last / get / earliest / latest as typed reads (#1352)
# Expected: first(T) on no rows is `nothing`; get(T, …) the row or DoesNotExist /
# MultipleObjectsReturned; last/earliest/latest the same rows their untyped forms pick.
# Matters: every single-row terminal shares the typed rules, and get keeps its contract.
# ─────────────────────────────────────────────────────────────────────────────
@testset "the single-row terminals take a type (#1352)" begin
    @test _tr_q().filter("driverid" => 99).first(TrDriverRow) === nothing
    @test _tr_q().first(TrDriverRow).surname == "Senna"
    @test _tr_q().last(TrDriverRow).surname == "Mansell"
    @test TR.Driver.objects.get(TrDriverRow, "surname" => "Prost").driverid == 2
    @test TR.Driver.objects.filter("surname" => "Senna").get(TrDriverRow) isa TrDriverRow
    @test_throws DoesNotExist TR.Driver.objects.get(TrDriverRow, "surname" => "Hill")
    @test_throws MultipleObjectsReturned TR.Driver.objects.get(TrDriverRow, "active" => true)
    @test TR.Driver.objects.earliest(TrDriverRow, "wins").surname == "Mansell"
    @test TR.Driver.objects.latest(TrDriverRow, "wins").surname == "Prost"

    # The untyped forms are unchanged.
    @test _tr_q().first() isa PormG.PormGRow
    @test TR.Driver.objects.get("driverid" => 1) isa PormG.PormGRow
    # A count is not a row type: still a MethodError on the closure, never Base.first(itr, n).
    @test_throws MethodError _tr_q().first(2)
end

# ─────────────────────────────────────────────────────────────────────────────
# Building typed rows allocates nothing per row (#1352)
# Expected: `_typed_rows` over 1 000 Dict rows holding the cells PostgreSQL delivers (Int32 for an
# IntegerField, a nullable, a String, a Float64) allocates a constant handful — the output vector —
# not a count that grows with the rows. Matters: the point of the typed read is concrete code after
# the query, and two shapes regressed silently before (an `Int32` cell through `convert(X, v::Any)`,
# a mixed struct through an `ntuple` closure: ~7 and ~10 allocations a row). SQLite never hands back
# an `Int32`, so nothing else in the unit suite reaches the hand-split integer arms.
# ─────────────────────────────────────────────────────────────────────────────
_tr_mixed_dicts(n) = [Dict{Symbol,Any}(:raceid => Int64(k), :points => 1.5 * k, :surname => "Senna",
                                        :position => isodd(k) ? Int32(k) : missing,
                                        :milliseconds => Int32(90_000 + k)) for k in 1:n]
# Measured inside a function: at testset scope the timing itself allocates through globals.
function _tr_alloc_count(rows)
    site = PormG.QueryBuilder._TypedReadSite("test", "Lap_times")
    PormG.QueryBuilder._typed_rows(TrMixedRow, rows, site)       # compile
    return Base.gc_alloc_count(@timed(PormG.QueryBuilder._typed_rows(TrMixedRow, rows, site)).gcstats)
end

@testset "typed rows allocate a constant amount, not per row (#1352)" begin
    rows = _tr_mixed_dicts(1_000)
    out = PormG.QueryBuilder._typed_rows(TrMixedRow, rows, PormG.QueryBuilder._TypedReadSite("test", "Lap_times"))
    @test out[1] == TrMixedRow(1, 1.5, "Senna", 1, 90_001) && out[2].position === nothing
    small, large = _tr_alloc_count(rows), _tr_alloc_count(_tr_mixed_dicts(10_000))
    @test small == large            # does not grow with the rows (it was ~10 a row)
    @test large <= 5                # the output vector, nothing per cell
end
