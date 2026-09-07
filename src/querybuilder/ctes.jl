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
  # A second reason it stays: `FExpression` is a mutable struct, so `g.operand = g` on an internal
  # object is one assignment away too. Be precise about what it buys, though: it protects **`cjoin_on`**, the
  # one caller that reaches this sweep WITHOUT going through `_prefix_join_filter`. It does NOT make
  # the `on()` / `cjoin()` route cycle-safe, and the three arms of `_prefix_join_filter` fail
  # differently, so do not read a uniform rule into it:
  #
  #   - `FExpression` — this guard runs, returns cleanly under the cap, and the very next line
  #     `deepcopy`s the same filter. `Base.deepcopy(::FExpression)` is uncapped, so the overflow just
  #     moves one line down.
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

# ─────────────────────────────────────────────────────────────────────────────
# #492 — the `"<cte>__<col>"` string spelling, resolved at BUILD time
#
# #444 removed this spelling outright because the CTE registry was consulted FIRST, ahead of the
# many-to-many / forward-FK / reverse arms, so `.with("parent" => …)` silently took over the path of
# a `parent` ForeignKey. The magic was that first-match-wins PRECEDENCE, not the string — and
# removing the precedence does not require removing the string. It requires refusing to ANSWER the
# ambiguity instead of guessing at it.
#
# WHY A REWRITE PASS AND NOT A GATE INSIDE `_build_row_join`. The issue proposes the gate. A gate
# there can decide which relation a path means, but it receives a `Vector{String}` and has no handle
# on the caller's `SQLField`, so it cannot fix four things that all fail SILENTLY:
#
#   1. It sets `cte = true` internally, so the join builder writes `(:cte, "ev__sku")` while the
#      caller's `SQLField.root` stays `:base` and every reader looks under `(:base, …)`. That is a
#      guaranteed memo miss — the #474 defect, reintroduced by the fix meant to prevent it.
#   2. The #352/#373 sargable date rewrite dispatches on the TYPE of `FObject.column`. A string that
#      stays a string takes `_resolve_bucket_column(::String, …)`, which reads the `:base` half, so
#      `filter("ev__seen__@yyyy_mm__@lte" => …)` would quietly lose the rewrite while the handle form
#      kept it. Two spellings, two query plans, no error.
#   3. JSON: the writer keys `:cte`, the reader `:base` — the miss drops the comparison to the
#      generic branch, which runs the JSON formatter on a plain-string RHS and throws.
#   4. RHS formatting reads `tab_field_cache` under the field's own key; a miss binds an unformatted
#      Date or number, on one spelling only.
#
# Rewriting the string into a real `CTEReference` makes all four vanish, because afterwards the two
# spellings are LITERALLY THE SAME EXPRESSION OBJECT. `_as` already agrees byte-for-byte between them
# (`_cte_as` is `string(name, "__", path)`, and the parse sets `_as` to the joined full string), so
# the rewrite touches only the terminal `String` → `CTEReference` and `root` — never `_as` — which
# also makes it idempotent.
#
# WHY BUILD TIME. The registry is complete only once `build()` runs; `.filter()` / `.values()` /
# `.on()` are call time, and a check there is order-dependent — `.with()` then `.filter()` refused
# while the reverse sailed past. That is exactly the #434 defect whose removal is recorded above in
# `_on`. Every read entry point `deepcopy`s the handler before `build()`, so this mutates a per-call
# copy and never the user's query object.
#
# THAT DEEPCOPY IS ALSO WHAT KEEPS THIS INSIDE THE #493/#508 CONTRACT (construct, never mutate —
# `pormg-querybuilder-internals` → *Expression nodes*). The arms below assign into `.column` /
# `.field` / a `WindowSpec` vector, which on a node that arrived through the public API would be the
# #508 defect: `agg = Sum("ev__sku")` bound to a name and reused across two queries would carry the
# first query's rewrite into the second. It does not, because by the time this runs every node is a
# per-build copy — the same standing this skill grants `_retag_cte_column` / `_retag_joined_column`,
# which rewrite a build product rather than a user node. Measured: after building a query that uses
# it, a shared `Sum("ev__sku")` still holds a `String`, and re-using it in a query with no `ev` CTE
# still fails as a field path rather than as a stale handle. Move this pass ahead of the deepcopy and
# that stops being true.
# ─────────────────────────────────────────────────────────────────────────────

