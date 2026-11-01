# #1352 — the TYPED READ: `list(T)`, `first(T)`, `get(T, …)` (and `last`/`earliest`/`latest`) for a
# struct or `NamedTuple` type `T` the caller declares, returning `Vector{T}` / `Union{Nothing,T}` / `T`.
#
# Every other read terminal hands back a container whose values are `Any` (`PormGRow`, `list(:dict)`),
# so all the code a query feeds is dynamic: each field access a runtime dispatch, each value boxed, and
# nothing past the query a static compiler (`juliac --trim`) can follow. A type assertion at the call
# site types only what comes back, never the container's inside. Here the caller states the shape once,
# and everything after the query is concrete.
#
# Step 1 of the issue, deliberately: the query path inside PormG stays what it is. The rows are the
# `Dict{Symbol,Any}` rows `_list_raw` already reads, with the #564 projection parsers already applied,
# so a `DateTimeField` arrives as the same `ZonedDateTime` it reads as in `list()`; this file only turns
# them into `T`. Decoding straight from the driver's columns into `T` (step 2) waits on the benchmark
# in `test/performance/read_path_list.jl`.
#
# The three rules the maintainer chose (#1352):
#   - COLUMNS ↔ FIELDS. With no `values(...)`, `list(T)` projects exactly `fieldnames(T)`. With
#     `values(...)`, the projected names and `fieldnames(T)` must be the same set: a field with no
#     column and a column with no field are both a `QueryBuildError`, raised before any SQL runs.
#   - NULL. The field's declared type decides: `Union{Nothing,X}` reads `nothing`, `Union{Missing,X}`
#     reads `missing`, and a field that admits neither refuses the NULL.
#   - CONVERSION. Decided by the TYPES, never by the data, so a query cannot pass in a test and fail
#     on one row in production: integer widths convert (a value out of the target's range is refused —
#     the one per-value check, and it is a range, not a type), an integer converts to a float or a
#     `Decimal` when exact, a float widens; everything else must already be the field's type.
#     `IntegerField` reads as `Int32` on PostgreSQL and MySQL and `Int64` on SQLite, which is why the
#     integer rule exists: one struct has to read the same on every engine.

const _TYPED_READ_FORMS = "list(T), first(T), last(T), get(T, filters...), earliest(T, fields...) or latest(T, fields...)"

# `T` must be something a row can be built into, decided before any SQL runs. A container the read
# path already has a terminal for is pointed at that terminal rather than refused generically.
function _check_typed_read_target(::Type{T}) where T
  T <: PormGRow && throw(QueryBuildError(
    "A typed read builds its own rows; for PormGRow rows call list(), first() or get() without a type."))
  T <: AbstractDict && throw(QueryBuildError(
    "A typed read needs a struct or NamedTuple type, not a dictionary type; for Dict rows call list(:dict)."))
  (T <: Tuple || T <: AbstractArray || T <: AbstractString || T <: Number || T <: Symbol) && throw(QueryBuildError(
    "A typed read needs a struct or NamedTuple type whose field names are the columns; $(T) has none. " *
    "Declare a struct, e.g. `struct DriverRow; driverid::Int64; surname::String; end`."))
  (isconcretetype(T) && isstructtype(T)) || throw(QueryBuildError(
    "A typed read needs a concrete struct or NamedTuple type; $(T) is not one. Declare the row as a " *
    "struct with concrete field types, or as `NamedTuple{(:a, :b), Tuple{A, B}}`."))
  fieldcount(T) > 0 || throw(QueryBuildError(
    "A typed read needs a type with at least one field; $(T) has none."))
  # Every field holds a CONCRETE type once NULL is set aside. An abstract field (`::Integer`, `::Real`,
  # `::Any`) would take whatever `isa` admits — a `Bool` into `::Integer`, a `Float64` or a `Decimal`
  # into `::Real` — past the conversion rules, and its row would not be concretely typed, which is the
  # point of the typed read.
  for k in 1:fieldcount(T)
    held = _typed_held(fieldtype(T, k))
    isconcretetype(held) || throw(QueryBuildError(
      "A typed read needs a concrete type for every field, and field $(fieldname(T, k)) of $(T) is " *
      "declared $(fieldtype(T, k)). Declare it as the concrete type it holds (`Int64`, `String`, " *
      "`Union{Nothing, Date}`, …): an abstract field would take values the conversion rules refuse."))
  end
  if !(T <: NamedTuple)
    hasmethod(T, Tuple{fieldtypes(T)...}) || throw(QueryBuildError(
      "A typed read builds each row as `$(T)(field1, field2, …)`, one argument per field in declaration " *
      "order, and $(T) has no such constructor (an inner constructor replaced it). Add one, or read into " *
      "a separate struct."))
  end
  return nothing
