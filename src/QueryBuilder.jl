module QueryBuilder

using ..PormG: SQLType, SQLConn, SQLInstruction, SQLTypeF, SQLTypeOper, SQLTypeQ, SQLTypeQor, SQLObject, PormGsuffix, PormGtrasnform, PormGModel
import DataFrames

function _get_join_query(array::Vector{String}; array_store::Vector{String}=String[])
  # println(array)
  # println(array_store)
  array = copy(array)
  for i in 1: size(array, 1)
    print(string(i, " - "))
    print(array[i])
    print(" ")
    for (k, value) in PormGsuffix
      if endswith(array[i], k)
        array[i] = array[i][1:end-length(k)]          
      end
    end
    for (k, value) in PormGtrasnform
      print(endswith(array[i], k))
      if endswith(array[i], k)          
        array[i] = array[i][1:end-length(k)]  
        print(" ")
        print(array[i])
        print(" ")        
      end
    end
    # println(array[i])
  end
  
  # how join to Vector
  # println(array)
  append!(array_store, array)
  unique!(array_store)
  # println(array_store)
  return array_store  
end

function _get_join_query(x::Tuple{Pair{String, Int64}, Vararg{Pair{String, Int64}}}; array_store::Vector{String} = String[])
  array = String[]
  for (k,v) in x
    push!(array, k)
  end
  _get_join_query(array, array_store=array_store)  
end
function _get_join_query(x::Tuple{String, Vararg{String}}; array_store::Vector{String} = String[])
  array = String[]
  for v in x
    push!(array, v)
  end
  _get_join_query(array, array_store=array_store)  
end
function _get_join_query(x::Dict{String,Union{Int64, String}}; array_store::Vector{String} = String[])
  array = String[]
  for (k,v) in x
    push!(array, k)
  end
  _get_join_query(array, array_store=array_store)  
end

function _get_alias_name(df::DataFrames.DataFrame)
  array = vcat(df.alias_a, df.alias_b)
  count = 1
  while true
    alias_name = "tb_" * string(count) # TODO maybe when exist more then one sql, the alias must be different
    if !in(alias_name, array)
      return alias_name
    end
    count += 1
  end
end
function _get_alias_name(row_join::Vector{Dict{String, Any}})
  array = vcat([r["alias_a"] for r in row_join], [r["alias_b"] for r in row_join])
  count = 1
  while true
    alias_name = "tb_" * string(count) # TODO maybe when exist more then one sql, the alias must be different
    if !in(alias_name, array)
      return alias_name
    end
    count += 1
  end
end

function _insert_join(df::DataFrames.DataFrame, row::Dict{String,String})
  check = DataFrames.subset(df, DataFrames.AsTable([:a, :b, :key_a, :key_b]) => ( @. r -> 
  (r.a == row["a"]) && (r.b == row["b"]) && (r.key_a == row["key_a"]) && (r.key_b == row["key_b"])) )

  # check = filter(r -> r.a == row["a"] && r.b == row["b"] && r.key_a == row["key_a"] && r.key_b == row["key_b"], df)
  # subset(df, :alias_b)
  if size(check, 1) == 0
    push!(df, (row["a"], row["b"], row["key_a"], row["key_b"], row["how"], row["alias_b"], row["alias_a"]))
    return row["alias_b"]
  else
    if size(check, 1) > 1
      throw("Error in join")
    end
    return check[1, :alias_b]  
  end
end
function _insert_join(row_join::Vector{Dict{String, Any}}, row::Dict{String,String})
  if size(row_join, 1) == 0
    push!(row_join, row)
    return row["alias_b"]
  else
    check = filter(r -> r["a"] == row["a"] && r["b"] == row["b"] && r["key_a"] == row["key_a"] && r["key_b"] == row["key_b"], row_join)
    if size(check, 1) == 0
      push!(row_join, row)
      return row["alias_b"]
    else
      if size(check, 1) > 1
        throw("Error in join")
      end
      return check[1]["alias_b"]  
    end
  end
end
  

"build a row to join"
function _build_row_join(field::Vector{SubString{String}}, instruct::SQLInstruction; as::Bool=true)
  # convert the field to a vector of string
  vector = String.(field)
  _build_row_join(vector, instruct, as=as)  
