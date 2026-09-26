# ExistsObject is a standalone EXISTS predicate, not a binary operator.
# It is defined here — before FilterType — because FilterType references it
# and Julia evaluates constant definitions sequentially at load time.
# ExistsObject inherits SQLType (not SQLTypeOper) to avoid accidental access to
# the .column / .values contract that SQLTypeOper implies.
@kwdef mutable struct ExistsObject <: SQLType
  query::SQLObjectHandler
end
"""
    Exists(query::SQLObjectHandler) -> ExistsObject

Wrap a subquery as a SQL `EXISTS` predicate. Renders as `EXISTS (SELECT 1 … LIMIT 1)`, so it
answers "is there at least one match?" without counting or fetching the child rows.

Correlate the subquery to the current outer row with [`OuterRef`](@ref); the result can be used
two ways.

**As a filter predicate** — pass it positionally to `filter`, alongside ordinary pairs or inside
[`Qor`](@ref):

```julia
# Results whose driver set a lap under 90 s in that same race
fast_laps = M.Lap_times.objects.filter(
    "raceid"             => OuterRef("raceid"),
    "driverid"           => OuterRef("driverid"),
    "milliseconds__@lte" => 90_000,
)

n = M.Result.objects.filter(Exists(fast_laps)).count()
```

**As a projected boolean column** — pair it with an alias inside `values`:

```julia
standings = M.Driver_standings.objects.filter("driverid" => OuterRef("driverid"))

query = M.Driver.objects
query.values("surname", "has_standings" => Exists(standings))
```

SQLite returns `0`/`1` integers for a projected `Exists`; PostgreSQL returns booleans.

See also [`Subquery`](@ref) for the scalar (single-value) form and
[Subqueries and CTEs](read/subqueries_and_ctes.md).
"""
Exists(query::SQLObjectHandler) = ExistsObject(query=query)
Base.deepcopy(x::ExistsObject) = ExistsObject(query=deepcopy(x.query))

# SubqueryObject is a scalar single-column subquery projected as a SELECT-list column (#92).
# Like ExistsObject it inherits SQLType directly. It is rendered via query() and correlated with the
# enclosing query through OuterRef. It is defined before FieldPart (below), which is widened to admit
# it so an SQLField.field can carry it until get_select_query resolves it to SQL text.
@kwdef mutable struct SubqueryObject <: SQLType
  query::SQLObjectHandler
end
"""
    Subquery(query::SQLObjectHandler) -> SubqueryObject

Project a **scalar correlated subquery** as a column of the enclosing `SELECT` (#92) — one value
per outer row, computed by its own sub-`SELECT`.

The inner query must select exactly **one** column, and it correlates to the outer row through
[`OuterRef`](@ref). Always project it with an alias — a bare `Subquery(...)` inside `values`
raises.

```julia
# How many standings rows each driver has — one exact count per driver
standings = M.Driver_standings.objects
standings.filter("driverid" => OuterRef("driverid"))
standings.values("t" => Count("driverstandingsid"))

query = M.Driver.objects
query.values("surname", "total_standings" => Subquery(standings))
df = query |> DataFrame
```

This is the fan-out-safe way to aggregate across a to-many relation: two `Subquery` columns over
two different relations stay exact, where a joined `values(Count(...), Count(...))` would
row-multiply (the guard for that is #74).

!!! note "Outer `GROUP BY` — guarded (#194)"
    Combining a correlated `Subquery` with an outer aggregate is only well-defined when the
    correlated column is itself grouped. When it is not, PormG raises a `QueryBuildError` naming
    the ungrouped column, on both backends and before any SQL runs — left to the database,
    PostgreSQL refuses it while SQLite evaluates the subquery against an *arbitrary* row of each
    group and returns a plausible-looking wrong number. See
    [Subqueries and CTEs](read/subqueries_and_ctes.md).

See also [`Exists`](@ref) for the boolean form and [`OuterRef`](@ref) for the correlation.
"""
Subquery(query::SQLObjectHandler) = SubqueryObject(query=query)
Base.deepcopy(x::SubqueryObject) = SubqueryObject(query=deepcopy(x.query))
# Defensive backstop: a SubqueryObject is always resolved to a string by get_select_query before any
# string()/show consumer sees it (audited). If one ever leaked, this keeps it legible rather than dumping
# the whole struct into a SQL string.
Base.show(io::IO, ::SubqueryObject) = print(io, "Subquery(…)")

#
# Type Aliases for Heavy Unions
#
"""Filter components: Operator objects, Q (AND), Qor (OR), F expressions, and EXISTS predicates."""
const FilterType = Union{SQLTypeQ,SQLTypeQor,SQLTypeOper,SQLTypeF,ExistsObject}

"""
Key for the per-build memos (`SQLInstruction.cache`, `tab_field_cache`, `json_lookup_paths`):
`(root, name)`, where `root` names which namespace the name was drawn from —
`:base` (the query's own model: field paths and join paths), `:cte` (a `.with(...)` label, #444) or
`:joined` (a `cjoin_on` alias, #481).

`row_path` is deliberately NOT one of these — it stays a `Vector{String}` and simply does not record
CTE hops, nor (since #484) `cjoin_on` aliases (`_insert_join`'s `track_path`). Do not "unify" it onto
this key: it is the PATH namespace's membership set, a CTE hop has no `custom_join` entry for the
path materialization loop to skip, and recording one at all is what made a user's own join vanish.

#474 — the two namespaces this discriminates are a CTE's own names and the base model's field/join
names, and #444 fixed a CTE reference's output name at `"<cte>__<path>"`, which is byte-identical to
the field path `"<fk>__<col>"`. Whichever expression memoized first therefore claimed the entry for
both, which is how `.with("parent" => cte)` plus `filter("parent__sku" => "S")` filtered the CTE's
column and left the ForeignKey's join unused.

A `"cte:"` STRING PREFIX was tried first and is not sufficient, which is worth recording because it
looks sufficient: `Models.Model(name, ::AbstractDict{String,PormGField})` (the #317 import path) does not
run `format_fild_name`, so a field may legitimately be named `cte:x` — and then a `cjoin` keyed
`"cte:x"` collides with the prefixed key of a CTE named `x`, silently dropping the cjoin's whole
join, and an FK named `cte:x` collides in the memo, reproducing the very defect above. A prefix over
an unvalidated name space is a uniquifier; a tuple is a namespace. `Tuple` rather than a struct so
`==`/`hash` come from Base with the right value semantics for the `String` half.

#478 — build one with `memo_key` and read the memos through the verbs in `memos.jl`, which is the
only file that may name the three fields. Constructing a key inline is what restated the keying rule
at forty sites and made #474's defect reachable; `test/unit/test_memo_interface.jl` enforces it.

#481 widened the namespace half from `Bool` to `Symbol` because a THIRD namespace joined it: a
`cjoin_on` alias. `_cjoin_on` refuses only a duplicate alias, so an alias may legitimately equal a
ForeignKey field name AND a CTE name (the #474 coexistence proof pins that shape), which makes
`Joined("d", "surname")`'s output name `"d__surname"` byte-identical to both the field path and the
CTE reference. A `Bool` cannot hold three values, and adding a second flag would put the same
"which of these is set" question back into every reader — so the tag names the namespace outright.
"""
const MemoKey = Tuple{Symbol,String}

"""Field references in SQL: text, functions, string names, projected subqueries (Subquery/Exists, #92), a CTE column handle (`CTE(name, path)`, #444), or a joined-copy column handle (`Joined(alias, path)`, #481)."""
const FieldPart = Union{SQLTypeText,SQLTypeFunction,String,SQLTypeF,SubqueryObject,ExistsObject,SQLTypeCTE,SQLTypeJoined}

# #537 — exactly what is CONSTRUCTED, no wider. Every site that builds an `OperObject` produces one
# of the two: the `_get_pair_to_oper` arms wrap the parsed path in an `SQLField`, `OP(...)` wraps a
# `String` in one or passes a function through, and `_check_function` plus the two retag walkers
# (`build_helpers.jl`, `ctes.jl`) rebuild from those. `String`, `SQLTypeF`, `SQLTypeCTE`,
# `SQLTypeJoined` and the `Vector` member were admissions nothing ever built — a CTE or joined
# handle in the column position is normalized into an `SQLField` by `_retag_*_field!` before it
# gets here. This reconciles the slot with `OP`'s accepted set, which #537 found to be two different
# widths; `test_op_function_column.jl` and `test_node_admission.jl` pin it.
"""The left-hand side of an operator predicate: a resolved field, or a SQL function over one."""
const ColumnPart = Union{SQLTypeField,SQLTypeFunction}

# #444: `SQLTypeCTE` — PARTITION BY a CTE column worked before the change (the reference was a
# plain String, already admitted here) and must keep working. #481: `SQLTypeJoined` for the same
# reason one level up — `F("d.col")` was a plain String here too.
#
# #612: this comment sits ABOVE the docstring, not between it and the `const`. A comment there
# detaches the docstring silently — `@doc` binds to the next expression and a comment is not one.
"""Window PARTITION BY expressions."""
const WindowPartitionPart = Union{String,SQLTypeField,SQLTypeFunction,SQLTypeF,SQLTypeCTE,SQLTypeJoined}

# #444: `SQLTypeCTE` — a window ORDER BY over a CTE column worked before the change; it is also
# the second site (after the fluent `order_by`) where `CTE(...; desc = true)` is meaningful. #481:
# `SQLTypeJoined` likewise.
#
# #612: above the docstring, not between it and the `const` — see `WindowPartitionPart`.
"""Window ORDER BY expressions."""
const WindowOrderPart = Union{String,SQLTypeOrder,SQLTypeCTE,SQLTypeJoined}

"""Window function column SLOT — what `WindowFunction.column` may hold. The vocabulary a CALLER may
write is the wider `WindowColumnArg` below (#603)."""
const WindowColumnPart = Union{Nothing,String,SQLTypeField,SQLTypeText,SQLTypeFunction,SQLTypeF,SQLTypeCTE,SQLTypeJoined}

# #603 — the ARGUMENT vocabulary for the window VALUE functions (`Lag`, `Lead`, `FirstValue`,
# `LastValue`, `NthValue`): what a CALLER may write, as against what the node may HOLD. Those five
# normalize through `_norm_fn_arg` before the value reaches `WindowFunction.column`, so the slot
# above keeps naming the concrete `String` and no view can ever be stored.
#
# DERIVED from its sibling, never restated. The two drift directions are not symmetric, which is
# what makes the derivation load-bearing rather than tidy: a member added to `WindowColumnPart`
# alone becomes a `MethodError` at the constructor and `test_node_admission.jl` catches it, because
# that probe drives the slot THROUGH `Lag`. A member added here alone would be admitted, ride
# through `_norm_fn_arg`'s identity arm, and die inside `convert` on the slot — outside the
# taxonomy — and `test_node_admission` would NOT catch it, because its loop walks
# `uniontypes(WindowColumnPart)` and would never probe a member that exists only here.
const WindowColumnArg = Union{WindowColumnPart,AbstractString}

"""Optional strings (often used for aliases or configs)."""
const OptionalString = Union{String,Nothing}

"""Database connections."""
const ConnType = Union{PormGSQLite,PormGPostgres,Nothing}

"""CTE configuration dictionary."""
const CTEDict = Dict{String,Union{SQLObjectHandler,PormGModel,Pair,String,Nothing}}

# #487 — one materialized JOIN, typed by KIND.
#
# `InstructionObject.row_join` used to be a `Vector{Dict{String,Union{String,Vector{FilterType}}}}`
# whose kind — model hop, keyed CTE, cross-joined CTE, anchor-less `cjoin_on` — was a set of string
# booleans (`"no_anchor" => "1"`, `"cte" => "1"`, `"cross" => "1"`, `"to_many" => "1"`) that every
# reader probed with its own idiom. The same defect #484 removed one layer up, in the config
# namespace: the type IS the kind now, so a reader asks `isa` and the render path is selected by
# what the row is rather than by which tags it happens to carry. Every slot every kind renders is a
# real field; a slot a kind does not have (a `CrossJoin`'s key columns, a `CteJoin`'s ON predicates)
# no longer exists as an empty-string sentinel a consumer has to know to skip.
#
# All four are immutable. The join builder writes to a row at three moments, and each is a
# replacement rather than an edit: the shared tail applies a `cjoin`/`on()` override through
# `_with_config` (a copy), and `_apply_many_to_many_branch` stamps `to_many` onto the dedup SURVIVOR
# through `_flag_to_many!`, which replaces the slot in `row_join`. Nothing holds a row across either.
#
# The two slots every kind shares by name — `alias_a` / `alias_b`, and `a` / `b` — are read
# generically by the alias allocator, the dedup, the relocation pass and the UPDATE-FROM renderer, so
# they are spelled the same in all four structs on purpose.
abstract type JoinRow end

# A model-to-model equi-join: a forward ForeignKey / OneToOne hop, a reverse-relation hop, or either
# half of a many-to-many expansion (the through-table hop and the related-table hop are two of these).
# `to_many` marks the many-side of a reverse or M2M hop for the #74 fan-out guard; `on_conditions`
# carries a `cjoin`/`on()` entry's predicates, AND-appended to the equi-anchor at render.
Base.@kwdef struct ModelJoin <: JoinRow
  a::String                      # source relation (physical table, or a CTE name on a hop out of one)
  alias_a::String
  key_a::String                  # physical column on the source side (`field_db_column` / `model_column`)
  b::String                      # target physical table
  alias_b::String
  key_b::String                  # physical column on the target side
  how::String                    # "INNER" / "LEFT" — interpolated raw into ` <how> JOIN `
  to_many::Bool = false
  on_conditions::Vector{FilterType} = FilterType[]
end

# A keyed `.with(name => sub, join_field = main => cte)` hop. `key_b` is the CTE's PROJECTION
# ALIAS, not a physical column (#64/#376) — the one dual-natured key slot, which is why the #394
# quoting table lets the render site stay escape-only: `_with` validated the name at declaration.
# It never carries ON predicates or a join-type override: a CTE has no `custom_join` entry by
# construction (#474), and its join type comes from the `.with(...)` declaration.
Base.@kwdef struct CteJoin <: JoinRow
  a::String
  alias_a::String
  key_a::String
  b::String                      # the CTE name
  alias_b::String
  key_b::String                  # the CTE's projection alias
  how::String
end

# An unkeyed `.with(name => sub)`: `CROSS JOIN`, no ON clause, no join type (#44). The correlation
# is supplied by the outer query's `filter(...)`, which is why a predicate that lands here is refused
# rather than rendered (#424).
Base.@kwdef struct CrossJoin <: JoinRow
  a::String
  alias_a::String
  b::String                      # the CTE name
  alias_b::String
end

# A `cjoin_on` join (#45): `alias_b` is the user's alias and `on_conditions` is the ENTIRE ON clause —
# no equi-anchor is emitted, so there are no key columns to carry.
Base.@kwdef struct AnchorlessJoin <: JoinRow
  a::String
  alias_a::String
  b::String
  alias_b::String
  how::String
  on_conditions::Vector{FilterType}
end

