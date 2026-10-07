# ---
# Process the query entries to build the SQLObjectQuery object
#

"""
    get_settings(obj::Union{SQLObject, SQLObjectHandler}; connection::Union{Nothing, PormGPostgres, PormGSQLite} = nothing)

Resolves the database settings for a query. 
Returns a tuple of `(settings::PormGSettings, connection, conn_key::String)`.

If a `connection` is provided, it is returned as is. 
Otherwise, it returns the default connection from the resolved settings.
"""
function get_settings(obj::Union{SQLObject,SQLObjectHandler}; connection::Union{Nothing,PormGPostgres,PormGSQLite}=nothing)
  q = obj isa SQLObjectHandler ? obj.object : obj
  conn_key = q.connect_key !== nothing ? q.connect_key : q.model.connect_key
  if conn_key === nothing
    # Fall back to the only loaded config when unambiguous; otherwise give a clear error.
    if length(config) == 1
      conn_key = first(keys(config))
    else
      throw(InvalidConfigurationError("Model '$(q.model.name)' is not bound to a database connection key. " *
        "Call `set_models()` or `PormG.@import_models` to bind the model before querying."))
    end
  end
  settings = get_configuration_settings(conn_key)

  final_connection = connection === nothing ? settings.connections : connection
  # A config entry can exist with no pool built yet (`connections === nothing`); letting that
  # escape produced a raw `MethodError` at get_parameter downstream (audit probe). Same guard and
  # wording as `pool_stats(key)` in PormG.jl.
  final_connection === nothing && throw(InvalidConfigurationError(
    "Connection '$(conn_key)' has no pool yet (not built / not connected). " *
    "Call PormG.Configuration.load(...) so the pool exists before querying."))
  return settings, final_connection, conn_key
end

# I may not need this function initially, but it can be useful when processing queries
# function _check_function(f::OperObject)
function _check_function(f::Vector{N} where N<:SQLObject)
  r_v::Vector{SQLObject} = []
  for v in f
    if isa(v, SQLTypeOper)
      push!(r_v, _check_filter(v))
    else
      push!(r_v, _check_function(v))
    end
  end
  return r_v
end
# #508 phase 1 — these three arms CONSTRUCT. They used to assign `f.column = _check_function(f.column)`
# on the node they were handed, and that node arrives straight from the public API: `Sum("points")`,
# `Count("id")`, `Rank(over = …)` are handles a user may bind to a name and reuse, which the `F`
# docstring promises outright. No wrong SQL was measured from them — the transform is idempotent, so
# writing the same value back is invisible — but idempotence is a property of today's
# `_check_function`, not a contract, and the identical shape one arm over (`_values!`'s `Value`) DID
# produce wrong SQL. Replacing rather than writing is what `JoinedReference`'s comment calls the
# intended shape, and it costs one allocation on a path that already allocates.
#
# Every slot except `column` rides across by reference, deliberately: the built node must be
# byte-identical to what the mutating form left behind, which is the same discipline `_compare`
# (`operators.jl`) follows for the comparison operators. `kwargs` is shallow-copied for the reason it is
# there too — a `Dict` shared between the user's handle and the build product is exactly the mutable
# state #112 forbids sharing.
#
# `over` is shared rather than copied, and the honest reason is that nothing here needs it copied,
# not that copying would break anything: measured, `over = deepcopy(f.over)` leaves the whole unit
# suite green and every CTE/window render byte-identical. The caller's `WindowSpec` is already safe
# from the CTE-string pass by a different mechanism — every read path deepcopies the handler before
# `build()`, and Julia's generic array deepcopy clones the spec along with it — so a copy here would
# be a second layer over a hazard that does not reach this far. Sharing keeps the built node
# byte-identical to what the mutating form produced, which is the rule the rest of this function
# follows. #508 phase 2 settled the slot: `WindowFunction` is a `struct` now and the `_retag_*`
# walkers construct, so no build step can write through a shared `over` any more. Sharing is a
# property of the types here, not a bet on call paths.
# The operand LIST is copied before the walk, because the `Vector` arm below writes its results
# back in place. Without the copy, `values("x" => h)` rewrote the user's own `h`: since #843 stores a
# string operand bare, `Coalesce("ts__@date", "d")` held a `DATE` node in `h.column` afterwards. The
# result was idempotent, but a node the caller still holds must not change under them (#508).
_fresh_operands(c::AbstractVector) = copy(c)
_fresh_operands(c) = c

# #863 — the walk covers every slot an expression can hide in, not only `column`. It used to stop
# there, and `values(...)` was the only caller, so a transform (`"ts__@date"`) inside a function in
# any other position reached join resolution as if it named a column and the build died with "does
# not have a 'how' property": a `Case`/`When` branch (kwargs), an `F` arithmetic operand, a window's
# `partition_by` or a `Lag`/`Lead` `default`, and every right-hand side (`filter("d__@gte" =>
# Max("ts__@date"))`, `update(...)` SET) — which nothing walked at all.
#
# Only an EXPRESSION is walked: a function or an `FExpression`. A string in a slot is a literal or
# format data (`then = "win"`, `"format"`, `"output_field"`), and an `F("ts__@date")` path resolves at
# render through its own String path, so neither is touched. Subqueries, `Exists`, CTE/Joined/OuterRef
# handles and `Value`s are already resolved or resolve themselves.
_walk_slot(v) = v isa Union{SQLTypeFunction,FExpression} ? _check_function(v) : v
# A kwargs Dict copied, then reassigned key by key — never rebuilt from an iteration — so the
# copy keeps the original's order, which is the order `_get_select_query(::SQLTypeFunction)` binds
# the SQLType kwargs in.
function _walk_kwargs(kwargs::Dict{String,Any})
  out = copy(kwargs)
  for k in collect(keys(out))
    v = out[k]
    v isa Union{SQLTypeFunction,FExpression} && (out[k] = _check_function(v))
  end
  return out
end

function _check_function(f::FObject)
  return FObject(function_name=f.function_name, column=_check_function(_fresh_operands(f.column)),
                 aggregate=f.aggregate, formatter=f.formatter, _as=f._as,
                 kwargs=_walk_kwargs(f.kwargs))
end
# The spec is rebuilt only when a partition entry is an expression to walk; otherwise `over` stays
# shared and the built node is byte-identical to before #863. A rebuilt spec is a FRESH one (the
# `_retag_cte_string(::WindowFunction)` shape, ctes.jl): the caller's spec may be shared across two
# window functions, which is documented as supported, so it is never written into.
function _walk_window_spec(over::WindowSpec)
  any(p -> p isa Union{SQLTypeFunction,FExpression}, over.partition_by) || return over
  return WindowSpec(partition_by = WindowPartitionPart[_walk_slot(p) for p in over.partition_by],
                    order_by = WindowOrderPart[o for o in over.order_by],
                    frame = over.frame)
end
function _check_function(f::WindowFunction)
  return WindowFunction(function_name=f.function_name,
                        column=f.column === nothing ? nothing : _check_function(_fresh_operands(f.column)),
                        over=_walk_window_spec(f.over), aggregate=f.aggregate, formatter=f.formatter,
                        _as=f._as, kwargs=_walk_kwargs(f.kwargs))
end
function _check_function(f::Vector{FObject})
  for i in 1:size(f, 1)
    f[i] = _check_function(f[i])
  end
  return f
end
# #863: the right-hand side too, when it is an expression (a `When` condition, a hand-built `OP`).
function _check_function(f::SQLTypeOper)
  return OperObject(operator=f.operator, values=_walk_slot(f.values), column=_check_function(f.column))
end
function _check_function(f::Union{SQLText,SQLField})
  return f
end
function _check_function(f::Vector{T}) where T<:Union{SQLType,Any}
  for i in 1:length(f)
    f[i] = _check_function(f[i])
  end
  return f
end
function _check_function(f::QorObject)
  for i in 1:length(f.or)
    f.or[i] = _check_function(f.or[i])
  end
  return f
end
function _check_function(f::QObject)
  for i in 1:length(f.filters)
    f.filters[i] = _check_function(f.filters[i])
  end
  return f
end
function _check_function(x::Vector{String})
  if length(x) == 1
    return x[1]
  else
    if haskey(PormGtransform, x[end])
      resp = getfield(@__MODULE__, Symbol(PormGtransform[x[end]]))(x[1:end-1])
      return _check_function(resp)
    else
      # Sorted, as `_raise_invalid_filter_operator` already sorts its own copy of this list (#604):
      # `keys(Dict)` order is a hash artifact, so adding one operator silently reshuffled the whole
      # message. An error a user reads should not reorder between releases.
      joined_keys_with_prefix_func = join(map(key -> " \e[32m@" * key, sort!(collect(keys(PormGtransform)))), ", ")
      joined_keys_with_prefix_oper = join(map(key -> " \e[33m@" * key, sort!(collect(keys(PormGsuffix)))), ", ")
      if haskey(PormGsuffix, x[end])
        yes = "you can use \"column__@\e[32m$(x[end])\e[0m\""
        not = "you can not use \"column__\e[31m@$(x[end])__@function\e[0m\". valid functions are:\n$(joined_keys_with_prefix_func)\e[0m\nvalid operators are:\n$(joined_keys_with_prefix_oper)\e[0m"
        throw(FilterError("\e[4m\e[31m$(x[end])\e[0m is not allowed.\n$yes\n$not"))
      else
        throw(FilterError("\"$(x[1])__\e[31m@$(x[end])\e[0m\" is invalid;\n please use a valid function:\n  - $(joined_keys_with_prefix_func)\e[0m\nor a valid operator:\n  - $(joined_keys_with_prefix_oper)\e[0m"))
      end
    end
  end
end
# #603 — the single consumer arm the widened constructor surface owes under the #533 rule ("a
# consumer per admitted member"). Every `Union{AbstractString,...}` signature in `functions.jl`,
# `types.jl` and `object_manager.jl` normalizes at its own seam, so this arm is the backstop for the
# paths that hand a string straight to the walk. The body already normalizes: `split` on a
# `SubString` yields `Vector{SubString{String}}` and the broadcast makes it the `Vector{String}` the
# arm above demands.
_check_function(x::AbstractString) = _check_function(String.(split(x, "__@")))
# A vector of non-`String` strings must take the `Vector{String}` arm above — which reads the whole
# vector as ONE already-split `__@` path — and not the generic `Vector{T}` arm, which resolves
# element by element. Widening the scalar arm alone would have silently routed
# `split("date__@year", "__@")` to the wrong semantics instead of the `MethodError` it raises today.
# `Vector{String}` stays strictly more specific, so this adds no ambiguity.
_check_function(x::Vector{<:AbstractString}) = _check_function(String.(x))
# #863: arithmetic carries expressions in `field_name` (`Max(…) - Min(…)`) and `operand`
# (`F("id") + Coalesce(…)`). Each is walked when it IS an expression; a String `field_name` is left
# alone (it resolves at render), and so is every literal or handle operand. When nothing changed the
# node itself comes back, so a plain `F(...)` is returned as given. Otherwise every slot rides across,
# `aggregate` included — the walk resolves transforms, it does not change what the node aggregates.
function _check_function(x::FExpression)
  field_name = _walk_slot(x.field_name)
  operand = _walk_slot(x.operand)
  (field_name === x.field_name && operand === x.operand) && return x
  return FExpression(field_name=field_name, operation=x.operation, operand=operand,
                     function_name=x.function_name, column=x.column, aggregate=x.aggregate,
                     _as=x._as, kwargs=copy(x.kwargs))
end
# #863: a subquery's own query was resolved by its own `filter`/`values` calls, so there is nothing
# to walk. Without these two arms `Greatest(Subquery(…), "n")` — documented under Greatest/Least —
# and `When(Q(Exists(…)))` died with a raw `MethodError` naming this function.
_check_function(x::Union{ExistsObject,SubqueryObject}) = x
# #444 — a CTE handle is already fully resolved; there is nothing left to peel.
_check_function(x::CTEReference) = x
# #535 — an outer-query reference is fully resolved too. `OuterRefObject <: SQLTypeF`, so every
# union naming the abstract `SQLTypeF` — the ~18 scalar-function signatures in `functions.jl` and
# `WindowColumnPart` — admits it, and the RENDER side always had a consumer:
# `_get_select_query(::OuterRefObject)` resolves it against the enclosing query's `instruc.outer`
# (`Lower(OuterRef("surname"))` inside an `Exists`/`Subquery` renders `LOWER("Tb"."surname")`,
# Django's own spelling — `OuterRef` subclasses `F` there) or refuses with `QueryBuildError` when
# there is no outer query. What was missing was THIS arm on the build side: `_check_function(::FObject)`
# and `(::WindowFunction)` walk their `column` through here, so `values("l" => Lower(OuterRef(…)))`
# died with a raw `MethodError` before any SQL existed. One identity arm closes every union at once.
_check_function(x::OuterRefObject) = x

# #444 — retag a resolved column expression so its terminal column becomes a CTE handle.
#
# The parse pipeline for a CTE reference deliberately runs on `ref.path` ALONE, which lets it reuse
# every existing String code path unchanged — operator-suffix peeling, transform-function
# construction, and all fifteen RHS-typed `_get_pair_to_oper` validations. What that leaves behind is
# a plain `"seen"` where a CTE-scoped reference belongs, so this walks the result and swaps it.
#
# Shape and boundary are copied from `_prefix_join_filter` (join_conditions.jl), which already does this kind of
# recursive rewrite: descend `.column` / `.field` only, NEVER `kwargs`. That boundary is load-bearing
# here — `Y_M(["seen"])` is `ToChar(x, "YYYY-MM", …)` (functions.jl), so the format literal sits in
# kwargs and retagging it would corrupt the rendered function.
#
# #481 widened the walk. A COMPOSITE transform does not build a bare function over the column: the
# `@yyyy_q` / `@yyyy_quad` keys expand to `Concat([Cast(Year(x)), Value("-Q"), Case([When(...)])])`
# (`functions.jl`), so the walk also meets an `SQLText` literal, an `SQLField` wrapper and the
# `OperObject` inside each `When`. (#579 moved that expansion off `@quarter` / `@quadrimester`, which
# now extract the period number through one dialect function and reach none of these arms.)
# Without these three arms `CTE("ev","seen__@yyyy_q")` — and the
# `Joined` twin below — died on the catch-all with an "Internal … please report" message for a
# documented transform. An `SQLText` is a LITERAL (the `"-Q"` separator) and must never be retagged,
# which is the same boundary the `kwargs` rule above draws.
_retag_cte_column(x::String, name::String) = CTEReference(name=name, path=x)
_retag_cte_column(x::CTEReference, ::String) = x
_retag_cte_column(x::SQLTypeText, ::String) = x
# #508 phase 2 — these arms CONSTRUCT. The `SQLTypeFunction` arm splits in two because `FObject` and
# `WindowFunction` do not share a slot list: only the latter carries `over`.
#
# `kwargs` rides across BY REFERENCE here, unlike `_check_function`'s shallow copy above. The node
# reaching this walker is already the build product `_check_function` returned, so its `kwargs` is a
# fresh Dict the user's handle does not share — and the caller replaces the original rather than
# keeping it alongside, so there are never two live nodes over one Dict. Copying again would only
# make the retag allocate more than the mutating form it replaces.
function _retag_cte_column(x::FObject, name::String)
  return FObject(function_name=x.function_name, column=_retag_cte_column(x.column, name),
                 aggregate=x.aggregate, formatter=x.formatter, _as=x._as, kwargs=x.kwargs)
end
# No `nothing` guard on `column`, deliberately: the mutating form called `_retag_cte_column` on it
# unconditionally, so a column-less window function reaching this walker hit the catch-all and threw
# "Internal: … Please report this (#444)". Adding a guard here would convert that loud internal error
# into a silent pass — a behaviour change smuggled into a refactor that owes byte-identical output.
# (The `_retag_cte_string` twin in `ctes.jl` needs none: its catch-all RETURNS `x` for `nothing`.)
function _retag_cte_column(x::WindowFunction, name::String)
  return WindowFunction(function_name=x.function_name, column=_retag_cte_column(x.column, name),
                        over=x.over, aggregate=x.aggregate, formatter=x.formatter,
                        _as=x._as, kwargs=x.kwargs)
end
# `::SQLField`, not `::SQLTypeField`: `SQLTypeOrder <: SQLTypeField`, so the abstract signature also
# accepts an `SQLOrder` and would write its `.field` — a slot that means something entirely
# different. #533 removes that subtype relation; narrowing here is correct either way. `SQLField` is
# a build product and stays mutable, so this arm still writes.
function _retag_cte_column(x::SQLField, name::String)
  x.field = _retag_cte_column(x.field, name)
  return x
end
function _retag_cte_column(x::SQLTypeOper, name::String)
  return OperObject(operator=x.operator, values=x.values, column=_retag_cte_column(x.column, name))
end
_retag_cte_column(x::Vector, name::String) = Any[_retag_cte_column(v, name) for v in x]
function _retag_cte_column(x, ::String)
  throw(QueryBuildError(
    "Internal: a CTE reference resolved to an unexpected column expression (::$(typeof(x))). " *
    "Please report this (#444)."))
end

# Top-level entry: retag the SQLField a String-path parse produced, and restore the `name__path`
# spelling on `_as`. Keeping `_as` byte-identical to the pre-#444 string form is what lets every
# `_as`-keyed consumer downstream keep working untouched — the projection memo, the field memo,
# ORDER BY alias matching, the #352/#373 sargable date rewrite, the #441 duplicate-projection guard,
# and the result-column names users index DataFrames by.
function _retag_cte_field!(field::SQLField, name::String)
  field.field = _retag_cte_column(field.field, name)
  field._as === nothing || (field._as = _cte_as(name, field._as))
  # #474 — the single site that marks an expression CTE-rooted. `_as` keeps the `name__path`
  # spelling #444 pinned (it is the output column name); the MEMO moves to the other half of a
  # `MemoKey`, so a field path spelled identically can no longer read or claim this entry.
  field.root = :cte
  return field
end

# #481 — the joined-copy twin of the helpers above, arm for arm (see the composite-transform note
# there for why `SQLTypeText` / `SQLTypeField` / `SQLTypeOper` are walked).
#
# Never actually reached today: every entry point (`_check_filter`, `_values_field`, `_order_by!`)
# delegates on `ref.path`, which is a `String`, so `_check_function` sees the path and not the
# handle. Defined for symmetry with the CTE twin, and so a future caller that does pass a handle
# gets the identity rather than a MethodError.
_check_function(x::JoinedReference) = x

_retag_joined_column(x::String, alias::String) = JoinedReference(alias, x, false)
_retag_joined_column(x::JoinedReference, ::String) = x
_retag_joined_column(x::SQLTypeText, ::String) = x
# #508 phase 2 — the CTE twin's arms, construct for construct (see the note there for why the
# function arm splits and why `kwargs` rides across by reference).
function _retag_joined_column(x::FObject, alias::String)
  return FObject(function_name=x.function_name, column=_retag_joined_column(x.column, alias),
                 aggregate=x.aggregate, formatter=x.formatter, _as=x._as, kwargs=x.kwargs)
end
function _retag_joined_column(x::WindowFunction, alias::String)
  return WindowFunction(function_name=x.function_name, column=_retag_joined_column(x.column, alias),
                        over=x.over, aggregate=x.aggregate, formatter=x.formatter,
                        _as=x._as, kwargs=x.kwargs)
end
function _retag_joined_column(x::SQLField, alias::String)
  x.field = _retag_joined_column(x.field, alias)
  return x
end
function _retag_joined_column(x::SQLTypeOper, alias::String)
  return OperObject(operator=x.operator, values=x.values, column=_retag_joined_column(x.column, alias))
end
_retag_joined_column(x::Vector, alias::String) = Any[_retag_joined_column(v, alias) for v in x]
function _retag_joined_column(x, ::String)
  throw(QueryBuildError(
    "Internal: a Joined reference resolved to an unexpected column expression (::$(typeof(x))). " *
    "Please report this (#481)."))
end

function _retag_joined_field!(field::SQLField, alias::String)
  field.field = _retag_joined_column(field.field, alias)
  field._as === nothing || (field._as = _joined_as(alias, field._as))
  field.root = :joined
  return field
end


# ─────────────────────────────────────────────────────────────────────────────
# Invalid filter-operator diagnostics (#98)
#
# The scalar/function path (_check_function) already emits a rich "valid function
# / valid operator" message. The vector, subquery, and tuple value paths used to
# throw a terse message that neither listed the valid operators nor distinguished
# a typo (unknown operator, e.g. @notin) from a known operator that simply is not
# valid for that value shape (e.g. @gte with a vector). _raise_invalid_filter_operator
# gives all three shapes one consistent, actionable error, with a nearest-match
# "did you mean" suggestion for typos.
# ─────────────────────────────────────────────────────────────────────────────

# Nearest valid operator suffix to `suffix`, or nothing when nothing is close enough
# to be a plausible typo (so garbage input does not get a nonsense suggestion).
# Uses the shared Kernel `_suggest_name` helper with the same threshold (#365).
_suggest_operator(suffix::AbstractString)::Union{Nothing,String} =
  _suggest_name(suffix, keys(PormGsuffix))

# Consistent, actionable error for a filter operator that is not valid for the given
# value shape. `field_path` is the split lookup (…, suffix); `shape` is a human word
# ("vector", "subquery", "tuple"); `allowed` is the operator subset valid for that shape.
function _raise_invalid_filter_operator(field_path::Vector{String}, shape::AbstractString, allowed::Vector{String})
  all_opers = join(map(k -> "@" * k, sort!(collect(keys(PormGsuffix)))), ", ")
  allowed_opers = join(map(a -> "@" * a, allowed), ", ")
  if length(field_path) < 2
    # No __@ suffix at all: a bare field was paired with a $shape value.
    field = field_path[end]
    examples = join(map(a -> "$(field)__@" * a, allowed), ", ")
    throw(FilterError("Error in filter: field \e[31m$(field)\e[0m was given a $(shape) value but no operator.\n" *
                  "With a $(shape) value, use one of: $(examples)"))
  end
  suffix = field_path[end]
  if !haskey(PormGsuffix, suffix)
    # Unknown operator — typo or nonexistent. List every valid operator and, when the
    # input looks like a near-miss, suggest the intended one (e.g. @notin → @nin).
    suggestion = _suggest_operator(suffix)
    hint = suggestion === nothing ? "" : " Did you mean \e[32m@$(suggestion)\e[0m?"
    throw(FilterError("Error in filter: \e[31m@$(suffix)\e[0m is not a valid operator.$(hint)\n" *
                  "Valid operators: $(all_opers)\n" *
                  "With a $(shape) value, use one of: $(allowed_opers)"))
  else
    # Known operator, but not valid for this value shape (e.g. @gte with a vector).
    throw(FilterError("Error in filter: operator \e[31m@$(suffix)\e[0m is not valid with a $(shape) value.\n" *
                  "With a $(shape) value, use one of: $(allowed_opers)"))
  end
end

# #654: the two lookups whose value SHAPE is fixed, checked where the vector arm checks range
# arity. A scalar `@range` reached the renderer and indexed `[2]` into it — a raw `BoundsError`
# in WHERE, and in HAVING once #654 let an alias reach the range binder. A non-`Bool` `@isnull`
# reached `ISNULL` as a `MethodError`, and once that arm joined the shared ladder, as
# "ISNULL is not a supported operator" — a token nobody types, blaming the operator for the value.
#
# #808: every single-value arm calls it, not only the scalar one. The column-reference arms (`F`,
# a function, `Joined`, `CTE`) skipped it, so `"points__@isnull" => F("grid")` rendered
# `ISNULL "Tb"."grid"` and `@range => F(…)` a one-sided `BETWEEN` — both invalid SQL, surfacing at
# the database — and on a JSON path `@isnull` reached `v.values == true`, which on an expression
# builds a predicate (#541) and raised `TypeError: non-boolean`.
function _check_fixed_shape_lookup(suffix::AbstractString, value)
  suffix in ("range", "nrange") &&
    throw(FilterError("Error in filter, '$(suffix)' operator requires exactly 2 values, got 1"))
  suffix == "isnull" && !(value isa Bool) &&
    throw(FilterError("Error in filter, 'isnull' takes true or false, got $(value isa SQLType ? "a column expression" : "a $(typeof(value))")"))
  # #28: an array lookup compares two arrays, so its value is a list even for one element. A scalar is
  # refused rather than wrapped — and a bare String would otherwise be read as array-literal text
  # (`"SOFT"` is not one). A column expression is left to `_check_column_rhs_lookup`, which owns that
  # message on the column arms.
  suffix in ARRAY_CONTAINMENT_OPERATORS && !(value isa SQLType) &&
    throw(FilterError("Error in filter, '$(suffix)' takes a list of elements, even for one: " *
                      "wrap the value in a Vector, \e[4m\e[32m[value]\e[0m; got a single $(typeof(value))"))
  return nothing
end

# #997: true for the `@yyyy_q` / `@yyyy_quad` label column — a `Concat` node that `Y_Q` / `Y_QUAD`
# flagged `propagate_null`, so it renders `||` on both engines and is NULL exactly when its date is.
# That is what makes `<label> IS NULL` mean "the date is NULL", and so what licenses it in `ISNULL`.
# The narrowness is a fail-safe no test can pin: no other public spelling reaching that arm renders
# a call today, so a licence granted to every column would render the same SQL.
_is_null_propagating_label(c) =
  c isa SQLTypeField && c.field isa FObject && get(c.field.kwargs, "propagate_null", false) === true

# #811: the lookups whose right-hand side is never a single column, refused on the column-reference
# arms only (`F`, a function, `Joined`, `CTE`) — the scalar arm's `@in` binds a one-element list, which
# is fine. A column is not a list, so `"points__@in" => F("grid")` rendered `IN "Tb"."grid"`, invalid
# SQL found by the server; `IN CASE WHEN … END` likewise. Refused here, at parse, rather than in the
# renderer: every spelling — `filter`, `Q`/`Qor`, `When`, `cjoin_on(on = …)`, a HAVING alias — reaches
# these arms, so they all refuse the same way, on both engines.
#
# #793: the LIKE family, for the same reason one step removed. Its value is a text fragment that
# `add_parameter!` wraps in `%` and LIKE-escapes, and neither can happen to a column, so the arm
# concatenated the lookup NAME — `"Tb"."surname" contains "Tb"."forename"`, and no
# `BackendCapabilityError` for `iunaccent_contains` on SQLite. Rendering `'%' || col || '%'` would
# work, but the column's own `%` and `_` would then match as wildcards, unescaped. Refused instead
# (the maintainer's call on #793). Every name in `LIKE_WILDCARD_OPERATORS` is also its own
# `PormGsuffix` key, so the suffix is the membership test. The verbatim pattern lookups
# (`@regex`, `@iunaccent_exact`) take a column as-is and are not refused (#635).
function _check_column_rhs_lookup(path::Vector{String})
  suffix = path[end]
  lookup = join(path, "__@")
  suffix in ("in", "nin") &&
    throw(FilterError("Error in filter '$(lookup)': '$(suffix)' takes a list of values or a subquery, " *
                      "not a column expression"))
  suffix in LIKE_WILDCARD_OPERATORS &&
    throw(FilterError("Error in filter '$(lookup)': '$(suffix)' matches a text value, " *
                      "not a column expression"))
  # #811, found in review: the JSON containment operators render in `_render_json_operator`, ahead of
  # every column-RHS arm, and `has_key` bound `string(v.values)` — the expression's `repr` as the key,
  # zero rows on PostgreSQL. Each takes a key, a key list or a document, never a column.
  suffix in JSON_CONTAINMENT_OPERATORS &&
    throw(FilterError("Error in filter '$(lookup)': '$(suffix)' takes a JSON key or document value, " *
                      "not a column expression"))
  # #28: the array lookups bind their value as one array literal (`_render_array_operator`), which a
  # column cannot become. Comparing two array COLUMNS (`@>` against another `ArrayField`) is valid SQL
  # and Django has it; PormG does not render it yet, so it is refused here rather than bound as a value.
  suffix in ARRAY_CONTAINMENT_OPERATORS &&
    throw(FilterError("Error in filter '$(lookup)': '$(suffix)' takes a list of element values, " *
                      "not a column expression"))
  return nothing
