if !isdefined(Main, :PormG)
    include("common_setup.jl")
end

import TimeZones: ZonedDateTime

# ─────────────────────────────────────────────────────────────────────────────
# PormGRow: list format selection and row access
# Verifies that list() now returns model-aware rows by default while dict/json
# output remains available through the explicit list(format) API.
# ─────────────────────────────────────────────────────────────────────────────
@testset "PormGRow list formats" begin
    row_query = M.Driver.objects.filter("driverref" => "hamilton")
    rows = row_query.list()

    @test rows isa Vector{PormGRow}
    @test length(rows) == 1

    row = rows[1]
    # Field access is case-sensitive (#57): the field is declared `driverid`, so the
    # lowercase name resolves and the camelCase form misses (no silent normalization).
    @test row.driverid == row[:driverid]
    @test row.driverid == row["driverid"]
    @test haskey(row, :driverid)
    @test !haskey(row, :driverId)
    @test_throws PormG.UnknownFieldError row.driverId   # camelCase misses → no field/accessor
    @test_throws KeyError row[:driverId]      # raw getindex → KeyError
    @test get(row, "missingField", :fallback) === :fallback

    dict_rows = M.Driver.objects.filter("driverref" => "hamilton").list(:dict)
    @test dict_rows isa Vector
    @test dict_rows[1] isa Dict
    @test !(dict_rows[1] isa PormGRow)
    @test dict_rows[1][:driverid] == row.driverid

    json_rows = M.Driver.objects.filter("driverref" => "hamilton").values("driverid", "driverref").list(:json)
    @test json_rows isa String
    parsed = JSON.parse(json_rows)
    @test parsed[1]["driverid"] == row.driverid
    @test parsed[1]["driverref"] == "hamilton"

    @test_throws PormG.QueryBuildError M.Driver.objects.filter("driverref" => "hamilton").list(:typo)
end