# The dedup identity `_insert_join` compares. Deliberately KIND-AGNOSTIC and shaped exactly like the
# `(a, b, key_a, key_b, alias_a)` tuple the dict rows compared, because putting the kind in would be
# observable: a CTE row and a model row agree on `b` only when a CTE is named after a physical
# table, `_with` refuses that for every table reachable from the registered models — but its walk is
# one module deep, and SQL would resolve both joins to the CTE regardless, so a kind discriminator
# could only ever render a second join reading the wrong relation (#479, `_insert_join`).
#
# The sentinels the kinds without key columns contribute are the ones their dict rows carried: a
# `CrossJoin`'s empty strings collapse every reference to the same unkeyed CTE onto one `CROSS JOIN`,
# and an `AnchorlessJoin` contributes its own alias, which is what keeps two `cjoin_on` joins to the
# same target apart — `alias_b` is not in the tuple, so it has to arrive through `key_a`.
_key_a(r::Union{ModelJoin,CteJoin})::String = r.key_a
_key_a(::CrossJoin)::String = ""
_key_a(r::AnchorlessJoin)::String = r.alias_b
_key_b(r::Union{ModelJoin,CteJoin})::String = r.key_b
_key_b(::Union{CrossJoin,AnchorlessJoin})::String = ""
_dedup_key(r::JoinRow) = (r.a, r.b, _key_a(r), _key_b(r), r.alias_a)

# The predicates a row appends to (or, for an `AnchorlessJoin`, substitutes for) its equi-anchor.
# Empty for the two CTE kinds, which cannot carry any.
_on_conditions(r::Union{ModelJoin,AnchorlessJoin})::Vector{FilterType} = r.on_conditions
_on_conditions(::Union{CteJoin,CrossJoin})::Vector{FilterType} = FilterType[]

# #74: is this row the many-side of a to-many relation?
_to_many(r::ModelJoin)::Bool = r.to_many
_to_many(::JoinRow)::Bool = false

# #394: does this row name a CTE — i.e. a relation a statement that emits no `WITH` never declares?
_joins_cte(::Union{CteJoin,CrossJoin})::Bool = true
_joins_cte(::JoinRow)::Bool = false

# The join type the NEXT hop inherits (`_determine_join_type(previus_how = …)` turns a `LEFT`
# parent into a `LEFT` child). A `CrossJoin` has none: its dict row carried the sentinel `"CROSS"`
# purely so a deep path after an unkeyed CTE reached the "not a foreign key" error instead of a
# `KeyError`, and every consumer tests `== "LEFT"` only, so `nothing` renders identically.
_prev_how(r::Union{ModelJoin,CteJoin,AnchorlessJoin})::Union{String,Nothing} = r.how
_prev_how(::CrossJoin)::Union{String,Nothing} = nothing

# The shared tail of `_build_row_join`: fold a `cjoin`/`on()` entry's join-type override and ON
# predicates into the hop's row, by copy. Only a `ModelJoin` can receive one — the CTE kinds admit
# exactly the `(nothing, nothing)` the tail passes when `cte == true`, so a config reaching a CTE row
# is a `MethodError` at the call site rather than a silently ignored tag.
function _with_config(row::ModelJoin, join_type_override::Union{String,Nothing},
                      join_filters::Union{Vector{FilterType},Nothing})::ModelJoin
  how = join_type_override === nothing ? row.how : join_type_override
  on_conditions = (join_filters === nothing || isempty(join_filters)) ? row.on_conditions : join_filters
  return ModelJoin(a = row.a, alias_a = row.alias_a, key_a = row.key_a,
                   b = row.b, alias_b = row.alias_b, key_b = row.key_b,
                   how = how, to_many = row.to_many, on_conditions = on_conditions)
end
_with_config(row::Union{CteJoin,CrossJoin}, ::Nothing, ::Nothing) = row

#
# SQLTypeArrays Objects
#
@kwdef mutable struct SQLArrays <: SQLTypeArrays # TODO -- check if I need to use this
  count::Integer = 1
  array_string::Array{String,2} = Array{String,2}(undef, 20, 3)
  array_int::Array{Integer,2} = Array{Integer,2}(undef, 20, 3)
end

"""
One `OuterRef` that rendered inside a projected correlated `Subquery`/`Exists` (#194).

Spelled once, as a named type, because two places have to agree on it exactly: the recorder in
`_get_filter_query(::OuterRefObject, …)` writes it, and `_ungrouped_correlation_error_msg` reads it.
Written out twice as an anonymous `NamedTuple` they could drift without a type error.

- `label` — the projection's output name (`"n_standings"`), what the user sees as the offending column
- `ref` — what the user WROTE (`"driverid"`, or the literal `"pk"`)
- `column` — the RESOLVED outer column name (`OuterRef("pk")` → `"driverid"`)
- `expr` — the rendered outer SQL (`"Tb"."driverid"`), comparable to the group set

`ref` and `column` differ only for `OuterRef("pk")`, and the distinction is load-bearing in the error
message: a fix line that echoes `ref` would tell the user to add `"pk"` to `values(...)`, which is a
second error rather than a fix.
"""
const CorrelatedRef = NamedTuple{(:label, :ref, :column, :expr),NTuple{4,String}}

#
# SQLInstruction Objects (instructions to build a query)
#
@kwdef mutable struct InstructionObject <: SQLInstruction
  text::String # text to be used in the query
  table_alias::SQLTableAlias
  alias::String
  object::SQLObject
  select::Vector{SQLTypeField} = Array{SQLTypeField,1}(undef, 60)
  join::Vector{String} = []  # values to be used in join query
  _where::Vector{String} = []  # values to be used in where query
  aggregate::Bool = false
  group::Vector{String} = []  # values to be used in group query
  having::Vector{String} = [] # values to be used in having query
  order::Vector{String} = [] # values to be used in order query  
  # df_join::Union{Missing, DataFrames.DataFrame} = missing # dataframe to be used in join query
  row_join::Vector{JoinRow} = JoinRow[] # the materialized joins, one typed row each (#487)
  row_path::Vector{String} = [] # array of path to map the row_join (model__model__ etc)
  # array_join::Array{String, 2} = Array{String, 2}(undef, 30, 8) # array to be used in join query (meaby the best way to do this)
  tab_field_cache::Dict{MemoKey,PormGField} = sizehint!(Dict{MemoKey,PormGField}(), 12) # cache to be used in join query (#474: keyed by MemoKey)
  # #27: the membership set of resolved JSON-lookup paths (e.g. "payload__driver"). Added when the
  # JSON-path gate renders an extraction; tested by the filter-render branch to bind the RHS as
  # plain text (not through the JSON formatter) and to reject containment operators on a nested key
  # path.
  #
  # #478 — this was a `Dict` mapping to `(JSON base field, validated key segments)`, and both halves
  # of that value were dead. The base field is separately written to `tab_field_cache` on the very
  # next line of `_render_json_lookup`, the segments are consumed by `Dialect._json_extract_expr`
  # BEFORE the write, and both readers were `haskey` membership tests — `_render_json_lookup_comparison`
  # re-derives everything it needs from the filter expression it is handed. It was a `Set` wearing a
  # `Dict`'s allocation, so it is spelled as one now. Reach it through `memo_json_lookup` (`memos.jl`).
  json_lookup_paths::Set{MemoKey} = Set{MemoKey}()
  # #564 — the canonical kind each PROJECTION evaluates to, keyed by the RESULT-ROW column name
  # (`_projection_output_name`, the same expression `_query_select` renders the `AS` alias from, so
  # this key and the one the driver hands back agree by construction rather than by coincidence).
  #
  # DELIBERATELY NOT A FOURTH MEMO, and not reached through `memos.jl`. The three memos there are
  # RESOLUTION caches keyed by `MemoKey` — a namespace plus a name — consulted DURING the build to
  # avoid re-resolving an expression. This is a description of the RESULT SET, consumed AFTER the
  # build by a reader whose only handle on a column is the name the driver gave it: `_list_raw` has
  # no namespace to key with, and routing this through `memo_key` would force it to invent one.
  projection_kinds::Dict{Symbol,CanonicalType} = Dict{Symbol,CanonicalType}()
  connection::ConnType = nothing
  # array_defs::SQLTypeArrays = SQLArrays()
  cache::Dict{MemoKey,SQLTypeField} = sizehint!(Dict{MemoKey,SQLTypeField}(), 12)
  django::OptionalString = nothing
  parameters::Union{Nothing,AbstractPormGParam} = nothing # parameters to be used in the query
  outer::Union{Nothing,SQLInstruction} = nothing # parent query instruction for correlated subqueries
  # #74 fan-out guard: record each at-risk aggregate's source alias so build() can refuse
  # silently-inflated COUNT/SUM/AVG. To-many joins carry `ModelJoin.to_many` (stamped onto the dedup
  # survivor by `_flag_to_many!`) and the many-side alias set is derived from the *deduped* row_join at check time
  # (deriving avoids over-counting when _cache_join builds the same join twice). See _check_aggregate_fanout.
  agg_sources::Vector{NamedTuple{(:alias, :func, :label, :distinct),Tuple{String,String,String,Bool}}} =
    NamedTuple{(:alias, :func, :label, :distinct),Tuple{String,String,String,Bool}}[]
  # #194 grouped-correlation guard — same evidence-plumbing shape as `agg_sources` above, and for
  # the same reason: what the guard needs cannot be read back off the rendered state.
  #
  # `correlated_projection` is the output name of the projected correlated Subquery/Exists currently
  # rendering, or `nothing` outside one. It is set ONLY by the two PROJECTED entry points
  # (`_get_select_query(::SubqueryObject)` / `(::ExistsObject)`), which is what keeps a
  # FILTER-position `Exists` out of the guard: a WHERE predicate is evaluated before GROUP BY, so
  # correlating one on an ungrouped column is legal and both backends run it.
  #
  # **Set and restore it with `try`/`finally`.** A projected render throws routinely (the
  # one-column rule, the nested-CTE guard, the inner build), and a flag left set would make the NEXT
  # ref recorded against a projection that is no longer rendering.
  correlated_projection::OptionalString = nothing
  # One entry per OuterRef actually RENDERED inside a projected correlated subquery of this query.
  # Written at resolution time rather than collected by walking the inner query's AST, because the
  # two have opposite failure modes: a walker must enumerate every node type an OuterRef can hide in
  # and every miss is a silent wrong number, while a recorder's invariant — "a ref that was not
  # recorded was not rendered, and a ref that was not rendered cannot affect the answer" — holds by
  # construction. A walk is also actively WRONG here: `_build_exists_query` discards the inner
  # `values()`, so `Exists(q.values("t" => Lower(OuterRef("surname"))))` never renders that ref, and
  # a collector reading `.values` would refuse a correct query.
  #
  # `expr` is the resolved outer SQL (`"Tb"."driverid"`), directly comparable to the group set —
  # which is why the guard needs no parallel semantic bookkeeping on the group side.
  outer_refs::Vector{CorrelatedRef} = CorrelatedRef[]
end

# Store information to decide the name from table alias in subquery
mutable struct SQLTbAlias <: SQLTableAlias
  count::Integer
end
SQLTbAlias() = SQLTbAlias(0)
function get_alias(s::SQLTableAlias)
  if s.count == 0
    s.count += 1
    return "Tb"
  end
  s.count += 1
  return "R$(s.count -1)"
end

# Return a value to sql query, like value from DjangoSQLText
struct SQLText <: SQLTypeText
  field::Any
  _as::OptionalString
  custom_as::OptionalString
end
SQLText(field::Any; _as::OptionalString=nothing) = SQLText(field, _as, nothing)
SQLText(field::Any, _as::OptionalString) = SQLText(field, _as, nothing)


# Return a field to sql query
mutable struct SQLField <: SQLTypeField
  field::FieldPart
  _as::OptionalString
  custom_as::OptionalString
  # #474/#481 — which namespace is this expression rooted in? It selects the namespace half of the
  # `MemoKey` this projection memoizes under: `:base`, `:cte` (#444) or `:joined` (#481). It cannot
  # be derived from `_as`: #444 deliberately fixed a CTE reference's `_as` at `"<cte>__<path>"`, the
  # same spelling a field path produces, and `_as` is the OUTPUT column name so it cannot change.
  # `_retag_cte_field!` / `_retag_joined_field!` are the only places that set this.
  # Read it through `memo_key` (`memos.jl`), never directly.
  root::Symbol
end
SQLField(field::FieldPart; _as::OptionalString=nothing) = SQLField(field, _as, nothing, :base)
SQLField(field::FieldPart, _as::OptionalString) = SQLField(field, _as, nothing, :base)
# #508 phase 2 deleted seven hand-written `Base.deepcopy` methods — for `SQLText`, `FExpression`,
# `OuterRefObject`, `CTEReference`, `JoinedReference`, `FObject` and `WindowFunction`. They existed
# to satisfy the #112 discipline — *a copy must share no MUTABLE state with its original* — which an
# immutable node satisfies for free; `JoinedReference` had been immutable since #481 and kept one
# only for symmetry with the others. Do not re-add one: a node type that needs a copy method to be
# safe is a node type that should not have been mutable.
#
# Three survive, and each for a reason that is NOT mutability. (#540 deleted a fourth: the
# `SQLTypeOrder` one re-ran the #77 orientation whitelist through the inner constructor, which
# Base's generic `deepcopy` bypasses — but a frozen `SQLOrder` cannot hold an invalid orientation,
# so there was nothing left to re-validate. It was never a `deepcopy_internal` hook either, so
# `deepcopy(handler)` already went through Base; `test_sqlorder_orientation.jl` now pins that the
# generic path preserves every slot.)
#   - this one — deliberately SHALLOW on `.field`, which `ctes.jl` documents as load-bearing;
#   - `SQLTypeOper` — shares an `SQLObjectHandler` in `values` instead of cloning a whole subquery.
#     Narrower than it reads, and review measured the boundary: `Base.deepcopy(::T)` is not a
#     `deepcopy_internal` hook, so this specialisation applies to a TOP-LEVEL `deepcopy(::OperObject)`
#     only. Reached nested — under an `FObject`, or under an `FExpression` — the generic walk runs
#     instead and the handler IS cloned, where the deleted methods used to keep it shared. Cost, not
#     correctness: `Base.deepcopy_internal(::Model_Type, …)` still returns the model itself, so the
#     #157 sharing contract holds through the generic walk (pinned in `test_model_deepcopy.jl` and by
#     the chain testset in `test_f_expression_immutability.jl`);
#   - `WindowSpec` — still a mutable container.
Base.deepcopy(x::SQLTypeField) = SQLField(x.field, x._as, x.custom_as, x.root)

# `orientation` is interpolated into rendered SQL, so it is whitelisted here (#77) and stored
# uppercase. Single whitelist for every orientation path — the window path
# (_normalize_window_orientation, build_helpers.jl) delegates here with its own context label.
function _normalize_order_orientation(orientation::AbstractString; context::String="ORDER BY")::String
  normalized = uppercase(strip(String(orientation)))
  normalized in ("ASC", "DESC") || throw(QueryBuildError("$(context) orientation must be ASC or DESC, got $(repr(orientation))"))
  return normalized
end

