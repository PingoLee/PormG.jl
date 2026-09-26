# =============================================================================
# A DecimalField is exact on SQLite, or refused (#648)
#
# SQLite has no exact decimal type. `DECIMAL(p, s)` takes NUMERIC affinity, which converts a value AS
# IT IS STORED to a 64-bit integer or a double — `1.000000000000000000001` stores as the integer `1`,
# with no error. A double keeps 15 significant digits exactly (`DBL_DIG`), so a `DECIMAL(p ≤ 15, s)`
# column holds every value write validation lets into it, and nothing wider is guaranteed to.
#
# The decision #648 records, in two halves:
#   * PormG refuses to CREATE a column SQLite cannot honour (`BackendCapabilityError` from the SQLite
#     `field_to_column`, which every DDL path shares). An existing wide column is left alone, and the
#     migration that narrows one still plans.
#   * What it does create reads back as the exact `Decimals.Decimal` that was written — the type
#     PostgreSQL already delivers — so `list(:json)` emits PostgreSQL's text, not `1.23456789e6`.
#
# Hermetic: mock connections for the renderers, temporary / in-memory SQLite for everything that
# executes. No live database.
# =============================================================================
# julia --project=test/integration test/unit/test_sqlite_decimal_648.jl

using Test
using Logging
using DataFrames
using PormG
# The end-to-end testsets open a real (temporary) SQLite file, so they need the weakdep extension.
# `runtests.jl` loads it for the whole suite; this guard is what makes the file runnable alone.
isdefined(Main, :SQLite) || include(joinpath(@__DIR__, "..", "load_drivers.jl"))
import PormG: Configuration, Migrations, Dialect, Models, BackendCapabilityError, CDecimal
import PormG.ConnectionPool: fetch, close_pool!, SQLiteConnectionPool

# Suffixed names: `runtests.jl` includes every unit file into ONE module. The renderers never touch
# the connection, so an empty subtype is all they need.
struct Dec648MockSQLite <: PormG.PormGSQLite end
struct Dec648MockPg <: PormG.PormGPostgres end

_dec648_ledger(amount) = Models.Model("ledger648",
    id     = Models.IDField(),
    amount = amount,
    note   = Models.CharField(max_length = 50, null = true))

# ─────────────────────────────────────────────────────────────────────────────
# Renderers: 15 digits is the boundary, on every SQLite DDL path
# `field_to_column` is the one site, and these are its three callers — so each is driven once, at
# 15 (renders) and at 16 (refused). PostgreSQL's `numeric` is exact at any width, so a width the
# consuming apps really declare (30) must still render there.
# ─────────────────────────────────────────────────────────────────────────────
@testset "SQLite refuses a DecimalField wider than 15 digits on every DDL path (#648)" begin
    sl = Dec648MockSQLite()
    @test Dialect.SQLITE_EXACT_DECIMAL_DIGITS == 15

    # The boundary itself: 15 is exact, so it renders; 16 is not, so it is refused.
    @test occursin("DECIMAL(15, 4)",
                   Dialect.field_to_column("amount", Models.DecimalField(max_digits = 15, decimal_places = 4), sl))
    @test_throws BackendCapabilityError Dialect.field_to_column("amount",
                   Models.DecimalField(max_digits = 16, decimal_places = 2), sl)

    # The message names the column, the width, and the way out — and carries the phrase the
    # upgrade note tells readers to grep their logs for.
    err = try
        Dialect.field_to_column("amount", Models.DecimalField(max_digits = 20, decimal_places = 2), sl)
        nothing
    catch e
        e
    end
    @test err isa BackendCapabilityError
    @test occursin("\"amount\"", err.msg)
    @test occursin("max_digits = 20", err.msg)
    @test occursin("SQLite has no exact decimal type", err.msg)
    @test occursin("max_digits <= 15", err.msg)

    # A `db_column` names the PHYSICAL column, as every other `field_to_column` message does.
    err_col = try
        Dialect.field_to_column("amount",
            Models.DecimalField(max_digits = 18, decimal_places = 2, db_column = "amount_eur"), sl)
        nothing
    catch e
        e
    end
    @test err_col isa BackendCapabilityError && occursin("\"amount_eur\"", err_col.msg)

    # The three callers, each through the shared renderer: CREATE TABLE, ADD COLUMN, and the table
    # rebuild that is also SQLite's ALTER.
    narrow = _dec648_ledger(Models.DecimalField(max_digits = 15, decimal_places = 2))
    wide   = _dec648_ledger(Models.DecimalField(max_digits = 16, decimal_places = 2))
    @test occursin("DECIMAL(15, 2)", Dialect.create_table(sl, narrow))
    @test_throws BackendCapabilityError Dialect.create_table(sl, wide)
    @test occursin("DECIMAL(15, 2)", Dialect.add_field(sl, "ledger648", "amount",
                                                       Models.DecimalField(max_digits = 15, decimal_places = 2)))
    @test_throws BackendCapabilityError Dialect.add_field(sl, "ledger648", "amount",
                                                          Models.DecimalField(max_digits = 16, decimal_places = 2))
    @test occursin("DECIMAL(15, 2)", Dialect.rebuild_table(sl, narrow))
    @test_throws BackendCapabilityError Dialect.rebuild_table(sl, wide)

    # Only a DecimalField is measured: a FloatField is a double by declaration, not a promise of
    # exact digits, so it has nothing to refuse.
    @test occursin("REAL", Dialect.field_to_column("ratio", Models.FloatField(), sl))

    # PostgreSQL is untouched.
    pg = Dec648MockPg()
    @test occursin("decimal(30, 6)",
                   Dialect.field_to_column("lat", Models.DecimalField(max_digits = 30, decimal_places = 6), pg))
