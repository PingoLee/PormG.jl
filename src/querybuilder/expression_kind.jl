# #1034 — ONE WALK for "what type does this expression have?", asked under one of two policies.
#
# The question used to be answered by a function per consumer, each walking the tree its own way and
# each forgetting a shape the others typed: read kinds alone took six fixes, one per shape (#564,
# #800, #824, #888, #965, #979). The walk below is written once — paths and transforms, joined and CTE
# handles, a `Subquery`, literals, and each function through the rule it states beside its
# constructor (`_result_rule`, `functions.jl`) — and the two policies differ only on a computed number:
#
# - `_AllKinds` — `_expression_kind`: every type PormG can name, on this engine. The expression-kind
#   matrix records it (its `kind` channel), and #1034's phase 3 moved the readers onto it one at a
#   time, each move a reviewed diff of that fixture: `_integer_operand_kind` (#1147, the
#   `Abs`/`Floor`/`Ceil`/`Round` render and the #1111 division check), the binder's formatter (step 4),
#   `Concat`'s temporal check (`_textless_temporal`, step 5c), and the render's side typing, which reads
#   it through a temporal narrowing (`_temporal_side_kind`, #882, #1459).
# - `_MeaningKinds` — what a value MEANS, on every engine (#1121): `_AllKinds` in every arm but a
#   computed number, which is its function's `_output_kind` (Django's `output_field`) rather than the
#   type one engine happens to compute it as (`_computed_kind`). `Avg("grid")` is a `numeric` on
#   PostgreSQL and a REAL on SQLite, and it means a float on both. Its reader is the read view
#   (`_read_kind`), which records a computed number as that type so the read path turns either engine's
#   answer into it, and records every other kind a read parser undoes.
#
# A third policy, `_ReadKinds`, answered the #564 read kind as the per-shape readers had before this
# file existed (`_operand_kind`, `_function_projection_kind`). #1459 deleted it once its last readers,
# the render's side typing and the interval arm of `_render_interval_operand` (#1456), read the walk.
#
# Both are asked AFTER the render, as every reader here is: resolving a joined path is what fills the
# field memo `_alias_column_field` reads, and a `Subquery` files its kind when it renders.
#
# Both type the numeric operators (`_operation_kind`), and since #1034 step 5a TEMPORAL arithmetic
# too: the walk computes the kind the render gives it (`_temporal_arith_kind`), rather than reading it
# from the render, so a node asked in another build still has one (decided by the maintainer). Since
# step 5b both ask the one copy of the rule, `_temporal_result_kind`. It is asked after the render, as
# every kind is: a joined path's column is found through the memo the render fills.
# The two policies: they differ only on a computed number.
abstract type _EveryKind end
struct _AllKinds <: _EveryKind end
struct _MeaningKinds <: _EveryKind end

"""
    CJSONValue()

#1458 (#1034 phase 4, decision D1) — the value at a key of a JSON document (`"payload__n"`): a JSON
scalar whose type is the data's, so PormG cannot name it. A kind of the walk only, never of a column, so
it lives here rather than in the column IR (`column_ir.jl`): no migration ever sees it.

Its field is the document's `JSONField` (`_kind_field`), so the bare lookup keeps the JSON formatter
(#1382); every other reader takes it as unnamed, as it takes `nothing`. Before #1458 the walk named a
key lookup the document's `CJSON()`, and four readers told the two apart by the record of rendered
lookups instead (`_unnamed_side`, the CTE `kinds` record, `_json_document_operand`,
`_json_key_lookup_operand`).
"""
struct CJSONValue <: CanonicalType end

# Whether the path `key` whose column is `field` is a key lookup into it: a JSONField the join walk
# rendered as `#>>`/`json_extract` (`_render_json_lookup` records each, keyed by its namespace).
_json_key_value(field, instruc::SQLInstruction, key) =
  field isa Models.sJSONField && memo_json_lookup(instruc, key)

"""
    _expression_kind(x, instruc) -> Union{CanonicalType, Nothing}

Every type PormG can name for the expression `x`, on `instruc`'s engine, or `nothing` when it names
none. Read after `x` renders. See the policies above.
"""
_expression_kind(x, instruc::SQLInstruction)::Union{CanonicalType,Nothing} = _infer_kind(x, instruc, _AllKinds())

# ── The walk ─────────────────────────────────────────────────────────────────────────────────────────
function _infer_kind(p::String, instruc::SQLInstruction, policy::_EveryKind)
  # A transformed path (`"ts__@date"`) names the transform's result, not the column — through the one
  # transform ladder (#562), the call `_get_filter_query(::String)` renders with.
  occursin("__@", p) && return _infer_function_kind(_check_function(p), instruc, policy)
  column_field = _alias_column_field(p, instruc)
  column_field === nothing && return nothing
  _json_key_value(column_field, instruc, memo_key(:base, p)) && return CJSONValue()   # #1458
  return _column_kind(column_field, policy)
end
_infer_kind(p::FExpression, instruc::SQLInstruction, policy::_EveryKind) =
  p.operation === nothing ? _infer_kind(p.field_name, instruc, policy) :
  _memo_kind(() -> _operation_kind(p, instruc, policy), p, instruc, policy)
_infer_kind(p::SQLField, instruc::SQLInstruction, policy::_EveryKind) = _infer_kind(p.field, instruc, policy)
_infer_kind(p::SQLText, ::SQLInstruction, policy::_EveryKind) =
  _is_null_literal(p.field) ? nothing : _literal_kind(p.field, policy)
_infer_kind(p::Union{FObject,WindowFunction}, instruc::SQLInstruction, policy::_EveryKind) =
  _memo_kind(() -> _infer_function_kind(p, instruc, policy), p, instruc, policy)

# A walk only reads the instruction, so within one question a node has one kind however often it is
# asked. It is asked more than once: a side of F arithmetic is asked as the render types it and again
# for the numeric rule, and a function's boolean asks its formatter, which walks it again. Unmemoized,
# nested arithmetic over functions was walked once per path, exponentially in its depth (review of
# #1034 step 5a). The memo lives for the outermost question only, so a kind asked after the render
# has moved on (resolving a path fills the memo the walk reads) is never one from before it. It is
# keyed by the instruction too: an inner query's walk is another instruction's question.
function _memo_kind(f, node, instruc::SQLInstruction, tag)
  tls = task_local_storage()
  memo = get(tls, :_pormg_kind_memo, nothing)
  memo === nothing || return get!(f, memo, (node, instruc, tag))
  memo = IdDict{Any,Any}()
  tls[:_pormg_kind_memo] = memo
  try
    return get!(f, memo, (node, instruc, tag))
  finally
    delete!(tls, :_pormg_kind_memo)
  end
end
# #824: a `Joined(...)` handle is the joined column, exactly as `Max(Joined(…))` reads it.
function _infer_kind(p::JoinedReference, instruc::SQLInstruction, policy::_EveryKind)
  column_field = _alias_column_field(p, instruc)
  column_field === nothing && return nothing
  _json_key_value(column_field, instruc, memo_key(p)) && return CJSONValue()   # #1458
  return _column_kind(column_field, policy)
end
_infer_kind(p::CTEReference, instruc::SQLInstruction, policy::_EveryKind) = _cte_column_kind(p, instruc, policy)
# #888: a `Subquery(...)` is its one projected column, as its own build typed it.
# #1153: the walk reads the record of the inner expression's own kind, and falls back to the inner
# build's read record where there is none (a wildcard projection, `_subquery_read_record`).
function _infer_kind(p::SubqueryObject, instruc::SQLInstruction, policy::_EveryKind)
  # #1121: a computed number's meaning, which the inner build recorded as its read kind.
  meant = _numeric_meaning_record(p, instruc, policy)
  meant === nothing || return meant
  recorded = instruc.subquery_all_kinds === nothing ? nothing : get(instruc.subquery_all_kinds, p, nothing)
  return recorded === nothing ? _subquery_read_record(p, instruc) : recorded
end
# A predicate is a boolean. The read kind leaves it to the formatter bridge (#965), which reads it here.
_infer_kind(::Union{ExistsObject,SQLTypeQ,SQLTypeQor}, ::SQLInstruction, ::_EveryKind) = CBool()
_infer_kind(::Any, ::SQLInstruction, ::_EveryKind) = nothing

