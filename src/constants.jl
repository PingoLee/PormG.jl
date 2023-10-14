const DBDF_FOLDER_NAME = "migrations"

const CONFIG_PATH     = "config"
const ENV_PATH        = joinpath(CONFIG_PATH, "env")
const LOG_PATH        = "log"
const APP_PATH        = "app"
const RESOURCES_PATH  = joinpath(APP_PATH, "resources")
const TEST_PATH       = "test"
const DB_PATH         = "db"
const DBDF_PATH = joinpath(DB_PATH, DBDF_FOLDER_NAME)

const PORMG_DB_CONFIG_FILE_NAME   = "connection.yml"
const PORMG_COLS_FILE_NAME        = "columns.xlsx"
const PORMG_PK_FILE_NAME          = "pk.xlsx"
const PORMG_DBDF_SQUEMA           = "dbdf_schema"

const TEST_FILE_IDENTIFIER = "_test.jl"

const LAST_INSERT_ID_LABEL = "LAST_INSERT_ID"

const PormGsuffix = Dict{String,Union{Int64, String}}(
  "__gte" => ">=",
  "__gt" => ">",
  "__lte" => "<=",
  "__lt" => "<",
  "__contains" => "contains",
)

const PormGtrasnform = Dict{String,Union{Int64, String}}(
  "__date" => "_date",
  "__month" => "_month",
  "__year" => "_year",
  "__day" => "_day",  
  "__y_month" => "_y_month",
)
