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
#   error. The driver decides what it accepts, so PormG's tables never refuse a string it parses
#   (#1247), and a refusal it makes names the bad parameter from PormG's own parse of the string —
#   which agrees with Postgres.jl's — never from the driver's message text (#1235). Sessions run with LibPQ.jl's
#   DateStyle/TimeZone, results decode to the types LibPQ.jl delivers, errors classify by SQLSTATE
#   rather than by message text, an interrupt wrapped by the TLS layer is recognised as an abandoned
#   await, and COPY reports an exact record count.
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
    # Postgres.jl binds fewer parameters per statement than the protocol allows (#1447).
    (PormG.backend_postgres_parameter_limit, (PostgresPool,)),
    # Keyed on the exception alone (#987) — no pool to fall back on, but Postgres.jl's reader is
    # still the extension's own.
    (PormG.backend_error_fields, (Postgres.Error,)),
    # Keyed on the exception alone too (#1277): the cancel code is the extension's to read.
    (PormG.backend_is_cancellation, (Postgres.Error,)),
  ]
  for (f, types) in rows
    @test which(f, Tuple{types...}).module === PGExt
  end
  # Every PostgreSQL backend generic has a row: a new one without a method here would fall back to
  # LibPQ's marker-typed method for a Postgres.jl pool. The engine-only ones are not PostgreSQL's: the
  # two version probes, MySQL's insert id (`INSERT … RETURNING` carries PostgreSQL's row, #1266), and
  # MySQL's bulk INSERT report and duplicate-key test (PostgreSQL counts rows and reads SQLSTATE, #1267),
  # and MySQL's driver parameter limit (PostgreSQL's own is `backend_postgres_parameter_limit`, a row above).
  pg_generics = Set(nameof(f) for (f, _) in rows)
  for name in names(PormG; all = true)
    s = string(name)
    (startswith(s, "backend_") && name ∉ (:backend_sqlite_version, :backend_mysql_version, :backend_last_insert_id,
                                             :backend_insert_report, :backend_is_duplicate_key,
                                             :backend_mysql_parameter_limit) &&
     getfield(PormG, name) isa Function) || continue
    @test name in pg_generics
  end

  # The LibPQ pool still resolves to the LibPQ extension.
  @test which(PormG.backend_connect, Tuple{LibPQPool}).module === LibPQExtMod
  @test which(PormG.backend_is_connection_error, Tuple{LibPQPool, Any}).module === LibPQExtMod
  @test which(PormG.backend_num_rows, Tuple{LibPQPool, Any}).module === LibPQExtMod
  @test which(PormG.backend_is_cancellation, Tuple{LibPQ.Errors.QueryCanceled}).module === LibPQExtMod
end