# #1147: `+`, `-`, `*` and `/` over two integers is an integer on both engines — PostgreSQL resolves
# `int4 + int8` to `int8` and divides two integers as integers, as SQLite does — so the widest of the
# two is the kind (`_unify_kinds`). An integer literal is a `bigint` there (`$n::bigint`).
#
# #1150: arithmetic over a float or a decimal side is the wider of the two, as PostgreSQL resolves it
# (`integer < numeric < double precision`), and that is what the expression MEANS: `F("price") / 2`
# is a decimal quotient. SQLite can compute it otherwise — it stores a whole decimal as INTEGER and
# divides it as one — so its render casts the dividend (`_division_sql`); the kind is the meaning. A
# decimal's width is dropped: the operation may change it — except a whole one's, which `+`, `-` and
# `*` keep whole (#1550, below). A date or an interval side is temporal
# arithmetic, which `_temporal_arith_kind` answers first.
#
# #1153: the bitwise operators resolve their type as arithmetic does (`int4 & int8` is `int8`), and
# `~` has its operand's. A shift has its LEFT operand's type, whatever it shifts by, and binds an
# integer literal on either side as `::integer` (`_set_update_query_left`), so `1 << F("n")` is an
# `integer`. SQLite computes every one of them as a 64-bit integer; the walk keeps PostgreSQL's
# shape on both engines, as it does for `+`, `-`, `*` and `/`.
function _operation_kind(p::FExpression, instruc::SQLInstruction, policy::_EveryKind)
  p.operation in _COMPARISON_OPERATIONS && return CBool()
  # #1034 step 5a: temporal arithmetic is the kind its render gives it (below), on every policy.
  temporal = _memo_kind(() -> _temporal_arith_kind(p, instruc), p, instruc, :render)
  temporal === nothing || return temporal
  p.operation == "~" && return _integer_side_kind(p.field_name, instruc, policy)
  if p.operation in ("<<", ">>")
    _integer_side_kind(p.operand, instruc, policy) === nothing && return nothing
    shifted = p.field_name
    return shifted isa Integer && !(shifted isa Bool) ? CInt32() : _integer_side_kind(shifted, instruc, policy)
  end
  if p.operation in ("&", "|", "xor")
    left = _integer_side_kind(p.field_name, instruc, policy)
    right = _integer_side_kind(p.operand, instruc, policy)
    return left === nothing || right === nothing ? nothing : _unify_kinds(left, right, policy)
  end
  p.operation in ("+", "-", "*", "/") || return nothing
  left = _arithmetic_side_kind(p.field_name, instruc, policy)
  _numeric_rank(left) === nothing && return nothing
  right = _arithmetic_side_kind(p.operand, instruc, policy)
  _numeric_rank(right) === nothing && return nothing
  kind = _unify_kinds(left, right, policy)
  kind isa CDecimal || return kind
  # #1550: a whole decimal stays whole through `+`, `-` and `*` — `numeric(4,0) + 1` is scale 0 on
  # PostgreSQL and MySQL, and SQLite stores a zero-scale decimal as an INTEGER and adds it as one. Any
  # other scale is dropped: SQLite computes it as a REAL, where `0.1 + 0.2` gains digits.
  whole = p.operation in ("+", "-", "*") && _whole_kind(left) && _whole_kind(right)
  return CDecimal(nothing, whole ? 0 : nothing)
end
_arithmetic_side_kind(x::Integer, ::SQLInstruction, policy::_EveryKind) = x isa Bool ? nothing : _literal_kind(x, policy)
_arithmetic_side_kind(x::Union{AbstractFloat,Decimals.Decimal}, ::SQLInstruction, policy::_EveryKind) = _literal_kind(x, policy)
_arithmetic_side_kind(x, instruc::SQLInstruction, policy::_EveryKind) = _infer_kind(x, instruc, policy)
_integer_side_kind(x, instruc::SQLInstruction, policy::_EveryKind) =
  (k = _arithmetic_side_kind(x, instruc, policy); k isa Union{CInt16,CInt32,CInt64} ? k : nothing)

# ── #1034 step 5a: F temporal arithmetic ─────────────────────────────────────────────────────────────
# `date - date`, `timestamp - timestamp`, a date shifted by a duration, a day count or an interval, and
# interval arithmetic are typed by one rule, `_temporal_result_kind` (#1034 step 5b), from what each
# side is to the render. The render (`_render_expr_typed`, `expression_render.jl`) asks it over the
# sides it rendered; the walk asks it here, without rendering, over the sides `_render_side_kind` types.
# The side readers under it (`_side_kind`, `_side_function_kind`, `_day_count_column_kind`,
# `_is_number_side`) are narrower than the walk on purpose: a float column or a numeric sub-expression
# is no kind to them (#882, #881, #536).
#
# Every answer is a temporal kind or the `CInt32` day count of `date - date`; everything else is
# `nothing`, which leaves numeric arithmetic to the rules above it. A shape the render refuses has no
# answer to agree with, so it is `nothing` too. On SQLite the render holds an interval as milliseconds
# while it computes (`_IntervalMs`); the value it leaves is the interval, which is the kind here.
function _temporal_arith_kind(p::FExpression, instruc::SQLInstruction)::Union{CanonicalType,Nothing}
  op = p.operation
  if op === nothing
    f = p.field_name
    f isa String && return _side_kind(f, instruc)
    f isa Integer && return nothing
    return _render_side_kind(f, instruc)
  end
  op in ("+", "-", "*", "/") || return nothing
  left = _render_side_kind(p.field_name, instruc)
  right = p.operand isa Union{Dates.Period,Dates.CompoundPeriod,Interval} ? nothing :
          _render_side_kind(p.operand, instruc; right = true)
  return _temporal_result_kind(p, left, right, instruc)
end

# #1034 step 5b — THE ONE COPY of the rule: the kind F arithmetic `p` has, from what its two sides are
# to the render, `left` and `right` as `_render_side_kind` names them (an interval SQLite holds in
# milliseconds is an interval here). The walk calls it over the sides it types (`_temporal_arith_kind`),
# and the render over the sides it rendered (`_arith_result_kind`, `expression_render.jl`), so the
# kind the SQL is written for and the kind every other reader sees cannot drift apart. `right` is not
# read for a duration operand (a Julia period), which has no side kind.
function _temporal_result_kind(p::FExpression, left, right, instruc::SQLInstruction)::Union{CanonicalType,Nothing}
  op = p.operation
  # The duration spelling (#25): the left shifted by a Julia period, whatever the left is.
  if op in ("+", "-") && p.operand isa Union{Dates.Period,Dates.CompoundPeriod,Interval}
    period = p.operand isa Interval ? p.operand.period : p.operand
    return _shift_result_kind(left, _decompose_period(period))
  end
  # #568: a bare integer beside a date is whole days.
  if left isa Union{CDate,CDateTime} && op in ("+", "-") && p.operand isa Integer && !(p.operand isa Bool)
    return _shift_result_kind(left, _decompose_period(Dates.Day(p.operand)))
  end
  if left isa Union{CDate,CDateTime}
    p.operand isa String && !_is_field_path(p.operand, instruc) && return nothing   # refused (#814)
    op in ("+", "-") && (right = _day_count_column_kind(p.operand, right, instruc))   # #882
    right isa Union{CDate,CDateTime} && return op == "-" ? _difference_result_kind(left, right) : nothing
    op in ("+", "-") || return nothing
    right isa Union{CInt32,CInt64} && return left                               # a day count (#814)
    right isa CInterval && return left isa CDate ? CDateTime(false) : left       # #881
    return nothing
  end
  left isa CInterval && return _interval_left_kind(p, right, instruc)
  # #1406: a time of day minus a time of day is an interval where the engine computes it.
  if left isa CTime
    return op == "-" && right isa CTime && _subtracts_times(instruc.connection) ? CInterval() : nothing
  end
  # #814: a day count on the left, a date on the right, is the date shifted (`count - date` is refused).
  count = op in ("+", "-") ? _day_count_column_kind(p.field_name, left, instruc) : left
  if count isa Union{CInt32,CInt64} && op in ("+", "-")
    return right isa Union{CDate,CDateTime} && op == "+" ? right : nothing
  end
  # #881: an interval on the right of a value that is neither a date nor an interval.
  if _typed_right_operand(p.operand, instruc)
    right isa CInterval && op == "*" && _is_number_side(p.field_name, left, instruc) && return CInterval()
  end
  return nothing
end

