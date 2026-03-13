# ==============================================================================
# MIGRATION PLANNER
# Logic for diffing current code models against database state and generating
# migration plans (makemigrations).
# ==============================================================================

# ---
# Internal Helpers
# ---

function _hash_field_name(model_name::Symbol, field_name::Union{String, Symbol}; apend_number::Int64=5)::String
  _hash = randstring(8) 
  name = "$(model_name)_$field_name"
  if length(name) + 8 + apend_number > 63
    name = name[1:63 - length(_hash)]
  end
  return "$(name)_$_hash" |> lowercase
end

function _configure_order_dict_migration_plan(migration_plan::OrderedDict{Symbol, OrderedDict{String, String}}, model_name::Symbol, key::String, value::String)
  value == "" && return
  if !haskey(migration_plan, model_name)
    migration_plan[model_name] = OrderedDict{String, String}(key => value)
  else
    migration_plan[model_name][key] = value
  end
end  

function _drop_fk_constraint_in_alteration(conn::Union{PormGPostgres, PormGSQLite}, migration_plan::OrderedDict{Symbol, OrderedDict{String, String}}, model_name::Symbol, field_name::String, new_field::Union{PormGField, Nothing}, old_field::PormGField)::Nothing
  if hasfield(old_field |> typeof, :to) && old_field.db_constraint && (new_field === nothing || !hasfield(new_field |> typeof, :to) || !new_field.db_constraint)
    if conn isa PormGSQLite
      # SQLite doesn't have named FK constraints that can be dropped easily without recreation
      # For now, we rely on Dialect.drop_foreign_key which might return a recreation script
      _configure_order_dict_migration_plan(migration_plan, model_name, "Remove foreign key: $field_name", 
      Dialect.drop_foreign_key(conn, model_name |> string, field_name |> string))
      return nothing
    end
    
    constraint_name = get_constraints_fk(conn, model_name, field_name)
    if constraint_name === nothing
      return nothing
    end
    _configure_order_dict_migration_plan(migration_plan, model_name, "Remove foreign key: $field_name", 
    Dialect.drop_foreign_key(conn, model_name, constraint_name))
  end
  return nothing
end
function _drop_fk_constraint_in_alteration(conn::Union{PormGPostgres, PormGSQLite}, migration_plan::OrderedDict{Symbol, OrderedDict{String, String}}, model_name::Symbol, field_name::Symbol, new_field::Union{PormGField, Nothing}, old_field::PormGField)
  _drop_fk_constraint_in_alteration(conn, migration_plan, model_name, field_name |> string, new_field, old_field)
end

function _drop_index(conn::Union{PormGPostgres, PormGSQLite}, migration_plan::OrderedDict{Symbol, OrderedDict{String, String}}, model_name::Symbol, field_name::String; index_name::Union{String, Nothing} = nothing)::Nothing
  if index_name === nothing
    index_name = get_constraints_index(conn, model_name, field_name)
  end
  
  if index_name === nothing
    return nothing
  end
  # PostgreSQL: a UNIQUE constraint creates a backing index with the same name.
  # DROP INDEX fails when the index backs a constraint, so drop the constraint first.
  if conn isa PormGPostgres
    table_name = format_model_name(model_name)
    drop_sql = """ALTER TABLE \"$table_name\" DROP CONSTRAINT IF EXISTS \"$index_name\";\nDROP INDEX IF EXISTS \"$index_name\";"""
    _configure_order_dict_migration_plan(migration_plan, model_name, "Remove index on $field_name", drop_sql)
  else
    _configure_order_dict_migration_plan(migration_plan, model_name, "Remove index on $field_name",
    Dialect.drop_index(conn, index_name))
  end
  return nothing    
end
function _drop_index(conn::Union{PormGPostgres, PormGSQLite}, migration_plan::OrderedDict{Symbol, OrderedDict{String, String}}, model_name::Symbol, field_name::Symbol; index_name::Union{String, Nothing} = nothing)
  _drop_index(conn, migration_plan, model_name, field_name |> string, index_name=index_name)
end

