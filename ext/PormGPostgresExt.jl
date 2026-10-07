# ==============================================================================
# PormGPostgresExt — PostgreSQL through Postgres.jl (experimental, #788)
#
# Loaded when the user runs `using Postgres`. Implements the backend generics declared in
# `src/Backend.jl` for pools built with `postgres_driver: Postgres` — `PostgresConnectionPool{:postgres}`.
# Postgres.jl is a pure-Julia wire-protocol driver (no libpq), so nothing here is shared with
# `ext/PormGLibPQExt.jl` except the contract.
#
# Every method is typed on `PostgresConnectionPool{:postgres}`, and — wherever the LibPQ extension
# types its second argument (`conn::LibPQ.Connection`, `e::LibPQ.Errors.LibPQException`) — on a
# Postgres.jl type too. The LibPQ methods are typed on the `PormGPostgres` marker, so the pool type
# alone makes these strictly more specific; an untyped second argument where LibPQ types one would
# be ambiguous once both extensions are loaded (#785). `test/unit/test_postgres_ext.jl` pins both.
#
# Known gaps, documented rather than worked around: multi-statement SQL handed to `fetch` (Postgres.jl
# runs every statement over the extended protocol — JuliaDatabases/Postgres.jl#23; the migration
# runner cuts its plan entries into single statements for exactly that reason, #841),
# `passfile`/`hostaddr`/Unix sockets (unsupported by Postgres.jl), and no COPY row count from the
# driver (counted here instead).
# ==============================================================================

module PormGPostgresExt

using PormG
import PormG: PormGPostgresParam, InvalidConfigurationError
import Postgres
import Postgres: DBInterface
import Decimals
import TimeZones
using Dates

const _Pool = PormG.ConnectionPool.PostgresConnectionPool{:postgres}

# ── Session ──────────────────────────────────────────────────────────────────
#
# LibPQ.jl opens every connection with `-c DateStyle=ISO,YMD -c TimeZone=UTC`, and PormG's SQL has
# always run under it: `::date` on a timestamptz, `date_trunc`, `EXTRACT` and friends evaluate in UTC.
# Decoding to UTC alone would not reproduce that, so the session gets the same settings. The user's
# own `options` come AFTER ours, so a deliberate `-c TimeZone=…` still wins (with LibPQ.jl a user
# `options=` silently replaced the UTC setting instead).
const _SESSION_OPTIONS = "-c DateStyle=ISO,YMD -c TimeZone=UTC"

_session_options(user::Union{Nothing, AbstractString}) =
  (user === nothing || isempty(strip(user))) ? _SESSION_OPTIONS : string(_SESSION_OPTIONS, " ", user)

# Postgres.jl reports every server NOTICE as a `@warn`. libpq leaves them on stderr, and PormG's
# migrations issue `DROP … IF EXISTS` and friends on purpose, so a warning per notice is noise that
# also breaks `@test_logs`. Notices stay available at debug level.
struct _PormGStyle <: Postgres.AbstractPostgresStyle end

function Postgres.notice_callback(::_PormGStyle, notice)
  msg = get(notice, "M", "")
  isempty(msg) || @debug "PostgreSQL notice" message = msg
  return nothing
end

# ── Connection-string preflight ──────────────────────────────────────────────
#
# The LibPQ extension's rules (#657, #662), applied to what Postgres.jl parsed. Postgres.jl's own parse
# errors can quote the fragment they choked on — which may be a password (JuliaDatabases/Postgres.jl#22)
# — and a failure here becomes `PoolConnectError.cause`, so nothing from the string is echoed unmasked.

# libpq keyword names. A parse error that names one of these may say which, because a keyword is
# never a secret; any other quoted token might be a fragment of a password.
const _CONNINFO_KEYWORDS = (
  "host", "hostaddr", "port", "dbname", "user", "password", "passfile", "channel_binding",
  "connect_timeout", "client_encoding", "options", "application_name", "fallback_application_name",
  "keepalives", "keepalives_idle", "keepalives_interval", "keepalives_count", "tcp_user_timeout",
  "replication", "gssencmode", "sslmode", "requiressl", "sslcompression", "sslcert", "sslkey",
  "sslpassword", "sslcertmode", "sslrootcert", "sslcrl", "sslcrldir", "sslsni", "requirepeer",
  "ssl_min_protocol_version", "ssl_max_protocol_version", "krbsrvname", "gsslib", "gssdelegation",
  "service", "target_session_attrs", "load_balance_hosts", "sslnegotiation",
)

