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
const QB = PormG.QueryBuilder   # #1605: the typed read's cell rules

# Busy/locked retry policy (was in src/ConnectionPool.jl before SQLite became a weakdep).
const _SQLITE_LOCK_RETRY_MAX_ATTEMPTS = 20
const _SQLITE_LOCK_RETRY_BASE_DELAY = 0.005
const _SQLITE_LOCK_RETRY_MAX_DELAY = 0.25

# `e` is whatever the statement threw, caught as `Any`: taken unspecialized, so the retry's call is one
# compiled method and not one per exception type, which a `juliac --trim` image has no code for (#1599
# layer 2: the trimmed read's first statement error stopped here with a `MethodError`). SQLite.jl's own
# error, the one a lock raises, is read at its type, through the classifiers' `_phrase_text` (#1714):
# the message lowercased, a malformed character (invalid bytes in an identifier, echoed back) first
# replaced, so it never throws. The old text was `string(e)`, the type name around the escaped message;
# lowercased, that holds one of the two phrases exactly when `_phrase_text` of the message does, since the
# phrases are letters and spaces and neither an escape (`\xff`) nor U+FFFD can split or make one. The
# message field is typed `AbstractString`; SQLite.jl builds it as a `String`.
#
# Any other exception is read through core's `_unowned_string` (#1599), whose typed arms build `string`'s
# own text (an `InterruptException`, an `ErrorException` with a `String` message, …): `string` on an
# untyped exception had no code in a trimmed image, so the lock check replaced the error it was asked
# about with a `MethodError`. A `MethodError` itself answers with its type name, which holds no lock phrase
# (decided on #1799).
function _is_sqlite_locked_error(@nospecialize(e))::Bool
  if e isa SQLite.SQLiteException
    msg = e.msg
    msg isa String && return _is_locked_text(PormG._phrase_text(msg))
  end
  return _is_locked_text(lowercase(PormG._unowned_string(e)))
end
# server-text-match-ok: SQLite has no SQLSTATE here and never localizes its messages
_is_locked_text(msg::String)::Bool = occursin("database is locked", msg) || occursin("database table is locked", msg)

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

# #1599 layer 5: `pormg_lower` is registered with a callback compiled at its types, not through
# `SQLite.register`. SQLite.jl's scalar callback calls the function through a `Function` slot over a
# `Vector{Any}` of its arguments, so in a trimmed image it raised a `MethodError`, and so did the error report
# (`udf_error`, specialized on the error): the trimmed read stopped at `name__@icontains` with a `StatementError`
# and then hung at exit, in `sqlite3_close_v2`. This callback reads its one value as SQLite.jl's does
# (`sqlvalue`), folds it at its type and returns it with `sqlreturn`; any other value takes `_pormg_lower` at run
# time, as before. A failure (`lowercase` raises `InvalidCharError` on a TEXT value that is not valid UTF-8) takes
# the path the loaded SQLite.jl's own callback takes: from 1.10 on it is reported to SQLite as `udf_error` reports
# it, and the query raises `SQLiteException`; before 1.10 the callback had no `try`, so the error is rethrown,
# as it was.
function _pormg_lower_callback(context::Ptr{Cvoid}, nargs::Cint, values::Ptr{Ptr{Cvoid}})::Cvoid
  try
    _pormg_lower_return(context, SQLite.sqlvalue(values, 1))
  catch err
    _SQLITE_REPORTS_UDF_ERRORS || rethrow()
    _pormg_udf_error(context, err)
  end
  return nothing
end
# Whether the loaded SQLite.jl reports a callback's error to SQLite (`udf_error`, 1.10 and later) or lets it unwind.
const _SQLITE_REPORTS_UDF_ERRORS = isdefined(SQLite, :udf_error)
@noinline function _pormg_lower_return(context::Ptr{Cvoid}, @nospecialize(v))
  v isa String && return SQLite.sqlreturn(context, _pormg_lower(v))
  v isa Missing && return SQLite.sqlreturn(context, _pormg_lower(v))
  v isa Int64 && return SQLite.sqlreturn(context, _pormg_lower(v))
  v isa Float64 && return SQLite.sqlreturn(context, _pormg_lower(v))
  return SQLite.sqlreturn(context, _pormg_lower(v))
end
@noinline function _pormg_udf_error(context::Ptr{Cvoid}, @nospecialize(err))
  try
    if err isa OutOfMemoryError
      SQLite.C.sqlite3_result_error_nomem(context)
    else
      message = sprint(showerror, err)
      SQLite.C.sqlite3_result_error(context, message, sizeof(message))
    end
  catch  # swallows a failure to format the error: SQLite still gets one, as SQLite.jl's `udf_error` gives it
    SQLite.C.sqlite3_result_error(context, "Julia exception in SQLite callback", -1)
  end
  return nothing
end

# `SQLite.register(db, _pormg_lower; nargs = 1, name = "pormg_lower", isdeterm = true)`, with the callback above.
function _register_pormg_lower!(db::SQLite.DB)
  callback = @cfunction(_pormg_lower_callback, Cvoid, (Ptr{Cvoid}, Cint, Ptr{Ptr{Cvoid}}))
  enc = SQLite.C.SQLITE_UTF8 | SQLite.C.SQLITE_DETERMINISTIC
  rc = SQLite.C.sqlite3_create_function_v2(db.handle, "pormg_lower", 1, enc, C_NULL, callback, C_NULL, C_NULL, C_NULL)
  rc == SQLite.C.SQLITE_OK || SQLite.sqliteerror(db)
  return nothing
