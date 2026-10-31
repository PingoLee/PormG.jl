module AdvisoryLock

using Logging

import PormG
import PormG: PormGSettings, PormGPostgres, PormGSQLite, PormGMySQL, backend_execute_async
import PormG: _backend_name  # #1129: the engine's name in the contention error
import PormG.Configuration: get_settings
import PormG.ConnectionPool: acquire_connection, release_connection
# This module is the only one outside ConnectionPool that talks to the driver directly, so no
# `fetch`/`with_transaction` seam covers it — it has to funnel its own failures through the
# database-error boundary (#268) or `with_advisory_lock` would be the last public entry point
# still leaking raw `LibPQ.Errors.*`.
import PormG.ConnectionPool: _as_database_error
import PormG.ConnectionPool: NUL_REFUSAL_REASON
# Same reason, one defect class further on (#322): this module awaits driver handles directly, so a
# Ctrl-C leaves it holding a connection the driver has not let go of — and unlike a plain query, a
# session-level advisory lock is still held on it. Renewal is what releases that lock.
import PormG.ConnectionPool: _await_abandoned, _recover_abandoned_connection!, _fetch_interruptible
import PormG: PormGError, DatabaseError, OperationalError, BackendCapabilityError, InvalidValueError
import PormG: _capability_error  # #1129: the backend capability table (Kernel)

import PormG: @pormg_debug
export with_advisory_lock


const ADVISORY_KEY_EXPR = "(( 'x' || substr(md5(\$1), 1, 16))::bit(64))::bigint"
const TRY_SQL = "SELECT pg_try_advisory_lock($(ADVISORY_KEY_EXPR)) AS ok"
# Workaround for pg_advisory_lock returning void: select true from the void function call
const BLOCK_SQL = "SELECT true AS ok FROM (SELECT pg_advisory_lock($(ADVISORY_KEY_EXPR))) AS _"
const UNLOCK_SQL = "SELECT pg_advisory_unlock($(ADVISORY_KEY_EXPR)) AS ok"

# Who holds the lock on `$1`, for the error raised when it cannot be acquired (#737). `pg_locks` shows
# a `bigint` advisory key split in two — the high 32 bits in `classid`, the low 32 in `objid`, with
# `objsubid = 1` — so the key is hashed by the SAME expression the lock queries use and split the
# same way. Scoped to the current database, as the lock itself is (see `MIGRATION_LOCK_KEY`).
# `LEFT JOIN`: `pg_stat_activity` may hide another role's row detail, and the pid alone still names
# the process.
const HOLDER_SQL = """
  SELECT l.pid, a.application_name
  FROM pg_locks l
  LEFT JOIN pg_stat_activity a ON a.pid = l.pid
  CROSS JOIN (SELECT $(ADVISORY_KEY_EXPR) AS k) lk
  WHERE l.locktype = 'advisory' AND l.granted AND l.objsubid = 1
    AND l.database = (SELECT oid FROM pg_database WHERE datname = current_database())
    AND l.classid::bigint = ((lk.k >> 32) & 4294967295)
    AND l.objid::bigint = (lk.k & 4294967295)
  ORDER BY l.pid"""

# MySQL (#1130, #1269): `GET_LOCK` is a session-level named lock, released by `RELEASE_LOCK` or when the
# session ends — the shape of `pg_advisory_lock`, so the lifecycle below serves both. A name is at most
# 64 characters, so the key is hashed, as PostgreSQL's is hashed to a bigint: `pormg:` plus the 32-digit
# MD5. A MySQL lock name is SERVER-wide, where a PostgreSQL advisory lock is scoped to its database, so
# the database (`DATABASE()`) is hashed in with the key: two databases on one server do not exclude
# each other, as on PostgreSQL. `GET_LOCK` answers 1 (taken), 0 (timed out) or NULL (an error, such as
# the session being killed); only 1 is a lock.
const MYSQL_LOCK_NAME_EXPR = "CONCAT('pormg:', MD5(CONCAT(COALESCE(DATABASE(), ''), ':', ?)))"
const MYSQL_TRY_SQL = "SELECT GET_LOCK($(MYSQL_LOCK_NAME_EXPR), 0) AS ok"
const MYSQL_BLOCK_SQL = "SELECT GET_LOCK($(MYSQL_LOCK_NAME_EXPR), ?) AS ok"
const MYSQL_UNLOCK_SQL = "SELECT RELEASE_LOCK($(MYSQL_LOCK_NAME_EXPR)) AS ok"
# The holder's connection id, which `SHOW PROCESSLIST` and `KILL` take. No other detail is read: the
# process list shows another user's threads only to an account with the `PROCESS` privilege.
const MYSQL_HOLDER_SQL = "SELECT IS_USED_LOCK($(MYSQL_LOCK_NAME_EXPR)) AS id"

