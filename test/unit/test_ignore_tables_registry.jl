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
