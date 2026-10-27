# Rendering one item of the SELECT list (#130): the `_get_select_query` method per node type —
# values, fields, window functions and their OVER clause, `Case` / `When`, function bodies, CTE and
# joined-copy handles, scalar subqueries. `get_select_query` (`build_select.jl`) walks the list;
# this renders each item.

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
# #1130: MySQL has no `NULLS FIRST`/`NULLS LAST`, so every ordering term is emulated with the
# `(expr IS NULL)` key, and the shared renderer's one exit from it — a term holding a `?` with no
# separate flag render, printed bare so the value is not bound twice — would leave NULLs where MySQL
# puts them (first in ascending order), not where PormG's placement says. On SQLite that exit is only
# taken before 3.30; on MySQL it would be every such term, so it is refused here, before the shared
# arm. A projection ordered by its alias renders no `?` and keeps the placement.
function _order_term_sql(expr, orientation::AbstractString, placement::Symbol, conn::PormGMySQL;
                         null_flag::Union{Nothing,AbstractString} = nothing)
  null_flag === nothing && occursin('?', string(expr)) && throw(_capability_error(conn, :nulls_order,
    "Ordering by an expression that binds a value";
    why = "Project it under a name and order by that name instead, e.g. \e[32mvalues(\"key\" => <expression>)\e[0m " *
          "and \e[32morder_by(\"key\")\e[0m, which places NULLs with an `(key IS NULL)` sort key."))
  return invoke(_order_term_sql, Tuple{Any,AbstractString,Symbol,Any}, expr, orientation, placement, conn;
                null_flag = null_flag)
end

# #1130: the NULL sort key of an ORDER BY term printed as the projection named `name`, where a table the
# query reads has a column of that name (`get_order_query`): the projection's SQL as the SELECT list
# rendered it, with the values it bound bound again under `:order`, where the key's markers print. The
# text is reused rather than the node rendered again, so the key is the projection by construction, a
# path's join, a function's typed render and a literal's bind alike.
#
# Measured on MySQL 8.4: the key reads the projection for a column, an aggregate and a window, bound or
# not. Under DISTINCT, or GROUP BY, MySQL can also require the columns the key computes from to be
# projected or grouped, so a key over `position + 1`, a `CASE` or `LAG(position)` there is its error
# 3065 or 1055 (`RANK()` and an aggregate pass): loud, on that engine only, and left to it (#1087).
function _projection_null_key(name::AbstractString, instruc::SQLInstruction)::String
  for i in eachindex(instruc.select)
    isassigned(instruc.select, i) || continue
    value = instruc.select[i]
    _projection_output_name(value) == name || continue
    sql = value.field
    sql isa AbstractString || break
    copy_parameters_to!(instruc, :order, get(instruc.projection_params, name, Any[]))
    return String(sql)
  end
  throw(QueryBuildError("PormG internal error: order_by(\"$(name)\") names a projection whose SQL was not " *
                        "rendered. This is a PormG bug; please report it."))
end

# The column names of the tables in this statement's FROM clause: the base model's, each joined model's,
# and each joined CTE's projections. A joined model is found by its table among the models the base
# model reaches through its relations (forward and reverse, any depth, whatever module defines them),
# the `cjoin_on` targets, and the models of the base model's module.
#
# Read while ORDER BY renders (`get_order_query`), so it also counts the joins the statement adds after
# that point (#404 fixes that order): an `order_by` path a later term resolves, the relation paths a
# `cjoin_on` ON clause names, and the `cjoin`/`on()` paths. Each hop of such a path is walked without
# joining it. A column path's last segment is its column, never a join, even when it is a ForeignKey
# (`order_by("raceid__circuitid")` joins the race only); a `cjoin`/`on()` key is a join path, all hops.
function _from_column_names(object::SQLObject, instruc::SQLInstruction)::Set{String}
  tables = Set{String}([Models.model_table_name(object.model)])
  for rj in instruc.row_join
    hasproperty(rj, :b) && push!(tables, String(getproperty(rj, :b)))
  end
  column_hops(path) = (segs = split(String(first(split(lstrip(path, '-'), "__@"))), "__"); segs[1:end-1])
  hops = Iterators.flatten((
    (split(p, "__") for p in keys(object.custom_join)),
    (column_hops(p) for p in _projected_paths(object.order)),
    (segs[1:end-1] for segs in instruc.cjoin_on_paths)))
  for segs in hops
    model = object.model
    for (i, seg) in enumerate(segs)
      step = _relation_step(object, model, seg, i == 1)
      step === nothing && break
      model = step[2]
      push!(tables, Models.model_table_name(model))
    end
  end
  # A CTE a later term orders by is joined when that term renders: `order_by("br__surname")`, which
  # `_resolve_cte_string_paths!` has made a `CTEReference` before ORDER BY, `CTE("br", "surname")`, or
  # one read inside a window, a `Case` condition or a function. What this walk misses is caught after
  # every join exists (`_refuse_late_shadowed_null_key`), so a gap is a refusal, never a wrong order.
  _order_cte_names!(tables, object.order)
  candidates = PormGModel[object.model]
  for aj in values(object.alias_join)
    push!(tables, Models.model_table_name(aj.target))
    push!(candidates, aj.target)
  end
  mod = isdefined(object.model, :_module) ? object.model._module : nothing
  if mod isa Module
    for n in names(mod; all = true)
      isdefined(mod, n) && (m = getfield(mod, n)) isa PormGModel && push!(candidates, m)
    end
  end
  cols = Set{String}()
  seen = Base.IdSet{PormGModel}()
  while !isempty(candidates)
    m = pop!(candidates)
    m in seen && continue
    push!(seen, m)
    in_from = Models.model_table_name(m) in tables
    for (k, fld) in m.fields
      in_from && push!(cols, Models.field_db_column(fld, k))
      to = hasproperty(fld, :to) ? getproperty(fld, :to) : nothing
      to isa PormGModel && push!(candidates, to)
    end
    for rel in values(m.related_objects)
      for name in propertynames(rel)
        target = getproperty(rel, name)
        target isa PormGModel && push!(candidates, target)
      end
    end
  end
  for (name, cte) in object.ctes
    name in tables || continue
    for v in values(cte)
      v isa SQLObjectHandler || continue
      for p in v.object.values
        p isa SQLField && push!(cols, something(p.custom_as, p._as))
      end
    end
  end
  return cols
end

# The CTE names an `order_by` term reads, for `_from_column_names`: a `CTEReference` anywhere in it. A
# path into a CTE is one by then, inside a window or a `When` condition too (`_resolve_cte_string_paths!`).
_order_cte_names!(out::Set{String}, x::CTEReference) = (push!(out, x.name); out)
_order_cte_names!(out::Set{String}, x::Union{SQLOrder,SQLField}) = _order_cte_names!(out, x.field)
_order_cte_names!(out::Set{String}, x::FExpression) =
  (_order_cte_names!(out, x.field_name); _order_cte_names!(out, x.operand))