# The statements each engine locks with, by dispatch (#1129 item 2: no engine branch).
_try_lock_sql(::PormGPostgres) = TRY_SQL
_try_lock_sql(::PormGMySQL) = MYSQL_TRY_SQL
_unlock_sql(::PormGPostgres) = UNLOCK_SQL
_unlock_sql(::PormGMySQL) = MYSQL_UNLOCK_SQL

# A lock query's answer. PostgreSQL returns a boolean, MySQL the integer 1 — or NULL, which is no lock.
_lock_ok(v) = v === true || (v isa Integer && !(v isa Bool) && v == 1)

# Ceiling on how many distinct lock keys the SQLite no-op warning tracks (#277). Declared up here,
# ahead of the docstring below that interpolates it — a docstring is a plain string literal
# evaluated in file order, so a const defined further down would be an UndefVarError at load.
const SQLITE_LOCK_WARN_CAP = 64

"""
Records whether any await in one `with_advisory_lock` call was ABANDONED by a cancellation, and the
driver handle it was parked on (#322).

Mutable and threaded through the whole call rather than recomputed in the `finally`, because
"was this an abandoned await?" and "did an `InterruptException` reach the `finally`?" are different
questions with different right answers. A `Ctrl+C` inside the caller's `f()` interrupts a body that
was NOT touching this connection — it is clean, still holds the lock, and must take the ordinary
unlock-then-release path. Only an await recorded here means the driver is still on the connection.
"""
mutable struct _LockAwaitState
  abandoned::Bool
  handle::Any
end
_LockAwaitState() = _LockAwaitState(false, nothing)

# Await one lock-lifecycle driver handle, recording it (and any abandonment) on `state` first.
#
# `_fetch_interruptible`, not a bare `Base.fetch`: a Ctrl-C during a lock wait must reach this task
# while the statement runs (#1512).
function _await_lock_handle(pool::Union{PormGPostgres, PormGMySQL}, state::_LockAwaitState, handle)
  # Recorded BEFORE the await: the settle probe needs the handle precisely in the case where the
  # await never returns normally.
  state.handle = handle
  err = try
    return _fetch_interruptible(handle)
  catch e
    _await_abandoned(e) && (state.abandoned = true)
    _as_database_error(pool, e)
  end
  throw(err)   # Thrown after the `catch`, never inside it (#987) — see `ConnectionPool._as_database_error`.
end

# " — held by pid 4711 (app-worker-1)", or "" when the holder cannot be read (#737). Best-effort: the
# caller is already raising, and a failed diagnostic must not replace the real error. The one
# failure that is NOT swallowed is a cancellation — an abandoned await leaves the driver on `conn`,
# and the `finally` in `with_advisory_lock` has to see that to renew it (#322).
function _lock_holder_text(pool::PormGMySQL, conn, key::AbstractString, state::_LockAwaitState)::String
  rows = try
    collect(_await_lock_handle(pool, state, backend_execute_async(pool, conn, MYSQL_HOLDER_SQL, Any[key])))
  catch
    state.abandoned && rethrow()
    return ""
  end
  (isempty(rows) || rows[1][1] === missing || rows[1][1] === nothing) && return ""
  return " — held by connection $(rows[1][1])"
end

function _lock_holder_text(pool::PormGPostgres, conn, key::AbstractString, state::_LockAwaitState)::String
  rows = try
    collect(_await_lock_handle(pool, state, backend_execute_async(pool, conn, HOLDER_SQL, Any[key])))
  catch
    state.abandoned && rethrow()
    return ""
  end
  isempty(rows) && return ""
  holders = String[]
  for r in rows
    app = r[2]
    push!(holders, (app === nothing || ismissing(app) || isempty(String(app))) ?
                     "pid $(r[1])" : "pid $(r[1]) ($(app))")
  end
  return " — held by " * join(holders, ", ")
