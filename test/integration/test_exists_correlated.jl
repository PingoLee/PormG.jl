# julia -t auto  --project=. test/integration/test_exists_correlated.jl

if !isdefined(Main, :PormG)
    include("common_setup.jl")
end

import PormG.QueryBuilder: Exists, OuterRef

# ─────────────────────────────────────────────────────────────────────────────
# Correlated EXISTS – basic round-trip
#
# A Result row should match the Exists filter iff the driver recorded at least
# one Lap_time for that same race under the given threshold.
# ─────────────────────────────────────────────────────────────────────────────
@testset "Correlated EXISTS - basic Lap_times filter" begin
    threshold = 90_000  # ms — broad enough to return rows

    # ── Exists approach ──────────────────────────────────────────────────────
    lap_sub = M.Lap_times.objects.filter(
        "raceid"           => OuterRef("raceid"),
        "driverid"         => OuterRef("driverid"),
        "milliseconds__@lte" => threshold,
    )
    exists_q = M.Result.objects.filter(Exists(lap_sub))
    # insp = exists_q |> inspect_query
    # insp[:sql_text] |> println
    # SELECT
    #     *
    # FROM "result" as "Tb"
    # WHERE EXISTS (SELECT 1
    # FROM "lap_times" as "R1"
    # WHERE "R1"."raceid" = "Tb"."raceid" AND 
    # "R1"."driverid" = "Tb"."driverid" AND 
    # "R1"."milliseconds" <= $1
    # LIMIT 1)
    exists_count = exists_q.count()

    @test exists_count == 5866
    # exists() must be consistent with count() > 0
    @test exists_q.exists()
end

# ─────────────────────────────────────────────────────────────────────────────
# Correlated EXISTS with an impossible condition returns zero rows
# ─────────────────────────────────────────────────────────────────────────────
@testset "Correlated EXISTS - impossible condition yields no rows" begin
    lap_sub = M.Lap_times.objects.filter(
        "raceid"             => OuterRef("raceid"),
        "milliseconds__@lte" => -1,   # impossible: all times > 0
    )
    q = M.Result.objects.filter(Exists(lap_sub))
    @test q.count() == 0
    @test !q.exists()
end

# ─────────────────────────────────────────────────────────────────────────────
# Correlated EXISTS with additional filters on the outer query
# The Exists predicate narrows results; extra outer filters narrow further.
# ─────────────────────────────────────────────────────────────────────────────
@testset "Correlated EXISTS - combined with outer filter" begin
    threshold = 90_000

    lap_sub = M.Lap_times.objects.filter(
        "raceid"             => OuterRef("raceid"),
        "driverid"           => OuterRef("driverid"),
        "milliseconds__@lte" => threshold,
    )
    # All results with a fast lap
    all_fast = M.Result.objects.filter(Exists(lap_sub))
    # Restrict further to driver 1
    filtered = M.Result.objects.filter(Exists(lap_sub), "driverid" => 1)

    all_count      = all_fast.count()
    filtered_count = filtered.count()

    # Cross-check: driver 1's total results is an upper bound on the EXISTS+driverid count
    driver1_total = M.Result.objects.filter("driverid" => 1).count()
    @test filtered_count <= driver1_total
    # The EXISTS predicate is active: filtered must be a subset of all_fast
    @test filtered_count <= all_count
    # driver 1 data is present in F1 dataset
    @test filtered_count > 0
end

# ─────────────────────────────────────────────────────────────────────────────
# Correlated EXISTS with OuterRef("pk") auto-resolution
# The F1 Result model has resultid as primary key.
# ─────────────────────────────────────────────────────────────────────────────
@testset "Correlated EXISTS - OuterRef pk resolves to primary key" begin
    # Just_a_test_deletion.test_result is a FK back to Result.
    # An EXISTS over test_deletion correlated via OuterRef("pk") should find
    # results that have at least one linked test_deletion row.
    # (In the live F1 dataset, test_deletion rows may not exist; we only verify
    # the query executes without error and returns a sane count.)
    del_sub = M.Just_a_test_deletion.objects.filter(
        "test_result" => OuterRef("pk"),
    )
    q = M.Result.objects.filter(Exists(del_sub))
    # May be 0 if no test_deletion rows exist, but must not error.
    # FK linkage means matched rows can never exceed total results.
    # insp = q |> inspect_query
    # insp[:sql_text] |> println
     # SELECT
     #     *
     # FROM "result" as "Tb"
     # WHERE EXISTS (SELECT 1
     # FROM "just_a_test_deletion" as "R1"
     # WHERE "R1"."test_result" = "Tb"."resultid"
     # LIMIT 1)
    count = q.count()
    total = M.Result.objects.count()
    @test count >= 0
    @test count <= total
