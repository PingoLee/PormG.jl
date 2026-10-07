"""
A database error's text never carries the value the database refused (#984, #987).

#971 settled that PormG's own refusals never print the value, because a bound value can be a password
or a token and an app may hand the message to an HTTP client. This file holds the same rule for the
failures the *database* raises, on the two channels they used to leak through:

  1. **The logs (#984).** `with_transaction` logged `"…: \$e"`. That leak was latent, not live: every
     backend's handle is a task, so `\$e` rendered `TaskFailedException(Task (failed) @0x…)` — no
     driver text, and no information either. One unwrap away, it is the driver's whole message, which
     on PostgreSQL quotes the value (`invalid input syntax for type integer: "<value>"`, or a
     `DETAIL: Key (code)=(<value>)`). The line now logs types and safe fields, and a source scan keeps
     every log macro in `src/` and `ext/` from interpolating an exception again.

Pinned with no server: the log case runs through a mock pool whose statement fails with a marker in
its message.

julia --project=test/integration test/unit/test_error_text_no_value.jl
"""

using Test
using PormG
using Logging
include(joinpath(@__DIR__, "..", "load_drivers.jl"))

const SECRET987 = "s3cr3t987"
const CP987 = PormG.ConnectionPool

# Run `f()` under a `TestLogger` at `Debug` and return every record flattened into one string: the
# message and each keyword value, rendered both ways a sink renders it — `string` (the 2-arg `show`)
# and, for an exception, `showerror`, which is what `ConsoleLogger` prints for `exception = e`.
function _logged987(f)
  logger = Test.TestLogger(min_level = Logging.Debug)
  with_logger(logger) do
    try; f(); catch; end
  end
  render(v) = v isa Exception ? string(v, " ", sprint(showerror, v)) :
              v isa Tuple && !isempty(v) && first(v) isa Exception ? render(first(v)) : string(v)
  return logger.logs, join((string(r.message, " ", join((string(k, "=", render(v)) for (k, v) in r.kwargs), " "))
                            for r in logger.logs), "\n")
end

# ─────────────────────────────────────────────────────────────────────────────
# A PG-shaped mock pool whose every statement fails with the marker in the driver's text.
# It carries the exact fields the pool machinery reads, so `with_transaction` runs its real
# acquire / catch / release path. The failure is thrown inside the task, as a real driver's is, so
# the error arrives wrapped in a `TaskFailedException`.
# ─────────────────────────────────────────────────────────────────────────────
mutable struct FakeConn987
  closed::Bool
end
Base.close(c::FakeConn987) = (c.closed = true; nothing)

mutable struct MockPGPool987 <: PormG.PormGPostgres
  connections::Vector{Any}
  available::Vector{Bool}
  connection_string::String
  pool_size::Int
  lock::ReentrantLock
end
MockPGPool987() = MockPGPool987(Any[FakeConn987(false)], [true], "mock://pg", 1, ReentrantLock())

PormG.backend_is_alive(::MockPGPool987, conn) = conn isa FakeConn987 && !conn.closed
PormG.backend_connect(::MockPGPool987; kwargs...) = FakeConn987(false)
PormG.backend_renew_connection(::MockPGPool987, conn; kwargs...) = FakeConn987(false)
PormG.backend_is_connection_error(::MockPGPool987, e) = false
PormG.backend_execute_async(::MockPGPool987, conn, sql::String, params) =
  @async error("ERROR:  invalid input syntax for type integer: \"$(SECRET987)\"")

