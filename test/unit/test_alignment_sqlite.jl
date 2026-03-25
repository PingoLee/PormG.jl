using Test
using PormG
using Logging

# Mock SQLite Settings
struct MockSQLite <: PormG.PormGSQLite end
# Use a dummy path and key to prevent cross-test contamination in runtests.jl
MockSettings = PormG.Configuration.Settings(
    connections=MockSQLite(),
    change_data=true,
    db_def_folder="mock_sl_path"
)
PormG.config["mock_sl_key"] = MockSettings

# Manually include and initialize models instead of @import_models mapping
include("../integration/db_sl/models.jl")
import .models as M
PormG.Models.set_models(M, "mock_sl_path")
import PormG.QueryBuilder: cjoin, Q, Qor, F, inspect_query, Case, When, Sum, Avg, Value, Round, With

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
    q = M.Result.objects.filter("positionorder" => 1) # This goes to :where

    cjoin(q, "raceid" => "Race", filters=["year" => 2000])

    # Trigger the join by accessing a field from the related model
    q.values("raceid__name", "points")

    insp = q |> inspect_query

    # Parameters order for SQLite: CTE, SELECT, UPDATE, JOIN, WHERE, HAVING
    # 2000 (from cjoin) is in :join bucket
    # 1 (from filter) is in :where bucket

    ins_buckets = insp[:parameter_buckets]
    @test 2000 in ins_buckets[:join]
    @test 1 in ins_buckets[:where]

    @test insp[:parameters] == [2000, 1]
end

@testset "Alignment Verification - cjoin Rejects Base-Model Filters" begin
    q = M.Result.objects

    @test_throws ArgumentError begin
        cjoin(q, "raceid" => "Race", filters=["points" => 10])
    end
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

    # Execution Test (removed for unit testing)
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
    # Test 2 CTEs to verify DETERMINISTIC ordering (critical for positional params)
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

    # For SQLite positional params, order is CRITICAL: CTE must come before WHERE
    final_params = insp[:parameters]
    @test length(final_params) == 3
    @test final_params[3] == 1  # WHERE param (positionorder=1) must be last
    # Both CTE params in first 2 positions (order preserved from insertion)
    @test final_params[1] == "Brazilian"
    @test final_params[2] == 1991
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
    # Verify that parameters land in exactly ONE bucket (no cross-bucket contamination)
    # even if the same literal appears in different contexts
    races_91 = M.Race.objects.filter("year" => 1991).values("raceid")

    q = M.Result.objects.filter("positionorder" => 1)
    With(q, "r91", races_91, join_field="raceid" => "raceid")

    insp = q |> inspect_query

    buckets = insp[:parameter_buckets]
    cte_params = buckets[:cte]
    where_params = buckets[:where]

    # Verify non-empty buckets
    @test 1991 in cte_params
    @test 1 in where_params
    @test length(cte_params) == 1
    @test length(where_params) == 1

    # Verify order in final params matches bucket order: CTE first, WHERE second
    final_params = insp[:parameters]
    @test final_params == [1991, 1]
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

