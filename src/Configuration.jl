module Configuration

import YAML, Logging
import PormG: PormGSettings, PormGBackend, PormGPostgres, PormGPostgresParam, PormGSQLite, config, PormGModel
import PormG: ConfigurationError, InvalidConfigurationError  # semantic error taxonomy (#239); defined in Kernel
import PormG: TransactionError  # cross-connection transaction misuse (#268); the config is valid, the call pattern is not
import PormG: PORMG_DB_CONFIG_FILE_NAME, DB_PATH, MODEL_FILE, DATETIME_FORMAT, UTC_TIMEZONE, DEFAULT_POOL_TIMEOUT
import PormG: Generator
import PormG: @pormg_debug
# Backend generics — driver bodies live in the weakdep extensions (no direct LibPQ/SQLite here).
import PormG: backend_num_rows, backend_is_alive

using Base.ScopedValues: ScopedValue, with

export env, Settings, connection, close_pool!, get_settings
export with_tx_context, in_transaction_context, current_transaction_depth, register_connection, unregister_connection, set_connection_resolver
export set_before_connect_hook, ensure_before_connect!

const _REDACT_CONNECTION_STRING_RE = Regex("(?i)(password|user)=[^\\s]+")

# Dynamic connection resolver hook
const _CONNECTION_RESOLVER = Ref{Union{Nothing, Function}}(nothing)

# Optional hook invoked before opening a physical connection (e.g. VPN, SSH tunnel).
const _BEFORE_CONNECT_HOOK = Ref{Union{Nothing, Function}}(nothing)

"""
    set_before_connect_hook(f::Function)

Register a callback invoked before PormG opens a physical database connection.
The callback receives `(key::String, settings::Settings)` and must return `true`
to proceed or `false` to abort the connection attempt.

It runs only when a new connection must be opened (not on connection reuse) and
is invoked outside the pool lock. Decide inside the callback which connections
need setup, e.g. `basename(settings.db_def_folder) == "db_esus"`.

Typical uses include VPN setup, credential refresh, or SSH tunnel activation.
When no hook is registered, connections proceed normally.
"""
function set_before_connect_hook(f::Function)
  _BEFORE_CONNECT_HOOK[] = f
  return f
end

"""
    set_connection_resolver(f::Function)

Register a callback function to lazily resolve unknown connection keys.
The function `f` should accept a `key::String` and return:
- `nothing` if the key cannot be resolved.
- A `Tuple` of `(url, adapter, pool_size)` or a `Dict` with those keys.
"""
function set_connection_resolver(f::Function)
  _CONNECTION_RESOLVER[] = f
end

"""
    redact_secret(conn_str::String)

Replace sensitive connection string fields such as `password` or `user` with masked values before logging.
"""
function redact_secret(conn_str::String)::String
  return replace(conn_str, _REDACT_CONNECTION_STRING_RE => s"\1=****")
end

# app environments
const DEV   = "dev"
const PROD  = "prod"
const TEST  = "test"

# Raised when configuration cannot be loaded: a missing folder/yml (`load` no longer silently
# scaffolds + returns `nothing` — #205) or a selected environment with no matching block in the
# yaml. Typed so callers can `catch e; e isa MissingConfigurationError`. Renamed from
# `MissingDatabaseConfigurationException` in the pre-publish naming pass — the sole `*Exception`
# that survived the #231 clean break in an otherwise uniform `*Error` taxonomy. Previously the
# "no matching block" path referenced this name without defining it, so it threw an `UndefVarError`
# instead of the intended message.
#
# Reparented from `Exception` to `ConfigurationError <: PormGError` (#239): catching the specific
# type still works, it is merely ALSO catchable as `ConfigurationError` / `PormGError`. It keeps
# its own `showerror` below (a more specific method wins over the taxonomy's shared one).
struct MissingConfigurationError <: ConfigurationError
  msg::String
end
Base.showerror(io::IO, e::MissingConfigurationError) =
  print(io, "MissingConfigurationError: ", e.msg)

#
# Thread-Local Transaction Context
# This ensures that fetch() calls within a transaction use the same connection
#

"""
    TransactionContext

Holds the current transaction connection for a task/thread.
Used to ensure that nested fetch() calls within a transaction
use the same database connection.
"""
mutable struct TransactionContext
  conn::Any  # driver connection handle (untyped: core never names LibPQ.Connection / SQLite.DB)
  pool::Union{Nothing, PormGPostgres, PormGSQLite}
  depth::Int  # Track nested transaction contexts
  sqlite_reserved_primary_keys::Dict{Tuple{String, String}, Int64}
  
  TransactionContext() = new(nothing, nothing, 0, Dict{Tuple{String, String}, Int64}())
end

# Task-local storage for transaction context; TODO i need study this more
const _tx_context = ScopedValue(TransactionContext())