end

# `LPad`/`RPad` for SQLite (#122), which has no LPAD/RPAD. Registered per-connection (below) as
# `pormg_lpad`/`pormg_rpad`, which src/Dialect.jl emits. PostgreSQL's semantics, character for
# character: a string longer than `n` is cut to its first `n` characters (for both sides), a `fill`
# repeats and is cut, an empty `fill` pads nothing, a negative `n` is 0, and a NULL argument is NULL.
# A UDF is acceptable here where it was not for regex (#635): padding has one definition, so the
# Julia function cannot disagree with PostgreSQL's the way PCRE and POSIX patterns do, and the value
# is a projection or a SET value, so no index is lost to it. The query builder refuses a typed value
# that is not text before SQL is written, and PostgreSQL fails on it anyway. What still arrives
# untyped (a `Subquery`, an untyped `Case`) is converted with `string`, which is NOT SQLite's own
# conversion for a float (`1.0e20`, where SQLite writes `1.0e+20`); a blob is read as its bytes.
_pormg_pad_text(x::AbstractVector{UInt8}) = String(copy(x))
_pormg_pad_text(x) = string(x)
function _pormg_pad(s, n::Integer, fill, left::Bool)
  s, fill, n = _pormg_pad_text(s), _pormg_pad_text(fill), max(Int(n), 0)
  k = length(s)
  k >= n && return first(s, n)
  isempty(fill) && return s
  pad = first(repeat(fill, cld(n - k, length(fill))), n - k)
  return left ? pad * s : s * pad
end
_pormg_lpad(s, n, fill) = any(ismissing, (s, n, fill)) ? missing : _pormg_pad(s, n, fill, true)
_pormg_rpad(s, n, fill) = any(ismissing, (s, n, fill)) ? missing : _pormg_pad(s, n, fill, false)

function _create_sqlite_connection(connection_string::String; read_only::Bool = false)
  new_conn = SQLite.DB(connection_string)
  # Unicode-aware case folding for the i* lookups (#78). Deterministic so it stays index-eligible.
  _register_pormg_lower!(new_conn)
  # String padding for `LPad`/`RPad` (#122).
  SQLite.register(new_conn, _pormg_lpad; nargs = 3, name = "pormg_lpad", isdeterm = true)
  SQLite.register(new_conn, _pormg_rpad; nargs = 3, name = "pormg_rpad", isdeterm = true)
  # `busy_timeout` first: switching to WAL takes a lock on the file, and since #1540 two connections
  # of one pool can open at the same moment. Set after it, the first could see SQLITE_BUSY at once.
  SQLite.execute(new_conn, "PRAGMA busy_timeout = 30000;")
  SQLite.execute(new_conn, "PRAGMA journal_mode = WAL;")
  SQLite.execute(new_conn, "PRAGMA synchronous = NORMAL;")
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

# The statement's positional parameters, bound by value type (#1599 layer 2). SQLite.jl binds a vector
# of parameters with one `bind!(stmt, i, values[i])` per value, and PormG's collector holds them as
# `Vector{Any}`, so each was a call on an `Any`: one dispatch per value under the JIT, and in a
# `juliac --trim` image a call with no compiled target (the trimmed read stopped at
# `bind!(::Stmt, ::Int64, ::String)`). Wrapped in `_SQLiteBinds`, the vector reaches this extension's
# `SQLite.bind!` method instead of SQLite.jl's positional one. It has the same body, one positional
# `bind!` per placeholder after the same count check and message, with each value's call made at the
# types the SQLite collector binds (`sqlite_bind_value`). Any other value (a `ManualParams` entry) takes
# the call it took before, one dynamic `bind!`. A tuple, a named collection or `nothing` is handed over
# as it was.
struct _SQLiteBinds{V<:AbstractVector} <: AbstractVector{Any}
  values::V
end
Base.size(b::_SQLiteBinds) = size(b.values)
Base.getindex(b::_SQLiteBinds, i::Int) = b.values[i]
Base.IndexStyle(::Type{<:_SQLiteBinds}) = IndexLinear()

_sqlite_binds(params::AbstractVector) = _SQLiteBinds(params)
_sqlite_binds(params) = params

function SQLite.bind!(stmt::SQLite.Stmt, b::_SQLiteBinds)
  values = b.values
  nparams = SQLite.C.sqlite3_bind_parameter_count(SQLite._get_stmt_handle(stmt))
  (nparams == length(values)) || throw(
    SQLite.SQLiteException("values should be provided for all query placeholders"),
  )
  for i in 1:nparams
    @inbounds _sqlite_bind_one!(stmt, i, values[i])
  end
end

# One arm per type `sqlite_bind_value` hands over, each a static call into SQLite.jl's own method.
@noinline function _sqlite_bind_one!(stmt::SQLite.Stmt, i::Int, @nospecialize(v))
  v isa String && return SQLite.bind!(stmt, i, v)
  v isa Int64 && return SQLite.bind!(stmt, i, v)
  v isa Float64 && return SQLite.bind!(stmt, i, v)
  v isa Bool && return SQLite.bind!(stmt, i, v)
  v isa Missing && return SQLite.bind!(stmt, i, v)
  v isa Nothing && return SQLite.bind!(stmt, i, v)
  v isa Int32 && return SQLite.bind!(stmt, i, v)
  v isa Vector{UInt8} && return SQLite.bind!(stmt, i, v)
  return _sqlite_bind_open!(stmt, i, v)
