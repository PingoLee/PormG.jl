# ==============================================================================
# MIGRATION RUNNER
# Logic for applying generated migration plans to the database (migrate).
#
# Lifecycle: prepare → validate → lock → execute → commit/rollback →
#            record status → archive
#
# History table (pormg_migrations) is the canonical runtime source of truth.
# Filesystem archives remain secondary.
# ==============================================================================

import SHA: sha256

# Regex patterns for detecting destructive SQL operations
const _DESTRUCTIVE_PATTERNS = [
  r"DROP\s+TABLE"i,
  r"DROP\s+COLUMN"i,
  r"DROP\s+INDEX"i,
  r"DROP\s+CONSTRAINT"i,
  r"TRUNCATE\s+TABLE"i,
]

# ==============================================================================
# Helper: extract OrderedDicts from a loaded migration module
# ==============================================================================

function get_all_dicts(mod::Module)
  ordered_dicts = []
  for name in names(mod, all = true)
    if isdefined(mod, name)
      obj = getfield(mod, name)
      if isa(obj, OrderedDict)
        push!(ordered_dicts, obj)
      end
    end
  end
  return ordered_dicts
end

# ==============================================================================
# Migration History: checksum, version generation, destructive detection
# ==============================================================================

"""
    compute_checksum(sql_content::String) -> String

Compute a SHA-256 hex digest of the SQL content for integrity verification.
"""
function compute_checksum(sql_content::String)::String
  return bytes2hex(sha256(Vector{UInt8}(sql_content)))
end

"""
    generate_version() -> String

Generate a unique migration version string based on timestamp (YYYYMMDDHHmmssSSS).
Includes milliseconds to prevent version collisions for rapid successive migrations.
"""
function generate_version()::String
  return Dates.format(Dates.now(), "yyyymmddHHMMSSsss")
end

"""
    is_destructive(sql::String) -> Bool

Check if a SQL statement contains destructive operations (DROP TABLE, DROP COLUMN, etc.).
"""
function is_destructive(sql::String)::Bool
  for pattern in _DESTRUCTIVE_PATTERNS
    if occursin(pattern, sql)
      return true
    end
  end
  return false
end

"""
    detect_destructive_actions(statements::Vector{String}) -> Vector{String}

Return the subset of SQL statements that contain destructive operations.
"""
function detect_destructive_actions(statements::Vector{String})::Vector{String}
  return filter(is_destructive, statements)
end

function _manual_checksum(version::String, name::String)::String
  return bytes2hex(sha256(Vector{UInt8}("manual:" * version * ":" * name)))
end

# ==============================================================================
# Bootstrap: init_migrations() — ensure the history table exists
# ==============================================================================

"""
    init_migrations(connection::Union{PormGPostgres, PormGSQLite})

Create the pormg_migrations history table if it does not already exist.
This is called automatically by `migrate()` and `status()` but can be
invoked explicitly for bootstrapping.
"""
function init_migrations(connection::PormGPostgres)
  ddl = Dialect.create_migrations_table(connection)
  fetch(connection, ddl)
  nothing
end

function init_migrations(connection::PormGSQLite)
  ddl = Dialect.create_migrations_table(connection)
  fetch(connection, ddl)
  nothing
end

function init_migrations(settings::SQLConn)
  init_migrations(settings.connections)
end

function init_migrations(db::String; config::Dict{String,SQLConn} = config)
  settings = config[db]
  init_migrations(settings)
end

# ==============================================================================
# History table queries
# ==============================================================================

"""
    _migrations_table_exists(connection) -> Bool

Check whether the pormg_migrations table already exists in the database.
"""
function _migrations_table_exists(connection::PormGPostgres)::Bool
  sql = Dialect.migrations_table_exists_sql(connection)
  df = DataFrame(fetch(connection, sql))
  return nrow(df) > 0 && df[1, 1] == true
end

function _migrations_table_exists(connection::PormGSQLite)::Bool
  sql = Dialect.migrations_table_exists_sql(connection)
  df = DataFrame(fetch(connection, sql))
  return nrow(df) > 0 && df[1, 1] > 0
end

