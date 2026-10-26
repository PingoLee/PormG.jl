# ============================================================
# test/unit/test_mysql_ext.jl
#
# The MySQL driver extension (#1130, phase 1), hermetically.
#
# CONTRACT being tested:
#   `ext/PormGMySQLExt.jl` serves exactly `MySQLConnectionPool`, and loading it beside the other driver
#   extensions introduces no method ambiguity. `adapter: MySQL` builds that pool from connection.yml's
#   keys into a conninfo that `redact_secret` masks and the extension reads back exactly, and the
#   PostgreSQL-only keys are refused rather than dropped. Errors classify by MySQL's error number
#   (SQLSTATE `HY000` covers both statements and connections), the server's text survives only for
#   numbers whose text names objects, no failure is retry-safe (2006 is raised whether or not the
#   statement ran), a cancelled statement (1317, 3024) is not re-run by `with_read_retry` (#1277), and
#   an interrupt a wrapper carries in `.cause` is rethrown bare. The capability
#   table refuses a server older than 8.4 (#1264) in its own words. A DATETIME(6) value with digits
#   below the millisecond is refused, never truncated to a `DateTime` (#1270 decides what it reads as).
#
# No live database: parsers and classifiers are exercised directly. The connection, the pool,
# cancellation and advisory locks run against a live MySQL in
# `test/integration/test_mysql_backend.jl` (PORMG_DB=db_my).
#
# Run: julia --project=test/integration test/unit/test_mysql_ext.jl
# ============================================================

using Test
using PormG
using DataFrames, Decimals
import Dates

include(joinpath(@__DIR__, "..", "load_drivers.jl"))

const _MyCP = PormG.ConnectionPool
const _MyExt = Base.get_extension(PormG, :PormGMySQLExt)
const _MyPool = _MyCP.MySQLConnectionPool
const _MyConn = MySQL.Connection
const _MyP = MySQL.Protocol

_my_pool(conninfo = "host='127.0.0.1' user='u' password='p' dbname='f1'") = _MyPool(conninfo; pool_size = 1)
_my_err(errno, sqlstate = "HY000"; msg = "boom") = MySQL.Error(errno, msg, sqlstate)

# An exception carrying another in `.cause`, as the TLS layer's error does.
struct _MyCauseWrapper1130 <: Exception
  cause
end

# What: every backend generic resolves to the MySQL extension for a MySQL pool, and adding it to the
#   other three extensions creates no ambiguous method.
# Why: a method typed on the wrong pool (or left to a fallback) is unreachable or reaches another
#   driver's code; Aqua's ambiguity check loads no extension, so it cannot see this.
@testset "the MySQL extension loads and serves MySQL pools (#1130)" begin
  @test _MyExt !== nothing
  rows = [
    (PormG.backend_connect, (_MyPool,)),
    (PormG.backend_renew_connection, (_MyPool, _MyConn)),
    (PormG.backend_is_alive, (_MyPool, _MyConn)),
    (PormG.backend_execute, (_MyPool, _MyConn, String, Any)),
    (PormG.backend_execute_async, (_MyPool, _MyConn, String, Any)),
    (PormG.backend_is_connection_error, (_MyPool, Any)),
    (PormG.backend_is_permanent_connect_error, (_MyPool, Any)),
    (PormG.backend_classify_error, (_MyPool, MySQL.Error)),
    (PormG.backend_cancel_query!, (_MyPool, _MyConn)),
    (PormG.backend_drain_connection!, (_MyPool, _MyConn)),
    (PormG.backend_num_affected_rows, (_MyPool, _MyExt.MySQLResult)),
    (PormG.backend_num_rows, (_MyPool, _MyExt.MySQLResult)),
    (PormG.backend_mysql_version, (_MyPool,)),
    (PormG.backend_error_fields, (MySQL.Error,)),
    (PormG.backend_is_cancellation, (MySQL.Error,)),
  ]
  for (f, types) in rows
    @test which(f, Tuple{types...}).module === _MyExt
  end
  # Deliberately NOT the extension's: every MySQL failure keeps core's "not retry-safe" (#1042),
  # and COPY / the SQLite version are other engines' generics.
  @test which(PormG.backend_is_retry_safe, Tuple{_MyPool, MySQL.Error}).module === PormG
  ext_modules = Tuple(m for m in (Base.get_extension(PormG, n) for n in
                     (:PormGMySQLExt, :PormGLibPQExt, :PormGPostgresExt, :PormGSQLiteExt)) if m !== nothing)
  ambiguous = filter(Test.detect_ambiguities(PormG, ext_modules...; recursive = true)) do (a, b)
    a.module === _MyExt || b.module === _MyExt
  end
  @test isempty(ambiguous)
