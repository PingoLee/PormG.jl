# Rendering an `F(...)` expression to SQL (#130): `_set_update_query` — the funnel SELECT, WHERE-side
# `F` comparisons, UPDATE SET and the insert path all render an expression through — and the typed
# temporal path behind it: date/time shifts and differences (#25, #527, #564, #814), and interval
# arithmetic carried in milliseconds (#881). Nothing here executes a statement.
#
# Included just before `execution_read.jl` / `execution_write.jl`; until #130 this code sat inside
# `execution.jl`, since split into those two. Every caller reaches it from a function body, so
# nothing depends on where in the include chain it sits.

# `_is_date_field(::String, ::SQLInstruction)` used to live beside this code, then in
# `execution.jl`. Both of its callers were the integer-days special cases #568 deleted, so it went
# with them — and with it the #563 collision, in which two functions named `_is_date_field` carried
# DIFFERENT semantics: this one answered `true` for TIMESTAMP, while `sanitization.jl`'s
# `_is_date_field(f_meta)` answers `true` only for a plain DATE. That pair is what produced the
# integer-days half of #527 in the first place, and removing it is what CLOSED #563: that issue
# asked for the two predicates to have names distinguishing "any temporal column" from
# "calendar-date column", and there is no longer a pair to distinguish. The survivor reads
# unambiguously precisely because it has no confusable sibling left.
#
# What replaces it: `_operand_column_kind`, which answers with a `CanonicalType` rather than a Bool
# and is shape-polymorphic (a String, a `JoinedReference` or a nested `FExpression`), so there is one
# answer to "what temporal kind is this?" in this file instead of two predicates that agreed by luck.

function _set_update_query(v::SQLTypeFunction, instruc::SQLInstruction)
  return _get_select_query(v, instruc)
end

# --- Date arithmetic with explicit Julia duration types (#25) ------------------------------------
# Unit → SQL keyword maps. These are closed whitelists: the unit symbols come only from
# `_decompose_period`, never from user text, so the interpolated keyword can never carry injection.
const _PG_INTERVAL_KW     = Dict(:year => "years", :month => "months", :week => "weeks",
                                 :day => "days", :hour => "hours", :minute => "mins")  # :second → "secs"
const _SQLITE_INTERVAL_UNIT = Dict(:year => "years", :month => "months", :day => "days",
                                   :hour => "hours", :minute => "minutes", :second => "seconds")  # :week → converted to :day

# Concrete date/time type of a plain field reference, or `nothing` if the field is not a
# DATE/TIMESTAMP column or cannot be resolved. Sibling of `_is_date_field`; the migration-style
# `tab_field_cache` lookup only resolves a dotted join key AFTER that join has rendered.
function _date_field_type(field_name::String, instruc::SQLInstruction)::Union{String, Nothing}
  model = instruc.object.model
  if haskey(model.fields, field_name)
    t = model.fields[field_name].type
    return t in ("DATE", "TIMESTAMPTZ", "TIMESTAMP") ? t : nothing
  else
    memoized = memo_field(instruc, memo_key(:base, field_name))   # #474: base-model namespace
    if memoized !== nothing
      return memoized.type in ("DATE", "TIMESTAMPTZ", "TIMESTAMP") ? memoized.type : nothing
    end
  end
  return nothing
end

# Whether a plain field reference resolves at all (so soft validation only fires when a field is
# known to be a non-date column, never when its type is simply unknown — best-effort, fail-open).
function _field_type_known(field_name::String, instruc::SQLInstruction)::Bool
  return haskey(instruc.object.model.fields, field_name) ||
         memo_field(instruc, memo_key(:base, field_name)) !== nothing
end

# #494 — the DATE/TIMESTAMP type of a comparison's LEFT side, or `nothing` when there is no column
# to ask.
#
# `F("path")` puts a `String` in `field_name` and `Joined(alias, col)` puts the handle there. A
# nested expression — `F("dob") + Year(18)` — puts an `FExpression` there, and it is NOT
# unanswerable: the column one level down is the column the comparison is against, so recursing to
# find it is what keeps the representation following the COLUMN rather than the literal's own Julia
# type.
#
# That recursion is load-bearing, not tidiness. Without it `F("dob") + Year(0) == DateTime(1985,1,7)`
# on a `DateField` bound the canonical UTC string while `date(...)` rendered `'1985-01-07'` — no
# match, zero rows, no error. Exactly the silent failure the operand arm exists to prevent, one hop
# away from where it was being prevented. `_render_date_period_arithmetic` calls this same function
# to choose SQLite's `date()` vs `datetime()` wrapper, so the wrapper and the bound representation
# agree about which column the expression is rooted in.
#
# What this does NOT claim is that arithmetic preserves the column's KIND at render time. It does
# not: a sub-day duration on a `DateField` renders `datetime("seen", '+2 hours')` on SQLite, whose
# output matches neither the calendar-date form nor the canonical timestamp form. That is a
# render-side representation gap of its own — pre-existing, reachable without any of #494 (a plain
# `F(ts) + Day(1) == F(other_ts)` has it too), and tracked separately. Answering with the rooted
# column is the right answer to THIS question; it is not a claim that the rest of that path is sound.
#
# A `CTE(...)` cannot be a LEFT operand — no comparison method takes one on that side — so it has no
# arm. Nor does an `FObject`: since #895 a function on the left builds the node one hop down —
# `Max("seen") == Date(…)` is an `FExpression` over the `FObject`, as `(Sum("points") - 10) == Date(…)`
# always was — and falling back to the operand's own type is correct there, because a function is not
# its column: `Lower("code")` is text whatever `code` is. A `__@` transform does not arrive here as an `FObject` either:
# `F("seen__@year")` puts the whole path in `field_name` as a STRING, and `_date_field_type` already
# declines it.
#
# The joined arm reads the memo rather than the model: `_get_select_query(::JoinedReference)` writes
# the resolved `PormGField` under `memo_key(ref)` (`build_helpers.jl`), and the caller renders the
# left side BEFORE the operand, so the entry is always there by the time this runs. Without it a
# `Joined` comparison fell back to the operand's own type while the `F` twin consulted the column —
# the two families binding different bytes for the same query, which is the asymmetry #494 exists to
# close.
#
# #508 phase 2 removed this walk's `depth > 16` cap. It existed for one stated reason — `FExpression`
# was mutable, so a hand-built cycle (`g.field_name = g`) was one assignment away, in either of the
# two orderings the deleted comment enumerated. `FExpression` is a `struct` now and `field_name` can
# only be set at construction, so a self-cycle is unrepresentable rather than merely unlikely. That
# is the same reason #457 added no cap for the operator route it closed, applied one level up.
#
# Deleting it is a correctness fix and not only cleanup: the cap returned `nothing`, and `nothing`
# here means "not a date column" — so a legitimately 17-deep expression did not fail, it silently
# selected the wrong literal representation for the bound operand. #494's whole point is that an `F`
# comparison and an ordinary `filter(...)` pair bind the same bytes; the cap could break exactly that.
#
# #536 generalized the walk from "the DATE/TIMESTAMP type of the column" to "the column's FIELD",
# because the literal arm needs the column's FORMATTER, not only its temporal kind: a `Float64`
# against a `FloatField` must bind `format_number_sql`'s string, a `UUID` against a `UUIDField`
# `format_uuid_sql`'s — the same choice the pair path makes at `_get_filter_query(::SQLTypeOper)`
# (build_helpers.jl) by reading `model.fields[...]`. The String arm is `_date_field_type`'s own
# two-step lookup (model fields, then the base-namespace memo the left-side render populated).
function _operand_column_field(field_name, instruc::SQLInstruction)::Union{PormGField,Nothing}
  if field_name isa String
    model = instruc.object.model
    haskey(model.fields, field_name) && return model.fields[field_name]
    return memo_field(instruc, memo_key(:base, field_name))   # #474: base-model namespace
  end
  field_name isa JoinedReference && return memo_field(instruc, memo_key(field_name))
  field_name isa FExpression && return _operand_column_field(field_name.field_name, instruc)
  return nothing
end

# #564 — the rooted column's canonical kind, replacing `_operand_column_type`'s type STRING. The
# strings were the symptom the representation table exists to remove: every consumer re-derived the
# same DATE-vs-TIMESTAMP decision from them, and each copy was a place the two could disagree.
#
# NARROWED to the two kinds that take date arithmetic, exactly as the string version was. `CTime` and
# `CInterval` are temporal representations but never the LEFT of `± duration`.
#
# This is a CONSUMER-SIDE narrowing, and it is not the only thing enforcing the rule. Since the
# projection path needs the column's TRUE kind, `_render_left_typed` hands the unnarrowed answer to
# the temporal renderer, so a `CTime` left is refused by two independent things: the soft validation
# in `_render_date_period_arithmetic` (the String case), and `sql_canonicalize`'s generic arm, which
# THROWS rather than silently dropping modifiers whose parameters are already bound. Neither is a
# formality — `test_f_date_operands.jl`'s "#564: a TIME column is not whole-day arithmetic" testset
# fails if this narrowing is removed.
function _operand_column_kind(field_name, instruc::SQLInstruction)::TemporalKind
  kind = _projection_column_kind(field_name, instruc)
  return (kind isa CDate || kind isa CDateTime) ? kind : nothing
end

# The same lookup, UNNARROWED — the kind a column's values are stored as, whatever it is.
#
# Two functions rather than one because they answer two different questions, and conflating them
# changes behaviour in both directions. ARITHMETIC must see only DATE and TIMESTAMP: a `TimeField`
# or a `DurationField` is a temporal REPRESENTATION but never the left of `± duration`, and
# `_render_date_period_arithmetic`'s soft validation refuses one — widening `_operand_column_kind`
# would let `F(t) + 7` render `date(t, '+7 days')` instead of throwing. A PROJECTION must see all
# four: a `TimeField` column read back as a `String` on SQLite while PostgreSQL delivered a `Time`
# is precisely the defect this closes.
#
# One lookup, two policies, each named for its job — not two implementations of one rule.
function _projection_column_kind(field_name, instruc::SQLInstruction)::TemporalKind
  f = _operand_column_field(field_name, instruc)
  f === nothing && return nothing
  return field_canonical_kind(f)
end

# #536 — the operators whose right-hand literal is bound through the rooted column's formatter.
# Arithmetic (`+ - * / << >>` …) is deliberately NOT in this set: those operands keep the raw,
# SQL-typed bind (`integer_column / 2.0` must not be inferred back to integer on PostgreSQL), and
# the Integer arm's date-arithmetic wrapper depends on receiving the bare value.
const _COMPARISON_OPERATIONS = ("=", "!=", ">", "<", ">=", "<=")

