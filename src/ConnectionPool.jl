module ConnectionPool

import Logging
# Extend Base.fetch rather than define a fresh `fetch` — a shadowing `fetch` forces every
# caller to qualify it and conflicts with Base.fetch on `using` (#35). PormG owns the
# first-argument types (PormGPostgres/PormGSQLite/SQLConn), so this is not type piracy.
import Base: fetch
import PormG: SQLConn, PormGPostgres, PormGPostgresParam, PormGSQLite, PormGSQLiteParam, AbstractPormGParam, config, PormGModel
import PormG: @pormg_debug
# Backend generics — driver bodies live in ext/PormGLibPQExt.jl / ext/PormGSQLiteExt.jl.
import PormG: backend_connect, backend_renew_connection, backend_is_alive, backend_execute,
              backend_execute_async, backend_is_connection_error, backend_copy_in!

export fetch, fetch_async, await_result, FetchTask, fetch_copy
export with_transaction, with_transaction_async, run_in_transaction, with_savepoint
export acquire_connection, release_connection
export PoolTimeoutError
# NOTE: close_pool! is intentionally NOT exported here. Configuration owns the public
# `close_pool!` (it dispatches on a pool OR a db-name String and delegates the pool case to
# this module's `close_pool!`). Exporting it from both modules made `PormG.close_pool!`
# ambiguous and therefore undefined (#35). Callers in this package use `CP.close_pool!`.

# Import transaction context helpers from Configuration
import PormG.Configuration: get_tx_connection, get_tx_pool, with_tx_context, transaction_connection_for, get_settings, ensure_before_connect!, connection_key_for_pool

const _REDACT_CONNECTION_STRING_RE = Regex("(?i)(password|user)=[^\\s]+")

# Sentinel returned by the locked acquire block when a new physical connection
# must be opened. The before_connect hook then runs OUTSIDE the lock and the
# block is re-entered. Keeps long hooks (VPN, tunnels) off the pool lock.
const _BEFORE_CONNECT_PENDING = :__pormg_before_connect_pending__

# A pool starts at `pool_size` connections and may grow lazily (on demand) up to
# `pool_size * POOL_EXPANSION_FACTOR` before acquisition fails with a PoolTimeoutError (#37).
# The base stays small (idle footprint) while the ceiling gives async fan-out real headroom.
const POOL_EXPANSION_FACTOR = 10

"""
    PoolTimeoutError <: Exception

Thrown by `acquire_connection` when no connection becomes available within the retry/timeout budget —
i.e. the pool is saturated at its ceiling (`pool_size * POOL_EXPANSION_FACTOR`). It is a catchable
`Exception` (apps can e.g. translate it to a 503 / back off and retry). Remedy: raise `pool_size` in
`connection.yml`.
"""
struct PoolTimeoutError <: Exception
  adapter::String        # "PostgreSQL" | "SQLite"
  pool_size::Int
  max_size::Int
  attempts::Int
  elapsed_seconds::Float64
end

Base.showerror(io::IO, e::PoolTimeoutError) = print(io,
  "PoolTimeoutError: no available ", e.adapter, " connection after ", e.attempts, " attempts / ",
  round(e.elapsed_seconds, digits=1), "s (pool_size=", e.pool_size, ", max=", e.max_size,
  "). Raise pool_size (connection.yml `pool_size:`) to add capacity.")

function _run_before_connect!(pool::Union{PormGPostgres, PormGSQLite})
  if !ensure_before_connect!(pool)
    key = something(connection_key_for_pool(pool), "?")
    throw(ErrorException("before_connect hook aborted the connection for '$(key)'"))
  end
  return nothing
end

"""
    redact_secret(conn_str::String)

Replace sensitive connection string fields such as `password` or `user` with masked values before logging.
"""
function redact_secret(conn_str::String)::String
  return replace(conn_str, _REDACT_CONNECTION_STRING_RE => s"\1=****")
end

function _unwrap_async_exception(exception)
  current = exception
  while true
    if current isa TaskFailedException
      nested = current.task.exception
      nested === current && return current
      current = nested
    elseif current isa CompositeException && length(current.exceptions) == 1
      nested = current.exceptions[1]
      nested === current && return current
      current = nested
    else
      return current
    end
  end
end
#
# Connection Pool Implementation
#
# Connections are stored untyped (`Vector{Any}`): core never names a concrete driver
# type (`LibPQ.Connection` / `SQLite.DB`). The slots hold `nothing` or a live driver
# handle produced by `backend_connect`; all driver work dispatches through the backend
# generics keyed on the pool marker type.

mutable struct PostgresConnectionPool <: PormGPostgres
  connections::Vector{Any}
  available::Vector{Bool}
  connection_string::String
  pool_size::Int
  lock::ReentrantLock  # For thread safety
end

mutable struct SQLiteConnectionPool <: PormGSQLite
  connections::Vector{Any}
  available::Vector{Bool}
  connection_string::String
  pool_size::Int
  split_read_write::Bool
  writer_slot::Int
  reader_cursor::Int
  lock::ReentrantLock  # For thread safety
  # Serializes write transactions. SQLite permits only one writer per file, and
  # all statements funnel through a single global async worker; two concurrent
  # `BEGIN IMMEDIATE`s would deadlock (the losing BEGIN blocks the worker on
  # busy_timeout, starving the winner's COMMIT). Held for the whole BEGIN..COMMIT
  # so only one writer is ever outstanding. Distinct from `lock`, which only
  # guards the pool slot bookkeeping. See `with_sqlite_write_lock`.
  write_lock::ReentrantLock
