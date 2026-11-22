# ============================================================
# test/unit/test_atomic_callee_trim_1599.jl
#
# CONTRACT being tested:
#   `atomic(f, key)` and `atomic(f, settings)` hand the block to `with_pool` as the callee (`_Atomic`, #1599 layer 2)
#   instead of in its vararg slot (`with_pool(_atomic_on, pool, f, durable)`), and answer as the old form did: the
#   block's value, the block's own error after a rollback, `durable = true` refused inside an open transaction with
#   the same `TransactionError`, and an entry with no pool refused with the same `InvalidConfigurationError`. The old
#   form, copied below, is the oracle.
#
# Hermetic: a SQLite file in a temporary directory, no server.
#
# Run: julia --project=test/integration test/unit/test_atomic_callee_trim_1599.jl
# ============================================================

using Test
isdefined(Main, :SQLite) || include(joinpath(@__DIR__, "..", "load_drivers.jl"))
using PormG

const _ACT_CP = PormG.ConnectionPool
const _ACT_C = PormG.Configuration

# The form `atomic(f, ::String)` / `atomic(f, ::Settings)` had before `_Atomic`.
_act_old_atomic_on(pool, f::F, durable::Bool) where {F<:Function} = _ACT_CP.atomic(f, pool; durable = durable)
_act_old_atomic(f::F, db::String; durable::Bool = false) where {F<:Function} =
  _ACT_CP.with_pool(_act_old_atomic_on, _ACT_C.get_settings(db).connections, f, durable)
_act_old_atomic(f::F, s::PormG.Kernel.Settings; durable::Bool = false) where {F<:Function} =
  _ACT_CP.with_pool(_act_old_atomic_on, s.connections, f, durable)

struct _ActRollback <: Exception
  msg::String
end

_act_outcome(f) = try
  (:ok, f())
catch e
  (:err, typeof(e), sprint(showerror, e))
end

_act_count(key) = only(_ACT_CP.fetch(_ACT_C.get_settings(key).connections, "SELECT count(*) AS n FROM lap")).n

# What: the new `atomic` against the old form, on a key and on its settings entry: a value, a raised error (and the
#   rollback it causes), `durable = true` nested in an open block, and an entry with no pool.
# Expected: the same outcome (value, or error type and text) from both, and the same rows left after each.
# Why: `_Atomic` replaced the vararg call a trimmed image had no code for; the block must still run, roll back and
#   refuse exactly as before.
@testset "atomic answers as its vararg form did (#1599 layer 2)" begin
  dir = mktempdir()
  key = "act_atomic"
  _ACT_C.register_connection(key, joinpath(dir, "f1.sqlite"); adapter = "SQLite", env = "prod", pool_size = 1,
                             change_db = true, change_data = true)
  try
    pool = _ACT_C.get_settings(key).connections
    _ACT_CP.fetch(pool, "CREATE TABLE lap (raceid INTEGER, lap INTEGER)")
    for (label, new, old) in ((:key, f -> PormG.atomic(f, key), f -> _act_old_atomic(f, key)),
                              (:settings, f -> PormG.atomic(f, _ACT_C.get_settings(key)),
                               f -> _act_old_atomic(f, _ACT_C.get_settings(key))))
      @test (label, _act_outcome(() -> new(() -> 41 + 1))) == (label, _act_outcome(() -> old(() -> 41 + 1)))
      # A block that writes and raises its own error: both forms roll the write back and rethrow the error.
      raise = () -> (_ACT_CP.fetch(pool, "INSERT INTO lap VALUES (1, 30)"); throw(_ActRollback("lap 30")))
      n0 = _act_count(key)
      got_new = _act_outcome(() -> new(raise)); n_new = _act_count(key)
      got_old = _act_outcome(() -> old(raise)); n_old = _act_count(key)
      @test (label, got_new) == (label, got_old)
      @test got_new[1] === :err && got_new[2] === _ActRollback
      @test (label, n_new, n_old) == (label, n0, n0)
      # A block that writes and returns: both commit.
      write = () -> (_ACT_CP.fetch(pool, "INSERT INTO lap VALUES (2, 52)"); :done)
      @test (label, _act_outcome(() -> new(write))) == (label, (:ok, :done))
      @test (label, _act_outcome(() -> old(write))) == (label, (:ok, :done))
      @test _act_count(key) == n0 + 2
    end
    # `durable = true` inside an open block on the same database: the same `TransactionError`, from either entry form.
    inner_new = _act_outcome(() -> PormG.atomic(() -> PormG.atomic(() -> 1, key; durable = true), key))
    inner_old = _act_outcome(() -> PormG.atomic(() -> _act_old_atomic(() -> 1, key; durable = true), key))
    @test inner_new == inner_old
    @test inner_new[2] === PormG.TransactionError
    # An entry with no pool built: the same refusal.
    PormG.config["act_nopool"] = _ACT_C.Settings()
    try
      @test _act_outcome(() -> PormG.atomic(() -> 1, "act_nopool")) == _act_outcome(() -> _act_old_atomic(() -> 1, "act_nopool"))
      @test _act_outcome(() -> PormG.atomic(() -> 1, "act_nopool"))[2] === PormG.InvalidConfigurationError
    finally
      delete!(PormG.config, "act_nopool")
    end
  finally
    _ACT_C.close_pool!(key)
    delete!(PormG.config, key)
  end
end
