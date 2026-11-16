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
