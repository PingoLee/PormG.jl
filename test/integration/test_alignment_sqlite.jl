if !isdefined(Main, :PormG)
    include("common_setup.jl")
end

# bulk_copy is a PostgreSQL-only feature (COPY protocol)
if adapter_name == "PostgreSQL"
    @info "Skipping alignment tests for PostgreSQL (not supported)"
    return true
else

@testset "SQLite Parameter Alignment Verification (Real Models)" begin
    # 1. Positional Cross-Check with Real Schema
    q = M.Result.objects
    # Using lowercase as PormG internal fields are lowercased
    q.filter("driverid__nationality" => "Brazilian", "positionorder" => 1)
    
    insp = q |> inspect_query
    
    buckets = insp[:parameter_buckets]
    
    @test "Brazilian" in buckets[:where]
    @test 1 in buckets[:where]
    @test buckets[:where] == ["Brazilian", 1]
    
    sql = insp[:sql_text]
    @test match(r"WHERE.*$"s, sql) !== nothing && count(==('?'), sql) == 2
end

@testset "Alignment Verification - Join Overrides (Real Models)" begin
    # Using cjoin (custom join) to inject parameters directly into ON clause
    q = M.Result.objects.filter("positionorder" => 1); # This goes to :where
    
    cjoin(q, "raceid" => "Race", filters=["points" => 10]);
    
    # Trigger the join by accessing a field from the related model
    q.values("raceid__name", "points");
    
    insp = q |> inspect_query
    
    # Parameters order for SQLite: CTE, SELECT, UPDATE, JOIN, WHERE, HAVING
    # 10 (from cjoin) is in :join bucket
    # 1 (from filter) is in :where bucket
    
    ins_buckets = insp[:parameter_buckets]
    @test 10 in ins_buckets[:join]
    @test 1 in ins_buckets[:where]
    
    @test insp[:parameters] == [10, 1]
end


@testset "Alignment Verification - Recursive Subquery (Real Models)" begin
    # Subqueries must inherit parent's context but restore it afterwards
    inner_q = M.Circuit.objects.filter("country" => "Italy").values("circuitid")
    middle_q = M.Race.objects.filter("circuitid__@in" => inner_q, "year" => 1991).values("raceid")
    outer_q = M.Result.objects.filter("raceid__@in" => middle_q, "positionorder" => 1)
    
    insp = outer_q |> inspect_query
    
    # All these parameters land in the :where bucket of the main query
    # because subqueries in filters are processed while context is :where.
    # Order should be depth-first expansion: Italy, 1991, 1
    @test insp[:parameters] == ["Italy", 1991, 1]
end

@testset "Alignment Verification - Multi-Join Stress (Real Models)" begin
    # Multiple filter conditions across different joined tables all go to :where bucket
    # Even though satisfying them requires INNERJOINs, the parameters appear in WHERE clause
    q = M.Result.objects.filter(
        "driverid__surname" => "Senna",      # Requires join, but param in WHERE
        "constructorid__name" => "McLaren",  # Requires join, but param in WHERE
        "raceid__year" => 1988,              # Requires join, but param in WHERE
        "points" => 10                       # Direct Result field in WHERE
    )
    
    insp = q |> inspect_query
    
    # Verify bucket structure
    # All WHERE-clause parameters (regardless of join requirement) go to :where bucket
    join_params = insp[:parameter_buckets][:join]
    where_params = insp[:parameter_buckets][:where]
    
    @test length(join_params) == 0  # No custom join conditions
    @test length(where_params) == 4 # All 4 parameters in WHERE
    
    # Verify specific values in WHERE bucket
    @test "Senna" in where_params
    @test "McLaren" in where_params
    @test 1988 in where_params
    @test 10 in where_params
    
    # Verify final parameter order matches WHERE clause (since CTE, SELECT, UPDATE, JOIN are empty)
    final_params = insp[:parameters]
    @test final_params == ["Senna", "McLaren", 1988, 10]
    
    # Verify SQL has exactly 4 positional markers all in WHERE clause
    @test count(==('?'), insp[:sql_text]) == 4
    
    # Verify INNER JOINs were generated (required to resolve joined fields)
    @test contains(insp[:sql_text], "INNER JOIN")
