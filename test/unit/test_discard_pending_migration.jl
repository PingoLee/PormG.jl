"""
Unit coverage for `discard_pending_migration` — the filesystem-only migration-draft discard.

`discard_pending_migration` throws away an un-applied `migrations/pending_migrations.jl`
draft. It never touches the `pormg_migrations` history table or the schema, so it is fully
unit-testable with a temp `db_def_folder` (no live database). This file pins the contract:

  - no pending file        → returns `nothing` (and does not error),
  - backup=true (default)  → renames to `pending_migrations.jl.discarded`, original removed,
  - backup=false           → deletes outright, no backup file,
  - the returned counts (`tables`/`statements`) reflect the parsed plan,
  - the `db::String` overload resolves settings from `config`.

The fixture mirrors the module/`OrderedDict` shape that `generate_migration_plan` writes and
`_load_migration_plan` parses (`get_all_dicts` collects every `OrderedDict` in the module):
two tables carrying 1 + 2 = 3 statements total.
"""

using Test
using PormG
import PormG: Configuration
import PormG.Migrations: discard_pending_migration

# Write a valid pending_migrations.jl under `<dir>/migrations/`, matching the real
# generated format. Two OrderedDict "tables" → tables=2; 1+2 entries → statements=3.
function _write_pending_fixture(dir::String)
  migrations_dir = joinpath(dir, "migrations")
  mkpath(migrations_dir)
  path = joinpath(migrations_dir, "pending_migrations.jl")
  write(path, """
        module pending_migrations

        import PormG.Migrations
        import OrderedCollections: OrderedDict

        # table: tbl_a
        tbl_a = OrderedDict("New model" => "CREATE TABLE a (id INTEGER);")

        # table: tbl_b
        tbl_b = OrderedDict("Add field x" => "ALTER TABLE b ADD x INTEGER;", "Add field y" => "ALTER TABLE b ADD y TEXT;")

        end
        """)
  return path
end

@testset "discard_pending_migration" begin

  # ───────────────────────────────────────────────────────────────────────────
  # 1. No pending file → nothing (graceful, no error).
  # ───────────────────────────────────────────────────────────────────────────
  @testset "no pending file returns nothing" begin
    mktempdir() do dir
      settings = Configuration.Settings(db_def_folder = dir)
      @test discard_pending_migration(settings) === nothing
    end
  end

  # ───────────────────────────────────────────────────────────────────────────
  # 2. backup=true (default): rename to .discarded, original gone, counts reported.
  # ───────────────────────────────────────────────────────────────────────────
  @testset "backup=true renames to .discarded and reports counts" begin
    mktempdir() do dir
      path = _write_pending_fixture(dir)
      settings = Configuration.Settings(db_def_folder = dir)

      res = discard_pending_migration(settings)   # backup defaults to true
      @test res !== nothing
      @test res.discarded === true
      @test res.tables == 2
      @test res.statements == 3
      @test res.path == path
      @test res.backup == path * ".discarded"
      @test !isfile(path)                 # original removed
      @test isfile(path * ".discarded")   # recoverable backup written
    end
  end

  # ───────────────────────────────────────────────────────────────────────────
  # 3. backup=false: delete outright, no backup file, backup field is nothing.
  # ───────────────────────────────────────────────────────────────────────────
  @testset "backup=false deletes outright, no backup" begin
    mktempdir() do dir
      path = _write_pending_fixture(dir)
      settings = Configuration.Settings(db_def_folder = dir)

      res = discard_pending_migration(settings; backup = false)
      @test res.discarded === true
      @test res.backup === nothing
      @test !isfile(path)                  # original removed
      @test !isfile(path * ".discarded")   # nothing left behind
    end
  end

  # ───────────────────────────────────────────────────────────────────────────
  # 4. db::String overload resolves settings from `config` and delegates.
  # ───────────────────────────────────────────────────────────────────────────
  @testset "db::String overload resolves settings from config" begin
    mktempdir() do dir
      path = _write_pending_fixture(dir)
      key = "discard_pending_test_key"
      PormG.config[key] = Configuration.Settings(db_def_folder = dir)
      try
        res = discard_pending_migration(key)
        @test res.discarded === true
        @test res.tables == 2
        @test !isfile(path)
        @test isfile(path * ".discarded")
      finally
        delete!(PormG.config, key)
      end
    end
  end

end
