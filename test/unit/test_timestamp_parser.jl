# ============================================================
# test/unit/test_timestamp_parser.jl
#
# CONTRACT being tested:
#   `Models.parse_zoned_timestamp(text)` returns exactly what TimeZones.jl's
#   `_TSP_ZDT(text, Models._DATETIME_DATEFORMAT)` returns, for every text: the same `DateTime`, the
#   same zone objects (`===`: `tz"UTC"` for a zero offset, `FixedTimeZone("Z", 0)` for `Z`,
#   `FixedTimeZone("UTC±hh:mm", offset)` otherwise), or the same error type and message. It reads the
#   text PormG writes (`DATETIME_FORMAT`) at concrete types, so a `juliac --trim` image can run it
#   (#1599 layer 7, #1694), and hands any other text to TimeZones' parse, the open arm. TimeZones'
#   parse is the oracle here.
#
# Hermetic: no database.
#
# Run: julia --project=test/integration test/unit/test_timestamp_parser.jl
# ============================================================

using Test
using PormG
using Dates

const _TSP_M = PormG.Models
const _TSP_ZDT = _TSP_M.ZonedDateTime   # TimeZones' type and conversion, through PormG (not a direct test dependency);
const _TSP_ASTZ = _TSP_M.astimezone     # prefixed, as the suite includes every file into one module

_tsp_outcome(f) = try
  z = f()
  (:ok, typeof(z), z.utc_datetime, z.timezone, z.zone)
catch e
  (:err, typeof(e), sprint(showerror, e))
end
_tsp_same(a, b) = a[1] === b[1] && a[2] === b[2] && (a[1] === :err ? a[3] == b[3] : (a[3] === b[3] && a[4] === b[4] && a[5] === b[5]))

# What: `parse_zoned_timestamp` against `_TSP_ZDT(text, _DATETIME_DATEFORMAT)` over (1) the canonical shape
#   with dates and times across their ranges and past them (day 29-31 of each month, a leap and a common year,
#   hour 24, minute and second 60, years 0000 and 9999) and every offset spelling (`Z`, `±00:00`, ordinary
#   offsets, `+23:59`, `+24:00`, `+05:60`, `+99:99`, `-00:30`), and (2) other shapes TimeZones takes or
#   refuses (no milliseconds, two or four digits of them, a five-digit year, `±hhmm`, `±hh`, a lowercase `z`,
#   a space for `T`, trailing text, full-width digits, the empty string).
# Expected: the same value and zones, or the same error type and text, for every one.
# Why: the write path validates and the SQLite read path parses every timestamp through this; under the JIT it
#   must change nothing.
@testset "parse_zoned_timestamp returns what TimeZones' parse returns (#1599 layer 7)" begin
  df = _TSP_M._DATETIME_DATEFORMAT
  dates = String[]
  for (y, m, d) in (("2009", "05", "24"), ("2024", "02", "29"), ("2023", "02", "29"), ("2023", "02", "28"),
                    ("2023", "04", "31"), ("2023", "04", "30"), ("2023", "12", "31"), ("2023", "13", "01"),
                    ("2023", "00", "10"), ("2023", "06", "00"), ("0000", "01", "01"), ("9999", "12", "31"),
                    ("1970", "01", "01"), ("0001", "03", "15"))
    for (H, Mi, S, ms) in (("00", "00", "00", "000"), ("14", "30", "05", "123"), ("23", "59", "59", "999"),
                           ("24", "00", "00", "000"), ("12", "60", "00", "000"), ("12", "00", "60", "000"))
      push!(dates, "$(y)-$(m)-$(d)T$(H):$(Mi):$(S).$(ms)")
    end
  end
  offsets = ["Z", "+00:00", "-00:00", "+05:30", "-03:00", "+14:00", "-14:00", "+23:59", "+24:00", "+05:60",
             "+99:99", "-00:30", "+00:30"]
  n = 0
  for d in dates, o in offsets
    t = d * o
    @test _tsp_same(_tsp_outcome(() -> _TSP_M.parse_zoned_timestamp(t)), _tsp_outcome(() -> _TSP_ZDT(t, df)))
    n += 1
  end
  others = ["2009-05-24T14:00:00+00:00", "2009-05-24T14:00:00.12+00:00", "2009-05-24T14:00:00.1234+00:00",
            "12009-05-24T14:00:00.000+00:00", "2009-05-24T14:00:00.000+0530", "2009-05-24T14:00:00.000+05",
            "2009-05-24T14:00:00.000z", "2009-05-24 14:00:00.000+00:00", "2009-05-24T14:00:00.000+00:00 ",
            "2009-05-24T14:00:00.000+00:00Z", "２００９-05-24T14:00:00.000+00:00", "", "2009-05-24",
            "2009-05-24T14:00:00.000+5:30", "2009-05-24T14:00:00.000+05:3", "2009-5-24T14:00:00.000+00:00",
            "2009-05-24T14:00:00.000UTC", "2009-05-24T14:00:00.000+05:30:00", "-009-05-24T14:00:00.000+00:00"]
  for t in others
    @test _tsp_same(_tsp_outcome(() -> _TSP_M.parse_zoned_timestamp(t)), _tsp_outcome(() -> _TSP_ZDT(t, df)))
  end
  # A `SubString` is read as its text.
  t = "x2009-05-24T14:00:00.000+05:30"
  @test _tsp_same(_tsp_outcome(() -> _TSP_M.parse_zoned_timestamp(SubString(t, 2))), _tsp_outcome(() -> _TSP_ZDT(t[2:end], df)))
  # The typed path takes the canonical text: no call to TimeZones' parser for it.
  @test _TSP_M._canonical_zoned("2009-05-24T14:00:00.000+00:00") !== nothing
  @test _TSP_M._canonical_zoned("2009-05-24T14:00:00.000+00:00").timezone === _TSP_M._DATETIME_UTC_TZ
  @test _TSP_M._canonical_zoned("2009-05-24T14:00:00+00:00") === nothing   # another shape: the open arm
  @test n == length(dates) * length(offsets)