# An ORDER BY term. Immutable since #540: it is a value a user constructs and hands in, not a build
# product, and the one path that used to write into it — `last()`'s inversion — constructs the
# reversed term instead (`_invert_order`, execution.jl). With no second writer, the inner
# constructor's whitelist below is the only place an orientation is ever set, which is what let
# #540 delete the render-time re-validation in `get_order_query` and the hand-written `deepcopy`.
struct SQLOrder <: SQLTypeOrder
  # #533 — `SQLTypeField`, not `Union{SQLTypeField,String}`. The String member was admitted and never
  # handled: `get_order_query` read `._as` off it and raised a raw `FieldError` naming an internal
  # slot (#528). The inner constructor now routes every path through `_order_field`
  # (`object_manager.jl`), which NORMALIZES a String into the `SQLField` all four readers require —
  # so the spelling works instead of merely type-checking.
  field::SQLTypeField
  order::Union{Integer,Nothing}
  orientation::String
  _as::OptionalString
  # NULL placement for this term (#75): `nothing` = apply the canonical backend-aligned default
  # (ASC → NULLS LAST, DESC → NULLS FIRST); `:first`/`:last` force the placement explicitly.
  nulls::Union{Symbol,Nothing}
  # Inner constructor: every construction path (keyword, positional) passes the orientation
  # whitelist (#77), so an injection-shaped direction never reaches the renderer — and since the
  # struct is immutable (#540), construction is the only time the slot is ever written.
  SQLOrder(field, order, orientation, _as, nulls) = new(_order_field(field), order, _normalize_order_orientation(orientation), _as, nulls)
end
# `field` is untyped on purpose (#533): an unsupported value must reach `_order_field`'s typed
# refusal, which names the supported spellings, rather than dying as a bare `MethodError` on this
# signature. The `CTE`/`Joined` handles have their own more specific method below, so they still
# take the `desc`-rejecting path.
# #603: `orientation` and `_as` are keyword ANNOTATIONS, which do not convert — they raise
# `TypeError`, outside `PormGError`. Widened here; `_normalize_order_orientation` already took an
# `AbstractString`, and the struct's own slots convert on construction, so the inner constructor
# needs no change.
SQLOrder(field; order::Union{Integer,Nothing}=nothing, orientation::AbstractString="ASC", _as::Union{AbstractString,Nothing}=nothing, nulls::Union{Symbol,Nothing}=nothing) = SQLOrder(field, order, orientation, _as, nulls)
# #509 — a CTE (#444) or joined-copy (#481) column inside an `SQLOrder`. Until this, the keyword
# constructor above was the whole surface and its `field` union excluded both, so
# `SQLOrder(CTE("ev", "seen"))` was a `MethodError` — which is why an `SQLOrder` entry in a window's
# `order_by` had no spelling for a CTE column at all, and why the error message that told users to
# "write CTE(...) instead" prescribed a remedy that did not exist.
#
# The handle is NORMALIZED into the same `SQLField` the fluent `order_by(CTE(...))` builds, not
# stored raw. That is what makes this cheap rather than invasive: all four readers of
# `SQLOrder.field` — `get_order_query`, `_resolve_window_order`, the `_resolve_cte_string_paths!`
# order loop and `deepcopy` — already require an `SQLField`. Normalizing here keeps their invariant
# intact, so the widening costs zero consumer changes.
#
# This comment used to claim `._as` and `memo_key` "have no method for anything else". That was
# false for `memo_key`: it was typed `::SQLTypeField` and `SQLTypeOrder <: SQLTypeField`, so it
# accepted an `SQLOrder` and then read a `root` slot `SQLOrder` does not have — a raw `FieldError`
# instead of the MethodError the claim assumed. #508 phase 2 retyped it to `::SQLField` (`memos.jl`),
# which is what makes the sentence true.
#
# `desc = true` is REFUSED, not folded into `orientation`. `SQLOrder` carries the direction itself
# and its `"ASC"` default is indistinguishable from an explicitly passed one, so folding would have
# to silently pick a winner when the two spellings disagree — first-match precedence, which is the
# exact defect class #492/#509 exist to remove. One direction, one slot.
function SQLOrder(field::Union{SQLTypeCTE,SQLTypeJoined}; order::Union{Integer,Nothing}=nothing,
                  orientation::AbstractString="ASC", _as::Union{AbstractString,Nothing}=nothing,
                  nulls::Union{Symbol,Nothing}=nothing)
  _reject_handle_desc_in_sqlorder(field)
  return SQLOrder(_order_field(field), order, orientation, _as, nulls)
end

#
# SQLObject Objects (main object to build a query)
#

# #26: row-level locking clause carried on a SELECT. `nothing` on the query means no lock;
# a `ForUpdateClause` renders `FOR [NO KEY] UPDATE [NOWAIT|SKIP LOCKED]` on PostgreSQL and is a
# silent no-op on SQLite (which has no row-level locking). Immutable/set-once — the
# `_select_for_update!` mutator always builds a fresh clause, so it is shared by reference on copy.
# (An `OF <table>` target is a deferred follow-up: it must name the query's generated FROM alias,
# which is not yet exposed — see the row-locking follow-up issue.)
struct ForUpdateClause
  nowait::Bool
  skip_locked::Bool
  no_key::Bool                 # PostgreSQL: FOR NO KEY UPDATE (weaker lock, allows FK-referencing inserts)
end

# #484 — one `cjoin(...)` / `on(...)` entry, keyed in `custom_join` by a JOIN PATH on the base model.
#
# Typed rather than an entry in a `Dict{String,Any}` bag, because the bag is what let three writers
# share one keyspace: `_cjoin`/`_on` key by path, `_cjoin_on` keyed by user alias, and every reader
# had to guess which it had found from a tag inside the value (`"no_anchor"`). The type IS the
# namespace now — a reader that wants a path config asks `custom_join` and cannot be handed an
# alias config — so the `isa Dict` / `get(config, "…", nothing) isa T` probes are gone.
#
# Immutable, replace-on-update: `_on` builds a fresh entry and reassigns the key rather than editing
# one in place, which is what #112 was about. Note the limit of that — `filters` is a `Vector`, so an
# entry is only as immutable as what it points at, and `Base.deepcopy(::SQLObjectQuery)` copies that
# vector rather than relying on every future writer to remember not to mutate it.
struct PathJoin
  filters::Vector{FilterType}          # ON predicates, already prefixed onto the path
  field::Union{PormGField,Nothing}     # `cjoin`'s link (its join type folded into `field.how`); `nothing` for an `on()`-only entry
  join_type::Union{String,Nothing}     # explicit `on(join_type = …)` override; `nothing` = derived from the relation (#474)
end

# #484 — one `cjoin_on(...)` entry, keyed in `alias_join` by its USER ALIAS.
#
# Its own map rather than a tagged entry in `custom_join`, because an alias and a join path are
# genuinely different namespaces: while they shared one, a `cjoin_on(alias = "driver")` on a model
# with a ForeignKey named `driver` was absorbed by that FK's join — the alias's predicates
# AND-appended to the FK's ON, its `join_type` adopted, its own join never emitted, and the
# statement left naming a range variable it never declared. The two relations render under
# different SQL aliases, so SQL has no conflict; the collision was ours. Same move #474 made for
# CTE names. (#479 refused its overlap instead, correctly — there SQL itself merges the namespaces.)
struct AliasJoin
  target::PormGModel                   # resolved once at declaration (was a model NAME re-looked-up at three render sites)
  filters::Vector{FilterType}          # the ENTIRE ON clause — no equi-anchor is emitted (#45)
  join_type::String                    # normalized; "INNER" by default
end

mutable struct SQLObjectQuery <: SQLObject
  model::PormGModel
  connect_key::OptionalString # Override for multi-tenant scenarios
  values::Vector{Union{SQLTypeText,SQLTypeField}}
  filter::Vector{FilterType} # filters to be used in the query
  insert::OrderedCollections.OrderedDict{String,Any} # values to be used to create or insert (ordered so INSERT/UPDATE column lists follow call order — #97)
  limit::Integer
  offset::Integer
  order::Vector{SQLTypeOrder}
  group::Vector{String}
  having::Vector{String}
  list_joins::Vector{String} # is ther a better way to do this?
  distinct::Bool # Add distinct field
  for_update::Union{Nothing,ForUpdateClause} # #26: row-level lock clause (nothing = no lock)
  # ORDERED for the same reason as `alias_join` below and `insert` above. `build_cte_clause`
  # emits the WITH clause by ITERATING this container, and the CTE bodies' positional parameters
  # are collected in that same pass — so under a plain `Dict` the rendered SQL for one query was
  # decided by how Julia hashed the CTE NAME STRINGS. Renaming a CTE for readability reordered
  # the WITH clause, and so did upgrading Julia: 1.13.0 changed string hashing and flipped the
  # pair in `test_alignment_sqlite.jl`'s "Multiple CTEs" testset, which had been asserting
  # declaration order that a `Dict` never promised. Text and parameters do flip together, so
  # binding stayed correct — what was lost is that the same query rendered the same SQL twice.
  ctes::OrderedCollections.OrderedDict{String,CTEDict}
  # The PATH namespace (#484): `cjoin` / `on()` entries, keyed by a join path on the base model.
  # Ordered because materialization order decides generated alias numbering (#449).
  custom_join::OrderedCollections.OrderedDict{String,PathJoin}
  # The ALIAS namespace (#484): `cjoin_on` entries, keyed by the alias the caller declared.
  #
  # ORDERED, and load-bearing (#449). `build()` materializes row_join by ITERATING this container,
  # so its order decides which of two `cjoin_on` joins is emitted first — and Phase 1b relocates an
  # ON predicate onto the LAST join it names. Under a plain `Dict` that order came from hashing the
  # ALIAS STRINGS, so renaming an alias for readability could flip a working query into a
  # QueryBuildError, or the reverse, while reversing the DECLARATION changed nothing. Same reason
  # `insert` above is ordered (#97).
  alias_join::OrderedCollections.OrderedDict{String,AliasJoin}
  parameters::Union{Nothing,AbstractPormGParam}
  # #564 — the build writes back the canonical kind of each projection here, the same way it writes
  # back `parameters`, so the READ path can ask what each result column is without re-deriving it.
  #
  # Like `parameters`, it is a PER-BUILD artifact and `Base.deepcopy` deliberately does not carry it:
  # it describes the projections of one build, and a stale map surviving into a copy that is then
  # re-projected would describe columns that no longer exist.
  projection_kinds::Dict{Symbol,CanonicalType}

  SQLObjectQuery(; model=nothing, connect_key=nothing, values=[], filter=[], insert=OrderedCollections.OrderedDict{String,Any}(), limit=0, offset=0,
    order=[], group=[], having=[], list_joins=[], distinct=false, for_update=nothing, ctes=OrderedCollections.OrderedDict{String,CTEDict}(),
    custom_join=OrderedCollections.OrderedDict{String,PathJoin}(), alias_join=OrderedCollections.OrderedDict{String,AliasJoin}(), parameters=nothing,
    projection_kinds=Dict{Symbol,CanonicalType}()) =
    new(model, connect_key, values, filter, insert, limit, offset, order, group, having, list_joins, distinct, for_update, ctes, custom_join, alias_join, parameters, projection_kinds)
end

function Base.deepcopy(obj::SQLObjectHandler)
  return ObjectHandler(object=deepcopy(obj.object))
end

# #43: CTE state must be copied deeply enough that a copy's execution can't mutate
# the original. A shallow `copy(ctes)` aliases the inner CTEDict values, so
# materializing the per-build "model" (see _build_cte_custom_model) on one copy
# clobbers the other. Rebuild each CTEDict with a fresh dict: deep-copy the sub-query
# handler (recursion covers nested CTEs), carry the scalar join config by reference
# (Pair/String are immutable), and DROP the transient "model" — it is re-derived on
# every build and holds a Model_Type → Module reference that deepcopy cannot traverse
# (the very reason the original copy was shallow).
function _copy_ctes(ctes::OrderedCollections.OrderedDict{String,CTEDict})::OrderedCollections.OrderedDict{String,CTEDict}
  out = OrderedCollections.OrderedDict{String,CTEDict}()
  for (name, cte_dict) in ctes
    fresh = CTEDict()
    for (k, v) in cte_dict
      k == "model" && continue  # transient per-build artifact; re-materialized each build
      fresh[k] = v isa SQLObjectHandler ? deepcopy(v) : v
    end
    out[name] = fresh
  end
  return out
end

# #112: a copy must share no MUTABLE state with its original.
#
# Before #484 the entries were `Dict{String,Any}` and `on()` rewrote them in place, so a shallow
# `copy` let a copy's `on()` rewrite the original's join definition. #484 made the entries immutable
# structs and every writer replace-on-update, which closes that route — but an immutable struct is
# only as immutable as what it points at, and `filters` is a `Vector`. Measured on this branch before
# the vector copy went in: `push!(q2.object.custom_join["owner"].filters, …)` after `q2 = q.copy()`
# added a predicate to the ORIGINAL's rendered ON clause. Grepped at the time of writing, no `src/`
# reader of a stored filters vector mutates it — but that is a snapshot, not an invariant, and
# keeping the guarantee a PROPERTY of the copy rather than a convention every future writer has to
# remember is the whole point of #112. `test_order_by_joins.jl` already reaches for that idiom
# white-box.
#
# What stays shared, deliberately: the vector's `FilterType` ELEMENTS (every writer replaces the
# whole vector; none edits an element), and `PathJoin.field` / `AliasJoin.target`, which hold a
# Model_Type → Module that `deepcopy` cannot traverse — the very reason the original copy was shallow.
#
# Both containers are ORDERED (#449) and rebuilt by insertion, so declaration order survives a
# `.copy()`; an unordered accumulator here would silently re-hash it out on every copy.
function _copy_path_joins(m::OrderedCollections.OrderedDict{String,PathJoin})::OrderedCollections.OrderedDict{String,PathJoin}
  out = OrderedCollections.OrderedDict{String,PathJoin}()
  for (path, config) in m
    out[path] = PathJoin(copy(config.filters), config.field, config.join_type)
  end
  return out
end
function _copy_alias_joins(m::OrderedCollections.OrderedDict{String,AliasJoin})::OrderedCollections.OrderedDict{String,AliasJoin}
  out = OrderedCollections.OrderedDict{String,AliasJoin}()
  for (alias, config) in m
    out[alias] = AliasJoin(config.target, copy(config.filters), config.join_type)
  end
  return out
end

function Base.deepcopy(obj::SQLObjectQuery)
  try
    return SQLObjectQuery(
      model=obj.model,  # PormGModel doesn't need deep copy (immutable reference)
      connect_key=obj.connect_key,
      values=deepcopy(obj.values),
      filter=deepcopy(obj.filter),
      insert=deepcopy(obj.insert),
      limit=obj.limit,
      offset=obj.offset,
      order=deepcopy(obj.order),
      group=deepcopy(obj.group),
      having=deepcopy(obj.having),
      list_joins=deepcopy(obj.list_joins),
      distinct=obj.distinct,
      for_update=obj.for_update,  # #26: immutable/set-once lock clause — share by reference (like distinct)
      ctes=_copy_ctes(obj.ctes),  # #43: independent CTE state (deep sub-query, drop transient "model")
      custom_join=_copy_path_joins(obj.custom_join),  # #112/#484: fresh map, fresh filters vectors
      alias_join=_copy_alias_joins(obj.alias_join)    # (`field` / `target` shared by ref — see above)
    )
  catch e
    @pormg_debug false
    @error "Error in deepcopy for SQLObjectQuery: $e" exception = (e, catch_backtrace())
    rethrow(e)
  end
