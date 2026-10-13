# #1034 — ONE WALK for "what type does this expression have?", asked under one of three policies.
#
# The question used to be answered by a function per consumer, each walking the tree its own way and
# each forgetting a shape the others typed: read kinds alone took six fixes, one per shape (#564,
# #800, #824, #888, #965, #979). The walk below is written once — paths and transforms, joined and CTE
# handles, a `Subquery`, literals, and each function through the rule it states beside its
# constructor (`_result_rule`, `functions.jl`) — and the policies differ only where one of them
# declines to answer ON PURPOSE, or (`_MeaningKinds`) answers what a computed number means:
#
# - `_ReadKinds` — the #564 READ kind: the representation the read path must undo. It is what
#   `_operand_kind` and `_function_projection_kind` answer, exactly as before this file existed (the
#   expression-kind matrix pins every cell). A column has a kind only when the representation table
#   owns one (`field_canonical_kind`: temporal, decimal, array — no integer, float, text or boolean,
#   because the table also feeds the comparison binder, #882); a literal only a temporal one
#   (`literal_canonical_kind`, #721); a computed number none (`Sum`/`Avg` went through a double,
#   #648); and a boolean is the one the build's formatter already names (`_is_boolean_valued`, #965).
# - `_AllKinds` — `_expression_kind`: every type PormG can name, on this engine. The expression-kind
#   matrix records it beside the others (its `kind` channel), and #1034's phase 3 moves the readers
#   onto it one at a time, each move a reviewed diff of that fixture. Its first reader is
#   `_integer_operand_kind` (#1147): the `Abs`/`Floor`/`Ceil`/`Round` render and the #1111 division check.
# - `_MeaningKinds` — what a value MEANS, on every engine (#1121): `_AllKinds` in every arm but a
#   computed number, which is its function's `_output_kind` (Django's `output_field`) rather than the
#   type one engine happens to compute it as (`_computed_kind`). `Avg("grid")` is a `numeric` on
#   PostgreSQL and a REAL on SQLite, and it means a float on both. Its reader is the numeric read view
#   (`_numeric_read_kind`), which turns either engine's answer into that type.
#
# All three are asked AFTER the render, as every reader here is: resolving a joined path is what fills the
# field memo `_alias_column_field` reads, and a `Subquery` files its kind when it renders.
#
# The read kind types no `F` arithmetic, as `_operand_kind` never has; a comparison is a boolean.
# Every kind types the numeric operators (`_operation_kind`). TEMPORAL arithmetic is still typed by the
# render (`_render_expr_typed`, which holds an interval as milliseconds on SQLite while it computes),
# and whether the walk should take that kind from the render — stored with the memo entry, or the
# #979 reuse path loses it — is a phase-3 decision.
struct _ReadKinds end
# The two policies that name every type: they differ only on a computed number.
abstract type _EveryKind end
struct _AllKinds <: _EveryKind end
struct _MeaningKinds <: _EveryKind end
const _KindPolicy = Union{_ReadKinds,_EveryKind}

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
  p.operation === nothing ? _infer_kind(p.field_name, instruc, policy) : _operation_kind(p, instruc, policy)
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
# #1153: every kind reads the record of the inner expression's own kind, and falls back to the read
# kind where there is none (a wildcard projection).
_infer_kind(p::SubqueryObject, instruc::SQLInstruction, ::_ReadKinds) = _subquery_kind(p, instruc)
function _infer_kind(p::SubqueryObject, instruc::SQLInstruction, policy::_EveryKind)
  # #1121: a computed number's meaning, which the inner build recorded as its read kind.
  meant = _numeric_meaning_record(p, instruc, policy)
  meant === nothing || return meant
  recorded = instruc.subquery_all_kinds === nothing ? nothing : get(instruc.subquery_all_kinds, p, nothing)
  return recorded === nothing ? _subquery_kind(p, instruc) : recorded