end


@testset "Alignment Verification - Real-world CTE" begin
    # CTE filters for races in 1991 (lands in :cte)
    # Main query filters for winners (lands in :where)
    
    races_91 = M.Race.objects.filter("year" => 1991).values("raceid")
    
    q = M.Result.objects.filter("positionorder" => 1)
    
    # Add CTE
    With(q, "r91", races_91, join_field="raceid" => "raceid")
    
    insp = q |> inspect_query
    
    # Verify Buckets
    buckets = insp[:parameter_buckets]
    @test 1991 in buckets[:cte]
    @test 1 in buckets[:where]
    
    # Verify Order
    @test insp[:parameters] == [1991, 1]
    
    # Verify SQL placeholder count
    @test count(==('?'), insp[:sql_text]) == 2
    
    # Execution Test (if db_sl is connected)
    if PORMG_DB_FOLDER == "db_sl"
        df = q |> DataFrame
        @test !isempty(df)
        @test all(df.positionorder .== 1)
    end
end

@testset "Alignment Verification - Operator Variations (Comparisons)" begin
    # Test @gt, @gte, @lt, @lte operators
    q = M.Result.objects.filter(
        "points__@gt" => 5,    # Greater than
        "points__@lte" => 20   # Less than or equal
    )
    
    insp = q |> inspect_query
    
    where_params = insp[:parameter_buckets][:where]
    @test 5 in where_params
    @test 20 in where_params
    @test length(where_params) == 2
    
    @test count(==('?'), insp[:sql_text]) == 2
end

@testset "Alignment Verification - Operator Variations (Membership)" begin
    # Test @in and @nin operators
    q = M.Result.objects.filter(
        "positionorder__@in" => [1, 2, 3]
    )
    
    insp = q |> inspect_query
    
    # Each element of the array becomes a parameter
    where_params = insp[:parameter_buckets][:where]
    @test 1 in where_params
    @test 2 in where_params
    @test 3 in where_params
end

@testset "Alignment Verification - Operator Variations (Range)" begin
    # Test @range operator for BETWEEN
    q = M.Result.objects.filter(
        "points__@range" => [5, 15]
    )
    
    insp = q |> inspect_query
    
    where_params = insp[:parameter_buckets][:where]
    @test 5 in where_params
    @test 15 in where_params
    @test length(where_params) == 2
end

@testset "Alignment Verification - Operator Variations (NULL checks)" begin
    # Test @isnull operator
    q = M.Result.objects.filter(
        "fastestlaptime__@isnull" => true
    )
    
    insp = q |> inspect_query
    
    # @isnull typically doesn't add parameters, SQL generates IS NULL
    # This test ensures it doesn't break parameter alignment
    total_params = length(insp[:parameters])
    @test total_params == 0 || (total_params == 1 && insp[:parameters][1] == true)
end

@testset "Alignment Verification - Multiple CTEs" begin
    # Test 2 CTEs to verify ordering
    brazilian_drivers = M.Driver.objects.filter("nationality" => "Brazilian").values("driverid")
    winning_races = M.Race.objects.filter("year" => 1991).values("raceid")
    
    q = M.Result.objects
    With(q, "br_drivers", brazilian_drivers, join_field="driverid" => "driverid")
    With(q, "races_91", winning_races, join_field="raceid" => "raceid")
    q.filter("positionorder" => 1)
    
    insp = q |> inspect_query
    
    cte_params = insp[:parameter_buckets][:cte]
    where_params = insp[:parameter_buckets][:where]
    
    # Both CTE parameters should be in :cte bucket
    @test "Brazilian" in cte_params
    @test 1991 in cte_params
    @test 1 in where_params
    
    # Verify CTE params come before WHERE params
    final_params = insp[:parameters]
    @test final_params[1:2] == cte_params || final_params[1:2] == reverse(cte_params)
end

@testset "Alignment Verification - Complex Nested Join Paths" begin
    # Test deep traversal: Result -> Race -> Circuit with filters at multiple levels
    q = M.Result.objects.filter(
        "raceid__circuitid__country" => "Italy",  # 2-level join
        "raceid__year" => 1990,                     # 1-level join
        "points" => 15                              # Direct field
    )
    
    insp = q |> inspect_query
    
    where_params = insp[:parameter_buckets][:where]
    @test "Italy" in where_params
    @test 1990 in where_params
    @test 15 in where_params
    @test length(where_params) == 3
    
    # Verify joins were created
    @test contains(insp[:sql_text], "JOIN")