end
function Base.deepcopy(filter::Vector{FilterType})
  return [deepcopy(f) for f in filter]
end
function Base.deepcopy(oper::SQLTypeOper)
  @pormg_debug false
  return OperObject(
    operator=oper.operator,
    values=oper.values |> typeof <: SQLObjectHandler ? oper.values : deepcopy(oper.values),
    column=deepcopy(oper.column)
  )
end


#
# SQLTypeQ and SQLTypeQor Objects
#

"""
Mutable struct representing an SQL operator object for using in the filter and annotate.
That is a internal function, please do not use it.

# Fields
- `operator::String`: the operator used in the SQL query.
- `values::Union{String, Integer, Bool}`: the value(s) to be used with the operator.
- `column::ColumnPart`: the left-hand side — an `SQLTypeField`, or an `SQLTypeFunction` over one.

"""
@kwdef struct OperObject <: SQLTypeOper
  operator::String
  # `Base.UUID` appears on BOTH arms (#411): the vector arm so `uid__@in` can hold a list, and the
  # scalar arm so `filter("uid" => uuid)` can hold one value. Widening only the vector arm left plain
  # equality on a UUIDField raising a `convert` MethodError — an untyped error on the most ordinary
  # spelling there is, which is precisely what this pair of issues exists to remove.
  # `AbstractVector{UInt8}` on the vector arm (#466): a `blob__@in` list holds one `Vector{UInt8}`
  # per member. A scalar `"blob" => bytes` comparison is spelled the obvious way since #596 and needs
  # no widening here — a flat `Vector{UInt8}` already satisfies `Vector{T} where T<:Number`. The two
  # are distinguishable by type, which is what lets the parse ladder admit the scalar without knowing
  # the field: `Vector{Vector{UInt8}}` is a membership list, `Vector{UInt8}` is one payload. Whether
  # the column can actually hold bytes is decided at RENDER, where the field is known — see the
  # `_is_binary_field` guard in `_get_filter_query(::SQLTypeOper, …)`.
  values::Union{String,Number,Bool,Dates.TimeType,Dates.Period,Dates.CompoundPeriod,Base.UUID,SQLObjectHandler,SQLTypeF,SQLTypeFunction,SQLTypeCTE,SQLTypeJoined,Vector{T}} where T<:Union{Missing,String,Dates.TimeType,Dates.Period,Dates.CompoundPeriod,Number,Bool,SQLTypeF,Base.UUID,AbstractVector{UInt8}}
  column::ColumnPart
end
# `OP` is internal (#202): unexported, undocumented, and the string-lookup form (`"field__@op" =>
# value`) is the public way to write an operator predicate. The `SQLTypeFunction` arms exist for
# PormG's own composite transforms — `Y_Q` / `Y_QUAD` (functions.jl), the year-qualified
# `@yyyy_q` / `@yyyy_quad` labels — build `When(OP(MONTH(x), "<=", N))` — and a function column renders only where the filter path can name
# a formatter: the `PormGTypeField` functions (EXTRACT, TO_CHAR, COUNT). Any other function column,
# and any aggregate or window column in a WHERE predicate, is refused at render with a
# `QueryBuildError` naming the alias / suffix spelling (#537) rather than the raw `FieldError` it
# used to be. Do not widen the arms without a consumer: `test_op_function_column.jl` pins both the
# served set and the refusals.
# #603: `AbstractString` on both the column and the operator. `SQLField(String(column))` because
# `FieldPart`'s string member is `String` — widening the signature without converting only moves the
# `MethodError` into `SQLField`. The `SQLTypeFunction` arms are disjoint from `AbstractString`, so
# there is no ambiguity.
OP(column::AbstractString, value) = OperObject(operator="=", values=value, column=SQLField(String(column)))
OP(column::SQLTypeFunction, value) = OperObject(operator="=", values=value, column=column)
OP(column::AbstractString, operator::AbstractString, value) = OperObject(operator=String(operator), values=value, column=SQLField(String(column)))
OP(column::SQLTypeFunction, operator::AbstractString, value) = OperObject(operator=String(operator), values=value, column=column)

@kwdef mutable struct QObject <: SQLTypeQ
  filters::Vector{FilterType} # filters to be used in the query
end
function Base.deepcopy(q::QObject)
  return QObject(filters=deepcopy(q.filters))
end

@kwdef mutable struct QorObject <: SQLTypeQor
  or::Vector{FilterType} # filters to be used in the query
end
function Base.deepcopy(q::QorObject)
  return QorObject(or=deepcopy(q.or))
end

function Base.push!(q::SQLTypeQ, x...)
  for v in x
    if isa(v, Pair)
      push!(q.filters, _check_filter(v))
    elseif isa(v, FilterType)
      push!(q.filters, v)
    else
      throw(FilterError("Invalid argument: $(v); please use a pair (key => value) or a Q/Qor/OP object."))
    end
  end
  return q
end

function Base.push!(q::SQLTypeQor, x...)
  for v in x
    if isa(v, Pair)
      push!(q.or, _check_filter(v))
    elseif isa(v, FilterType)
      push!(q.or, v)
    else
      throw(FilterError("Invalid argument: $(v); please use a pair (key => value) or a Q/Qor/OP object."))
    end
  end
  return q
end


"""
    Interval(period)
    Interval(duration_string)

Explicit duration wrapper for F-expression date arithmetic (#25). Holds a Julia
`Dates.Period` / `Dates.CompoundPeriod`, or parses a portable time-duration string
(`"HH:MM:SS(.fff)"`, `"M:SS"`, or bare seconds) into a time-only `CompoundPeriod`.

`Interval(...)` is interchangeable with a bare period wherever date arithmetic is used —
`F("date") + Interval(Month(1))` is identical to `F("date") + Month(1)`. The string form is
the escape hatch for time-based intervals: `F("logged_at") + Interval("01:30:00")`.

Note: the name is shared with the `Intervals.jl` ecosystem — if you also `using Intervals`,
disambiguate as `PormG.QueryBuilder.Interval`.
"""
struct Interval
  period::Union{Dates.Period, Dates.CompoundPeriod}
end

# Parse a portable time-duration string into a time-only CompoundPeriod (Hour+Minute+Second
# [+sub-second]). Reuses the DurationField normalizer so accepted input formats stay identical,
# then rebuilds the period directly WITHOUT `canonicalize` (which would roll >=24h into days and
# >=7d into weeks — surprising for a time duration and would break the portable time-only guarantee).
function _parse_time_string_to_compoundperiod(s::AbstractString)::Dates.CompoundPeriod
  normalized = Models._normalize_duration_string(s)  # -> "±H:MM:SS(.fff)" (fields may exceed 2 digits,
                                                     # e.g. bare "120" seconds normalizes to "00:00:120")
  m = match(r"^(-?)(\d+):(\d+):(\d+)(?:\.(\d+))?$", normalized)
  m === nothing && throw(InvalidValueError("Interval: could not parse normalized duration '$(normalized)'"))
  sign = m.captures[1] == "-" ? -1 : 1
  parts = Dates.Period[Hour(sign * parse(Int, m.captures[2])),
                       Minute(sign * parse(Int, m.captures[3])),
                       Second(sign * parse(Int, m.captures[4]))]
  frac = m.captures[5]
  if frac !== nothing
    nanos = parse(Int, rpad(frac, 9, '0')[1:9])  # fractional seconds -> nanoseconds
    push!(parts, Nanosecond(sign * nanos))
  end
  return Dates.CompoundPeriod(parts)
end

Interval(s::AbstractString) = Interval(_parse_time_string_to_compoundperiod(s))

# #564 — the kind a rendered temporal expression EVALUATES TO, carried alongside its SQL text.
# `nothing` means "not a temporal expression, or one this build cannot type"; both consumers
# (the SQLite wrapper choice and the literal binder) treat it as "no representation to honour",
# which is what they did before the render carried a kind at all. Django's name for this is the
# expression's `output_field`.
const TemporalKind = Union{CanonicalType, Nothing}

# Duration operands accepted by F-expression +/- date arithmetic (#25).
const _DurationOperand = Union{Dates.Period, Dates.CompoundPeriod, Interval}

# ── The operand vocabulary, named ONCE (#533) ────────────────────────────────
#
# `_CompareOperand` (the comparison SIGNATURE) and `FExpression.operand` (the STORAGE slot) have to
# admit the same types, and until now each spelled its own list. Keeping two lists in step is the
# defect #494 was: the signature accepted `Date`/`DateTime` while the slot did not, so
# `F("date") == Date(2020,1,1)` died in `convert` naming an internal union. `test_f_date_operands.jl`
# has been asserting the two agree, by hand.
#
# They were spelled twice for a real reason, not carelessness: `_CompareOperand` names `FExpression`,
# and `FExpression.operand` would name `_CompareOperand` — a cycle. The slot reached for the ABSTRACT
# `SQLTypeF` to break it, and that is what silently admitted `OuterRefObject` (the other `SQLTypeF`
# subtype), which no `_set_update_query_operand` arm handles: it fell to the terminal `else` and was
# bound RAW as a parameter. Measured on origin/main: `PARAMS: Any[OuterRefObject("id")]`.
#
# The cycle breaks by naming the NON-circular halves here and composing on both sides. A struct may
# name itself in its own field types, so `FExpression` appears directly instead of through `SQLTypeF`,
# and the admission is a named seam again — the rule `CTEReference` and `JoinedReference` already follow.
#
# What the literal half holds, and the rule for adding to it (#536): a member is a SCALAR whose
# comparison binds — through the ROOTED COLUMN's own formatter — the same bytes the pair spelling
# `filter("col" => value)` binds, and `test_f_date_operands.jl`'s oracle table (`_FD_ORACLE_ROWS`)
# proves that per member, on both backends. The consumer half is the literal arm of
# `_set_update_query_operand` (`execution.jl`): it resolves the LEFT column with
# `_operand_column_field` and runs the value through that column's formatter, exactly as
# `_get_filter_query(::SQLTypeOper)` does for a pair. The three temporal members take the
# `_format_date_operand` arm beside it, which adds the DATE-vs-TIMESTAMP promotion.
#
# The arm is keyed by the COLUMN, not by the value's Julia type — that is what closed #536's two
# defects at once. `Float64` WAS a member and bound the raw Julia value where the pair path bound
# `format_number_sql`'s string; `Base.UUID` and `Dates.Time` had working formatters and were never
# admitted, so `F("uid") == uuid` fell through to `Base.==` and yielded a bare `Bool`. `Float16` /
# `Float32` / `Float64` rather than `Float64` alone for the same reason — `Float32` was the
# bare-`Bool` row in the issue's table — and rather than `AbstractFloat`, because those three are
# exactly the floats `format_number_sql` has a method for: a `BigFloat` member would type-check and
# then die inside the formatter (the #533 class, one level down), where a non-member is refused at
# the operator with a typed error.
#
# Deliberately out: `Decimals.Decimal`, `BigFloat` and other `Number`s (no formatter method or no
# oracle row, so no proof they bind identically — add both first), `Vector{UInt8}` and JSON (their
# scalar value is itself a collection, the trap `_format_filter_value` singles out, and neither has
# comparison semantics). Any other type is refused AT THE OPERATOR by `_unsupported_compare_operand`
# (`error_funnels.jl`) rather than left to `Base.==`; see the catch-all methods below `_CompareOperand`.
#
# Adding a member is still two halves: the union here AND an oracle row in `test_f_date_operands.jl`.
# The testset that walks `Base.uniontypes(_CompareLiteral)` fails on a member with no row, which is
# what keeps this comment a rule rather than a list.
const _CompareLiteral = Union{Integer,Float16,Float32,Float64,String,Base.UUID,Dates.Time,Dates.Date,Dates.DateTime,TimeZones.ZonedDateTime}
const _ColumnHandle   = Union{SQLTypeCTE,SQLTypeJoined}

# Carrier for an F reference and any arithmetic built on top of it. Users construct it through
# `F(field_name)` (documented below) and the Base.:+/-/*// overloads further down; the struct
# itself is internal.
@kwdef struct FExpression <: SQLTypeF
  # #481: `SQLTypeJoined` so a joined-copy reference can be the LEFT side of a comparison
  # (`Joined("d","driverid") == F("driverid")`). It renders through `_set_update_query`, the same
  # seam a `String` field_name uses.
  # #533: `FExpression`, not the abstract `SQLTypeF` — see the operand-vocabulary note above. The
  # abstract spelling also admitted `OuterRefObject`, which no renderer arm handles.
  field_name::Union{String,Integer,FExpression,SQLTypeFunction,SQLTypeJoined}
  operation::OptionalString = nothing  # +, -, *, /, etc.
  # Composed from the named halves above, so this slot and the `_CompareOperand` signature cannot
  # drift apart: widening one widens both, by construction rather than by a test that checks.
  #
  # `_DurationOperand` is the other half and is NOT part of `_CompareOperand`: those are the operands
  # #25 added for date ARITHMETIC (`F("seen") + Day(1)`), not for comparison. Conflating the two was
  # the whole of #494. `SQLTypeFunction` likewise — `F("x") * Sum("y")` is arithmetic.
  operand::Union{_CompareLiteral,_ColumnHandle,_DurationOperand,SQLTypeFunction,FExpression,Nothing} = nothing
  function_name::String = "F"
  column::Union{String,SQLTypeField,Vector{String}} = ""
  aggregate::Bool = false
  _as::OptionalString = nothing
  kwargs::Dict{String,Any} = Dict{String,Any}()
end

"""
    F(field_name::AbstractString) -> FExpression

Reference a **database column** rather than a Julia value (the Django `F()` equivalent). The
comparison or arithmetic happens inside SQL, so no data is pulled into Julia and the update stays
a single atomic statement.

`F` expressions support `+`, `-`, `*` and `/` against constants, other `F`s and SQL functions.
`+` and `-` additionally accept a `Dates` period or an [`Interval`](@ref), for date arithmetic
(`*` and `/` do not).

```julia
# Field-to-field comparison — grid position worse than finishing position
query = M.Result.objects.filter(F("grid") > F("positionorder"))

# Arithmetic projection, computed by the database
query = M.Result.objects
query.values("resultid", "adjusted" => F("points") * 2)

# Atomic update against the column's current value (no read-modify-write race)
M.Result.objects.filter("resultid" => 1).update("points" => F("points") + 1)

# Field-to-field update
M.Result.objects.filter("resultid" => 1).update("position" => F("positionorder"))
```

Prefer a plain lookup when the predicate compares against a *scalar*: write
`filter("points__@gt" => 20)`, not `filter(F("points") > 20)`.

Every operator builds a **new** expression and leaves its operands untouched, so one handle can be
bound to a name and reused across as many predicates as you like:

```julia
pts = F("points")
M.Result.objects.filter(pts > 10, pts < 25)   # two independent predicates on the same column
```

See also [Field Expressions](read/field_expressions.md).
"""
function F(field_name::AbstractString)
  # #603: `AbstractString` so a `SubString` out of `split(query_string, "=")` dispatches, then
  # normalized ONCE here — `FExpression.field_name` and `.column` are `String`-typed, and a
  # `Union{String,...}` slot without `Nothing` has no `convert` fallback, so an un-normalized view
  # would die one frame deeper with a raw `MethodError`. `String(x)`, not `string(x)`: `string` is
  # the identity for a `LazyString` (measured in #598).
  normalized_name = String(field_name)
  return FExpression(
    field_name=normalized_name,
    function_name="F",
    column=normalized_name
  )