# What: the bind-parameter limit PormG sizes a PostgreSQL statement to is the driver's — 32767 on
#   Postgres.jl, 65535 on LibPQ — and the writes it splits follow it: a many-to-many `remove`'s id groups,
#   and a bulk statement's `fld(limit, 8)` rows of eight columns when no positive `chunk_size` is given
#   (4095 on Postgres.jl, 8191 on LibPQ).
# SQL: none — the limit decides how many statements a write splits into (`DELETE … IN (?, …)` per batch).
# Why (#1447): Postgres.jl writes the Bind message's parameter count as an `Int16`, so a statement of
#   32768–65535 parameters, which PormG sized against the protocol's 65535, raised `InexactError` at the
#   driver instead of being split. LibPQ answers the core fallback, the protocol's limit, unchanged.
@testset "the bind-parameter limit is the PostgreSQL driver's (#1447)" begin
  pg = CP.PostgresConnectionPool("host=h"; driver = :postgres)
  lpq = CP.PostgresConnectionPool("host=h"; driver = :libpq)
  @test PormG.QueryBuilder._backend_parameter_limit(pg) == 32767
  @test PormG.QueryBuilder._backend_parameter_limit(lpq) == 65535
  @test which(PormG.backend_postgres_parameter_limit, Tuple{LibPQPool}).module === PormG
  @test PormG.QueryBuilder._bulk_chunk_rows(pg, 0, 8, 0, :bulk_insert) == 4095
  @test PormG.QueryBuilder._bulk_chunk_rows(lpq, 0, 8, 0, :bulk_insert) == 8191
  # The issue's own path: a many-to-many `remove` binds the owner and one parameter per id, so 32767 ids
  # are two statements on Postgres.jl and one on LibPQ.
  remove_sizes(pool, n) = length.(PormG.QueryBuilder._m2m_id_chunks(pool, Any[1:n...], 1, 1, :many_to_many_remove))
  @test remove_sizes(pg, 32767) == [32766, 1]
  @test remove_sizes(lpq, 32767) == [32767]
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
    # #1243: on Postgres.jl 2.2.2, URIs' `unescapeuri` raised Base's `invalid base 16 digit 'z' in "…"`,
    # and the single-quoted character — the password's — was outside what `_mask_quoted` masks.
    ("bad percent-escape URL", "postgresql://u:p%zzSECRET788@localhost/f1", ["SECRET788", "p%zz", "'z'"]),
    ("bad percent-escape in a realistic URL password", "postgresql://u:50%offSEC788@localhost/f1", ["SEC788", "'o'", "off"]),
    ("bad percent-escape in a URL user", "postgresql://SEC788%zz:p@localhost/f1", ["SEC788", "'z'"]),
    ("bad percent-escape in a URL host", "postgresql://u:p@SEC788%zz/f1", ["SEC788", "'z'"]),
    ("bad percent-escape in a URL database name", "postgresql://u:p@localhost/SEC788%zz", ["SEC788", "'z'"]),
    ("truncated percent-escape in a URL password", "postgresql://u:SEC788%4@localhost/f1", ["SEC788"]),
    # A query value URIs 1.6 cuts at its second `=` and URIs 1.7 decodes whole: PormG's pass takes the
    # reading that decodes, so only `_mask_quoted` stands between Base's `'o'` and the message.
    ("bad percent-escape in a URL query value", "postgresql://u:p@localhost/f1?password=x=50%offSEC788", ["SEC788", "'o'", "off"]),
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

