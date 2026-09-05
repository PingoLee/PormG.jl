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
    MIGRATION_FORMAT_VERSION

Version of PormG's frozen migration **format contract** — the on-disk migration-file layout, the
checksum algorithm, and the `pormg_migrations` tracking-table schema. Every record this engine
writes is stamped with this value (the `format_version` column), and generated migration files
carry it as a `# pormg-migration-format: N` header. It is the single source of truth referenced
wherever the format version is written.

`1` is the contract documented under *Migrations → Format Stability*. Bump this only alongside a
documented forward-migration path; never repurpose an existing version number.
"""
const MIGRATION_FORMAT_VERSION = 1

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

# ==============================================================================
# Migration confirmation gate (destructive guard + interactive prompt)
# ==============================================================================

"""
    DestructiveMigrationError(msg, statements)

Raised when a migration containing destructive operations (DROP TABLE, DROP COLUMN, …) is applied in a
**non-interactive** context (no TTY, or `interactive=false`) without `destructive=true`. Failing loudly
here means CI, `Pkg.test`, and deploy scripts break with an actionable message instead of hanging on
`readline()` or silently skipping the migration.

Reparented from `Exception` to `MigrationError <: PormGError` (#239). Catching
`DestructiveMigrationError` specifically is unaffected; it is merely ALSO catchable as
`MigrationError` / `PormGError`. It keeps its own `showerror` (a more specific method wins).
"""
struct DestructiveMigrationError <: MigrationError
  msg::String
  statements::Vector{String}
end

function Base.showerror(io::IO, e::DestructiveMigrationError)
  print(io, "DestructiveMigrationError: ", e.msg)
  for s in e.statements
    print(io, "\n  → ", length(s) > 120 ? first(s, 120) * "..." : s)
  end
end

"""
    _confirm_migration(has_destructive, destructive, destructive_stmts; interactive) -> Bool

Resolve the destructive guard and interactive confirmation for `migrate`. A prompt is only possible on a
real terminal, so `can_prompt = interactive && (stdin isa Base.TTY)` — this is what keeps `migrate()` from
ever blocking on `readline()` in CI, `Pkg.test`, or a deploy script (even when `interactive=true`, the
default).

Returns `true` to proceed, `false` to abort quietly (the caller then `return nothing`). Throws
[`DestructiveMigrationError`](@ref) when a destructive plan is refused in a non-interactive context, so
automation fails loudly instead of hanging or silently skipping.
"""
function _confirm_migration(has_destructive::Bool, destructive::Bool,
                            destructive_stmts::Vector{String}; interactive::Bool)::Bool
  can_prompt = interactive && (stdin isa Base.TTY)

  # Destructive guard: a destructive plan requires an explicit `destructive=true` opt-in.
  if has_destructive && !destructive
    msg = "Migration contains $(length(destructive_stmts)) destructive operation(s). " *
          "Pass `destructive=true` to confirm."
    # Non-interactive (CI / no TTY / interactive=false): fail loudly so automation cannot
    # silently skip — and never reach the blocking readline() below.
    can_prompt || throw(DestructiveMigrationError(msg, destructive_stmts))
    @error(_emsg("\e[31m$msg\e[0m"))
    for s in destructive_stmts
      display_s = length(s) > 120 ? first(s, 120) * "..." : s
      @error("  → $display_s")
    end
    return false
  end

  # Interactive confirmation — only when a human can actually answer (real TTY).
  if can_prompt
    if has_destructive
      @info(_emsg("\e[31m⚠ This migration contains DESTRUCTIVE operations (DROP TABLE, DROP COLUMN, etc.).\e[0m"))
    end
    @info(_emsg("\e[33mBefore applying the migrations, make sure to back up your database.\e[0m"))
    print(_emsg("\e[31mAre you sure you want to apply the migrations? (yes/no): \e[0m"))
    response = strip(lowercase(readline()))
    if !(response in ["yes", "y"])
      @info("Migrations were not applied.")
      return false
    end
  end

  return true
end

# Frozen format-v1 primitive (see test/unit/test_migration_format_v1.jl). Retained for format
# stability, but no longer auto-invoked: `mark_applied` used to call this to *fabricate* a checksum
# when the caller supplied neither `sql_content` nor `checksum`. A fabricated digest can never be
# verified against the real migration, silently defeating drift detection (issue #81), so
# `mark_applied` now refuses that path instead of fabricating.
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
  _ensure_format_version_column(connection)
  nothing
end

function init_migrations(connection::PormGSQLite)
  ddl = Dialect.create_migrations_table(connection)
  fetch(connection, ddl)
  _ensure_format_version_column(connection)
  nothing
end

"""
    _ensure_format_version_column(connection)

Idempotently add the `format_version` column to a `pormg_migrations` table that predates it.

Brand-new tables already include the column via `create_migrations_table`; this only matters for
databases initialized by a pre-`format_version` PormG release, where `CREATE TABLE IF NOT EXISTS`
is a no-op and the column must be added in place. Existing rows backfill to `1` via the column
DEFAULT — they were written under the v1 format contract.

The column is probed first (`migrations_table_info_sql`) so the `ALTER` runs only when genuinely
absent. SQLite *requires* this — re-adding a column is a hard error — and on PostgreSQL it avoids a
routine `NOTICE: column already exists` on every `init_migrations` call (which `migrate`, `status`,
and `mark_applied` all trigger). The PostgreSQL `ALTER` additionally keeps `IF NOT EXISTS` to stay
safe against a concurrent migration adding the column between this probe and the `ALTER`.
"""
function _ensure_format_version_column(connection::Union{PormGPostgres, PormGSQLite})
  cols = DataFrame(fetch(connection, Dialect.migrations_table_info_sql(connection)))
  has_col = nrow(cols) > 0 && "format_version" in string.(cols.name)
  has_col || fetch(connection, Dialect.add_format_version_column_sql(connection))
  nothing
end

function init_migrations(settings::PormGSettings)
  init_migrations(settings.connections)
end

function init_migrations(db::String; config::Dict{String,PormGSettings} = config)
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
    _latest_applied_checksum(connection) -> Union{String, Nothing}

Return the checksum of the most-recently-applied migration — the `status='applied'` record with
the greatest `version` — or `nothing` when nothing has been applied yet.

Idempotency guard for `migrate()` (issue #81). `migrate()` mints a fresh timestamp `version` on
every run, so re-apply detection must key on migration **content** (the checksum), never the
version. We deliberately compare against the *latest applied* record only, not the full history,
so a legitimate drop-then-re-add — whose regenerated SQL is byte-identical to the original add —
is still applied, while a stale `pending_migrations.jl` left behind by a post-commit archive
failure is recognised as already-applied and skipped instead of being destructively re-run.
"""
function _latest_applied_checksum(connection::Union{PormGPostgres, PormGSQLite})::Union{String, Nothing}
  records = _get_applied_migrations(connection)
  latest = nothing
  for r in records
    # records come back ordered by version ASC, so the last applied row we see is the newest.
    if r[:status] == "applied"
      latest = r
    end
  end
  latest === nothing && return nothing
  return String(latest[:checksum])
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
                           conn = nothing)
  sql = """INSERT INTO pormg_migrations ("version", "name", "checksum", "sql_content", "status", "is_destructive", "format_version")
           VALUES ('$(replace(version, "'" => "''"))', '$(replace(name, "'" => "''"))', '$(replace(checksum, "'" => "''"))',
           '$(replace(sql_content, "'" => "''"))', '$(replace(status, "'" => "''"))', $(is_destr), $(MIGRATION_FORMAT_VERSION));"""
  # Release the connection iff we acquired it here (conn === nothing). When the
  # caller supplies a `conn` it owns the connection (e.g. the migration tx) and
  # frees it itself; without this, the fire-and-forget call sites (mark_applied /
  # mark_failed and the lifecycle failure paths) would acquire a write connection
  # and never return it to the pool on success — a slow pool leak.
  with_transaction(pool, sql, conn=conn, release_conn = conn === nothing)
