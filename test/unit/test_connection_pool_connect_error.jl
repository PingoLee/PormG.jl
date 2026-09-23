# ============================================================
# test/unit/test_connection_pool_connect_error.jl
#
# Connect-failure classification + fast-fail → typed PoolConnectError (#72, AC2).
#
# CONTRACT being tested:
#   When `acquire_connection` cannot OPEN a physical connection (permanently-bad string: bad password,
#   missing role/db, an unopenable SQLite path) it must NOT wait the full pool_timeout and then blame
#   pool saturation. It fast-fails (when the error is classified permanent AND fail_fast_on_connect is
#   on) with a catchable `PoolConnectError` carrying the underlying driver cause + a redacted connection
#   string. A healthy-but-saturated pool still raises `PoolTimeoutError` (covered in
#   test_connection_pool_timeout.jl); the two paths must stay distinct.
#
# Deterministic and server-free: a SQLite pool pointed at a path whose PARENT directory does not exist
# makes SQLite raise CANTOPEN ("unable to open database file") on every connect attempt — the realistic
# "permanent" SQLite case. Classification itself is a pure, message-substring function, tested directly.
# ============================================================

using Test
using PormG

# SQLite/LibPQ are weakdeps since #34 — load the driver extensions so the backend hooks resolve.
include(joinpath(@__DIR__, "..", "load_drivers.jl"))

const CP = PormG.ConnectionPool

@testset "backend_is_permanent_connect_error classifies auth/cantopen only (#72)" begin
  # Pools build lazily (no connect), so these are safe to construct with dummy strings.
  pg = CP.PostgresConnectionPool("host=localhost dbname=x user=y")
  sl = CP.SQLiteConnectionPool(":memory:")

  # NOTE: the classifier is a pure `lowercase(string(e))` substring match, so proxying the driver
  # messages with ErrorException tests exactly the classification contract. The PG *end-to-end* path
  # (a real LibPQ.PQConnectionError from a live server) is left to the integration suite; SQLite is
  # exercised end-to-end below against a real SQLiteException.
  # PostgreSQL — permanent (config/auth) classes fast-fail…
  @test PormG.backend_is_permanent_connect_error(pg, ErrorException("FATAL: password authentication failed for user \"y\""))
  @test PormG.backend_is_permanent_connect_error(pg, ErrorException("FATAL: role \"y\" does not exist"))
  @test PormG.backend_is_permanent_connect_error(pg, ErrorException("FATAL: database \"x\" does not exist"))
  @test PormG.backend_is_permanent_connect_error(pg, ErrorException("no pg_hba.conf entry for host \"1.2.3.4\""))
  # …but host/DNS/network stay AMBIGUOUS (must NOT fast-fail — could be a transient blip).
  @test !PormG.backend_is_permanent_connect_error(pg, ErrorException("could not translate host name \"db\" to address"))
  @test !PormG.backend_is_permanent_connect_error(pg, ErrorException("could not connect to server: Connection timed out"))

  # SQLite — unopenable path is permanent; a locked/disk error is not a permanent OPEN failure.
  @test PormG.backend_is_permanent_connect_error(sl, SQLite.SQLiteException("unable to open database file"))
  @test !PormG.backend_is_permanent_connect_error(sl, SQLite.SQLiteException("database is locked"))
end

# A SQLite pool that can never open a connection (parent directory of the DB file does not exist →
# SQLITE_CANTOPEN). `close_pool!` on such a pool is a harmless no-op (nothing was ever opened).
_unopenable_sqlite_pool(; kwargs...) =
  CP.SQLiteConnectionPool(joinpath(tempname(), "db.sqlite"); kwargs...)

