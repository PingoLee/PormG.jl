# ==============================================================================
# TABLE RENAME, APPLIED — Live-Database Integration Test (#615)
#
# `makemigrations` could never rename a table: the planner's rename branch raised before it planned
# anything. #615 repaired it and ordered the rename FIRST — its own bucket, after DROP TABLE and
# before every column statement — so the renamed table's column work names the NEW table while the
# planner reads the OLD table's constraints from the catalog.
#
# Why integration: the unit layer proves that split against a mock (`test/unit/
# test_migration_rename_table.jl`), and the mock only answers what it was told to. Whether a real
# `pg_catalog` / `information_schema` actually returns the constraint names under the old table
# name, and whether the planned DDL actually executes in the planned order, is only provable against
# the engine. SQLite additionally rebuilds both the renamed table (its index snapshot is re-targeted
# at the new name) and the child whose key points at it.
#
# Self-contained, like `test_importers_introspection.jl`: every table is created by the planner from
# models, prefixed `pormg_rt615_`, and dropped in a `finally`. The planner and the introspection are
# scoped to those tables, so the rest of the fixture schema never enters the diff.
#
# Rows are seeded and read back with plain SQL over constants this file chose, not through a model's
# `objects`: the model is renamed half-way through the test, and a registered scratch model would
# need a top-level module plus `set_models` for each of its two names. The ORM is not what is under
# test here — the DDL is.
#
#   julia -t auto --project=test/integration test/integration/test_migration_rename_table.jl
#   PORMG_DB=db_sl julia -t 1 --project=test/integration test/integration/test_migration_rename_table.jl
# ==============================================================================

if !isdefined(Main, :PormG)
    include("common_setup.jl")
end
# column_names() lives in the migration setup helpers.
if !isdefined(Main, :column_names)
    include("common_migration_setup.jl")
end

import PormG.Migrations: LiveTable, read_live_schema, get_migration_plan, _order_statements,
                         _execute_statements_pg, _execute_statements_sqlite
# `with_transaction` is qualified at each call: `common_setup.jl` already binds the name from `PormG`.
import PormG.ConnectionPool: with_sqlite_write_lock, acquire_connection, finalize_transaction_connection!
const _rt615_tx = PormG.ConnectionPool.with_transaction

const RT615 = (parent = "pormg_rt615_parent", old = "pormg_rt615_old",
               new = "pormg_rt615_new", child = "pormg_rt615_child")

_rt615_settings() = (s = PormG.Configuration.Settings(); s.change_db = true; s)

_rt615_schema(models...) = Dict{Symbol, Dict{Symbol, Union{Bool, PormG.PormGModel}}}(
    Symbol(Models.model_table_name(m)) => Dict{Symbol, Union{Bool, PormG.PormGModel}}(:model => m, :exist => false)
    for m in models)

_rt615_live(pool) = read_live_schema(pool; include_table = collect(String, values(RT615)))

# Apply a plan the way `migrate` does — same ordering, same executor, one transaction, and on SQLite
# with foreign-key enforcement suspended on the transaction's own handle (#276) — minus the history
# row and the file archive, which would leave traces of a scratch migration behind.
function _rt615_apply!(pool, plan)
    ordered, _ = _order_statements([plan[k] for k in keys(plan)])
    if pool isa PormG.PormGPostgres
        _, conn = _rt615_tx(pool, "BEGIN;")
        try
            _execute_statements_pg(pool, ordered; conn = conn)
            _rt615_tx(pool, "COMMIT;", conn = conn, release_conn = false)
        catch
            _rt615_tx(pool, "ROLLBACK;", conn = conn, release_conn = false)
            rethrow()
        finally
            finalize_transaction_connection!(pool, conn)
        end
    else
        with_sqlite_write_lock(pool) do
            conn = acquire_connection(pool; mode = :write)
            try
                _rt615_tx(pool, "PRAGMA foreign_keys = OFF;", conn = conn)
                _rt615_tx(pool, "BEGIN IMMEDIATE TRANSACTION;", conn = conn)
                try
                    _execute_statements_sqlite(pool, ordered; conn = conn)
                    _rt615_tx(pool, "COMMIT;", conn = conn, release_conn = false)
                catch
                    _rt615_tx(pool, "ROLLBACK;", conn = conn, release_conn = false)
                    rethrow()
                end
            finally
                # renew: this handle has enforcement OFF and must not go back to the pool as it is.
                finalize_transaction_connection!(pool, conn; renew = true)
            end
        end
    end
    return nothing
end