end

function PostgresConnectionPool(connection_string::String; pool_size::Int = 3)
  connections = Vector{Any}(nothing, pool_size)
  available = fill(true, pool_size)
  lock = ReentrantLock()
  PostgresConnectionPool(connections, available, connection_string, pool_size, lock)
end

function SQLiteConnectionPool(connection_string::String; pool_size::Int = 3, split_read_write::Bool = false)
  connections = Vector{Any}(nothing, pool_size)
  available = fill(true, pool_size)
  lock = ReentrantLock()
  effective_split = split_read_write && pool_size > 1
  if split_read_write && !effective_split
    @warn "SQLite split read/write mode requires pool_size > 1; falling back to shared pool" pool_size=pool_size
  end
  SQLiteConnectionPool(connections, available, connection_string, pool_size, effective_split, 1, 0, lock, ReentrantLock())
end

function _sqlite_is_read_query(sql::String)::Bool
  cleaned = strip(sql)
  isempty(cleaned) && return true
  token = uppercase(split(cleaned)[1])
  if token in ("SELECT", "PRAGMA", "EXPLAIN")
    return true
  end
  if token == "WITH"
    upper_sql = uppercase(cleaned)
    has_write_keyword = occursin(r"\b(INSERT|UPDATE|DELETE|REPLACE|CREATE|DROP|ALTER|VACUUM|ANALYZE|ATTACH|DETACH|REINDEX|BEGIN|COMMIT|ROLLBACK|SAVEPOINT|RELEASE)\b", upper_sql)
    return !has_write_keyword
  end
  return false
end

function _sqlite_candidate_slots!(pool::PormGSQLite, mode::Symbol)::Vector{Int}
  total = length(pool.connections)
  writer = pool.writer_slot
  if !pool.split_read_write || mode == :any
    return collect(1:total)
  end
  if mode == :write
    return [writer]
  end

  reader_slots = [i for i in 1:total if i != writer]
  isempty(reader_slots) && return [writer]

  start = mod(pool.reader_cursor, length(reader_slots)) + 1
  ordered = vcat(reader_slots[start:end], reader_slots[1:start - 1], [writer])
  pool.reader_cursor = mod(start, length(reader_slots))
  return ordered
end

function close_pool!(pool::PormGPostgres)
  Base.lock(pool.lock) do
    for i in 1:length(pool.connections)
      conn = pool.connections[i]
      if conn !== nothing
        try
          close(conn)
        catch e
          @warn "Error closing PG connection $i: $e"
        finally
          pool.connections[i] = nothing
        end
      end
      pool.available[i] = true
    end
  end
end

function close_pool!(pool::PormGSQLite)
  Base.lock(pool.lock) do
    for i in 1:length(pool.connections)
      conn = pool.connections[i]
      if conn !== nothing
        try
          close(conn)
        catch e
          @warn "Error closing SQLite connection $i: $e"
        finally
          pool.connections[i] = nothing
        end
      end
      pool.available[i] = true
    end
  end
end

function acquire_connection(pool::PormGPostgres; timeout_seconds::Int = 30, max_retries::Int = 300)
  start_time = time()
  retry_count = 0
  # Tracks whether the before_connect hook already ran for this acquire call, so
  # it runs at most once even across retries.
  before_connect_done = false

  while retry_count < max_retries && (time() - start_time) < timeout_seconds
    connection = Base.lock(pool.lock) do
      # Look for an available connection
      for i in 1:length(pool.connections)
        if pool.available[i]
          # Check if existing connection is still alive
          if pool.connections[i] !== nothing && backend_is_alive(pool, pool.connections[i])
            pool.available[i] = false
            return pool.connections[i]
          end

          # Slot is empty or dead: a new physical connection is required. Defer
          # to the outer loop so the before_connect hook runs outside the lock.
          before_connect_done || return _BEFORE_CONNECT_PENDING

          try
            new_conn = backend_connect(pool)
            pool.connections[i] = new_conn
            pool.available[i] = false
            return new_conn
          catch e
            @error "Failed to create PG connection $i: $e" connection_string=redact_secret(pool.connection_string)
            pool.available[i] = true
            continue
          end
        end
      end

      # If we reach here, no available connections found.
      # Try to expand the pool if we haven't reached the ceiling. This runs inside the pool lock
      # and `pool.connections` is append-only (dead slots are replaced in-place, never removed), so
      # the `== ceiling` check below is race-free even under `-t auto`: exactly one locked push
      # transitions length to the ceiling → the @warn fires exactly once (#37).
      if length(pool.connections) < (pool.pool_size * POOL_EXPANSION_FACTOR)
        before_connect_done || return _BEFORE_CONNECT_PENDING
        try
          new_conn = backend_connect(pool)
          push!(pool.connections, new_conn)
          push!(pool.available, false)
          new_size = length(pool.connections)
          if new_size == pool.pool_size * POOL_EXPANSION_FACTOR
            @warn "PG pool reached its maximum size; raise pool_size to add capacity" max_size=new_size pool_size=pool.pool_size connection_string=redact_secret(pool.connection_string)
          else
            @debug "PG pool expanded beyond initial size" current_size=new_size initial_size=pool.pool_size
          end
          return new_conn
        catch e
          @error "Failed to expand PG pool: $e"
        end
      end

      # Return nothing if no connection could be acquired
      return nothing
    end

    # A new connection is needed: run the before_connect hook off the lock.
    if connection === _BEFORE_CONNECT_PENDING
      _run_before_connect!(pool)
      before_connect_done = true
      continue
    end

    # If we got a connection, return it
    if connection !== nothing
      return connection
    end

    # No connection available, wait and retry. @debug (not @info): under saturation this fires every
    # 100ms across many concurrent acquires; the actionable signals are the once-at-ceiling @warn above
    # and the PoolTimeoutError below (#37).
    retry_count += 1
    @debug "No available PG connections, retrying ($retry_count/$max_retries) in 100ms..." pool_size=pool.pool_size
    sleep(0.1)  # Wait 100ms before retrying
  end

  # Exhausted the retry/timeout budget → genuine starvation. This is a recoverable, caller-handleable
  # condition (the typed error lets apps back off / return 503), so log at @warn, not @error — an app
  # that catches PoolTimeoutError shouldn't see a scary error on every gracefully-handled timeout.
  if retry_count >= max_retries
    @warn "Exceeded maximum retry attempts ($max_retries) to acquire PG connection" pool_size=pool.pool_size connection_string=redact_secret(pool.connection_string)
  else
    @warn "Timeout after $(timeout_seconds) seconds waiting for available PG connection" pool_size=pool.pool_size connection_string=redact_secret(pool.connection_string)
  end
  throw(PoolTimeoutError("PostgreSQL", pool.pool_size, pool.pool_size * POOL_EXPANSION_FACTOR, retry_count, time() - start_time))
