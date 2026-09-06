# ─────────────────────────────────────────────────────────────────────────────
# Per-build memo access (#478)
#
# `InstructionObject` carries three memos, all keyed by `MemoKey` (`types.jl`):
#
#   cache             a resolved projection, by output name
#   tab_field_cache   the terminal field a path resolved to
#   json_lookup_paths the membership set of resolved JSON-lookup paths (#27)
#
# #474 gave them a typed key and stopped there. The ACCESS PATTERN was the remaining debt: ~40 call
# sites built their own key inline — in one of four spellings, plus 15 bare `(:base, x)` tuple
# literals — and then indexed the `Dict` directly. So the KEYING RULE (which namespace does this
# expression belong to?) was restated at forty sites instead of living at one. That is what made
# #474's original defect possible in the first place: a reader keyed by `_as` while its writer keyed
# by the namespaced key, and the two silently disagreed.
#
# The asymmetry that made it invisible, and the reason this file exists:
#
#   a bare-String WRITE to `Dict{MemoKey,V}` is a loud MethodError — `setindex!` calls
#   `convert(K, key0)` and no conversion exists;
#   a bare-String READ is a silent `false`/default — the memo simply misses, the expression
#   re-resolves, and in the collision case it resolves against the WRONG NAMESPACE and returns
#   valid SQL for the wrong column.
#
# So the entire residual risk of #474 lived in readers, where the failure is invisible. Every verb
# below is typed on `::MemoKey`, and Julia's dispatch — unlike `setindex!` — never converts its
# arguments: `String <: Tuple{Symbol,String}` is false, so `memo_field(instruc, "parent__sku")` is a
# MethodError at the interface rather than a miss inside it. That is the whole of #478 item 2, and
# it is why no wrapper struct was added: #41 measured the `Tuple` key at +3.6% allocation on #477,
# and a struct would have bought the same refusal at a cost that was already known to be non-zero.
#
# `test/unit/test_memo_interface.jl` is the backstop — the mechanical form of the hand audit PR
# #477's third review pass had to perform, which is the symptom that produced this issue.
#
# Everything here is internal. Nothing is exported.
# ─────────────────────────────────────────────────────────────────────────────

# ── Layer 1: the one key constructor ─────────────────────────────────────────
#
# Four methods, replacing `_field_cache_key` / `_cte_cache_key` / `_joined_cache_key` /
# `_join_path_key` and every inline `(:base, x)` literal. One name to grep, one place where a fifth
# namespace would be taught.

# Read a projection's memo key. Keying off `_as` directly is what let two namespaces share one memo
# (#474): #444 deliberately fixed a CTE reference's `_as` at `"<cte>__<path>"`, byte-identical to the
# field path `"<fk>__<col>"`, and `_as` is the OUTPUT column name so it cannot change. The namespace
# therefore has to come from `root`, which `_retag_cte_field!` / `_retag_joined_field!` are the only
# writers of. `nothing` means the expression has no output name and memoizes nowhere.
memo_key(v::SQLTypeField)::Union{Nothing,MemoKey} =
  v._as === nothing ? nothing : (v.root, v._as)

# The same key from a handle rather than from a built `SQLField`, for the sites that resolve a
# reference directly and then read back what `_build_row_join` cached for it.
memo_key(ref::CTEReference)::MemoKey = (:cte, _cte_as(ref))
memo_key(ref::JoinedReference)::MemoKey = (:joined, _joined_as(ref))

# The namespace stated outright, for a join path or any name resolved outside a `SQLField`.
#
# `row_path` does NOT go through here: a CTE hop is not tracked there at all (`_insert_join`'s
# `track_path`). It is the membership set `build()`'s PATH materialization loop tests `custom_join`
# keys against — since #484 the alias loop does not consult it at all — and a CTE hop has no
# `custom_join` entry to suppress, so registering one under the CTE's name is what silently dropped
# the user's own join before #474.
#
# `String(name)` rather than the bare argument so a `SubString` from a `split` cannot reach a `Dict`
# whose key type is `Tuple{Symbol,String}`. The inline literals this replaces had no such guard.
memo_key(ns::Symbol, name::AbstractString)::MemoKey = (ns, String(name))

# ── Layer 2: the verbs ───────────────────────────────────────────────────────
#
# One reader and one writer per memo, in the thin `::SQLInstruction` forwarding shape
# `parameters.jl` established (`set_context!`, `_positional_bucket`, `add_parameter!`) — a method
# that hides one field AND its `nothing` case.
#
# Readers return `nothing`/`false` rather than answering `haskey`, which collapses the ten
# `haskey`-then-index PAIRS this refactor replaced into single lookups. Readers accept a `Nothing`
# key because `memo_key(::SQLTypeField)` produces one for an unnamed expression and several call
# sites pass it straight through.
#
# WRITERS DELIBERATELY DO NOT accept `Nothing`. `build_query.jl` can reach a write with an unnamed
# projection, and the resulting `MethodError: Cannot convert … Nothing …` is a separately-tracked
# leak recorded there — not a bug this refactor may quietly absorb. Typing the writers on `::MemoKey`
# keeps it the same error class on the same reachable input, raised one frame higher. A `::Nothing`
# write no-op would silently change that behaviour, and is the one thing in this file that could
# have broken #478's neutrality claim.

memo_projection(instruc::SQLInstruction, key::MemoKey)::Union{Nothing,SQLTypeField} =
  get(instruc.cache, key, nothing)
memo_projection(::SQLInstruction, ::Nothing)::Nothing = nothing

memo_projection!(instruc::SQLInstruction, key::MemoKey, v::SQLTypeField)::SQLTypeField =
  instruc.cache[key] = v

# The declared output names, for error messages only — never for resolution. Yields the NAME half of
# every key, because the name is what the caller could have typed; the namespace half is internal
# bookkeeping and leaking it into a message reads as a bug. Pinned by
# `test/unit/test_relation_alias_namespace.jl` ("no raw MemoKey in an error message").
memo_projection_names(instruc::SQLInstruction)::Vector{String} =
  String[k[2] for k in keys(instruc.cache)]

memo_field(instruc::SQLInstruction, key::MemoKey)::Union{Nothing,PormGField} =
  get(instruc.tab_field_cache, key, nothing)
memo_field(::SQLInstruction, ::Nothing)::Nothing = nothing

memo_field!(instruc::SQLInstruction, key::MemoKey, f::PormGField)::PormGField =
  instruc.tab_field_cache[key] = f

memo_json_lookup(instruc::SQLInstruction, key::MemoKey)::Bool = key in instruc.json_lookup_paths
memo_json_lookup(::SQLInstruction, ::Nothing)::Bool = false

memo_json_lookup!(instruc::SQLInstruction, key::MemoKey)::Nothing =
  (push!(instruc.json_lookup_paths, key); nothing)
