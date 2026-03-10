
"build a row to join"
function _determine_join_type(field::PormGField; previus_how::Union{String, Nothing} = nothing, second_fild_name::Union{String, Nothing}=nothing)
  valid_joins = ["INNER", "LEFT", "RIGHT", "FULL", "CROSS"]

  if previus_how !== nothing && previus_how == "LEFT"
    # if the previous join was a LEFT JOIN, the current join must be a LEFT JOIN
    return "LEFT"
  end
  
  @infiltrate false
  if !hasproperty(field, :how)
    if second_fild_name !== nothing
      _check_if_field_is_a_operator(second_fild_name)
    end
    throw(ArgumentError("The field '$(field)' does not have a 'how' property"))
  elseif field.how !== nothing && !isempty(field.how)
    join_type = uppercase(strip(field.how))
    if join_type ∉ valid_joins
      throw(ArgumentError("Invalid join type '$(field.how)'. Valid types: $(join(valid_joins, ", "))"))
    end
    return join_type
  end
  
  return field.null ? "LEFT" : "INNER"
end

"""
    _cache_join(field::String, instruct::SQLInstruction)

Checks if a join path `field` is already in the cache. If not, and it's a join path (contains `__`), 
it attempts to build the join and cache it. Returns `true` if the field is in cache 
(either before or after the attempt), `false` otherwise.
"""
function _cache_join(field::String, instruct::SQLInstruction)
  haskey(instruct.cache, field) && return true
  
  if contains(field, "__")
    try
      # Build the join and get the SQL selector (e.g., "Tb.column")
      sql_selector = _build_row_join(split(field, "__") |> Vector{String}, instruct)
      
      # Populate the cache so it can be used immediately
      instruct.cache[field] = SQLField(sql_selector, field)
      return true
    catch e
      return false
    end
  end
  return false
end

function _build_row_join(field::Vector{SubString{String}}, instruct::SQLInstruction; as::Bool=true)
  # convert the field to a vector of string
  vector = String.(field)
  _build_row_join(vector, instruct, as=as)  