"""
    get_tx_connection() -> Union{Nothing, <driver connection>}

Get the current transaction connection if we're inside a transaction context.
Returns `nothing` if not in a transaction.
"""
function get_tx_connection()
  ctx = _tx_context[]
  return ctx.depth > 0 ? ctx.conn : nothing
end

"""
    get_tx_pool() -> Union{Nothing, PormGPostgres}

Get the connection pool associated with the current transaction context.
"""
function get_tx_pool()
  ctx = _tx_context[]
  return ctx.depth > 0 ? ctx.pool : nothing
end

"""
    in_transaction_context() -> Bool

Check if we're currently inside a transaction context.
"""
function in_transaction_context()
  return _tx_context[].depth > 0
end

"""
    current_transaction_depth() -> Int

Return the current transaction nesting depth (`0` when not inside any transaction).
The outermost `run_in_transaction`/`atomic` block is depth `1`; each nested savepoint
block increments it. Used to derive deterministic, per-level savepoint names (#26).
"""
function current_transaction_depth()::Int
  return _tx_context[].depth
end

function with_tx_context(f::Function, pool::Union{PormGPostgres, PormGSQLite}, conn)
  old_ctx = _tx_context[]
  new_ctx = TransactionContext()
  new_ctx.conn = conn
  new_ctx.pool = pool
  new_ctx.depth = old_ctx.depth + 1
  new_ctx.sqlite_reserved_primary_keys = old_ctx.depth > 0 ?
    old_ctx.sqlite_reserved_primary_keys :
    Dict{Tuple{String, String}, Int64}()
  
  return with(_tx_context => new_ctx) do
    f()
  end
end

function connection_key_for_pool(pool::Union{PormGPostgres, PormGSQLite})::Union{String, Nothing}
  for (key, settings) in config
    if settings.connections === pool
      return key
    end
  end
  return nothing
end

function ensure_model_transaction_scope(model::PormGModel)
  tx_pool = get_tx_pool()
  tx_pool === nothing && return
  model.connect_key === nothing && throw(InvalidConfigurationError("Model $(model.name) is not bound to a database connection key"))
  settings = get_settings(model.connect_key)
  if tx_pool === settings.connections
    return
  end
  active_key = connection_key_for_pool(tx_pool)
  active_desc = active_key === nothing ? "unknown transaction" : active_key
  # TransactionError, not InvalidConfigurationError (#268): the configuration is fine — both
  # connections are correctly declared — and the caller's *call pattern* is what cannot work. Its
  # sibling check, `ConnectionPool.atomic(durable=true)`, reported the same class as
  # QueryBuildError until #268 gave both one honest home.
  throw(TransactionError("Active transaction on connection $(active_desc) cannot include model $(model.name) bound to $(model.connect_key). Run run_in_transaction(\"$(model.connect_key)\") or move this operation outside the current transaction."))
end

function transaction_connection_for(settings::PormGSettings)
  tx_pool = get_tx_pool()
  tx_conn = get_tx_connection()
  return tx_conn !== nothing && tx_pool === settings.connections ? tx_conn : nothing
end

function get_sqlite_reserved_primary_key_max(model::PormGModel, pk_field::String)
  ctx = _tx_context[]
  ctx.depth > 0 || return nothing
  return get(ctx.sqlite_reserved_primary_keys, (string(model.name |> lowercase), pk_field), nothing)
end

function register_sqlite_reserved_primary_key_max!(model::PormGModel, pk_field::String, max_id::Integer)
  ctx = _tx_context[]
  ctx.depth > 0 || return Int64(max_id)

  key = (string(model.name |> lowercase), pk_field)
  current_max = get(ctx.sqlite_reserved_primary_keys, key, typemin(Int64))
  new_max = max(current_max, Int64(max_id))
  ctx.sqlite_reserved_primary_keys[key] = new_max
  return new_max
end

"""
    env() :: String

Returns the current environment.

# Examples
```julia
julia> Configuration.env()
"dev"
```
"""
function env(;path::String=DB_PATH)::String 
  return get_settings(path).app_env
end
env(x::String) = env(path=x)

# Resolve the active environment (#205). Precedence, first wins:
#   1. explicit `env=` kwarg to `load(...)`
#   2. `ENV["PORMG_ENV"]` (set by the user or a host framework)
#   3. the yaml's top-level `default_env:` (a per-file default)
#   4. `"dev"`
function _effective_env(env::Union{Nothing, String}, file_default::Union{Nothing, String} = nothing)::String
  env !== nothing && return env
  haskey(ENV, "PORMG_ENV") && return ENV["PORMG_ENV"]
  file_default !== nothing && return file_default
  return DEV
end