end
# Arithmetic operations for F expressions
# Aggregate propagation helper: result is aggregate if any operand is aggregate
_is_agg(f::FExpression) = f.aggregate
_is_agg(f::SQLTypeFunction) = f.aggregate
_is_agg(::Any) = false

# #702 — the flag a WRAPPING constructor sets: does any argument hold an aggregate?
#
# `aggregate` is stored on the node, and three readers trust it without looking inside: the GROUP BY
# decision in `get_select_query`, the HAVING routing (`_aggregate_alias_leaf`, #692) and the
# `update()`/`delete()` refusals. So a wrapper that leaves it `false` over an aggregate argument
# does not merely mislabel itself — `Coalesce(Sum("points"), Value(0))` projected with no GROUP BY,
# and SQLite answered with ONE row for the whole table. Only the numeric wrappers and `F`
# arithmetic propagated it; every constructor that wraps an argument now asks this instead.
#
# The flag answers only what the node can see when it is BUILT. A condition that names an alias
# (`When("total__@gte" => 100)` over `"total" => Sum(…)`) holds the name, not the aggregate, so the
# build-time readers — GROUP BY and the two HAVING routings — ask `_resolved_agg` (build_query.jl,
# #722), which adds the aliases a projection reads. The `update()`/`delete()` refusals still read the
# node: an alias can only be read beside the projection that defines it, which they already refuse.
# So does `.aggregate()` (execution.jl), which checks each pair before any projection exists to read:
# `aggregate("t" => Sum(…), "big" => Case([When("t__@gte" => 1, …)]))` is refused with "must be an
# aggregate function". That is a loud over-refusal, never wrong SQL — an aggregate over another
# aggregate's alias is a feature of its own, not this flag's business.
#
# It looks through the containers an argument can arrive in: a `Vector` (the variadic wrappers), an
# operator (a `When` condition), and `Q`/`Qor` (a `When` condition too). Concrete types on purpose —
# each is the only subtype of its abstract parent. The depth cap is the one `_guard_no_handle`
# (`ctes.jl`) keeps for the same reason: `push!(q, q)` on a `Q` is a user-buildable cycle.
function _holds_agg(x, depth::Int = 0)::Bool
  depth > 32 && return false
  x isa AbstractVector && return any(v -> _holds_agg(v, depth + 1), x)
  x isa OperObject && return _holds_agg(x.column, depth + 1) || _holds_agg(x.values, depth + 1)
  x isa QObject && return _holds_agg(x.filters, depth + 1)
  x isa QorObject && return _holds_agg(x.or, depth + 1)
  return _is_agg(x)
end
_any_agg(args...)::Bool = any(_holds_agg, args)

function Base.:+(f::FExpression, operand::Union{Integer,Float64,String,FExpression,SQLTypeFunction})
  return FExpression(
    field_name=f.operation === nothing ? f.field_name : f,
    operation="+",
    operand=operand,
    function_name="F",
    column=f.operation === nothing ? (f.field_name isa String ? f.field_name : "") : "",
    aggregate=f.aggregate || _is_agg(operand)
  )
end

function Base.:-(f::FExpression, operand::Union{Integer,Float64,String,FExpression,SQLTypeFunction})
  return FExpression(
    field_name=f.operation === nothing ? f.field_name : f,
    operation="-",
    operand=operand,
    function_name="F",
    column=f.operation === nothing ? (f.field_name isa String ? f.field_name : "") : "",
    aggregate=f.aggregate || _is_agg(operand)
  )
end

function Base.:*(f::FExpression, operand::Union{Integer,Float64,String,FExpression,SQLTypeFunction})
  return FExpression(
    field_name=f.operation === nothing ? f.field_name : f,
    operation="*",
    operand=operand,
    function_name="F",
    column=f.operation === nothing ? (f.field_name isa String ? f.field_name : "") : "",
    aggregate=f.aggregate || _is_agg(operand)
  )
end

function Base.:/(f::FExpression, operand::Union{Integer,Float64,String,FExpression,SQLTypeFunction})
  return FExpression(
    field_name=f.operation === nothing ? f.field_name : f,
    operation="/",
    operand=operand,
    function_name="F",
    column=f.operation === nothing ? (f.field_name isa String ? f.field_name : "") : "",
    aggregate=f.aggregate || _is_agg(operand)
  )
end

# Date arithmetic with explicit Julia duration types (#25): F("date") + Day(30), - Hour(6),
# + (Month(1) + Day(15)), + Interval("01:30:00"), etc. Only + and - are meaningful — multiplying
# or dividing a date field by a duration is nonsense (`Day(30) * 2` is resolved by Julia's own
# Period arithmetic before it ever reaches an FExpression). A duration is never an aggregate, so
# `aggregate` propagates from `f` unchanged.
function Base.:+(f::FExpression, operand::_DurationOperand)
  return FExpression(
    field_name=f.operation === nothing ? f.field_name : f,
    operation="+",
    operand=operand,
    function_name="F",
    column=f.operation === nothing ? (f.field_name isa String ? f.field_name : "") : "",
    aggregate=f.aggregate
  )
end

function Base.:-(f::FExpression, operand::_DurationOperand)
  return FExpression(
    field_name=f.operation === nothing ? f.field_name : f,
    operation="-",
    operand=operand,
    function_name="F",
    column=f.operation === nothing ? (f.field_name isa String ? f.field_name : "") : "",
    aggregate=f.aggregate
  )
end

# Reversed + only: `Day(30) + F("date")` commutes to `F("date") + Day(30)`. Reversed - is omitted
# on purpose (`interval - date` is not valid date arithmetic).
Base.:+(operand::_DurationOperand, f::FExpression) = f + operand

# Comparison operations for F expressions
#
# #457 — a comparison RETURNS a new expression; it NEVER mutates `f`. Until this, all six wrote
# `f.operation`/`f.operand` onto the left-hand object and handed the same object back whenever
# `f.operation === nothing`, which cost two things:
#
#   - **A self-cycle.** `f = F("sku"); g = (f == f)` stored `f` on `f`, so `g.operand === g`. Every
#     UNCAPPED recursive walker over an expression then ran forever. On the `on()`/`cjoin()` route that is
#     `Base.deepcopy(::FExpression)`: the depth-capped handle sweep in `_prefix_join_filter` runs and
#     returns cleanly, and the `deepcopy` beside it is what overflows — the guard was reached, it just
#     was never the thing that could help. `.filter(g)` overflowed in the render walker instead. Julia
#     reports either as "program state may be corrupted", from ordinary user code.
#   - **Silent wrong SQL on a reused handle.** `f = F("note"); f > "a"; f < "z"` rendered
#     `(("note" > ?) < ?)`: the second comparison found the operation the first had written and
#     nested it. A handle bound to a name was single-use, and nothing said so.
#
# Arithmetic (`+ - * /` above) has always built a new expression; this brings comparisons in line, and
# matches every comparable ORM — Django's `Combinable`, SQLAlchemy's `ClauseElement`, Ecto's query
# AST, jOOQ and peewee all return a new node and leave the operand untouched. Making THIS cycle
# unrepresentable is why no depth guard was added for it. It is not the only cycle a user can build —
# `q = Q("x" => 1); push!(q, q)` is a container cycle from exported spellings, and the depth cap in
# `_guard_no_handle` (ctes.jl) is what absorbs that one.
#
# The operand union is the dispatch contract for a `CTE(...)` / `Joined(...)` right-hand side
# (#444/#481) — narrowing it would make those comparisons fall through to `Base.==` and silently
# yield a `Bool`. It is reproduced verbatim from the six pre-#457 signatures; #457 named it, it did
# not redraw it.
#
# #494 closed the one gap #457 recorded here and left open: `Dates.Date` and `Dates.DateTime`
# dispatched through this union — in BOTH families that share it, the `F` comparisons below and the
# `JoinedReference` ones further down — and then died in the constructor, because
# `FExpression.operand` admitted `Period`/`CompoundPeriod`/`Interval` (the #25 duration operands, for
# date ARITHMETIC) but neither `Date` nor `DateTime` (comparison operands). `F("date") == Date(2020)`
# raised a bare `MethodError` from `convert`, outside the #231 taxonomy. The field now admits both,
# so the signature and the slot agree — `test_f_date_operands.jl` asserts every member of this union
# is storable, so the two cannot drift apart again silently.
#
# The union is still the dispatch contract for a `CTE(...)` / `Joined(...)` right-hand side. #533
# made "keep additions to it and to `FExpression.operand` in step" structural rather than a rule to
# remember: both are now COMPOSED from `_CompareLiteral` / `_ColumnHandle` (declared above the
# struct), so widening one widens the other. The CONSUMER half is no longer per-type either (#536):
# the literal arm of `_set_update_query_operand` (`execution.jl`) binds every `_CompareLiteral`
# scalar through the rooted column's formatter, so a new member cannot bind RAW — what it can still
# lack is PROOF, and that is the oracle row `test_f_date_operands.jl` demands per member. A column
# HANDLE (`_ColumnHandle`) is the other kind of operand and renders as a column reference, never a
# bound value; `test_node_admission.jl` is what fails when a NODE type is admitted without a consumer.
const _CompareOperand = Union{_CompareLiteral,_ColumnHandle,FExpression}

function _compare(f::FExpression, operation::String, operand)
  if f.operation === nothing
    # A bare handle: carry every other slot across unchanged, so the built expression is identical to
    # what the mutating form left behind and the rendered SQL is byte-for-byte the same.
    #
    # `kwargs` is copied defensively, not because anything needs it: no builder or render path
    # CONSUMES an `FExpression`'s `kwargs` — every `.kwargs` reader in the builder is typed
    # `SQLTypeFunction` / `WindowFunction` / `FObject`, and the only code touching this one is
    # `Base.deepcopy` and this function. `column` is NOT copied, and that is not a claim that it
    # could not be — `SQLField` and `Vector{String}` are mutable too. It is simply left as the
    # pre-#457 object left it, sharing by reference, which keeps the built expression byte-identical
    # to what the mutating form produced. So the guarantee this makes is narrow and exact — the
    # HANDLE comes back with no operation of its own — not that the two objects share no structure.
    return FExpression(field_name=f.field_name, operation=operation, operand=operand,
                       function_name=f.function_name, column=f.column,
                       aggregate=f.aggregate, _as=f._as, kwargs=copy(f.kwargs))
  end
  # Already carries an operation, so this comparison is over the whole expression: nest it, exactly as
  # the previous `else` branch did.
  return FExpression(field_name=f, operation=operation, operand=operand,
                     function_name="F", column="", aggregate=f.aggregate)
end

Base.:(==)(f::FExpression, operand::_CompareOperand) = _compare(f, "=", operand)
Base.:(!=)(f::FExpression, operand::_CompareOperand) = _compare(f, "!=", operand)
Base.:>(f::FExpression, operand::_CompareOperand)    = _compare(f, ">", operand)
Base.:<(f::FExpression, operand::_CompareOperand)    = _compare(f, "<", operand)
Base.:>=(f::FExpression, operand::_CompareOperand)   = _compare(f, ">=", operand)
Base.:<=(f::FExpression, operand::_CompareOperand)   = _compare(f, "<=", operand)

# #536 — a right-hand side OUTSIDE `_CompareOperand` used to fall through to `Base.==` (identity)
# and evaluate to a bare `Bool`, which `filter(...)` then reported as *"Invalid filter argument:
# false"* — naming a value the user never wrote (#530's complaint, on every type the union omits).
# Each operator now refuses with a `QueryBuildError` naming the type and the supported vocabulary.
#
# SQLAlchemy is the prior art: `column == object()` raises `ArgumentError: SQL expression element
# expected` rather than answering `False`. Django has no equivalent — its `F()` does not overload
# comparison at all.
#
# Only the expression-on-the-LEFT forms are covered. `1.5 == F("a")` still reaches Base's fallback
# and answers `false`: a `(::Any, ::FExpression)` method would collide with every left-typed `==`
# in Base, and the issue's table is the left-hand form. Out of scope here; #541 owns the
# node-as-container question (`isequal`/`in`) these methods sit beside and do not change.
#
# The `::Missing` / `::WeakRef` arms are NOT redundant. Measured on 1.12: Base defines
# `==(::Any, ::Missing)` and `<(::Any, ::Missing)` (missing.jl) and `==(::Any, ::WeakRef)`
# (gcutils.jl) — no others in the six — so those three signatures are ambiguous with the `::Any`
# arm, and Aqua's ambiguity check is what pins the set. `!=`, `>`, `<=`, `>=` have no such Base
# method and need no arm. They refuse exactly as the `::Any` arm does.
#
# The `JoinedReference` family gets the same twelve further down, generated in the same loop as
# its comparison methods — a second, independent site, so it is asserted separately in
# `test_f_date_operands.jl` rather than assumed to follow.
for (op, sym) in ((:(==), "="), (:(!=), "!="), (:(>), ">"), (:(<), "<"), (:(>=), ">="), (:(<=), "<="))
  @eval function Base.$op(x::FExpression, operand)
    # #603: a non-`String` `AbstractString` (a `SubString` from a query string, a `LazyString`)
    # is outside `_CompareOperand`, so it lands HERE and used to be refused for the wrong reason —
    # its type was fine, only its spelling was not. Normalize and re-dispatch to the
    # `_CompareOperand` arm above rather than admitting `AbstractString` into `_CompareLiteral`:
    # that union owes an oracle row per member (#533, and the note above it), and a method on
    # `::AbstractString` beside one on `::_CompareOperand` — which contains `String` — is ambiguous
    # in both directions. `String(x)` always returns a `String`, which IS in the union, so the
    # recursion terminates in exactly one hop.
    operand isa AbstractString && return Base.$op(x, String(operand))
    throw(_unsupported_compare_operand($sym, operand))
  end
end
Base.:(==)(::FExpression, operand::Missing) = throw(_unsupported_compare_operand("=", operand))
Base.:(==)(::FExpression, operand::WeakRef) = throw(_unsupported_compare_operand("=", operand))
Base.:<(::FExpression, operand::Missing)    = throw(_unsupported_compare_operand("<", operand))

# #536 — and the `isequal` half, mirroring the guard `JoinedReference` has carried since #481 (see
# that block further down). Base's fallback is `isequal(x, y) = x == y`, so without these the
# catch-alls above would make `isequal(F("a"), nothing)` THROW where it used to answer `false` — and
# `isequal` is the total hashing-equality contract `Dict`/`Set`/`unique`/`findfirst(isequal(x), …)`
# rely on; it must never throw. Identity for two nodes, `false` against anything else; the `::Missing`
# arm disambiguates against Base's `isequal(::Any, ::Missing)` exactly as the Joined block does.
# This is the `isequal` half of #541's option 1, applied here only for consistency with
# `JoinedReference`; `in` / `findfirst(==(x), …)` still reach `==` and remain #541's open question.
Base.isequal(a::FExpression, b::FExpression) = a === b
Base.isequal(::FExpression, ::Any) = false
Base.isequal(::FExpression, ::Missing) = false

