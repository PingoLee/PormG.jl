module ConnectionPool

import Logging
# Extend Base.fetch rather than define a fresh `fetch` — a shadowing `fetch` forces every
# caller to qualify it and conflicts with Base.fetch on `using` (#35). PormG owns the
# first-argument types (PormGPostgres/PormGSQLite/PormGSettings), so this is not type piracy.
import Base: fetch
import PormG: PormGSettings, PormGPostgres, PormGPostgresParam, PormGSQLite, PormGSQLiteParam, AbstractPormGParam, config, PormGModel, DEFAULT_POOL_TIMEOUT
import PormG: @pormg_debug
# `PoolError` is the taxonomy's connection-pool umbrella; it lives in Kernel (layer 1) so that
# modules included before this one can name it (#261). PormGError comes along for `catch` sites.
import PormG: PormGError, PoolError
# Throw sites (#239): a bad acquire mode is a value error, an unresolvable pool is a config error,
# and atomic(durable=true) nesting is transaction-API misuse (#268 — was QueryBuildError).
import PormG: InvalidValueError, InvalidConfigurationError, TransactionError
# #276: `without_foreign_keys` refuses to commit a block that left orphaned rows. Export alone is not
# enough — a submodule needs the name on an explicit import list or it is an UndefVarError at the
# throw site, which no unit test that avoids the path would catch.
import PormG: UnsafeMutationError
# The database-error boundary (#268). This module owns the wrap: every driver failure leaving the
# pool passes `_as_database_error` and arrives as one of these instead of a raw
# `SQLite.SQLiteException` / `LibPQ.Errors.*`.
import PormG: DatabaseError, IntegrityError, OperationalError, StatementError
# Backend generics — driver bodies live in ext/PormGLibPQExt.jl / ext/PormGSQLiteExt.jl.
import PormG: backend_connect, backend_renew_connection, backend_is_alive, backend_execute,
              backend_execute_async, backend_is_connection_error, backend_is_permanent_connect_error,
              backend_cancel_query!, backend_drain_connection!,
              backend_copy_in!, backend_classify_error

export fetch, fetch_async, await_result, FetchTask, fetch_copy
export with_transaction, with_transaction_async, run_in_transaction, atomic, with_savepoint
# #276. Exported HERE as well as from PormG: `src/PormG.jl` reaches this module via a bare
# `using .ConnectionPool`, which imports only exported names — so a top-level `export` of a name this
# module keeps to itself produces a public-but-undefined binding (Aqua's undefined_exports).
export without_foreign_keys
export acquire_connection, release_connection, finalize_transaction_connection!
export PoolTimeoutError, PoolConnectError
export pool_stats
# NOTE: close_pool! is intentionally NOT exported here. Configuration owns the public
# `close_pool!` (it dispatches on a pool OR a db-name String and delegates the pool case to
# this module's `close_pool!`). Exporting it from both modules made `PormG.close_pool!`
# ambiguous and therefore undefined (#35). Callers in this package use `CP.close_pool!`.

# Import transaction context helpers from Configuration
import PormG.Configuration: get_tx_connection, get_tx_pool, with_tx_context, transaction_connection_for, get_settings, ensure_before_connect!, connection_key_for_pool, in_transaction_context, current_transaction_depth

const _REDACT_CONNECTION_STRING_RE = Regex("(?i)(password|user)=[^\\s]+")

# #218: a raw-SQL manual-params array/tuple the caller binds with backend-native placeholders
# ($1,$2 on PostgreSQL, ? on SQLite). PormG performs NO placeholder translation — the caller
# writes the dialect's own marker. Disjoint from AbstractPormGParam (the ORM's internal collector),
# so admitting it in the fetch/fetch_async param slot never collides with the collector methods.
# `String <: AbstractString`, not `AbstractVector`, so the SQL argument is never swallowed.
const ManualParams = Union{AbstractVector, Tuple}

# Normalize a manual-params array before binding. A raw array bypasses every ORM `format_*_sql`
# formatter by design, so a bare `nothing` would reach the driver un-normalized (LibPQ/SQLite treat
# it differently from `missing`). Map `nothing`→`missing` so a NULL binds predictably on both
# backends; every non-null value is passed through byte-for-byte (this is a RAW hatch — no coercion).
# Returns a fresh `Any[]` (never mutates the caller's array) and is idempotent under the fetch retry.
_normalize_manual_params(params::ManualParams) = Any[v === nothing ? missing : v for v in params]

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

