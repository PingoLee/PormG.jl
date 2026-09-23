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

# ── Connection-string preflight (#657) ───────────────────────────────────────
#
# A connection string that libpq cannot PARSE leaks its credential two ways, and both happen inside
# `LibPQ.Connection` before PormG can intervene:
#
#   * `LibPQ.conninfo(str)` reports a parse failure through its Memento logger — `error(LOGGER, …)`
#     PRINTS `[error | LibPQ]: missing "=" after "horse" in connection info string` and then throws.
#     libpq's parse messages quote the fragment they choked on, and for an unquoted passphrase
#     (`password=corr3ct horse battery`) or a bad percent-escape (`postgresql://u:p%zzSECRET@h/db` →
#     `invalid percent-encoded token: "p%zzSECRET"`) that fragment IS the password.
#   * A NUL byte never reaches libpq at all: Julia's `Cstring` conversion throws
#     `ArgumentError: embedded NULs are not allowed in C strings: "<the whole DSN>"`.
#
# Either one then became `PoolConnectError.cause`, rendered verbatim beside the redacted
# `connection=` field. So the string is checked HERE, before `LibPQ.Connection` sees it: this is the
# one sink every DSN source reaches — the builder, `url:`, `register_connection`, the resolver —
# which is why the check is not per source. `PQconninfoParse` is called directly (not through
# `LibPQ.conninfo`) precisely to skip the Memento line.
#
# The NUL check must come FIRST: `PQconninfoParse` takes a `Cstring`, so a NUL makes the ccall itself
# throw the leaking `ArgumentError`.
function _preflight_conninfo(conn_str::AbstractString)
  '\0' in conn_str && throw(PormG.InvalidConfigurationError(
    "the PostgreSQL connection string contains a NUL character, which a PostgreSQL connection string cannot carry"))
  err_ref = Ref{Ptr{UInt8}}(C_NULL)
  ci_ptr = LibPQ.libpq_c.PQconninfoParse(conn_str, err_ref)
  # Read the parsed options (`LibPQ.conninfo(::Ptr)` only walks the array — it does not log) before
  # freeing them; they are needed for the host check below.
  parsed = ci_ptr == C_NULL ? LibPQ.ConnectionOption[] :
           try LibPQ.conninfo(ci_ptr) finally LibPQ.libpq_c.PQconninfoFree(ci_ptr) end
  if err_ref[] != C_NULL
    msg = unsafe_string(err_ref[])
    LibPQ.libpq_c.PQfreemem(err_ref[])
    throw(PormG.InvalidConfigurationError(
      "the PostgreSQL connection string could not be parsed: " * _mask_libpq_quoted(chomp(msg)) *
      # The example deliberately names no `password=`/`user=` key: `PoolConnectError` renders this
      # message through `redact_secret`, which would mask the example into `(password=****)`.
      ". A value containing spaces must be single-quoted ('two words'); in a URL, " *
      "percent-encode reserved characters"))
  end
  # A string that PARSES can still leak: libpq splits a URL's userinfo at the FIRST `@`, so a password
  # holding an unencoded `@` — `postgresql://u:pa@ssSEC@localhost/db` — becomes password `pa` and host
  # `ssSEC@localhost`, and the connect failure then quotes that host (`could not translate host name
  # "ssSEC@localhost"`) through LibPQ's Memento logger and into the cause, where no `://` lets
  # `redact_secret` recognise it. The host libpq PARSED is the exact test — no re-derivation of its
  # URL grammar here — and no DNS name or IP address contains an `@`, so refusing costs nothing. A
  # host starting with `/` is a Unix-socket directory, which may legitimately contain one.
  #
  # `port` gets the same treatment, and more strictly: when the password's tail holds a `:` as well
  # (`u:pa@ss:SEC@localhost`) the tail lands in PORT — `"SEC@localhost"` — and libpq's `invalid
  # integer value "…" for connection option "port"` quotes it at connect time. A port entry that is
  # not an integer is refused outright, `@` or not: libpq rejects it anyway, only later and louder.
  #
  # And `dbname` (#658), for the sibling shape: an unencoded `/` in a URL password. libpq's userinfo
  # scan stops at the first `/`, so `postgresql://u:1234/SEC@localhost/db` has NO userinfo — it is
  # host `u`, port `1234`, dbname `SEC@localhost/db` — and `u:pa@ss/SEC@localhost/db` is host `ss`
  # with the same dbname. Both parse cleanly, pass the host and port checks, and a connect error can
  # quote the host or the dbname. Wherever the `/` falls, the `@` that really ended the password lands
  # in the PATH, so a URL whose parsed dbname holds an `@` is refused. (When the tail ALSO holds a `?`,
  # the `@` lands in a query option instead — see the URL-option check after the loop, #662.)
  #
  # Checked BEFORE the loop so the message is the `/` remedy whatever order libpq lists its options
  # in (`u:pa/ss@h` also has port `pa`, and "not an integer" would point at the wrong character).
  #
  # The cost is real and accepted, unlike the host rule's: a database literally named with an `@`
  # cannot be reached through a URL any more — not even as `%40`, because libpq decodes the path
  # before we see it. The keyword form (`dbname=…`) is not ambiguous and stays accepted, so the rule
  # is gated on libpq's own URL test: the two prefixes, case-sensitive, at the very start.
  is_url = startswith(conn_str, "postgresql://") || startswith(conn_str, "postgres://")
  if is_url
    any(opt -> opt.keyword == "dbname" && !ismissing(opt.val) && occursin('@', opt.val), parsed) &&
      throw(PormG.InvalidConfigurationError(
        "the PostgreSQL connection URL's database name contains an `@`. If it came from a URL " *
        "password, percent-encode its `/` as %2F and `@` as %40 — libpq ends the credentials at the " *
        "first `/`. A database whose name really contains an `@` must be given in the keyword form"))
  end
  for opt in parsed
    ismissing(opt.val) && continue
    if opt.keyword == "host"
      any(h -> occursin('@', h) && !startswith(strip(h), '/'), split(opt.val, ',')) &&
        throw(PormG.InvalidConfigurationError(
          "the PostgreSQL connection string's host contains an `@`, which no host name can. If it " *
          "came from a URL password, percent-encode the `@` as %40 — the password ends at the first one"))
    elseif opt.keyword == "port"
      # `lstrip('+')`: libpq reads the port with `strtol`, which takes a sign, so `+5432` is legal.
      any(p -> !all(isdigit, lstrip(strip(p), '+')), split(opt.val, ',')) &&
        throw(PormG.InvalidConfigurationError(
          "the PostgreSQL connection string's port is not an integer. If it came from a URL password " *
          "holding an `@` or `:`, percent-encode them as %40 / %3A"))
    end
  end
  # The last shape of the unencoded-`/` leak (#662): when the password's tail also holds a `?` and a
  # real keyword, `postgresql://u:1234/x?sslmode=SEC@h/db` is host `u`, port `1234`, dbname `x` and
  # sslmode `SEC@h/db`, so the `@` that ended the password lands in that OPTION's value, past every
  # check above. libpq then quotes the value at connect time (`invalid sslmode value: "SEC@h/db"`).
  #
  # So in a URL, an option value may hold an `@` only if its keyword is on an ALLOW-list. A deny-list
  # of the keywords libpq validates was the obvious alternative, and measuring it showed why not:
  # besides the enum options, `service` (`definition of service "…" not found`), `hostaddr`,
  # `keepalives`, `tcp_user_timeout` and `ssl_min_protocol_version` all echo the value before any
  # network I/O, and `client_encoding`, `options` or a certificate path echo it once a server
  # answers. A deny-list leaks through whatever it forgot and whatever a later libpq adds; an
  # allow-list refuses instead, and the keyword form is never ambiguous, so it stays open for a value
  # that really holds an `@`. Runs AFTER the loop so the host/port messages above keep precedence.
  #
  # The allow-list alone is not enough, because the password's tail can span SEVERAL options and only
  # the last one receives the `@`: `u:1234/x?sslmode=SEC&application_name=@h/db` is sslmode `SEC` (no
  # `@`) and application_name `@h/db` (allowed), and libpq still echoes `invalid sslmode value: "SEC"`
  # before any network I/O (review finding). So an allow-listed value is refused too when its `@`
  # looks like the one that ended a password: nothing before it, nothing after it (a URL with no host,
  # `postgresql://u:PASS@`), or a host tail after it — a `/`, `?`, `:` or `,` (path, query, port,
  # second host). `user=me@server`, `a@b.com` and `etl@nightly`
  # carry none of those. The shape test reads the option's RAW query segment (`?kw=<raw>` up to the
  # next `&`, the keyword decoded to match libpq), never the decoded value, and looks at its last raw
  # `@`; only the tail after that `@` is decoded, so an encoded `/` or `:` there still counts. So a value that came from the
  # userinfo is never tested, and a percent-encoded `@` never counts: `p%40ss%2Fx` and a password
  # ending in `%40` stay accepted wherever they sit, and percent-encoding is the remedy for a
  # legitimate value that trips the test. A password that encoded its own `@` but not its `/`
  # (`…&user=a%40b@h/db`) still ends in a raw one, and is refused. (An earlier spelling asked whether
  # the decoded tail occurred verbatim in the string; the userinfo's own `@` satisfied that, so every
  # encoded password ending in `@` was refused — security review, #662.)
  #
  # Known residual: an allow-listed option that takes the `@` with a bare host and no port, path or
  # query after it — `u:1234/x?service=SEC&user=me@h`, from a password that literally ends in
  # `/x?service=SEC&user=me`. It has the same raw shape as Azure's `…?service=prod&user=me@server`, so
  # no rule over the string can tell them apart, and `SEC` is echoed at connect time. The user value
  # itself can reach output too: a server that asks for a password makes LibPQ.jl prompt
  # `Enter password for PostgreSQL user …`, and an auth failure quotes the user, but both need the
  # URL's username to resolve as a reachable host.
  if is_url
    for opt in parsed
      (ismissing(opt.val) || !occursin('@', opt.val)) && continue
      if !(opt.keyword in _URL_AT_OK_KEYWORDS)
        throw(PormG.InvalidConfigurationError(
          "the PostgreSQL connection URL's `$(opt.keyword)` option contains an `@`. " * _URL_AT_REMEDY *
          " A `$(opt.keyword)` value that really contains an `@` must be given in the keyword form"))
      end
      for m in eachmatch(_URL_QUERY_PARAM_RE, conn_str)
        # libpq percent-decodes the keyword too, so `us%65r=` is `user=` (delta review, #662).
        _pct_decode(m.captures[1]) == opt.keyword || continue
        raw = m.captures[2]
        at = findlast('@', raw)   # RAW: an encoded `%40` never counts
        at === nothing && continue
        tail = _pct_decode(raw[nextind(raw, at):end])
        if at == firstindex(raw) || isempty(tail) || any(in("/?:,"), tail)
          throw(PormG.InvalidConfigurationError(
            "the PostgreSQL connection URL's `$(opt.keyword)` option ends in what looks like a host: an " *
            "unencoded `@` followed by a host, port or path. " * _URL_AT_REMEDY *
            " A `$(opt.keyword)` value that really looks like this must percent-encode its `@` as %40"))
        end
      end
    end
  end
  # `C_NULL` with no message is libpq's out-of-memory case; let `LibPQ.Connection` report it.
  return nothing
