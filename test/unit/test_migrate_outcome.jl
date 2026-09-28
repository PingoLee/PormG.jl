# =============================================================================
# migrate() at boot: an outcome, not an exception, and every write under the lock (#737)
#
# `migrate()` returned `nothing` whatever it did, and threw `InvalidMigrationError("No pending
# migrations found")` when there was nothing to do — the same type a corrupt plan raises, so a boot
# script could not tell "up to date" from "broken". It now returns a `MigrationResult` whose
# `outcome` says which of five things happened.
#
# The rest of the issue is about N instances calling it at once:
#   * PostgreSQL: `init_migrations` and the extension install ran BEFORE the advisory lock, so N
#     instances issued that DDL concurrently. The probe connection below records whether each
#     statement ran inside the lock.
#   * SQLite: the #81 checksum guard ran before `BEGIN IMMEDIATE`, so two processes on one file
#     could both pass it. The last testset races a real second process against `migrate`.
#
# Hermetic: temporary SQLite files and folders, a probe `PormGPostgres` that runs nothing, and one
# child process that loads only SQLite.jl. No live database.
# =============================================================================
# julia --project=test/integration test/unit/test_migrate_outcome.jl

using Test
using Logging
using DataFrames
using PormG
# The SQLite testsets open real (temporary) files, so they need the weakdep extension. `runtests.jl`
# loads it for the whole suite; this guard is what makes the file runnable alone.
isdefined(Main, :SQLite) || include(joinpath(@__DIR__, "..", "load_drivers.jl"))
import PormG: Configuration, Migrations, PormGPostgres, InvalidValueError, InvalidMigrationError
import PormG.ConnectionPool: fetch, with_transaction, finalize_transaction_connection!, close_pool!,
                             SQLiteConnectionPool
import OrderedCollections: OrderedDict

# `migrate` and `makemigrations` report through the logger; the assertions read results and files.
_mo737_quiet(f) = with_logger(f, NullLogger())

# The models file `makemigrations` reads: one F1 table.
function _mo737_write_models(path::AbstractString)
    write(path, "module models\nimport PormG.Models\n" *
                "Circuit737 = Models.Model(\n    id = Models.IDField(),\n" *
                "    name = Models.CharField(null = true)\n)\nend\n")
end

# The history table's rows, straight from SQLite.
_mo737_history(pool) = DataFrame(fetch(pool, "SELECT version, status FROM pormg_migrations ORDER BY version;"))

# A fresh temporary SQLite project: a pool, a folder-backed settings object with `change_db` on, and
# the absolute path of its models file. `f(pool, settings, models_path)` runs inside the temp dir.
function _mo737_sqlite_project(f, tag::String)
    dir = mktempdir()
    pool = nothing
    try
        cd(dir) do
            mkpath(tag)
            pool = SQLiteConnectionPool(joinpath(dir, "$(tag).sqlite"); pool_size = 1)
            settings = Configuration.Settings(connections = pool, db_def_folder = tag)
            settings.change_db = true
            f(pool, settings, joinpath(dir, tag, "models.jl"))
        end
    finally
        pool === nothing || close_pool!(pool)
        rm(dir; recursive = true, force = true)
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# MigrationResult: the contract a boot script branches on
# Five outcomes, and a typo is refused at construction rather than becoming a sixth. `version` is a
# `String` or `nothing`, never a `SubString` that happens to print the same.
# ─────────────────────────────────────────────────────────────────────────────
@testset "MigrationResult: five outcomes, validated (#737)" begin
    for outcome in (:applied, :already_applied, :nothing_pending, :disabled, :declined)
        @test Migrations.MigrationResult(outcome, nothing, 0).outcome === outcome
    end
    refusal(f) = try f(); "" catch e; e isa InvalidValueError ? sprint(showerror, e) : "wrong type: $(typeof(e))" end
    @test occursin(":aplied", refusal(() -> Migrations.MigrationResult(:aplied, nothing, 0)))
    @test occursin("negative", refusal(() -> Migrations.MigrationResult(:applied, "v", -1)))

    r = Migrations.MigrationResult(:applied, SubString("x20260926", 2), 3)
    @test r.version === "20260926"
    @test r.n_statements == 3

    # The REPL rendering names the outcome, and omits a version that is not there.
    shown = sprint(show, MIME"text/plain"(), r)
    @test occursin("applied", shown) && occursin("20260926", shown) && occursin("3", shown)
    @test !occursin("Version", sprint(show, MIME"text/plain"(), Migrations.MigrationResult(:disabled, nothing, 0)))