"""
    _get_applied_migrations(connection) -> Vector{NamedTuple}

Fetch all migration records from the history table, ordered by version.
"""
function _get_applied_migrations(connection::Union{PormGPostgres, PormGSQLite})
  if !_migrations_table_exists(connection)
    return NamedTuple[]
  end
  sql = Dialect.select_all_migrations_sql(connection)
  df = DataFrame(fetch(connection, sql))
  # Convert DataFrame rows to NamedTuples for uniform access
  return [NamedTuple(row) for row in eachrow(df)]
end

"""
    _get_live_table_names(connection) -> Vector{String}

Retrieve the list of user table names from the live database schema.
Used for drift detection.
"""
function _get_live_table_names(connection::PormGPostgres)::Vector{String}
  sql = """SELECT table_name FROM information_schema.tables WHERE table_schema = 'public' AND table_type = 'BASE TABLE';"""
  df = DataFrame(fetch(connection, sql))
  return String[string(r[:table_name]) for r in eachrow(df)]
end

function _get_live_table_names(connection::PormGSQLite)::Vector{String}
  sql = """SELECT name FROM sqlite_master WHERE type='table' ORDER BY name;"""
  df = DataFrame(fetch(connection, sql))
  return String[string(r[:name]) for r in eachrow(df)]
end

"""
    _record_migration(connection, version, name, checksum, sql_content, status, is_destructive; conn)

Insert a migration record into the history table within an existing transaction connection.
"""
function _record_migration(pool::PormGPostgres, version::String, name::String, checksum::String, 
                           sql_content::String, status::String, is_destr::Bool; 
                           conn::Union{Nothing, LibPQ.Connection} = nothing)
  sql = """INSERT INTO pormg_migrations ("version", "name", "checksum", "sql_content", "status", "is_destructive") 
           VALUES ('$(replace(version, "'" => "''"))', '$(replace(name, "'" => "''"))', '$(replace(checksum, "'" => "''"))', 
           '$(replace(sql_content, "'" => "''"))', '$(replace(status, "'" => "''"))', $(is_destr));"""
  with_transaction(pool, sql, conn=conn)
end

function _record_migration(pool::PormGSQLite, version::String, name::String, checksum::String, 
                           sql_content::String, status::String, is_destr::Bool; 
                           conn::Union{Nothing, SQLite.DB} = nothing)
  is_destr_val = is_destr ? 1 : 0
  sql = """INSERT INTO pormg_migrations ("version", "name", "checksum", "sql_content", "status", "is_destructive") 
           VALUES ('$(replace(version, "'" => "''"))', '$(replace(name, "'" => "''"))', '$(replace(checksum, "'" => "''"))', 
           '$(replace(sql_content, "'" => "''"))', '$(replace(status, "'" => "''"))', $(is_destr_val));"""
  with_transaction(pool, sql, conn=conn)
end

"""
    _update_migration_status(connection, version, new_status; conn)

Update the status of an existing migration record.
"""
function _update_migration_status(pool::Union{PormGPostgres, PormGSQLite}, version::String, new_status::String; 
                                  conn = nothing)
  sql = """UPDATE pormg_migrations SET "status" = '$(replace(new_status, "'" => "''"))' WHERE "version" = '$(replace(version, "'" => "''"))';"""
  with_transaction(pool, sql, conn=conn)
end

# ==============================================================================
# Status API
# ==============================================================================

"""
    MigrationStatus

Structured result from `status()`. Contains applied migrations, pending files,
failed migrations, and drift signals.
"""
struct MigrationStatus
  applied::Vector{NamedTuple}    # Migrations recorded as 'applied' in DB
  failed::Vector{NamedTuple}     # Migrations recorded as 'failed' in DB
  pending::Bool                  # Whether a pending_migrations.jl file exists
  has_history_table::Bool        # Whether pormg_migrations table exists
  drift_signals::Vector{String}  # Informational messages about potential drift
end

function Base.show(io::IO, s::MigrationStatus)
  println(io, "Migration Status:")
  println(io, "  History table: ", s.has_history_table ? "✓ exists" : "✗ not initialized (run init_migrations)")
  println(io, "  Applied: ", length(s.applied), " migration(s)")
  if !isempty(s.failed)
    println(io, "  \e[31mFailed: ", length(s.failed), " migration(s)\e[0m")
    for m in s.failed
      println(io, "    - v", m[:version], " ", m[:name])
    end
  end
  println(io, "  Pending file: ", s.pending ? "\e[33myes (review and run migrate)\e[0m" : "none")
  if !isempty(s.drift_signals)
    println(io, "  \e[33mDrift signals:\e[0m")
    for d in s.drift_signals
      println(io, "    ⚠ ", d)
    end
  end
  if !isempty(s.applied)
    println(io, "\n  Applied migrations:")
    for m in s.applied
      println(io, "    [", m[:version], "] ", m[:name], " (", m[:status], ", ", 
              m[:is_destructive] in [true, 1] ? "destructive" : "safe", ")")
    end
  end
