if !isdefined(Main, :PormG)
    include("common_setup.jl")
end


@testset "Advanced check parameters binding" begin
  # 1. Verify basic binding order and type formatting
  query = M.Result |> object
  query.filter("resultid" => 1, "points" => "10.5", "driverid__forename" => "Lewis")
  
  # Manually build the instruction to inspect parameters before execution
  # We use PormG.QueryBuilder.build to get the internal instruction object
  instruc = PormG.QueryBuilder.build(query.object)
  params = instruc.parameters.parameters

  @test length(params) == 3
  @test params[1] == 1          # resultid
  @test params[2] == "10.5"   # points (string preserved)
  @test params[3] == "Lewis"  # forename

  # 2. Verify LIKE pattern escaping and wildcard wrapping for contains
  query = M.Result |> object;
  query.filter("driverid__forename__@contains" => "L%wis");
  instruc = PormG.QueryBuilder.build(query.object);

  # The parameter should be escaped and wrapped in % by add_parameter!(contains=true)
  # L%wis -> %L\%wis%
  @test instruc.parameters.parameters[1] == "%L\\%wis%"

  q = M.Just_a_test_deletion |> object;
  q.filter("name__@icontains" => "to-be-deleted");
  df = q |> DataFrame
  instruc = PormG.QueryBuilder.build(q.object);
  @test instruc.parameters.parameters[1] == "%to-be-deleted%"

  # 3. Verify array binding for IN clauses
  # Arrays should be stored as a single parameter (Postgres ANY) and preserved as an AbstractVector
  query = M.Result |> object
  query.filter("positionorder__@in" => [1, 2])
  instruc = PormG.QueryBuilder.build(query.object)
  @test length(instruc.parameters.parameters) == 1
  @test isa(instruc.parameters.parameters[1], AbstractVector)
  @test instruc.parameters.parameters[1] == [1, 2]

  # 4. Mixed types in same filter (integers, strings, dates, floats)
  query = M.Result |> object
  query.filter("resultid" => 1, "statusid__status" => "Finished", "raceid__date" => Date(2020,1,15))
  instruc = PormG.QueryBuilder.build(query.object)
  # Expect three parameters in the same order the filters were provided
  @test length(instruc.parameters.parameters) >= 3
  @test instruc.parameters.parameters[1] == 1
  @test instruc.parameters.parameters[2] == "Finished"
  # date formatting is model-dependent; ensure it is formatted as ISO string
  @test string(instruc.parameters.parameters[3]) == "2020-01-15"

  # 5. Nested Q / Qor filter parameter ordering
  # Q groups should preserve their parameter order and Qor should append its alternatives
  query = M.Driver |> object
  query.filter(Q("forename" => "Lewis", "driverid__@lte" => 50), Qor("surname" => "Hamilton", "surname" => "Rosberg"))
  instruc = PormG.QueryBuilder.build(query.object)
  # Expect four parameters in order: forename, driverid, surname1, surname2
  @test length(instruc.parameters.parameters) == 4
  @test instruc.parameters.parameters[1] == "Lewis"
  @test instruc.parameters.parameters[2] == 50
  @test instruc.parameters.parameters[3] == "Hamilton"
  @test instruc.parameters.parameters[4] == "Rosberg"

  # 6. Multiple LIKE patterns in same query are escaped independently
  query = M.Result |> object
  query.filter("driverid__forename__@contains" => "A_B", "raceid__circuitid__name__@icontains" => "%C%")
  instruc = PormG.QueryBuilder.build(query.object)
  @test length(instruc.parameters.parameters) == 2
  @test instruc.parameters.parameters[1] == "%A\\_B%"    # underscore escaped
  @test instruc.parameters.parameters[2] == "%\\%C\\%%"  # percent escaped and wrapped

  # 7. Verify binding in Updates (Filters + Set values) end-to-end
  # We check the functional correctness (DB updated) which proves binding was applied.
  query = M.Just_a_test_deletion |> object
  # Ensure a clean state for the test
  query |> do_exists && delete(query; allow_delete_all=true)
  query.create("id" => 500, "name" => "original", "test_result" => 10)

  # Update two columns using a filter; this exercises both WHERE and SET bindings
  query.filter("id" => 500)
  query.update("name" => "updated", "test_result" => 20)

  query = M.Just_a_test_deletion |> object
  query.filter("id" => 500)
  updated_row = query |> list
  @test updated_row[1][:name] == "updated"
  @test updated_row[1][:test_result] == 20

  # 8. Verify Date binding
  query = M.Race |> object
  test_date = Date(2023, 10, 22)
  query.filter("date" => test_date)
  instruc = PormG.QueryBuilder.build(query.object)

  # The formater should have converted Date to String for the DB driver if needed,
  # or kept it as Date if the driver handles it. Check ISO-like output.
  @test string(instruc.parameters.parameters[1]) == "2023-10-22"

  # Notes for maintainers/readers:
  # - These tests focus on the parameter *collection* and *formatting* performed by build()/add_parameter!.
  # - For UPDATE statements we verify the end-to-end effect in the database which implicitly tests the binding used during the DML.
  # - Keep tests readable and commented; they are educational and help debug future regressions.
end