# Read only the top-level `default_env:` from a connection.yml, for env precedence (#205).
# Returns it as a String, or `nothing` when the key is absent/blank. Parsed independently of
# `read_db_connection_data` (a tiny yaml — negligible) so that function keeps its signature; a parse
# error here is swallowed (returns `nothing`) and surfaces properly when `read_db_connection_data`
# re-parses.
function _peek_default_env(db_settings_file::String)::Union{Nothing, String}
  raw = try
    open(db_settings_file) do io
      YAML.load(io)
    end
  catch
    return nothing
  end
  raw isa AbstractDict || return nothing
  val = get(raw, "default_env", nothing)
  (val === nothing || (val isa AbstractString && isempty(strip(val)))) && return nothing
  return string(val)
end

function _resolve_loaded_key(path_or_key::String)::Union{Nothing, String}
  haskey(config, path_or_key) && return path_or_key

  target_path = abspath(path_or_key)
  for (key, settings) in config
    settings.db_def_folder == "dynamic_connection" && continue
    if abspath(settings.db_def_folder) == target_path
      return key
    end
  end

  return nothing
end

# Parse a seconds-valued pool setting from connection.yml. Returns `default` when the key is absent OR
# the value can't be parsed to a Float64. Pure parser — no `> 0` policy; callers pick the default and
# any enforcement. Consolidates the tryparse idiom for pool_timeout / idle_timeout / max_lifetime /
# leak_detection_threshold (#179).
function _config_secs(settings::PormGSettings, key::String, default::Float64 = 0.0)::Float64
  haskey(settings.db_config_settings, key) || return default
  v = settings.db_config_settings[key]
  return v isa Real ? Float64(v) : something(tryparse(Float64, strip(string(v))), default)
end

# Parse a boolean pool setting from connection.yml. Returns `default` when the key is absent; otherwise
# accepts a native Bool or the usual truthy/falsey strings. Consolidates the truthy idiom already used
# for `sqlite_split_read_write` so new bool keys (e.g. `fail_fast_on_connect`, #72) don't re-duplicate it.
function _config_bool(settings::PormGSettings, key::String, default::Bool)::Bool
  haskey(settings.db_config_settings, key) || return default
  v = settings.db_config_settings[key]
  v isa Bool && return v
  return lowercase(strip(string(v))) in ("1", "true", "yes", "on")
end

# Enforce the pool_timeout policy: `<= 0` ("never wait") is a cross-framework footgun, so fall back to
# DEFAULT_POOL_TIMEOUT and warn once. Shared by both entry points — `_build_connection_pool!` (YAML) and
# `register_connection` (kwarg) — so the guard and its message live in one place (#126, #179).
function _normalize_pool_timeout(v::Real)::Float64
  v > 0 && return Float64(v)
  @warn "pool_timeout must be > 0; using the default $(DEFAULT_POOL_TIMEOUT)s" got=v
  return DEFAULT_POOL_TIMEOUT
end

