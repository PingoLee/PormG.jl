"""
No decision keys on a localized server message (#1010).

PostgreSQL translates its messages by `lc_messages`, so on a `pt_BR` server
`canceling statement due to statement timeout` arrives in Portuguese, and an `occursin` over the
English text silently stops firing. #1001 fixed that for `bulk_insert`'s sequence resync and
`get_or_create`'s conflict target. This file holds the rest:

  1. **`with_advisory_lock`'s `:block` timeout** keys on SQLSTATE `55P03`, which `lock_timeout`
     raises and no cancel shares (#1024). A `57014` is a cancel and propagates.
  2. **The LibPQ connection fallbacks** have no SQLSTATE to read. Their decisions are pinned here:
     a dropped connection is still recognized on a localized server, by libpq's own (untranslated)
     line, and a localized auth failure degrades to the safe wait-to-deadline path.
  3. **A source scan** fails on any new match of driver-error text in `src/` or `ext/` that does not
     carry a reviewed `# server-text-match-ok: <why>` marker.

Hermetic: mock pools and hand-built driver exceptions. No server, and no `pt_BR` locale needed.
"""

using Test
using PormG
using Logging
include(joinpath(@__DIR__, "..", "load_drivers.jl"))

const CP1010 = PormG.ConnectionPool
const E1010 = LibPQ.Errors

# ─────────────────────────────────────────────────────────────────────────────
# 1. with_advisory_lock(:block): the timeout is SQLSTATE 55P03, not text, and not 57014
#
# A PG-shaped mock pool, after `MockPGPool322` (test_transaction_interrupt.jl). The blocking lock
# query sleeps `block_delay` seconds and then fails with `block_error`; the holder query answers one
# pid, so the lock-timeout error can be told apart from the error it replaces. Every statement is
# recorded, so the timeout the call sets and restores can be read back.
# ─────────────────────────────────────────────────────────────────────────────
mutable struct FakeConn1010
  closed::Bool
end
Base.close(c::FakeConn1010) = (c.closed = true; nothing)

mutable struct MockLockPool1010 <: PormG.PormGPostgres
  connections::Vector{Any}
  available::Vector{Bool}
  connection_string::String
  pool_size::Int
  lock::ReentrantLock
  block_error::Any
  block_delay::Float64
  show_answer::Any
  sqls::Vector{String}
  unlocks::Threads.Atomic{Int}
  renewals::Threads.Atomic{Int}
end
MockLockPool1010(block_error; block_delay = 0.0, show_answer = "0") =
  MockLockPool1010(Any[FakeConn1010(false)], [true], "mock://pg", 1, ReentrantLock(),
                   block_error, block_delay, show_answer, String[],
                   Threads.Atomic{Int}(0), Threads.Atomic{Int}(0))

PormG.backend_is_alive(::MockLockPool1010, conn) = conn isa FakeConn1010 && !conn.closed
PormG.backend_connect(::MockLockPool1010; kwargs...) = FakeConn1010(false)
PormG.backend_renew_connection(pool::MockLockPool1010, conn; kwargs...) =
  (Threads.atomic_add!(pool.renewals, 1); FakeConn1010(false))
PormG.backend_cancel_query!(::MockLockPool1010, conn) = nothing
PormG.backend_drain_connection!(::MockLockPool1010, conn) = true

function PormG.backend_execute_async(pool::MockLockPool1010, conn, sql::String, params)
  push!(pool.sqls, sql)
  startswith(sql, "SELECT pg_advisory_unlock") && Threads.atomic_add!(pool.unlocks, 1)
  return @async begin
    if startswith(sql, "SELECT true AS ok FROM (SELECT pg_advisory_lock")
      sleep(pool.block_delay)
      pool.block_error === nothing && return Any[(true,)]
      throw(pool.block_error)
    end
    occursin("pg_locks", sql) && return Any[(4711, "app-worker-1")]
    if startswith(sql, "SHOW ")
      pool.show_answer === nothing && error("SHOW failed")
      return Any[(pool.show_answer,)]
    end
    startswith(sql, "SELECT pg_") ? Any[(true,)] : NamedTuple[]
  end
