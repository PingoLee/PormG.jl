module Dialect
using Dates, TimeZones
using DataFrames
import Tables
import PormG: PormGSettings, SQLType, SQLInstruction, SQLTypeQ, SQLTypeQor, SQLTypeF, SQLTypeOper, SQLObject, PormGModel, PormGField, PormGBackend, PormGPostgres, PormGSQLite, PormGAbstractType
import PormG: backend_sqlite_version  # SQLite library-version probe (driver body in the weakdep extension)
# Semantic error taxonomy (#239). Dialect raises three categories:
#   InvalidValueError          — a rendered value has the wrong Julia type ("must be a String").
#   BackendCapabilityError — the active backend cannot do this (a PG-only JSONB/unaccent
#                                lookup, an extract part SQLite lacks, too old a SQLite library).
#   QueryBuildError            — the caller passed an impossible argument shape (on_conflict_clause).
import PormG: InvalidValueError, BackendCapabilityError, QueryBuildError
import PormG.ConnectionPool: fetch
import PormG: postgres_type_map, postgres_type_map_reverse, sqlite_date_format_map, sqlite_type_map_reverse
# The canonical column IR (#507). `alter_field` renders an ALTER from a `ColumnDelta`, which is why
# these types live in `Kernel` (layer 1) rather than in `Migrations` — this module is included
# BEFORE it, and a submodule resolves `import PormG: …` at include time. `_has_non_negative` and
# `_byte_bound` are underscore-private, hence named explicitly.
import PormG: ColumnDelta, LiteralDefault, ExpressionDefault
import PormG: _has_non_negative, _byte_bound
import PormG: get_constraints_pk, get_constraints_unique, get_constraints_check, get_constraints_byte_length_check
import PormG.Models: Migration, get_model_pk_field, format_model_name, field_db_column, fk_target_column, format_timezone_sql, model_table_name, fk_target_table
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
function DATE(column::String, format::Dict{String,Any}, conn::Union{PormGPostgres,PormGSQLite})
  return CAST(column, Dict{String,Any}("type" => "date"), conn)
end
function Y_M(column::String, format::Dict{String,Any}, conn::Union{PormGPostgres,PormGSQLite})
  return EXTRACT_DATE(column, Dict{String,Any}("format" => "YYYY-MM"), conn)
end
function QUARTER(column::String, format::Dict{String,Any}, conn::PormGPostgres)
  return "EXTRACT(QUARTER FROM $(column))"
end
function QUARTER(column::String, format::Dict{String,Any}, conn::PormGSQLite)
  return "((strftime('%m', $(column)) - 1) / 3) + 1"
end
function QUADRIMESTER(column::String, format::Dict{String,Any}, conn::PormGPostgres)
  return "CEIL(EXTRACT(MONTH FROM $(column)) / 4.0)"
end
function QUADRIMESTER(column::String, format::Dict{String,Any}, conn::PormGSQLite)
  return "((strftime('%m', $(column)) - 1) / 4) + 1"
end


# PostgreSQL
function EXTRACT_DATE(column::String, format::Dict{String,Any}, conn::PormGPostgres)
  format_str = format["format"]
  locale = get(format, "locale", "")
  nlsparam = get(format, "nlsparam", "")
  return "to_char($(column), '$(format_str)') $(locale) $(nlsparam)"
end
# SQLite
function EXTRACT_DATE(column::String, format::Dict{String,Any}, conn::PormGSQLite)
  format_str = format["format"]
  locale = get(format, "locale", "")
  return "strftime('$(sqlite_date_format_map[format_str])', $(column)) $(locale)"
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

function VALUE(value::Nothing, conn::PormGPostgres)
  return "NULL"
end
function VALUE(value::Number, conn::PormGPostgres)
  return "$value"
end
function VALUE(value::String, conn::PormGPostgres)
  return "('$(value)')::text"
end
function VALUE(value::Nothing, conn::PormGSQLite)
  return "NULL"
end
function VALUE(value::Number, conn::PormGSQLite)
  return "$value"
end
function VALUE(value::String, conn::PormGSQLite)
  return "'$(value)'"
