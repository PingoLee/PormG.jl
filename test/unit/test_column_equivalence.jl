"""
Unit coverage for physical-column identity — whether two `PormGField`s describe the same column, the
question the migration planner asks in place of Julia struct identity (#325).

Several field types materialize the SAME column, and introspection cannot tell them apart because the
information is not in the schema to read: PostgreSQL renders `CharField`, `URLField` and `SlugField`
all as `varchar(n)`, and SQLite collapses `UUIDField`, `JSONField`, `ImageField` and `TextField` all
onto bare `TEXT`. Demanding struct identity therefore proposed an ALTER whose SQL re-rendered the
column unchanged, on every single `makemigrations` — on SQLite as the full
`CREATE new → INSERT SELECT → DROP old → RENAME` rebuild.

RETARGETED BY #507, deliberately, and the diff is worth reading rather than skimming. This file used
to test `Dialect.describes_same_column`, a predicate that answered the question for the cross-type
case ONLY: it refused every relational field and every primary key outright, because it compared a
rendered type string plus two CHECK bounds and could not express their identity. That predicate is
gone, along with the two other comparators and the escape hatch that had to cover what it refused.
Both sides of the diff now compile to a `Migrations.ColumnSpec` and the answer is structural equality
on that.

Every case below survived the move, with ONE inversion, called out at its assertion: a declared
`ForeignKey(unique = true)` against the live `sOneToOneField` its own column reads back as is now
**equal**, where this file asserted `false`. That `false` was never a statement about the column — it
was the blanket refusal firing — and the planner's attribute-wise branch already concluded "equal"
for that exact pair (#437). One comparator cannot hold both answers, and the equal one is correct.
The four genuine refusals stay `false` and now say WHY (`reference`, `identity` or `primary_key`
differs) rather than declining to look.

Fully hermetic: `_get_column_type` and `column_spec` dispatch on the abstract backend marker and
never touch connection state, so a bare marker struct is a sufficient `conn`. The live-database half
is test/integration/test_migration_bootstrap.jl.
"""

using Test
using PormG
using PormG.Models
using PormG.Dialect: _get_column_type
using PormG.Migrations: column_spec, column_delta

# `PormGPostgres`/`PormGSQLite` are abstract backend markers (src/Kernel.jl); dialect rendering
# dispatches on them alone. Same mock pattern as test/unit/test_alter_field_constraint_drops.jl.
struct MockPg325 <: PormG.PormGPostgres end
struct MockSQLite325 <: PormG.PormGSQLite end

const PG325 = MockPg325()
const SL325 = MockSQLite325()

# The question this file is about, in one place. `column_spec` equality excludes `name` and `raw` by
# construction, so this is exactly "do these two describe the same physical column".
same_column(conn, a::PormG.PormGField, b::PormG.PormGField) = column_spec(a, conn) == column_spec(b, conn)