end

# The projection a typed read runs, on the caller's copy. With no `values(...)` it IS `fieldnames(T)`,
# so the query reads only the columns `T` needs, and each column comes back keyed by the field name
# (`values("f")` keys a `db_column` field by its field name; a bare `SELECT *` would key it by the
# physical column). With `values(...)`, the projected names are known before SQL runs — the same
# `_projection_output_name` the SELECT renders the alias from — and must be exactly `fieldnames(T)`.
function _typed_projection!(q::SQLObjectHandler, ::Type{T}) where T
  obj = q.object
  wanted = fieldnames(T)
  if isempty(obj.values)
    _values!(obj, Any[String(name) for name in wanted])
    return q
  end
  projected = String[]
  for v in obj.values
    name = _projection_output_name(v)
    name === nothing && continue            # build raises its own "Field requires an alias"
    name == "*" && throw(QueryBuildError(
      "A typed read cannot project values(\"*\"): it reads exactly the fields of $(T). Drop " *
      "values(\"*\") and list(T) projects fieldnames(T) for you, or name the columns in values(...)."))
    push!(projected, String(name))
  end
  missing_fields = [String(name) for name in wanted if !(String(name) in projected)]
  isempty(missing_fields) || throw(QueryBuildError(
    "values(...) projects no column for field(s) $(join(missing_fields, ", ")) of $(T). Add them to " *
    "values(...) — an alias names a column: `\"surname\" => \"driverid__surname\"` — or drop the " *
    "values(...) call and list(T) projects fieldnames(T)."))
  extra = [name for name in projected if !(Symbol(name) in wanted)]
  isempty(extra) || throw(QueryBuildError(
    "values(...) projects column(s) $(join(extra, ", ")) that $(T) has no field for. A typed read " *
    "refuses rather than drops a column, so a misspelled alias cannot pass silently: remove them from " *
    "values(...) or add the fields to $(T)."))
  return q
end

# The copy a typed read runs on: the caller's handler is never written to (#43, #199).
function _typed_query(objct::SQLObjectHandler, ::Type{T}) where T
  _check_typed_read_target(T)
  q = deepcopy(objct)
  _typed_projection!(q, T)
  return q
end

# Where a refusal happened, for the `InvalidValueError` location: the terminal, the model, the row.
struct _TypedReadSite
  op::String
  model::String
end

function _typed_rows(::Type{T}, rows::Vector{Dict{Symbol,Any}}, site::_TypedReadSite)::Vector{T} where T
  out = Vector{T}(undef, length(rows))
  for i in eachindex(rows)
    out[i] = _typed_row(T, rows[i], i, site)
  end
  return out
end