function _build_connection_pool!(settings::PormGSettings, path::String)
  # Extract pool size from config (defaults to 3)
  pool_size = haskey(settings.db_config_settings, "pool_size") ?
              parse(Int, string(settings.db_config_settings["pool_size"])) : 3

  # Default acquire timeout (#126), seconds; absent = DEFAULT_POOL_TIMEOUT. Values <= 0 fall back (a
  # "never wait" setting is ambiguous across frameworks and a footgun), warned once at build.
  pool_timeout = _normalize_pool_timeout(_config_secs(settings, "pool_timeout", DEFAULT_POOL_TIMEOUT))

  # Optional idle-connection reaping / max-lifetime (#125) and leak detection (#127), in seconds;
  # absent or 0 = off (gated by the `> 0` checks in the enable-wiring below).
  idle_timeout             = _config_secs(settings, "idle_timeout")
  max_lifetime             = _config_secs(settings, "max_lifetime")
  leak_detection_threshold = _config_secs(settings, "leak_detection_threshold")

  # Fast-fail permanent connect errors (bad password / unopenable path) instead of waiting the full
  # pool_timeout, then raise a truthful PoolConnectError (#72). Default on; set `false` to keep waiting.
  fail_fast_on_connect = _config_bool(settings, "fail_fast_on_connect", true)

  sqlite_split_read_write = false
  if haskey(settings.db_config_settings, "sqlite_split_read_write")
    raw_value = settings.db_config_settings["sqlite_split_read_write"]
    sqlite_split_read_write = raw_value isa Bool ? raw_value : lowercase(strip(string(raw_value))) in ("1", "true", "yes", "on")
  elseif haskey(settings.db_config_settings, "options") && isa(settings.db_config_settings["options"], Dict)
    options = settings.db_config_settings["options"]
    if haskey(options, "sqlite_split_read_write")
      raw_value = options["sqlite_split_read_write"]
      sqlite_split_read_write = raw_value isa Bool ? raw_value : lowercase(strip(string(raw_value))) in ("1", "true", "yes", "on")
    end
  end

  if settings.db_config_settings["adapter"] == "SQLite"
    dbname =  if haskey(settings.db_config_settings, "host") && settings.db_config_settings["host"] !== nothing
      settings.db_config_settings["host"]
        elseif haskey(settings.db_config_settings, "database") && settings.db_config_settings["database"] !== nothing
          settings.db_config_settings["database"]
        else
          nothing
        end

    db_path = if dbname !== nothing
      # Ensure path is absolute if it's not relative to memory
      full_path = isabspath(dbname) ? dbname : joinpath(path, dbname)
      isempty(dirname(full_path)) || mkpath(dirname(full_path))
      full_path
    else # in-memory
      ":memory:"
    end

    @pormg_debug false
    CP = getfield(parentmodule(@__MODULE__), :ConnectionPool)
    settings.connections = CP.SQLiteConnectionPool(db_path; pool_size=pool_size, split_read_write=sqlite_split_read_write, pool_timeout=pool_timeout, fail_fast_on_connect=fail_fast_on_connect)

  elseif settings.db_config_settings["adapter"] == "PostgreSQL"
    dns = String[]

    # Check for direct URL/Connection String support
    if haskey(settings.db_config_settings, "url") && settings.db_config_settings["url"] !== nothing
      dns_str = settings.db_config_settings["url"]
    else
      # Standard parameters loop
      for key in ["host", "hostaddr", "port", "password", "passfile", "connect_timeout", "client_encoding", "sslmode", "sslrootcert", "sslcert", "sslkey"]
        get!(settings.db_config_settings, key, nothing)
        settings.db_config_settings[key] !== nothing && push!(dns, string("$key=", settings.db_config_settings[key]))
      end

      get!(settings.db_config_settings, "database", nothing)
      settings.db_config_settings["database"] !== nothing && push!(dns, string("dbname=", settings.db_config_settings["database"]))

      get!(settings.db_config_settings, "username", nothing)
      settings.db_config_settings["username"] !== nothing && push!(dns, string("user=", settings.db_config_settings["username"]))

      dns_str = join(dns, " ")
    end

    # Use parent module reference to avoid circular dependency during module loading
    CP = getfield(parentmodule(@__MODULE__), :ConnectionPool)
    settings.connections = CP.PostgresConnectionPool(dns_str; pool_size=pool_size, pool_timeout=pool_timeout, fail_fast_on_connect=fail_fast_on_connect)

  else
    adapter = settings.db_config_settings["adapter"]
    throw(InvalidConfigurationError("Unsupported adapter: $(adapter)"))
  end

  # Opt the pool into idle-reaping / max-lifetime (#125) and/or leak detection (#127) if configured.
  # No-op when the respective keys are 0/absent. Both merge into one PoolMonitorState.
  reap_on = idle_timeout > 0 || max_lifetime > 0
  if reap_on || leak_detection_threshold > 0
    CP = getfield(parentmodule(@__MODULE__), :ConnectionPool)
    reap_on &&
      CP.enable_reaping!(settings.connections; idle_timeout=idle_timeout, max_lifetime=max_lifetime)
    leak_detection_threshold > 0 &&
      CP.enable_leak_detection!(settings.connections; threshold=leak_detection_threshold)
  end

  return settings
end

"""
    read_db_connection_data(db_settings_file::String) :: Dict{Any,Any}

Attempts to read the database configuration file and returns the part corresponding to the current environment as a `Dict`.
Does not check if `db_settings_file` actually exists so it can throw errors.
If the database connection information for the current environment does not exist, it returns an empty `Dict`.

# Examples
```julia
julia> Configuration.read_db_connection_data(...)
Dict{Any,Any} with 6 entries:
  "host"     => "localhost"
  "password" => "..."
  "username" => "..."
  "port"     => 5432
  "database" => "..."
  "adapter"  => "PostgreSQL"
```
"""
function _configured_extensions(settings::PormGSettings)::Vector{String}
  raw = get(settings.db_config_settings, "extensions", String[])
  (raw === nothing || raw === missing) && return String[]

  values = if raw isa AbstractString
    [raw]
  elseif raw isa AbstractVector
    raw
  else
    throw(InvalidConfigurationError("The 'extensions' setting must be a string or a list of strings"))
  end

  normalized = String[]
  for value in values
    (value === nothing || value === missing) && continue
    name = lowercase(strip(String(value)))
    isempty(name) && continue
    push!(normalized, name)
  end
  return unique(normalized)
end

