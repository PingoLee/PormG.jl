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
# This exercises the while-loop call site of _resolve_fk_short_form.
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

# #345: the same `<x>_id` FK convention on a connection with NO django_prefix. Before #345,
# `_resolve_fk_short_form` returned immediately when `instruct.django === nothing`, so short-form
# join paths were switched on by a TABLE-NAMING option — the shape #344 removed from sequence
# syncing. #345 is what makes the prefix unnecessary for naming, so anyone who unset it silently
# lost Django-style join paths. These fixtures reuse "default" (no prefix) deliberately.
DriverNoPrefixModel = Model("np_drivers",
  id=IDField(),
  forename=CharField()
)
DriverNoPrefixModel.connect_key = "default"
DriverNoPrefixModel._module = Main

ResultNoPrefixModel = Model("np_results",
  id=IDField(),
  driver_id=ForeignKey(DriverNoPrefixModel, pk_field="id"),
  points=IntegerField(null=true)
)
ResultNoPrefixModel.connect_key = "default"
ResultNoPrefixModel._module = Main

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
    # _resolve_fk_short_form maps the logical name "driver" → physical FK column "driver_id".
    q_short = ResultDjangoModel.objects
    q_short.values("driver__forename")
    res_short = q_short.list(show_query=:dict)

    @test res_short isa Dict
    @test contains(res_short[:sql_text], "INNER JOIN")
    @test contains(res_short[:sql_text], "driver_id")   # physical column used in ON clause
    @test contains(res_short[:sql_text], "forename")
    @test !contains(res_short[:sql_text], "driver_id_id")  # must not double-suffix

    # ---- 3b-2: the explicit _id form is ACCEPTED and renders the same join (#345) ----
    # This used to throw, telling the caller to write "driver__forename" instead. The rejection was a
    # style rule with no correctness content — both spellings name the same FK and produce identical
    # SQL — and it was enforced only when `django_prefix` was set. Universalising it broke `cjoin`
    # (whose key must be in `model.field_names`, hence necessarily `driver_id`) and `PormGRow.save()`
    # (which splits a projected key on `__` and looks `driver` up in `model.fields` → KeyError). With
    # no spelling satisfying both paths, the rule was removed rather than the call sites rewritten.
    q_explicit = ResultDjangoModel.objects
    q_explicit.values("driver_id__forename")
    res_explicit = q_explicit.list(show_query=:dict)

    @test res_explicit isa Dict
    @test contains(res_explicit[:sql_text], "INNER JOIN")
    @test contains(res_explicit[:sql_text], "driver_id")
    @test contains(res_explicit[:sql_text], "forename")
    @test !contains(res_explicit[:sql_text], "driver_id_id")   # must not double-suffix

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

    # ---- 3b-4: the explicit _id form is accepted on the filter path too (#345) ----
    # Both spellings must agree everywhere, not just in values() — the two paths reach
    # `_resolve_fk_short_form` through different call sites.
    q_filter_explicit = ResultDjangoModel.objects
    q_filter_explicit.filter("driver_id__forename" => "Lewis")
    res_filter_explicit = q_filter_explicit.list(show_query=:dict)

    @test contains(res_filter_explicit[:sql_text], "INNER JOIN")
    @test contains(res_filter_explicit[:sql_text], "driver_id")
    @test res_filter_explicit[:parameters] == ["Lewis"]

    # The two spellings are interchangeable: same SQL, byte for byte.
    q_short_cmp = ResultDjangoModel.objects
    q_short_cmp.filter("driver__forename" => "Lewis")
    @test q_short_cmp.list(show_query=:dict)[:sql_text] == res_filter_explicit[:sql_text]

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

  # ===== Section 3c: the same spellings WITHOUT a django_prefix (#345) =====
  # The prefix-free twin of 3b above. `_resolve_fk_short_form` used to return immediately when
  # `instruct.django === nothing`, so on a connection with no prefix 3c-1 raised UnknownFieldError.
  # 3c-2 is a different kind of assertion: it passes on `main` too, and guards against the rejection
  # being re-added rather than against the old gate.
  @testset "Django Join Syntax Works Without a Prefix (#345)" begin

    # ---- 3c-1: short form resolves with django_prefix === nothing ----
    # `np_results` has no field `driver`; the FK is `driver_id`. Ungating this is additive only
    # because resolution now defers to anything that already claims the raw name — see the
    # reverse-accessor testset at the end of this file, which is what makes that true.
    q_short = ResultNoPrefixModel.objects
    q_short.values("driver__forename")
    res_short = q_short.list(show_query=:dict)

    @test res_short isa Dict
    @test contains(res_short[:sql_text], "INNER JOIN")
    @test contains(res_short[:sql_text], "driver_id")
    @test contains(res_short[:sql_text], "forename")
    @test !contains(res_short[:sql_text], "driver_id_id")   # must not double-suffix

    # ---- 3c-2: the explicit _id form keeps working, and renders the SAME join ----
    # Ungating resolution must not cost anyone the spelling they already use. `cjoin` can only ever
    # name the `_id` column (its key must be in `model.field_names`) and `PormGRow.save()` resolves a
    # projected key by splitting on `__` and looking the prefix up in `model.fields` — so the explicit
    # form is load-bearing, not merely tolerated. PormG's own `test/integration/test_row_mutation.jl`
    # writes `required_parent_id__label` against a connection with no prefix.
    q_explicit = ResultNoPrefixModel.objects
    q_explicit.values("driver_id__forename")
    res_explicit = q_explicit.list(show_query=:dict)

    @test res_explicit isa Dict
    # The JOIN is identical; only the projection ALIAS differs, because a result column is keyed by
    # the path the caller wrote. Comparing whole SQL would assert the wrong thing.
    join_of(sql) = sql[findfirst("INNER JOIN", sql).start:end]
    @test join_of(res_explicit[:sql_text]) == join_of(res_short[:sql_text])
    @test contains(res_explicit[:sql_text], "as \"driver_id__forename\"")
    @test contains(res_short[:sql_text], "as \"driver__forename\"")

    # ---- 3c-3: the filter() path too, not just values() ----
    q_filter = ResultNoPrefixModel.objects
    q_filter.filter("driver__forename" => "Lewis")
    res_filter = q_filter.list(show_query=:dict)

    @test contains(res_filter[:sql_text], "INNER JOIN")
    @test contains(res_filter[:sql_text], "driver_id")
    @test res_filter[:parameters] == ["Lewis"]


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


