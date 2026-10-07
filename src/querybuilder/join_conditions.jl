# Join conditions (#977): what a condition in `on(path, …)` / `cjoin(filters = …)` refers to.
#
# The call-time side of custom joins lives here too, at the end of the file (#130): prefixing a
# condition key and the handles a condition may not hold, #962's right-side check, lowering a
# condition onto its path, and the `on` / `cjoin` / `cjoin_on` entry points themselves.
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
  col = _resolve_fk_short_form(model, String(seg))
  if first_segment
    # Keyed by the base field the `cjoin` links — always the field's own name, so look it up under
    # the resolved name: `status__…` reaches a `cjoin("status_id" => …)` link too.
    link = _get_join_field(q, col)
    link !== nothing && return link
  end
  return get(model.fields, col, nothing)
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
    # The resolved name either way: a `cjoin` link is keyed by the base field it links, which is that
    # field's own name, so `status` and `status_id` canonicalize alike with or without a link (#977
    # review). A plain-column link (`grid`) resolves to itself.
    return (col, _relation_target(model, to), :forward)
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
  hop = _canonical_join_path(q, path)
  for c in conditions
    lowered = _prefix_join_filter(c, path, target; base = q.model)
    _refuse_lhs_past_hop(lowered, q, path, hop, 0)
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
    target = _join_path_target(q, path)
    bound = _lower_join_conditions(q, path, target, cfg.filters)
    if !isempty(q.ctes)
      for f in bound
        _refuse_cte_string_in_join(f, q, "a join ON clause (on(...) / cjoin(...))")
      end
    end
    for f in bound
      _off_path_rhs_condition(f, q, path, 0)
    end
    # Keyed by the canonical path, so a hop finds its conditions whichever spelling reached it — the
    # FK short form `on("status", …)` against `values("status_id__name")`, or the reverse. Two
    # spellings of one path in `custom_join` meet here and are ANDed, as two `on()` calls on one path
    # always are.
    key = _canonical_join_path(q, path)
    instruct.join_conditions[key] = vcat(get(instruct.join_conditions, key, FilterType[]), bound)
    cfg.join_type === nothing || (instruct.join_type_overrides[key] = cfg.join_type)
  end
  _bind_cjoin_on_conditions!(instruct)
  return instruct
end

# ── Binding `cjoin_on` conditions (#982) ────────────────────────────────────────────────────────
# A `cjoin_on` condition has no hop to lower onto. Each column in it names the base row (a bare
# column or a `__` path) or a declared alias (`Joined(alias, col)`), and `_cjoin_on` has already
# checked it as a filter. What binding decides is WHERE each named row is, before anything renders:
#
#   - A relation path (`"driverid__code"`, `F("driverid__code")`, an `OuterRef` in a subquery) is
#     recorded, and `build()` joins it before the alias rows. It used to be joined while the ON clause
#     rendered, after the alias row, and the predicate was then moved by a substring scan of the
#     rendered SQL onto that later join (Phase 1b, #421, #435): out of the ON clause the caller wrote
#     it in, into a join of another type. Under a LEFT `cjoin_on` that turned "null the alias's
#     columns" into "drop the row". Only a to-one path is built: a reverse or ManyToMany hop would
#     multiply the base row, and is refused (#992).
#   - Another alias is a dependency. Alias rows are emitted every alias after the ones it names, so a
#     reference always points backwards (#449's declaration order breaks the ties). A cycle has no such
#     order, and is refused.
#   - An ON clause that never names its own alias constrains nothing, and is refused (#448), from the
#     conditions rather than from the SQL text they rendered to.
#
# The segments recorded are the column's own, as written (`__@` transforms peeled), so the render that
# follows resolves through the very join built here and adds none: `_assert_condition_added_no_join`
# holds it to that, for this row kind too.
function _bind_cjoin_on_conditions!(instruct::SQLInstruction)
  q = instruct.object
  isempty(q.alias_join) && return instruct
  names_of = OrderedCollections.OrderedDict{String,Vector{String}}()
  built = Set{String}()
  for (alias, cfg) in q.alias_join
    names = String[]
    self_ref = false
    for f in cfg.filters
      _each_condition_column(f, 0) do column, written
        if column isa JoinedReference
          column.alias == alias ? (self_ref = true) :
            (column.alias in names || push!(names, column.alias))
        elseif !isempty(_relation_prefix(q, column))
          path = String(first(split(column, "__@")))
          _refuse_to_many_cjoin_on_path(q, alias, path, written)
          path in built && return nothing
          push!(built, path)
          push!(instruct.cjoin_on_paths, String.(split(path, "__")))
        end
        return nothing
      end
    end
    self_ref || _refuse_unconstrained_cjoin_on(alias, cfg)
    # A `Joined` naming no declared alias is left to the render, which refuses it with the declared list.
    names_of[alias] = filter(n -> haskey(q.alias_join, n), names)
  end
  append!(instruct.cjoin_on_order, _cjoin_on_emission_order(names_of))
  return instruct
end

# #992: a path built first must be a FORWARD path. A forward hop to a primary key matches at most one
# row per base row (a nullable FK becomes LEFT through `_determine_join_type`), so joining it first
# adds no rows. (A `cjoin(field = …)` link to a non-unique column can repeat rows, but that is the
# link's own semantics, the same wherever its path is referenced.) A reverse or ManyToMany hop does
# not: joined onto the base row it repeats it once per related row, and an INNER join drops it when
# there is none — a reverse OneToOne too, which is to-one but may have no match. Under a LEFT
# `cjoin_on` nothing undoes either. No SQL placement gives the caller
# what they wrote — in the path's ON the predicate filters the base row (the pre-#982 bug), in the
# alias's ON the path's join multiplies it — and no aggregate is projected for #74's guard to catch.
# The intent is a correlated existence test, which `Exists(… OuterRef …)` spells explicitly.
function _refuse_to_many_cjoin_on_path(q::SQLObject, alias::String, path::String, written::String)
  model = q.model
  segments = split(path, "__")
  for (i, seg) in enumerate(segments)
    step = _relation_step(q, model, seg, i == 1)
    step === nothing && return nothing   # the column; every hop before it was to-one
    if step[3] !== :forward
      hop = join(segments[1:i], "__")
      kind = step[3] === :reverse ? "reverse" : "ManyToMany"
      throw(FilterError(
        "\e[4m\e[31m$(written)\e[0m in the ON clause of cjoin_on alias \e[4m\e[31m$(alias)\e[0m crosses the " *
        "$(kind) relation '$(hop)'. PormG joins a path a cjoin_on condition names onto the base row, and " *
        "that join repeats each base row once per related '$(step[2].name)' row, and can drop it when there " *
        "is none.\n  To match on the existence of a related row, correlate a subquery over it: " *
        "\e[4m\e[32mExists(M.<Related>.objects.filter(\"<link>\" => OuterRef(\"<column>\"), …))\e[0m. " *
        "If the predicate was never about $(alias), pass that \e[4m\e[32mExists(...)\e[0m to " *
        "\e[4m\e[32m.filter(...)\e[0m instead — a to-many path there joins and repeats rows the same " *
        "way (#992)."))
    end
    model = step[2]
  end
  return nothing
