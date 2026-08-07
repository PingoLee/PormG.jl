# ==============================================================================
# Backend interface — the seam between core and the SQL-driver extensions.
#
# `LibPQ` and `SQLite` are weak dependencies (see Project.toml `[weakdeps]`). Core
# must never name a concrete driver type (`LibPQ.Connection`, `SQLite.DB`), so every
# operation that touches the driver goes through one of the generic functions below.
# The driver bodies live in `ext/PormGLibPQExt.jl` / `ext/PormGSQLiteExt.jl` and are
# loaded only when the user runs `using LibPQ` / `using SQLite`.
#
# Dispatch is keyed on the pool MARKER type (`PormGPostgres` / `PormGSQLite`), which
# is defined in core. A concrete pool (`PostgresConnectionPool <: PormGPostgres <:
# PormGBackend`) selects the extension method when the driver is loaded; otherwise the
# varargs fallback fires with a friendly "load the driver" error.
#
# Type discipline: core stores connections untyped (`Any`); each extension method
# pins the concrete driver type in its own signature (e.g.
# `backend_execute(::PormGSQLite, ::SQLite.DB, sql, params)`), so the body
# re-specializes fully. The only untyped step is the single dispatch at the call
# boundary, once per DB round-trip — negligible against I/O.
# ==============================================================================

const _PG_DRIVER_HINT = "PormG: the PostgreSQL backend requires LibPQ. Run `using LibPQ` " *
                        "(or `using PormG, LibPQ`) so the PostgreSQL extension loads."
const _SQLITE_DRIVER_HINT = "PormG: the SQLite backend requires SQLite. Run `using SQLite` " *
                            "(or `using PormG, SQLite`) so the SQLite extension loads."

# Backend generics. Real methods are added by the driver extensions; the fallbacks
# below fire when the matching driver has not been loaded.
#
#   backend_connect(pool; read_only=false)            -> open a physical connection
#   backend_renew_connection(pool, conn; read_only)   -> reset or recreate a dead connection
#   backend_is_alive(pool, conn)                       -> Bool liveness probe
#   backend_execute(pool, conn, sql, params)           -> SYNC execute (SQLite worker; PG parity)
#   backend_execute_async(pool, conn, sql, params)     -> async handle (PG: LibPQ.AsyncResult)
#   backend_is_connection_error(pool, e)               -> Bool: is `e` a dropped-connection error
#   backend_is_permanent_connect_error(pool, e)        -> Bool: is `e` a permanent connect failure (auth/cantopen) vs transient
#   backend_cancel_query!(pool, conn)                  -> best-effort: stop the statement running on `conn` (#315)
#   backend_drain_connection!(pool, conn)              -> Bool: is `conn` back to a clean, reusable state (#315)
#   backend_num_affected_rows(pool, result)            -> Int matched-row count (PG)
#   backend_num_rows(pool, result)                     -> Int row count (PG)
#   backend_copy_in!(pool, conn, sql, data_itr)        -> PostgreSQL COPY FROM STDIN
#   backend_sqlite_version(pool)                        -> Int SQLite library version number
#
# `backend_cancel_query!` and `backend_drain_connection!` are the abandoned-await pair (#315) —
# named rather than positioned, because this list grows. A Ctrl-C leaves the driver mid-operation, and
# neither state — libpq's unconsumed result, SQLite's worker still stepping — is visible to
# `backend_is_alive`, so the pool cannot tell a poisoned connection from a healthy one. They are in
# the loop below on purpose: the throwing "load the driver" fallback is a perfectly good answer for
# `ConnectionPool._recover_abandoned_connection!`, which catches both and treats a throw as
# "not clean" → renew or discard.
for fn in (:backend_connect, :backend_renew_connection, :backend_is_alive,
           :backend_execute, :backend_execute_async, :backend_is_connection_error,
           :backend_is_permanent_connect_error,
           :backend_cancel_query!, :backend_drain_connection!,
           :backend_num_affected_rows, :backend_num_rows, :backend_copy_in!,
           :backend_sqlite_version)
  @eval begin
    function $fn end
    # InvalidConfigurationError, not ErrorException: forgetting `using LibPQ`/`using SQLite` is a
    # setup mistake the docs' `catch PormGError` recipe must cover (audit finding — this fires from
    # ALL backend generics, i.e. the first thing a consumer hits with a missing driver).
    $fn(pool::PormGPostgres, args...; kwargs...) = throw(InvalidConfigurationError(_PG_DRIVER_HINT))
    $fn(pool::PormGSQLite, args...; kwargs...) = throw(InvalidConfigurationError(_SQLITE_DRIVER_HINT))
  end
end

"""
    backend_classify_error(pool, e) -> Symbol

Classify a failure raised by the database into one of the [`DatabaseError`](@ref) kinds:
`:integrity`, `:operational`, `:statement`, or `:unknown`. `ConnectionPool._as_database_error` maps
the symbol to a type; `:unknown` lands on `StatementError` so the umbrella never has a hole.

Deliberately **not** part of the missing-driver loop above: those fallbacks `throw`, and a
classifier that throws while an error is already propagating would replace the real failure with a
setup hint. This one always returns.

The default below is driver-agnostic — it can only recognize the case core already had a generic
for. Extensions refine it, and they dispatch on the **driver exception type**, not just the pool
marker:

    PormG.backend_classify_error(pool::PormGSQLite, e::SQLite.SQLiteException) = …

That is load-bearing. An extension method typed on the abstract marker alone shadows this default
for *every* pool of that flavor, including the behavioral mock pools the unit suite builds — which
throw plain `ErrorException`s and rely on their own `backend_is_connection_error` overrides. Pinning
the exception type means an extension only claims errors it actually understands. (PormG has been
bitten by exactly this shadowing before; see the note in `test/unit/test_error_taxonomy.jl`.)

Precision differs by backend, on purpose:

  * **PostgreSQL** — exact. LibPQ parameterizes its exception type on the SQLSTATE
    (`PQResultError{Class, Code}`), so the extension reads the class directly. No string matching.
  * **SQLite** — message-based. `SQLiteException` carries only `msg`. The extended result code
    (`sqlite3_extended_errcode`) exists but is unusable here: it reads live per-connection state,
    and the transaction seams issue `ROLLBACK` on that same connection before rethrowing, which
    resets it. So the extension matches SQLite's own literal constraint strings — the same approach
    ActiveRecord's SQLite3 adapter takes.
"""
function backend_classify_error end

function backend_classify_error(pool::PormGBackend, e)
  # `backend_is_connection_error` hits the throwing fallback above when no driver is loaded, and a
  # pool mock may not define it at all. Never let classification throw: the caller is mid-`catch`,
  # and the original failure is preserved on `.cause` regardless of how we label it.
  try
    return backend_is_connection_error(pool, e) ? :operational : :unknown
  catch classify_failure
    # Everything except a cancellation. Swallowing Ctrl-C here would make a hung query
    # uninterruptible, which is worse than an unclassified error.
    classify_failure isa InterruptException && rethrow()
    return :unknown
  end
end
