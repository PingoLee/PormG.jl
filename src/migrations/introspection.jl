# ==============================================================================
# INTROSPECTION LOGIC
# Functions for reading database schemas and converting them to PormG models.
# Handles both SQLite and PostgreSQL.
# ==============================================================================

# ---
# Shared identifier helpers
# ---

# #455 retired this section's two functions, `_unquote_ident` and `_split_leading_quoted_ident`.
# Both existed to undo `quote_ident` in the PostgreSQL schema query's string aggregates — one for
# the quoting itself (#389), one for a name containing a SPACE that the field separator tore in
# half (#414). That query now transports every identifier as a JSON string, which is not a SQL
# identifier and needs no quoting, so there is nothing left to undo.

# ---

# ---
# Shared FK helpers (both backends)
# ---

# A foreign key's column default, coerced to what `ForeignKey`/`OneToOneField` accept, or `nothing`.
#
# FAILURE POLICY (#292): introspection NEVER throws over a default it cannot represent. The field
# constructors run `validate_default(default, Union{Int64, Nothing}, …, format2int64)`, which raises
# `FieldValidationError` on anything non-numeric — a text default on a text FK column, a PostgreSQL
# expression default like `nextval(...)`. Letting that escape would abort an entire
# `convert_schema_to_models` run over one odd column, with no way to skip past it. So: warn, naming
# the table, column and raw value, and emit the FK without a `default=`.
#
# THE RESIDUAL, stated rather than hidden. This policy covers the *default*, not a self-contradictory
# *action*, so `set_models` still rejects two shapes — deliberately, because the database really is
# in a state PormG cannot express and silently dropping the action would hide it:
#
#   1. `SET_DEFAULT` on a column with no default (or an unrepresentable one) — #287's guard.
#   2. `SET_NULL` on a NOT NULL column — #287's other guard.
#
# Both are legal DDL on both backends (the action is only enforced at delete time), and PostgreSQL
# reaches them for the first time as of #292, because before it the PostgreSQL path never emitted
# `on_delete` at all and so could not contradict anything. The `@warn` above is what names the
# column for case 1; case 2 surfaces at registration with the model and field named. See the
# uncut entry under `upgrading/`.
#
# Shared by all three FK branches — the two SQLite ones and the PostgreSQL one. Before #292 the
# SQLite branches dropped the default silently and PostgreSQL passed it through unguarded, so this
# closes an existing PostgreSQL exposure as well as the SQLite gap it was written for.
function _fk_default_or_warn(default_val, table_name, column_name)
  default_val === nothing && return nothing
  ismissing(default_val) && return nothing

  # The `_ExpressionDefault` arm that stood here was REMOVED in #496, not relocated by accident: the
  # sole caller (`_default_or_drop`) now claims an expression default before it reaches the
  # `:reference` branch, and carries it as a `db_default` instead of dropping it. A relation's
  # expression default is no longer a foreign-key problem — `sForeignKey` and `sOneToOneField` have
  # the slot like every other struct — so nothing can arrive here as a tag any more. Left as a note
  # rather than as dead code with a stale comment.

  try
    # `Bool <: Integer`, so a SQLite 0/1 boolean default converts to 0/1 — which is what the
    # column actually stores. Inside the `try` on purpose: `Int64(::UInt64)` past `typemax(Int64)`
    # raises `InexactError`, and the whole point of this helper is that no input escapes as a throw.
    default_val isa Integer && return Int64(default_val)
    return Models.format2int64(default_val)
  catch e
    # Program-state failures are not "this default is unrepresentable" — same carve-out the
    # `Model_to_str` render-failure path uses (Models.jl), so Ctrl-C during a large
    # `convert_schema_to_models` run aborts instead of being reported as a bad default.
    (e isa InterruptException || e isa StackOverflowError) && rethrow()
    # The value is shown as introspection received it — on PostgreSQL, `_pg_clean_default`'s output,
    # which strips a trailing cast and unwraps a literal. Enough to identify the column, not a
    # faithful reproduction of the DDL.
    @warn "Foreign key default could not be represented as a field default; emitting the relation without it." table = string(table_name) column = string(column_name) default = string(default_val)
    return nothing
  end
end

# ---
# Shared column-DEFAULT classification (both backends)
# ---

# A column DEFAULT that is a SQL EXPRESSION rather than a literal value, carried out of the two
# cleaners as its own type so the reader arms can route on it (#475).
#
# WHY A TYPE, AND NOT A CLASSIFIER OVER THE CLEANED STRING. Both cleaners UNQUOTE a literal, and
# after that step an expression and a literal are the same bytes: `_pg_clean_default` turns BOTH
# `'now()'::text` and `now()` into `"now()"`, and `_normalize_sqlite_default` turns both
# `'CURRENT_TIMESTAMP'` and `CURRENT_TIMESTAMP` into `"CURRENT_TIMESTAMP"`. A classifier applied to
# the RESULT is therefore forced to be wrong in one direction or the other — keep a real expression,
# or drop the string a user deliberately quoted. The quoting is visible only INSIDE the cleaner, so
# that is where the question has to be answered.
#
# Returned INSTEAD of the value rather than tagging every value with a `(value, kind)` pair: a
# literal then flows through byte-for-byte unchanged, and no call site that handles one needs to
# know this type exists.
struct _ExpressionDefault
  sql::String
end

# `string` so both `@warn ... default = string(default_val)` sites keep printing the expression text
# with no change. `==`/`hash` so tests can compare tags directly. `==` is deliberately NOT defined
# against `AbstractString`: a tag must never silently satisfy an assertion written for the old
# string-returning behaviour.
Base.string(d::_ExpressionDefault) = d.sql
Base.:(==)(a::_ExpressionDefault, b::_ExpressionDefault) = a.sql == b.sql
Base.hash(d::_ExpressionDefault, h::UInt) = hash(d.sql, hash(:_ExpressionDefault, h))
Base.show(io::IO, d::_ExpressionDefault) = print(io, "_ExpressionDefault(", repr(d.sql), ")")

# True when `s` is ONE `q`-quoted literal — every interior quote doubled. The `r"^'(.+)'$"` this
# replaces also matched `'a' || 'b'`, which is a concatenation of two.
#
# Shared by BOTH engines and therefore kept with the other cross-backend helpers (#475) — the same
# journey `_wrapped_in_parens` made in #472, and the same defect at the end of it. SQLite tested
# `startswith(s, "'") && endswith(s, "'")`, which is true of `'a' || 'b'`, so a CONCATENATION was
# read as one literal and unquoted to the mangled `a' || 'b`. A textual column then KEPT that value
# and `Model_to_str` wrote it into the generated models file, where it re-renders as
# `DEFAULT 'a'' || ''b'`. PostgreSQL has used this predicate since #455 and never had the bug, so
# the two engines disagreed on exactly the shape #475 exists to make them agree on.
#
# UTF-8 safe: it walks with `nextind` rather than indexing bytes.
function _quoted_literal(s::AbstractString, q::Char)::Bool
  (ncodeunits(s) >= 2 && first(s) == q && last(s) == q) || return false
  last_i = lastindex(s)
  i = nextind(s, firstindex(s))
  while i < last_i
    if s[i] == q
      j = nextind(s, i)
      (j <= last_i && s[j] == q) || return false
      i = nextind(s, j); continue
    end
    i = nextind(s, i)
  end
  return true
end

# The content of a `q`-quoted literal, with doubled interior quotes collapsed.
#
# `nextind`/`prevind`, never `s[2:end-1]` (#475). Those are BYTE offsets, so `end-1` lands on a
# UTF-8 continuation byte whenever the character before the closing quote is multibyte — and
# `DEFAULT 'São José'` then raised `StringIndexError` from inside the SQLite cleaner, aborting the
# WHOLE `convert_schema_to_models` read over one ordinary column. That is precisely the failure
# mode #472 exists to eliminate, and the PostgreSQL cleaner had always used the safe form.
function _unquote_literal(s::AbstractString, q::Char)::String
  inner = ncodeunits(s) == 2 ? "" : s[nextind(s, firstindex(s)):prevind(s, lastindex(s))]
  return replace(inner, string(q, q) => string(q))
end

const _SQL_NUMERIC_LITERAL = r"^[+-]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?$"

# Is `s` one unquoted SQL literal — a number, or a boolean keyword?
#
# Deliberately narrow, and sound ONLY because of where it is called: both cleaners run it on their
# final fallthrough, after every quoted form, bare `NULL`, the SQLite `X'…'` blob literal and the
# SQLite boolean keywords have already been claimed by a branch above. The only inputs it ever
# judges are therefore BARE tokens, where the whole literal vocabulary is a number or `TRUE`/`FALSE`.
# It is not a general SQL-literal test and must not be reused as one.
#
# Its existence is the reason the fix is not "drop the fallthrough": that branch carries unquoted
# LITERALS too. `DEFAULT 5` reaches `IntegerField` as the *string* `"5"` and only becomes `5`
# because the converter is `format2int64`; `DEFAULT true` reaches `BooleanField` as `"true"` and is
# parsed there. Dropping the branch wholesale would take both with it.
#
# `0x1F`, `1_000` and other non-decimal or separated spellings are classified as EXPRESSIONS.
# `parse(Int64, "0x1F")` happens to succeed in Julia, but the same token on a `FloatField` or
# `DecimalField` column does not, and reject-rather-than-reinterpret is the rule at every other
# introspection boundary (#296's blob literals, #455's identifiers). A dropped default is reported
# and recoverable; silently importing 31 as a default the user never wrote is neither.
function _is_sql_literal_token(s::AbstractString)::Bool
  t = strip(s)
  lowercase(t) in ("true", "false") && return true
  return occursin(_SQL_NUMERIC_LITERAL, t)
end

# `_wrapped_in_parens` moved to `src/column_ir.jl` (layer 1) in #496 and is imported at the top of
# this module. It kept its contract exactly — plain string logic, neither backend in it — and moved
# for the same reason it moved here from `_pg_wrapped_in_parens` in #472: a third caller appeared
# below this layer. `canonical_db_default` normalises the DECLARED side of a `db_default`, in a
# field constructor at include step 107, and `Migrations` is step 226.

# Build a field from an introspected column, dropping the column's DEFAULT if the field type
# refuses it, or `nothing` never having been a default at all.
#
# THE SAME FAILURE POLICY AS `_fk_default_or_warn` (#292), applied to every OTHER arm (#472). That
# helper covered the five foreign-key branches only; the seven generic/key branches still passed
# `default=` straight into the constructor, where `validate_default` (Models.jl) THROWS. One such
# column aborted the entire `convert_schema_to_models` read, so `inspectdb` produced nothing and
# `makemigrations` reported "no plan generated" for the whole database — over a single column.
# `DEFAULT now()` on a timestamptz is the most common expression default there is, so the practical
# trigger was "point inspectdb at almost any third-party schema".
#
# WHY THIS TAKES A CLOSURE rather than a value the way `_fk_default_or_warn` does: the FK arms all
# coerce to one target type (`Union{Int64, Nothing}`), so a value-in/value-out helper can decide
# alone. Here the target is whatever field type the column mapped to — a dozen constructors with a
# dozen different contracts — so the only honest test of "can this field hold this default" is to
# build the field and see. The closure is that construction.
#
# WHY THE CATCH IS NARROW (`FieldValidationError`, not catch-all-with-carve-outs): a bare `catch`
# here would swallow a genuine bug in the reader — a `MethodError` from a mistyped kwarg, an
# `UndefVarError` — and silently report it as a bad column default. `FieldValidationError` is the
# type every default rejection raises (`validate_default`, and the field types that check their own
# defaults). InterruptException/StackOverflowError are therefore excluded BY CONSTRUCTION rather
# than by an explicit carve-out — but only because `validate_default` no longer relabels them
# (#472, Models.jl); before that fix a Ctrl-C arrived here disguised as a FieldValidationError.
#
# WHY IT RETRIES BEFORE WARNING. `FieldValidationError` is also what a bad `max_length` or another
# non-default kwarg raises, and blaming the default for one of those would be a lie in a warning
# the user cannot check. So the retry IS the proof of culprit: if `build(nothing)` succeeds, the
# default was the problem and dropping it is the fix; if it throws too, the failure was never about
# the default and that second exception propagates undisguised, with no warning emitted. (Julia
# keeps the first exception on the stack, so it surfaces as the "caused by" of the second.)
#
# Same shape as the Django importer's retry-without-`:choices`/`:default` (importers.jl), which is
# the in-repo precedent for degrade-instead-of-abort at an import boundary.
#
# CADENCE: one warning per column, per read — the house pattern (`@warn` with structured
# `table`/`column` kwargs, as every degrade in `src/migrations/` does), NOT a once-per-table
# summary. `convert_schema_to_models` is called by `makemigrations` and by the importers, so a
# schema with `created_at DEFAULT now()` on every table warns once per such column on every run
# until the default is representable or removed. That repetition is the intended signal: the
# condition is standing, not transient. (`maxlog` is deliberately not used — see AdvisoryLock.jl
# for why it is unreliable across the repeated calls this would need to survive.)
function _field_or_drop_default(build::Function, table_name, column_name, default_val)
  default_val === nothing && return build(nothing)

  # An EXPRESSION default is unrepresentable for every field type, so it never reaches the `try`
  # below (#475). Routing it here rather than letting the constructor decide is the whole fix: the
  # `try` arm asks "does THIS field type refuse this value", which a textual column answers "no"
  # for `CURRENT_TIMESTAMP` — silently keeping an expression as a quoted literal. The question that
  # belongs to the SCHEMA is answered by the cleaner, before any field type is consulted.
  #
  # `build(nothing)` runs BEFORE the warning, mirroring the retry's order below and for the same
  # reason: a field that cannot be built at all (a `max_digits` with no `decimal_places`) must
  # raise undisguised rather than behind a warning blaming a default that was not the problem.
  #
  # The message sentence is the `try` arm's, verbatim. Six test sites and the docs filter warnings
  # with `occursin("could not be represented", …)`; a second sentence for the same event would make
  # every one of them silently under-count exactly the columns this issue is about. The kwarg set is
  # identical too, so no consumer has to know which arm fired — only `reason` differs, because there
  # is no constructor complaint to quote when no constructor was asked.
  if default_val isa _ExpressionDefault
    field = build(nothing)
    @warn _DEFAULT_DROPPED_MESSAGE table = string(table_name) column = string(column_name) default = string(default_val) field_type = string(nameof(typeof(field)))[2:end] reason = "the DEFAULT is a SQL expression, not a literal value; PormG has no field-level representation for one"
    return field
  end

  try
    return build(default_val)
  catch e
    e isa FieldValidationError || rethrow()
    field = build(nothing)
    # The value is shown as introspection received it — post-`_pg_clean_default` on PostgreSQL,
    # post-`_normalize_sqlite_default` on SQLite. Enough to identify the column, not a faithful
    # reproduction of the DDL. PormG has no representation for an expression default, so the column
    # imports with none; the database keeps its own (nothing here alters the live schema).
    #
    # `field_type` is the PUBLIC spelling — the struct is `sCharField`, the name a user declares is
    # `CharField`, and naming a type they cannot type is no help. Same `x[2:end]` strip as
    # `Model_to_str`'s own render-failure warning (Models.jl) and `querybuilder/types.jl`.
    # `reason` carries the constructor's own complaint, using importers.jl's `_one_line` — the
    # SAME call that file's twin degrade warning makes (`reason = _one_line(sprint(showerror, e),
    # 160)`). Both files are included into `Migrations`, so it needs no import. Without it the
    # warning says a default was dropped but never why.
    @warn _DEFAULT_DROPPED_MESSAGE table = string(table_name) column = string(column_name) default = string(default_val) field_type = string(nameof(typeof(field)))[2:end] reason = _one_line(sprint(showerror, e), 160)
    return field
  end
end

# ── Live defaults: clean per engine, coerce per canonical type, drop out loud (#522) ─────────

const _DEFAULT_DROPPED_MESSAGE = "Column default could not be represented as a field default; importing the column without it."

"""
    _clean_default(raw, ctype::CanonicalType, conn)

The engine half of reading a column DEFAULT: `pg_get_expr`'s or `PRAGMA table_info`'s rendering
reduced to a literal, or tagged as an expression (#475), with the two type-directed special cases the
cleaners carry — a `BLOB`/`bytea` literal decoded to bytes (#296) and a boolean folded from `1/0/t/f`
— keyed on the canonical type rather than on a field struct. Pure and total: never logs, never throws.
"""
_clean_default(raw, ctype::CanonicalType, ::PormGSQLite) =
  _normalize_sqlite_default(raw, ctype isa CBytes ? :BinaryField : ctype isa CBool ? :BooleanField : :TextField)
function _clean_default(raw, ctype::CanonicalType, ::PormGPostgres)
  cleaned = _pg_clean_default(raw)
  # A bytea DEFAULT survives the cleanup as PostgreSQL's hex text; an unrecognised literal degrades
  # to "no default", as it always has (#296).
  (cleaned isa AbstractString && ctype isa CBytes) && return _pg_bytea_literal_bytes(cleaned)
  return cleaned
end

"""
    _parse_catalog_timestamp(s) -> Union{ZonedDateTime, DateTime, Nothing}

`YYYY-MM-DD[ T]HH:MM:SS[.fff][±HH[:MM]]` — the shape a catalog renders a stored timestamp in — as a
UTC `ZonedDateTime` when an offset is present and a naive `DateTime` otherwise (naive is UTC by
PormG's convention, `format_timezone_sql`). `nothing` when the string is not that shape, so the
caller can fall back to the constructor's own ladder.

PostgreSQL's `pg_get_expr` deparses a `timestamptz` default as `'2024-05-06 07:08:09+00'::timestamp
with time zone` — space separator, a two-digit offset, no milliseconds — which is not a spelling
`normalize_datetime_default` accepts (it knows PormG's own `…T…+00:00` form). The old reader fed the
same string to the same converter, so a declared `DateTimeField(default = …)` never converged on
PostgreSQL: every run planned `SET DEFAULT`. Found in review; pinned by a unit test.
"""
function _parse_catalog_timestamp(s::AbstractString)::Union{ZonedDateTime, DateTime, Nothing}
  m = match(r"^(\d{4}-\d{2}-\d{2})[ T](\d{2}:\d{2}:\d{2})(?:\.(\d+))?(?:([+-])(\d{2})(?::?(\d{2}))?)?$", strip(s))
  m === nothing && return nothing
  fraction = m.captures[3]
  millis = fraction === nothing ? 0 : parse(Int, rpad(first(fraction, 3), 3, '0'))
  dt = DateTime(m.captures[1] * "T" * m.captures[2]) + Millisecond(millis)
  m.captures[4] === nothing && return dt
  offset = Hour(parse(Int, m.captures[5])) + Minute(m.captures[6] === nothing ? 0 : parse(Int, m.captures[6]))
  utc = m.captures[4] == "+" ? dt - offset : dt + offset
  return ZonedDateTime(utc, tz"UTC")
end

"""
    _coerce_default(value, ctype::CanonicalType)

The Julia value a DECLARED field stores for this default — the coercion each field constructor's
`validate_default` converter applies (`format2int64`, `parse(Bool, …)`, `normalize_date_default`,
`normalize_datetime_default`, `format_uuid_sql`, …), keyed on the canonical type instead of on a
struct, so the live side lands on exactly the value the declared side holds and `LiteralDefault`'s
`isequal` is a real comparison (#522). Throws `FieldValidationError` for a literal the type cannot
hold, the category the constructors throw (#239); the caller turns that into the warn-and-drop the
readers have always done.

The `CDate` arm used to be the one place that did NOT share the constructor's converter: a
`DATE … DEFAULT '2024-01-01'` column reached `DateField`'s converter, `format_date_sql`, which
returned the String into a `Union{Date, Nothing}` slot — a `MethodError`, not a
`FieldValidationError`, so it escaped the drop guard and aborted the whole schema read. This
function worked around it by open-coding `Date(String(value))`. #631 fixed the constructor side
instead (`Models.normalize_date_default`) and this arm now calls it, so the workaround is gone and
`CDate` shares one definition with `CDateTime` the way #522 intended.
"""
function _coerce_default(value, ctype::CanonicalType)
  value === nothing && return nothing
  if ctype isa Union{CInt16, CInt32, CInt64}
    value isa Bool && throw(FieldValidationError("a boolean is not an integer default"))
    value isa Integer && return Int64(value)
    value isa AbstractString && return Models.format2int64(value)
  elseif ctype isa Union{CFloat64, CDecimal}
    value isa Bool && throw(FieldValidationError("a boolean is not a numeric default"))
    value isa Real && return Float64(value)
    value isa AbstractString && return Models.format2float64(value)
  elseif ctype isa CBool
    value isa Bool && return value
    return parse(Bool, lowercase(strip(string(value))))
  elseif ctype isa CVarChar
    # `CharField` stringifies a numeric default and refuses one longer than `max_length`.
    str = value isa AbstractString ? String(value) : string(value)
    (ctype.length !== nothing && length(str) > ctype.length) &&
      throw(FieldValidationError("default value has $(length(str)) characters, max_length is $(ctype.length)"))
    return str
  elseif ctype isa Union{CText, CJSON, CUnsupported}
    value isa AbstractString && return String(value)
  elseif ctype isa CDate
    # #631: was three open-coded lines duplicating what `DateField`'s converter should have done.
    # Now the same call shape as the `CDateTime` arm below.
    #
    # The refusal changes TYPE, not reachability. An unparseable string used to raise a raw
    # `ArgumentError` from `Date(…)` and a wrong-typed literal fell through to the catch-all at the
    # bottom; both now arrive as a `FieldValidationError`. `_default_or_drop`'s `catch` is bare
    # (interrupt carve-out only), so every one of those was already warned-and-dropped — nothing
    # escaped and no schema read aborted on this path. What improves is that the refusal is inside
    # the #231/#239 taxonomy, and that the warn line's `reason` now names the offending date
    # instead of reading "Day: 29 out of range (1:28)".
    return Models.normalize_date_default(value)
  elseif ctype isa CDateTime
    # The catalog's own rendering first (`_parse_catalog_timestamp`), then the constructor's ladder.
    if value isa AbstractString
      parsed = _parse_catalog_timestamp(value)
      parsed === nothing || return parsed
    end
    return Models.normalize_datetime_default(value)
  elseif ctype isa CTime
    value isa Time && return value
    value isa AbstractString && return Time(String(value))
  elseif ctype isa CUUID
    return Models.format_uuid_sql(String(value))
  elseif ctype isa CInterval
    return Models.format_duration_sql(value)
  elseif ctype isa CBytes
    value isa AbstractVector{UInt8} && return collect(UInt8, value)
    # A literal that is not blob syntax was never a default the field could hold: "none", silently,
    # exactly as `_normalize_sqlite_default` and `_pg_bytea_literal_bytes` have always answered.
    return nothing
  end
  throw(FieldValidationError("a $(typeof(value)) is not a valid default for this column type"))
