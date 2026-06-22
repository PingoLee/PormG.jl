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
      fetch(pool, "CREATE TABLE keep_me (id INTEGER PRIMARY KEY, n INTEGER);")
      fetch(pool, "CREATE TABLE nitro_task (id TEXT PRIMARY KEY, status TEXT);")
      fetch(pool, "CREATE TABLE nitro_session (session_key TEXT PRIMARY KEY, data TEXT);")

      models = convert_schema_to_models(pool)   # sqlite default ignore list ∪ registry
      names = Set(lowercase(string(m.name)) for m in models)

      @test "keep_me" in names            # ordinary user table is imported
      @test !("nitro_task" in names)      # registered → skipped
      @test !("nitro_session" in names)   # registered → skipped
    end
  finally
    PormG._EXTRA_IGNORE_TABLES[] = saved   # never leak registry state into other suites
  end
end
