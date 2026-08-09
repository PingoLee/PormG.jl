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

# Default acquire-connection timeout (seconds) when neither connection.yml nor register_connection
# specify `pool_timeout` (#126). Single source of truth shared by Configuration, ConnectionPool, and
# precompile.jl (#179) — matches the cross-framework norm (HikariCP `CONNECTION_TIMEOUT`, SQLAlchemy
# `pool_timeout`, both 30s).
const DEFAULT_POOL_TIMEOUT = 30.0

const TEST_FILE_IDENTIFIER = "_test.jl"

const LAST_INSERT_ID_LABEL = "LAST_INSERT_ID"

# Constants for dealing with datetime in UTC
const DATETIME_FORMAT = "yyyy-mm-ddTHH:MM:SS.ssszzzz"
const UTC_TIMEZONE = "UTC"

# Words that CANNOT be a Julia keyword-argument name — i.e. `Model("t", <word> = CharField())` is a
# syntax/lowering error, so a column with one of these names cannot be declared as a plain kwarg.
# `Model_to_str` consults this list to pick a legal identifier for a generated field and pins the real
# column with `db_column` (#317). It is NOT a list of SQL reserved words, and NOT "words Julia treats
# specially" — `type`, `where`, `in`, `isa`, `mutable`, `abstract`, `primitive`, `outer` and `var` all
# parse fine as kwarg names and are deliberately absent.
#
# Re-derive it with EVAL, not `Meta.parse`: `true`/`false` parse and then fail at lowering, and
# `Base.isidentifier("end")` is `true`, so neither is a usable predicate on its own.
#
#   f(; kw...) = keys(kw)
#   filter(w -> (try eval(Meta.parse("f($w = 1)")); false catch; true end), candidates)
#
# The list previously carried twelve legal words plus `id` — which is why every doc example and every
# generated model file said `_id = IDField()`. `id` is an ordinary Julia identifier (#317).
const reserved_words = [
  "baremodule", "begin", "break", "catch", "const", "continue", "do", "else", "elseif", "end",
  "export", "false", "finally", "for", "function", "global", "if", "import", "let", "local",
  "macro", "module", "quote", "return", "struct", "true", "try", "using", "while"
]

# Keyword arguments `Model(...)` peels off BEFORE the `fields...` slurp (`src/Models.jl`). A column
# with one of these names cannot be declared as a kwarg at all — not even as `var"db_table"`, since
# the peel keys on the kwarg NAME however it was spelled — so it needs `db_column` (#317).
# `Model_to_str` treats them exactly like `reserved_words` when picking a generated identifier;
# without that, an introspected `db_table` column emitted `db_table = Models.CharField()`, which the
# peel then read as the option and rejected on reload.
const MODEL_OPTION_KWARGS = ["constraints", "db_table"]

const PormGsuffix = Dict{String,Union{Int64, String}}(
  "gte" => ">=",
  "gt" => ">",
  "lte" => "<=",
  "lt" => "<",
  "ne" => "!=",
  "isnull" => "ISNULL",
  "in" => "IN",
  "nin" => "NOT IN",
  "contains" => "contains",
  "icontains" => "icontains",
  "iunaccent_contains" => "iunaccent_contains",
  "iunaccent_exact" => "iunaccent_exact",
  "startswith" => "startswith",
  "endswith" => "endswith",
  "range" => "BETWEEN",
  # #207: negated twins of the pattern/range lookups above. Each LIKE-family value is the operator
  # name itself — it doubles as the `Dialect.<name>` dispatch symbol in _get_filter_query(::SQLTypeOper)
  # (rendered as NOT LIKE / NOT ILIKE / <>). `nrange` renders NOT BETWEEN via the BETWEEN branch.
  # These negate a match rather than compose a NOT-group (PormG has no .exclude()/~Q by design).
  "ncontains" => "ncontains",
  "nicontains" => "nicontains",
  "niunaccent_contains" => "niunaccent_contains",
  "niunaccent_exact" => "niunaccent_exact",
  "nstartswith" => "nstartswith",
  "nendswith" => "nendswith",
  "nrange" => "NOT BETWEEN",
  # #27: PostgreSQL JSONB containment/overlap operators. Each maps to a Dialect renderer of the
  # same name (PG emits the operator; SQLite/abstract throw a friendly PG-only error). Distinct
  # from the LIKE `contains` above — a JSON `@>` and a string LIKE are different operations.
  "jcontains" => "jcontains",         # @>  (jsonb contains the given document)
  "has_key" => "has_key",             # ?   (top-level key exists)
  "has_any_keys" => "has_any_keys",   # ?|  (any of the given keys exists)
  "has_keys" => "has_keys",           # ?&  (all of the given keys exist)
)

# #27: the JSON containment/overlap operators, routed to a dedicated render branch in
# _get_filter_query(::SQLTypeOper) and gated PostgreSQL-only.
const JSON_CONTAINMENT_OPERATORS = ("jcontains", "has_key", "has_any_keys", "has_keys")

