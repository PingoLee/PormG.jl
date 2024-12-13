module QueryBuilder

import ..PormG: config, SQLType, SQLConn, SQLInstruction, SQLTypeF, SQLTypeOper, SQLTypeQ, SQLTypeQor, SQLObject, SQLTypeText, SQLTypeField, SQLTypeArrays, PormGsuffix, PormGtrasnform, PormGModel, Dialect, PormGField, CONNECTIONS
import DataFrames
import Dates, Intervals
import ..PormG.Models: CharField, IntegerField
using SQLite, LibPQ

#
# SQLTypeArrays Objects
#
@kwdef mutable struct SQLArrays <: SQLTypeArrays
  count::Int64 = 1
  array_string::Array{String, 2} = Array{String, 2}(undef, 20, 3)
  array_int::Array{Int64, 2} = Array{Int64, 2}(undef, 20, 3)
end

#
# SQLInstruction Objects (instructions to build a query)
#
@kwdef mutable struct InstrucObject <: SQLInstruction
  text::String # text to be used in the query
  object::SQLType
  select::Vector{SQLTypeField} = Array{SQLTypeField, 1}(undef, 60)
  agregate::Array{String, 2} = Array{String, 2}(undef, 10, 3)
  join::Vector{String} = []  # values to be used in join query
  _where::Vector{String} = []  # values to be used in where query
  group::Vector{String} = []  # values to be used in group query
  having::Vector{String} = [] # values to be used in having query
  order::Vector{String} = [] # values to be used in order query  
  df_join::Union{Missing, DataFrames.DataFrame} = missing # dataframe to be used in join query
  row_join::Vector{Dict{String, Any}} = [] # array of dictionary to be used in join query
  array_join::Array{String, 2} = Array{String, 2}(undef, 30, 8) # array to be used in join query (meaby the best way to do this)
  connection::Union{SQLite.DB, LibPQ.LibPQ.Connection, Nothing} = nothing
  array_defs::SQLTypeArrays = SQLArrays()
  cache::Dict{String, SQLTypeField} = Dict{String, SQLTypeField}()
  django::Bool = false

end

# Return a value to sql query, like value from DjangoSQLText
mutable struct SQLText <: SQLTypeText
  field::String
  _as::Union{String, Nothing}
end
SQLText(field::String; _as::Union{String, Nothing} = nothing) = SQLText(field, _as)
Base.copy(x::SQLTypeText) = SQLTypeText(x.field, x._as)


# Return a field to sql query
mutable struct SQLField <: SQLTypeField
  field::Union{SQLTypeText, SQLTypeF, String}
  _as::Union{String, Nothing}
end
SQLField(field::String; _as::Union{String, Nothing} = nothing) = SQLField(field, _as)
Base.copy(x::SQLTypeField) = SQLField(x.field, x._as)
#
# SQLType Objects (main object to build a query)
#

mutable struct SQLQuery <: SQLType
  model_name::PormGModel
  values::Vector{Union{SQLTypeText, SQLTypeField}}
  filter::Vector{Union{SQLTypeQ, SQLTypeQor, SQLTypeOper}}
  create::Dict{String,Union{Int64, String}}
  limit::Int64
  offset::Int64
  order::Vector{String}
  group::Vector{String}
  having::Vector{String}
  list_joins::Vector{String} # is ther a better way to do this?
  row_join::Vector{Dict{String, Any}}  

  SQLQuery(; model_name=nothing, values = [],  filter = [], create = Dict(), limit = 0, offset = 0,
        order = [], group = [], having = [], list_joins = [], row_join = []) =
    new(model_name, values, filter, create, limit, offset, order, group, having, list_joins, row_join)
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
  column::Union{SQLTypeField, SQLTypeF, String, Vector{String}} # Vector{String} is need 
end
OP(column::String, value) = OperObject(operator = "=", values = value, column = SQLField(column))
OP(column::SQLTypeF, value) = OperObject(operator = "=", values = value, column = column)
OP(column::String, operator::String, value) = OperObject(operator = operator, values = value, column = SQLField(column))
OP(column::SQLTypeF, operator::String, value) = OperObject(operator = operator, values = value, column = column)

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
  column::Union{String, SQLTypeField, N, Vector{N}, Vector{String}, SQLTypeOper, Vector{M}} where {N <: SQLTypeF, M <: SQLType}
  agregate::Bool = false
  _as::Union{String, Nothing} = nothing
  kwargs::Dict{String, Any} = Dict{String, Any}()
