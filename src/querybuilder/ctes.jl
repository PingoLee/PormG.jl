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
# before this check, the two rows also collided in `_insert_join`'s dedup tuple (`JoinRow.b`
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
  # as the JOIN target (`CteJoin.b`). Since #394 that second site quotes ESCAPE-ONLY, because
  # every other thing landing in that slot is a physical table name; checking here removes the
  # ordering dependency between the two renders entirely and puts the error on the call the user
  # wrote. `build_cte_clause` still quotes fail-closed as defence in depth. Same rule as `_cjoin_on`.
  _validate_identifier(name)
  # ...and the CTE side of the join key, for the same reason. `_build_row_join` stores it as
  # `CteJoin.key_b`, which since #394 is quoted escape-only because everything else in that slot
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
  # `_preset_cte_fields` stored it verbatim, `_build_row_join` copied it into `CteJoin.how`, and
  # Phase 2 interpolated it straight into `"$(value.how) JOIN …"`. So `join_type = "CROSS"` built
  # `CROSS JOIN … ON …` (invalid on both engines), and an arbitrary string reached the SQL text
  # unquoted — measured: `join_type = "LEFT OUTER JOIN cj_grand AS injected ON 1=1 --"` rendered
  # that clause verbatim ahead of the CTE's own JOIN. `_normalize_join_type` also upcases and
  # strips, so a lowercase `"inner"` now works here as it already did in `on()` and `cjoin_on()`.
  # ...but only the KEYED arm of `_build_row_join` ever reads this value; an unkeyed CTE is a
  # `CrossJoin` by construction, a kind with no join type at all. So `join_type = "CROSS"`
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
  # A second reason it stays, narrower since #508 phase 2: the expression nodes are immutable now, so
  # `g.operand = g` on an internal `FExpression` is no longer one assignment away — that route is
  # closed by the type. What survives is the same container cycle arriving INDIRECTLY: `FObject.column`
  # admits `SQLTypeQ`/`SQLTypeQor` (`types.jl`), so a cyclic `Q` nested inside a function still reaches
  # this walk. Be precise about what it buys, though: it protects **`cjoin_on`**, the
  # one caller that reaches this sweep WITHOUT going through `_prefix_join_filter`. It does NOT make
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
# #508 phase 2 — CONSTRUCTS. `::FObject` rather than `::SQLTypeFunction`: `WindowFunction` is the
# only other subtype and it has always had its own method below, so the abstract signature never
# served anything else.
function _retag_cte_string(x::FObject, q::SQLObject, rewrote::Set{String})
  return FObject(function_name=x.function_name, column=_retag_cte_string(x.column, q, rewrote),
                 aggregate=x.aggregate, formatter=x.formatter, _as=x._as, kwargs=x.kwargs)
