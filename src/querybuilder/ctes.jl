"""
Set the field definitions from a CTE query to create temporary PormGField objects.
This allows the CTE to be treated like a table with queryable fields for JOINs.
"""
function _preset_cte_fields(cte_name::String, query::SQLObjectHandler;
  join_field::Union{Pair{String,String},Nothing}=nothing,
  join_type::String="LEFT")

  if join_field === nothing
    # If no join fields provided, assume primary key of the model
    if haskey(query.object.model.fields, "id")
      join_field = Pair("id", "id")
    else
      throw(ArgumentError("CTE query model must have a primary key field 'id' or specify join_field"))
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
  join_field::Union{Pair{String,String},Nothing}=nothing,
  join_type::String="LEFT")
  cte_fields = _preset_cte_fields(name, query, join_field=join_field, join_type=join_type)
  if haskey(q.ctes, name)
    throw("CTE with name $(name) already exists in the query; please use a different name")
  end
  @pormg_debug false
  q.ctes[name] = cte_fields
  return q
end
With(o::SQLObjectHandler, name::String, query::SQLObjectHandler;
  join_field::Union{Pair{String,String},Nothing}=nothing,
  join_type::String="LEFT") = With(o.object, name, query, join_field=join_field, join_type=join_type)

"""
Pair-accepting overload for `With`, enabling the functor-style API:

```julia
# Django-idiomatic chain:
races_91 = M.Race.objects.filter("year" => 1991).values("raceid")
q = M.Result.objects
  .with("r91" => races_91, join_field="raceid" => "raceid")
  .filter("positionorder" => 1)
```

The `Pair` first argument maps the CTE name to its sub-query handler.
All keyword arguments are forwarded to the underlying `With` implementation.
"""
function With(o::SQLObjectHandler, pair::Pair{String,<:SQLObjectHandler};
  join_field::Union{Pair{String,String},Nothing}=nothing,
  join_type::String="LEFT")
  With(o.object, pair.first, pair.second, join_field=join_field, join_type=join_type)
  return o
end



# Helper to recursively prefix and validate fields in cjoin filters.
# cjoin filters are ON-clause predicates, so they must target the joined model.
function _normalize_cjoin_filter_key(key::String, prefix::String, foreign_model::Union{PormGModel,Nothing})
  foreign_model === nothing && return key

  if startswith(key, prefix * "__")
    suffix = key[length(prefix) + 3:end]
    isempty(suffix) && throw(ArgumentError("Invalid cjoin filter field '$(key)' for join path '$(prefix)'. Provide a field on the joined model after the join path prefix."))

    base_field = String(split(suffix, "__")[1])
    if base_field in foreign_model.field_names || haskey(foreign_model.related_objects, base_field)
      return key
    end

    throw(ArgumentError("Invalid cjoin filter field '$(key)' for join path '$(prefix)'. The joined model '$(foreign_model.name)' does not contain the field or related path '$(base_field)'."))
  end

  base_field = String(split(key, "__")[1])
  if base_field in foreign_model.field_names || haskey(foreign_model.related_objects, base_field)
    return string(prefix, "__", key)
  end

  throw(ArgumentError("Invalid cjoin filter field '$(key)' for join path '$(prefix)'. cjoin filters modify the JOIN ON clause and must target fields on the joined model '$(foreign_model.name)'. Use a joined-model field like '$(prefix)__field' (or just 'field' for auto-prefixing), and keep base-query filters in .filter(...)."))
end