_order_cte_names!(out::Set{String}, x::FObject) =
  (_order_cte_names!(out, x.column); _order_cte_names!(out, collect(values(x.kwargs))))
_order_cte_names!(out::Set{String}, x::WindowFunction) =
  (_order_cte_names!(out, x.column); _order_cte_names!(out, x.over.partition_by);
   _order_cte_names!(out, x.over.order_by))
_order_cte_names!(out::Set{String}, x::OperObject) =
  (_order_cte_names!(out, x.column); _order_cte_names!(out, x.values))
_order_cte_names!(out::Set{String}, x::QObject) = _order_cte_names!(out, x.filters)
_order_cte_names!(out::Set{String}, x::QorObject) = _order_cte_names!(out, x.or)
_order_cte_names!(out::Set{String}, x::AbstractVector) = (foreach(v -> _order_cte_names!(out, v), x); out)
_order_cte_names!(out::Set{String}, ::Any) = out

# #1130: the check behind `_from_column_names`' look-ahead. `get_order_query` decides each alias term's
# NULL key while ORDER BY renders, before the `cjoin`/`on()` and `cjoin_on` joins exist; here, at the end
# of `build`, every join does. A term that kept its alias in the key (`instruc.alias_null_keys`) whose
# name a table of the statement does have as a column after all would place its NULLs by that column,
# so it is refused rather than run: a join the look-ahead did not foresee is a loud error, never a
# silent order.
function _refuse_late_shadowed_null_key(object::SQLObject, instruc::SQLInstruction)
  isempty(instruc.alias_null_keys) && return nothing
  columns = _from_column_names(object, instruc)
  for name in instruc.alias_null_keys
    name in columns || continue
    throw(QueryBuildError("order_by(\"$(name)\") orders by the projection named `$(name)`, and a table this " *
      "query reads has a column with that name. $(_backend_name(instruc.connection)) places NULLs with an " *
      "`($(name) IS NULL)` sort key and reads `$(name)` there as that column, and PormG could not tell in time " *
      "to key it on the projection. Project it under a name no column has, e.g. " *
      "\e[32mvalues(\"$(name)_value\" => …)\e[0m, and order by that."))
  end
  return nothing
end

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
    # Not a capability-table row: SQLite has window frames (3.25+); PormG does not render them there yet.
    instruc.connection isa PormGSQLite && throw(BackendCapabilityError(
      "frame = $(repr(frame)): PormG does not render explicit window frames on SQLite yet. Remove " *
      "frame= to use the default frame."))
    # #1130 phase 2c-3b: ROWS and RANGE render everywhere frames do; a GROUPS frame and an EXCLUDE
    # clause are each a capability-table row (MySQL has neither).
    conn = instruc.connection
    if conn !== nothing
      for (needed, feature) in ((Base.startswith(frame, "GROUPS"), :window_groups_frame),
                                (occursin(" EXCLUDE ", frame), :window_frame_exclusion))
        needed && !_supports(conn, feature) && throw(_capability_error(conn, feature, "frame = $(repr(frame))"))
      end
      frame = Dialect.engine_frame_sql(frame, conn)
    end
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
    _check_temporal_mix(v, instruc)   # #1200: the operand and its default, once both render
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
# as ambiguous and conservatively refuses. PostgreSQL and SQLite quote identifiers with double quotes,
# MySQL with backticks (#1130); each doubles its own quote inside a name.
function _extract_leading_alias(s)
  s isa AbstractString || return nothing
  m = match(r"^\"((?:[^\"]|\"\")+)\"\.(?:\"(?:[^\"]|\"\")+\"|\*)$", s)
  m === nothing || return replace(m.captures[1], "\"\"" => "\"")
  m = match(r"^`((?:[^`]|``)+)`\.(?:`(?:[^`]|``)+`|\*)$", s)
  m === nothing ? nothing : replace(m.captures[1], "``" => "`")
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
  (!_greatest_skips_nulls(instruc.connection) && v.function_name in ("GREATEST", "LEAST") &&
   v.column isa AbstractVector && length(v.column) >= 2) || return v.column
  cols = collect(Any, v.column)
  # `rotation_of` marks the rotations as this node's: the #1200 check reads the node, not each one.
  return Any[FObject(function_name = "COALESCE", column = circshift(cols, 1 - k),
                     aggregate = _any_agg(cols), kwargs = Dict{String,Any}("rotation_of" => v.function_name))
             for k in 1:length(cols)]
end

# #1028 — one operand rendered exactly as `_get_select_query` renders it — the same SQL, the same
# binds, in the same order — with the kind that render computed: `(sql, kind)`. Only two shapes keep a
# kind: `F` arithmetic (`_set_update_query_typed` is what `_get_select_query(::SQLTypeF)` renders
# through), and a function that renders as an interval (`_get_select_query(::SQLTypeFunction)`'s own
# arm). The `Concat`, `LPad`/`RPad` and declared-cast checks read it until #1304; they read the walk
# now, and the expression-kind matrix records it as its `render` channel, the render's own answer.
function _render_operand_kind(node, instruc::SQLInstruction; _as::Union{Nothing,String}=nothing)
  node isa FExpression && return _set_update_query_typed(node, instruc)
  if node isa FObject
    sql, interval_ms, interval = _render_function_typed(node, instruc; _as = _as)
    return (interval_ms ? _interval_ms_as_text(sql, instruc.connection) : sql), (interval ? CInterval() : nothing)
  end
  return _get_select_query(node, instruc; _as = _as), nothing
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

# #31: the full-text nodes, at the one site every function renders through as a value. On SQLite each
# is refused here, naming the outermost one the caller wrote, before any operand binds. A
# `SearchVector` or `SearchQuery` reaching this site is being used as a VALUE — projected, compared,
# wrapped in another function, or put in arithmetic — and is refused on every engine: neither a
# tsvector nor a tsquery has a Julia reading yet. Their three legitimate consumers (`@search`,
# `SearchRank`, `SearchHeadline`) render them through `_render_fts_operand`, which does not come here,
# so no spelling can smuggle one past the check the way a scope flag inherited by nested operands could.
const _FTS_FUNCTION_NAMES = Dict("SEARCH_VECTOR" => "SearchVector", "SEARCH_QUERY" => "SearchQuery",
                                 "SEARCH_RANK" => "SearchRank", "SEARCH_HEADLINE" => "SearchHeadline")
