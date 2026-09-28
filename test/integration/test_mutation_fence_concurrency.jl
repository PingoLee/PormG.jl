# julia -t auto --project=test/integration test/integration/test_mutation_fence_concurrency.jl
#
# A filter is a FENCE, not just a selection (#765).
#
# `delete()`, the statements its cascade emits, and a joined `update()` used to scope their rows as
# `"pk" IN (SELECT "Tb"."pk" FROM <t> AS "Tb" WHERE <filters>)`. Under PostgreSQL READ COMMITTED a
# statement that waits on a row lock re-checks the row's NEW version against its own quals
# (EvalPlanQual) — and a self-subquery over the target is not one of them: it is an independent scan,
# read on the statement's snapshot, never re-run. So a filter written as a guard was ignored whenever
# another transaction changed the row and committed while the statement waited: the row was deleted
# (or updated, or nulled) though its new version matched nothing. Found through Nitro.jl#379, whose
# worker store did `.filter("id" => id, "run_id" => old, "status__@in" => terminal).delete()` as a
# compare-and-delete.
#
# Every testset below stages that race for real, with two sessions:
#
#   1. T1 opens a transaction, changes the row so the fence no longer matches, and does NOT commit.
#   2. T2 runs the fenced statement on another thread. It sees the committed OLD row, qualifies it,
#      and blocks on T1's row lock.
#   3. T1 commits; T2 resumes, re-checks, and must leave the row alone.
#
# Step 2 is PROVED, not assumed: `_mf_race` polls `pg_stat_activity` until T2's statement is waiting on
# a lock. Without that, a slow machine lets T1 commit before T2 reaches the row — T2 then reads the new
# version directly, affects nothing, and the test passes against the unfixed code as well. That probe
# is the one piece of raw SQL here, and it is irreducible: no ORM surface reports another session's
# lock wait.
#
# Each case was run against the unfixed renderer and fails there (1 row affected where 0 is correct).
#
# PostgreSQL only. SQLite cannot stage the race at all — `BEGIN IMMEDIATE` plus PormG's process-wide
# write lock serialize writers, so no statement ever waits on another writer's uncommitted row.

if !isdefined(Main, :PormG)
    include("common_setup.jl")
end

# Whether the race can run here. Decided up front and used to wrap the testset at the bottom, because
# a top-level `return` inside `if` leaves only that one expression — `include` evaluates the file
# expression by expression, so an early `return true` would skip nothing after it.
#
# By connection type, not by the `adapter:` string — db_sl's spelling of that is not "SQLite".
# T2's statement blocks its OS thread inside the driver while it waits on the lock, so T1 (which must
# commit) and the probe need another thread. With one thread the race deadlocks instead of failing.
const _MF_RUNS = if !(PormG.config[PORMG_DB_FOLDER].connections isa PormG.PormGPostgres)
    @info "Skipping the mutation-fence race tests on SQLite: writers are serialized, so the #765 race cannot occur"
    false
elseif Threads.nthreads() < 2
    @warn "Skipping the mutation-fence race tests: they need at least 2 threads (run db_2 with -t auto)"
    false
else
    true
end

const _MF_DB = PORMG_DB_FOLDER

# Scratch ids far from the fixture's and from every other file's scratch ranges.
const _MF_RESULT_A = 990901   # the fence's original target / the delete target
const _MF_RESULT_B = 990902   # where T1 moves the row to
const _MF_ROW      = 990951   # the Just_a_test_deletion row under contention

"""Clone Result 1 under `result_id`, labelled so a join filter can tell A from B."""
function _mf_seed_result!(result_id::Int, label::String)
    template = M.Result.objects.filter("resultid" => 1).list() |> first
    stale = M.Result.objects.filter("resultid" => result_id)
    stale.exists() && stale.delete()
    M.Result.objects.create(
        "resultid"        => result_id,
        "raceid"          => template[:raceid],
        "driverid"        => template[:driverid],
        "constructorid"   => template[:constructorid],
        "number"          => template[:number],
        "grid"            => template[:grid],
        "position"        => template[:position],
        "positiontext"    => label,
        "positionorder"   => result_id % 1000,
        "points"          => template[:points],
        "laps"            => template[:laps],
        "time"            => template[:time],
        "milliseconds"    => template[:milliseconds],
        "fastestlap"      => template[:fastestlap],
        "rank"            => template[:rank],
        "fastestlaptime"  => template[:fastestlaptime],
        "fastestlapspeed" => template[:fastestlapspeed],
        "statusid"        => template[:statusid],
    )
