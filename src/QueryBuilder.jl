module QueryBuilder

using ..PormG: SQLType, SQLConn, SQLInstruction, SQLTypeF, SQLTypeOper, SQLTypeQ, SQLTypeQor, SQLObject, PormGsuffix, PormGtrasnform, PormGModel
import DataFrames
import Dates, Intervals

#
# SQLInstruction Objects (instructions to build a query)
#

@kwdef mutable struct InstrucObject <: SQLInstruction
  text::String # text to be used in the query
  object::SQLType
  select::Vector{String}  # values to be used in select query
  join::Vector{String}  # values to be used in join query
  _where::Vector{String}  # values to be used in where query
  group::Vector{String}  # values to be used in group query
  having::Vector{String} # values to be used in having query
  order::Vector{String} # values to be used in order query  
  df_join::Union{Missing, DataFrames.DataFrame} = missing # dataframe to be used in join query
  row_join::Vector{Dict{String, Any}} = [] # dataframe to be used in join query
end

#
# SQLTypeOper Objects (operators from sql)
#

export OP

"""
  OperObject <: SQLTypeOper

  Mutable struct representing an SQL operator object for using in the filter and annotate.
  That is a internal function, please do not use it.

  # Fields
  - `operator::String`: the operator used in the SQL query.
  - `values::Union{String, Int64, Bool}`: the value(s) to be used with the operator.
  - `column::Union{String, SQLTypeF}`: the column to be used with the operator.

"""
@kwdef mutable struct OperObject <: SQLTypeOper
  operator::String
  values::Union{String, Int64, Bool}
  column::Union{String, SQLTypeF, Vector{String}}
end
OP(column::String, value) = OperObject(operator = "=", values = value, column = column)
OP(column::String, operator::String, value) = OperObject(operator = operator, values = value, column = column)

#
# SQLTypeQ and SQLTypeQor Objects
#

export Q, Qor

@kwdef mutable struct QObject <: SQLTypeQ
  filters::Vector{Union{SQLTypeOper, SQLTypeQ, SQLTypeQor}}
end

@kwdef mutable struct QorObject <: SQLTypeQor
  or::Vector{Union{SQLTypeOper, SQLTypeQ, SQLTypeQor}}
end

"""
  Q(x...)

  Create a `QObject` with the given filters.
  Ex.:
  ```julia
  a = object("tb_user")
  a.filter(Q("name" => "John", Qor("age" => 18, "age" => 19)))
  ```

  Arguments:
  - `x`: A list of key-value pairs or Qor(x...) or Q(x...) objects.

"""
function Q(x...)
  colect = [isa(v, Pair) ? _get_pair_to_oper(v) : isa(v, Union{SQLTypeQor, SQLTypeQ, SQLTypeOper}) ? v : throw("Invalid argument: $(v); please use a pair (key => value)") for v in x]
  return QObject(filters = colect)
end


"""
  Qor(x...)

  Create a `QorObject` from the given arguments. The `QorObject` represents a disjunction of `SQLTypeQ` or `SQLTypeQor` objects.

  Ex.:
  ```julia
  a = object("tb_user")
  a.filter(Qor("name" => "John", Q("age__gte" => 18, "age__lte" => 19)))
  ```

  # Arguments
  - `x...`: A variable number of arguments. Each argument can be either a `SQLTypeQ` or `SQLTypeQor` object, or a `Pair` object.

"""
function Qor(x...)
  colect = [isa(v, Pair) ? _get_pair_to_oper(v) : isa(v, Union{SQLTypeQor, SQLTypeQ, SQLTypeOper}) ? v : throw("Invalid argument: $(v); please use a pair (key => value)") for v in x]
  return QorObject(or = colect)
end

#
# SQLTypeF Objects (functions from sql)
#

export Sum, Avg, Count, Max, Min, When
@kwdef mutable struct FObject <: SQLTypeF
  function_name::String
  column::Union{String, SQLTypeF, Vector{String}}
  kwargs::Dict{String, Any}
end

function Sum(x)
  return FObject(function_name = "SUM", column = x)
end  
function Avg(x)
  return FObject(function_name = "AVG", column = x)
end
function Count(x)
  return FObject(function_name = "COUNT", column = x)
end
function Max(x)
  return FObject(function_name = "MAX", column = x)
end
function Min(x)
  return FObject(function_name = "MIN", column = x)