end

# A `lock_timeout` expiry as a `pt_BR` server reports it, wrapped the way the pool wraps it.
function _pt_lock_timeout1024()
  text = "cancelando comando devido a tempo de espera de bloqueio"
  return PormG.OperationalError("PostgreSQL", E1010.LockNotAvailable("ERRO:  " * text, nothing);
                                sqlstate = "55P03", message = text)
end

# A `57014` cancel as a `pt_BR` server reports it — the SQLSTATE `statement_timeout` raised too.
function _pt_timeout1010()
  cause = E1010.QueryCanceled("ERRO:  cancelando comando devido ao tempo de espera do comando", nothing)
  return PormG.OperationalError("PostgreSQL", cause; sqlstate = "57014",
                                message = "cancelando comando devido ao tempo de espera do comando")
end

function _lock_outcome1010(pool; timeout_ms)
  ran = Ref(false)
  err = try
    PormG.with_advisory_lock(() -> (ran[] = true), pool, "k1010"; wait = true, strategy = :block,
                             timeout_ms = timeout_ms)
    nothing
  catch e
    e
  end
  return err, ran[]
end

@testset "#1024: a Portuguese lock_timeout (55P03) reads as a lock timeout" begin
  pool = MockLockPool1010(_pt_lock_timeout1024(); block_delay = 0.08)
  local err, ran
  @test_logs (:warn, r"Advisory lock timed out on server-side lock_timeout") match_mode = :any begin
    err, ran = _lock_outcome1010(pool; timeout_ms = 20)
  end
  # The lock-timeout error, not the 55P03 it degrades: it names the holder (#737).
  @test err isa PormG.OperationalError
  @test err.sqlstate === nothing
  @test occursin("Failed to acquire advisory lock for 'k1010' within 20 ms", err.message)
  @test occursin("held by pid 4711 (app-worker-1)", err.message)
  @test !ran
  @test pool.unlocks[] == 0                 # no lock was taken, so none is released
  @test pool.available[1] === true          # a plain release, not a renewal
  @test pool.renewals[] == 0
end

@testset "#1024: a 57014 is a cancel, however long the wait took" begin
  # Arrives AFTER `timeout_ms` has passed — exactly what `statement_timeout`'s own expiry looked
  # like, and what #1023's clock guard degraded into a lock timeout. `lock_timeout` cannot raise it,
  # so it is an external `pg_cancel_backend` (or a session `statement_timeout`) and propagates.
  cancel = _pt_timeout1010()
  pool = MockLockPool1010(cancel; block_delay = 0.08)
  err, ran = _lock_outcome1010(pool; timeout_ms = 20)
  @test err === cancel
  @test !ran
  @test pool.available[1] === true
  @test pool.renewals[] == 0
end

@testset "#1010: an abandoned await is never read as a timeout" begin
  # PormG's own #315 cancel: the await was interrupted, so the connection is renewed and the
  # cancellation propagates, however long it took. Built in the shape it really arrives in:
  # `_as_database_error` unwraps to the `InterruptException`, which carries no SQLSTATE at all.
  abandoned = PormG.OperationalError("PostgreSQL", InterruptException())
  @test abandoned.sqlstate === nothing
  pool = MockLockPool1010(abandoned; block_delay = 0.08)
  err, ran = with_logger(NullLogger()) do
    _lock_outcome1010(pool; timeout_ms = 20)
  end
  @test err === abandoned
  @test !ran
  # Renewal runs on a background task (#322), so wait for it rather than read it at once.
  deadline = time() + 10
  while pool.renewals[] == 0 && time() < deadline
    sleep(0.01)
  end
  @test pool.renewals[] == 1
end