end

"""
  _get_pair_to_oper(x::Pair)

  Converts a Pair object to an OperObject. If the Pair's key is a string, it checks if it contains an operator suffix (e.g. "__@gte", "__@lte") and returns an OperObject with the corresponding operator. If the key does not contain an operator suffix, it returns an OperObject with the "=" operator. If the key is not a string, it throws an error.

  ## Arguments
  - `x::Pair`: A Pair object to be converted to an OperObject.

  ## Returns
  - `OperObject`: An OperObject with the corresponding operator and values.

"""
function _get_pair_to_oper(x::Pair{Vector{String},T}) where T<:Union{AbstractString,Number,Bool,Dates.TimeType,Dates.Period,Dates.CompoundPeriod,Base.UUID}
  if haskey(PormGsuffix, x.first[end])
    _check_fixed_shape_lookup(x.first[end], x.second)
    return OperObject(operator=PormGsuffix[x.first[end]], values=x.second, column=SQLField(_check_function(x.first[1:end-1]), join(x.first[1:end-1], "__")))
  else
    return OperObject(operator="=", values=x.second, column=SQLField(_check_function(x.first), join(x.first, "__"))) # TODO, maybe I need to check if the column is valid and process the function before store
  end
end
# `Sockets.IPAddr` (#28): a network-address field takes one on write, so a filter — and the lookup
# `get_or_create` builds from its pairs — must take one too. It used to fall off this ladder as a raw
# `MethodError`, and `get_or_create` failed on a hit where `create` succeeded. Taken as its printed
# text (`format_inet_sql`) — `OperObject` carries no address type of its own. The printed form, not
# `string(ip)`: Sockets prints `::ffff:1.2.3.4` as `::ffff:102:304`, which a network field's formatter
# would re-normalize but a text column compared against it would not match.
_get_pair_to_oper(x::Pair{Vector{String},T}) where T<:Sockets.IPAddr =
  _get_pair_to_oper(x.first => Models.format_inet_sql(x.second))
_get_pair_to_oper(x::Pair{Vector{String},Vector{T}}) where T<:Sockets.IPAddr =
  _get_pair_to_oper(x.first => String[Models.format_inet_sql(v) for v in x.second])
# #635: a Julia `Regex` is PCRE, while the `@regex` family is evaluated by PostgreSQL as POSIX ARE.
# Accepting the object would reinterpret its pattern in the other dialect — the divergence #635
# refused to ship — so it is refused with the spelling that works. It used to fall off this ladder
# as a bare `MethodError` naming an internal function.
function _get_pair_to_oper(x::Pair{Vector{String},Regex})
  key = join(x.first, "__@")
  op = x.first[end]
  # Suggest the pattern spelling only where it is the pattern lookup the user already chose; on any
  # other lookup a `@regex` suggestion would be a detour into a PostgreSQL-only feature.
  if op in ("regex", "iregex", "nregex", "niregex")
    # A string carries no flags, so `r"^sen"i` must be suggested as the case-insensitive twin —
    # echoing `@regex` would silently turn it case-sensitive.
    caseless = (x.second.compile_options & Base.PCRE.CASELESS) != 0
    suggested = caseless && op in ("regex", "nregex") ?
      join([x.first[1:end-1]..., op == "regex" ? "iregex" : "niregex"], "__@") : key
    hint = "Pass the pattern as a String, e.g. \"$(suggested)\" => $(repr(x.second.pattern)); " *
           "PostgreSQL evaluates it as a POSIX regular expression"
  else
    hint = "Pass the value as a String"
  end
  throw(FilterError("Error in filter '$(key)': a Julia Regex is not a filter value. $(hint)"))
end
function _get_pair_to_oper(x::Pair{String,T}) where T<:Union{AbstractString,Number,Bool,Dates.Date,Dates.DateTime,Dates.TimeType,Dates.Period,Dates.CompoundPeriod}
  return _get_pair_to_oper(String.(split(x.first, "__@")) => x.second)
end
# A FLAT `Vector{UInt8}` is one binary payload, not a list of small numbers (#596).
#
# `UInt8 <: Number`, so a byte payload used to land in the vector arm below, whose every branch
# slices `x.first[1:end-1]` — it assumes the last path segment is the operator. With a bare path
# nothing matched and the pair was refused as "a vector value but no operator", which is the
# spelling #411's own error message had prescribed as the workaround for `blob__@in`. It never worked.
#
# This method is strictly more specific than that arm, so it wins dispatch, and it mirrors the scalar
# shape above exactly: a `PormGsuffix` key in the last segment delegates back to the ladder (so
# `blob__@in => UInt8[1, 2]` keeps meaning a two-element IN list of the numbers 1 and 2), and a bare
# path builds the equality the scalar arm builds.
#
# It deliberately does NOT decide whether the field is binary. It cannot: `_check_filter` is handed
# only the pair, and the `Q` / `Qor` / `When` routes reach it with no model at all — a parse-time
# decision would fix `filter("blob" => bytes)` and leave `filter(Q("blob" => bytes))` refused. The
# render path already resolves the field, applies `format_binary_sql` and binds one blob through the
# scalar `PormGBytes` collector arms; the type check for a NON-binary field lives there with it, so
# every spelling behaves the same.
#
# The distinction is unambiguous by type: `Vector{Vector{UInt8}}` (a list of payloads, #466) and
# `Vector{Int}` are different types and still take the vector arm.
#
# ONLY the bare-path case is this method's business. A suffixed path goes to
# `_vector_oper_from_suffix` — the vector arm's own ladder, shared rather than restated, because
# restating it is how the first cut of this fix lost the `@range` arity check and the
# wrong-operator refusal. `PormGsuffix` is the right membership test for "is the last segment an
# operator": a TRANSFORM segment (`@year`, `@yyyy_mm`) is not in it, so `date__@year => bytes` stays a
# bare-path equality over a transform column and is refused at render like any other non-binary field.
function _get_pair_to_oper(x::Pair{Vector{String},Vector{UInt8}})
  haskey(PormGsuffix, x.first[end]) && return _vector_oper_from_suffix(x)
  return OperObject(operator="=", values=x.second, column=SQLField(_check_function(x.first), join(x.first, "__")))
end
function _get_pair_to_oper(x::Pair{String,Vector{UInt8}})
  return _get_pair_to_oper(String.(split(x.first, "__@")) => x.second)
end
# Widened alongside its `Pair{Vector{String},…}` twin below (#411). Not reachable from
# `_check_filter`, which splits the key at `__@` first — but leaving one of a matched pair behind
# is the drift that bites whoever calls it directly next.
function _get_pair_to_oper(x::Pair{String,Vector{T}}) where T<:Union{Missing,AbstractString,Number,Bool,Dates.TimeType,Dates.Period,Dates.CompoundPeriod,Base.UUID,AbstractVector{UInt8}}
  return _get_pair_to_oper(String.(split(x.first, "__@")) => x.second)
end
# Store SQLObject, to use __@in operator
function _get_pair_to_oper(x::Pair{Vector{String},T}) where T<:SQLObjectHandler
  if x.first[end] in ["in", "nin"]
    # @pormg_debug
    return OperObject(operator=PormGsuffix[x.first[end]], values=x.second, column=SQLField(_check_function(x.first[1:end-1]), join(x.first[1:end-1], "__")))
  else
    _raise_invalid_filter_operator(x.first, "subquery", ["in", "nin"])
  end
end
# #444 — `filter("raceid" => CTE("r91", "raceid"))`: the RHS is a COLUMN reference, not a value.
# Same shape as the SQLTypeF method below it (that is the idiom `F("r91__raceid")` used pre-#444).
function _get_pair_to_oper(x::Pair{Vector{String},T}) where T<:SQLTypeCTE
  _reject_cte_desc(x.second, "a filter comparison")
  if haskey(PormGsuffix, x.first[end])
    _check_fixed_shape_lookup(x.first[end], x.second)
    _check_column_rhs_lookup(x.first)
    return OperObject(operator=PormGsuffix[x.first[end]], values=x.second, column=SQLField(_check_function(x.first[1:end-1]), join(x.first[1:end-1], "__")))
  else
    return OperObject(operator="=", values=x.second, column=SQLField(_check_function(x.first), join(x.first, "__")))
  end
end
# #481 — the same shape for a joined-copy handle on the RHS:
# `filter("driverid" => Joined("d", "driverid"))` compares two columns.
function _get_pair_to_oper(x::Pair{Vector{String},T}) where T<:SQLTypeJoined
  _reject_joined_desc(x.second, "a filter comparison")
  if haskey(PormGsuffix, x.first[end])
    _check_fixed_shape_lookup(x.first[end], x.second)
    _check_column_rhs_lookup(x.first)
    return OperObject(operator=PormGsuffix[x.first[end]], values=x.second, column=SQLField(_check_function(x.first[1:end-1]), join(x.first[1:end-1], "__")))
  else
    return OperObject(operator="=", values=x.second, column=SQLField(_check_function(x.first), join(x.first, "__")))
  end
end
# #863: the right-hand side is walked like a projection (`_walk_slot`), so a transform inside it
# resolves: `filter("seen__@gte" => Max("ts__@date"))` and `F("id") + Coalesce("ts__@year", 0)`. Every
# pair spelling reaches these two methods — `filter`, `Q`/`Qor`, `When` conditions, CTE- and
# Joined-keyed pairs, `.on`/`.cjoin`/`.cjoin_on` — so this is the one place to do it.
function _get_pair_to_oper(x::Pair{Vector{String},T}) where T<:SQLTypeF
  if haskey(PormGsuffix, x.first[end])
    _check_fixed_shape_lookup(x.first[end], x.second)
    _check_column_rhs_lookup(x.first)
    return OperObject(operator=PormGsuffix[x.first[end]], values=_walk_slot(x.second), column=SQLField(_check_function(x.first[1:end-1]), join(x.first[1:end-1], "__")))
  else
    return OperObject(operator="=", values=_walk_slot(x.second), column=SQLField(_check_function(x.first), join(x.first, "__")))
  end
end
# #926: a scalar `Subquery(...)` is a filter value — `filter("grid" => Subquery(…))` renders
# `WHERE "grid" = (SELECT …)`, Django's `filter(grid=Subquery(…))`. It raised a raw `MethodError`
# naming this function on every pair spelling (`filter`, `Q`/`Qor`, `When`, `on`, `cjoin_on`). Shaped
# like the function arm below: a subquery is one value per row, not a list and not a text fragment,
# so the column-RHS refusals apply — except that `@in` gets its own hint, because the membership
# spelling already takes a subquery: the query itself, unwrapped (the `SQLObjectHandler` arm above).
function _get_pair_to_oper(x::Pair{Vector{String},SubqueryObject})
  suffix = x.first[end]
  if suffix in ("in", "nin")
    lookup = join(x.first, "__@")
    throw(FilterError("Error in filter '$(lookup)': '$(suffix)' takes the query itself, not a scalar " *
                      "Subquery(...) — pass it unwrapped, \e[4m\e[32m\"$(lookup)\" => query\e[0m."))
  end
  if haskey(PormGsuffix, suffix)
    _check_fixed_shape_lookup(suffix, x.second)
    _check_column_rhs_lookup(x.first)
    return OperObject(operator=PormGsuffix[suffix], values=x.second, column=SQLField(_check_function(x.first[1:end-1]), join(x.first[1:end-1], "__")))
  else
    return OperObject(operator="=", values=x.second, column=SQLField(_check_function(x.first), join(x.first, "__")))
  end
end
# Allow Case/When and other FObject expressions as filter RHS values
function _get_pair_to_oper(x::Pair{Vector{String},T}) where T<:SQLTypeFunction
  if haskey(PormGsuffix, x.first[end])
    _check_fixed_shape_lookup(x.first[end], x.second)
    _check_column_rhs_lookup(x.first)
    return OperObject(operator=PormGsuffix[x.first[end]], values=_check_function(x.second), column=SQLField(_check_function(x.first[1:end-1]), join(x.first[1:end-1], "__")))
  else
    return OperObject(operator="=", values=_check_function(x.second), column=SQLField(_check_function(x.first), join(x.first, "__")))
  end
end
# `Base.UUID` and `AbstractVector{UInt8}` (#411, #466): without them a `Vector{UUID}` or a
# `Vector{Vector{UInt8}}` right-hand side never reached this method at all, so `__@in` on a UUIDField
# or a BinaryField failed at PARSE time with a MethodError — before any formatter ran, which is why
# mapping the formatter at the call site does not fix those two on its own. #411 admitted the UUID
# and refused the binary list by name, because the ARRAY collectors did not unwrap `PormGBytes`;
# #466 taught them to, so a binary list takes the ordinary vector arm below.
# A FLAT `Vector{UInt8}` — one payload rather than a list of them — does NOT take that arm: #596 gave
# it its own, strictly more specific method above, because every branch here slices off a trailing
# operator segment that a bare field path does not have.
# `Vector{Any}` (#411). `[]` — the way anyone writes an empty list, and what `ids = []` gives you
# before the first `push!` — is `Vector{Any}`, and `Any` satisfies none of the element bounds the
# methods below dispatch on. So the most natural spelling of an empty membership list raised a
# `MethodError` naming `_get_pair_to_oper` and a tuple type nobody typed: the exact untyped-error
# class this pair of issues exists to remove, on the one shape the documentation shows.
#
# `_normalize_filter_pair`'s comprehension already narrows a NON-empty `Any[…]` whose elements share
# a type, which is why `Any[UInt8[1], UInt8[2]]` reaches the binary guard correctly. It cannot narrow
# an empty one — there is nothing to infer from — so that case is handled here.
function _get_pair_to_oper(x::Pair{Vector{String},Vector{Any}})
  # Empty: no element type to preserve, because nothing is ever bound. `String[]` is as good as any.
  isempty(x.second) && return _get_pair_to_oper(x.first => String[])
  narrowed = identity.(x.second)
  # Genuinely heterogeneous — narrowing changed nothing, so re-dispatching would recurse forever.
  # Report it as what it is rather than looping or leaking a MethodError.
  narrowed isa Vector{Any} && throw(FilterError(
    "The filter \e[4m\e[31m$(join(x.first, "__"))\e[0m was given a list whose values do not share " *
    "a type: \e[4m\e[31m$(join(unique(typeof.(x.second)), ", "))\e[0m. A membership list must be " *
    "homogeneous — build it as a typed vector, e.g. \e[1mInt[…]\e[0m or \e[1mString[…]\e[0m."))
  return _get_pair_to_oper(x.first => narrowed)
end

# #918: a list of query NODES — `"grid__@in" => [F("raceid")]`, `[Lower("surname")]`, `[Max("grid")]`,
# a `CTE`/`Joined` handle, a subquery — matched no arm above and raised a raw `MethodError` naming this
# function. Refused, typed, as #793/#811 refuse ONE column expression on `@in` (`_check_column_rhs_lookup`):
# a membership list holds values, and accepting columns would reopen that decision and give the
# membership renderer — which binds the whole list — an inline-column arm on each engine.
#
# The element bound is the node families, not `PormGAbstractType`, because `PormGBytes` is one too and
# a binary payload is a value. `Vector{PormGAbstractType}` is admitted by name: it is what Julia infers
# for `[F("a"), subquery]`, whose two node families share nothing narrower. A mixed node/value list
# (`[1, F("a")]`) is `Vector{Any}` and keeps the heterogeneity refusal above.
function _get_pair_to_oper(x::Pair{Vector{String},<:Union{AbstractVector{<:Union{SQLType,SQLObject}},Vector{PormGAbstractType}}})
  # An empty list binds nothing, whatever its element type — the `Vector{Any}` arm's reasoning.
  isempty(x.second) && return _get_pair_to_oper(x.first => String[])
  suffix = x.first[end]
  lookup = join(x.first, "__@")
  kinds = join(unique(string.(nameof.(typeof.(x.second)))), ", ")
  if suffix in ("in", "nin") && all(v -> v isa SQLObjectHandler, x.second)
    # A subquery wrapped in a list — the fix is to unwrap it, not to compare columns (#918, review).
    throw(FilterError("Error in filter '$(lookup)': '$(suffix)' takes a subquery directly, not inside a " *
                      "list — pass it as \e[4m\e[32m\"$(lookup)\" => subquery\e[0m."))
  elseif suffix in ("in", "nin")
    # The spelling that works, per polarity: IN is an OR of equalities, NOT IN an AND of inequalities.
    f = "F(\"$(join(x.first[1:end-1], "__@"))\")"
    hint = suffix == "in" ?
      "OR the equalities — \e[4m\e[32mQor($(f) == F(\"a\"), $(f) == F(\"b\"))\e[0m" :
      "AND the inequalities — \e[4m\e[32mQ($(f) != F(\"a\"), $(f) != F(\"b\"))\e[0m"
    throw(FilterError("Error in filter '$(lookup)': '$(suffix)' takes a list of values or a subquery, " *
                      "not a list of column expressions ($(kinds)). To compare against several columns, " *
                      "$(hint)."))
  end
  throw(FilterError("Error in filter '$(lookup)': a list of column expressions ($(kinds)) is not a " *
                    "filter value. A list right-hand side holds literal values."))
end

function _get_pair_to_oper(x::Pair{Vector{String},Vector{T}}) where T<:Union{Missing,AbstractString,Number,Bool,Dates.TimeType,Dates.Period,Dates.CompoundPeriod,Base.UUID,AbstractVector{UInt8}}
  return _vector_oper_from_suffix(x)
end

# #28: every other vector right-hand side — in practice a list of vectors, `"tags__@in" => [[1], [2]]`,
# the shape an `ArrayField` membership list would take. It used to match no method and leak a raw
# `MethodError`. A membership list of whole arrays is not supported: the PostgreSQL membership render
# binds the list as ONE array parameter, and an array of arrays is a single two-dimensional value, not
# a list of them. Strictly less specific than every arm above, so it only catches what they do not.
function _get_pair_to_oper(x::Pair{Vector{String},<:AbstractVector})
  lookup = join(x.first, "__@")
  path = join(haskey(PormGsuffix, x.first[end]) ? x.first[1:end-1] : x.first, "__")
  # A `nothing` among values is the other shape that lands here (`["SOFT", nothing]` is a
  # `Vector{Union{Nothing, String}}`). In a filter value a NULL element is spelled `missing` — except
  # in an array lookup, which takes no NULL element in either spelling (`_refuse_null_array_element`).
  x.first[end] in ARRAY_CONTAINMENT_OPERATORS && _refuse_null_array_element(x.second, lookup)
  any(isnothing, x.second) && throw(FilterError(
    "Error in filter '$(lookup)': a filter value cannot hold `nothing`; write a NULL element as " *
    "`missing` — \e[4m\e[32m\"$(path)\" => [\"SOFT\", missing]\e[0m."))
  kinds = join(unique(string.(typeof.(x.second))), ", ")
  throw(FilterError("Error in filter '$(lookup)': a list of $(kinds) values is not a filter value. " *
                    "To match an ArrayField against several whole arrays, OR the equalities: " *
                    "\e[4m\e[32mQor(\"$(path)\" => [1, 2], \"$(path)\" => [3])\e[0m."))
end

# The suffix ladder for a VECTOR right-hand side, extracted so the `Vector{UInt8}` method above can
# reach it (#596). It cannot get here by delegation — a `Pair{Vector{String},Vector{UInt8}}` dispatches
# to its own, more specific method — and the first cut of #596 reimplemented the two-branch SCALAR
# shape instead. That silently dropped all four guards below: `blob__@gt => UInt8[1,2]` built a
# comparison against a vector (`WHERE "n" > ?, ?`, a syntax error), `@icontains` reached
# `format_text_sql(::UInt8)` as an untyped `MethodError`, and `@range => UInt8[1,2,3]` rendered a
# silently TRUNCATED `BETWEEN` over the first two bytes — the exact silent-wrong-query shape #596 set
# out to remove, reintroduced one method up. One body, two callers, so a guard cannot be missing from
# one of them.
function _vector_oper_from_suffix(x::Pair{Vector{String},<:AbstractVector})
  suffix = x.first[end]
  # #28: a bare path — the last segment is no operator — is an equality against the WHOLE vector, the
  # meaning an `ArrayField` gives it. Built here without knowing the field, as the `Vector{UInt8}` arm
  # above builds a binary equality, and for the same reason: `Q`/`Qor`/`When` reach this ladder with
  # no model. The render resolves the field and refuses the vector for any other column
  # (`_guard_vector_equality`), with the "no operator" message this ladder used to give at parse time.
  #
  # Only a path with no `__@` segment, whose last `__` segment is not an operator name: `surname__in`
  # is a typo for `surname__@in`, and keeps the "no operator" message that names the fix.
  if length(x.first) == 1 && !haskey(PormGsuffix, last(split(x.first[1], "__")))
    return OperObject(operator="=", values=x.second, column=SQLField(_check_function(x.first), join(x.first, "__")))
  end
  if suffix in ["in", "nin"]
    @pormg_debug false
    return OperObject(operator=PormGsuffix[suffix], values=x.second, column=SQLField(_check_function(x.first[1:end-1]), join(x.first[1:end-1], "__")))
  elseif suffix in ("range", "nrange")   # #207: nrange = NOT BETWEEN, same 2-value shape
    if length(x.second) != 2
      throw(FilterError("Error in filter, '$(suffix)' operator requires exactly 2 values, got $(length(x.second))"))
    end
    return OperObject(operator=PormGsuffix[suffix], values=x.second, column=SQLField(_check_function(x.first[1:end-1]), join(x.first[1:end-1], "__")))
  elseif suffix in ("has_any_keys", "has_keys")
    # #27: JSONB overlap operators (?| / ?&) take an array of keys; the render branch binds the
    # vector as a single text[] parameter.
    return OperObject(operator=PormGsuffix[suffix], values=x.second, column=SQLField(_check_function(x.first[1:end-1]), join(x.first[1:end-1], "__")))
  elseif suffix == "jcontains"
    # #27: JSONB array containment (@>) with a vector RHS — serialize to a JSON document string at
    # parse time so OperObject.values stays a String (no downstream type-union change).
    return OperObject(operator="jcontains", values=Models.format_json_sql(x.second), column=SQLField(_check_function(x.first[1:end-1]), join(x.first[1:end-1], "__")))
  elseif suffix in ARRAY_CONTAINMENT_OPERATORS
    # #28: the vector stays as written — formatting it needs the ELEMENT field, which only the render
    # knows (`_render_array_operator`). A NULL element is refused now, while the lookup is in hand.
    _refuse_null_array_element(x.second, join(x.first, "__@"))
    return OperObject(operator=suffix, values=x.second, column=SQLField(_check_function(x.first[1:end-1]), join(x.first[1:end-1], "__")))
  else
    _raise_invalid_filter_operator(x.first, "vector", _VECTOR_VALUE_OPERATORS)
  end
end

# The lookups that take a vector right-hand side — the `allowed` list every "a vector needs one of
# these operators" refusal names. One list, because it was restated as a literal at three sites (here,
# `_guard_vector_equality`, and its alias twin in `projection_types.jl`) and #28 had to grow all three.
const _VECTOR_VALUE_OPERATORS = ["in", "nin", "range", "nrange", "has_any_keys", "has_keys", "jcontains",
                                 ARRAY_CONTAINMENT_OPERATORS...]

# #28: a NULL element in an array lookup's value. PostgreSQL's `@>`, `<@` and `&&` compare elements
# with `=`, so a NULL never matches anything — not even a NULL element of the column. Rendering it
# would be a filter that silently drops what the caller asked for; `@isnull` is the NULL test.
function _refuse_null_array_element(values::AbstractVector, lookup::AbstractString)
  any(v -> v === missing || v === nothing, values) || return nothing
  throw(FilterError("Error in filter '$(lookup)': an array lookup cannot match a NULL element " *
                    "(`missing`/`nothing`) — PostgreSQL compares elements with `=`, so a NULL never " *
                    "matches. Remove it from the list."))
end
# #27: JSONB document containment (@>) with a Dict / NamedTuple RHS — serialize at parse time so
# OperObject.values stays a String.
function _get_pair_to_oper(x::Pair{Vector{String},<:AbstractDict})
  x.first[end] == "jcontains" || _raise_invalid_filter_operator(x.first, "dict", ["jcontains"])
  return OperObject(operator="jcontains", values=Models.format_json_sql(x.second), column=SQLField(_check_function(x.first[1:end-1]), join(x.first[1:end-1], "__")))
end
function _get_pair_to_oper(x::Pair{Vector{String},<:NamedTuple})
  x.first[end] == "jcontains" || _raise_invalid_filter_operator(x.first, "namedtuple", ["jcontains"])
  return OperObject(operator="jcontains", values=Models.format_json_sql(x.second), column=SQLField(_check_function(x.first[1:end-1]), join(x.first[1:end-1], "__")))
end
function _get_pair_to_oper(x::Pair{Vector{String},Tuple{T,T}}) where T
  if x.first[end] in ("range", "nrange")   # #207: nrange = NOT BETWEEN, same 2-value shape
    return OperObject(operator=PormGsuffix[x.first[end]], values=[x.second[1], x.second[2]], column=SQLField(_check_function(x.first[1:end-1]), join(x.first[1:end-1], "__")))
  elseif x.first[end] in ARRAY_CONTAINMENT_OPERATORS
    _refuse_array_lookup_tuple(x)
  else
    _raise_invalid_filter_operator(x.first, "tuple", ["range", "nrange"])
  end
end
# #28: every other Tuple — three elements, one, mixed types (`("SOFT", "MEDIUM", "HARD")`, `(12,)`,
# `("S", 1)`). None matched a method, so each leaked a raw `MethodError` naming this function. Strictly
# less specific than the 2-tuple arm above, so it only catches what that arm does not.
function _get_pair_to_oper(x::Pair{Vector{String},<:Tuple})
  suffix = x.first[end]
  suffix in ARRAY_CONTAINMENT_OPERATORS && _refuse_array_lookup_tuple(x)
  suffix in ("range", "nrange") &&
    throw(FilterError("Error in filter, '$(suffix)' operator requires exactly 2 values, got $(length(x.second))"))
  _raise_invalid_filter_operator(x.first, "tuple", ["range", "nrange"])