end

# Kahn's algorithm over "alias → the aliases its ON clause names", taking the earliest-declared ready
# alias each step, so a query whose aliases already name only earlier ones keeps its declaration order
# (#449) — and with it the generated-alias numbering the rest of the statement was built against.
function _cjoin_on_emission_order(names_of::OrderedCollections.OrderedDict{String,Vector{String}})::Vector{String}
  order = String[]
  placed = Set{String}()
  pending = collect(keys(names_of))
  while !isempty(pending)
    i = findfirst(a -> all(n -> n in placed, names_of[a]), pending)
    if i === nothing
      # Name the cycle, not every alias still waiting: one that only names a member is blocked by it,
      # not part of it. Every pending alias names a pending one, so following those names from any of
      # them must revisit one, and the walk from that first revisit is the cycle.
      walk = String[first(pending)]
      while true
        nxt = first(n for n in names_of[walk[end]] if n in pending)
        k = findfirst(==(nxt), walk)
        k === nothing || (walk = walk[k:end]; break)
        push!(walk, nxt)
      end
      cycle = join(("\e[4m\e[31m$(a)\e[0m" for a in walk), ", ", " and ")
      throw(QueryBuildError(
        "The cjoin_on ON clauses of $(cycle) name each other, so no join order emits every alias before " *
        "the ON clauses that reference it.\n  Each ON clause may name only the base row, a relation path " *
        "and the aliases joined before it. Break the cycle: correlate one of them with the base row " *
        "instead, e.g. \e[4m\e[32mJoined(\"$(first(walk))\", \"<column>\") == F(\"<base column>\")\e[0m (#982)."))
    end
    push!(order, pending[i])
    push!(placed, pending[i])
    deleteat!(pending, i)
  end
  return order
end

# #448: having an ON clause is not the same as being CONSTRAINED by one. A predicate list that names
# this alias nowhere — `on = ["note" => "Z"]` — renders a well-formed, unconstrained join: every row
# of the joined table pairs with every matched base row, silently, since the #44 Cartesian warning
# covers CROSS entries only.
#
# Fail closed rather than warn. Stricter than SQLAlchemy, Ecto and jOOQ, which all emit an
# unconstrained join without complaint; Django never has the question because it exposes no arbitrary
# ON clause. Deliberate: a silently row-multiplied result is the worst failure mode here, and there is
# an escape hatch.
#
# That escape hatch is an unkeyed `.with(...)` that is REFERENCED — `values("x" => CTE(n, c))` — which
# is what the message points at. NOT `.with(...)` + `.filter(...)`: since #444 a CTE is joined only
# when referenced, so that spelling emits no join at all and silently returns N rows instead of N×M —
# the inverse of the bug this guard exists for.
function _refuse_unconstrained_cjoin_on(alias::String, cfg::AliasJoin)
  table = Models.model_table_name(cfg.target)
  throw(QueryBuildError(
    "The ON clause built for \e[4m\e[31m$(alias)\e[0m never references " *
    "\e[4m\e[31m$(alias)\e[0m, so the join is not constrained by it: every " *
    "\e[4m\e[31m$(table)\e[0m row would pair with every matched base row.\n  " *
    "Give it a predicate naming its own alias, e.g. " *
    "\e[4m\e[32mJoined(\"$(alias)\", \"<column>\") == F(\"<base column>\")\e[0m. " *
    "If the conditions were never about this join, move them to " *
    "\e[4m\e[32m.filter(...)\e[0m and drop the \e[4m\e[32mcjoin_on\e[0m; if you " *
    "genuinely want a cross product, declare the table as an unkeyed " *
    "\e[4m\e[32m.with(\"n\" => sub)\e[0m and REFERENCE it — e.g. " *
    "\e[4m\e[32mvalues(\"x\" => CTE(\"n\", \"col\"))\e[0m — which emits a real " *
    "\e[4m\e[32mCROSS JOIN\e[0m and warns that it is Cartesian (#44, #448)."))
end

# The canonical key of a hop being built (`_finish_hop!`, the PATH loop) — the one `_bind_join_conditions!`
# files its conditions under.
_join_key(instruct::SQLInstruction, join_path::AbstractString) = _canonical_join_path(instruct.object, join_path)

# ── #973: a left side stays on its hop ──────────────────────────────────────────────────────────
# A condition's left side names the joined row. A key whose RELATION part goes past the hop —
# `on("driverid", "results__grid" => 1)`, lowered to `"driverid__results__grid"` — names a row of a
# further relation instead, and resolving it used to ADD that join, silently: an unwritten INNER JOIN
# (row-multiplying, for a reverse relation) carrying the predicate in its ON clause. Refused, pointing
# at the hop that owns the column — `on("driverid__results", …)` joins it if nothing else does — or at
# `.filter(...)`. Walks the LOWERED condition, where every left-side column is a base-rooted path; the
# shapes are `_prefix_join_column`'s, the right side (#958) is left to #962's walk.
#
# #985 made this walk the HINT, not the guarantee: a node type it misses still renders through
# `_column_sql`, and the recorder refuses the column there. It stays because it refuses before any
# join is appended, with the spelling the caller wrote and the `on(...)` that would join it.
function _refuse_lhs_past_hop(x, q::SQLObject, path::String, hop::String, depth::Int)
  depth > 32 && return nothing
  if x isa Pair
    x.first isa String && _check_lhs_on_hop(x.first, q, path, hop)
  elseif x isa String
    _check_lhs_on_hop(x, q, path, hop)
  elseif x isa QObject
    for f in x.filters; _refuse_lhs_past_hop(f, q, path, hop, depth + 1); end
  elseif x isa QorObject
    for f in x.or; _refuse_lhs_past_hop(f, q, path, hop, depth + 1); end
  elseif x isa OperObject
    _refuse_lhs_past_hop(x.column, q, path, hop, depth + 1)
  elseif x isa SQLField
    _refuse_lhs_past_hop(x.field, q, path, hop, depth + 1)
  elseif x isa FObject
    x.aggregate && return nothing   # left as written; #917 refuses it with its own message
    _refuse_lhs_past_hop(x.column, q, path, hop, depth + 1)
    for v in values(x.kwargs)
      v isa Union{SQLTypeFunction,FExpression} && _refuse_lhs_past_hop(v, q, path, hop, depth + 1)
    end
  elseif x isa FExpression
    _refuse_lhs_past_hop(x.field_name, q, path, hop, depth + 1)
    _refuse_lhs_past_hop(x.column, q, path, hop, depth + 1)
    # An arithmetic operand is the left side too; a comparison's is the right side (#958).
    x.operation in _COMPARISON_OPERATIONS || _refuse_lhs_past_hop(x.operand, q, path, hop, depth + 1)
  elseif x isa AbstractVector && !(x isa AbstractVector{UInt8})
    for v in x; _refuse_lhs_past_hop(v, q, path, hop, depth + 1); end
  end
  return nothing