end

# The URL options whose value may carry an `@` (#662). Every other option is refused in URL form.
const _URL_AT_OK_KEYWORDS = (
  "user",                        # Azure's documented `user=me@server`, and e-mail-shaped role names
  "password",                    # a percent-encoded `@` decodes to one; libpq never echoes a password
  "sslpassword",                 # the same, for the client key's passphrase
  "application_name",            # free text the server stores and never rejects
  "fallback_application_name",   # the same
)

# One raw URL query parameter: `?` or `&`, a keyword, `=`, and the value up to the next `&` — how
# libpq itself splits the query. The raw text, before libpq's percent-decoding, is the point.
const _URL_QUERY_PARAM_RE = r"[?&]([^=&]*)=([^&]*)"

# Byte-wise `%XX` decoding, enough to compare against ASCII keywords and delimiters. A malformed
# escape never reaches it: libpq refuses the string at parse time, on the masked path above.
_pct_decode(s::AbstractString) =
  replace(s, r"%[0-9A-Fa-f]{2}" => h -> string(Char(parse(UInt8, h[2:3]; base = 16))))

# Both #662 refusals share it. libpq ends a URL's credentials at the first `/` OR the first `@`, and
# either way a `?` later in the password carries the rest of it into the query.
const _URL_AT_REMEDY =
  "If it came from a URL password, percent-encode the password's `/` as %2F, `?` as %3F and `@` as " *
  "%40 — libpq ends the credentials at the first `/` or `@`, and a later `?` moves the rest into the query."