# Segment 1 of `path`, if this is a CTE COLUMN reference on this query; `nothing` otherwise.
#
# Naming a declared CTE is necessary but NOT sufficient, and getting that wrong cost both halves of
# the defect this guard exists to prevent. A CTE reference is `"<name>__<column path>"`: there has to
# be a column INSIDE the CTE for it to name. So the remainder after `<name>__` must carry at least
# one ordinary segment — an operator/transform token (`@isnull`, `@yyyy_mm`) is a suffix ON a column,
# never a column itself, which is why they do not count.
#
# Without that test, segment 1 alone made `"parent"` mean `CTE("parent", "parent")` (`chopprefix` is
# a no-op when there is no prefix to chop), and:
#
#   • `filter("parent" => 1)` and `values("parent")` on a model whose `parent` is a ForeignKey
#     started raising `AmbiguousFieldError` the moment a CTE was named `parent` — a REGRESSION on one
#     of the commonest calls an app makes, and against #492's own "everything legal today stays
#     legal". The message was incoherent too: with no remainder it printed `CTE("parent", "column")`,
#     a spelling that cannot exist.
#   • worse, where the model had NO such field but the CTE projected a column of its own name,
#     `values("pcte")` resolved SILENTLY to the CTE's column — first-match-wins resolution surviving
#     in the single-segment namespace, which is the exact class #492 removes.
#
# `_build_row_join`'s own `rest = length(vector) > 1 ? … : "column"` fallback is the tell that a
# one-segment path was never meant to reach a CTE.
function _cte_string_root(q::SQLObject, path::AbstractString)::Union{Nothing,String}
  segs = split(path, "__")
  length(segs) > 1 || return nothing
  any(!isempty(s) && !startswith(s, "@") for s in segs[2:end]) || return nothing
  seg1 = String(first(segs))
  return haskey(q.ctes, seg1) ? seg1 : nothing
end

# THE AMBIGUITY PROBE. It must agree with `_build_row_join`'s arms exactly, or the gate disagrees
# with the cascade it is protecting — so it consults the same registries, in the same forms:
#
#   • `_resolve_fk_short_form`'s OUTPUT for the field lookups (the m2m arm, the JSON base guard and
#     the forward-FK arm all test the resolved column);
#   • the RAW segment for `related_objects` (the reverse arm tests it unresolved) and for
#     `custom_join` (a join path is a literal key).
#
# The join-path arm is the easy one to miss — it is #474's `cjoin`/`on()` PATH keyspace, not a
# model field, and a path there is reached by segment 1 just like a relation. It asks
# `_get_join_config` rather than the `_get_join_field` the issue named, because
# `_get_join_field` returns `config.field`, and that is `nothing` for an `on()`-only entry
# (`cjoin` sets the link, `on()` does not) — so the obvious spelling skips silently over every
# path declared with `on()` alone.
#
# Belt and braces either way, and worth saying so rather than implying a hole: `on()` and
# `cjoin()` both validate their path against the model at declaration, so a join-config key is
# ALWAYS also a field or a reverse accessor and one of the arms above has already fired. It is
# kept because a future join writer accepting a key that is not a relation would otherwise
# re-open a silent resolution, and this probe's whole job is to be never narrower than the
# cascade it protects.
#
# `alias_join` is deliberately NOT consulted. #484 gave a `cjoin_on` alias its own namespace,
# reachable only through `Joined(alias, path)` — a `__` string cannot mean an alias at all, so an
# alias sharing a CTE's name is not an ambiguity for a string.
#
# OR-ing every arm makes the gate never NARROWER than the cascade, which is the safe direction: a
# false refusal is loud and one edit away, a false resolution is silent wrong rows.
function _segment1_on_model(q::SQLObject, seg1::AbstractString)::Bool
  resolved = _resolve_fk_short_form(q.model, String(seg1))
  return haskey(q.model.fields, resolved) ||
         resolved in q.model.field_names ||
         haskey(q.model.related_objects, String(seg1)) ||
         _get_join_config(q, String(seg1)) !== nothing