end
# `::SQLField`, not `::SQLTypeField` — see the twin note in `_retag_cte_column` (`build_helpers.jl`).
# `SQLField` is a build product and stays mutable, so this arm still writes.
function _retag_cte_string(x::SQLField, q::SQLObject, rewrote::Set{String})
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
# #508 phase 2 — the vectors were mutated in place here; now the whole node is rebuilt, `over`
# included. The TYPED comprehensions are what replaces the old element-assignment trick: they
# produce a `Vector{WindowPartitionPart}` / `Vector{WindowOrderPart}` directly, where the `::Vector`
# arm below would return an `Any[]` that neither `WindowSpec` field accepts.
#
# A FRESH `WindowSpec`, not the caller's. `WindowSpec` is a container and stays mutable, so reusing
# it would put the rewritten entries into a spec the user may still hold and may have shared across
# two window functions in the same query — which is documented as supported (`WindowSpec`'s
# docstring). This is the one place a container being mutable actually mattered.
function _retag_cte_string(x::WindowFunction, q::SQLObject, rewrote::Set{String})
  over = WindowSpec(
    partition_by = WindowPartitionPart[_retag_cte_string(p, q, rewrote) for p in x.over.partition_by],
    order_by = WindowOrderPart[_retag_cte_string_window_order(o, q, rewrote) for o in x.over.order_by],
    frame = x.over.frame)
  return WindowFunction(function_name=x.function_name,
                        column=_retag_cte_string(x.column, q, rewrote),
                        over=over, aggregate=x.aggregate, formatter=x.formatter,
                        _as=x._as, kwargs=x.kwargs)
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
# #509 — an `SQLOrder` entry, the one window slot #492 left untouched. It was left alone because
# `SQLOrder` could not hold a CTE column in either spelling (`SQLOrder(CTE("ev","seen"))` was a
# `MethodError`), so there was nothing to rewrite INTO and firing the gate here would have printed a
# `CTE(...)` remedy the wrapper could not accept. #509 gave `SQLOrder` that constructor, so both
# halves are available now and this arm closes the corner:
#
#   • the SHADOWING case stops resolving silently. `SQLOrder("parent__sku")` inside a window's
#     `order_by` rendered against the ForeignKey with no error, while the identical string raised
#     `AmbiguousFieldError` in `values()`, in `partition_by` and in a bare `order_by` entry. That is
#     first-match precedence surviving in one corner, which is the class #431/#434/#492 remove.
#   • the UNAMBIGUOUS case now resolves to the CTE column instead of the model, so `SQLOrder` is no
#     longer the one ordering spelling a CTE column cannot reach.
#
# BOTH spellings of the wrapper's field are walked, not just the `String` one. `SQLField` is the
# form every doc example and every existing test writes (`SQLOrder(SQLField(f, f); nulls = :first)`),
# and it reaches the same silent resolution by the same route — covering only the `String` would fix
# the issue's repro and leave the commoner spelling broken.
#
# A leading `-` is deliberately NOT stripped here, unlike the bare-string arm above: an `SQLOrder`
# carries its direction in `orientation`, so `"-ev__seen"` inside one would be a second spelling for
# a slot that already has one. `nulls`, `order`, `_as` and `orientation` all ride across untouched.
#
# CONSTRUCTS, never mutates: this node arrived through the public API, so it is replaced rather than
# written into (the standing contract above, and #508's half of it).
function _retag_cte_string_window_order(x::SQLTypeOrder, q::SQLObject, rewrote::Set{String})
  # #533 removed the `x.field isa String` branch that stood here. `SQLOrder.field` is `SQLTypeField`
  # now, so a String is normalized into an `SQLField` by `_order_field` at CONSTRUCTION and reaches
  # this walker as one: `SQLOrder("ev__sku")` takes the branch below, where `_bind_cte_string!`
  # resolves the same CTE path.
  #
  # ONE BEHAVIOUR CHANGED WITH IT, and it is not cosmetic — found by review, and recorded here
  # because the first draft of this comment claimed the opposite. The deleted branch also pushed the
  # output spelling onto the CALLER's `rewrote` set, which is what tagged the enclosing projection
  # `root = :cte`; `_bind_cte_string!` keeps its own set and never reaches that one. So when a
  # projection is ALIASED with the same string the window orders by —
  # `values("ev__seen" => Rank(over = WindowOver(order_by = [SQLOrder("ev__seen")])))` — that
  # projection's memo root moves from `:cte` to `:base`, and a later `filter("ev__seen" => …)`
  # resolves the CTE COLUMN instead of reusing the projection. Measured:
  #
  #     before:  WHERE RANK() OVER (ORDER BY "R1_1"."seen" ASC) = ?
  #     after:   WHERE "R1_1"."seen" = ?
  #
  # The new rendering is the correct one — a window function is not legal in `WHERE` on either
  # backend — and it makes this spelling agree with `SQLOrder(CTE("ev","seen"))`, which has always
  # rendered the column. The BARE-STRING entry (`order_by = ["ev__seen"]`) still reuses the
  # projection, so the three spellings are two-to-one rather than unanimous; that inconsistency
  # predates #533 and is deliberately not addressed here.
  #
  # Pinned by "a window SQLOrder over a CTE path resolves the column, not the projection" in
  # `test_cte_reference.jl`.
  #
  # #757 refuses that alias at `values()` (an alias cannot contain `__`), so the aliased shape above
  # can no longer be written. The note stays because the rule it records still holds for the
  # unaliased spellings.
  if x.field isa SQLField
    # `_bind_cte_string!` is the same per-field entry the top-level `q.order` loop uses, so the
    # window and the fluent `order_by` agree on what a CTE-rooted path means.
    #
    # It WRITES into the `SQLField` it is handed, hence the copy — which is DEFENSIVE, not
    # demonstrated, and saying so is the point of this comment. Measured: removing the `deepcopy`
    # turns no test red and leaves the caller's node unmutated anyway, because every read path
    # deepcopies the handler before `build()` and Julia's generic walk clones `q.values`/`q.order`
    # wholesale rather than routing through the shallow `Base.deepcopy(::SQLTypeField)` method. So
    # the caller's `SQLField` never actually reaches this walker today.
    #
    # It stays because that protection is a property of the CALL PATH, not of this function, and
    # this function is the one that writes. It costs one shallow copy per window ORDER BY entry.
    # Its reach used to be partial: `deepcopy(::SQLTypeField)` rebuilds the wrapper while SHARING
    # whatever `.field` holds, so reassigning that slot on the copy protected a `String` terminal —
    # what every `SQLOrder(SQLField(f, f))` in the docs and the suite carries — but not a nested
    # mutable node such as an `FObject` from a `__@` transform, which the function arm rewrote in
    # place. #508 phase 2 closed that gap from the other side: `FObject` is immutable and
    # `_retag_cte_string`'s function arm constructs, so there is no in-place write left for the
    # shallow copy to fail to cover.
    return SQLOrder(_bind_cte_string!(deepcopy(x.field), q),
                    x.order, x.orientation, x._as, x.nulls)
  end
  return x
