# ==============================================================================
# PormGMySQLExt — MySQL through MySQL.jl 2.0 (#1130, in progress)
#
# Loaded when the user runs `using MySQL`. Implements the backend generics declared in `src/Backend.jl`
# for `MySQLConnectionPool` (src/ConnectionPool.jl). MySQL.jl 2.0 is a pure-Julia wire-protocol driver
# on Reseau, the socket layer Postgres.jl uses, so the shapes here follow `ext/PormGPostgresExt.jl`.
#
# Phase 1 of #1130: connections, the pool, statements, transactions, cancellation and error
# classification. No query is rendered for MySQL yet — that is phase 2.
#
# Every method is typed on the concrete `MySQLConnectionPool`, and the classifiers also on the driver's
# exception types, so none shadows core's defaults for the unit suite's mock pools (the hazard
# `backend_classify_error`'s docstring records).
#
# What the phase-0 spike measured (#1130) and this file therefore does:
#   * 2006 "MySQL server has gone away" is raised whether or not the statement ran (a committed INSERT
#     whose reply was lost reports it too), so NO error is retry-safe here until the driver can say
#     "refused before send" (JuliaDatabases/MySQL.jl#248);
#   * closing a socket does not stop a statement on the server, so cancellation is `KILL QUERY` from a
#     second connection;
#   * under TLS an interrupt arrives as a `ProtocolError` with the `InterruptException` dropped
#     (JuliaDatabases/MySQL.jl#247), so an abandoned await is recognised only without TLS until then;
#   * the ERR packet carries an error number, a SQLSTATE and a text — no constraint, table or column
#     field — and several texts quote the value or the statement, so the text is shown only for an
#     allow-list of error numbers.
# ==============================================================================

module PormGMySQLExt

using PormG
import PormG: InvalidConfigurationError, AbstractPormGParam
import MySQL
import MySQL: DBInterface
import Decimals
import TimeZones
import Tables
using Dates

const _Pool = PormG.ConnectionPool.MySQLConnectionPool

# ── Connection info ──────────────────────────────────────────────────────────
#
# The pool carries a libpq-style conninfo built by `Configuration._mysql_conninfo`, every value in
# single quotes with `\` and `'` backslash-escaped. Read back here into MySQL.jl's keywords. A value is
# never echoed in a refusal: the conninfo holds the password.

function _parse_conninfo(s::AbstractString)::Dict{String, String}
  out = Dict{String, String}()
  i = firstindex(s)
  n = lastindex(s)
  while i <= n
    while i <= n && isspace(s[i]); i = nextind(s, i); end
    i > n && break
    eq = findnext('=', s, i)
    eq === nothing && throw(InvalidConfigurationError("MySQL connection info is malformed (a key without `=`)"))
    key = strip(s[i:prevind(s, eq)])
    i = nextind(s, eq)
    buf = IOBuffer()
    if i <= n && s[i] == '\''
      i = nextind(s, i)
      closed = false
      while i <= n
        c = s[i]
        if c == '\\' && nextind(s, i) <= n
          i = nextind(s, i)
          write(buf, s[i])
        elseif c == '\''
          closed = true
          i = nextind(s, i)
          break
        else
          write(buf, c)
        end
        i = nextind(s, i)
      end
      closed || throw(InvalidConfigurationError("MySQL connection info is malformed (an unterminated quote after `$(key)=`)"))
    else
      while i <= n && !isspace(s[i])
        write(buf, s[i])
        i = nextind(s, i)
      end
    end
    out[String(key)] = String(take!(buf))
  end
  return out
end

const _SSL_MODES = ("disabled", "preferred", "required", "verify_ca", "verify_identity")

# A whole, non-negative number, as libpq reads `port` and `connect_timeout`. Never echoes the value.
_conninfo_int(key::String, v::String)::Int = begin
  parsed = tryparse(Int, strip(v))
  (parsed === nothing || parsed < 0) &&
    throw(InvalidConfigurationError("connection.yml: `$(key):` must be a whole, non-negative number for `adapter: MySQL`"))
  parsed
end

