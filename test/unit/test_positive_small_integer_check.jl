# ─────────────────────────────────────────────────────────────────────────────
# Positive integer fields: non-negative CHECK constraint lifecycle (SQL shape)
# Verifies the `CHECK ("col" >= 0)` constraint is emitted at CREATE TABLE for both
# backends and, on PostgreSQL ALTER, is added/dropped as a column transitions into
# or out of PositiveSmallIntegerField / PositiveIntegerField. Mirrors Django, which
# diffs CHECK constraints across alters instead of only emitting them at table
# creation. Pure SQL-shape tests — no live DB.
# ─────────────────────────────────────────────────────────────────────────────

using Test
using PormG
using PormG.Models

# Mock connections for DB-free SQL generation (same pattern as test_migrations_runner.jl).
struct MockPGCheck <: PormG.PormGPostgres end
struct MockSLCheck <: PormG.PormGSQLite end

# A second Postgres mock whose introspection returns a known constraint name, so the
# DROP-on-transition path can be exercised deterministically without querying a database.
struct MockPGCheckNamed <: PormG.PormGPostgres end
PormG.get_constraints_check(::MockPGCheckNamed, table_name::String, field_name::String) = "circuits_alt_check"

@testset "PositiveSmallIntegerField CHECK constraint" begin
  # ───────────────────────────────────────────────────────────────────────────
  # CREATE TABLE: positive small integer columns carry a non-negative CHECK on both
  # backends, while a plain IntegerField does not. This is the baseline guard.
  # ───────────────────────────────────────────────────────────────────────────
  @testset "emitted at CREATE TABLE" begin
    psi = Models.PositiveSmallIntegerField()
    int_field = Models.IntegerField()

    pg_col = PormG.Dialect.field_to_column("position", psi, MockPGCheck())
    sl_col = PormG.Dialect.field_to_column("position", psi, MockSLCheck())
    @test occursin("CHECK (\"position\" >= 0)", pg_col)
    @test occursin("CHECK (\"position\" >= 0)", sl_col)

    # A non-positive integer field must never emit the CHECK.
    @test !occursin("CHECK", PormG.Dialect.field_to_column("laps", int_field, MockPGCheck()))
    @test !occursin("CHECK", PormG.Dialect.field_to_column("laps", int_field, MockSLCheck()))
  end

  # ───────────────────────────────────────────────────────────────────────────
  # ALTER (Postgres) into a positive field: the type change is followed by an
  # `ADD CHECK (...)`. Order matters — the constraint must be added after the cast.
  # ───────────────────────────────────────────────────────────────────────────
  @testset "added on transition into PositiveSmallIntegerField" begin
    new_field = Models.PositiveSmallIntegerField()
    old_field = Models.IntegerField()

    sql = PormG.Dialect.alter_field(MockPGCheck(), "circuits", "alt", new_field, old_field, Symbol[:type])

    @test occursin("ALTER COLUMN \"alt\" TYPE smallint", sql)
    @test occursin("ADD CHECK (\"alt\" >= 0)", sql)
    # ADD must come after the TYPE change so the cast is not blocked.
    @test findfirst("TYPE smallint", sql).start < findfirst("ADD CHECK", sql).start
  end

  # ───────────────────────────────────────────────────────────────────────────
  # ALTER (Postgres) out of a positive field: the existing CHECK is dropped (by the
  # name introspection returns) before the type change. Uses the named mock so no DB
  # is required.
  # ───────────────────────────────────────────────────────────────────────────
  @testset "dropped on transition out of PositiveSmallIntegerField" begin
    new_field = Models.IntegerField()
    old_field = Models.PositiveSmallIntegerField()

    sql = PormG.Dialect.alter_field(MockPGCheckNamed(), "circuits", "alt", new_field, old_field, Symbol[:type])

    @test occursin("DROP CONSTRAINT \"circuits_alt_check\"", sql)
    # DROP must precede the TYPE change so an incompatible cast is not blocked.
    @test findfirst("DROP CONSTRAINT", sql).start < findfirst("ALTER COLUMN \"alt\" TYPE", sql).start
    # No spurious ADD when leaving the positive field.
    @test !occursin("ADD CHECK", sql)
  end
end