end
@noinline _sqlite_bind_open!(stmt::SQLite.Stmt, i::Int, @nospecialize(v)) = SQLite.bind!(stmt, i, v)

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
      SQLite.DBInterface.execute(stmt, _sqlite_binds(params))
    # `Query{false}`, the cursor PormG's call builds (see `_sqlite_decode_rows`); any other is read by
    # `Tables.rowtable`, as before, behind `@noinline`.
    cursor isa SQLite.Query{false} && return _sqlite_rowtable(cursor)
    return _sqlite_rowtable_open(cursor)
  finally
    SQLite.DBInterface.close!(stmt)
  end
end
@noinline _sqlite_rowtable_open(@nospecialize(cursor)) = Tables.rowtable(cursor)

# #1599: what `Tables.rowtable(cursor)` returns, built without it. `Tables.rowtable` builds each row as a
# `NamedTuple` whose type the row's cells decide (SQLite types each cell), through calls on types known only
# at run time, and a trimmed image had no code for them: every non-typed SQLite statement (a write's
# INSERT and its read-back, a count, a migration's introspection) raised `MethodError` there. This builds
# the same `Vector` from builtins, which need no compiled code per type:
#   - the column names are read once (`q.names`, which `Tables.columnnames(::Query)` returns);
#   - each cell by its storage class (`_sqlite_value`), the read `Tables.getcolumn` makes on a non-strict
#     row (`SQLite.getvalue` with `Any`);
#   - each row as `NamedTuple{names, typeof(cells)}` (`Core.apply_type`, `jl_new_structt`), the row type
#     `NamedTuple{names}(cells)` makes;
#   - the vector's element type widened as `collect` widens it (`Base.promote_typejoin` of the row
#     types), and its elements stored with `memoryrefset!`;
#   - for no rows, the element type `Tables.rowtable` takes from the cursor's schema then:
#     `NamedTuple{names, Tuple{q.types...}}`.
# `test_sqlite_materialize.jl` compares the result with `Tables.rowtable`'s, type and values.
function _sqlite_rowtable(q::SQLite.Query{false})
  names = q.names
  key = (names...,)
  isempty(q) && return _sqlite_typed_vector(Core.apply_type(NamedTuple, key, (Core.apply_type(Tuple, q.types...))), Any[])
  # The handle at its type: SQLite.jl keeps it in a `Ref{Ptr{SQLite.C.sqlite3_stmt}}`, an abstract field at
  # the 1.6.1 floor, where the read came back untyped and each cell read was a dynamic call.
  handle = SQLite._get_stmt_handle(q.stmt)::Ptr{SQLite.C.sqlite3_stmt}
  n = length(names)
  rows = Any[]
  eltype_ = Union{}
  next = iterate(q)
  while next !== nothing
    cells = Vector{Any}(undef, n)
    for j in 1:n
      cells[j] = _sqlite_value(handle, j)
    end
    tup = (cells...,)
    R = Core.apply_type(NamedTuple, key, typeof(tup))
    push!(rows, ccall(:jl_new_structt, Any, (Any, Any), R, tup))
    eltype_ = eltype_ === Union{} ? R : (R <: eltype_ ? eltype_ : Base.promote_typejoin(eltype_, R))
    next = iterate(q, next[2])
  end
  return _sqlite_typed_vector(eltype_, rows)
end

# A cell by its storage class, as a non-strict `SQLite.getvalue` reads it (1.6.1 through 1.11 read the
# classes the same way; `test_driver_internals.jl` pins the C names); a BLOB through SQLite.jl's own read.
@inline function _sqlite_value(handle, col::Int)
  t = SQLite.C.sqlite3_column_type(handle, col - 1)
  t == SQLite.C.SQLITE_NULL && return missing
  t == SQLite.C.SQLITE_INTEGER && return SQLite.C.sqlite3_column_int64(handle, col - 1)
  t == SQLite.C.SQLITE_FLOAT && return SQLite.C.sqlite3_column_double(handle, col - 1)
  t == SQLite.C.SQLITE_TEXT && return SQLite.sqlitevalue(String, handle, col)
  return SQLite.sqlitevalue(Any, handle, col)
end

# A `Vector{T}` holding `rows`, for a `T` known only at run time: allocated by the runtime
# (`jl_alloc_array_1d`) and filled through `memoryrefset!`, which check each element against `T` as
# `setindex!` would, with no method compiled per `T`. Each slot's reference is bounds-checked
# (`memoryrefnew(…, true)`), as `setindex!` checks its index.
function _sqlite_typed_vector(@nospecialize(T::Type), rows::Vector{Any})
  v = ccall(:jl_alloc_array_1d, Any, (Any, Csize_t), Core.apply_type(Vector, T), length(rows))
  ref = getfield(v, :ref)
  for i in eachindex(rows)
    Core.memoryrefset!(Core.memoryrefnew(ref, i, true), rows[i], :not_atomic, false)
  end
  return v
end

# ── Backend interface methods ────────────────────────────────────────────────

# #1683: the handle type this extension's pool holds, so `ConnectionPool._with_handle` calls the
# driver at its concrete type (`backend_handle_type`'s docstring).
PormG.backend_handle_type(::Type{<:PormG.ConnectionPool.SQLiteConnectionPool}) = SQLite.DB

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
  try
    return _sqlite_with_retry(() -> _sqlite_execute_materialized(conn, sql, resolved))
  catch
    _release_leaked_db_lock!(conn)
    rethrow()
  end
end

