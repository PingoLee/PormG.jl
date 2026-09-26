module Dialect
using Dates, TimeZones
using DataFrames
import Tables
import PormG: PormGSettings, SQLType, SQLInstruction, SQLTypeQ, SQLTypeQor, SQLTypeF, SQLTypeOper, SQLObject, PormGModel, PormGField, PormGBackend, PormGPostgres, PormGSQLite, PormGAbstractType
import PormG: backend_sqlite_version  # SQLite library-version probe (driver body in the weakdep extension)
# Semantic error taxonomy (#239). Dialect raises three categories:
#   InvalidValueError          — a rendered value has the wrong Julia type ("must be a String"),
#                                or SQL grammar PormG writes itself is outside what it parses
#                                (a `Cast` type name #696, a window frame #713).
#   BackendCapabilityError — the active backend cannot do this (a PG-only JSONB/unaccent
#                                lookup, an extract part SQLite lacks, too old a SQLite library,
#                                a DecimalField wider than SQLite stores exactly #648).
#   QueryBuildError            — the caller passed an impossible argument shape (on_conflict_clause).
import PormG: InvalidValueError, BackendCapabilityError, QueryBuildError
# #496: the `db_default` vocabulary (Kernel, layer 1). `db_default_sql` below renders from it, and
# `Migrations._column_default` compiles the declared side through the same function.
import PormG: PORTABLE_DB_DEFAULTS
import PormG.ConnectionPool: fetch
import PormG: postgres_type_map_reverse, date_format_map, sqlite_type_map_reverse
# The canonical column IR (#507). `alter_field` renders an ALTER from a `ColumnDelta`, which is why
# these types live in `Kernel` (layer 1) rather than in `Migrations` — this module is included
# BEFORE it, and a submodule resolves `import PormG: …` at include time. `_has_non_negative` and
# `_byte_bound` are underscore-private, hence named explicitly.
import PormG: ColumnDelta, LiteralDefault, ExpressionDefault
# #522: the two `USING` casts in `alter_field` read the LIVE column's canonical type off the delta
# instead of dispatching on a reconstructed field struct — the readers no longer build one.
import PormG: CanonicalType, CInt16, CInt32, CInt64, CFloat64, CDecimal, CText, CVarChar, CTime
# #564: the remaining temporal nouns, for the read-parser half of the value-representation table.
import PormG: CDate, CDateTime, CInterval
import PormG: _has_non_negative, _byte_bound
import PormG: get_constraints_pk, get_constraints_unique, get_constraints_check, get_constraints_byte_length_check
import PormG.Models: Migration, get_model_pk_field, format_model_name, field_db_column, fk_target_column, format_timezone_sql, model_table_name, fk_target_table
# #564: the read side of the canonical timestamp text, now that its PARSER lives here beside the
# mask it inverts. `normalize_sqlite_datetime_string` stays in `Models` because it is also on the
# WRITE path (`validate_timezone`) — this module only consumes it.
import PormG.Models: normalize_sqlite_datetime_string
# `_foreign_key_on_delete_sql` lives in `Models` since #498 — see the note where it used to be defined.
import PormG.Models: _foreign_key_on_delete_sql

import PormG: @pormg_debug


# Date Part Wrappers
function YEAR(column::String, format::Dict{String,Any}, conn::Union{PormGPostgres,PormGSQLite})
  return EXTRACT(column, Dict{String,Any}("part" => "YEAR"), conn)
end
function MONTH(column::String, format::Dict{String,Any}, conn::Union{PormGPostgres,PormGSQLite})
  return EXTRACT(column, Dict{String,Any}("part" => "MONTH"), conn)
end
function DAY(column::String, format::Dict{String,Any}, conn::Union{PormGPostgres,PormGSQLite})
  return EXTRACT(column, Dict{String,Any}("part" => "DAY"), conn)
end
# #562 — `@date` is the one transform whose two resolution ladders did not merely differ in
# spelling: one of them was wrong. `CAST(col AS DATE)` applies NUMERIC affinity on SQLite, because
# `DATE` is a declared type name containing none of the affinity keywords (`INT`, `CHAR`, `CLOB`,
# `TEXT`, `BLOB`, `REAL`, `FLOA`, `DOUB`), so a stored `'2026-04-07T21:30:23.741+00:00'` came back
# as the INTEGER `2026` — the year, silently, both projected and compared. Measured on SQLite
# 3.53.4.
#
# PostgreSQL keeps the real cast: `date` is a type there and `(col)::date` yields one. SQLite gets
# `strftime`, which is what the string ladder already emitted and what `format_date_sql` parses back
# — so both engines now read back a `Date`, which is also Django's `__date` contract (`TruncDate`
# returns a `datetime.date`, not text).
function DATE(column::String, format::Dict{String,Any}, conn::PormGPostgres)
  return CAST(column, Dict{String,Any}("type" => "date"), conn)
end
function DATE(column::String, format::Dict{String,Any}, conn::PormGSQLite)
  return "strftime('%Y-%m-%d', $(column))"
end
function Y_M(column::String, format::Dict{String,Any}, conn::Union{PormGPostgres,PormGSQLite})
  return EXTRACT_DATE(column, Dict{String,Any}("format" => "YYYY-MM"), conn)
end
# #571 — the PostgreSQL date-part arms cast to `integer`. `EXTRACT(...)` is `numeric` on
# PostgreSQL ≥ 14 (it was `double precision` before), which LibPQ delivers as a `Decimal`, while
# the SQLite arms below are integer-valued (`CAST(... AS INTEGER)` / integer division). Same value,
# two Julia types per engine — the one divergence inside the `Dialect` ladder that #562's collapse
# could not fix. `::integer` rather than `::bigint` on purpose: it is what a PostgreSQL `IntegerField`
# already reads back as, and it matches Django's `Extract.output_field = IntegerField()`.
function QUARTER(column::String, format::Dict{String,Any}, conn::PormGPostgres)
  return "EXTRACT(QUARTER FROM $(column))::integer"
end
function QUARTER(column::String, format::Dict{String,Any}, conn::PormGSQLite)
  return "((strftime('%m', $(column)) - 1) / 3) + 1"
end
function QUADRIMESTER(column::String, format::Dict{String,Any}, conn::PormGPostgres)
  # `numeric / 4.0` is `numeric` and `CEIL(numeric)` is `numeric` — the cast goes outside CEIL.
  return "CEIL(EXTRACT(MONTH FROM $(column)) / 4.0)::integer"
end
function QUADRIMESTER(column::String, format::Dict{String,Any}, conn::PormGSQLite)
  return "((strftime('%m', $(column)) - 1) / 4) + 1"
end

# #527 — the SQL-side image of `DATETIME_FORMAT` (#79, `constants.jl`), for SQLite.
#
# SQLite's own `datetime(...)` emits `YYYY-MM-DD HH:MM:SS`, but a `DateTimeField` stores what
# `Models.format_timezone_sql` produces — `YYYY-MM-DDTHH:MM:SS.sss+00:00` — and SQLite compares TEXT
# lexicographically. A space (0x20) sorts below `T` (0x54), so a `datetime()`-wrapped value is
# ALWAYS less than the same instant in canonical form: `=` never matches and `<`/`>` are
# systematically biased rather than occasionally wrong. Worse on the write side — an
# `update("ts" => F("ts") + Day(1))` persisted that string into the column, after which the read
# path (`_parse_sqlite_datetime`, which anchors on the `T`) silently returned a `String` instead of
# a `ZonedDateTime`.
#
# `%f` is SQLite's `SS.SSS`, so this mask is a character-for-character image of
# `"yyyy-mm-ddTHH:MM:SS.ssszzzz"` with the zone pinned to UTC — which is honest, because every
# PormG write path canonicalizes to UTC through `Models.validate_timezone` first. Rendering date
# arithmetic through it makes the expression's OUTPUT directly comparable to every stored value,
# so wrapper and bind agree by construction instead of needing the counterpart operand wrapped at
# each of the (many) comparison sites.
#
# Derived from the `date_format_map` row for the same spelling (#569), not restated. #527 had to
# introduce this as a NEW constant because that map then spelled the mask `"%Y-%m-%dT%H:%M:%S.%f"`
# — `%f` already carries the seconds, so it rendered `…:09.09.000` — and reusing it would have
# inherited the defect. #569 fixed the map on both engines, so the canonical timestamp mask now has
# ONE owner: the row `ToChar` renders and the row date arithmetic canonicalizes through are the
# same string, and the `+00:00` suffix is the only thing this constant adds.
#
# The `date(...)` sibling is deliberately NOT changed: its output already equals what
# `Models.format_date_sql` produces for a `DateField`, so there is nothing to reconcile.
const SQLITE_CANONICAL_DATETIME_MASK = "'" * date_format_map["YYYY-MM-DDTHH:MI:SS.SSS"].sqlite * "+00:00'"

"""
    _sqlite_canonical_datetime(expr, modifiers) -> String

Render a SQLite timestamp-valued expression in PormG's canonical UTC form (#527).

`modifiers` are already-rendered `strftime`/`datetime` modifier arguments (e.g.
`"'+' || ? || ' days'"`); pass none to canonicalize `expr` on its own.

The emitted `SQLITE_CANONICAL_DATETIME_MASK` literal doubles as the **marker** that says "this text
is already canonical". Sniffing a bare `strftime(` would not work — `QUARTER`, `QUADRIMESTER`,
`EXTRACT_DATE` and `EXTRACT` above all emit that too, and none of them yields a timestamp.
"""
function _sqlite_canonical_datetime(expr::AbstractString, modifiers::Vector{String} = String[])
  isempty(modifiers) && return "strftime($(SQLITE_CANONICAL_DATETIME_MASK), $(expr))"
  return "strftime($(SQLITE_CANONICAL_DATETIME_MASK), $(expr), $(join(modifiers, ", ")))"
end


# A naive timestamp, with or without the `T`, with an optional fraction. Used only by the fallback
# arm of `_parse_sqlite_timestamp` below — the canonical form with its offset is handled by
# `normalize_sqlite_datetime_string`.
#
# #612: this const used to sit BETWEEN the docstring below and the function that docstring
# describes, which detached it — and, worse, would have attached `_parse_sqlite_timestamp`'s
# documentation to this regex had the comment alone been hoisted.
const _SQLITE_NAIVE_TS = r"^(\d{4}-\d{2}-\d{2})[T ](\d{2}:\d{2}:\d{2})(?:\.(\d{1,3})\d*)?$"

"""
    _parse_sqlite_timestamp(v) -> Union{ZonedDateTime, DateTime, typeof(v)}

Parse SQLite's stored text for a timestamp back into a Julia temporal type — the READ half of the
representation `SQLITE_CANONICAL_DATETIME_MASK` above renders and `Models.format_timezone_sql`
writes.

It lives here, next to that mask, for the reason #564 exists: the write format, the SQL rendering of
it and the parse of it are one convention, and while they sat in three files nothing made them agree.
`PormG.value_parser(::CDateTime, ::PormGSQLite)` is what names this as the third slot of the pair.

PostgreSQL needs no equivalent: LibPQ delivers a `ZonedDateTime` natively.

- a string carrying a timezone offset -> `ZonedDateTime`
- a naive ISO 8601 string -> `DateTime`
- a non-string, or a string in no shape it recognises -> returned **unchanged**

That last rule is what makes a wrong caller harmless rather than lossy: handed the integer `2031`
that `CAST(col AS DATE)` yields on SQLite, or text in a representation nothing here wrote, it hands
it straight back rather than guessing.
"""
function _parse_sqlite_timestamp(v::Any)
    v isa AbstractString || return v
    normalized = normalize_sqlite_datetime_string(v)
    # Timezone-aware form first (e.g. "2026-04-07T18:30:23.741-03:00") — the canonical one.
    try
      return ZonedDateTime(normalized, dateformat"yyyy-mm-ddTHH:MM:SS.ssszzzz")
    catch e
      (e isa InterruptException || e isa StackOverflowError) && rethrow()
    end
    # Fall back to a naive datetime. MATCH FIRST, then parse.
    #
    # This used to slice the RAW `v` by byte — `v[1:min(19, length(v))]` — which assumes an ASCII,
    # `T`-separated prefix in exactly the arm that fires for a string
    # `normalize_sqlite_datetime_string` did NOT recognise. On a multi-byte value that is a
    # `StringIndexError`, and the bare `catch` it sat behind swallowed it. Matching a shape before
    # parsing removes the assumption, and accepts the space-separated form as a side effect.
    m = match(_SQLITE_NAIVE_TS, normalized)
    m === nothing && return v
    frac = m[3] === nothing ? "000" : rpad(m[3], 3, '0')
    try
      return DateTime("$(m[1])T$(m[2]).$(frac)", dateformat"yyyy-mm-ddTHH:MM:SS.sss")
    catch e
      (e isa InterruptException || e isa StackOverflowError) && rethrow()
      return v
    end
end

"""
    _parse_sqlite_date(v) -> Union{Date, typeof(v)}

The READ half of `Models.format_date_sql` on SQLite — `"2031-07-04"` back into a `Date`.

Deliberately refuses a timestamp string rather than truncating it. A `CDate`-kinded expression that
produced one means the render side mistyped it, and silently taking the date part would hide exactly
the class of defect #564 exists to surface.
"""
function _parse_sqlite_date(v::Any)
    v isa AbstractString || return v
    occursin(r"^\d{4}-\d{2}-\d{2}$", v) || return v
    try
      return Date(v)
    catch e
      (e isa InterruptException || e isa StackOverflowError) && rethrow()
      return v                                   # a well-shaped but impossible date (2023-02-29)
    end
end

"""
    _parse_sqlite_time(v) -> Union{Time, typeof(v)}

The READ half of `TimeField`'s formatter on SQLite. `TimeField` has no dedicated formatter — it
rides `Models.format_text_sql(::Time)`, which is `string(::Time)`, an exact inverse of
`Time(::String)`. That formatter is left alone: changing it would be a write-side behaviour change
this table has no mandate for.
"""
function _parse_sqlite_time(v::Any)
    v isa AbstractString || return v
    occursin(r"^\d{1,2}:\d{2}(:\d{2}(\.\d{1,9})?)?$", v) || return v
    try
      return Time(v)
    catch e
      (e isa InterruptException || e isa StackOverflowError) && rethrow()
      return v
    end
end

# `HH:MM:SS` with an optional fraction and an optional leading sign — the shape
# `Models._duration_nanoseconds_to_string` writes.
const _SQLITE_INTERVAL = r"^([+-]?)(\d+):(\d{2}):(\d{2})(?:\.(\d{1,9}))?$"

"""
    _parse_sqlite_interval(v) -> Union{Dates.CompoundPeriod, typeof(v)}

The READ half of `Models.format_duration_sql` on SQLite.

Reconstructed from the SAME units the writer emits — hours, minutes, seconds, nanoseconds — so the
two are literal inverses. NOT `Dates.canonicalize`, which would roll hours up into days and weeks
while the writer caps at hours: the round trip would not close, and `format_duration_sql` would then
write something different from what it read.

`CompoundPeriod <: Dates.AbstractTime`, which is the type parity PostgreSQL's driver already
delivers for an INTERVAL column.
"""
function _parse_sqlite_interval(v::Any)
    v isa AbstractString || return v
    m = match(_SQLITE_INTERVAL, strip(v))
    m === nothing && return v
    sign  = m[1] == "-" ? -1 : 1
    nanos = m[5] === nothing ? 0 : parse(Int, rpad(m[5], 9, '0'))
    try
      return Dates.CompoundPeriod(Hour(sign * parse(Int, m[2])), Minute(sign * parse(Int, m[3])),
                                  Second(sign * parse(Int, m[4])), Nanosecond(sign * nanos))
    catch e
      (e isa InterruptException || e isa StackOverflowError) && rethrow()
      return v
    end
end


# `ToChar` (#569). The user-facing format is a key of `date_format_map` (`constants.jl`), which
# carries one spelling PER ENGINE — the keys only look like `to_char` templates (`HH` is 12-hour
# there, `T` before `H` is the `TH` ordinal suffix, `SSS` is not a pattern), so the PostgreSQL arm
# must translate too, not pass the key through.
#
# PostgreSQL: a key renders its `postgres` template; anything else is passed through as a native
# `to_char` template (the documented PostgreSQL-only escape for patterns the map does not carry),
# with the quote escaped so the format can never close the SQL literal it is written into.
function EXTRACT_DATE(column::String, format::Dict{String,Any}, conn::PormGPostgres)
  format_str = format["format"]
  entry = get(date_format_map, format_str, nothing)
  template = entry === nothing ? replace(format_str, "'" => "''") : entry.postgres
  return "to_char($(column), '$(template)')"
end
# SQLite: only a key renders — `strftime` has no way to spell an arbitrary `to_char` template, so
# an unknown format is a capability the backend lacks, named with the formats it does have. Before
# #569 this was a bare `KeyError` from the map lookup, outside the #231 taxonomy.
function EXTRACT_DATE(column::String, format::Dict{String,Any}, conn::PormGSQLite)
  format_str = format["format"]
  entry = get(date_format_map, format_str, nothing)
  if entry === nothing
    supported = join(sort(collect(keys(date_format_map))), ", ")
    throw(BackendCapabilityError("ToChar: format \"$(format_str)\" is not supported on SQLite. Supported formats: $(supported)"))
  end
  return "strftime('$(entry.sqlite)', $(column))"
end

function SUM(column::String, format::Dict{String,Any}, conn::PormGPostgres)
  if get(format, "distinct", false)
    return "SUM(DISTINCT $(column))"
  else
    return "SUM($(column))"
  end
end

function SUM(column::String, format::Dict{String,Any}, conn::PormGSQLite)
  if get(format, "distinct", false)
    return "SUM(DISTINCT $(column))"
  else
    return "SUM($(column))"
  end
end

function AVG(column::String, format::Dict{String,Any}, conn::PormGPostgres)
  if get(format, "distinct", false)
    return "AVG(DISTINCT $(column))"
  else
    return "AVG($(column))"
  end
end

function AVG(column::String, format::Dict{String,Any}, conn::PormGSQLite)
  if get(format, "distinct", false)
    return "AVG(DISTINCT $(column))"
  else
    return "AVG($(column))"
  end
end

function COUNT(column::String, format::Dict{String,Any}, conn::PormGPostgres)
  if get(format, "distinct", false)
    return "COUNT(DISTINCT $(column))"
  else
    return "COUNT($(column))"
  end
end

function COUNT(column::String, format::Dict{String,Any}, conn::PormGSQLite)
  if get(format, "distinct", false)
    return "COUNT(DISTINCT $(column))"
  else
    return "COUNT($(column))"
  end
end

function MAX(column::String, format::Dict{String,Any}, conn::PormGPostgres)
  return "MAX($(column))"
end

function MAX(column::String, format::Dict{String,Any}, conn::PormGSQLite)
  return "MAX($(column))"
end

function MIN(column::String, format::Dict{String,Any}, conn::PormGPostgres)
  return "MIN($(column))"
end

