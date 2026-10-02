# =============================================================================
# Shipping a reviewed plan: the schema precondition, and failed rows a retry resolved (#739)
#
# `migrate()` applied whatever `pending_migrations.jl` sat on disk, to whatever database it was
# pointed at. Nothing checked that the database still held the schema the plan was diffed against,
# so a plan generated on one database could run half-way on another, and a plan baked into an old
# release replayed after a newer one had moved past it. The #81 guard catches only the LATEST
# applied plan, on purpose: a legitimate drop-then-re-add regenerates byte-identical SQL.
#
# `makemigrations` now records, in the plan header, a fingerprint of every table its diff compared —
# `absent` for one that did not exist yet — and `migrate` refuses on any difference before a
# statement runs: once before the lock, and again, deciding, inside it. `status()` moves a `failed` row whose plan a later run applied into
# `superseded`, so its drift signal clears.
#
# Hermetic: temporary SQLite files and folders. No live database.
# =============================================================================
# julia --project=test/integration test/unit/test_plan_schema_fingerprint.jl

using Test
using Logging
using DataFrames
using PormG
# The end-to-end testsets open real (temporary) SQLite files, so they need the weakdep extension.
isdefined(Main, :SQLite) || include(joinpath(@__DIR__, "..", "load_drivers.jl"))
import PormG: Configuration, Migrations, InvalidMigrationError
import PormG: ColumnSpec, CInt64, CText, CVarChar, NoDefault, LiteralDefault, CheckKind, NonNegativeCheck
import PormG.Migrations: LiveTable, LiveComposite, LiveCheck, PlanPreconditionError
import PormG.ConnectionPool: fetch, close_pool!, SQLiteConnectionPool
import OrderedCollections: OrderedDict
import TimeZones: ZonedDateTime, @tz_str
import Dates: DateTime

# `migrate` and `makemigrations` report through the logger; the assertions read results and files.
_ps739_quiet(f) = with_logger(f, NullLogger())

# One column, with every slot the fingerprint reads spelled out so a test can vary one at a time.
_ps739_col(name; type = CInt64(), nullable = false, pk = false, unique = false, default = NoDefault(),
           checks = CheckKind[], raw = "BIGINT") =
    ColumnSpec(name, type, nullable, pk, unique, default, nothing, checks, nothing, raw)

# A two-column `drivers` table, the base every fingerprint variation below starts from.
function _ps739_table(; columns = [_ps739_col("driverid"; pk = true),
                                   _ps739_col("surname"; type = CVarChar(250), raw = "VARCHAR(250)")],
                      indexes = Dict{String, Union{String, Nothing}}(),
                      composites = LiveComposite[], checks = LiveCheck[])
    LiveTable("drivers", OrderedDict{String, ColumnSpec}(c.name => c for c in columns), indexes, composites, checks)
end

# A models file for `makemigrations`: one F1 table per entry, each with an id and a name column, plus
# whatever extra field source `extra` adds to the first one.
function _ps739_write_models(path::AbstractString, tables::Vector{String}; extra::String = "")
    body = join(["$(t) = Models.Model(\n    id = Models.IDField(),\n    name = Models.CharField(null = true)" *
                 (i == 1 ? extra : "") * "\n)\n" for (i, t) in enumerate(tables)], "")
    write(path, "module models\nimport PormG.Models\n" * body * "end\n")
end

# The history table's rows, straight from SQLite.
_ps739_history(pool) = DataFrame(fetch(pool, "SELECT version, status FROM pormg_migrations ORDER BY version;"))

# A fresh temporary SQLite project — the `test_migrate_outcome.jl` shape. `pool_size = 1`, so a
# transaction connection that leaked back to the pool, or one that was never released, deadlocks
# the next statement instead of passing unnoticed.
function _ps739_project(f, tag::String)
    dir = mktempdir()
    pool = nothing
    try
        cd(dir) do
            mkpath(tag)
            pool = SQLiteConnectionPool(joinpath(dir, "$(tag).sqlite"); pool_size = 1)
            settings = Configuration.Settings(connections = pool, db_def_folder = tag)
            settings.change_db = true
            f(pool, settings, joinpath(dir, tag, "models.jl"), joinpath(tag, "migrations", "pending_migrations.jl"))
        end
    finally
        pool === nothing || close_pool!(pool)
        rm(dir; recursive = true, force = true)
    end