function _prefix_join_filter(filter, prefix::String, foreign_model::Union{PormGModel,Nothing})
  if filter isa Pair
    key = filter.first
    if key isa String
      return _normalize_cjoin_filter_key(key, prefix, foreign_model) => filter.second
    end
    return filter
  elseif filter isa QObject
    return QObject(filters=[_prefix_join_filter(f, prefix, foreign_model) for f in filter.filters])
  elseif filter isa QorObject
    return QorObject(or=[_prefix_join_filter(f, prefix, foreign_model) for f in filter.or])
  elseif filter isa OperObject
    new_oper = deepcopy(filter)

    if new_oper.column isa SQLField && new_oper.column.field isa String
      new_oper.column = SQLField(
        _normalize_cjoin_filter_key(new_oper.column.field, prefix, foreign_model),
        new_oper.column._as,
        new_oper.column.custom_as
      )
    elseif new_oper.column isa String
      new_oper.column = _normalize_cjoin_filter_key(new_oper.column, prefix, foreign_model)
    end

    if new_oper.values isa FExpression
      new_oper.values = _prefix_join_filter(new_oper.values, prefix, foreign_model)
    end

    return new_oper
  elseif filter isa FExpression
    new_filter = deepcopy(filter)

    if new_filter.field_name isa String
      new_filter.field_name = _normalize_cjoin_filter_key(new_filter.field_name, prefix, foreign_model)
    elseif new_filter.field_name isa FExpression
      new_filter.field_name = _prefix_join_filter(new_filter.field_name, prefix, foreign_model)
    end

    if new_filter.column isa String
      new_filter.column = _normalize_cjoin_filter_key(new_filter.column, prefix, foreign_model)
    elseif new_filter.column isa Vector{String}
      new_filter.column = [_normalize_cjoin_filter_key(v, prefix, foreign_model) for v in new_filter.column]
    elseif new_filter.column isa SQLField && new_filter.column.field isa String
      new_filter.column = SQLField(
        _normalize_cjoin_filter_key(new_filter.column.field, prefix, foreign_model),
        new_filter.column._as,
        new_filter.column.custom_as
      )
    end

    if new_filter.operand isa FExpression
      new_filter.operand = _prefix_join_filter(new_filter.operand, prefix, foreign_model)
    end

    return new_filter
  else
    return filter
  end
end

function _collect_join_filters(filters)
  _filters::Vector{Union{Pair,SQLTypeQ,SQLTypeQor,SQLTypeOper,SQLTypeF}} = Vector{Union{Pair,SQLTypeQ,SQLTypeQor,SQLTypeOper,SQLTypeF}}()

  if filters === nothing
    return _filters
  elseif isa(filters, Union{Pair,SQLTypeQ,SQLTypeQor,SQLTypeOper,SQLTypeF})
    push!(_filters, filters)
  elseif isa(filters, Vector)
    for f in filters
      if isa(f, Union{Pair,SQLTypeQ,SQLTypeQor,SQLTypeOper,SQLTypeF})
        push!(_filters, f)
      else
        throw(ArgumentError("Invalid filter type in array: $(typeof(f)). Use Pair, Q, Qor, OP, or F expressions."))
      end
    end
  else
    throw(ArgumentError("Invalid filters type: $(typeof(filters)). Use a Pair, Q, Qor, OP, F expression, or an array of these."))
  end

  return _filters
end

function _resolve_join_target_model(q::SQLObject, join_path::String)
  parts = split(join_path, "__")
  isempty(parts) && throw(ArgumentError("on() requires a non-empty join path."))

  current_model = q.model
  current_module = q.model._module

  for (index, part) in enumerate(parts)
    current_path = join(parts[1:index], "__")

    if index == 1 && haskey(q.ctes, part)
      throw(ArgumentError("on() does not target CTE names. Use with(..., join_type=...) to configure CTE join types."))
    end

    field = if part in current_model.field_names
      current_model.fields[part]
    elseif index == 1 && _get_join_field(q, current_path) !== nothing
      _get_join_field(q, current_path)
    else
      nothing
    end

    if field !== nothing
      if !hasproperty(field, :to) || field.to === nothing
        throw(ArgumentError("Join path '$(join_path)' stops at base field '$(part)', which is not a relation. Use cjoin(..., field=...) first if this path depends on a custom link."))
      end

      current_model = field.to isa PormGModel ? field.to : getfield(current_module, Symbol(String(field.to)))
    elseif haskey(current_model.related_objects, part)
      reverse_model = Symbol(uppercasefirst(string(current_model.related_objects[part][3])))
      current_model = getfield(current_module, reverse_model)
    else
      throw(ArgumentError("Join path '$(join_path)' is invalid. The segment '$(part)' is not a relation on model '$(current_model.name)'."))
    end
  end

  return current_model
end

