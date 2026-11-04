"""
An interrupt that lands inside the Postgres.jl driver's read still stops the statement on the server
(#1577), inside a transaction too (#1588).

A statement runs in a task in its caller's threadpool (#1577), so under plain `julia`, `-t N` and
`-t auto` a statement awaited by the main task or the REPL runs on thread 1, the interactive thread,
and a Ctrl-C lands in the statement's own task, inside Postgres.jl's read loop. The driver then
closes the socket, and `Postgres.cancel_query!` refuses a closed connection, so before the fix the
cancel never left the client and the statement ran on. The extension now sends the cancel by key
(the backend's pid and secret, on a separate connection, as the protocol defines it).

Inside a `run_in_transaction` body the abandoned-await recovery does not run, so before #1588 nothing
sent that cancel: the cleanup `ROLLBACK` failed on the closed socket, the slot was renewed, and the
statement ran to its end with its locks held. The transaction's cleanup now sends the cancel by key
before it renews the slot; the second testset holds a row lock and checks that it is released.

The interrupt is thrown into the driver's task with `schedule(…; error = true)`, which is what the
signal does there, under any thread layout. `test/performance/sigint_query_probe.jl` sends the real
signal to a child process. The statements are raw SQL on purpose: the feature is a statement still in
flight and the server's own view of it (`pg_stat_activity`), which no ORM call can stage.

The testset is the Postgres.jl driver's. Run the file once per PostgreSQL driver; on LibPQ it records
a skip, since LibPQ keeps its connection open and cancels with `PQcancel`:

    julia -t auto --project=test/integration test/integration/test_postgres_interrupt.jl                                 # LibPQ
    PORMG_POSTGRES_DRIVER=Postgres julia -t auto --project=test/integration test/integration/test_postgres_interrupt.jl  # Postgres.jl
"""

if !isdefined(Main, :PormG)
    include("common_setup.jl")
end

const PI1577_POOL = PormG.config[PORMG_DB_FOLDER].connections
# The driver this run goes through; `nothing` off PostgreSQL. A row per engine (#1179).
const PI1577_DRIVER = by_engine(postgres = () -> PormG.postgres_driver(PI1577_POOL), sqlite = () -> nothing,
                                mysql = () -> nothing)()

# How many backends other than this one are running `sql`.
pi1577_running(sql::String) = Int(DataFrame(PormG.ConnectionPool.fetch(PI1577_POOL,
    "SELECT count(*) AS c FROM pg_stat_activity WHERE query = \$1 AND state = 'active' AND pid <> pg_backend_pid()";
    params = Any[sql]))[1, :c])

@testset "An interrupt inside the Postgres.jl driver's read (#1577) on $(PORMG_DB_FOLDER)" begin
  if only_on(:postgres, "the cancel by key is the Postgres.jl driver's (#1577)")
    # ─────────────────────────────────────────────────────────────────────────────
    # What: an interrupt thrown into the driver's own task while it reads `pg_sleep(20)`'s result is an
    #   abandoned await, and the statement is gone from `pg_stat_activity` within 10 s, long before
    #   `pg_sleep(20)` would end on its own, so only the cancel can empty it. A query afterwards runs.
    # SQL: `SELECT pg_sleep(20) AS abandoned_1577` through `fetch_async`; then
    #   `SELECT count(*) AS c FROM pg_stat_activity WHERE query = $1 AND state = 'active' AND pid <> pg_backend_pid()`.
    # Why (#1577): Postgres.jl closes its socket when an interrupt lands in its read loop, and
    #   `cancel_query!` refuses a closed connection. PostgreSQL does not see the closed client until it
    #   next writes, so the statement ran to its end, and an interrupted autocommit write committed.
    #   Before the cancel by key, `pg_stat_activity` still showed the statement after 10 s.
    # ─────────────────────────────────────────────────────────────────────────────
    @testset "the statement stops on the server ($(PI1577_DRIVER))" begin
      if PI1577_DRIVER !== :postgres
        @test_skip "LibPQ keeps its connection open after an interrupt and cancels with PQcancel"
      else
        sql = "SELECT pg_sleep(20) AS abandoned_1577"
        ft = PormG.fetch_async(PI1577_POOL, sql)
        sleep(1.0)
        @test pi1577_running(sql) == 1
        schedule(ft.async_result, InterruptException(); error = true)
        e = try
          PormG.await_result(ft)
          nothing
        catch err
          err
        end
        @test PormG.ConnectionPool._await_abandoned(e)
        @test ft.abandoned === true
        deadline = time() + 10
        while pi1577_running(sql) > 0 && time() < deadline
          sleep(0.25)
        end
        @test pi1577_running(sql) == 0
        @test DataFrame(PormG.ConnectionPool.fetch(PI1577_POOL, "SELECT 1 AS one")).one[1] == 1
      end
    end
  end
