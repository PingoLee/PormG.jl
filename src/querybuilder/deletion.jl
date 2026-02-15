# ---
# Django like function to build a delete query with cascade, restrict, set null, set default and set value (AI please don't delete this code)
#

"""
Delete objects from the database with proper handling of foreign key relationships and cascading operations.

## Arguments
- `objct::SQLObjectHandler`: The SQL object handler containing the query and model information
- `show_query::Bool=false`: If `true`, displays the generated SQL queries instead of executing them
- `allow_delete_all::Bool=false`: If `true`, allows deletion without WHERE clause filters (dangerous operation)

## Returns
- `Tuple{Integer, Dict{String, Integer}}`: A tuple containing:
  - Total number of deleted objects
  - Dictionary mapping model names to their respective deletion counts

## Behavior
- Validates that the connection allows data modification operations
- Requires WHERE clause filters unless `allow_delete_all` is explicitly set to `true`
- Handles foreign key relationships by building a deletion dependency graph
- Processes SET_NULL, SET_DEFAULT, and cascading delete operations appropriately
- Executes all operations within a database transaction for data integrity

## Examples

```julia
# Delete objects from a model with a specific filter
query = M.Status |> object
query.filter("status" => "Engine")
total, dict = delete(query)

# Show the SQL query without executing it
query = M.Just_a_test_deletion |> object
query.filter("test_result__constructorid__name" => "Williams")
total, dict = delete(query, show_query = true)

# Delete related tables (cascading delete)
query = M.Result |> object
query.filter("resultid" => 1)
total, dict = delete(query, show_query = false)

# Delete all objects from a model (use with caution)
query = M.Just_a_test_deletion |> object
total, dict = delete(query; allow_delete_all = true)


```
"""
function delete(objct::SQLObjectHandler; 
    table_alias::Union{Nothing, SQLTableAlias} = nothing, 
    connection::Union{Nothing, PormGPostgres, PormGSQLite} = nothing, 
    show_query::Bool = false,
    allow_delete_all::Bool = false)
  model = objct.object.model
  ensure_model_transaction_scope(model)
  
  # Resolve settings
  settings, connection, conn_key = get_settings(objct, connection=connection)
    
  # check if is allowed to delete
  !settings.change_data && throw(ArgumentError("Error in delete, the connection \e[4m\e[31m$conn_key\e[0m not allowed to delete"))

  # don't allow to delete without filter
  !allow_delete_all && objct.object.filter  |> isempty && throw("Error in delete, the delete must have a filter")
  
  # If no objects to delete, return early
  if objct |> !do_exists
    return 0, Dict{String, Integer}()
  end

  # We'll track deletion counts
  deleted_counter = Dict{String, Integer}()
  
  # Collect related models that need special handling
  collector = DeletionCollector(model, settings)
  
  # Add the primary objects to delete
  add_objects_to_collector!(collector, objct |> deepcopy, model)
  
  # Build and sort the deletion graph
  process_collector!(collector)

  @infiltrate false
  if connection isa PormGPostgres
    @infiltrate false
    run_deletions = function(conn::Union{Nothing, LibPQ.Connection})
      # Process fast deletes first (objects that can be deleted directly)
      for (model, keys) in collector.fast_deletes
        delete_objects(connection, model, keys, show_query, deleted_counter, conn)
        # Remove from objects to prevent double deletion
        delete!(collector.objects, model)
      end

      # Process field updates (for SET_NULL, SET_DEFAULT, etc.)
      for ((field, value), affected_models) in collector.field_updates
        @infiltrate false
        for (affected_model, keys) in affected_models
          update_field(connection, affected_model, field, value, keys, show_query, conn)
        end
      end
      
      # Execute deletions in the sorted order
      for model_to_delete in collector.sorted_models
        @infiltrate false
        _array = get(collector.objects, model_to_delete, [])        
        if !isempty(_array)
          @infiltrate false
          delete_objects(connection, model_to_delete, _array, show_query, deleted_counter, conn)
        end
      end
    end

    tx_conn = transaction_connection_for(settings)
    if show_query
      run_deletions(nothing)
    elseif tx_conn !== nothing
      run_deletions(tx_conn)
    else
      _, conn = with_transaction(settings, "BEGIN;")
      try
        with_tx_context(settings.connections, conn) do
          run_deletions(conn)
        end
        # Commit transaction
        with_transaction(settings, "COMMIT;", conn=conn, release_conn=true)
      catch e
        # Rollback on error
        with_transaction(settings, "ROLLBACK;", conn=conn, release_conn=true)
        rethrow(e)
      end
    end
  else
    # Similar implementation for SQLite
    # ...
  end

  total_deleted = sum(values(deleted_counter))
  if total_deleted == 0
    @warn("Warning in delete, no objects were deleted")  
  end
  
  return total_deleted, deleted_counter
