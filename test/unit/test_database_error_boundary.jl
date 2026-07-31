# ============================================================
# test/unit/test_database_error_boundary.jl
#
# The database-error boundary (#268).
#
# CONTRACT being tested:
#   `docs/src/api.md` promises "`catch PormGError` catches them all". Before #268 that was false
#   for runtime database failures: a UNIQUE violation, SQL the backend rejected, or a connection
#   dropped mid-query reached the caller as a raw `SQLite.SQLiteException` / `LibPQ.Errors.*`, so an
#   app had to depend on the driver package purely to NAME the type — fighting the weakdep design
#   that keeps LibPQ/SQLite optional. The pool now wraps those at its own seams into
#   `DatabaseError` subtypes, keeping the driver exception on `.cause`.
#
#   The half that is easy to get wrong is the NEGATIVE contract. `run_in_transaction`/`atomic`/
#   `with_savepoint` run the CALLER'S closure inside their `try`. Wrapping there would relabel a
#   user's `BoundsError` — or an `InterruptException` — as a `StatementError`, which is worse than
#   the problem being solved. Those bodies wrap their BEGIN/COMMIT/ROLLBACK statements individually
#   instead, and the tests below pin both directions.
#
# Runs against a REAL temp SQLite database, not a mock: classification reads driver message
# fingerprints, so a mock that fabricates them would prove only that the mock matches itself.
# The PostgreSQL half (exact SQLSTATE class mapping) is covered by the integration suite, which is
# the only place a real `LibPQ.Errors.PQResultError` exists.
# ============================================================

using Test
using PormG

# Needs the real SQLite extension (runtests.jl loads it too; re-loading is idempotent).
include(joinpath(@__DIR__, "..", "load_drivers.jl"))

const CPB = PormG.ConnectionPool

# ── Scratch database ────────────────────────────────────────────────────────
# One table with a UNIQUE + NOT NULL column and a self-referencing FK, which is enough to raise
# every integrity class SQLite distinguishes.
const BOUNDARY_KEY = "pormg268_boundary"

function _boundary_pool()
  path = joinpath(mktempdir(), "boundary.sqlite")
  pool = CPB.SQLiteConnectionPool(path)
  # Registered in `config`, not just constructed: a NESTED `atomic` becomes a SAVEPOINT, and that
  # path resolves settings from the pool via `connection_key_for_pool`, which scans `config`. An
  # unregistered pool fails with "Cannot resolve connection settings for the active transaction
  # pool" long before reaching the seam under test. Each call re-registers under the same key, and
  # every testset uses the pool it just built, so the lookup always resolves to the live one.
  PormG.config[BOUNDARY_KEY] = PormG.Configuration.Settings(
      connections = pool, change_data = true)
  CPB.fetch(pool, "PRAGMA foreign_keys = ON;")
  CPB.fetch(pool, """
    CREATE TABLE constructor (
      id   INTEGER PRIMARY KEY,
      code TEXT NOT NULL UNIQUE,
      successor INTEGER REFERENCES constructor(id)
    );""")
  CPB.fetch(pool, "INSERT INTO constructor (id, code) VALUES (1, 'MCL');")
  return pool
end

_raised(f) = try (f(); nothing) catch e; e end