end

function _record_migration(pool::PormGSQLite, version::String, name::String, checksum::String, 
                           sql_content::String, status::String, is_destr::Bool;
                           conn = nothing)
  is_destr_val = is_destr ? 1 : 0
  sql = """INSERT INTO pormg_migrations ("version", "name", "checksum", "sql_content", "status", "is_destructive", "format_version")
           VALUES ('$(replace(version, "'" => "''"))', '$(replace(name, "'" => "''"))', '$(replace(checksum, "'" => "''"))',
           '$(replace(sql_content, "'" => "''"))', '$(replace(status, "'" => "''"))', $(is_destr_val), $(MIGRATION_FORMAT_VERSION));"""
  # Release the connection iff we acquired it here (conn === nothing). When the
  # caller supplies a `conn` it owns the connection (e.g. the migration tx) and
  # frees it itself; without this, the fire-and-forget call sites (mark_applied /
  # mark_failed and the lifecycle failure paths) would acquire a write connection
  # and never return it to the pool on success — a slow pool leak.
  with_transaction(pool, sql, conn=conn, release_conn = conn === nothing)
end

"""
    _update_migration_status(connection, version, new_status; conn)

Update the status of an existing migration record.
"""
function _update_migration_status(pool::Union{PormGPostgres, PormGSQLite}, version::String, new_status::String; 
                                  conn = nothing)
  sql = """UPDATE pormg_migrations SET "status" = '$(replace(new_status, "'" => "''"))' WHERE "version" = '$(replace(version, "'" => "''"))';"""
  # Release the connection iff we acquired it here (conn === nothing). When the
  # caller supplies a `conn` it owns the connection (e.g. the migration tx) and
  # frees it itself; without this, the fire-and-forget call sites (mark_applied /
  # mark_failed and the lifecycle failure paths) would acquire a write connection
  # and never return it to the pool on success — a slow pool leak.
  with_transaction(pool, sql, conn=conn, release_conn = conn === nothing)
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
    println(io, _emsg(io, "  \e[31mFailed: $(length(s.failed)) migration(s)\e[0m"))
    for m in s.failed
      println(io, "    - v", m[:version], " ", m[:name])
    end
  end
  println(io, "  Pending file: ", _emsg(io, s.pending ? "\e[33myes (review and run migrate)\e[0m" : "none"))
  if !isempty(s.drift_signals)
    println(io, _emsg(io, "  \e[33mDrift signals:\e[0m"))
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
function status(connection::Union{PormGPostgres, PormGSQLite}, settings::PormGSettings)::MigrationStatus
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

function status(settings::PormGSettings)::MigrationStatus
  status(settings.connections, settings)
end

