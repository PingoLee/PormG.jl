"""
Set the field definitions from a CTE query to create temporary PormGField objects.
This allows the CTE to be treated like a table with queryable fields for JOINs.
"""
function _preset_cte_fields(cte_name::String, query::SQLObjectHandler;
  join_field::Union{Pair{String,String},Nothing}=nothing,
  join_type::String="LEFT")

  # `join_field === nothing` is intentional and supported (#44): the CTE is emitted but not
  # keyed to the main table via a fixed ON. When the main query then references a CTE column
  # with `F("<cte>__col")`, the CTE is CROSS JOINed and the F() filter supplies the correlation
  # in WHERE (see the CTE branch of `_build_row_join`). No `id=>id` default — that was a latent
  # trap that only worked when the model happened to carry an `id` column.
  table = CTEDict(
    "join_type" => join_type,
    "query" => deepcopy(query),
    "join_field" => join_field
  )

  return table
end

# #479 — the model whose physical table a CTE name would shadow, or `nothing`.
#
# SQL puts a statement's CTE names and its table names in ONE namespace, and the CTE wins: an
# unqualified `FROM "d_parent"` / `JOIN "d_parent"` anywhere in the primary query reads the CTE
# (PostgreSQL's SELECT reference: "the WITH query hides any real table of the same name"; measured
# on SQLite too). PormG generates its joins from `db_table`, unqualified, so a CTE named after a
# table turns every join it generates to that table into a read of the CTE — silently. Measured
# before this check, the two rows also collided in `_insert_join`'s dedup tuple (`row_join["b"]`
# holds the CTE name for a CTE row and the physical table for a model row), so only ONE join was
# emitted and `CTE(name, col)` read the physical column instead. Fixing the dedup alone would have
# emitted two joins that both read the CTE, and on SQLite a CTE body that reads its own name is a
# hard `circular reference` error where PostgreSQL silently reads the table — an engine divergence
# on top of the wrong rows. The only correct render would schema-qualify the physical table, which
# PormG cannot do: `db_table` is unqualified on purpose (#59) and resolves through the search path.
#
# So the name is refused at declaration, against every physical table PormG can render from the
# models it knows — the joined set is only known at render, and a statement that never joins the
# table loses nothing by picking another CTE name. "Knows" is every module `set_models` registered
# under the SAME path as the query's module (`Models.REGISTERED_MODULES`; a table in another
# database cannot be in this statement's namespace, so its modules are not walked), plus the
# modules of the two base models involved: a ForeignKey target may live in a module other than the
# query's own, and a review probe rendered exactly the issue's collapse through such a target when
# only `q.model._module` was walked. The same probe found the second hole: a many-to-many THROUGH
# table has no model binding at all — it is a string on the `ManyToManyRelation` — yet
# `_insert_many_to_many_joins` renders it unqualified like any other table, so those are collected
# from each model's m2m relations too. Two model files registered under two paths against ONE
# database (two apps in one process) with a ForeignKey across them is a legal shape, so the modules
# of each base model's direct relation targets are walked as well, whatever path they registered
# under — one hop, which is exactly what the statement can join from either base. A target two
# hops away in a third differently-registered module is not reached; a module never passed to
# `set_models` (hand-built models) is reached only as a base model's own or a direct target's.
#
# Cost, measured warm in review: ~1.2 ms per `.with()` for a two-model module, ~6 ms with four
# registered modules — a per-declaration cost, not per row. Memoizing the per-module table set in
# `set_models` would remove it and is the follow-up if it ever matters.
#
# Returns `nothing`, or a `(model, m2m_field)` pair: the model whose table (or whose m2m through
# table, when `m2m_field` is a field name) the CTE name would shadow.
function _cte_name_shadowed_model(name::String, q::SQLObject, query::SQLObjectHandler)::Union{Nothing,Tuple{PormGModel,Union{Nothing,String}}}
  modules = Module[]
  own_path = get(Models.REGISTERED_MODULES, q.model._module, nothing)
  same_db = own_path === nothing ? keys(Models.REGISTERED_MODULES) :
    (mod for (mod, path) in Models.REGISTERED_MODULES if path == own_path)
  for mod in (q.model._module, query.object.model._module, same_db...)
    mod isa Module && !(mod in modules) && push!(modules, mod)
  end
  # The direct ForeignKey / many-to-many targets of both base models, whichever path their module
  # registered under (or none). A String `to` is skipped ON PURPOSE — do not resolve it here: a
  # ForeignKey's String target is written back as a model by `resolve_fk_target!`, but a
  # ManyToManyField's stays a String, and by construction it resolves IN THE BASE MODULE (defined
  # there, or visible there through `using`), which `get_all_models(base._module)` already walks;
  # its through table sits on the base model's own m2m cache. Only a target reachable by direct
  # reference from another module is a `PormGModel` here, and that is the one to follow.
  for base in (q.model, query.object.model), (_, field) in base.fields
    hasproperty(field, :to) || continue
    to = getproperty(field, :to)
    to isa PormGModel && hasproperty(to, :_module) || continue
    mod = to._module
    mod isa Module && !(mod in modules) && push!(modules, mod)
  end
  candidates = PormGModel[q.model, query.object.model]
  for mod in modules, m in Models.get_all_models(mod)
    m isa PormGModel && !any(c === m for c in candidates) && push!(candidates, m)
  end
  for m in candidates
    Models.model_table_name(m) == name && return (m, nothing)
    # Forward m2m relations sit in the model's cache; reverse ones in `related_objects`. Both carry
    # the physical through table (#363).
    m2m = get(m.cache, "many_to_many", nothing)
    if m2m isa AbstractDict
      for (field_name, rel) in m2m
        rel isa Models.ManyToManyRelation && rel.through_table == name && return (m, String(field_name))
      end
    end
    for (accessor, rel) in m.related_objects
      rel isa Models.ManyToManyRelation && rel.through_table == name && return (m, String(accessor))
    end
  end
  return nothing
end