function _check_fts_render(v::SQLTypeFunction, instruc::SQLInstruction)
  name = get(_FTS_FUNCTION_NAMES, v.function_name, nothing)
  name === nothing && return nothing
  _supports(instruc.connection, :full_text_search) || throw(Dialect.fts_capability_error(instruc.connection, name))
  # #1021: a SearchVector may be PROJECTED under a name (`build_select.jl` renders it past this
  # check), so the message says what is left: comparing and wrapping.
  v.function_name == "SEARCH_VECTOR" && throw(QueryBuildError(
    "A SearchVector is an operand of the \e[4m\e[32m@search\e[0m lookup or SearchRank, not a value: " *
    "it cannot be compared or wrapped in another function. Project it under a " *
    "name and search that, \e[4m\e[32mvalues(\"doc\" => SearchVector(…)).filter(\"doc__@search\" => …)\e[0m, " *
    "or score rows with \e[4m\e[32mSearchRank(SearchVector(…), SearchQuery(…))\e[0m (#1021)."))
  v.function_name in _FTS_OPERANDS && throw(QueryBuildError(
    "A $(name) is an operand of the \e[4m\e[32m@search\e[0m lookup, SearchRank or SearchHeadline, " *
    "not a value: it cannot be projected, compared or wrapped in another function. Search a column " *
    "with \e[4m\e[32m\"surname__@search\" => SearchQuery(\"senna\")\e[0m, or score rows with " *
    "\e[4m\e[32mSearchRank(SearchVector(…), SearchQuery(…))\e[0m (#31)."))
  return nothing
end
# One operand of an FTS consumer: a `SearchVector`/`SearchQuery` renders its body directly, past the
# refusal above; anything else (the headline's document, its bound options) renders as a value.
_render_fts_operand(c, instruc::SQLInstruction; _as::Union{Nothing,String}=nothing) =
  _is_fts_operand(c) ? _render_function_body(c, instruc; _as = _as)[1] : _get_select_query(c, instruc; _as = _as)

function _get_select_query(v::SQLTypeFunction, instruc::SQLInstruction; _as::Union{Nothing,String}=nothing)
  sql, interval_ms, _ = _render_function_typed(v, instruc; _as = _as)
  # #894: an interval held in milliseconds leaves as the interval text, as a difference does (#881).
  return interval_ms ? _interval_ms_as_text(sql, instruc.connection) : sql
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
  _check_fts_render(v, instruc)
  _is_aggregate_call(v) || return _render_function_body(v, instruc; _as = _as)
  return with_scope(() -> _render_function_body(v, instruc; _as = _as), instruc; phase = :row)
end
# #955: which column types a date or time part reads. Before it nothing checked, so
# `"surname__@month"` built and failed (or matched nothing) only at the database, and `@hour` on a
# plain `DateField` answered `0` on SQLite while PostgreSQL refused the statement. Classified by the
# field's declared type, not its formatter: a `TimeField` formats as text, exactly as a `CharField` does.
function _temporal_kind(field)
  _is_date_field(field) && return :date
  _is_datetime_field(field) && return :datetime
  _is_time_field(field) && return :time
  _is_duration_field(field) && return :interval
  return :other
end
const _TEMPORAL_KIND_FIELDS = Dict(:date => "DateField", :datetime => "DateTimeField",
                                   :time => "TimeField", :interval => "DurationField",
                                   :timestamptz => "DateTimeField with a time zone (the default `TIMESTAMPTZ`)")
# A row reads `:timestamptz` when only a zoned timestamp will do (`EXTRACT(TIMEZONE …)`): PostgreSQL
# rejects it over a `DateTimeField(type = "TIMESTAMP")`, which is a `:datetime` all the same.
_temporal_reads(field, reads) = _temporal_kind(field) in reads ||
                                (:timestamptz in reads && getproperty(field, :type) == "TIMESTAMPTZ")

# A bare `F("col")` or `SQLField("col")` names a column as plainly as `"col"` does, so it is checked as
# that column. Anything with an operation is an expression, and stays unchecked (fail open).
_temporal_operand(x::FExpression) = x.operation === nothing ? _temporal_operand(x.column) : x
_temporal_operand(x::SQLField) = _temporal_operand(x.field)
_temporal_operand(x) = x

# #1068: the field a relation's value is. A `ForeignKey`/`OneToOneField` column holds the related
# row's key, so a date part reads THAT field's type: `raceid__@year` over an integer key is an
# `EXTRACT(YEAR FROM <integer>)`, which PostgreSQL refuses and SQLite answers from the text. A key
# that is itself a relation (a one-to-one primary key) is followed in turn. `nothing` — fail open —
# for a target PormG cannot resolve here; the join walk reports that one when it needs the model.
function _relation_key_field(field::PormGField, instruc::SQLInstruction)
  for _ in 1:8
    field isa Union{Models.sForeignKey, Models.sOneToOneField} || return field
    mod = instruc.object.model._module
    target = field.to isa PormGModel ? field.to :
             (field.to isa AbstractString && mod isa Module) ? Models._resolve_target_model(field.to, mod) :
             nothing
    target isa PormGModel || return nothing
    pk = field.pk_field === nothing ? Models.get_model_pk_field(target) : field.pk_field
    pk === nothing && return nothing
    field = get(target.fields, String(pk), nothing)
    field isa PormGField || return nothing
  end
  return nothing
end

# The temporal kind a date function's operand has, from the type walk (a column, a literal, an
# expression), for the engines that spell a part by it (MySQL's date arms in `Dialect`); `nothing` when
# the walk names no date or time.
_temporal_hint(::CDate) = :date
_temporal_hint(::CDateTime) = :datetime
_temporal_hint(::CTime) = :time
_temporal_hint(::CInterval) = :interval
_temporal_hint(::Any) = nothing

# Refuses a date/time node over a model field its part cannot read, naming both (#1070: by the part's
# row, so a public `Extract` is checked exactly as the `__@` transform that builds it). Fails OPEN,
# unlike `@len`: a column is checked by the field PormG names for it, and an operand with no field (an
# expression, a subquery, an untyped CTE column) only by `_check_temporal_expression`; what neither
# can type passes, because refusing it would refuse valid SQL. A relation is checked against the key
# it holds (#1068); a many-to-many has no column.
function _check_temporal_operand(v::FObject, instruc::SQLInstruction)
  found = _temporal_row_of(v)
  found === nothing && return nothing
  row, part = found
  column = _temporal_operand(v.column)
  declared = _alias_column_field(column, instruc)
  declared isa PormGField || return _check_temporal_expression(v, row, part, instruc)
  declared isa Models.sManyToManyField && return nothing
  field = _relation_key_field(declared, instruc)
  field isa PormGField || return nothing
  hasproperty(field, :type) || return nothing
  _temporal_reads(field, row.reads) && return nothing
  label = column isa AbstractString ? column : sprint(show, column)
  accepted = [_TEMPORAL_KIND_FIELDS[k] for k in row.reads]
  must = length(accepted) == 1 ? "a $(only(accepted))" :
         join(["a $(f)" for f in accepted], ", ", " or ")
  declared_as = field === declared ? "is declared as $(_field_label(field))" :
    "is a $(_field_label(declared)) whose value is the related key, declared as $(_field_label(field))"
  throw(QueryBuildError(
    "The \e[31m$(part)\e[0m part reads $(row.what), so its column must be $(must); " *
    "\e[31m$(label)\e[0m $(declared_as) (#1070)."))