function MIN(column::String, format::Dict{String,Any}, conn::PormGSQLite)
  return "MIN($(column))"
end

const SQLITE_WINDOW_MIN_VERSION = 3025000

function _assert_sqlite_window_support(conn::PormGSQLite)
  version_number = backend_sqlite_version(conn)
  if version_number < SQLITE_WINDOW_MIN_VERSION
    # Reconstruct M.mm.pp from the packed version integer (e.g. 3039000 -> "3.39.0").
    major, rem = divrem(version_number, 1_000_000)
    minor, patch = divrem(rem, 1_000)
    throw(BackendCapabilityError("SQLite window functions require SQLite >= 3.25.0; current SQLite library is $major.$minor.$patch."))
  end
  return nothing
end

function _window_no_column(function_name::String, over_sql::String)
  return "$(function_name)() OVER ($(over_sql))"
end

function _window_column(function_name::String, column::String, over_sql::String)
  return "$(function_name)($(column)) OVER ($(over_sql))"
end

function _window_offset(function_name::String, column::String, over_sql::String, kwargs::Dict{String,Any})
  args = String[column]
  haskey(kwargs, "offset") && push!(args, string(kwargs["offset"]))
  haskey(kwargs, "default") && push!(args, string(kwargs["default"]))
  return "$(function_name)($(join(args, ", "))) OVER ($(over_sql))"
end

RANK(over_sql::String, conn::PormGPostgres) = _window_no_column("RANK", over_sql)
function RANK(over_sql::String, conn::PormGSQLite)
  _assert_sqlite_window_support(conn)
  return _window_no_column("RANK", over_sql)
end

DENSE_RANK(over_sql::String, conn::PormGPostgres) = _window_no_column("DENSE_RANK", over_sql)
function DENSE_RANK(over_sql::String, conn::PormGSQLite)
  _assert_sqlite_window_support(conn)
  return _window_no_column("DENSE_RANK", over_sql)
end

ROW_NUMBER(over_sql::String, conn::PormGPostgres) = _window_no_column("ROW_NUMBER", over_sql)
function ROW_NUMBER(over_sql::String, conn::PormGSQLite)
  _assert_sqlite_window_support(conn)
  return _window_no_column("ROW_NUMBER", over_sql)
end

LAG(column::String, over_sql::String, kwargs::Dict{String,Any}, conn::PormGPostgres) = _window_offset("LAG", column, over_sql, kwargs)
function LAG(column::String, over_sql::String, kwargs::Dict{String,Any}, conn::PormGSQLite)
  _assert_sqlite_window_support(conn)
  return _window_offset("LAG", column, over_sql, kwargs)
end

LEAD(column::String, over_sql::String, kwargs::Dict{String,Any}, conn::PormGPostgres) = _window_offset("LEAD", column, over_sql, kwargs)
function LEAD(column::String, over_sql::String, kwargs::Dict{String,Any}, conn::PormGSQLite)
  _assert_sqlite_window_support(conn)
  return _window_offset("LEAD", column, over_sql, kwargs)
end

FIRST_VALUE(column::String, over_sql::String, conn::PormGPostgres) = _window_column("FIRST_VALUE", column, over_sql)
function FIRST_VALUE(column::String, over_sql::String, conn::PormGSQLite)
  _assert_sqlite_window_support(conn)
  return _window_column("FIRST_VALUE", column, over_sql)
end

LAST_VALUE(column::String, over_sql::String, conn::PormGPostgres) = _window_column("LAST_VALUE", column, over_sql)
function LAST_VALUE(column::String, over_sql::String, conn::PormGSQLite)
  _assert_sqlite_window_support(conn)
  return _window_column("LAST_VALUE", column, over_sql)
end

NTH_VALUE(column::String, n::Integer, over_sql::String, conn::PormGPostgres) = "NTH_VALUE($(column), $(n)) OVER ($(over_sql))"
function NTH_VALUE(column::String, n::Integer, over_sql::String, conn::PormGSQLite)
  _assert_sqlite_window_support(conn)
  return "NTH_VALUE($(column), $(n)) OVER ($(over_sql))"
end

# #696 — a SQL type name is a keyword position, like #691's `EXTRACT` field: it cannot be a bind
# parameter, so `Cast(x, type)` and every `output_field=` string used to reach the SQL verbatim —
# `Cast(x, "int); DROP TABLE race; --")` on both engines. The grammar below is deliberately narrow.
# A name is ONE identifier, or one of the closed multi-word spellings here: "letters and spaces" is
# not safe, because `integer OR TRUE` carries no `;` or `--` and still rewrites a `WHERE`.
const _CAST_MULTIWORD_TYPES = (
  "double precision", "character varying", "bit varying", "integer unsigned",
  "timestamp with time zone", "timestamp without time zone",
  "time with time zone", "time without time zone",
)
# name words · optional `(n)` / `(n, m)`, then trailing words only after it (`timestamp(3) with time
# zone`) · `[]`s. Every repeat is possessive and the trailing words hang off the modifier, so no two
# groups can share a word: a failing match is linear, not the O(n²) backtrack that PCRE aborts with
# `match limit exceeded` — an `ErrorException`, outside the `PormGError` taxonomy (#239).
const _CAST_TYPE_RE = r"^\s*+([A-Za-z_][A-Za-z0-9_]*+(?:\s++[A-Za-z_][A-Za-z0-9_]*+)*+)\s*+(?:\(\s*+(\d++)\s*+(?:,\s*+(\d++)\s*+)?\)((?:\s++[A-Za-z_][A-Za-z0-9_]*+)*+))?\s*+((?:\[\s*+\d*+\s*+\]\s*+)*+)$"
# The longest real spelling (`timestamp without time zone(6)[]`) is about 35 characters.
const _CAST_TYPE_MAX_LENGTH = 128

# `(name, suffix)`: the validated name words (single-spaced, caller's case) and the rebuilt
# modifier / trailing words / array suffix, or `InvalidValueError`. Split so each engine can map the
# NAME through its reverse type map and keep the suffix — `BLOB[]` is `bytea[]` on PostgreSQL.
function _parse_cast_type(type::AbstractString, context::AbstractString)
  # `String` first: `match` refuses any other `AbstractString` (a `LazyString`, #603's probes).
  s = String(type)
  m = isascii(s) && ncodeunits(s) <= _CAST_TYPE_MAX_LENGTH ? match(_CAST_TYPE_RE, s) : nothing
  if m !== nothing
    head = join(split(m.captures[1]), " ")
    tail = m.captures[4] === nothing || isempty(m.captures[4]) ? "" : " " * join(split(m.captures[4]), " ")
    name = lowercase(head * tail)
    # Words after a modifier are only the `with/without time zone` of `timestamp(3) with time zone`,
    # after a one-word name. `Base.` because `Dialect.endswith` is the SQL renderer.
    valid = isempty(tail) ? (!occursin(' ', head) || name in _CAST_MULTIWORD_TYPES) :
                            (!occursin(' ', head) && name in _CAST_MULTIWORD_TYPES && Base.endswith(name, "time zone"))
    if valid
      mod = m.captures[2] === nothing ? "" :
            m.captures[3] === nothing ? "($(m.captures[2]))" : "($(m.captures[2]),$(m.captures[3]))"
      arr = join("[$(b.captures[1])]" for b in eachmatch(r"\[\s*(\d*)\s*\]", m.captures[5]))
      return head, mod * tail * arr
    end
  end
  # The caller's text may be request input: `repr` escapes it, and a long one is cut to its start.
  shown = ncodeunits(s) <= 64 ? repr(s) : repr(first(s, 48)) * "… ($(length(s)) characters)"
  throw(InvalidValueError("$(context): $(shown) is not an accepted SQL type name. Accepted: a single " *
                          "identifier (integer, bigint, text, timestamptz, …) or one of " *
                          join(_CAST_MULTIWORD_TYPES, ", ") *
                          "; optionally followed by a size (n) or (n, m) and, on PostgreSQL, array brackets []. " *
                          "A field object such as IntegerField() is accepted too."))
end

"""
    cast_type_name(type; context = "Cast") -> String

The validated spelling of a SQL type name for `Cast` and `output_field=`, or `InvalidValueError`
(#696). Accepts one identifier (`integer`, `timestamptz`, `mood`) or one of
`_CAST_MULTIWORD_TYPES`, an optional `(n)` / `(n, m)` modifier and optional `[]` array suffixes,
at most `_CAST_TYPE_MAX_LENGTH` characters.

The result is rebuilt from the parsed pieces, never the caller's text, and keeps the caller's case.
ASCII-only for `extract_part`'s reason: a Unicode fold can turn a look-alike into a keyword.
`context` names the argument in the error message.
"""
function cast_type_name(type::AbstractString; context::AbstractString = "Cast")
  name, suffix = _parse_cast_type(type, context)
  return name * suffix
end

# The map is consulted only for an UNSIZED name: a map value is an alias of its key, not of the key
# with a size — PostgreSQL's `DOUBLE_PRECISION => float` becomes `float(3)`, which is `real`.
# (`Base.` — `Dialect.startswith` is the SQL renderer. Typed, or the #604 reflection guard in
# `test_operators.jl` reads an untyped 3-arg function as an undeclared text-lookup renderer.)
_map_cast_name(map::AbstractDict, name::AbstractString, suffix::AbstractString) = Base.startswith(suffix, "(") ? name : get(map, uppercase(name), name)

"""
    cast_type_sql(type, conn) -> String

`cast_type_name(type)` in the engine's spelling (#696): an unsized name the engine's reverse type map knows
(a field struct's canonical `type`, e.g. `BLOB`) renders as that map's value, with an array suffix
kept — on PostgreSQL that is what turns `Cast(x, BinaryField())` into `::bytea`
instead of the nonexistent `::BLOB` — and any other validated name renders as validated. SQLite has
no array types, so a `[]` suffix raises `BackendCapabilityError` there.
"""
function cast_type_sql(type::AbstractString, conn::PormGPostgres; context::AbstractString = "Cast")
  name, suffix = _parse_cast_type(type, context)
  return _map_cast_name(postgres_type_map_reverse, name, suffix) * suffix
end
function cast_type_sql(type::AbstractString, conn::PormGSQLite; context::AbstractString = "Cast")
  name, suffix = _parse_cast_type(type, context)
  occursin('[', suffix) && throw(BackendCapabilityError("$(context): SQLite has no array types; $(repr(name * suffix)) is PostgreSQL-only."))
  return uppercase(_map_cast_name(sqlite_type_map_reverse, name, suffix) * suffix)
end

# A window frame clause (#713) is SQL grammar, not a value, so it cannot be a bind parameter — the
# #691 / #696 defect class a third time. `WindowOver(frame=)` used to write the caller's string into
# `OVER (...)` after nothing but a `strip`. The grammar is PostgreSQL's `frame_clause`, with the
# offsets narrowed to literals PormG can re-spell: a non-negative integer, and — under RANGE only,
# where the offset is measured in the ORDER BY column's own type — a decimal or `INTERVAL '<n> <unit>'`.
#
# Tokenized rather than one regex: each token class is a closed spelling, and any other character
# becomes a token of its own that no rule accepts, so there is nothing to backtrack over (#696's
# `match limit exceeded` lesson). Every repeat is possessive for the same reason.
const _FRAME_TOKEN_RE = r"'[^']*+'|[A-Za-z]++|\d++(?:\.\d++)?+|\S"
const _FRAME_INTERVAL_RE = r"^'\s*+(\d++)\s++([a-z]++)\s*+'$"
const _FRAME_INTERVAL_UNITS = ("microsecond", "millisecond", "second", "minute", "hour", "day", "week", "month", "year")
# The longest real spelling — two intervals and an EXCLUDE — is about 110 characters.
const _FRAME_MAX_LENGTH = 200

"""
    window_frame_sql(frame; context = "frame") -> String

The validated spelling of a window frame clause for `WindowOver(frame=)`, or `InvalidValueError`
(#713). Accepts `ROWS`, `RANGE` or `GROUPS`, then one bound or `BETWEEN <bound> AND <bound>`, then
optionally `EXCLUDE CURRENT ROW | GROUP | TIES | NO OTHERS`. A bound is `UNBOUNDED PRECEDING`,
`<n> PRECEDING`, `CURRENT ROW`, `<n> FOLLOWING` or `UNBOUNDED FOLLOWING`, where `<n>` is a
non-negative integer — under `RANGE` also a decimal or `INTERVAL '<n> <unit>'`. Keywords are
case-insensitive; at most `_FRAME_MAX_LENGTH` ASCII characters.

PostgreSQL's own ordering rules are applied too, so a frame the server would refuse is refused
here, before any SQL exists: the start is never `UNBOUNDED FOLLOWING`, the end never
`UNBOUNDED PRECEDING`, and the end never comes before the start (a one-bound frame ends at
`CURRENT ROW`).

The result is rebuilt from the parsed pieces — upper-case keywords, single spaces — never the
caller's text. `context` names the argument in the error message.
"""
function window_frame_sql(frame::AbstractString; context::AbstractString = "frame")
  # `String` first: `match` refuses any other `AbstractString` (a `LazyString`, #603's probes).
  s = String(frame)
  function fail(why::AbstractString)
    # The caller's text may be request input: `repr` escapes it, and a long one is cut to its start.
    shown = ncodeunits(s) <= 64 ? repr(s) : repr(first(s, 48)) * "… ($(length(s)) characters)"
    throw(InvalidValueError("$(context): $(shown) is not an accepted window frame ($(why)). Accepted: " *
                            "ROWS, RANGE or GROUPS, then one bound or BETWEEN <bound> AND <bound>, " *
                            "optionally followed by EXCLUDE CURRENT ROW | GROUP | TIES | NO OTHERS. " *
                            "A bound is UNBOUNDED PRECEDING, <n> PRECEDING, CURRENT ROW, <n> FOLLOWING " *
                            "or UNBOUNDED FOLLOWING, where <n> is a non-negative integer " *
                            "(under RANGE also a decimal, or INTERVAL '<n> <unit>')."))
  end
  isascii(s) || fail("only ASCII is accepted")
  ncodeunits(s) <= _FRAME_MAX_LENGTH || fail("longer than $(_FRAME_MAX_LENGTH) characters")
  toks = String[m.match for m in eachmatch(_FRAME_TOKEN_RE, s)]
  isempty(toks) && fail("it is empty")
  # Keywords compare upper-cased; a quoted literal is only ever read through `_FRAME_INTERVAL_RE`.
  kw(k::Int) = k <= length(toks) ? uppercase(toks[k]) : ""
  # A token echoed in a reason is `repr`-escaped and cut to 24 characters, like the input above.
  near(k::Int) = k > length(toks) ? "the end of the frame" : repr(first(toks[k], 24))

  mode = kw(1)
  mode in ("ROWS", "RANGE", "GROUPS") || fail("it must start with ROWS, RANGE or GROUPS")

  # One bound at `i`: `(rank, sql, next_i)`. The rank orders the bound kinds the way PostgreSQL does
  # — every PRECEDING form 1, CURRENT ROW 2, every FOLLOWING form 3 — which is all the start/end
  # check needs. `unbounded` marks the two forms the start and the end each forbid one of.
  function bound(i::Int)
    t = kw(i)
    if t == "CURRENT"
      kw(i + 1) == "ROW" || fail("CURRENT must be followed by ROW, found $(near(i + 1))")
      return 2, "CURRENT ROW", i + 2, false
    end
    j = i + 1
    if t == "UNBOUNDED"
      offset = "UNBOUNDED"
    elseif !isempty(t) && all(isdigit, t)
      offset = t
    elseif occursin(r"^\d++\.\d++$", t)
      mode == "RANGE" || fail("a decimal offset is only accepted under RANGE")
      offset = t
    elseif t == "INTERVAL"
      mode == "RANGE" || fail("an INTERVAL offset is only accepted under RANGE")
      m = j <= length(toks) ? match(_FRAME_INTERVAL_RE, lowercase(toks[j])) : nothing
      m === nothing && fail("INTERVAL must be followed by a quoted '<n> <unit>'")
      unit = m.captures[2]
      # `Base.` because `Dialect.endswith` is the SQL renderer.
      (unit in _FRAME_INTERVAL_UNITS || (Base.endswith(unit, "s") && chop(unit) in _FRAME_INTERVAL_UNITS)) ||
        fail("the INTERVAL unit must be one of $(join(_FRAME_INTERVAL_UNITS, ", ")), singular or plural")
      offset = "INTERVAL '$(m.captures[1]) $(unit)'"
      j += 1
    else
      fail("expected a frame bound, found $(near(i))")
    end
    dir = kw(j)
    dir in ("PRECEDING", "FOLLOWING") || fail("expected PRECEDING or FOLLOWING, found $(near(j))")
    return (dir == "PRECEDING" ? 1 : 3), "$(offset) $(dir)", j + 1, offset == "UNBOUNDED"
  end

  if kw(2) == "BETWEEN"
    start_rank, start_sql, i, start_unbounded = bound(3)
    kw(i) == "AND" || fail("expected AND, found $(near(i))")
    end_rank, end_sql, i, end_unbounded = bound(i + 1)
    body = "BETWEEN $(start_sql) AND $(end_sql)"
  else
    start_rank, start_sql, i, start_unbounded = bound(2)
    # A one-bound frame ends at the current row.
    end_rank, end_unbounded = 2, false
    body = start_sql
  end
  start_rank == 3 && start_unbounded && fail("the frame start cannot be UNBOUNDED FOLLOWING")
  end_rank == 1 && end_unbounded && fail("the frame end cannot be UNBOUNDED PRECEDING")
  start_rank <= end_rank || fail(body == start_sql ? "a one-bound frame ends at CURRENT ROW, so it cannot start FOLLOWING" :
                                                      "the frame end comes before its start")

  exclusion = ""
  if kw(i) == "EXCLUDE"
    rest = kw(i + 1)
    if rest == "CURRENT" && kw(i + 2) == "ROW"
      exclusion, i = " EXCLUDE CURRENT ROW", i + 3
    elseif rest == "NO" && kw(i + 2) == "OTHERS"
      exclusion, i = " EXCLUDE NO OTHERS", i + 3
    elseif rest in ("GROUP", "TIES")
      exclusion, i = " EXCLUDE $(rest)", i + 2
    else
      fail("EXCLUDE must be followed by CURRENT ROW, GROUP, TIES or NO OTHERS")
    end
  end
  i > length(toks) || fail("unexpected $(near(i)) after the frame")
  return "$(mode) $(body)$(exclusion)"
end

function CAST(column::String, format::Dict{String,Any}, conn::PormGPostgres)
  return """($column)::$(cast_type_sql(format["type"], conn))"""
end
function CAST(column::String, format::Dict{String,Any}, conn::PormGSQLite)
  return "CAST($column AS $(cast_type_sql(format["type"], conn)))"
end
function CONCAT(column::Array{Any,1}, format::Dict{String,Any}, conn::PormGPostgres)
  return "CONCAT($(join(column, ",\n")))"
end
function CONCAT(column::Array{Any,1}, format::Dict{String,Any}, conn::PormGSQLite)
  return "($(join(column, " ||\n")))"
