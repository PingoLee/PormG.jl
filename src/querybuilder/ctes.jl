"""
Set the field definitions from a CTE query to create temporary PormGField objects.
This allows the CTE to be treated like a table with queryable fields for JOINs.
"""
function _preset_cte_fields(cte_name::String, query::SQLObjectHandler;
    join_field::Union{Pair{String, String}, Nothing} = nothing,
    join_type::String = "LEFT") 

  if join_field === nothing
    # If no join fields provided, assume primary key of the model
    if haskey(query.object.model.fields, "id")
      join_field = Pair("id", "id")
    else
      throw("CTE query model must have a primary key field 'id' or specify join_field")
    end
  end
  table = CTEDict(
    "join_type" => join_type,
    "query" => deepcopy(query),
    "join_field" => join_field
  ) 

  return table
end

function With(q::SQLObject, name::String, query::SQLObjectHandler;
    join_field::Union{Pair{String, String}, Nothing} = nothing,
    join_type::String = "LEFT") 
  cte_fields = _preset_cte_fields(name, query, join_field=join_field, join_type=join_type)
  if haskey(q.ctes, name)
    throw("CTE with name $(name) already exists in the query; please use a different name")
  end
  @infiltrate false
  q.ctes[name] = cte_fields
  return q
end
With(o::SQLObjectHandler, name::String, query::SQLObjectHandler;
    join_field::Union{Pair{String, String}, Nothing} = nothing,
    join_type::String = "LEFT") = With(o.object, name, query, join_field=join_field, join_type=join_type)



"""
Add a custom join to the query object that does not have to follow the model's foreign key relationships.

# Arguments
 - `q::SQLObject`: The SQL object to add the custom join to
 - `main_join::Pair{String, String}`: A pair where the first element is the field in the main model to join on, and the second element is the related model name to join with
 - `filters::AbstractVector`: (Optional) An array of filters (Pair, Q, Qor, OP, F) to apply to the join condition
 - `join_type::Union{String, Nothing}`: (Optional) The type of join

# Examples
```julia
  query = M.New_join_position |> object;
  cjoin(query, "result" => "Result");
  query.values("result__statusid__status", "description", "result");

  @info query |> show_query
  ┌ Info: SELECT
  │    "Tb_2"."status" as result__statusid__status,
  │   "Tb"."description" as description,
  │   "Tb"."result" as result
  │ FROM "new_join_position" as "Tb"
  │  LEFT JOIN "result" AS "Tb_1" ON "Tb"."result" = "Tb_1"."resultid"
  └  LEFT JOIN "status" AS "Tb_2" ON "Tb_1"."statusid" = "Tb_2"."statusid"
```
"""
function cjoin(
  q::SQLObject, 
  main_join::Union{Pair{String, String}, Nothing},
  filters::AbstractVector,
  field::Union{PormGField, Nothing},
  join_type::Union{String, Nothing})
  
  # # Validations
  if main_join === nothing 
    throw(ArgumentError("Please, main_join argument is required to create a new join."))
  end

  # if field_destination !== nothing && !contains(field_destination, "__")
  #   throw(ArgumentError("Invalid field_destination format: '$field_destination'. Expected format 'related_model__field'."))
  # end
  if (split(main_join.first, "__") |> length) > 1
    throw(ArgumentError("That is not supported yet: main_join with related fields. Please, provide just the field name of the main model."))
  end

  @infiltrate false
  if (split(main_join.first, "__") |> length) == 1 && main_join.first ∉ q.model.field_names
    throw(ArgumentError("The field '$(main_join.first)' is not a field in model '$(q.model.table_name)'. The fields are: $(q.model.field_names)"))
  end

  @infiltrate false
    
  # Parse filters into proper Q/Qor/OP objects
  parsed_filters = Vector{FilterType}()
  for filter in filters
    if isa(filter, Pair)
      push!(parsed_filters, _check_filter(filter))
    elseif isa(filter, FilterType)
      push!(parsed_filters, filter)
    else
      throw(ArgumentError("Invalid filter type: $(typeof(filter)). Use Pair, Q, Qor, OP, or F expressions."))
    end
  end

  @infiltrate false

  if field === nothing
    # No field provided, create a default PormGField for the join

    #   test_result = Models.ForeignKey(Result, pk_field="resultId", on_delete="CASCADE", null=true, related_name="test_deletion"),
    if !isdefined(q.model._module, main_join.second |> Symbol)
      throw(ArgumentError("Model '$(main_join.second)' not found in module. Please remember that model names are case-sensitive."))
      return nothing
    end
    foreign_model = getfield(q.model._module, Symbol(main_join.second))
    @infiltrate false
    pk_field = Models.get_model_pk_field(foreign_model)
    if !isa(pk_field, Symbol)
      throw(ArgumentError("Foreign model '$(foreign_model.name)' does not have a valid/single primary key field."))
    end
    field = Models.ForeignKey(
      foreign_model,
      pk_field=pk_field,
      on_delete="RESTRICT",
      null=true,
      related_name="$(q.model.name)_$(main_join.second)_join",
      how=join_type
    )
  end

  
  # Store in custom_join dict
  if !haskey(q.custom_join, main_join.first)
    q.custom_join[main_join.first] = Dict{String, Any}("filters" => parsed_filters, "field" => field)
  else 
    throw(ArgumentError("Join path '$(main_join.first)' already exists"))
  end
  
  
  return q
end