end
# Everything else — a `CTEReference`, a `JoinedReference`, anything not a column path — is left as
# it arrived; those have their own arms or need none.
_retag_cte_string_window_order(x, q::SQLObject, rewrote::Set{String}) = x
function _retag_cte_string(x::SQLTypeOper, q::SQLObject, rewrote::Set{String})
  return OperObject(operator=x.operator, values=x.values,
                    column=_retag_cte_string(x.column, q, rewrote))
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
#
# #757 refuses a `__` alias at `values()`, so the first bullet's `"ev__sku"` alias can no longer be
# written. The `_as` test stays: it is still what separates a transform suffix from a CTE column.
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
  # `custom_join` conditions are refused where they are bound (`_bind_join_conditions!`, #977): stored
  # as written, they are not yet lowered onto their path here.
  for (alias, cfg) in q.alias_join
    for f in cfg.filters
      _refuse_cte_string_in_join(f, q, "a cjoin_on `on` expression")
    end
  end
  return q
end

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
function _off_path_rhs_paths(x, q::SQLObject, path::String, depth::Int; f_slot::Bool = false)
  depth > 32 && return nothing
  if x isa String
    _check_rhs_relation(x, q, path; spelled = f_slot ? "F(\"$(x)\")" : "\"$(x)\"")
  elseif x isa FExpression
    _off_path_rhs_paths(x.field_name, q, path, depth + 1; f_slot = true)
    _off_path_rhs_paths(x.column, q, path, depth + 1; f_slot = true)
    _off_path_rhs_paths(x.operand, q, path, depth + 1)
  elseif x isa FObject
    x.aggregate && return nothing
    _off_path_rhs_paths(x.column, q, path, depth + 1)
    for v in values(x.kwargs)
      v isa Union{SQLTypeFunction,FExpression} && _off_path_rhs_paths(v, q, path, depth + 1)
    end
  elseif x isa SQLField
    _off_path_rhs_paths(x.field, q, path, depth + 1)
  elseif x isa OperObject
    # A `When` inside a function: its column is a column, its `values` literals unless an expression.
    _off_path_rhs_paths(x.column, q, path, depth + 1)
    _is_rhs_expression(x.values) && _off_path_rhs_paths(x.values, q, path, depth + 1)
  elseif x isa SubqueryObject
    _off_path_outer_refs(getfield(x.query, :object), q, path)
  elseif x isa SQLObjectHandler   # an `@in` subquery, passed as the query itself
    _off_path_outer_refs(getfield(x, :object), q, path)
  elseif x isa AbstractVector && !(x isa AbstractVector{UInt8})
    for v in x; _off_path_rhs_paths(v, q, path, depth + 1); end
  end
  return nothing
