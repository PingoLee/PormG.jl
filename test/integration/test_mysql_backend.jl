# MySQL backend, phase 1 (#1130): the connection, the pool, statements, transactions, error
# classification, cancellation and advisory locks, against a live MySQL 8.4.
#
#   PORMG_DB=db_my julia -t auto --project=test/integration test/integration/test_mysql_backend.jl
#
# Raw SQL throughout, deliberately: the feature under test IS the driver layer, and no model query
# renders for MySQL until phase 2. Every table this file creates is named `pormg_my_phase1_*` and is
# dropped at the end. On another engine the whole file is skipped (`only_on`).
if !isdefined(Main, :PormG)
    include("common_setup.jl")
end
using Test, DataFrames, Dates, Decimals

const _MY_T = "pormg_my_phase1_values"
const _MY_PARENT = "pormg_my_phase1_driver"
const _MY_CHILD = "pormg_my_phase1_result"

@testset "MySQL backend, phase 1 (#1130)" begin
if only_on(:mysql, "drives the MySQL driver extension (ext/PormGMySQLExt.jl)")
    pool = PormG.config[PORMG_DB_FOLDER].connections
    run(sql; params = nothing) = PormG.fetch(pool, sql; params = params)
    rows(sql; params = nothing) = DataFrame(run(sql; params = params))
    msg(e) = sprint(showerror, e)

    for t in (_MY_CHILD, _MY_PARENT, _MY_T)
        run("DROP TABLE IF EXISTS $(t)")
    end

    # What: every connection runs against a MySQL 8.4+ server, in UTC, under 8.4's default sql_mode.
    # SQL: `SELECT @@time_zone, @@sql_mode, @@character_set_client` on a pooled connection.
    # Why: a TIMESTAMP shifts with the session time zone, and a server's global sql_mode (ANSI_QUOTES,
    # PIPES_AS_CONCAT) would change what `"x"` and `||` mean; the extension pins both at connect, and
    # the #1264 floor is checked on the server's own version.
    @testset "a connection is MySQL 8.4+, in UTC, under 8.4's sql_mode" begin
        r = rows("SELECT @@time_zone AS tz, @@sql_mode AS sm, @@character_set_client AS cs")
        @test r.tz[1] == "+00:00"
        @test r.sm[1] == "ONLY_FULL_GROUP_BY,STRICT_TRANS_TABLES,NO_ZERO_IN_DATE,NO_ZERO_DATE," *
                         "ERROR_FOR_DIVISION_BY_ZERO,NO_ENGINE_SUBSTITUTION"
        @test r.cs[1] == "utf8mb4"
        v = PormG._server_version(pool)
        @test v >= 80_400
        @test PormG._supports(pool, :supported_server)
        @test !PormG._supports(pool, :supported_server; server_version = 80_036)
        @test PormG.Kernel._backend_name(pool) == "MySQL"
    end

    # What: bound parameters reach the server as their values and read back as PormG's types.
    # SQL: `INSERT INTO pormg_my_phase1_values (…) VALUES (?, ?, …)`, then `SELECT … WHERE name = ?`.
    # Why: MySQL.jl returns zero-copy views (`DataString`, `DataBytes`), a `DecimalValue` and a
    # `Timestamp`, and cannot bind a `Decimals.Decimal`; a row must leave the extension as owned
    # `String`, `Vector{UInt8}`, `Decimal` and `DateTime` values, and a quote in a value must stay data.
    @testset "parameters bind and read back as PormG's types" begin
        run("""CREATE TABLE $(_MY_T) (id BIGINT PRIMARY KEY AUTO_INCREMENT, name VARCHAR(100) NOT NULL,
               big BIGINT, ratio DOUBLE, pts DECIMAL(12,3), day DATE, at DATETIME(3), payload BLOB,
               note VARCHAR(20) NULL) ENGINE=InnoDB""")
        name = "O'Brien \\ \"Räikkönen\" 🏎"
        r = run("INSERT INTO $(_MY_T) (name, big, ratio, pts, day, at, payload, note) VALUES (?, ?, ?, ?, ?, ?, ?, ?)";
                params = Any[name, typemax(Int64), 312.75, Decimal(0, 1234567125, -3), Date(1991, 3, 10),
                             DateTime(1991, 3, 10, 14, 30, 15, 123), UInt8[0x00, 0xff, 0x10], missing])
        @test PormG.backend_num_affected_rows(pool, r) == 1
        got = rows("SELECT * FROM $(_MY_T) WHERE name = ?"; params = Any[name])
        @test size(got, 1) == 1
        @test got.name[1] == name && got.name[1] isa String
        @test got.big[1] === typemax(Int64)
        @test got.ratio[1] === 312.75
        @test got.pts[1] isa Decimals.Decimal && got.pts[1] == Decimal(0, 1234567125, -3)
        @test got.day[1] == Date(1991, 3, 10)
        @test got.at[1] === DateTime(1991, 3, 10, 14, 30, 15, 123)
        @test got.payload[1] == UInt8[0x00, 0xff, 0x10] && got.payload[1] isa Vector{UInt8}
        @test ismissing(got.note[1])
        # A quote-injection string is a value: one row matches it exactly, and the table is intact.
        @test isempty(rows("SELECT id FROM $(_MY_T) WHERE name = ?"; params = Any["x' OR '1'='1"]))
        @test rows("SELECT COUNT(*) AS n FROM $(_MY_T)").n[1] == 1
    end

    # What: text reads as a `String` and binary data as a `Vector{UInt8}`, decided by the column's
    #       character set, whether the statement has parameters or not.
    # SQL: `SELECT t, v, s, b, bl FROM pormg_my_phase1_text …`, with and without a `WHERE id = ?`, and
    #      `LPAD(s, ?, '*')`, `CONCAT_WS('', s, ?)`, `REPLACE(s, ?, ?)` over a `utf8mb4_0900_bin` column.
    # Why: MySQL sets the BINARY flag on every column of a binary collation, which PormG's text columns
    #      are (#1265), and MySQL.jl 2.0 decides by that flag: a TEXT column and any text expression
    #      whose length a parameter sets came back as bytes, and a VARBINARY column as text
    #      (#1130 phase 2c-3b). The character set (63 = binary) is what says which.
    @testset "text reads as a String and bytes as bytes, by the column's character set" begin
        t = "pormg_my_phase1_text"
        run("DROP TABLE IF EXISTS $(t)")
        try
            run("""CREATE TABLE $(t) (id BIGINT PRIMARY KEY, t TEXT COLLATE utf8mb4_0900_bin,
                   v VARCHAR(50) COLLATE utf8mb4_0900_bin, s VARCHAR(50) COLLATE utf8mb4_0900_bin,
                   b VARBINARY(8), bl BLOB) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_bin""")
            run("INSERT INTO $(t) VALUES (?, ?, ?, ?, ?, ?)";
                params = Any[1, "Räikkönen's long text", "Senna", "Prost", UInt8[0x00, 0xc3, 0x28], UInt8[0xff, 0x01]])
            for (label, got) in ("no parameters" => rows("SELECT t, v, s, b, bl FROM $(t)"),
                                 "a parameter" => rows("SELECT t, v, s, b, bl FROM $(t) WHERE id = ?"; params = Any[1]))
                @test (label, got.t[1]) == (label, "Räikkönen's long text") && got.t[1] isa String
                @test got.v[1] == "Senna" && got.v[1] isa String && got.s[1] isa String
                @test (label, got.b[1]) == (label, UInt8[0x00, 0xc3, 0x28]) && got.b[1] isa Vector{UInt8}
                @test got.bl[1] == UInt8[0xff, 0x01] && got.bl[1] isa Vector{UInt8}
            end
            # Text expressions whose length a parameter sets: MySQL types them a BLOB of utf8mb4.
            e = rows("SELECT LPAD(s, ?, '*') AS lp, CONCAT_WS('', s, ?) AS cw, REPLACE(s, ?, ?) AS rp FROM $(t)";
                     params = Any[8, "!", "o", "0"])
            @test (e.lp[1], e.cw[1], e.rp[1]) == ("***Prost", "Prost!", "Pr0st")
            @test all(c -> c[1] isa String, (e.lp, e.cw, e.rp))
            # A row-returning statement MySQL will not prepare (error 1295, measured) runs over the
            # text protocol instead; and SQL that opens with a comment is still decoded.
            @test rows("SHOW WARNINGS") isa DataFrame
            c = rows("/* a note */ -- and a line\nSELECT t FROM $(t)")
            @test c.t[1] == "Räikkönen's long text" && c.t[1] isa String
            # A JSON column reports the binary character set, and is text.
            run("ALTER TABLE $(t) ADD COLUMN j JSON")
            run("UPDATE $(t) SET j = ? WHERE id = ?"; params = Any["{\"a\": 1}", 1])
            js = rows("SELECT j FROM $(t) WHERE id = ?"; params = Any[1])
            @test js.j[1] isa String && occursin("\"a\"", js.j[1])
        finally
            run("DROP TABLE IF EXISTS $(t)")
        end
    end

    # What: an UPDATE reports the rows it MATCHED, not only the rows whose value changed.
    # SQL: `UPDATE pormg_my_phase1_values SET big = big WHERE name = ?` (the value does not change).
    # Why: MySQL's default reports 0 for an unchanged row, where PostgreSQL and SQLite report 1; core's
    # matched-row counts (`update()`, deletion) assume the latter. The extension connects with
    # `found_rows`.
    @testset "an UPDATE reports matched rows" begin
        id = rows("SELECT MIN(id) AS id FROM $(_MY_T)").id[1]
        r = run("UPDATE $(_MY_T) SET big = big WHERE id = ?"; params = Any[id])
        @test PormG.backend_num_affected_rows(pool, r) == 1
    end

    # What: the server's version is asked on the transaction's own connection when one is open.
    # SQL: `SELECT VERSION()` inside `run_in_transaction` on a pool of ONE slot.
    # Why: a version row read mid-transaction must not lease a second connection — on a pool of one
    # it would wait `pool_timeout` and raise `PoolTimeoutError` (found in review of #1130).
    @testset "the server version is read on a transaction's own connection" begin
        one = PormG.ConnectionPool.MySQLConnectionPool(pool.connection_string; pool_size = 1, pool_timeout = 2)
        try
            v = PormG.run_in_transaction(() -> PormG._server_version(one), one)
            @test v == PormG._server_version(pool)
        finally
            PormG.ConnectionPool.close_pool!(one)
        end
    end

    # What: a model read and a model write reach the server.
    # SQL: `SELECT … FROM \`status\` …`, `COUNT(*)` and `INSERT INTO \`status\` …`, which the server
    # refuses (this database has no `status` table).
    # Why: reads render for MySQL since phase 2a and single-row writes since phase 3a
    # (`test_mysql_reads.jl` and `test_mysql_writes.jl` run them on real tables); each one reaches the
    # server as a statement, and its refusal arrives as a PormG error naming the table.
    @testset "a model read and a model write reach the server" begin
        for q in (() -> M.Status.objects.filter("statusid" => 1).list(),
                  () -> M.Status.objects.count(),
                  () -> M.Status.objects.create("status" => "x"))
            e = try q(); nothing catch err; err end
            @test e isa PormG.PormGError && occursin("status", msg(e))
        end
    end

    # What: the pool serves concurrent tasks, each with its own parameters.
    # SQL: `SELECT SLEEP(0.05) AS s, ? AS v` from 40 spawned tasks.
    # Why: MySQL.jl's I/O yields, so a pool of connections overlaps waits; a slot handed to two tasks
    # at once would mix their results.
    @testset "the pool serves concurrent tasks with their own parameters" begin
        t0 = time()
        tasks = [Threads.@spawn rows("SELECT SLEEP(0.05) AS s, ? AS v"; params = Any[i]) for i in 1:40]
        got = [fetch(t).v[1] for t in tasks]
        @test got == collect(1:40)
        @test time() - t0 < 40 * 0.05   # overlapped, not serialized
    end

    # What: `run_in_transaction` commits its body, and rolls it back when the body throws.
    # SQL: `START TRANSACTION`, `INSERT …`, then `COMMIT` or `ROLLBACK`, on one pinned connection.
    # Why: `_begin_write_sql(::PormGMySQL)` is MySQL's engine fact; a statement escaping the pinned
    # connection would commit on its own and survive the rollback.
    @testset "run_in_transaction commits, and rolls back on a throw" begin
        before = rows("SELECT COUNT(*) AS n FROM $(_MY_T)").n[1]
        @test_throws ErrorException PormG.run_in_transaction(pool) do
            run("INSERT INTO $(_MY_T) (name) VALUES (?)"; params = Any["rolled back"])
            error("boom")
        end
        @test rows("SELECT COUNT(*) AS n FROM $(_MY_T)").n[1] == before
        PormG.run_in_transaction(pool) do
            run("INSERT INTO $(_MY_T) (name) VALUES (?)"; params = Any["committed"])
        end
        @test rows("SELECT COUNT(*) AS n FROM $(_MY_T)").n[1] == before + 1
    end

    # What: server errors arrive as PormG's taxonomy, classified by MySQL's error number, and the
    # text is kept only where MySQL's message names objects rather than values.
    # SQL: a duplicate key (1062), a child row without its parent (1452), a missing table (1146),
    # and a lock wait timeout (1205) on a row another connection holds `FOR UPDATE`.
    # Why: MySQL's SQLSTATE `HY000` covers both statement and connection failures, so the class cannot
    # classify; 1062's text quotes the duplicate value, which must not reach the error's message.
    @testset "server errors are classified by error number, without quoting values" begin
        run("CREATE TABLE $(_MY_PARENT) (driverid BIGINT PRIMARY KEY, surname VARCHAR(50) NOT NULL UNIQUE) ENGINE=InnoDB")
        run("""CREATE TABLE $(_MY_CHILD) (resultid BIGINT PRIMARY KEY AUTO_INCREMENT, driverid BIGINT NOT NULL,
               CONSTRAINT pormg_my_phase1_fk FOREIGN KEY (driverid) REFERENCES $(_MY_PARENT)(driverid)) ENGINE=InnoDB""")
        run("INSERT INTO $(_MY_PARENT) (driverid, surname) VALUES (?, ?)"; params = Any[1, "Senna"])

        e = try run("INSERT INTO $(_MY_PARENT) (driverid, surname) VALUES (?, ?)"; params = Any[2, "Senna"]); nothing catch err; err end
        @test e isa PormG.IntegrityError
        @test e.sqlstate == "23000"
        @test e.message === nothing
        @test !occursin("Senna", msg(e))

        e = try run("INSERT INTO $(_MY_CHILD) (driverid) VALUES (?)"; params = Any[99]); nothing catch err; err end
        @test e isa PormG.IntegrityError
        @test e.message !== nothing && occursin("pormg_my_phase1_fk", e.message)

        e = try run("SELECT * FROM pormg_my_phase1_no_such_table"); nothing catch err; err end
        @test e isa PormG.StatementError
        @test e.sqlstate == "42S02"

        CP = PormG.ConnectionPool
        holder = CP.acquire_connection(pool)
        waiter = CP.acquire_connection(pool)
        try
            PormG.fetch(pool, "START TRANSACTION"; conn = holder)
            PormG.fetch(pool, "SELECT * FROM $(_MY_PARENT) WHERE driverid = ? FOR UPDATE"; params = Any[1], conn = holder)
            PormG.fetch(pool, "SET SESSION innodb_lock_wait_timeout = 1"; conn = waiter)
            e = try
                PormG.fetch(pool, "UPDATE $(_MY_PARENT) SET surname = ? WHERE driverid = ?"; params = Any["Prost", 1], conn = waiter)
                nothing
            catch err
                err
            end
            @test e isa PormG.OperationalError
            @test e.message !== nothing && occursin("Lock wait timeout", e.message)
        finally
            try; PormG.fetch(pool, "ROLLBACK"; conn = holder); catch; end
            try; PormG.fetch(pool, "SET SESSION innodb_lock_wait_timeout = DEFAULT"; conn = waiter); catch; end
            CP.release_connection(pool, holder)
            CP.release_connection(pool, waiter)
        end
    end

    # What: `backend_cancel_query!` stops a statement running on a connection, and the connection is
    # clean afterwards.
    # SQL: `SELECT SLEEP(20) AS s` on one connection; `KILL QUERY <its id>` from a second one.
    # Why: closing a MySQL socket does not stop the statement (the spike watched an abandoned UPDATE
    # commit later), so cancellation must reach the server; a cancelled `SLEEP` returns 1 at once.
    @testset "KILL QUERY cancels a running statement and leaves the connection usable" begin
        CP = PormG.ConnectionPool
        conn = CP.acquire_connection(pool)
        try
            t0 = time()
            task = PormG.backend_execute_async(pool, conn, "SELECT SLEEP(20) AS s", nothing)
            sleep(1.0)
            PormG.backend_cancel_query!(pool, conn)
            r = DataFrame(fetch(task))
            @test r.s[1] == 1          # SLEEP reports it was interrupted
            @test time() - t0 < 10
            @test PormG.backend_drain_connection!(pool, conn) === true
            @test DataFrame(PormG.backend_execute(pool, conn, "SELECT 1 AS one", nothing)).one[1] == 1
        finally
            CP.release_connection(pool, conn)
        end
    end

    # What: an await cut short by a cancellation is recovered — the statement stopped on the server,
    # the slot renewed or released — rather than leaving a slot whose driver is still busy.
    # SQL: `SELECT SLEEP(20) AS abandoned_1130` through `fetch_async`, the awaiting task interrupted.
    # Why: #315 on MySQL. The interrupt lands on the awaiting task here, which is recognised over TLS
    # too. An interrupt that lands inside the driver's own read under TLS is lost by MySQL.jl 2.0
    # (JuliaDatabases/MySQL.jl#247); that shape is pinned as broken below.
    @testset "an abandoned await is recovered and its statement stopped (#315)" begin
        sql = "SELECT SLEEP(20) AS abandoned_1130"
        running() = rows("SELECT COUNT(*) AS n FROM information_schema.PROCESSLIST WHERE INFO = ?"; params = Any[sql]).n[1]
        ft = PormG.fetch_async(pool, sql)
        waiter = @async PormG.await_result(ft)
        sleep(1.0)
        @test running() == 1
        schedule(waiter, InterruptException(); error = true)
        @test_throws Exception fetch(waiter)
        @test ft.abandoned === true
        deadline = time() + 10
        while running() > 0 && time() < deadline
            sleep(0.25)
        end
        @test running() == 0
        @test rows("SELECT 1 AS one").one[1] == 1
    end

    @testset "an interrupt inside the driver's TLS read is recognised (MySQL.jl#247)" begin
        tls = rows("SHOW SESSION STATUS LIKE 'Ssl_cipher'")
        if size(tls, 1) == 1 && !isempty(something(tls[1, 2], ""))
            sql = "SELECT SLEEP(8) AS abandoned_tls_1130"
            ft = PormG.fetch_async(pool, sql)
            sleep(1.0)
            schedule(ft.async_result, InterruptException(); error = true)
            e = try PormG.await_result(ft); nothing catch err; err end
            # Flips to `@test` once MySQL.jl keeps the interrupt as the TLS failure's cause.
            @test_broken PormG.ConnectionPool._await_abandoned(e)
            deadline = time() + 15
            while rows("SELECT COUNT(*) AS n FROM information_schema.PROCESSLIST WHERE INFO = ?"; params = Any[sql]).n[1] > 0 &&
                  time() < deadline
                sleep(0.5)
            end
        end
    end

    # What: `with_advisory_lock` excludes a second pool on the same key, names the holder, honours the
    # `:block` timeout rounded up to whole seconds, and releases the lock on exit.
    # SQL: `SELECT GET_LOCK(CONCAT('pormg:', MD5(CONCAT(COALESCE(DATABASE(), ''), ':', ?))), 0)`, then
    # `RELEASE_LOCK(…)`; `IS_USED_LOCK(…)` for the holder.
    # Why: #1269 — `migrate` and the suite lock serialize on it, so a second process must fail or
    # queue, never run alongside; MySQL rounds a fractional GET_LOCK timeout to the nearest second, so
    # a 300 ms wait would not wait at all.
    @testset "with_advisory_lock excludes another session on GET_LOCK (#1269)" begin
        other = PormG.ConnectionPool.MySQLConnectionPool(pool.connection_string; pool_size = 1)
        key = "pormg-test-1130-$(time_ns())"
        try
            @test PormG.with_advisory_lock(() -> :ran, pool, key) === :ran
            holding = Channel{Bool}(1)
            done = Channel{Bool}(1)
            t = Threads.@spawn PormG.with_advisory_lock(pool, key) do
                put!(holding, true)
                take!(done)
                :held
            end
            take!(holding)
            e = try PormG.with_advisory_lock(() -> :nope, other, key); nothing catch err; err end
            @test e isa PormG.OperationalError
            @test occursin("held by connection", msg(e))
            t0 = time()
            e = try
                PormG.with_advisory_lock(() -> :nope, other, key; wait = true, strategy = :block, timeout_ms = 300)
                nothing
            catch err
                err
            end
            @test e isa PormG.OperationalError
            @test 0.9 <= time() - t0 < 5     # 300 ms, rounded UP to one second
            put!(done, true)
            @test fetch(t) === :held
            @test PormG.with_advisory_lock(() -> :after, other, key; wait = true, strategy = :block, timeout_ms = 1000) === :after
        finally
            PormG.ConnectionPool.close_pool!(other)
        end
    end

    # What: this run holds the MySQL suite lock on its own connection.
    # SQL: `SELECT IS_USED_LOCK(<the suite lock's name>)`.
    # Why: the suite is destructive; a second run on `db_my` must queue behind this one (#1269).
    @testset "this run holds the MySQL integration-suite lock" begin
        if get(ENV, "PORMG_TEST_LOCK", "1") ∉ ("0", "false", "off")
            id = rows("SELECT IS_USED_LOCK($(PormG.AdvisoryLock.MYSQL_LOCK_NAME_EXPR)) AS id";
                      params = Any[_SUITE_LOCK_KEY]).id[1]
            @test id !== missing
            mine = DataFrame(PormG.fetch(_SUITE_LOCK_POOL[], "SELECT CONNECTION_ID() AS id")).id[1]
            @test id == mine
        end
    end

    for t in (_MY_CHILD, _MY_PARENT, _MY_T)
        run("DROP TABLE IF EXISTS $(t)")
    end
end
end