function _with(q::SQLObject, name::String, query::SQLObjectHandler;
  join_field::Union{Pair{String,String},Nothing}=nothing,
  join_type::String="LEFT")
  # #394: fail-closed on the CTE name HERE, at declaration. It is a query-time alias the caller typed,
  # and it reaches SQL twice — as the `WITH <name> AS (...)` label and, when a `join_field` is given,
  # as the JOIN target (`row_join["b"]`). Since #394 that second site quotes ESCAPE-ONLY, because
  # every other thing landing in that slot is a physical table name; checking here removes the
  # ordering dependency between the two renders entirely and puts the error on the call the user
  # wrote. `build_cte_clause` still quotes fail-closed as defence in depth. Same rule as `_cjoin_on`.
  _validate_identifier(name)
  # ...and the CTE side of the join key, for the same reason. `_build_row_join` stores it as
  # `row_join["key_b"]`, which since #394 is quoted escape-only because everything else in that slot
  # is a physical column. This one is a CTE PROJECTION ALIAS, so it belongs to the fail-closed half
  # of the contract. `join_field.first` is deliberately NOT checked: it names a field on the MAIN
  # model and is resolved through `Models.model_column`, i.e. it is genuinely physical.
  join_field !== nothing && _validate_identifier(join_field.second)
  # #479: a CTE name may not be a physical table name — see `_cte_name_shadowed_model`.
  shadowed = _cte_name_shadowed_model(name, q, query)
  if shadowed !== nothing
    model, m2m_field = shadowed
    what = m2m_field === nothing ?
      "the physical table of model $(model.name) (db_table \"$(Models.model_table_name(model))\")" :
      "the physical join table of $(model.name).$(m2m_field) (a many-to-many through table)"
    # The SQLite note is only true when the CTE body reads the shadowed table itself — which a
    # through-table hit never is (the body reads the owner model, not its join table).
    self_read = m2m_field === nothing && model === query.object.model ?
      " (and on SQLite a CTE body reading its own name is a circular reference)" : ""
    throw(QueryBuildError(
      "CTE name \"$(name)\" is $(what). SQL resolves an unqualified table reference to a " *
      "same-named CTE for the whole statement, so every join PormG generates to that table would " *
      "silently read the CTE instead$(self_read). Choose a CTE name that is not a table name."))
  end
  # #474: validate the join type HERE, for the same reason the two identifier checks above are here.
  # A keyed CTE's `join_type` was the one join-type slot with NO validation anywhere on its path:
  # `_preset_cte_fields` stored it verbatim, `_build_row_join` copied it into `row_join["how"]`, and
  # Phase 2 interpolated it straight into `"$(value["how"]) JOIN …"`. So `join_type = "CROSS"` built
  # `CROSS JOIN … ON …` (invalid on both engines), and an arbitrary string reached the SQL text
  # unquoted — measured: `join_type = "LEFT OUTER JOIN cj_grand AS injected ON 1=1 --"` rendered
  # that clause verbatim ahead of the CTE's own JOIN. `_normalize_join_type` also upcases and
  # strips, so a lowercase `"inner"` now works here as it already did in `on()` and `cjoin_on()`.
  # ...but only the KEYED arm of `_build_row_join` ever reads this value; an unkeyed CTE is
  # CROSS-joined by construction and hardcodes `row_join["how"]` itself. So `join_type = "CROSS"`
  # on an unkeyed `.with(...)` is a redundant statement of what already happens, and refusing it
  # would be absurd — the error would recommend the exact call the caller just wrote. Everything
  # else is still validated on both arms, so a typo is never silently swallowed.
  join_type = (join_field === nothing && uppercase(strip(join_type)) == "CROSS") ?
    "CROSS" : _normalize_join_type(join_type)
  cte_fields = _preset_cte_fields(name, query, join_field=join_field, join_type=join_type)
  if haskey(q.ctes, name)
    throw(QueryBuildError("CTE with name \"$(name)\" already exists in the query; please use a different name."))
  end
  @pormg_debug false
  q.ctes[name] = cte_fields
  return q
end
_with(o::SQLObjectHandler, name::String, query::SQLObjectHandler;
  join_field::Union{Pair{String,String},Nothing}=nothing,
  join_type::String="LEFT") = _with(o.object, name, query, join_field=join_field, join_type=join_type)

# Pair-accepting overload behind the fluent `.with("name" => subquery; join_field=...)`.
# The `Pair` first argument maps the CTE name to its sub-query handler; keyword arguments are
# forwarded to the `SQLObject` method above. No docstring on purpose (#305) — see the note on
# `_cjoin` below; the CTE guide is `docs/src/read/subqueries_and_ctes.md`.
function _with(o::SQLObjectHandler, pair::Pair{String,<:SQLObjectHandler};
  join_field::Union{Pair{String,String},Nothing}=nothing,
  join_type::String="LEFT")
  _with(o.object, pair.first, pair.second, join_field=join_field, join_type=join_type)
  return o
end



# Helper to recursively prefix and validate fields in cjoin filters.
# cjoin filters are ON-clause predicates, so they must target the joined model.
function _normalize_cjoin_filter_key(key::String, prefix::String, foreign_model::Union{PormGModel,Nothing})
  foreign_model === nothing && return key

  if startswith(key, prefix * "__")
    suffix = key[length(prefix) + 3:end]
    isempty(suffix) && throw(FilterError("Invalid cjoin filter field '$(key)' for join path '$(prefix)'. Provide a field on the joined model after the join path prefix."))

    base_field = String(split(suffix, "__")[1])
    if base_field in foreign_model.field_names || haskey(foreign_model.related_objects, base_field)
      return key
    end

    throw(FilterError("Invalid cjoin filter field '$(key)' for join path '$(prefix)'. The joined model '$(foreign_model.name)' does not contain the field or related path '$(base_field)'."))
  end

  base_field = String(split(key, "__")[1])
  if base_field in foreign_model.field_names || haskey(foreign_model.related_objects, base_field)
    return string(prefix, "__", key)
  end

  throw(FilterError("Invalid cjoin filter field '$(key)' for join path '$(prefix)'. cjoin filters modify the JOIN ON clause and must target fields on the joined model '$(foreign_model.name)'. Use a joined-model field like '$(prefix)__field' (or just 'field' for auto-prefixing), and keep base-query filters in .filter(...)."))
end