end

# The PUBLIC field name `inspectdb` would write for this column — for the dropped-default warning,
# which has always named it (`CharField`, never `sCharField`). Computed by the same compiler, under a
# null logger so its own lossy-choice warnings cannot fire from inside a default read.
_inspectdb_field_name(probe::ColumnSpec, table_name, conn)::String =
  Logging.with_logger(Logging.NullLogger()) do
    string(nameof(typeof(_inspectdb_field(probe, table_name, conn, false, nothing))))[2:end]
  end

"""
    _default_or_drop(table_name, probe::ColumnSpec, raw, conn) -> ColumnDefault

A live column's DEFAULT as the diff compares it, under the readers' standing policy (#472/#475): a
literal the type can hold is carried; a SQL expression, or a literal the type cannot hold, is
dropped with a warning naming the table and column — one per column per read, never `maxlog` — and
the column imports with no default. `probe` is the column's spec minus its default; its key arm
([`_inspectdb_key_arm`](@ref)) decides the policy the way the old readers' arms did: the
bare-`IDField` key — an INTEGER column on the fall-through key arm, `_integer_key_arm` — has never
read a default at all (its slot cannot hold the `nextval(…)` a legacy `serial` key carries, and
`check` reports that class on its own terms); a TEXT key on the same arm (a `UUIDField(primary_key =
true)`) reads its default like any column; and a relation reports through `_fk_default_or_warn`'s
foreign-key wording.
"""
function _default_or_drop(table_name, probe::ColumnSpec, raw,
                          conn::Union{PormGPostgres, PormGSQLite})::ColumnDefault
  arm = _inspectdb_key_arm(probe)
  _integer_key_arm(arm, probe.type) && return NoDefault()
  cleaned = _clean_default(raw, probe.type, conn)
  cleaned === nothing && return NoDefault()
  # #496: an expression default is CARRIED now, not dropped — the `db_default` slot can express one.
  # This test sits ABOVE the `:reference` branch on purpose: before #496 a relation's expression
  # default was reported in the foreign-key wording by `_fk_default_or_warn`, but an expression is
  # not a relational fact and `sForeignKey`/`sOneToOneField` carry the slot like every other struct.
  # Routing it here first is what makes the answer uniform across all arms, which is the property
  # #475 established and this issue has to preserve.
  #
  # THE TEXT STORED IS THE CLEANER'S OUTPUT, not `raw`, and that is what makes the column converge
  # with itself. The cleaner is applied on EVERY read, so its output is a fixed point: PostgreSQL
  # re-prints a stored default through its own deparser (`DEFAULT (random() * 10)` on an integer
  # column comes back as `((random() * (10)::double precision))::integer`), and
  # `_pg_clean_default` reduces that back to the same text it produced the first time. Storing `raw`
  # instead would put the deparser's spelling in the models file, which is longer, and no more
  # stable. `canonical_db_default` then normalises both sides of the diff identically.
  #
  # A value the guard rejects is DROPPED and warned rather than raised: a reader that threw would
  # abort the whole `convert_schema_to_models` run over one column, which is the #472 failure.
  #
  # IT IS REACHABLE FROM A REAL CATALOG, and an earlier version of this comment claimed otherwise
  # ("both readers re-print a PARSED expression, so neither can contain a top-level `;` or an
  # unterminated quote"). That enumeration was true of the characters the guard rejected when it was
  # written and stopped being true when the comma rule arrived: a deparsed expression certainly can
  # contain a top-level comma. It cannot today, because `depth` counts brackets so `ARRAY[…]` is
  # accepted — but the arm is a policy, not a formality, and `check` applies the SAME predicate so
  # it never advises pasting a value this would refuse. Found in the delta review.
  if cleaned isa _ExpressionDefault
    if !is_valid_db_default_sql(cleaned.sql)
      @warn _DEFAULT_DROPPED_MESSAGE table = string(table_name) column = probe.name default = string(cleaned) field_type = _inspectdb_field_name(probe, table_name, conn) reason = "the DEFAULT is a SQL expression PormG cannot render back safely (it contains a statement terminator, a top-level comma, a comment marker, or unbalanced quotes, parentheses or brackets)"
      return NoDefault()
    end
    return ExpressionDefault(canonical_db_default(cleaned.sql))
  end
  if arm === :reference
    value = _fk_default_or_warn(cleaned, table_name, probe.name)
    return value === nothing ? NoDefault() : _literal_default(value)
  end
  value = try
    _coerce_default(cleaned, probe.type)
  catch e
    (e isa InterruptException || e isa StackOverflowError) && rethrow()
    @warn _DEFAULT_DROPPED_MESSAGE table = string(table_name) column = probe.name default = string(cleaned) field_type = _inspectdb_field_name(probe, table_name, conn) reason = _one_line(sprint(showerror, e), 160)
    return NoDefault()
  end
  return value === nothing ? NoDefault() : _literal_default(value)
end

# The CHECK facts the IR carries are the two PormG renders, on the types it renders them on. A `>= 0`
# on a text column or a byte bound on an integer is a fact no declaration could ever match, so
# carrying it would be a permanent delta; such a clause is left to the database, unread.
function _reader_checks(found::Vector{CheckKind}, ctype::CanonicalType)::Vector{CheckKind}
  kept = CheckKind[]
  any(c -> c isa NonNegativeCheck, found) && ctype isa Union{CInt16, CInt32} && push!(kept, NonNegativeCheck())
  i = findfirst(c -> c isa ByteLengthCheck, found)
  i !== nothing && ctype isa CBytes && push!(kept, found[i])
  return kept
end

# Both readers end a column here: its facts minus the default are a probe spec, the default is read
# under that spec's arm, and the final spec carries it.
function _finish_column_spec(table_name, probe::ColumnSpec, raw_default,
                             conn::Union{PormGPostgres, PormGSQLite})::ColumnSpec
  default = _default_or_drop(table_name, probe, raw_default, conn)
  return ColumnSpec(probe.name, probe.type, probe.nullable, probe.primary_key, probe.unique, default,
                    probe.reference, probe.checks, probe.identity, probe.raw)
end

# PormG's `on_delete === nothing` and `DO_NOTHING` both render as SQL `ON DELETE NO ACTION`
# (`_foreign_key_on_delete_sql`, Models.jl since #498), so a "NO ACTION" read back out of a
# database is ambiguous — and `NO ACTION` is also what a backend stores when no action was declared
# at all.
# Introspecting it as `DO_NOTHING` would therefore stamp an explicit `on_delete=DO_NOTHING` onto
# EVERY plain foreign key in every generated model. Mapping it to `nothing` is lossless (the
# re-emitted DDL is identical either way) and keeps the two backends agreeing: PostgreSQL stores
# `confdeltype = 'a'` for the same two cases.
#
# `PROTECT` is not recoverable — it renders as SQL `RESTRICT`, so a round trip can only ever return
# `RESTRICT`. One-way by construction, not an oversight.
#
# PostgreSQL stores the action as a single char in `pg_constraint.confdeltype`. `'a'` (NO ACTION)
# maps to `nothing` for the reason above; an empty/unknown code does too, so a schema-query result
# predating #292 degrades to today's behaviour instead of erroring.
function _pg_confdeltype_to_on_delete(code)
  code === nothing && return nothing
  ismissing(code) && return nothing
  c = strip(string(code))
  c == "c" && return "CASCADE"
  c == "r" && return "RESTRICT"
  c == "n" && return "SET NULL"
  c == "d" && return "SET DEFAULT"
  return nothing   # 'a' (NO ACTION) and anything unrecognised
end

function _normalize_introspected_on_delete(action)
  action === nothing && return nothing
  ismissing(action) && return nothing
  normalized = uppercase(replace(strip(string(action)), r"\s+" => "_"))
  (isempty(normalized) || normalized == "NO_ACTION") && return nothing
  return normalized
end

# ---
# SQLite Introspection
# ---

function _strip_sqlite_default_wrapper(default_val)
  default_val === nothing && return nothing
  ismissing(default_val) && return nothing

  stripped = strip(String(default_val))
  # `_wrapped_in_parens` rather than `startswith("(") && endswith(")")` (#472). The textual test
  # is true for `(a) + (b)`, where the opening paren does NOT close on the final character, so it
  # unwrapped to `a) + (b` — two unbalanced fragments. That was survivable only while such a value
  # went on to throw: SQLite defaults now degrade to a `String` and a text column KEEPS the value,
  # so a mangled one would be written into the generated model as a literal default and re-rendered
  # as `DEFAULT 'a) + (b'`. The PostgreSQL cleaner hit this exact bug and fixed it with this
  # predicate; the SQLite twin was left behind.
  while _wrapped_in_parens(stripped)
    inner = strip(stripped[nextind(stripped, firstindex(stripped)):prevind(stripped, lastindex(stripped))])
    inner == stripped && break
    stripped = inner
  end

  return stripped
end

"""
    _sqlite_blob_literal_bytes(s) -> Union{Vector{UInt8}, Nothing}

Decode SQLite's `X'0102'` blob-literal syntax into bytes, or `nothing` if `s` is not one.

Normalizing here rather than loosening `BinaryField(default = …)` is deliberate: introspection is
the import layer, and the repo's rule is to normalize dirty inputs there instead of weakening a
field contract to accept them.
"""
function _sqlite_blob_literal_bytes(s::AbstractString)::Union{Vector{UInt8}, Nothing}
  m = match(r"^[Xx]'([0-9A-Fa-f]*)'$", strip(s))
  m === nothing && return nothing
  hex = m.captures[1]
  isodd(length(hex)) && return nothing   # malformed; treat as "no recoverable default"
  return hex2bytes(hex)
end

"""
    _pg_bytea_literal_bytes(s) -> Union{Vector{UInt8}, Nothing}

Decode PostgreSQL's hex `bytea` output form (`\\x0102`) into bytes, or `nothing` if `s` is not one.

The PostgreSQL twin of [`_sqlite_blob_literal_bytes`](@ref); see there for why the normalization
belongs in introspection rather than in the field constructor.
"""
function _pg_bytea_literal_bytes(s::AbstractString)::Union{Vector{UInt8}, Nothing}
  m = match(r"^\\\\?x([0-9A-Fa-f]*)$", strip(s))
  m === nothing && return nothing
  hex = m.captures[1]
  isodd(length(hex)) && return nothing
  return hex2bytes(hex)
end

function _normalize_sqlite_default(default_val, type_sym::Symbol)
  stripped = _strip_sqlite_default_wrapper(default_val)
  stripped === nothing && return nothing

  uppercase(stripped) == "NULL" && return nothing

  # A BinaryField default is written as `X'…'` and must come back as bytes (#296). Before this,
  # every branch below returned a String, and `BinaryField(default = <String>)` raises — so
  # introspecting a BLOB column with a DEFAULT would have crashed the whole schema read. That was
  # unreachable only while PormG never emitted a BLOB column.
  #
  # An unrecognized literal degrades to `nothing` (no default) rather than raising: a hand-written
  # or foreign table must stay introspectable, matching how `Model_to_str` degrades a field it
  # cannot render instead of failing the run.
  if type_sym == :BinaryField
    bytes = _sqlite_blob_literal_bytes(stripped)
    bytes !== nothing && return bytes
    # #475: an UNQUOTED token that is not blob syntax is an EXPRESSION (`(randomblob(16))`, which
    # `_strip_sqlite_default_wrapper` has already unwrapped), and gets the same drop-and-warn as
    # every other column type — otherwise the "uniform on every column type" rule this issue
    # establishes would have a silent hole on exactly the engine that cannot express it either.
    #
    # A LITERAL that simply is not valid blob syntax still degrades to "no default" with no warning:
    # a quoted string, and equally an `X'…'`-shaped token that is malformed (odd-length or non-hex,
    # which `_sqlite_blob_literal_bytes` rejects). Both are literals the field type cannot take,
    # which is #296's axis and contract, not #475's — reporting `X'010'` as "a SQL expression" would
    # be a false diagnosis in a warning the user cannot check.
    #
    # The `X'…'` test is ANCHORED and forbids an interior quote, matching
    # `_sqlite_blob_literal_bytes`'s own regex. `startswith(s, "X'") && endswith(s, "'")` is the
    # naive shape this whole issue exists to remove: it is equally true of
    # `X'0102' || X'03'` — a CONCATENATION, and a genuine expression — which it would then swallow
    # in silence. Found in review, after that exact bug was introduced here by the first draft.
    (_quoted_literal(stripped, '\'') || _quoted_literal(stripped, '"')) && return nothing
    occursin(r"^[Xx]'[^']*'$", stripped) && return nothing
    return _is_sql_literal_token(stripped) ? nothing : _ExpressionDefault(String(stripped))
  end

  if type_sym == :BooleanField
    lowered = lowercase(replace(stripped, "'" => "", "\"" => ""))
    lowered in ["1", "true", "t"] && return true
    lowered in ["0", "false", "f"] && return false
  end

  # BALANCED, not `startswith`/`endswith` (#475). The textual test is true for `'a' || 'b'` — a
  # CONCATENATION of two literals, whose first and last characters merely happen to be quotes — and
  # unquoting it produced the mangled `a' || 'b`, which a textual column then KEPT. PostgreSQL has
  # used the balanced predicate since #455; this is the same fix on the other engine.
  if _quoted_literal(stripped, '\'')
    return _unquote_literal(stripped, '\'')
  elseif _quoted_literal(stripped, '"')
    return _unquote_literal(stripped, '"')
  end

  # `String`, not the `SubString` `strip` produced (#472). `TextField`/`EmailField`/`ImageField`/
  # `FileField` validate against `Union{String, Nothing}` and their converter is `parse(String, x)`,
  # which has NO method for any input — so a `SubString` reached the throw path and an UNQUOTED
  # default aborted the read even on a text column. The two branches above already widen to `String`
  # (via `replace`), which is why every quoted-literal fixture passed and this went unnoticed.
  # Widening here makes the engines agree: `_pg_clean_default` reduces a quoted literal the same way.
  s = String(stripped)

  # …and whatever is left UNQUOTED is either a bare literal or a SQL EXPRESSION (#475). Until this,
  # the whole fallthrough returned a String, so whether an expression survived was decided by the
  # FIELD TYPE rather than by the schema: `TextField` validates against `Union{String, Nothing}` and
  # accepts anything, so `TEXT DEFAULT CURRENT_TIMESTAMP` was kept as a 17-character literal and
  # `Model_to_str` wrote it into the generated models file — where re-applying it renders
  # `DEFAULT 'CURRENT_TIMESTAMP'` and stores that text in every new row. The SAME expression on a
  # DATETIME column was dropped with a warning. Tagging here is what makes the two agree.
  return _is_sql_literal_token(s) ? s : _ExpressionDefault(s)
end

function get_database_schema(db::PormGSQLite)
  # Query the sqlite_master table to get the schema information
  schema_query = "SELECT type, name, sql FROM sqlite_master WHERE type='table' OR type='index';"
  schema_info = fetch(db, schema_query)

  # Initialize a dictionary to hold the schema data
  schema_data = Dict{String, Any}()

  for row in schema_info
      # For each row, store the type, name, and SQL in the schema_data dictionary
      table_name = row[:name]
      schema_data[table_name] = Dict(
          "type" => row[:type],
          "sql" => row[:sql]
      )
  end

  return schema_data
end

"""
    convertSQLToModel(sql::String) -> PormGModel

The model for one `CREATE TABLE` statement, read the way a live table is (#522): the DDL is executed
in a throwaway SQLite file and the result goes through the same reader as `convertSQLToModel(db,
table)`, so there is no second, regex-driven reader to keep in step with the first — the one this
replaced had two documented gaps (`unique` never read, a non-canonical `to_table`) for exactly that
reason.

**The statement is executed as given** — one SQL statement, in a scratch database that holds nothing
else — so pass only DDL you would run yourself. It must name its table in double quotes, as PormG
writes it; an `InvalidMigrationError` says so otherwise. SQLite does not check that a `REFERENCES`
target exists at `CREATE TABLE` time, so a statement carrying foreign keys reads fine on its own —
and, the parent being absent, its `to_table` keeps the `REFERENCES` spelling rather than a
canonical one.
"""
function convertSQLToModel(sql::String)::PormGModel
  table_name_match = match(r"CREATE TABLE \"(.+?)\"", sql)
  table_name = table_name_match !== nothing ? table_name_match.captures[1] :
    throw(InvalidMigrationError("Cannot introspect: CREATE TABLE statement has no double-quoted table name (table created outside PormG?): $(first(sql, 120))"))
  return mktempdir() do dir
    pool = SQLiteConnectionPool(joinpath(dir, "convert_sql.sqlite"); pool_size = 1)
    try
      fetch(pool, sql)
      return convertSQLToModel(pool, String(table_name))
    finally
      # Release the handle first, or Windows cannot remove the temp directory (WAL keeps it open).
      close_pool!(pool)
    end
  end
end

"""
    _sqlite_column_checks(create_sql) -> Dict{String, Vector{CheckKind}}

Recover the per-column CHECK facts PormG renders — the `>= 0` of a positive-integer field and the
`length(col) <= n` byte bound of a `BinaryField` (#296) — from a table's `CREATE TABLE` text, keyed
by LOWER-CASED column name.

`PRAGMA table_info` does not report CHECK constraints at all, and both are part of what the diff
compares (`ColumnSpec.checks`): without this the live side would compile without them and
`makemigrations` would propose the same `ADD CHECK` forever. They are read as FACTS, not inferred
from the type spelling (#522): an adopted `SMALLINT` column that never had the CHECK compiles
without it and the diff says so, once, instead of the reader claiming a constraint the catalog does
not hold.

Keys are lower-cased and looked up with `lowercase(col)` (#531): SQLite resolves identifiers
case-insensitively (ASCII only; Julia's `lowercase` is the Unicode superset, so a non-ASCII case pair
folds here where SQLite would not — the same trade `_sqlite_index_referenced_columns` makes), so the
spelling inside a CHECK need not match the column definition's nor what `PRAGMA table_info` reports.
All four identifier spellings are accepted, because an adopted schema wrote the clause, not PormG.
"""
function _sqlite_column_checks(create_sql::Union{AbstractString, Nothing})::Dict{String, Vector{CheckKind}}
  checks = Dict{String, Vector{CheckKind}}()
  create_sql === nothing && return checks
  # `"c"`, `[c]`, a backticked `c`, or bare — one capture group per spelling.
  ident = "(?:\"([^\"]+)\"|\\[([^\\]]+)\\]|`([^`]+)`|([A-Za-z_][A-Za-z0-9_]*))"
  name(m) = lowercase(String(something(m.captures[1], m.captures[2], m.captures[3], m.captures[4])))
  # NonNegative first, then ByteLength — the order `_column_checks` builds the declared side in.
  for m in eachmatch(Regex("CHECK\\s*\\(\\s*" * ident * "\\s*>=\\s*0\\s*\\)", "i"), create_sql)
    push!(get!(checks, name(m), CheckKind[]), NonNegativeCheck())
  end
  for m in eachmatch(Regex("CHECK\\s*\\(\\s*length\\s*\\(\\s*" * ident * "\\s*\\)\\s*<=\\s*(\\d+)\\s*\\)", "i"), create_sql)
    push!(get!(checks, name(m), CheckKind[]), ByteLengthCheck(parse(Int, m.captures[5])))
  end
  return checks
end

# The declared type as `PRAGMA table_info` reports it, upper-cased and stripped — the reader's own
# derivation, shared with `check()` so the two cannot disagree about a column's type. A typeless
# column reports `''`; `missing` is guarded as well as `nothing`, because a `DataFrame` cell is the
# former.
_sqlite_declared_type(x)::String =
  uppercase(String(strip((x === nothing || ismissing(x)) ? "" : String(x))))

