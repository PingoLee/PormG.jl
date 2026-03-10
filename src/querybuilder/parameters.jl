# ─────────────────────────────────────────────────────────────────────────────
# PostgreSQL Implementation – numbered parameters ($1, $2 …)
#
# Stores a single linear vector of values and a counter.
# The `current_context` field exists for interface compatibility but is ignored
# because PostgreSQL uses numbered placeholders whose order is irrelevant.
# ─────────────────────────────────────────────────────────────────────────────
mutable struct PgParameterizedQuery <: PormGPostgresParam
  sql::String
  parameters::Union{AbstractVector,Tuple}
  parameter_count::Int

  PgParameterizedQuery(sql::String, parameters::Union{AbstractVector,Tuple}, parameter_count::Int) = new(sql, parameters, parameter_count)
end
get_parameter(connection::PormGPostgres) = PgParameterizedQuery("", Any[], 0)

function _postgres_parameter_cast(::Nothing)
  return ""
end

function _postgres_parameter_cast(sql_type::AbstractString)
  isempty(sql_type) && return ""
  return "::$(sql_type)"
end

# ─────────────────────────────────────────────────────────────────────────────
# SQLite Implementation – Contextual Bucket Strategy
#
# SQLite uses purely positional parameters (?).  Because code execution order
# (filters first, then joins) does not match final SQL string order (JOINs
# appear before WHERE), we cannot simply append to a single vector.
#
# Instead we maintain one vector per SQL section ("bucket").  As the query
# builder processes each section it calls `set_context!` to switch the active
# bucket.  `add_parameter!` pushes into the *active* bucket and always returns
# "?".  After all sections are built, `get_final_parameters` concatenates the
# buckets in standard SQL clause order so that the positional `?` markers line
# up with their values.
# ─────────────────────────────────────────────────────────────────────────────
mutable struct SQLiteParameterizedQuery <: PormGSQLiteParam
  sql::String
  # Separate buckets for each SQL section
  cte_params::Vector{Any}
  select_params::Vector{Any}
  update_params::Vector{Any}
  join_params::Vector{Any}
  where_params::Vector{Any}
  having_params::Vector{Any}
  # Active bucket selector
  current_context::Symbol

  function SQLiteParameterizedQuery(sql::String="", current_context::Symbol=:where)
    new(sql, Any[], Any[], Any[], Any[], Any[], Any[], current_context)
  end
end
get_parameter(connection::PormGSQLite) = SQLiteParameterizedQuery()

# ─────────────────────────────────────────────────────────────────────────────
# Bucket accessor helper – returns the vector for the current context
# ─────────────────────────────────────────────────────────────────────────────
function _current_bucket(sq::SQLiteParameterizedQuery)::Vector{Any}
  ctx = sq.current_context
  ctx === :cte && return sq.cte_params
  ctx === :select && return sq.select_params
  ctx === :update && return sq.update_params
  ctx === :join && return sq.join_params
  ctx === :where && return sq.where_params
  ctx === :having && return sq.having_params
  # Fallback – warn about unknown context and route to :where so nothing silently breaks
  @warn "Unknown parameter context $(repr(ctx)), falling back to :where" ctx
  return sq.where_params
end

# ─────────────────────────────────────────────────────────────────────────────
# set_context!  – switch the active bucket before processing each SQL section
# ─────────────────────────────────────────────────────────────────────────────
"""
    set_context!(params::AbstractPormGParam, context::Symbol)

Switch the active parameter bucket for positional-parameter backends (SQLite).
Valid contexts: `:cte`, `:select`, `:update`, `:join`, `:where`, `:having`.

For numbered-parameter backends (PostgreSQL) this is a no-op.
"""
set_context!(::PormGPostgresParam, ::Symbol) = nothing   # no-op for Postgres
function set_context!(sq::PormGSQLiteParam, context::Symbol)
  sq.current_context = context
  return nothing
end

# ─────────────────────────────────────────────────────────────────────────────
# _apply_like_wildcards  – add wildcards based on operator type
# ─────────────────────────────────────────────────────────────────────────────
"""
    _apply_like_wildcards(value::Any, operator::String)::Any

Apply appropriate LIKE wildcards based on the operator:
- contains/icontains: %value%
- startswith: value%
- endswith: %value
- Other operators: no wildcards
"""
function _apply_like_wildcards(value::Any, operator::String)::Any
  escaped = escape_like_pattern(string(value))
  if operator in ["contains", "icontains"]
    return string("%", escaped, "%")
  elseif operator == "startswith"
    return string(escaped, "%")
  elseif operator == "endswith"
    return string("%", escaped)
  else
    return value
  end
end
# Convenience: operate on the instruction object directly
set_context!(instruc::SQLInstruction, context::Symbol) = instruc.parameters !== nothing ? set_context!(instruc.parameters, context) : nothing

# ─────────────────────────────────────────────────────────────────────────────
# add_parameter!  – push a value and return the placeholder string
# ─────────────────────────────────────────────────────────────────────────────

