# ============================================================
# test/unit/test_tx_context_leaked_task.jl
#
# A task that outlives its transaction block does not keep the block's connection (#839).
#
# CONTRACT being tested:
#   The transaction context is a ScopedValue, so a task spawned inside `run_in_transaction` /
#   `atomic` inherits it — intended, so an awaited `@async` joins the transaction. But a task that
#   is NOT awaited, and so outlives the block, inherits it too. Before #839 nothing marked the
#   context as finished, and that task's `fetch` went on reusing the block's pinned connection,
#   flagged `in_transaction = true`, after the block had committed and handed the connection back
#   to the pool, where another borrower could lease it at the same moment. Since #831 the chain
#   exposed an ENCLOSING pool's connection the same way.
#
#   Now the block marks its context closed when it returns or throws, and every reader skips a
#   closed context. A leaked task falls through to ordinary acquisition, in autocommit, exactly
#   like a task created outside a transaction — and PormG warns once, because an unawaited task
#   inside a transaction is almost always a bug in the calling code.
#
# Hermetic: two real SQLite pools on temp files, no live database. Each leaked task waits on an
# Event that is notified only after its block has returned, so "outlives the block" is
# deterministic rather than a sleep race.
# ============================================================

using Test
using PormG
using PormG.Models: Model, CharField, IDField

# Needs the real SQLite extension (runtests.jl loads it too; re-loading is idempotent).
include(joinpath(@__DIR__, "..", "load_drivers.jl"))

const CP839 = PormG.ConnectionPool
const CFG839 = PormG.Configuration

# Registered in `config`, because a nested same-pool block becomes a SAVEPOINT and that path
# resolves settings from the pool.
const POOL_A_KEY_839 = "pormg839_sqlite_a"
const POOL_B_KEY_839 = "pormg839_sqlite_b"

function _pool_839(dir, name, key)
  pool = CP839.SQLiteConnectionPool(joinpath(dir, name); split_read_write = true, pool_timeout = 2)
  PormG.config[key] = CFG839.Settings(connections = pool, change_data = true)
  CP839.fetch(pool, "CREATE TABLE drivers (id INTEGER PRIMARY KEY, surname TEXT NOT NULL);")
  return pool
end

# The same `drivers` table as an ORM model, bound to each scratch database by key.
const ORM_DRIVERS_A_839 = Model("drivers", id = IDField(), surname = CharField())
ORM_DRIVERS_A_839.connect_key = POOL_A_KEY_839
const ORM_DRIVERS_B_839 = Model("drivers", id = IDField(), surname = CharField())
ORM_DRIVERS_B_839.connect_key = POOL_B_KEY_839

# Spawn `work` inside the current block, held back until `gate` is notified. Returns the task
# unawaited — the caller's block ends first, which is the whole point.
function _leak_839(work, gate::Base.Event)
  return @async begin
    wait(gate)
    work()
  end
end

# What a leaked task sees when it issues a statement on `pool`: whether the FetchTask claims the
# transaction (and so would skip the release), and whether any transaction context is visible.
function _probe_839(pool)
  ft = CP839.fetch_async(pool, "SELECT 1 AS x;")
  flag = ft.in_transaction
  CP839.await_result(ft)
  return (in_transaction = flag,
          tx_conn = CFG839.transaction_connection_for(pool),
          in_context = CFG839.in_transaction_context(),
          depth = CFG839.current_transaction_depth())
end

