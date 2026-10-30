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
# The driver decides what it accepts: `Postgres.parse_dsn` reads the string as the user wrote it, and
# a string it parses meets no refusal from PormG's tables (#1247) — tables copied from one release must
# never refuse what a later one accepts. Only when the driver refuses does PormG tokenize the string
# and check it against Postgres.jl's rules, to NAME the bad parameter from its own parse, never from
# the text of the driver's message: one new message shape in a Postgres.jl release turned `main` red
# (#1233, #1235). The tokenizer follows Postgres.jl's grammar, which is not libpq's (`;` separates
# parameters too, and keys are lower-cased). PormG's own policy — the LibPQ extension's rules (#657,
# #662), `reconnect`, Unix sockets — is then applied to what Postgres.jl parsed. A failure here becomes
# `PoolConnectError.cause`, so no value is ever echoed — a value may be a password.

# libpq keyword names.
const _CONNINFO_KEYWORDS = (
  "host", "hostaddr", "port", "dbname", "user", "password", "passfile", "channel_binding",
  "connect_timeout", "client_encoding", "options", "application_name", "fallback_application_name",
  "keepalives", "keepalives_idle", "keepalives_interval", "keepalives_count", "tcp_user_timeout",
  "replication", "gssencmode", "sslmode", "requiressl", "sslcompression", "sslcert", "sslkey",
  "sslpassword", "sslcertmode", "sslrootcert", "sslcrl", "sslcrldir", "sslsni", "requirepeer",
  "ssl_min_protocol_version", "ssl_max_protocol_version", "krbsrvname", "gsslib", "gssdelegation",
  "service", "target_session_attrs", "load_balance_hosts", "sslnegotiation",
)

# The keywords Postgres.jl accepts — its `KNOWN_PARAMS`, then the libpq keywords it accepts and ignores
# (`IGNORED_PARAMS`); both tables are the same in Postgres.jl 2.2.2 and 2.3.0. PormG's own
# copy, because the WORDING of a refusal is PormG's: a libpq keyword missing here is named as one this
# driver does not support. A release that accepts more still connects, because the table is read
# only after the driver refused (#1247); the new keyword is a row to add, never a refusal.
const _DRIVER_KEYWORDS = (
  "host", "port", "user", "password", "dbname", "application_name", "options", "connect_timeout",
  "sslmode", "sslrootcert", "sslcert", "sslkey", "sslcapath", "sslservername", "gssencmode",
  "krbsrvname", "gssdelegation", "statement_timeout", "statement_cache_maxsize", "debug", "reconnect",
  "numeric_overflow",
  "channel_binding", "target_session_attrs", "gsslib", "sslnegotiation", "sslcompression", "sslcrl",
  "sslcrldir", "sslpassword", "requiressl", "requirepeer", "hostaddr", "client_encoding", "passfile",
  "service", "fallback_application_name", "keepalives", "keepalives_idle", "keepalives_interval",
  "keepalives_count", "tcp_user_timeout", "load_balance_hosts", "replication",
)

# A refusal names a key only when it is one of these, because a keyword is never a secret. Any other
# word in a key position may be a password fragment — `password=my secret=x` makes `secret` a key — so
# it is referred to by its position instead (Postgres.jl v2.3.0 stopped naming one for the same reason).
const _NAMEABLE_KEYWORDS = Set((_CONNINFO_KEYWORDS..., _DRIVER_KEYWORDS...))

# Ignored keywords Postgres.jl refuses unless set to a no-op value (its `SECURITY_SENSITIVE_IGNORED`):
# dropping `channel_binding=require` silently would leave the caller believing a protection is in place.
const _INERT_VALUES = Dict(
  "channel_binding" => ("", "prefer", "disable"),
  "target_session_attrs" => ("", "any"),
  "gsslib" => ("", "gssapi"),
  "sslnegotiation" => ("", "postgres"),
  "sslcompression" => ("", "0"),
  "sslcrl" => ("",),
  "sslcrldir" => ("",),
  "sslpassword" => ("",),
  "requiressl" => ("", "0"),
  "requirepeer" => ("",),
  "hostaddr" => ("",),
  "client_encoding" => ("", "UTF8", "UTF-8", "utf8", "utf-8"),
  "passfile" => ("",),
  "service" => ("",),
  "load_balance_hosts" => ("", "disable"),
  "replication" => ("", "0", "false", "off"),
)

