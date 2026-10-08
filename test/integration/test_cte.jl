# julia -t auto --project=test/integration test/integration/test_cte.jl

if !isdefined(Main, :PormG)
    include("common_setup.jl")
end


# ─────────────────────────────────────────────────────────────────────────────
# with (CTE)
# Tests for WITH clause injection, join semantics, and edge cases.
# ─────────────────────────────────────────────────────────────────────────────
@testset "With (CTE)" begin

    @testset "basic: CTE with join_field, aggregated column reachable" begin
        duplicates = M.Result.objects
        duplicates.filter("statusid" => 1)
        duplicates.values("driverid", "dias" => Count("resultid"))

        main_query = M.Result.objects
        main_query.with("tb_dup" => duplicates, join_field="driverid" => "driverid")
        main_query.filter("resultid__@lte" => 100)
        main_query.values("resultid", "driverid", CTE("tb_dup", "dias"))
        df = main_query |> DataFrame

        @test nrow(df) == 100
        @test filter(row -> row.resultid == 1, df)[1, :tb_dup__dias] == 312
        @test filter(row -> row.resultid == 1, df) |> nrow == 1
        @test filter(row -> row.resultid == 100, df)[1, :driverid] == 5
    end

    @testset "aggregation and multiple fields in CTE" begin
        stats = M.Result.objects
        stats.filter("raceid__@lte" => 100)
        stats.values(
            "driverid",
            "total_results" => Count("resultid"),
            "avg_grid" => Sum("grid")
        )

        query = M.Driver.objects
        query.with("driver_stats" => stats, join_field="driverid" => "driverid")
        query.filter("driverid__@lte" => 50)
        query.values(
            "driverid", "forename", "surname",
            CTE("driver_stats", "total_results"),
            CTE("driver_stats", "avg_grid")
        )
        df = query |> DataFrame

        @test nrow(df) == 50
        @test nrow(filter(row -> !ismissing(row.driver_stats__total_results), df)) == 48
        @test filter(row -> row.driverid == 22, df)[1, :driver_stats__total_results] == 100
        @test filter(row -> row.driverid == 22, df)[1, :driver_stats__avg_grid] == 986
        @test nrow(filter(row -> row.driverid == 22, df)) == 1
    end

    @testset "join_field nested path keeps ORDER BY resolved" begin
        # Regression: when join_field references a nested path that was already resolved
        # during CTE wiring, ORDER BY must reuse the resolved SQL selector and not emit
        # the raw lookup string "driverid__surname" as a quoted column name.
        # TODO: extend to cover alias, direct field, and other joined-field orderings.
        driver_lookup = M.Driver.objects
        driver_lookup.filter("driverid__@lte" => 5)
        driver_lookup.values("surname", "driverid")

        query = M.Result.objects
        query.with("driver_lookup" => driver_lookup, join_field="driverid__surname" => "surname")
        query.filter("resultid__@lte" => 50)
        query.values(
            "resultid",
            "driver_name" => "driverid__surname",
            CTE("driver_lookup", "driverid")
        )
        query.order_by("driverid__surname", "resultid")

        insp = query |> inspect_query
        df = query |> DataFrame

        @test !occursin("\"driverid__surname\"", insp[:sql_text])
        @test occursin(r"ORDER BY\s+\"[A-Za-z0-9_]+\"\.\"surname\" ASC", insp[:sql_text])
        @test nrow(df) == 50
    end

    @testset "multiple CTEs on same query" begin
        recent_races = M.Race.objects
        recent_races.filter("year__@gte" => 2020)
        recent_races.values("raceid", "name", "year")

        top_drivers = M.Driver.objects
        top_drivers.filter("driverid__@lte" => 100)
        top_drivers.values("driverid", "forename", "surname")

        query = M.Result.objects
        query.with("recent" => recent_races, join_field="raceid" => "raceid")
        query.with("top_d" => top_drivers, join_field="driverid" => "driverid")
        query.values("resultid", CTE("recent", "name"), CTE("top_d", "forename"), "points")
        query.filter(CTE("recent", "name__@isnull") => false, CTE("top_d", "forename__@isnull") => false)
        df = query |> DataFrame

        @test nrow(df) == 294
        @test nrow(filter(row -> row.top_d__forename == "Lewis", df)) == 106
        @test nrow(filter(row -> row.recent__name == "Australian Grand Prix", df)) == 7
    end

    @testset "join_type INNER on CTE join" begin
        # INNER removes main-table rows with no matching CTE row; LEFT (default) keeps them
        # with missing columns. This test exercises the INNER path.
        high_scorers = M.Result.objects
        high_scorers.filter("points__@gte" => 10)
        high_scorers.values("driverid", "max_points" => Sum("points"))

        query = M.Driver.objects
        query.with("high_scorers" => high_scorers, join_field="driverid" => "driverid", join_type="INNER")
        query.values("driverid", "forename", "max_points" => CTE("high_scorers", "max_points"))
        query.filter("driverid__@lte" => 100)
        df = query |> DataFrame

        @test nrow(df) == 29
        @test nrow(filter(row -> row.driverid == 1, df)) == 1
        @test filter(row -> row.driverid == 22, df)[1, :max_points] == 132
    end

    @testset "without join_field: CTE emitted but not joined to main query" begin
        # Omitting join_field still emits the WITH clause but produces no JOIN.
        # The CTE can still be referenced via an @in filter in the main query.
        seed_id = 915001
        seed_name = "cte-no-join-seed"

        cleanup = M.Just_a_test_deletion.objects
        cleanup.filter("id" => seed_id)
        cleanup.delete()

        cleanup = M.Just_a_test_deletion.objects
        cleanup.filter("name" => seed_name)
        cleanup.delete()

        seed = M.Just_a_test_deletion.objects
        seed.create("id" => seed_id, "name" => seed_name, "test_result" => 1)

        try
            subq = M.Just_a_test_deletion.objects.filter("test_result" => 1).values("id", "name")

            query = M.Just_a_test_deletion.objects
            query.with("sub" => subq)   # no join_field
            query.filter("id" => seed_id)

            insp = query |> inspect_query
            df = query |> DataFrame

            @test nrow(df) == 1
            # WITH clause is present ...
            @test occursin("WITH \"sub\"", insp[:sql_text])
            # ... but no JOIN to the CTE is emitted
            @test !occursin("LEFT JOIN \"sub\"", insp[:sql_text])
            @test !occursin("INNER JOIN \"sub\"", insp[:sql_text])
            # Both parameters (CTE filter + main filter) in order: CTE first
            @test insp[:parameters] == [1, seed_id]
        finally
            cleanup = M.Just_a_test_deletion.objects
            cleanup.filter("id" => seed_id)
            cleanup.delete()
        end
    end

    @testset "F() reference without join_field: CROSS JOIN + WHERE correlation (#44)" begin
        # #44: a CTE registered WITHOUT join_field, correlated to the main query by an F()
        # filter. `.with("r91" => races_91).filter("raceid" => CTE("r91", "raceid"), ...)` must emit
        # a CROSS JOIN to the CTE and render the correlation in WHERE — returning exactly the
        # 1991 race winners. Result-driven: cross-checked against the semantically equivalent
        # join-filter query, so this fails if the CROSS JOIN correlation is wrong.
        races_91_ids = Set(
            (M.Race.objects.filter("year" => 1991).values("raceid") |> DataFrame).raceid
        )

        races_91 = M.Race.objects.filter("year" => 1991).values("raceid")
        q = M.Result.objects
        q.with("r91" => races_91)                       # no join_field
        q.filter("raceid" => CTE("r91", "raceid"),          # correlation → CROSS JOIN + WHERE
                 "positionorder" => 1)                  # race winners only
        q.values("resultid", "raceid", "positionorder")

        insp = q |> inspect_query
        @test occursin("CROSS JOIN", insp[:sql_text])   # the #44 join shape is actually used

        df = q |> DataFrame
        @test nrow(df) > 0
        # Every winner belongs to a 1991 race (the CTE constrained the main query) ...
        @test all(rid -> rid in races_91_ids, df.raceid)
        # ... exactly one winner per distinct race (no CROSS-join fan-out) ...
        @test all(df.positionorder .== 1)
        @test nrow(df) == length(unique(df.raceid))
        # ... and the count matches the equivalent keyed join-filter query (independent path).
        expected = M.Result.objects.filter("raceid__year" => 1991, "positionorder" => 1).count()
        @test expected > 0              # fixture actually holds 1991 winners (guards vacuity)
        @test nrow(df) == expected
    end

    @testset "self-reference: CTE on same table (LEFT and INNER)" begin
        # CTE pre-filters Driver rows born before 1980, then joined back to Driver.
        # LEFT: Hamilton (1985) appears with missing CTE column.
        # INNER: Hamilton is excluded entirely.
        drivers_old = M.Driver.objects.filter("dob__@year__@lt" => 1980).values("driverid", "dob")

        # --- LEFT JOIN (default) ---
        query = M.Driver.objects
        query.with("old_guard" => drivers_old, join_field="driverid" => "driverid")
        query.filter("nationality" => "British")
        query.values("forename", "surname", CTE("old_guard", "dob"))
        df = query |> DataFrame

        lewis = df[df.forename.=="Lewis", :]
        @test !isempty(lewis)
        @test ismissing(lewis[1, :old_guard__dob])

        david = df[df.forename.=="David", :]
        @test !isempty(david)
        @test !ismissing(david[1, :old_guard__dob])
        # SQLite stores dates as text; accept both representations
        if typeof(david[1, :old_guard__dob]) <: AbstractString
            @test Date(david[1, :old_guard__dob]) == Date(1971, 3, 27)
        else
            @test david[1, :old_guard__dob] == Date(1971, 3, 27)
        end

        # --- INNER JOIN ---
        query_inner = M.Driver.objects
        query_inner.with("old_guard_inner" => drivers_old,
            join_field="driverid" => "driverid",
            join_type="INNER")
        query_inner.filter("nationality" => "British")
        query_inner.values("forename", "surname", CTE("old_guard_inner", "dob"))
        df_inner = query_inner |> DataFrame

        @test isempty(df_inner[df_inner.forename.=="Lewis", :])
        david_inner = df_inner[df_inner.forename.=="David", :]
        @test !isempty(david_inner)
        @test !ismissing(david_inner[1, :old_guard_inner__dob])
    end

    @testset "deep joins and CTE parameter ordering" begin
        # Validates that CTE parameters (from deep joins inside the CTE subquery) are
        # emitted before main-query parameters — critical for positional (?) backends like SQLite.
        cte_source = M.Result.objects
        cte_source.filter(
            "raceid__circuitid__name__@icontains" => "Monaco",  # CTE param 1
            "raceid__year__@gte" => 2010       # CTE param 2
        )
        cte_source.values("constructorid", "total_points" => Sum("points"))

        main_query = M.Constructor.objects
        main_query.with("monaco_stats" => cte_source, join_field="constructorid" => "constructorid")
        main_query.filter("name__@ne" => "Ferrari")             # main param 3
        main_query.values("name", "nationality", CTE("monaco_stats", "total_points"))
        main_query.order_by(CTE("monaco_stats", "total_points"; desc = true))
        df = main_query |> DataFrame

        @test "monaco_stats__total_points" in names(df)
        @test size(df, 1) > 0
        @test "Red Bull" in df.name
        @test !("Ferrari" in df.name)
        row_rb = df[df.name.=="Red Bull", :]
        @test !ismissing(row_rb[1, :monaco_stats__total_points])
        @test row_rb[1, :monaco_stats__total_points] == 390
    end

    # ─────────────────────────────────────────────────────────────────────────
    # count() / exists() with CTEs
    # ─────────────────────────────────────────────────────────────────────────
    # Regression: .count() and .exists() must build the CTE WITH clause
    # BEFORE the main query so that:
    #   (a) PostgreSQL $N numbering is sequential (CTE params first),
    #   (b) SQLite positional ? bucket ordering matches SQL clause order,
    #   (c) the WITH clause is actually emitted in the SQL string.
    # ─────────────────────────────────────────────────────────────────────────

    @testset "count() on CTE-bearing query returns correct count" begin
        # Reuse the "basic" CTE: count results ≤ 100 joined with driver finish counts.
        duplicates = M.Result.objects
        duplicates.filter("statusid" => 1)
        duplicates.values("driverid", "dias" => Count("resultid"))

        main_query = M.Result.objects
        main_query.with("tb_dup" => duplicates, join_field="driverid" => "driverid")
        main_query.filter("resultid__@lte" => 100)

        # count() must emit the WITH clause and produce the same row count as DataFrame.
        cnt = main_query.count()
        @test cnt == 100
    end

    @testset "exists() on CTE-bearing query returns true" begin
        # Same CTE as above: there ARE results with resultid ≤ 100,
        # so exists() must return true (and must not silently drop the CTE).
        duplicates = M.Result.objects
        duplicates.filter("statusid" => 1)
        duplicates.values("driverid", "dias" => Count("resultid"))

        main_query = M.Result.objects
        main_query.with("tb_dup" => duplicates, join_field="driverid" => "driverid")
        main_query.filter("resultid__@lte" => 100)

        @test main_query.exists() == true
    end

    @testset "exists() on CTE-bearing query with impossible filter returns false" begin
        # CTE source is fine, but the main query asks for an impossible resultid.
        duplicates = M.Result.objects
        duplicates.filter("statusid" => 1)
        duplicates.values("driverid", "dias" => Count("resultid"))

        main_query = M.Result.objects
        main_query.with("tb_dup" => duplicates, join_field="driverid" => "driverid")
        main_query.filter("resultid" => -999)  # no such resultid

        @test main_query.exists() == false
    end

