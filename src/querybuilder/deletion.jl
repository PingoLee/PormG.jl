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
total, dict = delete(query, show_query = :sql)

# Delete related tables (cascading delete)
query = M.Result |> object
query.filter("resultid" => 1)
total, dict = delete(query)

# Delete all objects from a model (use with caution)
query = M.Just_a_test_deletion |> object
total, dict = delete(query; allow_delete_all = true)


```
"""
function delete(objct::SQLObjectHandler; 
    table_alias::Union{Nothing, SQLTableAlias} = nothing, 
    connection::Union{Nothing, PormGPostgres, PormGSQLite} = nothing, 
    show_query::Symbol = :execute,
    allow_delete_all::Bool = false)
  model = objct.object.model
  ensure_model_transaction_scope(model)
  
  # Resolve settings
  settings, connection, conn_key = get_settings(objct, connection=connection)
    
  # check if is allowed to delete
  !settings.change_data && throw(_argerr("Error in delete, the connection \e[4m\e[31m$conn_key\e[0m not allowed to delete"))

  if objct.object.limit > 0 || objct.object.offset > 0 || !isempty(objct.object.order)
    throw(ArgumentError(
      "Cannot call delete() on a query that has limit(), offset(), or order_by() set. " *
      "The deletion collector operates on complete filtered object sets so counts, cascades, " *
      "and constraint handling stay deterministic. Filter by primary key explicitly to delete " *
      "a bounded set."
    ))
  end

  if objct.object.distinct
    throw(ArgumentError(
      "Cannot call delete() on a query with distinct(). " *
      "DISTINCT collapses the result set, making the deletion collector's " *
      "cascade counting unreliable. Remove distinct() or filter by primary key."
    ))
  end

  if any(v -> isa(v, SQLTypeField) && isa(v.field, Union{SQLTypeFunction, SQLTypeF}) && v.field.agregate, objct.object.values)
    throw(ArgumentError(
      "Cannot call delete() on a query with group_by() / annotate aggregations. " *
      "GROUP BY collapses rows, making cascade counting and constraint handling " *
      "unreliable. Remove the aggregation or filter by primary key."
    ))
  end

  # don't allow to delete without filter
  if !allow_delete_all && objct.object.filter |> isempty
    throw(_argerr(
      "Error in delete, the delete must have a filter. " *
      "To delete every row, pass \e[4m\e[31mallow_delete_all = true\e[0m explicitly, e.g. " *
      "Model.objects.delete(allow_delete_all = true) or delete(query; allow_delete_all = true)."
    ))
  end
  
  # If no objects to delete, return early (unless we're just inspecting the query)
  if show_query === :execute && objct |> !do_exists
    return 0, Dict{String, Integer}()
  end

  # We'll track deletion counts
  deleted_counter = Dict{String, Integer}()
  
  # Collect related models that need special handling
  collector = DeletionCollector(model, settings, show_query)
  
  # Add the primary objects to delete
  add_objects_to_collector!(collector, objct |> deepcopy, model)
  
  # Build and sort the deletion graph
  process_collector!(collector)

  # Definition of run_deletions (backend agnostic)
  results = []
  run_deletions = function(conn)
    # Process fast deletes first (objects that can be deleted directly)
    for (model, keys) in collector.fast_deletes
      res = delete_objects(connection, model, keys, show_query, deleted_counter, conn)
      push!(results, res)
      # Remove from objects to prevent double deletion
      delete!(collector.objects, model)
    end

    # Process field updates (for SET_NULL, SET_DEFAULT, etc.)
    for ((field, value), affected_models) in collector.field_updates
      for (affected_model, keys) in affected_models
        res = update_field(connection, affected_model, field, value, keys, show_query, conn)
        push!(results, res)
      end
    end
    
    # Execute deletions in the sorted order
    for model_to_delete in collector.sorted_models
      _array = get(collector.objects, model_to_delete, [])        
      if !isempty(_array)
        res = delete_objects(connection, model_to_delete, _array, show_query, deleted_counter, conn)
        push!(results, res)
      end
    end
  end

  tx_conn = transaction_connection_for(settings)
  if show_query !== :execute
    run_deletions(nothing)
  elseif tx_conn !== nothing
    run_deletions(tx_conn)
  else
    # Start transaction (backend specific SQL)
    begin_sql = if connection isa PormGPostgres
        "BEGIN;"
    else
        # Use BEGIN IMMEDIATE for SQLite to prevent deadlocks
        "BEGIN IMMEDIATE TRANSACTION;"
    end
    # Serialize SQLite writers around the whole BEGIN..COMMIT, matching
    # run_in_transaction, so a concurrent delete/create never races on
    # `BEGIN IMMEDIATE` (which would deadlock the single async worker). No-op on
    # PostgreSQL. See ConnectionPool.with_sqlite_write_lock.
    with_sqlite_write_lock(settings) do
      _, conn = with_transaction(settings, begin_sql)
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
  end

  if show_query !== :execute
    return length(results) == 1 ? results[1] : results
  end

  total_deleted = sum(values(deleted_counter))
  if total_deleted == 0
    @warn("Warning in delete, no objects were deleted")  
  end
  
  return total_deleted, deleted_counter
end
delete(; kwargs...) = (objct) -> delete(objct; kwargs...)

# Sentinel returned by resolve_delete_key when a keyless model should be deleted directly
# (bare DELETE FROM table, no WHERE clause). Chosen to be an impossible SQL identifier so
# accidental equality checks against real column names always fail.
const DIRECT_DELETE_KEY_SENTINEL = "__pormg_direct_delete__"

function resolve_delete_key(model::PormGModel; fallback::Union{Nothing,String}=nothing, allow_direct::Bool=false)
  pk_field = get_model_pk_field(model)
  if pk_field !== nothing
    return string(pk_field) |> lowercase
  end

  if fallback !== nothing
    fallback = lowercase(fallback)
    fallback in model.field_names || throw(ArgumentError("The fallback delete field $(fallback) was not found in $(model.name)"))
    return fallback
  end

  allow_direct && return DIRECT_DELETE_KEY_SENTINEL

  throw(ArgumentError("Delete on $(model.name) requires a primary key or an explicit fallback delete field"))
end

# Shared helper: resolves the delete key for a related model and returns a properly filtered
# copy of the parent query so all three on_delete branches (CASCADE, SET_NULL, SET_DEFAULT) stay in sync.
function prepare_related_query(keys::Dict{Symbol, Union{String, SQLObjectHandler}}, related_model::PormGModel, field_name::Union{String, Symbol})
  delete_key = resolve_delete_key(related_model; fallback=string(field_name))
  _query = deepcopy(keys[:objct])
  delete_key != DIRECT_DELETE_KEY_SENTINEL && _query.values(delete_key)
  return Dict{Symbol, Union{String, SQLObjectHandler}}(:key => delete_key, :objct => _query)
end

function add_objects_to_collector!(collector::DeletionCollector, objct::SQLObjectHandler, model::PormGModel)
  # Extract IDs from objects - handle NamedTuples or Dict structures
  @pormg_debug false
  delete_key = resolve_delete_key(model; allow_direct=isempty(objct.object.filter))
  delete_key != DIRECT_DELETE_KEY_SENTINEL && objct.values(delete_key)
  add_objects_to_collector!(collector, model, delete_key, objct)
end


function add_objects_to_collector!(collector::DeletionCollector, model::PormGModel, key::String, objct::SQLObjectHandler)
  # Add to collector
  # @info objct |> query
  @pormg_debug false
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

function should_check_related_existence(collector::DeletionCollector)::Bool
  pool = collector.settings.connections
  connection_pool = getfield(parentmodule(@__MODULE__), :ConnectionPool)
  return pool isa connection_pool.PostgresConnectionPool || pool isa connection_pool.SQLiteConnectionPool
end

function find_related_objects!(collector::DeletionCollector, model::PormGModel, dict::Vector{Dict{Symbol, Union{String, SQLObjectHandler}}})
  # For each foreign key in the model (model has FK -> related_model)
  @pormg_debug false
  _django = collector.settings.django_prefix === nothing ? false : true
    
  # For models with foreign keys pointing to this model (related_model has FK -> model)
  for (related_name, related_value) in model.related_objects
    # Skip many-to-many reverse accessors — these are handled by the through
    # table's own CASCADE FK on the owner side, not by this loop.
    related_value isa Models.ManyToManyRelation && continue
    field_name, pk_field, related_model_name, pk_model = related_value
    _django && (related_model_name = replace(string(related_model_name), collector.settings.django_prefix * "_" => "") |> Symbol)
    related_model = getfield(model._module, related_model_name |> capitalize_symbol);

    _query = related_model |> object;
    if size(dict, 1) == 1
      _query.filter("$(field_name)__@in" => dict[1][:objct]);
    else
      or_object = Qor("$(field_name)__@in" => dict[1][:objct])
      for (index, dict_) in enumerate(dict)
        if index == 1
          continue # already added via Qor constructor
        end
        push!(or_object, "$(field_name)__@in" => dict_[:objct])
      end
      _query.filter(or_object)
    end
    
    @pormg_debug false
    # For live pools, inspection should still reflect actual reverse-row presence so
    # PROTECT/RESTRICT do not raise false positives. Mock/unit-test connections keep
    # the previous behavior and assume related rows exist because no database is available.
    should_check_existence = collector.show_query === :execute || should_check_related_existence(collector)
    should_check_existence && (_query |> !do_exists) && continue
     
    # @info _query |> query

    # THE ORDER IS correctly set?
    if !haskey(collector.dependencies, related_model)
      collector.dependencies[related_model] = Set{PormGModel}()
    end  
    push!(collector.dependencies[related_model], model)

    _keys = Dict{Symbol, Union{String, SQLObjectHandler}}(
      :key => resolve_delete_key(related_model; fallback=string(field_name)),
      :objct => _query
    )

    field = related_model.fields[String(field_name)]
    handle_on_delete!(collector, field_name, field, model, _keys, related_model)

  end
end

function handle_on_delete!(collector::DeletionCollector, field_name::Union{String, Symbol}, field::PormGField, model::PormGModel, 
  keys::Dict{Symbol, Union{String, SQLObjectHandler}}, related_model::PormGModel)
  @pormg_debug false
  if field.on_delete == CASCADE
    @pormg_debug false
    _keys = prepare_related_query(keys, related_model, field_name)
    add_objects_to_collector!(collector, related_model, _keys[:key], _keys[:objct])
    @pormg_debug false
    find_related_objects!(collector, related_model, [_keys]) # Recursively find related objects for the related model
  elseif field.on_delete in [PROTECT, RESTRICT]    
    # More descriptive error with field name, constraint type, and sample IDs
    constraint_type = field.on_delete == PROTECT ? "PROTECT" : "RESTRICT"
    throw(_argerr("Cannot delete \e[4m\e[31m$(model.name)\e[0m because it is referenced by \e[4m\e[31m$(related_model.name).$(field_name)\e[0m with ON DELETE \e[4m\e[31m$(constraint_type)\e[0m constraint"))
  elseif field.on_delete == SET_NULL
    # TODO : I dont check if this works
    @pormg_debug false
    # check if the field allow null
    if !field.null
      throw(_argerr("Error in delete, the field \e[4m\e[31m$(field_name)\e[0m not allow null"))
    end

    # Add field update to set field to NULL
    if !haskey(collector.field_updates, (field_name |> string, nothing))
      @pormg_debug false
      collector.field_updates[(field_name |> string, nothing)] = Dict{PormGModel, Dict{Symbol, Union{String, SQLObjectHandler}}}()
    end
    
    # Add to field updates using _query object like CASCADE
    collector.field_updates[(field_name |> string, nothing)][related_model] = prepare_related_query(keys, related_model, field_name)

  elseif field.on_delete == SET_DEFAULT
    # TODO : I dont check if this works
    # Add field update to set field to default value
    default_value = field.default
    if !haskey(collector.field_updates, (field_name |> string, default_value))
      collector.field_updates[(field_name |> string, default_value)] = Dict{PormGModel, Dict{Symbol, Union{String, SQLObjectHandler}}}()
    end    
    
    # Add to field updates using _query object like CASCADE
    collector.field_updates[(field_name |> string, default_value)][related_model] = prepare_related_query(keys, related_model, field_name)
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
      @pormg_debug false
      collector.fast_deletes[model] = keys
    end
  end
end

function delete_objects(connection::Union{PormGPostgres, PormGSQLite}, model::PormGModel, keys::Vector{Dict{Symbol, Union{String, SQLObjectHandler}}},
   show_query::Symbol, deleted_counter::Dict{String, Integer}, conn)
  @pormg_debug false
  if size(keys, 1) == 1 && keys[1][:key] == DIRECT_DELETE_KEY_SENTINEL
    objct = keys[1][:objct]
    isempty(objct.object.filter) || throw(ArgumentError("Delete on keyless model $(model.name) with filters is not supported; define a primary key or delete all rows explicitly"))

    deleted_counter[model.name] = show_query === :execute ? (objct |> do_count) : 0
    sql = "DELETE FROM $(model.name |> lowercase)"

    if show_query !== :execute
      return _show_query_result(show_query, sql, connection, model, :delete, parameters=nothing)
    end

    with_transaction(connection, sql, conn=conn, params=nothing)
    return deleted_counter
  end

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
    deleted_counter[model.name] = show_query === :execute ? (keys[1][:objct] |> do_count) : 0
    sql = "DELETE FROM $(model.name |> lowercase) WHERE $(join(_where, " OR "))"
  else
    # Multi-path merge: all entries for the same model share the same resolved key field.
    # Keyless (sentinel) models reaching this path are not supported.
    pk_field = keys[1][:key]
    pk_field == DIRECT_DELETE_KEY_SENTINEL && throw(ArgumentError("Multi-path delete on keyless model $(model.name) is not supported; define a primary key"))
    _query = model |> object;
    or_object = Qor("$(pk_field)__@in" => keys[1][:objct])
    for (index, key) in enumerate(keys)
      if index == 1
        continue # already added
      end
      push!(or_object, "$(pk_field)__@in" => key[:objct])
    end
    _query.filter(or_object)
    deleted_counter[model.name] = show_query === :execute ? (_query |> do_count) : 0
    _query.values(pk_field) # Ensure the query is built
    @pormg_debug false
    sql = "DELETE FROM $(model.name |> lowercase) WHERE \"$(pk_field)\" IN ($(query(_query, parameters=parameters)))"
  end

  sql == "" && throw("Error in delete, the SQL query is empty, this should not happen")
      
  if show_query !== :execute
    return _show_query_result(show_query, sql, connection, model, :delete, parameters=parameters)
  end
  @pormg_debug false
  result, conn = with_transaction(connection, sql, conn=conn, params=parameters)
  return deleted_counter  # Return count of deleted objects
end

function update_field(connection::Union{PormGPostgres, PormGSQLite}, model::PormGModel, field::String, value::Any, keys::Dict{Symbol, Union{String, SQLObjectHandler}}, show_query::Symbol, conn)
  # Update field values using query object like CASCADE
  @pormg_debug false
  pk_field = keys[:key]
  pk_field == DIRECT_DELETE_KEY_SENTINEL && throw(ArgumentError("Cannot update field on keyless model $(model.name); define a primary key"))
  _query = keys[:objct]
  parameters = get_parameter(connection)
  value_sql = value === nothing ? "NULL" : model.fields[field].formater(value)
  sql = "UPDATE $(model.name |> lowercase) SET \"$(field)\" = $(value_sql) WHERE \"$(pk_field)\" IN ($(query(_query, parameters=parameters)))"
  if show_query !== :execute
    return _show_query_result(show_query, sql, connection, model, :update, parameters=parameters)
  end
  # LibPQ.execute(connection, sql)
  with_transaction(connection, sql, conn=conn, params=parameters)
end