@testset "PositiveIntegerField CHECK constraint" begin
  # ───────────────────────────────────────────────────────────────────────────
  # Constructor: defaults must respect Django's PositiveIntegerField range
  # (0..2147483647). Negative and overflowing defaults are rejected in Julia
  # before any SQL is generated.
  # ───────────────────────────────────────────────────────────────────────────
  @testset "constructor enforces the non-negative range" begin
    @test Models.PositiveIntegerField(default=0).default == 0
    @test Models.PositiveIntegerField(default=2147483647).default == 2147483647
    @test_throws ArgumentError Models.PositiveIntegerField(default=-1)
    @test_throws ArgumentError Models.PositiveIntegerField(default=2147483648)
  end

  # ───────────────────────────────────────────────────────────────────────────
  # CREATE TABLE: PostgreSQL renders plain `integer` (no unsigned type exists) and
  # relies on the CHECK; SQLite uses the distinct Django-style declared type
  # `INTEGER UNSIGNED` so introspection can round-trip the field without drift.
  # ───────────────────────────────────────────────────────────────────────────
  @testset "emitted at CREATE TABLE with backend-specific column types" begin
    pi_field = Models.PositiveIntegerField()

    pg_col = PormG.Dialect.field_to_column("milliseconds", pi_field, MockPGCheck())
    sl_col = PormG.Dialect.field_to_column("milliseconds", pi_field, MockSLCheck())

    @test occursin("\"milliseconds\" integer", pg_col)
    @test occursin("CHECK (\"milliseconds\" >= 0)", pg_col)
    @test occursin("\"milliseconds\" INTEGER UNSIGNED", sl_col)
    @test occursin("CHECK (\"milliseconds\" >= 0)", sl_col)
  end

  # ───────────────────────────────────────────────────────────────────────────
  # ALTER (Postgres) into a positive field: the type change is followed by an
  # `ADD CHECK (...)`, in that order, exactly like PositiveSmallIntegerField.
  # ───────────────────────────────────────────────────────────────────────────
  @testset "added on transition into PositiveIntegerField" begin
    new_field = Models.PositiveIntegerField()
    old_field = Models.IntegerField()

    sql = PormG.Dialect.alter_field(MockPGCheck(), "lap_times", "milliseconds", new_field, old_field, Symbol[:type])

    @test occursin("ALTER COLUMN \"milliseconds\" TYPE integer", sql)
    @test occursin("ADD CHECK (\"milliseconds\" >= 0)", sql)
    @test findfirst("TYPE integer", sql).start < findfirst("ADD CHECK", sql).start
  end

  # ───────────────────────────────────────────────────────────────────────────
  # ALTER (Postgres) out of a positive field: the existing CHECK is dropped before
  # the type change, using the constraint name introspection returns.
  # ───────────────────────────────────────────────────────────────────────────
  @testset "dropped on transition out of PositiveIntegerField" begin
    new_field = Models.IntegerField()
    old_field = Models.PositiveIntegerField()

    sql = PormG.Dialect.alter_field(MockPGCheckNamed(), "lap_times", "milliseconds", new_field, old_field, Symbol[:type])

    @test occursin("DROP CONSTRAINT \"circuits_alt_check\"", sql)
    @test findfirst("DROP CONSTRAINT", sql).start < findfirst("ALTER COLUMN \"milliseconds\" TYPE", sql).start
    @test !occursin("ADD CHECK", sql)
  end

  # ───────────────────────────────────────────────────────────────────────────
  # ALTER (Postgres) between the two positive fields: both carry the CHECK, so a
  # smallint <-> integer transition must change only the type — no constraint churn.
  # ───────────────────────────────────────────────────────────────────────────
  @testset "no CHECK churn between positive integer fields" begin
    new_field = Models.PositiveIntegerField()
    old_field = Models.PositiveSmallIntegerField()

    sql = PormG.Dialect.alter_field(MockPGCheckNamed(), "results", "points", new_field, old_field, Symbol[:type])

    @test occursin("ALTER COLUMN \"points\" TYPE integer", sql)
    @test !occursin("ADD CHECK", sql)
    @test !occursin("DROP CONSTRAINT", sql)
  end

  # ───────────────────────────────────────────────────────────────────────────
  # SQLite round-trip: a CREATE TABLE statement declaring `INTEGER UNSIGNED` must
  # introspect back to PositiveIntegerField (not IntegerField), otherwise every
  # makemigrations run after migrate would report a spurious type change.
  # ───────────────────────────────────────────────────────────────────────────
  @testset "SQLite CREATE TABLE sql introspects back to PositiveIntegerField" begin
    sql = """CREATE TABLE "lap_times" (
      "id" INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
      "lap" INTEGER NOT NULL,
      "milliseconds" INTEGER UNSIGNED NOT NULL CHECK ("milliseconds" >= 0)
    );"""

    model = PormG.Migrations.convertSQLToModel(sql)

    @test model.fields["milliseconds"] isa Models.sPositiveIntegerField
    # A plain INTEGER column must keep mapping to IntegerField.
    @test model.fields["lap"] isa Models.sIntegerField
  end
end
