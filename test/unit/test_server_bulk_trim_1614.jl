# ============================================================
# test/unit/test_server_bulk_trim_1614.jl
#
# CONTRACT being tested:
#   The typed forms `bulk_insert` on the servers now goes through (#1599 layers 2 and 7, #1614) return what the forms
#   they replaced returned, value for value and type for type:
#     - the Postgres.jl extension's `_ms(fraction)`, the milliseconds of a timestamp's fraction, is the old
#       `parse(Int, rpad(fraction, 3, '0')[1:3])` for every fraction the timestamp patterns admit (1 to 6 digits) and
#       for none, and the timestamp parsers built on it read the same values;
#     - `_bulk_result_at(count, rows)` is `_bulk_result(count, rows)`, the same concrete `NamedTuple`;
#     - the cause walk (`_unowned_field`) reads a `Core.MissingCodeError`'s field as `hasproperty`/`getproperty` do.
#   The old forms are the oracle. What `bulk_insert` sends and counts end to end is pinned by the bulk suite.
#
# Hermetic: no database.
#
# Run: julia --project=test/integration test/unit/test_server_bulk_trim_1614.jl
# ============================================================

using Test
isdefined(Main, :SQLite) || include(joinpath(@__DIR__, "..", "load_drivers.jl"))
using PormG
using Dates

const _SBT_PGX = Base.get_extension(PormG, :PormGPostgresExt)
const _SBT_QB = PormG.QueryBuilder

_sbt_old_ms(fraction) = fraction === nothing ? 0 : parse(Int, rpad(fraction, 3, '0')[1:3])

# What: the Postgres.jl extension's millisecond read against the old `rpad` form, over every fraction of 1 to 3 digits,
#   a sample of 4 to 6 digits, each as a `SubString` of a timestamp (what the pattern's capture is) and as a `String`, and
#   `nothing`; then the two timestamp parsers over values whose fraction PostgreSQL printed without its trailing zeros.
# Expected: the same `Int` for every fraction, and the same `DateTime`/`ZonedDateTime` for every value.
# Why: `rpad` had no compiled target in a trimmed image when it had to pad, and PostgreSQL drops a fraction's trailing
#   zeros, so a trimmed Postgres.jl `create` whose timestamp's milliseconds ended in 0 failed; the new read must give the
#   same milliseconds for every fraction.
@testset "the Postgres.jl millisecond read gives the old value for every fraction (#1599 layer 2, #1614)" begin
  fractions = String[]
  for n in 1:3, k in 0:(10^n - 1)
    push!(fractions, lpad(string(k), n, '0'))
  end
  append!(fractions, ["1234", "0005", "99999", "000001", "123456", "500000", "100000", "999999"])
  for f in fractions
    sub = SubString("2009-05-24 14:00:00.$(f)+00", 21, 20 + ncodeunits(f))
    @test sub == f
    @test (f, _SBT_PGX._ms(sub), _SBT_PGX._ms(f)) == (f, _sbt_old_ms(sub), _sbt_old_ms(f))
    @test _SBT_PGX._ms(sub) isa Int
  end
  @test _SBT_PGX._ms(nothing) === 0 === _sbt_old_ms(nothing)
  for s in ("2009-05-24 14:00:00.12+00", "2009-05-24 14:00:00.5+00", "2009-05-24 14:00:00.1+05:30", "2009-05-24 14:00:00.07-03",
            "2009-05-24 14:00:00.123456+02:30:15", "2009-05-24 14:00:00+00", "infinity", "-infinity")
    zoned = _SBT_PGX._pg_timestamptz(s)
    @test zoned isa PormG.Models.ZonedDateTime
  end
  @test _SBT_PGX._pg_timestamptz("2009-05-24 14:00:00.12+00") ==
        PormG.Models.ZonedDateTime(DateTime(2009, 5, 24, 14, 0, 0, 120), PormG.Models.TimeZone("UTC"))
  @test _SBT_PGX._pg_timestamp("2009-05-24 14:00:00.5") == DateTime(2009, 5, 24, 14, 0, 0, 500)
  @test _SBT_PGX._pg_timestamp("2009-05-24 14:00:00.000001") == DateTime(2009, 5, 24, 14, 0, 0, 0)
