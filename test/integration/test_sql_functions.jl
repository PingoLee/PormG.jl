# test/integration/test_sql_functions.jl
# This test file validates SQL functions (aggregates, string, math, logic) and filter modifiers.
# Each test set explains the expected SQL and the logic being tested.

if !isdefined(Main, :PormG)
    include("common_setup.jl")
end

@testset "Aggregate Functions" begin
    # Logic: Test basic aggregates (Sum, Avg, Count, Max, Min).
    # Why: Core ORM functionality for data analysis.
    q = M.Result.objects
    q.values(
        "total_results" => Count("resultid"),
        "max_points"    => Max("points"),
        "min_points"    => Min("points"),
        "sum_points"    => Sum("points"),
        "avg_points"    => Avg("points")
    )
    q.filter("raceid" => 1) # Australian GP
    df = q |> DataFrame

    q |> show_query  # For debugging
    
    @test df[1, :total_results] > 0
    @test df[1, :max_points] >= 10.0
    @test df[1, :sum_points] > 0
end

@testset "Function Calls" begin
    # Logic: Test functions that require explicit function syntax (string, logic, extremes).
    # Why: These functions provide more control and clarity.
    q = M.Driver.objects
    q.values(
        "driverid",
        "forename",
        "lower_name"   => Lower("forename"),
        "upper_name"   => Upper("surname"),
        "name_len"     => Length("forename"),
        "trimmed_code" => Trim("code"),
        "ltrimmed"     => LTrim(Value("  test")),
        "rtrimmed"     => RTrim(Value("test  ")),
        "replace_val"  => Replace("nationality", "British", "UK"),
        "coalesce_val" => Coalesce(Value(nothing), "forename", Value("N/A")),
        "nullif_val"   => NullIf("forename", Value("Lewis")),
        "round_val"    => Round(Value(10.556), 2),
        "round_def"    => Round(Value(10.5)),
        "abs_val"      => Abs(Value(-10.5)),
        "max_val"      => Greatest("driverid", Value(100), Value(50)),
        "min_val"      => Least("driverid", Value(10))
    )
    q.filter("driverid" => 1)
    df = q |> DataFrame
    
    @test df[1, :lower_name] == "lewis"
    @test df[1, :upper_name] == "HAMILTON"
    @test df[1, :name_len] == 5
    @test df[1, :trimmed_code] == "HAM"
    @test df[1, :ltrimmed] == "test"
    @test df[1, :rtrimmed] == "test"
    @test df[1, :replace_val] == "UK"
    @test df[1, :coalesce_val] == "Lewis"
    @test df[1, :nullif_val] === missing || df[1, :nullif_val] === nothing
    @test df[1, :round_val] == 10.56
    @test df[1, :round_def] == 11.0 # SQLite ROUND(10.5) is 11.0
    @test df[1, :abs_val] == 10.5
    @test df[1, :max_val] == 100
    @test df[1, :min_val] == 1
end

@testset "Range Filter Modifier" begin
    # Logic: Test the "__range" modifier which translates to SQL "BETWEEN".
    # Expected SQL: SELECT ... FROM ... WHERE "driverid" BETWEEN 1 AND 5
    # Why: Essential for filtering results within a specific span (dates or IDs).
    
    # Test with Vector
    q1 = M.Driver.objects.filter("driverid__@range" => [1, 5]).order_by("driverid")
    df1 = q1 |> DataFrame
    @test size(df1, 1) == 5
    @test df1[1, :driverid] == 1
    @test df1[5, :driverid] == 5

    # Test with Tuple
    q2 = M.Driver.objects.filter("driverid__@range" => (10, 15)).order_by("driverid")
    df2 = q2 |> DataFrame
    @test size(df2, 1) == 6
    @test df2[1, :driverid] == 10
end

@testset "Greatest and Least" begin
    # Logic: Test variadic functions that pick extremes from multiple columns/values.
    # Why: In Julia, Vector invariance requires special handling in the ORM's type system.
    q = M.Driver.objects
    q.values(
        "driver_id" => "driverid",
        "max_val" => Greatest("driverid", Value(100), Value(50)),
        "min_val" => Least("driverid", Value(100), Value(50))
    )
    q.filter("driverid" => 1)
    df = q |> DataFrame
    @test df[1, :max_val] == 100
    @test df[1, :min_val] == 1
end

@testset "Mathematical Functions" begin
    # Logic: Validates math operations like floor, ceil, power, and sqrt.
    # Why: For PostgreSQL, we must ensure inputs are cast to ::numeric to match function signatures.
    q = M.Driver.objects
    q.values(
        "floor_val" => Floor(Value(10.7)),
        "ceil_val"  => Ceil(Value(10.2)),
        "sqrt_val"  => Round(Sqrt(Value(16.0)), 1),
        "power_val" => Power(Value(2), Value(3)),
        "mod_val"   => Mod(Value(10), Value(3)),
        "abs_val"   => Abs(Value(-5.5)),
        "exp_val"   => Round(Exp(Value(1.0)), 2),
        "ln_val"    => Round(Ln(Value(2.71828)), 1)
    )
    q.filter("driverid" => 1)
    df = q |> DataFrame
    
    @test df[1, :floor_val] == 10.0
    @test df[1, :ceil_val] == 11.0
    @test df[1, :sqrt_val] == 4.0
    @test df[1, :power_val] == 8.0
    @test df[1, :mod_val] == 1.0
    @test df[1, :abs_val] == 5.5
    @test Float64(df[1, :exp_val]) ≈ 2.72 atol=0.01
    @test df[1, :ln_val] == 1.0
end