@testset "fast-fail raises PoolConnectError (not PoolTimeoutError) well under the deadline (#72)" begin
  # Warm the connect→classify→raise path on a THROWAWAY pool before measuring (#382). Everything
  # below the measurement is JIT-sensitive — SQLite's connect, the permanent-error classifier, the
  # PoolConnectError construction — and none of it is what the assertion is about.
  #
  # Not a nicety: run this file on its own and the cold path took 1.33-1.41 s here, so `elapsed < 1.0`
  # FAILED on unmodified main. It passes inside `test/runtests.jl` only because earlier testsets
  # happen to warm it, which makes the rung-1 "run the one file" workflow report a phantom failure.
  # Warm, the same call is ~0.2 s, so the 1.0 s bound recovers a real 5x margin against the 5 s
  # deadline it exists to exclude.
  warmup = _unopenable_sqlite_pool(pool_size = 1)
  try; CP.acquire_connection(warmup; timeout_seconds = 5); catch; end
  try; CP.close_pool!(warmup); catch; end

  pool = _unopenable_sqlite_pool(pool_size = 1)     # fail_fast_on_connect defaults to true
  try
    t0 = time()
    err = try
      CP.acquire_connection(pool; timeout_seconds = 5)   # would wait 5s if it did NOT fast-fail
      nothing
    catch e; e end
    elapsed = time() - t0

    @test err isa PormG.PoolConnectError               # truthful type — NOT PoolTimeoutError
    @test !(err isa PormG.PoolTimeoutError)
    @test err.adapter == "SQLite"
    @test err.cause isa SQLite.SQLiteException          # underlying driver cause preserved
    @test err.attempts >= 1
    @test 0.0 <= err.elapsed_seconds < 1.0              # the field itself reflects the fast-fail, not the 5s budget
    @test elapsed < 1.0                                 # MUTATION GATE: fast-fail, not the 5s deadline
    @test occursin("could not open", sprint(showerror, err))
    @test occursin("unable to open database file", sprint(showerror, err))   # cause surfaced in message
  finally
    try; CP.close_pool!(pool); catch; end
  end
end

@testset "fail_fast_on_connect=false waits to the deadline, still PoolConnectError (#72)" begin
  # Same unopenable pool, but fast-fail disabled → it must fall through to the normal wait-to-deadline
  # path (proving the toggle) and STILL surface the truthful PoolConnectError (not PoolTimeoutError).
  pool = _unopenable_sqlite_pool(pool_size = 1, fail_fast_on_connect = false)
  try
    t0 = time()
    err = try
      CP.acquire_connection(pool; timeout_seconds = 1)
      nothing
    catch e; e end
    elapsed = time() - t0

    @test err isa PormG.PoolConnectError               # truthful cause even without fast-fail
    @test err.cause isa SQLite.SQLiteException
    @test elapsed >= 0.8                               # discriminator: it waited ~the full 1s budget
  finally
    try; CP.close_pool!(pool); catch; end
  end
end

# ═════════════════════════════════════════════════════════════════════════════
# #657 — a connection string libpq cannot PARSE must not leak its credential.
#
# Every case below is hermetic: a parse failure happens inside libpq before any socket is opened, so
# `acquire_connection` never reaches a server. Three channels carried the password before the fix,
# and each is asserted separately, because each one leaked independently:
#
#   1. `sprint(showerror, err)` — `PoolConnectError` printed its `cause` verbatim;
#   2. PormG's own `@debug` lines — they interpolated the raw exception (`"…: $e"`);
#   3. LibPQ's Memento logger — `LibPQ.conninfo` PRINTS `[error | LibPQ]: <libpq message>` before it
#      throws, so no amount of redaction inside PormG could catch it after the fact.
# ═════════════════════════════════════════════════════════════════════════════

const LibPQExt657 = Base.get_extension(PormG, :PormGLibPQExt)