function status(db::String; config::Dict{String,PormGSettings} = config)::MigrationStatus
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
function _load_migration_plan(settings::PormGSettings)
  pending_path = joinpath(settings.db_def_folder, "migrations", "pending_migrations.jl")
  if !isfile(pending_path)
    throw(InvalidMigrationError("No pending migrations found at: $pending_path"))
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
  index_execution::Vector{String} = []   # #152: field CREATE INDEX runs AFTER same-table rebuilds

  for dict_instructs in migration_plan
    for (key, value) in dict_instructs
      if key == "New model"
        push!(first_execution, value)
      elseif key == "Drop table"
        push!(second_execution, value)
      elseif contains(key, "Rename field")
        push!(third_execution, value)
      elseif startswith(key, "Create index")
        # #152: a newly-added db_index field's CREATE INDEX must run AFTER any same-table rebuild. An
        # SQLite "Alter table:" rebuild DROP TABLEs the table (dropping every secondary index) and only
        # re-creates indexes snapshotted from the LIVE schema at planning time — which excludes an index
        # queued in the SAME migration, so a fresh index would be dropped and never re-created. Deferring
        # every field CREATE INDEX to the end lands it on the rebuilt table. Safe: a CREATE INDEX only
        # needs its table to exist. Matches "Create index on <field>" and, since #347, the model-level
        # "Create index: <name>" composite step — both for the same reason. "Remove index …" (different
        # prefix), "Create unique constraint: …" and the m2m "Create many-to-many unique index"
        # (separate join table) are excluded.
        push!(index_execution, value)
      else
        push!(last_execution, value)
      end
    end
  end

  ordered = vcat(first_execution, second_execution, third_execution, last_execution, index_execution)
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
    println(io, _emsg(io, "  \e[31m⚠ DESTRUCTIVE: $(length(r.destructive_statements)) destructive statement(s)\e[0m"))
    for s in r.destructive_statements
      # Show first 120 chars of each destructive statement
      display_s = length(s) > 120 ? s[1:120] * "..." : s
      println(io, "    → ", display_s)
    end
  else
    println(io, _emsg(io, "  \e[32m✓ Safe (no destructive operations)\e[0m"))
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
function dry_run(connection::Union{PormGPostgres, PormGSQLite}, settings::PormGSettings)::DryRunResult
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

function dry_run(settings::PormGSettings)::DryRunResult
  dry_run(settings.connections, settings)
end

function dry_run(db::String; config::Dict{String,PormGSettings} = config)::DryRunResult
  settings = config[db]
  dry_run(settings)
end

# ==============================================================================
# Schema Check API (#475)
# ==============================================================================

"""
    SchemaCheckFinding

One fact about the live database that PormG's models cannot faithfully express, as reported by
[`check`](@ref).

  * `kind` — the finding class. `:expression_default` today.
  * `table` — the live table name.
  * `columns` — the live column name(s). One entry for a column finding; a vector because the
    finding classes still to come are not all per-column (a composite foreign key names several).
  * `detail` — the schema text the finding is about, verbatim: for `:expression_default`, the
    `DEFAULT` expression as the database renders it.
  * `message` — a one-line explanation of the consequence.
"""
struct SchemaCheckFinding
  kind::Symbol
  table::String
  columns::Vector{String}
  detail::String
  message::String
end

"""
    SchemaCheckResult

Structured result from [`check`](@ref): the backend that was read (`:postgres` or `:sqlite`) and
the [`SchemaCheckFinding`](@ref)s, ordered by kind, then table, then column so two runs against the
same schema render identically.

`isempty(result)` is true when the models can express everything the schema contains.
"""
struct SchemaCheckResult
  backend::Symbol
  findings::Vector{SchemaCheckFinding}
end

Base.isempty(r::SchemaCheckResult) = isempty(r.findings)

const _EXPRESSION_DEFAULT_MESSAGE =
  "the DEFAULT is a SQL expression; the column imports without it and your model must declare no `default=`"

function Base.show(io::IO, r::SchemaCheckResult)
  println(io, "Schema Check (", r.backend, "):")
  if isempty(r.findings)
    println(io, _emsg(io, "  \e[32m✓ no findings — the models can express this schema\e[0m"))
    return
  end
  println(io, "  ", length(r.findings), " finding(s)")
  for kind in unique(f.kind for f in r.findings)
    group = filter(f -> f.kind === kind, r.findings)
    println(io, _emsg(io, "\n  \e[33m$(kind)\e[0m ($(length(group)))"))
    for f in group
      println(io, "    ⚠ ", f.table, ".", join(f.columns, ","), "  DEFAULT ", f.detail)
    end
    println(io, "      ", first(group).message)
  end
end

# Does this column land on a reader arm that IGNORES the column's DEFAULT entirely?
#
# Exactly one arm does: the bare-`IDField` primary-key fallback. Both readers order their key arms
# identically and document that lockstep as a cross-engine contract — uuid key, then relation, then
# sized textual key, then the `IDField` fallback (#409/#417) — so a primary key that is none of the
# first three reaches an `IDField` built with no `default=` at all. Nothing is dropped there and
# nothing is warned, so a finding would be `check` inventing work the importer never reported.
#
# WHY THIS IS THE RIGHT SUPPRESSION, stated precisely, because the obvious reason is wrong:
# `IDField(auto_increment=true)` does NOT "express" a `serial` column's `nextval(…)` on PostgreSQL.
# The reader never passes `auto_increment` there, `sIDField.type` is hard-coded `BIGINT`, and a
# legacy `serial` key reads back `generated=false` — which is why `makemigrations` proposes
# `ADD GENERATED BY DEFAULT AS IDENTITY` for one (UPGRADING.md, #438). The reason is narrower and
# actionable-shaped instead: `sIDField.default` is `Union{Int64, Nothing}`, so a user CANNOT declare
# the expression there and has nothing to remove. `check`'s one finding class says "your model must
# declare no `default=` on this column" — advice that is already true by construction for every
# `IDField`, and so is noise rather than a finding. The `serial` mismatch is real but it is a
# different report, and `makemigrations` already surfaces it.
#
# Erring toward REPORTING is deliberate wherever this is unsure: `check` being silent about a column
# the importer really did drop is the dangerous direction, and being noisy is merely annoying.
#
# This mirrors reader logic and can therefore drift from it. The agreement assertions in
# `test/unit/test_migrations_check.jl` and in `test/integration/test_importers_introspection.jl`
# (section 6b) compare `check`'s findings against the importer's warnings on one database, which is
# what catches that drift.
function _pg_key_arm_ignores_default(col, pk_set::Set{String}, fk_cols::Set{String},
                                     type_map::Dict{String, Symbol})::Bool
  col_name = String(col["name"])
  col_name in pk_set || return false          # not a key: the generic arm reads the default
  col_name in fk_cols && return false         # relation arm — `_fk_default_or_warn` reads it
  base, modifier = _pg_split_format_type(String(get(col, "type", "")), type_map)
  base == "uuid" && return false              # uuid key arm — `_field_or_drop_default` reads it
  # sized textual key arm; a LENGTHLESS one falls through to `IDField`, exactly as the reader does
  (base == "varchar" && modifier !== nothing && tryparse(Int, strip(modifier)) !== nothing) &&
    return false
  return true
