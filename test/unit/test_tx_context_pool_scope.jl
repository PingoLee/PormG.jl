# ============================================================
# test/unit/test_tx_context_pool_scope.jl
#
# The ambient transaction context belongs to ONE pool (#831).
#
# CONTRACT being tested:
#   A transaction opened by `run_in_transaction(pool_a)` binds pool A's connection into a
#   ScopedValue. Every reader of that context must check that the context is on the pool it is
#   about to use. Before #831, `fetch_async` and `fetch_copy` reused the connection whatever pool
#   the call targeted, so `fetch(pool_b, …)` inside A's transaction ran on A's connection — the
#   wrong database inside the wrong transaction, possibly through the other engine's driver.
#
#   Nested blocks on two databases need the context CHAIN, not just the innermost block: in
#   `atomic(b) do; atomic(a) do; fetch(b, …)`, the innermost context names only A, while B's
#   transaction is still open. A statement on B must find B's connection through the chain, and
#   every "is a transaction already open on this pool?" check (nested run_in_transaction,
#   atomic(durable=true), without_foreign_keys, the SQLite PK reservations, select_for_update) must
#   look through enclosing blocks too.
#
# Hermetic: two real SQLite pools on temp files (a table that exists only in B is the witness for
# "which database answered"), and mock PostgreSQL pools for the PG-only paths. No live database.
#
# The SQLite pools split reads from a single writer slot and time out after 2 s. While a
# transaction is open, it holds that pool's writer, so a regression that opens a SECOND write on
# the same pool fails fast with a pool timeout instead of hanging in SQLite's busy handler.
# ============================================================

using Test
using DataFrames
using PormG
using PormG.Models: Model, CharField, IDField, IntegerField

# Needs the real SQLite extension (runtests.jl loads it too; re-loading is idempotent).
include(joinpath(@__DIR__, "..", "load_drivers.jl"))

const CP831 = PormG.ConnectionPool
const CFG831 = PormG.Configuration

# ── Two scratch databases with DISJOINT tables ──
# A holds `drivers`, B holds `circuits`. A statement on `circuits` can only succeed on B, so the
# answer itself says which database ran it. Both are registered in `config`, because a nested
# same-pool block becomes a SAVEPOINT and that path resolves settings from the pool.
const POOL_A_KEY_831 = "pormg831_sqlite_a"
const POOL_B_KEY_831 = "pormg831_sqlite_b"

_scratch_pool_831(path) = CP831.SQLiteConnectionPool(path; split_read_write = true, pool_timeout = 2)

function _pool_a_831(dir)
  pool = _scratch_pool_831(joinpath(dir, "a.sqlite"))
  PormG.config[POOL_A_KEY_831] = CFG831.Settings(connections = pool, change_data = true)
  CP831.fetch(pool, "CREATE TABLE drivers (id INTEGER PRIMARY KEY, surname TEXT NOT NULL);")
  return pool
end

function _pool_b_831(dir)
  pool = _scratch_pool_831(joinpath(dir, "b.sqlite"))
  PormG.config[POOL_B_KEY_831] = CFG831.Settings(connections = pool, change_data = true)
  CP831.fetch(pool, "CREATE TABLE circuits (id INTEGER PRIMARY KEY, name TEXT NOT NULL);")
  CP831.fetch(pool, "INSERT INTO circuits (name) VALUES ('Interlagos');")
  return pool
end

_circuit_names_831(pool) = sort([r.name for r in CP831.fetch(pool, "SELECT name FROM circuits;")])
_driver_surnames_831(pool) = sort([r.surname for r in CP831.fetch(pool, "SELECT surname FROM drivers;")])
_raised_831(f) = try (f(); nothing) catch e; e end

# ── Mock PostgreSQL pool for `fetch_copy` (COPY is PG-only) ──
# Carries PostgresConnectionPool's exact fields (the pattern in test_fetch_retry_transaction.jl),
# and records the connection every COPY ran on.
mutable struct FakeConn831
  id::Int