end

function _check_lhs_on_hop(column::String, q::SQLObject, path::String, hop::String)
  (isempty(column) || isempty(hop)) && return nothing
  rel = _relation_prefix(q, column)
  startswith(rel, hop * "__") || return nothing
  # Split by SEGMENT COUNT, not by text: `rel` is canonical and `column` as lowered, and the FK short
  # form spells the same relation two ways.
  segments = split(column, "__")
  n_rel = length(split(rel, "__"))
  written = join(segments[length(split(path, "__"))+1:end], "__")
  rest = join(segments[n_rel+1:end], "__")
  throw(FilterError(
    "\e[4m\e[31m\"$(written)\"\e[0m in on(\"$(path)\", …) / cjoin(filters = …) reaches '$(rel)', past the " *
    "join path '$(path)'. A condition's left side names the joined row; a column of a relation beyond " *
    "it needs a join of its own, which PormG used to add silently.\n  " *
    "Write it on that relation's join: \e[4m\e[32mon(\"$(rel)\", \"$(rest)\" => …)\e[0m, which joins it if " *
    "nothing else does — or put it in \e[4m\e[32m.filter(\"$(column)\" => …)\e[0m to restrict rows (#973)."))
end

# ── The render-time backstop (#977) ────────────────────────────────────────────────────────────
# Binding is what makes "resolving a condition adds no join" true: every column a path join's
# condition names is on its hop, an ancestor of it, or the base row, and all of those are
# materialized before the ON clauses render. This checks it where it would break — a row appended
# while one condition rendered. Raised, not emitted: the old renderer did emit it, and an
# unwritten join with the predicate in its ON clause is #973 itself.
function _assert_condition_added_no_join(instruc::SQLInstruction, row::JoinRow, rows_before::Int)
  length(instruc.row_join) == rows_before && return nothing
  added = join(("\"$(r.b)\" AS \"$(r.alias_b)\"" for r in instruc.row_join[rows_before+1:end]), ", ")
  error(_emsg("PormG internal error: rendering an ON condition of the join to \"$(row.b)\" AS " *
              "\"$(row.alias_b)\" added $(added) — a join condition must name only its own hop, an " *
              "earlier table on its path or the base row (#977). This should not happen; please report it."))
end

# ── #985: which row each column names, recorded where it renders ────────────────────────────────
# The backstop above closes "a condition silently ADDED a join". Its neighbour is "a column silently
# names the WRONG row, and no join is added" (#961's shape): a left-side node the lowering does not
# descend into stays on the base alias, renders as valid SQL, and compares the wrong column. The
# defence used to be walkers alone — `_prefix_join_column`, `_refuse_lhs_past_hop`, the `_off_path_*`
# family — each of which must enumerate every node type a column can hide in. #981 closed four gaps in
# one of them a day after it merged.
#
# So the check moved to the one place a model column becomes `"alias"."col"`: `_column_sql`, which
# every emitting site calls (`test/unit/test_join_column_recorder.jl` scans for any that does not). A
# column that renders is checked; one that does not render cannot name a row. That is #194's
# `outer_refs` invariant, and it is why the recorder needs no list of node types.
#
# The walkers stay, deliberately: they run at binding, before anything renders, so they refuse with
# the condition as WRITTEN (`"results__grid"`, the hop it reaches past, the `on(...)` that would join
# it) and before a join could be appended. This is the net under them: a gap in a walker is now a
# loud refusal with a plainer message instead of a wrong row.

# A model column as SQL text: `"alias"."col"`. `column_sql` is already quoted.
function _column_sql(instruc::SQLInstruction, alias::AbstractString, column_sql::AbstractString)::String
  _record_join_column(instruc, alias, column_sql)
  return string(quote_identifier(alias, instruc.connection), ".", column_sql)
end

# The check. Outside an ON clause there is nothing to check; inside one, the left side of a comparison
# names the row the join adds (#961), and its right side the base row, an earlier table on the join's
# path, or the joined row itself (#958, #962). For a `cjoin_on` row both sets are "every row emitted
# before it, and itself".
#
# A column on NO side — `:none`, the scope `_join_scope` opens with — gets the narrow LEFT set (#993).
# Which side a column is on is opt-in at each comparison render site (`_join_side_change(…, :left)`,
# `_on_join_right`), and nothing scans for those sites, so the default decides which way a forgotten
# mark fails. The permissive right set made a forgotten `:left` silent: a left side naming the base
# row passed, #961's wrong-row shape. The left set makes it a loud refusal, and only an explicit
# `_on_join_right` widens it. What it refuses besides is a column outside any comparison naming
# another row, and that predicate restricts rows: it belongs in `.filter(...)`.
function _record_join_column(instruc::SQLInstruction, alias::AbstractString, column_sql::AbstractString)
  s = instruc.scope
  s.join_hop === nothing && return nothing
  allowed = s.join_side === :right ? s.join_right : s.join_left
  alias in allowed && return nothing
  hop = s.join_hop
  written = "\"$(alias)\".$(column_sql)"
  if s.join_side === :left
    throw(FilterError(
      "\e[4m\e[31m$(written)\e[0m is on the left side of a condition in the ON clause of \"$(hop)\", but " *
      "it names \"$(alias)\". A condition's left side names the row its join adds; compare another " *
      "row's column on the right, or put the predicate in \e[4m\e[32m.filter(...)\e[0m (#985)."))
  elseif s.join_side === :none
    throw(FilterError(
      "\e[4m\e[31m$(written)\e[0m sits in the ON clause of \"$(hop)\" outside any comparison, and names " *
      "\"$(alias)\" rather than the row that join adds. A condition that does not compare the joined row " *
      "with another restricts rows, not the join.\n  Put it in \e[4m\e[32m.filter(...)\e[0m instead. If the " *
      "column IS inside a comparison, PormG rendered it without marking its side: that is a bug, please " *
      "report it (#993)."))
  end
  throw(FilterError(
    "\e[4m\e[31m$(written)\e[0m in the ON clause of \"$(hop)\" names \"$(alias)\", which is not the base " *
    "row, a table joined before it on its path, or the joined row itself, so it cannot appear in that " *
    "ON clause.\n  Put the predicate in \e[4m\e[32m.filter(...)\e[0m instead (#985)."))
end