const PormGtransform = Dict{String,Union{Int64, String}}(
  "date" => "DATE",
  "month" => "MONTH",
  "year" => "YEAR",
  "day" => "DAY",  
  "yyyy_mm" => "Y_M",
  "quarter" => "QUARTER",
  "quadrimester" => "QUADRIMESTER",
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
  # Django-style declared type for PositiveIntegerField (INTEGER affinity); the
  # distinct spelling is what lets SQLite introspection round-trip the field.
  "INTEGER UNSIGNED" => :PositiveIntegerField,
  "SMALLINT" => :PositiveSmallIntegerField,
  "INT" => :BigIntegerField,
  # PormG renders every VARCHAR-family field as `TEXT(n)` on SQLite (see `sqlite_type_map_reverse`),
  # so a length suffix is what distinguishes a CharField from a TextField here — a BARE `TEXT` is
  # resolved to `:TextField` in `convertSQLToModel(::PormGSQLite)` rather than to a CharField whose
  # constructor would invent `max_length = 250` (#325). VARCHAR/CHAR are accepted for schemas PormG
  # did not create, so a hand-written `VARCHAR(50)` keeps its length.
  "TEXT" => :CharField,
  "VARCHAR" => :CharField,
  "CHAR" => :CharField,
  "NUMERIC" => :FloatField,
  "REAL" => :FloatField,
  "DECIMAL" => :DecimalField,
  "DATETIME" => :DateTimeField,
  "TIME" => :TimeField,
  "INTERVAL" => :DurationField,
  "DATE" => :DateField,
  "BLOB" => :BinaryField,
  "BOOLEAN" => :BooleanField,
  "UUID" => :UUIDField,
  "JSON" => :JSONField,
  "JSONB" => :JSONField
)

const postgres_type_map = Dict{String, Symbol}(
  "integer" => :IntegerField,
  "smallint" => :PositiveSmallIntegerField,
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
  "interval" => :DurationField,
  # PostgreSQL's format_type() reports `bytea`; it never reports "blob". The "blob" key below is
  # unreachable in practice and kept only so a hand-written mapping does not regress (#296).
  "bytea" => :BinaryField,
  "blob" => :BinaryField,
  "double_precision" => :FloatField,
  "uuid" => :UUIDField,
  "json" => :JSONField,
  "jsonb" => :JSONField,
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
  "TEXT" => "TEXT",
  "INTEGER" => "INTEGER",
  "INTEGER UNSIGNED" => "INTEGER UNSIGNED",
  "SMALLINT" => "SMALLINT",
  "BIGINT" => "INTEGER",
  "FLOAT" => "REAL",
  "DECIMAL" => "DECIMAL",
  "DATETIME" => "DATETIME",
  "TIMESTAMPTZ" => "DATETIME",
  "TIME" => "TIME",
  "INTERVAL" => "INTERVAL",
  "DATE" => "DATE",
  "BLOB" => "BLOB",
  "BOOLEAN" => "BOOLEAN",
  "UUID" => "TEXT",
  "JSONB" => "TEXT",
  "JSON" => "TEXT"
)

const postgres_type_map_reverse = Dict{String, String}(
  "BIGSERIAL" => "bigserial",
  "SERIAL" => "serial",
  "BIGINT" => "bigint",
  "INTEGER" => "integer",
  # PostgreSQL has no unsigned type: PositiveIntegerField renders as plain integer
  # and is distinguished on introspection by its non-negative CHECK constraint.
  "INTEGER UNSIGNED" => "integer",
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
  # BinaryField's canonical `field.type` is the SQLite spelling "BLOB"; PostgreSQL renders it as
  # `bytea` (#296). "BYTEA" is kept as an alias so an explicitly-BYTEA-typed field still maps.
  "BLOB" => "bytea",
  "BYTEA" => "bytea",
  "TIMESTAMPTZ" => "timestamptz",
  "TIMESTAMP" => "timestamp",
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
  "HH:MI" => "%H:%M",
  "DD/MM/YYYY" => "%d/%m/%Y",
  "DD-MM-YYYY" => "%d-%m-%Y"
)



const sqlite_ignore_schema::Vector{String} = ["sqlite_sequence", "sqlite_autoindex", "pormg_migrations"]

const postgres_ignore_table::Vector{String} = ["auth_", "django_", "social_", "account_", "allauth_", "admin_", "celery_", "django_celery_", "djcelery_", "kombu_", "pormg_migrations"]

# Consumer-extensible ignore list. Downstream packages (e.g. Nitro) register their OWN
# framework/infrastructure tables here — typically from a package extension's `__init__` —
# so introspection / makemigrations skips them without those app-specific table names being
# hardcoded into this general-purpose ORM. Merged into the per-call `ignore_table` inside
# `convert_schema_to_models`, so it applies to every introspection path.
const _EXTRA_IGNORE_TABLES = Ref{Vector{String}}(String[])

"""
    register_ignore_tables!(tables) -> Vector{String}

Register table-name patterns that schema introspection (`convert_schema_to_models`,
`import_models_from_*`, `makemigrations`) should always skip — e.g. a consumer framework's
own infrastructure tables. Additive and idempotent (deduplicated); returns the full list.

Intended to be called once at load time, typically from a package extension's `__init__`:

```julia
# in YourPkgPormGExt.__init__
isdefined(PormG, :register_ignore_tables!) && PormG.register_ignore_tables!(["yourpkg_jobs"])
```
"""
function register_ignore_tables!(tables::AbstractVector{<:AbstractString})
  _EXTRA_IGNORE_TABLES[] = unique(vcat(_EXTRA_IGNORE_TABLES[], String.(tables)))
  return _EXTRA_IGNORE_TABLES[]
end

export register_ignore_tables!

# deletion functions handlers
function CASCADE end
function RESTRICT end
function PROTECT end
function SET_NULL end
function SET_DEFAULT end
function DO_NOTHING end