end

# What: connection.yml's keys become a conninfo the extension reads back value for value, with the
#   password masked wherever the conninfo is shown, and PostgreSQL-only keys refused by name.
# Why: the pool keeps its connection info as one string so every log line, the REPL card and
#   `PoolConnectError` mask it with the same `redact_secret`; a value with a quote, a backslash or a
#   space must survive the round trip, and `passfile:` silently dropped would connect without it.
@testset "connection.yml keys round-trip through the MySQL conninfo (#1130)" begin
  db = Dict{String, Any}("adapter" => "MySQL", "host" => "db.example", "port" => 3307,
                         "username" => "f1 user", "password" => "s3cr'et\\ hunter", "database" => "f1",
                         "connect_timeout" => 5, "sslmode" => "verify_ca", "sslrootcert" => "/etc/ca.pem")
  info = PormG.Configuration._mysql_conninfo(db)
  parsed = _MyExt._parse_conninfo(info)
  @test parsed == Dict("host" => "db.example", "port" => "3307", "user" => "f1 user",
                       "password" => "s3cr'et\\ hunter", "dbname" => "f1", "connect_timeout" => "5",
                       "sslmode" => "verify_ca", "sslrootcert" => "/etc/ca.pem")
  masked = PormG.Configuration.redact_secret(info)
  @test !occursin("s3cr", masked) && !occursin("hunter", masked) && occursin("dbname='f1'", masked)

  host, user, password, kw = _MyExt._connect_args(parsed)
  @test (host, user, password) == ("db.example", "f1 user", "s3cr'et\\ hunter")
  @test kw.port == 3307 && kw.db == "f1" && kw.connect_timeout == 5
  @test kw.ssl_mode === :verify_ca && kw.ssl_ca == "/etc/ca.pem"
  @test kw.reconnect === false && kw.found_rows === true   # never a driver reconnect; matched-row counts

  for key in ("url", "hostaddr", "passfile", "client_encoding", "postgres_driver", "extensions")
    e = try PormG.Configuration._mysql_conninfo(Dict{String, Any}("adapter" => "MySQL", key => "SECRETVALUE")); nothing catch err; err end
    @test e isa PormG.InvalidConfigurationError
    @test occursin("`$(key):`", sprint(showerror, e)) && !occursin("SECRETVALUE", sprint(showerror, e))
  end
  e = try _MyExt._connect_args(Dict("sslmode" => "allow")); nothing catch err; err end
  @test e isa PormG.InvalidConfigurationError && occursin("verify_identity", sprint(showerror, e))
  for bad in ("SECRET", "3306.5", "-1", "99999999999999999999")
    e = try _MyExt._connect_args(Dict("port" => bad)); nothing catch err; err end
    @test e isa PormG.InvalidConfigurationError && !occursin(bad, sprint(showerror, e))
  end
  # `connect_timeout: 0` is libpq's "no timeout": the keyword is left out, as MySQL.jl spells it.
  @test !haskey(_MyExt._connect_args(Dict("connect_timeout" => "0"))[4], :connect_timeout)
  @test _MyExt._connect_args(Dict("connect_timeout" => "7"))[4].connect_timeout == 7
  @test_throws PormG.InvalidConfigurationError _MyExt._parse_conninfo("host='unterminated")
