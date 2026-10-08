# ============================================================
# test/unit/test_postgres_ext.jl
#
# The Postgres.jl PostgreSQL driver extension (#788), hermetically.
#
# CONTRACT being tested:
#   `ext/PormGPostgresExt.jl` serves exactly the pools built for it — `PostgresConnectionPool{:postgres}` —
#   and coexists with the LibPQ extension: every `backend_*` generic resolves to the right extension for
#   each pool type, and loading both introduces no method ambiguity (Aqua's own check loads neither
#   extension, so it cannot see this). A connection string never leaks a credential through a parse
#   error. Sessions run with LibPQ.jl's DateStyle/TimeZone, results decode to the types LibPQ.jl
#   delivers, errors classify by SQLSTATE rather than by message text, an interrupt wrapped by the TLS
#   layer is recognised as an abandoned await, and COPY reports an exact record count.
#
# No live database: parsers, classifiers and preflight are exercised directly. The integration suite
# runs PormG end to end through this driver with `PORMG_POSTGRES_DRIVER=Postgres`.
# ============================================================

using Test
using PormG

include(joinpath(@__DIR__, "..", "load_drivers.jl"))

const CP = PormG.ConnectionPool
const PGExt = Base.get_extension(PormG, :PormGPostgresExt)
const LibPQExtMod = Base.get_extension(PormG, :PormGLibPQExt)
const PostgresPool = CP.PostgresConnectionPool{:postgres}
const LibPQPool = CP.PostgresConnectionPool{:libpq}
const PgConn = Postgres.Connection

# A server error with the given SQLSTATE and text. Built by field name so a field added upstream
# cannot shift the others.
_pg_error(code; message = "boom", detail = nothing) = Postgres.Error((
  f === :severity ? "ERROR" : f === :code ? code : f === :message ? message : f === :detail ? detail : nothing
  for f in fieldnames(Postgres.Error))...)

# An exception that carries another in `.cause`, as the TLS layer's error does…
struct _CauseWrapper788 <: Exception
  cause
end
# …or in `.err`, as the socket layer's `OpError` does; and a stand-in for its closed-socket error,
# which the extension recognises by name so that it never depends on the socket package.
struct _ErrWrapper788 <: Exception
  err
end
struct NetClosingError <: Exception end

@testset "both extensions load, and each serves its own pools (#788)" begin
  @test PGExt !== nothing
  @test LibPQExtMod !== nothing

  # (generic, argument types for the Postgres.jl pool). A typo in the pool's type parameter would
  # silently define a method nothing ever reaches, so every row is checked by where it resolves.
  rows = [
    (PormG.backend_connect, (PostgresPool,)),
    (PormG.backend_renew_connection, (PostgresPool, PgConn)),
    (PormG.backend_is_alive, (PostgresPool, PgConn)),
    (PormG.backend_execute, (PostgresPool, PgConn, String, Any)),
    (PormG.backend_execute_async, (PostgresPool, PgConn, String, Any)),
    (PormG.backend_is_connection_error, (PostgresPool, Any)),
    # Typed on the driver's exceptions (#1042); any other type falls to core's `false`, not to LibPQ.
    (PormG.backend_is_retry_safe, (PostgresPool, Postgres.Error)),
    (PormG.backend_is_retry_safe, (PostgresPool, Postgres.PostgresInterfaceError)),
    (PormG.backend_is_permanent_connect_error, (PostgresPool, Any)),
    (PormG.backend_classify_error, (PostgresPool, Postgres.Error)),
    (PormG.backend_cancel_query!, (PostgresPool, PgConn)),
    (PormG.backend_drain_connection!, (PostgresPool, PgConn)),
    (PormG.backend_num_affected_rows, (PostgresPool, Any)),
    (PormG.backend_num_rows, (PostgresPool, Any)),
    (PormG.backend_copy_in!, (PostgresPool, PgConn, String, Any)),
    # Keyed on the exception alone (#987) — no pool to fall back on, but Postgres.jl's reader is
    # still the extension's own.
    (PormG.backend_error_fields, (Postgres.Error,)),
  ]
  for (f, types) in rows
    @test which(f, Tuple{types...}).module === PGExt
  end
  # Every PostgreSQL backend generic has a row: a new one without a method here would fall back to
  # LibPQ's marker-typed method for a Postgres.jl pool.
  pg_generics = Set(nameof(f) for (f, _) in rows)
  for name in names(PormG; all = true)
    s = string(name)
    (startswith(s, "backend_") && name !== :backend_sqlite_version && getfield(PormG, name) isa Function) || continue
    @test name in pg_generics
  end

  # The LibPQ pool still resolves to the LibPQ extension.
  @test which(PormG.backend_connect, Tuple{LibPQPool}).module === LibPQExtMod
  @test which(PormG.backend_is_connection_error, Tuple{LibPQPool, Any}).module === LibPQExtMod
  @test which(PormG.backend_num_rows, Tuple{LibPQPool, Any}).module === LibPQExtMod