"""
    _sqlite_live_table(db::PormGSQLite, table_name) -> LiveTable

The SQLite reader (#522): one table's catalog facts compiled straight into a `LiveTable` of
`ColumnSpec`s. No `PormGField` is built on the way — `convertSQLToModel` is this plus
`model_from_live`, and `makemigrations` uses this alone.

What each slot is read FROM, and what it is no longer inferred from:

  * `type` — the declared type `PRAGMA table_info` reports, through `parse_canonical_type`, which
    is the reader's whole type vocabulary now (`sqlite_type_map` is gone);
  * `checks` — the CHECK clauses in the stored DDL (`_sqlite_column_checks`), never the type
    spelling: an `INTEGER UNSIGNED` without its `>= 0` is read as it is;
  * `reference` — `PRAGMA foreign_key_list`, single-column keys only (#415), the parent resolved to
    its `sqlite_master` spelling (#390) and the binding derived from it exactly as `.to` used to be;
    `on_delete` rendered through `_foreign_key_on_delete_sql` so it compares by clause (#498);
  * `unique` / `indexes` — the single-column UNIQUE constraints and non-unique indexes the pragmas
    list (#318/#325). A key is unique on the arms that always built it so (`IDField`, a pk-fk),
    never from the pragma, exactly as before; a relational column's `db_index` is what the catalog
    holds, not the `true` the old reader stamped on every foreign key;
  * `identity` — the catalog image of the DECLARED rule, stated once beside its other half in
    `_column_identity(::PormGSQLite)`: an INTEGER column on the `IDField` arm (`_integer_key_arm`)
    compiles to the SQLite identity, because `IDField` is the only integer key PormG can declare and
    it always renders `AUTOINCREMENT`, so a rowid key without the token has no declaration that
    could ever equal it; a TEXT key (`UUIDField(primary_key = true)`) compiles none;
  * `default` — `_default_or_drop`: the literal coerced per canonical type; an expression or
    an uncoercible literal dropped with the same warning as before (#472/#475).

The table name is resolved to its catalog spelling ONCE, before any read (#531): the pragmas resolve
a name case-insensitively but `sqlite_master.name` is BINARY-collated, and a mixed-case table read
under another spelling used to lose every CHECK.
"""
function _sqlite_live_table(db::PormGSQLite, table_name::AbstractString)::LiveTable
  table_name = _sqlite_canonical_table_name(db, String(table_name))
  cols = fetch(db, "PRAGMA table_info(\"$table_name\")") |> DataFrame
  fks = fetch(db, "PRAGMA foreign_key_list(\"$table_name\")") |> DataFrame
  # PRAGMA cannot see CHECK constraints, so they come from the stored DDL text (#296). Parameterized,
  # not interpolated: `table_name` is caller-supplied (`convertSQLToModel` is public), and unlike the
  # PRAGMA calls above — which interpolate into a *quoted identifier* — this value lands inside a
  # single-quoted literal, where an embedded `'` would break out. An exact `name = ?` is correct only
  # because the name was resolved to the catalog spelling above (#531).
  ddl_rows = fetch(db, "SELECT sql FROM sqlite_master WHERE type='table' AND name = ?", [table_name]) |> DataFrame
  checks = _sqlite_column_checks(nrow(ddl_rows) == 0 || ismissing(ddl_rows[1, :sql]) ? nothing : ddl_rows[1, :sql])
  unique_cols = _sqlite_single_column_unique_columns(db, table_name)
  indexed_cols = _sqlite_single_column_indexed_columns(db, table_name)
  composite = _sqlite_composite_indexes(db, table_name)

  # Single-column foreign keys by child column. A MULTI-COLUMN key is skipped rather than split
  # (#415): `PRAGMA foreign_key_list` returns one row per column grouped under a shared `id`, PormG
  # has no composite-FK field type, and a skipped constraint reads as "no relation" on both sides of
  # the diff — symmetric with the PostgreSQL reader's `array_length(con.conkey, 1) = 1`.
  fk_map = Dict{String, Any}()
  parent_canon = Dict{String, String}()
  if !isempty(fks)
    columns_per_fk = Dict{Any, Int}()
    for fk_row in eachrow(fks)
      columns_per_fk[fk_row.id] = get(columns_per_fk, fk_row.id, 0) + 1
    end
    for fk_row in eachrow(fks)
      columns_per_fk[fk_row.id] > 1 && continue
      fk_map[String(fk_row.from)] = fk_row
    end
    # #390: each DISTINCT parent resolved to its `sqlite_master` spelling once — `PRAGMA
    # foreign_key_list` reports the parent as the `REFERENCES` clause spelled it, which need not
    # match `CREATE TABLE`. A parent not in the catalog (a dangling key, which SQLite permits) keeps
    # the REFERENCES spelling; the first `migrate` creates it and the next read canonicalises it.
    for fk_row in values(fk_map)
      parent = String(fk_row.table)
      haskey(parent_canon, parent) || (parent_canon[parent] = _sqlite_canonical_table_name(db, parent))
    end
  end

  columns = OrderedDict{String, ColumnSpec}()
  for col_row in eachrow(cols)
    col_name = String(col_row.name)
    raw_type = _sqlite_declared_type(col_row.type)
    ctype = parse_canonical_type(raw_type, db)
    is_pk = col_row.pk > 0
    nullable = col_row.notnull == 0
    reference = nothing
    if haskey(fk_map, col_name)
      fk = fk_map[col_name]
      parent = parent_canon[String(fk.table)]
      reference = ForeignKeyRef(parent,
                                format_model_name(Models._model_binding_name(parent)),
                                String(fk.to),
                                Models._foreign_key_on_delete_sql(_normalize_introspected_on_delete(fk.on_delete)))
    end
    arm = _key_arm(is_pk, ctype, reference !== nothing)
    # `unique`, per arm, as the old reader built the field — narrowed in review: an INTEGER key on
    # the `IDField` arm and a pk-fk `OneToOneField` are unique by construction; every other column,
    # keys included, is unique when the pragma lists a single-column UNIQUE constraint on it (#318).
    # A PRIMARY KEY's own autoindex has `origin = 'pk'`, never `'u'`, so a bare `TEXT PRIMARY KEY` —
    # what `UUIDField(primary_key = true)` renders — reads `false`, exactly as its declaration
    # compiles. (The retired arm gave every fall-through key the `IDField`'s `unique = true` and
    # identity, so such a table rebuilt on every run.)
    integer_key = _integer_key_arm(arm, ctype)
    spec_unique = (integer_key || (arm === :reference && is_pk)) ? true : col_name in unique_cols
    identity = integer_key ? ColumnIdentity(false, false, true) : nothing
    probe = ColumnSpec(col_name, ctype, is_pk ? false : nullable, is_pk, spec_unique, NoDefault(),
                       reference, _reader_checks(get(checks, lowercase(col_name), CheckKind[]), ctype),
                       identity, raw_type)
    default_val = ismissing(col_row.dflt_value) ? nothing : col_row.dflt_value
    columns[col_name] = _finish_column_spec(table_name, probe, default_val, db)
  end
  indexes = Dict{String, Union{String, Nothing}}(k => v for (k, v) in indexed_cols)
  return LiveTable(table_name, columns, indexes, composite)
end

"""
    convertSQLToModel(db::PormGSQLite, table_name) -> PormGModel

The model `inspectdb` writes for one live SQLite table: `_sqlite_live_table` compiled
through `model_from_live`. The table name may be spelled in any case (#531); the model is
named by the catalog spelling.
"""
convertSQLToModel(db::PormGSQLite, table_name::String)::PormGModel =
  model_from_live(_sqlite_live_table(db, table_name), db)

"""
    _is_ignored_table(table_name, ignore_table) -> Bool

Whether `table_name` is skipped by the introspection ignore list — matched as a **prefix**, on both
backends (#325).

Every entry in `postgres_ignore_table` / `sqlite_ignore_schema` is a framework prefix
(`"django_"`, `"auth_"`, `"celery_"`, `"sqlite_autoindex"`) or a whole table name
(`"pormg_migrations"`), and a prefix test covers both. The two backends used to disagree, and both
were wrong in different directions:

  * PostgreSQL used `occursin`, so a user table merely *containing* an entry was silently dropped
    from the live schema — `company_admin_log` matched `"admin_"`, `oauth_tokens` matched `"auth_"`.
    A dropped table does not read as "ignored" downstream, it reads as "does not exist", so
    `makemigrations` proposed `CREATE TABLE` for it on every single run.
  * SQLite used `==`, so `"sqlite_autoindex"` — a prefix of `sqlite_autoindex_<table>_<n>`, never a
    table name in its own right — could never match. Harmless only because the table query already
    filters `name NOT LIKE 'sqlite_%'`.
"""
_is_ignored_table(table_name, ignore_table)::Bool =
  any(ignored -> startswith(String(table_name), ignored), ignore_table)

# `pragma_table_list`, the catalog that labels a table `virtual` / `shadow`, is SQLite 3.37.0+.
const _SQLITE_TABLE_LIST_MIN_VERSION = 3_037_000

"""
    _sqlite_user_table_names(db::PormGSQLite; sqlite_version) -> Vector{String}

The tables of the main schema that PormG could own, in `sqlite_master` order: ordinary tables
only (#730). This is the one list the SQLite readers enumerate: `read_live_schema`, `check()`'s
expression-default report and `status()`'s drift probe all use it, so they cannot disagree about
which tables exist.

`sqlite_master` alone cannot answer that. It lists a virtual table (`CREATE VIRTUAL TABLE … USING
fts5(…)`, `rtree`) and each of the SHADOW tables its module keeps its data in (`<name>_data`,
`<name>_idx`, `<name>_content`, `<name>_node`, …) as `type = 'table'`, like any other. No model
declares them, so `makemigrations` planned a `DROP TABLE` for every one: the destructive guard
stopped it, and no migration could run on that database without `destructive = true`, which would
have destroyed the index. This is the ownership rule, not the ignore list: it applies whatever
`ignore_table` a caller passes, as the PostgreSQL twin [`_PG_OWNABLE_TABLE_FILTER`](@ref) does.

Two sources, in order of authority:

  1. **`pragma_table_list`** (SQLite 3.37+) labels a virtual table `virtual` and a shadow table
     `shadow`, and both are left out. It is exact, but only as far as SQLite can tell: a table is a
     shadow table when its name is `<vtab>_<suffix>` AND the virtual table's MODULE, asked through
     `xShadowName`, claims the suffix. A module that is not registered on this connection — an
     extension such as sqlite-vec or SpatiaLite that the application loads on its own connection
     only — is never asked, and its shadow tables come back as plain `table`.
  2. **SQLite's own naming rule**, for exactly that gap. A virtual table none of whose shadow tables
     was confirmed has its whole `<vtab>_` namespace (compared case-insensitively, as SQLite does)
     treated as its module's, and a warning names every table skipped that way. A confirmed shadow
     vouches only for the virtual table with the LONGEST name it extends, so a registered
     `docs_title` cannot vouch for an unregistered `docs`. The same gap opens for a registered
     module that does not report shadow tables (no `xShadowName`), and below 3.37, where there is no
     `pragma_table_list` at all: there a virtual table is still recognised by the DDL SQLite stores
     for it (always normalised to `CREATE VIRTUAL TABLE …`), and this rule covers its shadow tables.

The fallback errs toward NOT reading a table, which is the safe direction here: an unread table is
never dropped, while a misread shadow table is one `destructive = true` would destroy. Its cost is
a user table named like a virtual table's shadows (`<vtab>_notes` beside `<vtab>`): it is skipped,
the warning names it, and a model that declares it plans `CREATE TABLE`, which fails at `migrate`
because the table exists — loud, but the fix is renaming the table. `sqlite_version` is the library
version (`backend_sqlite_version`); it is a keyword so the pre-3.37 path can be exercised against a
current SQLite.

Views are not in the list either, and never were: they are `type = 'view'`.
"""
function _sqlite_user_table_names(db::PormGSQLite;
                                  sqlite_version::Integer = backend_sqlite_version(db))::Vector{String}
  # The query the readers always ran, so the scan order — and the order tables are read back in —
  # is the catalog's. The names compare exactly because both catalogs hold the `CREATE` spelling.
  catalog = fetch(db, "SELECT name, sql FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%';") |> DataFrame
  names = String[String(r.name) for r in eachrow(catalog)]
  kind = Dict{String, String}()          # name ⇒ "virtual" / "shadow" / "table"; absent ⇒ "table"
  if sqlite_version >= _SQLITE_TABLE_LIST_MIN_VERSION
    for r in eachrow(fetch(db, "SELECT name, type FROM pragma_table_list WHERE schema = 'main';") |> DataFrame)
      kind[String(r.name)] = String(r.type)
    end
  else
    for r in eachrow(catalog)
      sql = r.sql
      (sql === missing || sql === nothing) && continue
      Base.startswith(uppercase(lstrip(String(sql))), "CREATE VIRTUAL TABLE") && (kind[String(r.name)] = "virtual")
    end
  end
  kind_of(n) = get(kind, n, "table")
  virtual = String[lowercase(n) for n in names if kind_of(n) == "virtual"]
  # A confirmed shadow table vouches for ONE virtual table: the longest name it extends. Matching
  # any prefix would let `docs_title`'s confirmed `docs_title_data` vouch for an unregistered `docs`
  # too, and `docs`'s own shadows would then be read — and dropped (found in review).
  vouched = Set{String}()
  for n in names
    kind_of(n) == "shadow" || continue
    s = lowercase(n)
    owners = String[v for v in virtual if Base.startswith(s, v * "_")]
    isempty(owners) || push!(vouched, owners[argmax(length.(owners))])
  end
  # The `<vtab>_` namespaces no module vouched for.
  unvouched = String[v * "_" for v in virtual if !(v in vouched)]
  owned = String[n for n in names if kind_of(n) == "table"]
  guessed = String[n for n in owned if any(p -> Base.startswith(lowercase(n), p), unvouched)]
  if !isempty(guessed)
    @warn "Introspection skips these tables: each is named like a shadow table of a virtual table whose shadow tables SQLite cannot confirm on this connection (its module is not loaded here, does not report shadow tables, or SQLite is older than 3.37), so they are neither read nor dropped. If one is your own table, rename it: a model declaring it would plan CREATE TABLE, which fails because the table exists." tables = guessed
  end
  return String[n for n in owned if !(n in guessed)]
end

"""
    read_live_schema(db; ignore_table, include_table) -> Vector{LiveTable}

Every user table of the live database as a `LiveTable` — the whole of what `makemigrations`
reads (#522). `convert_schema_to_models` is this plus `model_from_live` per table,
for `inspectdb`. Filtering is the same on both engines: `include_table` keeps only those names, and
`ignore_table` plus the consumer-registered `_EXTRA_IGNORE_TABLES` skip framework tables by prefix
(#325).

Relations PormG cannot own are never read, whatever the filters say (#730): views and materialized
views on both engines, SQLite virtual tables and their shadow tables
([`_sqlite_user_table_names`](@ref)), PostgreSQL partitions and tables an extension owns
([`_PG_OWNABLE_TABLE_FILTER`](@ref)). A relation the reader never sees is one `makemigrations` can
never plan to drop.
"""
function read_live_schema(db::PormGSQLite; ignore_table::Vector{String} = sqlite_ignore_schema,
                          include_table::Union{Vector{String}, Nothing} = nothing)::Vector{LiveTable}
  ignore_table = unique(vcat(ignore_table, _EXTRA_IGNORE_TABLES[]))
  out = LiveTable[]
  for table_name in _sqlite_user_table_names(db)
    include_table !== nothing && !any(included -> table_name == included, include_table) && continue
    _is_ignored_table(table_name, ignore_table) && continue
    push!(out, _sqlite_live_table(db, table_name))
  end
  return out
end

"""
    convert_schema_to_models(db; ignore_table, include_table) -> Vector{PormGModel}

The models `inspectdb` writes for the live database: `read_live_schema` compiled through
`model_from_live`, table by table. `makemigrations` does not call this any more — it diffs
the `LiveTable`s directly — so a struct chosen here is a choice about the generated file, never
about the plan.
"""
convert_schema_to_models(db::PormGSQLite; kwargs...)::Vector{PormGModel} =
  PormGModel[model_from_live(table, db) for table in read_live_schema(db; kwargs...)]

# ---
# PostgreSQL Introspection
# ---

"""
    _PG_OWNABLE_TABLE_FILTER

The `WHERE` fragment that keeps a `relkind = 'r'` table only when PormG could own it (#730), over
a `pg_class` row aliased `c`. Every PostgreSQL query that enumerates live tables interpolates THIS
constant — the schema dump (`get_database_schema`), the composite-index reader
(`_pg_composite_indexes`) and `status()`'s drift probe — so they cannot disagree about which
tables exist. It is the twin of [`_sqlite_user_table_names`](@ref).

`relkind = 'r'` alone admitted two kinds of relation no model can declare, and `makemigrations`
planned a `DROP TABLE` for each:

  * **a partition** — the partitioned parent is `relkind = 'p'` and was already skipped, but every
    partition is an ordinary `'r'` table. `relispartition` marks it.
  * **a table an extension owns** — PostGIS's `spatial_ref_sys` is the common one, and dropping it
    fails with "extension postgis requires it". Membership is recorded only in `pg_depend`, as a
    dependency of `deptype = 'e'` on the extension.

This is the filter Atlas's PostgreSQL inspector applies for the same reason, and Django's
`inspectdb` leaves partitions out by default. Views and materialized views need nothing here: they
are `relkind` `'v'` / `'m'`.
"""
const _PG_OWNABLE_TABLE_FILTER = """
      AND NOT c.relispartition
      AND NOT EXISTS (SELECT 1 FROM pg_depend dep
                      WHERE dep.classid = 'pg_class'::regclass AND dep.objid = c.oid
                        AND dep.deptype = 'e')"""

"""
    _PG_NON_NEGATIVE_CHECK_MATCH

The predicate that recognises PormG's OWN non-negative CHECK on PostgreSQL (#731), over a
`pg_constraint` row aliased `con` and the one `pg_attribute` row it constrains, aliased `a`. It is
interpolated by BOTH the reader (the `non_negative_checks` CTE in `get_database_schema`) and the
dropper (`get_constraints_check`), so what `makemigrations` reads as PormG's check and what
`Dialect.alter_field` drops as PormG's check cannot differ.

PormG writes `CHECK ("col" >= 0)` (`Dialect._non_negative_check_clause`), and
`pg_get_constraintdef` hands it back re-parenthesised as `CHECK ((col >= 0))`, the column quoted
only when it must be — exactly `quote_ident`'s rule, because both call the same quoting routine
(`"Grid"` for a mixed-case name). The match is on that whole text. It used to be
`LIKE '%>= 0%'` (and `ILIKE` in the dropper), which read a user's `CHECK (grid >= 0 AND grid <=
30)` or `CHECK (price >= 0.5)` as PormG's, so the planner could propose dropping the user's
constraint. This is the same exactness the SQLite reader has: `_sqlite_column_checks` matches the
rendered clause with an anchored regex.

A hand-written `CHECK (col >= 0)` is still indistinguishable from PormG's, on both engines — the
same text is the same fact. The byte-length CHECK (`byte_length_checks` /
`get_constraints_byte_length_check`) still matches any `octet_length … <= N` clause rather than one
exact clause — this defect, on the other CHECK PormG writes; #747 tracks it.
"""
const _PG_NON_NEGATIVE_CHECK_MATCH =
  "pg_get_constraintdef(con.oid) = 'CHECK ((' || quote_ident(a.attname) || ' >= 0))'"

