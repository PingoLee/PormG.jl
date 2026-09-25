# ============================================================
# test/unit/test_bulk_pg_unnest.jl
#
# PostgreSQL bulk writers bind one array per column and expand it with `unnest` (#672).
#
# CONTRACT being tested:
#   On PostgreSQL, `bulk_insert` and `bulk_update` bind ONE array parameter per column instead of
#   one parameter per cell:
#
#     INSERT INTO "t" (…) SELECT * FROM unnest($1::bigint[], $2::float[])
#     UPDATE "t" AS "Tb" SET … FROM unnest($2::float[], $3::bigint[]) AS source (…) WHERE …
#
#   so a chunk's parameters are exactly `[prefix…, col1_array, col2_array, …]` — the #665 handler /
#   `filters=` prefix first, then the arrays — and the statement text is the same for every chunk,
#   whatever its row count. The #84 bind-parameter cap therefore no longer binds on PostgreSQL.
#   Every array element is `missing`, an `Integer` or a `String` (bytes as `\x…` hex text), so
#   LibPQ quotes and escapes each element and the server recovers the exact per-cell text.
#
#   SQLite has no array parameters and keeps one `?` per cell in a VALUES list — an intentional
#   divergence. Both backends carry the same values and refuse the same bad input.
#
# Deterministic and DB-free: mock PostgreSQL and SQLite connections; `show_query` returns each
# chunk's statement before any driver call. The real-server round-trip of every element type is
# test/integration/test_bulk_column_arrays.jl.
# ============================================================

using Test
using PormG
using PormG.Models: Model, IDField, IntegerField, CharField, TextField, FloatField, BooleanField,
    TimeField, DurationField, DateField, DateTimeField, DecimalField, UUIDField, JSONField, BinaryField
using PormG.QueryBuilder: bulk_insert, bulk_update
using Dates, UUIDs
import DataFrames
import LibPQ   # only for the rendering canary below; the rest of the file is driver-free

const QB672 = PormG.QueryBuilder

# Dedicated mocks and config keys so this file cannot contaminate (or be contaminated by) other
# unit files sharing Main in runtests.jl.
struct PgUnnestMockPg <: PormG.PormGPostgres end
struct PgUnnestMockSl <: PormG.PormGSQLite end
# The SQLite chunk cap reads the library version for its bind-parameter limit; a modern build (32766).
PormG.backend_sqlite_version(::PgUnnestMockSl) = 3045000
PormG.config["pgu672_pg"] = PormG.Configuration.Settings(connections = PgUnnestMockPg(), change_data = true)
PormG.config["pgu672_sl"] = PormG.Configuration.Settings(connections = PgUnnestMockSl(), change_data = true)

# A trimmed F1 results table: `raceid` carries the scope filter, `points` is re-scored.
pgu672_result(key) = begin
    m = Model("pgu672_result",
        id     = IDField(),
        raceid = IntegerField(),
        points = FloatField(null = true),
    )
    m.connect_key = key
    m
end
Pgu672_result_pg = pgu672_result("pgu672_pg")
Pgu672_result_sl = pgu672_result("pgu672_sl")

# A pit-stop log carrying every value shape a bulk writer formats differently, so each one is
# seen as an array element: text with array-literal metacharacters, bool, time, interval, date,
# timestamptz, decimal, uuid, json and bytes.
pgu672_pit_stop(key) = begin
    m = Model("pgu672_pit_stop",
        id          = IDField(),
        raceid      = IntegerField(),
        driver      = CharField(null = true),
        note        = TextField(null = true),
        on_track    = BooleanField(null = true),
        stop_time   = TimeField(null = true),
        duration    = DurationField(null = true),
        race_day    = DateField(null = true),
        recorded_at = DateTimeField(null = true),
        fuel        = DecimalField(max_digits = 6, decimal_places = 2, null = true),
        token       = UUIDField(null = true),
        telemetry   = JSONField(null = true),
        payload     = BinaryField(null = true),
    )
    m.connect_key = key
    m
end
Pgu672_stop_pg = pgu672_pit_stop("pgu672_pg")
Pgu672_stop_sl = pgu672_pit_stop("pgu672_sl")

# Five 2021 Abu Dhabi results; chunk_size = 2 makes chunks of 2, 2 and 1 rows.
pgu672_df() = DataFrames.DataFrame(id = [1, 2, 3, 4, 5], raceid = fill(1073, 5),
                                   points = [25.0, 18.0, 15.0, 12.0, 10.0])

