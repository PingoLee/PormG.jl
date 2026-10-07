# Julia operator overloads on the query-expression nodes (#130): arithmetic (`+ - * /`), the six
# comparisons, `isequal`, and the bitwise set (`& | ~ << >> xor`), for `FExpression`,
# `JoinedReference`, `WindowFunction` and `FObject`.
#
# A file of its own, included after `types.jl`, because a method SIGNATURE is evaluated when the
# method is defined — not lazily like its body. Inside `types.jl` each family had to sit after the
# struct it dispatches on, so the overloads were split into runs between struct definitions. Here
# every struct already exists, so the families sit together. The node structs, the operand unions
# they compose from (`_CompareLiteral`, `_ColumnHandle`, `_DurationOperand`) and `OP()` stay in
# `types.jl`; the refusal builder `_unsupported_compare_operand` is in `error_funnels.jl`.

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

# #814 — a date or timestamp LITERAL as the right side of `-`: the time from that instant to the
# expression's, `F("date") - Date(2009, 3, 1)`. `-` only: adding, multiplying or dividing two
# instants has no meaning (#801 refuses the column spelling of each). The literal is the explicit
# spelling of what `F("date") - "2009-03-01"` attempted, which bound TEXT — PostgreSQL has no
# `date - text`, and SQLite subtracted the years — and which is now refused on both engines.
# The renderer types the literal (`_render_operand_typed`) and refuses it against a left that is not
# temporal.
const _TemporalLiteral = Union{Dates.Date, Dates.DateTime, TimeZones.ZonedDateTime}

function Base.:-(f::FExpression, operand::_TemporalLiteral)
  return FExpression(
    field_name=f.operation === nothing ? f.field_name : f,
    operation="-",
    operand=operand,
    function_name="F",
    column=f.operation === nothing ? (f.field_name isa String ? f.field_name : "") : "",
    aggregate=f.aggregate
  )
end

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
# `_guard_no_handle` (join_conditions.jl) is what absorbs that one.
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
# `FExpression` struct in `types.jl`), so widening one widens the other. The CONSUMER half is no
# longer per-type either (#536): the literal arm of `_set_update_query_operand`
# (`expression_render.jl`) binds every `_CompareLiteral` scalar through the rooted column's
# formatter, so a new member cannot bind RAW — what it can still lack is PROOF, and that is the
# oracle row `test_f_date_operands.jl` demands per member. A column HANDLE (`_ColumnHandle`) is the
# other kind of operand and renders as a column reference, never a bound value;
# `test_node_admission.jl` is what fails when a NODE type is admitted without a consumer.
const _CompareOperand = Union{_CompareLiteral,_ColumnHandle,_SubqueryOperand,FExpression}

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
# in Base, and the issue's table is the left-hand form. Out of scope here; the node-as-container
# question (`isequal`/`in`) these methods sit beside is settled by #541 — see the `isequal` block below.
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
    # that union owes an oracle row per member (#533, and its note in `types.jl`), and a method on
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
# that block in `types.jl`). Base's fallback is `isequal(x, y) = x == y`, so without these the
# catch-alls above would make `isequal(F("a"), nothing)` THROW where it used to answer `false` — and
# `isequal` is the total hashing-equality contract `Dict`/`Set`/`unique`/`findfirst(isequal(x), …)`
# rely on; it must never throw. Identity for two nodes, `false` against anything else; the `::Missing`
# arm disambiguates against Base's `isequal(::Any, ::Missing)` exactly as the Joined block does.
#
# #541 settled what this guard does NOT cover, and settled it as "leave it": `x in v` and
# `findfirst(==(x), v)` reach `==`, not `isequal`, so on a node they still build a predicate and the
# caller's boolean context throws a `TypeError`. A node is a predicate, not a container value — ask
# `isequal`, `===` or a `Set` instead. The alternatives were weighed and rejected: a `Bool`-returning
# `==(::FExpression, ::FExpression)` would break `F("grid") == F("positionorder")`, the column-to-column
# predicate this operator exists for; a `Base.in` override would give `in` a meaning `==` does not
# have, for one type, and still leave `"a" in [f]` broken. `test_f_date_operands.jl` pins it.
Base.isequal(a::FExpression, b::FExpression) = a === b
Base.isequal(::FExpression, ::Any) = false
Base.isequal(::FExpression, ::Missing) = false

# A number on the LEFT of an F expression. `+` and `*` commute, so `n + f` is `f + n`, built by the
# overloads above. #884: these used to build the node from `f.field_name` themselves. For a bare
# `F("x")` that is the column, but for an expression it is only the left-most column, so
# `2 * (F("a") - F("b"))` rendered `"a" * 2` on both engines, silently.
Base.:+(operand::Union{Integer,Float64}, f::FExpression) = f + operand
Base.:*(operand::Union{Integer,Float64}, f::FExpression) = f * operand