end
# #28: an `ArrayField` WRITE takes a Tuple, so a caller reaches for one in an array lookup too. In a
# filter a 2-tuple is `@range`'s pair (#944 kept that meaning), so the refusal names the Vector
# spelling the lookup takes rather than pointing at `@range`.
function _refuse_array_lookup_tuple(x::Pair{Vector{String},<:Tuple})
  lookup = join(x.first, "__@")
  throw(FilterError("Error in filter '$(lookup)': '$(x.first[end])' takes a Vector of elements, not a " *
                    "Tuple — \e[4m\e[32m\"$(lookup)\" => [a, b, …]\e[0m."))
end
function _get_pair_to_oper(x::Pair{Vector{String},Date})
  _get_pair_to_oper(x.first => x.second |> string)
end



# Normalize filter values at the public boundary so _get_pair_to_oper and
# OperObject always receive concrete String (not SubString or other AbstractString
# subtypes that fail the Union constraint and hold parent-string references).
function _normalize_filter_pair(value::AbstractString)
  return String(value)
end
function _normalize_filter_pair(values::AbstractVector)
  return [v isa AbstractString ? String(v) : v for v in values]
end
_normalize_filter_pair(value) = value

function _is_wildcard_projection(value)
  return false
end

function _is_wildcard_projection(value::Union{SQLTypeText,SQLTypeField})
  value isa SQLTypeText && return false
  if value.custom_as == "*" || value._as == "*"
    return true
  end
  return value.field isa String && (value.field == "*" || endswith(value.field, ".*"))
end

function _subquery_projection_labels(subquery::SQLObjectHandler)
  if isempty(subquery.object.values)
    return subquery.object.model.field_names
  end

  labels = String[]
  for value in subquery.object.values
    if _is_wildcard_projection(value)
      append!(labels, subquery.object.model.field_names)
      continue
    end

    alias = value.custom_as !== nothing ? value.custom_as : value._as

    if alias !== nothing && !isempty(alias)
      push!(labels, alias)
    elseif value isa SQLTypeField && value.field isa String
      push!(labels, value.field)
    else
      push!(labels, "<expression>")
    end
  end
  return labels
end

function _summarize_projection_labels(labels::Vector{String}; max_items::Integer=4)
  shown = labels[1:min(length(labels), max_items)]
  summary = join(shown, ", ")
  if length(labels) > max_items
    summary *= ", ..."
  end
  return summary
end

function _validate_membership_subquery(v::SQLTypeOper)
  v.values isa SQLObjectHandler || return nothing
  v.operator in ["IN", "NOT IN"] || return nothing

  subquery = v.values
  projection_labels = _subquery_projection_labels(subquery)
  projection_count = length(projection_labels)
  projection_count == 1 && return nothing

  filter_field = v.column isa SQLTypeField && v.column.field isa String ? v.column.field : "field"
  operator_suffix = v.operator == "IN" ? "in" : "nin"
  lookup = string(filter_field, "__@", operator_suffix)
  detail = if isempty(subquery.object.values)
    "The subquery currently selects all columns from '$(subquery.object.model.name)' because .values(...) was not called."
  else
    "The subquery currently selects $(projection_count) columns: $(_summarize_projection_labels(projection_labels))."
  end

  throw(FilterError(
    "PormG: '$lookup' requires a subquery that returns exactly one column. " *
    detail * " Fix: call .values(\"field_name\") on the subquery so it projects only the key used by the filter."
  ))
end

# #863 — a filter NODE handed over directly (`filter((F("id") + Coalesce("ts__@year", 0)) > 5)`,
# `OP(Max("ts__@date"), …)`) is walked like a pair's right-hand side. A `Q`/`Qor` container is not
# re-entered: its pairs were resolved when it was built, and a container can hold itself
# (`push!(q, q)`, pinned by test_cte_reference.jl). `Exists` resolves its own inner query.
_check_filter_node(v::SQLTypeOper) = _check_function(v)
function _check_filter_node(v::FExpression)
  _guard_boolean_condition(v)   # #931
  return _check_function(v)
end
_check_filter_node(v) = v

# #931 — an expression used as a CONDITION must be boolean. A top-level arithmetic or bitwise node
# (`F("lap") + 1`, `~F("flag")`, `F("a") & 4`) rendered as written: PostgreSQL rejects it ("argument of
# WHERE/CASE must be type boolean"), SQLite reads the number for truthiness and returns rows. Refused
# here, at construction, because every condition position funnels through `_check_filter_node` —
# `filter`, `Q`/`Qor` and their `push!`, `When(expr)` (via `Q`), `on`/`cjoin`/`cjoin_on` — while a
# projection or a right-hand side never does. A bare handle (`operation === nothing`) is left alone: it
# is how a `BooleanField` is tested (`filter(F("flag"))`), and no column type is known at this point.
function _guard_boolean_condition(v::FExpression)
  op = v.operation
  (op === nothing || op in _COMPARISON_OPERATIONS) && return nothing
  throw(_non_boolean_condition(op))
end
function _non_boolean_condition(op::String)
  written, fix = if op in _ARITHMETIC_OPERATIONS
    "an arithmetic expression (`$(op)`)", "compare it, e.g. \e[4m\e[32m(F(\"lap\") + 1) > 0\e[0m"
  elseif op == "~"
    "a bitwise NOT (`~`)", "compare the column instead, e.g. \e[4m\e[32mF(\"flag\") == false\e[0m"
  else
    "a bitwise expression (`$(op)`)",
    "combine conditions with \e[4m\e[32mQ(…)\e[0m / \e[4m\e[32mQor(…)\e[0m, or compare the bitwise value, " *
    "e.g. \e[4m\e[32m(F(\"points\") & 4) > 0\e[0m"
  end
  return _condition_not_boolean(written, "a number", fix, 931)
end
# The sentence #931 and #942 share: what was written, why the engines disagree, and how to fix it.
_condition_not_boolean(written::String, value::String, fix::String, issue::Int) = QueryBuildError(  # refusal-value-ok: `value` here is explanatory text, not a bound value
  "\e[4m\e[31m$(written) used as a condition\e[0m — a condition must be boolean. PostgreSQL rejects " *
  "$(value) there and SQLite reads it for truthiness, so the two engines disagree; $(fix) (#$(issue)).")

# #942 — a FUNCTION used as a `When` condition. `When(Lower("chassis"))` rendered
# `CASE WHEN LOWER(…) THEN …`: PostgreSQL rejects it, SQLite coerces the text to a number and reads it
# for truthiness, so the query silently took the default on every row. `When` is the only condition
# position that admits a bare function — `filter`/`Q`/`on` refuse one by type (`FilterType`) — but
# #931's node-type rule cannot decide it, because a function CAN be boolean (`Cast(x, "boolean")`,
# `output_field = "boolean"`, `Coalesce` over a `BooleanField`). The result type decides instead:
#
# - `:boolean` / `:non_boolean` when the node alone names its type — a declared `Cast` type or
#   `output_field`, a formatter the constructor set, or a name whose result type is fixed;
# - `:unknown` when only the operands can say (`Coalesce`, `Max`, `Lag`, an untyped `Case`). `When`
#   builds those, and `_render_function_body` asks `_expression_formatter` once the columns resolve.
#
# Only a type that is KNOWN to be non-boolean is refused, as `_expression_formatter` only answers a
# known type: an expression whose type cannot be named builds, unchecked, as it did before.
const _NUMBER_RESULT_FUNCTIONS = ("SUM", "AVG", "RANK", "DENSE_RANK", "ROW_NUMBER")
function _function_condition_kind(v::SQLTypeFunction)
  name = v.function_name
  # A declared type names the result outright, including one `_sql_type_field` has no field for
  # (`jsonb`, `timestamp`, an array): only `boolean` itself is a condition.
  declared = get(v.kwargs, name == "CAST" ? "type" : "output_field", nothing)
  if declared isa AbstractString
    base = Base.endswith(strip(declared), "]") ? "" : lowercase(strip(first(split(declared, '('))))
    return base in ("boolean", "bool") ? :boolean : :non_boolean
  end
  v.formatter === nothing || return v.formatter === Models.format_bool_sql ? :boolean : :non_boolean
  # A `WHEN` branch is not a value at all; the rest have one fixed result type.
  (name == "WHEN" || name in _NUMBER_RESULT_FUNCTIONS || name in _TEXT_OUTPUT_FUNCTIONS ||
    haskey(PormGTypeField, name)) && return :non_boolean
  return :unknown
end
function _boolean_sum_refusal(v::SQLTypeFunction)
  written = v.function_name == "SUM" ? "Sum" : "Avg"
  # The caller's own column when the operand is one; a placeholder for anything else.
  op = v.column isa FExpression && v.column.operation === nothing ? v.column.field_name : v.column
  path = op isa SQLField ? op.field : op
  path = path isa AbstractString ? path : "is_active"
  return QueryBuildError(
    "`$(written)` over a boolean is not supported: PostgreSQL has no $(lowercase(v.function_name))(boolean), " *
    "and SQLite would silently compute it over the stored 0/1. Turn the flag into a number explicitly, e.g. " *
    "\e[4m\e[32m$(written)(When(\"$(path)\" => true, then = 1, otherwise = 0))\e[0m" *
    (written == "Avg" ? " for the share of true rows." : " to count the true rows."))
end
function _non_boolean_function_condition(v::SQLTypeFunction)
  _condition_not_boolean("`$(v.function_name)(…)`", "a non-boolean value",
    "compare it, e.g. \e[4m\e[32mWhen(Lower(\"surname\") == \"senna\")\e[0m — a function whose result is " *
    "boolean (\e[4m\e[32mCast(…, \"boolean\")\e[0m, \e[4m\e[32moutput_field = \"boolean\"\e[0m) is accepted", 942)
end

function _check_filter(x::Pair)
  # #444: a CTE-scoped LHS. Delegate on `ref.path` so the whole String pipeline runs — the `__@`
  # peel, `_check_function`'s transform construction, and whichever of the fifteen RHS-typed
  # `_get_pair_to_oper` methods matches (with its `in`/`range`/`jcontains`/arity validation intact) —
  # then retag the column it produced. Reusing the ladder is the point: a hand-written CTE branch
  # would have to re-derive every one of those checks and would drift from them.
  if isa(x.first, CTEReference)
    ref = _reject_cte_desc(x.first, "filter(...)")
    oper = _check_filter(ref.path => x.second)
    isa(oper, SQLTypeOper) && isa(oper.column, SQLField) && _retag_cte_field!(oper.column, ref.name)
    return oper
  end
  # #481: the joined-copy twin, for exactly the reason above. Delegating on `ref.path` is also what
  # makes an ALIAS-QUALIFIED OPERATOR PAIR work — `filter(Joined("d","points__@gte") => 3)` — which
  # the removed `F("d.points")` spelling could never express: the `__@` peel and the RHS-typed
  # `_get_pair_to_oper` ladder run on the path, and only the column it produced is retagged.
  if isa(x.first, JoinedReference)
    ref = _reject_joined_desc(x.first, "filter(...)")
    oper = _check_filter(ref.path => x.second)
    isa(oper, SQLTypeOper) && isa(oper.column, SQLField) && _retag_joined_field!(oper.column, ref.alias)
    return oper
  end
  if isa(x.first, AbstractString)
    key = String(x.first)
    check = String.(split(key, "__@"))
    normalized_value = _normalize_filter_pair(x.second)
    try
      # @pormg_debug
      return _get_pair_to_oper(check => normalized_value)
    catch e
      @pormg_debug false
      @error "Error in filter processing '$(key)'" exception = (e, catch_backtrace())
      rethrow(e)
    end
  else
    throw(FilterError("Error in filter: '$(x.first) => ...' must use a String key, got $(typeof(x.first))"))
  end
end

# The next free generated alias (`<base>_<n>`) for a join row.
#
# #480 — it steps around every alias the caller DECLARED, not only the ones already materialized.
# `cjoin_on` rows are built in `build()`'s ALIAS materialization loop, after `values()` /
# `filter()` / `order_by()` have already resolved their joins, and `_build_cjoin_on_row_join`
# writes the user's alias straight into `alias_b`. So when this function chose `R1_1` for a CTE or
# ForeignKey join, no `cjoin_on(alias = "R1_1")` was in `row_join` yet to be avoided, and the
# statement ended up with two range variables of one name — invalid on both engines, and where an
# engine did resolve it, the projection and the ON clause named different relations. The declared
# aliases all sit in `object.alias_join` before `build()` starts, which is early enough.
function _get_alias_name(instruct::SQLInstruction)::String
  return _get_alias_name(instruct.row_join, instruct.alias, _declared_join_aliases(instruct.object))
end
function _get_alias_name(row_join::Vector{JoinRow}, alias::String,
                         reserved::Vector{String}=String[])::String
  taken = vcat([r.alias_a for r in row_join], [r.alias_b for r in row_join], reserved)
  count = 1
  while true
    alias_name = alias * string("_", count)
    in(alias_name, taken) || return alias_name
    count += 1
  end
end

# #480 — every `cjoin_on` alias declared on the query, materialized or not. Since #484 that is
# exactly `alias_join`'s key set: `cjoin` and `on()` entries live in `custom_join`, keyed by PATH
# rather than by an alias they introduce, and their joins get generated aliases like any ForeignKey
# hop.
_declared_join_aliases(object::SQLObject)::Vector{String} = collect(keys(object.alias_join))

# `track_path = false` (#474) records the join WITHOUT claiming its name in `row_path`. A CTE hop
# uses it: `row_path` exists so `build()`'s PATH materialization loop can skip a `custom_join` entry
# that traversal already built, and a CTE has no `custom_join` entry — so a CTE hop registering its
# own name there could only ever suppress an unrelated user join that happened to share it. A
# `cjoin_on` row uses it for the same reason since #484 — an alias is not a path, so it has no
# business claiming a name in the PATH membership set. Nothing indexes `row_path` positionally (its
# one remaining reader is an `∉` membership test), so the two vectors do not have to stay the same
# length.
function _insert_join(
  row_join::Vector{JoinRow},
  row::JoinRow,
  row_path::Vector{String}, join_path::String; track_path::Bool=true)
  @pormg_debug false
  if size(row_join, 1) == 0
    push!(row_join, row)
    track_path && push!(row_path, join_path)
    return row.alias_b
  else
    # The tuple has no CTE-vs-physical discriminator on purpose (#479): a CTE row and a model row
    # agree on `b` only when a CTE is named after a physical table, and `_with` refuses that at
    # declaration for every table reachable from the registered models. SQL would resolve both
    # joins to the CTE anyway, so keeping such rows apart here could only ever render a second
    # join that reads the wrong relation — a discriminator would not fix the shape, only hide it.
    # #487 kept that when the rows became typed: `_dedup_key` (`types.jl`) is the same
    # `(a, b, key_a, key_b, alias_a)` tuple, with the kind deliberately left out of it.
    key = _dedup_key(row)
    check = filter(r -> _dedup_key(r) == key, row_join)
    if size(check, 1) == 0
      @pormg_debug false
      push!(row_join, row)
      track_path && push!(row_path, join_path)
      return row.alias_b
    else
      if size(check, 1) > 1
        # #197: was `throw("Error in join")` — a raw String with zero context. This branch means
        # the dedup filter matched the same (a, b, key_a, key_b, alias_a) join row more than once,
        # which the dedup invariant forbids.
        error(_emsg("PormG internal error in _insert_join: duplicate deduplicated join rows for $(row.a) → $(row.b) (alias $(row.alias_a)) — please report this."))
      end
      return check[1].alias_b
    end
  end
end

# #619: the names the hint may mention but PormG does not implement, mapped to the nearest spelling
# that does work. This is a MESSAGE table, not a registry — nothing dispatches on it, and membership
# here grants no behavior. It exists so "there is no such lookup" can still be useful for the names
# where a real alternative exists. `test/unit/test_operators.jl` asserts every key is unreachable
# from both registries, so an entry cannot outlive the wiring of its own name.
const UNIMPLEMENTED_LOOKUP_HINTS = Dict{String,String}(
  # Worded as the affirmative it is: `exact` is the ONE name here whose behaviour PormG has, just
  # under no lookup spelling at all. "no spelling of it works — a bare `field => value` already IS
  # an exact match" read as a contradiction, so this entry says what to write instead of what fails.
  "exact"        => "write it as a bare `field => value`, which already IS an exact match",
  "iso_year"     => "the nearest is `__@year`",
  "week"         => "there is no week transform either; `__@month` and `__@yyyy_mm` are the nearest buckets",
  "week_day"     => "there is no weekday transform either",
  "iso_week_day" => "there is no weekday transform either",
)

function _check_if_field_is_a_operator(field::String)
  # The pattern family comes from the shared constant (#604) rather than a literal copy — this list
  # named `istartswith`/`iendswith` while `PormGsuffix` did not, so it told the user to add the `@`
  # and the `@` spelling then raised a FilterError of its own. The rest stays literal on purpose:
  # this is the "you forgot the `@`" hint, not the lookup registry, so it also spans transforms.
  #
  # #619: it also names Django lookups PormG implements nowhere — keys of neither `PormGsuffix`
  # nor `PormGtransform` — and for those it used to instruct a spelling that then failed, which is
  # #604's own two-step dead end surviving 11 more times. The MEMBERSHIP is deliberate and stays:
  # this is a near-miss hint, and a reader who typed `surname__week_day` is better served by being
  # told PormG has no such lookup than by the generic "no such field". Only the WORDING was wrong.
  # (`regex`/`iregex` were two of the 11 until #635 wired them, and `iexact` a third until #634;
  # they now arrive through PATTERN_LOOKUP_OPERATORS, and the reachability check below flips their
  # message by itself. #636 did the same for `hour`/`minute`/`second` through `PormGtransform`.)
  common_operators = [PATTERN_LOOKUP_OPERATORS...,
    "exact", "in", "gt", "gte", "lt", "lte", "range", "nrange", "date", "isnull",
    "year", "iso_year", "quarter", "month", "day", "week", "week_day", "iso_week_day",
    "hour", "minute", "second"]
  field in common_operators || return nothing

  # Reachability is COMPUTED from the registries, never listed a third time. That is the whole
  # defect-prevention: wiring a name into `PormGsuffix` or `PormGtransform` later flips its hint by
  # itself, so the two halves cannot drift the way the #604 list and `PormGsuffix` did. A second
  # hand-maintained list of "implemented" names would be the same bug wearing the fix's clothes.
  if haskey(PormGsuffix, field) || haskey(PormGtransform, field)
    throw(FilterError("The filter operator '\e[31m$field\e[0m' requires '@' prefix. Use '\e[32m$field\e[0m' => ... as part of '__\e[33m@$field\e[0m' syntax. Example: \e[36mq.filter(\"name__@$field\" => value)\e[0m"))
  end

  # No example here, on purpose: an example is a promise, and there is no spelling of this name that
  # builds a query.
  alternative = get(UNIMPLEMENTED_LOOKUP_HINTS, field, "")
  throw(FilterError("PormG has no '\e[31m$field\e[0m' lookup, so no spelling of it works" *
                    (isempty(alternative) ? "." : " — $alternative.")))
end

# #474: `"CROSS"` is NOT in this list, and its absence is the fix rather than an oversight. Every
# consumer of this function feeds a `ModelJoin`/`CteJoin`/`AnchorlessJoin`'s `how`, and Phase 2 of
# `build_row_join_sql_text` emits `"$(value.how) JOIN $b AS $alias ON $on_clause"` for every one of
# those kinds unconditionally — so an accepted `"CROSS"`
# could only ever render `CROSS JOIN … ON …`, which BOTH PostgreSQL and SQLite reject. Measured on
# all three writers before removal: `cjoin_on(join_type="CROSS")`, `on(join_type="CROSS")` and a
# `field.how` of `"CROSS"` each produced that statement. It was never documented either
# (`docs/src/api.md` has always listed only the four below).
#
# The one real CROSS JOIN PormG emits is an UNKEYED `.with(...)` that is REFERENCED — that path builds
# a `CrossJoin` in `build_joins.jl`, a kind with no join type at all, and Phase 2 short-circuits on it
# ahead of the `ON` render; it never comes through here. That is also the only supported spelling for a deliberate cross product, so the
# message points at it (and at the reference, not just the declaration: since #444 a `.with(...)`
# alone emits no join at all).
function _normalize_join_type(join_type::String)
  valid_joins = ["INNER", "LEFT", "RIGHT", "FULL"]
  normalized = uppercase(strip(join_type))
  if !(normalized in valid_joins)
    cross_hint = normalized == "CROSS" ?
      ("\n  A \e[4m\e[32mCROSS JOIN\e[0m cannot carry the \e[4m\e[32mON\e[0m clause this join " *
       "renders. For a deliberate cross product, declare the table as an UNKEYED " *
       "\e[4m\e[32m.with(\"n\" => sub)\e[0m and REFERENCE it — e.g. " *
       "\e[4m\e[32mvalues(\"x\" => CTE(\"n\", \"col\"))\e[0m — which emits a real CROSS JOIN and " *
       "warns that it is Cartesian (#44, #474).") : ""
    throw(QueryBuildError(
      "Invalid join type \e[4m\e[31m$(join_type)\e[0m. Valid types: " *
      "\e[4m\e[32m$(join(valid_joins, ", "))\e[0m.$(cross_hint)"))
  end
  return normalized
end

# The three readers below resolve a MODEL JOIN PATH, so they read the path namespace and only that
# (#484). A `cjoin_on` alias is unreachable from here by construction — it is not in this map — which
# is what makes the alias-equals-ForeignKey-name collision unrepresentable rather than guarded: this
# is the site that used to hand a ForeignKey hop the alias's ON clause and join type.
_get_join_config(q::SQLObject, join_path::String)::Union{PathJoin,Nothing} = get(q.custom_join, join_path, nothing)

function _get_join_field(q::SQLObject, join_path::String)
  config = _get_join_config(q, join_path)
  config === nothing && return nothing
  return config.field
end

# The one place an unknown field name becomes a typed error (#446).
#
# #612: this block sits ABOVE the docstring. Between it and `function`, it detached the docstring
# silently — `@doc` binds to the next expression and a comment is not one.
#
# Returns the exception; the call site throws it — the convention `test_docs_error_type_drift.jl`
# pins for `_unsupported_conn` / `_write_not_allowed` / `_fielderr`. A helper that threw internally
# would invite the mirror-image mistake at a returning one, where a forgotten `throw(` silently
# constructs an exception and lets execution continue past the guard.
#
# The choices are SORTED, and that is not cosmetic: `field_names` is declaration order, so on a wide
# model the name a user typo'd sits at an unpredictable offset in a 40-item line. Django sorts the
# same list in `names_to_path` for the same reason. Reverse accessors are listed too — they are
# addressable at exactly the same position in a path, so omitting them makes a legal name look
# unavailable.
#
# `include_accessors = false` is for the WRITE path (#462). A reverse accessor is addressable in a
# filter/values path but is not a column, so `create("results" => …)` can never work — listing them
# in a write error would advertise a capability that does not exist. Every read-path caller keeps
# the default.
function _unknown_field(model::PormGModel, name::AbstractString;
                       aliases::Vector{String} = String[],
                       include_accessors::Bool = true,
                       hint::String = "")::UnknownFieldError
  choices = sort(collect(model.field_names))
  accessors = include_accessors ? sort(collect(keys(model.related_objects))) : String[]
  tail = isempty(accessors) ? "" :
    "; and the reverse accessors: \e[4m\e[32m$(join(accessors, ", "))\e[0m"
  # A projection alias is addressable in exactly the same position as a field — `filter("tot__@gt")`
  # over a `Sum(...)` alias is the documented way to write HAVING — so a message that omitted them
  # would call a legal name unavailable. Django lists `annotation_select` alongside the fields for
  # the same reason.
  tail *= isempty(aliases) ? "" :
    "; and the declared aliases: \e[4m\e[32m$(join(sort(aliases), ", "))\e[0m"
  # #481 — a dotted name is almost always the removed `F("alias.col")` spelling rather than a column
  # anyone believes exists. Without this the reader is sent looking for a field named `d.surname`,
  # which is exactly the misdirection the fail-open resolver used to produce. It is a HINT on the
  # message, not a resolver: the name still does not exist and the error is still the same type.
  # Shaped like an alias reference — exactly one dot, with an identifier on each side. A looser
  # `occursin('.', name)` also fired on `"1.5"`, `"a.b.c"`, `".note"` and `"note."`, none of which
  # anyone wrote meaning a joined copy. A schema-qualified `"public.result"` still matches, and
  # that is accepted: it is indistinguishable from an alias reference by shape alone, and the hint
  # is additive text on an error the name earns either way.
  looks_like_alias_ref = occursin(r"^[\p{L}_][\p{L}\p{M}\p{N}_]*\.[\p{L}_][\p{L}\p{M}\p{N}_]*$", name)
  tail *= looks_like_alias_ref ?
    "\n  If you meant a \e[4m\e[32mcjoin_on\e[0m joined copy: \e[4m\e[31mF(\"alias.column\")\e[0m " *
    "was removed in #481 — write \e[4m\e[32mJoined(\"alias\", \"column\")\e[0m instead." : ""
  tail *= hint
  return UnknownFieldError(
    "the column \e[4m\e[31m$(name)\e[0m not found in \e[4m\e[32m$(Models.model_table_name(model))\e[0m, " *
    "that contains the fields: \e[4m\e[32m$(join(choices, ", "))\e[0m$(tail)")
end

# #566 — a subquery reaching for a CTE its ENCLOSING query declares. Correct to refuse: each query
# has its own CTE namespace (#444), so the inner build genuinely has no such CTE. But the bare
# refusal reads "declared CTEs: none" (or "column not found") while the caller can see the `.with()`
# two lines up, which looks like PormG lost the CTE rather than like a scoping rule. This names the
# rule. The whole `outer` chain is walked, not one level: a filter `Exists` nested in another filter
# `Exists` is legal, so the declaring query can be further up. Returns "" when no enclosing query
# declares `name`. It only ever changes a message, never which error is raised.
function _outer_cte_hint(instruct::SQLInstruction, name::AbstractString)::String
  outer = instruct.outer
  while outer !== nothing
    haskey(outer.object.ctes, name) && return (
      "\n  \e[4m\e[31m$(name)\e[0m is declared on an ENCLOSING query, and a subquery " *
      "(Subquery, Exists, __@in) has its own CTE namespace: it cannot see its parent's " *
      "\e[4m\e[32m.with(...)\e[0m (#444). Put the condition on the CTE in the enclosing query's " *
      "own \e[4m\e[32m.filter(...)\e[0m instead.")
    outer = outer.outer
  end
  return ""
end

