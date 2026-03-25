"""
  get_select_query(object::SQLObject, instruc::SQLInstruction)

  Iterates over the values of the object and generates the SELECT query for the given SQLInstruction object.

  #### ALERT
  - This internal function is called by the `build` function.

  #### Arguments
  - `object::SQLObject`: The object containing the values to be selected.
  - `instruc::SQLInstruction`: The SQLInstruction object to which the SELECT query will be added.
"""
function get_select_query(values::Vector{Union{SQLTypeText,SQLTypeField}}, instruc::SQLInstruction)
  for i in eachindex(values) # linear indexing
    v_copy = deepcopy(values[i])

    # SQLText (from Value(x)) is a literal value, not a column reference.
    # Handle it separately: parameterize via _get_select_query(::SQLText) 
    # and use custom_as as the alias.
    if isa(v_copy, SQLTypeText)
      resolved = _get_select_query(v_copy, instruc)
      # Wrap into an SQLField for consistent SELECT rendering
      alias = v_copy.custom_as !== nothing ? v_copy.custom_as : v_copy._as
      instruc.select[i] = SQLField(resolved, alias)
      if alias !== nothing
        instruc.cache[alias] = instruc.select[i]
      end
      continue
    end

    if isa(v_copy.field, Union{SQLTypeFunction, SQLTypeF})
      if v_copy.field.agregate == false
        push!(instruc.group, i |> string)
      else
        instruc.agregate = true
      end
    else
      push!(instruc.group, i |> string)
    end

    if haskey(instruc.cache, v_copy._as)
      instruc.select[i] = instruc.cache[v_copy._as]  # TODO That is necessary in get_select_query    
    else
      @pormg_debug false
      v_copy.field = _get_select_query(v_copy.field, instruc, _as=v_copy._as)
      instruc.select[i] = v_copy
      if v_copy._as === nothing
        throw(ArgumentError("Field requires an alias: \e[4m\e[31m$(v_copy.field)\e[0m must have a name using the format \e[4m\e[32m\"field_name\" => $(v_copy.field)\e[0m or use \e[4m\e[32mSQLField($(v_copy.field), \"alias_name\")\e[0m"))
      end
      instruc.cache[v_copy._as] = instruc.select[i]
    end
  end
end

function get_order_query(object::SQLObject, instruc::SQLInstruction)
  for v in object.order
    found_in_select = false
    v_field_copy = deepcopy(v.field)

    # Check if the ORDER BY target matches a selected alias. Only those aliases can be
    # referenced directly in ORDER BY. Cached join paths created while resolving CTE join_field
    # entries must reuse their resolved SQL selector instead of quoting the raw lookup string.
    for value in object.values
      if isa(value, SQLTypeFunction) && value.field.agregate == true
        continue
      end

      selected_alias = value.custom_as !== nothing ? value.custom_as : value._as
      if selected_alias == v_field_copy._as
        found_in_select = true
        break
      end
    end

    if haskey(instruc.cache, v_field_copy._as)
      if found_in_select
        # Use the alias name instead of the expression to avoid double parameterization.
        # Most databases (PG, SQLite, MySQL) support aliases in ORDER BY.
        v_field_copy.field = quote_identifier(v_field_copy._as, instruc.connection)
      else
        v_field_copy.field = instruc.cache[v_field_copy._as].field
      end
    else
      v_field_copy.field = _get_select_query(v_field_copy.field, instruc)
    end
    push!(instruc.order, string(v_field_copy.field, " ", v.orientation))
    instruc.cache[v_field_copy._as] = v_field_copy

    if !found_in_select
      push!(instruc.group, v_field_copy.field)
    end

  end
  return nothing
end

function _sqlite_preserve_native_parameter(raw_value, formatted_value, instruc::SQLInstruction)
  if instruc.connection isa PormGSQLite && raw_value isa Union{Number,Bool}
    return raw_value
  end
  return formatted_value
end