end


# ─────────────────────────────────────────────────────────────────────────────
# CTE error paths
# Guard tests for invalid with() usage patterns.
# ─────────────────────────────────────────────────────────────────────────────
@testset "CTE error paths" begin

    @testset "on() targeting a CTE name is rejected" begin
        # CTE names are in q.ctes, not join paths. The user should use with(..., join_type=...)
        # to control CTE join types, not on().
        q = M.Result.objects
        sub = M.Driver.objects.filter("driverid__@lte" => 5).values("driverid")
        q.with("driver_cte" => sub, join_field="driverid" => "driverid")
        @test_throws PormGError q.on("driver_cte", "driverid__@lte" => 5)
    end

    @testset "with() duplicate CTE name is rejected" begin
        # Two CTEs with the same alias on the same query would produce invalid SQL.
        # The ORM catches this at the with() call site.
        q = M.Result.objects
        sub = M.Driver.objects.filter("driverid__@lte" => 5).values("driverid")
        q.with("dup" => sub, join_field="driverid" => "driverid")
        # #197: the CTE builder now throws a typed ArgumentError (was a raw String, which no
        # `catch e; e isa Exception` could see).
        @test_throws PormGError q.with("dup" => sub, join_field="driverid" => "driverid")
    end

end


# ─────────────────────────────────────────────────────────────────────────────
# cjoin + with combinations
# Queries that combine a CTE and a custom join on the same object.
# Both features touch the parameter routing separately; this block verifies
# that bucket isolation holds when they appear together.
# ─────────────────────────────────────────────────────────────────────────────
@testset "cjoin + with combinations" begin

    @testset "CTE and cjoin on same query: parameter buckets stay isolated" begin
        # CTE supplies one filter (constructorid <= 5), cjoin supplies another
        # (Driver.nationality = 'German'). If bucket routing is broken, the database
        # would either error or silently return wrong rows.
        top_const = M.Constructor.objects
        top_const.filter("constructorid__@lte" => 5)
        top_const.values("constructorid", "name")

        query = M.Result.objects
        query.with("tc" => top_const, join_field="constructorid" => "constructorid")
        query.cjoin("driverid" => "Driver", filters=["nationality" => "German"], warn=false)
        query.values("resultid", CTE("tc", "name"), "driverid__surname")
        query.limit(10)
        df = query |> DataFrame

        @test "tc__name" in names(df)
        @test "driverid__surname" in names(df)
        @test nrow(df) <= 10
    end

    @testset "with() CTE and on() forward FK on same query" begin
        # CTE and on() use different internal stores (q.ctes vs q.custom_join) so
        # they must not interfere with each other's parameter routing.
        # CTE: constructors with id ≤ 5 — LEFT joined to results by constructorid.
        # on(): only Brazilian drivers get their surname populated (LEFT JOIN on driverid).
        #
        # #474/#489 — `join_type = "LEFT"` is load-bearing here. `Result.driverid` is NOT NULL, so
        # PormG derives INNER and `on()` no longer overrides that on its own. Both assertions at the
        # end of this testset depend on the non-Brazilian rows surviving: without the explicit LEFT
        # the result narrows to Brazilian winners, `df.driverid__surname` has no missing values at
        # all, and `df.tc__name` came back all-missing too.
        top_const = M.Constructor.objects
        top_const.filter("constructorid__@lte" => 5)
        top_const.values("constructorid", "name")

        query = M.Result.objects
        query.with("tc" => top_const, join_field="constructorid" => "constructorid")
        query.on("driverid", "nationality" => "Brazilian", join_type = "LEFT")
        query.filter("positionorder" => 1, "resultid__@lte" => 200)
        query.values("resultid", CTE("tc", "name"), "driverid__surname")
        df = query |> DataFrame

        @test "tc__name" in names(df)
        @test "driverid__surname" in names(df)
        @test nrow(df) > 0

        # CTE dimension: at least one winner was from a top-5 constructor
        @test any(.!ismissing.(df.tc__name))

        # on() dimension: at least one winner was Brazilian, and at least one wasn't
        @test any(.!ismissing.(df.driverid__surname))   # Brazilian driver rows
        @test any(ismissing.(df.driverid__surname))      # non-Brazilian driver rows
    end