end
function _build_row_join(field::Vector{String}, instruct::SQLInstruction; as::Bool=true)
  vector = copy(field) 
  # println(vector)
  foreign_table_name::Union{String, PormGModel, Nothing} = nothing
  foreing_table_module::Module = instruct.object.model_name._module::Module
  row_join = Dict{String,String}()
  # println(vector)

  # fields_model = instruct.object.model_name.field_names
  # println(fields_model)
  last_column::String = ""

  println(instruct.object.model_name.reverse_fields)
  
  if vector[1] in instruct.object.model_name.field_names # vector moust be a field from the model
    last_column = vector[1]
    row_join["a"] = instruct.object.model_name.name
    row_join["alias_a"] = "tb" # TODO maybe when exist more then one sql, the alias must be different
    how = instruct.object.model_name.fields[vector[1]].how
    if how === nothing
      row_join["how"] = instruct.object.model_name.fields[vector[1]].null == "YES" ? "LEFT" : "INNER"
    else
      row_join["how"] = how
    end
    foreign_table_name = instruct.object.model_name.fields[vector[1]].to
    if foreign_table_name === nothing
      throw("Error in _build_row_join, the column $(vector[1]) does not have a foreign key")
    elseif isa(foreign_table_name, PormGModel)
      row_join["b"] = foreign_table_name.table_name
    else
      row_join["b"] = foreign_table_name
    end
    # row_join["alias_b"] = _get_alias_name(instruct.df_join) # TODO chage by row_join and test the speed
    row_join["alias_b"] = _get_alias_name(instruct.row_join)
    row_join["key_b"] = instruct.object.model_name.fields[vector[1]].pk_field::String
    row_join["key_a"] = vector[1]
  elseif haskey(instruct.object.model_name.reverse_fields, vector[1])
    reverse_model = getfield(foreing_table_module, instruct.object.model_name.reverse_fields[vector[1]][3])
    length(vector) == 1 && throw("Error in _build_row_join, the column $(vector[1]) is a reverse field, you must inform the column to be selected. Example: ...filter(\"$(vector[1])__column\")")
    # !(vector[2] in reverse_model.field_names) && throw("Error in _build_row_join, the column $(vector[2]) not found in $(reverse_model.table_name)")
    last_column = vector[2]
    row_join["a"] = instruct.object.model_name.name
    row_join["alias_a"] = "tb" # TODO maybe when exist more then one sql, the alias must be different
    how = reverse_model.fields[instruct.object.model_name.reverse_fields[vector[1]][1] |> String].how
    if how === nothing
      row_join["how"] = instruct.object.model_name.fields[instruct.object.model_name.reverse_fields[vector[1]][4] |> String].null == "YES" ? "LEFT" : "INNER"
    else
      row_join["how"] = how
    end
    foreign_table_name = instruct.object.model_name.reverse_fields[vector[1]][3] |> String
    if foreign_table_name === nothing
      throw("Error in _build_row_join, the column $(foreign_table_name) does not have a foreign key")
    elseif isa(foreign_table_name, PormGModel)
      row_join["b"] = foreign_table_name.table_name
    else
      row_join["b"] = foreign_table_name
    end

    row_join["alias_b"] = _get_alias_name(instruct.row_join)
    row_join["key_b"] = instruct.object.model_name.reverse_fields[vector[1]][1] |> String
    row_join["key_a"] = instruct.object.model_name.reverse_fields[vector[1]][4] |> String
  else
    throw("Error in _build_row_join, the column $(vector[1]) not found in $(instruct.df_object.table_name)")
  end
  
  # println(row_join)
  # println(instruct.row_join)
  vector = vector[2:end]  

  tb_alias = _insert_join(instruct.row_join, row_join)
  functions = []
  while size(vector, 1) > 1
    println(foreign_table_name)
    println(vector)
    row_join2 = Dict{String,String}()
    # get new object
    new_object = getfield(foreing_table_module, foreign_table_name |> Symbol)
    println(new_object.reverse_fields)
    println(new_object.field_names)

    if vector[1] in new_object.field_names
      !("to" in new_object.field_names) && throw("Error in _build_row_join, the column $(vector[1]) is a field from $(new_object.name), but this field has not a foreign key")
      println(new_object.fields[vector[1]])
      last_column = vector[2]
      row_join2["a"] = row_join["b"]
      row_join2["alias_a"] = tb_alias
      how = new_object.fields[vector[1]].how
      if how === nothing
        row_join2["how"] = new_object.fields[vector[1]].null == "YES" ? "LEFT" : "INNER"
      else
        row_join2["how"] = how
      end
      foreign_table_name = new_object.fields[vector[1]].to
      if foreign_table_name === nothing
        throw("Error in _build_row_join, the column $(vector[2]) does not have a foreign key")
      elseif isa(foreign_table_name, PormGModel)
        row_join2["b"] = foreign_table_name.table_name
      else
        row_join2["b"] = foreign_table_name
      end
      row_join2["alias_b"] = _get_alias_name(instruct.row_join) # TODO chage by row_join and test the speed
      row_join2["key_b"] = new_object.fields[vector[1]].pk_field::String
      row_join2["key_a"] = vector[1]
      tb_alias = _insert_join(instruct.row_join, row_join2)
    
    elseif haskey(new_object.reverse_fields, vector[1])
      reverse_model = getfield(foreing_table_module, new_object.reverse_fields[vector[1]][3])
      length(vector) == 1 && throw("Error in _build_row_join, the column $(vector[1]) is a reverse field, you must inform the column to be selected. Example: ...filter(\"$(vector[1])__column\")")
      !(vector[2] in reverse_model.field_names) && throw("Error in _build_row_join, the column $(vector[2]) not found in $(reverse_model.table_name)")
      last_column = vector[2]
      row_join2["a"] = row_join["b"]
      row_join2["alias_a"] = tb_alias
      how = reverse_model.fields[new_object.reverse_fields[vector[1]][1] |> String].how
      if how === nothing
        row_join2["how"] = new_object.fields[new_object.reverse_fields[vector[1]][4] |> String].null == "YES" ? "LEFT" : "INNER"
      else
        row_join2["how"] = how
      end
      foreign_table_name = new_object.reverse_fields[vector[1]][3] |> String
      if foreign_table_name === nothing
        throw("Error in _build_row_join, the column $(foreign_table_name) does not have a foreign key")
      elseif isa(foreign_table_name, PormGModel)
        row_join2["b"] = foreign_table_name.table_name
      else
        row_join2["b"] = foreign_table_name
      end

      row_join2["alias_b"] = _get_alias_name(instruct.row_join)
      row_join2["key_b"] = new_object.reverse_fields[vector[1]][1] |> String
      row_join2["key_a"] = new_object.reverse_fields[vector[1]][4] |> String
      tb_alias = _insert_join(instruct.row_join, row_join2)
      vector = vector[2:end]

    else
      println(field)
      throw("Error in _build_row_join, the column $(vector[1]) not found in $(new_object.name)")
    end
    vector = vector[2:end]
  end

  # tb_alias is the last table alias in the join ex. tb_1
  # last_column is the last column in the join ex. last_login
  # vector is the full path to the column ex. user__last_login__date (including functions (except the suffix))

  # check if last_column a field from the model
  println(last_column)
  new_model = getfield(foreing_table_module, foreign_table_name |> Symbol)
  if !(last_column in new_model.field_names)
    throw("Error in _build_row_join, the column $(last_column) not found in $(new_model.table_name)")
  end


  # functions must be processed here
  text = string(tb_alias, ".", last_column)
  while size(functions, 1) > 0
    function_name = functions[end]      
    text = getfield(QueryBuilder, Symbol(PormGtrasnform[string(function_name)]))(text)
    functions = functions[1:end-1]
  end

  if as
    return string(text, " as ", join(field, "__"))
  else
    # println("as false")
    # println(text)
    return text
  end      
  
