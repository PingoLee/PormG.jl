
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

"""
    FirstValue(x; over::WindowSpec = WindowOver())

Window `FIRST_VALUE(x)` — the value of `x` in the first row of the window frame.

Safe under the default frame (`RANGE BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW`), because
the frame always starts at the partition's first row. [`LastValue`](@ref) is **not** — see
its docstring.

See also [`NthValue`](@ref), [Window Functions](@ref).
"""
FirstValue(x::WindowColumnArg; over::WindowSpec=WindowOver()) = WindowFunction(function_name="FIRST_VALUE", column=_norm_fn_arg(x), over=over)

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
# `Replace`'s `find`/`replace`: TEXT slots, so a string there is a literal. A number is refused
# rather than converted — PostgreSQL has no `replace(text, bigint, bigint)`, and turning `1` into
# `"1"` would be a guess the caller can spell for themselves.
_text_operand(x::AbstractString) = Value(String(x))
_text_operand(x::Union{Integer,Float16,Float32,Float64}) = throw(QueryBuildError(
  "\e[4m\e[31mReplace\e[0m searches and replaces TEXT, and a $(typeof(x)) is a number. " *
  "Write it as a string: \e[4m\e[32mstring(x)\e[0m (#705)."))
_text_operand(x) = _function_operand(x)

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

`type` is preferably a field object (`Cast("points", IntegerField())`), which renders in each
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

```julia
using PormG.Functions: Cast
using PormG.Models: IntegerField

M.Result.objects.values("resultid", "points_int" => Cast("points", IntegerField()))
M.Result.objects.values("resultid", "points_2dp" => Cast("points", "numeric(10,2)"))
```

See also [Functions and Dates](@ref).
"""
function Cast(x::_ScalarOperand, type::AbstractString)
  return FObject(function_name = "CAST", column = _norm_fn_arg(x), aggregate = _any_agg(x), kwargs = Dict{String, Any}("type" => Dialect.cast_type_name(type)))
end
function Cast(x::_ScalarOperand, type::PormGField)
  return Cast(x, type.type)
end

"""
    Concat(expressions; output_field=nothing)

Concatenates multiple strings or columns.

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
  return FObject(function_name = "CONCAT", column = processed_cols, aggregate = _any_agg(processed_cols), kwargs = Dict{String, Any}("output_field" => output_field, "as" => String(_as)))
end
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

# Variadic convenience: Concat("forename", Value(" "), "surname") → same as vector form
Concat(args...; kwargs...) = Concat(collect(args); kwargs...)

# #878 — `Extract` and `ToChar` take the operand `_ScalarOperand` would, plus an already-split `__@`
# path (the transform ladder hands `YEAR`/`MONTH`/`DAY`/`Y_M` a `Vector{String}`). Named once for
# both, for the same reason: the subquery was missing from each spelled-out copy.
const _TemporalOperand = Union{AbstractString,SQLTypeField,SQLTypeFunction,SQLTypeF,SQLTypeCTE,
                               SQLTypeJoined,SubqueryObject,Vector{<:AbstractString}}

"""
    Extract(column, part)

Extracts a component (`"year"`, `"month"`, `"dow"`, …) from a date/time column.

`part` is case-insensitive and must be a PostgreSQL `EXTRACT` field: `CENTURY`, `DAY`, `DECADE`,
`DOW`, `DOY`, `EPOCH`, `HOUR`, `ISODOW`, `ISOYEAR`, `JULIAN`, `MICROSECONDS`, `MILLENNIUM`,
`MILLISECONDS`, `MINUTE`, `MONTH`, `QUARTER`, `SECOND`, `TIMEZONE`, `TIMEZONE_HOUR`,
`TIMEZONE_MINUTE`, `WEEK`, `YEAR`. Anything else — PostgreSQL's synonyms such as `"years"` or
`"hr"` included — raises `InvalidValueError` when the expression is built, on both engines.
SQLite runs `YEAR` `MONTH` `DAY` `HOUR` `MINUTE` `SECOND` `DOW` `DOY` and raises
`BackendCapabilityError` for the rest.

To change the result type, wrap it in [`Cast`](@ref) — e.g. on PostgreSQL,
`Cast(Extract("date", "epoch"), "bigint")`.
"""
function Extract(x::_TemporalOperand, part::AbstractString; formatter::Union{Nothing, Function, PormGField} = nothing)
  isa(formatter, PormGField) && (formatter = formatter.formatter)
  # #691: refuse an unknown part at build time on both engines. The node keeps the caller's
  # spelling — the dialect renders the canonical one — so the `"YEAR"` range rewrite in
  # `filter_operators.jl` sees exactly what it saw before.
  Dialect.extract_part(part)
  return FObject(function_name = "EXTRACT", column = _norm_fn_arg(x), aggregate = _any_agg(x), formatter = formatter, kwargs = Dict{String, Any}("part" => String(part)))