"""
This function checks if the given `field` is a valid field in the provided `model`. If the field is valid, it returns the field name, potentially modified based on certain conditions.
"""
function _solve_field(field::String, model::PormGModel, instruct::SQLInstruction)
  # check if last_column a field from the model    
  if !(field in model.field_names)
    _check_if_field_is_a_operator(field)
    @pormg_debug false
    throw(_unknown_field(model, field))
  end
  # (instruct.django !== nothing && hasfield(model.fields[field] |> typeof, :to)) && (field = string(field, "_id"))

  # Resolve to the physical column (db_column when set, else the field name) and quote
  # it to prevent SQL injection (#50). SELECT auto-aliases back to the field name, so
  # rows stay keyed by the declared field name even when the column differs.
  return safe_column_identifier(Models.field_db_column(model.fields[field], field), instruct.connection)
end
_solve_field(field::String, _module::Module, model_name::Symbol, instruct::SQLInstruction) = _solve_field(field, getfield(_module, model_name), instruct)
_solve_field(field::String, _module::Module, model_name::String, instruct::SQLInstruction) = _solve_field(field, _module, Symbol(model_name), instruct)
_solve_field(field::String, _module::Module, model_name::PormGModel, instruct::SQLInstruction) = _solve_field(field, model_name, instruct)


# `_df_to_dic` used to live here — deleted in #197: it had zero callers and referenced an
# undefined variable (`filtro`), so it was both dead and broken.

# ---
# Build the SQLInstruction object
#

# select
function _infer_parameter_sql_type(value, instruc::SQLInstruction; fallback::Union{Nothing,String}=nothing)
  instruc.connection isa PormGPostgres || return nothing
  fallback !== nothing && return fallback
  value isa AbstractString && return "text"
  value isa Bool && return "boolean"
  value isa Integer && return "bigint"
  value isa AbstractFloat && return "double precision"
  value isa Dates.Date && return "date"
  value isa Dates.DateTime && return "timestamp"
  value isa Dates.Time && return "time"
  value isa Sockets.IPAddr && return "inet"   # #903 — bound as its text by `add_parameter!`
  return nothing
end

function _deferred_kwarg_sql_type(v::SQLTypeFunction, key::String, resolved_kwargs::Dict{String,Any}, instruc::SQLInstruction)
  value = v.kwargs[key]

  if key == "precision"
    return _infer_parameter_sql_type(value, instruc; fallback="integer")
  end

  output_field = get(resolved_kwargs, "output_field", nothing)
  if output_field isa AbstractString && !isempty(output_field)
    # #696: `output_field` becomes the bind cast `$n::<type>` here — a fourth place the type string
    # reaches the SQL text. The dialect helper validates it and gives the engine's spelling.
    instruc.connection isa PormGPostgres || return nothing
    return _infer_parameter_sql_type(value, instruc;
      fallback=Dialect.cast_type_sql(output_field, instruc.connection; context="output_field"))
  end

  return _infer_parameter_sql_type(value, instruc)
end

function _get_select_query(v::SQLText, instruc::SQLInstruction; _as::Union{Nothing,String}=nothing)
  # Parameterize Value(x) instead of rendering as raw SQL literal.
  # NULL must stay literal (can't parameterize NULL in SQL).
  if v.field === nothing
    return "NULL"
  end
  return add_parameter!(instruc, v.field; sql_type=_infer_parameter_sql_type(v.field, instruc))
end
function _get_select_query(v::Vector{T}, instruc::SQLInstruction; _as::Union{Nothing,String}=nothing) where T
  resp = []
  for item in v
    push!(resp, _get_select_query(item, instruc, _as=_as))
  end
  return resp
end
function _get_select_query(v::String, instruc::SQLInstruction; _as::Union{Nothing,String}=nothing)
  parts = split(v, "__")
  if size(parts, 1) > 1
    return _build_row_join(parts, instruc)
  else
    # Fast path: allow "*" to select all main-table columns seamlessly.
    # We intercept this before _solve_field to prevent the missing-field validation error.
    if v == "*"
      return string(quote_identifier(instruc.alias, instruc.connection), ".*")
    end
    
    # #474: `v` is a column of the BASE model here, so the base-model half of the namespace.
    if _as !== nothing && memo_field(instruc, memo_key(:base, _as)) !== nothing && haskey(instruc.object.model.fields, v)
      # The fields haskey guard matters: an invalid `v` must fall through to _solve_field's
      # UnknownFieldError below, not die here with a raw KeyError (audit finding).
      memo_field!(instruc, memo_key(:base, _as), instruc.object.model.fields[v])
    end
    return _column_sql(instruc, instruc.alias, _solve_field(v, instruc.object.model, instruc))   # #985
  end
end
function _get_select_query(v::SQLField, instruc::SQLInstruction; _as::Union{Nothing,String}=nothing)
  return _get_select_query(v.field, instruc, _as=_as)
  # return v.field
end
function _get_select_query(v::SQLTypeOper, instruc::SQLInstruction; _as::Union{Nothing,String}=nothing)
  # use logic to when funtion
  return _get_filter_query(v, instruc)
end
function _resolve_window_expression(v, instruc::SQLInstruction)
  if v isa Symbol
    return _resolve_window_expression(String(v), instruc)
  elseif v isa AbstractString && !(v isa String)
    # #603: normalize and recurse, exactly as the `Symbol` arm above does. Without this a
    # `SubString` fell past every branch into the `else` and was told its TYPE was unsupported,
    # when a window expression by column name is precisely what it was.
    #
    # `!(v isa String)` is load-bearing, not redundant with the ordering below: `String(s::String)`
    # returns the SAME object, so a `String` reaching this branch would recurse into it forever.
    return _resolve_window_expression(String(v), instruc)
  elseif v isa String
    isempty(v) && throw(QueryBuildError("Window expression fields cannot be empty"))
    return _get_select_query(_check_function(v), instruc)
  elseif v isa SQLType
    return _get_select_query(v, instruc)
  else
    throw(QueryBuildError("Unsupported window expression $(repr(v)) of type $(typeof(v))"))  # refusal-value-ok: an expression object the query was built from
  end
end

# Delegates to the shared whitelist (types.jl, #77) so the ORDER BY and window paths can't drift.
_normalize_window_orientation(orientation::AbstractString)::String =
  _normalize_order_orientation(orientation; context="Window ORDER BY")

# Each `_resolve_window_order` method answers `(expression, term)`: the term is what OVER prints, and
# the bare expression — no direction, no NULLS placement — is what `_build_over_clause` records for
# GROUP BY (#789), where a direction is a syntax error.
function _resolve_window_order(v::String, instruc::SQLInstruction)::Tuple{String,String}
  isempty(v) && throw(QueryBuildError("Window ORDER BY fields cannot be empty"))
  orientation = startswith(v, "-") ? "DESC" : "ASC"
  field = startswith(v, "-") ? v[2:end] : v
  isempty(field) && throw(QueryBuildError("Window ORDER BY fields cannot be empty"))
  expr = string(_resolve_window_expression(field, instruc))
  return (expr, string(expr, " ", orientation))
end

# #509 — an EXPLICIT `nulls` placement is honoured here; before this the window path read
# `v.orientation` and dropped `v.nulls` on the floor, for every `SQLOrder` entry and not merely a
# CTE-carrying one. A keyword the constructor accepts, validates and stores, silently ignored at
# render, is the same silent-wrong-answer shape #509 is about — found while making a CTE column
# reachable from this wrapper, fixed here for every entry rather than for the new case only.
#
# An UNSET `nulls` still renders exactly as before — bare `expr ORIENTATION`, no NULLS clause — so
# every existing window's SQL is byte-for-byte unchanged. The top-level ORDER BY applies a
# backend-aligned DEFAULT placement (`_nulls_placement`'s ASC → :last, DESC → :first) and a window
# deliberately does not: adding one would rewrite SQL nobody asked to change, and the two clauses
# are not obliged to agree on a default they never agreed on.
#
# `_order_term_sql` is the same renderer the top-level clause uses, so the SQLite < 3.30 emulation
# (`(expr IS NULL) DESC, expr ASC`, legal inside `OVER (...)` too) and its placeholder guard come
# along for free instead of being restated.
function _resolve_window_order(v::SQLTypeOrder, instruc::SQLInstruction)::Tuple{String,String}
  expr = string(_resolve_window_expression(v.field, instruc))
  orientation = _normalize_window_orientation(v.orientation)
  v.nulls === nothing && return (expr, string(expr, " ", orientation))
  return (expr, _order_term_sql(expr, orientation, _nulls_placement(orientation, v.nulls), instruc.connection))
end
# #444 — a window's ORDER BY is the SECOND place where `desc = true` is meaningful (the fluent
# `order_by(...)` is the first), so it consumes the flag here instead of letting `_cte_join_path`
# refuse it. Rendering goes through the same `_get_select_query` every other CTE reference uses,
# which is what keeps the emitted OVER (...) clause identical to the pre-#444 `"-<cte>__col"` string.
function _resolve_window_order(v::CTEReference, instruc::SQLInstruction)::Tuple{String,String}
  orientation = v.desc ? "DESC" : "ASC"
  expr = string(_get_select_query(CTEReference(name=v.name, path=v.path), instruc))
  return (expr, string(expr, " ", orientation))
end
# #481 — the joined-copy twin: consume `desc` here, then render through the same resolver.
function _resolve_window_order(v::JoinedReference, instruc::SQLInstruction)::Tuple{String,String}
  orientation = v.desc ? "DESC" : "ASC"
  expr = string(_get_select_query(JoinedReference(v.alias, v.path, false), instruc))
  return (expr, string(expr, " ", orientation))
end

function _build_over_clause(over::WindowSpec, instruc::SQLInstruction)::String
  parts = String[]

  # #789: each term is also recorded, with the values it bound, for `_group_window_terms!` — an
  # aggregating statement must group every column a window reads, and the OVER clause is the one
  # place that reads a column without projecting it. Recorded here, where the term renders, so the
  # GROUP BY copy reuses this render's SQL and values rather than resolving the path a second time.
  # A term that holds an aggregate is not recorded: it is computed per group, never grouped by
  # (Django's `Aggregate.get_group_by_cols` is empty for the same reason). Asked of the RESOLVED
  # term (`_resolved_contains_agg`), because a condition reading an aggregate alias renders the
  # aggregate while its own node carries only the name (#722).
  # A MIXED term — `F("raceid") + Sum("points")` — is left out whole too, and the bare `raceid` in it
  # is NOT grouped for the user: `_check_mixed_grouping` (#798, build_query.jl) refuses it unless the
  # statement already groups that column.
  if !isempty(over.partition_by)
    partition_sql = String[]
    for field in over.partition_by
      mark = parameter_mark(instruc)
      expr = string(_resolve_window_expression(field, instruc))
      _resolved_contains_agg(field, instruc) || push!(instruc.window_group_terms, (expr, bound_since(mark)))
      push!(partition_sql, expr)
    end
    push!(parts, "PARTITION BY " * join(partition_sql, ", "))
  end

  if !isempty(over.order_by)
    order_sql = String[]
    for order_field in over.order_by
      mark = parameter_mark(instruc)
      expr, term = _resolve_window_order(order_field, instruc)
      order_node = order_field isa SQLTypeOrder ? order_field.field : order_field
      _resolved_contains_agg(order_node, instruc) || push!(instruc.window_group_terms, (expr, bound_since(mark)))
      push!(order_sql, term)
    end
    push!(parts, "ORDER BY " * join(order_sql, ", "))
  end

  if over.frame !== nothing
    # #713: parsed again at the sink — `WindowOver` already did, but a `WindowSpec` built or mutated
    # directly never passed through it. Parsed BEFORE the SQLite refusal, so that message echoes
    # PormG's rebuilt spelling rather than the caller's text.
    frame = Dialect.window_frame_sql(over.frame)
    instruc.connection isa PormGSQLite && throw(BackendCapabilityError("SQLite window functions in PormG do not support explicit frame specifications yet. Remove frame=$(repr(frame)) or use PostgreSQL."))
    push!(parts, frame)
  end

  return join(parts, " ")
end

# #808: the literal-NULL spellings a value slot (CASE `then`/`else`, `Lag`/`Lead` `default`) accepts.
# Type-checked before any `==`: that slot also takes a column expression, and `==` on an
# `FExpression` or `JoinedReference` builds a predicate node, not a `Bool` (#541) — `val == "NULL"`
# on `then = F("points")` raised `TypeError: non-boolean (FExpression)` before any SQL existed.
_is_null_literal(x) = x isa Missing || x === nothing || (x isa AbstractString && x == "NULL")

function _resolve_window_kwarg(value, instruc::SQLInstruction; sql_type::Union{Nothing,String}=nothing)
  if _is_null_literal(value)
    return "NULL"
  elseif value isa SQLType
    return _get_select_query(value, instruc)
  else
    return add_parameter!(instruc, value; sql_type=sql_type === nothing ? _infer_parameter_sql_type(value, instruc) : sql_type)
  end
end

# The OVER clause renders LAST, after the column and the keyword arguments: that is where it prints
# (`LAG(col, ?, ?) OVER (…)`), and a positional backend binds in render order. Rendering it first
# filed a binding OVER term's values (a `date__@yyyy_q` partition binds nine) ahead of the
# function's own: `Lag`/`Lead`'s offset, which every one binds, and any binding column
# (`FirstValue(F("points") * 3)`). SQLite shifted each value by one position and read the label's
# `"-Q"` as the offset. Found beside #789, whose GROUP BY copy of that term exposed it.
# A no-op on PostgreSQL apart from the `$N` numbering, which travels with the text.
function _get_select_query(v::WindowFunction, instruc::SQLInstruction; _as::Union{Nothing,String}=nothing)
  func_name = Symbol(v.function_name)

  if v.column === nothing
    v.function_name in ["LAG", "LEAD", "FIRST_VALUE", "LAST_VALUE", "NTH_VALUE"] &&
      throw(QueryBuildError("$(v.function_name) requires a column argument; got nothing"))
    return getfield(Dialect, func_name)(_build_over_clause(v.over, instruc), instruc.connection)
  end

  # #887: a subquery column renders with the projection's alias, so a #194 refusal of its correlation
  # names the column the caller wrote, as it does for `Coalesce(Subquery(…), …)`. Only here, not in
  # `_resolve_window_expression`: that also renders PARTITION BY and ORDER BY terms, and its path arm
  # memoizes under whatever `_as` it is handed.
  resolved_column = v.column isa SubqueryObject ? _get_select_query(v.column, instruc; _as = _as) :
                                                  _resolve_window_expression(v.column, instruc)

  if v.function_name in ["LAG", "LEAD"]
    resolved_kwargs = Dict{String,Any}()
    if haskey(v.kwargs, "offset")
      resolved_kwargs["offset"] = _resolve_window_kwarg(v.kwargs["offset"], instruc; sql_type="integer")
    end
    if haskey(v.kwargs, "default")
      resolved_kwargs["default"] = _resolve_window_kwarg(v.kwargs["default"], instruc)
    end
    over_sql = _build_over_clause(v.over, instruc)
    return getfield(Dialect, func_name)(resolved_column, over_sql, resolved_kwargs, instruc.connection)
  elseif v.function_name == "NTH_VALUE"
    n = get(v.kwargs, "n", nothing)
    n isa Integer || throw(QueryBuildError("NthValue requires a positive integer n"))
    n <= 0 && throw(QueryBuildError("NthValue n must be a positive integer"))
    return getfield(Dialect, func_name)(resolved_column, n, _build_over_clause(v.over, instruc), instruc.connection)
  else
    return getfield(Dialect, func_name)(resolved_column, _build_over_clause(v.over, instruc), instruc.connection)
  end
end
# #74: extract the single source table alias from a fully-resolved bare column reference like
# `"Tb_1"."points"` or `"Tb".*`. Returns the unquoted alias, or `nothing` for anything that is not a
# single column (nested aggregate, F-expression, multi-column) — the fan-out guard treats `nothing`
# as ambiguous and conservatively refuses. Both backends quote identifiers with double quotes.
function _extract_leading_alias(s)
  s isa AbstractString || return nothing
  m = match(r"^\"((?:[^\"]|\"\")+)\"\.(?:\"(?:[^\"]|\"\")+\"|\*)$", s)
  m === nothing ? nothing : replace(m.captures[1], "\"\"" => "\"")
end

# #844 — `Greatest`/`Least` skip a NULL argument on both engines, as PostgreSQL's GREATEST/LEAST do.
# SQLite has neither: `Dialect` renders its scalar `MAX(a, b)` / `MIN(a, b)`, which return NULL when
# ANY argument is NULL, so the same query answered differently per engine and said nothing.
#
# The fix rewrites the OPERANDS, one COALESCE per rotation of the list:
#   GREATEST(a, b, c)  →  MAX(COALESCE(a, b, c), COALESCE(b, c, a), COALESCE(c, a, b))
# Each rotation yields some non-NULL operand, and every non-NULL operand leads one rotation, so the
# MAX over them is the largest non-NULL value; all NULL still gives NULL, as on PostgreSQL.
#
# It lives here and not in `Dialect.GREATEST`, because the dialect receives operands already
# RENDERED, with their `?` placeholders in them. Repeating a rendered string would repeat a `?`
# whose value was bound once, misbinding every parameter after it. Repeating the NODES instead makes
# each rotation render — and bind — its own operands, in text order. Constructs, never mutates (#508).
# Fewer than two operands are left alone: the constructors refuse them since #859 (SQLite's `max(x)`
# with one argument is the AGGREGATE, and its `coalesce` needs two), so only a hand-built node gets
# here with one, and the guard keeps it from a `coalesce` SQLite would reject.
function _null_skipping_operands(v::SQLTypeFunction, instruc::SQLInstruction)
  (instruc.connection isa PormGSQLite && v.function_name in ("GREATEST", "LEAST") &&
   v.column isa AbstractVector && length(v.column) >= 2) || return v.column
  cols = collect(Any, v.column)
  return Any[FObject(function_name = "COALESCE", column = circshift(cols, 1 - k),
                     aggregate = _any_agg(cols)) for k in 1:length(cols)]
end

# #964: a `When` with no `otherwise` is a `CASE` branch: `WHEN … THEN …`, no `ELSE`, no `END`. Only
# `Case` renders one as such (`_render_case_branches`), so a `When` that reaches the typed renderer
# stands as a value (a projection, an aggregate's operand, a function argument), where it printed
# `COUNT(WHEN … THEN …)` and the driver refused it on both engines. Refused at build instead, naming
# the two complete spellings rather than supplying an `ELSE NULL` the caller never wrote.
function _bare_when_refusal()
  return QueryBuildError(
    "A \e[4m\e[31mWhen\e[0m with no `otherwise` is a branch of a Case, not a value: alone it renders " *
    "`WHEN … THEN …` with no ELSE and no END, which no engine parses. Give it its own ELSE, " *
    "\e[4m\e[32mWhen(…, then = x, otherwise = y)\e[0m, or put it in a Case, " *
    "\e[4m\e[32mCase([When(…, then = x)], default = y)\e[0m (#964).")
end
# A `Case`'s branches, a vector of them or the single node `Case(When(…))` and `When(…; otherwise)`
# hold. A `WHEN` renders through its body, past the #964 refusal in `_render_function_typed`, because
# here it is a branch. Anything else renders as a value, as it did before.
_render_case_branch(b::SQLTypeFunction, instruc::SQLInstruction; _as::Union{Nothing,String}=nothing) =
  b.function_name == "WHEN" ? _render_function_body(b, instruc; _as = _as)[1] : _get_select_query(b, instruc; _as = _as)
_render_case_branch(b, instruc::SQLInstruction; _as::Union{Nothing,String}=nothing) = _get_select_query(b, instruc; _as = _as)
_render_case_branches(col::AbstractVector, instruc::SQLInstruction; _as::Union{Nothing,String}=nothing) =
  Any[_render_case_branch(b, instruc; _as = _as) for b in col]
_render_case_branches(col, instruc::SQLInstruction; _as::Union{Nothing,String}=nothing) =
  _render_case_branch(col, instruc; _as = _as)

function _get_select_query(v::SQLTypeFunction, instruc::SQLInstruction; _as::Union{Nothing,String}=nothing)
  sql, interval_ms, _ = _render_function_typed(v, instruc; _as = _as)
  # #894: an interval held in milliseconds leaves as the interval text, as a difference does (#881).
  return interval_ms ? Dialect._sqlite_interval_text(sql) : sql
end

# The function's SQL, whether it is an interval held in SQLite milliseconds, and whether it is an
# interval at all (#894). Only the functions in `_INTERVAL_MS_AGGREGATES`/`_INTERVAL_MS_VARIADIC` over
# an interval are either. `MAX` over the milliseconds is the longest interval, where `MAX` over the
# stored `HH:MM:SS` text was the last one in text order (`"99:00:00"` over `"100:00:00"`, and
# `"-01:00:00"` over `"02:00:00"`); `SUM` and `AVG` over the text added up its leading hours (#900).
# The third value types the projection on both engines: `_operand_kind` cannot type
# `Max(F("start_at") - F("date"))`, because arithmetic answers `nothing` there, and it types no
# `Sum` at all (a computed value is not the column) — only the render knows. Every other function
# renders exactly as before and answers `false, false`.
#
# #932: a grouping aggregate's argument is evaluated per input row, before GROUP BY, so it renders in
# the `:row` phase — `Sum(Case([When("grid" => Subquery(…), then = 1)], default = 0))` correlates on
# whatever column it likes. This is the one site every aggregate call renders through (projection,
# HAVING and ORDER BY re-renders, `F` arithmetic over an aggregate). A window is a `WindowFunction`,
# never `_is_aggregate_call`, so its arguments keep the clause's phase; the `Sum` inside
# `Lag(Sum(…))` is a real grouping aggregate and takes `:row` for its own argument.
function _render_function_typed(v::SQLTypeFunction, instruc::SQLInstruction;
                                _as::Union{Nothing,String}=nothing)::Tuple{String,Bool,Bool}
  v.function_name == "WHEN" && throw(_bare_when_refusal())
  _is_aggregate_call(v) || return _render_function_body(v, instruc; _as = _as)
  return with_scope(() -> _render_function_body(v, instruc; _as = _as), instruc; phase = :row)
end
function _render_function_body(v::SQLTypeFunction, instruc::SQLInstruction;
                               _as::Union{Nothing,String}=nothing)::Tuple{String,Bool,Bool}
  # Parameterize scalar kwargs instead of rendering them as SQL literals.
  # IMPORTANT: these must be parameterized AFTER the column is resolved, because the SQL text order
  # places condition params first positionally (e.g., WHEN cond THEN ? ... ELSE ? END).
  #
  # Parameterizable kwargs by function:
  #   CASE/WHEN  → "then", "else"      (output values)
  #   ROUND      → "precision"         (decimal places)
  parameterize_keys = if v.function_name in ["CASE", "WHEN"]
    Set(["then", "else"])
  elseif v.function_name == "ROUND"
    Set(["precision"])
  else
    Set{String}()
  end

  # Phase 1: Resolve non-parameterizable kwargs (output_field, distinct, etc.)
  resolved_kwargs = Dict{String,Any}()
  deferred_kwargs = Dict{String,Any}()  # kwargs to parameterize after column
  for (k, val) in v.kwargs
    # For CASE/WHEN, THEN/ELSE must always be resolved after condition SQL so positional
    # placeholders follow SQL text order (important for SQLite/MySQL style backends).
    if k in parameterize_keys
      # #808: stored as the literal, not as `val` — a `missing` reached `Dialect.CASE`/`WHEN`
      # verbatim and rendered `ELSE missing` / `THEN missing`, which no engine parses. `WHEN`'s own
      # `"else" => missing` placeholder takes this branch too; its renderer never reads the slot.
      if _is_null_literal(val)
        resolved_kwargs[k] = "NULL"
      else
        deferred_kwargs[k] = val
      end
    elseif isa(val, Union{SQLObject,SQLType})
      resolved_kwargs[k] = _get_select_query(val, instruc)
    else
      resolved_kwargs[k] = val
    end
  end

  # Phase 2: Resolve column (conditions) — this adds condition params in SQL text order
  #
  # #894/#900: a function in `_INTERVAL_MS_FUNCTIONS` over an interval resolves its operands to
  # milliseconds on SQLite. `_render_interval_operand` renders each operand exactly once, and hands
  # back the SQL below alongside the millisecond form, so the function binds the same values in the
  # same order whichever form it prints, and keeps the SQL it always rendered when it has none.
  #
  # On PostgreSQL the operand of an extremum over arithmetic renders through the typed renderer,
  # which is exactly what `_get_select_query(::FExpression)` renders, so its SQL is unchanged and
  # only its kind is kept.
  interval_ms = interval = false
  fanout_column = nothing   # the operand as the #74 guard reads it: its column, not the parse of it
  if v isa FObject && v.function_name == "ABS" && instruc.connection isa PormGSQLite && !(v.column isa AbstractVector)
    resolved_column, ms, operand_interval = _render_interval_operand(v.column, instruc; _as = _as)
    # #900: PostgreSQL has no `abs(interval)`, so the statement fails there when it runs. SQLite
    # computed the absolute value of the text's leading hours, silently. Refused, as `d * d` is (#881).
    (ms === nothing && !operand_interval) || throw(QueryBuildError(
      "`Abs` of an interval is not supported: PostgreSQL has no abs(interval), and SQLite stores an " *
      "interval as text. For the magnitude of an interval d, write Greatest(d, d * -1)."))
  elseif v isa FObject && _interval_ms_candidate(v)
    sqlite = instruc.connection isa PormGSQLite
    if v.column isa AbstractVector
      operands = _null_skipping_operands(v, instruc)
      forms = [_render_interval_operand(x, instruc; _as = _as) for x in operands]
      # A NULL literal is NULL in either form, and never the value; every other operand must agree.
      valued = [f for (x, f) in zip(operands, forms) if !_is_null_operand(x)]
      if sqlite && !isempty(valued) && all(f -> f[2] !== nothing, valued)
        resolved_column = Any[_is_null_operand(x) ? f[1] : f[2] for (x, f) in zip(operands, forms)]
        interval_ms = interval = true
      else
        resolved_column = Any[f[1] for f in forms]
        interval = !sqlite && !isempty(valued) && all(f -> f[3], valued)
      end
    else
      fanout_column, ms, operand_interval = _render_interval_operand(v.column, instruc; _as = _as)
      if sqlite && ms !== nothing
        resolved_column, interval_ms, interval = ms, true, true
      else
        # An interval with no millisecond form on SQLite is its text, and `SUM` over that is a number:
        # only PostgreSQL's value is typed from the operand here.
        resolved_column, interval = fanout_column, !sqlite && operand_interval
      end
    end
  elseif v.function_name == "CASE"
    resolved_column = _render_case_branches(v.column, instruc; _as = _as)
  else
    resolved_column = _get_select_query(_null_skipping_operands(v, instruc), instruc, _as=_as)
  end
  # #942: the half of the `When` condition check construction could not do. Read after the condition
  # renders, so a joined path's field memo exists for `_expression_formatter` to find.
  if v.function_name == "WHEN" && v.column isa SQLTypeFunction && _function_condition_kind(v.column) === :unknown
    formatter = _expression_formatter(v.column, instruc)
    (formatter === nothing || formatter === Models.format_bool_sql) ||
      throw(_non_boolean_function_condition(v.column))
  end
  # #28: `@len` counts an array's elements, so its operand must be an `ArrayField` — a column, a
  # joined or CTE path, or a slice (`tags__0_2`), whose memo entry is the array field itself. Read
  # after the operand renders, like the check above: rendering a path is what fills the memo. Fails
  # closed — an operand whose type cannot be named (an expression) is refused too.
  v.function_name == "ARRAY_LEN" && !(_expression_formatter(v.column, instruc) isa Models.ArrayFormatter) &&
    throw(FilterError("The \e[31m@len\e[0m transform counts the elements of an ArrayField, and " *
                      "\e[31m$(_len_operand_label(v.column))\e[0m is not one."))
  # #953: an aggregate over a boolean, read once its column resolves (as the check above is).
  # PostgreSQL has none of `max/min/sum/avg(boolean)`, so each failed there when it ran, while SQLite
  # answered over its stored 0/1. An extremum keeps its meaning — any true, all true — so it renders
  # PostgreSQL's own aggregate (`Dialect.MAX`). A sum or mean turns a boolean into a number, which
  # PormG does not do implicitly: refused on both engines, pointing to the explicit count.
  if v.function_name in ("MAX", "MIN", "SUM", "AVG") &&
     _expression_formatter(v.column, instruc) === Models.format_bool_sql
    v.function_name in ("SUM", "AVG") && throw(_boolean_sum_refusal(v))
    resolved_kwargs["boolean"] = true
  end

  # #74 fan-out guard: record COUNT/SUM/AVG and the source alias of their column so build() can
  # refuse aggregates a to-many join would silently inflate. MAX/MIN are immune and omitted; a
  # `distinct=true` aggregate is an explicit opt-in and is exempted by the check.
  if v.function_name in ("COUNT", "SUM", "AVG")
    guard_column = fanout_column === nothing ? resolved_column : fanout_column
    src = _extract_leading_alias(guard_column)
    push!(instruc.agg_sources, (
      alias = src === nothing ? "\0AMBIGUOUS" : src,
      func = v.function_name,
      label = _as === nothing ? string(v.function_name, "(", guard_column, ")") : _as,
      distinct = get(v.kwargs, "distinct", false) === true))
  end

  # Phase 3: Now parameterize deferred kwargs (they appear AFTER conditions in SQL)
  # Order matters for positional backends: then → else → precision
  for key in ["then", "else", "precision"]
    if haskey(deferred_kwargs, key)
      deferred_val = deferred_kwargs[key]
      if isa(deferred_val, Union{SQLObject,SQLType})
        resolved_kwargs[key] = _get_select_query(deferred_val, instruc)
      else
        resolved_kwargs[key] = add_parameter!(instruc, deferred_val; sql_type=_deferred_kwarg_sql_type(v, key, resolved_kwargs, instruc))
      end
    end
  end

  sql = getfield(Dialect, Symbol(v.function_name))(resolved_column, resolved_kwargs, instruc.connection)
  # #900: PostgreSQL's `avg(interval)` is an interval; the milliseconds' mean is rounded to one, the
  # precision every SQLite interval has (#881).
  interval_ms && v.function_name == "AVG" && (sql = "CAST(round($(sql)) AS INTEGER)")
  return sql, interval_ms, interval