end

# The `OuterRef`s of one subquery, from every slot that can hold an expression. Not descended: a nested
# subquery, whose own `OuterRef`s name ITS enclosing query (the inner one), not this statement.
function _off_path_outer_refs(inner::SQLObject, q::SQLObject, path::String)
  refs = String[]
  slots = Any[inner.values, inner.filter, [o.field for o in inner.order]]
  for cfg in values(inner.custom_join); push!(slots, cfg.filters); end
  for cfg in values(inner.alias_join); push!(slots, cfg.filters); end
  for s in slots; _collect_outer_refs!(refs, s, 0); end
  for r in refs
    _check_rhs_relation(r, q, path; spelled = "OuterRef(\"$(r)\")")
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
# row it names — #917 refuses it at render (`build_query.jl`, "cannot appear in a join's ON clause")
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


"""
Build CTE (WITH clause) SQL string from the CTEs defined in the query object.

# Arguments
- `ctes::OrderedDict{String, CTEDict}`: CTE name => fields dict. ORDERED, and the order is the
  declaration order of the `.with(...)` calls — iterating it here is what fixes the emitted WITH
  clause, so the same query renders the same SQL on every run and every Julia version. See the
  `ctes` field comment in `types.jl` for why a plain `Dict` was not enough.
- `connection`: Database connection for quoting identifiers
- `parameters`: Parameterized query object to collect all parameters

# Returns
- String containing the WITH clause SQL, or empty string if no CTEs
"""
function build_cte_clause(ctes::OrderedCollections.OrderedDict{String,CTEDict}, connection, parameters::Union{Nothing,AbstractPormGParam}, table_alias::Union{Nothing,SQLTableAlias})
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


# #812 — the type of a CTE column projected from `Case`/`When`, resolved the way Django's
# `Expression._resolve_output_field` does it: `output_field=` wins (handled by the caller); otherwise
# every `then` and the `else` is resolved to a field, the NULL sentinels are skipped, and the fields
# must agree. What they cannot agree on is REFUSED, not guessed.
#
# The guess this replaces typed every branch by `isa Integer`/`isa Number`/`isa AbstractString` and
# fell back to `CharField`, so an expression branch (`then = Rank(…)`, `then = F("points")`) and the
# `Case` default itself — the STRING `"NULL"` — made a numeric column text. The outer filter then
# bound `"10"` for `c__top__@gt => 10`, and on SQLite, where neither a computed CTE column nor a
# parameter has type affinity and INTEGER sorts below TEXT, that drops every row with no error.
# It also collected no `then` at all from a single bare `Case(When(…))` or from
# `When(…, otherwise = x)`, whose CASE holds ONE `WHEN` node rather than a vector of them.
function _case_output_field(func::SQLTypeFunction, field::String, instruct::SQLInstruction)
  outputs = Any[]
  if func.function_name == "WHEN"
    push!(outputs, func.kwargs["then"])
  else
    for branch in (func.column isa AbstractVector ? func.column : (func.column,))
      # A `Case` holds `When` nodes; anything else (a `When(…; otherwise = …)`, which is already a
      # CASE, or a nested `Case`) renders no `THEN`, so there is no branch value to type.
      (branch isa SQLTypeFunction && branch.function_name == "WHEN") ||
        _refuse_case_type(field, "a Case branch is not a bare When(…)")
      push!(outputs, branch.kwargs["then"])
    end
    push!(outputs, get(func.kwargs, "else", missing))
  end

  fields = PormGField[]
  for value in outputs
    # `Value(missing)` is a NULL too — unwrap it before the check, not after.
    _is_null_literal(value isa SQLText ? value.field : value) && continue
    push!(fields, _case_value_field(value, field, instruct))
  end
  isempty(fields) && _refuse_case_type(field, "every branch is NULL, so there is no type to infer")
  return _unify_case_fields(fields, field)
end

