# Resolving a field path to its join (#130): generated join aliases and `_insert_join`, spotting an
# operator token inside a path (`_check_if_field_is_a_operator`), the join type and field a segment
# follows, `_unknown_field` and `_solve_field`; and the SQL type a bound parameter is cast to.

# The next free generated alias (`<base>_<n>`) for a join row.
#
# #480 — it steps around every alias the caller DECLARED, not only the ones already materialized.
# `cjoin_on` rows are built in `build()`'s ALIAS materialization loop, after `values()` /
# `filter()` / `order_by()` have already resolved their joins, and `_build_cjoin_on_row_join`
# writes the user's alias straight into `alias_b`. So when this function chose `R1_1` for a CTE or
# ForeignKey join, no `cjoin_on(alias = "R1_1")` was in `row_join` yet to be avoided, and the
# statement ended up with two range variables of one name — invalid on both engines, and where an
# engine did resolve it, the projection and the ON clause named different relations. The declared
# aliases all sit in `object.alias_join` before `build()` starts, which is early enough.
function _get_alias_name(instruct::SQLInstruction)::String
  return _get_alias_name(instruct.row_join, instruct.alias, _declared_join_aliases(instruct.object))
end
function _get_alias_name(row_join::Vector{JoinRow}, alias::String,
                         reserved::Vector{String}=String[])::String
  taken = vcat([r.alias_a for r in row_join], [r.alias_b for r in row_join], reserved)
  count = 1
  while true
    alias_name = alias * string("_", count)
    in(alias_name, taken) || return alias_name
    count += 1
  end
end

# #480 — every `cjoin_on` alias declared on the query, materialized or not. Since #484 that is
# exactly `alias_join`'s key set: `cjoin` and `on()` entries live in `custom_join`, keyed by PATH
# rather than by an alias they introduce, and their joins get generated aliases like any ForeignKey
# hop.
_declared_join_aliases(object::SQLObject)::Vector{String} = collect(keys(object.alias_join))

# `track_path = false` (#474) records the join WITHOUT claiming its name in `row_path`. A CTE hop
# uses it: `row_path` exists so `build()`'s PATH materialization loop can skip a `custom_join` entry
# that traversal already built, and a CTE has no `custom_join` entry — so a CTE hop registering its
# own name there could only ever suppress an unrelated user join that happened to share it. A
# `cjoin_on` row uses it for the same reason since #484 — an alias is not a path, so it has no
# business claiming a name in the PATH membership set. Nothing indexes `row_path` positionally (its
# one remaining reader is an `∉` membership test), so the two vectors do not have to stay the same
# length.
function _insert_join(
  row_join::Vector{JoinRow},
  row::JoinRow,
  row_path::Vector{String}, join_path::String; track_path::Bool=true)
  @pormg_debug false
  if size(row_join, 1) == 0
    push!(row_join, row)
    track_path && push!(row_path, join_path)
    return row.alias_b
  else
    # The tuple has no CTE-vs-physical discriminator on purpose (#479): a CTE row and a model row
    # agree on `b` only when a CTE is named after a physical table, and `_with` refuses that at
    # declaration for every table reachable from the registered models. SQL would resolve both
    # joins to the CTE anyway, so keeping such rows apart here could only ever render a second
    # join that reads the wrong relation — a discriminator would not fix the shape, only hide it.
    # #487 kept that when the rows became typed: `_dedup_key` (`types.jl`) is the same
    # `(a, b, key_a, key_b, alias_a)` tuple, with the kind deliberately left out of it.
    key = _dedup_key(row)
    check = filter(r -> _dedup_key(r) == key, row_join)
    if size(check, 1) == 0
      @pormg_debug false
      push!(row_join, row)
      track_path && push!(row_path, join_path)
      return row.alias_b
    else
      if size(check, 1) > 1
        # #197: was `throw("Error in join")` — a raw String with zero context. This branch means
        # the dedup filter matched the same (a, b, key_a, key_b, alias_a) join row more than once,
        # which the dedup invariant forbids.
        error(_emsg("PormG internal error in _insert_join: duplicate deduplicated join rows for $(row.a) → $(row.b) (alias $(row.alias_a)) — please report this."))
      end
      return check[1].alias_b
    end
  end
end

