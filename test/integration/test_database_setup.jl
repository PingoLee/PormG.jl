if !isdefined(Main, :PormG)
    include("common_setup.jl")
end

# conn = PormG.Configuration.acquire_connection(PormG.config["db_2"].connections)
@testset "Database Setup Insert" begin
  @testset "Schema Evolution and Error Recovery" begin
    # 1. Schema Evolution: Reordered columns and extra columns
    query = M.Status.objects
    delete(query, allow_delete_all=true)
    
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
      bulk_insert(query, df_bad)
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
    delete(M.Status.objects, allow_delete_all=true)
    df_multi = DataFrame(
        statusid = [2001, 2002, 2001, 2003], # 2001 is repeated in the 3rd row
        status = ["Chunk 1", "Chunk 1", "Chunk 2 (Fail)", "Chunk 2"]
    )
    
    query = M.Status.objects;
    got_error = false
    try
      bulk_insert(query, df_multi, chunk_size=2)
    catch e
      got_error = true  # async task failure is unwrapped, so catch sees the real constraint error
    end

    @test got_error
    # Verify that even the first chunk (2001, 2002) was rolled back
    @test query.count() == 0
  end

  # Clear all tables
  delete(M.Circuit.objects, allow_delete_all = true)
  delete(M.Status.objects, allow_delete_all = true)
  delete(M.Driver.objects, allow_delete_all = true)
  delete(M.Constructor.objects, allow_delete_all = true)
  delete(M.Result.objects, allow_delete_all = true)
  delete(M.Just_a_test_deletion.objects, allow_delete_all = true)

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
        df[!, col] = map(x -> ismissing(x) || x == "\\N" ? missing : x, df[!, col])
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
        df[!, col] = map(x -> ismissing(x) || x == "\\N" ? missing : x, df[!, col])
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
        df[!, col] = map(x -> ismissing(x) || x == "\\N" ? missing : x, df[!, col])
    end
    bulk_insert(query, df)
    @test query.count() == 26759
  end  

end