# #1605: the typed read, on the same worker and with the same statement lifecycle, retry and lock
# release as `backend_execute`, but stepped straight into `T`. `_sqlite_execute_materialized` builds a
# `Tables.rowtable`, whose `NamedTuple` types are decided by each row's cells at run time: a typed read
# that went through it paid for that row and then made a dynamic call on it per row, and a trimmed build
# (`juliac --trim`) has no compiled target for either. Here each cell is read by its storage class
# (INTEGER, FLOAT, TEXT, BLOB, NULL), the read `SQLite.getvalue` makes for that class, and goes through
# the field's parser and the typed read's cell rules (`_typed_value`) with every call static.
function PormG.backend_execute_rows(pool::PormGSQLite, conn::SQLite.DB, sql::String, params,
                                    decode::PormG.QueryBuilder._RowDecoder{T}) where T
  resolved = params isa PormGSQLiteParam ? params.parameters : params
  try
    return _sqlite_with_retry(() -> _sqlite_decode_rows(conn, sql, resolved, decode))::Vector{T}
  catch
    _release_leaked_db_lock!(conn)
    rethrow()
  end
end

function _sqlite_decode_rows(conn::SQLite.DB, sql::String, params,
                             decode::PormG.QueryBuilder._RowDecoder{T})::Vector{T} where T
  stmt = SQLite.Stmt(conn, sql; register = false)
  try
    q = params === nothing ? SQLite.DBInterface.execute(stmt) : SQLite.DBInterface.execute(stmt, _sqlite_binds(params))
    # #1599 layer 2: SQLite.jl builds its cursor as `Query{strict}` from a keyword, so the call returns
    # an abstract `Query` to inference, and the call below was dynamic: the trimmed read stopped at
    # `_sqlite_rows_into(::DataType, ::Query{false}, …)`. PormG never passes `strict`, so the cursor is
    # `Query{false}` (a parameter of `Query` on every SQLite.jl from the 1.6.1 floor up); any other
    # takes the same call through one `@noinline` arm.
    q isa SQLite.Query{false} && return _sqlite_rows_into(T, q, decode)
    return _sqlite_rows_into_open(T, q, decode)
  finally
    SQLite.DBInterface.close!(stmt)
  end
end
@noinline _sqlite_rows_into_open(::Type{T}, @nospecialize(q), decode::PormG.QueryBuilder._RowDecoder{T}) where T =
  _sqlite_rows_into(T, q, decode)::Vector{T}

# The rows, stepped with `iterate` (the first row is already stepped by `execute`; each further one is
# one step, under the lock each SQLite.jl version takes for it, and an error status raises there as it
# did through `Tables.rowtable`). An error raised while BUILDING a row (a cell rule's refusal, a parser's,
# or the row type's own constructor) is recorded on the decoder and the walk stops: thrown here, on the
# worker, it would reach the caller wrapped as the statement's `StatementError`; `fetch` raises the
# recorded error as it was raised (`decoded_on_worker`), as when the decode ran after `fetch` returned.
function _sqlite_rows_into(::Type{T}, q, decode::PormG.QueryBuilder._RowDecoder{T})::Vector{T} where T
  handle = SQLite._get_stmt_handle(q.stmt)
  # `q.names` (a `Vector{Symbol}` on every SQLite.jl from 1.6.1 on, pinned in test_driver_internals.jl):
  # the field `Tables.columnnames(::SQLite.Query)` returns, read directly.
  cols = _sqlite_field_columns(T, q.names)
  parsers, site = decode.parsers, decode.site
  out = T[]
  i = 0
  next = iterate(q)
  while next !== nothing
    i += 1
    row = try
      _sqlite_typed_row(T, handle, cols, parsers, i, site)
    catch e
      (e isa InterruptException || !(e isa Exception)) && rethrow()   # a Ctrl-C stops the statement, as anywhere else
      PormG.QueryBuilder._decode_failed!(decode, e)
      return out
    end
    push!(out, row)
    next = iterate(q, next[2])
  end
  return out
end

# The insert's read-back (#1599 layer 7, #1694): the same statement lifecycle, retry and lock release, the
# rows stepped straight into the field-keyed Dicts the query builder's `_FieldRowDecoder` describes. The
# read-back went through `Tables.rowtable` and `pairs(row)` on a row type decided at run time, which a
# trimmed image has no code for. Each cell is read by its storage class, as `_sqlite_value` reads it, and
# handed at that type to its field's parser; the Dict holds `Any`, so storing it is static.
function PormG.backend_execute_rows(pool::PormGSQLite, conn::SQLite.DB, sql::String, params,
                                    decode::PormG.QueryBuilder._FieldRowDecoder)
  resolved = params isa PormGSQLiteParam ? params.parameters : params
  try
    return _sqlite_with_retry(() -> _sqlite_field_rows(conn, sql, resolved, decode))::Vector{Dict{Symbol,Any}}
  catch
    _release_leaked_db_lock!(conn)
    rethrow()
  end
end

function _sqlite_field_rows(conn::SQLite.DB, sql::String, params,
                            decode::PormG.QueryBuilder._FieldRowDecoder)::Vector{Dict{Symbol,Any}}
  stmt = SQLite.Stmt(conn, sql; register = false)
  try
    q = params === nothing ? SQLite.DBInterface.execute(stmt) : SQLite.DBInterface.execute(stmt, _sqlite_binds(params))
    q isa SQLite.Query{false} && return _sqlite_field_rows_into(q, decode)   # `_sqlite_decode_rows`'s reason
    return _sqlite_field_rows_into_open(q, decode)
  finally
    SQLite.DBInterface.close!(stmt)
  end
