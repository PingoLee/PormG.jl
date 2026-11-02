# ── Query-builder error funnels ──────────────────────────────────────────────
# The taxonomy TYPES live in `src/exceptions.jl`, included by `Kernel` (layer 1) — see the header
# there for why. What stays here are the query-builder's message-composing funnels.
#
# ## The rule: a funnel RETURNS an exception; the call site THROWS it
#
# `throw(_write_not_allowed(op, key))`, never a funnel that throws internally. This is uniform with
# direct construction (`throw(QueryBuildError(...))`), so a reader never has to remember which of
# the two a given helper is — and the hazard it removes is real: a funnel that throws internally
# invites the mirror-image mistake at a *returning* funnel, where a forgotten `throw(` silently
# constructs an exception, discards it, and lets execution continue straight past the guard. No
# error raised, no test failure. `test_typed_exceptions.jl` pins the convention.
#
# ## What belongs here
#
# A funnel earns its place by **composing a message** from parameters, so that every call site
# reports the same wording and the same fix. A funnel that only maps a message to a type is not an
# abstraction — it is an alias that hides which type is thrown, and the call site should name the
# type itself.
#
# That is why `_argerr(msg) = QueryBuildError(msg)` was removed in #262: it was scaffolding for
# #231's mechanical `ArgumentError(` → `_argerr(` swap, spread across nine files, and reading
# `throw(_argerr("…"))` told you nothing about the resulting type. Its 71 call sites now say
# `throw(QueryBuildError("…"))`.
#
# Scope, so a fifth funnel has an obvious home: **shared** funnels live here; a funnel used by
# exactly one file lives beside its call sites. `_fielderr` in `src/models/fields.jl` is the latter
# — its call sites live in one file, one category, documented where it is used (#260 cut them from 248 to ~50).

# Internal dispatch fallback (#197, retyped in #231): a connection object that is not one of PormG's
# engine pools reached an execution path — a catchable `PormGError` subtype.
_unsupported_conn(op::AbstractString, conn) = UnsupportedConnectionError(
  "PormG internal error in $(op): unsupported connection type $(typeof(conn)) — expected a PostgreSQL, SQLite or MySQL connection pool. This is a PormG bug; please report it.")

# Standard actionable error for a write blocked by `change_data: false` (#205), typed as
# `WritesDisabledError` (#231, renamed from `PermissionError` in the pre-publish naming pass). Every DML entry point (insert, update, delete, update_or_create,
# bulk_*, many-to-many add/remove/clear, primary-key allocation) shares this one message so a user
# hitting any of them gets the same fix — writes are disabled by default (safety-first, the common
# first-`create` trap), and the message names where to fix it: the `config:` block of the active
# environment in connection.yml.
_write_not_allowed(operation::AbstractString, conn_key) = WritesDisabledError(
  "Error in $(operation): the connection \e[4m\e[31m$(conn_key)\e[0m is not allowed to write. " *
  "Writes are disabled by default — set \e[1mchange_data: true\e[0m under the `config:` block of the active " *
  "environment in connection.yml to enable creates, updates, and deletes.")

# #536 — an `F(...)` / `Joined(...)` comparison against a value the operand vocabulary does not
# admit. Without this the call fell through to `Base.==` (identity) and evaluated to a bare `Bool`,
# so `q.filter(F("uid") == uuid)` reported *"Invalid filter argument: false"* — naming a value the
# user never wrote (#530's complaint, on every type the union omitted). Shared by the eighteen
# catch-all methods in `operators.jl` — six per family, `F`, `Joined` and, since #895, a function on the
# left (`Lower(…) == x`) — which is what earns it a funnel: one wording, one fix, and the accepted
# list is read LIVE from `_CompareLiteral` so the text cannot drift from the union it describes.
# #1476 — an operand `+ - * /` does not take, named rather than left to Julia's `MethodError`. What
# each node family takes differs (`operators.jl`), so the message lists that family's operands: only an
# `F` expression takes a Dates period, and an aggregate or scalar function takes no window function. A
# `Decimal` has no literal here (a comparison and a function take none either), so the spelling is a
# `Float64` or a cast of its digits; a `Rational` has no SQL literal at all. The value is never printed.
_arith_operands(::Type{FExpression}) =
  "a number (an Integer, Float64, Float32 or Float16), a column path (a String), an \e[4m\e[32mF(...)\e[0m " *
  "expression, a function or a window function, a \e[4m\e[32mCTE(...)\e[0m column, or " *
  "\e[4m\e[32mValue(n)\e[0m of a number; `+` and `-` also take a Dates period or an Interval"