"""
    _pg_composite_indexes(db::PormGPostgres; schema = "public") -> Dict{String, Vector{LiveComposite}}

Every model-level index in `schema` that PormG can re-emit, as `table_name => [LiveComposite, …]` —
the PostgreSQL half of #347 / #161 and the exact mirror of [`_sqlite_composite_indexes`](@ref).

Three shapes, partitioned against the column readers of `get_database_schema` so no index has two
owners:

| shape | reads as | the other arity belongs to |
|---|---|---|
| non-unique, `indnkeyatts > 1` | `Index` | the `indexes` CTE (`= 1`) — `db_index` |
| unique with no backing constraint, any arity | `UniqueConstraint` | nobody: a one-column bare unique index is what a one-field `UniqueConstraint` creates |
| unique backing a `contype = 'u'` constraint, arity > 1 | `UniqueConstraint`, `constraint = true` | the `unique_constraints` CTE (`= 1`) — the field's `unique` |

`indpred IS NULL` keeps a partial index out. Before #161 the reader carried `NOT indisunique`, so no
composite uniqueness came back at all — neither PormG's own `CREATE UNIQUE INDEX` nor Django's
`unique_together`, which PostgreSQL holds as a real constraint. Harmless while nothing diffed
composites; with a diff it would have made every declared `UniqueConstraint` look missing on every
run.

**The backing constraint is joined on `conrelid = indrelid` and `contype IN ('u', 'p', 'x')`, never
on `conindid` alone.** A foreign key ALSO records `conindid`: the referenced unique index, on the
PARENT. A bare `conindid` test would read a unique index some child's key points at — or, for a
self-reference, the table's own — as constraint-backed, and the planner would then emit a
`DROP CONSTRAINT` for a constraint that does not exist. (`get_constraints_index` asks a broader
question — "is any constraint using this index" — where that is exactly right.)

Run **once for the whole schema**, not per table, and joined to the models by name in
`convert_schema_to_models`. It is a separate query rather than another CTE on the schema dump because
that query returns one row per table and would need a second aggregation level.

The other half of that rationale is **retired and must not be restored**: it used to say no delimiter
could serialize `(index, columns)` pairs safely, because every candidate is a legal character in a
PostgreSQL identifier. True of any *delimiter* — but #455 moved the schema query off delimiters
entirely and onto `json_agg(json_build_object(...))`, which escapes its own. So folding this query in
is now merely unnecessary work, not an impossibility, and the counter-example lives in this same
file.

Everything PormG cannot re-emit is excluded, never read partially or approximately. Reading it
"close enough" would regenerate a **different** index under the developer's name, which is the one
failure a schema dump must not have — the same reject-rather-than-reinterpret rule the Django
importer applies to `Meta.indexes`. Beyond the shared predicates:

  * `am.amname = 'btree'` — `Dialect.create_index` emits a default b-tree and nothing else. A GIN,
    GiST, BRIN or hash index read back as an `Index` would regenerate as a b-tree (#29).
  * `NOT i.indisexclusion` — an `EXCLUDE USING gist (…)` constraint's backing index is non-unique,
    non-primary and unfiltered, so it passes every other predicate. Regenerating it as a plain index
    would drop a constraint the database was enforcing.
  * `indoption`, `indclass` and `indcollation`, selected per column and filtered in Julia alongside
    the NULL check: a **non-default sort** (`indoption != 0` — descending *or* `NULLS FIRST`), a
    non-default **operator class** (`varchar_pattern_ops`), or an explicit **collation**
    (`COLLATE "C"`) each makes a different index. PormG can express none of them, and the importer
    already refuses Django's `Index(fields=["-year"])` and `opclasses=` on the same grounds.

    The collation test answers the same *question* as the SQLite reader's non-BINARY `coll` filter
    but is not the same *test*, and the difference is deliberate rather than drift — do not "fix"
    one to match the other. This one is RELATIVE (did the index override the column's collation?);
    SQLite's is ABSOLUTE (is the effective collation `BINARY`?), because `pragma_index_xinfo` cannot
    distinguish an index-level `COLLATE` from one declared on the column. They agree on the case
    both exist for — an explicit `COLLATE` in the index — and diverge only on a column *declared*
    with a non-default collation, which PostgreSQL keeps (re-emitting the index reproduces it
    exactly) and SQLite drops for want of the information to do better.
  * Four whole-index refusals, each a shape PormG would re-emit as a DIFFERENT index (#161): an
    `INCLUDE` clause (`indnatts <> indnkeyatts` — the payload columns vanish on re-emission); an
    invalid index (`NOT indisvalid`, a failed `CREATE INDEX CONCURRENTLY`); a `DEFERRABLE` unique
    constraint (a different enforcement point); and `NULLS NOT DISTINCT`. The last is read from
    `pg_get_indexdef` rather than `pg_index.indnullsnotdistinct`, which only exists from PostgreSQL
    15 — naming it would break every introspection on 11 through 14.

    Both are subscripted `[k.ord - 1]`, and the `- 1` is load-bearing. `indkey`/`indoption`/`indclass`
    are `int2vector`/`oidvector`, which PostgreSQL builds with **lower bound 0**; the `::int2[]` cast
    is binary-coercible (`pg_cast.castmethod = 'b'`, no function runs), so the 0-based bound survives
    it. `WITH ORDINALITY` numbers rows from 1 regardless. Without the offset every row reads the
    *next* column's option — so a `DESC` or non-default opclass on the **first** key column, the
    canonical case, went undetected while the last row read out of range and came back NULL.
    Measured on a live server: `array_lower(indoption::int2[], 1)` is `0`, and
    `CREATE INDEX … (a DESC, b)` read back as a plain ascending index. There are no false positives,
    which is why nothing failed.

Two details the naive query gets wrong:

  * `unnest(indkey) WITH ORDINALITY` rather than `attnum = ANY(indkey)`: an index's column ORDER is
    part of its identity, and `ANY` returns them in table order. `ord <= indnkeyatts` then drops an
    `INCLUDE` clause's non-key columns, which are payload, not index keys.
  * the `LEFT JOIN` to `pg_attribute` is deliberate: an expression member has `attnum = 0` and matches
    no row. It surfaces as a NULL column name, and the caller drops that index whole rather than
    declaring the remaining columns as if they were the index (functional indexes are #29).

`indnkeyatts` is PostgreSQL 11+, which the pre-existing `indexes` CTE already requires, so this adds
no floor of its own.

The partition with the `db_index` reader is per INDEX (`indnkeyatts = 1` there, `> 1` here), not per
column: the older CTE still selects its column with `attnum = ANY(indkey)`, so a covering
`CREATE INDEX ON t (a) INCLUDE (b, c)` marks `b`/`c` as `db_index` too. That is pre-existing and
untouched here — no index reaches both readers.
"""
function _pg_composite_indexes(db::PormGPostgres; schema::Union{String, Nothing} = "public")::Dict{String, Vector{LiveComposite}}
  # Parameterized rather than interpolated: `schema` is a keyword argument, so it is caller-supplied
  # by contract even though every call site today passes the default.
  schema_clause = schema === nothing ? "" : "AND n.nspname = \$1"
  params = schema === nothing ? String[] : String[schema]
  query = """
    SELECT c.relname AS table_name,
           ic.relname AS index_name,
           i.indisunique AS is_unique,
           con.contype::text AS contype,
           con.condeferrable AS is_deferrable,
           i.indisvalid AS is_valid,
           (i.indnatts <> i.indnkeyatts) AS has_include,
           (i.indisunique AND pg_get_indexdef(i.indexrelid) LIKE '%NULLS NOT DISTINCT%') AS nulls_not_distinct,
           a.attname AS column_name,
           (i.indoption::int2[])[k.ord - 1] AS opt,
           (i.indcollation::oid[])[k.ord - 1] AS idx_coll,
           a.attcollation AS col_coll,
           oc.opcdefault AS opc_default
    FROM pg_index i
    JOIN pg_class ic ON ic.oid = i.indexrelid
    JOIN pg_am am ON am.oid = ic.relam
    JOIN pg_class c ON c.oid = i.indrelid
    JOIN pg_namespace n ON n.oid = c.relnamespace
    JOIN LATERAL unnest(i.indkey::int2[]) WITH ORDINALITY AS k(attnum, ord)
      ON k.ord <= i.indnkeyatts
    LEFT JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = k.attnum
    LEFT JOIN pg_opclass oc ON oc.oid = (i.indclass::oid[])[k.ord - 1]
    LEFT JOIN pg_constraint con ON con.conindid = i.indexrelid AND con.conrelid = i.indrelid
                               AND con.contype IN ('u', 'p', 'x')
    WHERE c.relkind = 'r'
      $(_PG_OWNABLE_TABLE_FILTER)
      AND am.amname = 'btree'
      AND NOT i.indisprimary
      AND NOT i.indisexclusion
      AND i.indpred IS NULL
      AND (i.indisunique OR i.indnkeyatts > 1)
      $(schema_clause)
    ORDER BY c.relname, ic.relname, k.ord;
    """
  rows = DataFrame(fetch(db, query, params))
  out = Dict{String, Vector{LiveComposite}}()
  nrow(rows) == 0 && return out
  # index name ⇒ its column list, per table; `ORDER BY … k.ord` above means push order IS index order.
  # `nothing` marks a member PormG cannot express; the whole index is then skipped below.
  grouped = OrderedDict{Tuple{String, String}, Vector{Union{String, Nothing}}}()
  kind = Dict{Tuple{String, String}, Tuple{Bool, Bool}}()      # ⇒ (unique, constraint-backed)
  refused = Set{Tuple{String, String}}()
  for r in eachrow(rows)
    (r.table_name === missing || r.index_name === missing) && continue
    key = (string(r.table_name), string(r.index_name))
    unique = r.is_unique === true
    constraint = r.contype !== missing && string(r.contype) == "u"
    kind[key] = (unique, constraint)
    # Whole-index refusals (see the docstring). A NULL defaults to REFUSED, like every test below.
    (r.is_valid !== true || r.has_include !== false || r.nulls_not_distinct !== false ||
     (constraint && r.is_deferrable !== false)) && push!(refused, key)
    # Every test defaults to UNUSABLE on a NULL, which is the safe direction: after the `k.ord - 1`
    # fix the subscripts are always in range, so a NULL here means something unexpected, and this
    # reader's whole contract is that it never reads an index approximately.
    #
    #   * `indoption != 0`, not `& 1`. Bit 0 is DESC and bit 1 is NULLS FIRST (`access/skey.h`), and
    #     `DESC` implies `NULLS FIRST` — a live `(a DESC, b)` measures 3, not 1. Masking bit 0 alone
    #     therefore lets `(a NULLS FIRST, b)` (value 2) through, and PormG would re-emit it as
    #     NULLS LAST. `Dialect.create_index` only ever emits the all-default 0.
    #   * `opcdefault = false` is an explicit operator class (`varchar_pattern_ops`).
    #   * `indcollation` differing from the COLUMN's own collation is an explicit `COLLATE` in the
    #     index — a different comparison, so a different index. 0 means no collation applies (an
    #     integer column). Deliberately RELATIVE, unlike SQLite's absolute non-BINARY test — see the
    #     docstring; a PormG-created index can never trip this, since PormG emits no `COLLATE` at all.
    unusable = r.column_name === missing ||
               r.opt === missing || Int(r.opt) != 0 ||
               r.opc_default === missing || r.opc_default == false ||
               r.idx_coll === missing ||
               (r.idx_coll != 0 && (r.col_coll === missing || r.idx_coll != r.col_coll))
    push!(get!(grouped, key, Union{String, Nothing}[]), unusable ? nothing : string(r.column_name))
  end
  for ((tbl, idx), cols) in grouped
    (tbl, idx) in refused && continue
    unique, constraint = kind[(tbl, idx)]
    # Arity partition (see the table above): only a BARE unique index may have one column.
    length(cols) > 1 || (unique && !constraint) || continue
    any(c -> c === nothing, cols) && continue    # a member PormG cannot re-emit ⇒ drop it whole
    push!(get!(out, tbl, LiveComposite[]), LiveComposite(idx, String[String(c) for c in cols], unique, constraint))
  end
  return out
end

"""
  convert_schema_to_models(db::PormGPostgres; ignore_table::Vector{String} = postgres_ignore_table)

Convert the database schema to models.

# Arguments
- `db::PormGPostgres`: The database connection.
- `ignore_table::Vector{String}`: A vector of table names to ignore. Defaults to `postgres_ignore_table`.

# Returns
- `models_array::Vector{Any}`: A vector containing the converted models.

# Description
This function retrieves the database schema and converts it to models. It collects all create instructions and skips tables specified in the `ignore_table` vector. The function prints the type of each schema and returns the schema for debugging purposes. It stops processing after the fifth schema.
"""
function read_live_schema(db::PormGPostgres; ignore_table::Vector{String} = postgres_ignore_table,
                          include_table::Union{Vector{String}, Nothing} = nothing)::Vector{LiveTable}
  ignore_table = unique(vcat(ignore_table, _EXTRA_IGNORE_TABLES[]))
  schemas = get_database_schema(db)
  # #347: composite indexes come from their own schema-wide query — see `_pg_composite_indexes` for
  # why they cannot ride along on the dump above. Keyed by physical table name.
  composite_by_table = _pg_composite_indexes(db)
  out = LiveTable[]
  for schema in eachrow(schemas)
    table_name = String(schema.table_name)
    include_table !== nothing && !any(included -> table_name == included, include_table) && continue
    _is_ignored_table(table_name, ignore_table) && continue
    table = _pg_live_table(schema)
    push!(out, LiveTable(table.name, table.columns, table.indexes,
                         get(composite_by_table, table.name, LiveComposite[])))
  end
  return out
end

convert_schema_to_models(db::PormGPostgres; kwargs...)::Vector{PormGModel} =
  PormGModel[model_from_live(table, db) for table in read_live_schema(db; kwargs...)]

function get_database_schema(db::PormGPostgres; schema::Union{String, Nothing} = "public", table::Union{String, Nothing} = nothing)
  # ONE ROUND TRIP. There used to be a `SELECT split_part(version(), ' ', 2)` probe here, whose only
  # consumer was a `major_version >= 10` gate around an `attidentity` SQL fragment. That gate was
  # dead: the `indexes` CTE below uses `indnkeyatts`, which is PostgreSQL 11+, and it sits in THIS
  # SAME STATEMENT — so 11 is the effective floor for every introspection and nothing could reach
  # the `else` branch. #455 made `identity` a JSON field read straight from `a.attidentity`, which
  # left the probe with no consumer at all. The floor is stated here rather than probed for.
  #
  # #455: every aggregate that is TRANSPORTED to the reader is `json_agg(...)::text`, not
  # `array_to_string(array_agg(...), ', ')`. (`unique_constraints` and `non_negative_checks` still
  # build plain `array_agg` arrays; those never leave the statement — they are consumed by `= ANY`
  # in the outer SELECT, so no delimiter is ever chosen for them and none can be forged.)
  # The old wire format chose `", "` as its entry separator, and `", "` is a legal substring of the
  # data it delimited — `quote_ident('Race, Total')` is `"Race, Total"`, and `pg_get_expr` renders
  # `DEFAULT concat('a', 'b')` with one too. A single tear did not merely split one column in two:
  #
  #   * `columns`      — the real column vanished and two phantoms appeared, so makemigrations
  #                      proposed adding the phantoms and dropping the real column on every run.
  #   * `primary_keys` — tore on the SAME name, so both sides AGREED on both wrong names and both
  #                      phantoms came back as IDFields.
  #   * `foreign_keys` — six parallel aggregates zipped POSITIONALLY, and `zip` truncates to the
  #                      shortest, so every LATER foreign key shifted onto the wrong parent table,
  #                      wrong referenced column and wrong ON DELETE. Worse than a phantom: the
  #                      planner then diffed a live, correct constraint against a real table that is
  #                      the wrong one.
  #   * `indexes`      — the same zip shifted index NAMES onto other columns, and `cache["index"]`
  #                      feeds `planner._drop_index`.
  #
  # JSON escapes its own delimiters, so no identifier and no DEFAULT expression can forge one. That
  # makes the tear UNREPRESENTABLE rather than guarded, which is why #414's `_split_leading_quoted_ident`
  # and `_unquote_ident` are gone rather than merely unused: `quote_ident` appears nowhere below,
  # because a JSON string is not a SQL identifier and needs no quoting to survive transport.
  #
  # Parameterized rather than interpolated into single-quoted literals, matching
  # `_pg_composite_indexes` above. Both are keyword arguments, so both are caller-supplied by
  # contract even though every call site today passes `schema = "public"` and no `table`.
  params = String[]
  schema === nothing || push!(params, schema)
  schema_clause = schema === nothing ? "" : "AND n.nspname = \$$(length(params))"
  table === nothing || push!(params, table)
  table_clause = table === nothing ? "" : "AND c.relname = \$$(length(params))"
  query = """
    WITH unique_constraints AS (
        SELECT
            con.conrelid AS table_oid,
            array_agg(a.attname) AS unique_cols
        FROM pg_constraint con
        JOIN pg_attribute a ON a.attrelid = con.conrelid AND a.attnum = ANY(con.conkey)
        WHERE con.contype = 'u'
          -- #318: the single-column test belongs HERE, per CONSTRAINT — not on the aggregate below.
          -- This CTE groups by TABLE, so it merged every unique constraint's columns into ONE array:
          -- a table with two SEPARATE single-column UNIQUEs produced {slug, uuid_token}, and the
          -- consumer's `array_length(...) = 1` guard then rejected BOTH. Every such column
          -- introspected as `unique=false`, never matched its own declaration, and makemigrations
          -- proposed the same alteration forever.
          --
          -- Multi-column constraints stay excluded on purpose: PormG models composite uniqueness as
          -- a model-level UniqueConstraint (#19), never as a per-field `unique`, so marking a member
          -- column would churn in the opposite direction. `CREATE UNIQUE INDEX` — how #19 is
          -- materialized — has no pg_constraint row at all and is excluded for free.
          --
          -- Grouping by `con.oid` instead would be wrong: the CTE must stay ONE ROW PER TABLE, or the
          -- LEFT JOIN below fans out and every table yields N duplicate models.
          AND array_length(con.conkey, 1) = 1
        GROUP BY con.conrelid
    ),
    foreign_keys AS (
        SELECT
            con.conrelid AS table_oid,
            -- #455: ONE OBJECT PER CONSTRAINT, replacing six `", "`-joined aggregates that the
            -- consumer zipped POSITIONALLY. Alignment used to be a property nothing enforced — it
            -- held only while every one of the six produced the same number of entries in the same
            -- order — and a parent table, child column or referenced column containing `, ` broke it
            -- silently, shifting every LATER foreign key onto a different parent. Now each fact
            -- travels attached to the constraint it belongs to, so there is no order to preserve.
            --
            -- `condeferrable` / `condeferred` are DROPPED, not converted: they were selected,
            -- transported and grouped by from #292 onward and read by nothing — `convertSQLToModel`
            -- never touched `row[:deferrable]`, and neither test helper built it.
            --
            -- #292: the referential action. Single-char codes: a=NO ACTION, r=RESTRICT, c=CASCADE,
            -- n=SET NULL, d=SET DEFAULT.
            json_agg(json_build_object(
                'column',    att2.attname,
                'table',     cf.relname,
                'pk',        pk_att.attname,
                'on_delete', con.confdeltype::text
            ) ORDER BY att2.attnum)::text AS foreign_keys
        FROM pg_constraint con
        JOIN pg_class cf ON cf.oid = con.confrelid
        JOIN pg_namespace nf ON nf.oid = cf.relnamespace
        -- #415: the child and parent columns are correlated THROUGH THE CONSTRAINT. Before this the
        -- referenced column came from the parent's PRIMARY KEY INDEX — `con.confkey`, the array that
        -- says which parent columns the FK actually references, was not selected anywhere in this
        -- file — and the two `pg_attribute` joins were uncorrelated, leaving the consumer's `zip` to
        -- pair them positionally by chance. Two distinct failures came out of that:
        --
        --   1. `REFERENCES parent(some_unique_col)` — legal wherever that column carries a UNIQUE
        --      constraint — reported the parent's PK instead. `pk_field` was then wrong, and so was
        --      every consumer of it: `Dialect.add_foreign_key`, `create_table`,
        --      `Models.fk_target_column`, the join builder's `key_b`. `makemigrations` proposed
        --      re-pointing a foreign key that was never mispointed, and the DDL it emitted named a
        --      different column than the live constraint does.
        --   2. `attnum = ANY(pk_idx.indkey)` yielded ONE ROW PER PARENT PK COLUMN, multiplying every
        --      aggregate here. A single-column FK to a composite-keyed parent bound to an arbitrary
        --      one of the parent's key columns (the last fanned-out row won the `fk_map[...]`
        --      assignment), and the same fan-out duplicated `deferrable` / `initially_deferred` /
        --      `delete_rules`, breaking the positional alignment #292 established.
        --
        -- A THIRD change falls out of dropping the `pg_index` join, and it is an improvement rather
        -- than a side effect worth hiding: that join was INNER, so a foreign key whose PARENT TABLE
        -- HAS NO PRIMARY KEY AT ALL matched nothing and vanished from this CTE entirely — the child
        -- column introspected as having no relation. That schema is legal (a referenced column only
        -- needs a UNIQUE constraint, not the key), and SQLite's `PRAGMA foreign_key_list` always
        -- reported it, so the two engines disagreed about it. They now agree.
        --
        -- `unnest` over the two arrays in lockstep, deliberately NOT `con.conkey[1]`. Subscripting
        -- would be shorter but would depend on the array's LOWER BOUND, which is exactly the
        -- assumption that produced #347's off-by-one in this same file (`int2vector` has lower bound
        -- 0 while `WITH ORDINALITY` counts from 1). `unnest` is bound-agnostic, so there is nothing
        -- to assert. No `WITH ORDINALITY` either: nothing is subscripted, and with the single-column
        -- filter below each constraint contributes exactly one row.
        JOIN LATERAL unnest(con.conkey, con.confkey) AS k(child_attnum, parent_attnum) ON true
        JOIN pg_attribute att2   ON att2.attrelid   = con.conrelid AND att2.attnum   = k.child_attnum
        JOIN pg_attribute pk_att ON pk_att.attrelid = cf.oid       AND pk_att.attnum = k.parent_attnum
        WHERE con.contype = 'f'
          -- A genuinely MULTI-COLUMN foreign key is skipped, not approximated — the same idiom
          -- `unique_constraints` and `non_negative_checks` use above, and the same
          -- reject-rather-than-reinterpret rule `_pg_composite_indexes` states in full. PormG has no
          -- composite-FK field type, so the alternatives are both wrong: pick one column and pretend
          -- (what the old query did), or emit N independent single-column relations that regenerate
          -- as N separate constraints the parent may not even accept. A skipped constraint reads as
          -- "no relation" on BOTH sides of the diff, so the schema still converges. The SQLite
          -- reader skips the same shape for the same reason — see `fk_map` in
          -- `convertSQLToModel(::PormGSQLite, …)`.
          AND array_length(con.conkey, 1) = 1
        GROUP BY con.conrelid
    ),
    -- Secondary indexes, filtered down to exactly what `field.db_index = true` emits: ONE
    -- `CREATE INDEX` over ONE column (`planner._add_constrains` → `Dialect.create_index`). #325
    -- made this feed `db_index` on read-back, which the three added predicates are what makes
    -- safe — without them a model declaring only `unique=true` (or a composite `UniqueConstraint`,
    -- #19) would read back as `db_index=true` and churn in the opposite direction:
    --   * NOT indisunique — a UNIQUE constraint's backing index is `field.unique`, already read
    --     from `pg_constraint` by the `unique_constraints` CTE above. Keeps the backends symmetric
    --     with SQLite's `il."unique" = 0` filter.
    --   * indpred IS NULL — a partial index constrains rows, not the column; PormG cannot declare
    --     one, so reading it would be permanent churn.
    --   * indnkeyatts = 1 — a composite index marks no single column, mirroring #318's
    --     `HAVING COUNT(*) = 1` for composite UNIQUE.
    -- An expression index joins no `pg_attribute` row (its `indkey` entry is 0) and so drops out
    -- on its own.
    indexes AS (
        -- #455: one object per (column, index name) pair. These two aggregates were the other
        -- positional zip, and they were the ASYMMETRIC one — `index_columns` was raw `attname`
        -- while `index_names` was `quote_ident`-ed, so the consumer de-quoted one side and not the
        -- other. JSON carries both raw, which is why that asymmetry (and the comment justifying it)
        -- is gone rather than restated.
        SELECT
            i.indrelid AS table_oid,
            json_agg(json_build_object('column', a.attname, 'name', c.relname)
                     ORDER BY a.attnum)::text AS indexes
        FROM pg_index i
        JOIN pg_class c ON c.oid = i.indexrelid
        JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = ANY(i.indkey)
        WHERE NOT i.indisprimary
          AND NOT i.indisunique
          AND i.indpred IS NULL
          AND i.indnkeyatts = 1
        GROUP BY i.indrelid
    ),
    non_negative_checks AS (
        SELECT
            con.conrelid AS table_oid,
            array_agg(a.attname) AS check_cols
        FROM pg_constraint con
        JOIN pg_attribute a ON a.attrelid = con.conrelid AND a.attnum = ANY(con.conkey)
        WHERE con.contype = 'c'
          AND array_length(con.conkey, 1) = 1
          -- #731: PormG's own clause, exactly, not any CHECK containing `>= 0`.
          AND $(_PG_NON_NEGATIVE_CHECK_MATCH)
        GROUP BY con.conrelid
    ),
    -- BinaryField byte bounds (#296). Unlike non_negative_checks this is per-COLUMN and carries a
    -- VALUE, because `max_length` is part of the field state the planner diffs — a boolean marker
    -- would leave every makemigrations proposing the same ALTER forever. `bytea` has no length
    -- parameter, so the CHECK is the only place the bound exists in the schema.
    byte_length_checks AS (
        SELECT
            con.conrelid AS table_oid,
            a.attname AS col_name,
            -- pg_get_constraintdef renders it as `CHECK ((octet_length(col) <= 4))`. Matching on
            -- digits after `<=` avoids backslash escapes surviving both Julia and SQL quoting.
            --
            -- `substring(… from …)` rather than `regexp_match`, kept as the equivalent that carries
            -- no version question at all. The 9.x rationale this comment used to give was already
            -- false when it was written: the `indexes` CTE above uses `indnkeyatts`, which is
            -- PostgreSQL 11+, and it sits in THIS SAME STATEMENT — the one every introspection runs.
            -- So 11 is the effective floor for this query and `regexp_match` (10+) would have been
            -- safe too. #415 leans on the same fact for multi-argument `unnest` in FROM (9.4+).
            --
            -- Scope of that claim, deliberately narrow: it is about THIS statement. It used to be
            -- the reason a `major_version >= 10` gate on an `identity_case` fragment could never
            -- take its `else` branch; #455 acted on that and removed the gate, the fragment and the
            -- `version()` probe that fed them, so the floor is now simply stated here.
            --
            -- min() collapses to ONE row per (table, column). This CTE is joined per-column, not
            -- per-table like non_negative_checks above, so without the GROUP BY two matching CHECKs
            -- on the same column (a hand-written extra bound, or a stale one) would fan the outer
            -- row out and emit that column twice into the columns aggregate — after which the recovered
            -- max_length would depend on row order, which is exactly the drift this CTE prevents.
            -- min() also picks the tightest bound, which is the one actually enforced.
            min(substring(pg_get_constraintdef(con.oid) from '<= ([0-9]+)')::bigint) AS byte_limit
        FROM pg_constraint con
        JOIN pg_attribute a ON a.attrelid = con.conrelid AND a.attnum = ANY(con.conkey)
        WHERE con.contype = 'c'
          AND array_length(con.conkey, 1) = 1
          AND pg_get_constraintdef(con.oid) LIKE '%octet_length%'
          AND pg_get_constraintdef(con.oid) ~ '<= [0-9]+'
        GROUP BY con.conrelid, a.attname
    )
    SELECT
        n.nspname AS table_schema,
        c.relname AS table_name,
        -- #455: one object per column. Every marker below used to be a SPACE-DELIMITED TOKEN that
        -- the consumer looked for with `occursin`, which meant the DEFAULT expression — arbitrary
        -- user text — sat in the same string being scanned. `note text DEFAULT 'NOT NULL'::text` on
        -- a NULLABLE column read back `null=false`; `DEFAULT 'a UNIQUE b'::text` fabricated a
        -- unique constraint (#318's move to a token test fixed only the single-word form). A field
        -- cannot be forged by its own neighbour's value, so that whole class is gone.
        json_agg(json_build_object(
            'name',    a.attname,
            'type',    format_type(a.atttypid, a.atttypmod),
            'notnull', a.attnotnull,
            'default', CASE WHEN ad.adbin IS NOT NULL
                            THEN pg_get_expr(ad.adbin, ad.adrelid) END,
            -- `attidentity` is the internal "char" type; cast so the JSON value is a predictable
            -- ""/"a"/"d" rather than whatever json_build_object makes of an unknown scalar. This
            -- replaces the version-gated GENE_*_IDENTITY marker fragment (see the note above the
            -- query for why the version probe went with it).
            'identity', a.attidentity::text,
            -- #318: plain membership. `unique_cols` already holds ONLY single-column constraints
            -- (filtered per-constraint in the CTE above), so the old `array_length(...) = 1` guard
            -- here was testing the wrong thing — the merged per-table array — and rejected every
            -- column on any table with more than one unique constraint. COALESCE because
            -- `unique_cols` is NULL when a table has none (LEFT JOIN), `x = ANY(NULL)` is NULL, and
            -- JSON null is not false.
            'unique',             COALESCE(a.attname = ANY(u.unique_cols), false),
            'non_negative_check', COALESCE(a.attname = ANY(nn.check_cols), false),
            'byte_limit',         bl.byte_limit
        ) ORDER BY a.attnum)::text AS columns,
        pk.primary_keys AS primary_keys,
        fk.foreign_keys AS foreign_keys,
        ix.indexes      AS indexes
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    JOIN pg_attribute a ON a.attrelid = c.oid
    LEFT JOIN pg_attrdef ad ON ad.adrelid = a.attrelid AND ad.adnum = a.attnum
    LEFT JOIN (
        SELECT i.indrelid, json_agg(a.attname ORDER BY a.attnum)::text AS primary_keys
        FROM pg_index i
        JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = ANY(i.indkey)
        WHERE i.indisprimary
        GROUP BY i.indrelid
    ) pk ON pk.indrelid = c.oid
    LEFT JOIN foreign_keys fk ON fk.table_oid = c.oid
    LEFT JOIN indexes ix ON ix.table_oid = c.oid
    LEFT JOIN unique_constraints u ON u.table_oid = c.oid
    LEFT JOIN non_negative_checks nn ON nn.table_oid = c.oid
    LEFT JOIN byte_length_checks bl ON bl.table_oid = c.oid AND bl.col_name = a.attname
    WHERE c.relkind = 'r'
      $(_PG_OWNABLE_TABLE_FILTER)
      $(schema_clause)
      $(table_clause)
      AND a.attnum > 0
      AND NOT a.attisdropped
    -- The `::text` on every json_agg above is MANDATORY, not defensive: these three columns sit in
    -- this GROUP BY, and PostgreSQL's `json` type has no equality operator — leaving any of them as
    -- `json` fails the whole statement with "could not identify an equality operator for type json".
    -- It also pins the Julia side to a String independently of LibPQ's user-extensible type map.
    GROUP BY n.nspname, c.relname, pk.primary_keys, fk.foreign_keys, ix.indexes,
             u.unique_cols, nn.check_cols
    ORDER BY table_schema, table_name;
    """

  df = DataFrame(fetch(db, query, params))
  # @pormg_debug false
  if nrow(df) == 0
      @warn("No tables found in the database.")
  end

  # println(df)

  return df