end
# The operand `@len` refused, as the caller spelled it (#28).
_len_operand_label(c::AbstractString) = String(c)
_len_operand_label(c::CTEReference) = "CTE(\"$(c.name)\", \"$(c.path)\")"
_len_operand_label(c::JoinedReference) = "Joined(\"$(c.alias)\", \"$(c.path)\")"
_len_operand_label(::Any) = "this expression"
function _get_select_query(q::SQLTypeQor, instruc::SQLInstruction; _as::Union{Nothing,String}=nothing)
  resp = []
  for v in q.or
    push!(resp, _get_select_query(v, instruc, _as=_as))
  end
  return "(" * join(resp, " OR ") * ")"
end

function _get_select_query(q::SQLTypeQ, instruc::SQLInstruction; _as::Union{Nothing,String}=nothing)
  resp = []
  for v in q.filters
    push!(resp, _get_select_query(v, instruc, _as=_as))
  end
  return "(" * join(resp, " AND ") * ")"
end
# #938: a Subquery/Exists nested inside another subquery builds in every position. #92 refused the
# PROJECTED spelling only ("OuterRef resolves one level, so a nested projected subquery could correlate
# to the wrong level"), which left the filter spelling of the same predicate open (#926) and refused
# `Coalesce(Subquery(…))` in a nested WHERE while the bare `Subquery(…)` built. Neither level can
# mis-bind: every nested render passes `outer = instruc`, so `OuterRef` resolves against the
# IMMEDIATELY enclosing query — Django's rule — and the shared `SQLTbAlias` counter gives each level
# its own alias (`Tb`, `R1`, `R2`, …), so an inner `OuterRef` cannot be captured by a deeper scope.
# Correlating two levels up (Django's `OuterRef(OuterRef(…))`) is not expressible; it is not
# mis-resolved either. The guard's other premise, the nested parameter order, is #432's
# `nested_parameter_mark` / `detach_nested_run!` since.

# #433: a `.with(...)` declared INSIDE a Subquery / Exists / `__@in` subquery is refused, because
# no backend renders it correctly today. The three call sites fail in two different ways, and the
# guard is deliberately wider than either break:
#
#   - `Exists(...)` never rendered it AT ALL. `_build_exists_query` hand-rolls its own SELECT rather
#     than going through `query()`, so it emits no `WITH` prefix and never materializes the CTE's
#     model — the first path resolving `<cte>__col` reached the "internal error … please report it"
#     in `build_joins.jl`, for a shape the user was always entitled to write. That message is for a
#     broken invariant; this was a missing render step.
#   - `Subquery(...)` and `"col__@in" => sub` DO render an inline `WITH`, and on PostgreSQL they are
#     correct. On SQLite they can misbind: `build_cte_clause` binds unconditionally into the `:cte`
#     bucket, `:cte` is flattened FIRST (`get_final_parameters`), and the subquery's text sits in
#     SELECT or WHERE. Any value whose TEXT precedes the nested CTE but whose bucket flattens later
#     ends up bound behind it. Measured on this fixture:
#         filter("note" => "A", "parent__@in" => <sub declaring .with("gv" => …)>)
#         PostgreSQL ["A", "CTEVAL", "INNERVAL"]   SQLite ["CTEVAL", "INNERVAL", "A"]
#     — wrong rows, no error. It is conditional, not universal: with no earlier parameter to jump,
#     the same shapes bind correctly, which is why this survived so long.
#
# Refusing on BOTH backends rather than only on SQLite is the "keep PostgreSQL and SQLite aligned"
# rule: a query that builds on one engine and is refused on the other is a worse trap than one
# refused on both. The removal of the working PostgreSQL shapes is recorded in the upgrade log.
#
# NOT guarded, on purpose: a CTE declared inside a CTE **body**. That renders through
# `build_cte_clause` → `query(…, cte=…)`, so its values bind in `:cte` during the same pass that
# emits their text, all of it inside the leading `WITH` — measured correct on both backends. The
# guard therefore belongs at these three filter/projection sites and nowhere else.
function _guard_no_nested_cte(handler::SQLObjectHandler, what::AbstractString)
  ctes = handler.object.ctes
  isempty(ctes) && return nothing
  names = join(collect(keys(ctes)), ", ")
  throw(QueryBuildError(
    "$what does not support a subquery that declares its own \e[4m\e[32m.with(...)\e[0m; " *
    "this one declares \e[4m\e[31m$(names)\e[0m.\n  " *
    "A nested CTE renders inside the subquery's parentheses, but its values bind into the " *
    "\e[4m\e[31m:cte\e[0m parameter bucket, which is flattened ahead of \e[4m\e[31m:select\e[0m " *
    "and \e[4m\e[31m:where\e[0m — on SQLite that binds them ahead of any value whose text comes " *
    "first, silently matching the wrong rows.\n  " *
    "Fold the CTE's predicate into the subquery's own \e[4m\e[32m.filter(...)\e[0m, or declare " *
    "the CTE on a query that is not nested inside a filter or a projection (#433)."))
end

_projection_is_aggregate(v)::Bool =
  v isa SQLTypeField && v.field isa SQLTypeFunction &&
  hasproperty(v.field, :aggregate) && getproperty(v.field, :aggregate) === true

# Soft heads-up: a non-aggregate scalar subquery with no LIMIT may match >1 row and error at the DB.
function _warn_if_possible_multirow(handler::SQLObjectHandler)
  vals = handler.object.values
  length(vals) == 1 || return nothing
  is_agg = _projection_is_aggregate(vals[1])
  has_limit = handler.object.limit != 0
  (!is_agg && !has_limit) && @warn(_emsg(
    "Subquery(...) projects a non-aggregate column with no LIMIT; if the correlation matches more than " *
    "one row the database raises \"more than one row returned by a subquery used as an expression\". " *
    "Use an aggregate, or add order_by + a limit of 1."))
  return nothing
end

function _get_select_query(v::ExistsObject, instruc::SQLInstruction; _as::Union{Nothing,String}=nothing)
  # #194 needs nothing here (#932): the clause this renders in set the evaluation phase, and the
  # OuterRef recorder reads it. Nesting needs nothing either (#938, above): the projected and the
  # filter spelling render the same `EXISTS (…)`.
  return _get_filter_query(v, instruc)
end
function _get_select_query(v::OuterRefObject, instruc::SQLInstruction; _as::Union{Nothing,String}=nothing)
  return _get_filter_query(v, instruc)
end
function _get_select_query(v::CTEReference, instruc::SQLInstruction; _as::Union{Nothing,String}=nothing)
  return _build_row_join(_cte_join_path(v), instruc, cte=true)
end
# #481 — unlike a CTE reference, a joined-copy reference does NOT materialize a join: `cjoin_on`
# already declared it, and `build()`'s ALIAS loop emits it. This only has to render the column.
function _get_select_query(v::JoinedReference, instruc::SQLInstruction; _as::Union{Nothing,String}=nothing)
  return _resolve_joined(v, instruc)
end
function _get_select_query(v::SubqueryObject, instruc::SQLInstruction; _as::Union{Nothing,String}=nothing)
  # #92: scalar single-column correlated subquery projected as a SELECT-list column. #194 is decided
  # by the clause's phase and nesting is legal (#938) — see `_get_select_query(::ExistsObject)`.
  return _render_scalar_subquery(v, instruc)
end
# #926: the FILTER-position arm — `filter("grid" => Subquery(…))`, `F("grid") == Subquery(…)`, an ON
# pair, a `When` condition. Whether its correlation needs a grouped column is the #194 guard's call,
# from the phase of the clause it renders in (#932): WHERE and ON are evaluated before GROUP BY, HAVING
# and the SELECT list after. Its values bind into whatever clause bucket the caller switched to
# (`:where`, `:join`, `:having`), as the membership arm's subquery does.
function _get_filter_query(v::SubqueryObject, instruc::SQLInstruction)
  return _render_scalar_subquery(v, instruc)
end

# The render both arms share: `(SELECT …)` for exactly one projected column, its values bound as one
# clause-ordered run in the ambient bucket.
function _render_scalar_subquery(v::SubqueryObject, instruc::SQLInstruction)::String
  # #433: renders an inline WITH that binds into `:cte` while its text sits in SELECT or WHERE.
  _guard_no_nested_cte(v.query, "Subquery(...)")

  # query() mutates the handler's parameters, and SQLField deepcopy is shallow on `.field`, so the same
  # SubqueryObject can be shared across list()/count() deepcopies — copy before rendering.
  handler = deepcopy(v.query)

  # Exactly one projected column (reuse the @in one-column rule).
  labels = _subquery_projection_labels(handler)
  length(labels) == 1 || throw(QueryBuildError(
    "Subquery(...) must project exactly one column; it currently projects $(length(labels)): " *
    "$(_summarize_projection_labels(labels)). Call .values(\"alias\" => <expr>) on the inner query."))

  _warn_if_possible_multirow(handler)

  # Passing the shared `parameters` makes query() treat this as a subquery: its build files under its
  # own clauses and restores the ambient bucket the caller switched to (`:select` for a projection,
  # `:where`/`:join`/`:having` for a predicate, #926), so the lifted run below lands where the text
  # sits. Correlate via outer=instruc.
  # #432: same nested-run reordering as `_build_exists_query` — everything this subquery binds must be
  # one clause-ordered run in the ambient bucket.
  nested_mark = nested_parameter_mark(instruc)
  inner_formatter = Ref{Any}(nothing)
  inner_sql = query(handler,
                    table_alias=instruc.table_alias,
                    connection=instruc.connection,
                    parameters=instruc.parameters,
                    outer=instruc,
                    built = inner -> (inner_formatter[] = _subquery_projection_formatter(handler, inner)))
  reattach_parameters!(instruc, detach_nested_run!(instruc, nested_mark))
  # #888: the inner build typed its one column (`query()` writes `projection_kinds` back onto
  # `handler`, our copy), so the value this text returns has that kind. File it under the node the
  # caller holds, for `_operand_kind` to read once the enclosing projection has rendered.
  _record_subquery_kind!(instruc, v, handler)
  # #929: and the formatter a value compared with it must satisfy, for `_expression_formatter`.
  _record_subquery_formatter!(instruc, v, inner_formatter[])
  return string("(", inner_sql, ")")
end
function _get_select_query(q::SQLTypeF, instruc::SQLInstruction; _as::Union{Nothing,String}=nothing)
  return _set_update_query(q, instruc)
end

function _resolve_outer_ref_field_name(ref::OuterRefObject, outer::SQLInstruction)::String
  if ref.field_name == "pk"
    pk_field = Models.get_model_pk_field(outer.object.model)
    pk_field === nothing && throw(QueryBuildError("OuterRef(\"pk\") requires the outer model '$(outer.object.model.name)' to define exactly one primary key field"))
    return String(pk_field)
  end
  return ref.field_name
end

function _build_exists_query(subquery::SQLObjectHandler, instruc::SQLInstruction)::String
  # #433 — before the deepcopy: this renderer emits no `WITH` prefix at all, so a CTE declared on
  # the subquery would be dropped from the SQL while still being resolvable by path. Guarding here
  # covers `Exists` in BOTH positions, because the projected form (`_get_select_query`) delegates
  # to the filter form.
  _guard_no_nested_cte(subquery, "Exists(...)")
  q = deepcopy(subquery)
  q.object.values = []
  q.object.order = []
  q.object.limit = 0
  q.object.offset = 0

  # #432: the inner build scatters its values across its own clause buckets while this EXISTS text is
  # spliced into ONE of the parent's clauses. Mark every bucket, then re-emit what it bound as one
  # contiguous run, clause-ordered, at this fragment's position. See `detach_nested_run!`. The build
  # files under its OWN clause roles, which is what the run sorts by, and restores the parent's
  # ambient bucket itself, on return and on throw (#936, #939).
  nested_mark = nested_parameter_mark(instruc)
  instruction = build(
    q.object,
    table_alias=instruc.table_alias,
    connection=instruc.connection,
    parameters=instruc.parameters,
    outer=instruc,
  )
  reattach_parameters!(instruc, detach_nested_run!(instruc, nested_mark))

  safe_table_name = safe_table_identifier(Models.model_table_name(q.object.model), instruction.connection)
  safe_alias = quote_identifier(instruction.alias, instruction.connection)

  io = IOBuffer()
  print(io, "EXISTS (SELECT 1\nFROM ", safe_table_name, " as ", safe_alias, "\n")

  for join_sql in instruction.join
    print(io, join_sql, "\n")
  end

  if !isempty(instruction._where)
    print(io, "WHERE ")
    for (index, where_sql) in enumerate(instruction._where)
      index > 1 && print(io, " AND \n   ")
      print(io, where_sql)
    end
    print(io, "\n")
  end

  if instruction.aggregate && !isempty(instruction.group)
    print(io, "GROUP BY ", join(instruction.group, ", "), " \n")
  end

  if !isempty(instruction.having)
    print(io, "HAVING ")
    for (index, having_sql) in enumerate(instruction.having)
      index > 1 && print(io, " AND \n   ")
      print(io, having_sql)
    end
    print(io, "\n")
  end

  print(io, "LIMIT 1)")
  return String(take!(io))
end


# #562: the `F(...)` / update-expression arrival point for a `"col__@transform"` string.
#
# This used to be a SECOND resolution ladder over `PormGtransform`: it read the same table and
# resolved the name with `getfield(Dialect, ...)`, while the string spelling resolved it with
# `getfield(@__MODULE__, ...)` into `QueryBuilder`'s own constructors. Two ladders over one table
# emitted different SQL for the same transform on the same column, and for `@date` on SQLite one of
# them was outright wrong (`CAST(col AS DATE)` -> the integer year; see `Dialect.DATE`).
#
# It now delegates into the one surviving ladder. `_check_function` is the richer of the two: it
# builds a typed `FObject` carrying a `formatter` (so the comparison value is validated rather than
# bound raw), it is the shape the #352/#373 sargable date-range rewrite recognises, and it already
# resolves joined paths, CTE and window columns. `_resolve_joined` below does exactly this.
function _get_filter_query(v::Vector{SubString{String}}, instruc::SQLInstruction)
  return _get_select_query(_check_function(String.(v)), instruc)
end
function _get_filter_query(v::String, instruc::SQLInstruction)
  # V does not have be suffix
  contains(v, "@") && return _get_filter_query(split(v, "__@"), instruc)
  # #481 removed the `"alias.column"` branch that used to sit here. It resolved FAIL-OPEN — an
  # unknown prefix fell through to ordinary field resolution and reported an unknown field named
  # `"typo.col"` — and it existed on this resolver only, which is why the same spelling never
  # worked in `values(...)` or in an operator pair. `Joined(alias, path)` replaces it.
  parts = split(v, "__")
  if size(parts, 1) > 1
    return _build_row_join(parts, instruc, as=false)
  else
    return _column_sql(instruc, instruc.alias, _solve_field(v, instruc.object.model, instruc))   # #985
  end
end

# #481 — resolve a `Joined(alias, path)` reference to `"alias"."db_column"`. It replaces #45's
# `_resolve_cjoin_on_alias_column`, which took a `"alias.column"` String and returned `nothing` for
# an unknown prefix so the caller could fall through. Every exit here is loud: a reference that
# names no declared alias is the caller's typo, and reporting it as an unknown *field* (what the
# fail-open path did) sent people looking for a column that was never the problem.
#
# The lookup is `object.alias_join`, NOT `instruct.row_join`: `cjoin_on` rows materialize in
# `build()`'s alias loop, after `values()` / `filter()` / `order_by()` have already rendered, so at
# the moment a projection resolves the row may not exist yet — but the declaration always does.
# Rendering needs only the alias and the target model, both of which the config carries.
#
# The rendered text is byte-identical to what the dotted-string path produced. Nothing reads it back
# any more: the #448 self-reference check and the alias ordering read the handle itself, at binding
# (#982), where #435's relocation and Phase 1b used to substring-match `"alias".` in the ON clause.
function _resolve_joined(ref::JoinedReference, instruc::SQLInstruction)::String
  _reject_joined_desc(ref, "a projection or predicate")
  # A `__@` segment is one of two different things, and they end differently.
  #
  # A TRANSFORM (`@year`, `@yyyy_mm`, …) is part of the column expression: the removed
  # `F("b2.dt__@year")` spelling supported it inside an ON clause — `_get_filter_query(::String)`
  # peeled it before reaching the alias branch — and dropping that would be a capability
  # regression, the exact failure #444 recorded when it swapped in a typed handle without widening
  # the paths around it. So it is built here, over the bare reference, through the same
  # `_check_function` ladder every other clause uses.
  #
  # An operator SUFFIX (`@gte`, `@in`, …) is a comparison, not a column, and belongs on the LEFT of
  # a filter pair where `_check_filter` peels it. Reaching here with one means the caller wrote it
  # somewhere that cannot carry it.
  if occursin("__@", ref.path)
    segments = String.(split(ref.path, "__@"))
    haskey(PormGsuffix, segments[end]) && throw(QueryBuildError(
      "Joined(\"$(ref.alias)\", \"$(ref.path)\") carries an operator suffix, which is only meaningful " *
      "on the left of a filter pair — write filter(Joined(\"$(ref.alias)\", \"$(ref.path)\") => value)."))
    transformed = _retag_joined_column(_check_function(segments), ref.alias)
    return _get_select_query(transformed, instruc)
  end
  occursin("__", ref.path) && throw(QueryBuildError(
    "Joined(\"$(ref.alias)\", \"$(ref.path)\") cannot traverse a relation: a cjoin_on joined copy is " *
    "one table, so its reference is a single column on that model. Declare another cjoin_on for the " *
    "next hop and reference its alias."))
  config = get(instruc.object.alias_join, ref.alias, nothing)
  if config === nothing
    declared = collect(keys(instruc.object.alias_join))
    throw(QueryBuildError(
      "Joined(\"$(ref.alias)\", …) names no cjoin_on alias on this query. " *
      (isempty(declared) ? "This query declares no cjoin_on at all." :
       "Declared aliases: $(join(declared, ", ")).")))
  end
  target_model = config.target
  (ref.path in target_model.field_names) ||
    throw(_unknown_field(target_model, ref.path))
  # Memoize the joined field so a filter's RHS formats through it (the same service
  # `tab_field_cache` performs for a base-model column), under the `:joined` namespace so an
  # identically spelled field path or CTE reference cannot read or claim the entry.
  memo_field!(instruc, memo_key(ref), target_model.fields[ref.path])
  return _column_sql(instruc, ref.alias,   # #985
                     safe_column_identifier(Models.field_db_column(target_model.fields[ref.path], ref.path), instruc.connection))
end
function _get_filter_query(v::SQLTypeFunction, instruc::SQLInstruction)
  # A function in a condition renders as it does projected: a filter-position function is an operand
  # (`Coalesce(Subquery(…), 0)`), and its arguments render through the same arms either way. #938
  # removed the one difference the two entry points used to make, the #92 nesting refusal.
  return _get_select_query(v, instruc)
end
function _get_filter_query(v::ExistsObject, instruc::SQLInstruction)
  return _build_exists_query(v.query, instruc)
end
function _get_filter_query(v::OuterRefObject, instruc::SQLInstruction)
  instruc.outer === nothing && throw(QueryBuildError("OuterRef(\"$(v.field_name)\") can only be resolved while building a correlated subquery such as Exists(subquery)."))
  outer = instruc.outer
  column = _resolve_outer_ref_field_name(v, outer)
  # #985: an `OuterRef` resolves in the outer statement, so inside an ON clause it is checked there as
  # a right-side column — whichever side of its comparison the subquery sits on (#962's rule). The
  # subquery's own columns render on its own instruction, outside the ON clause's scope.
  sql = _on_join_right(() -> _get_filter_query(column, outer), outer)
  # #194: this is the ONE place an OuterRef becomes SQL — `_resolve_outer_ref_field_name` has a
  # single caller and `_get_select_query(::OuterRefObject)` delegates straight here — so recording
  # the reference here cannot miss one that renders. Resolving against `outer` is also what makes
  # `sql` directly comparable to the outer's GROUP BY entries: both sides come out of the same
  # `_get_filter_query(::String, outer)`, including the join-alias numbering for a `__` path.
  #
  # A second caller of `_resolve_outer_ref_field_name` must record here too, or the guard in
  # `_check_grouped_correlation` (`build_query.jl`) silently stops seeing that reference.
  #
  # EVERY rendered ref is recorded, with the outer's scope at this moment — the clause the outer
  # render is suspended in, which is where this subquery is evaluated (#932). Recording is
  # unconditional so no spelling can slip past by reaching a different render entry point; whether
  # the ref needs a grouped column is decided once, in the guard, from `phase` and `group_key`.
  scope = outer.scope
  push!(outer.outer_refs, (label = something(scope.label, "a correlated subquery"), ref = v.field_name,
                           column = column, expr = sql, phase = scope.phase, group_key = scope.group_key))
  return sql
end
function _get_filter_query(v::CTEReference, instruc::SQLInstruction)
  return _build_row_join(_cte_join_path(v), instruc, as=false, cte=true)
end
# #481 — see `_get_select_query(::JoinedReference, …)`: the join already exists, so only the column
# is rendered, and both clauses share one resolver.
function _get_filter_query(v::JoinedReference, instruc::SQLInstruction)
  return _resolve_joined(v, instruc)
end

# #444 — lower a CTE handle to the segment vector `_build_row_join` walks. It is byte-for-byte the
# vector the pre-#444 string `"<name>__<path>"` produced, which is why the deep-hop loop, the
# FK-reached JSON gate and the terminality error all keep working with no edit of their own.
function _cte_join_path(v::CTEReference)
  _reject_cte_desc(v, "a projection or predicate")
  # Every legitimate suffix has been peeled by the parse boundary (`_check_filter` splits `ref.path`
  # on `__@` before retagging; `values`/`order_by` refuse suffixes outright). One surviving here can
  # only come from a spelling those boundaries never see — e.g. a CTE handle on a filter's RIGHT side.
  occursin("__@", v.path) && throw(QueryBuildError(
    "\e[4m\e[31mCTE(\"$(v.name)\", \"$(v.path)\")\e[0m carries an operator or transform suffix " *
    "(\e[4m\e[31m__@\e[0m) where a plain column path is required. Suffixes belong on the LEFT side " *
    "of a \e[4m\e[32mfilter(...)\e[0m pair."))
  return String[v.name; String.(split(v.path, "__"))]
