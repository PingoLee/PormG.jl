# ==============================================================================
# VALUE REPRESENTATION (#564) — ONE OWNER FOR "THE STORED TEXT OF A TEMPORAL VALUE"
#
# PormG had THREE independent producers of one convention, in three files, with no shared object:
#
#   write / bind   the field's `formatter`   `Models.format_timezone_sql`, `format_date_sql`, …
#   SQL render     whatever the dialect emit `Dialect.SQLITE_CANONICAL_DATETIME_MASK`, `date(...)`
#   read parse     a third thing again       `_parse_sqlite_datetime` in the query builder
#
# On PostgreSQL a mismatch between them fails at execution, because `date`, `timestamp` and `text`
# are real types. On SQLite every temporal column is TEXT with NUMERIC affinity, so comparing two
# differently-formatted values is always well-defined and always silent — the engine converts every
# representation mistake into a WRONG ANSWER rather than an error. That is why the #527 family is
# SQLite-only, why it is silent, and why it survives review: the engine that would catch it is not
# the engine that has the bug.
#
# This file is the owner. Three generics keyed by `(CanonicalType, backend)`:
#
#   value_formatter(kind, backend)            Julia value -> the stored text     (slot 1)
#   sql_canonicalize(kind, backend, e, mods)  a SQL expression -> the stored text (slot 2)
#   value_parser(kind, backend)               the stored text -> a Julia value    (slot 3)
#
# Slots 1 and 3 are inverses and both return a function or `nothing`, so `parser(formatter(x)) == x`
# is a property a test can state (`test/unit/test_read_value_coercion.jl` does) — for the temporal
# kinds.
#
# ── `CDecimal`, THE ONE NON-TEMPORAL KIND (#648) ─────────────────────────────────────────────────
# A `DecimalField` joined the table for its READ half. SQLite's NUMERIC affinity turns the bound text
# into an `Int64` or a `Float64` as it stores it, so its slot 3 inverts the ENGINE's storage, not slot
# 1's text: `parser(formatter(x)) == x` does not hold for it, and the tests do not claim it. What it
# inverts exactly is guaranteed from the other end — `Dialect.field_to_column` refuses a SQLite
# decimal wider than `Dialect.SQLITE_EXACT_DECIMAL_DIGITS`, and the parser declines every wider kind,
# so it never reconstructs a value SQLite could have rounded. It has no slot-2 method: a decimal
# expression needs no canonical text, and the generic arms below return it unchanged.
#
# ── WHY MULTIPLE DISPATCH RATHER THAN A RECORD STRUCT ────────────────────────────────────────────
# The #564 design review asked for the representation to hang OFF `CanonicalType`, not to sit beside
# it as a second noun: "a separate `ValueRepr` noun would be a second thing to keep aligned with the
# first." Dispatch IS the table, so there is no record type to keep aligned, nothing can accidentally
# dispatch on "a representation", and an unhandled pair falls to a fallback arm instead of needing a
# row. `CanonicalType` (`column_ir.jl`) and `PormGBackend` (`Kernel.jl`) are both layer-1 nouns.
#
# ── WHY THIS FILE, AND NOT `column_ir.jl` ────────────────────────────────────────────────────────
# `column_ir.jl` is included FROM `Kernel` (include step 1) and its header states it "needs nothing
# but itself". This table must name `Models.format_timezone_sql` (step `include("Models.jl")`) and
# `Dialect._sqlite_canonical_datetime` (step `include("Dialect.jl")`) at DEFINITION time. Defining it
# there is the #239/#507 failure verbatim — a name that does not exist yet when the file compiles.
#
# ── WHY NOT A SUBMODULE ──────────────────────────────────────────────────────────────────────────
# Three generics do not earn a fourth namespace that `QueryBuilder` and `Migrations` would each have
# to import. This is `Backend.jl`'s precedent, not `column_spec.jl`'s: `column_spec` is a compiler
# living inside the submodule that owns its inputs, but this table's inputs live in THREE different
# submodules, so the only module that can see all of them is `PormG` itself.
# **Kernel holds the nouns; `PormG` keeps the verbs.**
#
# ── INCLUDE-ORDER NOTE FOR A FUTURE PHASE ───────────────────────────────────────────────────────
# `Dialect.jl` is included BEFORE this file. A later change that wants `Dialect` to consult the table
# must call `PormG.sql_canonicalize(...)` QUALIFIED inside a function body (resolved at runtime),
# never `import PormG: sql_canonicalize` at Dialect's include time.
#
# ── PRIOR ART, AND THE ONE APPROACH DELIBERATELY REJECTED ───────────────────────────────────────
# The `(type, backend) -> (write, read)` pair is the shape every mature ORM converged on, so this is
# Django-shaped rather than invented:
#
#   * SQLAlchemy — the SQLite `DATETIME` type carries `storage_format` (bind) and `regexp` (result)
#     as two parameters of ONE object; generally `TypeEngine.bind_processor(dialect)` paired with
#     `result_processor(dialect, coltype)`.
#   * Django — `get_db_converters(expression)` keys the read coercion off
#     `expression.output_field.get_internal_type()`, never off "is this alias a plain column". Django
#     calls the kind an expression evaluates to its **`output_field`**, and every `Expression` carries
#     one; that is the precedent for the `TemporalKind` the temporal renderer now carries.
#   * Ecto's `Ecto.Type` (`dump/1` + `load/1`), jOOQ's `Binding` (`sql`/`set`/`get`) and Diesel's
#     `ToSql`/`FromSql` are the same pairing under other names.
#
# REJECTED — and it is the obvious "why not just do what Django does": Django's SQLite backend does
# not translate date SQL at all. It registers PYTHON functions onto the connection
# (`django_date_trunc`, `django_datetime_cast_date`, …) via `create_function`, so the SQL-side
# transform IS the Python-side transform — one owner by construction, with nothing to reconcile.
# `SQLite.jl` supports `register`, so this was available. It is wrong here for four reasons:
#   1. it kills index usability, in a codebase that has `_render_sargable_date_range` specifically to
#      STRIP functions off date columns;
#   2. registration is per-connection, and PormG hands connections out of an async pool;
#   3. it does nothing for PostgreSQL, so two renderers remain — the seam moves rather than closing;
#   4. it makes `inspect_query` output unrunnable outside PormG.
# Django accepts all four. PormG's #79 canonical-text choice is a deliberate bet against the first.
# ==============================================================================


