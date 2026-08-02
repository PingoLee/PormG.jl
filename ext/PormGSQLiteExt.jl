# ==============================================================================
# PormGSQLiteExt — SQLite backend for PormG
#
# Loaded automatically when the user runs `using SQLite`. Implements the backend
# generics declared in `src/Backend.jl` for SQLite pools. Core never names
# `SQLite.DB`; every SQLite-typed body lives here.
# ==============================================================================

module PormGSQLiteExt

using PormG
import PormG: PormGSQLite, PormGSQLiteParam
import SQLite
import Tables

# Busy/locked retry policy (was in src/ConnectionPool.jl before SQLite became a weakdep).
const _SQLITE_LOCK_RETRY_MAX_ATTEMPTS = 20
const _SQLITE_LOCK_RETRY_BASE_DELAY = 0.005
const _SQLITE_LOCK_RETRY_MAX_DELAY = 0.25

function _is_sqlite_locked_error(e)::Bool
  msg = lowercase(string(e))
  return occursin("database is locked", msg) || occursin("database table is locked", msg)
end

function _sqlite_with_retry(op::Function)
  attempt = 1
  while true
    try
      return op()
    catch e
      if !_is_sqlite_locked_error(e) || attempt >= _SQLITE_LOCK_RETRY_MAX_ATTEMPTS
        rethrow(e)
      end

      sleep_seconds = min(_SQLITE_LOCK_RETRY_BASE_DELAY * (1.4^(attempt - 1)), _SQLITE_LOCK_RETRY_MAX_DELAY)
      sleep(sleep_seconds)
      attempt += 1
    end
  end
end

# Unicode-aware LOWER for SQLite case-insensitive lookups (#78). SQLite's built-in LOWER()
# folds ASCII only, so `icontains` missed accented uppercase (e.g. "RÄIKKÖNEN" vs "Räikkönen")
# while PostgreSQL's ILIKE matched. Julia `lowercase` is Unicode-aware. Registered per-connection
# (below) as the SQL function `pormg_lower`, which src/Dialect.jl emits in the SQLite i* renderers.
# A SQL NULL arrives as `missing` and must round-trip to SQL NULL, not throw; non-text values are
# coerced to text (mirroring SQLite's built-in LOWER).
_pormg_lower(x::AbstractString) = lowercase(x)
_pormg_lower(::Missing) = missing
_pormg_lower(x) = lowercase(string(x))

function _create_sqlite_connection(connection_string::String; read_only::Bool = false)
  new_conn = SQLite.DB(connection_string)
  # Unicode-aware case folding for the i* lookups (#78). Deterministic so it stays index-eligible.
  SQLite.register(new_conn, _pormg_lower; nargs = 1, name = "pormg_lower", isdeterm = true)
  SQLite.execute(new_conn, "PRAGMA journal_mode = WAL;")
  SQLite.execute(new_conn, "PRAGMA synchronous = NORMAL;")
  SQLite.execute(new_conn, "PRAGMA busy_timeout = 30000;")
  SQLite.execute(new_conn, "PRAGMA case_sensitive_like = ON;")
  # #276: SQLite defaults `foreign_keys` OFF for backwards compatibility, so PormG's own REFERENCES
  # clauses were declared and never enforced — a dangling FK inserted fine on SQLite and raised
  # IntegrityError on PostgreSQL. That inverts what a test backend is for: the bug passes the SQLite
  # suite and only surfaces in production.
  #
  # It is per-connection, so it belongs here rather than anywhere in core: this is the ONLY
  # `SQLite.DB(` in the repo, and both `backend_connect` and `backend_renew_connection` route
  # through it — which is also what lets a suspended connection be made safe again by renewing it
  # (see `finalize_transaction_connection!(…; renew = true)`). Suspend it for a block with
  # `without_foreign_keys`; migrations do so around the table rebuild.
  SQLite.execute(new_conn, "PRAGMA foreign_keys = ON;")
  if read_only
    SQLite.execute(new_conn, "PRAGMA query_only = ON;")
  end
  return new_conn
end

# Prepare an UNREGISTERED statement, execute it, fully materialize the result rows into a
# connection-independent rowtable, and finalize the statement deterministically.
#
# Why not `SQLite.DBInterface.execute(conn, sql, params)` directly: that path
# (`execute(prepare(conn, sql), params)`) *registers* the `SQLite.Stmt` in the DB's
# `WeakKeyDict` and returns a *lazy* cursor whose backing `sqlite3_stmt` is finalized only
# when the GC later runs the `Stmt` finalizer — on an arbitrary thread, at an arbitrary
# safepoint. Two consequences, both observed as instability on SQLite:
#
#   1. The lazy cursor outlived its pool lease: `await_result` releases the connection as
#      soon as `fetch` returns, but callers materialized the rows (`Tables.rowtable`, etc.)
#      afterwards — stepping a cursor on a connection that had already been handed back to
#      the pool and possibly reused by another statement.
#   2. Under bulk seeding, thousands of registered `Stmt`s accumulate, each with a pending
#      `sqlite3_finalize` finalizer. Those fire while the single async worker is mid
#      `bind`/`step` on the same connection. SQLite is built serialized (THREADSAFE=1) so a
#      well-formed concurrent call is mutex-safe, but combined with the non-idempotent
#      explicit-close paths this opened a use-after-free / double-free window that surfaced
#      as an intermittent `EXCEPTION_ACCESS_VIOLATION` in `sqlite3_bind_int64`.
#
# Preparing with `register = false` keeps the statement out of the `WeakKeyDict` (so a DB
# close never double-finalizes it), `Tables.rowtable` materializes every row while the
# connection is still leased on the worker, and the explicit `close!` finalizes the
# statement immediately instead of deferring to the GC. The returned rowtable is a plain
# `Vector{<:NamedTuple}` that is safe to hand back across the response channel.
function _sqlite_execute_materialized(conn::SQLite.DB, sql::String, params)
  stmt = SQLite.Stmt(conn, sql; register = false)
  try
    cursor = params === nothing ?
      SQLite.DBInterface.execute(stmt) :
      SQLite.DBInterface.execute(stmt, params)
    return Tables.rowtable(cursor)
  finally
    SQLite.DBInterface.close!(stmt)
  end
