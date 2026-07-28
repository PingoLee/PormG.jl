"""
Unit tests for issue #79 — DateTimeField values are canonicalized to a single UTC
ISO-8601 string (`yyyy-mm-ddTHH:MM:SS.sss+00:00`) on both the write/bind path and the
filter path, so SQLite's lexicographic TEXT comparison agrees with PostgreSQL's
instant comparison.

Root cause: SQLite stores datetimes as TEXT and compares them byte-for-byte, but
PormG's shared formatter (`Models.format_timezone_sql`, wired as the `DateTimeField`
`.formatter`) previously returned any offset-bearing string verbatim. Equivalent
instants in different spellings (`Z` vs `+00:00`, `.0`/`.000`/no-subsecond, non-UTC
offsets) therefore produced *distinct* TEXT that neither compared equal nor ordered
chronologically on SQLite — while PostgreSQL saw them as the same `timestamptz`.

Fix contract (mirrors Django `USE_TZ` / Rails / SQLAlchemy): every equivalent instant
collapses to ONE canonical UTC string. `format_timezone_sql` is the single choke point
feeding both create/update binds and filter parameters, so pinning it here guards both
paths with no live database (`show_query=:dict` for the filter-plumbing check).

Why a dedicated file: no existing unit test covers `format_timezone_sql` /
`validate_timezone` canonicalization, and a silent regression (dropping the UTC
conversion or the sub-second padding) would re-introduce the PG/SQLite divergence with
no other failing test.
"""

using Test
using PormG
using Dates, TimeZones
using PormG.Models: Model, IDField, DateTimeField, format_timezone_sql

# The one canonical string every "2020-01-01 10:00:00 UTC" spelling must collapse to.
const _CANON79 = "2020-01-01T10:00:00.000+00:00"

# ---------------------------------------------------------------------------
# Minimal mock-Postgres fixture (no live database) for the filter-plumbing check.
# Defined at top level (struct/model) like test_date_bucket_operator.jl.
# ---------------------------------------------------------------------------
if !isdefined(Main, :_Dt79Event)
  _Dt79Event = Model("dt79_events",
    id         = IDField(),
    event_time = DateTimeField(null = true),
  )
  _Dt79Event.connect_key = "default"

  struct _MockPostgres79 <: PormG.PormGPostgres end
  PormG.config["default"] = PormG.Configuration.Settings(
    connections = _MockPostgres79(),
    change_data = true,
  )
end

