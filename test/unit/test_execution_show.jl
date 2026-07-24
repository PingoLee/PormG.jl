using Test
using PormG: object, Q
using PormG.Models: Model, CharField, IDField
import PormG
import DataFrames

# Initialize a dummy model for testing
TestDriver = Model("drivers",
  id=IDField(),
  forename=CharField(),
  surname=CharField()
)
TestDriver.connect_key = "default"

# Setup a default connection mock
# We don't need a real working connection because we'll only use show_query=:dict
# which returns before any actual database call.
struct MockPostgres <: PormG.PormGPostgres end
MockSettings = PormG.Configuration.Settings(
  connections=MockPostgres(),
  change_data=true
)
PormG.config["default"] = MockSettings

@testset "Execution show_query return values" begin
  q = TestDriver.objects.filter("forename" => "Lewis")

  # query with :dict
  res = q.list(show_query=:dict)
  @test res isa Dict
  @test haskey(res, :sql_text)
  @test haskey(res, :parameters)
  @test res[:parameters] == ["Lewis"]

  # query with :sql
  sql = q.list(show_query=:sql)
  @test sql isa String
  @test contains(sql, "drivers")
  @test contains(sql, "WHERE")

  # query with :params
  params = q.list(show_query=:params)
  @test params == ["Lewis"]

  # bulk_insert with :dict
  df = DataFrames.DataFrame(forename=["Max", "Fernando"], surname=["Verstappen", "Alonso"])
  res_bulk = TestDriver |> PormG.QueryBuilder.bulk_insert(df, show_query=:dict)
  @test res_bulk isa Dict
  @test haskey(res_bulk, :sql_text)
  @test res_bulk[:parameters] == ["Max", "Verstappen", "Fernando", "Alonso"]

  # bulk_update with :dict
  df_update = DataFrames.DataFrame(id=[1, 2], forename=["Max", "Fernando"], surname=["Verstappen", "Alonso"])
  res_update = TestDriver |> PormG.QueryBuilder.bulk_update(df_update, show_query=:dict)
  @test res_update isa Dict
  @test haskey(res_update, :sql_text)
  # bulk_update for postgres involves JOIN or WHERE source.id = table.id
  # We just care if it returns the dict and some params
  @test !isempty(res_update[:parameters])
end

@testset "Filter accepts SubString request values" begin
  exact_value = split("forename=Lewis", "=")[2]
  @test exact_value isa SubString{String}

  exact_query = TestDriver.objects.filter("forename" => exact_value)
  exact_result = exact_query.list(show_query=:dict)

  @test exact_result[:parameters] == ["Lewis"]

  in_values = split("Lewis,Max", ",")
  @test all(value -> value isa SubString{String}, in_values)

  in_query = TestDriver.objects.filter("forename__@in" => in_values)
  in_result = in_query.list(show_query=:dict)

  @test in_result[:parameters] == [["Lewis", "Max"]]
end

# ─────────────────────────────────────────────────────────────────────────────
# Subquery validation: reject multi-column IN subqueries during dry-run
# This guards the builder boundary before SQL execution so callers get a
# fix-oriented ArgumentError instead of a backend syntax failure.
# ─────────────────────────────────────────────────────────────────────────────
@testset "IN subqueries require exactly one projected column" begin
  subquery = TestDriver.objects.values("id", "forename")
  query = TestDriver.objects.filter("id__@in" => subquery)

  err = try
    query.list(show_query=:dict)
    nothing
  catch e
    e
  end

  @test err isa ArgumentError

  message = sprint(showerror, err)
  @test occursin("'id__@in' requires a subquery that returns exactly one column", message)
  @test occursin("currently selects 2 columns: id, forename", message)
  @test occursin("call .values(\"field_name\") on the subquery", message)
end

# ─────────────────────────────────────────────────────────────────────────────
# Subquery validation: single SQL-function projections stay valid
# The projection validator must treat SQL functions as ordinary one-column
# projections instead of throwing a MethodError while introspecting them.
# ─────────────────────────────────────────────────────────────────────────────
@testset "IN subqueries accept single SQL-function projections" begin
  # A single aliased SQL-function projection counts as one column — must pass validation.
  subquery = TestDriver.objects.values("max_id" => PormG.Functions.Max("id"))
  query = TestDriver.objects.filter("id__@in" => subquery)

  result = query.list(show_query=:dict)

  @test contains(result[:sql_text], "MAX")
  @test contains(result[:sql_text], "IN (")
  # Max("id") compiles to inline SQL with no bind parameters
  @test result[:parameters] == []