end

@testset "no method ambiguity with both PostgreSQL extensions loaded (#788)" begin
  ext_modules = (PGExt, LibPQExtMod)
  # The extension modules are named explicitly: they are not submodules of PormG, so a scan of
  # PormG alone never looks at the methods they add (measured — it passed with an ambiguous method).
  # Only pairs this extension could have caused: one side in it, or both sides in the two drivers.
  # (Other unit files define mocks in `Main` whose overlaps with the LibPQ extension predate #788.)
  ambiguous = filter(Test.detect_ambiguities(PormG, ext_modules...; recursive = true)) do (a, b)
    a.module === PGExt || b.module === PGExt || (a.module in ext_modules && b.module in ext_modules)
  end
  @test isempty(ambiguous)
end

@testset "a connection string never leaks a credential through the preflight (#788)" begin
  # (label, DSN, secret fragments). Each is either refused with none of the fragments in the message,
  # or parsed with every fragment confined to the credential fields.
  cases = [
    ("NUL byte", "host=localhost password=s3cr\0etNUL dbname=f1", ["s3cr", "etNUL"]),
    ("unquoted passphrase", "host=localhost password=corr3ct horse battery dbname=f1", ["horse", "battery"]),
    ("bad percent-escape URL", "postgresql://u:p%zzSECRET788@localhost/f1", ["SECRET788", "p%zz"]),
    ("unencoded @ in URL password", "postgresql://u:pa@ssSEC788@localhost:1/f1", ["ssSEC788"]),
    ("unencoded @ and : in URL password", "postgresql://u:pa@ss:PORTSEC788@localhost/f1", ["PORTSEC788"]),
    ("unencoded / in URL password", "postgresql://u:pa/ssSEC788@localhost/f1", ["ssSEC788"]),
    ("unencoded / then ?sslmode= in URL password", "postgresql://u:1234/x?sslmode=SEC788@h/f1", ["SEC788"]),
    ("unencoded @ then ?keyword= in URL password", "postgresql://u:pa@ss?sslmode=SEC788@h/f1", ["SEC788"]),
    # Postgres.jl-only shapes (JuliaDatabases/Postgres.jl#22 and its rejected keywords).
    ("mistyped URL scheme", "postgresq://u:SEC788scheme@h/f1", ["SEC788scheme"]),
    # Postgres.jl reads the scheme case-insensitively, so the `@` rule must as well (review finding).
    ("upper-case scheme, / then ?sslmode=", "POSTGRESQL://u:1234/x?sslmode=SEC788up@h/f1", ["SEC788up", "sec788up"]),
    ("mixed-case scheme, / then ?options=", "Postgres://u:1234/x?options=SEC788mix@h/f1", ["SEC788mix"]),
    # #662's second half (security review): the tail spans several options and only the last,
    # allow-listed one takes the `@`, leaving the fragment in an earlier option Postgres.jl echoes.
    ("?keyword= tail ending in application_name=@host", "postgresql://u:1234/x?gssencmode=SEC788gss&application_name=@h/f1", ["SEC788gss", "sec788gss"]),
    ("?keyword= tail ending in user=@host", "postgresql://u:1234/x?gssencmode=SEC788usr&user=@h/f1", ["SEC788usr", "sec788usr"]),
    ("sslpassword", "host=h sslpassword=SEC788ssl dbname=f1", ["SEC788ssl"]),
    ("unsupported keyword value", "host=h target_session_attrs=SEC788tsa dbname=f1", ["SEC788tsa"]),
  ]
  credential_fields = (:user, :password)
  for (label, dsn, secrets) in cases
    @testset "$label" begin
      outcome = try
        PGExt._checked_params(dsn)
      catch e
        e
      end
      if outcome isa Exception
        @test outcome isa PormG.InvalidConfigurationError
        msg = PormG.error_message(outcome)
        for s in secrets
          @test !occursin(s, msg)
        end
      else
        for f in fieldnames(Postgres.ConnectionParams)
          f in credential_fields && continue
          v = getfield(outcome, f)
          v isa AbstractString || continue
          for s in secrets
            @test !occursin(s, v)
          end
        end
      end
    end
  end

  # A rejected keyword is still named, because a keyword is never a secret…
  err = try PGExt._checked_params("host=h sslpassword=x dbname=f1"); nothing catch e; e end
  @test occursin("`sslpassword`", PormG.error_message(err))
  # …but a lone word is never taken for one, even when it spells a keyword: here it is the second
  # word of an unquoted password.
  err = try PGExt._checked_params("host=h password=my service dbname=f1"); nothing catch e; e end
  @test err isa PormG.InvalidConfigurationError
  @test !occursin("service", PormG.error_message(err))

  # The allowed shapes stay allowed: an `@` inside a user name or free text, not shaped like a host.
  for dsn in ("postgresql://u@h/f1?application_name=etl@nightly", "postgresql://h/f1?user=me@server",
              # a password holding `&k=v` of its own, before the authority's `@` (security re-review)
              "postgresql://u:pa&x=y@h/f1")
    @test PGExt._checked_params(dsn) isa Postgres.ConnectionParams
  end

  # Refused before any I/O: settings this driver would honour dangerously or not at all.
  for dsn in ("host=h dbname=f1 reconnect=true", "host=/tmp dbname=f1")
    @test_throws PormG.InvalidConfigurationError PGExt._checked_params(dsn)
  end