end

# #1388: an operand with no field is checked by its kind from the type walk, for a calendar part only.
# A duration EXPRESSION — a timestamp difference, interval arithmetic, a `Sum` of a duration — has no
# calendar date on any engine, as a `DurationField` column has none (#1070). A clock part over one is
# not refused here: PostgreSQL reads the interval's components, and whether SQLite agrees is measured on
# #1388. MySQL refuses the clock parts on itself (`Dialect._mysql_part_of_interval_refusal`, #1324).
function _check_temporal_expression(v::FObject, row::_TemporalRow, part::String, instruc::SQLInstruction)
  row.reads == _CALENDAR_READS.reads || return nothing
  _expression_kind(v.column, instruc) isa CInterval || return nothing
  throw(Dialect._duration_calendar_refusal("The \e[31m$(part)\e[0m part"))
end

# #122: `LPad`/`RPad` pad text. PostgreSQL has no `lpad` over a number, a date, a time, a boolean, a
# uuid, a timestamp, an interval or a JSON document, nor one whose fill is any of those, and fails the
# statement — while SQLite's `pormg_lpad` pads whatever text the value converts to. So a typed operand
# or fill that is not text is refused on both engines. Fails OPEN, like `_check_transform_operand`: a
# value PormG cannot type passes (an untyped `Case`, a `Subquery` over a number, a relation whose
# target is not loaded).
#
# Text is an ALLOW list of formatters — `format_text_sql`, and `format_yyyy_mm` for the `@yyyy_mm`
# label, which renders `to_char`/`strftime` — so a typed value of any other kind is refused rather
# than reaching PostgreSQL. Three readings beside the formatter: a `TimeField` formats as text (see
# above) but is a `time`; a JSON key lookup (`"payload__driver"`) carries the JSONField's formatter but
# renders `#>>`/`json_extract`, which are text, so only a whole document is refused
# (`_json_document_operand`, Concat's rule); a relation is its target key's type, not the
# relation's (`"cc"` over a `CharField` primary key is text).
const _PAD_TEXT_FORMATTERS = (Models.format_text_sql, Models.format_yyyy_mm)

# The value's description when it is typed and not text, else `nothing`. A timestamp or an interval is
# named from the walk, as the `Concat` classifier names it (`_textless_temporal`, #1304): a column,
# temporal arithmetic, and a function over one. (Until #1304 it read the kind the operand's render
# computed, which named the arithmetic alone and left `Max("start_at")` to the formatter's "a non-text
# expression".)
function _pad_textless(operand, instruc::SQLInstruction)::Union{String,Nothing}
  if operand isa SQLText
    x = operand.field
    (_is_null_literal(x) || x isa AbstractString) && return nothing
    return "a literal of type $(nameof(typeof(x)))"   # never the value: it is a bound value (#971, #1057)
  end
  temporal = _textless_temporal(operand, instruc)
  temporal !== nothing && temporal[1] in (:timestamp, :interval) && return temporal[2]
  # A time of day formats as text, so the formatter cannot tell it from text; its kind can, through
  # the functions that keep their operand's (`Max("clock")`, `Coalesce`, a `Subquery`).
  time_kind = _expression_kind(operand, instruc) isa CTime
  formatter = _expression_formatter(operand, instruc)
  column = operand isa FExpression && operand.operation === nothing ? operand.field_name : operand
  column = column isa SQLField ? column.field : column
  field = _alias_column_field(column, instruc)
  relation = ""
  if field isa Models.sRelationalColumn
    target = field.to
    (target isa PormGModel && field.pk_field !== nothing) || return nothing
    relation = string(nameof(typeof(field)))[2:end]
    field = get(target.fields, String(field.pk_field), nothing)
    field isa PormGField || return nothing
    formatter = hasproperty(field, :formatter) ? field.formatter : nothing
  end
  formatter === nothing && return nothing
  formatter === Models.format_json_sql && !_json_document_operand(operand, instruc) && return nothing
  time_field = time_kind || (field isa PormGField && hasproperty(field, :type) && _is_time_field(field))
  formatter in _PAD_TEXT_FORMATTERS && !time_field && return nothing
  label = _concat_operand_label(operand)
  kind_name = field isa PormGField ? string(nameof(typeof(field))) : ""
  kind_name = Base.startswith(kind_name, "s") ? kind_name[2:end] : kind_name
  label === nothing && return time_field ? "a time of day" : "a non-text expression"
  isempty(relation) || return "the $(relation) `$(label)`, whose key is of type $(kind_name)"
  return isempty(kind_name) ? "`$(label)`" : "the $(kind_name) `$(label)`"
end