# #444 — a CTE column cannot appear in a JOIN's ON clause. Pre-#444 the same class was reachable by
# spelling `"<cte>__col"` inside `on`/`cjoin`/`cjoin_on`, and it was caught only downstream, by
# #424's CROSS-join guard, with a message about a name collision. Now the reference is typed, so
# refuse it where it is written, naming the clause the caller used.
function _reject_cte_in_join(ref::CTEReference, context::String)
  throw(FilterError(
    "\e[4m\e[31mCTE(\"$(ref.name)\", \"$(ref.path)\")\e[0m cannot be used in $(context). A JOIN's " *
    "ON clause targets the joined MODEL; a CTE is joined by its own \e[4m\e[32m.with(...)\e[0m " *
    "declaration (\e[4m\e[32mjoin_field=\e[0m keys it, \e[4m\e[32mjoin_type=\e[0m sets how).\n  " *
    "Put the predicate in \e[4m\e[32m.filter(...)\e[0m instead (#444)."))
end

# #481 — a joined-copy handle cannot appear in `on(...)` or `cjoin(...)`. Those clauses add
# predicates to a join PormG derives from a relation, and every reference in them is forced onto
# that single joined model (`_prefix_join_filter`); a `cjoin_on` alias names a different join
# entirely. It IS legal in `cjoin_on`'s own `on` list — that is the clause it was built for.
function _reject_joined_in_join(ref::JoinedReference, context::String)
  throw(FilterError(
    "\e[4m\e[31mJoined(\"$(ref.alias)\", \"$(ref.path)\")\e[0m cannot be used in $(context). That " *
    "clause adds predicates to a join derived from a relation, and every reference in it targets " *
    "that joined model; a \e[4m\e[32mcjoin_on\e[0m alias names a different join.\n  " *
    "Write the predicate in the \e[4m\e[32mcjoin_on(...; on = [...])\e[0m that declares the alias (#481)."))
end

# Recursive handle sweep for a filter element that has NOT been through `_prefix_join_filter`.
# `_cjoin_on` is the one such caller: it skips that helper on purpose, because the helper forces
# every reference onto a single joined model and `cjoin_on` must reference both sides.
#
# #481 made it generic over the handle type rather than duplicating the walk: `on()`/`cjoin()` refuse
# BOTH handle kinds, `cjoin_on` refuses only the CTE one. The two wrappers below name which.
_guard_no_cte_reference(filter, context::String, depth::Int = 0) =
  _guard_no_handle(filter, CTEReference, _reject_cte_in_join, context, depth)

# Both kinds, for `on()` / `cjoin()`.
function _guard_no_join_handles(filter, context::String, depth::Int = 0)
  _guard_no_handle(filter, CTEReference, _reject_cte_in_join, context, depth)
  _guard_no_handle(filter, JoinedReference, _reject_joined_in_join, context, depth)
  return nothing
end

function _guard_no_handle(filter, ::Type{T}, reject::Function, context::String, depth::Int = 0) where T
  # `Base.:(==)(f::FExpression, ::FExpression)` MUTATES `f` in place when `f.operation === nothing`,
  # so `f = F("x"); g = (f == f)` builds a genuine self-cycle (`g.operand === g`). Walking that
  # unbounded is a StackOverflowError — which Julia reports with "program state may be corrupted".
  # A depth cap is enough: no legitimate predicate nests anywhere near this deep, and stopping the
  # walk only means the guard declines to look further, never that it accepts something it saw.
  depth > 32 && return nothing
  if filter isa T
    reject(filter, context)
  elseif filter isa Pair
    # RECURSE into both sides rather than testing the handle type flatly. A pair's RHS is very often
    # an expression — `"sku" => (F("note") == CTE("ev","sku"))` — and a flat test walked straight past
    # it, letting the handle reach the ON clause after all. The rendered SQL was not merely on the
    # wrong join, it compared a varchar to a boolean:
    #   ON … AND "R1_1"."product_sku" = ("R1"."note" = "R1_2"."sku")
    _guard_no_handle(filter.first, T, reject, context, depth + 1)
    _guard_no_handle(filter.second, T, reject, context, depth + 1)
  elseif filter isa QObject
    for f in filter.filters; _guard_no_handle(f, T, reject, context, depth + 1); end
  elseif filter isa QorObject
    for f in filter.or; _guard_no_handle(f, T, reject, context, depth + 1); end
  elseif filter isa OperObject
    filter.column isa T && reject(filter.column, context)
    filter.column isa SQLField && filter.column.field isa T &&
      reject(filter.column.field, context)
    filter.values isa T && reject(filter.values, context)
    _guard_no_handle(filter.values, T, reject, context, depth + 1)
  elseif filter isa FExpression
    # #444: the comparison overloads (`F("sku") == CTE("ev","sku")`) put the handle in `.operand`,
    # and an `FExpression` is a `FilterType`, so `on`/`cjoin`/`cjoin_on` accept it as an element.
    # Without this arm the predicate was ACCEPTED and then resolved onto the CTE's own join instead
    # of the one the caller named — silently the wrong join, which is the whole defect class #444
    # exists to close. Every slot that can hold a handle is swept, including nested F expressions.
    # #481 added `field_name` as a slot a handle can occupy on its own account, since a joined
    # reference on the LEFT of a comparison lands there.
    filter.field_name isa T && reject(filter.field_name, context)
    filter.column     isa T && reject(filter.column, context)
    filter.operand    isa T && reject(filter.operand, context)
    _guard_no_handle(filter.field_name, T, reject, context, depth + 1)
    _guard_no_handle(filter.operand, T, reject, context, depth + 1)
  end
  return nothing
end

