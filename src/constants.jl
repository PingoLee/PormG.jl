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
# peel then read as the option and rejected on reload. `managed` joined with #741, the same narrow
# break `indexes` caused with #347.
const MODEL_OPTION_KWARGS = ["constraints", "db_table", "indexes", "managed"]

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
  # #634: case-insensitive equality, the last gap in the `i*` family. Verbatim — it compares with `=`,
  # so it sits in VERBATIM_PATTERN_OPERATORS below and a literal `%` in the value stays literal.
  "iexact" => "iexact",
  "iunaccent_contains" => "iunaccent_contains",
  "iunaccent_exact" => "iunaccent_exact",
  "startswith" => "startswith",
  # #604: the case-insensitive prefix/suffix twins. Their `Dialect` renderers shipped complete with
  # #78 (PG `ILIKE`, SQLite `pormg_lower(col) LIKE pormg_lower(val)`) and were unreachable for want
  # of this key alone — `filter("surname__@istartswith" => "ham")` raised FilterError.
  "istartswith" => "istartswith",
  "endswith" => "endswith",
  "iendswith" => "iendswith",
  # #635: POSIX regular expressions — PostgreSQL only (`~` / `~*`). SQLite raises
  # BackendCapabilityError instead of registering a PCRE UDF, because the two engines would then
  # read the same pattern in two different regex dialects and return different rows silently.
  "regex" => "regex",
  "iregex" => "iregex",
  "range" => "BETWEEN",
  # #207: negated twins of the pattern/range lookups above. Each LIKE-family value is the operator
  # name itself — it doubles as the `Dialect.<name>` dispatch symbol in _get_filter_query(::SQLTypeOper)
  # (rendered as NOT LIKE / NOT ILIKE / <>). `nrange` renders NOT BETWEEN via the BETWEEN branch.
  # These negate a match rather than compose a NOT-group (PormG has no .exclude()/~Q by design).
  "ncontains" => "ncontains",
  "nicontains" => "nicontains",
  "niexact" => "niexact",             # #634 (`<>`)
  "niunaccent_contains" => "niunaccent_contains",
  "niunaccent_exact" => "niunaccent_exact",
  "nstartswith" => "nstartswith",
  "nistartswith" => "nistartswith",   # #604
  "nendswith" => "nendswith",
  "niendswith" => "niendswith",       # #604
  "nregex" => "nregex",               # #635 (`!~`)
  "niregex" => "niregex",             # #635 (`!~*`)
  "nrange" => "NOT BETWEEN",
  # #27: PostgreSQL JSONB containment/overlap operators. Each maps to a Dialect renderer of the
  # same name (PG emits the operator; SQLite/abstract throw a friendly PG-only error). Distinct
  # from the LIKE `contains` above — a JSON `@>` and a string LIKE are different operations.
  "jcontains" => "jcontains",         # @>  (jsonb contains the given document)
  "has_key" => "has_key",             # ?   (top-level key exists)
  "has_any_keys" => "has_any_keys",   # ?|  (any of the given keys exists)
  "has_keys" => "has_keys",           # ?&  (all of the given keys exist)
  # #28: PostgreSQL array containment/overlap, Django's `ArrayField` lookups. `acontains` rather than
  # `contains` because `@contains` is a LIKE on every other column — the `@jcontains` precedent. Each
  # maps to a Dialect renderer of the same name (PG emits the operator; SQLite/abstract refuse).
  "acontains" => "acontains",         # @>  (the array holds every given element)
  "contained_by" => "contained_by",   # <@  (every element of the array is among the given ones)
  "overlap" => "overlap",             # &&  (the array shares at least one element with the given)
  # #904: PostgreSQL network operators on an `inet`/`cidr` column — django-netfields' lookups. Each
  # maps to a Dialect renderer of the same name, as the JSON four do. `net_` keeps them apart from the
  # LIKE `contains` above, the `jcontains` precedent.
  "net_contained" => "net_contained",                     # <<   (strictly inside the given network)
  "net_contained_or_equal" => "net_contained_or_equal",   # <<=  (inside or equal)
  "net_contains" => "net_contains",                       # >>   (strictly contains the given value)
  "net_contains_or_equals" => "net_contains_or_equals",   # >>=  (contains or equal)
  "net_overlaps" => "net_overlaps",                       # &&   (either contains the other)
  "family" => "family",                                   # family(col) = 4 | 6
  "prefixlen" => "prefixlen",                             # masklen(col) = n
)