end

# ─────────────────────────────────────────────────────────────────────────────
# The compiler never refuses: a wide column stays comparable on both sides
# `column_spec` compiles the DECLARED and the LIVE side through `_get_column_type`, not through
# `field_to_column`. A throw on the live side would block the very migration that narrows a wide
# column, so this pins that the refusal never reached the compiler — on either side of the diff.
# ─────────────────────────────────────────────────────────────────────────────
@testset "the migration compiler reads a wide SQLite decimal without refusing it (#648)" begin
    sl = Dec648MockSQLite()
    wide20 = Models.DecimalField(max_digits = 20, decimal_places = 2)
    narrow15 = Models.DecimalField(max_digits = 15, decimal_places = 2)

    spec = Migrations.column_spec(wide20, sl; name = "amount")
    @test spec.type == CDecimal(20, 2)
    @test spec.raw == "DECIMAL(20, 2)"

    # Both directions of a delta, and a whole table — no throw, and the width change is seen.
    @test !isempty(Migrations.column_delta(narrow15, wide20, sl; name = "amount").changed)
    @test !isempty(Migrations.column_delta(wide20, narrow15, sl; name = "amount").changed)
    live = Migrations.live_table(_dec648_ledger(wide20), sl)
    @test live.columns["amount"].type == CDecimal(20, 2)
end

# ─────────────────────────────────────────────────────────────────────────────
# Reading an existing schema never refuses (#648)
# inspectdb builds a model from the live catalog and renders no DDL, so a database created before
# this change — or by another tool — can still be imported. The model it emits keeps the real width;
# migrating THAT model is what gets refused.
# ─────────────────────────────────────────────────────────────────────────────
@testset "importing a wide SQLite DECIMAL column does not refuse (#648)" begin
    model = with_logger(NullLogger()) do
        Migrations.convertSQLToModel(
            "CREATE TABLE \"ledger648\" (\"id\" INTEGER PRIMARY KEY AUTOINCREMENT, \"amount\" DECIMAL(20, 2) NOT NULL);")
    end
    amount = model.fields["amount"]
    @test amount isa Models.sDecimalField
    @test amount.max_digits == 20 && amount.decimal_places == 2
end

# ── End to end, through `makemigrations` ─────────────────────────────────────────────────────────