function _prefix_join_filter(filter, prefix::String, foreign_model::Union{PormGModel,Nothing})
  if filter isa Pair
    key = filter.first
    # Refuse BEFORE the `return filter` fall-through below: without this a CTE-keyed pair passes
    # through untouched and `_check_filter` — which since #444 resolves such a key — would build a
    # perfectly valid CTE predicate onto a join that cannot carry it.
    #
    # The sweep is RECURSIVE on both sides. A flat `isa CTEReference` test missed the common shape
    # `"sku" => (F("note") == CTE("ev","sku"))`, where the handle sits inside an F expression on the
    # RHS — accepted, then resolved onto the CTE's own join instead of the one the caller named.
    # #481: both handle kinds — a joined-copy reference names a `cjoin_on` join, not this one.
    _guard_no_join_handles(filter, "a join ON clause (on(...) / cjoin(...))")
    if key isa String
      return _normalize_cjoin_filter_key(key, prefix, foreign_model) => filter.second
    end
    return filter
  elseif filter isa QObject
    return QObject(filters=[_prefix_join_filter(f, prefix, foreign_model) for f in filter.filters])
  elseif filter isa QorObject
    return QorObject(or=[_prefix_join_filter(f, prefix, foreign_model) for f in filter.or])
  elseif filter isa OperObject
    new_oper = deepcopy(filter)

    # A `Q(...)`/`Qor(...)` element arrives here already converted, so the handle is inside the
    # OperObject rather than on a raw Pair. Same refusal, same reason (#444/#481).
    _guard_no_join_handles(new_oper, "a join ON clause (on(...) / cjoin(...))")

    if new_oper.column isa SQLField && new_oper.column.field isa String
      new_oper.column = SQLField(
        _normalize_cjoin_filter_key(new_oper.column.field, prefix, foreign_model),
        new_oper.column._as,
        new_oper.column.custom_as,
        new_oper.column.root   # #474: carry the namespace tag through the rewrite
      )
    elseif new_oper.column isa String
      new_oper.column = _normalize_cjoin_filter_key(new_oper.column, prefix, foreign_model)
    end

    if new_oper.values isa FExpression
      new_oper.values = _prefix_join_filter(new_oper.values, prefix, foreign_model)
    end

    return new_oper
  elseif filter isa FExpression
    # #444: sweep the F expression BEFORE prefixing. `F("sku") == CTE("ev","sku")` is a `FilterType`,
    # so `on()`/`cjoin()` accept it, and the arms below only rewrite `String` slots — a handle rode
    # through untouched and its predicate then resolved onto the CTE's join rather than the join the
    # caller named. Same refusal as a raw pair; the sweep walks the nested slots (#481: both kinds).
    _guard_no_join_handles(filter, "a join ON clause (on(...) / cjoin(...))")
    new_filter = deepcopy(filter)

    if new_filter.field_name isa String
      new_filter.field_name = _normalize_cjoin_filter_key(new_filter.field_name, prefix, foreign_model)
    elseif new_filter.field_name isa FExpression
      new_filter.field_name = _prefix_join_filter(new_filter.field_name, prefix, foreign_model)
    end

    if new_filter.column isa String
      new_filter.column = _normalize_cjoin_filter_key(new_filter.column, prefix, foreign_model)
    elseif new_filter.column isa Vector{String}
      new_filter.column = [_normalize_cjoin_filter_key(v, prefix, foreign_model) for v in new_filter.column]
    elseif new_filter.column isa SQLField && new_filter.column.field isa String
      new_filter.column = SQLField(
        _normalize_cjoin_filter_key(new_filter.column.field, prefix, foreign_model),
        new_filter.column._as,
        new_filter.column.custom_as,
        new_filter.column.root   # #474: carry the namespace tag through the rewrite
      )
    end

    if new_filter.operand isa FExpression
      new_filter.operand = _prefix_join_filter(new_filter.operand, prefix, foreign_model)
    end

    return new_filter
  else
    return filter
  end
end

function _collect_join_filters(filters)
  _filters::Vector{Union{Pair,SQLTypeQ,SQLTypeQor,SQLTypeOper,SQLTypeF}} = Vector{Union{Pair,SQLTypeQ,SQLTypeQor,SQLTypeOper,SQLTypeF}}()

  if filters === nothing
    return _filters
  elseif isa(filters, Union{Pair,SQLTypeQ,SQLTypeQor,SQLTypeOper,SQLTypeF})
    push!(_filters, filters)
  elseif isa(filters, Vector)
    for f in filters
      if isa(f, Union{Pair,SQLTypeQ,SQLTypeQor,SQLTypeOper,SQLTypeF})
        push!(_filters, f)
      else
        throw(FilterError("Invalid filter type in array: $(typeof(f)). Use Pair, Q, Qor, OP, or F expressions."))
      end
    end
  else
    throw(FilterError("Invalid filters type: $(typeof(filters)). Use a Pair, Q, Qor, OP, F expression, or an array of these."))
  end

  return _filters
end

function _resolve_join_target_model(q::SQLObject, join_path::String)
  parts = split(join_path, "__")
  isempty(parts) && throw(QueryBuildError("on() requires a non-empty join path."))

  current_model = q.model
  current_module = q.model._module

  for (index, part) in enumerate(parts)
    current_path = join(parts[1:index], "__")

    # #434 was here: `if index == 1 && haskey(q.ctes, part) throw(…) end`. It read the CTE registry
    # as it stood at `.on()` time, so `.with()` then `.on()` was refused while `.on()` then `.with()`
    # sailed past — order-dependent where every other fluent method is order-independent.
    #
    # #444 dissolves it rather than moving it. `join_path` is now unambiguously a FIELD path: a CTE
    # is reachable only through `CTE(name, path)`, which `on()` refuses outright (see
    # `_prefix_join_filter`). So a segment naming a CTE is simply a segment that is not a relation,
    # and the generic error below is both correct and order-independent. The CTE-aware hint lives
    # there, where it can be best-effort without any of this being conditional on it.

    field = if part in current_model.field_names
      current_model.fields[part]
    elseif index == 1 && _get_join_field(q, current_path) !== nothing
      _get_join_field(q, current_path)
    else
      nothing
    end

    if field !== nothing
      if !hasproperty(field, :to) || field.to === nothing
        throw(QueryBuildError("Join path '$(join_path)' stops at base field '$(part)', which is not a relation. Use .cjoin(..., field=...) first if this path depends on a custom link."))
      end

      current_model = field.to isa PormGModel ? field.to : getfield(current_module, Symbol(String(field.to)))
    elseif haskey(current_model.related_objects, part)
      related_value = current_model.related_objects[part]
      if related_value isa Models.ManyToManyRelation
        # ManyToMany reverse traversal in cjoin path: hop directly to the
        # related model, the through table is materialized later by the
        # query builder when emitting joins.
        current_model = getfield(current_module, Symbol(related_value.related_binding))
      else
        # #343: hop to the resolved child. This arm used to respell the binding as
        # `uppercasefirst(lowercased_name)` — the mirror of the M2M arm above, except that one reads
        # a STORED binding and therefore worked, while this one could not reach `Dim_CNES`.
        current_model = (related_value::Models.ReverseRelation).model_resolved
      end
    else
      # #434/#444: best-effort hint. Both `.on()`-then-`.with()` and `.with()`-then-`.on()` reach
      # this same throw with the same wording; only the parenthetical depends on whether the CTE has
      # been declared yet, and it adds information rather than deciding the outcome.
      hint = haskey(q.ctes, part) ?
        " ('$(part)' is a CTE declared on this query — on() targets model relations only; set a CTE's join type with with(..., join_type=...).)" : ""
      throw(QueryBuildError("Join path '$(join_path)' is invalid. The segment '$(part)' is not a relation on model '$(current_model.name)'.$(hint)"))
    end
  end

  return current_model
