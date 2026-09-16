"""
Value representation property on the F1 fixture (#564, order item 1) — both engines.

The integration twin of `test/unit/test_value_repr_property.jl`. It runs the SAME case table
(`test/unit/helper_value_repr_cases.jl`) against real, seeded columns on whichever engine
`PORMG_DB` selects, so the property is measured on PostgreSQL as well as SQLite:

  - `Race.start_at`  — the fixture's only seeded TIMESTAMP column (#564 added it; derived from
                       `date` + `time` at seed time). Race 1 is the 2009 Australian Grand Prix,
                       `2009-03-29` at `06:00:00` UTC.
  - `Race.date`, `Race.time` — the DATE and TIME columns on the same row.
  - `Lap_times.time` — a seeded INTERVAL: lap 1 of race 1, driver 1, `1:49.088`.
  - `Django_contract_scratch.event_time` — one labelled row created and deleted here, carrying
                       MILLISECONDS, which the seeded race start does not. The canonical mask
                       spells `.sss`, so a probe at `.000` would let a renderer that drops or
                       doubles the fraction pass by coincidence.

Why the fixture column matters: until #564 the F1 schema had no TIMESTAMP column on any seeded
table, so every date-arithmetic test reached for `Race.date` — a DATE, the one case that was
already correct — and the integration suite steered around the broken case by accident.

The `broken` marks are MEASURED per engine (see the helper's header). This file asserts nothing
about SQL shape; the unit siblings do that.

Run (either engine; the SQLite pass needs `-t 1`):
  julia -t auto --project=test/integration test/integration/test_value_repr_property.jl
  PORMG_DB=db_sl julia -t 1 --project=test/integration test/integration/test_value_repr_property.jl
"""

if !isdefined(Main, :PormG)
    include("common_setup.jl")
end

include(joinpath(@__DIR__, "..", "unit", "helper_value_repr_cases.jl"))

const _VRI_ENGINE = PORMG_DB_FOLDER == "db_sl" ? :sqlite : :postgres

# Race 1 as the seed loader writes it: `start_at = DateTime(Date("2009-03-29"), Time("06:00:00"))`.
const _VRI_RACE_START = DateTime(2009, 3, 29, 6, 0, 0)
const _VRI_RACE_DATE  = Date(2009, 3, 29)
const _VRI_RACE_TIME  = Time(6, 0, 0)

_vri_race() = M.Race.objects.filter("raceid" => 1)
_vri_lap()  = M.Lap_times.objects.filter("raceid" => 1, "driverid" => 1, "lap" => 1)