# #494 — the representation a `Date`/`DateTime` literal binds as on the RIGHT of an `F(...)` /
# `Joined(...)` comparison.
#
# The LEFT column decides, and `_set_update_query_operand` already receives it as `field_name`, so
# the choice is made the way the plain-filter path makes it: by the field, not by the value.
# `_operand_column_type` above answers for both families, and its answer selects the MODEL LAYER's
# own formatter rather than a second copy of the rules — `format_date_sql` for a DATE column,
# `format_timezone_sql` for a TIMESTAMP/TIMESTAMPTZ one (the canonical UTC string #79 defined, so
# SQLite's lexicographic TEXT comparison agrees with PostgreSQL's instant comparison). Reusing those
# is the whole point: an `F` comparison and an ordinary `filter(...)` pair against the same column
# now bind the same bytes.
#
# A `Date` against a TIMESTAMP column is promoted to midnight first, because `format_timezone_sql`
# has no `::Date` method — and midnight is what SQL itself means by a date literal compared to a
# timestamp, so the promotion is exact rather than a guess.
#
# When the left side is a nested expression or an unresolvable path there is no column to ask, so
# the operand's own type decides. Still a formatted string, never a raw bind.
# #533 added `ZonedDateTime`. The body needed no new arm: `Models.format_date_sql` and
# `Models.format_timezone_sql` each already carry a `::ZonedDateTime` method, and the two branches
# below pick between them by the COLUMN's type, not the value's — which is the whole point of #494.
# So a `ZonedDateTime` against a TIMESTAMP column binds the canonical UTC string (#79), byte-identical
# to what the ordinary `filter("ts" => zdt)` pair spelling binds.
# #564: `left_kind` is the kind the LEFT SIDE evaluates to, carried out of its own render rather than
# reconstructed here. That replaces the `_f_arith_result_kind` chain walk this used to perform.
#
# #527's promotion is now a property of the value it receives: `F("dob") + Hour(6)` on a `DateField`
# evaluates to a timestamp — `date + interval` is a `timestamp` in SQL:2003 and PostgreSQL, and Django
# resolves the same combination to a `DateTimeField` — so the literal must bind the canonical form,
# not the column's calendar date. Bound to the column's date form, the comparison was unsatisfiable on
# BOTH engines and returned zero rows with no error. The promotion still fires only on a sub-day
# component (`_shift_result_kind`), so the pinned truncation contract for whole-day arithmetic
# (`F("dob") + Day(1) == DateTime(...)` binds the calendar date, exactly as the pair spelling does) is
# untouched.
#
# Which formatter a kind gets is NOT decided here — `value_formatter` is the single declaration both
# this binder and the field itself derive from (#564), so an `F` comparison and an ordinary
# `filter(...)` pair against the same column bind the same bytes by construction rather than because
# two ladders happen to agree.
function _format_date_operand(operand::Union{Dates.Date,Dates.DateTime,TimeZones.ZonedDateTime}, field_name, instruc::SQLInstruction;
                              left_kind::TemporalKind = nothing)
  kind = left_kind === nothing ? _operand_column_kind(field_name, instruc) : left_kind
  # Only a DATE/TIMESTAMP left decides a date literal's representation. A `TimeField` left reaching
  # here means the caller compared a date against a time column, where the column has nothing useful
  # to say — the operand's own type decides, as it did before the render carried a kind.
  kind isa Union{CDate,CDateTime} || (kind = nothing)
  formatter = kind === nothing ? nothing : value_formatter(kind, instruc.connection)
  # No column to ask (a nested expression rooted in a function, an unresolvable path): the operand's
  # own type decides. Still a formatted string, never a raw bind.
  formatter === nothing &&
    return operand isa Dates.Date ? Models.format_date_sql(operand) : Models.format_timezone_sql(operand)
  # A `Date` against a TIMESTAMP column is promoted to midnight first, because `format_timezone_sql`
  # has no `::Date` method — and midnight is what SQL itself means by a date literal compared to a
  # timestamp, so the promotion is exact rather than a guess.
  kind isa CDateTime && operand isa Dates.Date && return formatter(Dates.DateTime(operand))
  return formatter(operand)
end

# Decompose a Period/CompoundPeriod into an ordered [(unit, magnitude)] list (largest → smallest),
# folding sub-second components into a single fractional `:second`. Zero-valued components are
# dropped. Month/Year are kept as calendar units (SQL renders them natively) rather than rejected
# the way `_duration_to_nanoseconds` does — nanosecond conversion is ambiguous, SQL interval math is not.
function _decompose_period(period::Union{Dates.Period, Dates.CompoundPeriod})
  cp = period isa Dates.CompoundPeriod ? period : Dates.CompoundPeriod(period)
  acc = Dict{Symbol, Int}()
  frac_nanos = Int64(0)
  for p in Dates.periods(cp)
    val = Dates.value(p)
    if     p isa Year        ; acc[:year]   = get(acc, :year, 0)   + val
    elseif p isa Quarter     ; acc[:month]  = get(acc, :month, 0)  + 3 * val
    elseif p isa Month       ; acc[:month]  = get(acc, :month, 0)  + val
    elseif p isa Week        ; acc[:week]   = get(acc, :week, 0)   + val
    elseif p isa Day         ; acc[:day]    = get(acc, :day, 0)    + val
    elseif p isa Hour        ; acc[:hour]   = get(acc, :hour, 0)   + val
    elseif p isa Minute      ; acc[:minute] = get(acc, :minute, 0) + val
    elseif p isa Second      ; acc[:second] = get(acc, :second, 0) + val
    elseif p isa Millisecond ; frac_nanos += Int64(val) * 1_000_000
    elseif p isa Microsecond ; frac_nanos += Int64(val) * 1_000
    elseif p isa Nanosecond  ; frac_nanos += Int64(val)
    else
      throw(InvalidValueError("Unsupported duration component $(typeof(p)) in F-expression date arithmetic"))
    end
  end
  comps = Tuple{Symbol, Real}[]
  for u in (:year, :month, :week, :day, :hour, :minute)
    haskey(acc, u) && acc[u] != 0 && push!(comps, (u, acc[u]))
  end
  whole_sec = get(acc, :second, 0)
  if frac_nanos != 0
    push!(comps, (:second, whole_sec + frac_nanos / 1e9))
  elseif whole_sec != 0
    push!(comps, (:second, whole_sec))
  end
  return comps
end

# #564 — the kind an expression evaluates to, given the kind its LEFT SIDE evaluates to and the
# duration components applied to it. One rule, one line, no walk.
#
# It replaces `_f_arith_result_kind`, a type inferencer written as a RETROACTIVE walk: because the
# render returned a bare `String`, anything downstream that needed the type had to reconstruct it
# afterwards, either by re-walking the AST or by sniffing the rendered text. The walk's three
# documented subtleties were all consequences of that, and the typed render gets each for free:
#
#   1. "It walks the CHAIN, not just the top link" — the inner node's kind is now CARRIED out of the
#      inner render and read from the tuple, so there is no chain left to walk.
#   2. "It asks `_decompose_period`, not `typeof(operand)`" — still true, and now structural: this
#      function takes `comps`, so it cannot be spelled any other way.
#   3. The zero-length link (`F(ts) + Day(0) + Day(1)`) — the identity short-circuit returns
#      `(left_sql, kind)`, so the kind survives a link that emits no text at all. That is what makes
#      the textual backstop unnecessary rather than merely redundant; see the deletion note below.
#
# Django calls the kind an expression evaluates to its `output_field`, and every `Expression` carries
# one — this is that idea, narrowed to the temporal path.
#
# The promotion is the SQL one: a sub-day duration on a DATE column yields a TIMESTAMP. `date +
# interval` is a `timestamp` in SQL:2003 and in PostgreSQL; Django registers `DateField +
# DurationField -> DateTimeField` in `_connector_combinations` and SQLAlchemy resolves
# `Date + Interval -> DateTime`. Without it `F("dob") + Hour(6) == DateTime(...)` bound the column's
# calendar-date form against a timestamp-valued left side and returned zero rows — on BOTH engines,
# silently.
#
# NARROWER than Django on purpose: Django promotes `DateField + Duration` unconditionally, including
# whole days. PormG has a pinned, deliberate contract that a `DateTime` literal against a DATE column
# truncates to its calendar date exactly as the `filter("dob__@gte" => …)` pair spelling does, and
# promoting on `Day(1)` would overturn it. Promoting only when the expression itself produced a
# time-of-day changes nothing that already has a correct answer.
#
# #572 settled the one consequence this left open. PostgreSQL's own `date + interval` is a timestamp
# even for whole days, so the PROJECTED type split by engine until the PostgreSQL render was cast
# back to `date` — `sql_canonicalize(::CDate, ::PormGPostgres)`, which `_render_temporal_shift`
# consults with the kind this function returns. The rule here is therefore the rule both engines
# project, not only the one PormG binds by.
_shift_result_kind(::Nothing, comps) = nothing
_shift_result_kind(kind::CDate, comps) =
  any(c -> c[1] in (:hour, :minute, :second), comps) ? CDateTime(false) : kind
_shift_result_kind(kind::CanonicalType, comps) = kind

# #801 — the other half of the same table: the kind `a - b` evaluates to when BOTH sides are temporal.
# `_shift_result_kind` names `temporal ± duration`; this names `temporal - temporal`. Without it the
# difference fell into the generic infix arm, which renders a bare `-` and types it `nothing` — and on
# SQLite a DATE is TEXT, so `-` subtracts each side's leading numeric prefix: `'2009-04-28' -
# '2009-03-29'` is `2009 - 2009 = 0`. A plausible integer, no error, on the engine with the bug only.
#
#   DATE - DATE  → `CInt32`: a whole number of days. PostgreSQL's own `date - date` is an `integer`,
#                  so its SQL is unchanged and SQLite is rendered to agree with it.
#   anything with a TIMESTAMP side (a sub-day-promoted DATE included) → `CInterval`, PostgreSQL's
#                  `timestamp - timestamp`. Typed so the #581 read-back pin applies to it.
#   anything else → `nothing`: not a temporal difference, rendered exactly as before.
#
# NOT Django's answer, deliberately: Django's `TemporalSubtraction` gives a `DurationField` for
# `DateField - DateField`. An integer is what PostgreSQL already returns, and it keeps `gap > 30`
# a numeric comparison on both engines — a duration on SQLite is TEXT and compares as TEXT.
_difference_result_kind(::CDate, ::CDate) = CInt32()
_difference_result_kind(::Union{CDate,CDateTime}, ::Union{CDate,CDateTime}) = CInterval()
_difference_result_kind(_, _) = nothing

# The LEFT side of an expression, rendered AND typed.
#
# RENDERS BEFORE IT TYPES, and the order is load-bearing rather than incidental: resolving the left
# populates `instruc.tab_field_cache` for a dotted join key (`F("driverid__dob")`), which is the only
# way `_projection_column_kind` can answer for one. Type first and every joined temporal column silently
# becomes `nothing` — on PostgreSQL that is `timestamptz + bigint`, a hard error; on SQLite it is a
# `date()` truncation nobody sees.
function _render_left_typed(value::Any, operation::String, instruc::SQLInstruction)::Tuple{String,_RenderKind}
  # #985: a comparison's left side, inside an ON clause; arithmetic inherits the side it sits on.
  if operation in _COMPARISON_OPERATIONS && (side = _join_side_change(instruc, :left)) !== nothing
    return with_scope(() -> _render_left_typed(value, operation, instruc), instruc; join_side = side)
  end
  value isa FExpression && return _render_expr_typed(value, instruc)
  value isa FObject && return _render_function_operand_typed(value, instruc)
  sql = _set_update_query_left(value, operation, instruc)
  return sql, _side_kind(value, instruc)
end

# #907 — a function as a side of an expression, rendered ONCE by `_render_function_typed`, which is
# what `_get_select_query` renders for it, so its SQL and its bindings are the ones it always had.
# What changes is that the millisecond form #900 gave a function over an interval is kept here too:
# on SQLite `Sum(d)`, `Avg(d)`, `Max("time")` stay `_IntervalMs` inside the tree, so `Sum(d) / Count(…)`
# and `Sum("time") - Max("time")` are arithmetic on milliseconds rather than on the text's leading
# hours, and `Max("time") + d` has the millisecond form #881 refused it for. On PostgreSQL the SQL is
# unchanged and the function is typed `CInterval` wherever its render says it is one, which
# `_function_projection_kind` alone cannot say of a `Sum`. Every other function is typed as before.
function _render_function_operand_typed(v::FObject, instruc::SQLInstruction)::Tuple{String,_RenderKind}
  sql, interval_ms, interval = _render_function_typed(v, instruc)
  interval_ms && return sql, _IntervalMs()
  return sql, interval ? CInterval() : _side_function_kind(v, instruc)
end

# #814 — the kind of an ALREADY-RENDERED side that is not itself an expression: a column, a
# transformed path, or a function. The column lookup answers for a column, and only for one. A
# transform (`"date__@date"`) or a function (`Max("date")`) answered `nothing` there, so
# `F("date") - Max("date")` fell to a bare `-`, which on SQLite subtracts the YEARS of two TEXT
# dates, silently. Both now ask the projection path's own resolver (`build_query.jl`), the one that
# already types `.values("m" => Max("date"))` for the read path, so a side is typed in arithmetic
# exactly as it is when projected on its own: `Max`/`Min` keep their operand's kind, `@date` is a
# date, and a function PormG does not type (`Sum`, `@year`) stays `nothing`.
#
# The order rule is the caller's: render first, then call this.
_side_kind(value::Any, instruc::SQLInstruction) = _projection_column_kind(value, instruc)
_side_kind(value::String, instruc::SQLInstruction) =
  occursin("__@", value) ? _operand_kind(value, instruc) : _projection_column_kind(value, instruc)