@testset "DateTime UTC canonicalization (#79)" begin

  # =========================================================================
  # 1. Every spelling of the same instant → one canonical UTC string
  # =========================================================================
  @testset "equivalent instants collapse to one canonical UTC string" begin
    # Same UTC instant, different offset tokens / sub-second spellings.
    @test format_timezone_sql("2020-01-01T10:00:00Z")          == _CANON79
    @test format_timezone_sql("2020-01-01T10:00:00.000Z")      == _CANON79
    @test format_timezone_sql("2020-01-01T10:00:00.0Z")        == _CANON79
    @test format_timezone_sql("2020-01-01T10:00:00+00:00")     == _CANON79
    @test format_timezone_sql("2020-01-01T10:00:00.000+00:00") == _CANON79

    # Cross-offset: the SAME instant expressed in another zone must convert to UTC.
    @test format_timezone_sql("2020-01-01T15:30:00+05:30")     == _CANON79  # +05:30 → UTC
    @test format_timezone_sql("2020-01-01T07:00:00-03:00")     == _CANON79  # -03:00 → UTC

    # Naive string (no offset) is assumed UTC.
    @test format_timezone_sql("2020-01-01T10:00:00")           == _CANON79

    # Object inputs go through the ZonedDateTime / DateTime methods.
    @test format_timezone_sql(DateTime(2020, 1, 1, 10, 0, 0))  == _CANON79
    @test format_timezone_sql(ZonedDateTime(DateTime(2020, 1, 1, 10, 0, 0), TimeZone("UTC")))              == _CANON79
    @test format_timezone_sql(ZonedDateTime(DateTime(2020, 1, 1, 7, 0, 0),  TimeZone("America/Sao_Paulo"))) == _CANON79
  end

  # =========================================================================
  # 2. Sub-seconds preserved at fixed 3-digit (millisecond) width
  # =========================================================================
  @testset "sub-second precision preserved and fixed-width" begin
    @test format_timezone_sql("2020-01-01T10:00:00.5Z")   == "2020-01-01T10:00:00.500+00:00"  # 500 ms
    @test format_timezone_sql("2020-01-01T10:00:00.05Z")  == "2020-01-01T10:00:00.050+00:00"  # 50 ms
    @test format_timezone_sql("2020-01-01T10:00:00.123Z") == "2020-01-01T10:00:00.123+00:00"
    @test format_timezone_sql(ZonedDateTime(DateTime(2020, 1, 1, 10, 0, 0, 500), TimeZone("UTC"))) ==
          "2020-01-01T10:00:00.500+00:00"
  end

  # =========================================================================
  # 2b. Naive / bare-date / separator / sub-millisecond string inputs
  # =========================================================================
  @testset "naive, bare-date, separator, and sub-millisecond inputs" begin
    # Naive (no offset) is assumed UTC.
    @test format_timezone_sql("2020-01-01T10:00:00")   == _CANON79
    @test format_timezone_sql("2020-01-01T10:00")      == _CANON79                        # no seconds
    @test format_timezone_sql("2020-01-01T10:00:00.5") == "2020-01-01T10:00:00.500+00:00" # naive sub-second
    # Bare date → midnight UTC.
    @test format_timezone_sql("2020-01-01")            == "2020-01-01T00:00:00.000+00:00"
    # Single-space separator (Django / SQLite `datetime()` rendering), naive and offset forms.
    @test format_timezone_sql("2020-01-01 10:00:00Z")  == _CANON79
    @test format_timezone_sql("2020-01-01 10:00:00")   == _CANON79
    # Sub-millisecond precision (e.g. Python's microsecond isoformat) is truncated to ms
    # consistently on BOTH the offset and the naive branch — same instant → same string.
    @test format_timezone_sql("2020-01-01T10:00:00.123456Z") == "2020-01-01T10:00:00.123+00:00"
    @test format_timezone_sql("2020-01-01T10:00:00.123456")  == "2020-01-01T10:00:00.123+00:00"
  end

  # =========================================================================
  # 3. Idempotent — feeding the canonical form back yields itself
  #    (the migrations planner double-formats; validation pre-calls the formatter).
  # =========================================================================
  @testset "idempotent" begin
    c = format_timezone_sql("2020-01-01T07:00:00-03:00")
    @test c == _CANON79
    @test format_timezone_sql(c) == c
  end

  # =========================================================================
  # 4. Missing / nothing pass through; unparseable strings are rejected
  # =========================================================================
  @testset "missing / nothing pass through; invalid rejected" begin
    @test format_timezone_sql(missing) === missing
    @test format_timezone_sql(nothing) === missing
    @test_throws PormG.InvalidValueError format_timezone_sql("not-a-date")
    # Out-of-range offsets must be rejected, not silently shifted into a wrong instant.
    @test_throws PormG.InvalidValueError format_timezone_sql("2020-01-01T10:00:00+25:00")  # hour > 23
    @test_throws PormG.InvalidValueError format_timezone_sql("2020-01-01T10:00:00+00:60")  # minute > 59
    # Real-world offsets (up to the ±14:00 max) are still accepted and converted to UTC.
    @test format_timezone_sql("2020-01-01T10:00:00+14:00") == "2019-12-31T20:00:00.000+00:00"
    @test format_timezone_sql("2020-01-01T10:00:00-13:00") == "2020-01-01T23:00:00.000+00:00"
  end

  # =========================================================================
  # 5. Filter-path plumbing — a DateTimeField filter binds the CANONICAL parameter,
  #    proving canonicalization reaches the WHERE clause, not just the formatter.
  # =========================================================================
  @testset "filter binds canonical datetime parameter" begin
    res = _Dt79Event.objects.filter("event_time" => "2020-01-01T10:00:00Z").list(show_query = :dict)
    @test res[:parameters] == [_CANON79]
    # Value is bound as a parameter, never interpolated into the SQL text.
    @test !contains(res[:sql_text], "2020-01-01")
  end

  # =========================================================================
  # 6. DDL DEFAULT for a DateTimeField default is canonicalized too (issue #79),
  #    so a DEFAULT-filled row matches canonical filter values on SQLite.
  # =========================================================================
  @testset "DDL DEFAULT is canonicalized" begin
    # America/Sao_Paulo 07:00 (-03:00) == 10:00 UTC.
    @test PormG.Dialect._format_default_sql_value(
              ZonedDateTime(DateTime(2020, 1, 1, 7, 0, 0), TimeZone("America/Sao_Paulo"))) ==
          "'2020-01-01T10:00:00.000+00:00'"
    # A naive DateTime default is treated as UTC.
    @test PormG.Dialect._format_default_sql_value(DateTime(2020, 1, 1, 10, 0, 0)) ==
          "'2020-01-01T10:00:00.000+00:00'"
    # Date / Time defaults are unaffected (already canonical for their field types).
    @test PormG.Dialect._format_default_sql_value(Date(2020, 1, 1)) == "'2020-01-01'"
  end

end