end

"""
Execute a lock/unlock query on a held connection and return boolean result.
"""
function _exec_lock_query(pool::Union{PormGPostgres, PormGMySQL}, conn, sql::String, key::AbstractString,
                          state::_LockAwaitState; params = Any[key])::Bool
  # backend_execute_async yields to the scheduler, allowing other Tasks to run.
  # It runs on the held connection without releasing it back to the pool, so the
  # session-level lock stays bound to this connection.
  async_res = backend_execute_async(pool, conn, sql, params)

  res = _await_lock_handle(pool, state, async_res)

  rows = collect(res)
  return !isempty(rows) && _lock_ok(rows[1][1])
end

# `strategy = :block`: wait on the server, bounded by `timeout_ms`. Returns whether the lock was taken.
# What the PostgreSQL arm must restore afterwards goes into `saved` as soon as it is read, so the caller's
# `finally` restores it even when the wait itself throws.
#
# PostgreSQL bounds the wait with `lock_timeout` (#1024). It limits only the time spent waiting for a
# lock, which is exactly what `:block` means, so a `statement_timeout` the caller set on the session
# keeps applying to the statement as a whole instead of being overwritten.
function _block_lock!(pool::PormGPostgres, conn, key::AbstractString, timeout_ms::Int, state::_LockAwaitState,
                     saved::Base.RefValue{Any})
  try
    prev = _await_lock_handle(pool, state, backend_execute_async(pool, conn, "SHOW lock_timeout", nothing))
    rows = collect(prev)
    !isempty(rows) && (saved[] = rows[1][1])
  catch
    # Best-effort probe: a failure here only costs us the restore value. An ABANDONED await is
    # NOT that — the connection is poisoned from here on and the `SET` below would be issued on
    # it, so let the cancellation out to the finally instead of swallowing it (#322).
    state.abandoned && rethrow()
    saved[] = nothing
  end

  # Await commands without returned rows through the same seam, so a cancellation here is
  # recorded too — this one runs BEFORE `got_lock`, i.e. on a connection the finally would
  # otherwise release straight back into the pool with no unlock attempted at all.
  _await_lock_handle(pool, state, backend_execute_async(pool, conn, "SET lock_timeout = $(timeout_ms)", nothing))

  got_lock = try
    _exec_lock_query(pool, conn, BLOCK_SQL, key, state)
  catch e
    # The timeout is recognized by SQLSTATE, never by the message (#1010): PostgreSQL localizes
    # its text by `lc_messages`, so on a `pt_BR` server a text match never fires and the raw
    # error replaces the lock-holder one (#737).
    #
    # `55P03` (`lock_not_available`) is the server SAYING the lock wait timed out, so it needs no
    # guard (#1024). Under `statement_timeout` the same wait raised `57014`, which every cancel
    # shares — an external `pg_cancel_backend`, PormG's own abandoned-await cancel (#315) — so
    # the timeout had to be deduced from the clock. Now a `57014` is a cancel, or a session
    # `statement_timeout` shorter than `timeout_ms` that ended the wait first; either way it is
    # not ours, and propagates as it is. `timeout_ms = 0` disables `lock_timeout`, so no `55P03`
    # arrives there.
    timed_out = e isa DatabaseError && e.sqlstate == "55P03"
    timed_out || throw(e)
    @warn "Advisory lock timed out on server-side lock_timeout" key=key timeout_ms=timeout_ms
    false
  end
  return got_lock
end

# MySQL bounds the wait in the call itself: `GET_LOCK(name, seconds)` answers 0 when it runs out, so
# nothing is set on the session and nothing needs restoring. The server rounds a fractional timeout
# to the NEAREST second (measured on 8.4: 0.3 does not wait at all, 1.5 waits 2), so the milliseconds
# are rounded UP to whole seconds here: the wait is never shorter than asked, and at most a second
# longer. `timeout_ms = 0` waits with no bound (a negative timeout), as `lock_timeout = 0` does on
# PostgreSQL.
function _block_lock!(pool::PormGMySQL, conn, key::AbstractString, timeout_ms::Int, state::_LockAwaitState,
                     saved::Base.RefValue{Any})
  seconds = timeout_ms == 0 ? -1 : cld(timeout_ms, 1_000)
  got_lock = _exec_lock_query(pool, conn, MYSQL_BLOCK_SQL, key, state; params = Any[key, seconds])
  got_lock || @warn "Advisory lock timed out on the server-side GET_LOCK timeout" key=key timeout_ms=timeout_ms
  return got_lock
