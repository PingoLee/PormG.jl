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

# ── Abandoned-await recovery (#315) ──────────────────────────────────────────

# Ask SQLite to abort whatever statement is running on `conn`.
#
# `sqlite3_interrupt` is the right primitive for all three states the recovery cannot distinguish
# between: it is explicitly documented as safe to call from a thread other than the one running the
# statement (which is always the case here — the global worker owns the handle, the caller does
# not), it is a no-op when nothing is running, and since SQLite 3.8 it provably does not affect
# statements started after it returns. The interrupted statement fails with SQLITE_INTERRUPT and
# the worker's own `finally` finalizes it, so the handle is left consistent.
function PormG.backend_cancel_query!(pool::PormGSQLite, conn::SQLite.DB)
  isopen(conn) || return nothing
  SQLite.C.sqlite3_interrupt(conn.handle)
  return nothing
end

# SQLite has no wire protocol to leave half-consumed, so there is nothing to drain: every statement
# is prepared, stepped and finalized inside ONE `_sqlite_execute_materialized` call above, and the
# async worker only answers its caller AFTER that call returns. So by the time core has seen the
# handle settle, the worker is already off this connection.
#
# The generic exists so the recovery path in core stays backend-agnostic; the PostgreSQL twin is
# the half that does real work.
PormG.backend_drain_connection!(pool::PormGSQLite, conn::SQLite.DB) = true

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

# ── Precompile workload: real queries against a throwaway SQLite database ────
#
# This runs in the precompile worker for the EXTENSION's cache — the one place PormG can execute a
# statement at precompile time, because only here is a driver guaranteed to be loaded.
# `src/precompile.jl` has no driver, so it stops at `show_query` and has never compiled anything
# past SQL generation: parameter binding, the async fetch path, row assembly, the
# `:row`/`:dict`/`:json` shapers, the write terminals, a transaction, model registration and
# the deletion collector.
#
# The approach is Nitro.jl's (`src/precompile.jl` there): drive the PUBLIC surface end to end, the
# way an application does, instead of naming internal methods. Nitro drives `internalrequest`
# without a socket; this drives `Model.objects` against a temp file with no server. What that buys
# over snooped `precompile(...)` directives is that nothing here can go stale silently — the hints
# this replaced referred to anonymous closures by generated number (`#106#107`), and by the time
# they were removed three of the four no longer existed and the fourth named a different closure.
# A renamed method here is an error at precompile time, and so is a workload step that throws:
# PrecompileTools lets it propagate and Julia declines to load the extension. That last part is
# quiet — `using SQLite` still succeeds — so `test/unit/test_precompile_hints.jl` asserts the
# extension loaded, which is what turns a broken workload into a red unit run.
#
# Measured on Julia 1.12.7 with `test/performance/time_to_first_query.jl`, one fresh process per
# run, against models this workload does NOT define, registered the way `@import_models` registers
# them (so what it reports is what carries over to an application's own models): first-use
# latency across 15 steps — DDL, model definition and registration, 12 query operations — fell
# from 24.5 s to 2.3 s (median of three processes each side, on a machine running other sessions:
# before 23.6–25.5 s, after 2.30–2.39 s). The price: the extension's precompile went from ~3 s to
# ~40 s (38–48 s with that load), paid once per install, and `using PormG, SQLite` loads ~0.1–0.2 s
# slower from the larger cache image — paid every start, and under 1% of what the first requests
# save.
#
# Honest scope, the same split Nitro's file documents:
#   * SQLite rows arrive as `NamedTuple`s typed by the query's column names and types, so code
#     specialized on a row is specialized on ONE query shape. The remaining ~2 s is spread over
#     the first `create`s, the first `:json`, the first joined and aggregate reads — the steps
#     that materialize a row type this workload never produced — which is the per-application
#     share no workload can pay in advance. The shared machinery no longer costs anything.
#   * PostgreSQL can inherit at most the backend-agnostic half (query building, the fluent chain,
#     result shaping), and how much of it does is NOT measured here. The LibPQ path cannot be
#     driven at precompile time without a server, which is this workload's version of Nitro's
#     "no socket" rule: warming it is worth doing, doing it with a live connection is not.
#
# Temp directory and pool are created and torn down INSIDE the workload: a module-body side effect
# would run only in the precompile worker (#203), and the config key must not be serialized.

using PrecompileTools: @setup_workload, @compile_workload

# Where the workload registers its models with `set_models`, which is what `@import_models` calls
# and the only thing that wires REVERSE relations — without it `delete()` never reaches the
# collector's walk (measured: with bare `Model(...)` here, the application's first `set_models`
# still cost 0.7 s and its first cascading delete 0.8 s; registered here, 0.04 s and 0.02 s).
# `set_models` needs the models as globals of a module, which constrains where that module can be:
#   * not a throwaway `Module()`: precompilation refuses `Core.eval` into any module outside the
#     package being compiled, and 1.12's `setglobal!` cannot create a binding;
#   * so a submodule of this extension, which IS serialized — hence the two rules below.
# The marker is pre-declared so `set_models` does not inject its own, which would bake this
# machine's deleted temp path into the cache image. Nothing reads it: the self-healing scan in
# `Models.ensure_model_initialized` looks only at top-level modules, and at models whose
# `_module` is this one, of which none survive the workload (see the `finally` below).
module _PrecompileModels
const __pormg_init_path__ = ""
end