end
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
  return FObject(function_name = "EXTRACT_DATE", column = _norm_fn_arg(x), aggregate = _any_agg(x), formatter = formatter, kwargs = Dict{String, Any}("format" => String(format)))
end


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
`Coalesce("points", 0; output_field = "integer")` renders `(…)::integer` on PostgreSQL and `CAST(… AS INTEGER)` on SQLite, so the value,
a filter on it, and a CTE column typed by it all agree. On SQLite a `date` renders `date(…)`, and the
other temporal types and arrays raise `BackendCapabilityError`, as for [`Cast`](@ref).
"""
function Coalesce(x...; output_field::Union{N, AbstractString, Nothing} where N <: PormGField = nothing)
  output_field = _output_field_type(output_field)   # #603, #696
  _check_operand_count("Coalesce", x)   # #859
  processed_cols = Any[_function_operand(v) for v in x]   # #705
  return FObject(function_name = "COALESCE", column = processed_cols, aggregate = _any_agg(processed_cols), kwargs = Dict{String, Any}("output_field" => output_field))
end

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
`Greatest("points", 0; output_field = "integer")` renders `(…)::integer` on PostgreSQL and `CAST(… AS INTEGER)` on SQLite, so the value,
a filter on it, and a CTE column typed by it all agree. On SQLite a `date` renders `date(…)`, and the
other temporal types and arrays raise `BackendCapabilityError`, as for [`Cast`](@ref).
"""
function Greatest(x...; output_field::Union{N, AbstractString, Nothing} where N <: PormGField = nothing)
  output_field = _output_field_type(output_field)   # #603, #696
  _check_operand_count("Greatest", x)   # #859
  processed_cols = Any[_function_operand(v) for v in x]   # #705
  return FObject(function_name = "GREATEST", column = processed_cols, aggregate = _any_agg(processed_cols), kwargs = Dict{String, Any}("output_field" => output_field))
end

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
`Least("points", 25; output_field = "integer")` renders `(…)::integer` on PostgreSQL and `CAST(… AS INTEGER)` on SQLite, so the value,
a filter on it, and a CTE column typed by it all agree. On SQLite a `date` renders `date(…)`, and the
other temporal types and arrays raise `BackendCapabilityError`, as for [`Cast`](@ref).
"""
function Least(x...; output_field::Union{N, AbstractString, Nothing} where N <: PormGField = nothing)
  output_field = _output_field_type(output_field)   # #603, #696
  _check_operand_count("Least", x)   # #859
  processed_cols = Any[_function_operand(v) for v in x]   # #705
  return FObject(function_name = "LEAST", column = processed_cols, aggregate = _any_agg(processed_cols), kwargs = Dict{String, Any}("output_field" => output_field))
end



"""
    Lower(column)

Converts a string to lowercase.
"""
function Lower(x::_ScalarOperand)
  return FObject(function_name = "LOWER", column = _norm_fn_arg(x), aggregate = _any_agg(x))
end

"""
    Upper(column)

Converts a string to uppercase.
"""
function Upper(x::_ScalarOperand)
  return FObject(function_name = "UPPER", column = _norm_fn_arg(x), aggregate = _any_agg(x))
end

"""
    Length(column)

Returns the length of a string.
"""
function Length(x::_ScalarOperand)
  return FObject(function_name = "LENGTH", column = _norm_fn_arg(x), aggregate = _any_agg(x), formatter = Models.format_number_sql)
end

"""
    Abs(column)

Returns the absolute value of a number.
"""
function Abs(x::_ScalarOperand)
  return FObject(function_name = "ABS", column = _norm_fn_arg(x), aggregate = _any_agg(x), formatter = Models.format_number_sql)
end

"""
    Round(column, precision=0)