end

# outher functions
function _df_to_dic(df::DataFrames.DataFrame, column::String, filter::String)
  column = Symbol(column)
  loc = DataFrames.subset(df, DataFrames.AsTable([column]) => ( @. x -> x[column] == filtro) )
  if size(loc, 1) == 0
    throw("Error in _df_to_dic, $(filter) not found in $(column)")
  elseif size(loc, 1) > 1
    throw("Error in _df_to_dic, $(filter) found more than one time in $(column)")
  else 
    return loc[1, :]
  end
end


#PostgreSQL
function TO_CHAR(column::String, format::String)
  return "to_char($(column), '$(format)')"
end
MONTH(x) = TO_CHAR(x, "MM")
YEAR(x) = TO_CHAR(x, "YYYY")
DAY(x) = TO_CHAR(x, "DD")
Y_M(x) = TO_CHAR(x, "YYYY-MM")
DATE(x) = TO_CHAR(x, "YYYY-MM-DD")


function ISNULL(v::String , value::Bool)
  if contains(v, "(")
    throw("Error in ISNULL, the column $(v) can't be a function")
  end
  if value
    return string(v, " IS NULL")
  else
    return string(v, " IS NOT NULL")
  end
end
 


# APAGAR
# function get_select_query(object::SQLType, df::DataFrames.DataFrame)
#   values = []
#   # check if values contains PormGsuffix and throw error
#   for v in object.values
#     for (k, value) in PormGsuffix
#       if endswith(v, k)
#         throw("Error in values, $(v) contains $(k), that isn't allowed")
#       end
#     end
#   end