# Where Postgres.jl's messages put a KEY: before `=` in a quoted `key=value`, or quoted after "for
# connection parameter". A lone quoted word elsewhere (`connection parameter "horse" is missing '='`)
# may be a password fragment even when it spells a keyword (`password=my service`), so it never counts.
const _KEYWORD_POSITIONS = (
  r"^connection parameter \"([a-z_]+)=",
  r"for connection parameter \"([a-z_]+)\"",
)

# Mask everything between the first and the last `"`, as the LibPQ extension does for libpq's
# messages: masking quote PAIRS would leak a value that itself contains a `"`.
function _mask_quoted(msg::AbstractString)::String
  first_q = findfirst('"', msg)
  first_q === nothing && return PormG.Configuration.redact_secret(msg)
  last_q = findlast('"', msg)
  tail = last_q == first_q ? "" : msg[nextind(msg, last_q):end]
  return PormG.Configuration.redact_secret(msg[1:first_q] * "****\"" * tail)
end

function _parse_failure(e)::InvalidConfigurationError
  base = "the PostgreSQL connection string could not be parsed"
  # Only a driver-authored message is shown, and only masked. Anything else — a `URIs.ParseError`
  # quotes the user info it rejected — is reduced to its type.
  e isa ArgumentError || e isa Postgres.PostgresInterfaceError ||
    return InvalidConfigurationError("$(base) ($(nameof(typeof(e))))")
  msg = e.msg
  keyword = ""
  for pattern in _KEYWORD_POSITIONS
    m = match(pattern, msg)
    if m !== nothing && m[1] in _CONNINFO_KEYWORDS
      keyword = " (parameter `$(m[1])`)"
      break
    end
  end
  return InvalidConfigurationError("$(base): $(_mask_quoted(msg))$(keyword)")
end

# Case-insensitive, as `Postgres.parse_dsn` decides it: `POSTGRESQL://…` is parsed as a URL too.
_is_url(s::AbstractString) = (l = lowercase(s); startswith(l, "postgresql://") || startswith(l, "postgres://"))

# Fields a URL may legitimately carry an `@` in: the credentials themselves and free text.
const _URL_AT_OK_FIELDS = (:user, :password, :application_name)

# One raw URL query parameter — `?` or `&`, a keyword, `=`, the value up to the next `&` — as the LibPQ
# extension splits it for #662. The RAW text, before percent-decoding, is the point: an encoded `%40`
# never counts as an `@`.
const _URL_QUERY_PARAM_RE = r"[?&]([^=&]*)=([^&]*)"

_pct_decode(s::AbstractString) =
  replace(s, r"%[0-9A-Fa-f]{2}" => h -> string(Char(parse(UInt8, h[2:3]; base = 16))))