end

"""
    status(connection, settings) -> MigrationStatus

Report migration status: applied, failed, pending, and drift signals.
Includes basic drift detection by comparing live database tables against
the history of applied migrations.
"""
function status(connection::Union{PormGPostgres, PormGSQLite}, settings::SQLConn)::MigrationStatus
  has_table = _migrations_table_exists(connection)
  
  applied = NamedTuple[]
  failed = NamedTuple[]
  drift_signals = String[]
  
  if has_table
    all_records = _get_applied_migrations(connection)
    for r in all_records
      if r[:status] == "applied"
        push!(applied, r)
      elseif r[:status] == "failed"
        push!(failed, r)
      end
    end
  else
    push!(drift_signals, "History table pormg_migrations does not exist. Run init_migrations() to bootstrap.")
  end
  
  # Check for pending migrations file
  pending_path = joinpath(settings.db_def_folder, "migrations", "pending_migrations.jl")
  has_pending = isfile(pending_path)
  
  if has_pending && !isempty(applied)
    push!(drift_signals, "Pending migrations file exists alongside applied history — review before applying.")
  end
  
  # Drift detection: check for failed migrations that need attention
  if !isempty(failed)
    push!(drift_signals, "$(length(failed)) failed migration(s) detected. Investigate and use mark_applied/mark_failed/remove_migration_record to reconcile.")
  end
  
  # Basic drift detection: try to detect tables in the live schema that have no
  # migration history (possible out-of-band schema changes)
  if has_table && !isempty(applied)
    try
      live_tables = _get_live_table_names(connection)
      # Filter out internal tables
      internal_tables = Set(["pormg_migrations", "sqlite_sequence"])
      live_user_tables = filter(t -> !(t in internal_tables), live_tables)
      
      if isempty(live_user_tables) && !isempty(applied)
        push!(drift_signals, "No user tables found in database but migrations are recorded — possible external drop.")
      end
    catch e
      # Don't fail status() if drift detection fails
      @debug "Drift detection skipped" exception=e
    end
  end
  
  return MigrationStatus(applied, failed, has_pending, has_table, drift_signals)
end

function status(settings::SQLConn)::MigrationStatus
  status(settings.connections, settings)
end

function status(db::String; config::Dict{String,SQLConn} = config)::MigrationStatus
  settings = config[db]
  status(settings)
end

# ==============================================================================
# Migration Plan Loading & Ordering
# ==============================================================================

"""
    _load_migration_plan(settings) -> Vector{OrderedDict}

Load and return all OrderedDicts from the pending_migrations.jl file.
"""
function _load_migration_plan(settings::SQLConn)
  pending_path = joinpath(settings.db_def_folder, "migrations", "pending_migrations.jl")
  if !isfile(pending_path)
    error("No pending migrations found at: $pending_path")
  end
  temp_migration_module = include(pending_path)
  return Base.invokelatest(get_all_dicts, temp_migration_module)
end

"""
    _order_statements(migration_plan) -> (ordered_statements, all_sql_content)

Order SQL statements for safe execution:
1. New tables (CREATE TABLE)
2. Drop tables
3. Rename fields
4. All other alterations

Returns the ordered statements and the concatenated SQL content for checksum.
"""
function _order_statements(migration_plan)
  first_execution::Vector{String} = []
  second_execution::Vector{String} = []
  third_execution::Vector{String} = []
  last_execution::Vector{String} = []

  for dict_instructs in migration_plan
    for (key, value) in dict_instructs
      if key == "New model"
        push!(first_execution, value)
      elseif key == "Drop table"
        push!(second_execution, value)
      elseif contains(key, "Rename field")
        push!(third_execution, value)
      else
        push!(last_execution, value)
      end
    end
  end

  ordered = vcat(first_execution, second_execution, third_execution, last_execution)
  all_sql = join(ordered, "\n")
  return ordered, all_sql