# ─────────────────────────────────────────────────────────────────────────────
# #345: short-form resolution must defer to a relation that already claims the name
#
# `_build_row_join` matches the forward-FK branch on the RESOLVED column but the
# reverse branch on the RAW segment, in that order. So rewriting `x` -> `x_id`
# unconditionally moves a path that reached the reverse branch onto the forward
# one: a different table, joined on a different column, with no error and no
# warning. Needs a real `set_models` run, because the collision is with
# `related_objects`, which only registration populates.
# ─────────────────────────────────────────────────────────────────────────────
PormG.config["fkshort_mock"] = PormG.Configuration.Settings(
  connections = MockPostgres(), change_data = true, db_def_folder = "fkshort_mock")

module FkShortFormModels
import PormG
import PormG.Models

Fkscircuit = Models.Model("fkscircuit", id = Models.IDField(), name = Models.CharField())

# Race carries a forward FK spelled `circuit_id`...
Race = Models.Model("fks_race",
  id = Models.IDField(),
  year = Models.IntegerField(),
  circuit_id = Models.ForeignKey(Fkscircuit, pk_field = "id"))

# ...and Lap claims the reverse accessor "circuit" on Race. This model set is LEGAL — do not reach
# for Django's fields.E302 to call it ill-formed. E302 compares a reverse accessor against the
# target's FIELD names, and a Django FK spelled `circuit` IS the field `circuit`, so it collides
# there. PormG declares that FK as `circuit_id`, which `circuit` does not collide with. The clash is
# only between the reverse name and the SHORT FORM the resolver would invent, which is exactly why
# the resolver must defer rather than silently pick a side.
#
# #396 added a registration-time check that a reverse accessor does not shadow a field on the model
# it lands on. That check is `haskey(related_model.fields, accessor)` VERBATIM and deliberately does
# NOT go through `_resolve_fk_short_form` — widening it to the short form would outlaw this fixture.
# If a future change makes this model set raise, the check has been over-widened, not this fixture
# made wrong.
Lap = Models.Model("fks_lap",
  id = Models.IDField(),
  name = Models.CharField(),
  race_id = Models.ForeignKey(Race, pk_field = "id", related_name = "circuit"))