end
@noinline _sqlite_field_rows_into_open(@nospecialize(q), decode::PormG.QueryBuilder._FieldRowDecoder) =
  _sqlite_field_rows_into(q, decode)::Vector{Dict{Symbol,Any}}

# The rows, stepped as `_sqlite_rows_into` steps them; an error raised while building a row (a parser's
# refusal) is recorded on the decoder and the walk stops, so `fetch` raises it as it was raised.
function _sqlite_field_rows_into(q, decode::PormG.QueryBuilder._FieldRowDecoder)::Vector{Dict{Symbol,Any}}
  handle = SQLite._get_stmt_handle(q.stmt)::Ptr{SQLite.C.sqlite3_stmt}   # `_sqlite_rowtable`'s reason
  names = q.names   # a `Vector{Symbol}` (see `_sqlite_rows_into`)
  fkeys = Symbol[QB._field_key(decode, n) for n in names]
  parsers = PormG.ReadParser[QB._field_parser(decode, k) for k in fkeys]
  out = Dict{Symbol,Any}[]
  next = iterate(q)
  while next !== nothing
    row = try
      dict = Dict{Symbol,Any}()
      for c in eachindex(fkeys)
        dict[fkeys[c]] = _sqlite_field_cell(handle, c, parsers[c])
      end
      dict
    catch e
      (e isa InterruptException || !(e isa Exception)) && rethrow()   # a Ctrl-C stops the statement
      decode.failure[] = e
      return out
    end
    push!(out, row)
    next = iterate(q, next[2])
  end
  return out
end

# One cell by its storage class, as `_sqlite_value` reads it, through the field's parser at that type. A BLOB
# is SQLite.jl's own read, untyped, so its parse is one call through `@noinline`.
@inline function _sqlite_field_cell(handle, col::Int, parser::PormG.ReadParser)
  t = SQLite.C.sqlite3_column_type(handle, col - 1)
  t == SQLite.C.SQLITE_NULL && return parser(missing)
  t == SQLite.C.SQLITE_INTEGER && return parser(SQLite.C.sqlite3_column_int64(handle, col - 1))
  t == SQLite.C.SQLITE_FLOAT && return parser(SQLite.C.sqlite3_column_double(handle, col - 1))
  t == SQLite.C.SQLITE_TEXT && return parser(SQLite.sqlitevalue(String, handle, col))
  return _sqlite_field_blob(parser, SQLite.sqlitevalue(Any, handle, col))
end
@noinline _sqlite_field_blob(parser::PormG.ReadParser, @nospecialize(v)) = parser(v)

# How many rows a statement returns (`exists()`, #1599 layer 7, #1694): the statement lifecycle, retry and lock
# release of `backend_execute`, the rows stepped and counted. Each cell is read as `_sqlite_rowtable` reads it
# (`_sqlite_value`), and discarded, so a cell whose read raised there raises here, inside the statement as there.
function PormG.backend_execute_rows(pool::PormGSQLite, conn::SQLite.DB, sql::String, params,
                                    ::PormG.QueryBuilder._RowCounter)
  resolved = params isa PormGSQLiteParam ? params.parameters : params
  try
    return _sqlite_with_retry(() -> _sqlite_count_rows(conn, sql, resolved))::Int
  catch
    _release_leaked_db_lock!(conn)
    rethrow()
  end
end

function _sqlite_count_rows(conn::SQLite.DB, sql::String, params)::Int
  stmt = SQLite.Stmt(conn, sql; register = false)
  try
    q = params === nothing ? SQLite.DBInterface.execute(stmt) : SQLite.DBInterface.execute(stmt, _sqlite_binds(params))
    q isa SQLite.Query{false} && return _sqlite_count_rows_in(q)   # `_sqlite_decode_rows`'s reason
    return _sqlite_count_rows_open(q)
  finally
    SQLite.DBInterface.close!(stmt)
  end
end
@noinline _sqlite_count_rows_open(@nospecialize(q)) = length(Tables.rowtable(q))

function _sqlite_count_rows_in(q::SQLite.Query{false})::Int
  handle = SQLite._get_stmt_handle(q.stmt)::Ptr{SQLite.C.sqlite3_stmt}   # `_sqlite_rowtable`'s reason
  ncols = length(q.names)
  n = 0
  next = iterate(q)
  while next !== nothing
    for j in 1:ncols
      _sqlite_value(handle, j)
    end
    n += 1
    next = iterate(q, next[2])
  end
  return n
end

# The result column of each field of `T`, by name: the typed projection names every field (and nothing
# else), but a `values(...)` projection may list them in another order.
function _sqlite_field_columns(::Type{T}, names::AbstractVector{Symbol}) where T
  return ntuple(Val(fieldcount(T))) do k
    col = something(findfirst(==(fieldname(T, k)), names), 0)
    col == 0 && throw(PormG.QueryBuildError(
      "The typed read's result has no column for field $(fieldname(T, k)); the projection and the row type disagree."))
    col
  end
end

@generated function _sqlite_typed_row(::Type{T}, handle, cols::Tuple, parsers::Tuple, i::Int, site) where T
  cells = [:(_sqlite_cell($(fieldtype(T, k)), handle, cols[$k], parsers[$k], $(QuoteNode(fieldname(T, k))), i, site))
           for k in 1:fieldcount(T)]
  return T <: NamedTuple ? :(T(($(cells...),))) : :(T($(cells...)))
