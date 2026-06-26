"""
Comprehensive test suite for complex query scenarios and API coverage.
Tests show_query return values, parameter handling, and execution modes.

These tests use show_query mode to inspect SQL/parameters without requiring
a live database connection. Some complex join tests are deferred for integration tests.
"""

using Test
using PormG
using PormG.Models: Model, CharField, IDField, IntegerField, ForeignKey
using PormG.QueryBuilder: Q, Qor, F
import DataFrames

# Initialize test models - kept simple to focus on query generation
DriverModel = Model("drivers",
  id=IDField(),
  forename=CharField(),
  surname=CharField(),
  nationality=CharField()
)
DriverModel.connect_key = "default"

RaceModel = Model("races",
  id=IDField(),
  name=CharField(),
  year=IntegerField()
)
RaceModel.connect_key = "default"

# Mock settings for test mode (no DB connection needed when using show_query)
struct MockPostgres <: PormG.PormGPostgres end
MockSettings = PormG.Configuration.Settings(
  connections=MockPostgres(),
  change_data=true
)
PormG.config["default"] = MockSettings

# Separate settings key so Django-prefixed query generation is isolated from the
# generic unit tests above. This uses show_query mode, so no live DB is required.
DjangoMockSettings = PormG.Configuration.Settings(
  connections=MockPostgres(),
  change_data=true,
  django_prefix="f1"
)
PormG.config["django_test"] = DjangoMockSettings

DriverDjangoModel = Model("driver",
  id=IDField(),
  forename=CharField(),
  surname=CharField()
)
DriverDjangoModel.connect_key = "django_test"
DriverDjangoModel._module = Main

ResultDjangoModel = Model("result",
  id=IDField(),
  driver_id=ForeignKey(DriverDjangoModel, pk_field="id"),
  points=IntegerField(null=true)
)
ResultDjangoModel.connect_key = "django_test"
ResultDjangoModel._module = Main

# For multi-hop testing: ConstrResult → result_id (FK→Result) → driver_id (FK→Driver) → forename.
# This exercises the while-loop call site of _resolve_django_join_field.
ConstructorDjangoModel = Model("constructor",
  id=IDField(),
  name=CharField()
)
ConstructorDjangoModel.connect_key = "django_test"
ConstructorDjangoModel._module = Main

ConstrResultDjangoModel = Model("constructor_result",
  id=IDField(),
  result_id=ForeignKey(ResultDjangoModel, pk_field="id"),
  constructor_id=ForeignKey(ConstructorDjangoModel, pk_field="id")
)
ConstrResultDjangoModel.connect_key = "django_test"
ConstrResultDjangoModel._module = Main

# For camelCase FK convention (real F1 style: driverid, not driver_id).
# Short-form resolution ("driver" → "driver_id") does NOT apply here because
# nobody named the field "driver_id" — it is "driverid". Callers must use the
# full physical field name: "driverid__forename".
ResultCamelDjangoModel = Model("result_camel",
  id=IDField(),
  driverid=ForeignKey(DriverDjangoModel, pk_field="id"),
  points=IntegerField(null=true)
)
ResultCamelDjangoModel.connect_key = "django_test"
ResultCamelDjangoModel._module = Main