end
# #691 — the `EXTRACT` field list, PostgreSQL's (the superset: SQLite's eight are all in it).
# `EXTRACT(<field> FROM x)` takes a keyword, not a value, so it cannot be a bind parameter — the
# only safe way to let a caller choose it is to render a spelling from THIS table, never theirs.
# Until #691 the PostgreSQL arm wrote the caller's string verbatim, so `Extract(col, user_input)`
# was an injection surface on one engine while SQLite's arm was already fail-closed.
const PG_EXTRACT_FIELDS = (
  "CENTURY", "DAY", "DECADE", "DOW", "DOY", "EPOCH", "HOUR", "ISODOW", "ISOYEAR", "JULIAN",
  "MICROSECONDS", "MILLENNIUM", "MILLISECONDS", "MINUTE", "MONTH", "QUARTER", "SECOND",
  "TIMEZONE", "TIMEZONE_HOUR", "TIMEZONE_MINUTE", "WEEK", "YEAR",
)

"""
    extract_part(part) -> String

The canonical (upper-case) spelling of an `EXTRACT` field, or `InvalidValueError` when `part` is
not one of `PG_EXTRACT_FIELDS` (#691).

Case-blind like PostgreSQL (#684), but the fold is ASCII-only: Julia's `uppercase("ſecond")` is
`"SECOND"`, and PostgreSQL rejects that spelling. Both engine arms and the `Extract` constructor
call this, so an unknown part is refused identically everywhere — only a real field that SQLite
cannot spell reaches its `BackendCapabilityError`.
"""
function extract_part(part::AbstractString)
  up = isascii(part) ? uppercase(part) : String(part)
  up in PG_EXTRACT_FIELDS && return up
  throw(InvalidValueError("Extract: $(repr(part)) is not a date/time field. Valid fields (any case, no plural or " *
                          "abbreviated synonyms such as \"years\" or \"hr\"): " *
                          join(PG_EXTRACT_FIELDS, ", ")))
end

# #571 — parts PostgreSQL defines as fractional stay bare: a cast would be lossy, and SQLite's
# fail-closed whitelist below has no twin for any of them, so there is no parity to keep.
const _PG_EXTRACT_FRACTIONAL = ("EPOCH", "JULIAN", "MILLISECONDS", "MICROSECONDS")
function EXTRACT(column::String, format::Dict{String,Any}, conn::PormGPostgres)
  # #691 — the rendered field is the table's spelling, so no caller text reaches the SQL. The
  # 3-arg `Extract(x, part, format)` raw cast suffix is gone too: `Cast(Extract(x, part), type)`.
  up = extract_part(format["part"])
  bare = "EXTRACT($(up) FROM $(column))"
  up in _PG_EXTRACT_FRACTIONAL && return bare
  # `numeric::integer` ROUNDS (45.6 → 46) where SQLite's `%S` truncates; `trunc` keeps parity.
  up == "SECOND" && return "trunc($(bare))::integer"
  # See the note above `QUARTER` for why `::integer` and not `::bigint`.
  return "$(bare)::integer"
end
function EXTRACT(column::String, format::Dict{String,Any}, conn::PormGSQLite)
  part = format["part"]
  # #684 — case-blind like PostgreSQL, ASCII-only fold; #691 — through the shared table, so a part
  # that is no field at all raises `InvalidValueError` here exactly as on PostgreSQL, and only a
  # real field SQLite cannot spell reaches the capability error below.
  up = extract_part(part)
  strftime_format = if up == "YEAR"
    "%Y"
  elseif up == "MONTH"
    "%m"
  elseif up == "DAY"
    "%d"
  elseif up == "HOUR"
    "%H"
  elseif up == "MINUTE"
    "%M"
  elseif up == "SECOND"
    "%S"
  elseif up == "DOW"
    "%w"
  elseif up == "DOY"
    "%j"
  else
    throw(BackendCapabilityError("Unsupported extract part for SQLite: $part"))
  end

  return "CAST(strftime('$(strftime_format)', $(column)) AS INTEGER)"
end
function CASE(column::Vector{Any}, format::Dict{String,Any}, conn::PormGPostgres)
  output_field = get(format, "output_field", nothing)
  if !isnothing(output_field) && output_field != ""
    return """(CASE
    $(join(column, "\n"))
    ELSE $(format["else"])
    END)::$(cast_type_sql(output_field, conn; context = "output_field"))
    """
  else
    return """CASE
    $(join(column, "\n"))
    ELSE $(format["else"])
    END
    """
  end
end
function CASE(column::String, format::Dict{String,Any}, conn::PormGPostgres)
  return """CASE $(column) ELSE $(format["else"]) END"""
end
function CASE(column::String, format::Dict{String,Any}, conn::PormGSQLite)
  return """CASE $(column) ELSE $(format["else"]) END"""
end
function CASE(column::Vector{Any}, format::Dict{String,Any}, conn::PormGSQLite)
  resp::String = """CASE
    $(join(column, "\n"))
    ELSE $(format["else"])
    END
    """
  output_field = get(format, "output_field", nothing)
  if !isnothing(output_field) && output_field != ""
    return "CAST($resp AS $(cast_type_sql(output_field, conn; context = "output_field")))"
  else
    return resp
  end
end

function WHEN(column::String, format::Dict{String,Any}, conn::Union{PormGPostgres,PormGSQLite})
  return "WHEN $(column) THEN $(format["then"])" |> string
end

function COALESCE(columns::Vector{Any}, format::Dict{String,Any}, conn::PormGPostgres)
  sql = "COALESCE($(join(columns, ", ")))"
  output_field = get(format, "output_field", nothing)
  if !isnothing(output_field) && output_field != ""
    return "($sql)::$(cast_type_sql(output_field, conn; context = "output_field"))"
  end
  return sql
end

function COALESCE(columns::Vector{Any}, format::Dict{String,Any}, conn::PormGSQLite)
  return "COALESCE($(join(columns, ", ")))"
end

function GREATEST(columns::Vector{Any}, format::Dict{String,Any}, conn::PormGPostgres)
  return "GREATEST($(join(columns, ", ")))"
end

function GREATEST(columns::Vector{Any}, format::Dict{String,Any}, conn::PormGSQLite)
  return "MAX($(join(columns, ", ")))"
end

function LEAST(columns::Vector{Any}, format::Dict{String,Any}, conn::PormGPostgres)
  return "LEAST($(join(columns, ", ")))"
end

function LEAST(columns::Vector{Any}, format::Dict{String,Any}, conn::PormGSQLite)
  return "MIN($(join(columns, ", ")))"
end

function NULLIF(columns::Vector{Any}, format::Dict{String,Any}, conn::Union{PormGPostgres,PormGSQLite})
  return "NULLIF($(columns[1]), $(columns[2]))"
end

function LOWER(column::String, format::Dict{String,Any}, conn::Union{PormGPostgres,PormGSQLite})
  return "LOWER($(column))"
end

function UPPER(column::String, format::Dict{String,Any}, conn::Union{PormGPostgres,PormGSQLite})
  return "UPPER($(column))"
end

function LENGTH(column::String, format::Dict{String,Any}, conn::Union{PormGPostgres,PormGSQLite})
  return "LENGTH($(column))"
end

function ABS(column::String, format::Dict{String,Any}, conn::PormGPostgres)
  return "ABS(($(column))::numeric)"
end
function ABS(column::String, format::Dict{String,Any}, conn::PormGSQLite)
  return "ABS($(column))"
end

function ROUND(column::String, format::Dict{String,Any}, conn::PormGPostgres)
  precision = get(format, "precision", 0)
  # When parameterized, precision is a "?" placeholder string — always include it.
  # When it's the default (0), omit the precision argument.
  if precision isa AbstractString || precision != 0
    return "ROUND(($(column))::numeric, $(precision))"
  else
    return "ROUND(($(column))::numeric)"
  end
end

function ROUND(column::String, format::Dict{String,Any}, conn::PormGSQLite)
  precision = get(format, "precision", 0)
  if precision isa AbstractString || precision != 0
    return "ROUND($(column), $(precision))"
  else
    return "ROUND($(column))"
  end
end

function REPLACE(columns::Vector{Any}, format::Dict{String,Any}, conn::Union{PormGPostgres,PormGSQLite})
  return "REPLACE($(columns[1]), $(columns[2]), $(columns[3]))"
end

function TRIM(column::String, format::Dict{String,Any}, conn::Union{PormGPostgres,PormGSQLite})
  return "TRIM($(column))"
end

function LTRIM(column::String, format::Dict{String,Any}, conn::Union{PormGPostgres,PormGSQLite})
  return "LTRIM($(column))"
end

function RTRIM(column::String, format::Dict{String,Any}, conn::Union{PormGPostgres,PormGSQLite})
  return "RTRIM($(column))"
end

function FLOOR(column::String, format::Dict{String,Any}, conn::PormGPostgres)
  return "FLOOR(($(column))::numeric)"
end
function FLOOR(column::String, format::Dict{String,Any}, conn::PormGSQLite)
  return "FLOOR($(column))"
end

function CEIL(column::String, format::Dict{String,Any}, conn::PormGPostgres)
  return "CEIL(($(column))::numeric)"
end
function CEIL(column::String, format::Dict{String,Any}, conn::PormGSQLite)
  return "CEIL($(column))"
end

function SQRT(column::String, format::Dict{String,Any}, conn::PormGPostgres)
  return "SQRT(($(column))::numeric)"
end
function SQRT(column::String, format::Dict{String,Any}, conn::PormGSQLite)
  return "SQRT($(column))"
end

function EXP(column::String, format::Dict{String,Any}, conn::PormGPostgres)
  return "EXP(($(column))::numeric)"
end
function EXP(column::String, format::Dict{String,Any}, conn::PormGSQLite)
  return "EXP($(column))"
end

function LN(column::String, format::Dict{String,Any}, conn::PormGPostgres)
  return "LN(($(column))::numeric)"
end
function LN(column::String, format::Dict{String,Any}, conn::PormGSQLite)
  return "LN($(column))"
end

function POWER(columns::Vector{Any}, format::Dict{String,Any}, conn::PormGPostgres)
  return "POWER(($(columns[1]))::numeric, ($(columns[2]))::numeric)"
end
function POWER(columns::Vector{Any}, format::Dict{String,Any}, conn::PormGSQLite)
  return "POWER($(columns[1]), $(columns[2]))"
end

function MOD(columns::Vector{Any}, format::Dict{String,Any}, conn::PormGPostgres)
  return "MOD(($(columns[1]))::numeric, ($(columns[2]))::numeric)"
end
function MOD(columns::Vector{Any}, format::Dict{String,Any}, conn::PormGSQLite)
  return "MOD($(columns[1]), $(columns[2]))"
end

function F(column::String, format::Dict{String,Any}, conn::Union{PormGPostgres,PormGSQLite})
  # For simple field references, just return the column name
  # The actual processing is handled in QueryBuilder._get_select_query
  return column
end

# ---
# Convert PormGField to SQL column string
# ---
import PormG.Models: sIDField, sCharField, sTextField, sBooleanField, sIntegerField, sBigIntegerField, sPositiveSmallIntegerField, sPositiveIntegerField, sFloatField, sDecimalField, sDateField, sDateTimeField, sTimeField, sDurationField, sRelationalColumn, sManyToManyField, sUUIDField, sURLField, sSlugField, sJSONField, sBinaryField, sImageField

"""
    db_default_sql(field, conn) -> Union{String, Nothing}

The DDL text a field's `db_default` contributes on `conn`'s engine (#496), or `nothing` when it has
none. Raises `BackendCapabilityError` when the expression is pinned to the *other* engine.

**One resolver, and every production DDL path goes through it** — both `field_to_column` methods
(so `create_table`, both `add_field`s and `rebuild_table`) and `Migrations._column_default` on the
declared side of the diff, which is where every real `ColumnDelta` is built. That is what makes the
engine check unskippable in practice: a pinned expression cannot leak into DDL the target database
will reject.

The one seam it does not physically guard is `alter_field`, which renders `SET DEFAULT` straight off
the delta's `ExpressionDefault`. A HAND-BUILT delta therefore bypasses this function — which is
exactly what the pre-#496 unit test did to reach that branch at all. Nothing in production builds
one, but "unreachable without asking" is a statement about the call graph, not about the types.

Three shapes in, three answers out:

  * `nothing` (no slot, or unset) → `nothing`;
  * a `String` → itself. It is in `PORTABLE_DB_DEFAULTS` by construction, because the field
    constructor refuses any other bare string;
  * a `NamedTuple` → its entry for this engine. An entry of `nothing` is the deliberate
    "no database default on this engine" opt-out and yields `nothing`; a MISSING entry is the pin,
    and raises.

**SQLite parenthesises**, and this is the one intentional engine divergence in #496. SQLite's
column-`DEFAULT` grammar accepts a bare token only for its `literal-value` set — measured on 3.53.4,
`DEFAULT abs(random())` is a syntax error while `DEFAULT (abs(random()))` is accepted — so PormG adds
exactly one layer for anything outside the vocabulary. `PRAGMA table_info` then reports the text back
with that layer already stripped, which is why [`canonical_db_default`](@ref) strips outer parens:
the renderer's addition and the catalog's removal are exact inverses, and the column converges with
itself. PostgreSQL accepts both spellings and is given the text verbatim.

`BackendCapabilityError` rather than a new exception type: its documented meaning is already *"the
active backend cannot do this … the remedy is to change the request or the backend"*, which is this
case exactly.
"""
function db_default_sql(field, conn::PormGBackend)::Union{String, Nothing}
  hasfield(typeof(field), :db_default) || return nothing
  spec = getfield(field, :db_default)
  spec === nothing && return nothing

  engine = conn isa PormGPostgres ? :postgres : :sqlite
  sql = if spec isa AbstractString
    String(spec)
  elseif spec isa NamedTuple
    if !haskey(spec, engine)
      pinned = join(("$k = $(repr(String(spec[k])))" for k in keys(spec) if spec[k] !== nothing), ", ")
      throw(BackendCapabilityError(
        "db_default is pinned to $(join(keys(spec), " and ")) ($pinned) and this migration targets " *
        "$engine. PormG renders a pinned expression verbatim and will not guess a translation for " *
        "another engine — emitting it here would produce DDL $engine rejects. Add the $engine " *
        "spelling (`$engine = \"…\"`), declare that the column has no database default there " *
        "(`$engine = nothing`), or use one of the portable expressions " *
        "($(join(PORTABLE_DB_DEFAULTS, ", ")))."))
    end
    v = spec[engine]
    v === nothing && return nothing        # explicit per-engine opt-out
    String(v)
  else
    return nothing
  end

  # The vocabulary renders bare on both engines; everything else gets SQLite's required parens.
  conn isa PormGSQLite && !(uppercase(sql) in PORTABLE_DB_DEFAULTS) && return "($sql)"
  return sql
end

"""
    _format_default_sql_value(default_value, conn) -> String

Render a field's `default` as a SQL literal for `conn`'s dialect.

**A `db_default` must never reach this function.** It quotes an `AbstractString`, which is exactly
the #475 damage — `DEFAULT 'now()'` stores five characters in every row instead of calling the
function. The two are mutually exclusive at construction, and every call site asks
[`db_default_sql`](@ref) first.

Only binary payloads actually diverge, and they have no portable spelling: PostgreSQL wants
`'\\x0102'::bytea`, SQLite wants `X'0102'` (#296). Everything else delegates to the
backend-agnostic method — which must NOT be reached with a `Vector{UInt8}`, since its fallthrough
is `string(default_value)` and would emit the literal SQL text `UInt8[0x01, 0x02]`.
"""
_format_default_sql_value(default_value::AbstractVector{UInt8}, ::PormGPostgres)::String =
  "'\\x$(bytes2hex(default_value))'::bytea"
_format_default_sql_value(default_value::AbstractVector{UInt8}, ::PormGSQLite)::String =
  "X'$(bytes2hex(default_value))'"
_format_default_sql_value(default_value, ::PormGBackend) = _format_default_sql_value(default_value)

function _format_default_sql_value(default_value)
  if default_value isa AbstractString
    return "'$(replace(default_value, "'" => "''"))'"
  elseif default_value isa Bool
    return default_value ? "TRUE" : "FALSE"
  elseif default_value isa Union{DateTime, ZonedDateTime}
    # Canonicalize DateTimeField defaults to UTC (issue #79) so a DEFAULT-filled row is stored
    # in the same canonical form as explicitly-written values — otherwise a canonical equality/
    # range filter would miss the DEFAULT-filled row on SQLite (TEXT comparison).
    return "'$(format_timezone_sql(default_value))'"
  elseif default_value isa Union{Date, Time}
    return "'$default_value'"
  end

  return string(default_value)
end

"""
    _postgres_bytea_cast_expression(field_name, old_type::Union{Nothing, CanonicalType}) -> String

The `USING` expression for a column transitioning **into** `bytea` (#296).

PostgreSQL has no assignment cast to `bytea`, so a bare `ALTER … TYPE bytea` fails outright with
*"column cannot be cast automatically"*. Every app that used `BinaryField` before this change has a
`text` column today (the field rendered as `TEXT` on both backends), so this path is the normal
upgrade, not an edge case.

`convert_to(col, 'UTF8')` reinterprets the text as its UTF-8 bytes. It is total (never raises) and
NULL-preserving, and it agrees byte-for-byte with what `format_binary_sql` now writes for a
`String` — so text stored before the migration and text written after it land as the same bytes.

**It reinterprets; it does not decode.** A column holding hex or Base64 *text* becomes the bytes of
those characters, not the payload they encode. PormG cannot tell the difference, so it emits the
faithful-reinterpretation form and the upgrade log tells the operator to substitute
`decode(col, 'base64')` / `decode(col, 'hex')` in the generated migration when that is what the
column actually held. `makemigrations` writes a reviewable plan before anything runs, which is
where that substitution belongs.
"""
function _postgres_bytea_cast_expression(field_name::Union{String, Symbol}, old_type::Union{Nothing, CanonicalType})
  column_ref = "\"$(_quote_table_ddl(field_name))\""

  # #522: keyed on what the live column HOLDS (`delta.old_spec.type`) rather than on which struct the
  # reader happened to reconstruct — the text family is exactly the structs this used to list
  # (`CharField`, `TextField`, `ImageField`, `SlugField`, `URLField` all render `text`/`varchar`),
  # plus the two that rendered `text` through the `else` arm and were missed (`EmailField`,
  # `FileField`), for which a bare `::bytea` was a cast PostgreSQL refuses.
  if old_type isa Union{CText, CVarChar}
    return "convert_to($(column_ref), 'UTF8')"
  end
  # Already bytea, or a type with a real cast to it — let PostgreSQL apply its own.
  return "$(column_ref)::bytea"
end

