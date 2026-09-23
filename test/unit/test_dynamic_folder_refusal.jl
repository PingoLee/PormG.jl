"""
Unit coverage for #683: migrations, planning and model import refuse a `register_connection` entry.

A dynamic connection has no models folder. `register_connection` stores the label
`"dynamic_connection"` in `Settings.db_def_folder` (the real marker is `settings.dynamic`, #623),
and the migration runner, the planner and the importers all `joinpath` that field as a folder
relative to the working directory. So when a static folder of that name sat in the working
directory, it stood in for the tenant: `dry_run("tenant7")` ran and reported **that folder's**
pending plan, `discard_pending_migration` moved it, the importers wrote beside it, and — once the
entry's `change_db` was enabled — `makemigrations` overwrote it with the tenant's diff and
`migrate` applied it to the tenant's database.

This is the opposite direction of #623, which stopped a static folder being *read as dynamic*; its
tests live in `test_connect_key_resolution.jl`, and the positive controls below keep that direction
green. Every case here runs in a temporary working directory holding exactly that decoy folder, and
asserts two things: the call raises `InvalidConfigurationError`, and the decoy is byte-for-byte
untouched. Hermetic — the only connection opened is an in-memory SQLite pool.

Sibling guard, same flag one layer up: `test_self_heal_inference.jl` (the `Models.jl` fallback).
"""
# julia --project=test/integration test/unit/test_dynamic_folder_refusal.jl

using Test
using PormG
# The real `register_connection` case builds a SQLite pool, which needs the weakdep extension.
# `runtests.jl` loads the drivers for the whole suite; this makes the file runnable on its own.
isdefined(Main, :SQLite) || include(joinpath(@__DIR__, "..", "load_drivers.jl"))
import PormG: Configuration, Migrations

# Top-level mock (struct definitions are forbidden inside @testset bodies). Uniquely named so it
# never clashes with other unit files included into the same module.
if !isdefined(Main, :_MockPg683)
  struct _MockPg683 <: PormG.PormGPostgres end
end

# Every file under `dir`, keyed by its relative path. Equal snapshots before and after a call mean
# the call neither wrote, moved nor removed anything there.
function _snapshot_683(dir::AbstractString)
  Dict(relpath(joinpath(root, f), dir) => read(joinpath(root, f), String)
       for (root, _, files) in walkdir(dir) for f in files)
end

# The folder a pre-#683 dynamic entry resolved to, populated the way a real static folder of that
# name would be: a reviewed pending plan and a models file.
function _write_decoy_683(root::AbstractString)
  mkpath(joinpath(root, "dynamic_connection", "migrations"))
  write(joinpath(root, "dynamic_connection", "migrations", "pending_migrations.jl"),
        "# decoy: a pending plan that belongs to the STATIC folder, never to a tenant\n")
  write(joinpath(root, "dynamic_connection", "models.jl"), "# decoy models file\n")
end

const _DJANGO_SRC_683 = """
from django.db import models

class Circuit(models.Model):
    name = models.CharField(max_length=255)
"""