function _check_pad_operands(v::SQLTypeFunction, instruc::SQLInstruction)
  name = v.function_name == "LPAD" ? "LPad" : "RPad"
  for (i, slot) in ((1, "the value it pads"), (3, "its fill"))
    what = _pad_textless(v.column[i], instruc)
    what === nothing && continue
    advice = v.column[i] isa SQLText ?
      "Write the literal as a string: \e[4m\e[32mstring(x)\e[0m" :
      "Convert it to text first: \e[4m\e[32mCast(x, \"text\")\e[0m for an integer, a date, a time or a " *
      "uuid, \e[4m\e[32mToChar\e[0m for a timestamp, a \e[4m\e[32mCase\e[0m for a boolean; a float, a " *
      "decimal, an interval or a JSON document reads differently on each engine, so format it in Julia"
    throw(QueryBuildError(
      "\e[4m\e[31m$(name)\e[0m pads TEXT, and $(slot), $(what), is not text: PostgreSQL has no " *
      "$(lowercase(v.function_name)) over it. $(advice) (#122)."))
  end
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
  # #1356: an integer cast an engine guards names its operand more than once (`_integer_cast_guard`), so
  # the values the operand binds are read back from here and bound again for each further occurrence.
  # #1405: a declared `output_field` is the same cast over the whole function, whose values (a `Case`'s
  # `then`/`else` too, bound in Phase 3) are all bound after this mark.
  cast_marks = v.function_name == "CAST" || _declared_output_function(v) ?
    (parameter_mark(instruc), nested_parameter_mark(instruc)) : nothing
  fanout_column = nothing   # the operand as the #74 guard reads it: its column, not the parse of it
  if v isa FObject && v.function_name == "ABS" && _interval_as_ms(instruc.connection) && !(v.column isa AbstractVector)
    resolved_column, ms, operand_interval = _render_interval_operand(v.column, instruc; _as = _as)
    # #900: PostgreSQL has no `abs(interval)`, so the statement fails there when it runs. SQLite
    # computed the absolute value of the text's leading hours, silently. Refused, as `d * d` is (#881).
    # MySQL (#1130) would take it of the microseconds. #1324: the refusal is the one every number
    # function over a duration takes (`_operand_domain`), here because this arm renders the operand in
    # milliseconds before the check after Phase 3 would see it.
    (ms === nothing && !operand_interval) || throw(_duration_math_refusal("ABS", instruc.connection))
  elseif v isa FObject && _interval_ms_candidate(v)
    sqlite = _interval_as_ms(instruc.connection)
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
  elseif v.function_name in ("SEARCH_RANK", "SEARCH_HEADLINE") || _is_combined_fts(v)
    # #31: in text order — the vector or document, then the query, then the headline's options.
    # #1021: a sum of vectors renders its two halves the same way, left to right.
    resolved_column = Any[_render_fts_operand(c, instruc; _as = _as) for c in v.column]
  else
    # #1304: `Concat`, `LPad`/`RPad` and the declared casts render here too. They kept the kind their
    # operands' render computed, for the checks below, until #1034 step 5a/5c made the walk name the
    # same kinds (the render and the walk share one rule since step 5b) — the checks read the walk.
    resolved_column = _get_select_query(_null_skipping_operands(v, instruc), instruc, _as=_as)
  end
  # #942: the half of the `When` condition check construction could not do. Read after the condition
  # renders, so a joined path's field memo exists for `_expression_formatter` to find.
  if v.function_name == "WHEN" && v.column isa SQLTypeFunction && _function_condition_kind(v.column) === :unknown
    formatter = _expression_formatter(v.column, instruc)
    (formatter === nothing || formatter === Models.format_bool_sql) ||
      throw(_non_boolean_function_condition(v.column))
  end
  # #1021: the full-text nodes over a `SearchVectorField` column, read after their operands render (as
  # `@len` below is). `SearchRank` ranks one; `SearchVector` and `SearchHeadline` must not take one.
  v.function_name in ("SEARCH_RANK", "SEARCH_VECTOR", "SEARCH_HEADLINE") && _check_fts_column_operands(v, instruc)
  # #28: `@len` counts an array's elements, so its operand must be an `ArrayField` — a column, a
  # joined or CTE path, or a slice (`tags__0_2`), whose memo entry is the array field itself. Read
  # after the operand renders, like the check above: rendering a path is what fills the memo. Fails
  # closed — an operand whose type cannot be named (an expression) is refused too.
  v.function_name == "ARRAY_LEN" && !(_expression_formatter(v.column, instruc) isa Models.ArrayFormatter) &&
    throw(FilterError("The \e[31m@len\e[0m transform counts the elements of an ArrayField, and " *
                      "\e[31m$(_len_operand_label(v.column))\e[0m is not one."))
  # #955, #1070: a date or time part over a column of another type, whoever built the node. Read at
  # the same point as `@len` above, for the same reason, but it fails OPEN — see
  # `_check_temporal_operand`.
  v isa FObject && _check_temporal_operand(v, instruc)
  # #1027: a `Concat` operand that is not text — a boolean, a float or a decimal column, a timestamp,
  # or an expression of one — read once the operands render, as the checks around it are. A literal
  # was refused when the `Concat` was built. This is the one site every `Concat` renders through, the
  # `@yyyy_q` labels included (their operands are text and integers, so they pass).
  #
  # #1147 step 2: such an operand is explicit intent — the query does not say which text it means —
  # and is refused on every engine, naming the cast that says it. An integer quotient one engine
  # computes with a fraction is a question of meaning instead: refused only on that engine.
  if v.function_name == "CONCAT" && v.column isa AbstractVector
    for operand in v.column
      textless = _concat_textless_operand(operand, instruc)
      textless === nothing && continue
      if _meaning_kind(:concat, textless[1])
        row = _departure(instruc.connection, :concat, textless[1])
        row === nothing || throw(_meaning_refusal("Concat", textless[2], row, instruc.connection; flag = _concat_flag(operand)))
        continue
      end
      throw(_concat_textless_refusal(textless...; flag = _concat_flag(operand)))
    end
  end
  # #122: `LPad`/`RPad` over a typed operand that is not text, read at the same point.
  v.function_name in ("LPAD", "RPAD") && _check_pad_operands(v, instruc)
  # #1028: a declared cast — `Cast(x, CharField())`, `Cast(x, IntegerField())`, `Cast(x, "numeric(p,
  # s)")`, and the `output_field` cast `Coalesce`/`Greatest`/`Least` apply — over an operand on which
  # this engine departs from what the cast means (#1147 step 2). Read at the same point, so a `Concat`
  # over such a cast meets this refusal first, while its operand renders. Each operand's type is the
  # walk's, the same on every engine (#1304), so `Greatest`/`Least`, whose operands render on SQLite as
  # NULL-skipping `COALESCE` rotations, are read as their operands are written.
  if v.function_name in _DECLARED_CAST_FUNCTIONS && v isa FObject
    # #1147 step 2: only an operand on which this engine departs from the cast's meaning comes back.
    d = _cast_divergent_operand(v, instruc)
    d === nothing || throw(_meaning_refusal(_declared_cast_label(v), d.what, d.row, instruc.connection;
                                            flag = d.flag, declared = d.declared))
  end
  # #1061: `Round(x, d)` renders each engine's own `ROUND`, as Django does — `ROUND(x::numeric, d)` on
  # PostgreSQL, exact, and `ROUND(x, d)` over the stored double on SQLite, which can round a tie the
  # other way (`2.675` → `2.68` / `2.67`). That last-digit difference is documented, not refused. Text
  # is refused: PostgreSQL rejects text that is no number while SQLite reads it as 0, a different
  # value rather than a different last digit. The #1040 classifier names it (its `:text` kind, a JSON
  # value included); read here, after the operand renders, for the joined and CTE memos.
  #
  # #1044, #1167: a negative precision rounds to tens, hundreds, … — a capability, since SQLite's
  # `ROUND` has none and reads it as 0 (`Round(125, -1)` would answer `125.0`, not `130`). Refused on a
  # backend without the row, built on the others, as Django's `Round.as_sqlite` does.
  if v isa FObject && v.function_name == "ROUND"
    digits = get(v.kwargs, "precision", 0)
    if digits isa Integer && digits < 0 && !_supports(instruc.connection, :negative_round_precision)
      throw(_capability_error(instruc.connection, :negative_round_precision, "\e[31mRound(…, $(digits))\e[0m";
        why = "Fetch the value and round it in Julia: \e[32mround(x, RoundNearestTiesAway; digits = $(digits))\e[0m."))
    end
    if digits isa Integer && digits != 0
      # `Round` takes any `Integer` (`Int32`, `BigInt`); the classifier's scale is an `Int`. Only its
      # `:text` answer is read here: text is no number to round to tens either (#1167, a negative
      # precision built where the engine has it). It asks at the widest scale, which no number
      # exceeds, so a decimal or float branch ahead of a text one (`Coalesce("price", "surname")`)
      # does not answer first; the classifier only compares the scale.
      # #1387: a time renders through the text formatter, but it is a time, which the operand-domain
      # check after Phase 3 refuses with its own reason; so is a date, a timestamp or a UUID.
      divergent = _scale_divergent_operand(v.column, digits > 0 ? Int(digits) : typemax(Int), instruc)
      divergent !== nothing && divergent[1] === :text && !_non_number_operand(v.column, instruc) &&
        throw(_round_text_refusal(digits, divergent[2]))
    end
  end
  # #953: an aggregate over a boolean, read once its column resolves (as the check above is). An
  # extremum keeps its meaning — any true, all true — and each engine spells it (`Dialect.MAX`:
  # `BOOL_OR` where `max(boolean)` does not exist). A sum or mean turns a boolean into a number, which
  # the query does not say how to do: EXPLICIT INTENT (#1167), refused on every engine, pointing to the
  # explicit count.
  if v.function_name in ("MAX", "MIN", "SUM", "AVG") &&
     _expression_formatter(v.column, instruc) === Models.format_bool_sql
    v.function_name in ("SUM", "AVG") && throw(_boolean_sum_refusal(v))
    resolved_kwargs["boolean"] = true
  end
  # #1147: `Abs`/`Floor`/`Ceil` over an integer keep it, which `Dialect` renders where an engine would
  # not (PostgreSQL's `::numeric`). Read once the operand renders, as the checks above are; the walk's
  # `_computed_kind` answers the same kind from the same operand walk, so the SQL and the type agree.
  # #1196: so does `Round`, whose places add nothing to an integer: they are not bound, since the
  # engine that renders the integer itself (SQLite, `Dialect.ROUND`) has no slot for them. A NEGATIVE
  # precision does change an integer (`125` → `130`), so it stays bound (#1167); only an engine with
  # `:negative_round_precision` gets this far, and it renders `ROUND(x::numeric, d)` cast back.
  if v isa FObject && v.function_name in _INTEGER_KEEPING_FUNCTIONS && !(v.column isa AbstractVector)
    integer_kind = _integer_operand_kind(v, instruc)
    if integer_kind !== nothing
      resolved_kwargs["integer_kind"] = integer_kind
      places = get(v.kwargs, "precision", 0)
      if v.function_name == "ROUND" && !(places isa Integer && places < 0)
        delete!(deferred_kwargs, "precision")
        resolved_kwargs["precision"] = 0
      end
    elseif v.function_name == "ROUND" && _expression_kind(v.column, instruc) isa CDecimal
      # #1130: an engine whose `ROUND` rounds a double half to even (MySQL) rounds only a known decimal
      # as it is; `Dialect.ROUND` reads this, and the other engines ignore it.
      resolved_kwargs["decimal_operand"] = true
    end
  end
  # #1130: an engine whose date functions read a duration as no date (MySQL stores it as microseconds)
  # and a time's date as today's spells `Extract`'s EPOCH and refuses what has no meaning by the
  # operand's temporal kind; MySQL's date arms in `Dialect` read this, and the other engines ignore it.
  if v isa FObject && v.function_name in ("EXTRACT", "EXTRACT_DATE", "WEEK_DAY", "QUARTER", "QUADRIMESTER", "DATE")
    temporal = _temporal_hint(_expression_kind(v.column, instruc))
    temporal === nothing || (resolved_kwargs["temporal_kind"] = temporal)
  end
  # #1130 phase 2c-3b: an empty literal fill (`LPad(x, n, "")`) pads nothing, which an engine whose
  # pad answers `''` for it (MySQL) renders as the cut alone; `Dialect.LPAD` reads this.
  if v isa FObject && v.function_name in ("LPAD", "RPAD") && v.column isa AbstractVector &&
     length(v.column) == 3 && v.column[3] isa SQLText && v.column[3].field == ""
    resolved_kwargs["empty_fill"] = true
  end
  # #1150: `NullIf(a, b)` is `a` or NULL, so it has `a`'s type — but PostgreSQL resolves it with `b`
  # for the `=` it is defined by, so `NULLIF(<integer>, 0.5)` is a `numeric` there and keeps the half
  # once divided, where SQLite returns the integer. PostgreSQL renders it back to `a`'s integer type
  # (`Dialect.NULLIF`): exact, since the value is `a` itself. The walk's `:first_operand` rule says
  # the same type, so the SQL and the type agree.
  if v isa FObject && v.function_name == "NULLIF" && v.column isa AbstractVector && length(v.column) == 2
    integer_kind = _integer_operand_kind(v, instruc)
    if integer_kind !== nothing && _expression_kind(v.column[2], instruc) isa Union{CDecimal,CFloat64}
      resolved_kwargs["integer_kind"] = integer_kind
    end
  end
  # #1147 step 2: `Sum` over a `bigint` is an integer — Django's `Sum` of an integer field is one, and
  # SQLite sums one — but PostgreSQL widens `sum(bigint)` to `numeric`, which keeps the half once
  # divided. So PostgreSQL renders it back to the `bigint` (`Dialect.SUM`), read from the same walk
  # its `_computed_kind` answers, so the SQL and the type agree.
  if v isa FObject && v.function_name == "SUM" && _sums_bigint(v, instruc)
    resolved_kwargs["bigint"] = true
  end
  # #1130: on an engine whose sum of integers is a DECIMAL (MySQL), a `Sum` over an integer of any width
  # is turned back into the integer (`Dialect.SUM`: `x DIV 1`), and its `_computed_kind` answers it.
  if v isa FObject && v.function_name == "SUM" && _sums_integers_as_decimal(instruc.connection) &&
     _integer_operand_kind(v, instruc) !== nothing
    resolved_kwargs["integer"] = true
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

  # #1200: a value of one of several operands over two temporal types, or a temporal type and text,
  # refused on every engine. After Phase 3, so a `Case`'s rendered default has filled its memo.
  v isa FObject && _check_temporal_mix(v, instruc)
  # #1324: a number function over a duration, refused on every engine.
  v isa FObject && _check_operand_domain(v, instruc)
  # #1217: a `Case`'s `output_field` is the same declared cast as the four above, over its branch
  # values (`_cast_divergent_operand` reads them). After Phase 3 for the same reason as #1200.
  if _declared_case(v)
    d = _cast_divergent_operand(v, instruc)
    d === nothing || throw(_meaning_refusal(_declared_cast_label(v), d.what, d.row, instruc.connection;
                                            flag = d.flag, declared = d.declared))
  end
  # #1130: a value of several, or a declared type, over values whose MySQL form a plain render would
  # misread (an interval, which is its count of microseconds there; a boolean target, which MySQL casts
  # to no type). Decided by `_mysql_declared_output`, before any SQL: `nothing` everywhere else, and for
  # an undeclared function that passes its check, which renders as it always has.
  declared_sql = _mysql_declared_output(v, instruc)
  # #1356, #1405: an integer `Cast` or `output_field` this engine's own cast does not apply the range of.
  guard_type = declared_sql === nothing && cast_marks !== nothing &&
               (v.function_name != "CAST" || resolved_column isa AbstractString) ?
    _guarded_integer_type(v, instruc.connection) : nothing
  if declared_sql === nothing && guard_type === nothing
    sql = getfield(Dialect, Symbol(v.function_name))(resolved_column, resolved_kwargs, instruc.connection)
  else
    # The function with no declaration (`Cast`'s is the operand itself), handed to the decided form, or
    # to the integer guard, which casts it to the declared type itself.
    undeclared = copy(resolved_kwargs)
    delete!(undeclared, "output_field")
    x = v.function_name == "CAST" ? resolved_column :
        getfield(Dialect, Symbol(v.function_name))(resolved_column, undeclared, instruc.connection)
    sql = guard_type === nothing ? declared_sql(x) :
          _integer_cast_guard(x, guard_type, cast_marks, instruc, String(v.function_name))
  end
  # #900: PostgreSQL's `avg(interval)` is an interval; the milliseconds' mean is rounded to one, the
  # precision every SQLite interval has (#881).
  interval_ms && v.function_name == "AVG" && (sql = _interval_round_sql(sql, instruc.connection))
  return sql, interval_ms, interval