# ── The adapter: a PormGField's own `.type` tag -> the canonical noun ────────────────────────────
#
# Deliberately NOT `Migrations.parse_canonical_type`, which answers a DIFFERENT question: it maps a
# RENDERED SQL type string per engine (so it collapses SQLite's `TIMESTAMPTZ` and `DATETIME` onto one
# another, an engine fact). This maps PormG's own declared tag and is engine-independent, so
# `CDateTime`'s `with_timezone` flag survives. It also lives at include step `Migrations`, AFTER
# `QueryBuilder` — reusing it from here would be an include-order failure, not merely a wrong fit.
"""
    field_canonical_kind(f::PormGField) -> Union{CanonicalType, Nothing}

The canonical type a field's values are stored as, or `nothing` when the field is not one this
table owns. The temporal kinds, and `CDecimal` carrying the declared width (#648); every other field
falls through.
"""
function field_canonical_kind(f::PormGField)::Union{CanonicalType, Nothing}
  t = f.type
  t == "TIMESTAMPTZ" && return CDateTime(true)
  t == "TIMESTAMP"   && return CDateTime(false)
  t == "DATE"        && return CDate()
  t == "TIME"        && return CTime()
  t == "INTERVAL"    && return CInterval()
  # The width travels on the kind because the SQLite parser needs it: it is exact only up to 15
  # digits, and a value that does not fit `(max_digits, decimal_places)` is not the one written.
  t == "DECIMAL" && hasfield(typeof(f), :max_digits) &&
    return CDecimal(getfield(f, :max_digits), getfield(f, :decimal_places))
  return nothing
end


