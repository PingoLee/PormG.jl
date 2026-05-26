struct ManyToManyDescriptor
  owner_model::PormGModel
  accessor::String
  relation::Models.ManyToManyRelation
end

struct ManyToManyManager
  owner_model::PormGModel
  related_model::PormGModel
  relation::Models.ManyToManyRelation
  owner_id::Any
end

function _m2m_model_from_binding(_module::Module, binding::String, table_name::String)::PormGModel
  binding_symbol = Symbol(binding)
  if isdefined(_module, binding_symbol)
    candidate = Base.invokelatest(getfield, _module, binding_symbol)
    candidate isa PormGModel && return candidate
  end

  target_name = Models.format_model_name(table_name)
  for model in Models.get_all_models(_module)
    Models.format_model_name(model.name) == target_name && return model
  end

  throw(ArgumentError("The many-to-many related model $(binding) is not defined"))
end

function _m2m_extract_pk(value, pk_field::String)
  if value isa PormGRow
    return value[pk_field]
  end
  if value isa AbstractDict
    haskey(value, Symbol(pk_field)) && return value[Symbol(pk_field)]
    haskey(value, pk_field) && return value[pk_field]
  elseif value isa NamedTuple
    pk_symbol = Symbol(pk_field)
    pk_symbol in keys(value) && return getfield(value, pk_symbol)
  end
  return value
end

function _m2m_items(values)
  if length(values) == 1 && values[1] isa AbstractVector
    return collect(values[1])
  end
  return collect(values)
end

function _m2m_settings(manager::ManyToManyManager)
  conn_key = manager.owner_model.connect_key
  if conn_key === nothing
    if length(config) == 1
      conn_key = first(keys(config))
    else
      throw(ArgumentError("Model '$(manager.owner_model.name)' is not bound to a database connection key. Call set_models() before using a many-to-many manager."))
    end
  end
  settings = get_configuration_settings(conn_key)
  return settings, settings.connections, conn_key
end

function _m2m_format_owner(manager::ManyToManyManager)
  return manager.owner_model.fields[manager.relation.owner_pk].formater(manager.owner_id)
end

function _m2m_format_related(manager::ManyToManyManager, related_id)
  return manager.related_model.fields[manager.relation.related_pk].formater(related_id)
end

function _m2m_target_ids(manager::ManyToManyManager, targets)::Vector{Any}
  ids = Any[]
  for target in _m2m_items(targets)
    push!(ids, _m2m_format_related(manager, _m2m_extract_pk(target, manager.relation.related_pk)))
  end
  return ids
end

function _m2m_has_extra_fields(manager::ManyToManyManager)::Bool
  owner_module = manager.owner_model._module
  owner_module === nothing && return false

  # Only catch ArgumentError ("binding not found") — the expected failure when
  # the through model is auto-generated and not registered in the module.
  # Any other exception (type error, module error, etc.) should propagate so
  # the caller is not silently allowed to mutate a through table with extra fields.
  through_model = try
    _m2m_model_from_binding(owner_module, manager.relation.through_model, manager.relation.through_model)
  catch e
    e isa ArgumentError && return false
    rethrow(e)
  end

  owner_col = manager.relation.owner_column
  related_col = manager.relation.related_column

  for field_name in keys(through_model.fields)
    clean_name = strip(field_name, '"')
    if clean_name != "id" && clean_name != owner_col && clean_name != related_col
      return true
    end
  end
  return false
end

function (descriptor::ManyToManyDescriptor)(owner)
  owner_id = _m2m_extract_pk(owner, descriptor.relation.owner_pk)
  owner_module = descriptor.owner_model._module
  owner_module === nothing && throw(ArgumentError("Many-to-many descriptor $(descriptor.accessor) requires initialized models. Call set_models() before using it."))
  related_model = _m2m_model_from_binding(owner_module, descriptor.relation.related_binding, descriptor.relation.related_model)
  return ManyToManyManager(descriptor.owner_model, related_model, descriptor.relation, owner_id)
end

function _m2m_query(manager::ManyToManyManager)
  q = object(manager.related_model)
  q.object.connect_key = manager.owner_model.connect_key
  q.filter("$(manager.relation.inverse_accessor)__$(manager.relation.owner_pk)" => manager.owner_id)
  q.values("*")
  return q
end

function add!(manager::ManyToManyManager, targets...)
  _m2m_has_extra_fields(manager) && throw(ArgumentError("Cannot use direct many-to-many manager mutators (add!, remove!, clear!, set!) on relationship with a custom through model that has extra fields. Create/delete through model objects directly instead."))
  target_ids = _m2m_target_ids(manager, targets)
  isempty(target_ids) && return nothing

  settings, connection, conn_key = _m2m_settings(manager)
  !settings.change_data && throw(ArgumentError("Error in many-to-many add!, the connection \e[4m\e[31m$conn_key\e[0m is not allowed to insert"))

  table_name = safe_table_identifier(manager.relation.through_model, connection)
  owner_column = quote_identifier(manager.relation.owner_column, connection)
  related_column = quote_identifier(manager.relation.related_column, connection)
  owner_value = _m2m_format_owner(manager)

  if connection isa PormGPostgres
    # Use INSERT ... SELECT ... WHERE NOT EXISTS for idempotent inserts.
    # This works regardless of whether a unique constraint exists on the
    # through table (auto-generated through tables have one; explicit
    # through models typically do not).
    # Since Postgres/LibPQ parameterized queries do not allow multiple statements
    # in a single query execution, we execute them one by one.
    for target_id in target_ids
      parameters = get_parameter(connection)
      set_context!(parameters, :select)
      owner_ph = add_parameter!(parameters, owner_value)
      target_ph = add_parameter!(parameters, target_id)
      owner_ph2 = add_parameter!(parameters, owner_value)
      target_ph2 = add_parameter!(parameters, target_id)
      sql = "INSERT INTO $table_name ($owner_column, $related_column) " *
            "SELECT $owner_ph, $target_ph " *
            "WHERE NOT EXISTS (" *
              "SELECT 1 FROM $table_name WHERE $owner_column = $owner_ph2 AND $related_column = $target_ph2" *
            ");"
      fetch(settings, sql, parameters)
    end
  elseif connection isa PormGSQLite
    parameters = get_parameter(connection)
    set_context!(parameters, :select)
    groups = String[]
    for target_id in target_ids
      owner_placeholder = add_parameter!(parameters, owner_value)
      target_placeholder = add_parameter!(parameters, target_id)
      push!(groups, "($owner_placeholder, $target_placeholder)")
    end
    sql = "INSERT OR IGNORE INTO $table_name ($owner_column, $related_column) VALUES $(join(groups, ", "));"
    fetch(settings, sql, parameters)
  else
    throw(ArgumentError("Unsupported connection type $(typeof(connection)) for many-to-many add!"))
  end

  return nothing