function _checked_params(conn_str::AbstractString)::Postgres.ConnectionParams
  # First: a NUL never reaches the parser, and its error would quote the whole string.
  '\0' in conn_str && throw(InvalidConfigurationError(
    "the PostgreSQL connection string contains a NUL character, which a PostgreSQL connection string cannot carry"))
  params = try
    Postgres.parse_dsn(String(conn_str))
  catch e
    e isa InterruptException && rethrow()
    throw(_parse_failure(e))
  end
  # `reconnect=true` would let Postgres.jl reopen a dropped connection in the middle of a transaction
  # PormG opened with a raw `BEGIN` — the rest of the transaction would run in autocommit. The pool
  # already renews dead connections itself.
  params.reconnect && throw(InvalidConfigurationError(
    "the PostgreSQL connection string sets `reconnect`; PormG renews dead connections itself, and a " *
    "driver-level reconnect inside a transaction would silently continue it in autocommit"))
  startswith(params.host, "/") && throw(InvalidConfigurationError(
    "the Postgres.jl driver does not support Unix-socket hosts; use a TCP host, or `postgres_driver: LibPQ`"))
  # #657/#662: an `@` outside the credentials is a password that was not percent-encoded, spilled
  # into a field a later error would quote.
  if _is_url(conn_str)
    for f in fieldnames(Postgres.ConnectionParams)
      f in _URL_AT_OK_FIELDS && continue
      v = getfield(params, f)
      (v isa AbstractString && occursin('@', v)) && throw(InvalidConfigurationError(
        "the PostgreSQL connection URL's `$(f)` contains an `@`. If it came from a URL password, " *
        "percent-encode the password's `@` as %40, `/` as %2F and `?` as %3F"))
    end
    # #662's second half (security review): a password tail can span SEVERAL query options, and only
    # the last one receives the `@` — `u:1234/x?gssencmode=SEC&application_name=@h/db` leaves `SEC` in
    # an earlier option, which Postgres.jl echoes when it validates it (`invalid gssencmode: sec`). So
    # an allowed `@` is refused too when it looks like the end of a password: nothing before it, or a
    # host tail after it — nothing, or a `/`, `?`, `:` or `,`. `user=me@server` carries none of those.
    # The scan starts at the first `?`: before it is the authority, where a legitimate password may
    # hold `&k=v` of its own (security re-review).
    query_start = findfirst('?', conn_str)
    query = query_start === nothing ? "" : conn_str[query_start:end]
    for m in eachmatch(_URL_QUERY_PARAM_RE, query)
      raw = m.captures[2]
      at = findlast('@', raw)
      at === nothing && continue
      tail = _pct_decode(raw[nextind(raw, at):end])
      if at == firstindex(raw) || isempty(tail) || any(in("/?:,"), tail)
        # Named only when it is one of libpq's keywords: in the spill this check exists for, the
        # "keyword" can itself come from the password.
        keyword = lowercase(_pct_decode(m.captures[1]))
        named = keyword in _CONNINFO_KEYWORDS ? "`$(keyword)` option" : "query"
        throw(InvalidConfigurationError(
          "the PostgreSQL connection URL's $(named) ends in what looks like a host: an unencoded `@` " *
          "followed by a host, port or path. If it came from a URL password, percent-encode the " *
          "password's `/` as %2F, `?` as %3F and `@` as %40"))
      end
    end
  end
  return params
end

function _with_session_options(params::Postgres.ConnectionParams)::Postgres.ConnectionParams
  return Postgres.ConnectionParams(
    (f === :options ? _session_options(params.options) : getfield(params, f)
     for f in fieldnames(Postgres.ConnectionParams))...)
end

# ── Result types ─────────────────────────────────────────────────────────────
#
# Registered on every connection so rows decode to the types PormG already receives from LibPQ.jl
# (Dialect.jl, value_repr.jl): `Decimals.Decimal`, `ZonedDateTime` in UTC, `DateTime` to the
# millisecond, `bpchar` without its padding, and String for uuid/json/jsonb.

const _UTC = TimeZones.TimeZone("UTC")

# `numeric` text: an optional sign, digits, an optional fraction — never an exponent. Built with the
# three-argument constructor, the one spelling Decimals 0.4 and 0.5 share (Dialect.jl
# `_parse_sqlite_decimal`), in canonical form: no trailing fractional zeros, never a positive exponent.
const _NUMERIC_TEXT = r"^(-)?(\d+)(?:\.(\d+))?$"

function _pg_numeric(s::AbstractString, _registry = nothing)::Decimals.Decimal
  m = match(_NUMERIC_TEXT, s)
  m === nothing && throw(ArgumentError(
    "PostgreSQL numeric value $(repr(s)) has no Decimals.Decimal representation; cast it to text in the query"))
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

# ISO timestamps as the session above renders them. The fraction is truncated to milliseconds, the
# precision of `DateTime` and of LibPQ.jl's result.
const _TIMESTAMP_TEXT = r"^(\d{4,})-(\d\d)-(\d\d) (\d\d):(\d\d):(\d\d)(?:\.(\d{1,6}))?$"
const _TIMESTAMPTZ_TEXT = r"^(\d{4,})-(\d\d)-(\d\d) (\d\d):(\d\d):(\d\d)(?:\.(\d{1,6}))?([+-])(\d\d)(?::(\d\d))?(?::(\d\d))?$"

_ms(fraction) = fraction === nothing ? 0 : parse(Int, rpad(fraction, 3, '0')[1:3])

_datetime(m) = DateTime(parse(Int, m[1]), parse(Int, m[2]), parse(Int, m[3]),
                        parse(Int, m[4]), parse(Int, m[5]), parse(Int, m[6]), _ms(m[7]))

