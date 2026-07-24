module Dialect
using Dates, TimeZones
using DataFrames
import Tables
import PormG: PormGSettings, SQLType, SQLInstruction, SQLTypeQ, SQLTypeQor, SQLTypeF, SQLTypeOper, SQLObject, PormGModel, PormGField, PormGPostgres, PormGSQLite, PormGAbstractType
import PormG: backend_sqlite_version  # SQLite library-version probe (driver body in the weakdep extension)
import PormG.ConnectionPool: fetch
import PormG: postgres_type_map, postgres_type_map_reverse, sqlite_date_format_map, sqlite_type_map_reverse
import PormG: get_constraints_pk, get_constraints_unique, get_constraints_check
import PormG.Models: Migration, get_model_pk_field, format_model_name, field_db_column, fk_target_column, format_timezone_sql

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
    throw(ArgumentError("SQLite window functions require SQLite >= 3.25.0; current SQLite library is $major.$minor.$patch."))
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
    throw(ArgumentError("Unsupported extract part for SQLite: $part"))
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
import PormG.Models: sIDField, sCharField, sTextField, sBooleanField, sIntegerField, sBigIntegerField, sPositiveSmallIntegerField, sPositiveIntegerField, sFloatField, sDecimalField, sDateField, sDateTimeField, sTimeField, sDurationField, sForeignKey, sManyToManyField, sUUIDField, sURLField, sSlugField, sJSONField

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

function _postgres_interval_cast_expression(field_name::Union{String, Symbol}, old_field::Union{Nothing, PormGField})
  column_ref = "\"$(field_name)\""

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
  elseif field isa sForeignKey
    return type_map[field.type]
  elseif field isa sUUIDField
    return type_map[field.type]
  elseif field isa sJSONField
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
  elseif field isa sForeignKey
    return sql_type
  elseif field isa sUUIDField
    return sql_type
  elseif field isa sJSONField
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
_non_negative_check_clause(col_name)::String = "CHECK (\"$(col_name)\" >= 0)"

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
    push!(constraints, "DEFAULT $(_format_default_sql_value(default_value))")
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

  # Combine everything into a single string: "col_name base_type constraints..."
  return join(["\"$(col_name)\"", base_type, join(constraints, " ")], " ")
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
    push!(constraints, "DEFAULT $(_format_default_sql_value(default_value))")
  end

  # Non-negative CHECK for positive integer fields. SQLite's alter_field recreates the
  # table from current model state, so this clause is re-derived automatically on ALTER.
  _requires_non_negative_check(field) && push!(constraints, _non_negative_check_clause(col_name))

  # Combine everything into a single string: "col_name base_type constraints..."
  return join(["\"$(col_name)\"", base_type, join(constraints, " ")], " ")
end

# ---
# Functions to create migration queries
#

function create_table(conn::PormGPostgres, table_name::String, columns::Vector{String})
  return """CREATE TABLE IF NOT EXISTS $(table_name) (\n  $(join(columns, ",\n  "))
    );"""
end

function create_table(conn::PormGSQLite, table_name::String, columns::Vector{String})
  return """CREATE TABLE IF NOT EXISTS $(table_name) (\n  $(join(columns, ",\n  "))
    );"""
end

function _foreign_key_on_delete_sql(on_delete::Nothing)::String
  return "NO ACTION"
end

function _foreign_key_on_delete_sql(on_delete)::String
  action = string(on_delete) |> x -> split(x, ".")[end] |> uppercase |> strip
  action = replace(action, " " => "_")

  if action == "SET_NULL"
    return "SET NULL"
  elseif action == "SET_DEFAULT"
    return "SET DEFAULT"
  elseif action == "DO_NOTHING"
    return "NO ACTION"
  elseif action == "PROTECT"
    return "RESTRICT"
  else
    return replace(action, "_" => " ")
  end
end

function create_table(conn::PormGPostgres, model::PormGModel)
  columns::Vector{String} = []
  for (field_name, field) in model.fields
    field isa sManyToManyField && continue
    push!(columns, field_to_column(field_name |> string, field, conn))
  end

  return create_table(conn, model.name |> lowercase, columns)
