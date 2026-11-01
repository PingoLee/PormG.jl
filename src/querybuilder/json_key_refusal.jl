# #1531 — ONE POINT for "an uncast JSON key's value is refused where a type is needed".
#
# Since #1458 (D1 of #1034) a JSON key's value is `CJSONValue`: a scalar the document types, row by
# row. It is accepted only in the comparisons the key lookup itself renders (`=`, `@ne`, the four
# orderings, `@isnull`); every position that needs a type refuses it, naming the cast. That rule was
# enforced one position at a time — six helpers called from thirteen sites across six files — and each
# new position meant one more bug (#1471 … #1511, then #1528 and #1529). This file states it once:
#
# - TWO PROBES, defined here and nowhere else. `_json_key_lookup_operand` asks the walk whether a value
#   IS a key's value (its kind is `CJSONValue`) — the one question a consumer asks to send a key down
#   the key lookup's comparison, so it is called from the comparison renders; `_json_number_side` asks
#   whether a value CARRIES one, and only this file asks it to refuse —
#   arithmetic over it, a function whose value is its operand's, a `Case` branch, a CTE column or a
#   `Subquery` over it, an `OuterRef` to it — which no kind can say: `Coalesce(key, 0)` has no
#   `CJSONValue` kind and still holds the key's value on the rows where it is set.
# - THE POSITIONS, as types (`_JSONKeyPosition`), each with the one refusal it raises
#   (`_json_key_refusal`). A position is where a value needs a type: arithmetic, an ordering, an
#   equality `NullIf` decides, a filter, an operator the key lookup has no comparison for.
# - ONE ENTRY POINT, `_refuse_uncast_json_key(position, operand, instruc)`: probe, then raise the
#   position's refusal. The consumers (`expression_render.jl`, `select_nodes.jl`, `build_select.jl`,
#   `filter_nodes.jl`, `filter_operators.jl`, `projection_types.jl`) call it and decide nothing.
#
# `test/unit/test_json_key_refusal_point.jl` fails on a `_json_number_side` call outside this file (the
# record writers excepted), a `CJSONValue` test outside it and the walk (`expression_kind.jl`), a
# refusal text written elsewhere, and a position with no refusal.

# ---------------------------------------------------------------------------------------------------
# The probes
# ---------------------------------------------------------------------------------------------------

# #1382 — whether an operand holds a JSON key's value: a key lookup (`payload__driver`), an `F` over
# one, or a CTE column whose body projects one. That is what a comparison or a filter on it compares —
# the key's value rather than the document. Its field is the JSONField all the same (`_render_json_lookup`
# memoizes it so), so the field alone cannot tell the two apart; the walk can (`CJSONValue`, #1458),
# from the record of rendered key lookups, and for a CTE column from the kind its body recorded. Decided
# by that evidence, never as "not known to be the document": a handle `_json_document_operand` lets
# through is not thereby a key.
_json_key_lookup_operand(p::SQLField, instruc::SQLInstruction) = _json_key_lookup_operand(p.field, instruc)
_json_key_lookup_operand(p::FExpression, instruc::SQLInstruction) =
  p.operation === nothing && _json_key_lookup_operand(p.field_name, instruc)
# #1492: a `Subquery` is its one projected column (#888), so one that projects a key lookup holds the
# key's value, as the walk names it from the inner build's record. An alias over it compared through the
# document's JSON formatter, which bound `100` as the text `"100"`.
_json_key_lookup_operand(p::Union{String,CTEReference,JoinedReference,SubqueryObject}, instruc::SQLInstruction) =
  _expression_kind(p, instruc) isa CJSONValue
_json_key_lookup_operand(::Any, ::SQLInstruction) = false