# `±infinity` maps to `typemax`/`typemin(DateTime)`, as LibPQ.jl maps it.
_pg_infinity(s::AbstractString) = s == "infinity" ? typemax(DateTime) : s == "-infinity" ? typemin(DateTime) : nothing

function _pg_timestamp(s::AbstractString, _registry = nothing)::DateTime
  inf = _pg_infinity(s)
  inf === nothing || return inf
  m = match(_TIMESTAMP_TEXT, s)
  m === nothing && throw(ArgumentError(
    "PostgreSQL timestamp value $(repr(s)) has no DateTime representation; cast it to text in the query"))
  return _datetime(m)
end

function _pg_timestamptz(s::AbstractString, _registry = nothing)::TimeZones.ZonedDateTime
  inf = _pg_infinity(s)
  inf === nothing || return TimeZones.ZonedDateTime(inf, _UTC)
  m = match(_TIMESTAMPTZ_TEXT, s)
  m === nothing && throw(ArgumentError(
    "PostgreSQL timestamptz value $(repr(s)) has no ZonedDateTime representation; cast it to text in the query"))
  offset = parse(Int, m[9]) * 3600 + parse(Int, something(m[10], "0")) * 60 + parse(Int, something(m[11], "0"))
  m[8] == "-" && (offset = -offset)
  return TimeZones.ZonedDateTime(_datetime(m) - Second(offset), _UTC)
end

_pg_bpchar(s::AbstractString, _registry = nothing)::String = rstrip(s, ' ')

function _register_types!(conn::Postgres.Connection)
  Postgres.register_type!(conn, 1700, Decimals.Decimal; parser = _pg_numeric)                # numeric
  Postgres.register_type!(conn, 1184, TimeZones.ZonedDateTime; parser = _pg_timestamptz)     # timestamptz
  Postgres.register_type!(conn, 1114, DateTime; parser = _pg_timestamp)                      # timestamp
  Postgres.register_type!(conn, 1042, String; parser = _pg_bpchar)                           # bpchar
  for oid in (2950, 114, 3802)                                                               # uuid, json, jsonb
    Postgres.register_type!(conn, oid, String)
  end
  # inet, cidr (#28). Already `String` through Postgres.jl's unknown-oid fallback; pinned so a future
  # default registry entry cannot change the read type away from LibPQ's.
  for oid in (869, 650)
    Postgres.register_type!(conn, oid, String)
  end
  return conn
end

# ── Connections ──────────────────────────────────────────────────────────────

function _open_connection(pool::_Pool)::Postgres.Connection
  params = _with_session_options(_checked_params(pool.connection_string))
  conn = DBInterface.connect(Postgres.Connection, params; style = _PormGStyle())
  try
    _register_types!(conn)
  catch
    close(conn)
    rethrow()
  end
  @info "PormG: the Postgres.jl PostgreSQL driver is experimental (postgres_driver: Postgres)" maxlog = 1
  return conn
end

PormG.backend_connect(pool::_Pool; read_only::Bool = false) = _open_connection(pool)

# Postgres.jl has no reset primitive, so a renewal is a new connection. The pool closes the old
# handle itself (`_renew_or_discard_connection!`); on the fetch-retry path it is already dead.
PormG.backend_renew_connection(pool::_Pool, conn::Postgres.Connection; read_only::Bool = false) =
  _open_connection(pool)

# `isvalid` reads whatever already arrived without blocking (Postgres.jl #14), so a backend the server
# terminated while the connection sat idle is seen here — the #442 case the LibPQ extension needs
# `PQconsumeInput` for. It answers `true` WITHOUT checking while another task holds the connection's
# lock, so it says nothing about a connection with a statement in flight; core only asks about idle
# or settled ones.
function PormG.backend_is_alive(pool::_Pool, conn::Postgres.Connection)
  try
    return Postgres.isvalid(conn)
  catch
    return false
  end
end

# ── Execution ────────────────────────────────────────────────────────────────

# A bare `Vector{UInt8}` parameter is a list of small integers to PormG (`filter("x__in" => UInt8[1, 2])`,
# Kernel.jl `PormGBytes`) — LibPQ renders it as an array literal — but Postgres.jl binds it as `bytea`.
# Binary payloads never arrive bare: core has already turned a `PormGBytes` into hex text.
_bind_value(v::AbstractVector{UInt8}) = Vector{Int}(v)
_bind_value(v) = v