end

function get_database_schema(;pickup::Union{PormGSQLite, PormGPostgres} = connection())  
  return get_database_schema(pickup)
end

# #498: hardened to match `get_constraints_pk` / `get_constraints_unique` / `get_constraints_check`
# below, which were fixed and left this one behind. Four defects, all of which the caller acts on by
# DROPPING whatever name comes back:
#
#   * The `kcu` join matched on `constraint_name` ALONE. PostgreSQL scopes a constraint name to its
#     TABLE (`pg_constraint`'s unique index is `(conrelid, contypid, conname)`), not to the schema and
#     certainly not to the database — two tables may each carry `orders_fk`, in the same schema — so
#     joining on the name alone could return a name that belongs to a DIFFERENT table's constraint,
#     which the caller then drops off this one. Fixed by joining on `table_schema` AND `table_name`.
#     (The sibling `get_constraints_pk` / `get_constraints_unique` said "unique per SCHEMA" and
#     carried the same missing `table_name` predicate; #731's review gave both the join.)
#   * No `search_path` restriction, unlike `get_constraints_unique`. `current_schemas(false)` rather
#     than a literal `public` on purpose: the DDL this feeds (`ALTER TABLE "x" DROP CONSTRAINT`) is
#     emitted UNQUALIFIED and so resolves through the search path, and the lookup has to agree with
#     the statement it is arming.
#   * The `constraint_column_usage` join earned nothing — this function returns only
#     `constraint_name` — and fanned out one row per referenced column for a multi-column key.
#   * Unordered, then `result[1, …]`. With the filters above a second row is already pathological,
#     but "whichever PostgreSQL returned first" is not an answer.
#
# Parameterized, per this file's own rule: the unparameterized siblings predate it and are left
# alone, but an edited query does not inherit the exemption. That was cosmetic while this ran only
# for a `db_constraint` flip; #498 puts it on the ordinary re-point path.
function get_constraints_fk(conn::PormGPostgres, table_name::Symbol, field_name::String )
  query = """
  SELECT tc.constraint_name
  FROM information_schema.table_constraints AS tc
  JOIN information_schema.key_column_usage AS kcu
    ON tc.constraint_name = kcu.constraint_name
   AND tc.table_schema   = kcu.table_schema
   AND tc.table_name     = kcu.table_name
  WHERE tc.table_name = \$1
    AND tc.constraint_type = 'FOREIGN KEY'
    AND kcu.column_name = \$2
    AND tc.table_schema = ANY(current_schemas(false))
  ORDER BY tc.constraint_name, tc.table_schema;
  """
  result = fetch(conn, query, [string(table_name), field_name]) |> DataFrame
  if nrow(result) == 0
      return nothing
  end
  return result[1, :constraint_name]
end

"""
    get_constraints_index(conn, table_name::Symbol, field_name::String) -> Union{String,Nothing}

Name of a live index on `table_name` that covers `field_name` **and that PormG may drop**, or
`nothing`. Both backends answer the same question, and it is deliberately NARROWER than "an index
touching this column".

#515: the main caller is `planner._drop_index`, which exists to remove an index so a `RENAME COLUMN`
can re-create it under the new name, or — on SQLite, which refuses `DROP COLUMN` on an indexed
column — so a deletion is not refused. (PostgreSQL never refuses a `DROP COLUMN` over an index; it
drops the index with the column. The second errand is SQLite's alone.) An index that *backs a
constraint* serves neither errand and cannot survive the attempt:

  * PostgreSQL implements a `UNIQUE` constraint AS an index of the same name and refuses to drop
    that index while the constraint owns it. `_drop_index` used to work around that by emitting
    `ALTER TABLE … DROP CONSTRAINT IF EXISTS` first — which succeeded, and silently destroyed the
    constraint. Nothing re-added it: `_add_constrains` has no `unique` half, and `alter_field`'s
    `:unique` branch is unreachable from the rename path.
  * SQLite names the same thing `sqlite_autoindex_<table>_<n>` and refuses outright — *"index
    associated with UNIQUE or PRIMARY KEY constraint cannot be dropped"* — so the migration aborts
    and rolls back.

Same input, opposite failures, neither of them right. Filtering HERE rather than at `_drop_index`'s
call sites is what makes it safe by construction for all of them, and it settles the third half of
#515 in the same move: the PostgreSQL query below matches on real column MEMBERSHIP instead of
`indexdef LIKE '%<field_name>%'`, which was unanchored (a short name matched a neighbouring index's
definition text), unparameterized, and unordered under a `result[1, …]`.

THE FOURTH CALLER is not a drop at all, and the narrowing changed it — deliberately, and for the
better. `_alter_table_fields`' `index_actions` `:create` flush probes this function to avoid queuing
a `CREATE INDEX` beside one a SQLite rebuild is about to re-create (the random name suffix defeats
`IF NOT EXISTS`). It is asking "does a plain index already cover this column?", which is what this
function now answers and is not what it answered before: a column carrying only a UNIQUE index and
newly declared `db_index = true` used to see that index, skip the CREATE, and be re-proposed on
every `makemigrations` forever, because the rebuild renders `UNIQUE` inline rather than as the
separate index `db_index` means. It now gets its plain index once and converges.

NOT narrowed to single-column, non-partial indexes, unlike the `db_index` reader
[`_sqlite_single_column_indexed_columns`](@ref) whose filter this otherwise mirrors. That reader
answers *"is this column `db_index = true`?"*; this one answers *"may PormG drop this index?"*, and a
composite index is both droppable and worth finding. Do not collapse the two.

#519: THIS FUNCTION IS NOT A DELETION-BLOCKING CHECK, and an earlier version of this docstring said it
was — *"SQLite refuses `DROP COLUMN` on ANY indexed column, so the planner's field-deletion loop needs
those found."* It cannot answer that question, for two reasons that are both structural rather than
fixable here: the SQLite query below matches on `pragma_index_info.name`, which is `NULL` for an
EXPRESSION member and never lists a PARTIAL index's `WHERE` columns; and it returns a single name, so a
column with two eligible indexes reports one. Use
[`_sqlite_indexes_referencing_column`](@ref) for "would SQLite refuse to drop this column?" — it reads
the index DDL as well as the pragma members and returns every hit. The field-deletion loop routes
through the table rebuild on that answer and no longer pre-drops anything on SQLite.
"""
function get_constraints_index(conn::PormGPostgres, table_name::Symbol, field_name::String)
  # Parameterized, per this file's own rule (see `get_constraints_fk` above): the unparameterized
  # siblings predate it and are left alone, but an EDITED query does not inherit the exemption.
  #
  # `NOT indisunique` / `NOT indisprimary` is the constraint-backing index in its two ordinary
  # shapes. The `pg_constraint` probe closes the residual one they miss — an EXCLUDE constraint owns
  # an index that is not unique — so what comes back is provably owned by no constraint, which is
  # what lets `_drop_index` emit a bare `DROP INDEX` with no `DROP CONSTRAINT` ahead of it.
  #
  # `indkey` covers INCLUDE columns as well as key columns, on purpose: an INCLUDE column is as much a
  # reason to re-create the index under a new name after a `RENAME COLUMN` as a key column is, and this
  # lookup arms that. (#519: it is NOT arming a deletion — PostgreSQL drops an index with the column it
  # covers and never refuses the `DROP COLUMN`, as the docstring above says. An earlier version of this
  # comment claimed the lookup existed "to find what stands in the way", which contradicted it.)
  # Scoped through `current_schemas(false)` for `get_constraints_fk`'s reason — the DDL this arms is
  # emitted UNQUALIFIED and so resolves through the search path, and the lookup has to agree with the
  # statement it is arming. Ordered, because "whichever PostgreSQL returned first" is not an answer.
  query = """
  SELECT ic.relname AS indexname
  FROM pg_index i
  JOIN pg_class ic    ON ic.oid = i.indexrelid
  JOIN pg_class tc    ON tc.oid = i.indrelid
  JOIN pg_namespace n ON n.oid  = tc.relnamespace
  JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = ANY(i.indkey::int2[])
  WHERE tc.relname = \$1
    AND a.attname  = \$2
    AND NOT i.indisunique
    AND NOT i.indisprimary
    AND NOT EXISTS (SELECT 1 FROM pg_constraint con WHERE con.conindid = ic.oid)
    AND n.nspname = ANY(current_schemas(false))
  ORDER BY ic.relname;
  """
  result = fetch(conn, query, [string(table_name), field_name]) |> DataFrame
  if nrow(result) == 0
      return nothing
  end
  return result[1, :indexname]
end

function get_constraints_index(conn::PormGSQLite, table_name::Symbol, field_name::String)
  # The SQLite half of #515. `il.origin = 'c'` is the `sqlite_autoindex_…` skip: an auto-index
  # created by a `UNIQUE` or `PRIMARY KEY` clause carries origin `'u'` or `'pk'`, never `'c'`.
  # `il."unique" = 0` excludes the case origin alone would let through — a `CREATE UNIQUE INDEX`,
  # which IS origin `'c'` and yet is the same hazard: dropping it destroys uniqueness on a column
  # that never set `field.unique`. That second filter is also why a declared-side guard at the call
  # site would not have been enough.
  #
  # One parameterized query, in the shape `_sqlite_single_column_indexed_columns` established — the
  # `pragma_index_list(?)` / `pragma_index_info(…)` table-valued join, rather than a `fetch` per
  # index in a Julia loop. Ordered so a table carrying two eligible indexes on one column answers
  # the same way twice.
  rows = fetch(conn, """
    SELECT il.name AS idx
    FROM pragma_index_list(?) AS il
    JOIN pragma_index_info(il.name) AS ii
    WHERE il."unique" = 0 AND il.origin = 'c' AND ii.name = ?
    ORDER BY il.name
    """, [string(table_name), field_name]) |> DataFrame
  # An empty frame's columns are eltype Missing, so guard before touching them.
  nrow(rows) == 0 && return nothing
  rows[1, :idx] === missing && return nothing
  return string(rows[1, :idx])
end

# #151: probe the live schema for a UNIQUE index of ANY arity covering `field_name`. That covers the
# column-level UNIQUE auto-index (`sqlite_autoindex_…`, which `DROP INDEX` can't remove), a table-level
# `UNIQUE (a, b)`, and any `CREATE UNIQUE INDEX`. Such a column is refused by `ALTER TABLE DROP COLUMN`,
# so its deletion must route through a table rebuild (same remedy #116 uses for FK columns).
#
# STILL REQUIRED after #318 gave introspection a `unique` flag, and deliberately BROADER than it: this
# answers "would SQLite refuse to drop this column?", which is true for a composite-unique member and
# for a `CREATE UNIQUE INDEX` column — neither of which sets `field.unique`. Do not collapse the two.
function _sqlite_column_is_unique(conn::PormGSQLite, table_name, field_name::String)::Bool
  idx_list = fetch(conn, "PRAGMA index_list(\"$(string(table_name))\")") |> DataFrame
  isempty(idx_list) && return false
  for row in eachrow(idx_list)
    row.unique == 1 || continue
    idx_info = fetch(conn, "PRAGMA index_info(\"$(row.name)\")") |> DataFrame
    (!isempty(idx_info) && field_name in idx_info.name) && return true
  end
  return false
end

"""
    _sqlite_single_column_unique_columns(conn::PormGSQLite, table_name) -> Set{String}

Physical columns of `table_name` carrying a SINGLE-column `UNIQUE` **constraint** — exactly the set for
which `field.unique` must introspect back as `true` (#318).

`PRAGMA table_info` has no uniqueness column at all, so `convertSQLToModel(::PormGSQLite)` never
populated `unique`: every `unique=true` field compared unequal to its own live table and
`makemigrations` proposed the same rebuild forever.

Deliberately NARROWER than [`_sqlite_column_is_unique`](@ref) above, which answers the different
question `ALTER TABLE DROP COLUMN` asks. Two filters make the difference, and both are load-bearing:

  * `origin = 'u'` keeps only the auto-index SQLite creates for a `UNIQUE` clause inside
    `CREATE TABLE` — the one and only thing `field.unique` emits (`Dialect.field_to_column`). It
    excludes `origin = 'c'` (`CREATE UNIQUE INDEX`), which is how a model-level `UniqueConstraint`
    (#19) is materialized, and `origin = 'pk'` (a primary key is already an IDField). Arity alone is
    NOT enough here: a `UniqueConstraint` may name a single field, and marking that column would
    churn in the opposite direction. This also keeps the backends symmetric — PostgreSQL reads
    `pg_constraint` (`contype='u'`), which likewise cannot see a bare `CREATE UNIQUE INDEX`.
  * `HAVING COUNT(*) = 1` drops a table-level `UNIQUE (a, b)`, whose origin is also `'u'`.

`partial = 0` is belt-and-braces rather than load-bearing: SQLite only produces a partial index via
`CREATE INDEX … WHERE`, which is always `origin = 'c'` and therefore already excluded. Kept so the
predicate stays correct if that ever changes.

A bare `CREATE UNIQUE INDEX` stays `unique = false` HERE, on purpose: reading it as the field's
`unique` would be permanent churn for a single-field `UniqueConstraint` — the exact bug class #318
fixes. Since #161 it is not lost either: [`_sqlite_composite_indexes`](@ref) reads it, at any arity,
as the model-level `UniqueConstraint` it is.

ONE query per table (the table-valued-pragma idiom `get_secondary_index_ddls` also uses), not one probe
per column: callers test membership. An unknown table yields an empty set rather than throwing.
"""
function _sqlite_single_column_unique_columns(conn::PormGSQLite, table_name)::Set{String}
  rows = fetch(conn, """
    SELECT ii.name AS col
    FROM pragma_index_list(?) AS il
    JOIN pragma_index_info(il.name) AS ii
    WHERE il."unique" = 1 AND il.origin = 'u' AND il.partial = 0
    GROUP BY il.name
    HAVING COUNT(*) = 1
    """, [string(table_name)]) |> DataFrame
  # An empty frame's column is eltype Missing, so guard before touching `rows.col`.
  nrow(rows) == 0 && return Set{String}()
  return Set{String}(string(c) for c in rows.col if c !== missing)
end

"""
    _sqlite_canonical_table_name(conn::PormGSQLite, name) -> String

The `sqlite_master` spelling of table `name`, or `name` unchanged when nothing matches (#390).

`PRAGMA foreign_key_list` reports a foreign key's parent table **as spelled in the `REFERENCES`
clause**, not as `CREATE TABLE` spelled it. SQLite identifiers are case-insensitive, so

    CREATE TABLE driver (id INTEGER PRIMARY KEY);
    CREATE TABLE pit_stop (…, driver_id INTEGER REFERENCES DRIVER(id));

is legal and introspects as `DRIVER` against a table the catalog calls `driver`. Resolving that back
here is what lets the live-vs-declared foreign-key comparison be EXACT on both engines: the
PostgreSQL reader has always returned the catalog spelling (`cf.relname` in `get_database_schema`),
so this reader was the one producer of a non-canonical name. Before #390, the planner's same-parent
comparison absorbed the difference by folding case unconditionally — which was safe here and wrong on
PostgreSQL, where `Driver` and `driver` can be two distinct tables.

The fold happens **in SQL** (`COLLATE NOCASE`), deliberately not in Julia. Julia's `lowercase` is
Unicode-aware while SQLite's built-in identifier matching is ASCII-only, so folding here could
canonicalize to a table SQLite would not consider the same one. Letting the engine answer keeps the
two in step by construction.

Returns `name` unchanged when the lookup finds nothing — a view, a temp table, or a table in an
ATTACHed database, none of which the main schema's `sqlite_master` lists. That is exactly the
pre-#390 value, so a parent this cannot resolve is no worse off than before.

ONE query per DISTINCT parent table per introspected table (callers memoize), not one per column —
the same discipline as `_sqlite_single_column_unique_columns` above.
"""
function _sqlite_canonical_table_name(conn::PormGSQLite, name)::String
  rows = fetch(conn, "SELECT name FROM sqlite_master WHERE type = 'table' AND name = ? COLLATE NOCASE",
               [string(name)]) |> DataFrame
  nrow(rows) == 0 && return string(name)
  return string(rows[1, :name])
end