# ── Slot 1: the Julia value -> the stored text ───────────────────────────────────────────────────
#
# These are not new implementations — they are the field formatters themselves, named once here so a
# renderer can ASK for the right one instead of re-deriving the choice from a `.type` string. The
# chooser this replaces was an `if ftype == "DATE" … elseif ftype == "TIMESTAMP" …` ladder inside
# `_format_date_operand`.
#
# DISPATCH ON `::CDateTime`, NEVER BRANCH ON `.with_timezone`. `CDateTime(true)` and
# `CDateTime(false)` are two distinct keys; a method written for one flavour lets the other fall to
# the generic arm below and silently lose its representation — which on the render side is the #527
# truncation, reachable only through `DateTimeField(type = "TIMESTAMP")`. The "no-tz flavour" testset
# in `test/unit/test_value_repr_property.jl` exists for exactly this failure.
#
# `CTime` rides `format_text_sql`: `TimeField` has no dedicated formatter, and `format_text_sql(::Time)`
# is an exact inverse of `Time(::String)`. Recorded rather than fixed — changing a field's formatter
# is a write-side behavior change this table has no mandate for.
value_formatter(::CDateTime, ::PormGBackend) = Models.format_timezone_sql
value_formatter(::CDate,     ::PormGBackend) = Models.format_date_sql
value_formatter(::CTime,     ::PormGBackend) = Models.format_text_sql
value_formatter(::CInterval, ::PormGBackend) = Models.format_duration_sql
# #648: the field's own formatter, named here for the same reason as the four above. Nothing ASKS for
# it yet — every consumer of slot 1 narrows to a date kind first — but a kind a field declares must
# answer, which is what `test_value_repr_table.jl`'s totality testset holds the table to.
value_formatter(::CDecimal,  ::PormGBackend) = Models.format_number_sql
# Every other canonical type. `nothing` means "this table does not own the representation", which
# is the same answer it gave before this file existed.
value_formatter(::CanonicalType, ::PormGBackend) = nothing


# ── Slot 1 for a LITERAL: a Julia value with no column to take its representation from (#721) ──
#
# A filter value reaches the binder through its column's formatter, so it arrives as the stored text.
# A `Value(x)` literal, a function kwarg, a window default and a raw-SQL parameter have no column —
# and neither does a filter value its formatter passes through untouched (`format_number_sql`
# returns any `Integer` as is). They reach SQLite.jl RAW, and SQLite.jl has `bind!` methods for
# `Int32`, `Int64`, `Bool`, `AbstractFloat`, strings, `Vector{UInt8}`, `missing` and `nothing` only.
# Everything else falls to `bind!(stmt, i, ::Any) = bind!(stmt, i, sqlserialize(val))`, which
# JULIA-SERIALIZES the value into a BLOB and raises nothing: `Value(Date(2020, 1, 1))` compared
# against a serialized Julia object, and `filter("points" => Int16(5))` matched no row, silently.
# Measured with `SELECT typeof(?)`: `Date`, `DateTime`, `Time`, `Int8`, `Int16`, every `UInt`,
# `Int128` and `BigInt` all bind as `blob`.
#
# The kind a literal evaluates to is this table's key, so a date literal gets the SAME formatter its
# column's values get — `"2020-01-01"` for a `Date`, the canonical UTC text for a `DateTime`. There is
# no second date formatter to drift from the first. `literal_canonical_kind` is also what the read
# path records for a projected `Value(x)`, so the text parses back into a typed value — the type that
# went in for a `Date`/`Time`, a UTC `ZonedDateTime` for a `DateTime` (as a SQLite `DateTimeField` reads).
import TimeZones, UUIDs   # the literal types below; `Dates` is imported by `PormG.jl`

"""
    literal_canonical_kind(x) -> Union{CanonicalType, Nothing}

The canonical type a Julia literal is stored as, or `nothing` when this table does not own its
representation. Temporal values only, as [`field_canonical_kind`](@ref).
"""
literal_canonical_kind(::Dates.Date) = CDate()
literal_canonical_kind(::Dates.DateTime) = CDateTime(false)
literal_canonical_kind(::TimeZones.ZonedDateTime) = CDateTime(true)
literal_canonical_kind(::Dates.Time) = CTime()
literal_canonical_kind(::Union{Dates.Period, Dates.CompoundPeriod}) = CInterval()
literal_canonical_kind(_) = nothing

# Dispatch-only engine for the one binder with no connection in hand — the SQLite parameter
# collector, which never held one. `value_formatter` keys on a backend VALUE, and every temporal cell
# is backend-generic today, so a subtype with no fields is enough. `column_spec.jl`'s `_SQLiteEngine`
# is the same shape for the same reason.
struct _SQLiteBindEngine <: PormGSQLite end

