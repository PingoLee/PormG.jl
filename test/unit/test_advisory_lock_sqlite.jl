# ─────────────────────────────────────────────────────────────────────────────
# with_advisory_lock on SQLite: the no-op now signals (#277)
#
# SQLite has no advisory locks, so the body runs with NO mutual exclusion. Staying
# a no-op is deliberate — it is what lets one source target PostgreSQL in
# production and SQLite in tests — but it degrades a *guarantee*, not a query that
# still returns correct rows, and the failure mode is a race visible only under
# concurrency. #277 made the path speak up without changing the default behavior.
# `on_missing_lock` picks the policy by name:
#
#   :warn (default) → body runs, warns once per key
#   :ignore         → body runs silently (the caller accepted the no-op)
#   :error          → BackendCapabilityError; the body does NOT run
#
# Before #277 this method was `f()` and nothing else, and it had ZERO test
# coverage anywhere: test/integration/test_advisorylock.jl returns before defining
# any testset when the adapter is SQLite.
#
# Runs WITHOUT a live database — the SQLite method never touches a connection.
# ─────────────────────────────────────────────────────────────────────────────

using Test
using PormG
using Logging

# Suffixed names on purpose: bare `MockSQLite` / `MockPostgres` already exist in
# several unit files, and runtests.jl includes them all into ONE session, so a
# duplicate silently redefines the struct for whichever file runs later.
struct MockSQLiteLock277 <: PormG.PormGSQLite end

const ADVLOCK_SRC = joinpath(normpath(joinpath(@__DIR__, "..", "..")), "src", "AdvisoryLock.jl")

# Collect only the warnings a block emits, from a FRESH warn-ledger. The ledger is
# process-wide (that is what makes "once per key" hold across a whole run), so
# without the reset these testsets would suppress each other depending on order.
function _advlock_warnings(f)
  PormG.AdvisoryLock._reset_sqlite_lock_warnings!()
  tl = Test.TestLogger()
  Logging.with_logger(tl) do
    f()
  end
  return filter(r -> r.level == Logging.Warn, tl.logs)
end

