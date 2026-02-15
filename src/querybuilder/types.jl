#
# Type Aliases for Heavy Unions
#
"""Filter components: Operator objects, Q (AND), Qor (OR), and F expressions."""
const FilterType = Union{SQLTypeQ, SQLTypeQor, SQLTypeOper, SQLTypeF}

"""Field references in SQL: text, functions, or string names."""
const FieldPart = Union{SQLTypeText, SQLTypeFunction, String, SQLTypeF}

"""Column references: fields, functions, strings, or vectors of operations."""
const ColumnPart = Union{SQLTypeField, SQLTypeFunction, String, SQLTypeF, Vector{Union{String, SQLTypeF}}}

"""Optional strings (often used for aliases or configs)."""
const OptionalString = Union{String, Nothing}

"""Database connections."""
const ConnType = Union{PormGSQLite, PormGPostgres, Nothing}

"""CTE configuration dictionary."""
const CTEDict = Dict{String, Union{SQLObjectHandler, PormGModel, Pair, String, Nothing}}

"""Join metadata dictionary."""
const JoinDict = Dict{String, Union{String, Vector{FilterType}}}

#
# SQLTypeArrays Objects
#
@kwdef mutable struct SQLArrays <: SQLTypeArrays # TODO -- check if I need to use this
  count::Integer = 1
  array_string::Array{String, 2} = Array{String, 2}(undef, 20, 3)
  array_int::Array{Integer, 2} = Array{Integer, 2}(undef, 20, 3)
end

#
# SQLInstruction Objects (instructions to build a query)
#
@kwdef mutable struct InstrucObject <: SQLInstruction
  text::String # text to be used in the query
  table_alias::SQLTableAlias
  alias::String
  object::SQLObject
  select::Vector{SQLTypeField} = Array{SQLTypeField, 1}(undef, 60)
  join::Vector{String} = []  # values to be used in join query
  _where::Vector{String} = []  # values to be used in where query
  agregate::Bool = false
  group::Vector{String} = []  # values to be used in group query
  having::Vector{String} = [] # values to be used in having query
  order::Vector{String} = [] # values to be used in order query  
  # df_join::Union{Missing, DataFrames.DataFrame} = missing # dataframe to be used in join query
  row_join::Vector{JoinDict} = [] # array of dictionary to be used in join query
  row_path::Vector{String} = [] # array of path to map the row_join (model__model__ etc)
  # array_join::Array{String, 2} = Array{String, 2}(undef, 30, 8) # array to be used in join query (meaby the best way to do this)
  tab_field_cache::Dict{String, PormGField} = sizehint!(Dict{String, PormGField}(), 12) # cache to be used in join query
  connection::ConnType = nothing
  # array_defs::SQLTypeArrays = SQLArrays()
  cache::Dict{String, SQLTypeField} = sizehint!(Dict{String, SQLTypeField}(), 12)
  django::OptionalString = nothing
  parameters::Union{Nothing, PormGPostgresParam, PormGSQLiteParam} = nothing # parameters to be used in the query
end

# Store information to decide the name from table alias in subquery
mutable struct SQLTbAlias <: SQLTableAlias
  count::Integer
end
SQLTbAlias() = SQLTbAlias(0)
function get_alias(s::SQLTableAlias)
  if s.count == 0
    s.count += 1
    return "Tb"
  end
  s.count += 1
  return "R$(s.count -1)"
end

# Return a value to sql query, like value from DjangoSQLText
mutable struct SQLText <: SQLTypeText
  field::Any
  _as::OptionalString
  custom_as::OptionalString
end
SQLText(field::Any; _as::OptionalString = nothing) = SQLText(field, _as, nothing)
SQLText(field::Any, _as::OptionalString) = SQLText(field, _as, nothing)
Base.deepcopy(x::SQLTypeText) = SQLText(x.field, x._as, x.custom_as)


# Return a field to sql query
mutable struct SQLField <: SQLTypeField
  field::FieldPart
  _as::OptionalString
  custom_as::OptionalString
end
SQLField(field::FieldPart; _as::OptionalString = nothing) = SQLField(field, _as, nothing)
SQLField(field::FieldPart, _as::OptionalString) = SQLField(field, _as, nothing)
Base.deepcopy(x::SQLTypeField) = SQLField(x.field, x._as, x.custom_as)

# Return a order of field to sql query
mutable struct SQLOrder <: SQLTypeOrder
  field::Union{SQLTypeField, String}
  order::Union{Integer, Nothing}
  orientation::String
  _as::OptionalString
end
SQLOrder(field::Union{SQLTypeField, String}; order::Union{Integer, Nothing} = nothing, orientation::String = "ASC", _as::OptionalString = nothing) = SQLOrder(field, order, orientation, _as)
Base.deepcopy(x::SQLTypeOrder) = SQLOrder(x.field, x.order, x.orientation, x._as)