# Whether the right side of F arithmetic or an ordering is typed when its left is neither a date nor an
# interval: an expression, a function, a window function or a field path. The render
# (`_render_expr_typed`) and the walk above both ask it, so the two cannot type different right sides.
# A window function was missing from both until #1465: `F("grid") * Lag(<duration>)` was untyped, so
# SQLite multiplied the duration's `HH:MM:SS` text while `Lag(<duration>) * F("grid")` was refused.
_typed_right_operand(x, instruc::SQLInstruction) =
  x isa Union{FExpression,FObject,WindowFunction} || (x isa String && _is_field_path(x, instruc))

# #881: an interval on the left (`_render_interval_left`). A date on the right of `+` is the date
# shifted, an interval beside it is an interval, and `*`/`/` by a number side scales it.
function _interval_left_kind(p::FExpression, right, instruc::SQLInstruction)
  if p.operation in ("+", "-")
    right isa Union{CDate,CDateTime} && return p.operation == "+" ? (right isa CDate ? CDateTime(false) : right) : nothing
    return right isa CInterval ? CInterval() : nothing
  end
  return _is_number_side(p.operand, right, instruc) ? CInterval() : nothing
end

# The kind a side of F arithmetic is to the render: the left as `_render_left_typed` types it, the right
# as `_render_operand_typed` does. An expression is its own temporal kind. A function the walk names an
# interval is one (#1301): a `Max`/`Min`/`Sum`/`Avg` or `Greatest`/`Least`/`Coalesce` over interval
# candidates (`_interval_ms_candidate`, #894, #900), which SQLite computes in milliseconds
# (`_render_function_body`), and also one with no millisecond form — a `Case` over durations, a `Sum`
# of one. That one is typed so its arithmetic is: PostgreSQL computes `interval * bigint`, and SQLite,
# which holds it as its `HH:MM:SS` text, refuses it as an interval with no millisecond form (#881)
# rather than multiply the text (`'00:01:30' * 2` is `0`). A function the walk names a date or a
# timestamp is one too (#1307): a `Case` over dates, which `_side_function_kind` does not type, is then
# the date side of a shift, as a `DateField` column is. Any other function is `_side_function_kind`.
# A column is `_side_kind`. On the right, a temporal literal is its own kind, a field-path string is
# the column it names, a CTE handle is its column's kind (#1539: a CTE date beside a date, untyped, was
# the generic `-` on SQLite's text), and a bare `Subquery` or `Joined` handle is untyped, as it is to
# the render.
function _render_side_kind(x, instruc::SQLInstruction; right::Bool = false)::Union{CanonicalType,Nothing}
  x isa FExpression && return _memo_kind(() -> _temporal_arith_kind(x, instruc), x, instruc, :render)
  if x isa FObject
    walked = _infer_kind(x, instruc, _AllKinds())
    walked isa CInterval && return CInterval()
    # #1307: so is a date or a timestamp, the side of the date-shift arms (`_temporal_result_kind`).
    walked isa Union{CDate,CDateTime} && return walked
    return _side_function_kind(x, instruc)
  end
  right || return _side_kind(x, instruc)
  x isa String && return _is_field_path(x, instruc) ? _side_kind(x, instruc) : nothing
  x isa _TemporalLiteral && return literal_canonical_kind(x)
  return x isa Union{SQLTypeFunction,CTEReference} ? _side_kind(x, instruc) : nothing
end

# ── #1310: an operand the walk cannot name, beside a date, a timestamp, a time or an interval ─────────
# `_expression_kind` answers `nothing` for a value it cannot name: a JSON key lookup, a `Case` or a
# `Coalesce` whose values disagree, a function with no stated rule. Where the value only passes —
# projected, compared for equality, beside another number — that is harmless. Where the engine computes
# by what it stores (`_types_temporal_operands`), the SQL of arithmetic or an ordering beside a date or
# an interval is chosen by the type, and an unnamed side fell to the generic arm: SQLite multiplied a
# duration's text (#1301) and added to a date's (#1307). `_unnamed_temporal_side` names the side the
# render cannot type in such a shape, so it is refused before SQL is written for a type it may not have.

# A side as the walk names it. A bare literal is its own kind (the walk's `::Any` arm names none), a
# Julia period is an interval, and a string that is not a field path is a text literal, as the binder
# takes it. A NULL is never the value, so it is named (`_unnamed_side` skips it).
_side_walk_kind(x::Bool, ::SQLInstruction) = CBool()
_side_walk_kind(x::Union{Integer,AbstractFloat,Decimals.Decimal}, ::SQLInstruction) = _literal_kind(x, _AllKinds())
_side_walk_kind(::Union{Dates.Period,Dates.CompoundPeriod,Interval}, ::SQLInstruction) = CInterval()
_side_walk_kind(x::Union{_TemporalLiteral,Dates.Time}, ::SQLInstruction) = literal_canonical_kind(x)   # #1323: a Time too
_side_walk_kind(x::AbstractString, instruc::SQLInstruction) =
  x isa String && _is_field_path(x, instruc) ? _expression_kind(x, instruc) : CText()
# An `OuterRef` is the outer query's column, typed on the outer instruction, which rendered it when the
# reference resolved (`_get_filter_query(::OuterRefObject)`): `"date__@gt" => OuterRef("date")` is a
# date beside a date.
_side_walk_kind(x::OuterRefObject, instruc::SQLInstruction) =
  instruc.outer === nothing ? nothing : _side_walk_kind(x.field_name, instruc.outer)
_side_walk_kind(x, instruc::SQLInstruction) = _expression_kind(x, instruc)

# A JSON value counts as unnamed: a key lookup (`"payload__n"`) is the scalar at the key, whose type is
# the data's (`CJSONValue`, #1458), and a whole document is no date, interval or number either.
_unnamed_side(x, instruc::SQLInstruction) =
  !_is_null_literal(x isa SQLText ? x.field : x) &&
  (k = _side_walk_kind(x, instruc); k === nothing || k isa Union{CJSON,CJSONValue})
# #1323: a time of day too. SQLite holds it as its `HH:MM:SS` text and MySQL reads its digits as a
# number, so an unnamed value beside one, or holding one, is the same question as beside a date.
_is_temporal_kind(k) = k isa Union{CDate,CDateTime,CTime,CInterval}

"""
    _unnamed_temporal_side(left, right, instruc) -> Union{Nothing, Tuple{Any, CanonicalType}}

The side of arithmetic or an ordering over `left` and `right` that the type walk cannot name, when the
shape is temporal, with the temporal kind that makes it so: the other side is a date, a timestamp or an
interval, or the unnamed side holds one (`Case(<a JSON key or a duration>) * 2`). `nothing` otherwise.
A side that only holds a temporal value under a function that names its own result (`Extract`,
`Count`, a declared `Cast`) is not one: its value is that result. Read after both sides render, inside
one walk question (`_memo_kind`), so a node is walked once however many comparisons ask about it.
"""
function _unnamed_temporal_side(left, right, instruc::SQLInstruction)
  for (side, other) in ((left, right), (right, left))
    _unnamed_side(side, instruc) || continue
    k = _side_walk_kind(other, instruc)
    _is_temporal_kind(k) && return (side, k)
    held = _temporal_inside(side, instruc)
    held === nothing || return (side, held)
  end
  return nothing
end

# The date, timestamp or interval kind an unnamed value can be, or `nothing`: through the operands of
# arithmetic, of a function whose value is an operand's (`_result_rule` `:operand`, `:first_operand`,
# `:one_of`, `:promoting`, a `Lag`/`Lead` and its `default`), and of an undeclared `Case`'s branches. A
# declared type is the value's type, so it is not looked through. Memoized per node: a chain of
# arithmetic asks about each of its sub-expressions once per level.
function _held_temporal(x, instruc::SQLInstruction)
  _is_null_literal(x isa SQLText ? x.field : x) && return nothing
  k = _side_walk_kind(x, instruc)
  return _is_temporal_kind(k) ? k : _temporal_inside(x, instruc)
end
_first_held(values, instruc::SQLInstruction) =
  (for v in values; k = _held_temporal(v, instruc); k === nothing || return k; end; nothing)
_temporal_inside(p::FExpression, instruc::SQLInstruction) =
  p.operation in ("+", "-", "*", "/") ?
    _memo_kind(() -> _first_held((p.field_name, p.operand), instruc), p, instruc, :held_temporal) : nothing
_temporal_inside(p::Union{FObject,WindowFunction}, instruc::SQLInstruction) =
  _memo_kind(() -> _function_held_temporal(p, instruc), p, instruc, :held_temporal)