end
# #1405 — a `Coalesce`, `Greatest`, `Least` or `Case` that declares its `output_field`, which casts the
# whole function to it as `Cast` casts its operand. A NULL-skipping rotation (#844) declares nothing.
_declared_output_function(v::SQLTypeFunction)::Bool =
  v isa FObject && v.function_name in ("COALESCE", "GREATEST", "LEAST", "CASE") && !haskey(v.kwargs, "rotation_of") &&
  _declared_cast(v) isa AbstractString && !isempty(_declared_cast(v))

# #1356, #1405 — the integer type a `Cast` or a declared `output_field` names, where this engine's own cast
# does not apply that integer's range (`_guards_integer_cast`), or `nothing`: any other type, and an engine
# whose cast is the meaning.
function _guarded_integer_type(v::SQLTypeFunction, conn::_SQLEngine)::Union{String,Nothing}
  v isa FObject || return nothing
  type = _declared_cast(v)
  (type isa AbstractString && !isempty(type)) || return nothing
  bits = Dialect.integer_cast_bits(type)
  (bits === nothing || !_guards_integer_cast(conn, bits)) && return nothing
  return String(type)
end

# #1356 — `x` cast to the integer `type` (`_guarded_integer_type`) on an engine whose cast does not apply
# its range: the guard `Dialect.integer_cast_guard_sql` spells, which raises 22003 per row on a value
# outside it. `x` is `Cast`'s operand, or the function `fname` a declared `output_field` casts (#1405); the
# refusal names what the caller wrote, built from these two strings only when it is raised, so the render
# reads no untyped `kwargs` slot (#1346). The guard names `x` several times, and a positional backend binds
# a value once per marker, so the values `x` bound (`marks`, taken before it rendered) are bound again for
# each further occurrence, in text order — nothing binds between them. Fails closed when that cannot be done exactly:
# values bound in another clause's bucket, or a marker count that is not the number of values.
function _integer_cast_guard(x::AbstractString, type::AbstractString, marks::Tuple{ParameterMark,NestedMark},
                             instruc::SQLInstruction, fname::String)::String
  conn = instruc.connection
  bits = Dialect.integer_cast_bits(type)::Int
  sql, occurrences = Dialect.integer_cast_guard_sql(conn, x, bits)
  operand = bound_since(first(marks))
  before, now = last(marks), nested_parameter_mark(instruc)
  bound = (before === nothing || now === nothing) ? 0 : sum(now) - sum(before)
  if !(bound == length(operand) && count(==('?'), x) == length(operand))
    label = fname == "CAST" ? "Cast(…, \"$(type)\")" :
            "$(uppercasefirst(lowercase(fname)))(…; output_field = \"$(type)\")"
    throw(QueryBuildError(
      "$(label) cannot be rendered on $(_backend_name(conn)) over this operand: the cast to $(type) names it " *
      "more than once to apply the integer's range, and the values it binds cannot be bound again in step. " *
      "Cast a simpler expression, or compute the value before the cast."))
  end
  for _ in 2:occurrences
    reattach_parameters!(instruc, copy(operand))
  end
  return sql