# #1471, #1483 — an operand whose value is a JSON key's value, uncast: the key itself, or a value that
# carries it — arithmetic over it, a function whose value is its operand's (`Floor`, `Ceil`, `Abs`,
# `Max`, `Min`, `Coalesce`, `Greatest`, `Least`, `Lag` and its `default`), a `Case` branch, `NullIf`'s
# first operand. A key's value has no declared type: the document decides, row by row, whether it is
# an integer, a float or text, so arithmetic on it and a `Sum`/`Avg` of it do not say which number they
# compute on. EXPLICIT INTENT, refused on every engine: SQLite divides the integer `json_extract` hands
# over as an integer (`7 / 2` is `3`), and PostgreSQL's `#>>` is text, which `+`, `/` and `sum` reject
# at the server. A declared type (`Cast`, an `output_field`) and a `numeric` function (`Round`, `Avg`)
# name the number and carry no key. `(what, flag)`: the operand as a refusal names it, and the key's
# path for the explicit spelling; or `nothing`.
#
# Three callers outside this file record its answer rather than refuse on it — a CTE column's
# (`_record_cte_division!`, `_record_cte_json_key!` in `ctes.jl`) and a `Subquery`'s
# (`_subquery_projection_json_key`, `projection_types.jl`) — because the outer query reads the record
# back here, where the body is no longer in hand. The guard test lists them.
_json_number_side(p::SQLField, instruc::SQLInstruction) = _json_number_side(p.field, instruc)
function _json_number_side(p::FExpression, instruc::SQLInstruction)
  p.operation === nothing && return _json_number_side(p.field_name, instruc)
  p.operation in ("+", "-", "*") || return nothing
  side = _json_number_side(p.field_name, instruc)
  side === nothing && (side = _json_number_side(p.operand, instruc))
  return side === nothing ? nothing : ("arithmetic over $(side[1])", side[2])
end
_json_number_side(p::Union{String,JoinedReference}, instruc::SQLInstruction) =
  _json_key_lookup_operand(p, instruc) ? ("the JSON key `$(_concat_operand_label(p))`", _concat_flag(p)) : nothing
# #1482: a CTE column is the key when it projects one (its kind is `CJSONValue`), and carries it when
# its body's expression does (`Coalesce(key, 0)`, a `Case` branch), which its kind cannot say: the body
# records that (`CTEDivision.json_key`).
function _json_number_side(p::CTEReference, instruc::SQLInstruction)
  # The body's record first: it names the key path a cast in the body takes (`Max(key)` and a bare
  # `"payload__n"` column both record `payload__n`). The kind answers for a column with no record.
  side = _cte_division(p, instruc, :json_key)
  side === nothing || return ("the CTE column `$(_concat_operand_label(p))` ($(side[1]))", side[2])
  _json_key_lookup_operand(p, instruc) || return nothing
  return ("the CTE column `$(_concat_operand_label(p))`, a JSON key's value", _concat_flag(p))
end
# An `OuterRef` is the outer query's column, typed on the outer instruction (as `_side_walk_kind` reads
# it), so `Coalesce(OuterRef("payload__n"), 0) / 2` inside a `Subquery` carries the outer key.
_json_number_side(p::OuterRefObject, instruc::SQLInstruction) =
  instruc.outer === nothing ? nothing :
  (side = _json_number_side(p.field_name, instruc.outer); side === nothing ? nothing :
   ("$(side[1]) of the outer query (an `OuterRef`)", side[2]))
# #1482: a `Subquery` carries the key when its one projection does, as the inner build recorded.
function _json_number_side(p::SubqueryObject, instruc::SQLInstruction)
  instruc.subquery_json_key === nothing && return nothing
  side = get(instruc.subquery_json_key, p, nothing)
  return side === nothing ? nothing : ("a Subquery projecting $(side[1])", side[2])