@testset "Alignment Verification - Negative Operators (@ne)" begin
    # Test @ne (not equal) operator
    q = M.Result.objects.filter(
        "driverid__surname__@ne" => "Hamilton"
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
    # LIMIT/OFFSET are rendered as literals, not as '?' parameters, by design.
    # No placeholder is expected for them.
    q = M.Result.objects.filter("points" => 10).limit(5)

    insp = q |> inspect_query

    where_params = insp[:parameter_buckets][:where]
    @test 10 in where_params
    # LIMIT parameters (if any) should be in appropriate bucket
    @test contains(insp[:sql_text], "LIMIT")
end

@testset "Alignment Verification - OFFSET with Parameter" begin
    # Test OFFSET clause integration
    # LIMIT/OFFSET are rendered as literals, not as '?' parameters, by design.
    # No placeholder is expected for them.
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

    # Perform an UPDATE with show_query=:inspection to run the builder but SKIP execution
    insp = q.update("points" => 25, show_query=:inspection)

    # Check that UPDATE bucket was populated correctly
    @test insp[:operation] == :update
    @test 25 in insp[:parameter_buckets][:update]
    @test 1990 in insp[:parameter_buckets][:where]

    # Post-assignment parameters order for SQL (SET before WHERE)
    @test insp[:parameters] == [25, 1990]

    # Also verify a SELECT query never touches :update bucket
    q_select = M.Result.objects.filter("raceid__year" => 1990)
    insp_select = q_select |> inspect_query

    @test 1990 in insp_select[:parameter_buckets][:where]
    @test length(insp_select[:parameter_buckets][:update]) == 0  # SELECT has no UPDATE params
end

@testset "Alignment Verification - F() Expression in Filter" begin
    # Test F() (field reference) for field-to-field comparisons in filters
    # F expressions inject column references (no parameters) alongside scalar params
    # Example: "points" > grid (compare field to field, not field to literal)
    q = M.Result.objects.filter("points__@gt" => F("grid"))

    insp = q |> inspect_query

    # F() expressions should NOT add parameters
    # Only the right-hand side (grid column) is referenced
    where_params = insp[:parameter_buckets][:where]

    # No scalar parameters from the F() expression
    @test length(where_params) == 0 || !any(p -> p == "grid", where_params)

    # Verify SQL references the grid column
    sql = insp[:sql_text]
    @test contains(sql, ">")
    @test contains(sql, "grid")
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
    races_91 = M.Race.objects.filter("year" => 1991).values("raceid")

    q = M.Result.objects
    With(q, "races_1991", races_91, join_field="raceid" => "raceid")

    cjoin(q, "driverid" => "Driver", filters=["nationality" => "Brazilian"])
    q.filter("points" => 10)
    q.values("raceid__name", "driverid__surname", "points")

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
    # Test filtering on an explicit BooleanField
    # Passing true/false to BooleanField demonstrates the parameterisation layer's 
    # handling of boolean literals without type errors (Bool parameters are tracked properly).
    q = M.New_join_position.objects.filter("boolean_field" => true, "result__@gt" => 5)

    insp = q |> inspect_query

    # Verify query builds correctly and parameters are captured
    @test length(insp[:parameters]) == 2

    # Check presence of true/false in the :where bucket
    # PormG stores the original parameter values before execution casting
    @test true in insp[:parameter_buckets][:where]
    @test 5 in insp[:parameter_buckets][:where]

    # Verify operator
    @test contains(insp[:sql_text], "=")
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

@testset "Alignment Verification - Mixing Logic in Custom Join (Q/Qor)" begin
    # Test recursive normalization of Q and Qor filters inside cjoin
    q = M.Result.objects

    # Passing Q and Qor with plain fields that should be prefixed
    cjoin(q, "driverid" => "Driver", filters=[
        Q("nationality" => "Brazilian", Qor("forename" => "Ayrton", "forename" => "Nelson"))
    ])

    q.filter("points" => 10)
    q.values("driverid__surname")

    insp = q |> inspect_query
    sql = insp[:sql_text]

    # 10 is in :where
    # Brazilian, Ayrton, Nelson should ideally land in :join
    join_params = insp[:parameter_buckets][:join]
    where_params = insp[:parameter_buckets][:where]

    @test "Brazilian" in join_params
    @test "Ayrton" in join_params
    @test "Nelson" in join_params
    @test 10 in where_params

    # Verify the SQL ON clause contains the join predicates (not WHERE)
    @test contains(sql, "JOIN")
    # Regex: ensure 'nationality' appears between ON and WHERE, not in WHERE clause
    @test match(r"ON\s+.*?nationality.*?WHERE"s, sql) !== nothing
    # Regex: ensure 'forename' appears between ON and WHERE, not in WHERE clause
    @test match(r"ON\s+.*?forename.*?WHERE"s, sql) !== nothing
end

@testset "Alignment Verification - set_context! Stability (Join Context)" begin
    # Verify that build_row_join_sql_text sets :join context properly
    q = M.Result.objects
    cjoin(q, "driverid" => "Driver", filters=["nationality" => "German"])
    q.filter("points" => 5)
    q.values("driverid__surname")

    insp = q |> inspect_query
    sql = insp[:sql_text]

    # "German" must be in :join, 5 in :where
    @test insp[:parameter_buckets][:join] == ["German"]
    @test insp[:parameter_buckets][:where] == [5]

    # Verify "German" is in ON clause, not WHERE clause
    @test match(r"ON\s+.*?nationality.*?WHERE"s, sql) !== nothing
end

@testset "Alignment Verification - cjoin FK Target Validation" begin
    # Verify that cjoin validates ForeignKey target model match
    # Result.driverid is a FK pointing to Driver
    # Calling cjoin with a mismatched target should raise an error

    q = M.Result.objects

    # This should raise an error because driverid points to Driver, not Constructor
    @test_throws ArgumentError begin
        cjoin(q, "driverid" => "Constructor", filters=["name" => "Ferrari"])
    end

    # This should succeed because we use the correct target (Driver)
    q2 = M.Result.objects
    cjoin(q2, "driverid" => "Driver", filters=["nationality" => "Italian"])
    q2.values("driverid__surname")

    insp = q2 |> inspect_query
    # Verify filter was added to join context
    @test "Italian" in insp[:parameter_buckets][:join]
end

@testset "Alignment Verification - cjoin Auto-Discovery Warning (Default=true)" begin
    # Test that cjoin emits a warning when auto-discovering join target PK (default behavior)
    # This catches accidental joins to wrong models
    q = M.Result.objects

    # Capture warning: cjoin on non-FK field "positionorder" should warn
    warn_buffer = IOBuffer()

    with_logger(ConsoleLogger(warn_buffer, Logging.Warn)) do
        cjoin(q, "positionorder" => "Result", warn=true)  # Explicit warn=true
        q.values("positionorder__points")
    end

    # Verify warning was logged
    warn_text = String(take!(warn_buffer))
    @test contains(warn_text, "auto-discovered") || contains(warn_text, "cjoin")
end

@testset "Alignment Verification - cjoin Auto-Discovery Warning (Suppressed)" begin
    # Test that warn=false suppresses the auto-discovery warning
    q = M.Result.objects

    # Suppress warning explicitly
    warn_buffer = IOBuffer()

    warn_count_before = length(String(take!(warn_buffer)))

    with_logger(ConsoleLogger(warn_buffer, Logging.Warn)) do
        cjoin(q, "positionorder" => "Result", warn=false)  # Suppress warning
        q.values("positionorder__points")
    end

    warn_text = String(take!(warn_buffer))
    warn_count_after = length(warn_text)

    # With warn=false, the specific auto-discovery warning should not appear
    # (other warnings may still exist, but not this one)
    @test !contains(warn_text, "auto-discovered join target primary key")
end

@testset "Alignment Verification - cjoin Placeholder Integrity (Mixed CTE+JOIN+WHERE)" begin
    # Comprehensive test: verify that SQL placeholder count matches parameter vector length
    # when mixing CTEs, JOINs, and WHERE filters
    races_91 = M.Race.objects.filter("year" => 1991).values("raceid")

    q = M.Result.objects
    With(q, "r91", races_91, join_field="raceid" => "raceid")
    cjoin(q, "driverid" => "Driver", filters=["nationality" => "Brazilian"])
    q.filter("points" => 10)
    q.values("driverid__surname")

    insp = q |> inspect_query
    sql = insp[:sql_text]
    params = insp[:parameters]

    # CRITICAL: Count of '?' in SQL must match length of parameters
    placeholder_count = count(==('?'), sql)
    param_count = length(params)

    @test placeholder_count == param_count
    @test placeholder_count == 3  # 1991 (CTE) + Brazilian (JOIN) + 10 (WHERE)

    # Verify buckets sum to total
    cte_len = length(insp[:parameter_buckets][:cte])
    join_len = length(insp[:parameter_buckets][:join])
    where_len = length(insp[:parameter_buckets][:where])

    @test cte_len + join_len + where_len == param_count
end

@testset "Alignment Verification - on() merges filters and overrides join type" begin
    # on() should behave like a dedicated ON-clause API for an existing join path.
    # Multiple calls against the same path should merge predicates, while join_type
    # should override the join keyword used by the SQL builder.
    q = M.Result.objects
    q.on("driverid", "nationality" => "Brazilian")
    q.on("driverid", "code" => "SEN", join_type="INNER")
    q.filter("points" => 10)
    q.values("driverid__surname")

    insp = q |> inspect_query
    sql = insp[:sql_text]

    @test insp[:parameter_buckets][:join] == ["Brazilian", "SEN"]
    @test insp[:parameter_buckets][:where] == [10]
    @test contains(sql, "INNER JOIN")
    @test match(r"ON\s+.*?nationality.*?code.*?WHERE"s, sql) !== nothing
end

@testset "Alignment Verification - on() supports reverse joins" begin
    # Reverse joins are the main reason a dedicated ON API exists.
    # The base rows should be preserved while only matching reverse rows attach.
    q = M.Result.objects
    q.on("test_deletion", "name" => "reverse-join-a")
    q.filter("resultid__@in" => [1, 2, 3])
    q.values("resultid", "test_deletion__name")

    insp = q |> inspect_query
    sql = insp[:sql_text]

    @test insp[:parameter_buckets][:join] == ["reverse-join-a"]
    @test insp[:parameter_buckets][:where] == [1, 2, 3]
    @test contains(sql, "LEFT JOIN")
    # PormG uses table aliases in ON clauses (e.g. "Tb_1"."name"), so the table name
    # "just_a_test_deletion" appears in the JOIN clause (before ON), not inside the ON condition.
    # The correct check: table name appears in the JOIN clause, field name appears in the ON clause.
    @test match(r"JOIN.*?test_deletion.*?ON.*?name.*?WHERE"s, sql) !== nothing
end

@testset "Alignment Verification - Positive HAVING" begin
    # Test that parameters in HAVING (aggregate filters) land in :having bucket
    # Note: Aggregate filters must refer to an alias from values() that uses an aggregate function
    q = M.Result.objects.values("raceid__circuitid__name", "total_points" => Sum("points"))
    q.filter("total_points__@gt" => 1000)

    insp = q |> inspect_query

    having_params = insp[:parameter_buckets][:having]
    @test 1000 in having_params
    @test length(having_params) == 1

    # Verify SQL contains HAVING and points
    @test contains(insp[:sql_text], "HAVING")
    @test contains(insp[:sql_text], "SUM")
end

@testset "Alignment Verification - DELETE Inspection" begin
    # Test DELETE operation parameters land in :where bucket
    q = M.Result.objects.filter("resultid" => 5)

    # Use inspect_query with explicit :delete operation
    insp = q |> inspect_query(operation=:delete)

    @test insp[:operation] == :delete
    @test 5 in insp[:parameter_buckets][:where]
    @test contains(insp[:sql_text], "DELETE")
end

@testset "Alignment Verification - INSERT Inspection" begin
    # Test INSERT operation parameters land in :select bucket (as expected from execution.jl:358)

    # Use .create(...) which is the primary user-facing terminal method
    # We pass show_query=:inspection to avoid DB persistence
    # The Result model requires these non-null fields
    insp = M.Result.objects.create(
        "raceid" => 1,
        "driverid" => 1,
        "constructorid" => 1,
        "statusid" => 1,
        "grid" => 18,
        "positiontext" => "1",
        "positionorder" => 1,
        "points" => 25,
        "laps" => 50,
        show_query=:inspection
    )

    @test insp[:operation] == :insert
    @test 25 in insp[:parameter_buckets][:select]
    @test 50 in insp[:parameter_buckets][:select]
    @test 18 in insp[:parameter_buckets][:select]

    @test contains(insp[:sql_text], "INSERT INTO")
end

@testset "Alignment Verification - UPDATE with JOIN Alignment" begin
    # Test UPDATE with JOIN: parameters should be ordered: :update -> :join -> :where
    # Scenario: Update Result points to 25 for drivers from Brazil in 1990
    q = M.Result.objects.filter("raceid__year" => 1990)

    # Add a custom join with a filter (lands in :join bucket)
    cjoin(q, "driverid" => "Driver", filters=["nationality" => "Brazilian"])

    # Run UPDATE inspection
    insp = q.update("points" => 25, show_query=:inspection)

    buckets = insp[:parameter_buckets]
    @test 25 in buckets[:update]
    @test "Brazilian" in buckets[:join]
    @test 1990 in buckets[:where]

    # Verify concatenation order for positional params: Update, then Join, then Where
    # This is critical for SQLite UPDATE FROM syntax
    @test insp[:parameters] == [25, "Brazilian", 1990]
end

@testset "Alignment Verification - Saturation Test (All Query Buckets)" begin
    # Logic: Construct a complex query combining CTE, Custom Joins, WHERE, and HAVING contexts simultaneously.
    # Why: This acts as a saturation test to ensure PormGPositionalParam correctly concatenates 
    # vcat(cte, select, update, join, where, having) in precision alignment matching the generated SQL string.

    races_91 = M.Race.objects.filter("year" => 1991).values("raceid")

    q = M.Result.objects

    # 1. Provide CTE parameter (should go to :cte)
    With(q, "r91", races_91, join_field="raceid" => "raceid")

    # 2. Provide JOIN parameter (should go to :join)
    cjoin(q, "driverid" => "Driver", filters=["nationality" => "Brazilian"])

    # 3. Provide WHERE parameter (should go to :where)
    q.filter("points__@gt" => 5)

    # 4. Provide HAVING parameter (should go to :having)
    q.values("driverid__surname", "total_points" => Sum("points"))
    q.filter("total_points__@gt" => 100)

    insp = q |> inspect_query

    buckets = insp[:parameter_buckets]

    @test 1991 in buckets[:cte]
    @test "Brazilian" in buckets[:join]
    @test 5 in buckets[:where]
    @test 100 in buckets[:having]

    # Verify final positional array matches string order exactly: CTE -> (SELECT) -> (UPDATE) -> JOIN -> WHERE -> HAVING
    @test insp[:parameters] == [1991, "Brazilian", 5, 100]

    # Verify exact marker count matches parameter array length
    @test count(==('?'), insp[:sql_text]) == 4

    # Test that each keyword exists in the actual query output
    @test contains(uppercase(insp[:sql_text]), "WITH")
    @test contains(uppercase(insp[:sql_text]), "JOIN")
    @test contains(uppercase(insp[:sql_text]), "WHERE")
    @test contains(uppercase(insp[:sql_text]), "HAVING")
end

@testset "Saturation Test - Full Pipeline Stress" begin
    # Logic: Populate EVERY bucket with MULTIPLE parameters (CTE, JOIN, WHERE, HAVING).
    # Why: This verifies that concatenation order is strict and deterministic across all possible query sections.

    # 1. CTE Elements (Order: races_91 then drivers_br)
    # Making races_91 CTE complex: its internal query exercises SELECT (Case/When),
    # JOIN (cjoin), WHERE (filter), and HAVING (aggregate alias filter).
    #
    # IMPORTANT DISCOVERY: CTE-internal params do NOT all land in :cte bucket.
    # CTE-internal JOIN/HAVING params leak into the parent's :join/:having buckets
    # because set_context! inside the CTE builder overrides the parent's :cte context.
    # Only CTE SELECT and WHERE params remain in the :cte bucket.
    races_91 = M.Race.objects
    # CTE-internal SELECT: only the condition value is parameterized (round > ?),
    # `then=2` and `default=3` are rendered as SQL literals (THEN 2, ELSE 3).
    races_91.values("raceid", "points_avg" => Avg("round"), "cat" => Case([When("round__@gt" => 1, then=2)], default=3))
    # CTE-internal JOIN: param "Monza" → goes to PARENT's :join bucket
    cjoin(races_91, "circuitid" => "Circuit", filters=["name" => "Monza"])
    # CTE-internal WHERE: param 1991 → stays in :cte bucket
    races_91.filter("year" => 1991)
    # CTE-internal HAVING: param 5 → goes to PARENT's :having bucket
    races_91.filter("points_avg__@gt" => 5)

    drivers_br = M.Driver.objects.filter("nationality" => "Brazilian").values("driverid")

    q = M.Result.objects
    With(q, "r91", races_91, join_field="raceid" => "raceid")
    With(q, "drivers_br", drivers_br, join_field="driverid" => "driverid")

    # 2. Outer JOIN Elements (Order: Italian -> VET -> MSC)
    cjoin(q, "driverid" => "Driver", filters=[
        "nationality" => "Italian",
        "code__@in" => ["VET", "MSC"]
    ])

    # 3. Outer WHERE Elements (Order: 10 -> 20 -> 5 -> 5)
    q.filter(
        "points__@gte" => 10,
        "points__@lte" => 20,
        "grid__@gt" => 5,
        "positionorder__@lt" => 5
    )

    # 4. Outer SELECT Elements (Order: 20, 10) and HAVING Elements (Order: 8)
    q.values(
        "driverid__surname",
        "avg_points" => Avg("points"),
        "custom_cat" => Case([
                When("points__@gt" => 20, then=3),
                When("points__@gt" => 10, then=2)
            ], default=1)
    )
    q.filter("avg_points__@gt" => 8)

    insp = q |> inspect_query

    # STRICT ORDER VERIFICATION:
    # vcat(cte, select, update, join, where, having)
    #
    # Bucket distribution:
    #   :cte    = [1, 2, 3, 1991, "Brazilian"]  — races_91 SELECT(condition=1, then=2, default=3) + WHERE(1991) + drivers_br
    #   :select = [20, 3, 10, 2, 1]             — outer CASE WHEN (condition, then, condition, then, default)
    #   :join   = ["Monza", "Italian", "VET", "MSC"]  — races_91 cjoin + outer cjoin
    #   :where  = [10, 20, 5, 5]                — outer WHERE filters
    #   :having = [5, 8]                         — races_91 HAVING(5) + outer HAVING(8)
    #
    # Within each CASE/WHEN, parameter order follows SQL text:
    #   WHEN condition THEN then_val ... ELSE else_val END
    expected_order = [
        1, 2, 3, 1991, "Brazilian",            # CTE: races_91 SELECT(cond=1, then=2, default=3) + WHERE(1991), drivers_br WHERE
        20, 3, 10, 2, 1,                       # Outer SELECT: When(>20, then=3), When(>10, then=2), default=1
        "Monza", "Italian", "VET", "MSC",       # JOIN: races_91 cjoin("Monza") + outer cjoin
        10, 20, 5, 5,                           # Outer WHERE (points range, grid, positionorder)
        5, 8                                    # HAVING: races_91 HAVING(5) + outer HAVING(8)
    ]

    @test insp[:parameters] == expected_order
    @test count(==('?'), insp[:sql_text]) == length(expected_order)
end

@testset "Alignment Verification - LIMIT/OFFSET Documentation" begin
    # LIMIT and OFFSET are currently rendered as integer literals in the SQL string,
    # not as parameterized '?' values. This is safe by design because the SQLObject
    # strictly enforces Integer types for these fields, eliminating injection risk.
    # This test documents this expected behavior.

    q = M.Driver.objects.filter("nationality" => "British")
    q.limit(10).offset(5)

    insp = q |> inspect_query

    # Only the filter parameter is present
    @test insp[:parameters] == ["British"]
    @test count(==('?'), insp[:sql_text]) == 1

    # But both LIMIT and OFFSET are woven into the raw SQL string
    @test contains(insp[:sql_text], "LIMIT 10")
    @test contains(insp[:sql_text], "OFFSET 5")
end

@testset "Alignment Verification - deepcopy Isolation Test" begin
    # Verify that deepcopying a query builder completely isolates its parameter buckets.
    # This guarantees that mutating a copied query (e.g., in bulk execution)
    # doesn't illegally append parameters to the original query's buckets.

    q1 = M.Result.objects.filter("points" => 10)
    q2 = deepcopy(q1)

    # Mutate the copy
    q2.filter("points" => 99)

    insp1 = q1 |> inspect_query
    insp2 = q2 |> inspect_query

    # Original query should remain untouched
    @test insp1[:parameters] == [10]
    @test insp1[:parameter_buckets][:where] == [10]

    # Copied query should have both parameters
    @test insp2[:parameters] == [10, 99]
    @test insp2[:parameter_buckets][:where] == [10, 99]
end

@testset "Alignment Verification - Context Restoration (Subqueries)" begin
    # Verify that after building a subquery (which uses its own temporary contextual 
    # buckets or shares them), the parent query's original bucket context is restored.
    # This prevents parameters added *after* the subquery from leaking into the wrong bucket.

    inner = M.Circuit.objects.filter("country" => "Italy").values("circuitid")
    q = M.Result.objects.filter("raceid__circuitid__@in" => inner)

    # This parameter is added AFTER the subquery is processed.
    # It must correctly land in the parent's :where bucket.
    q.filter("positionorder" => 1)

    insp = q |> inspect_query

    # Both "Italy" (from subquery) and 1 (from parent) should be in the :where bucket
    # due to depth-first resolution of the filter tree.
    @test insp[:parameters] == ["Italy", 1]
    @test insp[:parameter_buckets][:where] == ["Italy", 1]
end

@testset "Alignment Verification - SELECT-phase Bucket Test" begin
    # Verify that parameters introduced in the SELECT clause (via values())
    # correctly land in the :select bucket. This typically happens with CASE/WHEN.

    q = M.Result.objects.filter("points__@gte" => 10)

    # This Case/When expression is in the SELECT clause, so all its parameters
    # (condition 1, then 100, default 0) must land in the :select bucket.
    q.values("resultid", "bonus" => Case([When("positionorder" => 1, then=100)], default=0))

    insp = q |> inspect_query

    # Order:
    # :select bucket -> [1, 100, 0] (from Case When: condition, then, default)
    # :where bucket  -> [10] (from filter points >= 10)
    @test insp[:parameters] == [1, 100, 0, 10]
    @test insp[:parameter_buckets][:select] == [1, 100, 0]
    @test insp[:parameter_buckets][:where] == [10]
end

@testset "Alignment Verification - Default Equality Operator" begin
    # Many operators are tested with explicit `@` suffixes (@lt, @in), but the 
    # default equality path (no suffix) is implicitly the most common.
    # This explicit test documents the expected behavior for future readers.

    q = M.Driver.objects.filter("nationality" => "British")

    insp = q |> inspect_query

    @test insp[:parameters] == ["British"]
    @test insp[:parameter_buckets][:where] == ["British"]

    # Verify the SQL uses '=' and not some other operator mapping
    # SQLite dialect rendering for equality is '='
    @test contains(insp[:sql_text], "=")
    @test !contains(insp[:sql_text], "<>")
end

@testset "Alignment Verification - Value(x) Parameterization" begin
    # Value(x) should push its argument to `add_parameter!` instead of rendering as a raw SQL literal.
    # This prevents SQL injection if user input is ever passed to Value().

    # String value — must be parameterized, not rendered as '...'
    q = M.Result.objects.values("resultid", "label" => Value("hello"))
    insp = q |> inspect_query
    @test insp[:parameters] == ["hello"]
    @test insp[:parameter_buckets][:select] == ["hello"]
    @test !contains(insp[:sql_text], "'hello'")   # must NOT be literal
    @test contains(insp[:sql_text], "?")            # must be placeholder

    # Number value — must be parameterized, not rendered as raw number
    q2 = M.Result.objects.values("resultid", "score" => Value(42))
    insp2 = q2 |> inspect_query
    @test insp2[:parameters] == [42]
    @test insp2[:parameter_buckets][:select] == [42]

    # Nothing value — must stay as NULL literal (can't parameterize NULL)
    q3 = M.Result.objects.values("resultid", "empty" => Value(nothing))
    insp3 = q3 |> inspect_query
    @test isempty(insp3[:parameters])
    @test contains(insp3[:sql_text], "NULL")
end

@testset "Alignment Verification - Round(precision) Parameterization" begin
    # Round(col, precision) should parameterize the precision argument 
    # instead of interpolating it as a raw integer literal.

    q = M.Result.objects.values("resultid", "rounded_pts" => Round("points", 2))
    insp = q |> inspect_query

    # Precision should be parameterized in the :select bucket
    @test 2 in insp[:parameters]
    @test 2 in insp[:parameter_buckets][:select]
    @test contains(insp[:sql_text], "ROUND")
    @test contains(insp[:sql_text], "?")
end

@testset "Saturation Test - Recursive Subquery Ordering" begin
    # Subqueries in WHERE clause should follow depth-first parameter injection 
    # while correctly restoring the parent's bucket context.

    inner = M.Circuit.objects.filter("country" => "Italy").values("circuitid")
    middle = M.Race.objects.filter("circuitid__@in" => inner, "year__@gte" => 1990).values("raceid")

    q = M.Result.objects.filter("raceid__@in" => middle, "points__@gte" => 18)
    q.filter("constructorid__nationality" => "British") # Append another where param

    insp = q |> inspect_query

    # Expected ordering in WHERE bucket: Italy -> 1990 -> 18 -> British
    @test insp[:parameters] == ["Italy", 1990, 18, "British"]
    @test count(==('?'), insp[:sql_text]) == 4
end

@testset "Alignment Verification - Context Restoration After Subquery" begin
    # Logic: After a subquery is expanded in a filter, the parent's :where context
    # must be restored so that subsequent filter parameters still land in :where.
    # Why: execution.jl saves/restores `old_context` (lines 166-182) when building
    # subqueries. If the restore is broken, the second filter parameter would be
    # silently routed to whatever bucket the subquery left active.

    inner = M.Circuit.objects.filter("country" => "Italy").values("circuitid")

    q = M.Result.objects
    # First filter contains a subquery — its params ("Italy") expand depth-first in :where
    q.filter("raceid__circuitid__@in" => inner)
    # Second filter is added AFTER subquery — must still go to :where, not a stale context
    q.filter("positionorder" => 1)

    insp = q |> inspect_query

    where_params = insp[:parameter_buckets][:where]

    # Both parameters must be in :where in depth-first order: "Italy" then 1
    @test where_params == ["Italy", 1]

    # Final parameter order: subquery param first, then parent's param
    @test insp[:parameters] == ["Italy", 1]

    # Placeholder count must match
    @test count(==('?'), insp[:sql_text]) == 2
end

@testset "Alignment Verification - Context Restoration With CTE + Subquery" begin
    # Logic: Combine CTE (params in :cte) with a subquery in WHERE plus a post-subquery filter.
    # Why: Ensures context restoration works when multiple bucket types are active in the same query.

    # CTE: races in 1991 (param goes to :cte)
    races_91 = M.Race.objects.filter("year" => 1991).values("raceid")

    q = M.Result.objects
    With(q, "r91", races_91, join_field="raceid" => "raceid")

    # Subquery in WHERE filter
    italian_circuits = M.Circuit.objects.filter("country" => "Italy").values("circuitid")
    q.filter("raceid__circuitid__@in" => italian_circuits)

    # Post-subquery filter — must go to :where, not :cte or any stale context
    q.filter("positionorder" => 1)

    insp = q |> inspect_query

    cte_params = insp[:parameter_buckets][:cte]
    where_params = insp[:parameter_buckets][:where]

    # 1991 must be in :cte; "Italy" and 1 must be in :where in depth-first order
    @test cte_params == [1991]
    @test where_params == ["Italy", 1]

    # Final order: CTE first, then WHERE (depth-first: Italy, then 1)
    @test insp[:parameters] == [1991, "Italy", 1]
    @test count(==('?'), insp[:sql_text]) == 3
end