# One row: one `_typed_value(fieldtype(T, k), row[:name_k], …)` call per field, written out, then the
# constructor. GENERATED rather than an `ntuple` closure, and that is measured, not stylistic: for a
# struct mixing field types (an `Int64`, a `Float64`, a `String`, a nullable) Julia does not specialize
# the closure per field index, so each cell came back `Any` and the constructor was a dynamic call —
# about ten allocations a row. Written out, every call is typed by its own field and a row allocates
# nothing beyond what its values already hold. The generator reads only `T`'s field names and types.
@generated function _typed_row(::Type{T}, row::Dict{Symbol,Any}, i::Int, site::_TypedReadSite) where T
  cells = [:(_typed_value($(fieldtype(T, k)), row[$(QuoteNode(fieldname(T, k)))],
                          $(QuoteNode(fieldname(T, k))), i, site)) for k in 1:fieldcount(T)]
  return T <: NamedTuple ? :(T(($(cells...),))) : :(T($(cells...)))
end

# One cell. `v isa FT` is the common case and costs one type check. Otherwise a NULL becomes the
# field's declared absent value or is refused, and a non-null value goes through the conversion rules
# for the type the field holds (`X`, the field type without `Nothing`/`Missing`).
@inline function _typed_value(::Type{FT}, v, name::Symbol, i::Int, site::_TypedReadSite)::FT where FT
  v isa FT && return v
  if v === missing
    # `Missing <: FT` was answered by the `isa` above.
    Nothing <: FT && return nothing
    throw(_typed_null_refusal(FT, name, i, site))
  end
  return _typed_coerce(_typed_held(FT), FT, v, name, i, site)
end

# What a field holds once NULL is set aside: `Union{Nothing,Int64}` holds `Int64`.
_typed_held(::Type{FT}) where FT = Base.nonmissingtype(Base.nonnothingtype(FT))

# The conversion rules, for a concrete `X` (`_check_typed_read_target` refuses any other). The column
# arrives as `Any` (a `Dict{Symbol,Any}` cell), so the driver types the rules see are tested one by one
# — a union split by hand. Each arm then runs on a concrete source type and returns a concrete `X`, so
# a converted cell allocates nothing: a generic `convert(X, v::Any)` was a dynamic call returning a
# boxed value, and on PostgreSQL, where an `IntegerField` arrives as `Int32`, that was seven allocations
# a row on a five-column read (`test/performance/read_path_list.jl`). Anything the arms do not name
# falls through to `_typed_coerce_any`, which applies the same rules to any type.
@inline function _typed_coerce(::Type{X}, ::Type{FT}, v, name::Symbol, i::Int, site::_TypedReadSite)::X where {X,FT}
  if X <: Integer && !(X <: Bool)
    v isa Int32 && return _typed_int(X, FT, v, name, i, site)
    v isa Int64 && return _typed_int(X, FT, v, name, i, site)
    v isa Int16 && return _typed_int(X, FT, v, name, i, site)
    v isa Int8  && return _typed_int(X, FT, v, name, i, site)
  elseif X <: AbstractFloat
    v isa Int32 && return _typed_int_to_float(X, FT, v, name, i, site)
    v isa Int64 && return _typed_int_to_float(X, FT, v, name, i, site)
    v isa Float32 && return _typed_float(X, FT, v, name, i, site)
  elseif X === String
    v isa SubString{String} && return String(v)
  end
  return _typed_coerce_any(X, FT, v, name, i, site)
end

# The rules over any source type: the arms above, without the split.
function _typed_coerce_any(::Type{X}, ::Type{FT}, v, name::Symbol, i::Int, site::_TypedReadSite)::X where {X,FT}
  v isa X && return v
  # `Bool <: Integer` in Julia, but a boolean and a number are different MEANINGS (the engine rule
  # that refuses `Bool` vs `1` elsewhere), so neither direction converts.
  if v isa Integer && !(v isa Bool) && X <: Integer && !(X <: Bool)
    return _typed_int(X, FT, v, name, i, site)
  elseif v isa Integer && !(v isa Bool) && X <: AbstractFloat      # `Decimal <: AbstractFloat` too
    return _typed_int_to_float(X, FT, v, name, i, site)
  elseif v isa AbstractFloat && !(v isa Decimals.Decimal) && X <: AbstractFloat
    return _typed_float(X, FT, v, name, i, site)
  elseif v isa AbstractString && X === String
    return String(v)
  end
  throw(_typed_type_refusal(FT, typeof(v), name, i, site))
