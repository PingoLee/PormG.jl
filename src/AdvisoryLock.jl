module AdvisoryLock

using Logging

import PormG
import PormG: PormGSettings, PormGPostgres, PormGSQLite, backend_execute_async
import PormG.Configuration: get_settings
import PormG.ConnectionPool: acquire_connection, release_connection
# This module is the only one outside ConnectionPool that talks to the driver directly, so no
# `fetch`/`with_transaction` seam covers it — it has to funnel its own failures through the
# database-error boundary (#268) or `with_advisory_lock` would be the last public entry point
# still leaking raw `LibPQ.Errors.*`.
import PormG.ConnectionPool: _as_database_error
# Same reason, one defect class further on (#322): this module awaits driver handles directly, so a
# Ctrl-C leaves it holding a connection the driver has not let go of — and unlike a plain query, a
# session-level advisory lock is still held on it. Renewal is what releases that lock.
import PormG.ConnectionPool: _await_abandoned, _recover_abandoned_connection!
import PormG: PormGError, OperationalError, BackendCapabilityError, InvalidValueError

import PormG: @pormg_debug
export with_advisory_lock


const ADVISORY_KEY_EXPR = "(( 'x' || substr(md5(\$1), 1, 16))::bit(64))::bigint"
const TRY_SQL = "SELECT pg_try_advisory_lock($(ADVISORY_KEY_EXPR)) AS ok"
# Workaround for pg_advisory_lock returning void: select true from the void function call
const BLOCK_SQL = "SELECT true AS ok FROM (SELECT pg_advisory_lock($(ADVISORY_KEY_EXPR))) AS _"
const UNLOCK_SQL = "SELECT pg_advisory_unlock($(ADVISORY_KEY_EXPR)) AS ok"

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
# `Base.fetch` qualified deliberately: this module imports no `fetch`, so a bare call would resolve
# to Base only by absence — qualifying keeps it immune to import shadowing.
function _await_lock_handle(pool::PormGPostgres, state::_LockAwaitState, handle)
  # Recorded BEFORE the await: the settle probe needs the handle precisely in the case where the
  # await never returns normally.
  state.handle = handle
  try
    return Base.fetch(handle)
  catch e
    _await_abandoned(e) && (state.abandoned = true)
    throw(_as_database_error(pool, e))
  end
end

"""
Execute a lock/unlock query on a held connection and return boolean result.
"""
function _exec_lock_query(pool::PormGPostgres, conn, sql::String, key::AbstractString,
                          state::_LockAwaitState)::Bool
  # backend_execute_async yields to the scheduler, allowing other Tasks to run.
  # It runs on the held connection without releasing it back to the pool, so the
  # session-level lock stays bound to this connection.
  async_res = backend_execute_async(pool, conn, sql, Any[key])

  res = _await_lock_handle(pool, state, async_res)

  rows = collect(res)
  return !isempty(rows) && rows[1][1] == true
end

