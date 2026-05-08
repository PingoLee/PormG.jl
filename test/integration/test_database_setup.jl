if !isdefined(Main, :PormG)
    include("common_setup.jl")
end

_bulk_update_fixture_id_type(pool) = pool isa PormG.PormGPostgres ? "SERIAL" : "INTEGER"

function _ensure_bulk_update_fixture_schema!()
  pool = PormG.config[PORMG_DB_FOLDER].connections
  id_type = _bulk_update_fixture_id_type(pool)

  PormG.ConnectionPool.fetch(pool, """
  CREATE TABLE IF NOT EXISTS \"bulk_update_required_parent_scratch\" (
    \"id\" $id_type PRIMARY KEY,
    \"label\" TEXT NOT NULL
  );
  """)

  PormG.ConnectionPool.fetch(pool, """
  CREATE TABLE IF NOT EXISTS \"bulk_update_optional_parent_scratch\" (
    \"id\" $id_type PRIMARY KEY,
    \"label\" TEXT NOT NULL
  );
  """)

  PormG.ConnectionPool.fetch(pool, """
  CREATE TABLE IF NOT EXISTS \"bulk_update_payload_scratch\" (
    \"id\" $id_type PRIMARY KEY,
    \"label\" TEXT NOT NULL,
    \"required_parent_id\" INTEGER NOT NULL REFERENCES \"bulk_update_required_parent_scratch\" (\"id\"),
    \"optional_parent_id\" INTEGER REFERENCES \"bulk_update_optional_parent_scratch\" (\"id\"),
    \"event_date\" DATE,
    \"is_active\" BOOLEAN NOT NULL DEFAULT FALSE
  );
  """)

  return nothing
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
  # Insert-specific behavioral tests (Schema Evolution, Error Recovery) have been
  # extracted to test_inserts.jl, which runs before this file in the suite.
  # This file now acts purely as a fixture seeder for the remaining test phases.

  _ensure_bulk_update_fixture_schema!()

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
  M.Bulk_update_payload_scratch.objects.delete(allow_delete_all = true)
  M.Bulk_update_optional_parent_scratch.objects.delete(allow_delete_all = true)
  M.Bulk_update_required_parent_scratch.objects.delete(allow_delete_all = true)

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