@testset "Conditional & Case Functions" begin
    # Logic: Test Case/When logic for conditional SQL expressions.
    # Why: Allows complex logic to be executed on the database side.
    q = M.Driver.objects
    q.values(
        "driverid",
        "category" => Case([
            When(("driverid__@lte" => 5), then = Value("Top 5")),
            When(("driverid__@range" => [6, 10]), then = Value("6-10"))
        ], default = Value("Other"))
    )
    q.filter("driverid__@lte" => 15)
    q.order_by("driverid")
    df = q |> DataFrame

    insp = q |> inspect_query
    # @info insp[:sql_text]
    if insp[:dialect] == :sqlite
        @test insp[:parameters] == Any[5, "Top 5", 6, 10, "6-10", "Other", 15]
    end
    
    @test df[1, :category] == "Top 5"
    @test df[6, :category] == "6-10"
    @test df[11, :category] == "Other"
end

@testset "Casting & Concatenation" begin
    # Logic: Test explicit type casting and string concatenation.
    # Why: Useful for formatting output data for reports.
    q = M.Driver.objects
    q.values(
        "full_info" => Concat([
            "forename", 
            Value(" "), 
            "surname", 
            Value(" ("), 
            Cast("driverid", "text"), 
            Value(")")
        ])
    )
    q.filter("driverid" => 1)
    df = q |> DataFrame
    
    @test df[1, :full_info] == "Lewis Hamilton (1)"
end

@testset "Extraction & To_char" begin
    # Logic: Test explicit Extract and To_char functions.
    # Why: Provides more control over date/time formatting than standard modifiers.
    q = M.Driver.objects
    q.values(
        "extracted_year"  => Extract("dob", "YEAR"),
        "formatted_date" => To_char("dob", "DD/MM/YYYY")
    )
    q.filter("driverid" => 1)
    df = q |> DataFrame
    
    @test df[1, :extracted_year] == 1985
    @test df[1, :formatted_date] == "07/01/1985"
end

@testset "Advanced Nesting & Combined Functions" begin
    # Logic: Test nesting multiple functions (e.g., Lower(Trim(...))).
    # Why: Ensures the QueryBuilder can recursively process function objects.
    q = M.Driver.objects
    q.values(
        "driverid",
        "nested_val" => Lower(Trim(Upper(Value("  Lewis  ")))),
        "math_nest"  => Round(Sqrt(Abs(Value(-16.0))), 0)
    )
    q.filter("driverid" => 1)
    df = q |> DataFrame
    
    @test df[1, :nested_val] == "lewis"
    @test df[1, :math_nest] == 4.0
end

@testset "Special Date Functions (Quarter/Quadrimester)" begin
    # Logic: Test the high-level QUARTER and QUADRIMESTER functions.
    # Why: These are complex functions that use Case, When, and Concat internally.
    q = M.Driver.objects
    q.values(
        "driverid",
        "q_func"    => "dob__@quarter",
        "quad_func" => "dob__@quadrimester"
    )
    q.filter("surname" => "Hamilton")
    df = q |> DataFrame
    
    # Hamilton born 1985-01-07 -> Q1, Quad 1
    @test df[1, :q_func] == "1985-Q1"
    @test df[1, :quad_func] == "1985-Q1" # QUADRIMESTER also uses -Q in its current implementation
end

@testset "Date Functions & Modifiers" begin
    # Logic: Test date extraction features (Year, Month, Day) using "__@modifier" syntax.
    # Expected SQL: SELECT EXTRACT(YEAR FROM "dob") FROM "drivers" ...
    # Why: Native lookup-style syntax for date parts is a core PormG feature.
    
    # Test values extraction
    q = M.Driver.objects
    q.values(
        "driverid",
        "forename",
        "birth_year"  => "dob__@year",
        "birth_month" => "dob__@month",
        "birth_day"   => "dob__@day"
    )
    q.filter("surname" => "Hamilton")
    df = q |> DataFrame
    
    @test df[1, :birth_year] == 1985
    @test df[1, :birth_month] == 1
    @test df[1, :birth_day] == 7

    # Test complex date modifiers (Quarter)
    q_complex = M.Driver.objects.values("driverid", "q" => "dob__@quarter")
    q_complex.filter("surname" => "Hamilton")
    df_complex = q_complex |> DataFrame
    @test df_complex[1, :q] == "1985-Q1"

    # Test filter modifiers
    q2 = M.Driver.objects.filter("dob__@year" => 1985, "dob__@month" => 1)
    df2 = q2 |> DataFrame
    @test any(x -> x.surname == "Hamilton", eachrow(df2))
end

@testset "Null Checks (ISNULL)" begin
    # Logic: Test the @isnull operator for both TRUE and FALSE.
    # Why: Essential for finding records with missing or present data.
    
    # Check for non-null (nationality should not be null for most drivers)
    count_not_null = M.Driver.objects.filter("nationality__@isnull" => false).count()
    @test count_not_null > 800
    
    # Check for null (some drivers might not have a 'code' in the dataset)
    count_null = M.Driver.objects.filter("code__@isnull" => true).count()
    @test count_null >= 0 # Just verify it doesn't crash
end

