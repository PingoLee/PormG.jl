module QueryBuilder

using ..PormG: SQLType, SQLConn, SQLInstruction, SQLTypeF, SQLTypeOper, SQLTypeQ, SQLTypeQor, SQLObject, PormGsuffix, PormGtrasnform
import DataFrames


println(typeof(SQLType))

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
    println(array[i])
  end
  
  # how join to Vector
  println(array)
  append!(array_store, array)
  unique!(array_store)
  println(array_store)
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
    alias_name = "tb_" * string(count)
    if !in(alias_name, array)
      return alias_name
    end
    count += 1
  end
end

function _insert_join(df::DataFrames.DataFrame, row::Dict{String,String})
  check = filter(r -> r.a == row["a"] && r.b == row["b"] && r.key_a == row["key_a"] && r.key_b == row["key_b"], df)
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

"build a row to join"
function _build_row_join(tables::Vector{SubString{String}}, instruct::SQLInstruction)
  println("_build_row_join")
  println(tables)
    df = filter(row -> row.column_name == tables[1], instruct.df_object)
    # check if A is the from table
    row_join = Dict{String,String}()
    if size(df, 1) != 0
      row_join["a"] = df[1, :table_name]
      row_join["alias_a"] = "tb"  
      row_join["how"] = df[1, :is_nullable] == "YES" ? "LEFT" : "INNER"   
      df2 = filter(row -> row.table_name == row_join["a"] && row.column_name == tables[1], instruct.df_pks)
      row_join["b"] = df2[1, :foreign_table_name]
      row_join["alias_b"] = _get_alias_name(instruct.df_join)
      row_join["key_b"] = df2[1, :foreign_column_name]
      row_join["key_a"] = tables[1]    
    else
      df = filter(row -> row.column_name == column_name, instruct.df_columns)
      if size(df, 1) != 0
        # construir o join inverso
      else
        throw("""The column $(tables[1]) not found in $(instruct.df_object.table_name) or $(instruct.df_columns.table_name)""")
      end
    end
  
    println("")
  
    println(row_join)
  
    last_alias = _insert_join(instruct.df_join, row_join)
    
    while size(tables, 1) > 2
      row_join2 = Dict{String,String}()
      df = filter(row -> row.table_name == row_join["b"] && row.column_name == tables[3], instruct.df_pks)
      if size(df, 1) != 0
        row_join2["a"] = row_join["b"]
        row_join2["alias_a"] = row_join["alias_b"]      
        row_join2["b"] = df[1, :foreign_table_name]
        row_join2["alias_b"] = _get_alias_name(instruct.df_join)
        row_join2["key_b"] = df[1, :foreign_column_name]
        row_join2["key_a"] = tables[2]
        df2 = filter(row -> row.table_name == row_join2["a"] && row.column_name == row_join2["key_a"], instruct.df_columns)
        row_join2["how"] = df2[1, :is_nullable] == "YES" ? "LEFT" : "INNER"
        last_alias =_insert_join(instruct.df_join, row_join)      
        tables = tables[2:end]
      else
        throw("""The column $(tables[3]) not found in $(instruct.df_object.table_name)""")
      end
    end
  
    return last_alias

  
end

# forma antiga
# function _build_row_join(tables::Vector{SubString{String}}, df_join::DataFrames.DataFrame, df_object::DataFrames.DataFrame, 
#   df_pks::DataFrames.DataFrame, df_columns::DataFrames.DataFrame)

#   df = filter(row -> row.column_name == tables[1], df_object)
#   # check if A is the from table
#   row_join = Dict{String,String}()
#   if size(df, 1) != 0
#     row_join["a"] = df[1, :table_name]
#     row_join["alias_a"] = "tb"  
#     row_join["how"] = df[1, :is_nullable] == "YES" ? "LEFT" : "INNER"   
#     df2 = filter(row -> row.table_name == row_join["a"] && row.column_name == tables[1], df_pks)
#     row_join["b"] = df2[1, :foreign_table_name]
#     row_join["alias_b"] = _get_alias_name(df_join)
#     row_join["key_b"] = df2[1, :foreign_column_name]
#     row_join["key_a"] = tables[1]    
#   else
#     df = filter(row -> row.column_name == column_name, df_columns)
#     if size(df, 1) != 0
#       # construir o join inverso
#     else
#       throw("""The column $(tables[1]) not found in $(df_object.table_name) or $(df_columns.table_name)""")
#     end
#   end

#   println("")

#   println(row_join)

#   last_alias = _insert_join(df_join, row_join)
  
#   while size(tables, 1) > 2
#     row_join2 = Dict{String,String}()
#     df = filter(row -> row.table_name == row_join["b"] && row.column_name == tables[3], df_pks)
#     if size(df, 1) != 0
#       row_join2["a"] = row_join["b"]
#       row_join2["alias_a"] = row_join["alias_b"]      
#       row_join2["b"] = df[1, :foreign_table_name]
#       row_join2["alias_b"] = _get_alias_name(df_join)
#       row_join2["key_b"] = df[1, :foreign_column_name]
#       row_join2["key_a"] = tables[2]
#       df2 = filter(row -> row.table_name == row_join2["a"] && row.column_name == row_join2["key_a"], df_columns)
#       row_join2["how"] = df2[1, :is_nullable] == "YES" ? "LEFT" : "INNER"
#       last_alias =_insert_join(df_join, row_join)      
#       tables = tables[2:end]
#     else
#       throw("""The column $(tables[3]) not found in $(df_object.table_name)""")
#     end
#   end