end
# function When(condition::Vector{Union{SQLTypeQ, SQLTypeQor}}; then::Vector{Union{String, Int64, Bool, SQLTypeF}} = [], else_result::Union{String, Int64, Bool, SQLTypeF, Missing} = missing)
#   return FObject(function_name = "WHEN", column = x, kwargs = Dict{String, Any}("condition" => condition, "then" => then, "else_result" => else_result))
# end
# function When(condition::Union{SQLTypeQ, SQLTypeQor}; then::Union{String, Int64, Bool, SQLTypeF} = 1, else_result::Union{String, Int64, Bool, SQLTypeF, Missing} = missing)
#   return FObject(function_name = "WHEN", column = x, kwargs = Dict{String, Any}("condition" => [condition], "then" => [then], "else_result" => else_result))
# end

export TO_CHAR

TO_CHAR(x::Union{String, SQLTypeF, Vector{String}}, format::String) = FObject(function_name = "TO_CHAR", column = x, kwargs = Dict{String, Any}("format" => format))
MONTH(x) = TO_CHAR(x, "MM")
YEAR(x) = TO_CHAR(x, "YYYY")
DAY(x) = TO_CHAR(x, "DD")
Y_M(x) = TO_CHAR(x, "YYYY-MM")
DATE(x) = TO_CHAR(x, "YYYY-MM-DD")


mutable struct SQLQuery <: SQLType
  model_name::PormGModel
  values::Vector{Union{String, SQLTypeF}}
  filter::Vector{Union{SQLTypeQ, SQLTypeQor, SQLTypeOper}}
  create::Dict{String,Union{Int64, String}}
  limit::Int64
  offset::Int64
  order::Vector{String}
  group::Vector{String}
  having::Vector{String}
  list_joins::Vector{String} # is ther a better way to do this?
  row_join::Vector{Dict{String, Any}}
  #distinct::Bool

  SQLQuery(; model_name=nothing, values = [],  filter = [], create = Dict(), limit = 0, offset = 0,
        order = [], group = [], having = [], list_joins = [], row_join = []) =
    new(model_name, values, filter, create, limit, offset, order, group, having, list_joins, row_join)
end

function _get_pair_list_joins(q::SQLType, v::Pair)
  push!(q.list_joins, v[1])
  unique!(q.list_joins)
end
function _get_pair_list_joins(q::SQLType, v::SQLTypeQ)
  for v in v.filters
    _get_pair_list_joins(q, v)
  end
end
function _get_pair_list_joins(q::SQLType, v::SQLTypeQor)
  for v in v.or
    _get_pair_list_joins(q, v)
  end
end

function up_values(q::SQLType, values::NTuple{N, Union{String, SQLTypeF, Vector{String}}} where N)
  # every call of values, reset the values
  q.values = []
  for v in values 
    if isa(v, SQLTypeF)
      push!(q.values, _check_function(v))
    elseif isa(v, String)
      check = String.(split(v, "__@"))
      if haskey(PormGsuffix, check[end])
        throw("Invalid argument: $(v) does not must contain operators (lte, gte, contains ...)")
      else     
        push!(q.values, _check_function(check))
      end     
    else
      throw("Invalid argument: $(v) (::$(typeof(v)))); please use a string or a function (TO_CHAR, Mounth, Year, Day, Y_M ...)")
    end    
  end 
  
  # return Object(object =q)
end
  
function up_create(q::SQLType, values::Tuple{Pair{String, Int64}, Vararg{Pair{String, Int64}}})
  for (k,v) in values   
    q.values[k] = v 
  end
end

function up_filter(q::SQLType, filter)
  for v in filter
    if isa(v, SQLTypeQ) || isa(v, SQLTypeQor) 
      push!(q.filter, v) # TODO I need process the Qor and Q with _check_filter
    elseif isa(v, Pair)
      push!(q.filter, _check_filter(v))
    else
      error("Invalid argument: $(v) (::$(typeof(v)))); please use a pair (key => value) or a Q(key => value...) or a Qor(key => value...)")
    end
  end
  return Object(object =q)
end


function query(q::SQLType)
  instruction = build(q) 
  respota = """ Query returned:
    SELECT
      $(length(instruction.select )> 0 ? join(instruction.select, ", \n  ") : "*" )
    FROM $(q.model_name.name) as tb
    $(join(instruction.join, "\n"))
    WHERE $(join(instruction._where, " AND \n   "))
    """
  @info respota
  # return respota
end
  
Base.@kwdef mutable struct Object <: SQLObject
  object::SQLType
  values::Function = (x...) -> up_values(object, x) 
  filter::Function = (x...) -> up_filter(object, x) 
  create::Function = (x...) -> up_create(object, x) 
  annotate::Function = (x...) -> annotate(object, x) 
  query::Function = () -> query(object)
end


export object

function object(model_name::PormGModel)
  return Object(object = SQLQuery(model_name = model_name))
end
# function object(model_name::String)
#   return object(getfield(Models, Symbol(model_name)))
# end
# function object(model_name::Symbol)
#   return object(getfield(Models, model_name))
# end
 