# #619: the names the hint may mention but PormG does not implement, mapped to the nearest spelling
# that does work. This is a MESSAGE table, not a registry — nothing dispatches on it, and membership
# here grants no behavior. It exists so "there is no such lookup" can still be useful for the names
# where a real alternative exists. `test/unit/test_operators.jl` asserts every key is unreachable
# from both registries, so an entry cannot outlive the wiring of its own name.
const UNIMPLEMENTED_LOOKUP_HINTS = Dict{String,String}(
  # Worded as the affirmative it is: `exact` is the ONE name here whose behaviour PormG has, just
  # under no lookup spelling at all. "no spelling of it works — a bare `field => value` already IS
  # an exact match" read as a contradiction, so this entry says what to write instead of what fails.
  "exact"        => "write it as a bare `field => value`, which already IS an exact match",
)

function _check_if_field_is_a_operator(field::String)
  # The pattern family comes from the shared constant (#604) rather than a literal copy — this list
  # named `istartswith`/`iendswith` while `PormGsuffix` did not, so it told the user to add the `@`
  # and the `@` spelling then raised a FilterError of its own. The rest stays literal on purpose:
  # this is the "you forgot the `@`" hint, not the lookup registry, so it also spans transforms.
  #
  # #619: it also names Django lookups PormG implements nowhere — keys of neither `PormGsuffix`
  # nor `PormGtransform` — and for those it used to instruct a spelling that then failed, which is
  # #604's own two-step dead end surviving 11 more times. The MEMBERSHIP is deliberate and stays:
  # this is a near-miss hint, and a reader who typed `surname__week_day` is better served by being
  # told PormG has no such lookup than by the generic "no such field". Only the WORDING was wrong.
  # (`regex`/`iregex` were two of the 11 until #635 wired them, and `iexact` a third until #634;
  # they now arrive through PATTERN_LOOKUP_OPERATORS, and the reachability check below flips their
  # message by itself. #636 did the same for `hour`/`minute`/`second` and the four week parts
  # through `PormGtransform`.)
  common_operators = [PATTERN_LOOKUP_OPERATORS...,
    "exact", "in", "gt", "gte", "lt", "lte", "range", "nrange", "date", "isnull",
    "year", "iso_year", "quarter", "month", "day", "week", "week_day", "iso_week_day",
    "hour", "minute", "second", "search"]
  field in common_operators || return nothing

  # Reachability is COMPUTED from the registries, never listed a third time. That is the whole
  # defect-prevention: wiring a name into `PormGsuffix` or `PormGtransform` later flips its hint by
  # itself, so the two halves cannot drift the way the #604 list and `PormGsuffix` did. A second
  # hand-maintained list of "implemented" names would be the same bug wearing the fix's clothes.
  if haskey(PormGsuffix, field) || haskey(PormGtransform, field)
    throw(FilterError("The filter operator '\e[31m$field\e[0m' requires '@' prefix. Use '\e[32m$field\e[0m' => ... as part of '__\e[33m@$field\e[0m' syntax. Example: \e[36mq.filter(\"name__@$field\" => value)\e[0m"))
  end

  # No example here, on purpose: an example is a promise, and there is no spelling of this name that
  # builds a query.
  alternative = get(UNIMPLEMENTED_LOOKUP_HINTS, field, "")
  throw(FilterError("PormG has no '\e[31m$field\e[0m' lookup, so no spelling of it works" *
                    (isempty(alternative) ? "." : " — $alternative.")))
end