# Two pit stops: the first carries every awkward value, the second is all NULL but its keys.
const PGU672_TOKEN = UUID("8c2d6e7a-1f4b-4c3e-9a0d-5b6f7e8d9c0a")
pgu672_stops() = DataFrames.DataFrame(
    id          = [1, 2],
    raceid      = [1073, 1073],
    driver      = Union{String, Missing}["O\"Brien, {Jr}", ""],
    note        = Union{String, Missing}["back\\slash, \"NULL\"", "NULL"],
    on_track    = Union{Bool, Missing}[true, missing],
    stop_time   = Union{Time, Missing}[Time(14, 5, 3), missing],
    duration    = Union{Second, Missing}[Second(23), missing],
    race_day    = Union{Date, Missing}[Date(2021, 12, 12), missing],
    recorded_at = Union{DateTime, Missing}[DateTime(2021, 12, 12, 13, 5, 0), missing],
    fuel        = Union{String, Missing}["12.5", missing],
    token       = Union{UUID, Missing}[PGU672_TOKEN, missing],
    telemetry   = Union{Dict{String, Any}, Missing}[Dict{String, Any}("lap" => 42, "tyre" => "soft"), missing],
    payload     = Union{Vector{UInt8}, Missing}[UInt8[0x00, 0xff], missing],
)

