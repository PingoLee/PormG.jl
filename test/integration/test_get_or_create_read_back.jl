# =============================================================================
# get_or_create: a read-back miss is a database condition, not a UsageError (#1299)
#
# `get_or_create` reads the row back after its `INSERT … ON CONFLICT DO NOTHING`. When that read finds
# nothing, the caller's call was not at fault, so the error is outside `UsageError` (which an app maps
# to a bad request):
#   - PostgreSQL: `OperationalError`. The conflicting row was deleted between the skipped insert and
#     the read, and the same call retried can succeed;
#   - SQLite: `StatementError`. The call runs under the serialized write lock, so no other writer can
#     interleave; the insert stored nothing the lookup finds, and a retry fails the same way;
#   - MySQL: `StatementError`. A plain INSERT that succeeded and a read that sees it, so a row the
#     lookup misses was changed or dropped on the way in, and a retry fails the same way.
#
# A race cannot be scheduled from a test, so every arm is reached the same way: a scratch table
# whose BEFORE INSERT trigger keeps the lookup from finding the row. On PostgreSQL the trigger function
# returns NULL, so the INSERT reports no row and RETURNING is empty, the shape a lost race leaves. On
# SQLite it is `RAISE(IGNORE)`, so the insert reports success and stores nothing. A MySQL trigger
# cannot skip a row, so it rewrites the key the lookup reads: the insert stores another one. Raw DDL
# because a trigger is what is under test; the call itself goes through the ORM.
#
# Isolation: one scratch table, `goc1299` (and on PostgreSQL its trigger function), dropped before
# and after.
#
# julia -t auto --project=test/integration test/integration/test_get_or_create_read_back.jl
# PORMG_DB=db_sl julia -t 1 --project=test/integration test/integration/test_get_or_create_read_back.jl
# =============================================================================

if !isdefined(Main, :PormG)
    include("common_setup.jl")
end

# Whether this run's account may create the trigger. MySQL refuses a trigger to an account without
# SUPER while binary logging is on (error 1419) unless the server sets `log_bin_trust_function_creators`,
# a server setting rather than a PormG behavior, so the testset is recorded as skipped there.
function _goc1299_can_create_trigger()
    conn = PormG.config[PORMG_DB_FOLDER].connections
    ddl(sql) = PormG.ConnectionPool.fetch(conn, sql)
    ddl("DROP TABLE IF EXISTS goc1299_probe")
    try
        ddl("CREATE TABLE goc1299_probe (id BIGINT AUTO_INCREMENT PRIMARY KEY)")
        ddl("CREATE TRIGGER goc1299_probe_t BEFORE INSERT ON goc1299_probe FOR EACH ROW SET NEW.id = NEW.id")
        return true
    catch e
        cause = e isa PormG.DatabaseError ? getfield(e, :cause) : nothing
        (cause !== nothing && hasproperty(cause, :errno) && Int(cause.errno) == 1419) || rethrow()
        return false
    finally
        ddl("DROP TABLE IF EXISTS goc1299_probe")
    end
end
const GOC1299_TRIGGERS = by_engine(postgres = () -> true, sqlite = () -> true, mysql = _goc1299_can_create_trigger)()
GOC1299_TRIGGERS || @testset "get_or_create read-back miss (#1299): skipped, no trigger privilege" begin
    @test_skip "this MySQL account cannot create a trigger while binary logging is on (error 1419); " *
               "start the server with --log-bin-trust-function-creators=1 to run it"
end

GOC1299_TRIGGERS && @testset "get_or_create: a read-back miss is not a UsageError on $(adapter_name) (#1299)" begin
    # What: `get_or_create("driverref" => <key>)` on a table whose trigger drops the insert raises
    # `OperationalError` on PostgreSQL and `StatementError` on SQLite and MySQL — never a `UsageError` — with
    # a message naming the read-back and not the key, and stores no row. Why: a `UsageError → 400`
    # handler answered a bad request to a race (PostgreSQL) or a fault (SQLite) the caller did not
    # cause and cannot fix by changing the call.
    key = PORMG_DB_FOLDER
    conn = PormG.config[key].connections
    ddl(sql) = PormG.ConnectionPool.fetch(conn, sql)
    source = "module models\nimport PormG.Models\n" *
             "Goc1299 = Models.Model(\"goc1299\",\n    id = Models.IDField(),\n" *
             "    driverref = Models.CharField(max_length = 64, unique = true))\nend\n"
    holder = Module(:Goc1299Holder)
    Base.include_string(holder, source)
    model = Base.invokelatest(getfield, Base.invokelatest(getfield, holder, :models), :Goc1299)
    PormG.Models.bind!(model, key)

    drop!() = by_engine(
        postgres = () -> (ddl("DROP TABLE IF EXISTS goc1299"); ddl("DROP FUNCTION IF EXISTS goc1299_drop_row()")),
        sqlite = () -> ddl("DROP TABLE IF EXISTS goc1299"),
        mysql = () -> ddl("DROP TABLE IF EXISTS goc1299"))()   # its trigger goes with it
    drop!()
    try
        by_engine(
            postgres = () -> begin
                ddl("CREATE TABLE goc1299 (id BIGSERIAL PRIMARY KEY, driverref VARCHAR(64) NOT NULL UNIQUE)")
                ddl("CREATE FUNCTION goc1299_drop_row() RETURNS trigger LANGUAGE plpgsql AS \$\$ BEGIN RETURN NULL; END \$\$")
                ddl("CREATE TRIGGER goc1299_drop_row BEFORE INSERT ON goc1299 FOR EACH ROW EXECUTE FUNCTION goc1299_drop_row()")
            end,
            sqlite = () -> begin
                ddl("CREATE TABLE goc1299 (id INTEGER PRIMARY KEY AUTOINCREMENT, driverref VARCHAR(64) NOT NULL UNIQUE)")
                ddl("CREATE TRIGGER goc1299_drop_row BEFORE INSERT ON goc1299 BEGIN SELECT RAISE(IGNORE); END")
            end,
            mysql = () -> begin
                ddl("CREATE TABLE goc1299 (id BIGINT AUTO_INCREMENT PRIMARY KEY, driverref VARCHAR(64) NOT NULL UNIQUE)")
                ddl("CREATE TRIGGER goc1299_rekey_row BEFORE INSERT ON goc1299 FOR EACH ROW " *
                    "SET NEW.driverref = CONCAT('rekeyed-', NEW.driverref)")
            end)()

        secret = "senna-1299"
        err = try model.objects.get_or_create("driverref" => secret); nothing catch e; e end
        expected = by_engine(postgres = PormG.OperationalError, sqlite = PormG.StatementError,
                             mysql = PormG.StatementError)
        @test err isa expected
        @test !(err isa PormG.UsageError)
        msg = PormG.error_message(err)
        @test occursin("could not be read back", msg)
        @test by_engine(postgres = occursin("a trigger or rule that skips the insert", msg),
                        sqlite = occursin("a trigger may have dropped it", msg),
                        mysql = occursin("the lookup does not match what was stored", msg))
        @test !occursin(secret, msg)
        @test model.objects.filter("driverref" => secret).count() == 0
        # MySQL stored the row under the trigger's key: the miss is the rewrite, not a lost insert.
        by_engine(postgres = () -> nothing, sqlite = () -> nothing,
                  mysql = () -> @test(model.objects.filter("driverref" => "rekeyed-" * secret).count() == 1))()
    finally
        drop!()
    end
end