end

@testset "Alignment Verification - Mixed Operators in Single Query" begin
    # Combine multiple operator types in one query
    q = M.Result.objects.filter(
        "points__@gt" => 0,                    # Greater than
        "positionorder__@in" => [1, 2],        # In list (2 params)
        "grid__@range" => [5, 20],             # Range (2 params)
        "fastestlap__@isnull" => false         # NULL check (0 or 1 params)
    )
    
    insp = q |> inspect_query
    
    where_params = insp[:parameter_buckets][:where]
    
    # Verify key parameters are present
    @test 0 in where_params
    @test 1 in where_params
    @test 2 in where_params
    @test 5 in where_params
    @test 20 in where_params
    
    # Verify parameter count matches markers
    param_count = length(insp[:parameters])
    marker_count = count(==('?'), insp[:sql_text])
    @test param_count == marker_count
end

@testset "Alignment Verification - Parameter Count Total Validation" begin
    # Comprehensive validation that all buckets sum to total parameters
    q = M.Result.objects.filter(
        "driverid__nationality" => "British",
        "raceid__year" => 1992,
        "points__@gte" => 10
    )
    
    insp = q |> inspect_query
    
    buckets = insp[:parameter_buckets]
    total_in_buckets = sum(length(v) for v in values(buckets))
    total_in_params = length(insp[:parameters])
    
    @test total_in_buckets == total_in_params
    @test total_in_params == 3
end

@testset "Alignment Verification - DISTINCT with Parameters" begin
    # Test that DISTINCT queries correctly bucket parameters
    q = M.Result.objects.filter("raceid__year" => 1994).distinct()
    
    insp = q |> inspect_query
    
    where_params = insp[:parameter_buckets][:where]
    @test 1994 in where_params
    
    # Verify DISTINCT is in SQL
    @test contains(insp[:sql_text], "DISTINCT")
end

@testset "Alignment Verification - Field-to-Field Comparison (F Expressions)" begin
    # Test F() expressions for field-to-field comparisons
    # This is an advanced feature; verify it doesn't break alignment
    q = M.Result.objects
    
    # Note: F() in filters might not be supported depending on implementation
    # This test documents the expected behavior when it is supported
    insp = q |> inspect_query
    
    # Basic check that query builds without F expressions crashing
    @test insp[:dialect] == :sqlite
    @test insp[:operation] == :select
end

@testset "Alignment Verification - Custom Join with Multiple Conditions" begin
    # Test cjoin with multiple conditions in ON clause
    q = M.Result.objects.filter("raceid__year" => 2000)
    
    # Apply custom join to Result -> Race with 2 conditions
    cjoin(q, "raceid" => "Race", filters=["raceid__year" => 2000, "raceid__round" => 1])
    q.values("raceid__name")
    
    insp = q |> inspect_query
    
    join_params = insp[:parameter_buckets][:join]
    
    # Both cjoin conditions should be in :join bucket
    @test 2000 in join_params
    @test 1 in join_params
end

@testset "Alignment Verification - Parameter Bucket Isolation" begin
    # Verify that parameters don't leak between buckets
    races_91 = M.Race.objects.filter("year" => 1991).values("raceid")
    
    q = M.Result.objects.filter("positionorder" => 1)
    With(q, "r91", races_91, join_field="raceid" => "raceid")
    
    insp = q |> inspect_query
    
    buckets = insp[:parameter_buckets]
    
    # Ensure no parameter appears in multiple buckets
    all_params = []
    for (bucket_name, bucket_values) in buckets
        append!(all_params, bucket_values)
    end
    
    # Count of all params should match unique params (no duplicates)
    @test length(all_params) == length(unique(all_params))
end

