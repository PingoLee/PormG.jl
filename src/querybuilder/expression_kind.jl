# #1034 — ONE WALK for "what type does this expression have?", asked under one of two policies.
#
# The question used to be answered by a function per consumer, each walking the tree its own way and
# each forgetting a shape the others typed: read kinds alone took six fixes, one per shape (#564,
# #800, #824, #888, #965, #979). The walk below is written once — paths and transforms, joined and CTE
# handles, a `Subquery`, literals, and each function through the rule it states beside its
# constructor (`_result_rule`, `functions.jl`) — and the two policies differ only where one of them
# declines to answer ON PURPOSE:
#
# - `_ReadKinds` — the #564 READ kind: the representation the read path must undo. It is what
#   `_operand_kind` and `_function_projection_kind` answer, exactly as before this file existed (the
#   expression-kind matrix pins every cell). A column has a kind only when the representation table
#   owns one (`field_canonical_kind`: temporal, decimal, array — no integer, float, text or boolean,
#   because the table also feeds the comparison binder, #882); a literal only a temporal one
#   (`literal_canonical_kind`, #721); a computed number none (`Sum`/`Avg` went through a double,
#   #648); and a boolean is the one the build's formatter already names (`_is_boolean_valued`, #965).
# - `_AllKinds` — `_expression_kind`: every type PormG can name, on this engine. No reader consumes it
#   yet: the expression-kind matrix records it beside the others (its `kind` channel), and #1034's
#   phase 3 moves the readers onto it one at a time, each move a reviewed diff of that fixture.
#
# Both are asked AFTER the render, as every reader here is: resolving a joined path is what fills the
# field memo `_alias_column_field` reads, and a `Subquery` files its kind when it renders.
#
# Neither types `F` arithmetic: the render does (`_render_expr_typed`, which holds an interval as
# milliseconds on SQLite while it computes), and whether the walk should take that kind from the render
# — stored with the memo entry, or the #979 reuse path loses it — is a phase-3 decision. Until then an
# arithmetic node answers `nothing` here, as `_operand_kind` always has; a comparison is a boolean.
struct _ReadKinds end
struct _AllKinds end
const _KindPolicy = Union{_ReadKinds,_AllKinds}

"""
    _expression_kind(x, instruc) -> Union{CanonicalType, Nothing}

Every type PormG can name for the expression `x`, on `instruc`'s engine, or `nothing` when it names
none. Read after `x` renders. See the policies above.
"""
_expression_kind(x, instruc::SQLInstruction)::Union{CanonicalType,Nothing} = _infer_kind(x, instruc, _AllKinds())

# ── The walk ─────────────────────────────────────────────────────────────────────────────────────────
function _infer_kind(p::String, instruc::SQLInstruction, policy::_KindPolicy)
  # A transformed path (`"ts__@date"`) names the transform's result, not the column — through the one
  # transform ladder (#562), the call `_get_filter_query(::String)` renders with.
  occursin("__@", p) && return _infer_function_kind(_check_function(p), instruc, policy)
  column_field = _alias_column_field(p, instruc)
  return column_field === nothing ? nothing : _column_kind(column_field, policy)
end
_infer_kind(p::FExpression, instruc::SQLInstruction, policy::_KindPolicy) =
  p.operation === nothing ? _infer_kind(p.field_name, instruc, policy) : _operation_kind(p, policy)
_infer_kind(p::SQLField, instruc::SQLInstruction, policy::_KindPolicy) = _infer_kind(p.field, instruc, policy)
_infer_kind(p::SQLText, ::SQLInstruction, policy::_KindPolicy) =
  _is_null_literal(p.field) ? nothing : _literal_kind(p.field, policy)
_infer_kind(p::Union{FObject,WindowFunction}, instruc::SQLInstruction, policy::_KindPolicy) =
  _infer_function_kind(p, instruc, policy)
# #824: a `Joined(...)` handle is the joined column, exactly as `Max(Joined(…))` reads it.
function _infer_kind(p::JoinedReference, instruc::SQLInstruction, policy::_KindPolicy)
  column_field = _alias_column_field(p, instruc)
  return column_field === nothing ? nothing : _column_kind(column_field, policy)
end
_infer_kind(p::CTEReference, instruc::SQLInstruction, policy::_KindPolicy) = _cte_column_kind(p, instruc, policy)
# #888: a `Subquery(...)` is its one projected column, as its own build typed it (`_subquery_kind`).
# That record is a READ kind under either policy until phase 3 records the inner build's full kind.
_infer_kind(p::SubqueryObject, instruc::SQLInstruction, ::_KindPolicy) = _subquery_kind(p, instruc)
# A predicate is a boolean. The read kind leaves it to the formatter bridge (#965), as before.
_infer_kind(::Union{ExistsObject,SQLTypeQ,SQLTypeQor}, ::SQLInstruction, ::_AllKinds) = CBool()
_infer_kind(::Any, ::SQLInstruction, ::_KindPolicy) = nothing

_operation_kind(::FExpression, ::_ReadKinds) = nothing
_operation_kind(p::FExpression, ::_AllKinds) = p.operation in _COMPARISON_OPERATIONS ? CBool() : nothing