end

# ─────────────────────────────────────────────────────────────────────────────
# Qor(Exists, Exists) — OR of two correlated subqueries
# The union count must be ≥ each individual count (union bound from below) and
# ≤ total results (natural upper bound).
# ─────────────────────────────────────────────────────────────────────────────
@testset "Correlated EXISTS - Qor OR of two EXISTS predicates" begin
    fast_lap_sub = M.Lap_times.objects.filter(
        "raceid"             => OuterRef("raceid"),
        "driverid"           => OuterRef("driverid"),
        "milliseconds__@lte" => 80_000,
    )
    pit_sub = M.Pit_stops.objects.filter(
        "raceid"             => OuterRef("raceid"),
        "driverid"           => OuterRef("driverid"),
        "milliseconds__@lte" => 25_000,
    )

    count_fast = M.Result.objects.filter(Exists(fast_lap_sub)).count()
    count_pit  = M.Result.objects.filter(Exists(pit_sub)).count()
    count_or   = M.Result.objects.filter(Qor(Exists(fast_lap_sub), Exists(pit_sub))).count()

    # insp_fast = M.Result.objects.filter(Exists(fast_lap_sub)) |> inspect_query
    # insp_fast[:sql_text] |> println
    # SELECT
    #     *
    # FROM "result" as "Tb"
    # WHERE EXISTS (SELECT 1
    # FROM "lap_times" as "R1"
    # WHERE "R1"."raceid" = "Tb"."raceid" AND 
    # "R1"."driverid" = "Tb"."driverid" AND 
    # "R1"."milliseconds" <= $1
    # LIMIT 1)


    # insp_pit = M.Result.objects.filter(Exists(pit_sub)) |> inspect_query
    # insp_pit[:sql_text]  |> println
    # SELECT
    #     *
    # FROM "result" as "Tb"
    # WHERE EXISTS (SELECT 1
    # FROM "pit_stops" as "R1"
    # WHERE "R1"."raceid" = "Tb"."raceid" AND 
    # "R1"."driverid" = "Tb"."driverid" AND 
    # "R1"."milliseconds" <= $1
    # LIMIT 1)


    # insp_or = M.Result.objects.filter(Qor(Exists(fast_lap_sub), Exists(pit_sub))) |> inspect_query
    # insp_or[:sql_text]   |> println
    # SELECT
    #     *
    # FROM "result" as "Tb"
    # WHERE (EXISTS (SELECT 1
    # FROM "lap_times" as "R1"
    # WHERE "R1"."raceid" = "Tb"."raceid" AND 
    # "R1"."driverid" = "Tb"."driverid" AND 
    # "R1"."milliseconds" <= $1
    # LIMIT 1) OR EXISTS (SELECT 1
    # FROM "pit_stops" as "R2"
    # WHERE "R2"."raceid" = "Tb"."raceid" AND 
    # "R2"."driverid" = "Tb"."driverid" AND 
    # "R2"."milliseconds" <= $2
    # LIMIT 1))

    # OR result is at least as large as either individual predicate
    @test count_or >= count_fast
    @test count_or >= count_pit

    # OR result is at most as large as total results
    total = M.Result.objects.count()
    @test count_or <= total
end

# ─────────────────────────────────────────────────────────────────────────────
# Correlated EXISTS – Pit_stops variant (different child model, same pattern)
# ─────────────────────────────────────────────────────────────────────────────
@testset "Correlated EXISTS - Pit_stops subquery" begin
    pit_sub = M.Pit_stops.objects.filter(
        "raceid"             => OuterRef("raceid"),
        "driverid"           => OuterRef("driverid"),
    )
    # Results where the driver pitted in the same race
    q = M.Result.objects.filter(Exists(pit_sub))
    count = q.count()

    @test count > 0
    # Every driver who pitted should have a result; pit count can't exceed results
    total = M.Result.objects.count()
    @test count <= total
end