end

_ps739_makemigrations(pool, settings, models_path) =
    _ps739_quiet(() -> Migrations.makemigrations(pool, settings; path = models_path, interactive = false))
_ps739_migrate(pool, settings) = _ps739_quiet(() -> Migrations.migrate(pool, settings; interactive = false))

# The exception `f` raises, or `nothing` when it returns.
_ps739_raised(f) = try f(); nothing catch e; e end

# ─────────────────────────────────────────────────────────────────────────────
# The fingerprint: one stable digest per table, of what the planner diffs
# It is persisted in a plan and compared in another process, so it is pinned to an exact value here:
# a change to the serialization changes every fingerprint and refuses every plan generated before
# it, which must be a deliberate, upgrade-logged decision — not a side effect of adding a slot to an
# IR struct. Every compared facet must move it; the catalog's spelling of the type and the physical
# column order must not.
# ─────────────────────────────────────────────────────────────────────────────
@testset "the fingerprint is a stable digest of the compared facets (#739)" begin
    base = Migrations._schema_table_fingerprint(_ps739_table())
    # Pinned: computed once and frozen. If this moves, bump `_SCHEMA_FINGERPRINT_VERSION` and say so
    # in the upgrade log — every reviewed plan in flight is refused by the change.
    @test base == "c02757aa87bdf95c"
    @test occursin(r"^[0-9a-f]{16}$", base)
    @test Migrations._schema_table_fingerprint(nothing) == "absent"

    # Not part of it: the catalog's raw type text, and the physical column order (an SQLite rebuild
    # can change the order without changing the schema).
    respelled = _ps739_table(columns = [_ps739_col("driverid"; pk = true, raw = "bigint"),
                                        _ps739_col("surname"; type = CVarChar(250), raw = "character varying(250)")])
    @test Migrations._schema_table_fingerprint(respelled) == base
    reordered = _ps739_table(columns = [_ps739_col("surname"; type = CVarChar(250), raw = "VARCHAR(250)"),
                                        _ps739_col("driverid"; pk = true)])
    @test Migrations._schema_table_fingerprint(reordered) == base

    # Part of it: each facet below is a different schema for a plan to run on.
    surname(; kw...) = _ps739_col("surname"; type = CVarChar(250), raw = "VARCHAR(250)", kw...)
    variants = Dict(
        "type"       => _ps739_table(columns = [_ps739_col("driverid"; pk = true), _ps739_col("surname"; type = CText())]),
        "length"     => _ps739_table(columns = [_ps739_col("driverid"; pk = true), _ps739_col("surname"; type = CVarChar(100))]),
        "nullable"   => _ps739_table(columns = [_ps739_col("driverid"; pk = true), surname(nullable = true)]),
        "unique"     => _ps739_table(columns = [_ps739_col("driverid"; pk = true), surname(unique = true)]),
        "default"    => _ps739_table(columns = [_ps739_col("driverid"; pk = true), surname(default = LiteralDefault("Senna"))]),
        "check"      => _ps739_table(columns = [_ps739_col("driverid"; pk = true, checks = CheckKind[NonNegativeCheck()]), surname()]),
        "rename"     => _ps739_table(columns = [_ps739_col("driverid"; pk = true), _ps739_col("family_name"; type = CVarChar(250))]),
        "new column" => _ps739_table(columns = [_ps739_col("driverid"; pk = true), surname(), _ps739_col("code"; type = CText())]),
        "index"      => _ps739_table(indexes = Dict{String, Union{String, Nothing}}("surname" => "drivers_surname_idx")),
        "composite"  => _ps739_table(composites = [LiveComposite("drivers_uniq", ["driverid", "surname"], true, true)]),
        "table check"=> _ps739_table(checks = [LiveCheck("drivers_ck", "driverid > 0", nothing)]),
    )
    for (facet, t) in variants
        @test (facet, Migrations._schema_table_fingerprint(t)) != (facet, base)
    end
    # A timestamp default is written as its UTC wall time, never through `repr` (which is TimeZones'
    # to change): it digests, and two instants are two defaults.
    at(t) = Migrations._schema_table_fingerprint(_ps739_table(columns = [_ps739_col("driverid"; pk = true),
        surname(default = LiteralDefault(ZonedDateTime(t, tz"UTC")))]))
    @test occursin(r"^[0-9a-f]{16}$", at(DateTime(1988, 4, 3)))
    @test at(DateTime(1988, 4, 3)) != at(DateTime(1988, 4, 3, 0, 0, 1))
    # A literal default carries its type: `0` and `"0"` are two defaults.
    @test Migrations._schema_table_fingerprint(_ps739_table(columns = [_ps739_col("driverid"; pk = true), surname(default = LiteralDefault(0))])) !=
          Migrations._schema_table_fingerprint(_ps739_table(columns = [_ps739_col("driverid"; pk = true), surname(default = LiteralDefault("0"))]))