# --- PostgreSQL (unchanged behaviour) ---
function add_parameter!(pq::PormGPostgresParam, value::AbstractArray; contains::Bool=false, operator::String="", sql_type::Union{Nothing,String}=nothing)
  contains && (throw(ArgumentError("Contains option is not supported for array parameters")))
  pq.parameter_count += 1
  push!(pq.parameters, value)
  return "\$$(pq.parameter_count)$(_postgres_parameter_cast(sql_type))"
end
function add_parameter!(pq::PormGPostgresParam, value; contains::Bool=false, operator::String="", sql_type::Union{Nothing,String}=nothing)::String
  if contains
    value = _apply_like_wildcards(value, operator)
  end
  pq.parameter_count += 1
  push!(pq.parameters, value)
  return "\$$(pq.parameter_count)$(_postgres_parameter_cast(sql_type))"  # PostgreSQL style
end

# --- SQLite – Contextual Bucket Strategy ---
function add_parameter!(sq::PormGSQLiteParam, value::AbstractArray; contains::Bool=false, operator::String="", sql_type::Union{Nothing,String}=nothing)
  contains && (throw(ArgumentError("Contains option is not supported for array parameters")))
  # Expand array into multiple positional parameters for SQLite
  placeholders = join(fill("?", length(value)), ", ")
  for v in value
    push!(_current_bucket(sq), v)
  end
  return placeholders
end
function add_parameter!(sq::PormGSQLiteParam, value; contains::Bool=false, operator::String="", sql_type::Union{Nothing,String}=nothing)::String
  if contains
    value = _apply_like_wildcards(value, operator)
  end
  push!(_current_bucket(sq), value)
  return "?"  # SQLite positional style
end

# --- SQLInstruction convenience (works for both backends) ---
add_parameter!(instruc::SQLInstruction, value::Any; contains::Bool=false, operator::String="", sql_type::Union{Nothing,String}=nothing) = add_parameter!(instruc.parameters, value; contains=contains, operator=operator, sql_type=sql_type)

# ─────────────────────────────────────────────────────────────────────────────
# get_final_parameters – return the parameters in correct SQL clause order
# ─────────────────────────────────────────────────────────────────────────────
"""
    get_final_parameters(p::AbstractPormGParam) -> Vector{Any}

Return all collected parameter values in the order expected by the final SQL string.

- **PostgreSQL**: returns the single linear vector (order already matches `\$N` numbering).
- **SQLite**: concatenates buckets in standard SQL clause order:
  `cte → select → join → where → having`
  so that each positional `?` aligns with its value.
"""
get_final_parameters(p::PormGPostgresParam)::Vector{Any} = p.parameters isa Vector{Any} ? p.parameters : collect(p.parameters)

function get_final_parameters(p::PormGSQLiteParam)::Vector{Any}
  return vcat(
    p.cte_params,
    p.select_params,
    p.update_params,
    p.join_params,
    p.where_params,
    p.having_params
  )
end

# Legacy compatibility: `.parameters` property access for SQLite
# Many places in the codebase access `params.parameters` directly.
# For SQLite with buckets, we provide this via `get_final_parameters`.
# We define a custom `getproperty` so that `sq.parameters` returns the
# concatenated vector in correct SQL order.
function Base.getproperty(sq::SQLiteParameterizedQuery, name::Symbol)
  if name === :parameters
    return get_final_parameters(sq)
  elseif name === :parameter_count
    # Computed property: sum of all bucket lengths (no drift risk)
    return length(getfield(sq, :cte_params)) + length(getfield(sq, :select_params)) +
           length(getfield(sq, :update_params)) + length(getfield(sq, :join_params)) +
           length(getfield(sq, :where_params)) + length(getfield(sq, :having_params))
  else
    return getfield(sq, name)
  end
end

function Base.hasproperty(::SQLiteParameterizedQuery, name::Symbol)
  return name in (:sql, :cte_params, :select_params, :update_params, :join_params, :where_params, :having_params, :current_context, :parameter_count, :parameters)
end

# Deep copy support – execution_bulk.jl relies on deepcopy(instruction.parameters)
function Base.deepcopy_internal(sq::SQLiteParameterizedQuery, stackdict::IdDict)
  haskey(stackdict, sq) && return stackdict[sq]::SQLiteParameterizedQuery
  new_sq = SQLiteParameterizedQuery(sq.sql, sq.current_context)
  # Copy each bucket
  setfield!(new_sq, :cte_params, Base.deepcopy_internal(getfield(sq, :cte_params), stackdict))
  setfield!(new_sq, :select_params, Base.deepcopy_internal(getfield(sq, :select_params), stackdict))
  setfield!(new_sq, :update_params, Base.deepcopy_internal(getfield(sq, :update_params), stackdict))
  setfield!(new_sq, :join_params, Base.deepcopy_internal(getfield(sq, :join_params), stackdict))
  setfield!(new_sq, :where_params, Base.deepcopy_internal(getfield(sq, :where_params), stackdict))
  setfield!(new_sq, :having_params, Base.deepcopy_internal(getfield(sq, :having_params), stackdict))
  # parameter_count is now computed from bucket lengths — no need to copy
  stackdict[sq] = new_sq
  return new_sq
end