_side_kind(value::SQLTypeFunction, instruc::SQLInstruction) = _side_function_kind(value, instruc)

# #965 — a function SIDE's kind is its projection kind, except a boolean #965 typed. `CBool` is a READ
# kind: it tells SQLite's parser to turn the 0/1 back into a `Bool`. A side's kind types the arithmetic
# and the comparison around it, and there a kind decides what the side IS: `_is_number_side` reads any
# kind as "not a number", so `F("dur") * Cast("lap", "boolean")` turned from the multiplication it was
# into a refusal naming an interval. Such a side stays untyped here, as it was before #965. The #953
# extremum keeps the kind it has had since #953, so `Max("dur") * Max("is_active")` is still refused
# on SQLite rather than multiplying the milliseconds by 0/1, which PostgreSQL has no operator for.
function _side_function_kind(v::SQLTypeFunction, instruc::SQLInstruction)
  kind = _function_projection_kind(v, instruc)
  kind isa CBool || return kind
  return v isa FObject && v.function_name in ("MAX", "MIN") ? kind : nothing
end

# #882 — AN INTEGER COLUMN BESIDE A DATE IS A WHOLE NUMBER OF DAYS. An integer literal already is
# (#568), and so is a `DATE - DATE` count (#814); an integer COLUMN was untyped, because
# `field_canonical_kind` answers `nothing` for an `IntegerField`. So `F("seen") - F("points")` shifted
# the date by `points` days on PostgreSQL, and on SQLite subtracted `points` from the YEAR, silently.
#
# Typed HERE, for date arithmetic only, and not in `field_canonical_kind`: that table also drives the
# read path, the CTE kind records and the #536 comparison binder, and an integer column has no
# representation for any of them to undo. `CInt64` for a `BigIntegerField`, because PostgreSQL has
# `date ± integer` but no `date ± bigint`, so that count is cast (`_day_count_sql`).
#
# A bare column only — `F("points") * 2` is arithmetic over one, and a ForeignKey or an ID is an
# integer that is not a quantity of anything. Both stay untyped, and an untyped side combined with a
# date is refused on SQLite (`_refuse_untyped_date_operand`).
function _day_count_column_kind(side, kind::_RenderKind, instruc::SQLInstruction)::_RenderKind
  kind === nothing && _is_bare_column(side) || return kind
  f = _operand_column_field(side, instruc)
  # The whole integer family a quantity is declared as. SMALLINT needs no cast: PostgreSQL reaches
  # `date ± integer` through its implicit int2 -> int4 (measured on db_2).
  f isa Union{Models.sIntegerField,Models.sPositiveIntegerField,Models.sPositiveSmallIntegerField} &&
    return CInt32()
  f isa Models.sBigIntegerField && return CInt64()
  return nothing
end
_is_bare_column(s::String) = !occursin("__@", s)
_is_bare_column(::JoinedReference) = true
_is_bare_column(x::FExpression) = x.operation === nothing && _is_bare_column(x.field_name)
_is_bare_column(::Any) = false

# A day count's SQL as a day shift reads it. Only a `BIGINT` count on PostgreSQL changes.
_day_count_sql(sql::AbstractString, kind::TemporalKind, instruc::SQLInstruction) =
  kind isa CInt64 && instruc.connection isa PormGPostgres ? "CAST($(sql) AS integer)" : sql

# #882 — `date ± x` where `x` is none of the kinds a date combines with: a text column, `Sum(...)`,
# `F("points") * 2`, a float. SQLite stores a date as TEXT, so `+`/`-` there added the date's YEAR to
# the number, silently. Refused on SQLite; PostgreSQL's SQL is left as it was. For most of these
# PostgreSQL has no operator either and fails when the statement runs. The exception is a `TimeField`:
# PostgreSQL's `date + time` is a timestamp, which SQLite does not render — an intentional divergence,
# documented beside the integer-column rule.
function _refuse_untyped_date_operand(operation::AbstractString, instruc::SQLInstruction)
  instruc.connection isa PormGSQLite || return nothing
  throw(QueryBuildError("`$(operation)` between a date and a value PormG cannot type is not supported on " *
                        "SQLite, where a date is text and `$(operation)` would use only its year. Add a " *
                        "whole number of days (an IntegerField, F(\"date\") + 7) or a duration " *
                        "(F(\"date\") + Day(7))."))
end

# #564/#568 — THE ONE TEMPORAL RENDERER. It takes an ALREADY-RENDERED left side and the kind that
# left evaluates to, which is what lets the duration spelling and the bare-integer spelling share it:
# each resolves its own operand into `comps` and then renders identically.
#
# Taking the left pre-rendered is not a convenience, it is the fix for an ordering hazard. Rendering
# the left is what populates `instruc.tab_field_cache` for a dotted join key (`F("driverid__dob")`),
# and nothing can resolve that key's kind until it has. A caller that decided "is this temporal?"
# BEFORE rendering would see `nothing` for every joined temporal column and fall through to plain
# arithmetic — `timestamptz + bigint` on PostgreSQL, a silent `date()` truncation on SQLite. Making
# the rendered left a PARAMETER means a caller cannot ask the question in the wrong order.
function _render_temporal_shift(left_side::AbstractString, kind::TemporalKind, operation::String,
                                comps, instruc::SQLInstruction)::String
  if instruc.connection isa PormGPostgres
    parts = String[]
    for (unit, value) in comps
      if unit === :second
        ph = add_parameter!(instruc, Float64(value); sql_type = "double precision")
        push!(parts, "secs => $ph")
      else
        ph = add_parameter!(instruc, Int(value); sql_type = "integer")
        push!(parts, "$(_PG_INTERVAL_KW[unit]) => $ph")
      end
    end
    isempty(parts) && return left_side  # zero-length interval → identity
    # #572 — rendered into the representation the RESULT kind is stored in, exactly as the SQLite
    # branch below is. For a whole-day shift on a DATE that is a `::date` cast (PostgreSQL's own
    # `date + interval` is a timestamp); for everything else the table's PostgreSQL arm is the
    # identity. `kind` is the result kind, so a sub-day shift on a DATE is never cast. An untyped
    # left (`nothing`) renders as it always did — no cast chosen on a guess.
    shifted = "($(left_side) $(operation) make_interval($(join(parts, ", "))))"
    kind === nothing && return shifted
    return sql_canonicalize(kind, instruc.connection, shifted)

  elseif instruc.connection isa PormGSQLite
    op_factor = operation == "-" ? -1 : 1
    mods = String[]
    for (unit, value) in comps
      # SQLite has no 'weeks' modifier — express weeks as days.
      u, mag = unit === :week ? (:day, value * 7) : (unit, value)
      signed = op_factor * mag
      sign   = signed < 0 ? "-" : "+"
      ph     = add_parameter!(instruc, abs(signed))
      push!(mods, "'$sign' || $ph || ' $(_SQLITE_INTERVAL_UNIT[u])'")
    end
    # Zero-length interval → identity, matching the PostgreSQL branch (never wrap, so a timestamp
    # column is not truncated by a stray date() on a no-op interval). The KIND still travels out of
    # the caller, which is what makes the deleted backstop below unnecessary: `F(ts) + Day(0) + Day(1)`
    # emits no text here for the inner link, and the outer call is told `CDateTime` anyway.
    isempty(mods) && return left_side

    # #564 — the wrapper is no longer chosen by an `if` at this site. `sql_canonicalize` is asked to
    # render the expression into the form THIS kind's values are stored in, and the table owns which
    # form that is: the canonical `strftime` mask for a timestamp (#527 — SQLite's own `datetime()`
    # emits `YYYY-MM-DD HH:MM:SS`, which can never equal, and always sorts below, the
    # `YYYY-MM-DDTHH:MM:SS.sss+00:00` a `DateTimeField` stores), `date(...)` for a DATE column, whose
    # output already equals `format_date_sql`'s.
    #
    # ── THE TEXTUAL BACKSTOP IS GONE (#564) ──────────────────────────────────────────────────────
    # This site used to read
    #
    #     use_datetime = <resolver> === :timestamp || occursin(<the canonical mask>, left_side)
    #
    # — a sniff of the RENDERED TEXT, kept because the resolver could not see through a zero-length
    # link. It is deleted on two independent grounds, both required:
    #
    #   * STRUCTURAL — the kind is now carried out of the left render instead of reconstructed from
    #     it, and the identity short-circuit above propagates it, so the one shape the backstop
    #     existed for is handled by construction.
    #   * MEASURED — both branches were instrumented and run over four corpora (a purpose-built
    #     256-shape sweep, the full unit suite, the hermetic property test, and the full `db_sl`
    #     integration suite): 519 renders, of which `text ∧ ¬kind` occurred **0** times. The sniff
    #     never once decided an outcome the resolver had not already decided.
    #
    # `test/unit/test_value_repr_table.jl` scans `src/querybuilder/` for the mask so it cannot return.
    #
    # `nothing` means a left side this build cannot type. `date(...)` is what that case rendered
    # before, and it stays that, rather than being promoted on a guess.
    kind === nothing && return "date($(left_side), $(join(mods, ", ")))"
    return sql_canonicalize(kind, instruc.connection, left_side, mods)
  else
    throw(_unsupported_conn("date/interval arithmetic", instruc.connection))
  end
end

# #801 — THE DIFFERENCE OF TWO TEMPORAL SIDES, `kind` being `_difference_result_kind`'s answer.
#
# PostgreSQL types both columns, so its `-` is already the right operator; the text is the one the
# generic infix arm always emitted. SQLite's `-` on two TEXT dates is the difference of the YEARS, so
# the day count goes through `julianday`, which reads both `date(...)`'s output and the canonical UTC
# text a `DateTimeField` stores, and propagates NULL. The difference of two midnights is a whole
# number, so the `CAST` is exact — it only turns SQLite's REAL into the integer PostgreSQL returns.
#
# #814 — a TIMESTAMP difference is an interval. PostgreSQL's `-` already is one.
#
# #881 — on SQLite it is the INTEGER number of milliseconds between the two instants, kind
# `_IntervalMs`, and it stays that number while the expression around it is built, so `d > Hour(1)`,
# `d + d` and `F("date") + d` are arithmetic on a number. It becomes the interval TEXT a `DurationField`
# stores there (`[-]HH:MM:SS[.f]`, which `value_parser(::CInterval, ::PormGSQLite)` reads back as the
# `Dates.CompoundPeriod` PostgreSQL's `interval` reads back as, the #581 pin) only once, where its SQL
# leaves the expression tree (`_finalize_render`). Under #814 it was that text from the start, so
# ordering compared text (`"100:00:00" < "99:00:00"`) and arithmetic added the leading hours; both
# were refused on SQLite.
#
# Milliseconds, because that is the precision a stored timestamp carries (the #79 mask); `round`
# absorbs `julianday`'s binary fraction. Each side appears exactly once, so each of its parameters is
# bound once. NULL on either side is NULL, as on PostgreSQL.
function _render_temporal_difference(left_side::AbstractString, right_side::AbstractString,
                                     kind::CanonicalType, instruc::SQLInstruction)::Tuple{String,_RenderKind}
  if instruc.connection isa PormGPostgres
    return "($(left_side) - $(right_side))", kind
  elseif instruc.connection isa PormGSQLite
    kind isa CInt32 && return "CAST(julianday($(left_side)) - julianday($(right_side)) AS INTEGER)", kind
    return "CAST(round((julianday($(left_side)) - julianday($(right_side))) * 86400000) AS INTEGER)", _IntervalMs()
  else
    throw(_unsupported_conn("date difference", instruc.connection))
  end
end

# #881 — where a rendered expression LEAVES the tree (`_set_update_query`, the projection in
# `build_query.jl`), an interval held in milliseconds becomes the stored text, read back as `CInterval`.
# Every other kind is already what its SQL evaluates to.
_finalize_render(sql::AbstractString, kind::TemporalKind, ::SQLInstruction) = (String(sql), kind)
_finalize_render(sql::AbstractString, ::_IntervalMs, ::SQLInstruction) =
  (Dialect._sqlite_interval_text(sql), CInterval())