# Run `f()` while capturing BOTH log channels, and return `(value_or_exception, julia_log_text,
# memento_text)`. The Julia side uses a `TestLogger` at `Debug`, so the pool's `@debug` lines are
# seen; every message and every keyword VALUE is flattened into one string to search. The Memento
# side installs a handler on `LibPQ.LOGGER` itself (it has none of its own and propagates to the
# root), and removes it in `finally` so no other test inherits it.
function _capture_657(f)
  memento_buf = IOBuffer()
  handler_key = "pormg-657-capture"
  LibPQ.LOGGER.handlers[handler_key] = LibPQ.Memento.DefaultHandler(memento_buf)
  julia_logger = Test.TestLogger(min_level = Base.CoreLogging.Debug)
  result = try
    Base.CoreLogging.with_logger(julia_logger) do
      try; f(); catch e; e; end
    end
  finally
    delete!(LibPQ.LOGGER.handlers, handler_key)
  end
  julia_text = join((string(r.message, " ", join((string(k, "=", v) for (k, v) in r.kwargs), " "))
                     for r in julia_logger.logs), "\n")
  return result, julia_text, String(take!(memento_buf))
end

# ─────────────────────────────────────────────────────────────────────────────
# Connection-string preflight: an unparseable or NUL-bearing DSN leaks nothing (#657)
# For each of the three leaking shapes from the issue, `acquire_connection` must fail fast with a
# `PoolConnectError` whose cause is PormG's own value-free `InvalidConfigurationError`, and no
# secret fragment may appear in the rendered error, in PormG's logs, or in LibPQ's Memento log.
# ─────────────────────────────────────────────────────────────────────────────
@testset "an unparseable / NUL DSN leaks no credential through any channel (#657)" begin
  cases = [
    # (label, DSN, secret fragments, a phrase the masked message must still carry)
    ("NUL byte", "host=localhost password=s3cr\0etNUL dbname=f1", ["s3cr", "etNUL"], "NUL character"),
    ("unquoted passphrase", "host=localhost password=corr3ct horse battery dbname=f1",
     ["corr3ct", "horse", "battery"], "could not be parsed"),
    ("bad percent-escape URL", "postgresql://u:p%zzSECRET657@localhost/f1", ["SECRET657", "p%zz"],
     "could not be parsed"),
    # PARSES cleanly — libpq splits the userinfo at the first `@`, making host `ssSEC657@localhost` —
    # and leaked at connect time instead, through the host-resolution error (review finding, #657).
    ("unencoded @ in URL password", "postgresql://u:pa@ssSEC657@localhost:1/f1", ["ssSEC657"], "%40"),
    # The same, with a `:` in the tail: it lands in PORT (`"PORTSEC657@localhost"`) instead, and
    # libpq's "invalid integer value" error quoted it (delta review, #657).
    ("unencoded @ and : in URL password", "postgresql://u:pa@ss:PORTSEC657@localhost/f1",
     ["PORTSEC657"], "not an integer"),
    # An unencoded `/` in a URL password (#658). libpq's userinfo scan stops at the first `/`, so each
    # of these parses cleanly and the password's tail lands in the DBNAME. They leaked through the
    # `connection=` field — the redaction stopped at `/` too — and, for the two whose port is an
    # integer or whose host is a password fragment, at connect time through LibPQ's Memento logger.
    ("unencoded / in URL password", "postgresql://u:pa/ssSEC658@localhost/f1", ["ssSEC658"], "%2F"),
    ("unencoded / after an integer", "postgresql://u:1234/SEC658@localhost/f1", ["SEC658"], "%2F"),
    ("unencoded @ then / in URL password", "postgresql://u:pa@ss/SEC658@localhost/f1",
     ["SEC658", "ss/"], "%2F"),
    # The same `/`, with a `?keyword=` in the tail too (#662): the `@` lands in that OPTION's value,
    # past the dbname check, and libpq quoted it (`invalid sslmode value: "…"`). `service` is the case
    # the issue's list of enum keywords missed; it echoes before any network I/O as well.
    ("unencoded / then ?sslmode= in URL password", "postgresql://u:1234/x?sslmode=SEC662@h/f1",
     ["SEC662"], "%3F"),
    ("unencoded / then ?service= in URL password", "postgresql://u:1234/x?service=SEC662@h/f1",
     ["SEC662"], "%3F"),
    # The tail can span several options, and only the last one takes the `@`: when that one is
    # allow-listed, the fragment sits `@`-free in an earlier option and was still echoed (review
    # finding, #662) — `invalid sslmode value: "SEC662"`.
    ("?keyword= tail ending in an allow-listed option", "postgresql://u:1234/x?sslmode=SEC662&application_name=@h/f1",
     ["SEC662"], "%3F"),
    ("?keyword= tail ending in user=…@host/db", "postgresql://u:1234/x?service=SEC662&user=me@h/f1",
     ["SEC662"], "%3F"),
    # A password that percent-encoded its own `@` but not its `/`: the decoded value `a@b@h/f1` is
    # nowhere in the string, but its LAST `@` still arrived raw (delta review, #662).
    ("?keyword= tail, own @ encoded", "postgresql://u:1234/x?sslmode=SEC662&user=a%40b@h/f1",
     ["SEC662"], "%3F"),
    # …and one whose real URL had no host at all (`postgresql://u:PASS@`), so nothing follows the `@`.
    ("?keyword= tail, no host after @", "postgresql://u:1234/x?sslmode=SEC662&user=me@",
     ["SEC662"], "%3F"),
    # libpq percent-decodes query KEYWORDS as well, and the tail may carry an encoded delimiter; the
    # raw-segment test decodes both before comparing (fourth delta review, #662).
    ("?keyword= tail, encoded keyword", "postgresql://u:1234/x?sslmode=SEC662&us%65r=me@h/f1",
     ["SEC662"], "%3F"),
    ("?keyword= tail, encoded / in tail", "postgresql://u:1234/x?sslmode=SEC662&user=me@h%2Ff1",
     ["SEC662"], "%3F"),
    # No `/` at all: libpq ends the credentials at the first `@` (`pa`), the host at the `?`, and the
    # rest of the password is the query.
    ("unencoded @ then ?keyword= in URL password", "postgresql://u:pa@ss?sslmode=SEC662@h/f1",
     ["SEC662"], "%3F"),
  ]
  # Warm the preflight→classify→raise path on a throwaway pool before timing anything, for the #382
  # reason given above: cold, the FIRST case measured 3.4 s here, all of it JIT.
  warmup = CP.PostgresConnectionPool("host=localhost password=warm up"; pool_size = 1)
  _capture_657(() -> CP.acquire_connection(warmup; timeout_seconds = 5))
  try; CP.close_pool!(warmup); catch; end

  for (label, dsn, secrets, phrase) in cases
    # Pools build lazily, so constructing one with a bad string opens nothing.
    pool = CP.PostgresConnectionPool(dsn; pool_size = 1)
    try
      t0 = time()
      err, julia_text, memento_text = _capture_657(() -> CP.acquire_connection(pool; timeout_seconds = 5))
      elapsed = time() - t0
      rendered = sprint(showerror, err)

      @testset "$label" begin
        @test err isa PormG.PoolConnectError
        # The cause is the preflight's own error, not the driver's: LibPQ.Connection was never handed
        # the string (which is the only way the Memento channel stays clean).
        @test err.cause isa PormG.InvalidConfigurationError
        @test occursin(phrase, rendered)
        # The remedy must survive the redaction it passes through: an example spelled
        # `password='two words'` rendered as `(password=****)`, garbling the one useful line.
        phrase == "could not be parsed" && @test occursin("('two words')", rendered)
        # A string that can never parse is permanent → fast-fail, not the 5 s deadline.
        @test elapsed < 2.5
        for s in secrets
          @test !occursin(s, rendered)
          # On this fast-fail path no pool `@debug` fires, so `julia_text` is normally empty and this
          # line only catches a log added later. The log channel's POSITIVE coverage — proving the
          # capture sees the lines — is in the two testsets below, which take the retry path.
          @test !occursin(s, julia_text)
          @test !occursin(s, memento_text)
          @test !occursin(s, sprint(showerror, err.cause))
        end
        # LibPQ must not have logged anything at all for a string it never received.
        @test isempty(memento_text)
      end
    finally
      try; CP.close_pool!(pool); catch; end
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# Connection-string preflight: well-formed strings pass untouched (#657)
# The preflight sits in front of EVERY PostgreSQL connect, so a false refusal is an outage. Each
# string here is legal and must return `nothing`: a quoted passphrase, a percent-encoded `@`, and a
# Unix-socket directory that itself contains an `@` (the one host shape allowed to hold one).
# ─────────────────────────────────────────────────────────────────────────────
@testset "the preflight accepts well-formed connection strings (#657)" begin
  pre = LibPQExt657._preflight_conninfo
  @test pre("host=localhost port=5432 dbname=f1 user=pingo password='corr3ct horse battery'") === nothing
  @test pre("postgresql://pingo:p%40ss@localhost:5432/f1") === nothing
  @test pre("postgresql://localhost/f1?user=pingo&sslmode=disable") === nothing
  @test pre("host=/run/pg@main dbname=f1") === nothing
  @test pre("host=db1,db2 dbname=f1") === nothing
  # Ports: the non-integer refusal must leave every integer spelling alone, multi-host included.
  @test pre("postgresql://pingo@db1:5432,db2:5433/f1") === nothing
  @test pre("host=localhost port=5432 dbname=f1") === nothing
  @test pre("host=localhost port=+5432 dbname=f1") === nothing   # strtol takes a sign; so must we
  @test pre("postgresql://[::1]:5432/f1") === nothing
  # The #658 dbname refusal is URL-only: the remedy it prints (a percent-encoded `/`) must pass, and a
  # keyword-form dbname holding an `@` carries no URL ambiguity at all.
  @test pre("postgresql://u:p%2Fw@localhost/f1") === nothing
  @test pre("host=localhost dbname=f1@archive") === nothing
  @test pre("host=localhost dbname='f1@archive'") === nothing
  # The #662 URL-option refusal spares its allow-list — Azure's `user=me@server` above all — and,
  # like #658's, the keyword form, where a path holding an `@` carries no ambiguity.
  @test pre("postgresql://localhost/f1?user=pingo@server") === nothing
  @test pre("postgresql://pingo%40server:pw@localhost/f1") === nothing
  @test pre("postgresql://localhost/f1?application_name=etl@nightly") === nothing
  @test pre("postgresql://localhost/f1?fallback_application_name=etl@nightly") === nothing
  @test pre("postgresql://localhost/f1?sslpassword=key@phrase") === nothing
  @test pre("host=localhost dbname=f1 sslrootcert=/etc/ca@2026.pem") === nothing
  # The host-tail test only reads a RAW `@`: a percent-encoded password whose decoded form is `@`
  # then `/` must pass, in the userinfo and in the query alike — and so must the encoded spelling of
  # an allow-listed value that the test refuses raw, since that is the remedy the message gives.
  @test pre("postgresql://pingo:p%40ss%2Fx@localhost/f1") === nothing
  # A password ENDING in an encoded `@`: the userinfo's own `@` separator must not stand in for a raw
  # one in the value (security review, #662).
  @test pre("postgresql://pingo:Secr3t%40@localhost/f1") === nothing
  @test pre("postgresql://pingo:p%2F%3Fsslmode%3DSEC%40@localhost/f1") === nothing
  @test pre("postgresql://localhost/f1?password=Secr3t%40") === nothing
  @test pre("postgresql://localhost/f1?password=p%40ss%2Fx") === nothing
  @test pre("postgresql://localhost/f1?application_name=etl%40nightly%3Av2") === nothing