end

# ── Backend interface methods ────────────────────────────────────────────────

PormG.backend_connect(pool::PormGSQLite; read_only::Bool = false) =
  _create_sqlite_connection(pool.connection_string; read_only = read_only)

PormG.backend_renew_connection(pool::PormGSQLite, conn::SQLite.DB; read_only::Bool = false) =
  _create_sqlite_connection(pool.connection_string; read_only = read_only)

function PormG.backend_is_alive(pool::PormGSQLite, conn::SQLite.DB)
  try
    # Simple query to check if the database is accessible
    SQLite.execute(conn, "SELECT 1")
    return true
  catch
    return false
  end
end

# Synchronous execute — funnelled through the single global SQLite worker in core.
function PormG.backend_execute(pool::PormGSQLite, conn::SQLite.DB, sql::String, params)
  resolved = params isa PormGSQLiteParam ? params.parameters : params
  return _sqlite_with_retry(() -> _sqlite_execute_materialized(conn, sql, resolved))
end

function PormG.backend_is_connection_error(pool::PormGSQLite, e)
  msg = lowercase(string(e))
  return occursin("database is closed", msg) ||
         occursin("database connection is closed", msg) ||
         occursin("disk i/o error", msg)
end

# Is `e` a *permanent* connect failure (won't succeed on retry) rather than transient? SQLite has no
# auth; the realistic permanent case is an unopenable path (missing parent dir / permissions →
# SQLITE_CANTOPEN, "unable to open database file"). Everything else stays ambiguous (return false),
# degrading to the normal wait-to-deadline path. Message-substring based — SQLite.jl exposes one
# `SQLiteException` type for every open failure, so type-matching can't separate causes (#72).
function PormG.backend_is_permanent_connect_error(pool::PormGSQLite, e)
  msg = lowercase(string(e))
  return occursin("unable to open database file", msg)
end

# ── Error classification (#268) ──────────────────────────────────────────────
#
# SQLite is the imprecise half of the boundary, and the asymmetry with PostgreSQL is deliberate —
# do not "clean it up" into a shared helper.
#
# `SQLiteException` carries a single `msg::AbstractString` field and nothing else: `sqliteexception`
# builds it from `sqlite3_errmsg` and discards the result code. `sqlite3_extended_errcode` does
# exist in the C wrapper, but it is unusable from here — it reads live per-connection state, this
# generic is handed `(pool, e)` with no connection, and by the time a caller classifies, the
# transaction seams have already run `ROLLBACK` on that same handle and reset it.
#
# So this matches SQLite's own literal, self-generated constraint strings, which is what
# ActiveRecord's SQLite3 adapter does for the same reason. They are stable across SQLite versions.
#
# Dispatch pins `SQLite.SQLiteException` rather than the abstract `PormGSQLite` marker alone, so
# this never shadows core's default for the unit suite's mock pools (see `backend_classify_error`
# in src/Backend.jl for why that matters).
function PormG.backend_classify_error(pool::PormGSQLite, e::SQLite.SQLiteException)
  PormG.backend_is_connection_error(pool, e) && return :operational
  msg = lowercase(string(e.msg))
  # SQLite spells every constraint failure "<KIND> constraint failed[: table.column]".
  occursin("constraint failed", msg) && return :integrity
  # Contention. `_sqlite_with_retry` above already burns 20 attempts on these, so reaching here
  # means the lock never cleared — transient, and the caller may reasonably retry.
  (occursin("database is locked", msg) || occursin("database table is locked", msg)) && return :operational
  occursin("no such table", msg) && return :statement
  occursin("no such column", msg) && return :statement
  occursin("syntax error", msg) && return :statement
  # Unrecognized: core maps :unknown onto StatementError, so the umbrella still has no hole.
  return :unknown
end

# Window-function support probe used by src/Dialect.jl.
PormG.backend_sqlite_version(pool::PormGSQLite) = Int(SQLite.C.sqlite3_libversion_number())

# ── Precompile hints (moved here from src/precompile.jl with SQLite) ─────────
if ccall(:jl_generating_output, Cint, ()) == 1
  Base.precompile(Tuple{typeof(SQLite.bind!), SQLite.Stmt, Int64, Float64})
  Base.precompile(Tuple{typeof(SQLite.bind!), SQLite.Stmt, Int64, Int64})
end

end # module PormGSQLiteExt
