# julia -t auto  --project=. test/integration/test_subqueries.jl

if !isdefined(Main, :PormG)
    include("common_setup.jl")
end


# ─────────────────────────────────────────────────────────────────────────────
# Subqueries
# A sub-SELECT used as the right-hand side of a field__@in filter.
# ─────────────────────────────────────────────────────────────────────────────
@testset "Subqueries test" begin
    subquery = M.Status.objects
    subquery.filter("status" => "Engine")
    subquery.values("statusid")

    # The subquery narrows results to only "Engine"-status results
    query = M.Result.objects
    query.filter("statusid__@in" => subquery)
    query.values("resultid", "statusid", "statusid__status", "grid", "driverid")
    df = query |> DataFrame
    @test query.count() == 2026

    # A second filter added after the subquery is already attached
    query.filter("driverid__@lte" => 7)
    @test query.count() == 40

    # Deep joins and aggregated date expressions coexist with the subquery
    query.values("resultid", "statusid", "statusid__status", "grid", "driverid", "raceid__date__@quarter")
    query.order_by("raceid__date__quarter")
    text = query |> inspect_query
    df = query |> DataFrame
    @test query.count() == 40
    @test query.exists()
end

# ─────────────────────────────────────────────────────────────────────────────
# Subqueries: missing projection should fail before database execution
# A field__@in subquery must project exactly one key. Forgetting .values(...)
# used to leak a raw SQL backend error; now it should raise a clear fix-oriented
# ArgumentError at the PormG boundary.
# ─────────────────────────────────────────────────────────────────────────────
@testset "Subqueries require a single projected field for IN filters" begin
    subquery = M.Status.objects
    subquery.filter("status" => "Engine")

    query = M.Result.objects
    query.filter("statusid__@in" => subquery)

    err = try
        query |> DataFrame
        nothing
    catch e
        e
    end

    @test err isa ArgumentError

    message = sprint(showerror, err)
    @test occursin("'statusid__@in' requires a subquery that returns exactly one column", message)
    @test occursin("selects all columns from 'status' because .values(...) was not called", message)
    @test occursin("call .values(\"field_name\") on the subquery", message)
end

# ─────────────────────────────────────────────────────────────────────────────
# Subqueries: a single SQL-function projection is still a valid IN subquery
# The validator should accept a one-column aggregate subquery and let the query
# execute end to end instead of crashing while inspecting the projection type.
# ─────────────────────────────────────────────────────────────────────────────
@testset "Subqueries accept single SQL-function projections" begin
    max_id_subquery = M.Result.objects
    max_id_subquery.values("max_resultid" => Max("resultid"))

    expected_max = maximum((M.Result.objects.values("resultid") |> DataFrame).resultid)

    query = M.Result.objects
    query.filter("resultid__@in" => max_id_subquery)
    rows = query.values("resultid").list()

    @test length(rows) == 1
    @test rows[1][:resultid] == expected_max
end

# ═════════════════════════════════════════════════════════════════════════════
# Scalar correlated subqueries (#92): "alias" => Subquery(inner) projected in
# values(), correlated with OuterRef — the supported fix the #74 fan-out guard
# points users to. Subquery/Exists/OuterRef are used through the top-level
# `using PormG` exports (from common_setup) — deliberately, to pin the public
# surface. Every aggregate value below is recomputed independently and asserted
# for equality — a query that executes can still be wrong.
# ═════════════════════════════════════════════════════════════════════════════

# ─────────────────────────────────────────────────────────────────────────────
# Subquery (#92): the fan-out proof — the before/after that motivates #92.
# The naive reverse-FK join aggregate is refused by the #74 guard (cause-checked);
# the same question asked through a correlated Subquery returns the exact
# per-driver value because the aggregate runs in its own scalar subquery and the
# outer Driver rows are never row-multiplied.
# ─────────────────────────────────────────────────────────────────────────────
@testset "Subquery (#92) - fan-out proof: naive join raises, Subquery is exact" begin
    # Naive form: COUNT over a base column under a to-many join → #74 guard raises.
    naive = M.Driver.objects
    naive.values("surname", "n" => Count("driverid"))
    naive.filter("driver_standings__position__@gte" => 1)
    err = try; naive |> DataFrame; nothing; catch e; e; end
    @test err isa ArgumentError && occursin("fan-out", err.msg)

    # #92 form: the aggregate moves into a correlated scalar subquery.
    standings = M.Driver_standings.objects
    standings.filter("driverid" => OuterRef("driverid"))
    standings.values("t" => Count("driverstandingsid"))

    q = M.Driver.objects.
        filter("driverid" => 1).
        values("surname", "n_standings" => Subquery(standings))
    df = q |> DataFrame

    # Independent recomputation — the fan-out factor must be real (>1 related row).
    expected = M.Driver_standings.objects.filter("driverid" => 1).count()
    @test expected > 1
    @test nrow(df) == 1
    @test df[1, :n_standings] == expected
