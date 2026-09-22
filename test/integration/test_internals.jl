if !isdefined(Main, :PormG)
    include("common_setup.jl")
end


@testset "Advanced check parameters binding" begin
  # 1. Verify basic binding order and type formatting
  query = M.Result.objects
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
  query = M.Result.objects;
  query.filter("driverid__forename__@contains" => "L%wis");
  instruc = PormG.QueryBuilder.build(query.object);

  # The parameter should be escaped and wrapped in % by add_parameter!(contains=true)
  # L%wis -> %L\%wis%
  @test instruc.parameters.parameters[1] == "%L\\%wis%"

  q = M.Just_a_test_deletion.objects;
  q.filter("name__@icontains" => "to-be-deleted");
  df = q |> DataFrame
  instruc = PormG.QueryBuilder.build(q.object);
  @test instruc.parameters.parameters[1] == "%to-be-deleted%"

  # 3. Verify array binding for IN clauses
  # Postgres stores as a single parameter (Postgres ANY).
  # SQLite expands to multiple positional parameters (?).
  query = M.Result.objects
  query.filter("positionorder__@in" => [1, 2])
  instruc = PormG.QueryBuilder.build(query.object)
  
  if adapter_name == "PostgreSQL"
    @test length(instruc.parameters.parameters) == 1
    @test isa(instruc.parameters.parameters[1], AbstractVector)
    @test instruc.parameters.parameters[1] == [1, 2]
  else # SQLite, etc.
    # In SQLite/MySQL, IN clause expands to (?, ?)
    params = PormG.QueryBuilder.get_final_parameters(instruc.parameters)
    @test length(params) >= 2
    @test 1 in params
    @test 2 in params
  end

  # 4. Mixed types in same filter (integers, strings, dates, floats)
  query = M.Result.objects
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
  query = M.Driver.objects
  query.filter(Q("forename" => "Lewis", "driverid__@lte" => 50), Qor("surname" => "Hamilton", "surname" => "Rosberg"))
  instruc = PormG.QueryBuilder.build(query.object)
  # Expect four parameters in order: forename, driverid, surname1, surname2
  @test length(instruc.parameters.parameters) == 4
  @test instruc.parameters.parameters[1] == "Lewis"
  @test instruc.parameters.parameters[2] == 50
  @test instruc.parameters.parameters[3] == "Hamilton"
  @test instruc.parameters.parameters[4] == "Rosberg"

  # 6. Multiple LIKE patterns in same query are escaped independently
  query = M.Result.objects
  query.filter("driverid__forename__@contains" => "A_B", "raceid__circuitid__name__@icontains" => "%C%")
  instruc = PormG.QueryBuilder.build(query.object)
  @test length(instruc.parameters.parameters) == 2
  @test instruc.parameters.parameters[1] == "%A\\_B%"    # underscore escaped
  @test instruc.parameters.parameters[2] == "%\\%C\\%%"  # percent escaped and wrapped

  # 7. Verify binding in Updates (Filters + Set values) end-to-end
  # We check the functional correctness (DB updated) which proves binding was applied.
  query = M.Just_a_test_deletion.objects
  # Ensure a clean state for the test
  query.exists() && query.delete(allow_delete_all=true)
  query.create("id" => 500, "name" => "original", "test_result" => 10)

  # Update two columns using a filter; this exercises both WHERE and SET bindings
  query.filter("id" => 500)
  query.update("name" => "updated", "test_result" => 20)

  query = M.Just_a_test_deletion.objects
  query.filter("id" => 500)
  updated_row = query.list()
  @test updated_row[1][:name] == "updated"
  @test updated_row[1][:test_result] == 20

  # 8. Verify Date binding
  query = M.Race.objects
  test_date = Date(2023, 10, 22)
  query.filter("date" => test_date)
  instruc = PormG.QueryBuilder.build(query.object)

  # The formatter should have converted Date to String for the DB driver if needed,
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
  query = M.Result.objects;
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
  
  # Test 2: DELETE with show_query=:sql returns SQL string
  delete_queries = M.Circuit.objects.delete(allow_delete_all=true, show_query=:sql)
  # Verify the circuit table still exists after show_query (no actual deletion)
  @test M.Circuit.objects.exists()
  @test delete_queries isa String || delete_queries isa Vector{Any}

  # Test 3: BULK_INSERT with show_query=:sql does not crash and returns SQL.
  # constructors.csv ships camelCase headers (constructorId, ...); bulk matching is
  # case-sensitive, so normalize them to the model's lowercase fields first.
  query = M.Constructor.objects
  df = CSV.File(joinpath("f1", "constructors.csv")) |> DataFrame
  rename!(df, lowercase.(names(df)))
  sql_bulk = bulk_insert(query, df, show_query=:sql)
  @test sql_bulk isa String || sql_bulk isa Vector{String}

  # Test 4: UPDATE with show_query=:sql returns SQL string
  query = M.Just_a_test_deletion.objects
  query.filter("id" => 1)
  
  sql_update = query.update("name" => "test_structured_logging", show_query=:sql)
  @test typeof(sql_update) == String
  @test contains(sql_update, "UPDATE")

  # Test 5: BULK_UPDATE with show_query=:sql does not crash and returns SQL
  query = M.Just_a_test_deletion.objects;
  df = query |> DataFrame
  for (index, row) in enumerate(eachrow(df))
    row.name = "test_bulk_update_$(index)"
  end
  try
    sql_bulk = bulk_update(query, df, columns=["name"], match_on=["id"], show_query=:sql)
    @test sql_bulk isa String || sql_bulk isa Vector{String}
  catch e
    @error "Error during bulk_update with show_query" error=e
    @test false
  end

  # Test 6: Verify structured logging contains expected fields (query, params, task_id)
  # by inspecting the logged message structure
  query = M.Result.objects;
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
        
  # Two rules, one per axis (#394). `quote_identifier` is the fail-closed ALIAS path; the
  # `safe_*_identifier` pair is the escape-only PHYSICAL path, because a table or column name is
  # pinned by the model author or read from the catalog, and validating it meant refusing names
  # PormG's own DDL creates. The partition itself is covered exhaustively in
  # `test/unit/test_identifier_quoting.jl`.
  @testset "Identifier Sanitization" begin
    # Test the SQLSanitizer module
    
    # Test basic identifier quoting
    @test quote_identifier("valid_field", nothing) == "\"valid_field\""
    @test quote_identifier("field_with_123", nothing) == "\"field_with_123\""
    @test quote_identifier("localização", nothing) == "\"localização\""
    
    # Test malicious identifiers are rejected instead of silently rewritten
    @test_throws PormGError quote_identifier("field'; DROP TABLE users; --", nothing)
    @test_throws PormGError quote_identifier("field OR 1=1", nothing)
    
    # Test table name sanitization
    @test safe_table_identifier("users", nothing) == "\"users\""

    # A PHYSICAL name is escaped, not validated (#394) — the same strings refused above are legal
    # as a `db_table`/`db_column`, and quote doubling is what makes them safe.
    @test safe_table_identifier("driver profile", nothing) == "\"driver profile\""
    @test safe_table_identifier("we\"ird", nothing) == "\"we\"\"ird\""
    @test safe_column_identifier("Say\"Hi", nothing) == "\"Say\"\"Hi\""
    # The doubled quote cannot terminate the identifier, which is the whole threat.
    @test safe_table_identifier("x\"; DROP TABLE users; --", nothing) ==
          "\"x\"\"; DROP TABLE users; --\""
    
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

  @testset "Injection in Values (Parameterization Check)" begin
    query = M.Just_a_test_deletion.objects
    
    # 1. Classic attack payload ("Little Bobby Tables")
    payload = "Robert'); DROP TABLE users; --"
    
    # Attempt to insert the payload as the name
    # If parameterization failed, the 'users' table (or another) would be dropped
    query.create("name" => payload, "test_result" => 999)
    
    # Check: The data must have been stored LITERALLY
    q_check = M.Just_a_test_deletion.objects.filter("name" => payload)
    @test q_check.count() == 1
    
    item = q_check.list() |> first
    @test item[:name] == payload  # The DB should have stored the quotes and semicolon as literal text
  end


  @testset "Injection in Identifiers (Columns/Aliases)" begin
    query = M.Result.objects
    
    # 1. Injection in ORDER BY
    # If the ORM simply concatenates the string this would execute pg_sleep (time-based blind SQLi)
    # or raise a syntax error if properly sanitized.
    injection_col = "raceid; SELECT pg_sleep(10)--"
    
    # Expectation: ORM should turn this into something harmless like "raceidSELECTpg_sleep5"
    # or raise a column-not-found error. It MUST NOT lock the DB for 5s.
    caught_msg = ""
    t = @elapsed begin
      try
        query.order_by(injection_col)
        query |> DataFrame # force execution
      catch e
        # Error is acceptable (column doesn't exist) but should contain the injection string
        caught_msg = string(e)
      end
    end
    @test t < 1.0 # Ensure pg_sleep(5) did not run
    @test caught_msg != ""
    @test occursin(injection_col, caught_msg)
    
    # 2. Injection in Aliases (values)
    # Attempts to break the "AS alias"
    caught_msg = ""
    injection_alias = "points AS points_hacked; DROP TABLE users; --"
    try
      query = M.Result.objects.values("resultid" => "\"id_hacked\" FROM result; --")
      query |> DataFrame
    catch e
      caught_msg = string(e)
    end
    @test caught_msg != ""
    @test occursin("id_hacked", caught_msg)
    @test occursin(" FROM result; --", caught_msg)
  end

  @testset "Injection in Operators and Joins" begin
    query = M.Result.objects
    
    # Attempt to inject a nonexistent operator that closes the query
    # e.g.: try to turn "points__@gt" into "points > 10; DROP..."
    bad_filter = "points__@gt; --"    
    
    # Idiomatic Julia way to catch and verify an exception
    # We use a logger to suppress the internal @error log during this specific test
    Base.CoreLogging.with_logger(Base.CoreLogging.NullLogger()) do
      try
        query.filter(bad_filter => 1)
        @test false # Should not reach here
      catch e
        @test e isa PormGError
        @test occursin("is invalid;", e.msg)
      end
    end
  end

  # Every string below stays refused as an ALIAS after #394, and every one of them is legal as a
  # physical `db_table`/`db_column`. That is the split, and it is deliberate: an alias is chosen at
  # query-build time and names nothing that exists, so there is nothing to be faithful to.
  @testset "Advanced Sanitizer Unit Tests" begin
    # Test with Unicode and control characters
    # Sometimes 'latin1' or other encodings allow single-quote bypasses
    import PormG.QueryBuilder: quote_identifier
    
    # Empty identifier
    @test_throws PormGError quote_identifier("", nothing)
    
    # Double quotes inside (attempt to break the identifier)
    @test_throws PormGError quote_identifier("column\"name", nothing)
    
    # SQL comments
    @test_throws PormGError quote_identifier("admin--", nothing)
    
    # Whitespace is not part of PormG's identifier contract.
    @test_throws PormGError quote_identifier("user name", nothing)
  end