# #27: the JSON containment/overlap operators, routed to a dedicated render branch in
# _get_filter_query(::SQLTypeOper) and gated PostgreSQL-only.
const JSON_CONTAINMENT_OPERATORS = ("jcontains", "has_key", "has_any_keys", "has_keys")

# #28: the array containment/overlap operators — the same arrangement as the JSON four: a dedicated
# render branch (`_render_array_operator`), a vector right-hand side bound as ONE array literal, and
# PostgreSQL only (SQLite has no array type, and PormG does not emulate one).
const ARRAY_CONTAINMENT_OPERATORS = ("acontains", "contained_by", "overlap")

# #904: the network operators, routed to `_render_network_operator` in
# _get_filter_query(::SQLTypeOper) and gated PostgreSQL-only. The first five compare against a
# network (`NETWORK_CONTAINMENT_OPERATORS`); `family` and `prefixlen` compare a number the column
# yields.
const NETWORK_CONTAINMENT_OPERATORS = ("net_contained", "net_contained_or_equal", "net_contains",
                                       "net_contains_or_equals", "net_overlaps")
const NETWORK_LOOKUP_OPERATORS = (NETWORK_CONTAINMENT_OPERATORS..., "family", "prefixlen")

# ──────────────────────────────────────────────────────────────────────────────
# The LIKE-family pattern lookups (#604)
#
# Grouped by the wildcard shape `_apply_like_wildcards` (`querybuilder/parameters.jl`) gives the
# bound value, because that shape IS the distinction between them. One list in total, because this
# family used to be restated as a literal at six consumption sites and `istartswith`/`iendswith`
# reached none of them: they had complete Dialect renderers and were unreachable. Every name here
# is also a `PormGsuffix` key whose value is the name itself, which doubles as the
# `Dialect.<name>` dispatch symbol.
#
# `test/unit/test_operators.jl` holds that correspondence to three sources, not two: these tuples,
# `PormGsuffix`, and `Dialect` itself read back by reflection. The third is the one that matters —
# a comparison between this file and `PormGsuffix` is two halves of the same declaration and cannot
# see a renderer that only `Dialect` knows about, which is exactly what `istartswith` was.
# ──────────────────────────────────────────────────────────────────────────────
const LIKE_CONTAINS_OPERATORS = ("contains", "icontains", "iunaccent_contains",
                                 "ncontains", "nicontains", "niunaccent_contains")
const LIKE_PREFIX_OPERATORS   = ("startswith", "istartswith", "nstartswith", "nistartswith")
const LIKE_SUFFIX_OPERATORS   = ("endswith", "iendswith", "nendswith", "niendswith")

# Everything that takes `%` decoration (and, with it, `escape_like_pattern`). Deliberately NOT the
# same set as PATTERN_LOOKUP_OPERATORS below: `iexact` / `niexact` and `iunaccent_exact` /
# `niunaccent_exact` render through Dialect but compare with `=` / `<>`, and the regex four (#635)
# hand the value to `~` as a pattern, so a wildcard — or LIKE escaping — on their value would change
# what they match.
#
# Defined as the union rather than spelled out, so the gate and the shapes cannot drift apart: the
# builder gates the wildcard call on membership HERE, `_apply_like_wildcards` picks the shape from
# the three sets above, and the only way to add a wildcard operator is to put it in one of them.
# `test/unit/test_operators.jl` pins the rest: the difference between this tuple and
# PATTERN_LOOKUP_OPERATORS is exactly VERBATIM_PATTERN_OPERATORS.
const LIKE_WILDCARD_OPERATORS = (LIKE_CONTAINS_OPERATORS..., LIKE_PREFIX_OPERATORS...,
                                 LIKE_SUFFIX_OPERATORS...)