end

# ─────────────────────────────────────────────────────────────────────────────
# Subquery (#92): reverse-FK per-row correctness across multiple outer rows.
# Each driver's scalar must equal an independently computed count() — the
# correlation binds per outer row, not once per query.
# ─────────────────────────────────────────────────────────────────────────────
@testset "Subquery (#92) - reverse FK counts are exact per outer row" begin
    standings = M.Driver_standings.objects
    standings.filter("driverid" => OuterRef("driverid"))
    standings.values("t" => Count("driverstandingsid"))

    df = M.Driver.objects.
        filter("driverid__@lte" => 5).
        values("driverid", "n_standings" => Subquery(standings)) |> DataFrame

    @test nrow(df) == 5
    for row in eachrow(df)
        # Independent per-driver recomputation through the manager.
        indep = M.Driver_standings.objects.filter("driverid" => row.driverid).count()
        @test row.n_standings == indep
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# Subquery (#92): multiple independent aggregates in ONE query — the key
# ergonomic win over a CTE join. Two correlated subqueries over two different
# to-many relations must each stay exact, with no fan-out interaction (this is
# precisely the case where a naive double join multiplies both counts).
# ─────────────────────────────────────────────────────────────────────────────
@testset "Subquery (#92) - multiple independent aggregates in one query" begin
    standings = M.Driver_standings.objects
    standings.filter("driverid" => OuterRef("driverid"))
    standings.values("t" => Count("driverstandingsid"))

    # Lap_times, NOT Result: standings and results are both one-per-race, so their
    # counts are structurally EQUAL for every driver — a bug projecting the same
    # subquery into both columns would pass undetected. Lap counts differ by orders
    # of magnitude, so the two expected values discriminate.
    laps = M.Lap_times.objects
    laps.filter("driverid" => OuterRef("driverid"))
    laps.values("t" => Count("lap"))

    df = M.Driver.objects.
        filter("driverid" => 1).
        values("surname",
               "n_standings" => Subquery(standings),
               "n_laps"      => Subquery(laps)) |> DataFrame

    exp_standings = M.Driver_standings.objects.filter("driverid" => 1).count()
    exp_laps      = M.Lap_times.objects.filter("driverid" => 1).count()
    # Both relations must have >1 row, or the no-interaction claim is vacuous —
    # and the two expected values must DIFFER, or a same-subquery-twice bug hides.
    @test exp_standings > 1 && exp_laps > 1
    @test exp_standings != exp_laps
    @test nrow(df) == 1
    @test df[1, :n_standings] == exp_standings   # NOT n_standings × n_laps
    @test df[1, :n_laps]      == exp_laps
end

# ─────────────────────────────────────────────────────────────────────────────
# Subquery (#92): latest-value (non-aggregate) scalar — the inner query's own
# ORDER BY + LIMIT 1 select a single related value per outer row ("the driver's
# most recent standings position"). An aggregate is not required; the one-column
# rule is the only structural constraint.
# ─────────────────────────────────────────────────────────────────────────────
@testset "Subquery (#92) - latest-value non-aggregate scalar" begin
    latest = M.Driver_standings.objects
    latest.filter("driverid" => OuterRef("driverid"))
    latest.values("position")
    latest.order_by("-driverstandingsid")
    latest.limit(1)

    df = M.Driver.objects.
        filter("driverid" => 1).
        values("latest_position" => Subquery(latest)) |> DataFrame

    # Independent recomputation: same ordering, directly against the related table.
    indep = M.Driver_standings.objects.
        filter("driverid" => 1).
        order_by("-driverstandingsid").
        limit(1).
        values("position") |> DataFrame

    @test nrow(df) == 1 && nrow(indep) == 1
    @test df[1, :latest_position] == indep[1, :position]