end

function acquire_connection(pool::PormGSQLite; timeout_seconds::Int = 30, max_retries::Int = 300, mode::Symbol = :any)
  start_time = time()
  retry_count = 0
  # See PormGPostgres acquire_connection: run the before_connect hook outside the
  # lock, at most once per acquire call.
  before_connect_done = false

  mode in (:any, :read, :write) || throw(ArgumentError("Invalid SQLite acquire mode: $(mode). Expected :any, :read or :write."))

  while retry_count < max_retries && (time() - start_time) < timeout_seconds
    connection = Base.lock(pool.lock) do
      slot_order = _sqlite_candidate_slots!(pool, mode)

      # Look for an available connection
      for i in slot_order
        if pool.available[i]
          # Check if existing connection is still alive
          if pool.connections[i] !== nothing && backend_is_alive(pool, pool.connections[i])
            pool.available[i] = false
            return pool.connections[i]
          end

          # Slot is empty or dead: defer creation so the hook runs off the lock.
          before_connect_done || return _BEFORE_CONNECT_PENDING

          try
            is_reader_slot = pool.split_read_write && i != pool.writer_slot
            new_conn = backend_connect(pool; read_only = is_reader_slot)
            pool.connections[i] = new_conn
            pool.available[i] = false
            return new_conn
          catch e
            @error "Failed to create SQLite connection $i: $e" connection_string=pool.connection_string
            pool.available[i] = true
            continue
          end
        end
      end

      # Expand pool logic (append-only + under the lock → the `== ceiling` warn below is race-free; see
      # the PostgreSQL twin for the full rationale, #37).
      can_expand = !pool.split_read_write && length(pool.connections) < (pool.pool_size * POOL_EXPANSION_FACTOR)
      if can_expand
        before_connect_done || return _BEFORE_CONNECT_PENDING
        try
          new_conn = backend_connect(pool)
          push!(pool.connections, new_conn)
          push!(pool.available, false)
          new_size = length(pool.connections)
          if new_size == pool.pool_size * POOL_EXPANSION_FACTOR
            @warn "SQLite pool reached its maximum size; raise pool_size to add capacity" max_size=new_size pool_size=pool.pool_size connection_string=pool.connection_string
          else
            @debug "SQLite pool expanded beyond initial size" current_size=new_size initial_size=pool.pool_size
          end
          return new_conn
        catch e
          @error "Failed to expand SQLite pool: $e"
        end
      end

      return nothing
    end

    if connection === _BEFORE_CONNECT_PENDING
      _run_before_connect!(pool)
      before_connect_done = true
      continue
    end

    if connection !== nothing
      return connection
    end

    # @debug (not @info): see the PostgreSQL twin — avoids per-retry spam under saturation (#37).
    retry_count += 1
    @debug "No available SQLite connections, retrying ($retry_count/$max_retries) in 100ms..." pool_size=pool.pool_size
    sleep(0.1)
  end

  # Exhausted the retry/timeout budget → genuine starvation. Recoverable + caller-handleable, so
  # @warn not @error (see the PostgreSQL twin).
  @warn (retry_count >= max_retries ?
    "Exceeded maximum retry attempts ($max_retries) to acquire SQLite connection" :
    "Timeout after $(timeout_seconds) seconds waiting for available SQLite connection") pool_size=pool.pool_size connection_string=pool.connection_string
  throw(PoolTimeoutError("SQLite", pool.pool_size, pool.pool_size * POOL_EXPANSION_FACTOR, retry_count, time() - start_time))
end

function release_connection(pool::PormGPostgres, conn)
  released = Base.lock(pool.lock) do
    for i in 1:length(pool.connections)
      if pool.connections[i] === conn
        pool.available[i] = true
        return true
      end
    end
  end
  released !== nothing && return released
  @warn "PG Connection not found in the pool - connection may have been replaced due to failure"
  return false
end