#   # colect a array wiht keys of PormGtrasnform
#   keys = []
#   for (k, value) in PormGtrasnform
#     push!(keys, replace(k, "__" => ""))
#   end

#   # check if values contains PormGtrasnform and transform
#   println(object.values)
#   for v in object.values
#     println(v)
#     parts = split(v, "__")
#     last = ""
#     value = []
#     text = ""
#     if size(parts, 1) > 1
#       for p in parts   
#         println(p)     
#         if !in(p, keys)
#           last = p 
#           push!(value, p)    
#         end
#         println(value)
#         if in(p, keys)
#           loc = _df_to_dic(df, "all", join(value, "__"))
#           println(loc)
#           text = getfield(QueryBuilder, Symbol(PormGtrasnform[string("__", p)]))(loc["last_alias"] * "." * last)            
#         end
#       end
#       if text == ""
#         loc = _df_to_dic(df, "all", join(value, "__"))
#         text = loc["last_alias"] * "." * last  
#       end
#       push!(values, Dict("text" => text, "value" => join(value, "__")))
#     else
#       text = string("tb", ".", v)
#       push!(values, Dict("text" => text, "value" => v))
#     end
    
#   end

#   return values

# end

# function get_filter_query(object::SQLType, df::DataFrames.DataFrame)
#   filter = []
#   # colect a array wiht keys of PormGtrasnform
#   keys = []
#   for (k, value) in PormGtrasnform
#     push!(keys, replace(k, "__" => ""))
#   end

#   # colect a array wiht keys of PormGsuffix
#   keys2 = []
#   for (k, value) in PormGsuffix
#     push!(keys2, replace(k, "__" => ""))
#   end

#   # check if values contains PormGtrasnform and transform
#   println(object.filter)
#   for (k, v) in object.filter
#     println(k)
#     parts = split(k, "__")
#     last = ""
#     value = []
#     text = ""
#     opr = "="
#     if size(parts, 1) > 1
#       for p in parts   
#         println(p)     
#         if !in(p, keys) && !in(p, keys2)
#           last = p 
#           push!(value, p)    
#         end
#         println(value)
#         if in(p, keys)
#           loc = _df_to_dic(df, "all", join(value, "__"))
#           println(loc)
#           text = getfield(QueryBuilder, Symbol(PormGtrasnform[string("__", p)]))(loc["last_alias"] * "." * last)            
#         end
#         if in(p, keys2)
#           opr = PormGsuffix[string("__", p)]
#         end
#       end
#       if text == ""
#         loc = _df_to_dic(df, "all", join(value, "__"))
#         text = loc["last_alias"] * "." * last * " " * opr * " '" * v * "'" 
#       else
#         text *= " " * opr * " '" * v * "'" 
#       end
#       push!(filter, Dict("text" => text, "value" => join(value, "__")))
#     else
#       text = string("tb", ".", k, " = '", v, "'")
#       push!(filter, Dict("text" => text, "value" => k))
#     end
    
#   end


#   return filter

  
# end


# select
function _get_select_query(v::String, instruc::SQLInstruction)
  # V does not have be suffix
  # println(v)
  parts = split(v, "__")  
  if size(parts, 1) > 1
    return _build_row_join(parts, instruc)
  else
    return string("tb", ".", v)    
  end
  
end
function _get_select_query(v::SQLTypeF, instruc::SQLInstruction)
  # println("foi")
  # println(v)
  value = _get_select_query(v.kwargs["column"], instruc)
  split_value = split(value, " as ")
  # println(split_value)
  return string(getfield(QueryBuilder, Symbol(v.function_name))(string(split_value[1]), v.kwargs["format"]), " as ", split_value[2], "__", lowercase(v.kwargs["format"]))
  # println(result)
  # return result