end
function _json_number_side(p::Union{FObject,WindowFunction}, instruc::SQLInstruction)
  name = p.function_name
  declared = get(p.kwargs, name == "CAST" ? "type" : "output_field", nothing)
  declared isa AbstractString && !isempty(declared) && return nothing
  if _undeclared_case(p)
    values = _case_values(p)
  else
    rule = _result_rule(p)
    rule in _OPERAND_TYPED_RULES || return nothing   # `SUM` is `:promoting`
    values = rule === :first_operand ? (_first_operand(p),) : p.column isa AbstractVector ? p.column : (p.column,)
  end
  for value in values
    side = _json_number_side(value, instruc)
    side === nothing || return ("`$(name)(…)` over $(side[1])", side[2])
  end
  # A `Lag`/`Lead` `default` is the value on the rows it applies to, as `_textless_number` reads it.
  if p isa WindowFunction
    default = get(p.kwargs, "default", nothing)
    literal = default isa SQLText ? default.field : default
    if !(literal === nothing || literal isa AbstractString || _is_null_literal(literal))
      side = _json_number_side(default, instruc)
      side === nothing || return ("`$(name)(…)` over $(side[1])", side[2])
    end
  end
  return nothing
end
_json_number_side(::Any, ::SQLInstruction) = nothing

# ---------------------------------------------------------------------------------------------------
# The positions — where a value needs a type
# ---------------------------------------------------------------------------------------------------

abstract type _JSONKeyPosition end

# A position is built on every render that asks, and refuses on few, so it holds the name as the
# render has it and the refusal spells it: `:plain` as is, `:quoted` in backticks (`` `+` ``), `:titled`
# title-cased (`SUM` → `Sum`). Building the spelling up front allocated a string on every arithmetic
# node and every aggregate, where the helpers this file replaced formatted only on a refusal.
_json_key_spelling(name::String, style::Symbol)::String =
  style === :quoted ? string("`", name, "`") : style === :titled ? titlecase(name) : name

# #1483 — arithmetic (`+ - * /`) over the value, and a `Sum`/`Avg` of it: the query does not say which
# number it computes on. `name` is the operation as the caller wrote it (`+`, quoted; `SUM`, titled).
struct _JSONKeyArithmetic <: _JSONKeyPosition
  name::String
  style::Symbol
end
# #1491 — a `Max`/`Min` computes nothing, but orders the value, and the query does not say whether as
# numbers or as text.
struct _JSONKeyExtremum <: _JSONKeyPosition
  name::String
  style::Symbol
end
# #1497 — an ordering term (`order_by`, a window's `order_by`) or a `Greatest`/`Least` operand, which
# orders the value as `Max` does. An `order_by` term takes a path or a projected name, not an
# expression, so it adds the `projected` spelling.
struct _JSONKeyOrdering <: _JSONKeyPosition
  name::String
  style::Symbol
  projected::Bool
end
# #1510 — `NullIf` compares its operands for equality. `comparing` is the operand's position, so the
# spelling casts the key where it sits: a cast in the first position would change which value `NullIf`
# returns.
struct _JSONKeyNullIf <: _JSONKeyPosition
  comparing::Int
end
# #1506 — a filter on a handle that carries the value without being the key: an alias over
# `Coalesce(key, 0)`, a `Case` branch or `NullIf(key, …)`, a `Subquery` projecting one; and (#1511) an
# expression comparison whose left carries it. The value bound through the handle's formatter (`"9"`,
# text), which SQLite's `json_extract` integer is never equal to nor greater than, so the filter matched
# no row; and PostgreSQL's `COALESCE(text, bigint)` is a server error. EXPLICIT INTENT, refused on every
# engine and whatever the right side is. The caller asks for the key first: a handle that IS the key
# compares as the key lookup (#1382). `@isnull` binds nothing and keeps its own arm.
# `comparison`: the label is the expression comparison itself, spelled from its operator on a refusal.
struct _JSONKeyCarrierFilter <: _JSONKeyPosition
  label::String
  operator::String
  comparison::Bool
end
_JSONKeyCarrierFilter(label::String, operator::String) = _JSONKeyCarrierFilter(label, operator, false)
# #1499 — an operator the key lookup has no comparison for (a membership list, a range, a pattern), on
# the key itself and on everything that holds its value.
struct _JSONKeyOperator <: _JSONKeyPosition
  operator::String
  label::String
end
# #811 — a column expression on the right of the key lookup: comparing extracted JSON against a column
# needs a per-engine cast nobody has designed.
struct _JSONKeyColumnRHS <: _JSONKeyPosition
  label::String
