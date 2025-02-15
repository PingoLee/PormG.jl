const DBDF_FOLDER_NAME = "migrations"

const CONFIG_PATH     = "config"
const ENV_PATH        = joinpath(CONFIG_PATH, "env")
const LOG_PATH        = "log"
const APP_PATH        = "app"
const RESOURCES_PATH  = joinpath(APP_PATH, "resources")
const TEST_PATH       = "test"
const DB_PATH         = "db"
const MODEL_PATH      = joinpath(DB_PATH)
const MODEL_FILE      = "models.jl"
const DBDF_PATH       = joinpath(DB_PATH, DBDF_FOLDER_NAME)

const PORMG_DB_CONFIG_FILE_NAME = "connection.yml"

const TEST_FILE_IDENTIFIER = "_test.jl"

const LAST_INSERT_ID_LABEL = "LAST_INSERT_ID"

const PORMG_ENV = ENV["PORMG_ENV"]

# Constants for dealing with datetime in UTC
const DATETIME_FORMAT = "yyyy-mm-ddTHH:MM:SS.ssszzzz"
const UTC_TIMEZONE = "UTC"

const reserved_words = [
  "if", "else", "elseif", "while", "for", "begin", "end", "function", "return",
  "break", "continue", "global", "local", "const", "let", "do", "try", "catch",
  "finally", "struct", "mutable", "abstract", "primitive", "type", "quote",
  "macro", "module", "baremodule", "using", "import", "export", "importall",
  "where", "in", "isa", "throw", "true", "false", "nothing", "missing", "id"
]

const PormGsuffix = Dict{String,Union{Int64, String}}( # TODO: REMOVE THIS
  "gte" => ">=",
  "gt" => ">",
  "lte" => "<=",
  "lt" => "<",
  "isnull" => "ISNULL",
  "contains" => "contains",

)

const PormGtrasnform = Dict{String,Union{Int64, String}}( # TODO: REMOVE THIS
  "date" => "DATE",
  "month" => "MONTH",
  "year" => "YEAR",
  "day" => "DAY",  
  "yyyy_mm" => "Y_M",
  "quarter" => "QUARTER",
)

# dictionary from function to type of the field
const PormGTypeField = Dict{String,Symbol}(
  "COUNT" => :format_number_sql,
  "EXTRACT" => :format_number_sql,
  "TO_CHAR" => :format_text_sql,
)

# I whant work with dictionary to handle pool connections

const sqlite_type_map = Dict{String, Symbol}(
  "INTEGER" => :IntegerField, 
  "INT" => :BigIntegerField,
  "TEXT" => :CharField,
  "NUMERIC" => :FloatField,
  "REAL" => :FloatField,
  "DECIMAL" => :DecimalField,
  "DATETIME" => :DateTimeField,
  "TIME" => :TimeField,
  "DATE" => :DateField,
  "BLOB" => :BinaryField,
  "BOOLEAN" => :BooleanField
)

const postgres_type_map = Dict{String, Symbol}(
  "integer" => :IntegerField,
  "bigint" => :BigIntegerField,
  "boolean" => :BooleanField,
  "date" => :DateField,
  "timestamp" => :DateTimeField,
  "decimal" => :DecimalField,
  "numeric" => :DecimalField,
  "varchar" => :CharField,
  "character" => :CharField,
  "text" => :TextField,
  "float" => :FloatField,
  "time" => :TimeField,
  "blob" => :BinaryField,
  "double_precision" => :FloatField,
)

# const postgres_map_type_to_cast = Dict{String, String}(
#   "TIME" => "time",
#   "DATE" => "date",
#   "TIMESTAMP" => "timestamp",
#   "INTEGER" => "integer",
#   "BIGINT" => "bigint",
#   "FLOAT" => "float",
#   "BIGINT" => "bigint",
#   "DECIMAL" => "decimal",
#   "TEXT" => "text",
#   "VARCHAR" => "varchar"
# )


const sqlite_type_map_reverse = Dict{String, String}(
  "VARCHAR" => "TEXT",
  "CHAR" => "TEXT",
  "INTEGER" => "INTEGER",
  "BIGINT" => "INTEGER",
  "FLOAT" => "REAL",
  "DECIMAL" => "DECIMAL",
  "DATETIME" => "DATETIME",
  "TIME" => "TIME",
  "DATE" => "DATE",
  "BLOB" => "BLOB",
)

const postgres_type_map_reverse = Dict{String, String}(
  "BIGSERIAL" => "bigserial",
  "SERIAL" => "serial",
  "BIGINT" => "bigint",
  "INTEGER" => "integer",
  "SMALLINT" => "smallint",
  "DECIMAL" => "decimal",
  "FLOAT" => "float",
  "NUMERIC" => "decimal",
  "REAL" => "real",
  "DOUBLE_PRECISION" => "float",
  "MONEY" => "money",
  "CHAR" => "char",
  "VARCHAR" => "varchar",
  "TEXT" => "text",
  "BYTEA" => "bytea",
  "TIMESTAMPTZ" => "timestamptz",
  "DATE" => "date",
  "TIME" => "time",  
  "INTERVAL" => "interval",
  "BOOLEAN" => "boolean",
  "POINT" => "point",
  "LINE" => "line",
  "LSEG" => "lseg",
  "BOX" => "box",
  "PATH" => "path",
  "POLYGON" => "polygon",
  "CIRCLE" => "circle",
  "CIDR" => "cidr",
  "INET" => "inet",
  "MACADDR" => "macaddr",
  "BIT" => "bit",
  "VARBIT" => "varbit",
  "UUID" => "uuid",
  "XML" => "xml",
  "JSON" => "json",
  "JSONB" => "jsonb",
  "ARRAY" => "array",
  "HSTORE" => "hstore"
)

const sqlite_date_format_map = Dict{String, String}(
  "YYYY" => "%Y",
  "MM" => "%m",
  "DD" => "%d",
  "HH" => "%H",
  "MI" => "%M",
  "SS" => "%S",
  "YYYY-MM-DD" => "%Y-%m-%d",
  "YYYY-MM" => "%Y-%m",
  "YYYY-MM-DD HH:MI:SS" => "%Y-%m-%d %H:%M:%S",
  "YYYY-MM-DD HH:MI:SS.SSS" => "%Y-%m-%d %H:%M:%S.%f",
  "YYYY-MM-DDTHH:MI:SS" => "%Y-%m-%dT%H:%M:%S",
  "YYYY-MM-DDTHH:MI:SS.SSS" => "%Y-%m-%dT%H:%M:%S.%f",
  "HH:MI:SS" => "%H:%M:%S",
  "HH:MI:SS.SSS" => "%H:%M:%S.%f",
  "HH:MI" => "%H:%M"
)



const sqlite_ignore_schema::Vector{String} = ["sqlite_sequence", "sqlite_autoindex"]

const postgres_ignore_table::Vector{String} = ["auth_", "django_", "social_", "account_", "allauth_", "admin_", "celery_", "django_celery_", "djcelery_", "kombu_"]