# ─────────────────────────────────────────────────────────────────────────────
# with_transaction: the failure log names the types, never the driver's text (#984)
# The statement fails with the marker in its message. The caller still gets the classified
# `DatabaseError`, with the driver's text intact in `.cause` for a caller that wants it; the log
# record says which kinds failed and nothing the database said. The type keys are what the old
# `"…: $e"` line lacked (it named only the task wrapper); the marker check guards every later
# change to the record — a `msg = error_message(err)` is only safe while that rendering is.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#984: with_transaction logs the error's types, not its text" begin
  pool = MockPGPool987()
  thrown = Ref{Any}(nothing)
  logs, text = _logged987() do
    try
      CP987.with_transaction(pool, "UPDATE driver SET number = \$1"; release_conn = true)
    catch e
      thrown[] = e
      rethrow()
    end
  end

  # The caller's error is unchanged: classified, with the driver's own exception kept.
  @test thrown[] isa PormG.StatementError
  @test occursin(SECRET987, sprint(showerror, PormG.ConnectionPool._driver_cause(thrown[])))

  # The log: one record, structured, and the marker nowhere in it.
  record = only(filter(r -> occursin("Failed to execute SQL transaction", string(r.message)), logs))
  @test record.level == Logging.Error
  kw = Dict(record.kwargs)
  @test kw[:type] === PormG.StatementError
  @test kw[:cause_type] === ErrorException
  @test !occursin(SECRET987, text)

  # The connection went back to the pool despite the failure.
  @test pool.available == [true]
end

# ─────────────────────────────────────────────────────────────────────────────
# LibPQ's own logger: the documented way to keep the driver's text out of the logs works (#984)
# LibPQ prints every failed statement's full message — DETAIL and the value included — through
# its Memento logger before it throws, which no change inside PormG can intercept. errors.md tells
# an app to raise that logger's level; this pins that the call silences it and the error still
# reaches the caller.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#984: raising LibPQ's logger level silences the driver's own error line" begin
  err = LibPQ.Errors.PQResultError{LibPQ.Errors.C23, LibPQ.Errors.E23505}(
    "ERROR:  duplicate key value violates unique constraint \"drivers_code_key\"\n" *
    "DETAIL:  Key (code)=($(SECRET987)) already exists.\n")
  buf = IOBuffer()
  handler_key = "pormg-984-capture"
  level, propagating = LibPQ.Memento.getlevel(LibPQ.LOGGER), LibPQ.LOGGER.propagate
  LibPQ.LOGGER.handlers[handler_key] = LibPQ.Memento.DefaultHandler(buf)
  LibPQ.Memento.setpropagating!(LibPQ.LOGGER, false)   # print to `buf` only, not the suite's output
  try
    # By default the driver prints the value: this is the channel the docs warn about.
    @test_throws typeof(err) error(LibPQ.LOGGER, err)
    @test occursin(SECRET987, String(take!(buf)))

    # The documented call: nothing printed, the same error raised.
    LibPQ.Memento.setlevel!(LibPQ.LOGGER, "critical")
    raised = try error(LibPQ.LOGGER, err); nothing catch e; e end
    @test raised === err
    @test isempty(String(take!(buf)))
  finally
    LibPQ.Memento.setlevel!(LibPQ.LOGGER, level)   # no other test inherits the silenced logger
    LibPQ.Memento.setpropagating!(LibPQ.LOGGER, propagating)
    delete!(LibPQ.LOGGER.handlers, handler_key)
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# Source scan: no log macro in src/ or ext/ interpolates or renders an exception (#984)
# `"…: $e"` puts the driver's text — and with it the value — into the log, and so does a keyword
# whose value is `sprint(showerror, e)`. Log the type, a classified kind, or `msg = error_message(e)`
# instead. A reviewed exception (an error whose text is known not to carry user data) carries
# `# log-error-text-ok: <why>` on one of the call's lines.
# The scan reads the call's own text only: text rendered into a local first and logged by name
# (importers.jl's `reason = _one_line(sprint(showerror, e), 160)`) is out of its sight.
# ─────────────────────────────────────────────────────────────────────────────

# Names an exception goes by in this code base: `e`, `err`, `ex`, `exception`, and `<what>_err` /
# `<what>_error` (`rollback_err`, `renew_error`). An interpolation of one, or of its `.msg`, is its text.
const EXC_NAME987 = r"^(?:e|err|ex|exc|exception|error|[a-z_]+_err|[a-z_]+_error|[a-z_]+_exception)(?:\.msg)?$"