end

# The SQLite twin. Same four arms in the same order, read from `PRAGMA table_info`
# (`pk > 0` marks a key member) and `PRAGMA foreign_key_list` (`from` names the child column).
function _sqlite_key_arm_ignores_default(col_name::String, col_type::String, is_pk::Bool,
                                         fk_cols::Set{String})::Bool
  is_pk || return false
  col_name in fk_cols && return false
  base_type = uppercase(String(strip(first(split(col_type, '(')))))
  base_type == "UUID" && return false
  (base_type in ("TEXT", "VARCHAR", "CHAR") && occursin("(", col_type)) && return false
  return true
end

# The `:expression_default` findings in a PostgreSQL schema dump.
#
# Pure over the frame `get_database_schema(::PormGPostgres)` returns, so the whole PostgreSQL arm is
# unit-testable against a synthetic `DataFrame` with no live database — the same trick the reader's
# own tests play with `_introspection_row`.
function _pg_expression_default_findings(schemas::AbstractDataFrame;
                                         ignore_table::Vector{String})::Vector{SchemaCheckFinding}
  findings = SchemaCheckFinding[]
  for row in eachrow(schemas)
    _is_ignored_table(row.table_name, ignore_table) && continue
    pk_set = Set{String}(String.(something(_pg_json(row, :primary_keys), Any[])))
    fk_cols = Set{String}(String(fk["column"]) for fk in
                          something(_pg_json(row, :foreign_keys), Any[]))
    for col in something(_pg_json(row, :columns), Any[])
      cleaned = _pg_clean_default(get(col, "default", nothing))
      cleaned isa _ExpressionDefault || continue
      # The bare-`IDField` key arm reads no default, so there is nothing to report — the common
      # case being every `serial`/`bigserial` `id` column in an ordinary schema. See
      # `_pg_key_arm_ignores_default` for why this is a suppression rather than a lie.
      _pg_key_arm_ignores_default(col, pk_set, fk_cols, postgres_type_map) && continue
      push!(findings, SchemaCheckFinding(:expression_default, String(row.table_name),
                                         [String(col["name"])], cleaned.sql,
                                         _EXPRESSION_DEFAULT_MESSAGE))
    end
  end
  return findings
end

# The `:expression_default` findings in a live SQLite database.
#
# `PRAGMA table_info`, NOT `get_database_schema(::PormGSQLite)`: that returns `sqlite_master`'s DDL
# TEXT with no per-column defaults, so using it would put this on the DDL-regex reader that
# `convertSQLToModel(::String)`'s own header declares off the production route. The PRAGMA is the
# source the live reader uses, which is the point — `check` must not be able to disagree with
# `makemigrations` about which columns are affected.
#
# `type_sym` is derived with the plain type-map lookup and deliberately WITHOUT the readers'
# CharField→TextField refinement (#325). `_normalize_sqlite_default` branches on `type_sym` for
# exactly two values, `:BinaryField` and `:BooleanField`; a bare `TEXT` and a `TEXT(120)` take the
# same path through it either way, so replicating the refinement here would add a second copy of a
# rule that cannot change this answer.
function _sqlite_expression_default_findings(db::PormGSQLite;
                                             ignore_table::Vector{String},
                                             include_table::Union{Vector{String}, Nothing} = nothing,
                                             type_map::Dict{String, Symbol} = sqlite_type_map)::Vector{SchemaCheckFinding}
  findings = SchemaCheckFinding[]
  tables = fetch(db, "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%';") |> DataFrame
  for trow in eachrow(tables)
    table_name = String(trow.name)
    if include_table !== nothing
      !any(included -> table_name == included, include_table) && continue
    end
    _is_ignored_table(table_name, ignore_table) && continue

    # Same quoted-identifier interpolation the live reader uses for the PRAGMA calls.
    cols = fetch(db, "PRAGMA table_info(\"$table_name\")") |> DataFrame
    # The reader SKIPS a composite foreign key rather than splitting it into N single-column
    # relations (#415), so such a child column has no `fk_map` entry and falls through to the
    # bare-`IDField` key arm. `fk_cols` has to be filtered the same way or the predicate below
    # would believe a composite-FK key column takes the relation arm. PostgreSQL needs no
    # equivalent: its `foreign_keys` CTE already filters on `array_length(con.conkey, 1) = 1`.
    fks = fetch(db, "PRAGMA foreign_key_list(\"$table_name\")") |> DataFrame
    cols_per_fk = Dict{Any, Int}()
    for r in eachrow(fks)
      cols_per_fk[r.id] = get(cols_per_fk, r.id, 0) + 1
    end
    fk_cols = Set{String}(String(r.from) for r in eachrow(fks) if cols_per_fk[r.id] == 1)
    for crow in eachrow(cols)
      raw = crow.dflt_value
      (raw === nothing || ismissing(raw)) && continue
      col_type = uppercase(String(crow.type))
      # `strip` matches the reader's own derivation (`convertSQLToModel(::PormGSQLite, …)`): a
      # declared `BLOB (4)` would otherwise yield the key `"BLOB "`, miss the type map and fall
      # back to `:TextField` — and `:BinaryField`/`:BooleanField` are the only two values
      # `_normalize_sqlite_default` branches on, so that is exactly where this could disagree with
      # the importer.
      base_type = String(strip(first(split(col_type, '('))))
      type_sym = get(type_map, base_type, :TextField)
      cleaned = _normalize_sqlite_default(raw, type_sym)
      cleaned isa _ExpressionDefault || continue
      # The same bare-`IDField` carve-out as the PostgreSQL arm. SQLite reaches it too: an
      # `INTEGER PRIMARY KEY DEFAULT (abs(random()))` is read as a plain `IDField` with the default
      # ignored and no warning, so reporting it would be a disagreement in the noisy direction.
      _sqlite_key_arm_ignores_default(String(crow.name), String(crow.type),
                                      crow.pk isa Number && crow.pk > 0, fk_cols) && continue
      push!(findings, SchemaCheckFinding(:expression_default, table_name, [String(crow.name)],
                                         cleaned.sql, _EXPRESSION_DEFAULT_MESSAGE))
    end
  end
  return findings
