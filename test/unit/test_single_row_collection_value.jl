# ============================================================
# test/unit/test_single_row_collection_value.jl
#
# The single-row writers refuse a collection in a write value, like the bulk writers do (#712).
#
# CONTRACT being tested:
#   `create`, `update`, `get_or_create` and `update_or_create` raise `InvalidValueError`, naming the
#   field, when a text-like field (`CharField`, `TextField`, …) is given a `Vector` — on BOTH
#   backends, before anything binds. Before #712 the value passed validation (`format_text_sql` maps
#   a `Vector` element-wise, which is what `__in` needs) and then:
#
#     PostgreSQL — bound as ONE array parameter, stored as the literal text `{"Ayrton","Senna"}`
#     SQLite     — expanded into extra `?`s: `VALUES (?, ?)` for one column, `SET "c" = ?, ?`
#
#   The refusal is the one the bulk writers use since #672 (`_single_value`), and it runs AFTER the
#   field's formatter, so a `JSONField` vector — serialized to one string — is still accepted. That
#   is not hypothetical: a consuming app writes a vector into a JSONField through `create`.
#
#   `bulk_copy` (PostgreSQL only) had the same gap after #672 — CSV wrote the vector's `repr` as the
#   column text — and is covered here too, beside the single-row writers.
#
#   #716: the collection is refused whatever its ELEMENTS. `format_text_sql` could not format a
#   `Float64`, a `nothing` or a tuple, so those crashed inside the formatter before the #712 check
#   ran. `_format_single` now also checks the raw value first, for every field but JSON and binary.
#
# Deterministic and DB-free: mock PostgreSQL and SQLite connections, `show_query = :dict`. The
# executing calls (`get_or_create`, `bulk_copy`) are refused before they reach the (absent) driver.
# ============================================================

using Test
using PormG
using PormG.Models: Model, IDField, CharField, TextField, JSONField
using PormG.QueryBuilder: bulk_copy, bulk_insert, bulk_update
import DataFrames

# Dedicated mocks and config keys so this file cannot contaminate (or be contaminated by) other
# unit files sharing Main in runtests.jl.
struct SrCollMockPg <: PormG.PormGPostgres end
struct SrCollMockSl <: PormG.PormGSQLite end
PormG.config["srcoll712_pg"] = PormG.Configuration.Settings(connections = SrCollMockPg(), change_data = true)
PormG.config["srcoll712_sl"] = PormG.Configuration.Settings(connections = SrCollMockSl(), change_data = true)

# A trimmed F1 drivers table: `driverref` is the unique lookup key, `forename`/`surname` are the
# text-like columns under test, and `nicknames` is a JSONField that legitimately takes a vector.
srcoll712_driver(key) = begin
    m = Model("srcoll712_driver",
        id        = IDField(),
        driverref = CharField(unique = true),
        forename  = CharField(null = true),
        surname   = TextField(null = true),
        nicknames = JSONField(null = true),
    )
    m.connect_key = key
    m
end
const SRCOLL712_MODELS = (srcoll712_driver("srcoll712_pg"), srcoll712_driver("srcoll712_sl"))

# The exception a call raises, or `nothing` — so a missing refusal fails the `isa` test rather than
# the whole file (a unit file stops at its first failing top-level testset).
srcoll712_refusal(call) = try
    call()
    nothing
catch e
    e
end

# Every refusal must be the #231 value-error type and must say which field and why.
function srcoll712_check(err, field)
    @test err isa PormG.InvalidValueError
    msg = err === nothing ? "" : sprint(showerror, err)
    @test occursin("`$(field)`", msg)
    @test occursin("single value", msg)
end

