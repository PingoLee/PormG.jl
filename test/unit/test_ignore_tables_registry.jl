"""
Unit coverage for the consumer-extensible ignore-table registry
(`register_ignore_tables!` + its effect on `convert_schema_to_models`).

A downstream framework (e.g. Nitro) registers its OWN infrastructure tables so PormG's
introspection / makemigrations skips them, instead of those app-specific names being
hardcoded into the ORM's `postgres_ignore_table`. This pins:
  - the registry is additive and deduplicated,
  - registered tables are skipped by `convert_schema_to_models` on top of the caller's list.

The introspection check uses a hermetic temp SQLite DB. The process-global registry is
saved and restored so the test never leaks state into other suites.
"""

using Test
using PormG
using DataFrames
# The testsets open real (temporary) SQLite files, so they need the weakdep extension. `runtests.jl`
# loads it for the whole suite; this guard is what makes the file runnable alone.
isdefined(Main, :SQLite) || include(joinpath(@__DIR__, "..", "load_drivers.jl"))
import PormG.ConnectionPool: SQLiteConnectionPool, fetch
import PormG.Migrations: convert_schema_to_models

@testset "register_ignore_tables! registry" begin
  saved = copy(PormG._EXTRA_IGNORE_TABLES[])
  try
    PormG._EXTRA_IGNORE_TABLES[] = String[]   # deterministic clean slate

    # ── 1. Registry is additive and deduplicated ───────────────────────────
    PormG.register_ignore_tables!(["nitro_task", "nitro_session"])
    @test "nitro_task" in PormG._EXTRA_IGNORE_TABLES[]
    @test "nitro_session" in PormG._EXTRA_IGNORE_TABLES[]
    PormG.register_ignore_tables!(["nitro_task"])               # re-register → no duplicate
    @test count(==("nitro_task"), PormG._EXTRA_IGNORE_TABLES[]) == 1

    # ── 2. Introspection skips registered tables (hermetic temp SQLite) ─────
    mktempdir() do dir
      pool = SQLiteConnectionPool(joinpath(dir, "ig.sqlite"); pool_size = 1)
      try
        fetch(pool, "CREATE TABLE keep_me (id INTEGER PRIMARY KEY, n INTEGER);")
        fetch(pool, "CREATE TABLE nitro_task (id TEXT PRIMARY KEY, status TEXT);")
        fetch(pool, "CREATE TABLE nitro_session (session_key TEXT PRIMARY KEY, data TEXT);")

        models = convert_schema_to_models(pool)   # sqlite default ignore list ∪ registry
        names = Set(lowercase(string(m.name)) for m in models)

        @test "keep_me" in names            # ordinary user table is imported
        @test !("nitro_task" in names)      # registered → skipped
        @test !("nitro_session" in names)   # registered → skipped
      finally
        # Release the SQLite handle so mktempdir can delete the temp DB on Windows (WAL keeps it open).
        PormG.ConnectionPool.close_pool!(pool)
      end
    end
  finally
    PormG._EXTRA_IGNORE_TABLES[] = saved   # never leak registry state into other suites
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# #325: the ignore list matches a PREFIX, and matches the same way on both backends
#
# Every entry is either a framework prefix (`"django_"`, `"auth_"`, `"sqlite_autoindex"`) or a whole
# table name (`"pormg_migrations"`) — a prefix test covers both. The backends used to disagree, and
# each was wrong in its own direction:
#
#   * PostgreSQL used `occursin`, so a user table merely CONTAINING an entry vanished from the live
#     schema. A dropped table does not read as "ignored" downstream, it reads as "does not exist" —
#     so `makemigrations` proposed `CREATE TABLE` for it on every single run, which is the same
#     never-converging churn #325 is about. `company_admin_log` and `oauth_tokens` are the shapes
#     that actually bite; both are ordinary user tables.
#   * SQLite used `==`, so `"sqlite_autoindex"` — only ever a prefix of `sqlite_autoindex_<t>_<n>`,
#     never a table name — could not match anything.
#
# Pure predicate, no database.
# ─────────────────────────────────────────────────────────────────────────────
@testset "ignore-list matching is prefix-based on both backends (#325)" begin
  import PormG.Migrations: _is_ignored_table

  pg = PormG.postgres_ignore_table

  # Genuine framework tables are still skipped — the whole point of the list.
  @test _is_ignored_table("django_migrations", pg)
  @test _is_ignored_table("django_content_type", pg)
  @test _is_ignored_table("auth_user", pg)
  @test _is_ignored_table("celery_taskmeta", pg)
  @test _is_ignored_table("pormg_migrations", pg)

  # THE mutation gate: user tables that merely CONTAIN an entry are no longer swallowed.
  @test !_is_ignored_table("company_admin_log", pg)      # contains "admin_"
  @test !_is_ignored_table("oauth_tokens", pg)           # contains "auth_"
  @test !_is_ignored_table("contract_django_scratch", pg)  # contains "django_" — the #325 fixture
  @test !_is_ignored_table("my_social_graph", pg)        # contains "social_"

  # A table that genuinely starts with a framework prefix is STILL skipped, so the fix did not
  # simply turn the list off. This is why the integration fixture had to be renamed rather than the
  # list edited — ignoring `django_*` is correct behavior.
  @test _is_ignored_table("django_contract_scratch", pg)

  # SQLite side: `sqlite_autoindex` is a prefix and never a table name, so `==` could not match it.
  sl = PormG.sqlite_ignore_schema
  @test _is_ignored_table("sqlite_sequence", sl)
  @test _is_ignored_table("sqlite_autoindex_drivers_1", sl)   # ← impossible under `==`
  @test _is_ignored_table("pormg_migrations", sl)
  @test !_is_ignored_table("drivers", sl)
