module Dialect
using Dates
using SQLite
using DataFrames
using LibPQ
import PormG: SQLConn, SQLType, SQLInstruction, SQLTypeQ, SQLTypeQor, SQLTypeF, SQLTypeOper, SQLObject, AbstractModel, PormGModel, PormGField
import PormG: postgres_type_map, postgres_type_map_reverse, sqlite_date_format_map, sqlite_type_map_reverse
import PormG.Models: Migration

# PostgreSQL
function EXTRACT_DATE(column::String, format::Dict{String, Any}, conn::LibPQ.Connection)
  format_str = format["format"]
  locale = get(format, "locale", "")
  nlsparam = get(format, "nlsparam", "")
  return "to_char($(column), '$(format_str)') $(locale) $(nlsparam)"
end
# SQLite
function EXTRACT_DATE(column::String, format::Dict{String, Any}, conn::SQLite.DB)
  format_str = format["format"]
  locale = get(format, "locale", "")
  return "strftime('$(sqlite_date_format_map[format_str])', $(column)) $(locale)"
end

function SUM(column::String, format::Dict{String, Any}, conn::Union{LibPQ.Connection,SQLite.DB})
  if get(format, "distinct", false)
    return "SUM(DISTINCT $(column))"
  else
    return "SUM($(column))"
  end
end
function AVG(column::String, format::Dict{String, Any}, conn::Union{LibPQ.Connection,SQLite.DB})
  if get(format, "distinct", false)
    return "AVG(DISTINCT $(column))"
  else
    return "AVG($(column))"
  end
end
function COUNT(column::String, format::Dict{String, Any}, conn::Union{LibPQ.Connection,SQLite.DB})
  if get(format, "distinct", false)
    return "COUNT(DISTINCT $(column))"
  else
    return "COUNT($(column))"
  end
end
function MAX(column::String, format::Dict{String, Any}, conn::Union{LibPQ.Connection,SQLite.DB})
  return "MAX($(column))"
end
function MIN(column::String, format::Dict{String, Any}, conn::Union{LibPQ.Connection,SQLite.DB})
  return "MIN($(column))"
end

# Same that function CAST in django ORM
# # relatorio = relatorio.annotate(quarter=functions.Concat(functions.Cast(f'{data}__year', CharField()), Value('-Q'), Case(
# # 					When(**{ f'{data}__month__lte': 4 }, then=Value('1')),
# # 					When(**{ f'{data}__month__lte': 8 }, then=Value('2')),
# # 					When(**{ f'{data}__month__lte': 12 }, then=Value('3')),
# # 					output_field=CharField()
# # 				)))
function VALUE(value::String, conn::LibPQ.Connection)
  return "('$(value)')::text"
end
function VALUE(value::String, conn::SQLite.DB)
  return "'$(value)'"
end
function CAST(column::String, format::Dict{String, Any}, conn::LibPQ.Connection)
  return """($column)::$(format["type"])"""
end
function CAST(column::String, format::Dict{String, Any}, conn::SQLite.DB)
  return "CAST($column AS $(sqlite_type_map_reverse[format["type"]]))"
end
function CONCAT(column::Array{Any, 1}, format::Dict{String, Any}, conn::LibPQ.Connection)
  return "CONCAT($(join(column, ",\n")))"
end
function CONCAT(column::Array{Any, 1}, format::Dict{String, Any}, conn::SQLite.DB)
  return "($(join(column, " ||\n")))"
end
function EXTRACT(column::String, format::Dict{String, Any}, conn::LibPQ.Connection)
  if haskey(format, "format")
    return "EXTRACT($(format["part"]) FROM $(column))$(format["format"])"  
  else
    return "EXTRACT($(format["part"]) FROM $(column))"  
  end
end
function CASE(column::Vector{Any}, format::Dict{String, Any}, conn::LibPQ.Connection)
  if format["output_field"] != ""
    return """(CASE
    $(join(column, "\n"))
    ELSE $(format["else"])
    END)::$(format["output_field"])
    """
  else 
    return """CASE
    $(join(column, "\n"))
    ELSE $(format["else"])
    END
    """
  end
end
function CASE(column::String, format::Dict{String, Any}, conn::LibPQ.Connection)
  return """CASE $(column) ELSE $(format["else"]) END"""