# Values Postgres.jl parses when it builds its parameters. An empty integer or boolean means "unset";
# `numeric_overflow` has no empty form.
const _INT_KEYWORDS = ("port", "connect_timeout", "statement_timeout", "statement_cache_maxsize")
const _BOOL_KEYWORDS = ("gssdelegation", "debug", "reconnect")
const _BOOL_WORDS = ("1", "on", "true", "yes", "0", "off", "false", "no")
const _NUMERIC_OVERFLOW_VALUES = ("warn", "error")

# One parameter as PormG split it. `label` says where it is ("parameter 3"); `values` holds every
# reading of its value the driver may take — one, except for a URL query value holding a second `=`,
# which URIs 1.7 keeps whole and URIs 1.6 cuts at that `=`.
struct _DsnParam
  label::String
  key::String
  values::Vector{String}
end

# How a refusal refers to a parameter: by name when it is a keyword, otherwise by position.
_param_ref(p::_DsnParam) = p.key in _NAMEABLE_KEYWORDS ? "parameter `$(p.key)`" : p.label

# The example deliberately names no `password=`/`user=` key: `PoolConnectError` renders the message
# through `redact_secret`, which would mask the example into `(password=****)` (as in the LibPQ extension).
const _QUOTING_HINT = ". A value containing spaces must be single-quoted ('two words'); in a URL, " *
                      "percent-encode reserved characters"

_unparseable(what::AbstractString) = throw(InvalidConfigurationError(
  "the PostgreSQL connection string could not be parsed: $(what)$(_QUOTING_HINT)"))

# Postgres.jl's keyword/value grammar, step for step: parameters are separated by whitespace or `;`,
# a key ends at `=`, whitespace or `;` and is lower-cased, whitespace may surround the `=`, and a value
# is either single-quoted or runs to the next whitespace or `;`, with `\` escaping the next character
# in both forms.
function _keyword_dsn_params(dsn::String)::Vector{_DsnParam}
  params = _DsnParam[]
  i = firstindex(dsn)
  stop = lastindex(dsn)
  while i <= stop
    while i <= stop && (isspace(dsn[i]) || dsn[i] == ';')
      i = nextind(dsn, i)
    end
    i > stop && break
    label = "parameter $(length(params) + 1)"
    key_start = i
    while i <= stop && dsn[i] != '=' && !isspace(dsn[i]) && dsn[i] != ';'
      i = nextind(dsn, i)
    end
    key = i == key_start ? "" : lowercase(String(SubString(dsn, key_start, prevind(dsn, i))))
    isempty(key) && _unparseable("$(label) has an empty name")
    while i <= stop && isspace(dsn[i])
      i = nextind(dsn, i)
    end
    # Never named, even when the word spells a keyword: a lone word is most often the second word of an
    # unquoted password (`password=my service`, #1233).
    (i <= stop && dsn[i] == '=') || _unparseable("$(label) has no `=`")
    i = nextind(dsn, i)
    while i <= stop && isspace(dsn[i])
      i = nextind(dsn, i)
    end
    ref = _param_ref(_DsnParam(label, key, String[]))
    buf = IOBuffer()
    if i <= stop && dsn[i] == '\''
      i = nextind(dsn, i)
      closed = false
      while i <= stop
        c = dsn[i]
        if c == '\\'
          i = nextind(dsn, i)
          i <= stop || _unparseable("the value of $(ref) ends in a dangling `\\`")
          write(buf, dsn[i])
          i = nextind(dsn, i)
        elseif c == '\''
          i = nextind(dsn, i)
          closed = true
          break
        else
          write(buf, c)
          i = nextind(dsn, i)
        end
      end
      closed || _unparseable("the quoted value of $(ref) is never closed")
      (i <= stop && !isspace(dsn[i]) && dsn[i] != ';') &&
        _unparseable("the quoted value of $(ref) is followed by more text")
    else
      while i <= stop && !isspace(dsn[i]) && dsn[i] != ';'
        c = dsn[i]
        if c == '\\'
          i = nextind(dsn, i)
          i <= stop || _unparseable("the value of $(ref) ends in a dangling `\\`")
          write(buf, dsn[i])
        else
          write(buf, c)
        end
        i = nextind(dsn, i)
      end
    end
    push!(params, _DsnParam(label, key, [String(take!(buf))]))
  end
  return params