@testset "Complex reporting scenarios" begin
    # Cleanup and setup
    # M.Result is the central table linking Drivers, Constructors and Races
    
    @testset "Case/When with nested F arithmetic and Q objects" begin
        # Scenario: Find results where the race happened more than 30 days after driver's DOB
        # but less than 200000 days (arbitrary example for testing arithmetic)
        
        # Note: In F1 dataset, races and drivers have a big gap, so 30 days is always true.
        # We just want to check if the SQL generates correctly and executes.
        
        query = M.Result.objects.filter("raceid__@year" => 2024,
           Q(
               F("raceid__date") > F("driverid__dob") + 30,
               F("raceid__date") <= F("driverid__dob") + 10957 # Using large number to match some data
            )
        );
        
        query.values(
            "raceid__year",
            "driverid__surname",
            "driverid__dob",
            "is_within_range" => Sum(
                Case(
                    When(
                        Q(
                            F("raceid__date") > F("driverid__dob") + 30,
                            F("raceid__date") <= F("driverid__dob") + 10957
                        ),
                        then=1
                    ),
                    default=0
                )
            )
        );
        
        query.order_by("-raceid__year", "driverid__surname");
        query.limit(10);
        
        # # Test generation
        # sql = query |> show_query
        # @test contains(sql, "CASE")
        # @test contains(sql, ">")
        # @test contains(sql, "<=")
        # @test contains(sql, "interval") # Our F logic uses interval for date arithmetic
        
        # Test execution
        # query |> show_query  # For debugging
        df = query |> DataFrame
        @test size(df, 1) == 10
        @test "is_within_range" in names(df)
        alonso_data = df[df.driverid__surname .== "Alonso", :]
        @test isempty(alonso_data) # More then 30 years old, should not match
        albon_data = df[df.driverid__surname .== "Albon", :]
        @test !isempty(albon_data) # More then 30 years old, should not match
        @test albon_data.is_within_range[1] == 24
    end

    @testset "Qor with __isnull and explicit values in When" begin
        # Scenario: Count results where status is either null or 1
        query = M.Result.objects
        query.values(
            "raceid__year",
            "statusid",
            "special_count" => Sum(
                Case(
                    When(
                        Qor(
                            "statusid" => 2,
                            "statusid" => 1
                        ),
                        then=1
                    ),
                    default=0
                )
            )
        )
        query.order_by("-raceid__year", "statusid")
        query.limit(5)
        
        df = query |> DataFrame
        @test size(df, 1) == 5
        @test "special_count" in names(df)
        @test df[1, :special_count] == 287
        @test df[2, :special_count] == 2
        @test df[3, :special_count] == 0
        

    end

    @testset "When with __@in operator" begin
        # Scenario: Filter by a list of IDs inside a Case/When
        lucky_positions = [1, 2, 3]
        query = M.Result.objects
        query.values(
            "driverid__surname",
            "podiums" => Sum(
                Case(
                    When("positionorder__@in" => lucky_positions, then=1),
                    default=0
                )
            )
        )
        query.order_by("-podiums")
        query.limit(5)

        insp = query |> inspect_query
        @info insp[:sql_text]
        
        df = query |> DataFrame
        @test size(df, 1) == 5
        @test "podiums" in names(df)
        @test df[1, :podiums] == 202
        @test df[1, :driverid__surname] == "Hamilton"
    end

    @testset "When with simple Pair (non-Q syntax)" begin
        # Scenario: Use When with a direct Pair instead of wrapping in Q()
        # Expected SQL: ... WHEN "driverid" = 1 THEN 1 ELSE 0 END ...
        # Why: Verify that single conditions work without Q wrapper
        query = M.Result.objects
        query.values(
            "driverid",
            "is_hamilton" => Sum(
                Case(
                    When("driverid" => 1, then=1),
                    default=0
                )
            )
        )
        query.order_by("driverid")
        query.limit(5)
        
        df = query |> DataFrame
        @test size(df, 1) > 0
        @test "is_hamilton" in names(df)
        # Hamilton (driverid=1) should have is_hamilton > 0
        @test df[1, :is_hamilton] == 356
    end

    @testset "When with operator modifier syntax" begin
        # Scenario: Use When with operator modifiers (__@gt, __@lte, etc.)
        # Expected SQL: ... WHEN "points" > 10 THEN 1 ELSE 0 END ...
        # Why: Verify that string-based operator syntax works in When conditions
        query = M.Result.objects
        query.values(
            "driverid__surname",
            "high_points_count" => Sum(
                Case(
                    When("points__@gt" => 10, then=1),
                    default=0
                )
            )
        )
        query.order_by("-high_points_count")
        query.limit(5)
        
        df = query |> DataFrame
        @test size(df, 1) > 0
        @test "high_points_count" in names(df)
        @test df[1, :high_points_count] > 0
    end

    @testset "When with date modifiers in filter" begin
        # Scenario: Use date extraction modifiers (__@year, __@month) in When conditions
        # Expected SQL: ... WHEN EXTRACT(YEAR FROM "date") = 2024 THEN 1 ELSE 0 END ...
        # Why: Verify that date functions work inside When
        query = M.Result.objects
        query.values(
            "raceid__year",
            "races_2024" => Sum(
                Case(
                    When("raceid__date__@year" => 2024, then=1),
                    default=0
                )
            )
        )
        query.order_by("-races_2024")
        query.limit(3)
        
        df = query |> DataFrame
        @test size(df, 1) > 0
        @test "races_2024" in names(df)
        @test df[1, :races_2024] > 0
    end

    @testset "Nested Case inside Case" begin
        # Scenario: Complex conditional logic with nested Case statements for numeric results
        # Expected SQL: CASE WHEN ... THEN ... ELSE CASE WHEN ... THEN ... END END
        # Why: Verify that Case functions can be nested for hierarchical logic
        query = M.Result.objects
        query.values(
            "driverid__surname",
            "complex_points" => Sum(
                Case(
                    [
                        When("points__@gt" => 15, then=3),
                        When("points__@gt" => 10, then=2),
                        When("points__@gt" => 0, then=1)
                    ],
                    default=0
                )
            )
        )
        query.order_by("driverid__surname")
        query.limit(3)
        
        df = query |> DataFrame
        @test size(df, 1) == 3
        @test "complex_points" in names(df)
    end

    @testset "Complex Qor with combined Q logic" begin
        # Scenario: Combine multiple Q objects inside Qor for sophisticated filtering
        # Expected SQL: ... OR (cond1 AND cond2) OR (cond3 AND cond4) ...
        # Why: Verify that Qor can handle combined AND conditions
        query = M.Result.objects
        query.values(
            "driverid__surname",
            "raceid__year",
            "special_results" => Sum(
                Case(
                    When(
                        Qor(
                            Q("points__@gt" => 15, "positionorder__@lte" => 3),  # High points AND podium
                            Q("points" => 0, "statusid" => 3)  # Zero points or specific status
                        ),
                        then=1
                    ),
                    default=0
                )
            )
        )
        query.order_by("-special_results")
        query.limit(5)
        
        df = query |> DataFrame
        @test size(df, 1) > 0
        @test "special_results" in names(df)
    end

    @testset "When with chained join in filter" begin
        # Scenario: Use deep join path (__model__field) inside When condition
        # Expected SQL: ... WHEN "circuit"."country" = 'Monaco' THEN 1 ELSE 0 END ...
        # Why: Verify that multi-level joins work in When conditions
        query = M.Result.objects
        query.values(
            "raceid__circuitid__name",
            "raceid__circuitid__country",
            "monaco_races" => Sum(
                Case(
                    When("raceid__circuitid__country" => "Monaco", then=1),
                    default=0
                )
            )
        )
        query.order_by("-monaco_races", "raceid__circuitid__name")
        query.limit(5)
        
        df = query |> DataFrame
        @test size(df, 1) > 0
        @test "monaco_races" in names(df)
        # Check if Monaco appears in results
        @test any(df.raceid__circuitid__country .== "Monaco")
        @test df[df.raceid__circuitid__country .== "Monaco", :monaco_races][1] > 0
    end

    @testset "Multiple When clauses with different operator types" begin
        # Scenario: Use various operators (@lte, @range, @isnull, __in) in different When clauses
        # Expected SQL: Multiple WHEN clauses with different operator styles - must return numeric type
        # Why: Verify that all operator types work interchangeably in When
        query = M.Result.objects
        query.values(
            "driverid__surname",
            "result_classification" => Sum(
                Case(
                    [
                        When("positionorder__@lte" => 3, then=3),  # Podium
                        When("positionorder__@range" => [4, 10], then=2),  # Points
                        When("statusid__@isnull" => false, then=1)  # Classified
                    ],
                    default=0
                )
            )
        )
        query.order_by("driverid__surname")
        query.limit(5)
        
        df = query |> DataFrame
        @test size(df, 1) == 5
        @test "result_classification" in names(df)
    end

    # @testset "Case with only default (no When clauses)" begin
    #     # Scenario: Use Case with just a default value (edge case)
    #     # Expected SQL: This should still generate valid SQL, even without WHEN
    #     # Why: Verify edge case handling and robustness
    #     query = M.Driver.objects
    #     query.values(
    #         "driverid",
    #         "forename",
    #         "constant_value" => Case([], default=Value("No Condition"))
    #     )
    #     query.filter("driverid__@lte" => 5)
        
    #     df = query |> DataFrame
    #     @test size(df, 1) == 5
    #     @test "constant_value" in names(df)
    #     @test all(df.constant_value .== "No Condition")
    # end

    @testset "When with F expression using comparison operators" begin
        # Scenario: Test F expressions with comparison operators in filter() context
        # Expected SQL: ... WHEN (F logic) THEN ... - demonstrating that F works inside filter
        # Why: Verify that F expressions are used for field-to-field comparisons, while string operators (__@) are for field-to-value
        query = M.Result.objects
        query.filter(
            Q(
                F("raceid__date") > F("driverid__dob") + 10950,  # Field-to-field comparison (F is here)
                "points__@gte" => 15  # Field-to-value uses string operators
            )
        )
        query.values(
            "driverid__surname",
            "raceid__year",
            "points",
            "points_gte_15" => Sum(
                Case(
                    When("points__@gte" => 15, then=1),  # String operator in When
                    default=0
                )
            )
        )
        query.order_by("driverid__surname")
        query.limit(5)
        
        df = query |> DataFrame
        @test size(df, 1) <= 5
        @test "points_gte_15" in names(df)
        @test all(df.points_gte_15 .>= 0)
    end

    @testset "Distinct Aggregates" begin
        # Logic: Test the 'distinct' parameter in aggregate functions.
        # Why: Ensures we can count unique values (e.g., how many unique constructors won).
        q = M.Result.objects
        q.values(
            "total_wins" => Count("resultid"),
            "unique_constructors" => Count("constructorid", distinct=true)
        )
        q.filter("positionorder" => 1) # Only winners
        df = q |> DataFrame
        
        # In history, multiple winners exist, but fewer constructors than total races won
        @test df[1, :total_wins] > df[1, :unique_constructors]
        @test df[1, :unique_constructors] > 10 # More than 10 brands won in F1 history
    end

    @testset "Having Clause (Aggregate Filtering)" begin
        # Logic: Test filtering results based on aggregated values.
        # Why: Essential for queries like "Teams with more than 100 wins".
        q = M.Result.objects
        q.values(
            "constructorid__name",
            "win_count" => Count("resultid")
        )
        q.filter("positionorder" => 1)
        # The filter on "win_count" should be automatically moved to HAVING because "win_count" 
        # is an alias for an aggregate in the SELECT clause.
        q.filter("win_count__@gt" => 100) 
        
        df = q |> DataFrame
        
        # Giants like Ferrari, McLaren, Williams, Mercedes, Red Bull should be here
        @test size(df, 1) >= 5 
        @test all(df.win_count .> 100)
        @test "Ferrari" in df.constructorid__name
    end

    @testset "Advanced F-Expression Math" begin
        # Logic: Test subtraction, multiplication, and division in F expressions.
        # Why: These common arithmetic operations must be correctly translated to SQL.
        q = M.Result.objects.values(
            "resultid",
            "points",
            "grid",
            "p_minus_one" => F("points") - 1,
            "p_times_two" => F("points") * 2,
            "p_div_two"   => F("points") / 2.0,
            "composite"   => (F("points") + F("grid")) / 2
        );
        q.filter("points__@gt" => 20);
        q.limit(5);
        df = q |> DataFrame
        
        @test size(df, 1) == 5
        @test df[1, :p_minus_one] == df[1, :points] - 1
        @test df[1, :p_times_two] == df[1, :points] * 2
        @test df[1, :p_div_two]   == df[1, :points] / 2.0
        @test df[1, :composite]   == (df[1, :points] + df[1, :grid]) / 2
    end

    @testset "Variadic Greatest/Least" begin
        # Logic: Test that Greatest/Least can handle more than 2-3 arguments.
        # Why: Verified variadic support in the type system.
        q = M.Driver.objects
        q.values(
            "max_of_many" => Greatest(Value(1), Value(5), Value(10), Value(2), Value(8)),
            "min_of_many" => Least(Value(100), Value(50), Value(25), Value(75), Value(10))
        )
        q.filter("driverid" => 1)
        df = q |> DataFrame
        
        @test df[1, :max_of_many] == 10
        @test df[1, :min_of_many] == 10
    end