# The arguments `DBInterface.connect(MySQL.Connection, host, user, password; kw...)` takes. `reconnect`
# is always `false`: a driver reconnect inside what PormG believes is one session would silently lose
# a `START TRANSACTION` it issued as a plain statement (the Postgres.jl extension refuses it for the
# same reason). `found_rows` makes an UPDATE report the rows it MATCHED, as PostgreSQL and SQLite do,
# rather than the rows whose value changed — `backend_num_affected_rows` is a matched-row count.
function _connect_args(info::Dict{String, String})
  host = get(info, "host", "localhost")
  user = get(info, "user", "")
  password = get(info, "password", nothing)
  kw = Pair{Symbol, Any}[:reconnect => false, :found_rows => true]
  haskey(info, "dbname") && push!(kw, :db => info["dbname"])
  haskey(info, "port") && push!(kw, :port => _conninfo_int("port", info["port"]))
  # `connect_timeout: 0` is libpq's "no timeout"; MySQL.jl takes no timeout as the keyword left out.
  if haskey(info, "connect_timeout")
    t = _conninfo_int("connect_timeout", info["connect_timeout"])
    t > 0 && push!(kw, :connect_timeout => t)
  end
  if haskey(info, "sslmode")
    mode = lowercase(strip(info["sslmode"]))
    mode in _SSL_MODES || throw(InvalidConfigurationError(
      "connection.yml: `sslmode:` for `adapter: MySQL` must be one of $(join(_SSL_MODES, ", "))"))
    push!(kw, :ssl_mode => Symbol(mode))
  end
  haskey(info, "sslrootcert") && push!(kw, :ssl_ca => info["sslrootcert"])
  haskey(info, "sslcert") && push!(kw, :ssl_cert => info["sslcert"])
  haskey(info, "sslkey") && push!(kw, :ssl_key => info["sslkey"])
  return host, user, password, (; kw...)
end

# ── Session ──────────────────────────────────────────────────────────────────
#
# Pinned per connection, so the server's global settings (or a DBA changing them) cannot change what a
# statement means. UTC for the reason the PostgreSQL extensions use it: a `TIMESTAMP` column shifts
# with the session `time_zone` (measured: `14:30` at `+00:00` reads `11:30` at `-03:00`). `sql_mode`
# is MySQL 8.4's default, written out: it keeps `||` a logical OR and `"x"` a string (no `ANSI_QUOTES`,
# no `PIPES_AS_CONCAT`), which the MySQL dialect (#1271) will render against. The collation stays the
# server's: what a text comparison means on MySQL is #1265's decision.
const _SESSION_SQL = "SET time_zone = '+00:00', sql_mode = 'ONLY_FULL_GROUP_BY,STRICT_TRANS_TABLES," *
                     "NO_ZERO_IN_DATE,NO_ZERO_DATE,ERROR_FOR_DIVISION_BY_ZERO,NO_ENGINE_SUBSTITUTION'"

# `major * 10000 + minor * 100 + patch`, the number the capability table's MySQL rows use.
_version_number(v::VersionNumber)::Int = Int(v.major) * 10_000 + Int(v.minor) * 100 + Int(v.patch)

# #1264: MySQL first, 8.4 or newer. MariaDB, TiDB and Vitess answer the same protocol with their own
# version numbers (MariaDB 11.4 would pass an 8.4 check it has nothing to do with), so the server's kind
# is checked before its version.
function _check_server(pool::_Pool, conn::MySQL.Connection)::Nothing
  kind = MySQL.server_kind(conn)
  kind === :mysql || throw(InvalidConfigurationError(
    "this server identifies as $(kind), not MySQL: PormG's MySQL backend supports MySQL 8.4 or newer, " *
    "and MariaDB is planned as a separate backend (#1264)"))
  PormG._require_feature(pool, :supported_server, "Connecting to MySQL";
                         server_version = _version_number(MySQL.server_version(conn)))
  return nothing
end

# A connection with nothing of PormG's applied: the side connection `KILL QUERY` is sent on.
function _dial(pool::_Pool)::MySQL.Connection
  host, user, password, kw = _connect_args(_parse_conninfo(pool.connection_string))
  return DBInterface.connect(MySQL.Connection, host, user, password; kw...)
end