# Allow arithmetic operations with F expressions on the right side
function Base.:+(operand::Union{Integer,Float64}, f::FExpression)
  return FExpression(
    field_name=f.field_name,
    operation="+",
    operand=operand,
    function_name="F",
    column=f.field_name,
    aggregate=f.aggregate
  )
end

function Base.:*(operand::Union{Integer,Float64}, f::FExpression)
  return FExpression(
    field_name=f.field_name,
    operation="*",
    operand=operand,
    function_name="F",
    column=f.field_name,
    aggregate=f.aggregate
  )
end

# `<: SQLTypeF` on purpose, and — unlike `CTEReference` / `JoinedReference` below — every union the
# abstract type reaches is a place an outer-row reference is legitimate SQL: the ~18 scalar-function
# signatures in `functions.jl` and `WindowColumnPart` (`Lower(OuterRef("surname"))`,
# `Lag(OuterRef("id"), over = …)` inside a correlated subquery). #535 gave the build side the one
# consumer it lacked (`_check_function(::OuterRefObject)`, build_helpers.jl); the render side always
# resolved it against `instruc.outer` or refused with `QueryBuildError`. The ONE union it must not
# reach is `FExpression.operand` — `F("a") == OuterRef("b")` has no render arm and would bind the
# handle RAW — which is why that slot names `FExpression` rather than `SQLTypeF` (#533).
@kwdef struct OuterRefObject <: SQLTypeF
  field_name::String
end

"""
    OuterRef(field_name::AbstractString) -> OuterRefObject

Reference a column of the **enclosing** query from inside a subquery — the correlation that turns
an independent child query into a per-outer-row one. Use it inside the query you hand to
[`Exists`](@ref) or [`Subquery`](@ref).

```julia
# "did this driver set a lap under 90 s in this race?" — both columns come from the outer row
fast_laps = M.Lap_times.objects.filter(
    "raceid"             => OuterRef("raceid"),
    "driverid"           => OuterRef("driverid"),
    "milliseconds__@lte" => 90_000,
)

query = M.Result.objects.filter(Exists(fast_laps))
```

`OuterRef("pk")` resolves to the outer model's primary key, so a correlation does not have to
name the column: `filter("driverid" => OuterRef("pk"))` against an outer `M.Driver` query.

Two limits, both enforced with a `QueryBuildError`:

- **One level only.** It binds to the immediately enclosing query, so a projected subquery nested
  inside another projected subquery is rejected rather than silently correlated to the wrong level.
- **Correlated context required.** Used outside an `Exists`/`Subquery` build there is no outer
  query to bind to — wrapped in a function or not.

An outer column may be wrapped in a scalar function or a window column inside the correlated query
— `Lower(OuterRef("surname"))`, `Cast(OuterRef("driverid"), "text")`, `Lag(OuterRef("driverid"),
over = …)` — and resolves against the outer row exactly as the bare reference does.

Correlate on a base column of the outer model. A joined path (`OuterRef("constructorid__name")`)
adds a join to the outer query and is outside the validated surface.
"""
function OuterRef(field_name::AbstractString)
  normalized = String(field_name)
  isempty(normalized) && throw(QueryBuildError("OuterRef requires a non-empty field name"))
  return OuterRefObject(field_name=normalized)
end

# #444 — a CTE column reference. `SQLTypeCTE` (Kernel.jl) was declared with zero subtypes and zero
# uses; this is what it was reserved for. Deliberately NOT `<: SQLTypeF`: that would auto-admit the
# type into `FilterType`, `FObject.column` and the ~18 `functions.jl` unions for free, which is
# exactly the hazard — `Sum(CTE(...))` would silently construct (it is refused, see functions.jl)
# and a bare `filter(CTE("ev","sku"))` with no pair would parse as a standalone filter. Every
# admission below is a named seam, on purpose.
@kwdef struct CTEReference <: SQLTypeCTE
  name::String        # the `.with(...)` label this column belongs to
  path::String        # a field path INSIDE that CTE
  desc::Bool = false  # order_by only; refused everywhere else
end

"""
    CTE(name::AbstractString, path::AbstractString; desc::Bool = false) -> CTEReference

Reference a column of a CTE declared with [`.with(...)`](@ref object) as an **object** rather than
as the ordinary `"<name>__<path>"` string. Both spellings mean the same column and render identical
SQL; the object is the **disambiguator** (#444, #492).

A CTE name that collides with nothing needs no object — `values("ev__sku")` is the idiomatic
spelling. Write the handle when the CTE's name *also* names something on the model, because then the
shared `__` path has two readings and PormG refuses to choose:

```julia
driver_totals = M.Result.objects
driver_totals.values("driverid", "n" => Count("resultid"))

q = M.Result.objects
q.with("driverid" => driver_totals)       # "driverid" is ALSO a ForeignKey of Result
q.values("points", "driverid__surname")   # → AmbiguousFieldError: the FK, or the CTE?
q.values("points", "n" => CTE("driverid", "n"))   # the CTE's column, explicitly
```

It is also required on the **right** of a filter pair, where a bare string is a value rather than a
column: `filter("surname" => CTE("d91", "surname"))` correlates, while
`filter("surname" => "d91__surname")` compares `surname` against that literal text — quietly
matching nothing on a text column, and raising `FilterError` on a numeric one.

The second argument is a **path**, not a bare column, and carries the same `__` vocabulary the rest
of PormG uses — a hop out of the CTE through a projected ForeignKey, a JSON sub-path, or an operator
suffix:

```julia
q.filter(CTE("ev", "sku") => "ABC")                       # plain column
q.values("s" => CTE("ev", "parent__sku"))                 # hop through a projected FK
q.filter(CTE("ev", "meta__driver") => "senna")            # JSON sub-path
q.filter(CTE("ev", "seen__@yyyy_mm__@lte") => "1991-10")  # operator suffix
q.order_by(CTE("monaco_stats", "total_points"; desc = true))
```

An unaliased projection is named by joining the two with a double underscore —
`values(CTE("parent", "sku"))` emits the output column `parent__sku`, byte-identical to what
`values("parent__sku")` produces.

SQL functions, aggregates and window clauses accept a handle wherever they accept a field path —
`Lower(CTE("ev","sku"))`, `Cast(CTE("ev","qty"), "text")`, `Sum(CTE("ev","qty"))`,
`Rank(over = WindowOver(partition_by = CTE("ev","sku")))`.

`desc = true` is meaningful in `order_by(...)` and in a window's `order_by`; anywhere else it raises
a `QueryBuildError`. Both take the string's `-` prefix too, so it is a convenience rather than the
only way to order descending. A CTE column cannot be referenced from `on(...)`, `cjoin(...)` or
`cjoin_on(...)` — those clauses target model relations — however it is spelled, including as the
operand of an `F` comparison.

See also [Subqueries and CTEs](read/subqueries_and_ctes.md).
"""
function CTE(name::AbstractString, path::AbstractString; desc::Bool=false)
  normalized_name = String(name)
  normalized_path = String(path)
  isempty(normalized_name) && throw(QueryBuildError("CTE requires a non-empty CTE name"))
  # Refused HERE rather than at build time, where the same mistake surfaced as
  # "CTE reference 'ev' must include a field name" after a join had already been planned.
  isempty(normalized_path) && throw(QueryBuildError(
    "CTE(\e[4m\e[31m$(normalized_name)\e[0m, \"\") requires a column path inside the CTE. " *
    "Example: \e[4m\e[32mCTE(\"$(normalized_name)\", \"sku\")\e[0m."))
  # The CTE NAME is not identifier-validated here on purpose: `_with` already validates it
  # fail-closed at declaration (#394), and duplicating the check would fire with a less specific
  # message on the call that is not the one at fault.
  return CTEReference(name=normalized_name, path=normalized_path, desc=desc)
end

# The output/cache spelling of a CTE reference — `name__path`. It is byte-identical to what the
# pre-#444 string form produced, which is what lets every `_as`-keyed consumer downstream
# (`instruct.cache`, `tab_field_cache`, ORDER BY alias matching, the #352/#373 sargable rewrite,
# the #441 duplicate-projection guard, and result-column names) keep working unchanged.
_cte_as(name::AbstractString, path::AbstractString) = string(name, "__", path)
_cte_as(ref::CTEReference) = _cte_as(ref.name, ref.path)

# Guard for every site that accepts a CTE reference but cannot express an ordering direction.
function _reject_cte_desc(ref::CTEReference, context::AbstractString)
  ref.desc && throw(QueryBuildError(
    "\e[4m\e[31mdesc = true\e[0m on \e[4m\e[31mCTE(\"$(ref.name)\", \"$(ref.path)\")\e[0m is only " *
    "meaningful in \e[4m\e[32morder_by(...)\e[0m, not in $(context). Drop it here."))
  return ref
end

# #481 — a column of a `cjoin_on` joined copy. Same shape and the same reasoning as `CTEReference`
# one level up: NOT `<: SQLTypeF`, so it is not auto-admitted into `FilterType`, `FObject.column`
# and the ~18 `functions.jl` unions; every admission is a named seam. It is also NOT `<: SQLTypeCTE`,
# because the two are opposites at the one place it matters — a CTE handle is REFUSED inside a join
# ON clause (`_guard_no_cte_reference`), which is exactly where a joined-copy reference belongs.
#
# Immutable: nothing rewrites a reference in place, and the retag walker replaces rather than
# mutates. That also makes it safe to share between a `deepcopy`'d field and its original.
struct JoinedReference <: SQLTypeJoined
  alias::String       # the `cjoin_on(...; alias = ...)` label this column belongs to
  path::String        # a column ON THAT MODEL (optionally with an operator suffix)
  desc::Bool          # order_by only; refused everywhere else
end

"""
    Joined(alias::AbstractString, path::AbstractString; desc::Bool = false) -> JoinedReference

Reference a column of the joined copy declared by [`.cjoin_on(...)`](@ref object). The joined copy's
columns live in their **own namespace**, so an alias may share a name with a model field or with a
CTE and neither shadows the other (#481):

```julia
q = M.Result.objects
q.cjoin_on(M.Driver, alias = "d", on = [Joined("d", "driverid") == F("driverid")])
q.values("points", "who" => Joined("d", "surname"))
q.filter(Joined("d", "nationality") => "Brazilian")
```

Inside a `cjoin_on` `on` list the two sides of the join are named by how you write the reference:

| You write | Resolves to |
|-----------|-------------|
| `F("col")` (bare) | the **base** table — the query's own model |
| `Joined("d", "col")` | the **joined copy** declared under `alias = "d"` |

A reference may name **another** `cjoin_on`'s alias, which is how a join correlates against a third
table; the emission-order rule in [Custom Joins](read/custom_joins.md) still applies. Operator
suffixes work in `filter(...)`, so a comparison against a literal on the joined side is an ordinary
pair — `filter(Joined("d", "points__@gte") => 3)`.

`desc = true` is meaningful in `order_by(...)` and in a window's `order_by`; anywhere else it raises
a `QueryBuildError`. An unaliased projection is named by joining the two with a double underscore,
so `values(Joined("d", "surname"))` emits the output column `d__surname`.

This replaces the `F("d.surname")` dotted-string spelling, which was removed in the same change: it
resolved fail-open (a typo in the alias reported an unknown *field* named `"typo.col"`), it could not
carry an operator suffix, and the bare string form could not be projected — `values("d.surname")`
raised, because the dotted branch lived on the filter resolver only. (Wrapped in `F(...)` it did
project, since `F` routes through that resolver.)

See also [Custom Joins](read/custom_joins.md).
"""
function Joined(alias::AbstractString, path::AbstractString; desc::Bool=false)
  normalized_alias = String(alias)
  normalized_path = String(path)
  isempty(normalized_alias) && throw(QueryBuildError("Joined requires a non-empty cjoin_on alias"))
  isempty(normalized_path) && throw(QueryBuildError(
    "Joined(\e[4m\e[31m$(normalized_alias)\e[0m, \"\") requires a column on the joined model. " *
    "Example: \e[4m\e[32mJoined(\"$(normalized_alias)\", \"surname\")\e[0m."))
  # The alias is not identifier-validated here on purpose: `_cjoin_on` already validates it
  # fail-closed at declaration, and an alias that could not pass that check can never match a
  # declared one — so it reports as an unknown alias, naming the ones that exist.
  return JoinedReference(normalized_alias, normalized_path, desc)
end
Base.show(io::IO, x::JoinedReference) = print(io, "Joined(\"", x.alias, "\", \"", x.path, "\")")
# `Base.:(==)` on this type builds a PREDICATE (see the comparison methods below), so the generic
# `isequal` fallback — which calls `==` and expects a Bool — would throw a TypeError on any value
# comparison: `isequal(a, b)`, `a in [b]`, `findfirst(==(a), v)`. The struct is immutable and every
# field is compared by value in `hash`, so identity is the right answer here and it keeps
# `Dict`/`Set`/`unique` behaving. `FExpression` carries the same hazard without this guard; adding
# it there is a separate change with its own blast radius.
Base.isequal(a::JoinedReference, b::JoinedReference) = a === b
# ...and against anything else. The comparison methods below accept several operand types, so
# without this a HETEROGENEOUS container (`isequal(handle, "d__x")`, `isequal(handle, CTE(...))`)
# would still route through `==` and throw. First argument is ours, so this is not piracy.
#
# The `::Missing` arm is NOT redundant: Base defines `isequal(::Any, ::Missing)` (missing.jl), so
# the `::Any` method alone is ambiguous with it for `isequal(handle, missing)` — Aqua's method
# ambiguity check caught exactly that. Answering `false` matches what Base's method would have
# returned, so the disambiguation changes no result.
Base.isequal(::JoinedReference, ::Any) = false
Base.isequal(::JoinedReference, ::Missing) = false

# The output/cache spelling of a joined-copy reference — `alias__path`, matching `_cte_as`'s shape
# one level up, so every `_as`-keyed consumer downstream reads a name the caller can recognise.
_joined_as(alias::AbstractString, path::AbstractString) = string(alias, "__", path)
_joined_as(ref::JoinedReference) = _joined_as(ref.alias, ref.path)

# Guard for every site that accepts a joined reference but cannot express an ordering direction.
function _reject_joined_desc(ref::JoinedReference, context::AbstractString)
  ref.desc && throw(QueryBuildError(
    "\e[4m\e[31mdesc = true\e[0m on \e[4m\e[31mJoined(\"$(ref.alias)\", \"$(ref.path)\")\e[0m is only " *
    "meaningful in \e[4m\e[32morder_by(...)\e[0m, not in $(context). Drop it here."))
  return ref
end

