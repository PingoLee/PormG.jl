# ==============================================================================
# ARRAY FIELD — Live-Database Integration Test (#28)
#
# `ArrayField(base)` is a one-dimensional PostgreSQL array of the base field's values. It is
# PostgreSQL only: SQLite has no array type, and PormG refuses one there rather than emulate it — on
# SQLite this file asserts exactly that refusal and nothing else.
#
# What only a live server can say:
#   * the literal PormG prints is what PostgreSQL's `array_in` reads — quoting, escaping and NULLs
#     included — so every value written reads back unchanged;
#   * BOTH drivers read every element kind back as the same 1-based `Vector{T}`, `T` being exactly
#     the type a scalar column of the same base field reads as (LibPQ hands most arrays back as raw
#     `{…}` text, Postgres.jl as typed vectors, and an array with a lower bound other than 1 as an
#     offset-indexed one);
#   * the bulk writers' `text[]`-of-literals source casts back to the column's array type;
#   * the catalog's defaults and types compile to the declaration, so `makemigrations` converges;
#   * the array lookups' one untyped literal is read as the column's array type, on both drivers.
#
# Run it under both PostgreSQL drivers — `PORMG_POSTGRES_DRIVER=Postgres` selects Postgres.jl (#788):
#
# Self-contained: the table is created by the planner from a model, scoped with `include_table`, and
# dropped in a `finally`, so the shared fixture never sees it and the file slices on a database that
# was bootstrapped before this table existed.
#
#   julia -t auto --project=test/integration test/integration/test_array_field.jl
#   PORMG_POSTGRES_DRIVER=Postgres julia -t auto --project=test/integration test/integration/test_array_field.jl
#   PORMG_DB=db_sl julia -t 1 --project=test/integration test/integration/test_array_field.jl
# ==============================================================================

if !isdefined(Main, :PormG)
    include("common_setup.jl")
end

import UUIDs, Decimals, TimeZones
import PormG.Migrations: LiveTable, read_live_schema, get_migration_plan, _order_statements,
                         _execute_statements_pg, field_from_spec, column_spec
import PormG.ConnectionPool: finalize_transaction_connection!
const _af28_tx = PormG.ConnectionPool.with_transaction

const AF28_TABLE = "pormg_af28_strategy"

_af28_settings() = (s = PormG.Configuration.Settings(); s.change_db = true; s)

# A race-strategy sheet: one array column per element kind, each beside a scalar column of the same
# base field, so a test can compare an element's read type with what the scalar reads as.
_af28_model() = Models.Model(AF28_TABLE;
    id        = Models.IDField(),
    label     = Models.CharField(max_length = 60, unique = true),
    compounds = Models.ArrayField(Models.CharField(max_length = 12, null = true); null = true),
    notes     = Models.ArrayField(Models.TextField(null = true); default = String[]),
    laps      = Models.ArrayField(Models.IntegerField(null = true); null = true),
    one_lap   = Models.IntegerField(null = true),
    sectors   = Models.ArrayField(Models.BigIntegerField(); null = true),
    one_sector = Models.BigIntegerField(null = true),
    ratios    = Models.ArrayField(Models.FloatField(); null = true),
    one_ratio = Models.FloatField(null = true),
    targets   = Models.ArrayField(Models.DecimalField(max_digits = 7, decimal_places = 3); null = true),
    one_target = Models.DecimalField(max_digits = 7, decimal_places = 3, null = true),
    quota     = Models.ArrayField(Models.DecimalField(max_digits = 5, decimal_places = 2); default = [1.5, 2]),
    flags     = Models.ArrayField(Models.BooleanField(); null = true),
    one_flag  = Models.BooleanField(null = true),
    days      = Models.ArrayField(Models.DateField(); null = true),
    one_day   = Models.DateField(null = true),
    stamps    = Models.ArrayField(Models.DateTimeField(); null = true),
    one_stamp = Models.DateTimeField(null = true),
    naive     = Models.ArrayField(Models.DateTimeField(type = "TIMESTAMP"); null = true),
    one_naive = Models.DateTimeField(type = "TIMESTAMP", null = true),
    ids       = Models.ArrayField(Models.UUIDField(); null = true),
    one_id    = Models.UUIDField(null = true))

