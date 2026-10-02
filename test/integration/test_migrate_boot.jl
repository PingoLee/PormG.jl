# =============================================================================
# migrate() at boot, against a real PostgreSQL server (#737)
#
# The unit file `test/unit/test_migrate_outcome.jl` pins the outcome contract and the ORDER of
# statements with a probe connection. What a probe cannot show is PostgreSQL's side:
#
#   1. a `pool_size: 1` pool can run `migrate` at all, although the lock and the migration each hold
#      a connection (the issue suspected a PoolTimeoutError; the pool grows on demand);
#   2. a held migration lock makes `migrate` give up after `lock_wait`, naming the holder;
#   3. `lock_timeout` makes a plan statement queued behind another session's table lock fail fast
#      instead of waiting — and blocking every later query on that table — indefinitely;
#   4. a plan whose recorded schema the database no longer holds is refused inside the advisory
#      lock, before BEGIN, with no `failed` row (#739 — the SQLite lifecycle is pinned in
#      `test/unit/test_plan_schema_fingerprint.jl`).
#
# Isolation: each pool gets a temporary `db_def_folder`, so the plan files are private. The shared
# fixture is touched only through one scratch table and the history rows this file writes, and
# both are removed in `finally`. Configured extensions are stripped from the copied settings, so
# no extension DDL runs from here.
#
# julia -t auto --project=test/integration test/integration/test_migrate_boot.jl
# =============================================================================

if !isdefined(Main, :PormG)
    include("common_setup.jl")
end

if adapter_name == "SQLite"
    @info "Skipping migrate-boot lock tests on SQLite (its race is covered by test/unit/test_migrate_outcome.jl)"
else

import OrderedCollections: OrderedDict

const _BOOT737_BASE = PormG.config[haskey(PormG.config, "db_2") ? "db_2" : first(keys(PormG.config))]
const _BOOT737_NAME = "pormg_test_boot737"

# A pool on the fixture database with its own temporary folder and pool size, change_db on.
function _boot737_settings(label::String; pool_size::Int)
    cfg = copy(_BOOT737_BASE.db_config_settings)
    cfg["pool_size"] = pool_size
    delete!(cfg, "extensions")   # no extension DDL from this file
    folder = mktempdir()
    st = PormG.Configuration.Settings(app_env = _BOOT737_BASE.app_env, db_def_folder = folder,
                                      db_config_settings = cfg)
    st.change_db = true
    PormG.Configuration._build_connection_pool!(st, "pormg_test::boot737_$(label)")
    return st
end

function _boot737_close(st)
    try; PormG.Configuration.close_pool!(st.connections); catch; end
    rm(st.db_def_folder; recursive = true, force = true)
end

_boot737_quiet(f) = Base.CoreLogging.with_logger(f, Base.CoreLogging.SimpleLogger(IOBuffer(), Base.CoreLogging.Error))

