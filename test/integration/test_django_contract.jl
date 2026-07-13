"""
Django Data-Type Contract Tests (Pure Julia — No Python/Django required)

This file validates that PormG is wire-format compatible with tables created by Django.
Instead of running Django, we create a PormG model (`Django_contract_scratch`) that
mirrors the column types Django generates, then verify round-trip behavior against
a real database.

Contracts verified here:
  - TIMESTAMPTZ: naive DateTime stored as UTC, ZonedDateTime preserves the instant (both backends)
  - auto_now_add: populated on INSERT, frozen on subsequent UPDATEs
  - auto_now: populated on INSERT and refreshed on every UPDATE
  - DateField truncation: DateTime inputs truncate to Date (same as Django — no error)
  - DecimalField precision: NUMERIC(10,2) round-trips without float drift

Run with:
  julia -t auto --project=. test/integration/runtests.jl
  \$env:PORMG_DB="db_sl"; julia -t 1 --project=. test/integration/runtests.jl
"""

if !isdefined(Main, :PormG)
    include("common_setup.jl")
end

using Dates
using TimeZones
using Decimals

# ─────────────────────────────────────────────────────────────────────────────
# Helpers
# ─────────────────────────────────────────────────────────────────────────────

"""Return the adapter type symbol for the current integration test backend."""
function _current_adapter()
    if !haskey(PormG.config, PORMG_DB_FOLDER)
        return :unknown
    end
    adapter_str = PormG.config[PORMG_DB_FOLDER].db_config_settings["adapter"]
    lowercase(adapter_str) == "sqlite" ? :sqlite : :postgresql
end

"""Cleanup a Django_contract_scratch row by label (idempotent)."""
function _cleanup_django_scratch!(label::String)
    q = M.Django_contract_scratch.objects
    q.filter("label" => label)
    q.exists() && q.delete()
    return nothing
end

"""
Normalize a datetime value read back from the database to a comparable UTC DateTime.

After the SQLite datetime normalization in `list()` (src/querybuilder/execution.jl), both
backends return `ZonedDateTime` for `DateTimeField` columns:
- PostgreSQL TIMESTAMPTZ → `ZonedDateTime` natively via LibPQ.
- SQLite DATETIME → `ZonedDateTime` after ORM normalization of the stored ISO 8601 string.

The String and DateTime branches are defensive fall-backs kept for edge cases
(e.g. values obtained outside `list()`, or pre-normalization paths).
"""
function _to_utc_datetime(raw)
    (raw === nothing || ismissing(raw)) && return nothing
    raw isa ZonedDateTime && return DateTime(astimezone(raw, TimeZone("UTC")))
    raw isa DateTime && return raw
    # Defensive fallback — should not be reached for DateTimeField columns returned by list().
    s = string(raw)
    try
        normalized = PormG.Models.normalize_sqlite_datetime_string(s)
        return DateTime(astimezone(ZonedDateTime(normalized, dateformat"yyyy-mm-ddTHH:MM:SS.ssszzzz"), TimeZone("UTC")))
    catch
        try
            return DateTime(astimezone(ZonedDateTime(s), TimeZone("UTC")))
        catch
            return DateTime(s[1:min(19, length(s))], dateformat"yyyy-mm-ddTHH:MM:SS")
        end
    end
end

"""Normalize a date value from DB to a Julia Date."""
function _normalize_date(raw)
    raw isa Date && return raw
    raw === nothing || ismissing(raw) && return nothing
    return Date(string(raw)[1:10])
end

"""Normalize a decimal/numeric value from DB to a Decimal."""
function _normalize_decimal(raw)
    raw === nothing || ismissing(raw) && return nothing
    raw isa Decimal && return raw
    return parse(Decimal, string(raw))
end

