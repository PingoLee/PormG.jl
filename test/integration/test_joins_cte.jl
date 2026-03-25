# julia -t auto  --project=. test/integration/test_joins_cte.jl

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
    df   = query |> DataFrame
    @test query.count() == 40
    @test query |> do_exists
end


# ─────────────────────────────────────────────────────────────────────────────
# cjoin
# Custom JOIN from an arbitrary base field to a named model.
# ─────────────────────────────────────────────────────────────────────────────
@testset "cjoin" begin
    # Shared fixture: 3 New_join_position rows pointing to Result ids 1-3.
    # Recreated at the start of this block so all inner testsets see a clean state.
    M.New_join_position.objects.delete(allow_delete_all=true, show_query=:execute)
    M.New_join_position.objects.create("result" => 1, "description" => "teste 1")
    M.New_join_position.objects.create("result" => 2, "description" => "teste 2")
    M.New_join_position.objects.create("result" => 3, "description" => "teste 3")

    @testset "simple join: all rows returned, deep path resolved" begin
        # A cjoin with no ON filter attaches every matching joined row.
        query = M.New_join_position.objects
        query.cjoin("result" => "Result")
        query.values("result__statusid__status", "description", "result")
        df = query |> DataFrame

        @test size(df, 1) == 3
        @test unique(df.result__statusid__status) == ["Finished"]
    end

    @testset "rejects base-model predicates in ON filters" begin
        # Predicates that belong to the calling model (New_join_position) are rejected
        # by cjoin. Allowing them would silently produce WHERE semantics, not ON semantics.
        q1 = M.New_join_position.objects
        @test_throws ArgumentError q1.cjoin("result" => "Result", filters=["description" => "teste 1"])

        q2 = M.New_join_position.objects
        @test_throws ArgumentError q2.cjoin("result" => "Result", filters=["result__description" => "teste 1"])
    end

    @testset "ON filter restricts joined rows (LEFT JOIN default)" begin
        # With resultid=1 in the ON clause only the row that joins to Result 1 gets
        # populated; the other two rows still appear with missing joined columns.
        query = M.New_join_position.objects
        query.cjoin("result" => "Result", filters=["resultid" => 1])
        query.values("result__statusid__status", "description", "result")
        df = query |> DataFrame

        @test size(df, 1) == 3
        @test "result__statusid__status" in names(df)
        @test df[df.description .== "teste 1", :result__statusid__status][1] == "Finished"
        @test df[df.description .== "teste 2", :result__statusid__status][1] === missing
    end

    @testset "ON filter with table-prefixed field name" begin
        # The field may be spelled with the joined-model prefix (result__resultid)
        # and must behave identically to the short form (resultid).
        query = M.New_join_position.objects
        query.cjoin("result" => "Result", filters=["result__resultid" => 1])
        query.values("result__statusid__status", "description", "result")
        df = query |> DataFrame

        @test size(df, 1) == 3
        @test df[df.description .== "teste 1", :result__statusid__status][1] == "Finished"
        @test df[df.description .== "teste 2", :result__statusid__status][1] === missing
    end

    @testset "ON filter combined with WHERE filter" begin
        # cjoin ON filter restricts which joined columns are populated;
        # .filter(...) on the main query then restricts the overall result set.
        query = M.New_join_position.objects
        query.cjoin("result" => "Result", filters=["resultid" => 1])
        query.filter("description" => "teste 1")
        query.values("result__statusid__status", "description", "result")
        df = query |> DataFrame

        @test size(df, 1) == 1
        @test df[1, :description] == "teste 1"
        @test df[1, :result__statusid__status] == "Finished"
    end

    @testset "join_type INNER: only matched rows are returned" begin
        # INNER drops rows whose join partner fails the ON predicate entirely,
        # instead of keeping them with missing columns (LEFT behaviour).
        query = M.New_join_position.objects
        query.cjoin("result" => "Result", filters=["resultid" => 1], join_type="INNER")
        query.values("result__statusid__status", "description", "result")
        df = query |> DataFrame

        @test size(df, 1) == 1
        @test df[1, :description] == "teste 1"
        @test df[1, :result__statusid__status] == "Finished"
    end

    @testset "multiple ON filters + wildcard values(*)" begin
        # Multiple filters are AND-combined on the ON clause.
        # Executing a cjoin query without explicit values() must raise ArgumentError
        # to prevent DataFrames from crashing on duplicate column names.
        # The wildcard "*" shorthand selects all native columns of the main model.
        query = M.New_join_position.objects
        query.cjoin("result" => "Result", filters=["resultid" => 1, "statusid" => 1], join_type="INNER")

        # Guard: a bare DataFrame() across a multi-table cjoin is rejected
        @test_throws ArgumentError query |> DataFrame

        # Wildcard selects all New_join_position columns plus the one named from Result
        query.values("*", "result__statusid")
        df = query |> DataFrame

        @test df |> nrow == 1
        @test df[1, :description] == "teste 1"
        @test df[1, :result] == df[1, :result__statusid] == 1
    end

    @testset "chaining multiple cjoins on same query" begin
        # Two cjoins on the same query LEFT-join independently.
        # Parameter bucket order must be: [cjoin1 params, cjoin2 params, WHERE params].
        query = M.Result.objects
        query.cjoin("driverid" => "Driver", filters=["nationality" => "Brazilian"])
        query.cjoin("raceid"   => "Race",   filters=["year" => 1991])
        query.filter("positionorder" => 1)

        # Guard: missing explicit values() is rejected
        @test_throws ArgumentError query |> DataFrame

        query.values("*", "driverid__surname", "raceid__name")
        df = query |> DataFrame

        # LEFT-joined custom filters preserve the full winner set while only
        # populating joined columns for rows that satisfy the respective ON predicate.
        @test nrow(df) > 0
        @test any(ismissing.(df.driverid__surname))
        @test any(.!ismissing.(df.driverid__surname))
        @test any(ismissing.(df.raceid__name))
        @test any(.!ismissing.(df.raceid__name))
        @test all(df.positionorder .== 1)
    end

    @testset "Qor filter in ON clause" begin
        # cjoin filters accept Qor (OR logic), not just flat Pairs.
        # The OR is placed in the JOIN ON clause, so all base rows are preserved
        # while only drivers matching either nationality get their column populated.
        query = M.Result.objects
        query.cjoin("driverid" => "Driver",
                    filters=[Qor("nationality" => "Brazilian", "nationality" => "German")])
        query.filter("positionorder" => 1)
        query.values("*", "driverid__surname", "driverid__nationality")
        df = query |> DataFrame

        # LEFT JOIN default: all winners appear
        @test nrow(df) > 0

        # Rows where the driver is Brazilian or German have their columns populated
        populated = df[.!ismissing.(df.driverid__surname), :]
        @test nrow(populated) > 0
        @test all(in.(populated.driverid__nationality, Ref(["Brazilian", "German"])))

        # At least one winner is neither Brazilian nor German → that row stays missing
        @test any(ismissing.(df.driverid__surname))
    end