end

# ==============================================================================
# Dry Run
# ==============================================================================

"""
    DryRunResult

Result of a dry-run migration analysis.

Contains only the substantive fields needed to evaluate the migration plan.
Use `is_destructive(r)` and `total_statements(r)` for derived properties.
"""
struct DryRunResult
  checksum::String
  statements::Vector{String}
  destructive_statements::Vector{String}
end

"""Whether the dry-run result contains any destructive statements."""
is_destructive(r::DryRunResult) = !isempty(r.destructive_statements)

"""Total number of SQL statements in the dry-run result."""
total_statements(r::DryRunResult) = length(r.statements)

function Base.show(io::IO, r::DryRunResult)
  println(io, "Dry Run Result:")
  println(io, "  Checksum: ", r.checksum[1:min(16, length(r.checksum))], "...")
  println(io, "  Total statements: ", total_statements(r))
  if is_destructive(r)
    println(io, "  \e[31m⚠ DESTRUCTIVE: ", length(r.destructive_statements), " destructive statement(s)\e[0m")
    for s in r.destructive_statements
      # Show first 120 chars of each destructive statement
      display_s = length(s) > 120 ? s[1:120] * "..." : s
      println(io, "    → ", display_s)
    end
  else
    println(io, "  \e[32m✓ Safe (no destructive operations)\e[0m")
  end
  println(io, "\n  SQL statements:")
  for (i, s) in enumerate(r.statements)
    display_s = length(s) > 200 ? s[1:200] * "..." : s
    println(io, "    $i. ", display_s)
  end
end

"""
    dry_run(connection, settings) -> DryRunResult

Analyze pending migrations without applying them.
Validates ordering, checksums, destructive actions, and SQL generation.
Does NOT modify the database or move files.
"""
function dry_run(connection::Union{PormGPostgres, PormGSQLite}, settings::SQLConn)::DryRunResult
  migration_plan = _load_migration_plan(settings)
  ordered_statements, all_sql = _order_statements(migration_plan)
  
  checksum = compute_checksum(all_sql)
  destructive_stmts = detect_destructive_actions(ordered_statements)
  
  return DryRunResult(
    checksum,
    ordered_statements,
    destructive_stmts
  )
end

function dry_run(settings::SQLConn)::DryRunResult
  dry_run(settings.connections, settings)
end

function dry_run(db::String; config::Dict{String,SQLConn} = config)::DryRunResult
  settings = config[db]
  dry_run(settings)
end

# ==============================================================================
# Core Execution Engine — unified lifecycle for both PostgreSQL and SQLite
# ==============================================================================

"""
    _execute_statements_pg(connection, statements; conn) -> Nothing

Execute a list of SQL statements on a PostgreSQL connection within a transaction.
"""
function _execute_statements_pg(connection::PormGPostgres, statements::Vector{String}; conn)
  for action in statements
    @debug "Executing: $action"
    with_transaction(connection, action, conn=conn)
  end
end

function _split_sqlite_statements(sql::String)::Vector{String}
  statements = String[]
  buffer = IOBuffer()
  in_single_quote = false
  in_double_quote = false
  escape_next = false

  for char in sql
    if escape_next
      write(buffer, char)
      escape_next = false
      continue
    end

    if char == '\\'
      write(buffer, char)
      escape_next = true
      continue
    end

    if char == '\'' && !in_double_quote
      in_single_quote = !in_single_quote
      write(buffer, char)
      continue
    end

    if char == '"' && !in_single_quote
      in_double_quote = !in_double_quote
      write(buffer, char)
      continue
    end

    if char == ';' && !in_single_quote && !in_double_quote
      statement = strip(String(take!(buffer)))
      isempty(statement) || push!(statements, statement)
      continue
    end

    write(buffer, char)
  end

  statement = strip(String(take!(buffer)))
  isempty(statement) || push!(statements, statement)
  return statements
end

"""
    _execute_statements_sqlite(connection, statements; conn) -> Nothing

Execute a list of SQL statements on a SQLite connection within a transaction.
SQLite requires splitting multi-statement strings by `;`.
"""
function _execute_statements_sqlite(connection::PormGSQLite, statements::Vector{String}; conn)
  for action in statements
    parts = _split_sqlite_statements(action)
    for part in parts
      trimmed = strip(part) |> string
      isempty(trimmed) && continue
      @debug "Executing: $trimmed"
      with_transaction(connection, trimmed, conn=conn)
    end
  end