# ─────────────────────────────────────────────────────────────────────────────
# TIMESTAMPTZ Round-Trip (both backends)
#
# PostgreSQL uses a native TIMESTAMPTZ column — the DB engine normalises to UTC.
# SQLite stores the value as TEXT in canonical UTC (e.g. "2024-06-15T17:30:00.000+00:00", issue #79).
# PormG's read path (_parse_sqlite_datetime) reconstructs a ZonedDateTime from that string,
# and _to_utc_datetime converts both backends to a plain UTC DateTime for comparison.
# The semantic contract is therefore identical on both adapters.
# ─────────────────────────────────────────────────────────────────────────────
@testset "Django Contract: TIMESTAMPTZ Round-Trip" begin
    label_naive  = "django-tz-naive-roundtrip"
    label_aware  = "django-tz-aware-roundtrip"
    _cleanup_django_scratch!(label_naive)
    _cleanup_django_scratch!(label_aware)

    try
        # 1. Naive DateTime → treated as UTC by both backends
        naive_dt = DateTime(2024, 6, 15, 14, 30, 0)
        M.Django_contract_scratch.objects.create(
            "label"      => label_naive,
            "event_time" => naive_dt
        )
        row_naive = M.Django_contract_scratch.objects.filter(
            "label" => label_naive
        ).values("event_time").list() |> first

        stored_naive = _to_utc_datetime(row_naive[:event_time])
        @test stored_naive == naive_dt

        # 2. ZonedDateTime (America/Sao_Paulo = UTC-3) → stored preserving the UTC instant
        #    2024-06-15 14:30:00 BRT = 2024-06-15 17:30:00 UTC
        #    PostgreSQL normalises to UTC in the column; SQLite stores the offset string and
        #    the ORM normalises on read — both yield the same UTC instant.
        aware_dt  = ZonedDateTime(DateTime(2024, 6, 15, 14, 30, 0), TimeZone("America/Sao_Paulo"))
        expected_utc = DateTime(2024, 6, 15, 17, 30, 0)
        M.Django_contract_scratch.objects.create(
            "label"      => label_aware,
            "event_time" => aware_dt
        )
        row_aware = M.Django_contract_scratch.objects.filter(
            "label" => label_aware
        ).values("event_time").list() |> first

        stored_aware = _to_utc_datetime(row_aware[:event_time])
        @test stored_aware == expected_utc

        # 3. The two instants must differ (different originals → different UTC instants)
        @test stored_naive != stored_aware
    finally
        _cleanup_django_scratch!(label_naive)
        _cleanup_django_scratch!(label_aware)
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# TIMESTAMPTZ Bulk Operations
# This covers the production-sensitive path where DataFrame-backed ETL code sends
# DateTime/ZonedDateTime/missing values through bulk_insert and bulk_update.
# If bulk parameter formatting, adapter coercion, or nullable datetime handling
# regresses, this test should fail before the ETL layer does.
# ─────────────────────────────────────────────────────────────────────────────
@testset "Django Contract: TIMESTAMPTZ bulk_insert / bulk_update round-trip" begin
    labels = [
        "django-bulk-tz-naive",
        "django-bulk-tz-aware",
        "django-bulk-tz-missing",
    ]
    for label in labels
        _cleanup_django_scratch!(label)
    end

    try
        naive_insert = DateTime(2024, 6, 16, 9, 15, 0)
        aware_insert = ZonedDateTime(DateTime(2024, 6, 16, 9, 15, 0), TimeZone("America/Sao_Paulo"))
        expected_aware_insert_utc = DateTime(2024, 6, 16, 12, 15, 0)

        bulk_insert(
            M.Django_contract_scratch.objects,
            DataFrame(
                label = labels,
                event_time = Any[naive_insert, aware_insert, missing],
            ),
            columns = ["label", "event_time"],
        )

        inserted_rows = M.Django_contract_scratch.objects.filter(
            "label__@in" => labels,
        ).values("label", "event_time").list()
        inserted_by_label = Dict(row[:label] => row[:event_time] for row in inserted_rows)

        @test _to_utc_datetime(inserted_by_label[labels[1]]) == naive_insert
        @test _to_utc_datetime(inserted_by_label[labels[2]]) == expected_aware_insert_utc
        @test _to_utc_datetime(inserted_by_label[labels[3]]) === nothing

        id_rows = M.Django_contract_scratch.objects.filter(
            "label__@in" => labels,
        ).values("id", "label").list()
        ids_by_label = Dict(row[:label] => row[:id] for row in id_rows)

        aware_update = ZonedDateTime(DateTime(2024, 6, 17, 8, 0, 0), TimeZone("America/Sao_Paulo"))
        expected_aware_update_utc = DateTime(2024, 6, 17, 11, 0, 0)
        naive_update = DateTime(2024, 6, 17, 12, 30, 0)

        bulk_update(
            M.Django_contract_scratch.objects,
            DataFrame(
                id = [ids_by_label[labels[1]], ids_by_label[labels[2]], ids_by_label[labels[3]]],
                event_time = Any[aware_update, missing, naive_update],
            ),
            columns = ["event_time", "id"],
            match_on = ["id"],
        )

        updated_rows = M.Django_contract_scratch.objects.filter(
            "label__@in" => labels,
        ).values("label", "event_time").list()
        updated_by_label = Dict(row[:label] => row[:event_time] for row in updated_rows)

        @test _to_utc_datetime(updated_by_label[labels[1]]) == expected_aware_update_utc
        @test _to_utc_datetime(updated_by_label[labels[2]]) === nothing
        @test _to_utc_datetime(updated_by_label[labels[3]]) == naive_update
    finally
        for label in labels
            _cleanup_django_scratch!(label)
        end
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# auto_now_add: populated on INSERT, frozen on UPDATE
#   Django: DateTimeField(auto_now_add=True)
# ─────────────────────────────────────────────────────────────────────────────
@testset "Django Contract: auto_now_add — frozen after INSERT" begin
    label = "django-auto-now-add"
    _cleanup_django_scratch!(label)

    try
        before_insert = now(UTC)
        M.Django_contract_scratch.objects.create("label" => label)
        after_insert  = now(UTC)

        q = M.Django_contract_scratch.objects
        q.filter("label" => label)
        row = q.values("created_at").list() |> first

        created_at = _to_utc_datetime(row[:created_at])

        # Verify auto_now_add was populated and falls within the test window
        @test created_at !== nothing
        @test before_insert <= created_at <= after_insert

        # Now update a different field and verify created_at is NOT touched
        sleep(0.2)  # Ensure at least some time passes
        q.update("event_date" => Date(2024, 1, 1))

        row_after = q.values("created_at").list() |> first
        created_at_after = _to_utc_datetime(row_after[:created_at])

        @test created_at_after == created_at  # Must be frozen
    finally
        _cleanup_django_scratch!(label)
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# auto_now: populated on INSERT and refreshed on every UPDATE
#   Django: DateTimeField(auto_now=True)
# ─────────────────────────────────────────────────────────────────────────────
@testset "Django Contract: auto_now — refreshes on every UPDATE" begin
    label = "django-auto-now"
    _cleanup_django_scratch!(label)

    try
        M.Django_contract_scratch.objects.create("label" => label)

        q = M.Django_contract_scratch.objects
        q.filter("label" => label)
        row_insert = q.values("updated_at").list() |> first
        updated_at_insert = _to_utc_datetime(row_insert[:updated_at])
        @test updated_at_insert !== nothing

        # Wait, then update → updated_at must advance
        sleep(1.1)
        before_update = now(UTC)
        q.update("event_date" => Date(2024, 6, 1))
        after_update  = now(UTC)

        row_update = q.values("updated_at").list() |> first
        updated_at_after = _to_utc_datetime(row_update[:updated_at])

        @test updated_at_after !== nothing
        @test updated_at_after > updated_at_insert   # Must have advanced
        @test before_update <= updated_at_after <= after_update
    finally
        _cleanup_django_scratch!(label)
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# DateField Truncation Contract
#   Django: DateField — silently truncates DateTime to Date (no error)
# ─────────────────────────────────────────────────────────────────────────────
@testset "Django Contract: DateField truncation — DateTime becomes Date" begin
    label_date = "django-datefield-date"
    label_dt   = "django-datefield-datetime"
    _cleanup_django_scratch!(label_date)
    _cleanup_django_scratch!(label_dt)

    try
        # 1. Storing a plain Date — must read back the same Date
        plain_date = Date(2024, 7, 14)
        M.Django_contract_scratch.objects.create(
            "label"      => label_date,
            "event_date" => plain_date
        )
        row_date = M.Django_contract_scratch.objects.filter(
            "label" => label_date
        ).values("event_date").list() |> first
        @test _normalize_date(row_date[:event_date]) == plain_date

        # 2. Storing a DateTime — must truncate to the date portion without error
        dt_with_time = DateTime(2024, 7, 14, 22, 30, 45)  # time component must be dropped
        M.Django_contract_scratch.objects.create(
            "label"      => label_dt,
            "event_date" => dt_with_time
        )
        row_dt = M.Django_contract_scratch.objects.filter(
            "label" => label_dt
        ).values("event_date").list() |> first
        @test _normalize_date(row_dt[:event_date]) == Date(2024, 7, 14)  # truncated

        # 3. Verify the two rows have the same stored date
        @test _normalize_date(row_date[:event_date]) == _normalize_date(row_dt[:event_date])
    finally
        _cleanup_django_scratch!(label_date)
        _cleanup_django_scratch!(label_dt)
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# DecimalField Precision
#   Django: DecimalField(max_digits=10, decimal_places=2) → NUMERIC(10,2)
#   Key: no float drift — 99.99 must come back as exactly 99.99
# ─────────────────────────────────────────────────────────────────────────────
@testset "Django Contract: DecimalField precision — no float drift" begin
    label_a = "django-decimal-99"
    label_b = "django-decimal-pi"
    label_c = "django-decimal-neg"
    _cleanup_django_scratch!(label_a)
    _cleanup_django_scratch!(label_b)
    _cleanup_django_scratch!(label_c)

    try
        # 1. Typical price value — must come back exactly
        M.Django_contract_scratch.objects.create("label" => label_a, "price" => "99.99")
        row_a = M.Django_contract_scratch.objects.filter(
            "label" => label_a
        ).values("price").list() |> first
        price_a = _normalize_decimal(row_a[:price])
        @test price_a == parse(Decimal, "99.99")

        # 2. Truncated pi (3.14) — must not gain or lose precision in round-trip
        M.Django_contract_scratch.objects.create("label" => label_b, "price" => "3.14")
        row_b = M.Django_contract_scratch.objects.filter(
            "label" => label_b
        ).values("price").list() |> first
        price_b = _normalize_decimal(row_b[:price])
        @test price_b == parse(Decimal, "3.14")

        # 3. Negative value — sign must be preserved
        M.Django_contract_scratch.objects.create("label" => label_c, "price" => "-1234.56")
        row_c = M.Django_contract_scratch.objects.filter(
            "label" => label_c
        ).values("price").list() |> first
        price_c = _normalize_decimal(row_c[:price])
        @test price_c == parse(Decimal, "-1234.56")

        # 4. Update: value changes, precision is preserved
        q_upd = M.Django_contract_scratch.objects
        q_upd.filter("label" => label_a)
        q_upd.update("price" => "0.01")
        row_upd = q_upd.values("price").list() |> first
        @test _normalize_decimal(row_upd[:price]) == parse(Decimal, "0.01")
    finally
        _cleanup_django_scratch!(label_a)
        _cleanup_django_scratch!(label_b)
        _cleanup_django_scratch!(label_c)
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# #79 — DateTimeField equality/range filters agree across formats & offsets
#
# SQLite stores DateTimeField values as TEXT and compares them lexicographically, so two
# spellings of the SAME instant (`Z` vs `+00:00`, `.0`/`.000`, or a non-UTC offset like
# `-03:00` / `+05:30`) used to match on PostgreSQL but MISS on SQLite. PormG now
# canonicalizes every DateTimeField value to one UTC ISO-8601 form on BOTH the write/bind
# and the filter paths, so a plain TEXT comparison is correct and both backends agree.
#
# Three rows are stored at KNOWN, distinct UTC instants, each written through a DIFFERENT
# offset, then queried by spellings that differ from how each was stored. Pre-fix, the
# equality-across-spellings and cross-offset range assertions fail on SQLite (db_sl).
# ─────────────────────────────────────────────────────────────────────────────
@testset "Django Contract: #79 DateTimeField filters agree across formats/offsets" begin
    label_a = "django-79-utc10"   # 2020-01-01 10:00:00 UTC (stored as naive → UTC)
    label_b = "django-79-brt"     # 2020-01-01 13:00:00 UTC (stored as 10:00 -03:00)
    label_c = "django-79-ist"     # 2020-01-01 04:30:00 UTC (stored as 10:00 +05:30)
    labels  = [label_a, label_b, label_c]
    for l in labels; _cleanup_django_scratch!(l); end

    try
        # Store each instant through a different offset spelling.
        M.Django_contract_scratch.objects.create(
            "label" => label_a, "event_time" => DateTime(2020, 1, 1, 10, 0, 0))                      # naive → UTC 10:00
        M.Django_contract_scratch.objects.create(
            "label" => label_b,
            "event_time" => ZonedDateTime(DateTime(2020, 1, 1, 10, 0, 0), TimeZone("America/Sao_Paulo")))  # UTC 13:00
        M.Django_contract_scratch.objects.create(
            "label" => label_c,
            "event_time" => ZonedDateTime(DateTime(2020, 1, 1, 10, 0, 0), TimeZone("Asia/Kolkata")))       # UTC 04:30

        # --- Equality across spellings: every equivalent spelling of A's instant
        #     (2020-01-01 10:00:00 UTC) must match EXACTLY label_a on both backends.
        equal_spellings = Any[
            "2020-01-01T10:00:00Z",                                                    # Z, no sub-seconds
            "2020-01-01T10:00:00.000+00:00",                                           # explicit +00:00, .000
            "2020-01-01T10:00:00.0Z",                                                  # single sub-second digit
            "2020-01-01 10:00:00Z",                                                    # space separator
            ZonedDateTime(DateTime(2020, 1, 1, 7, 0, 0), TimeZone("America/Sao_Paulo")),  # 07:00 -03:00 = 10:00 UTC
        ]
        for spelling in equal_spellings
            q = M.Django_contract_scratch.objects
            q.filter("event_time" => spelling)
            q.filter("label__@in" => labels)
            rows = q.values("label").list()
            @test length(rows) == 1
            @test rows[1][:label] == label_a
        end

        # Cross-offset equality: C was stored as +05:30 (04:30 UTC); its UTC spelling finds it.
        qc = M.Django_contract_scratch.objects
        qc.filter("event_time" => "2020-01-01T04:30:00Z")
        qc.filter("label__@in" => labels)
        rows_c = qc.values("label").list()
        @test length(rows_c) == 1
        @test rows_c[1][:label] == label_c

        # --- Range / ordering (lexicographic == chronological only after canonicalization):
        #     UTC instants are C=04:30 < A=10:00 < B=13:00.
        qgte = M.Django_contract_scratch.objects
        qgte.filter("event_time__@gte" => "2020-01-01T10:00:00Z")
        qgte.filter("label__@in" => labels)
        got_gte = Set(r[:label] for r in qgte.values("label").list())
        @test got_gte == Set([label_a, label_b])           # 10:00 and 13:00

        qlt = M.Django_contract_scratch.objects
        qlt.filter("event_time__@lt" => "2020-01-01T10:00:00Z")
        qlt.filter("label__@in" => labels)
        got_lt = Set(r[:label] for r in qlt.values("label").list())
        @test got_lt == Set([label_c])                     # only 04:30

        # Range covering only the middle instant: (04:31 .. 12:00] UTC → {A} (10:00), not B/C.
        qrange = M.Django_contract_scratch.objects
        qrange.filter("event_time__@range" => ["2020-01-01T04:31:00Z", "2020-01-01T12:00:00+00:00"])
        qrange.filter("label__@in" => labels)
        got_range = Set(r[:label] for r in qrange.values("label").list())
        @test got_range == Set([label_a])
    finally
        for l in labels; _cleanup_django_scratch!(l); end
    end
end