# Detection-only check run at load() time. Installing extensions is DDL and is
# handled by the migration runner (gated on change_db, deliberate operator step),
# never on app boot. Here we only probe pg_extension and warn on misconfiguration
# so a missing extension is visible before the first query fails.
function _check_configured_extensions!(settings::PormGSettings)::Nothing
  extensions = _configured_extensions(settings)
  isempty(extensions) && return nothing

  adapter = get(settings.db_config_settings, "adapter", nothing)
  if adapter != "PostgreSQL"
    @warn "Database extensions are only supported for PostgreSQL; ignoring configured extensions" adapter=adapter extensions=extensions db_def_folder=settings.db_def_folder
    return nothing
  end

  CP = getfield(parentmodule(@__MODULE__), :ConnectionPool)
  for extension in extensions
    if extension == "unaccent"
      # Literal name only — never interpolate the raw YAML value into SQL.
      installed = try
        backend_num_rows(settings.connections, CP.fetch(settings, "SELECT 1 FROM pg_extension WHERE extname = 'unaccent';")) > 0
      catch e
        @warn "Could not verify PostgreSQL extension state" extension=extension db_def_folder=settings.db_def_folder exception=e
        continue
      end
      installed || @warn "Configured PostgreSQL extension is not installed; run PormG.migrate(...) to install it and the public.immutable_unaccent helper" extension=extension db_def_folder=settings.db_def_folder
    else
      @warn "Unsupported PostgreSQL extension configured; it will be ignored" extension=extension supported=["unaccent"] db_def_folder=settings.db_def_folder
    end
  end
  return nothing
end

function _install_configured_extensions!(settings::PormGSettings)::Nothing
  extensions = _configured_extensions(settings)
  isempty(extensions) && return nothing

  adapter = get(settings.db_config_settings, "adapter", nothing)
  if adapter != "PostgreSQL"
    @warn "Database extensions are only supported for PostgreSQL; ignoring configured extensions" adapter=adapter extensions=extensions db_def_folder=settings.db_def_folder
    return nothing
  end

  for extension in extensions
    if extension == "unaccent"
      _install_postgres_extension!(settings, "unaccent")
      _install_immutable_unaccent!(settings)
    else
      throw(InvalidConfigurationError("Unsupported PostgreSQL extension '$(extension)'. Supported extensions: unaccent"))
    end
  end

  return nothing
end

function _install_postgres_extension!(settings::PormGSettings, extension::String)::Nothing
  safe_extensions = Set(["unaccent"])
  extension in safe_extensions || throw(InvalidConfigurationError("Unsupported PostgreSQL extension '$(extension)'"))

  CP = getfield(parentmodule(@__MODULE__), :ConnectionPool)
  sql = "CREATE EXTENSION IF NOT EXISTS $(extension) WITH SCHEMA public;"

  try
    CP.fetch(settings, sql)
  catch e
    throw(InvalidConfigurationError(
      "Could not install PostgreSQL extension '$(extension)' for $(settings.db_def_folder). " *
      "Run this once as the database owner: $(sql) Original error: $(sprint(showerror, e))"
    ))
  end

  return nothing
end

# PostgreSQL's one-argument unaccent(text) is only STABLE (it depends on the
# default text-search config), so it cannot back a functional index. Wrap the
# two-argument form with an explicit dictionary, which is safe to mark IMMUTABLE,
# so iunaccent_contains can be backed by an expression index — e.g. a pg_trgm
# GIN index on public.immutable_unaccent(column).
function _install_immutable_unaccent!(settings::PormGSettings)::Nothing
  CP = getfield(parentmodule(@__MODULE__), :ConnectionPool)
  sql = "CREATE OR REPLACE FUNCTION public.immutable_unaccent(text) " *
        "RETURNS text LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE " *
        "AS \$\$ SELECT public.unaccent('public.unaccent', \$1) \$\$;"

  try
    CP.fetch(settings, sql)
  catch e
    throw(InvalidConfigurationError(
      "Could not create helper function public.immutable_unaccent for $(settings.db_def_folder). " *
      "Run this once as the database owner: $(sql) Original error: $(sprint(showerror, e))"
    ))
  end

  return nothing
end