"""
    sqlite_bind_value(x, backend = _SQLiteBindEngine()) -> value

`x` as a value SQLite.jl binds as itself, or an `InvalidValueError` when there is none. Never a
serialized BLOB (#721). The native types pass through; a narrower or wider integer becomes `Int64`
(out of range → error); a date, time, datetime or duration becomes its column's stored text; a
`UUID` becomes the text its field formatter binds; anything else is refused. A `Decimal` is an
`AbstractFloat`, which SQLite.jl already binds as REAL, so it is native here.
"""
function sqlite_bind_value end
# The native set. Each arm is its own method so the `Integer` arm below is strictly less specific
# than `Int32`/`Int64`/`Bool` — one `Union` beside it would be an ambiguity, not a table.
sqlite_bind_value(x::Union{Int32, Int64, Bool}, ::PormGSQLite = _SQLiteBindEngine()) = x
sqlite_bind_value(x::AbstractFloat, ::PormGSQLite = _SQLiteBindEngine()) = x
sqlite_bind_value(x::AbstractString, ::PormGSQLite = _SQLiteBindEngine()) = x
sqlite_bind_value(x::Vector{UInt8}, ::PormGSQLite = _SQLiteBindEngine()) = x
sqlite_bind_value(x::Union{Missing, Nothing}, ::PormGSQLite = _SQLiteBindEngine()) = x
# `Vector{UInt8}` is the only byte container SQLite.jl binds as a blob; a view or `codeunits` of one
# would be serialized instead, so it is copied into the concrete type.
sqlite_bind_value(x::AbstractVector{UInt8}, ::PormGSQLite = _SQLiteBindEngine()) = Vector{UInt8}(x)
function sqlite_bind_value(x::Integer, ::PormGSQLite = _SQLiteBindEngine())
  typemin(Int64) <= x <= typemax(Int64) && return Int64(x)
  throw(InvalidValueError("$(repr(x)) (::$(typeof(x))) does not fit a 64-bit integer, the widest " *
                          "integer SQLite stores. Bind it as text instead: string($(repr(x))) (#721)."))
end
function sqlite_bind_value(x::Union{Dates.Date, Dates.DateTime, TimeZones.ZonedDateTime, Dates.Time,
                                    Dates.Period, Dates.CompoundPeriod},
                           backend::PormGSQLite = _SQLiteBindEngine())
  try
    return value_formatter(literal_canonical_kind(x), backend)(x)
  catch e
    # The formatter's own message names `DurationField` for a `Month`/`Year`, a field the caller of
    # `Value(Month(1))` never used. Say which value was being bound, keep the formatter's reason.
    e isa InvalidValueError || rethrow()
    throw(InvalidValueError("$(repr(x)) (::$(typeof(x))) cannot be bound as a SQLite parameter: " *
                            "$(rstrip(e.msg, '.')) (#721)."))
  end
end
sqlite_bind_value(x::UUIDs.UUID, ::PormGSQLite = _SQLiteBindEngine()) = Models.format_uuid_sql(x)
sqlite_bind_value(x, ::PormGSQLite = _SQLiteBindEngine()) = throw(InvalidValueError(
  "$(repr(x)) (::$(typeof(x))) cannot be bound as a SQLite parameter: SQLite.jl would store it as a " *
  "serialized Julia object. Convert it to a string, number, Bool, date or time first (#721)."))


# ── Slot 2: a SQL expression -> the stored text ─────────────────────────────────────────────────
#
# `modifiers` are already-rendered SQLite modifier arguments (`"'+' || ? || ' days'"`); pass none to
# canonicalize the expression on its own.
#
# The asymmetry between the two engines IS the subject of #564, so it is stated in the table rather
# than in an `if` at a call site: on PostgreSQL a temporal column has a real type and its value IS
# its canonical form, so there is nothing to wrap; on SQLite the value is TEXT and the wrapper is the
# only thing making the expression comparable to what the column holds.
"""
    sql_canonicalize(kind, backend, expr, modifiers = String[]) -> String

Render `expr` so its OUTPUT is in the representation `kind`'s values are stored in on `backend`.
"""
sql_canonicalize(::CDateTime, ::PormGSQLite, expr::AbstractString, modifiers::Vector{String} = String[]) =
  Dialect._sqlite_canonical_datetime(expr, modifiers)