end

# What: a folder with `adapter: MySQL` loads into a MySQL pool without connecting, displays as one,
#   and `register_connection` refuses MySQL (it takes a URL, which MySQL does not yet).
# Why: `load` checks the driver extension and the built-in ignore list before it builds the pool;
#   before #1130 every `adapter: MySQL` stopped at "Unsupported adapter".
@testset "adapter: MySQL loads into a MySQL pool (#1130)" begin
  mktempdir() do root
    dir = joinpath(root, "db_my_unit")
    mkpath(dir)
    write(joinpath(dir, "connection.yml"),
          "test:\n  adapter: MySQL\n  host: 127.0.0.1\n  port: 3307\n  username: u\n  password: hunter2\n" *
          "  database: f1\n  config:\n    change_db: true\n    change_data: true\n")
    PormG.Configuration.load(dir; env = "test")
    try
      pool = PormG.config[dir].connections
      @test pool isa _MyPool
      @test PormG.Kernel._backend_name(pool) == "MySQL"
      @test PormG.Kernel._engine_key(pool) === :mysql
      @test sprint(show, pool) == "Pool(MySQL, 3 slots)"
      card = sprint(show, MIME"text/plain"(), pool)
      @test occursin("dbname='f1'", card) && !occursin("hunter2", card)
    finally
      PormG.Configuration.unregister_connection(dir)
    end
  end
  e = try PormG.Configuration.register_connection("my_dyn_1130", "mysql://u:p@h/f1"; adapter = "MySQL", env = "dev"); nothing catch err; err end
  @test e isa PormG.InvalidConfigurationError && occursin("connection.yml", sprint(showerror, e))
  @test !haskey(PormG.config, "my_dyn_1130")
end

# What: MySQL's error numbers classify into the taxonomy; lost connections are recognised from the
#   number, MySQL.jl's own closed-connection text, the transport, or a wrapper's cause.
# Why: SQLSTATE `HY000` covers 1205 (lock wait), 3024 (statement timeout) and 2006 (server gone), so
#   only the number classifies them; a wrongly "operational" constraint violation would be retried by
#   a caller that backs off on `OperationalError`.
@testset "MySQL errors classify by error number (#1130)" begin
  pool = _my_pool()
  classify(e) = PormG.backend_classify_error(pool, e)
  @test classify(_my_err(1062, "23000")) === :integrity
  @test classify(_my_err(1452, "23000")) === :integrity
  @test classify(_my_err(1048, "23000")) === :integrity
  @test classify(_my_err(3819)) === :integrity              # CHECK constraint, SQLSTATE HY000
  @test classify(_my_err(1205)) === :operational            # lock wait timeout, HY000
  @test classify(_my_err(1213, "40001")) === :operational   # deadlock
  @test classify(_my_err(3024)) === :operational            # MAX_EXECUTION_TIME
  @test classify(_my_err(1317, "70100")) === :operational   # KILL QUERY
  @test classify(_my_err(2006)) === :operational
  @test classify(_my_err(1064, "42000")) === :statement
  # 1052 (an ambiguous column) is filed under SQLSTATE 23000 (measured on 8.4): a broken query, not a
  # constraint, so the class is not a fallback.
  @test classify(_my_err(1052, "23000")) === :statement
  @test classify(_my_err(1022, "23000")) === :integrity
  @test classify(_my_err(1146, "42S02")) === :statement
  @test classify(MySQL.StmtError(1062, "dup", "23000")) === :integrity
  @test classify(_MyP.AuthError("denied")) === :operational
  @test classify(ErrorException("unrelated")) === :unknown

  lost(e) = PormG.backend_is_connection_error(pool, e)
  @test lost(_my_err(2006)) && lost(_my_err(2013)) && lost(_my_err(4031))
  @test !lost(_my_err(1062, "23000")) && !lost(_my_err(1205))
  @test lost(ErrorException("mysql connection has been closed or disconnected"))
  @test !lost(ErrorException("something else"))
  @test lost(_MyP.ProtocolError("TLS transport failure (read)"))
  @test lost(_MyP.TimeoutError("read timed out"))
  @test lost(EOFError()) && lost(Base.IOError("reset", -104))
  @test lost(_MyCauseWrapper1130(_my_err(2013)))
  @test lost(CompositeException([ErrorException("x"), _my_err(2006)]))

  # 2006 is raised for a committed INSERT whose reply was lost, so nothing is retry-safe (#1042).
  for e in (_my_err(2006), _my_err(2013), ErrorException("mysql connection has been closed or disconnected"))
    @test PormG.backend_is_retry_safe(pool, e) === false
  end

  permanent(e) = PormG.backend_is_permanent_connect_error(pool, e)
  @test permanent(_my_err(1045, "28000")) && permanent(_my_err(1049, "42000"))
  @test permanent(_my_err(1130)) && permanent(_my_err(3159))   # host not allowed; TLS required
  @test permanent(_MyP.AuthError("caching_sha2_password requires a secure connection"))
  @test permanent(PormG.BackendCapabilityError("old server"))
  @test permanent(PormG.InvalidConfigurationError("bad"))
  @test !permanent(_my_err(2006)) && !permanent(_my_err(1062, "23000"))