function _bind(params)
  resolved = params isa PormGPostgresParam ? params.parameters : params
  resolved === nothing && return nothing
  return map(_bind_value, resolved)
end

# An interrupt that lands during a TLS read reaches us wrapped in the TLS layer's own error, with the
# `InterruptException` as its `cause`. Core recognises an abandoned await by the `InterruptException`
# (#315), so it is rethrown bare. The chain is walked a few levels deep and nothing driver-specific is
# named.
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

_run(conn::Postgres.Connection, sql::String, params) = _with_bare_interrupt() do
  params === nothing ? DBInterface.execute(conn, sql) : DBInterface.execute(conn, sql, params)
end

PormG.backend_execute(pool::_Pool, conn::Postgres.Connection, sql::String, params) =
  _run(conn, sql, _bind(params))

# The async handle is a plain Task, as the SQLite extension's is: core only `fetch`es and `wait`s it.
# A Postgres.jl connection serializes concurrent use on its own lock.
function PormG.backend_execute_async(pool::_Pool, conn::Postgres.Connection, sql::String, params)
  bound = _bind(params)
  return Threads.@spawn _run(conn, sql, bound)
end

PormG.backend_num_rows(pool::_Pool, result) = length(result)

# Postgres.jl reports `nothing` for a command tag without a count (CREATE, SET, …); core needs an Int.
PormG.backend_num_affected_rows(pool::_Pool, result) = something(Postgres.rows_affected(result), 0)

# ── Errors ───────────────────────────────────────────────────────────────────

# SQLSTATEs that mean the backend is gone and the statement never ran — the same set, for the same
# reasons, as the LibPQ extension's `_PG_LOST_CONNECTION_ERRORS` (08007, 08P01, 57014, 57P04, 40001,
# 40P01 and 25P03 are excluded there, and here).
const _LOST_CONNECTION_CODES = ("08000", "08001", "08003", "08004", "08006", "57P01", "57P02", "57P03", "57P05")

# Postgres.jl's own message for a connection it already closed. Matched as a PREFIX: its other
# interface errors (a parameter-count mismatch) quote the SQL, which is user text.
const _CLOSED_CONNECTION_PREFIX = "postgres connection has been closed or disconnected"

const _LOST_SOCKET_ERRNOS = (Libc.ECONNRESET, Libc.EPIPE, Libc.ECONNABORTED, Libc.ENOTCONN)

function _is_lost_connection(e, depth::Int = 4)::Bool
  e isa CompositeException && return any(inner -> _is_lost_connection(inner, depth), e.exceptions)
  # The server named a code: trust it over any text (a DETAIL can quote stored user data).
  e isa Postgres.Error && return e.code in _LOST_CONNECTION_CODES
  e isa Postgres.PostgresInterfaceError && return startswith(e.msg, _CLOSED_CONNECTION_PREFIX)
  (e isa EOFError || e isa Base.IOError) && return true
  # The socket layer (Reseau) reports a reset or a closed socket as a `SystemError` carrying the errno,
  # or as its own `NetClosingError` — matched by name, so the extension never depends on Reseau.
  e isa SystemError && return e.errnum in _LOST_SOCKET_ERRNOS
  nameof(typeof(e)) === :NetClosingError && return true
  depth > 0 || return false
  # Wrappers keep the underlying failure in `.cause` (the TLS layer) or `.err` (Reseau's `OpError`).
  for field in (:cause, :err)
    inner = hasproperty(e, field) ? getproperty(e, field) : nothing
    inner isa Exception && return _is_lost_connection(inner, depth - 1)
  end
  return false
end

PormG.backend_is_connection_error(pool::_Pool, e) = _is_lost_connection(e)

# Permanent: the same configuration fails the same way on every retry.
const _PERMANENT_CONNECT_CODES = ("28P01", "28000", "3D000")  # bad password, no such role, no such database

function PormG.backend_is_permanent_connect_error(pool::_Pool, e)
  e isa InvalidConfigurationError && return true
  return e isa Postgres.Error && e.code in _PERMANENT_CONNECT_CODES
end

