const DBDF_FOLDER_NAME = "migrations"

const CONFIG_PATH     = "config"
const ENV_PATH        = joinpath(CONFIG_PATH, "env")
const LOG_PATH        = "log"
const APP_PATH        = "app"
const RESOURCES_PATH  = joinpath(APP_PATH, "resources")
const TEST_PATH       = "test"
const DB_PATH         = "db"
const MODEL_PATH      = joinpath(DB_PATH, "models")
const DBDF_PATH       = joinpath(DB_PATH, DBDF_FOLDER_NAME)

const PORMG_DB_CONFIG_FILE_NAME   = "connection.yml"
const PORMG_COLS_FILE_NAME        = "columns.xlsx"
const PORMG_PK_FILE_NAME          = "pk.xlsx"
const PORMG_DBDF_SQUEMA           = "dbdf_schema"

const TEST_FILE_IDENTIFIER = "_test.jl"

const LAST_INSERT_ID_LABEL = "LAST_INSERT_ID"

const reserved_words = [
  "if", "else", "elseif", "while", "for", "begin", "end", "function", "return",
  "break", "continue", "global", "local", "const", "let", "do", "try", "catch",
  "finally", "struct", "mutable", "abstract", "primitive", "type", "quote",
  "macro", "module", "baremodule", "using", "import", "export", "importall",
  "where", "in", "isa", "throw", "true", "false", "nothing", "missing"
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

const CONNECTIONS::Dict{String, Union{SQLite.DB, LibPQ.Connection}} = Dict()


# I whant work with dictionary to handle pool connections


const sqlite_type_map = Dict{String, Any}(
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