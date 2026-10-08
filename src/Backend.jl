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

# PostgreSQL has more than one candidate driver (#785), so the driver is a property of the POOL —
# `PostgresConnectionPool{D}` in ConnectionPool.jl — not only of the `PormGPostgres` marker. Several
# generics below carry no driver-typed argument (`backend_connect(pool)`,
# `backend_is_connection_error(pool, e)`, `backend_num_rows(pool, result)`, …), so two extensions
# that both typed those methods on the marker would overwrite each other, and whichever loaded last
# would serve every pool. An extension other than LibPQ's types its methods on its own
# `PostgresConnectionPool{D}` AND on its own connection, result and error types: the pool argument
# alone is not enough, because LibPQ's methods also type their second argument
# (`conn::LibPQ.Connection`, `e::LibPQ.Errors.LibPQException`), and an untyped one there is
# ambiguous with them once both extensions are loaded.
#
# Keyed by driver; the value is the package the user must load for it.
const _PG_DRIVER_PACKAGES = (libpq = "LibPQ", postgres = "Postgres")

"""
    postgres_driver(pool::PormGPostgres) -> Symbol

The PostgreSQL driver `pool` is configured for: a key of `_PG_DRIVER_PACKAGES`. Every
`PormGPostgres` other than `PostgresConnectionPool{D}` — the unit suite's mock pools included —
answers `:libpq`, the only driver before #785.
"""
function postgres_driver end
postgres_driver(::PormGPostgres) = :libpq

# The missing-driver message for a PostgreSQL pool. A LibPQ pool keeps `_PG_DRIVER_HINT` byte for
# byte (docs/src/index.md quotes it).
function _pg_driver_hint(pool::PormGPostgres)::String
  driver = postgres_driver(pool)
  driver === :libpq && return _PG_DRIVER_HINT
  # `get`, not indexing: this runs inside a fallback that must raise InvalidConfigurationError, and
  # a mock pool may answer a driver no real pool can have.
  package = get(_PG_DRIVER_PACKAGES, driver, string(driver))
  return "PormG: this PostgreSQL pool is configured for the $(package).jl driver. Run `using $(package)` " *
         "(or `using PormG, $(package)`) so its PostgreSQL extension loads."
end

# Backend generics. Real methods are added by the driver extensions; the fallbacks
# below fire when the matching driver has not been loaded.
#
#   backend_connect(pool; read_only=false)            -> open a physical connection
#   backend_renew_connection(pool, conn; read_only)   -> reset or recreate a dead connection
#   backend_is_alive(pool, conn)                       -> Bool liveness probe
#   backend_execute(pool, conn, sql, params)           -> SYNC execute (SQLite worker; PG parity)
#   backend_execute_async(pool, conn, sql, params)     -> async handle (PG: LibPQ.AsyncResult)
#   backend_is_connection_error(pool, e)               -> Bool: is `e` a dropped-connection error
#   backend_is_retry_safe(pool, e)                     -> Bool: did the statement provably never run (#1042; below, not in the loop)
#   backend_is_permanent_connect_error(pool, e)        -> Bool: is `e` a permanent connect failure (auth/cantopen) vs transient
#   backend_cancel_query!(pool, conn)                  -> best-effort: stop the statement running on `conn` (#315)
#   backend_drain_connection!(pool, conn)              -> Bool: is `conn` back to a clean, reusable state (#315)
#   backend_num_affected_rows(pool, result)            -> Int matched-row count (PG)
#   backend_num_rows(pool, result)                     -> Int row count (PG)
#   backend_copy_in!(pool, conn, sql, data_itr)        -> Int rows copied: PostgreSQL COPY FROM STDIN (#670)
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
    $fn(pool::PormGPostgres, args...; kwargs...) = throw(InvalidConfigurationError(_pg_driver_hint(pool)))
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

"""
    backend_is_retry_safe(pool, e) -> Bool

Did the statement that raised the lost connection `e` provably **never run** on the server? `fetch`
asks this only after `backend_is_connection_error` has said the connection is lost, and it
re-runs the statement only when this also says `true` (#1042).

The two questions are separate because they have different bars. *Lost* only has to mean the session
is gone, which is enough to renew the slot and retire the idle ones. *Never ran* is what a retry
needs, because a statement whose socket went away after the server received it may already have
committed, and a second run would apply an autocommit write twice. A driver answers `true` only for
the server saying so in a SQLSTATE (the backend is gone and the statement was not executed) or for
a failure raised before anything was written to the socket. A codeless "the socket went away"
answers `false`, whatever the phrase.

Not in the missing-driver loop above, for `backend_classify_error`'s reason: `fetch` calls it
mid-`catch`, and a throw would replace the failure being reported. The default answers `false` —
no retry — so a driver or mock pool that never defines it is safe. Extensions add methods typed on
their **exception types**, never on the pool marker alone, so none shadows this default for the unit
suite's mock pools:

    PormG.backend_is_retry_safe(pool::PormGPostgres, e::LibPQ.Errors.LibPQException) = …
"""
function backend_is_retry_safe end

function backend_is_retry_safe(pool::PormGBackend, e)
  # A multi-result failure: one coded "never ran" among them is the server's own answer.
  e isa CompositeException && return any(inner -> backend_is_retry_safe(pool, inner), e.exceptions)
  return false
end

"""
    backend_error_fields(e) -> NamedTuple{(:sqlstate, :constraint, :table, :column, :message)}

The reason a driver exception carries, **as data** (#987): the fields a [`DatabaseError`](@ref) is
built with, each `nothing` when the driver does not report it. `ConnectionPool._as_database_error`
calls it for every failure it wraps, so the error's rendered text can be built from these fields
alone and never from the driver's text — which carries DETAIL, HINT and the `LINE n:` excerpt,
i.e. the row (prior art: psycopg's `e.diag`).

Keyed on the **exception type alone**, unlike the other `backend_*` generics: the type says which
driver raised it, and with no pool argument no extension method can shadow the default for the unit
suite's mock pools (the hazard `backend_classify_error` documents). Extensions add one method per
driver exception type:

    PormG.backend_error_fields(e::SQLite.SQLiteException) = …

What each driver can report differs, on purpose — the Postgres.jl `Error` has every field, LibPQ's
exception keeps only its text, and SQLite names no SQLSTATE. LibPQ still reports every field: its
extension reads them off the failed result before closing it and hands them to
`_as_database_error` itself (#1000), so its method here is only the fallback for a `PQResultError`
that arrives without its result. Like `backend_classify_error`, it never throws: the caller is
mid-`catch`.
"""
function backend_error_fields end

const _NO_ERROR_FIELDS = (sqlstate = nothing, constraint = nothing, table = nothing, column = nothing,
                          message = nothing)

backend_error_fields(e) = _NO_ERROR_FIELDS

# The server's primary message, or `nothing` when it is not safe to show. SQLSTATE class 22 (data
# exception) is the class whose message PostgreSQL builds FROM THE INPUT —
# `invalid input syntax for type uuid: "<value>"`, `value "<value>" is out of range for type integer`.
# Every other class names objects (a constraint, a column, a type), not values; the value is in the
# DETAIL, which no field carries. Decided here once, for both PostgreSQL extensions.
_safe_server_message(sqlstate, message) =
  (message === nothing || isempty(message) || (sqlstate !== nothing && Base.startswith(sqlstate, "22"))) ?
    nothing : String(message)