end

function create_table(conn::PormGSQLite, model::PormGModel)
  columns::Vector{String} = []
  for (field_name, field) in model.fields
    field isa sManyToManyField && continue
    push!(columns, field_to_column(field_name |> string, field, conn))
  end

  # Add foreign key constraints for SQLite during CREATE TABLE
  for (field_name, field) in model.fields
    if field isa sForeignKey && field.db_constraint
      on_delete_str = _foreign_key_on_delete_sql(field.on_delete)
      # Local FK column and referenced parent column both honor db_column (#50).
      local_col = field_db_column(field, string(field_name))
      target_pk = fk_target_column(field)
      push!(columns, "FOREIGN KEY (\"$local_col\") REFERENCES \"$(field.to |> format_model_name)\"(\"$target_pk\") ON DELETE $on_delete_str")
    end
  end

  return create_table(conn, model.name |> lowercase, columns)
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
    throw(ArgumentError("on_conflict_clause: action must be :nothing or :update, got :$action"))
  target_sql = isempty(target) ? "" : " ($(join(target, ", ")))"
  if action === :nothing
    return "ON CONFLICT$(target_sql) DO NOTHING"
  end
  isempty(target) &&
    throw(ArgumentError("on_conflict_clause: action :update requires a non-empty conflict target"))
  isempty(set) &&
    throw(ArgumentError("on_conflict_clause: action :update requires a non-empty set column list"))
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

function add_foreign_key(conn::PormGPostgres, table_name::Union{Symbol,String}, constraint_name::String, field_name::String, ref_table_name::String, ref_field_name::String; on_delete::Union{String,Nothing}=nothing)
  on_delete_clause = on_delete !== nothing ? " ON DELETE $on_delete" : ""
  return """ALTER TABLE $table_name ADD CONSTRAINT $constraint_name FOREIGN KEY ($field_name) REFERENCES $ref_table_name ($ref_field_name)$on_delete_clause DEFERRABLE INITIALLY DEFERRED;"""
end
# function add_foreign_key(conn::PormGPostgres, model::PormGModel, constraint_name::String, field_name::String, ref_model::PormGModel, ref_field_name::String)
#   return add_foreign_key(model.name, model.name, constraint_name, field_name, ref_model.name, ref_field_name)
# end