function _resolve_having_filter_value(alias::String, raw_value, instruc::SQLInstruction)
  if haskey(instruc.tab_field_cache, alias)
    formatted_value = instruc.tab_field_cache[alias].formater(raw_value)
    return _sqlite_preserve_native_parameter(raw_value, formatted_value, instruc)
  end

  for selected_value in instruc.object.values
    selected_alias = selected_value.custom_as !== nothing ? selected_value.custom_as : selected_value._as
    selected_alias == alias || continue

    if isa(selected_value, SQLTypeField) && isa(selected_value.field, SQLTypeFunction)
      sql_function = selected_value.field

      if sql_function.formater !== nothing
        formatted_value = sql_function.formater(raw_value)
        return _sqlite_preserve_native_parameter(raw_value, formatted_value, instruc)
      elseif sql_function.function_name == "AVG"
        formatted_value = Models.format_number_sql(raw_value)
        return _sqlite_preserve_native_parameter(raw_value, formatted_value, instruc)
      elseif haskey(PormGTypeField, sql_function.function_name)
        formatted_value = getfield(Models, PormGTypeField[sql_function.function_name])(raw_value)
        return _sqlite_preserve_native_parameter(raw_value, formatted_value, instruc)
      elseif sql_function.function_name in ["SUM", "COUNT"]
        formatted_value = Models.format_number_sql(raw_value)
        return _sqlite_preserve_native_parameter(raw_value, formatted_value, instruc)
      elseif sql_function.function_name in ["MAX", "MIN"] && sql_function.column isa String && haskey(instruc.object.model.fields, sql_function.column)
        formatted_value = instruc.object.model.fields[sql_function.column].formater(raw_value)
        return _sqlite_preserve_native_parameter(raw_value, formatted_value, instruc)
      end
    end
  end

  formatted_value = IntegerField().formater(raw_value)
  return _sqlite_preserve_native_parameter(raw_value, formatted_value, instruc)
end

"""
  get_filter_query(object::SQLObject, instruc::SQLInstruction)

  Iterates over the filter of the object and generates the WHERE query for the given SQLInstruction object.

  #### ALERT
  - This internal function is called by the `build` function.

  #### Arguments
  - `object::SQLObject`: The object containing the filter to be selected.
  - `instruc::SQLInstruction`: The SQLInstruction object to which the WHERE query will be added.
"""
function get_filter_query(object::SQLObject, instruc::SQLInstruction)::Nothing
  # [isa(v, Union{SQLTypeQor, SQLTypeQ, SQLTypeOper}) ? push!(instruc._where, _get_filter_query(v, instruc)) : throw("Error in values, $(v) is not a SQLTypeQor, SQLTypeQ or SQLTypeOper") for v in object.filter]
  @pormg_debug false
  for v in object.filter
    if isa(v, SQLTypeOper)
      @pormg_debug false
      if isa(v.column, SQLTypeField) && isa(v.column.field, String) && !contains(v.column.field, "__") && !(v.column.field in instruc.object.model.field_names)
        # @pormg_debug false
        field = try
          instruc.cache[v.column._as].field
        catch e
          # @pormg_debug
          rethrow(e)
        end
        # Switch to having context for positional parameters
        set_context!(instruc, :having)
        placeholder = add_parameter!(instruc, _resolve_having_filter_value(v.column._as, v.values, instruc))
        push!(instruc.having, "$(field) $(v.operator) $(placeholder)")
        set_context!(instruc, :where)
        continue
      end
      push!(instruc._where, _get_filter_query(v, instruc))
    elseif isa(v, Union{SQLTypeQor,SQLTypeQ,SQLTypeF})
      push!(instruc._where, _get_filter_query(v, instruc))
    else
      throw("Error in values, $(v) is not a SQLTypeQor, SQLTypeQ or SQLTypeOper")
    end
  end
  return nothing
end

