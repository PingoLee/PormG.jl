# test/pg/test_sql_functions.jl
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
    df = q |> list |> DataFrame
    
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
        "round_val"    => Round(Value(10.555), 2),
        "max_val"      => Greatest("driverid", Value(100), Value(50)),
        "min_val"      => Least("driverid", Value(10))
    )
    q.filter("driverid" => 1)
    df = q |> list |> DataFrame
    
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
    @test df[1, :max_val] == 100
    @test df[1, :min_val] == 1
end

@testset "Range Filter Modifier" begin
    # Logic: Test the "__range" modifier which translates to SQL "BETWEEN".
    # Expected SQL: SELECT ... FROM ... WHERE "driverid" BETWEEN 1 AND 5
    # Why: Essential for filtering results within a specific span (dates or IDs).
    
    # Test with Vector
    q1 = M.Driver.objects.filter("driverid__@range" => [1, 5]).order_by("driverid")
    df1 = q1 |> list |> DataFrame
    @test size(df1, 1) == 5
    @test df1[1, :driverid] == 1
    @test df1[5, :driverid] == 5

    # Test with Tuple
    q2 = M.Driver.objects.filter("driverid__@range" => (10, 15)).order_by("driverid")
    df2 = q2 |> list |> DataFrame
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
    df = q |> list |> DataFrame
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
    df = q |> list |> DataFrame
    
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
    df = q |> list |> DataFrame
    
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
    df = q |> list |> DataFrame
    
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
    df = q |> list |> DataFrame
    
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
    df = q |> list |> DataFrame
    
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
    df = q |> list |> DataFrame
    
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
    df = q |> list |> DataFrame
    
    @test df[1, :birth_year] == 1985
    @test df[1, :birth_month] == 1
    @test df[1, :birth_day] == 7

    # Test complex date modifiers (Quarter)
    q_complex = M.Driver.objects.values("driverid", "q" => "dob__@quarter")
    q_complex.filter("surname" => "Hamilton")
    df_complex = q_complex |> list |> DataFrame
    @test df_complex[1, :q] == "1985-Q1"

    # Test filter modifiers
    q2 = M.Driver.objects.filter("dob__@year" => 1985, "dob__@month" => 1)
    df2 = q2 |> list |> DataFrame
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
        
        query = M.Result.objects
        query.filter("raceid__@year" => 2024,
           Q(
               F("raceid__date") > F("driverid__dob") + 30,
               F("raceid__date") <= F("driverid__dob") + 10957 # Using large number to match some data
            )
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
                            F("raceid__date") <= F("driverid__dob") + 10957
                        ),
                        then=1
                    ),
                    default=0
                )
            )
        )
        
        query.order_by("-raceid__year", "driverid__surname")
        query.limit(10)
        
        # # Test generation
        # sql = query |> show_query
        # @test contains(sql, "CASE")
        # @test contains(sql, ">")
        # @test contains(sql, "<=")
        # @test contains(sql, "interval") # Our F logic uses interval for date arithmetic
        
        # Test execution
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

        query |> show_query  # For debugging
        
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
end

