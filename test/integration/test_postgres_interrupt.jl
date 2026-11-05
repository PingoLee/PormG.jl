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

`delete()` drives its own BEGIN/ROLLBACK, and had the same gap (#1638). Its statements never reach a
test as a handle, so the third testset sends the real SIGINT to a child process that runs the delete,
while this process holds the row lock the cascade waits on.

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

# ── #1638: delete()'s own transaction, interrupted by a real SIGINT in a child process ──────────────
# `delete()` runs its statements through `with_transaction(…, conn = c)`, so no handle reaches a test
# to `schedule` an interrupt into, and its cascade runs no `pg_sleep`. So the statement held in flight is
# the cascade's DELETE waiting on a row lock this process holds, and the interrupt is the real signal,
# sent to a child that runs the delete on its main task (the idiom of
# `test/performance/sigint_query_probe.jl`). The child loads the same database without the suite lock,
# which this process holds.
const PI1638_STATUS = 991638   # a status of this testset's own, so the delete never reaches the fixture
const PI1638_RESULT = 991638   # its only result, a clone of result 1

pi1638_child_script(dir::String) = """
Base.exit_on_sigint(false)
ENV["PORMG_ENV"] = "dev"
using PormG
include($(repr(normpath(joinpath(@__DIR__, "..", "load_drivers.jl")))))
cd($(repr(dir)))
PormG.Configuration.load($(repr(PORMG_DB_FOLDER)))
PormG.@import_models $(repr(joinpath(dir, PORMG_DB_FOLDER, "models.jl"))) models
import .models as M
outcome = try
  M.Status.objects.filter("statusid" => $(PI1638_STATUS)).delete()
  "completed"
catch e
  PormG.ConnectionPool._await_abandoned(e) ? "abandoned" : "other " * string(nameof(typeof(e)))
end
println("OUTCOME ", outcome)
flush(stdout)
"""

# How many backends wait on a lock while running a DELETE on `result` (the child's cascade statement).
pi1638_waiting() = Int(DataFrame(PormG.ConnectionPool.fetch(PI1577_POOL,
    "SELECT count(*) AS c FROM pg_stat_activity WHERE state = 'active' AND wait_event_type = 'Lock' " *
    "AND query ILIKE 'DELETE FROM%result%' AND pid <> pg_backend_pid()"))[1, :c])

# Can another session lock this testset's status row right now? `false` while the child's backend
# still holds the `FOR UPDATE` its delete took; any error other than 55P03 is raised.
function pi1638_status_lockable()::Bool
  try
    PormG.ConnectionPool.fetch(PI1577_POOL, "SELECT statusid FROM status WHERE statusid = \$1 FOR UPDATE NOWAIT";
                               params = Any[PI1638_STATUS])
    return true
  catch e
    e isa PormG.DatabaseError && e.sqlstate == "55P03" && return false
    rethrow()
  end
end

function pi1638_cleanup!()
  q = M.Status.objects.filter("statusid" => PI1638_STATUS)
  q.exists() && q.delete()   # cascades to the result
  return nothing
end

@testset "A Ctrl+C inside delete()'s transaction on Postgres.jl (#1638) on $(PORMG_DB_FOLDER)" begin
  if only_on(:postgres, "the cancel by key is the Postgres.jl driver's (#1638)")
    # ─────────────────────────────────────────────────────────────────────────────
    # What: a child process runs `M.Status.objects.filter("statusid" => 991638).delete()`. Its key
    #   step locks the status row (`SELECT … FOR UPDATE`), and the cascade's `DELETE FROM result …`
    #   waits on a row lock this process holds on the status's one result. The child gets SIGINT while
    #   it waits. Within 10 s, with this process's lock still held, the DELETE is gone from
    #   `pg_stat_activity` and the status row is lockable again; the child's delete raised an
    #   abandoned await.
    # SQL: the probes are `SELECT count(*) AS c FROM pg_stat_activity WHERE state = 'active' AND
    #   wait_event_type = 'Lock' AND query ILIKE 'DELETE FROM%result%' AND pid <> pg_backend_pid()` and
    #   `SELECT statusid FROM status WHERE statusid = $1 FOR UPDATE NOWAIT`; the lock this process holds
    #   is `SELECT resultid FROM result WHERE resultid = $1 FOR UPDATE`.
    # Why (#1638): `delete()` drives its own BEGIN/ROLLBACK. On Postgres.jl the interrupt closes the
    #   socket, the cleanup ROLLBACK failed at once and the slot was renewed with no cancel, so the
    #   server kept the DELETE waiting, and the status row locked, for as long as this lock is held.
    #   `finalize_transaction_connection!` now sends the cancel by key first.
    # ─────────────────────────────────────────────────────────────────────────────
    @testset "the cascade's statement stops and its row lock is released ($(PI1577_DRIVER))" begin
      if PI1577_DRIVER !== :postgres
        # The child always runs Postgres.jl, so the testset runs once, in the Postgres.jl pass. Under
        # LibPQ the same delete's ROLLBACK would wait behind the lock-blocked DELETE instead.
        @test_skip "runs in the Postgres.jl pass: the child process uses Postgres.jl"
      elseif Sys.iswindows()
        @test_skip "sends SIGINT to a child process (Linux and macOS)"
      else
        pi1638_cleanup!()
        template = M.Result.objects.filter("resultid" => 1).list() |> first
        M.Status.objects.create("statusid" => PI1638_STATUS, "status" => "Interrupted delete (#1638)")
        M.Result.objects.create(
          "resultid" => PI1638_RESULT, "raceid" => template[:raceid], "driverid" => template[:driverid],
          "constructorid" => template[:constructorid], "grid" => template[:grid],
          "positiontext" => "R", "positionorder" => 99, "points" => 0.0, "laps" => 0,
          "statusid" => PI1638_STATUS)
        held, release = Channel{Nothing}(1), Channel{Nothing}(1)
        holder = Threads.@spawn PormG.ConnectionPool.run_in_transaction(PI1577_POOL) do
          PormG.ConnectionPool.fetch(PI1577_POOL, "SELECT resultid FROM result WHERE resultid = \$1 FOR UPDATE";
                                     params = Any[PI1638_RESULT])
          put!(held, nothing)
          take!(release)
        end
        # A holder that fails before taking the lock closes `held`, so `take!(held)` raises instead of
        # blocking forever with the suite lock held.
        bind(held, holder)
        dir = mktempdir()
        script = joinpath(dir, "delete_child.jl")
        write(script, pi1638_child_script(@__DIR__))
        env = copy(ENV)
        env["PORMG_POSTGRES_DRIVER"] = "Postgres"
        env["PORMG_DB"] = PORMG_DB_FOLDER
        out = Pipe()
        proc = nothing
        lines = String[]
        try
          take!(held)
          cmd = setenv(`$(Base.julia_cmd()) -t 4 --project=$(@__DIR__) $(script)`, env)
          proc = run(pipeline(cmd; stdout = out, stderr = joinpath(dir, "child.err")); wait = false)
          close(out.in)
          reader = @async for line in eachline(out)
            push!(lines, line)
          end
          # The child loads PormG and compiles the delete first; the DELETE waiting on our lock is the
          # moment the interrupt has to land in.
          deadline = time() + 300
          while pi1638_waiting() == 0 && process_running(proc) && time() < deadline
            sleep(0.2)
          end
          @test pi1638_waiting() == 1
          @test !pi1638_status_lockable()
          kill(proc, Base.SIGINT)
          deadline = time() + 10
          while (pi1638_waiting() > 0 || !pi1638_status_lockable()) && time() < deadline
            sleep(0.25)
          end
          @test pi1638_waiting() == 0          # the cancel reached the server
          @test pi1638_status_lockable()        # and the delete's transaction is gone with its lock
          t0 = time()
          while process_running(proc) && time() - t0 < 60
            sleep(0.1)
          end
          process_running(proc) && kill(proc, Base.SIGKILL)
          wait(proc); wait(reader)
          @test "OUTCOME abandoned" in lines
        finally
          proc !== nothing && process_running(proc) && kill(proc, Base.SIGKILL)
          isready(release) || put!(release, nothing)
          timedwait(() -> istaskdone(holder), 30.0)
          pi1638_cleanup!()
        end
        @test M.Status.objects.filter("statusid" => PI1638_STATUS).exists() == false
        @test DataFrame(PormG.ConnectionPool.fetch(PI1577_POOL, "SELECT 1 AS one")).one[1] == 1
      end
    end
  end
end
