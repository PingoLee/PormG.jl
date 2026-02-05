
mutable struct PgParameterizedQuery <: PormGPostgresParam
  sql::String
  parameters::Union{AbstractVector, Tuple}
  parameter_count::Int

  PgParameterizedQuery(sql::String, parameters::Union{AbstractVector, Tuple}, parameter_count::Int) = new(sql, parameters, parameter_count)
end
get_parameter(connection::PormGPostgres) = PgParameterizedQuery("", Any[], 0)

mutable struct SQLiteParameterizedQuery <: PormGSQLiteParam
  sql::String
  parameters::Union{AbstractVector, Tuple}
  parameter_count::Int
  
  SQLiteParameterizedQuery(sql::String, parameters::Union{AbstractVector, Tuple}, parameter_count::Int) = new(sql, parameters, parameter_count)
end
get_parameter(connection::PormGSQLite) = SQLiteParameterizedQuery("", Any[], 0)

function add_parameter!(pq::PormGPostgresParam, value::AbstractArray; contains::Bool = false)
  contains && (throw(ArgumentError("Contains option is not supported for array parameters")))
  pq.parameter_count += 1
  push!(pq.parameters, value)
  # push!(pq.parameters, "ANY(\$$(pq.parameter_count))")
  return "\$$(pq.parameter_count)"
end
function add_parameter!(pq::PormGPostgresParam, value; contains::Bool = false)::String
  contains && (value = string("%", value |> escape_like_pattern, "%"))  # Escape LIKE patterns if needed
  pq.parameter_count += 1
  push!(pq.parameters, value)
  return "\$$(pq.parameter_count)"  # PostgreSQL style
end
function add_parameter!(sq::PormGSQLiteParam, value::AbstractArray; contains::Bool = false)
  contains && (throw(ArgumentError("Contains option is not supported for array parameters")))
  sq.parameter_count += 1
  push!(sq.parameters, value)
  return "?$(sq.parameter_count)"
end
function add_parameter!(sq::PormGSQLiteParam, value; contains::Bool = false)::String
  contains && (value = string("%", value |> escape_like_pattern, "%"))  # Escape LIKE patterns if needed
  sq.parameter_count += 1
  push!(sq.parameters, value)
  return "?$(sq.parameter_count)"  # SQLite style
end
add_parameter!(instruc::SQLInstruction, value::Any; contains::Bool = false) = add_parameter!(instruc.parameters, value; contains = contains)