end

# Name both readings and print the spelling that selects each. The CTE side has a spelling; the model
# side does not, and saying so plainly is better than implying one exists — a base-namespace handle
# is deliberately deferred (#492), so renaming the CTE is the honest remedy today.
function _refuse_ambiguous_cte_path(q::SQLObject, path::AbstractString, seg1::AbstractString)
  rest = length(split(path, "__")) > 1 ? join(split(path, "__")[2:end], "__") : "column"
  throw(AmbiguousFieldError(
    "\e[4m\e[31m$(path)\e[0m is ambiguous: \e[4m\e[31m$(seg1)\e[0m names both a CTE declared by " *
    "\e[4m\e[32m.with(\"$(seg1)\" => …)\e[0m and something on " *
    "\e[4m\e[32m$(q.model.name)\e[0m (a field, reverse accessor, or join path), so this path has " *
    "two meanings and PormG will not choose one.\n  " *
    "For the CTE's column, write \e[4m\e[32mCTE(\"$(seg1)\", \"$(rest)\")\e[0m.\n  " *
    "For the model's own \e[4m\e[32m$(seg1)\e[0m, rename the CTE — a `__` path cannot select it " *
    "while the name is taken (#492)."))
end

# The expression walk. Mirrors `_retag_cte_column` (`build_helpers.jl`) arm for arm, because the shape
# space is the same one; the only difference is that a `String` here may or may not name a CTE, so
# each terminal is TESTED rather than converted unconditionally.
#
# `kwargs` is deliberately never descended — it holds format literals (`Y_M`) and the composite
# transform's own expansion, not column references.
_retag_cte_string(x::CTEReference, ::SQLObject, ::Set{String}) = x
_retag_cte_string(x::SQLTypeText, ::SQLObject, ::Set{String}) = x
_retag_cte_string(x::JoinedReference, ::SQLObject, ::Set{String}) = x
function _retag_cte_string(x::String, q::SQLObject, rewrote::Set{String})
  seg1 = _cte_string_root(q, x)
  seg1 === nothing && return x
  _segment1_on_model(q, seg1) && _refuse_ambiguous_cte_path(q, x, seg1)
  # The full OUTPUT spelling, not just the CTE name — `_bind_cte_string!` needs to tell "this field
  # IS that CTE column" from "this field merely has an alias starting with that CTE's name".
  push!(rewrote, _cte_as(seg1, chopprefix(x, seg1 * "__")))
  return CTEReference(name = seg1, path = chopprefix(x, seg1 * "__"))
end
function _retag_cte_string(x::SQLTypeFunction, q::SQLObject, rewrote::Set{String})
  x.column = _retag_cte_string(x.column, q, rewrote)
  return x
end
function _retag_cte_string(x::SQLTypeField, q::SQLObject, rewrote::Set{String})
  x.field = _retag_cte_string(x.field, q, rewrote)
  return x