# ─────────────────────────────────────────────────────────────────────────────
# migrate() at boot: pool_size 1 is enough (#737, gap 7)
# `with_advisory_lock` holds one connection for the whole run, and `init_migrations` and the
# transaction need another. The issue read that as "pool_size: 1 ends in PoolTimeoutError"; the
# pool opens connections on demand up to ten times `pool_size`, so it completes. This is the live
# confirmation the docs' "migrate() holds two" paragraph rests on.
# ─────────────────────────────────────────────────────────────────────────────
@testset "migrate at boot: a pool_size 1 pool completes (#737)" begin
    st = _boot737_settings("pool1"; pool_size = 1)
    try
        r = _boot737_quiet(() -> PormG.Migrations.migrate(st.connections, st; interactive = false))
        @test r.outcome === :nothing_pending
    finally
        _boot737_close(st)
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# migrate() at boot: a held lock is waited on for lock_wait, then named (#737)
# Another session holds the migration lock — the shape of a second instance mid-migration. A raw
# leased connection takes it, so the test knows the holder's pid and sets its application_name.
# `migrate(lock_wait = 1)` must give up after about a second, not the old hard-coded 30, and the
# error must say who is holding it.
# ─────────────────────────────────────────────────────────────────────────────
@testset "migrate at boot: lock_wait bounds the queue and names the holder (#737)" begin
    holder = _boot737_settings("holder"; pool_size = 2)
    waiter = _boot737_settings("waiter"; pool_size = 2)
    conn = PormG.ConnectionPool.acquire_connection(holder.connections)
    try
        run_on(sql) = DataFrame(first(PormG.ConnectionPool.with_transaction(holder.connections, sql; conn = conn)))
        run_on("SET application_name = 'pormg_boot737_holder';")
        holder_pid = run_on("SELECT pg_backend_pid() AS pid;").pid[1]
        lk = PormG.QueryBuilder.PgParameterizedQuery("", Any[], 0)
        ph = PormG.QueryBuilder.add_parameter!(lk, PormG.Migrations.MIGRATION_LOCK_KEY)
        key_expr = "(( 'x' || substr(md5($(ph)), 1, 16))::bit(64))::bigint"
        PormG.ConnectionPool.with_transaction(holder.connections, "SELECT pg_advisory_lock($(key_expr));";
                                              conn = conn, params = lk)
        try
            t0 = time()
            err = try
                _boot737_quiet(() -> PormG.Migrations.migrate(waiter.connections, waiter;
                                                              interactive = false, lock_wait = 1))
                nothing
            catch e
                e
            end
            elapsed = time() - t0
            @test err isa PormG.OperationalError
            msg = err === nothing ? "" : sprint(showerror, err)
            @test occursin("pormg::migrations", msg)
            # Mutation gate: without the holder lookup this is the bare "Failed to acquire …".
            @test occursin("held by pid $(holder_pid) (pormg_boot737_holder)", msg)
            @test elapsed < 15   # waited ~1 s, not the old fixed 30
        finally
            PormG.ConnectionPool.with_transaction(holder.connections, "SELECT pg_advisory_unlock($(key_expr));";
                                                  conn = conn, params = lk)
            PormG.ConnectionPool.with_transaction(holder.connections, "RESET application_name;"; conn = conn)
        end
    finally
        PormG.ConnectionPool.release_connection(holder.connections, conn)
        _boot737_close(holder)
        _boot737_close(waiter)
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# migrate() at boot: lock_timeout fails a queued ALTER fast (#737)
# Another session holds a table in an open transaction (a plain SELECT is enough: ALTER TABLE needs
# ACCESS EXCLUSIVE). Without a bound, the plan's ALTER waits for it — and while it waits, every
# later query on the table queues behind the ALTER. With `lock_timeout = 1` the statement fails
# after about a second, the plan rolls back, and `migrate` rethrows.
# ─────────────────────────────────────────────────────────────────────────────
@testset "migrate at boot: lock_timeout bounds a plan queued behind a table lock (#737)" begin
    table = "pormg_boot737_scratch"
    blocker = _boot737_settings("blocker"; pool_size = 2)
    st = _boot737_settings("timeout"; pool_size = 2)
    PormG.ConnectionPool.fetch(st.connections, "CREATE TABLE IF NOT EXISTS \"$(table)\" (id integer);")
    _, bconn = PormG.ConnectionPool.with_transaction(blocker.connections, "BEGIN;")
    try
        PormG.ConnectionPool.with_transaction(blocker.connections, "SELECT * FROM \"$(table)\";"; conn = bconn)

        plan = OrderedDict{Symbol, OrderedDict{String, String}}(
            Symbol(table) => OrderedDict{String, String}(
                "Add field: note" => "ALTER TABLE \"$(table)\" ADD COLUMN \"note\" TEXT;"))
        mkpath(joinpath(st.db_def_folder, "migrations"))
        PormG.Generator.generate_migration_plan("pending_migrations.jl", plan, joinpath(st.db_def_folder, "migrations"))

        # Without the bound the ALTER would wait for as long as the blocker holds on — forever,
        # here. The watchdog ends the blocker's transaction after 20 s so that case FAILS below
        # (the ALTER then succeeds and nothing is thrown) instead of hanging the run.
        watchdog = Timer(20) do _
            try; PormG.ConnectionPool.with_transaction(blocker.connections, "ROLLBACK;"; conn = bconn); catch; end
        end
        t0 = time()
        err = try
            _boot737_quiet(() -> PormG.Migrations.migrate(st.connections, st; interactive = false,
                                                          name = _BOOT737_NAME, lock_timeout = 1))
            nothing
        catch e
            e
        end
        elapsed = time() - t0
        close(watchdog)
        # Mutation gate: without the SET LOCAL, `err === nothing` after ~20 s.
        @test err isa PormG.DatabaseError
        @test err !== nothing && occursin("lock timeout", lowercase(sprint(showerror, err)))
        @test elapsed < 15
        # The plan rolled back: the column is not there, and the attempt is recorded as failed.
        cols = DataFrame(PormG.ConnectionPool.fetch(st.connections,
            "SELECT column_name FROM information_schema.columns WHERE table_name = '$(table)';"))
        @test !("note" in cols.column_name)
        rows = DataFrame(PormG.ConnectionPool.fetch(st.connections,
            "SELECT status FROM pormg_migrations WHERE name = '$(_BOOT737_NAME)';"))
        @test rows.status == ["failed"]
    finally
        PormG.ConnectionPool.with_transaction(blocker.connections, "ROLLBACK;"; conn = bconn)
        PormG.ConnectionPool.release_connection(blocker.connections, bconn)
        PormG.ConnectionPool.fetch(st.connections, "DELETE FROM pormg_migrations WHERE name = '$(_BOOT737_NAME)';")
        PormG.ConnectionPool.fetch(st.connections, "DROP TABLE IF EXISTS \"$(table)\";")
        _boot737_close(blocker)
        _boot737_close(st)
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# migrate() at boot: the schema precondition on PostgreSQL (#739)
# The unit file pins the SQLite lifecycle; this is the PostgreSQL one, where the deciding check runs
# inside the advisory lock and before BEGIN. A plan recording a scratch table's fingerprint is
# refused once the table is altered out of band — through `migrate` (the early check) and through
# the locked lifecycle alone (the in-lock check) — with no `failed` row and the plan's column not
# added. Back in its recorded state, the table takes the plan, and a `failed` row of that same
# checksum written earlier is then reported as superseded by `status()`.
# ─────────────────────────────────────────────────────────────────────────────
@testset "migrate at boot: a drifted plan is refused inside the lock (#739)" begin
    table = "pormg_boot739_scratch"
    name = "pormg_test_boot739"
    st = _boot737_settings("precondition"; pool_size = 2)
    pg = st.connections
    try
        PormG.ConnectionPool.fetch(pg, "CREATE TABLE IF NOT EXISTS \"$(table)\" (id integer PRIMARY KEY);")
        PormG.Migrations.init_migrations(pg)
        live_fp() = PormG.Migrations._schema_table_fingerprint(
            only(PormG.Migrations.read_live_schema(pg; include_table = [table])))
        recorded = OrderedDict{String, String}(table => live_fp())

        plan = OrderedDict{Symbol, OrderedDict{String, String}}(
            Symbol(table) => OrderedDict{String, String}(
                "Add field: note" => "ALTER TABLE \"$(table)\" ADD COLUMN \"note\" TEXT;"))
        folder = joinpath(st.db_def_folder, "migrations")
        mkpath(folder)
        PormG.Generator.generate_migration_plan("pending_migrations.jl", plan, folder; schema_tables = recorded)
        stmts, all_sql = PormG.Migrations._order_statements(PormG.Migrations._load_migration_plan(st))
        checksum = PormG.Migrations.compute_checksum(all_sql)
        columns() = DataFrame(PormG.ConnectionPool.fetch(pg,
            "SELECT column_name FROM information_schema.columns WHERE table_name = '$(table)';")).column_name
        rows() = DataFrame(PormG.ConnectionPool.fetch(pg,
            "SELECT status FROM pormg_migrations WHERE name = '$(name)' ORDER BY version;")).status

        # Out of band, after the plan was generated.
        PormG.ConnectionPool.fetch(pg, "ALTER TABLE \"$(table)\" ADD COLUMN \"location\" TEXT;")
        @test live_fp() != recorded[table]

        # Through migrate: refused, nothing written.
        e = try
            _boot737_quiet(() -> PormG.Migrations.migrate(pg, st; interactive = false, name = name)); nothing
        catch err
            err
        end
        @test e isa PormG.Migrations.PlanPreconditionError
        @test e !== nothing && [t.table for t in e.tables] == [table]
        @test !("note" in columns())
        @test isempty(rows())

        # The in-lock check on its own, past the early one: still refused, still nothing recorded.
        e2 = try
            _boot737_quiet(() -> PormG.Migrations._run_locked_lifecycle(pg, st, stmts, all_sql,
                PormG.Migrations.generate_version(), name, checksum, false; schema_tables = recorded)); nothing
        catch err
            err
        end
        @test e2 isa PormG.Migrations.PlanPreconditionError
        @test isempty(rows())

        # A failed attempt of this same plan, recorded before the apply below.
        PormG.Migrations._record_migration(pg, "20000101000000739", name, checksum, all_sql, "failed", false)

        # Back to the recorded state: the plan applies.
        PormG.ConnectionPool.fetch(pg, "ALTER TABLE \"$(table)\" DROP COLUMN \"location\";")
        @test live_fp() == recorded[table]
        r = _boot737_quiet(() -> PormG.Migrations.migrate(pg, st; interactive = false, name = name))
        @test r.outcome === :applied
        @test "note" in columns()
        @test rows() == ["failed", "applied"]

        # status(): the earlier failure of this checksum is superseded, not a failure.
        s = PormG.Migrations.status(pg, st)
        @test any(m -> m[:name] == name, s.superseded)
        @test !any(m -> m[:name] == name, s.failed)
    finally
        PormG.ConnectionPool.fetch(pg, "DELETE FROM pormg_migrations WHERE name = '$(name)';")
        PormG.ConnectionPool.fetch(pg, "DROP TABLE IF EXISTS \"$(table)\";")
        _boot737_close(st)
    end
end

end # adapter_name != "SQLite"