end

# ─────────────────────────────────────────────────────────────────────────────
# Connection-string preflight: the documented cost of the #658 refusal
# A URL cannot name a database containing `@` — not even as `%40`, because libpq decodes the path
# before the preflight sees it. Pinned so the cost stays deliberate: the message must point at the
# keyword form, which is the only spelling left for such a database.
# ─────────────────────────────────────────────────────────────────────────────
@testset "a URL naming a database with an `@` is refused toward the keyword form (#658)" begin
  pre = LibPQExt657._preflight_conninfo
  for dsn in ("postgresql://localhost/f1@archive", "postgresql://localhost/f1%40archive",
              "postgres://localhost/f1@archive")
    @testset "$dsn" begin
      err = try; pre(dsn); nothing; catch e; e; end
      @test err isa PormG.InvalidConfigurationError
      @test occursin("keyword form", sprint(showerror, err))
      @test !occursin("archive", sprint(showerror, err))
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# Connection-string preflight: the documented cost of the #662 refusal
# In a URL, only the allow-listed options may hold an `@`, so a certificate path or a Unix-socket
# directory containing one must move to the keyword form — and an allow-listed value whose raw `@` is
# followed by a host tail must be percent-encoded. The message names the option, never its value.
# ─────────────────────────────────────────────────────────────────────────────
@testset "a URL option holding an `@` outside the #662 rules is refused toward its remedy" begin
  pre = LibPQExt657._preflight_conninfo
  for (dsn, keyword, remedy, secret) in (
      ("postgresql://localhost/f1?sslrootcert=/etc/ca@2026.pem", "sslrootcert", "keyword form", "2026"),
      ("postgresql:///f1?host=/run/pg@main", "host", "keyword form", "main"),
      ("postgresql://%2Frun%2Fpg%40main/f1", "host", "keyword form", "main"),
      ("postgresql://localhost/f1?application_name=etl@nightly:v2", "application_name", "as %40", "nightly"))
    @testset "$dsn" begin
      err = try; pre(dsn); nothing; catch e; e; end
      @test err isa PormG.InvalidConfigurationError
      msg = sprint(showerror, err)
      @test occursin(remedy, msg)
      @test occursin("`$keyword`", msg)
      @test !occursin(secret, msg)
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# Connection-string preflight: libpq's quoted fragment is masked, not dropped wholesale (#657)
# `_mask_libpq_quoted` masks from the first `"` to the last one. Pair-wise masking would leak when
# the echoed value itself contains a quote, so that is the case pinned here; a message with no
# quotes passes through, keeping libpq's diagnosis.
# ─────────────────────────────────────────────────────────────────────────────
@testset "_mask_libpq_quoted masks every echoed fragment (#657)" begin
  mask = LibPQExt657._mask_libpq_quoted
  @test mask("missing \"=\" after \"horse\" in connection info string") ==
        "missing \"****\" in connection info string"
  # An embedded quote in the echoed value: `ab"cd` — pairing quotes would leave `cd` outside.
  masked = mask("missing \"=\" after \"ab\"cdLEAK\" in connection info string")
  @test !occursin("cdLEAK", masked)
  @test !occursin("ab", masked)
  # A lone quote masks to the end of the message.
  @test !occursin("TAIL", mask("invalid token: \"TAIL"))
  # No quotes: libpq's text survives untouched.
  @test mask("unterminated quoted string in connection info string") ==
        "unterminated quoted string in connection info string"