end

# What: the error's fields carry MySQL's SQLSTATE, and its text only for numbers whose text names
#   objects; through `_as_database_error` the duplicate value never reaches the rendered message.
# Why: `Duplicate entry 'Senna' for key …` (1062) and `Incorrect … value: '…'` (1292) quote the row;
#   #987 keeps a row's values out of every error's text.
@testset "MySQL error text is kept only where it names no value (#1130)" begin
  pool = _my_pool()
  f = PormG.backend_error_fields(_my_err(1062, "23000"; msg = "Duplicate entry 'Senna' for key 'driver.surname'"))
  @test f.sqlstate == "23000" && f.message === nothing
  @test PormG.backend_error_fields(_my_err(1292, "22007"; msg = "Incorrect datetime value: 'x1991'")).message === nothing
  @test PormG.backend_error_fields(_my_err(1064, "42000"; msg = "near 'SELECT secret'")).message === nothing
  f = PormG.backend_error_fields(_my_err(1146, "42S02"; msg = "Table 'f1.nope' doesn't exist"))
  @test f.message == "Table 'f1.nope' doesn't exist"
  @test (f.constraint, f.table, f.column) === (nothing, nothing, nothing)   # the ERR packet has none
  @test PormG.backend_error_fields(_my_err(2006; msg = "")).message === nothing

  e = _MyCP._as_database_error(pool, _my_err(1062, "23000"; msg = "Duplicate entry 'Senna' for key 'driver.surname'"))
  @test e isa PormG.IntegrityError && e.adapter == "MySQL"
  @test !occursin("Senna", sprint(showerror, e))
  @test (e.table, e.constraint) == ("driver", "surname")
end