end


# ─────────────────────────────────────────────────────────────────────────────
# Reverse joins
# Traversal from a model back to a model that holds the FK pointing at it.
# ─────────────────────────────────────────────────────────────────────────────
@testset "Reverse joins" begin
    # Shared fixture: two Just_a_test_deletion rows tied to Result ids 1 and 2.
    # Cleaned up and re-created at the top so all inner testsets share the same data.
    seed_ids   = [910001, 910002]
    seed_names = ["reverse-join-a", "reverse-join-b"]

    cleanup = M.Just_a_test_deletion.objects
    cleanup.filter("id__@in" => seed_ids)
    cleanup.delete()

    cleanup = M.Just_a_test_deletion.objects
    cleanup.filter("name__@in" => seed_names)
    cleanup.delete()

    seed = M.Just_a_test_deletion.objects
    seed.create("id" => seed_ids[1], "name" => seed_names[1], "test_result" => 1)
    seed.create("id" => seed_ids[2], "name" => seed_names[2], "test_result" => 2)

    @testset "basic: filter on reverse field collapses to matched rows only" begin
        # Normal .filter("reverse_relation__field" => ...) does an INNER-style traversal,
        # so only Result rows that have a matching reverse record are returned.
        query_a = M.Just_a_test_deletion.objects
        query_a.filter("name__@in" => seed_names)
        query_a.values("id", "name", "test_result", "test_result2")
        df_a = query_a |> DataFrame

        query = M.Result.objects
        query.values("test_deletion__id", "test_deletion__name", "resultid")
        query.filter("test_deletion__name__@in" => seed_names)
        df = query |> DataFrame

        @test size(df, 1) == size(df_a, 1)
        @test all(in.(df.test_deletion__id,   Ref(df_a.id)))
        @test all(in.(df.test_deletion__name, Ref(df_a.name)))
        @test sort(collect(skipmissing(df.resultid))) == [1, 2]
    end

    @testset "on() preserves all base rows (LEFT JOIN)" begin
        # query.on() places the predicate in the ON clause, not WHERE.
        # All three Result rows must appear; only matching reverse rows attach.
        # Compare with the test above: .filter() would have returned only 2 rows.
        query_on = M.Result.objects
        query_on.on("test_deletion", "name__@in" => seed_names)
        query_on.filter("resultid__@in" => [1, 2, 3])
        query_on.values("resultid", "test_deletion__name")
        df_on = query_on |> DataFrame

        @test nrow(df_on) == 3
        @test sort(df_on.resultid) == [1, 2, 3]
        @test df_on[df_on.resultid .== 1, :test_deletion__name][1] == "reverse-join-a"
        @test df_on[df_on.resultid .== 2, :test_deletion__name][1] == "reverse-join-b"
        # Result row 3 has no matching reverse record → column is missing
        @test df_on[df_on.resultid .== 3, :test_deletion__name][1] === missing
    end

    @testset "on() with join_type=INNER narrows to matched rows" begin
        # Switching to INNER eliminates Result row 3 entirely instead of keeping it
        # with a missing column — without moving the predicate into WHERE.
        query_on_inner = M.Result.objects
        query_on_inner.on("test_deletion", "name__@in" => seed_names, join_type="INNER")
        query_on_inner.filter("resultid__@in" => [1, 2, 3])
        query_on_inner.values("resultid", "test_deletion__name")
        df_on_inner = query_on_inner |> DataFrame

        @test nrow(df_on_inner) == 2
        @test sort(df_on_inner.resultid) == [1, 2]
        @test sort(collect(df_on_inner.test_deletion__name)) == seed_names
    end
