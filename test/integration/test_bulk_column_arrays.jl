if !isdefined(Main, :PormG)
    include("common_setup.jl")
end
# The foreign-key testset seeds through the shared bulk scratch helpers; runtests.jl includes them
# at top level, so load them only when this file runs on its own.
if !isdefined(Main, :_seed_bulk_update_scratch_parents!)
    include("common_bulk_scratch_setup.jl")
end

# A PostgreSQL TIMESTAMPTZ comes back as a ZonedDateTime; common_setup.jl does not load TimeZones.
using TimeZones

# ─────────────────────────────────────────────────────────────────────────────
# Bulk writes store exactly what a per-cell write stores (#672)
#
# On PostgreSQL `bulk_insert` and `bulk_update` bind ONE array per column and expand it with
# `unnest($n::<type>[])`; `create()` and `update()` still bind one parameter per value, and SQLite
# binds every bulk cell on its own. A value therefore reaches PostgreSQL by two different wire
# forms — an element of an array literal, or a scalar parameter — and this file checks that they
# store the same thing, for every value shape a bulk writer formats differently: text carrying
# array-literal metacharacters (`"` `\` `,` `{}`, the text "NULL"), JSON, bytes
# with an embedded NUL, UUID, decimal, timestamptz with a non-UTC zone, date, time, interval, and
# NULL in every nullable column.
#
# The oracle is a twin row written through `create()` / `update()` with the same values, read
# back the same way — so the assertion is "bulk == per-cell", which holds on BOTH engines and
# does not depend on how each engine hands a type back. A few absolute checks pin the values
# themselves, so both paths drifting together would still fail.
#
# It holds for columns whose type is the one their field declares — every table here. A column
# adopted with a different real type is the documented exception (docs/src/write/bulk.md →
# "PostgreSQL: the column must have its field's type"): its array cast cannot reach that type.
#
# Every row this file writes is its own (scratch slugs/labels, or `Race`/`Qualifying` rows it
# creates) and is removed in `finally`. No explicit primary key is bulk-inserted, so no sequence
# is advanced past what an ordinary insert would.
# ─────────────────────────────────────────────────────────────────────────────

# One row's `cols`, read back through the ORM, as a plain Vector in `cols` order.
_ca672_read(q, cols) = begin
    rows = q.values(cols...).list()
    @assert length(rows) == 1 "expected exactly one row, got $(length(rows))"
    Any[only(rows)[Symbol(c)] for c in cols]
end

# Text that would split, truncate or be mistaken for NULL inside an unquoted array element.
const _CA672_AWKWARD = "O\"Brien, {Jr} \\ \"NULL\""