@testset "a refusal names the parameter from PormG's own parse, never its value (#1235, #1233)" begin
  # What: `_checked_params` splits the string itself and checks it against Postgres.jl's rules before
  # the driver sees it. Expected: each refusal names the offending keyword — an ignored keyword set to
  # a value the driver refuses, a libpq keyword the driver lacks, a malformed integer, boolean or
  # `numeric_overflow` — in keyword and URL form alike; it never shows the value; and a key that is no
  # keyword is referred to by its position, because it may be a password fragment. Why: the name used
  # to be read back from the driver's message text, and a Postgres.jl release that changed one message
  # shape turned the refusal into `connection parameter "****"` and `main` red (#1233).
  named(dsn) = (try PGExt._checked_params(dsn); "" catch e; e isa PormG.InvalidConfigurationError ? PormG.error_message(e) : rethrow() end)
  cases = [
    # (DSN, the text the refusal must carry, fragments it must not carry)
    ("host=h sslpassword=SECssl dbname=f1", "parameter `sslpassword`", ["SECssl"]),
    ("host=h channel_binding=SECcb dbname=f1", "parameter `channel_binding`", ["SECcb"]),
    ("host=h port=SECport dbname=f1", "parameter `port` is not an integer", ["SECport"]),
    ("host=h connect_timeout='1 SECct' dbname=f1", "parameter `connect_timeout` is not an integer", ["SECct"]),
    ("host=h debug=SECdbg dbname=f1", "parameter `debug` is not a boolean", ["SECdbg"]),
    ("host=h numeric_overflow=SECno dbname=f1", "parameter `numeric_overflow` must be `warn` or `error`", ["SECno"]),
    ("host=h sslsni=1 dbname=f1", "sets `sslsni`, a libpq parameter the Postgres.jl driver does not support", String[]),
    # A word in a key position that is no keyword: by position. Here it is a password's second word.
    ("host=h password=abc SECkey=ghi dbname=f1", "parameter 3 is not a connection parameter", ["SECkey", "ghi"]),
    ("host=h ssl_mode=require", "parameter 2 is not a connection parameter", ["ssl_mode"]),
    # A lone word is never named even when it spells a keyword (#1233): `service` is the password's.
    ("host=h password=my service dbname=f1", "parameter 3 has no `=`", ["service"]),
    ("host=h password=corr3ct horse battery dbname=f1", "parameter 3 has no `=`", ["horse", "battery"]),
    ("host=h password='SECunterminated dbname=f1", "the quoted value of parameter `password` is never closed", ["SECunterminated"]),
    ("host=h password='SECq'x dbname=f1", "the quoted value of parameter `password` is followed by more text", ["SECq"]),
    ("host=h password=SECdangling\\", "the value of parameter `password` ends in a dangling", ["SECdangling"]),
    ("host=h =x", "parameter 2 has an empty name", String[]),
    # URL form: the query is split as URIs splits it, and keys keep their case there.
    ("postgresql://u:p@h/f1?port=SECurlport", "parameter `port` is not an integer", ["SECurlport"]),
    ("postgresql://u:p@h/f1?sslpassword=SECurlssl", "parameter `sslpassword`", ["SECurlssl"]),
    ("postgresql://u:p@h/f1?SSLMODE=require", "query parameter 1 is not a connection parameter Postgres.jl recognizes (parameter names are lower-case)", ["SSLMODE"]),
    ("postgresql://u:p@h/f1?sslmode=require&SECq=1", "query parameter 2 is not a connection parameter", ["SECq"]),
    ("postgresql://u:p@h/f1?sslpassword=SEC%zz", "the value of parameter `sslpassword` is not valid percent-encoding", ["SEC"]),
    # Before the query (#1243): the user info, host and database name, which Postgres.jl decodes too.
    ("postgresql://u:SEC%zz@h/f1", "URL's user info, host, port or database name is not valid percent-encoding", ["SEC", "'z'"]),
    ("postgresql://u:p@h/SEC%z", "URL's user info, host, port or database name is not valid percent-encoding", ["SEC", "'z'"]),
  ]
  for (dsn, expected, secrets) in cases
    @testset "$(expected)" begin
      msg = named(dsn)
      @test occursin(expected, msg)
      for s in secrets
        @test !occursin(s, msg)
      end
    end
  end

  # The forged value (#1233 security review): a `port` that itself spells `for connection parameter
  # "sslpassword"` names `port`, and `sslpassword` nowhere.
  msg = named("host=h port='x for connection parameter \"sslpassword\" y' dbname=f1")
  @test occursin("parameter `port` is not an integer", msg)
  @test !occursin("sslpassword", msg)

  # An invalid UTF-8 byte is refused as such, before anything lower-cases the string: `lowercase`
  # would throw an `InvalidCharError` printing the byte, a password's here (review finding).
  for dsn in ("host=h password=ab\xffSECutf dbname=f1", "postgresql://u:p@h/f1?application_name=\xffSECutf",
              "host=h password=ab\xc0\x80SECutf dbname=f1")   # overlong
    err = try PGExt._checked_params(dsn); nothing catch e; e end
    @test err isa PormG.InvalidConfigurationError
    @test occursin("not valid UTF-8", PormG.error_message(err))
    @test !occursin("SECutf", PormG.error_message(err))
  end
  # …but only what `lowercase` refuses: a lone surrogate is well-formed WTF-8, and the driver takes it.
  @test named("host=h password=a\ud800b dbname=f1") == ""
  # A URL's percent-decoding can MAKE invalid text out of a valid string, so no decoded key or value is
  # lower-cased unchecked: `lowercase` would throw an `InvalidCharError` printing the bytes — two
  # characters of the password in the spill shape `u:pa?ss%ffword@…` (security review). Each is a
  # value-free `InvalidConfigurationError`; a malformed boolean is refused as one, as the driver does.
  for dsn in ("postgresql://u:pa?ss%ffword@h/f1", "postgresql://u:p@h/f1?%ff=1",
              "postgresql://u:p@h/f1?x%e9y=1", "postgresql://u:p@h/f1?reconnect=%C0%80",
              "postgresql://u:p@h/f1?debug=%ffSECdbg")
    err = try PGExt._checked_params(dsn); nothing catch e; e end
    @test err isa PormG.InvalidConfigurationError
    rendered = sprint(showerror, err)
    @test !occursin("\\x", rendered)
    @test !occursin("SEC", rendered)
  end
  @test occursin("parameter `debug` is not a boolean", named("postgresql://u:p@h/f1?debug=%ffSECdbg"))
  # The key rows again, on PormG's pass alone: `_checked_params`' safety net would turn a throwing
  # `lowercase` into a value-free type name too, so only this shows the guard itself holds (review).
  for (dsn, label) in (("postgresql://u:pa?ss%ffword@h/f1", "query parameter 1"),
                       ("postgresql://u:p@h/f1?%ff=1", "query parameter 1"),
                       ("postgresql://u:p@h/f1?x%e9y=1", "query parameter 1"))
    err = try PGExt._check_dsn_params(PGExt._url_query_params(dsn)); nothing catch e; e end
    @test err isa PormG.InvalidConfigurationError
    @test occursin("$(label) is not a connection parameter", PormG.error_message(err))
  end
  # A decoded value nothing lower-cases stays the driver's to take, as it was.
  @test named("postgresql://u:p@h/f1?application_name=%ff") == ""

  # Only the LAST occurrence of a key is read, as Postgres.jl keeps it: a bad earlier value is never
  # used, so it is not refused.
  @test named("host=h port=x port=5432 dbname=f1") == ""
  # A URL value holding a second `=` is refused only when no reading of it passes — URIs 1.7 keeps
  # `5=x` whole, URIs 1.6 cuts it to `5`.
  @test PGExt._check_dsn_params(PGExt._url_query_params("postgresql://u:p@h/f1?port=5=x")) === nothing
  @test occursin("parameter `port` is not an integer", named("postgresql://u:p@h/f1?port=x=y"))