# A literal types by its Julia type; `Bool` first, because `true isa Integer`.
_case_value_field(::Bool, ::String, ::SQLInstruction) = Models.BooleanField()
_case_value_field(::Integer, ::String, ::SQLInstruction) = Models.IntegerField()
_case_value_field(::Number, ::String, ::SQLInstruction) = Models.FloatField()
_case_value_field(::AbstractString, ::String, ::SQLInstruction) = Models.CharField()
_case_value_field(v::SQLText, field::String, instruct::SQLInstruction) = _case_value_field(v.field, field, instruct)
_case_value_field(v::WindowFunction, field::String, instruct::SQLInstruction) =
  _set_field_from_sql_function(v, field, instruct)
_case_value_field(v::JoinedReference, field::String, instruct::SQLInstruction) =
  _set_field_from_sql_function(v, field, instruct)
function _case_value_field(v::SQLTypeFunction, field::String, instruct::SQLInstruction)
  # A declared type, a nested CASE and the aggregates are what the CTE typing already knows how to
  # read; anything else would die on the generic "not a recognized function", which says nothing
  # about the `output_field=` that would fix it.
  _is_typed_function(v, instruct) ||
    _refuse_case_type(field, "a branch is \e[31m$(v.function_name)\e[0m(…), whose result type PormG does not infer")
  return _set_field_from_sql_function(v, field, instruct)
end
_is_typed_function(v::SQLTypeFunction, instruct::SQLInstruction) =
  _declared_type(v, instruct) !== nothing || v.function_name in _CTE_TYPED_FUNCTIONS
_case_value_field(v::FExpression, field::String, instruct::SQLInstruction) =
  _f_expression_field(v, field, instruct, _refuse_case_type)
_case_value_field(v, field::String, ::SQLInstruction) =
  _refuse_case_type(field, "a branch is a $(nameof(typeof(v))), whose type PormG does not infer")

# A bare `F("points")` is that column. Arithmetic keeps a number a number — both sides integral stays
# an integer (SQL integer arithmetic does, on both engines), otherwise a float — and anything else
# (`F("date") + Day(1)`) is refused rather than given the column's type, as `_expression_formatter`
# (build_query.jl) declines to type it too.
#
# #823: one rule for a `Case` branch and for an `F` projected at the top of a CTE body, so the refusal
# is a parameter — `refuse(field, reason)` — and the message names what the caller wrote: a `Case`
# (`_refuse_case_type`) or the bare expression (`_refuse_projection_type`). The operands receive it
# too, so a refusal nested inside a top-level `F` never reports itself as a Case.
function _f_expression_field(v::FExpression, field::String, instruct::SQLInstruction, refuse)
  if v.operation === nothing
    v.column isa String || refuse(field, "it is an F(…) over more than one column")
    return _set_field_from_sql_function(v.column, v.column, instruct)
  end
  left = _f_operand_field(v.field_name, field, instruct, refuse)
  right = _f_operand_field(v.operand, field, instruct, refuse)
  if _is_number_field(left) && _is_number_field(right)
    return _is_integral_field(left) && _is_integral_field(right) ? Models.IntegerField() : Models.FloatField()
  end
  refuse(field, "it is F(…) arithmetic ($(v.operation)) on a value that is not a number")
end

# Inside `F` arithmetic a `String` is a column path, not a text literal. A number, a window, a joined
# column and a function the CTE typing knows type as a `Case` branch does; anything else is refused.
_f_operand_field(x::String, ::String, instruct::SQLInstruction, refuse) = _set_field_from_sql_function(x, x, instruct)
_f_operand_field(x::Number, field::String, instruct::SQLInstruction, refuse) = _case_value_field(x, field, instruct)
_f_operand_field(x::SQLText, field::String, instruct::SQLInstruction, refuse) =
  x.field isa Number ? _case_value_field(x.field, field, instruct) :
  refuse(field, "an operand is a Value of type $(nameof(typeof(x.field))), which is not a number")
_f_operand_field(x::FExpression, field::String, instruct::SQLInstruction, refuse) =
  _f_expression_field(x, field, instruct, refuse)
_f_operand_field(x::WindowFunction, field::String, instruct::SQLInstruction, refuse) =
  _set_field_from_sql_function(x, field, instruct)
_f_operand_field(x::JoinedReference, field::String, instruct::SQLInstruction, refuse) =
  _set_field_from_sql_function(x, field, instruct)
