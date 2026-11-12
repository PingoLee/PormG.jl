# ============================================================
# test/unit/test_statement_threadpool.jl
#
# The task a driver statement runs in is in the caller's threadpool (#1577), hermetically.
#
# CONTRACT being tested:
#   `PormG._statement_task(f)` runs `f` on a task in the caller's threadpool: an `:interactive`
#   caller's on `:interactive`, a `:default` caller's on `:default`. The two driver extensions with no
#   asynchronous call of their own (Postgres.jl, MySQL.jl) start their statement's task through it, and
#   no extension spawns a task of its own.
#
# No live database. The end-to-end measurement is
# `test/performance/async_concurrency_probe.jl interactive` on `db_2` (Postgres.jl) and `db_my`.
#
# Run: julia --project=test/integration test/unit/test_statement_threadpool.jl
# ============================================================

using Test
using PormG
isdefined(Main, :SQLite) || include(joinpath(@__DIR__, "..", "load_drivers.jl"))

# What: `_statement_task` gives an `:interactive` caller a task on `:interactive`, and a `:default`
#   caller one on `:default`. The second is the control: a constant pool passes only one of the two.
# SQL: none.
# Why (#1577): the driver extensions spawned each statement on `:default` whatever the caller, so an
#   `:interactive` task's statement (a heartbeat, a lease renewal) waited for a free `:default` thread.
#   With every `:default` thread computing, an interactive lookup ran once in 6 s instead of 60 times, on
#   Postgres.jl and on MySQL alike. LibPQ runs the statement on the caller's thread and never had this.
@testset "a statement's task is in the caller's threadpool (#1577)" begin
  if Threads.nthreads(:interactive) == 0
    @test_skip "needs an interactive thread (julia -t N,1)"
  else
    statement_pool(caller::Symbol) = fetch(Threads.@spawn caller begin
      t = PormG._statement_task(() -> Threads.threadpool())
      (spawned = Threads.threadpool(t), ran = fetch(t))
    end)
    from_interactive = statement_pool(:interactive)
    @test from_interactive.spawned === :interactive
    @test from_interactive.ran === :interactive
    from_default = statement_pool(:default)
    @test from_default.spawned === :default
    @test from_default.ran === :default
  end
end

# What: no file in `ext/` spawns a task with `Threads.@spawn`, and the Postgres.jl and MySQL extensions
#   start their statement through `PormG._statement_task`.
# SQL: none.
# Why (#1577): a bare `Threads.@spawn` is a task on `:default` whatever the caller, which is the defect
#   above. The extension method cannot run hermetically (its connection needs a server, and an unconnected
#   driver struct crashes rather than throws), so this reads the source; a third backend (#1130) reaches
#   for the same verb.
@testset "driver extensions start a statement's task only through _statement_task (#1577)" begin
  ext_dir = joinpath(pkgdir(PormG), "ext")
  code_lines(path) = [l for l in eachline(path) if !startswith(lstrip(l), "#")]
  for file in sort(filter(endswith(".jl"), readdir(ext_dir)))
    spawns = [l for l in code_lines(joinpath(ext_dir, file)) if occursin("@spawn", l)]
    @test (file, spawns) == (file, String[])
  end
  for file in ("PormGPostgresExt.jl", "PormGMySQLExt.jl")
    @test (file, any(l -> occursin("PormG._statement_task(", l), code_lines(joinpath(ext_dir, file)))) == (file, true)
  end
end