end
function _build_row_join(field::Vector{String}, instruct::SQLInstruction; as::Bool=true)
  vector = copy(field) 
  foreign_table_name::Union{String, PormGModel, Nothing} = nothing
  foreing_table_module::Module = instruct.object.model._module::Module
  row_join = sizehint!(Dict{String, Union{String, Vector{FilterType}}}(), 8)
 
  @infiltrate false

  first_column = instruct.django !== nothing ? string(vector[1], "_id") : vector[1]
  last_field::Union{Nothing, PormGField} = nothing
  join_path = field[1]

  # Check if first_column references a CTE table
  if haskey(instruct.object.ctes, vector[1])
    @infiltrate false
    cte_name = vector[1]
    cte_dict = instruct.object.ctes[cte_name]
    if !haskey(cte_dict, "model")
      throw(ArgumentError("Internal error: CTE $(cte_name) has not been materialized yet"))
    end
    cte_model = cte_dict["model"]::PormGModel
    
    length(vector) == 1 && throw("Error, CTE reference '$(cte_name)' must include a field name. Example: '$(cte_name)__field_name'")

    # Get the join field configuration from the CTE
    join_field_pair = cte_dict["join_field"]::Pair{String, String}
    main_table_key = join_field_pair.first    # e.g., "driverid" from main table
    cte_table_key = join_field_pair.second    # e.g., "driverid" from CTE
    @infiltrate false
    
    if !haskey(cte_model.fields, cte_table_key)
      available = join(collect(keys(cte_model.fields)), ", ")
      throw(ArgumentError("CTE join_field column '$(cte_table_key)' not found in $(cte_name); available fields: $(available)"))
    end
    

    if (main_table_key in instruct.object.model.field_names)
      row_join["alias_a"] = instruct.alias
      row_join["key_a"] = main_table_key
    elseif haskey(instruct.cache, main_table_key) || _cache_join(main_table_key, instruct)
      cache_item = instruct.cache[main_table_key]
      v_split = split(cache_item.field |> x -> replace(x,  '"' => ""), ".")
      row_join["alias_a"] = v_split[1] |> string
      row_join["key_a"] = v_split[2] |> string
    else
      throw(ArgumentError("Main table join_field column '$(main_table_key)' not found in $(instruct.object.model.name); available fields: $(join(instruct.object.model.field_names, ", "))"))
    end
    
    # Set up the join with the CTE
    row_join["a"] = instruct.object.model.name
    
    row_join["b"] = cte_name  # CTE name becomes the table name
    row_join["alias_b"] = _get_alias_name(instruct.row_join, instruct.alias)
    row_join["how"] = cte_dict["join_type"]::String
        
    row_join["key_b"] = cte_table_key

    @infiltrate false

    foreign_table_name = cte_model
    last_field = cte_model.fields[vector[2]]
   
  elseif first_column in instruct.object.model.field_names || haskey(instruct.object.custom_join, join_path)
    row_join["a"] = instruct.object.model.name
    row_join["alias_a"] = instruct.alias
    # @infiltrate
    first_field = haskey(instruct.object.custom_join, join_path) ? instruct.object.custom_join[join_path]["field"] : instruct.object.model.fields[first_column]
    # @infiltrate
    row_join["how"] = _determine_join_type(first_field, second_fild_name= size(vector, 1) > 1 ? vector[2] : nothing)
    foreign_table_name = first_field.to
    if foreign_table_name === nothing
      throw("Error in _build_row_join, the column $(first_column) does not have a foreign key")
    elseif isa(foreign_table_name, PormGModel)
      row_join["b"] = foreign_table_name.name
      size(vector, 1) == 2 && (last_field = foreign_table_name.fields[vector[2]])
    else
      row_join["b"] = instruct.django !== nothing ? string(instruct.django,  foreign_table_name |> lowercase) : foreign_table_name |> lowercase
      size(vector, 1) == 2 && (last_field = getfield(foreing_table_module, foreign_table_name |> Symbol).fields[vector[2]])
    end
    # @infiltrate
    row_join["alias_b"] = _get_alias_name(instruct.row_join, instruct.alias)
    row_join["key_b"] = first_field.pk_field::String
    row_join["key_a"] = first_column
  elseif haskey(instruct.object.model.related_objects, vector[1])
    # @infiltrate false
    s_model = Symbol(uppercasefirst(string(instruct.object.model.related_objects[vector[1]][3])))
    reverse_model = getfield(foreing_table_module, s_model)
    length(vector) == 1 && throw("Error in _build_row_join, the column $(vector[1]) is a reverse field, you must inform the column to be selected. Example: ...filter(\"$(vector[1])__column\")")
    # !(vector[2] in reverse_model.field_names) && throw("Error in _build_row_join, the column $(vector[2]) not found in $(reverse_model.name)")
    row_join["a"] = instruct.object.model.name
    row_join["alias_a"] = instruct.alias
    last_field = reverse_model.fields[instruct.object.model.related_objects[vector[1]][1] |> String]   
    row_join["how"] = _determine_join_type(last_field, second_fild_name= vector[2]) 
    foreign_table_name = instruct.object.model.related_objects[vector[1]][3] |> String
    if foreign_table_name === nothing
      throw("Error in _build_row_join, the column $(foreign_table_name) does not have a foreign key")
    elseif isa(foreign_table_name, PormGModel)
      row_join["b"] = foreign_table_name.name
    else
      row_join["b"] = instruct.django !== nothing ? string(instruct.django,  foreign_table_name |> lowercase) : foreign_table_name |> lowercase
    end

    row_join["alias_b"] = _get_alias_name(instruct.row_join, instruct.alias)
    row_join["key_a"] = instruct.object.model.related_objects[vector[1]][2] |> String
    row_join["key_b"] = instruct.object.model.related_objects[vector[1]][1] |> String
    foreign_table_name = s_model |> string
    @infiltrate false
  else
    @infiltrate false
    throw(ArgumentError("the column \e[4m\e[31m$(vector[1])\e[0m not found in \e[4m\e[32m$(instruct.object.model.name)\e[0m, that contains the fields: \e[4m\e[32m$(join(instruct.object.model.field_names, ", "))\e[0m and the related objects: \e[4m\e[32m$(join(keys(instruct.object.model.related_objects), ", "))\e[0m"))
  end

  if haskey(instruct.object.custom_join, join_path)
    @infiltrate false
    row_join["on_conditions"] = instruct.object.custom_join[join_path]["filters"]
  end

  tb_alias = _insert_join(instruct.row_join, row_join, instruct.row_path, join_path) 
  
  vector = vector[2:end]  

  @infiltrate false
  
  while size(vector, 1) > 1
    # get new object
    @infiltrate false
    join_path = join(field[1:length(field)-length(vector) + 1], "__")
    new_object = foreign_table_name isa PormGModel ? foreign_table_name : getfield(foreing_table_module, foreign_table_name |> Symbol)
    first_column = instruct.django !== nothing ? string(vector[1], "_id") : vector[1]

    # Create a new Dict for this join to avoid mutating previously inserted joins
    prev_how = row_join["how"]
    prev_b = row_join["b"]
    row_join = sizehint!(Dict{String, Union{String, Vector{FilterType}}}(), 8)

    if first_column in new_object.field_names
      first_field = new_object.fields[first_column]
      !hasfield(typeof(first_field), :to) && throw("Error in _build_row_join, the column $(first_column) is a field from $(new_object.name), but this field has not a foreign key")
      row_join["a"] = prev_b
      row_join["alias_a"] = tb_alias      
      row_join["how"] = _determine_join_type(new_object.fields[first_column], previus_how=prev_how, second_fild_name= size(vector, 1) > 1 ? vector[2] : nothing)
      foreign_table_name = new_object.fields[first_column].to
      if foreign_table_name === nothing
        throw("Error in _build_row_join, the column $(vector[2]) does not have a foreign key")
      elseif isa(foreign_table_name, PormGModel)
        row_join["b"] = foreign_table_name.name
        size(vector, 1) == 2 && (last_field = foreign_table_name.fields[vector[2]])
      else
        row_join["b"] = instruct.django !== nothing ? string(instruct.django,  foreign_table_name |> lowercase) : foreign_table_name |> lowercase
        size(vector, 1) == 2 && (last_field = getfield(foreing_table_module, foreign_table_name |> Symbol).fields[vector[2]])
      end
      row_join["alias_b"] = _get_alias_name(instruct.row_join, instruct.alias) # TODO chage by row_join and test the speed
      row_join["key_b"] = new_object.fields[first_column].pk_field::String
      row_join["key_a"] = first_column    
    elseif haskey(new_object.related_objects, vector[1])
      s_model = Symbol(uppercasefirst(string(new_object.related_objects[vector[1]][3])))
      reverse_model = getfield(foreing_table_module, s_model)
      length(vector) == 1 && throw("Error in _build_row_join, the column $(vector[1]) is a reverse field, you must inform the column to be selected. Example: ...filter(\"$(vector[1])__column\")")
      !(vector[2] in reverse_model.field_names) && throw("Error in _build_row_join, the column $(vector[2]) not found in $(reverse_model.name)")
      row_join["a"] = prev_b
      row_join["alias_a"] = tb_alias
      last_field = reverse_model.fields[new_object.related_objects[vector[1]][1] |> String]
      row_join["how"] = _determine_join_type(last_field, previus_how=prev_how, second_fild_name= vector[2])
      foreign_table_name = new_object.related_objects[vector[1]][3] |> String
      if foreign_table_name === nothing
        throw("Error in _build_row_join, the column $(foreign_table_name) does not have a foreign key")
      elseif isa(foreign_table_name, PormGModel)
        row_join["b"] =  foreign_table_name.name
      else
        row_join["b"] = instruct.django !== nothing ? string(instruct.django,  foreign_table_name |> lowercase) : foreign_table_name |> lowercase
      end

      row_join["alias_b"] = _get_alias_name(instruct.row_join, instruct.alias)
      row_join["key_a"] = new_object.related_objects[vector[1]][2] |> String
      row_join["key_b"] = new_object.related_objects[vector[1]][1] |> String
      vector = vector[2:end]

    else
      throw("Error in _build_row_join, the column $(vector[1]) not found in $(new_object.name)")
    end

    @infiltrate false   
    if haskey(instruct.object.custom_join, join_path)
      row_join["on_conditions"] = instruct.object.custom_join[join_path]["filters"]
    end
    
    tb_alias = _insert_join(instruct.row_join, row_join, instruct.row_path, join_path)

    vector = vector[2:end]
  end

  # tb_alias is the last table alias in the join ex. tb_1
  # last_column is the last column in the join ex. last_login
  # vector is the full path to the column ex. user__last_login__date (including functions (except the suffix))

  # @infiltrate

  # println("$(join(field, "__"))")
  # functions must be processed here
  instruct.tab_field_cache["$(join(field, "__"))"] = last_field
  return string(quote_identifier(tb_alias, instruct.connection), ".", _solve_field(vector[end], foreing_table_module, foreign_table_name, instruct))
  
end