end

function remove!(manager::ManyToManyManager, targets...)
  _m2m_has_extra_fields(manager) && throw(ArgumentError("Cannot use direct many-to-many manager mutators (add!, remove!, clear!, set!) on relationship with a custom through model that has extra fields. Create/delete through model objects directly instead."))
  target_ids = _m2m_target_ids(manager, targets)
  isempty(target_ids) && return nothing

  settings, connection, conn_key = _m2m_settings(manager)
  !settings.change_data && throw(ArgumentError("Error in many-to-many remove!, the connection \e[4m\e[31m$conn_key\e[0m is not allowed to delete"))

  table_name = safe_table_identifier(manager.relation.through_model, connection)
  owner_column = quote_identifier(manager.relation.owner_column, connection)
  related_column = quote_identifier(manager.relation.related_column, connection)
  owner_value = _m2m_format_owner(manager)

  parameters = get_parameter(connection)
  set_context!(parameters, :where)
  owner_placeholder = add_parameter!(parameters, owner_value)
  
  target_placeholders = String[]
  for target_id in target_ids
    push!(target_placeholders, add_parameter!(parameters, target_id))
  end

  sql = "DELETE FROM $table_name WHERE $owner_column = $owner_placeholder AND $related_column IN ($(join(target_placeholders, ", ")));"
  fetch(settings, sql, parameters)

  return nothing
end

function clear!(manager::ManyToManyManager)
  _m2m_has_extra_fields(manager) && throw(ArgumentError("Cannot use direct many-to-many manager mutators (add!, remove!, clear!, set!) on relationship with a custom through model that has extra fields. Create/delete through model objects directly instead."))
  settings, connection, conn_key = _m2m_settings(manager)
  !settings.change_data && throw(ArgumentError("Error in many-to-many clear!, the connection \e[4m\e[31m$conn_key\e[0m is not allowed to delete"))

  parameters = get_parameter(connection)
  set_context!(parameters, :where)
  owner_placeholder = add_parameter!(parameters, _m2m_format_owner(manager))
  table_name = safe_table_identifier(manager.relation.through_model, connection)
  owner_column = quote_identifier(manager.relation.owner_column, connection)
  fetch(settings, "DELETE FROM $table_name WHERE $owner_column = $owner_placeholder;", parameters)
  return nothing
end

function _m2m_current_ids(manager::ManyToManyManager)::Vector{Any}
  settings, connection, _ = _m2m_settings(manager)
  parameters = get_parameter(connection)
  set_context!(parameters, :where)
  owner_placeholder = add_parameter!(parameters, _m2m_format_owner(manager))
  table_name = safe_table_identifier(manager.relation.through_model, connection)
  owner_column = quote_identifier(manager.relation.owner_column, connection)
  related_column = quote_identifier(manager.relation.related_column, connection)
  sql = "SELECT $related_column FROM $table_name WHERE $owner_column = $owner_placeholder;"
  df = fetch(settings, sql, parameters) |> DataFrames.DataFrame
  DataFrames.nrow(df) == 0 && return Any[]
  return Any[row[Symbol(manager.relation.related_column)] for row in DataFrames.eachrow(df)]
end

function set!(manager::ManyToManyManager, targets...)
  _m2m_has_extra_fields(manager) && throw(ArgumentError("Cannot use direct many-to-many manager mutators (add!, remove!, clear!, set!) on relationship with a custom through model that has extra fields. Create/delete through model objects directly instead."))
  desired_ids = Set(_m2m_target_ids(manager, targets))
  settings, _, _ = _m2m_settings(manager)

  return run_in_transaction(settings) do
    current_ids = Set(_m2m_current_ids(manager))
    to_remove = collect(setdiff(current_ids, desired_ids))
    to_add = collect(setdiff(desired_ids, current_ids))

    !isempty(to_remove) && remove!(manager, to_remove)
    !isempty(to_add) && add!(manager, to_add)
    return (added=length(to_add), removed=length(to_remove))
  end
end

function Base.getproperty(manager::ManyToManyManager, sym::Symbol)
  if sym === :all
    return () -> _m2m_query(manager)
  elseif sym === :add!
    return (targets...) -> add!(manager, targets...)
  elseif sym === :remove!
    return (targets...) -> remove!(manager, targets...)
  elseif sym === :clear!
    return () -> clear!(manager)
  elseif sym === :set!
    return (targets...) -> set!(manager, targets...)
  else
    return getfield(manager, sym)
  end
end