end

# What: the two places a timestamp text is parsed: the write path's validation (`validate_timezone`, through
#   `format_timezone_sql`) and the SQLite read parser (`Dialect._parse_sqlite_timestamp`).
# Expected: the same canonical text and the same parsed value as TimeZones' parse gives, for PormG's own text and
#   for an offset and a `Z` a caller can write; a text neither shape takes keeps its refusal or its fail-open value.
# Why: both moved from TimeZones' parse to `parse_zoned_timestamp`.
@testset "the write validation and the SQLite read parse timestamps as before (#1599 layer 7)" begin
  df = _TSP_M._DATETIME_DATEFORMAT
  canon(z) = Dates.format(_TSP_ASTZ(z, _TSP_M._DATETIME_UTC_TZ), df)
  for t in ("2009-05-24T14:00:00.000+00:00", "2009-05-24T14:00:00+00:00", "2009-05-24 14:00:00.5-03:00",
            "2009-05-24T14:00:00.123456Z")
    want = try; canon(_TSP_ZDT(_TSP_M.normalize_sqlite_datetime_string(replace(t, ' ' => 'T', count = 1)), df)); catch e; e; end
    got = try; _TSP_M.format_timezone_sql(t); catch e; e; end
    @test (t, got) == (t, want)
    # Where TimeZones parses the normalized text, the read returns exactly that value; where it refuses it, so does
    # `parse_zoned_timestamp` (the testset above), and the read's fallback after it is unchanged.
    oracle = _tsp_outcome(() -> _TSP_ZDT(_TSP_M.normalize_sqlite_datetime_string(t), df))
    oracle[1] === :ok && @test _tsp_same(_tsp_outcome(() -> PormG.Dialect._parse_sqlite_timestamp(t)), oracle)
  end
  # Fail-open on the read side, refused on the write side, as before.
  @test PormG.Dialect._parse_sqlite_timestamp("not a timestamp") == "not a timestamp"
  @test_throws PormG.InvalidValueError _TSP_M.format_timezone_sql("2009-13-45T25:61:00.000+00:00")
  @test_throws PormG.InvalidValueError _TSP_M.format_timezone_sql("2009-05-24T14:00:00.000+05:60")   # its range check, before any parse
end

# What: `_canonicalize_datetime_utc(zdt)`, the text a timestamp is written as, against the `Dates.format` it
#   replaced, over a grid of years (0 through 9999, and outside it: 10000, 12009, -1, -5), months, days,
#   milliseconds and zones, and a deterministic sweep of 20,000 instants.
# Expected: the same text for every one.
# Why: it is written by hand for years 0-9999 (`Dates.format` pads through code a trimmed image has no code for,
#   #1599 layer 7); every other year keeps `Dates.format`, which writes a year's last four digits.
@testset "a timestamp's canonical text is the one Dates.format wrote (#1599 layer 7)" begin
  old(z) = Dates.format(_TSP_ASTZ(z, _TSP_M._DATETIME_UTC_TZ), _TSP_M._DATETIME_DATEFORMAT)
  zones = [_TSP_M._DATETIME_UTC_TZ, _TSP_M.FixedTimeZone("UTC+05:30", 19800), _TSP_M.FixedTimeZone("UTC-03:00", -10800),
           _TSP_M.FixedTimeZone("Z", 0), _TSP_M.FixedTimeZone("UTC+14:00", 50400)]
  for y in (0, 1, 9, 10, 99, 100, 999, 1000, 1969, 1970, 2009, 9998, 9999, 10000, 12009, -1, -5), m in (1, 12),
      d in (1, 28), ms in (0, 7, 45, 999), tz in zones
    z = _TSP_ZDT(DateTime(y, m, d, 1, 2, 3, ms), tz)
    @test (z, _TSP_M._canonicalize_datetime_utc(z)) == (z, old(z))
  end
  mismatches = 0
  for k in 0:19_999
    dt = DateTime(k % 10_000, 1 + k % 12, 1 + k % 28, k % 24, (7k) % 60, (13k) % 60, (37k) % 1000)
    z = _TSP_ZDT(dt, zones[1 + k % length(zones)])
    _TSP_M._canonicalize_datetime_utc(z) == old(z) || (mismatches += 1)
  end
  @test mismatches == 0
end