"""
    _sqlite_single_column_indexed_columns(conn::PormGSQLite, table_name) -> Dict{String, String}

Physical column ⇒ index name, for every SINGLE-column non-unique secondary index on `table_name` —
exactly the set for which `field.db_index` must introspect back as `true` (#325).

The `unique` sibling above and this one are the same shape for the same reason: `PRAGMA table_info`
carries neither attribute, so `convertSQLToModel(::PormGSQLite)` never populated `db_index` at all.
Every `db_index=true` field therefore compared unequal to its own live table, and — because
`Dialect.alter_field` has no `db_index` branch — `makemigrations` proposed a rebuild that emitted no
DDL for it, forever. `src/migrations/planner.jl` carried a workaround for one symptom of this
(a duplicated `CREATE INDEX`); the cause is here.

The three filters mirror the `unique` reader's, each excluding an index that is NOT `db_index`:

  * `il."unique" = 0` — a UNIQUE index is `field.unique`, read by
    [`_sqlite_single_column_unique_columns`](@ref). Marking it here would make a model declaring
    only `unique=true` churn in the opposite direction. Symmetric with PostgreSQL's
    `NOT i.indisunique`.
  * `il.origin = 'c'` — only a `CREATE INDEX`, which is the one and only thing `db_index=true`
    emits (`planner._add_constrains` → `Dialect.create_index`). Excludes `'u'` (a `UNIQUE` clause's
    auto-index) and `'pk'`.
  * `HAVING COUNT(*) = 1` — a composite index marks no single column, exactly as for composite
    UNIQUE (#318). PormG only ever indexes one column per `db_index`.

`il.partial = 0` IS load-bearing here, unlike in the `unique` reader: a partial index is created by
`CREATE INDEX … WHERE` and so shares this reader's `origin = 'c'`. It constrains rows rather than
the column, PormG cannot declare one, and reading it would be permanent churn.

Returns the index NAME as well as the column because the planner needs it to drop an index the model
no longer declares (`model.cache["index"]`); the PostgreSQL path builds the same mapping from its
`indexes` CTE. ONE query per table; an unknown table yields an empty dict rather than throwing.
"""
function _sqlite_single_column_indexed_columns(conn::PormGSQLite, table_name)::Dict{String, String}
  rows = fetch(conn, """
    SELECT MIN(ii.name) AS col, il.name AS idx
    FROM pragma_index_list(?) AS il
    JOIN pragma_index_info(il.name) AS ii
    WHERE il."unique" = 0 AND il.origin = 'c' AND il.partial = 0
    GROUP BY il.name
    HAVING COUNT(*) = 1
    """, [string(table_name)]) |> DataFrame
  # An empty frame's columns are eltype Missing, so guard before touching them.
  nrow(rows) == 0 && return Dict{String, String}()
  out = Dict{String, String}()
  for r in eachrow(rows)
    (r.col === missing || r.idx === missing) && continue
    # First index wins if two single-column indexes cover the same column — the duplicate is
    # redundant, and `db_index` is a boolean either way.
    get!(out, string(r.col), string(r.idx))
  end
  return out
end

"""
    _attach_composite_indexes!(model, composites::Vector{LiveComposite}) -> model

Stash introspected model-level indexes on `model` under the cache keys the declarations write —
`Models._apply_unique_constraints!`'s `"unique_constraints"` for a unique one (#161) and
`Models._apply_indexes!`'s `"composite_indexes"` for the rest (#347) — so `Model_to_str` re-emits
them as `constraints = [Models.UniqueConstraint(…)]` / `indexes = [Models.Index(…)]`.

Since #161 this is load-bearing, not cosmetic. `makemigrations` now DROPS a readable composite the
models file does not declare, so an `inspectdb` that lost one would hand the developer a models file
whose first migration deletes a live constraint. Reading composite uniqueness back is what makes
adopting a schema a no-op.

Shared by both backend readers, which is the whole point: the SQLite and PostgreSQL sides produce the
same [`LiveComposite`](@ref) shape and hand it here.

Deliberately NOT routed through `Models._apply_indexes!` / `_apply_unique_constraints!`. Those are
the *declaration* guards and raise `ModelDefinitionError` on anything they cannot accept — which on
this path would abort the introspection of an entire table over one odd index. Introspection is
best-effort by convention (`convertSQLToModel` degrades a field it cannot read rather than
throwing), so an index this model cannot express is skipped with a `@debug` and the rest of the
table still comes back. Two ways that happens, both real:

  * a column the field reader did not produce (it degraded, or the index covers a dropped column);
  * a column name `format_fild_name` rejects — `a__b` (the lookup separator) or one containing `@`.
    A live PostgreSQL schema can legally have either.

One name is dropped rather than kept: SQLite calls a table-level `UNIQUE (a, b)`'s index
`sqlite_autoindex_<table>_<n>` and reserves the `sqlite_` prefix, so written into a models file it
would later be re-created as `CREATE UNIQUE INDEX "sqlite_autoindex_…"`, which SQLite refuses. The
declaration gets `name = nothing` instead — PormG derives one, and a derived name accepts whatever
the live index is called, so the adopted constraint still matches.

A cache key is written only when at least one index of its kind survives, so a table with none is
byte-identical to before this existed.
"""
function _attach_composite_indexes!(model, composites::Vector{LiveComposite})
  isempty(composites) && return model
  kept_uc = Models.UniqueConstraint[]
  kept_ix = Models.Index[]
  for lc in composites
    if !all(c -> haskey(model.fields, c), lc.columns)
      @debug "introspection: composite index skipped — column not on the introspected model" table=model.name index=lc.name columns=lc.columns
      continue
    end
    name = startswith(lc.name, "sqlite_autoindex_") ? nothing : lc.name
    decl = try
      lc.unique ? Models.UniqueConstraint(fields = lc.columns, name = name) :
                  Models.Index(fields = lc.columns, name = name)
    catch e
      e isa ModelDefinitionError || rethrow()
      @debug "introspection: composite index skipped — PormG cannot name it" table=model.name index=lc.name columns=lc.columns exception=e
      continue
    end
    decl isa Models.Index ? push!(kept_ix, decl) : push!(kept_uc, decl)
  end
  isempty(kept_uc) || (model.cache["unique_constraints"] = Dict{String, Any}("constraints" => kept_uc))
  isempty(kept_ix) || (model.cache["composite_indexes"] = Dict{String, Any}("indexes" => kept_ix))
  return model
end

"""
    _sqlite_composite_indexes(conn::PormGSQLite, table_name) -> Vector{LiveComposite}

Every model-level index on `table_name` that PormG can re-emit, as [`LiveComposite`](@ref)s: what a
`Models.Index` (#347) or a `Models.UniqueConstraint` (#19, #161) materializes, plus the table-level
`UNIQUE (a, b)` a schema adopted from Django carries.

Three shapes, partitioned against the column readers so no index has two owners:

| `origin` | `unique` | arity | reads as | the other arity belongs to |
|---|---|---|---|---|
| `'c'` (`CREATE INDEX`) | 0 | > 1 | `Index` | [`_sqlite_single_column_indexed_columns`](@ref) — `db_index` |
| `'c'` (`CREATE UNIQUE INDEX`) | 1 | ≥ 1 | `UniqueConstraint` | nobody: a one-column bare unique index is what a one-field `UniqueConstraint` creates |
| `'u'` (a `UNIQUE` clause) | 1 | > 1 | `UniqueConstraint`, `constraint = true` | [`_sqlite_single_column_unique_columns`](@ref) — the field's `unique` |

`origin = 'pk'` (the primary key's own index) is never read. `il.partial = 0` keeps a
`CREATE INDEX … WHERE` out, which PormG cannot declare (#29).

Before #161 the reader carried `il."unique" = 0` and `origin = 'c'` and nothing else, so no
composite uniqueness came back at all — neither PormG's own `CREATE UNIQUE INDEX` nor Django's
`unique_together`. Harmless while nothing diffed composites; with a diff it would have made every
declared `UniqueConstraint` look missing on every run.

Three things this reader needs that the single-column ones do not:

  * **Column ORDER is part of the index.** An index over `(raceid, lap)` is not the index over
    `(lap, raceid)`, so the columns come back ordered by `seqno` rather than aggregated.
    `MIN(ii.name)` was fine for arity 1; here it would silently reorder the declaration.
  * **`pragma_index_xinfo`, not `index_info`.** `xinfo` carries three columns `info` does not, and
    each gates an index PormG cannot reproduce. `key = 1` drops the rowid/PK columns SQLite appends
    to every index — they are not part of the declaration.
  * **Anything PormG cannot re-emit is dropped WHOLE, never partially.** Emitting a subset, or the
    same columns under different semantics, would declare a *different* index under the developer's
    name — the same reject-rather-than-reinterpret rule the Django importer applies to
    `Meta.indexes`. Three shapes qualify:
      - an **expression** member (`lower(name)`) has a NULL `ii.name` — functional indexes are #29;
      - a **descending** member (`"desc" = 1`) — PormG indexes carry no per-column order, and the
        importer already *refuses* Django's `Index(fields=["-year"])` for exactly this reason;
      - a non-**BINARY** collation (`COLLATE NOCASE`) — a different comparison, so a different index.

ONE query per table; an unknown table yields an empty vector rather than throwing.
"""
function _sqlite_composite_indexes(conn::PormGSQLite, table_name)::Vector{LiveComposite}
  rows = fetch(conn, """
    SELECT il.name AS idx, il."unique" AS is_unique, il.origin AS origin,
           ii.name AS col, ii."desc" AS is_desc, ii.coll AS coll
    FROM pragma_index_list(?) AS il
    JOIN pragma_index_xinfo(il.name) AS ii
    WHERE il.partial = 0 AND ii."key" = 1
      AND (il.origin = 'c' OR (il.origin = 'u' AND il."unique" = 1))
    ORDER BY il.name, ii.seqno
    """, [string(table_name)]) |> DataFrame
  # An empty frame's columns are eltype Missing, so guard before touching them.
  nrow(rows) == 0 && return LiveComposite[]
  # `nothing` marks a member PormG cannot express; the whole index is then skipped below.
  grouped = OrderedDict{String, Vector{Union{String, Nothing}}}()
  kind = Dict{String, Tuple{Bool, Bool}}()      # index ⇒ (unique, constraint-backed)
  for r in eachrow(rows)
    r.idx === missing && continue
    idx = string(r.idx)
    kind[idx] = (r.is_unique !== missing && r.is_unique != 0, r.origin !== missing && r.origin == "u")
    unusable = r.col === missing ||                                    # expression member
               (r.is_desc !== missing && r.is_desc != 0) ||            # DESC member
               (r.coll !== missing && uppercase(string(r.coll)) != "BINARY")   # non-default collation
    push!(get!(grouped, idx, Union{String, Nothing}[]), unusable ? nothing : string(r.col))
  end
  out = LiveComposite[]
  for (idx, cols) in grouped
    unique, constraint = kind[idx]
    # Arity partition (see the table above): only a BARE unique index may have one column.
    length(cols) > 1 || (unique && !constraint) || continue
    any(c -> c === nothing, cols) && continue    # a member PormG cannot re-emit ⇒ drop it whole
    push!(out, LiveComposite(idx, String[String(c) for c in cols], unique, constraint))
  end
  return out
end

# ── SQLite index reference analysis (#519) ───────────────────────────────────────────────────────
#
# `pragma_index_info` is blind in two places, and both of them make SQLite refuse a `DROP COLUMN`
# that PormG planned as if the column were free:
#
#   * an EXPRESSION member reports `name = NULL` — `CREATE INDEX ix ON t(lower("a"))` lists one
#     member with no name, because an expression has no column name to give;
#   * a PARTIAL index's `WHERE` columns are not members at all — `CREATE INDEX ix ON t(a) WHERE b > 0`
#     reports only `a`, yet dropping `b` breaks the index just as badly.
#
# So the index's own DDL text from `sqlite_master` is the only place the reference is recorded. The
# #515 rule applies to reading it: no unanchored substring, no `LIKE '%<column>%'` — a short column
# name matches a neighbouring identifier, a function name, or the contents of a string literal. What
# follows is an identifier-aware read instead, and the answer is still grounded in the CATALOG: the
# DDL only supplies candidate tokens, and a token counts as a column reference only if
# `pragma_table_info` says the table really has a column by that name.

"""
    _SQLiteIdentifierToken

One identifier token of a SQLite statement as [`_sqlite_identifier_tokens`](@ref) reports it: its
`name` (quotes and brackets stripped, doubled quotes collapsed), whether it is `called` (followed by
`(`), whether it was `quoted`, and its BYTE span `start:stop` in the scanned string. A NAMED tuple
rather than a positional one since #532: two call sites used to destructure `(tok, called, quoted)`
positionally, so adding a field in the middle would have silently shifted their meaning.
"""
const _SQLiteIdentifierToken = @NamedTuple{name::String, called::Bool, quoted::Bool, start::Int, stop::Int}

"""
    _sqlite_identifier_tokens(sql) -> Vector{_SQLiteIdentifierToken}

Every identifier in `sql` as a named tuple `(name, called, quoted, start, stop)` — `called` is whether
the next non-space character is `(`, `quoted` whether the identifier was written in one of SQLite's
three quoting forms, and `start:stop` the token's BYTE span in `sql`: `sql[start:stop]` is the token
exactly as written, quotes or brackets included, so a caller can rewrite it in place. Punctuation is
not returned at all; the only punctuation this needs to report is that one `(`, and it travels with
the identifier before it.

The span is what #532 added. The #150 rename rewrite substituted the quoted `"old"` token as a string
and so could not see a column spelled bare inside an expression (`lower(a)`), while an unanchored
substring replace is exactly what #515 removed — it also rewrites an index name, a string literal or a
longer identifier that merely contains the column. A span lets [`_sqlite_rewrite_index_columns`](@ref)
splice precisely the token, whatever its spelling. [`_sqlite_index_argument_start`](@ref) still does
its own scan rather than reading this list, because it needs the position of a PARENTHESIS, which is
not a token here.

`quoted` is what lets a caller tell a COLUMN from SQL SYNTAX. `DESC`, `COLLATE`, `WHERE`, `AND` and
friends are bare words in the same position a column name occupies, and a legacy table really can have
a column named `desc` — so neither the word nor the position settles it, but the quoting does: a column
whose name is a reserved word can only be referenced quoted, while the syntax is never quoted. Dropping
this flag silently destroyed an index on an unrelated surviving column (see
[`_SQLITE_INDEX_SYNTAX_WORDS`](@ref)).

A tokenizer rather than a regex because the things that must NOT be mistaken for an identifier are
exactly the things a regex over raw text cannot exclude: `'…'` string literals (with `''` escapes),
`x'…'` blobs, `--` line comments and `/* … */` block comments. SQLite's three quoted-identifier
spellings are all recognised (`"…"` with `""` escapes, `[…]`, `` `…` `` with ``` `` ``` escapes), so a
column named `select` or `index` reads correctly, and bare identifiers use SQLite's own character
class (a leading letter or `_`, then letters, digits, `_` or \$).

Julia's `isletter` is Unicode-aware where SQLite's bare-identifier class is ASCII, so this accepts a
few spellings SQLite would reject in unquoted form. That is the harmless direction: a name that cannot
appear in real DDL simply never matches a real column.

The `(`-follows flag is what separates `lower` the function from `lower` the column in
`lower("a")` — without it, an index expression's function names would be indistinguishable from
column references, and a table with a column named after a function it uses would route every
deletion through a table rebuild.
"""
function _sqlite_identifier_tokens(sql::AbstractString)::Vector{_SQLiteIdentifierToken}
  cs = collect(sql)
  # Character position ⇒ byte index, so the spans reported below index `sql` itself. Scanning over
  # `collect(sql)` is what keeps the branches below simple, but a span in character positions would
  # put every token after a multi-byte identifier (`"país"`) off by one byte per non-ASCII character.
  idx = collect(eachindex(sql))
  n = length(cs)
  out = _SQLiteIdentifierToken[]
  i = 1
  # Position of the next non-space character at or after `j`, or 0 when there is none.
  next_visible = function (j::Int)
    while j <= n && isspace(cs[j])
      j += 1
    end
    return j <= n ? j : 0
  end
  # Byte span of the token that began at character `from` and ended at character `i - 1` — clamped,
  # because an unterminated quote or bracket runs to the end of the input, like SQLite reads it.
  span = function (from::Int)
    return (idx[from], idx[min(i - 1, n)])
  end
  while i <= n
    c = cs[i]
    if isspace(c)
      i += 1
    elseif c == '-' && i < n && cs[i + 1] == '-'
      # Line comment: to end of line.
      while i <= n && cs[i] != '\n'
        i += 1
      end
    elseif c == '/' && i < n && cs[i + 1] == '*'
      # Block comment. An unterminated one runs to the end, which is what SQLite does too.
      i += 2
      while i < n && !(cs[i] == '*' && cs[i + 1] == '/')
        i += 1
      end
      i = min(i + 2, n + 1)
    elseif c == '\''
      # String literal. `''` is an escaped quote, so a doubled quote does not end it.
      i += 1
      while i <= n
        if cs[i] == '\'' && i < n && cs[i + 1] == '\''
          i += 2
        elseif cs[i] == '\''
          i += 1
          break
        else
          i += 1
        end
      end
    elseif (c == 'x' || c == 'X') && i < n && cs[i + 1] == '\''
      # Blob literal `x'ABCD'` — skipped as a literal, NOT read as the identifier `x`.
      i += 2
      while i <= n && cs[i] != '\''
        i += 1
      end
      i += 1
    elseif c == '"' || c == '`'
      # Quoted identifier; the quote character doubles to escape itself.
      from = i
      q = c
      i += 1
      buf = Char[]
      while i <= n
        if cs[i] == q && i < n && cs[i + 1] == q
          push!(buf, q)
          i += 2
        elseif cs[i] == q
          i += 1
          break
        else
          push!(buf, cs[i])
          i += 1
        end
      end
      nx = next_visible(i)
      a, b = span(from)
      push!(out, (name = String(buf), called = nx != 0 && cs[nx] == '(', quoted = true, start = a, stop = b))
    elseif c == '['
      # Bracketed identifier — no escape form in SQLite; the first `]` ends it.
      from = i
      i += 1
      buf = Char[]
      while i <= n && cs[i] != ']'
        push!(buf, cs[i])
        i += 1
      end
      i += 1
      nx = next_visible(i)
      a, b = span(from)
      push!(out, (name = String(buf), called = nx != 0 && cs[nx] == '(', quoted = true, start = a, stop = b))
    elseif isdigit(c)
      # Numeric literal — consumed so that `1e5` or `0x1f` cannot leave an identifier fragment.
      while i <= n && (isdigit(cs[i]) || cs[i] == '.' || cs[i] == 'x' || cs[i] == 'X' ||
                       (cs[i] in ('e', 'E')) || isletter(cs[i]))
        i += 1
      end
    elseif isletter(c) || c == '_'
      from = i
      buf = Char[]
      while i <= n && (isletter(cs[i]) || isdigit(cs[i]) || cs[i] == '_' || cs[i] == '$')
        push!(buf, cs[i])
        i += 1
      end
      nx = next_visible(i)
      a, b = span(from)
      push!(out, (name = String(buf), called = nx != 0 && cs[nx] == '(', quoted = false, start = a, stop = b))
    else
      i += 1
    end
  end
  return out
end

"""
    _sqlite_index_argument_start(sql) -> Int

The BYTE index in `sql` of the first top-level `(` — where the part of a `CREATE INDEX` statement that
can reference a column begins: the indexed-column list plus any `WHERE` clause.

`CREATE [UNIQUE] INDEX [IF NOT EXISTS] [schema.]name ON table (…) [WHERE …]` has no parenthesis
before the column list, so that one boundary excludes the index name and the table name
STRUCTURALLY rather than by guessing — which matters because either of them may legitimately equal a
column name. The scan skips literals and comments the same way [`_sqlite_identifier_tokens`](@ref)
does, so a `(` inside a quoted index name cannot be mistaken for the list's opening paren.

Returns `1` when there is no `(` at all — the whole statement is then the region — which cannot
happen for real `CREATE INDEX` DDL but keeps a malformed or truncated `sqlite_master.sql`
conservative rather than blind.

A byte index rather than the region text (#532), so a caller holding the tokens of the WHOLE
statement can tell which of them lie in the region by comparing `token.start` against it — that is how
[`_sqlite_rewrite_index_columns`](@ref) rewrites a renamed column in place without offset arithmetic.
"""
function _sqlite_index_argument_start(sql::AbstractString)::Int
  cs = collect(sql)
  idx = collect(eachindex(sql))
  n = length(cs)
  i = 1
  while i <= n
    c = cs[i]
    if c == '-' && i < n && cs[i + 1] == '-'
      while i <= n && cs[i] != '\n'
        i += 1
      end
    elseif c == '/' && i < n && cs[i + 1] == '*'
      i += 2
      while i < n && !(cs[i] == '*' && cs[i + 1] == '/')
        i += 1
      end
      i = min(i + 2, n + 1)
    elseif c == '\''
      i += 1
      while i <= n
        if cs[i] == '\'' && i < n && cs[i + 1] == '\''
          i += 2
        elseif cs[i] == '\''
          i += 1
          break
        else
          i += 1
        end
      end
    elseif c == '"' || c == '`'
      q = c
      i += 1
      while i <= n
        if cs[i] == q && i < n && cs[i + 1] == q
          i += 2
        elseif cs[i] == q
          i += 1
          break
        else
          i += 1
        end
      end
    elseif c == '['
      i += 1
      while i <= n && cs[i] != ']'
        i += 1
      end
      i += 1
    elseif c == '('
      return idx[i]
    else
      i += 1
    end
  end
  return 1
end

"""
    _sqlite_index_argument_region(sql) -> String

`sql` from [`_sqlite_index_argument_start`](@ref) onwards — the part of a `CREATE INDEX` statement that
can reference a column. Kept as the convenient form for callers that only classify tokens
([`_sqlite_index_is_unmodellable`](@ref), [`_sqlite_index_referenced_columns`](@ref)) and never need
to know where in the statement they sat.
"""
_sqlite_index_argument_region(sql::AbstractString)::String =
  String(SubString(sql, _sqlite_index_argument_start(sql)))