end

# Undo what `_block_lock!` set on the session. Best-effort: restoring a timeout cannot fail the call.
#
# Awaited through `_await_lock_handle`, NOT a bare `wait`, for two reasons, one historical and one
# current. Inside `with_advisory_lock` the `wait::Bool` KEYWORD shadows `Base.wait`, so `wait(...)`
# evaluated as `false(...)` and raised `MethodError: objects of type Bool are not callable`; the empty
# `catch` blocks swallowed it, so this restore had never once completed (found while working #277). And
# the seam is also what records a cancellation here, which the caller's terminal branch reads. The
# empty `catch`es stay — restoring a timeout is genuinely best-effort — but neither a MethodError nor a
# swallowed Ctrl-C is one of the things they hide any more.
function _restore_block_timeout!(pool::PormGPostgres, conn, old_timeout, strategy::Symbol, state::_LockAwaitState)
  if old_timeout !== nothing
    try
      _await_lock_handle(pool, state, backend_execute_async(pool, conn, "SET lock_timeout = '$(old_timeout)'", nothing))
    catch
    end
  elseif strategy == :block
    try
      _await_lock_handle(pool, state, backend_execute_async(pool, conn, "SET lock_timeout TO DEFAULT", nothing))
    catch
    end
  end
  return nothing
end
_restore_block_timeout!(::PormGMySQL, conn, old_timeout, strategy::Symbol, state::_LockAwaitState) = nothing