end

function _on(q::SQLObject, join_path::String, filters::AbstractVector; join_type::Union{String,Nothing}=nothing)
  target_model = _resolve_join_target_model(q, join_path)
  parsed_filters = Vector{FilterType}()

  for filter in filters
    prefixed = _prefix_join_filter(filter, join_path, target_model)

    if isa(prefixed, Pair)
      push!(parsed_filters, _check_filter(prefixed))
    elseif isa(prefixed, FilterType)
      push!(parsed_filters, prefixed)
    else
      throw(FilterError("Invalid filter type: $(typeof(prefixed)). Use Pair, Q, Qor, OP, or F expressions."))
    end
  end

  if isempty(parsed_filters) && join_type === nothing
    throw(QueryBuildError("on() requires at least one ON predicate or a join_type override."))
  end

  # #484: the PATH namespace only. A `cjoin_on` alias equal to this path lives in `q.alias_join` and
  # is untouched here, so `on("driver", …)` decorates the ForeignKey `driver`'s join whether or not
  # a `cjoin_on(alias = "driver")` was also declared, and in either declaration order.
  existing = get(q.custom_join, join_path, nothing)

  # #474: carry a join type ONLY when the caller passed one, here or on an earlier `on()` for this
  # path. It used to be written on every call, defaulting to `"LEFT"` when nobody supplied one — a
  # join type nobody wrote, applied to a join `on()` did not create. `_get_join_type_override` reads
  # it as an OVERRIDE, so the invented `"LEFT"` silently downgraded a relation PormG would otherwise
  # have typed itself. Measured on a NOT NULL ForeignKey: the same path renders `INNER JOIN` on its
  # own and `LEFT JOIN` the moment an `on()` predicate is added — different rows, no error.
  #
  # `nothing` is not a new shape: a `cjoin`-seeded entry has never carried one (`_cjoin` folds its
  # join type into `field.how`), so `_get_join_type_override` already had to answer `nothing` here.
  # With no override the join keeps `_determine_join_type`'s answer — `field.how`, else
  # `field.null ? "LEFT" : "INNER"` — including the `previus_how` LEFT-propagation a deep path
  # needs, which is knowledge this call site does not have and should not reproduce.
  #
  # An earlier explicit `join_type` still stands: a call with none carries the existing one forward.
  q.custom_join[join_path] = PathJoin(
    existing === nothing ? parsed_filters : vcat(existing.filters, parsed_filters),
    existing === nothing ? nothing : existing.field,
    join_type === nothing ? (existing === nothing ? nothing : existing.join_type) : _normalize_join_type(join_type))

  return q
end

# Concrete overload resolves the ambiguity with _on(::SQLObject, ::String, ::AbstractVector)
# that Aqua detects when q is a SQLObjectHandler (subtype matching is ambiguous otherwise).
function _on(q::SQLObjectHandler, join_path::String, filters::AbstractVector; join_type::Union{String,Nothing}=nothing)
  _on(q.object, join_path, filters; join_type=join_type)
  return q
end

function _on(q::SQLObjectHandler, join_path::String, args...; filters=nothing, join_type::Union{String,Nothing}=nothing)
  positional_filters = _collect_join_filters(collect(args))
  kw_filters = _collect_join_filters(filters)
  combined_filters = vcat(positional_filters, kw_filters)

  _on(q.object, join_path, combined_filters; join_type=join_type)
  return q
end