@testset "#1010: the English timeout text under another SQLSTATE is not a timeout" begin
  # The text alone never decides: the message carries the English lock-timeout phrase, but the
  # SQLSTATE is a cancel's, so there is no degrade in any language.
  english = PormG.OperationalError("PostgreSQL",
    ErrorException("ERROR:  canceling statement due to lock timeout"); sqlstate = "57014",
    message = "canceling statement due to lock timeout")
  pool = MockLockPool1010(english; block_delay = 0.08)
  err, ran = _lock_outcome1010(pool; timeout_ms = 20)
  @test err === english
  @test !ran
end

@testset "#1024: :block sets and restores lock_timeout, never statement_timeout" begin
  # The previous value is restored as it was read…
  pool = MockLockPool1010(nothing; show_answer = "5s")
  err, ran = _lock_outcome1010(pool; timeout_ms = 250)
  @test err === nothing
  @test ran
  @test pool.sqls[1] == "SHOW lock_timeout"
  @test pool.sqls[2] == "SET lock_timeout = 250"
  @test pool.sqls[end] == "SET lock_timeout = '5s'"
  @test !any(sql -> occursin("statement_timeout", sql), pool.sqls)

  # …and when it cannot be read, the session default is put back instead.
  pool = with_logger(NullLogger()) do
    p = MockLockPool1010(_pt_lock_timeout1024(); show_answer = nothing)
    _lock_outcome1010(p; timeout_ms = 250)
    p
  end
  @test pool.sqls[2] == "SET lock_timeout = 250"
  @test pool.sqls[end] == "SET lock_timeout TO DEFAULT"
  @test !any(sql -> occursin("statement_timeout", sql), pool.sqls)
end

# ─────────────────────────────────────────────────────────────────────────────
# 2. The LibPQ fallbacks: what a localized server does to them
#
# Neither has a SQLSTATE to read (a codeless `PQResultError{CUN}`, a `PQConnectionError`), so these
# pin the decisions recorded in ext/PormGLibPQExt.jl rather than a fix.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1010: a dropped connection is recognized on a localized server" begin
  pg = CP1010.PostgresConnectionPool("host=localhost dbname=x user=y")
  # The #442 capture with its server line in Portuguese. libpq's own line is untranslated (LibPQ_jll
  # ships no message catalogs), and that is what still matches.
  for tail in ("SSL connection has been closed unexpectedly", "server closed the connection unexpectedly")
    codeless = E1010.PQResultError{E1010.CUN, E1010.EUNOWN}(
      "FATAL:  terminando conexão por causa de comando do administrador\n$tail", nothing)
    @test PormG.backend_is_connection_error(pg, codeless)
  end
  # The coded form needs no text at all.
  @test PormG.backend_is_connection_error(pg,
    E1010.AdminShutdown("FATAL:  terminando conexão por causa de comando do administrador", nothing))
end

@testset "#1010: a localized auth failure degrades to the wait-to-deadline path" begin
  pg = CP1010.PostgresConnectionPool("host=localhost dbname=x user=y")
  # The documented limitation: not recognized as permanent, so the pool waits out `pool_timeout`.
  # That direction is the safe one — never a fast-fail on something that might recover.
  @test !PormG.backend_is_permanent_connect_error(pg, ErrorException(
    "connection to server at \"localhost\" (127.0.0.1), port 5432 failed: " *
    "FATAL:  autenticação do tipo senha falhou para o usuário \"y\""))
  # …while the English server still fails fast, as #72 shipped it.
  @test PormG.backend_is_permanent_connect_error(pg, ErrorException(
    "connection to server at \"localhost\" (127.0.0.1), port 5432 failed: " *
    "FATAL:  password authentication failed for user \"y\""))
end

