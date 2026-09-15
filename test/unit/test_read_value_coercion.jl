"""
Reading a temporal value back on SQLite (#564, sibling 4 — the parser half).

PormG shipped THREE write formatters and ZERO read parsers. `Models.format_date_sql`,
`format_text_sql(::Time)` and `format_duration_sql` all wrote text into SQLite columns, and nothing
read any of it back: a `DateField`, a `TimeField` and a `DurationField` all surfaced as `String`,
while PostgreSQL's driver delivered `Date`, `Time` and a `Period` for the same query. Only
`DateTimeField` had a parser, and only for an alias naming a plain, unjoined column on the primary
model.

This file asserts the half that was missing, as a PROPERTY rather than as a list of strings:

    parser(formatter(x)) == x     for every temporal kind

That is the assertion which would have caught three-formatters-zero-parsers in the first place, and
it is why slots 1 and 3 of the representation table are inverses by construction rather than by two
people writing matching code years apart.

**Every parser is fail-open**, and that is what makes a wrong caller harmless instead of lossy:
handed a value it does not recognise it returns it UNCHANGED, never an approximation. So a
mis-resolved kind degrades to the raw value — exactly what SQLite returned before this table
existed — and can never produce a wrong typed value. Each parser is checked for that explicitly,
not just for its happy path.

No database: the parsers are pure functions of a string, and the table is pure dispatch.

julia --project=. test/unit/test_read_value_coercion.jl
"""

using Test
using PormG
using PormG.Models
using Dates
import TimeZones

struct RvcMockSQLite <: PormG.PormGSQLite end
struct RvcMockPostgres <: PormG.PormGPostgres end
const _RVC_SL = RvcMockSQLite()
const _RVC_PG = RvcMockPostgres()

# One probe per kind, each carrying a non-zero sub-second component where the format has one — a
# value ending in `.000` would let a parser that drops the fraction pass by coincidence.
const _RVC_PROBES = [
  (PormG.CDateTime(true),  TimeZones.ZonedDateTime(2031, 7, 4, 12, 30, 45, 123, TimeZones.tz"UTC")),
  (PormG.CDate(),          Date(2031, 7, 4)),
  (PormG.CTime(),          Time(12, 30, 45, 123)),
  (PormG.CInterval(),      Minute(1) + Second(49) + Millisecond(88)),   # lap 1 of race 1: "1:49.088"
]

# ── A scratch model, for the RECORDER half (#564) ────────────────────────────
# The parsers above are pure functions of a string; what decides whether one ever RUNS is the
# alias→kind map the build records. That half needs a model and a mock connection, not a database.
PormG.config["rvc_mock"] = PormG.Configuration.Settings(
  connections = _RVC_SL, change_data = true, db_def_folder = "rvc_mock")

module RvcModels
import PormG
import PormG.Models
Rvc_team = Models.Model("rvc_team", id = Models.IDField(), founded = Models.DateField(null = true))
Rvc_row = Models.Model("rvc_row",
  id    = Models.IDField(),
  team  = Models.ForeignKey(Rvc_team, on_delete = "CASCADE", related_name = "rvc_rows", null = true),
  ts    = Models.DateTimeField(null = true),
  d     = Models.DateField(null = true),
  t     = Models.TimeField(null = true),
  dur   = Models.DurationField(null = true),
  # #564: a temporal column whose PHYSICAL name differs from its field name. `SELECT "Tb".*` returns
  # the physical name, so a recorder keyed only on the field name never coerces this one.
  moved = Models.DateTimeField(db_column = "moved_at", null = true),
  note  = Models.CharField(null = true),
)
PormG.Models.set_models(@__MODULE__, "rvc_mock")
end
const RVC = RvcModels

"""Build a query on the mock connection and return the recorded alias→kind map."""
function _rvc_kinds(build!::Function)
  q = RVC.Rvc_row.objects
  build!(q)
  PormG.QueryBuilder.query(q; connection = _RVC_SL, show_query = :sql)
  return q.object.projection_kinds
end