end

function Sum(x)
  return FObject(function_name = "SUM", column = x, agregate = true)
end  
function Avg(x)
  return FObject(function_name = "AVG", column = x, agregate = true)
end
function Count(x)
  return FObject(function_name = "COUNT", column = x, agregate = true)
end
function Max(x)
  return FObject(function_name = "MAX", column = x, agregate = true)
end
function Min(x)
  return FObject(function_name = "MIN", column = x, agregate = true)
end
function Value(x::String)
  return SQLText(x)
end

function Cast(x::Union{String, SQLTypeText, SQLTypeF}, type::String)
  return FObject(function_name = "CAST", column = x, kwargs = Dict{String, Any}("type" => type))
end
function Cast(x::Union{String, SQLTypeText, SQLTypeF}, type::PormGField)
  return Cast(x, type.type)
end
function Concat(x::Union{Vector{String}, Vector{N}} where N <: SQLType; output_field::Union{N, String, Nothing} where N <: PormGField = nothing, _as::String="")
  if isa(output_field, PormGField)
    output_field = output_field.type
  end
  return FObject(function_name = "CONCAT", column = x, kwargs = Dict{String, Any}("output_field" => output_field, "as" => _as))
end
function Extract(x, format::String)
  return FObject(function_name = "EXTRACT", column = x, kwargs = Dict{String, Any}("format" => format))
end
function When(x; then::Union{String, Int64, Bool, SQLTypeF} = 0, _else::Union{String, Int64, Bool, SQLTypeF, Missing} = missing)
  return FObject(function_name = "WHEN", column = x, kwargs = Dict{String, Any}("then" => then, "else" => _else))
end
function Case(conditions::Vector{N} where N <: SQLTypeF; _else::Any = "NULL", output_field::Union{N, String, Nothing} where N <: PormGField = nothing)
  if isa(output_field, PormGField)
    output_field = output_field.type
  end  
  return FObject(function_name = "CASE", column = conditions, kwargs = Dict{String, Any}("else" => _else, "output_field" => output_field)) 
end
# function When(condition::Vector{Union{SQLTypeQ, SQLTypeQor}}; then::Vector{Union{String, Int64, Bool, SQLTypeF}} = [], else_result::Union{String, Int64, Bool, SQLTypeF, Missing} = missing)
#   return FObject(function_name = "WHEN", column = x, kwargs = Dict{String, Any}("condition" => condition, "then" => then, "else_result" => else_result))
# end
# function When(condition::Union{SQLTypeQ, SQLTypeQor}; then::Union{String, Int64, Bool, SQLTypeF} = 1, else_result::Union{String, Int64, Bool, SQLTypeF, Missing} = missing)
#   return FObject(function_name = "WHEN", column = x, kwargs = Dict{String, Any}("condition" => [condition], "then" => [then], "else_result" => else_result))
# end

Extract_date(x::Union{String, SQLTypeF, Vector{String}}, format::String) = FObject(function_name = "EXTRACT_DATE", column = x, kwargs = Dict{String, Any}("format" => format))
MONTH(x) = Extract_date(x, "MM")
YEAR(x) = Extract_date(x, "YYYY")
DAY(x) = Extract_date(x, "DD")
Y_M(x) = Extract_date(x, "YYYY-MM")
DATE(x) = Extract_date(x, "YYYY-MM-DD")
# Same that function CAST in django ORM
# # relatorio = relatorio.annotate(quarter=functions.Concat(functions.Cast(f'{data}__year', CharField()), Value('-Q'), Case(
# # 					When(**{ f'{data}__month__lte': 4 }, then=Value('1')),
# # 					When(**{ f'{data}__month__lte': 8 }, then=Value('2')),
# # 					When(**{ f'{data}__month__lte': 12 }, then=Value('3')),
# # 					output_field=CharField()
# # 				)))
QUARTER(x) = Concat([
                Cast(YEAR(x), CharField()), 
                Value("-Q"), 
                Case([When(OP(MONTH(x), "<=", 4), then = 1), 
                      When(OP(MONTH(x), "<=", 8), then = 2), 
                      When(OP(MONTH(x), "<=", 12), then = 3)
                      ], 
                      output_field = CharField())
                ], 
                output_field = CharField(), 
                _as = "$(x[1])__quarter")



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

