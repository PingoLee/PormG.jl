
"""
    Q(x...)

Create a `QObject` with the given filters.

# Arguments
- `x...`: key-value pairs, `Qor(x...)`, or `Q(x...)` objects.

# Example
```julia
a = object("tb_user")
a.filter(Q("name" => "John", Qor("age" => 18, "age" => 19)))
```
"""
function Q(x...)
  colect = [isa(v, Pair) ? _check_filter(v) : isa(v, FilterType) ? _check_filter_node(v) : throw(FilterError("Invalid argument: a $(typeof(v)); please use a pair (key => value).")) for v in x]   # #863
  return QObject(filters = colect)
end


"""
    Qor(x...)

Create a `QorObject` from the given arguments. The `QorObject` represents a disjunction of `SQLTypeQ` or `SQLTypeQor` objects.

# Arguments
- `x...`: A variable number of arguments. Each argument can be either a `SQLTypeQ` or `SQLTypeQor` object, or a `Pair` object.

# Example
```julia
a = object("tb_user")
a.filter(Qor("name" => "John", Q("age__gte" => 18, "age__lte" => 19)))
```
"""
function Qor(x...)
  colect = [isa(v, Pair) ? _check_filter(v) : isa(v, FilterType) ? _check_filter_node(v) : throw(FilterError("Invalid argument: a $(typeof(v)); please use a pair (key => value).")) for v in x]   # #863
  return QorObject(or = colect)
end

#
# SQLTypeFunction Objects (functions from sql)
#

# #603 — the one normalization the widened constructors below share.
#
# The seven constructors #602 widened (`Coalesce`, `Greatest`, `Least`, `NullIf`, `Replace`,
# `Power`, `Mod`) take an UNTYPED argument and branch on `isa(v, AbstractString)` in the body. The
# constructors below dispatch on a typed union instead, so widening the union is only half the
# change: `FObject.column`'s string member is `String`, and a `Union{String,...}` slot without
# `Nothing` has no `convert` fallback — an un-normalized `SubString` would die one frame deeper
# inside `FObject` with a raw `MethodError` naming nothing the caller wrote.
#
# The aggregates below are the same shape for the opposite reason: they take `x` UNTYPED, so there
# is no signature to widen — nothing refuses the view, it simply rides into `FObject.column` and
# dies in `convert` there.
#
# `String(x)`, never `string(x)`: `string` is the identity for a `LazyString` (measured in #598).
# A `String` argument comes back unchanged, so every rendered query stays byte-identical.
_norm_fn_arg(x::AbstractString) = String(x)
_norm_fn_arg(x::Vector{<:AbstractString}) = String.(x)
_norm_fn_arg(x) = x

# #867 — the aggregates' admission gate. Their `x` is untyped, so every node type reached
# `FObject.column` and anything outside that union died in `convert` there: `Max(Subquery(…))`,
# `Sum(Exists(…))`, `Count(SQLOrder(…))` and a bare query handler each raised a raw `MethodError`
# naming the struct's whole column union. The gate tests against the slot's OWN declared type, so
# the two cannot disagree (#533), and a refusal names the spelling that works.
#
# An aggregate over a `Subquery` is refused rather than rendered as `MAX((SELECT …))`. The
# subquery already aggregates in its own `values(...)`, which is the fan-out-safe shape the docs
# teach, and an outer aggregate around a correlated subquery would meet the #194 grouped-correlation
# guard from a direction it was not written for. Admitting it later is additive.
#
# No message interpolates the node itself: `repr` of an `SQLArrays` reads `undef` slots and throws,
# which would turn the refusal back into a raw error.
const _FObjectColumn = fieldtype(FObject, :column)
function _aggregate_operand(fn::String, x)
  y = _norm_fn_arg(x)
  # #878: the slot holds a `SubqueryObject` now (for `Lower(Subquery(…))` and its siblings), so the
  # refusal is decided here, before the slot test, rather than by the slot leaving it out.
  y isa SubqueryObject && throw(QueryBuildError(_aggregate_refusal(fn, y)))
  y isa _FObjectColumn && return y
  throw(QueryBuildError(_aggregate_refusal(fn, y)))
end
_aggregate_refusal(fn::String, ::SubqueryObject) =
  "\e[4m\e[31m$fn\e[0m cannot wrap a `Subquery(...)`: a subquery is already one value per row. " *
  "Aggregate inside it instead — " *
  "\e[4m\e[32ms.values(\"t\" => $fn(\"col\")); q.values(\"x\" => Subquery(s))\e[0m (#867)."
_aggregate_refusal(fn::String, ::ExistsObject) =
  "\e[4m\e[31m$fn\e[0m cannot wrap `Exists(...)`: it is a predicate, not a value. Filter on it, " *
  "or count the rows it holds for — " *
  "\e[4m\e[32mSum(Case([When(Q(Exists(s)), then = 1)], default = 0))\e[0m (#867)."
_aggregate_refusal(fn::String, ::SQLObjectHandler) =
  "\e[4m\e[31m$fn\e[0m cannot take a query. Aggregate inside it and project it as a column — " *
  "\e[4m\e[32ms.values(\"t\" => $fn(\"col\")); q.values(\"x\" => Subquery(s))\e[0m (#867)."
_aggregate_refusal(fn::String, ::SQLTypeOrder) =
  "\e[4m\e[31m$fn\e[0m cannot take an ordering term. Pass the column path — " *
  "\e[4m\e[32m$fn(\"col\")\e[0m — and order with \e[4m\e[32morder_by\e[0m (#867)."
_aggregate_refusal(fn::String, y) =
  "\e[4m\e[31m$fn\e[0m cannot take an operand of type `$(nameof(typeof(y)))`. " *
  "Its operand is a column path (a string), an `F(...)` expression or a function; wrap a literal " *
  "as \e[4m\e[32mValue(x)\e[0m (#867)."

# #1034 — WHAT EACH FUNCTION'S VALUE IS, stated beside the function rather than in name lists kept
# elsewhere. Keyed by `function_name`, the name `Dialect` renders by; one method per name, defined
# under the constructor that builds it. The answer is a rule, not a kind, because the readers that
# consult it walk the operands themselves (the `Concat` refusal names the operand that decides):
#
# - `:operand`       — the value is its one operand's own value (`Max`, `Lag`, …), so it has that kind;
# - `:one_of`        — the value is one of several operands' own values (`Coalesce`, `Greatest`,
#                      `Least`), so it has a kind only when they agree. A declared `output_field` is
#                      the cast these render (#852);
# - `:first_operand` — the value is the first operand's or NULL (`NullIf`);
# - `:promoting`     — a number computed from its operand's type (`Sum`, `Abs`, `Floor`, `Ceil`): on
#                      SQLite an integer stays one; on PostgreSQL the type is the function's own
#                      (`Dialect` casts `Abs`/`Floor`/`Ceil` to `numeric` except over a whole number,
#                      #1147, and `Sum` widens), which `_computed_kind` states;
# - `:numeric`       — a fractional number: PostgreSQL computes it as `numeric` (`Dialect` casts the
#                      operand; `Avg` renders bare and averages a `double precision` to one) and SQLite
#                      as a REAL (`Avg`, `Round`, `Mod`, …), measured for #1027;
# - `:declared`      — the type the call declares (`Cast`'s type, `Case`'s `output_field`);
# - a `CanonicalType` — the value always has that kind (`Count` is a `bigint`, `Lower` text);
# - `:unknown`       — not stated: the readers treat the value as untyped, the fail-open default.
#
# The fallback answers `:unknown` so a build never fails on a name without a method, and
# `test/unit/test_expression_kind_rules.jl` fails instead: every name a constructor builds must state
# its rule here, `:unknown` included, so a new function cannot be typed in one reader and forgotten in
# another.
_result_rule(p::SQLTypeFunction) = _result_rule(Val(Symbol(p.function_name)))
_result_rule(::Val) = :unknown
# The rules whose value is a number with its operands' type, or one of its operands' own values: one
# boolean, float or decimal operand makes the result one, so any operand decides.
const _OPERAND_TYPED_RULES = (:operand, :one_of, :first_operand, :promoting)

"""
    Sum(column; distinct=false)

Computes the sum of all values in the column.

A `Sum` over a `BooleanField` is refused with a `QueryBuildError` (#953): PostgreSQL has no
`sum(boolean)`, and SQLite would add up the stored 0/1. Count the true rows explicitly —
`Sum(When("is_active" => true, then = 1, otherwise = 0))`.
"""
function Sum(x; distinct::Bool = false)
  return FObject(function_name = "SUM", column = _aggregate_operand("Sum", x), aggregate = true, kwargs = Dict{String, Any}("distinct" => distinct))
end
_result_rule(::Val{:SUM}) = :promoting
# `SUM` renders bare on both engines, so it has each one's aggregate type, not the `::numeric` cast the
# other `:promoting` functions render on PostgreSQL (`_computed_kind`, `expression_kind.jl`). PostgreSQL
# widens `sum(smallint|integer)` to `bigint` and `sum(bigint)` to `numeric`.
_computed_kind(::Val{:SUM}, ::Symbol, ::Union{CInt16,CInt32}, ::PormGPostgres) = CInt64()
_computed_kind(::Val{:SUM}, ::Symbol, ::Union{CInt64,CDecimal}, ::PormGPostgres) = CDecimal(nothing, nothing)
_computed_kind(::Val{:SUM}, ::Symbol, k::Union{CFloat64,CInterval}, ::PormGPostgres) = k
_computed_kind(::Val{:SUM}, ::Symbol, ::Any, ::PormGPostgres) = nothing
_computed_kind(::Val{:SUM}, ::Symbol, k::CInterval, ::PormGSQLite) = k

"""
    Avg(x; distinct::Bool = false)

Aggregate `AVG(x)` — the mean of `x` across the group.

`x` is a field path (`"points"`, `"driverid__surname"`), an `F` expression, or a nested
function object. With `distinct = true` it renders `AVG(DISTINCT x)`.

Like [`Count`](@ref) and [`Sum`](@ref) — and unlike [`Max`](@ref)/[`Min`](@ref) — `AVG` is
covered by the to-many fan-out guard (#74): a join that multiplies rows would silently
inflate the mean, so PormG raises instead. Passing `distinct = true` is an explicit opt-in
and is exempt.

An `Avg` over a `BooleanField` is refused with a `QueryBuildError`, as [`Sum`](@ref) is (#953): the
share of true rows is `Avg(When("is_active" => true, then = 1, otherwise = 0))`.

See also [Filters and Aggregates](@ref).
"""
function Avg(x; distinct::Bool = false)
  return FObject(function_name = "AVG", column = _aggregate_operand("Avg", x), aggregate = true, kwargs = Dict{String, Any}("distinct" => distinct))
end
_result_rule(::Val{:AVG}) = :numeric
# `AVG` renders bare too: PostgreSQL averages a `double precision` to one and an interval to an
# interval, and every other number to a `numeric`. SQLite answers a REAL, but an interval stays one.
_computed_kind(::Val{:AVG}, ::Symbol, k::Union{CFloat64,CInterval}, ::PormGPostgres) = k
_computed_kind(::Val{:AVG}, ::Symbol, ::Union{CInt16,CInt32,CInt64,CDecimal}, ::PormGPostgres) = CDecimal(nothing, nothing)
_computed_kind(::Val{:AVG}, ::Symbol, ::Any, ::PormGPostgres) = nothing
_computed_kind(::Val{:AVG}, ::Symbol, k::CInterval, ::PormGSQLite) = k
"""
  Count(x; distinct::Bool = false)

Creates an aggregate COUNT function object for use in query building.

# Arguments
- `x`: The column or expression to count.
- `distinct::Bool = false`: If `true`, counts only distinct values of `x`.

# Examples
```julia
# Count just when other_model_id is distinct  
query = MyModels.model_test |> object;
query.filter("id__@gte" => 1)
query.values("id", "count" => Count("other_model_id", distinct=true))
df = query |> DataFrame
```
"""
function Count(x; distinct::Bool = false)
  return FObject(function_name = "COUNT", column = _aggregate_operand("Count", x), aggregate = true, kwargs = Dict{String, Any}("distinct" => distinct))
end
_result_rule(::Val{:COUNT}) = CInt64()   # `bigint` on PostgreSQL
"""
    Max(x)

Aggregate `MAX(x)` — the largest value of `x` in the group.

There is **no** `distinct` keyword: `MAX(DISTINCT x)` and `MAX(x)` are the same value.

`MAX`/`MIN` are deliberately exempt from the to-many fan-out guard (#74) that
[`Count`](@ref), [`Sum`](@ref) and [`Avg`](@ref) trip: duplicating rows across a to-many
join cannot change an extremum, so the query is safe where a sum would be wrong.

The value reads back as the same Julia type the column itself does, on both engines: a `MAX`
over a `DateField` is a `Date`, over a `DurationField` a `Dates.CompoundPeriod` (#800). `MAX`
returns one of the column's own values, so the column's read-side parser applies to it. This does
not extend to a computed aggregate: [`Sum`](@ref) and [`Avg`](@ref) come back as the engine
delivers them.

Over a `BooleanField` it answers "is any row true?" and reads back as a `Bool` on both engines. It
renders `BOOL_OR(x)` on PostgreSQL, which has no `max(boolean)`, and `MAX(x)` over SQLite's stored
0/1 (#953).

See also [`Min`](@ref), [Filters and Aggregates](@ref).
"""
function Max(x)
  return FObject(function_name = "MAX", column = _aggregate_operand("Max", x), aggregate = true)
end
_result_rule(::Val{:MAX}) = :operand

"""
    Min(x)

Aggregate `MIN(x)` — the smallest value of `x` in the group. The mirror of [`Max`](@ref) in
every respect: no `distinct` keyword, exempt from the fan-out guard (#74), and the result
reads back as the column's own Julia type on both engines (#800). Over a `BooleanField` it answers
"are all rows true?": `BOOL_AND(x)` on PostgreSQL, `MIN(x)` on SQLite (#953).

See also [Filters and Aggregates](@ref).
"""
function Min(x)
  return FObject(function_name = "MIN", column = _aggregate_operand("Min", x), aggregate = true)
end
_result_rule(::Val{:MIN}) = :operand

# #444 — aggregates DO accept a CTE column handle, and this note records why there is no guard here.
#
# An earlier draft of #444 refused them, on the stated grounds that the shape "does not need to
# compose on day one" — #444 measured class F (`Sum("<cte>__col")`) at ZERO call sites. That
# measurement was of CALL SITES, not of CAPABILITY, and the two are different questions. Rendering
# `Sum("ev__qty")` against `main` shows the capability was always there and always correct:
#
#     SELECT "R1"."note" as "note", SUM("R1_1"."qty") as "t"
#     FROM "va_child" as "R1" LEFT JOIN "ev" AS "R1_1" ON "R1"."id" = "R1_1"."id"
#     GROUP BY 1
#
# — including through HAVING. So a refusal here would have been a REGRESSION dressed as a deferral,
# and an incoherent one: `Sum(Length(CTE(...)))` renders correctly whatever the outer method does,
# because the handle is resolved by `_get_select_query` at the leaf. `Sum`/`Avg`/`Count`/`Max`/`Min`
# take an untyped `x` and pass it to `FObject.column`, whose union admits `SQLTypeCTE` (types.jl).
# Nothing else is needed; do not add a guard back without re-running that differential first.