end

@testset "sessions run with LibPQ.jl's DateStyle and TimeZone (#788)" begin
  @test PGExt._session_options(nothing) == "-c DateStyle=ISO,YMD -c TimeZone=UTC"
  @test PGExt._session_options("") == PGExt._session_options(nothing)
  # The user's options come after ours, so a deliberate setting of their own wins.
  @test PGExt._session_options("-c TimeZone=America/Sao_Paulo") ==
        "-c DateStyle=ISO,YMD -c TimeZone=UTC -c TimeZone=America/Sao_Paulo"

  params = Postgres.parse_dsn("host=h port=6543 user=u password=p dbname=d application_name=app sslmode=disable")
  rebuilt = PGExt._with_session_options(params)
  for f in fieldnames(Postgres.ConnectionParams)
    f === :options && continue
    @test getfield(rebuilt, f) == getfield(params, f)
  end
  @test rebuilt.options == PGExt._SESSION_OPTIONS
end

@testset "results decode to the types LibPQ.jl delivers (#788)" begin
  Decimal = PGExt.Decimals.Decimal
  UTC = PGExt.TimeZones.TimeZone("UTC")
  ZDT = PGExt.TimeZones.ZonedDateTime

  # numeric: compared with an independent parse, and pinned to the canonical triple.
  for (text, expected) in (("12.3400", "12.34"), ("-0.5", "-0.5"), ("7", "7"),
                           ("123456789012345678901234567890.123", "123456789012345678901234567890.123"))
    v = PGExt._pg_numeric(text)
    @test v isa Decimal
    @test v == parse(Decimal, expected)
  end
  canonical = PGExt._pg_numeric("12.3400")
  @test (canonical.s, canonical.c, canonical.q) == (0, 1234, -2)
  @test (PGExt._pg_numeric("0.000").c, PGExt._pg_numeric("0.000").q) == (0, 0)
  @test_throws ArgumentError PGExt._pg_numeric("NaN")

  # timestamptz: every offset lands in UTC, truncated to the millisecond.
  for (text, utc) in (("2024-02-29 10:11:12.5+00", PGExt.Dates.DateTime(2024, 2, 29, 10, 11, 12, 500)),
                      ("2024-02-29 10:11:12-03", PGExt.Dates.DateTime(2024, 2, 29, 13, 11, 12)),
                      ("2024-02-29 10:11:12.123456+05:30", PGExt.Dates.DateTime(2024, 2, 29, 4, 41, 12, 123)))
    v = PGExt._pg_timestamptz(text)
    @test v isa ZDT
    @test PGExt.TimeZones.timezone(v) == UTC
    @test v == ZDT(utc, UTC)
  end
  # ±infinity as LibPQ.jl maps it.
  @test PGExt._pg_timestamptz("infinity") == ZDT(typemax(PGExt.Dates.DateTime), UTC)
  @test PGExt._pg_timestamptz("-infinity") == ZDT(typemin(PGExt.Dates.DateTime), UTC)
  @test PGExt._pg_timestamp("infinity") == typemax(PGExt.Dates.DateTime)
  @test_throws ArgumentError PGExt._pg_timestamptz("2024-02-29 10:11:12 BC")

  @test PGExt._pg_timestamp("2024-02-29 10:11:12.123456") == PGExt.Dates.DateTime(2024, 2, 29, 10, 11, 12, 123)
  @test PGExt._pg_timestamp("2024-02-29 10:11:12") == PGExt.Dates.DateTime(2024, 2, 29, 10, 11, 12)
  @test PGExt._pg_bpchar("ab ") == "ab"