function _open_connection(pool::_Pool)::MySQL.Connection
  conn = _dial(pool)
  try
    _check_server(pool, conn)
    DBInterface.execute(conn, _SESSION_SQL)
  catch
    try; close(conn); catch; end
    rethrow()
  end
  @info "PormG: the MySQL backend is in progress (#1130): connections, transactions and raw SQL work; model queries do not yet" maxlog = 1
  return conn
end

PormG.backend_connect(pool::_Pool; read_only::Bool = false) = _open_connection(pool)

# MySQL.jl has no reset primitive, so a renewal is a new connection; the pool closes the old handle.
PormG.backend_renew_connection(pool::_Pool, conn::MySQL.Connection; read_only::Bool = false) =
  _open_connection(pool)

# `isopen` is local and takes no lock: it sees a transport the driver already knows is closed, not a
# server that dropped the connection silently. That one fails its next statement with 2006, a lost
# connection, so the slot is renewed then (never retried). `MySQL.ping` would ask the server, but it
# takes the connection lock and costs a round trip per acquire.
function PormG.backend_is_alive(pool::_Pool, conn::MySQL.Connection)
  try
    return isopen(conn)
  catch
    return false
  end
end

# Asked through `fetch`, never by leasing a connection here: inside a transaction `fetch` uses the
# transaction's own connection, where a lease would wait for a second slot (and time out on a pool of
# one). `VERSION()` can carry a suffix (`8.4.11-log`); the three numbers lead it.
function PormG.backend_mysql_version(pool::_Pool)::Int
  text = only(collect(PormG.ConnectionPool.fetch(pool, "SELECT VERSION() AS v")))[1]
  m = match(r"^(\d+)\.(\d+)\.(\d+)", String(text))
  m === nothing && throw(InvalidConfigurationError("the MySQL server reported a version PormG cannot read"))
  return _version_number(VersionNumber(parse(Int, m[1]), parse(Int, m[2]), parse(Int, m[3])))
end

# ── Execution ────────────────────────────────────────────────────────────────

# What MySQL.jl cannot bind (measured in the spike): a `Decimals.Decimal` (bound as its exact text,
# which the server parses back: `25.5` stores `25.500` in a DECIMAL(10,3)) and a `ZonedDateTime`
# (bound as its UTC wall time, which a `TIMESTAMP` reads back in this UTC session). The text is
# core's plain fixed-point spelling, never `string(d)`: Decimals 0.5 prints `Decimal(0, 1, 1)` as
# `1E+1`, and PormG supports both majors (README → Requirements).
_bind_value(v::Decimals.Decimal) = PormG.Models._pg_decimal_text(v)
_bind_value(v::TimeZones.ZonedDateTime) = DateTime(TimeZones.astimezone(v, TimeZones.tz"UTC"))
_bind_value(v) = v

function _bind(params)
  resolved = params isa AbstractPormGParam ? params.parameters : params
  (resolved === nothing || isempty(resolved)) && return nothing
  return Any[_bind_value(v) for v in resolved]
end

# DECIMAL text — an optional sign, digits, an optional fraction — as a `Decimals.Decimal`, built with
# the three-argument constructor, the one spelling Decimals 0.4 and 0.5 share (`parse` throws on 0.4.1
# for some inputs), in canonical form: no trailing fractional zeros, never a positive exponent. The
# Postgres.jl extension's `numeric` parser, for the same reason.
const _DECIMAL_TEXT = r"^(-)?(\d+)(?:\.(\d+))?$"

function _mysql_decimal(s::AbstractString)::Decimals.Decimal
  m = match(_DECIMAL_TEXT, s)
  m === nothing && throw(ArgumentError("a MySQL DECIMAL value has no Decimals.Decimal representation"))
  fraction = something(m[3], "")
  c = parse(BigInt, m[2] * fraction)
  iszero(c) && return Decimals.Decimal(0, BigInt(0), 0)
  q = -length(fraction)
  while q < 0 && iszero(c % 10)
    c = div(c, 10)
    q += 1
  end
  return Decimals.Decimal(m[1] === nothing ? 0 : 1, c, q)
end

