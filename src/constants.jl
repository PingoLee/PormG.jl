const DBDF_FOLDER_NAME = "migrations"

const CONFIG_PATH     = "config"
const ENV_PATH        = joinpath(CONFIG_PATH, "env")
const LOG_PATH        = "log"
const APP_PATH        = "app"
const RESOURCES_PATH  = joinpath(APP_PATH, "resources")
const TEST_PATH       = "test"
const DB_PATH         = "db"
const MODEL_PATH      = joinpath(APP_PATH, "models")
const DBDF_PATH       = joinpath(DB_PATH, DBDF_FOLDER_NAME)

const PORMG_DB_CONFIG_FILE_NAME   = "connection.yml"
const PORMG_COLS_FILE_NAME        = "columns.xlsx"
const PORMG_PK_FILE_NAME          = "pk.xlsx"
const PORMG_DBDF_SQUEMA           = "dbdf_schema"

const TEST_FILE_IDENTIFIER = "_test.jl"

const LAST_INSERT_ID_LABEL = "LAST_INSERT_ID"

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
  "y_month" => "Y_M",
)

CONNECTIONS::Union{Vector{SQLite.DB},Nothing} = nothing


const sqlite_type_map = Dict{String, Any}(
  "INTEGER" => :IntegerField, 
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


const sqlite_ignore_schema::Vector{String} = ["sqlite_sequence", "sqlite_autoindex"]