#
# SQLObject Objects (main object to build a query)
#

mutable struct SQLObjectQuery <: SQLObject
  model::PormGModel
  connect_key::OptionalString # Override for multi-tenant scenarios
  values::Vector{Union{SQLTypeText, SQLTypeField}}
  filter::Vector{FilterType} # filters to be used in the query
  insert::Dict{String, Any} # values to be used to create or insert
  limit::Integer
  offset::Integer
  order::Vector{SQLTypeOrder}
  group::Vector{String}
  having::Vector{String}
  list_joins::Vector{String} # is ther a better way to do this?
  row_join::Vector{Dict{String, Any}}  
  distinct::Bool # Add distinct field
  ctes::Dict{String, CTEDict}
  custom_join::Dict{String, Any} 
  parameters::Union{Nothing, PormGPostgresParam}

  SQLObjectQuery(; model=nothing, connect_key = nothing, values = [],  filter = [], insert = Dict(), limit = 0, offset = 0,
        order = [], group = [], having = [], list_joins = [], row_join = [], distinct = false, ctes = Dict{String, CTEDict}(), custom_join = Dict{String, Any}(), parameters = nothing) = # Add ctes and custom_join to constructor
    new(model, connect_key, values, filter, insert, limit, offset, order, group, having, list_joins, row_join, distinct, ctes, custom_join, parameters) # Add ctes and custom_join to new
end

function Base.deepcopy(obj::SQLObjectHandler)
  return ObjectHandler(object = deepcopy(obj.object))
end
function Base.deepcopy(obj::SQLObjectQuery)
  try
    return SQLObjectQuery(
      model = obj.model,  # PormGModel doesn't need deep copy (immutable reference)
      connect_key = obj.connect_key,
      values = deepcopy(obj.values),
      filter = deepcopy(obj.filter),
      insert = deepcopy(obj.insert),
      limit = obj.limit,
      offset = obj.offset,
      order = deepcopy(obj.order),
      group = deepcopy(obj.group),
      having = deepcopy(obj.having),
      list_joins = deepcopy(obj.list_joins),
      row_join = deepcopy(obj.row_join),
      distinct = obj.distinct,
      ctes = deepcopy(obj.ctes),
      custom_join = deepcopy(obj.custom_join)
    )
  catch e
    @infiltrate false
    @error "Error in deepcopy for SQLObjectQuery: $e" exception=(e, catch_backtrace())
    rethrow(e)
  end
end
function Base.deepcopy(filter::Vector{FilterType})
  return [deepcopy(f) for f in filter]
end
function Base.deepcopy(oper::SQLTypeOper)
  @infiltrate false
  return OperObject(
    operator = oper.operator,
    values = oper.values |> typeof <: SQLObjectHandler ? oper.values : deepcopy(oper.values),
    column = deepcopy(oper.column)
  )
end


#
# SQLTypeQ and SQLTypeQor Objects
#

"""
Mutable struct representing an SQL operator object for using in the filter and annotate.
That is a internal function, please do not use it.

# Fields
- `operator::String`: the operator used in the SQL query.
- `values::Union{String, Integer, Bool}`: the value(s) to be used with the operator.
- `column::Union{String, SQLTypeFunction}`: the column to be used with the operator.

"""
@kwdef mutable struct OperObject <: SQLTypeOper
  operator::String
  values::Union{String, Number, Bool, SQLObjectHandler, SQLTypeF, Vector{T}} where T <: Union{Missing, String, Dates.TimeType, Number, Bool, SQLTypeF}
  column::ColumnPart # Vector{String} is needed
end
OP(column::String, value) = OperObject(operator = "=", values = value, column = SQLField(column))
OP(column::SQLTypeFunction, value) = OperObject(operator = "=", values = value, column = column)
OP(column::String, operator::String, value) = OperObject(operator = operator, values = value, column = SQLField(column))
OP(column::SQLTypeFunction, operator::String, value) = OperObject(operator = operator, values = value, column = column)



@kwdef mutable struct QObject <: SQLTypeQ
  filters::Vector{FilterType} # filters to be used in the query
end
function Base.deepcopy(q::QObject)
  return QObject(filters = deepcopy(q.filters))
end

@kwdef mutable struct QorObject <: SQLTypeQor
  or::Vector{FilterType} # filters to be used in the query
end
function Base.deepcopy(q::QorObject)
  return QorObject(or = deepcopy(q.or))
end