# Mask everything libpq quoted. libpq quotes every value it echoes into a parse message, so masking
# from the FIRST `"` to the LAST one removes every echoed fragment at once:
# `missing "=" after "horse" in connection info string` → `missing "****" in connection info string`.
# Masking quote PAIRS instead would leak: the echoed value can itself contain a `"`, and then the
# pairing is off by one and the tail of the value lands outside every pair. Losing the template text
# between the first and last quote is the price, and over-masking is the safe direction.
# `redact_secret` still runs over the result — and again when `PoolConnectError` renders it.
function _mask_libpq_quoted(msg::AbstractString)::String
  first_q = findfirst('"', msg)
  first_q === nothing && return PormG.Configuration.redact_secret(msg)
  last_q = findlast('"', msg)
  tail = last_q == first_q ? "" : msg[nextind(msg, last_q):end]
  return PormG.Configuration.redact_secret(msg[1:first_q] * "****\"" * tail)
end

function _open_connection(pool::PormGPostgres)
  _preflight_conninfo(pool.connection_string)
  return LibPQ.Connection(pool.connection_string)
end

# ── Backend interface methods ────────────────────────────────────────────────

PormG.backend_connect(pool::PormGPostgres; read_only::Bool = false) = _open_connection(pool)

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
    return _open_connection(pool)
  end
