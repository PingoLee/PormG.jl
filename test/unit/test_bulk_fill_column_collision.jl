# ============================================================
# test/unit/test_bulk_fill_column_collision.jl
#
# Regression suite for #335 — WHERE PormG writes a value it supplies itself.
#
# THE RULE:
#   A fill never takes a caller-supplied column name. Every auto-populated
#   column is written to a private `__pormg:fill:<field>` name in the working
#   frame, and `mapping` points at it.
#
# Before #335 the two injection sites in `_prepare_bulk_df!` wrote to
# `df[!, field]` — the MODEL FIELD's own name. When an explicit `columns=`
# Pair mapped some OTHER field to a source column carrying that name, the
# injection landed on top of it and destroyed the caller's values before they
# were read. Silent: the SQL still named both fields, and both bound the
# defaulted field's value.
#
#     columns = ["driver", "laps" => "pit_stops"]      # on a model declaring BOTH
#     params:   ["Senna", 0, 0, "Prost", 0, 0]         # pre-#335 — 3 and 5 are gone
#     params:   ["Senna", 3, 0, "Prost", 5, 0]         # post-#335
#
# On `bulk_update` the same defect surfaced as a baffling error instead, when
# the injected type disagreed with the reader field's — an `auto_now` stamp
# landing in a column an Int field was mapped to.
#
# Sibling files, deliberately not duplicated here — and the reason they are the
# real guard for this change:
#   - test_bulk_default_fill_scope.jl — WHICH fills happen and when (#331/#334).
#   - test_bulk_update_column_scope.jl — the `columns=` scope contract.
# #335 redirects EVERY injection, not only colliding ones, so those two files
# asserting unchanged bound parameters is what proves the redirect is invisible.
# Run them alongside this file, never instead of it.
#
# Deterministic and DB-free: a mock PostgreSQL connection with
# `show_query = :dict`. `bulk_copy` is the exception — it returns before its row
# loop, so its values are asserted one layer down, on `_prepare_bulk_df!` itself.
# ============================================================

using Test
using PormG
using PormG.Models: Model, IDField, IntegerField, CharField, DateTimeField, UUIDField
using PormG.QueryBuilder: bulk_copy, bulk_insert, bulk_update
using PormG.QueryBuilder: _prepare_bulk_df!, _normalize_bulk_columns, _bulk_working_frame
using PormG.QueryBuilder: _BULK_FILL_PREFIX, _is_injected_fill_column
using UUIDs
import DataFrames

# Mock connection under a dedicated key so this file cannot contaminate (or be
# contaminated by) other unit files sharing Main in runtests.jl.
struct BulkFillCollisionMockPg <: PormG.PormGPostgres end
PormG.config["bfcc_mock"] = PormG.Configuration.Settings(
    connections = BulkFillCollisionMockPg(),
    change_data = true,
)

# The issue's own model. Two defaulted integer fields is the minimum shape that can
# collide: the frame's `laps` column carries the pit-stop count, mapped explicitly onto
# `pit_stops`, while the model ALSO declares a defaulted `laps` that takes no part.
Bfcc_stint = Model("bfcc_stint",
    id        = IDField(),
    driver    = CharField(),
    laps      = IntegerField(default = 0, null = true),
    pit_stops = IntegerField(default = 0),
)
Bfcc_stint.connect_key = "bfcc_mock"

# The `bulk_update`-reachable variant. An explicit `columns=` SUPPRESSES static defaults on
# `:update` (they would overwrite live rows merely because the frame lacks the column), so the
# static-default collision above simply cannot fire there. `auto_now` still injects — it is an
# intentional ORM side-effect — which makes a temporal field the only shape that reproduces
# #335 on an update. It is also the shape from the issue report: an `auto_now` timestamp landing
# in the column an Int field was mapped to, surfacing as a type error naming a field the caller
# never mentioned.
Bfcc_lap = Model("bfcc_lap",
    id         = IDField(),
    points     = IntegerField(null = true),
    updated_at = DateTimeField(auto_now = true, null = true),
)
Bfcc_lap.connect_key = "bfcc_mock"