# What: a duplicate key (1062) names its key in `constraint`, and its table in `table` when the text
#   qualifies it, as PostgreSQL's error does; the value in the same text is never read.
# Expected: `for key 'driver.surname'` → ("driver", "surname"); a bare `for key 'PRIMARY'` → (nothing,
#   "PRIMARY"); a value that spells ` for key 'x.y'` still gives the real key, which ends the text. Every
#   ambiguous text gives (nothing, nothing): a key name holding a quote, a name with two dots, a part
#   longer than an identifier, MySQL's `*UNKNOWN*`, a text at the 512-byte message limit (which the
#   server may have cut inside the value), and a text with no key.
# Why: the message is dropped because it quotes the value (#987), which left a caller nothing to tell
#   which unique key a row broke; the key name is the part of the text that is safe.
@testset "a MySQL duplicate key names its key, never its value (#1130)" begin
  dup(msg) = (f = PormG.backend_error_fields(_my_err(1062, "23000"; msg = msg)); (f.table, f.constraint, f.message))
  @test dup("Duplicate entry 'Senna' for key 'driver.surname'") == ("driver", "surname", nothing)
  @test dup("Duplicate entry '7' for key 'PRIMARY'") == (nothing, "PRIMARY", nothing)
  @test dup("Duplicate entry 'a' for key 'x.y' for key 'driver.driverref'") == ("driver", "driverref", nothing)
  @test dup("Duplicate entry 'a' for key 'driver.it's'") == (nothing, nothing, nothing)
  @test dup("Duplicate entry 'a'") == (nothing, nothing, nothing)
  # A name with two dots cannot be split (a quoted table or key name can hold one): no name, not a guess.
  @test dup("Duplicate entry 'a' for key 'circuit.idx.v2'") == (nothing, nothing, nothing)
  @test dup("Duplicate entry 'a' for key '*UNKNOWN*'") == (nothing, nothing, nothing)
  @test dup("Duplicate entry 'a' for key 'driver.$("k" ^ 65)'") == (nothing, nothing, nothing)
  # A text at MySQL's 512-byte message limit may have been cut inside a long value, so the value's own
  # ` for key 'x.y'` could end it: read as no name. One byte under the limit, the key is read.
  sized(n, tail) = "Duplicate entry '" * "a" ^ (n - 17 - ncodeunits(tail)) * tail
  cut = sized(511, " for key 'evil.k'")              # the value's own text, where the server cut it
  @test ncodeunits(cut) == 511 && dup(cut) == (nothing, nothing, nothing)
  whole = sized(510, "' for key 'driver.surname'")
  @test ncodeunits(whole) == 510 && dup(whole) == ("driver", "surname", nothing)
  # Only 1062 is read: another integrity number's text keeps its own fields.
  f = PormG.backend_error_fields(_my_err(1451, "23000"; msg = "Cannot delete or update a parent row"))
  @test (f.table, f.constraint) === (nothing, nothing)
end

# What: the #1277 repro on a MySQL pool object (built, never connected). 1317 (`KILL QUERY`,
#   SQLSTATE 70100) and 3024 (`max_execution_time`, HY000) become `OperationalError`s through
#   `_as_database_error`, as a failed statement's error does, and `with_read_retry(; attempts = 1)`
#   runs the block that raises them once. 1205 (lock wait timeout) and 1213 (deadlock) are
#   `OperationalError`s too, and are run twice.
# Expected: `backend_is_cancellation` is true for 1317 and 3024 only; the run counts are 1, 1, 2, 2.
# Why: neither number carries PostgreSQL's 57014, so the old core comparison ran a cancelled or
#   timed-out read a second time (2 runs measured on main) — a slow query took `max_execution_time`
#   once per attempt, and a `KILL QUERY` was undone by the retry.
@testset "a cancelled MySQL statement is not retried by with_read_retry (#1277)" begin
  pool = _my_pool()
  @test PormG.backend_is_cancellation(_my_err(1317, "70100"))
  @test PormG.backend_is_cancellation(_my_err(3024))
  @test PormG.backend_is_cancellation(MySQL.StmtError(3024, "x", "HY000"))
  for errno in (1205, 1213, 2006, 2013, 1062)
    @test !PormG.backend_is_cancellation(_my_err(errno))
  end
  @test !PormG.backend_is_cancellation(_MyP.TimeoutError("read timed out"))   # a client timeout closes the connection

  function runs_of(cause)
    err = _MyCP._as_database_error(pool, cause)
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
    return runs[]
  end
  @test runs_of(_my_err(1317, "70100")) == 1
  @test runs_of(_my_err(3024)) == 1
  @test_logs (:warn, r"with_read_retry") @test runs_of(_my_err(1205)) == 2
  @test_logs (:warn, r"with_read_retry") @test runs_of(_my_err(1213, "40001")) == 2