_temporal_inside(::Any, ::SQLInstruction) = nothing
function _function_held_temporal(p::Union{FObject,WindowFunction}, instruc::SQLInstruction)
  rule = _result_rule(p)
  if p isa FObject && rule in (:declared, :one_of)
    declared = _declared_cast(p)
    declared isa AbstractString && !isempty(declared) && return nothing
  end
  operands = Any[(p.column isa AbstractVector ? p.column : (p.column,))...]
  # A window value function's `default` is one of its values (`_with_window_default`); a string there
  # is a literal, not a path.
  default = p isa WindowFunction ? get(p.kwargs, "default", nothing) : nothing
  default === nothing || push!(operands, default isa AbstractString ? SQLText(default) : default)
  rule in (:operand, :promoting, :one_of) && return _first_held(operands, instruc)
  rule === :first_operand && return _held_temporal(first(operands), instruc)
  rule === :declared && p isa FObject && p.function_name == "CASE" && return _first_held(_case_values(p), instruc)
  return nothing
end

# ── Leaves: a column's field and a literal ───────────────────────────────────────────────────────────
_column_kind(f, ::_EveryKind) = _field_kind(f)

# Every type a field declares, by its `.type` — the string `Dialect` renders the column from, which is
# also what `field_canonical_kind` reads, so the two cannot disagree on the kinds that table owns.
function _field_kind(f::PormGField)::Union{CanonicalType,Nothing}
  owned = field_canonical_kind(f)
  owned === nothing || return owned
  t = f.type
  t == "BOOLEAN"  && return CBool()
  t == "SMALLINT" && return CInt16()
  t == "INTEGER"  && return CInt32()
  t == "INTEGER UNSIGNED" && return CInt32()   # `PositiveIntegerField`: an `integer` with a check
  t == "BIGINT"   && return CInt64()
  t == "FLOAT"    && return CFloat64()
  t == "VARCHAR"  && return CVarChar(hasfield(typeof(f), :max_length) ? getfield(f, :max_length) : nothing)
  t == "TEXT"     && return CText()
  t == "UUID"     && return CUUID()
  t == "JSONB"    && return CJSON()
  t == "BLOB"     && return CBytes()
  t == "TSVECTOR" && return CTsVector()
  t == "INET"     && return CInet()
  t == "CIDR"     && return CCidr()
  return nothing
end
_field_kind(::Any) = nothing

# #1034 phase 3 — the field that binds a value compared with a column of kind `k`: `_field_kind`'s
# inverse, for a column with no field of its own (a CTE column the body computes). A kind no field
# spells answers `nothing`. A decimal with no declared width is `DecimalField()`, whose width nothing
# reads for such a column: the read path takes the body's read kind (#1121), and the scale rule reads
# a declared width only on a model column (#1040).
_kind_field(::CBool) = Models.BooleanField()
_kind_field(::Union{CInt16,CInt32}) = Models.IntegerField()
_kind_field(::CInt64) = Models.BigIntegerField()
_kind_field(::CFloat64) = Models.FloatField()
_kind_field(k::CDecimal) = k.precision === nothing ? Models.DecimalField() :
  Models.DecimalField(max_digits = k.precision, decimal_places = something(k.scale, 0))
_kind_field(::CText) = Models.TextField()
_kind_field(k::CVarChar) = k.length === nothing ? Models.TextField() : Models.CharField(max_length = k.length)
_kind_field(::CDate) = Models.DateField()
_kind_field(k::CDateTime) = Models.DateTimeField(type = k.with_timezone ? "TIMESTAMPTZ" : "TIMESTAMP")
_kind_field(::CTime) = Models.TimeField()
_kind_field(::CInterval) = Models.DurationField()
_kind_field(::CUUID) = Models.UUIDField()
_kind_field(::CJSON) = Models.JSONField()
_kind_field(::CJSONValue) = Models.JSONField()   # #1458: the key's own column, so the JSON formatter (#1382)
_kind_field(::Any) = nothing
# #1034 step 4 — the formatter view: what a value compared with an expression of kind `k` must
# satisfy (`_expression_formatter`, `projection_types.jl`). A number of any width takes the number
# formatter and any text the text one; a date, timestamp, time, interval or decimal takes the
# representation table's (`value_formatter`, the field formatters themselves). An array names none:
# its formatter holds the element field's rules, which only a column has. An instruction over a
# declaration alone has no engine to ask, and names none either.
_kind_formatter(::CBool, ::SQLInstruction) = Models.format_bool_sql
_kind_formatter(::Union{CInt16,CInt32,CInt64,CFloat64}, ::SQLInstruction) = Models.format_number_sql
_kind_formatter(::Union{CText,CVarChar}, ::SQLInstruction) = Models.format_text_sql
_kind_formatter(::CArray, ::SQLInstruction) = nothing
_kind_formatter(k::CanonicalType, instruc::SQLInstruction) =
  instruc.connection === nothing ? nothing : value_formatter(k, instruc.connection)
_kind_formatter(::Nothing, ::SQLInstruction) = nothing
# The family a field and a kind agree on: every integer width is one, and so is every text, every
# decimal width and both timestamps; any other kind is its own.
_kind_family(::Union{CInt16,CInt32,CInt64}) = CInt64
_kind_family(::Union{CText,CVarChar}) = CText
_kind_family(k::CanonicalType) = typeof(k)
_kind_family(::Nothing) = nothing

_literal_kind(::Bool, ::_EveryKind) = CBool()
_literal_kind(::Integer, ::_EveryKind) = CInt64()
_literal_kind(::AbstractFloat, ::_EveryKind) = CFloat64()
_literal_kind(::Decimals.Decimal, ::_EveryKind) = CDecimal(nothing, nothing)   # a bound value has no declared width
_literal_kind(::AbstractString, ::_EveryKind) = CText()
_literal_kind(x, ::_EveryKind) = literal_canonical_kind(x)

# ── Functions, by their `_result_rule` ───────────────────────────────────────────────────────────────
# Every kind: a declared cast is the type (#852, and `Case`'s `output_field`), then the rule.
function _infer_function_kind(p::Union{FObject,WindowFunction}, instruc::SQLInstruction, policy::_EveryKind)
  rule = _result_rule(p)
  if p isa FObject && rule in (:declared, :one_of)
    declared = _declared_cast(p)
    declared isa AbstractString && !isempty(declared) && return _declared_kind(declared, instruc.connection)
  end
  rule isa CanonicalType && return rule
  # #1147: a date part both engines compute as an integer (`_integer_transform`) is one, whatever its
  # operand. Its rule stays `:unknown` until phase 3 states it, so the read kind is unchanged.
  _integer_transform(p) && return _integer_transform_kind(instruc.connection)
  # #1457, #1552: `EPOCH`, `MILLISECONDS`, `MICROSECONDS` and `JULIAN` are decimals on every engine
  # that has them (`_decimal_extract_kind`).
  decimal = _decimal_extract_kind(p, instruc, policy)
  decimal === nothing || return decimal
  rule === :operand && return _with_window_default(p, _infer_kind(p.column, instruc, policy), instruc, policy)
  rule === :first_operand && return _infer_kind(first(p.column), instruc, policy)
  rule === :one_of && return _agreeing_kind(p, instruc, policy)
  rule in (:promoting, :numeric) && return _number_kind(p, rule, instruc, policy)
  rule === :declared && p isa FObject && p.function_name == "CASE" && return _case_kind(p, instruc, policy)
  return nothing
end
_infer_function_kind(::Any, ::SQLInstruction, ::_EveryKind) = nothing

# A `Lag`/`Lead` `default` is one of the window's values too: PostgreSQL resolves `lag(int4, int,
# float8)` to a `float8` and `lag(int4, int, int8)` to an `int8` (review of #1147), so the operand's
# kind and the default's are unified as a `COALESCE`'s are. A string is a bound text literal there,
# not a path (`_case_kind`); any other default PormG cannot type leaves the value untyped.
function _with_window_default(p, kind, instruc::SQLInstruction, policy::_EveryKind)
  (p isa WindowFunction && kind !== nothing) || return kind
  default = get(p.kwargs, "default", nothing)
  default === nothing && return kind
  literal = default isa SQLText ? default.field : default
  # A NULL default is never the value (`lag(int4, int, NULL)` is an `int4`): skipped, as `_agreeing_kind`
  # skips a NULL operand.
  _is_null_literal(literal) && return kind
  k = literal isa Union{SQLObject,SQLType} ? _infer_kind(literal, instruc, policy) : _literal_kind(literal, policy)
  return k === nothing ? nothing : _unify_kinds(kind, k, policy)