Rounds a number to the specified precision.
"""
function Round(x::_ScalarOperand, precision::Integer = 0)
  return FObject(function_name = "ROUND", column = _norm_fn_arg(x), aggregate = _any_agg(x), kwargs = Dict{String, Any}("precision" => precision), formatter = Models.format_number_sql)
end

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


"""
    Replace(column, find, replace)

Replaces all occurrences of `find` with `replace` in the string.

`column` is a column path. `find` and `replace` are text: a string there is a literal, and a number
raises `QueryBuildError` naming its string spelling (#705).
"""
function Replace(x, find, replace)
  # #705: `find`/`replace` are text, so a string there is a literal (`_text_operand`).
  column = Any[_function_operand(x), _text_operand(find), _text_operand(replace)]
  return FObject(function_name = "REPLACE", column = column, aggregate = _any_agg(column))
end

"""
    Trim(column)

Removes leading and trailing whitespace from a string.
"""
function Trim(x::_ScalarOperand)
  return FObject(function_name = "TRIM", column = _norm_fn_arg(x), aggregate = _any_agg(x))
end

"""
    LTrim(column)

Removes leading whitespace from a string.
"""
function LTrim(x::_ScalarOperand)
  return FObject(function_name = "LTRIM", column = _norm_fn_arg(x), aggregate = _any_agg(x))
end

"""
    RTrim(column)

Removes trailing whitespace from a string.
"""
function RTrim(x::_ScalarOperand)
  return FObject(function_name = "RTRIM", column = _norm_fn_arg(x), aggregate = _any_agg(x))
end

"""
    Floor(column)

Returns the largest integer less than or equal to a number.
"""
function Floor(x::_ScalarOperand)
  return FObject(function_name = "FLOOR", column = _norm_fn_arg(x), aggregate = _any_agg(x), formatter = Models.format_number_sql)
end

"""
    Ceil(column)

Returns the smallest integer greater than or equal to a number.
"""
function Ceil(x::_ScalarOperand)
  return FObject(function_name = "CEIL", column = _norm_fn_arg(x), aggregate = _any_agg(x), formatter = Models.format_number_sql)
end



"""
    Sqrt(column)

Returns the square root of a number.
"""
function Sqrt(x::_ScalarOperand)
  return FObject(function_name = "SQRT", column = _norm_fn_arg(x), aggregate = _any_agg(x), formatter = Models.format_number_sql)
end

"""
    Exp(column)

Returns the exponential value (e^x) of a number.
"""
function Exp(x::_ScalarOperand)
  return FObject(function_name = "EXP", column = _norm_fn_arg(x), aggregate = _any_agg(x), formatter = Models.format_number_sql)
end

"""
    Ln(column)

Returns the natural logarithm of a number.
"""
function Ln(x::_ScalarOperand)
  return FObject(function_name = "LN", column = _norm_fn_arg(x), aggregate = _any_agg(x), formatter = Models.format_number_sql)
end

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


MONTH(x) = Extract(x, "MONTH", formatter = Models.format_number_sql)
YEAR(x) = Extract(x, "YEAR", formatter = Models.format_number_sql)
DAY(x) = Extract(x, "DAY", formatter = Models.format_number_sql)
# #636: the time parts. `Dialect.EXTRACT` already renders all three on both engines — PostgreSQL
# `trunc`s `SECOND` so a fractional timestamp agrees with SQLite's `%S` — so only the range-checking
# formatter is new: a value no clock can show is refused rather than silently matching nothing (#579).
HOUR(x) = Extract(x, "HOUR", formatter = Models.format_hour_sql)
MINUTE(x) = Extract(x, "MINUTE", formatter = Models.format_minute_sql)
SECOND(x) = Extract(x, "SECOND", formatter = Models.format_second_sql)
Y_M(x) = ToChar(x, "YYYY-MM", formatter = Models.format_yyyy_mm)
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
           FObject(function_name = "DATE", column = y, aggregate = _any_agg(y), formatter = Models.format_date_sql))
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
# not taken as a `Concat` keyword, because the public function does not offer it.
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
              FObject(function_name = "QUARTER", column = y, aggregate = _any_agg(y), formatter = Models.format_quarter_sql))
QUADRIMESTER(x) = (y = _transform_operand("QUADRIMESTER", x);
                   FObject(function_name = "QUADRIMESTER", column = y, aggregate = _any_agg(y), formatter = Models.format_quadrimester_sql))
# #28: `@len`, an `ArrayField`'s element count (`Dialect.ARRAY_LEN`). A count, so its right-hand side
# is a number. Unlike the date parts it is checked against its operand's type when it renders
# (`_get_select_query(::FObject)`): `cardinality` over a column that is not an array is an error only
# the server would report, so the build refuses it first, naming the path.
ARRAY_LEN(x) = (y = _transform_operand("LEN", x);
                FObject(function_name = "ARRAY_LEN", column = y, aggregate = _any_agg(y), formatter = Models.format_number_sql))


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


# ---
# Pagination
#
# INTERNAL, and NOT the fluent implementation. `query.page(...)` routes through
# `ChainCaller(_page!, q)` (object_manager.jl), which dispatches on `SQLObject`; these methods take
# an `SQLObjectHandler` and are never reached from the chain. `page` is un-exported (#202), has no
# caller in this repo, and survives only because test_public_exports.jl pins it as
# defined-but-unexported. The external API is the fluent `query.page(limit)` /
# `query.page(limit, offset)` — nothing in `docs/` or `README.md` mentions the function form.
#
# It is a second, parallel implementation of the same semantics, and the two surfaces silently
# drifting apart is exactly what #272 was. `test_fluent_parity_208.jl` now pins them equal; keep
# that test passing rather than editing one side alone.
#
# No docstring on purpose. Since #289 `api.md`'s `@autodocs` sets `Private = false`, so a docstring
# here would no longer reach the site by itself — but adding one would still present the function
# form as supported surface to anyone reading the source, and would invite a `public` declaration to
# "fix" its absence from the page. The `.page(...)` reference lives on the `object` docstring and in
# `docs/src/api.md` (the split that test_docstring_coverage.jl enforces).

# Sets BOTH clauses (offset falls back to its 0 default). Unreachable from the chain: `ChainCaller`
# forwards positional arguments only, so no keyword can arrive on the fluent path.
function page(object::SQLObjectHandler; limit::Integer = 10, offset::Integer = 0)
  object.object.limit = limit
  object.object.offset = offset
  return object
end
# Limit-only: the offset already on the handler is left alone. `_page!`'s 1-tuple method mirrors this.
function page(object::SQLObjectHandler, limit::Integer)
  object.object.limit = limit
  return object
end
function page(object::SQLObjectHandler, limit::Integer, offset::Integer)
  object.object.limit = limit
  object.object.offset = offset
  return object
end

# ---
# Fluent mutators behind `query.limit(...)`, `query.offset(...)` and `query.page(...)`.
#
# `ChainCaller` packs the call's varargs into ONE tuple and calls `f(q.object, args)`, so the
# argument these receive is always a `Tuple` and the arity check IS the dispatch. Every shape that is
# not an accepted arity therefore needs an `::Any` fallback throwing a `PormGError`: without one the
# user gets a bare `MethodError` naming `_page!` and a `Tuple{String, String}` — neither of which
# appears anywhere in their code — and `catch PormGError` (#231/#239) does not cover it (#272).
function _limit!(object::SQLObject, limit::Tuple{Integer})
  object.limit = limit[1]
end
function _limit!(object::SQLObject, limit)
  throw(QueryBuildError("Invalid limit() arguments: $(limit) (::$(typeof(limit))) — limit() takes exactly one Integer, e.g. limit(20)."))
end
function _offset!(object::SQLObject, offset::Tuple{Integer})
  object.offset = offset[1]
end
function _offset!(object::SQLObject, offset)
  throw(QueryBuildError("Invalid offset() arguments: $(offset) (::$(typeof(offset))) — offset() takes exactly one Integer, e.g. offset(40)."))
end
# page(n) is limit-only — the offset already on the handler survives, matching page(object, limit).
function _page!(object::SQLObject, v::Tuple{Integer})
  object.limit = v[1]
end
function _page!(object::SQLObject, v::Tuple{Integer, Integer})
  object.limit = v[1]
  object.offset = v[2]
end
function _page!(object::SQLObject, v)
  throw(QueryBuildError("Invalid page() arguments: a $(typeof(v)) — page() takes one Integer (limit) or two Integers (limit, offset), e.g. page(20) or page(20, 40)."))
end