end

# `URIs.unescapeuri` after `URIs.decodeplus`, the decoding Postgres.jl gives a URL's query: `+` is a
# space, and `%` takes the next two characters as hex. `nothing` where URIs throws.
function _decode_query_part(s::AbstractString)::Union{String, Nothing}
  s = replace(s, '+' => ' ')
  occursin('%', s) || return String(s)
  out = IOBuffer()
  io = IOBuffer(s)
  while !eof(io)
    c = read(io, Char)
    if c == '%'
      eof(io) && return nothing
      c1 = read(io, Char)
      eof(io) && return nothing
      c2 = read(io, Char)
      byte = tryparse(UInt8, string(c1, c2); base = 16)
      byte === nothing && return nothing
      write(out, byte)
    else
      write(out, c)
    end
  end
  return String(take!(out))
end

# A URL's query parameters, as `URIs.URI` and `URIs.queryparams` split them for Postgres.jl: the query
# runs from the first `?` to the next `#` — there is none when a `#` comes first — and splits at `&`,
# then at the first `=`. Keys keep their case. The authority is left to the driver, and so is a
# bracketed IPv6 host holding a `?` or `#` — no host does, and URIs reads one there differently. On
# Postgres.jl 2.3.0 a URL it cannot parse is refused with a message that quotes nothing; on 2.2.2
# URIs' own error reaches `_parse_failure`, which masks only what is double-quoted.
function _url_query_params(dsn::String)::Vector{_DsnParam}
  q = findfirst('?', dsn)
  fragment = findfirst('#', dsn)
  (q === nothing || (fragment !== nothing && fragment < q)) && return _DsnParam[]
  q_end = findnext('#', dsn, q)
  query = SubString(dsn, nextind(dsn, q), q_end === nothing ? lastindex(dsn) : prevind(dsn, q_end))
  params = _DsnParam[]
  for entry in split(query, '&'; keepempty = false)
    label = "query parameter $(length(params) + 1)"
    parts = split(entry, '='; limit = 3)
    key = _decode_query_part(parts[1])
    key === nothing && _unparseable("the name of $(label) is not valid percent-encoding")
    raw = length(parts) == 1 ? [""] :
          length(parts) == 2 ? [parts[2]] : unique([string(parts[2], "=", parts[3]), parts[2]])
    values = String[v for v in (_decode_query_part(r) for r in raw) if v !== nothing]
    p = _DsnParam(label, key, values)
    isempty(values) && _unparseable("the value of $(_param_ref(p)) is not valid percent-encoding")
    push!(params, p)
  end
  return params
end

# Whether every `%` in a URL before its query — the user info, host, port and database name —
# starts a two-hex-digit escape; no release of the driver accepts one that does not. On Postgres.jl
# 2.2.2 a bad one in the user info, host or database name reaches `URIs.unescapeuri`, whose Base
# `parse` error names the offending character: one character of a password (#1243). This names the
# fault; `_mask_quoted` is what keeps that character out of any message this does not anticipate.
function _url_escapes_ok(dsn::String)::Bool
  scheme_end = findfirst("://", dsn)
  scheme_end === nothing && return true
  query = findfirst(c -> c == '?' || c == '#', dsn)
  stop = query === nothing ? lastindex(dsn) : prevind(dsn, query)
  i = nextind(dsn, last(scheme_end))
  while i <= stop
    if dsn[i] == '%'
      for _ in 1:2
        i = nextind(dsn, i)
        (i <= stop && isxdigit(dsn[i])) || return false
      end
    end
    i = nextind(dsn, i)
  end
  return true
end

# Whether `lowercase` can read `s`: it throws an `InvalidCharError` that prints the bytes on a malformed
# or overlong sequence — and a percent-decoded URL part can be one, whatever the raw string was.
# A lone surrogate is fine.
_lowercasable(s::AbstractString) = !any(c -> Base.ismalformed(c) || Base.isoverlong(c), s)

function _value_accepted(key::String, v::String)::Bool
  inert = get(_INERT_VALUES, key, nothing)
  inert !== nothing && return v in inert
  key in _INT_KEYWORDS && return isempty(v) || tryparse(Int, v) !== nothing
  # A malformed decoded value is no boolean — the driver's own `lowercase` throws on it.
  key in _BOOL_KEYWORDS && return isempty(v) || (_lowercasable(v) && lowercase(v) in _BOOL_WORDS)
  key == "numeric_overflow" && return v in _NUMERIC_OVERFLOW_VALUES
  return true
