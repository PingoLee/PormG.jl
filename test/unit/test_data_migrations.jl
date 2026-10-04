# =============================================================================
# Data migrations: `Data (pre)` / `Data (post)` plan steps and `run_once` (#740)
#
# PormG had no recorded data step. Hand-added SQL in `pending_migrations.jl` ran in the catch-all
# bucket, ordered by the NAME of the binding it sat in, so a backfill could run before its own plan's
# `ADD COLUMN`; the next `makemigrations` overwrote it or moved it aside; and the documented
# alternative — `run_in_transaction` outside the engine — took no lock, recorded nothing, and ran
# again in every process that reached it.
#
# Two halves, both settled by the maintainer on the issue:
#   * plan entries labelled `Data (pre): …` / `Data (post): …` run before / after every schema
#     statement, are named by `dry_run`, and stop `makemigrations` from replacing their plan;
#   * `Migrations.run_once(db, name) do conn … end` runs a Julia step once per database, under the
#     migration lock, recorded by name in its own table, `pormg_migrations_data`.
#
# Hermetic: temporary SQLite files and folders, and one probe `PormGPostgres` that runs nothing.
# =============================================================================
# julia --project=test/integration test/unit/test_data_migrations.jl

using Test
using Logging
using DataFrames
using PormG
# The end-to-end testsets open real (temporary) SQLite files, so they need the weakdep extension.
isdefined(Main, :SQLite) || include(joinpath(@__DIR__, "..", "load_drivers.jl"))
import PormG: Configuration, Migrations, InvalidMigrationError, InvalidValueError, TransactionError, PormGPostgres
import PormG.ConnectionPool: fetch, close_pool!, run_in_transaction, SQLiteConnectionPool
import OrderedCollections: OrderedDict

_de740_quiet(f) = with_logger(f, NullLogger())

# The exception `f` raises, or `nothing` when it returns.
_de740_raised(f) = try f(); nothing catch e; e end

# A fresh temporary SQLite project, the `test_plan_schema_fingerprint.jl` shape: `pool_size = 1`, so
# a step that took a second connection — or leaked the transaction's — deadlocks instead of passing.
function _de740_project(f, tag::String)
    dir = mktempdir()
    pool = nothing
    try
        cd(dir) do
            mkpath(joinpath(tag, "migrations"))
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

# A models file with one F1 table, `circuit740 (id, name)`, plus whatever field source `extra` adds.
_de740_write_models(path::AbstractString; extra::String = "") =
    write(path, "module models\nimport PormG.Models\nCircuit740 = Models.Model(\n    id = Models.IDField(),\n" *
                "    name = Models.CharField(null = true)$(extra)\n)\nend\n")

_de740_makemigrations(pool, settings, models_path) =
    _de740_quiet(() -> Migrations.makemigrations(pool, settings; path = models_path, interactive = false))
_de740_migrate(pool, settings) = _de740_quiet(() -> Migrations.migrate(pool, settings; interactive = false))
_de740_rows(pool, sql) = DataFrame(fetch(pool, sql))

# A hand-written plan, through the generator `makemigrations` uses — so it is exactly what a user
# editing that file would start from.
function _de740_write_plan(pending::AbstractString, plan::OrderedDict{Symbol, OrderedDict{String, String}})
    PormG.Generator.generate_migration_plan(basename(pending), plan, dirname(pending))
end