end
function CAST(column::String, format::Dict{String,Any}, conn::PormGPostgres)
  return """($column)::$(format["type"])"""
end
function CAST(column::String, format::Dict{String,Any}, conn::PormGSQLite)
  target_type = uppercase(format["type"])
  if haskey(sqlite_type_map_reverse, target_type)
    return "CAST($column AS $(sqlite_type_map_reverse[target_type]))"
  else
    return "CAST($column AS $(target_type))"
  end
end
function CONCAT(column::Array{Any,1}, format::Dict{String,Any}, conn::PormGPostgres)
  return "CONCAT($(join(column, ",\n")))"
end
function CONCAT(column::Array{Any,1}, format::Dict{String,Any}, conn::PormGSQLite)
  return "($(join(column, " ||\n")))"
end
function EXTRACT(column::String, format::Dict{String,Any}, conn::PormGPostgres)
  if haskey(format, "format")
    return "EXTRACT($(format["part"]) FROM $(column))$(format["format"])"
  else
    return "EXTRACT($(format["part"]) FROM $(column))"
  end
end
function EXTRACT(column::String, format::Dict{String,Any}, conn::PormGSQLite)
  part = format["part"]
  strftime_format = if part == "YEAR"
    "%Y"
  elseif part == "MONTH"
    "%m"
  elseif part == "DAY"
    "%d"
  elseif part == "HOUR"
    "%H"
  elseif part == "MINUTE"
    "%M"
  elseif part == "SECOND"
    "%S"
  elseif part == "DOW"
    "%w"
  elseif part == "DOY"
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
    END)::$(output_field)
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
    return CAST(resp, Dict{String,Any}("type" => output_field), conn)
  else
    return resp
  end
end

function WHEN(column::String, format::Dict{String,Any}, conn::Union{PormGPostgres,PormGSQLite})
  return "WHEN $(column) THEN $(format["then"])" |> string
end

function COALESCE(columns::Vector{Any}, format::Dict{String,Any}, conn::PormGPostgres)
  sql = "COALESCE($(join(columns, ", ")))"
  if get(format, "output_field", nothing) !== nothing
    return "($sql)::$(format["output_field"])"
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
    _format_default_sql_value(default_value, conn) -> String