# The text of a side, for the places that compare or combine it as text rather than as a number.
_as_interval_text(sql::AbstractString, kind::_RenderKind) =
  kind isa _IntervalMs ? Dialect._sqlite_interval_text(sql) : String(sql)

_is_interval_kind(kind::_RenderKind) = kind isa Union{CInterval,_IntervalMs}

# #881 — a side as SQLite milliseconds, or `nothing` when it has no such form. An `_IntervalMs` side
# is one already. A `DurationField` column is its stored text, parsed in SQL; the column reference is
# repeated by the parse, which is safe because a column binds no parameter. A function over an interval
# with a millisecond form (`Max("lap")`, `Sum(d)`) arrives as `_IntervalMs` already (#907,
# `_render_function_operand_typed`). Any other interval — a `Case`, a window function — is text whose
# SQL may carry parameters, and has no millisecond form here.
function _interval_ms_sql(sql::AbstractString, side, kind::_RenderKind)::Union{String,Nothing}
  kind isa _IntervalMs && return String(sql)
  kind isa CInterval && _is_bare_column(side) && return Dialect._sqlite_interval_ms(sql)
  return nothing
end

# #881 — a duration literal as the milliseconds it binds against an `_IntervalMs` side, rounded half
# away from zero as the difference is. A month or a year has no fixed length, so it has no millisecond
# count (PostgreSQL's `interval` keeps months apart for the same reason).
function _duration_ms(p)::Int64
  period = p isa Interval ? p.period : p
  ns = try
    Models._duration_to_nanoseconds(period)
  catch e
    e isa InvalidValueError || rethrow()
    throw(QueryBuildError("A duration of months or years ($(period)) has no fixed length, so it cannot be " *
                          "combined with a timestamp difference on SQLite. Use weeks, days or a time: " *
                          "Day(30), Hour(1)."))
  end
  return _ns_to_ms(ns)
end
function _ns_to_ms(ns::Int64)::Int64
  q, r = divrem(ns, 1_000_000)
  return 2 * abs(r) >= 1_000_000 ? q + sign(ns) : q
end

# #894 — a filter value as the milliseconds it binds against an interval that is compared as a number,
# or `nothing` when it is not a duration: a `Period`, an `Interval`, or a duration string in a
# `DurationField`'s accepted forms. `nothing` sends the caller back to the text comparison, so a value
# that is not a duration still raises what it always raised there.
function _duration_value_ms(x)::Union{Int64,Nothing}
  x isa Interval && (x = x.period)
  ns = try
    if x isa Union{Dates.Period,Dates.CompoundPeriod}
      Models._duration_to_nanoseconds(x)   # a month or a year has no fixed length: `nothing`
    elseif x isa AbstractString
      Models._duration_string_nanoseconds(x)
    else
      return nothing
    end
  catch e
    e isa InvalidValueError || rethrow()
    return nothing
  end
  return _ns_to_ms(ns)
end

# The comparison, membership and range operators an interval compares as a number (#894), and their
# value as milliseconds, or `nothing`: another operator (a pattern lookup, `@isnull`) or a value that
# is not a duration keeps the text comparison.
const _INTERVAL_MS_PREDICATES = ("=", "!=", "<>", ">", ">=", "<", "<=")
const _INTERVAL_MS_LIST_PREDICATES = ("IN", "NOT IN", "BETWEEN", "NOT BETWEEN")
function _predicate_duration_ms(operator::AbstractString, values)
  operator in _INTERVAL_MS_PREDICATES && return _duration_value_ms(values)
  operator in _INTERVAL_MS_LIST_PREDICATES && return _duration_values_ms(values)
  return nothing
end

# Every value of a membership list or a range, or `nothing` when any one is not a duration.
function _duration_values_ms(values)::Union{Vector{Int64},Nothing}
  values isa Union{AbstractVector,Tuple} || return nothing
  out = Int64[]
  for x in values
    ms = _duration_value_ms(x)
    ms === nothing && return nothing
    push!(out, ms)
  end
  return out
end

# #894 — what a SQLite interval's VALUE becomes where the query sorts or compares it: the milliseconds,
# not the `HH:MM:SS` text a projection returns. Text order is numeric order only below 100 hours and
# for non-negative values (`"100:00:00" < "99:00:00"`), which is right for a lap time and silently
# wrong for a timestamp difference. #881 made every comparison INSIDE an expression numeric; this is
# the same rule for the projected value itself — `order_by` on its alias, a filter on its alias — and
# for a bare `DurationField` column.
#
# Renders `node` exactly ONCE, into the active parameter bucket, and returns `(sql, true)` with its
# millisecond form, or `(sql, false)` with exactly the SQL `_get_select_query` renders for it when it
# has none. So a caller that falls back to the text still binds what the projection binds — there is
# no speculative render whose parameters would have to be taken back.
#
#   - interval arithmetic and a timestamp difference: `_render_expr_typed`'s `_IntervalMs`, before
#     `_finalize_render` turns it into text;
#   - a `DurationField` column, bare or through `F(...)`: its stored text parsed in SQL
#     (`Dialect._sqlite_interval_ms`), which repeats the column reference and binds nothing;
#   - a function in `_INTERVAL_MS_FUNCTIONS` over either (`_render_function_typed`): `Max`/`Min`
#     (#894), and `Sum`/`Avg`, `Greatest`/`Least` and `Coalesce` (#900).
#
# Anything else — `Case`, a window function — is text, and sorts as text.
function _render_interval_ms(node, instruc::SQLInstruction; _as::Union{Nothing,String}=nothing)::Tuple{String,Bool}
  sql, ms, _ = _render_interval_operand(node, instruc; _as = _as)
  return ms === nothing ? (sql, false) : (ms, true)
end

# #900 — one operand of a function that may be an interval, rendered exactly ONCE: `(sql, ms, interval)`.
# `sql` is exactly what `_get_select_query` renders for it — the text on SQLite. `ms` is its SQLite
# millisecond form, or `nothing` (always `nothing` on PostgreSQL, which computes on the `interval`
# itself). `interval` says whether the operand is an interval at all, on either engine, and types the
# function's projection. Both forms are built from the one render: the text of an `_IntervalMs` is
# `_sqlite_interval_text` over it, and a `DurationField` column's millisecond form repeats a column
# reference, which binds nothing. So a caller picks either form after the fact without a second
# render, and a function whose operands disagree keeps the SQL it always rendered.
function _render_interval_operand(node, instruc::SQLInstruction;
                                  _as::Union{Nothing,String}=nothing)::Tuple{String,Union{String,Nothing},Bool}
  sqlite = instruc.connection isa PormGSQLite
  if node isa FExpression
    raw, kind = _render_expr_typed(node, instruc)
    sql, final_kind = _finalize_render(raw, kind, instruc)
    return sql, sqlite ? _interval_ms_sql(raw, node, kind) : nothing, final_kind isa CInterval
  elseif node isa FObject
    raw, ms, interval = _render_function_typed(node, instruc; _as = _as)
    ms && return Dialect._sqlite_interval_text(raw), raw, true
    return raw, nothing, interval || _function_projection_kind(node, instruc) isa CInterval
  elseif sqlite && node isa SQLText && (literal_ms = _duration_literal_ms(node.field)) !== nothing
    # #907: a duration literal binds its milliseconds ONCE, and its text is that bound number formatted
    # in SQL — which is the text `format_duration_sql` binds for it, because `_duration_literal_ms`
    # admits only a value with a whole number of milliseconds. So the literal has both forms from one
    # bind, as a `DurationField` column does, and a function that falls back to the text prints it
    # with the value it always compared. Binding the text first and the number later is not an option:
    # SQLite's parameters are positional, and a later operand may already have bound after it.
    ph = add_parameter!(instruc, literal_ms)
    return Dialect._sqlite_interval_text(ph), ph, true
  end
  sql = _get_select_query(node, instruc; _as = _as)
  # Render first, then type: resolving the path is what populates the memo the kind lookup reads.
  bare = node isa SQLField ? node.field : node
  interval = _operand_kind(bare, instruc) isa CInterval
  ms = sqlite && interval && _is_bare_column(bare) ? Dialect._sqlite_interval_ms(sql) : nothing
  return sql, ms, interval
end

# #894 — whether a projection's source can have a millisecond form, decided WITHOUT rendering it. The
# caller already knows the projection is an interval (its recorded kind is `CInterval`); this rules
# out only the shapes `_render_interval_ms` would hand back as text anyway, so their ORDER BY and
# alias filters keep the one alias reference (or memoized text) they always had instead of a re-render.
_interval_ms_candidate(::FExpression) = true
_interval_ms_candidate(p::String) = _is_bare_column(p)
_interval_ms_candidate(p::SQLField) = _interval_ms_candidate(p.field)
_interval_ms_candidate(::JoinedReference) = true
function _interval_ms_candidate(p::FObject)
  if p.function_name in _INTERVAL_MS_AGGREGATES
    return !(p.column isa AbstractVector) && _interval_ms_candidate(p.column)
  elseif p.function_name in _INTERVAL_MS_VARIADIC
    # A declared `output_field` is a cast (#852) the milliseconds would have to go through: keep it.
    declared = get(p.kwargs, "output_field", nothing)
    return p.column isa AbstractVector && (declared === nothing || declared == "") &&
           all(x -> _is_null_operand(x) || _interval_ms_candidate(x), p.column)
  end
  return false
end
_interval_ms_candidate(p::SQLText) = _duration_literal_ms(p.field) !== nothing   # #907
_interval_ms_candidate(::Any) = false

# #907 — a duration literal's exact number of milliseconds, or `nothing`: a value that is not a
# duration, a month or a year (no fixed length), or one with a fraction of a millisecond, whose
# millisecond form would not print back as the text it binds today. Decided from the literal alone,
# before anything renders, which is what lets a function choose its form ahead of the first bind.
function _duration_literal_ms(x)::Union{Int64,Nothing}
  x isa Interval && (x = x.period)
  x isa Union{Dates.Period,Dates.CompoundPeriod} || return nothing
  ns = try
    Models._duration_to_nanoseconds(x)
  catch e
    e isa InvalidValueError || rethrow()
    return nothing
  end
  q, r = divrem(ns, 1_000_000)
  return r == 0 ? q : nothing
end

_is_null_operand(x) = x isa SQLText && _is_null_literal(x.field)

# The functions whose value has a millisecond form when their operands do (#894, #900). The one-operand
# aggregates: `MAX`/`MIN` keep an operand's value, and `SUM`/`AVG` compute one, as PostgreSQL's
# `sum(interval)` and `avg(interval)` do. The variadic ones keep one of their operands' values, and
# need every non-NULL operand in milliseconds — the text of one beside the number of another compares
# nothing. `Greatest`/`Least` reach `Coalesce` through #844's rotations, so the three share one path.
const _INTERVAL_MS_AGGREGATES = ("MAX", "MIN", "SUM", "AVG")
const _INTERVAL_MS_VARIADIC = ("GREATEST", "LEAST", "COALESCE")

# #894 — the source of the projection named `name` when it is a SQLite interval that may have a
# millisecond form, or `nothing`. Decided without rendering anything, so a caller can check its other
# conditions before it commits to a render that binds. SQLite only — PostgreSQL orders and compares
# the `interval` itself.
function _projected_interval_source(name::AbstractString, instruc::SQLInstruction)::Union{SQLField,Nothing}
  instruc.connection isa PormGSQLite || return nothing
  get(instruc.projection_kinds, Symbol(name), nothing) isa CInterval || return nothing
  source = _projected_source(memo_key(:base, name), instruc)
  source isa SQLField && _interval_ms_candidate(source.field) || return nothing
  return source
end

