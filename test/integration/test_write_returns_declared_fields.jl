# ==============================================================================
# A WRITE RETURNS THE MODEL'S FIELDS — Live-Database Integration Test (#1490)
#
# `create()`, `update_or_create()` and `get_or_create()` read back the row they wrote by the model's
# declared columns: PostgreSQL's `RETURNING`, a `SELECT` of those columns on SQLite and MySQL. Before
# #1490 they read it back with `*`, so the row followed the TABLE, and under the Postgres.jl statement
# cache a cached `create()` failed inside a transaction once a deploy added a column.
#
# Why integration: the unit layer (`test/unit/test_write_returning_columns.jl`) pins the statements.
# What only the engines can say: that each statement runs, and that the row it hands back holds the
# model's fields and not the column the table has beside them, on every engine alike. The reads keep
# `SELECT *` (decided on #1490), so a read of the same row, and a `get_or_create()` that finds it,
# still carry the extra column; that is asserted here too, so a change to it is a reviewed diff.
#
# Self-contained: one scratch table, `pormg_wr1490_driver`, created raw because the feature is a
# column the model does not declare, which no model can create. Dropped before and in a `finally`.
#
#   julia -t auto --project=test/integration test/integration/test_write_returns_declared_fields.jl
#   PORMG_DB=db_sl julia -t 1 --project=test/integration test/integration/test_write_returns_declared_fields.jl
#   PORMG_DB=db_my julia -t auto --project=test/integration test/integration/test_write_returns_declared_fields.jl
# ==============================================================================

if !isdefined(Main, :PormG)
    include("common_setup.jl")
end

const WR1490_TABLE = "pormg_wr1490_driver"

# The F1 driver as the model knows it: a key and a surname. The table also has `team`.
function _wr1490_model()
    m = Models.Model(WR1490_TABLE; driverid = Models.IDField(generated = false),
                     surname = Models.CharField(max_length = 50))
    m.connect_key = PORMG_DB_FOLDER
    return m
end

@testset "a write returns the model's fields only (#1490) on $(PORMG_DB_FOLDER)" begin
    pool = PormG.config[PORMG_DB_FOLDER].connections
    drop_scratch_tables!(pool, WR1490_TABLE)
    try
        PormG.ConnectionPool.fetch(pool, engine_sql("""CREATE TABLE "$(WR1490_TABLE)" (
            "driverid" integer PRIMARY KEY, "surname" varchar(50) NOT NULL, "team" varchar(50))"""))
        Driver = _wr1490_model()
        declared = Set([:driverid, :surname])

        # ─────────────────────────────────────────────────────────────────────────────
        # create(): the row holds the declared fields; `team`, which the table has, is not on it.
        # Expected SQL: INSERT … RETURNING "driverid", "surname" (PostgreSQL); INSERT, then
        # SELECT "driverid", "surname" … (SQLite, MySQL). Why: the row is the model's on every engine,
        # and the statement's result type no longer follows the table (#1490).
        # ─────────────────────────────────────────────────────────────────────────────
        @testset "create()" begin
            row = Driver.objects.create("driverid" => 1, "surname" => "Senna")
            @test Set(keys(row)) == declared
            @test row.surname == "Senna" && row.driverid == 1
            @test_throws PormG.UnknownFieldError row.team
        end

        # ─────────────────────────────────────────────────────────────────────────────
        # A read is unchanged (decided on #1490): `get()` sends `SELECT *`, so the same row read
        # back carries `team`. Expected: :team among its keys, holding NULL. Why: recorded so moving
        # the reads onto the column list (a separate decision) shows here as a diff.
        # ─────────────────────────────────────────────────────────────────────────────
        @testset "a read still returns every column" begin
            got = Driver.objects.get("driverid" => 1)
            @test :team in keys(got)
            @test ismissing(got.team) || got.team === nothing
        end

        # ─────────────────────────────────────────────────────────────────────────────
        # update_or_create(): both arms — the insert and the update — return the declared fields.
        # Expected SQL: … RETURNING "driverid", "surname", (xmax = 0) AS "__pormg_created" on
        # PostgreSQL; the by-lookup read-back of those columns on SQLite and MySQL. Why: the sentinel
        # must still be stripped and `created` still exact once the list replaces `*`.
        # ─────────────────────────────────────────────────────────────────────────────
        @testset "update_or_create()" begin
            row, created = Driver.objects.update_or_create("driverid" => 2; defaults = ["surname" => "Prost"])
            @test created
            @test Set(keys(row)) == declared && row.surname == "Prost"
            row, created = Driver.objects.update_or_create("driverid" => 2; defaults = ["surname" => "Alain Prost"])
            @test !created
            @test Set(keys(row)) == declared && row.surname == "Alain Prost"
        end

        # ─────────────────────────────────────────────────────────────────────────────
        # get_or_create(): a miss returns the row it inserted by the declared columns, on every engine
        # (PostgreSQL's RETURNING; the read-back on SQLite and MySQL). A hit is a read and goes
        # through the lookup, so it carries `team`. Expected: miss keys == declared; hit keys ∋ :team.
        # Why: the miss is a write and follows #1490; the hit is a read and does not (decided).
        # ─────────────────────────────────────────────────────────────────────────────
        @testset "get_or_create()" begin
            row, created = Driver.objects.get_or_create("driverid" => 3; defaults = ["surname" => "Piquet"])
            @test created
            @test Set(keys(row)) == declared && row.surname == "Piquet"
            row, created = Driver.objects.get_or_create("driverid" => 3)
            @test !created
            @test :team in keys(row) && row.surname == "Piquet"
        end
    finally
        drop_scratch_tables!(pool, WR1490_TABLE)
    end
end
