module QueryBuilder

using ..PormG: SQLType
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
)

println(typeof(SQLType))

function get_on_query(object::SQLType)
  if length(object.values) > 0
    df = DataFrames.DataFrame(origem=String[], fim=String[], join=Union{Missing, Int64}[])

    for v in object.values
      transform = missing
      comp = missing      
      for (k, value) in PormGsuffix
        if endswith(v, k)
          v = v[1:end-length(k)]          
        end
      end
      for (k, value) in PormGtrasnform
        if endswith(v, k)          
          v = v[1:end-length(k)]          
        end
      end
      columns = split(v, "__")    

      if length(columns) > 1
        push!(df, [v, columns[end], missing])
      else
        push!(df, [v, v, missing])
      end
    end

    for v in object.filter        
      for (k, value) in PormGsuffix
        if endswith(v, k)
          v = v[1:end-length(k)]          
        end
      end
      for (k, value) in PormGtrasnform
        if endswith(v, k)          
          v = v[1:end-length(k)]          
        end
      end
      columns = split(v, "__")    
      
      if size(filter(r -> r.origem == v, df), 1) == 0
        if length(columns) > 1
          push!(df, [v, columns[end], missing])
        else
          push!(df, [v, v, missing])
        end
      end

    end


  end
  return df
end
  

end