"""
    with_advisory_lock(f::Function, pool::PormGPostgres, key::AbstractString; wait::Bool=false, timeout_ms::Int=5_000, interval_ms::Int=100, strategy::Symbol=:poll, on_missing_lock::Symbol=:warn)

Execute a function `f` while holding a PostgreSQL session-level advisory lock identified by `key`.

Advisory locks are an application-level locking mechanism provided by PostgreSQL. They are useful for ensuring exclusivity for tasks that don't map directly to a database row, such as synchronizing external API calls or preventing concurrent expensive calculations.

# Arguments
- `f::Function`: The function to execute while holding the lock.
- `pool::PormGPostgres`: The PostgreSQL connection pool.
- `key::AbstractString`: A unique string identifying the lock. It will be hashed to a 64-bit integer.

# Keywords
- `wait::Bool=false`: If `true`, the function will wait until the lock becomes available or the timeout is reached. If `false`, it throws an error immediately if the lock is already held.
- `timeout_ms::Int=5_000`: Maximum time to wait for the lock (in milliseconds).
- `strategy::Symbol=:poll`: The waiting strategy:
    - `:poll`: (Default) Periodically retries lock acquisition from the Julia client. Safe and recommended for most cases.
    - `:block`: Uses PostgreSQL's server-side blocking mechanism. Efficient but holds a connection and uses `statement_timeout`.
- `interval_ms::Int=100`: Retry interval for the `:poll` strategy.
- `on_missing_lock::Symbol=:warn`: What to do on a backend that cannot lock. Ignored on
  PostgreSQL, which always takes a real lock — it exists for the SQLite path (see below).
  An unrecognised value raises `InvalidValueError` on **both** backends, so a typo cannot lie in
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
rather than returned to the pool, and a PostgreSQL advisory lock is bound to the session — so
reconnecting releases it. That happens on a background task, so the interrupt reaches you
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
function with_advisory_lock(f::Function, pool::PormGPostgres, key::AbstractString;
                            wait::Bool = false,
                            timeout_ms::Int = 5_000,
                            interval_ms::Int = 100,
                            strategy::Symbol = :poll,
                            # Accepted and ignored: PostgreSQL always takes a real lock, so there is
                            # no "missing lock" case to have a policy about. It exists so the same
                            # call site can carry `on_missing_lock` and still run on both backends —
                            # on SQLite it is what turns the no-op into a warning or an error
                            # (#277). Without it here, `on_missing_lock = :error` would be a
                            # MethodError on the one backend that satisfies it. Still validated, so
                            # a typo fails on PostgreSQL too rather than lying in wait for SQLite.
                            on_missing_lock::Symbol = :warn)
  _validate_on_missing_lock(on_missing_lock)
  conn = acquire_connection(pool)
  got_lock = false
  old_timeout = nothing
  # Every driver await below funnels through `_await_lock_handle`, which records here whether one of
  # them was cut short by a cancellation — the `finally` reads it to decide the connection's fate.
  await_state = _LockAwaitState()

  try
    # Attempt to acquire lock
    if !wait
      # Non-blocking: single try
      got_lock = _exec_lock_query(pool, conn, TRY_SQL, key, await_state)
    elseif strategy == :block
      # Server-side blocking with timeout
      try
        prev = _await_lock_handle(pool, await_state,
                                  backend_execute_async(pool, conn, "SHOW statement_timeout", nothing))
        rows = collect(prev)
        !isempty(rows) && (old_timeout = rows[1][1])
      catch
        # Best-effort probe: a failure here only costs us the restore value. An ABANDONED await is
        # NOT that — the connection is poisoned from here on and the `SET` below would be issued on
        # it, so let the cancellation out to the finally instead of swallowing it (#322).
        await_state.abandoned && rethrow()
        old_timeout = nothing
      end

      # Await commands without returned rows through the same seam, so a cancellation here is
      # recorded too — this one runs BEFORE `got_lock`, i.e. on a connection the finally would
      # otherwise release straight back into the pool with no unlock attempted at all.
      _await_lock_handle(pool, await_state,
                         backend_execute_async(pool, conn, "SET statement_timeout = $(timeout_ms)", nothing))

      try
        got_lock = _exec_lock_query(pool, conn, BLOCK_SQL, key, await_state)
      catch e
        # `sprint(showerror, e)`, not `string(e)` — and this was a latent bug, not just style.
        # `_exec_lock_query` awaits an async handle, so a server-side cancellation used to arrive
        # here as a `TaskFailedException`, whose `string()` does NOT include the inner driver
        # message (the same fact `_is_benign_rollback_error`'s docstring records). The substring
        # below therefore never matched and this branch had never once fired: the LibPQ
        # `QueryCanceled` propagated instead of degrading to `got_lock = false`. The seam added
        # above now unwraps, and `showerror` renders the cause (#268).
        msg = lowercase(sprint(showerror, e))
        if occursin("canceling statement due to statement timeout", msg)
          @warn "Advisory lock timed out on server-side statement_timeout" key=key timeout_ms=timeout_ms
          got_lock = false
        else
          throw(e)
        end
      end
    else # :poll
      # Client-side polling with retry
      deadline = time() * 1_000 + timeout_ms
      while true
        got_lock = _exec_lock_query(pool, conn, TRY_SQL, key, await_state)
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
      throw(OperationalError("PostgreSQL", "Failed to acquire advisory lock for '$key'"))
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
        _exec_lock_query(pool, conn, UNLOCK_SQL, key, await_state)
      catch e
        @warn "Failed to release advisory lock; connection may have been dropped" key=key exception=(e, catch_backtrace())
      end
    end

    # Restore statement_timeout if we changed it.
    #
    # Awaited through `_await_lock_handle`, NOT a bare `wait` — two reasons, one historical and one
    # current. The `wait::Bool` KEYWORD above shadows `Base.wait` inside this method, so `wait(...)`
    # evaluated as `false(...)` and raised `MethodError: objects of type Bool are not callable`; the
    # empty `catch` blocks below swallowed it, so this restore had never once completed (found while
    # working #277). And now the seam is also what records a cancellation here, which the terminal
    # branch below reads. The empty `catch`es stay — restoring a timeout is genuinely best-effort —
    # but neither a MethodError nor a swallowed Ctrl-C is one of the things they hide any more.
    if !await_state.abandoned
      if old_timeout !== nothing
        try
          _await_lock_handle(pool, await_state,
                             backend_execute_async(pool, conn, "SET statement_timeout = '$(old_timeout)'", nothing))
        catch
        end
      elseif strategy == :block
        try
          _await_lock_handle(pool, await_state,
                             backend_execute_async(pool, conn, "SET statement_timeout TO DEFAULT", nothing))
        catch
        end
      end
    end

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
      # the `SET statement_timeout` before it, in which case no lock was ever taken and claiming to
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

function _validate_on_missing_lock(on_missing_lock::Symbol)
  on_missing_lock in (:warn, :ignore, :error) && return nothing
  throw(InvalidValueError(
    "Invalid on_missing_lock: $(repr(on_missing_lock)). Expected :warn (default), :ignore or :error."))
end

# `kwargs...` still swallows wait/timeout_ms/strategy/interval_ms so the PostgreSQL call shape stays
# portable — that tolerance is the whole point of the no-op.
function with_advisory_lock(f::Function, conn::PormGSQLite, key::AbstractString;
                            on_missing_lock::Symbol = :warn, kwargs...)
  _validate_on_missing_lock(on_missing_lock)

  if on_missing_lock === :error
    throw(BackendCapabilityError(
      "with_advisory_lock(on_missing_lock = :error) cannot be honoured on SQLite — it has no " *
      "advisory locks, so the body for '$key' would run with no mutual exclusion. Use PostgreSQL, " *
      "or pass on_missing_lock = :ignore to accept the no-op."))
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