module Dialect
using Dates, TimeZones
using SQLite
using DataFrames
using LibPQ
import PormG: SQLConn, SQLType, SQLInstruction, SQLTypeQ, SQLTypeQor, SQLTypeF, SQLTypeOper, SQLObject, AbstractModel, PormGModel, PormGField, PormGPostgres, PormGSQLite, PormGAbstractType
import PormG.ConnectionPool: fetch
import PormG: postgres_type_map, postgres_type_map_reverse, sqlite_date_format_map, sqlite_type_map_reverse
import PormG: get_constraints_pk, get_constraints_unique
import PormG.Models: Migration, get_model_pk_field, format_model_name

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
import PormG.Models: sIDField, sCharField, sTextField, sBooleanField, sIntegerField, sBigIntegerField, sFloatField, sDecimalField, sDateField, sDateTimeField, sTimeField, sDurationField, sForeignKey, sUUIDField, sURLField, sSlugField, sJSONField

function _format_default_sql_value(default_value)
  if default_value isa AbstractString
    return "'$(replace(default_value, "'" => "''"))'"
  elseif default_value isa Bool
    return default_value ? "TRUE" : "FALSE"
  elseif default_value isa Union{Date, DateTime, ZonedDateTime, Time}
    return "'$default_value'"
  end

  return string(default_value)
end

function _postgres_interval_cast_expression(field_name::Union{String, Symbol}, old_field::Union{Nothing, PormGField})
  column_ref = "\"$(field_name)\""

  if old_field isa Union{sFloatField, sDecimalField, sIntegerField, sBigIntegerField}
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
  elseif field isa sIntegerField || field isa sBigIntegerField
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

function field_to_column(col_name::String, field::PormGField, conn::PormGPostgres; temporary_default::Any=nothing)::String
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

  # Combine everything into a single string: "col_name base_type constraints..."
  return join(["\"$(col_name)\"", base_type, join(constraints, " ")], " ")
end

function field_to_column(col_name::String, field::PormGField, conn::PormGSQLite; temporary_default::Any=nothing)::String
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
    push!(columns, field_to_column(field_name |> string, field, conn))
  end

  return create_table(conn, model.name |> lowercase, columns)
end

function create_table(conn::PormGSQLite, model::PormGModel)
  columns::Vector{String} = []
  for (field_name, field) in model.fields
    push!(columns, field_to_column(field_name |> string, field, conn))
  end

  # Add foreign key constraints for SQLite during CREATE TABLE
  for (field_name, field) in model.fields
    if field isa sForeignKey && field.db_constraint
      on_delete_str = _foreign_key_on_delete_sql(field.on_delete)
      target_pk = isnothing(field.pk_field) ? "id" : field.pk_field
      push!(columns, "FOREIGN KEY (\"$field_name\") REFERENCES \"$(field.to |> format_model_name)\"(\"$target_pk\") ON DELETE $on_delete_str")
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

function add_foreign_key(conn::PormGPostgres, table_name::Union{Symbol,String}, constraint_name::String, field_name::String, ref_table_name::String, ref_field_name::String)
  return """ALTER TABLE $table_name ADD CONSTRAINT $constraint_name FOREIGN KEY ($field_name) REFERENCES $ref_table_name ($ref_field_name) DEFERRABLE INITIALLY DEFERRED;"""
end
# function add_foreign_key(conn::PormGPostgres, model::PormGModel, constraint_name::String, field_name::String, ref_model::PormGModel, ref_field_name::String)
#   return add_foreign_key(model.name, model.name, constraint_name, field_name, ref_model.name, ref_field_name)
# end

function alter_field(conn::PormGPostgres, table_name::Union{Symbol,String}, field_name::Union{Symbol,String}, new_field::PormGField, old_field::Union{Nothing,PormGField}, colect_not_equal::Vector{Symbol})::String # TODO add old_field
  sql_statements = []

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

function alter_field(conn::PormGSQLite, table_name::String, field_name::String, new_field::PormGField)
  # SQLite does not support altering column types directly.
  # You need to recreate the table. Here's a simplified example.
  # Note: This is a complex operation and may require handling additional constraints.

  # Define a unique identifier for the new table
  new_table_name = "$(table_name)_new"

  # Retrieve existing columns excluding the one to be altered
  existing_columns = Dialect.get_columns(conn, table_name)  # You need to implement this function
  columns_sql = join([col == field_name ? field_to_column(field_name, new_field, conn) : "\"$col\"" for col in existing_columns], ", ")

  # Begin transaction
  migration_sql = [
    "BEGIN TRANSACTION;",
    """CREATE TABLE "$new_table_name" ($columns_sql);""",
    """INSERT INTO "$new_table_name" SELECT * FROM "$table_name";""",
    """DROP TABLE "$table_name";""",
    """ALTER TABLE "$new_table_name" RENAME TO "$table_name";""",
    "COMMIT;"
  ]

  return join(migration_sql, "\n")

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