function release_connection(pool::PormGSQLite, conn)
  released = Base.lock(pool.lock) do
    for i in 1:length(pool.connections)
      if pool.connections[i] === conn
        pool.available[i] = true
        return true
      end
    end
  end
  released !== nothing && return released
  @warn "SQLite Connection not found in the pool"
  return false
end

function reconnect_db(pool::PormGPostgres, conn)
  _run_before_connect!(pool)

  reconnect = Base.lock(pool.lock) do
    for i in 1:length(pool.connections)
      if pool.connections[i] === conn
        new_conn = try
          # Reset in place, or recreate if the reset fails (handled in the extension).
          backend_renew_connection(pool, conn)
        catch e
          @error "Failed to renew PG connection $i: $e"
          nothing
        end
        if new_conn !== nothing
          pool.connections[i] = new_conn
          return new_conn
        end
      end
    end
  end
  reconnect !== nothing && return reconnect
  @error "PG Connection not found in the pool for reconnection"
  return nothing
end

function reconnect_db(pool::PormGSQLite, conn)
  _run_before_connect!(pool)

  reconnect = Base.lock(pool.lock) do
    for i in 1:length(pool.connections)
      if pool.connections[i] === conn
        is_reader_slot = pool.split_read_write && i != pool.writer_slot
        new_conn = try
          # SQLite has no in-place reset; the extension opens a fresh DB handle.
          backend_renew_connection(pool, conn; read_only = is_reader_slot)
        catch e
          @error "Failed to recreate SQLite connection $i: $e"
          nothing
        end
        if new_conn !== nothing
          pool.connections[i] = new_conn
          return new_conn
        end
      end
    end
  end
  reconnect !== nothing && return reconnect
  @error "SQLite Connection not found in the pool for reconnection"
  return nothing
end

"""
    _discard_connection!(pool, conn) -> Bool

Remove `conn` from its pool slot (the slot becomes `nothing` and is marked available, so the
next `acquire_connection` opens a fresh physical connection through the empty-slot path) and
best-effort `close` it. Used when a connection is known-dirty — e.g. a failed ROLLBACK (#71)
— and renewal via `reconnect_db` also failed. Returns whether the slot was found. Never
throws (callers run it while an original error is propagating).
"""
function _discard_connection!(pool::Union{PormGPostgres, PormGSQLite}, conn)::Bool
  found = Base.lock(pool.lock) do
    for i in 1:length(pool.connections)
      if pool.connections[i] === conn
        pool.connections[i] = nothing
        pool.available[i] = true
        return true
      end
    end
    return false
  end
  # Close OUTSIDE the pool lock: a driver close can block on I/O. On SQLite this also
  # releases the database file write-lock an aborted `BEGIN IMMEDIATE` may still hold.
  try
    close(conn)
  catch close_error
    @debug "Error closing discarded connection" exception=close_error
  end
  found || @warn "Connection to discard not found in the pool - it may already have been replaced"
  return found
end

"""
    _renew_or_discard_connection!(pool, conn) -> Nothing

Post-failed-ROLLBACK cleanup (#71). Renews `conn` in its slot via `reconnect_db`
(PostgreSQL: `LibPQ.reset!`, which aborts any open transaction and may return the SAME
handle; SQLite: a fresh handle) and releases the RENEWED handle back to the pool — never
the dirty one (`reconnect_db` swaps the slot in place and `release_connection` matches by
identity, so releasing the stale handle would leak the slot as permanently busy). If
renewal fails — including a `before_connect` hook abort, which `reconnect_db` surfaces as
a throw — the slot is discarded instead so the next borrower opens a fresh connection.
Never throws: the transaction's original error must keep propagating through the caller's
`finally`.
"""
function _renew_or_discard_connection!(pool::Union{PormGPostgres, PormGSQLite}, conn)
  new_conn = try
    reconnect_db(pool, conn)  # replaces the slot in place; does NOT flip `available`
  catch renew_error
    # reconnect_db only throws via the before_connect hook; driver renewal errors are
    # caught inside it and returned as `nothing`.
    @error "Connection renewal after failed rollback threw; discarding the connection" exception=renew_error
    nothing
  end
  if new_conn === nothing
    _discard_connection!(pool, conn)
  else
    if new_conn !== conn
      # A brand-new handle replaced the dirty one (always on SQLite; on PG only when
      # reset! fell back to a fresh Connection). Close the old handle now rather than
      # waiting for GC — on SQLite it may still hold the database file write-lock.
      try
        close(conn)
      catch close_error
        @debug "Error closing replaced connection" exception=close_error
      end
    end
    release_connection(pool, new_conn)
  end
  return nothing
end

"""
    _is_benign_rollback_error(pool, e) -> Bool

Classify a failed `ROLLBACK` as benign, meaning the connection is known-clean and may be
released normally. SQLite-only divergence: SQLite auto-rolls-back some failures, after
which `ROLLBACK` reports "no transaction is active"; PostgreSQL's `ROLLBACK` outside a
transaction merely warns, it never throws. Unwraps before matching: async failures arrive
as `TaskFailedException`, whose `string()` does not include the driver message.
"""
_is_benign_rollback_error(pool::Union{PormGPostgres, PormGSQLite}, e) =
  pool isa PormGSQLite && occursin("no transaction is active", string(_unwrap_async_exception(e)))

# A statement that ends the current transaction (plain ROLLBACK) — deliberately NOT
# "ROLLBACK TO SAVEPOINT", which keeps the outer transaction alive and must never
# trigger connection renewal.
function _is_transaction_rollback(sql::AbstractString)
  s = uppercase(strip(sql))
  return startswith(s, "ROLLBACK") && !startswith(s, "ROLLBACK TO")