# `date(...)`'s output already equals `Models.format_date_sql`'s, which is why #527 left it alone.
# Now that claim is a table cell instead of a comment (`Dialect.jl`'s own note said so in prose).
sql_canonicalize(::CDate, ::PormGSQLite, expr::AbstractString, modifiers::Vector{String} = String[]) =
  isempty(modifiers) ? expr : "date($(expr), $(join(modifiers, ", ")))"

# PostgreSQL composes durations with `make_interval`, never with SQLite-style modifier strings, so a
# non-empty `modifiers` here is a caller bug rather than a rendering choice — fail loudly.
function sql_canonicalize(::CanonicalType, conn::PormGPostgres, expr::AbstractString,
                          modifiers::Vector{String} = String[])
  isempty(modifiers) ||
    throw(QueryBuildError("PostgreSQL does not take SQLite-style datetime modifiers; " *
                          "compose the duration with make_interval instead"))
  return expr
end

# A kind/backend pair with no canonical form of its own: the expression is already what it is.
#
# NON-EMPTY MODIFIERS ARE REFUSED HERE, not merely ignored, and that is the point. The caller has
# already bound one parameter per modifier by the time it reaches this arm (`_render_temporal_shift`),
# so silently returning `expr` would emit a query whose text has fewer placeholders than its bound
# vector — a `StatementError` on SQLite, an unused `$N` on PostgreSQL. Only the CALL-SITE narrowings
# keep a `CTime`/`CInterval` from arriving here today, and a guard at the call site protecting a table
# cell that quietly does the wrong thing is exactly the arrangement #564 exists to remove. The cell
# states its own contract instead.
function sql_canonicalize(::CanonicalType, ::PormGBackend, expr::AbstractString,
                          modifiers::Vector{String} = String[])
  isempty(modifiers) ||
    throw(QueryBuildError("this column kind has no canonical form to render date modifiers into; " *
                          "a duration only applies to a DATE or TIMESTAMP column"))
  return expr
end


# ── Slot 3: the stored text -> the Julia value ──────────────────────────────────────────────────
#
# The inverse of slot 1, and the half PormG never had: three write formatters (`format_date_sql`,
# `format_text_sql`, `format_duration_sql`) shipped with ZERO read parsers, so on SQLite a
# `DateField`, a `TimeField` and a `DurationField` all read back as `String` while PostgreSQL
# delivered `Date`, `Time` and a `Period`. The bodies live in `Dialect` beside the masks they invert.
#
# PostgreSQL needs none: LibPQ delivers typed values, which is what the `p3 = (:sqlite,)` marks in
# `test/unit/helper_value_repr_cases.jl` measure.
"""
    value_parser(kind, backend) -> Union{Function, Nothing}

The function that turns `backend`'s stored text for `kind` back into a Julia value, or `nothing`
when the backend already delivers a typed value (or the kind is not one this table owns).

Every parser is **fail-open**: handed a value it does not recognise it returns it unchanged, never a
lossy approximation. So a wrong `kind` degrades to the raw value — exactly what SQLite returned
before this table existed — and can never produce a wrong typed value.
"""
value_parser(::CanonicalType, ::PormGPostgres) = nothing
value_parser(::CDateTime, ::PormGSQLite) = Dialect._parse_sqlite_timestamp
value_parser(::CDate,     ::PormGSQLite) = Dialect._parse_sqlite_date
value_parser(::CTime,     ::PormGSQLite) = Dialect._parse_sqlite_time
value_parser(::CInterval, ::PormGSQLite) = Dialect._parse_sqlite_interval
# #648: exact only for a column narrow enough that SQLite stored every accepted value exactly — the
# width `Dialect.field_to_column` refuses to exceed. A wider or width-less kind (a column created
# outside PormG, or before that refusal) gets NO parser, so its cells arrive raw, as they always have:
# declining is the fail-open answer, where parsing would dress a rounded double up as an exact value.
function value_parser(k::CDecimal, ::PormGSQLite)
  (k.precision === nothing || k.scale === nothing) && return nothing
  k.precision > Dialect.SQLITE_EXACT_DECIMAL_DIGITS && return nothing
  p, s = k.precision, k.scale
  return v -> Dialect._parse_sqlite_decimal(v, p, s)
end
value_parser(::CanonicalType, ::PormGBackend) = nothing