end

"""
    _archive_migration_files(settings, date_str) -> Nothing

Move pending_migrations.jl to applied_migrations/ and snapshot the models file.
"""
function _archive_migration_files(settings::SQLConn, date_str::String)
  path_applied = joinpath(settings.db_def_folder, "migrations", "applied_migrations")
  if !ispath(path_applied)
    mkpath(path_applied)
  end
  
  target_migration = joinpath(path_applied, "$(date_str)_migration.jl")
  while isfile(target_migration)
    suffix = string(rand(1000:9999))
    target_migration = joinpath(path_applied, "$(date_str)_$(suffix)_migration.jl")
  end
  
  pending_path = joinpath(settings.db_def_folder, "migrations", "pending_migrations.jl")
  if isfile(pending_path)
    mv(pending_path, target_migration)
  end
  
  final_date_str = replace(basename(target_migration), "_migration.jl" => "")
  models_path = joinpath(settings.db_def_folder, settings.model_file)
  if isfile(models_path)
    cp(models_path, joinpath(path_applied, "$(final_date_str)_old_models.jl"), force=true)
  end
end

# ==============================================================================
# Main migrate() — unified lifecycle
# ==============================================================================

"""
    migrate(connection::PormGPostgres, settings; interactive, destructive, dry_run_only, name)

Apply pending migrations to a PostgreSQL database.

# Lifecycle
1. Validate: check change_db, load plan, detect destructive ops
2. Lock: acquire advisory lock to prevent concurrent migrations
3. Execute: run SQL in a transaction
4. Record: insert history into pormg_migrations
5. Archive: move files to applied_migrations/

# Keywords
- `interactive::Bool=true`: prompt for confirmation before applying
- `destructive::Bool=false`: must be `true` to allow DROP TABLE / DROP COLUMN operations
- `dry_run_only::Bool=false`: if `true`, only analyze without applying (returns DryRunResult)
- `name::String="pending_migration"`: name for this migration in the history table
"""
function migrate(connection::PormGPostgres, settings::SQLConn;
                 path::String = "db/models/models.jl",
                 interactive::Bool = true,
                 destructive::Bool = false,
                 dry_run_only::Bool = false,
                 name::String = "pending_migration")
  # --- Phase 1: Validate ---
  if !settings.change_db
    @warn("The database is not set to change_db, so the migration plan will not be applied.")
    return nothing
  end

  # Bootstrap history table
  init_migrations(connection)

  # Install any configured PostgreSQL extensions (e.g. unaccent + the immutable_unaccent
  # helper). This is the deliberate, change_db-gated home for that DDL — never on app boot.
  # Runs before the empty-plan early return so `migrate()` provisions extensions even when
  # there is no schema diff. CREATE ... IF NOT EXISTS keeps it idempotent across runs.
  Configuration._install_configured_extensions!(settings)

  # Load and order the plan
  migration_plan = _load_migration_plan(settings)
  ordered_statements, all_sql = _order_statements(migration_plan)
  
  if isempty(ordered_statements)
    @info("\e[32mNo SQL statements to execute.\e[0m")
    return nothing
  end
  
  version = generate_version()
  checksum = compute_checksum(all_sql)
  destructive_stmts = detect_destructive_actions(ordered_statements)
  has_destructive = !isempty(destructive_stmts)
  
  # Dry run mode
  if dry_run_only
    return DryRunResult(checksum, ordered_statements, destructive_stmts)
  end
  
  # Destructive guard
  if has_destructive && !destructive
    @error("\e[31mMigration contains $(length(destructive_stmts)) destructive operation(s). " *
           "Pass `destructive=true` to confirm.\e[0m")
    for s in destructive_stmts
      display_s = length(s) > 120 ? s[1:120] * "..." : s
      @error("  → $display_s")
    end
    return nothing
  end
  
  # Interactive confirmation
  if interactive
    if has_destructive
      @info("\e[31m⚠ This migration contains DESTRUCTIVE operations (DROP TABLE, DROP COLUMN, etc.).\e[0m")
    end
    @info("\e[33mBefore applying the migrations, make sure to back up your database.\e[0m")
    print("\e[31mAre you sure you want to apply the migrations? (yes/no): \e[0m")
    response = readline()
    response = strip(lowercase(response))
    if !(response in ["yes", "y"])
      @info("Migrations were not applied.")
      return nothing
    end
  end
  
  # --- Phase 2: Lock (PostgreSQL advisory lock) ---
  lock_key = "pormg_migrations_$(settings.db_def_folder)"
  
  AdvisoryLock.with_advisory_lock(connection, lock_key; wait=true, timeout_ms=30_000) do
    _execute_migration_lifecycle(connection, settings, ordered_statements, all_sql,
                                 version, name, checksum, has_destructive)
  end