end

# ═════════════════════════════════════════════════════════════════════════════
# #749: the per-connection `ignore_tables:` list (connection.yml)
#
# The registry above is process-wide. `ignore_tables:` scopes the same prefix list to ONE connection,
# for an app that drives two databases — say the F1 primary next to a replica that also carries a
# legacy timing feed. Every fixture below is two temporary SQLite projects holding the same tables;
# only connection A lists `legacy_timing_`, so every assertion is paired with connection B doing the
# opposite. Without the pairing, "A skipped it" would pass for a list applied to every connection.
# ═════════════════════════════════════════════════════════════════════════════
using Logging
import PormG: Configuration, Migrations
import PormG.ConnectionPool: close_pool!

_ig749_quiet(f) = with_logger(f, NullLogger())

# A models file declaring one F1 table, plus whatever `extra` source a testset adds.
_ig749_write_models(path; extra = "") =
  write(path, "module models\nimport PormG.Models\n" *
              "Circuit749 = Models.Model(\n    id = Models.IDField(),\n    name = Models.CharField(null = true)\n)\n" *
              extra * "end\n")

# One temporary SQLite project: the models are planned and applied, then the database gains a table
# the models never declare — an external feed PormG must leave alone. `ignores` is the connection's
# `ignore_tables:` value, set on `db_config_settings` exactly as `load` would leave it.
function _ig749_project(f, tag::String; ignores = nothing)
  dir = mktempdir()
  pool = nothing
  try
    cd(dir) do
      mkpath(tag)
      pool = SQLiteConnectionPool(joinpath(dir, "$(tag).sqlite"); pool_size = 1)
      settings = Configuration.Settings(connections = pool, db_def_folder = tag)
      settings.change_db = true
      models_path = joinpath(dir, tag, settings.model_file)
      _ig749_write_models(models_path)
      _ig749_quiet(() -> Migrations.makemigrations(pool, settings; path = models_path, interactive = false))
      _ig749_quiet(() -> Migrations.migrate(pool, settings; interactive = false))
      # Raw DDL is the fixture here, not the feature: the table stands for another system's.
      fetch(pool, "CREATE TABLE legacy_timing_laps (id INTEGER PRIMARY KEY, lap INTEGER, stamp TEXT DEFAULT (datetime('now')));")
      ignores === nothing || (settings.db_config_settings = Dict{String,Any}("ignore_tables" => ignores))
      f(pool, settings, models_path)
    end
  finally
    pool === nothing || close_pool!(pool)
    rm(dir; recursive = true, force = true)
  end
end

_ig749_pending(settings) = isfile(joinpath(settings.db_def_folder, "migrations", "pending_migrations.jl"))