function _window_part_vector(value, part_name::AbstractString)::Vector{WindowPartitionPart}
  value === nothing && return WindowPartitionPart[]
  values = value isa Tuple ? collect(value) : value isa AbstractVector ? collect(value) : [value]
  parts = WindowPartitionPart[]
  for item in values
    item isa Symbol && (item = String(item))
    # #603: the same normalization one line up, for the other spelling a caller can produce. The
    # `WindowPartitionPart` / `WindowOrderPart` vectors these push into are `Union{String,...}`
    # WITHOUT `Nothing`, so they have no `convert` fallback — a view has to become a `String` here
    # or the guard below refuses it for a reason ("must be strings") it already satisfied.
    item isa AbstractString && (item = String(item))
    # #533 — the enumeration used to omit `CTE(...)` and `Joined(...)`, admitted since #444/#481, so
    # the message named fewer spellings than the guard accepted. It also gains the ordering case: an
    # `SQLOrder` used to satisfy this test through `SQLTypeOrder <: SQLTypeField` and then die at
    # render with a raw `MethodError` (#529); it is refused here now, and the refusal says why.
    item isa SQLTypeOrder && throw(QueryBuildError(
      "WindowOver $part_name does not take an \e[4m\e[31mSQLOrder\e[0m: an ordering term carries a " *
      "direction, which has no meaning in \e[4m\e[31mPARTITION BY\e[0m. Write the column itself — " *
      "\e[4m\e[32m$part_name = \"column\"\e[0m, \e[4m\e[32mCTE(\"name\", \"path\")\e[0m, " *
      "\e[4m\e[32mJoined(\"alias\", \"column\")\e[0m or an \e[4m\e[32mF(...)\e[0m expression (#533)."))
    item isa WindowPartitionPart || throw(QueryBuildError("WindowOver $part_name entries must be strings, SQL fields, SQL functions, F expressions, CTE(\"name\", \"path\") or Joined(\"alias\", \"column\"). Got $(typeof(item))."))
    push!(parts, item)
  end
  return parts
end

function _window_order_vector(value)::Vector{WindowOrderPart}
  value === nothing && return WindowOrderPart[]
  values = value isa Tuple ? collect(value) : value isa AbstractVector ? collect(value) : [value]
  parts = WindowOrderPart[]
  for item in values
    item isa Symbol && (item = String(item))
    # #603: the same normalization one line up, for the other spelling a caller can produce. The
    # `WindowPartitionPart` / `WindowOrderPart` vectors these push into are `Union{String,...}`
    # WITHOUT `Nothing`, so they have no `convert` fallback — a view has to become a `String` here
    # or the guard below refuses it for a reason ("must be strings") it already satisfied.
    item isa AbstractString && (item = String(item))
    # #533 — same omission as the sibling guard above: `CTE(...)` / `Joined(...)` have been admitted
    # here since #444/#481 and the message never said so.
    item isa WindowOrderPart || throw(QueryBuildError("WindowOver order_by entries must be strings, SQLOrder objects, CTE(\"name\", \"path\") or Joined(\"alias\", \"column\"). Got $(typeof(item))."))
    push!(parts, item)
  end
  return parts
end

"""
    WindowOver(partition_by, order_by = []; frame = nothing) -> WindowSpec
    WindowOver(; partition_by = [], order_by = [], frame = nothing) -> WindowSpec

Build the `OVER (...)` clause shared by every window function — this is the constructor you
want; [`WindowSpec`](@ref) is the value it returns.

# Arguments
- `partition_by`: restart the window per group. A field path, an `F` expression, or a
  vector/tuple of them. `Symbol`s are accepted and converted.
- `order_by`: ordering inside each window. Strings use the repo-wide `"-field"` convention
  for `DESC`; `SQLOrder` objects also work, and add an explicit `nulls = :first`/`:last`
  placement, which a string entry has no room for. With `nulls` unset the window emits no `NULLS`
  clause, which is the rendering every window has always produced.
  Since #509 an `SQLOrder` can also carry a CTE column — `SQLOrder(CTE("name", "col"))`, or the
  equivalent `"name__col"` path, both of which a bare entry has been able to name since #492 — and
  a `Joined` column, which only a handle can name. An `SQLOrder`'s direction is its own
  `orientation`, so `desc = true` on a handle nested inside one is refused; pass
  `orientation = "DESC"` instead.
- `frame`: a frame clause such as `"ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING"`.
  It is SQL grammar rather than a value, so it cannot be a bind parameter: PormG parses it and
  writes its own spelling back. Accepted: `ROWS`, `RANGE` or `GROUPS`, then one bound or
  `BETWEEN <bound> AND <bound>`, optionally followed by
  `EXCLUDE CURRENT ROW | GROUP | TIES | NO OTHERS`. A bound is `UNBOUNDED PRECEDING`,
  `<n> PRECEDING`, `CURRENT ROW`, `<n> FOLLOWING` or `UNBOUNDED FOLLOWING`, where `<n>` is a
  non-negative integer (under `RANGE` also a decimal, or `INTERVAL '<n> <unit>'`). Keywords are
  case-insensitive. Anything else — including a frame PostgreSQL itself would refuse, such as one
  whose end comes before its start — raises `InvalidValueError` when `WindowOver` is called, on
  both backends.

Both list arguments accept a bare scalar, so `partition_by = "raceid"` and
`partition_by = ["raceid"]` are equivalent. An entry of any other type raises
`QueryBuildError`.

!!! warning "`frame` is PostgreSQL-only"
    Passing `frame` on a SQLite connection raises `BackendCapabilityError`. Everything else
    here works on both backends (SQLite ≥ 3.25.0).

```julia
using PormG.Functions: WindowOver, Rank

# Rank drivers within each race — the ranking restarts per race.
query = M.Driver_standings.objects
query.filter("raceid__@in" => [305, 306], "points__@gt" => 0)
query.values(
    "raceid", "driverid__surname", "points",
    "race_rank" => Rank(over=WindowOver(
        partition_by=["raceid"],   # restart the ranking for each race
        order_by=["-points"]       # highest points = rank 1
    ))
)
```

See also [Window Functions](@ref).
"""
function WindowOver(partition_by, order_by=WindowOrderPart[]; frame::Union{AbstractString,Nothing}=nothing)
  # #603: `frame` is the third keyword on the constructor whose other two this issue widened. A
  # keyword TYPE ANNOTATION does not convert — it raises `TypeError`, which is outside `PormGError`
  # entirely — so the annotation is widened and the `WindowSpec` slot converts on construction.
  #
  # This comment lives INSIDE the body on purpose: a comment between a docstring and its `function`
  # DETACHES the docstring. Placing it above cost `WindowOver` its docs entirely, which failed
  # `test_docstring_coverage.jl` and then the docs build, unresolving the five `[`WindowOver`](@ref)`
  # links in `src/PormG.jl`, this file and `types.jl` (`api.md` renders them through `@autodocs`;
  # it contains no `@ref` of its own).
  #
  # #713: the frame is SQL grammar, not a value, so it is parsed here and stored as PormG's own
  # rebuilt spelling — a hostile string never reaches the node. `_build_over_clause` parses again,
  # because `WindowSpec` is exported and mutable and can be assembled without this constructor.
  return WindowSpec(
    partition_by=_window_part_vector(partition_by, "partition_by"),
    order_by=_window_order_vector(order_by),
    frame=frame === nothing ? nothing : Dialect.window_frame_sql(frame)
  )
end
function WindowOver(; partition_by=WindowPartitionPart[], order_by=WindowOrderPart[], frame::Union{AbstractString,Nothing}=nothing)
  return WindowOver(partition_by, order_by; frame=frame)
end

"""
    Rank(; over::WindowSpec = WindowOver())
    Rank(over::WindowSpec)

Window `RANK()` — position within the window, **leaving gaps after ties**: two rows tied for
1st are both `1` and the next row is `3`.

Takes no column; the ordering comes entirely from `over`. Omitting `over` ranks the whole
result set as one unordered window, which is rarely what you want — pass a
[`WindowOver`](@ref) with `order_by`. The positional form `Rank(spec)` is shorthand for
`Rank(over=spec)`.

See also [`DenseRank`](@ref) (no gaps), [`RowNumber`](@ref) (always unique),
[Window Functions](@ref).
"""
Rank(; over::WindowSpec=WindowOver()) = WindowFunction(function_name="RANK", column=nothing, over=over)
Rank(over::WindowSpec) = Rank(over=over)
_result_rule(::Val{:RANK}) = CInt64()

"""
    DenseRank(; over::WindowSpec = WindowOver())
    DenseRank(over::WindowSpec)

Window `DENSE_RANK()` — like [`Rank`](@ref), but **without gaps after ties**: two rows tied
for 1st are both `1` and the next row is `2`, not `3`.

Use it when you want "how many distinct values outrank this one", and [`Rank`](@ref) when
you want a true finishing position.

See also [`RowNumber`](@ref), [Window Functions](@ref).
"""
DenseRank(; over::WindowSpec=WindowOver()) = WindowFunction(function_name="DENSE_RANK", column=nothing, over=over)
DenseRank(over::WindowSpec) = DenseRank(over=over)
_result_rule(::Val{:DENSE_RANK}) = CInt64()

"""
    RowNumber(; over::WindowSpec = WindowOver())
    RowNumber(over::WindowSpec)

Window `ROW_NUMBER()` — a unique sequential number per row within the window, starting at 1.

Unlike [`Rank`](@ref) and [`DenseRank`](@ref) it never repeats a value, which means tied rows
get an **arbitrary** order between them. If the numbering has to be reproducible, add a
tiebreaker column to the `order_by` of the [`WindowOver`](@ref).

See also [Window Functions](@ref).
"""
RowNumber(; over::WindowSpec=WindowOver()) = WindowFunction(function_name="ROW_NUMBER", column=nothing, over=over)
RowNumber(over::WindowSpec) = RowNumber(over=over)
_result_rule(::Val{:ROW_NUMBER}) = CInt64()

"""
    Lag(x; offset::Integer = 1, default = nothing, over::WindowSpec = WindowOver())

Window `LAG(x, offset)` — the value of `x` from `offset` rows **earlier** in the window.

# Arguments
- `x`: the column to read — a column path, an expression, or a `Subquery(...)` projecting one
  value per row. Required — passing `nothing` raises `QueryBuildError`.
- `offset`: how many rows back. Must be non-negative; negatives raise `QueryBuildError`
  (use [`Lead`](@ref) to look forward).
- `default`: value returned at the window edge where no previous row exists. Omit it and
  those rows come back `missing`/`NULL`.
- `over`: the [`WindowOver`](@ref) spec. `order_by` is what makes "earlier" meaningful.

`offset` and a plain-value `default` are bound as query parameters, not interpolated. A column
expression as `default` — `default = F("grid")` — renders as that column instead.

See also [`Lead`](@ref), [Window Functions](@ref).
"""
function Lag(x::WindowColumnArg; offset::Integer=1, default=nothing, over::WindowSpec=WindowOver())
  offset < 0 && throw(QueryBuildError("Lag offset must be a non-negative integer"))
  kwargs = Dict{String,Any}("offset" => offset)
  default !== nothing && (kwargs["default"] = default)
  return WindowFunction(function_name="LAG", column=_norm_fn_arg(x), over=over, kwargs=kwargs)
end
_result_rule(::Val{:LAG}) = :operand

"""
    Lead(x; offset::Integer = 1, default = nothing, over::WindowSpec = WindowOver())

Window `LEAD(x, offset)` — the value of `x` from `offset` rows **later** in the window. The
forward-looking mirror of [`Lag`](@ref); the arguments, the parameter binding, the
`QueryBuildError` on a negative `offset`, and the `default`-at-the-edge behavior are
identical.

See also [Window Functions](@ref).
"""
function Lead(x::WindowColumnArg; offset::Integer=1, default=nothing, over::WindowSpec=WindowOver())
  offset < 0 && throw(QueryBuildError("Lead offset must be a non-negative integer"))
  kwargs = Dict{String,Any}("offset" => offset)
  default !== nothing && (kwargs["default"] = default)
  return WindowFunction(function_name="LEAD", column=_norm_fn_arg(x), over=over, kwargs=kwargs)
end
_result_rule(::Val{:LEAD}) = :operand

"""
    FirstValue(x; over::WindowSpec = WindowOver())

Window `FIRST_VALUE(x)` — the value of `x` in the first row of the window frame.

Safe under the default frame (`RANGE BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW`), because
the frame always starts at the partition's first row. [`LastValue`](@ref) is **not** — see
its docstring.

See also [`NthValue`](@ref), [Window Functions](@ref).
"""
FirstValue(x::WindowColumnArg; over::WindowSpec=WindowOver()) = WindowFunction(function_name="FIRST_VALUE", column=_norm_fn_arg(x), over=over)
_result_rule(::Val{:FIRST_VALUE}) = :operand

"""
    LastValue(x; over::WindowSpec = WindowOver())

Window `LAST_VALUE(x)` — the value of `x` in the last row of the window frame.

!!! warning "The default frame makes this return the current row"
    SQL's default frame is `RANGE BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW`, so with an
    `order_by` and no explicit `frame` the "last visible row" *is* the current row —
    `LastValue` silently returns each row's own value instead of the partition's last. This
    is correct SQL, not a PormG bug, and it is the single most common window-function trap.

    Pass an explicit frame to see the whole partition:

    ```julia
    WindowOver(
        partition_by = ["constructorid"],
        order_by     = ["positionorder"],
        frame = "ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING"  # PostgreSQL only
    )
    ```

    `frame` is PostgreSQL-only (`BackendCapabilityError` on SQLite). On SQLite, drop the
    `order_by` so the whole partition is one frame, or compute the value another way.

See also [`FirstValue`](@ref), [Window Functions](@ref).
"""
LastValue(x::WindowColumnArg; over::WindowSpec=WindowOver()) = WindowFunction(function_name="LAST_VALUE", column=_norm_fn_arg(x), over=over)
_result_rule(::Val{:LAST_VALUE}) = :operand

"""
    NthValue(x, n::Integer; over::WindowSpec = WindowOver())

Window `NTH_VALUE(x, n)` — the value of `x` in the `n`-th row of the window frame, counting
from 1. `n <= 0` raises `QueryBuildError`.

`n` is **positional, not a keyword**, and is rendered as a literal integer in the SQL rather
than a bound parameter — SQL requires a constant there.

The same frame caveat as [`LastValue`](@ref) applies whenever `n` reaches past the current
row: under the default frame those rows come back `NULL`.

```julia
using PormG.Functions: NthValue, WindowOver

"runner_up" => NthValue("driverid__surname", 2,
    over=WindowOver(partition_by=["raceid"], order_by=["positionorder"]))
```

See also [`FirstValue`](@ref), [Window Functions](@ref).
"""
function NthValue(x::WindowColumnArg, n::Integer; over::WindowSpec=WindowOver())
  n <= 0 && throw(QueryBuildError("NthValue n must be a positive integer"))
  return WindowFunction(function_name="NTH_VALUE", column=_norm_fn_arg(x), over=over, kwargs=Dict{String,Any}("n" => n))
end
_result_rule(::Val{:NTH_VALUE}) = :operand

"""
    Value(x)

Wraps a literal value for use in SQL queries. It binds as a parameter, except `nothing`, which
renders as `NULL`.

A string, an integer of any width, a float, a `Bool`, a `Date`, `DateTime`, `ZonedDateTime` or
`Time`, or a `UUID` binds on both engines. On SQLite each binds as what its column would store: a
date or time as the text a `DateField`/`DateTimeField`/`TimeField` holds, and an integer as
`Int64`. A projected `Date`, `DateTime` or `Time` reads back typed: `values("d" => Value(Date(2021, 3, 28)))`
is a `Date`, and a `DateTime` comes back as a UTC `ZonedDateTime` on SQLite, as a SQLite
`DateTimeField` column does. A float binds as a double on SQLite, so a `BigFloat` or `Decimal` is
narrowed to `Float64` there. A value SQLite cannot store as itself (a `Symbol`, a `Rational`, an
integer beyond `Int64`, an arbitrary struct) raises `InvalidValueError` there instead of being bound
as a serialized Julia object.

A `Sockets.IPv4` / `Sockets.IPv6` binds on PostgreSQL as an `inet`, in the text PostgreSQL prints
for it: `Value(ip"::FFFF:10.0.0.1")` is `::ffff:10.0.0.1`. SQLite has no network type, so there it
raises `InvalidValueError`.

```julia
using PormG.Functions: Value

"season_label" => Value("2021 season")
```
"""
function Value(x::Any)
  return SQLText(x)