function _dec648_write_models(path::AbstractString; max_digits::Int, note_length::Int = 50, extra::Bool = false)
    extra_line = extra ? "    memo = Models.CharField(max_length = 20, null = true),\n" : ""
    write(path, "module models\nimport PormG.Models\n" *
                "Ledger648 = Models.Model(\n    id = Models.IDField(),\n" *
                "    amount = Models.DecimalField(max_digits = $(max_digits), decimal_places = 2),\n" *
                extra_line *
                "    note = Models.CharField(max_length = $(note_length), null = true)\n)\nend\n")
end

_dec648_quiet(f) = with_logger(f, NullLogger())

# Runs `f(pool, settings, models_path, pending)` inside a throwaway folder and SQLite file.
function _dec648_sandbox(f, tag::AbstractString)
    dir = mktempdir()
    pool = nothing
    try
        cd(dir) do
            folder = "db648$(tag)"
            mkpath(folder)
            # Absolute: `makemigrations` `include`s it, and a relative include resolves against the
            # including source file, not the working directory.
            models_path = joinpath(dir, folder, "models.jl")
            pending = joinpath(folder, "migrations", "pending_migrations.jl")
            pool = SQLiteConnectionPool(joinpath(dir, "d648$(tag).sqlite"); pool_size = 1)
            settings = Configuration.Settings(connections = pool, db_def_folder = folder)
            settings.change_db = true
            f(pool, settings, models_path, pending)
        end
    finally
        pool === nothing || close_pool!(pool)
        rm(dir; recursive = true, force = true)
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# makemigrations refuses a new wide column before writing a plan (#648)
# The planner renders DDL at plan time, so the refusal surfaces at `makemigrations` — with the
# typed error, not a warning a catch-all turned it into — and no pending file is left for a
# `migrate` to apply half of.
# ─────────────────────────────────────────────────────────────────────────────
@testset "makemigrations refuses a new DecimalField wider than 15 digits (#648)" begin
    _dec648_sandbox("a") do pool, settings, models_path, pending
        _dec648_write_models(models_path; max_digits = 16)
        @test_throws BackendCapabilityError _dec648_quiet(() ->
            Migrations.makemigrations(pool, settings; path = models_path, interactive = false))
        @test !isfile(pending)

        # 15 is the widest SQLite honours, and it plans.
        _dec648_write_models(models_path; max_digits = 15)
        _dec648_quiet(() -> Migrations.makemigrations(pool, settings; path = models_path, interactive = false))
        @test isfile(pending) && occursin("DECIMAL(15, 2)", read(pending, String))
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# An existing wide column: untouched until PormG would re-create it (#648)
# The table is built exactly as PormG rendered it before this change — the same DDL with the old
# width — so this is the database an upgrading SQLite app has. Four things must hold at once: an
# unchanged model plans nothing (no churn), a bare ADD COLUMN plans (no rebuild, so nothing
# re-creates the wide column), a change that REBUILDS the table is refused (the rebuild would
# re-create it), and narrowing the width plans — and applies — the rebuild that fixes it.
# ─────────────────────────────────────────────────────────────────────────────
@testset "an existing wide SQLite decimal column is left alone until it would be re-created (#648)" begin
    _dec648_sandbox("b") do pool, settings, models_path, pending
        # What a pre-#648 PormG created: today's DDL for the same model at width 15, widened back.
        legacy_ddl = replace(Dialect.create_table(pool, _dec648_ledger(Models.DecimalField(max_digits = 15, decimal_places = 2))),
                             "DECIMAL(15, 2)" => "DECIMAL(20, 2)")
        @test occursin("DECIMAL(20, 2)", legacy_ddl)
        fetch(pool, legacy_ddl)
        fetch(pool, "INSERT INTO ledger648 (amount, note) VALUES ('12345.67', 'kept');")
        plan!() = _dec648_quiet(() -> Migrations.makemigrations(pool, settings; path = models_path, interactive = false))

        # Unchanged model: both sides compile to `CDecimal(20, 2)`, so there is nothing to plan.
        _dec648_write_models(models_path; max_digits = 20)
        plan!()
        @test !isfile(pending)

        # A nullable, defaultless column is a bare `ADD COLUMN` on SQLite — no rebuild, no refusal.
        _dec648_write_models(models_path; max_digits = 20, extra = true)
        plan!()
        @test isfile(pending) && occursin("ADD COLUMN", read(pending, String))
        rm(pending)

        # Changing ANOTHER column rebuilds the table, and a rebuild re-creates every column — so the
        # wide one is refused even though it did not change. The message says so.
        _dec648_write_models(models_path; max_digits = 20, note_length = 80)
        err = try
            plan!()
            nothing
        catch e
            e
        end
        @test err isa BackendCapabilityError
        @test occursin("rebuilds a SQLite table", err.msg)
        @test !isfile(pending)

        # The remedy the message names: narrow the width in that same change. It rides the same
        # rebuild, which renders only the DESIRED model — so the live `DECIMAL(20, 2)` never throws.
        _dec648_write_models(models_path; max_digits = 15, note_length = 80)
        plan!()
        @test isfile(pending)
        plan_text = read(pending, String)
        @test occursin("DECIMAL(15, 2)", plan_text) && !occursin("DECIMAL(20, 2)", plan_text)

        # And it applies. A rebuild drops the old table, so the destructive guard asks for consent.
        _dec648_quiet(() -> Migrations.migrate(pool, settings; interactive = false, destructive = true))
        info = DataFrame(fetch(pool, "PRAGMA table_info(ledger648);"))
        @test only(info[info.name .== "amount", :type]) == "DECIMAL(15, 2)"
        row = DataFrame(fetch(pool, "SELECT amount, note FROM ledger648;"))
        @test only(row.note) == "kept"
        @test only(row.amount) == 12345.67
    end