end

function _value_refusal(p::_DsnParam)::String
  base = "the PostgreSQL connection string's $(_param_ref(p))"
  inert = get(_INERT_VALUES, p.key, nothing)
  if inert !== nothing
    # The values listed are the driver's own no-op settings, never the user's.
    allowed = ["`$(v)`" for v in inert if !isempty(v)]
    accepts = "only " * join([allowed; "the parameter left out"], ", ", " or ")
    return "$(base) is set to a value the Postgres.jl driver does not support and cannot safely " *
           "ignore (it accepts $(accepts)); `postgres_driver: LibPQ` supports it"
  end
  p.key in _INT_KEYWORDS && return "$(base) is not an integer"
  p.key in _BOOL_KEYWORDS && return "$(base) is not a boolean (on/off, true/false, yes/no, 1/0)"
  return "$(base) must be `warn` or `error`"
end

# Postgres.jl's rules on what PormG split. Every key must be one it accepts; a value is read only from
# a key's LAST occurrence, as the driver keeps it, and is refused only when no reading of it would pass.
function _check_dsn_params(params::Vector{_DsnParam})
  for p in params
    p.key in _DRIVER_KEYWORDS && continue
    p.key in _CONNINFO_KEYWORDS && throw(InvalidConfigurationError(
      "the PostgreSQL connection string sets `$(p.key)`, a libpq parameter the Postgres.jl driver " *
      "does not support; leave it out, or use `postgres_driver: LibPQ`"))
    case_hint = _lowercasable(p.key) && lowercase(p.key) in _NAMEABLE_KEYWORDS ?
                " (parameter names are lower-case)" : ""
    throw(InvalidConfigurationError(
      "the PostgreSQL connection string's $(p.label) is not a connection parameter Postgres.jl " *
      "recognizes$(case_hint)$(_QUOTING_HINT)"))
  end
  last_seen = Dict(p.key => p for p in params)
  for p in params
    last_seen[p.key].label == p.label || continue
    any(v -> _value_accepted(p.key, v), p.values) ||
      throw(InvalidConfigurationError(_value_refusal(p)))
  end
  return nothing
end

# PormG's whole pass over the string: a URL's escapes before its query, then every parameter.
function _check_dsn(dsn::String)
  _is_url(dsn) || return _check_dsn_params(_keyword_dsn_params(dsn))
  _url_escapes_ok(dsn) || throw(InvalidConfigurationError(
    "the PostgreSQL connection URL's user info, host, port or database name is not valid " *
    "percent-encoding: a `%` must start an escape such as %25, which is a literal `%`"))
  return _check_dsn_params(_url_query_params(dsn))
end

# A `Char` as Base's errors print one — `'o'`, `'\''`, `'\x01'` — the way a Base `parse` error names
# the character it rejected: on Postgres.jl 2.2.2 one character of a password (#1243).
const _CHAR_LITERAL = r"'(?:\\(?:'|[^']*)|[^'\\])'"

# Mask every character literal, then everything between the first and the last `"`, as the LibPQ
# extension does for libpq's messages: masking quote PAIRS would leak a value that itself contains a
# `"`. Masking the literals does not depend on the message's shape, so it holds for whichever driver
# and URIs release produced it; PormG's own escape check can only cover the shapes it knows.
function _mask_quoted(msg::AbstractString)::String
  msg = replace(msg, _CHAR_LITERAL => "'****'")
  first_q = findfirst('"', msg)
  first_q === nothing && return PormG.Configuration.redact_secret(msg)
  last_q = findlast('"', msg)
  tail = last_q == first_q ? "" : msg[nextind(msg, last_q):end]
  return PormG.Configuration.redact_secret(msg[1:first_q] * "****\"" * tail)
end

# A rejection PormG's own pass did not anticipate — a value from a `PG*` environment variable, a rule
# a later Postgres.jl adds. Shown masked and naming nothing: no parameter is recovered from the
# driver's text (#1235).
function _parse_failure(e)::InvalidConfigurationError
  base = "the PostgreSQL connection string could not be parsed"
  # Only a driver-authored message is shown, and only masked. Anything else — a `URIs.ParseError`
  # quotes the user info it rejected — is reduced to its type.
  e isa ArgumentError || e isa Postgres.PostgresInterfaceError ||
    return InvalidConfigurationError("$(base) ($(nameof(typeof(e))))")
  return InvalidConfigurationError("$(base): $(_mask_quoted(e.msg))")