end

_sort_findings(f::Vector{SchemaCheckFinding}) =
  sort(f; by = x -> (String(x.kind), x.table, isempty(x.columns) ? "" : first(x.columns)))

"""
    check(connection, settings; ignore_table = nothing, include_table = nothing) -> SchemaCheckResult
    check(settings; kwargs...) -> SchemaCheckResult
    check(db::String; config = config, kwargs...) -> SchemaCheckResult

Report facts about the live database schema that PormG's models cannot faithfully express.

`ignore_table` replaces the backend's default skip list (`postgres_ignore_table` /
`sqlite_ignore_schema`); tables registered through `register_ignore_tables!` are always skipped on
top of it, so `check` reads exactly the tables the importer does. `include_table` restricts the read
to the named tables. Both match the parameters of `convert_schema_to_models`.

Read-only, on both backends, and independent of `makemigrations` — it needs no models file, no
migration history and no `init_migrations()`. Run it alongside [`status`](@ref) and
[`dry_run`](@ref) in the operator flow, and before upgrading PormG.

Today it reports one class:

  * `:expression_default` — a column whose `DEFAULT` is a SQL expression (`now()`,
    `CURRENT_TIMESTAMP`, `gen_random_uuid()`, `concat(...)`) rather than a literal value. PormG has
    no field-level representation for one, so `inspectdb` and `makemigrations` import the column
    **without** a default and the database keeps its own. Your model must therefore declare **no**
    `default=` on such a column: declaring one that matches the expression's spelling makes
    `makemigrations` propose `SET DEFAULT '<the expression>'`, which replaces the live expression
    with a quoted literal and stores that text in every new row.

A **primary key** that imports as an `IDField` is deliberately not reported — a `serial`/`bigserial`
`id` column, say. Its default is never read by the importer, and `sIDField.default` is
`Union{Int64, Nothing}` — so an *expression* is not something a model could declare there and then
be told to remove, which is the only advice this finding class carries. Reporting it would be
unactionable noise on every table. (That a
pre-existing `serial` key is not byte-identical to what PormG would emit is a separate matter, and
`makemigrations` already proposes the `IDENTITY` alteration for it.) A key that imports as a
`UUIDField`, a `CharField` or a relation IS reported, because those arms really do drop the default.

This is the diagnostic the warnings cannot be. `convert_schema_to_models` warns once per column as
it reads, so the information exists only in the log of a run you have to have made; `check` answers
the question directly, and covers the case that produced no warning at all before #475 — a textual
column, whose expression default was silently kept as a literal.

```julia
julia> PormG.Migrations.check("db_2")
Schema Check (postgres):
  2 finding(s)

  expression_default (2)
    ⚠ lap_note.created_at  DEFAULT now()
    ⚠ lap_note.note  DEFAULT concat('a'::text, 'b'::text)
      the DEFAULT is a SQL expression; the column imports without it and your model must declare no `default=`
```

`settings` is unused by the checks that exist today and is taken for parity with [`status`](@ref)
and [`dry_run`](@ref) — and because the finding classes still to come need it: comparing the live
schema against the declared models requires `settings.db_def_folder`.

See also [`SchemaCheckResult`](@ref), [`SchemaCheckFinding`](@ref).
"""
function check(connection::Union{PormGPostgres, PormGSQLite}, settings::PormGSettings;
               ignore_table::Union{Vector{String}, Nothing} = nothing,
               include_table::Union{Vector{String}, Nothing} = nothing)::SchemaCheckResult
  if connection isa PormGSQLite
    ignore = unique(vcat(something(ignore_table, sqlite_ignore_schema), _EXTRA_IGNORE_TABLES[]))
    findings = _sqlite_expression_default_findings(connection; ignore_table = ignore,
                                                   include_table = include_table)
    return SchemaCheckResult(:sqlite, _sort_findings(findings))
  else
    ignore = unique(vcat(something(ignore_table, postgres_ignore_table), _EXTRA_IGNORE_TABLES[]))
    schemas = get_database_schema(connection)
    if include_table !== nothing
      schemas = filter(r -> any(included -> r.table_name == included, include_table), schemas)
    end
    findings = _pg_expression_default_findings(schemas; ignore_table = ignore)
    return SchemaCheckResult(:postgres, _sort_findings(findings))
  end
end

function check(settings::PormGSettings; kwargs...)::SchemaCheckResult
  check(settings.connections, settings; kwargs...)
end

function check(db::String; config::Dict{String,PormGSettings} = config, kwargs...)::SchemaCheckResult
  settings = config[db]
  check(settings; kwargs...)
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
      if occursin(r"^PRAGMA\s+foreign_key_check"i, trimmed)
        # #82: gate emitted by the SQLite table-rebuild. foreign_key_check returns one row per orphaned
        # FK reference; any rows mean the rebuild left dangling children, so abort — the surrounding
        # catch rolls the whole migration back. (PRAGMA foreign_key_check works inside a transaction,
        # unlike PRAGMA foreign_keys.)
        result, _ = with_transaction(connection, trimmed, conn=conn)
        violations = DataFrame(result)
        if nrow(violations) > 0
          throw(InvalidMigrationError("Migration aborted: PRAGMA foreign_key_check found $(nrow(violations)) orphaned foreign-key row(s) after a SQLite table rebuild; rolling back."))
        end
      else
        with_transaction(connection, trimmed, conn=conn)
      end
    end
  end