function build_row_join_sql_text(instruc::SQLInstruction)
  @pormg_debug false

  # --- Phase 1: pre-resolve ON conditions -----------------------------------
  # Filter resolution for deep paths (e.g. "raceid__circuitid__country") may
  # create additional join entries in instruc.row_join via _build_row_join.
  # By pre-resolving with an index-based loop we process newly created entries
  # in order and store the generated SQL fragments for Phase 2.
  n_before = length(instruc.row_join)
  on_clause_extras = Dict{Int, Vector{String}}()
  i = 1
  while i <= length(instruc.row_join)
    value = instruc.row_join[i]
    set_context!(instruc, :join)

    if haskey(value, "on_conditions") && value["on_conditions"] !== nothing
      on_conditions = value["on_conditions"]::Vector{FilterType}
      alias_a_quoted = quote_identifier(value["alias_a"], instruc.connection)
      original_alias = instruc.alias
      extras = String[]

      for condition in on_conditions
        condition_sql = _get_filter_query(condition, instruc)
        condition_sql = replace(condition_sql, "\"$(original_alias)\"." => "$alias_a_quoted.")
        push!(extras, condition_sql)
      end

      instruc.alias = original_alias
      on_clause_extras[i] = extras
    end
    i += 1
  end

  # --- Phase 1b: relocate forward-referencing ON extras ----------------------
  # When ON extras for join `idx` reference the alias of a join `dep_idx` that
  # was *created* during Phase 1 (i.e. dep_idx > n_before), it means the ON
  # condition uses a deep path (e.g. raceid__circuitid__country) that chains
  # through the current join's target table.  Emitting those extras on `idx`
  # would forward-reference `dep_idx` (whose JOIN clause hasn't appeared yet).
  #
  # Fix: move such extras to `dep_idx`'s ON clause, which is the join whose
  # alias is referenced.  The base ON of `dep_idx` already references `idx`'s
  # alias_b (the parent), so ordering is satisfied: idx emits first, dep_idx
  # emits second with the relocated extras.
  for idx in 1:n_before
    haskey(on_clause_extras, idx) || continue
    extras = on_clause_extras[idx]
    relocated = falses(length(extras))

    for dep_idx in (n_before+1):length(instruc.row_join)
      dep_alias = instruc.row_join[dep_idx]["alias_b"]
      for (ei, extra) in enumerate(extras)
        if !relocated[ei] && occursin("\"$(dep_alias)\"", extra)
          # Move this extra to dep_idx's ON clause
          if !haskey(on_clause_extras, dep_idx)
            on_clause_extras[dep_idx] = String[]
          end
          push!(on_clause_extras[dep_idx], extra)
          relocated[ei] = true
        end
      end
    end

    # Keep only the non-relocated extras on the original join
    if any(relocated)
      on_clause_extras[idx] = extras[.!relocated]
      isempty(on_clause_extras[idx]) && delete!(on_clause_extras, idx)
    end
  end

  # --- Phase 2: emit JOIN SQL text in original order -------------------------
  for (idx, value) in enumerate(instruc.row_join)
    set_context!(instruc, :join)
    b_quoted = safe_table_identifier(value["b"], instruc.connection)
    alias_b_quoted = quote_identifier(value["alias_b"], instruc.connection)
    alias_a_quoted = quote_identifier(value["alias_a"], instruc.connection)
    key_a_quoted = quote_identifier(value["key_a"], instruc.connection)
    key_b_quoted = quote_identifier(value["key_b"], instruc.connection)

    # Build base ON clause
    on_clause = "$alias_a_quoted.$key_a_quoted = $alias_b_quoted.$key_b_quoted"

    # Append pre-resolved ON condition fragments
    if haskey(on_clause_extras, idx)
      for extra in on_clause_extras[idx]
        on_clause *= " AND $extra"
      end
    end

    push!(instruc.join, """ $(value["how"]) JOIN $b_quoted AS $alias_b_quoted ON $on_clause """)
  end
end

function build(object::SQLObject;
  table_alias::Union{Nothing,SQLTableAlias}=nothing,
  connection::Union{Nothing,PormGPostgres,PormGSQLite}=nothing,
  parameters::Union{Nothing,AbstractPormGParam}=nothing,
  set_contexts::Bool=true)
  ensure_model_transaction_scope(object.model)

  settings, connection, conn_key = get_settings(object, connection=connection)

  table_alias === nothing && (table_alias = SQLTbAlias())
  parameters === nothing && (parameters = get_parameter(connection))
  @pormg_debug false
  instruct = InstrucObject(text="",
    object=object,
    table_alias=table_alias === nothing ? SQLTbAlias() : table_alias,
    alias=get_alias(table_alias),
    connection=connection,
    django=settings.django_prefix === nothing ? nothing : settings.django_prefix * "_", # TODO, remover
    parameters=parameters,
  )

  # Switch context for each SQL section so positional-parameter backends
  # (SQLite) push values into the correct bucket.
  # Subqueries skip this to inherit the parent's current bucket.
  set_contexts && set_context!(instruct, :select)
  get_select_query(object.values, instruct)

  set_contexts && set_context!(instruct, :where)
  get_filter_query(object, instruct)

  # Materialize explicit custom joins that weren't discovered by traversal.
  # This ensures cjoin filters are applied even in UPDATE/DELETE without explicit field paths.
  # We check against instruct.row_path to avoid redundant materialization (forcing them twice).
  for c_j in object.custom_join
    config = c_j |> Base.last
    if c_j |> Base.first ∉ instruct.row_path && config isa Dict{String,Any} && haskey(config, "field") && config["field"] isa PormGField
      array = split(c_j |> Base.first, "__")
      push!(array, config["field"].pk_field)
      _build_row_join(array, instruct)
    end
  end

  set_contexts && set_context!(instruct, :join)
  build_row_join_sql_text(instruct)

  get_order_query(object, instruct)  # ORDER BY has no parameters  

  return instruct
end