# ─────────────────────────────────────────────────────────────────────────────
# PormGRow: JSON.json(row) serializes the ROW, and agrees with list(:json) (#641)
# A PormGRow has no JSON method of its own, so JSON.jl reflected over its slots, walked into
# `_model` and re-serialized the model graph along every path through it — 1.8 MB from one row on
# the 14-model F1 fixture, and an OOM-kill on a production schema. `src/querybuilder/execution.jl`
# now defines `StructUtils.lower` for it, routed through the SAME `_json_row` that builds
# `list(:json)`, so the two emitters cannot disagree about one row. That agreement is the assertion
# here: a real query, real driver-delivered values, both paths, one string.
#
# Guarded on the method's presence for the same reason the unit file is: on unpatched code the
# serialization is an allocation storm, and a `Task` with a timeout cannot stop it — a Julia task
# cannot be killed.
# ─────────────────────────────────────────────────────────────────────────────
@testset "JSON.json(row) agrees with list(:json) (#641)" begin
    _su = PormG.QueryBuilder.JSON.StructUtils
    # `methods(...)` rather than `which(...)` — the latter throws on an ambiguity instead of
    # answering, which would turn this guard into an error rather than a failure.
    has_lower = any(m -> m.module === PormG.QueryBuilder, methods(_su.lower, Tuple{Any, PormGRow}))
    @test has_lower

    if has_lower
        q = M.Driver.objects.filter("nationality" => "Brazilian").
            values("driverid", "driverref", "surname").
            order_by("driverid")

        rows = q.list()
        # The exact count, not `!isempty`: the F1 fixture holds 32 Brazilian drivers on both
        # engines, and a slice run against a half-seeded database is a real failure mode here. One
        # row standing in for thirty-two would hide it.
        @test length(rows) == 32

        # Both emitters build a plain `Dict{String,Any}` from the same keys via `_json_row`, so the
        # rendered strings are identical — not merely equivalent documents. Asserted as strings
        # first, because that is the stronger claim; the parse below says what went wrong when it
        # ever stops holding.
        @test JSON.json(rows) == q.list(:json)
        @test JSON.parse(JSON.json(rows)) == JSON.parse(q.list(:json))

        # A single row lowers to its own columns and nothing else — no model, no schema vocabulary.
        one = JSON.parse(JSON.json(rows[1]))
        @test Set(keys(one)) == Set(["driverid", "driverref", "surname"])
        @test one["driverid"] == rows[1].driverid
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# DecimalField: list(:json) emits the exact digits, as a NUMBER, on both engines (#644)
# `Decimals.Decimal <: AbstractFloat`, so JSON.jl never struct-reflected it — it routed the value
# through a `Float64`, which loses digits past ~16 significant figures and reshapes everything else
# (an integral `14` became `14.0`, and `0.000001` became `1.0e-6`). `_json_value` now hands JSON the
# digits `sDecimalField`'s own formatter writes, spliced as a raw JSON number.
#
# What only a LIVE run can say, and the reason this testset exists next to the unit one: that the
# value the DRIVER delivers reaches that arm. The engines do not agree on the Julia type at all —
# PostgreSQL/LibPQ hands back a `Decimals.Decimal` for every value, while SQLite's NUMERIC affinity
# hands back an `Int64` for an integral one and a `Float64` for a fractional one — so three distinct
# types reach `_json_value` for one declared column, and the JSON has to come out the same anyway.
# That equivalence is the assertion; it is also what the `JSONText` shape was chosen for, since a
# string arm would have made PostgreSQL emit `"14"` where SQLite emitted `14`.
#
# The fixture cannot show the DRIFT half: `Constructor_results.points` is `DecimalField(10, 2)`, and
# every width up to ~16 digits was already correct. `test/unit/test_read_value_coercion.jl` owns that
# dimension, with the long values the unpatched code got wrong.
# ─────────────────────────────────────────────────────────────────────────────
@testset "a DecimalField serializes as an exact JSON number (#644)" begin
    q = M.Constructor_results.objects
    q.filter("points__@gte" => 1)
    q.values("constructorresultsid", "points")
    q.order_by("constructorresultsid")
    q.limit(5)

    rows = q.list()
    @test length(rows) == 5

    # The engine-specific half, asserted rather than assumed — if a driver ever starts handing back
    # something else, the JSON assertions below would still pass while testing nothing about Decimal.
    if PORMG_DB_FOLDER == "db_2"
        @test all(r -> r[:points] isa PormG.QueryBuilder.Decimals.Decimal, rows)
    end

    parsed = JSON.parse(q.list(:json))

    # A NUMBER, never a string. This is the cross-engine contract the shape decision bought.
    @test all(row -> row["points"] isa Number, parsed)

    # And an integral DecimalField is `14`, not `14.0`. The fixture's points are whole numbers, which
    # makes this the one assertion here that fails on unpatched PostgreSQL — the `Float64` round-trip
    # rendered every one of them with a trailing `.0`.
    @test !occursin(".0", q.list(:json))
    @test [row["points"] for row in parsed] == [14, 8, 9, 5, 2]

    # The #641 cross-emitter agreement has to survive a raw-spliced column too: `JSONText` bypasses
    # the writer's escaping, so if it ever rendered differently in the two code paths the documented
    # `JSON.json(query.list()) == query.list(:json)` contract would break here first.
    @test JSON.json(rows) == q.list(:json)
end

# ─────────────────────────────────────────────────────────────────────────────
# PormGRow: single-row fetch helpers and DataFrames compatibility
# Verifies first()/get() row returns, typed get() failures, and the Tables.jl
# row-table interface used by DataFrame(query.list()).
# ─────────────────────────────────────────────────────────────────────────────
@testset "PormGRow first/get and DataFrame compatibility" begin
    driver = M.Driver.objects.get("driverref" => "hamilton")
    @test driver isa PormGRow
    @test driver.surname == "Hamilton"

    first_driver = M.Driver.objects.filter("driverref" => "hamilton").first()
    @test first_driver isa PormGRow
    @test first_driver.driverid == driver.driverid

    @test_throws DoesNotExist M.Driver.objects.get("driverref" => "pormg_missing_driver")
    @test_throws MultipleObjectsReturned M.Driver.objects.get("nationality" => "British")

    row_result = M.Driver.objects.filter("driverref" => "hamilton").list()
    df_from_rows = DataFrame(row_result)
    df_direct = M.Driver.objects.filter("driverref" => "hamilton") |> DataFrame

    @test nrow(df_from_rows) == 1
    @test nrow(df_direct) == 1
    @test df_from_rows[1, :driverid] == df_direct[1, :driverid]

    # #582: the two paths also agree on TEMPORAL columns. `query |> DataFrame` used to bypass the
    # #564 read-side coercion, so on SQLite `date`/`time`/`start_at` arrived as text there while
    # `list()` gave `Date`/`Time`/`ZonedDateTime`. Race 1 (2009 Australian GP) has all three seeded.
    race_q = M.Race.objects.filter("raceid" => 1)
    race_q.values("date", "time", "start_at")
    race_df   = race_q |> DataFrame
    race_dict = race_q.list(:dict)[1]
    @test nrow(race_df) == 1
    @test race_df[1, :date] isa Date
    @test race_df[1, :time] isa Time
    @test race_df[1, :start_at] isa ZonedDateTime
    for col in (:date, :time, :start_at)
        @test typeof(race_df[1, col]) == typeof(race_dict[col])
    end

    # Tables.getcolumn is case-sensitive (#57): the exact declared symbol resolves; a
    # wrong-case symbol misses (the old case-insensitive normalization is incompatible
    # with case preservation and was removed).
    row_item = row_result[1]
    @test Tables.getcolumn(row_item, :driverid) == row_item.driverid
    @test_throws KeyError Tables.getcolumn(row_item, :driverId)