end

# #1130 — a value of several (`Coalesce`, `Greatest`/`Least`, `NullIf`, a `Case`'s branches) or a declared
# type (`Cast(x, T)`, `output_field = T`) over values whose MySQL form a plain render would misread.
# Decided on the engine that departs (#1147), as a function of the undeclared SQL, or `nothing` for
# every other shape and on every other engine.
#
# Where the engine stores an interval as its count (`_stores_interval_as_units`, MySQL's microseconds):
# - an interval beside a value of another type (`Coalesce("fastestlaptime", 0)`) is refused, declared or
#   not: the one column would hold a count and a duration, and read the duration as its count. A NULL
#   is no value here. PostgreSQL has no common type for the two either;
# - an interval to text (or `uuid`'s `CHAR(36)`, or `json`): the `HH:MM:SS` text PormG writes, then the
#   cast (`json` then fails at the server, as PostgreSQL's cast of an interval does);
# - an interval to an interval (`DurationField()`): the count itself, which IS the interval there;
# - an interval to a date, a time, a timestamp or a boolean: refused, since the cast would read the
#   count's digits.
# Where the engine casts to no boolean type (`_normalizes_boolean_cast`, MySQL): a boolean target over
# booleans or integers is `((x) <> 0)`, NULL kept, as PostgreSQL's `integer::boolean` reads it; over any
# other value refused, since what MySQL would make of it (a text's leading digits) is no boolean.
const _ONE_OF_FUNCTIONS = ("COALESCE", "GREATEST", "LEAST", "NULLIF", "CASE")
const _ONE_OF_NAMES = Dict("COALESCE" => "Coalesce", "GREATEST" => "Greatest", "LEAST" => "Least",
                           "NULLIF" => "NullIf", "CASE" => "Case")