function _postgres_interval_cast_expression(field_name::Union{String, Symbol}, old_type::Union{Nothing, CanonicalType})
  column_ref = "\"$(_quote_table_ddl(field_name))\""

  # #522: the numeric family is what the six integer/decimal structs this used to list render to.
  if old_type isa Union{CInt16, CInt32, CInt64, CFloat64, CDecimal}
    return "make_interval(secs => $(column_ref)::double precision)"
  elseif old_type isa CTime
    return "($(column_ref)::text)::interval"
  elseif old_type isa Union{CText, CVarChar}
    return "CASE " *
      "WHEN $(column_ref) IS NULL THEN NULL " *
      "WHEN $(column_ref) ~ '^[+-]?\\d+(\\.\\d+)?\$' THEN make_interval(secs => $(column_ref)::double precision) " *
      "WHEN $(column_ref) ~ '^[+-]?\\d+:\\d{2}(\\.\\d+)?\$' THEN ('00:' || $(column_ref))::interval " *
      "ELSE $(column_ref)::interval END"
  end

  return "$(column_ref)::interval"
end

function _get_column_type(field::PormGField, conn::PormGPostgres; type_map::Dict{String,String}=postgres_type_map_reverse)::String
  if field isa sIDField
    return type_map[field.type]
  elseif field isa sCharField
    max_len = hasproperty(field, :max_length) ? field.max_length : 250
    return "$(type_map[field.type])($max_len)"
  elseif field isa sTextField
    return type_map[field.type]
  elseif field isa sBooleanField
    return type_map[field.type]
  elseif field isa sIntegerField
    return type_map[field.type]
  elseif field isa sBigIntegerField
    return type_map[field.type]
  elseif field isa sPositiveSmallIntegerField
    return type_map[field.type]
  elseif field isa sPositiveIntegerField
    return type_map[field.type]
  elseif field isa sFloatField
    return type_map[field.type]
  elseif field isa sDecimalField
    max_digits = hasproperty(field, :max_digits) ? field.max_digits : 10
    decimal_places = hasproperty(field, :decimal_places) ? field.decimal_places : 2
    return "$(type_map[field.type])($max_digits, $decimal_places)"
  elseif field isa sDateField
    return type_map[field.type]
  elseif field isa sDateTimeField
    return type_map[field.type]
  elseif field isa sTimeField
    return type_map[field.type]
  elseif field isa sDurationField
    return type_map[field.type]
  elseif field isa sRelationalColumn
    # A one-to-one IS a foreign key with a UNIQUE constraint; its column is the referenced key's
    # type, exactly like `sForeignKey` (`.type` is `"BIGINT"` on both structs), which is why the two
    # share this branch. Before #408 `sOneToOneField` had no branch at ALL and fell through to the
    # `else` below, so every OneToOneField column rendered `text` — and, being neither
    # `sForeignKey` nor a `db_constraint` the SQLite CREATE TABLE path recognised, carried no
    # FOREIGN KEY clause either.
    return type_map[field.type]
  elseif field isa sUUIDField
    return type_map[field.type]
  elseif field isa sJSONField
    return type_map[field.type]
  elseif field isa sBinaryField
    # `bytea` takes no length parameter — a BinaryField's `max_length` is a BYTE bound enforced by
    # the CHECK constraint below, not by the column type (#296).
    return type_map[field.type]
  elseif field isa sURLField
    max_len = hasproperty(field, :max_length) ? field.max_length : 200
    return "$(type_map[field.type])($max_len)"
  elseif field isa sSlugField
    max_len = hasproperty(field, :max_length) ? field.max_length : 50
    return "$(type_map[field.type])($max_len)"
  else
    return "TEXT"
  end
end

function _get_column_type(field::PormGField, conn::PormGSQLite; type_map::Dict{String,String}=sqlite_type_map_reverse)::String
  sql_type = get(type_map, field.type, field.type)

  if field isa sIDField
    return sql_type # SQLite primary keys are usually INTEGER
  elseif field isa sCharField
    max_len = hasproperty(field, :max_length) ? field.max_length : 250
    return "$(sql_type)($max_len)"
  elseif field isa sTextField
    return sql_type
  elseif field isa sBooleanField
    return sql_type
  elseif field isa sIntegerField || field isa sBigIntegerField || field isa sPositiveSmallIntegerField || field isa sPositiveIntegerField
    return sql_type
  elseif field isa sFloatField
    return sql_type
  elseif field isa sDecimalField
    # Renders ANY width, deliberately: the migration compiler calls this for the live side too, and
    # an existing wide column must stay comparable. The #648 width refusal is in `field_to_column`.
    max_digits = hasproperty(field, :max_digits) ? field.max_digits : 10
    decimal_places = hasproperty(field, :decimal_places) ? field.decimal_places : 2
    return "$(sql_type)($max_digits, $decimal_places)"
  elseif field isa sDateField
    return sql_type
  elseif field isa sDateTimeField
    return sql_type
  elseif field isa sTimeField
    return sql_type
  elseif field isa sDurationField
    return sql_type
  elseif field isa sRelationalColumn
    return sql_type   # both relational types, for the reason the PostgreSQL branch above gives (#408)
  elseif field isa sUUIDField
    return sql_type
  elseif field isa sJSONField
    return sql_type
  elseif field isa sBinaryField
    # `BLOB` takes no length parameter (and SQLite would ignore one anyway — BLOB affinity means
    # no affinity). The byte bound is the CHECK constraint below (#296).
    return sql_type
  elseif field isa sURLField
    max_len = hasproperty(field, :max_length) ? field.max_length : 200
    return "$(sql_type)($max_len)"
  elseif field isa sSlugField
    max_len = hasproperty(field, :max_length) ? field.max_length : 50
    return "$(sql_type)($max_len)"
  else
    return "TEXT"
  end
end

# Positive integer fields require a non-negative CHECK on PostgreSQL and SQLite
# because neither backend has an unsigned integer type (unlike MySQL, where Django
# uses an UNSIGNED column instead of a CHECK). Centralizing the predicate here lets
# the CHECK logic generalize automatically if PormG later adds
# PositiveBigIntegerField — add the new struct type to this Union.
_requires_non_negative_check(field::PormGField)::Bool = field isa Union{sPositiveSmallIntegerField, sPositiveIntegerField}

# The non-negative CHECK clause emitted both at CREATE TABLE and when a column's
# type transitions into a positive integer field on ALTER.
_non_negative_check_clause(col_name)::String = "CHECK (\"$(_quote_table_ddl(col_name))\" >= 0)"

# BinaryField's `max_length` is a BYTE bound, and neither `bytea` nor `BLOB` accepts a length
# parameter — so unlike CharField's `varchar(n)` it can only be expressed as a CHECK (#296).
# `nothing` means unbounded, so no clause is emitted at all.
_requires_byte_length_check(field::PormGField)::Bool =
  field isa sBinaryField && getfield(field, :max_length) !== nothing

# The byte-length function diverges: PostgreSQL's `length()` on bytea would work but reads as a
# character count, so `octet_length` states the intent; SQLite has no `octet_length`, and its
# `length()` returns BYTES for a BLOB (characters only for TEXT — which is why the SQLite table
# rebuild casts legacy TEXT values to BLOB, see `alter_field`).
_byte_length_check_clause(col_name, max_length::Int, ::PormGPostgres)::String =
  "CHECK (octet_length(\"$(_quote_table_ddl(col_name))\") <= $(max_length))"
_byte_length_check_clause(col_name, max_length::Int, ::PormGSQLite)::String =
  "CHECK (length(\"$(_quote_table_ddl(col_name))\") <= $(max_length))"

# ── #648: SQLite has no exact decimal type ────────────────────────────────────────────────────────
#
# `DECIMAL(p, s)` takes NUMERIC affinity on SQLite, which converts a value AS IT IS STORED into a
# 64-bit INTEGER or a binary64 REAL. A double preserves 15 significant decimal digits (`DBL_DIG`), so
# every value a `DECIMAL(p ≤ 15, s)` column accepts survives exactly, and nothing wider is guaranteed
# to: `1.000000000000000000001` stores as the integer `1`, with no error. Write validation already
# refuses a value wider than its declaration, so refusing the wide DECLARATION is what makes every
# decimal column PormG creates on SQLite exact rather than approximately so — and it is what lets the
# SQLite read parser (`value_repr.jl`) reconstruct a `Decimal` instead of guessing one.
#
# The refusal lives here, in the SQLite `field_to_column`, and nowhere else:
#   * Every caller renders the DESIRED model — `create_table`, `add_field`, and `rebuild_table`
#     (which is also `alter_field`). The migration compiler never calls it: `column_spec` renders
#     through `_get_column_type` alone, on BOTH sides of the diff. So a live or introspected wide
#     column never throws here, and the migration that narrows one from 20 to 15 still plans.
#   * The planner renders DDL at plan time, so this fires at `makemigrations`, before any pending
#     file is written — not at `migrate`, part-way through a plan.
#   * NOT in `_get_column_type`: `Migrations._render_column_type` wraps that in a catch-all that
#     degrades to the declared type string, which would launder this refusal into a warning.
#
# `BackendCapabilityError` for `db_default_sql`'s reason: the declaration is valid — PostgreSQL's
# `numeric` is exact at any width — and it is the active backend that cannot honour it.
const SQLITE_EXACT_DECIMAL_DIGITS = 15

function _refuse_inexact_sqlite_decimal(col_name::AbstractString, field::PormGField)::Nothing
  field isa sDecimalField || return nothing
  field.max_digits <= SQLITE_EXACT_DECIMAL_DIGITS && return nothing
  throw(BackendCapabilityError(
    "DecimalField \"$(col_name)\" declares max_digits = $(field.max_digits), and SQLite has no exact " *
    "decimal type: a DECIMAL column takes NUMERIC affinity, which stores each value as a 64-bit " *
    "integer or a double and keeps only $(SQLITE_EXACT_DECIMAL_DIGITS) significant digits exactly — a " *
    "wider value is rounded or truncated as it is written, with no error. Declare max_digits <= " *
    "$(SQLITE_EXACT_DECIMAL_DIGITS), or use PostgreSQL, whose numeric type is exact at any width. " *
    "PormG re-creates every column when it rebuilds a SQLite table, so this also refuses a change " *
    "elsewhere in the same table; narrowing max_digits in that same change is enough."))
end

# ── Physical-column identity ── moved out (#507) ───────────────────────────────────────
#
# `describes_same_column` and `_column_signature` lived here: a predicate the migration planner used
# to ask whether two DIFFERENT Julia field structs materialize the same physical column (#325), built
# from the lower-cased rendered type plus the two CHECK-expressed bounds.
#
# #507 replaced them. That predicate was one of four code paths answering "same column?", each with
# its own reconciliations, and it had to refuse every relational field and every primary key outright
# because it could not express their identity — which is what left the FK/O2O pair and the
# `db_constraint = false` escape to two other branches. `Migrations.column_spec` now compiles BOTH
# sides of the diff to a `ColumnSpec` that carries the reference, the identity and the key flag, so
# there is nothing left to refuse: the pairs this used to reject are answered rather than declined.
#
# The two CHECK predicates it read — `_requires_non_negative_check` and `_requires_byte_length_check`,
# just above — stayed here. They are still the single definition of "does this column carry that
# CHECK", now shared by `field_to_column`, `alter_field` and the IR's `checks` slot.

function field_to_column(col_name::String, field::PormGField, conn::PormGPostgres; temporary_default::Any=nothing)::String
  # Resolve the physical column name (db_column when set, else the field name) — #50.
  col_name = field_db_column(field, col_name)
  # Determine the base SQL type
  base_type = _get_column_type(field, conn)

  # Build constraints
  constraints::Vector{String} = String[]
  # Primary key
  if hasproperty(field, :primary_key) && getfield(field, :primary_key)
    push!(constraints, "PRIMARY KEY")
  end

  # Unique
  field.unique && push!(constraints, "UNIQUE")
  # Nullability (default is NOT NULL if 'null' is false)
  if hasproperty(field, :null) && field.null
    push!(constraints, "NULL")
  else
    push!(constraints, "NOT NULL")
  end

  # Default value. A `db_default` (#496) is rendered VERBATIM and takes precedence: it is mutually
  # exclusive with `default` at construction, and a column that computes its own default needs no
  # temporary one for an ADD COLUMN backfill. `db_default_sql` is also where a pinned expression
  # aimed at the other engine raises, so asking it first is what keeps the check unskippable.
  db_expr = db_default_sql(field, conn)
  if db_expr !== nothing
    push!(constraints, "DEFAULT $db_expr")
  elseif field.default !== nothing || temporary_default !== nothing
    default_value = field.default !== nothing ? field.default : temporary_default
    push!(constraints, "DEFAULT $(_format_default_sql_value(default_value, conn))")
  end

  # Generated by default as identity
  if hasproperty(field, :generated) && getfield(field, :generated)
    if hasproperty(field, :generated_always) && getfield(field, :generated_always)
      push!(constraints, "GENERATED ALWAYS AS IDENTITY")
    else
      push!(constraints, "GENERATED BY DEFAULT AS IDENTITY")
    end
  end

  # Non-negative CHECK for positive integer fields. On ALTER, alter_field diffs this
  # against the old field and adds/drops the constraint so it tracks the model state.
  _requires_non_negative_check(field) && push!(constraints, _non_negative_check_clause(col_name))

  # Byte-length CHECK for a bounded BinaryField — the only way `max_length` can reach a bytea
  # column, which takes no length parameter (#296). Diffed on ALTER like the one above.
  _requires_byte_length_check(field) && push!(constraints, _byte_length_check_clause(col_name, field.max_length, conn))

  # Combine everything into a single string: "col_name base_type constraints..."
  return join(["\"$(_quote_table_ddl(col_name))\"", base_type, join(constraints, " ")], " ")
end

"""
`defer_db_default` (#496) renders the column WITHOUT its `db_default` and as nullable, for the one
caller that cannot take it: `ALTER TABLE … ADD COLUMN`.

SQLite refuses `ADD COLUMN` with a non-constant default on a table that has rows — measured on
3.53.4, `Cannot add a column with non-constant default`, for `CURRENT_TIMESTAMP` and for a
parenthesised expression alike (an EMPTY table accepts both, but the planner cannot know which it
faces and must not ask). `NOT NULL` is dropped with it, because `ADD COLUMN … NOT NULL` needs a
default to fill existing rows and the default is exactly what was just removed.

Neither omission survives the migration: `_add_new_field` queues a table rebuild behind the
`ADD COLUMN`, and the rebuild re-renders every column from the DESIRED model through this same
function with the flag OFF — so the finished table carries the real default and the real
nullability. The rows are filled in between by the backfill `UPDATE` that `_add_new_field` emits,
which is also what keeps SQLite's result equal to PostgreSQL's (there, `ADD COLUMN … DEFAULT expr`
backfills by itself).

Raises `BackendCapabilityError` for a `DecimalField` with `max_digits` above
`SQLITE_EXACT_DECIMAL_DIGITS` (15): SQLite stores it through NUMERIC affinity and cannot keep the
declared digits (#648). Every caller renders the desired model, so an existing wide column is
never refused on its own — only when PormG would create or re-create it.
"""
function field_to_column(col_name::String, field::PormGField, conn::PormGSQLite;
                         temporary_default::Any=nothing, defer_db_default::Bool=false)::String
  # Resolve the physical column name (db_column when set, else the field name) — #50.
  col_name = field_db_column(field, col_name)
  # #648: a DecimalField SQLite cannot store exactly is refused before any DDL exists.
  _refuse_inexact_sqlite_decimal(col_name, field)
  # Determine the base SQL type
  base_type = _get_column_type(field, conn)
  # #496: is this the deferred ADD COLUMN rendering? Computed before the nullability block, which
  # has to know.
  deferring = defer_db_default && db_default_sql(field, conn) !== nothing

  # Build constraints
  constraints::Vector{String} = String[]
  # Primary key
  if hasproperty(field, :primary_key) && getfield(field, :primary_key)
    if field isa sIDField
      push!(constraints, "PRIMARY KEY AUTOINCREMENT")
    else
      push!(constraints, "PRIMARY KEY")
    end
  end

  # Unique
  field.unique && push!(constraints, "UNIQUE")
  # Nullability (default is NOT NULL if 'null' is false). `deferring` forces NULL: the default that
  # would have filled existing rows is being withheld from this statement, and SQLite refuses
  # `ADD COLUMN … NOT NULL` without one. The queued rebuild restores the declared nullability.
  if (hasproperty(field, :null) && field.null) || deferring
    push!(constraints, "NULL")
  else
    push!(constraints, "NOT NULL")
  end

  # Default value. See the PostgreSQL twin above; `db_default_sql` has already added SQLite's
  # required parentheses for a non-vocabulary expression, because the grammar accepts a bare token
  # only for its `literal-value` set.
  db_expr = deferring ? nothing : db_default_sql(field, conn)
  if db_expr !== nothing
    push!(constraints, "DEFAULT $db_expr")
  elseif !deferring && (field.default !== nothing || temporary_default !== nothing)
    default_value = field.default !== nothing ? field.default : temporary_default
    push!(constraints, "DEFAULT $(_format_default_sql_value(default_value, conn))")
  end

  # Non-negative CHECK for positive integer fields. SQLite's alter_field recreates the
  # table from current model state, so this clause is re-derived automatically on ALTER.
  _requires_non_negative_check(field) && push!(constraints, _non_negative_check_clause(col_name))

  # Byte-length CHECK for a bounded BinaryField (#296) — likewise re-derived on every rebuild.
  _requires_byte_length_check(field) && push!(constraints, _byte_length_check_clause(col_name, field.max_length, conn))

  # Combine everything into a single string: "col_name base_type constraints..."
  return join(["\"$(_quote_table_ddl(col_name))\"", base_type, join(constraints, " ")], " ")
end

# ---
# Functions to create migration queries
#

# Escape an identifier for interpolation between double quotes (#59). `db_table` carries an arbitrary
# user-supplied spelling and is deliberately not shape-validated (mirroring `db_column`), so an
# embedded `"` would otherwise close the quoted identifier early. Doubling is the standard SQL escape
# on both backends. A no-op for every name that does not contain a quote.
#
# #394 widened its USE, not its rule: it is now applied to COLUMN and constraint identifiers here too,
# not only table names, because `db_column` is unvalidated for exactly the same reason `db_table` is
# and the query side escapes both (`safe_table_identifier` / `safe_column_identifier` in
# `querybuilder/sanitization.jl`). Escaping one axis and not the other just moves the DDL-vs-query
# split rather than closing it. The name is kept for continuity — it is the DDL identifier escape.
#
# NOTE for anyone adding a DDL renderer: this is applied at the interpolation site, so a NEW statement
# that writes `"$table_name"` without it is unescaped again. The functions that emit several
# statements (`alter_field`, the SQLite rebuild) escape ONCE into the local at the top for exactly
# that reason — prefer that shape over sprinkling calls.
_quote_table_ddl(table_name::AbstractString)::String = replace(String(table_name), "\"" => "\"\"")
# Several renderers declare `table_name::Union{String,Symbol}` (the planner keys its plan by Symbol),
# so accept both rather than making every call site stringify.
_quote_table_ddl(table_name::Symbol)::String = _quote_table_ddl(String(table_name))