Render a field's `default` as a SQL literal for `conn`'s dialect.

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
    _postgres_bytea_cast_expression(field_name, old_field) -> String

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
faithful-reinterpretation form and `UPGRADING.md` tells the operator to substitute
`decode(col, 'base64')` / `decode(col, 'hex')` in the generated migration when that is what the
column actually held. `makemigrations` writes a reviewable plan before anything runs, which is
where that substitution belongs.
"""
function _postgres_bytea_cast_expression(field_name::Union{String, Symbol}, old_field::Union{Nothing, PormGField})
  column_ref = "\"$(_quote_table_ddl(field_name))\""

  if old_field isa Union{sCharField, sTextField, sImageField, sSlugField, sURLField}
    return "convert_to($(column_ref), 'UTF8')"
  end
  # Already bytea, or a type with a real cast to it — let PostgreSQL apply its own.
  return "$(column_ref)::bytea"
end

function _postgres_interval_cast_expression(field_name::Union{String, Symbol}, old_field::Union{Nothing, PormGField})
  column_ref = "\"$(_quote_table_ddl(field_name))\""

  if old_field isa Union{sFloatField, sDecimalField, sIntegerField, sBigIntegerField, sPositiveSmallIntegerField, sPositiveIntegerField}
    return "make_interval(secs => $(column_ref)::double precision)"
  elseif old_field isa sTimeField
    return "($(column_ref)::text)::interval"
  elseif old_field isa Union{sCharField, sTextField}
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

  # Default value
  if field.default !== nothing || temporary_default !== nothing
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

function field_to_column(col_name::String, field::PormGField, conn::PormGSQLite; temporary_default::Any=nothing)::String
  # Resolve the physical column name (db_column when set, else the field name) — #50.
  col_name = field_db_column(field, col_name)
  # Determine the base SQL type
  base_type = _get_column_type(field, conn)

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
  # Nullability (default is NOT NULL if 'null' is false)
  if hasproperty(field, :null) && field.null
    push!(constraints, "NULL")
  else
    push!(constraints, "NOT NULL")
  end

  # Default value
  if field.default !== nothing || temporary_default !== nothing
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
# `Dialect._foreign_key_on_delete_sql` still resolves for every existing caller. It had to move: it is
# also the CANONICAL COMPARISON of two `on_delete` values, and a module included BEFORE this one
# needs it: `Models._fk_on_delete_equal`, in the file it moved to. `Models._compare_model_field` was
# the caller that established that until #507 phase 2 retired it. (`Migrations.column_spec` renders
# through it too, but `Migrations` is included AFTER this module, so that use would not by itself
# require the move.)

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

function create_index(conn::PormGPostgres, index_name::String, table_name::String, columns::Vector{String})
  return """CREATE INDEX IF NOT EXISTS $(index_name) ON $(table_name) ($(join(columns, ", ")));"""
end

function create_index(conn::PormGSQLite, index_name::String, table_name::String, columns::Vector{String})
  return """CREATE INDEX IF NOT EXISTS $(index_name) ON $(table_name) ($(join(columns, ", ")));"""
end

function create_unique_index(conn::PormGPostgres, index_name::String, table_name::String, columns::Vector{String})
  return """CREATE UNIQUE INDEX IF NOT EXISTS $(index_name) ON $(table_name) ($(join(columns, ", ")));"""
end

function create_unique_index(conn::PormGSQLite, index_name::String, table_name::String, columns::Vector{String})
  return """CREATE UNIQUE INDEX IF NOT EXISTS $(index_name) ON $(table_name) ($(join(columns, ", ")));"""
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
function alter_field(conn::PormGPostgres, table_name::Union{Symbol,String}, field_name::Union{Symbol,String}, new_field::PormGField, old_field::Union{Nothing,PormGField}, delta::ColumnDelta)::String
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
  raw_table_name = string(table_name)
  table_name = _quote_table_ddl(raw_table_name)

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
      if old_field !== nothing
        old_max_digits = hasproperty(old_field, :max_digits) ? old_field.max_digits : nothing
        old_decimal_places = hasproperty(old_field, :decimal_places) ? old_field.decimal_places : nothing
        if old_max_digits !== nothing && decimal_places < old_decimal_places
          @warn "The new decimal_places is less than the old decimal_places in table $(table_name) and field $(field_name)"
        end
      end
    elseif new_field isa sTimeField
      push!(sql_statements, """ALTER TABLE "$table_name" ALTER COLUMN "$(_quote_table_ddl(field_name))" TYPE TIME USING "$(_quote_table_ddl(field_name))"::time without time zone;""")
    elseif new_field isa sDurationField
      cast_expression = _postgres_interval_cast_expression(field_name, old_field)
      push!(sql_statements, """ALTER TABLE "$table_name" ALTER COLUMN "$(_quote_table_ddl(field_name))" TYPE INTERVAL USING $cast_expression;""")
    elseif new_field isa sBinaryField
      # The inner `if :type in colect_not_equal` this used to carry is gone, and nothing replaced it:
      # a `BinaryField` whose `max_length` alone moved is a `:checks` delta, not a `:type` one, so it
      # never enters this branch at all. Same outcome — no redundant `TYPE bytea USING …` rewriting
      # the whole table for nothing — reached by the slot being right rather than by a second guard.
      cast_expression = _postgres_bytea_cast_expression(field_name, old_field)
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
  #   * `ExpressionDefault` — a database-side expression, emitted verbatim. `column_spec` cannot
  #     produce one yet: no `PormGField` has a slot that spells it, and introspection drops an
  #     expression default it cannot represent (#472/#475). #496 is the change that makes it
  #     reachable, and the branch is here so that #496 is a pure addition to the compiler rather
  #     than a re-shaping of the renderer. It is covered by a unit test that hands `alter_field` a
  #     hand-built delta, because nothing else can reach it.
  #   * `NoDefault` — DROP.
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
  return field isa sRelationalColumn && field.db_constraint &&
         field.null && field.default === nothing && temporary_default === nothing &&
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
  column_sql = field_to_column(field_name, field, conn, temporary_default=temporary_default)
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

function alter_field(conn::PormGPostgres, model::PormGModel, field_name::Union{Symbol,String}, new_field::PormGField, old_field::Union{Nothing,PormGField}, delta::ColumnDelta)
  return alter_field(conn, model_table_name(model), field_name, new_field, old_field, delta)
end

# SQLite alters a column by rebuilding the whole table from the DESIRED model, so it reads none of
# the arguments that describe the change: not the field pair, not the delta. It keeps them because
# the planner calls one `alter_field` for both engines. The signature is the only thing #507 phase 2
# changed here.
#
# `rebuild_table` below is that body, reachable on its own — see the note there for why the planner
# needs both spellings.
function alter_field(conn::PormGSQLite, model::PormGModel, field_name::Union{Symbol,String}, new_field::PormGField, old_field::Union{Nothing,PormGField}, delta::ColumnDelta)
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

function drop_foreign_key(conn::PormGPostgres, table_name::Symbol, constraint_name::String)
  return """ALTER TABLE "$(_quote_table_ddl(table_name))" DROP CONSTRAINT "$(_quote_table_ddl(constraint_name))";"""
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

# PostgreSQL JSONB containment/overlap operators (PG-only; SQLite + abstract throw a friendly
# error, mirroring iunaccent_*). LibPQ binds `$N` placeholders, so a literal `?`/`?|`/`?&` here is
# the jsonb operator, never a bind marker. The RHS placeholder already carries any needed cast
# (`::jsonb` for @>, `::text[]` for ?|/?&) from add_parameter!.
function jcontains(conn::PormGPostgres, column::String, value::String)::String
  return "$(column) @> $(value)"                    # jsonb contains the given document
end
function jcontains(conn::PormGSQLite, column::String, value::String)
  throw(BackendCapabilityError("The @jcontains lookup (JSONB @>) requires PostgreSQL"))
end
function jcontains(conn::PormGAbstractType, column::String, value)
  throw(BackendCapabilityError("The @jcontains lookup (JSONB @>) requires PostgreSQL"))
end

function has_key(conn::PormGPostgres, column::String, value::String)::String
  return "$(column) ? $(value)"                     # top-level key exists
end
function has_key(conn::PormGSQLite, column::String, value::String)
  throw(BackendCapabilityError("The @has_key lookup (JSONB ?) requires PostgreSQL"))
end
function has_key(conn::PormGAbstractType, column::String, value)
  throw(BackendCapabilityError("The @has_key lookup (JSONB ?) requires PostgreSQL"))
end

function has_any_keys(conn::PormGPostgres, column::String, value::String)::String
  return "$(column) ?| $(value)"                    # any of the given keys exists
end
function has_any_keys(conn::PormGSQLite, column::String, value::String)
  throw(BackendCapabilityError("The @has_any_keys lookup (JSONB ?|) requires PostgreSQL"))
end
function has_any_keys(conn::PormGAbstractType, column::String, value)
  throw(BackendCapabilityError("The @has_any_keys lookup (JSONB ?|) requires PostgreSQL"))
end

function has_keys(conn::PormGPostgres, column::String, value::String)::String
  return "$(column) ?& $(value)"                    # all of the given keys exist
end
function has_keys(conn::PormGSQLite, column::String, value::String)
  throw(BackendCapabilityError("The @has_keys lookup (JSONB ?&) requires PostgreSQL"))
end
function has_keys(conn::PormGAbstractType, column::String, value)
  throw(BackendCapabilityError("The @has_keys lookup (JSONB ?&) requires PostgreSQL"))
end

function contains(conn::PormGPostgres, column::String, value::String)::String
  return "$(column) LIKE $(value)$(_like_escape_clause())"
end
function contains(conn::PormGSQLite, column::String, value::String)::String
  return "$(column) LIKE $(value)$(_like_escape_clause())"
end
function contains(conn::PormGAbstractType, column::String, value)
  throw(InvalidValueError("The value must be a String"))
  return nothing
end

function icontains(conn::PormGPostgres, column::String, value::String)::String
  return "$(column) ILIKE $(value)$(_like_escape_clause())"
end
function icontains(conn::PormGSQLite, column::String, value::String)::String
  # pormg_lower = Unicode-aware LOWER UDF registered per-connection in PormGSQLiteExt (#78), so case
  # folding matches PostgreSQL ILIKE; case_sensitive_like=ON makes LIKE exact on the folded text.
  return "pormg_lower($(column)) LIKE pormg_lower($(value))$(_like_escape_clause())"
end
function icontains(conn::PormGAbstractType, column::String, value)
  throw(InvalidValueError("The value must be a String"))
  return nothing
end

function iunaccent_contains(conn::PormGPostgres, column::String, value::String)::String
  # Uses the IMMUTABLE wrapper (see Configuration._install_immutable_unaccent!) so the
  # expression can be backed by a functional/pg_trgm index on large tables.
  return "public.immutable_unaccent($(column)) ILIKE public.immutable_unaccent($(value))$(_like_escape_clause())"
end
function iunaccent_contains(conn::PormGSQLite, column::String, value::String)
  throw(BackendCapabilityError("The iunaccent_contains lookup requires PostgreSQL and the unaccent extension"))
  return nothing
end
function iunaccent_contains(conn::PormGAbstractType, column::String, value)
  throw(InvalidValueError("The value must be a String"))
  return nothing
end

function iunaccent_exact(conn::PormGPostgres, column::String, value::String)::String
  # Accent- and case-insensitive equality. Uses the IMMUTABLE wrapper (see
  # Configuration._install_immutable_unaccent!) so it can be backed by a functional
  # index on LOWER(public.immutable_unaccent(column)).
  return "LOWER(public.immutable_unaccent($(column))) = LOWER(public.immutable_unaccent($(value)))"
end
function iunaccent_exact(conn::PormGSQLite, column::String, value::String)
  throw(BackendCapabilityError("The iunaccent_exact lookup requires PostgreSQL and the unaccent extension"))
  return nothing
end
function iunaccent_exact(conn::PormGAbstractType, column::String, value)
  throw(InvalidValueError("The value must be a String"))
  return nothing
end

function startswith(conn::PormGPostgres, column::String, value::String)::String
  return "$(column) LIKE $(value)$(_like_escape_clause())"
end
function startswith(conn::PormGSQLite, column::String, value::String)::String
  return "$(column) LIKE $(value)$(_like_escape_clause())"
end
function startswith(conn::PormGAbstractType, column::String, value)
  throw(InvalidValueError("The value must be a String"))
  return nothing
end

function istartswith(conn::PormGPostgres, column::String, value::String)::String
  return "$(column) ILIKE $(value)$(_like_escape_clause())"
end
function istartswith(conn::PormGSQLite, column::String, value::String)::String
  # Unicode-aware case folding via the pormg_lower UDF (#78) — see icontains above.
  return "pormg_lower($(column)) LIKE pormg_lower($(value))$(_like_escape_clause())"
end
function istartswith(conn::PormGAbstractType, column::String, value)
  throw(InvalidValueError("The value must be a String"))
  return nothing
end

function endswith(conn::PormGPostgres, column::String, value::String)::String
  return "$(column) LIKE $(value)$(_like_escape_clause())"
end
function endswith(conn::PormGSQLite, column::String, value::String)::String
  return "$(column) LIKE $(value)$(_like_escape_clause())"
end
function endswith(conn::PormGAbstractType, column::String, value)
  throw(InvalidValueError("The value must be a String"))
  return nothing
end

function iendswith(conn::PormGPostgres, column::String, value::String)::String
  return "$(column) ILIKE $(value)$(_like_escape_clause())"
end
function iendswith(conn::PormGSQLite, column::String, value::String)::String
  # Unicode-aware case folding via the pormg_lower UDF (#78) — see icontains above.
  return "pormg_lower($(column)) LIKE pormg_lower($(value))$(_like_escape_clause())"
end
function iendswith(conn::PormGAbstractType, column::String, value)
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

function ncontains(conn::PormGPostgres, column::String, value::String)::String
  return "$(column) NOT LIKE $(value)$(_like_escape_clause())"
end
function ncontains(conn::PormGSQLite, column::String, value::String)::String
  return "$(column) NOT LIKE $(value)$(_like_escape_clause())"
end
function ncontains(conn::PormGAbstractType, column::String, value)
  throw(InvalidValueError("The value must be a String"))
  return nothing
end

function nicontains(conn::PormGPostgres, column::String, value::String)::String
  return "$(column) NOT ILIKE $(value)$(_like_escape_clause())"
end
function nicontains(conn::PormGSQLite, column::String, value::String)::String
  # pormg_lower = Unicode-aware LOWER UDF (#78); NOT LIKE over folded text mirrors icontains.
  return "pormg_lower($(column)) NOT LIKE pormg_lower($(value))$(_like_escape_clause())"
end
function nicontains(conn::PormGAbstractType, column::String, value)
  throw(InvalidValueError("The value must be a String"))
  return nothing
end

function niunaccent_contains(conn::PormGPostgres, column::String, value::String)::String
  return "public.immutable_unaccent($(column)) NOT ILIKE public.immutable_unaccent($(value))$(_like_escape_clause())"
end
function niunaccent_contains(conn::PormGSQLite, column::String, value::String)
  throw(BackendCapabilityError("The niunaccent_contains lookup requires PostgreSQL and the unaccent extension"))
  return nothing
end
function niunaccent_contains(conn::PormGAbstractType, column::String, value)
  throw(InvalidValueError("The value must be a String"))
  return nothing
end

function niunaccent_exact(conn::PormGPostgres, column::String, value::String)::String
  return "LOWER(public.immutable_unaccent($(column))) <> LOWER(public.immutable_unaccent($(value)))"
end
function niunaccent_exact(conn::PormGSQLite, column::String, value::String)
  throw(BackendCapabilityError("The niunaccent_exact lookup requires PostgreSQL and the unaccent extension"))
  return nothing
end
function niunaccent_exact(conn::PormGAbstractType, column::String, value)
  throw(InvalidValueError("The value must be a String"))
  return nothing
end

function nstartswith(conn::PormGPostgres, column::String, value::String)::String
  return "$(column) NOT LIKE $(value)$(_like_escape_clause())"
end
function nstartswith(conn::PormGSQLite, column::String, value::String)::String
  return "$(column) NOT LIKE $(value)$(_like_escape_clause())"
end
function nstartswith(conn::PormGAbstractType, column::String, value)
  throw(InvalidValueError("The value must be a String"))
  return nothing
end

function nendswith(conn::PormGPostgres, column::String, value::String)::String
  return "$(column) NOT LIKE $(value)$(_like_escape_clause())"
end
function nendswith(conn::PormGSQLite, column::String, value::String)::String
  return "$(column) NOT LIKE $(value)$(_like_escape_clause())"
end
function nendswith(conn::PormGAbstractType, column::String, value)
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
"""
function create_migrations_table(conn::PormGSQLite)::String
  return """CREATE TABLE IF NOT EXISTS pormg_migrations (
  "id" INTEGER PRIMARY KEY AUTOINCREMENT,
  "version" VARCHAR(17) NOT NULL UNIQUE,
  "name" VARCHAR(255) NOT NULL,
  "checksum" VARCHAR(64) NOT NULL,
  "sql_content" TEXT NOT NULL DEFAULT '',
  "applied_at" DATETIME NOT NULL DEFAULT (datetime('now')),
  "status" VARCHAR(20) NOT NULL DEFAULT 'applied',
  "is_destructive" BOOLEAN NOT NULL DEFAULT 0,
  "format_version" INTEGER NOT NULL DEFAULT 1
);"""
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
  return """INSERT INTO pormg_migrations ("version", "name", "checksum", "sql_content", "status", "is_destructive", "format_version") VALUES (?, ?, ?, ?, ?, ?, ?);"""
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