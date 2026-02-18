
# ---
# Build the object
#

# Why Vector{String}
function _up_values(str::String)
  check = String.(split(str, "__@"))
  if size(check, 1) == 1
    return SQLField(str, str)
  elseif haskey(PormGsuffix, check[end])
    throw("Invalid argument: $(str) does not must contain operators (lte, gte, contains ...)")
  else
    @infiltrate false
    return SQLField(_check_function(check), join(check, "__"))
  end     
end

function up_values!(q::SQLObject, values)
  # every call of values, reset the values
  q.values = []
  for v in values 
    isa(v, Symbol) && (v = String(v))
    if isa(v, SQLTypeText) || isa(v, SQLTypeField)
      push!(q.values, _check_function(v))
    elseif isa(v, SQLTypeFunction)
      push!(q.values, SQLField(_check_function(v), v._as))
    elseif isa(v, Pair)
      if !isa(v.first, String)
        throw("Invalid argument: $(v.first) (::$(typeof(v.first)))); please use a string as key in the pair (key => value)")
      end
      if isa(v.second, Union{SQLTypeFunction, SQLTypeF})
        try
          push!(q.values, SQLField(_check_function(v.second), v.first))
        catch e
          @infiltrate false
          @error "Error processing values pair: $e" exception=(e, catch_backtrace())
        end
      elseif isa(v.second, String)
        z = _up_values(v.second)
        z.custom_as = v.first
        push!(q.values, z)
      end
    elseif isa(v, String)
      push!(q.values, _up_values(v))  
    else
      throw("Invalid argument: $(v) (::$(typeof(v)))); please use a string or a function (Mounth, Year, Day, Y_M ...)")
    end    
  end 
  
  return q
end
  
function up_create!(q::SQLObject, values; kwargs...)
  q.insert = Dict()
  for (k,v) in values   
    q.insert[k] = v 
  end  

  return insert(q; kwargs...)
end

function up_update!(q::SQLObject, values; kwargs...)
  # check if kwargs is not empty and check if kwargs just contains show_query
  show_query = :execute
  if !isempty(kwargs)
    for (k, v) in kwargs
      if k == :show_query
        show_query = v
      else
        throw("Invalid keyword argument: $(k); please use :show_query")
      end
    end
  end
  q.insert = Dict()
  for (k,v) in values   
    q.insert[k] = v 
  end  

  return update(q, show_query=show_query)
end

"""
  up_filter!(q::SQLObject, filter)
  Add filters to the SQLObject query.
# Arguments
- `q::SQLObject`: The SQL object to add filters to.
- `filter`: A collection of filters to add. Each filter can be a `Pair`, `SQLTypeQ`, `SQLTypeQor`, `SQLTypeOper`, or `SQLTypeF`.
# Returns
- The modified SQLObject with the new filters added.
"""
function up_filter!(q::SQLObject, filter)  
  for v in filter   
    if isa(v, FilterType)
      push!(q.filter, v) # TODO I need process the Qor and Q with _check_filter
    elseif isa(v, Pair)
      push!(q.filter, _check_filter(v))
    else
      error("Invalid argument: $(v) (::$(typeof(v)))); please use a pair (key => value) or a Q(key => value...) or a Qor(key => value...)")
    end
  end
  return q
end

function up_db!(q::SQLObject, keys)
  if isempty(keys) || length(keys) > 1 || !isa(keys[1], String)
    throw(ArgumentError("db() expects exactly one String argument (the database key). Received: $(keys)"))
  end
  q.connect_key = keys[1]
  return q
end

function distinct!(q::SQLObject, value::Bool) #::Union{Bool, Nothing}) 
  q.distinct = value
  return q
end
distinct!(q::SQLObject, value::Tuple{}) = distinct!(q, true) # if no value is passed, distinct is true
distinct!(q::SQLObject, value::Tuple{Bool}) = distinct!(q, value[1]) # if a value is passed, distinct is the value
function distinct!(q::SQLObject, value)
  throw("Invalid argument: $(value) (::$(typeof(value))); please use a boolean value (true or false)")
end

# function distinct!(q::SQLObject, value)
#   throw("Invalid argument: $(value) (::$(typeof(value))); please use a boolean value (true or false)")
# end


