"""
Comprehensive test suite for the dedicated inspect_query() API.

The inspect_query() API provides explicit, type-safe query inspection without
the ambiguity of show_query's Union{Bool, Symbol} signature. It returns a 
rich dictionary with SQL, parameters, and comprehensive metadata.

All tests use mock PostgreSQL connections (no live database required).
"""

using Test
using PormG
using PormG.Models: Model, CharField, IDField, IntegerField, DateTimeField
using PormG.QueryBuilder: Q, Qor, F, Exists, OuterRef, Subquery, Count, inspect_query, list, update, delete, bulk_insert, bulk_update
import DataFrames

# Initialize test models
DriverModel = Model("drivers",
  id = IDField(),
  forename = CharField(),
  surname = CharField(),
  nationality = CharField(null=true) # Allow null for easy testing
)
DriverModel.connect_key = "default"

RaceModel = Model("races",
  id = IDField(),
  name = CharField(),
  year = IntegerField(null=true) # Allow null for easy testing
)
RaceModel.connect_key = "default"

DriverNoteModel = Model("driver_notes",
  id = IDField(),
  driver_id = IntegerField(),
  body = CharField()
)
DriverNoteModel.connect_key = "default"

RaceNoteModel = Model("race_notes",
  id = IDField(),
  race_id = IntegerField(),
  note = CharField()
)
RaceNoteModel.connect_key = "default"

# Mock settings for test mode (no DB connection needed)
struct MockPostgres <: PormG.PormGPostgres end
MockSettings = PormG.Configuration.Settings(
    connections = MockPostgres(),
    change_data = true
)
PormG.config["default"] = MockSettings