end

# Liveness probe. `PQstatus` ALONE is not enough: it reports libpq's *cached* state, and libpq only
# moves a connection to CONNECTION_BAD after an I/O attempt fails. An idle pooled connection attempts
# no I/O, so a backend the server killed — a restart, a failover, a `pg_terminate_backend` sweep —
# keeps reading CONNECTION_OK while its `FATAL: terminating connection due to administrator command`
# sits unread in the socket buffer, and the pool serves the corpse until some later statement finally
# pulls it out (#442).
#
# `PQconsumeInput` is that missing read: non-blocking, no round trip, and on EOF libpq sets
# CONNECTION_BAD — so consuming *before* checking the status makes the status truthful for exactly
# the case the pool cannot otherwise see. Consuming is safe: it only moves already-arrived socket
# data into libpq's input buffer, so a legitimate pending result (the #315 case) is preserved rather
# than discarded. What it does NOT catch is a silent drop that delivered no bytes at all; that one is
# handled reactively by `ConnectionPool._sweep_stale_idle!` once any one slot has actually failed.
#
# `LibPQ.lock(conn)` mirrors `_drain_postgres_connection!` below. It cannot wedge the pool even
# though all four call sites run under `pool.lock`: that semaphore is held for a query's whole life
# by the result task, and a connection with a statement in flight is LEASED — the probe only ever
# runs on a slot the acquirer owns or one whose `available[i]` is true. The abandoned-recovery
# timeout branch is safe from the other side for the same reason: it nils the slot
# (`_discard_connection!(...; close_handle = false)`), so the probe sees `nothing` and skips.
#
# SQLite diverges deliberately: its `backend_is_alive` runs a real `SELECT 1`, so it never had this
# blind spot and needs no equivalent.
function PormG.backend_is_alive(pool::PormGPostgres, conn::LibPQ.Connection)
  try
    return LibPQ.lock(conn) do
      LibPQ.libpq_c.PQconsumeInput(conn.conn) != 0 &&
        LibPQ.status(conn) == LibPQ.libpq_c.CONNECTION_OK
    end
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