end

"""
    _archive_migration_files(settings, date_str) -> Nothing

Move pending_migrations.jl to applied_migrations/ and snapshot the models file.
"""
function _archive_migration_files(settings::PormGSettings, date_str::String)
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
    migrate(connection::PormGBackend, settings; interactive, destructive, dry_run_only, name)

Apply pending migrations to a database (PostgreSQL or SQLite). This is the shared pre-flight for every
backend; the backend-specific execution step is dispatched to `_run_locked_lifecycle` (advisory lock on
PostgreSQL, direct on SQLite).

# Lifecycle
1. Validate: check change_db, install configured extensions, load plan, detect destructive ops
2. Confirm: destructive guard + interactive confirmation (TTY-aware — see `_confirm_migration`)
3. Execute: run SQL in a transaction (under an advisory lock on PostgreSQL)
4. Record: insert history into pormg_migrations
5. Archive: move files to applied_migrations/

# Keywords
- `interactive::Bool=true`: prompt for confirmation before applying — **only when stdin is a real
  terminal**. In a non-interactive process (CI, `Pkg.test`, deploy script) no prompt is shown and
  `migrate()` never blocks on `readline()`.
- `destructive::Bool=false`: must be `true` to allow DROP TABLE / DROP COLUMN operations. A destructive
  plan in a non-interactive context throws `DestructiveMigrationError` unless this is set.