# ── Leaves: a column's field and a literal ───────────────────────────────────────────────────────────
_column_kind(f, ::_ReadKinds) = field_canonical_kind(f)
_column_kind(f, ::_AllKinds) = _field_kind(f)

# Every type a field declares, by its `.type` — the string `Dialect` renders the column from, which is
# also what `field_canonical_kind` reads, so the two cannot disagree on the kinds that table owns.
function _field_kind(f::PormGField)::Union{CanonicalType,Nothing}
  owned = field_canonical_kind(f)
  owned === nothing || return owned
  t = f.type
  t == "BOOLEAN"  && return CBool()
  t == "SMALLINT" && return CInt16()
  t == "INTEGER"  && return CInt32()
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

_literal_kind(x, ::_ReadKinds) = literal_canonical_kind(x)
_literal_kind(::Bool, ::_AllKinds) = CBool()
_literal_kind(::Integer, ::_AllKinds) = CInt64()
_literal_kind(::AbstractFloat, ::_AllKinds) = CFloat64()
_literal_kind(::Decimals.Decimal, ::_AllKinds) = CDecimal(nothing, nothing)   # a bound value has no declared width
_literal_kind(::AbstractString, ::_AllKinds) = CText()
_literal_kind(x, ::_AllKinds) = literal_canonical_kind(x)

# ── Functions, by their `_result_rule` ───────────────────────────────────────────────────────────────
# The read kind (#800, #822, #824, #852, #953, #965): a declared date, `DATE`, a boolean the formatter
# names, and a value that is one of its operands' own values. Every other function answers `nothing`
# and its value stays as the driver delivered it — the fail-open default.
function _infer_function_kind(p::Union{FObject,WindowFunction}, instruc::SQLInstruction, policy::_ReadKinds)
  rule = _result_rule(p)
  if p isa FObject && rule in (:declared, :one_of)
    declared = _declared_cast(p)
    declared isa AbstractString && _sql_type_field(declared) isa Models.sDateField && return CDate()
  end
  rule isa CDate && return CDate()
  # #953, #965: a boolean value is typed a boolean, whichever function produced it. PostgreSQL's
  # driver types it already; SQLite delivers the 0/1 it stores, which `value_parser(::CBool, …)` turns
  # back into a `Bool`. `field_canonical_kind` names no boolean kind (#882), so the formatter the build
  # already gives the value decides: an extremum over a boolean, a `Cast`/`output_field` naming one,
  # `Coalesce` or `Case` over booleans. A window value function returns its operand's own value, so
  # its operand decides.
  _is_boolean_valued(p, instruc) && return CBool()
  p isa FObject && rule === :one_of && return _agreeing_kind(p, instruc, policy)
  p isa FObject && rule === :first_operand && return _infer_kind(first(p.column), instruc, policy)
  rule === :operand || return nothing
  return _infer_kind(p.column, instruc, policy)
end
# Every kind: a declared cast is the type (#852, and `Case`'s `output_field`), then the rule.
function _infer_function_kind(p::Union{FObject,WindowFunction}, instruc::SQLInstruction, policy::_AllKinds)
  rule = _result_rule(p)
  if p isa FObject && rule in (:declared, :one_of)
    declared = _declared_cast(p)
    declared isa AbstractString && !isempty(declared) && return _declared_kind(declared)
  end
  rule isa CanonicalType && return rule
  rule === :operand && return _infer_kind(p.column, instruc, policy)
  rule === :first_operand && return _infer_kind(first(p.column), instruc, policy)
  rule === :one_of && return _agreeing_kind(p, instruc, policy)
  rule === :promoting && return _promoted_kind(_infer_kind(_first_operand(p), instruc, policy))
  rule === :numeric && return _numeric_kind(p, instruc, policy)
  rule === :declared && p isa FObject && p.function_name == "CASE" && return _case_kind(p, instruc, policy)
  return nothing
end
_infer_function_kind(::Any, ::SQLInstruction, ::_KindPolicy) = nothing

_declared_cast(p::FObject) = get(p.kwargs, p.function_name == "CAST" ? "type" : "output_field", nothing)
_first_operand(p::SQLTypeFunction) = p.column isa AbstractVector ? first(p.column) : p.column

# The kind a declared type names. `_sql_type_field` maps a type NAME to a field and drops its size, so
# the size is read here: `numeric(10,2)` is `CDecimal(10, 2)` and a bare `numeric` has no width.
function _declared_kind(type_name::AbstractString)::Union{CanonicalType,Nothing}
  size = _numeric_cast_size(type_name)
  size === nothing || return CDecimal(size...)
  field = _sql_type_field(type_name)
  field isa Models.sDecimalField && return CDecimal(nothing, nothing)
  if field isa Models.sCharField
    m = match(r"\((\d+)\)$", type_name)
    return CVarChar(m === nothing ? nothing : parse(Int, m.captures[1]))
  end
  return _field_kind(field)
end

