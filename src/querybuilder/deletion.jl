# ---
# Django like function to build a delete query with cascade, restrict, set null, set default and set value (AI please don't delete this code)
#

"""
    delete(objct::SQLObjectHandler; show_query=:execute, allow_delete_all=false) -> (total::Int, Dict{String,Integer})

Delete every row the query matches, cascading through foreign-key relationships according to each
referencing field's `on_delete` action. The root delete and every dependent statement run inside one
transaction, so a failure part-way through leaves the database untouched.

# Arguments
- `objct::SQLObjectHandler`: the handler carrying the query and its model.
- `show_query::Symbol = :execute`: `:execute` runs the delete. `:sql`, `:dict`, `:inspection` and
  `:params` build the statements and return them instead of executing them, and `:none` builds and
  discards them — see [`show_query`](@ref). An unrecognized value raises `QueryBuildError` when the
  statements are rendered, which is *after* the guards below have run.
- `allow_delete_all::Bool = false`: permit a delete whose query carries no filter. Off by default;
  see the guard table below.
- `table_alias::Union{Nothing, SQLTableAlias} = nothing`: accepted for call-signature compatibility
  with the other terminals; the delete path does not read it.
- `connection::Union{Nothing, PormGPostgres, PormGSQLite} = nothing`: execute against this connection
  pool instead of the one on the model's settings (those two abstract types are the backend markers
  the concrete pools subtype). Only the pool is overridden; the settings, and therefore the dialect
  and the `change_data` flag, still come from the model's `connect_key`. Whether the delete joins a
  surrounding transaction is decided by the task-local transaction context, not by this argument.

# Returns
- Under `:execute`: `Tuple{Integer, Dict{String, Integer}}` — the total rows deleted and a per-table
  breakdown, e.g. `(1, Dict("just_a_test_deletion" => 1))`. A query matching nothing returns
  `(0, Dict())`; a delete that ran but removed no rows warns.
- Under `:sql`, `:dict`, `:inspection` or `:params`: the built statement(s) — one per statement the
  plan emits, returned bare when the plan is a single statement and as a `Vector` otherwise. A
  cascade can emit several statements for the same table (one `UPDATE` per `SET_NULL` /
  `SET_DEFAULT` field, plus its `DELETE`), so the count tracks statements, not tables.
- Under `:none`: `nothing`.

# Behavior

Every check below runs before any SQL is generated:

| Guard | Raises |
|-------|--------|
| A transaction is open on a connection other than the model's | `TransactionError` |
| The connection is configured `change_data: false` | [`WritesDisabledError`](@ref) |
| The query has `limit()`, `offset()` or `order_by()` set | [`UnsafeMutationError`](@ref) |
| The query has `distinct()` set | [`UnsafeMutationError`](@ref) |
| The query carries `group_by()` / aggregate annotations | [`UnsafeMutationError`](@ref) |
| The query has no filter and `allow_delete_all` is `false` | [`UnsafeMutationError`](@ref) |

The three query-shape guards share one rationale: the deletion collector walks the *complete*
filtered set so row counts, cascades and constraint handling stay deterministic. Any shape that
truncates or collapses that set is refused rather than quietly applied to part of it — there is no
"delete the first N rows" form, so filter by primary key to bound a delete.

Dependent rows are then resolved per referencing field, by that field's `on_delete`:

- `CASCADE`: the dependents are collected and deleted too, recursing into their own dependents.
- `PROTECT` / `RESTRICT`: raises [`ProtectedError`](@ref), naming the referencing model and field.
  The two behave identically apart from the word in the message. The check is existence-driven — it
  fires only when referencing rows are actually present, so an empty reverse relation does not block
  the delete.
- `SET_NULL`: issues `UPDATE ... SET <column> = NULL` over the dependents instead of deleting them.
  Declaring it on a `null = false` field is a contradiction the schema cannot satisfy, and raises
  [`ModelDefinitionError`](@ref).
- `SET_DEFAULT`: issues `UPDATE ... SET <column> = <the field's default>` over the dependents.
  Declaring it on a field with no `default` is the mirror-image contradiction, and raises
  [`ModelDefinitionError`](@ref) too.
- `DO_NOTHING`: PormG emits nothing for the relation and defers to the database's own constraint.

Only `CASCADE` walks further down the graph; `SET_NULL` and `SET_DEFAULT` do not recurse.

Both contradictions are normally caught earlier, at `set_models` registration; the checks here are the
backstop for models that never passed through it.

An **unset** `on_delete` — the default for `ForeignKey` — produces no ORM statement for that relation,
leaving the reference entirely to the database's own constraint. It renders `ON DELETE NO ACTION` in
DDL, so a dependent row is *not* cascaded by PormG unless its field says so explicitly.

The collected statements then execute in dependency order inside a single transaction (`BEGIN` on
PostgreSQL, `BEGIN IMMEDIATE TRANSACTION` on SQLite), so any failure rolls the whole set back.

# Examples

```julia
# Delete objects from a model with a specific filter
query = M.Status.objects
query.filter("status" => "Engine")
total, dict = delete(query)

# Build the SQL without executing it
query = M.Just_a_test_deletion.objects
query.filter("test_result__constructorid__name" => "Williams")
sql = delete(query, show_query = :sql)

# Delete related tables (cascading delete)
query = M.Result.objects
query.filter("resultid" => 1)
total, dict = delete(query)

# Delete all objects from a model (use with caution)
query = M.Just_a_test_deletion.objects
total, dict = delete(query; allow_delete_all = true)
```

See also [`show_query`](@ref), [`inspect_query`](@ref), and [Deleting Records](write/delete.md).
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
  !settings.change_data && throw(_write_not_allowed("delete", conn_key))

  if objct.object.limit > 0 || objct.object.offset > 0 || !isempty(objct.object.order)
    throw(UnsafeMutationError(
      "Cannot call delete() on a query that has limit(), offset(), or order_by() set. " *
      "The deletion collector operates on complete filtered object sets so counts, cascades, " *
      "and constraint handling stay deterministic. Filter by primary key explicitly to delete " *
      "a bounded set."
    ))
  end

  if objct.object.distinct
    throw(UnsafeMutationError(
      "Cannot call delete() on a query with distinct(). " *
      "DISTINCT collapses the result set, making the deletion collector's " *
      "cascade counting unreliable. Remove distinct() or filter by primary key."
    ))
  end

  if any(v -> isa(v, SQLTypeField) && isa(v.field, Union{SQLTypeFunction, SQLTypeF}) && v.field.aggregate, objct.object.values)
    throw(UnsafeMutationError(
      "Cannot call delete() on a query with group_by() / annotate aggregations. " *
      "GROUP BY collapses rows, making cascade counting and constraint handling " *
      "unreliable. Remove the aggregation or filter by primary key."
    ))
  end

  # don't allow to delete without filter
  if !allow_delete_all && objct.object.filter |> isempty
    throw(UnsafeMutationError(
      "Error in delete, the delete must have a filter. " *
      "To delete every row, pass \e[4m\e[31mallow_delete_all = true\e[0m explicitly, e.g. " *
      "Model.objects.delete(allow_delete_all = true) or delete(query; allow_delete_all = true)."
    ))
  end
  
  # If no objects to delete, return early (unless we're just inspecting the query)
  if show_query === :execute && objct |> !_exists
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
      # Release/renew the connection exactly once in a single terminal finally, so a failed
      # COMMIT never returns it to the pool before the cleanup ROLLBACK has run on it (#139).
      local rollback_error = nothing
      try
        # #276: same deferral as run_in_transaction — PormG's PG foreign keys are DEFERRABLE
        # INITIALLY DEFERRED, so the collector's intermediate states (a child DELETEd before its
        # parent, a SET_NULL applied mid-sweep) are legal there. Defer on SQLite too, or enforcement
        # would reject an ordering PostgreSQL accepts. Resets at COMMIT; no-op on PostgreSQL.
        #
        # INSIDE the try, not between it and the BEGIN: `with_transaction(…, conn=conn)` releases
        # nothing on failure (conn_acquired = false), so a throw in that gap would skip the terminal
        # finally entirely and strand this connection out of the pool holding an open
        # BEGIN IMMEDIATE — i.e. the database write lock. The #139/#71 class.
        connection isa PormGSQLite &&
          with_transaction(settings, "PRAGMA defer_foreign_keys = ON;", conn=conn)
        with_tx_context(settings.connections, conn) do
          run_deletions(conn)
        end
        # Commit — release_conn=false: the finally owns the single release.
        with_transaction(settings, "COMMIT;", conn=conn, release_conn=false)
      catch e
        # Roll back on the still-leased connection. A rollback failure must not mask the body's
        # error — capture it so the finally renews/discards the dirty connection instead of
        # releasing it (#71), then rethrow the original.
        try
          with_transaction(settings, "ROLLBACK;", conn=conn, release_conn=false)
        catch rollback_err
          rollback_error = rollback_err
          @error "Failed to rollback delete transaction" exception=rollback_err
        end
        rethrow(e)
      finally
        finalize_transaction_connection!(settings, conn; rollback_error=rollback_error)
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
    # Preserve the declared case (#57): field_names and column names are case-sensitive,
    # so the delete key must match the field's declared case verbatim.
    return string(pk_field)
  end

  if fallback !== nothing
    # Match the user-supplied fallback verbatim — field lookup is case-sensitive (#57).
    fallback in model.field_names || throw(UnknownFieldError("The fallback delete field $(fallback) was not found in $(model.name)"))
    return fallback
  end

  allow_direct && return DIRECT_DELETE_KEY_SENTINEL

  throw(QueryBuildError("Delete on $(model.name) requires a primary key or an explicit fallback delete field"))
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

  # For models with foreign keys pointing to this model (related_model has FK -> model)
  for (related_name, related_value) in model.related_objects
    # Skip many-to-many reverse accessors — these are handled by the through
    # table's own CASCADE FK on the owner side, not by this loop.
    related_value isa Models.ManyToManyRelation && continue
    # #343: read the resolved child. This used to respell the binding with `capitalize_symbol`,
    # which cannot produce an internal capital, so a cascade through `Dim_CNES` threw UndefVarError.
    # Its django-prefix strip went with it: `get_model_name` strips the prefix at REGISTRATION, so
    # the stored name never carried one and the strip was a guaranteed no-op. The tuple's `pk_field`
    # and `pk_model` slots were destructured here and never read — both are gone with the tuple.
    rel = related_value::Models.ReverseRelation
    field_name = rel.fk_field
    related_model = rel.model_resolved

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
    should_check_existence && (_query |> !_exists) && continue
     
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
    throw(ProtectedError("Cannot delete \e[4m\e[31m$(model.name)\e[0m because it is referenced by \e[4m\e[31m$(related_model.name).$(field_name)\e[0m with ON DELETE \e[4m\e[31m$(constraint_type)\e[0m constraint"))
  elseif field.on_delete == SET_NULL
    @pormg_debug false
    # Backstop copy of `set_models`' SET_NULL guard, for models that never passed registration —
    # see the fixtures in test/integration/common_delete_setup.jl, which register a VALID model and
    # then flip the field, so this path is the only thing left to catch it.
    #
    # This one stays PER-FIELD and IMMEDIATE. Do NOT "unify" it with the aggregating collector
    # `set_models` grew in #303. There, N models are being registered at once and reporting all N
    # contradictions in one error saves N import cycles — the whole point. Here we are inside one
    # delete, resolving one referencing field, with nothing to aggregate: deferring the throw would
    # only let the collector keep building statements against a schema already known to be
    # unsatisfiable, and then report them alongside an error we could have raised immediately.
    # Fail on the field in hand.
    if !field.null
      throw(ModelDefinitionError("Error in delete: ON DELETE SET_NULL is declared on \e[4m\e[31m$(field_name)\e[0m, but the field has null=false — the schema contradicts itself. Declare the FK with null=true or use a different on_delete."))
    end

    # Add field update to set field to NULL
    if !haskey(collector.field_updates, (field_name |> string, nothing))
      @pormg_debug false
      collector.field_updates[(field_name |> string, nothing)] = Dict{PormGModel, Dict{Symbol, Union{String, SQLObjectHandler}}}()
    end
    
    # Add to field updates using _query object like CASCADE
    collector.field_updates[(field_name |> string, nothing)][related_model] = prepare_related_query(keys, related_model, field_name)

  elseif field.on_delete == SET_DEFAULT
    # check that there is a default to set — symmetric with the SET_NULL guard above (#287), and
    # per-field/immediate for the same reason spelled out there (#303).
    # Without it `field.default === nothing` flows into update_field, which renders a bare NULL,
    # so SET_DEFAULT silently behaved as SET_NULL and then died on the column's NOT NULL constraint.
    if field.default === nothing
      throw(ModelDefinitionError("Error in delete: ON DELETE SET_DEFAULT is declared on \e[4m\e[31m$(field_name)\e[0m, but the field has no default — the schema contradicts itself. Give the FK a default= or use a different on_delete."))
    end

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
      throw(QueryBuildError("Circular dependency detected in model relationships"))
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
    isempty(objct.object.filter) || throw(QueryBuildError("Delete on keyless model $(model.name) with filters is not supported; define a primary key or delete all rows explicitly"))

    deleted_counter[model.name] = show_query === :execute ? (objct |> _count) : 0
    sql = "DELETE FROM $(safe_table_identifier(Models.model_table_name(model), connection))"

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
    # Outer WHERE targets the physical column (db_column when set); the subquery already
    # projects/aliases the key, so only this identifier needs resolving (#50).
    push!(_where, """"$(Models.model_column(model, pk_field))" IN ($(query(key[:objct], parameters=parameters)))""")
  end
  sql::String = ""
  if size(keys, 1) == 1
    deleted_counter[model.name] = show_query === :execute ? (keys[1][:objct] |> _count) : 0
    sql = "DELETE FROM $(safe_table_identifier(Models.model_table_name(model), connection)) WHERE $(join(_where, " OR "))"
  else
    # Multi-path merge: all entries for the same model share the same resolved key field.
    # Keyless (sentinel) models reaching this path are not supported.
    pk_field = keys[1][:key]
    pk_field == DIRECT_DELETE_KEY_SENTINEL && throw(QueryBuildError("Multi-path delete on keyless model $(model.name) is not supported; define a primary key"))
    _query = model |> object;
    or_object = Qor("$(pk_field)__@in" => keys[1][:objct])
    for (index, key) in enumerate(keys)
      if index == 1
        continue # already added
      end
      push!(or_object, "$(pk_field)__@in" => key[:objct])
    end
    _query.filter(or_object)
    deleted_counter[model.name] = show_query === :execute ? (_query |> _count) : 0
    _query.values(pk_field) # Ensure the query is built
    @pormg_debug false
    sql = "DELETE FROM $(safe_table_identifier(Models.model_table_name(model), connection)) WHERE \"$(Models.model_column(model, pk_field))\" IN ($(query(_query, parameters=parameters)))"
  end

  sql == "" && error(_emsg("PormG internal error in delete(): the generated SQL is empty — this should not happen; please report it."))
      
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
  pk_field == DIRECT_DELETE_KEY_SENTINEL && throw(QueryBuildError("Cannot update field on keyless model $(model.name); define a primary key"))
  _query = keys[:objct]
  parameters = get_parameter(connection)
  value_sql = value === nothing ? "NULL" : model.fields[field].formatter(value)
  # SET column and outer WHERE key both target the physical column (db_column) — #50.
  sql = "UPDATE $(safe_table_identifier(Models.model_table_name(model), connection)) SET \"$(Models.model_column(model, field))\" = $(value_sql) WHERE \"$(Models.model_column(model, pk_field))\" IN ($(query(_query, parameters=parameters)))"
  if show_query !== :execute
    return _show_query_result(show_query, sql, connection, model, :update, parameters=parameters)
  end
  # LibPQ.execute(connection, sql)
  with_transaction(connection, sql, conn=conn, params=parameters)
end