# Adds a custom join that does not have to follow the model's foreign-key relationships.
#
# No docstring on purpose (#305). The public surface is the fluent `.cjoin(...)`, whose contract
# lives on the `object` docstring's bullet and in `docs/src/api.md`; there is no user-facing binding
# here to attach docs to. The worked examples live in `docs/src/read/custom_joins.md`.
function _cjoin(
  q::SQLObject,
  main_join::Union{Pair{String,String},Nothing},
  filters::AbstractVector,
  field::Union{PormGField,Nothing},
  join_type::Union{String,Nothing},
  warn::Bool=true)

  # # Validations
  if main_join === nothing
    throw(QueryBuildError("Please, main_join argument is required to create a new join."))
  end

  # if field_destination !== nothing && !contains(field_destination, "__")
  #   throw(QueryBuildError("Invalid field_destination format: '$field_destination'. Expected format 'related_model__field'."))
  # end
  if (split(main_join.first, "__") |> length) > 1
    throw(QueryBuildError("That is not supported yet: main_join with related fields. Please, provide just the field name of the main model."))
  end

  @pormg_debug false
  if (split(main_join.first, "__") |> length) == 1 && main_join.first ∉ q.model.field_names
    throw(UnknownFieldError("The field '$(main_join.first)' is not a field in model '$(Models.model_table_name(q.model))'. The fields are: $(q.model.field_names)"))
  end

  # Validation: if field already exists as a FK on the model, ensure target model matches
  existing_field = q.model.fields[main_join.first]
  if hasproperty(existing_field, :to) && existing_field.to !== nothing
    # existing_field is a FK, extract its target model name
    existing_target = if isa(existing_field.to, PormGModel)
      existing_field.to.name
    elseif isa(existing_field.to, String)
      existing_field.to
    else
      nothing
    end

    # Compare case-insensitively since model names may be capitalized differently
    if existing_target !== nothing && lowercase(existing_target) != lowercase(main_join.second)
      throw(QueryBuildError("Field '$(main_join.first)' is already a ForeignKey pointing to '$(existing_target)', but cjoin attempted to join with '$(main_join.second)'. To add ON conditions to an existing FK, the target model must match. Use query.cjoin(\"$(main_join.first)\" => \"$(existing_target)\", filters=[...]) instead."))
    end
  end

  @pormg_debug false
  foreign_model::Union{PormGModel,Nothing} = nothing

  if field === nothing
    # No field provided, create a default PormGField for the join

    #   test_result = Models.ForeignKey(Result, pk_field="resultId", on_delete="CASCADE", null=true, related_name="test_deletion"),
    if !isdefined(q.model._module, main_join.second |> Symbol)
      throw(QueryBuildError("Model '$(main_join.second)' not found in module. Please remember that model names are case-sensitive."))
      return nothing
    end
    foreign_model = getfield(q.model._module, Symbol(main_join.second))
    @pormg_debug false
    pk_field = Models.get_model_pk_field(foreign_model)
    if !isa(pk_field, Symbol)
      throw(QueryBuildError("Foreign model '$(foreign_model.name)' does not have a valid/single primary key field."))
    end

    if warn
      @warn "cjoin auto-discovered join target primary key" join_field = main_join.first target_model = main_join.second auto_pk_field = String(pk_field) hint = "No explicit ForeignKey mapping was provided for this cjoin path. PormG will join main.$(main_join.first) -> $(main_join.second).$(pk_field). If this is not your intended link, pass field=Models.ForeignKey(<Model>, pk_field=your_target_field) in cjoin or use warn=false to suppress this warning."
    end

    field = Models.ForeignKey(
      foreign_model,
      pk_field=pk_field,
      on_delete="RESTRICT",
      null=true,
      # #420: deliberately NO `related_name`. This FK is synthesized at QUERY time and is never
      # registered as a reverse accessor — nothing reads the name back — but `related_name` is now
      # shape-validated at the constructor, so a synthetic value could fail that check for a string
      # the user never wrote and cannot change. It did: the old
      # `"$(q.model.name)_$(main_join.second)_join"` renders `tb__Circuit_join` for a model named
      # `tb_` (a trailing underscore is legal — `_validate_positional_model_name` rejects only mixed
      # case and a LEADING underscore), so `M.Tb_.objects.cjoin(...)` died with a definition error
      # from a read path.
      related_name=nothing,
      how=join_type
    )
  else
    if hasproperty(field, :to)
      field_to = getproperty(field, :to)
      if field_to isa PormGModel
        foreign_model = field_to
      elseif field_to isa String && isdefined(q.model._module, Symbol(field_to))
        foreign_model = getfield(q.model._module, Symbol(field_to))
      end
    end
  end

  # Parse filters into proper FilterType objects and apply recursive join-field prefixing.
  # This "mixing logic" ensures that keys in Q (AND) or Qor (OR) objects belonging to the 
  # joined model correctly map through the join path (e.g. "nationality" -> "driverid__nationality")
  # before being converted into OperObjects.
  parsed_filters = Vector{FilterType}()
  for filter in filters
    # Call recursive helper before converting pairs into full FilterTypes
    prefixed = _prefix_join_filter(filter, main_join.first, foreign_model)

    if isa(prefixed, Pair)
      push!(parsed_filters, _check_filter(prefixed))
    elseif isa(prefixed, FilterType)
      push!(parsed_filters, prefixed)
    else
      throw(FilterError("Invalid filter type: $(typeof(prefixed)). Use Pair, Q, Qor, OP, or F expressions."))
    end
  end


  # Store in the PATH namespace (#484). A `cjoin_on` alias spelled the same sits in `q.alias_join`
  # and does not trip this guard — before #484 it did, with a message naming a join path the caller
  # never declared.
  #
  # No join type of its own: `_cjoin` folded it into `field.how` above, which is why `PathJoin`'s
  # `join_type` (the `on(join_type = …)` override) stays `nothing` here.
  if !haskey(q.custom_join, main_join.first)
    q.custom_join[main_join.first] = PathJoin(parsed_filters, field, nothing)
  else
    throw(QueryBuildError("Join path '$(main_join.first)' already exists"))
  end


  return q
end

# Convenience function for ObjectHandler
function _cjoin(q::SQLObjectHandler, main_join::Union{Pair{String,String},Nothing}; kwargs...)
  accepted = Set([:filters, :field, :join_type, :warn])
  for k in keys(kwargs)
    if !(k in accepted)
      throw(QueryBuildError("Invalid keyword argument: \e[31m$k\e[0m. Accepted: \e[31m$(collect(accepted))\e[0m"))
    end
  end
  filters = get(kwargs, :filters, nothing)
  field = get(kwargs, :field, nothing)
  join_type = get(kwargs, :join_type, nothing)
  warn = get(kwargs, :warn, true)
  _filters = _collect_join_filters(filters)

  if field !== nothing && !isa(field, PormGField)
    throw(QueryBuildError("Invalid field type: $(typeof(field)). Use a PormGField or nothing."))
  end

  @pormg_debug false

  _cjoin(q.object, main_join, _filters, field, join_type, warn)
  return q
end
_cjoin(q::SQLObjectHandler; kwargs...) = _cjoin(q, nothing; kwargs...)