end
# A window function hides column paths in TWO slots the arm above cannot see. `WindowFunction` is a
# `SQLTypeFunction`, so without this method it takes that arm, its `column` is rewritten and its
# `OVER (...)` clause is not — and `partition_by` / `order_by` are fields of `over::WindowSpec`,
# never of `column`.
#
# Both halves of #492 failed there, in opposite directions. `partition_by = "ev__sku"` threw the
# scope diagnostic, breaking the acceptance item that names window clauses; and with a SHADOWING
# name it was worse than a missing feature — `partition_by = "parent__sku"` resolved silently to the
# ForeignKey and rendered, while the identical string in `values()` raised `AmbiguousFieldError`.
# One query, one string, refused in one clause and guessed in the other: that is exactly the
# first-match precedence #492 exists to remove, surviving in a corner.
#
# The vectors are mutated IN PLACE, not rebuilt. They are typed `Vector{WindowPartitionPart}` /
# `Vector{WindowOrderPart}` while the `::Vector` arm below returns an `Any[]`, which neither field
# will accept; element assignment type-checks because `SQLTypeCTE` is a member of both unions.
function _retag_cte_string(x::WindowFunction, q::SQLObject, rewrote::Set{String})
  x.column = _retag_cte_string(x.column, q, rewrote)
  for i in eachindex(x.over.partition_by)
    x.over.partition_by[i] = _retag_cte_string(x.over.partition_by[i], q, rewrote)
  end
  for i in eachindex(x.over.order_by)
    x.over.order_by[i] = _retag_cte_string_window_order(x.over.order_by[i], q, rewrote)
  end
  return x
end

# A window's ORDER BY stores each entry AS GIVEN — `"-ev__seen"` keeps its `-`, and the prefix is
# resolved to DESC at render time (`WindowSpec`). So the sign has to come off before segment 1 can be
# tested and go back on as `desc = true`, which is what makes `order_by = "-ev__seen"` render
# byte-identically to `order_by = CTE("ev", "seen"; desc = true)`.
#
# Reporting the STRIPPED path in an ambiguity message is deliberate, not sloppy: the fluent
# `order_by("-parent__sku")` also strips the prefix into an orientation before the gate ever sees a
# path, so both spellings of the same mistake produce the same sentence.
function _retag_cte_string_window_order(x::String, q::SQLObject, rewrote::Set{String})
  desc = startswith(x, "-")
  path = desc ? chopprefix(x, "-") : x
  seg1 = _cte_string_root(q, path)
  seg1 === nothing && return x
  _segment1_on_model(q, seg1) && _refuse_ambiguous_cte_path(q, path, seg1)
  push!(rewrote, _cte_as(seg1, chopprefix(path, seg1 * "__")))
  return CTEReference(name = seg1, path = chopprefix(path, seg1 * "__"), desc = desc)
end
# An `SQLOrder` entry is left ALONE, and that is a scope decision rather than an oversight.
# `SQLOrder.field` is `Union{SQLTypeField,String}` and `SQLTypeCTE` is not a `SQLTypeField`, so the
# wrapper cannot hold a CTE column in EITHER spelling — `SQLOrder(CTE("ev","seen"))` is a
# `MethodError` today and was one under #444 too. Rewriting into a bare `CTEReference` would work
# (the vector's element type admits one) but would silently drop the entry's `nulls` placement, and
# firing the ambiguity gate here would print a `CTE(...)` remedy that this wrapper cannot accept.
# Both are new design, not #492's, so the shape keeps its pre-existing behaviour and the gap is
# tracked separately in #509, together with the three distinct ways the shape currently fails.
_retag_cte_string_window_order(x, q::SQLObject, rewrote::Set{String}) = x
function _retag_cte_string(x::SQLTypeOper, q::SQLObject, rewrote::Set{String})
  x.column = _retag_cte_string(x.column, q, rewrote)
  return x
end
_retag_cte_string(x::Vector, q::SQLObject, rewrote::Set{String}) =
  Any[_retag_cte_string(v, q, rewrote) for v in x]
# Anything else — a bound value, a subquery, a number — is not a column path and is left alone.
_retag_cte_string(x, ::SQLObject, ::Set{String}) = x

