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

# #770's cascade-order cases: a Circuit → Race → Result chain of its own, so deleting it cannot touch
# the fixture. The race is the parent that changes mid-delete; the result is the child that must
# survive it.
const _MF_CIRCUIT_A = 990961   # the circuit the race starts on (and the one #770 (b) deletes)
const _MF_CIRCUIT_B = 990962   # where T1 moves the race to
const _MF_RACE      = 990971
const _MF_RACE_NAME = "Fence Cancelled Grand Prix"
const _MF_RACE_KID  = 990981   # the race's only Result

"""
Clone Result 1 under `result_id`, labelled so a join filter can tell A from B. `raceid` hangs it off
another race (the #770 chain) instead of the template's.
"""
function _mf_seed_result!(result_id::Int, label::String; raceid::Union{Nothing, Int} = nothing)
    template = M.Result.objects.filter("resultid" => 1).list() |> first
    stale = M.Result.objects.filter("resultid" => result_id)
    stale.exists() && stale.delete()
    M.Result.objects.create(
        "resultid"        => result_id,
        "raceid"          => something(raceid, template[:raceid]),
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
    _mf_cleanup_chain!()
    return nothing
end

"""Remove the #770 chain, root first: each delete cascades to whatever of the chain is left below it."""
function _mf_cleanup_chain!()
    for id in (_MF_CIRCUIT_A, _MF_CIRCUIT_B)
        c = M.Circuit.objects.filter("circuitid" => id)
        c.exists() && c.delete()
    end
    return nothing
end

"""
Seed the #770 chain: circuits A and B, the race on A, and one result on the race. Clears any chain a
previous testset left behind first — an ERROR inside one (a rethrow from `_mf_race`) skips its own
trailing cleanup, and the next seed would otherwise die on a duplicate key.
"""
function _mf_seed_chain!()
    _mf_cleanup_chain!()
    for (id, ref) in ((_MF_CIRCUIT_A, "fence_a"), (_MF_CIRCUIT_B, "fence_b"))
        M.Circuit.objects.create("circuitid" => id, "circuitref" => ref, "name" => "Fence Circuit $(ref)",
            "location" => "Nowhere", "country" => "Nowhere", "lat" => 0.0, "lng" => 0.0, "alt" => 0,
            "url" => "https://example.invalid/$(ref)")
    end
    M.Race.objects.create("raceid" => _MF_RACE, "year" => 1901, "round" => 1, "circuitid" => _MF_CIRCUIT_A,
        "name" => _MF_RACE_NAME, "date" => Date(1901, 1, 1), "url" => "https://example.invalid/race")
    _mf_seed_result!(_MF_RACE_KID, "fence-kid"; raceid = _MF_RACE)
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

        # ── #770: the cascade's ORDER. Children go before their parent, so a parent that stops ──
        # matching mid-delete must be locked before any child statement reads it — or its children
        # are already gone by the time its own (fenced) DELETE correctly skips it.
        #
        # Both needles match the lock statement (`FROM "race" AS "Tb" … FOR UPDATE`) and, on the
        # unfixed code, the race DELETE — whichever of the two is the one left waiting on T1.
        @testset "cascade order: a root that stops matching keeps its children (#770)" begin
            _mf_seed_chain!()

            blocked, (total, _) = _mf_race(
                () -> M.Race.objects.filter("raceid" => _MF_RACE).update("name" => "Fence Rescheduled Grand Prix"),
                () -> _mf_quiet(() -> M.Race.objects.filter("raceid" => _MF_RACE, "name" => _MF_RACE_NAME).delete()),
                "FROM \"race\" AS \"Tb\"")

            @test blocked
            @test total == 0
            @test M.Race.objects.filter("raceid" => _MF_RACE, "name" => "Fence Rescheduled Grand Prix").count() == 1
            @test M.Result.objects.filter("resultid" => _MF_RACE_KID).count() == 1
            _mf_cleanup_chain!()
        end

        @testset "cascade order: a mid-level parent moved away keeps its children (#770)" begin
            _mf_seed_chain!()

            blocked, (_, per_table) = _mf_race(
                () -> M.Race.objects.filter("raceid" => _MF_RACE).update("circuitid" => _MF_CIRCUIT_B),
                () -> _mf_quiet(() -> M.Circuit.objects.filter("circuitid" => _MF_CIRCUIT_A).delete()),
                "FROM \"race\" AS \"Tb\"")

            @test blocked
            @test get(per_table, "circuit", 0) == 1
            @test get(per_table, "result", 0) == 0
            @test M.Race.objects.filter("raceid" => _MF_RACE, "circuitid" => _MF_CIRCUIT_B).count() == 1
            @test M.Result.objects.filter("resultid" => _MF_RACE_KID).count() == 1
            _mf_cleanup_chain!()
        end

        # ── #771: a root filter across a relation — the table it reads is locked too ──────────────
        # The root filter crosses into `circuit`. T1 renames the circuit and also holds the race's
        # result row. T2's lock on the race succeeds (T1 holds no race lock). Before #771, T2 then
        # waited on the result: after T1 committed, the result's re-check reused the joined race row
        # and deleted it, and the race's own fenced DELETE re-read `circuit`, no longer matched, and
        # survived without its result (measured on db_2 while #770 was reviewed). Now T2 waits on its
        # `FOR SHARE` lock of the circuit instead, and every statement after it reads the renamed
        # circuit: nothing matches, nothing is deleted.
        #
        # The needle matches both waits — the #771 lock's inner join and the pre-#771 result DELETE's
        # nested one — so the unfixed code fails on the row counts below, not on `blocked`.
        @testset "cascade order: a joined root filter is pinned (#771)" begin
            _mf_seed_chain!()

            blocked, (total, per_table) = _mf_race(
                () -> begin
                    M.Circuit.objects.filter("circuitid" => _MF_CIRCUIT_A).update("name" => "Fence Circuit renamed")
                    M.Result.objects.filter("resultid" => _MF_RACE_KID).update("positiontext" => "held")
                end,
                () -> _mf_quiet(() -> M.Race.objects.
                    filter("raceid" => _MF_RACE, "circuitid__name" => "Fence Circuit fence_a").delete()),
                "JOIN \"circuit\"")

            @test blocked
            @test total == 0
            @test get(per_table, "race", 0) == 0
            @test get(per_table, "result", 0) == 0
            @test M.Race.objects.filter("raceid" => _MF_RACE).count() == 1
            @test M.Result.objects.filter("resultid" => _MF_RACE_KID).count() == 1
            _mf_cleanup_chain!()
        end
    finally
        _mf_cleanup!()
    end
end

# ── #771 without a race: the related-row locks are valid PostgreSQL and change no outcome ──────────
# The race above proves the hop locks pin; this proves they RUN, on the two shapes a mock connection
# cannot vouch for: a two-hop root (result → race → circuit) that cascades, and a null test across a
# LEFT JOIN. The rows written must be exactly the ones a lock-free delete writes. PostgreSQL only
# (SQLite takes no lock), but no second thread is needed, so it is gated apart from the race.
const _MF_IS_PG = PormG.config[PORMG_DB_FOLDER].connections isa PormG.PormGPostgres

_MF_IS_PG && @testset "joined-root locks execute on PostgreSQL (#771)" begin
    try
        _mf_cleanup!()
        _mf_seed_chain!()
        M.Just_a_test_deletion.objects.create("id" => _MF_ROW, "name" => "fence-lock-probe", "test_result" => _MF_RACE_KID)
        two_hops() = M.Result.objects.filter("resultid" => _MF_RACE_KID, "raceid__circuitid__name" => "Fence Circuit fence_a")

        @testset "two hops: the root's own lock, then one FOR SHARE per hop, in chain order" begin
            steps = two_hops().delete(show_query = :dict)
            locks = [s for s in steps if s[:operation] == :lock]
            @test [s[:model] for s in locks] == ["result", "race", "circuit"]
            @test all(occursin("FOR SHARE", s[:sql_text]) for s in locks[2:3])

            total, per_table = two_hops().delete()
            @test total == 2
            @test per_table == Dict("result" => 1, "just_a_test_deletion" => 1)
            @test M.Race.objects.filter("raceid" => _MF_RACE).count() == 1
            @test M.Circuit.objects.filter("circuitid" => _MF_CIRCUIT_A).count() == 1
        end

        # `test_result` is a NULLABLE key, so this hop is a LEFT JOIN — the side PostgreSQL refuses to
        # lock directly — and the row has no result at all, so the lock's IN set is the null-extended
        # {NULL}: it must run, lock nothing, and leave the anti-join matching the row.
        @testset "a null test across a LEFT JOIN" begin
            M.Just_a_test_deletion.objects.create("id" => _MF_ROW, "name" => "fence-left-join")
            M.Just_a_nested_roll_back.objects.create("test" => _MF_ROW, "description" => "fence-left-join-child")
            left_join() = M.Just_a_test_deletion.objects.
                filter("id" => _MF_ROW, "test_result__positiontext__@isnull" => true)

            locks = [s for s in left_join().delete(show_query = :dict) if s[:operation] == :lock]
            @test [s[:model] for s in locks] == ["just_a_test_deletion", "result"]
            @test occursin("LEFT JOIN \"result\"", locks[2][:sql_text])

            total, per_table = left_join().delete()
            @test per_table == Dict("just_a_test_deletion" => 1, "just_a_nested_roll_back" => 1)
        end
    finally
        _mf_cleanup!()
    end
end
