# Se for rodar este arquivo isoladamente durante o dev, 
# você pode colocar um check no topo:
if !isdefined(Main, :PormG)
    include("common_setup.jl")
end

settings = PormG.config[PORMG_DB_FOLDER]

@info "Starting Transactions testset"
@testset "Transactions and Context Propagation" begin
  # cleanup
  @info "Running initial cleanup"
  M.Just_a_test_deletion.objects.delete(allow_delete_all = true, show_query = :execute)
  @info "Cleanup finished"

  @testset "with_transaction block" begin
    @info "Starting with_transaction block test"
    PormG.run_in_transaction(PORMG_DB_FOLDER) do
      @info "Inside run_in_transaction"
      q = M.Just_a_test_deletion.objects
      q.create("name" => "test1", "test_result" => 10)
      q.create("name" => "test2", "test_result" => 20)
      @info "Created records"
    end
    @info "Exited run_in_transaction"

    q = M.Just_a_test_deletion.objects
    @test q.count() == 2
    df = q |> DataFrame
    @test sort(df.name) == ["test1", "test2"]

    # cleanup for next test
    M.Just_a_test_deletion.objects.delete(allow_delete_all = true)
  end

  @testset "Nested with_tx_context shares connection" begin
    # Start a manual transaction and get connection
    begin_sql = adapter_name == "PostgreSQL" ? "BEGIN;" : "BEGIN IMMEDIATE TRANSACTION;"
    result, conn = with_transaction(settings, begin_sql)
    try
      with_tx_context(settings.connections, conn) do
        q = M.Just_a_test_deletion.objects
        q.create("name" => "n1", "test_result" => 1)
        # nested context should increase depth but reuse same conn
        with_tx_context(settings.connections, conn) do
          q.create("name" => "n2", "test_result" => 2)
        end
      end
      # commit
      with_transaction(settings, "COMMIT;", conn=conn, release_conn=true)
    catch e
      with_transaction(settings, "ROLLBACK;", conn=conn, release_conn=true)
      rethrow(e)
    end

    q = M.Just_a_test_deletion.objects
    @test q.count() == 2
    df = q |> DataFrame
    @test sort(df.name) == ["n1", "n2"]

    # cleanup for next test
    M.Just_a_test_deletion.objects.delete(allow_delete_all = true)
  end

  @testset "Transactions and Context rollback" begin
    got_error = false
    try
      PormG.run_in_transaction(settings) do
        q = M.Just_a_test_deletion.objects
        q.create("name" => "tx_test_1", "test_result" => 100)
        q.create("name" => "tx_test_2", "test_result" => 200)

        throw(ErrorException("force rollback"))
      end
    catch e
      got_error = true
    end
    @test got_error

    q = M.Just_a_test_deletion.objects
    @test q.count() == 0
    df = q |> DataFrame
    @test nrow(df) == 0
  end

  @testset "@async task inherits transaction context" begin
    child_sees_tx = Atomic{Bool}(false)
    got_error = false
    try
      PormG.run_in_transaction(settings) do
        q = M.Just_a_test_deletion.objects
        q.create("name" => "parent", "test_result" => 10)

        t = @async begin
          child_sees_tx[] = get_tx_connection() !== nothing
          sleep(0.05)
          (M.Just_a_test_deletion.objects).create("name" => "child", "test_result" => 999)
        end

        wait(t)

        throw(ErrorException("force rollback"))
      end
    catch e
      got_error = true
    end
    @test got_error
    @test child_sees_tx[]

    q = M.Just_a_test_deletion.objects
    @test q.count() == 0
    df = q |> DataFrame
    @test nrow(df) == 0

    M.Just_a_test_deletion.objects.delete(allow_delete_all = true)
  end

  @testset "Scheduling a pre-created Task inside a transaction does NOT inherit context" begin
    # Create a Task *outside* any transaction (captures no tx context)
    M.Just_a_test_deletion.objects.delete(allow_delete_all = true)

    child_saw_tx = Atomic{Bool}(false)
    task_ran = Atomic{Bool}(false)

    # Task created outside a transaction - it captures the current (empty) ScopedValue
    t = Task(() -> begin
      # When this task runs it will see whatever ScopedValue was active at creation time
      child_saw_tx[] = get_tx_connection() !== nothing
      if adapter_name == "SQLite"
        # SQLite transactions use BEGIN IMMEDIATE in run_in_transaction, which acquires
        # the writer lock. A write from another connection can block/fail due to lock,
        # so use a read-only operation here to validate context propagation semantics.
        _ = M.Just_a_test_deletion.objects.count()
      else
        # On PostgreSQL, write to prove this task executes outside the parent transaction.
        M.Just_a_test_deletion.objects.create("name" => "pre-created", "test_result" => 1)
      end
      task_ran[] = true
    end)

    # Schedule/execute the task *inside* a transaction
    try
      PormG.run_in_transaction(PORMG_DB_FOLDER) do
        schedule(t)
        wait(t)
        throw(ErrorException("force rollback"))
      end
    catch e
      # ignore
    end

    # The task should NOT have inherited the transaction context because it was created outside
    @test child_saw_tx[] == false
    @test task_ran[] == true

    # For PostgreSQL, the write is outside tx and remains visible after rollback.
    # For SQLite, this test uses a read-only task to avoid lock contention by design.
    q = M.Just_a_test_deletion.objects
    @test q.count() == (adapter_name == "SQLite" ? 0 : 1)

    M.Just_a_test_deletion.objects.delete(allow_delete_all = true)
  end

  @testset "Multithreaded inserts" begin
    M.Just_a_test_deletion.objects.delete(allow_delete_all = true)
    thread_count = 5
    @sync for i in 1:thread_count
      @async begin
        M.Just_a_test_deletion.objects.create("name" => "mt-$(i)", "test_result" => 100 + i)
      end
    end

    q = M.Just_a_test_deletion.objects
    @test q.count() == thread_count
    names = sort(q.list() .|> x -> x[:name])
    @test names == sort(["mt-$(i)" for i in 1:thread_count])

    M.Just_a_test_deletion.objects.delete(allow_delete_all = true)
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # Transactions: concurrent writers exceeding the pool size must not deadlock
  # Each create()/delete() outside an explicit transaction opens its own write
  # transaction (SQLite: BEGIN IMMEDIATE). Before the writer-serialization fix,
  # spawning more concurrent writers than pool_size let the losing BEGIN IMMEDIATEs
  # block the single SQLite async worker on busy_timeout, starving the winner's
  # COMMIT — a deadlock that surfaced as "Timeout after 30s waiting for available
  # SQLite connection". ConnectionPool.with_sqlite_write_lock now serializes SQLite
  # writers so exactly one BEGIN is ever outstanding; PostgreSQL relies on its own
  # MVCC and treats the lock as a no-op. This regression deliberately uses far more
  # writers than the default pool (3) and mixes inserts with a concurrent delete.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "Concurrent writers exceed pool size without deadlock" begin
    M.Just_a_test_deletion.objects.delete(allow_delete_all = true)

    # Seed one row so a concurrent delete has something to remove while inserts run.
    # test_result is a nullable FK to result(resultid); the seed's FK value is irrelevant to this
    # test (the row is deleted by name), so leave it NULL. A literal 0 violates the FK on PostgreSQL
    # (which enforces it) while passing on SQLite (FK enforcement off) — see the create() below.
    M.Just_a_test_deletion.objects.create("name" => "seed-to-delete", "test_result" => nothing)

    # Deliberately exceed the default SQLite pool_size (3) to force write contention.
    writer_count = 8
    @sync begin
      for i in 1:writer_count
        @async M.Just_a_test_deletion.objects.create("name" => "cw-$(i)", "test_result" => 500 + i)
      end
      # A delete racing the inserts exercises the delete() write-transaction path,
      # which is serialized by the same write lock as create()/run_in_transaction.
      @async M.Just_a_test_deletion.objects.filter("name" => "seed-to-delete").delete()
    end

    # All inserts landed and the seed row was deleted — no lost writers, no deadlock.
    q = M.Just_a_test_deletion.objects
    @test q.count() == writer_count
    names = sort(q.list() .|> x -> x[:name])
    @test names == sort(["cw-$(i)" for i in 1:writer_count])

    M.Just_a_test_deletion.objects.delete(allow_delete_all = true)
  end

  @testset "Multithreaded inserts with transactions" begin
    M.Just_a_test_deletion.objects.delete(allow_delete_all = true)
    thread_count = 5
    PormG.run_in_transaction(settings) do
      @sync for i in 1:thread_count
        @async begin
          M.Just_a_test_deletion.objects.create("name" => "mt-tx-$(i)", "test_result" => 200 + i)
        end
      end
    end
    q = M.Just_a_test_deletion.objects
    @test q.count() == thread_count
    names = sort(q.list() .|> x -> x[:name])
    @test names == sort(["mt-tx-$(i)" for i in 1:thread_count])
    M.Just_a_test_deletion.objects.delete(allow_delete_all = true)
  end

  @testset "Rollback in multithreaded inserts with transactions" begin
    M.Just_a_test_deletion.objects.delete(allow_delete_all = true)
    thread_count = 5
    got_error = false
    try
      PormG.run_in_transaction(settings) do
        @sync for i in 1:thread_count
          @async begin
            M.Just_a_test_deletion.objects.create("name" => "mt-tx-rb-$(i)", "test_result" => 300 + i)
          end
        end
        q = M.Just_a_test_deletion.objects
        @test q.count() == thread_count
        throw(ErrorException("force rollback"))
      end
    catch e
      got_error = true
    end
    @test got_error

    q = M.Just_a_test_deletion.objects
    @test q.count() == 0

    M.Just_a_test_deletion.objects.delete(allow_delete_all = true)
  end

  @testset "Multithreaded stress insert" begin
    M.Just_a_test_deletion.objects.delete(allow_delete_all = true)
    
    # Reduce worker count for SQLite to avoid excessive "database is locked" errors 
    # under heavy concurrent writes which SQLite serializes.
    worker_count = min(Base.Threads.nthreads() > 0 ? Base.Threads.nthreads() : 4, adapter_name == "SQLite" ? 4 : 16)
    
    iterations_per_worker = 100
    inserted = Atomic{Int}(0)
    deleted = Atomic{Int}(0)

    @sync for worker in 1:worker_count
      @async begin
        last_name = ""
        for iteration in 1:iterations_per_worker
          query = M.Just_a_test_deletion.objects
          name = "stress-mix-$(worker)-$(iteration)"
          if iteration % 3 == 1
            query.create("name" => name, "test_result" => 400 + worker)
            atomic_add!(inserted, 1)
            last_name = name
          elseif iteration % 3 == 2 && last_name != ""
            query.filter("name" => last_name)
            query.update("test_result2" => iteration)
          else
            if last_name != ""
              query.filter("name" => last_name)
              query.delete()
              atomic_add!(deleted, 1)
              last_name = ""
            end
          end
        end
      end
    end

    

    expected = inserted[] - deleted[]
    q = M.Just_a_test_deletion.objects
    # df = q |> DataFrame
    @test q.count() == expected
    M.Just_a_test_deletion.objects.delete(allow_delete_all = true)
  end

  @testset "Transaction isolation under pressure" begin
    M.Just_a_test_deletion.objects.delete(allow_delete_all = true)
    worker_count = min(Base.Threads.nthreads() > 0 ? Base.Threads.nthreads() : 4, 12)
    committed = Atomic{Int}(0)
    rolled_back = Atomic{Int}(0)
    context_seen = Atomic{Int}(0)

    @sync for worker in 1:worker_count
      @async begin
        try
          PormG.run_in_transaction(settings) do
            q = M.Just_a_test_deletion.objects
            q.create("name" => "iso-$(worker)", "test_result" => 600 + worker)
            if get_tx_connection() !== nothing
              atomic_add!(context_seen, 1)
            end
            if iseven(worker)
              throw(ErrorException("force rollback"))
            else
              atomic_add!(committed, 1)
            end
          end
        catch _
          atomic_add!(rolled_back, 1)
        end
      end
    end

    q = M.Just_a_test_deletion.objects
    @test q.count() == committed[]
    @test context_seen[] == worker_count
    @test committed[] + rolled_back[] == worker_count
    M.Just_a_test_deletion.objects.delete(allow_delete_all = true)
  end

  @testset "Async fetch inside transaction" begin
    M.Just_a_test_deletion.objects.delete(allow_delete_all = true)
    worker_count = min(Base.Threads.nthreads() > 0 ? Base.Threads.nthreads() : 4, 6)
    fetch_success = Atomic{Int}(0)

    @sync for worker in 1:worker_count
      @async begin
        PormG.run_in_transaction(settings) do
          q = M.Just_a_test_deletion.objects
          name = "async-$(worker)"
          q.create("name" => name, "test_result" => 700 + worker)
          task = fetch_async(settings, "SELECT COUNT(*) FROM just_a_test_deletion WHERE name LIKE 'async-$(worker)%'")
          result = await_result(task)
          df = DataFrame(result)
          if df[1, 1] >= 1
            atomic_add!(fetch_success, 1)
          end
        end
      end
    end

    q = M.Just_a_test_deletion.objects
    @test q.count() == worker_count
    @test fetch_success[] == worker_count
    M.Just_a_test_deletion.objects.delete(allow_delete_all = true)
  end

  @testset "Transaction with delection and bulk operations" begin
    M.Just_a_test_deletion.objects.delete(allow_delete_all = true)

    # Pre-insert some records
    q = M.Just_a_test_deletion.objects
    for i in 1:10
      q.create("name" => "to-be-deleted-$(i)", "test_result" => 800 + i)
    end

    (M.Just_a_test_deletion.objects).create("name" => "test_update", "test_result" => 456)

    q = M.Just_a_test_deletion.objects
    q.filter("name" => "test_update")
    df_u = q |> DataFrame
    # Ensure column is typed to allow Integer (for SQLite parity)
    # Using a more robust way to ensure the column accepts Int64 and Missing
    df_u[!, :test_result2] = Vector{Union{Int64, Missing}}(df_u[:, :test_result2])
    df_u[1, :test_result2] = 457


    PormG.run_in_transaction(settings) do
      q = M.Just_a_test_deletion.objects;
      q.filter("name__@icontains" => "to-be-deleted");
      # instruc = PormG.QueryBuilder.build(q.object);
      # instruc.parameters.parameters[1]  

      df = q |> DataFrame
      q.delete()

      # Bulk insert
      bulk_data = [Dict("name" => "bulk-$(i)", "test_result" => 900 + i) for i in 1:5]
      df = DataFrame(bulk_data)
      q = M.Just_a_test_deletion.objects
      PormG.bulk_insert(q, df)

      # Bulk update
      PormG.bulk_update(q, df_u)
    end

    q = M.Just_a_test_deletion.objects
    @test q.count() == 6
    names = sort(q.list() .|> x -> x[:name])
    @test names == vcat(sort(["bulk-$(i)" for i in 1:5]), ["test_update"])
    q = M.Just_a_test_deletion.objects
    q.filter("name" => "test_update")
    df = q |> DataFrame
    @test nrow(df) == 1
    @test df[1, :test_result2] === 457
    M.Just_a_test_deletion.objects.delete(allow_delete_all = true)
  end

  @testset "Transaction error cleanup" begin
    M.Just_a_test_deletion.objects.delete(allow_delete_all = true)
    
    (M.Just_a_test_deletion.objects).create("name" => "child-in-tx", "test_result" => 456)

    q = M.Just_a_test_deletion.objects
    df = q |> DataFrame

    # Ensure column is typed to allow Integer (for SQLite parity)
    df[!, :test_result2] = Vector{Union{Int64, Missing}}(df[:, :test_result2])
    df[1, :test_result2] = 999

    got_error = false
    try
      PormG.run_in_transaction(settings) do
        bulk_data = [Dict("name" => "bulk-$(i)", "test_result" => 900 + i) for i in 1:5]
        df = DataFrame(bulk_data)
        q = M.Just_a_test_deletion.objects
        PormG.bulk_insert(q, df)

        M.Just_a_test_deletion.objects.delete(allow_delete_all = true)

        PormG.bulk_update(q, df) 

        throw(ErrorException("force rollback"))
      end
    catch e
      got_error = true
    end

    @test got_error
    q = M.Just_a_test_deletion.objects
    @test q.count() == 1         # no rows persisted
    @test get_tx_connection() === nothing  # tx context cleared
    q = M.Just_a_test_deletion.objects
    df = q |> DataFrame
    @test df[1, :test_result2] === missing  # no update applied
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # Transactions (#71): failed-ROLLBACK renewal, end-to-end smoke against a real server
  # Kill our own PostgreSQL backend mid-transaction (pg_terminate_backend on our own
  # pid) so the transaction body error AND the subsequent ROLLBACK genuinely fail,
  # driving the renewal path (LibPQ.reset!) against a live server: no crash, no hang,
  # pool stays consistent, nothing commits. NOTE this is a smoke test, not the
  # regression gate: a terminated backend leaves a DEAD socket, which the acquire-time
  # liveness probe already replaced before the #71 fix — the true #71 hazard (an ALIVE
  # connection stuck in aborted-transaction state) can't be forced on a healthy server
  # and is gated by the unit mocks in test/unit/test_transaction_rollback_renewal.jl.
  # The @test_logs gate below asserts the renewal branch actually ran: its message
  # exists only in the #71 code path, so reverting the fix fails this testset.
  # The terminate statement is issued DIRECTLY via backend_execute_async on the tx
  # connection — this test is explicitly about pool internals and needs both the body
  # statement and the ROLLBACK to fail deterministically. (fetch()'s lost-connection
  # retry no longer fires inside transactions — #138 — so routing through fetch() would
  # merely propagate; the direct calls stay for determinism, not to dodge the retry.)
  # PG-only: SQLite has no server-side session to terminate.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "Failed rollback renews the pooled connection (#71)" begin
    if adapter_name == "PostgreSQL"
      M.Just_a_test_deletion.objects.delete(allow_delete_all = true)
      pool = settings.connections

      got_error = false
      # Log-gate: this @error is emitted only by the #71 renewal branch (the pre-fix
      # code logged a different message), so the fix being active is what makes this
      # assertion pass. match_mode=:any tolerates the driver's own error logs.
      @test_logs (:error, r"connection will be renewed") match_mode=:any begin
        try
          PormG.run_in_transaction(settings) do
            # A write inside the doomed transaction — it must NOT survive.
            # test_result is a nullable FK to result(resultid); keep it NULL (see the
            # concurrent-writers testset above).
            M.Just_a_test_deletion.objects.create("name" => "dirty-tx", "test_result" => nothing)

            conn = get_tx_connection()
            # Our own backend dies mid-statement: the fetch below throws, and the
            # ROLLBACK the transaction wrapper then attempts fails on the dead socket.
            t = PormG.backend_execute_async(pool, conn, "SELECT pg_terminate_backend(pg_backend_pid());", nothing)
            Base.fetch(t)
            # Belt-and-braces: if the terminate somehow returned, the dead connection
            # must throw on the next statement.
            t2 = PormG.backend_execute_async(pool, conn, "SELECT 1;", nothing)
            Base.fetch(t2)
            error("unreachable: connection survived pg_terminate_backend")
          end
        catch
          got_error = true
        end
      end
      @test got_error

      # The next borrowers must get a CLEAN connection: a read and a write both work
      # (no leftover aborted-transaction state), and the doomed write never committed.
      q = M.Just_a_test_deletion.objects
      @test q.count() == 0
      M.Just_a_test_deletion.objects.create("name" => "post-heal", "test_result" => nothing)
      @test q.count() == 1

      M.Just_a_test_deletion.objects.delete(allow_delete_all = true)
    else
      @test_skip "PG-only: pg_terminate_backend has no SQLite equivalent"
    end
  end

end
