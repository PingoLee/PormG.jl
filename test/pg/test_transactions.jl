using Pkg
Pkg.activate(".")
ENV["PORMG_ENV"] = "dev"
using Revise
using PormG
using DataFrames
using Test
using Dates
using Base.Threads: Atomic, atomic_add!

cd("test")
cd("pg")

# Ensure configuration is loaded
PormG.Configuration.load("db_2")

import PormG: with_transaction
import PormG.Configuration: with_tx_context, get_tx_connection, fetch_async, await_result

# load models
Base.include(PormG, "db_2/models.jl")
import PormG.models as M

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

end