# ─────────────────────────────────────────────────────────────────────────────
# 3. Source scan: no unreviewed match against a driver error's text (#1010)
#
# A SITE is a text test whose subject is driver text: an `occursin` / `contains` / `startswith` /
# `endswith` / `match` / `findfirst` / `findlast` / `findnext` / `eachmatch` call, or a `==` / `!=`
# against a string literal. Driver text is:
#   * `sprint(showerror, …)`, `<exception>.msg`, `<exception>.message`, any `.cause`, `error_message(…)`;
#   * a rendering of an exception: `string(…)`, `repr(…)`, `sprint(…)`, `… |> string` or a `"$…"`
#     interpolation whose text names an exception, however deep (`string(_driver_cause(e))`);
#   * a local assigned from one of those anywhere in the same file (`msg = lowercase(string(e))`,
#     `let msg = …`, `msg::String = …`, `msg, rest = …`), and locals assigned from those in turn.
# `<exception>.message` is the one to watch: since #987 it is the server's own, LOCALIZED, primary
# message, so `occursin("…", e.message)` is exactly the defect this file exists for.
# Exception names follow the #984 scan's convention — `e`, `err`, `ex`, `exc`, `exception`, `error`,
# `<what>_err` / `<what>_error` / `<what>_exception` — plus `root`, `cause` and `e2`-style names.
#
# A reviewed site carries `# server-text-match-ok: <why>` on its own line, on any line of the
# `||` / `&&` chain it belongs to, or in the comment block directly above that chain. Never between
# a docstring and its definition: a comment there detaches the docstring (#612 guards that). The reasons
# that are legitimate: SQLite (no SQLSTATE, never localized), a driver's own client-side text, and
# a codeless PostgreSQL fallback whose limit is documented. A server message PostgreSQL localizes is
# NOT one of them — key on `e.sqlstate` instead.
#
# Text-based and per file, on purpose: a local tainted in one function taints the name file-wide.
# That over-flags rather than under-flags, and the marker settles a false positive. What it cannot
# see is a helper that does the matching for its caller (`_has(t) = occursin("x", t)` called as
# `_has(sprint(showerror, e))`): the call site passes driver text to a function, not to a text test.
# Nor a loop or lambda variable over driver text (`for l in split(string(e), '\n')`,
# `any(l -> startswith(l, "FATAL"), …)`), nor a test on a wrapped name (`lowercase(msg) == "…"`).
# ─────────────────────────────────────────────────────────────────────────────
const MARKER1010 = "server-text-match-ok:"
const EXC1010 = raw"(?:e|err|ex|exc|exception|error|root|cause|e\d|err\d|ex\d|[a-z_]+_err|[a-z_]+_error|[a-z_]+_exception)"
# An exception's name as a token: not part of a longer name or a qualified path, and not called.
const EXC_TOKEN1010 = Regex(raw"(?<![\w.:])" * EXC1010 * raw"(?![\w(])")
const DIRECT1010 = Regex(raw"sprint\(\s*showerror\b|(?<![\w.])" * EXC1010 *
                         raw"\.(?:msg|message)\b|\.cause\b|\berror_message\(")
const RENDER1010 = r"\b(?:string|repr|sprint)\(|\|>\s*string\b|\$"
const CALL1010 = r"(?<![\w.])(?:Base\.)?(?:occursin|contains|startswith|endswith|match|eachmatch|findfirst|findlast|findnext)\("
const ASSIGN1010 = r"^\s*(?:local\s+|let\s+|global\s+)?((?:[A-Za-z_]\w*(?:::[\w{}.]+)?\s*,\s*)*[A-Za-z_]\w*(?:::[\w{}.]+)?)\s*(?<![=<>!])=(?!=)(.*)$"

_is_source1010(text) = occursin(DIRECT1010, text) ||
                       (occursin(RENDER1010, text) && occursin(EXC_TOKEN1010, text))
_names_in1010(text, names) = any(n -> occursin(Regex("(?<![\\w.])" * n * "\\b"), text), names)