end

function add_objects_to_collector!(collector::DeletionCollector, objct::SQLObjectHandler, model::PormGModel)
  # Extract IDs from objects - handle NamedTuples or Dict structures
  @infiltrate false
  pk_field = get_model_pk_field(model) |> string |> lowercase
  objct.values(pk_field);
  add_objects_to_collector!(collector, model, pk_field, objct)
end


function add_objects_to_collector!(collector::DeletionCollector, model::PormGModel, key::String, objct::SQLObjectHandler)
  # Add to collector
  # @info objct |> query
  @infiltrate false
  if !haskey(collector.objects, model)
    collector.objects[model] = []
  end
 
  push!(collector.objects[model], Dict(:key => key, :objct => objct))
  
  # Add model to the list of models to process
  if !haskey(collector.dependencies, model)
    collector.dependencies[model] = Set{PormGModel}()
  end
end


function process_collector!(collector::DeletionCollector)
  # Process each model and its objects
  for (model, keys) in collector.objects
    # Find related objects through foreign keys    
    find_related_objects!(collector, model, keys)
  end

  # Identify objects that can be fast-deleted
  collect_fast_deletes!(collector)
  
  # Topologically sort models for deletion
  collector.sorted_models = topological_sort(collector.dependencies)
end

function find_related_objects!(collector::DeletionCollector, model::PormGModel, dict::Vector{Dict{Symbol, Union{String, SQLObjectHandler}}})
  # For each foreign key in the model (model has FK -> related_model)
  @infiltrate false
  _django = collector.settings.django_prefix === nothing ? false : true
    
  # For models with foreign keys pointing to this model (related_model has FK -> model)
  for (related_name, (field_name, pk_field, related_model_name, pk_model)) in model.related_objects
    _django && (related_model_name = replace(string(related_model_name), collector.settings.django_prefix * "_" => "") |> Symbol)
    related_model = getfield(model._module, related_model_name |> capitalize_symbol);

    _query = related_model |> object;
    if size(dict, 1) == 1
      _query.filter("$(field_name)__@in" => dict[1][:objct]);
    else
      or_object = Qor("$(field_name)__@in" => dict[1][:objct])
      push!(or_object, "$(field_name)__@in" => dict[1][:objct])
      for (index, dict_) in enumerate(dict)
        if index == 1
          continue # already added
        end
        push!(or_object, "$(field_name)__@in" => dict_[:objct])
      end
      _query.filter(or_object)
    end
    
    @infiltrate false
    _query |> do_exists || continue # No related objects, skip
     
    # @info _query |> query

    # THE ORDER IS correctly set?
    if !haskey(collector.dependencies, related_model)
      collector.dependencies[related_model] = Set{PormGModel}()
    end  
    push!(collector.dependencies[related_model], model)

    _keys = Dict{Symbol, Union{String, SQLObjectHandler}}()
    _keys[:key] = pk_model |> string |> lowercase
    _keys[:objct] = _query    

    field = related_model.fields[String(field_name)]
    handle_on_delete!(collector, field_name, field, model, _keys, related_model)

  end