# ─────────────────────────────────────────────────────────────────────────────
# ignore_tables: makemigrations skips the table on the listing connection only
# The core property. Connection A lists the prefix and plans nothing; connection B, the same database
# shape without the key, still plans to drop the undeclared table — so the list is per connection,
# not global.
# ─────────────────────────────────────────────────────────────────────────────
@testset "ignore_tables: makemigrations skips the table on that connection only (#749)" begin
  _ig749_project("db749a"; ignores = ["legacy_timing_"]) do pool, settings, models_path
    _ig749_quiet(() -> Migrations.makemigrations(pool, settings; path = models_path, interactive = false))
    @test !_ig749_pending(settings)          # nothing to plan: the feed table was never read
  end
  _ig749_project("db749b") do pool, settings, models_path
    _ig749_quiet(() -> Migrations.makemigrations(pool, settings; path = models_path, interactive = false))
    @test _ig749_pending(settings)           # the control: without the key, a DROP is planned
    plan = read(joinpath(settings.db_def_folder, "migrations", "pending_migrations.jl"), String)
    @test occursin("legacy_timing_laps", plan)
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# ignore_tables: check() honors the key in both finding classes, on top of its keyword
# `:schema_drift` reads through `read_live_schema`; `:expression_default` does its own read, so it is
# the arm a merge in one place would miss. A caller's `ignore_table=` replaces only the backend
# default — the connection's list still applies on top of it, like the registry.
# ─────────────────────────────────────────────────────────────────────────────
@testset "ignore_tables: check() honors the key in both finding classes (#749)" begin
  kinds = [:schema_drift, :expression_default]
  _ig749_project("db749c"; ignores = "legacy_timing_") do pool, settings, _
    r = _ig749_quiet(() -> Migrations.check(pool, settings; kinds = kinds))
    @test !any(f -> f.table == "legacy_timing_laps", r.findings)
    # An explicit keyword does not switch the connection's list off.
    r = _ig749_quiet(() -> Migrations.check(pool, settings; kinds = kinds, ignore_table = copy(PormG.sqlite_ignore_schema)))
    @test !any(f -> f.table == "legacy_timing_laps", r.findings)
  end
  _ig749_project("db749d") do pool, settings, _
    r = _ig749_quiet(() -> Migrations.check(pool, settings; kinds = kinds))
    tables = Dict(f.kind => f.table for f in r.findings)
    @test get(tables, :schema_drift, nothing) == "legacy_timing_laps"         # "Drop table"
    @test get(tables, :expression_default, nothing) == "legacy_timing_laps"   # DEFAULT (datetime('now'))
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# ignore_tables: merges with register_ignore_tables!, and neither replaces the other
# Two feed tables, one per source. Each is hidden only by the source that names it: the registry is
# process-wide, the key belongs to this connection.
# ─────────────────────────────────────────────────────────────────────────────
@testset "ignore_tables: merges with the registry (#749)" begin
  saved = copy(PormG._EXTRA_IGNORE_TABLES[])
  try
    PormG._EXTRA_IGNORE_TABLES[] = ["nitro_"]
    _ig749_project("db749e"; ignores = ["legacy_timing_"]) do pool, settings, _
      fetch(pool, "CREATE TABLE nitro_task (id TEXT PRIMARY KEY);")
      fetch(pool, "CREATE TABLE pit_feed (id INTEGER PRIMARY KEY);")
      r = _ig749_quiet(() -> Migrations.check(pool, settings; kinds = [:schema_drift]))
      # Only the table no list names is reported — the drop proves the read saw the database.
      @test [f.table for f in r.findings] == ["pit_feed"]
    end
  finally
    PormG._EXTRA_IGNORE_TABLES[] = saved
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# ignore_tables: a declared managed model on a listed table is a configuration error
# The model asks PormG to migrate the table; the key asks PormG never to read it. Read as absent, the
# table would be planned as `CREATE TABLE IF NOT EXISTS` — a no-op — on every run. Both planners of
# that plan refuse it, naming the model and the entry. `managed = false` is the sanctioned way to
# query such a table, and plans nothing; the same managed model on a connection without the key
# still plans normally, which scopes the refusal to the per-connection list.
# ─────────────────────────────────────────────────────────────────────────────
@testset "ignore_tables: a managed model on an ignored table is refused (#749)" begin
  lap_model(opts) = "Legacy_timing_laps = Models.Model(\"legacy_timing_laps\"; $(opts)id = Models.IDField(), lap = Models.IntegerField(null = true))\n"

  _ig749_project("db749f"; ignores = ["legacy_timing_"]) do pool, settings, models_path
    _ig749_write_models(models_path; extra = lap_model(""))
    err = try
      _ig749_quiet(() -> Migrations.makemigrations(pool, settings; path = models_path, interactive = false))
      nothing
    catch e
      e
    end
    @test err isa PormG.InvalidConfigurationError
    msg = PormG.error_message(err)
    @test occursin("legacy_timing_laps", msg)
    @test occursin("\"legacy_timing_\"", msg)      # the entry that matched
    @test occursin("managed = false", msg)         # the fix
    @test !_ig749_pending(settings)

    # check(:schema_drift) builds the same plan, so it refuses the same way — for the same reason.
    check_err = try
      _ig749_quiet(() -> Migrations.check(pool, settings; kinds = [:schema_drift]))
      nothing
    catch e
      e
    end
    @test check_err isa PormG.InvalidConfigurationError
    @test occursin("\"legacy_timing_\"", PormG.error_message(check_err))

    # Unmanaged, the model is legitimate: nothing to plan, no error.
    _ig749_write_models(models_path; extra = lap_model("managed = false, "))
    _ig749_quiet(() -> Migrations.makemigrations(pool, settings; path = models_path, interactive = false))
    @test !_ig749_pending(settings)

    # ...until it gains a ManyToManyField to a managed model. Its auto join table,
    # `legacy_timing_laps_circuits`, is managed because one end is, and sits under the prefix. The
    # refusal still fires, but `managed = false` cannot be written on a synthesized table, so the
    # message names the join table and its own fix instead.
    _ig749_write_models(models_path; extra =
      "Legacy_timing_laps = Models.Model(\"legacy_timing_laps\"; managed = false, id = Models.IDField(), " *
      "circuits = Models.ManyToManyField(Circuit749))\n")
    m2m_err = try
      _ig749_quiet(() -> Migrations.makemigrations(pool, settings; path = models_path, interactive = false))
      nothing
    catch e
      e
    end
    @test m2m_err isa PormG.InvalidConfigurationError
    m2m_msg = PormG.error_message(m2m_err)
    @test occursin("auto join table", m2m_msg)
    @test occursin("legacy_timing_laps_circuits", m2m_msg)
    @test occursin("db_table", m2m_msg)
    @test !occursin("managed = false", m2m_msg)   # the one fix that cannot apply here is not offered
  end

  # The same managed model without the key: the refusal is the key's, not the model's.
  _ig749_project("db749g") do pool, settings, models_path
    _ig749_write_models(models_path; extra = lap_model(""))
    _ig749_quiet(() -> Migrations.makemigrations(pool, settings; path = models_path, interactive = false))
    @test _ig749_pending(settings)
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# ignore_tables: import_models_from_sqlite skips the listed tables
# The importer is the other reader holding `settings` (#749's title: "introspection and
# makemigrations"). It needs a folder-backed connection, so this one goes through `load` and a real
# connection.yml rather than a hand-built `Settings`.
# ─────────────────────────────────────────────────────────────────────────────
@testset "ignore_tables: import_models_from_sqlite skips the listed tables (#749)" begin
  mktempdir() do dir
    db_dir = joinpath(dir, "db749h")
    mkpath(db_dir)
    write(joinpath(db_dir, "connection.yml"),
          "dev:\n  adapter: SQLite\n  database: f1.sqlite\n  ignore_tables: ['legacy_timing_']\n")
    key = _ig749_quiet(() -> Configuration.load(db_dir; env = "dev"))
    try
      pool = Configuration.get_settings(key).connections
      fetch(pool, "CREATE TABLE circuit749 (id INTEGER PRIMARY KEY, name TEXT);")
      fetch(pool, "CREATE TABLE legacy_timing_laps (id INTEGER PRIMARY KEY, lap INTEGER);")
      _ig749_quiet(() -> Migrations.import_models_from_sqlite(key; file = "imported.jl"))
      src = read(joinpath(db_dir, "imported.jl"), String)
      @test occursin("circuit749", src)              # the read happened
      @test !occursin("legacy_timing_laps", src)     # and skipped the listed table
    finally
      close_pool!(Configuration.get_settings(key).connections)
      pop!(PormG.config, key, nothing)
    end
  end
end