end

# The integer an integer date part is on the engine: PostgreSQL renders `EXTRACT(…)::integer` (and
# `QUARTER`/`QUADRIMESTER`/`WEEK_DAY` as an `integer` too), SQLite computes a 64-bit integer.
_integer_transform_kind(::PormGPostgres) = CInt32()
_integer_transform_kind(::PormGSQLite) = CInt64()
# MySQL (#1130 phase 2c-3a): `EXTRACT`, `QUARTER`, `DAYOFWEEK`, … are an INT, which MySQL.jl hands back
# as an `Int64` (measured on 8.4).
_integer_transform_kind(::PormGMySQL) = CInt64()
_integer_transform_kind(::Any) = nothing

"""
    _integer_operand_kind(p, instruc) -> Union{CInt16, CInt32, CInt64, Nothing}

The integer kind of `p`'s first operand on `instruc`'s engine, or `nothing` when it is not one PormG
can name. `Abs`/`Floor`/`Ceil` keep it (#1147), and so does `Round` (#1196): `Dialect` renders them
over that integer, not over `(x)::numeric`. Their `_computed_kind` methods answer the same kind from the same walk of the same
operand, so the SQL and the walk agree by construction. Read after the operand renders.
"""
function _integer_operand_kind(p::SQLTypeFunction, instruc::SQLInstruction)
  k = _infer_kind(_first_operand(p), instruc, _AllKinds())
  return k isa Union{CInt16,CInt32,CInt64} ? k : nothing
end

"""
    _sums_bigint(p, instruc) -> Bool

Whether the `Sum` `p` adds up `bigint` values, by the walk (`CInt64`): its operand is a `bigint`
column, an integer literal, an integer `Case`, `Count`, or integer arithmetic over one. PostgreSQL
widens that sum to `numeric`, so `Dialect.SUM` renders it `::bigint` there (#1147 step 2), and
`_computed_kind(::Val{:SUM}, …)` answers `CInt64` from the same walk. A `sum(smallint|integer)` is a
`bigint` already. Read after the operand renders.
"""
_sums_bigint(p::SQLTypeFunction, instruc::SQLInstruction) =
  _infer_kind(_first_operand(p), instruc, _AllKinds()) isa CInt64

_declared_cast(p::FObject) = get(p.kwargs, p.function_name == "CAST" ? "type" : "output_field", nothing)
_first_operand(p::SQLTypeFunction) = p.column isa AbstractVector ? first(p.column) : p.column

# The kind a declared type names on the engine. `_sql_type_field` maps a type NAME to a field and drops
# its size, so the size is read here: `numeric(10,2)` is `CDecimal(10, 2)`, a bare `numeric` has no
# width, and `smallint` is not an `integer`. A `real` is a `CFloat64`: no kind names a 4-byte float.
# #1258: so `CFloat64` stands for both widths here, while PostgreSQL's driver returns a `Float32` for
# a `real` (SQLite refuses the cast, #1215). Every reader is indifferent to the width: the read view
# records no declared float (only arithmetic over one, which means a float, #1121, and whose parser
# returns a `Float32` unchanged), a pattern lookup refuses either as an inexact number, `Concat` and
# the casts classify either as a float, and a CTE column over it is a `FloatField`, which binds either.
# A reader that must tell the widths apart is the point to add a `CFloat32`.
# On SQLite a uuid or network cast renders `CAST(x AS TEXT)` (`_declared_type_formatter`), so it is text.
#
# #1439: a one-dimensional array of an element an `ArrayField` can declare is `CArray(element)`, read
# back by the parser an `ArrayField` column has (`value_parser(::CArray, …)`), so `"varchar[]"` reads a
# `Vector{String}` on both PostgreSQL drivers instead of LibPQ's `{…}` literal. Any other array names
# nothing and arrives as the driver hands it over: `CArray` is one-dimensional, and `smallint[]` and
# `real[]` are arrays PormG never writes (a `real` element is a `Float32`, which `CFloat64` would widen,
# #1258). `_sql_type_field` still answers `nothing` for an array (#852): both of its readers take its
# field for a scalar. SQLite and MySQL refuse an array cast before this is read.
# The suffix is the last `[]` (or `[n]`) only, so `integer[][]` reads its element as `integer[]`, a
# `CArray`, which is no `_ArrayElementKind`.
const _ONE_ARRAY_SUFFIX = r"^\s*(.*?)\s*\[\s*\d*\s*\]\s*$"
function _declared_kind(type_name::AbstractString, conn)::Union{CanonicalType,Nothing}
  array = Base.endswith(rstrip(type_name), ']') ? match(_ONE_ARRAY_SUFFIX, type_name) : nothing
  if array !== nothing
    _single_precision_cast(strip(array.captures[1])) && return nothing
    element = _declared_kind(array.captures[1], conn)
    return element isa _ArrayElementKind ? CArray(element) : nothing
  end
  size = _numeric_cast_size(type_name)
  size === nothing || return CDecimal(size...)
  field = _sql_type_field(type_name)
  field === nothing && return nothing
  _cast_renders_text(field, conn) && return CText()
  field isa Models.sDecimalField && return CDecimal(nothing, nothing)
  lowercase(strip(first(split(type_name, '(')))) in ("smallint", "int2") && return CInt16()
  if field isa Models.sCharField
    m = match(r"\((\d+)\)$", type_name)
    return CVarChar(m === nothing ? nothing : parse(Int, m.captures[1]))
  end
  return _field_kind(field)
end

# #824 — the kind of a function whose value is one of several operands' own values. Typed only on
# agreement: every operand names a kind, and the kinds unify as PostgreSQL resolves a `COALESCE`
# (`_unify_kinds`). An operand with no kind — arithmetic, a function PormG does not type —
# disqualifies the whole projection: the value may be that operand's, and a kind taken from the others
# would run text through a date parser (`Coalesce("note", Date(…))`). A NULL literal is skipped: it is
# never the value. A declared `output_field` never reaches here: `_infer_function_kind` answers it
# first, as the cast it renders (#852).
function _agreeing_kind(p::FObject, instruc::SQLInstruction, policy::_EveryKind)::Union{CanonicalType,Nothing}
  kind = nothing
  for operand in (p.column isa AbstractVector ? p.column : (p.column,))
    _is_null_literal(operand isa SQLText ? operand.field : operand) && continue   # the #812 `Case` rule
    k = _infer_kind(operand, instruc, policy)
    k === nothing && return nothing
    kind = kind === nothing ? k : _unify_kinds(kind, k, policy)
    kind === nothing && return nothing
  end
  return kind
end

# Two operands' kinds as one value's, as PostgreSQL resolves a `COALESCE`/`CASE`: integers widen,
# `integer` < `numeric` < `double precision`, and text is text whatever its length.
function _unify_kinds(a::CanonicalType, b::CanonicalType, ::_EveryKind)
  a == b && return a
  ra, rb = _numeric_rank(a), _numeric_rank(b)
  if ra !== nothing && rb !== nothing
    r = max(ra, rb)
    r == 3 && return _unify_decimals(a, b)
    return r == 4 ? CFloat64() : r == 2 ? CInt64() : r == 1 ? CInt32() : CInt16()
  end
  a isa Union{CText,CVarChar} && b isa Union{CText,CVarChar} && return CText()
  return nothing
end
# #1550: a `Case`/`Coalesce` over decimals that agree on their places keeps them, as each row is one of
# those values (an integer has none): `Case(…, then = "grid", default = 0)` over a zero-scale `grid` is
# whole, as `grid` is. The precision is kept only where both declare the same one.
function _unify_decimals(a::CanonicalType, b::CanonicalType)
  sa, sb = _kind_scale(a), _kind_scale(b)
  (sa === nothing || sa != sb) && return CDecimal(nothing, nothing)
  pa, pb = a isa CDecimal ? a.precision : nothing, b isa CDecimal ? b.precision : nothing
  return CDecimal(pa == pb ? pa : nothing, sa)
end
# The declared scale of a numeric kind (an integer has none to carry: 0). Not `_decimal_scale`, the
# places a literal needs (`projection_types.jl`).
_kind_scale(k::CDecimal) = k.scale
_kind_scale(::Union{CInt16,CInt32,CInt64}) = 0
_numeric_rank(::CInt16) = 0
_numeric_rank(::CInt32) = 1
_numeric_rank(::CInt64) = 2
_numeric_rank(::CDecimal) = 3
_numeric_rank(::CFloat64) = 4
_numeric_rank(::Any) = nothing