function alter_field(conn::PormGPostgres, table_name::Union{Symbol,String}, field_name::Union{Symbol,String}, new_field::PormGField, old_field::Union{Nothing,PormGField}, colect_not_equal::Vector{Symbol})::String # TODO add old_field
  # Resolve to the physical column (db_column when set) so every ALTER targets the real
  # column even when called with the field-name key (e.g. the temporary-default cleanup in
  # _add_new_field). Idempotent when callers already pass the physical column (#50).
  field_name = field_db_column(new_field, string(field_name))
  sql_statements = []

  # Non-negative CHECK constraint diffing on a type transition (Django-style).
  # PostgreSQL has no unsigned integer type, so positive integer fields are backed by a
  # CHECK (col >= 0). When the column type changes into or out of a positive integer
  # field we add or drop that CHECK so it tracks the model rather than only the original
  # CREATE TABLE. The DROP must precede the TYPE change (an incompatible cast would
  # otherwise be blocked by the stale `>= 0` clause); the ADD must follow it.
  new_needs_check = _requires_non_negative_check(new_field)
  old_needs_check = old_field !== nothing && _requires_non_negative_check(old_field)
  if :type in colect_not_equal && old_needs_check && !new_needs_check
    constraint = get_constraints_check(conn, string(table_name), string(field_name))
    constraint !== nothing && push!(sql_statements, """ALTER TABLE "$table_name" DROP CONSTRAINT "$(constraint)";""")
  end

  # Alter column type
  if any(attr -> attr in colect_not_equal, [:type, :max_length, :max_digits, :decimal_places])
    if new_field isa sCharField
      max_length = hasproperty(new_field, :max_length) ? new_field.max_length : 255
      push!(sql_statements, """ALTER TABLE "$table_name" ALTER COLUMN "$field_name" TYPE VARCHAR($max_length);""")
    elseif new_field isa sDecimalField
      max_digits = hasproperty(new_field, :max_digits) ? new_field.max_digits : 10
      decimal_places = hasproperty(new_field, :decimal_places) ? new_field.decimal_places : 2
      push!(sql_statements, """ALTER TABLE "$table_name" ALTER COLUMN "$field_name" TYPE DECIMAL($max_digits, $decimal_places);""")
      if old_field !== nothing
        old_max_digits = hasproperty(old_field, :max_digits) ? old_field.max_digits : nothing
        old_decimal_places = hasproperty(old_field, :decimal_places) ? old_field.decimal_places : nothing
        if old_max_digits !== nothing && decimal_places < old_decimal_places
          @warn "The new decimal_places is less than the old decimal_places in table $(table_name) and field $(field_name)"
        end
      end
    elseif new_field isa sTimeField
      push!(sql_statements, """ALTER TABLE "$table_name" ALTER COLUMN "$field_name" TYPE TIME USING "$field_name"::time without time zone;""")
    elseif new_field isa sDurationField
      cast_expression = _postgres_interval_cast_expression(field_name, old_field)
      push!(sql_statements, """ALTER TABLE "$table_name" ALTER COLUMN "$field_name" TYPE INTERVAL USING $cast_expression;""")
    else
      push!(sql_statements, """ALTER TABLE "$table_name" ALTER COLUMN "$field_name" TYPE $(_get_column_type(new_field, conn));""")
    end
  end

  # Add the non-negative CHECK after the type change when the column became a positive
  # integer field (see the DROP counterpart above for the rationale and ordering).
  if :type in colect_not_equal && new_needs_check && !old_needs_check
    push!(sql_statements, """ALTER TABLE "$table_name" ADD $(_non_negative_check_clause(field_name));""")
  end

  # Set NOT NULL if specified
  if :null in colect_not_equal
    if !new_field.null
      push!(sql_statements, """ALTER TABLE "$table_name" ALTER COLUMN "$field_name" SET NOT NULL;""")
    else
      push!(sql_statements, """ALTER TABLE "$table_name" ALTER COLUMN "$field_name" DROP NOT NULL;""")
    end
  end

  # Set unique if specified
  if :unique in colect_not_equal
    if new_field.unique
      push!(sql_statements, """ALTER TABLE "$table_name" ADD UNIQUE ("$field_name");""")
    else
      contrains = get_constraints_unique(conn, table_name, field_name)
      if contrains !== nothing
        push!(sql_statements, """ALTER TABLE "$table_name" DROP CONSTRAINT "$(contrains)";""")
      end
    end
  end

  # Set default value if specified
  if :default in colect_not_equal
    if new_field.default !== nothing
      default_value = _format_default_sql_value(new_field.default)
      push!(sql_statements, """ALTER TABLE "$table_name" ALTER COLUMN "$field_name" SET DEFAULT $default_value;""")
    else
      push!(sql_statements, """ALTER TABLE "$table_name" ALTER COLUMN "$field_name" DROP DEFAULT;""")
    end
  end

  # Set primary key if specified
  if :primary_key in colect_not_equal
    if new_field.primary_key
      push!(sql_statements, """ALTER TABLE "$table_name" ADD PRIMARY KEY ("$field_name");""")
    else
      contrains = get_constraints_pk(conn, table_name)
      if contrains !== nothing
        push!(sql_statements, """ALTER TABLE "$table_name" DROP CONSTRAINT "$(contrains)";""")
      end
    end
  end

  # generated
  if :generated in colect_not_equal || :generated_always in colect_not_equal
    if new_field.generated
      if new_field.generated_always
        push!(sql_statements, """ALTER TABLE "$table_name" ALTER COLUMN "$field_name" ADD GENERATED ALWAYS AS IDENTITY;""")
      else
        push!(sql_statements, """ALTER TABLE "$table_name" ALTER COLUMN "$field_name" ADD GENERATED BY DEFAULT AS IDENTITY;""")
      end
    else
      push!(sql_statements, """ALTER TABLE "$table_name" ALTER COLUMN "$field_name" DROP IDENTITY;""")
    end
  end

  # alert if any colect_not_equal are not checked
  XXX::Vector{Symbol} = [:type, :max_length, :max_digits, :decimal_places, :null, :unique, :default, :primary_key, :generated, :generated_always, :blank, :auto_now, :auto_now_add]
  if any(attr -> !(attr in XXX), colect_not_equal)
    not_in = [attr for attr in colect_not_equal if !(attr in XXX)]
    @warn "The attributes $(not_in) are not implemented in alter_field function ($(table_name).$(field_name))"
  end
  return join(sql_statements, "\n")
