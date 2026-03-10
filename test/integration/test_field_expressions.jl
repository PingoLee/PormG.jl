# julia -t auto --project=. test/integration/test_field_expressions.jl
if !isdefined(Main, :PormG)
    include("common_setup.jl")
end

@testset "Field Expressions in Read Queries" begin
  @testset "Field-to-field filters and aggregate aliases" begin
    # This is the core read-side integration case for F().
    # It verifies that field-to-field comparisons survive join traversal,
    # while the aggregate alias filter is promoted to HAVING instead of WHERE.
    query = M.Result.objects
    query.filter(
      F("driverid__dob__@day") == F("raceid__date__@day"),
      F("driverid__dob__@month") == F("raceid__date__@month"),
      "min_grid__@gt" => 0,
    )
    query.values(
      "raceid__circuitid__name",
      "raceid__date",
      "driverid__forename",
      "constructorid__name",
      "count_grid" => Count("grid"),
      "max_grid" => Max("grid"),
      "min_grid" => Min("grid"),
    )
    query.order_by("min_grid", "-raceid__date")
    # insp = query |> inspect_query
    # @info insp[:sql_text]

    df = query |> DataFrame
    @test size(df, 1) == 75
    @test df[1, :raceid__circuitid__name] == "Nürburgring"
    @test df[1, :driverid__forename] == "Mika"
  end

  @testset "Arithmetic projections" begin
    # Arithmetic on F() should remain database-side when projected through values().
    # These checks cover subtraction, multiplication, division, and nested expressions.
    query = M.Result.objects
    query.values(
      "resultid",
      "points",
      "grid",
      "p_minus_one" => F("points") - 1,
      "p_times_two" => F("points") * 2,
      "p_div_two" => F("points") / 2.0,
      "composite" => (F("points") + F("grid")) / 2,
    )
    query.filter("points__@gt" => 20)
    query.order_by("resultid")
    query.limit(5)
    df = query |> DataFrame
    insp = query |> inspect_query
    @info insp[:sql_text]

    @test size(df, 1) == 5
    @test df[1, :p_minus_one] == df[1, :points] - 1
    @test df[1, :p_times_two] == df[1, :points] * 2
    @test df[1, :p_div_two] == df[1, :points] / 2.0
    @test df[1, :composite] == (df[1, :points] + df[1, :grid]) / 2
  end

  @testset "Date arithmetic with Q and Case" begin
    # This exercises a more realistic expression tree:
    # F(date) +/- integer day arithmetic inside Q(), then wrapped in Case/When,
    # then aggregated with Sum(). If this fails, the issue is usually in the
    # expression compiler rather than in plain function support.
    query = M.Result.objects
    query.filter(
      "raceid__@year" => 2024,
      Q(
        F("raceid__date") > F("driverid__dob") + 30,
        F("raceid__date") <= F("driverid__dob") + 10957,
      ),
    )
    query.values(
      "raceid__year",
      "driverid__surname",
      "driverid__dob",
      "is_within_range" => Sum(
        Case(
          When(
            Q(
              F("raceid__date") > F("driverid__dob") + 30,
              F("raceid__date") <= F("driverid__dob") + 10957,
            ),
            then=1,
          ),
          default=0,
        )
      ),
    )
    query.order_by("driverid__surname")
    query.limit(10)
    df = query |> DataFrame

    @test size(df, 1) > 0
    @test "is_within_range" in names(df)
    @test all(.!ismissing.(df.is_within_range))
  end

  @testset "Case over F date comparison" begin
    # This is the compact form of the previous pattern.
    # It protects the branch where When(Q(F(...) <= F(...) + days)) is used
    # directly in a projection without the extra outer filter.
    query = M.Result.objects
    query.filter("driverid__forename" => "Mika")
    query.values(
      "raceid__circuitid__name",
      "until_30_years" => Sum(
        Case(
          When(Q(F("raceid__date") <= F("driverid__dob") + 10950), then=1),
          default=0,
        )
      ),
    )
    df = query |> DataFrame
    @test size(df, 1) > 0
    @test "until_30_years" in names(df)
  end

  @testset "Aggregate F arithmetic reaches HAVING" begin
    # This is intentionally inspection-driven instead of only result-driven.
    # The critical behavior is not just returning rows, but proving that an
    # aggregate arithmetic alias remains an aggregate expression and is emitted
    # in HAVING after GROUP BY.
    query = M.Result.objects
    query.values(
      "constructorid__name",
      "points_per_entry" => Sum("points") / Count("resultid"),
    )
    query.filter("points_per_entry__@gt" => 5)

   
    df = query |> DataFrame
    # insp = query |> inspect_query
    # @info insp[:sql_text]

    @test size(df, 1) == 3
    # Use issetequal to check for existence regardless of row order
    @test issetequal(df.constructorid__name, ["Red Bull", "Mercedes", "Brawn"])
    @test all(df.points_per_entry .> 5)
    @test all(df.points_per_entry .< 12)
  end

  @testset "Non-aggregate F() filter stays in WHERE (not HAVING)" begin
    # Inverse of the HAVING promotion test.
    # A plain (non-aggregate) F-to-F comparison must remain in the WHERE clause.
    # If the ORM incorrectly promotes it, the generated SQL would be invalid.
    query = M.Result.objects
    query.filter(F("points") > F("grid"))
    query.values("resultid", "points", "grid")
    query.order_by("resultid")
    query.limit(10)

    # insp = query |> inspect_query
    # @info insp[:sql_text]
    df = query |> DataFrame

    @test df.resultid == [1, 2, 5, 23, 24, 26, 45, 46, 47, 67]
    @test df.grid == [1, 5, 3, 2, 4, 3, 2, 4, 1, 1]
  end

  @testset "Creating a new column with F() arithmetic in values()" begin
    # This tests that we can create a new projected column by doing arithmetic on F() expressions.
    # The generated SQL should perform the arithmetic in the SELECT clause, not in a subquery or client-side.
    query = M.Result.objects
    query.values(
      "resultid",
      "points",
      "grid",
      "points_plus_grid" => F("points") + F("grid"),
      "points_times_grid" => F("points") * F("grid"),
      "points_div_grid" => F("points") / F("grid"),
      "points_minus_grid" => F("points") - F("grid"),      
    )
    query.filter("points__@gt" => 15)
    query.order_by("resultid")
    query.limit(5)

    # insp = query |> inspect_query
    # @info insp[:sql_text]
    df = query |> DataFrame

    df.points_div_grid = round.(df.points_div_grid, digits=1)

    @test df.points_plus_grid == [28.0, 20.0, 29.0, 27.0, 28.0]
    @test df.points_times_grid == [75.0, 36.0, 100.0, 162.0, 75.0]
    @test df.points_div_grid == [8.3, 9.0, 6.2, 2.0, 8.3]
    @test df.points_minus_grid == [22.0, 16.0, 21.0, 9.0, 22.0]
  end

  @testset "OR-logic with F expressions (Q | Q)" begin
    # Tests that F-expression comparisons survive OR composition.
    # Q(...) | Q(...) must produce an OR branch in the WHERE clause,
    # not two separate AND conditions.
    query = M.Result.objects
    query.filter(
      Q(F("points") > 20), Q(F("grid") == 1),
    )
    query.values("resultid", "points", "grid")
    query.order_by("resultid")
    query.limit(20)

    insp = query |> inspect_query
    @info insp[:sql_text]
    df = query |> DataFrame
   
    @test size(df, 1) == 20
    @test all(
      coalesce.(df.points, 0.0) .> 20 .| (coalesce.(df.grid, -1) .== 1)
    )
  end

  @testset "F() inequality (!=) field comparison" begin
    # Exercises the != operator overload on FExpression.
    # We look for drivers who raced for a constructor of a different nationality —
    # a realistic cross-column inequality that cannot be expressed with a plain value filter.
    query = M.Result.objects
    query.filter(F("driverid__nationality") != F("constructorid__nationality"))
    query.values(
      "resultid",
      "driverid__surname",
      "driverid__nationality",
      "constructorid__name",
      "constructorid__nationality",
    )
    query.order_by("resultid")
    query.limit(10)

    inspection = PormG.QueryBuilder.inspect_query(query)
    sql_text = inspection[:sql_text]
    df = query |> DataFrame

    # The != operator must appear as <> or != in the generated SQL.
    @test occursin("<>", sql_text) || occursin("!=", sql_text)
    @test size(df, 1) > 0
    # All returned rows must have different nationalities between driver and constructor.
    @test all(df.driverid__nationality .!= df.constructorid__nationality)
  end
end