@testset "Complex Query Coverage" begin

  # ===== Section 1: Basic Filters with Operators =====
  @testset "Filter Operators" begin
    # Test: Greater than operator
    q = RaceModel.objects
    q.filter("year__@gt" => 2020)
    res = q.list(show_query=:dict)

    @test res isa Dict
    @test haskey(res, :sql_text)
    @test haskey(res, :parameters)
    @test res[:parameters] == [2020]
    @test contains(res[:sql_text], ">")

    # Test: Less than or equal operator
    q2 = RaceModel.objects
    q2.filter("year__@lte" => 1990)
    res2 = q2.list(show_query=:dict)

    @test res2[:parameters] == [1990]
    @test contains(res2[:sql_text], "<=")

    # Test: Not equal operator
    q3 = RaceModel.objects
    q3.filter("year__@ne" => 2021)
    res3 = q3.list(show_query=:dict)

    @test res3[:parameters] == [2021]
  end

  # ===== Section 2: String Pattern Matching =====
  @testset "String Pattern Matching" begin
    # Test: contains/icontains for LIKE
    q = DriverModel.objects
    q.filter("forename__@contains" => "lew")
    res = q.list(show_query=:dict)

    @test res isa Dict
    @test contains(res[:sql_text], "LIKE") || contains(res[:sql_text], "LOWER")

    # Test: Multiple string filters
    q2 = DriverModel.objects
    q2.filter("nationality" => "British")
    q2.filter("forename__@contains" => "lewis")
    res2 = q2.list(show_query=:dict)

    @test length(res2[:parameters]) >= 2
    @test contains(res2[:sql_text], "WHERE")
  end

  # ===== Section 3: Ordering + Limiting + Offset =====
  @testset "Pagination and Ordering" begin
    # Test: ORDER BY with LIMIT and OFFSET
    q = DriverModel.objects
    q.order_by("forename")  # ascending order
    q.limit(10)
    q.offset(5)
    res = q.list(show_query=:dict)

    @test res isa Dict
    @test contains(res[:sql_text], "ORDER BY")
    @test contains(res[:sql_text], "LIMIT 10")
    @test contains(res[:sql_text], "OFFSET 5")
  end

  # ===== Section 3b: Django-style join spelling compatibility =====
  @testset "Django Join Syntax Compatibility" begin

    # ---- 3b-1: Short form via values() ----
    # Django convention: caller writes "driver__forename", not "driver_id__forename".
    # _resolve_django_join_field maps the logical name "driver" → physical FK column "driver_id".
    q_short = ResultDjangoModel.objects
    q_short.values("driver__forename")
    res_short = q_short.list(show_query=:dict)

    @test res_short isa Dict
    @test contains(res_short[:sql_text], "INNER JOIN")
    @test contains(res_short[:sql_text], "driver_id")   # physical column used in ON clause
    @test contains(res_short[:sql_text], "forename")
    @test !contains(res_short[:sql_text], "driver_id_id")  # must not double-suffix

    # ---- 3b-2: Explicit _id form via values() must throw ----
    # "driver_id__forename" is rejected because "driver_id" is the raw FK column name.
    # Callers must use the short logical form "driver__forename".
    q_explicit = ResultDjangoModel.objects
    q_explicit.values("driver_id__forename")
    err_values = try
      q_explicit.list(show_query=:dict)
      nothing
    catch e
      e
    end
    @test err_values isa ArgumentError
    @test contains(sprint(showerror, err_values), "driver__...")
    @test contains(sprint(showerror, err_values), "driver_id__...")

    # ---- 3b-3: Short form via filter() ----
    # The same resolution must happen in the WHERE clause path, not just SELECT.
    # Expected SQL: INNER JOIN on driver_id + WHERE with the forename parameter.
    q_filter = ResultDjangoModel.objects
    q_filter.filter("driver__forename" => "Lewis")
    res_filter = q_filter.list(show_query=:dict)

    @test res_filter isa Dict
    @test contains(res_filter[:sql_text], "INNER JOIN")  # join was built
    @test contains(res_filter[:sql_text], "WHERE")       # filter was applied
    @test contains(res_filter[:sql_text], "driver_id")  # ON clause uses the physical column
    @test res_filter[:parameters] == ["Lewis"]

    # ---- 3b-4: Explicit _id form via filter() must also throw ----
    # Ensures the guard is active on the filter path, not just the values path.
    q_filter_bad = ResultDjangoModel.objects
    q_filter_bad.filter("driver_id__forename" => "Lewis")
    err_filter = try
      q_filter_bad.list(show_query=:dict)
      nothing
    catch e
      e
    end
    @test err_filter isa ArgumentError
    @test contains(sprint(showerror, err_filter), "driver__...")

    # ---- 3b-5: Multi-hop join (tests the while-loop call site) ----
    # ConstrResult → result_id (FK→Result) → driver_id (FK→Driver) → forename.
    # Each hop uses short-form resolution: "result" → "result_id", "driver" → "driver_id".
    # Expected SQL: two INNER JOINs and "forename" in the SELECT.
    q_multi = ConstrResultDjangoModel.objects
    q_multi.values("result__driver__forename")
    res_multi = q_multi.list(show_query=:dict)

    @test res_multi isa Dict
    # Count INNER JOIN occurrences: one to result, one to driver
    @test length(collect(eachmatch(r"INNER JOIN", res_multi[:sql_text]))) == 2
    @test contains(res_multi[:sql_text], "forename")
    @test !contains(res_multi[:sql_text], "driver_id_id")  # no double-suffix on second hop

    # ---- 3b-6: CamelCase FK convention (real F1 style: driverid, not driver_id) ----
    # When the FK field has no underscore before "id" (e.g. "driverid"), short-form
    # resolution does not apply — there is no "driver_id" field to resolve to.
    # Callers must use the full physical field name: "driverid__forename".
    q_camel = ResultCamelDjangoModel.objects
    q_camel.values("driverid__forename")
    res_camel = q_camel.list(show_query=:dict)

    @test res_camel isa Dict
    @test contains(res_camel[:sql_text], "INNER JOIN")
    @test contains(res_camel[:sql_text], "driverid")   # full camelCase field name in ON clause
    @test contains(res_camel[:sql_text], "forename")
  end

  # ===== Section 4: Multiple Filters =====
  @testset "Multiple Filters" begin
    # Test: Multiple filter conditions (AND logic)
    q = DriverModel.objects
    q.filter("nationality" => "British")
    q.filter("forename__@contains" => "lewis")
    res = q.list(show_query=:dict)

    @test res isa Dict
    @test contains(res[:sql_text], "WHERE")
    @test contains(res[:sql_text], "AND")
    @test length(res[:parameters]) >= 2
  end

  # ===== Section 5: DISTINCT Queries =====
  @testset "Distinct Queries" begin
    # Test: DISTINCT to eliminate duplicates
    q = DriverModel.objects
    q.distinct(true)
    q.filter("nationality" => "Italian")
    res = q.list(show_query=:dict)

    @test res isa Dict
    @test contains(res[:sql_text], "DISTINCT")
    @test res[:parameters] == ["Italian"]
  end

  # ===== Section 6: Value Selection =====
  @testset "Value Selection" begin
    # Test: Selecting specific fields (projection)
    q = DriverModel.objects
    q.values("forename", "surname", "nationality")
    res = q.list(show_query=:dict)

    @test res isa Dict
    @test contains(res[:sql_text], "SELECT")
    @test contains(res[:sql_text], "forename")
    @test contains(res[:sql_text], "surname")
    @test contains(res[:sql_text], "nationality")
  end

  # ===== Section 7: show_query API Modes =====
  @testset "show_query Return Modes" begin
    q = DriverModel.objects
    q.filter("nationality" => "German")

    # Mode: :dict (default structured format)
    res_dict = q.list(show_query=:dict)
    @test res_dict isa Dict
    @test haskey(res_dict, :sql_text)
    @test haskey(res_dict, :parameters)

    # Mode: :sql (only SQL string)
    res_sql = q.list(show_query=:sql)
    @test res_sql isa String
    @test contains(res_sql, "SELECT")
    @test contains(res_sql, "drivers")

    # Mode: :params (only parameters array)
    res_params = q.list(show_query=:params)
    @test res_params isa Vector
    @test res_params == ["German"]

    # Mode: :inspection (should behave like :dict)
    res_inspection = q.list(show_query=:inspection)
    @test res_inspection isa Dict
    @test haskey(res_inspection, :sql_text)
  end

  # ===== Section 8: Terminal Methods with show_query =====
  @testset "Terminal Query Methods with show_query" begin
    # Test: list() returns different formats based on show_query
    q = DriverModel.objects
    q.filter("nationality" => "Spanish")

    # Test with :dict
    res_dict = q.list(show_query=:dict)
    @test res_dict isa Dict
    @test haskey(res_dict, :sql_text)

    # Test: list(:json) returns inspection metadata when show_query=:dict
    res_json = q.list(:json, show_query=:dict)
    @test res_json isa Dict
  end

  # ===== Section 8b: get() single-row SELECT generation =====
  @testset "get() SQL generation" begin
    # .get(filters...) builds a SELECT with the filter predicate plus a small LIMIT
    # (to detect MultipleObjectsReturned) — inspected here without executing.
    res = DriverModel.objects.get("id" => 42, show_query=:dict)

    @test res isa Dict
    @test contains(res[:sql_text], "SELECT")
    @test contains(res[:sql_text], "WHERE")
    @test contains(res[:sql_text], "\"id\" = \$1")
    @test contains(res[:sql_text], "LIMIT")
    @test res[:parameters] == [42]
    @test res[:operation] === :select
  end

  # ===== Section 9: Bulk Insert with show_query =====
  @testset "Bulk Operations" begin
    # Test: bulk_insert with show_query returns structured data
    df_insert = DataFrames.DataFrame(
      forename=["Max", "Charles", "Lewis"],
      surname=["Verstappen", "Leclerc", "Hamilton"],
      nationality=["Dutch", "Monegasque", "British"]
    )

    res_insert = DriverModel |> PormG.QueryBuilder.bulk_insert(df_insert, show_query=:dict)
    @test res_insert isa Dict
    @test haskey(res_insert, :sql_text)
    @test haskey(res_insert, :parameters)
    @test contains(res_insert[:sql_text], "INSERT")
    @test length(res_insert[:parameters]) >= 9  # 3 rows × 3 fields

    # Test: bulk_insert with :sql mode
    res_sql = DriverModel |> PormG.QueryBuilder.bulk_insert(df_insert, show_query=:sql)
    @test res_sql isa String
    @test contains(res_sql, "INSERT")

    # Test: bulk_insert with :params mode
    res_params = DriverModel |> PormG.QueryBuilder.bulk_insert(df_insert, show_query=:params)
    @test res_params isa Vector
  end

  # ===== Section 10: Multiple Chained Operations =====
  @testset "Chained Method Calls" begin
    # Test: Multiple chained operations in sequence
    q = DriverModel.objects
    q.filter("nationality" => "Dutch")
    q.order_by("forename")
    q.limit(5)

    res = q.list(show_query=:dict)

    @test res isa Dict
    @test contains(res[:sql_text], "WHERE")
    @test contains(res[:sql_text], "ORDER BY")
    @test contains(res[:sql_text], "LIMIT 5")
    @test res[:parameters] == ["Dutch"]
  end

  # ===== Section 11: Filter Combinations =====
  @testset "Filter Combinations" begin
    # Test: Q object with multiple conditions
    q = DriverModel.objects
    q.filter(Q("nationality" => "British", "forename__@contains" => "lew"))
    res = q.list(show_query=:dict)

    @test res isa Dict
    @test contains(res[:sql_text], "WHERE")
    @test length(res[:parameters]) >= 2

    # Test: Multiple filters with different operators
    q2 = RaceModel.objects
    q2.filter("year__@gte" => 2010)
    q2.filter("year__@lte" => 2020)
    res2 = q2.list(show_query=:dict)

    @test contains(res2[:sql_text], "AND")
    @test length(res2[:parameters]) == 2
  end

  # ===== Section 12: Query Inspection Without Execution =====
  @testset "Query Inspection" begin
    # Test: Can inspect query without executing it
    q = DriverModel.objects
    q.filter("nationality" => "Italian")
    q.order_by("surname")
    q.limit(20)
    q.offset(10)

    # Get just the SQL text
    sql = q.list(show_query=:sql)
    @test sql isa String
    @test contains(sql, "SELECT")
    @test contains(sql, "ORDER BY")
    @test contains(sql, "LIMIT 20")
    @test contains(sql, "OFFSET 10")

    # Get just the parameters
    params = q.list(show_query=:params)
    @test params == ["Italian"]

    # Get full structure
    full = q.list(show_query=:dict)
    @test full[:sql_text] == sql
    @test full[:parameters] == params
  end

  # ===================================================================
  # Section: _query_select returns valid SQL when all array slots are filled
  # ===================================================================
  # Regression: _query_select relied on finding an unassigned trailing slot in
  # the values array to trigger `return join(...)`. If every slot was assigned
  # the function fell through and returned `nothing`, producing "nothing" in
  # the SELECT clause. The fix adds an explicit return after the loop.
  @testset "SELECT clause renders correctly for every values count" begin
    # Single value — minimal case; the array has exactly one assigned slot.
    q1 = DriverModel.objects
    q1.values("forename")
    res1 = q1.list(show_query=:dict)
    @test res1 isa Dict
    @test contains(res1[:sql_text], "SELECT")
    @test !contains(res1[:sql_text], "nothing")  # bug symptom: literal "nothing"
    @test contains(res1[:sql_text], "forename")

    # Two values — exercises the loop body twice.
    q2 = DriverModel.objects
    q2.values("forename", "surname")
    res2 = q2.list(show_query=:dict)
    @test !contains(res2[:sql_text], "nothing")
    @test contains(res2[:sql_text], "forename")
    @test contains(res2[:sql_text], "surname")

    # All four model fields — fully packed array, no trailing unassigned slot.
    q3 = DriverModel.objects
    q3.values("id", "forename", "surname", "nationality")
    res3 = q3.list(show_query=:dict)
    @test !contains(res3[:sql_text], "nothing")
    @test contains(res3[:sql_text], "\"id\"")  # id is quoted to avoid keyword collision
  end

  # ===== Section: Concat variadic vs vector form =====
  @testset "Concat variadic and vector forms produce identical SQL" begin
    using PormG.Functions: Concat, Value

    # Variadic form: Concat("forename", Value(" "), "surname")
    q_var = DriverModel.objects
    q_var.values("full_name" => Concat("forename", Value(" "), "surname"))
    res_var = q_var.list(show_query=:dict)

    # Vector form: Concat(["forename", Value(" "), "surname"])
    q_vec = DriverModel.objects
    q_vec.values("full_name" => Concat(["forename", Value(" "), "surname"]))
    res_vec = q_vec.list(show_query=:dict)

    # Both should produce a CONCAT(...) SELECT clause
    @test contains(res_var[:sql_text], "CONCAT")
    @test contains(res_vec[:sql_text], "CONCAT")

    # Both forms must generate the same SQL
    @test res_var[:sql_text] == res_vec[:sql_text]
    @test res_var[:parameters] == res_vec[:parameters]
  end

  # ===== Section: Case/When expression as filter RHS =====
  @testset "Case/When as filter RHS value" begin
    using PormG.Functions: Case, When

    # Filter: year >= threshold where threshold comes from a Case expression
    q = RaceModel.objects
    q.filter(
      "year__@gte" => Case([
        When("year__@gte" => 2010, then = 2010),
      ], default = 1950)
    )
    res = q.list(show_query=:dict)

    # Must include a CASE WHEN ... END in the WHERE clause
    @test contains(res[:sql_text], "WHERE")
    @test contains(res[:sql_text], "CASE")
    @test contains(res[:sql_text], "WHEN")
    @test contains(res[:sql_text], "END")

    # Threshold values are parameterised — never interpolated into SQL
    @test !contains(res[:sql_text], "2010")
    @test !contains(res[:sql_text], "1950")
    @test 2010 in res[:parameters]
    @test 1950 in res[:parameters]
  end

end

