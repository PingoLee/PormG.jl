# Shared build helpers: `get_settings`, the `_check_function` walker over a function's arguments,
# and the CTE / joined-copy column retag. #130 moved the rest of this file into `filter_pairs.jl`,
# `field_resolution.jl`, `select_nodes.jl`, `filter_nodes.jl` and `filter_operators.jl`.

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
# #1004 — the `SQLField` for a path the caller wrote, already split on `__@`: the column, or the
# transform over it. The single constructor every `values`/`filter`/`order_by` parse goes through,
# because each of them used to restate `SQLField(_check_function(check), join(check, "__"))`, and
# that `join` is where the `@` was lost. `_as` keeps the `__` spelling — it is the output column name
# (`values("raceid__@year")` → `raceid__year`, as Django names it) — and a transform's memo name
# keeps the `@`, so it cannot share a memo entry with the plain path to the related `year`.
function _path_sqlfield(check::Vector{String})::SQLField
  return SQLField(_check_function(check), join(check, "__"), nothing, :base,
                  length(check) > 1 ? join(check, "__@") : nothing)
end
_path_sqlfield(check::AbstractVector{<:AbstractString}) = _path_sqlfield(String.(check))
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
  # #1004: the memo name moves with it, so `"ev__seen__@year"` and `CTE("ev", "seen__@year")` share
  # one key and neither shares it with the plain CTE path `seen__year`.
  field.memo_as === nothing || (field.memo_as = _cte_as(name, field.memo_as))
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
  field.memo_as === nothing || (field.memo_as = _joined_as(alias, field.memo_as))   # #1004, as above
  field.root = :joined
  return field
end