end

@testset "parameters bind as LibPQ.jl binds them (#788)" begin
  @test PGExt._bind(nothing) === nothing
  bound = PGExt._bind(Any[UInt8[1, 2], "x", 3])
  @test bound[1] == [1, 2] && bound[1] isa Vector{Int}
  @test bound[2] == "x" && bound[3] == 3
  @test PGExt._bind((UInt8[1], 2)) isa Tuple
  query = PormG.QueryBuilder.PgParameterizedQuery("", Any[UInt8[5], "y"], 2)
  @test PGExt._bind(query) == Any[[5], "y"]
end

@testset "errors classify by SQLSTATE, never by message text (#788)" begin
  pool = CP.PostgresConnectionPool("host=h"; driver = :postgres)
  lost(e) = PormG.backend_is_connection_error(pool, e)
  kind(e) = PormG.backend_classify_error(pool, e)

  # A unique violation whose stored data reads like a dropped connection is still an integrity error.
  spoof = _pg_error("23505"; message = "duplicate key", detail = "Key (msg)=(FATAL: terminating connection) already exists.")
  @test !lost(spoof)
  @test kind(spoof) === :integrity

  @test lost(_pg_error("57P01")) && kind(_pg_error("57P01")) === :operational
  @test lost(_pg_error("08006"))
  for code in ("08P01", "08007", "57014", "40001", "40P01", "25P03", "57P04")
    @test !lost(_pg_error(code))   # never retried by fetch: see the LibPQ extension's exclusions
  end
  @test kind(_pg_error("40001")) === :operational
  @test kind(_pg_error("57014")) === :operational
  @test kind(_pg_error("42601")) === :statement
  @test kind(_pg_error("22012")) === :statement
  @test kind(_pg_error("")) === :operational

  closed = Postgres.PostgresInterfaceError("postgres connection has been closed or disconnected; reconnect disabled")
  @test lost(closed) && kind(closed) === :operational
  # The prefix, not a substring: other interface errors quote the SQL, which is user text.
  quoting = Postgres.PostgresInterfaceError("number of parameters provided (1) does not match number of placeholders (2) in sql: postgres connection has been closed or disconnected")
  @test !lost(quoting)
  @test kind(quoting) === :unknown

  @test lost(EOFError()) && kind(EOFError()) === :operational
  # The socket layer's own shapes (review finding): a reset or broken pipe as a `SystemError`, a
  # closed socket as `NetClosingError`, and a wrapper holding the failure in `.err`.
  @test lost(SystemError("read", Libc.ECONNRESET)) && kind(SystemError("write", Libc.EPIPE)) === :operational
  @test !lost(SystemError("connect", Libc.ECONNREFUSED))
  @test kind(SystemError("read", Libc.ETIMEDOUT)) === :operational
  @test lost(NetClosingError())
  @test lost(_ErrWrapper788(SystemError("read", Libc.ECONNRESET)))
  @test !lost(_ErrWrapper788(SystemError("connect", Libc.ECONNREFUSED)))
  @test lost(_CauseWrapper788(EOFError()))
  @test lost(CompositeException([ErrorException("x"), EOFError()]))
  @test !lost(ErrorException("server closed the connection unexpectedly"))

  @test PormG.backend_is_permanent_connect_error(pool, _pg_error("28P01"))
  @test PormG.backend_is_permanent_connect_error(pool, _pg_error("3D000"))
  @test PormG.backend_is_permanent_connect_error(pool, PormG.InvalidConfigurationError("x"))
  @test !PormG.backend_is_permanent_connect_error(pool, _pg_error("57P01"))
end