# Per-`SQLField` entry. `root` must land wherever the HANDLE form lands, or the two spellings memoize
# under different `MemoKey`s and one query using both gets two cache entries for one column. The
# handle rule is simple — `_retag_cte_field!` sets `:cte` exactly when the projection or predicate
# WAS a bare `CTE(...)`, and not when one was nested inside a function — but by the time this pass
# runs the string equivalent has already been parsed, so "was it one whole path" cannot be read off
# the terminal's type. Two drafts got this wrong in opposite directions:
#
#   • keying off `_as`'s FIRST SEGMENT retagged `values("ev__sku" => Sum("ev__id"))` to `:cte`, where
#     the handle twin `values("ev__sku" => Sum(CTE("ev","id")))` stays `:base`. That `_as` is a user
#     ALIAS that merely looks like a CTE path.
#   • requiring the terminal to still BE a `CTEReference` missed every `__@` path: `"ev__seen__@year"`
#     is parsed into an `FObject` before this runs, so it read `:base` while the handle read `:cte` —
#     four shapes, including the sargable-date one this pass exists to protect.
#
# So `rewrote` carries the full `<name>__<path>` OUTPUT spelling of everything rewritten, and the
# test is whether this field's `_as` IS one of them, or is one of them plus a transform suffix
# (`"ev__seen"` → `"ev__seen__year"`). That is exactly "the output name is this CTE column's name",
# which separates the two cases above: the alias `"ev__sku"` is not `"ev__id"` nor a suffix of it.
#
# `values("x" => Concat("note", CTE("ev","sku")))` stays `:base` on both sides for free — `_as` is
# `"x"`, which matches nothing.
function _bind_cte_string!(field::SQLField, q::SQLObject)
  rewrote = Set{String}()
  field.field = _retag_cte_string(field.field, q, rewrote)
  if field._as !== nothing
    as = String(field._as)
    any(as == r || startswith(as, r * "__") for r in rewrote) && (field.root = :cte)
  end
  return field
end

# Refuse a CTE-rooted STRING inside a JOIN's ON clause, at build time.
#
# `_reject_cte_in_join` is typed on `CTEReference`, so under #444 this was unrepresentable; the
# restored string re-opens it and #434 comes back with it unless the refusal is order-independent.
# It runs here, over the STORED join configs, rather than at `.on()` / `.cjoin_on()` call time — the
# registry is complete now and was not then.
#
# `alias_join` is the live route: `_cjoin_on` skips `_prefix_join_filter` on purpose, so
# `cjoin_on(…, on = ["ev__sku" => 1])` reaches `_check_filter` raw and stores a `:base`-rooted field.
# `custom_join` is swept too — `_normalize_cjoin_filter_key` appears to make it unreachable by
# prefixing the key, but that is a negative about a helper with four rewrite arms, and one extra loop
# is cheaper than proving it.
function _refuse_cte_string_in_join(x, q::SQLObject, context::String, depth::Int = 0)
  depth > 32 && return nothing
  if x isa String
    seg1 = _cte_string_root(q, x)
    seg1 !== nothing && !_segment1_on_model(q, seg1) &&
      _reject_cte_in_join(CTEReference(name = seg1, path = chopprefix(x, seg1 * "__")),
                          context; spelled = "\"$(x)\"")
  elseif x isa Pair
    _refuse_cte_string_in_join(x.first, q, context, depth + 1)
    _refuse_cte_string_in_join(x.second, q, context, depth + 1)
  elseif x isa QObject
    for f in x.filters; _refuse_cte_string_in_join(f, q, context, depth + 1); end
  elseif x isa QorObject
    for f in x.or; _refuse_cte_string_in_join(f, q, context, depth + 1); end
  elseif x isa OperObject
    _refuse_cte_string_in_join(x.column, q, context, depth + 1)
    # The RHS, swept the same as everything else — including a bare `String`.
    #
    # That is deliberate OVER-refusal, and it is worth being explicit about because the same shape
    # means something different one clause over: in `.filter()`, `"note" => "ev__sku"` is a VALUE
    # (measured — it binds the literal text). Here it is refused. Three reasons: the `Pair` arm above
    # already refuses it, so exempting only this slot made the walk disagree with itself depending on
    # whether `_check_filter` had folded the pair into an `OperObject` yet; nobody compares a column
    # against the literal text of a CTE path they just declared; and the pass's standing policy is
    # that a false refusal is loud and one edit away while a false resolution is silent wrong rows.
    #
    # There is no in-clause escape for someone who genuinely meant the literal, and an earlier draft
    # of this comment claimed `Value("ev__sku")` was one — it is not: a `Value` on the RHS of an ON
    # pair is a `MethodError` out of `_get_pair_to_oper`, independently of anything #492 did. The
    # remedy is the one the message already prints: move the predicate into `.filter(...)`, where the
    # same pair IS a value comparison. Failing that, rename the CTE.
    _refuse_cte_string_in_join(x.values, q, context, depth + 1)
  elseif x isa SQLTypeField
    _refuse_cte_string_in_join(x.field, q, context, depth + 1)
  elseif x isa FExpression
    # All three slots, `operand` INCLUDED. An earlier draft excluded it on the grounds that a bare
    # `String` there is a literal — which is false, and measurably so: with no CTE anywhere,
    # `filter(F("note") == "parent__sku")` emits `LEFT JOIN "cj_parent" … WHERE "Tb"."note" =
    # "Tb_1"."product_sku"`. The resolver tries the COLUMN reading first; `F("sku") == "ABC"` binds a
    # parameter only because `"ABC"` does not resolve as a path. So `operand` is a column slot that
    # falls back to a literal, not the other way round.
    #
    # Sweeping it cannot over-refuse: a string here that names a declared CTE plus a real column path
    # is already an error today, so the only thing that changes is WHICH error. Without it,
    # `on("parent", F("sku") == "ev__sku")` died with the scope `UnknownFieldError` telling the caller
    # to write `CTE("ev","sku")` — advice this very clause refuses, and contrary to what
    # `read/custom_joins.md` promises. `_guard_no_handle` sweeps all three for the same reason.
    _refuse_cte_string_in_join(x.field_name, q, context, depth + 1)
    _refuse_cte_string_in_join(x.column, q, context, depth + 1)
    _refuse_cte_string_in_join(x.operand, q, context, depth + 1)
  elseif x isa FObject
    _refuse_cte_string_in_join(x.column, q, context, depth + 1)
  end
  return nothing