# The pattern lookups whose value binds verbatim — no `%`, no `escape_like_pattern`, no `ESCAPE`.
# `iexact` / `niexact` (#634) belong here for `iunaccent_exact`'s reason: they compare with `=` /
# `<>`, so a wildcard set would silently turn a user's literal `%` into a wildcard.
const VERBATIM_PATTERN_OPERATORS = ("iexact", "niexact", "iunaccent_exact", "niunaccent_exact",
                                    "regex", "iregex", "nregex", "niregex")

# Every operator whose SQL comes from `getfield(Dialect, Symbol(op))` in the pattern branch of
# `_get_filter_query(::SQLTypeOper, …)`.
const PATTERN_LOOKUP_OPERATORS = (LIKE_WILDCARD_OPERATORS..., VERBATIM_PATTERN_OPERATORS...)

const PormGtransform = Dict{String,Union{Int64, String}}(
  "date" => "DATE",
  "month" => "MONTH",
  "year" => "YEAR",
  "day" => "DAY",  
  "yyyy_mm" => "Y_M",
  "quarter" => "QUARTER",
  "quadrimester" => "QUADRIMESTER",
  # #579: the year-qualified LABEL forms. `@quarter` used to render `CONCAT(year, '-Q', CASE …)`,
  # so it denoted the string `'1985-Q1'` rather than the number every doc table promised — which is
  # why `filter("date__@quarter" => 1)` could never match. `@quarter` / `@quadrimester` now extract
  # the period number, as Django's `ExtractQuarter` lookup does, and the label moves here under
  # names shaped like the `@yyyy_mm` bucket it belongs beside.
  "yyyy_q" => "Y_Q",
  "yyyy_quad" => "Y_QUAD",
  # #636: the time parts of a `DateTimeField` / `TimeField`. The week parts (`week`, `week_day`,
  # `iso_week_day`, `iso_year`) are deliberately absent — the two engines number weeks differently,
  # and which numbering each name promises is still an open decision on #636.
  "hour" => "HOUR",
  "minute" => "MINUTE",
  "second" => "SECOND",
  # #28: an `ArrayField`'s element count, Django's `len`. A transform rather than an operator, so it
  # chains like the date parts do: `"pit_laps__@len__@gte" => 2`. PostgreSQL only.
  "len" => "ARRAY_LEN",
)

# dictionary from function to type of the field
#
# Keyed by the node's `function_name`, which is the Dialect dispatch name — not the SQL keyword. So
# `ToChar` is `EXTRACT_DATE`: it renders `to_char`/`strftime`, and the key here was `TO_CHAR` until
# #862, a name no node carries, so no reader of this table ever typed a `ToChar` expression.
const PormGTypeField = Dict{String,Symbol}(
  "COUNT" => :format_number_sql,
  "EXTRACT" => :format_number_sql,
  "EXTRACT_DATE" => :format_text_sql,
)

# I whant work with dictionary to handle pool connections

# `sqlite_type_map` and `postgres_type_map` — the two FORWARD maps from a catalog type to a field
# struct — lived here until #522. The introspection readers compile a catalog type straight to a
# `CanonicalType` through `Migrations.parse_canonical_type`, and `inspectdb` picks its struct from
# the compiled `ColumnSpec` (`Migrations.field_from_spec`), so nothing maps a rendered type back to
# a field struct any more. The two REVERSE maps below are the renderer's and stay.

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
  "JSON" => "TEXT",
  # #28. For the migration compiler only: SQLite has no `inet`/`cidr`, and `Dialect.field_to_column`
  # refuses both fields there, so no DDL carries this. It keeps the compiled spec a `CText` rather
  # than an `INET` that SQLite's affinity rule would read as INTEGER.
  "INET" => "TEXT",
  "CIDR" => "TEXT",
  # #28, the same arrangement for `ArrayField`: SQLite has no array type and `field_to_column`
  # refuses it there, so this only keeps the compiled spec a `CText`.
  "ARRAY" => "TEXT"
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