end
# A predicate is a boolean. The read kind leaves it to the formatter bridge (#965), as before.
_infer_kind(::Union{ExistsObject,SQLTypeQ,SQLTypeQor}, ::SQLInstruction, ::_EveryKind) = CBool()
_infer_kind(::Any, ::SQLInstruction, ::_KindPolicy) = nothing

_operation_kind(::FExpression, ::SQLInstruction, ::_ReadKinds) = nothing
# #1147: `+`, `-`, `*` and `/` over two integers is an integer on both engines — PostgreSQL resolves
# `int4 + int8` to `int8` and divides two integers as integers, as SQLite does — so the widest of the
# two is the kind (`_unify_kinds`). An integer literal is a `bigint` there (`$n::bigint`).
#
# #1150: arithmetic over a float or a decimal side is the wider of the two, as PostgreSQL resolves it
# (`integer < numeric < double precision`), and that is what the expression MEANS: `F("price") / 2`
# is a decimal quotient. SQLite can compute it otherwise — it stores a whole decimal as INTEGER and
# divides it as one — so its render casts the dividend (`_division_sql`); the kind is the meaning. A
# decimal's width is dropped: the operation may change it. A date or an interval stays untyped here.
#
# #1153: the bitwise operators resolve their type as arithmetic does (`int4 & int8` is `int8`), and
# `~` has its operand's. A shift has its LEFT operand's type, whatever it shifts by, and binds an
# integer literal on either side as `::integer` (`_set_update_query_left`), so `1 << F("n")` is an
# `integer`. SQLite computes every one of them as a 64-bit integer; the walk keeps PostgreSQL's
# shape on both engines, as it does for `+`, `-`, `*` and `/`.
function _operation_kind(p::FExpression, instruc::SQLInstruction, policy::_EveryKind)
  p.operation in _COMPARISON_OPERATIONS && return CBool()
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
  return kind isa CDecimal ? CDecimal(nothing, nothing) : kind
end
_arithmetic_side_kind(x::Integer, ::SQLInstruction, policy::_EveryKind) = x isa Bool ? nothing : _literal_kind(x, policy)
_arithmetic_side_kind(x::Union{AbstractFloat,Decimals.Decimal}, ::SQLInstruction, policy::_EveryKind) = _literal_kind(x, policy)
_arithmetic_side_kind(x, instruc::SQLInstruction, policy::_EveryKind) = _infer_kind(x, instruc, policy)
_integer_side_kind(x, instruc::SQLInstruction, policy::_EveryKind) =
  (k = _arithmetic_side_kind(x, instruc, policy); k isa Union{CInt16,CInt32,CInt64} ? k : nothing)

# ── Leaves: a column's field and a literal ───────────────────────────────────────────────────────────
_column_kind(f, ::_ReadKinds) = field_canonical_kind(f)
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

_literal_kind(x, ::_ReadKinds) = literal_canonical_kind(x)
_literal_kind(::Bool, ::_EveryKind) = CBool()
_literal_kind(::Integer, ::_EveryKind) = CInt64()
_literal_kind(::AbstractFloat, ::_EveryKind) = CFloat64()
_literal_kind(::Decimals.Decimal, ::_EveryKind) = CDecimal(nothing, nothing)   # a bound value has no declared width
_literal_kind(::AbstractString, ::_EveryKind) = CText()
_literal_kind(x, ::_EveryKind) = literal_canonical_kind(x)

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
  rule === :operand && return _with_window_default(p, _infer_kind(p.column, instruc, policy), instruc, policy)
  rule === :first_operand && return _infer_kind(first(p.column), instruc, policy)
  rule === :one_of && return _agreeing_kind(p, instruc, policy)
  rule in (:promoting, :numeric) && return _number_kind(p, rule, instruc, policy)
  rule === :declared && p isa FObject && p.function_name == "CASE" && return _case_kind(p, instruc, policy)
  return nothing
end
_infer_function_kind(::Any, ::SQLInstruction, ::_KindPolicy) = nothing