end

"""
    migrate(connection::PormGSQLite, settings; interactive, destructive, dry_run_only, name)

Apply pending migrations to a SQLite database.

SQLite migrations use BEGIN IMMEDIATE TRANSACTION for safety.
Advisory locking is not available — single-instance migration safety only.
"""
function migrate(connection::PormGSQLite, settings::SQLConn; 
                 path::String = "db/models/models.jl",
                 interactive::Bool = true, 
                 destructive::Bool = false,
                 dry_run_only::Bool = false,
                 name::String = "pending_migration")
  # --- Phase 1: Validate ---
  if !settings.change_db
    @warn("The database is not set to change_db, so the migration plan will not be applied.")
    return nothing
  end
  
  # Bootstrap history table
  init_migrations(connection)
  
  # Load and order the plan
  migration_plan = _load_migration_plan(settings)
  ordered_statements, all_sql = _order_statements(migration_plan)
  
  if isempty(ordered_statements)
    @info("\e[32mNo SQL statements to execute.\e[0m")
    return nothing
  end
  
  version = generate_version()
  checksum = compute_checksum(all_sql)
  destructive_stmts = detect_destructive_actions(ordered_statements)
  has_destructive = !isempty(destructive_stmts)
  
  # Dry run mode
  if dry_run_only
    return DryRunResult(checksum, ordered_statements, destructive_stmts)
  end
  
  # Destructive guard
  if has_destructive && !destructive
    @error("\e[31mMigration contains $(length(destructive_stmts)) destructive operation(s). " *
           "Pass `destructive=true` to confirm.\e[0m")
    for s in destructive_stmts
      display_s = length(s) > 120 ? s[1:120] * "..." : s
      @error("  → $display_s")
    end
    return nothing
  end
  
  # Interactive confirmation
  if interactive
    if has_destructive
      @info("\e[31m⚠ This migration contains DESTRUCTIVE operations (DROP TABLE, DROP COLUMN, etc.).\e[0m")
    end
    @info("\e[33mBefore applying the migrations, make sure to back up your database.\e[0m")
    print("\e[31mAre you sure you want to apply the migrations? (yes/no): \e[0m")
    response = readline()
    response = strip(lowercase(response))
    if !(response in ["yes", "y"])
      @info("Migrations were not applied.")
      return nothing
    end
  end
  
  # --- Phase 2: No advisory lock for SQLite (single-instance only) ---
  _execute_migration_lifecycle(connection, settings, ordered_statements, all_sql,
                               version, name, checksum, has_destructive)
end

# ==============================================================================
# Shared execution lifecycle (called within lock for PostgreSQL)
# ==============================================================================

function _execute_migration_lifecycle(connection::PormGPostgres, settings::SQLConn,
                                      ordered_statements::Vector{String}, all_sql::String,
                                      version::String, name::String, checksum::String, 
                                      has_destructive::Bool)
  date_str = Dates.format(Dates.now(), "yyyy-mm-dd_HH-MM-SS")
  
  # Begin transaction
  result, conn = with_transaction(connection, "BEGIN;")
  
  try
    # Execute all SQL statements
    _execute_statements_pg(connection, ordered_statements; conn=conn)
    
    # Record in history table (within same transaction)
    _record_migration(connection, version, name, checksum, all_sql, "applied", has_destructive; conn=conn)
    
    # Commit
    with_transaction(connection, "COMMIT;", conn=conn, release_conn=true)
    @info("\e[32mMigrations applied successfully. Version: $version\e[0m")
  catch e
    # Rollback and record failure
    try
      with_transaction(connection, "ROLLBACK;", conn=conn, release_conn=true)
    catch rollback_err
      @error "Failed to rollback transaction" exception=rollback_err
    end
    
    # Record failed status outside the rolled-back transaction
    try
      _record_migration(connection, version, name, checksum, all_sql, "failed", has_destructive)
    catch record_err
      @error "Failed to record migration failure in history table" exception=record_err
    end
    
    @error "Error applying migrations" exception=e
    rethrow(e)
  end
  
  # Archive files (post-commit, best-effort)
  try
    _archive_migration_files(settings, date_str)
  catch e
    @error "Error archiving migration files (migration was applied successfully)" exception=e
  end