end

@testset "the driver decides what it accepts; PormG's tables only name its refusals (#1247)" begin
  # What: `_checked_params` hands the string to the driver first, and reads it with PormG's tables only
  # once the driver has refused it. Expected: a key a later Postgres.jl accepts but PormG's table lacks
  # — `sslsni`, stood in for by a stub `parse` — connects through; PormG's own policy checks still run
  # on what the driver parsed; and a refusal is still named from PormG's parse. Why: the tables match
  # Postgres.jl 2.2.2 and 2.3.0, and run first they would refuse a valid string the day a release
  # accepted more; CI resolves the newest Postgres.jl, so a working configuration would stop connecting.
  # The parity fuzz below cannot see it: it generates only keys the tables already know.
  newer_driver(dsn) = Postgres.parse_dsn(replace(dsn, r"\s*sslsni=\S*" => ""))
  for dsn in ("host=h sslsni=1 dbname=f1", "postgresql://u:p@h/f1?sslsni=1")
    # Today's driver refuses the key, and PormG names it…
    err = try PGExt._checked_params(dsn); nothing catch e; e end
    @test err isa PormG.InvalidConfigurationError
    @test occursin("sets `sslsni`, a libpq parameter the Postgres.jl driver does not support", PormG.error_message(err))
    # …a release that accepts it connects, whatever PormG's table says.
    params = PGExt._checked_params(dsn; parse = newer_driver)
    @test params isa Postgres.ConnectionParams
    @test params.host == "h" && params.dbname == "f1"
  end
  # A value rule the driver relaxes: PormG's table says `numeric_overflow` is `warn` or `error`.
  relaxed(dsn) = Postgres.parse_dsn(replace(dsn, "numeric_overflow=saturate" => ""))
  @test PGExt._checked_params("host=h numeric_overflow=saturate dbname=f1"; parse = relaxed) isa Postgres.ConnectionParams
  # PormG's own policy is not a table: it still refuses what any driver parses.
  @test_throws PormG.InvalidConfigurationError PGExt._checked_params("host=h sslsni=1 reconnect=true dbname=f1"; parse = newer_driver)

  # The driver's own error never rides along: its message may quote the string, and an error thrown
  # inside a `catch` would carry it on the exception stack ("caused by: …").
  # Both explanations: one PormG's parse names, and one only the driver's masked message can give.
  for (dsn, env) in (("host=h password=SECstack sslpassword=SECstack2 dbname=f1", "PGPORT" => nothing),
                     ("host=h password=SECstack dbname=f1", "PGPORT" => "SECstack3"))
    stack = withenv(env) do
      try
        PGExt._checked_params(dsn)
        nothing
      catch
        current_exceptions()
      end
    end
    @test length(stack) == 1
    @test stack[1].exception isa PormG.InvalidConfigurationError
    @test !occursin("SECstack", sprint(showerror, stack[1].exception))
  end