end

# ─────────────────────────────────────────────────────────────────────────────
# The wait bounds: seconds in, validated before anything else
# `lock_wait`, `lock_timeout` and `statement_timeout` reach SQL only as an `Int` of milliseconds
# PormG formats, so the validation IS the injection guard for the `SET LOCAL` statements. A bad
# value must fail even on a `change_db: false` connection, where `migrate` returns before reading
# anything — otherwise the same deploy script fails only on the instances that migrate.
# ─────────────────────────────────────────────────────────────────────────────
@testset "migrate's timeouts: positive seconds, checked first (#737)" begin
    t = Migrations._migration_timeouts(2.5, 1, nothing)
    @test t.lock_wait_ms == 2500
    @test t.lock_timeout_ms == 1000
    @test t.statement_timeout_ms === nothing
    @test Migrations._migration_timeouts().lock_wait_ms == 30_000   # the documented default

    # Each refusal names the keyword it refuses, so a bad `statement_timeout` is not reported as the
    # lock wait.
    refusal(f) = try f(); "" catch e; e isa InvalidValueError ? sprint(showerror, e) : "wrong type: $(typeof(e))" end
    for bad in (0, -1, Inf, NaN, true, 3_000_000)
        @test occursin("lock_wait = ", refusal(() -> Migrations._migration_timeouts(bad)))
        @test occursin("lock_timeout = ", refusal(() -> Migrations._migration_timeouts(30, bad)))
        @test occursin("statement_timeout = ", refusal(() -> Migrations._migration_timeouts(30, nothing, bad)))
    end

    _mo737_sqlite_project("db737t") do pool, settings, _
        settings.change_db = false
        @test occursin("lock_wait = 0", refusal(() -> Migrations.migrate(pool, settings; interactive = false, lock_wait = 0)))
        @test occursin("statement_timeout = -5",
                       refusal(() -> Migrations.migrate(pool, settings; interactive = false, statement_timeout = -5)))
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# SQLite, end to end: :disabled, :nothing_pending, :applied, :already_applied
# The four outcomes a hermetic run can reach. (`:declined` needs a terminal to answer the prompt:
# `_confirm_migration` only prompts when stdin is a TTY, which a test process never has.)
# ─────────────────────────────────────────────────────────────────────────────
@testset "migrate returns what it did, on SQLite (#737)" begin
    _mo737_sqlite_project("db737a") do pool, settings, models_path
        pending = joinpath("db737a", "migrations", "pending_migrations.jl")
        applied_dir = joinpath("db737a", "migrations", "applied_migrations")

        # change_db: false touches nothing — not even the history table.
        settings.change_db = false
        r = _mo737_quiet(() -> Migrations.migrate(pool, settings; interactive = false))
        @test r.outcome === :disabled && r.version === nothing && r.n_statements == 0
        @test !Migrations._migrations_table_exists(pool)
        settings.change_db = true

        # Nothing pending is an outcome, not an error. It used to throw InvalidMigrationError. The
        # history table is still ensured: `migrate` bootstraps even when there is nothing to apply.
        r = _mo737_quiet(() -> Migrations.migrate(pool, settings; interactive = false))
        @test r.outcome === :nothing_pending && r.version === nothing && r.n_statements == 0
        @test Migrations._migrations_table_exists(pool)
        @test nrow(_mo737_history(pool)) == 0

        # A plan: applied, and the result names the history row it wrote.
        _mo737_write_models(models_path)
        _mo737_quiet(() -> Migrations.makemigrations(pool, settings; path = models_path, interactive = false))
        n_planned = length(first(Migrations._order_statements(Migrations._load_migration_plan(settings))))
        r = _mo737_quiet(() -> Migrations.migrate(pool, settings; interactive = false))
        @test r.outcome === :applied
        @test r.n_statements == n_planned > 0
        h = _mo737_history(pool)
        @test nrow(h) == 1 && h.status[1] == "applied" && r.version == string(h.version[1])
        @test !isfile(pending)

        # The #81 state — the apply committed but the archive failed, so the plan is still pending.
        # The next call archives it and reports the ORIGINAL row, running nothing.
        archived = only(filter(f -> endswith(f, "_migration.jl"), readdir(applied_dir)))
        mv(joinpath(applied_dir, archived), pending)
        r2 = _mo737_quiet(() -> Migrations.migrate(pool, settings; interactive = false))
        @test r2.outcome === :already_applied
        @test r2.version == r.version
        @test r2.n_statements == 0
        @test nrow(_mo737_history(pool)) == 1
        @test !isfile(pending)
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# The plan is read before anything is written
# A pending plan that does not parse still raises InvalidMigrationError (#710) — and now it raises
# BEFORE `init_migrations` has created the history table, instead of after. An empty plan file is
# `:nothing_pending`, the same as no file.
# ─────────────────────────────────────────────────────────────────────────────
@testset "migrate reads the plan before writing anything (#737)" begin
    _mo737_sqlite_project("db737b") do pool, settings, _
        mkpath(joinpath("db737b", "migrations"))
        pending = joinpath("db737b", "migrations", "pending_migrations.jl")

        # Not a plan: a call, where the reader accepts only string literals.
        write(pending, "module pending_migrations\nimport OrderedCollections: OrderedDict\n" *
                       "t = OrderedDict{String, String}(\"Drop table\" => string(\"DROP \", \"TABLE t\"))\nend\n")
        @test_throws InvalidMigrationError _mo737_quiet(() -> Migrations.migrate(pool, settings; interactive = false))
        # Mutation gate: with the plan read after `init_migrations` again, this table exists.
        @test !Migrations._migrations_table_exists(pool)

        # A plan with no statements is nothing to do.
        write(pending, "module pending_migrations\nimport OrderedCollections: OrderedDict\nend\n")
        r = _mo737_quiet(() -> Migrations.migrate(pool, settings; interactive = false))
        @test r.outcome === :nothing_pending
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# A plan another instance already archived is not archived again
# Instances booting from one shared folder all read the same pending file; the first to finish
# moves it to `applied_migrations/`. The rest report `:already_applied`, and their archive step must
# find nothing to do — not copy a models snapshot beside an archive they did not write.
# ─────────────────────────────────────────────────────────────────────────────
@testset "archiving with no pending plan writes nothing (#737)" begin
    _mo737_sqlite_project("db737c") do pool, settings, models_path
        _mo737_write_models(models_path)
        Migrations._archive_migration_files(settings, "2026-09-26_00-00-00")
        @test !isdir(joinpath("db737c", "migrations", "applied_migrations"))
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# PostgreSQL probe: what runs inside the advisory lock
# A probe pool records every statement `migrate` issues and whether the migration lock was held when
# it ran. The lock itself is the probe's too: it records the keywords it was called with, marks the
# body as inside, and runs it. Nothing reaches a server.
# ─────────────────────────────────────────────────────────────────────────────
struct MigrateOutcomeProbePg737 <: PormGPostgres end
const _MO737_INSIDE = Ref(false)
const _MO737_LOG = Tuple{Bool, String}[]
const _MO737_LOCK_KWARGS = Ref{Any}(nothing)