# ─────────────────────────────────────────────────────────────────────────────
# Plan ordering: the label places a data step, never the binding it sits in
# `Data (pre)` runs before every schema statement and `Data (post)` after every one, whatever the
# binding is called — `aaa` sorts first, `zzz` last, and neither moves them. A data step whose text
# happens to contain "Rename field" is still a data step. A plan with no data label orders exactly
# as before #740, so its checksum — part of the frozen format — is unchanged.
# ─────────────────────────────────────────────────────────────────────────────
@testset "data steps run first and last, whatever the binding (#740)" begin
    plan = [
        # binding `aaa` (read first): the post step must still run last
        OrderedDict("Data (post): backfill code" => "UPDATE drivers SET code = 'X';"),
        OrderedDict("New model" => "CREATE TABLE drivers (id INTEGER);",
                    "Create index on code" => "CREATE INDEX drivers_code ON drivers (code);",
                    "Add field: code" => "ALTER TABLE drivers ADD COLUMN code TEXT;",
                    "Rename field: nick" => "ALTER TABLE drivers RENAME COLUMN a TO nick;"),
        # binding `zzz` (read last): the pre step must still run first, and the "Rename field" in
        # its label must not send it to the rename bucket
        OrderedDict("Data (pre): Rename field values" => "UPDATE drivers SET a = 'pre';"),
    ]
    ordered, all_sql = Migrations._order_statements(plan)
    @test ordered == ["UPDATE drivers SET a = 'pre';",
                      "CREATE TABLE drivers (id INTEGER);",
                      "ALTER TABLE drivers RENAME COLUMN a TO nick;",
                      "ALTER TABLE drivers ADD COLUMN code TEXT;",
                      "CREATE INDEX drivers_code ON drivers (code);",
                      "UPDATE drivers SET code = 'X';"]
    @test all_sql == join(ordered, "\n")
    @test [first(e) for e in Migrations._ordered_entries(plan)][[1, end]] ==
          ["Data (pre): Rename field values", "Data (post): backfill code"]

    # No data label: byte-for-byte the pre-#740 order (catch-all in reading order, indexes last).
    legacy = [OrderedDict("Add field: a" => "A;", "Create index on a" => "I;"),
              OrderedDict("Custom backfill" => "U;", "New model" => "C;")]
    @test first(Migrations._order_statements(legacy)) == ["C;", "A;", "U;", "I;"]
end

# ─────────────────────────────────────────────────────────────────────────────
# A near-miss data label is refused, not reordered silently
# `Data (Pre):`, `data (post):`, a missing colon, an unknown phase: each looks like a data step to its
# author and would land in the catch-all bucket, ordered by binding name — the defect this issue
# fixes. Detection is loose in case and spacing, the parse strict.
# ─────────────────────────────────────────────────────────────────────────────
@testset "a label that starts `Data (` must be a data step (#740)" begin
    for label in ("Data (Pre): x", "Data (post) x", "Data (middle): x", "Data (): x",
                  "data (post): x", "DATA (pre): x", "Data(post): x", "  data (pre): x")
        e = _de740_raised(() -> Migrations._order_statements([OrderedDict(label => "UPDATE t SET a = 1;")]))
        @test (label, e isa InvalidMigrationError) == (label, true)
        @test e !== nothing && occursin(repr(label), sprint(showerror, e))
    end
    # Not a data label at all: ordinary catch-all, as before.
    @test first(Migrations._order_statements([OrderedDict("Data fix" => "U;", "Database backfill" => "V;")])) == ["U;", "V;"]
end