# #45 — anchor-less, full-control custom join.
#
# Unlike `cjoin` (which always emits `main.field = target.pk` and AND-appends joined-model-only
# filters), `cjoin_on` takes a target model, an explicit SQL alias for the joined copy, and an
# `on` list of arbitrary expressions that become the ENTIRE ON clause — no equi-anchor. This is
# what makes self-joins and cross-side predicates expressible without raw SQL.
#
# Reference convention inside `on`:
#   * bare `F("col")`            → the BASE/main table (b1)
#   * `Joined("<alias>", "col")` → the joined copy declared here (b2), #481
# A self-join is `_cjoin_on(q, "<BaseModelName>"; alias="b2", on=[...])`.
#
# #484 — the entry goes in `q.alias_join`, its own namespace, NOT in `q.custom_join` alongside the
# `cjoin` / `on()` PATH entries. Sharing one map is what made an alias equal to a ForeignKey field
# name unrepresentable-as-written: `_build_row_join` asked that map for the FK hop's config under
# the hop's path, found this entry, and folded the alias's whole ON clause into the FK's join. The
# alias is therefore refused only when it duplicates ANOTHER alias; it may equal a relation name, a
# `cjoin` path or an `on()` path, in any declaration order, and both joins are emitted under their
# own SQL aliases (they always did have different ones — the collision was only ever internal).
function _cjoin_on(q::SQLObject, target_model::String, on::AbstractVector; alias::String, join_type::Union{String,Nothing}="INNER")
  isempty(strip(target_model)) && throw(QueryBuildError("cjoin_on requires a target model name."))
  # Fail-closed identifier check on the user alias (it is interpolated into SQL as a quoted alias).
  _validate_identifier(alias)
  if !isdefined(q.model._module, Symbol(target_model))
    throw(QueryBuildError("cjoin_on target model '$(target_model)' not found in module. Model names are case-sensitive."))
  end
  if haskey(q.alias_join, alias)
    throw(QueryBuildError("cjoin_on alias '$(alias)' is already declared on this query. Choose a distinct alias."))
  end

  # Collect + validate element types. Crucially we DO NOT run `_prefix_join_filter` here: that helper
  # forces every reference onto the single joined model and rejects base-side references — the exact
  # opposite of what cjoin_on needs (it must reference both sides). `_check_filter` still converts a
  # Pair into an OperObject; the alias-qualified resolution happens at render time.
  parsed = Vector{FilterType}()
  for f in on
    # #444: `_prefix_join_filter` is deliberately skipped here (see the note above), so this loop
    # carries its own copy of that helper's CTE refusal. Without it a CTE handle would resolve into
    # a valid predicate on an ON clause that cannot carry it.
    _guard_no_cte_reference(f, "a cjoin_on `on` expression")
    if isa(f, Pair)
      push!(parsed, _check_filter(f))
    elseif isa(f, FilterType)
      push!(parsed, f)
    else
      throw(FilterError("Invalid cjoin_on `on` element: $(typeof(f)). Use Pair, Q, Qor, OP, or F expressions."))
    end
  end
  isempty(parsed) && throw(QueryBuildError("cjoin_on requires at least one `on` predicate."))

  # The target model is resolved HERE, once, rather than re-looked-up from a stored name at each of
  # the three render sites that need it (#484). `isdefined` was checked above, so this cannot throw.
  # The map key carries the alias and the map itself carries "anchor-less", so the old
  # `"user_alias"` / `"no_anchor"` tags have nothing left to say.
  q.alias_join[alias] = AliasJoin(
    getfield(q.model._module, Symbol(target_model))::PormGModel,
    parsed,
    join_type === nothing ? "INNER" : _normalize_join_type(join_type))
  return q
end

function _cjoin_on(q::SQLObjectHandler, target_model::String; alias::String, on::AbstractVector, join_type::Union{String,Nothing}="INNER")
  _cjoin_on(q.object, target_model, on; alias=alias, join_type=join_type)
  return q
end


"""
Build CTE (WITH clause) SQL string from the CTEs defined in the query object.

# Arguments
- `ctes::Dict{String, Dict{String, Union{SQLObjectHandler, PormGField}}}`: Dict of CTE name => fields dict
- `connection`: Database connection for quoting identifiers
- `parameters`: Parameterized query object to collect all parameters

# Returns
- String containing the WITH clause SQL, or empty string if no CTEs
"""
function build_cte_clause(ctes::Dict{String,CTEDict}, connection, parameters::Union{Nothing,AbstractPormGParam}, table_alias::Union{Nothing,SQLTableAlias})
  isempty(ctes) && return ""

  @pormg_debug false
  cte_parts = String[]
  for (cte_name, cte_fields) in ctes
    # Extract the query from the fields dict
    @pormg_debug false
    if !haskey(cte_fields, "query")
      @error "CTE '$cte_name' does not have a query" fields = keys(cte_fields)
      continue
    end

    cte_query = cte_fields["query"]

    # IMPORTANT: Set context to :cte for positional parameters (SQLite/MySQL)
    # This ensures parameters inside the CTE land in the correct bucket
    # and appear before main query parameters in the final SQL order.
    set_context!(parameters, :cte)

    # #432: a CTE BODY is a nested render too — the fourth one. Its own joins bind through the
    # ungated `set_context!(:join)` in `build_row_join_sql_text`, so a `.with(...)` whose body
    # carries a parameterized join scattered its values across `:cte` and `:join` while its whole
    # text sits inside the leading `WITH`. Measured before this: a CTE body with a `cjoin` ON filter
    # plus its own WHERE bound SQLite `["CTEWHERE", "CTEON"]` against a text order of
    # `CTEON, CTEWHERE`, because `:cte` flattens ahead of `:join`. Correct on PostgreSQL, silent
    # wrong rows on SQLite, and NOT refused by anything — a plain documented `.with(...)`.
    #
    # Same treatment as the other three sites: let the body file its values under its own clauses,
    # then lift them and re-emit as one clause-ordered run in `:cte`, where this text lives.
    nested_mark = nested_parameter_mark(parameters)

    # IMPORTANT: Pass the SAME parameters object so parameter numbering continues sequentially
    cte_sql = query(cte_query, table_alias=table_alias, connection=connection, parameters=parameters, cte=cte_fields, own_contexts=true)

    set_context!(parameters, :cte)
    reattach_parameters!(parameters, detach_nested_run!(parameters, nested_mark))

    @pormg_debug false

    # Quote the CTE name
    safe_cte_name = quote_identifier(cte_name, connection)

    # Add to CTE parts
    push!(cte_parts, "$safe_cte_name AS (\n  $cte_sql\n)")
  end

  return "WITH " * join(cte_parts, ",\n") * "\n"
end


"""
Infer the output PormGField type for a CASE/WHEN expression by inspecting
the `then` values from WHEN branches and the `default`/`else` value.

Returns IntegerField if all values are integers, FloatField if any are floats,
or CharField as a safe fallback for strings or mixed types.
"""
function _infer_case_output_type(func::SQLTypeFunction)
  output_values = Any[]

  # Collect `else`/default from the CASE kwargs
  if haskey(func.kwargs, "else") && !(func.kwargs["else"] isa Missing)
    push!(output_values, func.kwargs["else"])
  end

  # Collect `then` from each WHEN branch (stored in func.column for CASE)
  if func.column isa Vector
    for when_branch in func.column
      if hasproperty(when_branch, :kwargs) && haskey(when_branch.kwargs, "then")
        push!(output_values, when_branch.kwargs["then"])
      end
    end
  elseif func.function_name == "WHEN" && haskey(func.kwargs, "then")
    push!(output_values, func.kwargs["then"])
  end

  # Infer type from collected values
  if isempty(output_values)
    return CharField()  # no values to infer from, safest default
  elseif all(v -> v isa Integer, output_values)
    return IntegerField()
  elseif all(v -> v isa Number, output_values)
    return FloatField()
  elseif all(v -> v isa AbstractString, output_values)
    return CharField()
  else
    return CharField()  # mixed types, safest default
  end