# The projection named `name` as SQLite milliseconds, rendered into the active bucket: `(sql, true)`;
# or `nothing` when `_projected_interval_source` has none. `(sql, false)` is the rare candidate whose
# render turned out to be text after all — still the projection's own SQL with its own bindings, so a
# caller that prints it orders and compares exactly as the alias would have.
function _render_projected_interval_ms(name::AbstractString, instruc::SQLInstruction)::Union{Tuple{String,Bool},Nothing}
  source = _projected_interval_source(name, instruc)
  source === nothing && return nothing
  return _render_interval_ms(source.field, instruc; _as = source._as)
end

# #814 — a WINDOW function cannot be inside a SQLite interval. The interval becomes text in a correlated
# scalar subquery (`Dialect._sqlite_interval_text`), and a window is evaluated over the rows of the
# SELECT it appears in, which there is exactly one: `LAG(x) OVER (…)` there is NULL on every row and
# `FIRST_VALUE(x)` is `x`, silently (measured on SQLite 3.45). An aggregate is safe — SQLite attributes
# an aggregate over outer columns to the outer query — so only a window is refused. Its value can
# still be used on SQLite once it is a column: project it in a CTE or a subquery first.
_has_window_function(::WindowFunction) = true
_has_window_function(x::FExpression) = _has_window_function(x.field_name) || _has_window_function(x.operand)
# `kwargs` too: `When(…; then = Lag(…))` keeps its branch value there, not in `column`.
_has_window_function(x::FObject) = _has_window_function(x.column) || any(_has_window_function, values(x.kwargs))
_has_window_function(x::SQLField) = _has_window_function(x.field)
_has_window_function(x::AbstractVector) = any(_has_window_function, x)
_has_window_function(::Any) = false

function _refuse_window_in_interval(left, right, instruc::SQLInstruction)
  instruc.connection isa PormGSQLite && (_has_window_function(left) || _has_window_function(right)) || return nothing
  throw(QueryBuildError("A window function (Lag, Lead, FirstValue, …) cannot be a side of a timestamp " *
                        "difference, or of arithmetic on one, on SQLite: the interval is turned into text in " *
                        "a subquery, where the window sees one row. Project the window value in a CTE first " *
                        "and use the column."))
end

const _ARITHMETIC_OPERATIONS = ("+", "-", "*", "/")

# #814 — the operators whose answer depends on ORDER, as opposed to equality.
const _ORDERING_OPERATIONS = (">", "<", ">=", "<=")

# #881 — what SQLite still cannot do with an interval, each because the matching PostgreSQL
# expression has no operator either (`interval + integer`, `interval * interval`, `integer / interval`
# fail when the statement runs) or because the side has no millisecond form (`_interval_ms_sql`).
# Refused at build time on SQLite, where it would otherwise compute on text or on a number, silently.
_sqlite_interval_error(what::AbstractString) =
  QueryBuildError("$(what) is not supported on SQLite. An interval there is a timestamp difference, a " *
                  "DurationField column or a duration (Hour(1)); it combines with another interval " *
                  "(+, -, comparisons), with a number (* and /), or with a date (date + interval).")

# #801 — the RIGHT side of a binary expression, rendered AND typed, for the one caller that must know
# what the right evaluates to: a `-` over a temporal left. Rendered exactly once — a second render
# would bind its parameters a second time.
#
# Only the operands `F(...) - x` can carry reach here (`Integer`, `Float64`, `String`, `FExpression`,
# a function — the `Base.:-` overloads in `operators.jl`). A nested expression reports the kind it
# EVALUATES to, not its rooted column's: `F("date") - (F("date") + Hour(6))` is a timestamp
# difference. A `String` that names a field is the `F(...)` it stands for, which is the route
# `_set_update_query_operand` already takes. Everything else — a function, a text literal, a number —
# has no kind this build can know, and answers `nothing`.
#
# #814 widened what has a kind: a function is typed as the projection path types it (`_side_kind`),
# and a date literal (`F("date") - Date(2009, 3, 1)`) by its own Julia type — bound in the
# representation of THAT kind, since the difference reads both sides as the instants they are. On
# PostgreSQL it carries the cast that names it, because `date - $1` has three candidate operators
# (`date - date`, `date - integer`, `date - interval`) and an uncast parameter is ambiguous among them.
function _render_operand_typed(operand::Any, field_name::Any, operation::String, instruc::SQLInstruction;
                               left_kind::TemporalKind = nothing)::Tuple{String,_RenderKind}
  # #985: a comparison's right side, inside an ON clause; arithmetic inherits the side it sits on.
  if operation in _COMPARISON_OPERATIONS && _join_side_change(instruc, :right) !== nothing
    return _on_join_right(() -> _render_operand_typed(operand, field_name, operation, instruc;
                                                      left_kind = left_kind), instruc)
  end
  operand isa FExpression && return _render_expr_typed(operand, instruc)
  operand isa FObject && return _render_function_operand_typed(operand, instruc)   # #907
  if operand isa String && _is_field_path(operand, instruc)
    return _render_expr_typed(FExpression(field_name = operand, function_name = "F", column = operand), instruc)
  end
  if operand isa _TemporalLiteral
    kind = literal_canonical_kind(operand)
    # A timestamp literal binds the canonical UTC text (`…+00:00`). Against a `timestamp` column (no
    # time zone) it is cast to that type, whose input ignores the offset and keeps the UTC wall time
    # the column itself stores; everything else casts to `timestamptz`, which reads the offset.
    sql_type = !(instruc.connection isa PormGPostgres) ? nothing :
               kind isa CDate ? "date" :
               left_kind == CDateTime(false) ? "timestamp" : "timestamptz"
    return add_parameter!(instruc, value_formatter(kind, instruc.connection)(operand); sql_type = sql_type), kind
  end
  sql = _set_update_query_operand(operand, field_name, operation, instruc; left_kind = left_kind)
  return sql, operand isa SQLTypeFunction ? _side_kind(operand, instruc) : nothing
end

# A `String` operand names a FIELD when it is a path or one of the model's own fields; otherwise it
# is a text literal. The rule `_set_update_query_operand`'s String arm applies.
_is_field_path(s::String, instruc::SQLInstruction) = contains(s, "__") || s in instruc.object.model.field_names

# #814 — A DAY COUNT COMBINED WITH A DATE: `date ± count` and `count + date`, where the count is a
# `DATE - DATE` difference (`CInt32`). PostgreSQL has `date ± integer` and `integer + date` as whole-
# day shifts, and SQLite added the date's YEAR to the integer, silently. Rendered as the shift
# PostgreSQL means, on both, and typed as the DATE side's kind.
#
# PostgreSQL: native for a DATE; a timestamp has no `+ integer`, so the count becomes
# `make_interval(days => …)`. SQLite: through the julian-day NUMBER, `julianday(d) ± n`, then back to
# the side's stored text. The number keeps the TEXT ORDER of the two sides as written, which is the
# order their parameters were bound in. A modifier (`date(d, n || ' days')`) cannot do that for
# `count + date`, since the count would print after the date it was bound before. SQLite rounds a
# julian number to the millisecond when it formats it, which is a stored timestamp's own precision.
function _render_day_count_shift(date_side::AbstractString, date_kind::Union{CDate,CDateTime},
                                 count_side::AbstractString, operation::String, date_first::Bool,
                                 instruc::SQLInstruction)::String
  if instruc.connection isa PormGPostgres
    days = date_kind isa CDate ? count_side : "make_interval(days => $(count_side))"
    return date_first ? "($(date_side) $(operation) $(days))" : "($(days) + $(date_side))"
  elseif instruc.connection isa PormGSQLite
    jd = date_first ? "julianday($(date_side)) $(operation) ($(count_side))" :
                      "($(count_side)) + julianday($(date_side))"
    return date_kind isa CDate ? "date($(jd))" : sql_canonicalize(date_kind, instruc.connection, jd)
  else
    throw(_unsupported_conn("date shift by a day count", instruc.connection))
  end
end

# #814/#881 — a date or timestamp shifted by an INTERVAL value (a `DurationField`, or the difference
# of two timestamps) rather than by a duration literal. PostgreSQL's `timestamp ± interval` is native
# and its SQL is left alone. SQLite stores both as text, where `+` added the year to the hours,
# silently; #814 refused it. #881 shifts the julian-day number by the interval's milliseconds, through
# the day-count shift above, so the date may be on either side and its text order is kept.
#
# PostgreSQL's `date ± interval` is a `timestamp`, so a DATE side becomes `CDateTime(false)`; a
# timestamp keeps its own kind. Typed on both engines, so both read the result back the same way.
function _render_interval_shift(date_side::AbstractString, date_kind::Union{CDate,CDateTime},
                                interval_side::AbstractString, interval_node, interval_kind::_RenderKind,
                                operation::String, date_first::Bool, instruc::SQLInstruction)::Tuple{String,_RenderKind}
  kind = date_kind isa CDate ? CDateTime(false) : date_kind
  if instruc.connection isa PormGSQLite
    ms = _interval_ms_sql(interval_side, interval_node, interval_kind)
    ms === nothing &&
      throw(_sqlite_interval_error("Shifting a date by an interval that is not a timestamp difference or a " *
                                   "DurationField column"))
    return _render_day_count_shift(date_side, kind, "($(ms)) / 86400000.0", operation, date_first, instruc), kind
  end
  sql = date_first ? "($(date_side) $(operation) $(interval_side))" : "($(interval_side) + $(date_side))"
  return sql, kind
end

# A side a duration can be multiplied or divided by: a typed number, or a value PormG does not type —
# but not a text literal, and not a bare column that holds no number. A text, UUID or boolean column
# also has no canonical kind, and SQLite multiplied the milliseconds by its numeric prefix, silently
# (PostgreSQL has no `interval * varchar`). Review of #881.
const _NUMERIC_FIELDS = Union{Models.sIntegerField, Models.sPositiveIntegerField, Models.sPositiveSmallIntegerField,
                              Models.sBigIntegerField, Models.sFloatField, Models.sDecimalField}
function _is_number_side(side, kind::_RenderKind, instruc::SQLInstruction)::Bool
  kind isa Union{CInt32,CInt64,CDecimal} && return true
  kind === nothing || return false
  side isa Bool && return false                                        # `Bool <: Integer`, but not a number
  side isa String && !_is_field_path(side, instruc) && return false   # a text literal
  _is_bare_column(side) || return true                                 # untyped arithmetic, a function
  f = _operand_column_field(side, instruc)
  return f === nothing || f isa _NUMERIC_FIELDS
end