end
# function _get_filter_query(v::SQLTypeText, instruc::SQLInstruction)
#   return _get_select_query(v, instruc)
# end
function _get_filter_query(v::SQLTypeField, instruc::SQLInstruction)
  # check if SQLTypeField exists in cache
  # #474: keyed by `memo_key`, not `_as`. This is the site the measured defect went
  # through — a CTE reference projected as `CTE("parent", "sku")` claimed the memo under
  # `"parent__sku"`, and a later `filter("parent__sku" => …)` on the model's OWN ForeignKey read it
  # back, filtering the CTE's column while the ForeignKey's join sat unused in the statement.
  key = memo_key(v)
  cached = memo_projection(instruc, key)
  # #586: a memoized render is reused ONLY for a node kind that never binds a parameter — a String
  # path, a CTE or joined-copy handle, an outer reference. A projected label (`values("q" =>
  # "date__@yyyy_q")`) memoizes text carrying nine `?` whose values sit in `:select`; reusing that
  # text for `filter("date__@yyyy_q" => …)` printed the markers into WHERE with nothing bound for
  # them. The discarded second render this fix removes from `_get_filter_query(::SQLTypeOper)`
  # happened to bind them — under the right bucket, by accident — which is why the shape ever
  # executed on SQLite. Same rule and same gate as `get_order_query` (#587); a WHERE predicate has
  # no alias to fall back on, so a binding expression renders afresh here on both backends (on
  # PostgreSQL that renumbers its `$N`s, which is harmless outside DISTINCT/ORDER BY).
  #
  # #701: that gate reads the KEY's kind, and a projection alias is a plain `String` key whose
  # memoized text can still bind — `Q("next_race" => 73)` over `F("raceid") + 1` reprinted the `?`
  # with its value in `:select`. `_alias_lhs` (projection_types.jl) applies the same rule to the
  # PROJECTION behind an alias key and renders it afresh when it binds; any other hit is returned
  # as it was.
  # #985: not inside an ON clause, though. Memoized text was rendered outside the clause's scope, so it
  # never passed `_record_join_column`; there a projection alias renders its source afresh
  # (`_alias_lhs(…; fresh = true)`), and a path or handle falls through to the render below, which
  # resolves the same row — so the same text — and is checked on the way. It writes no memo entry
  # (`cached` is set), so the first render stays the one every reader memoized against (#404).
  reuse = cached !== nothing && v.field isa Union{String,SQLTypeCTE,SQLTypeJoined,OuterRefObject}
  if reuse && instruc.scope.join_hop !== nothing
    fresh = _alias_lhs(key, cached, instruc; fresh = true)
    fresh === nothing || return fresh
    reuse = false
  end
  if reuse
    return _alias_lhs(key, cached, instruc)
  else
    v_copy = deepcopy(v)
    # `_as` travels with the render. This is now the ONLY render of a predicate's left-hand side —
    # the discarded second render was the one passing `_as`, and `_get_select_query(::String)`
    # reads it to refresh the base-model `memo_field` entry under that key.
    v_copy.field = _get_select_query(v_copy.field, instruc, _as=v._as)
    # Never overwrite an existing entry (#404): the first render is the one every other reader
    # memoized against, and a fresh render of a binding node is not a better selector, only a
    # second binding.
    if key !== nothing && cached === nothing
      memo_projection!(instruc, key, v_copy)
    end
    return v_copy.field
  end
end
# Coerce a JSON numeric-comparison RHS to an actual Julia number, so BOTH dialects compare
# numerically (PostgreSQL casts the extracted text `::numeric`; SQLite's json_extract returns a
# native number). Binding a string here would make SQLite compare number-vs-text and silently
# invert every comparison.
function _json_numeric_rhs(value)
  value isa Bool && return Int(value)
  value isa Integer && return value
  value isa AbstractFloat && return value
  s = strip(string(value))
  # Base 10 only, as on every other numeric path (#773): the bare parsers read `"0x10"` as 16.
  Models.is_base10_number(s) || throw(FilterError("A numeric JSON comparison requires a base-10 number; got a string that is not one."))
  n = tryparse(Int, s); n !== nothing && return n
  f = tryparse(Float64, s); (f !== nothing && isfinite(f)) && return f
  throw(FilterError("A numeric JSON comparison requires a number; got a $(typeof(value))."))
end

# #27: render a comparison against a JSON path lookup (e.g. `payload__driver`). The RHS binds
# dialect-aware — NOT through the JSON field's formatter (which would reject a plain string like
# "hamilton"):
#   - PostgreSQL `#>>` always yields TEXT, so equality binds text and `<`/`>` cast the LHS
#     `::numeric`.
#   - SQLite `json_extract` returns the value's NATIVE type, so equality binds the raw Julia value
#     (a JSON number stays a number → `5 = 5`, not `5 = '5'`) and comparisons need no cast.
function _render_json_lookup_comparison(v::SQLTypeOper, column::String, instruc::SQLInstruction)::String
  op = v.operator
  # #596: a JSON path lookup (`payload__kind`) is a bare path, so admitting a flat `Vector{UInt8}` at
  # parse made it reachable here — and this is the one arm where it was SILENT: the PostgreSQL branch
  # does `string(v.values)`, which stringified the payload's Julia `repr` into
  # `#>> '{"kind"}' = 'UInt8[0x01, 0x02]'` — valid SQL, zero rows, no error. A JSON value is never a
  # byte payload, so the refusal is unconditional.
  _guard_vector_equality(v, nothing)
  # #811: the same silent arm, reached by a column expression. `"payload__kind" => F("grid")` bound
  # the `FExpression`'s `repr` as text on PostgreSQL — zero rows, no error — while SQLite refused it as
  # an unbindable value. Comparing extracted JSON against a column needs a per-engine cast nobody has
  # designed, so it is refused on both engines. It has to be here, not at parse: whether a path is a
  # JSON path is only known once its column resolves. `@isnull` never gets this far (#808's parse check).
  v.values isa SQLType && throw(FilterError(
    "Error in filter '$(_filter_path_label(v))': a JSON path lookup compares the extracted value " *
    "against a value, not a column expression"))
  is_pg = instruc.connection isa PormGPostgres
  if op == "ISNULL"
    # Render IS NULL directly — the shared ISNULL() rejects any column containing "(", which a
    # legitimate SQLite json_extract(...) expression trips.
    return string(column, v.values == true ? " IS NULL" : " IS NOT NULL")
  elseif op in ("=", "!=", "<>")
    # PG: bind text (LHS is text). SQLite: bind the native value (LHS keeps its JSON type).
    ph = add_parameter!(instruc, is_pg ? string(v.values) : v.values)
    return string(column, " ", op, " ", ph)
  elseif op in (">", ">=", "<", "<=")
    lhs = is_pg ? "($(column))::numeric" : column
    ph = add_parameter!(instruc, _json_numeric_rhs(v.values))
    return string(lhs, " ", op, " ", ph)
  else
    throw(FilterError("The operator \e[31m$(op)\e[0m is not supported on a JSON path lookup. Use =, !=, <, <=, >, >=, or __@isnull."))
  end
end

# #27: render a JSONB containment/overlap operator (@>, ?, ?|, ?&). The LHS must be a JSON COLUMN
# (terminal), not a nested key path. Binds the RHS per operator (jsonb document / text key /
# text[] key array) and dispatches to the per-dialect Dialect renderer (PG emits the operator;
# SQLite throws PG-only).
function _render_json_operator(v::SQLTypeOper, column::String, instruc::SQLInstruction)::String
  col_as = isa(v.column, SQLTypeField) ? v.column._as : nothing
  # #474: the memo is keyed by namespace, the MESSAGE by what the caller wrote.
  col_key = isa(v.column, SQLTypeField) ? memo_key(v.column) : nothing
  if memo_json_lookup(instruc, col_key)
    throw(FilterError("The \e[31m@$(v.operator)\e[0m operator applies to a JSON column, not a nested key path (\e[31m$(col_as)\e[0m); this is not supported in v1."))
  end
  base = _resolve_json_operator_field(v, instruc)
  (base !== nothing && Models.is_json_field(base)) ||
    throw(FilterError("The \e[31m@$(v.operator)\e[0m operator requires a JSONField column; \e[31m$(something(col_as, "the target"))\e[0m is not JSON."))
  op = v.operator
  ph = if op == "jcontains"
    add_parameter!(instruc, Models.format_json_sql(v.values); sql_type="jsonb")
  elseif op == "has_key"
    add_parameter!(instruc, string(v.values))
  else  # has_any_keys / has_keys
    v.values isa AbstractVector ||
      throw(FilterError("The \e[31m@$(op)\e[0m operator requires an array of keys, e.g. filter(\"col__@$(op)\" => [\"a\", \"b\"]); got a single value."))
    add_parameter!(instruc, String.(v.values); sql_type="text[]")
  end
  return getfield(Dialect, Symbol(op))(instruc.connection, column, ph)
end

# #904: render a PostgreSQL network operator (`<<`, `<<=`, `>>`, `>>=`, `&&`, `family()`,
# `masklen()`). The left-hand side must be a `GenericIPAddressField` or `CIDRField` column — the
# model's own or a joined path's terminal field — which is the same evidence a pattern lookup reads
# (`_pattern_text_kind`). A projection alias never gets here from a filter
# (`_ALIAS_UNSUPPORTED_OPERATORS`), and a `When` condition on one has no field, so it is refused below.
#
# The containment operand binds through `format_inet_network_sql`, not the column's own formatter: it
# is a network, which `format_inet_sql` refuses, and its host bits may be set, which `format_cidr_sql`
# refuses. It binds typed (`::inet`), because `<<` is ambiguous on an untyped parameter; a `cidr` column
# meets it through PostgreSQL's implicit `cidr → inet` cast. A column on the right (`F`, a CTE or a
# joined column) is compared as it is, uncast. Any other expression is refused: none was asked for, and
# an unvalidated one would fail at the server instead.
function _render_network_operator(v::SQLTypeOper, column::String, operand_field, field_label::AbstractString,
                                  instruc::SQLInstruction)::String
  op = v.operator
  # The path the caller wrote, for the messages. Without a field it is a projection alias (reached
  # through a `When` condition) or a transform (`happened__@year`). A transform node keeps neither the
  # caller's `@year` spelling nor a path to quote, so its refusal names the column it transforms and
  # quotes no path, rather than one the caller never wrote or the SQL it renders.
  label, subject = if operand_field !== nothing
    field_label, field_label
  elseif isa(v.column, SQLTypeField) && isa(v.column.field, AbstractString)
    v.column.field, v.column.field
  elseif isa(v.column, SQLTypeField) && isa(v.column.field, SQLTypeFunction) &&
         isa(v.column.field.column, AbstractString)
    nothing, "$(v.column.field.column), under a transform,"
  else
    column, column
  end
  where_ = label === nothing ? "Error in filter" : "Error in filter '$(label)__@$(op)'"
  (operand_field !== nothing && _pattern_text_kind(operand_field.formatter) in (:inet, :cidr)) ||
    throw(FilterError("$(where_): the @$(op) lookup requires a GenericIPAddressField " *
                      "or CIDRField column, and $(subject) is not one."))
  lookup = "$(label)__@$(op)"
  ph = if isa(v.values, Union{SQLTypeF,SQLTypeCTE,SQLTypeJoined})
    _on_join_right(() -> _get_filter_query(v.values, instruc), instruc)   # #985: the right side
  elseif isa(v.values, Union{SQLType,SubqueryObject,SQLObjectHandler})
    throw(FilterError("Error in filter '$(lookup)': the @$(op) lookup takes a value or a column " *
                      "(F(\"…\")), not this expression."))
  elseif op in NETWORK_CONTAINMENT_OPERATORS
    add_parameter!(instruc, _guarded_format(Models.format_inet_network_sql, v.values, op, label,
                                            operand_field.type); sql_type = "inet")
  else  # family / prefixlen
    # A `Bool` is an `Integer` in Julia, and `true` is not a family (#949's reasoning).
    allowed, what = op == "family" ? ((4, 6), "4 or 6") : (0:128, "a whole number from 0 to 128")
    (v.values isa Integer && !(v.values isa Bool) && v.values in allowed) ||
      throw(FilterError("Error in filter '$(lookup)': the @$(op) lookup takes $(what), got another $(typeof(v.values))."))
    add_parameter!(instruc, Int(v.values))
  end
  return getfield(Dialect, Symbol(op))(instruc.connection, column, ph)
end

# Resolve the base PormGField a JSON operator targets: a bare column name lives on the model;
# an FK-reached terminal JSON column was cached in tab_field_cache when `column` resolved.
function _resolve_json_operator_field(v::SQLTypeOper, instruc::SQLInstruction)
  isa(v.column, SQLTypeField) || return nothing
  fld = v.column.field
  if fld isa String && !contains(fld, "__")
    return get(instruc.object.model.fields, fld, nothing)
  end
  # #474: the memo key, like every other `tab_field_cache` reader. Missing this one made a JSONB
  # containment operator over a CTE column — `filter(CTE("evc", "payload__@has_key") => "driver")` —
  # miss the entry `_build_row_join` had just written under the namespaced key and fail closed with
  # "evc__payload is not JSON", a shape that rendered before #474. The mirror hazard is worse: with
  # a base-model path spelled the same, the un-namespaced lookup could return the OTHER namespace's
  # field and license a jsonb operator against a CTE's text column.
  return memo_field(instruc, memo_key(v.column))
end

# #28: render an array containment/overlap lookup (`@acontains` @>, `@contained_by` <@, `@overlap` &&)
# on an `ArrayField` column — a bare one, one reached through a ForeignKey or a CTE, or a slice
# (`tags__0_2`), whose memo entry is the array field itself. Read AFTER `column` renders, which is
# what fills the memo for a joined path.
#
# The value goes through the column's `ArrayFormatter`, so every element is checked and converted by
# the ELEMENT field's own formatter and the whole list binds as ONE array literal — exactly what an
# equality binds — but with the field's `size` lifted: `size` bounds what the column may STORE, and
# `@contained_by`/`@overlap` legitimately ask about a longer list (`"tyre_compounds__@contained_by"
# => [all five compounds]` against a `size = 3` column). No cast: the operators are polymorphic, so
# the server types the parameter from the column, as it does for `=` (measured on both drivers).
function _render_array_operator(v::SQLTypeOper, column::String, instruc::SQLInstruction)::String
  field, _ = _operand_field(v, instruc)
  (field !== nothing && _is_array_field(field)) ||
    throw(FilterError("The \e[31m@$(v.operator)\e[0m lookup requires an ArrayField column; " *
                      "\e[31m$(_array_lookup_label(v))\e[0m is not one."))
  # The parse ladder admits only a vector here (`_check_fixed_shape_lookup` refuses a scalar, and
  # `_check_column_rhs_lookup` a column); this is the fail-safe for a spelling that bypasses it.
  v.values isa AbstractVector ||
    throw(FilterError("The \e[31m@$(v.operator)\e[0m lookup takes a list of elements."))
  formatter = field.formatter::Models.ArrayFormatter
  unbounded = Models.ArrayFormatter(formatter.base, formatter.kind, nothing)
  literal = _guarded_format(unbounded, v.values, v.operator, _array_lookup_label(v), field.type)
  placeholder = add_parameter!(instruc, literal)
  return getfield(Dialect, Symbol(v.operator))(instruc.connection, column, placeholder)
end

# The path an array lookup names, for its messages: the field path the caller wrote, or the memo
# key's path for a joined or CTE column. `"this expression"` for an operand with neither (`@len`).
function _array_lookup_label(v::SQLTypeOper)::String
  c = v.column
  c isa SQLField && c.field isa String && return c.field
  k = c isa Union{SQLField,CTEReference,JoinedReference} ? memo_key(c) : nothing
  return k === nothing ? "this expression" : k[2]
end

# #352: sargable rewrite for `col__@yyyy_mm` / `col__@year` / `col__@date` comparisons.
#
# `to_char(col, 'YYYY-MM') <= $1` (and the EXTRACT(YEAR ...) equivalent) puts a function call on
# the indexed column: no index on `col` applies, and PostgreSQL cannot estimate selectivity
# through it (issue #352 measured a 193x row-count misestimate cascading into an 18+ minute plan).
# Rewritten as a plain comparison/range on the raw column:
#
#   @exact (bare `=`)  col >= F AND col < N
#   @gte               col >= F
#   @gt                col >= N
#   @lte               col < N
#   @lt                col < F
#
# where F = first day of the bucket period and N = first day of the following period. `@date`
# needs no range at all (F == the literal) since to_char at day granularity on a DATE column
# preserves chronological order exactly — the rewrite there is just "drop the to_char".
#
# #373 extended the rewrite to a JOINED path (`fk__col__@yyyy_mm`), which #352 had left out
# because the terminal field's TYPE — what the DATE-only gate below needs — is not readable off
# `instruc.object.model`. See `_resolve_bucket_column` for how that is answered.
#
# Scope:
#   - Only a plain DATE column (`_is_date_field`) — TIMESTAMPTZ/TIMESTAMP are excluded because
#     to_char renders in the session TimeZone, so naively computing F/N would shift the boundary
#     around midnight. Left on the existing rendering.
#   - Only a plain scalar RHS (String/Number) — an F()/subquery/Case RHS falls through unchanged.
#
# Returns the rendered SQL string, or `nothing` to fall through to the existing rendering.
function _render_sargable_date_range(v::SQLTypeOper, instruc::SQLInstruction)::Union{String,Nothing}
  isa(v.column, SQLTypeField) || return nothing
  fobj = v.column.field
  isa(fobj, FObject) || return nothing
  raw_field = fobj.column
  # #444: a CTE-scoped bucket column arrives as a handle rather than a `"<cte>__col"` string. It
  # must be admitted here or the rewrite silently stops firing for every CTE date filter — the exact
  # failure mode #376 describes two paragraphs down in `_resolve_bucket_column`, reached by a
  # different route. Measured against main by rendering both spellings: without this line
  # `filter(CTE("ev","seen__@yyyy_mm__@lte") => "1991-10")` degraded from `"seen" < '1991-11-01'`
  # back to `to_char("seen",'YYYY-MM') <= '1991-10'`.
  # #481: `JoinedReference` for the same reason, one namespace over.
  isa(raw_field, Union{String,CTEReference,JoinedReference}) || return nothing
  v.operator in ("=", ">=", ">", "<=", "<") || return nothing
  (v.values isa AbstractString || v.values isa Number) || return nothing

  # The bucket gate runs BEFORE the column is resolved: resolving a joined path renders its join,
  # and a non-bucket transform (`@month`, `@quarter`, …) must never reach that.
  bucket = if fobj.function_name == "EXTRACT_DATE" && get(fobj.kwargs, "format", nothing) == "YYYY-MM"
    :yyyy_mm
  elseif fobj.function_name == "DATE"
    # #562: `@date` used to be a `ToChar(x, "YYYY-MM-DD")`, i.e. an `EXTRACT_DATE` node carrying the
    # mask. It is now a named `DATE` function so the dialect can pick the per-engine spelling. This
    # arm moves with it, and it is load-bearing in a way no correctness test can see: on a plain
    # `DateField` the rewrite DROPS the transform entirely, so a stale marker here does not render
    # wrong SQL — it silently stops rewriting, the #376 failure mode.
    :date
  elseif fobj.function_name == "EXTRACT" && get(fobj.kwargs, "part", nothing) == "YEAR"
    :year
  else
    return nothing
  end

  f_meta, column_sql = _resolve_bucket_column(raw_field, instruc)
  f_meta === nothing && return nothing
  _is_date_field(f_meta) || return nothing                          # DATE only, not TIMESTAMP(TZ)

  # #576: this rewrite runs AHEAD of every branch in `_get_filter_query`, so for `@date` / `@yyyy_mm`
  # / `@year` on a plain `DateField` it — not the transform ladder — is what formats the user's
  # value, and it was the leak nobody had named. `raw_field` is the spelling the user wrote (a
  # String, or a `CTEReference`/`JoinedReference` that prints as one) and `f_meta` is the terminal
  # field, so both message labels are real here rather than synthesised.
  bind(x) = add_parameter!(instruc, _guarded_format(f_meta.formatter, x, "=", raw_field, f_meta.type))

  if bucket == :date
    # Same granularity as the column: no range, operator unchanged — just drop the to_char.
    # This `bind` is the only one handed the RAW value; the range arms below bind computed `Date`s.
    return string(column_sql, " ", v.operator, " ", bind(v.values))
  end

  # `_year_bucket_bounds` raises `FilterError` on every rejection already, but
  # `_yyyy_mm_bucket_bounds` opens with `Models.format_yyyy_mm(value)`, which raises
  # `InvalidValueError` on a bad shape — the same leak, one call deeper. Guarded here rather than
  # inside the helper, because the helper has no field to name.
  first_of_period, next_period = try
    bucket == :yyyy_mm ? _yyyy_mm_bucket_bounds(v.values) : _year_bucket_bounds(v.values)
  catch e
    _locate_filter_refusal(e, raw_field, f_meta.type)
  end

  if v.operator == ">="
    return string(column_sql, " >= ", bind(first_of_period))
  elseif v.operator == ">"
    return string(column_sql, " >= ", bind(next_period))
  elseif v.operator == "<="
    return string(column_sql, " < ", bind(next_period))
  elseif v.operator == "<"
    return string(column_sql, " < ", bind(first_of_period))
  else # "="
    p1, p2 = bind(first_of_period), bind(next_period)
    return string("(", column_sql, " >= ", p1, " AND ", column_sql, " < ", p2, ")")
  end
end

# Terminal field metadata + rendered SQL for the column a date-bucket comparison targets, or
# `(nothing, "")` to fall through to the existing rendering.
#
# A bare column reads its metadata straight off the queried model. A JOINED path (#373) cannot:
# `FObject.column` still holds the unsplit dotted string at this point, and the terminal field only
# becomes knowable once the path has actually been walked. So the path is RENDERED first and the
# type read back out of `tab_field_cache`, which `_build_row_join` populates as it goes.
#
# Rendering first is the design, not a compromise. `_build_row_join` is the only authority on which
# model and field a dotted path resolves to — forward FK, reverse relation, many-to-many, and the
# `driver` → `driver_id` short-form rewrite whose ambiguity against a declared `related_name` is
# documented on `_resolve_fk_short_form`. Re-deriving that walk here would be a SECOND resolver able
# to disagree with the renderer, and a disagreement puts the date range on a different table's
# column with no error and wrong rows. Nothing is saved by not rendering, either: the rewritten
# predicate references the joined column, so the join is built either way.
#
# The early render is side-effect-free in every way that matters here: `build_joins.jl` binds no
# parameters, and `_insert_join` dedups on (a, b, key_a, key_b, alias_a) — so when the DATE gate
# rejects the field, the fall-through renders the same path again and gets the same alias back.
# Identical SQL, one extra traversal.
function _resolve_bucket_column(raw_field::String, instruc::SQLInstruction)
  if !contains(raw_field, "__")
    f_meta = get(instruc.object.model.fields, raw_field, nothing)
    f_meta === nothing && return (nothing, "")
    return _checked_bucket_column(f_meta, raw_field, _get_select_query(raw_field, instruc), instruc)
  end

  # A CTE-rooted reference now takes the `::CTEReference` method below (#444) rather than this
  # branch, but the reasoning that makes the DATE gate trustworthy over a CTE is the same and is
  # recorded here because it is not obvious.
  # A CTE model's column types are INFERRED (`_set_field_from_sql_function`, ctes.jl), so the
  # question is whether one can ever be typed DATE while the column holds something else. It cannot:
  # a plain-column projection reads the real field; COUNT/SUM yield IntegerField; CASE/WHEN route
  # through `_case_output_field`, which types a CASE as DATE only when every non-NULL branch is
  # itself a date column (#812) or `output_field` names `date`, which the SQL casts to a date on
  # both engines (`date(…)` on SQLite since #822, and for `Coalesce` & co. since #852);
  # MIN/MAX carry the base DateField and genuinely produce a date; and every OTHER function —
  # `ToChar` included, which is what would actually produce a "1991-10" text column — is rejected
  # outright when the CTE model is built unless it declares its type. So the DATE gate is as
  # trustworthy here as anywhere else.
  #
  # #376: the drift guard below still MATCHES on a CTE path. It matched before the fix too — both
  # sides read the SAME field object, so they agreed on the physical name and the rewrite was
  # applied to a column the CTE does not expose. What changed is WHICH name they agree on: the CTE
  # model's fields now carry no db_column (`Models.field_without_db_column`, applied in
  # `_build_cte_custom_model`), so `field_db_column(f_meta, <alias>)` and the rendered column both
  # answer the projection ALIAS. Resolving the alias at the REFERENCE site instead would have left
  # `f_meta` claiming the physical name while the render answered the alias — failing this guard
  # closed and silently dropping the #352/#373 rewrite for every CTE date-bucket filter, with no
  # other symptom. That is why the fix belongs at construction.
  column_sql = _get_select_query(raw_field, instruc)
  # #474: a String path reaching HERE is base-model. #492 restored `"<cte>__<col>"`, so that is no
  # longer true by construction — it is true because `_resolve_cte_string_paths!` (`ctes.jl`) has
  # already rewritten every CTE-rooted string into a `CTEReference` by the time `build()` renders
  # anything. Rewriting rather than gating is exactly what keeps this line correct: had the string
  # stayed a string and been resolved here, it would read `:base` while the join builder wrote
  # `:cte`, silently dropping the #352/#373 rewrite on one spelling only. Its CTE twin below asks
  # for the same entry under the other half of the namespace.
  f_meta = memo_field(instruc, memo_key(:base, raw_field))
  f_meta === nothing && return (nothing, "")
  return _checked_bucket_column(f_meta, String(last(split(raw_field, "__"))), column_sql, instruc)
end

# #444 — the CTE-handle twin of the joined-path branch above, and deliberately identical to it in
# every step: render first (only `_build_row_join` is authority on what a path resolves to), read
# the terminal field back out of `tab_field_cache`, then run the same drift guard. The cache key is
# `_cte_as(ref)` — `"<name>__<path>"` — which is precisely the key `_build_row_join` writes, because
# the segment vector it walks is the one the pre-#444 string produced. All the reasoning above about
# why the DATE gate can be trusted over a CTE (inferred column types, #376's db_column stripping)
# applies here unchanged.
function _resolve_bucket_column(ref::CTEReference, instruc::SQLInstruction)
  column_sql = _get_select_query(ref, instruc)
  f_meta = memo_field(instruc, memo_key(ref))   # #474: namespaced memo
  f_meta === nothing && return (nothing, "")
  return _checked_bucket_column(f_meta, String(last(split(ref.path, "__"))), column_sql, instruc)
end

# #481 — the joined-copy twin. `_resolve_joined` writes the memo entry as it renders, so the read
# below always hits; the same drift guard then applies.
function _resolve_bucket_column(ref::JoinedReference, instruc::SQLInstruction)
  column_sql = _get_select_query(ref, instruc)
  f_meta = memo_field(instruc, memo_key(ref))
  f_meta === nothing && return (nothing, "")
  return _checked_bucket_column(f_meta, ref.path, column_sql, instruc)
end

# Drift guard: the rewrite may only range on a column that IS the one `f_meta` describes. That holds
# by construction on every branch today — `_build_row_join` renders the terminal column through
# `_solve_field` and caches `last_field` from the same model and segment — which is precisely why it
# is worth pinning. If the correspondence ever breaks, the rewrite falls back to the existing
# (correct, merely non-sargable) rendering instead of quietly ranging on some other column.
# Fail-safe, never fail-loud: a mismatch is a PormG-internal invariant, not a user error.
function _checked_bucket_column(f_meta, last_segment::String, column_sql::String, instruc::SQLInstruction)
  expected = safe_column_identifier(Models.field_db_column(f_meta, last_segment), instruc.connection)
  endswith(column_sql, string(".", expected)) || return (nothing, "")
  return (f_meta, column_sql)
end

# Reuses Models.format_yyyy_mm for shape/type validation (String "YYYY-MM" regex, or 6-digit
# Integer YYYYMM), then parses the normalized string for range math. format_yyyy_mm does NOT
# validate the month is 01-12 (only the regex shape) — Dates.Date(y, m, 1) does, and its
# ArgumentError is caught and rethrown as a FilterError so a filter-level defect isn't a bare
# Dates.jl exception (consistent with the catch/rethrow pattern below for BETWEEN-style errors).
# A year outside 1..9999 cannot be expressed as a date bound: `Dates.Date` happily accepts year 0
# and negatives and stringifies them as "0000-01-01" / "-0005-01-01", which both backends reject at
# execution with an opaque server-side error — and `format_date_sql(::Date)` is a bare `string(...)`
# that validates nothing. Takes any `Real` so it can run before `Int(...)` narrowing.
function _check_year_bound(y::Real)
  (1 <= y <= 9999) || throw(FilterError("The year is out of the range a date bound can express (1-9999)."))
  return nothing