# The portable `ToChar` formats (#569). Each key is the user-facing token; each value carries the
# spelling the ENGINE parses — PostgreSQL `to_char` on the left, SQLite `strftime` on the right.
#
# Two spellings per row because the keys are not valid `to_char` templates, however much they look
# like them: `HH` is the 12-hour clock in `to_char` (`HH24` is 24-hour), a `T` before `H` parses as
# the ordinal-suffix pattern `TH` (the hour vanishes and a literal `HH` appears), and `SSS` is `SS`
# plus a literal `S` (`MS` is milliseconds). On SQLite `%f` already spells `SS.SSS`, so a mask must
# never write `%S.%f` — that renders the seconds twice. Until #569 this map held one string per row,
# used it as the SQLite mask AND passed the key through to `to_char` verbatim, and neither half had
# been evaluated on its engine.
#
# The contract: for a fixed instant, every key renders the SAME text on both engines, and that
# text is what `Dates.format` produces for the matching Julia mask — `HH` is 24-hour on both. The
# in-engine measurement is `vr_run_tochar_formats` (`test/unit/helper_value_repr_cases.jl`), whose
# oracle table must name every key here; an entry with an unverified half cannot be added.
#
# `Dialect.SQLITE_CANONICAL_DATETIME_MASK` is the `YYYY-MM-DDTHH:MI:SS.SSS` row's SQLite mask plus
# the `+00:00` UTC suffix — one canonical spelling, derived rather than restated.
const date_format_map = Dict{String, NamedTuple{(:postgres, :sqlite), Tuple{String, String}}}(
  "YYYY" => (postgres = "YYYY", sqlite = "%Y"),
  "MM"   => (postgres = "MM",   sqlite = "%m"),
  "DD"   => (postgres = "DD",   sqlite = "%d"),
  "HH"   => (postgres = "HH24", sqlite = "%H"),
  "MI"   => (postgres = "MI",   sqlite = "%M"),
  "SS"   => (postgres = "SS",   sqlite = "%S"),
  "YYYY-MM-DD" => (postgres = "YYYY-MM-DD", sqlite = "%Y-%m-%d"),
  "YYYY-MM"    => (postgres = "YYYY-MM",    sqlite = "%Y-%m"),
  "YYYY-MM-DD HH:MI:SS"     => (postgres = "YYYY-MM-DD HH24:MI:SS",    sqlite = "%Y-%m-%d %H:%M:%S"),
  "YYYY-MM-DD HH:MI:SS.SSS" => (postgres = "YYYY-MM-DD HH24:MI:SS.MS", sqlite = "%Y-%m-%d %H:%M:%f"),
  "YYYY-MM-DDTHH:MI:SS"     => (postgres = "YYYY-MM-DD\"T\"HH24:MI:SS",    sqlite = "%Y-%m-%dT%H:%M:%S"),
  "YYYY-MM-DDTHH:MI:SS.SSS" => (postgres = "YYYY-MM-DD\"T\"HH24:MI:SS.MS", sqlite = "%Y-%m-%dT%H:%M:%f"),
  "HH:MI:SS"     => (postgres = "HH24:MI:SS",    sqlite = "%H:%M:%S"),
  "HH:MI:SS.SSS" => (postgres = "HH24:MI:SS.MS", sqlite = "%H:%M:%f"),
  "HH:MI"        => (postgres = "HH24:MI",       sqlite = "%H:%M"),
  "DD/MM/YYYY" => (postgres = "DD/MM/YYYY", sqlite = "%d/%m/%Y"),
  "DD-MM-YYYY" => (postgres = "DD-MM-YYYY", sqlite = "%d-%m-%Y"),
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

# Names a generated models file's own boilerplate already binds (#338) — the module import plus the
# six on_delete handlers above. Single source for Generator.jl's `import PormG.Models: ...` line and
# the cross-model binding-collision dedup seed in Models.jl/importers.jl, so the two cannot drift.
const GENERATED_MODULE_RESERVED_BINDINGS = ["Models", "RESTRICT", "CASCADE", "SET_NULL", "SET_DEFAULT", "DO_NOTHING", "PROTECT"]