_arith_operands(::Type{WindowFunction}) =
  "a number (an Integer, Float64, Float32 or Float16), a column path (a String), an \e[4m\e[32mF(...)\e[0m " *
  "expression, a function, a \e[4m\e[32mCTE(...)\e[0m column, or \e[4m\e[32mValue(n)\e[0m of a number"
_arith_operands(::Type{FObject}) =
  "a number (an Integer, Float64, Float32 or Float16), a column path (a String), an \e[4m\e[32mF(...)\e[0m " *
  "expression, another function that is not a window function, a \e[4m\e[32mCTE(...)\e[0m column, or " *
  "\e[4m\e[32mValue(n)\e[0m of a number"
# #1539: a CTE column takes the `F` family's operands.
_arith_operands(::Type{CTEReference}) =
  "a number (an Integer, Float64, Float32 or Float16), a column path (a String), an \e[4m\e[32mF(...)\e[0m " *
  "expression, a function or a window function, another \e[4m\e[32mCTE(...)\e[0m column, or " *
  "\e[4m\e[32mValue(n)\e[0m of a number; `+` and `-` also take a Dates period or an Interval"
function _unsupported_arithmetic_operand(op::AbstractString, operand, node::Type)
  T = typeof(operand)
  spelling = operand isa Decimals.Decimal ?
      "Write it as a float, \e[4m\e[32mFloat64(x)\e[0m, or keep its digits with a cast, " *
      "\e[4m\e[32mCast(Value(string(x)), \"numeric\")\e[0m." :
    operand isa Rational ? "Write it as a float, \e[4m\e[32mFloat64(x)\e[0m." :
    operand isa Union{Dates.Period,Dates.CompoundPeriod,Interval} ?
      (node <: Union{FExpression,CTEReference} ? _duration_multiplicand_hint() :
       "Shift the column inside the function instead: \e[4m\e[32mMax(F(\"date\") + Day(1))\e[0m.") :
    (operand === missing || operand === nothing) ? _null_arithmetic_hint() :
    operand isa WindowFunction ?
      "Compute the window function in a CTE and combine its column, or put the function inside the window's operand." :
      "Wrap a literal of another type in a cast, or compute it in Julia first."
  return QueryBuildError(
    "\e[4m\e[31m$(T)\e[0m is not an operand of \e[4m\e[31m$(op)\e[0m here (#1476). Arithmetic on " *
    "$(_arith_node_label(node)) takes " * _arith_operands(node) * ". " * spelling)
end
_arith_node_label(::Type{FExpression}) = "an `F(...)` expression"
_arith_node_label(::Type{WindowFunction}) = "a window function"
_arith_node_label(::Type{FObject}) = "a function"
_arith_node_label(::Type{CTEReference}) = "a CTE(...) column"

# #1549 — the LEFT side of `+ - * /` on the four families. A number goes on either side (#1476); a date
# goes on the left of `-` only, the mirror of #814's `F("date") - Date(…)`; a duration on the left of
# `+` commutes where the right takes one (`F`, `CTE(...)`). Everything else that reaches the left
# catch-all — a date under `+ * /`, a duration under `- * /`, `missing` — is refused here, naming what
# the left of that family takes. The value is never printed, only its type.
_arith_left_operands(::Type{T}) where {T<:Union{FExpression,CTEReference}} =
  "a number (\e[4m\e[32m10 - F(\"grid\")\e[0m), a Dates period or an Interval under `+` " *
  "(\e[4m\e[32mDay(1) + F(\"date\")\e[0m), and a Date, DateTime or ZonedDateTime under `-` " *
  "(\e[4m\e[32mDate(2009, 3, 29) - F(\"date\")\e[0m)"
_arith_left_operands(::Type{T}) where {T<:Union{FObject,WindowFunction}} =
  "a number (\e[4m\e[32m10 - Max(\"grid\")\e[0m), and a Date, DateTime or ZonedDateTime under `-` " *
  "(\e[4m\e[32mDate(2009, 3, 29) - Max(\"date\")\e[0m)"