- `dry_run_only::Bool=false`: if `true`, only analyze without applying (returns DryRunResult)
- `name::String="pending_migration"`: name for this migration in the history table
"""
function migrate(connection::PormGBackend, settings::PormGSettings;
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
    @info(_emsg("\e[32mNo SQL statements to execute.\e[0m"))
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
  
  # Destructive guard + interactive confirmation.
  # TTY-aware: never blocks on readline() without a terminal, and throws in the non-interactive
  # destructive case so automation fails loudly (see `_confirm_migration`).
  _confirm_migration(has_destructive, destructive, destructive_stmts; interactive=interactive) || return nothing

  # --- Phase 2: Execute (backend-specific: advisory lock on PostgreSQL, direct on SQLite) ---
  _run_locked_lifecycle(connection, settings, ordered_statements, all_sql,
                        version, name, checksum, has_destructive)
end

# ==============================================================================
# Backend-specific execution wrapper. PostgreSQL serializes migrations with an advisory
# lock; SQLite is single-instance only (no lock). `_execute_migration_lifecycle` is itself
# already dialect-dispatched — this hook only decides whether to wrap it in a lock.
# ==============================================================================

function _run_locked_lifecycle(connection::PormGPostgres, settings::PormGSettings,
                               ordered_statements, all_sql, version, name, checksum, has_destructive)
  lock_key = "pormg_migrations_$(settings.db_def_folder)"
  AdvisoryLock.with_advisory_lock(connection, lock_key; wait=true, timeout_ms=30_000) do
    _execute_migration_lifecycle(connection, settings, ordered_statements, all_sql,
                                 version, name, checksum, has_destructive)
  end
end

function _run_locked_lifecycle(connection::PormGSQLite, settings::PormGSettings,
                               ordered_statements, all_sql, version, name, checksum, has_destructive)
  _execute_migration_lifecycle(connection, settings, ordered_statements, all_sql,
                               version, name, checksum, has_destructive)
end

# ==============================================================================
# Shared execution lifecycle (called within lock for PostgreSQL)
# ==============================================================================

function _execute_migration_lifecycle(connection::PormGPostgres, settings::PormGSettings,
                                      ordered_statements::Vector{String}, all_sql::String,
                                      version::String, name::String, checksum::String,
                                      has_destructive::Bool)
  date_str = Dates.format(Dates.now(), "yyyy-mm-dd_HH-MM-SS")

  # Idempotency guard (issue #81). Runs inside the advisory lock, so the check-and-skip is
  # serialized against any concurrent migrator. If the pending plan's checksum matches the latest
  # applied migration, this is a re-run over a `pending_migrations.jl` that a previous apply
  # COMMITted but then failed to archive — re-executing non-idempotent DDL (a plain ADD COLUMN /
  # ADD CONSTRAINT / CREATE INDEX) would error and leave a spurious `failed` row. Skip the DDL and
  # retry the archive so the stale pending file finally clears.
  if _latest_applied_checksum(connection) == checksum
    @info(_emsg("\e[32mMigration already applied (checksum match) — skipping re-apply.\e[0m"))
    try
      _archive_migration_files(settings, date_str)
    catch e
      @error "Error archiving already-applied migration files" exception=e
    end
    return nothing
  end

  # Begin transaction
  _, conn = with_transaction(connection, "BEGIN;")
  # Release/renew the transaction connection exactly once, in a single terminal finally, so a
  # failed COMMIT never returns it to the pool before the cleanup ROLLBACK has run on it (#139).
  local rollback_error = nothing

  try
    # Execute all SQL statements
    _execute_statements_pg(connection, ordered_statements; conn=conn)

    # Record in history table (within same transaction)
    _record_migration(connection, version, name, checksum, all_sql, "applied", has_destructive; conn=conn)

    # Commit — release_conn=false: the finally owns the single release.
    with_transaction(connection, "COMMIT;", conn=conn, release_conn=false)
    @info(_emsg("\e[32mMigrations applied successfully. Version: $version\e[0m"))
  catch e
    # Roll back on the still-leased connection. A rollback failure must not mask the body's
    # error — capture it so the finally renews/discards the (now-dirty) connection instead of
    # releasing it (#71), then rethrow the original.
    try
      with_transaction(connection, "ROLLBACK;", conn=conn, release_conn=false)
    catch rollback_err
      rollback_error = rollback_err
      @error "Failed to rollback transaction" exception=rollback_err
    end

    # Record failed status outside the (now rolled-back) transaction. Reuse the transaction's
    # own connection (conn=conn) rather than acquiring a fresh one: it is still leased until the
    # finally, and SQLite's single writer slot would otherwise deadlock this write. Trade-off: if
    # the ROLLBACK above ALSO failed, `conn` is dirty/aborted and this INSERT fails too (logged and
    # skipped, then the finally renews the connection) — so in that rare double-failure the `failed`
    # row is not recorded; the error is still logged and rethrown.
    try
      _record_migration(connection, version, name, checksum, all_sql, "failed", has_destructive; conn=conn)
    catch record_err
      @error "Failed to record migration failure in history table" exception=record_err
    end

    @error "Error applying migrations" exception=e
    rethrow(e)
  finally
    finalize_transaction_connection!(connection, conn; rollback_error=rollback_error)
  end

  # Archive files (post-commit, best-effort)
  try
    _archive_migration_files(settings, date_str)
  catch e
    @error "Error archiving migration files (migration was applied successfully)" exception=e
  end
end

function _execute_migration_lifecycle(connection::PormGSQLite, settings::PormGSettings,
                                      ordered_statements::Vector{String}, all_sql::String,
                                      version::String, name::String, checksum::String,
                                      has_destructive::Bool)
  date_str = Dates.format(Dates.now(), "yyyy-mm-dd_HH-MM-SS")

  # Idempotency guard (issue #81) — see the PostgreSQL lifecycle for the full rationale. If the
  # pending plan's checksum matches the latest applied migration, this is a re-run over a
  # `pending_migrations.jl` a previous apply COMMITted but failed to archive; re-executing
  # non-idempotent DDL would error. Skip and retry the archive so the stale pending file clears.
  if _latest_applied_checksum(connection) == checksum
    @info(_emsg("\e[32mMigration already applied (checksum match) — skipping re-apply.\e[0m"))
    try
      _archive_migration_files(settings, date_str)
    catch e
      @error "Error archiving already-applied migration files" exception=e
    end
    return nothing
  end

  # Serialize the whole BEGIN..COMMIT against any concurrent SQLite writer, like
  # run_in_transaction/delete(). Migrations normally run sequentially at startup,
  # but if one is applied while app writes are in flight, two un-serialized
  # `BEGIN IMMEDIATE`s would race and deadlock the single async worker. No-op on
  # PostgreSQL. See ConnectionPool.with_sqlite_write_lock.
  with_sqlite_write_lock(connection) do
    # #276: acquire EXPLICITLY rather than letting `with_transaction` acquire at BEGIN. SQLite
    # ignores `PRAGMA foreign_keys` inside a transaction — silently, returning success — so
    # enforcement has to be suspended on this exact handle BEFORE the BEGIN. Acquired inside the
    # write lock to keep the lock→slot order `run_in_transaction` uses; the reverse order deadlocks
    # against it under split_read_write, where there is exactly one writer slot.
    conn = acquire_connection(connection; mode = :write)
    # Single terminal finally releases/renews the connection exactly once, so a failed COMMIT
    # never returns it to the pool before the cleanup ROLLBACK has run on it (#139).
    local rollback_error = nothing

    try
      # #276: the SQLite table-rebuild drops the old table, and with enforcement on that implicit
      # DELETE fires child ON DELETE actions — a CASCADE child's rows are deleted, the parent is
      # renamed back, and the migration COMMITs. The per-table `PRAGMA foreign_key_check` gate
      # cannot see it (after a cascade there are no orphans left, only missing children). This is
      # step 1 of SQLite's own documented ALTER procedure. `foreign_key_check` still works while
      # suspended, so the #82 gate keeps its full detection power.
      with_transaction(connection, "PRAGMA foreign_keys = OFF;", conn=conn)
      _assert_foreign_keys_suspended(connection, conn)

      # Begin transaction (IMMEDIATE for SQLite)
      with_transaction(connection, "BEGIN IMMEDIATE TRANSACTION;", conn=conn)

      # Inner try scoped to "a transaction is actually open" (#276). Kept separate from the outer
      # one on purpose: folding them together would make a failed PRAGMA or BEGIN run the ROLLBACK
      # and write a spurious `failed` history row for a transaction that never started.
      try
        # Execute all SQL statements
        _execute_statements_sqlite(connection, ordered_statements; conn=conn)

        # Record in history table (within same transaction)
        _record_migration(connection, version, name, checksum, all_sql, "applied", has_destructive; conn=conn)

        # Commit — release_conn=false: the finally owns the single release.
        with_transaction(connection, "COMMIT;", conn=conn, release_conn=false)
        @info(_emsg("\e[32mMigrations applied successfully. Version: $version\e[0m"))
      catch e
        # Roll back on the still-leased connection; capture a rollback failure so the finally
        # renews/discards the dirty connection instead of releasing it (#71), then rethrow.
        try
          with_transaction(connection, "ROLLBACK;", conn=conn, release_conn=false)
        catch rollback_err
          rollback_error = rollback_err
          @error "Failed to rollback transaction" exception=rollback_err
        end

        # Record failed status outside the (now rolled-back) transaction, reusing the transaction's
        # own connection (conn=conn): it is still leased until the finally, and acquiring a fresh
        # writer would deadlock on SQLite's single writer slot. Trade-off: if the ROLLBACK above also
        # failed, `conn` is dirty and this INSERT fails too (logged and skipped, then the finally
        # renews it) — so the `failed` row is not recorded in that rare double-failure.
        try
          _record_migration(connection, version, name, checksum, all_sql, "failed", has_destructive; conn=conn)
        catch record_err
          @error "Failed to record migration failure in history table" exception=record_err
        end

        @error "Error applying migrations" exception=e
        rethrow(e)
      end
    finally
      # renew=true (#276): this handle has FK enforcement OFF and must never go back to the pool as
      # it stands. Renewal re-runs the connect path, which sets the pragma back ON by construction;
      # the suspended handle is closed, so it cannot reach another borrower. A `PRAGMA foreign_keys
      # = ON` here would be unsound — it is silently ignored if a transaction is still open.
      #
      # `rollback_error` is now redundant here (renew=true already short-circuits the helper's
      # classification) — kept deliberately so this call still reads the same as its PG twin and the
      # delete lifecycle, and stays correct if renew ever becomes conditional.
      finalize_transaction_connection!(connection, conn; rollback_error=rollback_error, renew=true)
    end
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

function migrate(db::String; config::Dict{String,PormGSettings} = config, interactive::Bool = true,
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
function migrate_to(connection::Union{PormGPostgres, PormGSQLite}, settings::PormGSettings, 
                    target_version::String; interactive::Bool = true, destructive::Bool = false)
  init_migrations(connection)
  
  applied = _get_applied_migrations(connection)
  for m in applied
    if m[:version] == target_version
      @info("Version $target_version is already applied.")
      return nothing
    end
  end

  throw(InvalidMigrationError("migrate_to(version) is not implemented for the current single pending_migrations.jl workflow. Generate and apply the pending plan with migrate(), or implement ordered multi-file migration queues first."))
end

function migrate_to(db::String, target_version::String; config::Dict{String,PormGSettings} = config, 
                    interactive::Bool = true, destructive::Bool = false)
  settings = config[db]
  migrate_to(settings.connections, settings, target_version; interactive=interactive, destructive=destructive)
end

# ==============================================================================
# Repair Operations
# ==============================================================================

"""
    _resolve_mark_checksum(checksum, sql_content) -> String