#
# Build the object
#

# Why Vector{String}
"Agora eu tenho que ver como que eu padronizo todas as variáveis para sair como SQLTypeField"
function up_values!(q::SQLType, values::NTuple{N, Union{String, Symbol, SQLTypeF, SQLTypeText, SQLTypeField}} where N)
  # every call of values, reset the values
  q.values = []
  for v in values 
    isa(v, Symbol) && (v = String(v))
    if isa(v, SQLTypeText) || isa(v, SQLTypeField)
      push!(q.values, _check_function(v))
    elseif isa(v, SQLTypeF)
      push!(q.values, SQLField(_check_function(v), v._as))
    elseif isa(v, String)
      check = String.(split(v, "__@"))
      if size(check, 1) == 1
        push!(q.values, SQLField(v, v))
      elseif haskey(PormGsuffix, check[end])
        throw("Invalid argument: $(v) does not must contain operators (lte, gte, contains ...)")
      else    
        push!(q.values, SQLField(_check_function(check), join(check, "__")))
      end     
    else
      throw("Invalid argument: $(v) (::$(typeof(v)))); please use a string or a function (Mounth, Year, Day, Y_M ...)")
    end    
  end 
  
  return q
end
function up_values!(q::SQLType, values::NTuple{N, Union{Pair, Int }} where N)
  @error "Invalid argument: $(values) (::$(typeof(values))); please use a string or a function (Mounth, Year, Day, Y_M ...)"
end
  
function up_create!(q::SQLType, values::Tuple{Pair{String, Int64}, Vararg{Pair{String, Int64}}})
  for (k,v) in values   
    q.values[k] = v 
  end
  return q
end

function up_filter!(q::SQLType, filter)
  for v in filter
    if isa(v, SQLTypeQ) || isa(v, SQLTypeQor) 
      push!(q.filter, v) # TODO I need process the Qor and Q with _check_filter
    elseif isa(v, Pair)
      push!(q.filter, _check_filter(v))
    else
      error("Invalid argument: $(v) (::$(typeof(v)))); please use a pair (key => value) or a Q(key => value...) or a Qor(key => value...)")
    end
  end
  return q
end

function _query_select(array::Vector{SQLTypeField})
  typeof(array) |> println
  println(array)
  println(size(array, 1))
  if !isassigned(array, 1, 1)
    return "*"
  else
    colect = []
    for i in 1:size(array, 1)     
      if !isassigned(array, i, 1)
        return join(colect,  ", \n  ")
      else
        push!(colect, "$(array[i, 1].field) as $(array[i, 1]._as)")
      end
    end
  end   
end

function query(q::SQLType)
  instruction = build(q) 
  println("$(instruction._where |> length > 0 ? "WHERE" : "")")
  respota = """ Query returned:
    SELECT
      $(_query_select(instruction.select ))
    FROM $(q.model_name.name) as tb
    $(join(instruction.join, "\n"))
    $(instruction._where |> length > 0 ? "WHERE" : "") $(join(instruction._where, " AND \n   "))
    """
  @info respota
  # return respota
end
  
Base.@kwdef mutable struct Object <: SQLObject
  object::SQLType
  values::Function = (x...) -> up_values!(object, x) 
  filter::Function = (x...) -> up_filter!(object, x) 
  create::Function = (x...) -> up_create!(object, x) 
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

#
# Process the query entries to build the SQLQuery object
#

# talvez eu não precise dessa função no inicio, mas pode ser útil na hora de processar o query
# function _check_function(f::OperObject)
function _check_function(f::Vector{N} where N <: SQLType)
  r_v::Vector{SQLType} = []
  for v in f
    if isa(v, SQLTypeOper)
      push!(r_v, _check_filter(v))
    else
      push!(r_v, _check_function(v))
    end
  end
  return r_v
end
function _check_function(f::FObject)
  f.column = _check_function(f.column)
  return f