@testset "PostgreSQL bulk writers bind one array per column (#672)" begin

    # ─────────────────────────────────────────────────────────────────────────────
    # bulk_update: the source is `unnest` over one typed array per column.
    # The static `filters=` value binds first as $1 (the #665 prefix), then the SET column and the
    # match key follow as $2 and $3, each cast to its column's type. No `source."col"::type` cast
    # remains in SET or WHERE — the arrays already type the source columns.
    # ─────────────────────────────────────────────────────────────────────────────
    @testset "bulk_update renders FROM unnest(…) AS source" begin
        res = bulk_update(Pgu672_result_pg.objects, pgu672_df()[1:2, :],
            columns = ["points"], match_on = ["id"], filters = ["raceid" => 1073], show_query = :dict)
        # (Concatenated rather than one triple-quoted literal: the WHERE join leaves a trailing
        # space after AND, which an editor would silently strip from a literal.)
        @test res[:sql_text] ==
            "UPDATE \"pgu672_result\" AS \"Tb\"\n" *
            "SET \"points\" = source.\"points\"\n" *
            "FROM unnest(\$2::float[], \$3::bigint[]) AS source (\"points\",\"id\")\n" *
            "WHERE \"Tb\".\"id\" = source.\"id\" AND \n" *
            "   \"Tb\".\"raceid\" = \$1\n"
        # Exactly [prefix…, col1_array, col2_array]: the filter value, then one array per column
        # in source-column order, each holding every row of the chunk.
        @test res[:parameters] == Any[1073, Any["25", "18"], Any[1, 2]]
        @test res[:parameter_count] == 3
    end

    # ─────────────────────────────────────────────────────────────────────────────
    # bulk_insert: the source is `SELECT * FROM unnest(…)`, and ON CONFLICT still follows it.
    # `bulk_copy` stays the fast path for a plain insert; this shape matters most for the
    # `on_conflict` insert COPY cannot express, so the clause must survive the new source.
    # ─────────────────────────────────────────────────────────────────────────────
    @testset "bulk_insert renders SELECT * FROM unnest(…)" begin
        res = bulk_insert(Pgu672_result_pg.objects, pgu672_df()[1:2, :], show_query = :dict)
        @test res[:sql_text] == """
            INSERT INTO "pgu672_result" ("id", "raceid", "points")
            SELECT * FROM unnest(\$1::bigint[], \$2::integer[], \$3::float[])
            """
        @test res[:parameters] == Any[Any[1, 2], Any[1073, 1073], Any["25", "18"]]

        upsert = bulk_insert(Pgu672_result_pg.objects, pgu672_df()[1:2, :], show_query = :dict,
            on_conflict = (action = :update, target = ["id"], set = ["points"]))
        @test upsert[:sql_text] == """
            INSERT INTO "pgu672_result" ("id", "raceid", "points")
            SELECT * FROM unnest(\$1::bigint[], \$2::integer[], \$3::float[])
            ON CONFLICT ("id") DO UPDATE SET "points" = EXCLUDED."points"
            """
        # The clause binds nothing: the parameters are the plain insert's.
        @test upsert[:parameters] == res[:parameters]
    end

    # ─────────────────────────────────────────────────────────────────────────────
    # Every chunk renders the same statement text; only the array lengths differ.
    # This is the property per-cell VALUES could never have — its placeholder count grew with the
    # chunk's rows, so a short final chunk rendered a different statement. With arrays the text is
    # fixed by the column set alone.
    # ─────────────────────────────────────────────────────────────────────────────
    @testset "the statement text is the same for every chunk" begin
        upd = bulk_update(Pgu672_result_pg.objects, pgu672_df(),
            columns = ["points"], match_on = ["id"], filters = ["raceid" => 1073],
            chunk_size = 2, show_query = :dict)
        @test length(upd) == 3
        @test allequal(r[:sql_text] for r in upd)
        # Each chunk binds only its own rows: arrays of 2, 2 and 1, after the same prefix.
        @test [length(r[:parameters][2]) for r in upd] == [2, 2, 1]
        @test all(r -> r[:parameters][1] == 1073, upd)
        @test upd[3][:parameters] == Any[1073, Any["10"], Any[5]]

        ins = bulk_insert(Pgu672_result_pg.objects, pgu672_df(), chunk_size = 2, show_query = :dict)
        @test length(ins) == 3
        @test allequal(r[:sql_text] for r in ins)
        @test [length(r[:parameters][1]) for r in ins] == [2, 2, 1]
    end

    # ─────────────────────────────────────────────────────────────────────────────
    # The #84 bind-parameter cap no longer binds on PostgreSQL.
    # One row past what 65,535 per-cell parameters allowed at three columns, requested as a single
    # chunk: PostgreSQL now honours it as one statement of three parameters, while SQLite, which
    # still binds per cell, is split by the cap. `_bulk_chunk_rows` is the switch — and a
    # non-positive chunk_size keeps the old cap on PostgreSQL, so it can never collapse a whole
    # frame into one statement whose arrays grow without bound.
    # ─────────────────────────────────────────────────────────────────────────────
    @testset "chunk_size is honoured past the old 65,535-parameter cap" begin
        pg, sl = PgUnnestMockPg(), PgUnnestMockSl()
        @test QB672._bulk_chunk_rows(pg, 30_000, 3, 0, :bulk_insert) == 30_000   # 90k cells: uncapped
        @test QB672._bulk_chunk_rows(sl, 30_000, 3, 0, :bulk_insert) == fld(32766, 3)
        # A filter prefix is still charged against the per-cell budget on SQLite only.
        @test QB672._bulk_chunk_rows(pg, 30_000, 3, 5, :bulk_update) == 30_000
        @test QB672._bulk_chunk_rows(sl, 30_000, 3, 5, :bulk_update) == fld(32766 - 5, 3)
        # Degenerate chunk_size: the backend-safe cap on both, never "everything in one statement".
        for requested in (0, -1)
            @test QB672._bulk_chunk_rows(pg, requested, 3, 0, :bulk_insert) == fld(65535, 3)
            @test QB672._bulk_chunk_rows(sl, requested, 3, 0, :bulk_insert) == fld(32766, 3)
        end

        nrows = fld(65535, 3) + 1
        df = DataFrames.DataFrame(id = collect(1:nrows), raceid = fill(1073, nrows),
                                  points = fill(1.0, nrows))

        res = bulk_insert(Pgu672_result_pg.objects, df, chunk_size = nrows, show_query = :params)
        @test length(res) == 3                          # one statement: [ids, raceids, points]
        @test all(col -> length(col) == nrows, res)

        res_sl = bulk_insert(Pgu672_result_sl.objects, df, chunk_size = nrows, show_query = :params)
        @test res_sl isa Vector{<:Any} && length(res_sl) > 1   # SQLite: several capped statements
        @test all(chunk -> length(chunk) <= 32766, res_sl)

        # The degenerate fallback reaches both public writers, not just the helper: the frame is one
        # row past fld(65535, 3), so chunk_size = 0 must split it in two — a writer that stopped
        # routing through `_bulk_chunk_rows` would send it as one unbounded statement (a String).
        split_insert = bulk_insert(Pgu672_result_pg.objects, df, chunk_size = 0, show_query = :sql)
        @test split_insert isa Vector && length(split_insert) == 2
        split_update = bulk_update(Pgu672_result_pg.objects, df, columns = ["points", "raceid"],
                                   match_on = ["id"], chunk_size = 0, show_query = :sql)
        @test split_update isa Vector && length(split_update) == 2   # 3 source columns, like the insert
    end

    # ─────────────────────────────────────────────────────────────────────────────
    # Array elements carry each cell's scalar text, as a String LibPQ will quote.
    # LibPQ writes a non-String element with a bare `string()`, unquoted, so an element whose text
    # held a comma, brace or quote could corrupt the literal. Every element must be `missing`, an
    # Integer (Bool included) or a String; the metacharacter-laden strings pass through unchanged
    # for LibPQ to escape, "NULL" stays text rather than becoming SQL NULL, and bytes travel as
    # the same `\x…` hex text the per-cell parameter used.
    # ─────────────────────────────────────────────────────────────────────────────
    @testset "elements are missing, Integer or String — never raw values" begin
        res = bulk_insert(Pgu672_stop_pg.objects, pgu672_stops(), show_query = :dict)
        cols = strip.(split(match(r"\((.*?)\)\n"s, res[:sql_text]).captures[1], ", "), '"')
        col(name) = res[:parameters][findfirst(==(name), cols)]

        for (name, array) in zip(cols, res[:parameters])
            @test all(el -> el isa Union{Missing, Integer, String}, array)
        end

        @test col("driver") == Any["O\"Brien, {Jr}", ""]
        @test col("note") == Any["back\\slash, \"NULL\"", "NULL"]   # the TEXT "NULL", not SQL NULL
        @test isequal(col("on_track"), Any[true, missing])
        @test isequal(col("payload"), Any["\\x00ff", missing])      # hex text, never Julia bytes
        @test isequal(col("token"), Any[string(PGU672_TOKEN), missing])
        @test isequal(col("fuel"), Any["12.5", missing])
        # JSON goes as its serialized text: a String, so its quotes and braces get escaped.
        @test col("telemetry")[1] isa String
        @test occursin("\"tyre\":\"soft\"", col("telemetry")[1])
        # Every remaining nullable column is NULL on the second stop.
        for name in ("stop_time", "duration", "race_day", "recorded_at")
            @test col(name)[1] isa String
            @test ismissing(col(name)[2])
        end
    end

    # ─────────────────────────────────────────────────────────────────────────────
    # _pg_array_element: any other value is reduced to the String LibPQ would have sent.
    # Every field formatter today returns a String, an Integer, `missing` or bytes, so the public
    # path above never reaches the `string` fallback — it exists for a formatter that one day
    # returns a raw value. Pinned directly: the fallback must produce a String (which LibPQ
    # quotes), never pass a Date/Float/Symbol through to be written unquoted.
    # ─────────────────────────────────────────────────────────────────────────────
    @testset "_pg_array_element reduces any value to missing, Integer or String" begin
        @test QB672._pg_array_element(missing) === missing
        @test QB672._pg_array_element(nothing) === missing
        @test QB672._pg_array_element(42) === 42
        @test QB672._pg_array_element(true) === true
        @test QB672._pg_array_element(SubString("O\"Brien", 1)) === "O\"Brien"   # a String, not a view
        @test QB672._pg_array_element(PormG.PormGBytes(UInt8[0x01, 0x02])) == "\\x0102"
        @test QB672._pg_array_element(Date(2021, 12, 12)) === "2021-12-12"
        @test QB672._pg_array_element(1.5) === "1.5"
        @test QB672._pg_array_element(Symbol("a,b")) === "a,b"   # would split an unquoted element
    end

    # ─────────────────────────────────────────────────────────────────────────────
    # Both backends carry the same values — only the transport differs.
    # The same frame on SQLite binds per cell, row-major; column k of its flat vector must equal
    # PostgreSQL's array k element for element. The one exception is bytes: SQLite binds the raw
    # blob, PostgreSQL its hex text — the two wire forms `add_parameter!` already used per cell.
    # ─────────────────────────────────────────────────────────────────────────────
    @testset "PostgreSQL arrays hold what SQLite binds per cell" begin
        pg = bulk_insert(Pgu672_stop_pg.objects, pgu672_stops(), show_query = :dict)
        sl = bulk_insert(Pgu672_stop_sl.objects, pgu672_stops(), show_query = :dict)
        # SQLite still renders one `?` per cell in a VALUES list.
        @test occursin("VALUES (?, ?,", sl[:sql_text])
        @test !occursin("unnest", sl[:sql_text])

        ncols = length(pg[:parameters])
        @test length(sl[:parameters]) == 2 * ncols
        for k in 1:ncols
            sl_column = sl[:parameters][k:ncols:end]
            if any(v -> v isa Vector{UInt8}, sl_column)
                @test isequal(pg[:parameters][k], Any["\\x" * bytes2hex(sl_column[1]), missing])
            else
                @test isequal(pg[:parameters][k], Any[sl_column...])
            end
        end
    end

    # ─────────────────────────────────────────────────────────────────────────────
    # A collection in a cell is refused on both backends, naming the field.
    # A text field lets a Vector through validation, and neither row source can store it: an
    # array element would render as a nested array literal, and a SQLite VALUES row would grow
    # extra `?`s. The refusal is shared, so the two backends raise the same error type.
    # ─────────────────────────────────────────────────────────────────────────────
    @testset "a collection cell raises InvalidValueError on both backends" begin
        df = DataFrames.DataFrame(id = [1], raceid = [1073], driver = [["Verstappen", "Hamilton"]])
        refusal(call) = try
            call()
            nothing
        catch e
            e
        end
        for model in (Pgu672_stop_pg, Pgu672_stop_sl)
            # Both writers run the same per-row check, so both are asserted.
            for err in (refusal(() -> bulk_insert(model.objects, df, show_query = :dict)),
                        refusal(() -> bulk_update(model.objects, df, columns = ["driver"],
                                                  match_on = ["id"], show_query = :dict)))
                @test err isa PormG.InvalidValueError
                @test occursin("driver", sprint(showerror, err))
                @test occursin("single value", sprint(showerror, err))
            end
        end
    end

    # ─────────────────────────────────────────────────────────────────────────────
    # Canary: LibPQ renders a column array the way this transport relies on.
    # PormG hands LibPQ a Vector and LibPQ writes the array literal — an internal of the driver
    # (`string_parameter`), not public API, and LibPQ before 1.10 did not escape elements at all:
    # there `"\x00ff"` silently became other bytes and a `"` broke the literal. The real-server
    # round-trip is integration-only, which CI does not run, so this pins the rendering itself:
    # every String quoted with `\` and `"` escaped, "NULL" text quoted, `missing` a bare NULL,
    # integers and Bools bare. If a LibPQ upgrade changes this, re-verify the round-trip first.
    # ─────────────────────────────────────────────────────────────────────────────
    @testset "LibPQ renders a column array as a correctly escaped literal" begin
        column = Any["O\"Brien, {Jr}", "back\\slash", "NULL", "", missing, 42, true, "\\x00ff"]
        @test LibPQ.string_parameter(column) ==
              "{\"O\\\"Brien, {Jr}\",\"back\\\\slash\",\"NULL\",\"\",NULL,42,true,\"\\\\x00ff\"}"
    end