# A read value as PormG hands it on. MySQL.jl returns zero-copy views into its receive buffer
# (`DataString`, `DataBytes`), which stay valid only as long as the cursor; a row leaves this extension
# as owned Julia values. DECIMAL becomes `Decimals.Decimal` through its exact text, as on PostgreSQL. A
# DATETIME becomes a `DateTime`, which holds milliseconds: a `DATETIME(6)` column loses its last three
# digits here, and what PormG declares for a `DateTimeField` on MySQL is #1270's decision.
_read_value(v::MySQL.DataString) = String(v)
_read_value(v::MySQL.DataBytes) = Vector{UInt8}(v)
_read_value(v::MySQL.DataDecimals.AbstractDecimal) = _mysql_decimal(string(v))
_read_value(v::MySQL.Timestamp) = DateTime(v)
_read_value(v) = v

# A materialized result: the column table core reads through Tables.jl, and the counts the OK packet
# carried. `last_insert_id` is the FIRST id of a multi-row INSERT (measured); what `create` and
# `bulk_insert` do with it is #1266.
struct MySQLResult
  names::Vector{Symbol}
  columns::Vector{AbstractVector}
  nrows::Int
  rows_affected::Int
  last_insert_id::UInt64
end

Tables.istable(::Type{MySQLResult}) = true
Tables.columnaccess(::Type{MySQLResult}) = true
Tables.columns(r::MySQLResult) = NamedTuple{Tuple(r.names)}(Tuple(r.columns))
Tables.schema(r::MySQLResult) = Tables.Schema(r.names, Tuple(eltype(c) for c in r.columns))
Base.length(r::MySQLResult) = r.nrows
# Iterated, a result yields each row as a tuple — what `collect(result)[1][1]` reads in core's
# driver-level callers (`AdvisoryLock`), as a LibPQ or Postgres.jl result answers it.
Base.eltype(::Type{MySQLResult}) = Tuple
Base.iterate(r::MySQLResult, i::Int = 1) =
  i > r.nrows ? nothing : (Tuple(c[i] for c in r.columns), i + 1)

function _materialize(cursor)::MySQLResult
  schema = Tables.schema(cursor)
  names = schema === nothing ? Symbol[] : collect(Symbol, schema.names)
  raw = [Any[] for _ in names]
  for row in cursor, (j, name) in enumerate(names)
    push!(raw[j], _read_value(Tables.getcolumn(row, j)))
  end
  # Narrow each column to the types it holds (`String`, `Union{Missing, Int64}`, …), as a driver
  # result would be, so `DataFrame(result)` gets typed columns.
  columns = AbstractVector[isempty(c) ? c : identity.(c) for c in raw]
  nrows = isempty(raw) ? 0 : length(first(raw))
  return MySQLResult(names, columns, nrows, Int(cursor.rows_affected), UInt64(DBInterface.lastrowid(cursor)))
end

# An interrupt that lands during a read can reach us wrapped in the transport's error with the
# `InterruptException` as its `cause`. Core recognises an abandoned await by the `InterruptException`
# (#315), so it is rethrown bare — the Postgres.jl extension's rule, on the same socket layer. Under
# TLS, MySQL.jl 2.0 drops the cause (JuliaDatabases/MySQL.jl#247), and nothing here can recover it.
function _interrupt_in_causes(e, depth::Int = 4)::Bool
  e isa InterruptException && return true
  depth > 0 || return false
  cause = hasproperty(e, :cause) ? getproperty(e, :cause) : nothing
  return cause !== nothing && _interrupt_in_causes(cause, depth - 1)
end

function _with_bare_interrupt(f)
  try
    return f()
  catch e
    _interrupt_in_causes(e) && !(e isa InterruptException) && throw(InterruptException())
    rethrow()
  end
end

# A statement without parameters goes over the text protocol: MySQL cannot PREPARE every statement
# (`LOCK TABLES`, several `SET` forms, …), and a one-shot prepare costs two round trips besides.
_run(conn::MySQL.Connection, sql::String, bound) = _with_bare_interrupt() do
  cursor = bound === nothing ? DBInterface.execute(conn, sql) : DBInterface.execute(conn, sql, bound)
  _materialize(cursor)