const _OPERATIONAL_CLASSES = ("08", "40", "53", "55", "57")

# Typed on the driver's exception types — never on `Exception`, which would overlap the LibPQ
# extension's `LibPQException` method and be ambiguous with both loaded.
function PormG.backend_classify_error(pool::_Pool,
                                      e::Union{Postgres.Error, Postgres.PostgresInterfaceError, EOFError, Base.IOError, SystemError})
  _is_lost_connection(e) && return :operational
  e isa SystemError && return :operational   # e.g. ETIMEDOUT: the socket, not the statement
  e isa Postgres.Error || return :unknown
  isempty(e.code) && return :operational   # the driver's own protocol error: the session is suspect
  class = first(e.code, 2)
  class == "23" && return :integrity
  class in _OPERATIONAL_CLASSES && return :operational
  return :statement
end

# The reason as data (#987): the server's ErrorResponse fields, which Postgres.jl keeps one by one.
# `detail`, `hint`, `where` and `internal_query` are never copied — they quote the row or the
# statement. An empty `code` is the driver's own protocol error, which has no SQLSTATE.
# `PostgresInterfaceError` gets the default (no fields): its text can quote the SQL.
function PormG.backend_error_fields(e::Postgres.Error)
  sqlstate = isempty(e.code) ? nothing : e.code
  return (sqlstate = sqlstate, constraint = e.constraint, table = e.table, column = e.column,
          message = PormG._safe_server_message(sqlstate, e.message))
end

# ── Cancellation (#315) ──────────────────────────────────────────────────────

# Out-of-band, on its own socket, safe while another task is inside `execute`. Never `isopen(conn)`
# here: it takes the connection lock the running statement holds.
function PormG.backend_cancel_query!(pool::_Pool, conn::Postgres.Connection)
  try
    Postgres.cancel_query!(conn)
  catch e
    @debug "PostgreSQL refused the cancel request" exception = e
  end
  return nothing
end

# Postgres.jl always reads a response through ReadyForQuery or closes the socket, so once core's settle
# wait is over, "still valid" means clean. Never throws: the caller is a detached recovery task.
function PormG.backend_drain_connection!(pool::_Pool, conn::Postgres.Connection)
  try
    return Postgres.isvalid(conn)
  catch
    return false
  end
end

# ── COPY (#670) ──────────────────────────────────────────────────────────────

# Postgres.jl's `copy_from` does not report the `COPY n` count, so the records are counted from the
# payload: newlines outside RFC 4180 quotes (a doubled `""` is an escaped quote), plus a final record
# without one. Exact for what core sends — `FORMAT CSV, HEADER FALSE`, strings force-quoted
# (execution_bulk.jl `bulk_copy`) — where a quoted string may hold a raw newline.
function _csv_record_count(payload::AbstractString)::Int
  count = 0
  quoted = false
  last = '\n'
  for c in payload
    if c == '"'
      quoted = !quoted
    elseif c == '\n' && !quoted
      count += 1
    end
    last = c
  end
  return isempty(payload) || last == '\n' ? count : count + 1
end

# The count is exact for core's own COPY (`bulk_copy`). A caller of `fetch_copy` that sends another
# shape — `HEADER true`, `FORMAT text` or `binary`, a custom `QUOTE` — gets the CSV record count of
# what it sent, which can differ from the server's; documented as a known gap until Postgres.jl reports
# the tag. Chunks may be strings or bytes, as LibPQ.jl's `CopyIn` accepts both.
function _copy_payload(data_itr)::Vector{UInt8}
  buffer = IOBuffer()
  for chunk in (data_itr isa Union{AbstractString, AbstractVector{UInt8}} ? (data_itr,) : data_itr)
    # Anything else would be written as its raw bytes; LibPQ.jl's `CopyIn` refuses it too.
    chunk isa Union{AbstractString, AbstractVector{UInt8}} ||
      throw(ArgumentError("COPY data chunks must be strings or bytes; got a $(typeof(chunk))"))
    write(buffer, chunk)
  end
  return take!(buffer)
end

function PormG.backend_copy_in!(pool::_Pool, conn::Postgres.Connection, sql::String, data_itr)::Int
  payload = _copy_payload(data_itr)
  Postgres.copy_from(conn, sql, payload)
  return _csv_record_count(String(payload))
end

end # module PormGPostgresExt