function on(q::SQLObject, join_path::String, filters::AbstractVector; join_type::Union{String,Nothing}=nothing)
  target_model = _resolve_join_target_model(q, join_path)
  parsed_filters = Vector{FilterType}()

  for filter in filters
    prefixed = _prefix_join_filter(filter, join_path, target_model)

    if isa(prefixed, Pair)
      push!(parsed_filters, _check_filter(prefixed))
    elseif isa(prefixed, FilterType)
      push!(parsed_filters, prefixed)
    else
      throw(ArgumentError("Invalid filter type: $(typeof(prefixed)). Use Pair, Q, Qor, OP, or F expressions."))
    end
  end

  existing = get(q.custom_join, join_path, Dict{String,Any}())

  if isempty(parsed_filters) && join_type === nothing
    throw(ArgumentError("on() requires at least one ON predicate or a join_type override."))
  end

  existing_join_type = get(existing, "join_type", nothing)
  join_type_normalized = if join_type === nothing
    existing_join_type isa String ? existing_join_type : "LEFT"
  else
    _normalize_join_type(join_type)
  end

  existing_filters = get(existing, "filters", FilterType[])
  if !(existing_filters isa Vector{FilterType})
    existing_filters = FilterType[]
  end

  existing["filters"] = vcat(existing_filters, parsed_filters)
  existing["join_type"] = join_type_normalized
  q.custom_join[join_path] = existing

  return q
end

# Concrete overload resolves the ambiguity with on(::SQLObject, ::String, ::AbstractVector)
# that Aqua detects when q is a SQLObjectHandler (subtype matching is ambiguous otherwise).
function on(q::SQLObjectHandler, join_path::String, filters::AbstractVector; join_type::Union{String,Nothing}=nothing)
  on(q.object, join_path, filters; join_type=join_type)
  return q
end

function on(q::SQLObjectHandler, join_path::String, args...; filters=nothing, join_type::Union{String,Nothing}=nothing)
  positional_filters = _collect_join_filters(collect(args))
  kw_filters = _collect_join_filters(filters)
  combined_filters = vcat(positional_filters, kw_filters)

  on(q.object, join_path, combined_filters; join_type=join_type)
  return q