end

# One cell, by its storage class. Each branch hands a concrete value to the parser and the cell rules.
# A BLOB is read as `SQLite.getvalue` reads it (SQLite.jl's deserialization), the one dynamic branch:
# the typed read has no binary rule to apply to it.
@inline function _sqlite_cell(::Type{FT}, handle, col::Int, parser, name::Symbol, i::Int, site)::FT where FT
  t = SQLite.C.sqlite3_column_type(handle, col - 1)
  t == SQLite.C.SQLITE_NULL &&
    return QB._typed_value(FT, QB._typed_parse(parser, missing), name, i, site)
  t == SQLite.C.SQLITE_INTEGER &&
    return QB._typed_value(FT, QB._typed_parse(parser, SQLite.C.sqlite3_column_int64(handle, col - 1)), name, i, site)
  t == SQLite.C.SQLITE_FLOAT &&
    return QB._typed_value(FT, QB._typed_parse(parser, SQLite.C.sqlite3_column_double(handle, col - 1)), name, i, site)
  t == SQLite.C.SQLITE_TEXT &&
    return QB._typed_value(FT, QB._typed_parse(parser, SQLite.sqlitevalue(String, handle, col)), name, i, site)
  return QB._typed_value(FT, QB._typed_parse(parser, SQLite.sqlitevalue(Any, handle, col)), name, i, site)
end

# Give back every hold this task still has on `conn`'s own lock after a statement failed (#1521).
#
# SQLite.jl takes the `ReentrantLock` on its `DB` (`db.lock`) around each native call, as
# `Base.@lock db.lock C.sqlite3_step(…)`, which releases it in a `finally`. An `InterruptException`
# can defeat that `finally`. Under `julia -t 1`, a Ctrl-C during a long statement stays pending
# while `sqlite3_step` runs (a ccall, so no safepoint), and the first safepoint after it returns is
# the entry of `unlock` itself, inside that `finally`. So the exception is thrown by the `unlock`
# that was meant to release the lock, before it decrements the count, and nothing else releases it.
# The worker task then keeps `db.lock` for good, idle on its queue. The next statement, the
# checkout probe (`backend_is_alive`) and `close` on that handle all wait on it forever: the hang
# #1521 reported, and the reason `exit` hung too. Captured with the exception's backtrace, which
# ends in `Base._unlock` called from `SQLite.execute`.
#
# PormG never holds `db.lock` across this call (nothing in PormG takes it), so whatever hold the
# task has left when the statement has failed can only be a leaked one, and giving it back is
# exact. Only this task's holds are touched: `locked_by` names the owner, and a lock another task
# holds is left alone. Every exception gets the check, not only `InterruptException`, because the
# same leak follows from any exception thrown at that point, and the check costs one field read.
#
# The count guard is for an exception landing inside `unlock` after it decremented the count and
# before it cleared the owner: that leaves count 0 with this task named, and an unguarded loop would
# underflow the count. `locked_by` and `reentrancy_cnt` are fields of Base's `ReentrantLock`; the
# #1521 test reads both, so a rename fails there.
#
# SQLite.jl took no Julia-side lock before 1.9.0 (`DB` has no `lock` field there; PormG's floor is
# 1.6.1), so there is nothing to leak and nothing to release. `hasfield` on the type is a constant,
# so the check costs nothing at run time.
function _release_leaked_db_lock!(conn::SQLite.DB)
  hasfield(SQLite.DB, :lock) || return nothing
  l = conn.lock
  while l.locked_by === current_task() && l.reentrancy_cnt > 0
    unlock(l)
  end
  return nothing
end

# No `backend_is_retry_safe` method: on SQLite, core's default (`false`) holds for every failure, so
# `fetch` renews the connection and never re-runs the statement (#1042). The one match below that
# libsqlite3 produces, "disk I/O error", can come from a commit whose outcome is unknown. Neither
# "closed" phrase appears in libsqlite3's string table or in SQLite.jl, so no "never ran" signal
# exists to recognize.
#
# No `backend_is_cancellation` method either (#1277): SQLite has no statement timeout, and its one
# cancel, PormG's own `sqlite3_interrupt` below, classifies as `:unknown` → `StatementError`, never
# as the `OperationalError` a retry would consider.
# The message of a SQLite exception (#1714), read at a known type: SQLite.jl declares `msg` an
# `AbstractString` and stores a `String`, so only a hand-built one takes the open arm. A phrase is matched
# against the message itself, where it used to be matched against `string(e)` (SQLite.jl's default
# `show`, `SQLiteException("<msg>")`). The answers are the same except where `show` escaped a character:
# an escape spells letters (`\n`, `\t`, `\xe7`), which could complete a phrase that the message does not
# hold, and a malformed character, which `_phrase_text` replaces instead of letting `lowercase` throw.
_sqlite_msg(e::SQLite.SQLiteException)::String = (m = e.msg; m isa String ? m : PormG._unowned_string(m))
# The lower-cased text a phrase is matched against: the message, or, for an exception SQLite does not
# own, the text `string` gives it, as always (core's open arm).
_sqlite_text(@nospecialize(e))::String =
  e isa SQLite.SQLiteException ? PormG._phrase_text(_sqlite_msg(e)) : PormG._unowned_error_text(e)

function PormG.backend_is_connection_error(pool::PormGSQLite, @nospecialize(e))
  msg = _sqlite_text(e)
  # server-text-match-ok: SQLite has no SQLSTATE here and never localizes its messages
  return occursin("database is closed", msg) ||
         occursin("database connection is closed", msg) ||
         occursin("disk i/o error", msg)
