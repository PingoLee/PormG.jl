# =============================================================================
# get_or_create: a read-back miss is a database condition, not a UsageError (#1299)
#
# `get_or_create` reads the row back after its `INSERT … ON CONFLICT DO NOTHING`. When that read finds
# nothing, the caller's call was not at fault, so the error is outside `UsageError` (which an app maps
# to a bad request):
#   - PostgreSQL: `OperationalError`. The conflicting row was deleted between the skipped insert and
#     the read, and the same call retried can succeed;
#   - SQLite: `StatementError`. The call runs under the serialized write lock, so no other writer can
#     interleave; the insert stored nothing the lookup finds, and a retry fails the same way.
#
# A race cannot be scheduled from a test, so both arms are reached the same way: a scratch table
# whose BEFORE INSERT trigger drops every row. On PostgreSQL the trigger function returns NULL, so the
# INSERT reports no row and RETURNING is empty, the shape a lost race leaves. On SQLite it is
# `RAISE(IGNORE)`, so the insert reports success and stores nothing. Raw DDL because a trigger is
# what is under test; the call itself goes through the ORM.
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

@testset "get_or_create: a read-back miss is not a UsageError on $(adapter_name) (#1299)" begin
    # What: `get_or_create("driverref" => <key>)` on a table whose trigger drops the insert raises
    # `OperationalError` on PostgreSQL and `StatementError` on SQLite — neither a `UsageError` — with
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
        sqlite = () -> ddl("DROP TABLE IF EXISTS goc1299"))()
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
            end)()

        secret = "senna-1299"
        err = try model.objects.get_or_create("driverref" => secret); nothing catch e; e end
        expected = by_engine(postgres = PormG.OperationalError, sqlite = PormG.StatementError)
        @test err isa expected
        @test !(err isa PormG.UsageError)
        msg = PormG.error_message(err)
        @test occursin("could not be read back", msg)
        @test by_engine(postgres = occursin("a trigger or rule that skips the insert", msg),
                        sqlite = occursin("a trigger may have dropped it", msg))
        @test !occursin(secret, msg)
        @test model.objects.filter("driverref" => secret).count() == 0
    finally
        drop!()
    end
end