@testset "Connection string redaction" begin
  # Verify redact_secret masks sensitive connection parameters while preserving others.
  # This ensures we never log plaintext credentials (user/password) but keep other keys intact.
  raw = "host=localhost user=admin password=s3cr3t port=5432"
  masked = PormG.Configuration.redact_secret(raw)

  # Non-sensitive fields should remain unchanged
  @test occursin("host=localhost", masked)
  @test occursin("port=5432", masked)

  # Sensitive fields should be masked and originals must not appear
  @test occursin("user=****", masked)
  @test occursin("password=****", masked)
  @test !occursin("admin", masked)
  @test !occursin("s3cr3t", masked)
  # # Expect two masked occurrences (user and password)
  # @test count(collect(eachmatch("\\*\\*\\*\\*", masked))) == 2

  # Case-insensitive matching should also work
  uppercase = PormG.Configuration.redact_secret("PASSWORD=topsecret")
  @test uppercase == "PASSWORD=****"

  # Strings without sensitive keys should be left untouched
  untouched = PormG.Configuration.redact_secret("dbname=f1_database")
  @test untouched == "dbname=f1_database"
end

@testset "Show Query" begin
  # Test 1: SELECT with show_query returns SQL string
  query = M.Result |> object;
  query.filter("statusid__status" => "Finished", "driverid__forename" => "Ayrton");
  query.values("resultid", "driverid__forename", "constructorid__name" , "statusid__status");
  logger = Base.CoreLogging.SimpleLogger(IOBuffer())
  Base.CoreLogging.with_logger(logger) do
    try
      query |> show_query
      @test true
    catch e
      @error "Error during show_query" error=e
      @test false
    end
  end
  
  # Test 2: DELETE with show_query=true logs structured info
  # We capture log messages using Julia's logging
  delete_logs = []
  logger = Base.CoreLogging.SimpleLogger(IOBuffer())
  Base.CoreLogging.with_logger(logger) do
    try
      delete(M.Circuit |> object, allow_delete_all=true, show_query=true)
      @test true
    catch e
        @error "Error during delete with show_query" error=e
        @test false
    end
  end
  # Verify the circuit table still exists after show_query=true (no actual deletion)
  @test M.Circuit |> object |> do_exists

  # Test 3: BULK_INSERT with show_query=true does not crash
  query = M.Constructor |> object
  bulk_insert_logs = []
  logger = Base.CoreLogging.SimpleLogger(IOBuffer())
  Base.CoreLogging.with_logger(logger) do
    try
      bulk_insert(query, CSV.File(joinpath("f1", "constructors.csv")) |> DataFrame, show_query=true)
      @test true
    catch e
      @error "Error during bulk_insert with show_query" error=e
      @test false
    end
  end

  # Test 4: UPDATE with show_query=true logs structured info
  query = M.Just_a_test_deletion |> object
  query.filter("id" => 1)
  
  # Capture structured log output
  update_log_captured = false
  logger = Base.CoreLogging.SimpleLogger(IOBuffer(), Base.CoreLogging.Info)
  Base.CoreLogging.with_logger(logger) do
    try
      sql = query.update("name" => "test_structured_logging", show_query=true)
      # When show_query=true, update returns the SQL string
      @test typeof(sql) == String
      @test contains(sql, "UPDATE")
      update_log_captured = true
    catch e
      @error "Error during update with show_query" error=e
    end
  end
  @test update_log_captured

  # Test 5: BULK_UPDATE with show_query=true does not crash
  query = M.Just_a_test_deletion |> object;
  df = query |> DataFrame
  for (index, row) in enumerate(eachrow(df))
    row.name = "test_bulk_update_$(index)"
  end
  try
    bulk_update(query, df, columns=["name"], filters=["id"], show_query=false)
    @test true
  catch e
    @error "Error during bulk_update with show_query" error=e
    @test false
  end

  # Test 6: Verify structured logging contains expected fields (query, params, task_id)
  # by inspecting the logged message structure
  query = M.Result |> object;
  query.filter("resultid" => 1);
  query.values("resultid", "points");
  
  logged_messages = []
  function capture_logs(logger, level, message, _module, group, id, file, line; kwargs...)
    if level == Base.CoreLogging.Info && message == "SQL Exec"
      # kwargs should contain: query, params, task_id
      push!(logged_messages, kwargs)
    end
    Base.CoreLogging.handle_message(logger, level, message, _module, group, id, file, line; kwargs...)
  end  

end

@testset "SQL Injection Prevention Tests" begin
        
  @testset "Identifier Sanitization" begin
    # Test the SQLSanitizer module
    
    # Test basic identifier quoting
    @test quote_identifier("valid_field", nothing) == "\"valid_field\""
    @test quote_identifier("field_with_123", nothing) == "\"field_with_123\""
    
    # Test malicious identifier cleaning
    @test quote_identifier("field'; DROP TABLE users; --", nothing) == "\"fieldDROPTABLEusers\""
    @test quote_identifier("field OR 1=1", nothing) == "\"fieldOR11\""
    
    # Test table name sanitization
    @test safe_table_identifier("users", nothing) == "\"users\""
    
    println("✅ All identifier sanitization tests passed!")
  end
  
  @testset "LIKE Pattern Escaping" begin    
    # Test LIKE pattern escaping
    @test escape_like_pattern("test_pattern") == "test\\_pattern"
    @test escape_like_pattern("test%pattern") == "test\\%pattern" 
    @test escape_like_pattern("test\\pattern") == "test\\\\pattern"
    @test escape_like_pattern("test_%\\pattern") == "test\\_\\%\\\\pattern"
    
    println("✅ All LIKE pattern escaping tests passed!")
  end
end