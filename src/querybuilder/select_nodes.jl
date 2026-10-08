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
  instruc.connection isa PormGSQLite && throw(Dialect.fts_capability_error(name))
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
  _check_fts_render(v, instruc)
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
  elseif v.function_name in ("SEARCH_RANK", "SEARCH_HEADLINE") || _is_combined_fts(v)
    # #31: in text order — the vector or document, then the query, then the headline's options.
    # #1021: a sum of vectors renders its two halves the same way, left to right.
    resolved_column = Any[_render_fts_operand(c, instruc; _as = _as) for c in v.column]
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
# #1021: a `SearchVectorField` column is a document, not text. `SearchRank`'s vector written as a path
# must be one — a text column would be cast to `tsvector` as a literal, not parsed. `SearchVector` and
# `SearchHeadline` cast their text operands to text: on a stored document that text is the lexeme list
# (`'grand':2 'prix':3`), which `to_tsvector` would parse again into different words. Read off the
# formatter, which a column, a joined path and a CTE path all carry.
function _check_fts_column_operands(v::SQLTypeFunction, instruc::SQLInstruction)
  stored(c) = c isa AbstractString && _expression_formatter(c, instruc) === Models.format_tsvector_sql
  if v.function_name == "SEARCH_RANK"
    c = v.column[1]
    (c isa AbstractString && !stored(c)) && throw(QueryBuildError(
      "SearchRank ranks a SearchVector(...), or a SearchVectorField column, and \e[31m$(c)\e[0m is not " *
      "one. To rank a text column, wrap it: SearchRank(SearchVector(\"$(c)\"), …) (#1021)."))
  elseif v.function_name == "SEARCH_VECTOR" && !_is_combined_fts(v)
    for c in v.column
      stored(c) && throw(QueryBuildError(
        "\e[31m$(c)\e[0m is a SearchVectorField, already a document: SearchVector would parse its " *
        "lexemes again as text. Rank or search the column itself — SearchRank(\"$(c)\", …), " *
        "\"$(c)__@search\" (#1021)."))
    end
  elseif v.function_name == "SEARCH_HEADLINE"
    stored(v.column[1]) && throw(QueryBuildError(
      "SearchHeadline marks words in TEXT, and \e[31m$(v.column[1])\e[0m is a SearchVectorField, a " *
      "document of lexemes. Headline the text column it was built from (#1021)."))
  end
  return nothing
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
function _get_select_query(q::SQLTypeF, instruc::SQLInstruction; _as::Union{Nothing,String}=nothing)
  return _set_update_query(q, instruc)
end