end

PormG.backend_execute(pool::_Pool, conn::MySQL.Connection, sql::String, params) =
  _run(conn, sql, _bind(params))

# The async handle is a plain Task, as the other extensions' are: core only `fetch`es and `wait`s it.
# A MySQL.jl connection serializes concurrent use on its own lock.
function PormG.backend_execute_async(pool::_Pool, conn::MySQL.Connection, sql::String, params)
  bound = _bind(params)
  return Threads.@spawn _run(conn, sql, bound)
end

PormG.backend_num_rows(pool::_Pool, result::MySQLResult) = result.nrows
PormG.backend_num_affected_rows(pool::_Pool, result::MySQLResult) = result.rows_affected

# ── Errors ───────────────────────────────────────────────────────────────────
#
# Keyed on MySQL's error number. SQLSTATE `HY000` covers both a statement's failure and the
# connection's (1205 lock wait timeout, 3024 statement timeout, 2006 server gone), so the class alone
# cannot classify.

# The connection is gone: 2006 server gone away, 2013 lost during query, 4031 dropped by the server for
# inactivity, 1927 killed. Renewed and swept; never retried (see the header).
const _LOST_CONNECTION_ERRNOS = (2006, 2013, 4031, 1927)

# MySQL.jl's own message for a connection it already closed (`checkconn`), raised with `error()`.
# Matched as a prefix on its exact text.
const _CLOSED_CONNECTION_PREFIX = "mysql connection has been closed or disconnected"

const _LOST_SOCKET_ERRNOS = (Libc.ECONNRESET, Libc.EPIPE, Libc.ECONNABORTED, Libc.ENOTCONN,
                             Libc.ETIMEDOUT, Libc.EHOSTUNREACH, Libc.ENETUNREACH)

function _is_lost_connection(e, depth::Int = 4)::Bool
  e isa CompositeException && return any(inner -> _is_lost_connection(inner, depth), e.exceptions)
  # The server or the driver named a number: trust it over any text.
  e isa MySQL.Protocol.ServerError && return Int(e.errno) in _LOST_CONNECTION_ERRNOS
  # A wire fault closes the connection (MySQL.jl's `ProtocolError` contract), and a client read or
  # write timeout closes it too.
  (e isa MySQL.Protocol.ProtocolError || e isa MySQL.Protocol.TimeoutError) && return true
  # server-text-match-ok: MySQL.jl's own client-side text, not a server message
  e isa ErrorException && return Base.startswith(e.msg, _CLOSED_CONNECTION_PREFIX)
  (e isa EOFError || e isa Base.IOError) && return true
  e isa SystemError && return e.errnum in _LOST_SOCKET_ERRNOS
  nameof(typeof(e)) === :NetClosingError && return true
  depth > 0 || return false
  for field in (:cause, :err)
    inner = hasproperty(e, field) ? getproperty(e, field) : nothing
    inner isa Exception && return _is_lost_connection(inner, depth - 1)
  end
  return false
end

PormG.backend_is_connection_error(pool::_Pool, e) = _is_lost_connection(e)

# `backend_is_retry_safe` keeps core's default, `false`, for every MySQL failure: no error MySQL or
# MySQL.jl raises proves the statement never ran (the header). No method is defined, on purpose.

# Permanent: the same configuration fails the same way on every retry. 1045 access denied, 1044 access
# denied to the database, 1049 unknown database, 1130 host not allowed, 3159 an insecure transport the
# account refuses, 1251 / 1524 an authentication plugin the client or server lacks. A refused server
# (#1264) and a bad option are too.
const _PERMANENT_CONNECT_ERRNOS = (1044, 1045, 1049, 1130, 3159, 1251, 1524)

function PormG.backend_is_permanent_connect_error(pool::_Pool, e)
  e isa InvalidConfigurationError && return true
  e isa PormG.BackendCapabilityError && return true
  e isa ArgumentError && return true   # MySQL.jl's refusal of an option value (`ssl_mode`, `tls_version`, …)
  (e isa MySQL.Protocol.AuthError || e isa MySQL.Protocol.UnsupportedAuthError) && return true
  return e isa MySQL.Protocol.ServerError && Int(e.errno) in _PERMANENT_CONNECT_ERRNOS
