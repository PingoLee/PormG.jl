# Join conditions (#977): what a condition in `on(path, …)` / `cjoin(filters = …)` refers to.
#
# ── One relation resolver ─────────────────────────────────────────────────────────────────────────
# "Which model does segment `s` reach from model `m`?" used to have three answers: the renderer's
# (`_build_row_join`), `_resolve_join_target_model` (`on()`'s path, base field FIRST) and `_relation_hop`
# (#962's right-side check, `cjoin` link first). They disagreed, and the disagreement was #974:
# `on("grid", …)` after `cjoin("grid" => "Driver", field = …)` was refused, because the plain column
# `grid` won over the link the renderer itself follows. Every caller now asks `_relation_step`, whose
# precedence is the renderer's first hop, arm for arm:
#
#   1. a JSON or array field is a VALUE lookup (`payload__key`, `tags__0`), never a hop (#27, #28);
#   2. a ManyToMany field hops to its target;
#   3. a `cjoin(field = …)` link on the FIRST segment, before the model field of the same name;
#   4. the model field (after the FK short form, `status` → `status_id`), if it has a target;
#   5. a reverse relation or a reverse ManyToMany, by its declared name.
#
# `_segment_field` is the only reader of a `cjoin` link (`_get_join_field`); `test_join_resolver_single.jl`
# fails if a second one appears.

# The field a segment names — a `cjoin` link on the first segment, consulted first, else the model's own
# field under the FK short form — or `nothing` when it names none. A field, not a relation: it may be a
# plain column, which is the caller's call to refuse or accept.
function _segment_field(q::SQLObject, model::PormGModel, seg::AbstractString, first_segment::Bool)
  if first_segment
    link = _get_join_field(q, String(seg))
    link !== nothing && return link
  end
  return get(model.fields, _resolve_fk_short_form(model, String(seg)), nothing)
end

# The model a target slot names: a model, or a binding name in the model's module.
_relation_target(model::PormGModel, to) = to isa PormGModel ? to : getfield(model._module, Symbol(String(to)))

# One relation hop: `(canonical segment, model reached, kind)`, or `nothing` when `seg` is not a relation
# from `model` — a plain column, a JSON/array value lookup, an unknown name. The canonical segment is the
# spelling `row_path` records for a forward hop (the short form resolved); a reverse hop keeps its name.
# `kind` is `:forward`, `:reverse` or `:many_to_many` (either direction: two rows through a link table).
function _relation_step(q::SQLObject, model::PormGModel, seg::AbstractString, first_segment::Bool)
  seg = String(seg)
  col = _resolve_fk_short_form(model, seg)
  own = get(model.fields, col, nothing)
  if own !== nothing
    (Models.is_json_field(own) || own isa sArrayField) && return nothing
    if Models.is_many_to_many_field(own)
      return (col, _relation_target(model, own.to), :many_to_many)
    end
  end
  field = _segment_field(q, model, seg, first_segment)
  if field !== nothing
    to = hasproperty(field, :to) ? field.to : nothing
    to === nothing && return nothing
    # A `cjoin` link is keyed by the segment as written; the model's own field by its resolved name.
    return (field === own ? col : seg, _relation_target(model, to), :forward)
  end
  haskey(model.related_objects, seg) || return nothing
  related = model.related_objects[seg]
  related isa Models.ManyToManyRelation &&
    return (seg, getfield(model._module, Symbol(related.related_binding)), :many_to_many)
  return (seg, (related::Models.ReverseRelation).model_resolved, :reverse)
end

# The relation part of a column path, in canonical spelling: the longest leading run of segments that are
# relations from the base model, `__@` transforms stripped first. `"driverid__nationality"` → `"driverid"`;
# a base column, a JSON key path (`"payload__key"`) or a literal → `""`. The last segment is the column,
# so it is never part of the prefix, even when it is itself a ForeignKey column.
function _relation_prefix(q::SQLObject, column::AbstractString)
  segments = split(String(first(split(String(column), "__@"))), "__")
  return _relation_run(q, segments[1:end-1])
end

# A join path in canonical spelling, every segment kept while it is a relation: `"status"` → `"status_id"`.
_canonical_join_path(q::SQLObject, path::AbstractString) = _relation_run(q, split(String(path), "__"))

function _relation_run(q::SQLObject, segments)
  prefix = ""
  model = q.model
  for (i, seg) in enumerate(segments)
    step = _relation_step(q, model, seg, i == 1)
    step === nothing && break
    prefix = isempty(prefix) ? step[1] : string(prefix, "__", step[1])
    model = step[2]
  end
  return prefix
end

# The model at the end of a join path `on()` names, or the error that says which segment is not a
# relation. `on()` targets model relations only — a CTE has its own join type knob (#434/#444).
function _join_path_target(q::SQLObject, join_path::String)
  parts = split(join_path, "__")
  (isempty(join_path) || isempty(parts)) && throw(QueryBuildError("on() requires a non-empty join path."))
  model = q.model
  for (i, part) in enumerate(parts)
    step = _relation_step(q, model, part, i == 1)
    if step !== nothing
      model = step[2]
      continue
    end
    if _segment_field(q, model, part, i == 1) !== nothing
      throw(QueryBuildError("Join path '$(join_path)' stops at base field '$(part)', which is not a relation. Use .cjoin(..., field=...) first if this path depends on a custom link."))
    end
    # #434/#444: best-effort hint. Both `.on()`-then-`.with()` and `.with()`-then-`.on()` reach this
    # same throw with the same wording; only the parenthetical depends on whether the CTE has been
    # declared yet, and it adds information rather than deciding the outcome.
    hint = haskey(q.ctes, part) ?
      " ('$(part)' is a CTE declared on this query — on() targets model relations only; set a CTE's join type with with(..., join_type=...).)" : ""
    throw(QueryBuildError("Join path '$(join_path)' is invalid. The segment '$(part)' is not a relation on model '$(model.name)'.$(hint)"))
  end
  return model