end
function _check_function(f::SQLTypeOper)
  f.column = _check_function(f.column)
  return f
end
function _check_function(f::SQLText)
  return f
end
function _check_function(x::Vector{String})  
  if length(x) == 1
    return x[1]
  else    
    if haskey(PormGtrasnform, x[end])
      resp = getfield(@__MODULE__, Symbol(PormGtrasnform[x[end]]))(x[1:end-1])   
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

  Converts a Pair object to an OperObject. If the Pair's key is a string, it checks if it contains an operator suffix (e.g. "__@gte", "__@lte") and returns an OperObject with the corresponding operator. If the key does not contain an operator suffix, it returns an OperObject with the "=" operator. If the key is not a string, it throws an error.

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
    return OperObject(operator = PormGsuffix[x.first[end]], values = x.second, column = SQLField(_check_function(x.first[1:end-1]), join(x.first[1:end-1], "__")))
  else    
    return OperObject(operator = "=", values = x.second, column = SQLField(_check_function(x.first), join(x.first, "__"))) # TODO, maybe I need to check if the column is valid and process the function before store
  end  
end

function _check_filter(x::Pair)
  # println(x)
  # println(typeof(x))
  if isa(x.first, String)
    check = String.(split(x.first, "__@"))
    return _get_pair_to_oper(check => x.second)  
  end
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
  println("_build_row_join")
  println(vector)
  foreign_table_name::Union{String, PormGModel, Nothing} = nothing
  foreing_table_module::Module = instruct.object.model_name._module::Module
  row_join = Dict{String,String}()
  # println(vector)

  # fields_model = instruct.object.model_name.field_names
  # println(fields_model)
  last_column::String = ""

  println(instruct.object.model_name.reverse_fields)
  println("fiels", instruct.object.model_name.fields)  
  if vector[1] in instruct.object.model_name.field_names # vector moust be a field from the model
    last_column = vector[1]
    row_join["a"] = instruct.object.model_name.name
    row_join["alias_a"] = "tb" # TODO maybe when exist more then one sql, the alias must be different
    how = instruct.object.model_name.fields[last_column].how
    if how === nothing
      row_join["how"] = instruct.object.model_name.fields[last_column].null == "YES" ? "LEFT" : "INNER"
    else
      row_join["how"] = how
    end
    foreign_table_name = instruct.object.model_name.fields[last_column].to
    if foreign_table_name === nothing
      throw("Error in _build_row_join, the column $(last_column) does not have a foreign key")
    elseif isa(foreign_table_name, PormGModel)
      row_join["b"] = foreign_table_name.table_name
    else
      row_join["b"] = foreign_table_name
    end
    # row_join["alias_b"] = _get_alias_name(instruct.df_join) # TODO chage by row_join and test the speed
    row_join["alias_b"] = _get_alias_name(instruct.row_join)
    row_join["key_b"] = instruct.object.model_name.fields[last_column].pk_field::String
    row_join["key_a"] = last_column
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
    throw("Error in _build_row_join, the column $(vector[1]) not found in $(instruct.object.model_name.name)")
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
  column = vector[end]
  println(column)
  new_model = getfield(foreing_table_module, foreign_table_name |> Symbol)
  println(new_model)
  if !(column in new_model.field_names)
    throw("Error in _build_row_join, the column $(vector[end]) not found in $(new_model.name): $(join(new_model.field_names, ", "))")
  end
  (instruct.django && hasfield(new_model.fields[column], :to)) && (column = string(column, "_id"))

  # functions must be processed here
  return string(tb_alias, ".", column) 
  
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

#
# Build the SQLInstruction object
#

# select
function _get_select_query(v::SQLText, instruc::SQLInstruction)  
  println("foi SQLText")
  return Dialect.VALUE(v.field, instruc.connection)
end
function _get_select_query(v::Vector{SQLType}, instruc::SQLInstruction)
  println("foi vector")
  resp = []
  for v in v
    push!(resp, _get_select_query(v, instruc))
  end
  return resp