end

function _yyyy_mm_bucket_bounds(value)::Tuple{Dates.Date,Dates.Date}
  normalized = Models.format_yyyy_mm(value)   # throws InvalidValueError on bad shape/type
  y = parse(Int, normalized[1:4])
  m = parse(Int, normalized[6:7])
  # The regex admits "0000-01", which would render the unusable "0000-01-01". Same bound as @year.
  _check_year_bound(y)
  try
    first_of_period = Dates.Date(y, m, 1)
    return first_of_period, first_of_period + Dates.Month(1)
  catch e
    throw(FilterError("The value is not a valid YYYY-MM bucket: it is not a calendar month."))
  end
end

# Resolve `@year`'s RHS to a calendar year, accepting every value shape the pre-#352 rendering
# accepted via `Models.format_number_sql` — Integer, Decimal, and a whole-valued Float (an ETL
# app pulling a year out of a Float64 DataFrame column is the common case), plus a numeric
# String. Narrowing this would be a breaking change for consuming apps, not a tightening.
#
# What IS rejected, because the range rewrite cannot express it while `EXTRACT(YEAR ...)` could:
#   - Bool (`Bool <: Integer` in Julia; format_number_sql carries a ::Bool overload for exactly
#     this trap) — `false` would silently become year 0.
#   - a fractional year (1991.7) — no single date bound represents it.
#   - a year outside 1..9999 — `Dates.Date` accepts year 0 and negatives and renders them
#     "0000-01-01" / "-0005-01-01", which both backends reject at execution with an opaque
#     server-side error; `format_date_sql(::Date)` is a bare `string(...)` and validates nothing.
# The string branch parses base-10 explicitly: `tryparse(Int, "0x10")` returns 16 in Julia, so
# the default would silently accept a hex literal as a year.
function _year_bucket_bounds(value)::Tuple{Dates.Date,Dates.Date}
  # The range check runs BEFORE `Int(...)` narrowing on every numeric branch: `Int(big(10)^20)`
  # and `Int(1e30)` throw a raw `InexactError`, which is not a PormGError at all and whose message
  # never mentions a year filter. `isinteger(1e30)` is `true`, so the whole-year guard alone does
  # not stop it. Comparing first works on any Real — BigInt, BigFloat, Rational, Decimal.
  y = if value isa Bool
    throw(FilterError("A __@year filter requires a year, not a Bool."))
  elseif value isa Integer
    _check_year_bound(value)
    Int(value)
  elseif value isa Real
    isinteger(value) || throw(FilterError("The value is not a whole year for a __@year filter."))
    _check_year_bound(value)
    Int(value)
  elseif value isa AbstractString
    n = tryparse(Int, strip(value), base=10)
    n === nothing && throw(FilterError("The value is not a valid year for a __@year filter."))
    _check_year_bound(n)
    n
  else
    throw(FilterError("A __@year filter requires a year as an Integer, a whole Real, or a numeric String; got $(typeof(value))."))
  end
  first_of_period = Dates.Date(y, 1, 1)
  return first_of_period, first_of_period + Dates.Year(1)
end

# Apply a field's formatter to a filter's right-hand side (#411).
#
# Django's answer, in one function. `Field.get_prep_value` is scalar-only for EVERY Django field type;
# `In` and `Range` inherit `FieldGetDbPrepValueIterableMixin`, whose `get_prep_lookup()` maps it over
# the rhs itself. The iterable-aware layer belongs to the LOOKUP, not to the field. PormG had that
# contract inverted — the three call sites below handed the whole vector to `field.formatter`, so
# every formatter had to cope with an array individually, and only two of them did. `__@in` was
# therefore broken on DateField, DateTimeField, BooleanField, DurationField, UUIDField and
# BinaryField, and silently WRONG on JSONField.
#
# The operator is the discriminator, not the value's type, and that distinction is the whole point.
# `format_binary_sql` and `format_json_sql` are the field types whose SCALAR value is itself a
# collection: a `Vector{UInt8}` IS one binary value, and `[1, 2]` IS one JSON array. Dispatching on
# `values isa AbstractArray` would map over the bytes of a BinaryField and destroy it. Only "this is a
# MEMBERSHIP lookup, so the rhs is a list of values" licenses the map — which is exactly why Django
# puts the mixin on the lookup class.
#
# `BETWEEN`/`NOT BETWEEN` are the other iterable lookup — Django's `Range` carries the same mixin —
# and #654 routes them through here too, so their two operands are formatted in ONE guarded call and
# neither binds until both succeed (the #467 contract, which the WHERE arm used to hand-roll). Every
# scalar comparison passes through untouched.
const _ITERABLE_LOOKUP_OPERATORS = ("IN", "NOT IN", "BETWEEN", "NOT BETWEEN")
_format_filter_value(formatter, values, operator::AbstractString) =
  operator in _ITERABLE_LOOKUP_OPERATORS && values isa AbstractArray ? [formatter(v) for v in values] :
                                                                       formatter(values)

# The filter path's shared re-raise (#411, #467). A formatter reports a value it cannot coerce as
# `InvalidValueError`, whose own docstring scopes it to the insert/update coercion helpers — on a
# READ that is the wrong bucket, so the filter path reports its own type instead. Anything else is
# someone else's error and is rethrown untouched.
#
# A function rather than a copy of the `catch` body, because it had exactly one copy and that is how
# #467 happened: `BETWEEN` formats its two operands in a branch of its own, and the arm that was not
# guarded kept leaking `InvalidValueError` for two releases while every sibling operator converted.
# One definition means the next operator branch cannot diverge by being written somewhere else.
#
# Since #576 it is the only re-raise on the FILTER path: the HAVING ladder (projection_types.jl), the
# `SQLTypeFunction` transform branches, the #474 memo arm, the `F(...)` operand
# (expression_render.jl) and the sargable rewrite all reach it, most of them through
# `_guarded_format` below. Before that, one of thirteen formatter call sites was guarded — see the
# count in that helper's comment.
#
# "Filter path", not "read path", and the difference is one pair of functions: `_m2m_format_owner` /
# `_m2m_format_related` (`many_to_many.jl`) call a field formatter unguarded, and the owner one is
# reached on a read via `manager.all()`. They are not guarded because their input is a row's own
# primary key, never a value the caller typed, so there is no wrong-typed value to report — but the
# claim is narrowed rather than left to mean more than it does.
#
# **Call it only from inside a `catch`.** The non-`InvalidValueError` arm is `rethrow(e)`, which is
# legal in a function only while a handler is dynamically in scope; called anywhere else it raises
# `"rethrow(exc) not allowed outside a catch block"` and masks the error it was handed. There are
# exactly two callers, both inside a `catch`: `_guarded_format` below and the sargable rewrite's
# bounds guard. (The `BETWEEN` arm was a third until #654 routed it through `_guarded_format`.)
#
# #971: a refused value raises `InvalidValueError` here as on a write, located by this funnel —
# filter, field and column type — and never quoting the value. It used to be re-raised as a
# `FilterError` ending in "Please check the value: <value>", which put the bound value (a password,
# a token) in a message an app may return to an HTTP client. `FilterError` stays for what is wrong
# with the filter's SHAPE — a lookup, an operator — not with a value.
# A label that is not a name — an `F` expression on the left of a comparison — is not printed: its
# `string` is a struct dump, operands included.
function _locate_filter_refusal(e, label, type_label; subject::AbstractString = "field")
  e isa InvalidValueError || rethrow(e)
  named = label isa AbstractString ? String(label) : label isa Symbol ? string(label) :
          # A CTE or `Joined` handle holds names only, so it is quoted as the caller wrote it.
          label isa CTEReference ? "CTE(\"$(label.name)\", \"$(label.path)\")" :
          label isa JoinedReference ? sprint(show, label) : nothing
  throw(subject == "field" && named !== nothing ?
          with_location(e; op = "filter", field = named, field_type = _opt_label(type_label)) :
        subject == "field" ?
          with_location(e; op = "filter on an expression", field_type = _opt_label(type_label)) :
          with_location(e; op = named === nothing ? "filter on a $(subject)" :
                                                    "filter on the `$(named)` $(subject)",
                        field_type = _opt_label(type_label)))
end

_opt_label(x) = x === nothing ? nothing : string(x)

# #576: the guarded form of the format step. `_locate_filter_refusal` above fixed the `catch`
# body; this fixes the `try`. #467 was never a missing message -- it was a branch that formatted
# where the guard was not, and the rest of them were still out there.
#
# The count, on one definition of "site" so the numbers reconcile: there were 13 `_format_filter_value`
# call sites on the read path (3 transform ladder, 1 `#474` memo arm, 7 HAVING, 1 `execution.jl`,
# 1 plain model field). Exactly ONE -- the plain-field arm -- sat inside a `try`. #576 routed the
# other 12 through here.
#
# One further site calls a formatter DIRECTLY rather than through `_format_filter_value`: the
# sargable rewrite guards a bounds computation rather than a formatter call (guarded by #576), and
# calls `_locate_filter_refusal` directly, so the message and the type check still have one
# definition. The `BETWEEN` arm was the other until #654 — its two operands now format here, as one
# iterable lookup, which is what keeps "bind neither until both succeed" (#467) true in both clauses.
#
# Both labels are arguments because the sites cannot agree on where they come from: a model field
# carries `.type`, a projection alias carries only its own spelling and whichever formatter the
# HAVING ladder resolved for it, and the transform ladder has an `FObject` with neither. `subject`
# names what the message is talking about, so an alias is not told it is a field.
_guarded_format(formatter, values, operator::AbstractString, label, type_label;
                subject::AbstractString = "field") =
  try
    _format_filter_value(formatter, values, operator)
  catch e
    _locate_filter_refusal(e, label, type_label; subject = subject)
  end

# #576: the type label for a site that has a formatter but no `PormGField` to read `.type` off.
# Every read-path coercion helper is named `format_<t>_sql` in `Models`, so what the value has to
# satisfy is RECOVERABLE from the formatter rather than guessed — `format_number_sql` -> "number".
#
# The `format_<t>` arm without the `_sql` suffix exists for `format_yyyy_mm`, the one formatter
# outside the convention. Falling through to the bare function name was the first cut and it put
# "is the type format_yyyy_mm" — an internal symbol — in a sentence a user reads; truthful and
# unreadable are not the same bar. `yyyy-mm` is what that formatter actually demands.
function _formatter_type_label(formatter)::String
  n = string(nameof(formatter))
  m = match(r"^format_(.+)_sql$", n)
  m === nothing || return replace(m.captures[1], '_' => ' ')
  m2 = match(r"^format_(.+)$", n)
  return m2 === nothing ? n : replace(m2.captures[1], '_' => '-')
end

# #576: message labels for a site whose column is a TRANSFORM rather than a field. The transform
# ladder has an `FObject`, which carries neither a `.type` nor the `field_name` local the `BETWEEN`
# arm uses, so both labels are recovered instead of invented: the name is the underlying column and
# the subject names the transform, so the message says which of the two — the column or the `__@`
# suffix on it — is being talked about.
#
# The COLUMN, not `_as`, and that ordering is the fix for a message that undercut this cluster's
# other half. `_as` holds the flattened spelling `happened__month` — without the `@` — which is
# exactly the dead spelling #619 exists to tell users does not work; a reader pasting it back got
# "requires '@' prefix". `fobj.column` is a live spelling in every case, including a joined path
# (`driverid__dob`). `_as` stays as the fallback for a node whose column is not a plain String.
function _transform_filter_labels(node, formatter)
  fobj = node isa SQLTypeField ? node.field : node
  name = (fobj.column isa AbstractString && !isempty(fobj.column)) ? fobj.column :
         fobj._as !== nothing                                      ? fobj._as :
         (node isa SQLTypeField && node._as !== nothing)           ? node._as :
                                                                     string(fobj.column)
  return (name, _formatter_type_label(formatter), "$(fobj.function_name) transform")
end

# The single renderer for `IN` / `NOT IN` (#411). Extracted so the WHERE path and the HAVING path
# cannot drift: `get_filter_query`'s aggregate-alias branch used to build its own
# `"$(field) $(operator) $(placeholder)"`, which produced `HAVING MAX(x) IN $1` on PostgreSQL and
# `HAVING MAX(x) IN ?, ?` on SQLite — no parentheses, no `= ANY`, a syntax error on both engines.
# That was invisible because nothing asserted on the rendered HAVING text.
#
# `column` is the already-rendered left-hand side; `placeholders` is whatever `add_parameter!`
# returned, which is dialect-dependent by design.
function _render_membership(column::AbstractString, operator::AbstractString, placeholders,
                            instruc::SQLInstruction)::String
  # An EMPTY membership list, handled before the dialect split because only one dialect breaks.
  # SQLite has no array type, so `add_parameter!` expands a vector into one `?` per element and binds
  # them individually — for an empty vector that is ZERO parameters and an empty placeholder string,
  # which rendered `IN ()`: a syntax error. PostgreSQL binds the whole vector as a single array
  # parameter and rendered a valid `= ANY($1)` over `'{}'` that simply never matches. One query, a
  # loud failure on one backend and correct behavior on the other.
  #
  # Render the constant the empty set means, so the two agree on BEHAVIOR — which is what the
  # PG/SQLite alignment rule actually requires; their SQL text already differs here, `IN (?, ?)`
  # against `= ANY($1)`. Nothing is a member of the empty set, and everything is not a member of it.
  # Django reaches the same truth value from the other end, raising `EmptyResultSet` so the query is
  # never sent; PormG has no such short-circuit and emits a predicate with the same meaning instead.
  #
  # Dropping `column` is safe because no filter-LHS renderer binds a parameter of its own — that is
  # the real invariant, not "an empty placeholder means nothing was bound", and it is what keeps the
  # parameter list in step. Registered joins live in `instruct.row_join`, not in the discarded string.
  if isempty(placeholders)
    return operator == "IN" ? "(1 = 0)" : "(1 = 1)"
  end
  if isa(placeholders, String)
    # One placeholder for the whole list: PostgreSQL bound it as a single array parameter.
    if instruc.connection isa PormGPostgres
      return string(column, " ", operator == "IN" ? "= ANY" : "<> ALL", "(", placeholders, ")")
    else
      return string(column, " ", operator, " (", placeholders, ")")
    end
  elseif isa(placeholders, AbstractArray)
    # SQLite and friends: one placeholder per element, so the list is spelled out.
    return string(column, " ", operator, " (", join(placeholders, ", "), ")")
  else
    # Internal invariant: add_parameter! only ever returns a String or a Vector of placeholders.
    error(_emsg("PormG internal error rendering $(operator): parameter placeholders must be a String or a Vector, got $(typeof(placeholders))."))
  end
end

# The render-time half of #596: a flat `Vector{UInt8}` is only a byte payload if the column can hold
# bytes.
#
# The parse ladder admits `"blob" => bytes` without knowing the field, because it cannot know it —
# `_check_filter` is handed only the pair, and `Q`/`Qor`/`When` reach it with no model at all. The
# field IS known here, at every arm that resolves one, so this is where the decision belongs.
#
# It must be called from EVERY arm, which is the mistake this helper exists to make hard to repeat:
# guarding only the base-model arm left `filter("eventid__n" => UInt8[1, 2])` — a joined path to an
# IntegerField — binding two parameters and comparing a column against the FIRST byte, silently.
# Measured: refused on the unpatched code, two markers with the guard on one arm only. A payload
# reaching `add_parameter!` as a bare `AbstractArray` expands to one marker per byte, so a missing
# guard is silent wrong data, not a loud failure.
#
# `f_meta === nothing` means the arm resolved no field, and then this fails CLOSED: nothing has
# proved the column holds bytes.
#
# Keyed on the field STRUCT via `_is_binary_field`, never on `f_meta.type` — `ImageField` and
# `FileField` also carry `type == "BLOB"` and hold no bytes (#296).
#
# The refusal is the funnel the parse ladder used, with the same `allowed` list, so a non-binary
# field reports the message it has always reported for an operator-less vector value.
#
# #28 widened it from bytes to every vector: a bare-path vector is now admitted at parse for any
# element type (`_vector_oper_from_suffix`), because an `ArrayField` compares one whole vector. So the
# same render-time decision covers both columns whose ONE value is a vector — a `BinaryField` given a
# flat `Vector{UInt8}`, and an `ArrayField` given any vector — and refuses the vector everywhere else,
# with the message the parse ladder gave before. Renamed from `_guard_scalar_bytes` for that reason.
function _guard_vector_equality(v::SQLTypeOper, f_meta, label::AbstractString)
  (v.operator == "=" && v.values isa AbstractVector) || return nothing
  (f_meta !== nothing && _is_array_field(f_meta)) && return nothing
  (v.values isa Vector{UInt8} && f_meta !== nothing && _is_binary_field(f_meta)) && return nothing
  _raise_invalid_filter_operator([String(label)], "vector", _VECTOR_VALUE_OPERATORS)
end
# Label-deriving form, for the arms that have no field name of their own to pass (the JSON-path
# lookup).
_guard_vector_equality(v::SQLTypeOper, f_meta) = _guard_vector_equality(v, f_meta, _filter_path_label(v))

# The path the user wrote, for an error message on an arm that has no field name of its own (the
# JSON-path lookup). Best effort: falls back to the rendered column.
function _filter_path_label(v::SQLTypeOper)
  isa(v.column, SQLTypeField) && isa(v.column.field, String) && return v.column.field
  k = memo_key(v.column)
  return k === nothing ? string(v.column) : k[2]
end

# Bind an already-FORMATTED value in the shape `_render_predicate` expects for `operator` (#654).
#
# Two operators do not fit "one value, one placeholder": `BETWEEN`/`NOT BETWEEN` bind their two
# operands as two parameters, in text order, and hand back the pair; `ISNULL` binds nothing and
# hands back its `Bool` polarity. Everything else is the ordinary single bind, with the wildcard
# decoration a `LIKE_WILDCARD_OPERATORS` value needs. Shared by the WHERE `BETWEEN` arm and the
# HAVING alias branch so the two clauses cannot bind a range differently — that divergence is the
# failure mode `_render_predicate` exists to remove, one step earlier.
function _bind_predicate_value(instruc::SQLInstruction, operator::AbstractString, formatted)
  if operator in ("BETWEEN", "NOT BETWEEN")
    return (add_parameter!(instruc, formatted[1]), add_parameter!(instruc, formatted[2]))
  elseif operator == "ISNULL"
    return formatted
  end
  return add_parameter!(instruc, formatted,
                        contains = operator in LIKE_WILDCARD_OPERATORS, operator = operator)
end

# #972: the binding half of the three transform arms of `_get_filter_query(::SQLTypeOper, …)`.
#
# They bound every value with one `add_parameter!`, so `"date__@year__@range" => [1990, 1999]`
# handed `_render_predicate` one placeholder where `BETWEEN` needs a pair, and `@isnull` handed it a
# placeholder where `ISNULL` needs its `Bool` — each refused as "X is not a supported operator".
# `_bind_predicate_value` is the shape the WHERE `BETWEEN` arm and the alias branch already share
# (#654), so the transform arms take it too.
#
# `@isnull` skips the formatter (#886). Its value is the `IS [NOT] NULL` polarity, already checked to
# be a `Bool` by `_check_fixed_shape_lookup`, not a value of the transform's type — formatting it
# sent `true` through `format_yyyy_mm` / `format_date_sql` and blamed the value, the one part of the
# filter that was right.
#
# `node` is the function the arm matched. `COUNT` reaches the two `PormGTypeField`-keyed arms through
# the internal `OP(Count(…), …)`, and `COUNT(…) IS NULL` can never match (an empty group counts 0), so
# it is refused here exactly as the alias branch refuses it (#654) — those arms were a refusal for
# every `@isnull` before #972, and stay one for this case.
function _bind_transform_value(instruc::SQLInstruction, v::SQLTypeOper, node::SQLTypeFunction,
                               formatter, label, type, subject)
  if v.operator == "ISNULL"
    node.function_name == "COUNT" && throw(FilterError(
      "The \e[31m@isnull\e[0m lookup can never match COUNT($(label)): COUNT never returns NULL — an empty " *
      "group counts 0. Compare it with 0 instead."))
    return v.values
  end
  formatted = _guarded_format(formatter, v.values, v.operator, label, type; subject = subject)
  return _bind_predicate_value(instruc, v.operator, formatted)
end

# The operator ladder every filter predicate renders through, whatever clause it lands in (#618).
#
# It used to be inlined at the tail of `_get_filter_query(::SQLTypeOper, …)` — the WHERE path — while
# the HAVING/projection-alias branch in `get_filter_query` (`build_filter.jl`) hand-rolled its own
# two-case version: `IN`/`NOT IN` through `_render_membership` (#411) and a bare
# `"$(field) $(operator) $(placeholder)"` for everything else. So a pattern lookup on an alias
# printed the LOOKUP NAME as a SQL token — `HAVING MAX("Tb"."name") istartswith $1` — which is a
# syntax error on both engines, and an operator no renderer knows at all was never refused there.
#
# The duplication is the cause, not the symptom: four defects have now landed in those ten lines
# (#411 the membership render, #576 the formatter choice, #618 this, #595 the memo reuse). One ladder
# with two call sites is what makes a fifth divergence unrepresentable, and it is why the extraction
# is the fix rather than a fourth patch. `_render_membership` above is the precedent — it was already
# shared by both clauses for exactly this reason.
#
# `column` is the already-rendered left-hand side (a quoted column, a transform expression, or a
# projection's aggregate text); `placeholders` is whatever `add_parameter!` returned, which is
# dialect-dependent by design. Neither is re-rendered here, and this function binds nothing — the
# caller owns the binding, including the `contains=` / `operator=` wildcard decoration a
# `LIKE_WILDCARD_OPERATORS` value needs.
#
# #654 finished the extraction. `BETWEEN`/`NOT BETWEEN` and `ISNULL` were served by WHERE arms that
# returned ABOVE this ladder, so the alias branch could not reach them and #618 refused them there.
# They are arms here now, with the two shapes that made them early returns stated as the argument:
# `BETWEEN` takes a 2-tuple of placeholders (`_bind_predicate_value`), and `ISNULL` takes the `Bool`
# polarity itself, because it binds nothing. Since #972 the transform arms bind through the same
# helper (`_bind_transform_value`), so `@range` and `@isnull` after a transform reach these arms
# too. `expression` is the caller's explicit licence to put a call under `IS NULL`, which `ISNULL`
# otherwise refuses (#197): the alias branch passes it for an aggregate projection (#654) and the
# WHERE path for a transform column (#972). It is never inferred from the column text.
function _render_predicate(column::AbstractString, operator::AbstractString, placeholders,
                           instruc::SQLInstruction; expression::Bool = false)::String
  if operator in ["=", ">", "<", ">=", "<=", "<>", "!="]
    return string(column, " ", operator, " ", placeholders)
  elseif operator in ["IN", "NOT IN"]
    return _render_membership(column, operator, placeholders, instruc)
  elseif operator in ("BETWEEN", "NOT BETWEEN") && placeholders isa Tuple{Any,Any}
    # #207: `nrange` renders NOT BETWEEN — the operator string carries it, so it is emitted verbatim.
    return string(column, " ", operator, " ", placeholders[1], " AND ", placeholders[2])
  elseif operator == "ISNULL" && placeholders isa Bool
    return ISNULL(column, placeholders; expression = expression)
  elseif operator in PATTERN_LOOKUP_OPERATORS
    @pormg_debug false
    # The `ESCAPE` clause an escaped pattern needs comes from these arms and the `%` from the
    # caller's `contains=`; the two halves are useless apart. The SQLite-refusing arms
    # (`*unaccent*`, and the regex four since #635) raise `BackendCapabilityError` from here, so an
    # alias filter reports the same capability error a WHERE filter does.
    return getfield(Dialect, Symbol(operator))(instruc.connection, column, placeholders)
  else
    throw(FilterError("Invalid filter operator: $(operator) is not a supported operator."))
  end
end

# #635: a filter whose RHS is a column or expression (`F`, a CTE column, `Joined`, `Case`/`When`)
# is not a bound value, so it used to skip `_render_predicate` and concatenate the operator as-is.
# For a comparison that is right, but a pattern lookup's operator is a `Dialect` name, not SQL:
# `"surname__@regex" => F("forename")` rendered `surname regex forename` on both engines — a server
# syntax error on PostgreSQL, and no `BackendCapabilityError` on SQLite. The verbatim-bound pattern
# lookups take their RHS as-is, so they dispatch through Dialect exactly as a bound value does.
#
# Nothing else reaches this with a column RHS: `_check_column_rhs_lookup` refuses the LIKE family and
# `@in`/`@nin` at parse (#811/#793), and `_check_fixed_shape_lookup` refuses `@range`/`@isnull` (#808).
# So the fallthrough is a comparison, and anything else fails CLOSED rather than concatenating an
# operator name into the SQL. That is the fail-safe for an operator node built past the parse
# ladder (`OP` is internal, #202). No public spelling reaches it, so no test pins it: a test would
# have to build the node by hand, past the API, which is the #596 fallback arm's rule too.
function _render_column_rhs(column::AbstractString, operator::AbstractString, rhs,
                            instruc::SQLInstruction)::String
  operator in VERBATIM_PATTERN_OPERATORS &&
    return _render_predicate(column, operator, rhs, instruc)
  operator in ("=", ">", "<", ">=", "<=", "<>", "!=") ||
    throw(FilterError("Invalid filter operator: $(operator) does not take a column expression."))
  return string(column, " ", operator, " ", rhs)
end

# #894 — the milliseconds a SQLite `DurationField` filter compares, or `nothing` for the text
# comparison every other filter makes. Ordering lookups only (`@gt`/`@gte`/`@lt`/`@lte`/`@range`/
# `@nrange`): the stored text orders wrongly at 100 hours and for negative values, while equality and
# membership are exact on the canonical text the writer stores (#891) and stay sargable on the column.
# A value that is not a duration keeps the text path, so the formatter raises what it always raised.
const _INTERVAL_ORDERING_LOOKUPS = (">", ">=", "<", "<=", "BETWEEN", "NOT BETWEEN")
function _is_sqlite_duration_column(v::SQLTypeOper, instruc::SQLInstruction)::Bool
  (instruc.connection isa PormGSQLite && v.operator in _INTERVAL_ORDERING_LOOKUPS) || return false
  (v.column isa SQLField && v.column.field isa String && _is_bare_column(v.column.field)) || return false
  field = get(instruc.object.model.fields, v.column.field, nothing)
  if field === nothing
    key = memo_key(v.column)   # a joined path's terminal field (#474); `nothing` for no name
    key === nothing || (field = memo_field(instruc, key))
  end
  return field isa Models.sDurationField
end
function _sqlite_duration_column_ms(v::SQLTypeOper, instruc::SQLInstruction)
  _is_sqlite_duration_column(v, instruc) || return nothing
  v.operator in ("BETWEEN", "NOT BETWEEN") && return _duration_values_ms(v.values)
  return _duration_value_ms(v.values)