# A `Lag`/`Lead` `default` is one of the window's values too: PostgreSQL resolves `lag(int4, int,
# float8)` to a `float8` and `lag(int4, int, int8)` to an `int8` (review of #1147), so the operand's
# kind and the default's are unified as a `COALESCE`'s are. A string is a bound text literal there,
# not a path (`_bigint_operand_function`); any other default PormG cannot type leaves the value untyped.
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
# On SQLite a uuid or network cast renders `CAST(x AS TEXT)` (`_declared_type_formatter`), so it is text.
function _declared_kind(type_name::AbstractString, conn)::Union{CanonicalType,Nothing}
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
# agreement: every operand names the SAME kind (a `CDecimal` of the same width, a `CDateTime` of the
# same flavour). An operand with no kind — a text or number column, a number, arithmetic, a function
# PormG does not type — disqualifies the whole projection: the value may be that operand's, and a
# kind taken from the others would run text through a date parser (`Coalesce("note", Date(…))`). A
# NULL literal is skipped: it is never the value. A declared `output_field` other than `date` (which
# `_infer_function_kind` answers first) is kept only when it names the kind the operands agree on:
# the cast it renders (#852) is not a read kind of its own here — `Cast(x, "numeric(10,2)")` records
# none in this walk either; a declared decimal reads through the numeric read view instead (#1212) —
# so a declaration that disagrees with the operands records nothing here. (Under `_AllKinds` a
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
function _unify_kinds(a::CanonicalType, b::CanonicalType, ::_EveryKind)
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
_computed_kind(::Val, ::Symbol, k, ::Any) = nothing
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

# A `:promoting`/`:numeric` function's kind: what this engine computes (`_computed_kind`, from the
# first operand), or what the call means (`_output_kind`, from every operand).
_number_kind(p::SQLTypeFunction, rule::Symbol, instruc::SQLInstruction, policy::_AllKinds) =
  _computed_kind(Val(Symbol(p.function_name)), rule, _infer_kind(_first_operand(p), instruc, policy), instruc.connection)
function _number_kind(p::SQLTypeFunction, rule::Symbol, instruc::SQLInstruction, policy::_MeaningKinds)
  operands = p.column isa AbstractVector ? p.column : (p.column,)
  return _output_kind(Val(Symbol(p.function_name)), rule, [_arithmetic_side_kind(o, instruc, policy) for o in operands])
end

# #1121 — what a computed number MEANS, from its operands' kinds `ks`: Django's `output_field`, the
# same on every engine. PostgreSQL's `numeric` and SQLite's REAL are two engines computing it; the
# read path turns either into this (`_numeric_read_kind`).
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

# ── #1121: the numeric read view ─────────────────────────────────────────────────────────────────────
# The kinds the read path records for a computed number and no other projection: a float, and a
# decimal with no width. A column's decimal keeps its width (#648's parser), and an integer or a date
# is the read kind's own business.
_numeric_view(k::CFloat64) = k
_numeric_view(k::CDecimal) = k.precision === nothing && k.scale === nothing ? k : nothing
_numeric_view(::Any) = nothing

"""
    _numeric_read_kind(x, instruc) -> Union{CFloat64, CDecimal, Nothing}

The read kind of a projected COMPUTED number (#1121): what it means (`_MeaningKinds`), when that is a
float or a decimal, or `nothing`. Recorded where the read kind is `nothing` (`get_select_query`), so
the read path turns PostgreSQL's `numeric` and SQLite's REAL into the one Julia type the call means,
as Django's `convert_value` turns them by `output_field`. A computed number is arithmetic, a
`:promoting`/`:numeric` function, a function whose value is one of those (`Max(F("points") * 2)`,
`Coalesce(Avg("grid"), 0)`, `NullIf`, a `Case` with no `output_field`), a declared decimal
(`Cast(x, "numeric(10,2)")`, an `output_field` naming one, #1212), or a CTE column or `Subquery` whose
own build recorded one. A column, a literal, or a `Coalesce`/`Case` over columns is not: each row is a
value an operand already has, as the driver delivers it. A decimal records no width (`_computed_meaning`).
Read after `x` renders.
"""
_numeric_read_kind(p::FExpression, instruc::SQLInstruction) =
  p.operation === nothing ? nothing : _numeric_view(_infer_kind(p, instruc, _MeaningKinds()))
