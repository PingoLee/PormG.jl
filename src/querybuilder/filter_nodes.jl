# Rendering one predicate (#130): the `_get_filter_query` method per node type — scalar subqueries,
# `Exists`, joined-copy and CTE handles, the field/operator methods — and its value side: running a
# right-hand side through the column's formatter, the refusal labels, membership lists, predicate
# binding and pattern operands. `get_filter_query` (`build_filter.jl`) walks the filter; this
# renders each node. The specialised lookup operators are `filter_operators.jl`'s.

# #926: the FILTER-position arm — `filter("grid" => Subquery(…))`, `F("grid") == Subquery(…)`, an ON
# pair, a `When` condition. Whether its correlation needs a grouped column is the #194 guard's call,
# from the phase of the clause it renders in (#932): WHERE and ON are evaluated before GROUP BY, HAVING
# and the SELECT list after. Its values bind into whatever clause bucket the caller switched to
# (`:where`, `:join`, `:having`), as the membership arm's subquery does.
function _get_filter_query(v::SubqueryObject, instruc::SQLInstruction)
  return _render_scalar_subquery(v, instruc)
end

# The render both arms share (the SELECT arm is in `select_nodes.jl`): `(SELECT …)` for exactly one
# projected column, its values bound as one
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
    # #1004: under the memo name, which for a transform keeps its `@` — see `get_select_query`.
    v_copy.field = _get_select_query(v_copy.field, instruc, _as=memo_name(v))
    # Never overwrite an existing entry (#404): the first render is the one every other reader
    # memoized against, and a fresh render of a binding node is not a better selector, only a
    # second binding.
    if key !== nothing && cached === nothing
      memo_projection!(instruc, key, v_copy)
    end
    return v_copy.field
  end
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
  # #31: full-text search — the same shape again, ahead of the JSON path and value arms below.
  if v.operator in SEARCH_LOOKUP_OPERATORS
    return _render_search_operator(v, column, instruc)
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