function _f_operand_field(x::SQLTypeFunction, field::String, instruct::SQLInstruction, refuse)
  _is_typed_function(x, instruct) ||
    refuse(field, "an operand is \e[31m$(x.function_name)\e[0m(…), whose result type PormG does not infer")
  return _set_field_from_sql_function(x, field, instruct)
end
_f_operand_field(x, field::String, ::SQLInstruction, refuse) =
  refuse(field, "an operand is a $(nameof(typeof(x))), whose type PormG does not infer")

# The functions `_set_field_from_sql_function(::SQLTypeFunction, …)` types without a declared type.
const _CTE_TYPED_FUNCTIONS = ("CASE", "WHEN", "COUNT", "SUM", "AVG", "MIN", "MAX")

_is_number_field(f::PormGField) = hasproperty(f, :formatter) && f.formatter === Models.format_number_sql
_is_integral_field(f::PormGField) = f isa Union{Models.sIntegerField, Models.sBigIntegerField,
  Models.sPositiveSmallIntegerField, Models.sPositiveIntegerField, Models.sIDField, Models.sForeignKey,
  Models.sOneToOneField}

# Fields of one struct type agree; numbers promote as they always have (all integral → integer,
# otherwise float); text-with-text and the other same-formatter families keep the first field. Two
# families refuse — there is no type both branches are.
#
# Two keys agree only when they point at the same parent: the outer query can traverse a CTE key
# column (`c__who__surname`), and `F("driverid")` beside `F("constructorid")` typed as the FIRST key
# would join constructor ids to drivers. They fall through to the numeric arm instead — a plain
# integer column, which refuses the traversal rather than answer it wrongly.
function _unify_case_fields(fields::Vector{PormGField}, field::String)
  first_field = fields[1]
  all(f -> typeof(f) === typeof(first_field) && _same_key_target(f, first_field), fields) && return first_field
  if all(_is_number_field, fields)
    return all(_is_integral_field, fields) ? Models.IntegerField() : Models.FloatField()
  end
  formatter = hasproperty(first_field, :formatter) ? first_field.formatter : nothing
  if formatter !== nothing && all(f -> hasproperty(f, :formatter) && f.formatter === formatter, fields)
    return first_field
  end
  other = fields[findfirst(f -> !(hasproperty(f, :formatter) && f.formatter === formatter), fields)]
  _refuse_case_type(field, "its branches have different types " *
    "(\e[31m$(_field_label(first_field))\e[0m and \e[31m$(_field_label(other))\e[0m)")
end

_key_target(f::PormGField) = (f.to isa PormGModel ? f.to.name : f.to, f.pk_field)
_same_key_target(a::PormGField, b::PormGField) =
  !(a isa Union{Models.sForeignKey,Models.sOneToOneField}) || isequal(_key_target(a), _key_target(b))

# `IntegerField`, as the caller spells the constructor — not the `sIntegerField` struct behind it.
_field_label(f::PormGField) = chopprefix(string(nameof(typeof(f))), "s")

function _refuse_case_type(field::String, reason::String)
  throw(QueryBuildError(
    "The CTE column \e[4m\e[31m$(field)\e[0m is a Case whose type cannot be inferred: $(reason). " *
    "Name the type the column holds with \e[32moutput_field\e[0m — e.g. " *
    "\e[32mCase(…; output_field = CharField())\e[0m — so a filter on the column binds its value as " *
    "that type (#812)."))
end

# #823: the twin of `_refuse_case_type` for an expression projected directly. There is no `Case` to
# give an `output_field`, so the fix it names is `Cast` — or, for a shape `Cast` does not take
# (`Exists`), projecting it in the outer query instead of the body. `Cast` takes a `Subquery` since
# #878, so a bare one is told to wrap itself.
const _CAST_HINT = "Name the type the column holds by wrapping the expression in " *
                   "\e[32mCast(…, \"integer\")\e[0m (or the type it returns)"
function _refuse_projection_type(field::String, reason::String; hint::String = _CAST_HINT)
  throw(QueryBuildError(
    "The CTE column \e[4m\e[31m$(field)\e[0m cannot be typed: $(reason). $(hint), so a filter on " *
    "the column binds its value as that type (#823)."))