end

# ── `on()` declares its join (#977) ──────────────────────────────────────────────────────────────
# The path `build()` materializes for a `custom_join` entry nothing else reached: its segments, plus a
# column of the model at the end to stop on (the last segment of a path is always a column, never a
# hop). A `cjoin` names its link's target column; an `on()`-only entry the target's primary key, or its
# first field when it declares none.
function _join_path_columns(q::SQLObject, path::String, config::PathJoin)
  segments = String.(split(path, "__"))
  if config.field !== nothing
    push!(segments, config.field.pk_field)
  else
    target = _join_path_target(q, path)
    pk = Models.get_model_pk_field(target)
    push!(segments, pk === nothing ? first(target.field_names) : String(pk))
  end
  return segments
end

# A ManyToMany hop is two joins through a link table, built by `_apply_many_to_many_branch`, which never
# reads the `custom_join` entry for its path — so an `on()` predicate or `join_type` on one was dropped
# from the statement, silently, traversed or not. Refused until it is supported, rather than ignored.
function _refuse_many_to_many_join_path(q::SQLObject, path::String)
  model = q.model
  for (i, seg) in enumerate(split(path, "__"))
    step = _relation_step(q, model, seg, i == 1)
    step === nothing && return nothing   # not a relation path; `_join_path_target` reports it
    if step[3] === :many_to_many
      hop = join(split(path, "__")[1:i], "__")
      throw(QueryBuildError(
        "on(\"$(path)\", …) crosses the ManyToMany relation '$(hop)', whose join goes through a link " *
        "table that an ON predicate or join_type is not attached to. PormG would drop the condition " *
        "from the statement, so it refuses it instead.\n  Put the predicate in .filter(...) instead (#977)."))
    end
    model = step[2]
  end
  return nothing
end

# ── Binding conditions (#977) ───────────────────────────────────────────────────────────────────
# A condition is written against the HOP (`on("driverid", "number" => 5)` names the driver's
# `number`) and rendered through the base model's field-path namespace, so binding it means lowering
# every left-side column onto the path (`"driverid__number"`) — `_prefix_join_filter`'s rule, #958's
# and #961's — and then checking it as a filter. That used to happen at the `.on()` / `.cjoin()` call,
# against whatever was declared so far; it now happens once per build, against the final query, so a
# `cjoin` link declared after the `on()` that needs it is seen (#974).

# The conditions as the caller wrote them, with the checks that need no model: a handle refused (#444,
# #481) and a shape that is not a condition at all.
function _join_conditions_as_written(filters)::Vector{JoinCondition}
  out = JoinCondition[]
  for f in filters
    _guard_no_join_handles(f, "a join ON clause (on(...) / cjoin(...))")
    f isa JoinCondition ||
      throw(FilterError("Invalid filter type: $(typeof(f)). Use Pair, Q, Qor, OP, or F expressions."))
    push!(out, f)
  end
  return out
end

# Does this path's target depend on a `cjoin` link not declared yet? Only a first segment that is a
# plain field of the base model can become a join later — `cjoin` links a base field and nothing
# else — so every other path can be bound the moment it is written.
function _join_path_awaits_link(q::SQLObject, path::String)
  seg = String(first(split(path, "__")))
  return _relation_step(q, q.model, seg, true) === nothing && _segment_field(q, q.model, seg, true) !== nothing
end

# One path's conditions, bound: each left side lowered onto `path` (whose model is `target`), then
# checked into the node the renderer reads.
function _lower_join_conditions(q::SQLObject, path::String, target::PormGModel, conditions)::Vector{FilterType}
  out = FilterType[]
  for c in conditions
    lowered = _prefix_join_filter(c, path, target; base = q.model)
    if lowered isa Pair
      push!(out, _check_filter(lowered))
    elseif lowered isa FilterType
      push!(out, _check_filter_node(lowered))   # #863
    else
      throw(FilterError("Invalid filter type: $(typeof(lowered)). Use Pair, Q, Qor, OP, or F expressions."))
    end
  end
  return out
end

# The build pass: bind every path's conditions into `instruct.join_conditions`, and refuse what no ON
# clause can hold — a CTE-rooted string (#492) and a right side reaching a relation off the path
# (#962). Runs where the CTE pass does, after the instruction exists and before anything renders, and
# never touches the query object, so a nested or repeated build binds the same way.
function _bind_join_conditions!(instruct::SQLInstruction)
  q = instruct.object
  for (path, cfg) in q.custom_join
    bound = _lower_join_conditions(q, path, _join_path_target(q, path), cfg.filters)
    if !isempty(q.ctes)
      for f in bound
        _refuse_cte_string_in_join(f, q, "a join ON clause (on(...) / cjoin(...))")
      end
    end
    for f in bound
      _off_path_rhs_condition(f, q, path, 0)
    end
    instruct.join_conditions[path] = bound
  end
  return instruct
end