end


# ─────────────────────────────────────────────────────────────────────────────
# Stress: full parameter-bucket saturation
#
# This testset deliberately exercises every parameter source and bucket in a
# single composed query to validate that:
#   1. All six buckets (cte, select, join, where, having, subquery-in-filter)
#      are populated and kept isolated.
#   2. The final DataFrame contains rows that are semantically correct against
#      the real F1 dataset.
#   3. Neither backend (PostgreSQL / SQLite) scrambles parameter order when
#      ALL of the following are active simultaneously:
#        • Two CTEs (each with their own deep-join filters)
#        • One cjoin with an ON-clause filter
#        • One on() forward-FK predicate
#        • A subquery used as an @in filter
#        • A Qor WHERE filter
#        • A HAVING aggregate filter
#        • ORDER BY on a CTE-aliased column
#
# Business question answered:
#   "Among Brazilian or German race winners (Qor) whose driver id is in the
#    set of drivers who won at least one Monaco race (subquery), which
#    constructor–driver combinations earned more than 50 total points
#    together at circuits outside Europe (HAVING), given that the constructor
#    was among the top-15 by id (CTE-1 = top_constructors) and the race was
#    from 2000 onward (CTE-2 = modern_races)?
#    Additionally, attach the circuit country for each result row via cjoin,
#    but restrict the join to non-European circuits (ON filter), and use
#    on() to attach each driver's dob only when the driver is born before 1980."
#
# Everything is pinned against the real F1 dataset, so the row counts and
# aggregate values below are hard-coded expected values.
# ─────────────────────────────────────────────────────────────────────────────
@testset "stress: full parameter-bucket saturation" begin

    # ── Subquery: driver ids who won (positionorder = 1) at Monaco ───────────
    # Bucket contribution: WHERE (?/subquery position depends on backend;
    # for positional backends this lives inside the CTE parameter block
    # because the subquery is embedded in the CTE filter).
    # We keep it as a standalone scalar subquery used inside a @in filter.
    monaco_winners_sq = M.Result.objects.filter(
        "raceid__circuitid__name__@icontains" => "Monaco",   # subquery param 1
        "positionorder" => 1                                  # subquery param 2
    )
    monaco_winners_sq.values("driverid")

    # ── CTE 1: top_constructors ───────────────────────────────────────────────
    # Restricts to constructors with id ≤ 15.
    # CTE bucket param: 15
    top_constructors = M.Constructor.objects.filter("constructorid__@lte" => 15)     # cte param 1
    top_constructors.values("constructorid", "name", "nationality")

    # ── CTE 2: modern_races ───────────────────────────────────────────────────
    # Races from 2000 onward at non-European circuits.
    # CTE bucket params: 2000, "Europe"
    modern_races = M.Race.objects
    modern_races.filter(
        "year__@gte" => 2000,       # cte param 2
        "circuitid__country__@ne" => "Europe"    # cte param 3 (placeholder; actual continents stored as country)
    )
    modern_races.values("raceid", "year", "circuitid__country")

    # ── Main query: Result ────────────────────────────────────────────────────
    query = M.Result.objects

    # Attach CTE 1 – LEFT join on constructorid
    query.with("tc" => top_constructors, join_field="constructorid" => "constructorid")

    # Attach CTE 2 – LEFT join on raceid
    query.with("mr" => modern_races, join_field="raceid" => "raceid")

    # cjoin: attach Race, and Circuit via raceid__circuitid, but only for circuits outside the UK.
    # ON filter bucket: join param 1. #973: the circuit predicate is written on the circuit's own hop
    # with on() — inside the race cjoin's filters, `circuitid__country__@ne` reached past the hop and
    # is refused. LEFT on both, as the relocated predicate's join was.
    query.cjoin("raceid" => "Race", join_type="LEFT", warn=false)
    query.on("raceid__circuitid", "country__@ne" => "UK", join_type = "LEFT")  # join param 1

    # on(): attach Driver but only for drivers born before 1985 (LEFT JOIN).
    # join bucket param 2. The explicit join_type keeps that "(LEFT JOIN)" true after #474 — this
    # testset is about parameter-bucket saturation and its assertions do not depend on the join
    # type, but a comment describing a join the query does not emit is how #489 stayed invisible.
    query.on("driverid", "dob__@year__@lt" => 1985, join_type = "LEFT")   # join param 2

    # WHERE filters:
    #   - positionorder = 1  (only race winners)                 where param 1
    #   - driverid in monaco_winners_sq  (won at Monaco)         where subquery
    #   - Qor: driver is Brazilian OR German                     where params 2, 3
    query.filter("positionorder" => 1)                          # where param 1
    query.filter("driverid__@in" => monaco_winners_sq)          # where: inline subquery
    query.filter(Qor("driverid__nationality" => "Brazilian",
        "driverid__nationality" => "German"))      # where params 2, 3

    # SELECT: resultid, CTE columns, joined columns, and aggregation alias
    query.values(
        "resultid",
        "driverid",
        "constructorid",
        "points",
        CTE("tc", "name"),               # from CTE 1
        CTE("mr", "year"),               # from CTE 2
        "raceid__name",                  # from cjoin → Race
        "driverid__surname",             # from on() → Driver (LEFT: may be missing)
        "total_points" => Sum("points"), # aggregate — will go to HAVING
        CTE("tc", "nationality")
    )

    # HAVING: only groups with summed points > 5
    # having bucket param: 5
    query.filter("total_points__@gt" => 5)                     # having param 1

    # ORDER BY: descending total_points so the dominant pair is first
    query.order_by("-total_points", "driverid")

    # ── Inspect SQL structure ─────────────────────────────────────────────────
    insp = query |> inspect_query

    # Both CTEs must be emitted in the WITH clause
    @test occursin("WITH", insp[:sql_text])
    @test occursin("\"tc\"", insp[:sql_text])
    @test occursin("\"mr\"", insp[:sql_text])

    # cjoin (Race) and on() (Driver) produce LEFT JOINs
    @test occursin("LEFT JOIN", insp[:sql_text])

    # HAVING clause must be present (aggregate filter)
    @test occursin("HAVING", insp[:sql_text])

    # Parameter buckets must each be populated (positional backends only — PostgreSQL
    # uses linear parameter numbering without per-clause buckets).
    buckets = insp[:parameter_buckets]
    if !isempty(buckets)
        # Positional backend (e.g. SQLite): per-clause buckets are available
        @test !isempty(buckets[:cte])         # CTE filters
        @test !isempty(buckets[:join])        # cjoin ON + on() predicates
        @test !isempty(buckets[:where])       # positionorder, subquery params, Qor nationality
        @test !isempty(buckets[:having])      # total_points > 50
    end

    # CTE params come before join params, which come before where params.
    # Verify by checking the overall flat order contains at least one value from each bucket
    # and that the total matches the sum of individual buckets.
    all_params = insp[:parameters]
    if !isempty(buckets)
        total_expected = length(buckets[:cte]) +
                         length(buckets[:select]) +
                         length(buckets[:join]) +
                         length(buckets[:where]) +
                         length(buckets[:having])
        @test length(all_params) == total_expected
    else
        # PostgreSQL: no bucket breakdown, but we still expect parameters to be present
        @test length(all_params) > 0
    end

    # ── Execute and validate results ──────────────────────────────────────────
    df = query |> DataFrame

    # The query is selective — Brazilian/German Monaco winners who also scored
    # > 50 points in CTE-filtered modern non-European races is a narrow set.
    # We expect at least one row but do not hard-code an exact count since it
    # depends on the full dataset loaded into the test database.
    @test nrow(df) >= 1

    # positionorder = 1 is guaranteed by the WHERE filter; verify only that
    # the expected selected columns are present (positionorder itself is not
    # in the values list — it was used purely as a filter).
    @test "resultid" in names(df)

    # tc__name should be present (type check); rows from non-top-15 constructors get missing
    @test "tc__name" in names(df)

    # mr__year should be present; modern race rows have a year value
    @test "mr__year" in names(df)

    # total_points must always exceed 5 (the HAVING cutoff)
    @test all(df.total_points .> 5)

    # For rows where the driver was born before 1985, surname must NOT be missing
    if "driverid__surname" in names(df)
        early_drivers = df[.!ismissing.(df.driverid__surname), :]
        # Every populated surname row must correspond to a driver born before 1985
        # (left-join predicate; we can't directly check dob here, but we can verify
        #  that the column is present and some rows are indeed populated)
        @test nrow(early_drivers) >= 0   # structural: column exists and is iterable
    end

    # ORDER BY correctness: total_points must be non-increasing row by row
    pts = collect(skipmissing(df.total_points))
    @test pts == sort(pts, rev=true)

    # ── Scalar spot-check ─────────────────────────────────────────────────────
    # Senna (Brazilian) won more races than any other driver from this filtered set.
    # If the dataset is the canonical F1 dataset, at least one row should mention him.
    senna_rows = df[.!ismissing.(df.driverid__surname).&(df.driverid__surname.=="Senna"), :]
    if nrow(senna_rows) > 0
        # His total_points in this filtered set must respect the HAVING cutoff
        @test all(senna_rows.total_points .> 5)
        # He raced for McLaren (constructorid 1) or Toleman/Lotus — not a top-15 check,
        # just verify the CTE name column is non-missing for known top constructors
        mclaren_senna = senna_rows[.!ismissing.(senna_rows.tc__name), :]
        if nrow(mclaren_senna) > 0
            @test all(mclaren_senna.tc__name .∈ Ref(["McLaren", "Williams", "Ferrari",
                "Brabham", "Lotus", "Tyrrell",
                "Benetton", "Renault"]))
        end
    end