# #474: `"CROSS"` is NOT in this list, and its absence is the fix rather than an oversight. Every
# consumer of this function feeds a `ModelJoin`/`CteJoin`/`AnchorlessJoin`'s `how`, and Phase 2 of
# `build_row_join_sql_text` emits `"$(value.how) JOIN $b AS $alias ON $on_clause"` for every one of
# those kinds unconditionally — so an accepted `"CROSS"`
# could only ever render `CROSS JOIN … ON …`, which BOTH PostgreSQL and SQLite reject. Measured on
# all three writers before removal: `cjoin_on(join_type="CROSS")`, `on(join_type="CROSS")` and a
# `field.how` of `"CROSS"` each produced that statement. It was never documented either
# (`docs/src/api.md` has always listed only the four below).
#
# The one real CROSS JOIN PormG emits is an UNKEYED `.with(...)` that is REFERENCED — that path builds
# a `CrossJoin` in `build_joins.jl`, a kind with no join type at all, and Phase 2 short-circuits on it
# ahead of the `ON` render; it never comes through here. That is also the only supported spelling for a deliberate cross product, so the
# message points at it (and at the reference, not just the declaration: since #444 a `.with(...)`
# alone emits no join at all).
function _normalize_join_type(join_type::String)
  valid_joins = ["INNER", "LEFT", "RIGHT", "FULL"]
  normalized = uppercase(strip(join_type))
  if !(normalized in valid_joins)
    cross_hint = normalized == "CROSS" ?
      ("\n  A \e[4m\e[32mCROSS JOIN\e[0m cannot carry the \e[4m\e[32mON\e[0m clause this join " *
       "renders. For a deliberate cross product, declare the table as an UNKEYED " *
       "\e[4m\e[32m.with(\"n\" => sub)\e[0m and REFERENCE it — e.g. " *
       "\e[4m\e[32mvalues(\"x\" => CTE(\"n\", \"col\"))\e[0m — which emits a real CROSS JOIN and " *
       "warns that it is Cartesian (#44, #474).") : ""
    throw(QueryBuildError(
      "Invalid join type \e[4m\e[31m$(join_type)\e[0m. Valid types: " *
      "\e[4m\e[32m$(join(valid_joins, ", "))\e[0m.$(cross_hint)"))
  end
  return normalized
end

# The three readers below resolve a MODEL JOIN PATH, so they read the path namespace and only that
# (#484). A `cjoin_on` alias is unreachable from here by construction — it is not in this map — which
# is what makes the alias-equals-ForeignKey-name collision unrepresentable rather than guarded: this
# is the site that used to hand a ForeignKey hop the alias's ON clause and join type.
_get_join_config(q::SQLObject, join_path::String)::Union{PathJoin,Nothing} = get(q.custom_join, join_path, nothing)

function _get_join_field(q::SQLObject, join_path::String)
  config = _get_join_config(q, join_path)
  config === nothing && return nothing
  return config.field
end

# The one place an unknown field name becomes a typed error (#446).
#
# #612: this block sits ABOVE the docstring. Between it and `function`, it detached the docstring
# silently — `@doc` binds to the next expression and a comment is not one.
#
# Returns the exception; the call site throws it — the convention `test_docs_error_type_drift.jl`
# pins for `_unsupported_conn` / `_write_not_allowed` / `_fielderr`. A helper that threw internally
# would invite the mirror-image mistake at a returning one, where a forgotten `throw(` silently
# constructs an exception and lets execution continue past the guard.
#
# The choices are SORTED, and that is not cosmetic: `field_names` is declaration order, so on a wide
# model the name a user typo'd sits at an unpredictable offset in a 40-item line. Django sorts the
# same list in `names_to_path` for the same reason. Reverse accessors are listed too — they are
# addressable at exactly the same position in a path, so omitting them makes a legal name look
# unavailable.
#
# `include_accessors = false` is for the WRITE path (#462). A reverse accessor is addressable in a
# filter/values path but is not a column, so `create("results" => …)` can never work — listing them
# in a write error would advertise a capability that does not exist. Every read-path caller keeps
# the default.
function _unknown_field(model::PormGModel, name::AbstractString;
                       aliases::Vector{String} = String[],
                       include_accessors::Bool = true,
                       hint::String = "")::UnknownFieldError
  choices = sort(collect(model.field_names))
  accessors = include_accessors ? sort(collect(keys(model.related_objects))) : String[]
  tail = isempty(accessors) ? "" :
    "; and the reverse accessors: \e[4m\e[32m$(join(accessors, ", "))\e[0m"
  # A projection alias is addressable in exactly the same position as a field — `filter("tot__@gt")`
  # over a `Sum(...)` alias is the documented way to write HAVING — so a message that omitted them
  # would call a legal name unavailable. Django lists `annotation_select` alongside the fields for
  # the same reason.
  tail *= isempty(aliases) ? "" :
    "; and the declared aliases: \e[4m\e[32m$(join(sort(aliases), ", "))\e[0m"
  # #481 — a dotted name is almost always the removed `F("alias.col")` spelling rather than a column
  # anyone believes exists. Without this the reader is sent looking for a field named `d.surname`,
  # which is exactly the misdirection the fail-open resolver used to produce. It is a HINT on the
  # message, not a resolver: the name still does not exist and the error is still the same type.
  # Shaped like an alias reference — exactly one dot, with an identifier on each side. A looser
  # `occursin('.', name)` also fired on `"1.5"`, `"a.b.c"`, `".note"` and `"note."`, none of which
  # anyone wrote meaning a joined copy. A schema-qualified `"public.result"` still matches, and
  # that is accepted: it is indistinguishable from an alias reference by shape alone, and the hint
  # is additive text on an error the name earns either way.
  looks_like_alias_ref = occursin(r"^[\p{L}_][\p{L}\p{M}\p{N}_]*\.[\p{L}_][\p{L}\p{M}\p{N}_]*$", name)
  tail *= looks_like_alias_ref ?
    "\n  If you meant a \e[4m\e[32mcjoin_on\e[0m joined copy: \e[4m\e[31mF(\"alias.column\")\e[0m " *
    "was removed in #481 — write \e[4m\e[32mJoined(\"alias\", \"column\")\e[0m instead." : ""
  tail *= hint
  return UnknownFieldError(
    "the column \e[4m\e[31m$(name)\e[0m not found in \e[4m\e[32m$(Models.model_table_name(model))\e[0m, " *
    "that contains the fields: \e[4m\e[32m$(join(choices, ", "))\e[0m$(tail)")