# Quoted (#59) — table_name is rendered as given, no case fold. Previously bare/unquoted, which was
# harmless while every table name was lowercase-enforced; an unquoted mixed-case db_table would
# otherwise fold to lowercase on PostgreSQL, splitting DDL from every already-quoted query-side site.
function create_table(conn::PormGPostgres, table_name::String, columns::Vector{String})
  return """CREATE TABLE IF NOT EXISTS "$(_quote_table_ddl(table_name))" (\n  $(join(columns, ",\n  "))
    );"""
end

function create_table(conn::PormGSQLite, table_name::String, columns::Vector{String})
  return """CREATE TABLE IF NOT EXISTS "$(_quote_table_ddl(table_name))" (\n  $(join(columns, ",\n  "))
    );"""
end

# `_foreign_key_on_delete_sql` moved to `Models` (#498) and is imported at the top of this module, so
# `Dialect._foreign_key_on_delete_sql` still resolves for every existing caller. It is field
# vocabulary — the one definition of what an `on_delete` MEANS as SQL, and the value the column IR
# stores and compares (`ForeignKeyRef.on_delete`, rendered on both sides) — which is why it lives
# beside the sentinels it interprets rather than here. The include-order argument that first forced
# the move (a field-pair predicate in `Models`, `_fk_on_delete_equal`) went with that predicate in
# #522; the comment on the function in `Models.jl` carries the history.

function create_table(conn::PormGPostgres, model::PormGModel)
  columns::Vector{String} = []
  for (field_name, field) in model.fields
    field isa sManyToManyField && continue
    push!(columns, field_to_column(field_name |> string, field, conn))
  end

  return create_table(conn, model_table_name(model), columns)
end

"""
    _foreign_key_references_sql(field::PormGField; column, model) -> String

The `REFERENCES "<parent>"("<pk>") ON DELETE <action>` tail of a foreign-key declaration, for a
`field` that has already been established to be an `sRelationalColumn` with `db_constraint = true`.

Three callers, all SQLite: `create_table`, the `alter_field` table rebuild, and — since #514 — the
inline clause `add_field` attaches to an `ALTER TABLE … ADD COLUMN`. The first two hold the whole
clause and prefix their own `FOREIGN KEY ("<local column>") `, because SQLite writes those at the
table level; `add_field` writes it at the column level and so uses this tail on its own.

Extracted rather than copied a third time: the two existing renderings were already byte-identical,
and the reason they must STAY identical is convergence, not tidiness. What `add_field` emits is what
a later rebuild re-renders and what introspection reads back, so a clause that differed by so much
as a `DEFERRABLE` would make `makemigrations` propose the same column forever.

Resolvers, all preserved from the sites this replaces: the referenced parent TABLE honors `db_table`
(#59) via `fk_target_table` and is ESCAPED (#388) — an unescaped `db_table` holding a `"` closed the
identifier early, rendering `REFERENCES "Ev"il"("id")`, which is malformed SQL and a DDL-injection
seam — and the referenced parent COLUMN honors `db_column` (#50) via `fk_target_column`.
"""
function _foreign_key_references_sql(field::PormGField; column::Union{String,Symbol}, model::PormGModel)::String
  on_delete_str = _foreign_key_on_delete_sql(field.on_delete)
  target_tbl = fk_target_table(field; column = column, model = model)
  target_pk = fk_target_column(field)
  return "REFERENCES \"$(_quote_table_ddl(target_tbl))\"(\"$(_quote_table_ddl(target_pk))\") ON DELETE $on_delete_str"
end

function create_table(conn::PormGSQLite, model::PormGModel)
  columns::Vector{String} = []
  for (field_name, field) in model.fields
    field isa sManyToManyField && continue
    push!(columns, field_to_column(field_name |> string, field, conn))
  end

  # Add foreign key constraints for SQLite during CREATE TABLE
  for (field_name, field) in model.fields
    # #408: `sOneToOneField` is NOT a subtype of `sForeignKey` — both are bare `PormGField` — so an
    # `isa sForeignKey` gate silently emitted no constraint for a one-to-one. The ALTER paths in
    # `planner.jl` already gate on `hasfield(:to)` and so always covered both.
    if field isa sRelationalColumn && field.db_constraint
      # Local FK column honors db_column (#50); the referenced half is the shared tail above.
      local_col = field_db_column(field, string(field_name))
      push!(columns, "FOREIGN KEY (\"$(_quote_table_ddl(local_col))\") " *
                     _foreign_key_references_sql(field; column = field_name, model = model))
    end
  end

  return create_table(conn, model_table_name(model), columns)
end

# `if_not_exists = false` is the model-level composite path (#161). An index name is unique per
# SCHEMA on PostgreSQL (shared with tables and sequences) and per DATABASE on SQLite, so a name some
# other object already holds turns `IF NOT EXISTS` into a silent no-op — the table never gets its
# index, the next `makemigrations` plans it again, and the plan converges never. Without the clause
# the collision fails the migration loudly, inside its transaction. The single-column `db_index` path
# keeps the clause: its names carry a random suffix and cannot collide that way.
function create_index(conn::PormGPostgres, index_name::String, table_name::String, columns::Vector{String}; if_not_exists::Bool = true)
  return """CREATE INDEX $(if_not_exists ? "IF NOT EXISTS " : "")$(index_name) ON $(table_name) ($(join(columns, ", ")));"""
end

function create_index(conn::PormGSQLite, index_name::String, table_name::String, columns::Vector{String}; if_not_exists::Bool = true)
  return """CREATE INDEX $(if_not_exists ? "IF NOT EXISTS " : "")$(index_name) ON $(table_name) ($(join(columns, ", ")));"""
end

function create_unique_index(conn::PormGPostgres, index_name::String, table_name::String, columns::Vector{String}; if_not_exists::Bool = true)
  return """CREATE UNIQUE INDEX $(if_not_exists ? "IF NOT EXISTS " : "")$(index_name) ON $(table_name) ($(join(columns, ", ")));"""
end

function create_unique_index(conn::PormGSQLite, index_name::String, table_name::String, columns::Vector{String}; if_not_exists::Bool = true)
  return """CREATE UNIQUE INDEX $(if_not_exists ? "IF NOT EXISTS " : "")$(index_name) ON $(table_name) ($(join(columns, ", ")));"""
end

"""
    on_conflict_clause(action, target, set, conn) -> String

Render an `ON CONFLICT` clause for an INSERT statement (#123). `target` and `set` must be
pre-quoted physical column identifiers — quoting stays with the caller, like `create_index`.
PostgreSQL and SQLite (≥3.24) share this syntax, so one method covers both backends.

- `(:nothing, [], [])`        → `ON CONFLICT DO NOTHING`
- `(:nothing, cols, [])`      → `ON CONFLICT (cols) DO NOTHING`
- `(:update, cols, setcols)`  → `ON CONFLICT (cols) DO UPDATE SET c = EXCLUDED.c, …`
"""
function on_conflict_clause(action::Symbol, target::Vector{String}, set::Vector{String},
                            conn::Union{PormGPostgres, PormGSQLite})::String
  action in (:nothing, :update) ||
    throw(QueryBuildError("on_conflict_clause: action must be :nothing or :update, got :$action"))
  target_sql = isempty(target) ? "" : " ($(join(target, ", ")))"
  if action === :nothing
    return "ON CONFLICT$(target_sql) DO NOTHING"
  end
  isempty(target) &&
    throw(QueryBuildError("on_conflict_clause: action :update requires a non-empty conflict target"))
  isempty(set) &&
    throw(QueryBuildError("on_conflict_clause: action :update requires a non-empty set column list"))
  assignments = join(["$col = EXCLUDED.$col" for col in set], ", ")
  return "ON CONFLICT$(target_sql) DO UPDATE SET $(assignments)"
end

"""
    for_update_clause(nowait, skip_locked, no_key, conn) -> String

Render a row-level locking clause for a SELECT (#26), appended after ORDER BY / LIMIT / OFFSET.

- **PostgreSQL** → `FOR [NO KEY] UPDATE [NOWAIT | SKIP LOCKED]`.
- **SQLite** → `""`. SQLite has no row-level locking, so the clause is a silent no-op — the one
  intentional PostgreSQL/SQLite divergence for this feature (keeps `select_for_update` portable;
  see `docs/src/write/transaction.md`).

An `OF <table>` target is a deferred follow-up (it must name the query's generated FROM alias).
"""
function for_update_clause(nowait::Bool, skip_locked::Bool, no_key::Bool, conn::PormGPostgres)::String
  lock_sql = no_key ? "FOR NO KEY UPDATE" : "FOR UPDATE"
  wait_sql = nowait ? " NOWAIT" : (skip_locked ? " SKIP LOCKED" : "")
  return "$(lock_sql)$(wait_sql) \n"
end
function for_update_clause(nowait::Bool, skip_locked::Bool, no_key::Bool, conn::PormGSQLite)::String
  return ""  # SQLite: no row-level locking — silent no-op (documented divergence, #26)
end

# `table_name` is QUOTED here (#59) — the caller pre-quotes every other identifier it passes but not
# this one, which made it the last bare `ALTER TABLE` target in this file. Harmless while every table
# name was lowercase; a mixed-case `db_table` would fold to lowercase on PostgreSQL and the statement
# would target a table that does not exist.
function add_foreign_key(conn::PormGPostgres, table_name::Union{Symbol,String}, constraint_name::String, field_name::String, ref_table_name::String, ref_field_name::String; on_delete::Union{String,Nothing}=nothing)
  on_delete_clause = on_delete !== nothing ? " ON DELETE $on_delete" : ""
  return """ALTER TABLE "$(_quote_table_ddl(table_name))" ADD CONSTRAINT $constraint_name FOREIGN KEY ($field_name) REFERENCES $ref_table_name ($ref_field_name)$on_delete_clause DEFERRABLE INITIALLY DEFERRED;"""
end
# function add_foreign_key(conn::PormGPostgres, model::PormGModel, constraint_name::String, field_name::String, ref_model::PormGModel, ref_field_name::String)
#   return add_foreign_key(model.name, model.name, constraint_name, field_name, ref_model.name, ref_field_name)
# end

