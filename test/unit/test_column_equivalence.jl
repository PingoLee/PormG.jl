"""
Unit coverage for `Dialect.describes_same_column` — the physical-column identity predicate the
migration planner uses in place of Julia struct identity (#325).

Several field types materialize the SAME column, and introspection cannot tell them apart because
the information is not in the schema to read: PostgreSQL renders `CharField`, `URLField` and
`SlugField` all as `varchar(n)`, and SQLite collapses `UUIDField`, `JSONField`, `ImageField` and
`TextField` all onto bare `TEXT`. Demanding struct identity therefore proposed an ALTER whose SQL
re-rendered the column unchanged, on every single `makemigrations` — on SQLite as the full
`CREATE new → INSERT SELECT → DROP old → RENAME` rebuild.

Fully hermetic: `_get_column_type` dispatches on the abstract backend marker and never touches
connection state, so a bare marker struct is a sufficient `conn`. The live-database half is
test/integration/test_migration_bootstrap.jl.
"""

using Test
using PormG
using PormG.Models
using PormG.Dialect: describes_same_column, _get_column_type

# `PormGPostgres`/`PormGSQLite` are abstract backend markers (src/Kernel.jl); dialect rendering
# dispatches on them alone. Same mock pattern as test/unit/test_alter_field_constraint_drops.jl.
struct MockPg325 <: PormG.PormGPostgres end
struct MockSQLite325 <: PormG.PormGSQLite end

const PG325 = MockPg325()
const SL325 = MockSQLite325()