end

function handle_on_delete!(collector::DeletionCollector, field_name::Union{String, Symbol}, field::PormGField, model::PormGModel, 
  keys::Dict{Symbol, Union{String, SQLObjectHandler}}, related_model::PormGModel)
  @infiltrate false
  if field.on_delete == CASCADE
    pk_field = get_model_pk_field(related_model) |> string |> lowercase
    @infiltrate false
    _query = deepcopy(keys[:objct])
    _query.values(pk_field) 
    _keys = Dict{Symbol, Union{String, SQLObjectHandler}}()
    _keys[:key] = pk_field
    _keys[:objct] = _query
    
    # @info _query |> query
    add_objects_to_collector!(collector, related_model, pk_field, _query) 
    @infiltrate false
    find_related_objects!(collector, related_model, [_keys]) # Recursively find related objects for the related model
  elseif field.on_delete in [PROTECT, RESTRICT]    
    # More descriptive error with field name, constraint type, and sample IDs
    constraint_type = field.on_delete == PROTECT ? "PROTECT" : "RESTRICT"
    throw(ArgumentError("Cannot delete \e[4m\e[31m$(related_model.name)\e[0m because it is referenced by \e[4m\e[31m$(model.name).$(field_name)\e[0m with ON DELETE \e[4m\e[31m$(constraint_type)\e[0m constraint"))
  elseif field.on_delete == SET_NULL
    # TODO : I dont check if this works
    @infiltrate false
    # check if the field allow null
    if !field.null
      throw(ArgumentError("Error in delete, the field \e[4m\e[31m$(field_name)\e[0m not allow null"))
    end

    # Add field update to set field to NULL
    if !haskey(collector.field_updates, (field_name |> string, nothing))
      @infiltrate false
      collector.field_updates[(field_name |> string, nothing)] = Dict{PormGModel, Dict{Symbol, Union{String, SQLObjectHandler}}}()
    end
    
    @infiltrate false
    # Add to field updates using _query object like CASCADE
    pk_field = get_model_pk_field(related_model) |> string |> lowercase
    _query = deepcopy(keys[:objct])
    _query.values(pk_field)
    _keys = Dict{Symbol, Union{String, SQLObjectHandler}}()
    _keys[:key] = pk_field
    _keys[:objct] = _query
    collector.field_updates[(field_name |> string, nothing)][related_model] = _keys

  elseif field.on_delete == SET_DEFAULT
    # TODO : I dont check if this works
    # Add field update to set field to default value
    default_value = field.default
    if !haskey(collector.field_updates, (field_name |> string, default_value))
      collector.field_updates[(field_name |> string, default_value)] = Dict{PormGModel, Dict{Symbol, Union{String, SQLObjectHandler}}}()
    end    
    
    # Add to field updates using _query object like CASCADE
    pk_field = get_model_pk_field(related_model) |> string |> lowercase
    _query = deepcopy(keys[:objct])
    _query.values(pk_field)
    _keys = Dict{Symbol, Union{String, SQLObjectHandler}}()
    _keys[:key] = pk_field
    _keys[:objct] = _query
    @infiltrate
    collector.field_updates[(field_name |> string, default_value)][related_model] = _keys
  end
end

function topological_sort(dependencies::Dict{PormGModel, Set{PormGModel}})
  result = Vector{PormGModel}()
  temp_mark = Set{PormGModel}()
  perm_mark = Set{PormGModel}()
  
  function visit(node)
    if node in temp_mark
      throw(ArgumentError("Circular dependency detected in model relationships"))
    end
    
    if !(node in perm_mark)
      push!(temp_mark, node)
      for dep in get(dependencies, node, Set{PormGModel}())
        visit(dep)
      end
      delete!(temp_mark, node)
      push!(perm_mark, node)
      push!(result, node)
    end
  end
  
  for node in keys(dependencies)
    if !(node in perm_mark)
      visit(node)
    end
  end
  
  return reverse(result)
end