end

mutable struct MockPGPool831 <: PormG.PormGPostgres
  connections::Vector{Any}
  available::Vector{Bool}
  connection_string::String
  pool_size::Int
  lock::ReentrantLock
  copied_on::Vector{Any}   # the connection each backend_copy_in! call received, in order
end
MockPGPool831() = MockPGPool831(Any[FakeConn831(1)], [true], "mock://pg831", 1, ReentrantLock(), Any[])

PormG.backend_is_alive(::MockPGPool831, conn) = conn isa FakeConn831
PormG.backend_connect(::MockPGPool831; kwargs...) = FakeConn831(2)
# BEGIN/COMMIT/ROLLBACK for the same-pool control case; nothing else runs through here.
PormG.backend_execute_async(::MockPGPool831, conn, sql::String, params) = @async NamedTuple[]
function PormG.backend_copy_in!(pool::MockPGPool831, conn, sql::String, data_itr)
  push!(pool.copied_on, conn)
  return 1
end

# ── Two mock PostgreSQL databases for the `select_for_update` guard ──
# The guard only exists on PostgreSQL (SQLite never locks). A model bound to database A, read
# through `.db(B)`, is what routes the query away from the model's own connection — past
# `ensure_model_transaction_scope`, which checks the model's binding. `fetch` is stubbed to record
# the statement and answer with no rows; distinct `name`s keep the two pools non-`===`.
struct MockSFUPool831 <: PormG.PormGPostgres
  name::String
end
const SFU_A_831 = MockSFUPool831("a")
const SFU_B_831 = MockSFUPool831("b")
PormG.config["pormg831_pg_a"] = CFG831.Settings(connections = SFU_A_831, change_data = true)
PormG.config["pormg831_pg_b"] = CFG831.Settings(connections = SFU_B_831, change_data = true)

const SFU_SQL_831 = String[]
function CP831.fetch(::MockSFUPool831, sql::String; kwargs...)
  push!(SFU_SQL_831, sql)
  return DataFrame()
end

const SFU_LAP_TIMES_831 = Model("pormg831_lap_times",
  id = IDField(), driver = CharField(), lap = IntegerField())
SFU_LAP_TIMES_831.connect_key = "pormg831_pg_a"