end

function add_field(conn::PormGPostgres, table_name::Union{String,Symbol}, field_name::String, field::PormGField; temporary_default::Any=nothing)
  return """ALTER TABLE "$table_name" ADD COLUMN $(field_to_column(field_name, field, conn, temporary_default=temporary_default));"""
end

function add_field(conn::PormGSQLite, table_name::Union{String,Symbol}, field_name::String, field::PormGField; temporary_default::Any=nothing)
  return """ALTER TABLE "$table_name" ADD COLUMN $(field_to_column(field_name, field, conn, temporary_default=temporary_default));"""
end

function drop_field(conn::PormGPostgres, table_name::Union{String,Symbol}, field_name::Union{String,Symbol})
  return """ALTER TABLE "$table_name" DROP COLUMN "$field_name";"""
end

function drop_field(conn::PormGSQLite, table_name::Union{String,Symbol}, field_name::Union{String,Symbol})
  # Modern SQLite supports DROP COLUMN. If not, we'd need recreation.
  return """ALTER TABLE "$table_name" DROP COLUMN "$field_name";"""
end

function alter_field(conn::PormGPostgres, model::PormGModel, field_name::Union{Symbol,String}, new_field::PormGField, old_field::Union{Nothing,PormGField}, colect_not_equal::Vector{Symbol})
  return alter_field(conn, model.name |> lowercase, field_name, new_field, old_field, colect_not_equal)
end

function alter_field(conn::PormGSQLite, model::PormGModel, field_name::Union{Symbol,String}, new_field::PormGField, old_field::Union{Nothing,PormGField}, colect_not_equal::Vector{Symbol})
  # SQLite implementation using table recreation
  table_name = model.name |> lowercase
  new_table_name = "$(table_name)_new"

  # 1. Define columns for the NEW table (using current model state)
  columns_defs = []
  for (f_name, f) in model.fields
    push!(columns_defs, field_to_column(f_name |> string, f, conn))
  end

  # Add foreign key constraints (local + referenced columns honor db_column — #50)
  for (f_name, f) in model.fields
    if f isa sForeignKey && f.db_constraint
      on_delete_str = _foreign_key_on_delete_sql(f.on_delete)
      local_col = field_db_column(f, string(f_name))
      target_pk = fk_target_column(f)
      push!(columns_defs, "FOREIGN KEY (\"$local_col\") REFERENCES \"$(f.to |> format_model_name)\"(\"$target_pk\") ON DELETE $on_delete_str")
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
  model_cols = [field_db_column(f, string(k)) for (k, f) in model.fields]
  cols_joined = join(["\"$c\"" for c in model_cols], ", ")

  insert_sql = """INSERT INTO "$new_table_name" ($cols_joined) SELECT $cols_joined FROM "$table_name";"""

  return """DROP TABLE IF EXISTS "$new_table_name";
$create_sql;
$insert_sql;
DROP TABLE "$table_name";
ALTER TABLE "$new_table_name" RENAME TO "$table_name";"""
end

function rename_field(conn::Union{PormGSQLite,PormGPostgres}, table_name::Union{String,Symbol}, old_field_name::Union{String,Symbol}, new_field_name::Union{String,Symbol})
  return """ALTER TABLE "$table_name" RENAME COLUMN "$old_field_name" TO "$new_field_name";"""
end

function drop_foreign_key(conn::PormGPostgres, table_name::Symbol, constraint_name::String)
  return """ALTER TABLE "$table_name" DROP CONSTRAINT "$constraint_name";"""
end