end

@testset "sslmode and gssencmode are refused before any I/O, by name, never by value (#1242)" begin
  # What: a `sslmode`/`gssencmode` value Postgres.jl parses but refuses when it connects — libpq's
  # `allow`/`verify-ca`, an empty value, a password fragment — in keyword form, URL form and from
  # `PGSSLMODE`/`PGGSSENCMODE`. Expected: `_checked_params` refuses it with an
  # `InvalidConfigurationError` that names the setting and lists the values the driver accepts, never
  # the value; the accepted values pass in any case. Why: the driver checks these only after opening
  # the socket, and its `invalid sslmode: <value>` echoes the value — the tail of a password when an
  # unencoded `?` spilled it into the query with no `@` for the #662 check to catch.
  # The accepted set is `_CONNECT_TIME_VALUES`, a copy pinned to the Postgres.jl versions its comment
  # names (#1257). The parity fuzz below cannot cover it: it compares against `Postgres.parse_dsn`, which
  # takes any `sslmode`/`gssencmode`, while the driver checks the value only inside `connect` —
  # `gssencmode` before dialling, `sslmode` once a socket is open — and exposes no constant to compare.
  refusal(dsn) = (try PGExt._checked_params(dsn); "" catch e; e isa PormG.InvalidConfigurationError ? PormG.error_message(e) : rethrow() end)
  withenv("PGSSLMODE" => nothing, "PGGSSENCMODE" => nothing) do
    for (dsn, field) in (("host=h sslmode=allow dbname=f1", "sslmode"),
                         ("host=h sslmode=verify-ca dbname=f1", "sslmode"),
                         ("host=h sslmode=SECssl dbname=f1", "sslmode"),
                         ("postgresql://u:p@h/f1?sslmode=SECurl", "sslmode"),
                         ("host=h gssencmode=SECgss dbname=f1", "gssencmode"),
                         ("postgresql://u:p@h/f1?gssencmode=verify-full", "gssencmode"),
                         # A spilled password tail with no `@` in the query, so the #662 check passes it.
                         ("postgresql://u:1234/f1?gssencmode=SECspill", "gssencmode"))
      msg = refusal(dsn)
      @test occursin("the PostgreSQL connection's `$(field)`", msg)
      @test occursin("is set to a value the Postgres.jl driver does not support", msg)
      @test occursin(field == "sslmode" ? "`disable`, `prefer`, `require` or `verify-full`" :
                                          "`disable`, `prefer` or `require`", msg)
      @test !occursin("SEC", msg) && !occursin("sec", msg)
      @test !occursin("allow", msg) && !occursin("verify-ca", msg)
    end
    # Empty: refused, not taken for "unset" — an unexpanded `${PGSSLMODE}` must fail loudly.
    for dsn in ("host=h sslmode='' dbname=f1", "postgresql://u:p@h/f1?gssencmode=")
      @test occursin("is empty", refusal(dsn))
    end
    # Under `gssencmode=require` the driver never reads `sslmode` (it connects over GSS or fails
    # before TLS), so a `sslmode` it would refuse still connects, and is not refused. `prefer` falls
    # back to TLS and reads it, so it is.
    @test refusal("host=h gssencmode=REQUIRE sslmode=verify-ca dbname=f1") == ""
    @test occursin("`sslmode`", refusal("host=h gssencmode=prefer sslmode=verify-ca dbname=f1"))
    @test occursin("`gssencmode`", refusal("host=h gssencmode=SECg sslmode=verify-ca dbname=f1"))
    # The accepted values pass, compared lower-cased as the driver compares them.
    for dsn in ("host=h sslmode=disable dbname=f1", "host=h sslmode=REQUIRE gssencmode=Prefer dbname=f1",
                "postgresql://u:p@h/f1?sslmode=verify-full&gssencmode=require", "host=h dbname=f1")
      @test refusal(dsn) == ""
    end
  end
  # From the environment: the setting is named, the variable too, the value never.
  msg = withenv(() -> refusal("host=h dbname=f1"), "PGSSLMODE" => "SECenv")
  @test occursin("`sslmode` (from the connection string or `PGSSLMODE`)", msg)
  @test !occursin("SECenv", msg) && !occursin("secenv", msg)