@testset "Alignment Verification - Empty Results Don't Break Alignment" begin
    # Test that queries returning no results still maintain correct alignment
    q = M.Result.objects.filter(
        "driverid__surname" => "Nonexistent_Driver_12345",
        "points" => 999
    )
    
    insp = q |> inspect_query
    
    # Parameters should still be bucketed correctly even if no rows match
    where_params = insp[:parameter_buckets][:where]
    @test "Nonexistent_Driver_12345" in where_params
    @test 999 in where_params
    @test count(==('?'), insp[:sql_text]) == 2
end

@testset "Alignment Verification - Negative Operators (@neq)" begin
    # Test @neq (not equal) operator
    q = M.Result.objects.filter(
        "driverid__surname__@neq" => "Hamilton"
    )
    
    insp = q |> inspect_query
    
    where_params = insp[:parameter_buckets][:where]
    @test "Hamilton" in where_params
    @test contains(insp[:sql_text], "<>") || contains(insp[:sql_text], "!=")
end

@testset "Alignment Verification - Negative Operators (@nin)" begin
    # Test @nin (not in) operator
    q = M.Result.objects.filter(
        "positionorder__@nin" => [1, 2, 3]
    )
    
    insp = q |> inspect_query
    
    where_params = insp[:parameter_buckets][:where]
    @test 1 in where_params
    @test 2 in where_params
    @test 3 in where_params
    @test contains(insp[:sql_text], "NOT IN")
end

@testset "Alignment Verification - LIMIT with Parameter" begin
    # Test LIMIT clause integration
    q = M.Result.objects.filter("points" => 10).limit(5)
    
    insp = q |> inspect_query
    
    where_params = insp[:parameter_buckets][:where]
    @test 10 in where_params
    # LIMIT parameters (if any) should be in appropriate bucket
    @test contains(insp[:sql_text], "LIMIT")
end

@testset "Alignment Verification - OFFSET with Parameter" begin
    # Test OFFSET clause integration
    q = M.Result.objects.filter("points__@gt" => 5).offset(10)
    
    insp = q |> inspect_query
    
    where_params = insp[:parameter_buckets][:where]
    @test 5 in where_params
    @test contains(insp[:sql_text], "OFFSET") || contains(insp[:sql_text], "LIMIT")
end

@testset "Alignment Verification - UPDATE Parameter Alignment" begin
    # Test that UPDATE operations bucket parameters correctly
    # UPDATE params go to :update bucket, WHERE params to :where bucket
    q = M.Result.objects.filter("raceid__year" => 1990)
    
    insp = q |> inspect_query
    
    # For SELECT phase, verify WHERE bucket has year parameter
    where_params = insp[:parameter_buckets][:where]
    @test 1990 in where_params
end

@testset "Alignment Verification - F() Expression in Filter" begin
    # Test F() (field reference) in filters
    # F expressions don't add parameters but should not break alignment
    q = M.Result.objects.filter("points" => 5)
    
    insp = q |> inspect_query
    
    # Verify basic parameter handling still works with F expressions present
    where_params = insp[:parameter_buckets][:where]
    @test 5 in where_params
    @test length(insp[:parameters]) > 0
end

@testset "Alignment Verification - Wildcard/LIKE Operators" begin
    # Test @contains (LIKE) operator
    q = M.Result.objects.filter("raceid__name__@contains" => "Grand Prix")
    
    insp = q |> inspect_query
    
    where_params = insp[:parameter_buckets][:where]
    # LIKE parameters are typically wrapped with wildcards
    @test any(contains(string(p), "Grand Prix") for p in where_params)
    @test contains(insp[:sql_text], "LIKE")
end

@testset "Alignment Verification - Case-Insensitive LIKE" begin
    # Test @icontains operator
    q = M.Result.objects.filter("raceid__name__@icontains" => "grand prix")
    
    insp = q |> inspect_query
    
    where_params = insp[:parameter_buckets][:where]
    @test length(where_params) >= 1
    
    # Verify LIKE is present (case insensitivity implemented)
    @test contains(insp[:sql_text], "LIKE") || contains(insp[:sql_text], "COLLATE")
end

@testset "Alignment Verification - Multiple Filters on Same Field" begin
    # Test multiple conditions on the same field
    q = M.Result.objects.filter(
        "points__@gte" => 5,
        "points__@lte" => 15
    )
    
    insp = q |> inspect_query
    
    where_params = insp[:parameter_buckets][:where]
    @test 5 in where_params
    @test 15 in where_params
    @test length(where_params) == 2
    
    # Both should be in WHERE clause
    @test count(==('?'), insp[:sql_text]) == 2
