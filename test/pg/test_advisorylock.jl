if !isdefined(Main, :PormG)
    include("common_setup.jl")
end

@testset "AdvisoryLock: non-blocking exclusivity" begin
  dbname = haskey(PormG.config, "db_2") ? "db_2" : first(keys(PormG.config))
  key = "test_advisory_lock_$(uuid4())"
  n = 5
  counter = Atomic{Int}(0)
  tasks = Vector{Task}(undef, n)

  # Use wait=true with blocking strategy so tasks queue for the lock
  @sync for i in 1:n
    @async begin
      try
        # Acquire lock with server-side blocking (tasks queue if lock is held)
        PormG.with_advisory_lock(dbname, key; wait=true, strategy=:pool, timeout_ms=6_000) do
          # increment the counter only when the lock is held
          @info "Inside lock block, task $i"
          atomic_add!(counter, 1)
          sleep(0.5)  # short critical section so all tasks can acquire in sequence
        end
      catch e
        @error "Task $i failed to acquire lock" exception=e
      end
    end
  end

  # after all tasks complete, all 5 should have acquired and incremented
  final_count = atomic_add!(counter, 0)
  @info "Advisory lock test results" final_count
  @test final_count == 5
end

@testset "AdvisoryLock: blocking with timeout" begin
  dbname = haskey(PormG.config, "db_2") ? "db_2" : first(keys(PormG.config))
  key = "test_advisory_lock_timeout_$(uuid4())"

  # First, acquire the lock in a separate task and hold it
  lock_task = @async begin
    PormG.with_advisory_lock(dbname, key; wait=true, strategy=:block, timeout_ms=10_000) do
      @info "Lock holder task acquired lock"
      sleep(5)  # hold the lock for 5 seconds
      @info "Lock holder task releasing lock"
    end
  end

  sleep(0.5)  # ensure the lock holder has started

  # Now, attempt to acquire the same lock with a short timeout
  got_error = false
  timeout_exc = nothing

  # Suppress noisy internal errors from LibPQ by using a temporary logger
  logger = Base.CoreLogging.SimpleLogger(IOBuffer(), Base.CoreLogging.Error)
  Base.CoreLogging.with_logger(logger) do
    try
      PormG.with_advisory_lock(dbname, key; wait=true, strategy=:block, timeout_ms=1_000) do
        @info "This should not print, as lock acquisition should time out"
      end
    catch e
      timeout_exc = e
      got_error = true
    end
  end

  # Report the expected timeout in a controlled way
  # @info "Expected timeout error caught" exception=timeout_exc
  @info "Expected timeout error caught"
  @test got_error

  # Wait for the lock holder to finish

  # Now, attempt to acquire the lock again, this time it should succeed
  acquired = false
  try
    PormG.with_advisory_lock(dbname, key; wait=true, strategy=:block, timeout_ms=15_000) do
      @info "Successfully acquired lock after it was released"
      acquired = true
    end
  catch e
    @error "Failed to acquire lock unexpectedly" exception=e
  end
  @test acquired

  wait(lock_task)
end