end

@testset "a driver rejection PormG did not anticipate names no parameter (#1235)" begin
  # What: `_parse_failure`, the fallback for whatever Postgres.jl rejects that PormG's own parse cannot
  # attribute — a value from a `PG*` environment variable, or a rule a later release adds. Expected: the message is
  # masked and carries no `(parameter …)` for ANY driver message shape, including the three the old
  # text matching recognised and a forged value that spells one of them. Why: the parameter name now
  # comes only from PormG's own parse; reading it from the driver's prose is what broke on #1233.
  # (This flips the assertions #1233/#1234 made here: they expected the name to be recovered.)
  shapes = [
    "connection parameter \"sslpassword\" is set to a value Postgres.jl does not support and cannot safely ignore",
    "connection parameter \"sslpassword=SECv\" is not supported by Postgres.jl and cannot be safely ignored",
    "invalid value \"x for connection parameter \"sslpassword\"; y\" for connection parameter \"port\"; expected an integer",
    "connection parameter \"service\" is missing '='",
    "unrecognized connection parameter; recognized parameters are host, port",
  ]
  for shape in shapes
    msg = PormG.error_message(PGExt._parse_failure(ArgumentError(shape)))
    @test startswith(msg, "the PostgreSQL connection string could not be parsed")
    @test !occursin("(parameter", msg)
    @test !occursin("sslpassword", msg)
    @test !occursin("SECv", msg)
  end
  # A Base `parse` error reaching it names the rejected character as a `Char` literal, outside the
  # double quotes (#1243): on Postgres.jl 2.2.2, `?password=x=50%off…` with URIs 1.7, or a bracketed
  # host holding `#`, gets past PormG's escape check. Every literal is masked, whatever the shape.
  for (shape, char) in (("invalid base 16 digit 'o' in \"ffSECb\"", "'o'"),
                        ("invalid base 16 digit '\\'' in \"'fSECb\"", "'\\''"),
                        ("invalid base 16 digit '\\x01' in \"\\x01SECb\"", "'\\x01'"),
                        ("invalid base 16 digit 'é' in \"éSECb\"", "'é'"))
    msg = PormG.error_message(PGExt._parse_failure(ArgumentError(shape)))
    @test occursin("invalid base 16 digit '****' in \"****\"", msg)
    @test !occursin(char, msg)
    @test !occursin("SECb", msg)
  end
  # An exception that is not the driver's own is reduced to its type.
  @test PormG.error_message(PGExt._parse_failure(EOFError())) ==
        "the PostgreSQL connection string could not be parsed (EOFError)"

  # End to end: a bad `PGPORT` is the driver's to reject, so nothing is named and its value is masked.
  err = withenv("PGPORT" => "SECenv") do
    try PGExt._checked_params("host=h dbname=f1"); nothing catch e; e end
  end
  @test err isa PormG.InvalidConfigurationError
  @test !occursin("SECenv", PormG.error_message(err))
  @test !occursin("(parameter", PormG.error_message(err))
end