end
function CASE(column::Vector{Any}, format::Dict{String, Any}, conn::SQLite.DB)
  resp::String = """CASE
    $(join(column, "\n"))
    ELSE $(format["else"])
    END
    """
  if format["output_field"] != ""
    return CAST(resp, Dict{String, Any}("type" => format["output_field"]), conn)    
  else 
    return resp
  end
end

function WHEN(column::String, format::Dict{String, Any}, conn::Union{LibPQ.Connection,SQLite.DB})
  return "WHEN $(column) THEN $(format["then"])" |> string
end


# postgresql query synopsis
# CREATE [ [ GLOBAL | LOCAL ] { TEMPORARY | TEMP } | UNLOGGED ] TABLE [ IF NOT EXISTS ] table_name ( [
#   { column_name data_type [ STORAGE { PLAIN | EXTERNAL | EXTENDED | MAIN | DEFAULT } ] [ COMPRESSION compression_method ] [ COLLATE collation ] [ column_constraint [ ... ] ]
#     | table_constraint
#     | LIKE source_table [ like_option ... ] }
#     [, ... ]
# ] )
# [ INHERITS ( parent_table [, ... ] ) ]
# [ PARTITION BY { RANGE | LIST | HASH } ( { column_name | ( expression ) } [ COLLATE collation ] [ opclass ] [, ... ] ) ]
# [ USING method ]
# [ WITH ( storage_parameter [= value] [, ... ] ) | WITHOUT OIDS ]
# [ ON COMMIT { PRESERVE ROWS | DELETE ROWS | DROP } ]
# [ TABLESPACE tablespace_name ]

# ---
# Convert PormGField to SQL column string
# ---
import PormG.Models: sIDField, sCharField, sTextField, sBooleanField, sIntegerField, sBigIntegerField, sFloatField, sDecimalField, sDateField, sDateTimeField, sTimeField, sForeignKey
function field_to_column(col_name::String, field::PormGField, conn::Union{LibPQ.Connection, SQLite.DB}; type_map::Dict{String, String} = postgres_type_map_reverse)
  # Determine the base SQL type for PostgreSQL
  base_type = ""
  if field isa sIDField
    base_type = type_map[field.type]    
  elseif field isa sCharField
    max_len = hasproperty(field, :max_length) ? field.max_length : 250
    base_type = "$(type_map[field.type])($max_len)"
  elseif field isa sTextField
    base_type = type_map[field.type]
  elseif field isa sBooleanField
    base_type = type_map[field.type]
  elseif field isa sIntegerField
    base_type = type_map[field.type]
  elseif field isa sBigIntegerField
    base_type = type_map[field.type]
  elseif field isa sFloatField
    base_type = type_map[field.type]
  elseif field isa sDecimalField
    max_digits = hasproperty(field, :max_digits) ? field.max_digits : 10
    decimal_places = hasproperty(field, :decimal_places) ? field.decimal_places : 2
    base_type = "$(type_map[field.type])($max_digits, $decimal_places)"
  elseif field isa sDateField
    base_type = type_map[field.type]
  elseif field isa sDateTimeField
    base_type = type_map[field.type]
  elseif field isa sTimeField
    base_type = type_map[field.type]
  elseif field isa sForeignKey
    base_type = type_map[field.type]
  else
      # Generic fallback
      base_type = "TEXT"
  end

  # Build constraints
  constraints = String[]
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
  if field.default !== nothing
    default_value = field.default
    if isa(default_value, String)
      default_value = "'$default_value'"
    elseif isa(default_value, Bool)
      default_value = default_value ? "TRUE" : "FALSE"
    elseif isa(default_value, Date) || isa(default_value, DateTime)
      default_value = "'$default_value'"
    end
    push!(constraints, "DEFAULT $default_value")
  end


  # Generated by default as identity
  if hasproperty(field, :generated) && getfield(field, :generated)
    push!(constraints, "GENERATED BY DEFAULT AS IDENTITY")
  end

  # Combine everything into a single string: "col_name base_type constraints..."
  return join(["\"$(col_name)\"", base_type, join(constraints, " ")], " ")
end

# ---
# Functions to create migration queries
#

