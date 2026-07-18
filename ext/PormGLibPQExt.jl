# ==============================================================================
# PormGLibPQExt — PostgreSQL backend for PormG
#
# Loaded automatically when the user runs `using LibPQ`. Implements the backend
# generics declared in `src/Backend.jl` for PostgreSQL pools. Core never names
# `LibPQ.Connection`; every LibPQ-typed body lives here, including the low-level
# COPY drain (`LibPQ.libpq_c.*`).
# ==============================================================================

module PormGLibPQExt

using PormG
import PormG: PormGPostgres, PormGPostgresParam
import LibPQ

# ── Backend interface methods ────────────────────────────────────────────────

PormG.backend_connect(pool::PormGPostgres; read_only::Bool = false) =
  LibPQ.Connection(pool.connection_string)

function PormG.backend_renew_connection(pool::PormGPostgres, conn::LibPQ.Connection; read_only::Bool = false)
  # Reset the existing handle in place; if that fails, open a fresh connection.
  # NOTE: the connection-reset API is `reset!` (with a bang) — plain `LibPQ.reset`
  # only resolves to Base.reset methods (none accept a Connection), so the pre-#34
  # `LibPQ.reset(conn)` always MethodError'd and silently fell through to recreate.
  try
    LibPQ.reset!(conn)
    return conn
  catch e
    @debug "PG connection reset failed; opening a new connection" exception=e
    return LibPQ.Connection(pool.connection_string)
  end
end

function PormG.backend_is_alive(pool::PormGPostgres, conn::LibPQ.Connection)
  try
    return LibPQ.status(conn) == LibPQ.libpq_c.CONNECTION_OK
  catch
    return false
  end
end

function PormG.backend_execute(pool::PormGPostgres, conn::LibPQ.Connection, sql::String, params)
  resolved = params isa PormGPostgresParam ? params.parameters : params
  return resolved === nothing ? LibPQ.execute(conn, sql) : LibPQ.execute(conn, sql, resolved)
end

function PormG.backend_execute_async(pool::PormGPostgres, conn::LibPQ.Connection, sql::String, params)
  resolved = params isa PormGPostgresParam ? params.parameters : params
  return resolved === nothing ? LibPQ.async_execute(conn, sql) : LibPQ.async_execute(conn, sql, resolved)
end

function PormG.backend_is_connection_error(pool::PormGPostgres, e)
  msg = lowercase(string(e))
  return (e isa LibPQ.Errors.UnknownError && string(e) == "LibPQ.Errors.UnknownError(\"\")") ||
         occursin("server closed the connection", msg) ||
         occursin("connection not open", msg)
end

# Is `e` a *permanent* connect failure (won't succeed on retry) rather than transient? Scoped to
# high-confidence config/auth classes only — bad password, missing role/database, no pg_hba.conf entry.
# Host/DNS/network failures are deliberately NOT matched: they can be a transient blip during a deploy,
# so they degrade to the normal wait-to-deadline path. LibPQ raises the same `PQConnectionError` (message
# only, no SQLSTATE) for auth and host failures alike, so this is message-substring based (#72).
function PormG.backend_is_permanent_connect_error(pool::PormGPostgres, e)
  msg = lowercase(string(e))
  return occursin("password authentication failed", msg) ||
         occursin("no pg_hba.conf entry", msg) ||
         (occursin("role ", msg) && occursin("does not exist", msg)) ||
         (occursin("database ", msg) && occursin("does not exist", msg))
end

PormG.backend_num_affected_rows(pool::PormGPostgres, result) = LibPQ.num_affected_rows(result)
PormG.backend_num_rows(pool::PormGPostgres, result) = LibPQ.num_rows(result)

function _drain_postgres_connection!(conn::LibPQ.Connection)
  LibPQ.lock(conn) do
    while true
      # COPY can leave a trailing PGresult pending on the connection even after
      # the main Result is closed. Drain it before the connection returns to the pool.
      LibPQ.libpq_c.PQconsumeInput(conn.conn) == 1 || throw(LibPQ.Errors.PQConnectionError(conn))

      if LibPQ.libpq_c.PQisBusy(conn.conn) == 1
        yield()
        continue
      end

      result_ptr = LibPQ.libpq_c.PQgetResult(conn.conn)
      result_ptr == C_NULL && return nothing
      LibPQ.libpq_c.PQclear(result_ptr)
    end
  end
end

# PostgreSQL COPY FROM STDIN. `LibPQ.CopyIn` owns the connection until the stream is
# fully consumed; the caller in core holds the pool lease for the whole call.
function PormG.backend_copy_in!(pool::PormGPostgres, conn::LibPQ.Connection, sql::String, data_itr)
  try
    res = LibPQ.execute(conn, LibPQ.CopyIn(sql, data_itr))
    try
      close(res)
    finally
      _drain_postgres_connection!(conn)
    end
  catch e
    try
      _drain_postgres_connection!(conn)
    catch
    end
    rethrow(e)
  end
end

end # module PormGLibPQExt