end

# ─────────────────────────────────────────────────────────────────────────────
# Credential containment against a REAL connection (#649).
#
# The unit half (`test/unit/test_redact_secret.jl`, `test_json_serialization.jl`,
# `test_repl_display.jl`) is hermetic and asserts on invented credentials, which is what lets it
# check VALUES. This file faces the live DSN for the selected database, so it asserts on TOKENS and
# SHAPES only and never on the secret itself — a failure message is CI output, and the whole point
# is that the credential does not travel.
#
# That constraint is why the `show` assertions are written as "`password=` NOT followed by the
# mask" rather than "the password is absent": the card legitimately CONTAINS `password=****`, so a
# bare token check cannot distinguish a redacted DSN from a raw one.
#
# **Every assertion here tests a hoisted `Bool`, never the call itself**, and that is not style.
# Julia's `@test` prints an `Evaluated:` line carrying BOTH arguments of a call, so
# `@test !occursin(RAW_KV, rendered)` publishes the entire rendered card — live DSN included — to
# CI output, and does so precisely when redaction has regressed. Measured on 1.12:
#
#     Expression: !(occursin(RAW_KV, secret_text))
#      Evaluated: !(occursin(r"...", "host=h password=THE_LIVE_SECRET user=admin"))
#
# `leaked = occursin(...); @test !leaked` prints `Expression: !leaked` and no `Evaluated:` line at
# all. A test that turns a leak into a PUBLISHED leak is worse than no test.
# ─────────────────────────────────────────────────────────────────────────────
@testset "Credential containment: live pool, Settings and config (#649)" begin
  settings = PormG.config[PORMG_DB_FOLDER]
  pool = settings.connections
  @test pool isa PormG.Kernel.PormGBackend   # the fixture is only a fixture if it is a real pool

  J649 = PormG.QueryBuilder.JSON

  # An un-redacted credential in either dialect. `password=` / `user=` not followed by the mask is
  # the keyword form; `://…:…@` is the URL form, which was invisible to the rule before #649.
  RAW_KV  = r"(?i)(password|user)\s*=\s*(?!\*\*\*\*)"
  # The middle class must exclude `:` as well as `*`, or the `:` inside a CORRECTLY redacted
  # `://****:****@` satisfies "at least one non-mask character" and the assertion goes red on the
  # fixed behaviour — then prints the card. Verified: old pattern matched `://****:****@`, this one
  # does not, and both still match `://pingo:s3cret@` and `://pingo@`.
  # The class mirrors `_REDACT_URL_USERINFO_RE` and must MOVE WITH IT: only `/` and a line break
  # terminate a userinfo run, because `?`, `#`, spaces and tabs are all ordinary password
  # characters to libpq. A guard whose class is narrower than the rule's cannot see the very class
  # of leak the rule was widened for.
  RAW_URL = r"://[^/@\n\r]*[^*:/@\n\r][^/@\n\r]*@"

  # ── JSON: no DSN at all, in any form ──────────────────────────────────────
  # Stricter than the display route by design (see `src/json_lower.jl`): a document travels, so it
  # carries no connection string even redacted.
  @testset "JSON.json emits no connection string" begin
    for (label, value) in ("pool" => pool, "Settings" => settings, "config" => PormG.config)
      @testset "$label" begin
        doc = J649.json(value)
        for token in ("connection_string", "db_config_settings", "password", "user=",
                      "dbname", "host=", "pool_size", "available", "://")
          # Hoisted — see the header. `@test !occursin(token, doc)` would print `doc`.
          present = occursin(token, doc)
          @testset "$token" begin
            @test !present
          end
        end
      end
    end
  end

  # ── show: a redacted DSN on the card, none at all on the compact route ────
  @testset "Base.show never renders a live credential" begin
    for (label, value) in ("pool" => pool, "Settings" => settings, "config" => PormG.config)
      @testset "$label" begin
        compact = sprint(show, value)
        card    = repr(MIME"text/plain"(), value)

        # Neither route may carry an unmasked credential in either dialect. Every check is
        # hoisted to a `Bool` before `@test` sees it — see the header.
        for (route, rendered) in ("compact" => compact, "card" => card)
          @testset "$route" begin
            unmasked_kv  = occursin(RAW_KV, rendered)
            unmasked_url = occursin(RAW_URL, rendered)
            reflected_cs = occursin("connection_string", rendered)
            reflected_yaml = occursin("db_config_settings", rendered)
            @test !unmasked_kv
            @test !unmasked_url
            @test !reflected_cs
            @test !reflected_yaml
          end
        end

        # The compact route promises more than "masked": no DSN at all. `password=****` nested
        # inside another value's rendering would pass every assertion above and still be wrong.
        any_dsn = occursin("password", compact)
        @test !any_dsn
      end
    end
  end

  # ── the card actually shows something, so the tests above are not vacuous ─
  # A `show` that rendered nothing at all would satisfy every absence assertion in this testset.
  # This is the non-vacuity floor.
  @testset "the card is not empty" begin
    card = repr(MIME"text/plain"(), pool)
    # Hoisted like everything else in this block, and the third one is the reason the rule is
    # absolute rather than a style preference: a POSITIVE `occursin` prints its haystack on failure
    # exactly as a negated one does, and this assertion's failure condition IS "the mask is missing
    # from the card" — i.e. redaction regressed and `card` holds the raw DSN.
    names_pool = occursin("Pool(", card)
    has_dsn_line = occursin("dsn:", card)
    @test names_pool
    @test has_dsn_line
    # …and the DSN it shows went through the redaction rule, evidenced by the mask being present.
    # (PostgreSQL's DSN carries a password; SQLite's connection string is a file path, so the mask
    # is only asserted where the source string actually had something to mask.)
    if pool isa PormG.PormGPostgres && occursin("password", pool.connection_string)
      masked = occursin("password=****", card)
      @test masked
    end
  end
end
