# ==============================================================================
# SCHEMA IMPORTER / INTROSPECTION — Live-Database Integration Tests
#
# Included from runtests.jl AFTER common_setup.jl, against the selected DB
# (PORMG_DB_FOLDER; db_2 = PostgreSQL by default, db_sl = SQLite).
#
# Why integration: every importer/introspection UNIT test uses a hermetic temp
# SQLite database or a synthetic DataFrameRow. The real PostgreSQL introspection
# path — `convert_schema_to_models(::PormGPostgres)` → `get_database_schema` →
# `convertSQLToModel(::DataFrameRow)` — is exercised by NOTHING at the unit level.
# This file closes that gap against a real engine:
#
#   1. Edge-case primary keys (VARCHAR / NUMERIC PRIMARY KEY) introspect without
#      crashing and map to an IDField. On PostgreSQL this exercises the
#      `hasfield(field, :max_length/:max_digits)` guards directly — before them,
#      assigning those attributes onto the PK's IDField raised FieldError.
#   2. `register_ignore_tables!` is honoured by the live introspection (the same
#      registry the Nitro extension uses), not just by the hermetic SQLite test.
#
# The file-writing layer (`Model_to_str` / `generate_models_from_db`) already has
# hermetic unit coverage (test/unit/test_importers.jl); here we target the
# introspection core where the real-DB behaviour lives. Fixture tables use a
# `pormg_it_` prefix and are dropped in a `finally`, leaving the schema untouched.
# ==============================================================================

@testset "Schema Importer / Introspection ($(PORMG_DB_FOLDER))" begin
  settings = PormG.config[PORMG_DB_FOLDER]
  pool = settings.connections
  is_pg = adapter_name == "PostgreSQL"

  ddl(sql) = PormG.ConnectionPool.fetch(pool, sql)
  fixtures = ("pormg_it_natural_key", "pormg_it_numeric_key", "pormg_it_ignored")
  drop_fixtures() = for t in fixtures
    try; ddl("DROP TABLE IF EXISTS \"$(t)\""); catch; end
  end

  # Adapter-appropriate DDL. The VARCHAR/NUMERIC primary keys only stress the
  # Postgres max_length/max_digits guard; on SQLite they degrade to TEXT/INTEGER
  # (still a valid "PK → IDField, no crash" check on the SQLite introspection path).
  natural_pk_ddl = is_pg ?
    """CREATE TABLE "pormg_it_natural_key" (code VARCHAR(20) PRIMARY KEY, label VARCHAR(100))""" :
    """CREATE TABLE "pormg_it_natural_key" (code TEXT PRIMARY KEY, label TEXT)"""
  numeric_pk_ddl = is_pg ?
    """CREATE TABLE "pormg_it_numeric_key" (id NUMERIC(10,0) PRIMARY KEY, amount NUMERIC(8,2))""" :
    """CREATE TABLE "pormg_it_numeric_key" (id INTEGER PRIMARY KEY, amount REAL)"""
  ignored_ddl = is_pg ?
    """CREATE TABLE "pormg_it_ignored" (id INTEGER PRIMARY KEY, note VARCHAR(50))""" :
    """CREATE TABLE "pormg_it_ignored" (id INTEGER PRIMARY KEY, note TEXT)"""

  drop_fixtures()                      # clean slate if a prior run aborted mid-test
  ddl(natural_pk_ddl)
  ddl(numeric_pk_ddl)
  ddl(ignored_ddl)

  saved_ignore = copy(PormG._EXTRA_IGNORE_TABLES[])
  try
    # ── 1. Introspection survives edge-case primary keys (Finding 3.1) ──────
    # Not throwing IS the regression guard: before the hasfield guards, a
    # VARCHAR/NUMERIC PK crashed convertSQLToModel on the Postgres path.
    models = PormG.Migrations.convert_schema_to_models(pool;
        include_table = ["pormg_it_natural_key", "pormg_it_numeric_key"])
    by_name = Dict(lowercase(string(m.name)) => m for m in models)

    @test haskey(by_name, "pormg_it_natural_key")
    @test haskey(by_name, "pormg_it_numeric_key")
    # PKs map to IDField regardless of their underlying SQL type.
    @test by_name["pormg_it_natural_key"].fields["code"] isa PormG.Models.sIDField
    @test by_name["pormg_it_numeric_key"].fields["id"] isa PormG.Models.sIDField
    # A non-PK sized column keeps its max_length — the guard skipped only the PK.
    if is_pg
      @test by_name["pormg_it_natural_key"].fields["label"].max_length == 100
    end

    # ── 2. register_ignore_tables! honoured by live introspection (Finding 4) ──
    PormG.register_ignore_tables!(["pormg_it_ignored"])
    models2 = PormG.Migrations.convert_schema_to_models(pool;
        include_table = ["pormg_it_ignored", "pormg_it_natural_key"])
    names2 = Set(lowercase(string(m.name)) for m in models2)

    @test "pormg_it_natural_key" in names2     # ordinary table still imported
    @test !("pormg_it_ignored" in names2)      # registered table skipped on the real path
  finally
    PormG._EXTRA_IGNORE_TABLES[] = saved_ignore   # never leak registry state
    drop_fixtures()
  end
end