end

# What: an `InterruptException` a wrapper carries in `.cause` is rethrown bare; any other failure
#   passes through untouched.
# Why: core recognises an abandoned await by the `InterruptException` (#315); the TLS layer wraps it.
@testset "a wrapped interrupt is rethrown bare (#315, #1130)" begin
  @test_throws InterruptException _MyExt._with_bare_interrupt(() -> throw(_MyCauseWrapper1130(InterruptException())))
  @test_throws ErrorException _MyExt._with_bare_interrupt(() -> error("plain"))
  @test _MyExt._with_bare_interrupt(() -> 42) == 42
end

# What: read values become PormG's types, and a materialized result is a Tables.jl table that also
#   iterates as row tuples.
# Why: MySQL.jl decodes DECIMAL to a `DecimalValue`, which no other PormG path understands; core's
#   driver-level callers (`AdvisoryLock`) read `collect(result)[1][1]`.
@testset "MySQL values and results take PormG's shapes (#1130)" begin
  d = _MyExt._read_value(MySQL.DataDecimals.DecimalValue("1234567.125"))
  # Built with the three-argument constructor, the spelling Decimals 0.4 and 0.5 share.
  @test d isa Decimals.Decimal && d == Decimals.Decimal(0, 1234567125, -3)
  @test _MyExt._read_value(MySQL.DataDecimals.DecimalValue("-0.500")) == Decimals.Decimal(1, 5, -1)
  @test iszero(_MyExt._read_value(MySQL.DataDecimals.DecimalValue("0.000")))
  @test _MyExt._bind_value(Decimals.Decimal(0, 255, -1)) == "25.5"
  @test _MyExt._bind_value(Decimals.Decimal(0, 1, 1)) == "10"   # never `1E+1` (Decimals 0.5's spelling)
  @test _MyExt._read_value(missing) === missing && _MyExt._read_value(7) === 7

  r = _MyExt.MySQLResult([:id, :surname], AbstractVector[[1, 2], ["Senna", "Prost"]], 2, 0, UInt64(0), "")
  df = DataFrame(r)
  @test df.surname == ["Senna", "Prost"] && eltype(df.id) == Int
  @test collect(r) == [(1, "Senna"), (2, "Prost")]
  @test PormG.backend_num_rows(_my_pool(), r) == 2
  empty = _MyExt.MySQLResult(Symbol[], AbstractVector[], 0, 3, UInt64(5), "Records: 3  Duplicates: 1  Warnings: 0")
  @test PormG.backend_num_affected_rows(_my_pool(), empty) == 3 && isempty(collect(empty))
  # The OK packet's text after a multi-row INSERT, as `bulk_insert` counts its skips by it (#1267).
  @test PormG.backend_insert_report(_my_pool(), empty) == (records = 3, duplicates = 1)
  @test PormG.backend_insert_report(_my_pool(), r) === nothing
end