end
# I think that is not the local to build the select query
function _get_select_query(v::String, instruc::SQLInstruction) # TODO I need Refactor the way to build the "tb" + "." + v
  println("foi string")
  println(v)
  println(instruc.select)
  parts = split(v, "__")  
  if size(parts, 1) > 1
    return _build_row_join(parts, instruc)
  else
    return string("tb", ".", v)    
  end 
  
end
function _get_select_query(v::SQLTypeOper, instruc::SQLInstruction)
  println("foi SQLTypeOper")
  column = _get_select_query(v.column, instruc)
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
function _get_select_query(v::SQLTypeF, instruc::SQLInstruction)  
  println("foi SQLTypeF")
  println(v) 
  println(v.kwargs)
  println(v.function_name)
  println(v.column |> typeof)
  value = getfield(Dialect, Symbol(v.function_name))(_get_select_query(v.column, instruc), v.kwargs, instruc.connection)
  println(value)
  return value # getfield(Dialect, Symbol(v.function_name))(_get_select_query(v.column, instruc), v.kwargs, instruc.connection)
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
function get_select_query(values::Vector{Union{SQLTypeText, SQLTypeField}}, instruc::SQLInstruction)
  for i in eachindex(values) # linear indexing
    v_copy = copy(values[i])
    # check if SQLTypeField exists in cache
    println(v_copy._as)
    println(typeof(v_copy))
    if haskey(instruc.cache, v_copy._as)
      instruc.select[i] = instruc.cache[v_copy]      
    else
      v_copy.field = _get_select_query(v_copy.field, instruc)
      instruc.select[i] = v_copy
      instruc.cache[v_copy._as] = instruc.select[i]
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
    text = getfield(Dialect, Symbol(PormGtrasnform[string(function_name)]))(text)
    functions = functions[1:end-1]
  end
end

function _get_filter_query(v::String, instruc::SQLInstruction)
  # V does not have be suffix
  contains(v, "@") && return _get_filter_query(split(v, "__@"), instruc)
  parts = split(v, "__")  
  if size(parts, 1) > 1
    return _build_row_join(parts, instruc, as=false)
  else
    # TODO I need Refactor the way to build the "tb" + "." + v (is important to check if the column is valid)

    return string("tb", ".", v)    
  end
  
end
# function _get_filter_query(v::SQLTypeF, instruc::SQLInstruction)
#   println("foi SQLTypeF")
#   return _get_select_query(v, instruc) 
# end
# function _get_filter_query(v::SQLTypeText, instruc::SQLInstruction)
#   println("foi SQLTypeText")
#   return _get_select_query(v, instruc)
# end
function _get_filter_query(v::SQLTypeField, instruc::SQLInstruction)
  println("foi SQLTypeField")
  # check if SQLTypeField exists in cache
  if haskey(instruc.cache, v._as)
    return instruc.cache[v._as]      
  else
    v_copy = copy(v)
    v_copy.field = _get_select_query(v_copy.field, instruc)
    instruc.cache[v_copy._as] = v_copy
    return v_copy.field
  end
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
  # [isa(v, Union{SQLTypeQor, SQLTypeQ, SQLTypeOper}) ? push!(instruc._where, _get_filter_query(v, instruc)) : throw("Error in values, $(v) is not a SQLTypeQor, SQLTypeQ or SQLTypeOper") for v in object.filter]
  for v in object.filter
    if isa(v, Union{SQLTypeQor, SQLTypeQ, SQLTypeOper})
      println("Loc: ", _get_filter_query(v, instruc))
      push!(instruc._where, _get_filter_query(v, instruc))
    else
      throw("Error in values, $(v) is not a SQLTypeQor, SQLTypeQ or SQLTypeOper")
    end
  end  
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

function build(object::SQLType)
  object.model_name.connect_key |> println
  connection = CONNECTIONS[object.model_name.connect_key]
  # println(connection)
  instruct = InstrucObject(text = "", 
    object = object,
    connection = connection,
    # df_join = DataFrames.DataFrame(a=String[], b=String[], key_a=String[], key_b=String[], how=String[], 
    # alias_b=String[], alias_a=String[]),
  )

   
  
  # df_sels, df_join, text_on = QueryBuilder.get_join_query(object, connection)
  
  get_select_query(object.values, instruct)
  get_filter_query(object, instruct)
  build_row_join_sql_text(instruct)

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