function read_db_connection_data(path::String, settings::PormGSettings) :: Dict{String,Any}
  db_settings_file = joinpath(path, PORMG_DB_CONFIG_FILE_NAME) 

  endswith(db_settings_file, ".yml") || throw(InvalidConfigurationError("Unknown configuration file type at $(db_settings_file) — expecting a .yml file"))
  db_conn_data::Dict = open(db_settings_file) do io
    YAML.load(io)
  end

  # The top-level `env:` key is inert (#205): it was renamed to `default_env:`, and a bare `env:`
  # never selected anything (its reader was long dead). Warn once per file so stale configs get a
  # migration nudge — the environment comes from `load(...; env=)`, `ENV["PORMG_ENV"]`, or the
  # file's `default_env:`, never from `env:`.
  if haskey(db_conn_data, "env")
    @warn "Ignoring the legacy top-level `env:` key in $(db_settings_file) — it was renamed to `default_env:` (#205) and a bare `env:` no longer selects an environment. Rename it to `default_env:` or remove it. Active environment: $(settings.app_env)." maxlog=1 _id=Symbol(:pormg_legacy_env_key_, db_settings_file)
  end

  if  haskey(db_conn_data, settings.app_env)
      if haskey(db_conn_data[settings.app_env], "config") && isa(db_conn_data[settings.app_env]["config"], Dict)
        for (k, v) in db_conn_data[settings.app_env]["config"]
          # Safely apply settings that exist in the Settings struct
          if hasfield(Settings, Symbol(k))
            if k == "log_level"
              for dl in Dict("debug" => Logging.Debug, "error" => Logging.Error, "info" => Logging.Info, "warn" => Logging.Warn)
                occursin(dl[1], lowercase(string(v))) && setfield!(settings, Symbol(k), dl[2])
              end
            else
              setfield!(settings, Symbol(k), ((isa(v, String) && startswith(v, ":")) ? Symbol(v[2:end]) : v) )
            end
          end
        end
      end

      if ! haskey(db_conn_data[settings.app_env], "options") || ! isa(db_conn_data[settings.app_env]["options"], Dict)
        db_conn_data[settings.app_env]["options"] = Dict{String,String}()
      end
  end

  haskey(db_conn_data, settings.app_env) && return db_conn_data[settings.app_env]

  # No block for the selected env — list the available ones so the fix is obvious (#205).
  available = sort!(String[string(k) for (k, v) in db_conn_data if v isa AbstractDict])
  avail_str = isempty(available) ? "(none defined)" : join(available, ", ")
  throw(MissingConfigurationError(
    "environment \"$(settings.app_env)\" not found in $(db_settings_file); available: $(avail_str). " *
    "Select one with `load(...; env=\"…\")`, `ENV[\"PORMG_ENV\"]`, or a top-level `default_env:` in the yaml."))
end


function load(path::Union{String,Nothing} = nothing; context::Union{Module,Nothing} = nothing, env::Union{Nothing,String} = nothing, scaffold::Bool = false, config::Dict{String,PormGSettings} = config)
  # create settings if does not exists
  path === nothing && (path = DB_PATH )

  @pormg_debug false

  db_settings_file = joinpath(path, PORMG_DB_CONFIG_FILE_NAME)

  # Fail loudly on a missing folder/yml (#205). The old behavior — scaffold a skeleton, log an
  # `@error`, and `return nothing` — turned a typo'd path into a silent no-op that resurfaced far
  # away as a confusing settings-lookup error. First-run scaffolding is now explicit: pass
  # `scaffold=true`, or use `PormG.setup(path)`.
  if !isdir(path) || !isfile(db_settings_file)
    if scaffold
      Generator.create_db_folder_and_yml(path=path)
      @info "PormG wrote a new configuration skeleton at $(db_settings_file). Edit it, then call `PormG.Configuration.load(\"$(path)\")` again."
      return nothing
    end
    missing_what = !isdir(path) ? "the folder \"$(path)\" does not exist" :
                                  "no \"$(PORMG_DB_CONFIG_FILE_NAME)\" was found in \"$(path)\""
    throw(MissingConfigurationError(
      "cannot load PormG configuration: $(missing_what). Create it interactively with " *
      "`PormG.setup(\"$(path)\")`, or call `PormG.Configuration.load(\"$(path)\"; scaffold=true)` " *
      "to write a skeleton to edit."))
  end

  # Resolve the environment with the file's `default_env:` folded into the precedence (#205).
  selected_env = _effective_env(env, _peek_default_env(db_settings_file))

  if haskey(config, path) && config[path].connections !== nothing
    close_pool!(config[path].connections)
  end

  config[path] = Settings(app_env = selected_env, db_def_folder=path)
  settings::PormGSettings = config[path]

  settings.db_config_settings = read_db_connection_data(path, settings)

  _build_connection_pool!(settings, path)
  _check_configured_extensions!(settings)
  return nothing
end

"""
    load_many(paths::AbstractVector{<:AbstractString}; env::Union{Nothing,String} = nothing)

Load several static configuration folders using the same environment override.
Returns the list of connection keys that were loaded.
"""
function load_many(paths::AbstractVector{<:AbstractString}; env::Union{Nothing,String} = nothing, config::Dict{String,PormGSettings} = config)
  loaded_keys = String[]
  for path in paths
    key = String(path)
    load(key; env=env, config=config)
    push!(loaded_keys, key)
  end
  return loaded_keys
end

"""
    is_loaded(path_or_key::String) -> Bool

Return `true` when a static configuration folder or dynamic connection key has
already been registered in the in-memory configuration cache.
"""
function is_loaded(path_or_key::String)::Bool
  return _resolve_loaded_key(path_or_key) !== nothing
end

function connection(; key::String = "db") 
  settings = config[key]
  return settings.connections
end