end

# ─────────────────────────────────────────────────────────────────────────────
# Subquery (#92): empty related set — a COUNT scalar must be 0 (COUNT of an
# empty set), while a non-aggregate scalar must be missing (SQL NULL). The F1
# dataset contains drivers with no driver_standings rows; find one dynamically
# so reseeding can't break the fixture.
# ─────────────────────────────────────────────────────────────────────────────
@testset "Subquery (#92) - empty related set: Count is 0, plain scalar is missing" begin
    with_standings = Set((M.Driver_standings.objects.values("driverid") |> DataFrame).driverid)
    all_ids = (M.Driver.objects.values("driverid") |> DataFrame).driverid
    lonely = [id for id in all_ids if !(id in with_standings)]
    @test !isempty(lonely)              # dataset invariant: some drivers never scored standings
    lonely_id = minimum(lonely)

    count_sub = M.Driver_standings.objects
    count_sub.filter("driverid" => OuterRef("driverid"))
    count_sub.values("t" => Count("driverstandingsid"))

    latest_sub = M.Driver_standings.objects
    latest_sub.filter("driverid" => OuterRef("driverid"))
    latest_sub.values("position")
    latest_sub.order_by("-driverstandingsid")
    latest_sub.limit(1)

    df = M.Driver.objects.
        filter("driverid" => lonely_id).
        values("n_standings"     => Subquery(count_sub),
               "latest_position" => Subquery(latest_sub)) |> DataFrame

    @test nrow(df) == 1
    @test df[1, :n_standings] == 0             # COUNT over the empty set
    @test ismissing(df[1, :latest_position])   # scalar over the empty set is NULL
end

# ─────────────────────────────────────────────────────────────────────────────
# Exists-as-column (#92): Exists(...) projected in values() returns a boolean
# per outer row (SQLite renders 0/1 integers, PostgreSQL booleans — normalize
# via Bool()). Cross-checked against a driver with and a driver without
# related rows.
# ─────────────────────────────────────────────────────────────────────────────
@testset "Exists projection (#92) - boolean column per outer row" begin
    standings = M.Driver_standings.objects
    standings.filter("driverid" => OuterRef("driverid"))
    standings.values("t" => Count("driverstandingsid"))

    # A driver with standings (1 = Hamilton) → true.
    df_has = M.Driver.objects.
        filter("driverid" => 1).
        values("has_standings" => Exists(standings)) |> DataFrame
    @test Bool(df_has[1, :has_standings]) == true

    # A driver without standings → false (found dynamically, as above).
    with_standings = Set((M.Driver_standings.objects.values("driverid") |> DataFrame).driverid)
    all_ids = (M.Driver.objects.values("driverid") |> DataFrame).driverid
    lonely_id = minimum([id for id in all_ids if !(id in with_standings)])
    df_not = M.Driver.objects.
        filter("driverid" => lonely_id).
        values("has_standings" => Exists(standings)) |> DataFrame
    @test Bool(df_not[1, :has_standings]) == false
end