function _af28_apply!(pool, plan)
    ordered, _ = _order_statements([plan[k] for k in keys(plan)])
    _, conn = _af28_tx(pool, "BEGIN;")
    try
        _execute_statements_pg(pool, ordered; conn = conn)
        _af28_tx(pool, "COMMIT;", conn = conn, release_conn = false)
    catch
        _af28_tx(pool, "ROLLBACK;", conn = conn, release_conn = false)
        rethrow()
    finally
        finalize_transaction_connection!(pool, conn)
    end
    return nothing
end

_af28_err(f) = try f(); nothing catch e; e end
_af28_utc(y, mo, d, h, mi, s, ms = 0) = TimeZones.ZonedDateTime(DateTime(y, mo, d, h, mi, s, ms), TimeZones.tz"UTC")

@testset "ArrayField, live ($(PORMG_DB_FOLDER)) (#28)" begin
    pool = PormG.config[PORMG_DB_FOLDER].connections
    is_pg = pool isa PormG.PormGPostgres
    drop() = try; PormG.ConnectionPool.fetch(pool, Dialect.drop_table(pool, AF28_TABLE)); catch; end

    model = _af28_model()
    model.connect_key = PORMG_DB_FOLDER
    schema = Dict{Symbol, Dict{Symbol, Union{Bool, PormG.PormGModel}}}(
        Symbol(AF28_TABLE) => Dict{Symbol, Union{Bool, PormG.PormGModel}}(:model => model, :exist => false))
    live() = read_live_schema(pool; include_table = [AF28_TABLE])

    # ─────────────────────────────────────────────────────────────────────
    # SQLite: the column is refused, and nothing is created
    # The planner refuses at `makemigrations`, before a plan exists — not part-way through a migration.
    # ─────────────────────────────────────────────────────────────────────
    if !is_pg
        @testset "SQLite refuses the column" begin
            drop()
            err = _af28_err(() -> get_migration_plan(LiveTable[], schema, pool, _af28_settings(); interactive = false))
            @test err isa PormG.BackendCapabilityError
            @test err !== nothing && occursin("PostgreSQL", sprint(showerror, err))
            @test isempty(live())
        end
    else
        drop()
        try
            _af28_apply!(pool, get_migration_plan(LiveTable[], schema, pool, _af28_settings(); interactive = false))
            # A fresh handler per query: a handler accumulates its filters.
            S() = model.objects

            # ─────────────────────────────────────────────────────────────────────
            # The column types, the defaults, and a schema that converges with its declaration
            # The catalog prints `character varying(12)[]`, `numeric(5,2)[]`, `'{1.50,2.00}'::numeric(5,2)[]`
            # — the reader maps each back to the declared kind and default, so the next makemigrations
            # proposes nothing. inspectdb's declaration compiles back to the same columns too.
            # ─────────────────────────────────────────────────────────────────────
            @testset "DDL, defaults and convergence" begin
                cols = only(live()).columns
                @test cols["compounds"].raw == "character varying(12)[]"
                @test cols["laps"].raw == "integer[]" && cols["sectors"].raw == "bigint[]"
                @test cols["targets"].raw == "numeric(7,3)[]"
                @test cols["stamps"].raw == "timestamp with time zone[]"
                @test cols["naive"].raw == "timestamp without time zone[]"
                @test cols["ids"].raw == "uuid[]"
                @test cols["laps"].type == PormG.CArray(PormG.CInt32())
                @test cols["quota"].default == PormG.Migrations.LiteralDefault("{1.5,2}")
                @test cols["notes"].default == PormG.Migrations.LiteralDefault("{}")
                @test isempty(get_migration_plan(live(), schema, pool, _af28_settings(); interactive = false))
                tbl = only(live())
                for (name, spec) in tbl.columns
                    spec.type isa PormG.CArray || continue
                    f = field_from_spec(spec, tbl, pool)
                    @test (name, f isa Models.sArrayField) == (name, true)
                    @test (name, column_spec(f, pool; name = name).type) == (name, spec.type)
                end
            end

            # ─────────────────────────────────────────────────────────────────────
            # Every element kind round-trips, as the scalar of the same base field reads
            # Written through `create`, read through `list` and through the row `create` returns.
            # ─────────────────────────────────────────────────────────────────────
            @testset "element kinds round-trip" begin
                u1, u2 = UUIDs.UUID("550e8400-e29b-41d4-a716-446655440000"), UUIDs.uuid4()
                st = _af28_utc(2024, 3, 2, 14, 0, 0, 250)
                ret = S().create("label" => "kinds",
                    "compounds" => ["SOFT", "MEDIUM"], "laps" => [12, 31], "one_lap" => 12,
                    "sectors" => [2^40], "one_sector" => 2^40,
                    "ratios" => [0.25, -1.5e10], "one_ratio" => 0.25,
                    "targets" => Any[Decimals.Decimal(0, 81500, -3), "1.25"], "one_target" => "81.500",
                    "flags" => [true, false], "one_flag" => true,
                    "days" => Any[Date(2024, 3, 2), "2024-03-09"], "one_day" => Date(2024, 3, 2),
                    "stamps" => Any[st, DateTime(2024, 3, 2, 12)], "one_stamp" => st,
                    "naive" => [DateTime(2024, 3, 2, 14, 30)], "one_naive" => DateTime(2024, 3, 2, 14, 30),
                    "ids" => Any[u1, string(u2)], "one_id" => u1)
                row = S().filter("label" => "kinds").list()[1]
                for got in (row, ret)
                    @test got["compounds"] == ["SOFT", "MEDIUM"]
                    @test got["notes"] == String[]                       # filled from the default
                    @test got["quota"] == [Decimals.Decimal(0, 15, -1), Decimals.Decimal(0, 2, 0)]
                    @test got["laps"] == [12, 31] && got["sectors"] == [2^40]
                    @test got["ratios"] == [0.25, -1.5e10]
                    @test got["targets"] == [Decimals.Decimal(0, 815, -1), Decimals.Decimal(0, 125, -2)]
                    @test got["flags"] == [true, false]
                    @test got["days"] == [Date(2024, 3, 2), Date(2024, 3, 9)]
                    @test got["stamps"] == [st, _af28_utc(2024, 3, 2, 12, 0, 0)]
                    @test got["naive"] == [DateTime(2024, 3, 2, 14, 30)]
                    @test got["ids"] == [string(u1), string(u2)]
                end
                # The element type is the scalar read's type — on whichever driver is running.
                for (arr, one) in (("laps", "one_lap"), ("sectors", "one_sector"), ("ratios", "one_ratio"),
                                   ("targets", "one_target"), ("flags", "one_flag"), ("days", "one_day"),
                                   ("stamps", "one_stamp"), ("naive", "one_naive"), ("ids", "one_id"))
                    @test (arr, eltype(row[arr])) == (arr, typeof(row[one]))
                    @test (arr, row[arr] isa Vector) == (arr, true)
                end
                @test row["stamps"][1] == row["one_stamp"]
                @test row["targets"][1] == row["one_target"]
            end

            # ─────────────────────────────────────────────────────────────────────
            # Text the literal syntax reserves, and NULLs
            # Each string must come back byte for byte: quoting, backslashes, braces, a quoted "NULL",
            # whitespace, the empty string. A NULL element reads as `missing`; a NULL column as `missing`.
            # ─────────────────────────────────────────────────────────────────────
            @testset "special text and NULLs" begin
                tricky = ["a b", "", " lead", "x,y", "{z}", "q\"t", "b\\s", "NULL", "null", "São Paulo", "tab\there"]
                S().create("label" => "tricky", "notes" => tricky, "compounds" => ["SOFT", nothing], "laps" => [nothing, 3])
                row = S().filter("label" => "tricky").list()[1]
                @test row["notes"] == tricky
                @test isequal(row["compounds"], ["SOFT", missing]) && eltype(row["compounds"]) == Union{Missing, String}
                @test isequal(row["laps"], [missing, 3])
                @test ismissing(row["targets"])
                # The server's own reading of what PormG sent: the right number of elements, the NULL a NULL.
                txt = PormG.ConnectionPool.fetch(pool, "SELECT cardinality(notes) AS n, compounds[2] IS NULL AS null2 " *
                                                       "FROM \"$AF28_TABLE\" WHERE label = 'tricky'") |> DataFrame
                @test txt.n[1] == length(tricky) && txt.null2[1] == true
                # A lower bound other than 1, written outside PormG, reads 1-based.
                PormG.ConnectionPool.fetch(pool, "UPDATE \"$AF28_TABLE\" SET laps = '[0:2]={7,8,9}'::integer[] WHERE label = 'tricky'")
                @test S().filter("label" => "tricky").values("laps").list()[1]["laps"] == [7, 8, 9]
            end

            # ─────────────────────────────────────────────────────────────────────
            # Filters, update and get_or_create
            # A vector is an equality against the whole array, bound as one literal.
            # ─────────────────────────────────────────────────────────────────────
            @testset "filters and writers" begin
                @test S().filter("compounds" => ["SOFT", "MEDIUM"]).values("label").list()[1]["label"] == "kinds"
                @test !S().filter("compounds" => ["MEDIUM", "SOFT"]).exists()       # order matters
                @test S().filter("notes" => String[]).count() == 1                    # only "kinds"
                @test S().filter(PormG.Q("laps" => [12, 31])).count() == 1
                @test S().filter("targets__@isnull" => true).count() == 1             # "tricky"
                @test _af28_err(() -> S().filter("compounds__@contains" => "SOFT").count()) isa PormG.FilterError

                S().filter("label" => "kinds").update("laps" => [1, 2, 3], "compounds" => String[])
                row = S().filter("label" => "kinds").values("laps", "compounds").list()[1]
                @test row["laps"] == [1, 2, 3] && row["compounds"] == String[]

                obj, created = S().get_or_create("label" => "kinds", "laps" => [1, 2, 3])
                @test !created
                # The array in `defaults` — its lookup is the UNIQUE `label`, the ON CONFLICT target.
                obj, created = S().get_or_create("label" => "goc"; defaults = ["laps" => [4]])
                @test created && S().filter("label" => "goc").values("laps").list()[1]["laps"] == [4]

                # Refused before the server sees it: an element the base field refuses, too many, a NULL.
                @test _af28_err(() -> S().create("label" => "bad", "compounds" => ["INTERMEDIATE!"])) isa PormG.InvalidValueError
                @test _af28_err(() -> S().create("label" => "bad", "sectors" => [1, nothing])) isa PormG.InvalidValueError
                @test !S().filter("label" => "bad").exists()
            end

            # ─────────────────────────────────────────────────────────────────────
            # The array lookups (#28, part 2)
            # What only the server can say: that the one untyped array literal each containment lookup
            # binds is read as the COLUMN's array type on this driver — text, numeric, date and uuid
            # elements alike — that `cardinality` is 0 for `{}` and NULL for NULL, and that an index or
            # a slice selects what the docs say, including past the end. Rows of their own, `lk-*`.
            # ─────────────────────────────────────────────────────────────────────
            @testset "lookups: containment, @len, index and slice" begin
                u1 = UUIDs.UUID("550e8400-e29b-41d4-a716-446655440000")
                S().create("label" => "lk-a", "compounds" => ["SOFT", "HARD"], "laps" => [12, 30, 45],
                           "notes" => ["a b", "x"], "days" => [Date(2024, 3, 2)], "targets" => ["81.5"],
                           "ids" => [u1])
                S().create("label" => "lk-b", "compounds" => ["MEDIUM"], "laps" => Int[])
                S().create("label" => "lk-c")                                    # NULL arrays
                S().create("label" => "lk-d", "compounds" => ["SOFT", "MEDIUM", "HARD"], "laps" => [30])
                # The labels a filter matches among the `lk-*` rows, sorted.
                lk(pairs...) = sort([r["label"] for r in S().filter("label__@startswith" => "lk-", pairs...).
                                                     values("label").list()])

                # Containment, overlap, and their empty-list answers.
                @test lk("compounds__@acontains" => ["SOFT"]) == ["lk-a", "lk-d"]
                @test lk("compounds__@acontains" => ["HARD", "SOFT"]) == ["lk-a", "lk-d"]   # any order
                @test lk("compounds__@acontains" => String[]) == ["lk-a", "lk-b", "lk-d"]   # not NULL
                @test lk("compounds__@contained_by" => ["SOFT", "MEDIUM"]) == ["lk-b"]
                @test lk("compounds__@contained_by" => ["SOFT", "MEDIUM", "HARD", "INTERMEDIATE", "WET"]) ==
                      ["lk-a", "lk-b", "lk-d"]
                @test lk("laps__@overlap" => [30, 99]) == ["lk-a", "lk-d"]
                @test isempty(lk("laps__@overlap" => Int[]))
                # The element kinds whose literal the server must type from the column: text with a
                # space, numeric (81.5 matches the stored 81.500), date and uuid.
                @test lk("notes__@acontains" => ["a b"]) == ["lk-a"]
                @test lk("targets__@acontains" => [Decimals.Decimal(0, 815, -1)]) == ["lk-a"]
                @test lk("days__@overlap" => [Date(2024, 3, 2), Date(2025, 1, 1)]) == ["lk-a"]
                @test lk("ids__@acontains" => [u1]) == ["lk-a"]

                # `@len`: 0 for the empty array, NULL for the NULL one, and a number in `values()`.
                @test lk("laps__@len" => 0) == ["lk-b"]
                @test lk("laps__@len__@gte" => 2) == ["lk-a"]
                n = S().filter("label" => "lk-a").values("n" => "laps__@len").list()[1]["n"]
                @test n == 3 && n isa Integer
                @test ismissing(S().filter("label" => "lk-c").values("n" => "laps__@len").list()[1]["n"])

                # Index: 0-based, an element of the element field's type, and NULL past the end.
                @test lk("laps__0" => 12) == ["lk-a"]
                @test lk("compounds__0" => "SOFT") == ["lk-a", "lk-d"]
                @test lk("compounds__0__@icontains" => "med") == ["lk-b"]
                @test lk("laps__2__@gt" => 40) == ["lk-a"]
                @test lk("laps__1__@isnull" => true) == ["lk-b", "lk-c", "lk-d"]
                row = S().filter("label" => "lk-a").values("compounds__0", "laps__1", "laps__0_2").list()[1]
                @test row["compounds__0"] == "SOFT"
                @test row["laps__1"] == 30 && row["laps__1"] isa Integer
                @test row["laps__0_2"] == [12, 30]
                ordered = S().filter("label__@in" => ["lk-a", "lk-d"]).order_by("-laps__0").values("label").list()
                @test [r["label"] for r in ordered] == ["lk-d", "lk-a"]                   # 30 before 12

                # Slice: an array, half-open, `{}` past the end.
                @test lk("laps__0_2" => [12, 30]) == ["lk-a"]
                @test lk("laps__1_3__@len" => 2) == ["lk-a"]
                @test lk("laps__5_9" => Int[]) == ["lk-a", "lk-b", "lk-d"]
                @test lk("compounds__0_2__@acontains" => ["HARD"]) == ["lk-a"]            # lk-d's HARD is third

                # A subscript is absolute: "tricky" holds `[0:2]={7,8,9}` (written above, outside PormG),
                # which reads back as [7, 8, 9], but its `__0` is subscript 1 — the 8.
                @test S().filter("label" => "tricky", "laps__0" => 8).exists()
            end

            # ─────────────────────────────────────────────────────────────────────
            # Bulk writers
            # Rows of different lengths, NULL arrays and NULL elements, across chunk boundaries: each
            # cell travels as its literal's text and is cast back to the column's array type.
            # ─────────────────────────────────────────────────────────────────────
            @testset "bulk writers" begin
                df = DataFrame(label = ["bulk-1", "bulk-2", "bulk-3"],
                               laps = Any[[1], Union{Nothing, Int}[2, nothing, 4], nothing],
                               notes = [["a b"], String[], ["{x}", "q\"t"]],
                               stamps = Any[[_af28_utc(2024, 1, 1, 0, 0, 0)], nothing, DateTime[]])
                bulk_insert(model, df; chunk_size = 2)
                got = S().filter("label__@in" => ["bulk-1", "bulk-2", "bulk-3"]).order_by("label").
                    values("label", "laps", "notes", "stamps").list()
                @test [r["laps"] for r in got[1:1]] == [[1]]
                @test isequal(got[2]["laps"], [2, missing, 4]) && ismissing(got[3]["laps"])
                @test [r["notes"] for r in got] == [["a b"], String[], ["{x}", "q\"t"]]
                @test got[1]["stamps"] == [_af28_utc(2024, 1, 1, 0, 0, 0)] && got[3]["stamps"] == TimeZones.ZonedDateTime[]

                ids = [r["id"] for r in S().filter("label__@in" => ["bulk-1", "bulk-2"]).order_by("label").values("id").list()]
                bulk_update(model, DataFrame(id = ids, laps = [[10, 11], Int[]]); columns = ["laps"])
                got = S().filter("label__@in" => ["bulk-1", "bulk-2"]).order_by("label").values("laps").list()
                @test [r["laps"] for r in got] == [[10, 11], Int32[]]

                bulk_copy(model, DataFrame(label = ["copy-1"], notes = [["a,b", "\"", "NULL", ""]], laps = [[5, 6]]))
                row = S().filter("label" => "copy-1").values("notes", "laps").list()[1]
                @test row["notes"] == ["a,b", "\"", "NULL", ""] && row["laps"] == [5, 6]

                # RETURNING reads the arrays back like `list` does.
                res = bulk_insert(model, DataFrame(label = ["ret-1"], laps = [[9, 9]]); returning = ["laps"])
                @test res.rows[1, "laps"] == [9, 9]
            end
        finally
            drop()
        end
    end
end