function get_settings(key::String)
  if !haskey(config, key) && _CONNECTION_RESOLVER[] !== nothing
    # Attempt lazy resolution
    try
      res = _CONNECTION_RESOLVER[](key)
      if res !== nothing
        if res isa Tuple
          url, adapter, pool_size = res
          register_connection(key, url; adapter=adapter, pool_size=pool_size)
        elseif res isa Dict
          url = get(res, "url", nothing)
          adapter = get(res, "adapter", "PostgreSQL")
          pool_size = get(res, "pool_size", 3)
          url !== nothing && register_connection(key, url; adapter=adapter, pool_size=pool_size)
        end
      end
    catch e
      @error "Error in lazy connection resolver for key '$key'" exception=(e, catch_backtrace())
    end
  end

  haskey(config, key) || throw(InvalidConfigurationError("Settings for key '$(key)' not found. Ensure it is loaded via 'load()' or registered via 'register_connection()'."))
  return config[key]  
end

"""
    register_connection(key::String, url::String; adapter::String = "PostgreSQL", pool_size::Int = 3)

Register a new database connection pool dynamically using a connection URL.
Useful for multi-tenant applications or connecting to dynamic data sources.
"""
function register_connection(key::String, url::String; adapter::String = "PostgreSQL", pool_size::Int = 3, sqlite_split_read_write::Bool = false, idle_timeout::Real = 0, max_lifetime::Real = 0, pool_timeout::Real = DEFAULT_POOL_TIMEOUT, leak_detection_threshold::Real = 0, fail_fast_on_connect::Bool = true)
  # SAFETY: Deny using folder paths as dynamic keys to avoid hijacking static configs
  if isdir(key)
    throw(InvalidConfigurationError("Cannot register dynamic connection using key '$(key)'. Folder paths are reserved for static configurations loaded via 'load()'."))
  end

  # Default acquire timeout (#126); <= 0 falls back to DEFAULT_POOL_TIMEOUT (shared with _build_connection_pool!).
  pool_timeout = _normalize_pool_timeout(pool_timeout)

  if haskey(config, key)
    existing = config[key]
    if existing.db_def_folder != "dynamic_connection"
      throw(InvalidConfigurationError("Cannot overwrite static connection '$(key)'. This key is bound to folder '$(existing.db_def_folder)'."))
    end
    
    @warn "Dynamic connection '$(key)' already exists. Closing old pool before re-registering."
    close_pool!(key)
  end

  # Create a minimal Settings object
  settings = Settings(
    app_env = haskey(ENV, "PORMG_ENV") ? ENV["PORMG_ENV"] : DEV,
    db_def_folder = "dynamic_connection"
  )
  
  settings.db_config_settings = Dict{String, Any}(
    "adapter" => adapter,
    "url" => url,
    "pool_size" => pool_size,
    "sqlite_split_read_write" => sqlite_split_read_write,
    "idle_timeout" => idle_timeout,
    "max_lifetime" => max_lifetime,
    "pool_timeout" => pool_timeout,
    "leak_detection_threshold" => leak_detection_threshold,
    "fail_fast_on_connect" => fail_fast_on_connect
  )

  CP = getfield(parentmodule(@__MODULE__), :ConnectionPool)

  if adapter == "PostgreSQL"
    settings.connections = CP.PostgresConnectionPool(url; pool_size=pool_size, pool_timeout=pool_timeout, fail_fast_on_connect=fail_fast_on_connect)
  elseif adapter == "SQLite"
    settings.connections = CP.SQLiteConnectionPool(url; pool_size=pool_size, split_read_write=sqlite_split_read_write, pool_timeout=pool_timeout, fail_fast_on_connect=fail_fast_on_connect)
  else
    throw(InvalidConfigurationError("Unsupported adapter: $adapter"))
  end

  # Opt into idle-reaping / max-lifetime (#125) and/or leak detection (#127) if configured. No-ops when 0.
  (idle_timeout > 0 || max_lifetime > 0) &&
    CP.enable_reaping!(settings.connections; idle_timeout=idle_timeout, max_lifetime=max_lifetime)
  leak_detection_threshold > 0 &&
    CP.enable_leak_detection!(settings.connections; threshold=leak_detection_threshold)

  config[key] = settings
  return key
end

"""
    unregister_connection(key::String)

Close the connection pool and remove the configuration for the specified key.
"""
function unregister_connection(key::String)
  if haskey(config, key)
    close_pool!(key)
    delete!(config, key)
    return true
  end
  return false
end

"""
    close_pool!(pool::Union{PormGPostgres, PormGSQLite})
    close_pool!(db::String)

Close all connections in the database pool.
"""
function close_pool!(pool::Union{PormGPostgres, PormGSQLite})
  CP = getfield(parentmodule(@__MODULE__), :ConnectionPool)
  CP.close_pool!(pool)
end