end

# Can another session lock `status` row 1 right now? `NOWAIT` raises 55P03 (`lock_not_available`)
# instead of waiting while a transaction holds the row, so `false` means the row lock is still held.
# Any other error is raised, so a pool or connection failure cannot read as a held lock.
function pi1588_row_lockable()::Bool
  try
    PormG.ConnectionPool.fetch(PI1577_POOL, "SELECT statusid FROM status WHERE statusid = 1 FOR UPDATE NOWAIT")
    return true
  catch e
    e isa PormG.DatabaseError && e.sqlstate == "55P03" && return false
    rethrow()
  end
end

@testset "An interrupt inside the Postgres.jl driver's read, within run_in_transaction (#1588) on $(PORMG_DB_FOLDER)" begin
  if only_on(:postgres, "the cancel by key is the Postgres.jl driver's (#1588)")
    # ─────────────────────────────────────────────────────────────────────────────
    # What: inside `run_in_transaction`, an UPDATE takes the row lock on `status` row 1, then an
    #   interrupt is thrown into the driver's task while it reads `pg_sleep(20)`'s result. The block
    #   raises an abandoned await; within 10 s the statement is gone from `pg_stat_activity` and the row
    #   lock is released, long before `pg_sleep(20)` would end on its own. A query afterwards runs.
    # SQL: `UPDATE status SET status = status WHERE statusid = 1`, then
    #   `SELECT pg_sleep(20) AS abandoned_1588` in the transaction; the probes are
    #   `SELECT count(*) AS c FROM pg_stat_activity WHERE query = $1 AND state = 'active' AND pid <> pg_backend_pid()`
    #   and `SELECT statusid FROM status WHERE statusid = 1 FOR UPDATE NOWAIT`.
    # Why (#1588): Postgres.jl closes its socket when an interrupt lands in its read loop. Inside a
    #   transaction the abandoned-await recovery does not run, so the cleanup ROLLBACK failed on the
    #   closed socket and the slot was renewed without any cancel: the statement ran its full 20 s and
    #   kept the row lock, and the server rolled back only once it found the client gone. The
    #   transaction cleanup now sends the cancel by key before it renews the slot.
    # ─────────────────────────────────────────────────────────────────────────────
    @testset "the statement stops and its row lock is released ($(PI1577_DRIVER))" begin
      if PI1577_DRIVER !== :postgres
        @test_skip "LibPQ keeps its connection open after an interrupt: the ROLLBACK waits behind the statement"
      else
        sql = "SELECT pg_sleep(20) AS abandoned_1588"
        ft_ref = Ref{Any}(nothing)
        tx = Threads.@spawn PormG.ConnectionPool.run_in_transaction(PI1577_POOL) do
          PormG.ConnectionPool.fetch(PI1577_POOL, "UPDATE status SET status = status WHERE statusid = 1")
          ft = PormG.fetch_async(PI1577_POOL, sql)
          ft_ref[] = ft
          PormG.await_result(ft)
        end
        try
          deadline = time() + 10
          while (ft_ref[] === nothing || pi1577_running(sql) == 0) && time() < deadline
            sleep(0.1)
          end
          @test pi1577_running(sql) == 1
          @test !pi1588_row_lockable()
          @test ft_ref[] !== nothing
          if ft_ref[] !== nothing
            schedule(ft_ref[].async_result, InterruptException(); error = true)
            e = try
              fetch(tx)
              nothing
            catch err
              PormG.ConnectionPool._unwrap_async_exception(err)
            end
            @test PormG.ConnectionPool._await_abandoned(e)
            @test ft_ref[].abandoned === true
            deadline = time() + 10
            while (pi1577_running(sql) > 0 || !pi1588_row_lockable()) && time() < deadline
              sleep(0.25)
            end
            @test pi1577_running(sql) == 0
            @test pi1588_row_lockable()
            @test DataFrame(PormG.ConnectionPool.fetch(PI1577_POOL, "SELECT 1 AS one")).one[1] == 1
          end
        finally
          # Never leave the transaction (its pool slot and the row-1 lock) behind for the next file:
          # wait it out, bounded by pg_sleep's own 20 s.
          timedwait(() -> istaskdone(tx), 25.0)
        end
      end
    end
  end
end