end

@testset "PormGsuffix Operator Integration Tests" begin
    # Logic: Iterate through all operators defined in PormGsuffix and execute them against the database.
    # Why: End-to-end validation that each operator generates correct SQL and returns expected results.
    # Disclaimer: These are integration tests using the F1 dataset; results depend on the data.

    @testset "Comparison Operators (gt, gte, lt, lte, ne)" begin
        # Test: driverid > 100 (gt)
        q_gt = M.Driver.objects.filter("driverid__@gt" => 100).values("driverid").distinct().order_by("driverid")
        df_gt = q_gt |> DataFrame
        @test all(df_gt.driverid .> 100)
        @test size(df_gt, 1) == 761

        # Test: driverid >= 100 (gte)
        q_gte = M.Driver.objects.filter("driverid__@gte" => 100).values("driverid").distinct().order_by("driverid")
        df_gte = q_gte |> DataFrame
        @test all(df_gte.driverid .>= 100)
        @test size(df_gte, 1) == 762

        # Test: driverid < 50 (lt)
        q_lt = M.Driver.objects.filter("driverid__@lt" => 50).values("driverid").distinct().order_by("driverid")
        df_lt = q_lt |> DataFrame
        @test all(df_lt.driverid .< 50)

        # Test: driverid <= 50 (lte)
        q_lte = M.Driver.objects.filter("driverid__@lte" => 50).values("driverid").distinct().order_by("driverid")
        df_lte = q_lte |> DataFrame
        @test all(df_lte.driverid .<= 50)
        @test size(df_lte, 1) == 50

        # Test: driverid != 1 (ne)
        q_ne = M.Driver.objects.filter("driverid__@ne" => 1).values("driverid").distinct().order_by("driverid")
        df_ne = q_ne |> DataFrame
        @test all(df_ne.driverid .!= 1)
    end

    @testset "Range Operator (range / BETWEEN)" begin
        # Test: driverid BETWEEN 50 AND 100
        q_range = M.Driver.objects.filter("driverid__@range" => [50, 100]).order_by("driverid").values("driverid")
        df_range = q_range |> DataFrame
        @test all(df_range.driverid .>= 50 .&& df_range.driverid .<= 100)
        @test size(df_range, 1) == 51
    end

    @testset "IN and NOT IN Operators (in, nin)" begin
        # Test: driverid IN (1, 2, 3)  (in)
        lucky_ids = [1, 2, 3]
        q_in = M.Driver.objects.filter("driverid__@in" => lucky_ids).order_by("driverid").values("driverid")
        df_in = q_in |> DataFrame
        @test size(df_in, 1) == 3
        @test df_in[1, :driverid] == 1
        @test df_in[2, :driverid] == 2
        @test df_in[3, :driverid] == 3

        # Test: driverid NOT IN (1, 2, 3)  (nin)
        q_nin = M.Driver.objects.filter("driverid__@nin" => lucky_ids).order_by("driverid").values("driverid")
        df_nin = q_nin |> DataFrame
        @test all(df_nin.driverid .∉ Ref(lucky_ids))
        @test size(df_nin, 1) > 0
    end

    @testset "String Match Operators (contains, icontains, startswith, endswith)" begin
        # Test: surname LIKE '%ilton%' (contains)
        q_contains = M.Driver.objects.filter("surname__@contains" => "ilton").values("surname")
        df_contains = q_contains |> DataFrame
        @test all(occursin.("ilton", df_contains.surname))

        # Test: surname ILIKE '%HAM%' (case-insensitive contains)
        q_icontains = M.Driver.objects.filter("surname__@icontains" => "HAM").values("surname")
        df_icontains = q_icontains |> DataFrame
        @test all(occursin.("HAM", uppercase.(df_icontains.surname)))

        # Test: nationality LIKE 'British%' (startswith)
        q_startswith = M.Driver.objects.filter("nationality__@startswith" => "British").values("nationality")
        df_startswith = q_startswith |> DataFrame
        if size(df_startswith, 1) > 0
            @test all(startswith.(df_startswith.nationality, "British"))
        end

        # Test: code LIKE '%AM' (endswith)
        q_endswith = M.Driver.objects.filter("code__@endswith" => "AM").values("code")
        df_endswith = q_endswith |> DataFrame
        @test all(endswith.(df_endswith.code, "AM"))
    end

    @testset "NULL Check Operator (isnull)" begin
        # Test: code IS NOT NULL  (isnull => false)
        q_not_null = M.Driver.objects.filter("code__@isnull" => false).values("code")
        df_not_null = q_not_null |> DataFrame
        @test all(.!(ismissing.(df_not_null.code)) .& (df_not_null.code .!= ""))

        # Test: code IS NULL  (isnull => true)
        q_null = M.Driver.objects.filter("code__@isnull" => true)
        df_null = q_null |> DataFrame
        # Some drivers may not have a code; if the query returns results, verify they're null
        if size(df_null, 1) > 0
            # At least some should be missing or empty
            @test any(ismissing.(df_null.code))
        end
    end

    @testset "Exact Equality (default operator without suffix)" begin
        # Test: driverid = 1  (implicit = operator)
        q_exact = M.Driver.objects.filter("driverid" => 1).values("driverid", "forename")
        df_exact = q_exact |> DataFrame
        @test size(df_exact, 1) == 1
        @test df_exact[1, :driverid] == 1
        @test df_exact[1, :forename] == "Lewis"
    end

    @testset "Combined operator filtering (multiple filters)" begin
        # Test: Multiple operators in a single query
        q_multi = M.Driver.objects.filter(
            "driverid__@gt" => 10,
            "driverid__@lte" => 50,
            "nationality__@icontains" => "British"
        ).values("driverid", "nationality").order_by("driverid")
        df_multi = q_multi |> DataFrame
        @test all(df_multi.driverid .> 10 .&& df_multi.driverid .<= 50)
        if size(df_multi, 1) > 0
            @test all(contains.(uppercase.(df_multi.nationality), "BRITISH"))
        end
    end
