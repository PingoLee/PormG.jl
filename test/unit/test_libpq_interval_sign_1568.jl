# ============================================================
# test/unit/test_libpq_interval_sign_1568.jl
#
# LibPQ reads a negative interval with a fraction of a second exactly (#1568).
#
# CONTRACT being tested:
#   Every connection the LibPQ extension opens reads an `interval` through `_interval_conversion`,
#   which parses PostgreSQL's `iso_8601` text (the `IntervalStyle` LibPQ.jl sets) with the fraction
#   signed like the seconds it belongs to. LibPQ.jl 1.18.0's own parser reads it unsigned:
#   `PT-2M-37.754S` came back as -156.246 s instead of -157.754 s, and `PT-0.754S` as +754 ms — a
#   silent wrong value, and the second one cannot be repaired after the read. Every interval LibPQ
#   already read correctly reads back identically, components included, so nothing else moves.
#
#   The end-to-end read is in test/integration/test_field_expressions.jl (#1568 testset), run on both
#   PostgreSQL drivers. This file pins the parser and the oracle, so it needs no database.
#
#   LibPQ.jl#321 fixes the upstream parser but is in no release yet. The "upstream is wrong" testset
#   is gated on the version that has the defect; when a release ships the fix, it is deleted together
#   with the override in ext/PormGLibPQExt.jl and the LibPQ floor goes up.
#
# Hermetic: the drivers are loaded, nothing connects.
# ============================================================

using Test
using PormG
using Dates

include(joinpath(@__DIR__, "..", "load_drivers.jl"))

const _IVL_EXT = Base.get_extension(PormG, :PormGLibPQExt)
_ivl(s) = _IVL_EXT._parse_iso_interval(s)
_upstream(s) = LibPQ.pqparse(Dates.CompoundPeriod, s)
_ns(p::Dates.CompoundPeriod) = sum((Dates.tons(x) for x in p.periods); init = 0)

# The defect's inputs, with the value each means computed here, in nanoseconds, from the text's own
# numbers. Mixed signs across the date part, the day and the time are PostgreSQL's (each is stored
# signed on its own); within the time part every component has the seconds' sign.
const _NEGATIVE_FRACTIONS = [
  ("PT-2M-37.754S", -(2 * 60 + 37) * 10^9 - 754 * 10^6,
   [Minute(-2), Second(-37), Millisecond(-754)]),
  ("PT-0.754S", -754 * 10^6, [Millisecond(-754)]),
  ("PT-0.000001S", -1_000, [Microsecond(-1)]),
  ("PT-1H-0.5S", -3600 * 10^9 - 500 * 10^6, [Hour(-1), Millisecond(-500)]),
  ("PT-1.000000001S", -10^9 - 1, [Second(-1), Nanosecond(-1)]),
]

@testset "a negative fraction of a second keeps its sign (#1568)" begin
  # The lap the issue reports: 157754 ms subtracted twice from itself reads back as -157754 ms.
  for (text, ns, periods) in _NEGATIVE_FRACTIONS
    got = _ivl(text)
    @test got isa Dates.CompoundPeriod
    @test _ns(got) == ns
    @test got.periods == periods
  end
  @test Dates.toms(_ivl("PT-2M-37.754S")) == -157754
  # The date part, the days and the time each carry their own sign; only the time's fraction was lost.
  mixed = _ivl("P-1Y2M-3DT-4H-5M-6.789S")
  @test mixed.periods == [Year(-1), Month(2), Day(-3), Hour(-4), Minute(-5), Second(-6), Millisecond(-789)]
end

@testset "every interval LibPQ read correctly reads back identically, components included (#1568)" begin
  # A differential against LibPQ's own parser over the inputs it gets right: positive fractions, whole
  # negative seconds, date parts alone, zero. Equal values AND the same component vector — the
  # override changes the defect and nothing else, so an app that printed a decomposition sees no change.
  for text in ("PT0S", "PT2M37.754S", "PT0.754S", "PT0.0005S", "PT25.021S", "P1DT2H", "P1Y2M3D",
               "PT-37S", "PT-2M-37S", "P-1Y-2M", "P3DT-4H", "PT1.000000001S", "PT90H", "P-5D")
    got = _ivl(text)
    want = _upstream(text)
    @test got == want
    @test got.periods == want.periods
  end
end

@testset "text the pattern does not match is LibPQ's to refuse (#1568)" begin
  # No new error: the fallback is LibPQ's parser, so a malformed text raises what it always raised.
  for text in ("1 day 02:00:00", "garbage", "PT1.0000000001S")
    @test_throws ErrorException _ivl(text)
    @test_throws ErrorException _upstream(text)
  end
end

@testset "every LibPQ connection reads an interval through the override (#1568)" begin
  conv = LibPQ.PQConversions(_IVL_EXT._CONNECTION_CONVERSIONS)
  @test conv[(:interval, Dates.CompoundPeriod)] === _IVL_EXT._interval_conversion
  @test length(conv) == 1
end

if pkgversion(LibPQ) <= v"1.18.0"
  @testset "LibPQ.jl $(pkgversion(LibPQ)) reads the same texts wrong: the override is still needed (#1568)" begin
    # Proves the defect, not only the fix: each assertion above would have failed through LibPQ's own
    # parser. When a LibPQ release carries LibPQ.jl#321 this testset stops running; then raise the
    # floor, delete the override and this file's comparisons against it.
    for (text, ns, _) in _NEGATIVE_FRACTIONS
      @test _ns(_upstream(text)) != ns
    end
    @test Dates.toms(_upstream("PT-0.754S")) == 754
  end
end