function PormG.AdvisoryLock.with_advisory_lock(f::Function, ::MigrateOutcomeProbePg737,
                                               key::AbstractString; kwargs...)
    _MO737_LOCK_KWARGS[] = (key = String(key), kwargs = Dict(kwargs))
    _MO737_INSIDE[] = true
    try
        return f()
    finally
        _MO737_INSIDE[] = false
    end
end
# Every read answers "nothing there": no history table, no applied row, no format_version column.
function fetch(::MigrateOutcomeProbePg737, sql::String; conn = nothing, params = nothing, ignore_tx::Bool = false)
    push!(_MO737_LOG, (_MO737_INSIDE[], sql))
    return DataFrame()
end
function with_transaction(::MigrateOutcomeProbePg737, sql::String; conn = nothing,
                          release_conn::Bool = false, params = nothing)
    push!(_MO737_LOG, (_MO737_INSIDE[], sql))
    return DataFrame(), :probe_conn
end
finalize_transaction_connection!(::MigrateOutcomeProbePg737, conn; rollback_error = nothing, renew::Bool = false) = nothing

# Settings for the probe: folder-backed, change_db on, and unaccent configured so the extension
# install has DDL to issue.
function _mo737_probe_settings(folder::String)
    s = Configuration.Settings(connections = MigrateOutcomeProbePg737(), db_def_folder = folder,
                               db_config_settings = Dict{String, Any}("adapter" => "PostgreSQL",
                                                                      "extensions" => ["unaccent"]))
    s.change_db = true
    return s