@testset "Physical-column identity (ColumnSpec, #325/#507)" begin

  # ───────────────────────────────────────────────────────────────────────────
  # The premise: the VARCHAR family really is one column on PostgreSQL
  # If these rendering assertions ever stop holding, the equivalences below stop being safe rather
  # than merely stop being useful — so they are pinned first, not assumed. They matter MORE under
  # #507 than before: `column_spec` parses the output of `_get_column_type`, so these strings are
  # literally the compiler's input.
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
  @testset "PostgreSQL varchar and text families" begin
    @test same_column(PG325, Models.URLField(max_length = 500), Models.CharField(max_length = 500))
    @test same_column(PG325, Models.SlugField(max_length = 120), Models.CharField(max_length = 120))
    @test same_column(PG325, Models.ImageField(), Models.TextField())
    @test same_column(PG325, Models.FileField(), Models.TextField())

    # Negative controls — a real difference must still be reported.
    @test !same_column(PG325, Models.URLField(max_length = 500), Models.CharField(max_length = 250))
    @test !same_column(PG325, Models.CharField(max_length = 250), Models.TextField())
    @test !same_column(PG325, Models.JSONField(), Models.TextField())    # jsonb vs text
    @test !same_column(PG325, Models.UUIDField(), Models.CharField())    # uuid vs varchar
    @test !same_column(PG325, Models.BinaryField(), Models.TextField())  # bytea vs text

    # A length-only change is a `:type` delta, because the IR's type IS the rendered column:
    # `CVarChar(250)` and `CVarChar(120)` are different types. Phase 1 reported the narrow
    # `:max_length` here, purely so `Dialect.alter_field`'s char branch — which gated on the
    # field-attribute name — kept firing; #507 phase 2 deleted that adapter and the renderer now
    # gates on `:type` for every width, precision and outright type change alike.
    @test column_delta(Models.CharField(max_length = 250), Models.CharField(max_length = 120),
                       PG325; name = "code").changed == [:type]
  end

  # ───────────────────────────────────────────────────────────────────────────
  # SQLite: a much wider collapse
  # `sqlite_type_map_reverse` sends UUID, JSONB and JSON all to `TEXT`, so a UUID column and a JSON
  # column are indistinguishable in the schema — introspection reports both as one struct.
  # ───────────────────────────────────────────────────────────────────────────
  @testset "SQLite TEXT collapse" begin
    @test same_column(SL325, Models.UUIDField(), Models.TextField())
    @test same_column(SL325, Models.JSONField(), Models.TextField())
    @test same_column(SL325, Models.ImageField(), Models.TextField())
    @test same_column(SL325, Models.URLField(max_length = 500), Models.CharField(max_length = 500))

    # Negative controls: TEXT(n) is not bare TEXT, and BLOB is a different storage class.
    @test !same_column(SL325, Models.JSONField(), Models.CharField(max_length = 250))
    @test !same_column(SL325, Models.CharField(max_length = 120), Models.CharField(max_length = 250))
    @test !same_column(SL325, Models.BinaryField(), Models.TextField())
  end

  # ───────────────────────────────────────────────────────────────────────────
  # The CHECK-expressed bounds are part of the column
  # Two facts neither backend can put in the type itself, so a signature built from the type string
  # alone would call two different columns the same.
  # ───────────────────────────────────────────────────────────────────────────
  @testset "CHECK-expressed bounds are part of the column" begin
    # PostgreSQL has no unsigned integer: both render `integer`, and only the `>= 0` CHECK differs.
    @test _get_column_type(Models.IntegerField(), PG325) == _get_column_type(Models.PositiveIntegerField(), PG325)
    @test !same_column(PG325, Models.IntegerField(), Models.PositiveIntegerField())

    # BinaryField's max_length is a BYTE bound expressed only as a CHECK (#296): neither `bytea` nor
    # `BLOB` takes a length parameter, so the rendered types are identical and the bound is not.
    @test _get_column_type(Models.BinaryField(max_length = 8), SL325) == _get_column_type(Models.BinaryField(), SL325)
    @test !same_column(SL325, Models.BinaryField(max_length = 8), Models.BinaryField())
    @test !same_column(PG325, Models.BinaryField(max_length = 8), Models.BinaryField(max_length = 16))

    # A CHECK-expressed bound is the `:checks` facet, and on PostgreSQL that is ALL it is: both
    # `IntegerField` and `PositiveIntegerField` render `integer`, so the type did not change and
    # `alter_field` emits the CHECK alone. Phase 1 reported `:type` / `:max_length` here because its
    # adapter had to name a symbol the renderer's old field-attribute gates recognised — which is
    # exactly how a redundant `ALTER COLUMN … TYPE integer` came to ride along with the CHECK.
    @test column_delta(Models.PositiveIntegerField(), Models.IntegerField(), PG325; name = "n").changed == [:checks]
    @test column_delta(Models.BinaryField(max_length = 16), Models.BinaryField(max_length = 8),
                       PG325; name = "blob").changed == [:checks]
  end

  # ───────────────────────────────────────────────────────────────────────────
  # The relational / primary-key guard rail — same verdicts, stated reasons
  # `sForeignKey` and `sBigIntegerField` both render `bigint`. Calling them the same column would
  # silently stop planning FK add/drop on an existing column, because
  # `_add_fk_constraint_in_alteration` runs only for a field the diff already flagged as changed.
  #
  # #507 changed how these verdicts are reached. `describes_same_column` returned `false` for ANY
  # relational field or primary key before comparing anything — a refusal, not an answer, and one
  # that also swallowed the #437 pair below. `ColumnSpec` carries `reference`, `identity` and
  # `primary_key`, so each verdict below now has a reason, asserted alongside it.
  # ───────────────────────────────────────────────────────────────────────────
  @testset "a constrained foreign key is not a plain integer column" begin
    @test _get_column_type(Models.ForeignKey("Races"), PG325) == _get_column_type(Models.BigIntegerField(), PG325)
    @test !same_column(PG325, Models.ForeignKey("Races"), Models.BigIntegerField())
    @test !same_column(PG325, Models.BigIntegerField(), Models.ForeignKey("Races"))
    @test !same_column(SL325, Models.ForeignKey("Races"), Models.IntegerField())
    # The reason, not just the verdict: the constraint is what differs.
    @test column_spec(Models.ForeignKey("Races"), PG325).reference !== nothing
    @test column_spec(Models.BigIntegerField(), PG325).reference === nothing

    # IDField renders `bigint` on PostgreSQL exactly like BigIntegerField; the identity and the key
    # flags are what separate them.
    @test !same_column(PG325, Models.IDField(), Models.BigIntegerField())
    @test column_spec(Models.IDField(), PG325).identity !== nothing
    @test column_spec(Models.BigIntegerField(), PG325).identity === nothing

    @test !same_column(PG325, Models.CharField(max_length = 50, primary_key = true), Models.SlugField(max_length = 50))
    @test column_spec(Models.CharField(max_length = 50, primary_key = true), PG325).primary_key
    @test !column_spec(Models.SlugField(max_length = 50), PG325).primary_key
  end

  # ───────────────────────────────────────────────────────────────────────────
  # THE INVERSION (#437 via #507) — read the file docstring before changing this
  #
  # This assertion used to read `!describes_same_column(conn, ForeignKey(unique=true), OneToOneField)`
  # on both backends, and the comment beside it explained that #437's pair was reconciled one branch
  # EARLIER in the planner instead, so this predicate deliberately kept refusing it.
  #
  # There is no "earlier branch" any more. The two spellings render byte-identical DDL, BOTH schema
  # readers report a UNIQUE non-key foreign key as `sOneToOneField` since #417, and the planner's
  # attribute-wise branch already answered "equal" for the pair. With one comparator the two answers
  # cannot both stand, and "equal" is the true one — a `bigint` column, UNIQUE, constrained against
  # the same parent with the same action, is one column however it was spelled in Julia.
  # ───────────────────────────────────────────────────────────────────────────
  @testset "ForeignKey(unique=true) and OneToOneField ARE one column (#437)" begin
    for conn in (PG325, SL325)
      @test same_column(conn, Models.ForeignKey("Races", unique = true), Models.OneToOneField("Races"))
      @test same_column(conn, Models.OneToOneField("Races"), Models.ForeignKey("Races", unique = true))
      @test isempty(column_delta(Models.ForeignKey("Races", unique = true),
                                 Models.OneToOneField("Races"), conn; name = "race_id"))
    end

    # Not a blanket "relational fields are equal": drop the UNIQUE and they are two columns again.
    for conn in (PG325, SL325)
      @test !same_column(conn, Models.ForeignKey("Races"), Models.OneToOneField("Races"))
      @test :unique in column_delta(Models.ForeignKey("Races"), Models.OneToOneField("Races"),
                                    conn; name = "race_id")
    end
  end

  # ───────────────────────────────────────────────────────────────────────────
  # Symmetry and reflexivity
  # The planner calls this with (declared, live); nothing should depend on that order.
  # ───────────────────────────────────────────────────────────────────────────
  @testset "the comparison is symmetric and reflexive" begin
    for conn in (PG325, SL325)
      for (a, b) in ((Models.URLField(max_length = 500), Models.CharField(max_length = 500)),
                     (Models.ImageField(), Models.TextField()),
                     (Models.JSONField(), Models.TextField()),
                     (Models.IntegerField(), Models.PositiveIntegerField()),
                     (Models.ForeignKey("Races", unique = true), Models.OneToOneField("Races")),
                     (Models.IDField(), Models.BigIntegerField()))
        @test same_column(conn, a, b) == same_column(conn, b, a)
      end
      @test same_column(conn, Models.TextField(), Models.TextField())
      @test same_column(conn, Models.ForeignKey("Races"), Models.ForeignKey("Races"))
    end
  end
end