### string(q::SQLQuery, m::Type{T}) where {T<:AbstractModel} = to_fetch_sql(m, q)

# talvez eu não precise dessa função no inicio, mas pode ser útil na hora de processar o query
# function _check_function(f::OperObject)
function _check_function(f::FObject)
  f.column = _check_function(f.column)
  return f
end
function _check_function(x::Vector{String})
  if length(x) == 1
    return x[1]
  else    
    if haskey(PormGtrasnform, x[end])
      resp = getfield(PormG, Symbol(PormGtrasnform[x[end]]))(x[1:end-1])
      return _check_function(resp)
    else
      joined_keys_with_prefix = join(map(key -> " \e[32m@" * key, keys(PormGtrasnform) |> collect), "\n")
      if haskey(PormGsuffix, x[end])
        yes = "you can use \"column__@\e[32m$(x[end])\e[0m\""
        not = "you can not use \"column__\e[31m@$(x[end])__@function\e[0m\". valid functions are:\n$(joined_keys_with_prefix)\e[0m"
        throw(ArgumentError("\e[4m\e[31m$(x[end])\e[0m is not allowed.\n$yes\n$not"))
      else
        throw(ArgumentError("\"$(x[1])__\e[31m@$(x[end])\e[0m\" is invalid; please use a valid function:\n$(joined_keys_with_prefix)\e[0m"))
      end
    end
  end    
end
_check_function(x::String) = _check_function(String.(split(x, "__@")))


"""
  _get_pair_to_oper(x::Pair)

  Converts a Pair object to an OperObject. If the Pair's key is a string, it checks if it contains an operator suffix (e.g. "__gte", "__lte") and returns an OperObject with the corresponding operator. If the key does not contain an operator suffix, it returns an OperObject with the "=" operator. If the key is not a string, it throws an error.

  # Arguments
  - `x::Pair`: A Pair object to be converted to an OperObject.

  # Returns
  - `OperObject`: An OperObject with the corresponding operator and values.

  # Throws
  - `Error`: If the key is not a string or if it contains more than one operator suffix.

  # Wharning
  - That is a internal function, please do not use it.
"""
function _get_pair_to_oper(x::Pair{Vector{String}, T}) where T <: Union{String, Int64}
 if haskey(PormGsuffix, x.first[end])
    return OperObject(operator = PormGsuffix[x.first[end]], values = x.second, column = x.first[1:end-1])   
  else
    return OperObject(operator = "=", values = x.second, column = x.first)
  end  
end

function _check_filter(x::Pair)
  check = String.(split(x.first, "__@"))
  resp = _get_pair_to_oper(check => x.second)
  resp.column = _check_function(resp.column)
  return resp
end

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

function _get_filter_query(v::Vector{SubString{String}}, instruc::SQLInstruction, )
  # for loop from end to start exept the first
  v = String.(v)
  text = _build_row_join(v[1], instruc, as=false)
  i = 2
  to = size(v, 1)
  
  while i <= to
    function_name = functions[end]      
    text = getfield(QueryBuilder, Symbol(PormGtrasnform[string(function_name)]))(text)
    functions = functions[1:end-1]
  end
end

function _get_filter_query(v::String, instruc::SQLInstruction)
  # V does not have be suffix
  contains(v, "@") && return _get_filter_query(split(v, "_@"), instruc)
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

function build(object::SQLType; conection=config) 
  if ismissing(object.model_name )
    throw("""You new to set a object before build a query (ex. object("table_name"))""")
  end

  instruct = InstrucObject(text = "", 
    object = object,
    select = [], 
    join = [],
    _where = [],
    group = [],
    having = [],
    order = [],
    # df_join = DataFrames.DataFrame(a=String[], b=String[], key_a=String[], key_b=String[], how=String[], 
    # alias_b=String[], alias_a=String[]),
  )

   
  
  # df_sels, df_join, text_on = QueryBuilder.get_join_query(object, conection)
  
  QueryBuilder.get_select_query(object, instruct)
  QueryBuilder.get_filter_query(object, instruct)
  QueryBuilder.build_row_join_sql_text(instruct)

  # println("TESTE")
  # println(instruct.select)
  # println(instruct._where)
  # println(instruct.df_join)

  # filter = QueryBuilder.get_filter_query(object, df_sels)

  
  # text_values = [] 
  # for v in values
  #   push!(text_values, string(v["text"], " as ", v["value"]))
  # end

  # filter_Values = []
  # for v in filter
  #   push!(filter_Values, v["text"])
  # end
 
  # return """SELECT $(join(text_values, ", ")) FROM $(object.model_name) as tb $text_on WHERE $(join(filter_Values, " AND ")))"""

  return instruct
end
# function build(object::SQLType)
#   build(object, config)
# end


end