# #824 — the kind of a function whose value is one of several operands' own values. Typed only on
# agreement: every operand names the SAME kind (a `CDecimal` of the same width, a `CDateTime` of the
# same flavour). An operand with no kind — a text or number column, a number, arithmetic, a function
# PormG does not type — disqualifies the whole projection: the value may be that operand's, and a
# kind taken from the others would run text through a date parser (`Coalesce("note", Date(…))`). A
# NULL literal is skipped: it is never the value. A declared `output_field` other than `date` (which
# `_infer_function_kind` answers first) is kept only when it names the kind the operands agree on:
# the cast it renders (#852) is not a read kind of its own — `Cast(x, "numeric(10,2)")` records none
# either — so a declaration that disagrees with the operands records nothing. (Under `_AllKinds` a
# declaration has already answered, and the operands agree under PostgreSQL's numeric promotion.)
function _agreeing_kind(p::FObject, instruc::SQLInstruction, policy::_KindPolicy)::Union{CanonicalType,Nothing}
  kind = nothing
  for operand in (p.column isa AbstractVector ? p.column : (p.column,))
    _is_null_literal(operand isa SQLText ? operand.field : operand) && continue   # the #812 `Case` rule
    k = _infer_kind(operand, instruc, policy)
    k === nothing && return nothing
    kind = kind === nothing ? k : _unify_kinds(kind, k, policy)
    kind === nothing && return nothing
  end
  declared = get(p.kwargs, "output_field", nothing)
  if kind !== nothing && declared isa AbstractString
    declared_field = _sql_type_field(declared)
    (declared_field === nothing || _column_kind(declared_field, policy) != kind) && return nothing
  end
  return kind
end

# Two operands' kinds as one value's. The read kind demands the same kind: a parser runs per column,
# not per row. Every kind follows PostgreSQL's resolution of a `COALESCE`/`CASE`: integers widen,
# `integer` < `numeric` < `double precision`, and text is text whatever its length.
_unify_kinds(a::CanonicalType, b::CanonicalType, ::_ReadKinds) = a == b ? a : nothing
function _unify_kinds(a::CanonicalType, b::CanonicalType, ::_AllKinds)
  a == b && return a
  ra, rb = _numeric_rank(a), _numeric_rank(b)
  if ra !== nothing && rb !== nothing
    r = max(ra, rb)
    return r == 4 ? CFloat64() : r == 3 ? CDecimal(nothing, nothing) : r == 2 ? CInt64() : r == 1 ? CInt32() : CInt16()
  end
  a isa Union{CText,CVarChar} && b isa Union{CText,CVarChar} && return CText()
  return nothing
end
_numeric_rank(::CInt16) = 0
_numeric_rank(::CInt32) = 1
_numeric_rank(::CInt64) = 2
_numeric_rank(::CDecimal) = 3
_numeric_rank(::CFloat64) = 4
_numeric_rank(::CanonicalType) = nothing

# `:promoting` — a number of its operand's type. The width an operation may change is dropped: a sum
# of `numeric(10,2)` values is not a `numeric(10,2)`. An interval sums to an interval. An integer keeps
# its own integer kind, although PostgreSQL widens `sum(integer)` to `bigint`: no reader undoes an
# integer, so the width has nothing to drive yet.
_promoted_kind(k::Union{CInt16,CInt32,CInt64,CFloat64,CInterval}) = k
_promoted_kind(::CDecimal) = CDecimal(nothing, nothing)
_promoted_kind(::Any) = nothing

# `:numeric` — PostgreSQL computes these as `numeric` whatever the operand (`Dialect` casts each operand
# `::numeric`) and SQLite answers a REAL (#1027). The engine-dependent result is stated here, once. An
# average of intervals is an interval on PostgreSQL.
function _numeric_kind(p::SQLTypeFunction, instruc::SQLInstruction, policy::_AllKinds)
  p.function_name == "AVG" && _infer_kind(_first_operand(p), instruc, policy) isa CInterval && return CInterval()
  return _numeric_result_kind(instruc.connection)
end
_numeric_result_kind(::PormGPostgres) = CDecimal(nothing, nothing)
_numeric_result_kind(::PormGSQLite) = CFloat64()
_numeric_result_kind(::Any) = nothing

# A `Case` with no `output_field`: its value is a branch's, so it has the kind its `then` values and
# its default agree on. A branch value that is a string is a literal, not a path (`_boolean_case`).
function _case_kind(p::FObject, instruc::SQLInstruction, policy::_AllKinds)
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
# parser (#648). The body's record is a READ kind under either policy until phase 3 records more.
function _cte_column_kind(ref::CTEReference, instruc::SQLInstruction, policy::_KindPolicy = _ReadKinds())::Union{CanonicalType,Nothing}
  if occursin("__", ref.path)
    column_field = _alias_column_field(ref, instruc)
    return column_field === nothing ? nothing : _column_kind(column_field, policy)
  end
  cte = get(instruc.object.ctes, ref.name, nothing)
  cte === nothing && return nothing
  body = get(cte, "query", nothing)
  body isa SQLObjectHandler || return nothing
  return get(body.object.projection_kinds, Symbol(ref.path), nothing)
end