# The side a comparison's operand renders on, or `nothing` when the scope already says it: no ON
# clause is rendering, the side is already that one, or the operand sits inside a RIGHT side, where
# every column is a right-side column whichever side of its own comparison it is on (#975). A
# comparison nested inside a LEFT side splits again: its own column left, its values right.
function _join_side_change(instruc::SQLInstruction, side::Symbol)::Union{Nothing,Symbol}
  s = instruc.scope
  (s.join_hop === nothing || s.join_side === :right || s.join_side === side) && return nothing
  return side
end

# Render `f()` as a comparison's right side.
function _on_join_right(f, instruc::SQLInstruction)
  side = _join_side_change(instruc, :right)
  side === nothing && return f()
  return with_scope(f, instruc; join_side = side)
end

# The scope one row's ON clause renders under: the hop, and the aliases each side may name. A path
# join's right side may name the base row, every table on its own path, and itself; its left side
# only itself, and so may a column no comparison has marked yet (`:none`, #993). A `cjoin_on` row
# has no hop to bind a side to, so both sides may name the base row and every row emitted before it
# — binding built every row it names there (#982) — and itself.
function _join_scope(f, instruc::SQLInstruction, idx::Int, value::JoinRow)
  hop = value.alias_b
  if value isa AnchorlessJoin
    rows = (instruc.alias, (r.alias_b for r in instruc.row_join[1:idx-1])..., hop)
    return with_scope(f, instruc; join_hop = hop, join_side = :none, join_left = rows, join_right = rows)
  end
  path = String[instruc.alias, hop]
  parent = value.alias_a
  for _ in 1:length(instruc.row_join)
    parent == instruc.alias && break
    push!(path, parent)
    i = findfirst(r -> r.alias_b == parent, instruc.row_join)
    i === nothing && break
    parent = instruc.row_join[i].alias_a
  end
  return with_scope(f, instruc; join_hop = hop, join_side = :none, join_left = (hop,), join_right = Tuple(path))
end