# The code part of a line: everything before a `#` that is outside a string or char literal.
function _code1010(line::AbstractString)
  in_str = false
  chars = collect(line)
  i = 1
  while i <= length(chars)
    c = chars[i]
    if in_str
      c == '\\' ? (i += 1) : (c == '"' && (in_str = false))
    elseif c == '"'
      in_str = true
    elseif c == '\'' && i + 2 <= length(chars) && chars[i+2] == '\''
      i += 2                                   # a one-char literal such as '#'
    elseif c == '#'
      return String(chars[1:i-1])
    end
    i += 1
  end
  return line
end

# The argument text of the call opening at `col` on line `i`, through its matching `)`. Parentheses
# inside a string literal do not count: `occursin("%(", name)` must end at its own `)`.
function _call_args1010(codes, i, col)
  depth = 0
  in_str = false
  escaped = false
  buf = IOBuffer()
  for j in i:min(i + 10, length(codes))
    text = j == i ? codes[j][col:end] : codes[j]
    for c in text
      print(buf, c)
      if in_str
        escaped ? (escaped = false) : c == '\\' ? (escaped = true) : (c == '"' && (in_str = false))
        continue
      end
      c == '"' && (in_str = true)
      c == '(' && (depth += 1)
      c == ')' && (depth -= 1)
      depth == 0 && return String(take!(buf))
    end
  end
  return String(take!(buf))
end

# Names bound to driver text in this file, closed over `m = lowercase(msg)`-style rebinding.
function _tainted1010(codes)
  names = Set{String}()
  changed = true
  while changed
    changed = false
    for code in codes
      m = match(ASSIGN1010, code)
      m === nothing && continue
      lhs, rhs = m.captures[1], m.captures[2]
      (_is_source1010(rhs) || _names_in1010(rhs, names)) || continue
      for part in split(lhs, ',')
        name = String(strip(first(split(part, "::"))))
        name in names || (push!(names, name); changed = true)
      end
    end
  end
  return names
end

_continues1010(code) = occursin(r"(\|\||&&|\(|,|=)\s*$", code)

function _marked1010(lines, codes, i)
  s = i
  while s > 1 && _continues1010(codes[s-1])
    s -= 1
  end
  any(j -> occursin(MARKER1010, lines[j]), s:i) && return true
  j = s - 1
  while j >= 1 && occursin(r"^\s*#", lines[j])
    occursin(MARKER1010, lines[j]) && return true
    j -= 1
  end
  return false
end

# Is line `i` a site? A text-test call over driver text, or driver text compared to a literal.
function _is_site1010(codes, i, tainted)
  code = codes[i]
  for m in eachmatch(CALL1010, code)
    args = _call_args1010(codes, i, m.offset + ncodeunits(m.match) - 1)
    # A one-character needle (`findfirst('"', msg)`, masking quotes) is not a phrase to translate.
    occursin(r"^\(\s*'(?:[^'\\]|\\.)'\s*,", args) && continue
    (_is_source1010(args) || _names_in1010(args, tainted)) && return true
  end
  occursin(r"[!=]=\s*\"|\"\s*[!=]=", code) || return false
  any(n -> occursin(Regex("(?<![\\w.])" * n * "\\s*[!=]=\\s*\"|\"\\s*[!=]=\\s*" * n * "\\b"), code), tainted) &&
    return true
  return occursin(r"\)\s*[!=]=\s*\"", code) && _is_source1010(code)
end

# Every site in `path`, each as (line, marked).
function _sites1010(path)
  lines = readlines(path)
  codes = map(_code1010, lines)
  tainted = _tainted1010(codes)
  return [(i, _marked1010(lines, codes, i)) for i in eachindex(codes) if _is_site1010(codes, i, tainted)]
end

_offenders1010(path, root) =
  ["$(relpath(path, root)):$(line) matches driver-error text with no `# $(MARKER1010)` marker"
   for (line, marked) in _sites1010(path) if !marked]

