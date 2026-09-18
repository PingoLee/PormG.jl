if !isdefined(Main, :PormG)
    include("common_setup.jl")
end

if adapter_name == "SQLite"
    @info "Skipping AdvisoryLock tests for SQLite (not supported)"
    return true
else

  @testset "AdvisoryLock: non-blocking exclusivity" begin
    # Find a Postgres DB. Advisory locks are only supported in Postgres.
    dbname = nothing
    for k in ["db_2", "db", first(keys(PormG.config))]
      if haskey(PormG.config, k) && PormG.config[k].db_config_settings["adapter"] == "PostgreSQL"
        dbname = k
        break
      end
    end
    
    if dbname === nothing
      @warn "Skipping AdvisoryLock tests: No PostgreSQL connection found."
      return
    end
    
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

  @testset "AdvisoryLock: wait=false immediate failure when held" begin
    # The production scheduler uses wait=false to skip duplicate work instead of
    # queueing. This regression proves the non-blocking path succeeds when free
    # and throws without running the protected block when another session holds it.
    dbname = haskey(PormG.config, "db_2") ? "db_2" : first(keys(PormG.config))

    free_key = "test_advisory_lock_wait_false_free_$(uuid4())"
    @test PormG.with_advisory_lock(dbname, free_key; wait=false) do
      :acquired
    end == :acquired

    held_key = "test_advisory_lock_wait_false_held_$(uuid4())"
    entered_lock = Channel{Bool}(1)
    release_lock = Channel{Bool}(1)

    holder = @async begin
      PormG.with_advisory_lock(dbname, held_key; wait=true, strategy=:block, timeout_ms=10_000) do
        put!(entered_lock, true)
        take!(release_lock)
      end
    end

    take!(entered_lock)

    executed = false
    got_error = false
    err_msg = ""

    logger = Base.CoreLogging.SimpleLogger(IOBuffer(), Base.CoreLogging.Error)
    Base.CoreLogging.with_logger(logger) do
      try
        PormG.with_advisory_lock(dbname, held_key; wait=false) do
          executed = true
        end
      catch e
        got_error = true
        err_msg = sprint(showerror, e)
      end
    end

    put!(release_lock, true)
    wait(holder)

    @test got_error
    @test !executed
    @test occursin("Failed to acquire advisory lock", err_msg)
  end

  # ───────────────────────────────────────────────────────────────────────────────────────────
  # Migration lock identity: one database, one lock, whatever the config folder is called (#90)
  #
  # `migrate()`'s lock key used to embed `settings.db_def_folder`, so two config folders resolving
  # to ONE physical database took two DIFFERENT locks and migrated it concurrently. The fix drops
  # the qualifier entirely, and that is only correct because PostgreSQL tags an advisory lock with
  # the DATABASE OID alongside the key — a property this repo has so far asserted only in a comment
  # (`common_setup.jl`: "verified on this server"). Both halves are checked here by execution:
  #
  #   1. the lock PormG takes really is tagged with THIS database in `pg_locks`;
  #   2. two independently-built pools standing in for two config folders really do exclude each
  #      other on the migration key.
  #
  # Part 2 is the end-to-end mutation gate for #90: each pool derives its key through
  # `Migrations._migration_lock_key`, so against the unpatched folder-derived key the two keys
  # differ, the second acquisition SUCCEEDS, and `@test blocked` fails.
  # ───────────────────────────────────────────────────────────────────────────────────────────
  @testset "AdvisoryLock: migration lock identity is the database, not the folder (#90)" begin
    base = PormG.config[haskey(PormG.config, "db_2") ? "db_2" : first(keys(PormG.config))]

    # Two settings differing ONLY in `db_def_folder` — the shape the issue describes: separate `db/`
    # directories whose connection.yml resolve to one server and database. Each needs its own pool,
    # because a session-level advisory lock lives on the connection that took it.
    #
    # pool_size = 2, not 1: `with_advisory_lock` holds its connection for the whole body, so the
    # `pg_locks` probe inside the body needs a second slot or it would wait on the pool for its own
    # lock to be released.
    function folder_pool(folder::String)
      cfg = copy(base.db_config_settings)
      cfg["pool_size"] = 2
      delete!(cfg, "url")   # a `url:` entry would win over the discrete params
      st = PormG.Configuration.Settings(app_env = base.app_env,
                                        db_def_folder = folder,
                                        db_config_settings = cfg)
      PormG.Configuration._build_connection_pool!(st, "pormg_test::lock_identity_$(folder)")
      return st
    end

    settings_a = folder_pool("db_prod_a")
    settings_b = folder_pool("db_prod_b")

    try
      key_a = PormG.Migrations._migration_lock_key(settings_a)
      key_b = PormG.Migrations._migration_lock_key(settings_b)

      # ── 1. PostgreSQL scopes the advisory lock to the current database ──────────────────────
      # Hold the real migration key, then look the lock up in `pg_locks` from the pool's OTHER
      # connection. Matching `l.database` against this session's own database OID is the proof that
      # the key needs no qualifier: a cluster-wide lock would carry database = 0.
      #
      # The key halves are compared in the FORWARD direction (key -> classid/objid) on purpose.
      # Reconstructing the key as `(classid << 32) | objid` overflows bigint whenever the md5-derived
      # key is negative, which is half of all keys. `(k >> 32) & 4294967295` is also agnostic to
      # whether PostgreSQL's `>>` sign-extends: the mask discards those bits either way.
      scoped = false
      PormG.with_advisory_lock(settings_a.connections, key_a; wait = true, timeout_ms = 10_000) do
        kq  = PormG.QueryBuilder.PgParameterizedQuery("", Any[], 0)
        kph = PormG.QueryBuilder.add_parameter!(kq, key_a)
        rows = DataFrame(PormG.ConnectionPool.fetch(settings_a.connections, """
          WITH k AS (SELECT (( 'x' || substr(md5($(kph)), 1, 16))::bit(64))::bigint AS key)
          SELECT count(*) AS n
          FROM pg_locks l, k
          WHERE l.locktype = 'advisory'
            AND l.granted
            AND l.database = (SELECT oid FROM pg_database WHERE datname = current_database())
            AND l.classid  = ((k.key >> 32) & 4294967295)::oid
            AND l.objid    = (k.key & 4294967295)::oid;"""; params = kq))
        scoped = rows.n[1] >= 1
      end
      @test scoped

      # ── 2. Two "config folders" on one database exclude each other ──────────────────────────
      @test key_a == key_b

      entered = Channel{Bool}(1)
      release = Channel{Bool}(1)
      holder = @async begin
        PormG.with_advisory_lock(settings_a.connections, key_a;
                                 wait = true, strategy = :block, timeout_ms = 15_000) do
          put!(entered, true)
          take!(release)
        end
      end
      take!(entered)

      blocked   = false
      b_entered = false
      # Losing the race logs at error level; keep it out of the run output.
      logger = Base.CoreLogging.SimpleLogger(IOBuffer(), Base.CoreLogging.Error)
      Base.CoreLogging.with_logger(logger) do
        try
          PormG.with_advisory_lock(settings_b.connections, key_b; wait = false) do
            b_entered = true
          end
        catch
          blocked = true
        end
      end

      put!(release, true)
      wait(holder)

      @test blocked
      @test !b_entered

      # ── 3. and the lock is genuinely released, so folder B can take it afterwards ───────────
      @test PormG.with_advisory_lock(settings_b.connections, key_b; wait = false) do
        :acquired
      end == :acquired
    finally
      for st in (settings_a, settings_b)
        try; PormG.Configuration.close_pool!(st.connections); catch; end
      end
    end
  end

end # End of if adapter_name != "SQLite"