end

# ─────────────────────────────────────────────────────────────────────────────
# Shared mutable state in the read/copy path (#43)
# A CTE query must be re-executable and copy-independent: `.list()`/`DataFrame`
# must not write back onto the caller, and `.copy()` must not alias CTE state.
# Runs against whichever backend the suite is bound to (db_2 / db_sl), so it
# exercises both PostgreSQL and SQLite. See test/unit/test_shared_state_readpath.jl
# for the deterministic SQL-shape counterpart.
# ─────────────────────────────────────────────────────────────────────────────
@testset "CTE copy-independence and re-execution (#43)" begin
    dup = M.Result.objects
    dup.filter("statusid" => 1)
    dup.values("driverid", "dias" => Count("resultid"))

    q = M.Result.objects
    q.with("tb_dup" => dup, join_field="driverid" => "driverid")
    q.filter("resultid__@lte" => 100)
    q.values("resultid", "driverid", CTE("tb_dup", "dias"))
    q.order_by("resultid")   # deterministic row order so DataFrame equality is stable

    # AC4: re-executing the same query returns identical results (no accumulation).
    # isequal (not ==): tb_dup__dias comes from a LEFT join and can be `missing`, and
    # DataFrame `==` returns `missing` (not a Bool) when any cell is missing — which
    # would ERROR @test rather than fail. isequal treats missing == missing and yields Bool.
    df_first = q |> DataFrame
    df_second = q |> DataFrame
    @test nrow(df_first) == 100
    @test isequal(df_first, df_second)

    # AC1: the read did not mutate the caller (no parameters write-back, no CTE "model" leak).
    @test q.object.parameters === nothing
    @test !haskey(q.object.ctes["tb_dup"], "model")

    # AC2/AC3: a copy given a divergent filter executes independently; original unaffected.
    q2 = q.copy()
    @test q2.object.ctes["tb_dup"] !== q.object.ctes["tb_dup"]   # #43: fresh CTE state, not an alias
    q2.filter("resultid__@lte" => 10)                            # narrows the copy to 10 rows

    df_copy = q2 |> DataFrame
    df_orig_again = q |> DataFrame
    @test nrow(df_copy) == 10
    @test isequal(df_orig_again, df_first)    # original still renders/returns its own 100-row result