function Base.push!(q::SQLTypeQ, x...)
  for v in x
    if isa(v, Pair)
      push!(q.filters, _check_filter(v))
    elseif isa(v, FilterType)
      push!(q.filters, v)
    else
      throw("Invalid argument: $(v); please use a pair (key => value) or Q/Qor/OP object")
    end
  end
  return q
end

function Base.push!(q::SQLTypeQor, x...)
  for v in x
    if isa(v, Pair)
      push!(q.or, _check_filter(v))
    elseif isa(v, FilterType)
      push!(q.or, v)
    else
      throw("Invalid argument: $(v); please use a pair (key => value) or Q/Qor/OP object")
    end
  end
  return q
end


"""
F object for direct database field references and operations (similar to Django F expressions).

Allows you to reference database fields directly in operations without pulling data into Julia.

# Examples
```julia
# Update a field with another field's value
query = MyModel |> object
query.filter("id" => 1)
query.update("field1" => F("field2"))

# Increment a field by a constant
query.update("counter" => F("counter") + 1)

# Update with arithmetic operations between fields
query.update("total" => F("price") * F("quantity"))

# Use in filters to compare fields
query.filter(F("start_date") <= F("end_date"))

# Use in annotations/values
query.values("price", "discounted_price" => F("price") * 0.9)
```
"""
@kwdef mutable struct FExpression <: SQLTypeF
  field_name::String
  operation::OptionalString = nothing  # +, -, *, /, etc.
  operand::Union{String, Integer, Float64, SQLTypeF, Nothing} = nothing
  function_name::String = "F"
  column::Union{String, SQLTypeField, Vector{String}} = ""
  agregate::Bool = false
  _as::OptionalString = nothing
  kwargs::Dict{String, Any} = Dict{String, Any}()
end

# Constructor for F expressions
function F(field_name::String)
  return FExpression(
    field_name = field_name,
    function_name = "F",
    column = field_name
  )
end
function Base.deepcopy(f::FExpression)
  try
    return FExpression(
      field_name = f.field_name,
      operation = f.operation,
      operand = deepcopy(f.operand),
      function_name = f.function_name,
      column = deepcopy(f.column),
      agregate = f.agregate,
      _as = f._as,
      kwargs = deepcopy(f.kwargs)
    )
  catch e
    @error "Error in deepcopy for FExpression: $e" exception=(e, catch_backtrace())
    rethrow(e)
  end
end

# Arithmetic operations for F expressions
function Base.:+(f::FExpression, operand::Union{Integer, Float64, String, FExpression})
  return FExpression(
    field_name = f.field_name,
    operation = "+",
    operand = operand,
    function_name = "F",
    column = f.field_name
  )
end

function Base.:-(f::FExpression, operand::Union{Integer, Float64, String, FExpression})
  return FExpression(
    field_name = f.field_name,
    operation = "-",
    operand = operand,
    function_name = "F",
    column = f.field_name
  )
end

function Base.:*(f::FExpression, operand::Union{Integer, Float64, String, FExpression})
  return FExpression(
    field_name = f.field_name,
    operation = "*",
    operand = operand,
    function_name = "F",
    column = f.field_name
  )
end

function Base.:/(f::FExpression, operand::Union{Integer, Float64, String, FExpression})
  return FExpression(
    field_name = f.field_name,
    operation = "/",
    operand = operand,
    function_name = "F",
    column = f.field_name
  )
end

# Comparison operations for F expressions
function Base.:(==)(f::FExpression, operand::Union{Integer, Float64, String, Dates.Date, Dates.DateTime, FExpression})  
  f.operation = "="
  f.operand = operand
  return f
end
function Base.:>(f::FExpression, operand::Union{Integer, Float64, String, Dates.Date, Dates.DateTime, FExpression})
  f.operation = ">"
  f.operand = operand
  return f
end

function Base.:<(f::FExpression, operand::Union{Integer, Float64, String, Dates.Date, Dates.DateTime, FExpression})
  f.operation = "<"
  f.operand = operand
  return f
end

function Base.:>=(f::FExpression, operand::Union{Integer, Float64, String, Dates.Date, Dates.DateTime, FExpression})
  f.operation = ">="
  f.operand = operand
  return f
end

function Base.:<=(f::FExpression, operand::Union{Integer, Float64, String, Dates.Date, Dates.DateTime, FExpression})
  f.operation = "<="
  f.operand = operand
  return f
end
# function Base.:>(f::FExpression, operand::Union{Integer, Float64, String, Dates.Date, Dates.DateTime, FExpression})
#   return OperObject(operator = ">", values = operand, column = f)
# end

# function Base.:<(f::FExpression, operand::Union{Integer, Float64, String, Dates.Date, Dates.DateTime, FExpression})
#   return OperObject(operator = "<", values = operand, column = f)
# end