end

#
# Connection Execution
#
# The actual driver execute paths live in the extensions as methods of
# `backend_execute` (sync) and `backend_execute_async` (async). The SQLite async
# worker below stays in core but dispatches each statement through `backend_execute`.

mutable struct SQLiteAsyncWorkItem
  pool::PormGSQLite
  conn::Any
  sql::String
  params::Any
  response::Channel{Any}
end

struct SQLiteAsyncResponse
  success::Bool
  payload::Any
end

# A single global worker serializes all SQLite async operations across all pool instances.
# This is intentional: SQLite supports only one concurrent writer per file, and even for
# reads, WAL mode only provides limited concurrency at the file level. A shared queue
# prevents connection pool instances from racing on the same file and avoids the
# "database is locked" errors that arise from concurrent writers on different Julia tasks.
# The queue capacity (2048) is intentionally large so that producers never block.
const _sqlite_async_worker_lock = ReentrantLock()
const _sqlite_async_worker_started = Ref(false)
const _sqlite_async_work_queue = Channel{SQLiteAsyncWorkItem}(2048)

function _ensure_sqlite_async_worker!()
  _sqlite_async_worker_started[] && return

  Base.lock(_sqlite_async_worker_lock) do
    _sqlite_async_worker_started[] && return

    Threads.@spawn begin
      while true
        item = take!(_sqlite_async_work_queue)
        try
          # Dispatches into the SQLite extension's backend_execute (materialized + retry).
          # invokelatest: this task lives forever and Julia tasks run in the world age
          # they were created in, so without it the worker cannot see backend_execute
          # methods defined after it spawned (Revise hot-reloads, test mocks).
          result = Base.invokelatest(backend_execute, item.pool, item.conn, item.sql, item.params)
          put!(item.response, SQLiteAsyncResponse(true, result))
        catch e
          put!(item.response, SQLiteAsyncResponse(false, e))
        end
      end
    end

    _sqlite_async_worker_started[] = true
  end
end

"""
    sqlite_execute_async(pool::PormGSQLite, conn, sql::String, params)

Internal helper that funnels a SQLite query through the single global worker so all
statements run serialized on one thread, then returns a `Task` the caller awaits. This
keeps the main event loop responsive while waiting for the database.
"""
function sqlite_execute_async(pool::PormGSQLite, conn, sql::String, params)
  _ensure_sqlite_async_worker!()

  response = Channel{Any}(1)
  work_item = SQLiteAsyncWorkItem(pool, conn, sql, params, response)

  return @async begin
    put!(_sqlite_async_work_queue, work_item)
    result = take!(response)
    if result isa SQLiteAsyncResponse
      result.success && return result.payload
      throw(result.payload)
    end
    throw(ErrorException("SQLite async worker returned an invalid response payload"))
  end
end

"""
    FetchTask

A wrapper around an async database query result that manages connection lifecycle.
Use `await_result(task)` to get the result and properly release the connection.

# Fields
- `async_result`: The underlying async handle (a `LibPQ.AsyncResult` for PG, a `Task` for SQLite)
- `pool::Union{PormGPostgres, PormGSQLite}`: The connection pool to release the connection to
- `conn`: The driver connection being used for this query
- `completed::Bool`: Whether the async result has been awaited
- `result_cache::Union{Nothing, Any}`: Cached result for multiple `await_result` calls
- `in_transaction::Bool`: Whether this task is part of a transaction (don't release connection)
"""
mutable struct FetchTask
  async_result::Any  # LibPQ.AsyncResult (PG) or Task (SQLite)
  pool::Union{PormGPostgres, PormGSQLite}
  conn::Any
  completed::Bool
  result_cache::Union{Nothing, Any}
  in_transaction::Bool  # Whether this task is part of a transaction context

  # Constructor for transaction-aware fetch
  FetchTask(async_result, pool::Union{PormGPostgres, PormGSQLite}, conn, in_transaction::Bool) =
    new(async_result, pool, conn, false, nothing, in_transaction)

  # Legacy constructor (defaults to not in transaction)
  FetchTask(async_result, pool::Union{PormGPostgres, PormGSQLite}, conn) =
    new(async_result, pool, conn, false, nothing, false)
end

"""
    await_result(ft::FetchTask) -> result

Await the completion of an async fetch task and return the result.
Automatically releases the connection back to the pool.

This function is idempotent - calling it multiple times returns the same result
without re-releasing the connection.
"""
function await_result(ft::FetchTask)
  if ft.completed
    # Already completed, just return the cached result
    return ft.result_cache
  end

  try
    # Await the async result (works for both LibPQ.AsyncResult and Task)
    result = Base.fetch(ft.async_result)
    ft.result_cache = result
    ft.completed = true
    return result
  catch e
    ft.completed = true
    root = _unwrap_async_exception(e)
    root === e ? rethrow() : throw(root)
  finally
    # Only release connection if we're not in a transaction context
    # Transaction context manages its own connection lifecycle
    if ft.completed && !ft.in_transaction
      release_connection(ft.pool, ft.conn)
    end
  end
end