@testset "Value representation property on the F1 fixture (#564)" begin

  # ───────────────────────────────────────────────────────────────────────────
  # Fixture: the seeded TIMESTAMP column holds what the loader derived, and stays NULL exactly
  # where the CSV has no start time. Asserted through the formatter, not a spelling: on SQLite
  # a plain-column alias is coerced to `ZonedDateTime` on the way out, on PostgreSQL the driver
  # delivers one, and both must denote the same instant as the loader's `DateTime`.
  # ───────────────────────────────────────────────────────────────────────────
  @testset "Race.start_at is seeded from date + time" begin
    got = _vri_race().values("start_at").list(:dict)[1][:start_at]
    @test vr_observed_text(:timestamp, got) == Models.format_timezone_sql(_VRI_RACE_START)
    without_time = M.Race.objects.filter("time__@isnull" => true).count()
    without_start = M.Race.objects.filter("start_at__@isnull" => true).count()
    @test without_start == without_time
    # `races.csv`: 1125 rows, 731 without a published time → 394 derived starts.
    @test M.Race.objects.count() - without_start == 394
  end

  # ───────────────────────────────────────────────────────────────────────────
  # The property, per seeded column kind. Every case evaluates on the live engine; P1 compares
  # the projected value to the column's own formatter, P2 binds it back, P3 checks the type.
  # ───────────────────────────────────────────────────────────────────────────
  @testset "TIMESTAMP — Race.start_at" begin
    vr_run_cases(_vri_race, "start_at", _VRI_RACE_START, _VRI_ENGINE; kind = :timestamp)
  end

  @testset "DATE — Race.date" begin
    vr_run_cases(_vri_race, "date", _VRI_RACE_DATE, _VRI_ENGINE; kind = :date)
  end

  @testset "TIME — Race.time" begin
    vr_run_cases(_vri_race, "time", _VRI_RACE_TIME, _VRI_ENGINE; kind = :time)
  end

  @testset "INTERVAL — Lap_times.time" begin
    vr_run_cases(_vri_lap, "time", VR_DURATION, _VRI_ENGINE; kind = :interval)
  end

  # ───────────────────────────────────────────────────────────────────────────
  # Milliseconds: the seeded race start is a whole second, so the `.sss` half of the canonical
  # mask is exercised on a scratch row instead. Its own row, created and deleted here, for the
  # reason `test_field_expressions.jl` states — the scratch tables are truncated by other tests.
  # ───────────────────────────────────────────────────────────────────────────
  @testset "TIMESTAMP with milliseconds — Django_contract_scratch.event_time" begin
    label = "vr564_ms_probe"
    cleanup = M.Django_contract_scratch.objects
    cleanup.filter("label" => label)
    cleanup.exists() && cleanup.delete()
    base() = M.Django_contract_scratch.objects.filter("label" => label)
    try
      M.Django_contract_scratch.objects.create("label" => label, "event_time" => VR_INSTANT)
      vr_run_cases(base, "event_time", VR_INSTANT, _VRI_ENGINE; kind = :timestamp)
      # #569: every portable `ToChar` format, measured on THIS engine against the `Dates.format`
      # oracle. On PostgreSQL this is the only place the `postgres` half of `date_format_map` is
      # ever evaluated — the unit twin has no PostgreSQL. The millisecond probe is deliberate: a
      # `SS` where `MS` was meant would pass on a whole-second instant.
      @testset "every ToChar format renders the oracle text (#569)" begin
        vr_run_tochar_formats(base, "event_time", VR_INSTANT, _VRI_ENGINE)
      end
    finally
      M.Django_contract_scratch.objects.filter("label" => label).delete()
    end
  end

  # ───────────────────────────────────────────────────────────────────────────
  # #562: the two `__@` ladders project the same value for every transform — measured on the
  # seeded TIMESTAMP, on both engines.
  # ───────────────────────────────────────────────────────────────────────────
  @testset "transform ladder parity (#562)" begin
    vr_run_ladder_parity(_vri_race, "start_at", _VRI_RACE_START, _VRI_ENGINE)
  end

  # ───────────────────────────────────────────────────────────────────────────
  # #564 sibling 4: a JOINED temporal alias. The widest behaviour change in the fix and the one the
  # shared case table cannot reach — every case there projects a column of the query's OWN model.
  #
  # The gate this removes dropped every alias whose path contained `__`, so `values("d" =>
  # "raceid__date")` came back as text on SQLite while the identical column read directly came back
  # as a `Date`. It is also the shape that catches an implementation typing the projection BEFORE it
  # renders: a dotted path's kind is resolvable only after the join has been resolved.
  # ───────────────────────────────────────────────────────────────────────────
  @testset "a joined temporal alias reads back typed (#564)" begin
    q = M.Result.objects
    q.filter("raceid" => 1)
    q.values("d" => "raceid__date", "ts" => "raceid__start_at")
    row = q.list(:dict)[1]
    @test row[:d] isa Date
    @test row[:d] == _VRI_RACE_DATE
    # The joined TIMESTAMP too — same gate, and the kind has to survive the join resolution.
    @test row[:ts] isa Union{DateTime, TimeZones.ZonedDateTime}
    # The direct and the joined spelling of ONE column must now agree in type. That equality is the
    # whole point: before, which spelling you used decided what Julia type you got back.
    direct = M.Race.objects
    direct.filter("raceid" => 1)
    direct.values("d" => F("date"))
    @test typeof(direct.list(:dict)[1][:d]) == typeof(row[:d])
  end

  # ───────────────────────────────────────────────────────────────────────────
  # The coerced values must still be values the WRITE path accepts. A parser that produced something
  # the matching formatter rejects would turn every read-modify-write into a runtime error, and no
  # assertion about types alone would catch it.
  # ───────────────────────────────────────────────────────────────────────────
  @testset "a coerced value round-trips back through the write path (#564)" begin
    label = "vr564_roundtrip"
    cleanup = M.Django_contract_scratch.objects
    cleanup.filter("label" => label)
    cleanup.exists() && cleanup.delete()
    try
      M.Django_contract_scratch.objects.create("label" => label, "event_time" => VR_INSTANT)
      read_back = M.Django_contract_scratch.objects.filter("label" => label).
                    values("event_time").list(:dict)[1][:event_time]
      # Write the value we just read straight back, unmodified, and read it again.
      M.Django_contract_scratch.objects.filter("label" => label).update("event_time" => read_back)
      again = M.Django_contract_scratch.objects.filter("label" => label).
                values("event_time").list(:dict)[1][:event_time]
      @test vr_observed_text(:timestamp, again) == vr_observed_text(:timestamp, read_back)
    finally
      M.Django_contract_scratch.objects.filter("label" => label).delete()
    end
  end
end