end

# Is `e` a *permanent* connect failure (won't succeed on retry) rather than transient? SQLite has no
# auth; the realistic permanent case is an unopenable path (missing parent dir / permissions →
# SQLITE_CANTOPEN, "unable to open database file"). Everything else stays ambiguous (return false),
# degrading to the normal wait-to-deadline path. Message-substring based — SQLite.jl exposes one
# `SQLiteException` type for every open failure, so type-matching can't separate causes (#72).
function PormG.backend_is_permanent_connect_error(pool::PormGSQLite, @nospecialize(e))
  msg = _sqlite_text(e)
  # server-text-match-ok: SQLite has no SQLSTATE here and never localizes its messages
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
function PormG.backend_classify_error(pool::PormGSQLite, @nospecialize(e))
  # One method, the exception `@nospecialize` and tested here (#1696): see `backend_classify_error`.
  e isa SQLite.SQLiteException || return PormG._default_classify_error(pool, e)
  PormG.backend_is_connection_error(pool, e) && return :operational
  msg = PormG._phrase_text(_sqlite_msg(e))
  # SQLite spells every constraint failure "<KIND> constraint failed[: table.column]".
  # server-text-match-ok: SQLite's own literal constraint text; no result code reaches here (above)
  occursin("constraint failed", msg) && return :integrity
  # Contention. `_sqlite_with_retry` above already burns 20 attempts on these, so reaching here
  # means the lock never cleared — transient, and the caller may reasonably retry.
  (occursin("database is locked", msg) || occursin("database table is locked", msg)) && return :operational  # server-text-match-ok: SQLite, as above
  occursin("no such table", msg) && return :statement    # server-text-match-ok: SQLite, as above
  occursin("no such column", msg) && return :statement   # server-text-match-ok: SQLite, as above
  occursin("syntax error", msg) && return :statement     # server-text-match-ok: SQLite, as above
  occursin("integer overflow", msg) && return :statement # server-text-match-ok: SQLite, as above
  # Unrecognized: core maps :unknown onto StatementError, so the umbrella still has no hole.
  return :unknown
end

# The reason as data (#987). SQLite reports no SQLSTATE and no separate fields, and its messages
# name the table and column, never the value (`UNIQUE constraint failed: driver.code`), because a
# bound value never enters SQLite's text — so the whole message is the safe primary.
# #1356: SQLite's "integer overflow" (an integer cast's range guard, `abs()` of the smallest integer, a
# `sum()` past 64 bits) is the overflow PostgreSQL reports as SQLSTATE 22003, so it carries that code.
# On the concrete pool, not the `PormGSQLite` marker: a stand-in pool keeps the default, the
# one-argument form, which reads whichever driver's exception it is handed (#1696).
PormG.backend_error_fields(pool::PormG.ConnectionPool.SQLiteConnectionPool, @nospecialize(e)) =
  e isa SQLite.SQLiteException ? PormG.backend_error_fields(e) : PormG._NO_ERROR_FIELDS
function PormG.backend_error_fields(e::SQLite.SQLiteException)
  msg = _sqlite_msg(e)
  return PormG._error_record(occursin("integer overflow", PormG._phrase_text(msg)) ? "22003" : nothing,  # server-text-match-ok: SQLite's own literal
                             nothing, nothing, nothing, isempty(msg) ? nothing : msg)
end

# Window-function support probe used by src/Dialect.jl.
PormG.backend_sqlite_version(pool::PormGSQLite) = Int(SQLite.C.sqlite3_libversion_number())

# ── Precompile workload: real queries against a throwaway SQLite database ────
#
# This runs in the precompile worker for the EXTENSION's cache — the one place PormG can execute a
# statement at precompile time, because only here is a driver guaranteed to be loaded.
# `src/precompile.jl`'s own workload has no driver, so it stops at `show_query`: it compiles no
# parameter binding, no async fetch path, no row assembly, no `:row`/`:dict`/`:json` shaper and no
# transaction. Running here also means the code is compiled after SQLite and its dependencies have
# loaded, so their methods cannot invalidate it; the PostgreSQL extensions run their workload here
# for that reason (#1732).
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
#   * PostgreSQL gets the query build and the terminals from its own extensions' workloads
#     (`PormG._offline_postgres_workload`, #1732), rendered with `show_query = :sql` on an offline
#     key. Statement execution cannot be driven there without a server, which is this workload's
#     version of Nitro's "no socket" rule: warming it is worth doing, doing it with a live
#     connection is not.
#
# Temp directory and pool are created and torn down INSIDE the workload: a module-body side effect
# would run only in the precompile worker (#203), and the config key must not be serialized.

# The module name is imported too, not just the macros: PrecompileTools 1.0.0 — the declared floor
# until #788 raised it to 1.2 — expands `@setup_workload` into code that names `PrecompileTools` in
# the CALLING module, so the macros alone fail with `UndefVarError: PrecompileTools not defined in
# PormGSQLiteExt` there (caught by CI's floor-resolve job, #574). Kept: the import costs nothing, and
# a floor can move again.
using PrecompileTools: PrecompileTools, @setup_workload, @compile_workload