# ─────────────────────────────────────────────────────────────────────────────
# Subquery (#92): M2M through-table counts. The naive M2M-join aggregate raises
# the #74 guard; counting the explicit through model's rows in a correlated
# Subquery returns the exact per-driver team count. Self-seeded scratch rows
# (explicit through: M2m_link_plain_scratch) with idempotent cleanup.
# ─────────────────────────────────────────────────────────────────────────────
@testset "Subquery (#92) - M2M through-table count" begin
    slug = "subq92"

    # Idempotent cleanup of any prior run (links first: FK references).
    for d in M.M2m_driver_plain_scratch.objects.filter("driverref__@contains" => slug).list()
        M.M2m_link_plain_scratch.objects.filter("driver" => d[:id]).delete()
    end
    M.M2m_driver_plain_scratch.objects.filter("driverref__@contains" => slug).delete()
    M.M2m_team_plain_scratch.objects.filter("name__@contains" => slug).delete()

    # Seed: one driver on TWO teams (fan-out factor > 1), one teamless control driver.
    driver   = M.M2m_driver_plain_scratch.objects.create("driverref" => "$(slug)-senna")
    loner    = M.M2m_driver_plain_scratch.objects.create("driverref" => "$(slug)-lone")
    team_a   = M.M2m_team_plain_scratch.objects.create("name" => "$(slug)-mclaren")
    team_b   = M.M2m_team_plain_scratch.objects.create("name" => "$(slug)-lotus")
    M.M2m_link_plain_scratch.objects.create("driver" => driver[:id], "team" => team_a[:id])
    M.M2m_link_plain_scratch.objects.create("driver" => driver[:id], "team" => team_b[:id])

    # Naive form: base-column COUNT under the M2M join → #74 guard raises.
    naive = M.M2m_driver_plain_scratch.objects
    naive.values("driverref", "n" => Count("id"))
    naive.filter("teams__name__@contains" => slug)
    err = try; naive |> DataFrame; nothing; catch e; e; end
    @test err isa ArgumentError && occursin("fan-out", err.msg)

    # #92 form: count the through-table rows in a correlated scalar subquery.
    links = M.M2m_link_plain_scratch.objects
    links.filter("driver" => OuterRef("id"))
    links.values("t" => Count("id"))

    df = M.M2m_driver_plain_scratch.objects.
        filter("driverref__@contains" => slug).
        values("driverref", "n_teams" => Subquery(links)) |> DataFrame

    @test nrow(df) == 2
    by_ref = Dict(row.driverref => row.n_teams for row in eachrow(df))
    @test by_ref["$(slug)-senna"] == 2   # exact — not inflated by any other relation
    @test by_ref["$(slug)-lone"]  == 0   # COUNT over the empty set

    # Teardown (links first: FK references).
    M.M2m_link_plain_scratch.objects.filter("driver" => driver[:id]).delete()
    M.M2m_driver_plain_scratch.objects.filter("driverref__@contains" => slug).delete()
    M.M2m_team_plain_scratch.objects.filter("name__@contains" => slug).delete()
end

# ─────────────────────────────────────────────────────────────────────────────
# Subquery (#92): reuse-safety. query() renders an internal deepcopy of the
# wrapped handler, so the SAME Subquery object projected in two different outer
# queries — and a count() then list() on one of them — yields correct,
# uncorrupted results (mirrors the Exists "immutability across two usages" test).
# ─────────────────────────────────────────────────────────────────────────────
@testset "Subquery (#92) - reuse across outer queries and terminals" begin
    standings = M.Driver_standings.objects
    standings.filter("driverid" => OuterRef("driverid"))
    standings.values("t" => Count("driverstandingsid"))
    shared = Subquery(standings)

    q1 = M.Driver.objects.
        filter("driverid" => 1).
        values("n_standings" => shared)
    first_val = (q1 |> DataFrame)[1, :n_standings]
    @test first_val == M.Driver_standings.objects.filter("driverid" => 1).count()

    # count() clears values internally (COUNT(*) of the outer rows) — it must not
    # corrupt the shared Subquery for later renders.
    @test q1.count() == 1
    @test (q1 |> DataFrame)[1, :n_standings] == first_val

    # The same Subquery object in a second outer query correlates independently.
    q2 = M.Driver.objects.
        filter("driverid" => 2).
        values("n_standings" => shared)
    @test (q2 |> DataFrame)[1, :n_standings] ==
        M.Driver_standings.objects.filter("driverid" => 2).count()

    # And q1 still renders correctly after q2 ran.
    @test (q1 |> DataFrame)[1, :n_standings] == first_val
end

# ─────────────────────────────────────────────────────────────────────────────
# Subquery (#92): fail-loud nesting boundary. A Subquery projected inside
# another subquery raises — OuterRef resolves one level only, so a nested
# projection could silently correlate to the wrong outer query. Locks in the
# error rather than a wrong number (the #74 philosophy).
# ─────────────────────────────────────────────────────────────────────────────
@testset "Subquery (#92) - nested projected subquery raises" begin
    innermost = M.Driver_standings.objects
    innermost.filter("driverid" => OuterRef("driverid"))
    innermost.values("t" => Count("driverstandingsid"))

    middle = M.Driver_standings.objects
    middle.filter("driverid" => OuterRef("driverid"))
    middle.values("nested" => Subquery(innermost))
    middle.limit(1)                       # single column + LIMIT: passes every other check

    q = M.Driver.objects.
        filter("driverid" => 1).
        values("x" => Subquery(middle))

    err = try; q |> DataFrame; nothing; catch e; e; end
    @test err isa ArgumentError && occursin("one level", err.msg)
end