# #881 — EVERYTHING AN INTERVAL ON THE LEFT COMBINES WITH, on both engines: a timestamp difference
# (`_IntervalMs` on SQLite, `CInterval` on PostgreSQL), arithmetic on one, or a `DurationField` column
# (`CInterval` on both). `± duration` never reaches here (`_render_date_period_arithmetic` owns it).
#
# PostgreSQL renders the SQL it always rendered; what changes there is the KIND. Interval arithmetic
# is typed `CInterval`, so `(d + d) > Hour(1)` binds the duration as an interval, as `d > Hour(1)`
# does, and a projected `d + d` reads back as a `Dates.CompoundPeriod`. SQLite computes on
# milliseconds (`_interval_ms_sql`) and refuses what has no millisecond form, or no operator on
# PostgreSQL either.
#
# One rule keeps the old text comparison: a `DurationField` column tested for EQUALITY against a
# literal or another column compares its stored text, as before #881. Ordering one (`<`, `>`) compares
# its milliseconds since #894.
function _render_interval_left(v::FExpression, left_side::String, left_kind::_RenderKind,
                               instruc::SQLInstruction)::Tuple{String,_RenderKind}
  op = v.operation
  sqlite = instruc.connection isa PormGSQLite
  bind_kind = left_kind isa _IntervalMs ? CInterval() : left_kind   # what the binder may see
  expr_right = v.operand isa FExpression || (v.operand isa String && _is_field_path(v.operand, instruc))

  if op in _COMPARISON_OPERATIONS
    if expr_right
      right_side, right_kind = _render_operand_typed(v.operand, v.field_name, op, instruc; left_kind = bind_kind)
      if sqlite && (left_kind isa _IntervalMs || right_kind isa _IntervalMs)
        lms = _interval_ms_sql(left_side, v.field_name, left_kind)
        rms = _interval_ms_sql(right_side, v.operand, right_kind)
        lms !== nothing && rms !== nothing && return "($(lms) $(op) $(rms))", nothing
        op in _ORDERING_OPERATIONS &&
          throw(_sqlite_interval_error("Ordering (`$(op)`) an interval against a value with no millisecond form"))
      end
      # #894: two `DurationField` columns ORDERED against each other compare their milliseconds too.
      # Equality keeps the text: it is exact for a canonical value, and `==` on a column stays sargable.
      if sqlite && op in _ORDERING_OPERATIONS && left_kind isa CInterval && right_kind isa CInterval
        lms = _interval_ms_sql(left_side, v.field_name, left_kind)
        rms = _interval_ms_sql(right_side, v.operand, right_kind)
        lms !== nothing && rms !== nothing && return "($(lms) $(op) $(rms))", nothing
      end
      return "($(_as_interval_text(left_side, left_kind)) $(op) $(_as_interval_text(right_side, right_kind)))", nothing
    end
    if sqlite && left_kind isa _IntervalMs
      if v.operand isa Union{Dates.Period,Dates.CompoundPeriod}
        return "($(left_side) $(op) $(add_parameter!(instruc, _duration_ms(v.operand))))", nothing
      end
      op in _ORDERING_OPERATIONS &&
        throw(_sqlite_interval_error("Ordering (`$(op)`) an interval against $(typeof(v.operand))"))
      # Equality against any other literal compares the text, exactly as before #881, and the binder
      # raises what it always raised for a literal that is not a duration.
      left_side = _as_interval_text(left_side, left_kind)
    end
    # #894: a `DurationField` column ORDERED against a duration compares its milliseconds — its stored
    # text sorts `"100:00:00"` before `"99:00:00"`. A value that is not a duration (and a month, which
    # has no fixed length) keeps the text comparison, and the binder raises what it always raised.
    if sqlite && left_kind isa CInterval && op in _ORDERING_OPERATIONS &&
       (lms = _interval_ms_sql(left_side, v.field_name, left_kind)) !== nothing &&
       (ms = _duration_value_ms(v.operand)) !== nothing
      return "($(lms) $(op) $(add_parameter!(instruc, ms)))", nothing
    end
    return "($(left_side) $(op) $(_set_update_query_operand(v.operand, v.field_name, op, instruc; left_kind = bind_kind)))", nothing
  end

  if op in _ARITHMETIC_OPERATIONS
    right_side, right_kind = _render_operand_typed(v.operand, v.field_name, op, instruc; left_kind = bind_kind)
    if op in ("+", "-")
      if right_kind isa Union{CDate,CDateTime}
        op == "-" &&
          throw(QueryBuildError("A duration minus a date has no meaning. To move a date back, subtract from " *
                                "the date instead: F(\"date\") - (F(\"date\") - F(\"dob\")), or " *
                                "F(\"date\") - Day(30)."))
        return _render_interval_shift(right_side, right_kind, left_side, v.field_name, left_kind, "+", false, instruc)
      end
      if _is_interval_kind(right_kind)
        sqlite || return "($(left_side) $(op) $(right_side))", CInterval()
        lms = _interval_ms_sql(left_side, v.field_name, left_kind)
        rms = _interval_ms_sql(right_side, v.operand, right_kind)
        (lms === nothing || rms === nothing) &&
          throw(_sqlite_interval_error("`$(op)` with an interval that is not a timestamp difference or a DurationField column"))
        _refuse_window_in_interval(v.field_name, v.operand, instruc)
        return "($(lms) $(op) $(rms))", _IntervalMs()
      end
      sqlite && throw(_sqlite_interval_error("`$(op)` between an interval and a number"))
      return "($(left_side) $(op) $(right_side))", nothing
    end
    # `*` and `/`, by a number only.
    if _is_number_side(v.operand, right_kind, instruc)
      sqlite || return "($(left_side) $(op) $(right_side))", CInterval()
      lms = _interval_ms_sql(left_side, v.field_name, left_kind)
      lms === nothing &&
        throw(_sqlite_interval_error("`$(op)` on an interval that is not a timestamp difference or a DurationField column"))
      _refuse_window_in_interval(v.field_name, v.operand, instruc)
      product = op == "*" ? "($(lms)) * ($(right_side))" : "($(lms)) * 1.0 / ($(right_side))"
      return "CAST(round($(product)) AS INTEGER)", _IntervalMs()
    end
    sqlite && throw(_sqlite_interval_error("`$(op)` between an interval and $(right_kind === nothing ? "a value that is not a number (text, a boolean, a UUID)" : "a date or an interval")"))
    return "($(left_side) $(op) $(right_side))", nothing
  end

  # Any other operator (bitwise, …) has no interval meaning; the interval is its text, as before #881.
  left_side = _as_interval_text(left_side, left_kind)
  return "($(left_side) $(op) $(_set_update_query_operand(v.operand, v.field_name, op, instruc; left_kind = bind_kind)))", nothing
end

# #881 — an interval on the RIGHT of a left that is neither a date nor an interval. Only a number
# times an interval is one (`F("points") * d`, and `2 * d`, which is `d * 2`). On SQLite, ordering a
# number against a `DurationField` column still compares the stored text, as before #881; every other
# shape has no PostgreSQL operator either and is refused there.
function _render_interval_right(v::FExpression, left_side::String, left_kind::_RenderKind,
                                right_side::String, right_kind::_RenderKind,
                                instruc::SQLInstruction)::Tuple{String,_RenderKind}
  op = v.operation
  sqlite = instruc.connection isa PormGSQLite
  if op == "*" && _is_number_side(v.field_name, left_kind, instruc)
    sqlite || return "($(left_side) * $(right_side))", CInterval()
    rms = _interval_ms_sql(right_side, v.operand, right_kind)
    rms === nothing &&
      throw(_sqlite_interval_error("`*` on an interval that is not a timestamp difference or a DurationField column"))
    _refuse_window_in_interval(v.field_name, v.operand, instruc)
    return "CAST(round(($(left_side)) * ($(rms))) AS INTEGER)", _IntervalMs()
  end
  if sqlite
    right_kind isa CInterval && op in _ORDERING_OPERATIONS && return "($(left_side) $(op) $(right_side))", nothing
    throw(_sqlite_interval_error("`$(op)` with an interval on the right of a value that is not one"))
  end
  return "($(left_side) $(op) $(right_side))", nothing
end

# #801: arithmetic that has no meaning between two temporal values. PostgreSQL has no `date + date`
# operator and fails at execution; SQLite adds the two years and returns a number. Refused at build
# time on both, so the engines agree on the answer — an error — and neither is silent.
const _TEMPORAL_PAIR_REFUSED_OPERATIONS = ("+", "*", "/")

# The DURATION spelling (#25): `F(date) ± <a Dates period or an Interval>`.
function _render_date_period_arithmetic(v::FExpression, instruc::SQLInstruction)::Tuple{String,_RenderKind}
  period = v.operand isa Interval ? v.operand.period : v.operand
  comps  = _decompose_period(period)

  # Resolve the left side FIRST — see `_render_temporal_shift`'s note on why the order is the fix.
  left_side, left_kind = _render_left_typed(v.field_name, v.operation, instruc)
  # #881: `d ± Hour(1)` on a SQLite interval is millisecond arithmetic. A zero-length duration is the
  # identity and binds nothing, as `_render_temporal_shift` does on both engines.
  if left_kind isa _IntervalMs
    isempty(comps) && return left_side, left_kind
    return "($(left_side) $(v.operation) $(add_parameter!(instruc, _duration_ms(period))))", left_kind
  end
  kind = _shift_result_kind(left_kind, comps)

  # Soft validation (#25, best-effort): a duration only makes sense on a date/time column. Only
  # throw when the field is known AND known to be non-date; stay silent for unresolved/nested lefts.
  if v.field_name isa String && _field_type_known(v.field_name, instruc) &&
     _date_field_type(v.field_name, instruc) === nothing
    throw(InvalidValueError("F(\"$(v.field_name)\") ± a duration requires a DATE/TIMESTAMP field; \"$(v.field_name)\" is not a date/time column"))
  end

  return _render_temporal_shift(left_side, kind, v.operation, comps, instruc), kind
end

