# ==============================================================================
# IDField(generated = false), A KEY NO ENGINE FILLS — Live-Database Integration Test (#1393)
#
# Since #1334 `IDField(generated = false)` is the one spelling for an integer key the caller supplies,
# but only PostgreSQL's DDL read `generated`. SQLite and MySQL rendered an auto-increment key for it,
# and the write paths treated it as database-generated: `allocate_primary_keys` on PostgreSQL returned
# the frame with the ids missing (`nextval` of a sequence that does not exist), and `bulk_insert` left
# an all-blank key column out of the INSERT.
#
# Why integration: the unit layer (`test/unit/test_idfield_generated_key.jl`) proves the predicate and
# the SQLite half on a temp file. What only the engines can say: that the rebuilt or altered table is
# one the database refuses to fill (measured below on each), that the planned migration runs —
# including MySQL's `MODIFY COLUMN` on a key another table's foreign key references — and that the
# catalog reads the result back as `IDField(generated = false)`.
#
# Self-contained: every table is created by the planner from models, prefixed `pormg_ig1393_`, and
# dropped before and in a `finally`. The planner and the introspection are scoped to those tables.
#
#   julia -t auto --project=test/integration test/integration/test_idfield_generated_key.jl
#   PORMG_DB=db_sl julia -t 1 --project=test/integration test/integration/test_idfield_generated_key.jl
#   PORMG_DB=db_my julia -t auto --project=test/integration test/integration/test_idfield_generated_key.jl
# ==============================================================================

if !isdefined(Main, :PormG)
    include("common_setup.jl")
end

import PormG.Migrations: LiveTable, read_live_schema, get_migration_plan, _order_statements,
                         _execute_statements_pg, _execute_statements_sqlite, _split_mysql_statements,
                         convert_schema_to_models, column_spec
import PormG.ConnectionPool: with_sqlite_write_lock, acquire_connection, finalize_transaction_connection!
const _ig1393_tx = PormG.ConnectionPool.with_transaction

const IG1393 = (circuit = "pormg_ig1393_circuit", lap = "pormg_ig1393_lap", auto = "pormg_ig1393_auto")

_ig1393_settings() = (s = PormG.Configuration.Settings(); s.change_db = true; s)

_ig1393_schema(models...) = Dict{Symbol, Dict{Symbol, Union{Bool, PormG.PormGModel}}}(
    Symbol(Models.model_table_name(m)) => Dict{Symbol, Union{Bool, PormG.PormGModel}}(:model => m, :exist => false)
    for m in models)

_ig1393_live(pool) = read_live_schema(pool; include_table = collect(String, values(IG1393)))

# Apply a plan the way `migrate` does, minus the history row and the archive (`test_migration_rename_table.jl`).
function _ig1393_apply!(pool, plan)
    ordered, _ = _order_statements([plan[k] for k in keys(plan)])
    pg = () -> begin
        _, conn = _ig1393_tx(pool, "BEGIN;")
        try
            _execute_statements_pg(pool, ordered; conn = conn)
            _ig1393_tx(pool, "COMMIT;", conn = conn, release_conn = false)
        catch
            _ig1393_tx(pool, "ROLLBACK;", conn = conn, release_conn = false)
            rethrow()
        finally
            finalize_transaction_connection!(pool, conn)
        end
    end
    sl = () -> with_sqlite_write_lock(pool) do
        conn = acquire_connection(pool; mode = :write)
        try
            _ig1393_tx(pool, "PRAGMA foreign_keys = OFF;", conn = conn)
            _ig1393_tx(pool, "BEGIN IMMEDIATE TRANSACTION;", conn = conn)
            try
                _execute_statements_sqlite(pool, ordered; conn = conn)
                _ig1393_tx(pool, "COMMIT;", conn = conn, release_conn = false)
            catch
                _ig1393_tx(pool, "ROLLBACK;", conn = conn, release_conn = false)
                rethrow()
            end
        finally
            finalize_transaction_connection!(pool, conn; renew = true)
        end
    end
    my = () -> begin
        conn = acquire_connection(pool)
        try
            for entry in ordered, statement in _split_mysql_statements(entry)
                _ig1393_tx(pool, statement; conn = conn)
            end
        finally
            finalize_transaction_connection!(pool, conn; renew = true)
        end
    end
    by_engine(pool; postgres = pg, sqlite = sl, mysql = my)()
    return nothing
end

_ig1393_err(f) = try
    f(); nothing
catch e
    e
end