# #481 — the six comparisons with a JOINED-COPY reference on the LEFT, which is the spelling a
# `cjoin_on` ON clause is written in: `Joined("d","driverid") == F("driverid")`.
#
# These signatures name `JoinedReference`, which `types.jl` defines after `FExpression`. In
# `types.jl` they had to sit after that struct, apart from the `FExpression` comparisons. In this
# file every struct already exists (see the header), so the two families sit together.
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
# ambiguities with Base. `isequal(::JoinedReference, ::Any)` (`types.jl`) is untouched: it never
# reaches `==`, so hashed containers (`Set`/`Dict`/`unique`) keep behaving.
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

function Base.:+(f::WindowFunction, operand::Union{Integer,Float64,String,FExpression,SQLTypeFunction})
  return FExpression(field_name=f, operation="+", operand=operand, function_name="F", column="", aggregate=_is_agg(operand))
end
function Base.:-(f::WindowFunction, operand::Union{Integer,Float64,String,FExpression,SQLTypeFunction})
  return FExpression(field_name=f, operation="-", operand=operand, function_name="F", column="", aggregate=_is_agg(operand))
end
# #814: `Lag("date", …) - Date(2009, 3, 1)`, the window-function twin of the `F` method above.
function Base.:-(f::WindowFunction, operand::_TemporalLiteral)
  return FExpression(field_name=f, operation="-", operand=operand, function_name="F", column="", aggregate=false)
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
# #814: `Max("date") - Date(2009, 3, 1)`, the function twin of the `F` method above.
function Base.:-(f::FObject, operand::_TemporalLiteral)
  return FExpression(field_name=f, operation="-", operand=operand, function_name="F", column="", aggregate=f.aggregate)
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

# Comparison operations for FObject — the `F` comparisons above, with a function on the left (#895).
#
# `Count("id") > 1` raised a raw `MethodError: isless(::Int64, ::FObject)`, because no comparison
# method took a function on the left, and `Lower("surname") == "senna"` fell through to `Base.==` and
# reached `filter(...)` as a bare `false`. One hop down they already worked: `(Count("id") + 0) > 1` is
# arithmetic, which builds an `FExpression`, and the comparison nests over it. So a comparison builds
# that same node — the nesting branch of `_compare(::FExpression)` — and the filter decides what it
# means: a row function filters in WHERE, and a predicate containing an aggregate is refused by
# `_guard_no_aggregate_predicate` (build_filter.jl), as `OP(Count("id"), ">", 1)` has been since #537.
#
# The operand vocabulary is `_CompareOperand`, the `F` one, and a value outside it is refused by the
# same funnel. A function on the RIGHT is outside it, as it is for `F`.
#
# #919: a window function is the other `SQLTypeFunction`, and `Rank(…) > 1` raised the same raw
# `MethodError: isless` #895 removed for `Count("id") > 1`. It takes the same methods and builds the
# same node `(Rank(…) + 0) > 1` already built. `filter(...)` then refuses it with the CTE advice, through
# `_is_window_expr`, and a SELECT-side `Case` renders it. `aggregate` is `false` on every window.
const _ComparedFunction = Union{FObject,WindowFunction}

_compare(f::_ComparedFunction, operation::String, operand) =
  FExpression(field_name=f, operation=operation, operand=operand, function_name="F", column="",
              aggregate=f.aggregate)

for (op, sym) in ((:(==), "="), (:(!=), "!="), (:(>), ">"), (:(<), "<"), (:(>=), ">="), (:(<=), "<="))
  @eval Base.$op(f::_ComparedFunction, operand::_CompareOperand) = _compare(f, $sym, operand)
  # `FExpression`'s #536/#603 catch-all, for the same reasons: a non-`String` `AbstractString` is
  # normalized and re-dispatched, and anything else is refused instead of answering from `Base`.
  @eval function Base.$op(x::_ComparedFunction, operand)
    operand isa AbstractString && return Base.$op(x, String(operand))
    throw(_unsupported_compare_operand($sym, operand))
  end
end
# The Base methods these collide with, as for `FExpression` — Aqua's ambiguity check pins the set.
Base.:(==)(::_ComparedFunction, operand::Missing) = throw(_unsupported_compare_operand("=", operand))
Base.:(==)(::_ComparedFunction, operand::WeakRef) = throw(_unsupported_compare_operand("=", operand))
Base.:<(::_ComparedFunction, operand::Missing)    = throw(_unsupported_compare_operand("<", operand))

# The `isequal` half, as for `FExpression` (#536, #541): `isequal` falls back to `==`, which now
# builds a predicate, and `Dict`/`Set`/`unique` rely on it answering a `Bool`. Identity for two nodes.
Base.isequal(a::_ComparedFunction, b::_ComparedFunction) = a === b
Base.isequal(::_ComparedFunction, ::Any) = false
Base.isequal(::_ComparedFunction, ::Missing) = false


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