# A UUID `auto_add` PRIMARY KEY, for the `_drop_blank_auto_primary_keys!` route. That drop is the
# ONLY way a `per_row = true` fill (one distinct UUID per row, #334) can reach a collision: it
# deletes the pk's own mapping mid-flight while leaving a second field still reading that column.
Bfcc_token = Model("bfcc_token",
    token = UUIDField(primary_key = true, auto_add = true),
    note  = CharField(null = true),
)
Bfcc_token.connect_key = "bfcc_mock"

# Several fill kinds at once, for the blanket "no fill takes a caller name" assertion.
Bfcc_sheet = Model("bfcc_sheet",
    id         = IDField(),
    driver     = CharField(),
    laps       = IntegerField(default = 0, null = true),
    pit_stops  = IntegerField(default = 0),
    checked_at = DateTimeField(auto_now_add = true, null = true),
    token      = UUIDField(auto_add = true, null = true),
)
Bfcc_sheet.connect_key = "bfcc_mock"

# ------------------------------------------------------------------
# Read bound values back BY COLUMN NAME, never by a hard-coded index — an INSERT
# renders its column list in the same order it binds parameters, so a column's
# position in that list is its parameter index. Present columns come first and
# injected ones are appended, so index literals would be brittle here in exactly
# the way #335 makes interesting.
#
# Prefixed `bfcc_` because test_bulk_default_fill_scope.jl defines the same three
# helpers at top level and both files land in Main under runtests.jl.
# ------------------------------------------------------------------
function bfcc_insert_columns(res)
    m = match(r"INSERT INTO\s+\S+\s*\((.*?)\)\s*VALUES"s, res[:sql_text])
    m === nothing && error("could not parse an INSERT column list from: $(res[:sql_text])")
    return [strip(c, ['"', ' ', '\n', '\r', '\t']) for c in split(m.captures[1], ",")]
end

# Every bound value for `col`, across all rows. `parameters` is flat and row-major:
# column `idx` out of `n` appears at positions `idx, idx+n, idx+2n, ...`.
function bfcc_params_for(res, col)
    cols = bfcc_insert_columns(res)
    idx = findfirst(==(col), cols)
    idx === nothing && error("column $(col) is not in the INSERT: $(res[:sql_text])")
    return res[:parameters][idx:length(cols):end]
end

# The bulk_update VALUES source list plays the same role for an UPDATE.
function bfcc_source_params_for(res, col)
    m = match(r"AS\s+source\s*\((.*?)\)"s, res[:sql_text])
    m === nothing && error("could not parse a source column list from: $(res[:sql_text])")
    cols = [strip(c, ['"', ' ', '\n', '\r', '\t']) for c in split(m.captures[1], ",")]
    idx = findfirst(==(col), cols)
    idx === nothing && error("column $(col) is not in the source list: $(res[:sql_text])")
    return res[:parameters][idx:length(cols):end]
end

# Run `_prepare_bulk_df!` exactly as the three public entry points do — normalize `columns=`,
# wrap the caller's frame zero-copy, prepare. Returns the working frame too, because for
# `bulk_copy` (which returns before its row loop) that frame is the only place the values are
# observable at this layer.
function bfcc_prepare(model, df_o, columns, operation)
    df = _bulk_working_frame(df_o)
    mapping, fields_df, pk_exist, pk_field =
        _prepare_bulk_df!(df, model, _normalize_bulk_columns(columns), operation, nothing)
    return df, mapping, fields_df, pk_exist, pk_field
end