@testset "Dedicated Inspection API (inspect_query)" begin

  # ===== Section 1: Basic Inspection Structure =====
  @testset "Inspection Result Structure" begin
    # Test: inspect_query returns a Dict with all required fields
    q = DriverModel.objects
    q.filter("nationality" => "British")
    
    result = inspect_query(q)
    
    @test result isa Dict
    # Check for required fields
    @test haskey(result, :sql_text)
    @test haskey(result, :parameters)
    @test haskey(result, :dialect)
    @test haskey(result, :model)
    @test haskey(result, :operation)
    @test haskey(result, :bucketing)
    @test haskey(result, :parameter_count)
    @test haskey(result, :parameter_buckets)
  end

  # ===== Section 2: Operation Detection Metadata =====
  @testset "Operation Type Detection" begin
    # Test: list(show_query=:dict) returns :operation => :select
    q = DriverModel.objects
    q.filter("nationality" => "British")
    
    res_select = q.list( show_query=:dict)
    @test res_select[:operation] === :select
    @test res_select[:model] == "drivers"
    
    # Test: update(show_query=:dict) returns :operation => :update
    # We mock the return as it wouldn't connect but show_query handles cases before fetch
    res_update = q.update("forename" => "Lewis", show_query=:dict)
    @test res_update[:operation] === :update
    @test res_update[:model] == "drivers"
    @test contains(res_update[:sql_text], "UPDATE")
    
    # Test: delete(show_query=:dict) returns :operation => :delete
    res_delete = q.delete( show_query=:dict)
    @test res_delete[:operation] === :delete
    @test res_delete[:model] == "drivers"
    @test contains(res_delete[:sql_text], "DELETE")

    # Test: bulk_insert(show_query=:dict) returns :operation => :insert
    df = DataFrames.DataFrame(forename=["Lewis", "Valtteri"], surname=["Hamilton", "Bottas"])
    res_bulk_insert = bulk_insert(DriverModel.objects, df, show_query=:dict)
    @test res_bulk_insert[:operation] === :insert
    @test res_bulk_insert[:model] == "drivers"
    @test contains(res_bulk_insert[:sql_text], "INSERT")

    # Test: bulk_update(show_query=:dict) returns :operation => :update
    res_bulk_update = bulk_update(DriverModel.objects, df, columns=["forename"], match_on=["surname"], show_query=:dict)
    @test res_bulk_update[:operation] === :update
    @test res_bulk_update[:model] == "drivers"
    @test contains(res_bulk_update[:sql_text], "UPDATE")

    # Test: inspect_query(operation=:delete) returns :operation => :delete (explicitly requested)
    res_inspect_delete = inspect_query(q, operation=:delete)
    @test res_inspect_delete[:operation] === :delete

    
  end

  # Test: DELETE Inspection: Verify SQL and Metadata
  @testset "DELETE Inspection: Detailed Verification" begin
      q_del = DriverModel.objects;
      q_del.filter("id" => 880001);

      # Using show_query=:dict as it's the preferred pattern for mutations.
      # Deletion may return a Vector for cascaded operations; pick the drivers entry.
      inspection_raw = q_del.delete(show_query=:dict)

      inspection = if inspection_raw isa Vector
          idx = findfirst(i -> i[:model] == "drivers", inspection_raw)
          inspection_raw[idx]
      else
          inspection_raw
      end

      @test inspection[:operation] === :delete
      @test contains(inspection[:sql_text], "DELETE FROM")
      @test occursin("drivers", lowercase(inspection[:sql_text]))
      @test inspection[:parameter_count] == 1
      @test inspection[:parameters] == [880001]
      @test inspection[:dialect] === :postgresql
  end

  # ===== Section 3: Operation Auto-Detection Heuristic =====
  @testset "Heuristic Operation Detection" begin
    # Test: Auto-detect :select (default)
    q = DriverModel.objects.filter("id" => 1)
    res = inspect_query(q)
    @test res[:operation] === :select
    
    # Test: Auto-detect :update (has insert data + filters)
    q_up = DriverModel.objects.filter("id" => 1)
    # Manually populate insert field for the test. It must be an OrderedDict — that is the
    # declared field type (types.jl: `insert::OrderedDict{String,Any}`, ordered so INSERT/UPDATE
    # column lists follow call order, #97). OrderedCollections 2 removed the implicit
    # Dict→OrderedDict conversion (ordering would be undefined), so a plain Dict now throws here.
    q_up.object.insert = PormG.QueryBuilder.OrderedCollections.OrderedDict{String,Any}("forename" => "Ayrton")
    res_up = inspect_query(q_up)
    @test res_up[:operation] === :update
    
    # Test: Auto-detect :insert (has insert data, no filters)
    q_in = DriverModel.objects.copy()
    q_in.object.insert = PormG.QueryBuilder.OrderedCollections.OrderedDict{String,Any}(
        "forename" => "Ayrton", "surname" => "Senna")
    res_in = inspect_query(q_in)
    @test res_in[:operation] === :insert
    
    # Reset for following tests
  end

  # ===== Section 4: SQL and Parameter Correctness =====
  @testset "SQL Generation and Parameters" begin
    # Test: Simple filter generates correct SQL
    q = DriverModel.objects
    q.filter("nationality" => "Italian")
    res = inspect_query(q)
    
    @test res[:sql_text] isa String
    @test contains(res[:sql_text], "SELECT")
    @test contains(res[:sql_text], "drivers")  # May be quoted as "drivers"
    @test contains(res[:sql_text], "WHERE")
    @test res[:parameters] == ["Italian"]
    @test res[:parameter_count] == 1
    
    # Test: Multiple filters
    q2 = RaceModel.objects
    q2.filter("year__@gte" => 2010)
    q2.filter("year__@lte" => 2020)
    res2 = inspect_query(q2)
    
    @test contains(res2[:sql_text], "AND")
    @test length(res2[:parameters]) == 2
    @test res2[:parameter_count] == 2
    @test res2[:parameters] == [2010, 2020]
  end

  # ===== Section 3: Metadata Fields =====
  @testset "Metadata Accuracy" begin
    # Test: Model name is correctly reported
    q = DriverModel.objects
    q.filter("forename" => "Lewis")
    res = inspect_query(q)
    
    @test res[:model] == "drivers"
    @test res[:operation] == :select
    
    # Test: Operation type detection (all read queries are :select in current implementation)
    q2 = RaceModel.objects
    q2.limit(5)
    res2 = inspect_query(q2)
    
    @test res2[:model] == "races"
    @test res2[:operation] == :select
  end

  # ===== Section 4: Dialect Detection =====
  @testset "Dialect Detection" begin
    # Test: PostgreSQL dialect is detected from mock connection
    q = DriverModel.objects
    res = inspect_query(q)
    
    @test res[:dialect] == :postgresql
    @test res[:bucketing] == :numbered
  end

  # ===== Section 5: Complex Query Inspection =====
  @testset "Complex Queries" begin
    # Test: Chained operations all reflected in inspection
    q = DriverModel.objects
    q.filter("nationality" => "Dutch")
    q.order_by("forename")
    q.limit(10)
    q.offset(5)
    q.distinct(true)
    
    res = inspect_query(q)
    
    @test res[:sql_text] isa String
    @test contains(res[:sql_text], "DISTINCT")
    @test contains(res[:sql_text], "ORDER BY")
    @test contains(res[:sql_text], "LIMIT 10")
    @test contains(res[:sql_text], "OFFSET 5")
    @test res[:parameters] == ["Dutch"]
    @test res[:parameter_count] == 1
  end

  # ===== Section 6: Query Projection (Values) =====
  @testset "Value Selection Inspection" begin
    # Test: Selected fields are reflected in SQL
    q = DriverModel.objects
    q.values("forename", "surname", "nationality")
    q.filter("nationality" => "German")
    
    res = inspect_query(q)
    
    @test contains(res[:sql_text], "forename")
    @test contains(res[:sql_text], "surname")
    @test contains(res[:sql_text], "nationality")
    @test res[:parameters] == ["German"]
  end

  # ===== Section 7: Multiple Filter Types =====
  @testset "Operator Inspection" begin
    # Test: Various operators generate expected SQL
    q = RaceModel.objects
    q.filter("year__@gt" => 2000)
    res = inspect_query(q)
    
    @test contains(res[:sql_text], ">")
    @test res[:parameters] == [2000]
    
    # Test: Contains operator
    q2 = DriverModel.objects
    q2.filter("forename__@contains" => "lew")
    res2 = inspect_query(q2)
    
    @test contains(res2[:sql_text], "LIKE") || contains(res2[:sql_text], "LOWER")
  end

  # ===== Section 8: Parameter Ordering Verification =====
  @testset "Parameter Ordering" begin
    # Test: Parameters appear in the order they're added
    q = DriverModel.objects
    q.filter("nationality" => "British")
    q.filter("forename__@contains" => "lewis")
    q.order_by("surname")  # ordering adds no parameters
    
    res = inspect_query(q)
    
    # Parameters should be in the order: WHERE clauses (British), then WHERE clauses (escaped for LIKE)
    @test length(res[:parameters]) == 2
    @test res[:parameters][1] == "British"
    # LIKE operator adds % for pattern matching, so check for that pattern
    @test contains(res[:parameters][2], "lewis")
  end

  # ===== Section 9: Curried API =====
  @testset "Curried Method Syntax" begin
    # Test: Pipe syntax works with curried inspect_query
    q = DriverModel.objects
    q.filter("nationality" => "Spanish")
    
    res = q |> inspect_query()
    
    @test res isa Dict
    @test haskey(res, :sql_text)
    @test res[:model] == "drivers"
  end

  # ===== Section 10: Empty Query Inspection =====
  @testset "Empty Query" begin
    # Test: Query without filters still inspects correctly
    q = RaceModel.objects
    
    res = inspect_query(q)
    
    @test res[:sql_text] isa String
    @test contains(res[:sql_text], "SELECT")
    @test contains(res[:sql_text], "races")  # May be quoted as "races"
    @test isempty(res[:parameters])
    @test res[:parameter_count] == 0
  end

  # ===== Section 11: Distinct Inspection =====
  @testset "Distinct Queries" begin
    # Test: DISTINCT modifier is visible in inspection
    q = DriverModel.objects
    q.distinct(true)
    q.filter("nationality" => "French")
    
    res = inspect_query(q)
    
    @test contains(res[:sql_text], "DISTINCT")
    @test res[:parameters] == ["French"]
  end

  # ===== Section 11b: DISTINCT + ORDER BY projection guard (#76) =====
  @testset "Distinct + Order By must project the sort key (#76)" begin
    # Under SELECT DISTINCT, an ORDER BY term that is not part of the projection is rejected by
    # PostgreSQL and the SQL standard (SQL Server / Oracle / DB2 / default-mode MySQL all reject it)
    # while SQLite runs it with a nondeterministic DISTINCT/order interaction. PormG raises on both
    # backends so they stay aligned. The guard matches the resolved SQL *expression*, not the base
    # column, so it tolerates aliased columns yet still rejects `ORDER BY f(x)` when only `x` is
    # projected. See issue #76.
    DistinctModel = Model("distinct_drivers",
      id = IDField(),
      surname = CharField(),
      nationality = CharField(null = true),
      created_at = DateTimeField(null = true),
    )
    DistinctModel.connect_key = "default"

    @testset "unselected plain column raises with an actionable message" begin
      # The reported bug: distinct nationalities ordered by a column that isn't projected.
      err = try
        DistinctModel.objects.values("nationality").distinct().order_by("surname").list(show_query = :sql)
        nothing
      catch e
        e
      end
      @test err isa PormGError
      msg = sprint(showerror, err)
      # Discriminating: names the offending column, the DISTINCT context, and the .values() fix —
      # not a bare @test_throws that any ArgumentError would satisfy.
      @test occursin("surname", msg)
      @test occursin("DISTINCT", msg)
      @test occursin(".values(", msg)
    end

    @testset "ordering by a function of a selected column raises" begin
      # PG rejects `ORDER BY DATE(created_at)` even though created_at is projected: the *expression*
      # (not the base column) must be in the select list. A crude column-membership check would wrongly
      # allow this; the expression-membership guard matches PG. Cause-check the message (not a bare
      # @test_throws) so an unrelated ArgumentError — e.g. a future transform-resolution change — can't
      # masquerade as a pass.
      err = try
        DistinctModel.objects.values("created_at").distinct().
          order_by("created_at__@date").list(show_query = :sql)
        nothing
      catch e
        e
      end
      @test err isa PormGError
      msg = sprint(showerror, err)
      @test occursin("created_at", msg)   # names the offending order term
      @test occursin("DISTINCT", msg)
      @test occursin("projection", msg)
    end

    @testset "valid distinct + order forms still render (no false positives)" begin
      # aligned: the order key is the (only) projected column
      @test DistinctModel.objects.values("nationality").distinct().
        order_by("nationality").list(show_query = :sql) isa String
      # no explicit projection => SELECT DISTINCT * (the sort key is covered by *)
      sql_star = DistinctModel.objects.distinct().order_by("surname").list(show_query = :sql)
      @test occursin("DISTINCT *", sql_star)
      # explicit wildcard projection likewise covers the sort key
      @test DistinctModel.objects.values("*").distinct().
        order_by("surname").list(show_query = :sql) isa String
      # aliased source: SELECT surname AS nm ... ORDER BY surname — surname IS the selected expression
      @test DistinctModel.objects.values("nm" => "surname").distinct().
        order_by("surname").list(show_query = :sql) isa String
      # projected function: the DATE(created_at) expression is itself in the select list
      @test DistinctModel.objects.values("created_at", "d" => "created_at__@date").distinct().
        order_by("created_at__@date").list(show_query = :sql) isa String
      # scope guard: the check is DISTINCT-only — a non-distinct unselected order must NOT raise
      @test DistinctModel.objects.values("nationality").
        order_by("surname").list(show_query = :sql) isa String
    end
  end

  # ===== Section 12: Deep Copy Safety =====
  @testset "Query Immutability" begin
    # Test: Inspecting a query doesn't modify it
    q = DriverModel.objects
    q.filter("nationality" => "Swedish")
    
    # First inspection
    res1 = inspect_query(q)
    params1 = deepcopy(res1[:parameters])
    
    # Modify the query after inspection
    q.filter("forename" => "Valtteri")
    
    # Second inspection should reflect the new filter
    res2 = inspect_query(q)
    
    @test res1[:parameter_count] == 1
    @test res2[:parameter_count] == 2
    @test res2[:parameters] == ["Swedish", "Valtteri"]
  end

  # ===== Section 13: show_query Validation =====
  @testset "show_query Mode Validation" begin
    # Test: Invalid show_query modes throw error
    q = DriverModel.objects
    
    # Valid modes should work (using show_query to avoid actual DB execution with MockPostgres)
    @test (q.list(show_query=:dict)) isa Dict
    @test (q.list(show_query=:params)) isa Vector
    @test (q.list(show_query=:sql)) isa String
    @test (q.list(show_query=:none)) === nothing
    
    # Invalid mode should throw
    @test_throws PormGError (q.list(show_query=:invalid))
  end

  # ===== Section 14: Comparison: inspect_query vs show_query =====
  @testset "API Consistency" begin
    # Test: inspect_query and show_query=:dict return same core data
    q1 = DriverModel.objects
    q1.filter("nationality" => "Monaco")
    
    q2 = DriverModel.objects
    q2.filter("nationality" => "Monaco")
    
    # Using dedicated API
    inspection = inspect_query(q1)
    
    # Using show_query (for backward compatibility)
    show_result = q2.list(show_query=:dict)
    
    # Core SQL and parameters should match
    @test inspection[:sql_text] == show_result[:sql_text]
    @test inspection[:parameters] == show_result[:parameters]
    
    # But inspection has richer metadata
    @test haskey(inspection, :dialect)
    @test haskey(inspection, :bucketing)
    @test haskey(inspection, :parameter_buckets)
  end

  # ===== Section 15: Q Object Filters =====
  @testset "Q Object Inspection" begin
    # Test: Q objects with multiple conditions
    q = DriverModel.objects
    q.filter(Q("nationality" => "British", "forename__@contains" => "lew"))
    
    res = inspect_query(q)
    
    @test res isa Dict
    @test length(res[:parameters]) >= 2
    @test contains(res[:sql_text], "WHERE")
  end

  # ===== Section 16: Parameter Bucket Visibility (SQLite Focus) =====
  @testset "Parameter Buckets" begin
    # Test: Inspection reveals bucket structure (PostgreSQL shows empty since not positional)
    q = DriverModel.objects
    q.filter("nationality" => "Canadian")
    
    res = inspect_query(q)
    
    # For PostgreSQL, bucket_breakdown should be empty
    @test res[:parameter_buckets] isa Dict
    # For positional databases, it would show the breakdown
  end

  # ───────────────────────────────────────────────────────────────────────────
  # Correlated EXISTS inspection: PostgreSQL should render EXISTS (SELECT 1 ...)
  # with OuterRef("pk") resolved to the parent alias and text matching still
  # represented as a normal bind parameter.
  # ───────────────────────────────────────────────────────────────────────────
  @testset "Correlated Exists Inspection" begin
    note_query = DriverNoteModel.objects.filter(
      "driver_id" => OuterRef("pk"),
      "body__@icontains" => "rain",
    )

    q = DriverModel.objects
    q.filter(Exists(note_query))
    q.values("id")

    res = inspect_query(q)

    @test contains(res[:sql_text], "EXISTS (SELECT 1")
    @test contains(res[:sql_text], "FROM \"driver_notes\" as \"R1\"")
    @test contains(res[:sql_text], "\"R1\".\"driver_id\" = \"Tb\".\"id\"")
    @test contains(res[:sql_text], "\"R1\".\"body\" ILIKE \$1")
    @test contains(res[:sql_text], "LIMIT 1)")
    @test res[:parameters] == ["%rain%"]
    @test res[:dialect] == :postgresql
  end

  # ───────────────────────────────────────────────────────────────────────────
  # Correlated EXISTS with a named (non-pk) OuterRef field.
  # OuterRef("forename") must bind to the outer alias column, not become a
  # parameter.  The scalar icontains filter must remain a bound parameter.
  # ───────────────────────────────────────────────────────────────────────────
  @testset "Correlated Exists Inspection - named OuterRef field" begin
    note_query = DriverNoteModel.objects.filter(
      "driver_id" => OuterRef("id"),
      "body__@icontains" => "wet",
    )

    q = DriverModel.objects
    q.filter("nationality" => "British", Exists(note_query))
    q.values("id", "surname")

    res = inspect_query(q)
    sql = res[:sql_text]

    # EXISTS block is present and correlated on the named field
    @test contains(sql, "EXISTS (SELECT 1")
    @test contains(sql, "\"R1\".\"driver_id\" = \"Tb\".\"id\"")
    # Scalar filter before EXISTS must be AND-connected, not absorbed into the subquery.
    # Django-compatible pattern: WHERE "Tb"."nationality" = $1 AND EXISTS (... LIMIT 1)
    # Normalize whitespace (the builder emits " AND \n   " between conditions).
    normalized_sql = replace(sql, r"\s+" => " ")
    @test contains(normalized_sql, "AND EXISTS (SELECT 1")
    # Scalar filter remains parameterized; nationality filter is $1, icontains is $2
    @test contains(sql, "\"R1\".\"body\" ILIKE \$2")
    @test contains(sql, "LIMIT 1)")
    @test res[:parameters] == ["British", "%wet%"]
    @test res[:dialect] == :postgresql
  end

  # ───────────────────────────────────────────────────────────────────────────
  # Scalar correlated Subquery projection (#92) on PostgreSQL: the linear $N
  # collector must number parameters in SQL-text order — inner subquery ($1),
  # projected EXISTS ($2), then the outer WHERE ($3) — with the scalar wrapped
  # in parens, aliased, and correlated against the outer alias "Tb".
  # ───────────────────────────────────────────────────────────────────────────
  @testset "Subquery projection (#92) - PostgreSQL scalar + Exists column" begin
    note_query = DriverNoteModel.objects.filter(
      "driver_id" => OuterRef("id"),
      "body__@icontains" => "rain",
    )
    note_query.values("n" => Count("id"))

    q = DriverModel.objects
    q.filter("nationality" => "British")
    q.values("surname",
             "n_rain_notes" => Subquery(note_query),
             "has_rain" => Exists(note_query))

    res = inspect_query(q)
    sql = res[:sql_text]

    # Scalar subquery column: paren-wrapped aggregate, correlated, aliased.
    @test contains(sql, "(SELECT")
    @test contains(sql, "COUNT(\"R1\".\"id\")")
    @test contains(sql, "\"R1\".\"driver_id\" = \"Tb\".\"id\"")
    @test contains(sql, ") as \"n_rain_notes\"")
    # EXISTS column reuses the EXISTS(SELECT 1 … LIMIT 1) template with its own alias (R2).
    @test contains(sql, "EXISTS (SELECT 1")
    @test contains(sql, "\"R2\".\"driver_id\" = \"Tb\".\"id\"")
    @test contains(sql, "LIMIT 1) as \"has_rain\"")
    # Linear $N numbering follows SQL-text order: subquery, EXISTS, outer WHERE.
    @test contains(sql, "\"R1\".\"body\" ILIKE \$1")
    @test contains(sql, "\"R2\".\"body\" ILIKE \$2")
    @test contains(sql, "\"Tb\".\"nationality\" = \$3")
    @test res[:parameters] == ["%rain%", "%rain%", "British"]
    # A projected subquery is a per-row expression — it must not force a GROUP BY.
    @test !contains(sql, "GROUP BY")
    @test res[:dialect] == :postgresql
  end

  # ───────────────────────────────────────────────────────────────────────────
  # Qor(Exists, Exists) in PostgreSQL: two EXISTS predicates joined by OR.
  # Each child query gets its own alias counter (R1, R2).  Both child scalar
  # filters become bound parameters in SQL-text order.
  # ───────────────────────────────────────────────────────────────────────────
  @testset "Correlated Exists Inspection - Qor two EXISTS predicates" begin
    note_query = DriverNoteModel.objects.filter(
      "driver_id" => OuterRef("pk"),
      "body__@icontains" => "rain",
    )
    race_note_query = RaceNoteModel.objects.filter(
      "race_id" => OuterRef("id"),
      "note__@icontains" => "crash",
    )

    q = DriverModel.objects
    q.filter(Qor(Exists(note_query), Exists(race_note_query)))
    q.values("id")

    res = inspect_query(q)
    sql = res[:sql_text]

    # Both EXISTS blocks rendered
    @test length(collect(eachmatch(r"EXISTS \(SELECT 1", sql))) == 2
    @test contains(sql, " OR ")
    # The OR group must be wrapped in parens so it ANDs correctly with other outer filters
    @test contains(sql, "WHERE (EXISTS")
    # Each child table gets its own alias
    @test contains(sql, "FROM \"driver_notes\" as \"R1\"")
    @test contains(sql, "FROM \"race_notes\" as \"R2\"")
    # OuterRef resolved for both children
    @test contains(sql, "\"R1\".\"driver_id\" = \"Tb\".\"id\"")
    @test contains(sql, "\"R2\".\"race_id\" = \"Tb\".\"id\"")
    # Scalar filters parameterized in declaration order
    @test contains(sql, "ILIKE \$1")
    @test contains(sql, "ILIKE \$2")
    @test res[:parameters] == ["%rain%", "%crash%"]
    @test res[:dialect] == :postgresql
  end

  # ───────────────────────────────────────────────────────────────────────────
  # OuterRef guardrail: calling inspect_query directly on a subquery that
  # contains OuterRef must raise ArgumentError because there is no outer
  # instruction to resolve against.
  # ───────────────────────────────────────────────────────────────────────────
  @testset "Correlated Exists Inspection - OuterRef requires correlated context" begin
    note_query = DriverNoteModel.objects.filter(
      "driver_id" => OuterRef("id"),
    )

    # inspect_query on the raw subquery (no Exists wrapper, no outer) must error
    @test_throws PormGError inspect_query(note_query)
  end

  # ───────────────────────────────────────────────────────────────────────────
  # count() / exists() inspection (#42): both terminals must honor show_query so
  # their generated SQL is inspectable without a live database. The short-circuit
  # returns before fetch(), so MockPostgres is sufficient.
  # ───────────────────────────────────────────────────────────────────────────
  @testset "count()/exists() honor show_query" begin
    q = DriverModel.objects
    q.filter("nationality" => "British")

    # count(show_query=:sql) renders the COUNT SELECT without executing.
    count_sql = q.count(show_query=:sql)
    @test count_sql isa String
    @test contains(count_sql, "COUNT")
    @test occursin("drivers", lowercase(count_sql))

    # count(show_query=:dict) exposes the full metadata dict with bound parameters.
    count_meta = q.count(show_query=:dict)
    @test count_meta isa Dict
    @test count_meta[:operation] === :select
    @test count_meta[:model] == "drivers"
    @test contains(count_meta[:sql_text], "COUNT")
    @test count_meta[:parameters] == ["British"]

    # exists(show_query=:sql) renders the `SELECT 1 ... LIMIT 1` probe.
    exists_sql = q.exists(show_query=:sql)
    @test exists_sql isa String
    @test contains(exists_sql, "SELECT 1")
    @test contains(exists_sql, "LIMIT 1")

    # exists(show_query=:dict) exposes the same metadata shape.
    exists_meta = q.exists(show_query=:dict)
    @test exists_meta isa Dict
    @test exists_meta[:model] == "drivers"
    @test contains(exists_meta[:sql_text], "SELECT 1")
    @test exists_meta[:parameters] == ["British"]

    # Default path (no show_query) is unchanged: count() still returns an Integer.
    # (Skipped here — requires a live DB; covered in integration suites.)
  end

  # ───────────────────────────────────────────────────────────────────────────
  # create()/update() column order follows call order (#97): q.insert is backed
  # by an OrderedDict, so the rendered INSERT column list (and matching params)
  # and the UPDATE SET list appear in the exact order fields were passed. With
  # the previous plain-Dict backing these came out in hash order, so create()/
  # update() could only be asserted structurally; now they are exact-string
  # golden-testable, which is what the offline golden-SQL suites need.
  # ───────────────────────────────────────────────────────────────────────────
  @testset "create()/update() column order follows call order" begin
    # Pass fields in a deliberately non-alphabetical, non-model-declaration order.
    # (DriverModel declares id, forename, surname, nationality — none of which
    # matches the call order below.) id is the primary key and is auto-skipped,
    # and every other passed field is non-null, so no auto-fill reordering occurs:
    # the rendered order must be exactly nationality, surname, forename.

    # --- create(): INSERT column list ---
    create_sql = DriverModel.objects.create(
      "nationality" => "Brazilian",
      "surname"     => "Senna",
      "forename"    => "Ayrton",
      show_query = :sql
    )
    @test create_sql isa String
    # Each column name appears exactly once (INSERT has no WHERE), so first-index
    # ordering is a robust, whitespace/newline-agnostic check of column order.
    pos_nat = findfirst("\"nationality\"", create_sql)
    pos_sur = findfirst("\"surname\"", create_sql)
    pos_for = findfirst("\"forename\"", create_sql)
    @test pos_nat !== nothing && pos_sur !== nothing && pos_for !== nothing
    @test pos_nat.start < pos_sur.start < pos_for.start

    # The strongest check: bound params must line up with the call order, so a
    # positional backend inserts each value into its intended column.
    create_meta = DriverModel.objects.create(
      "nationality" => "Brazilian",
      "surname"     => "Senna",
      "forename"    => "Ayrton",
      show_query = :dict
    )
    @test create_meta[:operation] === :insert
    @test create_meta[:parameters] == ["Brazilian", "Senna", "Ayrton"]

    # --- update(): SET clause list (same OrderedDict backing) ---
    # update() enforces a filter guard (no accidental update-all), so attach one.
    # The filter is on `id`, which never collides with the SET column names below.
    uq = DriverModel.objects
    uq.filter("id" => 44)
    update_sql = uq.update(
      "nationality" => "British",
      "surname"     => "Hamilton",
      "forename"    => "Lewis",
      show_query = :sql
    )
    @test update_sql isa String
    u_nat = findfirst("\"nationality\"", update_sql)
    u_sur = findfirst("\"surname\"", update_sql)
    u_for = findfirst("\"forename\"", update_sql)
    @test u_nat !== nothing && u_sur !== nothing && u_for !== nothing
    @test u_nat.start < u_sur.start < u_for.start

    uq2 = DriverModel.objects
    uq2.filter("id" => 44)
    update_meta = uq2.update(
      "nationality" => "British",
      "surname"     => "Hamilton",
      "forename"    => "Lewis",
      show_query = :dict
    )
    @test update_meta[:operation] === :update
    # The WHERE param may flatten before or after the SET params depending on
    # backend/bucketing, so assert the SET values keep their call order relative
    # to each other rather than pinning absolute positions.
    params = update_meta[:parameters]
    i_br = findfirst(==("British"), params)
    i_ha = findfirst(==("Hamilton"), params)
    i_le = findfirst(==("Lewis"), params)
    @test i_br !== nothing && i_ha !== nothing && i_le !== nothing
    @test i_br < i_ha < i_le
  end

  # ───────────────────────────────────────────────────────────────────────────
  # distinct().count() must render valid SQL. COUNT(DISTINCT *) is a syntax error
  # in both PostgreSQL and SQLite, so count() on a distinct() query must instead
  # wrap `SELECT DISTINCT *` in an outer COUNT(*) subquery.
  # ───────────────────────────────────────────────────────────────────────────
  @testset "distinct().count() renders valid SQL (no COUNT(DISTINCT *))" begin
    q = DriverModel.objects
    q.filter("nationality" => "British")
    q.distinct()

    sql = q.count(show_query=:sql)
    @test sql isa String
    @test !occursin("COUNT(DISTINCT", sql)   # the invalid form must be gone
    @test occursin("SELECT DISTINCT", sql)    # inner distinct row-select
    @test occursin("COUNT(*)", sql)           # outer plain count over the subquery

    # The WHERE parameter survives the subquery wrapping (bound exactly once).
    meta = q.count(show_query=:dict)
    @test meta[:parameters] == ["British"]
  end

  # ───────────────────────────────────────────────────────────────────────────
  # Terminal count() column/distinct forms:
  #   count("col")                -> COUNT("col")           (non-null values)
  #   count("col", distinct=true) -> COUNT(DISTINCT "col")  (distinct values, scalar; flat, no subquery)
  #   count(distinct=true)        -> distinct rows          (subquery, like .distinct().count())
  # ───────────────────────────────────────────────────────────────────────────
  @testset "count() column and distinct forms render valid SQL" begin
    # count("col", distinct=true) is the efficient flat form — COUNT(DISTINCT col),
    # not a subquery (COUNT(DISTINCT single_column) is valid SQL, unlike COUNT(DISTINCT *)).
    sql_cd = DriverModel.objects.count("nationality", distinct=true, show_query=:sql)
    @test occursin("COUNT(DISTINCT", sql_cd)
    @test occursin("nationality", sql_cd)
    @test !occursin("SELECT DISTINCT", sql_cd)      # flat, no subquery wrapping

    # count("col") counts non-null values of the column (no DISTINCT).
    sql_c = DriverModel.objects.count("nationality", show_query=:sql)
    @test occursin("COUNT(", sql_c)
    @test occursin("nationality", sql_c)
    @test !occursin("DISTINCT", sql_c)

    # count(distinct=true) with no column = distinct rows (subquery form).
    qd = DriverModel.objects
    qd.filter("nationality" => "British")
    sql_dr = qd.count(distinct=true, show_query=:sql)
    @test occursin("SELECT DISTINCT", sql_dr)
    @test occursin("COUNT(*)", sql_dr)
    @test !occursin("COUNT(DISTINCT", sql_dr)

    # WHERE param preserved in the flat column-distinct form.
    meta_cd = DriverModel.objects.filter("nationality" => "British").
      count("nationality", distinct=true, show_query=:dict)
    @test meta_cd[:parameters] == ["British"]
  end

  # ───────────────────────────────────────────────────────────────────────────
  # Terminal-name cleanup (#42): `query.inspect()` is the only surviving inspection
  # terminal. The `query.inspect_query()` alias was removed, so the accessor must
  # fall through to getfield and error.
  # ───────────────────────────────────────────────────────────────────────────
  @testset "inspect terminal: alias removed, :inspect survives" begin
    q = DriverModel.objects
    q.filter("nationality" => "Italian")

    # `.inspect()` forwards to inspect_query and returns the same metadata.
    via_terminal = q.inspect()
    via_function = inspect_query(q)
    @test via_terminal isa Dict
    @test via_terminal[:sql_text] == via_function[:sql_text]
    @test via_terminal[:parameters] == via_function[:parameters]

    # The removed alias is no longer a property → getfield fallback throws.
    @test_throws ErrorException q.inspect_query
  end

  # ===== Section: Row-level locking — select_for_update (#26) =====
  # Render-only assertions on the PostgreSQL mock: the FOR UPDATE clause and every option map
  # to the right SQL, land after ORDER BY / LIMIT, and invalid combinations fail fast. Execution
  # (and the "must be inside a transaction" guard) is covered by the integration suite.
  @testset "select_for_update renders FOR UPDATE (#26)" begin
    # Plain lock → bare FOR UPDATE, no OF / NOWAIT / SKIP LOCKED / NO KEY.
    q = DriverModel.objects
    q.select_for_update()
    sql = inspect_query(q)[:sql_text]
    @test contains(sql, "FOR UPDATE")
    @test !contains(sql, "NO KEY")
    @test !contains(sql, "NOWAIT")
    @test !contains(sql, "SKIP LOCKED")

    # skip_locked → FOR UPDATE SKIP LOCKED (the "claim next available row" queue pattern).
    q = DriverModel.objects
    q.select_for_update(skip_locked = true)
    sql = inspect_query(q)[:sql_text]
    @test contains(sql, "FOR UPDATE") && contains(sql, "SKIP LOCKED")

    # nowait → FOR UPDATE NOWAIT (raise instead of block on a locked row).
    q = DriverModel.objects
    q.select_for_update(nowait = true)
    sql = inspect_query(q)[:sql_text]
    @test contains(sql, "FOR UPDATE") && contains(sql, "NOWAIT")

    # no_key → the weaker FOR NO KEY UPDATE (PostgreSQL).
    q = DriverModel.objects
    q.select_for_update(no_key = true)
    @test contains(inspect_query(q)[:sql_text], "FOR NO KEY UPDATE")

    # Clause ORDER: FOR UPDATE must come AFTER ORDER BY / LIMIT (invalid SQL otherwise).
    q = DriverModel.objects
    q.order_by("surname")
    q.limit(5)
    q.select_for_update()
    sql = inspect_query(q)[:sql_text]
    @test first(findfirst("FOR UPDATE", sql)) > first(findfirst("LIMIT", sql))
    @test first(findfirst("LIMIT", sql)) > first(findfirst("ORDER BY", sql))

    # Chainable terminal returns the handler, so it composes with other builder calls.
    q = DriverModel.objects
    @test q.select_for_update() === q

    # nowait and skip_locked are mutually exclusive → fail at mutation time (Django parity).
    # Assert the SPECIFIC cause (not just "an ArgumentError") so an unrelated error can't pass.
    excl_err = try
      DriverModel.objects.select_for_update(nowait = true, skip_locked = true); nothing
    catch e; e end
    @test excl_err isa PormGError && occursin("mutually exclusive", excl_err.msg)

    # FOR UPDATE + DISTINCT is invalid on PostgreSQL → friendly error at render time.
    q = DriverModel.objects
    q.distinct(true)
    q.select_for_update()
    dist_err = try inspect_query(q); nothing catch e; e end
    @test dist_err isa PormGError && occursin("distinct", dist_err.msg)
  end

end