end
# #444: `Value` wraps a LITERAL. A CTE handle reaching it was bound as a parameter — the SQL rendered
# `? as "x"` with the struct itself in the parameter vector, no join emitted, and the driver left to
# reject a value it cannot encode. `Value(x)` accepts `Any` by design, so the refusal has to be an
# explicit method.
Value(x::CTEReference) = throw(QueryBuildError(
  "\e[4m\e[32mValue\e[0m wraps a literal, not a column. Project the CTE column directly — " *
  "\e[4m\e[32mvalues(\"x\" => CTE(\"$(x.name)\", \"$(x.path)\"))\e[0m (#444)."))
# #481: the joined-copy handle is a column too, and reaches `Value(x::Any)` the same way.
Value(x::JoinedReference) = throw(QueryBuildError(
  "\e[4m\e[32mValue\e[0m wraps a literal, not a column. Project the joined column directly — " *
  "\e[4m\e[32mvalues(\"x\" => Joined(\"$(x.alias)\", \"$(x.path)\"))\e[0m (#481)."))

# #705 — one reading for a function OPERAND, shared by every constructor that takes its operands
# untyped (`Coalesce`, `Greatest`, `Least`, `NullIf`, `Power`, `Mod`, `Replace`, `Concat`).
#
# They turned a string into a column and stored anything else as is, and the build walk
# (`_check_function`, build_helpers.jl) has no arm for a Julia number — so `Coalesce("points", 0)`,
# the most natural way to write a default, died in `values()` with a raw `MethodError` naming an
# internal function. Django's `Func` wraps a non-string argument in `Value` (`_parse_expressions`),
# and so does this: a scalar literal becomes `Value(x)` and binds as a parameter, exactly as
# `Coalesce("points", Value(0))` always did. A string is still a column path — a string LITERAL needs
# `Value("…")`, as in Django.
#
# The literal set is every number and every date/time value. `Value(x)` binds its literal as a
# parameter, and since #721 the SQLite binder (`sqlite_bind_value`, value_repr.jl) turns each of them
# into what SQLite stores — an integer of any width into `Int64`, a `Date` into the text a date column
# holds — so a function compares against the value, not a serialized Julia object. Before #721 these
# bound as a BLOB and #705 refused them here; that refusal was a stop-gap and is gone.
# `BigFloat`/`Decimal` stay out for `_CompareLiteral`'s reason (types.jl), and a `Period` because a
# bare duration has no one reading as an operand (an interval on PostgreSQL, text on SQLite). A PormG
# node passes through untouched — the walk owns those. Anything else is refused HERE, at the
# constructor, rather than as a `MethodError` from the walk.
#
# #843 — a string operand is stored as a bare `String`, the reading `Concat` already used, and not
# wrapped as `SQLField(x)`. The build walk resolves a bare string through the transform ladder
# (`_check_function(::AbstractString)`, #562), so `Coalesce("ts__@date", "d")` gets the same `DATE`
# node `Max("ts__@date")` and `F("ts__@date")` get. The `SQLField` arm of the walk returns its node
# untouched, so the wrap sent `__@date` on to join resolution as if it named a column, and the build
# died with "does not have a 'how' property". The wrap existed to dodge the walk's `Vector{String}`
# arm, which reads a vector as ONE split path; every constructor below builds an `Any[]` column, which
# takes the per-element arm instead, so there is nothing left to dodge.
const _FunctionLiteral = Union{Bool,Integer,Float16,Float32,Float64,
                               Dates.Date,Dates.DateTime,Dates.Time,ZonedDateTime}
#
# #867 — "a PormG node passes through" now means a node the walk has an arm for. The pass-through
# used to be `Union{SQLType,SQLObject}`, which admitted an `SQLOrder` and a bare query handler
# (`Coalesce(qs, 0)`, `Subquery` forgotten), and both died in `values()` with a raw `MethodError`
# naming `_check_function` (#533's defect class). The union below is that consumer set, named once;
# every other node is refused here by type name. `repr` is not used for those, for the reason given
# at `_aggregate_operand` above.
const _FunctionOperandNode = Union{SQLTypeField,SQLTypeText,SQLTypeFunction,SQLTypeF,SQLTypeOper,
                                  SQLTypeQ,SQLTypeQor,SQLTypeCTE,SQLTypeJoined,
                                  SubqueryObject,ExistsObject}
_function_operand(x::AbstractString) = String(x)
_function_operand(x::_FunctionLiteral) = Value(x)
_function_operand(x::_FunctionOperandNode) = x
_function_operand(::SQLObjectHandler) = throw(QueryBuildError(
  "A query is not a function operand. Project one value from it and wrap it — " *
  "\e[4m\e[32ms.values(\"col\"); Coalesce(Subquery(s), 0)\e[0m (#867)."))
_function_operand(::SQLTypeOrder) = throw(QueryBuildError(
  "An ordering term is not a function operand. Pass the column path — " *
  "\e[4m\e[32mCoalesce(\"col\", 0)\e[0m — and order with \e[4m\e[32morder_by\e[0m (#867)."))
_function_operand(x::Union{SQLType,SQLObject}) = throw(QueryBuildError(
  "A `$(nameof(typeof(x)))` is not a function operand. An operand is a column path (a string), a " *
  "literal, or an expression (`F(...)`, a function, `Subquery(...)`, `CTE(...)`) (#867)."))
_function_operand(x) = throw(QueryBuildError(
  "A \e[4m\e[31m$(typeof(x))\e[0m is not a function operand. An operand is a column " *
  "path (a string), a number, a `Bool`, a `Date`/`DateTime`/`ZonedDateTime`/`Time`, or an expression " *
  "(a duration is not one); wrap any other literal as " *
  "\e[4m\e[32mValue(x)\e[0m (#705)."))
# `Replace`'s `find`/`replace` and `LPad`/`RPad`'s `fill` (#122): TEXT slots, so a string there is a
# literal. A number is refused rather than converted — PostgreSQL has no `replace(text, bigint,
# bigint)`, and turning `1` into `"1"` would be a guess the caller can spell for themselves. `does`
# opens the refusal with what the function does with the slot.
_text_operand(x::AbstractString, does::AbstractString) = Value(String(x))
_text_operand(x::Union{Integer,Float16,Float32,Float64}, does::AbstractString) = throw(QueryBuildError(
  "$(does), and a $(typeof(x)) is a number. " *
  "Write it as a string: \e[4m\e[32mstring(x)\e[0m (#705)."))
_text_operand(x, does::AbstractString) = _function_operand(x)

# #878 — the operand of the one-argument scalar functions (`Lower`, `Upper`, `Trim`, `LTrim`,
# `RTrim`, `Length`, `Abs`, `Round`, `Floor`, `Ceil`, `Sqrt`, `Exp`, `Ln`, `Cast`), named once. The
# union used to be spelled out in each signature and omitted `SubqueryObject`, so `Lower(Subquery(s))`
# was a `MethodError` while `Coalesce(Subquery(s), 0)` worked. A subquery is one value per row, which
# is all these functions need, and Django takes the same spelling. Every member has a consumer in the
# build walk and the renderer (#533); `test_node_admission.jl` probes this union directly.
const _ScalarOperand = Union{AbstractString,SQLTypeField,SQLTypeText,SQLTypeFunction,SQLTypeF,
                             SQLTypeCTE,SQLTypeJoined,SubqueryObject}

# #859 — `Coalesce`, `Greatest` and `Least` take at least two expressions, as Django's do ("Greatest
# must take at least two expressions"). One argument is never useful — the result IS that argument —
# and it was not harmless: SQLite's `max(x)`/`min(x)` are scalar only with two or more arguments, so a
# one-argument `Greatest(x)` rendered the AGGREGATE `MAX(x)` and collapsed the result to one row (no
# GROUP BY, no warning), while PostgreSQL's `GREATEST(x)` returned `x` per row. `Coalesce(x)` failed
# only at SQLite, whose `coalesce` needs two; no arguments at all failed only at the database.
# Checked after `output_field` (a bad type string reports as itself) and before the operands.
function _check_operand_count(fname::AbstractString, x::Tuple)
  length(x) >= 2 && return nothing
  throw(QueryBuildError(
    "\e[4m\e[31m$(fname)\e[0m must take at least two expressions; got $(length(x)). With one " *
    "argument the result is that argument: write it directly, as \e[4m\e[32mF(\"points\")\e[0m (#859)."))
end

# #696: every `output_field=` goes through here, so a type string is validated when the expression
# is built rather than when it renders. A field object contributes its canonical `type`; the dialect
# maps that to the engine's spelling (`BLOB` → `bytea`). `""` has always meant "no cast" to `CASE`.
_output_field_type(::Nothing) = nothing
_output_field_type(f::PormGField) = Dialect.cast_type_name(f.type; context = "output_field")
_output_field_type(s::AbstractString) = isempty(s) ? nothing : Dialect.cast_type_name(s; context = "output_field")

"""
    Cast(expression, type)

Casts a column or expression to a SQL type — PostgreSQL `(x)::type`, SQLite `CAST(x AS type)`.
SQLite has no time types: a `date` target renders `date(x)` there, and `timestamp`, `timestamptz`,
`time` and `interval` raise `BackendCapabilityError` (#822).

`type` is preferably a field object (`Cast("grid", BigIntegerField())`), which renders in each
engine's own spelling. A string is accepted when it is a single type name (`"integer"`, `"bigint"`,
`"text"`, `"timestamptz"`), one of the multi-word names `"double precision"`,
`"character varying"`, `"bit varying"`, `"timestamp with time zone"` (and `without`, and the `time`
forms), optionally followed by a size `(n)` or `(n, m)` — `"numeric(10,2)"`, `"varchar(20)"` — and,
on PostgreSQL only, array brackets (`"integer[]"`). Anything else raises `InvalidValueError` when
the expression is built, on both engines: a type name is a keyword in the SQL, so it cannot be a
bind parameter, and PormG only writes a spelling it has parsed. The same rule applies to every
`output_field=` string.

The expression may be a column path, an `F(...)` expression, another function or a
`Subquery(...)` — `Cast(Subquery(s), "date")` casts the one value the subquery returns per row.

A cast the two engines apply differently raises `QueryBuildError` when the query is built (#1028):

- to text (`CharField()`, `"text"`, …), any operand `Concat` refuses: a boolean (`'true'` vs `'1'`),
  a float (`'25'` vs `'25.0'`), a decimal, a `numeric` function, a timestamp, an interval or a whole
  JSON document;
- to an integer, a float, a decimal or a `numeric` function: PostgreSQL rounds it and SQLite
  truncates it. Round it first — `Cast(Round(x), IntegerField())`, `Floor(x)` or `Ceil(x)` read the
  same integer on both engines. A boolean casts to `1`/`0` on both and passes;
- to `numeric(p, s)` (or `numeric(p)`, scale 0), an operand with more than `s` digits after the
  point — a float column, a float literal with more places (#1050), text, a `numeric` function, a
  decimal with more places (#1040): PostgreSQL rounds
  to the scale and SQLite keeps every digit. Round it to the scale first —
  `Cast(Round(x, 2), "numeric(10,2)")` — or cast to an unscaled `"numeric"`.

```julia
using PormG.Functions: Cast, Round
using PormG.Models: IntegerField

M.Result.objects.values("resultid", "points_int" => Cast(Round("points"), IntegerField()))
M.Result.objects.values("resultid", "points_num" => Cast("points", "numeric"))
```

See also [Functions and Dates](@ref).
"""
function Cast(x::_ScalarOperand, type::AbstractString)
  return FObject(function_name = "CAST", column = _norm_fn_arg(x), aggregate = _any_agg(x), kwargs = Dict{String, Any}("type" => Dialect.cast_type_name(type)))
end
_result_rule(::Val{:CAST}) = :declared
function Cast(x::_ScalarOperand, type::PormGField)
  return Cast(x, type.type)
end

"""
    Concat(expressions; output_field=nothing)

Concatenates multiple strings or columns.

A NULL operand is skipped, read as an empty string, on both engines, so the result is never NULL:
`Concat(Value("#"), "number", Value(" "), "surname")` is `"# Senna"` for a driver with no number.
This follows Django's `Concat`. PostgreSQL renders `CONCAT(…)`, which skips a NULL itself, and
SQLite renders `COALESCE(operand, '') || …`. To get NULL when a column is NULL, test it explicitly:
`Case(When("number__@isnull" => false, then = Concat(…)))` — a `Case` with no match is NULL.

Text, integer, date, time and uuid operands read the same on both engines. A boolean, a float or a
decimal operand raises `QueryBuildError` — a literal (`true`, `1.5`, a `Decimal`) when the expression
is built, a `BooleanField`/`FloatField`/`DecimalField` column or an expression of those types when the
query is — because PostgreSQL's `CONCAT` writes `t`, `25`, `3.00` where SQLite's `||` writes `1`,
`25.0`, `3` (#1027). So does a timestamp, an interval or a whole JSON document (#1028), whose text
differs the same way. Write the text yourself: a `Case` for a boolean, `ToChar(x, "YYYY-MM-DD
HH:MI:SS")` for a timestamp, and for the rest, format the fetched value in Julia.
`Cast(…, CharField())` is refused over the same operands, for the same reason.

The result is text on both engines, so `output_field`, when given, must be a text type
(`CharField()`, `TextField()`, `"text"`, `"varchar(20)"`). Any other type raises
`InvalidValueError` when the expression is built. `Concat` renders no cast, so a number declared
there would be a type the SQL never applies. To get a number, cast the result explicitly:
`Cast(Concat(…), "integer")`.
"""
function Concat(x::Vector; output_field::Union{N, AbstractString, Nothing} where N <: PormGField = nothing, _as::AbstractString="")
  output_field = _output_field_type(output_field)   # #603, #696
  _check_concat_output_field(output_field)          # #835
  # #603: the string ELEMENTS too, so no view is ever stored on the node. The original reason was
  # that `_check_function`'s vector arm assigns its result back in place and a narrowly-typed vector
  # would fail that store; since #612 made the container `Any[]` the store cannot fail, so this is
  # now about what the node HOLDS rather than about the walk surviving. Still wanted: a `SubString`
  # reaching the renderer retains its whole parent buffer.
  #
  # #612: `Any[...]`, not a type-preserving comprehension. A HOMOGENEOUS string vector —
  # `Concat(["forename", "surname"])`, the documented signature's most obvious spelling — stayed a
  # `Vector{String}` and so dispatched to `_check_function(::Vector{String})`, the arm that reads a
  # whole vector as ONE already-split `__@` path. It answered
  # `FilterError: "forename__@surname" is invalid`, naming a path the caller never wrote.
  #
  # What escaped was a HETEROGENEOUS argument list, not the variadic form as such: `collect` of a
  # homogeneous tuple is a `Vector{String}` too, so `Concat("forename", "surname")` was broken in
  # exactly the same way. Every `Concat` in the docs and tests happens to carry a `Value(" ")`
  # separator, which makes the collected vector `Vector{Any}` and routes it to the per-element arm
  # — that accident, not the spelling, is why this went unseen.
  #
  # Widening the CONTAINER rather than the walk, because the walk's `Vector{String}` semantics is
  # correct where it is reached from: `_check_function(::AbstractString)` splits a path on `__@` and
  # hands the pieces straight to it. Concat's payload is a list of operands, never one split path,
  # so the fix belongs at the seam that knows which of the two this is.
  #
  # Not an `SQLField(String(v))` wrap: Concat's elements legitimately carry `__@` transform paths
  # (`Concat("date__@year", ...)`), and wrapping would strip the per-element resolution that makes
  # those work. The other operand-taking constructors used that wrap until #843 found it broke them
  # the same way; `_function_operand` now stores a string bare for all of them.
  # #705: a number part is a literal (`Value`), as in the other operand-taking constructors.
  processed_cols = Any[_function_operand(v) for v in x]
  # #1027: a literal's type is known now, so it is refused when the expression is built. A column's is
  # known only once its path resolves, which the render checks (`_render_function_body`).
  for col in processed_cols
    textless = col isa SQLText ? _textless_literal(col.field) : nothing
    textless === nothing || throw(_concat_textless_refusal(textless...))
  end
  return FObject(function_name = "CONCAT", column = processed_cols, aggregate = _any_agg(processed_cols), kwargs = Dict{String, Any}("output_field" => output_field, "as" => String(_as)))
