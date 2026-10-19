"""
`UsageError` — the umbrella for "PormG refused the call" (#1238).

A refusal of the caller's input has moved between concrete types on consecutive trains (#576 to
`FilterError`, #971 and #988 to `InvalidValueError`), and `catch PormGError` is too wide for a
"bad request" handler: it also catches the database, the pool and the configuration. This file
pins the umbrella's membership exactly, because moving a type into or out of it changes what an
app's `catch e isa UsageError` matches, and shows a representative refusal of each member reaching
no driver.

No database required: the PostgreSQL pool is a mock that records every statement.
"""
# julia --project=test/integration test/unit/test_usage_error.jl

using Test
using InteractiveUtils: subtypes
using PormG
using PormG.Models: Model, IDField, IntegerField, FloatField

_usage_concrete(T, acc = Set{Any}()) =
  (foreach(S -> isabstracttype(S) ? _usage_concrete(S, acc) : push!(acc, S), subtypes(T)); acc)

@testset "UsageError membership is exactly the five (#1238)" begin
  # What: the direct children of `UsageError`, and every concrete type beneath it.
  # Why: membership is the umbrella's contract. A type added later would start answering a bad
  # request to whatever it reports (BackendCapabilityError is a deployment fault); one removed
  # would escape the handler. Either move owes an upgrading/ entry, so it must fail here first.
  @test PormG.UsageError <: PormG.PormGError
  @test isabstracttype(PormG.UsageError)
  @test Set(subtypes(PormG.UsageError)) == Set([
    PormG.FieldAccessError, PormG.FilterError, PormG.InvalidValueError,
    PormG.QueryBuildError, PormG.UnsafeMutationError])
  @test _usage_concrete(PormG.UsageError) == Set([
    PormG.UnknownFieldError, PormG.AmbiguousFieldError, PormG.LazyTraversalError,
    PormG.FilterError, PormG.InvalidValueError, PormG.QueryBuildError, PormG.UnsafeMutationError])
end

# ─────────────────────────────────────────────────────────────────────────────
# A representative refusal per member, against a PostgreSQL mock that records every statement
# handed to `backend_execute_async` and then fails, so a statement that got through is visible.
# Calls run inside `with_tx_context`, standing in for `run_in_transaction`: the mock has no
# connection to acquire. The pattern is test_nul_in_string_values.jl's.
# ─────────────────────────────────────────────────────────────────────────────
struct UsageMockPg1238 <: PormG.PormGPostgres end
PormG.config["usage1238_pg"] = PormG.Configuration.Settings(connections = UsageMockPg1238(), change_data = true)

const USAGE1238_SENT = String[]
struct UsageReached1238 <: Exception end
function PormG.backend_execute_async(::UsageMockPg1238, conn, sql::String, params)
  push!(USAGE1238_SENT, sql)
  throw(UsageReached1238())
end

const USAGE1238_RESULT = Model("usage1238_result",
  resultid = IDField(), grid = IntegerField(), points = FloatField())
USAGE1238_RESULT.connect_key = "usage1238_pg"

# Run `f` in the mock's transaction context, and return what it raised, or `nothing`.
function usage1238(f)
  empty!(USAGE1238_SENT)
  try
    PormG.Configuration.with_tx_context(f, PormG.config["usage1238_pg"].connections, :mock_tx_conn)
    nothing
  catch e
    e
  end
end

@testset "each member is refused before the driver is called (#1238)" begin
  # What: a well-formed read reaches the mock (one recorded statement, and the mock's own failure
  # arrives classified as a `StatementError`); each refusal below raises its member, is caught as
  # `UsageError`, and records none.
  # Why: the umbrella promises that PormG, not the database, refused the call. Its docstring names
  # the calls that refuse after one of their own statements ran (bulk chunks, delete cascades, get_or_create); the
  # build-time refusals here are the common case and must stay ahead of the driver.
  R = USAGE1238_RESULT
  e = usage1238(() -> R.objects.filter("grid" => 1).list())
  @test e isa PormG.StatementError && e.cause isa UsageReached1238
  @test length(USAGE1238_SENT) == 1

  cases = (
    (PormG.UnknownFieldError,   () -> R.objects.filter("no_such_field" => 1).list()),
    (PormG.FilterError,         () -> R.objects.filter(123).list()),
    (PormG.InvalidValueError,   () -> R.objects.filter("grid" => "pole").list()),
    (PormG.QueryBuildError,     () -> R.objects.values("points__@gte").list()),
    (PormG.UnsafeMutationError, () -> R.objects.update("grid" => 1)),
  )
  for (T, call) in cases
    e = usage1238(call)
    @test e isa T
    @test e isa PormG.UsageError
    @test isempty(USAGE1238_SENT)
  end
end