# The interpolations inside one string literal: `$name` and `$(expr)`.
function _interpolations987(lit::AbstractString)
  out = String[]
  for m in eachmatch(r"\$(?:\(((?:[^()]|\((?:[^()]|\([^()]*\))*\))*)\)|([A-Za-z_][A-Za-z0-9_]*))", lit)
    push!(out, strip(something(m.captures[1], m.captures[2], "")))
  end
  return out
end

_log_leaks987(expr) = occursin(EXC_NAME987, expr) || occursin("showerror", expr)

# Every log call's text: from the macro to its matching `)` when it is called with parentheses, else
# to the end of the line — extended over continuation lines that end in an operator (`*`, `,`).
function _log_sites987(path)
  lines = readlines(path)
  sites = Tuple{Int, String}[]
  i = 1
  while i <= length(lines)
    line = lines[i]
    m = match(r"@(?:error|warn|info|debug)\b", line)
    if m === nothing || occursin('#', line[1:prevind(line, m.offset)])   # absent, or in a comment
      i += 1
      continue
    end
    rest = line[m.offset:end]
    j = i
    if startswith(rest[ncodeunits(m.match)+1:end], "(")
      depth = count(==('('), rest) - count(==(')'), rest)
      while depth > 0 && j < length(lines)
        j += 1
        depth += count(==('('), lines[j]) - count(==(')'), lines[j])
      end
    else
      while j < length(lines) && occursin(r"[*,]\s*$", lines[j])
        j += 1
      end
    end
    push!(sites, (i, join(lines[i:j], "\n")))
    i = j + 1
  end
  return sites
end

function _log_offenders987(path, root)
  offenders = String[]
  for (line, span) in _log_sites987(path)
    occursin("log-error-text-ok:", span) && continue
    occursin("sprint(showerror", span) &&
      push!(offenders, "$(relpath(path, root)):$(line) renders an exception with `sprint(showerror, …)`")
    for lit in eachmatch(r"\"(?:[^\"\\]|\\.)*\"", span), expr in _interpolations987(lit.match)
      _log_leaks987(expr) && push!(offenders, "$(relpath(path, root)):$(line) interpolates `$(expr)`")
    end
  end
  return offenders
end

@testset "#984: no log macro in src/ or ext/ interpolates an exception" begin
  root = pkgdir(PormG)
  offenders = String[]
  nsites = 0
  for dir in ("src", "ext"), (base, _, files) in walkdir(joinpath(root, dir)), f in files
    endswith(f, ".jl") || continue
    path = joinpath(base, f)
    nsites += length(_log_sites987(path))
    append!(offenders, _log_offenders987(path, root))
  end
  @test nsites > 100        # the scan found the log calls at all
  @test isempty(offenders)
  isempty(offenders) || foreach(o -> @info(o), offenders)
end

@testset "#984: the scanner flags a leak and passes a type" begin
  # Its own mutation check, against a scratch file: each shape it exists to catch, and the shapes
  # it must let through.
  mktempdir() do dir
    probe(src) = (path = joinpath(dir, "probe.jl"); write(path, src); _log_offenders987(path, dir))
    for leak in ("@error \"Failed: \$e\"\n", "@warn \"Failed: \$(err)\" key=1\n",
                 "@error(\"rolled back: \$(rollback_err)\")\n", "@error \"x\" reason=sprint(showerror, e)\n",
                 "@error \"failed: \" *\n    \"\$(e.msg)\"\n", "  @warn(\"multi\",\n    \"\$(renew_error)\")\n")
      @test !isempty(probe(leak))
    end
    for fine in ("@error \"Failed\" exception=e\n", "@error \"Failed\" type=typeof(e) msg=error_message(e)\n",
                 "@warn \"pool \$(pool_size)\"\n", "# @error \"comment: \$e\"\n",
                 "@error \"x \$(typeof(e))\"\n",
                 "@warn \"y\" reason=sprint(showerror, e)  # log-error-text-ok: schema text\n")
      @test isempty(probe(fine))
    end
  end
end