end

# An integer into an integer: the one value-dependent rule, and it is a RANGE, not a type.
@inline function _typed_int(::Type{X}, ::Type{FT}, v::Integer, name::Symbol, i::Int, site::_TypedReadSite)::X where {X,FT}
  if Base.hastypemax(X)
    (typemin(X) <= v <= typemax(X)) || throw(_typed_range_refusal(FT, typeof(v), name, i, site))
  end
  return X(v)
end

# An integer into a float or a `Decimal`, when exact: past 2^53 a `Float64` rounds.
@inline function _typed_int_to_float(::Type{X}, ::Type{FT}, v::Integer, name::Symbol, i::Int, site::_TypedReadSite)::X where {X,FT}
  f = convert(X, v)
  f == v || throw(_typed_range_refusal(FT, typeof(v), name, i, site))
  return f
end

# A float into a float: widening only. A `Decimal` on either side is a different number type, refused.
@inline function _typed_float(::Type{X}, ::Type{FT}, v::AbstractFloat, name::Symbol, i::Int, site::_TypedReadSite)::X where {X,FT}
  (X <: Decimals.Decimal || v isa Decimals.Decimal || precision(X) < precision(typeof(v))) &&
    throw(_typed_type_refusal(FT, typeof(v), name, i, site))
  return convert(X, v)
end

# The refusals. Each names the terminal, the model, the row, the field, the field's declared type and
# the column's Julia type — never the value (#971: a cell can be a secret, and an app may hand `e.msg`
# to a client). `@noinline`: the `string(::Type)` rendering stays off the per-cell path (#1346).
@noinline function _typed_null_refusal(::Type{FT}, name::Symbol, i::Int, site::_TypedReadSite) where FT
  return InvalidValueError(
    "the column is NULL, and the field's type admits neither `nothing` nor `missing`. Declare it " *
    "`Union{Nothing, $(FT)}` to read NULL as `nothing`, or `Union{Missing, $(FT)}` to read it as `missing`.",
    :type; op = site.op, model = site.model, field = String(name), field_type = string(FT), row = i)
end

# The declaration that takes the column's type, keeping the field's own `Nothing`/`Missing`: the
# advice for a `Union{Nothing,String}` field over a `Date` column is `Union{Nothing, Date}`, not a bare
# `Date` that the next NULL would refuse.
function _typed_advice(::Type{FT}, src::Type) where FT
  absent = String[]
  Nothing <: FT && push!(absent, "Nothing")
  Missing <: FT && push!(absent, "Missing")
  isempty(absent) && return string(src)
  return "Union{" * join(absent, ", ") * ", " * string(src) * "}"
end

@noinline function _typed_range_refusal(::Type{FT}, src::Type, name::Symbol, i::Int, site::_TypedReadSite) where FT
  return InvalidValueError(
    "the column reads as $(src), and this row's value does not fit exactly in the field's type. " *
    "Declare the field as a type that holds every value the column can, e.g. $(_typed_advice(FT, src)).",
    :range; op = site.op, model = site.model, field = String(name), field_type = string(FT), row = i)
end

@noinline function _typed_type_refusal(::Type{FT}, src::Type, name::Symbol, i::Int, site::_TypedReadSite) where FT
  return InvalidValueError(
    "the column reads as $(src), which the field's type does not take. A typed read converts only " *
    "between integer widths, from an integer to a float or Decimal when exact, and to a wider float; " *
    "anything else is decided by the types, not the value, so declare the field as " *
    "$(_typed_advice(FT, src)).",
    :type; op = site.op, model = site.model, field = String(name), field_type = string(FT), row = i)
end