end

# Case-insensitive, as `Postgres.parse_dsn` decides it: `POSTGRESQL://…` is parsed as a URL too.
_is_url(s::AbstractString) = (l = lowercase(s); startswith(l, "postgresql://") || startswith(l, "postgres://"))

# The values Postgres.jl accepts when it CONNECTS, compared lower-cased as it compares them. Read off
# the params the driver parsed — PormG's policy on the driver's own result, like `reconnect`, not a
# table run before it (#1247). In the driver's order: `gssencmode` is checked before dialling.
#
# A COPY, pinned to Postgres.jl 2.2.2 and 2.3.0 (#1257): the driver has no constant to read. Its
# `connect` compares inline, in `src/api/API.jl` — the `invalid gssencmode` and `invalid sslmode`
# checks — and both releases accept exactly these. `[compat]` admits any 2.x, so a new release reaches
# CI with no bump: re-read those two checks when one appears. A value it starts accepting (libpq's
# `allow`, `verify-ca`) needs its row here, or PormG refuses a configuration the driver would connect
# with — the #1247 break. The parity fuzz in `test_postgres_ext.jl` cannot see the drift: it compares
# with `Postgres.parse_dsn`, which takes any value for both.
const _CONNECT_TIME_VALUES = (
  :gssencmode => ("disable", "prefer", "require"),
  :sslmode => ("disable", "prefer", "require", "verify-full"),
)

# Fields a URL may legitimately carry an `@` in: the credentials themselves and free text.
const _URL_AT_OK_FIELDS = (:user, :password, :application_name)

# One raw URL query parameter — `?` or `&`, a keyword, `=`, the value up to the next `&` — as the LibPQ
# extension splits it for #662. The RAW text, before percent-decoding, is the point: an encoded `%40`
# never counts as an `@`.
const _URL_QUERY_PARAM_RE = r"[?&]([^=&]*)=([^&]*)"

_pct_decode(s::AbstractString) =
  replace(s, r"%[0-9A-Fa-f]{2}" => h -> string(Char(parse(UInt8, h[2:3]; base = 16))))

# Why the driver refused, in PormG's own words. PormG's pass names the parameter; anything else it
# throws — a defect — is reduced to its type, as `_parse_failure` reduces the driver's: Base's errors
# print their input (security review, #1235). When PormG's pass finds nothing wrong — a value from a
# `PG*` environment variable, a rule a later Postgres.jl adds — the driver's own message is shown
# masked, naming nothing.
function _driver_refusal(dsn::String, e)::InvalidConfigurationError
  try
    _check_dsn(dsn)
  catch named
    named isa InterruptException && rethrow()
    named isa InvalidConfigurationError && return named
    return InvalidConfigurationError(
      "the PostgreSQL connection string could not be parsed ($(nameof(typeof(named))))")
  end
  return _parse_failure(e)
end