function create_table(conn::Union{SQLite.DB, LibPQ.Connection}, table_name::String, columns::Vector{String})
  return """CREATE TABLE IF NOT EXISTS $(table_name) (\n  $(join(columns, ",\n  "))
    );""" #|> x -> replace(x, "\\\"" => "\"")
end
function create_table(conn::LibPQ.Connection, model::PormGModel)
  columns::Vector{String} = []
  for (field_name, field) in model.fields    
    push!(columns, field_to_column(field_name, field, conn))
  end
  return create_table(conn, model.name |> lowercase, columns)
end


function create_index(conn::Union{SQLite.DB, LibPQ.Connection}, index_name::String, table_name::String, columns::Vector{String})
  return """CREATE INDEX IF NOT EXISTS $(index_name) ON $(table_name) ($(join(columns, ", ")));"""
end


function add_foreign_key(conn::LibPQ.Connection, table_name::Symbol, constraint_name::String, field_name::String, ref_table_name::String, ref_field_name::String)
  return """ALTER TABLE $table_name ADD CONSTRAINT $constraint_name FOREIGN KEY ($field_name) REFERENCES $ref_table_name ($ref_field_name) DEFERRABLE INITIALLY DEFERRED;"""
end
# function add_foreign_key(conn::LibPQ.Connection, model::PormGModel, constraint_name::String, field_name::String, ref_model::PormGModel, ref_field_name::String)
#   return add_foreign_key(model.name, model.name, constraint_name, field_name, ref_model.name, ref_field_name)
# end

function alter_field(conn::LibPQ.Connection, table_name::String, field_name::String, new_field::PormGField)
  return """ALTER TABLE "$table_name" ALTER COLUMN "$field_name"  TYPE $(field_to_column(field_name, new_field, conn));"""
end

function alter_field(conn::SQLite.DB, table_name::String, field_name::String, new_field::PormGField)  
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

function drop_foreign_key(conn::LibPQ.Connection, table_name::Symbol, constraint_name::String)
  return """ALTER TABLE "$table_name" DROP CONSTRAINT "$constraint_name";"""
end
  
function drop_foreign_key(conn::SQLite.DB, table_name::String, constraint_name::String)
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
      columns_sql = join([ "\"$col\"" for col in existing_columns ], ", ")
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

function drop_index(conn::LibPQ.Connection, index_name::String)
  return """DROP INDEX IF EXISTS "$index_name";"""
end
function drop_index(conn::SQLite.DB, index_name::String)
  return """DROP INDEX IF EXISTS "$index_name";"""  
end


# function apply_migration(db::SQLite.DB, migration::DropTable)
#   query = "DROP TABLE IF EXISTS $(migration.table_name)"
#   SQLite.execute(db, query)
# end

# function apply_migration(db::SQLite.DB, migration::AddColumn)
#   query = "ALTER TABLE $(migration.table_name) ADD COLUMN $(migration.column_name) $(migration.column_type)"
#   SQLite.execute(db, query)
# end

# function apply_migration(db::SQLite.DB, migration::DropColumn)
#   query = "ALTER TABLE $(migration.table_name) DROP COLUMN $(migration.column_name)"
#   SQLite.execute(db, query)
# end

# function apply_migration(db::SQLite.DB, migration::RenameColumn)
#   query = "ALTER TABLE $(migration.table_name) RENAME COLUMN $(migration.old_column_name) TO $(migration.new_column_name)"
#   SQLite.execute(db, query)
# end

# function apply_migration(db::SQLite.DB, migration::AlterColumn)
#   query = "ALTER TABLE $(migration.table_name) RENAME COLUMN $(migration.column_name) TO $(migration.new_column_name); ALTER TABLE $(migration.table_name) ALTER COLUMN $(migration.new_column_name) TYPE $(migration.new_column_type)"
#   SQLite.execute(db, query)
# end


# function apply_migration(db::SQLite.DB, migration::DropForeignKey)
#   query = "ALTER TABLE $(migration.table_name) DROP FOREIGN KEY $(migration.column_name)"
#   SQLite.execute(db, query)
# end


# function apply_migration(db::SQLite.DB, migration::DropIndex)
#   query = "DROP INDEX IF EXISTS $(migration.table_name)_$(migration.column_name)_index"
#   SQLite.execute(db, query)
# end

# function apply_migration(db::SQLite.DB, migration::Migration)
#   @warn "Migration type not recognized"
# end


end