end

# ─────────────────────────────────────────────────────────────────────────────
# The header: written by the generator, read back by line scan, outside the checksum
# Additive within format v1: the plan still parses as data (#710), its checksum covers only the
# ordered SQL, and a plan without the lines reads back as "no precondition". A table name with a tab
# or a newline is escaped, so it cannot end the field or the comment.
# ─────────────────────────────────────────────────────────────────────────────
@testset "the schema header round-trips and stays outside the checksum (#739)" begin
    dir = mktempdir()
    try
        plan = OrderedDict{Symbol, OrderedDict{String, String}}(
            :drivers => OrderedDict{String, String}("New model drivers" => "CREATE TABLE \"drivers\" (\"driverid\" INTEGER);"))
        tables = OrderedDict{String, String}("circuits" => "absent", "drivers" => "0123456789abcdef",
                                             "odd\tname\nimport x" => "fedcba9876543210")
        PormG.Generator.generate_migration_plan("with.jl", plan, dir; schema_tables = tables)
        PormG.Generator.generate_migration_plan("without.jl", plan, dir)
        with_path, without_path = joinpath(dir, "with.jl"), joinpath(dir, "without.jl")

        @test Migrations._plan_schema_tables(with_path) == tables
        @test Migrations._plan_schema_tables(without_path) === nothing
        # The escaped name stays on its one header line: no line of the file starts `import x`.
        @test !any(l -> startswith(l, "import x"), readlines(with_path))
        # Same statements, same checksum: the header is not part of what was applied.
        sql(p) = last(Migrations._order_statements(Migrations._read_migration_plan(p)))
        @test Migrations.compute_checksum(sql(with_path)) == Migrations.compute_checksum(sql(without_path))
        # The format marker is still the line right under `module`.
        @test readlines(with_path)[2] == "# pormg-migration-format: $(Migrations.MIGRATION_FORMAT_VERSION)"

        # A damaged line is refused, not dropped — dropping it would apply the plan unchecked.
        lines = readlines(with_path)
        # A line that only LOOKS like one — indented, re-spaced — is refused too: skipping it would be
        # the same silent drop, and skipping all of them would apply the plan unchecked.
        for (what, bad) in (("not hex", "# pormg-schema-table: 0123456789abcdeZ\tdrivers"),
                            ("no tab", "# pormg-schema-table: 0123456789abcdef drivers"),
                            ("twice", "# pormg-schema-table: absent\tdrivers"),
                            ("indented", "  # pormg-schema-table: absent\tpits"),
                            ("re-spaced", "#pormg-schema-table:absent\tpits"))
            damaged = joinpath(dir, "damaged.jl")
            write(damaged, join(vcat(lines[1:2], [bad], lines[3:end]), "\n") * "\n")
            @test (what, _ps739_raised(() -> Migrations._plan_schema_tables(damaged)) isa InvalidMigrationError) == (what, true)
        end
    finally
        rm(dir; recursive = true, force = true)
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# makemigrations stamps the tables its diff compared
# Every managed declared table — `absent` until it exists — and every live table the planner read.
# A table the database holds outside the models is compared too (the plan drops it), so it is
# recorded; an unmanaged one is not, because the plan never touches it.
# ─────────────────────────────────────────────────────────────────────────────
@testset "makemigrations records the diffed tables in the header (#739)" begin
    _ps739_project("db739m") do pool, settings, models_path, pending
        _ps739_write_models(models_path, ["Circuit739"])
        _ps739_makemigrations(pool, settings, models_path)
        recorded = Migrations._plan_schema_tables(pending)
        @test recorded == OrderedDict("circuit739" => "absent")

        # Applied, the table exists; a second declared table is new, so it is recorded absent while
        # the first carries its live fingerprint.
        @test _ps739_migrate(pool, settings).outcome === :applied
        _ps739_write_models(models_path, ["Circuit739", "Driver739"])
        _ps739_makemigrations(pool, settings, models_path)
        recorded = Migrations._plan_schema_tables(pending)
        @test collect(keys(recorded)) == ["circuit739", "driver739"]
        @test recorded["driver739"] == "absent"
        @test occursin(r"^[0-9a-f]{16}$", recorded["circuit739"])
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# The scope is what the diff compared — not more, not less
# A live table the models do not declare is compared (the plan drops it), so its fingerprint is
# recorded; a many-to-many join table is declared by synthesis, so it is recorded `absent` until it
# exists; an unmanaged model's table is never touched by the plan, so it is not recorded even though
# it is live.
# ─────────────────────────────────────────────────────────────────────────────
@testset "the recorded scope: undeclared live, join table, unmanaged (#739)" begin
    _ps739_project("db739k") do pool, settings, models_path, pending
        fetch(pool, "CREATE TABLE scratch739 (id INTEGER PRIMARY KEY);")     # live, undeclared
        fetch(pool, "CREATE TABLE legacy739 (id INTEGER PRIMARY KEY);")      # live, unmanaged below
        write(models_path, "module models\nimport PormG.Models\n" *
            "Circuit739 = Models.Model(\n    id = Models.IDField(),\n    name = Models.CharField(null = true)\n)\n" *
            "Driver739 = Models.Model(\n    id = Models.IDField(),\n    circuits = Models.ManyToManyField(Circuit739)\n)\n" *
            "Legacy739 = Models.Model(\"legacy739\"; managed = false, id = Models.IDField())\n" *
            "end\n")
        _ps739_makemigrations(pool, settings, models_path)
        recorded = Migrations._plan_schema_tables(pending)

        @test occursin(r"^[0-9a-f]{16}$", get(recorded, "scratch739", ""))
        @test !haskey(recorded, "legacy739")
        @test recorded["circuit739"] == "absent" && recorded["driver739"] == "absent"
        # The synthesized join table: whatever it is named, it is the one recorded name left over.
        join_tables = setdiff(keys(recorded), ["scratch739", "circuit739", "driver739"])
        @test length(join_tables) == 1 && recorded[only(join_tables)] == "absent"
        @test occursin("circuits", only(join_tables))
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# migrate refuses a plan the database has moved away from
# The plan adds a column; before it runs, someone alters the same table out of band. Without the
# precondition the ADD COLUMN still succeeds — on a schema nobody reviewed it against. With it, the
# plan is refused naming the table, nothing is written, no `failed` row is recorded, and the plan is
# left in place. Deleting the header lines is the documented way through.
# ─────────────────────────────────────────────────────────────────────────────
@testset "a drifted table refuses the plan; without the header it applies (#739)" begin
    _ps739_project("db739d") do pool, settings, models_path, pending
        _ps739_write_models(models_path, ["Circuit739"])
        _ps739_makemigrations(pool, settings, models_path)
        @test _ps739_migrate(pool, settings).outcome === :applied

        _ps739_write_models(models_path, ["Circuit739"]; extra = ",\n    country = Models.CharField(null = true)")
        _ps739_makemigrations(pool, settings, models_path)
        fetch(pool, "ALTER TABLE circuit739 ADD COLUMN location TEXT;")   # the out-of-band change

        e = _ps739_raised(() -> _ps739_migrate(pool, settings))
        @test e isa PlanPreconditionError
        @test [t.table for t in e.tables] == ["circuit739"]
        @test occursin("circuit739: differs", sprint(showerror, e))
        h = _ps739_history(pool)
        @test nrow(h) == 1 && all(==("applied"), h.status)   # no `failed` row: nothing was attempted
        @test isfile(pending)

        # The way through: remove the precondition lines, and the plan applies as before #739.
        write(pending, join(filter(l -> !startswith(l, Migrations.SCHEMA_TABLE_HEADER), readlines(pending)), "\n") * "\n")
        @test _ps739_migrate(pool, settings).outcome === :applied
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# The refusal comes before migrate writes anything at all
# On a fresh database the plan creates a table; the table appears before `migrate` runs. The early
# check refuses before the history table is even created — before the row pre-check and the
# confirmation prompt, which would otherwise read or ask about a schema the plan does not describe.
# A table created out of band that the plan never compared does not block it.
# ─────────────────────────────────────────────────────────────────────────────
@testset "the refusal precedes every write; an unrelated table does not refuse (#739)" begin
    _ps739_project("db739e") do pool, settings, models_path, pending
        _ps739_write_models(models_path, ["Circuit739"])
        _ps739_makemigrations(pool, settings, models_path)
        fetch(pool, "CREATE TABLE circuit739 (id INTEGER PRIMARY KEY);")

        e = _ps739_raised(() -> _ps739_migrate(pool, settings))
        @test e isa PlanPreconditionError
        @test only(e.tables).table == "circuit739" && only(e.tables).expected == "absent"
        @test occursin(r"^[0-9a-f]{16}$", only(e.tables).found)
        @test occursin("did not exist when the plan was generated", sprint(showerror, e))
        # Mutation gate for the early check: the in-lock check alone runs after `init_migrations`.
        @test !Migrations._migrations_table_exists(pool)

        fetch(pool, "DROP TABLE circuit739;")
        fetch(pool, "CREATE TABLE scratch_unrelated739 (id INTEGER PRIMARY KEY);")
        @test _ps739_migrate(pool, settings).outcome === :applied
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# An old plan cannot replay after a newer one moved the database on (failure mode 2)
# Release N ships P1 (create circuits); release N+1 ships P2 (create drivers). An instance still on
# release N restarts with P1 as its pending file. The #81 guard does not see it — P2 is the latest
# applied — so before #739 P1 re-ran. Its precondition says circuits was absent, and now it is not.
# And the #81 case itself still wins: the latest applied plan, back as pending, is archived as
# `:already_applied`, never refused, although its own apply changed its tables.
# ─────────────────────────────────────────────────────────────────────────────
@testset "a stale plan is refused; the latest applied one still archives (#739)" begin
    _ps739_project("db739r") do pool, settings, models_path, pending
        applied_dir = joinpath("db739r", "migrations", "applied_migrations")
        _ps739_write_models(models_path, ["Circuit739"])
        _ps739_makemigrations(pool, settings, models_path)
        p1 = read(pending, String)
        @test _ps739_migrate(pool, settings).outcome === :applied

        _ps739_write_models(models_path, ["Circuit739", "Driver739"])
        _ps739_makemigrations(pool, settings, models_path)
        p2 = read(pending, String)
        @test _ps739_migrate(pool, settings).outcome === :applied

        # The latest applied plan back as pending: the #81 path, not a refusal.
        write(pending, p2)
        @test _ps739_migrate(pool, settings).outcome === :already_applied

        # The older one: refused, and nothing recorded.
        write(pending, p1)
        e = _ps739_raised(() -> _ps739_migrate(pool, settings))
        @test e isa PlanPreconditionError
        @test [t.table for t in e.tables] == ["circuit739"]
        @test nrow(_ps739_history(pool)) == 2
        @test isfile(pending)
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# The check that decides runs inside the write transaction
# The early check is only a diagnosis: another process can change the schema between it and the
# lock. So the lifecycle checks again after the #81 guard, inside `BEGIN IMMEDIATE`, on the
# transaction's own connection. Called directly here, past the early check. A refusal rolls back
# without a `failed` row, and the one-connection pool must still serve the next statement — a read
# that took a second connection would deadlock, and one that released the transaction's would leak it.
# ─────────────────────────────────────────────────────────────────────────────
@testset "the in-transaction check refuses on its own, and releases its connection (#739)" begin
    _ps739_project("db739t") do pool, settings, models_path, pending
        _ps739_write_models(models_path, ["Circuit739"])
        _ps739_makemigrations(pool, settings, models_path)
        stmts, all_sql = Migrations._order_statements(Migrations._load_migration_plan(settings))
        Migrations.init_migrations(pool)
        fetch(pool, "CREATE TABLE circuit739 (id INTEGER PRIMARY KEY);")

        recorded = Migrations._plan_schema_tables(pending)
        e = _ps739_raised(() -> _ps739_quiet(() -> Migrations._execute_migration_lifecycle(
            pool, settings, stmts, all_sql, Migrations.generate_version(), "p", Migrations.compute_checksum(all_sql),
            false; schema_tables = recorded)))
        @test e isa PlanPreconditionError
        @test nrow(_ps739_history(pool)) == 0
        # The pool's only connection is back, and usable.
        @test nrow(DataFrame(fetch(pool, "SELECT 1 AS one;"))) == 1

        # A matching precondition applies.
        fetch(pool, "DROP TABLE circuit739;")
        r = _ps739_quiet(() -> Migrations._execute_migration_lifecycle(
            pool, settings, stmts, all_sql, Migrations.generate_version(), "p", Migrations.compute_checksum(all_sql),
            false; schema_tables = recorded))
        @test r.outcome === :applied
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# status(): a failure a later apply of the same plan resolved is superseded
# Failures retry freely and a plan runs in one transaction, so a `failed` row means nothing was
# applied. Once the same checksum is applied by a LATER row, the failure is history, not drift: it
# moves to `superseded` and its signal clears. An earlier apply does not resolve a later failure,
# and a failure of a different plan stays.
# ─────────────────────────────────────────────────────────────────────────────
@testset "status() supersedes a failure a later apply resolved (#739)" begin
    _ps739_project("db739s") do pool, settings, _, _
        Migrations.init_migrations(pool)
        rec(version, checksum, status) = Migrations._record_migration(pool, version, "m$(version)", checksum, "", status, false)

        # A failed, then applied: resolved. B failed, never applied: stays.
        rec("20260101000001", "A", "failed")
        rec("20260101000002", "A", "applied")
        rec("20260101000003", "B", "failed")
        st = Migrations.status(pool, settings)
        @test [r[:version] for r in st.superseded] == ["20260101000001"]
        @test [r[:version] for r in st.failed] == ["20260101000003"]
        @test any(s -> occursin("1 failed migration(s)", s), st.drift_signals)
        @test occursin("Superseded failures: 1", sprint(show, st))

        # A failure AFTER the only apply of its checksum is not resolved by it.
        rec("20260101000004", "A", "failed")
        @test length(Migrations.status(pool, settings).failed) == 2

        # Every failure resolved: no failure signal at all.
        rec("20260101000005", "B", "applied")
        rec("20260101000006", "A", "applied")
        st = Migrations.status(pool, settings)
        @test isempty(st.failed) && length(st.superseded) == 3
        @test !any(s -> occursin("failed migration", s), st.drift_signals)
    end
end