end

function _execute_migration_lifecycle(connection::PormGSQLite, settings::SQLConn,
                                      ordered_statements::Vector{String}, all_sql::String,
                                      version::String, name::String, checksum::String, 
                                      has_destructive::Bool)
  date_str = Dates.format(Dates.now(), "yyyy-mm-dd_HH-MM-SS")
  
  # Begin transaction (IMMEDIATE for SQLite)
  result, conn = with_transaction(connection, "BEGIN IMMEDIATE TRANSACTION;")
  
  try
    # Execute all SQL statements
    _execute_statements_sqlite(connection, ordered_statements; conn=conn)
    
    # Record in history table (within same transaction)
    _record_migration(connection, version, name, checksum, all_sql, "applied", has_destructive; conn=conn)
    
    # Commit
    with_transaction(connection, "COMMIT;", conn=conn, release_conn=true)
    @info("\e[32mMigrations applied successfully. Version: $version\e[0m")
  catch e
    try
      with_transaction(connection, "ROLLBACK;", conn=conn, release_conn=true)
    catch rollback_err
      @error "Failed to rollback transaction" exception=rollback_err
    end
    
    # Record failed status outside the rolled-back transaction
    try
      _record_migration(connection, version, name, checksum, all_sql, "failed", has_destructive)
    catch record_err
      @error "Failed to record migration failure in history table" exception=record_err
    end
    
    @error "Error applying migrations" exception=e
    rethrow(e)
  end
  
  # Archive files (post-commit, best-effort)
  try
    _archive_migration_files(settings, date_str)
  catch e
    @error "Error archiving migration files (migration was applied successfully)" exception=e
  end
end

# ==============================================================================
# String-based entry point
# ==============================================================================

function migrate(db::String; config::Dict{String,SQLConn} = config, interactive::Bool = true,
                 destructive::Bool = false, dry_run_only::Bool = false, name::String = "pending_migration")
  settings = config[db]
  migrate(settings.connections, settings, interactive=interactive, destructive=destructive, 
          dry_run_only=dry_run_only, name=name)
end

# ==============================================================================
# Targeted Execution: migrate_to(version)
# ==============================================================================

"""
    migrate_to(connection, settings, target_version; interactive, destructive)

Apply pending migrations up to (and including) a specific version.
Only meaningful when multiple migration files exist in the pending queue.
For now, this validates the target version against the current history.
"""
function migrate_to(connection::Union{PormGPostgres, PormGSQLite}, settings::SQLConn, 
                    target_version::String; interactive::Bool = true, destructive::Bool = false)
  init_migrations(connection)
  
  applied = _get_applied_migrations(connection)
  for m in applied
    if m[:version] == target_version
      @info("Version $target_version is already applied.")
      return nothing
    end
  end

  throw(ArgumentError("migrate_to(version) is not implemented for the current single pending_migrations.jl workflow. Generate and apply the pending plan with migrate(), or implement ordered multi-file migration queues first."))
end

function migrate_to(db::String, target_version::String; config::Dict{String,SQLConn} = config, 
                    interactive::Bool = true, destructive::Bool = false)
  settings = config[db]
  migrate_to(settings.connections, settings, target_version; interactive=interactive, destructive=destructive)
end

# ==============================================================================
# Repair Operations
# ==============================================================================

"""
    mark_applied(connection, settings, version, name; checksum, sql_content)

Manually mark a migration version as applied in the history table.
Useful for reconciliation after manual intervention or interrupted migrations.
"""
function mark_applied(connection::Union{PormGPostgres, PormGSQLite}, settings::SQLConn,
                      version::String, name::String; 
                      checksum::String = "", sql_content::String = "")
  init_migrations(connection)
  
  if isempty(checksum) && !isempty(sql_content)
    checksum = compute_checksum(sql_content)
  elseif isempty(checksum)
    checksum = _manual_checksum(version, name)
  end
  
  _record_migration(connection, version, name, checksum, sql_content, "applied", false)
  @info("Marked version $version as applied.")