end

@testset "SQL Functions wrapping F() arithmetic expressions" begin
    # This test set covers the feature gap where FExpression (SQLTypeF) could not be
    # used as the column argument of SQL functions like Round, Abs, Floor, Ceil, etc.
    #
    # Root cause fixed: FObject.column union type now includes SQLTypeF so any arithmetic
    # expression produced by F() operators is accepted as a function argument.
    #
    # Pattern being tested: Round(F("field") * scalar, precision)
    #                        Abs(F("field") - scalar)
    #                        Floor / Ceil wrapping F arithmetic
    #                        Aggregate function wrapping FExpression (e.g. Round(Sum("x") / Count("y"), n))
    #                        Nesting: Round(Abs(F("field") - scalar), precision)

    @testset "Round wrapping F arithmetic" begin
        # Scenario: Project a rounded 10% bonus on race points.
        # Expected SQL shape: ROUND((T."points" * ?), ?)
        # The raw arithmetic value F("points") * 1.1 and its rounded counterpart are
        # both projected so we can verify the relationship in Julia.
        q = M.Result.objects
        q.values(
            "resultid",
            "points",
            "raw_bonus"    => F("points") * 1.1,
            "round_bonus2" => Round(F("points") * 1.1, 2),
            "round_bonus0" => Round(F("points") * 1.1)
        )
        q.filter("points__@gt" => 0.0)
        q.order_by("resultid")
        q.limit(10)

        insp = q |> inspect_query
        # @info insp[:sql_text]

        df = q |> DataFrame
        @test size(df, 1) == 10
        @test "round_bonus2" in names(df)
        @test "round_bonus0" in names(df)

        # Round to 2 decimal places must equal Julia-side rounding of the raw value.
        @test all(eachrow(df)) do row
            expected2 = round(row.raw_bonus, digits=2)
            expected0 = round(row.raw_bonus, digits=0)
            isapprox(Float64(row.round_bonus2), expected2; atol=1e-6) &&
            isapprox(Float64(row.round_bonus0), expected0; atol=1e-6)
        end
    end

    @testset "Abs wrapping F arithmetic" begin
        # Scenario: Compute absolute deviation from 10 points for every scored result.
        # Expected SQL shape: ABS((T."points" - ?))
        q = M.Result.objects
        q.values(
            "resultid",
            "points",
            "deviation" => Abs(F("points") - 10.0)
        )
        q.filter("points__@gt" => 0.0)
        q.order_by("resultid")
        q.limit(10)

        df = q |> DataFrame
        @test size(df, 1) == 10
        @test "deviation" in names(df)

        @test all(eachrow(df)) do row
            isapprox(Float64(row.deviation), abs(row.points - 10.0); atol=1e-6)
        end
    end

    @testset "Floor and Ceil wrapping F arithmetic" begin
        # Scenario: Floor / Ceil the halved grid position so we can bucket drivers per lap.
        # Expected SQL shape: FLOOR((T."grid" / ?))  and  CEIL((T."grid" / ?))
        q = M.Result.objects
        q.values(
            "resultid",
            "grid",
            "floor_half" => Floor(F("grid") / 2.0),
            "ceil_half"  => Ceil(F("grid") / 2.0)
        )
        q.filter("grid__@gt" => 0)
        q.order_by("resultid")
        q.limit(10)

        df = q |> DataFrame
        @test size(df, 1) == 10
        @test "floor_half" in names(df)
        @test "ceil_half"  in names(df)

        @test all(eachrow(df)) do row
            Float64(row.floor_half) == floor(row.grid / 2.0) &&
            Float64(row.ceil_half)  == ceil(row.grid / 2.0)
        end
    end

    @testset "Aggregate expression wrapped in Round" begin
        # Scenario: Average points per result, rounded to 1 decimal place.
        # Sum("points") / Count("resultid") produces an FExpression (field_name=FObject, ...),
        # and Round(that_expression, 1) must now accept it via the fixed FObject.column type.
        #
        # Expected SQL shape: ROUND((SUM(T."points") / COUNT(T."resultid")), ?)
        q = M.Driver_standings.objects
        q.values(
            "driverid",
            "total_points"  => Sum("points"),
            "total_entries" => Count("driverstandingsid"),
            "avg_pts_round" => Round(Sum("points") / Count("driverstandingsid"), 1)
        )
        q.filter("raceid__year" => 2021)
        q.order_by("-total_points")
        q.limit(5)

        df = q |> DataFrame
        @test size(df, 1) == 5
        @test "avg_pts_round" in names(df)

        @test all(eachrow(df)) do row
            expected = round(row.total_points / row.total_entries, digits=1)
            isapprox(Float64(row.avg_pts_round), expected; atol=0.05)
        end
    end

    @testset "Nested: Round wrapping Abs wrapping F arithmetic" begin
        # Scenario: Compound nesting — first take the absolute deviation from 12.5, then round it.
        # This validates that FExpression flows through multiple layers of FObject.column.
        # Expected SQL shape: ROUND(ABS((T."points" - ?)), ?)
        q = M.Result.objects
        q.values(
            "resultid",
            "points",
            "rounded_dev" => Round(Abs(F("points") - 12.5), 1)
        )
        q.filter("points__@gt" => 0.0)
        q.order_by("resultid")
        q.limit(10)

        df = q |> DataFrame
        @test size(df, 1) == 10
        @test "rounded_dev" in names(df)

        @test all(eachrow(df)) do row
            expected = round(abs(row.points - 12.5), digits=1)
            isapprox(Float64(row.rounded_dev), expected; atol=0.1)
        end
    end

    @testset "F expression as column of Lower / Upper (string coercion path)" begin
        # Scenario: Lower / Upper must also accept FExpression for completeness, even though
        # calling string functions on numeric fields is not typical usage. We verify the
        # type acceptance by wrapping a Cast-produced expression.
        # Expected SQL shape: LOWER(CAST((T."driverid")::text AS text))  (PostgreSQL)
        #                      LOWER(CAST(T."driverid" AS text))          (SQLite)
        q = M.Driver.objects
        q.values(
            "driverid",
            "lower_cast" => Lower(Cast(F("driverid"), "text"))
        )
        q.filter("driverid__@lte" => 3)
        q.order_by("driverid")

        df = q |> DataFrame
        @test size(df, 1) == 3
        @test "lower_cast" in names(df)
        # driverid 1, 2, 3 cast to text and lowercased
        @test df[1, :lower_cast] == "1"
        @test df[2, :lower_cast] == "2"
        @test df[3, :lower_cast] == "3"
    end

    @testset "Joined-path SQLField inputs remain accepted by helpers" begin
        # Scenario: helper constructors should still accept SQLField carrying joined paths,
        # not just direct field names or F expressions. This protects against narrowing the
        # helper signatures beyond what the query builder already knows how to render.
        q = M.Result.objects
        q.values(
            "resultid",
            "surname_raw" => "driverid__surname",
            "code_raw" => "driverid__code",
            "year_raw" => "raceid__year",
            "surname_lower" => Lower(PormG.QueryBuilder.SQLField("driverid__surname")),
            "code_trimmed" => Trim(PormG.QueryBuilder.SQLField("driverid__code")),
            "year_text" => Cast(PormG.QueryBuilder.SQLField("raceid__year"), "text")
        )
        q.filter("driverid__code__@isnull" => false)
        q.order_by("resultid")
        q.limit(10)

        df = q |> DataFrame
        @test size(df, 1) == 10
        @test "surname_lower" in names(df)
        @test "code_trimmed" in names(df)
        @test "year_text" in names(df)

        @test all(eachrow(df)) do row
            row.surname_lower == lowercase(row.surname_raw) &&
            row.code_trimmed == strip(row.code_raw) &&
            row.year_text == string(row.year_raw)
        end
    end

    @testset "Extract and To_char accept SQLField and F inputs" begin
        # Scenario: Extract/To_char should be consistent with the other helper constructors
        # and accept both SQLField(joined path) and F(date_field) inputs.
        q = M.Result.objects
        q.values(
            "resultid",
            "race_date_raw" => "raceid__date",
            "race_year_from_field" => Extract(PormG.QueryBuilder.SQLField("raceid__date"), "YEAR"),
            "race_date_fmt_field" => To_char(PormG.QueryBuilder.SQLField("raceid__date"), "YYYY-MM-DD"),
            "race_year_from_f" => Extract(F("raceid__date"), "YEAR"),
            "race_date_fmt_f" => To_char(F("raceid__date"), "YYYY-MM-DD")
        )
        q.order_by("resultid")
        q.limit(10)

        df = q |> DataFrame
        @test size(df, 1) == 10

        @test all(eachrow(df)) do row
            date_str = string(row.race_date_raw)[1:10]
            expected_year = parse(Int, date_str[1:4])
            row.race_year_from_field == expected_year &&
            row.race_year_from_f == expected_year &&
            row.race_date_fmt_field == date_str &&
            row.race_date_fmt_f == date_str
        end
    end