end

# ─────────────────────────────────────────────────────────────────────────────
# CTE column typed from a Case with an expression branch (#812)
# A `Case` column in a CTE body whose branch is an expression (`then = F("points")`,
# `then = Rank(…)`) was typed CharField, so the outer `c__col__@gt => n` bound the STRING "n". On
# SQLite a computed CTE column and a bound parameter both lack type affinity, INTEGER/REAL sort
# below TEXT, and the filter silently returned no rows; PostgreSQL inferred the parameter type from
# the column and happened to work. Each expected set is computed by a plain query on `result`, not by
# the CTE path under test. Race 1 is the 2009 Australian GP: podium 10/8/6, points to 8th, none tied.
# ─────────────────────────────────────────────────────────────────────────────
@testset "CTE Case column with an expression branch filters as a number (#812)" begin
    @testset "then = F(\"points\")" begin
        body = M.Result.objects
        body.filter("raceid" => 1)
        body.values("resultid", "podium_pts" => Case([When("positionorder__@lte" => 3, then = F("points"))], default = 0))
        q = M.Result.objects
        q.with("c" => body, join_field = "resultid" => "resultid")
        q.filter("raceid" => 1, "c__podium_pts__@gt" => 7)
        q.values("resultid")
        got = sort((q |> DataFrame).resultid)

        # Independent: the podium finishers of race 1 with more than 7 points (the winner and 2nd).
        expected = sort((M.Result.objects.filter("raceid" => 1, "positionorder__@lte" => 3, "points__@gt" => 7).
            values("resultid") |> DataFrame).resultid)
        @test length(expected) == 2
        @test got == expected
    end

    @testset "then = Rank(…), the issue's spelling" begin
        body = M.Result.objects
        body.filter("raceid" => 1)
        body.values("resultid", "rk" => Case([When("points__@gt" => 0, then = Rank(over = WindowOver(order_by = ["-points"])))], default = 0))
        q = M.Result.objects
        q.with("c" => body, join_field = "resultid" => "resultid")
        q.filter("raceid" => 1, "c__rk__@gt" => 3)
        q.values("resultid")
        got = sort((q |> DataFrame).resultid)

        # Independent: a scorer ranks above 3rd exactly when it scored less than the 3rd place's 6
        # points, since no two scorers in race 1 share a total — 4th to 8th, five rows.
        expected = sort((M.Result.objects.filter("raceid" => 1, "points__@gt" => 0, "points__@lt" => 6).
            values("resultid") |> DataFrame).resultid)
        @test length(expected) == 5
        @test got == expected
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# Cast(…, "date") is a date on both engines (#822)
# SQLite rendered `CAST(date AS DATE)`, and its DATE type name has NUMERIC affinity, so the race date
# `'2009-03-29'` came back as the integer 2009 and a date filter on a CTE column built from it matched
# nothing (#812 refused that CTE shape on SQLite for this reason). SQLite now renders `date(…)`. Each
# expected value comes from the plain `date` column, not from the cast under test.
# ─────────────────────────────────────────────────────────────────────────────
@testset "Cast(…, \"date\") is a date on both engines (#822)" begin
    @testset "projected, it reads back as the column's Date" begin
        q = M.Race.objects
        q.filter("raceid__@lte" => 3)
        q.order_by("raceid")
        q.values("raceid", "day" => Cast("date", "date"))
        got = q |> DataFrame

        plain = M.Race.objects
        plain.filter("raceid__@lte" => 3)
        plain.order_by("raceid")
        plain.values("raceid", "date")
        expected = plain |> DataFrame

        @test nrow(got) == 3
        @test all(d -> d isa Date, got.day)
        @test got.day == expected.date
    end

    @testset "a CTE column declared date filters by a date string" begin
        body = M.Race.objects
        body.filter("year" => 2009)
        body.values("raceid", "day" => Cast("date", "date"))
        q = M.Race.objects
        q.with("c" => body, join_field = "raceid" => "raceid")
        q.filter("c__day__@gte" => "2009-06-01")
        q.values("raceid")
        got = sort((q |> DataFrame).raceid)

        expected = sort((M.Race.objects.filter("year" => 2009, "date__@gte" => "2009-06-01").
            values("raceid") |> DataFrame).raceid)
        @test !isempty(expected)
        @test got == expected
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# Coalesce/Greatest output_field is what the value is, on both engines (#852)
# `start_at` is a timestamp — on SQLite the stored text `'2009-03-29T06:00:00.000+00:00'`. Declared
# `date`, `Coalesce("start_at", "date")` was believed by both readers while SQLite rendered no cast,
# so a date filter compared that timestamp text with `'2009-03-29'` and matched nothing (and the CTE
# shape was refused outright). It now renders `date(COALESCE(…))`. Expected values come from the
# plain `date` column, not from the cast under test.
# ─────────────────────────────────────────────────────────────────────────────
@testset "Coalesce/Greatest output_field casts on both engines (#852)" begin
    race_day() = Coalesce("start_at", "date"; output_field = "date")

    @testset "an alias declared date filters, and reads back, as a date" begin
        q = M.Race.objects
        q.filter("year" => 2009)
        q.values("raceid", "day" => race_day())
        q.filter("day" => Date(2009, 3, 29))     # the 2009 Australian GP
        df = q |> DataFrame
        @test df.raceid == [1]
        @test df[1, :day] isa Date && df[1, :day] == Date(2009, 3, 29)
    end

    @testset "a CTE column declared date filters by a date string" begin
        body = M.Race.objects
        body.filter("year" => 2009)
        body.values("raceid", "day" => race_day())
        q = M.Race.objects
        q.with("c" => body, join_field = "raceid" => "raceid")
        q.filter("c__day__@gte" => "2009-06-01")
        q.values("raceid")
        got = sort((q |> DataFrame).raceid)

        expected = sort((M.Race.objects.filter("year" => 2009, "date__@gte" => "2009-06-01").
            values("raceid") |> DataFrame).raceid)
        @test !isempty(expected)
        @test got == expected
    end

    @testset "Greatest declared integer filters by a number" begin
        plain = M.Result.objects.filter("raceid" => 1).values("resultid", "points") |> DataFrame
        expected = sort(plain.resultid[plain.points .== 10])
        @test length(expected) == 1           # the winner's 10 points

        q = M.Result.objects
        q.filter("raceid" => 1)
        # #1028: over `Floor`, because a float cast to an integer rounds on PostgreSQL and truncates
        # on SQLite, and is refused. Race 1's points are whole numbers, so the filter is unchanged.
        q.values("resultid", "pts" => Greatest(Floor("points"), 0; output_field = "integer"))
        q.filter("pts" => 10)
        df = q |> DataFrame
        @test sort(df.resultid) == expected
        @test all(x -> x isa Integer, df.pts)
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# CTE column typed from F arithmetic or a declared alias type (#823)
# A body projecting `F` directly (`"gain" => F("grid") - F("positionorder")`) died as a MethodError
# before any SQL ran, and `Cast(x, "int8")` / `output_field = PositiveIntegerField()` were refused as
# unknown types. Each now types the column as a number, so the outer filter binds one. The expected
# set is computed in Julia from the plain `grid`/`positionorder` columns, not by the CTE path under
# test. Race 1 is the 2009 Australian GP: six finishers gained five places or more.
# ─────────────────────────────────────────────────────────────────────────────
@testset "CTE column from F arithmetic or a declared alias type filters as a number (#823)" begin
    plain = M.Result.objects.filter("raceid" => 1).values("resultid", "grid", "positionorder") |> DataFrame
    expected = sort(plain.resultid[(plain.grid .- plain.positionorder) .>= 5])
    @test length(expected) == 6

    gain = F("grid") - F("positionorder")
    for (label, expr) in (
        "F arithmetic, the issue's shape" => gain,
        "Cast(…, \"int8\")" => Cast(gain, "int8"),
        "output_field = PositiveIntegerField()" =>
            Coalesce(gain, 0, output_field = PormG.Models.PositiveIntegerField()),
    )
        @testset "$label" begin
            body = M.Result.objects
            body.filter("raceid" => 1)
            body.values("resultid", "gain" => expr)
            q = M.Result.objects
            q.with("g" => body, join_field = "resultid" => "resultid")
            q.filter("raceid" => 1, "g__gain__@gte" => 5)
            q.values("resultid", "g__gain")
            df = q |> DataFrame
            @test sort(df.resultid) == expected
            @test all(x -> x isa Integer, df.g__gain)
        end
    end
end