function _add_fk_constraint_in_alteration(conn::Union{PormGPostgres, PormGSQLite}, migration_plan::OrderedDict{Symbol, OrderedDict{String, String}}, model_name::Symbol, field_name::String, new_field::PormGField, old_field::PormGField, name::String)::Nothing
  # to alterations
  if hasfield(new_field |> typeof, :to) && new_field.db_constraint && (!hasfield(old_field |> typeof, :to) || !old_field.db_constraint)
    if conn isa PormGSQLite
       @warn "Adding foreign keys to existing SQLite tables requires recreation. This is not fully automated yet."
       return nothing
    end
    constraint_name = "$(name)_fk" |> lowercase
    resolved_pk = isnothing(new_field.pk_field) ? "id" : string(new_field.pk_field)
    _configure_order_dict_migration_plan(migration_plan, model_name, "New foreign key: $field_name", 
    Dialect.add_foreign_key(conn, model_name, "\"$constraint_name\"", "\"$field_name\"",  "\"$(new_field.to |> format_model_name)\"", "\"$resolved_pk\""))
  end
  return nothing
end

function _add_constrains(conn::Union{PormGPostgres, PormGSQLite}, migration_plan::OrderedDict{Symbol, OrderedDict{String, String}}, model_name::Symbol, model::PormGModel, field_name::Union{String, Symbol}, field::PormGField, name::String)::Nothing
  # to new fields
  # If the new field is a foreign key
  if hasfield(field |> typeof, :to) && field.db_constraint
    if conn isa PormGPostgres
      constraint_name = name * "_fk" |> lowercase
      resolved_pk = isnothing(field.pk_field) ? "id" : string(field.pk_field)
      _configure_order_dict_migration_plan(migration_plan, model_name, "New foreign key: $field_name", 
      Dialect.add_foreign_key(conn, model.name, "\"$constraint_name\"", "\"$field_name\"",  "\"$(field.to |> format_model_name)\"", "\"$resolved_pk\""))
    # For SQLite, FKs are added in CREATE TABLE, so if we are adding a field to an existing table, 
    # we might need recreation if it's a FK.
    end
  end

  # If the new field is also indexed
  if !field.primary_key && field.db_index 
    index_name = name * "_idx" |> lowercase
    _configure_order_dict_migration_plan(migration_plan, model_name, "Create index on $field_name", 
    Dialect.create_index(conn, "\"$index_name\"", "\"$(model.name |> lowercase)\"", ["\"$field_name\""]))
  end  
  nothing
end

function _add_new_table(conn::Union{PormGPostgres, PormGSQLite}, migration_plan::OrderedDict{Symbol, OrderedDict{String, String}}, model_name::Symbol, model::PormGModel)::Nothing
  _configure_order_dict_migration_plan(migration_plan, model_name, "New model", Dialect.create_table(conn, model))
  for (field_name, field) in model.fields       
    name = _hash_field_name(model_name, field_name)      
    _add_constrains(conn, migration_plan, model_name, model, field_name, field, name)      
  end
  return nothing
end

function _add_new_field(conn::Union{PormGPostgres, PormGSQLite}, migration_plan::OrderedDict{Symbol, OrderedDict{String, String}}, model_name::Symbol, model::PormGModel, field_name::String; temporary_default_value::Any = nothing)::Nothing
  field = model.fields[field_name]
  name = _hash_field_name(model_name, field_name)
  _configure_order_dict_migration_plan(migration_plan, model_name, "Add field: $field_name", Dialect.add_field(conn, model_name, field_name, field, temporary_default = temporary_default_value))
  _add_constrains(conn, migration_plan, model_name, model, field_name, field, name)
  if temporary_default_value !== nothing
    _configure_order_dict_migration_plan(migration_plan, model_name, "Alter field: $field_name", Dialect.alter_field(conn, model_name, field_name, field, nothing, [:default]))
  end
  return nothing
end
function _add_new_field(conn::Union{PormGPostgres, PormGSQLite}, migration_plan::OrderedDict{Symbol, OrderedDict{String, String}}, model_name::Symbol, model::PormGModel, field_name::Symbol; temporary_default_value::Any = nothing)::Nothing
  _add_new_field(conn, migration_plan, model_name, model, field_name |> string, temporary_default_value=temporary_default_value)
end