end

# ── The read half: what PormG creates reads back exact ───────────────────────────────────────────

const _D648_D = PormG.QueryBuilder.Decimals   # through PormG: `Decimals` is not in `[targets].test`
const _D648_KEY = normpath(joinpath(@__DIR__, "pormg648_dec"))
const _D648_POOL = SQLiteConnectionPool(":memory:"; pool_size = 1)
PormG.config[_D648_KEY] = Configuration.Settings(
    connections = _D648_POOL, change_data = true, db_def_folder = _D648_KEY)

# `v` is the widest column SQLite honours at scale 4. `Legacy` is declared at a width PormG now
# refuses to CREATE — its table is built by hand below, the way an older PormG or another tool left it.
PormG.@models_module Dec648 "pormg648_dec" begin
    Amount = Models.Model("dec648_amount",
        id    = Models.IDField(),
        label = Models.CharField(max_length = 40),
        v     = Models.DecimalField(max_digits = 15, decimal_places = 4, null = true))
    Legacy = Models.Model("dec648_legacy",
        id = Models.IDField(),
        v  = Models.DecimalField(max_digits = 20, decimal_places = 2, null = true))
end
import .Dec648 as D648

# DDL through PormG's own renderer, so the column under test is the one a migration creates.
fetch(_D648_POOL, Dialect.create_table(_D648_POOL, D648.Amount))
# The legacy table: today's DDL for the same shape at width 15, widened back to what `Legacy` declares.
fetch(_D648_POOL, replace(Dialect.create_table(_D648_POOL,
        Models.Model("dec648_legacy", id = Models.IDField(),
                     v = Models.DecimalField(max_digits = 15, decimal_places = 2, null = true))),
    "DECIMAL(15, 2)" => "DECIMAL(20, 2)"))

_d648_parts(d) = (Int(d.s), d.c, Int(d.q))

