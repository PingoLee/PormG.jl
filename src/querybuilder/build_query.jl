"""
  get_select_query(object::SQLObject, instruc::SQLInstruction)

  Iterates over the values of the object and generates the SELECT query for the given SQLInstruction object.

  #### ALERT
  - This internal function is called by the `build` function.

  #### Arguments
  - `object::SQLObject`: The object containing the values to be selected.
  - `instruc::SQLInstruction`: The SQLInstruction object to which the SELECT query will be added.
"""
function get_select_query(values::Vector{Union{SQLTypeText, SQLTypeField}}, instruc::SQLInstruction)
  for i in eachindex(values) # linear indexing
    v_copy = deepcopy(values[i])
    if isa(v_copy.field, SQLTypeFunction) 
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
      @infiltrate false
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
    if haskey(instruc.cache, v_field_copy._as)
      v_field_copy.field = instruc.cache[v_field_copy._as].field # TODO how can i recover the order of the field in select, maybe is better thar use the function in order by
    else
      v_field_copy.field = _get_select_query(v_field_copy.field, instruc)
    end     
    push!(instruc.order, string(v_field_copy.field, " ", v.orientation))
    instruc.cache[v_field_copy._as] = v_field_copy   

    # check if the field is in the select
    for value in object.values
      if isa(value, SQLTypeFunction) && value.field.agregate == true
        continue
      elseif value._as == v_field_copy._as
        found_in_select = true
        break
      end
    end

    if !found_in_select
      push!(instruc.group, v_field_copy.field)
    end

  end  
  return nothing  
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
  @infiltrate false
  for v in object.filter
    if isa(v, SQLTypeOper)
      @infiltrate false
      if isa(v.column, SQLTypeField) && isa(v.column.field, String) && !contains(v.column.field, "__") && !(v.column.field in instruc.object.model.field_names)
        # @infiltrate false
        field = try
          instruc.cache[v.column._as].field
        catch e
          # @infiltrate
          rethrow(e)
        end
        if haskey(instruc.tab_field_cache, v.column._as)
          _validation = instruc.tab_field_cache[instruc.cache[v.column._as]._as]
        else
          _validation = IntegerField()
        end
        push!(instruc.having, "$(field) $(v.operator) $(_validation.formater(v.values))")
        continue
      end
      push!(instruc._where, _get_filter_query(v, instruc))
    elseif isa(v, Union{SQLTypeQor, SQLTypeQ, SQLTypeF})
      push!(instruc._where, _get_filter_query(v, instruc))
    else      
      throw("Error in values, $(v) is not a SQLTypeQor, SQLTypeQ or SQLTypeOper")
    end
  end  
  return nothing
end

function build_row_join_sql_text(instruc::SQLInstruction)
  @infiltrate false
  for value in instruc.row_join
    b_quoted = safe_table_identifier(value["b"], instruc.connection)
    alias_b_quoted = quote_identifier(value["alias_b"], instruc.connection)
    alias_a_quoted = quote_identifier(value["alias_a"], instruc.connection)
    key_a_quoted = quote_identifier(value["key_a"], instruc.connection)
    key_b_quoted = quote_identifier(value["key_b"], instruc.connection)
    
    # Build base ON clause
    on_clause = "$alias_a_quoted.$key_a_quoted = $alias_b_quoted.$key_b_quoted"
    
    # Add additional ON conditions if present (from cjoin or CustomJoin)
    if haskey(value, "on_conditions") && value["on_conditions"] !== nothing
      on_conditions = value["on_conditions"]::Vector{FilterType}      
      original_alias = instruc.alias
      
      for condition in on_conditions
        condition_sql = _get_filter_query(condition, instruc)        
        condition_sql = replace(condition_sql, "\"$(original_alias)\"." => "$alias_a_quoted.")
        
        if haskey(value, "b")
          table_b_name = value["b"]        
        end
        
        on_clause *= " AND $condition_sql"
      end
      
      instruc.alias = original_alias
    end
    
    push!(instruc.join, """ $(value["how"]) JOIN $b_quoted AS $alias_b_quoted ON $on_clause """)
  end
end

function build(object::SQLObject; 
  table_alias::Union{Nothing, SQLTableAlias} = nothing, 
  connection::Union{Nothing, PormGPostgres, PormGSQLite} = nothing,
  parameters::Union{Nothing, PormGPostgresParam} = nothing)
  ensure_model_transaction_scope(object.model)
  
  settings, connection, conn_key = get_settings(object, connection=connection)
  
  table_alias === nothing && (table_alias = SQLTbAlias())
  parameters === nothing && (parameters = get_parameter(connection))
  @infiltrate false
  instruct = InstrucObject(text = "", 
    object = object,
    table_alias = table_alias === nothing ? SQLTbAlias() : table_alias,
    alias = get_alias(table_alias),
    connection = connection,
    django = settings.django_prefix === nothing ? nothing : settings.django_prefix * "_", # TODO, remover
    parameters = parameters,
  )   
  
  get_select_query(object.values, instruct)
  get_filter_query(object, instruct)
  build_row_join_sql_text(instruct)
  get_order_query(object, instruct)

  @infiltrate false
  
  return instruct
end