"""
    _SQLITE_INDEX_SYNTAX_WORDS

Bare words that are SQL SYNTAX inside a `CREATE INDEX` argument region rather than column references.
Consulted only for an UNQUOTED token: `"desc"` in quotes is a column named `desc`, while a bare `DESC`
is the sort direction, and SQLite gives no other way to tell them apart.

Why this list is not merely tidiness: without it, an ordinary descending index over a table that also
has a column named `desc` — `CREATE INDEX ix ON t("a" DESC)` — read as referencing BOTH `a` and `desc`.
Deleting `desc` then dropped `ix`, an index on the surviving column `a`, and reported it as an
expression index. That is the one direction that must not happen: an index lost on a column nobody
touched, silently, because a rebuild declined to re-create it.

Erring the other way is safe, and it is worth knowing exactly how far the exposure goes rather than
trusting the shape. Nine of these are NOT reserved in SQLite and so are legal as unquoted identifiers —
`asc`, `desc`, `like`, `glob`, `regexp`, `match`, `true`, `false`, `end` — while the other seventeen can
only ever appear quoted, where this filter does not touch them. For a PLAIN member even those nine are
still found, because `pragma_index_info` supplies the column and the DDL half only adds to it. The
residual miss is one of those nine names referenced unquoted INSIDE an expression or a `WHERE` clause
(`ON t(lower(match))`), and it cannot go silent: a miss shrinks the referenced set, so the index is
KEPT and re-emitted, and SQLite refuses it by name. A missed reference is therefore loud and
recoverable, where the reverse — inventing a reference and dropping an index on a column nobody
touched — is silent and not.

Deliberately NOT a full keyword list: only words reachable in this one region, so an ordinary column
named `key` or `value` (also non-reserved, also legal unquoted) is still matched.
"""
const _SQLITE_INDEX_SYNTAX_WORDS = Set([
  # ordering and collation
  "ASC", "DESC", "COLLATE",
  # the partial-index predicate, and the operators an expression or predicate can contain
  "WHERE", "AND", "OR", "NOT", "IS", "IN", "LIKE", "GLOB", "REGEXP", "MATCH", "BETWEEN", "ESCAPE",
  "NULL", "TRUE", "FALSE",
  # expression forms
  "CASE", "WHEN", "THEN", "ELSE", "END", "CAST", "AS", "DISTINCT",
])

"""
    _SQLITE_INDEX_UNMODELLABLE_WORDS

The bare words whose presence means PormG could not have written the index — a `WHERE` predicate, an
explicit `COLLATE`, or a sort direction. Read by
[`_sqlite_index_is_unmodellable`](@ref); UNQUOTED occurrences only.

Much narrower than [`_SQLITE_INDEX_SYNTAX_WORDS`](@ref) on purpose, because the two answer different
questions. That set is "this token is syntax, so it is not a column"; this one is "this index carries
intent no model declaration holds". `AND`, `NULL`, `LIKE` and the rest are syntax but say nothing about
renderability — they only ever appear inside a predicate, which `WHERE` already disqualifies. Widening
this to the full set would flag every partial index twice and nothing new.
"""
const _SQLITE_INDEX_UNMODELLABLE_WORDS = ("WHERE", "COLLATE", "ASC", "DESC")

"""
    _sqlite_index_is_unmodellable(index_sql, pragma_members, ddl_columns) -> Bool

Whether this index is one PormG could not have created itself — an expression index, a partial index,
one with an explicit `COLLATE`, or one with a sort direction — and therefore one it cannot re-create
after a table rebuild.

PormG emits exactly two index shapes — `Dialect.create_index` (from `db_index` and `Models.Index`) and
`Dialect.create_unique_index` (from `Meta.unique_together` and the many-to-many join table). Both are a
bare list of column names, nothing else. Anything a rebuild drops that does NOT have that shape carries
intent no model declaration can hold, so nothing will bring it back and the operator has to be told.

Four things disqualify an index, and each is checked against what the renderers can actually produce:

  * an **expression** member — a column the DDL references that `pragma_index_info` does not list;
  * a **partial** index — a `WHERE` clause, whose columns pragma never lists at all, and which is
    still disqualifying when its predicate happens to name only plain members
    (`CREATE INDEX ix ON t(a) WHERE a > 0`), where the difference test alone sees nothing;
  * an explicit **`COLLATE`**, which changes which rows the index can serve;
  * an **`ASC`/`DESC`** direction. Django's `Index(fields=['-name'])` produces exactly this, so a
    schema imported from Django can arrive carrying one.

A plain `CREATE UNIQUE INDEX` is deliberately NOT disqualifying: PormG renders those from
`unique_together` and for M2M join tables, and one that references a dropped column is intent the
declared model no longer holds either — the operator removed the column from the group in the same
edit. Warning there would be noise on an ordinary field deletion, which is also why a plain
`CREATE INDEX` (i.e. `db_index`) does not warn.
"""
function _sqlite_index_is_unmodellable(index_sql::AbstractString, pragma_members::Set{String},
                                       ddl_columns::Set{String})::Bool
  # A column the DDL references but pragma does not report as a member ⇒ expression or WHERE clause.
  any(c -> !(c in pragma_members), ddl_columns) && return true
  # The modifiers no PormG renderer emits. UNQUOTED only — `"desc"` is a column named `desc`, and
  # reading it as a sort direction is the same confusion `_SQLITE_INDEX_SYNTAX_WORDS` exists for. See
  # `_SQLITE_INDEX_UNMODELLABLE_WORDS` for why that list is narrower than the syntax one.
  for t in _sqlite_identifier_tokens(_sqlite_index_argument_region(index_sql))
    t.quoted && continue
    uppercase(t.name) in _SQLITE_INDEX_UNMODELLABLE_WORDS && return true
  end
  return false
end

"""
    _sqlite_index_pragma_members(conn, index_name) -> Set{String}

The index's `pragma_index_info` members — the column names SQLite itself reports, with expression
members (whose `name` is `NULL`) absent.

Split out for [`get_secondary_index_ddls`](@ref), which needs BOTH this set and the DDL-derived one
(it classifies the index by their difference) and passes the result into
[`_sqlite_index_referenced_columns`](@ref) as `pragma_members` so the pragma is fetched once per index
rather than twice.
"""
function _sqlite_index_pragma_members(conn::PormGSQLite, index_name::AbstractString)::Set{String}
  rows = fetch(conn, "SELECT name FROM pragma_index_info(?)", [string(index_name)]) |> DataFrame
  members = Set{String}()
  isempty(rows) && return members
  for c in rows.name
    c === missing || push!(members, string(c))
  end
  return members
end

"""
    _sqlite_index_referenced_columns(conn, table_name, index_name, index_sql) -> Set{String}

Which of `table_name`'s columns the index actually references — its `pragma_index_info` members
UNION the columns named in its DDL, so an expression member and a partial index's `WHERE` columns are
both included where `pragma_index_info` alone reports neither (#519).

The DDL half is deliberately conservative in the safe direction. Candidate identifier tokens come
from [`_sqlite_index_argument_region`](@ref); a candidate is dropped when it is

  * followed by `(` — a function call, which is what separates `lower` the function from `lower` the
    column in `lower("a")`;
  * an unquoted [`_SQLITE_INDEX_SYNTAX_WORDS`](@ref) member — `DESC`, `WHERE`, `AND` … ; or
  * the name immediately after an unquoted `COLLATE`, which is a collation (`NOCASE`, `BINARY`,
    `RTRIM`) and not a column, however much it may coincide with one;

and what survives is kept only if `pragma_table_info` confirms the table has a column of that name. So
the DDL text never decides anything on its own: it narrows, and the catalog confirms. Comparison is
case-insensitive because SQLite compares ASCII identifiers that way, and the LIVE spelling is what
comes back, so the result can be tested against a `surviving_columns` set built from a model.
"""
function _sqlite_index_referenced_columns(conn::PormGSQLite, table_name::Union{String,Symbol},
                                          index_name::AbstractString,
                                          index_sql::Union{Nothing,AbstractString};
                                          pragma_members::Union{Nothing,Set{String}} = nothing)::Set{String}
  referenced = pragma_members === nothing ?
               _sqlite_index_pragma_members(conn, index_name) : copy(pragma_members)
  (index_sql === nothing || isempty(strip(String(index_sql)))) && return referenced

  # Parameterized, per this file's own rule (`get_constraints_index`: "an EDITED query does not
  # inherit the exemption") — and these are new queries, so they never had the exemption. The
  # table-valued pragmas take a bound argument, which `get_constraints_index`'s SQLite arm already
  # relies on.
  cols = fetch(conn, "SELECT name FROM pragma_table_info(?)", [string(table_name)]) |> DataFrame
  isempty(cols) && return referenced
  # lowercase ⇒ live spelling, so a mixed-case column (#57) is matched case-insensitively but
  # returned exactly as the catalog holds it.
  by_lower = Dict{String,String}()
  for c in cols.name
    c === missing || (by_lower[lowercase(string(c))] = string(c))
  end

  after_collate = false
  for t in _sqlite_identifier_tokens(_sqlite_index_argument_region(index_sql))
    # The token right after an unquoted COLLATE is a collation name. Consumed here rather than
    # filtered by name, because `NOCASE` is a perfectly legal column name and a user-defined
    # collation can be called anything at all.
    if after_collate
      after_collate = false
      continue
    end
    if !t.quoted && uppercase(t.name) == "COLLATE"
      after_collate = true
      continue
    end
    t.called && continue                                                    # a function name
    (!t.quoted && uppercase(t.name) in _SQLITE_INDEX_SYNTAX_WORDS) && continue  # SQL syntax
    live = get(by_lower, lowercase(t.name), nothing)
    live === nothing || push!(referenced, live)
  end
  return referenced
end

"""
    _sqlite_rewrite_index_columns(index_sql, column_renames) -> String

`index_sql` with every reference to a renamed column — inside the argument region, whatever its
spelling — replaced by the QUOTED new name (#532).

The #150 rewrite substituted the quoted `"old"` token as a string: exact for the one spelling PormG
writes and blind to every other, so a hand-written `lower(a)`, `[a]` or `` `a` `` passed the
`surviving_columns` filter (the identifier-aware reader sees the reference) and was re-emitted with the
PRE-rename name, failing the rebuild at the server with "no such column". A bare-word substitution is
not the fix — it is the unanchored substring match #515 removed, and it would rewrite an index NAME,
a string literal or a longer identifier that merely contains the column. So the rewrite is by token
SPAN, over the tokens of the whole statement:

  * a candidate must start at or after [`_sqlite_index_argument_start`](@ref), which excludes the
    index name and the table name structurally;
  * the same three exclusions [`_sqlite_index_referenced_columns`](@ref) applies hold here — a name
    followed by `(` is a function, an unquoted [`_SQLITE_INDEX_SYNTAX_WORDS`](@ref) member is syntax,
    the name after an unquoted `COLLATE` is a collation — so the filter and the rewrite agree about
    what a column reference is;
  * matching is ASCII-case-insensitive, as SQLite resolves identifiers; the replacement is always the
    quoted form, which is how PormG spells every identifier it writes, with an embedded `"` doubled;
  * spans are spliced right to left, so replacing one never moves the offsets of the ones before it.

String literals, comments and blob literals are never candidates, because the tokenizer does not
report them.
"""
function _sqlite_rewrite_index_columns(index_sql::AbstractString,
                                       column_renames::AbstractDict{String,String})::String
  out = String(index_sql)
  isempty(column_renames) && return out
  by_lower = Dict{String,String}(lowercase(k) => v for (k, v) in column_renames)
  region_start = _sqlite_index_argument_start(out)
  edits = Tuple{Int,Int,String}[]
  after_collate = false
  for t in _sqlite_identifier_tokens(out)
    t.start < region_start && continue                          # the index name and the table name
    if after_collate
      after_collate = false
      continue
    end
    if !t.quoted && uppercase(t.name) == "COLLATE"
      after_collate = true
      continue
    end
    t.called && continue                                        # a function name
    (!t.quoted && uppercase(t.name) in _SQLITE_INDEX_SYNTAX_WORDS) && continue
    newc = get(by_lower, lowercase(t.name), nothing)
    newc === nothing && continue
    push!(edits, (t.start, t.stop, string('"', replace(newc, '"' => string('"', '"')), '"')))
  end
  # Tokens arrive in source order; splice from the last one back so the earlier spans stay valid.
  for (a, b, repl) in Iterators.reverse(edits)
    out = string(SubString(out, 1, prevind(out, a)), repl, SubString(out, nextind(out, b)))
  end
  return out
end

"""
    _sqlite_rewrite_index_table(index_sql, new_table) -> String

`index_sql` with the table it is `ON` replaced by the QUOTED `new_table` (#615) — for a `CREATE
INDEX` snapshotted from `sqlite_master` before a table rename that runs ahead of the rebuild which
re-emits it.

The table is the last identifier before [`_sqlite_index_argument_start`](@ref), and it must follow an
unquoted `ON`: `CREATE [UNIQUE] INDEX [IF NOT EXISTS] name ON table (…)` puts nothing else there, and
SQLite does not allow a schema qualifier on the table. Located by token SPAN, with the tokenizer
[`_sqlite_rewrite_index_columns`](@ref) uses, so the index name, a column or a string literal that
happens to equal the table's name is never touched, and any of SQLite's spellings (bare, `"…"`,
`[…]`, `` `…` ``) is replaced. So is the legacy `'…'` one — SQLite accepts a string literal where a
table name is expected and stores it verbatim — which the tokenizer skips as a literal, so it is
found as the text between the `ON` and the column list instead. Anything that does not have that
shape — a malformed or truncated `sql` — is returned unchanged rather than guessed at.
"""
function _sqlite_rewrite_index_table(index_sql::AbstractString, new_table::AbstractString)::String
  out = String(index_sql)
  region_start = _sqlite_index_argument_start(out)
  region_start == 1 && return out                               # no column list: not an index DDL
  head = [t for t in _sqlite_identifier_tokens(out) if t.start < region_start]
  isempty(head) && return out
  repl = string('"', replace(String(new_table), '"' => string('"', '"')), '"')
  final = head[end]
  if !final.quoted && uppercase(final.name) == "ON"
    # `ON 'old_t' (…)`: the table is a string literal, invisible to the tokenizer.
    gap = SubString(out, nextind(out, final.stop), prevind(out, region_start))
    lit = strip(gap)
    (length(lit) >= 2 && startswith(lit, '\'') && endswith(lit, '\'')) || return out
    a = final.stop + findfirst('\'', gap)          # byte index of the opening quote
    b = final.stop + findlast('\'', gap)           # …and of the closing one
    return string(SubString(out, 1, prevind(out, a)), repl, SubString(out, nextind(out, b)))
  end
  length(head) >= 2 || return out
  on, tbl = head[end - 1], head[end]
  (!on.quoted && uppercase(on.name) == "ON") || return out
  return string(SubString(out, 1, prevind(out, tbl.start)), repl, SubString(out, nextind(out, tbl.stop)))
end

"""
    _sqlite_indexes_referencing_column(conn, table_name, column_name) -> Vector{String}

Names of every user-created index on `table_name` that references `column_name`, in name order —
plain, composite, unique, expression and partial alike (#519).

This is the question `ALTER TABLE … DROP COLUMN` asks on SQLite, which refuses to drop a column ANY
index references. It is deliberately much wider than [`get_constraints_index`](@ref), which answers
"may PormG drop this index?" and therefore excludes the constraint-backing ones and returns a single
name; a blocking check needs every index, including the ones that cannot be dropped separately and
the ones a second `DROP INDEX` would be needed for.

Restricted to `sql IS NOT NULL`, i.e. indexes with DDL of their own. The auto-indexes that back a
`UNIQUE` or `PRIMARY KEY` clause have a NULL `sql`, cannot be dropped at all, and are already routed
to the rebuild by [`_sqlite_column_is_unique`](@ref) and the planner's `primary_key` test.
"""
function _sqlite_indexes_referencing_column(conn::PormGSQLite, table_name::Union{String,Symbol},
                                            column_name::AbstractString)::Vector{String}
  # `COLLATE NOCASE` on `tbl_name`, because SQLite resolves a table NAME case-insensitively while
  # `sqlite_master.tbl_name` is BINARY-collated. Without it this answers "no indexes" for a table
  # whose `db_table` spelling differs in case from its `CREATE TABLE` — the plain `DROP COLUMN` is
  # then planned and SQLite refuses it, i.e. #519 silently un-fixed for a mixed-case table (#57). The
  # sibling probe in the same planner disjunct, `_sqlite_column_is_unique`, goes through
  # `PRAGMA index_list`, which is already case-insensitive; these two must agree.
  rows = fetch(conn, "SELECT name, sql FROM sqlite_master WHERE type = 'index' AND tbl_name = ? COLLATE NOCASE AND sql IS NOT NULL ORDER BY name", [string(table_name)]) |> DataFrame
  isempty(rows) && return String[]
  target = lowercase(String(column_name))
  hits = String[]
  for r in eachrow(rows)
    r.name === missing && continue
    sql = r.sql === missing ? nothing : string(r.sql)
    referenced = _sqlite_index_referenced_columns(conn, table_name, string(r.name), sql)
    any(c -> lowercase(c) == target, referenced) && push!(hits, string(r.name))
  end
  return hits
end

"""
    get_secondary_index_ddls(conn::PormGSQLite, table_name) -> Vector{String}

Return the `CREATE INDEX` DDL for every *user-created* secondary index on `table_name`, verbatim from
`sqlite_master`. Auto-indexes backing column-level `UNIQUE` constraints have a NULL `sql` and are excluded —
they are recreated automatically by the rebuilt `CREATE TABLE`. Used by the SQLite table-rebuild path to
re-create the indexes that the rebuild's `DROP TABLE` would otherwise silently lose (#82).

`column_renames` (old ⇒ new physical name) supports the rename-with-FK-change rebuild (#150): the DDL is
snapshotted from the LIVE schema at planning time (old column name), but the rebuilt table carries the new
name, so each renamed column is mapped through this dict both when testing `surviving_columns` membership
(else the renamed column's index would be wrongly filtered out and lost) and when rewriting the emitted DDL
— by token span, so a column spelled bare, bracketed or backticked in a hand-written index follows the
rename exactly like PormG's own quoted spelling (#532, [`_sqlite_rewrite_index_columns`](@ref)).
Default empty ⇒ no rewriting, so every existing #82/#116 call site is unaffected.

`rename_table_to` is the same idea for the TABLE (#615): `table_name` is what the catalog holds at
planning time, and when the table is renamed in the same migration the rebuild runs against the new
name, so each emitted statement is re-targeted with [`_sqlite_rewrite_index_table`](@ref). Default
`nothing` ⇒ the table token is left as the catalog spelled it.
"""
function get_secondary_index_ddls(conn::PormGSQLite, table_name::Union{String,Symbol};
                                  surviving_columns::Union{Nothing,Set{String}} = nothing,
                                  column_renames::Dict{String,String} = Dict{String,String}(),
                                  rename_table_to::Union{Nothing,String} = nothing)::Vector{String}
  # `name` is fetched alongside `sql` so we can probe each index's columns via pragma_index_info
  # when filtering (#116). Auto-created indexes (UNIQUE/PK) carry a NULL `sql` and are excluded here,
  # exactly as before — they belong to the CREATE TABLE the rebuild already re-emits.
  # `? COLLATE NOCASE`, for the reason spelled out in `_sqlite_indexes_referencing_column`: SQLite
  # resolves a table NAME case-insensitively while `sqlite_master.tbl_name` is BINARY-collated.
  #
  # #519 review: this query and that probe MUST agree, and making only one of them insensitive was a
  # regression worse than leaving both blind. The probe decides whether a deletion routes to the
  # rebuild; this decides which indexes the rebuild puts back. Insensitive probe + sensitive snapshot
  # on a mixed-case table (#57) meant "rebuild the table, and re-create NONE of its indexes" — every
  # index silently lost, including ones on columns nobody touched, which is the #82 class this filter
  # exists to prevent. While both were blind they agreed and the deletion merely failed loudly. The
  # two name sources also differ (the probe gets the planner's key, this gets
  # `model_table_name(current_model)`), so agreement cannot be assumed from the callers.
  rows = fetch(conn, "SELECT name, sql FROM sqlite_master WHERE type = 'index' AND tbl_name = ? COLLATE NOCASE AND sql IS NOT NULL", [string(table_name)]) |> DataFrame
  isempty(rows) && return String[]
  ddls = String[]
  for r in eachrow(rows)
    s = r.sql
    s === missing && continue
    stmt = strip(string(s))
    isempty(stmt) && continue
    # #116: when the caller is rebuilding a table with columns removed (FK-field deletion), an index on a
    # dropped column must NOT be re-created — SQLite would raise "no such column". Drop the index if any
    # of the columns it references is no longer present in the rebuilt table. No filtering when the kwarg
    # is `nothing`, so every existing rebuild call site keeps its current behavior.
    #
    # #519: the membership test was `pragma_index_info` alone, and that reports NULL for an EXPRESSION
    # member and does not list a PARTIAL index's WHERE-clause columns — so an expression or partial index
    # over a dropped column slipped through the filter, was re-emitted verbatim, and failed the rebuild
    # with "no such column". `_sqlite_index_referenced_columns` answers the same question over the index's
    # DDL as well as its pragma members, identifier-aware and confirmed against `pragma_table_info`, so
    # both shapes are now caught. The old comment called this an accepted limitation on the grounds that
    # PormG never CREATES such an index; that is still true, and it was never the point — an adopted
    # database arrives with indexes PormG did not write.
    if surviving_columns !== nothing
      pragma_members = _sqlite_index_pragma_members(conn, string(r.name))
      all_referenced = _sqlite_index_referenced_columns(conn, table_name, string(r.name), stmt;
                                                        pragma_members = pragma_members)
      # #150: the live index references the OLD column name; map it to the rebuilt table's new name
      # before the membership test so a renamed-but-surviving column keeps its index.
      referenced = String[get(column_renames, c, c) for c in all_referenced]
      lost = String[c for c in referenced if !(c in surviving_columns)]
      if !isempty(lost)
        # #519: nothing is dropped in silence. Only for an index PormG could not have created — a plain
        # column index is `db_index` / `Models.Index`, which the declared model re-creates by itself, so
        # warning there would be noise on an ordinary field deletion. Structured kwargs and NO `maxlog`,
        # per the repo's warn-once policy in `src/AdvisoryLock.jl`: that policy exists for unbounded call
        # sites, and this one is bounded by a single table's index count. A rebuild can be registered
        # more than once for one table (the entry is relocated on each registration), so the same warning
        # may appear twice in a `makemigrations` — repetition beats a silently lost index.
        if _sqlite_index_is_unmodellable(stmt, pragma_members, all_referenced)
          # The message names all four disqualifying shapes, because the `definition` printed beside it
          # tells the operator which one they have — and a message that said "expression or partial"
          # beside a `("a" DESC)` definition contradicted itself.
          @warn "SQLite table rebuild will DROP an index PormG cannot re-create: it uses an " *
                "expression, a WHERE clause, an explicit COLLATE or a sort direction, none of which a " *
                "model declaration expresses. Re-create it by hand after the migration if you still " *
                "need it." table = string(table_name) index = string(r.name) dropped_columns = sort(lost) definition = stmt
        end
        continue
      end
    end
    # #150 / #532: rewrite each renamed column in the snapshotted DDL — by token span, not by string
    # substitution. The quoted-token `replace` this used to be was precise for what PormG writes and
    # blind to a column spelled bare inside an expression or a WHERE clause, which then came back under
    # the pre-rename name and failed the rebuild at the server. Empty dict ⇒ no-op for #82/#116.
    stmt = _sqlite_rewrite_index_columns(stmt, column_renames)
    # #615: the table itself is being renamed in the same migration, ahead of the rebuild, so the
    # snapshot's `ON "<old>"` must follow it. `nothing` (every non-rename caller) leaves it alone.
    rename_table_to === nothing || (stmt = _sqlite_rewrite_index_table(stmt, rename_table_to))
    push!(ddls, endswith(stmt, ";") ? stmt : stmt * ";")
  end
  return ddls