end

# The pass entry, called from `build()` once the registry is final.
function _resolve_cte_string_paths!(q::SQLObject)
  # A query with no CTE cannot have a CTE-rooted path, so it pays one `isempty` and nothing else.
  # That is most of the neutrality argument for this pass, for free.
  isempty(q.ctes) && return q

  for v in q.values
    v isa SQLField && _bind_cte_string!(v, q)
  end
  for f in q.filter
    _bind_cte_filter!(f, q)
  end
  for o in q.order
    o.field isa SQLField && _bind_cte_string!(o.field, q)
  end

  # Opposite policy, same registry: a CTE reached from a join's ON clause is refused, not resolved.
  for (path, cfg) in q.custom_join
    for f in cfg.filters
      _refuse_cte_string_in_join(f, q, "a join ON clause (on(...) / cjoin(...))")
    end
  end
  for (alias, cfg) in q.alias_join
    for f in cfg.filters
      _refuse_cte_string_in_join(f, q, "a cjoin_on `on` expression")
    end
  end
  return q
end

# Filter elements are containers, not `SQLField`s, so they get their own shallow walk down to the
# fields that carry a column. A handle on the RHS (`filter("x" => CTE("ev","sku"))`) is already legal
# and already typed, so only the LHS positions need testing.
function _bind_cte_filter!(f, q::SQLObject, depth::Int = 0)
  depth > 32 && return nothing
  if f isa Pair
    _bind_cte_filter!(f.first, q, depth + 1)
  elseif f isa QObject
    for x in f.filters; _bind_cte_filter!(x, q, depth + 1); end
  elseif f isa QorObject
    for x in f.or; _bind_cte_filter!(x, q, depth + 1); end
  elseif f isa OperObject
    f.column isa SQLField && _bind_cte_string!(f.column, q)
  elseif f isa SQLField
    _bind_cte_string!(f, q)
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
  # #474: the CTE BODY's own instruction, where an outer CTE cannot be referenced (#433) — so this is
  # unambiguously the base-model half of that inner build's namespace.
  memoized = memo_field(instruct, memo_key(:base, field))
  if memoized !== nothing
    return memoized
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