function _alter_table_fields(conn::Union{PormGPostgres, PormGSQLite}, migration_plan::OrderedDict{Symbol, OrderedDict{String, String}}, model_name::Symbol, model::PormGModel, current_schema::Dict{Symbol, Dict{Symbol, Union{Bool, PormGModel}}}, settings::SQLConn; interactive::Bool = true)::Nothing
  # @infiltrate model_name == :new_join_position
  if Models.are_model_fields_equal(current_schema[model_name][:model], model)
    # println("Model $model_name are equal")
  else        
    # Compare fields
    @infiltrate false
    # Convert keys(model.fields) to an array of stripped strings and keep mapping to original key
    model_fields_map = Dict(String(strip(key, '"')) => String(key) for key in keys(model.fields))
    stripped_model_fields = Set(keys(model_fields_map))

    # Do the same for current_schema model fields
    current_fields_map = Dict(String(strip(key, '"')) => String(key) for key in keys(current_schema[model_name][:model].fields))
    stripped_current_fields = Set(keys(current_fields_map))

    # check the field are not in current_schema (deletion)
    colect_deletion::Vector{Symbol} = []
    for field_name in stripped_model_fields
      if !(field_name in stripped_current_fields)
        push!(colect_deletion, Symbol(field_name))
      end
    end

    colect_addition::Vector{Symbol} = []
    for field_name in stripped_current_fields
      if !(field_name in stripped_model_fields)
        push!(colect_addition, Symbol(field_name))
      end
    end    
    
    @infiltrate false
    # Pass maps to resolve fields so original keys can be used for accessing model.fields
    _resolve_table_fields(conn, model_name, model, current_schema[model_name][:model], colect_deletion, colect_addition, migration_plan, settings, model_fields_map, current_fields_map, interactive=interactive)
      
    for field_name_stripped in stripped_current_fields
      original_code_key = current_fields_map[field_name_stripped]
      if haskey(model_fields_map, field_name_stripped)
        original_db_key = model_fields_map[field_name_stripped]
        
        field = current_schema[model_name][:model].fields[original_code_key]
        old_field = model.fields[original_db_key]

        # check if the field is diferent
        colect_not_equal::Vector{Symbol} = []
        if old_field |> typeof == field |> typeof                          
          # Check if all attributes are equal                
          for attr in fieldnames(typeof(field))
            new_var = getfield(field, attr)
            old_var = getfield(old_field, attr)
            if new_var != old_var                  
              attr == :to && Models._compare_field_foreign_key(field, old_field) && continue
              attr in [:blank, :on_delete, :related_name, :verbose_name, :editable, :how, :formater] && continue 
              push!(colect_not_equal, attr)
            end
          end
        else
          # check is db_constraint is false in field
          if field |> typeof == Models.sForeignKey && !field.db_constraint &&  old_field |> typeof == Models.sBigIntegerField
            continue
          else
            push!(colect_not_equal, :type)
          end
        end
        
        # if field_name == "time"
        #   @infiltrate
        # end
        
        isempty(colect_not_equal) && continue                       

        # Check if is needed remove the foreign key
        name::String = _hash_field_name(model_name, field_name_stripped)
        
        _drop_fk_constraint_in_alteration(conn, migration_plan, model_name, field_name_stripped, field, old_field)
        
        _configure_order_dict_migration_plan(migration_plan, model_name, "Alter field: $field_name_stripped",
        Dialect.alter_field(conn, current_schema[model_name][:model], field_name_stripped, field, old_field, colect_not_equal))

        # Check if the field is a foreign key
        _add_fk_constraint_in_alteration(conn, migration_plan, model_name, field_name_stripped, field, old_field, name)
        
        # Check if the field is also indexed
        if !field.primary_key && field.db_index && !model.fields[original_db_key].db_index
          @infiltrate false
          index_name = "$(name)_idx"
          _configure_order_dict_migration_plan(migration_plan, model_name, "Create index on $field_name_stripped", 
          Dialect.create_index(conn, "\"$index_name\"", "\"$(model.name |> lowercase)\"", ["\"$field_name_stripped\""]))
        end

        # Check if is need to remove the index
        if !field.primary_key && old_field.db_index && !field.db_index
          @infiltrate
          index_name = model.cache["index"][original_db_key]
          _drop_index(conn, migration_plan, model_name, field_name_stripped, index_name=index_name)
          # _configure_order_dict_migration_plan(migration_plan, model_name, "Remove index on $field_name_stripped", 
          # Dialect.drop_index(conn, "\"$index_name\""))
        end
      end
    end    
  end     