@testset "PormG's DSN tokenizer agrees with Postgres.parse_dsn (#1235)" begin
  # What: the parity PormG's own pass depends on — whatever Postgres.jl accepts, PormG accepts, with
  # the same value for every key; whatever PormG accepts, Postgres.jl accepts (keyword form; a URL the
  # driver cannot parse is its own, quote-free refusal); and no refusal ever carries a value. Checked
  # on grammar rows (quoting, `\` escapes, `;`, upper-case keys, spaces around `=`, URL `+`/`%xx`, and
  # `%xx` before the query, #1243) and on a seeded fuzz. Why: a tokenizer that disagreed would refuse a valid string — a behavior change
  # for a working app — or name the wrong key. Compared through the public `Postgres.parse_dsn` only,
  # so a renamed driver internal cannot turn this red. Not covered here: the `sslmode`/`gssencmode`
  # values the driver accepts only in `connect` — see the #1242 testset above (#1257).
  string_fields = ("host", "user", "password", "dbname", "application_name", "options", "sslrootcert",
                   "sslcert", "sslkey", "sslcapath", "sslservername", "krbsrvname")
  problems = String[]
  function compare(dsn)
    mine = try
      PGExt._check_dsn(dsn)
      PGExt._is_url(dsn) ? PGExt._url_query_params(dsn) : PGExt._keyword_dsn_params(dsn)
    catch e
      e isa PormG.InvalidConfigurationError || rethrow()
      e
    end
    theirs = try Postgres.parse_dsn(dsn) catch e; e end
    if mine isa Exception
      occursin("SEC", PormG.error_message(mine)) && push!(problems, "leak: $(repr(dsn))")
      theirs isa Exception || push!(problems, "refused by PormG only: $(repr(dsn))")
    elseif theirs isa Exception
      PGExt._is_url(dsn) || push!(problems, "refused by the driver only: $(repr(dsn))")
    else
      for p in values(Dict(p.key => p for p in mine))
        p.key in string_fields || continue
        getfield(theirs, Symbol(p.key)) in p.values || push!(problems, "value of $(p.key) differs: $(repr(dsn))")
      end
    end
  end

  grammar = [
    "host=h password='two words' dbname=f1", "host=h password='it\\'s' dbname=f1",
    "host=h password='back\\\\slash' dbname=f1", "host=h password=bare\\ space dbname=f1",
    "host=h;port=5432;dbname=f1", "HOST=h Port = 5432 dbname= f1", "host=h\tdbname=f1",
    "host=h options='-c search_path=x' dbname=f1", "host=h password='' dbname=f1", "host=h port= dbname=f1",
    "host=h password='SECa'SECb dbname=f1", "host=h password='SECa", "host=h password=SECa\\",
    "postgresql://u:p@h/f1?application_name=a+b&options=-c%20x%3D1",
    "postgresql://u:p@h/f1?port=5#x=SEC", "postgresql://u:p@h/f1#?port=SEC",
    "postgresql://u:p@h/f1?client_encoding=UTF8&channel_binding=prefer",
    # Escapes before the query (#1243): an IPv6 zone id is `%25`-encoded, and a fragment is not decoded.
    "postgresql://u:p%41@h/f%C3%A91", "postgresql://u:p@[fe80::1%25eth0]/f1", "postgresql://u:p@h/f1#%zz",
  ]
  # The URL prefixes the fuzz puts its query on: well-formed, and each slot with a bad escape.
  url_prefixes = ["postgresql://u:p@h/f1?", "postgresql://u:%41@h/f1?", "postgresql://u:p%zz@h/f1?",
                  "postgresql://u%4:p@h/f1?", "postgresql://u:p@h%zz/f1?", "postgresql://u:p@h/f%z?",
                  "postgresql://u:p@[fe80::1%eth0]/f1?"]

  # Seeded fuzz: half structured `key=value` lists, half random concatenations of grammar pieces.
  # A seeded xorshift64, so the file needs no `Random` in the test environment.
  state = Ref(UInt64(1235))
  next!() = (x = state[]; x ⊻= x << 13; x ⊻= x >> 7; x ⊻= x << 17; state[] = x)
  pick(xs) = xs[Int(next!() % UInt64(length(xs))) + firstindex(xs)]
  chance(p) = next!() % 1000 < p * 1000
  fuzz_keys = ["host", "port", "password", "sslpassword", "options", "debug", "numeric_overflow",
          "channel_binding", "sslmode", "service", "sslsni", "SEC", "Host", "connect_timeout",
          "reconnect", "client_encoding", "application_name", "user", "dbname", "gssdelegation"]
  vals = ["", "5", " 7 ", "on", "warn", "prefer", "UTF8", "x y", "a'b", "a\\b", "SEC", "SEC;x", "off",
          "-c x=1", "é", "%41", "%zz", "+", "a&b", "a=b", "#", "maybe", "SEC=x", "%ff", "%C0%80", "%e9"]
  pieces = ["host", "port", "password", "sslpassword", "debug", "service", "SEC", "PORT", "=", "=",
            " ", ";", "'", "\\", "x", "5", "on", "\t", "é", "%41", "%zz", "+", "&", "?", "#", "@", "\""]
  kwquote(v) = "'" * replace(v, "\\" => "\\\\", "'" => "\\'") * "'"
  kwbare(v) = replace(v, "\\" => "\\\\", " " => "\\ ", ";" => "\\;", "'" => "\\'")
  withenv([k => nothing for k in keys(ENV) if startswith(k, "PG")]...) do
    foreach(compare, grammar)
    for _ in 1:20_000
      url = chance(0.4)
      body = if chance(0.5)
        parts = [(k = pick(fuzz_keys); v = pick(vals);
                  url ? "$(k)=$(v)" : k * pick(["=", " = "]) * (chance(0.4) ? kwquote(v) : kwbare(v)))
                 for _ in 1:pick(1:5)]
        join(parts, url ? "&" : pick([" ", ";", "\t"]))
      else
        join(pick(pieces) for _ in 1:pick(1:12))
      end
      compare(url ? (chance(0.7) ? first(url_prefixes) : pick(url_prefixes)) * body : body)
    end
  end
  @test isempty(problems)
  isempty(problems) || foreach(println, first(problems, 20))
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