# ONE FRAGMENT PER CHANGED SLOT (#507 phase 2).
#
# `delta` is the whole input to every decision below: which statements are emitted comes from
# `delta.changed`, and which DIRECTION each takes (SET vs DROP NOT NULL, ADD vs DROP a CHECK,
# add-an-identity vs drop-one) comes from `delta.new_spec` / `delta.old_spec`. The fields are still
# read — but only to render TEXT a spec does not carry: a column type, a USING cast expression, a
# decimal precision. Reading a field to re-decide whether to emit something is the regression this
# change exists to prevent; #498, #504, #514 and #515 were four action sites doing exactly that.
#
# There is no allowlist and no "not implemented" warning any more. `delta.changed` is a subset of
# `COLUMN_DELTA_SLOTS` (validated by `ColumnDelta`'s constructor), so an unrenderable symbol cannot
# arrive; what used to be a runtime warning is now a closed type plus a test that walks the slot set
# and asserts each one reaches a branch here. `:reference` is the one slot with no branch, and needs
# none: a FOREIGN KEY is not part of a column ALTER on PostgreSQL, so `Migrations` plans it as DROP +
# ADD CONSTRAINT off the same slot. An empty `delta` — or one carrying only `:reference` — therefore
# returns `""`, which `_configure_order_dict_migration_plan` drops from the plan entirely. That is
# what the `_FK_IDENTITY_ATTRS` filter used to arrange by hand, one call site at a time.
function alter_field(conn::PormGPostgres, table_name::Union{Symbol,String}, field_name::Union{Symbol,String}, new_field::PormGField, delta::ColumnDelta;
                     catalog_table::Union{Symbol,String} = table_name)::String
  # Resolve to the physical column (db_column when set) so every ALTER targets the real
  # column even when called with the field-name key (e.g. the temporary-default cleanup in
  # _add_new_field). Idempotent when callers already pass the physical column (#50).
  field_name = field_db_column(new_field, string(field_name))
  # Escape ONCE here (#59) rather than at each of the ~20 `"$table_name"` interpolations below, so a
  # statement added later cannot forget it. A no-op for every name without an embedded quote.
  #
  # `raw_table_name` exists because the escaped spelling must NOT reach the four `get_constraints_*`
  # CATALOG lookups below (#394). Those query the catalog BY VALUE, so a table named `Ev"il` would be
  # looked up as `Ev""il`, match nothing and return `nothing` — and the `DROP CONSTRAINT` that
  # depends on the answer would simply never be emitted. Dropping a `unique` or a `primary_key` would
  # silently do nothing, and `makemigrations` would re-propose the same no-op on every run.
  #
  # `catalog_table` is the same idea one level up, and the table's counterpart of the live column
  # below (#615). On a table RENAME the DDL targets the NEW name — `_order_statements` runs the
  # rename first — while the catalog still holds the table under its OLD name when the plan is built,
  # so the lookups ask for `catalog_table` and the statements name `table_name`. The two are equal
  # everywhere else, which is why it defaults to `table_name`.
  raw_table_name = string(catalog_table)
  table_name = _quote_table_ddl(string(table_name))

  # THE COLUMN THE CATALOG KNOWS, which is not always the column being altered.
  #
  # Four statements below name a constraint they can only learn by ASKING the catalog — the two CHECK
  # drops, the UNIQUE drop and the PRIMARY KEY drop — because those names are the database's, not
  # PormG's. At plan time nothing has executed yet, so on a RENAME the catalog still knows the column
  # by its PRE-rename name while `field_name` above is already the post-rename one. Asking for the
  # new name returns `nothing`, and each of those statements then silently does not get emitted.
  #
  # That is not hypothetical and it is not merely a missing statement: #507 phase 2 made a rename
  # carry its column change, so a renamed `PositiveIntegerField` becoming a `TextField` emitted
  # `ALTER COLUMN … TYPE text` with the stale `>= 0` CHECK still in place — which PostgreSQL rejects,
  # for the reason the DROP-before-TYPE comment above states. Found in review, reproduced, and fixed
  # by reading the fact off the delta: `old_spec.name` IS the live column, because
  # `Migrations.column_delta` compiles the old side with `old_name`.
  #
  # The fallback covers a hand-built delta with unnamed specs (several unit tests construct one to
  # aim at a single branch); for every planner-built delta the spec name is always set.
  live_column = isempty(delta.old_spec.name) ? string(field_name) : delta.old_spec.name

  sql_statements = []

  # Non-negative CHECK constraint diffing on a type transition (Django-style).
  # PostgreSQL has no unsigned integer type, so positive integer fields are backed by a
  # CHECK (col >= 0). When the column type changes into or out of a positive integer
  # field we add or drop that CHECK so it tracks the model rather than only the original
  # CREATE TABLE. The DROP must precede the TYPE change (an incompatible cast would
  # otherwise be blocked by the stale `>= 0` clause); the ADD must follow it.
  #
  # Read off the SPECS, not off the fields. `_has_non_negative` asks the same question
  # `_requires_non_negative_check` does — `column_spec` built the spec's `checks` with that very
  # predicate — but asking the delta is what keeps this function from holding a second opinion. It
  # also narrows the trigger correctly: the gate is now `:checks`, so a transition that changes the
  # CHECK without changing the column TYPE no longer drags a redundant `ALTER … TYPE` along with it
  # (on PostgreSQL `IntegerField` and `PositiveIntegerField` both render `integer`, so that pair is
  # a checks-only delta — see the golden-plan corpus, which carries the before and after).
  checks_changed = :checks in delta
  new_needs_check = _has_non_negative(delta.new_spec)
  old_needs_check = _has_non_negative(delta.old_spec)
  if checks_changed && old_needs_check && !new_needs_check
    constraint = get_constraints_check(conn, raw_table_name, live_column)
    constraint !== nothing && push!(sql_statements, """ALTER TABLE "$table_name" DROP CONSTRAINT "$(_quote_table_ddl(constraint))";""")
  end

  # Byte-length CHECK diffing for BinaryField (#296), the `octet_length` analogue of the block
  # above. It differs in one way that matters: the clause embeds the bound, so it must also be
  # replaced when `max_length` merely CHANGES (4 → 8) with no type transition at all. Hence the
  # trigger is `:type` *or* `:max_length`, and the DROP fires whenever an old bound existed and the
  # new one differs, rather than only on the bounded → unbounded edge.
  #
  # `_byte_bound` carries the bound the CHECK enforces, so both halves of this decision come from
  # the delta. The old `[:type, :max_length]` trigger is exactly `:checks`: a bound that changes
  # changes `ByteLengthCheck`, and nothing else can.
  new_byte_bound = _byte_bound(delta.new_spec)
  old_byte_bound = _byte_bound(delta.old_spec)
  byte_bound_changed = checks_changed && new_byte_bound != old_byte_bound
  if byte_bound_changed && old_byte_bound !== nothing
    constraint = get_constraints_byte_length_check(conn, raw_table_name, live_column)
    constraint !== nothing && push!(sql_statements, """ALTER TABLE "$table_name" DROP CONSTRAINT "$(_quote_table_ddl(constraint))";""")
  end

  # DROP IDENTITY comes BEFORE the type change, and that ordering is load-bearing.
  #
  # `new_is_identity` is the SPEC's answer, and that is now the only way to get it right. Only
  # `sIDField` carries a `generated` slot, and the diff legitimately reports an identity difference
  # for a pair whose DECLARED side is any other field type: introspection force-converts every
  # non-UUID primary key to `IDField` (see the table in `migrations/importers.jl`), so a models file
  # declaring a `UUIDField` or a natural `CharField` key over a live identity column is an ordinary,
  # reachable state. Phase 1 shipped a `hasproperty(new_field, :generated)` guard here after a bare
  # field access turned out to be a `FieldError` that killed the whole `makemigrations` rather than a
  # caught comparison failure; `delta.new_spec.identity === nothing` says the same thing without the
  # guard, because `_column_identity` already asked the engine-appropriate question when it compiled
  # the spec — PostgreSQL reads `generated`, SQLite reads the renderer's `sIDField && primary_key`.
  #
  # PostgreSQL restricts an identity column to smallint / integer / bigint and enforces it DURING
  # `ALTER COLUMN … TYPE`, so retyping a live identity column to `uuid` or `varchar(n)` fails with
  # *"identity column type must be smallint, integer, or bigint"* — the later `DROP IDENTITY` never
  # gets to run. The reachable shape is a models file declaring a natural key (`UUIDField`, a
  # `CharField` code) over a column the database holds as an identity, which introspection reports
  # as `IDField` for every non-UUID primary key.
  #
  # The same statement stays AFTER the type change in the `ADD GENERATED` direction below, for the
  # mirror-image reason: a column can only BECOME an identity once it is already an integer type.
  # Same shape as the two CHECK drops above, which precede the type change for the same class of
  # reason. (drizzle-kit shipped and fixed this exact ordering bug —
  # drizzle-team/drizzle-orm#4178.)
  #
  # #523: there are THREE identity arms, not two, and the third is the one PostgreSQL refuses to let
  # you spell either of the other ways. `old_is_identity` is what discriminates them; see the
  # `SET GENERATED` block after the type change for why it needs no new comparison.
  identity_changing = :identity in delta
  new_is_identity = delta.new_spec.identity !== nothing
  old_is_identity = delta.old_spec.identity !== nothing
  if identity_changing && !new_is_identity
    push!(sql_statements, """ALTER TABLE "$table_name" ALTER COLUMN "$(_quote_table_ddl(field_name))" DROP IDENTITY;""")
  end

  # Alter column type.
  #
  # ONE gate where there were four. `:type` covers everything the old
  # `[:type, :max_length, :max_digits, :decimal_places]` list did — a `CVarChar` whose length moved,
  # a `CDecimal` whose precision or scale moved, and an outright change of `CanonicalType` are all a
  # difference in `ColumnSpec.type`, because the spec's type is parsed from the RENDERED column. The
  # statements below still read the field for their text: the spec says *that* the type changed, not
  # how PostgreSQL should be told to change it.
  if :type in delta
    if new_field isa sCharField
      max_length = hasproperty(new_field, :max_length) ? new_field.max_length : 255
      push!(sql_statements, """ALTER TABLE "$table_name" ALTER COLUMN "$(_quote_table_ddl(field_name))" TYPE VARCHAR($max_length);""")
    elseif new_field isa sDecimalField
      max_digits = hasproperty(new_field, :max_digits) ? new_field.max_digits : 10
      decimal_places = hasproperty(new_field, :decimal_places) ? new_field.decimal_places : 2
      push!(sql_statements, """ALTER TABLE "$table_name" ALTER COLUMN "$(_quote_table_ddl(field_name))" TYPE DECIMAL($max_digits, $decimal_places);""")
      # #522: the live precision is read off the delta's old spec, not off a reconstructed field.
      old_type = delta.old_spec.type
      if old_type isa CDecimal && old_type.scale !== nothing && decimal_places < old_type.scale
        @warn "The new decimal_places is less than the old decimal_places in table $(table_name) and field $(field_name)"
      end
    elseif new_field isa sTimeField
      push!(sql_statements, """ALTER TABLE "$table_name" ALTER COLUMN "$(_quote_table_ddl(field_name))" TYPE TIME USING "$(_quote_table_ddl(field_name))"::time without time zone;""")
    elseif new_field isa sDurationField
      cast_expression = _postgres_interval_cast_expression(field_name, delta.old_spec.type)
      push!(sql_statements, """ALTER TABLE "$table_name" ALTER COLUMN "$(_quote_table_ddl(field_name))" TYPE INTERVAL USING $cast_expression;""")
    elseif new_field isa sBinaryField
      # The inner `if :type in colect_not_equal` this used to carry is gone, and nothing replaced it:
      # a `BinaryField` whose `max_length` alone moved is a `:checks` delta, not a `:type` one, so it
      # never enters this branch at all. Same outcome — no redundant `TYPE bytea USING …` rewriting
      # the whole table for nothing — reached by the slot being right rather than by a second guard.
      cast_expression = _postgres_bytea_cast_expression(field_name, delta.old_spec.type)
      push!(sql_statements, """ALTER TABLE "$table_name" ALTER COLUMN "$(_quote_table_ddl(field_name))" TYPE bytea USING $cast_expression;""")
    else
      push!(sql_statements, """ALTER TABLE "$table_name" ALTER COLUMN "$(_quote_table_ddl(field_name))" TYPE $(_get_column_type(new_field, conn));""")
    end
  end

  # Add the non-negative CHECK after the type change when the column became a positive
  # integer field (see the DROP counterpart above for the rationale and ordering).
  if checks_changed && new_needs_check && !old_needs_check
    push!(sql_statements, """ALTER TABLE "$table_name" ADD $(_non_negative_check_clause(field_name));""")
  end

  # Add the byte-length CHECK after the type change, mirroring the DROP above (#296).
  if byte_bound_changed && new_byte_bound !== nothing
    push!(sql_statements, """ALTER TABLE "$table_name" ADD $(_byte_length_check_clause(field_name, new_byte_bound, conn));""")
  end

  # Set NOT NULL if specified. The spec's `nullable` IS `field.null` — `column_spec` copies it — so
  # reading it here is not a longer way to say the same thing: it is the difference between an action
  # that reads the delta and one that re-reads the struct the delta was built from.
  if :nullable in delta
    if !delta.new_spec.nullable
      push!(sql_statements, """ALTER TABLE "$table_name" ALTER COLUMN "$(_quote_table_ddl(field_name))" SET NOT NULL;""")
    else
      push!(sql_statements, """ALTER TABLE "$table_name" ALTER COLUMN "$(_quote_table_ddl(field_name))" DROP NOT NULL;""")
    end
  end

  # Set unique if specified
  if :unique in delta
    if delta.new_spec.unique
      push!(sql_statements, """ALTER TABLE "$table_name" ADD UNIQUE ("$(_quote_table_ddl(field_name))");""")
    else
      contrains = get_constraints_unique(conn, raw_table_name, live_column)
      if contrains !== nothing
        push!(sql_statements, """ALTER TABLE "$table_name" DROP CONSTRAINT "$(_quote_table_ddl(contrains))";""")
      end
    end
  end

  # Set default value if specified. The delta's `ColumnDefault` is a three-way classification (#475),
  # so this branches on the variant rather than on `!== nothing`:
  #
  #   * `LiteralDefault` — a value PormG renders, exactly as before (`_format_default_sql_value` on
  #     `.value`, which IS `field.default`).
  #   * `ExpressionDefault` — a database-side expression, emitted verbatim. Reachable since #496,
  #     which added the `db_default` slot that spells one; the branch predated it so that #496 was a
  #     pure addition to the compiler rather than a re-shaping of the renderer, and it needed no
  #     change when that landed. `.sql` is the CANONICAL form — outer parentheses stripped — which
  #     is what PostgreSQL wants here; SQLite needs a paren layer and never reaches this method
  #     (its `alter_field` rebuilds the table through `field_to_column`, which asks
  #     `db_default_sql` and gets them added). A mis-pinned expression has already raised in
  #     `Migrations._column_default` before the delta existed, so nothing here can emit DDL aimed
  #     at the wrong engine.
  #   * `NoDefault` — DROP. Note this is NOT reached for the one asymmetric case #496 introduced:
  #     a live expression default the model does not declare never enters the delta at all
  #     (`_defaults_equal`, `src/column_ir.jl`), so PormG cannot propose dropping it.
  if :default in delta
    new_default = delta.new_spec.default
    if new_default isa LiteralDefault
      default_value = _format_default_sql_value(new_default.value, conn)
      push!(sql_statements, """ALTER TABLE "$table_name" ALTER COLUMN "$(_quote_table_ddl(field_name))" SET DEFAULT $default_value;""")
    elseif new_default isa ExpressionDefault
      push!(sql_statements, """ALTER TABLE "$table_name" ALTER COLUMN "$(_quote_table_ddl(field_name))" SET DEFAULT $(new_default.sql);""")
    else
      push!(sql_statements, """ALTER TABLE "$table_name" ALTER COLUMN "$(_quote_table_ddl(field_name))" DROP DEFAULT;""")
    end
  end

  # Set primary key if specified
  if :primary_key in delta
    if delta.new_spec.primary_key
      push!(sql_statements, """ALTER TABLE "$table_name" ADD PRIMARY KEY ("$(_quote_table_ddl(field_name))");""")
    else
      contrains = get_constraints_pk(conn, raw_table_name, live_column)
      if contrains !== nothing
        push!(sql_statements, """ALTER TABLE "$table_name" DROP CONSTRAINT "$(_quote_table_ddl(contrains))";""")
      end
    end
  end

  # generated — the ADD and the SET directions; the DROP was emitted before the type change above,
  # and a column can only BECOME an identity once it is already an integer type.
  #
  # Before #507 this whole block was unreachable for a declared non-`IDField` over a live identity
  # column: the diff reported `:type` alone, so no identity statement was emitted at all, the
  # identity survived, and the same ALTER was re-proposed forever — while the bare TYPE change it
  # did emit could not have succeeded against a non-integer target anyway.
  #
  # #523: `ADD GENERATED … AS IDENTITY` is correct ONLY for a column that is not an identity yet.
  # Changing the FLAVOUR of one that already is — `BY DEFAULT` ⇄ `ALWAYS`, which is what an operator
  # produces by tightening a key so application code can no longer supply the value — is
  # `SET GENERATED { ALWAYS | BY DEFAULT }`. Emitting `ADD` there earned *"column "c" is already an
  # identity column"* and there was no third arm, so the flavour flip landed in the ADD branch and
  # every such migration failed at the server. Both directions are equally reachable: introspection
  # force-converts every non-UUID primary key to `IDField` and reads the flavour back from the
  # catalog (`attidentity` `a` = ALWAYS, `d` = BY DEFAULT), so "live is BY DEFAULT, models file says
  # ALWAYS" is an ordinary state rather than a contrived one.
  #
  # `old_is_identity` is the discriminator, and it needs no new comparison: on this backend
  # `_column_identity` returns either `nothing` or `ColumnIdentity(true, generated_always, false)`
  # (`migrations/column_spec.jl`), so slots 1 and 3 are constants and `always` is the only degree of
  # freedom two non-`nothing` PostgreSQL identities have. Both sides carrying an identity while
  # `:identity` is in the delta therefore MEANS the flavour moved.
  #
  # ONE PATH ESCAPES THAT, and it is the #69 fail-safe rather than a hole in the reasoning above:
  # `_degraded_spec` carries `identity = nothing`, so a live identity column whose old side failed to
  # COMPILE reads as a non-identity and takes the ADD arm — which PostgreSQL still refuses. That is
  # pre-#523 behaviour on a path that already warns loudly that the diff may be wrong (the `@warn` in
  # `_spec_or_degraded`, which is NOT `maxlog`-suppressed and so fires for every such column), and it
  # is a defect in whatever made the compile fail rather than here: a spec that could not be built
  # cannot be the authority on what the column already is.
  #
  # Unlike its two siblings this statement has no ordering constraint relative to the type change: it
  # neither creates nor removes an identity, so it cannot collide with PostgreSQL's
  # "identity column type must be smallint, integer, or bigint" enforcement during
  # `ALTER COLUMN … TYPE`. It sits here because this is where the identity block's ADD half already
  # was, not because the position is load-bearing.
  if identity_changing && new_is_identity
    if old_is_identity
      if delta.new_spec.identity.always
        push!(sql_statements, """ALTER TABLE "$table_name" ALTER COLUMN "$(_quote_table_ddl(field_name))" SET GENERATED ALWAYS;""")
      else
        push!(sql_statements, """ALTER TABLE "$table_name" ALTER COLUMN "$(_quote_table_ddl(field_name))" SET GENERATED BY DEFAULT;""")
      end
    elseif delta.new_spec.identity.always
      push!(sql_statements, """ALTER TABLE "$table_name" ALTER COLUMN "$(_quote_table_ddl(field_name))" ADD GENERATED ALWAYS AS IDENTITY;""")
    else
      push!(sql_statements, """ALTER TABLE "$table_name" ALTER COLUMN "$(_quote_table_ddl(field_name))" ADD GENERATED BY DEFAULT AS IDENTITY;""")
    end
  end

  # No `IMPLEMENTED` allowlist and no "are not implemented in alter_field" warning: #507 phase 2
  # deleted both, because there is nothing left for them to catch. That warning existed while this
  # function received an OPEN vocabulary of field-attribute symbols and had to say so when handed one
  # it could not render — and it was load-bearing twice (#325 for `:blank`-class attributes, #498 for
  # a re-pointed foreign key that planned nothing at all). Both causes are gone by construction:
  #
  #   * the vocabulary is CLOSED — `ColumnDelta` validates every facet against `COLUMN_DELTA_SLOTS`,
  #     so an unknown symbol cannot reach here (it raises at the delta, naming the closed set);
  #   * the two upstream FILTERS it warned around are gone with it. `NON_DB_ATTRS` still keeps
  #     model-layer attributes out of the IR, and `:reference` — the `_FK_IDENTITY_ATTRS` case —
  #     needs no filter at all, because a slot with no branch here simply renders nothing while
  #     `Migrations._fk_constraint_action` renders it as DROP + ADD CONSTRAINT.
  #
  # What replaces the warning is a test, not a promise: `test_plan_actions_golden.jl` walks
  # `COLUMN_DELTA_SLOTS` and asserts each slot either reaches a statement here or is the documented
  # `:reference` exception. A list inside a test was the old guard's shape too — and it passed while
  # this function raised, because `:generated` was ON the list and membership is not a branch. The
  # new one calls `alter_field` for every slot and reads the SQL.
  return join(sql_statements, "\n")
end

"""
    sqlite_add_column_can_inline_fk(field, temporary_default) -> Bool

Whether SQLite will accept this field's `FOREIGN KEY` as an inline `REFERENCES` clause on an
`ALTER TABLE … ADD COLUMN` (#514). `false` means the key has to arrive through a table rebuild
instead; `false` for a non-relational or `db_constraint = false` field means there is no key to add.

The predicate is SQLite's own `ALTER TABLE ADD COLUMN` rule, which is also, term for term, what
Django's SQLite schema editor tests before falling back to `_remake_table`:

  * *"If foreign key constraints are enabled and a column with a REFERENCES clause is added, the
    column must have a default value of NULL"* — hence `null` and no default, `temporary_default`
    included, since that is a real `DEFAULT` in the emitted DDL.
  * *"The column may not have a PRIMARY KEY or UNIQUE constraint"* — hence the last two. Those two
    make SQLite refuse the `ADD COLUMN` outright, foreign key or not.

`sRelationalColumn`, never a bare `isa sForeignKey`: `sOneToOneField` is a sibling struct rather
than a subtype, and four subsystems have each shipped that bug (#408, #409, #418, #437). A
one-to-one is `unique = true` and so is ineligible here anyway — but for the stated reason, not by
accident of the gate.
"""
function sqlite_add_column_can_inline_fk(field::PormGField, temporary_default::Any)::Bool
  # `db_default` disqualifies inlining for a reason the other terms only imply (#496): SQLite
  # refuses `ADD COLUMN` with a NON-CONSTANT default outright — measured on 3.53.4, a populated
  # table answers `Cannot add a column with non-constant default` for `CURRENT_TIMESTAMP` and for a
  # parenthesized expression alike, while an EMPTY table accepts both. PormG cannot know which it is
  # facing at plan time and must not ask, so any `db_default` routes through the table rebuild —
  # which is the same place this predicate's `false` already sends a column.
  # Both `sRelationalColumn` structs carry the slot, so it is read directly rather than through a
  # `hasfield` guard — the `isa` below already establishes it.
  return field isa sRelationalColumn && field.db_constraint &&
         field.null && field.default === nothing && temporary_default === nothing &&
         field.db_default === nothing &&
         !field.unique && !field.primary_key
end

# `model` is accepted and IGNORED on PostgreSQL, so the planner has one call to make rather than a
# backend branch. PostgreSQL adds its key separately and must keep doing so: `_add_constrains` emits
# a named `ALTER TABLE … ADD CONSTRAINT … DEFERRABLE INITIALLY DEFERRED`, which an inline clause here
# would duplicate.
function add_field(conn::PormGPostgres, table_name::Union{String,Symbol}, field_name::String, field::PormGField; temporary_default::Any=nothing, model::Union{PormGModel,Nothing}=nothing)
  return """ALTER TABLE "$(_quote_table_ddl(table_name))" ADD COLUMN $(field_to_column(field_name, field, conn, temporary_default=temporary_default));"""
end

# #514: SQLite can only declare a foreign key inside a `CREATE TABLE` — or, in the one case above,
# inline on the `ADD COLUMN` itself. Without this the column arrived with NO constraint at all and
# nothing said so: `field_to_column` renders no `REFERENCES` on either backend and `_add_constrains`'
# FK block is PostgreSQL-only.
#
# What happened NEXT is not what #514 assumed, and the difference is worth recording because it is
# the reason this is a correctness fix and not merely a tidiness one. #514 reasoned that
# `makemigrations` converges afterwards, so nothing would ever propose repairing the column.
# Measured on a real temp SQLite file, it does the opposite: introspection reads the constraint-less
# column back as `sIntegerField`, the declared side is still `sForeignKey`, no comparator reconciles
# that pair, and the SECOND `makemigrations` plans a whole-table rebuild — which does create the key.
# So the pre-fix behaviour was a constraint-less window followed by a surprise rebuild on a later,
# unrelated run. Both halves are gone now: the key is created by the migration that declares it, and
# nothing is left over to re-propose.
#
# When the clause cannot be inlined, this still emits the bare column and the PLANNER routes the key
# through a table rebuild — `_add_new_field` owns that decision, calling the same predicate. Passing
# `model = nothing` therefore means "caller has no model to resolve the parent from", and yields the
# pre-#514 bare column; every in-tree caller passes one.
#
# NEWLY REACHABLE THROW, stated rather than discovered later. `_foreign_key_references_sql` resolves
# the parent through `Models.fk_target_table`, which raises `ModelDefinitionError` when a key's `.to`
# is still an unresolved binding string with no `to_table` breadcrumb — the state a models file
# generated with `include_table`/`ignore_table` is left in when the parent was filtered out. This
# path never called it before and emitted a bare column instead. That is a divergence REMOVED, not
# added: PostgreSQL already raised from `_add_constrains` for the same models file, and SQLite
# silently producing a constraint-less column was the #514 bug in its purest form. It fires only for
# `db_constraint = true`, and the rebuild branch reaches the same resolver anyway.
function add_field(conn::PormGSQLite, table_name::Union{String,Symbol}, field_name::String, field::PormGField; temporary_default::Any=nothing, model::Union{PormGModel,Nothing}=nothing)
  # `defer_db_default = true` — this is the one statement SQLite will not accept a non-constant
  # default on (#496). `_add_new_field` queues the rebuild that puts it back.
  column_sql = field_to_column(field_name, field, conn, temporary_default=temporary_default,
                               defer_db_default=true)
  if model !== nothing && sqlite_add_column_can_inline_fk(field, temporary_default)
    column_sql *= " " * _foreign_key_references_sql(field; column = field_name, model = model)
  end
  return """ALTER TABLE "$(_quote_table_ddl(table_name))" ADD COLUMN $(column_sql);"""
end

function drop_field(conn::PormGPostgres, table_name::Union{String,Symbol}, field_name::Union{String,Symbol})
  return """ALTER TABLE "$(_quote_table_ddl(table_name))" DROP COLUMN "$(_quote_table_ddl(field_name))";"""
end

function drop_field(conn::PormGSQLite, table_name::Union{String,Symbol}, field_name::Union{String,Symbol})
  # Modern SQLite supports DROP COLUMN. If not, we'd need recreation.
  return """ALTER TABLE "$(_quote_table_ddl(table_name))" DROP COLUMN "$(_quote_table_ddl(field_name))";"""
end