# ─────────────────────────────────────────────────────────────────────────────
# Result immutability: applying Exists filter to the same subquery object twice
# should not mutate or corrupt the subquery.
# ─────────────────────────────────────────────────────────────────────────────
@testset "Correlated EXISTS - subquery immutability across two usages" begin
    lap_sub = M.Lap_times.objects.filter(
        "raceid"             => OuterRef("raceid"),
        "driverid"           => OuterRef("driverid"),
        "milliseconds__@lte" => 90_000,
    )

    q1 = M.Result.objects.filter(Exists(lap_sub))
    q2 = M.Result.objects.filter(Exists(lap_sub), "driverid" => 2)

    # inspect queries for debugging if needed
    # insp1 = q1 |> inspect_query
    # insp2 = q2 |> inspect_query
    # insp1[:sql_text] |> println
    # SELECT
    #     *
    # FROM "result" as "Tb"
    # WHERE EXISTS (SELECT 1
    # FROM "lap_times" as "R1"
    # WHERE "R1"."raceid" = "Tb"."raceid" AND 
    # "R1"."driverid" = "Tb"."driverid" AND 
    # "R1"."milliseconds" <= $1
    # LIMIT 1)
    # insp2[:sql_text] |> println
    # SELECT
    #     *
    # FROM "result" as "Tb"
    # WHERE EXISTS (SELECT 1
    # FROM "lap_times" as "R1"
    # WHERE "R1"."raceid" = "Tb"."raceid" AND 
    # "R1"."driverid" = "Tb"."driverid" AND 
    # "R1"."milliseconds" <= $1
    # LIMIT 1) AND 
    # "Tb"."driverid" = $2


    count1 = q1.count()
    count2 = q2.count()

    # Running q2 must not corrupt q1's count
    @test q1.count() == count1
    @test count2 <= count1
end


# ─────────────────────────────────────────────────────────────────────────────
# A nested render binds its values in TEXT order, against real rows (#432)
#
# The unit file pins the parameter vector; this pins the ROWS, which is the only thing that proves a
# misbind mattered. A positional mix-up produces perfectly valid SQL — the driver is happy, nothing
# raises, and the query just answers a different question. Only comparing the returned set against
# an independently computed one catches that.
#
# The shape needs three things at once, and dropping any one makes it pass against the bug:
#   1. a value bound in the OUTER query whose text PRECEDES the nested render (`statusid`),
#   2. a nested `Exists` whose inner query binds a value in a JOIN ON clause (`year`),
#   3. and another in the inner WHERE (`milliseconds`).
# Before the fix SQLite flattened `:join` ahead of `:where`, so `year`'s value bound to `statusid`'s
# marker and the query silently selected on the wrong columns.
#
# The cjoin is INNER on purpose. Under the default LEFT JOIN the ON predicate does not filter — a
# non-matching row still satisfies `EXISTS` — so the year value would have no effect on the result
# and this testset would pass whatever it bound to. Measured: 3218 rows LEFT, 121 rows INNER.
#
# `PORMG_DB=db_sl` is where this can fail; on PostgreSQL `$N` travels with the text, so there the
# same assertions are a control rather than a regression.
# ─────────────────────────────────────────────────────────────────────────────
@testset "nested Exists binds in text order against real rows (#432)" begin
    threshold = 95_000   # ms — broad enough to select a real, non-empty set
    year      = 2009
    finished  = 1        # statusid 1 == "Finished" in the F1 fixture

    inner = M.Lap_times.objects
    inner.values("raceid")
    inner.filter("raceid" => OuterRef("raceid"), "driverid" => OuterRef("driverid"))
    inner.cjoin("raceid" => "Race", filters = ["year" => year], join_type = "INNER", warn = false)
    inner.filter("milliseconds__@lt" => threshold)

    q = M.Result.objects
    q.filter("statusid" => finished)      # MUST be declared before the nesting — see above
    q.filter(Exists(inner))
    q.values("resultid")

    got = Set((q |> DataFrame).resultid)

    # Independently computed expectation: two plain queries, no nesting, so it cannot share the
    # defect under test. A Result row qualifies iff it is Finished AND that driver set a sub-95s lap
    # in that race AND the race was in `year`.
    fast = M.Lap_times.objects
    fast.filter("milliseconds__@lt" => threshold, "raceid__year" => year)
    fast.values("raceid", "driverid")
    pairs = Set((r.raceid, r.driverid) for r in eachrow(fast |> DataFrame))

    finished_rows = M.Result.objects
    finished_rows.filter("statusid" => finished)
    finished_rows.values("resultid", "raceid", "driverid")
    expected = Set(r.resultid for r in eachrow(finished_rows |> DataFrame)
                   if (r.raceid, r.driverid) in pairs)

    # Non-emptiness is a premise, not decoration: an empty set makes the comparison vacuous and this
    # testset would pass against the bug it exists to catch.
    @test !isempty(expected)
    @test got == expected
end