PormG.Models.set_models(@__MODULE__, "fkshort_mock")
end

@testset "Short-form FK resolution defers to an existing reverse accessor (#345)" begin
  FKS = FkShortFormModels
  @test haskey(FKS.Race.related_objects, "circuit")   # the collision exists
  @test haskey(FKS.Race.fields, "circuit_id")

  q = FKS.Race.objects
  q.values("circuit__name")
  sql = q.list(show_query=:dict)[:sql_text]

  # The REVERSE reading wins, unchanged from before the gate was lifted: join the child on the
  # parent's PK. Resolving to `circuit_id` would join fkscircuit on "Tb"."circuit_id" instead —
  # a working query silently reading a different table.
  @test contains(sql, "fks_lap")
  @test contains(sql, "\"Tb\".\"id\" = \"Tb_1\".\"race_id\"")
  # The table is `fkscircuit`, with no underscore — spelling this `fks_circuit` would make the
  # negative assertion pass no matter which branch the resolver took.
  @test !contains(sql, "fkscircuit")

  # The short form still resolves where nothing else claims the name: `fks_lap` has no reverse
  # accessor "race", so `race__year` reaches the FK column `race_id`.
  q2 = FKS.Lap.objects
  q2.values("race__year")
  sql2 = q2.list(show_query=:dict)[:sql_text]
  @test contains(sql2, "fks_race")
  @test contains(sql2, "\"Tb\".\"race_id\"")

  # `cjoin` can only ever name the `_id` column — `_cjoin` requires its key to be in
  # `model.field_names`, and for an FK that is `circuit_id`. Rejecting that spelling at
  # query-build time left cjoin with no legal key at all, and its own error message recommended
  # a form it then refused. Guards the whole path end to end.
  q3 = FKS.Race.objects
  q3.cjoin("circuit_id" => "Fkscircuit", filters = ["name" => "Monza"], warn = false)
  q3.values("year")
  res3 = q3.list(show_query=:dict)
  @test res3 isa Dict
  @test contains(res3[:sql_text], "fkscircuit")
  @test res3[:parameters] == ["Monza"]
end

# ─────────────────────────────────────────────────────────────────────────────
# #345: the reverse-accessor rule is the SAME on a prefixed connection
#
# The rule this pins is a real behaviour change, not a restoration. Before #345
# the clash resolved BOTH ways depending on `django_prefix`: prefix-less
# connections read the reverse relation (the gate returned early), prefixed ones
# read the forward FK (resolution ran). A prefixed app therefore changes here.
# The rule chosen is that an author's explicit `related_name` outranks a name
# this ORM invents — asserted for the prefixed direction so nobody "fixes" the
# guard back into a prefix-conditional one.
# ─────────────────────────────────────────────────────────────────────────────
PormG.config["fkshort_prefixed"] = PormG.Configuration.Settings(
  connections = MockPostgres(), change_data = true,
  db_def_folder = "fkshort_prefixed", django_prefix = "dash")

module FkShortFormPrefixedModels
import PormG
import PormG.Models

Fkspcircuit = Models.Model("fkspcircuit", id = Models.IDField(), name = Models.CharField())

Race = Models.Model("fksp_race",
  id = Models.IDField(),
  year = Models.IntegerField(),
  circuit_id = Models.ForeignKey(Fkspcircuit, pk_field = "id"))

Lap = Models.Model("fksp_lap",
  id = Models.IDField(),
  name = Models.CharField(),
  race_id = Models.ForeignKey(Race, pk_field = "id", related_name = "circuit"))

PormG.Models.set_models(@__MODULE__, "fkshort_prefixed")
end