@testset "#1010: no unreviewed match against driver-error text in src/ or ext/" begin
  root = pkgdir(PormG)
  offenders = String[]
  nsites = 0
  for dir in ("src", "ext"), (base, _, files) in walkdir(joinpath(root, dir)), f in files
    endswith(f, ".jl") || continue
    path = joinpath(base, f)
    nsites += length(_sites1010(path))
    append!(offenders, _offenders1010(path, root))
  end
  @test nsites >= 15        # the scan found the reviewed sites at all
  @test isempty(offenders)
  isempty(offenders) || foreach(o -> @info(o), offenders)
end

@testset "#1010: the scanner flags a text match and passes a reviewed one" begin
  # Its own mutation check, against a scratch file: each shape it exists to catch, and the shapes it
  # must let through.
  mktempdir() do dir
    probe(src) = (path = joinpath(dir, "probe.jl"); write(path, src); _offenders1010(path, dir))
    for leak in (
        # pre-#1001 bulk_insert
        "if occursin(\"duplicate key value violates unique constraint\", sprint(showerror, e))\nend\n",
        # pre-#1010 AdvisoryLock: a local bound from the rendering, matched on a later line
        "msg = lowercase(sprint(showerror, e))\nif occursin(\"canceling statement due to statement timeout\", msg)\nend\n",
        "contains(e.msg, \"deadlock detected\")\n",
        "startswith(error_message(err), \"ERROR\")\n",
        "low = lowercase(string(rollback_err))\nok = Base.occursin(\"x\", low)\n",
        "msg = string(e)\nm = lowercase(msg)\nendswith(m, \"y\")\n",
        "return occursin(\"a\", lowercase(string(e))) ||\n       occursin(\"b\", lowercase(string(e)))\n",
        # The #987 reason field: the server's own, localized, primary message.
        "occursin(\"deadlock\", e.message)\n",
        "msg = err.message\noccursin(\"x\", msg)\n",
        # Renderings that name the exception somewhere inside.
        "occursin(\"x\", string(_driver_cause(_unwrap_async_exception(e))))\n",
        "occursin(\"x\", repr(e))\n", "occursin(\"x\", \"\$e\")\n", "occursin(\"x\", sprint(show, err))\n",
        "msg = e |> string\noccursin(\"x\", msg)\n", "occursin(\"x\", e.cause.msg)\n",
        "occursin(\"x\", string(root))\n", "occursin(\"x\", string(cause))\n", "occursin(\"x\", string(e2))\n",
        # Other binding forms.
        "let msg = string(e)\n  occursin(\"x\", msg)\nend\n",
        "msg::String = string(e)\noccursin(\"x\", msg)\n",
        "msg, n = string(e), 1\noccursin(\"x\", msg)\n",
        # Other text tests.
        "m = match(r\"x\", string(e))\n", "findfirst(\"x\", sprint(showerror, e))\n",
        "msg = string(e)\nmsg == \"server closed\" && return true\n",
        "string(e) == \"LibPQ.Errors.UnknownError(\\\"\\\")\"\n")
      @test !isempty(probe(leak))
    end
    for fine in (
        "occursin('?', string(expr))\n",
        "# occursin(\"x\", sprint(showerror, e))\n",
        "occursin(\"x\", sprint(showerror, e))   # $(MARKER1010) SQLite text\n",
        "msg = lowercase(string(e))\n# $(MARKER1010) libpq's own text\nreturn occursin(\"a\", msg) ||\n       occursin(\"b\", msg)\n",
        "e.sqlstate == \"57014\" && occursin(\"x\", name)\n",
        # A `(` inside a literal must not carry the argument span onto the next line.
        "occursin(\"%(\", cname)\nreason = error_message(e)\n",
        "msg = string(e)\nq = findfirst('\"', msg)\n",
        "s = \"# not a comment\"; occursin(\"y\", s)\n")
      @test isempty(probe(fine))
    end
  end
end