# ─────────────────────────────────────────────────────────────────────────────
# End to end: a backfill in a binding that sorts first still runs after its ADD COLUMN
# Before #740 the hand-added binding `aaa` ran its UPDATE before the `circuit740` binding's ADD
# COLUMN, and the plan failed on a column that did not exist yet. dry_run names the step.
# ─────────────────────────────────────────────────────────────────────────────
@testset "a Data (post) backfill sees the column its plan adds (#740)" begin
    _de740_project("db740e") do pool, settings, models_path, pending
        _de740_write_models(models_path)
        _de740_makemigrations(pool, settings, models_path)
        @test _de740_migrate(pool, settings).outcome === :applied
        fetch(pool, "INSERT INTO circuit740 (name) VALUES ('Monza'), ('Suzuka');")

        _de740_write_plan(pending, OrderedDict{Symbol, OrderedDict{String, String}}(
            :aaa_backfill => OrderedDict("Data (post): fill code" =>
                                         "UPDATE circuit740 SET code = upper(substr(name, 1, 3)) WHERE code IS NULL;"),
            :circuit740 => OrderedDict("Add field: code" => "ALTER TABLE circuit740 ADD COLUMN code TEXT;")))

        dr = Migrations.dry_run(pool, settings)
        @test dr.data_steps == ["Data (post): fill code"]
        @test last(dr.statements) == "UPDATE circuit740 SET code = upper(substr(name, 1, 3)) WHERE code IS NULL;"
        shown = sprint(show, dr)
        @test occursin("Data steps: 1", shown) && occursin("Data (post): fill code", shown)

        @test _de740_migrate(pool, settings).outcome === :applied
        @test sort(_de740_rows(pool, "SELECT code FROM circuit740;").code) == ["MON", "SUZ"]
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# makemigrations does not replace a plan holding data steps
# The steps exist only in that file. On an empty diff — the likely case: models and database already
# agree — it used to move the plan aside; on a non-empty one, overwrite it. Both now refuse, naming
# the step and leaving the file byte-identical. An explicit discard still works: that is the user's
# call to make.
# ─────────────────────────────────────────────────────────────────────────────
@testset "makemigrations refuses to overwrite or discard data steps (#740)" begin
    _de740_project("db740m") do pool, settings, models_path, pending
        _de740_write_models(models_path)
        _de740_makemigrations(pool, settings, models_path)
        @test _de740_migrate(pool, settings).outcome === :applied

        _de740_write_plan(pending, OrderedDict{Symbol, OrderedDict{String, String}}(
            :fix => OrderedDict("Data (pre): normalise names" => "UPDATE circuit740 SET name = trim(name);")))
        before = read(pending, String)

        # Empty diff.
        e = _de740_raised(() -> _de740_makemigrations(pool, settings, models_path))
        @test e isa InvalidMigrationError
        @test e !== nothing && occursin("\"Data (pre): normalise names\"", sprint(showerror, e))
        @test read(pending, String) == before
        @test !isfile(pending * ".discarded")

        # Non-empty diff: the models gained a field.
        _de740_write_models(models_path; extra = ",\n    country = Models.CharField(null = true)")
        @test _de740_raised(() -> _de740_makemigrations(pool, settings, models_path)) isa InvalidMigrationError
        @test read(pending, String) == before

        # Applied, the plan is archived and the next makemigrations plans normally.
        @test _de740_migrate(pool, settings).outcome === :applied
        _de740_makemigrations(pool, settings, models_path)
        @test occursin("country", read(pending, String))

        # A plan that does not parse is no plan anyone can apply: makemigrations is not blocked by
        # the data step written inside it, and moves it aside as before (with its backup).
        @test _de740_migrate(pool, settings).outcome === :applied   # the `country` plan: up to date now
        write(pending, "module pending_migrations\nt = OrderedDict(\"Data (post): x\" => string(\"UPDATE \", \"t\"))\nend\n")
        _de740_makemigrations(pool, settings, models_path)
        @test !isfile(pending) && isfile(pending * ".discarded")

        # An explicit discard of a data-step plan is not refused.
        _de740_write_plan(pending, OrderedDict{Symbol, OrderedDict{String, String}}(
            :fix => OrderedDict("Data (post): x" => "UPDATE circuit740 SET name = name;")))
        @test _de740_quiet(() -> Migrations.discard_pending_migration(settings)) !== nothing
        @test !isfile(pending)
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# A Data (pre) step can satisfy a counted column change, when the header says so (#897)
# `migrate` counts a lossy change's rows before any statement runs, so a `Data (pre)` step that fixes
# them came too late: the issue's repro, a NOT NULL over NULLs with a pre step that fills them, was
# refused with MigrationPrecheckError. It still is, unmarked. Marked `handled=pre`, the rows are
# counted and shown but not refused, the step runs, and the database enforces the NOT NULL — so a step
# that leaves a NULL fails inside the migration and rolls everything back. A mark with no pre step is
# refused before anything runs. `destructive = true` throughout: every SQLite column change rebuilds
# the table, which the destructive guard flags whatever #897 does.
# ─────────────────────────────────────────────────────────────────────────────
@testset "a handled=pre finding lets a Data (pre) step fix its rows (#897)" begin
    _de740_project("db897") do pool, settings, models_path, pending
        _de740_write_models(models_path)
        _de740_makemigrations(pool, settings, models_path)
        @test _de740_migrate(pool, settings).outcome === :applied
        fetch(pool, "INSERT INTO circuit740 (name) VALUES ('Monza'), (NULL), (NULL);")

        # `name` becomes NOT NULL over the two NULLs just inserted.
        write(models_path, replace(read(models_path, String), "Models.CharField(null = true)" => "Models.CharField()"))
        _de740_makemigrations(pool, settings, models_path)
        generated = read(pending, String)
        @test occursin("kind=set_not_null", generated)

        migrate!() = _de740_quiet(() -> Migrations.migrate(pool, settings; interactive = false, destructive = true))
        with_step(text, sql) = replace(text, r"\nend\n$" =>
            "\n# table: aaa_fill\naaa_fill = OrderedDict{String, String}(\"Data (pre): fill name\" => \"$(sql)\")\n\nend\n")
        mark(text) = replace(text, r"# pormg-lossy-alter: [^\n]*kind=set_not_null[^\n]*" => l -> l * "\thandled=pre")
        nulls() = _de740_rows(pool, "SELECT COUNT(*) AS n FROM circuit740 WHERE name IS NULL;").n[1]
        fill_sql = "UPDATE circuit740 SET name = 'Unknown' WHERE name IS NULL;"

        # The issue's repro, unmarked: refused before anything runs, the pre step included.
        write(pending, with_step(generated, fill_sql))
        @test _de740_raised(migrate!) isa Migrations.MigrationPrecheckError
        @test nulls() == 2

        # Marked, but no step to back the mark: refused as a damaged plan, by dry_run and migrate alike.
        write(pending, mark(generated))
        for run in (() -> Migrations.dry_run(pool, settings), migrate!)
            e = _de740_raised(run)
            @test e isa InvalidMigrationError
            @test e !== nothing && occursin("handled=pre", sprint(showerror, e))
        end

        # Marked, with a step that fills one NULL of two: not refused up front, so the NOT NULL fails
        # inside the migration, which rolls back — the step's own write included, so both NULLs are
        # still there, and the plan still pending.
        write(pending, mark(with_step(generated,
            "UPDATE circuit740 SET name = 'Imola' WHERE id = (SELECT MIN(id) FROM circuit740 WHERE name IS NULL);")))
        e = _de740_raised(migrate!)
        @test e !== nothing && occursin("NOT NULL constraint failed", sprint(showerror, e))
        @test nulls() == 2
        @test isfile(pending)

        # Marked, with the fill: dry_run counts both rows and shows them as handled, migrate applies.
        write(pending, mark(with_step(generated, fill_sql)))
        dr = Migrations.dry_run(pool, settings)
        @test [(f.kind, f.handled, f.rows) for f in dr.lossy_alters] == [(:set_not_null, :pre, 2)]
        shown = sprint(show, dr)
        @test occursin("HANDLED BY A Data (pre) STEP: 1", shown)
        @test !occursin("WOULD FAIL", shown)
        @test migrate!().outcome === :applied
        @test nulls() == 0
        @test _de740_rows(pool, "SELECT \"notnull\" FROM pragma_table_info('circuit740') WHERE name = 'name';").notnull[1] == 1
        @test sort(_de740_rows(pool, "SELECT name FROM circuit740;").name) == ["Monza", "Unknown", "Unknown"]
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# run_once: once per database, recorded by name
# The first call runs the block and records it; the second finds the record and does not call the
# block at all. status() lists the step, and makemigrations does not plan to drop the table it lives
# in — `pormg_migrations_data` sits under the `pormg_migrations` ignore prefix.
# ─────────────────────────────────────────────────────────────────────────────
@testset "run_once runs a step once and records it (#740)" begin
    _de740_project("db740o") do pool, settings, models_path, pending
        _de740_write_models(models_path)
        _de740_makemigrations(pool, settings, models_path)
        @test _de740_migrate(pool, settings).outcome === :applied
        fetch(pool, "INSERT INTO circuit740 (name) VALUES ('Spa');")

        calls = Ref(0)
        step(conn) = (calls[] += 1; fetch(conn, "UPDATE circuit740 SET name = upper(name);"))
        @test Migrations.run_once(step, pool, settings, "2026-10-02_upper_names") === :applied
        @test Migrations.run_once(step, pool, settings, "2026-10-02_upper_names") === :already_applied
        @test calls[] == 1
        @test only(_de740_rows(pool, "SELECT name FROM circuit740;").name) == "SPA"

        st = Migrations.status(pool, settings)
        @test [r[:name] for r in st.data_steps] == ["2026-10-02_upper_names"]
        @test occursin("Data steps: 1 applied", sprint(show, st))

        # The history table is not a table the models forgot: nothing to plan.
        _de740_makemigrations(pool, settings, models_path)
        @test !isfile(pending)
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# run_once: a failing transactional step leaves nothing behind
# The step's writes and its record commit together. A throw rolls back both — the inserted row is
# gone, no record exists — and the error reaches the caller. The next call runs it again. The
# one-connection pool must still serve the following statement.
# ─────────────────────────────────────────────────────────────────────────────
@testset "run_once rolls a failed step back, and retries it (#740)" begin
    _de740_project("db740r") do pool, settings, models_path, _
        _de740_write_models(models_path)
        _de740_makemigrations(pool, settings, models_path)
        _de740_migrate(pool, settings)

        boom(conn) = (fetch(conn, "INSERT INTO circuit740 (name) VALUES ('Imola');"); error("backfill failed"))
        e = _de740_raised(() -> _de740_quiet(() -> Migrations.run_once(boom, pool, settings, "imola")))
        @test e isa ErrorException && occursin("backfill failed", e.msg)
        @test nrow(_de740_rows(pool, "SELECT * FROM circuit740;")) == 0
        @test nrow(_de740_rows(pool, "SELECT * FROM pormg_migrations_data;")) == 0

        ok(conn) = fetch(conn, "INSERT INTO circuit740 (name) VALUES ('Imola');")
        @test Migrations.run_once(ok, pool, settings, "imola") === :applied
        @test nrow(_de740_rows(pool, "SELECT * FROM circuit740;")) == 1
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# run_once(transaction = false): recorded after the block, nothing recorded on a throw
# For what cannot run in a transaction (CREATE INDEX CONCURRENTLY on PostgreSQL). The block's own
# work is not undone by a later throw — which is why such a step has to be safe to re-run — but it
# is not recorded either, so the next call runs it again.
# ─────────────────────────────────────────────────────────────────────────────
@testset "run_once(transaction = false) records only a step that returned (#740)" begin
    _de740_project("db740n") do pool, settings, models_path, _
        _de740_write_models(models_path)
        _de740_makemigrations(pool, settings, models_path)
        _de740_migrate(pool, settings)

        half(conn) = (fetch(conn, "INSERT INTO circuit740 (name) VALUES ('Baku');"); error("stopped half-way"))
        @test _de740_raised(() -> Migrations.run_once(half, pool, settings, "baku"; transaction = false)) isa ErrorException
        @test nrow(_de740_rows(pool, "SELECT * FROM circuit740;")) == 1   # kept: no transaction
        @test nrow(_de740_rows(pool, "SELECT * FROM pormg_migrations_data;")) == 0

        idx(conn) = fetch(conn, "CREATE INDEX IF NOT EXISTS circuit740_name ON circuit740 (name);")
        @test Migrations.run_once(idx, pool, settings, "idx"; transaction = false) === :applied
        @test Migrations.run_once(idx, pool, settings, "idx"; transaction = false) === :already_applied
        # status() reports `transactional` as a Bool on both engines (SQLite stores 0/1).
        rec = only(Migrations.status(pool, settings).data_steps)
        @test rec.name == "idx" && rec.transactional === false

        # Nothing serializes a non-transactional step on SQLite, so another runner can record the
        # same name while this one's block runs. That is not an error: the step ran, and it is
        # recorded — the second recorder reports :already_applied instead of a UNIQUE failure.
        raced(conn) = fetch(conn, "INSERT INTO pormg_migrations_data (name, transactional) VALUES ('raced', 0);")
        @test Migrations.run_once(raced, pool, settings, "raced"; transaction = false) === :already_applied
        @test nrow(_de740_rows(pool, "SELECT * FROM pormg_migrations_data WHERE name = 'raced';")) == 1
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# run_once refuses what it cannot honour
# Inside an open transaction its commit would be a savepoint the outer block can still roll back,
# so it raises TransactionError — the atomic(durable = true) rule. A change_db: false connection
# returns :disabled and runs nothing, not even the table DDL — the migrate contract. A name must be
# non-empty and fit the column.
# ─────────────────────────────────────────────────────────────────────────────
@testset "run_once refusals: open transaction, change_db, name (#740)" begin
    _de740_project("db740x") do pool, settings, _, _
        ran = Ref(false)
        step(conn) = (ran[] = true)

        e = _de740_raised(() -> run_in_transaction(pool) do
            Migrations.run_once(step, pool, settings, "nested")
        end)
        @test e isa TransactionError
        @test !ran[]

        settings.change_db = false
        @test _de740_quiet(() -> Migrations.run_once(step, pool, settings, "off")) === :disabled
        @test !ran[]
        @test nrow(_de740_rows(pool, "SELECT name FROM sqlite_master WHERE name = 'pormg_migrations_data';")) == 0
        settings.change_db = true

        @test _de740_raised(() -> Migrations.run_once(step, pool, settings, "  ")) isa InvalidValueError
        @test _de740_raised(() -> Migrations.run_once(step, pool, settings, "x"^256)) isa InvalidValueError
        @test _de740_raised(() -> Migrations.run_once(step, pool, settings, "ok"; lock_wait = 0)) isa InvalidValueError
        @test !ran[]
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# run_once on SQLite: a racing process's record is seen under BEGIN IMMEDIATE
# SQLite has no advisory lock, so the transactional step's guarantee is that it reads its record
# inside its own `BEGIN IMMEDIATE`. A child process — SQLite.jl only — holds the write lock with the
# step's record inserted but not committed. run_once must wait for it, see the record, and not run
# its block. Checked before BEGIN (or outside the transaction), it would see no row and run the step
# a second time. The #737 race test's shape, in a second OS process because SQLite's busy wait blocks
# in C.
# ─────────────────────────────────────────────────────────────────────────────
@testset "run_once on SQLite: a racing process's record is seen (#740)" begin
    _de740_project("db740c") do pool, settings, _, _
        dbfile = abspath("db740c.sqlite")
        fetch(pool, PormG.Dialect.create_data_steps_table(pool))
        marker, committed_at, script = abspath("child_holds_lock"), abspath("child_committed_at"), abspath("race740.jl")
        record = "INSERT INTO pormg_migrations_data (\"name\", \"transactional\") VALUES ('raced_step', 1);"
        write(script, """
            using SQLite
            db = SQLite.DB($(repr(dbfile)))
            SQLite.execute(db, "PRAGMA busy_timeout = 30000;")
            SQLite.execute(db, "BEGIN IMMEDIATE TRANSACTION;")
            SQLite.execute(db, $(repr(record)))
            touch($(repr(marker)))
            sleep(6)                     # run_once is waiting on the write lock meanwhile
            # Stamped just BEFORE the commit: run_once cannot get the lock until after it, so its
            # return time is at or past this one by construction, never by a scheduling race.
            write($(repr(committed_at)), string(time()))
            SQLite.execute(db, "COMMIT;")
            close(db)
            """)
        errlog = abspath("child.err")
        cmd = `$(Base.julia_cmd()) --startup-file=no --project=$(Base.active_project()) $(script)`
        proc = run(pipeline(cmd; stdout = devnull, stderr = errlog); wait = false)
        deadline = time() + 180
        while !isfile(marker) && process_running(proc) && time() < deadline
            sleep(0.2)
        end
        isfile(marker) || error("race child never took the lock:\n" * (isfile(errlog) ? read(errlog, String) : ""))

        ran = Ref(false)
        started_at = time()
        r = Migrations.run_once(_ -> (ran[] = true), pool, settings, "raced_step")
        returned_at = time()
        wait(proc)
        @test success(proc)
        # The race was real: run_once was called well before the child committed, and returned only
        # after it — it waited on the write lock rather than reading before the child's commit.
        committed = parse(Float64, read(committed_at, String))
        @test committed - started_at > 2
        @test returned_at >= committed
        @test r === :already_applied
        @test !ran[]
        @test nrow(_de740_rows(pool, "SELECT * FROM pormg_migrations_data;")) == 1
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# run_once on PostgreSQL takes migrate's lock
# A data step and a schema migration must never run at once, so `run_once` waits on the same
# advisory-lock key `migrate` holds, for `lock_wait` seconds. A probe pool intercepts the lock and
# records what it was asked for; it runs no block.
# ─────────────────────────────────────────────────────────────────────────────
struct RunOnceLockProbePg740 <: PormGPostgres end
const RUN_ONCE_LOCK_SEEN_740 = Ref{Any}(nothing)
function PormG.AdvisoryLock.with_advisory_lock(f::Function, pool::RunOnceLockProbePg740, key::AbstractString; kwargs...)
    RUN_ONCE_LOCK_SEEN_740[] = (key = String(key), kwargs = Dict(kwargs))
    return :intercepted
end

@testset "run_once waits on the migration lock (#740)" begin
    settings = Configuration.Settings()
    settings.change_db = true
    r = Migrations.run_once(_ -> error("must not run"), RunOnceLockProbePg740(), settings, "probe"; lock_wait = 7)
    @test r === :intercepted
    seen = RUN_ONCE_LOCK_SEEN_740[]
    @test seen.key == Migrations.MIGRATION_LOCK_KEY
    @test seen.kwargs[:wait] === true
    @test seen.kwargs[:timeout_ms] == 7_000
end