@testset "single-row writers refuse a collection value (#712)" begin

    # ─────────────────────────────────────────────────────────────────────────────
    # create / update: a Vector in a CharField or a TextField is refused on both backends.
    # These are the two bind sites every single-row write goes through (`_prepare_row_insert!` for
    # the INSERT-shaped writers, `update()` for UPDATE and `row.save()`); before #712 PostgreSQL
    # stored array-literal text and SQLite rendered a placeholder per element.
    # ─────────────────────────────────────────────────────────────────────────────
    @testset "create and update refuse a Vector in a text-like field" begin
        for m in SRCOLL712_MODELS, field in ("forename", "surname")
            # create: the vector sits beside a valid required key, so only the vector is wrong.
            err = srcoll712_refusal(() -> m.objects.create("driverref" => "senna", field => ["Ayrton", "Senna"],
                                                           show_query = :dict))
            srcoll712_check(err, field)
            # update: filtered, so the refusal is the value check and not the unfiltered-update guard.
            err = srcoll712_refusal(() -> m.objects.filter("id" => 1).update(field => ["Ayrton", "Senna"],
                                                                            show_query = :dict))
            srcoll712_check(err, field)
        end
    end

    # ─────────────────────────────────────────────────────────────────────────────
    # update_or_create: a collection in the lookup AND in the defaults is refused.
    # Both halves are merged into one INSERT row, so both reach the same bind site as create().
    # ─────────────────────────────────────────────────────────────────────────────
    @testset "update_or_create refuses a collection in lookup or defaults" begin
        for m in SRCOLL712_MODELS
            err = srcoll712_refusal(() -> m.objects.update_or_create("driverref" => ["senna", "prost"],
                                                                     defaults = ["forename" => "Ayrton"],
                                                                     show_query = :dict))
            srcoll712_check(err, "driverref")
            err = srcoll712_refusal(() -> m.objects.update_or_create("driverref" => "senna",
                                                                     defaults = ["forename" => ["Ayrton", "Senna"]],
                                                                     show_query = :dict))
            srcoll712_check(err, "forename")
        end
    end

    # ─────────────────────────────────────────────────────────────────────────────
    # get_or_create: refused on the miss path (the INSERT) and, before any read, on the hit path.
    # `show_query = :dict` renders only the INSERT a miss would run. The `:execute` call exercises
    # the lookup read that runs FIRST: without the up-front check it reached `filter()` and raised
    # `FilterError` ("a vector value but no operator") instead — a different type for the same
    # mistake. Here it must be refused before the mock driver is ever asked for anything.
    # ─────────────────────────────────────────────────────────────────────────────
    @testset "get_or_create refuses a collection on both the insert and the lookup path" begin
        for m in SRCOLL712_MODELS
            err = srcoll712_refusal(() -> m.objects.get_or_create("driverref" => "senna",
                                                                  defaults = ["surname" => ["Senna", "da Silva"]],
                                                                  show_query = :dict))
            srcoll712_check(err, "surname")
            err = srcoll712_refusal(() -> m.objects.get_or_create("driverref" => ["senna", "prost"]))
            srcoll712_check(err, "driverref")
        end
    end

    # ─────────────────────────────────────────────────────────────────────────────
    # bulk_copy: a collection cell is refused like every other writer's.
    # COPY has no placeholders, so the failure mode was different but just as silent: CSV.write
    # serialized the formatter's Vector as `["Ayrton", "Senna"]` text into the column. bulk_copy
    # formats every cell of a chunk before the COPY is sent, so the mock driver is never reached.
    # It runs inside `with_tx_context` (standing in for `run_in_transaction`, as in
    # test_bulk_row_counts.jl) because outside a transaction bulk_copy first opens one on the pool.
    # ─────────────────────────────────────────────────────────────────────────────
    @testset "bulk_copy refuses a collection cell" begin
        df = DataFrames.DataFrame(driverref = ["senna"], forename = [["Ayrton", "Senna"]])
        err = srcoll712_refusal(() -> PormG.Configuration.with_tx_context(
            () -> bulk_copy(SRCOLL712_MODELS[1].objects, df),
            PormG.config["srcoll712_pg"].connections, :mock_tx_conn))
        srcoll712_check(err, "forename")
    end

    # ─────────────────────────────────────────────────────────────────────────────
    # A collection is refused whatever its elements, on every writer (#716).
    # The #712 check ran only AFTER the field formatter, and `format_text_sql` maps a collection
    # element-wise — so any element it cannot format crashed there first: `[1.5, 2.5]` and a tuple
    # as a raw `MethodError`, `["A", nothing]` as a `Missing`→`String` convert error. Neither is in
    # the #231 taxonomy and neither names the field. Each shape is asserted on each writer, and on
    # bulk_update also as a MATCH column, which skips validation but is still formatted.
    # ─────────────────────────────────────────────────────────────────────────────
    @testset "a collection of any elements is refused before the formatter (#716)" begin
        shapes = ([1.5, 2.5], ["Ayrton", nothing], ("Ayrton", "Senna"))
        for m in SRCOLL712_MODELS, v in shapes
            err = srcoll712_refusal(() -> m.objects.create("driverref" => "senna", "forename" => v, show_query = :dict))
            srcoll712_check(err, "forename")
            err = srcoll712_refusal(() -> m.objects.filter("id" => 1).update("surname" => v, show_query = :dict))
            srcoll712_check(err, "surname")
            err = srcoll712_refusal(() -> m.objects.update_or_create("driverref" => "senna",
                                                                     defaults = ["forename" => v], show_query = :dict))
            srcoll712_check(err, "forename")
            err = srcoll712_refusal(() -> m.objects.get_or_create("driverref" => v))
            srcoll712_check(err, "driverref")

            df = DataFrames.DataFrame(driverref = ["senna"], forename = [v])
            err = srcoll712_refusal(() -> bulk_insert(m.objects, df, show_query = :dict))
            srcoll712_check(err, "forename")
            err = srcoll712_refusal(() -> bulk_update(m.objects, df, columns = ["forename"],
                                                      match_on = ["driverref"], show_query = :dict))
            srcoll712_check(err, "forename")
            key_df = DataFrames.DataFrame(driverref = [v], forename = ["Ayrton"])
            err = srcoll712_refusal(() -> bulk_update(m.objects, key_df, columns = ["forename"],
                                                      match_on = ["driverref"], show_query = :dict))
            srcoll712_check(err, "driverref")
        end
        for v in shapes
            df = DataFrames.DataFrame(driverref = ["senna"], forename = [v])
            err = srcoll712_refusal(() -> PormG.Configuration.with_tx_context(
                () -> bulk_copy(SRCOLL712_MODELS[1].objects, df),
                PormG.config["srcoll712_pg"].connections, :mock_tx_conn))
            srcoll712_check(err, "forename")
        end
    end

    # ─────────────────────────────────────────────────────────────────────────────
    # Control: a JSONField vector is still ONE bound value, on every writer.
    # The formatter serializes the vector to a single JSON string, and the raw-value check (#716)
    # exempts JSONField (`_takes_collection`). Refusing it would break a consuming app that stores a
    # vector of regions into a JSONField through create().
    # ─────────────────────────────────────────────────────────────────────────────
    @testset "a JSONField vector still binds as one JSON string" begin
        json = "[\"Magic\",\"Beco\"]"
        for m in SRCOLL712_MODELS
            r = m.objects.create("driverref" => "senna", "nicknames" => ["Magic", "Beco"], show_query = :dict)
            @test r[:parameters] == Any["senna", json]
            r = m.objects.filter("id" => 1).update("nicknames" => ["Magic", "Beco"], show_query = :dict)
            @test json in r[:parameters]
            @test length(r[:parameters]) == 2          # the SET value and the id filter — nothing extra
            # A JSONField vector as a get_or_create LOOKUP passes the up-front check (this renders the
            # miss INSERT). The hit read that runs first is covered by the #717 testset below.
            r = m.objects.get_or_create("nicknames" => ["Magic", "Beco"],
                                        defaults = ["driverref" => "senna"], show_query = :dict)
            @test r[:parameters] == Any[json, "senna"]
            r = m.objects.update_or_create("driverref" => "senna", defaults = ["nicknames" => ["Magic", "Beco"]],
                                           show_query = :dict)
            @test r[:parameters] == Any["senna", json]
        end
    end

    # ─────────────────────────────────────────────────────────────────────────────
    # get_or_create matches a JSONField collection lookup by equality (#717).
    # The hit read runs BEFORE the INSERT and went through `filter(f => vector)`, which refuses a
    # bare vector at parse time ("a vector value but no operator") — so the call raised
    # `FilterError` before any SQL, while `show_query = :dict`, which renders only the miss INSERT,
    # looked fine. The read is rendered here directly: one `=` against the column, binding the SAME
    # JSON string the INSERT binds, which is what makes it the ON CONFLICT target's equality.
    # ─────────────────────────────────────────────────────────────────────────────
    @testset "get_or_create's hit read matches a JSONField collection by its JSON text (#717)" begin
        lookup = PormG.QueryBuilder._get_or_create_lookup
        for m in SRCOLL712_MODELS
            for (v, json) in ((["Magic", "Beco"], "[\"Magic\",\"Beco\"]"),
                              (Dict("team" => "McLaren"), "{\"team\":\"McLaren\"}"))
                r = lookup(m, ["nicknames"], Dict{String,Any}("nicknames" => v)).list(show_query = :dict)
                @test r[:parameters] == Any[json]
                @test occursin(r"\"nicknames\" = (\$1|\?)", r[:sql_text])
                # The miss INSERT binds the identical text, so a row it wrote is the row the read finds.
                r = m.objects.get_or_create("nicknames" => v, defaults = ["driverref" => "senna"],
                                            show_query = :dict)
                @test r[:parameters] == Any[json, "senna"]
            end
            # Only a JSONField is serialized: a scalar lookup binds as before, and a text-field
            # collection is still refused up front (#712/#716), never matched.
            r = lookup(m, ["driverref"], Dict{String,Any}("driverref" => "senna")).list(show_query = :dict)
            @test r[:parameters] == Any["senna"]
            srcoll712_check(srcoll712_refusal(() -> m.objects.get_or_create("forename" => [1.5, 2.5])), "forename")
            # The EXECUTING call goes through `_get_or_create_lookup` too. On a mock it cannot finish
            # (there is no pool to acquire), but it must get past the hit read's `filter()`: before
            # #717 it stopped there with `FilterError` ("... but no operator").
            err = srcoll712_refusal(() -> m.objects.get_or_create("nicknames" => ["Magic", "Beco"],
                                                                  defaults = ["driverref" => "senna"]))
            @test !(err isa PormG.FilterError)
            @test !occursin("no operator", err === nothing ? "" : sprint(showerror, err))
        end
    end

    # ─────────────────────────────────────────────────────────────────────────────
    # The bulk writers' error-context pass keeps reporting the row's REAL error (#716 review).
    # `_depuration_values_bulk_insert` walks every cell after any failure in the row and throws on
    # the first it rejects. The collection check lives in its `catch`, so a collection the text
    # formatter maps without throwing (`["A", "B"]`) cannot pre-empt a later field's genuine error —
    # here an invalid JSON string, which `create` reports for the same row.
    # ─────────────────────────────────────────────────────────────────────────────
    @testset "bulk error context names the failing field, not a formattable collection" begin
        df = DataFrames.DataFrame(driverref = ["senna"], forename = [["Ayrton", "Senna"]], nicknames = ["{not json"])
        for m in SRCOLL712_MODELS
            err = srcoll712_refusal(() -> bulk_insert(m.objects, df, show_query = :dict))
            @test err isa PormG.InvalidValueError
            msg = err === nothing ? "" : sprint(showerror, err)
            @test occursin("nicknames", msg)
            @test !occursin("single value", msg)
        end
    end

    # ─────────────────────────────────────────────────────────────────────────────
    # Control: an `__in` lookup on the same text field still formats element-wise.
    # `format_text_sql(::AbstractArray)` is what makes the bug possible, and it has to stay: it is
    # how `@in` binds its list. Lookups never pass through the write bind sites.
    # ─────────────────────────────────────────────────────────────────────────────
    @testset "an @in lookup on a text field still binds its elements" begin
        for m in SRCOLL712_MODELS
            r = m.objects.filter("forename__@in" => ["Ayrton", "Alain"]).list(show_query = :dict)
            flat = collect(Iterators.flatten(p isa AbstractVector ? p : (p,) for p in r[:parameters]))
            @test "Ayrton" in flat && "Alain" in flat
        end
    end
end
