# ==============================================================================
# MIGRATION RUNNER
# Logic for applying generated migration plans to the database (migrate).
# ==============================================================================

function get_all_dicts(mod::Module)
  ordered_dicts = []
  for name in names(mod, all = true)
    if isdefined(mod, name)
      obj = getfield(mod, name)
      if isa(obj, OrderedDict)
        push!(ordered_dicts, obj)
      end
    end
  end
  return ordered_dicts
end

function migrate(connection::PormGPostgres, settings::SQLConn; path::String = "db/models/models.jl", interactive::Bool = true)
  if !settings.change_db
    @warn("The database is not set to change_db, so the migration plan will not be applied.")
    return
  end
  
  if interactive
    @info("\e[33mBefore applying the migrations, make sure to back up your database. Migrations are irreversible. And the PormG is in development, so it is not guaranteed that the migrations will be applied correctly.\e[0m")
    print("\e[31mAre you sure you want to apply the migrations? (yes/no): \e[0m")
    response = readline()
    response = strip(lowercase(response))
    if !(response in ["yes", "y"])
      @info("Migrations were not applied.")
      return
    end
  end

  # Load the migration plan
  # migration_plan = include(joinpath(settings.db_def_folder, "migrations", "pending_migrations.jl")) |> get_all_dicts
  temp_migration_module = include(joinpath(settings.db_def_folder, "migrations", "pending_migrations.jl"))
  migration_plan = Base.invokelatest(get_all_dicts, temp_migration_module)

  # build the transaction to apply the migration plan
  fisrt_execution::Vector{String} = []
  second_execution::Vector{String} = []
  third_execution::Vector{String} = []
  last_execution::Vector{String} = []

  @infiltrate false

  for dict_instructs in migration_plan
    # println("Executing: $dict_instructs")
    for (key, value) in dict_instructs
      if key == "New model"
        push!(fisrt_execution, value)
      elseif key == "Drop table"
        push!(second_execution, value)
      elseif contains(key, "Rename field")
        push!(third_execution, value)
      else
        push!(last_execution, value)
      end
    end  
  end

  contatenate_execution = [fisrt_execution, second_execution, third_execution, last_execution]

  # Begin a transaction
  result, conn = with_transaction(connection, "BEGIN;")

  try
    # Iterate over the migration plan and execute each SQL statement
    for execution in contatenate_execution
      for action in execution
        println("Executing: $action")
        with_transaction(connection, action, conn=conn)
      end
    end   
    # Commit the transaction
    with_transaction(connection, "COMMIT;", conn=conn, release_conn = true)
    @info("Migrations applied successfully.")    
  catch e
    # Rollback the transaction in case of an error
    with_transaction(connection, "ROLLBACK;", conn=conn, release_conn = true)
    println("Error applying migrations: ", e)
    @error("Error applying migrations: ", e)
    return nothing
  end

  try
    # check if folder applied_migrations exists
    path = joinpath(settings.db_def_folder, "migrations", "applied_migrations")
    if !ispath(path)
      mkdir(path)
    end
    # move the file pending_migrations.jl to applied_migrations folder and rename it to the current date and time
    date = Dates.format(Dates.now(), "yyyy-mm-dd_HH-MM-SS")
    target_migration = joinpath(path, "$(date)_migration.jl")
    if isfile(target_migration)
        date = date * "_" * string(rand(1000:9999))
        target_migration = joinpath(path, "$(date)_migration.jl")
    end
    mv(joinpath(settings.db_def_folder, "migrations", "pending_migrations.jl"), target_migration)   
    cp(joinpath(settings.db_def_folder, "models.jl"), joinpath(path, "$(date)_old_models.jl"), force=true) # TODO: I need deal with custom model name
  catch e
    # @infiltrate
    @error("Error moving files: ", e)
  end

  
end

function migrate(connection::PormGSQLite, settings::SQLConn; path::String = "db/models/models.jl", interactive::Bool = true)
  if !settings.change_db
    @warn("The database is not set to change_db, so the migration plan will not be applied.")
    return
  end
  
  if interactive
    @info("\e[33mBefore applying the migrations, make sure to back up your database. Migrations are irreversible.\e[0m")
    print("\e[31mAre you sure you want to apply the migrations? (yes/no): \e[0m")
    response = readline()
    response = strip(lowercase(response))
    if !(response in ["yes", "y"])
      @info("Migrations were not applied.")
      return
    end
  end

  # Load the migration plan
  temp_migration_module = include(joinpath(settings.db_def_folder, "migrations", "pending_migrations.jl"))
  migration_plan = Base.invokelatest(get_all_dicts, temp_migration_module)

  # build the execution plan
  fisrt_execution::Vector{String} = []
  second_execution::Vector{String} = []
  third_execution::Vector{String} = []
  last_execution::Vector{String} = []

  for dict_instructs in migration_plan
    for (key, value) in dict_instructs
      if key == "New model"
        push!(fisrt_execution, value)
      elseif key == "Drop table"
        push!(second_execution, value)
      elseif contains(key, "Rename field")
        push!(third_execution, value)
      else
        push!(last_execution, value)
      end
    end  
  end

  concatenate_execution = [fisrt_execution, second_execution, third_execution, last_execution]

  # Begin a transaction
  # Use BEGIN IMMEDIATE TRANSACTION for SQLite to prevent deadlocks
  result, conn = with_transaction(connection, "BEGIN IMMEDIATE TRANSACTION;")

  try
    for execution in concatenate_execution
      for action in execution
        # Split action into multiple statements by ;
        # We need to be careful not to split ; inside strings, but for migrations 
        # generated by PormG, ; is only used as a statement separator.
        statements = split(action, ";")
        for stmt in statements
          trimmed_stmt = strip(stmt) |> string
          if isempty(trimmed_stmt)
            continue
          end
          println("Executing: $trimmed_stmt")
          with_transaction(connection, trimmed_stmt, conn=conn)
        end
      end
    end
    # Commit the transaction
    with_transaction(connection, "COMMIT;", conn=conn, release_conn = true)
    @info("Migrations applied successfully.")
  catch e
    # Rollback the transaction in case of an error
    with_transaction(connection, "ROLLBACK;", conn=conn, release_conn = true)
    @error("Error applying migrations: ", e)
    rethrow(e)
  end

  try
    path_applied = joinpath(settings.db_def_folder, "migrations", "applied_migrations")
    if !ispath(path_applied)
      mkdir(path_applied)
    end
    date = Dates.format(Dates.now(), "yyyy-mm-dd_HH-MM-SS")
    target_migration = joinpath(path_applied, "$(date)_migration.jl")
    
    # If file exists (e.g. multiple migrations in same second), append a suffix
    while isfile(target_migration)
        suffix = string(rand(1000:9999))
        target_migration = joinpath(path_applied, "$(date)_$(suffix)_migration.jl")
    end
    
    final_date_str = occursin("_migration.jl", target_migration) ? replace(basename(target_migration), "_migration.jl" => "") : date

    mv(joinpath(settings.db_def_folder, "migrations", "pending_migrations.jl"), target_migration)   
    cp(joinpath(settings.db_def_folder, "models.jl"), joinpath(path_applied, "$(final_date_str)_old_models.jl"), force=true)
  catch e
    @error("Error moving files: ", e)
  end
end

function migrate(db::String; config::Dict{String,SQLConn} = config, interactive::Bool = true)
  settings = config[db]
  migrate(settings.connections, settings, interactive=interactive)
end