end

# ─────────────────────────────────────────────────────────────────────────────
# Subquery validation: two SQL-function projections must still be rejected
# The column-count validator must count SQL-function entries the same way it
# counts plain string entries — a pair-keyed function is still one column, so
# two such pairs must trigger the same ArgumentError as two plain strings.
# ─────────────────────────────────────────────────────────────────────────────
@testset "IN subqueries reject two SQL-function projections" begin
  subquery = TestDriver.objects.values("max_id" => PormG.Functions.Max("id"), "min_id" => PormG.Functions.Min("id"))
  query = TestDriver.objects.filter("id__@in" => subquery)

  err = try
    query.list(show_query=:dict)
    nothing
  catch e
    e
  end

  @test err isa ArgumentError
  message = sprint(showerror, err)
  @test occursin("'id__@in' requires a subquery that returns exactly one column", message)
end

@testset "Delete respects change_data guard" begin
  # TestDriver.connect_key is explicitly set to "default" (line 13 above), which matches
  # the MockSettings registered under PormG.config["default"] in this file's setup block.
  previous_change_data = PormG.config["default"].change_data

  try
    PormG.config["default"].change_data = false

    q = TestDriver.objects.filter("id" => 1)
    err = try
      q.delete()
      nothing
    catch e
      e
    end

    @test err isa ArgumentError
    # #205: unified write-disabled message names the op and points at the `config:` block.
    let m = lowercase(sprint(showerror, err))
      @test occursin("error in delete:", m) && occursin("not allowed to write", m) && occursin("change_data", m)
    end
  finally
    PormG.config["default"].change_data = previous_change_data
  end
end

@testset "Update respects change_data guard" begin
  previous_change_data = PormG.config["default"].change_data

  try
    PormG.config["default"].change_data = false

    q = TestDriver.objects.filter("id" => 1)
    err = try
      q.update("forename" => "Blocked")
      nothing
    catch e
      e
    end

    @test err isa ArgumentError
    let m = lowercase(sprint(showerror, err))
      @test occursin("error in update:", m) && occursin("not allowed to write", m) && occursin("change_data", m)
    end

    inspect_err = try
      q.update("forename" => "Blocked", show_query=:dict)
      nothing
    catch e
      e
    end

    @test inspect_err isa ArgumentError
    let m = lowercase(sprint(showerror, inspect_err))
      @test occursin("error in update:", m) && occursin("not allowed to write", m) && occursin("change_data", m)
    end
  finally
    PormG.config["default"].change_data = previous_change_data
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# Pagination guard on update():
# Standard SQL UPDATE does not support LIMIT, OFFSET, or ORDER BY. If a user
# chains these on a query and then calls .update(), PormG must throw an
# ArgumentError immediately — before any SQL is sent to the database —
# so that the developer gets a clear, actionable error rather than silently
# mutating all matching rows.
# ─────────────────────────────────────────────────────────────────────────────
@testset "Update rejects queries with limit, offset, or order_by" begin
  # All three variants must be caught regardless of whether show_query is used,
  # because the guard fires before SQL is built or dispatched.
  #
  # IMPORTANT: each sub-test creates a fresh handler via TestDriver.objects.filter(...).
  # limit(), offset(), and order_by() mutate the handler in place (last-call model), so
  # a shared q_base would accumulate state across sub-tests — the offset and order_by
  # guards would never be exercised in isolation because the residual limit from the
  # first sub-test would always fire first.

  # limit() must be rejected
  err_limit = try
    TestDriver.objects.filter("id__@gt" => 0).limit(5).update("forename" => "X")
    nothing
  catch e
    e
  end
  @test err_limit isa ArgumentError
  @test occursin("limit", lowercase(sprint(showerror, err_limit)))

  # offset() must be rejected — fresh handler, no prior limit
  err_offset = try
    TestDriver.objects.filter("id__@gt" => 0).offset(2).update("forename" => "X")
    nothing
  catch e
    e
  end
  @test err_offset isa ArgumentError
  @test occursin("offset", lowercase(sprint(showerror, err_offset)))

  # order_by() must be rejected — fresh handler, no prior limit or offset
  err_order = try
    TestDriver.objects.filter("id__@gt" => 0).order_by("id").update("forename" => "X")
    nothing
  catch e
    e
  end
  @test err_order isa ArgumentError
  @test occursin("order_by", lowercase(sprint(showerror, err_order)))

  # show_query=:dict must also be rejected (the guard fires before SQL dispatch)
  err_dry = try
    TestDriver.objects.filter("id__@gt" => 0).limit(3).update("forename" => "X", show_query=:dict)
    nothing
  catch e
    e
  end
  @test err_dry isa ArgumentError
  @test occursin("limit", lowercase(sprint(showerror, err_dry)))