# Where the workload registers its models with `set_models`, which is what `@import_models` calls
# and the only thing that wires REVERSE relations — without it `delete()` never reaches the
# collector's walk (measured: with bare `Model(...)` here, the application's first `set_models`
# still cost 0.7 s and its first cascading delete 0.8 s; registered here, 0.04 s and 0.02 s).
# `set_models` needs the models as globals of a module, which constrains where that module can be:
#   * not a throwaway `Module()`: precompilation refuses `Core.eval` into any module outside the
#     package being compiled, and 1.12's `setglobal!` cannot create a binding;
#   * so a submodule of this extension, which IS serialized — hence the two rules below.
# Registration records the key and this machine's temp folder in the module's model set (#1607); the
# `finally` below clears that record, so the deleted temp path never reaches the cache image. Nothing
# would read it anyway: the self-healing scan in `Models.ensure_model_initialized` looks only at
# top-level modules, and at models whose `_module` is this one, of which none survive the workload.
module _PrecompileModels
end

@setup_workload begin
  Models = PormG.Models
  CP = PormG.ConnectionPool
  # `QB` is the module's constant (top of file). PrecompileTools 1.2 runs this block at module top level,
  # where assigning it again is "invalid assignment to constant".

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
            name = Models.CharField(max_length = 255, unique = true))
          Race = Models.Model("race",
            raceid = Models.IDField(),
            year = Models.IntegerField(),
            name = Models.CharField(max_length = 255),
            date = Models.DateField(),
            start_at = Models.DateTimeField(null = true))
          Result = Models.Model("result",
            resultid = Models.IDField(),
            driverid = Models.ForeignKey(Driver, pk_field = "driverid", on_delete = "CASCADE"),
            constructorid = Models.ForeignKey(Constructor, pk_field = "constructorid", on_delete = "RESTRICT"),
            grid = Models.IntegerField(),
            points = Models.FloatField())
          # #1602: the set `set_models` reads. Interpolated: the block's macros expand before its
          # `import PormG.Models` runs, so `Models.@models` would not resolve here.
          $(PormG.Models._model_set_declaration([:Driver, :Constructor, :Race, :Result]))
        end)
        # `invokelatest`: the bindings are newer than this code's world, the rule `@import_models`
        # handles the same way (#211).
        Base.invokelatest(Models.set_models, _PrecompileModels, dir)
        Driver, Constructor, Race, Result =
          (Base.invokelatest(getglobal, _PrecompileModels, n) for n in (:Driver, :Constructor, :Race, :Result))

        # The tables come from PormG's own DDL, not a hand-written CREATE: the first draft of this
        # workload wrote its own, left out AUTOINCREMENT, and `bulk_insert` then failed on the
        # missing `sqlite_sequence` table. A workload must exercise the schema migrations produce.
        for m in (Driver, Constructor, Race, Result)
          CP.fetch(pool, PormG.Dialect.create_table(pool, m))
        end

        # ── Writes: row-level, bulk, and inside a transaction ──
        Driver.objects.create("driverid" => 1, "code" => "SEN", "forename" => "Ayrton",
                              "surname" => "Senna", "dob" => PormG.Dates.Date(1960, 3, 21))
        Driver.objects.create("driverid" => 2, "forename" => "Alain", "surname" => "Prost")
        PormG.run_in_transaction(key) do
          Constructor.objects.create("constructorid" => 1, "name" => "McLaren")
          # Any Tables.jl table (#1344); the pipeline past `_bulk_frame` does not specialize on its type.
          QB.bulk_insert(Result.objects,
            (resultid = [1, 2], driverid = [1, 2], constructorid = [1, 1], grid = [1, 2], points = [9.0, 6.0]))
        end
        # A float through `create`, and a `DateTime` on insert and on update (#1732): each value type is
        # its own `validate_field_data` specialization. PormG's own workload compiled the float one
        # before #1732 moved the PostgreSQL terminals into their extensions.
        Result.objects.create("resultid" => 3, "driverid" => 1, "constructorid" => 1, "grid" => 3, "points" => 4.0)
        Race.objects.create("raceid" => 1, "year" => 1988, "name" => "Japanese Grand Prix",
                            "date" => PormG.Dates.Date(1988, 10, 30), "start_at" => PormG.Dates.DateTime(1988, 10, 30, 4, 0))
        Race.objects.filter("raceid" => 1).update("start_at" => PormG.Dates.DateTime(1988, 10, 30, 5, 0))
        # `defaults` built at run time is a `Vector{Pair{String,Any}}` (#1732), on a text lookup and an
        # integer one; both miss and insert.
        Constructor.objects.get_or_create("name" => "Williams"; defaults = Pair{String, Any}["constructorid" => 2])
        Driver.objects.get_or_create("driverid" => 3;
          defaults = Pair{String, Any}["forename" => "Lewis", "surname" => "Hamilton", "dob" => PormG.Dates.Date(1985, 1, 7)])

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
        # The models must not reach the cache image through `_PrecompileModels`, nor this machine's
        # temp folder through its registration record (#1607).
        Core.eval(_PrecompileModels, :(Driver = Constructor = Race = Result = nothing))
        # `invokelatest`: the set is a global the `Core.eval` above made, newer than this code's world.
        record = Base.invokelatest(Models._model_set, _PrecompileModels)
        # The set holds the models themselves (#1606), so its lists are emptied too, or the bindings
        # reset above would still reach the image through it.
        if record !== nothing
          record.key = record.load_root = record.folder = nothing
          empty!(record.models)
          empty!(record.bindings)
        end
        delete!(PormG.config, key)
        CP.close_pool!(pool)
      end
    end
  end
end

end # module PormGSQLiteExt