end

function _mf_cleanup!()
    q = M.Just_a_test_deletion.objects.filter("id" => _MF_ROW)
    q.exists() && q.delete()
    for id in (_MF_RESULT_A, _MF_RESULT_B)
        r = M.Result.objects.filter("resultid" => id)
        r.exists() && r.delete()
    end
    return nothing
end

"""True once another backend is waiting on a lock while running a statement containing `needle`."""
function _mf_lock_wait_seen(needle::String; timeout::Float64 = 30.0)
    settings = PormG.config[_MF_DB]
    deadline = time() + timeout
    while time() < deadline
        rows = DataFrame(PormG.fetch(settings, """
            SELECT count(*) AS n FROM pg_stat_activity
            WHERE datname = current_database() AND pid <> pg_backend_pid()
              AND wait_event_type = 'Lock' AND position(\$1 in query) > 0"""; params = [needle]))
        rows.n[1] > 0 && return true
        sleep(0.05)
    end
    return false
end

"""
Stage the race: `concurrent()` runs in T1's open transaction, `fenced()` runs as T2 while T1 still
holds the row, then T1 commits. Returns `(blocked, result)` — whether T2 was seen waiting on the lock
(the proof the race happened), and what `fenced()` returned.
"""
function _mf_race(concurrent::Function, fenced::Function, needle::String)
    locked  = Channel{Bool}(1)
    release = Channel{Bool}(1)
    holder = Threads.@spawn PormG.atomic(_MF_DB) do
        concurrent()
        put!(locked, true)
        take!(release)
    end
    bind(locked, holder)   # a T1 failure closes the channel instead of hanging the take!

    take!(locked)
    victim = Threads.@spawn fenced()
    blocked = try
        _mf_lock_wait_seen(needle)
    finally
        put!(release, true)
        Base.fetch(holder)
    end
    return blocked, Base.fetch(victim)
end

# `delete()` warns when it removes nothing — the correct outcome here. Keep the log clean.
_mf_quiet(f) = Base.CoreLogging.with_logger(f, Base.CoreLogging.SimpleLogger(IOBuffer(), Base.CoreLogging.Error))