# `parse` is the seam a test replaces with a driver release that accepts more than PormG's tables.
function _checked_params(conn_str::AbstractString;
                         parse = Postgres.parse_dsn)::Postgres.ConnectionParams
  # First: a NUL never reaches the parser, and its error would quote the whole string.
  '\0' in conn_str && throw(InvalidConfigurationError(
    "the PostgreSQL connection string contains a NUL character, which a PostgreSQL connection string cannot carry"))
  dsn = String(conn_str)
  # Before anything lower-cases it: a malformed or overlong byte sequence makes `lowercase` throw an
  # `InvalidCharError` that prints the bytes — in our tokenizer and `Postgres.parse_dsn` alike (review
  # finding, #1235). Exactly what `lowercase` refuses, not `isvalid`: a lone surrogate passes
  # `lowercase`, and the driver accepts it.
  _lowercasable(dsn) || throw(InvalidConfigurationError(
    "the PostgreSQL connection string is not valid UTF-8, which a PostgreSQL connection string must be"))
  # The driver first (#1247). Its refusal is explained outside the `catch`, so the exception stack never
  # carries the driver's error, whose message may quote the string — as Postgres.jl 2.3.0 does itself.
  refused = nothing
  params = try
    parse(dsn)
  catch e
    e isa InterruptException && rethrow()
    refused = e
    nothing
  end
  refused === nothing || throw(_driver_refusal(dsn, refused))
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
        named = keyword in _NAMEABLE_KEYWORDS ? "`$(keyword)` option" : "query"
        throw(InvalidConfigurationError(
          "the PostgreSQL connection URL's $(named) ends in what looks like a host: an unencoded `@` " *
          "followed by a host, port or path. If it came from a URL password, percent-encode the " *
          "password's `/` as %2F, `?` as %3F and `@` as %40"))
      end
    end
  end
  # #1242: Postgres.jl takes any `sslmode`/`gssencmode` when it parses, and refuses one only in
  # `connect` — `gssencmode` before dialling, `sslmode` once the socket is open — with a message that
  # echoes the value: in the #662 spill shape, a password's tail with no `@` to catch it above.
  # Refused here instead, before any I/O, by name. An empty value too: the
  # driver keeps it so that an unexpanded `${PGSSLMODE}` fails loudly, and so does this.
  # Under `gssencmode=require` the driver connects over GSS or fails before TLS, and never reads
  # `sslmode`, so a value it would refuse there still connects and is not refused here (review).
  gss = params.gssencmode
  gss_only = gss !== nothing && _lowercasable(gss) && lowercase(gss) == "require"
  for (field, accepted) in _CONNECT_TIME_VALUES
    field === :sslmode && gss_only && continue
    v = getfield(params, field)
    (v === nothing || (_lowercasable(v) && lowercase(v) in accepted)) && continue
    accepts = join(("`$(a)`" for a in accepted), ", ", " or ")
    throw(InvalidConfigurationError(
      "the PostgreSQL connection's `$(field)` (from the connection string or `PG$(uppercase(String(field)))`) " *
      "$(isempty(v) ? "is empty" : "is set to a value the Postgres.jl driver does not support"); " *
      "it accepts $(accepts). `postgres_driver: LibPQ` supports libpq's other modes"))
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
  # tsvector (#1021): a projected `SearchVector` alias, later a `SearchVectorField` column. Its text,
  # as LibPQ reads it, pinned for the reason above.
  Postgres.register_type!(conn, 3614, String)
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

# #1479: a statement runs through the driver's per-connection cache of named prepared statements
# (`statement_cache_maxsize`, an LRU of 100 by default), so a query shape the connection has seen
# skips the Parse and Describe round trip; ~26% off a two-join read. A statement the connection has
# not seen costs two extra round trips, once. `statement_cache_maxsize=0` in the connection string
# keeps the unnamed statement on every call (a PgBouncer in transaction mode before 1.21 needs it):
# `prepare` with no cache would make an uncached server statement per call instead.
#
# `close!` releases a handle the driver re-prepared outside the cache (an entry evicted between
# `prepare` and `execute`); on a cached handle it is a no-op.
function _execute_prepared(conn::Postgres.Connection, sql::String, params)
  stmt = DBInterface.prepare(conn, sql)
  try
    return params === nothing ? DBInterface.execute(stmt) : DBInterface.execute(stmt, params)
  finally
    DBInterface.close!(stmt)
  end
end

# A cached statement whose result columns changed under it — an `ADD COLUMN` on the table of a
# cached `RETURNING *`, run by any process — is refused at Bind with `cached plan must not change
# result type`. Recognised by its SQLSTATE and the server routine that raises it, as pgjdbc does
# (`willHealViaReparse`): `0A000` alone is every `feature_not_supported`. The routine is a C
# function name, never translated by `lc_messages`.
_is_stale_cached_plan(e::Postgres.Error)::Bool = e.code == "0A000" && e.routine == "RevalidateCachedQuery"
_is_stale_cached_plan(e)::Bool = false