end


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
  main_join::Union{Pair{String,String},Nothing},
  filters::AbstractVector,
  field::Union{PormGField,Nothing},
  join_type::Union{String,Nothing},
  warn::Bool=true)

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

  @pormg_debug false
  if (split(main_join.first, "__") |> length) == 1 && main_join.first ∉ q.model.field_names
    throw(ArgumentError("The field '$(main_join.first)' is not a field in model '$(q.model.table_name)'. The fields are: $(q.model.field_names)"))
  end

  # Validation: if field already exists as a FK on the model, ensure target model matches
  existing_field = q.model.fields[main_join.first]
  if hasproperty(existing_field, :to) && existing_field.to !== nothing
    # existing_field is a FK, extract its target model name
    existing_target = if isa(existing_field.to, PormGModel)
      existing_field.to.name
    elseif isa(existing_field.to, String)
      existing_field.to
    else
      nothing
    end

    # Compare case-insensitively since model names may be capitalized differently
    if existing_target !== nothing && lowercase(existing_target) != lowercase(main_join.second)
      throw(ArgumentError("Field '$(main_join.first)' is already a ForeignKey pointing to '$(existing_target)', but cjoin attempted to join with '$(main_join.second)'. To add ON conditions to an existing FK, the target model must match. Use cjoin(query, \"$(main_join.first)\" => \"$(existing_target)\", filters=[...]) instead."))
    end
  end

  @pormg_debug false
  foreign_model::Union{PormGModel,Nothing} = nothing

  if field === nothing
    # No field provided, create a default PormGField for the join

    #   test_result = Models.ForeignKey(Result, pk_field="resultId", on_delete="CASCADE", null=true, related_name="test_deletion"),
    if !isdefined(q.model._module, main_join.second |> Symbol)
      throw(ArgumentError("Model '$(main_join.second)' not found in module. Please remember that model names are case-sensitive."))
      return nothing
    end
    foreign_model = getfield(q.model._module, Symbol(main_join.second))
    @pormg_debug false
    pk_field = Models.get_model_pk_field(foreign_model)
    if !isa(pk_field, Symbol)
      throw(ArgumentError("Foreign model '$(foreign_model.name)' does not have a valid/single primary key field."))
    end

    if warn
      @warn "cjoin auto-discovered join target primary key" join_field = main_join.first target_model = main_join.second auto_pk_field = String(pk_field) hint = "No explicit ForeignKey mapping was provided for this cjoin path. PormG will join main.$(main_join.first) -> $(main_join.second).$(pk_field). If this is not your intended link, pass field=Models.ForeignKey(<Model>, pk_field=your_target_field) in cjoin or use warn=false to suppress this warning."
    end

    field = Models.ForeignKey(
      foreign_model,
      pk_field=pk_field,
      on_delete="RESTRICT",
      null=true,
      related_name="$(q.model.name)_$(main_join.second)_join",
      how=join_type
    )
  else
    if hasproperty(field, :to)
      field_to = getproperty(field, :to)
      if field_to isa PormGModel
        foreign_model = field_to
      elseif field_to isa String && isdefined(q.model._module, Symbol(field_to))
        foreign_model = getfield(q.model._module, Symbol(field_to))
      end
    end
  end

  # Parse filters into proper FilterType objects and apply recursive join-field prefixing.
  # This "mixing logic" ensures that keys in Q (AND) or Qor (OR) objects belonging to the 
  # joined model correctly map through the join path (e.g. "nationality" -> "driverid__nationality")
  # before being converted into OperObjects.
  parsed_filters = Vector{FilterType}()
  for filter in filters
    # Call recursive helper before converting pairs into full FilterTypes
    prefixed = _prefix_join_filter(filter, main_join.first, foreign_model)

    if isa(prefixed, Pair)
      push!(parsed_filters, _check_filter(prefixed))
    elseif isa(prefixed, FilterType)
      push!(parsed_filters, prefixed)
    else
      throw(ArgumentError("Invalid filter type: $(typeof(prefixed)). Use Pair, Q, Qor, OP, or F expressions."))
    end
  end


  # Store in custom_join dict
  if !haskey(q.custom_join, main_join.first)
    q.custom_join[main_join.first] = Dict{String,Any}("filters" => parsed_filters, "field" => field)
  else
    throw(ArgumentError("Join path '$(main_join.first)' already exists"))
  end


  return q
end

# Convenience function for ObjectHandler
function cjoin(q::SQLObjectHandler, main_join::Union{Pair{String,String},Nothing}; kwargs...)
  accepted = Set([:filters, :field, :join_type, :warn])
  for k in keys(kwargs)
    if !(k in accepted)
      throw(ArgumentError("Invalid keyword argument: \e[31m$k\e[0m. Accepted: \e[31m$(collect(accepted))\e[0m"))
    end
  end
  filters = get(kwargs, :filters, nothing)
  field = get(kwargs, :field, nothing)
  join_type = get(kwargs, :join_type, nothing)
  warn = get(kwargs, :warn, true)
  _filters = _collect_join_filters(filters)

  if field !== nothing && !isa(field, PormGField)
    throw(ArgumentError("Invalid field type: $(typeof(field)). Use a PormGField or nothing."))
  end

  @pormg_debug false

  cjoin(q.object, main_join, _filters, field, join_type, warn)
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
function build_cte_clause(ctes::Dict{String,CTEDict}, connection, parameters::Union{Nothing,AbstractPormGParam}, table_alias::Union{Nothing,SQLTableAlias})
  isempty(ctes) && return ""

  @pormg_debug false
  cte_parts = String[]
  for (cte_name, cte_fields) in ctes
    # Extract the query from the fields dict
    @pormg_debug false
    if !haskey(cte_fields, "query")
      @error "CTE '$cte_name' does not have a query" fields = keys(cte_fields)
      continue
    end

    cte_query = cte_fields["query"]

    # IMPORTANT: Set context to :cte for positional parameters (SQLite/MySQL)
    # This ensures parameters inside the CTE land in the correct bucket
    # and appear before main query parameters in the final SQL order.
    set_context!(parameters, :cte)

    # IMPORTANT: Pass the SAME parameters object so parameter numbering continues sequentially
    cte_sql = query(cte_query, table_alias=table_alias, connection=connection, parameters=parameters, cte=cte_fields)

    @pormg_debug false

    # Quote the CTE name
    safe_cte_name = quote_identifier(cte_name, connection)

    # Add to CTE parts
    push!(cte_parts, "$safe_cte_name AS (\n  $cte_sql\n)")
  end

  return "WITH " * join(cte_parts, ",\n") * "\n"