end

# #566 — a subquery reaching for a CTE its ENCLOSING query declares. Correct to refuse: each query
# has its own CTE namespace (#444), so the inner build genuinely has no such CTE. But the bare
# refusal reads "declared CTEs: none" (or "column not found") while the caller can see the `.with()`
# two lines up, which looks like PormG lost the CTE rather than like a scoping rule. This names the
# rule. The whole `outer` chain is walked, not one level: a filter `Exists` nested in another filter
# `Exists` is legal, so the declaring query can be further up. Returns "" when no enclosing query
# declares `name`. It only ever changes a message, never which error is raised.
function _outer_cte_hint(instruct::SQLInstruction, name::AbstractString)::String
  outer = instruct.outer
  while outer !== nothing
    haskey(outer.object.ctes, name) && return (
      "\n  \e[4m\e[31m$(name)\e[0m is declared on an ENCLOSING query, and a subquery " *
      "(Subquery, Exists, __@in) has its own CTE namespace: it cannot see its parent's " *
      "\e[4m\e[32m.with(...)\e[0m (#444). Put the condition on the CTE in the enclosing query's " *
      "own \e[4m\e[32m.filter(...)\e[0m instead.")
    outer = outer.outer
  end
  return ""
end

# #1134 — a path whose LAST segment is a relation: a reverse accessor, a ManyToMany field, or the
# reverse side of one. It names a model, not a column, so there is nothing to select or compare.
# Before this it reached `_unknown_field`, which said the name was "not found" while listing it among
# the reverse accessors — and left a ManyToMany field out altogether, since `field_names` excludes
# them. The dedicated "is a reverse field" refusals in `_build_row_join` were meant for this, but
# could never fire: that function only ever receives two or more segments, and its loop only runs
# while two remain, so a path's last segment arrives at `_solve_field` — no hop, the first hop, or any
# later one. The one other place a last segment is resolved is a plain `filter(...)` key, which is
# tried as a projection alias first (`build_filter.jl`), so that branch asks this too.
#
# Still an `UnknownFieldError`: the path does not name a column, and a caller's handler for that
# kind of mistake keeps firing. Only the message changes, to the remedy.
#
# Returns `nothing` when `name` is not a relation of `model`; otherwise the exception, which the call
# site throws (the `_unknown_field` convention). `path` is the full path the caller wrote.
function _relation_terminal(model::PormGModel, name::AbstractString;
                            path::AbstractString = name)::Union{Nothing, UnknownFieldError}
  rel = get(model.related_objects, name, nothing)
  kind, target = if rel isa Models.ReverseRelation
    ("reverse relation", rel.model_resolved)
  elseif rel isa Models.ManyToManyRelation
    ("reverse ManyToMany accessor", something(rel.related_model_resolved, rel.related_model))
  elseif haskey(model.fields, name) && Models.is_many_to_many_field(model.fields[name])
    m2m = Models.has_many_to_many_accessor(model, String(name)) ?
      Models.get_many_to_many_relation(model, String(name)) : nothing
    ("ManyToMany field", m2m === nothing ? nothing : something(m2m.related_model_resolved, m2m.related_model))
  else
    return nothing
  end
  reaches = target isa PormGModel ? " to \e[4m\e[32m$(Models.model_table_name(target))\e[0m" :
            target isa AbstractString ? " to \e[4m\e[32m$(target)\e[0m" : ""
  # The example only for a single-column key. Not `Models.get_model_pk_field`, which THROWS on a
  # model with two primary-key fields — that would turn this refusal into a `ModelDefinitionError`.
  pks = target isa PormGModel ? [k for (k, f) in target.fields if f.primary_key] : String[]
  pk = length(pks) == 1 ? only(pks) : nothing
  example = pk === nothing ? "" : " (e.g. \e[4m\e[32m$(path)__$(pk)\e[0m)"
  return UnknownFieldError(
    "the path \e[4m\e[31m$(path)\e[0m ends at \e[4m\e[31m$(name)\e[0m, a $(kind) from " *
    "\e[4m\e[32m$(Models.model_table_name(model))\e[0m$(reaches), not a column. A relation needs a " *
    "column after it: \e[4m\e[32m$(path)__<column>\e[0m$(example).")