# Outside a transaction nothing ran, so the cache is cleared and the statement prepared again, once
# (asyncpg's rule for `InvalidCachedStatementError`). Inside one the server has already aborted the
# transaction, so a second attempt could only raise 25P02 and hide the cause: the error propagates.
# PormG opens its transactions with a raw `BEGIN`, which the driver's `in_transaction` flag does not
# see, so the server's ReadyForQuery status is read instead — `server_in_transaction`, a field of
# `Postgres.Connection` from 2.2.2 through 2.4.0 that Postgres.jl's own pool reset reads the same
# way. `test_postgresjl_statement_cache.jl` pins it.
function _execute(conn::Postgres.Connection, sql::String, params)
  if conn.statement_cache_maxsize == 0
    return params === nothing ? DBInterface.execute(conn, sql) : DBInterface.execute(conn, sql, params)
  end
  try
    return _execute_prepared(conn, sql, params)
  catch e
    (_is_stale_cached_plan(e) && !(@lock conn.lock conn.server_in_transaction)) || rethrow()
    Postgres.clear_statement_cache!(conn)
    return _execute_prepared(conn, sql, params)
  end
end

_run(conn::Postgres.Connection, sql::String, params) = _with_bare_interrupt() do
  _execute(conn, sql, params)
end

PormG.backend_execute(pool::_Pool, conn::Postgres.Connection, sql::String, params) =
  _run(conn, sql, _bind(params))

# The async handle is a plain Task, as the SQLite extension's is: core only `fetch`es and `wait`s it.
# A Postgres.jl connection serializes concurrent use on its own lock.
function PormG.backend_execute_async(pool::_Pool, conn::Postgres.Connection, sql::String, params)
  bound = _bind(params)
  return Threads.@spawn _run(conn, sql, bound)
end

# #1447: the most parameters Postgres.jl binds in one statement. It writes the Bind message's parameter
# count as a signed `Int16` (`Int16(length(params))`, 2.2.2 through 2.4.0), so 32768 raises an
# `InexactError` before anything is sent, where the protocol and libpq allow 65535. Upstream:
# JuliaDatabases/Postgres.jl#34. A statement PormG splits under the limit (a many-to-many `remove`, a bulk
# write given no positive `chunk_size`) sizes to this.
PormG.backend_postgres_parameter_limit(::_Pool)::Int = Int(typemax(Int16))

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

# The socket under the session failed. A timeout or an unreachable host is here as well as a reset,
# because the LibPQ extension treats libpq's "could not receive data from server: <errno>" the same way
# for any errno. Both drivers renew the slot and sweep on it, and neither retries it (#1042).
const _LOST_SOCKET_ERRNOS = (Libc.ECONNRESET, Libc.EPIPE, Libc.ECONNABORTED, Libc.ENOTCONN,
                             Libc.ETIMEDOUT, Libc.EHOSTUNREACH, Libc.ENETUNREACH)

function _is_lost_connection(e, depth::Int = 4)::Bool
  e isa CompositeException && return any(inner -> _is_lost_connection(inner, depth), e.exceptions)
  # The server named a code: trust it over any text (a DETAIL can quote stored user data).
  e isa Postgres.Error && return e.code in _LOST_CONNECTION_CODES
  # server-text-match-ok: Postgres.jl's own client-side text, not a server message
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

# Did the statement provably NEVER RUN? The gate on `fetch`'s retry (#1042), with the same rule as the
# LibPQ extension's method. Two cases meet it:
#
#   * The server named one of `_LOST_CONNECTION_CODES`, a set defined by this bar.
#   * Postgres.jl refused to send. It raises "…closed or disconnected" from `checkconn` (and from
#     `commit` / `rollback`) after finding the socket closed, before writing anything. PormG refuses a
#     driver-level `reconnect`, so the refusal is never replaced by a silent reopen.
#
# An `EOFError`, an `IOError`, a socket errno or a `NetClosingError` is a lost connection, so it is
# renewed and swept. It can come after the server received the statement, though, so it is not retried.
# Typed on the driver's own exception types, which never overlap LibPQ's `LibPQException` method (see the
# header). Any other type falls to core's default, `false`.
function PormG.backend_is_retry_safe(pool::_Pool, e::Union{Postgres.Error, Postgres.PostgresInterfaceError})
  e isa Postgres.Error && return e.code in _LOST_CONNECTION_CODES
  # server-text-match-ok: Postgres.jl's own client-side text, not a server message
  return startswith(e.msg, _CLOSED_CONNECTION_PREFIX)
end

# A cancelled statement (#1277): 57014 `query_canceled`, as on the LibPQ extension. Neither `fetch`
# nor `with_read_retry` runs it again.
PormG.backend_is_cancellation(e::Postgres.Error) = e.code == "57014"

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
  e isa SystemError && return :operational   # any other errno: the socket, not the statement
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