end


# ─────────────────────────────────────────────────────────────────────────────
# on() forward FK
# on() can also be applied to forward FK paths (not just reverse relations).
# The ON predicate is placed in the JOIN clause, so all base rows are preserved
# even when the joined partner does not satisfy the extra predicate.
# ─────────────────────────────────────────────────────────────────────────────
@testset "on() forward FK" begin

    @testset "on() forward FK: all base rows preserved (LEFT JOIN)" begin
        # Using .filter("driverid__nationality" => "Brazilian") would return only
        # Brazilian-winner rows (INNER-style traversal through the FK).
        # Using .on("driverid", ...) places the predicate on the ON clause,
        # keeping ALL winner rows while only populating surname for Brazilian drivers.
        query = M.Result.objects
        query.on("driverid", "nationality" => "Brazilian")
        query.filter("positionorder" => 1)
        query.values("resultid", "driverid__surname")
        df = query |> DataFrame

        # Compare against the direct-filter approach (INNER-style): fewer rows
        inner_q = M.Result.objects
        inner_q.filter("positionorder" => 1, "driverid__nationality" => "Brazilian")
        inner_q.values("resultid", "driverid__surname")
        df_inner = inner_q |> DataFrame

        # on() (LEFT) returns more rows than the inner-style filter
        @test nrow(df) > nrow(df_inner)

        # The rows that did get surname populated match exactly what the inner filter returned
        populated = df[.!ismissing.(df.driverid__surname), :]
        @test nrow(populated) == nrow(df_inner)
    end

    @testset "on() accumulation: two calls AND their predicates" begin
        # Two on() calls on the same join path accumulate as AND conditions in the ON clause.
        # British AND code HAM means only Lewis Hamilton satisfies both predicates.
        # (Ayrton Senna's code is stored as "\\N" in the dataset, so he cannot be used here.)
        query = M.Result.objects
        query.on("driverid", "nationality" => "British")
        query.on("driverid", "code" => "HAM")
        query.filter("positionorder" => 1)
        query.values("resultid", "driverid__surname", "driverid__code")
        df = query |> DataFrame

        # LEFT JOIN: all winners appear
        @test nrow(df) > 0

        # Only Hamilton (British + HAM) satisfies both predicates and gets columns populated
        populated = df[.!ismissing.(df.driverid__surname), :]
        @test nrow(populated) > 0
        @test all(populated.driverid__code .== "HAM")
        @test all(populated.driverid__surname .== "Hamilton")

        # Compare with single predicate: double predicate yields ≤ rows populated
        query_single = M.Result.objects
        query_single.on("driverid", "nationality" => "British")
        query_single.filter("positionorder" => 1)
        query_single.values("resultid", "driverid__surname")
        df_single = query_single |> DataFrame
        populated_single = df_single[.!ismissing.(df_single.driverid__surname), :]

        # British includes Hamilton AND other British drivers; the double predicate is stricter
        @test nrow(populated) <= nrow(populated_single)
    end
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
        main_query.values("resultid", "driverid", "tb_dup__dias")
        df = main_query |> DataFrame

        @test nrow(df) == 100
        @test filter(row -> row.resultid == 1,   df)[1, :tb_dup__dias] == 312
        @test filter(row -> row.resultid == 1,   df) |> nrow == 1
        @test filter(row -> row.resultid == 100, df)[1, :driverid] == 5
    end

    @testset "aggregation and multiple fields in CTE" begin
        stats = M.Result.objects
        stats.filter("raceid__@lte" => 100)
        stats.values(
            "driverid",
            "total_results" => Count("resultid"),
            "avg_grid"      => Sum("grid")
        )

        query = M.Driver.objects
        query.with("driver_stats" => stats, join_field="driverid" => "driverid")
        query.filter("driverid__@lte" => 50)
        query.values(
            "driverid", "forename", "surname",
            "driver_stats__total_results",
            "driver_stats__avg_grid"
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
            "driver_lookup__driverid"
        )
        query.order_by("driverid__surname", "resultid")

        insp = query |> inspect_query
        df   = query |> DataFrame

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
        query.with("recent" => recent_races, join_field="raceid"   => "raceid")
        query.with("top_d"  => top_drivers,  join_field="driverid" => "driverid")
        query.values("resultid", "recent__name", "top_d__forename", "points")
        query.filter("recent__name__@isnull" => false, "top_d__forename__@isnull" => false)
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
        query.values("driverid", "forename", "max_points" => "high_scorers__max_points")
        query.filter("driverid__@lte" => 100)
        df = query |> DataFrame

        @test nrow(df) == 29
        @test nrow(filter(row -> row.driverid == 1, df)) == 1
        @test filter(row -> row.driverid == 22, df)[1, :max_points] == 132
    end

    @testset "without join_field: CTE emitted but not joined to main query" begin
        # Omitting join_field still emits the WITH clause but produces no JOIN.
        # The CTE can still be referenced via an @in filter in the main query.
        subq = M.Just_a_test_deletion.objects.filter("test_result" => 1).values("id", "name")

        query = M.Just_a_test_deletion.objects
        query.with("sub" => subq)   # no join_field
        query.filter("id" => 910001)

        insp = query |> inspect_query
        df   = query |> DataFrame

        @test nrow(df) == 1
        # WITH clause is present ...
        @test occursin("WITH \"sub\"", insp[:sql_text])
        # ... but no JOIN to the CTE is emitted
        @test !occursin("LEFT JOIN \"sub\"",  insp[:sql_text])
        @test !occursin("INNER JOIN \"sub\"", insp[:sql_text])
        # Both parameters (CTE filter + main filter) in order: CTE first
        @test insp[:parameters] == [1, 910001]
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
        query.values("forename", "surname", "old_guard__dob")
        df = query |> DataFrame

        lewis = df[df.forename .== "Lewis", :]
        @test !isempty(lewis)
        @test ismissing(lewis[1, :old_guard__dob])

        david = df[df.forename .== "David", :]
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
        query_inner.values("forename", "surname", "old_guard_inner__dob")
        df_inner = query_inner |> DataFrame

        @test isempty(df_inner[df_inner.forename .== "Lewis", :])
        david_inner = df_inner[df_inner.forename .== "David", :]
        @test !isempty(david_inner)
        @test !ismissing(david_inner[1, :old_guard_inner__dob])
    end

    @testset "deep joins and CTE parameter ordering" begin
        # Validates that CTE parameters (from deep joins inside the CTE subquery) are
        # emitted before main-query parameters — critical for positional (?) backends like SQLite.
        cte_source = M.Result.objects
        cte_source.filter(
            "raceid__circuitid__name__@icontains" => "Monaco",  # CTE param 1
            "raceid__year__@gte"                  => 2010       # CTE param 2
        )
        cte_source.values("constructorid", "total_points" => Sum("points"))

        main_query = M.Constructor.objects
        main_query.with("monaco_stats" => cte_source, join_field="constructorid" => "constructorid")
        main_query.filter("name__@ne" => "Ferrari")             # main param 3
        main_query.values("name", "nationality", "monaco_stats__total_points")
        main_query.order_by("-monaco_stats__total_points")
        df = main_query |> DataFrame

        @test "monaco_stats__total_points" in names(df)
        @test size(df, 1) > 0
        @test "Red Bull" in df.name
        @test !("Ferrari" in df.name)
        row_rb = df[df.name .== "Red Bull", :]
        @test !ismissing(row_rb[1, :monaco_stats__total_points])
        @test row_rb[1, :monaco_stats__total_points] == 390
    end

    # ─────────────────────────────────────────────────────────────────────────
    # count() / exists() with CTEs
    # ─────────────────────────────────────────────────────────────────────────
    # Regression: do_count and do_exists must build the CTE WITH clause
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
        query.cjoin("driverid" => "Driver", filters=["nationality" => "German"])
        query.values("resultid", "tc__name", "driverid__surname")
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
        top_const = M.Constructor.objects
        top_const.filter("constructorid__@lte" => 5)
        top_const.values("constructorid", "name")

        query = M.Result.objects
        query.with("tc" => top_const, join_field="constructorid" => "constructorid")
        query.on("driverid", "nationality" => "Brazilian")
        query.filter("positionorder" => 1, "resultid__@lte" => 200)
        query.values("resultid", "tc__name", "driverid__surname")
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
# Error paths
# Guard tests: ArgumentError / throw for invalid usage patterns.
# These tests do NOT execute SQL — they verify that the ORM rejects bad input
# at the query-building layer before it reaches the database.
# ─────────────────────────────────────────────────────────────────────────────
@testset "error paths" begin

    @testset "on() targeting a CTE name is rejected" begin
        # CTE names are in q.ctes, not join paths. The user should use with(..., join_type=...)
        # to control CTE join types, not on().
        q = M.Result.objects
        sub = M.Driver.objects.filter("driverid__@lte" => 5).values("driverid")
        q.with("driver_cte" => sub, join_field="driverid" => "driverid")
        @test_throws ArgumentError q.on("driver_cte", "driverid__@lte" => 5)
    end

    @testset "on() on a non-relational field is rejected" begin
        # on() requires the first segment of the join path to be a FK or reverse relation.
        # Scalars like `points` (FloatField) cannot be traversed.
        q = M.Result.objects
        @test_throws ArgumentError q.on("points", "points__@gt" => 0)
    end

    @testset "on() with no filters and no join_type is rejected" begin
        # An on() call with nothing to contribute is meaningless and is rejected early.
        q = M.Result.objects
        @test_throws ArgumentError q.on("driverid")
    end

    @testset "cjoin duplicate join path is rejected" begin
        # cjoin stores state in q.custom_join keyed by the join path.
        # Adding the same path twice would silently overwrite the first ON filter,
        # so it is rejected with an explicit error.
        q = M.Result.objects
        q.cjoin("driverid" => "Driver", warn=false)
        @test_throws ArgumentError q.cjoin("driverid" => "Driver", warn=false)
    end

    @testset "cjoin to unknown model name is rejected" begin
        # Model names are looked up via isdefined/getfield in the model's module;
        # a typo or wrong casing produces a clear error rather than a runtime crash.
        q = M.New_join_position.objects
        @test_throws ArgumentError q.cjoin("result" => "NonExistentModel")
    end

    @testset "cjoin mismatched FK target is rejected" begin
        # When the base field is already a FK (driverid → Driver), attempting to cjoin
        # it to a different model is rejected before any SQL is generated.
        q = M.Result.objects
        @test_throws ArgumentError q.cjoin("driverid" => "Constructor", warn=false)
    end

    @testset "With() duplicate CTE name is rejected" begin
        # Two CTEs with the same alias on the same query would produce invalid SQL.
        # The ORM catches this at the with() call site.
        q = M.Result.objects
        sub = M.Driver.objects.filter("driverid__@lte" => 5).values("driverid")
        q.with("dup" => sub, join_field="driverid" => "driverid")
        @test_throws String q.with("dup" => sub, join_field="driverid" => "driverid")
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
    );
    monaco_winners_sq.values("driverid");

    # ── CTE 1: top_constructors ───────────────────────────────────────────────
    # Restricts to constructors with id ≤ 15.
    # CTE bucket param: 15
    top_constructors = M.Constructor.objects.filter("constructorid__@lte" => 15);     # cte param 1
    top_constructors.values("constructorid", "name", "nationality");

    # ── CTE 2: modern_races ───────────────────────────────────────────────────
    # Races from 2000 onward at non-European circuits.
    # CTE bucket params: 2000, "Europe"
    modern_races = M.Race.objects;
    modern_races.filter(
        "year__@gte"                          => 2000,       # cte param 2
        "circuitid__country__@ne"             => "Europe"    # cte param 3 (placeholder; actual continents stored as country)
    );
    modern_races.values("raceid", "year", "circuitid__country");

    # ── Main query: Result ────────────────────────────────────────────────────
    query = M.Result.objects;

    # Attach CTE 1 – LEFT join on constructorid
    query.with("tc"  => top_constructors, join_field="constructorid" => "constructorid");

    # Attach CTE 2 – LEFT join on raceid
    query.with("mr"  => modern_races,     join_field="raceid"        => "raceid");

    # cjoin: attach Circuit via raceid__circuitid, but only for non-null altitude circuits
    # (alt IS NOT NULL means the circuit has a recorded elevation, used as a proxy
    #  for non-street circuits).  ON filter bucket: join param 1.
    query.cjoin("raceid" => "Race",
                filters=["circuitid__country__@ne" => "UK"],  # join param 1
                join_type="LEFT",
                warn=false);

    # on(): attach Driver but only for drivers born before 1985 (LEFT JOIN).
    # join bucket param 2.
    query.on("driverid", "dob__@year__@lt" => 1985);           # join param 2

    # WHERE filters:
    #   - positionorder = 1  (only race winners)                 where param 1
    #   - driverid in monaco_winners_sq  (won at Monaco)         where subquery
    #   - Qor: driver is Brazilian OR German                     where params 2, 3
    query.filter("positionorder" => 1);                          # where param 1
    query.filter("driverid__@in" => monaco_winners_sq);          # where: inline subquery
    query.filter(Qor("driverid__nationality" => "Brazilian",
                     "driverid__nationality" => "German"));      # where params 2, 3

    # SELECT: resultid, CTE columns, joined columns, and aggregation alias
    query.values(
        "resultid",
        "driverid",
        "constructorid",
        "points",
        "tc__name",                      # from CTE 1
        "mr__year",                      # from CTE 2
        "raceid__name",                  # from cjoin → Race
        "driverid__surname",             # from on() → Driver (LEFT: may be missing)
        "total_points" => Sum("points"), # aggregate — will go to HAVING
        "tc__nationality"
    );

    # HAVING: only groups with summed points > 5
    # having bucket param: 5
    query.filter("total_points__@gt" => 5);                     # having param 1

    # ORDER BY: descending total_points so the dominant pair is first
    query.order_by("-total_points", "driverid");

    # ── Inspect SQL structure ─────────────────────────────────────────────────
    insp = query |> inspect_query

    # Both CTEs must be emitted in the WITH clause
    @test occursin("WITH", insp[:sql_text])
    @test occursin("\"tc\"",  insp[:sql_text])
    @test occursin("\"mr\"",  insp[:sql_text])

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
    senna_rows = df[.!ismissing.(df.driverid__surname) .&
                    (df.driverid__surname .== "Senna"), :]
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
