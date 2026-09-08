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

# #507 phase 2: `alter_field` takes a `ColumnDelta` rather than a `Vector{Symbol}` of
# field-attribute names. `_psi_delta` compiles both fields and names the facets under test, which is
# the direct translation of the vector each call used to pass.
#
# THE FACET IS THE POINT HERE, not merely the argument shape. A non-negative CHECK is the IR
# `:checks` facet, and on PostgreSQL that is ALL that separates `IntegerField` from
# `PositiveIntegerField` — both render `integer`. So the honest delta for that pair names `:checks`
# and NOT `:type`, and the renderer emits the CHECK alone. See the two re-adjudicated testsets
# below for what that changed.
# CHECKED, not trusted: the named facets must be exactly what the compiler reports for this pair, so
# a compiler change cannot leave these tests asserting a rendering the planner can no longer reach.
# (Flagged in review — a hand-built list is a second opinion, which is the very thing #507 removes.)
# `diffed = false` opts out for a pair that is deliberately SYNTHETIC: naming a facet an identical
# pair does not have is how "no constraint churn" is probed, and it has to stay possible.
function _psi_delta(conn, new_field, old_field, slots; name = "alt", diffed = true)
  new_spec = PormG.Migrations.column_spec(new_field, conn; name = name)
  old_spec = PormG.Migrations.column_spec(old_field, conn; name = name)
  diffed && @test PormG.column_delta(new_spec, old_spec) == slots
  return PormG.ColumnDelta(new_spec, old_spec, slots)
end

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

    sql = PormG.Dialect.alter_field(MockPGCheck(), "circuits", "alt", new_field, old_field,
                                    _psi_delta(MockPGCheck(), new_field, old_field, [:type, :checks]))

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

    sql = PormG.Dialect.alter_field(MockPGCheckNamed(), "circuits", "alt", new_field, old_field,
                                    _psi_delta(MockPGCheckNamed(), new_field, old_field, [:type, :checks]))

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
    @test_throws PormG.FieldValidationError Models.PositiveIntegerField(default=-1)
    @test_throws PormG.FieldValidationError Models.PositiveIntegerField(default=2147483648)
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
  # ALTER (Postgres) into a positive field: the CHECK is added, and NOTHING ELSE.
  #
  # RE-ADJUDICATED BY #507 phase 2, deliberately overwriting what this testset used to assert. It
  # required `ALTER COLUMN "milliseconds" TYPE integer` alongside the CHECK, and ordered the two.
  # But on PostgreSQL `IntegerField` and `PositiveIntegerField` BOTH render `integer` — the `>= 0`
  # CHECK is the entire difference — so that retype changed nothing while taking an ACCESS
  # EXCLUSIVE lock on the table. It was emitted because phase 1 `alter_attrs` mapped the `:checks`
  # facet onto the `:type` symbol, the only name the renderer old field-attribute gate recognised.
  # With the renderer gating on the IR facet, a checks-only delta emits a checks-only statement.
  #
  # The PositiveSmallIntegerField testset above still asserts a TYPE line, and must: `integer` to
  # `smallint` IS a type change. That contrast is the discrimination this pair of testsets carries.
  # ───────────────────────────────────────────────────────────────────────────
  @testset "added on transition into PositiveIntegerField" begin
    new_field = Models.PositiveIntegerField()
    old_field = Models.IntegerField()

    # DIFFED, not named: "this pair is checks-only" is then the compiler answer rather than an
    # assumption this test smuggles in through its own argument.
    delta = PormG.Migrations.column_delta(new_field, old_field, MockPGCheck(); name = "milliseconds")
    @test delta.changed == [:checks]

    sql = PormG.Dialect.alter_field(MockPGCheck(), "lap_times", "milliseconds", new_field, old_field, delta)

    @test occursin("ADD CHECK (\"milliseconds\" >= 0)", sql)
    @test !occursin("TYPE", sql)
    # One statement, not two.
    @test count(!isempty, split(strip(sql), Char(10))) == 1
  end

  # ───────────────────────────────────────────────────────────────────────────
  # ALTER (Postgres) out of a positive field: the existing CHECK is dropped, and nothing else.
  #
  # RE-ADJUDICATED BY #507 phase 2, the mirror of the testset above. It used to assert that the
  # DROP came BEFORE a `TYPE integer` statement — an ordering that only mattered because a
  # redundant retype was emitted at all. `integer` to `integer` is not a type change, so there is
  # nothing for the DROP to precede. The ordering RULE is unchanged and still covered where it
  # bites: the PositiveSmallIntegerField testset above, a real `smallint` -> `integer` transition
  # where a stale `>= 0` clause would block the cast.
  # ───────────────────────────────────────────────────────────────────────────
  @testset "dropped on transition out of PositiveIntegerField" begin
    new_field = Models.IntegerField()
    old_field = Models.PositiveIntegerField()

    delta = PormG.Migrations.column_delta(new_field, old_field, MockPGCheckNamed(); name = "milliseconds")
    @test delta.changed == [:checks]

    sql = PormG.Dialect.alter_field(MockPGCheckNamed(), "lap_times", "milliseconds", new_field, old_field, delta)

    @test occursin("DROP CONSTRAINT \"circuits_alt_check\"", sql)
    @test !occursin("ADD CHECK", sql)
    @test !occursin("TYPE", sql)
    @test count(!isempty, split(strip(sql), Char(10))) == 1
  end

  # ───────────────────────────────────────────────────────────────────────────
  # ALTER (Postgres) between the two positive fields: both carry the CHECK, so a
  # smallint <-> integer transition must change only the type — no constraint churn.
  # ───────────────────────────────────────────────────────────────────────────
  @testset "no CHECK churn between positive integer fields" begin
    new_field = Models.PositiveIntegerField()
    old_field = Models.PositiveSmallIntegerField()

    sql = PormG.Dialect.alter_field(MockPGCheckNamed(), "results", "points", new_field, old_field,
                                    _psi_delta(MockPGCheckNamed(), new_field, old_field, [:type]; name = "points"))

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