function collect_fast_deletes!(collector::DeletionCollector)
  # Find models that have no dependencies (nothing depends on them)
  
  # First, identify all models that have something depending on them
  models_with_dependents = Set{PormGModel}()  
  # A model is a dependent if it appears as a key in the dependencies dict
  # AND has a non-empty set of dependencies
  for (model, dependencies) in collector.dependencies
    if !isempty(dependencies)
      # This model depends on something, so it's not a leaf node
      push!(models_with_dependents, model)
      
      # Also add the models it depends on (they have dependents)
      union!(models_with_dependents, dependencies)
    end
  end
  
  # Models that can be fast-deleted are those that:
  # 1. Have objects to delete
  # 2. Don't appear in models_with_dependents
  for (model, keys) in collector.objects
    if !(model in models_with_dependents)
      @infiltrate false
      collector.fast_deletes[model] = keys
    end
  end
end

function delete_objects(connection::Union{PormGPostgres, PormGSQLite}, model::PormGModel, keys::Vector{Dict{Symbol, Union{String, SQLObjectHandler}}},
   show_query::Bool, deleted_counter::Dict{String, Integer}, conn::Union{Nothing, LibPQ.Connection})
  @infiltrate false
  # Execute the actual deletion SQL
  _where = String[]
  parameters = get_parameter(connection)
  # @info keys[1][:objct] |> query
  for key in keys
    pk_field = key[:key]
    push!(_where, """"$(pk_field)" IN ($(query(key[:objct], parameters=parameters)))""")
  end
  sql::String = ""
  if size(keys, 1) == 1
    deleted_counter[model.name] = keys[1][:objct] |> do_count
    sql = "DELETE FROM $(model.name |> lowercase) WHERE $(join(_where, " OR "))"
  else
    # TODO : this code has not been tested, I need to check if it works    
    pk_field = get_model_pk_field(model) |> string |> lowercase
    _query = model |> object;
    or_object = Qor("$(pk_field)__@in" => keys[1][:objct])
    for (index, key) in enumerate(keys)
      if index == 1
        continue # already added
      end
      push!(or_object, "$(pk_field)__@in" => key[:objct])
    end
    _query.filter(or_object)
    deleted_counter[model.name] = _query |> do_count
    _query.values(pk_field) # Ensure the query is built
    @infiltrate false
    sql = "DELETE FROM $(model.name |> lowercase) WHERE $(pk_field) IN ($(query(_query, parameters=parameters)))"
  end

  sql == "" && throw("Error in delete, the SQL query is empty, this should not happen")
      
  if show_query
    params_list = parameters === nothing ? [] : (hasproperty(parameters, :parameters) ? parameters.parameters : parameters)
    @info "SQL Query" query=sql params=params_list |> string task_id=string(current_task())
    return deleted_counter  # Return count of deleted objects
  end
  @infiltrate false
  result, conn = with_transaction(connection, sql, conn=conn, params=parameters)
  return deleted_counter  # Return count of deleted objects
end

function update_field(connection::PormGPostgres, model::PormGModel, field::String, value::Any, keys::Dict{Symbol, Union{String, SQLObjectHandler}}, show_query::Bool, conn::Union{Nothing, LibPQ.Connection})
  # Update field values using query object like CASCADE
  @infiltrate false
  pk_field = keys[:key]
  _query = keys[:objct]
  parameters = get_parameter(connection)
  value_sql = value === nothing ? "NULL" : model.fields[field].formater(value)
  sql = "UPDATE $(model.name |> lowercase) SET $(field) = $(value_sql) WHERE $(pk_field) IN ($(query(_query, parameters=parameters)))"
  if show_query
    params_list = parameters === nothing ? [] : (hasproperty(parameters, :parameters) ? parameters.parameters : parameters)
    @info "SQL Query" query=sql params=params_list |> string task_id=string(current_task())
    return
  end
  # LibPQ.execute(connection, sql)
  with_transaction(connection, sql, conn=conn, params=parameters)
end