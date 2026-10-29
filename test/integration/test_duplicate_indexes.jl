# ==============================================================================
# DUPLICATE ONE-COLUMN INDEXES, APPLIED — Live-Database Integration Test (#1341)
#
# A column can carry the same plain index more than once, under several names: every plan that read
# the column as unindexed (#325) created one more copy, because a `db_index` name ended in a random
# suffix and `IF NOT EXISTS` compares names. The readers kept one name per column, so the planner
# never saw the extras, and removing `db_index` dropped only one of them.
#
# Why integration: the unit layer (`test/unit/test_duplicate_one_column_indexes.jl`) drives the
# planner on hand-built live tables and the SQLite reader on a temporary file. Whether PostgreSQL's
# `indexes` CTE and MySQL's `information_schema.STATISTICS` reader return every copy, and whether the
# planned `DROP INDEX` statements run, is only provable against the engine.
#
# Self-contained: the table is created by the planner from a model, prefixed `pormg_dx1341_`, and
# dropped in a `finally`; the planner and the introspection are scoped to it. The extra copies are
# planted with `Dialect.create_index`, the statement the planner itself renders.
#
#   julia -t auto --project=test/integration test/integration/test_duplicate_indexes.jl
#   PORMG_DB=db_sl julia -t 1 --project=test/integration test/integration/test_duplicate_indexes.jl
#   PORMG_DB=db_my julia -t auto --project=test/integration test/integration/test_duplicate_indexes.jl
# ==============================================================================

if !isdefined(Main, :PormG)
    include("common_setup.jl")
end

import PormG.Migrations: LiveTable, read_live_schema, get_migration_plan, _order_statements,
                         _execute_statements_pg, _execute_statements_sqlite, _split_mysql_statements
import PormG.ConnectionPool: with_sqlite_write_lock, acquire_connection, finalize_transaction_connection!
const _dx1341_tx = PormG.ConnectionPool.with_transaction

const DX1341 = "pormg_dx1341_result"

_dx1341_settings() = (s = PormG.Configuration.Settings(); s.change_db = true; s)
_dx1341_schema(m) = Dict{Symbol, Dict{Symbol, Union{Bool, PormG.PormGModel}}}(
    Symbol(Models.model_table_name(m)) => Dict{Symbol, Union{Bool, PormG.PormGModel}}(:model => m, :exist => false))
_dx1341_model(; db_index::Bool) = Models.Model(DX1341; id = Models.IDField(),
                                               grid = Models.IntegerField(db_index = db_index),
                                               points = Models.FloatField(default = 0.0))
_dx1341_live(pool) = read_live_schema(pool; include_table = [DX1341])
_dx1341_plan(pool, m) = get_migration_plan(_dx1341_live(pool), _dx1341_schema(m), pool, _dx1341_settings();
                                           interactive = false)

# Apply a plan the way `migrate` does — its ordering and executor, one transaction where the engine
# has one — minus the history row and the file archive (the `test_migration_rename_table.jl` shape).
function _dx1341_apply!(pool, plan)
    ordered, _ = _order_statements([plan[k] for k in keys(plan)])
    pg = () -> begin
        _, conn = _dx1341_tx(pool, "BEGIN;")
        try
            _execute_statements_pg(pool, ordered; conn = conn)
            _dx1341_tx(pool, "COMMIT;", conn = conn, release_conn = false)
        catch
            _dx1341_tx(pool, "ROLLBACK;", conn = conn, release_conn = false)
            rethrow()
        finally
            finalize_transaction_connection!(pool, conn)
        end
    end
    sl = () -> with_sqlite_write_lock(pool) do
        conn = acquire_connection(pool; mode = :write)
        try
            _dx1341_tx(pool, "BEGIN IMMEDIATE TRANSACTION;", conn = conn)
            try
                _execute_statements_sqlite(pool, ordered; conn = conn)
                _dx1341_tx(pool, "COMMIT;", conn = conn, release_conn = false)
            catch
                _dx1341_tx(pool, "ROLLBACK;", conn = conn, release_conn = false)
                rethrow()
            end
        finally
            finalize_transaction_connection!(pool, conn)
        end
    end
    my = () -> begin
        conn = acquire_connection(pool)
        try
            for entry in ordered, statement in _split_mysql_statements(entry)
                _dx1341_tx(pool, statement; conn = conn)
            end
        finally
            finalize_transaction_connection!(pool, conn; renew = true)
        end
    end
    by_engine(pool; postgres = pg, sqlite = sl, mysql = my)()
    return nothing
end

# ─────────────────────────────────────────────────────────────────────────────
# What: a `db_index` column carrying three copies of its index is read with all three, the plan
# keeps the one named `<table>_grid_idx` and drops the other two, and the next plan is empty;
# removing `db_index` with two copies live then drops both in one plan.
# SQL: CREATE INDEX IF NOT EXISTS "pormg_dx1341_result_grid_idx" ON "pormg_dx1341_result" ("grid");
#      (MySQL: no IF NOT EXISTS), then one "Remove duplicate index <name> on grid" DROP INDEX per extra.
# Why: before #1341 each reader kept one name per column, so this plan was empty and the copies stayed
# for good; and the index was created under a random name, so a repeated plan made another copy.
# ─────────────────────────────────────────────────────────────────────────────
@testset "Duplicate one-column indexes, applied ($(PORMG_DB_FOLDER)) (#1341)" begin
    pool = PormG.config[PORMG_DB_FOLDER].connections
    drop_scratch_tables!(pool, DX1341)
    try
        declared = _dx1341_model(db_index = true)
        created = get_migration_plan(LiveTable[], _dx1341_schema(declared), pool, _dx1341_settings(); interactive = false)
        derived = "$(DX1341)_grid_idx"
        @test occursin(derived, created[Symbol(DX1341)]["Create index on grid"])
        _dx1341_apply!(pool, created)

        # Two more copies, under the names a random-suffix era would have left.
        extras = ["$(DX1341)_grid_s21bkzlw_idx", "$(DX1341)_grid_zndqsv7m_idx"]
        plant!(name) = PormG.ConnectionPool.fetch(pool, PormG.Dialect.create_index(pool,
            PormG.Dialect._ddl_ident(pool, name), PormG.Dialect._ddl_ident(pool, DX1341),
            [PormG.Dialect._ddl_ident(pool, "grid")]))
        foreach(plant!, extras)

        live = only(_dx1341_live(pool))
        @test live.indexes["grid"] == sort([derived; extras])

        plan = _dx1341_plan(pool, declared)
        steps = collect(plan[Symbol(DX1341)])
        @test first.(steps) == ["Remove duplicate index $(n) on grid" for n in extras]
        @test all(s -> startswith(last(s), "DROP INDEX"), steps)
        _dx1341_apply!(pool, plan)

        @test only(_dx1341_live(pool)).indexes["grid"] == [derived]
        @test !haskey(_dx1341_plan(pool, declared), Symbol(DX1341))

        # A copy again, then the field stops declaring the index: every copy goes in one plan, and
        # nothing is left (the planner used to drop one per run).
        plant!(extras[1])
        undeclared = _dx1341_model(db_index = false)
        dropping = _dx1341_plan(pool, undeclared)
        @test first.(collect(dropping[Symbol(DX1341)])) ==
              ["Remove index on grid", "Remove duplicate index $(extras[1]) on grid"]
        _dx1341_apply!(pool, dropping)
        @test !haskey(only(_dx1341_live(pool)).indexes, "grid")
        @test !haskey(_dx1341_plan(pool, undeclared), Symbol(DX1341))
    finally
        drop_scratch_tables!(pool, DX1341)
    end
end