_MF_RUNS && @testset "Mutation fence under concurrent UPDATE (#765)" begin
    try
        _mf_cleanup!()
        _mf_seed_result!(_MF_RESULT_A, "fence-a")
        _mf_seed_result!(_MF_RESULT_B, "fence-b")

        # ── The issue's own shape: a compare-and-delete on the target's columns ───────────────────
        @testset "delete(): a filter on the row itself is re-checked" begin
            M.Just_a_test_deletion.objects.create("id" => _MF_ROW, "name" => "fence-old")

            blocked, (total, _) = _mf_race(
                () -> M.Just_a_test_deletion.objects.filter("id" => _MF_ROW).update("name" => "fence-moved"),
                () -> _mf_quiet(() -> M.Just_a_test_deletion.objects.filter("id" => _MF_ROW, "name" => "fence-old").delete()),
                "DELETE FROM \"just_a_test_deletion\"")

            @test blocked
            @test total == 0
            @test M.Just_a_test_deletion.objects.filter("id" => _MF_ROW, "name" => "fence-moved").count() == 1
            M.Just_a_test_deletion.objects.filter("id" => _MF_ROW).delete()
        end

        # ── A filter that crosses a relation: the joined EXISTS must be re-checked too ────────────
        @testset "delete(): a filter across a join is re-checked" begin
            M.Just_a_test_deletion.objects.create("id" => _MF_ROW, "name" => "fence-join", "test_result" => _MF_RESULT_A)

            blocked, (total, _) = _mf_race(
                () -> M.Just_a_test_deletion.objects.filter("id" => _MF_ROW).update("test_result" => _MF_RESULT_B),
                () -> _mf_quiet(() -> M.Just_a_test_deletion.objects.
                    filter("id" => _MF_ROW, "test_result__positiontext" => "fence-a").delete()),
                "DELETE FROM \"just_a_test_deletion\"")

            @test blocked
            @test total == 0
            @test M.Just_a_test_deletion.objects.filter("id" => _MF_ROW, "test_result" => _MF_RESULT_B).count() == 1
            M.Just_a_test_deletion.objects.filter("id" => _MF_ROW).delete()
        end

        @testset "update(): a filter across a join is re-checked" begin
            M.Just_a_test_deletion.objects.create("id" => _MF_ROW, "name" => "fence-join-upd", "test_result" => _MF_RESULT_A)

            blocked, n = _mf_race(
                () -> M.Just_a_test_deletion.objects.filter("id" => _MF_ROW).update("test_result" => _MF_RESULT_B),
                () -> M.Just_a_test_deletion.objects.
                    filter("id" => _MF_ROW, "test_result__positiontext" => "fence-a").update("name" => "overwritten"),
                "UPDATE \"just_a_test_deletion\"")

            @test blocked
            @test n == 0
            @test M.Just_a_test_deletion.objects.filter("id" => _MF_ROW, "name" => "fence-join-upd").count() == 1
            M.Just_a_test_deletion.objects.filter("id" => _MF_ROW).delete()
        end

        # ── The cascade: a child re-parented mid-delete belongs to its NEW parent ─────────────────
        # Deleting Result A cascades to its Just_a_test_deletion children. T1 moves the child to B. The
        # child's statement must re-check its own foreign key, not the pk list it snapshotted.
        @testset "cascade DELETE: a re-parented child is not deleted" begin
            M.Just_a_test_deletion.objects.create("id" => _MF_ROW, "name" => "fence-child", "test_result" => _MF_RESULT_A)

            blocked, (_, per_table) = _mf_race(
                () -> M.Just_a_test_deletion.objects.filter("id" => _MF_ROW).update("test_result" => _MF_RESULT_B),
                () -> _mf_quiet(() -> M.Result.objects.filter("resultid" => _MF_RESULT_A).delete()),
                "DELETE FROM \"just_a_test_deletion\"")

            @test blocked
            @test get(per_table, "just_a_test_deletion", 0) == 0
            @test M.Just_a_test_deletion.objects.filter("id" => _MF_ROW, "test_result" => _MF_RESULT_B).count() == 1
            @test M.Result.objects.filter("resultid" => _MF_RESULT_A).count() == 0
            M.Just_a_test_deletion.objects.filter("id" => _MF_ROW).delete()
            _mf_seed_result!(_MF_RESULT_A, "fence-a")
        end

        # ── SET_NULL: the collector's UPDATE re-checks the same way ────────────────────────────────
        @testset "cascade SET_NULL: a re-parented child is not nulled" begin
            M.Just_a_test_deletion.objects.create("id" => _MF_ROW, "name" => "fence-setnull", "test_result_set_null" => _MF_RESULT_A)

            blocked, _ = _mf_race(
                () -> M.Just_a_test_deletion.objects.filter("id" => _MF_ROW).update("test_result_set_null" => _MF_RESULT_B),
                () -> _mf_quiet(() -> M.Result.objects.filter("resultid" => _MF_RESULT_A).delete()),
                "UPDATE \"just_a_test_deletion\"")

            @test blocked
            @test M.Just_a_test_deletion.objects.filter("id" => _MF_ROW, "test_result_set_null" => _MF_RESULT_B).count() == 1
            M.Just_a_test_deletion.objects.filter("id" => _MF_ROW).delete()
        end
    finally
        _mf_cleanup!()
    end
end