end

# What: the bulk writers' total through `_bulk_result_at` against `_bulk_result`, over the count types a total can be
#   (`Int`, and the open arm's `Int32`, `Int8`, `BigInt`) and a result's `rows` (`nothing`, a table).
# Expected: the same value, and for the same arguments the same concrete type.
# Why: `bulk_insert` returns `(count, rows)`, which a caller (the trim fixture among them) asserts at its concrete type.
@testset "the bulk total is the result it was (#1599 layer 7, #1614)" begin
  for c in Any[0, 2, Int32(5), Int8(1), big(7)], rows in Any[nothing, [(raceid = 1,)], Dict{String, Vector{Any}}()]
    new = _SBT_QB._bulk_result_at(c, rows)
    old = _SBT_QB._bulk_result(c, rows)
    @test (typeof(c), typeof(new), new) == (typeof(c), typeof(old), old)
  end
end

# What: the cause walk's field read on a `Core.MissingCodeError`, what a trimmed image raises for a call it has no code
#   for, against `hasproperty`/`getproperty`.
# Expected: the same answer for its field and for a field it does not have.
# Why: unlisted, the walk's open arm called `hasproperty` on it, which a trimmed image has no code for, so that
#   `MethodError` replaced the error being reported; listed, the read is the same.
@testset "the cause walk reads a MissingCodeError as hasproperty does (#1599, #1614)" begin
  mi = first(mi for mi in Base.specializations(which(+, (Int, Int))) if mi isa Core.MethodInstance)
  e = Core.MissingCodeError(mi)
  @test PormG._unowned_field(e, :mi) === getproperty(e, :mi)
  @test PormG._unowned_field(e, :cause) === nothing && !hasproperty(e, :cause)
  @test Core.MissingCodeError in PormG._KNOWN_EXCEPTIONS
end

# What: PostgreSQL's bulk column arrays: each formatted cell through `_pg_array_element_at` against `_pg_array_element`,
#   over the types a field formatter returns and ones that take the open arm, and the loop that fills the columns
#   against the `foreach` it replaces, columns of equal and unequal length.
# Expected: the same element at the same type, and the same columns, in the same order.
# Why: the `foreach` closure was called with each cell's run-time type, which a trimmed image had no instance for, so a
#   trimmed Postgres.jl `bulk_insert` raised `MethodError` on it; the array PostgreSQL binds must not change.
@testset "PostgreSQL's bulk column arrays are filled as before (#1599 layer 7, #1614)" begin
  cells = Any["Monaco", 2010, missing, nothing, true, SubString("Monaco GP", 1, 6), Int32(6), 2.5,
              PormG.PormGBytes(UInt8[0x01, 0x02]), PormG.PormGArrayLiteral("{1,2}"),
              PormG.Models.Decimals.Decimal(0, 150, -2), Date(2010, 5, 16), :sym, Int16(3)]
  for c in cells
    new = _SBT_QB._pg_array_element_at(c)
    old = _SBT_QB._pg_array_element(c)
    @test (typeof(c), typeof(new), isequal(new, old)) == (typeof(c), typeof(old), true)
  end
  for (ncols, ncells) in ((3, 3), (3, 2), (2, 3))
    row = cells[1:ncells]
    old_cols = [Any[] for _ in 1:ncols]; new_cols = [Any[] for _ in 1:ncols]
    foreach((column, cell) -> push!(column, _SBT_QB._pg_array_element(cell)), old_cols, row)
    for j in 1:min(length(new_cols), length(row)); push!(new_cols[j], _SBT_QB._pg_array_element_at(row[j])); end
    @test isequal(new_cols, old_cols)
  end
end