# `left_kind` (#564): the kind the LEFT side evaluates to, when the caller has it. Only the temporal
# literal arm reads it — the `xor` call sites legitimately have no temporal left and pass nothing.
function _set_update_query_operand(operand::Any, field_name::Any, operation::String, instruc::SQLInstruction;
                                   left_kind::TemporalKind = nothing)
  # #985: the same right side as `_render_operand_typed`, for the operands that bind or render plainly.
  if operation in _COMPARISON_OPERATIONS && _join_side_change(instruc, :right) !== nothing
    return _on_join_right(() -> _set_update_query_operand(operand, field_name, operation, instruc;
                                                          left_kind = left_kind), instruc)
  end
  if isa(operand, FExpression)
    return _set_update_query(operand, instruc)
  elseif isa(operand, SQLTypeFunction)
    return _get_select_query(operand, instruc)
  elseif isa(operand, Union{SQLTypeCTE,SQLTypeJoined})
    # #444/#481: a CTE or joined-copy handle is a COLUMN reference, exactly like the
    # `F("<cte>__col")` / `F("d.col")` spelling each replaces.
    # Without this arm it falls through to the `add_parameter!` at the bottom of this chain and
    # binds as a VALUE — `F("note") == CTE("ev","code")` rendered `"R1"."note" = ?` with no join
    # emitted at all, which is valid SQL comparing a column against a stringified handle.
    return _get_select_query(operand, instruc)
  elseif isa(operand, SubqueryObject)
    # #926: a scalar subquery, rendered as the pair spelling renders it — the filter-position arm, so
    # its values bind into the clause the comparison sits in and #194 records nothing.
    return _get_filter_query(operand, instruc)
  elseif isa(operand, Union{Dates.Date,Dates.DateTime,TimeZones.ZonedDateTime})
    # #494 — a date/timestamp literal on the right of an `F(...)` / `Joined(...)` comparison.
    # #533 added `ZonedDateTime`: it is the third temporal type the `format_*_sql` family binds, and
    # the one #530 reported. Widening `_CompareOperand` without extending THIS arm would have bound
    # it raw — which is the failure this arm's own comment describes, on a new type.
    #
    # Ahead of the generic `add_parameter!` at the bottom for the same reason the #25 duration gate
    # sits ahead of the infix branch: reaching it would bind the RAW Julia value, and
    # `add_parameter!` normalizes nothing. On PostgreSQL that survives (the driver adapts a `Date`),
    # but on SQLite a date column holds the TEXT its field formatter produced — `"2020-01-01"`, or
    # the canonical UTC string for a timestamp — so a raw bind compares against a different
    # representation and returns the wrong rows with no error at all. Silent, not loud, which is why
    # this arm is not optional.
    #
    # So the literal takes the SAME route a plain filter value takes (`_get_filter_query(::SQLTypeOper)`,
    # build_helpers.jl): run it through the field's formatter, then bind the formatted string with no
    # explicit cast, letting PostgreSQL infer the type from the comparison context exactly as an
    # ordinary `filter("date" => Date(...))` already does.
    # #576: this arm formats through `_format_date_operand` rather than `_format_filter_value`, so
    # it is not one of the thirteen — but it is a read-path formatter call one arm above the one
    # that WAS guarded, and leaving it out would make the "every formatter call on the read path
    # reaches one re-raise" claim false. No leak is reachable today (the operand union here is
    # `Date`/`DateTime`/`ZonedDateTime` and each has a concrete method), so this is the same
    # free-guard case as the two arms below it.
    # The label is DERIVED, not asserted: `_format_date_operand` picks `format_timezone_sql` for a
    # TIMESTAMP column and `format_date_sql` for a DATE one, so a hardcoded "date" would give the
    # wrong answer to "what rejected this" on exactly the timestamp path this guard exists for.
    # Computed inside the `catch`, so the happy path pays nothing for it.
    formatted_date = try
      _format_date_operand(operand, field_name, instruc; left_kind = left_kind)
    catch e
      _kind = left_kind === nothing ? _operand_column_kind(field_name, instruc) : left_kind
      _locate_filter_refusal(e, field_name,
                             _kind isa CDateTime ? _formatter_type_label(Models.format_timezone_sql) :
                                                   _formatter_type_label(Models.format_date_sql))
    end
    return add_parameter!(instruc, formatted_date)
  elseif operation in _COMPARISON_OPERATIONS &&
         isa(operand, Union{Integer,Float16,Float32,Float64,Base.UUID,Dates.Time,Dates.Period,Dates.CompoundPeriod})
    # #536 — every other `_CompareLiteral` scalar on the right of a COMPARISON, bound the way the
    # pair spelling binds it: through the rooted column's formatter, with no explicit SQL type. The
    # column decides, not the value's Julia type — `F("points") == true` on an IntegerField binds
    # `1` (`format_number_sql(::Bool)`), on a BooleanField `true` (`format_bool_sql`), and a `Float64`
    # binds `format_number_sql`'s `"1.5"` string rather than the raw `1.5` this used to fall through
    # to. On PostgreSQL the raw bind survived (the driver adapts it); on SQLite a column whose
    # formatter produces TEXT compared against a different representation and matched nothing, with
    # no error — which is why this arm sits ahead of the typed binds below.
    #
    # `Bool <: Integer`, so `true`/`false` arrive here too. Ahead of the Integer arm on purpose: that
    # arm is the ARITHMETIC one (date offsets, bitwise shifts), and only comparisons take this route.
    #
    # No column to ask (a nested expression rooted in a function, an unresolvable path): fall back to
    # the value's own formatter family — still a formatted value, never a raw bind — mirroring what
    # `_format_date_operand` does one arm up.
    f = _operand_column_field(field_name, instruc)
    column_formatter = f === nothing ? nothing : f.formatter
    # #801: the rooted column decides only while the left still EVALUATES to that column's kind.
    # `F("date") - F("dob")` is rooted at a DateField and evaluates to a day count, so
    # `(F("date") - F("dob")) > 30` bound `format_date_sql(30)` — an `InvalidValueError` on both
    # engines. When the kinds differ, the LEFT's kind decides through the #564 table: a day count has
    # no formatter there, so the literal falls to its own family below; a sub-day-promoted date is a
    # timestamp, so `(F("date") + Hour(6)) > 5` still refuses the `5` instead of binding an integer
    # SQLite would compare against TEXT (always true, silently). A left the build could not type
    # (`nothing`) keeps the root, as it always has: `(F("date") * 2) > 5` binds exactly as before.
    if left_kind !== nothing && f !== nothing && left_kind != field_canonical_kind(f)
      column_formatter = value_formatter(left_kind, instruc.connection)
    end
    # #814: an interval left with NO rooted column — `Max(ts) - Min(ts)`, a window difference — has
    # no column formatter to override, so it falls to the literal's own family below, and a duration
    # reached `format_number_sql(::Hour)`, a raw `MethodError`. The left's kind names the formatter.
    left_kind isa CInterval && f === nothing && (column_formatter = value_formatter(left_kind, instruc.connection))
    # #814: a duration and an interval belong together, in both directions. The kind that decides is
    # the left's, else the rooted column's — on SQLite only while the left IS that column. Untyped
    # arithmetic over a DurationField (`F("lap") * 2`) is an interval on PostgreSQL (`interval * 2`),
    # but on SQLite it is a NUMBER, and a duration bound against it would compare number with text.
    #   * A duration against anything else has no formatter that can bind it (`format_number_sql`
    #     has no `::Hour` method, a raw `MethodError`), and no meaning: `F("points") > Hour(1)`.
    #   * A `Time` against an interval reached `format_duration_sql`, which refuses it with a message
    #     about durations that never says why a `Time` is not one.
    rooted_kind = f === nothing ? nothing : field_canonical_kind(f)
    root_decides = !(field_name isa FExpression && field_name.operation !== nothing) ||
                   instruc.connection isa PormGPostgres
    decided_kind = left_kind !== nothing ? left_kind : root_decides ? rooted_kind : nothing
    if operand isa Union{Dates.Period,Dates.CompoundPeriod} && !(decided_kind isa CInterval)
      throw(QueryBuildError("A duration (a $(typeof(operand))) compares only against an interval — a DurationField, " *
                            "or the difference of two timestamps. To compare dates, shift one instead: " *
                            "F(\"date\") + Day(30) > F(\"other_date\")."))
    elseif operand isa Dates.Time && (decided_kind isa CInterval || rooted_kind isa CInterval)
      throw(QueryBuildError("A Time is a time of day, not a duration, so it does not compare " *
                            "against an interval. Write the duration instead: Hour(1), Minute(90), " *
                            "Hour(1) + Minute(30)."))
    end
    formatter = column_formatter !== nothing ? column_formatter :
                operand isa Base.UUID ? Models.format_uuid_sql :
                operand isa Dates.Time ? Models.format_text_sql :
                Models.format_number_sql
    # The BYTES are the pair path's; the SQL-text cast is not, and deliberately so — but only where
    # the cast agrees with the column. A numeric literal against a NUMERIC column (its formatter is
    # `format_number_sql`), or against no resolvable column, keeps the explicit PostgreSQL cast the
    # raw arms always gave it (`$1::bigint`, `$1::double precision`, pinned by `test_operators.jl`'s
    # bitwise examples): it is what lets `F("number") > 2.5` compare an integer column against a
    # double, where an uncast `$1` would be inferred as integer from the column and PostgreSQL would
    # reject "2.5". Everything else binds UNCAST, like a pair, so PostgreSQL types the parameter from
    # the column: a `Bool` (its formatted value is the column's — `1` on an IntegerField, `true` on a
    # BooleanField), a UUID or a Time, and a numeric literal against a text or boolean column —
    # `F("flag") == 1` binds `true` and must not carry `::bigint` (review of #536 measured the cast
    # following the LITERAL there: `"flag" = $1::bigint` with `true` bound, a PostgreSQL error).
    numeric_column = column_formatter === nothing || column_formatter === Models.format_number_sql
    sql_type = numeric_column && operand isa Union{Integer,Float16,Float32,Float64} && !(operand isa Bool) ?
               _infer_parameter_sql_type(operand, instruc) : nothing
    # #576: this arm was unguarded, and the issue listed it as SUSPECTED. Guarded since, and the guard
    # became load-bearing with #860: `format_text_sql` now refuses anything it cannot render as text
    # with `InvalidValueError`, so `F("surname") == 1.5` (a float or a UUID against a text column)
    # reaches it and reports an `InvalidValueError` (a `FilterError` until #971). The pairs this arm can still form against
    # `format_number_sql` (`::UUID`, `::Time`) have no method, so they raise `MethodError`, which
    # `_locate_filter_refusal` rethrows untouched by design.
    #
    # `field_name` is in scope, but `f` may be `nothing` (a nested expression, an unresolvable
    # path) — there the formatter came from the OPERAND's own type above, so the type label comes
    # from the formatter rather than from a column that was never found. The same when the left's
    # kind overrode the column's (#801): the column's `type` would name a formatter not used.
    return add_parameter!(instruc,
      _guarded_format(formatter, operand, operation, field_name,
                      f !== nothing && formatter === f.formatter ? f.type : _formatter_type_label(formatter));
      sql_type=sql_type)
  elseif isa(operand, String)
    # Check if it's a field reference
    if contains(operand, "__") || operand in instruc.object.model.field_names
      return _set_update_query(FExpression(field_name = operand, function_name = "F", column = operand), instruc)
    else
      # Keep scalar literals parameterized with an explicit SQL type on PostgreSQL so
      # expressions like integer_column / 2.0 don't get inferred back to integer.
      return add_parameter!(instruc, operand; sql_type=_infer_parameter_sql_type(operand, instruc))
    end
  elseif isa(operand, Integer)
    # SECURITY: parameterize the integer (bitwise shifts and ordinary arithmetic).
    #
    # #568 — the date arm that used to live here is GONE. It bound the placeholder FIRST and only
    # then asked whether the left was a date column, so on PostgreSQL a nested left arrived already
    # bound as `$n::bigint` and produced `timestamp with time zone + bigint`, which has no operator.
    # Whole days are now normalized into `Day(n)` by `_set_update_query_typed` BEFORE this function
    # is reached, so an integer that survives to here is genuinely arithmetic, never a duration.
    sql_type = (operation in ["<<", ">>"]) ? "integer" : _infer_parameter_sql_type(operand, instruc)
    return add_parameter!(instruc, operand; sql_type=sql_type)
  else
    # SECURITY: Use parameterized query for other numeric values
    return add_parameter!(instruc, operand; sql_type=_infer_parameter_sql_type(operand, instruc))
  end
end

function _set_update_query_left(value::Any, operation::String, instruc::SQLInstruction)
  if value isa String
    return _get_filter_query(value, instruc)
  elseif value isa Integer
    sql_type = (operation in ["<<", ">>"]) ? "integer" : _infer_parameter_sql_type(value, instruc)
    return add_parameter!(instruc, value; sql_type=sql_type)
  elseif value isa FExpression
    return _set_update_query(value, instruc)
  elseif value isa SQLTypeFunction
    return _get_select_query(value, instruc)
  else
    return _set_update_query(value, instruc)
  end
end

# #444: a bare CTE handle as an UPDATE SET value. Resolving it through the ordinary column path is
# what makes `update()`'s no-WITH-clause refusal (#433) fire with its own accurate message instead of
# a `MethodError` from the field formatter.
_set_update_query(v::CTEReference, instruc::SQLInstruction) = _get_select_query(v, instruc)

# #481: the same for a joined-copy handle. This is also the recursion target that renders the LEFT
# side of `Joined("d","x") == F("y")`, since `_set_update_query(::FExpression)` forwards a
# non-String `field_name` here.
_set_update_query(v::JoinedReference, instruc::SQLInstruction) = _get_select_query(v, instruc)

# #564 — the temporal path renders AND types, in one pass.
#
# `_set_update_query` keeps its `String` contract for every caller (`_get_select_query(::SQLTypeF)`
# in `build_helpers.jl`, through which SELECT, WHERE-side `F` comparisons and UPDATE SET all funnel;
# the insert path; the recursive operand and left-side calls). Only this file's own temporal
# recursion reads the second element, so nothing downstream had to change.
#
# EVERY ARM MUST RETURN A KIND EXPLICITLY. A missed arm returns `nothing`, and `nothing` degrades to
# `date(...)` on SQLite — which is the #527 truncation, silently. There is no arm where "it does not
# matter": where the result is genuinely not temporal, `nothing` is the ANSWER, not the default.
_set_update_query(v::FExpression, instruc::SQLInstruction) = first(_set_update_query_typed(v, instruc))

# #881 — the two doors out of the renderer (`_set_update_query` above, the projection in
# `build_query.jl`) see only kinds a reader or a binder can act on: an interval the renderer held in
# milliseconds leaves as its stored text, typed `CInterval`. Inside, `_render_expr_typed` and its
# helpers pass `_IntervalMs` along, so an interval stays a number for as long as it is being computed.
_set_update_query_typed(v::FExpression, instruc::SQLInstruction)::Tuple{String,TemporalKind} =
  _finalize_render(_render_expr_typed(v, instruc)..., instruc)

