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

# One relation hop: `(canonical segment, model reached)`, or `nothing` when `seg` is not a relation from
# `model` — a plain column, a JSON/array value lookup, an unknown name. The canonical segment is the
# spelling `row_path` records for a forward hop (the short form resolved); a reverse hop keeps its name.
function _relation_step(q::SQLObject, model::PormGModel, seg::AbstractString, first_segment::Bool)
  seg = String(seg)
  col = _resolve_fk_short_form(model, seg)
  own = get(model.fields, col, nothing)
  if own !== nothing
    (Models.is_json_field(own) || own isa sArrayField) && return nothing
    if Models.is_many_to_many_field(own)
      return (col, _relation_target(model, own.to))
    end
  end
  field = _segment_field(q, model, seg, first_segment)
  if field !== nothing
    to = hasproperty(field, :to) ? field.to : nothing
    to === nothing && return nothing
    # A `cjoin` link is keyed by the segment as written; the model's own field by its resolved name.
    return (field === own ? col : seg, _relation_target(model, to))
  end
  haskey(model.related_objects, seg) || return nothing
  related = model.related_objects[seg]
  related isa Models.ManyToManyRelation &&
    return (seg, getfield(model._module, Symbol(related.related_binding)))
  return (seg, (related::Models.ReverseRelation).model_resolved)
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