end
_result_rule(::Val{:CONCAT}) = CText()   # its `output_field` renders no cast (#835): the value is text
# #835: `CONCAT(…)` / `a || b` is text on both engines, and `Dialect.CONCAT` renders no cast, so a
# non-text `output_field` named a type the SQL never applied. The CTE typing believed it (a column
# of `'Hamilton1'` typed INTEGER, refusing "abc" and binding 7 as a number against text — on SQLite
# a silent empty result) while the alias filter checked text. Refused here, at construction, so the
# two readers agree by construction; the explicit spelling is `Cast(Concat(…), type)`, which does
# render the cast. A text type stays legal: it is what the value already is.
# An array is not text whatever its element; `_sql_type_field` answers `nothing` for one (#852).
function _check_concat_output_field(t::Union{String,Nothing})
  t === nothing && return nothing
  _sql_type_field(t) isa Union{Models.sCharField, Models.sTextField} && return nothing
  throw(InvalidValueError(
    "Concat returns text on both engines and renders no cast, so its output_field cannot be " *
    "\e[31m$(t)\e[0m. Cast the result instead: \e[32mCast(Concat(…), \"$(lowercase(t))\")\e[0m (#835)."))
end

# #1027 — the one message for a `Concat` operand with no single text (`_concat_textless_operand`,
# projection_types.jl), raised at construction for a literal and at render for a column. The way out
# is the caller's own text. For a boolean, a `Case` writes it on both engines. For a number there is
# no SQL spelling that agrees: `Cast(x, CharField())` is `'25'` on PostgreSQL and `'25.0'` on SQLite,
# and `Cast(x, IntegerField())` rounds on one and truncates on the other. So the advice is to format
# it in Julia, where the caller chooses the digits.
function _concat_textless_refusal(kind::Symbol, what::AbstractString; flag::AbstractString = "<flag>")
  why = kind === :bool ? "a boolean reads `t` on PostgreSQL and `1` on SQLite" : _divergent_text_why(kind)
  issue = kind in (:timestamp, :interval, :json) ? "#1028" : "#1027"
  return QueryBuildError(
    "\e[4m\e[31mConcat\e[0m cannot make the same text from $(what) on both engines: $(why) ($(issue)). " *
    _divergent_text_fix(kind, flag))
end

# #1028 — the text each engine makes of an operand `_concat_textless_operand` classifies, for both
# refusals. A boolean differs between them: `CONCAT` writes PostgreSQL's output form `t`, a cast to
# text the word `true`, so each caller words its own.
_divergent_text_why(kind::Symbol) =
  kind === :float ? "a float reads `25` on PostgreSQL and `25.0` on SQLite" :
  kind === :decimal ? "a decimal reads `3.00` on PostgreSQL and `3` on SQLite" :
  kind === :timestamp ? "a timestamp reads `2009-03-29 06:00:00+00` on PostgreSQL and `2009-03-29T06:00:00.000+00:00` on SQLite" :
  kind === :interval ? "PostgreSQL writes an interval in its `IntervalStyle` (`PT25.021S`, `1 day 02:00:00`) and SQLite as PormG stored it (`00:00:25.021`)" :
  kind === :json ? "PostgreSQL's `jsonb` re-renders a document (`{\"a\": [1, 2]}`) and SQLite keeps the stored text (`{\"a\":[1,2]}`)" :
  # #1087/#1111: a whole number PostgreSQL types `numeric`, divided — the split is the division.
  kind === :integer_division ? "PostgreSQL divides it as `numeric` (`15 / 2` is `7.5`) and SQLite as an integer (`7`)" :
                   "PostgreSQL computes it as `numeric` (`1`) and SQLite as a REAL (`1.0`)"
_divergent_text_fix(kind::Symbol, flag::AbstractString) =
  kind === :bool ?
    "Write the text you mean: \e[32mCase(When(\"$(flag)\" => true, then = Value(\"yes\")), default = \"no\")\e[0m." :
  kind === :timestamp ?
    "Name the format: \e[32mToChar(\"$(flag)\", \"YYYY-MM-DD HH:MI:SS\")\e[0m reads the same on both engines." :
  kind in (:interval, :json) ?
    "PormG does not choose its text: fetch the value and format it in Julia." :
    "PormG does not choose a number's text: fetch the value and format it in Julia " *
    "(\e[32mstring(row.points)\e[0m, \e[32mround(x; digits = 2)\e[0m)."

# #1028 — the one message for a declared cast the engines apply differently (`_cast_divergent_operand`,
# projection_types.jl), raised when the query renders. `fname` is the function as the caller wrote it.
# To an integer the way out is to say how to round, which `Round`/`Floor`/`Ceil` do on both engines.
function _cast_divergent_refusal(fname::AbstractString, kind::Symbol, what::AbstractString,
                                 target::Symbol, flag::AbstractString)
  # #1040: `flag` is the declared type. The way out is to round first, which makes every value fit the
  # scale on both engines (only a tie can round apart: #1061 follows Django there), or an unscaled
  # `numeric`, which keeps the value.
  if target === :scale
    why = "PostgreSQL rounds a value cast to $(flag) to its scale (`1.555` → `1.56` at scale 2, `1.5` → `2` at scale 0) and SQLite keeps every digit"
    # #1111: an integer division has no fraction on SQLite at all, so the split is the division, and
    # the way out is to divide as a float first.
    kind === :integer_division && (why = _divergent_text_why(kind) * ", so only PostgreSQL has a fraction to round to $(flag)")
    scale = something(_numeric_cast_scale(flag), 0)
    # Text is not rounded either (`_round_text_refusal`): it is made a number first.
    spelled = kind === :text ? "Cast(x, FloatField())" : "x"
    fix = "Round it to the scale first (\e[32mCast(Round($(spelled), $(scale)), \"$(flag)\")\e[0m, #1061), or cast to an " *
          "unscaled \e[32m\"numeric\"\e[0m, which keeps the value on both engines."
    # An unscaled cast keeps `7` on SQLite and `7.5` on PostgreSQL, so it is no way out here.
    kind === :integer_division && (fix =
      "Divide as a float first, so SQLite keeps the fraction too, then round it to the scale " *
      "(\e[32mCast(Round(x / 2.0, $(scale)), \"$(flag)\")\e[0m, #1061), or fetch the number and divide it in Julia.")
    return QueryBuildError(
      "\e[4m\e[31m$(fname)\e[0m cannot make the same number from $(what) on both engines: $(why) (#1040). $(fix)")
  end
  # #1087: a literal too large for the precision. The way out is a precision that holds it.
  if target === :precision
    precision, scale = something(_numeric_cast_size(flag), (0, 0))
    # A scale at or above the precision leaves no digit before the point: `numeric(2,3)` holds below 0.1.
    holds = precision > scale ? "at most $(_digit_count(precision - scale)) before the point" :
            "only values below $(precision == scale ? "1" : "0." * "0"^(scale - precision - 1) * "1")"
    why = "$(flag) holds $(holds), so PostgreSQL raises a " *
          "numeric field overflow and SQLite stores the value as it is"
    fix = "Declare a precision that holds it (\e[32mCast(x, \"numeric(p, $(scale))\")\e[0m with a larger p), or cast to an " *
          "unscaled \e[32m\"numeric\"\e[0m."
    return QueryBuildError(
      "\e[4m\e[31m$(fname)\e[0m cannot make the same number from $(what) on both engines: $(why) (#1087). $(fix)")
  end
  if target === :integer
    why = "PostgreSQL rounds a fractional number cast to an integer (`1.5` → `2`) and SQLite truncates it (`1.5` → `1`)"
    fix = "Say how to round it: \e[32mCast(Round(x), IntegerField())\e[0m, \e[32mFloor(x)\e[0m or \e[32mCeil(x)\e[0m read the same integer on both engines."
    # #1111: rounding after an integer division cannot bring the half back on SQLite. The fraction
    # exists on both engines only when the division is a float's.
    if kind === :integer_division
      why = _divergent_text_why(kind) * ", and PostgreSQL rounds the quotient cast to an integer (`7.5` → `8`)"
      fix = "Divide as a float first, so SQLite keeps the fraction too, then say how to round it: " *
            "\e[32mCast(Round(x / 2.0), IntegerField())\e[0m reads the same integer on both engines."
    end
    return QueryBuildError(
      "\e[4m\e[31m$(fname)\e[0m cannot make the same integer from $(what) on both engines: $(why) (#1028). $(fix)")
  end
  why = kind === :bool ? "a boolean cast to text reads `true` on PostgreSQL and `1` on SQLite" : _divergent_text_why(kind)
  return QueryBuildError(
    "\e[4m\e[31m$(fname)\e[0m cannot make the same text from $(what) on both engines: $(why) (#1028). " *
    _divergent_text_fix(kind, flag))
end

# #1061 — `Round(x, d)` over text (`_scale_divergent_operand`'s `:text` kind: a text column or
# function, a string literal, a JSON value). Every number rounds through each engine's own `ROUND`,
# but text is no number to it: PostgreSQL's `::numeric` rejects `'abc'`, where SQLite reads it as 0
# and goes on. PormG does not read text as a number implicitly; a cast says it.
function _round_text_refusal(digits::Integer, what::AbstractString)
  return QueryBuildError(
    "\e[4m\e[31mRound(…, $(digits))\e[0m cannot round $(what): it is text, and PormG does not read " *
    "text as a number for you — PostgreSQL rejects text that is not a number and SQLite reads it as 0 " *
    "(#1061). If it holds numbers, say so with a cast, \e[32mRound(Cast(x, FloatField()), $(digits))\e[0m, " *
    "or fetch the value and round it in Julia.")
end

# Variadic convenience: Concat("forename", Value(" "), "surname") → same as vector form
Concat(args...; kwargs...) = Concat(collect(args); kwargs...)

# #878 — `Extract` and `ToChar` take the operand `_ScalarOperand` would, plus an already-split `__@`
# path (the transform ladder hands `YEAR`/`MONTH`/`DAY`/`Y_M` a `Vector{String}`). Named once for
# both, for the same reason: the subquery was missing from each spelled-out copy.
const _TemporalOperand = Union{AbstractString,SQLTypeField,SQLTypeFunction,SQLTypeF,SQLTypeCTE,
                               SQLTypeJoined,SubqueryObject,Vector{<:AbstractString}}

# #1070: what each date/time part reads, and the value a filter may hold it to. One row per thing the
# node COMPUTES, never per spelling: `"start_at__@hour"` builds `Extract("start_at", "HOUR")`, so the
# two get one rule. #955 keyed the check on a tag only the `__@` ladder stamped, which left the public
# `Extract` unchecked — `Extract(date, "HOUR")` answered `0` on SQLite where PostgreSQL refused it —
# and the range followed the constructor, so `@month => 13` matched nothing. Django is the prior art:
# `Extract.resolve_expression` checks the field type against the part, and `__hour` IS `ExtractHour`.
#
# `reads` is the operand kinds (`_temporal_kind`, `select_nodes.jl`); `what` the phrase the refusal
# uses; `formatter` checks a filter's value. The gate fails open on an operand PormG cannot type —
# see `_check_temporal_operand`. An interval reads only `EPOCH`: its hours on PostgreSQL are a
# component of the duration, while SQLite reads the stored text as a clock (#955).
const _TemporalRow = @NamedTuple{reads::Tuple{Vararg{Symbol}}, what::String, formatter::Function}
const _CALENDAR_READS = (reads = (:date, :datetime), what = "a calendar date")
const _CLOCK_READS = (reads = (:datetime, :time), what = "a time of day")
_temporal_row(r::NamedTuple, formatter::Function) = _TemporalRow((r.reads, r.what, formatter))

# Keyed by `Dialect.extract_part`'s canonical spelling. `test_transform_ladder_parity.jl` fails if a
# `Dialect.PG_EXTRACT_FIELDS` part has no row, so a new part cannot arrive unchecked.
const _EXTRACT_PART_ROWS = Dict{String,_TemporalRow}(
  "YEAR"            => _temporal_row(_CALENDAR_READS, Models.format_year_sql),
  "ISOYEAR"         => _temporal_row(_CALENDAR_READS, Models.format_number_sql),
  "MONTH"           => _temporal_row(_CALENDAR_READS, Models.format_month_sql),
  "DAY"             => _temporal_row(_CALENDAR_READS, Models.format_day_sql),
  "QUARTER"         => _temporal_row(_CALENDAR_READS, Models.format_quarter_sql),
  "WEEK"            => _temporal_row(_CALENDAR_READS, Models.format_week_sql),
  "ISODOW"          => _temporal_row(_CALENDAR_READS, Models.format_week_day_sql),
  "DOW"             => _temporal_row(_CALENDAR_READS, Models.format_dow_sql),
  "DOY"             => _temporal_row(_CALENDAR_READS, Models.format_doy_sql),
  "CENTURY"         => _temporal_row(_CALENDAR_READS, Models.format_number_sql),
  "DECADE"          => _temporal_row(_CALENDAR_READS, Models.format_number_sql),
  "MILLENNIUM"      => _temporal_row(_CALENDAR_READS, Models.format_number_sql),
  "JULIAN"          => _temporal_row(_CALENDAR_READS, Models.format_number_sql),
  "HOUR"            => _temporal_row(_CLOCK_READS, Models.format_hour_sql),
  "MINUTE"          => _temporal_row(_CLOCK_READS, Models.format_minute_sql),
  "SECOND"          => _temporal_row(_CLOCK_READS, Models.format_second_sql),
  "MILLISECONDS"    => _temporal_row(_CLOCK_READS, Models.format_number_sql),
  "MICROSECONDS"    => _temporal_row(_CLOCK_READS, Models.format_number_sql),
  # PostgreSQL has a zone only on a `timestamptz` (or a `timetz`, which no PormG field declares).
  "TIMEZONE"        => _TemporalRow(((:timestamptz,), "a timestamp with a time zone", Models.format_number_sql)),
  "TIMEZONE_HOUR"   => _TemporalRow(((:timestamptz,), "a timestamp with a time zone", Models.format_number_sql)),
  "TIMEZONE_MINUTE" => _TemporalRow(((:timestamptz,), "a timestamp with a time zone", Models.format_number_sql)),
  # Seconds since the epoch, since midnight, or in the duration: every temporal kind has one.
  "EPOCH"           => _TemporalRow(((:date, :datetime, :time, :interval),
                                     "a date, a time or a duration", Models.format_number_sql)),
)

# The date nodes that are not `EXTRACT` fields, keyed by `function_name` (`week_day` is 1 = Sunday,
# which neither engine has as a field; `@date`, `@quarter`, `@quadrimester` render per engine).
const _TEMPORAL_FUNCTION_ROWS = Dict{String,_TemporalRow}(
  "WEEK_DAY"     => _temporal_row(_CALENDAR_READS, Models.format_week_day_sql),
  "QUARTER"      => _temporal_row(_CALENDAR_READS, Models.format_quarter_sql),
  "QUADRIMESTER" => _temporal_row(_CALENDAR_READS, Models.format_quadrimester_sql),
  "DATE"         => _temporal_row(_CALENDAR_READS, Models.format_date_sql),
)

# The row a node is checked against, and the name its messages use for it — the part, lower-cased as
# a caller writes it (`hour`, `isodow`), or the node's own name. `nothing` for a node that is no date
# part. `ToChar` is checked only for the `"YYYY-MM"` mask `@yyyy_mm` builds: `to_char` also formats a
# number on PostgreSQL, so an arbitrary mask says nothing about its operand's type.
function _temporal_row_of(v::FObject)
  name = v.function_name
  if name == "EXTRACT"
    up = Dialect.extract_part(v.kwargs["part"])
    return _EXTRACT_PART_ROWS[up], lowercase(up)
  elseif name == "EXTRACT_DATE"
    get(v.kwargs, "format", nothing) == "YYYY-MM" || return nothing
    return _temporal_row(_CALENDAR_READS, Models.format_yyyy_mm), "yyyy_mm"
  end
  row = get(_TEMPORAL_FUNCTION_ROWS, name, nothing)
  return row === nothing ? nothing : (row, lowercase(name))