function alter_field(conn::PormGPostgres, model::PormGModel, field_name::Union{Symbol,String}, new_field::PormGField, delta::ColumnDelta;
                     catalog_table::Union{Symbol,String} = model_table_name(model))
  return alter_field(conn, model_table_name(model), field_name, new_field, delta; catalog_table = catalog_table)
end

# SQLite alters a column by rebuilding the whole table from the DESIRED model, so it reads none of
# the arguments that describe the change: not the new field, not the delta. It keeps them because
# the planner calls one `alter_field` for both engines. The signature is the only thing #507 phase 2
# changed here, and #522 dropped the reconstructed old field from it on both engines.
#
# `rebuild_table` below is that body, reachable on its own — see the note there for why the planner
# needs both spellings.
#
# `catalog_table` is accepted for the same reason and ignored: the rebuild asks the catalog nothing
# (the index snapshot around it is `_sqlite_rebuild_preserving_indexes`' job, and that takes its own).
function alter_field(conn::PormGSQLite, model::PormGModel, field_name::Union{Symbol,String}, new_field::PormGField, delta::ColumnDelta;
                     catalog_table::Union{Symbol,String} = model_table_name(model))
  return rebuild_table(conn, model)
end

"""
    rebuild_table(conn::PormGSQLite, model) -> String

Re-create `model`'s table from the model itself: `CREATE TABLE … _new`, copy every column across,
drop the original, rename the copy into place.

This is how SQLite performs *any* schema change to an existing column, and it is what
`alter_field(::PormGSQLite, …)` returns. It is exposed separately because one planner call site is a
rebuild with **no column diff at all** — a field DELETION, where the table is re-created precisely
because the desired model no longer has that column. That site used to call `alter_field` with an
empty `Vector{Symbol}` and, in its own comment, "a representative deleted field … only to satisfy
the shared signature". Handing it a fabricated empty `ColumnDelta` instead would have been worse
than the old wart rather than better: since #507 phase 2 an empty delta means "this column did not
change, plan nothing", which is the opposite of what that call site is asking for.

The emitted SQL is identical either way — this function IS the body `alter_field` used to hold.

This is the BARE rebuild. What its `DROP TABLE` takes along and its `RENAME` trips over — the
secondary indexes (#82), the triggers on the table, and the views and other tables' triggers that
name it (#729) — is put back around it by the migration planner, which renders every rebuild once
the whole plan is known (`Migrations._finalize_sqlite_rebuilds!`).
"""
function rebuild_table(conn::PormGSQLite, model::PormGModel)
  # SQLite implementation using table recreation.
  # Escaped ONCE here (#59) — this function interpolates the name into five statements below, and
  # `new_table_name` is derived from it. A no-op for every name without an embedded quote.
  table_name = _quote_table_ddl(model_table_name(model))
  new_table_name = "$(table_name)_new"

  # 1. Define columns for the NEW table (using current model state)
  columns_defs = []
  for (f_name, f) in model.fields
    push!(columns_defs, field_to_column(f_name |> string, f, conn))
  end

  # Add foreign key constraints (local + referenced columns honor db_column — #50)
  for (f_name, f) in model.fields
    if f isa sRelationalColumn && f.db_constraint   # #408, as in `create_table`
      # Local FK column honors db_column (#50); the referenced half is `_foreign_key_references_sql`,
      # shared with `create_table` and `add_field` so all three render one clause (#514).
      local_col = field_db_column(f, string(f_name))
      push!(columns_defs, "FOREIGN KEY (\"$(_quote_table_ddl(local_col))\") " *
                          _foreign_key_references_sql(f; column = f_name, model = model))
    end
  end

  create_sql = """CREATE TABLE "$new_table_name" (
  $(join(columns_defs, ",\n  "))
);"""

  # 2. Build the INSERT column list from model.fields.
  # At execution time every ADD COLUMN statement queued before this recreation
  # has already run, so all model fields are present in the old table.
  # Reading the live database's columns at planning time would omit columns that
  # were just queued via ADD COLUMN (they are not in the live DB yet), causing a
  # NOT NULL constraint failure when the INSERT tries to populate the new table
  # from the old one — the new table's CREATE has the column as NOT NULL but the
  # INSERT simply doesn't mention it.
  # Physical column names (db_column when set) — both old and new tables use these,
  # so the column-aligned copy stays correct for db_column-mapped fields (#50).
  #
  # The INSERT targets and the SELECT expressions are built in ONE pass so they cannot drift out of
  # alignment — this is a positional column-to-column copy, and a mismatch would silently write
  # every value into the wrong column.
  #
  # BinaryField columns are cast on the SELECT side (#296). A `BLOB`-declared column has BLOB
  # affinity, which means *no* affinity — SQLite converts nothing on insert, so a plain copy would
  # leave pre-migration rows with storage class TEXT while new writes land as BLOB. SQLite.jl infers
  # a result column's Julia type from the first non-NULL row, so that mixed column reads back
  # inconsistently: whichever class comes first wins and the rest are coerced through the wrong
  # accessor (`sqlite3_column_text` on a blob truncates at the first 0x00).
  #
  # `CAST(x AS BLOB)` converts TEXT to its UTF-8 bytes — the same reinterpretation PostgreSQL's
  # `convert_to(col,'UTF8')` applies — and is a no-op on a value that is already a blob, so this
  # stays correct on every subsequent rebuild.
  insert_cols = String[]
  select_exprs = String[]
  for (k, f) in model.fields
    col = field_db_column(f, string(k))
    push!(insert_cols, "\"$(_quote_table_ddl(col))\"")
    push!(select_exprs, f isa sBinaryField ? "CAST(\"$(_quote_table_ddl(col))\" AS BLOB)" : "\"$(_quote_table_ddl(col))\"")
  end
  cols_joined = join(insert_cols, ", ")
  select_joined = join(select_exprs, ", ")

  insert_sql = """INSERT INTO "$new_table_name" ($cols_joined) SELECT $select_joined FROM "$table_name";"""

  return """DROP TABLE IF EXISTS "$new_table_name";
$create_sql;
$insert_sql;
DROP TABLE "$table_name";
ALTER TABLE "$new_table_name" RENAME TO "$table_name";"""
end

function rename_field(conn::Union{PormGSQLite,PormGPostgres}, table_name::Union{String,Symbol}, old_field_name::Union{String,Symbol}, new_field_name::Union{String,Symbol})
  return """ALTER TABLE "$(_quote_table_ddl(table_name))" RENAME COLUMN "$(_quote_table_ddl(old_field_name))" TO "$(_quote_table_ddl(new_field_name))";"""
end

# `IF EXISTS`, and it is a fix rather than defensiveness (#89). `drop_table` on PostgreSQL is
# `DROP TABLE ... CASCADE`, which also drops every FK constraint POINTING AT the dropped table --
# and `_order_statements` runs "Drop table" (bucket 2) BEFORE "Remove foreign key: ..." (bucket 5).
# So dropping a parent table and removing the child's FK field in one migration reached this
# statement with the constraint already gone, and the whole migration aborted. The ordering is
# fine; asking to drop a constraint that a CASCADE already took is what was not.
#
# Known cost, accepted: on a REPOINT the planner emits this DROP and a matching ADD under the same
# constraint name, taken from `get_constraints_fk` at plan time. If the executing session resolves
# that name differently from the planning one -- the `search_path` case `_add_fk_constraint_in_
# alteration` already documents -- the DROP used to abort the migration and now silently no-ops,
# leaving the old constraint in place beside the new one. Narrowing `IF EXISTS` to the deletion
# path would not help: the CASCADE hazard reaches the repoint path too.
function drop_foreign_key(conn::PormGPostgres, table_name::Symbol, constraint_name::String)
  return """ALTER TABLE "$(_quote_table_ddl(table_name))" DROP CONSTRAINT IF EXISTS "$(_quote_table_ddl(constraint_name))";"""
end

# NOTE (#83): there is intentionally no `drop_foreign_key(::PormGSQLite, …)`. SQLite has no
# `ALTER TABLE DROP CONSTRAINT`, so an FK is removed by rebuilding the table from the desired model
# (see `alter_field(::PormGSQLite, model, …)` + `_sqlite_rebuild_preserving_indexes`), which omits
# the FK clause. The planner's `_drop_fk_constraint_in_alteration` is therefore a no-op on SQLite.

# The CREATE side escapes the index name (`planner.jl` wraps it in `_quote_table_ddl` before handing
# it to `create_index`), so the DROP side must too (#394) — otherwise an index whose declared name
# carries a `"` is created under one spelling and dropped under another, and `IF EXISTS` hides it.
function drop_index(conn::PormGPostgres, index_name::String)
  return """DROP INDEX IF EXISTS "$(_quote_table_ddl(index_name))";"""
end
function drop_index(conn::PormGSQLite, index_name::String)
  return """DROP INDEX IF EXISTS "$(_quote_table_ddl(index_name))";"""
end

# The model-level composite diff's other three statements (#161), PostgreSQL only. SQLite has none of
# them: it cannot drop or rename a table constraint, and cannot rename an index — the planner drops
# and re-creates a bare index there, and removes a `UNIQUE (a, b)` clause by rebuilding the table.
#
# `drop_unique_constraint` is the constraint-backed half of a composite DROP: `DROP INDEX` on an index
# a constraint owns is refused ("constraint … requires it"), and the Django-adopted `unique_together`
# is exactly that shape. `IF EXISTS` for the reason `drop_foreign_key` gives above.
function drop_unique_constraint(conn::PormGPostgres, table_name::String, constraint_name::String)
  return """ALTER TABLE "$(_quote_table_ddl(table_name))" DROP CONSTRAINT IF EXISTS "$(_quote_table_ddl(constraint_name))";"""
end

# A bare index renames in place. A constraint-backed one is renamed through its constraint, which
# renames the backing index with it, so the statement names the `pg_constraint` row the reader keyed
# it by.
function rename_index(conn::PormGPostgres, old_name::String, new_name::String)
  return """ALTER INDEX "$(_quote_table_ddl(old_name))" RENAME TO "$(_quote_table_ddl(new_name))";"""
end

function rename_constraint(conn::PormGPostgres, table_name::String, old_name::String, new_name::String)
  return """ALTER TABLE "$(_quote_table_ddl(table_name))" RENAME CONSTRAINT "$(_quote_table_ddl(old_name))" TO "$(_quote_table_ddl(new_name))";"""
end

function rename_table(conn::Union{PormGSQLite,PormGPostgres}, old_table_name::String, new_table_name::String)
  return """ALTER TABLE "$(_quote_table_ddl(old_table_name))" RENAME TO "$(_quote_table_ddl(new_table_name))";"""
end

function drop_table(conn::PormGPostgres, table_name::Union{String,Symbol})
  return """DROP TABLE IF EXISTS "$(_quote_table_ddl(table_name))" CASCADE;"""
end
function drop_table(conn::PormGSQLite, table_name::Union{String,Symbol})
  return """DROP TABLE IF EXISTS "$(_quote_table_ddl(table_name))";"""
end

function alter_sequence_name(conn::PormGPostgres, old_sequence_name::String, new_sequence_name::String)
  return """ALTER SEQUENCE IF EXISTS "$old_sequence_name" RENAME TO "$new_sequence_name";"""
end

# function create_sequence(conn::PormGPostgres, sequence_name::String, start_value::Int = 1, increment_by::Int = 1, min_value::Int = 1, max_value::Int = 9223372036854775807, cache::Int = 1)
#   return """CREATE SEQUENCE IF NOT EXISTS "$sequence_name" START WITH $start_value INCREMENT BY $increment_by MINVALUE $min_value MAXVALUE $max_value CACHE $cache;"""
# end

# function drop_sequence(conn::PormGPostgres, sequence_name::String)
#   return """DROP SEQUENCE IF EXISTS "$sequence_name";"""
# end

# ---
# Function to deal with deletion objects
#

# NOTE: this function currently has NO callers anywhere in `src/` or `test/` — the live delete path
# is `querybuilder/deletion.jl`. The table identifier is resolved through `model_table_name` and
# quoted anyway (#59) so it is not left as a landmine for whoever revives it; deciding whether to
# delete it outright is out of scope for this issue.
function get_objects_to_delete(connection::PormGPostgres, model::PormGModel, instruction::SQLInstruction)::Vector{NamedTuple}
  # Get the SQL that identifies objects to be deleted
  sql_to_delete = """
    SELECT "$(get_model_pk_field(model))"
    FROM "$(_quote_table_ddl(model_table_name(model)))" as $(instruction.alias)
    $(join(instruction.join, "\n"))
    $(instruction._where |> length > 0 ? "WHERE" : "") $(join(instruction._where, " AND \n   "))
  """
  # Execute the query to get IDs of objects to delete
  @pormg_debug false
  result = fetch(connection, sql_to_delete)
  return Tables.rowtable(result)
end

# ---
# Function to deal with operators
#

_like_escape_clause() = " ESCAPE '\\'"

# ---
# #27: JSON/JSONB support
# ---

# JSON path extraction as TEXT. `segments` are pre-validated (safe identifier charset or a
# non-negative integer index) by `_validate_json_key_segments`, so interpolating them into the
# path literal is injection-safe. A numeric segment is a JSON array index.
function _json_extract_expr(::PormGPostgres, column::String, segments::Vector{String})::String
  # `#>>` takes a text[] path and returns text; a numeric element indexes an array. Non-numeric
  # keys are double-quoted so a key literally named `null`/`true`/`false` is a normal path element
  # rather than an array-literal keyword (segments are pre-validated, so no escaping is needed).
  parts = map(s -> tryparse(Int, s) === nothing ? "\"$s\"" : s, segments)
  return string(column, " #>> '{", join(parts, ","), "}'")
end
function _json_extract_expr(::PormGSQLite, column::String, segments::Vector{String})::String
  # SQLite JSONPath: numeric segment => [n] (array index); key => .key.
  path = "\$" * join(map(s -> tryparse(Int, s) === nothing ? ".$s" : "[$s]", segments))
  return string("json_extract(", column, ", '", path, "')")
end

# #602: every text-lookup renderer below takes `column::AbstractString, value::AbstractString`.
# Both are RENDERED SQL text — `column` is the quoted column expression and `value` is the bind
# placeholder (`$N` / `?`) `add_parameter!` returned — never the user's value, which is already
# bound by the time the builder dispatches here (build_helpers.jl). The wide spelling is the
# type-system contract, not a live repro: a `::String` arm beside an untyped generic sibling
# meant a non-`String` placeholder fell to the sibling and was refused for the WRONG reason
# (`InvalidValueError`, or `BackendCapabilityError` "requires PostgreSQL" *on* PostgreSQL).
# The generic `(conn::PormGAbstractType, column, value)` arm stays as the guard against a
# non-string VALUE (placeholder) reaching a renderer; a non-string column is a `MethodError`,
# exactly as before.
#
# PostgreSQL JSONB containment/overlap operators (PG-only; SQLite + abstract throw a friendly
# error, mirroring iunaccent_*). LibPQ binds `$N` placeholders, so a literal `?`/`?|`/`?&` here is
# the jsonb operator, never a bind marker. The RHS placeholder already carries any needed cast
# (`::jsonb` for @>, `::text[]` for ?|/?&) from add_parameter!.
function jcontains(conn::PormGPostgres, column::AbstractString, value::AbstractString)::String
  return "$(column) @> $(value)"                    # jsonb contains the given document
end
function jcontains(conn::PormGSQLite, column::AbstractString, value::AbstractString)
  throw(BackendCapabilityError("The @jcontains lookup (JSONB @>) requires PostgreSQL"))
end
function jcontains(conn::PormGAbstractType, column::AbstractString, value)
  throw(BackendCapabilityError("The @jcontains lookup (JSONB @>) requires PostgreSQL"))
end

function has_key(conn::PormGPostgres, column::AbstractString, value::AbstractString)::String
  return "$(column) ? $(value)"                     # top-level key exists
end
function has_key(conn::PormGSQLite, column::AbstractString, value::AbstractString)
  throw(BackendCapabilityError("The @has_key lookup (JSONB ?) requires PostgreSQL"))
end
function has_key(conn::PormGAbstractType, column::AbstractString, value)
  throw(BackendCapabilityError("The @has_key lookup (JSONB ?) requires PostgreSQL"))
end

function has_any_keys(conn::PormGPostgres, column::AbstractString, value::AbstractString)::String
  return "$(column) ?| $(value)"                    # any of the given keys exists
end
function has_any_keys(conn::PormGSQLite, column::AbstractString, value::AbstractString)
  throw(BackendCapabilityError("The @has_any_keys lookup (JSONB ?|) requires PostgreSQL"))
end
function has_any_keys(conn::PormGAbstractType, column::AbstractString, value)
  throw(BackendCapabilityError("The @has_any_keys lookup (JSONB ?|) requires PostgreSQL"))
end

function has_keys(conn::PormGPostgres, column::AbstractString, value::AbstractString)::String
  return "$(column) ?& $(value)"                    # all of the given keys exist
end
function has_keys(conn::PormGSQLite, column::AbstractString, value::AbstractString)
  throw(BackendCapabilityError("The @has_keys lookup (JSONB ?&) requires PostgreSQL"))
end
function has_keys(conn::PormGAbstractType, column::AbstractString, value)
  throw(BackendCapabilityError("The @has_keys lookup (JSONB ?&) requires PostgreSQL"))
end

function contains(conn::PormGPostgres, column::AbstractString, value::AbstractString)::String
  return "$(column) LIKE $(value)$(_like_escape_clause())"
end
function contains(conn::PormGSQLite, column::AbstractString, value::AbstractString)::String
  return "$(column) LIKE $(value)$(_like_escape_clause())"
end
function contains(conn::PormGAbstractType, column::AbstractString, value)
  throw(InvalidValueError("The value must be a String"))
  return nothing
end

function icontains(conn::PormGPostgres, column::AbstractString, value::AbstractString)::String
  return "$(column) ILIKE $(value)$(_like_escape_clause())"
end
function icontains(conn::PormGSQLite, column::AbstractString, value::AbstractString)::String
  # pormg_lower = Unicode-aware LOWER UDF registered per-connection in PormGSQLiteExt (#78), so case
  # folding matches PostgreSQL ILIKE; case_sensitive_like=ON makes LIKE exact on the folded text.
  return "pormg_lower($(column)) LIKE pormg_lower($(value))$(_like_escape_clause())"
end
function icontains(conn::PormGAbstractType, column::AbstractString, value)
  throw(InvalidValueError("The value must be a String"))
  return nothing
end

function iunaccent_contains(conn::PormGPostgres, column::AbstractString, value::AbstractString)::String
  # Uses the IMMUTABLE wrapper (see Configuration._install_immutable_unaccent!) so the
  # expression can be backed by a functional/pg_trgm index on large tables.
  return "public.immutable_unaccent($(column)) ILIKE public.immutable_unaccent($(value))$(_like_escape_clause())"
end
function iunaccent_contains(conn::PormGSQLite, column::AbstractString, value::AbstractString)
  throw(BackendCapabilityError("The iunaccent_contains lookup requires PostgreSQL and the unaccent extension"))
  return nothing