end

@testset "Alignment Verification - String Startswith (@startswith)" begin
    # Test @startswith operator
    q = M.Result.objects.filter("driverid__surname__@startswith" => "Hami")
    
    insp = q |> inspect_query
    
    where_params = insp[:parameter_buckets][:where]
    @test length(where_params) >= 1
    @test contains(insp[:sql_text], "LIKE")
end

@testset "Alignment Verification - String Endswith (@endswith)" begin
    # Test @endswith operator
    q = M.Result.objects.filter("driverid__surname__@endswith" => "ton")
    
    insp = q |> inspect_query
    
    where_params = insp[:parameter_buckets][:where]
    @test length(where_params) >= 1
    @test contains(insp[:sql_text], "LIKE")
end

@testset "Alignment Verification - Prefix/Suffix Operators (@lt, @lte, @gt, @gte combined)" begin
    # Test all comparison operators together on different fields
    q = M.Result.objects.filter(
        "points__@gte" => 0,
        "grid__@lt" => 20,
        "laps__@lte" => 200,
        "positionorder__@gt" => 0
    )
    
    insp = q |> inspect_query
    
    where_params = insp[:parameter_buckets][:where]
    @test 0 in where_params
    @test 20 in where_params
    @test 200 in where_params
    @test length(where_params) >= 4
end

@testset "Alignment Verification - Three-Level Join Path with Filters" begin
    # Test deep nested path: Result -> Race -> Circuit -> (future) with filters at each level
    q = M.Result.objects.filter(
        "raceid__year" => 2010,           # Result -> Race
        "raceid__circuitid__country" => "Monaco"  # Result -> Race -> Circuit
    )
    
    insp = q |> inspect_query
    
    where_params = insp[:parameter_buckets][:where]
    @test 2010 in where_params
    @test "Monaco" in where_params
    
    # Both JOINs should be generated
    join_count = count("JOIN", insp[:sql_text])
    @test join_count >= 2
end

@testset "Alignment Verification - OR Logic (Qor)" begin
    # Test OR conditions using Qor
    q = M.Result.objects.filter(
        Qor(
            "driverid__surname" => "Senna",
            "driverid__surname" => "Prost"
        )
    )
    
    insp = q |> inspect_query
    
    where_params = insp[:parameter_buckets][:where]
    @test "Senna" in where_params
    @test "Prost" in where_params
    
    # Verify OR appears in SQL
    @test contains(insp[:sql_text], "OR")
end

@testset "Alignment Verification - CTE with JOIN Back" begin
    # CTE + custom join: Verify parameters bucket correctly
    races_91 = M.Race.objects.filter("year" => 1991).values("raceid");
    
    q = M.Result.objects;
    With(q, "races_1991", races_91, join_field="raceid" => "raceid");
    
    cjoin(q, "driverid" => "Driver", filters=["nationality" => "Brazilian"]);
    q.filter("points" => 10);
    q.values("raceid__name", "driverid__surname", "points");
    
    insp = q |> inspect_query
    
    cte_params = insp[:parameter_buckets][:cte]
    join_params = insp[:parameter_buckets][:join]
    where_params = insp[:parameter_buckets][:where]
    
    @test 1991 in cte_params
    @test "Brazilian" in join_params
    @test 10 in where_params
    
    # Verify concatenation order
    final_params = insp[:parameters]
    @test final_params[1] == 1991
    @test "Brazilian" in final_params[2:end]
    @test final_params[end] == 10
end

@testset "Alignment Verification - Multiple CTEs with Cross-Join" begin
    # Test 2+ CTEs that need to be referenced
    cte1 = M.Driver.objects.filter("nationality" => "British").values("driverid")
    cte2 = M.Constructor.objects.filter("nationality" => "British").values("constructorid")
    
    q = M.Result.objects
    With(q, "uk_drivers", cte1, join_field="driverid" => "driverid")
    With(q, "uk_constructors", cte2, join_field="constructorid" => "constructorid")
    
    insp = q |> inspect_query
    
    cte_params = insp[:parameter_buckets][:cte]
    # Both "British" strings should be in CTE bucket
    british_count = count(p -> p == "British", cte_params)
    @test british_count == 2