end
_temporal_row_of(::Any) = nothing

"""
    Extract(column, part)

Extracts a component (`"year"`, `"month"`, `"dow"`, …) from a date/time column.

`part` is case-insensitive and must be a PostgreSQL `EXTRACT` field: `CENTURY`, `DAY`, `DECADE`,
`DOW`, `DOY`, `EPOCH`, `HOUR`, `ISODOW`, `ISOYEAR`, `JULIAN`, `MICROSECONDS`, `MILLENNIUM`,
`MILLISECONDS`, `MINUTE`, `MONTH`, `QUARTER`, `SECOND`, `TIMEZONE`, `TIMEZONE_HOUR`,
`TIMEZONE_MINUTE`, `WEEK`, `YEAR`. Anything else — PostgreSQL's synonyms such as `"years"` or
`"hr"` included — raises `InvalidValueError` when the expression is built, on both engines.
SQLite runs `YEAR` `MONTH` `DAY` `HOUR` `MINUTE` `SECOND` `DOW` `DOY` `WEEK` `ISOYEAR` `ISODOW`,
numbered as PostgreSQL numbers them, and raises `BackendCapabilityError` for the rest.

The part must be one the column holds, checked against the field the column is declared as when
the query is built, on both engines (#1070). It raises `QueryBuildError` otherwise:

- the time-of-day parts (`HOUR`, `MINUTE`, `SECOND`, `MILLISECONDS`, `MICROSECONDS`) read a
  `DateTimeField` or a `TimeField`;
- the `TIMEZONE` parts read a `DateTimeField` with a time zone (the default `TIMESTAMPTZ`);
- `EPOCH` reads any of those, a `DateField` or a `DurationField`;
- every other part reads a `DateField` or a `DateTimeField`.

The `"col__@hour"` transforms are this function, so they follow the same rule. A column PormG
cannot name a field for — an expression, a subquery, an untyped CTE column — is not checked.

A filter on the result is held to the part's range: `HOUR` 0–23, `MINUTE` and `SECOND` 0–59,
`MONTH` 1–12, `DAY` 1–31, `QUARTER` 1–4, `WEEK` 1–53, `ISODOW` 1–7, `DOW` 0–6, `DOY` 1–366. A
value outside it raises `InvalidValueError` rather than matching nothing.

To change the result type, wrap it in [`Cast`](@ref) — e.g. on PostgreSQL,
`Cast(Extract("date", "epoch"), "bigint")`.
"""
function Extract(x::_TemporalOperand, part::AbstractString; formatter::Union{Nothing, Function, PormGField} = nothing)
  isa(formatter, PormGField) && (formatter = formatter.formatter)
  # #691: refuse an unknown part at build time on both engines. The node keeps the caller's
  # spelling — the dialect renders the canonical one — so the `"YEAR"` range rewrite in
  # `filter_operators.jl` sees exactly what it saw before.
  up = Dialect.extract_part(part)
  # #1070: a filter's value is checked against the part's range whoever built the node — the `__@`
  # ladder is this call. An explicit `formatter=` still wins.
  formatter === nothing && (formatter = _EXTRACT_PART_ROWS[up].formatter)
  return FObject(function_name = "EXTRACT", column = _norm_fn_arg(x), aggregate = _any_agg(x), formatter = formatter, kwargs = Dict{String, Any}("part" => String(part)))
end
_result_rule(::Val{:EXTRACT}) = :unknown   # an integer on SQLite; PostgreSQL's `extract` type is not stated here yet
# Build a WHEN fragment. When `otherwise` is provided, wrap it in a CASE automatically so
# When(..., otherwise=x) is a complete standalone expression. When used inside Case([...]),
# `otherwise` is always missing (the default) so no wrapping occurs — Case owns the ELSE branch.
function _make_when(column, then, otherwise)
  fobj = FObject(function_name = "WHEN", column = column, aggregate = _any_agg(column, then), kwargs = Dict{String, Any}("then" => then, "else" => missing))
  ismissing(otherwise) && return fobj
  return FObject(function_name = "CASE", column = fobj, aggregate = _any_agg(fobj, otherwise), kwargs = Dict{String, Any}("else" => otherwise, "output_field" => nothing))
end

"""
    When(condition; then = 0, otherwise = missing)

One `WHEN condition THEN value` branch of a SQL `CASE`.

`condition` accepts five forms:

- a lookup pair — `When("points__@gt" => 10, then = 1)`
- a tuple of pairs, ANDed together — `When(("points__@gt" => 10, "grid" => 1), then = 1)`
- a `Q(...)` / `Qor(...)` object, for OR and nested boolean logic
- a comparison over an `F`, function or window expression —
  `When(F("grid") < F("positionorder"), then = 1)`, `When(Lower("surname") == "senna", then = 1)`.
  It renders exactly as the same expression wrapped in `Q(...)`. An arithmetic or bitwise
  expression is a value, not a condition, so `When(F("laps") + 1)` raises `QueryBuildError`:
  compare it, as in `When((F("laps") + 1) > 0)` (#931). A bare boolean column, `When(F("is_active"))`,
  is a condition.
- a function whose result is boolean — `When(Cast("grid", "boolean"), then = 1)`, a
  `Coalesce`/`Case` with `output_field = "boolean"`, `When(Coalesce(F("is_active"), false))` over a
  `BooleanField`. A function whose result is known not to be boolean (`Lower`, `Length`, `Sum`,
  `Rank`, a `Cast` to a non-boolean type, a `Coalesce` over a number column) raises
  `QueryBuildError`: compare it, as in `When(Lower("surname") == "senna")` (#942). A function whose
  type cannot be named (`Lag` over a column, a `Case` with no `output_field`) is not checked.

`then` defaults to `0`. A plain value in `then` or the `CASE` `ELSE` is bound as a query
parameter; a column expression — `F("points")`, `F("points") * 2`, `Joined(…)`, a function —
renders as SQL, so `When("positionorder" => 1, then = F("points"))` returns that row's points.
`then = missing` renders as SQL `NULL`. (`otherwise = missing` is the default and means *no*
`ELSE` of this branch's own — see the tip below.)

!!! tip "`otherwise` makes `When` standalone"
    Passing `otherwise` wraps the branch in a complete `CASE … ELSE … END`, so a two-way
    conditional needs no [`Case`](@ref) at all:

    ```julia
    # Points scored, or 0 for a non-points finish — one call, no Case needed.
    "scored" => When("points__@gt" => 0, then = 1, otherwise = 0)
    ```

    Inside `Case([...])`, leave `otherwise` unset — `Case` owns the `ELSE` branch. Outside one, a
    `When` with no `otherwise` raises `QueryBuildError` wherever it stands as a value (a projection,
    an aggregate's operand such as `Count(When(…))`, a function argument), because alone it renders
    `WHEN … THEN …` with no `ELSE` and no `END`, which no engine parses (#964).

See also [`Case`](@ref), [Functions and Dates](@ref).
"""
function When(x::NTuple{N, <:Pair}; then::Any = 0, otherwise::Any = missing) where N
  return When(Q(x), then = then, otherwise = otherwise)
end
_result_rule(::Val{:WHEN}) = :unknown   # a branch of a `Case`, never a value of its own
# #444: a CASE branch keyed on a CTE column. `When` dispatches on the Pair's KEY TYPE, so this is a
# new method rather than a widened union — and it is the one function in the family with no
# alternative spelling, since a CASE over a CTE column cannot be written any other way.
function When(x::Pair{CTEReference, T}; then::Any = 0, otherwise::Any = missing) where T
  return When(_check_filter(x); then = then, otherwise = otherwise)
end
# #481: the same for a joined-copy column, for the same dispatch-on-key-type reason.
function When(x::Pair{JoinedReference, T}; then::Any = 0, otherwise::Any = missing) where T
  return When(_check_filter(x); then = then, otherwise = otherwise)
end
# #811: through `_check_filter`, like the two methods above. Calling `_get_pair_to_oper` on the raw
# pair skipped the `__@` split, and only the split form has the column-expression arms:
# `When("points__@gt" => F("grid"))` was a `MethodError`, while `Q` around the same pair worked.
function When(x::Pair{String, T}; then::Any = 0, otherwise::Any = missing) where T
  return _make_when(_check_filter(x), then, otherwise)
end
function When(x::Union{SQLTypeQ, SQLTypeQor}; then::Any = 0, otherwise::Any = missing)
  return _make_when(x, then, otherwise)
end
function When(x::SQLTypeOper; then::Any = 0, otherwise::Any = missing)
  return _make_when(x, then, otherwise)
end
# #942: a function is a condition only when its result is boolean. One whose name or declared type
# already says otherwise (`Lower`, `Length`, `Sum`, a `Cast` to integer) is refused here; one typed by
# its operands (`Coalesce`, `Max`) is checked at render, where the columns are known.
function When(x::SQLTypeFunction; then::Any = 0, otherwise::Any = missing)
  _function_condition_kind(x) === :non_boolean && throw(_non_boolean_function_condition(x))
  return _make_when(x, then, otherwise)
end
# #921: an `F` comparison — and since #895 a function or window comparison, which builds the same node —
# had no arm and raised a raw `MethodError`, though the docstring above already promised it. Django's
# `When` takes a boolean expression the same way. Delegating to `Q` is deliberate: it runs the
# `_check_filter_node` walk (transforms inside the expression resolve) and renders byte-for-byte what
# the documented `When(Q(expr))` workaround rendered, so the two spellings cannot drift apart.
function When(x::FExpression; then::Any = 0, otherwise::Any = missing)
  return When(Q(x); then = then, otherwise = otherwise)
end
"""
    Case(conditions; default = "NULL", output_field = nothing)

A SQL `CASE … END` expression: evaluate each [`When`](@ref) branch in order and return the
first match.

# Arguments
- `conditions`: a `Vector` of `When` branches, or a single bare `When`.
- `default`: the `ELSE` branch. Defaults to the **string** `"NULL"`, which is emitted as the
  SQL literal `NULL` — it is not a bound parameter, so pass a Julia value (`0`, `""`) when
  you want a real default. `missing` is emitted as `NULL` too, and a column expression
  (`F("grid")`) renders as that column.
- `output_field`: the result type. Accepts a `PormGField` instance (e.g. `CharField()`, whose
  `.type` is used) or a raw SQL type string. Renders as a `::type` cast on PostgreSQL and a
  `CAST(...)` on SQLite — `date(...)` for a date, and a time type raises `BackendCapabilityError`
  there (#822). In a CTE body it is also the column's type; without it the type is
  inferred from the branches, and branches that do not agree raise `QueryBuildError` — see
  [How a CTE Column Is Typed](@ref).

Usable anywhere a column expression is — in `values()`, nested inside [`Sum`](@ref), as a
filter right-hand side, and in `.update()`.

```julia
using PormG.Functions: Case, When
using PormG.Models: CharField          # field types are not part of PormG.Functions

"podium" => Case([
    When("positionorder" => 1, then = "win"),
    When("positionorder__@lte" => 3, then = "podium"),
], default = "none", output_field = CharField())
```

See also [`When`](@ref), [Functions and Dates](@ref).
"""
function Case(conditions::Vector{N} where N <: SQLTypeFunction; default::Any = "NULL", output_field::Union{N, AbstractString, Nothing} where N <: PormGField = nothing)
  output_field = _output_field_type(output_field)   # #603, #696
  return FObject(function_name = "CASE", column = conditions, aggregate = _any_agg(conditions, default), kwargs = Dict{String, Any}("else" => default, "output_field" => output_field))
end
_result_rule(::Val{:CASE}) = :declared   # its `output_field`; without one, a branch's value
function Case(conditions::SQLTypeFunction; default::Any = "NULL", output_field::Union{N, AbstractString, Nothing} where N <: PormGField = nothing)
  output_field = _output_field_type(output_field)   # #603, #696
  return FObject(function_name = "CASE", column = conditions, aggregate = _any_agg(conditions, default), kwargs = Dict{String, Any}("else" => default, "output_field" => output_field))
end
"""
    ToChar(x, format::AbstractString; formatter = nothing)

Format a date/time column as text — PostgreSQL `to_char(x, format)`, SQLite `strftime`.

# Arguments
- `x`: a field path, `F` expression, function object, or a vector of field paths.
- `format`: one of the portable formats below, e.g. `"YYYY-MM"`, `"YYYY-MM-DD"`, `"YYYY"`.
- `formatter`: an optional Julia-side hook applied to the returned values. Accepts a
  `Function`, or a `PormGField` whose `.formatter` is used.

# Portable formats

Each format renders the **same text on both engines** for a given instant — PormG spells it for
each engine itself (`HH` is the 24-hour clock on both; the `T` separator and the `.SSS`
milliseconds render as written). The full list:

| `format` | renders as |
|---|---|
| `"YYYY"`, `"MM"`, `"DD"`, `"HH"`, `"MI"`, `"SS"` | one component: `2009`, `03`, `29`, `06`, `00`, `00` |
| `"YYYY-MM"`, `"YYYY-MM-DD"` | `2009-03`, `2009-03-29` |
| `"DD/MM/YYYY"`, `"DD-MM-YYYY"` | `29/03/2009`, `29-03-2009` |
| `"HH:MI"`, `"HH:MI:SS"`, `"HH:MI:SS.SSS"` | `06:00`, `06:00:00`, `06:00:00.000` |
| `"YYYY-MM-DD HH:MI:SS"`, `"YYYY-MM-DD HH:MI:SS.SSS"` | `2009-03-29 06:00:00`, `2009-03-29 06:00:00.000` |
| `"YYYY-MM-DDTHH:MI:SS"`, `"YYYY-MM-DDTHH:MI:SS.SSS"` | `2009-03-29T06:00:00`, `2009-03-29T06:00:00.000` |

!!! warning "Any other format is PostgreSQL-only"
    A format outside that table is passed to `to_char` as written (so a native template such as
    `"HH12:MI AM"` works on PostgreSQL), and raises `BackendCapabilityError` on SQLite, naming
    the supported formats — `strftime` cannot spell an arbitrary `to_char` template.

!!! note "Time zone"
    On PostgreSQL `to_char` renders a `timestamptz` in the session time zone; on SQLite the stored
    text is UTC. Keep the session in UTC for the two engines to agree on the hour.

```julia
using PormG.Functions: ToChar, Count

# Races per month
query.values("month" => ToChar("date", "YYYY-MM"), "n" => Count("raceid"))

# A race start as the canonical timestamp text, identical on both engines
query.values("start" => ToChar("start_at", "YYYY-MM-DDTHH:MI:SS.SSS"))
```

Named `ToChar` since `0.3.0` (previously `To_char`, with a `formater` keyword).

See also [Functions and Dates](@ref).
"""
function ToChar(x::_TemporalOperand, format::AbstractString; formatter::Union{Nothing, Function, PormGField} = nothing)
  isa(formatter, PormGField) && (formatter = formatter.formatter)
  # #1070: the one mask with a row (`_temporal_row_of`) checks a filter's value as `@yyyy_mm` does —
  # `@yyyy_mm` is this call. Any other mask is free text. An explicit `formatter=` still wins.
  formatter === nothing && format == "YYYY-MM" && (formatter = Models.format_yyyy_mm)
  return FObject(function_name = "EXTRACT_DATE", column = _norm_fn_arg(x), aggregate = _any_agg(x), formatter = formatter, kwargs = Dict{String, Any}("format" => String(format)))
end
_result_rule(::Val{:EXTRACT_DATE}) = CText()