function _unsupported_left_arithmetic_operand(op::AbstractString, operand, node::Type)
  T = typeof(operand)
  spelling = (operand === missing || operand === nothing) ? _null_arithmetic_hint() :
    operand isa Dates.Time ? "Wrap a literal of another type in a cast, or compute it in Julia first." :
    operand isa Union{Dates.Date,Dates.DateTime,TimeZones.ZonedDateTime} ?
      (op == "+" ?
        "Only `-` takes a date on the left. To add a column's number of days to a date literal, cast the " *
        "literal to a date: \e[4m\e[32mCast(Value(Date(2009, 3, 29)), \"date\") + F(\"grid\")\e[0m." :
        "A date is not multiplied or divided. Only `-` takes one on the left: the days or the interval " *
        "to the right side, or the date moved back by a day count or an interval.") :
    op == "-" ?
      "A duration on the left of `-` is not taken: a duration minus a date or a number has no meaning, " *
      "and minus an interval is not supported yet (#1553). To move a date back, subtract the duration " *
      "from it: \e[4m\e[32mF(\"date\") - Day(1)\e[0m." :
      _duration_multiplicand_hint()
  return QueryBuildError(
    "\e[4m\e[31m$(T)\e[0m on the left of \e[4m\e[31m$(op)\e[0m is not an operand here (#1549). On the " *
    "left, arithmetic on $(_arith_node_label(node)) takes " * _arith_left_operands(node) * ". " * spelling)
end

# A Dates period is a shift, not a number to scale or divide by: only `+` and `-` take one. The shift by
# a column's number of days is the column itself (#882). Shared by both sides' refusals.
_duration_multiplicand_hint() =
  "A duration is not scaled by a column or divided here (#1553); only `+` and `-` take one. To shift a " *
  "date by a column's number of days, add the column: \e[4m\e[32mF(\"date\") + F(\"grid\")\e[0m."
# SQL NULL in arithmetic is always NULL, so `missing` (or `nothing`) as an operand says nothing the query
# could mean. Django has no `None + F(...)` either.
_null_arithmetic_hint() =
  "`missing` (or `nothing`) is SQL NULL, and arithmetic with NULL is always NULL. To treat a missing value as a " *
  "number, coalesce the column: \e[4m\e[32mCoalesce(\"grid\", 0) + 1\e[0m."

function _unsupported_compare_operand(op::AbstractString, operand)
  accepted = join(string.(Base.uniontypes(_CompareLiteral)), ", ")
  hint = (operand === nothing || operand === missing) ?
    " To test for NULL, filter with \e[4m\e[32m\"col__@isnull\" => true\e[0m instead." : ""
  return QueryBuildError(
    "\e[4m\e[31m$(typeof(operand))\e[0m is not a supported right-hand side for an F/Joined/function comparison " *
    "(\e[4m\e[31m$(op)\e[0m). A comparison operand must be a literal of one of these types — " *
    "$(accepted) — a column reference (\e[4m\e[32mF(...)\e[0m, \e[4m\e[32mCTE(...)\e[0m, " *
    "\e[4m\e[32mJoined(...)\e[0m), or a scalar \e[4m\e[32mSubquery(...)\e[0m." * hint)
end

# #1204 — the pair a build-time refusal came from. `_check_filter` and the `values()` function arm used
# to `@error` the key or alias with a backtrace and then rethrow, so every deliberate refusal printed
# twice, and the log was the only place the key appeared: a refusal raised deep in the build
# ("operator @gt is not valid with a vector value") does not name it. The #1107 decision drops the
# log; this keeps what it carried by appending the pair to the error, as the same type, so a `catch
# FilterError` and a `startswith` on the message still hold.
#
# Only for a `msg`-only `PormGError`. An `InvalidValueError` carries its location as data and is
# located by its own funnels (#971); anything else is a bug, kept as it was, backtrace included.
# `nothing` tells the call site to `rethrow()`.
function _in_pair(e, pair::AbstractString)
  e isa PormGError && fieldnames(typeof(e)) == (:msg,) || return nothing
  # `e.msg` is a PormG refusal already held to #971; `pair` is the key or alias the caller wrote.
  return typeof(e)(string(e.msg, " — in ", pair))   # refusal-value-ok: no bound value, see above
end