Resolve the checksum `mark_applied` will record, or throw if the caller gave nothing to base it on.

Guardrail for issue #81: a manually-reconciled migration must carry a *verifiable* checksum. When
the caller supplies `sql_content` we hash it; when they supply an explicit `checksum` we trust it;
when they supply neither we refuse rather than fabricate one, because a made-up digest can never be
verified against the real migration and would silently defeat drift detection. Pure/DB-free so it
can be unit-tested directly.
"""
function _resolve_mark_checksum(checksum::String, sql_content::String)::String
  if isempty(checksum) && isempty(sql_content)
    throw(InvalidMigrationError(
      "mark_applied requires the migration's `sql_content` (preferred — the checksum is then " *
      "computed from, and verifiable against, the real SQL) or an explicit `checksum`. Refusing " *
      "to fabricate one: a made-up checksum can never be verified and silently defeats drift " *
      "detection (issue #81)."))
  end
  return isempty(checksum) ? compute_checksum(sql_content) : checksum
end

"""
    mark_applied(connection, settings, version, name; checksum, sql_content)

Manually mark a migration version as applied in the history table.
Useful for reconciliation after manual intervention or interrupted migrations.

Requires either `sql_content` (preferred) or an explicit `checksum` so the recorded digest is
verifiable — passing neither is refused rather than fabricated (issue #81). Destructiveness is
classified from `sql_content` when provided instead of being hard-coded, so a manually-reconciled
destructive migration is still flagged in history.
"""
function mark_applied(connection::Union{PormGPostgres, PormGSQLite}, settings::PormGSettings,
                      version::String, name::String;
                      checksum::String = "", sql_content::String = "")
  # Validate arguments before touching the DB so a bad call is a pure ArgumentError.
  checksum = _resolve_mark_checksum(checksum, sql_content)
  init_migrations(connection)

  destr = !isempty(sql_content) && is_destructive(sql_content)
  _record_migration(connection, version, name, checksum, sql_content, "applied", destr)
  @info("Marked version $version as applied.")
end

function mark_applied(db::String, version::String, name::String; config::Dict{String,PormGSettings} = config, kwargs...)
  settings = config[db]
  mark_applied(settings.connections, settings, version, name; kwargs...)
end

"""
    mark_failed(connection, settings, version)

Update an existing migration record to 'failed' status.
Useful after manual investigation of a partially-applied migration.
"""
function mark_failed(connection::Union{PormGPostgres, PormGSQLite}, settings::PormGSettings,
                     version::String)
  init_migrations(connection)
  _update_migration_status(connection, version, "failed")
  @info("Marked version $version as failed.")
end

function mark_failed(db::String, version::String; config::Dict{String,PormGSettings} = config)
  settings = config[db]
  mark_failed(settings.connections, settings, version)
end

"""
    remove_migration_record(connection, settings, version)

Remove a migration record from the history table entirely.
Use with caution — this erases history. Intended for cleanup after
manual rollbacks or test scenarios.
"""
function remove_migration_record(connection::Union{PormGPostgres, PormGSQLite}, settings::PormGSettings,
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

function remove_migration_record(db::String, version::String; config::Dict{String,PormGSettings} = config)
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
function discard_pending_migration(settings::PormGSettings; backup::Bool = true)
  pending_path = joinpath(settings.db_def_folder, "migrations", "pending_migrations.jl")
  if !isfile(pending_path)
    @info(_emsg("\e[32mNo pending migration to discard.\e[0m"))
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

  @info(_emsg("\e[33mDiscarded pending migration ($(tables) table(s), $(statements) statement(s)).\e[0m" *
        (backup ? " Backup saved to $(backup_path)." : "")))
  return (discarded = true, path = pending_path, backup = backup_path, tables = tables, statements = statements)
end

function discard_pending_migration(db::String; config::Dict{String,PormGSettings} = config, backup::Bool = true)
  settings = config[db]
  discard_pending_migration(settings; backup = backup)
end