# ─────────────────────────────────────────────────────────────────────────────
# Every read terminal hands back the written Decimal (#648)
# One value per way a decimal reaches the column — a String, a `Decimal`, a `Float64`, an integer —
# and one per shape SQLite stores it in (INTEGER for a whole value, REAL otherwise). Each read
# terminal is asserted, because each consults the parsers through its own path: `list()` and
# `list(:dict)` through `_list_raw`, `DataFrame` separately (#582), and the wildcard through the
# `SELECT *` recorder rather than a named projection.
# ─────────────────────────────────────────────────────────────────────────────
@testset "a SQLite DecimalField reads back as the Decimal that was written (#648)" begin
    written = [
        ("str15",   "12345678901.2345",              (0, 123456789012345, -4)),  # 15 digits, as text
        ("dec15",   _D648_D.Decimal(1, 999999999999999, -4), (1, 999999999999999, -4)),
        ("float",   1234567.89,                      (0, 123456789, -2)),        # was 1.23456789e6 in JSON
        ("whole",   14,                              (0, 14, 0)),                # stored as INTEGER
        ("tenth",   0.1,                             (0, 1, -1)),                # bound as "%.17g" text
    ]
    for (label, value, _) in written
        D648.Amount.objects.create("label" => label, "v" => value)
    end
    expected = Dict(label => parts for (label, _, parts) in written)

    q() = D648.Amount.objects.filter("label__@in" => first.(written)).order_by("id")

    # list() — the row terminal, and the one `get()`/`first()` go through.
    for r in q().values("label", "v").list()
        @test r[:v] isa _D648_D.Decimal
        @test _d648_parts(r[:v]) == expected[r[:label]]
    end
    # list(:dict), DataFrame, and the wildcard — three more routes to the same parser.
    @test all(d -> d[:v] isa _D648_D.Decimal, q().values("label", "v").list(:dict))
    df = DataFrame(q().values("label", "v"))
    @test all(v -> v isa _D648_D.Decimal, df.v)
    @test all(r -> r[:v] isa _D648_D.Decimal, q().list())
    @test all(r -> r[:v] isa _D648_D.Decimal, q().values("*").list())

    # list(:json) now emits PostgreSQL's text for the same values: exact digits, as numbers.
    json = D648.Amount.objects.filter("label__@in" => ["float", "whole", "tenth"]).
        values("v").order_by("id").list(:json)
    @test json == "[{\"v\":1234567.89},{\"v\":14},{\"v\":0.1}]"
end

# ─────────────────────────────────────────────────────────────────────────────
# The premise, measured: 15 significant digits survive SQLite's storage (#648)
# The parser is exact only if SQLite's text->double conversion keeps every 15-digit value distinct.
# SQLite documents about 15.95 digits; this checks it on the linked library across 500 values
# spread over the column's whole range, with the fractional digits populated. A failure here shows up
# as a `Float64` coming back (the parser declines what it cannot prove), never as a wrong Decimal —
# which is also what makes it the right thing to measure rather than assume.
# ─────────────────────────────────────────────────────────────────────────────
@testset "every 15-digit value round-trips through SQLite storage exactly (#648)" begin
    # Deterministic spread, no RNG: a large odd multiplier mod 10^15 walks the coefficient range.
    coeffs = [mod(BigInt(i) * 7_919_000_003_311 + 1_234_567_890_123, BigInt(10)^15) for i in 1:500]
    values = [_D648_D.Decimal(isodd(i) ? 1 : 0, c, -4) for (i, c) in enumerate(coeffs)]
    PormG.bulk_insert(D648.Amount.objects,
        DataFrame(label = fill("sweep", length(values)), v = values))

    rows = D648.Amount.objects.filter("label" => "sweep").values("v").order_by("id").list()
    @test length(rows) == length(values)
    back = [r[:v] for r in rows]
    @test count(v -> !(v isa _D648_D.Decimal), back) == 0
    @test count(i -> back[i] != values[i], eachindex(values)) == 0
end

# ─────────────────────────────────────────────────────────────────────────────
# A column wider than 15 digits keeps its raw cells (#648)
# PormG will not create one, but one can exist. SQLite may already have rounded what it holds, so
# rebuilding a Decimal from it would present a guess as an exact value. No parser runs: the cell
# arrives as SQLite stored it, exactly as before this change.
# ─────────────────────────────────────────────────────────────────────────────
@testset "a wider-than-15-digit SQLite column reads raw, not as a guessed Decimal (#648)" begin
    fetch(_D648_POOL, "INSERT INTO dec648_legacy (v) VALUES ('12345678901234567.89'), ('14'), ('0.5');")
    back = [r[:v] for r in D648.Legacy.objects.values("v").order_by("id").list()]
    @test !any(v -> v isa _D648_D.Decimal, back)
    @test back[2] === 14 && back[3] === 0.5
end