# SQLSTATEs that mean THE BACKEND IS GONE AND THE STATEMENT NEVER RAN. That second half is the bar,
# not just "the connection is broken": `backend_is_connection_error` gates `fetch`'s transparent
# retry, so anything listed here may be silently re-executed.
#
# Deliberately EXCLUDED from class 08, which is not uniformly safe:
#   08007 transaction_resolution_unknown — the commit outcome is UNKNOWN. Re-running double-applies.
#   08P01 protocol_violation            — the wire is broken, but the statement may well have run.
# And from class 57:
#   57014 query_canceled  — the session is alive; retrying defeats statement_timeout / an explicit
#                           pg_cancel_backend, and #315 already owns that path.
#   57P04 database_dropped — retrying is futile.
# Elsewhere:
#   40001 / 40P01 serialization_failure / deadlock_detected — the caller must retry the whole
#                           TRANSACTION; re-running one statement on a fresh autocommit session is
#                           the data-corruption bug `fetch`'s retry comment already forbids.
#   25P03 idle_in_transaction_session_timeout — only occurs inside a transaction, where `fetch`
#                           does not retry anyway.
# Every one of those still reaches the caller as an `OperationalError` where that is right, via
# `_PG_OPERATIONAL_CLASSES` below — excluding them here costs no classification fidelity, only the
# retry.
const _PG_LOST_CONNECTION_ERRORS = Union{
  LibPQ.Errors.ConnectionException,                            # 08000
  LibPQ.Errors.SqlclientUnableToEstablishSqlconnection,        # 08001
  LibPQ.Errors.ConnectionDoesNotExist,                         # 08003
  LibPQ.Errors.SqlserverRejectedEstablishmentOfSqlconnection,  # 08004
  LibPQ.Errors.ConnectionFailure,                              # 08006
  LibPQ.Errors.AdminShutdown,                                  # 57P01 — pg_terminate_backend, fast shutdown
  LibPQ.Errors.CrashShutdown,                                  # 57P02 — crash of another server process
  LibPQ.Errors.CannotConnectNow,                               # 57P03 — server still starting up
  LibPQ.Errors.IdleSessionTimeout,                             # 57P05 — the one that targets IDLE POOLED conns
}

# Is `e` a DROPPED connection (retryable by `fetch`, and the trigger for retiring the pool's other
# idle connections) rather than a statement-level failure?
#
# SQLSTATE FIRST, message fingerprints only as the fallback. LibPQ parameterizes its result
# exceptions on the code (`PQResultError{Class, Code}`), so when the server handed one back we
# classify on it — exact, and impossible to spoof.
#
# That ordering is not cosmetic. `string(::PQResultError)` renders the full `PQresultErrorMessage`,
# which embeds DETAIL/HINT and the `LINE n:` query excerpt — i.e. USER DATA. An app storing captured
# PostgreSQL log text hits a unique violation whose DETAIL reads
# `Key (msg)=(FATAL: terminating connection due to administrator command) already exists.`, and a
# bare `occursin` over that message would classify an integrity error as a dropped connection:
# `backend_classify_error` asks this function first, so the caller would get `OperationalError`
# where the documented type is `IntegrityError`, and `fetch` would renew a healthy connection and
# flush every idle slot on each occurrence.
#
# The message branch survives because the case that started #442 has NO usable SQLSTATE: a
# connection dropped mid-query arrives as `PQResultError{CUN, EUNOWN}` — libpq returned no code, so
# LibPQ synthesized the class "UN" — and so do `PQConnectionError` and friends. A real
# `pg_terminate_backend` delivers exactly this, and it matched none of the pre-#442 patterns:
#
#   FATAL:  terminating connection due to administrator command
#   SSL connection has been closed unexpectedly
#
# which is why `fetch`'s retry never fired and the error propagated to the caller — the mechanism
# the #442 production report actually hit.
function PormG.backend_is_connection_error(pool::PormGPostgres, e)
  # (0) LibPQ raises `CompositeException` when several results in one execute errored, and
  #     `_unwrap_async_exception` only unwraps the single-error case. Recurse, or a multi-result
  #     failure would skip the SQLSTATE gate below and be judged on concatenated message text.
  e isa CompositeException &&
    return any(inner -> PormG.backend_is_connection_error(pool, inner), e.exceptions)

  # (1) The server gave us a code — trust it over any text.
  e isa _PG_LOST_CONNECTION_ERRORS && return true

  # (2) A result error carrying a REAL SQLSTATE that is not one of the above is not a retryable
  #     dropped connection, and must never reach the message matching below — that is the user-data
  #     hazard above. `CUN` is LibPQ's synthetic "no code" class, so it deliberately falls through.
  if e isa LibPQ.Errors.PQResultError && !(e isa LibPQ.Errors.PQResultError{LibPQ.Errors.CUN})
    return false
  end

  # (3) No usable SQLSTATE: fall back to libpq's own message fingerprints. Every phrase here is text
  #     libpq or the server generates about the SESSION, never a value an app would store.
  msg = lowercase(string(e))
  return (e isa LibPQ.Errors.UnknownError && string(e) == "LibPQ.Errors.UnknownError(\"\")") ||
         occursin("server closed the connection", msg) ||
         occursin("connection not open", msg) ||
         occursin("terminating connection", msg) ||
         occursin("connection to server was lost", msg) ||
         occursin("ssl connection has been closed unexpectedly", msg) ||
         occursin("no connection to the server", msg)