# A computed number's kind on the engine, from its rule and its (first) operand's kind `k` — the
# engine-dependent results #1034 asks to state once, as data. What `Dialect` renders decides:
#
# - PostgreSQL renders every `:numeric` function over `(x)::numeric`, so the value is a `numeric`
#   whatever the operand; so are `Abs`/`Floor`/`Ceil`, except over an integer, which they keep
#   (#1147: their methods beside their constructors override this, `_integer_operand_kind`), and so is
#   `Round` (#1196);
# - SQLite renders them bare: a `:promoting` function keeps its operand's type (an integer stays one,
#   #1087) and a `:numeric` one answers a REAL (`Mod(7, 3)` reads `1.0`, #1027) — except `Round` over
#   an integer, which renders the integer itself (#1196).
#
# `Sum` and `Avg` render bare on both engines and take each engine's aggregate type, so their methods
# override these, beside their constructors (`functions.jl`). A width the operation may change is
# dropped: a sum of `numeric(10,2)` values is not a `numeric(10,2)`.
_computed_kind(::Val, ::Symbol, k, ::PormGPostgres) = CDecimal(nothing, nothing)
_computed_kind(::Val, rule::Symbol, k, ::PormGSQLite) = rule === :numeric ? CFloat64() : _sqlite_number_kind(k)
# MySQL (#1130, measured on 8.4) renders them bare too. `SQRT`/`EXP`/`LN`/`POWER` are a DOUBLE over
# any operand; `FLOOR`/`CEIL` a `BIGINT` over an integer, and over a decimal a `BIGINT` or a DECIMAL by
# its precision, which the width-less decimal names. `Abs`, `Round` and `Mod` keep more of their
# operand's type, beside their constructors (`functions.jl`).
_computed_kind(::Val, rule::Symbol, k, ::PormGMySQL) = rule === :numeric ? CFloat64() : _mysql_number_kind(k)
# A backend with no method here (#1034 phase 3 step 2a, #1129 item 2) gets a `MethodError` naming
# this fact rather than "unknown": what an engine computes is that engine's fact.
# A number SQLite computes over `k` without a cast: an integer is a 64-bit integer, and anything else
# is not a number this names. Over a `DecimalField` SQLite computes a REAL or an INTEGER from its
# NUMERIC-affinity storage; it is named a width-less decimal, the type PostgreSQL gives the same call.
# Its read parser (#1121, `value_parser(::CDecimal, ::PormGSQLite)`) builds that decimal from the
# double through 15 significant digits, Django's rule — never #648's exact parser, which only a
# column's declared width reaches.
_sqlite_number_kind(::Union{CInt16,CInt32,CInt64}) = CInt64()
_sqlite_number_kind(::CFloat64) = CFloat64()
_sqlite_number_kind(::CDecimal) = CDecimal(nothing, nothing)
_sqlite_number_kind(::Any) = nothing
# The same for a number MySQL computes over `k`: an integer function result is a `BIGINT`, a decimal
# one a DECIMAL whose width the operation may change, a float one a DOUBLE.
_mysql_number_kind(::Union{CInt16,CInt32,CInt64}) = CInt64()
_mysql_number_kind(::CFloat64) = CFloat64()
_mysql_number_kind(::CDecimal) = CDecimal(nothing, nothing)
_mysql_number_kind(::Any) = nothing

# A `:promoting`/`:numeric` function's kind: what this engine computes (`_computed_kind`, from the
# first operand), or what the call means (`_output_kind`, from every operand). An instruction over
# the declaration alone (`_declaration_instruction`) has no engine, so nothing is computed there.
_number_kind(p::SQLTypeFunction, rule::Symbol, instruc::SQLInstruction, policy::_AllKinds) =
  instruc.connection === nothing ? nothing :
  _computed_kind(Val(Symbol(p.function_name)), rule, _infer_kind(_first_operand(p), instruc, policy), instruc.connection)
function _number_kind(p::SQLTypeFunction, rule::Symbol, instruc::SQLInstruction, policy::_MeaningKinds)
  operands = p.column isa AbstractVector ? p.column : (p.column,)
  return _output_kind(Val(Symbol(p.function_name)), rule, [_arithmetic_side_kind(o, instruc, policy) for o in operands])
end

# #1121 — what a computed number MEANS, from its operands' kinds `ks`: Django's `output_field`, the
# same on every engine. PostgreSQL's `numeric` and SQLite's REAL are two engines computing it; the
# read path turns either into this (`_read_kind`).
#
# - `:promoting` (`Sum`, `Abs`, `Floor`, `Ceil`) — its operand's type, as a Django `Transform` or `Sum`
#   is. A decimal's width is dropped: the operation may change it;
# - `:numeric` (`Avg`, `Mod`, `Power`, `Sqrt`, `Exp`, `Ln`) — Django's `NumericOutputFieldMixin`: a
#   decimal when an operand is one, otherwise a float, so `Avg("grid")` and `Mod("grid", 2)` are
#   floats. `Round` keeps its operand's type, beside its constructor (`functions.jl`).
#
# An interval stays one (`Sum`/`Avg` of a duration). Any other operand names nothing.
function _output_kind(::Val, rule::Symbol, ks)
  rule === :promoting && return _operand_meaning(first(ks))
  length(ks) == 1 && only(ks) isa CInterval && return only(ks)
  all(k -> _numeric_rank(k) !== nothing, ks) || return nothing
  return any(k -> k isa CDecimal, ks) ? CDecimal(nothing, nothing) : CFloat64()
end
_operand_meaning(k::Union{CInt16,CInt32,CInt64,CFloat64,CInterval}) = k
_operand_meaning(::CDecimal) = CDecimal(nothing, nothing)
_operand_meaning(::Any) = nothing

# ── #1034 phase 3 step 3: the read view ──────────────────────────────────────────────────────────────
# The read path records a kind per projection (`projection_kinds`, #564) so that a read parser can undo
# what one engine did to the value: SQLite's stored text for a date, a time, a timestamp or an interval,
# its 0/1 for a boolean, its REAL for a decimal (`value_parser`, `value_repr.jl`). That kind used to be
# assembled at each projection site from five sources — a read-kind policy of the walk (deleted by
# #1459), the column lookup, the formatter's boolean, the record of a `Subquery`, and the numeric read
# kind (#1121) — each written for one shape (#564, #800, #824, #888, #965, #979, #1121). It is now one
# view of the walk.
#
# The view keeps the kinds a parser undoes and drops the rest: an integer, a float column, text, JSON or
# a uuid reads as the driver delivers it (#882's reason, now a filter rather than a gap in the walk).

# The kinds a STORED value is read as: one a column holds, or one of its operands' own values (`Max`,
# `Coalesce` over columns that agree, #824). A decimal keeps its declared width for #648's exact parser;
# one with no width is never a column.
_stored_read_view(k::Union{CDate,CDateTime,CTime,CInterval,CBool,CArray}) = k
_stored_read_view(k::CDecimal) = k.precision === nothing ? nothing : k
_stored_read_view(::Any) = nothing

"""
    _read_kind(x, instruc; rendered = nothing) -> Union{CanonicalType, Nothing}

The kind the read path records for the projection `x` (#564), or `nothing` when no read parser has
anything to undo. `rendered` is the kind the render itself computed: temporal arithmetic
(`_set_update_query_typed`, whose kind is the walk's one copy since #1034 step 5b) and an interval
aggregate SQLite held in milliseconds (`_render_function_typed`). It answers first, ahead of the view,
so a day count records the `CInt32` the view would drop. Otherwise:

- a literal is its Julia value's kind (#721), and a `Bool` a boolean (#1122);
- a `Subquery` or a CTE column reads as its own build recorded it, by this same view (#888, #824);
- anything else is what the walk says it means (`_MeaningKinds`), through the view: a computed number is
  the float or the width-less decimal it means (#1121, #1212), and a stored value keeps its kind. A
  `Case` with no `output_field` is one of its branch values on each row, so it has the kind its values
  agree on, as `Coalesce` has (#824, #1262), and none when they disagree.

Read after `x` renders, as every kind lookup here is: resolving a path fills the memo the walk reads.
"""
function _read_kind(x, instruc::SQLInstruction; rendered = nothing)
  rendered === nothing || return rendered
  x isa SQLText && return _literal_read_kind(x.field)
  recorded = _recorded_read_kind(x, instruc)
  recorded === false || return recorded
  # A window value function (`Lag`, `Lead`) returns a row's value of its operand, and its `default` only
  # stands in on the rows that have none: Django gives it its expression's `output_field`. So a stored
  # value reads as its operand's — `Lag("points", default = 0)` keeps the column's decimal width (#648) —
  # and only a computed number reads as what the whole call means, default included (#1121).
  if x isa WindowFunction && haskey(x.kwargs, "default") && _result_rule(x) === :operand &&
     !_computes_number(x, instruc)
    k = _read_kind(x.column, instruc)
    return _unapplied_window_default(x, k, instruc) ? _computed_meaning(k) : k
  end
  return _read_view(_infer_kind(x, instruc, _MeaningKinds()), x, instruc)