# #509 — the SQLOrder-specific refusal, and NOT `_reject_cte_desc(ref, "an SQLOrder")`: that
# message reads *"`desc = true` is only meaningful in order_by(...)"*, which is false here and
# actively misleading, because an `SQLOrder` IS an ordering term. What is wrong is not the place,
# it is the duplication — two spellings for one direction — so the message names the slot that
# wins instead.
function _reject_handle_desc_in_sqlorder(ref::CTEReference)
  ref.desc && throw(QueryBuildError(
    "\e[4m\e[31mdesc = true\e[0m on \e[4m\e[31mCTE(\"$(ref.name)\", \"$(ref.path)\")\e[0m cannot be " *
    "combined with \e[4m\e[32mSQLOrder\e[0m, which carries the direction in its own " *
    "\e[4m\e[32morientation\e[0m. Write \e[4m\e[32mSQLOrder(CTE(\"$(ref.name)\", " *
    "\"$(ref.path)\"); orientation = \"DESC\")\e[0m (#509)."))
  return ref
end
function _reject_handle_desc_in_sqlorder(ref::JoinedReference)
  ref.desc && throw(QueryBuildError(
    "\e[4m\e[31mdesc = true\e[0m on \e[4m\e[31mJoined(\"$(ref.alias)\", \"$(ref.path)\")\e[0m cannot " *
    "be combined with \e[4m\e[32mSQLOrder\e[0m, which carries the direction in its own " *
    "\e[4m\e[32morientation\e[0m. Write \e[4m\e[32mSQLOrder(Joined(\"$(ref.alias)\", " *
    "\"$(ref.path)\"); orientation = \"DESC\")\e[0m (#509)."))
  return ref
end

# #481 — the six comparisons with a JOINED-COPY reference on the LEFT, which is the spelling a
# `cjoin_on` ON clause is written in: `Joined("d","driverid") == F("driverid")`.
#
# Defined HERE, after the struct, because a method signature is evaluated when the method is
# defined — not lazily like its body — so these cannot sit beside the `FExpression` comparisons
# further up the file.
#
# They build an `FExpression` so the result is a `FilterType` and takes the identical render path as
# the `F(...)`-on-the-left form: `_set_update_query` resolves the `field_name` slot, which admits
# `SQLTypeJoined`. Unlike the `F` methods there is no in-place arm — a `JoinedReference` is
# immutable and has no `operation` slot to fill, so every comparison constructs, which also means
# `j == j` cannot build the self-cycle `f == f` did (#457). `_reject_joined_desc` fires because an
# ordering direction cannot mean anything in a predicate.
#
# The operand type is the SHARED `_CompareOperand`, not a second copy of the same union: the two
# families must admit exactly the same right-hand sides, and a union spelled twice drifts silently —
# a member added to one side would make `Joined(...) == CTE(...)` and `F(...) == CTE(...)` disagree.
#
# #536 — and the same refusal for an operand OUTSIDE the union, so `Joined("r","uid") == 1//2`
# raises the same `QueryBuildError` the `F` twin does instead of answering `false` from `Base.==`.
# The `::Missing` / `::WeakRef` arms mirror the `FExpression` set above, for the same three
# ambiguities with Base. `isequal(::JoinedReference, ::Any)` above is untouched: it never reaches
# `==`, so containers keep behaving.
for (op, sym) in ((:(==), "="), (:(!=), "!="), (:(>), ">"), (:(<), "<"), (:(>=), ">="), (:(<=), "<="))
  @eval function Base.$op(j::JoinedReference, operand::_CompareOperand)
    _reject_joined_desc(j, "a comparison")
    return FExpression(field_name=j, operation=$sym, operand=operand, function_name="F", column="", aggregate=false)
  end
  @eval function Base.$op(x::JoinedReference, operand)
    # #603: the `FExpression` twin of this branch, for the same reason and with the same
    # termination argument — see the note on that loop above. Spelled out here rather than shared,
    # because this family is generated independently and `test_f_date_operands.jl` asserts the two
    # separately rather than assuming one follows the other.
    operand isa AbstractString && return Base.$op(x, String(operand))
    throw(_unsupported_compare_operand($sym, operand))
  end
end
Base.:(==)(::JoinedReference, operand::Missing) = throw(_unsupported_compare_operand("=", operand))
Base.:(==)(::JoinedReference, operand::WeakRef) = throw(_unsupported_compare_operand("=", operand))
Base.:<(::JoinedReference, operand::Missing)    = throw(_unsupported_compare_operand("<", operand))

#
# SQLTypeFunction Objects (functions from sql)
#

@kwdef struct FObject <: SQLTypeFunction
  function_name::String
  # #444: `SQLTypeCTE` is admitted for the TRANSFORM path — `CTE("ev", "seen__@yyyy_mm__@lte")`
  # builds a `ToChar` over the CTE's column, and the retag puts the handle here. It does NOT open the
  # aggregate door: `Sum`/`Avg`/`Count`/`Max`/`Min` refuse a `CTEReference` at the constructor
  # (functions.jl), so no aggregate FObject can ever be built holding one.
  column::Union{String,SQLTypeField,SQLTypeText,SQLTypeCTE,SQLTypeJoined,N,Vector{N},Vector{T},SQLTypeOper,SQLTypeQ,SQLTypeQor,SQLTypeF} where {N<:SQLTypeFunction,T}
  aggregate::Bool = false
  formatter::Union{Nothing,Function} = nothing # function to format the value
  _as::OptionalString = nothing
  kwargs::Dict{String,Any} = Dict{String,Any}()
end
"""
    WindowSpec <: SQLType

The `OVER (...)` clause of a window function, in structured form.

# Fields
- `partition_by::Vector` — the grouping the window restarts on. Empty means one window over
  the whole result set.
- `order_by::Vector` — the ordering inside each window, stored **as given**: a `"-points"`
  entry stays `"-points"`, and the `-` prefix is resolved to `DESC` at build time.
- `frame::Union{String,Nothing}` — an explicit frame clause, or `nothing` for the SQL default
  (`RANGE BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW`). PostgreSQL only. Held in the grammar
  [`WindowOver`](@ref) documents: `WindowOver` stores its own rebuilt spelling, and a frame
  assigned here directly is parsed when the query is built, raising `InvalidValueError` if it is
  outside that grammar.

Build one with [`WindowOver`](@ref), which validates and coerces its arguments; the `@kwdef`
constructor is exported for the rare case where you want to assemble or mutate a spec
directly. The same spec can be reused across several window functions in one query.

See also [Window Functions](@ref).
"""
@kwdef mutable struct WindowSpec <: SQLType
  partition_by::Vector{WindowPartitionPart} = WindowPartitionPart[]
  order_by::Vector{WindowOrderPart} = WindowOrderPart[]
  frame::OptionalString = nothing
end
function Base.deepcopy(w::WindowSpec)
  return WindowSpec(
    partition_by=deepcopy(w.partition_by),
    order_by=deepcopy(w.order_by),
    frame=w.frame
  )
end

@kwdef struct WindowFunction <: SQLTypeFunction
  function_name::String
  column::WindowColumnPart = nothing
  over::WindowSpec
  aggregate::Bool = false
  formatter::Union{Nothing,Function} = nothing
  _as::OptionalString = nothing
  kwargs::Dict{String,Any} = Dict{String,Any}()
end
_is_agg(::WindowFunction) = false
_is_window_expr(::WindowFunction) = true
_is_window_expr(f::FExpression) = _is_window_expr(f.field_name) || _is_window_expr(f.operand)
_is_window_expr(f::FObject) = _is_window_expr(f.column)
_is_window_expr(values::Vector) = any(_is_window_expr, values)
_is_window_expr(::Any) = false

function Base.:+(f::WindowFunction, operand::Union{Integer,Float64,String,FExpression,SQLTypeFunction})
  return FExpression(field_name=f, operation="+", operand=operand, function_name="F", column="", aggregate=_is_agg(operand))
end
function Base.:-(f::WindowFunction, operand::Union{Integer,Float64,String,FExpression,SQLTypeFunction})
  return FExpression(field_name=f, operation="-", operand=operand, function_name="F", column="", aggregate=_is_agg(operand))
end
function Base.:*(f::WindowFunction, operand::Union{Integer,Float64,String,FExpression,SQLTypeFunction})
  return FExpression(field_name=f, operation="*", operand=operand, function_name="F", column="", aggregate=_is_agg(operand))
end
function Base.:/(f::WindowFunction, operand::Union{Integer,Float64,String,FExpression,SQLTypeFunction})
  return FExpression(field_name=f, operation="/", operand=operand, function_name="F", column="", aggregate=_is_agg(operand))
end

function Base.:+(operand::Union{Integer,Float64}, f::WindowFunction)
  return FExpression(field_name=f, operation="+", operand=operand, function_name="F", column="", aggregate=false)
end

function Base.:*(operand::Union{Integer,Float64}, f::WindowFunction)
  return FExpression(field_name=f, operation="*", operand=operand, function_name="F", column="", aggregate=false)
end

# Arithmetic operations for FObject (aggregate functions like Sum, Count, Avg)
# Enable expressions like Sum("points") / Count("resultid")
function Base.:+(f::FObject, operand::Union{Integer,Float64,String,FExpression,FObject})
  return FExpression(field_name=f, operation="+", operand=operand, function_name="F", column="", aggregate=f.aggregate || _is_agg(operand))
end
function Base.:-(f::FObject, operand::Union{Integer,Float64,String,FExpression,FObject})
  return FExpression(field_name=f, operation="-", operand=operand, function_name="F", column="", aggregate=f.aggregate || _is_agg(operand))
end
function Base.:*(f::FObject, operand::Union{Integer,Float64,String,FExpression,FObject})
  return FExpression(field_name=f, operation="*", operand=operand, function_name="F", column="", aggregate=f.aggregate || _is_agg(operand))
end
function Base.:/(f::FObject, operand::Union{Integer,Float64,String,FExpression,FObject})
  return FExpression(field_name=f, operation="/", operand=operand, function_name="F", column="", aggregate=f.aggregate || _is_agg(operand))
end


# Commutative: scalar op FObject
function Base.:+(operand::Union{Integer,Float64}, f::FObject)
  return FExpression(field_name=f, operation="+", operand=operand, function_name="F", column="", aggregate=f.aggregate)
end

function Base.:*(operand::Union{Integer,Float64}, f::FObject)
  return FExpression(field_name=f, operation="*", operand=operand, function_name="F", column="", aggregate=f.aggregate)
end


# ---
# Bitwise expression types and operands (narrow overloads to prevent spooky dispatch)
# ---
const BitwiseExpression = Union{FExpression,WindowFunction,FObject}
const BitwiseOperand = Union{Integer,FExpression,WindowFunction,FObject}

_bitwise_is_agg(f::BitwiseExpression) = f.aggregate
_bitwise_is_agg(::Integer) = false

function _build_bitwise_expr(left, op::String, right)
  return FExpression(
    field_name=left isa FExpression && left.operation === nothing ? left.field_name : left,
    operation=op,
    operand=right,
    function_name="F",
    column=left isa FExpression && left.operation === nothing ? (left.field_name isa String ? left.field_name : "") : "",
    aggregate=_bitwise_is_agg(left) || _bitwise_is_agg(right)
  )
end

function _build_bitwise_unary(expr, op::String)
  return FExpression(
    field_name=expr,
    operation=op,
    operand=nothing,
    function_name="F",
    column="",
    aggregate=_bitwise_is_agg(expr)
  )
end

# Overload Base operators
function Base.:&(a::BitwiseExpression, b::BitwiseOperand)
  return _build_bitwise_expr(a, "&", b)
end
function Base.:&(a::Integer, b::BitwiseExpression)
  return _build_bitwise_expr(b, "&", a)
end

function Base.:|(a::BitwiseExpression, b::BitwiseOperand)
  return _build_bitwise_expr(a, "|", b)
end
function Base.:|(a::Integer, b::BitwiseExpression)
  return _build_bitwise_expr(b, "|", a)
end

function Base.:~(f::BitwiseExpression)
  return _build_bitwise_unary(f, "~")
end

function Base.:<<(a::BitwiseExpression, b::BitwiseOperand)
  return _build_bitwise_expr(a, "<<", b)
end
function Base.:<<(a::Integer, b::BitwiseExpression)
  return FExpression(
    field_name=a,
    operation="<<",
    operand=b,
    function_name="F",
    column="",
    aggregate=_bitwise_is_agg(b)
  )
end

function Base.:>>(a::BitwiseExpression, b::BitwiseOperand)
  return _build_bitwise_expr(a, ">>", b)
end
function Base.:>>(a::Integer, b::BitwiseExpression)
  return FExpression(
    field_name=a,
    operation=">>",
    operand=b,
    function_name="F",
    column="",
    aggregate=_bitwise_is_agg(b)
  )
end

function Base.xor(a::BitwiseExpression, b::BitwiseOperand)
  return _build_bitwise_expr(a, "xor", b)
end
function Base.xor(a::Integer, b::BitwiseExpression)
  return _build_bitwise_expr(b, "xor", a)
end


"""
    ObjectHandler <: SQLObjectHandler

The query handler `Model.objects` returns — the object every fluent chain is built on.

Its methods are synthesized by `getproperty` rather than being real fields, which means the Julia
REPL cannot help you with them: `?query.filter` does not work (it errors, for any Julia value).
**The complete fluent reference lives on [`object`](@ref)** — type `?object` — and on the
[API reference](api.md).

```julia
query = M.Driver.objects          # an ObjectHandler
query.filter("nationality" => "Brazilian")
rows = query.values("forename", "surname").list()
```

Chainable methods mutate the handler and return it; terminal methods execute and return a result.
Use `.copy()` when you need to branch a chain without disturbing the original.
"""
mutable struct ObjectHandler <: SQLObjectHandler
  object::SQLObject
end
ObjectHandler(; object::SQLObject) = ObjectHandler(object)

"""
A model-aware row returned by `list()`, `first()`, and `get()`.

Wraps a `Dict{Symbol, Any}` and remembers which model produced it, enabling
dot-access to fields and many-to-many relationship accessors.
"""
mutable struct PormGRow
  _data::Dict{Symbol,Any}
  _model::PormGModel
  _dirty::Set{Symbol}
end
PormGRow(data::Dict{Symbol,<:Any}, model::PormGModel) = PormGRow(Dict{Symbol,Any}(data), model, Set{Symbol}())

"""Validate a row-facing symbol against the declared-case storage keys used internally. Each `__`
segment goes through `format_fild_name`, which since #317 rewrites nothing — the name is returned
verbatim, case preserved (#57). It used to strip a leading underscore, so `row._id` reached the key
`:id`; now it reaches `:_id`, which resolves only on a model that genuinely has that field."""
function _normalize_row_symbol(sym::Symbol)::Symbol
  parts = split(String(sym), "__")
  any(isempty, parts) && throw(UnknownFieldError("Invalid projected row field '$sym'. Empty '__' path segment."))
  return Symbol(join(Models.format_fild_name.(String.(parts)), "__"))
end

