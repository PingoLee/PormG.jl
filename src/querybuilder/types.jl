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

!!! warning "Outer `GROUP BY`"
    Combining a correlated `Subquery` with an outer aggregate is only well-defined when the
    correlated column is itself grouped. If it is not, PostgreSQL fails loudly while SQLite
    silently evaluates the subquery against an arbitrary row of each group. See
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
Key for the per-build memos (`SQLInstruction.cache`, `tab_field_cache`, `json_lookup_cache`):
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
looks sufficient: `Models.Model(name, ::Dict{String,PormGField})` (the #317 import path) does not
run `format_fild_name`, so a field may legitimately be named `cte:x` — and then a `cjoin` keyed
`"cte:x"` collides with the prefixed key of a CTE named `x`, silently dropping the cjoin's whole
join, and an FK named `cte:x` collides in the memo, reproducing the very defect above. A prefix over
an unvalidated name space is a uniquifier; a tuple is a namespace. `Tuple` rather than a struct so
`==`/`hash` come from Base with the right value semantics for the `String` half.

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

"""Column references: fields, functions, strings, CTE or joined-copy column handles, or vectors of operations."""
const ColumnPart = Union{SQLTypeField,SQLTypeFunction,String,SQLTypeF,SQLTypeCTE,SQLTypeJoined,Vector{Union{String,SQLTypeF}}}

"""Window PARTITION BY expressions."""
# #444: `SQLTypeCTE` — PARTITION BY a CTE column worked before the change (the reference was a
# plain String, already admitted here) and must keep working. #481: `SQLTypeJoined` for the same
# reason one level up — `F("d.col")` was a plain String here too.
const WindowPartitionPart = Union{String,SQLTypeField,SQLTypeFunction,SQLTypeF,SQLTypeCTE,SQLTypeJoined}

"""Window ORDER BY expressions."""
# #444: `SQLTypeCTE` — a window ORDER BY over a CTE column worked before the change; it is also
# the second site (after the fluent `order_by`) where `CTE(...; desc = true)` is meaningful. #481:
# `SQLTypeJoined` likewise.
const WindowOrderPart = Union{String,SQLTypeOrder,SQLTypeCTE,SQLTypeJoined}

"""Window function argument expressions."""
const WindowColumnPart = Union{Nothing,String,SQLTypeField,SQLTypeText,SQLTypeFunction,SQLTypeF,SQLTypeCTE,SQLTypeJoined}

"""Optional strings (often used for aliases or configs)."""
const OptionalString = Union{String,Nothing}

"""Database connections."""
const ConnType = Union{PormGSQLite,PormGPostgres,Nothing}

"""CTE configuration dictionary."""
const CTEDict = Dict{String,Union{SQLObjectHandler,PormGModel,Pair,String,Nothing}}

"""Join metadata dictionary."""
const JoinDict = Dict{String,Union{String,Vector{FilterType}}}

#
# SQLTypeArrays Objects
#
@kwdef mutable struct SQLArrays <: SQLTypeArrays # TODO -- check if I need to use this
  count::Integer = 1
  array_string::Array{String,2} = Array{String,2}(undef, 20, 3)
  array_int::Array{Integer,2} = Array{Integer,2}(undef, 20, 3)
end

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
  row_join::Vector{JoinDict} = [] # array of dictionary to be used in join query
  row_path::Vector{String} = [] # array of path to map the row_join (model__model__ etc)
  # array_join::Array{String, 2} = Array{String, 2}(undef, 30, 8) # array to be used in join query (meaby the best way to do this)
  tab_field_cache::Dict{MemoKey,PormGField} = sizehint!(Dict{MemoKey,PormGField}(), 12) # cache to be used in join query (#474: keyed by MemoKey)
  # #27: records each resolved JSON-lookup path (e.g. "payload__driver") → (JSON base field,
  # validated key segments). Set when the JSON-path gate renders an extraction; read by the
  # filter-render branch to bind the RHS as plain text (not through the JSON formatter) and to
  # reject containment operators on a nested key path.
  json_lookup_cache::Dict{MemoKey,Tuple{PormGField,Vector{String}}} = Dict{MemoKey,Tuple{PormGField,Vector{String}}}()
  connection::ConnType = nothing
  # array_defs::SQLTypeArrays = SQLArrays()
  cache::Dict{MemoKey,SQLTypeField} = sizehint!(Dict{MemoKey,SQLTypeField}(), 12)
  django::OptionalString = nothing
  parameters::Union{Nothing,AbstractPormGParam} = nothing # parameters to be used in the query
  outer::Union{Nothing,SQLInstruction} = nothing # parent query instruction for correlated subqueries
  # #74 fan-out guard: record each at-risk aggregate's source alias so build() can refuse
  # silently-inflated COUNT/SUM/AVG. To-many joins are flagged in-place on their row_join dict (a
  # "to_many" key) and the many-side alias set is derived from the *deduped* row_join at check time
  # (deriving avoids over-counting when _cache_join builds the same join twice). See _check_aggregate_fanout.
  agg_sources::Vector{NamedTuple{(:alias, :func, :label, :distinct),Tuple{String,String,String,Bool}}} =
    NamedTuple{(:alias, :func, :label, :distinct),Tuple{String,String,String,Bool}}[]
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
mutable struct SQLText <: SQLTypeText
  field::Any
  _as::OptionalString
  custom_as::OptionalString
end
SQLText(field::Any; _as::OptionalString=nothing) = SQLText(field, _as, nothing)
SQLText(field::Any, _as::OptionalString) = SQLText(field, _as, nothing)
Base.deepcopy(x::SQLTypeText) = SQLText(x.field, x._as, x.custom_as)


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
  # Read it through `_field_cache_key`, never directly.
  root::Symbol
end
SQLField(field::FieldPart; _as::OptionalString=nothing) = SQLField(field, _as, nothing, :base)
SQLField(field::FieldPart, _as::OptionalString) = SQLField(field, _as, nothing, :base)
Base.deepcopy(x::SQLTypeField) = SQLField(x.field, x._as, x.custom_as, x.root)

# `orientation` is interpolated into rendered SQL, so it is whitelisted here (#77) and stored
# uppercase. Single whitelist for every orientation path — the window path
# (_normalize_window_orientation, build_helpers.jl) delegates here with its own context label.
function _normalize_order_orientation(orientation::AbstractString; context::String="ORDER BY")::String
  normalized = uppercase(strip(String(orientation)))
  normalized in ("ASC", "DESC") || throw(QueryBuildError("$(context) orientation must be ASC or DESC, got $(repr(orientation))"))
  return normalized
end

# Return a order of field to sql query
mutable struct SQLOrder <: SQLTypeOrder
  field::Union{SQLTypeField,String}
  order::Union{Integer,Nothing}
  orientation::String
  _as::OptionalString
  # NULL placement for this term (#75): `nothing` = apply the canonical backend-aligned default
  # (ASC → NULLS LAST, DESC → NULLS FIRST); `:first`/`:last` force the placement explicitly.
  nulls::Union{Symbol,Nothing}
  # Inner constructor: every construction path (keyword, positional, deepcopy) passes the
  # orientation whitelist (#77), so an injection-shaped direction never reaches the renderer.
  SQLOrder(field, order, orientation, _as, nulls) = new(field, order, _normalize_order_orientation(orientation), _as, nulls)
end
SQLOrder(field::Union{SQLTypeField,String}; order::Union{Integer,Nothing}=nothing, orientation::String="ASC", _as::OptionalString=nothing, nulls::Union{Symbol,Nothing}=nothing) = SQLOrder(field, order, orientation, _as, nulls)
Base.deepcopy(x::SQLTypeOrder) = SQLOrder(x.field, x.order, x.orientation, x._as, x.nulls)

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
  row_join::Vector{Dict{String,Any}}
  distinct::Bool # Add distinct field
  for_update::Union{Nothing,ForUpdateClause} # #26: row-level lock clause (nothing = no lock)
  ctes::Dict{String,CTEDict}
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

  SQLObjectQuery(; model=nothing, connect_key=nothing, values=[], filter=[], insert=OrderedCollections.OrderedDict{String,Any}(), limit=0, offset=0,
    order=[], group=[], having=[], list_joins=[], row_join=[], distinct=false, for_update=nothing, ctes=Dict{String,CTEDict}(),
    custom_join=OrderedCollections.OrderedDict{String,PathJoin}(), alias_join=OrderedCollections.OrderedDict{String,AliasJoin}(), parameters=nothing) =
    new(model, connect_key, values, filter, insert, limit, offset, order, group, having, list_joins, row_join, distinct, for_update, ctes, custom_join, alias_join, parameters)
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
function _copy_ctes(ctes::Dict{String,CTEDict})::Dict{String,CTEDict}
  out = Dict{String,CTEDict}()
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
      row_join=deepcopy(obj.row_join),
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
- `column::Union{String, SQLTypeFunction}`: the column to be used with the operator.

"""
@kwdef mutable struct OperObject <: SQLTypeOper
  operator::String
  # `Base.UUID` appears on BOTH arms (#411): the vector arm so `uid__@in` can hold a list, and the
  # scalar arm so `filter("uid" => uuid)` can hold one value. Widening only the vector arm left plain
  # equality on a UUIDField raising a `convert` MethodError — an untyped error on the most ordinary
  # spelling there is, which is precisely what this pair of issues exists to remove.
  values::Union{String,Number,Bool,Dates.TimeType,Dates.Period,Dates.CompoundPeriod,Base.UUID,SQLObjectHandler,SQLTypeF,SQLTypeFunction,SQLTypeCTE,SQLTypeJoined,Vector{T}} where T<:Union{Missing,String,Dates.TimeType,Dates.Period,Dates.CompoundPeriod,Number,Bool,SQLTypeF,Base.UUID}
  column::ColumnPart # Vector{String} is needed
end
OP(column::String, value) = OperObject(operator="=", values=value, column=SQLField(column))
OP(column::SQLTypeFunction, value) = OperObject(operator="=", values=value, column=column)
OP(column::String, operator::String, value) = OperObject(operator=operator, values=value, column=SQLField(column))
OP(column::SQLTypeFunction, operator::String, value) = OperObject(operator=operator, values=value, column=column)

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

# Duration operands accepted by F-expression +/- date arithmetic (#25).
const _DurationOperand = Union{Dates.Period, Dates.CompoundPeriod, Interval}

# Carrier for an F reference and any arithmetic built on top of it. Users construct it through
# `F(field_name)` (documented below) and the Base.:+/-/*// overloads further down; the struct
# itself is internal.
@kwdef mutable struct FExpression <: SQLTypeF
  # #481: `SQLTypeJoined` so a joined-copy reference can be the LEFT side of a comparison
  # (`Joined("d","driverid") == F("driverid")`). It renders through `_set_update_query`, the same
  # seam a `String` field_name uses.
  field_name::Union{String,Integer,SQLTypeF,SQLTypeFunction,SQLTypeJoined}
  operation::OptionalString = nothing  # +, -, *, /, etc.
  # #444/#481: `SQLTypeCTE`/`SQLTypeJoined` so `F("note") == CTE("ev","code")` builds a comparison instead of
  # falling through to `Base.==` and silently yielding a Bool.
  operand::Union{String,Integer,Float64,SQLTypeF,SQLTypeFunction,SQLTypeCTE,SQLTypeJoined,Dates.Period,Dates.CompoundPeriod,Interval,Nothing} = nothing
  function_name::String = "F"
  column::Union{String,SQLTypeField,Vector{String}} = ""
  aggregate::Bool = false
  _as::OptionalString = nothing
  kwargs::Dict{String,Any} = Dict{String,Any}()
end

"""
    F(field_name::String) -> FExpression

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
function F(field_name::String)
  return FExpression(
    field_name=field_name,
    function_name="F",
    column=field_name
  )
end
function Base.deepcopy(f::FExpression)
  try
    return FExpression(
      field_name=f.field_name,
      operation=f.operation,
      operand=deepcopy(f.operand),
      function_name=f.function_name,
      column=deepcopy(f.column),
      aggregate=f.aggregate,
      _as=f._as,
      kwargs=deepcopy(f.kwargs)
    )
  catch e
    @error "Error in deepcopy for FExpression: $e" exception = (e, catch_backtrace())
    rethrow(e)
  end
end

# Arithmetic operations for F expressions
# Aggregate propagation helper: result is aggregate if any operand is aggregate
_is_agg(f::FExpression) = f.aggregate
_is_agg(f::SQLTypeFunction) = f.aggregate
_is_agg(::Any) = false

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
# Two of its members are NOT honoured, and predate this: `Dates.Date` and `Dates.DateTime` dispatch
# through this union — in BOTH families that share it, the `F` comparisons below and the
# `JoinedReference` ones further down — and then die in the constructor, because
# `FExpression.operand` (the struct field, above) admits
# `Period`/`CompoundPeriod`/`Interval` but neither `Date` nor `DateTime`. So `F("date") == Date(2020)`
# raises a bare `MethodError`, outside the #231 taxonomy. Left alone deliberately — widening the field
# is a behaviour change with its own tests, not part of #457 — but recorded here so the next reader
# does not take this union as proof the shapes work.
const _CompareOperand = Union{Integer,Float64,String,Dates.Date,Dates.DateTime,FExpression,SQLTypeCTE,SQLTypeJoined}

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

@kwdef mutable struct OuterRefObject <: SQLTypeF
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
  query to bind to.

Correlate on a base column of the outer model. A joined path (`OuterRef("constructorid__name")`)
adds a join to the outer query and is outside the validated surface.
"""
function OuterRef(field_name::AbstractString)
  normalized = String(field_name)
  isempty(normalized) && throw(QueryBuildError("OuterRef requires a non-empty field name"))
  return OuterRefObject(field_name=normalized)
end
Base.deepcopy(x::OuterRefObject) = OuterRefObject(field_name=x.field_name)

# #444 — a CTE column reference. `SQLTypeCTE` (Kernel.jl) was declared with zero subtypes and zero
# uses; this is what it was reserved for. Deliberately NOT `<: SQLTypeF`: that would auto-admit the
# type into `FilterType`, `FObject.column` and the ~18 `functions.jl` unions for free, which is
# exactly the hazard — `Sum(CTE(...))` would silently construct (it is refused, see functions.jl)
# and a bare `filter(CTE("ev","sku"))` with no pair would parse as a standalone filter. Every
# admission below is a named seam, on purpose.
@kwdef mutable struct CTEReference <: SQLTypeCTE
  name::String        # the `.with(...)` label this column belongs to
  path::String        # a field path INSIDE that CTE
  desc::Bool = false  # order_by only; refused everywhere else
end

"""
    CTE(name::AbstractString, path::AbstractString; desc::Bool = false) -> CTEReference

Reference a column of a CTE declared with [`.with(...)`](@ref object). The CTE's columns live in
their **own namespace**, separate from the model's field paths, so a CTE may legally share a name
with a field and neither shadows the other (#444):

```julia
parent_cte = M.Cj_parent.objects
parent_cte.values("id", "sku")

q = M.Cj_child.objects
q.with("parent" => parent_cte)          # "parent" is ALSO a ForeignKey of Cj_child
q.values("note",
         "parent__sku",                 # the ForeignKey's column — unambiguous
         "fk" => CTE("parent", "sku"))  # the CTE's column        — unambiguous
```

The second argument is a **path**, not a bare column, and carries the same `__` vocabulary the rest
of PormG uses — a hop out of the CTE through a projected ForeignKey, a JSON sub-path, or an operator
suffix:

```julia
q.filter(CTE("ev", "sku") => "ABC")                       # plain column
q.values("s" => CTE("ev", "parent__sku"))                 # hop through a projected FK
q.filter(CTE("ev", "meta__driver") => "senna")            # JSON sub-path
q.filter(CTE("ev", "seen__@yyyy_mm__@lte") => "1991-10")  # operator suffix
q.filter("raceid" => CTE("r91", "raceid"))                # correlate an unkeyed CTE (#44)
q.order_by(CTE("monaco_stats", "total_points"; desc = true))
```

An unaliased projection is named by joining the two with a double underscore —
`values(CTE("parent", "sku"))` emits the output column `parent__sku`.

SQL functions, aggregates and window clauses accept a handle wherever they accept a field path —
`Lower(CTE("ev","sku"))`, `Cast(CTE("ev","qty"), "text")`, `Sum(CTE("ev","qty"))`,
`Rank(over = WindowOver(partition_by = CTE("ev","sku")))`.

`desc = true` is meaningful in `order_by(...)` and in a window's `order_by`; anywhere else it raises
a `QueryBuildError`. A CTE column cannot be referenced from `on(...)`, `cjoin(...)` or
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
Base.deepcopy(x::CTEReference) = CTEReference(name=x.name, path=x.path, desc=x.desc)

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
q.cjoin_on("Driver", alias = "d", on = [Joined("d", "driverid") == F("driverid")])
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
Base.deepcopy(x::JoinedReference) = JoinedReference(x.alias, x.path, x.desc)
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
for (op, sym) in ((:(==), "="), (:(!=), "!="), (:(>), ">"), (:(<), "<"), (:(>=), ">="), (:(<=), "<="))
  @eval function Base.$op(j::JoinedReference, operand::_CompareOperand)
    _reject_joined_desc(j, "a comparison")
    return FExpression(field_name=j, operation=$sym, operand=operand, function_name="F", column="", aggregate=false)
  end
end

#
# SQLTypeFunction Objects (functions from sql)
#

@kwdef mutable struct FObject <: SQLTypeFunction
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
function Base.deepcopy(f::FObject)
  return FObject(
    function_name=f.function_name,
    column=deepcopy(f.column),
    aggregate=f.aggregate,
    formatter=f.formatter,
    _as=f._as,
    kwargs=deepcopy(f.kwargs)
  )
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
  (`RANGE BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW`). PostgreSQL only.

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

@kwdef mutable struct WindowFunction <: SQLTypeFunction
  function_name::String
  column::WindowColumnPart = nothing
  over::WindowSpec
  aggregate::Bool = false
  formatter::Union{Nothing,Function} = nothing
  _as::OptionalString = nothing
  kwargs::Dict{String,Any} = Dict{String,Any}()
end
function Base.deepcopy(f::WindowFunction)
  return WindowFunction(
    function_name=f.function_name,
    column=deepcopy(f.column),
    over=deepcopy(f.over),
    aggregate=f.aggregate,
    formatter=f.formatter,
    _as=f._as,
    kwargs=deepcopy(f.kwargs)
  )
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
Base.getindex(row::PormGRow, key::String) = getfield(row, :_data)[_normalize_row_symbol(Symbol(key))]
Base.haskey(row::PormGRow, key::Symbol) = haskey(getfield(row, :_data), _normalize_row_symbol(key))
Base.haskey(row::PormGRow, key::String) = haskey(getfield(row, :_data), _normalize_row_symbol(Symbol(key)))
Base.get(row::PormGRow, key::Symbol, default) = get(getfield(row, :_data), _normalize_row_symbol(key), default)
Base.get(row::PormGRow, key::String, default) = get(getfield(row, :_data), _normalize_row_symbol(Symbol(key)), default)
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
  reference its columns with [`Joined(alias, column)`](@ref Joined) in any clause. Its alias may
  equal a relation name on the base model or an `on()`/`cjoin()` join path; each stays addressable,
  and both joins are emitted (#484)
- `.with("name" => subquery; join_field, join_type)` — define a CTE; call again for a second one.
  Its name may equal a model field or a join key; each stays addressable (#444, #474)
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