# Build the SELECT part of the string final query
function _query_select(array::Vector{SQLTypeField})
  if !isassigned(array, 1, 1)
    return "*"
  else
    colect = []
    for i in 1:size(array, 1)     
      if !isassigned(array, i, 1)
        return join(colect,  ", \n  ")
      else
        @infiltrate false
        if isa(array[i, 1], SQLField) && array[i, 1].custom_as !== nothing 
          push!(colect, "$(array[i, 1].field) as $(array[i, 1].custom_as)")
        else
          push!(colect, "$(array[i, 1].field) as $(array[i, 1]._as)")
        end
      end
    end
  end   
end


function order_by!(q::SQLObject, values::NTuple{N, Union{String, SQLTypeOrder}} where N)
  q.order = [] # every call of order_by, reset the order
  for v in values 
    if isa(v, String)
      # check if v constains - in the first position
      v[1:1] == "-" ? (orientation = "DESC"; v = v[2:end]) : orientation = "ASC"
      check = String.(split(v, "__@"))
      if size(check, 1) == 1
        push!(q.order, SQLOrder(SQLField(v, v), orientation=orientation))
      elseif haskey(PormGsuffix, check[end])
        throw("Invalid argument: $(v) does not must contain operators (lte, gte, contains ...)")
      else    
        push!(q.order, SQLOrder(SQLField(_check_function(check), join(check, "__")), orientation=orientation))
      end     
    else
      push!(q.order, v)
    end    
  end   
  return q  
end
function order_by!(q::SQLObject, values)
  throw("Invalid argument: $(values) (::$(typeof(values))); please use a string or a SQLTypeOrder)")
end



# ---
# The "Functor" for chainable methods
# ---

struct ChainCaller{F, T}
    func::F
    handler::T
end

# When called (e.g., query.filter(...)), it executes and returns the handler itself
function (c::ChainCaller)(args...)
    c.func(c.handler.object, args)
    return c.handler
end

function Base.getproperty(q::ObjectHandler, sym::Symbol)
  # === CATEGORY 1: Chainable methods (return 'q') ===
  # Allows: query.filter(...).order_by(...)
  if sym === :filter
    return ChainCaller(up_filter!, q)
  elseif sym === :db
    return ChainCaller(up_db!, q)
  elseif sym === :values
    return ChainCaller(up_values!, q)
  elseif sym === :order_by
    return ChainCaller(order_by!, q)
  elseif sym === :limit
    return ChainCaller(limit!, q)
  elseif sym === :offset
    return ChainCaller(offset!, q)
  elseif sym === :page
    return ChainCaller(page!, q)
  elseif sym === :distinct
    return ChainCaller(distinct!, q)
  elseif sym === :copy
    return () -> deepcopy(q)

      
  # === CATEGORY 2: Terminal methods (return result) ===
  # End the chain. E.g.: query.create(...) returns a Dict.
  elseif sym === :create
    # Returns a simple function that forwards to up_create!
    return (args...) -> up_create!(q.object, args)
  elseif sym === :update
    return (args...; kwargs...) -> up_update!(q.object, args; kwargs...)
  elseif sym === :count
    return () -> do_count(q)
  elseif sym === :exists
    return () -> do_exists(q)
  elseif sym === :list || sym === :all
    return (; kwargs...) -> list(q; kwargs...)
  elseif sym === :list_json
    return (; kwargs...) -> list_json(q; kwargs...)
  elseif sym === :inspect_query || sym === :inspect
    return (; kwargs...) -> inspect_query(q; kwargs...)
  elseif sym === :delete
    return (; kwargs...) -> delete(q; kwargs...)
      
  # === CATEGORY 3: Internal fields ===
  else
    return getfield(q, sym)
  end
end

function Base.getproperty(m::PormGModel, sym::Symbol)
  if sym === :objects
    # Self-healing: Ensure models are initialized before returning objects
    Models.ensure_model_initialized(m)
    return object(m)
  else
    return getfield(m, sym)
  end
end

@doc """
    filter(args...)

Apply filters to the query. Chainable method that returns the query object.

Usage: `query.filter("field" => value)`

See [Read documentation](read.md) for detailed filter syntax and examples.
""" ChainCaller(up_filter!, q)