end

# ─────────────────────────────────────────────────────────────────────────────
# Connection-string preflight: a refused DSN is a PERMANENT connect error (#657)
# The same string fails identically on every retry, so it must fast-fail — and the opt-out still
# works: with `fail_fast_on_connect=false` the pool waits to its deadline and still ends redacted.
# ─────────────────────────────────────────────────────────────────────────────
@testset "a refused DSN is permanent; fail_fast_on_connect=false still waits (#657)" begin
  pg = CP.PostgresConnectionPool("host=localhost dbname=x user=y")
  @test PormG.backend_is_permanent_connect_error(pg, PormG.InvalidConfigurationError("refused"))

  pool = CP.PostgresConnectionPool("host=localhost password=corr3ct horse battery dbname=f1";
                                   pool_size = 1, fail_fast_on_connect = false)
  try
    t0 = time()
    err, julia_text, _ = _capture_657(() -> CP.acquire_connection(pool; timeout_seconds = 1))
    elapsed = time() - t0
    @test err isa PormG.PoolConnectError
    @test elapsed >= 0.8                                  # the opt-out was honoured
    # This path DOES reach the pool's `@debug "Failed to … connection"` lines; prove the capture
    # saw them, or the negative assertions below would pass vacuously.
    @test occursin("Failed to", julia_text)
    for s in ("corr3ct", "horse", "battery")
      @test !occursin(s, julia_text)
      @test !occursin(s, sprint(showerror, err))
    end
  finally
    try; CP.close_pool!(pool); catch; end
  end