end

# #1110: on an engine whose read path applies a decimal's width (`_unapplied_decimal_width`), a
# `Lag`/`Lead` default is a value no column holds and no declaration covers: PostgreSQL's
# `lag(numeric(4,2), 1, 999)` is a plain `numeric` and returns `999`. So a decimal read with a default
# that is not NULL claims no width there, and the 15-digit parser reads both the column's values (the
# same `Decimal`s) and the default, which the width would round or refuse.
function _unapplied_window_default(x::WindowFunction, k, instruc::SQLInstruction)
  (k isa CDecimal && k.precision !== nothing && instruc.connection !== nothing) || return false
  _unapplied_decimal_width(instruc.connection) > 0 || return false
  default = x.kwargs["default"]
  return !_is_null_literal(default isa SQLText ? default.field : default)
end

function _literal_read_kind(x)
  k = literal_canonical_kind(x)
  k === nothing && x isa Bool && return CBool()
  return k
end

# The record a `Subquery`'s inner build or a CTE body made for its one column: that build's own read
# kind, by this view, so the two compose by construction. `false` for every other node. A CTE path that
# hops on through the column (`CTE("ev", "parent__x")`) ends at a real model field, and the walk reads it.
_recorded_read_kind(::Any, ::SQLInstruction) = false
_recorded_read_kind(p::SubqueryObject, instruc::SQLInstruction) =
  instruc.subquery_kinds === nothing ? nothing : get(instruc.subquery_kinds, p, nothing)
function _recorded_read_kind(ref::CTEReference, instruc::SQLInstruction)
  occursin("__", ref.path) && return false
  cte = get(instruc.object.ctes, ref.name, nothing)
  body = cte === nothing ? nothing : get(cte, "query", nothing)
  body isa SQLObjectHandler || return nothing
  return get(body.object.projection_kinds, Symbol(ref.path), nothing)
end

function _read_view(k, x, instruc::SQLInstruction)
  if k isa Union{CFloat64,CDecimal} && _computes_number(x, instruc)
    stored = _declared_stored_decimal(x, instruc)
    stored === nothing || return stored
    unapplied = _unapplied_declared_decimal(x, instruc)
    return unapplied === nothing ? _computed_meaning(k) : unapplied
  end
  if x isa Union{FObject,WindowFunction}
    # #965: a function's boolean is the one its FORMATTER names (`_is_boolean_valued`), as the render's
    # is: #953 renders PostgreSQL's `BOOL_OR` for an extremum only over a boolean-formatted operand.
    # Since #1034 step 4 the formatter is a view of this walk, so a condition as an operand is one
    # (`Max(Q(…))`, `Coalesce(Q(…), false)`), and the read kind, the render and the binder agree on it.
    _is_boolean_valued(x, instruc) && return CBool()
    k isa CBool && return nothing
  end
  return _stored_read_view(k)
end

# #1212: a value that is one of its operands' own (`Coalesce`, `Greatest`, `Least`) over columns that
# agree on one decimal, declared as that decimal, is a value SQLite stored, not one it computed: it keeps
# the columns' width and #648's exact parser (#824's agreement rule). Any operand of another kind — a
# literal, a column of another width — makes it the computed number its declaration means. The
# declaration is compared at the width it declares (`_declared_kind`, #1276): `numeric(12,4)` over
# `DecimalField(12, 4)` columns reads exactly, while `numeric(12,4)` over `(10, 2)` columns and a bare
# `numeric`, which declares no width, read as the computed number. Before #1276 it was compared by its
# type name's field, which drops the size, so any `numeric` counted as `DecimalField()`'s `(10, 2)`.
function _declared_stored_decimal(x, instruc::SQLInstruction)
  (x isa FObject && _result_rule(x) === :one_of) || return nothing
  declared = _declared_cast(x)
  (declared isa AbstractString && !isempty(declared)) || return nothing
  k = _declared_kind(declared, instruc.connection)
  (k isa CDecimal && k.precision !== nothing) || return nothing
  for operand in (x.column isa AbstractVector ? x.column : (x.column,))
    _is_null_literal(operand isa SQLText ? operand.field : operand) && continue
    _infer_kind(operand, instruc, _AllKinds()) == k || return nothing
  end
  return k
end

# #1110: a declared decimal the engine hands back without applying (`_unapplied_decimal_width`) keeps
# its width, so the read path applies it: `Cast("driverid", "numeric(2,0)")` reads `100` on SQLite,
# where PostgreSQL raises "numeric field overflow". Its parser rounds to the scale and raises on that
# row. An engine that applies the declaration itself records the width-less decimal (#1212).
function _unapplied_declared_decimal(x, instruc::SQLInstruction)
  (x isa FObject && instruc.connection !== nothing && _declares_decimal(x, instruc)) || return nothing
  k = _declared_kind(_declared_cast(x), instruc.connection)
  (k isa CDecimal && k.precision !== nothing && k.scale !== nothing) || return nothing
  return k.precision <= _unapplied_decimal_width(instruc.connection) ? k : nothing
end

# Whether `x`'s read kind is such a declaration, and not a value the engine stored at that width
# (`_declared_stored_decimal`, #1276). A CTE column or a `Subquery` over one keeps the answer its body
# recorded (`cte["unapplied"]`, `subquery_unapplied`). The plain projection of that column reads the
# width, but a value composed over it (`Coalesce(CTE("c", "v"), 0)`, `Max(Subquery(…))`) is the
# computed number the declaration means (#1212), and the comparison binder does not see it.
_reads_unapplied_declaration(::Any, ::SQLInstruction) = false
_reads_unapplied_declaration(x::FObject, instruc::SQLInstruction) =
  _unapplied_declared_decimal(x, instruc) !== nothing && _declared_stored_decimal(x, instruc) === nothing
_reads_unapplied_declaration(p::SubqueryObject, instruc::SQLInstruction) =
  instruc.subquery_unapplied !== nothing && haskey(instruc.subquery_unapplied, p)
function _reads_unapplied_declaration(ref::CTEReference, instruc::SQLInstruction)
  occursin("__", ref.path) && return false
  cte = get(instruc.object.ctes, ref.name, nothing)
  unapplied = cte === nothing ? nothing : get(cte, "unapplied", nothing)
  return unapplied isa Set{String} && ref.path in unapplied
end

# The numeric read view (#1121): the kinds the read path records for a computed number.
_numeric_view(k::CFloat64) = k
_numeric_view(k::CDecimal) = k.precision === nothing && k.scale === nothing ? k : nothing
_numeric_view(::Any) = nothing

# #1212: a computed number's decimal meaning claims no width. Only a declaration names one
# (`Cast(x, "numeric(10,2)")`, or a value over one, `Max(Cast(…))`), and the read path must not take it
# to a column's: #648's exact parser is for a value SQLite stored, not a double it computed.
_computed_meaning(k::CDecimal) = CDecimal(nothing, nothing)
_computed_meaning(k) = k