"""
    Coalesce(args...; output_field=nothing)

Returns the first non-null value in the list of arguments. It takes two or more arguments: fewer raise
`QueryBuildError` when the expression is built (#859), since one argument is the argument itself.

A string argument is a column path. A number, a `Bool`, or a `Date`/`DateTime`/`ZonedDateTime`/`Time`
is a literal that is bound as a parameter
(`Coalesce("points", 0)` means `Coalesce("points", Value(0))`). Wrap a string literal in `Value`. Any other value raises `QueryBuildError`
when the expression is built (#705).

The value reads back as the column's own Julia type on both engines when every argument is of one
type — `Coalesce("date", "fp1_date")` is a `Date`, not SQLite's stored text. When the argument types
differ, the value comes back as the engine delivers it (#824): on SQLite, the stored value of the
argument that won.

`output_field` casts the result to the type it names, on both engines (#852):
`Coalesce("number", 0; output_field = "integer")` renders `(…)::integer` on PostgreSQL and `CAST(… AS INTEGER)` on SQLite, so the value,
a filter on it, and a CTE column typed by it all agree. On SQLite a `date` renders `date(…)`, and the
other temporal types and arrays raise `BackendCapabilityError`, as for [`Cast`](@ref). A text or
integer `output_field` refuses the operands [`Cast`](@ref) refuses (#1028): over a float, round first
(`Floor("points")`). So does a scaled `numeric(p, s)` one (#1040).
"""
function Coalesce(x...; output_field::Union{N, AbstractString, Nothing} where N <: PormGField = nothing)
  output_field = _output_field_type(output_field)   # #603, #696
  _check_operand_count("Coalesce", x)   # #859
  processed_cols = Any[_function_operand(v) for v in x]   # #705
  return FObject(function_name = "COALESCE", column = processed_cols, aggregate = _any_agg(processed_cols), kwargs = Dict{String, Any}("output_field" => output_field))
end
_result_rule(::Val{:COALESCE}) = :one_of

"""
    Greatest(args...; output_field=nothing)

Returns the greatest value in the list of arguments. It takes two or more arguments: fewer raise
`QueryBuildError` when the expression is built (#859), since one argument is the argument itself.

A string argument is a column path. A number, a `Bool`, or a `Date`/`DateTime`/`ZonedDateTime`/`Time`
is a literal that is bound as a parameter
(`Greatest("points", 0)` means `Greatest("points", Value(0))`). Wrap a string literal in `Value`. Any other value raises `QueryBuildError`
when the expression is built (#705).

The value reads back as the column's own Julia type on both engines when every argument is of one
type — `Greatest("date", "fp1_date")` is a `Date`, not SQLite's stored text. When the argument types
differ, the value comes back as the engine delivers it (#824): on SQLite, the stored value of the
argument that won.

`output_field` casts the result to the type it names, on both engines (#852):
`Greatest("grid", 1; output_field = "integer")` renders `(…)::integer` on PostgreSQL and `CAST(… AS INTEGER)` on SQLite, so the value,
a filter on it, and a CTE column typed by it all agree. On SQLite a `date` renders `date(…)`, and the
other temporal types and arrays raise `BackendCapabilityError`, as for [`Cast`](@ref). A text or
integer `output_field` refuses the operands [`Cast`](@ref) refuses (#1028): over a float, round first
(`Floor("points")`). So does a scaled `numeric(p, s)` one (#1040).
"""
function Greatest(x...; output_field::Union{N, AbstractString, Nothing} where N <: PormGField = nothing)
  output_field = _output_field_type(output_field)   # #603, #696
  _check_operand_count("Greatest", x)   # #859
  processed_cols = Any[_function_operand(v) for v in x]   # #705
  return FObject(function_name = "GREATEST", column = processed_cols, aggregate = _any_agg(processed_cols), kwargs = Dict{String, Any}("output_field" => output_field))
end
_result_rule(::Val{:GREATEST}) = :one_of

"""
    Least(args...; output_field=nothing)

Returns the least value in the list of arguments. It takes two or more arguments: fewer raise
`QueryBuildError` when the expression is built (#859), since one argument is the argument itself.

A string argument is a column path. A number, a `Bool`, or a `Date`/`DateTime`/`ZonedDateTime`/`Time`
is a literal that is bound as a parameter
(`Least("points", 25)` means `Least("points", Value(25))`). Wrap a string literal in `Value`. Any other value raises `QueryBuildError`
when the expression is built (#705).

The value reads back as the column's own Julia type on both engines when every argument is of one
type — `Least("date", "fp1_date")` is a `Date`, not SQLite's stored text. When the argument types
differ, the value comes back as the engine delivers it (#824): on SQLite, the stored value of the
argument that won.

`output_field` casts the result to the type it names, on both engines (#852):
`Least("grid", 25; output_field = "integer")` renders `(…)::integer` on PostgreSQL and `CAST(… AS INTEGER)` on SQLite, so the value,
a filter on it, and a CTE column typed by it all agree. On SQLite a `date` renders `date(…)`, and the
other temporal types and arrays raise `BackendCapabilityError`, as for [`Cast`](@ref). A text or
integer `output_field` refuses the operands [`Cast`](@ref) refuses (#1028): over a float, round first
(`Floor("points")`). So does a scaled `numeric(p, s)` one (#1040).
"""
function Least(x...; output_field::Union{N, AbstractString, Nothing} where N <: PormGField = nothing)
  output_field = _output_field_type(output_field)   # #603, #696
  _check_operand_count("Least", x)   # #859
  processed_cols = Any[_function_operand(v) for v in x]   # #705
  return FObject(function_name = "LEAST", column = processed_cols, aggregate = _any_agg(processed_cols), kwargs = Dict{String, Any}("output_field" => output_field))
end
_result_rule(::Val{:LEAST}) = :one_of



"""
    Lower(column)

Converts a string to lowercase.
"""
function Lower(x::_ScalarOperand)
  return FObject(function_name = "LOWER", column = _norm_fn_arg(x), aggregate = _any_agg(x))
end
_result_rule(::Val{:LOWER}) = CText()

"""
    Upper(column)

Converts a string to uppercase.
"""
function Upper(x::_ScalarOperand)
  return FObject(function_name = "UPPER", column = _norm_fn_arg(x), aggregate = _any_agg(x))
end
_result_rule(::Val{:UPPER}) = CText()

"""
    Length(column)

Returns the length of a string.
"""
function Length(x::_ScalarOperand)
  return FObject(function_name = "LENGTH", column = _norm_fn_arg(x), aggregate = _any_agg(x), formatter = Models.format_number_sql)
end
_result_rule(::Val{:LENGTH}) = CInt32()   # `integer` on PostgreSQL

"""
    Abs(column)

Returns the absolute value of a number.
"""
function Abs(x::_ScalarOperand)
  return FObject(function_name = "ABS", column = _norm_fn_arg(x), aggregate = _any_agg(x), formatter = Models.format_number_sql)
end
_result_rule(::Val{:ABS}) = :promoting
# #1147: over a whole number PostgreSQL renders `ABS(x)` with no `::numeric` cast (`Dialect.ABS`,
# `_whole_operand_function`), and `abs` keeps an integer's own type; any other operand is cast, so the
# value is a `numeric`. An operand of no kind may be either, so it states none.
_computed_kind(::Val{:ABS}, ::Symbol, k::Union{CInt16,CInt32,CInt64}, ::PormGPostgres) = k
_computed_kind(::Val{:ABS}, ::Symbol, ::Nothing, ::PormGPostgres) = nothing

"""
    Round(column, precision=0)

Rounds a number to `precision` decimal places, half away from zero.

Each engine rounds with its own `ROUND`, as Django's `Round` does: PostgreSQL renders
`ROUND(x::numeric, d)`, which rounds the value's exact decimal form (a `DecimalField` keeps its
`Decimal`), and SQLite `ROUND(x, d)`, which rounds the stored double. The two agree except at a
decimal tie whose double sits just below it: `Round(2.675, 2)` is `2.68` on PostgreSQL and `2.67` on
SQLite. PostgreSQL's is the exact answer; on SQLite, a development engine for PormG, the last digit of
such a tie can differ (#1061). `Round(x)` (no places) gives the same whole number on both.

Text is not a number to round: `Round(x, d)` over a text column, a string or a JSON value raises
`QueryBuildError` when the query is built, because PostgreSQL rejects text that is not a number and
SQLite reads it as 0. Cast it first: `Round(Cast(x, FloatField()), d)`.

A negative `precision` raises `InvalidValueError` when the expression is built: PostgreSQL rounds
`Round(125, -1)` to `130` and SQLite takes a negative precision as 0.
"""
function Round(x::_ScalarOperand, precision::Integer = 0)
  # #1044: SQLite reads a negative precision as 0, PostgreSQL rounds to tens, hundreds, … — an
  # integer operand diverges too, so it is refused before any operand is typed.
  precision < 0 && throw(InvalidValueError(
    "\e[31mRound(…, $(precision))\e[0m: SQLite takes a negative precision as 0 (`Round(125, -1)` is " *
    "`125.0`) and PostgreSQL rounds to it (`130`), so the two engines disagree (#1044). Fetch the value " *
    "and round it in Julia: \e[32mround(x, RoundNearestTiesAway; digits = $(precision))\e[0m.", :range))
  return FObject(function_name = "ROUND", column = _norm_fn_arg(x), aggregate = _any_agg(x), kwargs = Dict{String, Any}("precision" => precision), formatter = Models.format_number_sql)
end
_result_rule(::Val{:ROUND}) = :numeric

"""
    NullIf(field1, field2)

Returns NULL if field1 equals field2, otherwise returns field1.

A string argument is a column path. A number, a `Bool`, or a `Date`/`DateTime`/`ZonedDateTime`/`Time`
is a literal that is bound as a parameter
(`NullIf("points", 0)` means `NullIf("points", Value(0))`). Wrap a string literal in `Value`. Any other value raises `QueryBuildError`
when the expression is built (#705).

`NullIf("code", "")` compares two columns; write `NullIf("code", Value(""))` for the empty string.

The value is `field1`'s, so it reads back as `field1`'s own Julia type on both engines: `NullIf("date",
"fp1_date")` is a `Date`, not SQLite's stored text (#824).
"""
function NullIf(x, y)
  column = Any[_function_operand(x), _function_operand(y)]   # #705
  return FObject(function_name = "NULLIF", column = column, aggregate = _any_agg(column))
end
_result_rule(::Val{:NULLIF}) = :first_operand


"""
    Replace(column, find, replace)

Replaces all occurrences of `find` with `replace` in the string.

`column` is a column path. `find` and `replace` are text: a string there is a literal, and a number
raises `QueryBuildError` naming its string spelling (#705).
"""
function Replace(x, find, replace)
  # #705: `find`/`replace` are text, so a string there is a literal (`_text_operand`).
  does = "\e[4m\e[31mReplace\e[0m searches and replaces TEXT"
  column = Any[_function_operand(x), _text_operand(find, does), _text_operand(replace, does)]
  return FObject(function_name = "REPLACE", column = column, aggregate = _any_agg(column))
end
_result_rule(::Val{:REPLACE}) = CText()

"""
    Trim(column)

Removes leading and trailing whitespace from a string.
"""
function Trim(x::_ScalarOperand)
  return FObject(function_name = "TRIM", column = _norm_fn_arg(x), aggregate = _any_agg(x))
end
_result_rule(::Val{:TRIM}) = CText()

"""
    LTrim(column)

Removes leading whitespace from a string.
"""
function LTrim(x::_ScalarOperand)
  return FObject(function_name = "LTRIM", column = _norm_fn_arg(x), aggregate = _any_agg(x))
end
_result_rule(::Val{:LTRIM}) = CText()

"""
    RTrim(column)

Removes trailing whitespace from a string.
"""
function RTrim(x::_ScalarOperand)
  return FObject(function_name = "RTRIM", column = _norm_fn_arg(x), aggregate = _any_agg(x))
end
_result_rule(::Val{:RTRIM}) = CText()

# #122 — `LPad`/`RPad`. All three arguments stay in `column`, in text order, so the two bound
# parameters (`len`, then a literal `fill`) are numbered as they are written — a kwarg binds after
# every operand (Phase 3 in `_render_function_body`), which would put `len` behind `fill`. `len` is
# checked here because a negative width is never meant (Django refuses it too; PostgreSQL returns
# `''`), and one past `_PAD_MAX_LEN` fails on PostgreSQL while the SQLite function would allocate it.
# A `Bool` is an `Integer` to Julia, and never a width.
#
# `_PAD_MAX_LEN`: PostgreSQL sizes the result for the encoding's widest character before padding, so
# in a UTF-8 database (4 bytes) any length from 268435455 up is "requested length too large" — the
# 1 GB allocation limit. Measured on PostgreSQL 16, which refuses 268435455 and `typemax(Int32)` alike.
const _PAD_MAX_LEN = 268_435_454
function _pad_function(name::String, x, len::Integer, fill)
  label = name == "LPAD" ? "LPad" : "RPad"
  (len isa Bool || !(0 <= len <= _PAD_MAX_LEN)) && throw(InvalidValueError(
    "\e[31m$(label)(…, $(len), …)\e[0m: the length is a number of characters from 0 to " *
    "$(_PAD_MAX_LEN), PostgreSQL's limit in a UTF-8 database (#122).", :range))
  does = "\e[4m\e[31m$(label)\e[0m pads with TEXT"
  column = Any[_function_operand(x), Value(len), _text_operand(fill, does)]
  return FObject(function_name = name, column = column, aggregate = _any_agg(column))
end

"""
    LPad(column, len, fill = " ")

Pads a string on the left with `fill` until it is `len` characters long — `LPad(Cast("number",
"text"), 3, "0")` turns `44` into `"044"`. A string longer than `len` is cut to its first `len`
characters, a `fill` of several characters repeats and is cut where the length is reached
(`LPad("code", 6, "xy")` over `"HAM"` is `"xyxHAM"`), an empty `fill` pads nothing, and a NULL
string is NULL. The same on PostgreSQL (`LPAD`) and SQLite, which has no `LPAD` and calls a
function PormG registers on every connection it opens (`pormg_lpad`).

`column` is a column path or an expression, and it must be text: PostgreSQL has no `lpad` over a
number, a date, a time, a boolean, a uuid or a JSON document, so such a column raises
`QueryBuildError` when the query is built, on both engines. Convert it to text first — an integer, a
date, a time or a uuid with [`Cast`](@ref) (`Cast(x, "text")`), a timestamp with [`ToChar`](@ref).
`fill` is text too: a string there is a literal, and a number, a date or a boolean (a literal or a
column) raises `QueryBuildError`. A `len` below 0 or above 268435454 (PostgreSQL's limit in a UTF-8
database) raises `InvalidValueError`.

Zero-filling an integer column into a text column, in one statement:

```julia
M.Driver.objects.
    filter("number__@isnull" => false).
    update("code" => LPad(Cast("number", "text"), 3, "0"))
```
"""
LPad(x, len::Integer, fill = " ") = _pad_function("LPAD", x, len, fill)
_result_rule(::Val{:LPAD}) = CText()

"""
    RPad(column, len, fill = " ")

Pads a string on the right with `fill` until it is `len` characters long — `RPad("code", 5, ".")`
turns `"HAM"` into `"HAM.."`. Like [`LPad`](@ref), a longer string is cut to its first `len`
characters, a `fill` of several characters repeats and is cut, an empty `fill` pads nothing, and a
NULL string is NULL, on PostgreSQL (`RPAD`) and SQLite (`pormg_rpad`) alike.

`column` and `fill` must be text, as for [`LPad`](@ref): anything else raises `QueryBuildError` when
the query is built, and a `len` below 0 or above 268435454 raises `InvalidValueError`.
"""
RPad(x, len::Integer, fill = " ") = _pad_function("RPAD", x, len, fill)
_result_rule(::Val{:RPAD}) = CText()

"""
    Floor(column)

Returns the largest integer less than or equal to a number.
"""
function Floor(x::_ScalarOperand)
  return FObject(function_name = "FLOOR", column = _norm_fn_arg(x), aggregate = _any_agg(x), formatter = Models.format_number_sql)
end
_result_rule(::Val{:FLOOR}) = :promoting
# #1147: over a whole number it is that number, rendered with no cast, so its own type (see `Abs`).
_computed_kind(::Val{:FLOOR}, ::Symbol, k::Union{CInt16,CInt32,CInt64}, ::PormGPostgres) = k
_computed_kind(::Val{:FLOOR}, ::Symbol, ::Nothing, ::PormGPostgres) = nothing