"""
    fetch_async(connection::PormGPostgres, sql::String; params=nothing) -> FetchTask

Start an async database query that yields to the Julia scheduler.
Returns a `FetchTask` that can be awaited with `await_result()`.

This is useful in Genie.jl async handlers where you want to run multiple
queries in parallel or allow other tasks to run while waiting for the database.

# Example
```julia
# Start multiple queries in parallel
task1 = fetch_async(pool, "SELECT * FROM users")
task2 = fetch_async(pool, "SELECT * FROM orders")

# Both queries run concurrently, await results
users = await_result(task1)
orders = await_result(task2)
```
"""
function fetch_async(connection::Union{PormGPostgres, PormGSQLite}, sql::String;
  conn = nothing,
  params::Union{Nothing, AbstractPormGParam} = nothing,
  ignore_tx::Bool = false)

  # Check for transaction context first
  tx_conn = ignore_tx ? nothing : get_tx_connection()
  use_tx_context = conn === nothing && tx_conn !== nothing

  if use_tx_context
    # Use transaction context connection - don't acquire a new one
    conn = tx_conn
    try
      task = if connection isa PormGPostgres
        backend_execute_async(connection, conn, sql, params)
      else
        sqlite_execute_async(connection, conn, sql, params)
      end
      # Return a special FetchTask that won't release the connection
      return FetchTask(task, connection, conn, true)  # true = in_transaction
    catch e
      # Don't release - transaction context manages the connection
      throw(e)
    end
  else
    # Normal path: acquire connection from pool
    if conn === nothing
      if connection isa PormGSQLite
        sqlite_mode = _sqlite_is_read_query(sql) ? :read : :write
        conn = acquire_connection(connection; mode=sqlite_mode)
      else
        conn = acquire_connection(connection)
      end
    end
    try
      task = if connection isa PormGPostgres
        backend_execute_async(connection, conn, sql, params)
      else
        sqlite_execute_async(connection, conn, sql, params)
      end
      return FetchTask(task, connection, conn, false)  # false = not in transaction
    catch e
      # If EXEC fails immediately, release connection
      release_connection(connection, conn)
      throw(e)
    end
  end
end
fetch_async(settings::SQLConn, sql::String; conn = nothing, params::Union{Nothing, AbstractPormGParam} = nothing, ignore_tx::Bool = false) = fetch_async(settings.connections, sql; conn=conn, params=params, ignore_tx=ignore_tx)
fetch_async(settings::SQLConn, sql::String, params::AbstractPormGParam; conn = nothing, ignore_tx::Bool = false) = fetch_async(settings.connections, sql; conn=conn, params=params, ignore_tx=ignore_tx)
fetch_async(settings::Union{PormGPostgres, PormGSQLite}, sql::String, params::AbstractPormGParam; conn = nothing, ignore_tx::Bool = false) = fetch_async(settings, sql; conn=conn, params=params, ignore_tx=ignore_tx)

"""
    fetch(connection::Union{PormGPostgres, PormGSQLite}, sql::String; params=nothing, ignore_tx=false) -> Tables.rowtable

Execute a database query synchronously (blocking).
Internally uses async execution but immediately awaits the result.
"""
function fetch(connection::Union{PormGPostgres, PormGSQLite}, sql::String;
  conn = nothing,
  params::Union{Nothing, AbstractPormGParam} = nothing,
  ignore_tx::Bool = false)
  @pormg_debug false

  # Use async-first approach: start async query then await
  fetch_task = fetch_async(connection, sql; conn=conn, params=params, ignore_tx=ignore_tx)

  try
    return await_result(fetch_task)
  catch e
    root = _unwrap_async_exception(e)
    # Never retry inside a transaction context or on a caller-pinned conn (#138): the retry
    # re-runs the statement on a fresh autocommit session (a write that should die with the
    # transaction gets committed) and reconnect_db + await_result would swap and release the
    # transaction's pool slot mid-transaction. Propagate instead so run_in_transaction's
    # rollback/renewal path (#71) owns the cleanup on the original pinned connection.
    if conn === nothing && !fetch_task.in_transaction && backend_is_connection_error(connection, root)
      @warn "Lost connection to database. Attempting to reconnect..."
      # Renew the dead handle in its slot, then retry through NORMAL pool acquisition —
      # never by pinning `conn=new_conn`: the failed task's finally already marked the slot
      # available, so a pinned retry would run on a connection a concurrent borrower can
      # acquire at the same time. Acquisition flips the slot unavailable under the lock.
      new_conn = reconnect_db(connection, fetch_task.conn)
      if new_conn !== nothing
        retry_task = fetch_async(connection, sql; params=params, ignore_tx=ignore_tx)
        return await_result(retry_task)
      end
    end
    throw(root)
  end
end
fetch(settings::SQLConn, sql::String; conn = nothing, params::Union{Nothing, AbstractPormGParam} = nothing, ignore_tx::Bool = false) = fetch(settings.connections, sql; conn=conn, params=params, ignore_tx=ignore_tx)
fetch(settings::SQLConn, sql::String, params::AbstractPormGParam; conn = nothing, ignore_tx::Bool = false) = fetch(settings.connections, sql; conn=conn, params=params, ignore_tx=ignore_tx)
fetch(settings::Union{PormGPostgres, PormGSQLite}, sql::String, params::AbstractPormGParam; conn = nothing, ignore_tx::Bool = false) = fetch(settings, sql; conn=conn, params=params, ignore_tx=ignore_tx)