end
function iunaccent_contains(conn::PormGAbstractType, column::AbstractString, value)
  throw(InvalidValueError("The value must be a String"))
  return nothing
end

function iunaccent_exact(conn::PormGPostgres, column::AbstractString, value::AbstractString)::String
  # Accent- and case-insensitive equality. Uses the IMMUTABLE wrapper (see
  # Configuration._install_immutable_unaccent!) so it can be backed by a functional
  # index on LOWER(public.immutable_unaccent(column)).
  return "LOWER(public.immutable_unaccent($(column))) = LOWER(public.immutable_unaccent($(value)))"
end
function iunaccent_exact(conn::PormGSQLite, column::AbstractString, value::AbstractString)
  throw(BackendCapabilityError("The iunaccent_exact lookup requires PostgreSQL and the unaccent extension"))
  return nothing
end
function iunaccent_exact(conn::PormGAbstractType, column::AbstractString, value)
  throw(InvalidValueError("The value must be a String"))
  return nothing
end

function startswith(conn::PormGPostgres, column::AbstractString, value::AbstractString)::String
  return "$(column) LIKE $(value)$(_like_escape_clause())"
end
function startswith(conn::PormGSQLite, column::AbstractString, value::AbstractString)::String
  return "$(column) LIKE $(value)$(_like_escape_clause())"
end
function startswith(conn::PormGAbstractType, column::AbstractString, value)
  throw(InvalidValueError("The value must be a String"))
  return nothing
end

function istartswith(conn::PormGPostgres, column::AbstractString, value::AbstractString)::String
  return "$(column) ILIKE $(value)$(_like_escape_clause())"
end
function istartswith(conn::PormGSQLite, column::AbstractString, value::AbstractString)::String
  # Unicode-aware case folding via the pormg_lower UDF (#78) — see icontains above.
  return "pormg_lower($(column)) LIKE pormg_lower($(value))$(_like_escape_clause())"
end
function istartswith(conn::PormGAbstractType, column::AbstractString, value)
  throw(InvalidValueError("The value must be a String"))
  return nothing
end

function endswith(conn::PormGPostgres, column::AbstractString, value::AbstractString)::String
  return "$(column) LIKE $(value)$(_like_escape_clause())"
end
function endswith(conn::PormGSQLite, column::AbstractString, value::AbstractString)::String
  return "$(column) LIKE $(value)$(_like_escape_clause())"
end
function endswith(conn::PormGAbstractType, column::AbstractString, value)
  throw(InvalidValueError("The value must be a String"))
  return nothing
end

function iendswith(conn::PormGPostgres, column::AbstractString, value::AbstractString)::String
  return "$(column) ILIKE $(value)$(_like_escape_clause())"
end
function iendswith(conn::PormGSQLite, column::AbstractString, value::AbstractString)::String
  # Unicode-aware case folding via the pormg_lower UDF (#78) — see icontains above.
  return "pormg_lower($(column)) LIKE pormg_lower($(value))$(_like_escape_clause())"
end
function iendswith(conn::PormGAbstractType, column::AbstractString, value)
  throw(InvalidValueError("The value must be a String"))
  return nothing
end

# ------------------------------------------------------------------------------
# #207: negated pattern lookups — the NOT-LIKE / NOT-ILIKE / <> twins of the
# renderers above. The value is decorated with the same wildcards by
# _apply_like_wildcards (parameters.jl); only the operator differs here. `col NOT
# LIKE …` / `<>` yield UNKNOWN (row excluded) for NULL columns — consistent with
# @ne / @nin. The unaccent twins stay PostgreSQL-only, mirroring their positive form.
# ------------------------------------------------------------------------------

function ncontains(conn::PormGPostgres, column::AbstractString, value::AbstractString)::String
  return "$(column) NOT LIKE $(value)$(_like_escape_clause())"
end
function ncontains(conn::PormGSQLite, column::AbstractString, value::AbstractString)::String
  return "$(column) NOT LIKE $(value)$(_like_escape_clause())"
end
function ncontains(conn::PormGAbstractType, column::AbstractString, value)
  throw(InvalidValueError("The value must be a String"))
  return nothing
end

function nicontains(conn::PormGPostgres, column::AbstractString, value::AbstractString)::String
  return "$(column) NOT ILIKE $(value)$(_like_escape_clause())"
end
function nicontains(conn::PormGSQLite, column::AbstractString, value::AbstractString)::String
  # pormg_lower = Unicode-aware LOWER UDF (#78); NOT LIKE over folded text mirrors icontains.
  return "pormg_lower($(column)) NOT LIKE pormg_lower($(value))$(_like_escape_clause())"
end
function nicontains(conn::PormGAbstractType, column::AbstractString, value)
  throw(InvalidValueError("The value must be a String"))
  return nothing
end

function niunaccent_contains(conn::PormGPostgres, column::AbstractString, value::AbstractString)::String
  return "public.immutable_unaccent($(column)) NOT ILIKE public.immutable_unaccent($(value))$(_like_escape_clause())"
end
function niunaccent_contains(conn::PormGSQLite, column::AbstractString, value::AbstractString)
  throw(BackendCapabilityError("The niunaccent_contains lookup requires PostgreSQL and the unaccent extension"))
  return nothing
end
function niunaccent_contains(conn::PormGAbstractType, column::AbstractString, value)
  throw(InvalidValueError("The value must be a String"))
  return nothing
end

function niunaccent_exact(conn::PormGPostgres, column::AbstractString, value::AbstractString)::String
  return "LOWER(public.immutable_unaccent($(column))) <> LOWER(public.immutable_unaccent($(value)))"
end
function niunaccent_exact(conn::PormGSQLite, column::AbstractString, value::AbstractString)
  throw(BackendCapabilityError("The niunaccent_exact lookup requires PostgreSQL and the unaccent extension"))
  return nothing
end
function niunaccent_exact(conn::PormGAbstractType, column::AbstractString, value)
  throw(InvalidValueError("The value must be a String"))
  return nothing
end

function nstartswith(conn::PormGPostgres, column::AbstractString, value::AbstractString)::String
  return "$(column) NOT LIKE $(value)$(_like_escape_clause())"
end
function nstartswith(conn::PormGSQLite, column::AbstractString, value::AbstractString)::String
  return "$(column) NOT LIKE $(value)$(_like_escape_clause())"
end
function nstartswith(conn::PormGAbstractType, column::AbstractString, value)
  throw(InvalidValueError("The value must be a String"))
  return nothing
end

function nistartswith(conn::PormGPostgres, column::AbstractString, value::AbstractString)::String
  return "$(column) NOT ILIKE $(value)$(_like_escape_clause())"
end
function nistartswith(conn::PormGSQLite, column::AbstractString, value::AbstractString)::String
  # pormg_lower = Unicode-aware LOWER UDF (#78); NOT LIKE over folded text mirrors istartswith.
  return "pormg_lower($(column)) NOT LIKE pormg_lower($(value))$(_like_escape_clause())"
end
function nistartswith(conn::PormGAbstractType, column::AbstractString, value)
  throw(InvalidValueError("The value must be a String"))
  return nothing
end

function nendswith(conn::PormGPostgres, column::AbstractString, value::AbstractString)::String
  return "$(column) NOT LIKE $(value)$(_like_escape_clause())"
end
function nendswith(conn::PormGSQLite, column::AbstractString, value::AbstractString)::String
  return "$(column) NOT LIKE $(value)$(_like_escape_clause())"
end
function nendswith(conn::PormGAbstractType, column::AbstractString, value)
  throw(InvalidValueError("The value must be a String"))
  return nothing
end

function niendswith(conn::PormGPostgres, column::AbstractString, value::AbstractString)::String
  return "$(column) NOT ILIKE $(value)$(_like_escape_clause())"
end
function niendswith(conn::PormGSQLite, column::AbstractString, value::AbstractString)::String
  # pormg_lower = Unicode-aware LOWER UDF (#78); NOT LIKE over folded text mirrors iendswith.
  return "pormg_lower($(column)) NOT LIKE pormg_lower($(value))$(_like_escape_clause())"
end
function niendswith(conn::PormGAbstractType, column::AbstractString, value)
  throw(InvalidValueError("The value must be a String"))
  return nothing
end

# ==============================================================================
# MIGRATION HISTORY TABLE DDL
# DDL for the pormg_migrations table that tracks applied migrations.
# ==============================================================================

"""
    create_migrations_table(conn::PormGPostgres) -> String

Generate DDL to create the pormg_migrations history table for PostgreSQL.
"""
function create_migrations_table(conn::PormGPostgres)::String
  return """CREATE TABLE IF NOT EXISTS pormg_migrations (
  "id" SERIAL PRIMARY KEY,
  "version" VARCHAR(17) NOT NULL UNIQUE,
  "name" VARCHAR(255) NOT NULL,
  "checksum" VARCHAR(64) NOT NULL,
  "sql_content" TEXT NOT NULL DEFAULT '',
  "applied_at" TIMESTAMP NOT NULL DEFAULT NOW(),
  "status" VARCHAR(20) NOT NULL DEFAULT 'applied',
  "is_destructive" BOOLEAN NOT NULL DEFAULT FALSE,
  "format_version" INTEGER NOT NULL DEFAULT 1
);"""
end

"""
    create_migrations_table(conn::PormGSQLite) -> String

Generate DDL to create the pormg_migrations history table for SQLite.

`applied_at` defaults to the canonical timestamp text (#570) — `SQLITE_CANONICAL_DATETIME_MASK`,
what every `DateTimeField` stores — rather than SQLite's own `datetime('now')`, whose
`YYYY-MM-DD HH:MM:SS` form no PormG reader anchors on. `CREATE TABLE IF NOT EXISTS` leaves an
existing table's default alone, which is why `_record_migration` also writes the column explicitly
and `init_migrations` repairs rows in the old form (`repair_migrations_applied_at_sql`).
"""
function create_migrations_table(conn::PormGSQLite)::String
  return """CREATE TABLE IF NOT EXISTS pormg_migrations (
  "id" INTEGER PRIMARY KEY AUTOINCREMENT,
  "version" VARCHAR(17) NOT NULL UNIQUE,
  "name" VARCHAR(255) NOT NULL,
  "checksum" VARCHAR(64) NOT NULL,
  "sql_content" TEXT NOT NULL DEFAULT '',
  "applied_at" DATETIME NOT NULL DEFAULT ($(sqlite_applied_at_now_sql())),
  "status" VARCHAR(20) NOT NULL DEFAULT 'applied',
  "is_destructive" BOOLEAN NOT NULL DEFAULT 0,
  "format_version" INTEGER NOT NULL DEFAULT 1
);"""
end

"""
    sqlite_applied_at_now_sql() -> String

The SQLite expression that yields "now" in PormG's canonical timestamp text (#570):
`strftime('%Y-%m-%dT%H:%M:%f+00:00', 'now')`. Used by the `pormg_migrations` DDL default and by
the explicit `applied_at` value every migration-record INSERT writes, so the two cannot drift.
"""
sqlite_applied_at_now_sql() = "strftime($(SQLITE_CANONICAL_DATETIME_MASK), 'now')"

# The rows `repair_migrations_applied_at_sql` rewrites, stated once so the probe and the UPDATE
# cannot disagree: TEXT values (the #527 repair shape), without the `T` separator, that `strftime`
# can actually parse — a value it cannot would otherwise become NULL under `NOT NULL`.
_legacy_applied_at_predicate() =
  """typeof("applied_at") = 'text' AND "applied_at" NOT GLOB '*T*'
    AND strftime($(SQLITE_CANONICAL_DATETIME_MASK), "applied_at") IS NOT NULL"""

"""
    legacy_applied_at_exists_sql(conn::PormGSQLite) -> String

`SELECT 1 … LIMIT 1` over exactly the rows `repair_migrations_applied_at_sql` would rewrite. The
runner probes with this before issuing the UPDATE, so a database with nothing to repair — every
database after its first pass — is never asked for a write: SQLite opens the write transaction at
statement start even when the WHERE matches nothing, and a read-only file would refuse it.
"""
function legacy_applied_at_exists_sql(conn::PormGSQLite)::String
  return "SELECT 1 FROM pormg_migrations WHERE $(_legacy_applied_at_predicate()) LIMIT 1;"
end

"""
    repair_migrations_applied_at_sql(conn::PormGSQLite) -> String

Idempotent UPDATE that rewrites `pormg_migrations.applied_at` rows still in SQLite's own
`YYYY-MM-DD HH:MM:SS` form — written by the `datetime('now')` default of tables created before
#570 — into the canonical text, preserving the instant. After the first pass the WHERE matches
nothing; `legacy_applied_at_exists_sql` is the read-only probe for the same rows.
"""
function repair_migrations_applied_at_sql(conn::PormGSQLite)::String
  return """UPDATE pormg_migrations SET "applied_at" = strftime($(SQLITE_CANONICAL_DATETIME_MASK), "applied_at")
  WHERE $(_legacy_applied_at_predicate());"""
end

"""
    insert_migration_record_sql(conn::PormGPostgres) -> String

Returns parameterized INSERT for recording an applied migration (PostgreSQL).
"""
function insert_migration_record_sql(conn::PormGPostgres)::String
  return """INSERT INTO pormg_migrations ("version", "name", "checksum", "sql_content", "status", "is_destructive", "format_version") VALUES (\$1, \$2, \$3, \$4, \$5, \$6, \$7);"""
end

"""
    insert_migration_record_sql(conn::PormGSQLite) -> String

Returns parameterized INSERT for recording an applied migration (SQLite).
"""
function insert_migration_record_sql(conn::PormGSQLite)::String
  # `applied_at` is written explicitly (#570): a table created before #570 still carries the
  # `datetime('now')` default, and relying on it would keep writing the non-canonical form there.
  return """INSERT INTO pormg_migrations ("version", "name", "checksum", "sql_content", "status", "is_destructive", "format_version", "applied_at") VALUES (?, ?, ?, ?, ?, ?, ?, $(sqlite_applied_at_now_sql()));"""
end

"""
    update_migration_status_sql(conn::PormGPostgres) -> String

Returns parameterized UPDATE for changing a migration status by version (PostgreSQL).
"""
function update_migration_status_sql(conn::PormGPostgres)::String
  return """UPDATE pormg_migrations SET "status" = \$1 WHERE "version" = \$2;"""
end

"""
    update_migration_status_sql(conn::PormGSQLite) -> String

Returns parameterized UPDATE for changing a migration status by version (SQLite).
"""
function update_migration_status_sql(conn::PormGSQLite)::String
  return """UPDATE pormg_migrations SET "status" = ? WHERE "version" = ?;"""
end

"""
    select_all_migrations_sql(conn) -> String

Returns SQL to select all migration records ordered by version.
"""
function select_all_migrations_sql(conn::Union{PormGPostgres, PormGSQLite})::String
  return """SELECT "id", "version", "name", "checksum", "sql_content", "applied_at", "status", "is_destructive", "format_version" FROM pormg_migrations ORDER BY "version" ASC;"""
end

"""
    select_migration_by_version_sql(conn::PormGPostgres) -> String

Returns parameterized SQL to select a single migration by version (PostgreSQL).
"""
function select_migration_by_version_sql(conn::PormGPostgres)::String
  return """SELECT "id", "version", "name", "checksum", "sql_content", "applied_at", "status", "is_destructive", "format_version" FROM pormg_migrations WHERE "version" = \$1;"""
end

"""
    select_migration_by_version_sql(conn::PormGSQLite) -> String

Returns parameterized SQL to select a single migration by version (SQLite).
"""
function select_migration_by_version_sql(conn::PormGSQLite)::String
  return """SELECT "id", "version", "name", "checksum", "sql_content", "applied_at", "status", "is_destructive", "format_version" FROM pormg_migrations WHERE "version" = ?;"""
end

"""
    delete_migration_record_sql(conn::PormGPostgres) -> String

Returns parameterized DELETE for removing a migration record by version (PostgreSQL).
"""
function delete_migration_record_sql(conn::PormGPostgres)::String
  return """DELETE FROM pormg_migrations WHERE "version" = \$1;"""
end

"""
    delete_migration_record_sql(conn::PormGSQLite) -> String

Returns parameterized DELETE for removing a migration record by version (SQLite).
"""
function delete_migration_record_sql(conn::PormGSQLite)::String
  return """DELETE FROM pormg_migrations WHERE "version" = ?;"""
end

"""
    migrations_table_exists_sql(conn::PormGPostgres) -> String

Returns SQL to check if pormg_migrations table exists (PostgreSQL).
"""
function migrations_table_exists_sql(conn::PormGPostgres)::String
  return """SELECT EXISTS (SELECT 1 FROM information_schema.tables WHERE table_name = 'pormg_migrations');"""
end

"""
    migrations_table_exists_sql(conn::PormGSQLite) -> String

Returns SQL to check if pormg_migrations table exists (SQLite).
"""
function migrations_table_exists_sql(conn::PormGSQLite)::String
  return """SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='pormg_migrations';"""
end

"""
    add_format_version_column_sql(conn::PormGPostgres) -> String

DDL that backfills the `format_version` column onto a pre-existing `pormg_migrations` table.
Callers gate this on `migrations_table_info_sql` (see `_ensure_format_version_column`) so it does
not emit a `NOTICE: column already exists` on every `init_migrations` call; the `IF NOT EXISTS`
clause additionally keeps it safe against the rare race where a concurrent migration adds the column
between the probe and this `ALTER`.
"""
function add_format_version_column_sql(conn::PormGPostgres)::String
  return """ALTER TABLE pormg_migrations ADD COLUMN IF NOT EXISTS "format_version" INTEGER NOT NULL DEFAULT 1;"""
end

"""
    add_format_version_column_sql(conn::PormGSQLite) -> String

DDL that adds the `format_version` column to an existing `pormg_migrations` table. SQLite has no
`IF NOT EXISTS` for `ADD COLUMN` and errors if the column already exists, so callers MUST gate this
on `migrations_table_info_sql` first (see `_ensure_format_version_column`).
"""
function add_format_version_column_sql(conn::PormGSQLite)::String
  return """ALTER TABLE pormg_migrations ADD COLUMN "format_version" INTEGER NOT NULL DEFAULT 1;"""
end

"""
    migrations_table_info_sql(conn::PormGPostgres) -> String

Returns SQL listing the `pormg_migrations` columns (one row per column, in a `name` column) so
`_ensure_format_version_column` can check whether `format_version` already exists before issuing the
`ALTER`. Mirrors the column-name shape of the SQLite `PRAGMA table_info` result.
"""
function migrations_table_info_sql(conn::PormGPostgres)::String
  return """SELECT column_name AS name FROM information_schema.columns WHERE table_name = 'pormg_migrations';"""
end

"""
    migrations_table_info_sql(conn::PormGSQLite) -> String

Returns SQL to introspect the `pormg_migrations` columns (used to check whether `format_version`
already exists before attempting an idempotent `ALTER TABLE ... ADD COLUMN`). The result set has a
`name` column listing each existing column.
"""
function migrations_table_info_sql(conn::PormGSQLite)::String
  return """PRAGMA table_info(pormg_migrations);"""
end

end