@testset "The reverse-accessor rule is prefix-independent (#345)" begin
  FKSP = FkShortFormPrefixedModels
  @test haskey(FKSP.Race.related_objects, "circuit")
  @test haskey(FKSP.Race.fields, "circuit_id")

  q = FKSP.Race.objects
  q.values("circuit__name")
  sql = q.list(show_query=:dict)[:sql_text]

  # Reverse wins here too. On `main` this connection resolved `circuit` -> `circuit_id` and joined
  # the parent forward, so this assertion is the one that would go red if the guard were made
  # conditional on the prefix again — in either direction.
  @test contains(sql, "fksp_lap")
  @test contains(sql, "\"Tb\".\"id\" = \"Tb_1\".\"race_id\"")
  @test !contains(sql, "fkspcircuit")
end

# ─────────────────────────────────────────────────────────────────────────────
# #345: an EMPTY django_prefix is the absence of one, not a prefix of ""
#
# `Settings` is populated generically from connection.yml's `config:` block
# (`hasfield` -> `setfield!`), so `django_prefix: ''` reaches the field. Every
# consumer composes "$(prefix)_", so treating "" as set derives `_dim_uf` for a
# table named `dim_uf`. Before #345 that at least failed loudly — the generated
# `Model("_dim_uf", …)` was rejected at include time — but with the prefix moved
# into `db_table` the file would load and every query would read `_dim_uf`.
# ─────────────────────────────────────────────────────────────────────────────
const EMPTY_PREFIX_SETTINGS = PormG.Configuration.Settings(
  connections = MockPostgres(), change_data = true,
  django_prefix = "", db_def_folder = "empty_prefix_q")
PormG.config["empty_prefix_q"] = EMPTY_PREFIX_SETTINGS

@testset "An empty django_prefix is treated as unset (#345)" begin
  empty_prefix = EMPTY_PREFIX_SETTINGS

  # `_django_app_label` is the single normalizer every consumer of the setting goes through, so it
  # is the assertion that covers all of them at once.
  @test PormG.Models._django_app_label(empty_prefix) === nothing

  # `get_model_name` must not strip a bare "_" from every logical name.
  named = PormG.Models.Model("dim_uf", Dict{String, PormG.PormGField}("id" => PormG.Models.IDField()))
  @test PormG.Models.get_model_name(named, empty_prefix, false) == "dim_uf"

  # The RENDER half of this contract moved out of `Model_to_str` in #346 — it no longer takes a
  # `Settings` at all — and is now asserted at the importer, which is where the app label turns into
  # a `db_table`: `test_import_django_models.jl` → "Django importer pins the ManyToMany join table
  # under a prefix (#345)" checks that `django_prefix = ""` output is byte-identical to unset.
end

# The QUERY side must agree with the render side. `build_query.jl` stashes the prefix on
# `instruct.django` as `"$(prefix)_"`, which the reverse-join fallback prepends to any table not
# pinned by `db_table` — so an empty prefix there means every such table is looked up with a leading
# underscore. A reverse join is the shortest path to observing it. The config this module registers
# against is `EMPTY_PREFIX_SETTINGS` above, at top level: `set_models` runs at MODULE LOAD time, so
# the registration cannot live inside a @testset body without making the file's load order depend on
# a test having run.
module EmptyPrefixReverseModels
import PormG
import PormG.Models

Epteam = Models.Model("epteam", id = Models.IDField(), name = Models.CharField())
Epdriver = Models.Model("epdriver",
  id = Models.IDField(),
  surname = Models.CharField(),
  team_id = Models.ForeignKey(Epteam, pk_field = "id", related_name = "drivers"))

PormG.Models.set_models(@__MODULE__, "empty_prefix_q")
end

@testset "An empty django_prefix does not underscore-prefix reverse join tables (#345)" begin
  q = EmptyPrefixReverseModels.Epteam.objects
  q.values("drivers__surname")
  sql = q.list(show_query=:dict)[:sql_text]

  # `epdriver` declares no db_table, so the reverse join takes the prefix fallback. With `""` read
  # as a real prefix that fallback emits `_epdriver`, and the query targets a table that does not
  # exist — silently, since nothing validates a table name at build time.
  @test contains(sql, "epdriver")
  @test !contains(sql, "_epdriver")
end