@setup_workload begin
  Models = PormG.Models
  CP = PormG.ConnectionPool
  QB = PormG.QueryBuilder

  @compile_workload begin
    mktempdir() do dir
      key = dir   # `set_models(mod, dir)` resolves its connection by this folder
      pool = CP.SQLiteConnectionPool(joinpath(dir, "precompile.sqlite"); pool_size = 1)
      PormG.config[key] = PormG.Configuration.Settings(
        connections = pool, db_def_folder = dir, change_data = true)
      try
        Core.eval(_PrecompileModels, quote
          import PormG.Models
          Driver = Models.Model("driver",
            driverid = Models.IDField(),
            code = Models.CharField(max_length = 3, null = true),
            forename = Models.CharField(max_length = 255),
            surname = Models.CharField(max_length = 255),
            dob = Models.DateField(null = true))
          Constructor = Models.Model("constructor",
            constructorid = Models.IDField(),
            name = Models.CharField(max_length = 255))
          Result = Models.Model("result",
            resultid = Models.IDField(),
            driverid = Models.ForeignKey(Driver, pk_field = "driverid", on_delete = "CASCADE"),
            constructorid = Models.ForeignKey(Constructor, pk_field = "constructorid", on_delete = "RESTRICT"),
            grid = Models.IntegerField(),
            points = Models.FloatField())
        end)
        # `invokelatest`: the bindings are newer than this code's world, the rule `@import_models`
        # handles the same way (#211).
        Base.invokelatest(Models.set_models, _PrecompileModels, dir)
        Driver, Constructor, Result =
          (Base.invokelatest(getglobal, _PrecompileModels, n) for n in (:Driver, :Constructor, :Result))

        # The tables come from PormG's own DDL, not a hand-written CREATE: the first draft of this
        # workload wrote its own, left out AUTOINCREMENT, and `bulk_insert` then failed on the
        # missing `sqlite_sequence` table. A workload must exercise the schema migrations produce.
        for m in (Driver, Constructor, Result)
          CP.fetch(pool, PormG.Dialect.create_table(pool, m))
        end

        # ── Writes: row-level, bulk, and inside a transaction ──
        Driver.objects.create("driverid" => 1, "code" => "SEN", "forename" => "Ayrton",
                              "surname" => "Senna", "dob" => PormG.Dates.Date(1960, 3, 21))
        Driver.objects.create("driverid" => 2, "forename" => "Alain", "surname" => "Prost")
        PormG.run_in_transaction(key) do
          Constructor.objects.create("constructorid" => 1, "name" => "McLaren")
          QB.bulk_insert(Result.objects, PormG.DataFrames.DataFrame(
            resultid = [1, 2], driverid = [1, 2], constructorid = [1, 1], grid = [1, 2], points = [9.0, 6.0]))
        end

        # ── Reads: every list() format, over a plain and a joined projection ──
        Driver.objects.filter("surname" => "Senna").list()
        Driver.objects.filter(QB.Qor("code" => "SEN", "code__@isnull" => true)).order_by("-dob").list(:dict)
        joined = Result.objects.filter("driverid__surname" => "Senna", "points__@gte" => 1.0).
          values("resultid", "driverid__forename", "driverid__dob", "constructorid__name", "points")
        joined.list()
        joined.list(:dict)
        joined.list(:json)
        Result.objects.values("constructorid__name", "total" => QB.Sum("points"), "n" => QB.Count("resultid")).list()
        Result.objects.values("resultid", "adjusted" => QB.F("points") * 1.1).order_by("resultid").limit(5).offset(0).list(:json)
        Driver.objects.get("driverid" => 1)
        Driver.objects.filter("forename__@icontains" => "ayr").count()
        Result.objects.exists()

        # ── Updates and deletes ──
        Result.objects.filter("resultid" => 1).update("points" => QB.F("points") + 1)
        Driver.objects.filter("driverid" => 2).update("code" => "PRO")
        # Checked, not just called: a count without `result` means the collector never saw the
        # reverse relation — the row would still vanish, through SQLite's own ON DELETE CASCADE,
        # so nothing else here would notice. An `AssertionError`, not `error(...)`: it is an internal
        # invariant no user can reach, and `ext/` carries no untyped errors
        # (test/unit/test_docs_error_type_drift.jl).
        _, per_table = Driver.objects.filter("driverid" => 2).delete()
        get(per_table, "result", 0) == 1 || throw(AssertionError(
          "PormG precompile workload: delete() did not cascade through the collector ($per_table)"))

        # ── The two failures every application meets ──
        # Each rethrows anything but the error it is here to reach: a catch-all would keep this
        # green while warming some other failure, which is the #348 shape (a workload that only
        # ever compiled its own error path).
        try
          Driver.objects.create("driverid" => 1, "forename" => "Dup", "surname" => "Dup")
        catch e
          e isa PormG.IntegrityError || rethrow()
        end
        try
          Driver.objects.get("driverid" => 99)
        catch e
          e isa PormG.DoesNotExist || rethrow()
        end
      finally
        # The models must not reach the cache image through `_PrecompileModels`.
        Core.eval(_PrecompileModels, :(Driver = Constructor = Result = nothing))
        delete!(PormG.config, key)
        CP.close_pool!(pool)
      end
    end
  end
end

end # module PormGSQLiteExt