end

@testset "PostgreSQL: init, extensions and the plan all run inside the lock (#737)" begin
    dir = mktempdir()
    try
        cd(dir) do
            # ─────────────────────────────────────────────────────────────────
            # Nothing pending: the bootstrap DDL still runs, and only inside the lock
            # Before #737 `CREATE TABLE IF NOT EXISTS pormg_migrations` and `CREATE OR REPLACE
            # FUNCTION public.immutable_unaccent` ran before the lock, on every call — the
            # concurrent-boot race the issue reports.
            # ─────────────────────────────────────────────────────────────────
            mkpath("db737pg")
            settings = _mo737_probe_settings("db737pg")
            empty!(_MO737_LOG)
            r = _mo737_quiet(() -> Migrations.migrate(MigrateOutcomeProbePg737(), settings; interactive = false))
            @test r.outcome === :nothing_pending
            sqls = last.(_MO737_LOG)
            @test any(q -> occursin("pormg_migrations", q), sqls)
            @test any(q -> occursin("CREATE EXTENSION", q), sqls)
            @test any(q -> occursin("immutable_unaccent", q), sqls)
            # Mutation gate: move `init_migrations` or the extension install back ahead of the lock
            # and these statements are logged with `false`.
            @test all(first, _MO737_LOG)

            # The lock is the migration key, waited on for the default 30 s.
            @test _MO737_LOCK_KWARGS[].key == Migrations.MIGRATION_LOCK_KEY
            @test _MO737_LOCK_KWARGS[].kwargs[:wait] == true
            @test _MO737_LOCK_KWARGS[].kwargs[:timeout_ms] == 30_000

            # ─────────────────────────────────────────────────────────────────
            # A plan, with both opt-in timeouts: SET LOCAL right after BEGIN
            # They bound every plan statement, so they come first in the transaction, and LOCAL so
            # they end with it. `lock_wait` reaches the lock as milliseconds.
            # ─────────────────────────────────────────────────────────────────
            plan = OrderedDict{Symbol, OrderedDict{String, String}}(
                :circuit737 => OrderedDict{String, String}(
                    "Add field: country" => "ALTER TABLE \"circuit737\" ADD COLUMN \"country\" TEXT;"))
            mkpath(joinpath("db737pg", "migrations"))
            PormG.Generator.generate_migration_plan("pending_migrations.jl", plan, joinpath("db737pg", "migrations"))

            empty!(_MO737_LOG)
            r = _mo737_quiet(() -> Migrations.migrate(MigrateOutcomeProbePg737(), settings; interactive = false,
                                                      lock_wait = 2.5, lock_timeout = 1, statement_timeout = 90))
            @test r.outcome === :applied && r.n_statements == 1 && r.version !== nothing
            @test _MO737_LOCK_KWARGS[].kwargs[:timeout_ms] == 2500
            @test all(first, _MO737_LOG)

            sqls = last.(_MO737_LOG)
            i_begin = findfirst(==("BEGIN;"), sqls)
            @test i_begin !== nothing
            @test sqls[i_begin + 1] == "SET LOCAL lock_timeout = '1000ms';"
            @test sqls[i_begin + 2] == "SET LOCAL statement_timeout = '90000ms';"
            @test occursin("ADD COLUMN \"country\"", sqls[i_begin + 3])
            @test sqls[end] == "COMMIT;"
            @test !isfile(joinpath("db737pg", "migrations", "pending_migrations.jl"))   # archived

            # Without them, no SET LOCAL at all: the connection's own settings stand.
            PormG.Generator.generate_migration_plan("pending_migrations.jl", plan, joinpath("db737pg", "migrations"))
            empty!(_MO737_LOG)
            _mo737_quiet(() -> Migrations.migrate(MigrateOutcomeProbePg737(), settings; interactive = false))
            @test !any(q -> occursin("SET LOCAL", q), last.(_MO737_LOG))
        end
    finally
        rm(dir; recursive = true, force = true)
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# SQLite: two processes racing one file apply the plan once (#737 gap 5)
# A child process opens the same file, takes the write lock (`BEGIN IMMEDIATE`), applies the plan
# and records it — and holds the transaction open while this process calls `migrate`. `migrate`
# queues on the write lock; when the child commits, it must see the child's history row and report
# `:already_applied`. Before #737 the #81 guard ran BEFORE `BEGIN IMMEDIATE`, saw no row (the child
# had not committed), and then re-ran the child's `CREATE TABLE` after the lock came free: a
# "table already exists" failure and a `failed` history row.
#
# A second OS process on purpose: SQLite's busy wait blocks in C, so a same-process writer could not
# commit while `migrate` waits. The child loads SQLite.jl only, not PormG.
# ─────────────────────────────────────────────────────────────────────────────
@testset "SQLite: a racing migrator's commit is seen under BEGIN IMMEDIATE (#737)" begin
    _mo737_sqlite_project("db737r") do pool, settings, models_path
        dbfile = abspath("db737r.sqlite")
        _mo737_write_models(models_path)
        _mo737_quiet(() -> Migrations.makemigrations(pool, settings; path = models_path, interactive = false))
        Migrations.init_migrations(pool)

        # Exactly what `migrate` will compare: the ordered plan's checksum. The child applies the
        # same statements, split the way the SQLite executor splits them.
        ordered, all_sql = Migrations._order_statements(Migrations._load_migration_plan(settings))
        checksum = Migrations.compute_checksum(all_sql)
        stmts = reduce(vcat, [Migrations._split_sqlite_statements(s) for s in ordered])
        record = "INSERT INTO pormg_migrations (\"version\", \"name\", \"checksum\", \"sql_content\", " *
                 "\"status\", \"is_destructive\", \"format_version\", \"applied_at\") VALUES " *
                 "('race737', 'racer', '$(checksum)', '', 'applied', 0, " *
                 "$(Migrations.MIGRATION_FORMAT_VERSION), $(PormG.Dialect.sqlite_applied_at_now_sql()));"

        marker = abspath("child_holds_lock")
        committed_at = abspath("child_committed_at")
        script = abspath("race737.jl")
        write(script, """
            using SQLite
            db = SQLite.DB($(repr(dbfile)))
            SQLite.execute(db, "PRAGMA busy_timeout = 30000;")
            SQLite.execute(db, "BEGIN IMMEDIATE TRANSACTION;")
            for s in $(repr(stmts))
                SQLite.execute(db, s)
            end
            SQLite.execute(db, $(repr(record)))
            touch($(repr(marker)))
            sleep(6)                     # migrate() is waiting on the write lock meanwhile
            SQLite.execute(db, "COMMIT;")
            write($(repr(committed_at)), string(time()))
            close(db)
            """)
        errlog = abspath("child.err")
        cmd = `$(Base.julia_cmd()) --startup-file=no --project=$(Base.active_project()) $(script)`
        proc = run(pipeline(cmd; stdout = devnull, stderr = errlog); wait = false)

        # Wait until the child holds the write lock with the plan applied but not committed.
        deadline = time() + 180
        while !isfile(marker) && process_running(proc) && time() < deadline
            sleep(0.2)
        end
        isfile(marker) || error("race child never took the lock:\n" * (isfile(errlog) ? read(errlog, String) : ""))

        started_at = time()
        r = _mo737_quiet(() -> Migrations.migrate(pool, settings; interactive = false))
        wait(proc)
        @test success(proc)
        # The race really happened: `migrate` had a head start of more than 2 s on the child's
        # COMMIT (the child sleeps 6 s after the marker). If this loop stalled until the child had
        # committed, the pre-#737 guard would see the row too and the test would prove nothing.
        # (A first-call compile inside `migrate` is not covered by this; the testsets above have
        # already compiled the SQLite path.)
        @test parse(Float64, read(committed_at, String)) - started_at > 2

        # Mutation gate: move the guard back ahead of BEGIN IMMEDIATE and this is a thrown
        # "table already exists" — plus a `failed` row below.
        @test r.outcome === :already_applied
        @test r.version == "race737"
        h = _mo737_history(pool)
        @test nrow(h) == 1 && h.status[1] == "applied"
        @test !isfile(joinpath("db737r", "migrations", "pending_migrations.jl"))
    end
end