"""
    Ceil(column)

Returns the smallest integer greater than or equal to a number.
"""
function Ceil(x::_ScalarOperand)
  return FObject(function_name = "CEIL", column = _norm_fn_arg(x), aggregate = _any_agg(x), formatter = Models.format_number_sql)
end
_result_rule(::Val{:CEIL}) = :promoting
# #1147: over a whole number it is that number, rendered with no cast, so its own type (see `Abs`).
_computed_kind(::Val{:CEIL}, ::Symbol, k::Union{CInt16,CInt32,CInt64}, ::PormGPostgres) = k
_computed_kind(::Val{:CEIL}, ::Symbol, ::Nothing, ::PormGPostgres) = nothing



"""
    Sqrt(column)

Returns the square root of a number.
"""
function Sqrt(x::_ScalarOperand)
  return FObject(function_name = "SQRT", column = _norm_fn_arg(x), aggregate = _any_agg(x), formatter = Models.format_number_sql)
end
_result_rule(::Val{:SQRT}) = :numeric

"""
    Exp(column)

Returns the exponential value (e^x) of a number.
"""
function Exp(x::_ScalarOperand)
  return FObject(function_name = "EXP", column = _norm_fn_arg(x), aggregate = _any_agg(x), formatter = Models.format_number_sql)
end
_result_rule(::Val{:EXP}) = :numeric

"""
    Ln(column)

Returns the natural logarithm of a number.
"""
function Ln(x::_ScalarOperand)
  return FObject(function_name = "LN", column = _norm_fn_arg(x), aggregate = _any_agg(x), formatter = Models.format_number_sql)
end
_result_rule(::Val{:LN}) = :numeric

"""
    Power(base, exponent)

Returns `base` raised to the power of `exponent`.

A string argument is a column path. A number, a `Bool`, or a `Date`/`DateTime`/`ZonedDateTime`/`Time`
is a literal that is bound as a parameter
(`Power("points", 2)` means `Power("points", Value(2))`). Wrap a string literal in `Value`. Any other value raises `QueryBuildError`
when the expression is built (#705).
"""
function Power(x, y)
  column = Any[_function_operand(x), _function_operand(y)]   # #705
  return FObject(function_name = "POWER", column = column, aggregate = _any_agg(column), formatter = Models.format_number_sql)
end
_result_rule(::Val{:POWER}) = :numeric

"""
    Mod(dividend, divisor)

Returns the remainder (modulo) of a division.

A string argument is a column path. A number, a `Bool`, or a `Date`/`DateTime`/`ZonedDateTime`/`Time`
is a literal that is bound as a parameter
(`Mod("points", 2)` means `Mod("points", Value(2))`). Wrap a string literal in `Value`. Any other value raises `QueryBuildError`
when the expression is built (#705).
"""
function Mod(x, y)
  column = Any[_function_operand(x), _function_operand(y)]   # #705
  return FObject(function_name = "MOD", column = column, aggregate = _any_agg(column), formatter = Models.format_number_sql)
end
_result_rule(::Val{:MOD}) = :numeric

# ──────────────────────────────────────────────────────────────────────────────
# #31: PostgreSQL full-text search, after `django.contrib.postgres.search`. Four `FObject`s, rendered by
# `Dialect.SEARCH_*`; every one raises `BackendCapabilityError` on SQLite when the query is built.
#
# A `SearchVector` and a `SearchQuery` are OPERANDS — of the `@search` lookup, `SearchRank` and
# `SearchHeadline` — never values: projecting a tsvector or a tsquery, or comparing one, is refused
# (`_render_function_typed`, select_nodes.jl), because neither has a Julia reading yet. The three
# consumers render them through `_render_fts_operand`, past that refusal.
#
# The config is a validated literal (`Dialect.ts_config_name`, and the maintainer's call on #31); the
# search text is always bound. Where one side is written as a bare string, it takes its config from
# the side written as an object: `"surname__@search" => SearchQuery("senna"; config = "simple")`
# parses the column with `simple` too, and so does a string query given to `SearchRank`.
# ──────────────────────────────────────────────────────────────────────────────
const _FTS_OPERANDS = ("SEARCH_VECTOR", "SEARCH_QUERY")
_is_fts_node(x, name::AbstractString) = x isa FObject && x.function_name == name
_is_fts_operand(x) = x isa FObject && x.function_name in _FTS_OPERANDS

const _SEARCH_TYPES = ("plain", "phrase", "websearch", "raw")

"""
    SearchQuery(text; config = nothing, search_type = "plain")

The query side of a full-text search (PostgreSQL only): `text` parsed into a `tsquery`. It is the
right-hand side of the `@search` lookup and the query of `SearchRank` and `SearchHeadline`.

`search_type` picks the parser PostgreSQL applies to `text`:

| `search_type` | renders | `text` is read as |
|---|---|---|
| `"plain"` | `plainto_tsquery` | words, all required |
| `"phrase"` | `phraseto_tsquery` | words, in this order |
| `"websearch"` | `websearch_to_tsquery` | search-engine syntax: `"a phrase"`, `or`, `-word` |
| `"raw"` | `to_tsquery` | `tsquery` syntax: `senn:* & !prost`. A syntax error is the server's, at execution |

`config` names a text-search configuration (`"english"`, `"simple"`, `"pg_catalog.portuguese"`); with
none, the server's `default_text_search_config` applies.

Queries combine with `&` (both), `|` (either) and `~` (not), PostgreSQL's `&&`, `||` and `!!`.
Combined queries must share one config, or `QueryBuildError` is raised:

```julia
SearchQuery("senna"; config = "simple") | SearchQuery("prost"; config = "simple")
# (plainto_tsquery('simple'::regconfig, \$1::text) || plainto_tsquery('simple'::regconfig, \$2::text))
```

The text is bound as a parameter; the config
is checked to be a name and written into the SQL, which is what lets PostgreSQL use an index built on
`to_tsvector('english', col)`. A config that is not a name, or an unknown `search_type`, raises
`InvalidValueError` here, as does text containing a NUL character.

```julia
M.Driver.objects.filter("surname__@search" => SearchQuery("senna"; config = "simple"))
M.Race.objects.filter("name__@search" => SearchQuery("\\"grand prix\\" -british"; search_type = "websearch"))
```
"""
function SearchQuery(text::AbstractString; config = nothing, search_type = "plain")
  cfg = Dialect.ts_config_name(config)
  (search_type isa AbstractString && search_type in _SEARCH_TYPES) || throw(InvalidValueError(
    "SearchQuery's search_type is one of \"plain\", \"phrase\", \"websearch\" or \"raw\" (#31).", :format))
  occursin('\0', text) && throw(InvalidValueError(
    "SearchQuery's text contains a NUL character, which PostgreSQL text cannot hold.", :nul))
  return FObject(function_name = "SEARCH_QUERY", column = Any[Value(String(text))],
                 kwargs = Dict{String,Any}("config" => cfg, "search_type" => String(search_type)))
end
_result_rule(::Val{:SEARCH_QUERY}) = :unknown   # a `tsquery`, which no `CanonicalType` names
# `a & b`, `a | b`, `~a` (#1021): Django's `SearchQuery` combinators, PostgreSQL's `&&`, `||` and `!!`
# on `tsquery`. The result is a SEARCH_QUERY node, so the lookup, `SearchRank` and `SearchHeadline`
# take it as they take one query. Each leaf keeps its own search type and its text stays bound.
#
# The halves must agree on the config. The `@search` lookup parses the COLUMN with its query's config,
# and a combination of two configs has no single one to give it — Django lends it the left side's,
# which is the guess this refuses. A query with a config and one without disagree too: the second is
# parsed with the server's `default_text_search_config`, which may or may not be the first's.
const _TS_COMBINATORS = Dict("&&" => "&", "||" => "|", "!!" => "~")
function _combine_search_queries(op::String, operands...)
  all(x -> _is_fts_node(x, "SEARCH_QUERY"), operands) || throw(QueryBuildError(
    "A SearchQuery combines only with another SearchQuery, through &, | and ~: " *
    "SearchQuery(\"senna\") | SearchQuery(\"prost\"). A SearchVector adds to another with + instead (#1021)."))
  configs = unique(x.kwargs["config"] for x in operands)
  length(configs) == 1 || throw(QueryBuildError(
    "SearchQueries combined with $(_TS_COMBINATORS[op]) must share one config; got " *
    "$(join((c === nothing ? "none" : repr(c) for c in configs), " and ")). The @search lookup parses the " *
    "column with its query's config, so a combination of two has none to give it (#1021)."))
  column = Any[operands...]
  return FObject(function_name = "SEARCH_QUERY", column = column, aggregate = _any_agg(column),
                 kwargs = Dict{String,Any}("config" => only(configs), "combinator" => op))
end

SearchQuery(x; kwargs...) = throw(QueryBuildError(
  "SearchQuery takes the search text as a String; got a $(typeof(x)). To search a column, use the " *
  "lookup: \e[4m\e[32m\"surname__@search\" => SearchQuery(\"senna\")\e[0m (#31)."))

"""
    SearchVector(fields...; config = nothing, weight = nothing)

The document side of a full-text search (PostgreSQL only): one or more columns, each cast to text,
NULL-safe and joined by a space, then parsed into a `tsvector`. It is the vector of `SearchRank`.

```julia
SearchVector("forename", "surname"; config = "simple")
# to_tsvector('simple'::regconfig, COALESCE(("Tb"."forename")::text, '') || ' ' || COALESCE(("Tb"."surname")::text, ''))
```

`weight` labels every word of the document `"A"`, `"B"`, `"C"` or `"D"` (`setweight`), for
`SearchRank`'s `weights` to score; anything else raises `InvalidValueError`. Two vectors add with
`+` into one document, each keeping its own config and weight:

```julia
SearchVector("name"; weight = "A") + SearchVector("location"; weight = "B")
# (setweight(to_tsvector(COALESCE(("Tb"."name")::text, '')), 'A') || setweight(to_tsvector(…), 'B'))
```

A field is a column path or an expression, as for `Lower`. A `SearchVector` is an operand, not a
value: projecting one, comparing it or wrapping it in another function raises `QueryBuildError`, and
putting one on the right of a filter pair raises `FilterError`. To filter a single column, use the
`@search` lookup on it.
"""
function SearchVector(fields::_ScalarOperand...; config = nothing, weight = nothing)
  isempty(fields) && throw(QueryBuildError("SearchVector takes at least one field (#31)."))
  any(_is_fts_operand, fields) && throw(QueryBuildError(
    "A SearchVector's fields are text columns or expressions; a SearchVector or SearchQuery cannot be " *
    "one. To join two vectors into one document, add them: SearchVector(…) + SearchVector(…) (#1021)."))
  column = Any[_norm_fn_arg(f) for f in fields]
  return FObject(function_name = "SEARCH_VECTOR", column = column, aggregate = _any_agg(column),
                 kwargs = Dict{String,Any}("config" => Dialect.ts_config_name(config),
                                           "weight" => Dialect.ts_weight_name(weight)))
end
_result_rule(::Val{:SEARCH_VECTOR}) = CTsVector()
SearchVector(fields...; kwargs...) = throw(QueryBuildError(
  "SearchVector takes column paths (strings) or expressions as its fields (#31)."))

# `v1 + v2` (#1021): one document of two, `(v1 || v2)`, each half keeping its own config and weight —
# Django's `CombinedSearchVector`. The sum's config is the halves' when they agree; when they do not,
# it has none to lend a query written as a bare string, and `SearchRank` asks for a `SearchQuery`
# rather than guessing which half's config the text should be parsed with.
function _combine_search_vectors(a, b)
  (_is_fts_node(a, "SEARCH_VECTOR") && _is_fts_node(b, "SEARCH_VECTOR")) || throw(QueryBuildError(
    "A SearchVector adds only to another SearchVector, into one document: SearchVector(\"name\") + " *
    "SearchVector(\"location\"). A SearchQuery combines with &, | and ~ instead (#1021)."))
  ca, cb = a.kwargs["config"], b.kwargs["config"]
  mixed = get(a.kwargs, "mixed_config", false) === true || get(b.kwargs, "mixed_config", false) === true || ca != cb
  column = Any[a, b]
  return FObject(function_name = "SEARCH_VECTOR", column = column, aggregate = _any_agg(column),
                 kwargs = Dict{String,Any}("config" => mixed ? nothing : ca, "combinator" => "||",
                                           "mixed_config" => mixed))
end
_is_combined_fts(x) = _is_fts_operand(x) && get(x.kwargs, "combinator", nothing) !== nothing

# A query written as a bare string takes the config of the side written as an object.
_search_query_operand(q::AbstractString, config) = SearchQuery(q; config = config)
_search_query_operand(q, config) = _is_fts_node(q, "SEARCH_QUERY") ? q : throw(QueryBuildError(
  "The query is a SearchQuery(...), or the search text as a String (#31)."))

"""
    SearchRank(vector, query; normalization = nothing, cover_density = false, weights = nothing)

How well each row's document matches a query (PostgreSQL only), as a `Float64`: `ts_rank`, or
`ts_rank_cd` with `cover_density = true`. `vector` is a `SearchVector`, or the path of a
`SearchVectorField` column (#1021), a stored document: `SearchRank("search", q)`, Django's
`SearchRank(F("search"), q)`. `query` is a `SearchQuery`, or the search text as a String, which is
parsed with the vector's config (with none, for a stored column, which does not record one). `normalization` is PostgreSQL's integer bitmask (0 to 63)
for weighing the document's length; any other value raises `InvalidValueError`.

`weights` scores a word by its `SearchVector` weight label: four numbers from 0 to 1 for the labels
**D, C, B and A, in that order**, as PostgreSQL's `ts_rank` takes them (its default is
`[0.1, 0.2, 0.4, 1.0]`). Any other shape raises `InvalidValueError`. Weights only change scores
between words labelled differently, so they go with a weighted vector:

```julia
vector = SearchVector("name"; config = "english", weight = "A") +
         SearchVector("location"; config = "english", weight = "B")
SearchRank(vector, SearchQuery("monaco"; config = "english"); weights = [0.0, 0.0, 0.2, 1.0])
```

A sum of vectors with different configs has no single config to parse a String query with, so it
needs a `SearchQuery`; a String raises `QueryBuildError`.

Project it under a name, then filter and order by that name:

```julia
using PormG.Functions: SearchRank, SearchVector, SearchQuery

M.Driver.objects.
  values("forename", "surname",
         "rank" => SearchRank(SearchVector("forename", "surname"; config = "simple"), "ayrton senna")).
  filter("rank__@gte" => 0.01).
  order_by("-rank")
```

Filter on a threshold rather than `> 0`: for a query of several words, a row that misses them can
score a tiny positive value (`1e-20`) instead of `0`.
"""
function SearchRank(vector, query; normalization = nothing, cover_density = false, weights = nothing)
  # #1021: a String is the path of a SearchVectorField column, checked to be one at render, where the
  # path resolves (`_check_fts_column_operands`).
  stored = vector isa AbstractString
  (stored || _is_fts_node(vector, "SEARCH_VECTOR")) || throw(QueryBuildError(
    "SearchRank ranks a SearchVector(...), or a SearchVectorField column by its path; pass the columns " *
    "to rank as a SearchVector (#1021)."))
  stored && (vector = String(vector))
  w = Dialect.ts_rank_weights(weights)
  normalization === nothing || (normalization isa Integer && 0 <= normalization <= 63) ||
    throw(InvalidValueError("SearchRank's normalization is an integer bitmask from 0 to 63 (#31).", :range))
  cover_density isa Bool ||
    throw(InvalidValueError("SearchRank's cover_density is true or false (#31).", :type))
  !stored && get(vector.kwargs, "mixed_config", false) === true && query isa AbstractString && throw(QueryBuildError(
    "This SearchVector adds vectors with different configs, so a query written as a String has no " *
    "config to be parsed with. Pass a SearchQuery(text; config = …) (#1021)."))
  q = _search_query_operand(query, stored ? nothing : vector.kwargs["config"])
  column = Any[vector, q]
  return FObject(function_name = "SEARCH_RANK", column = column, aggregate = _any_agg(column),
                 formatter = Models.format_number_sql,
                 kwargs = Dict{String,Any}("normalization" => normalization, "cover_density" => cover_density,
                                           "weights" => w))