#   return last_alias
  
# end

function _build_row_join_sql_text(df::DataFrames.DataFrame)
  sql = """"""
  for row in eachrow(df)
    sql *= """ $(row.how) JOIN $(row.b) $(row.alias_b) ON $(row.alias_a).$(row.key_a) = $(row.alias_b).$(row.key_b) \n"""
  end
  return sql
end

"Substituir essa ideia está ultrapassada"
function get_join_query(object::SQLType, instruc::SQLInstruction, config::SQLConn)
  
    println("get_values")
    joins = _get_join_query(object.values)
    println("get_filter")
    joins = _get_join_query(object.filter, array_store=joins)

    println(joins)
   
    df = DataFrames.DataFrame(all=joins)
    df.first = map(v -> contains(v, "__") ?  split(v, "__")[1] : missing, df.all)
    df.last = map(v -> contains(v, "__") ?  split(v, "__")[end] : missing, df.all)
    df.size = map(v -> contains(v, "__") ?  size(split(v, "__"), 1) - 1 : 0, df.all)

    println(df)

    # println(config.pks)
    df_object = filter(row -> row.table_name == object.model_name, config.columns)
    # println(df_object)

    df_join = DataFrames.DataFrame(a=String[], b=String[], key_a=String[], key_b=String[], how=String[], 
      alias_b=String[], alias_a=String[])
    DataFrames.insertcols!(df, :last_alias => "") 
    for row in eachrow(df)
      if row.size > 0
        tables = split(row.all, "__")       
        row.last_alias = _build_row_join(tables, df_join, df_object, config.pk, config.columns)                     
      end
    end

    



  return df , df_join, _build_row_join_sql_text(df_join)
end


# outher functions
function _df_to_dic(df::DataFrames.DataFrame, column::String, filter::String)
  println(df)
  println(filter)
  loc = DataFrames.filter(row -> row[column] == filter, df)
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

function get_filter_query(object::SQLType, df::DataFrames.DataFrame)
  filter = []
  # colect a array wiht keys of PormGtrasnform
  keys = []
  for (k, value) in PormGtrasnform
    push!(keys, replace(k, "__" => ""))
  end

  # colect a array wiht keys of PormGsuffix
  keys2 = []
  for (k, value) in PormGsuffix
    push!(keys2, replace(k, "__" => ""))
  end

  # check if values contains PormGtrasnform and transform
  println(object.filter)
  for (k, v) in object.filter
    println(k)
    parts = split(k, "__")
    last = ""
    value = []
    text = ""
    opr = "="
    if size(parts, 1) > 1
      for p in parts   
        println(p)     
        if !in(p, keys) && !in(p, keys2)
          last = p 
          push!(value, p)    
        end
        println(value)
        if in(p, keys)
          loc = _df_to_dic(df, "all", join(value, "__"))
          println(loc)
          text = getfield(QueryBuilder, Symbol(PormGtrasnform[string("__", p)]))(loc["last_alias"] * "." * last)            
        end
        if in(p, keys2)
          opr = PormGsuffix[string("__", p)]
        end
      end
      if text == ""
        loc = _df_to_dic(df, "all", join(value, "__"))
        text = loc["last_alias"] * "." * last * " " * opr * " '" * v * "'" 
      else
        text *= " " * opr * " '" * v * "'" 
      end
      push!(filter, Dict("text" => text, "value" => join(value, "__")))
    else
      text = string("tb", ".", k, " = '", v, "'")
      push!(filter, Dict("text" => text, "value" => k))
    end
    
  end


  return filter

  
end


# select
function _get_select_query(v::String, instruc::SQLInstruction)
  for (k, value) in PormGsuffix
    if endswith(v, k)
      throw("Error in values, $(v) contains $(k), that isn't allowed in values")
    end
  end  

  println(v)
  parts = split(v, "__")  
  if size(parts, 1) > 1
    return string(_build_row_join(parts, instruc), ".", parts[end])
  else
    return string("tb", ".", v)    
  end
  
end
function _get_select_query(v::SQLTypeF, instruc::SQLInstruction)
  println("foi")
  println(v)
  value = _get_select_query(v.kwargs["column"], instruc)
  return getfield(QueryBuilder, Symbol(v.function_name))(value, v.kwargs["format"])
  # println(result)
  # return result
end

"""
get_select_query(object::SQLType, instruc::SQLInstruction)

Iterates over the values of the SQLType object and generates the SELECT query for the given SQLInstruction object.

# ALERT
- This internal function is called by the `build` function.

# Arguments
- `object::SQLType`: The SQLType object containing the values to be selected.
- `instruc::SQLInstruction`: The SQLInstruction object to which the SELECT query will be added.
"""
function get_select_query(object::SQLType, instruc::SQLInstruction)
  for v in object.values    
    if isa(v, String)    
      if count("__", v) > 0 # if exist join in values insert as alias
        push!(instruc.select, string(_get_select_query(v, instruc), " as ", v)) 
      else
        push!(instruc.select, _get_select_query(v, instruc))
      end
    elseif isa(v, SQLTypeF)
      push!(instruc.select, string(_get_select_query(v, instruc), " as ", v.kwargs["as"]))    
    else
      throw("Error in values, $(v) is not a SQLTypeF or String")
    end    
  end  
end

end