"""
    with_advisory_lock(f::Function, pool::PormGPostgres, key::AbstractString; wait::Bool=false, timeout_ms::Int=5_000, interval_ms::Int=100, strategy::Symbol=:poll, on_missing_lock::Symbol=:warn)
    with_advisory_lock(f::Function, pool::PormGMySQL, key::AbstractString; ...)

Execute a function `f` while holding a session-level advisory lock identified by `key`: a PostgreSQL
advisory lock, or a MySQL `GET_LOCK` named lock.

Advisory locks are an application-level locking mechanism provided by the database. They are useful for ensuring exclusivity for tasks that don't map directly to a database row, such as synchronizing external API calls or preventing concurrent expensive calculations.

# Arguments
- `f::Function`: The function to execute while holding the lock.
- `pool`: The PostgreSQL or MySQL connection pool.
- `key::AbstractString`: A unique string identifying the lock. It is hashed: to a 64-bit integer on
  PostgreSQL, to a 38-character lock name (`pormg:` and an MD5) on MySQL. Either way the lock is
  scoped to the database: on MySQL, whose lock names are server-wide, the database name is hashed in
  with the key.

# Keywords
- `wait::Bool=false`: If `true`, the function will wait until the lock becomes available or the timeout is reached. If `false`, it throws an error immediately if the lock is already held.
- `timeout_ms::Int=5_000`: Maximum time to wait for the lock (in milliseconds).
- `strategy::Symbol=:poll`: The waiting strategy:
    - `:poll`: (Default) Periodically retries lock acquisition from the Julia client. Safe and recommended for most cases.
    - `:block`: Uses the server's blocking wait. Efficient but holds a connection while it waits. On PostgreSQL the wait is bounded by `lock_timeout`, set for the acquisition and restored when the call returns; a `statement_timeout` you set on the session is left alone, so if it is shorter than `timeout_ms` it ends the wait first, as a query-canceled `OperationalError` (SQLSTATE `57014`). On MySQL the wait is `GET_LOCK`'s own timeout, which takes whole seconds: `timeout_ms` is rounded up to the next second, and nothing is set on the session. On both, `timeout_ms = 0` waits with no bound.
- `interval_ms::Int=100`: Retry interval for the `:poll` strategy.
- `on_missing_lock::Symbol=:warn`: What to do on a backend that cannot lock. Ignored on
  PostgreSQL and MySQL, which always take a real lock — it exists for the SQLite path (see below).
  An unrecognised value raises `InvalidValueError` on **every** backend, so a typo cannot lie in
  wait until you run on SQLite.

# SQLite

SQLite has no advisory locks, so `with_advisory_lock` **runs the body with no mutual exclusion**.
That is deliberate: it lets the same source run against PostgreSQL in production and SQLite in
tests, exactly as [`select_for_update`](@ref) does. Unlike `select_for_update`, though, what
degrades here is a *guarantee* rather than a query that still returns correct rows — so the SQLite
path is not silent. `on_missing_lock` selects what happens (#277):

| `on_missing_lock` | On SQLite |
| :--- | :--- |
| `:warn` (default) | Body runs; warns once per key |
| `:ignore` | Body runs silently — you have accepted the no-op |
| `:error` | Throws `BackendCapabilityError`; the body does **not** run |

The other keywords (`wait`, `timeout_ms`, `strategy`, `interval_ms`) are accepted and ignored on
SQLite, and the contention path cannot fire there, so `OperationalError` is never raised.

The warning is emitted once per distinct key, tracked in-process, for up to
`$(SQLITE_LOCK_WARN_CAP)` keys — the message says so when that cap is reached, rather than going
quiet without saying.

# Cancelling with `Ctrl+C`

Interrupting a lock or unlock query does **not** leak the lock. The connection it ran on is renewed
rather than returned to the pool, and an advisory lock is bound to the session — so reconnecting
releases it. That happens on a background task, so the interrupt reaches you
immediately; the pool slot stays checked out until the connection is safe to replace. Interrupting
the *body* `f` is unaffected: the connection is clean there, so the lock is released normally.

# Examples
```julia
# Lock around a critical update for a specific constructor
PormG.with_advisory_lock(M.Constructor.objects.object.model.connect_key, "update_constructor_1") do
    # This block is protected by the lock "update_constructor_1"
    # Perform complex logic here...
    @info "Exclusive access granted"
end
```
"""
function with_advisory_lock(f::Function, pool::Union{PormGPostgres, PormGMySQL}, key::AbstractString;
                            wait::Bool = false,
                            timeout_ms::Int = 5_000,
                            interval_ms::Int = 100,
                            strategy::Symbol = :poll,
                            # Accepted and ignored: PostgreSQL and MySQL always take a real lock, so there is
                            # no "missing lock" case to have a policy about. It exists so the same
                            # call site can carry `on_missing_lock` and still run on both backends —
                            # on SQLite it is what turns the no-op into a warning or an error
                            # (#277). Without it here, `on_missing_lock = :error` would be a
                            # MethodError on the one backend that satisfies it. Still validated, so
                            # a typo fails on PostgreSQL too rather than lying in wait for SQLite.
                            on_missing_lock::Symbol = :warn)
  _validate_on_missing_lock(on_missing_lock)
  _refuse_nul_key(key)
  conn = acquire_connection(pool)
  got_lock = false
  old_timeout = Ref{Any}(nothing)   # PostgreSQL's `lock_timeout` before a `:block` acquisition set it
  # Every driver await below funnels through `_await_lock_handle`, which records here whether one of
  # them was cut short by a cancellation — the `finally` reads it to decide the connection's fate.
  await_state = _LockAwaitState()

  try
    # Attempt to acquire lock
    if !wait
      # Non-blocking: single try
      got_lock = _exec_lock_query(pool, conn, _try_lock_sql(pool), key, await_state)
    elseif strategy == :block
      got_lock = _block_lock!(pool, conn, key, timeout_ms, await_state, old_timeout)
    else # :poll
      # Client-side polling with retry
      deadline = time() * 1_000 + timeout_ms
      while true
        got_lock = _exec_lock_query(pool, conn, _try_lock_sql(pool), key, await_state)
        got_lock && break
        (time() * 1_000) >= deadline && break
        sleep(interval_ms / 1_000)
      end
    end
    
    if !got_lock
      # OperationalError, not ErrorException (#268): losing a race for a lock is a transient
      # runtime condition — the caller may reasonably back off and retry — not misuse of PormG,
      # and it must be reachable via `catch PormGError` like every other runtime failure. The
      # `cause` is a plain String because no driver raised anything: the lock query succeeded and
      # answered "no". `PoolConnectError` sets the precedent for a non-Exception cause.
      #
      # The message names who holds the lock (#737): "instance 2 could not migrate" is not
      # actionable, "it waited 30 s on pid 4711 (app-worker-1)" is.
      waited = wait ? " within $(timeout_ms) ms" : ""
      throw(OperationalError(_backend_name(pool),
        "Failed to acquire advisory lock for '$key'$(waited)$(_lock_holder_text(pool, conn, key, await_state))"))
    end
    
    # Execute user function while holding lock
    return f()

  finally
    # An ABANDONED await takes the rest of this cleanup off the table (#322). The driver is still on
    # `conn`, so every statement below would be issued on a poisoned connection — and the UNLOCK is
    # the one that matters: it fails, the `@warn` says so, and the connection then goes back into the
    # pool STILL HOLDING a session-level `pg_advisory_lock` that nothing will ever release.
    #
    # `await_state.abandoned` is re-read before each step rather than latched once, so a SECOND
    # Ctrl-C — landing on the unlock or the restore — stops the remaining ones the same way.

    # Release lock if acquired (on same connection)
    if got_lock && !await_state.abandoned
      try
        _exec_lock_query(pool, conn, _unlock_sql(pool), key, await_state)
      catch e
        @warn "Failed to release advisory lock; connection may have been dropped" key=key exception=(e, catch_backtrace())
      end
    end

    # Restore what a `:block` acquisition set on the session (PostgreSQL's `lock_timeout`).
    await_state.abandoned || _restore_block_timeout!(pool, conn, old_timeout[], strategy, await_state)

    # Terminal: the connection goes back exactly one way.
    #
    # An `if/else`, NOT an early `return` in the abandoned branch: a `return` inside a `finally`
    # DISCARDS the exception that is propagating, so the Ctrl-C would be swallowed and this would
    # hand the caller a silent `nothing`.
    #
    # Renewal is the remedy rather than a fallback: an advisory lock is bound to the SESSION, so
    # reconnecting the slot is what drops it. `force_renew` makes that unconditional — a connection
    # that drains clean still holds the lock, so wire-cleanliness is not the question here.
    if await_state.abandoned
      # Worded on `got_lock`: the cancellation may have landed on the very first lock query, or on
      # the `SET lock_timeout` before it, in which case no lock was ever taken and claiming to
      # release one would be a lie in the log.
      @warn(got_lock ?
              "Advisory-lock query was cancelled; renewing the connection so the session lock is released" :
              "Advisory-lock query was cancelled before the lock was taken; renewing the connection",
            key = key)
      _recover_abandoned_connection!(pool, conn, await_state.handle; force_renew = true)
    else
      release_connection(pool, conn)
    end
  end