@testset "A task that outlives its transaction block (#839)" begin
  mktempdir() do dir
    a = _pool_839(dir, "a.sqlite", POOL_A_KEY_839)
    b = _pool_839(dir, "b.sqlite", POOL_B_KEY_839)
    try

      # ─────────────────────────────────────────────────────────────────────────────
      # Same pool: the leaked task does not reuse the released connection
      # The block commits and returns its connection to the pool; the task runs afterwards.
      # Unpatched, its FetchTask reported `in_transaction = true` on that released connection,
      # so nothing would ever release the lease it was not holding.
      # ─────────────────────────────────────────────────────────────────────────────
      @testset "same pool: autocommit, not the released connection" begin
        gate = Base.Event()
        leaked = CP839.atomic(a) do
          _leak_839(() -> _probe_839(a), gate)
        end
        @test all(a.available)            # the block really did hand its connection back
        notify(gate)
        seen = fetch(leaked)
        @test seen.in_transaction == false
        @test seen.tx_conn === nothing
        @test seen.in_context == false
        @test seen.depth == 0
        @test all(a.available)            # the autocommit lease came back too
      end

      # ─────────────────────────────────────────────────────────────────────────────
      # Through a nested block on another pool: the enclosing pool's connection is not exposed
      # `A → B → leak → fetch(a)`. Since #831 the chain looks through B's context to A's, so
      # unpatched the leaked task found A's released connection via the chain.
      # ─────────────────────────────────────────────────────────────────────────────
      @testset "nested on another pool: the ancestor's connection is not exposed" begin
        gate = Base.Event()
        leaked = CP839.atomic(a) do
          CP839.atomic(b) do
            _leak_839(() -> (_probe_839(a), _probe_839(b)), gate)
          end
        end
        notify(gate)
        seen_a, seen_b = fetch(leaked)
        @test seen_a.in_transaction == false
        @test seen_b.in_transaction == false
        @test seen_a.tx_conn === nothing && seen_b.tx_conn === nothing
        @test all(a.available) && all(b.available)
      end

      # ─────────────────────────────────────────────────────────────────────────────
      # Only the closed block is skipped: an enclosing block still open is still found
      # The task outlives the inner block on B but not the outer one on A, so A's transaction is
      # genuinely open when it runs — joining it is correct, as for any task spawned in A's block.
      # The fix must skip closed contexts, not discard the whole chain.
      # ─────────────────────────────────────────────────────────────────────────────
      @testset "an enclosing block that is still open is still found" begin
        seen, pinned_a = CP839.atomic(a) do
          gate = Base.Event()
          leaked = CP839.atomic(b) do
            _leak_839(() -> _probe_839(a), gate)
          end
          notify(gate)
          (fetch(leaked), CFG839.get_tx_connection())
        end
        @test seen.in_transaction == true
        @test seen.tx_conn === pinned_a
        @test seen.depth == 1             # the open block's depth, not the closed inner one's
        @test all(a.available) && all(b.available)
      end

      # ─────────────────────────────────────────────────────────────────────────────
      # A leaked task's own block is a fresh transaction, not a savepoint on a released connection
      # Unpatched, `atomic(a)` in the leaked task saw A's (finished) transaction as still open and
      # became a nested SAVEPOINT at depth 2 on the connection the block had already released.
      # Its write must commit as an ordinary outermost transaction instead.
      # ─────────────────────────────────────────────────────────────────────────────
      @testset "a block opened by the leaked task starts its own transaction" begin
        gate = Base.Event()
        leaked = CP839.atomic(a) do
          _leak_839(gate) do
            CP839.atomic(a) do
              CP839.fetch(a, "INSERT INTO drivers (surname) VALUES ('Hakkinen');")
              CFG839.current_transaction_depth()
            end
          end
        end
        notify(gate)
        @test fetch(leaked) == 1
        @test "Hakkinen" ∈ [r.surname for r in CP839.fetch(a, "SELECT surname FROM drivers;")]
        @test all(a.available)
      end

      # ─────────────────────────────────────────────────────────────────────────────
      # The context is closed on a throw as well as on a normal return
      # A rolled-back block hands its connection back just the same, so a task leaked from it
      # must not reuse that connection either.
      # ─────────────────────────────────────────────────────────────────────────────
      @testset "a block that throws closes its context too" begin
        gate = Base.Event()
        leaked = Ref{Task}()
        err = try
          CP839.atomic(a) do
            leaked[] = _leak_839(() -> _probe_839(a), gate)
            error("safety car deployed")
          end
          nothing
        catch e
          e
        end
        @test err isa ErrorException
        notify(gate)
        @test fetch(leaked[]).in_transaction == false
        @test all(a.available)
      end

      # ─────────────────────────────────────────────────────────────────────────────
      # PormG warns when a task outlives its block
      # An unawaited task inside a transaction is almost always a caller bug: its work silently
      # leaves the transaction. It is logged once per process — readers run several times per
      # statement — so the test resets the once-flag the earlier testsets already tripped. The
      # logger here IGNORES `maxlog`, as an app's logging stack may: two leaked tasks, each walking
      # past the closed context several times, must still produce exactly one warning. The tasks
      # are created under that logger because a task takes its logger from its parent at creation.
      # ─────────────────────────────────────────────────────────────────────────────
      @testset "a warning names the escaped task, once" begin
        CFG839._OUTLIVED_BLOCK_WARNED[] = false
        logger = Test.TestLogger(min_level = Base.CoreLogging.Warn, respect_maxlog = false)
        Base.CoreLogging.with_logger(logger) do
          gate = Base.Event()
          leaked = CP839.atomic(a) do
            (_leak_839(() -> _probe_839(a), gate), _leak_839(() -> _probe_839(a), gate))
          end
          notify(gate)
          foreach(fetch, leaked)
        end
        warnings = [r for r in logger.logs if occursin("outlived the transaction block", string(r.message))]
        @test length(warnings) == 1
        @test warnings[1].level == Base.CoreLogging.Warn
      end

      # ─────────────────────────────────────────────────────────────────────────────
      # ORM calls from a leaked task follow the same rules as any other call
      # With no block left open, an ORM write is an ordinary autocommit write. When the task
      # outlived only an inner block on B and A's block is still running, a transaction is still
      # open, so #838's scope rule applies: a call on A joins A's transaction, and a call on B —
      # whose block has ended — is refused rather than run in autocommit.
      # ─────────────────────────────────────────────────────────────────────────────
      @testset "ORM calls from a leaked task" begin
        gate = Base.Event()
        leaked = CP839.atomic(a) do
          _leak_839(() -> ORM_DRIVERS_A_839.objects.create("surname" => "Fittipaldi"), gate)
        end
        notify(gate)
        fetch(leaked)
        @test "Fittipaldi" ∈ [r.surname for r in CP839.fetch(a, "SELECT surname FROM drivers;")]

        err = try
          CP839.atomic(a) do
            gate = Base.Event()
            leaked = CP839.atomic(b) do
              _leak_839(gate) do
                ORM_DRIVERS_A_839.objects.create("surname" => "Piquet")   # A: still open, joins it
                ORM_DRIVERS_B_839.objects.create("surname" => "Piquet")   # B: block ended, refused
              end
            end
            notify(gate)
            fetch(leaked)
          end
          nothing
        catch e
          e
        end
        # The block's rollback path unwraps the task failure, so the TransactionError arrives bare.
        @test err isa PormG.TransactionError
        @test occursin(POOL_B_KEY_839, PormG.error_message(err))
        @test "Piquet" ∉ [r.surname for r in CP839.fetch(a, "SELECT surname FROM drivers;")]   # rolled back with A
        @test isempty(CP839.fetch(b, "SELECT surname FROM drivers;"))
        @test all(a.available) && all(b.available)
      end

    finally
      delete!(PormG.config, POOL_A_KEY_839)
      delete!(PormG.config, POOL_B_KEY_839)
      CP839.close_pool!(a; drain_seconds = 0)
      CP839.close_pool!(b; drain_seconds = 0)
    end
  end
end