end

function _resolve_table_fields(
                                conn::Union{PormGPostgres, PormGSQLite}, 
                                model_name::Symbol, 
                                model::PormGModel, 
                                current_model::PormGModel, 
                                colect_deletion::Vector{Symbol}, 
                                colect_addition::Vector{Symbol}, 
                                migration_plan::OrderedDict{Symbol, OrderedDict{String, String}},
                                settings::SQLConn,
                                model_fields_map::Dict{String, String},
                                current_fields_map::Dict{String, String};
                                interactive::Bool = true
                              )::Nothing
  # Check by rename field  
  while !isempty(colect_addition)
    field_name_sym = colect_addition[1]
    field_name = field_name_sym |> string       
    colect_numbered, list_to_question = _colect_numbered_fields(colect_deletion)
    if colect_deletion |> isempty 
      _add_new_field(conn, migration_plan, model_name, current_model, field_name, temporary_default_value = _get_temporary_default_value(current_model.fields[current_fields_map[field_name]], settings))
    else       
      response = "no"
      if interactive
        print("Is the field \"\e[4m\e[31m$field_name\e[0m\" from table \"\e[4m\e[34m$model_name\e[0m\" the same as one of the following fields: \e[4m\e[33m$list_to_question\e[0m? If yes, please enter the corresponding number; otherwise, type 'no':")
        response = readline()
        response = strip(lowercase(response))
      end
      
      if response in ["no", "n"]
        _add_new_field(conn, migration_plan, model_name, current_model, field_name, temporary_default_value = _get_temporary_default_value(current_model.fields[current_fields_map[field_name]], settings))
      else
        old_field_sym::Union{Symbol,Nothing} = nothing
        try
          response_idx = parse(Int, response)
          old_field_sym = colect_numbered[response_idx]          
        catch e
          throw("Invalid number, please try makemigrations again")
          return
        end
        old_field_name = old_field_sym |> string
        _drop_fk_constraint_in_alteration(conn, migration_plan, model_name, old_field_name, current_model.fields[current_fields_map[field_name]], model.fields[model_fields_map[old_field_name]])
        !current_model.fields[current_fields_map[field_name]].primary_key && _drop_index(conn, migration_plan, model_name, old_field_name)
        _configure_order_dict_migration_plan(migration_plan, model_name, "Rename field: $field_name", 
        Dialect.rename_field(conn, model_name, old_field_name, field_name))
        _add_constrains(conn, migration_plan, model_name, current_model, field_name, current_model.fields[current_fields_map[field_name]], _hash_field_name(model_name, field_name))
        # Update model.fields to reflect rename to avoid double processing if needed
        model.fields[model_fields_map[old_field_name]] = model.fields[model_fields_map[old_field_name]] # effectively stays same but we can update key if we want to sync
        # remove the old field from colect_deletion
        filter!(x -> x != old_field_sym, colect_deletion)
      end
    end      
    filter!(x -> x != field_name_sym, colect_addition)
  end
  if !isempty(colect_deletion)
    for field_name_sym in colect_deletion
      field_name = field_name_sym |> string
      _drop_fk_constraint_in_alteration(conn, migration_plan, model_name, field_name, nothing, model.fields[model_fields_map[field_name]])
      _drop_index(conn, migration_plan, model_name, field_name)
      _configure_order_dict_migration_plan(migration_plan, model_name, "Remove field: $field_name", 
      Dialect.drop_field(conn, model_name, field_name))
    end
  end
end

function _colect_numbered_fields(colect::Vector{Symbol})
  colect_numbered = Dict{Int64, Symbol}()
  for (index, field_name) in enumerate(colect)
    colect_numbered[index] = field_name
  end
  return colect_numbered, join([string(index, " - ", colect[index]) for index in keys(colect_numbered)], ", ")