function _mysql_declared_output(v::FObject, instruc::SQLInstruction)::Union{Function,Nothing}
  conn = instruc.connection
  units = _stores_interval_as_units(conn)
  booleans = _normalizes_boolean_cast(conn)
  (units || booleans) || return nothing
  v.function_name in ("CAST", _ONE_OF_FUNCTIONS...) || return nothing
  # A NULL-skipping rotation (#844) is `Greatest`/`Least`'s own operand list: the function the caller
  # wrote checks its operands, and names itself.
  haskey(v.kwargs, "rotation_of") && return nothing
  values = v.function_name == "CASE" ? _case_values(v) : v.column isa AbstractVector ? v.column : Any[v.column]
  kinds = [_expression_kind(x, instruc) for x in values if !_is_null_operand(x)]
  engine = _backend_name(conn)
  interval = units && any(k -> k isa CInterval, kinds)
  label() = v.function_name == "CAST" || _declared_cast(v) isa AbstractString && !isempty(_declared_cast(v)) ?
            _declared_cast_label(v) : "$(_ONE_OF_NAMES[v.function_name])(…)"
  # #1321: an operand of another type the walk names is refused before this, on every engine
  # (`_check_temporal_mix`); what reaches it here is one the walk cannot type.
  interval && !all(k -> k isa CInterval, kinds) && throw(QueryBuildError(
    "$(label()) over an interval and a value of another type is not supported on $(engine): it stores an " *
    "interval as its count of microseconds, so one value cannot be both. Give every value the one type: " *
    "a duration beside a duration (Value(Second(0)) for a zero)."))
  declared = _declared_cast(v)
  (declared isa AbstractString && !isempty(declared)) || return nothing
  target_kind = _declared_kind(declared, conn)
  if interval
    target_kind isa CInterval && return identity
    target = target_kind isa CBool ? "BOOLEAN" :
             Dialect.cast_type_sql(declared, conn; context = v.function_name == "CAST" ? "Cast" : "output_field")
    (Base.startswith(target, "CHAR") || target == "JSON") &&
      return sql -> "CAST($(Dialect._mysql_interval_text(sql)) AS $(target))"
    if any(t -> Base.startswith(target, t), ("DATE", "TIME", "BOOLEAN"))
      # A date, a time, a timestamp or a boolean cast of the count reads its digits as one (`80500000` is
      # `8050:00:00`), where PostgreSQL refuses `interval::date` and `interval::boolean`, and reads
      # `interval::time` as a time of day. Refused on MySQL, the engine that departs, before any SQL.
      as_what = target == "BOOLEAN" ? "boolean" : Base.startswith(target, "DATETIME") ? "timestamp" :
                Base.startswith(target, "DATE") ? "date" : "time"
      throw(QueryBuildError("$(_declared_cast_label(v)) of an interval is not supported on $(engine): it " *
                            "stores an interval as its count of microseconds, whose digits the cast would read " *
                            "as a $(as_what). Compare or shift the interval instead: F(\"duration\") > Second(80), " *
                            "F(\"date\") + F(\"duration\")."))
    end
    return nothing
  end
  if booleans && target_kind isa CBool
    all(k -> k isa Union{CBool,CInt16,CInt32,CInt64}, kinds) || throw(QueryBuildError(
      "$(_declared_cast_label(v)) is not supported on $(engine) over a value that is not a boolean or an " *
      "integer: $(engine) has no boolean type to cast to, and PormG reads only those two as one there. " *
      "State the condition instead: Case(When(\"points__@gt\" => 0, then = true), default = false)."))
    return sql -> "(($(sql)) <> 0)"
  end
  return nothing
end

# #1021: a `SearchVectorField` column is a document, not text. `SearchRank`'s vector written as a path
# must be one — a text column would be cast to `tsvector` as a literal, not parsed. `SearchVector` and
# `SearchHeadline` cast their text operands to text: on a stored document that text is the lexeme list
# (`'grand':2 'prix':3`), which `to_tsvector` would parse again into different words. Read off the
# formatter, which a column, a joined path, a CTE path and an `F` over any of them all carry. An
# explicit `Cast(…, "text")` is the caller asking for that text, and is left alone.
function _check_fts_column_operands(v::SQLTypeFunction, instruc::SQLInstruction)
  stored(c) = c isa Union{AbstractString, SQLTypeF} && _expression_formatter(c, instruc) === Models.format_tsvector_sql
  if v.function_name == "SEARCH_RANK"
    c = v.column[1]
    (c isa AbstractString && !stored(c)) && throw(QueryBuildError(
      "SearchRank ranks a SearchVector(...), or a SearchVectorField column, and \e[31m$(c)\e[0m is not " *
      "one. To rank a text column, wrap it: SearchRank(SearchVector(\"$(c)\"), …) (#1021)."))
  elseif v.function_name == "SEARCH_VECTOR"
    # A sum's columns are its two vectors, never a column, so this loop finds nothing there.
    for c in v.column
      stored(c) && throw(QueryBuildError(
        "\e[31m$(_fts_operand_label(c))\e[0m is a SearchVectorField, already a document: SearchVector " *
        "would parse its lexemes again as text. Rank or search the column itself — " *
        "SearchRank(\"<column>\", …), \"<column>__@search\" (#1021)."))
    end
  elseif v.function_name == "SEARCH_HEADLINE"
    stored(v.column[1]) && throw(QueryBuildError(
      "SearchHeadline marks words in TEXT, and \e[31m$(_fts_operand_label(v.column[1]))\e[0m is a " *
      "SearchVectorField, a document of lexemes. Headline the text column it was built from (#1021)."))
  end
  return nothing
end

_fts_operand_label(c::AbstractString) = String(c)
_fts_operand_label(c::SQLTypeF) = c isa FExpression && c.field_name isa String ? "F(\"$(c.field_name)\")" : "this expression"
_fts_operand_label(::Any) = "this expression"

# The operand `@len` refused, as the caller spelled it (#28).
_len_operand_label(c::AbstractString) = String(c)
_len_operand_label(c::CTEReference) = "CTE(\"$(c.name)\", \"$(c.path)\")"
_len_operand_label(c::JoinedReference) = "Joined(\"$(c.alias)\", \"$(c.path)\")"
_len_operand_label(::Any) = "this expression"
function _get_select_query(q::SQLTypeQor, instruc::SQLInstruction; _as::Union{Nothing,String}=nothing)
  resp = []
  for v in q.or
    push!(resp, _or_arm(() -> _get_select_query(v, instruc, _as=_as), instruc))   # #1367
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
# The misbind is PormG's, not an engine's: values bind in bucket order, and a backend that binds by
# position (`?`) reads them in text order. Refused on EVERY engine for now (#1167), as a gap in PormG:
# firing it only where values bind by position is a follow-up, since the expression-kind matrix pins
# this refusal on both engines. The removal of the working PostgreSQL shapes is recorded in the
# upgrade log.
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
    "A nested CTE renders inside the subquery's parentheses, but PormG binds its values into the " *
    "\e[4m\e[31m:cte\e[0m parameter bucket, which is flattened ahead of \e[4m\e[31m:select\e[0m " *
    "and \e[4m\e[31m:where\e[0m — on a backend that binds parameters by position, ahead of any " *
    "value whose text comes first, silently matching the wrong rows.\n  " *
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
  has_limit = handler.object.limit !== nothing
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
function _get_select_query(q::SQLTypeF, instruc::SQLInstruction; _as::Union{Nothing,String}=nothing)
  return _set_update_query(q, instruc)
end