Base.getindex(row::PormGRow, key::Symbol) = getfield(row, :_data)[_normalize_row_symbol(key)]
# #612: `AbstractString`, not `String` — the READ side of the web-app pattern #603 was written
# around. A value goes into the query as a `SubString` out of `split(query_string, "=")` and comes
# back out of the row the same way (`row[split(cols, ",")[1]]`), which was a raw `MethodError`
# naming an internal signature. `Symbol(key)` already takes any `AbstractString`, so the annotation
# is the whole fix — nothing here needs to normalize, because the Symbol is the storage key.
Base.getindex(row::PormGRow, key::AbstractString) = getfield(row, :_data)[_normalize_row_symbol(Symbol(key))]
Base.haskey(row::PormGRow, key::Symbol) = haskey(getfield(row, :_data), _normalize_row_symbol(key))
Base.haskey(row::PormGRow, key::AbstractString) = haskey(getfield(row, :_data), _normalize_row_symbol(Symbol(key)))
Base.get(row::PormGRow, key::Symbol, default) = get(getfield(row, :_data), _normalize_row_symbol(key), default)
Base.get(row::PormGRow, key::AbstractString, default) = get(getfield(row, :_data), _normalize_row_symbol(Symbol(key)), default)
Base.keys(row::PormGRow) = keys(getfield(row, :_data))
Base.values(row::PormGRow) = values(getfield(row, :_data))
Base.pairs(row::PormGRow) = pairs(getfield(row, :_data))
Base.iterate(row::PormGRow, args...) = iterate(getfield(row, :_data), args...)

function Base.getproperty(row::PormGRow, sym::Symbol)
  # These five shadow any real column of the same name. Since #317 retired the leading-underscore
  # strip, an introspected schema can genuinely carry a `_data`/`_model`/`_dirty` column — reach it
  # with `row[:_data]` (indexing skips this dispatch), not dot access.
  sym === :_data && return getfield(row, :_data)
  sym === :_model && return getfield(row, :_model)
  sym === :_dirty && return getfield(row, :_dirty)
  sym === :save && return (; show_query::Symbol=:execute) -> save(row; show_query=show_query)
  sym === :delete && return (; show_query::Symbol=:execute) -> delete(row; show_query=show_query)

  data = getfield(row, :_data)
  model = getfield(row, :_model)
  normalized = _normalize_row_symbol(sym)

  haskey(data, normalized) && return data[normalized]

  # Virtual `.pk` alias → the model's primary-key value (a real column named `pk`, if one
  # existed, would already have been returned by the `haskey` lookup above).
  normalized === :pk && return pk(row)

  if Models.has_many_to_many_accessor(model, String(normalized))
    descriptor = ManyToManyDescriptor(model, String(normalized), Models.get_many_to_many_relation(model, String(normalized)))
    return descriptor(data)
  end

  if haskey(model.fields, String(normalized)) && model.fields[String(normalized)] isa Models.sRelationalColumn
    # Name the DECLARED type rather than hardcoding "ForeignKey" (#418): this branch now also serves
    # `OneToOneField`, and a message that names the wrong field type sends the reader looking for a
    # declaration that isn't there. `x[2:end]` strips the struct's `s` prefix to recover the
    # constructor name the user actually typed — the same idiom as `Models._model_to_str`.
    declared_type = nameof(typeof(model.fields[String(normalized)])) |> string |> x -> x[2:end]
    throw(LazyTraversalError(
      "$(model.name).$(normalized) is a $(declared_type) that this row didn't project; " *
      "PormG does not support lazy FK access (`row.$(normalized)`). " *
      "Project it up front in `values(...)`: add `\"$(normalized)\"` for the raw key value, " *
      "or `\"$(normalized)__<field>\"` for a column from the related table — " *
      "then read it as `row[:$(normalized)]` or `row[:$(normalized)__<field>]`."
    ))
  end

  throw(UnknownFieldError("$(model.name) row has no field or accessor '$(sym)'"))
end

function Base.setproperty!(row::PormGRow, sym::Symbol, value)
  sym in (:_data, :_model, :_dirty) && return setfield!(row, sym, value)

  normalized = _normalize_row_symbol(sym)
  model = getfield(row, :_model)
  normalized_string = String(normalized)

  if occursin("__", normalized_string)
    fk_name = first(split(normalized_string, "__", limit=2)) |> String
    if !(haskey(model.fields, fk_name) && model.fields[fk_name] isa Models.sRelationalColumn)
      throw(QueryBuildError("Cannot assign to '$(sym)': '$(fk_name)' is not a ForeignKey or OneToOneField field on $(model.name)."))
    end
  else
    if !haskey(model.fields, normalized_string)
      throw(UnknownFieldError("$(model.name) row has no writable field '$(sym)'."))
    end
    if model.fields[normalized_string].primary_key
      throw(QueryBuildError("Cannot mutate primary key field '$(normalized)' on a PormGRow."))
    end
  end

  getfield(row, :_data)[normalized] = value
  push!(getfield(row, :_dirty), normalized)
  return value
end

"""
    pk(row::PormGRow)
    pk(row::PormGRow, default)

Primary-key value of `row`, read through its model's declared pk column — so it works for any
pk name, not only `id`. The 1-arg form throws if the model has no single-column primary key, or
the pk column is absent from the row. The 2-arg form returns `default` in those cases instead of
throwing (for best-effort callers). A composite (multi-column) primary key has no scalar `pk`;
read the individual key columns instead.
"""
function pk(row::PormGRow)
  model = getfield(row, :_model)
  field = Models.get_model_pk_field(model)
  field === nothing && throw(QueryBuildError("$(model.name) row has no single-column primary key"))
  data = getfield(row, :_data)
  haskey(data, field) || throw(QueryBuildError("$(model.name) row is missing its primary-key column '$(field)'"))
  return data[field]
end

function pk(row::PormGRow, default)
  model = getfield(row, :_model)
  field = try
    Models.get_model_pk_field(model)     # throws on a composite (multi-column) pk
  catch
    return default
  end
  field === nothing && return default
  data = getfield(row, :_data)
  return haskey(data, field) ? data[field] : default
end

# PormGRow overrides getproperty to expose its stored columns (plus the `save` closure) via
# dot-access. Without these overrides Julia's defaults only saw the struct's real fields
# (_data/_model/_dirty), so hasproperty(row, :id) was false even though row.id works. Report the
# stored columns so introspection, REPL tab-completion, and hasproperty stay honest and
# consistent with getproperty. (`:pk` is a synthesized alias, not listed; the real pk column is.)
function Base.propertynames(row::PormGRow, private::Bool = false)
  cols = collect(keys(getfield(row, :_data)))
  push!(cols, :save)
  push!(cols, :delete)
  private && append!(cols, (:_data, :_model, :_dirty))
  return Tuple(cols)
end

# haskey(row, ::Symbol) applies the same leading-underscore normalization getproperty does, so
# this matches getproperty's success set for stored columns exactly.
Base.hasproperty(row::PormGRow, sym::Symbol) =
  sym in (:save, :_data, :_model, :_dirty) || haskey(row, sym)

Tables.isrowtable(::Type{Vector{PormGRow}}) = true
Tables.columnnames(row::PormGRow) = collect(keys(getfield(row, :_data)))
Tables.getcolumn(row::PormGRow, nm::Symbol) = getfield(row, :_data)[_normalize_row_symbol(nm)]


"""
    object(model::PormGModel) -> ObjectHandler

Wrap a model in an [`ObjectHandler`](@ref) — the start of every query. `M.Driver.objects` is the
idiomatic spelling; `object(M.Driver)` is the same thing as a function call.

**This docstring is the fluent-API reference.** The methods below are synthesized by
`getproperty`, so they have no bindings of their own — `?query.filter` cannot work. `?object` (or
the [API reference](api.md)) is where to look them up.

# Chainable methods

Each mutates the handler and returns it, so calls can be chained or accumulated on a variable.

- `.filter(pairs...)` — add `WHERE` conditions. Each argument may be a `Pair`, a `Q`/`Qor`, an
  operator expression, an `F` expression, or an `Exists(subquery)`. Repeated calls **accumulate**
  (ANDed), unlike `.values`/`.order_by`, which replace their previous call (#199)
- `.values(fields...)` — choose/annotate the selected columns; `"*"` selects the main table.
  **Replaces** its previous call, last-call-wins (#199)
- `.order_by(fields...)` — sort; prefix `-` for descending. Accepts a field path or an alias
  declared by `.values()` (#423). **Replaces** its previous call, matching Django's *each
  `order_by()` clears previous ordering* (#199)
- `.limit(n)` / `.offset(n)` — pagination, one clause each
- `.page(limit)` / `.page(limit, offset)` — pagination in one call; `.page(n)` sets the limit only
  and leaves any offset already on the handler in place. Those are the only two arities — anything
  else (no argument, three arguments, a non-`Integer`, a keyword) raises `QueryBuildError`, same as
  `.limit(...)` / `.offset(...)` (#272)
- `.distinct()` — add `DISTINCT`
- `.db("key")` — route the query to another connection pool
- `.on(path, pairs...; join_type)` — add predicates to the `ON` clause of an existing join path.
  Adds predicates only: without `join_type` the join keeps the type derived from the relation
  itself, and an explicit one stays in effect for later `on()` calls on that path (#474)
- `.cjoin("field" => "Model"; filters, join_type)` — custom join at query time
- `.cjoin_on(model; alias, on, join_type)` — anchor-less join where `on` is the entire `ON` clause;
  `model` is the model object (`M.Driver`) or its name (`"Driver"`), and a model registered on
  another connection is refused (#488). Reference its columns with
  [`Joined(alias, column)`](@ref Joined) in any clause. Its alias may
  equal a relation name on the base model or an `on()`/`cjoin()` join path; each stays addressable,
  and both joins are emitted (#484)
- `.with("name" => subquery; join_field, join_type)` — define a CTE; call again for a second one.
  Reference its columns as `"name__column"`, or as [`CTE(name, path)`](@ref CTE). Its name may equal
  a join key and each stays addressable (#474); a name equal to a **model field** makes the shared
  `__` path raise `AmbiguousFieldError`, and the handle selects the CTE side (#492)
- every `join_type` above accepts `"INNER"`, `"LEFT"`, `"RIGHT"` or `"FULL"`; anything else,
  `"CROSS"` included, raises `QueryBuildError` at the call (#474)
- `.select_for_update(; nowait, skip_locked, no_key)` — `SELECT … FOR UPDATE` row lock
- `.copy()` — deep copy, to branch a chain without disturbing the original

# Terminal methods

Each executes and returns a result. Every one below except `.inspect()` takes
`show_query = :sql` / `:dict` / `:params` to render instead of executing; `.inspect()` is already
an inspection call and takes `operation =` / `connection =` instead.

- `.list()` → `Vector{PormGRow}`; `.list(:dict)` → `Vector{Dict}`; `.list(:json)` → JSON `String`
- `query |> DataFrame` — preferred for analytical queries
- `.get(pairs...)` — exactly one row, or `DoesNotExist` / `MultipleObjectsReturned`
- `.first()` / `.last()` — one row or `nothing`, using the ordering already on the query
  (`.last` inverts it, falling back to primary-key descending when none is set)
- `.earliest(fields...)` / `.latest(fields...)` — **replace** the ordering with `fields`
  (ascending / descending) and take one row; at least one field is required, and an empty
  queryset raises `DoesNotExist` rather than returning `nothing`
- `.count(column = nothing; distinct = false)` / `.exists()` — checks without fetching rows
- `.aggregate(pairs...)` — whole-queryset aggregation with no `GROUP BY`; returns a `NamedTuple`
- `.create(pairs...)` — insert one row, returned as a `PormGRow`
- `.update(pairs...)` — update every matching row
- `.get_or_create(lookup...; defaults)` / `.update_or_create(lookup...; defaults)` → `(row, created)`
- `.delete()` — delete every matching row
- `.inspect()` — the [`inspect_query`](@ref) metadata `Dict`

# Examples

```julia
using PormG, DataFrames
using PormG.Functions: Count

# Accumulate on a variable — clearest for multi-step queries
query = M.Result.objects
query.filter("driverid__surname" => "Senna", "positionorder" => 1)
query.values("raceid__year", "raceid__name", "constructorid__name")

df    = query |> DataFrame
wins  = query.count()
any_  = query.exists()
```

```julia
# Inline chain — trailing dots; a leading dot on the next line is a ParseError
podiums = M.Result.objects.
    filter("raceid__year" => 2020, "positionorder__@lte" => 3).
    values("driverid__surname", "n" => Count("resultid")).
    order_by("-n").
    limit(10).
    list()
```

```julia
# Single-row writes — let the IDField allocate the key, then read it off the returned row
row = M.Status.objects.create("status" => "Heat shield fire")   # PormGRow
M.Status.objects.filter("statusid" => row.statusid).update("status" => "Heat shield")
```

See also [`ObjectHandler`](@ref), [`show_query`](@ref), and [Reading Data](read/index.md).
"""
function object(model::PormGModel)
  return ObjectHandler(object=SQLObjectQuery(model=model))
end


# delection

mutable struct DeletionCollector{T}
  model::PormGModel  # The main model being deleted from
  settings::PormGSettings  # Connection settings
  connection::Union{PormGPostgres,PormGSQLite}  # Database connection
  objects::Dict{PormGModel,Vector{Dict{Symbol,T}}}  # Models and their objects to delete
  dependencies::Dict{PormGModel,Set{PormGModel}}  # Model dependencies
  # One entry per cascade path, exactly like `objects` (#459 (a)). This used to hold a BARE
  # `Dict{Symbol,T}` and `handle_on_delete!` ASSIGNED into it, so a SET_NULL/SET_DEFAULT child of a
  # multi-path parent kept only the last path's scoping query and the other path's rows were never
  # written. `update_field` ORs the fragments, the way `delete_objects` does for `objects`.
  field_updates::Dict{Tuple{String,Any},Dict{PormGModel,Vector{Dict{Symbol,T}}}}  # Field updates for SET_NULL etc.
  fast_deletes::Dict{PormGModel,Vector{Dict{Symbol,T}}}  # Objects that can be deleted directly
  sorted_models::Vector{PormGModel}  # Models in deletion order
  show_query::Symbol  # Controls whether to execute or inspect; skips _exists during inspection
  # Models on the CURRENT recursion path of `find_related_objects!`, pushed on entry and popped in a
  # `finally`. Read only for its depth (`MAX_CASCADE_DEPTH`) and to name the path in the error —
  # see the guard in `deletion.jl` for why membership is deliberately NOT what is checked (#459 (b)).
  traversal_path::Vector{PormGModel}

  # The seeded literals below must match the field annotations. They used to disagree for
  # `field_updates` and `fast_deletes` (both were seeded `Dict{PormGModel,Dict{Symbol,String}}`),
  # which compiled only because assignment converts — so the constructor documented a shape the
  # struct did not have.
  DeletionCollector(model, settings, show_query=:execute) = new{Union{String,SQLObjectHandler}}(
    model,
    settings,
    settings.connections,
    Dict{PormGModel,Vector{Dict{Symbol,Union{String,SQLObjectHandler}}}}(),
    Dict{PormGModel,Set{PormGModel}}(),
    Dict{Tuple{String,Any},Dict{PormGModel,Vector{Dict{Symbol,Union{String,SQLObjectHandler}}}}}(),
    Dict{PormGModel,Vector{Dict{Symbol,Union{String,SQLObjectHandler}}}}(),
    Vector{PormGModel}(),
    show_query,
    Vector{PormGModel}()
  )
end