end

# A PG-shaped mock whose driver echoes the whole DSN into its exception — exactly what Julia's
# C-string conversion does on a NUL. It stands in for any driver path the LibPQ preflight does not
# know about, which is what the core backstop in `ConnectionPool` exists for. Fields mirror
# `test_connection_pool_handoff.jl`'s `MockPGHandoff` (no `waiters` → module-level registry).
mutable struct LeakyMockPG657 <: PormG.PormGPostgres
  connections::Vector{Any}
  available::Vector{Bool}
  connection_string::String
  pool_size::Int
  lock::ReentrantLock
end
const _LEAKY_DSN_657 = "host=localhost password=backst0pSECRET dbname=f1"
LeakyMockPG657() = LeakyMockPG657(Any[nothing], [true], _LEAKY_DSN_657, 1, ReentrantLock())
PormG.backend_connect(p::LeakyMockPG657; kwargs...) =
  throw(ArgumentError("embedded NULs are not allowed in C strings: $(repr(p.connection_string))"))
PormG.backend_is_permanent_connect_error(::LeakyMockPG657, e) = false   # take the retry/@debug path

# ─────────────────────────────────────────────────────────────────────────────
# Core backstop: a cause that quotes the DSN is redacted in showerror and in logs (#657)
# Independent of the LibPQ preflight: whatever a driver throws, `PoolConnectError` renders its cause
# through `redact_secret`, and the pool's connect-failure log lines do the same.
# ─────────────────────────────────────────────────────────────────────────────
@testset "PoolConnectError and the pool's logs redact a DSN-quoting cause (#657)" begin
  # Direct: a constructed error, no pool involved.
  direct = PormG.PoolConnectError("PostgreSQL", ArgumentError("bad: \"host=h password=s3cretDIRECT\""),
                                  "host=h password=****", 1, 0.0)
  @test !occursin("s3cretDIRECT", sprint(showerror, direct))
  @test occursin("password=****", sprint(showerror, direct))
  # The 2-arg `show` is a separate channel — `"$e"`, `string(e)`, `repr(e)` — and its default method
  # printed the raw cause field.
  @test !occursin("s3cretDIRECT", repr(direct))
  @test !occursin("s3cretDIRECT", "$direct")
  @test occursin("PoolConnectError(", repr(direct))

  # Through the acquire loop: retries until the deadline, logging each failure at @debug.
  pool = LeakyMockPG657()
  err, julia_text, _ = _capture_657(() -> CP.acquire_connection(pool; timeout_seconds = 0.5))
  @test err isa PormG.PoolConnectError
  @test err.cause isa ArgumentError                        # the raw object is kept (reflection)
  @test occursin("Failed to", julia_text)                  # the @debug lines were captured
  @test !occursin("backst0pSECRET", julia_text)
  @test !occursin("backst0pSECRET", sprint(showerror, err))
end