end

# #1528 — a key, or a value carrying one, on the RIGHT of a comparison: `F("constructorid") ==
# F("metadata__wins")`, `"constructorid" => F("metadata__wins")`, `F("grid") > Coalesce(key, 0)`. The key
# compares as its lookup does only on the left, against a value (#1511); on the right it was compared
# untyped — `bigint = text` on PostgreSQL, a server error, and `json_extract`'s native value on SQLite.
# EXPLICIT INTENT, refused on every engine in both spellings, as a column on the right of the key is
# (#811).
struct _JSONKeyRightOperand <: _JSONKeyPosition end

# Whether the position refuses at all for this use (a position may exempt an operator it renders).
_json_key_position_applies(::_JSONKeyPosition) = true
_json_key_position_applies(p::_JSONKeyCarrierFilter) = p.operator != "ISNULL"

# ---------------------------------------------------------------------------------------------------
# The refusals — one per position. `side` is `_json_number_side`'s `(what, key path)`.
# ---------------------------------------------------------------------------------------------------

function _json_key_refusal(p::_JSONKeyArithmetic, side::Tuple{String,String})
  return QueryBuildError(
    "\e[4m\e[31m$(_json_key_spelling(p.name, p.style))\e[0m over $(side[1]) is not supported: a JSON key's value has no declared type, " *
    "so the query does not say which number it computes on (#1483). Say the number type you mean: " *
    "\e[32mCast(\"$(side[2])\", \"numeric\")\e[0m keeps the fraction on every engine, and " *
    "\e[32mCast(\"$(side[2])\", BigIntegerField())\e[0m computes on integers.")
end

_json_key_ordering_refusal(what::String, side::Tuple{String,String}, issue::String, projected::Bool) =
  QueryBuildError(
    "\e[4m\e[31m$(what)\e[0m over $(side[1]) is not supported: a JSON key's value has no declared type, " *
    "so the query does not say whether it orders numbers or text ($(issue)). Say the type you mean: " *
    "\e[32mCast(\"$(side[2])\", \"numeric\")\e[0m orders numbers on every engine, and " *
    "\e[32mCast(\"$(side[2])\", \"text\")\e[0m orders text." *
    (projected ? " Project it and order by its name: \e[32mvalues(\"n\" => Cast(\"$(side[2])\", \"numeric\"))\e[0m, " *
                 "then \e[32morder_by(\"n\")\e[0m." : ""))
_json_key_refusal(p::_JSONKeyExtremum, side::Tuple{String,String}) =
  _json_key_ordering_refusal(_json_key_spelling(p.name, p.style), side, "#1491", false)
_json_key_refusal(p::_JSONKeyOrdering, side::Tuple{String,String}) =
  _json_key_ordering_refusal(_json_key_spelling(p.name, p.style), side, "#1497", p.projected)