end

# The type a function declares — `output_field=` on `Case`/`Coalesce`/`Concat`/`Greatest`/`Least`,
# `type` on `Cast` — as a field, or `nothing` when it declares none. A declared type outside the
# families `_sql_type_field` (build_query.jl) recognises is refused rather than dropped: the caller
# named it, and falling back to inference would quietly override them.
#
# A declared type is believed because the SQL applies it on both engines: `Cast` and `Case` render
# their cast (`date(x)` for a date on SQLite, #822), and since #852 so do `Coalesce`, `Greatest` and
# `Least` (`Dialect._output_field_cast`). Those three were refused a `date` on SQLite until then —
# they rendered no cast there, so the column held the operand's text (a timestamp, say) and a date
# filter on it matched nothing, the #812 silent-empty result. A temporal type with no exact SQLite
# rendering never reaches this function: the body's SELECT raises `BackendCapabilityError` first.
# `Concat` renders no cast on EITHER engine, so its constructor refuses any non-text type (#835).
function _declared_type(func::SQLTypeFunction, instruct::SQLInstruction)
  declared = get(func.kwargs, func.function_name == "CAST" ? "type" : "output_field", nothing)
  (declared isa AbstractString && !isempty(declared)) || return nothing
  typed = _sql_type_field(declared)
  # #929: `uuid`/`inet`/`cidr` became nameable for the alias filter, on PostgreSQL. They stay refused
  # on SQLite, where they were refused before: there each cast renders `CAST(x AS TEXT)`, so typing the
  # column would check — and normalize — its filter values against a type the engine never applied.
  sqlite = instruct.connection isa PormGSQLite
  (typed === nothing || (sqlite && _text_cast_on_sqlite(typed))) && throw(QueryBuildError(
    "A CTE column cannot be typed from the SQL type \e[4m\e[31m$(declared)\e[0m on " *
    "$(func.function_name)(…). Name a text, integer, bigint, float, numeric, boolean or date type" *
    "$(sqlite ? "" : ", or uuid / inet / cidr") instead (#812, #823, #929)."))
  return typed
end


function _set_field_from_sql_function(func::SQLTypeFunction, field::String, instruct::SQLInstruction)
  # #812: a declared type wins over anything inferred — it is also what the SQL casts the value to.
  declared = _declared_type(func, instruct)
  declared === nothing || return declared

  if func.function_name in ["CASE", "WHEN"]
    return _case_output_field(func, field, instruct)
  end

  if !(func.function_name in ["COUNT", "SUM", "AVG", "MIN", "MAX"])
    throw(QueryBuildError("Error in _set_field_from_sql_function, the function \e[4m\e[31m$(func.function_name)\e[0m is not a recognized function. Allowed: \e[4m\e[32mCOUNT, SUM, AVG, MIN, MAX, CASE, WHEN\e[0m " *
      "— or name the column's type by wrapping it in \e[32mCast(…, \"text\")\e[0m (or the type it returns) (#812)."))
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
# #685 — a CTE body that projects a window function. More specific than the `::SQLTypeFunction` arm
# above, whose name allow-list refused every window with "RANK is not a recognized function" — which
# made the CTE route the #537 refusal recommends for filtering on a window unreachable. The column
# type is not a guess: the ranking functions (`RANK`, `DENSE_RANK`, `ROW_NUMBER`) carry no column
# and return an integer, typed as `COUNT` is; the value functions (`LAG`, `LEAD`, `FIRST_VALUE`,
# `LAST_VALUE`, `NTH_VALUE`) return a value OF their column, so they type as that column.
#
# The column is passed as both arguments on purpose. The `::String` arm looks its SECOND argument up,
# which for a plain projection is the path and the alias at once; here the second argument would be
# the window's alias (`prev`), which names nothing on the model.
function _set_field_from_sql_function(func::WindowFunction, field::String, instruct::SQLInstruction)
  column = func.column
  column === nothing && return IntegerField()
  column isa String && return _set_field_from_sql_function(column, column, instruct)
  column isa Union{JoinedReference,SQLTypeFunction} && return _set_field_from_sql_function(column, field, instruct)
  # #887: a window over a subquery has the subquery's type, which a CTE body cannot infer (#878's
  # reason). `Cast` inside the window names it, and the `SQLTypeFunction` arm above types that.
  column isa SubqueryObject && _refuse_projection_type(field,
    "it is $(func.function_name) over Subquery(…), whose type PormG does not infer";
    hint = "Name the type inside the window, e.g. \e[32mLag(Cast(Subquery(…), \"integer\"), over = …)\e[0m " *
           "(or the type it returns)")
  throw(QueryBuildError(
    "A CTE column cannot be typed from \e[4m\e[31m$(func.function_name)\e[0m over a " *
    "$(nameof(typeof(column))) argument. Project the window over a field path instead (#685)."))
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
# #823 — an `F` projected at the top of a CTE body (`"half" => F("year") / 2`) types as a `Case`
# branch does. Without this method it reached no arm here and died as a raw MethodError.
_set_field_from_sql_function(v::FExpression, field::String, instruct::SQLInstruction) =
  _f_expression_field(v, field, instruct, _refuse_projection_type)