# ─────────────────────────────────────────────────────────────────────────────
# Dynamic connections: every folder-reading entry point refuses them (#683)
# One nested case per guarded site, so a mutant that drops any single guard fails exactly its own
# case — all of them sit under this one top-level testset, which is what lets a single run report
# every case instead of stopping at the first failure. The string arities go through the REAL
# `register_connection`, so the flag it sets is what trips the guard; the PostgreSQL arities need a
# connection type, which a mock supplies without opening anything.
# ─────────────────────────────────────────────────────────────────────────────
@testset "dynamic connections refuse migrations, planning and import (#683)" begin
  saved = copy(PormG.config)
  root = mktempdir()
  key = "tenant7_683"
  pg_key = "tenant7_pg_683"
  try
    cd(root) do
      _write_decoy_683(root)
      # A NAMED in-memory database, not `file::memory:?cache=shared`: that one name is shared by the
      # whole process, so a pool another file left open could hold a `pormg_migrations` table and
      # turn the history-table assertion below falsely red.
      Configuration.register_connection(key, "file:refusal683?mode=memory&cache=shared"; adapter = "SQLite")
      @test PormG.config[key].dynamic
      @test PormG.config[key].db_def_folder == "dynamic_connection"   # the label the bug followed
      # Enabled on the settings object — the only way a dynamic entry can enable it — and
      # load-bearing here: with the default
      # `change_db = false`, `migrate` returns early, which would hide a guard placed after
      # `init_migrations`. The history-table assertion after the loop depends on it.
      PormG.config[key].change_db = true

      pg_settings = Configuration.Settings(connections = _MockPg683(), dynamic = true,
                                           db_def_folder = "dynamic_connection")
      PormG.config[pg_key] = pg_settings
      sqlite_settings = PormG.config[key]

      # (label, the action name the message must carry, the call)
      cases = [
        ("status(key)",                     "status",                    () -> Migrations.status(key)),
        ("dry_run(key)",                    "dry_run",                   () -> Migrations.dry_run(key)),
        # Pre-fix this one warned about `change_db` and returned `nothing`: a dynamic entry's
        # defaults have `change_db = false`, so the refusal must come before that early return.
        ("migrate(key)",                    "migrate",                   () -> Migrations.migrate(key; interactive = false)),
        ("migrate_to(key, version)",        "migrate_to",                () -> Migrations.migrate_to(key, "20260101000000"; interactive = false)),
        ("discard_pending_migration(key)",  "discard_pending_migration", () -> Migrations.discard_pending_migration(key)),
        # The String arity builds `joinpath(key, model_file)` from the KEY before delegating, so it
        # carries its own guard; the SQLite method below is reached only by a direct call.
        ("makemigrations(key)",             "makemigrations",            () -> Migrations.makemigrations(key; interactive = false)),
        ("makemigrations(sqlite, settings)", "makemigrations",           () -> Migrations.makemigrations(sqlite_settings.connections, sqlite_settings; interactive = false)),
        ("makemigrations(pg, settings)",    "makemigrations",            () -> Migrations.makemigrations(_MockPg683(), pg_settings; interactive = false)),
        ("import_models_from_sqlite(key)",  "import_models_from_sqlite", () -> Migrations.import_models_from_sqlite(key; force_replace = true)),
        ("import_models_from_postgres(key)", "import_models_from_postgres", () -> Migrations.import_models_from_postgres(pg_key; force_replace = true)),
        ("import_models_from_postgres(; db, settings)", "import_models_from_postgres",
            () -> Migrations.import_models_from_postgres(; db = _MockPg683(), settings = pg_settings, force_replace = true)),
        ("import_models_from_django(src; db = key)", "import_models_from_django",
            () -> Migrations.import_models_from_django(_DJANGO_SRC_683; db = key, force_replace = true)),
        # A non-default prefix sends `_django_render_settings` down its throwaway-Settings branch,
        # which drops the `dynamic` flag while copying the label as its folder — the check has to
        # run before that copy, or this case would write `./dynamic_connection/automatic_models.jl`.
        ("import_models_from_django(src; db = key, django_prefix)", "import_models_from_django",
            () -> Migrations.import_models_from_django(_DJANGO_SRC_683; db = key, django_prefix = "f1", force_replace = true)),
      ]

      for (label, action, call) in cases
        @testset "$label" begin
          before = _snapshot_683(root)
          err = try
            call()
            nothing
          catch e
            e
          end
          # The failure has to happen before its type is checked — a call that now succeeds
          # would otherwise pass silently.
          @test err !== nothing
          @test err isa PormG.InvalidConfigurationError
          # The message names the refused call and the API that made the entry, so the reader
          # knows which half of the configuration to change.
          @test err isa PormG.InvalidConfigurationError && occursin(action, err.msg)
          @test err isa PormG.InvalidConfigurationError && occursin("register_connection", err.msg)
          # Nothing under the working directory moved: the decoy plan is still there and no
          # models file was generated beside it.
          @test _snapshot_683(root) == before
        end
      end

      # The refusal comes before any DATABASE side effect too, which the filesystem snapshot cannot
      # see: `migrate` and `migrate_to` both bootstrap `pormg_migrations` via `init_migrations`, so
      # a guard moved below that call would leave the table behind in the tenant's database.
      @test !Migrations._migrations_table_exists(sqlite_settings.connections)
    end
  finally
    Configuration.unregister_connection(key)
    empty!(PormG.config)
    merge!(PormG.config, saved)
    rm(root; recursive = true, force = true)
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# Positive controls: what the refusal must NOT catch
# The guard is keyed on the `dynamic` flag. A STATIC folder literally named `dynamic_connection`
# is a real folder (#623) and keeps working; and a Django import given an explicit `output_path`
# writes to a real folder, so it stays allowed on a dynamic `db`, which it only reads a prefix from.
# ─────────────────────────────────────────────────────────────────────────────
@testset "the #683 refusal is keyed on the flag, not the folder label" begin
  saved = copy(PormG.config)
  root = mktempdir()
  key = "tenant8_683"
  try
    cd(root) do
      _write_decoy_683(root)

      # A static entry pointing at the same folder: here the pending plan really is its own.
      static = Configuration.Settings(db_def_folder = "dynamic_connection")
      @test !static.dynamic
      result = Migrations.discard_pending_migration(static; backup = true)
      @test result !== nothing && result.discarded
      @test isfile(joinpath(root, "dynamic_connection", "migrations", "pending_migrations.jl.discarded"))

      # Django import on a dynamic key with an explicit output folder succeeds, and writes there
      # and only there.
      Configuration.register_connection(key, "file:refusal683_ok?mode=memory&cache=shared"; adapter = "SQLite")
      out = joinpath(root, "out")
      Migrations.import_models_from_django(_DJANGO_SRC_683; db = key, output_path = out, force_replace = true)
      @test isfile(joinpath(out, "automatic_models.jl"))
      @test !isfile(joinpath(root, "dynamic_connection", "automatic_models.jl"))
    end
  finally
    Configuration.unregister_connection(key)
    empty!(PormG.config)
    merge!(PormG.config, saved)
    rm(root; recursive = true, force = true)
  end
end