end
_result_rule(::Val{:SEARCH_RANK}) = :unknown   # a `real` (float4), which no `CanonicalType` names

# PostgreSQL's ts_headline option names, in the order they are written. The values are checked here
# and bound as ONE text parameter, never written into the SQL.
const _HEADLINE_OPTIONS = (:start_sel => "StartSel", :stop_sel => "StopSel", :max_words => "MaxWords",
                           :min_words => "MinWords", :short_word => "ShortWord",
                           :highlight_all => "HighlightAll", :max_fragments => "MaxFragments",
                           :fragment_delimiter => "FragmentDelimiter")
const _HEADLINE_TEXT_OPTIONS = (:start_sel, :stop_sel, :fragment_delimiter)

# One option as PostgreSQL's option parser (`deserialize_deflist`) reads it: a bare boolean, a bare
# integer, or a quoted string with `'` doubled and `\` doubled. The parser reads `\\` inside quotes as
# one backslash, so an undoubled pair arrived halved (measured on #31's review); this is PostgreSQL's
# own `serialize_deflist` escaping.
_headline_option_value(o::Bool) = o ? "true" : "false"
_headline_option_value(o::Integer) = string(Int(o))
_headline_option_value(o::AbstractString) = "'" * replace(o, "\\" => "\\\\", "'" => "''") * "'"

function _headline_options(opts::NamedTuple)::Union{Nothing,String}
  parts = String[]
  for (key, name) in _HEADLINE_OPTIONS
    o = opts[key]
    o === nothing && continue
    if key in _HEADLINE_TEXT_OPTIONS
      o isa AbstractString || throw(InvalidValueError("SearchHeadline's $(key) is a String (#31).", :type))
      occursin('\0', o) && throw(InvalidValueError("SearchHeadline's $(key) contains a NUL character.", :nul))
    elseif key == :highlight_all
      o isa Bool || throw(InvalidValueError("SearchHeadline's highlight_all is true or false (#31).", :type))
    else
      # PostgreSQL reads each as an int32, so a wider value is refused here rather than by the server.
      (o isa Integer && !(o isa Bool) && 0 <= o <= typemax(Int32)) ||
        throw(InvalidValueError("SearchHeadline's $(key) is a non-negative integer that fits an int32 (#31).", :range))
    end
    push!(parts, "$(name)=$(_headline_option_value(o))")
  end
  # PostgreSQL's own check, made here so it fails when the expression is built: 0 < MinWords < MaxWords,
  # with its defaults of 15 and 35 standing in for the one not given. Skipped under HighlightAll, which
  # ignores both, as PostgreSQL skips it.
  max_w = something(opts.max_words, 35)
  min_w = something(opts.min_words, 15)
  (opts.highlight_all === true || (max_w > 0 && min_w > 0 && min_w < max_w)) || throw(InvalidValueError(
    "SearchHeadline needs 0 < min_words < max_words; PostgreSQL's defaults are 15 and 35 (#31).", :range))
  return isempty(parts) ? nothing : join(parts, ", ")
end

"""
    SearchHeadline(expression, query; config = nothing, start_sel = nothing, stop_sel = nothing,
                   max_words = nothing, min_words = nothing, short_word = nothing,
                   highlight_all = nothing, max_fragments = nothing, fragment_delimiter = nothing)

`expression`'s text with the words `query` matches marked (PostgreSQL only): `ts_headline`, as a
`String`. The expression is cast to text, as each `SearchVector` field is. `query` is a `SearchQuery`, or the search text as a String. `config` defaults to the query's.

The options are PostgreSQL's (`StartSel`, `StopSel`, `MaxWords`, …), written in snake case. They are
checked when the expression is built and sent as one bound parameter: `start_sel`, `stop_sel` and
`fragment_delimiter` are strings, `highlight_all` a `Bool`, and the rest non-negative integers with
`0 < min_words < max_words`. Anything else raises `InvalidValueError`.

```julia
M.Race.objects.
  filter("name__@search" => SearchQuery("grand prix"; config = "english")).
  values("year", "hl" => SearchHeadline("name", SearchQuery("grand prix"; config = "english");
                                        start_sel = "<b>", stop_sel = "</b>"))
```

`ts_headline` reads the whole document for every row it returns, so filter and limit the rows first.
It does not HTML-escape the text: before rendering a headline of user-written text as HTML, see
*Showing a headline in a web page* in the Full-Text Search guide (#1026).
"""
function SearchHeadline(expression::_ScalarOperand, query; config = nothing, start_sel = nothing,
                        stop_sel = nothing, max_words = nothing, min_words = nothing,
                        short_word = nothing, highlight_all = nothing, max_fragments = nothing,
                        fragment_delimiter = nothing)
  _is_fts_operand(expression) && throw(QueryBuildError(
    "SearchHeadline marks up a text column or expression; a SearchVector or SearchQuery is not one (#31)."))
  cfg = Dialect.ts_config_name(config)
  q = _search_query_operand(query, cfg)
  cfg = something(cfg, Some(q.kwargs["config"]))
  options = _headline_options((; start_sel, stop_sel, max_words, min_words, short_word,
                                 highlight_all, max_fragments, fragment_delimiter))
  column = Any[_norm_fn_arg(expression), q]
  options === nothing || push!(column, Value(options))
  return FObject(function_name = "SEARCH_HEADLINE", column = column, aggregate = _any_agg(column),
                 formatter = Models.format_text_sql, kwargs = Dict{String,Any}("config" => cfg))
end
_result_rule(::Val{:SEARCH_HEADLINE}) = CText()
SearchHeadline(expression, query; kwargs...) = throw(QueryBuildError(
  "SearchHeadline marks up a column path (a string) or an expression (#31)."))


# #1070: the `__@` ladder is sugar — each part is the `Extract` a caller could write, and nothing
# more. The operand check and the value's range come from the part's row (`_EXTRACT_PART_ROWS`), so
# `"start_at__@hour"` and `Extract("start_at", "HOUR")` cannot disagree. (#955 tagged these nodes
# `"transform" => "<name>"` so a gate could tell them from a public `Extract`; the tag is gone.)
MONTH(x) = Extract(x, "MONTH")
YEAR(x) = Extract(x, "YEAR")
DAY(x) = Extract(x, "DAY")
# #636: the time parts. `Dialect.EXTRACT` renders all three on both engines — PostgreSQL `trunc`s
# `SECOND` so a fractional timestamp agrees with SQLite's `%S`.
HOUR(x) = Extract(x, "HOUR")
MINUTE(x) = Extract(x, "MINUTE")
SECOND(x) = Extract(x, "SECOND")
# #636: the week parts, on Django's numbering. Three are PostgreSQL `EXTRACT` fields with that exact
# numbering (`WEEK` and `ISOYEAR` are ISO-8601, `ISODOW` is 1 = Monday), so they go through `Extract`
# and `Dialect.EXTRACT` gives SQLite the matching arithmetic. `week_day` (1 = Sunday) is no EXTRACT
# field on either engine — `DOW` is 0-based — so it is a node of its own, like `QUARTER` below.
WEEK(x) = Extract(x, "WEEK")
ISO_YEAR(x) = Extract(x, "ISOYEAR")
ISO_WEEK_DAY(x) = Extract(x, "ISODOW")
WEEK_DAY(x) = (y = _transform_operand("WEEK_DAY", x);
               FObject(function_name = "WEEK_DAY", column = y, aggregate = _any_agg(y),
                       formatter = _TEMPORAL_FUNCTION_ROWS["WEEK_DAY"].formatter))
_result_rule(::Val{:WEEK_DAY}) = :unknown   # as `QUARTER`
Y_M(x) = ToChar(x, "YYYY-MM")
# #562: `@date` no longer goes through `ToChar`. A `ToChar` node carries the format mask as SQL
# text, which forces one spelling on both engines; `DATE` is the one transform where the correct
# spelling differs (`(col)::date` on PostgreSQL, `strftime` on SQLite — see `Dialect.DATE`). Naming
# the function lets the dialect decide, and it is what lets the `F` ladder delegate here instead of
# resolving into `Dialect` on its own.
# #878 — the transform targets take `x` untyped, so every value reached `FObject.column` and anything
# outside its union died in `convert` there (#533's defect class: a raw `MethodError` naming the whole
# column union). The gate is `_aggregate_operand`'s: test against the slot's OWN declared type, so the
# two cannot disagree, and refuse the rest by type name. A `Subquery` is inside the slot since #878 and
# renders where a column would — `((SELECT …))::date` on PostgreSQL, `strftime('%Y-%m-%d', (SELECT …))`
# on SQLite — with the formatter on this node, so it reads back as a date. The ladder hands these a
# split path (`Vector{String}`). The slot's `Vector{T}` member is wider than that — any vector — and a
# vector of anything else died in the build walk instead, so a vector must be a split path here.
function _transform_operand(fn::String, x)
  y = _norm_fn_arg(x)
  y isa _FObjectColumn && !(y isa AbstractVector && !(y isa Vector{String})) && return y
  throw(QueryBuildError(
    "\e[4m\e[31m$(fn)\e[0m cannot take an operand of type " *
    "`$(y isa AbstractVector ? string(typeof(y)) : nameof(typeof(y)))`. Its operand is a " *
    "column path, an expression or a `Subquery(...)`; the usual spelling is the transform on the path " *
    "— \e[4m\e[32m\"col__@$(lowercase(fn))\"\e[0m (#878)."))
end
DATE(x) = (y = _transform_operand("DATE", x);
           FObject(function_name = "DATE", column = y, aggregate = _any_agg(y), formatter = _TEMPORAL_FUNCTION_ROWS["DATE"].formatter))
_result_rule(::Val{:DATE}) = CDate()
# Same that function CAST in django ORM
# # relatorio = relatorio.annotate(quarter=functions.Concat(functions.Cast(f'{data}__year', CharField()), Value('-Q'), Case(
# # 					When(**{ f'{data}__month__lte': 4 }, then=Value('1')),
# # 					When(**{ f'{data}__month__lte': 8 }, then=Value('2')),
# # 					When(**{ f'{data}__month__lte': 12 }, then=Value('3')),
# # 					output_field=CharField()
# # 				)))

# #579 — `@quarter` / `@quadrimester` extract the period NUMBER; `@yyyy_q` / `@yyyy_quad` build the
# year-qualified label.
#
# These two used to be one thing. `QUARTER` built the `CONCAT(year, '-Q', CASE …)` expansion below,
# so it denoted the string `'1985-Q1'` — fine for a `values()` grouping key, and never able to equal
# the `1` that `api.md`, `read/filters_and_aggregates.md` and `read/functions_and_dates.md` all
# documented as the filter value. `filter("date__@quarter" => 1)` rendered valid SQL, bound the
# parameter, and returned nothing, with no error and no way to tell from the outside.
#
# Prior art settles the split, and it is unanimous: Django registers `ExtractQuarter` (an
# `IntegerField`, 1-4) as the `__quarter` LOOKUP and deliberately does NOT register `TruncQuarter`
# as a transform, because the `Extract` subclasses own those names; SQL/PostgreSQL/jOOQ separate
# `EXTRACT(QUARTER FROM x)` from `date_trunc('quarter', x)` the same way. Nobody resolves one name
# to two meanings by position. So the number keeps the plain name and the label gets its own —
# spelled like `@yyyy_mm`, the bucket it sits beside, rather than like Django's `TruncQuarter`,
# because PormG's existing bucket idiom is a to_char/strftime string and not a truncated date.
#
# The label bodies are moved verbatim. `@yyyy_quad` therefore still renders `'1985-Q1'`, sharing the
# `-Q` separator with `@yyyy_q`; that ambiguity predates this change and is left alone here so the
# move stays a rename.
#
# #997: both labels set `propagate_null`, so PostgreSQL joins them with `||` like SQLite does and a
# NULL date gives a NULL label rather than `'-Q'` (`Dialect.CONCAT`). The flag is set on the node and
# not taken as a `Concat` keyword, because the public function does not offer it: a public `Concat`
# skips a NULL operand on both engines (#1006).
function _null_propagating(f::FObject)
  f.kwargs["propagate_null"] = true
  return f
end
function Y_QUAD(x)
  return _null_propagating(Concat([
                Cast(YEAR(x), CharField()),
                Value("-Q"),
                Case([When(OP(MONTH(x), "<=", 4), then = 1),
                      When(OP(MONTH(x), "<=", 8), then = 2),
                      When(OP(MONTH(x), "<=", 12), then = 3)
                      ], 
                      output_field = CharField())
                ], 
                output_field = CharField(),
                _as = "$(x[1])__yyyy_quad"))
end
function Y_Q(x)
  return _null_propagating(Concat([
                Cast(YEAR(x), CharField()),
                Value("-Q"),
                Case([When(OP(MONTH(x), "<=", 3), then = 1),
                      When(OP(MONTH(x), "<=", 6), then = 2),
                      When(OP(MONTH(x), "<=", 9), then = 3),
                      When(OP(MONTH(x), "<=", 12), then = 4)
                      ], 
                      output_field = CharField())
                ],
                output_field = CharField(),
                _as = "$(x[1])__yyyy_q"))
end
# `Dialect.QUARTER` / `Dialect.QUADRIMESTER` already rendered the number per engine — they were what
# the `F` ladder resolved into before #562 collapsed the two. Naming the function here is what puts
# both spellings on that one rendering. The formatter is what makes the right-hand side type-check:
# the `Concat` node above carries none, which is the second half of #579 — `=> "abc"` bound the
# string and matched nothing instead of raising.
# #878: through `_transform_operand` (above `DATE`), for the same reason.
QUARTER(x) = (y = _transform_operand("QUARTER", x);
              FObject(function_name = "QUARTER", column = y, aggregate = _any_agg(y), formatter = _TEMPORAL_FUNCTION_ROWS["QUARTER"].formatter))
_result_rule(::Val{:QUARTER}) = :unknown   # an integer on SQLite; the PostgreSQL type is not stated here yet
QUADRIMESTER(x) = (y = _transform_operand("QUADRIMESTER", x);
                   FObject(function_name = "QUADRIMESTER", column = y, aggregate = _any_agg(y), formatter = _TEMPORAL_FUNCTION_ROWS["QUADRIMESTER"].formatter))
_result_rule(::Val{:QUADRIMESTER}) = :unknown   # as `QUARTER`
# #28: `@len`, an `ArrayField`'s element count (`Dialect.ARRAY_LEN`). A count, so its right-hand side
# is a number. Unlike the date parts it is checked against its operand's type when it renders
# (`_get_select_query(::FObject)`): `cardinality` over a column that is not an array is an error only
# the server would report, so the build refuses it first, naming the path.
ARRAY_LEN(x) = (y = _transform_operand("LEN", x);
                FObject(function_name = "ARRAY_LEN", column = y, aggregate = _any_agg(y), formatter = Models.format_number_sql))
_result_rule(::Val{:ARRAY_LEN}) = :unknown   # PostgreSQL only; the `cardinality` type is not stated here yet


function ISNULL(v::AbstractString, value::Bool; expression::Bool = false)
  # `v` is the rendered column text (#602: `AbstractString`, so a non-`String` spelling dispatches).
  # `expression`: the caller's licence for a column whose rendered text is a call by construction.
  # The HAVING alias branch passes it for a `Max`/`Min`/`Sum`/`Avg` projection (#654) —
  # `MAX("Tb"."name") IS NULL` is meaningful there (every value in the group is NULL) — and the WHERE
  # path for a transform column (#972), `EXTRACT(YEAR FROM "Tb"."date") IS NULL`. Named `aggregate`
  # until #972 gave it a second, non-aggregate caller. The caller decides from the node, never from
  # the text, so the refusal below is unchanged for every other column.
  if !expression && contains(v, "(")
    throw(FilterError("Error in ISNULL: the column $(v) cannot be a function expression."))  # refusal-value-ok: a column name from the query, not a bound value
  end
  if value
    return string(v, " IS NULL")
  else
    return string(v, " IS NOT NULL")
  end
end