end

@testset "#74 Aggregate fan-out guard" begin
    # Logic: COUNT/SUM/AVG over a column a to-many join (reverse FK / M2M) row-multiplies must RAISE the
    #        #74 guard *specifically* (cause-checked, not just any ArgumentError); aggregating the
    #        to-many table's OWN column under a single to-many returns the CORRECT recomputed value;
    #        MAX/MIN and distinct=true are exempt; two to-many joins (n>=2), M2M, and un-attributable
    #        expressions raise; a plain aggregate is correct and unaffected.
    # Why: a base/parent column aggregated under a to-many join returns a confidently-wrong number
    #      (verified 36x inflation on driver_standings). Fail-loud guard for issue #74.

    # Returns the thrown error (or nothing). is_fanout confirms it is the #74 guard, so an unrelated
    # ArgumentError (e.g. a bad field path) cannot masquerade as a passing raise.
    fanout_err(f) = try; f(); nothing; catch e; e; end
    is_fanout(e)  = e isa ArgumentError && occursin("fan-out", e.msg)

    did = 1  # F1 dataset: driver 1 (Hamilton) has many driver_standings rows.

    # CASE B — base-table pk under a to-many join → inflated → raise (cause-checked).
    qB = M.Driver.objects
    qB.values("nationality", "n" => Count("driverid"))
    qB.filter("driver_standings__position__@gte" => 1)
    @test is_fanout(fanout_err(() -> (qB |> DataFrame)))

    # SUM / AVG over a BASE column under a to-many must also raise — the guard is not COUNT-only.
    qSum = M.Driver.objects
    qSum.values("nationality", "s" => Sum("number"))     # `number` is a base Driver column
    qSum.filter("driver_standings__position__@gte" => 1)
    @test is_fanout(fanout_err(() -> inspect_query(qSum)))

    qAvg = M.Driver.objects
    qAvg.values("nationality", "a" => Avg("number"))
    qAvg.filter("driver_standings__position__@gte" => 1)
    @test is_fanout(fanout_err(() -> inspect_query(qAvg)))

    # CASE A — aggregate the to-many table's OWN column (single to-many) → allowed AND correct.
    qA = M.Driver.objects
    qA.values("driverid", "n" => Count("driver_standings__driverstandingsid"))
    qA.filter("driverid" => did)
    dfA = qA |> DataFrame
    expectedA = M.Driver_standings.objects.filter("driverid" => did).count()
    @test expectedA > 0                                  # guard against a vacuous 0 == 0
    @test nrow(dfA) == 1 && dfA[1, :n] == expectedA       # recomputed value, not just "it ran"

    # CASE A' — related column AND a filter on the SAME relation must NOT raise, and stay correct. The
    #           join is built twice (cache + real); the guard derives from the deduped row_join.
    qAp = M.Driver.objects
    qAp.values("driverid", "n" => Count("driver_standings__driverstandingsid"))
    qAp.filter("driverid" => did, "driver_standings__position__@gte" => 1)
    dfAp = qAp |> DataFrame
    expectedAp = M.Driver_standings.objects.filter("driverid" => did, "position__@gte" => 1).count()
    @test (nrow(dfAp) == 1 ? dfAp[1, :n] : 0) == expectedAp

    # MAX over a to-many column is immune to duplication → allowed AND equals the true max.
    qMax = M.Driver.objects
    qMax.values("driverid", "m" => Max("driver_standings__points"))
    qMax.filter("driverid" => did)
    pts = (M.Driver_standings.objects.filter("driverid" => did).values("points") |> DataFrame).points
    @test (qMax |> DataFrame)[1, :m] == maximum(pts)

    # MIN is exempt too (symmetric to MAX) → allowed AND equals the true min.
    qMin = M.Driver.objects
    qMin.values("driverid", "m" => Min("driver_standings__points"))
    qMin.filter("driverid" => did)
    @test (qMin |> DataFrame)[1, :m] == minimum(pts)

    # distinct=true → renders COUNT(DISTINCT …) and counts the single grouped driver once.
    qDist = M.Driver.objects
    qDist.values("driverid", "n" => Count("driverid", distinct=true))
    qDist.filter("driverid" => did, "driver_standings__position__@gte" => 1)
    @test occursin("COUNT(DISTINCT", inspect_query(qDist)[:sql_text])   # cause: opt-in rendered
    @test (qDist |> DataFrame)[1, :n] == 1

    # COUNT(*) under a to-many join → inflated → raise (cause-checked).
    qStar = M.Driver.objects
    qStar.values("nationality", "n" => Count("*"))
    qStar.filter("driver_standings__position__@gte" => 1)
    @test is_fanout(fanout_err(() -> (qStar |> DataFrame)))

    # n >= 2 — aggregating ONE many-side column while a SECOND to-many relation is also joined still
    #          inflates (the grains multiply), so even the many-side aggregate must raise.
    qN2 = M.Driver.objects
    qN2.values("driverid", "n" => Count("driver_standings__driverstandingsid"))
    qN2.filter("lap_times__lap__@gte" => 1)              # second reverse to-many relation
    @test is_fanout(fanout_err(() -> inspect_query(qN2)))

    # Many-to-many — counting the BASE row while joining an M2M relation inflates → raise; counting the
    # M2M-related table's own column (single to-many) is allowed. Build-level (needs no M2M data).
    qM2M = M.M2m_driver_endorsement_scratch.objects
    qM2M.values("driverref", "n" => Count("id"))
    qM2M.filter("sponsors__name__@icontains" => "x")
    @test is_fanout(fanout_err(() -> inspect_query(qM2M)))

    qM2Mok = M.M2m_driver_endorsement_scratch.objects
    qM2Mok.values("driverref", "n" => Count("sponsors__id"))
    @test fanout_err(() -> inspect_query(qM2Mok)) === nothing   # related-col M2M aggregate is fine

    # Ambiguous — an aggregate over a multi-column expression cannot be attributed to one table, so the
    # guard conservatively raises under a to-many rather than risk a silent wrong number.
    qAmb = M.Driver.objects
    qAmb.values("nationality", "s" => Sum(F("driver_standings__points") + F("driver_standings__wins")))
    qAmb.filter("driver_standings__position__@gte" => 1)
    @test is_fanout(fanout_err(() -> inspect_query(qAmb)))

    # Forward FK (to-one) join present → NOT a fan-out → guard must allow. This is the key
    # discrimination: a to-one join must never be marked to-many. Counts stay correct.
    qFk = M.Result.objects
    qFk.values("constructorid__name", "n" => Count("resultid"))
    qFk.filter("raceid" => 1)
    @test fanout_err(() -> inspect_query(qFk)) === nothing            # to-one join does not trip the guard
    dfFk = qFk |> DataFrame
    @test sum(dfFk.n) == M.Result.objects.filter("raceid" => 1).count()  # per-constructor counts sum to the race total

    # No to-many join (plain aggregate) → unaffected AND correct.
    qPlain = M.Result.objects
    qPlain.values("raceid", "n" => Count("resultid"))
    qPlain.filter("raceid" => 1)
    @test (qPlain |> DataFrame)[1, :n] == M.Result.objects.filter("raceid" => 1).count()
end