"""
    fetch_copy(connection::PormGPostgres, sql::String, data_itr)

Execute a PostgreSQL `COPY FROM STDIN` operation using an iterable of data chunks.
The driver-specific streaming (`LibPQ.CopyIn` + result drain) lives in the PostgreSQL
extension as `backend_copy_in!`.
"""
function fetch_copy(connection::PormGPostgres, sql::String, data_itr)
  # Check for transaction context
  tx_conn = get_tx_connection()

  if tx_conn !== nothing
    # Reuse the transaction connection — COPY is part of the open transaction.
    backend_copy_in!(connection, tx_conn, sql, data_itr)
  else
    # Acquire a pool connection for the duration of the COPY stream. CopyIn owns the
    # connection until the stream is fully consumed, so we hold it until done.
    conn = acquire_connection(connection)
    try
      backend_copy_in!(connection, conn, sql, data_itr)
    finally
      release_connection(connection, conn)
    end
  end
end
fetch_copy(settings::SQLConn, sql::String, data_itr) = fetch_copy(settings.connections, sql, data_itr)

"""
    with_transaction_async(pool::PormGPostgres, sql::String; ...) -> (task, conn)

Start an async transaction query. Returns the async handle and connection.
The connection is NOT released - caller must manage it for transaction continuation.

For transactions, you typically want to keep the connection for multiple queries.
"""
function with_transaction_async(pool::Union{PormGPostgres, PormGSQLite}, sql::String;
  conn = nothing,
  params::Union{Nothing, AbstractPormGParam} = nothing)

  if conn === nothing
    if pool isa PormGSQLite
      conn = acquire_connection(pool; mode=:write)
    else
      conn = acquire_connection(pool)
    end
  end
  try
    task = if pool isa PormGPostgres
      backend_execute_async(pool, conn, sql, params)
    else
      sqlite_execute_async(pool, conn, sql, params)
    end
    # Don't wrap in FetchTask since we don't want auto-release
    return task, conn
  catch e
    release_connection(pool, conn)
    throw(e)
  end
end

function with_transaction(pool::Union{PormGPostgres, PormGSQLite}, sql::String;
  conn = nothing,
  release_conn::Bool = false,
  params::Union{Nothing, AbstractPormGParam} = nothing)

  conn_acquired = false
  rollback_failed = false
  if conn === nothing
    if pool isa PormGSQLite
      conn = acquire_connection(pool; mode=:write)
    else
      conn = acquire_connection(pool)
    end
    conn_acquired = true
  end

  try
    # Use async execution but await immediately
    task = if pool isa PormGPostgres
      backend_execute_async(pool, conn, sql, params)
    else
      sqlite_execute_async(pool, conn, sql, params)
    end
    result = Base.fetch(task)
    return result, conn
  catch e
    # A transaction-ending ROLLBACK that itself failed may leave the connection with an
    # open/aborted transaction — it must never return to the pool as-is (#71); both
    # release points below renew or discard it instead.
    rollback_failed = _is_transaction_rollback(sql) && !_is_benign_rollback_error(pool, e)
    # If we acquired the connection here and the command failed (like BEGIN),
    # and we were not asked to release it (which means the caller expected it back),
    # we MUST release it now because the caller won't receive it in the return.
    if conn_acquired && !release_conn
      rollback_failed ? _renew_or_discard_connection!(pool, conn) : release_connection(pool, conn)
    end
    @error "Failed to execute SQL transaction, rolling back: $e"
    throw(e)
  finally
    if release_conn
      rollback_failed ? _renew_or_discard_connection!(pool, conn) : release_connection(pool, conn)
    end
  end
end
with_transaction(pool::SQLConn, sql::AbstractString; conn = nothing, release_conn::Bool = false, params::Union{Nothing, AbstractPormGParam} = nothing) = with_transaction(pool.connections, sql; conn=conn, release_conn=release_conn, params=params)
with_transaction_async(pool::SQLConn, sql::String; conn = nothing, params::Union{Nothing, AbstractPormGParam} = nothing) = with_transaction_async(pool.connections, sql; conn=conn, params=params)

"""
    with_savepoint(f::Function, settings::SQLConn, name::String) -> result

Execute `f()` wrapped in a PostgreSQL savepoint named `name`. On success, releases the
savepoint. On error, rolls back to the savepoint, releases it, and rethrows so the outer
transaction remains usable.

Transparently no-ops when called outside an active transaction context or on a
non-PostgreSQL backend, so callers do not need to guard the call site.
"""
function with_savepoint(f::Function, settings::SQLConn, name::String)
  pool = settings.connections
  if !(pool isa PormGPostgres) || transaction_connection_for(settings) === nothing
    return f()
  end

  fetch(settings, "SAVEPOINT $(name);")
  try
    result = f()
    fetch(settings, "RELEASE SAVEPOINT $(name);")
    return result
  catch e
    try
      fetch(settings, "ROLLBACK TO SAVEPOINT $(name);")
      fetch(settings, "RELEASE SAVEPOINT $(name);")
    catch rollback_error
      @error "Failed to rollback savepoint" name=name exception=rollback_error
    end
    rethrow(e)
  end
end