end

# Is `e` a *permanent* connect failure (won't succeed on retry) rather than transient? Scoped to
# high-confidence config/auth classes only — bad password, missing role/database, no pg_hba.conf entry.
# Host/DNS/network failures are deliberately NOT matched: they can be a transient blip during a deploy,
# so they degrade to the normal wait-to-deadline path. LibPQ raises the same `PQConnectionError` (message
# only, no SQLSTATE) for auth and host failures alike, so this is message-substring based (#72).
function PormG.backend_is_permanent_connect_error(pool::PormGPostgres, e)
  # A connection string `_preflight_conninfo` refused (NUL, unparseable) is the most permanent
  # failure there is: the same string fails the same way on every retry (#657).
  e isa PormG.InvalidConfigurationError && return true
  msg = lowercase(string(e))
  return occursin("password authentication failed", msg) ||
         occursin("no pg_hba.conf entry", msg) ||
         (occursin("role ", msg) && occursin("does not exist", msg)) ||
         (occursin("database ", msg) && occursin("does not exist", msg))
end

# ── Error classification (#268) ──────────────────────────────────────────────
#
# PostgreSQL is the precise half of the boundary: LibPQ parameterizes its exception type on the
# SQLSTATE (`PQResultError{Class, Code}`), so the class is available without parsing a message.
#
# Two ordering rules, both load-bearing:
#
#   1. Ask `backend_is_connection_error` FIRST. A connection dropped mid-query arrives as
#      `PQResultError{CUN, EUNOWN}` — libpq returned no SQLSTATE, so LibPQ synthesized the class
#      "UN". Class-mapping that yields :statement, which would tell `fetch` the statement was bad
#      and silently kill the reconnect-retry of #138.
#   2. Dispatch on the LibPQ exception type, not on `PormGPostgres` alone. A method typed on the
#      abstract pool marker would shadow core's default for every PG-flavored pool, including the
#      behavioral mocks the unit suite builds — which throw plain `ErrorException`s and steer
#      through their own `backend_is_connection_error` overrides. (PormG has been bitten by
#      exactly this shadowing before; see test/unit/test_error_taxonomy.jl.)
const _PG_OPERATIONAL_CLASSES = (
  LibPQ.Errors.C08,   # connection_exception
  LibPQ.Errors.C40,   # transaction_rollback — serialization_failure, deadlock_detected
  LibPQ.Errors.C53,   # insufficient_resources — out of memory / disk / connections
  LibPQ.Errors.C55,   # object_not_in_prerequisite_state — lock_not_available
  LibPQ.Errors.C57,   # operator_intervention — query_canceled, admin_shutdown
)

function PormG.backend_classify_error(pool::PormGPostgres, e::LibPQ.Errors.LibPQException)
  PormG.backend_is_connection_error(pool, e) && return :operational
  # Connection-level failures are a SIBLING of PQResultError, not a subtype, so they carry no
  # SQLSTATE to map. The realistic source is the COPY drain in `_drain_postgres_connection!` below,
  # which raises this when `PQconsumeInput` fails mid-stream — the connection is gone, which is
  # operational, not a bad statement.
  e isa LibPQ.Errors.PQConnectionError && return :operational
  e isa LibPQ.Errors.PQResultError || return :unknown
  class = LibPQ.Errors.error_class(e)
  class === LibPQ.Errors.C23 && return :integrity      # integrity_constraint_violation
  class in _PG_OPERATIONAL_CLASSES && return :operational
  # Everything else the server named — syntax (42), data (22), feature (0A), privilege — is the
  # statement being refused. An unrecognized class lands here too, which is the safe default.
  return :statement