end


function _set_field_from_sql_function(func::SQLTypeFunction, field::String, instruct::SQLInstruction)
  # CASE/WHEN: infer output type from `then` and `default`/`else` values
  if func.function_name in ["CASE", "WHEN"]
    return _infer_case_output_type(func)
  end

  if !(func.function_name in ["COUNT", "SUM", "AVG", "MIN", "MAX"])
    throw(QueryBuildError("Error in _set_field_from_sql_function, the function \e[4m\e[31m$(func.function_name)\e[0m is not a recognized function. Allowed: \e[4m\e[32mCOUNT, SUM, AVG, MIN, MAX, CASE, WHEN\e[0m"))
  end

  if func.function_name in ["COUNT", "SUM"]
    return IntegerField()
  else
    # For AVG/MIN/MAX: resolve the base column from func.column to determine the output type.
    # `field` is the alias (e.g. "points_avg"), but we need the actual model column (e.g. "round")
    base_col = if func.column isa String
      func.column
    elseif hasproperty(func.column, :field) && func.column.field isa String
      func.column.field
    elseif hasproperty(func.column, :_as) && func.column._as isa String
      func.column._as
    else
      field  # fallback to alias
    end

    @pormg_debug false

    fields = instruct.object.model.fields
    if haskey(fields, base_col)
      return fields[base_col]
    elseif haskey(fields, field)
      return fields[field]
    else
      throw(UnknownFieldError("Error in _set_field_from_sql_function, the field \e[4m\e[31m$(field)\e[0m (base column: \e[31m$(base_col)\e[0m) not found in \e[4m\e[32m$(instruct.object.model.name)\e[0m"))
    end
  end

end
# #481 — a CTE body that projects a joined-copy column. The body is its own build with its own
# `alias_join`, so the alias resolves against that inner query; without this method the projection
# reaches the `::String` method below as a `JoinedReference` and dies with a MethodError.
function _set_field_from_sql_function(func::JoinedReference, field::String, instruct::SQLInstruction)
  config = get(instruct.object.alias_join, func.alias, nothing)
  if config !== nothing
    haskey(config.target.fields, func.path) && return config.target.fields[func.path]
  end
  throw(UnknownFieldError(
    "Error in _set_field_from_sql_function, Joined(\"$(func.alias)\", \"$(func.path)\") names no " *
    "cjoin_on alias on this CTE body"))
end
function _set_field_from_sql_function(func::String, field::String, instruct::SQLInstruction)
  if haskey(instruct.tab_field_cache, (:base,field))
    # #474: the CTE BODY's own instruction, where an outer CTE cannot be referenced (#433) — so
    # this is unambiguously the base-model half of that inner build's namespace.
    return instruct.tab_field_cache[(:base,field)]
  elseif haskey(instruct.object.model.fields, field)
    return instruct.object.model.fields[field]
  else
    throw(UnknownFieldError("Error in _set_field_from_sql_function, the field \e[4m\e[31m$(field)\e[0m not found in \e[4m\e[32m$(instruct.object.model.name)\e[0m"))
  end
end

function _build_cte_custom_model(cte::CTEDict, instruct::SQLInstruction)
  values = instruct.object.values
  fields = Dict{String,PormGField}()
  selected_field_names = String[]
  @pormg_debug false
  for value_part in values
    # fields[value_part.field] = _set_field_from_sql_function(value_part.field, value_part._as, instruct)
    key_new = value_part.custom_as !== nothing ? value_part.custom_as : value_part._as
    try
      # #376: `key_new` is the alias `_query_select` renders for this column, and a CTE's columns
      # ARE its aliases — the physical name is consumed inside the body. So the field object that
      # TYPES this column must not carry the SOURCE table's db_column, or every outer reference
      # (`_solve_field`'s terminal column, the deep-path join key, the JSON-lookup base column, and
      # the #373 bucket-column drift guard) names a column the CTE does not expose. Fixing it HERE
      # rather than at those four reference sites is what keeps them branch-free — see
      # `Models.field_without_db_column` for the full reasoning.
      #
      # It rests on every CTE column having an alias `key_new` agrees with. Two ways a body could
      # render bare physical names, and neither reaches this loop:
      #   - `values("*")` — `_set_field_from_sql_function` raises UnknownFieldError on the field `*`.
      #   - no `.values()` at all — the body renders `SELECT *`, but `values` is then empty, so this
      #     loop produces a model with ZERO fields and every outer reference fails closed with
      #     UnknownFieldError. Fail-closed, not wrong SQL.
      # If a `SELECT "R1".*` projection is ever allowed inside a CTE it must be excluded from this
      # call, not folded into it.
      #
      # The `key_new` == rendered-alias correspondence does have one PRE-EXISTING hole, unrelated to
      # db_column and not introduced here: two `values()` entries sharing an `_as` collapse onto ONE
      # rendered ALIAS — `get_select_query` reuses the cached SQLField for the second entry, so the
      # body emits two columns under the same name — while this loop still registers both names. So
      # `values("id", "sku", "code" => "sku")` puts `code` on the model though the body emits `sku`
      # twice and no `code` at all. It reproduces identically with no db_column anywhere.
      fields[key_new] = Models.field_without_db_column(
        _set_field_from_sql_function(value_part.field, value_part._as, instruct))
      push!(selected_field_names, key_new)
    catch e
      @pormg_debug false
      throw(e)
    end
  end
  @pormg_debug false

  cte["model"] = Models.Model_Type(
    name = "",
    fields = fields,
    field_names = selected_field_names,
    _module = instruct.object.model._module,
    connect_key = instruct.object.model.connect_key
  )

end