@testset "Transaction context is scoped to its own pool (#831)" begin
  mktempdir() do dir
    a = _pool_a_831(dir)
    b = _pool_b_831(dir)
    try

      # ─────────────────────────────────────────────────────────────────────────────
      # fetch / fetch_async: a call on another pool runs on THAT pool
      # Inside A's transaction, a read of B's `circuits` must be answered by B. Unpatched, it ran
      # on A's connection and failed with "no such table: circuits".
      # ─────────────────────────────────────────────────────────────────────────────
      @testset "fetch on another pool inside a transaction reads that pool" begin
        seen = CP831.run_in_transaction(a) do
          CP831.fetch(b, "SELECT name FROM circuits;")
        end
        @test [r.name for r in seen] == ["Interlagos"]

        # `fetch_async` is the funnel `fetch` delegates to; check it directly too, including that
        # the task is NOT marked in-transaction — so `await_result` hands B's lease back.
        task_flag, names = CP831.run_in_transaction(a) do
          task = CP831.fetch_async(b, "SELECT name FROM circuits;")
          flag = task.in_transaction
          (flag, [r.name for r in CP831.await_result(task)])
        end
        @test task_flag == false
        @test names == ["Interlagos"]
        @test all(b.available)   # every B slot came back; nothing leaked on the cross-pool path
      end

      # ─────────────────────────────────────────────────────────────────────────────
      # Same pool: the transaction connection is still reused
      # The control for the case above: the fix must narrow reuse to the right pool, not drop
      # it. A's own uncommitted insert is visible only on A's pinned connection.
      # ─────────────────────────────────────────────────────────────────────────────
      @testset "fetch on the transaction's own pool still reuses its connection" begin
        inside = CP831.run_in_transaction(a) do
          CP831.fetch(a, "INSERT INTO drivers (surname) VALUES ('Prost');")
          task = CP831.fetch_async(a, "SELECT surname FROM drivers;")
          (task.in_transaction, [r.surname for r in CP831.await_result(task)])
        end
        @test inside == (true, ["Prost"])
      end

      # ─────────────────────────────────────────────────────────────────────────────
      # A write on another pool is NOT part of the open transaction
      # It runs in autocommit on B (Django's per-connection model), so it survives A's rollback,
      # while A's own insert is rolled back.
      # ─────────────────────────────────────────────────────────────────────────────
      @testset "a write on another pool survives the transaction's rollback" begin
        err = _raised_831(() -> CP831.run_in_transaction(a) do
          CP831.fetch(a, "INSERT INTO drivers (surname) VALUES ('Senna');")
          CP831.fetch(b, "INSERT INTO circuits (name) VALUES ('Suzuka');")
          error("stewards voided the session")
        end)
        @test err isa ErrorException
        @test occursin("stewards voided the session", err.msg)
        @test "Senna" ∉ _driver_surnames_831(a)        # A rolled back
        @test "Suzuka" ∈ _circuit_names_831(b)         # B committed on its own
      end

      # ─────────────────────────────────────────────────────────────────────────────
      # Through a nested block: a statement on B finds B's transaction (the chain)
      # In `run_in_transaction(b) do; run_in_transaction(a) do; fetch(b, …)`, the innermost
      # context names only A. B's statement must still run on B's pinned connection — it sees B's
      # uncommitted row, and it is rolled back with B. Without the chain, it would lease a second B
      # connection and wait for B's writer slot (a pool timeout here; a hang in SQLite's busy
      # handler with a default pool).
      # ─────────────────────────────────────────────────────────────────────────────
      @testset "a statement on an enclosing transaction's pool runs in that transaction" begin
        names, conn_used, pinned_b = CP831.run_in_transaction(b) do
          CP831.fetch(b, "INSERT INTO circuits (name) VALUES ('Monza');")
          pinned = CFG831.get_tx_connection()
          CP831.run_in_transaction(a) do
            CP831.fetch(b, "INSERT INTO circuits (name) VALUES ('Spa');")
            (_circuit_names_831(b), CFG831.transaction_connection_for(b), pinned)
          end
        end
        @test issubset(["Monza", "Spa"], names)   # both rows, the outer one still uncommitted
        @test conn_used === pinned_b              # the chain found B's own connection

        # Rolled back with B, because it was part of B's transaction.
        err = _raised_831(() -> CP831.run_in_transaction(b) do
          CP831.run_in_transaction(a) do
            CP831.fetch(b, "INSERT INTO circuits (name) VALUES ('Imola');")
            error("red flag")
          end
        end)
        @test err isa ErrorException                # not a pool timeout on a second B connection
        @test "Imola" ∉ _circuit_names_831(b)
        @test all(a.available) && all(b.available)
      end

      # ─────────────────────────────────────────────────────────────────────────────
      # Through a nested block: a nested block on A becomes a savepoint, not a second BEGIN
      # In `atomic(a) do; atomic(b) do; atomic(a)`, A's transaction is still open. The inner
      # block must reuse A's connection as a SAVEPOINT. A second BEGIN IMMEDIATE on A would need
      # A's writer slot, which the outer block holds.
      # ─────────────────────────────────────────────────────────────────────────────
      @testset "a nested block on an enclosing transaction's pool is a savepoint" begin
        depth, seen = CP831.atomic(a) do
          CP831.fetch(a, "INSERT INTO drivers (surname) VALUES ('Hakkinen');")
          CP831.atomic(b) do
            CP831.atomic(a) do
              (PormG.current_transaction_depth(), _driver_surnames_831(a))
            end
          end
        end
        @test depth == 3                 # A, B, then A's savepoint level
        @test "Hakkinen" ∈ seen          # the outer A row, visible only on A's own connection

        # The savepoint rolls back on its own; the outer A transaction still commits.
        inner_err = CP831.atomic(a) do
          CP831.fetch(a, "INSERT INTO drivers (surname) VALUES ('Schumacher');")
          CP831.atomic(b) do
            _raised_831(() -> CP831.atomic(a) do
              CP831.fetch(a, "INSERT INTO drivers (surname) VALUES ('Coulthard');")
              error("gearbox failure")
            end)
          end
        end
        # The block's own error, re-raised by the savepoint — not a pool timeout from a second BEGIN.
        @test inner_err isa ErrorException
        @test occursin("gearbox failure", inner_err.msg)
        surnames = _driver_surnames_831(a)
        @test "Schumacher" ∈ surnames
        @test "Coulthard" ∉ surnames
      end

      # ─────────────────────────────────────────────────────────────────────────────
      # with_transaction never reads the ambient context
      # It uses the `conn` it is given or acquires from its own pool. Pinned here so a future
      # change that makes it consult the context has to scope it per pool too.
      # ─────────────────────────────────────────────────────────────────────────────
      @testset "with_transaction on another pool runs on that pool" begin
        rows = CP831.run_in_transaction(a) do
          first(CP831.with_transaction(b, "SELECT name FROM circuits WHERE name = 'Interlagos';";
                                       release_conn = true))
        end
        @test [r.name for r in rows] == ["Interlagos"]
        @test all(b.available)
      end

      # ─────────────────────────────────────────────────────────────────────────────
      # fetch_copy: COPY on another pool streams on that pool's connection
      # Inside a SQLite transaction, a COPY to a PostgreSQL pool must lease a PG connection.
      # Unpatched, it was handed A's SQLite handle.
      # ─────────────────────────────────────────────────────────────────────────────
      @testset "fetch_copy on another pool leases from that pool" begin
        pg = MockPGPool831()
        CP831.run_in_transaction(a) do
          CP831.fetch_copy(pg, "COPY lap_times FROM STDIN", ["841,1,1,1,\"1:38.109\",98109\n"])
        end
        @test length(pg.copied_on) == 1
        @test pg.copied_on[1] === pg.connections[1]   # PG's own slot, not A's SQLite.DB
        @test all(pg.available)                       # and the lease was returned
      end

      # ─────────────────────────────────────────────────────────────────────────────
      # fetch_copy: COPY on the transaction's own pool joins the transaction
      # The control for the case above: inside PG's own transaction, the COPY streams on the
      # pinned connection, so it commits or rolls back with the rest of the block.
      # ─────────────────────────────────────────────────────────────────────────────
      @testset "fetch_copy on the transaction's own pool reuses its connection" begin
        pg = MockPGPool831()
        pinned = CP831.run_in_transaction(pg) do
          CP831.fetch_copy(pg, "COPY lap_times FROM STDIN", ["841,1,1,1,\"1:38.109\",98109\n"])
          CFG831.get_tx_connection()
        end
        @test pg.copied_on == Any[pinned]
        @test all(pg.available)
      end

      # ─────────────────────────────────────────────────────────────────────────────
      # atomic(durable=true) is checked per database, enclosing blocks included
      # Django checks durability per connection, and #686 scoped `without_foreign_keys` the same
      # way. A durable block on B inside A's transaction is still B's outermost transaction; a
      # durable block on A is refused even when a block on B sits in between.
      # ─────────────────────────────────────────────────────────────────────────────
      @testset "durable atomic is outermost on its own pool only" begin
        @test CP831.atomic(a) do
          CP831.atomic(b; durable = true) do
            42
          end
        end == 42

        # Same pool: still refused, before anything is sent.
        inner_ran = Ref(false)
        err = _raised_831(() -> CP831.atomic(a) do
          CP831.atomic(a; durable = true) do
            inner_ran[] = true
          end
        end)
        @test err isa PormG.TransactionError
        @test occursin("already active on this database", PormG.error_message(err))
        @test !inner_ran[]

        # Same pool through a block on another database: still refused.
        err = _raised_831(() -> CP831.atomic(a) do
          CP831.atomic(b) do
            CP831.atomic(a; durable = true) do
              inner_ran[] = true
            end
          end
        end)
        @test err isa PormG.TransactionError
        @test !inner_ran[]
      end

      # ─────────────────────────────────────────────────────────────────────────────
      # without_foreign_keys is outermost on its pool, enclosing blocks included
      # #686's refusal must not be hidden by a block on another database in between.
      # ─────────────────────────────────────────────────────────────────────────────
      @testset "without_foreign_keys is refused through a block on another pool" begin
        inner_ran = Ref(false)
        err = _raised_831(() -> CP831.atomic(a) do
          CP831.atomic(b) do
            CP831.without_foreign_keys(() -> (inner_ran[] = true), a)
          end
        end)
        @test err isa PormG.TransactionError
        @test occursin("without_foreign_keys must be the outermost", PormG.error_message(err))
        @test !inner_ran[]
      end

      # ─────────────────────────────────────────────────────────────────────────────
      # SQLite primary-key reservations are shared with the same pool only
      # The reservation table is keyed by (table, pk) with no database in the key. A nested
      # context on the same pool shares it (that is what makes reservations survive a savepoint),
      # also through a block on another pool in between; a nested context on another pool must
      # start empty and must not write into the outer one.
      # ─────────────────────────────────────────────────────────────────────────────
      @testset "reservation table is shared on the same pool only" begin
        _reservations() = CFG831._tx_context[].sqlite_reserved_primary_keys
        CFG831.with_tx_context(a, :conn_a) do
          outer = _reservations()
          outer[("drivers", "id")] = 858

          CFG831.with_tx_context(a, :conn_a) do
            @test _reservations() === outer        # same pool → inherited
          end

          CFG831.with_tx_context(b, :conn_b) do
            inner = _reservations()
            @test inner !== outer                  # other pool → fresh table
            @test isempty(inner)
            inner[("drivers", "id")] = 1           # B's reservation for a same-named table…

            CFG831.with_tx_context(a, :conn_a) do
              @test _reservations() === outer      # A again, through B → A's table
            end
          end
          @test outer[("drivers", "id")] == 858    # …never reaches A's
        end
      end

      # ─────────────────────────────────────────────────────────────────────────────
      # select_for_update needs the transaction on the pool the read runs on
      # A PostgreSQL row lock outside a transaction is released at once, so the guard raises.
      # `.db(B)` routes a model bound to A onto B: a transaction open on A does not hold B's lock.
      # The control reads through A's own connection and passes the guard.
      # ─────────────────────────────────────────────────────────────────────────────
      @testset "select_for_update via .db() needs a transaction on that database" begin
        empty!(SFU_SQL_831)
        err = _raised_831(() -> CFG831.with_tx_context(SFU_A_831, :tx_a) do
          SFU_LAP_TIMES_831.objects.db("pormg831_pg_b").select_for_update().list()
        end)
        @test err isa PormG.QueryBuildError
        @test occursin("select_for_update() must run inside a transaction", PormG.error_message(err))
        @test isempty(SFU_SQL_831)   # refused before anything was sent

        CFG831.with_tx_context(SFU_A_831, :tx_a) do
          SFU_LAP_TIMES_831.objects.select_for_update().list()
        end
        @test length(SFU_SQL_831) == 1
        @test occursin("FOR UPDATE", SFU_SQL_831[1])
      end

    finally
      CP831.close_pool!(a)
      CP831.close_pool!(b)
      delete!(PormG.config, POOL_A_KEY_831)
      delete!(PormG.config, POOL_B_KEY_831)
      delete!(PormG.config, "pormg831_pg_a")
      delete!(PormG.config, "pormg831_pg_b")
    end
  end
end