# The F1 circuit table, keyed by the source system's id; a lap row references it.
_ig1393_circuit(; generated::Bool) = Models.Model(IG1393.circuit;
    circuitid = Models.IDField(generated = generated), name = Models.CharField(max_length = 255))
_ig1393_lap(circuit) = Models.Model(IG1393.lap; lapid = Models.IDField(),
    circuitid = Models.ForeignKey(circuit; pk_field = "circuitid", null = true))
_ig1393_auto() = Models.Model(IG1393.auto;
    circuitid = Models.IDField(), name = Models.CharField(max_length = 255))

@testset "IDField(generated = false) on $(PORMG_DB_FOLDER) (#1393)" begin
    pool = PormG.config[PORMG_DB_FOLDER].connections
    q(sql) = PormG.ConnectionPool.fetch(pool, engine_sql(sql)) |> DataFrame
    exec(sql) = (PormG.ConnectionPool.fetch(pool, engine_sql(sql)); nothing)
    # Child first (#276), so no engine needs CASCADE or suspended key checks. Not `Dialect.drop_table`:
    # on MySQL that is three statements meant for one connection, which `fetch` cannot run, so a
    # swallowed error there left the tables behind for the next run.
    drop_all() = for t in (IG1393.lap, IG1393.circuit, IG1393.auto)
        exec("""DROP TABLE IF EXISTS "$(t)" """)
    end
    connected(m) = (m.connect_key = PORMG_DB_FOLDER; m)

    drop_all()
    try
        # What: a table made by the DDL the code before #1393 rendered for `IDField(generated = false)`
        # — no identity on PostgreSQL, an auto-increment key on SQLite and MySQL (what `IDField()`
        # renders there) — plans the identity change, which runs, keeps the rows and the foreign key,
        # and leaves a key the database refuses to fill. Expected plan: nothing on PostgreSQL, a table
        # rebuild on SQLite, `MODIFY COLUMN` without `AUTO_INCREMENT` on MySQL. Why: that is the
        # migration the upgrade entry announces, and on MySQL the key is referenced by a foreign key.
        @testset "the old DDL plans the identity change, applied" begin
            old = _ig1393_circuit(generated = by_engine(pool; postgres = false, sqlite = true, mysql = true))
            _ig1393_apply!(pool, get_migration_plan(LiveTable[], _ig1393_schema(old, _ig1393_lap(old)), pool,
                                                    _ig1393_settings(); interactive = false))
            exec("""INSERT INTO "$(IG1393.circuit)" ("circuitid", "name") VALUES (14, 'Monza'), (13, 'Spa')""")
            exec("""INSERT INTO "$(IG1393.lap)" ("lapid", "circuitid") VALUES (1, 14)""")

            supplied = _ig1393_circuit(generated = false)
            schema = _ig1393_schema(supplied, _ig1393_lap(supplied))
            plan = get_migration_plan(_ig1393_live(pool), schema, pool, _ig1393_settings(); interactive = false)
            key = Symbol(IG1393.circuit)
            by_engine(pool;
                postgres = () -> @test(isempty(plan)),
                sqlite = () -> @test(haskey(plan, key) && any(occursin("INSERT INTO", s) for s in values(plan[key]))),
                mysql = () -> begin
                    sql = plan[key]["Alter field: circuitid"]
                    @test occursin("MODIFY COLUMN `circuitid` BIGINT NOT NULL", sql)
                    @test !occursin("AUTO_INCREMENT", sql)
                end)()
            @test !haskey(plan, Symbol(IG1393.lap))

            _ig1393_apply!(pool, plan)

            rows = q("""SELECT "circuitid", "name" FROM "$(IG1393.circuit)" ORDER BY "circuitid" """)
            @test rows.circuitid == [13, 14] && rows.name == ["Spa", "Monza"]
            @test only(q("""SELECT "circuitid" FROM "$(IG1393.lap)" """).circuitid) == 14
            # The foreign key still holds after the rebuild / MODIFY.
            @test _ig1393_err(() -> exec("""INSERT INTO "$(IG1393.lap)" ("lapid", "circuitid") VALUES (2, 999)""")) !== nothing

            # Measured: an INSERT without the key is refused, where SQLite and MySQL used to fill it.
            # Each engine's own classification: PostgreSQL's 23502 and SQLite's NOT NULL constraint are
            # integrity errors (measured); MySQL reports error 1364, which its classifier does not list
            # with the integrity errors (`_INTEGRITY_ERRNOS`), so only the umbrella is pinned there.
            refused = by_engine(pool; postgres = IntegrityError, sqlite = IntegrityError, mysql = PormGError)
            e = _ig1393_err(() -> exec("""INSERT INTO "$(IG1393.circuit)" ("name") VALUES ('Suzuka')"""))
            @test e isa refused
            @test only(q("""SELECT COUNT(*) AS c FROM "$(IG1393.circuit)" """).c) == 2

            # Converged.
            @test isempty(get_migration_plan(_ig1393_live(pool), schema, pool, _ig1393_settings(); interactive = false))
        end

        # What: on the write path a caller-supplied key is caller data, on a generated key the database
        # still allocates. Expected: `allocate_primary_keys` raises `QueryBuildError` naming the engine
        # for `generated = false` (PostgreSQL returned the ids missing before #1393); a blank key cell in
        # `bulk_insert` raises `InvalidValueError` and sends nothing; explicit ids insert; a frame without
        # the key column is refused by the database. Why: these are the calls the upgrade entry says
        # now raise.
        @testset "the write path: a caller-supplied key and a generated one" begin
            supplied = connected(_ig1393_circuit(generated = false))
            auto = connected(_ig1393_auto())
            _ig1393_apply!(pool, get_migration_plan(_ig1393_live(pool), _ig1393_schema(supplied, _ig1393_lap(supplied), auto),
                                                    pool, _ig1393_settings(); interactive = false))
            before = supplied.objects.count()

            e = _ig1393_err(() -> allocate_primary_keys(supplied.objects, DataFrame(name = ["Suzuka", "Imola"])))
            @test e isa QueryBuildError
            engine_name = by_engine(pool; postgres = "PostgreSQL", sqlite = "SQLite", mysql = "MySQL")
            @test occursin("IDField(generated = false)", sprint(showerror, e)) && occursin(engine_name, sprint(showerror, e))

            for blank in ([missing, missing], [missing, 22])
                e = _ig1393_err(() -> bulk_insert(supplied.objects, DataFrame(circuitid = blank, name = ["Suzuka", "Imola"])))
                @test (repr(blank), typeof(e)) == (repr(blank), InvalidValueError)
            end
            refused = by_engine(pool; postgres = IntegrityError, sqlite = IntegrityError, mysql = PormGError)
            e = _ig1393_err(() -> bulk_insert(supplied.objects, DataFrame(name = ["Suzuka"])))
            @test e isa refused
            e = _ig1393_err(() -> supplied.objects.create("name" => "Suzuka"))
            @test e isa PormGError
            @test supplied.objects.count() == before

            @test bulk_insert(supplied.objects, DataFrame(circuitid = [22, 21], name = ["Suzuka", "Imola"])).count == 2
            @test supplied.objects.count() == before + 2

            # The generated key, for contrast: an all-blank column is left out and the database allocates.
            @test bulk_insert(auto.objects, DataFrame(circuitid = [missing, missing], name = ["Monza", "Spa"])).count == 2
            @test auto.objects.count() == 2
            allocated = _ig1393_err(() -> allocate_primary_keys(auto.objects, DataFrame(name = ["Suzuka"])))
            if requires(:preallocated_keys)
                @test allocated === nothing
            else
                @test allocated isa BackendCapabilityError
            end
        end

        # What: the catalog reads the migrated table back as `IDField(generated = false)` and the
        # generated table as `IDField()`, and the imported models plan nothing. Why: a regenerated
        # models file must say what the table does; before #1393 SQLite and MySQL had no table that
        # could read back as a caller-supplied key.
        @testset "inspectdb round trip" begin
            models = Base.CoreLogging.with_logger(Base.CoreLogging.NullLogger()) do
                convert_schema_to_models(pool; include_table = [IG1393.circuit, IG1393.auto])
            end
            by = Dict(lowercase(string(m.name)) => m for m in models)
            @test by[IG1393.circuit].fields["circuitid"].generated === false
            @test by[IG1393.auto].fields["circuitid"].generated === true
            @test occursin("circuitid = Models.IDField(generated=false)", Models.Model_to_str(by[IG1393.circuit]))
            live = Dict(t.name => t for t in _ig1393_live(pool))
            for t in (IG1393.circuit, IG1393.auto)
                spec = live[t].columns["circuitid"]
                @test (t, column_spec(by[t].fields["circuitid"], pool; name = "circuitid") == spec) == (t, true)
            end
        end
    finally
        drop_all()
    end
end