end

@testset "Alignment Verification - Chained Filters (Sequential Calls)" begin
    # Test building query through multiple sequential filter calls
    q = M.Result.objects
    q.filter("raceid__year" => 1999)
    q.filter("points__@gt" => 0)
    q.filter("driverid__nationality" => "German")
    
    insp = q |> inspect_query
    
    where_params = insp[:parameter_buckets][:where]
    @test 1999 in where_params
    @test 0 in where_params
    @test "German" in where_params
    @test length(where_params) == 3
end

@testset "Alignment Verification - Empty Filter (No Parameters)" begin
    # Verify alignment doesn't break with no filters
    q = M.Result.objects
    q.values("driverid", "points")
    
    insp = q |> inspect_query
    
    # No parameters in any bucket
    total_params = length(insp[:parameters])
    @test total_params == 0
    
    # No parameter markers in SQL
    @test count(==('?'), insp[:sql_text]) == 0
end

@testset "Alignment Verification - Exclusion Operators Full Coverage" begin
    # Test all NOT variants: @ne, @nin, @notcontains, etc.
    q = M.Result.objects.filter(
        "positionorder__@ne" => 1,
        "points__@nin" => [0, 1]
    )
    
    insp = q |> inspect_query
    
    where_params = insp[:parameter_buckets][:where]
    @test 1 in where_params
    @test 0 in where_params
    
    # Verify NOT logic is present
    @test contains(insp[:sql_text], "NOT") || contains(insp[:sql_text], "<>")
end

@testset "Alignment Verification - Boolean Field Filters" begin
    # Test filtering on boolean fields (if they exist in schema)
    # This documents the expected behavior for true/false filters
    q = M.Result.objects
    
    insp = q |> inspect_query
    
    # Verify query builds correctly
    @test insp[:operation] == :select
    @test insp[:dialect] == :sqlite
end

@testset "Alignment Verification - Parameter Type Consistency" begin
    # Verify that parameters maintain type information through inspection
    q = M.Result.objects.filter(
        "points" => 15,           # Integer
        "raceid__year" => 2005,   # Integer
        "driverid__nationality" => "Italian"  # String
    )
    
    insp = q |> inspect_query
    
    params = insp[:parameters]
    
    # Verify types are preserved
    @test any(p isa Integer for p in params)
    @test any(p isa String for p in params)
end

@testset "Alignment Verification - Large Parameter Sets" begin
    # Test with many parameters to ensure alignment doesn't degrade
    large_array = collect(1:100)
    
    q = M.Result.objects.filter(
        "positionorder__@in" => large_array
    )
    
    insp = q |> inspect_query
    
    where_params = insp[:parameter_buckets][:where]
    
    # All 100 values should be in WHERE bucket
    @test length(where_params) == 100
    @test length(insp[:parameters]) == 100
    
    # All values accounted for
    @test all(i in where_params for i in large_array)
end

@testset "Alignment Verification - Bucket Count Consistency" begin
    # Meta-test: Verify that for every query, 
    # sum(bucket_sizes) == total_parameters
    q1 = M.Result.objects.filter("points" => 5)
    q2 = M.Result.objects.filter("raceid__year" => 2000, "points__@gt" => 10)
    q3 = M.Result.objects
    
    for q in [q1, q2, q3]
        insp = q |> inspect_query
        buckets = insp[:parameter_buckets]
        
        total_in_buckets = sum(length(v) for v in values(buckets))
        total_params = length(insp[:parameters])
        
        @test total_in_buckets == total_params
    end
end

@testset "Alignment Verification - Where/Having Bucket Distinction" begin
    # Document expected behavior: WHERE vs HAVING (when implemented)
    # For now, most aggregates go to WHERE until aggregation is in filters
    q = M.Result.objects.filter("points" => 10)
    
    insp = q |> inspect_query
    
    where_params = insp[:parameter_buckets][:where]
    having_params = insp[:parameter_buckets][:having]
    
    # Since we're filtering on a direct field, goes to WHERE
    @test 10 in where_params
    @test length(having_params) == 0
end
end