@testset "Physical-column identity (describes_same_column, #325)" begin

  # ───────────────────────────────────────────────────────────────────────────
  # The premise: the VARCHAR family really is one column on PostgreSQL
  # If these rendering assertions ever stop holding, the equivalences below stop being safe rather
  # than merely stop being useful — so they are pinned first, not assumed.
  # ───────────────────────────────────────────────────────────────────────────
  @testset "the rendered types this rests on" begin
    @test _get_column_type(Models.CharField(max_length = 500), PG325) == "varchar(500)"
    @test _get_column_type(Models.URLField(max_length = 500), PG325)  == "varchar(500)"
    @test _get_column_type(Models.SlugField(max_length = 120), PG325) == "varchar(120)"
    # SQLite has no varchar: the whole family renders TEXT(n), and the lengthless types bare TEXT.
    @test _get_column_type(Models.CharField(max_length = 120), SL325) == "TEXT(120)"
    @test _get_column_type(Models.UUIDField(), SL325)                 == "TEXT"
    @test _get_column_type(Models.JSONField(), SL325)                 == "TEXT"
    @test _get_column_type(Models.TextField(), SL325)                 == "TEXT"
  end

  # ───────────────────────────────────────────────────────────────────────────
  # PostgreSQL: the pairs that were churning
  # `canonical_url = URLField(max_length=500)` introspects as `CharField(500)` — the same
  # `varchar(500)` column. `photo = ImageField()` renders `text` (no `_get_column_type` branch) and
  # introspects as `TextField`, also the same column.
  # ───────────────────────────────────────────────────────────────────────────
  @testset "PostgreSQL: varchar and text families are each one column" begin
    @test describes_same_column(PG325, Models.URLField(max_length = 500), Models.CharField(max_length = 500))
    @test describes_same_column(PG325, Models.SlugField(max_length = 120), Models.CharField(max_length = 120))
    @test describes_same_column(PG325, Models.ImageField(), Models.TextField())
    @test describes_same_column(PG325, Models.FileField(), Models.TextField())

    # A DIFFERENT length is a different column and must still be planned.
    @test !describes_same_column(PG325, Models.URLField(max_length = 500), Models.CharField(max_length = 250))
    # varchar is not text: PostgreSQL keeps them apart, so PormG must too.
    @test !describes_same_column(PG325, Models.CharField(max_length = 250), Models.TextField())
    # …and the types PostgreSQL DOES round-trip faithfully stay distinct.
    @test !describes_same_column(PG325, Models.JSONField(), Models.TextField())    # jsonb vs text
    @test !describes_same_column(PG325, Models.UUIDField(), Models.CharField())    # uuid vs varchar
    @test !describes_same_column(PG325, Models.BinaryField(), Models.TextField())  # bytea vs text
  end

  # ───────────────────────────────────────────────────────────────────────────
  # SQLite: the collapse is wider, and that is CORRECT — the column really is identical
  # A UUIDField and a JSONField are byte-for-byte the same SQLite column, so switching one for the
  # other is genuinely a no-op schema change. What must NOT collapse is a length difference.
  # ───────────────────────────────────────────────────────────────────────────
  @testset "SQLite: the lengthless textual types are one column" begin
    @test describes_same_column(SL325, Models.UUIDField(), Models.TextField())
    @test describes_same_column(SL325, Models.JSONField(), Models.TextField())
    @test describes_same_column(SL325, Models.ImageField(), Models.TextField())
    @test describes_same_column(SL325, Models.URLField(max_length = 500), Models.CharField(max_length = 500))

    # A sized column is not a lengthless one — this is the pair the SQLite half of #325 was ABOUT.
    # Before the introspection fix a bare `TEXT` read back as `CharField(250)`, i.e. `TEXT(250)`,
    # and never matched the `TEXT` the model rendered.
    @test !describes_same_column(SL325, Models.JSONField(), Models.CharField(max_length = 250))
    @test !describes_same_column(SL325, Models.CharField(max_length = 120), Models.CharField(max_length = 250))
    # BLOB is a real storage class on SQLite and stays distinct from TEXT.
    @test !describes_same_column(SL325, Models.BinaryField(), Models.TextField())
  end

  # ───────────────────────────────────────────────────────────────────────────
  # The CHECK-expressed bounds are part of the column, not decoration
  # `_get_column_type` alone would call these pairs equal: PostgreSQL renders a PositiveIntegerField
  # as plain `integer` (it has no unsigned type) and distinguishes it only by a `>= 0` CHECK, and a
  # BinaryField's byte bound is a CHECK too because `bytea`/`BLOB` take no length parameter.
  # ───────────────────────────────────────────────────────────────────────────
  @testset "CHECK-expressed bounds count as part of the column" begin
    @test _get_column_type(Models.IntegerField(), PG325) == _get_column_type(Models.PositiveIntegerField(), PG325)
    @test !describes_same_column(PG325, Models.IntegerField(), Models.PositiveIntegerField())

    # Two BinaryFields with different byte bounds render identically but are not the same column.
    # (Same struct type, so the planner would compare them attribute-wise anyway — this pins the
    # predicate itself, which is what a future caller would rely on.)
    @test !describes_same_column(SL325, Models.BinaryField(max_length = 8), Models.BinaryField())
    @test !describes_same_column(PG325, Models.BinaryField(max_length = 8), Models.BinaryField(max_length = 16))
  end

  # ───────────────────────────────────────────────────────────────────────────
  # The relational / primary-key guard rail
  # `sForeignKey` and `sBigIntegerField` both render `bigint`. Calling them the same column would
  # silently stop planning FK add/drop on an existing column, because
  # `_add_fk_constraint_in_alteration` runs only for a field the diff already flagged as changed.
  # Same for a primary key, whose identity is not carried by the column type either.
  # ───────────────────────────────────────────────────────────────────────────
  @testset "relational fields and primary keys are never 'the same column'" begin
    @test _get_column_type(Models.ForeignKey("Races"), PG325) == _get_column_type(Models.BigIntegerField(), PG325)
    @test !describes_same_column(PG325, Models.ForeignKey("Races"), Models.BigIntegerField())
    @test !describes_same_column(PG325, Models.BigIntegerField(), Models.ForeignKey("Races"))
    @test !describes_same_column(SL325, Models.ForeignKey("Races"), Models.IntegerField())

    # IDField renders `bigint` on PostgreSQL exactly like BigIntegerField.
    @test !describes_same_column(PG325, Models.IDField(), Models.BigIntegerField())
    @test !describes_same_column(PG325, Models.CharField(max_length = 50, primary_key = true), Models.SlugField(max_length = 50))
  end

  # ───────────────────────────────────────────────────────────────────────────
  # Symmetry and reflexivity
  # The planner calls this with (declared, live); nothing should depend on that order.
  # ───────────────────────────────────────────────────────────────────────────
  @testset "the predicate is symmetric and reflexive" begin
    for conn in (PG325, SL325)
      for (a, b) in ((Models.URLField(max_length = 500), Models.CharField(max_length = 500)),
                     (Models.ImageField(), Models.TextField()),
                     (Models.JSONField(), Models.TextField()),
                     (Models.IntegerField(), Models.PositiveIntegerField()))
        @test describes_same_column(conn, a, b) == describes_same_column(conn, b, a)
      end
      @test describes_same_column(conn, Models.TextField(), Models.TextField())
    end
  end
end