end


"""
Infer the output PormGField type for a CASE/WHEN expression by inspecting
the `then` values from WHEN branches and the `default`/`else` value.

Returns IntegerField if all values are integers, FloatField if any are floats,
or CharField as a safe fallback for strings or mixed types.
"""
function _infer_case_output_type(func::SQLTypeFunction)
  output_values = Any[]

  # Collect `else`/default from the CASE kwargs
  if haskey(func.kwargs, "else") && !(func.kwargs["else"] isa Missing)
    push!(output_values, func.kwargs["else"])
  end

  # Collect `then` from each WHEN branch (stored in func.column for CASE)
  if func.column isa Vector
    for when_branch in func.column
      if hasproperty(when_branch, :kwargs) && haskey(when_branch.kwargs, "then")
        push!(output_values, when_branch.kwargs["then"])
      end
    end
  elseif func.function_name == "WHEN" && haskey(func.kwargs, "then")
    push!(output_values, func.kwargs["then"])
  end

  # Infer type from collected values
  if isempty(output_values)
    return CharField()  # no values to infer from, safest default
  elseif all(v -> v isa Integer, output_values)
    return IntegerField()
  elseif all(v -> v isa Number, output_values)
    return FloatField()
  elseif all(v -> v isa AbstractString, output_values)
    return CharField()
  else
    return CharField()  # mixed types, safest default
  end
end


function _set_field_from_sql_function(func::SQLTypeFunction, field::String, instruct::SQLInstruction)
  # CASE/WHEN: infer output type from `then` and `default`/`else` values
  if func.function_name in ["CASE", "WHEN"]
    return _infer_case_output_type(func)
  end

  if !(func.function_name in ["COUNT", "SUM", "AVG", "MIN", "MAX"])
    throw(ArgumentError("Error in _set_field_from_sql_function, the function \e[4m\e[31m$(func.function_name)\e[0m is not a recognized function. Allowed: \e[4m\e[32mCOUNT, SUM, AVG, MIN, MAX, CASE, WHEN\e[0m"))
  end

  if func.function_name in ["COUNT", "SUM"]
    return IntegerField()
  else
    # For AVG/MIN/MAX: resolve the base column from func.column to determine the output type.
    # `field` is the alias (e.g. "points_avg"), but we need the actual model column (e.g. "round")
    base_col = if func.column isa String
      func.column
    elseif hasproperty(func.column, :field) && func.column.field isa String
      func.column.field
    elseif hasproperty(func.column, :_as) && func.column._as isa String
      func.column._as
    else
      field  # fallback to alias
    end

    @pormg_debug false

    fields = instruct.object.model.fields
    if haskey(fields, base_col)
      return fields[base_col]
    elseif haskey(fields, field)
      return fields[field]
    else
      throw(ArgumentError("Error in _set_field_from_sql_function, the field \e[4m\e[31m$(field)\e[0m (base column: \e[31m$(base_col)\e[0m) not found in \e[4m\e[32m$(instruct.object.model.name)\e[0m"))
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
  fields = Dict{String,PormGField}()
  selected_field_names = String[]
  @pormg_debug false
  for value_part in values
    # fields[value_part.field] = _set_field_from_sql_function(value_part.field, value_part._as, instruct)
    key_new = value_part.custom_as !== nothing ? value_part.custom_as : value_part._as
    try
      fields[key_new] = _set_field_from_sql_function(value_part.field, value_part._as, instruct)
      push!(selected_field_names, key_new)
    catch e
      @pormg_debug false
      throw(e)
    end
  end
  @pormg_debug false

  cte["model"] = Models.Model_Type(
    name = "",
    fields = fields,
    field_names = selected_field_names,
    _module = instruct.object.model._module,
    connect_key = instruct.object.model.connect_key
  )

end