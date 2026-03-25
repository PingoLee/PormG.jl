if !isdefined(Main, :PormG)
    include("common_setup.jl")
end

# function ensure_integration_schema_current!()
#   settings = PormG.Configuration.get_settings(PORMG_DB_FOLDER)
#   pending_path = joinpath(settings.db_def_folder, "migrations", "pending_migrations.jl")

#   PormG.Migrations.init_migrations(PORMG_DB_FOLDER)
#   PormG.Migrations.makemigrations(PORMG_DB_FOLDER, interactive=false)

#   if isfile(pending_path)
#     PormG.Migrations.migrate(PORMG_DB_FOLDER, interactive=false)
#   end

#   return nothing
# end

# ensure_integration_schema_current!()

# conn = PormG.Configuration.acquire_connection(PormG.config["db_2"].connections)
@testset "Database Setup Insert" begin
  @testset "Schema Evolution and Error Recovery" begin
    # 1. Schema Evolution: Reordered columns and extra columns
    query = M.Status.objects
    query.delete(allow_delete_all=true)
    
    # Create DF with extra column and different order
    df_evolved = DataFrame(
      extra_col = ["ignore me", "me too"],
      status = ["Evolved 1", "Evolved 2"],
      statusid = [999, 1000]
    )
    
    # Should work because 'extra_col' is not in model fields and others are mapped by name
    bulk_insert(query, df_evolved)
    query.filter("statusid" => 999)
    @test query.count() == 1
    query = M.Status.objects
    query.filter("statusid" => 1000)
    @test query.count() == 1
    
    # 2. Error Recovery: Atomicity on failure
    query = M.Status.objects
    initial_count = query.count()
    df_bad = DataFrame(
        statusid = [1001, 999, 1002], # 999 is a duplicate
        status = ["Good", "Bad (Duplicate)", "Good"]
    )
    
    got_error = false
    try
      Base.CoreLogging.with_logger(Base.CoreLogging.NullLogger()) do
        bulk_insert(query, df_bad)
      end
    catch e
      got_error = true  # bulk_insert now rethrows the underlying DB error (e.g., duplicate key)
    end

    @test got_error
    # Verify atomicity: 1001 and 1002 should NOT be there
    query = M.Status.objects
    @test query.count() == initial_count
    query.filter("statusid" => 1001)
    @test query.count() == 0

    # 3. Multi-chunk Error Recovery: Atomicity across chunks
    M.Status.objects.delete(allow_delete_all=true)
    df_multi = DataFrame(
        statusid = [2001, 2002, 2001, 2003], # 2001 is repeated in the 3rd row
        status = ["Chunk 1", "Chunk 1", "Chunk 2 (Fail)", "Chunk 2"]
    )
    
    query = M.Status.objects;
    got_error = false
    try
      Base.CoreLogging.with_logger(Base.CoreLogging.NullLogger()) do
        bulk_insert(query, df_multi, chunk_size=2)
      end
    catch e
      got_error = true  # async task failure is unwrapped, so catch sees the real constraint error
    end

    @test got_error
    # Verify that even the first chunk (2001, 2002) was rolled back
    @test query.count() == 0
  end

  # Clear all tables
  M.Driver_standings.objects.delete(allow_delete_all = true)
  M.Lap_times.objects.delete(allow_delete_all = true)
  M.Pit_stops.objects.delete(allow_delete_all = true)
  M.Qualifying.objects.delete(allow_delete_all = true)
  M.Sprint_results.objects.delete(allow_delete_all = true)
  M.Constructor_results.objects.delete(allow_delete_all = true)
  M.Constructor_standings.objects.delete(allow_delete_all = true)
  M.Circuit.objects.delete(allow_delete_all = true)
  M.Status.objects.delete(allow_delete_all = true)
  M.Driver.objects.delete(allow_delete_all = true)
  M.Constructor.objects.delete(allow_delete_all = true)
  M.Result.objects.delete(allow_delete_all = true)
  M.Just_a_test_deletion.objects.delete(allow_delete_all = true)

  @testset "Single insertions" begin

    path_load = joinpath("f1", "status.csv")
    df = CSV.File(path_load) |> DataFrame

    query = M.Status.objects
    initial_count = query.count()
    for row in eachrow(df)
      try
        dt = query.create("statusid" => row.statusId, "status" => row.status)
      catch e
        @error "Error inserting status row" statusId=row.statusId error=e
      end
    end
    @test query.count() == initial_count + nrow(df)

  end

  @testset "Simple Bulk Insertions" begin
    # Insert Circuits
    query = M.Circuit.objects
    bulk_insert(query, CSV.File(joinpath("f1", "circuits.csv")) |> DataFrame)

    # Bulk insert for Race with expected error
    query = M.Race.objects
    path_load = joinpath("f1", "races.csv")
    df = CSV.File(path_load) |> DataFrame
    rename!(df, lowercase.(names(df)))
    got_error = false
    try
        bulk_insert(query, df)
    catch e
        got_error = true
    end
    @test got_error

    # Pre-processing and bulk insert for Race
    rename!(df, lowercase.(names(df)))
    for col in [:fp1_date, :fp1_time, :fp2_date, :fp2_time, :fp3_date, :fp3_time, :quali_date, :quali_time, :sprint_date, :sprint_time, :time]
        df[!, col] = map(x -> ismissing(x) || x == "\\N" || x == "" ? missing : x, df[!, col])
    end
    try
        bulk_insert(query, df, copy=true)
    catch e
        @error "Error in bulk_insert for Race after pre-processing" error=e
    end
    @test query.count() > 0

    # Insert Drivers
    query = M.Driver.objects
    df = CSV.File(joinpath("f1", "drivers.csv")) |> DataFrame
    for col in [:number]
        df[!, col] = map(x -> ismissing(x) || x == "\\N" || x == "" ? missing : x, df[!, col])
    end
    bulk_insert(query, df)
    @test query.count() == 861

    # Insert Constructors
    query = M.Constructor.objects
    bulk_insert(query, CSV.File(joinpath("f1", "constructors.csv")) |> DataFrame, chunk_size=100)

    query = M.Result.objects;
    df = CSV.File(joinpath("f1", "results.csv")) |> DataFrame
    # lowercase the column names
    rename!(df, lowercase.(names(df)))
    for col in [:position, :time, :milliseconds, :fastestlap, :rank, :fastestlaptime, :fastestlapspeed, :number]
        df[!, col] = map(x -> ismissing(x) || x == "\\N" || x == "" ? missing : x, df[!, col])
    end
    bulk_insert(query, df)
    @test query.count() == 26759

    query = M.Driver_standings.objects
    df = CSV.File(joinpath("f1", "driver_standings.csv")) |> DataFrame
    rename!(df, lowercase.(names(df)))
    for col in [:position, :wins]
        df[!, col] = map(x -> ismissing(x) || x == "\\N" || x == "" ? missing : x, df[!, col])
    end
    bulk_insert(query, df, chunk_size=5_000)
    @test query.count() == nrow(df)

    # Insert Lap Times when the integration model exposes the new table.
    # We lowercase the CSV headers to match the field naming used by bulk_insert.
    # The assertion uses the CSV row count directly so the test remains stable if
    # the fixture is refreshed later.
    query = M.Lap_times.objects
    df = CSV.File(joinpath("f1", "lap_times.csv")) |> DataFrame
    rename!(df, lowercase.(names(df)))
    bulk_insert(query, df, chunk_size=5_000)
    @test query.count() == nrow(df)

    # Insert Pit Stops when the integration model exposes the new table.
    # The dataset already matches the model shape, so only header normalization is needed.
    query = M.Pit_stops.objects
    df = CSV.File(joinpath("f1", "pit_stops.csv")) |> DataFrame
    rename!(df, lowercase.(names(df)))
    df[!, :duration] = map(x -> ismissing(x) || x == "\\N" || x == "" ? missing : x, df[!, :duration])
    bulk_insert(query, df, chunk_size=2_000)
    @test query.count() == nrow(df)

    query = M.Constructor_standings.objects
    df = CSV.File(joinpath("f1", "constructor_standings.csv")) |> DataFrame
    rename!(df, lowercase.(names(df)))
    bulk_insert(query, df, chunk_size=5_000)
    @test query.count() == nrow(df)

    query = M.Constructor_results.objects
    df = CSV.File(joinpath("f1", "constructor_results.csv")) |> DataFrame
    rename!(df, lowercase.(names(df)))
    bulk_insert(query, df, chunk_size=5_000)
    @test query.count() == nrow(df)

    query = M.Qualifying.objects
    df = CSV.File(joinpath("f1", "qualifying.csv")) |> DataFrame
    rename!(df, lowercase.(names(df)))
    hasproperty(df, :qualifyid) && rename!(df, :qualifyid => :qualifyingid)
    for col in [Symbol("q1"), Symbol("q2"), Symbol("q3")]
        df[!, col] = map(x -> ismissing(x) || x == "\\N" || x == "" ? missing : x, df[!, col])
    end
    bulk_insert(query, df, chunk_size=5_000)
    @test query.count() == nrow(df)

    query = M.Sprint_results.objects
    df = CSV.File(joinpath("f1", "sprint_results.csv")) |> DataFrame
    rename!(df, lowercase.(names(df)))
    for col in [:position, :time, :milliseconds, :fastestlap, :fastestlaptime]
        df[!, col] = map(x -> ismissing(x) || x == "\\N" || x == "" ? missing : x, df[!, col])
    end
    bulk_insert(query, df, chunk_size=5_000)
    @test query.count() == nrow(df)
    

  end  

end