# ─────────────────────────────────────────────────────────────────────────────
# Table rename: plan, apply, and converge against the live engine
# old → new, carrying what both engines can express: a column rename that also becomes nullable, a
# dropped UNIQUE, an indexed column, and a second table whose key points at the renamed one. The
# rows, the constraint drop (PostgreSQL finds its name only by asking the catalog under the OLD
# name), the indexes and the child's key must all survive, and the next `makemigrations` must
# propose nothing.
# ─────────────────────────────────────────────────────────────────────────────
@testset "Table rename, applied ($(PORMG_DB_FOLDER)) (#615)" begin
    pool = PormG.config[PORMG_DB_FOLDER].connections
    is_pg = pool isa PormG.PormGPostgres
    # Every value below is a constant this file chose, so the SQL carries literals and no parameters.
    q(sql) = PormG.ConnectionPool.fetch(pool, sql) |> DataFrame
    # A write returns no columns, which `DataFrame` cannot build on SQLite — so writes skip it.
    exec(sql) = (PormG.ConnectionPool.fetch(pool, sql); nothing)
    # Child before parents: SQLite enforces foreign keys outside a migration (#276).
    drop_all() = for t in (RT615.child, RT615.old, RT615.new, RT615.parent)
        try; PormG.ConnectionPool.fetch(pool, Dialect.drop_table(pool, t)); catch; end
    end

    drop_all()
    try
        # v1, created by the planner from nothing.
        parent = Models.Model(RT615.parent; id = Models.IDField(), name = Models.CharField(max_length = 20))
        old_v1 = Models.Model(RT615.old; id = Models.IDField(),
                              code = Models.CharField(max_length = 20, unique = true),
                              label = Models.CharField(max_length = 20, db_index = true),
                              n = Models.IntegerField(),
                              parent_id = Models.ForeignKey(parent; pk_field = "id", null = true))
        child_v1 = Models.Model(RT615.child; id = Models.IDField(),
                                tbl_id = Models.ForeignKey(old_v1; pk_field = "id", null = true))
        _rt615_apply!(pool, get_migration_plan(LiveTable[], _rt615_schema(parent, old_v1, child_v1), pool,
                                               _rt615_settings(); interactive = false))

        exec("""INSERT INTO "$(RT615.parent)" ("id", "name") VALUES (1, 'p')""")
        exec("""INSERT INTO "$(RT615.old)" ("id", "code", "label", "n", "parent_id") VALUES (1, 'a', 'L1', 10, 1), (2, 'b', 'L2', 20, 1)""")
        exec("""INSERT INTO "$(RT615.child)" ("id", "tbl_id") VALUES (1, 2)""")

        # v2: renamed table, `n` renamed to a nullable `m`, `code` no longer UNIQUE.
        new_v2 = Models.Model(RT615.new; id = Models.IDField(),
                              code = Models.CharField(max_length = 20),
                              label = Models.CharField(max_length = 20, db_index = true),
                              m = Models.IntegerField(null = true),
                              parent_id = Models.ForeignKey(parent; pk_field = "id", null = true))
        child_v2 = Models.Model(RT615.child; id = Models.IDField(),
                                tbl_id = Models.ForeignKey(new_v2; pk_field = "id", null = true))
        schema_v2 = _rt615_schema(parent, new_v2, child_v2)

        # "no" (not a new table), "1" (its former name), "1" (`m` is the old `n`).
        path, io = mktemp(); write(io, "no\n1\n1\n"); close(io)
        plan = open(path) do f
            redirect_stdin(f) do
                redirect_stdout(devnull) do
                    get_migration_plan(_rt615_live(pool), schema_v2, pool, _rt615_settings(); interactive = true)
                end
            end
        end
        new_key = Symbol(RT615.new)
        @test plan[new_key]["Rename table"] == "ALTER TABLE \"$(RT615.old)\" RENAME TO \"$(RT615.new)\";"
        @test !haskey(plan, Symbol(RT615.old))
        # The child plans nothing (#678): both engines carry its constraint across the rename, which
        # the dangling-insert check and the converged re-diff below then confirm on the real engine.
        @test !haskey(plan, Symbol(RT615.child))
        if is_pg
            # The UNIQUE constraint's name exists only in the catalog, under the old table.
            @test occursin("DROP CONSTRAINT", plan[new_key]["Alter field: code"])
        end

        _rt615_apply!(pool, plan)

        # The table moved, and the old name is gone.
        @test !isempty(column_names(pool, RT615.new))
        @test isempty(column_names(pool, RT615.old))

        # Rows carried across, the renamed column included.
        rows = q("""SELECT "id", "code", "label", "m" FROM "$(RT615.new)" ORDER BY "id" """)
        @test rows.id == [1, 2]
        @test rows.code == ["a", "b"]
        @test rows.m == [10, 20]

        # `label`'s index came through (the SQLite rebuild re-creates it from a snapshot taken under
        # the old table name), read the way the next makemigrations will read it.
        live_new = only(filter(t -> t.name == RT615.new, _rt615_live(pool)))
        @test haskey(live_new.indexes, "label")

        # UNIQUE really is gone: a duplicate code goes in.
        exec("""INSERT INTO "$(RT615.new)" ("id", "code", "label", "m", "parent_id") VALUES (3, 'a', 'L3', NULL, 1)""")
        @test only(q("""SELECT COUNT(*) AS c FROM "$(RT615.new)" WHERE "code" = 'a'""").c) == 2

        # The child still references the renamed table, and enforcement sees it.
        dangling = try
            exec("""INSERT INTO "$(RT615.child)" ("id", "tbl_id") VALUES (2, 999)"""); nothing
        catch e; e; end
        @test dangling !== nothing

        # Converged: the next makemigrations proposes nothing and asks nothing.
        again = get_migration_plan(_rt615_live(pool), schema_v2, pool, _rt615_settings(); interactive = false)
        @test isempty(again)
    finally
        drop_all()
    end
end