end
function _get_temporary_default_value(field::PormGField, settings::SQLConn)
  if field |> typeof == Models.sDateTimeField
    return field.formater(now(), settings.time_zone) |> field.formater
  elseif field |> typeof == Models.sDateField
    return field.formater(today())    
  else
    return nothing
  end
end


# ---
# Public API (makemigrations)
# ---

# Compare model definitions to the current database schema
function get_migration_plan(models::Vector{PormGModel}, current_schema::Dict{Symbol, Dict{Symbol, Union{Bool, PormGModel}}}, conn, settings::SQLConn; interactive::Bool = true)
# models is olds models

migration_plan = OrderedDict{Symbol, OrderedDict{String, String}}()
futher_processing = Dict{Symbol, Dict{Symbol, Any}}()

# models is empty set all models to migration_plan
if isempty(models)
  for (model_name, model) in current_schema
    _add_new_table(conn, migration_plan, model_name, model[:model])
  end
  return migration_plan  
end

@infiltrate false

for model in models # models is olds models
  model_name = model.name |> Symbol
  # model_name = lowercase(string(model.name)) |> Symbol
  @infiltrate false
  if haskey(current_schema, model_name)
    current_schema[model_name][:exist] = true
    _alter_table_fields(conn, migration_plan, model_name, model, current_schema, settings, interactive=interactive)
  else
    if !haskey(futher_processing, :drop_table)
      futher_processing[:drop_table] = Dict{Symbol, Any}(model_name => Dict{String, Any}("model" => model, "exist" => false))
    else
      futher_processing[:drop_table][model_name] = Dict{String, Any}("model" => model, "exist" => false)
    end
  end
end

@infiltrate false

# Check for models in the current schema that are not in the models
for (model_name, model) in current_schema
  if model[:exist] == false
    if haskey(futher_processing, :drop_table) # TODO: i need test this
      
      response = "yes"
      if interactive
        print("The table $model_name is a new table? (yes/no): ")
        response = readline()
        response = strip(lowercase(response))
      end

      if response in ["yes", "y"]
        _add_new_table(conn, migration_plan, model_name, model[:model])
      elseif response in ["no", "n"]
        dict_rename = Dict{Int64, Symbol}()
        for (index, (m_name, m_info)) in enumerate(futher_processing[:drop_table])
          !m_info["exist"] && (dict_rename[index] = m_name )           
        end         
        if isempty(dict_rename)
          _add_new_table(conn, migration_plan, model_name, model[:model])
        else 
          list_to_question = join([string(index, " - ", dict_rename[index]) for index in keys(dict_rename)], ", ")
          
          response = "no"
          if interactive
            print("Please choice what is the older name from table $model_name: $list_to_question (choice a number) or type 'no': ")
            response = readline()
            response = strip(lowercase(response))
          end

          if response in ["no", "n"]
            _add_new_table(conn, migration_plan, model_name, model[:model])
          else
            try
              res_idx = parse(Int, response)
              old_model_name = dict_rename[res_idx]
              # first i need to alter the fields from old table named in postgres
              _alter_table_fields(conn, migration_plan, old_model_name, futher_processing[:drop_table][old_model_name]["model"], current_schema, settings, interactive=interactive)
              _configure_order_dict_migration_plan(migration_plan, model_name, "Rename table", Dialect.rename_table(conn, model_name, old_model_name |> string))
              futher_processing[:drop_table][old_model_name]["exist"] = true
            catch e
              throw("Invalid number, please try makemigrations again")
            end
          end
        end         
      end    
    else 
      _add_new_table(conn, migration_plan, model_name, model[:model])    
    end
  end
 
end

@infiltrate false

# at last check all models in futher_processing to drop
if haskey(futher_processing, :drop_table)
  for (model_name, model_info) in futher_processing[:drop_table]
    if model_info["exist"] == false
      _configure_order_dict_migration_plan(migration_plan, model_name, "Drop table", Dialect.drop_table(conn, model_name))
    end
  end
end

# println(migration_plan)


return migration_plan
end

# Main function to simulate makemigrations
function makemigrations(connection::PormGPostgres, settings::SQLConn; path::String = "db/models.jl", interactive::Bool = true)
if !settings.change_db
  @warn("The database is not set to change_db, so the migration plan will not be applied.")
  return