# #823 — every other shape a body can project (`Subquery`, `Exists`, …) has no type PormG infers, and
# is refused by name rather than left to a MethodError. #878: `Cast(Subquery(s), type)` builds and is
# typed by the type it names, so a bare `Subquery` is pointed at that; the rest — which `Cast` does not
# take — at the outer query.
_set_field_from_sql_function(v::SubqueryObject, field, ::SQLInstruction) =
  _refuse_projection_type(string(something(field, "?")),
                          "it is Subquery(…), whose type PormG does not infer";
                          hint = "Name the type the column holds by wrapping it in " *
                                 "\e[32mCast(Subquery(…), \"integer\")\e[0m (or the type it returns)")
_set_field_from_sql_function(v, field, ::SQLInstruction) =
  _refuse_projection_type(string(something(field, "?")),
                          "it is $(chopsuffix(string(nameof(typeof(v))), "Object"))(…), whose type PormG does not infer";
                          hint = "Project it in the outer query instead of the CTE body")

# #823 — a `Value(x)` projection. `values` holds the `SQLText` itself, whose `field` is the literal
# and whose `_as` is `nothing`, so it never reached a `_set_field_from_sql_function` arm. A literal
# types by its Julia type, as a `Case` branch does — but only the types `_infer_parameter_sql_type`
# gives a PostgreSQL bind cast (`Integer`, `Bool`, `AbstractFloat`, `AbstractString`). Any other
# `Number` (`pi`, `1//2`) binds as a bare `$1`, which PostgreSQL resolves as TEXT: typing that column
# a float would bind a number against text, the #812 mismatch. A NULL has no type, and any other
# literal (a `Date`, bound as text on SQLite) is refused rather than guessed.
function _value_projection_field(v::SQLText, field::String, instruct::SQLInstruction)
  v.field isa Union{Integer,AbstractFloat,AbstractString} && return _case_value_field(v.field, field, instruct)
  _refuse_projection_type(field, v.field === nothing || v.field === missing ? "it is a NULL Value, which has no type" :
                                 "it is a Value of type $(nameof(typeof(v.field))), whose type PormG does not infer")
end
# `values("resultid", Value(1))` — no alias, so the column has no name for the outer query to use.
_value_projection_field(::SQLText, ::Nothing, ::SQLInstruction) = throw(QueryBuildError(
  "A Value(…) projected in a CTE body needs an alias — e.g. \e[32m\"flag\" => Value(1)\e[0m — so the " *
  "outer query can name the column (#823)."))

function _build_cte_custom_model(cte::CTEDict, instruct::SQLInstruction)
  values = instruct.object.values
  # Ordered to satisfy `Model_Type.fields` (#544), and meaningfully so: the loop below walks
  # `instruct.object.values` in the order the caller selected them, so the synthetic CTE model now
  # describes its columns in that same order instead of a hash of the aliases.
  fields = OrderedCollections.OrderedDict{String,PormGField}()
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
      typed = value_part isa SQLText ? _value_projection_field(value_part, key_new, instruct) :
              _set_field_from_sql_function(value_part.field, value_part._as, instruct)
      fields[key_new] = Models.field_without_db_column(typed)
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