_numeric_read_kind(p::Union{FObject,WindowFunction}, instruc::SQLInstruction) =
  _computes_number(p, instruc) ? _numeric_view(_computed_meaning(_infer_kind(p, instruc, _MeaningKinds()))) : nothing

# #1212: a computed number's decimal meaning claims no width. Only a declaration names one
# (`Cast(x, "numeric(10,2)")`, or a value over one, `Max(Cast(…))`), and the read path must not take it
# to a column's: #648's exact parser is for a value SQLite stored, not a double it computed.
_computed_meaning(k::CDecimal) = CDecimal(nothing, nothing)
_computed_meaning(k) = k
_numeric_read_kind(p::Union{CTEReference,SubqueryObject}, instruc::SQLInstruction) = _numeric_read_record(p, instruc)
_numeric_read_kind(::Any, ::SQLInstruction) = nothing

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
function _numeric_read_record(ref::CTEReference, instruc::SQLInstruction)
  occursin("__", ref.path) && return nothing
  cte = get(instruc.object.ctes, ref.name, nothing)
  body = cte === nothing ? nothing : get(cte, "query", nothing)
  body isa SQLObjectHandler || return nothing
  return _numeric_view(get(body.object.projection_kinds, Symbol(ref.path), nothing))
end
_numeric_read_record(p::SubqueryObject, instruc::SQLInstruction) =
  _numeric_view(instruc.subquery_kinds === nothing ? nothing : get(instruc.subquery_kinds, p, nothing))
_numeric_meaning_record(x, instruc::SQLInstruction, ::_MeaningKinds) = _numeric_read_record(x, instruc)
_numeric_meaning_record(x, ::SQLInstruction, ::Union{_ReadKinds,_AllKinds}) = nothing

# #882: the comparison binder and `_is_number_side` read a CTE column's or a `Subquery`'s recorded
# kind through `_operand_kind`, and name no float there (a float side is not a number side to them).
# A numeric read kind is the READ path's, so that view does not see it.
_without_numeric_read(k) = _numeric_view(k) === nothing ? k : nothing

# A `Case` with no `output_field`: its value is a branch's, so it has the kind its `then` values and
# its default agree on. A branch value that is a string is a literal, not a path (`_boolean_case`).
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
# parser (#648). Under `_AllKinds` the column is its expression's own type, which the body recorded
# while it could still resolve its paths (`cte["kinds"]`, #1147): a `Rank` is an integer there though
# it reads back with no kind to undo. The read kind stays the body's read record.
function _cte_column_kind(ref::CTEReference, instruc::SQLInstruction, policy::_KindPolicy = _ReadKinds())::Union{CanonicalType,Nothing}
  if occursin("__", ref.path)
    column_field = _alias_column_field(ref, instruc)
    return column_field === nothing ? nothing : _column_kind(column_field, policy)
  end
  meant = _numeric_meaning_record(ref, instruc, policy)
  meant === nothing || return meant
  cte = get(instruc.object.ctes, ref.name, nothing)
  cte === nothing && return nothing
  kind = _cte_expression_kind(cte, ref.path, policy)
  kind === nothing || return kind
  body = get(cte, "query", nothing)
  body isa SQLObjectHandler || return nothing
  return _without_numeric_read(get(body.object.projection_kinds, Symbol(ref.path), nothing))
end
_cte_expression_kind(::AbstractDict, ::String, ::_ReadKinds) = nothing
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
function _record_subquery_all_kind!(instruc::SQLInstruction, p::SubqueryObject, kind)
  kind isa CanonicalType || return nothing
  instruc.subquery_all_kinds === nothing && (instruc.subquery_all_kinds = IdDict{SubqueryObject,CanonicalType}())
  instruc.subquery_all_kinds[p] = kind
  return nothing
end