end

# ─────────────────────────────────────────────────────────────────────────────
# PormGRow: relationship access and lazy-FK refusal
# Verifies that row-level many-to-many accessors produce managers while missing
# FK projections fail loudly instead of implying hidden lazy traversal.
# ─────────────────────────────────────────────────────────────────────────────
@testset "PormGRow relationship access" begin
    M.M2m_driver_endorsement_scratch.objects.delete(allow_delete_all=true)
    M.M2m_sponsor_scratch.objects.delete(allow_delete_all=true)

    try
        sponsor = M.M2m_sponsor_scratch.objects.create("name" => "PormG Energy")
        driver_dict = M.M2m_driver_endorsement_scratch.objects.create("driverref" => "row-get-m2m")

        driver = M.M2m_driver_endorsement_scratch.objects.get("id" => driver_dict[:id])
        manager = driver.sponsors
        sponsor_row = M.M2m_sponsor_scratch.objects.get("id" => sponsor[:id])

        @test manager.all() isa PormG.QueryBuilder.ObjectHandler
        @test manager.add(sponsor_row) === nothing

        related = manager.all().list()
        @test length(related) == 1
        @test related[1].name == "PormG Energy"
    finally
        M.M2m_driver_endorsement_scratch.objects.delete(allow_delete_all=true)
        M.M2m_sponsor_scratch.objects.delete(allow_delete_all=true)
    end

    standings = M.Driver_standings.objects.values("driverstandingsid").limit(1).first()
    @test standings isa PormGRow
    # Accessing an un-projected ForeignKey (`driverid`) triggers the lazy-FK refusal.
    # #231 backs this with a semantic type (LazyTraversalError); we still lock the #204
    # guidance wording: it must steer to up-front `values("fk__field")` projection and
    # never re-suggest `.on(...)` (which throws its own error and does not project columns).
    err = try; standings.driverid; nothing; catch e; e; end
    @test err isa PormG.LazyTraversalError    # #231: typed, was a bare ArgumentError (#204)
    @test err isa PormG.FieldAccessError      # catch the field-access family
    @test occursin("values(", err.msg)   # steers to projection
    @test occursin("__", err.msg)        # via the __ lookup
    @test !occursin(".on(", err.msg)     # never re-suggests the on() dead end
end

# ─────────────────────────────────────────────────────────────────────────────
# PormGRow: SQLite DateTime normalisation
# Verifies that row and dict list formats share the same SQLite datetime parsing
# path; JSON remains a serialized string as expected for API payloads.
# ─────────────────────────────────────────────────────────────────────────────
@testset "PormGRow SQLite DateTime normalisation" begin
    if PORMG_DB_FOLDER == "db_sl"
        label = "row_get_datetime_$(uuid4())"
        M.Django_contract_scratch.objects.filter("label" => label).delete()

        try
            M.Django_contract_scratch.objects.create(
                "label" => label,
                "event_time" => DateTime(2026, 5, 13, 12, 1, 2),
                "event_date" => Date(2026, 5, 13),
                "price" => "12.34",
            )

            row = M.Django_contract_scratch.objects.filter("label" => label).values("label", "event_time").first()
            dict_row = M.Django_contract_scratch.objects.filter("label" => label).values("label", "event_time").list(:dict)[1]
            json_row = M.Django_contract_scratch.objects.filter("label" => label).values("label", "event_time").list(:json)

            @test row.event_time isa Union{DateTime,ZonedDateTime}
            @test dict_row[:event_time] isa Union{DateTime,ZonedDateTime}
            @test JSON.parse(json_row)[1]["event_time"] isa String
        finally
            M.Django_contract_scratch.objects.filter("label" => label).delete()
        end
    else
        @test true
    end
end