end

# Convenience wrappers for Settings/PormGSettings objects
with_advisory_lock(f::Function, settings::PormGSettings, key::AbstractString; kwargs...) =
  with_advisory_lock(f, settings.connections, key; kwargs...)

# ==============================================================================
# SQLite: no advisory locks exist, so the body runs UNPROTECTED (#277)
# ==============================================================================
#
# Staying a no-op rather than throwing is what lets one source target PostgreSQL in production and
# SQLite in tests, exactly as `select_for_update` does. But this degrades a mutual-exclusion
# GUARANTEE, not a query that still returns correct rows, and the failure mode is a race visible
# only under concurrency — the hardest class to notice in testing. So the caller chooses, by value:
#
#   :warn   (default) → run the body, warn once per key
#   :ignore           → run the body silently; the caller has read the docs and accepted the no-op
#   :error            → throw, rather than hand back a guarantee this backend cannot provide
#
# Dedup is an explicit Set rather than `@warn ... maxlog=1`. Two reasons, both found in review:
#   1. `maxlog` is honoured only by loggers that implement it (SimpleLogger/ConsoleLogger/
#      TestLogger). Under a custom application sink — common in Genie apps and LoggingExtras
#      stacks — it degrades to warning on EVERY call, which is the log flood the dedup exists to
#      prevent, for callers who never opted in.
#   2. `_id=Symbol(..., key)` interns a Symbol per key, and Julia never frees Symbols. The docs
#      teach `"driver_update_$(driver_id)"`, i.e. unbounded key cardinality, so that is a genuine
#      slow leak (~4.5 MiB retained at 50k keys, measured).
#
# The Set is plain DATA in a module body, which is safe under cached precompilation — the #203 trap
# is about side EFFECTS (atexit, hook registration), not container state. Same shape as
# ConnectionPool's `leak_warned` monitor.
const _SQLITE_LOCK_WARNED = Set{String}()
const _SQLITE_LOCK_WARNED_LOCK = ReentrantLock()
# The set is bounded by SQLITE_LOCK_WARN_CAP (declared at the top of this file) so a caller minting
# a key per entity cannot grow it without limit. Reaching the cap is announced, not swallowed.