# NOTE (#83): there is intentionally no `drop_foreign_key(::PormGSQLite, …)`. SQLite has no
# `ALTER TABLE DROP CONSTRAINT`, so an FK is removed by rebuilding the table from the desired model
# (see `alter_field(::PormGSQLite, model, …)` + `_sqlite_rebuild_preserving_indexes`), which omits
# the FK clause. The planner's `_drop_fk_constraint_in_alteration` is therefore a no-op on SQLite.

function drop_index(conn::PormGPostgres, index_name::String)
  return """DROP INDEX IF EXISTS "$index_name";"""
end
function drop_index(conn::PormGSQLite, index_name::String)
  return """DROP INDEX IF EXISTS "$index_name";"""
end

function rename_table(conn::Union{PormGSQLite,PormGPostgres}, old_table_name::String, new_table_name::String)
  return """ALTER TABLE "$old_table_name" RENAME TO "$new_table_name";"""
end

function drop_table(conn::PormGPostgres, table_name::Union{String,Symbol})
  return """DROP TABLE IF EXISTS "$table_name" CASCADE;"""
end
function drop_table(conn::PormGSQLite, table_name::Union{String,Symbol})
  return """DROP TABLE IF EXISTS "$table_name";"""
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

function get_objects_to_delete(connection::PormGPostgres, model::PormGModel, instruction::SQLInstruction)::Vector{NamedTuple}
  # Get the SQL that identifies objects to be deleted
  sql_to_delete = """
    SELECT "$(get_model_pk_field(model))"
    FROM $(model.name |> lowercase) as $(instruction.alias)
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
  throw(ArgumentError("The @jcontains lookup (JSONB @>) requires PostgreSQL"))
end
function jcontains(conn::PormGAbstractType, column::String, value)
  throw(ArgumentError("The @jcontains lookup (JSONB @>) requires PostgreSQL"))
end

function has_key(conn::PormGPostgres, column::String, value::String)::String
  return "$(column) ? $(value)"                     # top-level key exists
end
function has_key(conn::PormGSQLite, column::String, value::String)
  throw(ArgumentError("The @has_key lookup (JSONB ?) requires PostgreSQL"))
end
function has_key(conn::PormGAbstractType, column::String, value)
  throw(ArgumentError("The @has_key lookup (JSONB ?) requires PostgreSQL"))
end

function has_any_keys(conn::PormGPostgres, column::String, value::String)::String
  return "$(column) ?| $(value)"                    # any of the given keys exists
end
function has_any_keys(conn::PormGSQLite, column::String, value::String)
  throw(ArgumentError("The @has_any_keys lookup (JSONB ?|) requires PostgreSQL"))
end
function has_any_keys(conn::PormGAbstractType, column::String, value)
  throw(ArgumentError("The @has_any_keys lookup (JSONB ?|) requires PostgreSQL"))
end

function has_keys(conn::PormGPostgres, column::String, value::String)::String
  return "$(column) ?& $(value)"                    # all of the given keys exist
end
function has_keys(conn::PormGSQLite, column::String, value::String)
  throw(ArgumentError("The @has_keys lookup (JSONB ?&) requires PostgreSQL"))
end
function has_keys(conn::PormGAbstractType, column::String, value)
  throw(ArgumentError("The @has_keys lookup (JSONB ?&) requires PostgreSQL"))
end

function contains(conn::PormGPostgres, column::String, value::String)::String
  return "$(column) LIKE $(value)$(_like_escape_clause())"
end
function contains(conn::PormGSQLite, column::String, value::String)::String
  return "$(column) LIKE $(value)$(_like_escape_clause())"
end
function contains(conn::PormGAbstractType, column::String, value)
  throw(ArgumentError("The value must be a String"))
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
  throw(ArgumentError("The value must be a String"))
  return nothing
end

function iunaccent_contains(conn::PormGPostgres, column::String, value::String)::String
  # Uses the IMMUTABLE wrapper (see Configuration._install_immutable_unaccent!) so the
  # expression can be backed by a functional/pg_trgm index on large tables.
  return "public.immutable_unaccent($(column)) ILIKE public.immutable_unaccent($(value))$(_like_escape_clause())"
end
function iunaccent_contains(conn::PormGSQLite, column::String, value::String)
  throw(ArgumentError("The iunaccent_contains lookup requires PostgreSQL and the unaccent extension"))
  return nothing
end
function iunaccent_contains(conn::PormGAbstractType, column::String, value)
  throw(ArgumentError("The value must be a String"))
  return nothing
end

function iunaccent_exact(conn::PormGPostgres, column::String, value::String)::String
  # Accent- and case-insensitive equality. Uses the IMMUTABLE wrapper (see
  # Configuration._install_immutable_unaccent!) so it can be backed by a functional
  # index on LOWER(public.immutable_unaccent(column)).
  return "LOWER(public.immutable_unaccent($(column))) = LOWER(public.immutable_unaccent($(value)))"
end
function iunaccent_exact(conn::PormGSQLite, column::String, value::String)
  throw(ArgumentError("The iunaccent_exact lookup requires PostgreSQL and the unaccent extension"))
  return nothing
end
function iunaccent_exact(conn::PormGAbstractType, column::String, value)
  throw(ArgumentError("The value must be a String"))
  return nothing
end

function startswith(conn::PormGPostgres, column::String, value::String)::String
  return "$(column) LIKE $(value)$(_like_escape_clause())"
end
function startswith(conn::PormGSQLite, column::String, value::String)::String
  return "$(column) LIKE $(value)$(_like_escape_clause())"
end
function startswith(conn::PormGAbstractType, column::String, value)
  throw(ArgumentError("The value must be a String"))
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
  throw(ArgumentError("The value must be a String"))
  return nothing
end

function endswith(conn::PormGPostgres, column::String, value::String)::String
  return "$(column) LIKE $(value)$(_like_escape_clause())"
end
function endswith(conn::PormGSQLite, column::String, value::String)::String
  return "$(column) LIKE $(value)$(_like_escape_clause())"
end
function endswith(conn::PormGAbstractType, column::String, value)
  throw(ArgumentError("The value must be a String"))
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
  throw(ArgumentError("The value must be a String"))
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
  throw(ArgumentError("The value must be a String"))
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
  throw(ArgumentError("The value must be a String"))
  return nothing
end

function niunaccent_contains(conn::PormGPostgres, column::String, value::String)::String
  return "public.immutable_unaccent($(column)) NOT ILIKE public.immutable_unaccent($(value))$(_like_escape_clause())"
end
function niunaccent_contains(conn::PormGSQLite, column::String, value::String)
  throw(ArgumentError("The niunaccent_contains lookup requires PostgreSQL and the unaccent extension"))
  return nothing
end
function niunaccent_contains(conn::PormGAbstractType, column::String, value)
  throw(ArgumentError("The value must be a String"))
  return nothing
end

function niunaccent_exact(conn::PormGPostgres, column::String, value::String)::String
  return "LOWER(public.immutable_unaccent($(column))) <> LOWER(public.immutable_unaccent($(value)))"
end
function niunaccent_exact(conn::PormGSQLite, column::String, value::String)
  throw(ArgumentError("The niunaccent_exact lookup requires PostgreSQL and the unaccent extension"))
  return nothing
end
function niunaccent_exact(conn::PormGAbstractType, column::String, value)
  throw(ArgumentError("The value must be a String"))
  return nothing
end

function nstartswith(conn::PormGPostgres, column::String, value::String)::String
  return "$(column) NOT LIKE $(value)$(_like_escape_clause())"
end
function nstartswith(conn::PormGSQLite, column::String, value::String)::String
  return "$(column) NOT LIKE $(value)$(_like_escape_clause())"
end
function nstartswith(conn::PormGAbstractType, column::String, value)
  throw(ArgumentError("The value must be a String"))
  return nothing
end

function nendswith(conn::PormGPostgres, column::String, value::String)::String
  return "$(column) NOT LIKE $(value)$(_like_escape_clause())"
end
function nendswith(conn::PormGSQLite, column::String, value::String)::String
  return "$(column) NOT LIKE $(value)$(_like_escape_clause())"
end
function nendswith(conn::PormGAbstractType, column::String, value)
  throw(ArgumentError("The value must be a String"))
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