@testset "#335: a fill never takes a caller-supplied column name" begin

    # ─────────────────────────────────────────────────────────────────────────────
    # bulk_insert: the issue's reproduction, verbatim.
    # The frame's "laps" column holds the pit-stop count and is mapped onto `pit_stops`;
    # the model's own defaulted `laps` takes no part in the write and must be filled.
    # Pre-#335 the fill for `laps` overwrote df["laps"], so `pit_stops` bound 0 instead
    # of 3 and 5 — silent, wrong data on a documented first-class API.
    # ─────────────────────────────────────────────────────────────────────────────
    @testset "bulk_insert: a Pair's source column survives a same-named field's default" begin
        df = DataFrames.DataFrame(driver = ["Senna", "Prost"], laps = [3, 5])

        res = bulk_insert(Bfcc_stint.objects, df,
                          columns = ["driver", "laps" => "pit_stops"],
                          show_query = :dict)

        # The caller's numbers reach the column they were mapped to.
        @test bfcc_params_for(res, "pit_stops") == [3, 5]
        # ...and the field that merely shares the NAME still gets its own default, so a
        # `null = false` column is not left unsatisfied. Redirecting preserves the fill;
        # skipping it would have pushed the failure to the database.
        @test bfcc_params_for(res, "laps") == [0, 0]
        @test bfcc_params_for(res, "driver") == ["Senna", "Prost"]
        # Whole-batch shape: three columns, two rows, nothing dropped or duplicated.
        @test sort(bfcc_insert_columns(res)) == ["driver", "laps", "pit_stops"]
        @test res[:parameter_count] == 6
    end

    # ─────────────────────────────────────────────────────────────────────────────
    # bulk_update: the same defect, reported as a type error about a field the caller
    # never mentioned. `updated_at` is auto_now, so it injects even under an explicit
    # `columns=`; pre-#335 that stamp landed on the frame column `points` was mapped to,
    # and validation rejected the timestamp AS `points`.
    # ─────────────────────────────────────────────────────────────────────────────
    @testset "bulk_update: auto_now no longer stamps over a Pair's source column" begin
        df = DataFrames.DataFrame(record_id = [1, 2], updated_at = [10, 20])

        res = bulk_update(Bfcc_lap.objects, df,
                          columns  = ["updated_at" => "points", "record_id" => "id"],
                          match_on = ["id"],
                          show_query = :dict)

        # Pre-#335 this call did not merely bind the wrong value — it THREW, with
        # `field "points": expected Int64 …, got String("2026-…")`.
        @test bfcc_source_params_for(res, "points") == [10, 20]
        @test bfcc_source_params_for(res, "id") == [1, 2]
        # The auto_now stamp still happens; it just lands somewhere private now.
        @test "updated_at" in [strip(c, ['"', ' ']) for c in
              split(match(r"AS\s+source\s*\((.*?)\)"s, res[:sql_text]).captures[1], ",")]
    end

    # ─────────────────────────────────────────────────────────────────────────────
    # bulk_copy: `show_query` returns before the row loop, so the bound values cannot be
    # inspected at that layer. Assert one level down instead — on the working frame and
    # the mapping `_prepare_bulk_df!` hands back, which is what the COPY chunk builder
    # reads (`src = df[i:end_idx, mapping[field]]`).
    # ─────────────────────────────────────────────────────────────────────────────
    @testset "bulk_copy: the working frame keeps the Pair's source values" begin
        df_o = DataFrames.DataFrame(driver = ["Senna", "Prost"], laps = [3, 5])
        df, mapping, fields_df, _, _ =
            bfcc_prepare(Bfcc_stint, df_o, ["driver", "laps" => "pit_stops"], :copy)

        # The Pair's mapping is untouched — `pit_stops` still reads the frame's "laps".
        @test mapping["pit_stops"] == "laps"
        @test df[!, mapping["pit_stops"]] == [3, 5]
        # ...and `laps`'s own fill went somewhere the caller did not name.
        @test _is_injected_fill_column(mapping["laps"])
        @test df[!, mapping["laps"]] == [0, 0]
        @test sort(fields_df) == ["driver", "laps", "pit_stops"]
    end

    # ─────────────────────────────────────────────────────────────────────────────
    # The second live reproducer, and the only one that reaches a `per_row = true` fill.
    # `_drop_blank_auto_primary_keys!` runs BEFORE the fill loop: an all-blank auto pk
    # column is treated as absent, so it deletes `mapping["token"]` — but the Pair
    # `"token" => "note"` still reads that same frame column. Pre-#335 the per-row UUID
    # mint then landed on it and `note` bound three fresh UUIDs instead of NULL.
    # ─────────────────────────────────────────────────────────────────────────────
    @testset "an all-blank UUID auto_add pk does not mint over its other reader" begin
        df = DataFrames.DataFrame(token = [missing, missing, missing])

        res = bulk_insert(Bfcc_token.objects, df,
                          columns = ["token", "token" => "note"],
                          show_query = :dict)

        # `note` reads the frame's blanks — the caller asked for NULL and gets NULL.
        @test all(ismissing, bfcc_params_for(res, "note"))
        # The pk is still minted, still one distinct value per row (#334 stays honored).
        tokens = bfcc_params_for(res, "token")
        @test length(tokens) == 3
        @test all(!ismissing, tokens)
        @test length(unique(tokens)) == 3
    end

    # ─────────────────────────────────────────────────────────────────────────────
    # The contract itself, stated directly rather than through one collision at a time:
    # for EVERY auto-populated field, the destination is a private name absent from the
    # caller's frame. This is what makes the fix need no reachability argument.
    # ─────────────────────────────────────────────────────────────────────────────
    @testset "every injected fill lands on a private name" begin
        df_o = DataFrames.DataFrame(driver = ["Fangio", "Moss"], laps = [7, 9])
        caller_names = names(df_o)
        df, mapping, fields_df, _, _ =
            bfcc_prepare(Bfcc_sheet, df_o, ["driver", "laps" => "pit_stops"], :insert)

        # `laps`, `checked_at` and `token` are all absent from the write's scope and all
        # carry a fill; none of them may point at a name the caller supplied.
        for field in ["laps", "checked_at", "token"]
            @test haskey(mapping, field)
            @test startswith(mapping[field], _BULK_FILL_PREFIX)
            @test !(mapping[field] in caller_names)
        end
        # Fields the caller DID map keep pointing at the caller's own columns.
        @test mapping["driver"] == "driver"
        @test mapping["pit_stops"] == "laps"
        @test df[!, mapping["pit_stops"]] == [7, 9]
        # `id` is an auto pk with nothing to fill — it stays out of the write entirely.
        @test !("id" in fields_df)
    end

    # ─────────────────────────────────────────────────────────────────────────────
    # The private namespace is not a free pass: a caller column already named like one
    # would be clobbered by the fill, which is #335 all over again one level deeper.
    # The uniquifying loop keeps every injection a column ADDITION, never a replacement.
    # ─────────────────────────────────────────────────────────────────────────────
    @testset "a caller column named like the private prefix is not clobbered" begin
        squatter = "$(_BULK_FILL_PREFIX)pit_stops"
        df_o = DataFrames.DataFrame("driver" => ["Hawthorn"], squatter => [99])

        df, mapping, _, _, _ = bfcc_prepare(Bfcc_stint, df_o, [], :insert)

        # The fill stepped aside rather than overwriting the caller's cells.
        @test mapping["pit_stops"] != squatter
        @test df[!, squatter] == [99]
        @test df[!, mapping["pit_stops"]] == [0]
    end

    # ─────────────────────────────────────────────────────────────────────────────
    # The #132 no-mutation contract, re-asserted under a collision: the redirect adds a
    # column to the working frame, and the frame is a `copycols = false` wrapper, so the
    # addition must not reach the caller — neither as a new column nor as a rebound vector.
    # ─────────────────────────────────────────────────────────────────────────────
    @testset "the caller's DataFrame is untouched by a redirected fill (#132)" begin
        df = DataFrames.DataFrame(driver = ["Senna", "Prost"], laps = [3, 5])
        # Take the identity from the frame, not from the literal: the DataFrame
        # constructor copies its columns (`copycols = true`), so the array passed in is
        # never the one the frame holds.
        laps_vector = df[!, "laps"]

        bulk_insert(Bfcc_stint.objects, df,
                    columns = ["driver", "laps" => "pit_stops"], show_query = :dict)

        @test names(df) == ["driver", "laps"]
        @test df[!, "laps"] === laps_vector      # same vector object, not a copy
        @test df[!, "laps"] == [3, 5]            # and its cells were never written through
    end

    # ─────────────────────────────────────────────────────────────────────────────
    # The private names must not escape into anything the caller reads. Two consumers run
    # AFTER the injection and would otherwise present an internal column as if the caller
    # had supplied it — neither is reachable from the assertions above, so both are pinned
    # here directly. (`_depuration_values_bulk_insert`'s branch is the third such consumer
    # and is deliberately NOT pinned: reaching it needs a PormG-generated value that fails
    # its own field's formatter, and every route to one is rejected by the field
    # constructors. Not the same as unreachable — the field structs are mutable and do not
    # validate on `setproperty!`, so assigning a bad `.default` after construction would get
    # there — but nothing a caller writes through the public API does.)
    # ─────────────────────────────────────────────────────────────────────────────
    @testset "private fill names do not escape into caller-facing output" begin
        # `updated_at` is auto_now and excluded by columns=, so it is injected; the frame also
        # carries a column of that name. Without the prefix test in `_resolve_match_column!`,
        # `mapping["updated_at"] != "updated_at"` is now true and the warning fires, telling the
        # caller their column was "ignored in favor of the columns= mapping" — a mapping they
        # never declared, naming a source column that does not exist for them.
        # `id` is deliberately NOT mapped here: `match_on` names `updated_at`, so anything else
        # in `columns=` becomes a SET target, and a primary key may not be one.
        df_warn = DataFrames.DataFrame(new_points = [9], updated_at = ["1999-01-01T00:00:00"])
        # An empty pattern list asserts NO log records are emitted.
        @test_logs bulk_update(Bfcc_lap.objects, df_warn,
                               columns  = ["new_points" => "points"],
                               match_on = ["updated_at"],
                               show_query = :dict)

        # The not-found message lists the frame's columns as a "here is what you have" hint. It
        # must list what the CALLER has: a `columns:` entry reading `__pormg:fill:updated_at`
        # looks like a bug in PormG rather than help.
        df_missing = DataFrames.DataFrame(record_id = [1], new_points = [9])
        err = try
            bulk_update(Bfcc_lap.objects, df_missing,
                        columns  = ["new_points" => "points"],
                        match_on = ["id"],
                        show_query = :dict)
            nothing
        catch e
            e
        end
        # Not decoration: without it, an `err === nothing` (no throw at all) would make the
        # negative assertion below pass vacuously through `sprint(showerror, nothing)`.
        @test err isa PormG.UnknownFieldError
        msg = sprint(showerror, err)
        @test !occursin(_BULK_FILL_PREFIX, msg)
        # ...and the other side of it. `!occursin` alone would stay green if the whole
        # `(columns: ...)` hint were deleted, which is the failure it exists to prevent.
        @test occursin("record_id", msg)
    end

    # ─────────────────────────────────────────────────────────────────────────────
    # The mirror case from the issue's checklist: a Pair whose TARGET FIELD name matches
    # an unmapped frame column. Resolution is mapping-first (#107), so the declared Pair
    # wins and the same-named frame column is simply not read. No data is lost and no fix
    # is owed — pinned here so the asymmetry with the fixed case is on the record.
    # ─────────────────────────────────────────────────────────────────────────────
    @testset "mirror case: a Pair's target field name matching an unmapped column" begin
        # "laps" is a model field AND a frame column, but the caller mapped `laps` to "src".
        df = DataFrames.DataFrame(driver = ["Clark"], src = [42], laps = [999])

        res = bulk_insert(Bfcc_stint.objects, df,
                          columns = ["driver", "src" => "laps"],
                          show_query = :dict)

        # The declared mapping decides; the frame's own "laps" column is ignored, not blended.
        @test bfcc_params_for(res, "laps") == [42]
        # `pit_stops` is out of scope and gets its default, as `columns=` asks.
        @test bfcc_params_for(res, "pit_stops") == [0]
    end

end