end

function mark_applied(db::String, version::String, name::String; config::Dict{String,SQLConn} = config, kwargs...)
  settings = config[db]
  mark_applied(settings.connections, settings, version, name; kwargs...)
end

"""
    mark_failed(connection, settings, version)

Update an existing migration record to 'failed' status.
Useful after manual investigation of a partially-applied migration.
"""
function mark_failed(connection::Union{PormGPostgres, PormGSQLite}, settings::SQLConn,
                     version::String)
  init_migrations(connection)
  _update_migration_status(connection, version, "failed")
  @info("Marked version $version as failed.")
end

function mark_failed(db::String, version::String; config::Dict{String,SQLConn} = config)
  settings = config[db]
  mark_failed(settings.connections, settings, version)
end

"""
    remove_migration_record(connection, settings, version)

Remove a migration record from the history table entirely.
Use with caution — this erases history. Intended for cleanup after
manual rollbacks or test scenarios.
"""
function remove_migration_record(connection::Union{PormGPostgres, PormGSQLite}, settings::SQLConn,
                                 version::String)
  init_migrations(connection)
  
  # Use dialect-specific delete
  if connection isa PormGPostgres
    sql = """DELETE FROM pormg_migrations WHERE "version" = '$(replace(version, "'" => "''"))';"""
  else
    sql = """DELETE FROM pormg_migrations WHERE "version" = '$(replace(version, "'" => "''"))';"""
  end
  fetch(connection, sql)
  @info("Removed migration record for version $version.")
end

function remove_migration_record(db::String, version::String; config::Dict{String,SQLConn} = config)
  settings = config[db]
  remove_migration_record(settings.connections, settings, version)
end

"""
    discard_pending_migration(settings; backup=true) -> NamedTuple | Nothing
    discard_pending_migration(db::String; config=config, backup=true) -> NamedTuple | Nothing

Discard the un-applied pending migration draft (`migrations/pending_migrations.jl`) for this
connection — e.g. a `makemigrations` plan you generated and then regretted.

A pending migration is only a file with no database state behind it, so this is
filesystem-only: it never touches the `pormg_migrations` history table or the schema (unlike
`remove_migration_record` / `migrate_to`, which mutate applied state). That makes discarding
a draft the one inherently safe, reversible migration op.

When `backup=true` (default) the file is renamed to `pending_migrations.jl.discarded`
(overwriting any previous discard) so the draft can be recovered; otherwise it is deleted.
`makemigrations` overwrites the pending file anyway, so a later regenerate is unaffected.

Returns `(discarded=true, path, backup, tables, statements)` describing what was thrown away,
or `nothing` when there is no pending migration. Pairs with [`status`](@ref), which reports
whether a pending file exists.
"""
function discard_pending_migration(settings::SQLConn; backup::Bool = true)
  pending_path = joinpath(settings.db_def_folder, "migrations", "pending_migrations.jl")
  if !isfile(pending_path)
    @info("\e[32mNo pending migration to discard.\e[0m")
    return nothing
  end

  # Best-effort summary of what we're discarding. Never let a parse error block the discard —
  # getting rid of a bad/unwanted draft is exactly the point of this function.
  tables = 0
  statements = 0
  try
    plan = _load_migration_plan(settings)
    tables = length(plan)
    statements = sum(length(d) for d in plan; init = 0)
  catch
    # leave counts at 0; the file is still discarded below
  end

  backup_path = nothing
  if backup
    backup_path = pending_path * ".discarded"
    mv(pending_path, backup_path; force = true)
  else
    rm(pending_path)
  end

  @info("\e[33mDiscarded pending migration ($(tables) table(s), $(statements) statement(s)).\e[0m" *
        (backup ? " Backup saved to $(backup_path)." : ""))
  return (discarded = true, path = pending_path, backup = backup_path, tables = tables, statements = statements)
end

function discard_pending_migration(db::String; config::Dict{String,SQLConn} = config, backup::Bool = true)
  settings = config[db]
  discard_pending_migration(settings; backup = backup)
end