end

# A results table with a defaulted `status`, so a write that leaves it out gets a column PormG
# injects into the working frame itself — a source column the caller never wrote (#704).
pgu704_result(key) = begin
    m = Model("pgu704_result",
        id     = IDField(),
        raceid = IntegerField(),
        points = FloatField(null = true),
        status = CharField(default = "Finished"),
    )
    m.connect_key = key
    m
end
Pgu704_result_pg = pgu704_result("pgu672_pg")
Pgu704_result_sl = pgu704_result("pgu672_sl")

@testset "Bulk writers read each cell by column position (#704)" begin

    # ─────────────────────────────────────────────────────────────────────────────
    # Bulk writers: a renamed, reordered frame still binds each value to its own column.
    # Since #704 the row loop resolves each field's source column once (`df[!, mapping[field]]`)
    # and reads cells by position, instead of looking the column up by name per cell. A
    # misalignment there is a silent misbind, so the frame here is in the REVERSE of the model's
    # field order and renames two columns through `columns=`; the arrays must still come out in
    # the INSERT column list's order (id, raceid, points), and SQLite's row-major `?`s must agree.
    # ─────────────────────────────────────────────────────────────────────────────
    @testset "renamed and reordered columns bind to their own fields" begin
        frame = DataFrames.DataFrame(pts = [25.0, 18.0], race = [1073, 1074], id = [1, 2])
        mapping = ["id", "race" => "raceid", "pts" => "points"]

        pg = bulk_insert(Pgu672_result_pg.objects, frame, columns = mapping, show_query = :dict)
        @test pg[:sql_text] == """
            INSERT INTO "pgu672_result" ("id", "raceid", "points")
            SELECT * FROM unnest(\$1::bigint[], \$2::integer[], \$3::float[])
            """
        # Distinct values per column (1073 vs 1074, 25 vs 18), so a swapped column cannot pass.
        @test pg[:parameters] == Any[Any[1, 2], Any[1073, 1074], Any["25", "18"]]

        # SQLite: one `?` per cell, row by row, in the same column order.
        sl = bulk_insert(Pgu672_result_sl.objects, frame, columns = mapping, show_query = :dict)
        @test sl[:parameters] == Any[1, 1073, "25", 2, 1074, "18"]

        # bulk_update: the SET column, then the match key (the source-column order), both read
        # from their renamed / reordered frame columns.
        upd = bulk_update(Pgu672_result_pg.objects, frame, columns = ["pts" => "points", "id"],
            match_on = ["id"], show_query = :dict)
        @test upd[:parameters] == Any[Any["25", "18"], Any[1, 2]]
    end

    # ─────────────────────────────────────────────────────────────────────────────
    # Bulk writers: an injected default column lines up with the renamed ones.
    # `status` is left out by `columns=`, so PormG fills its default into a private column of the
    # working frame and appends the field to the INSERT list. The caller's own `status` column (a
    # decoy, the #335 shape) is excluded and must not be read. The positional reads must pick the
    # private fill column for `status`, the renamed frame columns for the rest.
    # ─────────────────────────────────────────────────────────────────────────────
    @testset "an injected default column binds beside renamed columns" begin
        frame = DataFrames.DataFrame(status = ["DNF", "Retired"], pts = [25.0, 18.0], race = [1073, 1074], id = [1, 2])
        mapping = ["id", "race" => "raceid", "pts" => "points"]

        pg = bulk_insert(Pgu704_result_pg.objects, frame, columns = mapping, show_query = :dict)
        @test occursin("(\"id\", \"raceid\", \"points\", \"status\")", pg[:sql_text])
        @test pg[:parameters] == Any[Any[1, 2], Any[1073, 1074], Any["25", "18"], Any["Finished", "Finished"]]

        sl = bulk_insert(Pgu704_result_sl.objects, frame, columns = mapping, show_query = :dict)
        @test sl[:parameters] == Any[1, 1073, "25", "Finished", 2, 1074, "18", "Finished"]
    end

    # ─────────────────────────────────────────────────────────────────────────────
    # Bulk writers: validation stays row by row, so the first bad ROW is the one reported.
    # Row 1 is bad only in its last column (points), row 2 only in an earlier one (raceid). Row by
    # row, `points` is reached first; a column-by-column pass would report `raceid` instead. Hoisting
    # the per-field work out of the loop (#704) must not have turned the loop inside out.
    # ─────────────────────────────────────────────────────────────────────────────
    @testset "the first failing row is reported, not the first failing column" begin
        frame = DataFrames.DataFrame(id = [1, 2], raceid = Any[1073, "not a race"], points = Any["fast", 18.0])
        # The message a writer raises for this frame. Row 1's cell cannot be formatted, so it comes
        # from the per-row depuration pass, which colors the field name — hence the bare-name checks.
        message(call) = try
            call()
            ""
        catch e
            @test e isa PormG.InvalidValueError
            sprint(showerror, e)
        end
        names_points_not_raceid(msg) = occursin("points", msg) && !occursin("raceid", msg)
        for model in (Pgu672_result_pg, Pgu672_result_sl)
            @test names_points_not_raceid(message(() -> bulk_insert(model.objects, frame, show_query = :dict)))
        end
        # bulk_update validates its SET columns the same way.
        @test names_points_not_raceid(message(() -> bulk_update(Pgu672_result_pg.objects, frame,
            columns = ["id", "raceid", "points"], match_on = ["id"], show_query = :dict)))
    end
end