@testset "Database-error boundary (#268)" begin

  # ─────────────────────────────────────────────────────────────────────────
  # The positive contract: the database said no, and it arrives as OUR type.
  # ─────────────────────────────────────────────────────────────────────────
  @testset "database failures arrive as DatabaseError subtypes" begin
    pool = _boundary_pool()

    # Each case asserts the SPECIFIC kind, not just "some PormGError". A classifier that collapsed
    # everything into StatementError would still satisfy `isa PormGError`, and the whole point of
    # IntegrityError is that an app can branch on it.
    unique_err = _raised(() -> CPB.fetch(pool, "INSERT INTO constructor (id, code) VALUES (2, 'MCL');"))
    @test unique_err isa PormG.IntegrityError

    notnull_err = _raised(() -> CPB.fetch(pool, "INSERT INTO constructor (id, code) VALUES (3, NULL);"))
    @test notnull_err isa PormG.IntegrityError

    fk_err = _raised(() -> CPB.fetch(pool, "INSERT INTO constructor (id, code, successor) VALUES (4, 'FER', 999);"))
    @test fk_err isa PormG.IntegrityError

    missing_table = _raised(() -> CPB.fetch(pool, "SELECT * FROM no_such_table;"))
    @test missing_table isa PormG.StatementError

    syntax = _raised(() -> CPB.fetch(pool, "SELEC 1;"))
    @test syntax isa PormG.StatementError

    # The umbrella must have no holes, and the root claim in api.md must hold.
    for e in (unique_err, notnull_err, fk_err, missing_table, syntax)
      @test e isa PormG.DatabaseError
      @test e isa PormGError
    end

    # Discrimination: StatementError and IntegrityError must not be the same bucket, or branching
    # on IntegrityError is meaningless. (A classifier returning :integrity unconditionally would
    # pass every assertion above.)
    @test !(missing_table isa PormG.IntegrityError)
    @test !(unique_err isa PormG.StatementError)
  end

  @testset "the driver exception survives on .cause" begin
    pool = _boundary_pool()
    err = _raised(() -> CPB.fetch(pool, "INSERT INTO constructor (id, code) VALUES (2, 'MCL');"))

    @test err isa PormG.IntegrityError
    @test err.adapter == "SQLite"
    # The exact driver type — this is what an app reaches for when it needs detail PormG's kinds
    # don't carry, and it is the promise `.cause` makes.
    @test err.cause isa SQLite.SQLiteException
    # …and the driver's own text must reach the caller through the documented accessor. A wrapper
    # that dropped the message would pass every `isa` assertion above.
    @test occursin("UNIQUE constraint failed", PormG.error_message(err))
    # `.msg` deliberately does not exist on the structured subtypes.
    @test :msg ∉ fieldnames(PormG.IntegrityError)
  end

  # ─────────────────────────────────────────────────────────────────────────
  # The NEGATIVE contract. This is the one that would have shipped a bug.
  # ─────────────────────────────────────────────────────────────────────────
  @testset "user code inside a transaction is never relabelled" begin
    pool = _boundary_pool()

    # Every one of these is raised by the CALLER's closure, not the driver. If `_as_database_error`
    # were applied to `_run_in_transaction_impl`'s function-wide catch (the obvious-looking place),
    # each would come back as a StatementError and every assertion here would fail.
    for (label, thunk) in (
          ("ErrorException", () -> error("validation failed")),
          ("BoundsError",    () -> [1, 2, 3][99]),
          ("KeyError",       () -> throw(KeyError(:nope))),
          ("custom type",    () -> throw(DimensionMismatch("bad shape"))),
        )
      err = _raised(() -> CPB.atomic(pool) do; thunk(); end)
      @test err !== nothing
      @test !(err isa PormG.DatabaseError)
      @test !(err isa PormGError)
    end

    # The identity of the user's exception must be preserved exactly, not merely its abstract class.
    sentinel = DimensionMismatch("f1 grid is 20 cars, got 22")
    err = _raised(() -> CPB.atomic(pool) do; throw(sentinel); end)
    @test err === sentinel

    # Same rule for savepoints (nested atomic → SAVEPOINT), which has its own catch.
    err = _raised(() -> CPB.atomic(pool) do
      CPB.atomic(pool) do; throw(sentinel); end
    end)
    @test err === sentinel
  end

  @testset "a real database failure inside a transaction still wraps" begin
    # The mirror of the test above: suppressing the wrap for user code must NOT suppress it for the
    # driver. Without this pair, "never relabel" could be satisfied by never wrapping at all.
    pool = _boundary_pool()
    err = _raised(() -> CPB.atomic(pool) do
      CPB.fetch(pool, "INSERT INTO constructor (id, code) VALUES (2, 'MCL');")
    end)
    @test err isa PormG.IntegrityError
    @test occursin("UNIQUE constraint failed", PormG.error_message(err))
  end

  # ─────────────────────────────────────────────────────────────────────────
  # Passthrough: PormG's own errors must not be re-wrapped or re-labelled.
  # ─────────────────────────────────────────────────────────────────────────
  @testset "PormG's own errors pass through the seam untouched" begin
    pool = _boundary_pool()

    # A QueryBuildError raised above the pool must not come back as a StatementError just because
    # it crossed a seam. `_as_database_error` returns PormGError values unchanged.
    original = PormG.QueryBuildError("not a database problem")
    @test CPB._as_database_error(pool, original) === original

    # …including when it arrives wrapped in the async envelope.
    task = @async throw(original)
    envelope = _raised(() -> Base.fetch(task))
    @test envelope isa TaskFailedException
    @test CPB._as_database_error(pool, envelope) === original
  end

  @testset "_driver_cause reaches the driver exception through the wrapper" begin
    # This accessor is what keeps `fetch`'s #138 reconnect-retry alive: the driver classifiers match
    # on the driver's type and message, so handing them the wrapper answers `false` and the retry
    # silently dies. Pin both directions.
    raw = ErrorException("server closed the connection")
    wrapped = PormG.OperationalError("PostgreSQL", raw)
    @test CPB._driver_cause(wrapped) === raw
    @test CPB._driver_cause(raw) === raw            # non-wrapper passes through unchanged
  end

  # ─────────────────────────────────────────────────────────────────────────
  # Classification, exercised directly.
  # ─────────────────────────────────────────────────────────────────────────
  @testset "backend_classify_error never throws and always returns a kind" begin
    pool = _boundary_pool()

    @test PormG.backend_classify_error(pool, SQLite.SQLiteException("UNIQUE constraint failed: t.c")) === :integrity
    @test PormG.backend_classify_error(pool, SQLite.SQLiteException("FOREIGN KEY constraint failed")) === :integrity
    @test PormG.backend_classify_error(pool, SQLite.SQLiteException("NOT NULL constraint failed: t.c")) === :integrity
    @test PormG.backend_classify_error(pool, SQLite.SQLiteException("no such table: nope")) === :statement
    @test PormG.backend_classify_error(pool, SQLite.SQLiteException("database is locked")) === :operational

    # A non-driver exception must fall to the core default rather than the SQLite method — that is
    # what keeps the behavioral pool mocks (which throw plain ErrorExceptions) working.
    @test PormG.backend_classify_error(pool, ErrorException("something else")) === :unknown

    # An unclassifiable failure must still land somewhere, so `catch DatabaseError` has no hole.
    @test CPB._as_database_error(pool, ErrorException("something else")) isa PormG.StatementError
  end

  # ─────────────────────────────────────────────────────────────────────────
  # Transaction-API misuse is NOT a database error.
  # ─────────────────────────────────────────────────────────────────────────
  @testset "transaction-API misuse raises TransactionError (#268)" begin
    pool = _boundary_pool()

    err = _raised(() -> CPB.atomic(pool) do
      CPB.atomic(pool; durable = true) do; nothing; end
    end)
    @test err isa PormG.TransactionError
    @test occursin("outermost transaction", PormG.error_message(err))
    # Nothing was sent to the database, so this must not be filed under DatabaseError…
    @test !(err isa PormG.DatabaseError)
    # …nor under the buckets it used to borrow, which is the whole reason the type exists.
    @test !(err isa PormG.QueryBuildError)
    @test !(err isa PormG.ConfigurationError)

    # `durable=true` outside a transaction is legal and must still run.
    @test CPB.atomic(pool; durable = true) do; 42; end == 42
  end

  # ─────────────────────────────────────────────────────────────────────────
  # Rendering.
  # ─────────────────────────────────────────────────────────────────────────
  @testset "showerror names the adapter and renders the cause" begin
    e = PormG.IntegrityError("SQLite", SQLite.SQLiteException("UNIQUE constraint failed: constructor.code"))
    msg = PormG.error_message(e)
    @test occursin("IntegrityError", msg)
    @test occursin("SQLite", msg)
    @test occursin("UNIQUE constraint failed: constructor.code", msg)
    # SQLite.jl defines no `showerror`, so `_cause_text` falls back to the cause's `msg` rather
    # than Julia's default struct rendering — otherwise the sentence reads
    # `… violated: SQLiteException("UNIQUE constraint failed: …")`, with the type name and quoting
    # as noise inside our own message.
    @test !occursin("SQLiteException(", msg)

    # A non-Exception cause is supported on purpose (advisory-lock contention passes a String, and
    # PoolConnectError set that precedent) — it must not throw when rendered.
    lock_err = PormG.OperationalError("PostgreSQL", "Failed to acquire advisory lock for 'grid'")
    @test occursin("Failed to acquire advisory lock", PormG.error_message(lock_err))
  end
end