# The same retry rule as the LibPQ extension (#1042): every lost connection is renewed and swept, but
# `fetch` re-runs a statement only when it provably never ran. The socket-level shapes can come after
# the server received the statement, so none of them is retry-safe.
@testset "only a statement that never ran is retry-safe — Postgres.jl (#1042)" begin
  pool = CP.PostgresConnectionPool("host=h"; driver = :postgres)
  lost(e) = PormG.backend_is_connection_error(pool, e)
  safe(e) = PormG.backend_is_retry_safe(pool, e)

  # The server named the backend gone.
  for code in ("57P01", "57P02", "57P03", "57P05", "08000", "08006")
    @test lost(_pg_error(code)) && safe(_pg_error(code))
  end
  # Postgres.jl refused before writing: `checkconn` found the socket closed.
  for msg in ("postgres connection has been closed or disconnected",
              "postgres connection has been closed or disconnected; reconnect disabled")
    @test lost(Postgres.PostgresInterfaceError(msg)) && safe(Postgres.PostgresInterfaceError(msg))
  end

  # The socket went away: lost, renewed and swept, but never re-run.
  for e in (EOFError(), Base.IOError("read: connection reset by peer", -104),
            SystemError("read", Libc.ECONNRESET), SystemError("write", Libc.EPIPE), NetClosingError(),
            _CauseWrapper788(EOFError()), _ErrWrapper788(SystemError("read", Libc.ECONNRESET)))
    @test lost(e) && !safe(e)
  end
  # A socket timeout or an unreachable host is a lost connection on both drivers, as LibPQ's
  # "could not receive data from server: <errno>" is. It used to be operational only here.
  for errno in (Libc.ETIMEDOUT, Libc.EHOSTUNREACH, Libc.ENETUNREACH)
    e = SystemError("read", errno)
    @test lost(e) && !safe(e)
    @test PormG.backend_classify_error(pool, e) === :operational
  end
  @test !lost(SystemError("connect", Libc.ECONNREFUSED))

  # Codes outside the lost-connection set, a spoofed DETAIL and an interface error quoting SQL: never.
  for code in ("08P01", "08007", "57014", "40001", "40P01", "23505")
    @test !safe(_pg_error(code))
  end
  @test !safe(_pg_error("23505"; detail = "Key (msg)=(FATAL: terminating connection) already exists."))
  @test !safe(Postgres.PostgresInterfaceError("number of parameters provided (1) does not match number of placeholders (2) in sql: postgres connection has been closed or disconnected"))

  # A multi-result failure is retry-safe when the server named one of its errors.
  @test safe(CompositeException([EOFError(), _pg_error("57P01")]))
  @test !safe(CompositeException([EOFError()]))
end

@testset "an interrupt wrapped by the TLS layer is an abandoned await (#788)" begin
  task = Threads.@spawn PGExt._with_bare_interrupt(() -> throw(_CauseWrapper788(InterruptException())))
  err = try
    fetch(task)
    nothing
  catch e
    e
  end
  @test CP._await_abandoned(err)

  # Anything else passes through untouched.
  other = try
    PGExt._with_bare_interrupt(() -> throw(_CauseWrapper788(EOFError())))
  catch e
    e
  end
  @test other isa _CauseWrapper788
end

@testset "COPY reports an exact record count (#788)" begin
  CSV = PormG.QueryBuilder.CSV
  rows = PormG.DataFrames.DataFrame(id = [1, 2, 3, 4], s = ["plain", "two\nlines", "a \"quoted\" word", missing])
  io = IOBuffer()
  # As bulk_copy writes a chunk (execution_bulk.jl): no header, strings force-quoted, NULL marker.
  CSV.write(io, rows; header = false, quotestrings = true, missingstring = "\\N")
  payload = String(take!(io))
  @test count(==('\n'), payload) > size(rows, 1)   # a raw newline inside a quoted value
  @test PGExt._csv_record_count(payload) == size(rows, 1)
  @test PGExt._csv_record_count(chop(payload)) == size(rows, 1)   # no trailing newline
  @test PGExt._csv_record_count("") == 0

  # Chunks may be strings or bytes, as LibPQ.jl's `CopyIn` accepts (review finding): bytes must be
  # written as bytes, never stringified.
  @test PGExt._copy_payload(["1,a\n", "2,b\n"]) == Vector{UInt8}("1,a\n2,b\n")
  @test PGExt._copy_payload([Vector{UInt8}("1,a\n"), "2,b\n"]) == Vector{UInt8}("1,a\n2,b\n")
  @test PGExt._copy_payload("1,a\n") == Vector{UInt8}("1,a\n")
  @test_throws ArgumentError PGExt._copy_payload([1, 2])
end