function _render_expr_typed(v::FExpression, instruc::SQLInstruction)::Tuple{String,_RenderKind}
  if v.operation === nothing
    # Resolve the field using existing logic for joins and modifiers
    if v.field_name isa String
      # Render before typing: resolving the path is what populates the memo the kind lookup reads.
      # The column's TRUE kind, not the arithmetic-narrowed one: a bare `F(col)` projection over a
      # `TimeField` or a `DurationField` has a representation the read path must undo. Each CONSUMER
      # states which kinds it can act on, rather than the producer pre-narrowing for all of them.
      sql = _get_filter_query(v.field_name, instruc)
      return sql, _side_kind(v.field_name, instruc)
    elseif v.field_name isa Integer
      # A bare integer is a value, not a column — no representation to carry.
      return add_parameter!(instruc, v.field_name; sql_type=_infer_parameter_sql_type(v.field_name, instruc)), nothing
    else
      # Recursive call for nested expressions
      return _render_left_typed(v.field_name, "", instruc)
    end
  elseif v.operation == "~"
    # Unary NOT operator. Bitwise, never temporal.
    left_side = _set_update_query_left(v.field_name, v.operation, instruc)
    return "~($(left_side))", nothing
  elseif v.operation == "xor"
    # Bitwise, never temporal — on either engine.
    if instruc.connection isa PormGPostgres
      left_side = _set_update_query_left(v.field_name, v.operation, instruc)
      right_side = _set_update_query_operand(v.operand, v.field_name, v.operation, instruc)
      return "($(left_side) # $(right_side))", nothing
    elseif instruc.connection isa PormGSQLite
      # Positional Parameter Alignment: render each side twice to duplicate any embedded parameters
      left_side1 = _set_update_query_left(v.field_name, v.operation, instruc)
      right_side1 = _set_update_query_operand(v.operand, v.field_name, v.operation, instruc)

      left_side2 = _set_update_query_left(v.field_name, v.operation, instruc)
      right_side2 = _set_update_query_operand(v.operand, v.field_name, v.operation, instruc)

      return "((($(left_side1)) | ($(right_side1))) - (($(left_side2)) & ($(right_side2))))", nothing
    else
      throw(_unsupported_conn("xor update expression", instruc.connection))
    end
  elseif v.operation in ("+", "-") && v.operand isa Union{Dates.Period, Dates.CompoundPeriod, Interval}
    # Date arithmetic with an explicit Julia duration type (#25). Handled ahead of the generic
    # infix branch: a Period operand must NOT reach `_set_update_query_operand`, which would try to
    # bind it as a raw SQL parameter.
    return _render_date_period_arithmetic(v, instruc)
  else
    # Field with operation - handle nesting and date arithmetic properly.
    #
    # RENDER THE LEFT FIRST, THEN ASK WHAT IT IS. That order is the whole of #568's fix and is not
    # negotiable: rendering is what populates `instruc.tab_field_cache` for a dotted join key, so
    # `F("driverid__dob") + 30` can only be typed afterwards. Deciding first types every joined
    # temporal column as `nothing` and silently drops it to plain arithmetic.
    left_side, left_kind = _render_left_typed(v.field_name, v.operation, instruc)

    # #568 — A BARE INTEGER ON ± OVER A TEMPORAL LEFT IS WHOLE DAYS, rendered by the one temporal
    # renderer rather than by a second implementation. Ahead of the operand bind below, because that
    # bind is what used to break PostgreSQL: it stamped `$n::bigint` on the parameter before anything
    # asked whether the left was temporal, and `timestamp with time zone + bigint` has no operator.
    #
    # The two implementations this replaces both gated on `v.field_name isa String`, while the
    # DURATION path gates on the OPERAND's type. That asymmetry was the whole of #568: a duration
    # composes over nesting and an integer did not, so `(F(c) + 7) + 3` fell through to plain numeric
    # addition — a silent `2012` on SQLite (TEXT with NUMERIC affinity), a hard error on PostgreSQL.
    # `F(c) + 7` alone was correct on both since #527; only the nested spelling failed, and only
    # because of where the test was written.
    #
    # Normalized at RENDER time, not at construction time (`operators.jl`'s `+`/`-` overloads), for two
    # reasons that are not close calls:
    #   * there is no type information at construction — `F("points") + 10` and `F("dob") + 10` are
    #     the same node shape, so an unconditional rewrite would send integer-column arithmetic into
    #     the date renderer and trip its soft validation on every one of them;
    #   * `FExpression` is a `struct` and the `F` docstring promises a caller may bind and reuse a
    #     node, so `x = F("dob") + 7` must still report `operand == 7`. The node stays faithful to
    #     what the user wrote; only the rendering is unified.
    #
    # `!(v.operand isa Bool)` because `Bool <: Integer` in Julia: without it `F("ts") + true` would
    # become `Day(true)` rather than staying the arithmetic the user wrote. `Dates.Day(n)` is exact —
    # a bare integer on a date column has meant whole days since #25 — and `_decompose_period` folds
    # `Day(0)` to an empty list, so `F(c) + 0` short-circuits to the identity and binds nothing.
    # `CDate`/`CDateTime` explicitly, because the left's kind is now the column's TRUE one: a
    # `TimeField` or a `DurationField` is a temporal representation but never the left of a day
    # shift, and must keep falling through to ordinary arithmetic exactly as it did before #568.
    if left_kind isa Union{CDate,CDateTime} && v.operation in ("+", "-") &&
       v.operand isa Integer && !(v.operand isa Bool)
      comps = _decompose_period(Dates.Day(v.operand))
      kind  = _shift_result_kind(left_kind, comps)   # whole days never promote; stated, not assumed
      return _render_temporal_shift(left_side, kind, v.operation, comps, instruc), kind
    end

    # #801 — ARITHMETIC OVER A TEMPORAL LEFT asks what the RIGHT evaluates to as well. A comparison
    # never takes this branch (`F("date") > F("dob")` is the ordinary case and stays below), nor does
    # a non-temporal left, so every other expression renders byte-for-byte as it did.
    if left_kind isa Union{CDate,CDateTime} && v.operation in ("-", _TEMPORAL_PAIR_REFUSED_OPERATIONS...)
      # #814: a TEXT literal on the right is refused on both engines. It bound as text: PostgreSQL has
      # no `date - text` and failed at execution, and SQLite subtracted the leading years of the two
      # strings, silently. The literal it meant is a `Date`, which is typed and bound as one.
      if v.operand isa String && !_is_field_path(v.operand, instruc)
        throw(QueryBuildError("`F(...) $(v.operation) \"…\"`: a String on the right of date " *
                              "arithmetic is text, not a date. Pass a date instead — " *
                              "F(\"date\") - Date(2009, 3, 1) — or a field name, F(\"date\") - \"dob\"."))
      end
      right_side, right_kind = _render_operand_typed(v.operand, v.field_name, v.operation, instruc;
                                                     left_kind = left_kind)
      # #882: an integer column on the right is a day count, typed once it has rendered.
      v.operation in ("+", "-") && (right_kind = _day_count_column_kind(v.operand, right_kind, instruc))
      if right_kind isa Union{CDate,CDateTime}
        if v.operation == "-"
          kind = _difference_result_kind(left_kind, right_kind)
          kind isa CInterval && _refuse_window_in_interval(v.field_name, v.operand, instruc)
          return _render_temporal_difference(left_side, right_side, kind, instruc)
        end
        throw(QueryBuildError("`$(v.operation)` between two date/timestamp values has no meaning; only " *
                              "`-` does (a whole number of days between two dates). To shift a date, " *
                              "add a duration instead: F(\"date\") + Day(30)."))
      end
      # #814: `date ± count` is a whole-day shift. #881: `date ± interval` is a shift by the interval.
      if v.operation in ("+", "-")
        if right_kind isa Union{CInt32,CInt64}
          return _render_day_count_shift(left_side, left_kind, _day_count_sql(right_side, right_kind, instruc),
                                         v.operation, true, instruc), left_kind
        end
        _is_interval_kind(right_kind) &&
          return _render_interval_shift(left_side, left_kind, right_side, v.operand, right_kind,
                                        v.operation, true, instruc)
        # #882: anything else beside a date used only the date's year on SQLite.
        _refuse_untyped_date_operand(v.operation, instruc)
      end
      # `*` and `/`: a date times an interval has no meaning on either engine; on SQLite the
      # interval would be milliseconds, so it is refused there rather than multiplied.
      right_kind isa _IntervalMs && throw(_sqlite_interval_error("`$(v.operation)` between a date and an interval"))
      return "($(left_side) $(v.operation) $(right_side))", nothing
    end

    # #881 — AN INTERVAL ON THE LEFT: a timestamp difference, arithmetic on one, or a `DurationField`
    # column. Everything it can be combined with is decided in one place, on both engines.
    _is_interval_kind(left_kind) && return _render_interval_left(v, left_side, left_kind, instruc)

    # #814 — the same pairing with the DATE on the right. `count + date` is the shift `date + count`.
    # A count MINUS a date has no meaning: PostgreSQL has no `integer - date` and failed at execution,
    # and SQLite subtracted a year. Refused on both. A count with a non-temporal right renders exactly
    # as before. (An interval on the left was decided above, by `_render_interval_left`.)
    #
    # #882: an integer column on the left is a count too (`F("points") + F("seen")`). Typed for this
    # branch only; the right still renders against the left's own kind, so an integer column with a
    # non-temporal right binds exactly as it did.
    count_kind = v.operation in ("+", "-") ? _day_count_column_kind(v.field_name, left_kind, instruc) : left_kind
    if count_kind isa Union{CInt32,CInt64} && v.operation in ("+", "-")
      right_side, right_kind = _render_operand_typed(v.operand, v.field_name, v.operation, instruc;
                                                     left_kind = left_kind)
      # #881: PostgreSQL has no `integer ± interval` and fails when the statement runs.
      _is_interval_kind(right_kind) && instruc.connection isa PormGSQLite &&
        throw(_sqlite_interval_error("`$(v.operation)` between a number and an interval"))
      if right_kind isa Union{CDate,CDateTime}
        v.operation == "-" &&
          throw(QueryBuildError("A day count minus a date has no meaning. To move a date back, subtract " *
                                "from the date instead: F(\"date\") - (F(\"date\") - F(\"dob\")), or " *
                                "F(\"date\") - Day(30)."))
        return _render_day_count_shift(right_side, right_kind, _day_count_sql(left_side, count_kind, instruc),
                                       "+", false, instruc), right_kind
      end
      return "($(left_side) $(v.operation) $(right_side))", nothing
    end

    # #814: a date literal subtracted from something that is not a date PormG can type — a number, a
    # text column, a function it does not type (`Sum`, `Coalesce` over mixed kinds). Bound as a date
    # and rendered as a bare `-`, it would subtract a year on SQLite and fail on PostgreSQL; refused
    # instead, naming the sides that are typed. `-` only: a date literal is also a COMPARISON operand
    # (#494), and `F("seen") > Date(…)` arrives here too.
    if v.operation == "-" && v.operand isa _TemporalLiteral
      throw(QueryBuildError("Subtracting a date (a $(typeof(v.operand))) needs a date or timestamp on the left: a " *
                            "DateField or DateTimeField, a shift of one (F(\"date\") + Day(1)), " *
                            "Max/Min of one, or a `__@date` path. The left side here is none of those."))
    end

    # Ordering and arithmetic with an EXPRESSION on the right of a left that is neither a date nor an
    # interval (both were decided above). The right is typed for this one question and rendered
    # exactly once: `_render_operand_typed` is the call `_set_update_query_operand` makes for an
    # expression operand, and a field-path String is the `F(...)` it names, so the text is the same.
    if v.operation in _ORDERING_OPERATIONS || v.operation in _ARITHMETIC_OPERATIONS
      # #907: a function on the right is typed too (`F("points") * Sum("time")`), as it is on the left.
      if v.operand isa Union{FExpression,FObject} || (v.operand isa String && _is_field_path(v.operand, instruc))
        right_side, right_kind = _render_operand_typed(v.operand, v.field_name, v.operation, instruc)
        # #881: an interval on the right (`F("points") * d`, `F("points") > d`).
        _is_interval_kind(right_kind) &&
          return _render_interval_right(v, left_side, left_kind, right_side, right_kind, instruc)
        # #882: a date on the right of `+`/`-` whose left PormG cannot type (a text column, `Sum(...)`,
        # `F("points") * 2`). Every typed left was handled above, so this left is not a count.
        v.operation in ("+", "-") && right_kind isa Union{CDate,CDateTime} &&
          _refuse_untyped_date_operand(v.operation, instruc)
        return "($(left_side) $(v.operation) $(right_side))", nothing
      end
    end

    # #564: the left's kind travels to the binder, so the representation the literal binds and the
    # one the wrapper renders come from the same value rather than from two resolvers that agree.
    right_side = _set_update_query_operand(v.operand, v.field_name, v.operation, instruc; left_kind = left_kind)

    return "($(left_side) $(v.operation) $(right_side))", nothing
  end
end