# ── Prefixing a condition key; the handles a condition may not hold (#444, #481) ──────────────────
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
#
# #492 restored the string spelling, which re-opens that route — so `spelled` lets a caller who wrote
# `"ev__sku"` see their OWN token as the offending one while the body and the remedy stay byte-
# identical to the handle form. One message, both spellings: every existing assertion on the tail
# keeps matching, and the reader is not told to fix a spelling they did not use.
function _reject_cte_in_join(ref::CTEReference, context::String;
                             spelled::AbstractString = "CTE(\"$(ref.name)\", \"$(ref.path)\")")
  throw(FilterError(
    "\e[4m\e[31m$(spelled)\e[0m cannot be used in $(context). A JOIN's " *
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
  # A cycle in the expression graph would make this walk a StackOverflowError — which Julia reports
  # with "program state may be corrupted". #457 closed ONE route into that: the comparison overloads
  # used to mutate their left operand, so `f = F("x"); g = (f == f)` returned an object containing
  # itself. They build a new expression now, so the F-expression self-cycle is gone.
  #
  # It did NOT make every cycle unreachable, and the cap is not merely defence against internal
  # mistakes: a CONTAINER cycle is still one exported spelling away — `q = Q("note" => "x");
  # push!(q, q)` — and the `QObject`/`QorObject` arms below walk straight into it. That is the cap's
  # live customer.
  #
  # A second reason it stays, narrower since #508 phase 2: the expression nodes are immutable now, so
  # `g.operand = g` on an internal `FExpression` is no longer one assignment away — that route is
  # closed by the type. What survives is the same container cycle arriving INDIRECTLY: `FObject.column`
  # admits `SQLTypeQ`/`SQLTypeQor` (`types.jl`), so a cyclic `Q` nested inside a function still reaches
  # this walk. Be precise about what it buys, though: it protects **`cjoin_on`**, and the `on()` /
  # `cjoin()` call-time sweep in `_join_conditions_as_written` (#977), the callers that reach it
  # WITHOUT going through `_prefix_join_filter`. It does NOT make
  # the `on()` / `cjoin()` route cycle-safe, and the three arms of `_prefix_join_filter` fail
  # differently, so do not read a uniform rule into it:
  #
  #   - `FExpression` — this guard runs, returns cleanly under the cap, and the very next line
  #     `deepcopy`s the same filter. That used to move the overflow one line down, because the
  #     hand-written `Base.deepcopy(::FExpression)` was uncapped; #508 phase 2 deleted it, so the copy
  #     now goes through Base, which tracks visited objects in an `IdDict` and terminates on a cycle
  #     instead of recursing into it.
  #   - `OperObject` — `deepcopy` runs FIRST, before this guard is called at all, so an internal cycle
  #     there never even reaches the cap.
  #   - `Pair` — this guard runs and nothing is copied; a cycle rides through untouched and overflows
  #     later, once something actually renders that ON clause. (If the join is pruned — nothing
  #     projects or filters through it — the predicate is never walked and the query completes.)
  #
  # Capping those walks too is deliberately not done: the shapes that reach them are built inside the
  # builder, and a cycle there is a defect to fix at its source rather than absorb downstream.
  #
  # No legitimate predicate nests anywhere near this deep, and stopping the walk only means the guard
  # declines to look further, never that it accepts something it saw.
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

# ── #962: a right side names only the base row or an ancestor on its path ─────────────────────────
# #962 — a condition in `on(path, …)` / `cjoin(filters = …)` may compare the joined row with the base
# row, or with a table earlier on the same path (an ancestor of `path`). A right side that names any
# OTHER relation — `on("constructorid", "nationality" => F("driverid__nationality"))` — cannot sit in
# the ON clause `on()` named, because that relation's join may not exist yet at that point in FROM;
# the renderer then relocated the predicate onto whichever join came later (`build_row_join_sql_text`,
# Phase 1b), so the result depended on `values()` order and could move a LEFT JOIN's predicate into an
# INNER JOIN, dropping rows instead of nulling columns. Refused, as Django's `FilteredRelation` refuses
# "relations outside" its own path.
#
# Checked at `build()` rather than at `.on()` time: a relation `cjoin` declares later is still a
# relation, so the answer cannot depend on call order (the #434 lesson `_on` records). The walk below
# runs over each path's BOUND conditions (`_bind_join_conditions!`, #977). Only the RIGHT side is
# walked: binding lowered the left side onto the path (`_prefix_join_filter`).
#
# #985 made this walk the HINT, not the guarantee: a right side it misses still renders through
# `_column_sql`, and the recorder refuses the column there (`_record_join_column`). It stays because
# it refuses at binding, naming the relation the caller wrote — before that relation's join exists.

# One condition: find its right side. A `Q`/`Qor` holds conditions; an `OperObject` keeps its right side
# in `values`; a comparison `FExpression` in `operand`. An `Exists(...)` contributes its `OuterRef`s.
function _off_path_rhs_condition(f, q::SQLObject, path::String, depth::Int)
  depth > 32 && return nothing
  if f isa QObject
    for x in f.filters; _off_path_rhs_condition(x, q, path, depth + 1); end
  elseif f isa QorObject
    for x in f.or; _off_path_rhs_condition(x, q, path, depth + 1); end
  elseif f isa OperObject
    # A String (or a list of them) here is a bound literal — `"nationality" => "Brazilian"` — never a
    # column, so only an expression node is walked.
    _is_rhs_expression(f.values) && _off_path_rhs_paths(f.values, q, path, depth + 1)
    _off_path_nested_rhs(f.column, q, path, depth + 1)
  elseif f isa FExpression && f.operation in _COMPARISON_OPERATIONS
    # A String operand of an `F` comparison is read as a column first (see `_refuse_cte_string_in_join`).
    _off_path_rhs_paths(f.operand, q, path, depth + 1)
    _off_path_nested_rhs(f.field_name, q, path, depth + 1)
  elseif f isa ExistsObject
    # #977: `Q(Exists(…))` is a condition of its own, and its `OuterRef`s resolve in this statement —
    # unwalked, an off-path one was relocated onto a later join like any other right side.
    _off_path_outer_refs(getfield(f.query, :object), q, path)
  end
  return nothing
end

# The right sides NESTED inside a left side. The left side's own columns were prefixed onto the path
# (#961), but two things inside it were not, by the same #958 rule: the right side of a comparison
# nested there — a `When` condition, `When(F("number") > F("x"))` — names the base row, and a
# subquery's `OuterRef` resolves in this statement. Either can reach an off-path relation, and was
# then relocated exactly like a top-level right side:
# `Case(When("number" => F("constructorid__constructorid"), then = 1), default = 0) > 0` on the driver
# join landed in the constructor's LEFT JOIN when `values()` built the driver first.
#
# The left side's columns themselves are not checked here: a left side that reaches BEYOND the hop
# (`on("driverid", "results__code" => "x")`) is refused by #973's own walk (`_refuse_lhs_past_hop`,
# `join_conditions.jl`), with a remedy that names the hop the column belongs to.
function _off_path_nested_rhs(x, q::SQLObject, path::String, depth::Int)
  depth > 32 && return nothing
  if x isa FExpression
    if x.operation in _COMPARISON_OPERATIONS
      _off_path_rhs_paths(x.operand, q, path, depth + 1)
    else
      _off_path_nested_rhs(x.operand, q, path, depth + 1)   # arithmetic: still the left side
    end
    _off_path_nested_rhs(x.field_name, q, path, depth + 1)
  elseif x isa OperObject   # a `When` condition: column on the left, `values` its right side
    _is_rhs_expression(x.values) && _off_path_rhs_paths(x.values, q, path, depth + 1)
    _off_path_nested_rhs(x.column, q, path, depth + 1)
  elseif x isa Union{QObject,QorObject}
    _off_path_rhs_condition(x, q, path, depth + 1)
  elseif x isa FObject
    x.aggregate && return nothing   # #917 refuses it, with its own message
    _off_path_nested_rhs(x.column, q, path, depth + 1)
    for v in values(x.kwargs)
      v isa Union{SQLTypeFunction,FExpression,SubqueryObject} && _off_path_nested_rhs(v, q, path, depth + 1)
    end
  elseif x isa SQLField
    _off_path_nested_rhs(x.field, q, path, depth + 1)
  elseif x isa SubqueryObject
    _off_path_outer_refs(getfield(x.query, :object), q, path)
  elseif x isa SQLObjectHandler
    _off_path_outer_refs(getfield(x, :object), q, path)
  elseif x isa ExistsObject
    _off_path_outer_refs(getfield(x.query, :object), q, path)
  elseif x isa AbstractVector && !(x isa AbstractVector{UInt8})
    for v in x; _off_path_nested_rhs(v, q, path, depth + 1); end
  end
  return nothing
end

_is_rhs_expression(x) = x isa Union{FExpression,FObject,SQLField,OperObject,SubqueryObject,SQLObjectHandler}

# Every column path inside a right-side value. Same boundary as `_prefix_join_column`: `.column` /
# `.field`, and a `kwargs` entry only when it holds an expression (a `Case`/`When`'s `then`/`else`;
# a String kwarg is a literal). An aggregate or window is skipped so #917's refusal keeps its own
# message; a literal names no relation. A subquery's own columns resolve in its own statement, but
# its `OuterRef`s resolve in THIS one, so those are checked like any right-side column.
#
# `f_slot` says the String came from an `F(...)`, so the error can show the caller the token they
# wrote — `F("driverid__x")` or a bare `"driverid__x"` (#492's "spelled" convention).
_off_path_rhs_paths(x, q::SQLObject, path::String, depth::Int; f_slot::Bool = false) =
  _each_condition_column(x, depth; f_slot = f_slot) do column, spelled
    column isa String && _check_rhs_relation(column, q, path; spelled = spelled)
  end

# The walk itself, shared by #962's check above and by `cjoin_on`'s binding (#982,
# `_bind_cjoin_on_conditions!`): `visit(column, spelled)` once per column reference — a String path
# (an `OuterRef`'s too, which resolves in this statement) or a `Joined(alias, col)` handle. Inside a
# value every column is a column of the statement, whichever side of its own comparison it sits on,
# which is exactly the reading both callers need: #962 checks each against the path, and a
# `cjoin_on` condition has no left side bound to a hop at all.
function _each_condition_column(visit::Function, x, depth::Int; f_slot::Bool = false)
  depth > 32 && return nothing
  if x isa String
    visit(x, f_slot ? "F(\"$(x)\")" : "\"$(x)\"")
  elseif x isa JoinedReference
    visit(x, "Joined(\"$(x.alias)\", \"$(x.path)\")")
  elseif x isa FExpression
    _each_condition_column(visit, x.field_name, depth + 1; f_slot = true)
    _each_condition_column(visit, x.column, depth + 1; f_slot = true)
    _each_condition_column(visit, x.operand, depth + 1)
  elseif x isa FObject
    x.aggregate && return nothing
    _each_condition_column(visit, x.column, depth + 1)
    for v in values(x.kwargs)
      # #977: a subquery in a `then`/`else` too — `_off_path_nested_rhs` already read it there, and
      # its `OuterRef` escaped this walk only.
      v isa Union{SQLTypeFunction,FExpression,SubqueryObject} && _each_condition_column(visit, v, depth + 1)
    end
  elseif x isa Union{QObject,QorObject}
    # #977: a `When` over a `Q(...)` holds its conditions here. Inside a right-side value every column
    # is a right-side column, whichever side of its own comparison it sits on.
    for v in (x isa QObject ? x.filters : x.or); _each_condition_column(visit, v, depth + 1); end
  elseif x isa ExistsObject
    _each_outer_ref(visit, getfield(x.query, :object))
  elseif x isa SQLField
    _each_condition_column(visit, x.field, depth + 1)
  elseif x isa OperObject
    # A `When` inside a function: its column is a column, its `values` literals unless an expression.
    # A `Joined` handle on the right of a pair is a column too (#982 reads it; #962 never sees one,
    # because a path join's conditions refuse the handle at the call).
    _each_condition_column(visit, x.column, depth + 1)
    (_is_rhs_expression(x.values) || x.values isa JoinedReference) &&
      _each_condition_column(visit, x.values, depth + 1)
  elseif x isa SubqueryObject
    _each_outer_ref(visit, getfield(x.query, :object))
  elseif x isa SQLObjectHandler   # an `@in` subquery, passed as the query itself
    _each_outer_ref(visit, getfield(x, :object))
  elseif x isa AbstractVector && !(x isa AbstractVector{UInt8})
    for v in x; _each_condition_column(visit, v, depth + 1); end
  end
  return nothing
end

# The `OuterRef`s of one subquery, from every slot that can hold an expression. Not descended: a nested
# subquery, whose own `OuterRef`s name ITS enclosing query (the inner one), not this statement.
_off_path_outer_refs(inner::SQLObject, q::SQLObject, path::String) =
  _each_outer_ref(inner) do column, spelled
    _check_rhs_relation(column, q, path; spelled = spelled)
  end

function _each_outer_ref(visit::Function, inner::SQLObject)
  refs = String[]
  slots = Any[inner.values, inner.filter, [o.field for o in inner.order]]
  for cfg in values(inner.custom_join); push!(slots, cfg.filters); end
  for cfg in values(inner.alias_join); push!(slots, cfg.filters); end
  for s in slots; _collect_outer_refs!(refs, s, 0); end
  for r in refs
    visit(r, "OuterRef(\"$(r)\")")
  end
  return nothing
end

function _collect_outer_refs!(refs::Vector{String}, x, depth::Int)
  depth > 32 && return refs
  if x isa OuterRefObject
    push!(refs, x.field_name)
  elseif x isa Pair
    _collect_outer_refs!(refs, x.first, depth + 1); _collect_outer_refs!(refs, x.second, depth + 1)
  elseif x isa QObject
    for v in x.filters; _collect_outer_refs!(refs, v, depth + 1); end
  elseif x isa QorObject
    for v in x.or; _collect_outer_refs!(refs, v, depth + 1); end
  elseif x isa OperObject
    _collect_outer_refs!(refs, x.column, depth + 1); _collect_outer_refs!(refs, x.values, depth + 1)
  elseif x isa FExpression
    for s in (x.field_name, x.column, x.operand); _collect_outer_refs!(refs, s, depth + 1); end
  elseif x isa Union{FObject,WindowFunction}
    _collect_outer_refs!(refs, x.column, depth + 1)
    for v in values(x.kwargs); _collect_outer_refs!(refs, v, depth + 1); end
  elseif x isa SQLField
    _collect_outer_refs!(refs, x.field, depth + 1)
  elseif x isa AbstractVector && !(x isa AbstractVector{UInt8})
    for v in x; _collect_outer_refs!(refs, v, depth + 1); end
  end
  return refs
end

# Both sides in canonical spelling (#977's one resolver): `F("status__name")` is the FK short form of
# `status_id`, so it is the same relation the renderer joins, and is judged as that relation.
function _check_rhs_relation(column::String, q::SQLObject, path::String;
                             spelled::AbstractString = "F(\"$(column)\")")
  isempty(column) && return nothing
  rel = _relation_prefix(q, column)
  canonical = _canonical_join_path(q, path)
  (isempty(rel) || rel == canonical || startswith(canonical, rel * "__")) && return nothing
  throw(FilterError(
    "\e[4m\e[31m$(spelled)\e[0m reaches '$(rel)', a relation outside the join path " *
    "'$(path)', so it cannot appear in that join's ON clause. A condition in on(...) / cjoin(...) " *
    "compares the joined row with the base row or with a table earlier on the same path; PormG will " *
    "not move it onto another join's ON clause.\n  " *
    "Put the predicate in \e[4m\e[32m.filter(...)\e[0m instead (#962)."))
end

# ── Lowering a condition onto its path; the `on` / `cjoin` / `cjoin_on` entry points ──────────────
# #961 — the left side of a join condition, walked to every column it holds. Shape and boundary are
# `_check_function`'s (build_helpers.jl): descend `.column` / `.field`, and a `kwargs` entry only when
# it holds an EXPRESSION (`_walk_kwargs`'s rule) — `Case`/`When` keep `then`/`else` there, while a
# String kwarg is a literal (`ToChar`'s format for `@yyyy_mm`, a `then = "x"` value) and stays
# untouched; so does an `SQLTypeText` literal (the `"-Q"` separator of `@yyyy_q`). Before this only a
# `String` column was rewritten, so a key inside `Q(...)` that carried a transform, and a function on
# the left of an `F` comparison, named the base row.
#
# `base` is the query's own model, which only the bare-string arithmetic operand needs (see the
# `FExpression` arm of `_prefix_join_filter`); every arm passes it along.
_prefix_join_column(x::String, prefix::String, foreign_model; base = nothing) =
  _normalize_cjoin_filter_key(x, prefix, foreign_model)
_prefix_join_column(x::SQLTypeText, ::String, _; base = nothing) = x
_prefix_join_column(x::Union{FExpression,SQLTypeQ,SQLTypeQor}, prefix::String, foreign_model; base = nothing) =
  _prefix_join_filter(x, prefix, foreign_model; base = base)
# The stale `_as` is half of #961: `Q("number" => 5)` builds `SQLField("number", _as = "number")`, and
# the renderer resolves that `_as` against the `values()` aliases, where a selected base `number`
# claimed it — so a rewritten `field` with the old `_as` still named the base row. Rewritten the same
# way, the node is the one the `Pair` arm builds from the prefixed key (`_as = "driverid__number"`).
function _prefix_join_column(x::SQLField, prefix::String, foreign_model; base = nothing)
  return SQLField(
    _prefix_join_column(x.field, prefix, foreign_model; base = base),
    x._as === nothing ? nothing : _normalize_cjoin_filter_key(x._as, prefix, foreign_model),
    x.custom_as,
    x.root   # #474: carry the namespace tag through the rewrite
  )
end
# An aggregate or a window function is left exactly as written. No ON clause can hold one, whatever
# row it names — #917 refuses it at render (`build_filter.jl`, "cannot appear in a join's ON clause")
# with the CTE remedy. Prefixing its column first would only swap that refusal for a less useful one:
# `OP(Count("grid"), ">", 1)` on the driver join would die as "Invalid cjoin filter field 'grid'".
function _prefix_join_column(x::FObject, prefix::String, foreign_model; base = nothing)
  x.aggregate && return x
  return FObject(function_name=x.function_name,
                 column=_prefix_join_column(x.column, prefix, foreign_model; base = base),
                 aggregate=x.aggregate, formatter=x.formatter, _as=x._as,
                 kwargs=_prefix_join_kwargs(x.kwargs, prefix, foreign_model, base))
end
_prefix_join_column(x::WindowFunction, ::String, _; base = nothing) = x
# The `When` inside a composite transform: its column is part of the left side, its `values` literals.
function _prefix_join_column(x::SQLTypeOper, prefix::String, foreign_model; base = nothing)
  return OperObject(operator=x.operator, values=x.values,
                    column=_prefix_join_column(x.column, prefix, foreign_model; base = base))
end
_prefix_join_column(x::Vector, prefix::String, foreign_model; base = nothing) =
  Any[_prefix_join_column(v, prefix, foreign_model; base = base) for v in x]
# A handle was refused by `_guard_no_join_handles` before any walk; a subquery, an `OuterRef` or a
# literal carries no column of the joined row.
_prefix_join_column(x, ::String, _; base = nothing) = x

# The expression-valued kwargs, prefixed; the Dict itself is returned when there are none, so a
# function with only literal kwargs comes back exactly as it was. A fresh Dict otherwise, because the
# caller's handle shares this one (#112).
function _prefix_join_kwargs(kwargs::Dict{String,Any}, prefix::String, foreign_model, base)
  any(v -> v isa Union{SQLTypeFunction,FExpression}, values(kwargs)) || return kwargs
  out = copy(kwargs)
  for (k, v) in out
    v isa Union{SQLTypeFunction,FExpression} &&
      (out[k] = _prefix_join_column(v, prefix, foreign_model; base = base))
  end
  return out
end

# Does `key` name a column or relation of `model` (`__@` transforms stripped)? Used for the base model,
# where it tells a column-reading string from a literal one.
function _model_has_key(model, key::String)
  model === nothing && return false
  first_segment = String(split(String(first(split(key, "__@"))), "__")[1])
  return first_segment in model.field_names || haskey(model.related_objects, first_segment)
end

# Does `key` name a field (or relation) of the joined model, with or without the join-path prefix?
# The test `_normalize_cjoin_filter_key` applies before it throws, asked without throwing.
function _joined_model_has_key(key::String, prefix::String, foreign_model)
  foreign_model === nothing && return false
  rest = startswith(key, prefix * "__") ? key[length(prefix) + 3:end] : key
  isempty(rest) && return false
  base_field = String(split(rest, "__")[1])
  return base_field in foreign_model.field_names || haskey(foreign_model.related_objects, base_field)
end

# #958 — one rule for every spelling: a condition's KEY / left side is prefixed with the join path, so
# it names the joined row; a comparison's RIGHT side is never prefixed, so a bare `F` there names the
# base row (the joined row stays reachable through its path, `F("driverid__number")`). The `Pair` arm
# always left `filter.second` alone, but the `OperObject` arm (what `Q`/`Qor`/`OP` build) and the
# `FExpression` arm prefixed the right side too — so `Q("number" => F("number"))` rendered
# `"Tb_1"."number" = "Tb_1"."number"`, a tautology that silently dropped the predicate.
function _prefix_join_filter(filter, prefix::String, foreign_model::Union{PormGModel,Nothing};
                             base::Union{PormGModel,Nothing} = nothing)
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
    return QObject(filters=[_prefix_join_filter(f, prefix, foreign_model; base = base) for f in filter.filters])
  elseif filter isa QorObject
    return QorObject(or=[_prefix_join_filter(f, prefix, foreign_model; base = base) for f in filter.or])
  elseif filter isa OperObject
    new_oper = deepcopy(filter)

    # A `Q(...)`/`Qor(...)` element arrives here already converted, so the handle is inside the
    # OperObject rather than on a raw Pair. Same refusal, same reason (#444/#481).
    _guard_no_join_handles(new_oper, "a join ON clause (on(...) / cjoin(...))")

    # #508 phase 2 — `OperObject` is immutable, so the rewritten slots are computed here and the node
    # is built ONCE at the end. The `deepcopy` above stays exactly where it was: it is what the guard
    # walks, and `values` may hold a nested handler it must not share.
    # #961: the whole column is the left side, so every column inside it is prefixed — including one
    # wrapped in a transform (`Q("dob__@year" => …)` arrives as `SQLField(EXTRACT(dob))`), which the
    # old `column.field isa String` test let through onto the base row.
    column = _prefix_join_column(new_oper.column, prefix, foreign_model; base = base)

    # #958: `values` is the right-hand side — never prefixed, as in the `Pair` arm.
    return OperObject(operator=new_oper.operator, values=new_oper.values, column=column)
  elseif filter isa FExpression
    # #444: sweep the F expression BEFORE prefixing. `F("sku") == CTE("ev","sku")` is a `FilterType`,
    # so `on()`/`cjoin()` accept it, and the arms below only rewrite `String` slots — a handle rode
    # through untouched and its predicate then resolved onto the CTE's join rather than the join the
    # caller named. Same refusal as a raw pair; the sweep walks the nested slots (#481: both kinds).
    _guard_no_join_handles(filter, "a join ON clause (on(...) / cjoin(...))")
    new_filter = deepcopy(filter)

    # #508 phase 2 — as in the `OperObject` arm above: compute each rewritten slot, build one node.
    # #961: `field_name` is the left side whatever it holds — a String, a nested expression, or a
    # function (`Abs(F("number")) > 0`), which used to pass through and name the base row.
    field_name = _prefix_join_column(new_filter.field_name, prefix, foreign_model; base = base)

    column = new_filter.column
    # #958: `""` is the placeholder `_compare` writes when it nests a comparison over an expression
    # (`(F("a") + F("b")) > …`); the column lives in `field_name`, and prefixing `""` threw.
    if column isa String && !isempty(column)
      column = _normalize_cjoin_filter_key(column, prefix, foreign_model)
    elseif column isa Vector{String}
      column = [_normalize_cjoin_filter_key(v, prefix, foreign_model) for v in column]
    elseif column isa SQLField
      column = _prefix_join_column(column, prefix, foreign_model; base = base)   # #961: `_as` too
    end

    # #958: a comparison's operand is its right-hand side, which names the base row — not prefixed.
    # An arithmetic/bitwise operand is part of the same side as `field_name`, so it is (#961: every
    # column-bearing operand, not just a nested `FExpression` — `F("number") + Abs(F("number"))`
    # prefixed the first `number` and left the `ABS` argument on the base row).
    #
    # A bare `String` operand is a column that FALLS BACK to a literal (the resolver tries the column
    # reading first — see `_refuse_cte_string_in_join`). So it is a column when it names a field of
    # the joined model OR of the base model, and is prefixed either way: a base-only column then
    # raises the same "Invalid cjoin filter field" a bare `F("grid")` does, instead of rendering on
    # the base row (`"Tb_1"."number" + "Tb"."grid"`). A string that names no column of either keeps
    # its literal reading (`F("number") + "7"`).
    operand = new_filter.operand
    if !(new_filter.operation in _COMPARISON_OPERATIONS)
      if operand isa String
        (_joined_model_has_key(operand, prefix, foreign_model) || _model_has_key(base, operand)) &&
          (operand = _normalize_cjoin_filter_key(operand, prefix, foreign_model))
      elseif operand isa Union{FExpression,SQLTypeFunction,SQLField}
        operand = _prefix_join_column(operand, prefix, foreign_model; base = base)
      end
    end

    return FExpression(field_name=field_name, operation=new_filter.operation, operand=operand,
                       function_name=new_filter.function_name, column=column,
                       aggregate=new_filter.aggregate, _as=new_filter._as, kwargs=new_filter.kwargs)
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

function _on(q::SQLObject, join_path::String, filters::AbstractVector; join_type::Union{String,Nothing}=nothing)
  # #977: stored as written and bound onto the path at build (`_bind_join_conditions!`). Bound now
  # too, result discarded, whenever the path's target cannot change — so a bad path or key still
  # fails at this call. It can change only when the first segment is a plain column a `cjoin(field
  # = …)` declared LATER turns into a join (#974, in the order #434 says must not matter): that one
  # waits for build, where the same checks run with every link known.
  parsed_filters = _join_conditions_as_written(filters)
  if !_join_path_awaits_link(q, join_path)
    _lower_join_conditions(q, join_path, _join_path_target(q, join_path), parsed_filters)
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

  # #977: the conditions are STORED as written and bound onto the path at build
  # (`_bind_join_conditions!`), once every link is declared. Binding them now as well, and discarding
  # the result, keeps their errors at this call: the target here is `foreign_model` whatever is
  # declared later, so the answer cannot change.
  conditions = _join_conditions_as_written(filters)
  _lower_join_conditions(q, main_join.first, foreign_model, conditions)

  # Store in the PATH namespace (#484). A `cjoin_on` alias spelled the same sits in `q.alias_join`
  # and does not trip this guard — before #484 it did, with a message naming a join path the caller
  # never declared.
  #
  # No join type of its own: `_cjoin` folded it into `field.how` above, which is why `PathJoin`'s
  # `join_type` (the `on(join_type = …)` override) is carried over from an earlier `on()`, never set.
  #
  # #974/#434: an `on()` on this path declared FIRST left an entry with no link. The `cjoin` supplies
  # it, after that entry's conditions — declaration order does not decide whether the two meet.
  existing = get(q.custom_join, main_join.first, nothing)
  if existing === nothing
    q.custom_join[main_join.first] = PathJoin(conditions, field, nothing)
  elseif existing.field === nothing
    q.custom_join[main_join.first] = PathJoin(vcat(existing.filters, conditions), field, existing.join_type)
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
# A self-join is `_cjoin_on(q, M.Base; alias="b2", on=[...])`.
#
# #484 — the entry goes in `q.alias_join`, its own namespace, NOT in `q.custom_join` alongside the
# `cjoin` / `on()` PATH entries. Sharing one map is what made an alias equal to a ForeignKey field
# name unrepresentable-as-written: `_build_row_join` asked that map for the FK hop's config under
# the hop's path, found this entry, and folded the alias's whole ON clause into the FK's join. The
# alias is therefore refused only when it duplicates ANOTHER alias; it may equal a relation name, a
# `cjoin` path or an `on()` path, in any declaration order, and both joins are emitted under their
# own SQL aliases (they always did have different ones — the collision was only ever internal).
#
# #488 — the target is a model OBJECT; the model-name `String` arm below is a prefix that resolves
# the name in the query's models module and delegates here. `AliasJoin.target` and all three of its
# render sites already spoke `PormGModel` since #484, so the object form is the shorter path, and a
# typo in it is an `UndefVarError` from Julia at the call rather than a runtime `QueryBuildError`.
function _cjoin_on(q::SQLObject, target::PormGModel, on::AbstractVector; alias::String, join_type::Union{String,Nothing}="INNER")
  # Fail-closed identifier check on the user alias (it is interpolated into SQL as a quoted alias).
  _validate_identifier(alias)
  # #488: an object can come from anywhere, including a model registered on ANOTHER connection.
  # That is refused — but at BUILD time, in `_build_cjoin_on_row_join`, not here: the connection a
  # statement runs on is `q.connect_key` (a `.db("key")` override) falling back to the model's
  # registration, and `.db()` may be called after this. Declaration time cannot know it.
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
      push!(parsed, _check_filter_node(f))   # #863
    else
      throw(FilterError("Invalid cjoin_on `on` element: $(typeof(f)). Use Pair, Q, Qor, OP, or F expressions."))
    end
  end
  isempty(parsed) && throw(QueryBuildError("cjoin_on requires at least one `on` predicate."))

  # The target model is stored resolved, once, rather than re-looked-up from a stored name at each
  # of the three render sites that need it (#484). The map key carries the alias and the map itself
  # carries "anchor-less", so the old `"user_alias"` / `"no_anchor"` tags have nothing left to say.
  q.alias_join[alias] = AliasJoin(
    target,
    parsed,
    join_type === nothing ? "INNER" : _normalize_join_type(join_type))
  return q
end

# The model-NAME spelling (#45's original form): resolve the binding in the query's models module,
# then delegate. Kept alongside the object arm because it costs nothing and reads naturally in a
# models file that has no `M.` prefix at hand. The alias is validated here too, so the two arms
# report a bad alias and an unknown model in the same order they always did.
function _cjoin_on(q::SQLObject, target_model::String, on::AbstractVector; alias::String, join_type::Union{String,Nothing}="INNER")
  isempty(strip(target_model)) && throw(QueryBuildError("cjoin_on requires a target model name."))
  _validate_identifier(alias)
  if !isdefined(q.model._module, Symbol(target_model))
    throw(QueryBuildError("cjoin_on target model '$(target_model)' not found in module. Model names are case-sensitive."))
  end
  return _cjoin_on(q, getfield(q.model._module, Symbol(target_model))::PormGModel, on; alias=alias, join_type=join_type)
end

function _cjoin_on(q::SQLObjectHandler, target::Union{String,PormGModel}; alias::String, on::AbstractVector, join_type::Union{String,Nothing}="INNER")
  _cjoin_on(q.object, target, on; alias=alias, join_type=join_type)
  return q
end