end

# `table_name::String` — NOT Symbol. This was the odd one out of the four `get_constraints_*`
# helpers, and since `alter_field`'s model-based overload always resolves the table to
# `model.name |> lowercase` (a String), a Symbol signature could never be dispatched to (#283).
function get_constraints_pk(conn::PormGPostgres, table_name::String, field_name::String)
  # The `kcu` join carries the TABLE as well as the name and schema. A constraint name is scoped to
  # its table (#498, beside `get_constraints_fk`): a primary key's name is also its index's, unique
  # per schema, but a foreign key on ANOTHER table may carry the same name, and a join on name and
  # schema alone then splices that table's key columns in — `get_constraints_pk(conn, "driver",
  # "driverid")` answering with `driver`'s key while it sits on `id`. This query was unreachable
  # until #283 (its only caller passed the wrong arity), so it had never run to expose the defect.
  # Filters on `tc.table_name` rather than `ccu.table_name` — `tc` IS the constrained table.
  #
  # #731: parameterized, search-path-restricted, and ordered by search-path position like
  # `get_constraints_check` — the unqualified DDL this arms binds to the first schema that holds the
  # table. The names used to be spliced into single-quoted literals, where a quote broke the query.
  query = """
  SELECT tc.constraint_name
  FROM information_schema.table_constraints tc
  JOIN information_schema.key_column_usage kcu
    ON tc.constraint_name = kcu.constraint_name AND tc.table_schema = kcu.table_schema
   AND tc.table_name = kcu.table_name
  WHERE tc.table_name = \$1
    AND tc.constraint_type = 'PRIMARY KEY'
    AND kcu.column_name = \$2
    AND tc.table_schema = ANY(current_schemas(false))
  ORDER BY array_position(current_schemas(false), tc.table_schema::name), tc.constraint_name;
  """
  result = fetch(conn, query, [table_name, field_name]) |> DataFrame
  if nrow(result) == 0
      return nothing
  end
  return result[1, :constraint_name]
end

# Returns `nothing` when no UNIQUE constraint matches — the annotation must admit it, or Julia
# converts the `return nothing` below and raises instead of letting callers test it (#284).
#
# #325: the SINGLE-column UNIQUE on `field_name`, and nothing else. The caller is
# `Dialect.alter_field`, dropping a constraint because the model stopped declaring `unique=true` —
# and `field.unique` is only ever read back from a single-column constraint (#318), so a composite
# one must never be droppable through this path. It was: the query matched every constraint the
# column merely *belongs to* and returned `result[1, …]` from an unordered result, so a column in
# both `UNIQUE(a)` and `UNIQUE(a, b)` dropped whichever row PostgreSQL happened to return first.
#
# Three changes make that deterministic:
#   * `key_column_usage`, not `constraint_column_usage` — the former lists a constraint's OWN
#     columns, which is what lets `COUNT(*) = 1` mean "single-column constraint". (The latter is
#     equivalent for UNIQUE, but only by accident of PostgreSQL's implementation; the sibling
#     `get_constraints_pk` above already uses `kcu`.)
#   * `GROUP BY` + `HAVING COUNT(*) = 1` — the arity filter, mirroring the CTE #318 added.
#   * `ORDER BY` — with the arity filter two matches are already pathological (two single-column
#     UNIQUEs on the same column), but "whichever came first" is not an answer.
#
# Parameterized and search-path-restricted, like every `get_constraints_*` lookup since #731, and
# for the same two reasons as `get_constraints_pk` above (#731 review): the `kcu` join carries the
# table — a foreign key elsewhere may share this constraint's name, and its columns would then
# count toward `COUNT(*)` — and the order puts the first schema on the search path first.
function get_constraints_unique(conn::PormGPostgres, table_name::String, field_name::String)::Union{String, Nothing}
  query = """
  SELECT tc.constraint_name
  FROM information_schema.table_constraints tc
  JOIN information_schema.key_column_usage kcu
    ON tc.constraint_name = kcu.constraint_name AND tc.table_schema = kcu.table_schema
   AND tc.table_name = kcu.table_name
  WHERE tc.table_name = \$1
    AND tc.constraint_type = 'UNIQUE'
    AND tc.table_schema = ANY(current_schemas(false))
  GROUP BY tc.constraint_name, tc.table_schema
  HAVING COUNT(*) = 1 AND bool_or(kcu.column_name = \$2)
  ORDER BY array_position(current_schemas(false), tc.table_schema::name), tc.constraint_name;
  """
  result = fetch(conn, query, [table_name, field_name]) |> DataFrame
  if nrow(result) == 0
      return nothing
  end
  return result[1, :constraint_name]
end

# Find the non-negative CHECK constraint backing a positive integer column.
# PostgreSQL has no unsigned integer type, so PormG enforces `col >= 0` with a
# CHECK constraint; on a type transition away from a positive integer field the
# migration engine needs the constraint's auto-generated name to drop it. We
# match by column and clause rather than assuming a name, so it works even for
# constraints PormG created anonymously at CREATE TABLE time. Returns `nothing`
# when no such constraint exists.
#
# #731: the clause is matched EXACTLY, by the predicate the reader uses
# (`_PG_NON_NEGATIVE_CHECK_MATCH`). It was `ILIKE '%>= 0%'` over
# `information_schema`, so a user's `CHECK (grid >= 0 AND grid <= 30)` on the column
# was returned as PormG's and dropped. Read from `pg_catalog` because the predicate
# needs `con.oid`, and scoped the way the DDL it feeds resolves: one column, a
# schema on the search path, the first such schema winning — an unqualified
# `ALTER TABLE` binds to that one.
function get_constraints_check(conn::PormGPostgres, table_name::String, field_name::String)::Union{String, Nothing}
  query = """
  SELECT con.conname AS constraint_name
  FROM pg_constraint con
  JOIN pg_class c ON c.oid = con.conrelid
  JOIN pg_namespace n ON n.oid = c.relnamespace
  JOIN pg_attribute a ON a.attrelid = con.conrelid AND a.attnum = ANY(con.conkey)
  WHERE con.contype = 'c'
    AND c.relname = \$1
    AND a.attname = \$2
    AND n.nspname = ANY(current_schemas(false))
    AND array_length(con.conkey, 1) = 1
    AND $(_PG_NON_NEGATIVE_CHECK_MATCH)
  ORDER BY array_position(current_schemas(false), n.nspname), con.conname;
  """
  result = fetch(conn, query, [table_name, field_name]) |> DataFrame
  if nrow(result) == 0
      return nothing
  end
  return result[1, :constraint_name]
end

# Find the byte-length CHECK backing a bounded BinaryField (#296) — the `octet_length` sibling of
# `get_constraints_check` above. `bytea` takes no length parameter, so `max_length` can only be a
# CHECK, and on a transition away from a bounded BinaryField the migration engine needs the
# auto-generated name to drop it. Matched on the clause rather than the name, for the same reason.
#
# Deliberately a separate generic rather than a parameter on `get_constraints_check`: a table can
# carry both kinds, and matching the wrong one would drop a live constraint.
function get_constraints_byte_length_check(conn::PormGPostgres, table_name::String, field_name::String)::Union{String, Nothing}
  # Parameterized, like every sibling since #731: both values would otherwise land inside
  # single-quoted literals, where an embedded `'` breaks out.
  #
  # `table_schema` is restricted to the search path: an unqualified table name in the DDL this
  # feeds resolves the same way, so without it a same-named table in another schema can hand back
  # a constraint name that does not exist on the target table, and the ALTER then fails.
  #
  # Residual ambiguity, deliberately left: a *hand-written* CHECK using `octet_length` on the same
  # column is indistinguishable from PormG's own by clause alone. Matching the auto-generated name
  # instead would be worse — the name is not stable across the paths that create it.
  query = """
  SELECT tc.constraint_name
  FROM information_schema.table_constraints tc
  JOIN information_schema.constraint_column_usage ccu
    ON tc.constraint_name = ccu.constraint_name AND tc.table_schema = ccu.table_schema
  JOIN information_schema.check_constraints cc
    ON cc.constraint_name = tc.constraint_name AND cc.constraint_schema = tc.constraint_schema
  WHERE tc.table_name = \$1
    AND tc.constraint_type = 'CHECK'
    AND ccu.column_name = \$2
    AND tc.table_schema = ANY(current_schemas(false))
    AND cc.check_clause ILIKE '%octet_length%'
    AND cc.check_clause ~ '<= [0-9]+';
  """
  result = fetch(conn, query, [table_name, field_name]) |> DataFrame
  if nrow(result) == 0
      return nothing
  end
  return result[1, :constraint_name]
end

# Same empty-result contract as `get_constraints_unique` above (#284).
# Parameterized (#731): the names are the function's text arguments, bound rather than spliced.
function get_sequence_name(conn::PormGPostgres, table_name::String, field_name::String)::Union{String, Nothing}
  query = """
  SELECT pg_get_serial_sequence(\$1, \$2);
  """
  result = fetch(conn, query, [table_name, field_name]) |> DataFrame
  if nrow(result) == 0
      return nothing
  end
  return result[1, :pg_get_serial_sequence]
end

# ---
# PostgreSQL schema-query decoding (#455)
#
# `get_database_schema(::PormGPostgres)` transports every aggregate as `json_agg(...)::text`. The
# two helpers below are the whole decode: one to parse an aggregate, one to undo `pg_get_expr`'s
# rendering of a DEFAULT; the `format_type` spelling goes to `parse_canonical_type` as it is (#522),
# which retired the alias table and the type-map normaliser that used to sit between them. They
# replaced a parse that split the same facts out of a rendered string, where the
# delimiters were `", "` and `" "` — both legal inside the identifiers and DEFAULT expressions they
# delimited.
# ---

# One aggregate, parsed. `missing` — which the LEFT JOINs produce for a table with no keys, no
# foreign keys or no indexes — degrades to `nothing`, and every caller reads that as "none".
#
# An ABSENT column degrades the same way. `convertSQLToModel(::DataFrameRow)` is exported, so a row
# may come from somewhere other than the current `get_database_schema` — that is how #292's addition
# of `delete_rules` reached a caller holding an older row. No in-repo producer omits a column today;
# this is the reader's "degrade, never abort a whole schema read" policy, not a live shape.
#
# Deliberately no rescue around `JSON.parse`. Under the old string format a malformed aggregate was
# an ordinary consequence of an odd-but-legal schema, so the reader degraded and warned; under JSON
# there is no legal schema that produces an unparseable aggregate, so one means PormG built bad SQL.
# `makemigrations` already wraps this read in a try/catch and reports "no plan generated".
function _pg_json(row, key::Symbol)
  (key in propertynames(row) && !ismissing(row[key])) || return nothing
  return JSON.parse(String(row[key]))
end

_pg_single_quoted_literal(s::AbstractString)::Bool = _quoted_literal(s, '\'')

# A cast at the END of an expression: `::text`, `::character varying`, `::numeric(10,2)`,
# `::integer[]`, `::"MyEnum"`, `::public.my_enum`. ANCHORED on purpose — the global
# `r"::[a-zA-Z_]+"` this replaces turned `'{1,2}'::integer[]` into `'{1,2}'[]`, silently losing an
# array default.
const _PG_TRAILING_CAST = r"::(?:\"[^\"]*\"|[A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z_][A-Za-z0-9_]*)?(?:\s+[A-Za-z_][A-Za-z0-9_]*)*)(?:\s*\(\s*\d+(?:\s*,\s*\d+)?\s*\))?(?:\s*\[\s*\])*\s*$"

function _pg_strip_trailing_casts(s::AbstractString)::String
  out = String(strip(s))
  for _ in 1:8   # `((x)::text)::varchar` — bounded so a pathological string cannot spin
    stripped = String(strip(replace(out, _PG_TRAILING_CAST => "")))
    stripped == out && break
    out = stripped
  end
  return out
end

# Undo `pg_get_expr`'s rendering of a column DEFAULT.
#
# Takes the WHOLE expression. The regex this replaces was WHITESPACE-TERMINATED
# (`r"DEFAULT\s+((?:\([^)]+\)|[^:\s]+)(?:::[a-zA-Z_]+)?)"`), so any default containing a space was
# truncated before the unwrapping below ever saw it — `DEFAULT 'Ferrari, Scuderia'::text` cleaned to
# `'Ferrari`. That is a SEPARATE defect from the aggregate tear #455 is about, and it survives the
# JSON move on its own: fixing where the string comes from does not fix a parser that stops at the
# first space.
#
# An expression this cannot reduce to a literal (`concat('a', 'b')`, `nextval('s'::regclass)`,
# `now()`, `now() - '1 day'::interval`) is returned WHOLE, which is what the field constructors then
# judge. "Whole" is load-bearing and is the reason the inner re-strip below is conditional — see
# there.
#
# A bare `NULL` (`DEFAULT NULL::character varying`, which pg_dump emits routinely) is "no default",
# not the four-character string `"NULL"`. That is the answer `_normalize_sqlite_default` already
# gives for the same input, and the engines have to agree.
function _pg_clean_default(expr)::Union{String, Nothing, _ExpressionDefault}
  expr === nothing && return nothing
  s = _pg_strip_trailing_casts(String(expr))
  isempty(s) && return nothing
  # `(0)::numeric` → strip the cast → `(0)` → unwrap → `0`.
  #
  # The inner value may carry its OWN cast (`('x'::text)`), but re-stripping unconditionally is
  # wrong: `pg_get_expr` parenthesizes every non-trivial expression, so the inner text is usually a
  # COMPOUND expression whose trailing cast belongs to its last OPERAND. Stripping it there turns
  # `('x'::text || 'y'::text)` into `'x'::text || 'y'` — a mangled expression rather than an
  # unrecognized one. So the re-stripped form is kept only when it actually reduced to a literal.
  if _wrapped_in_parens(s)
    inner = s[nextind(s, firstindex(s)):prevind(s, lastindex(s))]
    stripped = _pg_strip_trailing_casts(inner)
    s = _pg_single_quoted_literal(stripped) ? stripped : String(strip(inner))
  end
  if _pg_single_quoted_literal(s)
    # Shared with the SQLite cleaner (#475). Both engines unquote identically, and keeping two
    # copies of the logic is how they drifted apart twice already — once on the balanced-quote
    # test, once on byte-vs-character slicing.
    return _unquote_literal(s, '\'')
  end
  uppercase(s) == "NULL" && return nothing
  # Whatever did not reduce to a literal above is a SQL EXPRESSION — `now()`, `nextval('s')`,
  # `'x'::text || 'y'::text`. Tagged rather than returned as a bare String so the reader arms route
  # on the SCHEMA rather than on whether the target field type happens to refuse the value (#475).
  # See `_ExpressionDefault` for why this cannot be decided from the returned value afterwards.
  return _is_sql_literal_token(s) ? s : _ExpressionDefault(s)
end


"""
    _pg_live_table(row) -> LiveTable

The PostgreSQL reader (#522): one row of `get_database_schema(::PormGPostgres)` — a table with its
JSON-transported aggregates (#455) — compiled straight into a `LiveTable`. The slot-by-slot
contract is `_sqlite_live_table`'s, read from the catalog facts this engine has instead:
`format_type` for the type, `attnotnull`, the single-column `contype = 'u'` set, the `>= 0` and
`octet_length` CHECKs the schema query already isolates, `attidentity` for the identity of an
integer key, and the single-column non-unique index list for `indexes`. Composite indexes are
attached by `read_live_schema`, which holds the schema-wide query for them (#347).

The two readers must describe one schema the same way (#409): the key arms and their order are
`_key_arm`'s on both, `unique` and `null` follow the same per-arm rules, and the same coercion
lands each default on the value a declaration stores.
"""
function _pg_live_table(row::DataFrameRow)::LiveTable
  engine = _PostgresEngine()
  table_name = String(row[:table_name])
  # `primary_keys` is missing for keyless tables. No de-quoting anywhere since #455: JSON carries a
  # name as a string, not as a SQL identifier, so every name here is already the physical one.
  pk_set = Set{String}(String.(something(_pg_json(row, :primary_keys), Any[])))
  # Each fact reads off the object it belongs to (#455); `on_delete` degrades to "none recorded"
  # rather than throwing if absent, per the reader's policy of never aborting a schema read over one
  # field. `something(...)` because JSON null parses to `nothing`, which `String` has no method for.
  fk_map = Dict{String, NamedTuple{(:table, :pk, :on_delete), Tuple{String, String, Union{String, Nothing}}}}()
  for fk in something(_pg_json(row, :foreign_keys), Any[])
    fk_map[String(fk["column"])] =
      (table = String(fk["table"]), pk = String(fk["pk"]),
       on_delete = _pg_confdeltype_to_on_delete(something(get(fk, "on_delete", ""), "")))
  end
  # Physical column ⇒ index name, for the single-column secondary indexes the `indexes` CTE keeps;
  # the value is what `_drop_index` needs (#325, #455).
  indexes = Dict{String, Union{String, Nothing}}()
  for ix in something(_pg_json(row, :indexes), Any[])
    indexes[String(ix["column"])] = String(ix["name"])
  end

  # Ordered (#544): `columns` is aggregated `ORDER BY a.attnum`, i.e. in physical column order.
  columns = OrderedDict{String, ColumnSpec}()
  for col in something(_pg_json(row, :columns), Any[])
    # `name` and `type` are REQUIRED — an entry without them describes no column, so a `KeyError`
    # is the honest answer. Every optional key is read with a default, so a row that omits one still
    # imports (#455).
    col_name = String(col["name"])
    raw_type = String(col["type"])
    ctype = parse_canonical_type(raw_type, engine)
    is_pk = col_name in pk_set
    not_null = get(col, "notnull", false) === true
    unique = get(col, "unique", false) === true
    reference = nothing
    if haskey(fk_map, col_name)
      fk = fk_map[col_name]
      reference = ForeignKeyRef(fk.table,
                                format_model_name(Models._model_binding_name(fk.table)),
                                fk.pk,
                                Models._foreign_key_on_delete_sql(_normalize_introspected_on_delete(fk.on_delete)))
    end
    arm = _key_arm(is_pk, ctype, reference !== nothing)
    # `unique`, per arm, as the old reader built the field: `IDField` and a pk-fk `OneToOneField`
    # are unique by construction; every other arm takes the COMPUTED fact — PostgreSQL records a
    # key's uniqueness through the primary-key constraint, not a separate UNIQUE one, so a plain
    # `UUIDField(primary_key = true)` or `CharField(primary_key = true, …)` reads back `false`,
    # which is what its constructor defaults to (#334).
    spec_unique = (arm === :id_pk || (arm === :reference && is_pk)) ? true : unique
    # The two CHECK facts the schema query isolates per column (#296, PositiveIntegerField).
    found = CheckKind[]
    get(col, "non_negative_check", false) === true && push!(found, NonNegativeCheck())
    byte_limit = get(col, "byte_limit", nothing)
    byte_limit === nothing || push!(found, ByteLengthCheck(Int(byte_limit)))
    # `pg_attribute.attidentity` verbatim (#455): 'a' = GENERATED ALWAYS, 'd' = BY DEFAULT, '' =
    # neither — and only on the arm whose struct can carry it (`IDField`), as before.
    identity_code = something(get(col, "identity", ""), "")
    identity = (arm === :id_pk && identity_code in ("a", "d")) ?
               ColumnIdentity(true, identity_code == "a", false) : nothing
    probe = ColumnSpec(col_name, ctype, is_pk ? false : !not_null, is_pk, spec_unique, NoDefault(),
                       reference, _reader_checks(found, ctype), identity, raw_type)
    columns[col_name] = _finish_column_spec(table_name, probe, get(col, "default", nothing), engine)
  end
  return LiveTable(table_name, columns, indexes)
end

"""
    convertSQLToModel(row::DataFrameRow; conn = _PostgresEngine()) -> PormGModel

The model `inspectdb` writes for one row of `get_database_schema(::PormGPostgres)`:
`_pg_live_table` compiled through `model_from_live`. Exported, so a row may come
from a caller's own frame; `conn` only picks the engine's struct choices and touches no connection.
"""
convertSQLToModel(row::DataFrameRow{DataFrame, DataFrames.Index};
                  conn::Union{PormGPostgres, PormGSQLite} = _PostgresEngine())::PormGModel =
  model_from_live(_pg_live_table(row), conn)