function get_columns(conn::PormGSQLite, table_name::String)
  res = fetch(conn, "PRAGMA table_info(\"$table_name\")") |> DataFrame
  return res.name
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

  # Add foreign key constraints
  for (f_name, f) in model.fields
    if f isa sForeignKey && f.db_constraint
      on_delete_str = _foreign_key_on_delete_sql(f.on_delete)
      target_pk = isnothing(f.pk_field) ? "id" : f.pk_field
      push!(columns_defs, "FOREIGN KEY (\"$f_name\") REFERENCES \"$(f.to |> format_model_name)\"(\"$target_pk\") ON DELETE $on_delete_str")
    end
  end

  create_sql = """CREATE TABLE "$new_table_name" (
  $(join(columns_defs, ",\n  "))
);"""

  # 2. Get common columns between old and new to preserve data
  old_cols = get_columns(conn, string(table_name))
  model_cols = [string(k) for k in keys(model.fields)]
  common_cols = intersect(old_cols, model_cols)
  cols_joined = join(["\"$c\"" for c in common_cols], ", ")

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

function drop_foreign_key(conn::PormGSQLite, table_name::String, constraint_name::String)
  # SQLite does not support dropping foreign keys directly.
  # Implement the workaround by recreating the table without the foreign key.

  # Define a unique identifier for the new table
  new_table_name = "$(table_name)_new"

  # Retrieve existing columns and constraints excluding the foreign key
  # You need to implement Dialect.get_columns and Dialect.get_constraints excluding the specific foreign key
  existing_columns = Dialect.get_columns(conn, table_name)  # Implement this function
  existing_constraints = Dialect.get_constraints(conn, table_name)  # Implement this function

  # Remove the specific foreign key constraint from constraints
  filtered_constraints = [c for c in existing_constraints if c != constraint_name]

  # Recreate the CREATE TABLE statement without the foreign key constraint
  columns_sql = join(["\"$col\"" for col in existing_columns], ", ")
  constraints_sql = isempty(filtered_constraints) ? "" : ", " * join(["FOREIGN KEY ($fk_col) REFERENCES $ref_table($ref_col)" for (fk_col, ref_table, ref_col) in filtered_constraints], ", ")

  # Begin transaction
  migration_sql = [
    "BEGIN TRANSACTION;",
    """CREATE TABLE "$new_table_name" ($columns_sql$constraints_sql);""",
    """INSERT INTO "$new_table_name" SELECT * FROM "$table_name";""",
    """DROP TABLE "$table_name";""",
    """ALTER TABLE "$new_table_name" RENAME TO "$table_name";""",
    "COMMIT;"
  ]

  return join(migration_sql, "\n")

end

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
  result = LibPQ.execute(connection, sql_to_delete)
  return Tables.rowtable(result)
end

# ---
# Function to deal with operators
#

_like_escape_clause() = " ESCAPE '\\'"

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
  return "LOWER($(column)) LIKE LOWER($(value))$(_like_escape_clause())"
end
function icontains(conn::PormGAbstractType, column::String, value)
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
  return "LOWER($(column)) LIKE LOWER($(value))$(_like_escape_clause())"
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
  return "LOWER($(column)) LIKE LOWER($(value))$(_like_escape_clause())"
end
function iendswith(conn::PormGAbstractType, column::String, value)
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
  "is_destructive" BOOLEAN NOT NULL DEFAULT FALSE
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
  "is_destructive" BOOLEAN NOT NULL DEFAULT 0
);"""
end

"""
    insert_migration_record_sql(conn::PormGPostgres) -> String

Returns parameterized INSERT for recording an applied migration (PostgreSQL).
"""
function insert_migration_record_sql(conn::PormGPostgres)::String
  return """INSERT INTO pormg_migrations ("version", "name", "checksum", "sql_content", "status", "is_destructive") VALUES (\$1, \$2, \$3, \$4, \$5, \$6);"""
end

"""
    insert_migration_record_sql(conn::PormGSQLite) -> String

Returns parameterized INSERT for recording an applied migration (SQLite).
"""
function insert_migration_record_sql(conn::PormGSQLite)::String
  return """INSERT INTO pormg_migrations ("version", "name", "checksum", "sql_content", "status", "is_destructive") VALUES (?, ?, ?, ?, ?, ?);"""
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
  return """SELECT "id", "version", "name", "checksum", "sql_content", "applied_at", "status", "is_destructive" FROM pormg_migrations ORDER BY "version" ASC;"""
end

"""
    select_migration_by_version_sql(conn::PormGPostgres) -> String

Returns parameterized SQL to select a single migration by version (PostgreSQL).
"""
function select_migration_by_version_sql(conn::PormGPostgres)::String
  return """SELECT "id", "version", "name", "checksum", "sql_content", "applied_at", "status", "is_destructive" FROM pormg_migrations WHERE "version" = \$1;"""
end

"""
    select_migration_by_version_sql(conn::PormGSQLite) -> String

Returns parameterized SQL to select a single migration by version (SQLite).
"""
function select_migration_by_version_sql(conn::PormGSQLite)::String
  return """SELECT "id", "version", "name", "checksum", "sql_content", "applied_at", "status", "is_destructive" FROM pormg_migrations WHERE "version" = ?;"""
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

end