# Convenience function for ObjectHandler
function cjoin(q::SQLObjectHandler, main_join::Union{Pair{String, String}, Nothing}; kwargs...)
    accepted = Set([:filters, :field, :join_type])
    for k in keys(kwargs)
      if !(k in accepted)
        throw(ArgumentError("Invalid keyword argument: \e[31m$k\e[0m. Accepted: \e[31m$(collect(accepted))\e[0m"))
      end
    end
    filters = get(kwargs, :filters, nothing)
    field = get(kwargs, :field, nothing)
    join_type = get(kwargs, :join_type, nothing)

    _filters::Vector{Union{Pair, SQLTypeQ, SQLTypeQor, SQLTypeOper, SQLTypeF}} = Vector{Union{Pair, SQLTypeQ, SQLTypeQor, SQLTypeOper, SQLTypeF}}()
    @infiltrate false
    if filters === nothing
      # pass
    elseif isa(filters, Union{Pair, SQLTypeQ, SQLTypeQor, SQLTypeOper, SQLTypeF})
      push!(_filters, filters)
    elseif isa(filters, Vector)
      for f in filters
        if isa(f, Union{Pair, String, SQLTypeQ, SQLTypeQor, SQLTypeOper, SQLTypeF})
          push!(_filters, f)
        else
          throw(ArgumentError("Invalid filter type in array: $(typeof(f)). Use Pair, Q, Qor, OP, or F expressions."))
        end
      end
    else
      throw(ArgumentError("Invalid filters type: $(typeof(filters)). Use a Pair, Q, Qor, OP, F expression, or an array of these."))
    end

    if field !== nothing && !isa(field, PormGField)
      throw(ArgumentError("Invalid field type: $(typeof(field)). Use a PormGField or nothing."))
    end

    @infiltrate false

    cjoin(q.object, main_join, _filters, field, join_type)
    return q
end
cjoin(q::SQLObjectHandler; kwargs...) = cjoin(q, nothing; kwargs...)


"""
Build CTE (WITH clause) SQL string from the CTEs defined in the query object.

# Arguments
- `ctes::Dict{String, Dict{String, Union{SQLObjectHandler, PormGField}}}`: Dict of CTE name => fields dict
- `connection`: Database connection for quoting identifiers
- `parameters`: Parameterized query object to collect all parameters

# Returns
- String containing the WITH clause SQL, or empty string if no CTEs
"""
function build_cte_clause(ctes::Dict{String, CTEDict}, connection, parameters::Union{Nothing, AbstractPormGParam}, table_alias::Union{Nothing, SQLTableAlias})
  isempty(ctes) && return ""
  
  @infiltrate false
  cte_parts = String[]
  for (cte_name, cte_fields) in ctes
    # Extract the query from the fields dict
    @infiltrate false
    if !haskey(cte_fields, "query")
      @error "CTE '$cte_name' does not have a query" fields=keys(cte_fields)
      continue
    end
    
    cte_query = cte_fields["query"]
    
    # IMPORTANT: Pass the SAME parameters object so parameter numbering continues sequentially
    cte_sql = query(cte_query, table_alias=table_alias, connection=connection, parameters=parameters, cte=cte_fields)

    @infiltrate false
    
    # Quote the CTE name
    safe_cte_name = quote_identifier(cte_name, connection)
    
    # Add to CTE parts
    push!(cte_parts, "$safe_cte_name AS (\n  $cte_sql\n)")
  end
  
  return "WITH " * join(cte_parts, ",\n") * "\n"
end


function _set_field_from_sql_function(func::SQLTypeFunction, field::String, instruct::SQLInstruction)
  if !(func.function_name in ["COUNT", "SUM", "AVG", "MIN", "MAX"])
    throw(ArgumentError("Error in _set_field_from_sql_function, the function \e[4m\e[31m$(func.function_name)\e[0m is not an agregate function. Only agregate functions are allowed: \e[4m\e[32mCOUNT, SUM, AVG, MIN, MAX\e[0m"))
  end

  if func.function_name in ["COUNT", "SUM"]
    return IntegerField()
  else
    fields = instruct.object.model.fields
    if haskey(fields, field)
      return fields[field]
    else
      throw(ArgumentError("Error in _set_field_from_sql_function, the field \e[4m\e[31m$(field)\e[0m not found in \e[4m\e[32m$(instruct.object.model.name)\e[0m"))
    end
  end
 
end
function _set_field_from_sql_function(func::String, field::String, instruct::SQLInstruction)
  if haskey(instruct.tab_field_cache, field)
    return instruct.tab_field_cache[field]
  elseif haskey(instruct.object.model.fields, field)
    return instruct.object.model.fields[field]
  else
    throw(ArgumentError("Error in _set_field_from_sql_function, the field \e[4m\e[31m$(field)\e[0m not found in \e[4m\e[32m$(instruct.object.model.name)\e[0m"))
  end
end

function _build_cte_custom_model(cte::CTEDict, instruct::SQLInstruction)
  values = instruct.object.values
  fields = Dict{String, PormGField}()
  @infiltrate false
  for field_names in values
    # fields[field_names.field] = _set_field_from_sql_function(field_names.field, field_names._as, instruct)
    key_new = field_names.custom_as !== nothing ? field_names.custom_as : field_names._as
    try
      fields[key_new] = _set_field_from_sql_function(field_names.field, field_names._as, instruct)
    catch e
      @infiltrate
      throw(e)
    end
  end
  @infiltrate false

  cte["model"] = Models.Model("", fields)   

end