# function Base.:>=(f::FExpression, operand::Union{Integer, Float64, String, Dates.Date, Dates.DateTime, FExpression})
#   return OperObject(operator = ">=", values = operand, column = f)
# end

# function Base.:<=(f::FExpression, operand::Union{Integer, Float64, String, Dates.Date, Dates.DateTime, FExpression})
#   return OperObject(operator = "<=", values = operand, column = f)
# end

# Allow arithmetic operations with F expressions on the right side
function Base.:+(operand::Union{Integer, Float64}, f::FExpression)
  return FExpression(
    field_name = f.field_name,
    operation = "+",
    operand = operand,
    function_name = "F",
    column = f.field_name
  )
end

function Base.:*(operand::Union{Integer, Float64}, f::FExpression)
  return FExpression(
    field_name = f.field_name,
    operation = "*",
    operand = operand,
    function_name = "F",
    column = f.field_name
  )
end

#
# SQLTypeFunction Objects (functions from sql)
#

@kwdef mutable struct FObject <: SQLTypeFunction
  function_name::String
  column::Union{String, SQLTypeField, SQLTypeText, N, Vector{N}, Vector{T}, SQLTypeOper, SQLTypeQ, SQLTypeQor} where {N <: SQLTypeFunction, T}
  agregate::Bool = false
  formater::Union{Nothing, Function} = nothing # function to format the value
  _as::OptionalString = nothing
  kwargs::Dict{String, Any} = Dict{String, Any}()
end
function Base.deepcopy(f::FObject)
  return FObject(
    function_name = f.function_name,
    column = deepcopy(f.column),
    agregate = f.agregate,
    formater = f.formater,
    _as = f._as,
    kwargs = deepcopy(f.kwargs)
  )
end



# ---
# Define a struct ObjectHandler that wraps a SQLObjectQuery
# ---
mutable struct ObjectHandler <: SQLObjectHandler
  object::SQLObject 
end
ObjectHandler(; object::SQLObject) = ObjectHandler(object)


"""
Wraps a PormGModel into an ObjectHandler on which you can call:
```
- .filter(...) to add WHERE clauses
- .values(...) to choose/annotate columns
- .order_by(...) to sort
- .distinct() to add DISTINCT clause
- .create(...) for single-row DML
- .update(...) for single-row DML
- .limit(...), .offset(...), .page(...) for pagination
- plus bulk_insert, bulk_update, do_count, do_exists, list, etc.
```

# Arguments
- `model::PormGModel`: The model to be wrapped and handled.

# Example
```julia
using PormG, DataFrames

# assume models loaded as `M`
query = M.User.objects

# 1) Filtering & selecting
query.filter("is_active" => true)
query.values("id", "username", "email")
df = query |> DataFrame

# 2) Counting
active_users = query.count()

# 3) Inserting a single row
new = M.Status.objects.create("statusid" => 42, "status" => "Foo")  
# returns a Dict of the inserted row

# 4) Updating a single row
M.Status.objects.filter("statusid" => 42).update("status" => "Bar")

# 5) Ordering & aggregation
query = M.Result.objects.filter("raceid__year" => 2020)
query.values(
  "driverid__forename", 
  "constructorid__name", 
  "laps" => Count("laps")
).order_by("-laps")
df2 = query |> DataFrame

# 6) Existence check
exists = M.User.objects.filter("id" => 1).exists()

```
"""
function object(model::PormGModel)
  return ObjectHandler(object = SQLObjectQuery(model = model))
end


# delection

mutable struct DeletionCollector{T}
  model::PormGModel  # The main model being deleted from
  settings::SQLConn  # Connection settings
  connection::Union{PormGPostgres, PormGSQLite}  # Database connection
  objects::Dict{PormGModel, Vector{Dict{Symbol, T}}}  # Models and their objects to delete
  dependencies::Dict{PormGModel, Set{PormGModel}}  # Model dependencies
  field_updates::Dict{Tuple{String, Any}, Dict{PormGModel, Dict{Symbol, T}}}  # Field updates for SET_NULL etc.
  fast_deletes::Dict{PormGModel, Vector{Dict{Symbol, T}}}  # Objects that can be deleted directly
  sorted_models::Vector{PormGModel}  # Models in deletion order
  
  DeletionCollector(model, settings) = new{Union{String, SQLObjectHandler}}(
    model,
    settings,
    settings.connections,
    Dict{PormGModel, Vector{Dict{Symbol, Union{String, SQLObjectHandler}}}}(),
    Dict{PormGModel, Set{PormGModel}}(),
    Dict{Tuple{String, Any}, Dict{PormGModel, Dict{Symbol, String}}}(),
    Dict{PormGModel, Dict{Symbol, String}}(),
    Vector{PormGModel}()
  )
end