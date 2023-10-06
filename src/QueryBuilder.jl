module QueryBuilder

using ..PormG: SQLType, SQLConn
import DataFrames

const PormGsuffix = Dict{String,Union{Int64, String}}(
  "__gte" => ">=",
  "__gt" => ">",
  "__lte" => "<=",
  "__lt" => "<",
)

const PormGtrasnform = Dict{String,Union{Int64, String}}(
  "__date" => "date",
  "__month" => "month",
  "__year" => "year",
  "__day" => "day",
  "__contains" => "contains",
  "__y_month" => "y_month",
)

println(typeof(SQLType))

function _get_join_query(array::Vector{String}; array_store::Vector{String}=String[])
  for i in size(array, 1)
    # v = array[i]
    for (k, value) in PormGsuffix
      if endswith(array[i], k)
        array[i] = array[i][1:end-length(k)]          
      end
    end
    for (k, value) in PormGtrasnform
      # println(endswith(array[i], k))
      if endswith(array[i], k)          
        array[i] = array[i][1:end-length(k)]  
        # println(array[i])        
      end
    end
  end
  # how join to Vector

  append!(array_store, array)
  unique!(array_store)
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

function _df_to_dict(df::DataFrames.DataFrame; column_name::SubString{String}="table_name")
  df = filter(row -> row.column_name == column_name, df)

  columns = names(df)
  c = Dict()
  for k in columns
    c[k] = df[1, k]
  end
  
  return c
end

function get_join_query(object::SQLType, config::SQLConn)
  

    joins = _get_join_query(object.values)
    joins = _get_join_query(object.filter, array_store=joins)

    println(joins)
   
    df = DataFrames.DataFrame(all=joins)
    df.first = map(v -> contains(v, "__") ?  split(v, "__")[1] : missing, df.all)
    df.last = map(v -> contains(v, "__") ?  split(v, "__")[end] : missing, df.all)
    df.size = map(v -> contains(v, "__") ?  size(split(v, "__"), 1) - 1 : 0, df.all)

    println(df)

    # println(config.columns)
    df_object = filter(row -> row.table_name == object.model_name, config.columns)
    println(df_object)

    table = []
    for row in eachrow(df)
      if row.size == 0
        push!(table, "tb")
      else
        dict_types = _df_to_dict(df_object, column_name=row.first)
        is_nullable = dict_types["is_nullable"] == "YES" ? true : false
        table_name = dict_types["table_name"]
        
      end
    end



  return df
end
  

end