# What: a `Timestamp{Microsecond}` (a DATETIME(6) or TIMESTAMP(6) column) with digits below the
#   millisecond is refused, with or without a column, by an `InvalidValueError` that names its
#   precision and #1270, carries the column as `field`, and never the value; one whose
#   sub-millisecond part is zero reads as a `DateTime`, as does a `Timestamp{Millisecond}`.
# Why: a `DateTime` holds milliseconds, so `DateTime(v)` dropped the last three digits silently,
#   and raw `fetch` is a public path. What a `DateTimeField` declares on MySQL is #1270's decision.
@testset "a DATETIME(6) value finer than a millisecond is refused, not truncated (#1130, #1270)" begin
  fine = MySQL.Timestamp{Dates.Microsecond}(2026, 10, 16, 12, 34, 56, 789, 123)
  e = try _MyExt._read_value(fine, :fastest_lap_at); nothing catch err; err end
  @test e isa PormG.InvalidValueError && e.kind === :range
  @test e.field == "fastest_lap_at" && e.op == "a MySQL read"
  @test occursin("`fastest_lap_at`", e.msg) && occursin("microsecond precision", e.msg)
  @test occursin("DATETIME(6)", e.msg) && occursin("#1270", e.msg)
  @test !occursin("2026", e.msg) && !occursin("789", e.msg) && !occursin("123", e.msg)
  # One decision for every caller: the column-less form refuses too, rather than truncating.
  @test_throws PormG.InvalidValueError _MyExt._read_value(fine)

  whole = MySQL.Timestamp{Dates.Microsecond}(2026, 10, 16, 12, 34, 56, 789, 0)
  @test _MyExt._read_value(whole, :fastest_lap_at) === Dates.DateTime(2026, 10, 16, 12, 34, 56, 789)
  milli = MySQL.Timestamp{Dates.Millisecond}(2026, 10, 16, 12, 34, 56, 789)
  @test _MyExt._read_value(milli, :fastest_lap_at) === Dates.DateTime(2026, 10, 16, 12, 34, 56, 789)
  @test _MyExt._read_value(missing, :fastest_lap_at) === missing
end

# What: the capability table refuses a MySQL server older than 8.4 in its own words, and names
#   MySQL in it; the version numbers read as MySQL writes them.
# Why: #1264 — MySQL 8.4 is the floor. An 8.0 server is refused when a connection opens rather than
#   served SQL no one ran on it.
struct _MyAt1130 <: PormG.PormGMySQL
  v::Int
end
PormG.backend_mysql_version(c::_MyAt1130) = c.v
@testset "the capability table refuses MySQL below 8.4 (#1264)" begin
  @test _MyExt._version_number(v"8.4.11") == 80_411
  @test PormG._version_text(PormG.PormGMySQL, 80_400) == "8.4"
  @test PormG._supports(_MyAt1130(80_411), :supported_server)
  @test !PormG._supports(_MyAt1130(80_036), :supported_server)
  e = PormG._capability_error(_MyAt1130(80_036), :supported_server, "Connecting to MySQL")
  @test sprint(showerror, e) == "Connecting to MySQL needs MySQL 8.4 or newer, " *
                               "for a server version PormG is verified against; this server is 8.0.36."
  @test PormG._supports(_MyAt1130(80_411), :advisory_locks)
  @test !PormG._supports(_MyAt1130(80_411), :jsonb_operators)   # every other row waits for its phase
end

# What: `with_advisory_lock` on a MySQL pool sends `GET_LOCK` with its key and the `:block` timeout in
#   whole seconds, rounded UP, `-1` for `timeout_ms = 0`, and releases the lock it took.
# Why: MySQL rounds a fractional timeout to the NEAREST second (measured: 0.3 does not wait at all),
#   so a millisecond timeout passed through would shorten or remove the wait; `0` must mean no bound,
#   as `lock_timeout = 0` does on PostgreSQL (#1269).
struct _MyLockConn1130
  closed::Bool
end
mutable struct _MyLockPool1130 <: PormG.PormGMySQL
  connections::Vector{Any}
  available::Vector{Bool}
  connection_string::String
  pool_size::Int
  lock::ReentrantLock
  calls::Vector{Tuple{String, Vector{Any}}}
end
_MyLockPool1130() = _MyLockPool1130(Any[_MyLockConn1130(false)], [true], "mock://my", 1, ReentrantLock(), [])
PormG.backend_is_alive(::_MyLockPool1130, conn) = conn isa _MyLockConn1130
PormG.backend_connect(::_MyLockPool1130; kwargs...) = _MyLockConn1130(false)
function PormG.backend_execute_async(pool::_MyLockPool1130, conn, sql::String, params)
  push!(pool.calls, (sql, collect(Any, something(params, Any[]))))
  return @async Any[(1,)]