end

# ─────────────────────────────────────────────────────────────────────────────
# allocate_primary_keys change_data guard
#
# allocate_primary_keys() is a write-like operation: it permanently advances a
# PostgreSQL sequence (nextval) or bumps the SQLite sqlite_sequence counter.
# Those sequence slots are consumed even if the subsequent bulk_insert never
# runs, so the function must honour the same change_data=false guard as every
# other write path (insert, update, bulk_insert, bulk_copy, bulk_update).
#
# Without the guard the call falls through to _allocate_pg_ids or
# _allocate_sqlite_ids and either silently consumes sequence slots or raises a
# low-level connection error — neither of which is the correct behaviour.
# The correct behaviour is an ArgumentError at the ORM layer, raised before any
# DB round-trip takes place.
# ─────────────────────────────────────────────────────────────────────────────
@testset "allocate_primary_keys respects change_data guard" begin
  previous_change_data = PormG.config["default"].change_data

  try
    PormG.config["default"].change_data = false

    # A plain DataFrame without an :id column — allocate_primary_keys would
    # normally fill that column from the database sequence.
    df = DataFrames.DataFrame(forename=["Lewis", "Max"], surname=["Hamilton", "Verstappen"])

    err = try
      PormG.allocate_primary_keys(TestDriver.objects, df)
      nothing
    catch e
      e
    end

    # Must raise an ArgumentError with a message about not being allowed to
    # insert (sequence allocation is an insert-class operation).
    @test err isa ArgumentError
    @test occursin("not allowed", lowercase(sprint(showerror, err)))

    # The DataFrame must not have been mutated: no :id column should be present
    # because the guard must fire before any allocation or clone takes place.
    @test !(:id in Symbol.(DataFrames.names(df)))
  finally
    PormG.config["default"].change_data = previous_change_data
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# do_exists error-propagation contract
#
# Before the fix, do_exists caught ALL exceptions and returned false — meaning
# a connection failure, SQL error, or permission denial was silently reported
# as "does not exist". That masks real infrastructure problems.
#
# The correct contract is:
#   • Return false only when the query executes successfully and yields 0 rows.
#   • Rethrow every other exception so the caller can handle real failures.
#
# The MockPostgres connection registered in this file has no real backend, so
# any fetch() call inside do_exists will raise an exception. Before the fix,
# .exists() would swallow that and return false. After the fix, it rethrows.
# ─────────────────────────────────────────────────────────────────────────────
@testset "do_exists rethrows database errors instead of returning false" begin
  q = TestDriver.objects.filter("forename" => "Lewis")

  # The MockPostgres backend has no real connection, so fetch() inside
  # do_exists raises a backend exception (not an ArgumentError).
  # The fixed implementation must propagate that exception rather than
  # swallowing it and returning false.
  err = try
    q.exists()
    nothing
  catch e
    e
  end

  # Must propagate — any exception is acceptable here, but it must not be
  # nothing (which would indicate the call silently returned false).
  @test err !== nothing
  # Must NOT be an ArgumentError produced by ORM query validation — those
  # are intentionally propagated by both old and new code. The backend error
  # from the mock connection is a different exception type.
  @test !(err isa ArgumentError)
end

@testset "do_exists propagates ArgumentError from ORM validation" begin
  # An __@in subquery that projects two columns is caught by ORM validation
  # and raises ArgumentError. Both the old and new code must propagate this.
  # This test ensures the fix did not inadvertently swallow ArgumentErrors.
  subquery = TestDriver.objects.values("id", "forename")
  q = TestDriver.objects.filter("id__@in" => subquery)

  err = try
    q.exists()
    nothing
  catch e
    e
  end

  @test err isa ArgumentError
  message = sprint(showerror, err)
  @test occursin("requires a subquery that returns exactly one column", message)
end