end
@infiltrate false
models_array::Vector{PormGModel} = []
try
  models_array = convert_schema_to_models(connection)
catch e
  error_message = sprint(showerror, e)
  if occursin("Table definition not found", error_message)
    @info("The database is empty, that is migrate all tables") # TODO, impruve this message
  else
    println("Error: ", e)
    @error("Error: ", e)
    return
  end
end

# get module from the path
temp_module = Module(:TemporaryModels)
Base.include(temp_module, path)
# current_models = get_all_models(Base.invokelatest(getfield, temp_module, :models))
current_models = Base.invokelatest(get_all_models, Base.invokelatest(getfield, temp_module, :models)) # TODO : i need create abstrations to deal with change :models name

@infiltrate false

migration_plan = get_migration_plan(models_array, current_models, connection, settings, interactive=interactive)

@infiltrate false

# store migration_plan as pending_migrations.jl file
if migration_plan |> isempty
  @info("\e[32mYour database schema is already up-to-date. No migrations are pending.\e[0m")    
else     
  path = joinpath(settings.db_def_folder, "migrations")
  if !ispath(path)
    mkdir(path)
  end
  generate_migration_plan("pending_migrations.jl", migration_plan, path)
  @warn("The migration plan has been saved to '$(settings.db_def_folder)/migrations/pending_migrations.jl'. Review the plan before applying the migrations.")
  @info("\e[32mMigration plan generated successfully. Run 'PormG.Migrations.migrate($( settings.db_def_folder == "db" ? "" : string("\"", settings.db_def_folder, "\"")))' to apply the migrations.\e[0m")
end

end

function makemigrations(connection::PormGSQLite, settings::SQLConn; path::String = "db/models.jl", interactive::Bool = true)
  if !settings.change_db
    @warn("The database is not set to change_db, so the migration plan will not be applied.")
    return
  end
  
  models_array::Vector{PormGModel} = []
  try
    models_array = convert_schema_to_models(connection)
  catch e
    @error("Error converting schema to models: ", e)
    return
  end

  # get module from the path
  temp_module = Module(:TemporaryModels)
  Base.include(temp_module, path)
  current_models = Base.invokelatest(get_all_models, Base.invokelatest(getfield, temp_module, :models))

  migration_plan = get_migration_plan(models_array, current_models, connection, settings, interactive=interactive)

  # store migration_plan as pending_migrations.jl file
  if migration_plan |> isempty
    @info("\e[32mYour database schema is already up-to-date. No migrations are pending.\e[0m")    
  else     
    path = joinpath(settings.db_def_folder, "migrations")
    if !ispath(path)
      mkdir(path)
    end
    generate_migration_plan("pending_migrations.jl", migration_plan, path)
    @warn("The migration plan has been saved to '$(settings.db_def_folder)/migrations/pending_migrations.jl'. Review the plan before applying the migrations.")
    @info("\e[32mMigration plan generated successfully. Run 'PormG.Migrations.migrate($( settings.db_def_folder == "db" ? "" : string("\"", settings.db_def_folder, "\"")))' to apply the migrations.\e[0m")
  end
end

function makemigrations(db::String; config::Dict{String,SQLConn} = config, interactive::Bool = true)
settings = Configuration.get_settings(db)
path = joinpath(db, settings.model_file)
isfile(path) || error("The file $(path) does not exists")
makemigrations(settings.connections, settings, path=path, interactive=interactive)
end

function get_all_models(mod::Module)::Dict{Symbol, Dict{Symbol, Union{Bool, PormGModel}}}
# Get all models from a module
models = Dict{Symbol, Dict{Symbol, Union{Bool, PormGModel}}}()
for name in names(mod, all = true)
  if isdefined(mod, name)
    obj = getfield(mod, name)
    if isa(obj, PormGModel)
      if obj.name == ""
        obj.name = name |> string |> format_model_name
      end
      models[name |> string |> lowercase |> Symbol] = Dict{Symbol, Union{Bool, PormGModel}}(:model => obj, :exist => false) # TODO: change model.name to lowercase in all project
    end
  end
end
return models
end