# Test seam: the ledger is process-wide, so a suite asserting warn-once needs a way to re-arm.
# Directly callable for the same reason `ConnectionPool._leak_check!` is.
_reset_sqlite_lock_warnings!() = Base.@lock _SQLITE_LOCK_WARNED_LOCK empty!(_SQLITE_LOCK_WARNED)

# :warn → warn now; :final → warn now AND say we are going quiet; :silent → already covered.
function _claim_sqlite_lock_warning(key::AbstractString)::Symbol
  Base.@lock _SQLITE_LOCK_WARNED_LOCK begin
    key in _SQLITE_LOCK_WARNED && return :silent
    length(_SQLITE_LOCK_WARNED) >= SQLITE_LOCK_WARN_CAP && return :silent
    push!(_SQLITE_LOCK_WARNED, key)
    return length(_SQLITE_LOCK_WARNED) == SQLITE_LOCK_WARN_CAP ? :final : :warn
  end
end

# #951 — the key is bound straight to `backend_execute_async`, past every funnel `_refuse_nul` sits
# in, and under LibPQ a NUL would cut it short silently: "job\0a" and "job\0b" would both take the
# lock on "job", so two bodies written to run independently would exclude each other. Before the
# acquire, so a refusal leases nothing.
function _refuse_nul_key(key::AbstractString)
  '\0' in key && throw(InvalidValueError(
    "with_advisory_lock: the key contains a NUL character (\\0). " * NUL_REFUSAL_REASON, :nul))
  return nothing
end

function _validate_on_missing_lock(on_missing_lock::Symbol)
  on_missing_lock in (:warn, :ignore, :error) && return nothing
  throw(InvalidValueError(  # refusal-value-ok: a keyword argument the developer passed, not a bound value
    "Invalid on_missing_lock: $(repr(on_missing_lock)). Expected :warn (default), :ignore or :error."))
end

# `kwargs...` still swallows wait/timeout_ms/strategy/interval_ms so the PostgreSQL call shape stays
# portable — that tolerance is the whole point of the no-op.
function with_advisory_lock(f::Function, conn::PormGSQLite, key::AbstractString;
                            on_missing_lock::Symbol = :warn, kwargs...)
  _validate_on_missing_lock(on_missing_lock)
  _refuse_nul_key(key)   # SQLite never sends the key; refused anyway so a call site behaves alike

  if on_missing_lock === :error
    throw(_capability_error(conn, :advisory_locks, "with_advisory_lock(on_missing_lock = :error) for '$key'";
      why = "The body would run with no mutual exclusion; pass on_missing_lock = :ignore to accept the no-op."))
  end

  if on_missing_lock === :warn
    outcome = _claim_sqlite_lock_warning(key)
    if outcome !== :silent
      tail = outcome === :final ?
        " Reached $(SQLITE_LOCK_WARN_CAP) distinct keys; further advisory-lock warnings are suppressed." : ""
      @warn "Advisory locks are a no-op on SQLite: this body runs with NO mutual exclusion. Pass " *
            "on_missing_lock=:ignore to accept that silently, or :error to refuse it." * tail key=key
    end
  end

  return f()
end

# Wrapper to use by database name string
function with_advisory_lock(f::Function, db::String, key::AbstractString; kwargs...)
  @pormg_debug false
  settings = get_settings(db)
  return with_advisory_lock(f, settings, key; kwargs...)
end

end # module