end

# Constraint violations, by number only. SQLSTATE `23000` is not a fallback: MySQL files 1052 (an
# ambiguous column, a broken query) under it too, and an `IntegrityError` for it would send a caller's
# duplicate-key retry after a statement that can never succeed. 1062 / 1022 / 1586 / 1557 duplicate key,
# 1169 duplicate on a unique constraint, 1761 / 1762 duplicate key through a foreign key, 1451 / 1452
# foreign key (parent / child row), 1216 / 1217 the older foreign-key numbers, 1048 NOT NULL, 3819 CHECK.
const _INTEGRITY_ERRNOS = (1062, 1022, 1586, 1557, 1169, 1761, 1762, 1451, 1452, 1216, 1217, 1048, 3819)
# The server or the session, not the statement: 1205 lock wait timeout, 1213 deadlock, 3024 statement
# timeout, 1317 interrupted (`KILL QUERY`), 1040 too many connections, 1203 / 1226 a user's connection or
# resource limit, 1053 server shutdown.
const _OPERATIONAL_ERRNOS = (1205, 1213, 3024, 1317, 1040, 1203, 1226, 1053)

function PormG.backend_classify_error(pool::_Pool,
                                      e::Union{MySQL.MySQLError, ErrorException, EOFError, Base.IOError, SystemError})
  _is_lost_connection(e) && return :operational
  e isa SystemError && return :operational
  (e isa MySQL.Protocol.AuthError || e isa MySQL.Protocol.UnsupportedAuthError ||
   e isa MySQL.Protocol.TLSNegotiationError) && return :operational
  e isa MySQL.Protocol.ServerError || return :unknown
  errno = Int(e.errno)
  errno in _INTEGRITY_ERRNOS && return :integrity
  (errno in _OPERATIONAL_ERRNOS || e.sqlstate == "40001") && return :operational
  return :statement
end

# The error numbers whose text names objects only — a column, a table, a constraint, a lock — and
# never a value or the statement. Every other text stays in `cause`: 1062 quotes the duplicate value
# (`Duplicate entry 'Senna' for key …`), 1292 and 1366 the rejected value, 1064 the SQL.
const _SAFE_MESSAGE_ERRNOS = (1044, 1046, 1048, 1049, 1050, 1051, 1054, 1091, 1146, 1205, 1213, 1317,
                              1364, 1406, 1451, 1452, 2006, 2013, 3024, 3819, 4031)

function PormG.backend_error_fields(e::MySQL.Protocol.ServerError)
  sqlstate = isempty(e.sqlstate) ? nothing : e.sqlstate
  message = Int(e.errno) in _SAFE_MESSAGE_ERRNOS && !isempty(e.msg) ? e.msg : nothing
  return (sqlstate = sqlstate, constraint = nothing, table = nothing, column = nothing, message = message)
end

# ── Cancellation (#315) ──────────────────────────────────────────────────────

# `KILL QUERY <id>` on a second connection: MySQL has no out-of-band cancel, and closing the socket
# leaves the statement running on the server (measured: an abandoned UPDATE committed later). The
# worker then gets 1317 and its connection stays usable. The id is the driver's integer, never user
# text. Best effort, never throws: the caller is a recovery task.
function PormG.backend_cancel_query!(pool::_Pool, conn::MySQL.Connection)
  id = try
    MySQL.connection_id(conn)
  catch e
    @debug "MySQL: no connection id to cancel" exception = e
    return nothing
  end
  side = nothing
  try
    side = _dial(pool)
    DBInterface.execute(side, "KILL QUERY $(Int(id))")
  catch e
    @debug "MySQL refused the cancel request" exception = e
  finally
    side === nothing || try; close(side); catch; end
  end
  return nothing
end

# A round trip once core's settle wait is over: a connection the cancel left usable answers it, one the
# server or the driver closed does not. Never throws.
function PormG.backend_drain_connection!(pool::_Pool, conn::MySQL.Connection)
  try
    return isopen(conn) && MySQL.ping(conn) === true
  catch
    return false
  end
end

end # module PormGMySQLExt