"""
    with_sqlite_write_lock(f::Function, pool)

Run `f()` while holding the pool's write-serialization lock on SQLite; a no-op
(just `f()`) on PostgreSQL.

SQLite permits a single writer per database file, and PormG funnels every
statement through one global async worker. If two write transactions issue
`BEGIN IMMEDIATE` concurrently, the losing one blocks the worker inside
libsqlite3 for `busy_timeout` (30 s), which starves the winning transaction's
own INSERT/COMMIT on that same worker — a deadlock that surfaces as
"Timeout waiting for available SQLite connection". Holding this lock for the
whole `BEGIN..COMMIT/ROLLBACK` guarantees only one writer is ever outstanding,
so `BEGIN IMMEDIATE` never contends. Concurrent reads (WAL) are unaffected.

The lock is a `ReentrantLock`, so a task that already holds it (an outer
write transaction) may re-enter without self-deadlock.

!!! warning "Cross-task limitation"
    Reentrancy is *per task*, not per call-tree. A task that holds this lock
    (i.e. is inside `run_in_transaction`/`delete()`) and then `wait`s on a
    *separate* task that issues its own SQLite write will deadlock: the child
    blocks on the lock the parent holds while the parent blocks on the child.
    SQLite cannot run two live write transactions on one file anyway, so this
    pattern is unsupported — either schedule the write before opening the
    transaction, or let the child inherit the transaction context (a `@async`
    created *inside* the transaction reuses the pinned connection instead of
    opening its own).
"""
with_sqlite_write_lock(f::Function, pool::PormGSQLite) = Base.lock(f, pool.write_lock)
with_sqlite_write_lock(f::Function, pool::PormGPostgres) = f()
with_sqlite_write_lock(f::Function, settings::SQLConn) = with_sqlite_write_lock(f, settings.connections)

"""
    run_in_transaction(f::Function, pool::PormGPostgres) -> result

Execute a function within a database transaction with proper connection context.
All `fetch()` calls within the function will automatically use the same connection.

This is the recommended way to run transactions as it ensures:
1. All queries use the same connection (transaction isolation)
2. Automatic COMMIT on success
3. Automatic ROLLBACK on error
4. Connection is properly released back to the pool

# Example using PormG objects
```julia
include("db/models.jl")
import .models as M

result = run_in_transaction(pool) do
  driver_query = M.Driver |> object
  new_driver = driver_query.create(
    "forename" => "Alice",
    "surname" => "Lane",
    "nationality" => "British",
    "driverref" => "alice_lane"
  )

  race_query = M.Race |> object
  race_query.create(
    "year" => 2025,
    "round" => 1,
    "name" => "Gran Turismo",
    "circuitid" => 1
  )

  # Keep counting or aggregate inside the transaction if needed
  driver_count = driver_query |> do_count
  return (new_driver[:driverid], driver_count)
end
```
"""
function run_in_transaction(f::Function, pool::Union{PormGPostgres, PormGSQLite})
  # Serialize SQLite writers around the whole BEGIN..COMMIT so concurrent write
  # transactions never race on `BEGIN IMMEDIATE` (see `with_sqlite_write_lock`).
  # Acquire the write lock BEFORE the pool connection so a waiting writer does not
  # hold a pooled connection idle while blocked. No-op on PostgreSQL.
  return with_sqlite_write_lock(pool) do
    _run_in_transaction_impl(f, pool)
  end
end

function _run_in_transaction_impl(f::Function, pool::Union{PormGPostgres, PormGSQLite})
  conn = if pool isa PormGSQLite
    acquire_connection(pool; mode=:write)
  else
    acquire_connection(pool)
  end
  tx_started = false
  rollback_failed = false
  try
    # Begin transaction
    if pool isa PormGPostgres
        task = backend_execute_async(pool, conn, "BEGIN;", nothing)
        Base.fetch(task)
    else
        # Use BEGIN IMMEDIATE for SQLite to prevent deadlocks and ensure
        # write lock is acquired early for multi-threaded scenarios.
      task = sqlite_execute_async(pool, conn, "BEGIN IMMEDIATE TRANSACTION;", nothing)
      Base.fetch(task)
    end
    tx_started = true

    # Execute the function within transaction context
    result = with_tx_context(pool, conn) do
      f()
    end

    # Commit on success
    if pool isa PormGPostgres
        task = backend_execute_async(pool, conn, "COMMIT;", nothing)
        Base.fetch(task)
    else
      task = sqlite_execute_async(pool, conn, "COMMIT;", nothing)
      Base.fetch(task)
    end

    return result
  catch e
    root = _unwrap_async_exception(e)
    # Rollback on error if transaction actually started
    if tx_started
      try
        if pool isa PormGPostgres
            task = backend_execute_async(pool, conn, "ROLLBACK;", nothing)
            Base.fetch(task)
        else
          task = sqlite_execute_async(pool, conn, "ROLLBACK;", nothing)
          Base.fetch(task)
        end
      catch rollback_error
        if _is_benign_rollback_error(pool, rollback_error)
          # SQLite already auto-rolled-back; the connection is clean → the finally
          # releases it normally.
        else
          # The connection may still hold an open/aborted transaction that the acquire
          # liveness probe cannot detect. It must NOT return to the pool as-is (#71);
          # the finally renews or discards it instead.
          rollback_failed = true
          @error "Failed to rollback transaction; connection will be renewed before returning to the pool" exception=_unwrap_async_exception(rollback_error)
        end
      end
    end
    root === e ? rethrow() : throw(root)
  finally
    if rollback_failed
      # Never releases the dirty handle; never throws (the original error keeps propagating).
      _renew_or_discard_connection!(pool, conn)
    else
      release_connection(pool, conn)
    end
  end
end

function run_in_transaction(f::Function, db::String)
  settings::SQLConn = get_settings(db)
  return run_in_transaction(f, settings.connections)
end

run_in_transaction(f::Function, settings::SQLConn) = run_in_transaction(f, settings.connections)

end # module