"""
    list(objct::SQLObjectHandler, T::Type; show_query = :execute) -> Vector{T}

The typed read (#1352): every row built into `T`, a struct or `NamedTuple` type you declare, so the
code after the query is type-stable. With no `values(...)`, the query projects exactly
`fieldnames(T)`; with `values(...)`, the projected names (aliases included) must be exactly
`fieldnames(T)`, or it raises `QueryBuildError` before any SQL runs.

```julia
struct DriverRow
    driverid::Int64
    surname::String
    code::Union{Nothing, String}
end
rows = M.Driver.objects.filter("nationality" => "Brazilian").order_by("surname").list(DriverRow)
```

A NULL reads as `nothing` into a `Union{Nothing,X}` field and as `missing` into a `Union{Missing,X}`
one. Integer widths convert, an integer converts to a float or `Decimal` when exact, and a float
widens; any other mismatch, and a NULL into a field that admits neither, raises `InvalidValueError`
naming the field and both types. See *Typed rows* in the read guide.
"""
Base.@constprop :aggressive function list(objct::SQLObjectHandler, ::Type{T}; show_query::Symbol = :execute) where T
  q = _typed_query(objct, T)
  show_query !== :execute && return query_list(q, show_query=show_query)
  # `op` names the read, not the terminal: `first(T)`, `get(T, …)` and the others run this same body.
  return _typed_rows(T, _list_raw(q), _TypedReadSite("a typed read into $(T)", q.object.model.name))
end

"""
    first(objct::SQLObjectHandler, T::Type; show_query = :execute) -> Union{Nothing, T}

[`first`](@ref) as a typed read (#1352): the first row built into `T`, or `nothing`. The projection
and conversion rules are `list(T)`'s.
"""
Base.@constprop :aggressive first(objct::SQLObjectHandler, ::Type{T}; show_query::Symbol = :execute) where T =
  _first(objct, T; show_query=show_query)

"""
    last(objct::SQLObjectHandler, T::Type; show_query = :execute) -> Union{Nothing, T}

[`last`](@ref) as a typed read (#1352).
"""
Base.@constprop :aggressive last(objct::SQLObjectHandler, ::Type{T}; show_query::Symbol = :execute) where T =
  _last(objct, T; show_query=show_query)

"""
    get(objct::SQLObjectHandler, T::Type, filters...; show_query = :execute) -> T

[`get`](@ref) as a typed read (#1352): exactly one row, built into `T`. Raises `DoesNotExist` and
`MultipleObjectsReturned` as `get` does.

```julia
row = M.Driver.objects.get(DriverRow, "driverref" => "senna")
```
"""
Base.@constprop :aggressive get(objct::SQLObjectHandler, ::Type{T}, filters...; show_query::Symbol = :execute) where T =
  _get(objct, T, filters; show_query=show_query)

"""
    earliest(objct::SQLObjectHandler, T::Type, fields...; show_query = :execute) -> T

[`earliest`](@ref) as a typed read (#1352).
"""
Base.@constprop :aggressive function earliest(objct::SQLObjectHandler, ::Type{T}, fields...; show_query::Symbol = :execute) where T
  isempty(fields) &&
    throw(QueryBuildError("earliest() requires at least one field to order by, e.g. earliest(T, \"dob\")."))
  return _extreme(objct, fields, "earliest"; show_query=show_query, format=T)
end

"""
    latest(objct::SQLObjectHandler, T::Type, fields...; show_query = :execute) -> T

[`latest`](@ref) as a typed read (#1352).
"""
Base.@constprop :aggressive function latest(objct::SQLObjectHandler, ::Type{T}, fields...; show_query::Symbol = :execute) where T
  isempty(fields) &&
    throw(QueryBuildError("latest() requires at least one field to order by, e.g. latest(T, \"dob\")."))
  return _extreme(objct, _invert_order_token.(fields), "latest"; show_query=show_query, format=T)
end