end

PormG.backend_num_affected_rows(pool::PormGPostgres, result) = LibPQ.num_affected_rows(result)
PormG.backend_num_rows(pool::PormGPostgres, result) = LibPQ.num_rows(result)

# Consume every PGresult still queued on `conn` until the wire is clean. Returns `true` when it
# drained, `false` when `deadline` (an absolute `time()`) elapsed with a result still pending.
#
# Still THROWS `PQConnectionError` when `PQconsumeInput` fails: that means the socket is gone, which
# `backend_copy_in!` has always propagated and must keep propagating. `deadline = Inf` — the default,
# and what the COPY path passes — is exactly the pre-#315 behaviour.
#
# The bound matters only for the abandoned-await caller (#315). `PQisBusy` spins on `yield()` rather
# than waiting on the socket, so it is a HOT loop, and a result stream the driver task abandoned
# half-read can take as long as the query itself did.
function _drain_postgres_connection!(conn::LibPQ.Connection; deadline::Float64 = Inf)::Bool
  LibPQ.lock(conn) do
    while true
      # COPY can leave a trailing PGresult pending on the connection even after
      # the main Result is closed. Drain it before the connection returns to the pool.
      LibPQ.libpq_c.PQconsumeInput(conn.conn) == 1 || throw(LibPQ.Errors.PQConnectionError(conn))

      if LibPQ.libpq_c.PQisBusy(conn.conn) == 1
        time() > deadline && return false
        yield()
        continue
      end

      result_ptr = LibPQ.libpq_c.PQgetResult(conn.conn)
      result_ptr == C_NULL && return true
      LibPQ.libpq_c.PQclear(result_ptr)
    end
  end
end

# ── Abandoned-await recovery (#315) ──────────────────────────────────────────
#
# A Ctrl-C during a query leaves libpq with an unconsumed result queued on the socket. Nothing in
# the pool can see that: `backend_is_alive` is `PQstatus(conn) == CONNECTION_OK`, which stays true
# for a connection carrying a pending result — so the slot went back into circulation and every
# later statement on it failed with "another command is already in progress", permanently.

# How long the drain may spin on a still-busy socket before the caller gives up and renews the
# connection instead. Generous: `PQcancel` normally aborts within milliseconds, so reaching this
# means the server never acknowledged the cancel.
const _PG_ABANDON_DRAIN_SECONDS = 5.0

# Ask PostgreSQL to abandon the statement currently running on `conn` (#315).
#
# NOT `LibPQ.cancel(async_result)`: that only sets the AsyncResult's `should_cancel` flag, and the
# flag is read by the `_consume` loop INSIDE the driver's own result task. In the case this exists
# for, the SIGINT killed that task — the loop is gone, the flag is never read, and nothing is
# cancelled. The out-of-band request below is the only one that reaches the server: libpq builds a
# separate `PGcancel` and sends it on its OWN socket. That is also why this is the one libpq call
# safe to issue while another task may still hold the `PGconn`.
function PormG.backend_cancel_query!(pool::PormGPostgres, conn::LibPQ.Connection)
  isopen(conn) || return nothing
  cancel_ptr = LibPQ.libpq_c.PQgetCancel(conn.conn)
  cancel_ptr == C_NULL && return nothing
  try
    errbuf = zeros(UInt8, 256)
    if LibPQ.libpq_c.PQcancel(cancel_ptr, pointer(errbuf), Cint(length(errbuf))) != 1
      @debug "PostgreSQL refused the cancel request" reason=unsafe_string(pointer(errbuf))
    end
  finally
    LibPQ.libpq_c.PQfreeCancel(cancel_ptr)
  end
  return nothing
end

# Is `conn` clean enough to hand back to the pool? Never throws: the caller is a detached recovery
# task, where an escaping failure would surface as an unhandled task error instead of a renewed
# connection. A `false` here routes the connection to `_renew_or_discard_connection!`.
function PormG.backend_drain_connection!(pool::PormGPostgres, conn::LibPQ.Connection)
  try
    return _drain_postgres_connection!(conn; deadline = time() + _PG_ABANDON_DRAIN_SECONDS)
  catch drain_failure
    @debug "PostgreSQL connection could not be drained; it will be renewed or discarded" exception=drain_failure
    return false
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
