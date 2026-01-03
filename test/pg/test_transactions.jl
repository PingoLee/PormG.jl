# Se for rodar este arquivo isoladamente durante o dev, 
# você pode colocar um check no topo:
if !isdefined(Main, :PormG)
    include("common_setup.jl")
end

settings = PormG.config["db_2"]

@testset "Transactions and Context Propagation" begin
  # cleanup
  delete(M.Just_a_test_deletion |> object, allow_delete_all = true, show_query = false)

  @testset "with_transaction block" begin
    PormG.run_in_transaction("db_2") do
      q = M.Just_a_test_deletion |> object
      q.create("name" => "test1", "test_result" => 10)
      q.create("name" => "test2", "test_result" => 20)
    end

    q = M.Just_a_test_deletion |> object
    @test q |> do_count == 2
    df = q |> DataFrame
    @test sort(df.name) == ["test1", "test2"]

    # cleanup for next test
    delete(M.Just_a_test_deletion |> object, allow_delete_all = true)
  end

  @testset "Nested with_tx_context shares connection" begin
    # Start a manual transaction and get connection
    result, conn = with_transaction(settings, "BEGIN;")
    try
      with_tx_context(settings.connections, conn) do
        q = M.Just_a_test_deletion |> object
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

    q = M.Just_a_test_deletion |> object
    @test q |> do_count == 2
    df = q |> DataFrame
    @test sort(df.name) == ["n1", "n2"]

    # cleanup for next test
    delete(M.Just_a_test_deletion |> object, allow_delete_all = true)
  end

  @testset "Transactions and Context rollback" begin
    got_error = false
    try
      PormG.run_in_transaction(settings) do
        q = M.Just_a_test_deletion |> object
        q.create("name" => "tx_test_1", "test_result" => 100)
        q.create("name" => "tx_test_2", "test_result" => 200)

        throw(ErrorException("force rollback"))
      end
    catch e
      got_error = true
    end
    @test got_error

    q = M.Just_a_test_deletion |> object
    @test q |> do_count == 0
    df = q |> DataFrame
    @test nrow(df) == 0
  end

  @testset "@async task inherits transaction context" begin
    child_sees_tx = Atomic{Bool}(false)
    got_error = false
    try
      PormG.run_in_transaction(settings) do
        q = M.Just_a_test_deletion |> object
        q.create("name" => "parent", "test_result" => 10)

        t = @async begin
          child_sees_tx[] = get_tx_connection() !== nothing
          sleep(0.05)
          (M.Just_a_test_deletion |> object).create("name" => "child", "test_result" => 999)
        end

        wait(t)

        throw(ErrorException("force rollback"))
      end
    catch e
      got_error = true
    end
    @test got_error
    @test child_sees_tx[]

    q = M.Just_a_test_deletion |> object
    @test q |> do_count == 0
    df = q |> DataFrame
    @test nrow(df) == 0

    delete(M.Just_a_test_deletion |> object, allow_delete_all = true)
  end

  @testset "Scheduling a pre-created Task inside a transaction does NOT inherit context" begin
    # Create a Task *outside* any transaction (captures no tx context)
    delete(M.Just_a_test_deletion |> object, allow_delete_all = true)

    child_saw_tx = Atomic{Bool}(false)

    # Task created outside a transaction - it captures the current (empty) ScopedValue
    t = Task(() -> begin
      # When this task runs it will see whatever ScopedValue was active at creation time
      child_saw_tx[] = get_tx_connection() !== nothing
      # perform a small write to prove it runs
      (M.Just_a_test_deletion |> object).create("name" => "pre-created", "test_result" => 1)
    end)

    # Schedule/execute the task *inside* a transaction
    try
      PormG.run_in_transaction("db_2") do
        schedule(t)
        wait(t)
        throw(ErrorException("force rollback"))
      end
    catch e
      # ignore
    end

    # The task should NOT have inherited the transaction context because it was created outside
    @test child_saw_tx[] == false

    # The write performed by the task was executed outside the transaction, so it should be visible
    q = M.Just_a_test_deletion |> object
    @test q |> do_count == 1

    delete(M.Just_a_test_deletion |> object, allow_delete_all = true)
  end

  @testset "Multithreaded inserts" begin
    delete(M.Just_a_test_deletion |> object, allow_delete_all = true)
    thread_count = 5
    @sync for i in 1:thread_count
      @async begin
        (M.Just_a_test_deletion |> object).create("name" => "mt-$(i)", "test_result" => 100 + i)
      end
    end

    q = M.Just_a_test_deletion |> object
    @test q |> do_count == thread_count
    names = sort((q |> list) .|> x -> x[:name])
    @test names == sort(["mt-$(i)" for i in 1:thread_count])

    delete(M.Just_a_test_deletion |> object, allow_delete_all = true)
  end

  @testset "Multithreaded inserts with transactions" begin
    delete(M.Just_a_test_deletion |> object, allow_delete_all = true)
    thread_count = 5
    PormG.run_in_transaction(settings) do
      @sync for i in 1:thread_count
        @async begin
          (M.Just_a_test_deletion |> object).create("name" => "mt-tx-$(i)", "test_result" => 200 + i)
        end
      end
    end
    q = M.Just_a_test_deletion |> object
    @test q |> do_count == thread_count
    names = sort((q |> list) .|> x -> x[:name])
    @test names == sort(["mt-tx-$(i)" for i in 1:thread_count])
    delete(M.Just_a_test_deletion |> object, allow_delete_all = true)
  end

  @testset "Rollback in multithreaded inserts with transactions" begin
    delete(M.Just_a_test_deletion |> object, allow_delete_all = true)
    thread_count = 5
    got_error = false
    try
      PormG.run_in_transaction(settings) do
        @sync for i in 1:thread_count
          @async begin
            (M.Just_a_test_deletion |> object).create("name" => "mt-tx-rb-$(i)", "test_result" => 300 + i)
          end
        end
        q = M.Just_a_test_deletion |> object
        @test q |> do_count == thread_count
        throw(ErrorException("force rollback"))
      end
    catch e
      got_error = true
    end
    @test got_error

    q = M.Just_a_test_deletion |> object
    @test q |> do_count == 0

    delete(M.Just_a_test_deletion |> object, allow_delete_all = true)
  end

  @testset "Multithreaded stress insert" begin
    delete(M.Just_a_test_deletion |> object, allow_delete_all = true)
    worker_count = min(Base.Threads.nthreads() > 0 ? Base.Threads.nthreads() : 4, 16)
    iterations_per_worker = 100
    inserted = Atomic{Int}(0)
    deleted = Atomic{Int}(0)

    @sync for worker in 1:worker_count
      @async begin
        last_name = ""
        for iteration in 1:iterations_per_worker
          query = M.Just_a_test_deletion |> object
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
              delete(query)
              atomic_add!(deleted, 1)
              last_name = ""
            end
          end
        end
      end
    end

    

    expected = inserted[] - deleted[]
    q = M.Just_a_test_deletion |> object
    # df = q |> DataFrame
    @test q |> do_count == expected
    delete(M.Just_a_test_deletion |> object, allow_delete_all = true)
  end

  @testset "Transaction isolation under pressure" begin
    delete(M.Just_a_test_deletion |> object, allow_delete_all = true)
    worker_count = min(Base.Threads.nthreads() > 0 ? Base.Threads.nthreads() : 4, 12)
    committed = Atomic{Int}(0)
    rolled_back = Atomic{Int}(0)
    context_seen = Atomic{Int}(0)

    @sync for worker in 1:worker_count
      @async begin
        try
          PormG.run_in_transaction(settings) do
            q = M.Just_a_test_deletion |> object
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

    q = M.Just_a_test_deletion |> object
    @test q |> do_count == committed[]
    @test context_seen[] == worker_count
    @test committed[] + rolled_back[] == worker_count
    delete(M.Just_a_test_deletion |> object, allow_delete_all = true)
  end

  @testset "Async fetch inside transaction" begin
    delete(M.Just_a_test_deletion |> object, allow_delete_all = true)
    worker_count = min(Base.Threads.nthreads() > 0 ? Base.Threads.nthreads() : 4, 6)
    fetch_success = Atomic{Int}(0)

    @sync for worker in 1:worker_count
      @async begin
        PormG.run_in_transaction(settings) do
          q = M.Just_a_test_deletion |> object
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

    q = M.Just_a_test_deletion |> object
    @test q |> do_count == worker_count
    @test fetch_success[] == worker_count
    delete(M.Just_a_test_deletion |> object, allow_delete_all = true)
  end

  @testset "Transaction with delection and bulk operations" begin
    delete(M.Just_a_test_deletion |> object, allow_delete_all = true)

    # Pre-insert some records
    q = M.Just_a_test_deletion |> object
    for i in 1:10
      q.create("name" => "to-be-deleted-$(i)", "test_result" => 800 + i)
    end

    (M.Just_a_test_deletion |> object).create("name" => "test_update", "test_result" => 456)

    q = M.Just_a_test_deletion |> object
    q.filter("name" => "test_update")
    df_u = q |> DataFrame
    df_u[1, :test_result2] = 457


    PormG.run_in_transaction(settings) do
      q = M.Just_a_test_deletion |> object;
      q.filter("name__@icontains" => "to-be-deleted");
      # instruc = PormG.QueryBuilder.build(q.object);
      # instruc.parameters.parameters[1]  

      df = q |> DataFrame
      delete(q)

      # Bulk insert
      bulk_data = [Dict("name" => "bulk-$(i)", "test_result" => 900 + i) for i in 1:5]
      df = DataFrame(bulk_data)
      q = M.Just_a_test_deletion |> object
      PormG.bulk_insert(q, df)

      # Bulk update
      PormG.bulk_update(q, df_u)
    end

    q = M.Just_a_test_deletion |> object
    @test q |> do_count == 6
    names = sort((q |> list) .|> x -> x[:name])
    @test names == vcat(sort(["bulk-$(i)" for i in 1:5]), ["test_update"])
    q = M.Just_a_test_deletion |> object
    q.filter("name" => "test_update")
    df = q |> DataFrame
    @test nrow(df) == 1
    @test df[1, :test_result2] === 457
    delete(M.Just_a_test_deletion |> object, allow_delete_all = true)
  end

  @testset "Transaction error cleanup" begin
    delete(M.Just_a_test_deletion |> object, allow_delete_all = true)
    
    (M.Just_a_test_deletion |> object).create("name" => "child-in-tx", "test_result" => 456)

    q = M.Just_a_test_deletion |> object
    df = q |> DataFrame

    df[1, :test_result2] = 999

    got_error = false
    try
      PormG.run_in_transaction(settings) do
        bulk_data = [Dict("name" => "bulk-$(i)", "test_result" => 900 + i) for i in 1:5]
        df = DataFrame(bulk_data)
        q = M.Just_a_test_deletion |> object
        PormG.bulk_insert(q, df)

        delete(M.Just_a_test_deletion |> object, allow_delete_all = true)

        PormG.bulk_update(q, df) 

        throw(ErrorException("force rollback"))
      end
    catch e
      got_error = true
    end

    @test got_error
    q = M.Just_a_test_deletion |> object
    @test q |> do_count == 1         # no rows persisted
    @test get_tx_connection() === nothing  # tx context cleared
    q = M.Just_a_test_deletion |> object
    df = q |> DataFrame
    @test df[1, :test_result2] === missing  # no update applied
  end

end