end

# #894 — `filter("gap__@gt" => F("start_at") - F("date") - Hour(1))` over `"gap" => <interval>`: an
# interval alias compared with an expression rather than a value. The alias's own SQL is its
# `HH:MM:SS` text, so this compared two texts. Both sides render once here, each to its milliseconds
# where it has them; if only one does, that one is wrapped back into the interval text — exactly the
# text it would have printed — so the comparison is the text one it always was, with each side bound
# once. `nothing` for every other filter, which renders as before.
function _sqlite_interval_alias_comparison(v::SQLTypeOper, instruc::SQLInstruction)
  instruc.connection isa PormGSQLite || return nothing
  (v.values isa Union{FExpression,FObject} && v.operator in _INTERVAL_MS_PREDICATES) || return nothing
  # An ALIAS only: a model column projected under its own name (`values("lap")`) is a column, and
  # `_alias_filter_key` refuses model fields and every `__` path. A column's comparison stays in the
  # field-path arms below, which keep `==` on the stored text and the column-vs-column text compare.
  name = _alias_filter_key(v.column, instruc)
  name === nothing && return nothing
  source = _projected_interval_source(name, instruc)
  source === nothing && return nothing
  lhs, lhs_ms = _render_interval_ms(source.field, instruc; _as = source._as)
  rhs, rhs_ms = _on_join_right(() -> _render_interval_ms(v.values, instruc), instruc)   # #985: the right side
  if !(lhs_ms && rhs_ms)
    lhs_ms && (lhs = Dialect._sqlite_interval_text(lhs))
    rhs_ms && (rhs = Dialect._sqlite_interval_text(rhs))
  end
  return _render_column_rhs(lhs, v.operator, rhs, instruc)
end

# The field a filter's left-hand side names, and the path to report it by — a key of the model's own
# fields, or the terminal field of a joined path from the #474 memo. `(nothing, "")` when the operand
# is not a field. Read AFTER the column is rendered: rendering is what fills the memo.
function _operand_field(v::SQLTypeOper, instruc::SQLInstruction)
  v.column isa SQLField || return nothing, ""
  if v.column.field isa String && haskey(instruc.object.model.fields, v.column.field)
    return instruc.object.model.fields[v.column.field], v.column.field
  end
  f = memo_field(instruc, memo_key(v.column))
  return f === nothing ? (nothing, "") : (f, memo_key(v.column)[2])
end

# #28/#903: the kind of column a pattern lookup must read as TEXT, or `nothing` for one it reads as it
# is. Keyed on the formatter because that is the one piece of evidence a column and a projection alias
# share: a field carries it, and an alias over one resolves it (`_having_alias_formatter`) — the alias
# has no field to ask.
function _pattern_text_kind(formatter)::Union{Symbol,Nothing}
  # #28: an array has no one text to match — refused in `_pattern_operand`, never read as text.
  formatter isa Models.ArrayFormatter && return :array
  (formatter === Models.format_inet_sql || formatter === Models.format_inet_unpacked_sql) && return :inet
  formatter === Models.format_cidr_sql && return :cidr
  # #902: a UUID reads as its canonical lowercase hyphenated text — what SQLite stores and what
  # PostgreSQL prints. Django's PostgreSQL backend reads the same `::text`; its hyphen stripping
  # (`UUIDTextMixin`) is only for backends that store 32 hex digits, which PormG never does.
  formatter === Models.format_uuid_sql && return :uuid
  return nothing
end

# What such a column needs before its predicate renders. A pattern lookup reads the column's printed
# text (`Dialect._pattern_text_operand`), because PostgreSQL has no `LIKE` for `inet`, `cidr` or
# `uuid`. Everything else — `=`, `@in`, `@isnull`, the ordering lookups — compares the column itself,
# natively. On SQLite a UUID column already holds that text, and a network column cannot exist (the
# DDL that would create one is refused, `Dialect._refuse_specialized_sqlite_type`), so there the
# predicate is left as written.
function _pattern_operand(column::AbstractString, formatter, operator::AbstractString,
                          instruc::SQLInstruction; label::AbstractString = column)::String
  operator in PATTERN_LOOKUP_OPERATORS || return String(column)
  kind = _pattern_text_kind(formatter)
  kind === nothing && return String(column)
  # #28. Django spells array containment `contains`, and PormG's `@contains` is a LIKE. Reading the
  # array as text and matching a fragment of `{a,b}` would answer a different question than the one
  # either spelling asks, so it is refused — the `@jcontains` precedent: one operator, one meaning.
  if kind === :array
    # The index hint only where it is a valid spelling that reads text: after a slice a second
    # subscript is refused (`_render_array_subscript`), and an element of a number array has no LIKE.
    by_index = formatter.kind isa Union{CText, CVarChar} && !occursin(r"__[0-9]+_[0-9]+\z", label) ?
      ", or match one element's text by index, \"$(label)__0__@contains\" => \"…\"" : ""
    throw(FilterError(
      "Error in filter '$(label)': a pattern lookup (`@contains`, `@startswith`, `@regex`, …) matches " *
      "text, and this is an ArrayField. Test its elements with the array lookups instead: " *
      "\"$(label)__@acontains\" => [ … ] (it holds them all), `@overlap` (it holds any of them)$(by_index)."))
  end
  return Dialect._pattern_text_operand(instruc.connection, Val(kind), column)
end

# The formatter a filter value goes through. A pattern lookup's value is a FRAGMENT of an address
# (`"10.20."`, `"::ffff"`) or of a UUID (`"550e"`), which the column's strict formatter would refuse,
# so it binds as plain text — Django's `PatternLookup` skips the field's `get_prep_value` for the
# same reason. Every other column and lookup keeps its own formatter. The `formatter` arm serves a
# projection alias (#903), whose formatter may be `nothing` — a type the alias ladder cannot name.
_lookup_formatter(formatter, operator::AbstractString) =
  operator in PATTERN_LOOKUP_OPERATORS && _pattern_text_kind(formatter) !== nothing ? format_pattern_text_sql : formatter

# A pattern lookup's value on such a column: plain text, except a whole `UUID`, which is matched as
# the text the column reads as. `format_text_sql` alone refuses a `UUID` (#860, a text column is not
# a UUID column), and `"token__@contains" => uuid4()` worked on SQLite before #902.
format_pattern_text_sql(value::UUIDs.UUID) = Models.format_uuid_sql(value)
format_pattern_text_sql(value) = Models.format_text_sql(value)
_lookup_formatter(field::PormGField, operator::AbstractString) = _lookup_formatter(field.formatter, operator)

function _get_filter_query(v::SQLTypeOper, instruc::SQLInstruction)
  @pormg_debug false
  # #985: inside an ON clause a comparison renders its column as the LEFT side and its value, below,
  # through `_on_join_right`. Re-entered once under the new side; a no-op everywhere else.
  side = _join_side_change(instruc, :left)
  side === nothing || return with_scope(() -> _get_filter_query(v, instruc), instruc; join_side = side)
  # #352/#373: rewrite a non-sargable date-bucket comparison (to_char/EXTRACT on the column) into a
  # plain range/comparison directly on the column, so an index on the column — and the planner's
  # selectivity estimate — both apply. Covers joined paths as well as bare ones; see
  # _render_sargable_date_range and _resolve_bucket_column for scope.
  sargable = _render_sargable_date_range(v, instruc)
  sargable !== nothing && return sargable
  # #894: an interval alias compared with another expression, on SQLite. Both spellings reach here:
  # the top-level alias filter (`get_filter_query`) and `Q`/`Qor`.
  interval_comparison = _sqlite_interval_alias_comparison(v, instruc)
  interval_comparison === nothing || return interval_comparison
  # #907: the same alias compared with a duration VALUE, where only a `When` condition gets here — every
  # filter on an alias takes `_render_alias_predicate` first, which asks the same question.
  alias = _alias_filter_key(v.column, instruc)
  if alias !== nothing
    interval_comparison = _render_interval_alias_predicate(v, memo_key(:base, alias), instruc)
    interval_comparison === nothing || return interval_comparison
  end

  column = _get_filter_query(v.column, instruc)
  # #972: set by the three transform arms below, from the NODE they matched — the licence
  # `_render_predicate` needs to put a transform's call text under `IS [NOT] NULL` (#197 refuses
  # any `(` otherwise). Never inferred from `column`'s text.
  transform_lhs = false
  # #27: JSONB containment/overlap operators (@>, ?, ?|, ?&) — dedicated binding + PG-only render.
  if v.operator in JSON_CONTAINMENT_OPERATORS
    return _render_json_operator(v, column, instruc)
  end
  # #28: the array containment/overlap operators (@>, <@, &&) — the same shape as the JSON branch.
  if v.operator in ARRAY_CONTAINMENT_OPERATORS
    return _render_array_operator(v, column, instruc)
  end
  # #27: comparison against a JSON path lookup (payload__key). Resolving `column` above populated
  # json_lookup_paths; the dedicated branch binds the RHS as plain text (the generic path would run
  # the JSON formatter on the RHS and throw on plain strings) and applies the PG numeric cast for </>.
  # The `_as !== nothing` test this used to carry was redundant — `memo_key` answers `nothing` for an
  # unnamed expression and `memo_json_lookup` answers `false` for a `nothing` key.
  if isa(v.column, SQLTypeField) && memo_json_lookup(instruc, memo_key(v.column))
    return _render_json_lookup_comparison(v, column, instruc)
  end
  # #28: a network column. Here, once, so the model-field arm, the joined-path arm and a column RHS
  # all get it. #903: a `When` condition on a projection alias renders here too, and has no field —
  # the alias's formatter is what says it projects a network column.
  operand_field, operand_label = _operand_field(v, instruc)
  # #904: the network operators bind and render on their own, ahead of the pattern operand and every
  # value arm below — none of which knows their operand.
  v.operator in NETWORK_LOOKUP_OPERATORS &&
    return _render_network_operator(v, column, operand_field, operand_label, instruc)
  operand_formatter = operand_field !== nothing ? operand_field.formatter :
                      alias !== nothing ? _having_alias_formatter(memo_key(:base, alias), instruc) : nothing
  # The label is derived only for an array column — the one kind that refuses here and names a path.
  # `_filter_path_label` has no method for every column kind (an `F` transform), so it is not asked
  # for the others.
  column = _pattern_operand(column, operand_formatter, v.operator, instruc;
                            label = operand_formatter isa Models.ArrayFormatter ? _filter_path_label(v) : column)
  if isa(v.values, Union{SQLTypeF,SQLTypeCTE,SQLTypeJoined})
    @pormg_debug false
    # #894: a `DurationField` ordered against an `F` interval — another `DurationField`, a timestamp
    # difference — compares milliseconds on SQLite, as `F("time") < F(...)` does. The right side is
    # rendered once either way, to the same SQL `_get_filter_query` gives it when it has no
    # millisecond form, so the fallback keeps the text comparison with the same bindings.
    if v.values isa FExpression && v.operator in _ORDERING_OPERATIONS && _is_sqlite_duration_column(v, instruc)
      rhs, rhs_ms = _on_join_right(() -> _render_interval_ms(v.values, instruc), instruc)
      return _render_column_rhs(rhs_ms ? Dialect._sqlite_interval_ms(column) : column, v.operator, rhs, instruc)
    end
    # F expressions are safe since they reference model fields; a CTE handle (#444) is the same
    # thing scoped to a CTE — `filter("raceid" => CTE("r91", "raceid"))` is a column comparison,
    # never a bound value.
    placeholders = _on_join_right(() -> _get_filter_query(v.values, instruc), instruc)
    return _render_column_rhs(column, v.operator, placeholders, instruc)
  elseif isa(v.values, SQLTypeFunction)
    # Case/When and other SQL function expressions as filter RHS
    placeholders = _on_join_right(() -> _get_filter_query(v.values, instruc), instruc)
    return _render_column_rhs(column, v.operator, placeholders, instruc)
  elseif isa(v.values, SubqueryObject)
    # #926: a scalar subquery, `"grid" => Subquery(…)`. `column` rendered first, so its markers number
    # ahead of the subquery's — the text order (#586). The filter-position render: no #194 recording.
    return _render_column_rhs(column, v.operator,
                              _on_join_right(() -> _get_filter_query(v.values, instruc), instruc), instruc)
  elseif isa(v.column, SQLTypeField) && isa(v.column.field, SQLTypeFunction) && v.column.field.formatter !== nothing
    @pormg_debug false
    # #576: this is the arm `filter("happened__@month" => "abc")` lands in once the sargable rewrite
    # above has declined it, and it formatted outside any guard, so it reported the write path's
    # `InvalidValueError` on a read. Guarded now, like every sibling.
    _label, _type, _subject = _transform_filter_labels(v.column, v.column.field.formatter)
    # #596: a transform column is a bare path, so `date__@year => UInt8[1, 2]` reaches here as an
    # equality. No transform yields bytes, so this is always the refusal.
    #
    # This is the ONE of the three transform arms a public spelling reaches: the string forms
    # (`@year`, `@month`, `@yyyy_mm`, …) always attach a formatter (`functions.jl`), so they land
    # here. The two arms below need a function node with `formatter === nothing`, which no public
    # spelling produces — they carry the same guard as a fail-safe, and say so there.
    _guard_vector_equality(v, nothing, _label)
    # #618: the transform arms reach the `Dialect` dispatch below, so their SQL keyword and `ESCAPE`
    # clause were always right — but they bound the value with no `contains=` / `operator=`, so a
    # pattern lookup over a transform column got no `%` and no `escape_like_pattern`. That is the same
    # bind half as the HAVING/alias branch, so all three arms here take the two kwargs too — now
    # through `_bind_transform_value`, which also gives them `@isnull` and `@range` (#972).
    placeholders = _bind_transform_value(instruc, v, v.column.field, v.column.field.formatter, _label, _type, _subject)
    transform_lhs = true
  elseif isa(v.column, SQLTypeField) && isa(v.column.field, SQLTypeFunction) && haskey(PormGTypeField, v.column.field.function_name)
    # Through the same helper as the other sites (#411). These work today only because
    # `PormGTypeField` maps to `format_number_sql` / `format_text_sql` — the two formatters that
    # happen to carry an `AbstractArray` method, which is precisely the coincidence this issue is
    # about. Leaving them raw would keep that coincidence load-bearing.
    _fmt = getfield(Models, PormGTypeField[v.column.field.function_name])
    _label, _type, _subject = _transform_filter_labels(v.column, _fmt)   # #576
    _guard_vector_equality(v, nothing, _label)   # #596 — fail-safe; no public spelling reaches this arm
    placeholders = _bind_transform_value(instruc, v, v.column.field, _fmt, _label, _type, _subject)   # #618, #972
    transform_lhs = true
  elseif isa(v.column, SQLTypeFunction) && haskey(PormGTypeField, v.column.function_name)
    # Function with formatter
    @pormg_debug false
    # Through the same helper as the other sites (#411). These work today only because
    # `PormGTypeField` maps to `format_number_sql` / `format_text_sql` — the two formatters that
    # happen to carry an `AbstractArray` method, which is precisely the coincidence this issue is
    # about. Leaving them raw would keep that coincidence load-bearing.
    #
    # #862: the node's own `formatter=` wins over the table, as it does on every other path (the
    # wrapped arm above, `_expression_formatter`). Moot until #862 — the table keyed `TO_CHAR`, so a
    # `ToChar` never got here — but `ToChar(x, "YYYY-MM", formatter = format_yyyy_mm)` is `Y_M`, and
    # the table's `format_text_sql` would accept a value that formatter refuses. `MONTH(x)`, the one
    # internal caller (`Y_Q`/`Y_QUAD`), carries `format_number_sql`, the same as the table.
    _own = v.column isa FObject ? v.column.formatter : nothing
    _fmt = _own !== nothing ? _own : getfield(Models, PormGTypeField[v.column.function_name])
    _label, _type, _subject = _transform_filter_labels(v.column, _fmt)   # #576
    _guard_vector_equality(v, nothing, _label)   # #596 — fail-safe; no public spelling reaches this arm
    placeholders = _bind_transform_value(instruc, v, v.column, _fmt, _label, _type, _subject)   # #618, #972
    transform_lhs = true
  elseif isa(v.column, SQLTypeFunction)
    # #537 — a function column none of the branches above can bind. `OP(::SQLTypeFunction, …)` is a
    # constructor arm PormG itself relies on — `When(OP(MONTH(x), "<=", N))` builds `Y_Q` / `Y_QUAD`,
    # the `@yyyy_q` / `@yyyy_quad` labels (functions.jl; #579 moved that expansion off `@quarter` /
    # `@quadrimester`) — but only the `PormGTypeField` functions (EXTRACT, EXTRACT_DATE = `ToChar`, COUNT)
    # have a formatter this path can name. Every other function fell through to the `else` ladder
    # below and died reading `.field` off a node that has no such slot: a raw `FieldError`, outside
    # the #231 taxonomy. Refused HERE, ahead of any `.field` read, naming the two spellings that do
    # bind through a known formatter. Deliberately not a consumer arm: `OP` is internal (#202) and
    # the string-lookup forms are the public surface, so the fix does not grow a spelling users are
    # steered away from. An AGGREGATE or window column in a WHERE predicate is refused one level up
    # (`_guard_no_aggregate_predicate`, build_filter.jl) with the HAVING / CTE spelling, so what
    # reaches this branch is a scalar function — or a SELECT-side `When(OP(Sum(…)))`, which took the
    # same raw `FieldError` and now takes the same typed refusal.
    throw(QueryBuildError(
      "\e[4m\e[31mOP($(v.column.function_name)(…), …)\e[0m cannot bind a literal: only " *
      "$(join(sort!(collect(keys(PormGTypeField))), " / ")) function columns render through OP, in a " *
      "filter or inside a CASE/WHEN. For a filter on any other function, project it under an alias and " *
      "filter on the alias — \e[4m\e[32mvalues(\"total\" => Sum(\"qty\")); filter(\"total__@gt\" => 1)\e[0m " *
      "— or use the transform-suffix spelling \e[4m\e[32m\"seen__@month__@lte\" => 4\e[0m (#537)."))
  elseif isa(v.values, SQLObjectHandler)
    # Subqueries - these are safe since they're built through PormG.jl
    if !(v.operator in ["IN", "NOT IN"])
      @pormg_debug
      throw(FilterError("Invalid subquery filter on \"$(v.column.field)\": a queryset value requires a membership operator — use \"$(v.column.field)__@in\" => subquery or __@nin."))
    end
    _validate_membership_subquery(v)
    # #433: renders an inline WITH that binds into `:cte` while its text sits in the WHERE clause.
    _guard_no_nested_cte(v.values, "A membership filter (__@in / __@nin)")
    # #432: same nested-run reordering — the subquery renders inside this predicate's clause.
    nested_mark = nested_parameter_mark(instruc)
    placeholders = query(v.values, table_alias=instruc.table_alias, connection=instruc.connection, parameters=instruc.parameters, outer=instruc)
    reattach_parameters!(instruc, detach_nested_run!(instruc, nested_mark))
    # #586: `column` was rendered before the subquery, so its markers number ahead of the
    # subquery's — the text order. Re-rendering here would bind a composite LHS a second time.
    return string(column, " ", v.operator, " ($placeholders)")
  else
    @pormg_debug false
    # #586: the left-hand side is rendered EXACTLY ONCE, at the top of this function, and every arm
    # below reads `column`. A second `_get_select_query(v.column, …)` used to sit here — its string
    # discarded, its parameters kept — and for a composite transform (`@yyyy_q` expands to a
    # CONCAT/CASE binding nine operands) that bound the expansion twice for one copy of the text:
    # SQLite refused the statement, PostgreSQL's `$n` sequence had a nine-wide gap. The
    # `ISNULL`/`BETWEEN` arms re-rendered the column too, free only while the memo key was
    # non-`nothing`. `_render_membership` states the invariant this restores: no filter-LHS
    # renderer binds a parameter of its own.
    # #654: `ISNULL` and `BETWEEN` used to RETURN from here, rendering their own SQL above the
    # shared ladder — which is why the alias branch could not reach them. They only bind now, and
    # fall through to `_render_predicate` like every other operator.
    #
    # #894: a `DurationField` ordered against a duration compares its milliseconds on SQLite, as
    # `F("time") > Minute(2)` does (`_render_interval_left`). The column reference is repeated by the
    # parse, which is safe because it binds nothing.
    if (ms_values = _sqlite_duration_column_ms(v, instruc)) !== nothing
      return _render_predicate(Dialect._sqlite_interval_ms(column), v.operator,
                               _bind_predicate_value(instruc, v.operator, ms_values), instruc)
    end
    if v.operator == "ISNULL"
      placeholders = v.values   # the `Bool` polarity; `IS [NOT] NULL` binds nothing
      # #997: the year-qualified labels reach this arm rather than the transform arms above, because
      # their `Concat` node carries no formatter. They take the same `ISNULL` licence as the other
      # transform columns (#972), granted from the node and never from the text: only a label
      # built NULL-propagating (`Y_Q` / `Y_QUAD`) is NULL exactly when its date is.
      transform_lhs = _is_null_propagating_label(v.column)
    elseif v.operator in ("BETWEEN", "NOT BETWEEN")
      # #467: both operands format in ONE guard and neither binds until both succeed — the
      # iterable-lookup arm of `_format_filter_value` is what does that now.
      #
      # The joined-path arm is new with #654. A path that is not a key of `model.fields`
      # (`"driverid__dob__@range"`) used to bind both operands RAW — no formatter, so
      # `["x", "y"]` on a date column went to the database as two strings instead of refusing, and
      # a `Date` bound as a `Date` rather than as the text form its equality twin binds. It takes the
      # terminal field from the memo exactly as the joined-path equality arm below does (#474/#576).
      range_field, range_label = _operand_field(v, instruc)
      formatted = range_field === nothing ? v.values :
        _guarded_format(range_field.formatter, v.values, v.operator, range_label, range_field.type)
      placeholders = _bind_predicate_value(instruc, v.operator, formatted)
    elseif haskey(instruc.object.model.fields, v.column.field)
      # Does this operator take `%` decoration? `add_parameter!` then routes the value through
      # `_apply_like_wildcards`, which picks the shape from the same constants (#604).
      is_like_op = v.operator in LIKE_WILDCARD_OPERATORS
      _f_meta = instruc.object.model.fields[v.column.field]
      _guard_vector_equality(v, _f_meta, v.column.field)   # #596
      # #576: was a hand-written `try` whose `catch` carried the note below; it is now the shared
      # `_guarded_format`, which also moves `add_parameter!` OUT of the guard. That is what #467
      # said it wanted ("`add_parameter!` stays outside the new `try`") and what the `BETWEEN` arm
      # above already does — only the operand formatting is being converted, never the binding.
      placeholders = add_parameter!(instruc,
        _guarded_format(_lookup_formatter(_f_meta, v.operator), v.values, v.operator, v.column.field, _f_meta.type),
        contains=is_like_op, operator=v.operator)
      # Why the conversion exists at all, kept from #411's `catch` body:
      #
      # it used to string-match `"The date"` && `"is invalid"`. That fired for exactly one case —
      # `format_date_sql(::AbstractString)`, whose message is literally "The date $value is
      # invalid" — and for nothing else. The `format_date_sql` CATCH-ALL says "The date must be a
      # Date, DateTime, …", and no other field type's formatter mentions dates at all, so a
      # wrong-typed value on any non-Date field escaped as a raw `InvalidValueError`, whose own
      # docstring scopes it to the insert/update coercion helpers rather than to a filter.
      #
      # Widening it to a type check makes the filter path report its own house type consistently.
      # It is a deliberate behavior change, not a no-op: `filter("n" => "abc")` on an IntegerField
      # raises `FilterError` where it raised `InvalidValueError`. Both are `PormGError`.
      #
      # #467 brought `BETWEEN`/`NOT BETWEEN` onto the same helper; #576 brought the remaining 12
      # `_format_filter_value` sites, so every formatter call on the read path now reaches one
      # re-raise instead of one in thirteen doing so.
    elseif (_vc_field = memo_field(instruc, memo_key(v.column))) !== nothing # #474
      @pormg_debug false
      is_like_op = v.operator in LIKE_WILDCARD_OPERATORS
      _guard_vector_equality(v, _vc_field, memo_key(v.column)[2])   # #596: the joined-path twin
      # #576: unguarded, and CONFIRMED — this is the ordinary joined-path filter, not an exotic
      # one. Any FK traversal lands here, because `"driverid__dob"` is not a key of `model.fields`,
      # so `filter("driverid__dob" => "not-a-date")` reported `InvalidValueError` on what is
      # plausibly the most common wrong-typed filter a consuming app writes.
      #
      # The issue listed it as "suspected, no reproducing input found", and the first cut of this
      # fix repeated that label after probing only ALIAS reuse (`values("x" => …)` then
      # `filter("x" => …)`), which the field walk rejects earlier as `UnknownFieldError`. The
      # probe was wrong, not the arm. `_vc_field` is a real field, so no label is synthesised —
      # the memo key's second half is the path the user wrote.
      placeholders = add_parameter!(instruc,
        _guarded_format(_lookup_formatter(_vc_field, v.operator), v.values, v.operator,
                        memo_key(v.column)[2], _vc_field.type),
        contains=is_like_op, operator=v.operator)
    elseif isa(v.column, SQLTypeField)
      @pormg_debug false
      is_like_op = v.operator in LIKE_WILDCARD_OPERATORS
      # #596: this arm resolves no field, so it cannot prove the column holds bytes — and it binds
      # `v.values` RAW, which would send a payload to `add_parameter!(::AbstractArray)` and expand it
      # into one marker per byte. Fail closed by passing no field.
      #
      # NO TEST REACHES THIS CALL, and that is a statement about the arm, not a gap in coverage:
      # every spelling we could construct resolves through `model.fields` or the memo first, so the
      # review's mutation of this line left the whole #596 testset green while mutating either of the
      # other two call sites failed it loudly. Kept as a fail-safe rather than deleted because the arm
      # itself is a fallback whose reachability is not pinned by anything — if a future column kind
      # lands here, the silent expansion is what it would get. Do not "cover" it by reaching in past
      # the public API; if a real spelling is ever found, that is the test.
      _guard_vector_equality(v, nothing, string(v.column.field))
      placeholders = add_parameter!(instruc, v.values, contains=is_like_op, operator=v.operator)
    else
      @pormg_debug false
      throw(UnknownFieldError("Field \"$(v.column.field)\" not found in model $(instruc.object.model.name)"))
    end
  end

  # #618: the ladder lives in `_render_predicate` so the HAVING/alias branch renders through the
  # same one. Behavior here is unchanged, which is why the existing WHERE coverage is the
  # regression test for the extraction itself.
  return _render_predicate(column, v.operator, placeholders, instruc; expression = transform_lhs)
end
function _get_filter_query(q::SQLTypeQ, instruc::SQLInstruction)
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
function _get_filter_query(v::SQLTypeF, instruc::SQLInstruction)
  return _get_select_query(v, instruc)
end