end

"""
This function checks if the given `field` is a valid field in the provided `model`. If the field is valid, it returns the field name, potentially modified based on certain conditions.
"""
function _solve_field(field::String, model::PormGModel, instruct::SQLInstruction; path::AbstractString = field)
  # check if last_column a field from the model
  if !(field in model.field_names)
    _check_if_field_is_a_operator(field)
    @pormg_debug false
    # #1134: a relation, not a typo — say so instead of "not found" beside a list that contains it.
    relation = _relation_terminal(model, field; path = path)
    relation === nothing || throw(relation)
    throw(_unknown_field(model, field))
  end
  # (instruct.django !== nothing && hasfield(model.fields[field] |> typeof, :to)) && (field = string(field, "_id"))

  # Resolve to the physical column (db_column when set, else the field name) and quote
  # it to prevent SQL injection (#50). SELECT auto-aliases back to the field name, so
  # rows stay keyed by the declared field name even when the column differs.
  return safe_column_identifier(Models.field_db_column(model.fields[field], field), instruct.connection)
end
_solve_field(field::String, _module::Module, model_name::Symbol, instruct::SQLInstruction; kw...) = _solve_field(field, getfield(_module, model_name), instruct; kw...)
_solve_field(field::String, _module::Module, model_name::String, instruct::SQLInstruction; kw...) = _solve_field(field, _module, Symbol(model_name), instruct; kw...)
_solve_field(field::String, _module::Module, model_name::PormGModel, instruct::SQLInstruction; kw...) = _solve_field(field, model_name, instruct; kw...)


# `_df_to_dic` used to live here — deleted in #197: it had zero callers and referenced an
# undefined variable (`filtro`), so it was both dead and broken.

# ---
# Build the SQLInstruction object
#

# select
function _infer_parameter_sql_type(value, instruc::SQLInstruction; fallback::Union{Nothing,String}=nothing)
  instruc.connection isa PormGPostgres || return nothing
  fallback !== nothing && return fallback
  value isa AbstractString && return "text"
  value isa Bool && return "boolean"
  value isa Integer && return "bigint"
  value isa AbstractFloat && return "double precision"
  value isa Dates.Date && return "date"
  value isa Dates.DateTime && return "timestamp"
  value isa Dates.Time && return "time"
  value isa Sockets.IPAddr && return "inet"   # #903 — bound as its text by `add_parameter!`
  return nothing
end

function _deferred_kwarg_sql_type(v::SQLTypeFunction, key::String, resolved_kwargs::Dict{String,Any}, instruc::SQLInstruction)
  value = v.kwargs[key]

  if key == "precision"
    return _infer_parameter_sql_type(value, instruc; fallback="integer")
  end

  output_field = get(resolved_kwargs, "output_field", nothing)
  if output_field isa AbstractString && !isempty(output_field)
    # #696: `output_field` becomes the bind cast `$n::<type>` here — a fourth place the type string
    # reaches the SQL text. The dialect helper validates it and gives the engine's spelling.
    instruc.connection isa PormGPostgres || return nothing
    return _infer_parameter_sql_type(value, instruc;
      fallback=Dialect.cast_type_sql(output_field, instruc.connection; context="output_field"))
  end

  return _infer_parameter_sql_type(value, instruc)
end