function close_pool!(db::String)
  settings::PormGSettings = get_settings(db)
  if settings.connections !== nothing
    close_pool!(settings.connections)
  end
end

"""
    ping(path_or_key::String) -> Bool

Check whether a loaded database configuration is reachable right now.
This performs a real connection acquisition and liveness check instead of only
verifying that settings exist in memory.
"""
function ping(path_or_key::String)::Bool
  key = _resolve_loaded_key(path_or_key)
  key === nothing && return false

  settings::PormGSettings = config[key]
  pool = settings.connections
  pool === nothing && return false

  CP = getfield(parentmodule(@__MODULE__), :ConnectionPool)
  conn = nothing

  try
    if pool isa PormGSQLite
      conn = CP.acquire_connection(pool; timeout_seconds=5, max_retries=1, mode=:read)
    else
      conn = CP.acquire_connection(pool; timeout_seconds=5, max_retries=1)
    end
    return backend_is_alive(pool, conn)
  catch e
    @warn "Database ping failed" key=key db_def_folder=settings.db_def_folder adapter=get(settings.db_config_settings, "adapter", nothing) exception=(e, catch_backtrace())
    return false
  finally
    if conn !== nothing
      try
        CP.release_connection(pool, conn)
      catch
        # Releasing a failed health-check connection should not mask the original probe result.
      end
    end
  end
end

"""
    status(path_or_key::String) -> NamedTuple

Return a compact server-oriented status payload describing whether a
configuration is loaded and reachable.
"""
function status(path_or_key::String)
  key = _resolve_loaded_key(path_or_key)
  if key === nothing
    return (
      key = path_or_key,
      loaded = false,
      reachable = false,
      adapter = nothing,
      app_env = nothing,
      db_def_folder = nothing,
      dynamic = false,
    )
  end

  settings::PormGSettings = config[key]
  return (
    key = key,
    loaded = true,
    reachable = ping(key),
    adapter = get(settings.db_config_settings, "adapter", nothing),
    app_env = settings.app_env,
    db_def_folder = settings.db_def_folder,
    dynamic = settings.db_def_folder == "dynamic_connection",
  )
end

# Reconnection is now handled automatically by the ConnectionPool via acquire_connection()
# and reconnect_db() inside the fetch() cycle. Old direct handle logic removed.

#
# Settings struct
#

mutable struct Settings <: PormGSettings
  app_env::String
  db_def_folder::String # same then key
  model_file::String
  db_config_settings::Dict{String,Any}
  log_queries::Bool
  log_level::Logging.LogLevel
  log_to_file::Bool
  change_db::Bool # Enable makemigrations and migrations functionality in the app
  change_data::Bool # Enable the change of the database (upgrade, delete) in the app
  connections::Union{Nothing, PormGPostgres, PormGSQLite}
  time_zone::String
  django_prefix::Union{Nothing, String}

  Settings(;
      app_env             = haskey(ENV, "PORMG_ENV") ? ENV["PORMG_ENV"] : "dev",           
      db_def_folder       = DB_PATH,
      model_file          = MODEL_FILE,
      db_config_settings  = Dict{String,Any}(),
      log_queries         = true,
      log_level           = Logging.Debug,
      log_to_file         = true,
      change_db           = false,
      change_data         = false,
      connections         = nothing,
          time_zone           = UTC_TIMEZONE,
      django_prefix       = nothing
  ) =
  new(
      app_env,
      db_def_folder,
      model_file,
      db_config_settings,
      log_queries,
      log_level,
      log_to_file,
      change_db,
      change_data,
      connections,
      time_zone,
      django_prefix
  )
end

"""
    ensure_before_connect!(pool) -> Bool

Run the registered `before_connect` hook before opening a physical connection.
When no hook is registered, connection setup proceeds normally.
"""
function ensure_before_connect!(pool::Union{PormGPostgres, PormGSQLite})::Bool
  hook = _BEFORE_CONNECT_HOOK[]
  hook === nothing && return true

  key = connection_key_for_pool(pool)
  key === nothing && return true

  settings = config[key]

  try
    return hook(key, settings) === true
  catch e
    @error "before_connect hook failed" key=key db_def_folder=settings.db_def_folder exception=(e, catch_backtrace())
    return false
  end
end

# Add this to your module cleanup if needed
function __cleanup__()
  for (path, settings) in config
    # Close the registered pool if there is one. `settings.connections` is a PormGBackend pool or nothing.
    if settings.connections isa PormGBackend
      # Registered as an atexit hook (#203): one bad pool must not abort cleanup of the rest, nor
      # surface a stray error during process teardown. @debug (not @warn) — at-exit logging stays quiet.
      try
        close_pool!(settings.connections)
      catch e
        @debug "PormG atexit cleanup: error closing pool for '$path'" exception=e
      end
    end
  end
end

end