# A COMPUTED number (#1121): arithmetic, a `:promoting`/`:numeric` function, a function whose value is
# one of those (`Max(F("points") * 2)`, `Coalesce(Avg("grid"), 0)`, `NullIf`, a `Case` with no
# `output_field`), a declared decimal (`Cast(x, "numeric(10,2)")`, an `output_field` naming one, #1212),
# or a CTE column or `Subquery` whose own build recorded one. A column, a literal, or a `Coalesce`/`Case`
# over columns is not: each row is a value an operand already has, as the driver delivers it.
_computes_number(p::FExpression, ::SQLInstruction) = p.operation !== nothing
function _computes_number(p::Union{FObject,WindowFunction}, instruc::SQLInstruction)
  rule = _result_rule(p)
  rule in (:promoting, :numeric) && return true
  # #1212: a declared decimal — `Cast(x, "numeric(10,2)")`, `Coalesce(…; output_field = DecimalField())`
  # — is the number the caller said it means. Both engines render the cast, and SQLite still computes a
  # REAL (or an INTEGER, for a whole operand) where PostgreSQL's driver delivers a `Decimal`.
  p isa FObject && _declares_decimal(p, instruc) && return true
  rule === :operand && return _computes_number(p.column, instruc)
  # A value that is one of its operands' (review of #1121): `Coalesce(Avg("grid"), 0)` is the average
  # on the rows that have one, so it is a computed number when one of its values is. Any other declared
  # `output_field` is a cast both engines render, and its own business.
  (p isa FObject && !(get(p.kwargs, "output_field", nothing) isa AbstractString)) || return false
  rule === :first_operand && return _computes_number(first(p.column), instruc)
  rule === :one_of && return any(o -> _computes_number(o, instruc), p.column isa AbstractVector ? p.column : (p.column,))
  if rule === :declared && p.function_name == "CASE"
    branches = p.column isa AbstractVector ? p.column : (p.column,)
    values = Any[get(b.kwargs, "then", nothing) for b in branches if b isa SQLTypeFunction]
    push!(values, get(p.kwargs, "else", nothing))
    return any(v -> _computes_number(v, instruc), values)
  end
  return false
end
_computes_number(p::Union{CTEReference,SubqueryObject}, instruc::SQLInstruction) = _numeric_read_record(p, instruc) !== nothing
_computes_number(::Any, ::SQLInstruction) = false

# Whether `p` declares a decimal type: a `Cast`'s type or an `output_field`, read where
# `_infer_function_kind` reads one (rules `:declared` and `:one_of`), by the same `_declared_kind`.
function _declares_decimal(p::FObject, instruc::SQLInstruction)
  _result_rule(p) in (:declared, :one_of) || return false
  declared = _declared_cast(p)
  return declared isa AbstractString && !isempty(declared) && _declared_kind(declared, instruc.connection) isa CDecimal
end

# The numeric read kind a CTE body or a `Subquery`'s inner build recorded for its column: the meaning
# the outer query reads it as, and the one `_MeaningKinds` composes over it (`Abs(Subquery(…))`,
# `Max(CTE(…)) * 2`). A body value that is not a computed number has no such record, and the walk falls
# back to its `_AllKinds` record: what the engine computes, which is the column's own type for a column
# and differs per engine only for a number this view leaves out (`Round` over an integer).
function _numeric_read_record(x::Union{CTEReference,SubqueryObject}, instruc::SQLInstruction)
  recorded = _recorded_read_kind(x, instruc)
  recorded === false && return nothing
  # #1110: a declared width the read path applies is still the computed number it declares.
  _reads_unapplied_declaration(x, instruc) && return _computed_meaning(recorded)
  return _numeric_view(recorded)
end
_numeric_meaning_record(x, instruc::SQLInstruction, ::_MeaningKinds) = _numeric_read_record(x, instruc)
_numeric_meaning_record(x, ::SQLInstruction, ::_AllKinds) = nothing

# A read record's kind with its numeric read kind taken out (#1121): a computed number's numeric read
# kind is the READ path's (#882), so the walk does not take a number from a CTE body's or a
# `Subquery`'s read record when it falls back to one (`_cte_column_kind`, `_subquery_read_record`).
_without_numeric_read(k) = _numeric_view(k) === nothing ? k : nothing

# A `Case` with no `output_field`: its value is a branch's, so it has the kind its `then` values and
# its default agree on. A branch value that is a string is a literal, not a path (#965).
function _case_kind(p::FObject, instruc::SQLInstruction, policy::_EveryKind)
  values = Any[]
  for branch in (p.column isa AbstractVector ? p.column : (p.column,))
    (branch isa SQLTypeFunction && branch.function_name == "WHEN") || return nothing
    push!(values, get(branch.kwargs, "then", nothing))
  end
  push!(values, get(p.kwargs, "else", nothing))
  kind = nothing
  for value in values
    literal = value isa SQLText ? value.field : value
    _is_null_literal(literal) && continue
    k = value isa Union{SQLObject,SQLType} && !(value isa SQLText) ? _infer_kind(value, instruc, policy) :
        _literal_kind(literal, policy)
    k === nothing && return nothing
    kind = kind === nothing ? k : _unify_kinds(kind, k, policy)
    kind === nothing && return nothing
  end
  return kind
end

# #824 — the kind of a CTE column. The body is built before the outer query (`build_cte_clause`
# runs first), and building it recorded the kind of each of its own projections under the same
# output name the CTE model gives the column — so that record IS the answer, by the same rule, on the
# same connection: a plain column has its kind, `Max` its operand's, a `Cast(…, "date")` `CDate`, and
# `Avg`/`Sum`/`Count`/arithmetic none. A path that hops on through the CTE column
# (`CTE("ev", "parent__x")`) ends at a real model field, which the join walk memoised. No record —
# a body not built in this pass — answers `nothing`, the fail-open default.
#
# The CTE handle is NOT its inferred field: `_set_field_from_sql_function` hands an `Avg("amount")`
# column the operand's own `DecimalField`, which would run a computed double through the decimal
# parser (#648). The column is its expression's own type, which the body recorded while it could
# still resolve its paths (`cte["kinds"]`, #1147): a `Rank` is an integer there though it reads back
# with no kind to undo. A column the body's walk named nothing for falls back to the body's read
# record, without its numeric read kind (`_without_numeric_read`).
function _cte_column_kind(ref::CTEReference, instruc::SQLInstruction, policy::_EveryKind)::Union{CanonicalType,Nothing}
  if occursin("__", ref.path)
    column_field = _alias_column_field(ref, instruc)
    column_field === nothing && return nothing
    _json_key_value(column_field, instruc, memo_key(ref)) && return CJSONValue()   # #1458
    return _column_kind(column_field, policy)
  end
  meant = _numeric_meaning_record(ref, instruc, policy)
  meant === nothing || return meant
  cte = get(instruc.object.ctes, ref.name, nothing)
  cte === nothing && return nothing
  kind = _cte_expression_kind(cte, ref.path, policy)
  kind === nothing || return kind
  body = get(cte, "query", nothing)
  body isa SQLObjectHandler || return nothing
  _reads_unapplied_declaration(ref, instruc) && return nothing   # #1110: a numeric read kind
  return _without_numeric_read(get(body.object.projection_kinds, Symbol(ref.path), nothing))
end
function _cte_expression_kind(cte::AbstractDict, path::String, ::_EveryKind)
  kinds = get(cte, "kinds", nothing)
  return kinds isa AbstractDict ? get(kinds, path, nothing) : nothing
end

# #1153 — a `Subquery`'s one projected expression, typed by the walk over the INNER instruction while
# `query()` still holds it (its `built` callback), as `_subquery_projection_textless` classifies it:
# the inner memos are what resolve a joined path. Asked of the expression, not through
# `projection_kinds`, so the #979 memo-reuse path cannot lose it. Filed under the caller's node.
function _subquery_projection_kind(handler::SQLObjectHandler, inner::SQLInstruction)
  vals = handler.object.values
  length(vals) == 1 || return nothing
  v = only(vals)
  return _expression_kind(v isa SQLText ? v : v.field, inner)
end
# #1110: whether the subquery's one projection reads as a declaration the engine left unapplied,
# asked of the inner instruction in the same `built` window as its kind.
function _subquery_projection_unapplied(handler::SQLObjectHandler, inner::SQLInstruction)::Bool
  vals = handler.object.values
  length(vals) == 1 || return false
  v = only(vals)
  return _reads_unapplied_declaration(v isa SQLText ? v : v.field, inner)
end
function _record_subquery_unapplied!(instruc::SQLInstruction, p::SubqueryObject, unapplied::Bool)
  unapplied || return nothing
  instruc.subquery_unapplied === nothing && (instruc.subquery_unapplied = IdDict{SubqueryObject,Bool}())
  instruc.subquery_unapplied[p] = true
  return nothing
end
function _record_subquery_all_kind!(instruc::SQLInstruction, p::SubqueryObject, kind)
  kind isa CanonicalType || return nothing
  instruc.subquery_all_kinds === nothing && (instruc.subquery_all_kinds = IdDict{SubqueryObject,CanonicalType}())
  instruc.subquery_all_kinds[p] = kind
  return nothing
end