function _json_key_refusal(p::_JSONKeyNullIf, side::Tuple{String,String})
  flag = side[2]
  spell(type, other) = p.comparing == 1 ? "NullIf(Cast(\"$(flag)\", \"$(type)\"), $(other))" :
                                          "NullIf(…, Cast(\"$(flag)\", \"$(type)\"))"
  return QueryBuildError(
    "\e[4m\e[31m`NullIf`\e[0m over $(side[1]) is not supported: a JSON key's value has no declared type, " *
    "so the query does not say whether it compares numbers or text (#1510). Cast the key where it sits: " *
    "\e[32m$(spell("numeric", "0"))\e[0m compares numbers on every engine, and " *
    "\e[32m$(spell("text", "Value(\"\")"))\e[0m compares text.")
end

# The explicit spelling casts the key inside the expression, where the type is decided.
_json_key_refusal(p::_JSONKeyCarrierFilter, side::Tuple{String,String}) = FilterError(
  "A filter on \e[31m$(p.comparison ? string("the comparison (`", p.operator, "`)") : p.label)\e[0m is not supported: it holds $(side[1]), and a JSON key's value has no " *
  "declared type, so the query does not say what the comparison means (#1506). Cast the key inside the " *
  "expression, to the type you mean: \e[32mCast(\"$(side[2])\", \"numeric\")\e[0m compares numbers on every " *
  "engine (for example \e[32mCoalesce(Cast(\"$(side[2])\", \"numeric\"), 0)\e[0m), " *
  "\e[32mCast(\"$(side[2])\", \"text\")\e[0m text and \e[32mCast(\"$(side[2])\", \"date\")\e[0m a date.")

_json_key_refusal(::_JSONKeyRightOperand, side::Tuple{String,String}) = FilterError(
  "A comparison with \e[31m$(side[1])\e[0m on its right is not supported: a JSON key's value has no " *
  "declared type, so the query does not say what the comparison means (#1528). A key compares as its " *
  "lookup does only on the left, against a value. Cast the key to the type you mean: " *
  "\e[32mCast(\"$(side[2])\", \"numeric\")\e[0m compares numbers on every engine, " *
  "\e[32mCast(\"$(side[2])\", \"text\")\e[0m text and \e[32mCast(\"$(side[2])\", \"date\")\e[0m a date.")

# The lookup a caller wrote for an internal operator (`"BETWEEN"` → `"@range"`), for a refusal.
function _operator_spelling(op::AbstractString)::String
  for (suffix, internal) in PormGsuffix
    internal == op && return "@" * suffix
  end
  return String(op)
end

# A key's value has no declared type, and a range or a pattern over it compared text on PostgreSQL,
# where `'15'` is not between `'9'` and `'100'`. EXPLICIT INTENT, refused on every engine: a cast in a
# projection names the type.
_json_key_refusal(p::_JSONKeyOperator) = FilterError(
  "The \e[31m$(_operator_spelling(p.operator))\e[0m lookup is not supported on \e[31m$(p.label)\e[0m, a JSON " *
  "key's value: it has no declared type, so it compares only with =, @ne, @gt, @gte, @lt, @lte and " *
  "@isnull (#1499). Project the key with the type you mean and filter that name: " *
  "\e[32mvalues(\"n\" => Cast(<the key path>, \"numeric\"))\e[0m for numbers or " *
  "\e[32mCast(<the key path>, \"text\")\e[0m for text, then " *
  "\e[32mfilter(\"n__$(_operator_spelling(p.operator))\" => …)\e[0m.")

_json_key_refusal(p::_JSONKeyColumnRHS) = FilterError(
  "Error in filter '$(p.label)': a JSON path lookup compares the extracted value against a value, not a " *
  "column expression")

# ---------------------------------------------------------------------------------------------------
# The entry point
# ---------------------------------------------------------------------------------------------------

# Probe `operand` and raise `position`'s refusal when it carries an uncast key. Read after the operand
# renders, so a joined path's column is resolved (#568's order). A tuple of operands is probed in order
# and the first that carries a key is the one named (arithmetic's left, then its right).
function _refuse_uncast_json_key(position::_JSONKeyPosition, operand, instruc::SQLInstruction)
  _json_key_position_applies(position) || return nothing
  side = _json_number_side(operand, instruc)
  side === nothing || throw(_json_key_refusal(position, side))
  return nothing
end
# #1528: the right operand of a comparison, once it has rendered. A String is a column only when it is a
# field path (`_set_update_query_operand`'s rule); any other String is a bound text value.
function _refuse_json_key_right_operand(operand, instruc::SQLInstruction)
  operand isa AbstractString && !_is_field_path(String(operand), instruc) && return nothing
  return _refuse_uncast_json_key(_JSONKeyRightOperand(), operand, instruc)
end
function _refuse_uncast_json_key(position::_JSONKeyPosition, operands::Tuple, instruc::SQLInstruction)
  _json_key_position_applies(position) || return nothing
  for operand in operands
    side = _json_number_side(operand, instruc)
    side === nothing || throw(_json_key_refusal(position, side))
  end
  return nothing
end