# What: SQLSTATE 57014 is a cancelled statement on both PostgreSQL drivers, and no other code is;
#   `with_read_retry` runs a cancelled read once and a deadlocked read twice. The pools are built,
#   never connected; each error goes through `_as_database_error` as a failed statement's does.
# Expected: `backend_is_cancellation` answers true for 57014 (Postgres.jl's `Error`, LibPQ's
#   `QueryCanceled`) and false for 40P01 / 55P03 / 57P01; a 57014 block runs 1 time, a 40P01 block 2.
# Why: core asks each engine what a cancel is (#1277) instead of comparing PostgreSQL's code, so
#   the PostgreSQL answer has to be stated here, by the extensions, or a timed-out read would run twice.
@testset "a cancelled statement is 57014 on both PostgreSQL drivers, and is not retried (#1277)" begin
  E = LibPQ.Errors
  @test PormG.backend_is_cancellation(_pg_error("57014"))
  @test PormG.backend_is_cancellation(E.QueryCanceled("", nothing))
  for code in ("40P01", "55P03", "57P01", "08006")
    @test !PormG.backend_is_cancellation(_pg_error(code))
  end
  @test !PormG.backend_is_cancellation(E.DeadlockDetected("", nothing))
  @test !PormG.backend_is_cancellation(E.LockNotAvailable("", nothing))
  @test !PormG.backend_is_cancellation(EOFError())
  @test PormG.backend_is_cancellation(CompositeException([EOFError(), _pg_error("57014")]))

  runs_of(pool, cause) = begin
    err = CP._as_database_error(pool, cause)
    @test err isa PormG.OperationalError
    runs = Ref(0)
    caught = try
      with_read_retry(; attempts = 1) do
        runs[] += 1
        throw(err)
      end
      nothing
    catch e
      e
    end
    @test caught === err   # the block's own error, never one the cancel check raised
    runs[]
  end
  pg = CP.PostgresConnectionPool("host=h"; driver = :postgres)
  lpq = CP.PostgresConnectionPool("host=h"; driver = :libpq)
  @test runs_of(pg, _pg_error("57014")) == 1
  @test runs_of(lpq, E.QueryCanceled("", nothing)) == 1
  @test_logs (:warn, r"with_read_retry") @test runs_of(pg, _pg_error("40P01")) == 2
  @test_logs (:warn, r"with_read_retry") @test runs_of(lpq, E.DeadlockDetected("", nothing)) == 2
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