@testset "SQLite advisory-lock signalling (#277)" begin

  # ───────────────────────────────────────────────────────────────────────────
  # Default (:warn): the body still runs — the no-op is preserved — but it warns.
  # The return value must pass through untouched; callers use this for real work.
  # ───────────────────────────────────────────────────────────────────────────
  @testset ":warn (default) runs the body, warns, passes the value through" begin
    conn = MockSQLiteLock277()
    result = Ref{Any}(nothing)

    logs = _advlock_warnings() do
      result[] = PormG.with_advisory_lock(() -> :body_ran, conn, "standings_rebuild_2024")
    end

    @test result[] == :body_ran
    @test length(logs) == 1
    @test occursin("mutual exclusion", logs[1].message)   # emphasis casing is not the contract
    @test occursin("on_missing_lock", logs[1].message)    # the message must name the way out
    @test logs[1].kwargs[:key] == "standings_rebuild_2024"
  end

  # ───────────────────────────────────────────────────────────────────────────
  # The dedup IS the feature: a scheduled job taking the same lock in a loop must
  # not fill the log. Three calls on one key produce exactly one warning.
  #
  # Deliberately NOT built on `@warn maxlog=1`: that is honoured only by loggers
  # that implement it, so under a custom application sink it would degrade to
  # warning on every call. The explicit ledger holds for any logger.
  # ───────────────────────────────────────────────────────────────────────────
  @testset "same key warns exactly once, however many calls" begin
    conn = MockSQLiteLock277()
    calls = Ref(0)

    logs = _advlock_warnings() do
      for _ in 1:3
        PormG.with_advisory_lock(() -> (calls[] += 1), conn, "nightly_result_import")
      end
    end

    @test calls[] == 3          # every call still ran the body
    @test length(logs) == 1     # …but only the first one warned
  end

  # ───────────────────────────────────────────────────────────────────────────
  # Discrimination for the dedup: it is keyed per LOCK KEY, not once per session.
  # A single global flag would collapse these to one and hide the second critical
  # section entirely.
  # ───────────────────────────────────────────────────────────────────────────
  @testset "distinct keys warn separately" begin
    conn = MockSQLiteLock277()

    logs = _advlock_warnings() do
      PormG.with_advisory_lock(() -> nothing, conn, "driver_update_44")
      PormG.with_advisory_lock(() -> nothing, conn, "driver_update_1")
    end

    @test length(logs) == 2
    @test sort([l.kwargs[:key] for l in logs]) == ["driver_update_1", "driver_update_44"]
  end

  # ───────────────────────────────────────────────────────────────────────────
  # The ledger is BOUNDED — `"driver_update_$(id)"` is the pattern the docs teach,
  # so unbounded key cardinality is the expected case, not an edge case. Past the
  # cap it must stop growing, and it must SAY it has gone quiet rather than
  # silently swallowing the rest.
  # ───────────────────────────────────────────────────────────────────────────
  @testset "the warn ledger is capped, and announces the cap" begin
    conn = MockSQLiteLock277()
    cap = PormG.AdvisoryLock.SQLITE_LOCK_WARN_CAP

    logs = _advlock_warnings() do
      for i in 1:(cap + 25)   # comfortably past the ceiling
        PormG.with_advisory_lock(() -> nothing, conn, "driver_update_$(i)")
      end
    end

    @test length(logs) == cap                       # bounded, not one per key
    @test occursin("suppressed", logs[end].message)  # and it said so
    @test !occursin("suppressed", logs[1].message)   # only on the one that hit the cap
  end

  # ───────────────────────────────────────────────────────────────────────────
  # Informed consent: `:ignore` means "I know, and I accept it" and must be
  # completely silent — otherwise a SQLite test suite can never quiet this.
  # ───────────────────────────────────────────────────────────────────────────
  @testset ":ignore runs the body silently" begin
    conn = MockSQLiteLock277()
    result = Ref{Any}(nothing)

    logs = _advlock_warnings() do
      result[] = PormG.with_advisory_lock(() -> :quiet, conn, "cache_warm";
                                          on_missing_lock = :ignore)
    end

    @test result[] == :quiet
    @test isempty(logs)
  end

  # ───────────────────────────────────────────────────────────────────────────
  # The escape hatch. `:error` must FAIL rather than hand back a guarantee SQLite
  # cannot provide — and critically, the body must not run. A `@test_throws` alone
  # would pass even if the body had already executed, so the side-effect flag is
  # the assertion that matters.
  # ───────────────────────────────────────────────────────────────────────────
  @testset ":error throws and does NOT run the body" begin
    conn = MockSQLiteLock277()
    ran = Ref(false)

    err = try
      PormG.with_advisory_lock(() -> (ran[] = true), conn, "payout_reconciliation";
                               on_missing_lock = :error)
      nothing
    catch e
      e
    end

    @test err isa PormG.BackendCapabilityError
    @test ran[] == false
    # Assert the cause, not merely the type: the message must name the remedy and
    # the offending key, per the BackendCapabilityError house style.
    msg = sprint(showerror, err)
    @test occursin("on_missing_lock", msg)
    @test occursin("payout_reconciliation", msg)
    @test occursin("PostgreSQL", msg)
  end

  # ───────────────────────────────────────────────────────────────────────────
  # A typo must fail loudly, and on BOTH backends — otherwise `:warm` for `:warn`
  # passes every PostgreSQL test and only surfaces on SQLite. The SQLite side is
  # checked here; the PostgreSQL method validates through the same helper, which
  # is asserted directly since reaching its body needs a live connection.
  # ───────────────────────────────────────────────────────────────────────────
  @testset "an unrecognised on_missing_lock raises InvalidValueError" begin
    conn = MockSQLiteLock277()
    ran = Ref(false)

    err = try
      PormG.with_advisory_lock(() -> (ran[] = true), conn, "k"; on_missing_lock = :warm)
      nothing
    catch e
      e
    end

    @test err isa PormG.InvalidValueError
    @test ran[] == false
    @test occursin("warm", sprint(showerror, err))

    # The shared validator the PostgreSQL method calls before acquiring anything.
    @test PormG.AdvisoryLock._validate_on_missing_lock(:warn) === nothing
    @test PormG.AdvisoryLock._validate_on_missing_lock(:ignore) === nothing
    @test PormG.AdvisoryLock._validate_on_missing_lock(:error) === nothing
    @test_throws PormG.InvalidValueError PormG.AdvisoryLock._validate_on_missing_lock(:nope)
  end

  # ───────────────────────────────────────────────────────────────────────────
  # Portability: the whole point of the keyword is that ONE call site can carry it
  # and run on both backends. If the PostgreSQL method did not accept it,
  # `on_missing_lock = :error` would be a MethodError on the very backend that
  # satisfies it. Asserted on the signature because exercising the real
  # PostgreSQL body needs a live connection.
  # ───────────────────────────────────────────────────────────────────────────
  @testset "the PostgreSQL method accepts on_missing_lock" begin
    pg_methods = [m for m in methods(PormG.with_advisory_lock)
                  if PormG.PormGPostgres in Base.unwrap_unionall(m.sig).parameters]
    @test !isempty(pg_methods)
    @test all(m -> :on_missing_lock in Base.kwarg_decl(m), pg_methods)
  end

  # ───────────────────────────────────────────────────────────────────────────
  # The SQLite path must keep swallowing the PostgreSQL keywords — that tolerance
  # is what keeps a single source portable. Passing all four must not throw.
  # ───────────────────────────────────────────────────────────────────────────
  @testset "PostgreSQL keywords are still accepted and ignored on SQLite" begin
    conn = MockSQLiteLock277()
    @test PormG.with_advisory_lock(() -> :ok, conn, "portable_key";
                                   on_missing_lock = :ignore, wait = true, timeout_ms = 1,
                                   strategy = :block, interval_ms = 5) == :ok
  end

  # ───────────────────────────────────────────────────────────────────────────
  # Regression guard for the `Base.wait` shadowing bug fixed alongside #277.
  #
  # The `wait::Bool` keyword shadows `Base.wait` inside the PostgreSQL method, so
  # a bare `wait(...)` evaluated as `false(...)` and raised MethodError, which the
  # surrounding empty `catch` swallowed — the statement_timeout restore had never
  # once completed, and the async SET was never awaited before the connection went
  # back to the pool.
  #
  # A source scan because the only way to reach those lines is a live PostgreSQL
  # connection with strategy=:block; a text assertion that genuinely fails on
  # reintroduction beats a test that cannot run in CI. It scans the whole
  # PostgreSQL METHOD BODY for any unqualified `wait(`, rather than matching one
  # call shape — so hoisting the argument into a temporary (`h = ...; wait(h)`)
  # is caught too. Same technique as test_docstring_coverage.jl. Line endings
  # normalized: .jl is not pinned to LF in .gitattributes (#216, #228).
  #
  # #322 changed HOW the restore is awaited — `_await_lock_handle`, which fetches
  # the handle AND records a cancellation for the connection-recovery decision —
  # so the positive anchors below name that instead of `Base.wait(`. The negative
  # assertion, which is the actual invariant, is untouched: the method must never
  # call the shadowed `wait`. It is now stronger by construction, since the method
  # no longer calls `wait` in any form.
  # ───────────────────────────────────────────────────────────────────────────
  @testset "the PostgreSQL method never calls the shadowed `wait`" begin
    src = replace(read(ADVLOCK_SRC, String), "\r\n" => "\n")

    start_idx = findfirst("function with_advisory_lock(f::Function, pool::PormGPostgres", src)
    @test start_idx !== nothing
    rest = src[first(start_idx):end]
    stop_idx = findfirst("\nend\n", rest)
    @test stop_idx !== nothing
    body = rest[1:first(stop_idx)]

    # Strip comments before scanning — the comment ABOVE the fix quotes `wait(...)`
    # while explaining the bug, and prose must not be able to fail a code guard.
    # (Line-based, which is sound here: no string literal in this method contains
    # a `#`.)
    code = replace(body, r"(?m)#.*$" => "")

    # Guard the guard: if the restore block were removed, or went back to
    # fire-and-forget, the negative assertion below would pass vacuously.
    #
    # SCOPED to the restore block, not the whole method. `Base.wait(` used to occur
    # at exactly the two restore sites, which is what made a whole-body anchor
    # honest; `_await_lock_handle(` occurs FOUR times in this method — twice in the
    # `:block` acquisition path — so a whole-body anchor for it is satisfied by code
    # that has nothing to do with the restore, and a fire-and-forget restore passes.
    # That is not hypothetical: it was demonstrated on this file (#322 review).
    restore_idx = findfirst("Restore statement_timeout", body)
    @test restore_idx !== nothing
    restore = replace(body[first(restore_idx):end], r"(?m)#.*$" => "")
    @test occursin("SET statement_timeout TO DEFAULT", restore)
    # EVERY statement issued from here on is awaited — the actual invariant, rather than "there are
    # two of them". A fixed count is both too weak and too strong once `restore` runs to the end of
    # the method: regressing one branch to fire-and-forget while any later statement is awaited keeps
    # the count at 2 (a silent pass), and legitimately adding an awaited statement breaks it (a false
    # positive). Both were demonstrated on this file (#322 delta review).
    @test count("_await_lock_handle(", restore) == count("backend_execute_async(", restore)
    @test count("backend_execute_async(", restore) >= 2   # …and the branches are still there

    # Any `wait(` not preceded by a dot or word character is the shadowed kwarg.
    @test !occursin(r"(?<![.\w])wait\s*\(", code)
  end
end