Reparented from `Exception` to `PormGError` (#239), so `catch PormGError` covers connection
saturation too. Catching `PoolTimeoutError` specifically is unaffected.
"""
struct PoolTimeoutError <: PoolError
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

"""
    PoolConnectError <: Exception

Thrown by `acquire_connection` when it could not *open* a physical connection — a permanently-bad
connection string (wrong password, missing role/database, an unopenable SQLite path). Distinct from
`PoolTimeoutError` (a healthy pool that is merely saturated): the remedy here is to fix credentials /
host / database, not to raise `pool_size` (#72). Carries the underlying driver exception (`cause`) and a
redacted connection string; catchable so apps can translate it distinctly (e.g. a 500, not a 503-retry).

Reparented from `Exception` to `PormGError` (#239), so `catch PormGError` covers connection failures
too. Catching `PoolConnectError` specifically is unaffected.
"""
struct PoolConnectError <: PoolError
  adapter::String        # "PostgreSQL" | "SQLite"
  cause                  # underlying driver exception (untyped: a driver may throw a non-Exception)
  connection::String     # redacted connection string
  attempts::Int
  elapsed_seconds::Float64
end

Base.showerror(io::IO, e::PoolConnectError) = print(io,
  "PoolConnectError: could not open a ", e.adapter, " connection after ", e.attempts, " attempt(s) / ",
  round(e.elapsed_seconds, digits=1), "s: ",
  (e.cause isa Exception ? sprint(showerror, e.cause) : string(e.cause)),
  " (connection=", e.connection, "). Check credentials, host, and database name in connection.yml.")

function _run_before_connect!(pool::Union{PormGPostgres, PormGSQLite})
  if !ensure_before_connect!(pool)
    key = something(connection_key_for_pool(pool), "?")
    # PoolConnectError, not ErrorException: a hook refusing the connection is a connect-time
    # failure like any other, and `catch PoolError` must cover it (audit finding). The hook is the
    # documented downstream-extension seam (Nitro), so this is consumer-reachable.
    throw(PoolConnectError(pool isa PormGPostgres ? "PostgreSQL" : "SQLite",
                           "before_connect hook aborted the connection", key, 1, 0.0))
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

"""
    _await_abandoned(e) -> Bool

Was this await cut short by a *cancellation*, rather than by the database refusing the statement
(#315)? Two shapes reach `await_result` and both must answer `true`:

  * the SIGINT was force-thrown into the driver's own result task, so `Base.fetch` raises a
    `TaskFailedException` wrapping the `InterruptException` — this is the shape in the issue report;
  * the SIGINT hit the task doing the awaiting, so `e` IS the `InterruptException` and the driver
    task is still running on the connection.

The distinction is what decides the connection's fate: a refused statement leaves the connection
clean, an abandoned one does not.

Deliberately **not** built on [`_unwrap_async_exception`](@ref). That helper stops at a
`CompositeException` carrying more than one exception — which is exactly what LibPQ's
`handle_result` throws when several results errored, one of which can be the interrupt. The
recursion below finds it anywhere in the tree. It sees through a [`DatabaseError`](@ref) too, so a
caller that already crossed the taxonomy seam can ask the same question.
"""
function _await_abandoned(e, depth::Int = 0)::Bool
  depth > 8 && return false                       # cheap guard against pathological nesting
  e isa InterruptException && return true
  if e isa TaskFailedException
    nested = e.task.exception
    return nested !== e && _await_abandoned(nested, depth + 1)
  end
  e isa CompositeException && return any(x -> x !== e && _await_abandoned(x, depth + 1), e.exceptions)
  e isa DatabaseError && return _await_abandoned(_driver_cause(e), depth + 1)
  return false
end

"""
    _driver_cause(e) -> Any

The driver's own exception behind `e`, or `e` itself when it is not one of ours. Every site that
*classifies* a failure must call this, because since #268 a driver error may already be wrapped in a
[`DatabaseError`](@ref) by a lower seam — and the driver classifiers (`backend_is_connection_error`,
`backend_is_permanent_connect_error`) match on the driver type and message, so handing them a
wrapper silently answers `false`.

That is not theoretical: LibPQ reports a connection dropped mid-query as `PQResultError{CUN,EUNOWN}`
with an *empty* message, which `backend_is_connection_error` recognizes by exact type-and-string
match. Wrapped, that branch never fires and `fetch`'s reconnect-retry (#138) dies silently.
"""
_driver_cause(e::DatabaseError) = e.cause
_driver_cause(e) = e

"""
    _as_database_error(pool, e) -> Exception

Funnel every failure leaving the pool through the taxonomy: unwrap the async envelope, pass PormG's
own errors through untouched, and wrap anything else as a [`DatabaseError`](@ref) whose kind comes
from [`backend_classify_error`](@ref) (#268).

**Only ever apply this where the exception can only have come from the driver.** It must never see a
caller's closure: `run_in_transaction`/`atomic`/`with_savepoint` run user code inside their `try`,
and relabelling a user's `BoundsError` — or an `InterruptException` — as a `StatementError` would be
worse than the raw-driver-error problem this solves. Those bodies wrap their own BEGIN/COMMIT/
ROLLBACK statements individually instead (`_await_tx_statement`).
"""
function _as_database_error(pool, e)
  root = _unwrap_async_exception(e)
  root isa PormGError && return root
  adapter = pool isa PormGPostgres ? "PostgreSQL" : "SQLite"
  kind = backend_classify_error(pool, root)
  kind === :integrity   && return IntegrityError(adapter, root)
  kind === :operational && return OperationalError(adapter, root)
  # `:statement` and anything unrecognized land here, so `catch DatabaseError` has no hole.
  return StatementError(adapter, root)
end

"""
    _await_tx_statement(pool, task)

Await a bare BEGIN/COMMIT/ROLLBACK task and convert a driver failure into the taxonomy. These
statements are issued directly through `backend_execute_async` / `sqlite_execute_async` rather than
through `fetch`, so they are the one driver path a transaction body owns that no other seam covers.
"""
function _await_tx_statement(pool, task)
  try
    return Base.fetch(task)
  catch e
    throw(_as_database_error(pool, e))
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
  pool_timeout::Float64   # default acquire_connection timeout, seconds (#126; connection.yml `pool_timeout`)
  fail_fast_on_connect::Bool  # fast-fail permanent connect errors instead of waiting pool_timeout (#72)
  lock::ReentrantLock  # For thread safety
end

mutable struct SQLiteConnectionPool <: PormGSQLite
  connections::Vector{Any}
  available::Vector{Bool}
  connection_string::String
  pool_size::Int
  pool_timeout::Float64   # default acquire_connection timeout, seconds (#126; connection.yml `pool_timeout`)
  fail_fast_on_connect::Bool  # fast-fail permanent connect errors instead of waiting pool_timeout (#72)
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

function PostgresConnectionPool(connection_string::String; pool_size::Int = 3, pool_timeout::Real = DEFAULT_POOL_TIMEOUT, fail_fast_on_connect::Bool = true)
  connections = Vector{Any}(nothing, pool_size)
  available = fill(true, pool_size)
  lock = ReentrantLock()
  PostgresConnectionPool(connections, available, connection_string, pool_size, Float64(pool_timeout), fail_fast_on_connect, lock)
end

function SQLiteConnectionPool(connection_string::String; pool_size::Int = 3, split_read_write::Bool = false, pool_timeout::Real = DEFAULT_POOL_TIMEOUT, fail_fast_on_connect::Bool = true)
  connections = Vector{Any}(nothing, pool_size)
  available = fill(true, pool_size)
  lock = ReentrantLock()
  effective_split = split_read_write && pool_size > 1
  if split_read_write && !effective_split
    @warn "SQLite split read/write mode requires pool_size > 1; falling back to shared pool" pool_size=pool_size
  end
  SQLiteConnectionPool(connections, available, connection_string, pool_size, Float64(pool_timeout), fail_fast_on_connect, effective_split, 1, 0, lock, ReentrantLock())
end

# Default acquire timeout (seconds) for a pool. Dispatch + generic fallback so the pool-shaped mock
# structs (which don't carry `pool_timeout`) resolve to DEFAULT_POOL_TIMEOUT with zero changes.
_pool_timeout(pool::PostgresConnectionPool) = pool.pool_timeout
_pool_timeout(pool::SQLiteConnectionPool)   = pool.pool_timeout
_pool_timeout(pool) = DEFAULT_POOL_TIMEOUT

# Whether to fast-fail a permanently-bad connection instead of waiting the full pool_timeout (#72).
# Dispatch + generic fallback so pool-shaped mocks (which don't carry the field) default to `true`.
_fail_fast_on_connect(pool::PostgresConnectionPool) = pool.fail_fast_on_connect
_fail_fast_on_connect(pool::SQLiteConnectionPool)   = pool.fail_fast_on_connect
_fail_fast_on_connect(pool) = true

# Record a failed `backend_connect` and decide whether to fast-fail. Returns true only when the error is
# classified permanent (auth / cantopen — see `backend_is_permanent_connect_error`) AND fast-fail is
# enabled for the pool. `last_ref` persists the cause across acquire passes so the terminal branch can
# raise a truthful `PoolConnectError`. Shared by both acquire twins so the PG/SQLite policy can't drift (#72).
function _on_connect_failure!(pool, e, last_ref::Base.RefValue{Any})
  last_ref[] = e
  return _fail_fast_on_connect(pool) && backend_is_permanent_connect_error(pool, e)
end

# Choose the terminal acquire error. If any `backend_connect` failed during this call, the pool could not
# be (fully) opened → raise a truthful `PoolConnectError` carrying the driver cause (its remedy is
# credentials/host, not `pool_size`). Otherwise the pool is healthy but saturated → `PoolTimeoutError`.
# Shared by both twins' `:timeout` / `:wait`-timeout branches (#72).
function _acquire_terminal_error(pool, adapter::String, last_connect_error, pool_size::Int,
                                 ceiling::Int, attempts::Int, elapsed::Float64)
  last_connect_error === nothing &&
    return PoolTimeoutError(adapter, pool_size, ceiling, attempts, elapsed)
  return PoolConnectError(adapter, last_connect_error, redact_secret(pool.connection_string), attempts, elapsed)
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

# ── Direct-handoff wait (#124) ───────────────────────────────────────────────
# Replaces acquire_connection's busy-poll. Instead of sleeping 100ms and rescanning, a task with
# no available slot parks as a PoolWaiter; the next capacity-freeing op (release / discard) hands
# the freed slot DIRECTLY to the oldest compatible waiter — leaving it leased so a newcomer cannot
# barge (HikariCP / Go database/sql style). Fair (FIFO) and event-driven; sub-100ms handoff.

# One parked acquirer. `chan` is capacity-1: exactly ONE producer — a release-handoff OR the
# timeout Timer — ever put!s to it, decided by read-modify-writing `done` under the pool lock
# (that lock IS the compare-and-set). `mode` types the waiter for SQLite split pools (:any on PG).
mutable struct PoolWaiter
  mode::Symbol
  chan::Channel{Any}
  done::Bool
end
PoolWaiter(mode::Symbol) = PoolWaiter(mode, Channel{Any}(1), false)

# Delivered to a waiter's channel when its timeout budget elapses (vs. a slot index on handoff).
const _POOL_WAIT_TIMEOUT = :__pormg_pool_wait_timeout__

# Waiter FIFO queues live OUTSIDE the pool structs so mock pools that declare their own
# `<: PormGPostgres/PormGSQLite` struct (with no `waiters` field) are unaffected (#124). Each
# pool's Vector is only ever mutated while holding that pool's own `lock`; the WeakKeyDict itself
# is guarded by `_POOL_WAITERS_LOCK`. Lock order is always pool.lock → _POOL_WAITERS_LOCK, never
# the reverse. WeakKeyDict so a GC'd pool's queue is collected.
const _POOL_WAITERS = WeakKeyDict{Any, Vector{PoolWaiter}}()
const _POOL_WAITERS_LOCK = ReentrantLock()

_waiters_for(pool)::Vector{PoolWaiter} =
  Base.lock(() -> get!(() -> PoolWaiter[], _POOL_WAITERS, pool), _POOL_WAITERS_LOCK)

# Can a waiter of `mode` use slot `i`? Mirrors `_sqlite_candidate_slots!` so a freed slot wakes
# exactly the waiters a scan would have let use it (never strands free capacity behind a
# compatible waiter). PostgreSQL is homogeneous; SQLite typed only when split_read_write.
_slot_fits_mode(::PormGPostgres, ::Int, ::Symbol) = true
function _slot_fits_mode(pool::PormGSQLite, i::Int, mode::Symbol)
  (!pool.split_read_write || mode == :any) && return true
  mode == :write && return i == pool.writer_slot
  return true   # mode == :read: any reader slot, plus the writer slot as documented fallback
end

# Called UNDER pool.lock by every capacity-freeing site. Hands slot `i` directly to the oldest
# not-done waiter whose mode fits it (leaving available[i]=false — leased for that waiter, so no
# barging); if none is compatible, the slot returns to `available` for the next same-mode acquirer.
function _handoff_or_free!(pool, i::Int)
  ws = _waiters_for(pool)
  idx = findfirst(w -> !w.done && _slot_fits_mode(pool, i, w.mode), ws)
  if idx === nothing
    pool.available[i] = true
  else
    w = ws[idx]
    w.done = true                 # win the race against this waiter's timeout Timer
    deleteat!(ws, idx)
    put!(w.chan, i)               # cap-1 + empty → never blocks; slot stays leased (available[i]=false)
  end
  return nothing
end

# The timeout producer, symmetric with `_handoff_or_free!`: deliver the timeout sentinel iff the
# waiter has not already been handed a slot. The `done` read-modify-write under pool.lock resolves
# the timeout↔handoff race — exactly one producer ever put!s the waiter's channel.
function _pool_wait_timeout!(pool, w::PoolWaiter)
  Base.lock(pool.lock) do
    if !w.done
      w.done = true
      ws = _waiters_for(pool)
      k = findfirst(x -> x === w, ws)   # `===(w)` has no curried form; use an explicit closure
      k === nothing || deleteat!(ws, k)
      put!(w.chan, _POOL_WAIT_TIMEOUT)
    end
  end
  return nothing
end

# ── Pool monitor: idle reaping + max-lifetime (#125) + leak detection (#127) ─────────────────────────
# One per-slot state store shared by two opt-in features. Reaping (#125): connection.yml
# `idle_timeout`/`max_lifetime`, seconds; 0 = off. A global background sweeper
# closes OVERFLOW connections (slot index > pool_size) that sat idle-available beyond `idle_timeout` or
# are older than `max_lifetime`, trimming the pool back toward its base `pool_size`. Reaping closes +
# nils the slot IN PLACE (keeps available[i]=true, NEVER deleteat!), so #124's slot-index handoff and
# #37's append-only `== ceiling` reasoning stay valid; it never touches a leased or a base slot.
# When no pool has opted in (the default), every hook below is a single Atomic read — zero cost.

mutable struct ReapConfig
  idle_timeout::Float64   # seconds; 0 = off
  max_lifetime::Float64   # seconds; 0 = off
end

# Per-pool MONITOR state, index-aligned (append-only) with pool.connections. Lives OUTSIDE the pool
# structs (in `_POOL_MONITOR`) so mock pools without these fields are unaffected — same rationale as
# #124's `_POOL_WAITERS`. Mutated only inside the pool's own lock (keeps it aligned with connections).
# Shared by reaping (#125) and leak detection (#127): `last_used[i]` is written on checkout and again on
# return, so for a LEASED slot it is that slot's checkout instant — exactly what leak detection needs, so
# leak detection reuses it (no separate timestamp store, no parallel checkout hooks).
mutable struct PoolMonitorState
  config::ReapConfig            # idle_timeout / max_lifetime (#125)
  leak_threshold::Float64       # seconds; 0 = off (#127)
  created_at::Vector{Float64}   # when the connection now in slot i was opened (#125)
  last_used::Vector{Float64}    # when slot i was last checked out / returned (== checkout time while leased)
  leak_warned::Vector{Bool}     # already warned for slot i's current lease (#127)
end

const _POOL_MONITOR = WeakKeyDict{Any, PoolMonitorState}()   # populated ONLY by enable_reaping!/enable_leak_detection!
const _POOL_MONITOR_LOCK = ReentrantLock()
# Fast path: false (default — no pool opted in) → every hook returns immediately. Monotonic: set true by
# the first enable_reaping!/enable_leak_detection!, never cleared. Lock order: pool.lock → _POOL_MONITOR_LOCK.
const _MONITOR_ANY = Threads.Atomic{Bool}(false)
const _REAP_INTERVAL = 15.0   # seconds between background sweeps (fixed)

# The pool's PoolMonitorState, or nothing when monitoring is globally off / this pool never opted in.
function _monitor_state(pool)::Union{PoolMonitorState, Nothing}
  _MONITOR_ANY[] || return nothing
  Base.lock(() -> get(_POOL_MONITOR, pool, nothing), _POOL_MONITOR_LOCK)
end

# Get-or-create the pool's monitor state (empty = all features off, vectors sized to the current pool).
# Both enable_reaping! and enable_leak_detection! go through this so a later opt-in MERGES into the same
# state instead of overwriting the other's config. Sizing AND registration happen inside ONE pool.lock
# critical section (nested per the documented order pool.lock → _POOL_MONITOR_LOCK): the pool cannot
# grow between reading `length(pool.connections)` and registering the state, so a concurrent expand's
# `_monitor_note_create!` can never be lost — no slot is born untracked.
function _monitor_state_for!(pool)::PoolMonitorState
  Base.lock(pool.lock) do
    Base.lock(_POOL_MONITOR_LOCK) do
      st = get(_POOL_MONITOR, pool, nothing)
      st === nothing || return st
      n = length(pool.connections)
      t = time()
      st = PoolMonitorState(ReapConfig(0.0, 0.0), 0.0, fill(t, n), fill(t, n), fill(false, n))
      _POOL_MONITOR[pool] = st
      return st
    end
  end
end

# Record that slot i just received a freshly-opened connection: grow the vectors in lockstep with a
# path-C push!, or reset timestamps for a reused/materialized slot. Call UNDER pool.lock.
function _monitor_note_create!(pool, i::Int)
  st = _monitor_state(pool); st === nothing && return
  t = time()
  # Grow in lockstep (normally by exactly one). Gap entries are filled `fresh` (t), never 0.0, so an
  # accidental gap can never read as "ancient" and trigger a spurious max-lifetime retire.
  while length(st.last_used) < i
    push!(st.last_used, t); push!(st.created_at, t); push!(st.leak_warned, false)
  end
  st.created_at[i] = t; st.last_used[i] = t; st.leak_warned[i] = false
  return nothing
end

# Record that slot i was just checked out or returned: bump last_used and clear the leak warn so the
# next lease starts fresh. Call UNDER pool.lock.
function _monitor_note_touch!(pool, i::Int)
  st = _monitor_state(pool); st === nothing && return
  if i <= length(st.last_used)
    st.last_used[i] = time()
    st.leak_warned[i] = false
  end
  return nothing
end

# Should the connection being RETURNED to slot i be retired now (max-lifetime, overflow only)?
# Call UNDER pool.lock.
function _reap_should_retire(pool, i::Int)::Bool
  st = _monitor_state(pool); st === nothing && return false
  st.config.max_lifetime > 0 && i > pool.pool_size && i <= length(st.created_at) &&
    (time() - st.created_at[i]) > st.config.max_lifetime
end

"""
    enable_reaping!(pool; idle_timeout=0, max_lifetime=0) -> pool

Opt a pool into idle-connection reaping / max-lifetime (#125). `idle_timeout`/`max_lifetime` are in
seconds; `0` (the default) leaves that dimension off, and if both are off this is a no-op. Registers
(or updates) the pool's `PoolMonitorState` and starts the shared background sweeper. Called by
`Configuration` after a pool is built from `connection.yml`.

Re-configuring (calling again, or after `enable_leak_detection!` already registered the state) only
swaps the reap config — the per-slot clocks are deliberately NOT reset: `created_at`/`last_used`
keep measuring the connection's TRUE open / last-use instants, so an overflow connection that is
already idle or over-lifetime may be retired on the very next sweep rather than being granted a
fresh grace window from the enable instant. (Pre-#127, each call rebuilt the state with fresh
timestamps; the unified monitor state keeps the honest clocks instead.)
"""
function enable_reaping!(pool::Union{PormGPostgres, PormGSQLite}; idle_timeout::Real = 0, max_lifetime::Real = 0)
  (idle_timeout <= 0 && max_lifetime <= 0) && return pool
  st = _monitor_state_for!(pool)
  st.config = ReapConfig(Float64(idle_timeout), Float64(max_lifetime))   # merge: leak config (if any) preserved
  _MONITOR_ANY[] = true
  _ensure_reaper!()
  return pool
end

"""
    enable_leak_detection!(pool; threshold=0) -> pool

Opt a pool into connection-leak detection (#127). `threshold` is in seconds; `0` (the default) is a
no-op. When enabled, `acquire_connection` scans the leased slots and emits a single `@warn` per slot
whose lease has exceeded `threshold` — pointing at a connection that was acquired but never released
(e.g. a `fetch_async` that was never awaited). Reuses the shared per-slot checkout timestamps
(`PoolMonitorState.last_used`); no background task (the scan runs on the next acquire).
"""
function enable_leak_detection!(pool::Union{PormGPostgres, PormGSQLite}; threshold::Real = 0)
  threshold <= 0 && return pool
  st = _monitor_state_for!(pool)
  st.leak_threshold = Float64(threshold)   # merge: reaping config (if any) preserved
  _MONITOR_ANY[] = true
  return pool
end

# Scan LEASED slots for a lease held past the leak threshold and @warn once per culprit (#127). Directly
# callable so tests drive it deterministically. `last_used[i]` is the checkout instant for a leased slot,
# so no separate checkout timestamp is needed.
function _leak_check!(pool)
  st = _monitor_state(pool); st === nothing && return
  st.leak_threshold <= 0 && return
  now = time()
  leaked = Tuple{Int, Float64}[]
  Base.lock(pool.lock) do
    for i in 1:length(pool.connections)
      pool.available[i] && continue            # only LEASED (in-use) slots can leak
      i <= length(st.leak_warned) || continue
      st.leak_warned[i] && continue            # already warned for this lease
      held = now - st.last_used[i]
      if held > st.leak_threshold
        push!(leaked, (i, held)); st.leak_warned[i] = true
      end
    end
  end
  # @warn OUTSIDE the pool lock. One actionable line per culprit; connection string redacted per house rules.
  for (i, held) in leaked
    @warn "Pool connection held past leak_detection_threshold — likely acquired without release; await the FetchTask or release the connection" slot=i held_s=round(held; digits=1) threshold_s=st.leak_threshold connection_string=redact_secret(pool.connection_string)
  end
  return nothing
end

const _reaper_lock = ReentrantLock()
const _reaper_started = Ref(false)

# Start the single global sweeper task (spawn-once, mirroring `_ensure_sqlite_async_worker!`).
function _ensure_reaper!()
  _reaper_started[] && return
  Base.lock(_reaper_lock) do
    _reaper_started[] && return
    Threads.@spawn begin
      while true
        sleep(_REAP_INTERVAL)
        try
          _reap_all_pools!()
        catch e
          @debug "Connection-pool reaper sweep failed" exception=e
        end
      end
    end
    _reaper_started[] = true
  end
  return nothing
end

# Snapshot the registry (releasing its lock before taking any pool.lock), then reap each pool.
function _reap_all_pools!()
  pools = Base.lock(() -> collect(keys(_POOL_MONITOR)), _POOL_MONITOR_LOCK)
  for pool in pools                       # a GC'd pool is absent from the WeakKeyDict → _monitor_state nothing
    try
      _reap_pool!(pool)
    catch e
      @debug "Connection-pool reap failed" exception=e
    end
  end
  return nothing
end

# Close idle/over-lifetime OVERFLOW connections of one pool. Directly callable so tests drive it
# deterministically (no waiting on the Timer). Never touches a leased slot or a base slot.
function _reap_pool!(pool)
  st = _monitor_state(pool); st === nothing && return
  (st.config.idle_timeout <= 0 && st.config.max_lifetime <= 0) && return
  now = time()
  to_close = Any[]
  Base.lock(pool.lock) do
    for i in (pool.pool_size + 1):length(pool.connections)   # OVERFLOW ONLY — base 1..pool_size kept warm
      pool.available[i] || continue                          # never reap a LEASED (in-use) slot
      conn = pool.connections[i]
      conn === nothing && continue
      idle = st.config.idle_timeout > 0 && i <= length(st.last_used)  && (now - st.last_used[i])  > st.config.idle_timeout
      life = st.config.max_lifetime > 0 && i <= length(st.created_at) && (now - st.created_at[i]) > st.config.max_lifetime
      if idle || life
        pool.connections[i] = nothing      # available[i] STAYS true; no _handoff_or_free! (an available
        push!(to_close, conn)              # idle slot has no compatible waiter — see #125 notes)
      end
    end
  end
  # Close OUTSIDE the pool lock (a driver close can block on I/O), like `_discard_connection!`.
  for conn in to_close
    try
      Base.invokelatest(close, conn)
    catch e
      @debug "Error closing reaped connection" exception=e
    end
  end
  return nothing
end

# The single source of truth for the pool's growth ceiling — used by both acquire_connection
# twins (PoolTimeoutError enforcement) and pool_stats (reporting), so they can never diverge.
_pool_ceiling(pool)::Int = pool.pool_size * POOL_EXPANSION_FACTOR

"""
    pool_stats(pool) -> NamedTuple

A snapshot of connection-pool health (#127), driver-agnostic. Returns
`(; pool_size, size, in_use, available, ceiling, waiting)`:

- `pool_size` — the configured base floor (warm minimum).
- `size` — slots allocated so far (grows lazily under load; `== in_use + available`).
- `in_use` — connections leased right now.
- `available` — free slots (idle handles or not-yet-materialized slots).
- `ceiling` — the maximum the pool can grow to (`pool_size * $(POOL_EXPANSION_FACTOR)`).
- `waiting` — callers currently parked waiting for a connection (#124).

Safe to call anytime; all counts — including `waiting` — are read in one `pool.lock` critical
section for a coherent snapshot (waiter vectors are only ever mutated under `pool.lock`, #124).
`PormG`'s top module adds a `pool_stats(key::AbstractString)` convenience overload. Unlike
`close_pool!(db::String)` — a teardown that tolerates a never-built pool — that overload throws an
`ArgumentError` for a never-built pool: a zeroed snapshot would read as a healthy empty pool.
"""
function pool_stats(pool::Union{PormGPostgres, PormGSQLite})
  in_use, available, size, waiting = Base.lock(pool.lock) do
    # Dict lookup under _POOL_WAITERS_LOCK (lock order pool.lock → _POOL_WAITERS_LOCK); the waiter
    # Vector itself is only ever mutated under pool.lock, which we hold — so counting it here is
    # race-free AND coherent with the slot counts.
    ws = Base.lock(() -> get(_POOL_WAITERS, pool, PoolWaiter[]), _POOL_WAITERS_LOCK)
    (count(!, pool.available), count(identity, pool.available), length(pool.connections),
     count(w -> !w.done, ws))
  end
  return (; pool_size = pool.pool_size,
            size,
            in_use,
            available,
            ceiling = _pool_ceiling(pool),
            waiting)
end

function close_pool!(pool::PostgresConnectionPool)
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

function close_pool!(pool::SQLiteConnectionPool)
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

# The two methods above dispatch on the CONCRETE pool structs so they only ever touch real
# pool fields (`lock`/`connections`/`available`). Any other `PormGPostgres`/`PormGSQLite`
# value is not a real connection pool — e.g. a lightweight mock that SQL-inspection unit
# tests register in `config` to satisfy dialect dispatch — so cleanup must SKIP it rather
# than trip on its missing fields. Without this fallback, `__cleanup__` (which closes every
# `config` entry) aborts with a `FieldError` the first time it reaches a leaked test mock (#147).
close_pool!(::Union{PormGPostgres, PormGSQLite}) = nothing

"""
    acquire_connection(pool::PormGPostgres; timeout_seconds=nothing, max_retries=300)
    acquire_connection(pool::PormGSQLite; timeout_seconds=nothing, max_retries=300, mode=:any)

Lease a connection from the pool. **You own it until you give it back** — every
`acquire_connection` must be paired with a [`release_connection`](@ref), and the release
belongs in a `finally` so an exception cannot leak the slot:

```julia
conn = acquire_connection(pool)
try
    # … use conn …
finally
    release_connection(pool, conn)
end
```

Most code should not call this at all — `run_in_transaction` and the fluent terminals do the
pairing for you. Reach for it only when hand-rolling a connection lifecycle.

# Keyword arguments
- `timeout_seconds`: how long to wait for a free connection. Defaults to the pool's
  `pool_timeout` from `connection.yml` (30 s if unset, #126); passing it explicitly wins.
- `max_retries`: a safety bound on scan/materialize iterations, not a poll count — waiting is
  event-driven (#124), so this is normally 1.
- `mode` (**SQLite only**): `:read`, `:write`, or `:any`. When the pool has read/write
  splitting enabled, only the writer slot may write, so **a connection you intend to write on
  must be acquired with `mode = :write`**; `:read` or `:any` can hand you a read-only handle
  and the write will fail. Any other symbol raises `InvalidValueError`.

The pool grows lazily up to `pool_size × 10`. Exhausting that budget within the timeout raises
`PoolTimeoutError`; a permanent connect failure (bad credentials, missing database, unopenable
SQLite file) fails fast with `PoolConnectError`, whose connection string is redacted. Both are
catchable and exported.

See also [`release_connection`](@ref), `pool_stats`, and the
[Advanced Configuration](@ref) guide for pool tuning and leak detection.
"""
function acquire_connection(pool::PormGPostgres; timeout_seconds::Union{Nothing, Real} = nothing, max_retries::Int = 300)
  start_time = time()
  # Default acquire timeout comes from the pool (connection.yml `pool_timeout`, #126); an explicit
  # per-call `timeout_seconds` still wins.
  to = timeout_seconds === nothing ? _pool_timeout(pool) : Float64(timeout_seconds)
  deadline = start_time + to
  _MONITOR_ANY[] && _leak_check!(pool)   # leak detection (#127): warn about connections held past the threshold
  # `attempts` counts scan/materialize loop iterations (event-driven wait, not the old 100ms poll),
  # so it is small — typically 1 on a clean saturated timeout. It is a diagnostic field on
  # PoolTimeoutError; `max_retries` still bounds it as a safety limit on pathological create loops.
  attempts = 0
  # Tracks whether the before_connect hook already ran for this acquire call, so it runs at most
  # once even across retries.
  before_connect_done = false
  # A slot handed to us by a release/discard (leased for us) that still needs its connection
  # validated/materialized. `nothing` when we are doing a normal scan.
  owned::Union{Nothing, Int} = nothing
  ceiling = _pool_ceiling(pool)
  # Most recent `backend_connect` failure this call. When set, the terminal branch raises a truthful
  # PoolConnectError (the pool couldn't be opened) instead of the saturation PoolTimeoutError (#72).
  last_connect_error = Ref{Any}(nothing)

  while true
    attempts += 1

    outcome = Base.lock(pool.lock) do
      # (A) Materialize a handed-off slot (already leased for us; #124 direct handoff).
      if owned !== nothing
        i = owned
        conn = pool.connections[i]
        if conn !== nothing && backend_is_alive(pool, conn)
          _monitor_note_touch!(pool, i)                   # checkout timestamp (#125)
          return (:got, conn)                          # live handle handed over — reuse as-is
        end
        # Empty/dead slot (e.g. handed off by _discard_connection!): open a fresh connection.
        before_connect_done || return (:hook, nothing)
        try
          new_conn = backend_connect(pool)
          pool.connections[i] = new_conn
          _monitor_note_create!(pool, i)                  # fresh connection timestamp (#125)
          return (:got, new_conn)
        catch e
          # Free/hand-off the leased slot BEFORE we return either way — on a fast-fail bail too, so the
          # slot handed to us (#124) is never leaked (#72).
          fast_fail = _on_connect_failure!(pool, e, last_connect_error)
          _handoff_or_free!(pool, i)                    # pass the slot on / free it
          fast_fail && return (:connect_failed, e)
          @debug "Failed to materialize handed-off PG connection $i: $e" connection_string=redact_secret(pool.connection_string)
          return (:retry, nothing)
        end
      end

      # (B) Normal scan for an available slot.
      for i in 1:length(pool.connections)
        if pool.available[i]
          if pool.connections[i] !== nothing && backend_is_alive(pool, pool.connections[i])
            pool.available[i] = false
            _monitor_note_touch!(pool, i)                  # checkout timestamp (#125)
            return (:got, pool.connections[i])
          end
          # Slot is empty or dead: defer creation so the before_connect hook runs off the lock.
          before_connect_done || return (:hook, nothing)
          try
            new_conn = backend_connect(pool)
            pool.connections[i] = new_conn
            pool.available[i] = false
            _monitor_note_create!(pool, i)                 # fresh connection timestamp (#125)
            return (:got, new_conn)
          catch e
            _on_connect_failure!(pool, e, last_connect_error) && return (:connect_failed, e)
            @debug "Failed to create PG connection $i: $e" connection_string=redact_secret(pool.connection_string)
            pool.available[i] = true
            continue
          end
        end
      end

      # (C) Expand the pool if we haven't reached the ceiling. Append-only under the lock, so the
      # `== ceiling` check is race-free even under `-t auto` — the @warn fires exactly once (#37).
      if length(pool.connections) < ceiling
        before_connect_done || return (:hook, nothing)
        try
          new_conn = backend_connect(pool)
          push!(pool.connections, new_conn)
          push!(pool.available, false)
          _monitor_note_create!(pool, length(pool.connections))   # grow monitor vectors in lockstep (#125)
          new_size = length(pool.connections)
          if new_size == ceiling
            @warn "PG pool reached its maximum size; raise pool_size to add capacity" max_size=new_size pool_size=pool.pool_size connection_string=redact_secret(pool.connection_string)
          else
            @debug "PG pool expanded beyond initial size" current_size=new_size initial_size=pool.pool_size
          end
          return (:got, new_conn)
        catch e
          _on_connect_failure!(pool, e, last_connect_error) && return (:connect_failed, e)
          @debug "Failed to expand PG pool: $e" connection_string=redact_secret(pool.connection_string)
        end
      end

      # (D) No capacity. Time out, or park as a waiter for direct handoff. Enqueue happens in the
      # SAME locked section as the "no capacity" check, so a concurrent release can't slip a wakeup
      # in between (no lost wakeup).
      if attempts >= max_retries || time() >= deadline
        return (:timeout, nothing)
      end
      w = PoolWaiter(:any)
      push!(_waiters_for(pool), w)
      return (:wait, w)
    end

    kind = outcome[1]
    if kind === :got
      return outcome[2]
    elseif kind === :hook
      _run_before_connect!(pool)                        # off the lock (#37); keep `owned`
      before_connect_done = true
      continue
    elseif kind === :retry
      owned = nothing
      continue
    elseif kind === :connect_failed
      # Permanent connect failure (bad password / missing role|db) with fast-fail on: don't wait the
      # full timeout — raise the truthful cause now (#72).
      throw(PoolConnectError("PostgreSQL", outcome[2], redact_secret(pool.connection_string), attempts, time() - start_time))
    elseif kind === :timeout
      err = _acquire_terminal_error(pool, "PostgreSQL", last_connect_error[], pool.pool_size, ceiling, attempts, time() - start_time)
      if err isa PoolTimeoutError
        if attempts >= max_retries
          @warn "Exceeded maximum retry attempts ($max_retries) to acquire PG connection" pool_size=pool.pool_size connection_string=redact_secret(pool.connection_string)
        else
          @warn "Timeout after $(to) seconds waiting for available PG connection" pool_size=pool.pool_size connection_string=redact_secret(pool.connection_string)
        end
      end
      throw(err)
    else # :wait — park until a connection is handed to us or the deadline elapses.
      w = outcome[2]
      timer = Timer(_ -> _pool_wait_timeout!(pool, w), max(deadline - time(), 0.0))
      handed = try
        take!(w.chan)
      finally
        close(timer)
      end
      if handed === _POOL_WAIT_TIMEOUT
        err = _acquire_terminal_error(pool, "PostgreSQL", last_connect_error[], pool.pool_size, ceiling, attempts, time() - start_time)
        err isa PoolTimeoutError &&
          @warn "Timeout after $(to) seconds waiting for available PG connection" pool_size=pool.pool_size connection_string=redact_secret(pool.connection_string)
        throw(err)
      end
      owned = handed::Int                                # loop back to materialize the handed slot
      continue
    end
  end
end

function acquire_connection(pool::PormGSQLite; timeout_seconds::Union{Nothing, Real} = nothing, max_retries::Int = 300, mode::Symbol = :any)
  mode in (:any, :read, :write) || throw(InvalidValueError("Invalid SQLite acquire mode: $(mode). Expected :any, :read or :write."))

  start_time = time()
  # Default acquire timeout comes from the pool (connection.yml `pool_timeout`, #126); an explicit
  # per-call `timeout_seconds` still wins.
  to = timeout_seconds === nothing ? _pool_timeout(pool) : Float64(timeout_seconds)
  deadline = start_time + to
  _MONITOR_ANY[] && _leak_check!(pool)   # leak detection (#127): warn about connections held past the threshold
  attempts = 0
  # See the PormGPostgres twin: hook runs off the lock at most once; `owned` is a slot handed to
  # us (leased) awaiting materialize; direct-handoff wait replaces the busy-poll (#124).
  before_connect_done = false
  owned::Union{Nothing, Int} = nothing
  ceiling = _pool_ceiling(pool)
  # See the PormGPostgres twin: most recent connect failure this call → truthful PoolConnectError (#72).
  last_connect_error = Ref{Any}(nothing)

  while true
    attempts += 1

    outcome = Base.lock(pool.lock) do
      # (A) Materialize a handed-off slot (already leased for us).
      if owned !== nothing
        i = owned
        conn = pool.connections[i]
        if conn !== nothing && backend_is_alive(pool, conn)
          _monitor_note_touch!(pool, i)                   # checkout timestamp (#125)
          return (:got, conn)
        end
        before_connect_done || return (:hook, nothing)
        try
          is_reader_slot = pool.split_read_write && i != pool.writer_slot
          new_conn = backend_connect(pool; read_only = is_reader_slot)
          pool.connections[i] = new_conn
          _monitor_note_create!(pool, i)                  # fresh connection timestamp (#125)
          return (:got, new_conn)
        catch e
          # Free/hand-off the leased slot BEFORE we return either way, fast-fail included (#72/#124).
          fast_fail = _on_connect_failure!(pool, e, last_connect_error)
          _handoff_or_free!(pool, i)
          fast_fail && return (:connect_failed, e)
          @debug "Failed to materialize handed-off SQLite connection $i: $e" connection_string=redact_secret(pool.connection_string)
          return (:retry, nothing)
        end
      end

      # (B) Normal mode-aware scan.
      for i in _sqlite_candidate_slots!(pool, mode)
        if pool.available[i]
          if pool.connections[i] !== nothing && backend_is_alive(pool, pool.connections[i])
            pool.available[i] = false
            _monitor_note_touch!(pool, i)                  # checkout timestamp (#125)
            return (:got, pool.connections[i])
          end
          before_connect_done || return (:hook, nothing)
          try
            is_reader_slot = pool.split_read_write && i != pool.writer_slot
            new_conn = backend_connect(pool; read_only = is_reader_slot)
            pool.connections[i] = new_conn
            pool.available[i] = false
            _monitor_note_create!(pool, i)                 # fresh connection timestamp (#125)
            return (:got, new_conn)
          catch e
            _on_connect_failure!(pool, e, last_connect_error) && return (:connect_failed, e)
            @debug "Failed to create SQLite connection $i: $e" connection_string=redact_secret(pool.connection_string)
            pool.available[i] = true
            continue
          end
        end
      end

      # (C) Expand (never for split pools — fixed reader/writer layout). Append-only under the lock
      # → the `== ceiling` warn is race-free (#37).
      can_expand = !pool.split_read_write && length(pool.connections) < ceiling
      if can_expand
        before_connect_done || return (:hook, nothing)
        try
          new_conn = backend_connect(pool)
          push!(pool.connections, new_conn)
          push!(pool.available, false)
          _monitor_note_create!(pool, length(pool.connections))   # grow monitor vectors in lockstep (#125)
          new_size = length(pool.connections)
          if new_size == ceiling
            @warn "SQLite pool reached its maximum size; raise pool_size to add capacity" max_size=new_size pool_size=pool.pool_size connection_string=redact_secret(pool.connection_string)
          else
            @debug "SQLite pool expanded beyond initial size" current_size=new_size initial_size=pool.pool_size
          end
          return (:got, new_conn)
        catch e
          _on_connect_failure!(pool, e, last_connect_error) && return (:connect_failed, e)
          @debug "Failed to expand SQLite pool: $e" connection_string=redact_secret(pool.connection_string)
        end
      end

      # (D) No capacity: time out or park (enqueue in the same locked section → no lost wakeup).
      if attempts >= max_retries || time() >= deadline
        return (:timeout, nothing)
      end
      w = PoolWaiter(mode)
      push!(_waiters_for(pool), w)
      return (:wait, w)
    end

    kind = outcome[1]
    if kind === :got
      return outcome[2]
    elseif kind === :hook
      _run_before_connect!(pool)
      before_connect_done = true
      continue
    elseif kind === :retry
      owned = nothing
      continue
    elseif kind === :connect_failed
      # Permanent connect failure (unopenable path) with fast-fail on: raise the truthful cause now (#72).
      throw(PoolConnectError("SQLite", outcome[2], redact_secret(pool.connection_string), attempts, time() - start_time))
    elseif kind === :timeout
      err = _acquire_terminal_error(pool, "SQLite", last_connect_error[], pool.pool_size, ceiling, attempts, time() - start_time)
      err isa PoolTimeoutError &&
        @warn (attempts >= max_retries ?
          "Exceeded maximum retry attempts ($max_retries) to acquire SQLite connection" :
          "Timeout after $(to) seconds waiting for available SQLite connection") pool_size=pool.pool_size connection_string=redact_secret(pool.connection_string)
      throw(err)
    else # :wait
      w = outcome[2]
      timer = Timer(_ -> _pool_wait_timeout!(pool, w), max(deadline - time(), 0.0))
      handed = try
        take!(w.chan)
      finally
        close(timer)
      end
      if handed === _POOL_WAIT_TIMEOUT
        err = _acquire_terminal_error(pool, "SQLite", last_connect_error[], pool.pool_size, ceiling, attempts, time() - start_time)
        err isa PoolTimeoutError &&
          @warn "Timeout after $(to) seconds waiting for available SQLite connection" pool_size=pool.pool_size connection_string=redact_secret(pool.connection_string)
        throw(err)
      end
      owned = handed::Int
      continue
    end
  end
end

"""
    release_connection(pool, conn) -> Bool

Return a connection leased by [`acquire_connection`](@ref) to its pool. The other half of the
pairing contract — call it from a `finally`.

Returns `true` when the slot was found and freed, `false` (with a warning) when it was not,
which means the connection had already been replaced after a failure. The slot is matched by
object **identity**, so you must release the same handle you were given: after a renewal, pass
the renewed connection, not the original.

On release the pool either hands the slot straight to a caller waiting for one (#124) or marks
it available; an overflow connection past its `max_lifetime` is closed and retired instead of
reused (#125).

!!! warning "Not for a transaction that may have failed"
    A connection whose `ROLLBACK` itself threw can still hold an open transaction, and this
    function would hand it back to the pool as-is. Terminate a manual `BEGIN`/`COMMIT`/
    `ROLLBACK` lifecycle with [`finalize_transaction_connection!`](@ref), which renews or
    discards it in that case (#71).

See also [`acquire_connection`](@ref).
"""
function release_connection(pool::PormGPostgres, conn)
  retired = nothing
  released = Base.lock(pool.lock) do
    for i in 1:length(pool.connections)
      if pool.connections[i] === conn
        if _reap_should_retire(pool, i)    # over max_lifetime (overflow only) → retire on return (#125)
          retired = pool.connections[i]
          pool.connections[i] = nothing
        else
          _monitor_note_touch!(pool, i)       # last_used = now (#125)
        end
        _handoff_or_free!(pool, i)         # hand the slot to a waiter (leased) or mark it available (#124)
        return true
      end
    end
  end
  if retired !== nothing
    try; Base.invokelatest(close, retired); catch e; @debug "Error closing retired PG connection" exception=e; end
  end
  released !== nothing && return released
  @warn "PG Connection not found in the pool - connection may have been replaced due to failure"
  return false
end

function release_connection(pool::PormGSQLite, conn)
  retired = nothing
  released = Base.lock(pool.lock) do
    for i in 1:length(pool.connections)
      if pool.connections[i] === conn
        if _reap_should_retire(pool, i)    # over max_lifetime (overflow only) → retire on return (#125)
          retired = pool.connections[i]
          pool.connections[i] = nothing
        else
          _monitor_note_touch!(pool, i)       # last_used = now (#125)
        end
        _handoff_or_free!(pool, i)         # hand the slot to a waiter (leased) or mark it available (#124)
        return true
      end
    end
  end
  if retired !== nothing
    try; Base.invokelatest(close, retired); catch e; @debug "Error closing retired SQLite connection" exception=e; end
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

`close_handle = false` empties the slot but leaves the handle open. It exists for one caller —
[`_recover_abandoned_connection!`](@ref)'s timeout branch, which is reached *precisely because* the
driver is still on the connection — and closing there would free a SQLite handle the global worker
may be inside `sqlite3_step` on. That caller takes the slot out of circulation now and closes the
doomed handle later, once the driver has let go.
"""
function _discard_connection!(pool::Union{PormGPostgres, PormGSQLite}, conn; close_handle::Bool = true)::Bool
  found = Base.lock(pool.lock) do
    for i in 1:length(pool.connections)
      if pool.connections[i] === conn
        pool.connections[i] = nothing
        # Hand the now-empty slot to a waiter (which materializes a fresh conn) or free it (#124).
        _handoff_or_free!(pool, i)
        return true
      end
    end
    return false
  end
  # Close OUTSIDE the pool lock: a driver close can block on I/O. On SQLite this also
  # releases the database file write-lock an aborted `BEGIN IMMEDIATE` may still hold.
  if close_handle
    try
      close(conn)
    catch close_error
      @debug "Error closing discarded connection" exception=close_error
    end
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

Stays a message match on purpose. "no transaction is active" is a SQLite-only condition and SQLite
attaches no error code to it (`SQLiteException` carries only `msg`), so there is no kind for
[`backend_classify_error`](@ref) to return — this is a *benign* signal, not an error class. It does
have to see through a [`DatabaseError`](@ref) wrapper though: `finalize_transaction_connection!`
is handed `rollback_error` values that already crossed a seam (`migrations/runner.jl`,
`querybuilder/deletion.jl`), so `_driver_cause` is load-bearing here (#268).
"""
_is_benign_rollback_error(pool::Union{PormGPostgres, PormGSQLite}, e) =
  pool isa PormGSQLite &&
  occursin("no transaction is active", string(_driver_cause(_unwrap_async_exception(e))))

"""
    _finish_statement_connection!(pool, conn, handle; abandoned, rollback_failed) -> Nothing

How ONE statement's connection goes back to the pool, for [`with_transaction`](@ref)'s two release
points (the `catch`, when it acquired the connection itself, and the `finally`, when the caller asked
for a release). A single helper because the two sites must not drift apart — they are the same
decision reached down different paths.

Ordered by severity, and the order is load-bearing:

  * `abandoned` — a cancellation cut the await short (#322), so the driver may still be ON this
    connection. It is the only case where nothing here may touch it, so it must be tested first:
    the `rollback_failed` branch below renews SYNCHRONOUSLY, which would block on LibPQ's
    per-connection semaphore and would close a SQLite handle its worker is still stepping.
  * `rollback_failed` — a transaction-ending `ROLLBACK` that itself failed may leave an open or
    aborted transaction the acquire liveness probe cannot detect (#71).
  * otherwise the driver is done and the connection is clean: plain release.

`handle` is the driver object the abandoned await was parked on; it is only read on the `abandoned`
branch. Never throws — every branch is itself guarded, and callers run this while an original error
is propagating.
"""
function _finish_statement_connection!(pool::Union{PormGPostgres, PormGSQLite}, conn, handle;
                                       abandoned::Bool = false, rollback_failed::Bool = false)
  if abandoned
    # Detached: cancel, wait for the driver to let go, then renew — never touching the connection
    # while it may still be in use. `force_renew` because this connection is mid-lifecycle and a
    # clean wire says nothing about the transaction state left on it.
    _recover_abandoned_connection!(pool, conn, handle; force_renew = true)
  elseif rollback_failed
    _renew_or_discard_connection!(pool, conn)
  else
    release_connection(pool, conn)
  end
  return nothing
end

"""
    finalize_transaction_connection!(pool, conn; rollback_error=nothing) -> Nothing

Terminal step of a manually-driven `BEGIN`/`COMMIT`/`ROLLBACK` lifecycle: return `conn` to the
pool exactly once. Pass `rollback_error=nothing` when the COMMIT succeeded or the cleanup ROLLBACK
ran cleanly. If `rollback_error` is supplied — the cleanup ROLLBACK threw — and it is not a benign
"no transaction is active" error, `conn` may still hold an open/aborted transaction that the acquire
liveness probe cannot detect, so it is renewed or discarded instead of released (#71).

Call this from a single terminal `finally`, exactly as `run_in_transaction` does, so a lifecycle
never releases its connection to the pool before its ROLLBACK has run on it — the release-then-
rollback use-after-release race of #139. Never throws: it runs while the transaction's original
error is propagating.

Pass `renew=true` when the lifecycle mutated per-connection **session state** that releasing cannot
undo — today only SQLite's `PRAGMA foreign_keys = OFF`, which migrations and
[`without_foreign_keys`](@ref) use to suspend enforcement (#276). Renewal re-runs the driver's
connect path, which sets the pragma back ON by construction, and it is the *renewed* handle that
returns to the slot; the suspended one is closed. Restoring the pragma with a statement instead
would be unsound: `PRAGMA foreign_keys` is silently ignored while a transaction is open, so a failed
COMMIT *and* failed ROLLBACK would leave enforcement off with the restore reporting success.
"""
function finalize_transaction_connection!(pool::Union{PormGPostgres, PormGSQLite}, conn;
                                          rollback_error = nothing, renew::Bool = false)
  if renew || (rollback_error !== nothing && !_is_benign_rollback_error(pool, rollback_error))
    _renew_or_discard_connection!(pool, conn)
  else
    release_connection(pool, conn)
  end
  return nothing
end
# PormGSettings overload — delegates to the underlying pool, mirroring with_transaction(::PormGSettings).
finalize_transaction_connection!(pool::PormGSettings, conn; rollback_error = nothing, renew::Bool = false) =
  finalize_transaction_connection!(pool.connections, conn; rollback_error = rollback_error, renew = renew)

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
- `abandoned::Bool`: Whether the await was cut short by a cancellation rather than a database
  failure (#315). Set by `await_result`; it sends the connection through the abandoned-await
  recovery — cancel, wait for the driver, drain, then release or renew — instead of a plain
  release. (Plain backticks, not an `@ref`: this struct is exported, so `@autodocs` publishes this
  docstring to `api.md`, and a cross-reference from there to an internal helper cannot resolve —
  `Private = false` means the target is never rendered. That broke the docs build once.)
"""
mutable struct FetchTask
  async_result::Any  # LibPQ.AsyncResult (PG) or Task (SQLite)
  pool::Union{PormGPostgres, PormGSQLite}
  conn::Any
  completed::Bool
  result_cache::Union{Nothing, Any}
  in_transaction::Bool  # Whether this task is part of a transaction context
  abandoned::Bool       # Await cut short by a cancellation — connection is NOT returnable as-is (#315)

  # Constructor for transaction-aware fetch
  FetchTask(async_result, pool::Union{PormGPostgres, PormGSQLite}, conn, in_transaction::Bool) =
    new(async_result, pool, conn, false, nothing, in_transaction, false)

  # Legacy constructor (defaults to not in transaction)
  FetchTask(async_result, pool::Union{PormGPostgres, PormGSQLite}, conn) =
    new(async_result, pool, conn, false, nothing, false, false)
end

# Abandoned-await recovery budgets (#315), in seconds. Exposed as `_recover_abandoned_connection!`
# kwargs so a unit test can drive the timeout branch in milliseconds instead of waiting one out.
#
#   settle — how long the slot stays leased hoping the connection can be recovered in place. Both
#            cancels normally abort within milliseconds, so reaching this means the engine never
#            acknowledged one.
#   close  — how long a detached, doomed handle is kept alive waiting for the driver to let go
#            before `close` is attempted regardless. Long on purpose: the cost of waiting is one
#            parked task, the cost of closing early is a use-after-free. Note that expiry does not
#            make the close itself bounded — `close(::LibPQ.Connection)` takes the same per-connection
#            semaphore the running result task holds (it does set libpq's cancel flag first), and
#            SQLite's `sqlite3_close_v2` defers while a statement is live. Expiry only stops this
#            task polling; the handle is still closed in driver order.
const _ABANDON_SETTLE_SECONDS = 5.0
const _ABANDON_CLOSE_SECONDS = 300.0

"""
    _settle_probe(handle) -> Function

Park ONE detached waiter on the driver handle and return a zero-argument predicate answering
"has the driver let go of this connection?" (#315).

`Base.wait` is the only settle test that spans both backends without core naming a driver type:
LibPQ defines it on its `AsyncResult` as `wait(result_task)`, and SQLite's handle *is* a `Task`.
(`Base.isready` is not usable — LibPQ defines it on `AsyncResult`, `Task` does not have it.) It
**throws** when that task failed, which is a *settled* outcome and all we asked, so the throw is
swallowed. Waiting here also CONSUMES that failure, which is what stops Julia printing an
"Unhandled Task Error" for a query nobody is listening to any more.

One waiter, reused by every deadline: a query that never returns leaks exactly one parked task
rather than one per wait, and it exits the moment the driver finally lets go.
"""
function _settle_probe(handle)
  settled = Threads.Atomic{Bool}(false)
  Threads.@spawn begin
    try
      Base.wait(handle)
    catch
      # Failed, cancelled, interrupted — every one of those means the driver is done with it.
    finally
      settled[] = true
    end
  end
  return () -> settled[]
end

# Bounded, non-throwing settle wait. `timedwait` polls the predicate on its own Timer and never
# touches the driver, so a handle that never settles costs a bounded wait rather than a wedged
# recovery task.
_wait_settled(probe, seconds::Real)::Bool =
  timedwait(probe, max(0.0, Float64(seconds)); pollint = 0.05) === :ok

"""
    _recover_abandoned_connection!(pool, conn, handle; settle_seconds, close_seconds, force_renew) -> Nothing
    _recover_abandoned_connection!(ft::FetchTask; settle_seconds, close_seconds, force_renew) -> Nothing

Recover the pool slot of a connection whose driver await was abandoned by a cancellation (#315).
`handle` is the driver-side object the abandoned await was parked on — a `LibPQ.AsyncResult` or the
SQLite worker `Task` — which is what [`_settle_probe`](@ref) waits on. The [`FetchTask`](@ref) form
is the same call with the three fields unpacked.

Replaces the plain [`release_connection`](@ref) that used to run unconditionally. A connection whose
driver operation is still in flight, or which has an unconsumed result queued on it, must never go
back into the pool: neither state is visible to `backend_is_alive` — PostgreSQL still reports
`CONNECTION_OK` — so the next borrower inherits it and every later statement on that slot fails
with *"another command is already in progress"*, for the life of the process.

Runs on a DETACHED task, for three separate reasons:

  * Ctrl-C has to give the REPL back immediately, and every step below can block for seconds
    (`PQcancel` opens its own socket; `LibPQ.reset!` is a synchronous reconnect).
  * On SQLite the connection cannot be touched AT ALL until the global worker is off it, so doing
    this in the caller would make Ctrl-C wait for the very query it just cancelled.
  * A second Ctrl-C would abort a synchronous cleanup half-way and re-poison the slot. A detached
    task does not receive the REPL's interrupt.

The slot stays LEASED for the whole routine. That is the point: it becomes available again only
once the connection is proven clean, and otherwise it is renewed or emptied. Never throws — an
escaping error here would surface as an unhandled task error instead of a recovered slot.

`force_renew = true` skips the drain and renews unconditionally. It is for the callers that abandoned
an await **inside a transaction or session lifecycle** (#322) — `_run_in_transaction_impl`'s `BEGIN`,
`with_transaction`, `AdvisoryLock` — where a clean drain is not evidence the connection is reusable.
Two independent reasons, either one sufficient:

  * `backend_drain_connection!` answers a question about the WIRE, not about session state. Its
    PostgreSQL body consumes queued `PGresult`s and never reads `PQtransactionStatus`, so a `BEGIN`
    that *did* land on the server before the interrupt drains perfectly clean — and releasing it
    would put a connection with an open transaction back in the pool, which is #71 in a new place.
  * A session-level `pg_advisory_lock` survives on a drained connection too, and dies only with the
    session. Renewal is what actually releases it.

This is the same shape Go's `pgxpool` uses (`Conn.Release` destroys a connection that is busy or
not idle, and does it off the caller's goroutine) and psycopg's pool (state is verified on return;
a broken connection is discarded and replaced).
"""
function _recover_abandoned_connection!(pool::Union{PormGPostgres, PormGSQLite}, conn, handle;
                                        settle_seconds::Real = _ABANDON_SETTLE_SECONDS,
                                        close_seconds::Real = _ABANDON_CLOSE_SECONDS,
                                        force_renew::Bool = false)
  Threads.@spawn begin
    try
      # 1. Best-effort stop signal, and the ONLY driver call allowed to run while the operation may
      #    still be in flight: PQcancel uses a separate PGcancel on its own socket, and
      #    sqlite3_interrupt is documented cross-thread-safe. Never allowed to escape — a missing
      #    driver hits Backend.jl's throwing fallback, and a closed handle can raise too.
      try
        backend_cancel_query!(pool, conn)
      catch cancel_failure
        @debug "Cancel of an abandoned query failed" exception=cancel_failure
      end

      # 2. Bounded wait for the driver to let go. LOAD-BEARING, not an optimization: LibPQ's
      #    `lock(::Connection)` is a plain `Semaphore(1)` held by the result task for the whole
      #    query, so draining before it settles would block for the query's full remaining life.
      probe = _settle_probe(handle)
      if _wait_settled(probe, settle_seconds)
        if force_renew
          # No drain: the caller abandoned a transaction/session lifecycle, and the wire being clean
          # says nothing about an open transaction or a held session lock (#322 — see the docstring).
          # Skipping it is also the cheaper path, since renewal discards whatever the drain would
          # have consumed anyway.
          _renew_or_discard_connection!(pool, conn)
        else
          clean = try
            backend_drain_connection!(pool, conn)
          catch drain_failure
            @debug "Drain of an abandoned connection failed" exception=drain_failure
            false
          end
          # `=== true`, not a bare `clean ?`: `backend_drain_connection!` is a documented-Bool generic
          # that nothing enforces, and a downstream override returning anything else would raise a
          # TypeError here — landing in the outer catch and costing the slot. Anything that is not a
          # definite "clean" takes the safe branch.
          clean === true ? release_connection(pool, conn) : _renew_or_discard_connection!(pool, conn)
        end
      else
        # 3. Still in flight past the budget. Take the slot out of the pool WITHOUT closing — the
        #    next acquire materializes a fresh connection into it — then keep the doomed handle
        #    alive until the driver is finally off it, and only then close.
        _discard_connection!(pool, conn; close_handle = false)
        _wait_settled(probe, close_seconds)
        try
          Base.invokelatest(close, conn)
        catch close_failure
          @debug "Error closing an abandoned connection" exception=close_failure
        end
      end
    catch recovery_failure
      # Nothing may escape: this task has no owner, so an escape prints an unhandled task error to
      # stderr at finalization — which looks like a crash and pollutes unrelated `@test_logs`.
      #
      # But swallowing alone would re-create #315 in a new place: every branch above ends by
      # releasing, renewing or detaching the slot, so a failure BETWEEN them leaves it leased with
      # nothing scheduled to free it — silently, for the life of the process. The old code could not
      # do that, because its `release_connection` was unconditional. So bail out to the one action
      # that is always safe here: empty the slot so the next borrower opens a fresh connection, and
      # do NOT close the handle — reaching this branch means we do not know whether the driver is
      # still on it. The orphaned handle is left to the driver's own finalizer.
      #
      # Act only while the slot is still OURS. `_discard_connection!` matches by identity, so once an
      # earlier branch has handed the slot back — released it, emptied it, or had `reconnect_db` swap
      # a fresh handle into it — `conn` is no longer there, and blindly discarding would both warn
      # untruthfully and (worse) risk nilling a slot a new borrower already holds.
      #
      # Known gap, deliberately not plumbed: if the failure came from inside
      # `_renew_or_discard_connection!` AFTER its swap, the slot is leased around a handle we cannot
      # name from here, and this bails out to the `@debug` below instead of freeing it. That needs
      # `release_connection` to throw, whose every internal step is itself guarded — so the cost of
      # threading the renewed handle out here is not worth paying for it.
      still_ours = try
        Base.lock(() -> any(c -> c === conn, pool.connections), pool.lock)
      catch
        false
      end
      if still_ours
        @warn "Abandoned-connection recovery failed; emptying the pool slot" exception=recovery_failure
        try
          _discard_connection!(pool, conn; close_handle = false)
        catch discard_failure
          @debug "Emptying the slot after a failed recovery also failed" exception=discard_failure
        end
      else
        @debug "Abandoned-connection recovery failed after the slot was already handed back" exception=recovery_failure
      end
    end
  end
  return nothing
end

# The `fetch`/`await_result` caller already owns all three pieces on a FetchTask; the transaction and
# advisory-lock callers (#322) hold a bare driver handle and no FetchTask, which is why the method
# above is the primary one.
_recover_abandoned_connection!(ft::FetchTask; kwargs...) =
  _recover_abandoned_connection!(ft.pool, ft.conn, ft.async_result; kwargs...)

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
    # Did the await END, or was it ABANDONED? Only the second leaves the driver mid-operation, and
    # only it must keep the connection out of the pool (#315). Deliberately does not change what
    # this throws — see below.
    ft.abandoned = _await_abandoned(e)
    # `rethrow()` when nothing changed: PormG's own errors (DoesNotExist, QueryBuildError,
    # PoolTimeoutError…) pass through `_as_database_error` untouched, and re-`throw`ing the same
    # object would discard the backtrace saying where it came from.
    #
    # An abandoned await still goes through here, so a cancellation still surfaces as a
    # `StatementError` wrapping the `InterruptException`, exactly as before this fix. That
    # relabelling is its own defect — `_as_database_error`'s docstring above forbids it — but
    # correcting it changes a caller-visible error contract, so it is tracked separately.
    err = _as_database_error(ft.pool, e)
    err === e ? rethrow() : throw(err)
  finally
    # Only release connection if we're not in a transaction context
    # Transaction context manages its own connection lifecycle
    if ft.completed && !ft.in_transaction
      # An abandoned await must NOT hand the connection back: the driver may still be writing to it
      # (SQLite's global worker) or have left an unconsumed result on the socket (libpq), and
      # NEITHER state is visible to `backend_is_alive` — so the next borrower would inherit a
      # connection on which every statement fails. Recovery runs detached and owns the
      # release/renew/discard decision from here (#315).
      ft.abandoned ? _recover_abandoned_connection!(ft) : release_connection(ft.pool, ft.conn)
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
  params::Union{Nothing, AbstractPormGParam, ManualParams} = nothing,
  ignore_tx::Bool = false)

  # #218: this is the single funnel every fetch/fetch_async path reaches (delegates and the
  # sync `fetch` — including its reconnect retry — all land here), so normalize manual-params
  # NULLs once, here. Guarded to ManualParams: ORM collectors (AbstractPormGParam) and the
  # `nothing` sentinel are untouched (collectors already ran nothing→missing via format_*_sql).
  if params isa ManualParams
    params = _normalize_manual_params(params)
  end

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
      throw(_as_database_error(connection, e))
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
      throw(_as_database_error(connection, e))
    end
  end
end
fetch_async(settings::PormGSettings, sql::String; conn = nothing, params::Union{Nothing, AbstractPormGParam, ManualParams} = nothing, ignore_tx::Bool = false) = fetch_async(settings.connections, sql; conn=conn, params=params, ignore_tx=ignore_tx)
fetch_async(settings::PormGSettings, sql::String, params::Union{AbstractPormGParam, ManualParams}; conn = nothing, ignore_tx::Bool = false) = fetch_async(settings.connections, sql; conn=conn, params=params, ignore_tx=ignore_tx)
fetch_async(settings::Union{PormGPostgres, PormGSQLite}, sql::String, params::Union{AbstractPormGParam, ManualParams}; conn = nothing, ignore_tx::Bool = false) = fetch_async(settings, sql; conn=conn, params=params, ignore_tx=ignore_tx)

"""
    fetch(connection::Union{PormGPostgres, PormGSQLite}, sql::String; params=nothing, ignore_tx=false) -> Tables.rowtable

Execute a database query synchronously (blocking).
Internally uses async execution but immediately awaits the result.
"""
function fetch(connection::Union{PormGPostgres, PormGSQLite}, sql::String;
  conn = nothing,
  params::Union{Nothing, AbstractPormGParam, ManualParams} = nothing,
  ignore_tx::Bool = false)
  @pormg_debug false
  # Manual-params NULL normalization happens in the fetch_async funnel this delegates to (#218) —
  # `fetch` only forwards params, never inspects their values.

  # Use async-first approach: start async query then await
  fetch_task = fetch_async(connection, sql; conn=conn, params=params, ignore_tx=ignore_tx)

  try
    return await_result(fetch_task)
  catch e
    root = _as_database_error(connection, e)
    # Never retry inside a transaction context or on a caller-pinned conn (#138): the retry
    # re-runs the statement on a fresh autocommit session (a write that should die with the
    # transaction gets committed) and reconnect_db + await_result would swap and release the
    # transaction's pool slot mid-transaction. Propagate instead so run_in_transaction's
    # rollback/renewal path (#71) owns the cleanup on the original pinned connection.
    #
    # `_driver_cause`, not `root`: await_result has already wrapped this, and the classifier
    # matches on the driver's type/message. Deliberately NOT `root isa OperationalError` either —
    # that kind also covers deadlock, lock timeout and serialization failure, and transparently
    # re-running a statement on a fresh autocommit session after a deadlock is a data-corruption
    # bug. Only a *dropped connection* is safe to retry, which is exactly what this asks (#268).
    if conn === nothing && !fetch_task.in_transaction &&
       backend_is_connection_error(connection, _driver_cause(root))
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
fetch(settings::PormGSettings, sql::String; conn = nothing, params::Union{Nothing, AbstractPormGParam, ManualParams} = nothing, ignore_tx::Bool = false) = fetch(settings.connections, sql; conn=conn, params=params, ignore_tx=ignore_tx)
fetch(settings::PormGSettings, sql::String, params::Union{AbstractPormGParam, ManualParams}; conn = nothing, ignore_tx::Bool = false) = fetch(settings.connections, sql; conn=conn, params=params, ignore_tx=ignore_tx)
fetch(settings::Union{PormGPostgres, PormGSQLite}, sql::String, params::Union{AbstractPormGParam, ManualParams}; conn = nothing, ignore_tx::Bool = false) = fetch(settings, sql; conn=conn, params=params, ignore_tx=ignore_tx)

"""
    fetch_copy(connection::PormGPostgres, sql::String, data_itr)

Execute a PostgreSQL `COPY FROM STDIN` operation using an iterable of data chunks.
The driver-specific streaming (`LibPQ.CopyIn` + result drain) lives in the PostgreSQL
extension as `backend_copy_in!`.
"""
function fetch_copy(connection::PormGPostgres, sql::String, data_itr)
  # Check for transaction context
  tx_conn = get_tx_connection()

  # COPY bypasses `fetch`/`await_result` entirely, so it needs its own catch to honor the
  # database-error contract (#268) — before this it was the one write path that still leaked raw
  # `LibPQ.Errors.*` to callers. The catch sits INSIDE the pool branch's try so the terminal
  # `finally` still releases the lease.
  if tx_conn !== nothing
    # Reuse the transaction connection — COPY is part of the open transaction.
    try
      backend_copy_in!(connection, tx_conn, sql, data_itr)
    catch e
      throw(_as_database_error(connection, e))
    end
  else
    # Acquire a pool connection for the duration of the COPY stream. CopyIn owns the
    # connection until the stream is fully consumed, so we hold it until done.
    conn = acquire_connection(connection)
    try
      backend_copy_in!(connection, conn, sql, data_itr)
    catch e
      throw(_as_database_error(connection, e))
    finally
      release_connection(connection, conn)
    end
  end
end
fetch_copy(settings::PormGSettings, sql::String, data_itr) = fetch_copy(settings.connections, sql, data_itr)

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
    throw(_as_database_error(pool, e))
  end
end

"""
    with_transaction(pool, sql::String; conn=nothing, release_conn=false, params=nothing) -> (result, conn)

Run one statement on a transaction-carrying connection. The building block behind manual
`BEGIN` / `COMMIT` / `ROLLBACK` sequences.

!!! tip "Prefer `run_in_transaction`"
    It acquires, commits, rolls back and releases correctly on every path. Reach for
    `with_transaction` only when you genuinely need to drive the lifecycle statement by
    statement.

Returns a **tuple** `(result, conn)`, not just the result — `conn` is the connection the
statement ran on, which you pass back in as `conn` for the next statement of the same
transaction.

# Keyword arguments
- `conn`: an existing connection to reuse. When `nothing`, one is acquired — on SQLite with
  `mode = :write`, since a transaction writes.
- `release_conn`: return the connection to the pool when this call finishes. Leave it `false`
  while the transaction is still open; you receive `conn` back in the return tuple.
- `params`: bound query parameters. Never interpolate values into `sql`.

On error the connection is never orphaned: it is released if this call acquired it, and a
transaction-ending `ROLLBACK` that itself failed causes a renew-or-discard instead, so a
connection with an open or aborted transaction cannot go back into the pool (#71). The
underlying driver exception is rethrown as a `DatabaseError` subtype.

An await cut short by a **cancellation** (`Ctrl+C`) takes neither of those paths: the driver may
still be on the connection, so it is handed to the abandoned-await recovery — cancel, wait for the
driver to let go, then renew — which runs detached and returns the slot only once it is safe (#322).

!!! warning "`release_conn=true` on a COMMIT/ROLLBACK is a use-after-release race"
    It releases the connection **even when the statement fails**, which can hand it back to
    the pool before your cleanup `ROLLBACK` runs on it (#139). Do the cleanup on the still-
    leased connection and return it exactly once from a single `finally` via
    [`finalize_transaction_connection!`](@ref).

See also [`acquire_connection`](@ref), `with_transaction_async`, and the
[Transactions and `run_in_transaction`](@ref) guide.
"""
function with_transaction(pool::Union{PormGPostgres, PormGSQLite}, sql::String;
  conn = nothing,
  release_conn::Bool = false,
  params::Union{Nothing, AbstractPormGParam} = nothing)

  conn_acquired = false
  rollback_failed = false
  # Was the await ABANDONED by a cancellation (#322)?
  abandoned = false
  # The driver handle, and the reason the flag above is gated on it: an interrupt can land BEFORE
  # `backend_execute_async` returns, and with no handle there is nothing for the recovery to settle
  # on — that case must fall through to the ordinary release.
  local task = nothing
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
    # Same defect class one step earlier: a Ctrl-C leaves the driver mid-statement, and neither
    # backend's state is visible to `backend_is_alive`, so releasing here poisons the slot (#322).
    # `rollback_failed` cannot catch it — it is `false` for every sql that is not a plain ROLLBACK.
    abandoned = task !== nothing && _await_abandoned(e)
    # If we acquired the connection here and the command failed (like BEGIN),
    # and we were not asked to release it (which means the caller expected it back),
    # we MUST release it now because the caller won't receive it in the return.
    if conn_acquired && !release_conn
      _finish_statement_connection!(pool, conn, task; abandoned = abandoned, rollback_failed = rollback_failed)
    end
    @error "Failed to execute SQL transaction, rolling back: $e"
    throw(_as_database_error(pool, e))
  finally
    if release_conn
      _finish_statement_connection!(pool, conn, task; abandoned = abandoned, rollback_failed = rollback_failed)
    end
  end
end
with_transaction(pool::PormGSettings, sql::AbstractString; conn = nothing, release_conn::Bool = false, params::Union{Nothing, AbstractPormGParam} = nothing) = with_transaction(pool.connections, sql; conn=conn, release_conn=release_conn, params=params)
with_transaction_async(pool::PormGSettings, sql::String; conn = nothing, params::Union{Nothing, AbstractPormGParam} = nothing) = with_transaction_async(pool.connections, sql; conn=conn, params=params)

"""
    with_savepoint(f::Function, settings::PormGSettings, name::String) -> result

Execute `f()` wrapped in a savepoint named `name`. On success, releases the savepoint.
On error, rolls back to the savepoint, releases it, and rethrows so the outer transaction
remains usable.

Works on **both** PostgreSQL and SQLite — the `SAVEPOINT` / `RELEASE SAVEPOINT` /
`ROLLBACK TO SAVEPOINT` statements are identical on both backends (#26). Transparently
no-ops when called outside an active transaction context on `settings`' pool, so callers
do not need to guard the call site.

`name` must be a fixed, non-user-controlled identifier (it is interpolated into the SQL,
not parameterized — savepoint names are identifiers). Internal callers pass constants;
the reentrant `atomic`/`run_in_transaction` path passes `_savepoint_name(depth)`.
"""
function with_savepoint(f::Function, settings::PormGSettings, name::String)
  if transaction_connection_for(settings) === nothing
    return f()   # not inside a transaction on this pool → nothing to savepoint
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
with_sqlite_write_lock(f::Function, settings::PormGSettings) = with_sqlite_write_lock(f, settings.connections)

# Read `PRAGMA foreign_keys` back off a specific connection. Returns the *actual* session state, not
# what was requested — the distinction matters because SQLite silently ignores `PRAGMA foreign_keys`
# while a transaction is open (verified: setting OFF inside a BEGIN leaves the read-back at 1, with
# no error). Anything that suspends enforcement must therefore confirm it took (#276).
function sqlite_foreign_keys_enabled(pool::PormGSQLite, conn)::Bool
  rows, _ = with_transaction(pool, "PRAGMA foreign_keys;", conn = conn)
  # Fail CLOSED. A real SQLite always answers this with exactly one row, so an empty result means
  # something unexpected answered — and the caller is a guard whose whole job is to refuse to
  # continue unless suspension is *proven*. Reporting "not enabled" on no evidence would let the
  # rebuild proceed with enforcement possibly live, which is the silent-cascade path.
  isempty(rows) && return true
  return first(rows).foreign_keys != 0
end

# Throws if enforcement is still on. Used by the migration runner and `without_foreign_keys` right
# after issuing the suspension.
function _assert_foreign_keys_suspended(pool::PormGSQLite, conn)
  sqlite_foreign_keys_enabled(pool, conn) && throw(InvalidConfigurationError(
    "PRAGMA foreign_keys is still ON on this connection after being asked to suspend it — the \
     statement was almost certainly issued inside a transaction, where SQLite ignores it silently. \
     Refusing to continue: a SQLite table rebuild would cascade-delete child rows and still commit (#276)."))
  return nothing
end

"""
    without_foreign_keys(f::Function, db; check_on_exit::Bool = true) -> result

Run `f()` in a transaction with foreign-key enforcement **suspended**, on a single pinned connection.

**Try a plain [`atomic`](@ref) first.** Inside a transaction PormG already defers foreign-key checks
to `COMMIT` on both backends, so a block that is *transiently* inconsistent — writing children before
their parents — commits without any special handling. Reach for this only when that is not enough:
a load too large for one transaction, a repair that must leave a violation in place, or a test that
plants one deliberately.

`db` may be a pool, a `PormGSettings`, or a db-key `String`, like [`atomic`](@ref). Every query
inside `f()` reuses the pinned connection, and a nested [`atomic`](@ref) becomes a `SAVEPOINT`.

**This block must be the outermost transaction on its pool.** It cannot nest inside
`run_in_transaction`/`atomic` and raises `TransactionError` if you try: suspension works by setting
`PRAGMA foreign_keys = OFF`, which SQLite silently ignores while a transaction is open, so a nested
call could not suspend anything.

With `check_on_exit = true` (the default) a `PRAGMA foreign_key_check` runs before `COMMIT` and
rolls the block back if it finds an orphaned row, raising `UnsafeMutationError` — so the escape hatch
cannot quietly commit a corrupt database.

Note the check is **whole-database, not scoped to what `f()` touched**: on a database that already
contains orphans, it will abort a block that did nothing wrong. That is deliberate (it is the same
`PRAGMA foreign_key_check` the migration rebuild gate uses, and narrowing it would mean guessing
which rows the block touched), but it means a repair run against an already-inconsistent database
wants `check_on_exit = false` — as does deliberately planting a violation.

The connection is **renewed**, not returned as-is, so a suspended handle can never serve another
caller (#276).

# Example
```julia
# A load too large to hold in one transaction: commit each chunk, tolerating the inconsistency
# between them, and let the exit check prove the finished result is sound.
without_foreign_keys(pool) do
    for chunk in Iterators.partition(eachrow(results_df), 50_000)
        bulk_insert(M.Result, DataFrame(chunk))
    end
    bulk_insert(M.Race, races_df)
end

# For a merely transient inconsistency, a plain transaction is enough — and cheaper, since it does
# not have to renew the connection afterwards:
atomic(pool) do
    bulk_insert(M.Result, results_df)   # children
    bulk_insert(M.Race,   races_df)     # parents — checked at COMMIT, on both backends
end
```

!!! note "Backend divergence"
    SQLite genuinely suspends enforcement for the block. On PostgreSQL there is no equivalent — this
    issues `SET CONSTRAINTS ALL DEFERRED`, which *defers* checks to `COMMIT` rather than skipping
    them, so a violation still surfaces, just later. `check_on_exit` is SQLite-only.

See also [`atomic`](@ref), [`run_in_transaction`](@ref).
"""
function without_foreign_keys(f::Function, pool::PormGSQLite; check_on_exit::Bool = true)
  # Must be the OUTERMOST transaction on this pool. `run_in_transaction` degrades a nested call to a
  # SAVEPOINT, but that is not available here: the whole point is `PRAGMA foreign_keys = OFF`, which
  # SQLite ignores inside an open transaction — a nested block could not suspend anything. Worse, it
  # would not fail fast: it re-enters the (reentrant) write lock, then acquires a SECOND connection
  # whose `BEGIN IMMEDIATE` contends with the outer transaction's, and sits there until the busy
  # timeout × retry budget expires (measured: ~11 minutes to `database is locked`, or a
  # `PoolTimeoutError` on a split pool). Refuse immediately instead.
  if in_transaction_context() && get_tx_pool() === pool
    throw(TransactionError(
      "without_foreign_keys must be the outermost transaction on this pool — it cannot nest inside \
       run_in_transaction/atomic, because PRAGMA foreign_keys is silently ignored while a \
       transaction is open. Move the block outside, or drop the surrounding transaction."))
  end
  # Lock BEFORE acquiring, matching run_in_transaction (write lock → writer slot). The reverse order
  # deadlocks against it under split_read_write, where there is exactly one writer slot.
  with_sqlite_write_lock(pool) do
    conn = acquire_connection(pool; mode = :write)
    local rollback_error = nothing
    try
      # Outside the transaction — see sqlite_foreign_keys_enabled for why the order is load-bearing.
      with_transaction(pool, "PRAGMA foreign_keys = OFF;", conn = conn)
      _assert_foreign_keys_suspended(pool, conn)
      # A real transaction, not just the pragma: without one, a nested atomic/with_savepoint would
      # issue SAVEPOINT with nothing enclosing it — savepoint semantics for a caller who asked for
      # transaction semantics — and the block would not be atomic.
      with_transaction(pool, "BEGIN IMMEDIATE TRANSACTION;", conn = conn)
      try
        result = with_tx_context(pool, conn) do
          f()
        end
        if check_on_exit
          violations, _ = with_transaction(pool, "PRAGMA foreign_key_check;", conn = conn)
          # UnsafeMutationError, not IntegrityError: the database did not refuse anything — PormG
          # detected the orphans itself and is refusing to commit them. IntegrityError is reserved
          # for a driver exception it wraps as `.cause` (#268).
          isempty(violations) || throw(UnsafeMutationError(
            "without_foreign_keys left $(length(violations)) orphaned foreign-key row(s); rolling back. \
             Pass check_on_exit = false if the violation is intentional."))
        end
        with_transaction(pool, "COMMIT;", conn = conn, release_conn = false)
        return result
      catch e
        try
          with_transaction(pool, "ROLLBACK;", conn = conn, release_conn = false)
        catch rollback_err
          rollback_error = rollback_err
          @error "Failed to rollback without_foreign_keys block" exception=rollback_err
        end
        rethrow(e)
      end
    finally
      # renew=true: this handle has enforcement OFF and must never go back to the pool as-is.
      finalize_transaction_connection!(pool, conn; rollback_error = rollback_error, renew = true)
    end
  end
end

function without_foreign_keys(f::Function, pool::PormGPostgres; check_on_exit::Bool = true)
  # PostgreSQL has no per-session "skip FK checks". PormG creates its foreign keys
  # DEFERRABLE INITIALLY DEFERRED (Dialect.add_foreign_key), so deferring to COMMIT is the closest
  # equivalent and is what the docstring promises. `check_on_exit` is meaningless here: COMMIT is
  # itself the check.
  run_in_transaction(pool) do
    fetch(pool, "SET CONSTRAINTS ALL DEFERRED;")
    f()
  end
end

without_foreign_keys(f::Function, settings::PormGSettings; check_on_exit::Bool = true) =
  without_foreign_keys(f, settings.connections; check_on_exit = check_on_exit)
without_foreign_keys(f::Function, db::String; check_on_exit::Bool = true) =
  without_foreign_keys(f, get_settings(db); check_on_exit = check_on_exit)

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
    "driverref" => "alice_lane",
    "code" => "ALA",
    "forename" => "Alice",
    "surname" => "Lane",
    "dob" => "1998-04-12",
    "nationality" => "British",
    "url" => "https://example.com/alice_lane"
  )

  race_query = M.Race |> object
  race_query.create(
    "year" => 2025,
    "round" => 1,
    "circuitid" => 1,
    "name" => "Gran Turismo",
    "date" => "2025-03-16",
    "url" => "https://example.com/gran_turismo"
  )

  # Keep counting or aggregating inside the transaction if needed
  driver_count = driver_query.count()
  return (new_driver[:driverid], driver_count)
end
```

Every column above is one the F1 models declare `null = false`; omitting any of them raises at
`create()` before the statement is built.
"""
function run_in_transaction(f::Function, pool::Union{PormGPostgres, PormGSQLite})
  # Reentrancy (#26): a nested run_in_transaction / atomic on the SAME pool becomes a
  # SAVEPOINT on the already-pinned connection instead of a second independent BEGIN.
  # A nested call targeting a DIFFERENT pool (e.g. a second database) still opens its own
  # transaction — correct multi-DB behavior, already guarded by ensure_model_transaction_scope.
  if in_transaction_context() && get_tx_pool() === pool
    return _nested_savepoint(f, _settings_for_pool(pool))
  end
  # Serialize SQLite writers around the whole BEGIN..COMMIT so concurrent write
  # transactions never race on `BEGIN IMMEDIATE` (see `with_sqlite_write_lock`).
  # Acquire the write lock BEFORE the pool connection so a waiting writer does not
  # hold a pooled connection idle while blocked. No-op on PostgreSQL.
  return with_sqlite_write_lock(pool) do
    _run_in_transaction_impl(f, pool)
  end
end

# Deterministic, per-depth savepoint name. Fixed `pormg_sp_<int>` format → no
# identifier-injection surface (the integer suffix is the only variable part). Pure and
# unit-testable in isolation.
_savepoint_name(depth::Integer) = "pormg_sp_$(depth)"

# Resolve the registered PormGSettings for a pool so the reentrant savepoint path (which needs
# `settings` for `with_savepoint`/`fetch`) can route through the pinned connection.
function _settings_for_pool(pool::Union{PormGPostgres, PormGSQLite})::PormGSettings
  key = connection_key_for_pool(pool)
  key === nothing && throw(InvalidConfigurationError("Cannot resolve connection settings for the active transaction pool"))
  return get_settings(key)
end

# Run `f()` as a nested SAVEPOINT inside the already-open transaction on `settings`' pool.
# Enters a new tx context (bumping depth) so the savepoint name is unique per nesting level,
# then delegates to `with_savepoint` for the SAVEPOINT/RELEASE/ROLLBACK-TO lifecycle. Reuses
# the pinned connection: no new connection is acquired, no BEGIN is issued, the SQLite write
# lock (already held reentrantly by the outermost block) is not re-taken, and the outermost
# block still owns the single connection release.
function _nested_savepoint(f::Function, settings::PormGSettings)
  pool = settings.connections
  conn = transaction_connection_for(settings)
  return with_tx_context(pool, conn) do
    with_savepoint(f, settings, _savepoint_name(current_transaction_depth()))
  end
end

function _run_in_transaction_impl(f::Function, pool::Union{PormGPostgres, PormGSQLite})
  conn = if pool isa PormGSQLite
    acquire_connection(pool; mode=:write)
  else
    acquire_connection(pool)
  end
  tx_started = false
  local rollback_error = nothing
  # The BEGIN's driver handle, and whether its await was ABANDONED by a cancellation (#322). Hoisted
  # out of the `try` because the terminal `finally` needs both, and initialized to `nothing` because
  # an interrupt can land *before* `backend_execute_async` returns — with no handle there is nothing
  # to settle on, so that case must fall through to the ordinary finalize rather than recover.
  local begin_task = nothing
  abandoned_begin = false
  try
    # Begin transaction. `_await_tx_statement`, not a bare `Base.fetch`: these statements bypass
    # `fetch`, so they are the only driver contact in this function that no seam covers. The
    # function-wide `catch` below must NOT wrap — it also sees `f()`, the caller's own code (#268).
    if pool isa PormGPostgres
        begin_task = backend_execute_async(pool, conn, "BEGIN;", nothing)
        _await_tx_statement(pool, begin_task)
    else
        # Use BEGIN IMMEDIATE for SQLite to prevent deadlocks and ensure
        # write lock is acquired early for multi-threaded scenarios.
      begin_task = sqlite_execute_async(pool, conn, "BEGIN IMMEDIATE TRANSACTION;", nothing)
      _await_tx_statement(pool, begin_task)
      # The transaction is open from here on, so mark it BEFORE anything else can throw — otherwise
      # a failure below skips the ROLLBACK in the catch and releases a connection with an open
      # transaction back to the pool, which the acquire liveness probe cannot detect (#71).
      tx_started = true
      # #276: match PostgreSQL's timing, not just its strictness. `Dialect.add_foreign_key` creates
      # every PG foreign key DEFERRABLE INITIALLY DEFERRED, so PG checks at COMMIT and a transaction
      # may be transiently inconsistent — insert a child, then its parent, and it commits. SQLite's
      # `foreign_keys` pragma checks per statement, so turning it on alone would make that same
      # block raise on SQLite only: a NEW divergence, in the direction #276 exists to remove.
      # `defer_foreign_keys` is per-transaction and resets itself at COMMIT and ROLLBACK, so it
      # needs no renewal — unlike `foreign_keys`, which is why migrations suspend rather than defer.
      task = sqlite_execute_async(pool, conn, "PRAGMA defer_foreign_keys = ON;", nothing)
      _await_tx_statement(pool, task)
    end
    tx_started = true

    # Execute the function within transaction context
    result = with_tx_context(pool, conn) do
      f()
    end

    # Commit on success
    if pool isa PormGPostgres
        task = backend_execute_async(pool, conn, "COMMIT;", nothing)
        _await_tx_statement(pool, task)
    else
      task = sqlite_execute_async(pool, conn, "COMMIT;", nothing)
      _await_tx_statement(pool, task)
    end

    return result
  catch e
    root = _unwrap_async_exception(e)
    # Was the BEGIN await ABANDONED by a cancellation rather than refused by the database (#322)?
    # That is the one window this function does not otherwise cover: `tx_started` is still `false`,
    # so no ROLLBACK is issued below, and the terminal `finalize_transaction_connection!` would take
    # its plain-release branch and hand back a connection the driver has not let go of — #315 exactly.
    #
    # `!tx_started` is what scopes this to the BEGIN, and it is exact: on BOTH backends it is `false`
    # only while the BEGIN await is in flight (SQLite sets it immediately after `BEGIN IMMEDIATE`,
    # before the PRAGMA). So an `InterruptException` raised by the caller's own `f()` — which
    # `_await_abandoned` also answers `true` for — cannot reach this branch. It must not: an
    # interrupt between statements leaves a CLEAN connection with an OPEN transaction, where skipping
    # the ROLLBACK would be the bug rather than the fix.
    #
    # The third case — an interrupt landing while a query is IN FLIGHT inside `f()` — reaches neither
    # branch, and deliberately so. `await_result`'s release is gated on `!ft.in_transaction`, so an
    # abandoned in-transaction await does nothing to the connection; the ROLLBACK below is then
    # issued on that same connection and SERIALIZES behind the abandoned query (LibPQ's
    # per-connection semaphore; SQLite's single worker). Measured against a live PostgreSQL: the
    # connection comes back IDLE and the slot is reusable — the ROLLBACK really does run once it gets
    # the connection — but control returns only after the cancelled query's remaining runtime. So for
    # ONE interrupt the cost is responsiveness, not a poisoned slot, which is why #322 leaves it
    # alone: routing it here would trade a slow Ctrl-C for a reconnect on a connection that was going
    # to be fine.
    #
    # A SECOND interrupt landing on that blocked ROLLBACK is a different matter, and a genuine
    # pre-existing bug rather than a scope decision: it becomes `rollback_error`, which is not benign,
    # so the terminal `finalize_transaction_connection!` renews — and `_renew_or_discard_connection!`
    # closes the old handle SYNCHRONOUSLY. On SQLite `reconnect_db` always produces a fresh handle, so
    # that close always fires, on a handle the worker is still inside, and the queued ROLLBACK then
    # runs against it. Reproduced on a mock at two timings (#322 review). The remedy already exists in
    # this file — `_settle_probe` + `_discard_connection!(…; close_handle = false)` — but it belongs
    # to the #71 renewal path, not to this one. Tracked separately.
    if !tx_started && begin_task !== nothing && _await_abandoned(e)
      abandoned_begin = true
    end
    # Rollback on error if transaction actually started
    if tx_started
      try
        if pool isa PormGPostgres
            task = backend_execute_async(pool, conn, "ROLLBACK;", nothing)
            _await_tx_statement(pool, task)
        else
          task = sqlite_execute_async(pool, conn, "ROLLBACK;", nothing)
          _await_tx_statement(pool, task)
        end
      catch rb
        # Capture the rollback error so the finally can decide release-vs-renew (a benign
        # SQLite "no transaction is active" is clean → released; anything else may leave the
        # connection with an open/aborted transaction → renewed or discarded, #71).
        rollback_error = rb
        # This re-classifies the error that `finalize_transaction_connection!` also classifies in
        # the finally — intentional, not a leftover: the "will be renewed" log must fire here in the
        # catch, while the actual release/renew decision lives in the terminal finally. The cost is
        # one extra cheap string check on the (rare) rollback-failure path. Alternatives (a bool
        # passed to the helper, or logging inside it) either force `_is_benign_rollback_error` into
        # the migration/delete submodules or perturb the log the #71 tests assert — both worse.
        if !_is_benign_rollback_error(pool, rb)
          @error "Failed to rollback transaction; connection will be renewed before returning to the pool" exception=_unwrap_async_exception(rb)
        end
      end
    end
    root === e ? rethrow() : throw(root)
  finally
    if abandoned_begin
      # The driver may still be inside BEGIN on this connection, so nothing here may touch it: the
      # recovery cancels, waits for the driver to let go, and only then renews — all on a DETACHED
      # task, so Ctrl-C returns to the REPL now (#322). `force_renew` because a BEGIN that DID land
      # before the interrupt leaves an open transaction that draining cannot see, and releasing that
      # is #71 in a new place.
      _recover_abandoned_connection!(pool, conn, begin_task; force_renew = true)
    else
      # Single terminal release/renew, shared with the migration/delete lifecycles (#139).
      # Never releases a dirty handle; never throws (the original error keeps propagating).
      finalize_transaction_connection!(pool, conn; rollback_error = rollback_error)
    end
  end
end

function run_in_transaction(f::Function, db::String)
  settings::PormGSettings = get_settings(db)
  return run_in_transaction(f, settings.connections)
end

run_in_transaction(f::Function, settings::PormGSettings) = run_in_transaction(f, settings.connections)

"""
    atomic(f::Function, db; durable::Bool=false) -> result

Run `f()` in a database transaction — the friendly, Django-flavored alias for
[`run_in_transaction`](@ref). `db` may be a pool, a db-key `String` (e.g. `"db_2"`), or a
`PormGSettings`.

A **nested** `atomic`/`run_in_transaction` block on the *same* database automatically becomes
a `SAVEPOINT`: if `f()` throws, only that inner block is rolled back to its savepoint and the
error propagates, leaving the outer transaction intact (catch it outside the inner block to
continue). Works identically on PostgreSQL and SQLite (#26).

```julia
atomic("db_2") do
  driver = M.Driver.objects.create("forename" => "Alice", "surname" => "Lane", ...)
  try
    atomic("db_2") do                 # nested → SAVEPOINT
      M.Result.objects.create(...)    # rolled back to the savepoint on error…
      error("validation failed")
    end
  catch
    # …outer transaction still usable here
  end
end
```

Pass `durable=true` to require this block be the outermost transaction — it throws if a
transaction is already active (mirrors Django's `atomic(durable=True)`).
"""
function atomic(f::Function, pool::Union{PormGPostgres, PormGSQLite}; durable::Bool=false)
  if durable && in_transaction_context()
    # TransactionError, not QueryBuildError: nothing is wrong with the query shape — the
    # transaction API was called in a way that cannot work. Its sibling check,
    # `Configuration.ensure_model_transaction_scope`, reports the same class and used to say
    # InvalidConfigurationError; #268 gave both one honest home.
    throw(TransactionError("atomic(durable=true) must be the outermost transaction, but a transaction is already active"))
  end
  return run_in_transaction(f, pool)
end
atomic(f::Function, db::String; durable::Bool=false) = atomic(f, get_settings(db).connections; durable=durable)
atomic(f::Function, settings::PormGSettings; durable::Bool=false) = atomic(f, settings.connections; durable=durable)

end # module
