# ============================================================
# test/unit/test_migration_pg_fixture.jl
#
# Committed PostgreSQL migration fixture contract (#36).
#
# CONTRACT being tested:
#   `test/integration/db_test_migration_pg/connection.yml` is committed (so the migration
#   edge-case suite runs against a DEDICATED disposable DB, never the shared pormg_teste) AND
#   is credential-free (host/username/password blank, hydrated in-memory at runtime — no secrets
#   in git). This is a deterministic, DB-free guard: it parses the tracked YAML and fails if
#   anyone commits credentials or points the fixture back at the shared integration database.
#
# Mutation gate: point `database` at pormg_teste, or fill in any credential, and an assertion
# below fails. The blanket `*connection.yml` .gitignore rule plus its #36 negation exception are
# what make this file exist in a clean checkout for the test to read.
# ============================================================

using Test
import YAML

# The fixture lives beside the integration suite; resolve it relative to this unit test file.
const PG_FIXTURE_PATH = normpath(joinpath(@__DIR__, "..", "integration",
                                          "db_test_migration_pg", "connection.yml"))

# A value is "blank" when it is YAML null (`~` → nothing) or an empty/whitespace string.
_fixture_blank(v) = v === nothing || isempty(strip(string(v)))

@testset "Committed PostgreSQL migration fixture is isolated + credential-free (#36)" begin
  # ───────────────────────────────────────────────────────────────────────────
  # The file must be present in the checkout (the .gitignore negation makes it committable).
  # If this fails, the negation rule regressed and the fixture is being ignored again.
  # ───────────────────────────────────────────────────────────────────────────
  @test isfile(PG_FIXTURE_PATH)

  raw = YAML.load_file(PG_FIXTURE_PATH)

  # The active env section is what the loader actually reads, but we assert the invariant on
  # EVERY PostgreSQL section present (dev/test/prod) so no section can smuggle in credentials or
  # a shared-DB name.
  env_sections = [k for (k, v) in raw if v isa AbstractDict && get(v, "adapter", nothing) == "PostgreSQL"]
  @test !isempty(env_sections)   # at least one PostgreSQL section to validate

  for key in env_sections
    section = raw[key]

    # Adapter is PostgreSQL (this is the PG fixture).
    @test section["adapter"] == "PostgreSQL"

    # Isolation: a dedicated disposable DB, explicitly NOT the shared integration database.
    db = get(section, "database", nothing)
    @test !_fixture_blank(db)
    @test db == "pormg_migration_test"
    @test db != "pormg_teste"

    # Credential-free: no host/username/password committed — these are hydrated in-memory at
    # runtime (hydrate_postgres_settings! in common_migration_setup.jl). Guards against secrets
    # ever landing in git.
    @test _fixture_blank(get(section, "host", nothing))
    @test _fixture_blank(get(section, "username", nothing))
    @test _fixture_blank(get(section, "password", nothing))
  end
end