# ─────────────────────────────────────────────────────────────────────────────
# JSON, bytes and UUID through bulk_insert, the on_conflict upsert, and bulk_update.
# `Field_validation_scratch` carries jsonb, two bytea columns and a uuid. The JSON text holds
# quotes, backslashes, braces and a nested array; the bytes hold NUL, `"`, `,`, `\`, `{`, `}` and
# 0xFF — every byte the array literal would have to escape if it travelled raw.
# ─────────────────────────────────────────────────────────────────────────────
@testset "bulk column arrays: JSON, bytes and UUID store what create() stores (#672)" begin
    scratch = () -> M.Field_validation_scratch.objects
    slugs = ["ca672-bulk-1", "ca672-bulk-2", "ca672-twin-1", "ca672-twin-2"]
    purge = () -> begin
        q = scratch()
        q.filter("slug__@in" => slugs)
        q.exists() && q.delete()
    end
    purge()

    payload  = Dict{String, Any}("driver" => _CA672_AWKWARD, "laps" => [1, 2, 3],
                                 "circuit" => "São Paulo — Interlagos", "wet" => true)
    payload2 = Dict{String, Any}("driver" => "Verstappen", "note" => "a\\b\"c{d}")
    blob     = UInt8[0x00, 0x22, 0x2c, 0x5c, 0x7b, 0x7d, 0xff]
    blob2    = UInt8[0xff, 0x00, 0x5c]
    cols     = ["canonical_url", "payload", "blob_payload", "bounded_blob"]

    # Row 1 carries every awkward value; row 2 is NULL in every nullable column.
    frame = DataFrames.DataFrame(
        uuid_token    = ["ca672000-0000-4000-8000-000000000001", "ca672000-0000-4000-8000-000000000002"],
        canonical_url = ["https://www.formula1.com/en/results/2021/races,1073?a={b}", "NULL"],
        slug          = slugs[1:2],
        payload       = Union{Dict{String, Any}, Missing}[payload, missing],
        blob_payload  = Union{Vector{UInt8}, Missing}[blob, missing],
        bounded_blob  = Union{Vector{UInt8}, Missing}[UInt8[0x00, 0x01], missing],
    )

    try
        # ── bulk_insert vs create() ───────────────────────────────────────────
        bulk_insert(scratch(), frame)
        for (i, twin) in enumerate(slugs[3:4])
            scratch().create(
                "uuid_token"    => "ca672000-0000-4000-8000-00000000000$(i + 2)",
                "canonical_url" => frame.canonical_url[i],
                "slug"          => twin,
                "payload"       => frame.payload[i],
                "blob_payload"  => frame.blob_payload[i],
                "bounded_blob"  => frame.bounded_blob[i],
            )
        end
        for i in 1:2
            bulk = _ca672_read(scratch().filter("slug" => slugs[i]), cols)
            twin = _ca672_read(scratch().filter("slug" => slugs[i + 2]), cols)
            @test isequal(bulk, twin)
        end
        # Absolute: the bytes are byte-exact and the JSON parses back to what was sent.
        row1 = _ca672_read(scratch().filter("slug" => slugs[1]), cols)
        @test collect(row1[3]) == blob
        @test JSON.parse(row1[2] isa AbstractString ? row1[2] : JSON.json(row1[2])) == payload
        row2 = _ca672_read(scratch().filter("slug" => slugs[2]), cols)
        @test row2[1] == "NULL"                  # the TEXT "NULL", not SQL NULL
        @test all(ismissing, row2[2:4])

        # ── on_conflict upsert vs update() ────────────────────────────────────
        # The insert COPY cannot express: every row conflicts on `slug` and is rewritten.
        upsert = DataFrames.DataFrame(
            uuid_token    = frame.uuid_token,
            canonical_url = frame.canonical_url,
            slug          = slugs[1:2],
            payload       = Union{Dict{String, Any}, Missing}[payload2, payload2],
        )
        res = bulk_insert(scratch(), upsert,
            on_conflict = (action = :update, target = ["slug"], set = ["payload"]))
        @test res.count == 2
        for twin in slugs[3:4]
            q = scratch(); q.filter("slug" => twin); q.update("payload" => payload2)
        end
        for i in 1:2
            @test isequal(_ca672_read(scratch().filter("slug" => slugs[i]), ["payload"]),
                          _ca672_read(scratch().filter("slug" => slugs[i + 2]), ["payload"]))
        end

        # ── bulk_update vs update() ───────────────────────────────────────────
        # Swap the NULLs and the values between the two rows, so a no-op update cannot pass.
        changes = DataFrames.DataFrame(
            slug         = slugs[1:2],
            payload      = Union{Dict{String, Any}, Missing}[missing, payload],
            blob_payload = Union{Vector{UInt8}, Missing}[missing, blob2],
        )
        res = bulk_update(scratch(), changes, columns = ["payload", "blob_payload", "slug"], match_on = ["slug"])
        @test res.count == 2
        for i in 1:2
            q = scratch(); q.filter("slug" => slugs[i + 2])
            q.update("payload" => changes.payload[i], "blob_payload" => changes.blob_payload[i])
        end
        for i in 1:2
            @test isequal(_ca672_read(scratch().filter("slug" => slugs[i]), cols),
                          _ca672_read(scratch().filter("slug" => slugs[i + 2]), cols))
        end
        @test collect(_ca672_read(scratch().filter("slug" => slugs[2]), ["blob_payload"])[1]) == blob2
    finally
        purge()
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# Awkward text, timestamptz, date and decimal through bulk_insert and bulk_update.
# `Django_contract_scratch` is the Django-shaped table: varchar, a timestamptz written from a
# non-UTC ZonedDateTime and from a naive DateTime, a date and a NUMERIC(10,2). The label itself
# carries the array-literal metacharacters.
# ─────────────────────────────────────────────────────────────────────────────
@testset "bulk column arrays: text, timestamps and decimals store what create() stores (#672)" begin
    scratch = () -> M.Django_contract_scratch.objects
    labels = ["ca672 bulk " * _CA672_AWKWARD, "ca672 bulk 2", "ca672 twin " * _CA672_AWKWARD, "ca672 twin 2"]
    purge = () -> begin
        q = scratch()
        q.filter("label__@in" => labels)
        q.exists() && q.delete()
    end
    purge()

    cols = ["event_time", "event_date", "price"]
    frame = DataFrames.DataFrame(
        label      = labels[1:2],
        event_time = Union{ZonedDateTime, DateTime, Missing}[ZonedDateTime(2021, 12, 12, 17, 0, tz"Asia/Dubai"), missing],
        event_date = Union{Date, Missing}[Date(2021, 12, 12), missing],
        price      = Union{String, Missing}["1234.56", missing],
    )

    try
        bulk_insert(scratch(), frame, columns = ["label", "event_time", "event_date", "price"])
        for i in 1:2
            scratch().create("label" => labels[i + 2], "event_time" => frame.event_time[i],
                             "event_date" => frame.event_date[i], "price" => frame.price[i])
        end
        for i in 1:2
            @test isequal(_ca672_read(scratch().filter("label" => labels[i]), cols),
                          _ca672_read(scratch().filter("label" => labels[i + 2]), cols))
        end
        # Absolute: the metacharacter-laden label came back verbatim.
        @test scratch().filter("label" => labels[1]).count() == 1

        # bulk_update across a naive DateTime, a new decimal and a date, matched on the label.
        changes = DataFrames.DataFrame(
            label      = labels[1:2],
            event_time = Union{ZonedDateTime, DateTime, Missing}[missing, DateTime(2022, 11, 20, 13, 0)],
            event_date = Union{Date, Missing}[missing, Date(2022, 11, 20)],
            price      = Union{String, Missing}["-0.10", "99999999.99"],
        )
        res = bulk_update(scratch(), changes, columns = ["label", "event_time", "event_date", "price"],
                          match_on = ["label"])
        @test res.count == 2
        for i in 1:2
            q = scratch(); q.filter("label" => labels[i + 2])
            q.update("event_time" => changes.event_time[i], "event_date" => changes.event_date[i],
                     "price" => changes.price[i])
        end
        for i in 1:2
            @test isequal(_ca672_read(scratch().filter("label" => labels[i]), cols),
                          _ca672_read(scratch().filter("label" => labels[i + 2]), cols))
        end
    finally
        purge()
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# Time and interval columns through bulk_insert and bulk_update.
# No scratch table carries them, so this creates its own races (TimeField `time`/`fp1_time`) on a
# borrowed circuit, plus qualifying rows (DurationField `q1`…`q3`) on the first of them, and
# deletes all of it afterwards. Fractional seconds are included: they are where a time or
# interval literal is easiest to truncate.
# ─────────────────────────────────────────────────────────────────────────────
@testset "bulk column arrays: time and interval store what create() stores (#672)" begin
    race_names = ["ca672 bulk GP 1", "ca672 bulk GP 2", "ca672 twin GP 1", "ca672 twin GP 2"]
    purge = () -> begin
        races = M.Race.objects
        races.filter("name__@in" => race_names)
        ids = [r[:raceid] for r in races.values("raceid").list()]
        if !isempty(ids)
            q = M.Qualifying.objects; q.filter("raceid__@in" => ids)
            q.exists() && q.delete()
            races.delete()
        end
    end
    purge()

    circuit = (M.Circuit.objects.values("circuitid").order_by("circuitid").list() |> first)[:circuitid]
    borrowed = M.Qualifying.objects.values("driverid", "constructorid").order_by("qualifyingid").list() |> first

    race_cols = ["time", "fp1_time", "date"]
    frame = DataFrames.DataFrame(
        year      = [2099, 2099],
        round     = [91, 92],
        circuitid = [circuit, circuit],
        name      = race_names[1:2],
        date      = [Date(2099, 3, 1), Date(2099, 3, 8)],
        time      = Union{Time, Missing}[Time(14, 5, 3, 250), missing],
        fp1_time  = Union{Time, Missing}[Time(0, 0, 0), missing],
        url       = ["https://example.com/ca672/1", "https://example.com/ca672/2"],
    )

    try
        # ── races: bulk_insert vs create() ────────────────────────────────────
        bulk_insert(M.Race.objects, frame)
        for i in 1:2
            M.Race.objects.create("year" => 2099, "round" => 92 + i, "circuitid" => circuit,
                "name" => race_names[i + 2], "date" => frame.date[i], "time" => frame.time[i],
                "fp1_time" => frame.fp1_time[i], "url" => frame.url[i])
        end
        race_q(name) = (q = M.Race.objects; q.filter("name" => name); q)
        for i in 1:2
            @test isequal(_ca672_read(race_q(race_names[i]), race_cols), _ca672_read(race_q(race_names[i + 2]), race_cols))
        end

        # ── races: bulk_update vs update() ────────────────────────────────────
        changes = DataFrames.DataFrame(name = race_names[1:2],
            time = Union{Time, Missing}[missing, Time(23, 59, 59, 999)])
        @test bulk_update(M.Race.objects, changes, columns = ["name", "time"], match_on = ["name"]).count == 2
        for i in 1:2
            race_q(race_names[i + 2]).update("time" => changes.time[i])
        end
        for i in 1:2
            @test isequal(_ca672_read(race_q(race_names[i]), race_cols), _ca672_read(race_q(race_names[i + 2]), race_cols))
        end

        # ── qualifying intervals: bulk_insert vs create(), then bulk_update ───
        bulk_race = (race_q(race_names[1]).values("raceid").list() |> first)[:raceid]
        twin_race = (race_q(race_names[3]).values("raceid").list() |> first)[:raceid]
        q_cols = ["q1", "q2", "q3"]
        laps = DataFrames.DataFrame(
            raceid        = [bulk_race],
            driverid      = [borrowed[:driverid]],
            constructorid = [borrowed[:constructorid]],
            number        = [1],
            q1            = Union{Millisecond, Missing}[Millisecond(83_456)],
            q2            = Union{Millisecond, Missing}[missing],
            q3            = Union{Millisecond, Missing}[Millisecond(3_600_001)],
        )
        bulk_insert(M.Qualifying.objects, laps)
        M.Qualifying.objects.create("raceid" => twin_race, "driverid" => borrowed[:driverid],
            "constructorid" => borrowed[:constructorid], "number" => 1,
            "q1" => Millisecond(83_456), "q2" => missing, "q3" => Millisecond(3_600_001))
        quali_q(race) = (q = M.Qualifying.objects; q.filter("raceid" => race); q)
        @test isequal(_ca672_read(quali_q(bulk_race), q_cols), _ca672_read(quali_q(twin_race), q_cols))

        bulk_id = (quali_q(bulk_race).values("qualifyingid").list() |> first)[:qualifyingid]
        @test bulk_update(M.Qualifying.objects,
            DataFrames.DataFrame(qualifyingid = [bulk_id], q2 = [Millisecond(81_002)]),
            columns = ["q2"], match_on = ["qualifyingid"]).count == 1
        quali_q(twin_race).update("q2" => Millisecond(81_002))
        @test isequal(_ca672_read(quali_q(bulk_race), q_cols), _ca672_read(quali_q(twin_race), q_cols))
    finally
        purge()
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# A database-side failure raises the same error type through the arrays.
# A foreign key to a parent that does not exist passes every Julia-side check and is rejected by
# the server. Whether the bad value arrived as a scalar or as an array element, it is the same
# constraint violation (SQLSTATE 23503), so it must surface as the same `IntegrityError` — and
# the one-transaction wrap must leave nothing of the batch behind.
# ─────────────────────────────────────────────────────────────────────────────
@testset "bulk column arrays: a foreign-key violation raises IntegrityError (#672)" begin
    _clear_bulk_update_scratch_rows!()
    try
        required_ids, _ = _seed_bulk_update_scratch_parents!(["req-672-fk"], String[])
        good = required_ids["req-672-fk"]
        frame = DataFrames.DataFrame(label = ["ca672 fk ok", "ca672 fk dangling"],
                                     required_parent_id = [good, good + 1_000_000])
        err = try
            # chunk_size = 1: the valid row is flushed as its own statement BEFORE the dangling
            # one fails, so only the call's transaction can take it back.
            bulk_insert(M.Bulk_update_payload_scratch.objects, frame, chunk_size = 1)
            nothing
        catch e
            e
        end
        @test err isa PormG.IntegrityError
        @test M.Bulk_update_payload_scratch.objects.count() == 0   # the valid row rolled back too
    finally
        _clear_bulk_update_scratch_rows!()
    end
end
