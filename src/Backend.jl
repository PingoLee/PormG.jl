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
#   backend_num_affected_rows(pool, result)            -> Int matched-row count (PG)
#   backend_num_rows(pool, result)                     -> Int row count (PG)
#   backend_copy_in!(pool, conn, sql, data_itr)        -> PostgreSQL COPY FROM STDIN
#   backend_sqlite_version(pool)                        -> Int SQLite library version number
for fn in (:backend_connect, :backend_renew_connection, :backend_is_alive,
           :backend_execute, :backend_execute_async, :backend_is_connection_error,
           :backend_is_permanent_connect_error,
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
