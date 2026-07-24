# julia -t auto  --project=. test/integration/test_having.jl

if !isdefined(Main, :PormG)
    include("common_setup.jl")
end

# This file contains tests for the HAVING clause in PormG queries.
# The HAVING clause is used to filter results based on aggregate functions (like Count, Sum, Avg).
# In PormG, these filters are automatically detected when a field alias in a filter
# refers to an aggregate function in the .values() clause.


@testset "HAVING Clause Tests" begin

    @testset "Aggregate Alias Is Promoted To HAVING" begin
        # Logic: Validate that a filter using an aggregate alias is rendered in HAVING,
        # while non-aggregate predicates remain in WHERE.
        # Why: This protects the aggregate-alias promotion path from regressions.

        q = M.Result.objects.values(
            "constructorid__name",
            "win_count" => Count("resultid")
        )
        q.filter("positionorder" => 1)
        q.filter("win_count__@gt" => 100)

        inspection = PormG.QueryBuilder.inspect_query(q)
        sql_text = uppercase(inspection[:sql_text])

        where_range = findfirst("WHERE", sql_text)
        having_range = findfirst("HAVING", sql_text)

        @test where_range !== nothing
        @test having_range !== nothing

        where_start = first(where_range)
        having_start = first(having_range)
        @test where_start < having_start

        where_segment = sql_text[where_start:having_start-1]
        having_segment = sql_text[having_start:end]

        # The aggregate alias should not leak into WHERE.
        @test !occursin("WIN_COUNT", where_segment)
        # HAVING should contain the aggregate expression predicate.
        @test occursin("COUNT(", having_segment)
    end

    @testset "Basic HAVING with Count" begin
        # Logic: Find constructors that have participated in more than 500 races.
        # Expected SQL: SELECT constructorid__name, COUNT(resultid) as race_count ... GROUP BY ... HAVING COUNT(resultid) > 500
        # Why: Demonstrates the basic automatic promotion of aggregate filters to HAVING.
        
        q = M.Result.objects.values(
            "constructorid__name",
            "race_count" => Count("resultid")
        )
        q.filter("race_count__@gt" => 500)
        
        df = q |> DataFrame
        
        @test "Ferrari" in df.constructorid__name
        @test all(df.race_count .> 500)
    end

    @testset "HAVING with Sum and Multiple Filters" begin
        # Logic: Find drivers who have scored more than 1000 total points and scored them in races where they finished in the top 3.
        # Expected SQL: SELECT driverid__surname, SUM(points) as total_points ... WHERE positionorder <= 3 GROUP BY ... HAVING SUM(points) > 1000
        # Why: Shows interaction between WHERE (non-aggregate) and HAVING (aggregate) in the same query.
        
        q = M.Result.objects.values(
            "driverid__surname",
            "total_points" => Sum("points")
        )
        q.filter("positionorder__@lte" => 3)
        q.filter("total_points__@gt" => 1000)
        
        df = q |> DataFrame
        
        # Drivers like Hamilton, Vettel, Schumacher should be here
        @test size(df, 1) > 0
        @test all(df.total_points .> 1000)
        @test any(name -> name in df.driverid__surname, ["Hamilton", "Vettel", "Schumacher", "Alonso"])
    end

    @testset "HAVING with Average and Joins" begin
        # Logic: Find nationalites (drivers) that have an average finishing position better than 5 (lower is better).
        # Expected SQL: SELECT driverid__nationality, AVG(positionorder) as avg_pos ... GROUP BY ... HAVING AVG(positionorder) < 5
        # Why: Tests aggregates over joined fields with HAVING.
        
        q = M.Result.objects.values(
            "driverid__nationality",
            "avg_pos" => Avg("positionorder")
        )
        # We only care about finishers to avoid noise from DNFs
        q.filter("statusid__status" => "Finished")
        q.filter("avg_pos__@lt" => 10.0)
        
        df = q |> DataFrame
        insp = q |> inspect_query
        @info insp[:sql_text]

        if insp[:dialect] == :sqlite
            @test first(insp[:parameter_buckets][:having]) isa Number
            @test first(insp[:parameter_buckets][:having]) == 10.0
        end
        
        @test size(df, 1) > 0
        @test all(df.avg_pos .< 10.0)
    end

    @testset "HAVING with Max/Min" begin
        # Logic: Find races (years) where the highest points awarded was exactly 25.
        # Why: Validates other aggregate types in HAVING.
        
        q = M.Result.objects.values(
            "raceid__year",
            "max_points" => Max("points")
        )
        q.filter("max_points" => 25)
        
        df = q |> DataFrame
        
        @test size(df, 1) > 0
        @test all(df.max_points .== 25)
        # 25 points system started in 2010
        @test all(df.raceid__year .>= 2010)
    end

    @testset "HAVING with Aggregate Arithmetic (Sum/Count)" begin
        # Logic: Find constructors where (Sum of points / Count of results) > 5.
        # Why: Validates that FObject arithmetic (Sum / Count) produces a valid
        # FExpression with aggregate=true, correctly promoted to HAVING.

        q = M.Result.objects.values(
            "constructorid__name",
            "points_per_entry" => Sum("points") / Count("resultid")
        )
        q.filter("points_per_entry__@gt" => 5)

        df = q |> DataFrame

        @test size(df, 1) > 0
        @test all(df.points_per_entry .> 5)
    end

    @testset "HAVING with FK alias and aggregate alias" begin
        # Production code combines a joined-field alias in values() with a filter
        # on an aggregate alias. That belongs here because the regression is the
        # HAVING promotion, not basic selection.
        q = M.Result.objects
        q.values(
            "constructor" => "constructorid__name",
            "wins" => Count("resultid")
        )
        q.filter("positionorder" => 1)
        q.filter("wins__@gt" => 50)
        q.order_by("-wins")

        df = q |> DataFrame

        @test "constructor" in names(df)
        @test "wins" in names(df)
        @test all(df.wins .> 50)
        @test any(name -> name in df.constructor, ["Ferrari", "McLaren"])
    end

end