@testset "Reading a temporal value back on SQLite (#564)" begin

  # ───────────────────────────────────────────────────────────────────────────
  # THE PROPERTY. Slot 3 undoes slot 1, for every kind the table owns. Stated over the table rather
  # than over hand-written strings, so a kind added to the table without a parser fails here.
  # ───────────────────────────────────────────────────────────────────────────
  @testset "the parser is the formatter's inverse, for every temporal kind" begin
    for (kind, probe) in _RVC_PROBES
      formatter = PormG.value_formatter(kind, _RVC_SL)
      parser    = PormG.value_parser(kind, _RVC_SL)
      @test formatter !== nothing
      @test parser !== nothing
      @test parser(formatter(probe)) == probe
    end
  end

  # ───────────────────────────────────────────────────────────────────────────
  # The exact stored forms, spelled literally rather than computed. A change in a formatter shows up
  # here as a failure instead of being tracked silently by a test that recomputes whatever the code
  # now does — the same reason `test_f_date_operands.jl` spells its canonical strings out.
  # ───────────────────────────────────────────────────────────────────────────
  @testset "the stored forms are the ones the F1 fixture actually holds" begin
    @test PormG.value_parser(PormG.CDate(), _RVC_SL)("2009-03-29") == Date(2009, 3, 29)
    @test PormG.value_parser(PormG.CTime(), _RVC_SL)("06:00:00") == Time(6, 0, 0)
    # `Lap_times.time` for race 1 / driver 1 / lap 1, verbatim.
    @test PormG.value_parser(PormG.CInterval(), _RVC_SL)("00:01:49.088") ==
          Minute(1) + Second(49) + Millisecond(88)
    @test PormG.value_parser(PormG.CDateTime(true), _RVC_SL)("2009-03-29T06:00:00.000+00:00") ==
          TimeZones.ZonedDateTime(2009, 3, 29, 6, 0, 0, 0, TimeZones.tz"UTC")
  end

  # ───────────────────────────────────────────────────────────────────────────
  # FAIL-OPEN. This is the property that bounds the blast radius of a mis-resolved kind, so it is
  # asserted per parser rather than assumed. `===` where the input is a `String`, because "returned
  # unchanged" must mean the same object, not an equal one built by a lossy round trip.
  # ───────────────────────────────────────────────────────────────────────────
  @testset "an unrecognised value is returned unchanged, never approximated" begin
    for (kind, _) in _RVC_PROBES
      parser = PormG.value_parser(kind, _RVC_SL)
      # A non-String is already typed, or is an engine artifact — the integer `2031` that
      # `CAST(col AS DATE)` yields on SQLite (#562) is the live example.
      @test parser(2031) === 2031
      @test parser(missing) === missing
      @test parser(nothing) === nothing
      @test parser(Date(2031, 7, 4)) === Date(2031, 7, 4)
      # Text in a shape this parser did not write.
      for junk in ("", "not a value", "2031", "  ", "2031/07/04")
        @test parser(junk) === junk
      end
    end
  end

  # ───────────────────────────────────────────────────────────────────────────
  # Per-parser edges, each one a decision rather than an accident.
  # ───────────────────────────────────────────────────────────────────────────
  @testset "the date parser refuses a timestamp instead of truncating it" begin
    p = PormG.value_parser(PormG.CDate(), _RVC_SL)
    # A `CDate`-kinded expression that produced a timestamp means the RENDER side mistyped it.
    # Truncating would hide exactly the class of defect #564 exists to surface.
    @test p("2031-07-04T12:30:45.123+00:00") === "2031-07-04T12:30:45.123+00:00"
    # Well-shaped but not a real calendar date: returned unchanged, not thrown.
    @test p("2023-02-29") === "2023-02-29"
  end

  @testset "the time parser accepts the shapes the formatter writes, and no others" begin
    p = PormG.value_parser(PormG.CTime(), _RVC_SL)
    @test p("06:00:00") == Time(6)
    @test p("12:30:45.123") == Time(12, 30, 45, 123)
    @test p("12:30") == Time(12, 30)
    @test p("25:00:00") === "25:00:00"           # not a time; unchanged rather than an error
  end

  @testset "the interval parser is built from the writer's own units" begin
    p = PormG.value_parser(PormG.CInterval(), _RVC_SL)
    # `Dates.canonicalize` would roll 26 hours up into a day, while `format_duration_sql` caps at
    # hours — so the round trip would not close and a re-write would emit a different string.
    round_trip = p(Models.format_duration_sql(Hour(26) + Minute(5)))
    @test Models.format_duration_sql(round_trip) == "26:05:00"
    # A negative duration keeps its sign on every component.
    @test p("-01:30:00") == Dates.CompoundPeriod(Hour(-1), Minute(-30), Second(0), Nanosecond(0))
    # `CompoundPeriod <: Dates.AbstractTime` is the parity PostgreSQL's driver already delivers.
    @test p("00:01:49.088") isa Dates.AbstractTime
  end

  @testset "the timestamp parser matches a shape before parsing it" begin
    p = PormG.value_parser(PormG.CDateTime(true), _RVC_SL)
    # The canonical form, with offset.
    @test p("2031-07-04T12:30:45.123+00:00") isa TimeZones.ZonedDateTime
    # A naive form, with and without the `T` — SQLite's own `datetime()` writes the space-separated
    # one (#570), and a reader that assumed `T` returned it as a String.
    @test p("2031-07-04T12:30:45") == DateTime(2031, 7, 4, 12, 30, 45)
    @test p("2031-07-04 12:30:45") == DateTime(2031, 7, 4, 12, 30, 45)
    # The fallback used to slice the RAW string at byte 19, which is a `StringIndexError` on a
    # multi-byte value — swallowed by a bare `catch`. It must come back unchanged instead.
    @test p("2031-07-04T12:30:45é") === "2031-07-04T12:30:45é"
    # #569's doubled seconds are in no shape anything here wrote, and must NOT be coerced: they are
    # a separate, open defect, and a parser that guessed at them would hide it.
    @test p("2031-07-04T12:30:45.45.123+00:00") === "2031-07-04T12:30:45.45.123+00:00"
  end

  # ───────────────────────────────────────────────────────────────────────────
  # PostgreSQL asks for no parser at all — LibPQ delivers typed values, and re-parsing one would be
  # both wasted work and a chance to get it wrong. Asserted for EVERY canonical type, not only the
  # temporal ones, because the read path asks the table before it knows what it is holding.
  # ───────────────────────────────────────────────────────────────────────────
  @testset "PostgreSQL needs no parser, for any kind" begin
    for kind in (PormG.CDateTime(true), PormG.CDateTime(false), PormG.CDate(), PormG.CTime(),
                 PormG.CInterval(), PormG.CText(), PormG.CInt64(), PormG.CBool())
      @test PormG.value_parser(kind, _RVC_PG) === nothing
    end
  end

  # ───────────────────────────────────────────────────────────────────────────
  # A kind the table does not own has no parser on either engine — `nothing`, not a passthrough
  # function, so the read path can skip the column entirely rather than call an identity per row.
  # ───────────────────────────────────────────────────────────────────────────
  @testset "an unowned kind has no parser" begin
    for kind in (PormG.CText(), PormG.CInt64(), PormG.CBool(), PormG.CBytes())
      @test PormG.value_parser(kind, _RVC_SL) === nothing
    end
  end

  # ───────────────────────────────────────────────────────────────────────────
  # `list(:json)`'s duration serializer must be FAIL-OPEN, and this is the one place in the branch
  # where "fail-open" prevents a HARD ERROR rather than a wrong value.
  #
  # `Models.format_duration_sql` refuses a month or year component — `DurationField` deliberately
  # does not store one, because the conversion is ambiguous. But the JSON serializer dispatches on
  # the Julia VALUE, not on a column kind, so a PostgreSQL `interval` holding `'1 month'` (a column
  # PormG did not write, or an introspected database) reaches it. Formatting unconditionally turns a
  # working `list(:json)` into an exception — a worse regression than the lossy shape it fixes.
  #
  # Caught by asking what `format_duration_sql` actually does with a `Month`, after the first version
  # of the fix called it unconditionally.
  # ───────────────────────────────────────────────────────────────────────────
  @testset "the JSON duration serializer never throws on a period it cannot format" begin
    jv = PormG.QueryBuilder._json_value
    # What it CAN format, it does — the whole point of the fix.
    @test jv(Minute(1) + Second(49) + Millisecond(88)) == "00:01:49.088"
    @test jv(Hour(24)) == "24:00:00"
    # What it cannot, it hands back untouched rather than raising.
    # `=== refused` is the assertion doing the work: it can only hold if the call RETURNED, so it
    # covers "does not throw" and "does not approximate" at once. (`@test_nowarn` would be the wrong
    # idiom here — it asserts the absence of a warning, not of an exception.)
    for refused in (Month(1), Year(1), Dates.CompoundPeriod(Month(1), Day(2)))
      @test jv(refused) === refused
    end
    # And it is not in the way of anything else.
    @test jv("text") === "text"
    @test jv(42) === 42
    @test jv(missing) === missing
  end

  # ───────────────────────────────────────────────────────────────────────────
  # THE RECORDER. A parser only runs if the build recorded a kind for that output name, so the map is
  # half the fix and the half a value-level test cannot reach. Asserted white-box on a mock
  # connection, because the failures below are invisible on any single-column result.
  # ───────────────────────────────────────────────────────────────────────────
  @testset "the build records a kind per projection" begin
    kinds = _rvc_kinds(q -> q.values("a" => "ts", "b" => "d", "c" => "t", "e" => "dur", "z" => "note"))
    @test kinds[:a] == PormG.CDateTime(true)
    @test kinds[:b] == PormG.CDate()
    @test kinds[:c] == PormG.CTime()
    @test kinds[:e] == PormG.CInterval()
    # A non-temporal column records nothing: `nothing` means "no representation this table owns", and
    # the read path must skip the column entirely rather than call an identity on every row.
    @test !haskey(kinds, :z)
  end

  # The ORDERING the whole fix rests on. Resolving a dotted path is what populates the memo its kind
  # is read from, so the projection must be RENDERED before it is TYPED. Typing first answers
  # `nothing` for every joined temporal column — and the failure is invisible unless two projections
  # name the same joined path, because the second one then reads the memo the first one filled.
  # That asymmetry is exactly what this case pins.
  @testset "a joined projection is typed (render-then-type order)" begin
    kinds = _rvc_kinds(q -> q.values("a" => "team__founded", "b" => "team__founded"))
    @test kinds[:a] == PormG.CDate()
    @test kinds[:b] == PormG.CDate()
  end

  # `SELECT "Tb".*` returns PHYSICAL column names, so a recorder keyed only on the field name never
  # coerces a renamed column. Both keys are registered; the read loop only visits the one the row has.
  @testset "the wildcard branch records the db_column name too" begin
    for build! in (q -> nothing, q -> q.values("*"))
      kinds = _rvc_kinds(build!)
      @test kinds[:ts] == PormG.CDateTime(true)
      @test kinds[:moved] == PormG.CDateTime(true)      # the field name…
      @test kinds[:moved_at] == PormG.CDateTime(true)   # …and the physical one
      @test !haskey(kinds, :note)
    end
  end

  # An EXPLICIT wildcard beside a joined alias is the spelling PormG's own error message recommends
  # for a joined query. Recording only the empty-projection case left it returning a MIX — the joined
  # alias typed, every wildcard column raw — inside one row.
  @testset "an explicit wildcard beside a joined alias types both halves" begin
    kinds = _rvc_kinds(q -> q.values("*", "team__founded"))
    @test kinds[:ts] == PormG.CDateTime(true)
    @test kinds[:d] == PormG.CDate()
    @test kinds[:team__founded] == PormG.CDate()
  end

  # The wildcard recorder runs AFTER `get_select_query`, so it must never CLOBBER a kind an explicit
  # projection already recorded. It claims both a field's name and its `db_column`, while the
  # duplicate-name guard only reserves the star's PHYSICAL columns — so an alias equal to a renamed
  # field's NAME is legal, and a plain assignment would overwrite it with the wrong kind.
  #
  # Here `moved` is a `DateTimeField(db_column = "moved_at")` and the alias `moved` is bound to `d`,
  # a `DateField`. Before the `get!`, the star's `CDateTime` won and the SQLite read handed back a
  # `String` (the DATE text fails open through the timestamp parser) where the pre-#564 code gave a
  # `Date` — a silent type regression introduced by the wildcard branch itself.
  @testset "an explicit projection outranks the wildcard's model-derived kind" begin
    kinds = _rvc_kinds(q -> q.values("*", "moved" => "d"))
    @test kinds[:moved] == PormG.CDate()          # the alias's own column decides…
    @test kinds[:moved_at] == PormG.CDateTime(true)  # …and the physical name keeps the field's kind
    # Without the star, the same alias resolves the same way — which is the invariant that matters.
    @test _rvc_kinds(q -> q.values("moved" => "d"))[:moved] == PormG.CDate()
  end

  # An expression PormG cannot type records nothing, which is what keeps the fix fail-open: an
  # aggregate or a text-producing function is left exactly as the driver delivered it.
  @testset "an untypable projection records no kind" begin
    kinds = _rvc_kinds(q -> q.values("x" => PormG.Functions.Max("ts"),
                                     "y" => PormG.Functions.ToChar("ts", "YYYY-MM")))
    @test !haskey(kinds, :x)
    @test !haskey(kinds, :y)
  end
end