end
@testset "GET_LOCK takes whole seconds, rounded up (#1269)" begin
  for (ms, seconds) in ((300, 1), (1_000, 1), (2_001, 3), (0, -1))
    pool = _MyLockPool1130()
    @test PormG.with_advisory_lock(() -> :ran, pool, "k1130"; wait = true, strategy = :block, timeout_ms = ms) === :ran
    sql, params = pool.calls[1]
    @test occursin("GET_LOCK(", sql) && occursin("DATABASE()", sql)
    @test params == Any["k1130", seconds]
    @test occursin("RELEASE_LOCK(", pool.calls[end][1]) && pool.calls[end][2] == Any["k1130"]
    @test length(pool.calls) == 2      # nothing set on the session, nothing to restore
    @test pool.available[1]
  end
  pool = _MyLockPool1130()
  @test PormG.with_advisory_lock(() -> :ran, pool, "k1130") === :ran   # wait = false: GET_LOCK(…, 0)
  @test occursin("GET_LOCK(", pool.calls[1][1]) && occursin(", 0)", pool.calls[1][1])
end

# ─────────────────────────────────────────────────────────────────────────────
# MySQL session pins: the collation and the decimal precision a statement reads with (#1265, #1270)
# A comparison of two parameters takes the connection collation, so it is pinned to the code-point,
# no-pad `utf8mb4_0900_bin` a PormG column declares; `div_precision_increment` is pinned to its
# maximum so `AVG` of integers is not cut to 4 decimals. Expected: both in the one SET statement every
# connection runs, beside the UTC zone and 8.4's sql_mode. The live values are read back in
# `test/integration/test_mysql_reads.jl`.
# ─────────────────────────────────────────────────────────────────────────────
@testset "the MySQL session pins its collation and decimal precision (#1265, #1270)" begin
  sql = _MyExt._SESSION_SQL
  @test occursin("collation_connection = 'utf8mb4_0900_bin'", sql)
  @test occursin("div_precision_increment = 30", sql)
  @test occursin("time_zone = '+00:00'", sql) && !occursin("ANSI_QUOTES", sql) && !occursin("PIPES_AS_CONCAT", sql)
  # A written 0 key is stored as 0, as on PostgreSQL and SQLite, not replaced by a generated id.
  @test occursin("NO_AUTO_VALUE_ON_ZERO", sql)
end

# ─────────────────────────────────────────────────────────────────────────────
# A bulk statement stays under MySQL.jl's parameter limit (#84, #1130)
# MySQL.jl refuses a prepared statement with more parameters than its `max_columns` (4096 by default)
# before sending it, with a `ProtocolError`, though the protocol counts up to 65535. Expected: a MySQL pool
# answers the driver's limit, read from MySQL.jl, and a bulk write of nine-column rows takes 455 a chunk;
# a pool the extension does not serve (a mock, `show_query` only) answers the protocol's 65535.
# ─────────────────────────────────────────────────────────────────────────────
@testset "a MySQL bulk statement stays under MySQL.jl's parameter limit (#84, #1130)" begin
  pool = _my_pool()
  @test PormG.backend_mysql_parameter_limit(pool) == _MyP.Limits().max_columns == 4096
  @test PormG.QueryBuilder._backend_parameter_limit(pool) == 4096
  @test PormG.QueryBuilder._bulk_chunk_rows(pool, 100_000, 9, 0, :bulk_insert) == 455
  # Any other statement past it is refused before it is sent, counting the parameters, never showing one.
  @test _MyExt._bind(pool, collect(1:4096)) == collect(1:4096)
  e = try; _MyExt._bind(pool, fill(424242, 4097)); nothing; catch err; err; end
  @test e isa PormG.QueryBuildError && occursin("binds 4097 parameters", sprint(showerror, e))
  @test !occursin("424242", sprint(showerror, e))
end