end

"""
  get_select_query(object::SQLType, instruc::SQLInstruction)

  Iterates over the values of the SQLType object and generates the SELECT query for the given SQLInstruction object.

  #### ALERT
  - This internal function is called by the `build` function.

  #### Arguments
  - `object::SQLType`: The SQLType object containing the values to be selected.
  - `instruc::SQLInstruction`: The SQLInstruction object to which the SELECT query will be added.
"""
function get_select_query(object::SQLType, instruc::SQLInstruction)
  for v in object.values    
    if isa(v, String)    
      push!(instruc.select, _get_select_query(v, instruc))      
    elseif isa(v, SQLTypeF)
      push!(instruc.select, _get_select_query(v, instruc))    
    else
      throw("Error in values, $(v) is not a SQLTypeF or String")
    end    
  end  
end


function _get_filter_query(v::String, instruc::SQLInstruction)
  # V does not have be suffix 
  parts = split(v, "__")  
  if size(parts, 1) > 1
    return _build_row_join(parts, instruc, as=false)
  else
    return string("tb", ".", v)    
  end
  
end
function _get_filter_query(v::SQLTypeF, instruc::SQLInstruction)
  # println("foi SQLTypeF")
  value = _get_filter_query(v.kwargs["column"], instruc)
  return getfield(QueryBuilder, Symbol(v.function_name))(string(value[1]), v.kwargs["format"]) 
end
function _get_filter_query(v::SQLTypeOper, instruc::SQLInstruction)
  # println("foi SQLTypeOper")
  column = _get_filter_query(v.column, instruc)
  # println(column)
  if isa(v.values, String)
    value = "'" * v.values * "'"
  else
    value = string(v.values)
  end
  if v.operator in ["=", ">", "<", ">=", "<=", "<>", "!="]   
    return string(column, " ", v.operator, " ", value)
  elseif v.operator in ["in", "not in"]
    return string(column, " ", v.operator, " (", join(value, ", "), ")")
  elseif v.operator in ["ISNULL"]
    return getfield(QueryBuilder, Symbol(v.operator))(column, v.values)
  else
    throw("Error in operator, $(v.operator) is not a valid operator")
  end
end
function _get_filter_query(q::SQLTypeQ, instruc::SQLInstruction)
  # println("foi SQLTypeQ")
  resp = []
  for v in q.filters
    push!(resp, _get_filter_query(v, instruc))
  end
  return "(" * join(resp, " AND ") * ")"
end
function _get_filter_query(q::SQLTypeQor, instruc::SQLInstruction)
  resp = []
  for v in q.or
    push!(resp, _get_filter_query(v, instruc))
  end
  return "(" * join(resp, " OR ") * ")"
end


"""
  get_filter_query(object::SQLType, instruc::SQLInstruction)

  Iterates over the filter of the SQLType object and generates the WHERE query for the given SQLInstruction object.

  #### ALERT
  - This internal function is called by the `build` function.

  #### Arguments
  - `object::SQLType`: The SQLType object containing the filter to be selected.
  - `instruc::SQLInstruction`: The SQLInstruction object to which the WHERE query will be added.
"""
function get_filter_query(object::SQLType, instruc::SQLInstruction)::Nothing 
  [isa(v, Union{SQLTypeQor, SQLTypeQ, SQLTypeOper}) ? push!(instruc._where, _get_filter_query(v, instruc)) : throw("Error in values, $(v) is not a SQLTypeQor, SQLTypeQ or SQLTypeOper") for v in object.filter]

  return nothing
end



function build_row_join_sql_text(instruc::SQLInstruction)
  # for row in eachrow(instruc.df_join)
  #   push!(instruc.join, """ $(row.how) JOIN $(row.b) $(row.alias_b) ON $(row.alias_a).$(row.key_a) = $(row.alias_b).$(row.key_b) """)
  # end
  # println(instruc.row_join)
  for value in instruc.row_join
    push!(instruc.join, """ $(value["how"]) JOIN $(value["b"]) $(value["alias_b"]) ON $(value["alias_a"]).$(value["key_a"]) = $(value["alias_b"]).$(value["key_b"]) """)
  end
end


end

