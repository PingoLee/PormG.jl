"""
The canonical column IR (#507) — `Migrations.column_spec` and the diff that runs on it.

`makemigrations` used to decide "did this column change?" by comparing two `PormGField` structs, one
of which introspection had RECONSTRUCTED from the live schema through a type map that returns one
struct per rendered type. Struct identity is not column identity, and the gap produced the same bug
seven times: #325, #408, #409, #417, #437, #498, #503. Both sides now compile to a `ColumnSpec` and
the diff is structural equality on that.

The property every testset below is really checking: **two fields that render the same column compile
to the same spec, and two that render different columns do not.** That is what makes the readers'
lossiness stop mattering, and it is true by construction rather than by a lookup table someone has to
maintain, because `column_spec` renders through `Dialect._get_column_type` — the same function the
DDL path uses.

WHAT PHASE 2 CHANGED HERE. The compiler and its guards are unchanged; what moved is the SHAPE of
the answer. Phase 1 handed the typed facets to an `alter_attrs` adapter that translated them back
into the field-attribute symbols the plan actions consumed, and several testsets pinned that
translation. Phase 2 deleted the adapter — every action reads the facets — so those testsets now pin
the facet vocabulary itself. The IR value types also moved to `Kernel` (`src/column_ir.jl`), because
`Dialect.alter_field` renders from a `ColumnDelta` and is included before `Migrations`; the compiler
stayed here, where `Models` and `Dialect` are reachable.

Fully hermetic. `PormGPostgres`/`PormGSQLite` are abstract markers (src/Kernel.jl) and both the
renderer and the compiler dispatch on them alone, so a bare marker struct is a sufficient `conn` for
BOTH engines — no PostgreSQL server, no temp SQLite file. The live-database half is
test/integration/test_migration_bootstrap.jl.

    julia -t auto --project=. test/unit/test_column_spec.jl
"""

using Test
using PormG
using PormG: Migrations
using PormG.Models
using PormG.Dialect: _get_column_type
using PormG.Migrations: ColumnSpec, ForeignKeyRef, ColumnIdentity,
                        NoDefault, LiteralDefault, ExpressionDefault,
                        NonNegativeCheck, ByteLengthCheck,
                        CInt16, CInt32, CInt64, CFloat64, CDecimal, CBool, CText, CVarChar,
                        CDate, CDateTime, CTime, CInterval, CUUID, CJSON, CBytes, CUnsupported,
                        column_spec, column_delta,
                        parse_canonical_type, reference_delta,
                        NON_DB_ATTRS, SCHEMA_ATTRS
# The delta's own vocabulary, and the table it is derived from — Kernel-owned since #507 phase 2,
# because `Dialect.alter_field` renders from a `ColumnDelta` and is included before `Migrations`.
import PormG: ColumnDelta, COLUMN_DELTA_SLOTS, COLUMN_DELTA_COMPARATORS
using InteractiveUtils: subtypes
using Logging

struct MockPgSpec507 <: PormG.PormGPostgres end
struct MockSlSpec507 <: PormG.PormGSQLite end

const PG507 = MockPgSpec507()
const SL507 = MockSlSpec507()

# `Dialect.alter_field` looks up live constraint NAMES before it can drop them. Stubbed so the
# "every emitted symbol survives a real alter_field call" testset can invoke the renderer for real
# without a database — returning a name exercises the DROP branches rather than skipping them.
PormG.get_constraints_pk(::MockPgSpec507, table_name::String, field_name::String) = "t_pkey"
PormG.get_constraints_unique(::MockPgSpec507, table_name::String, field_name::String) = "t_c_key"
PormG.get_constraints_check(::MockPgSpec507, table_name::String, field_name::String) = "t_c_check"
PormG.get_constraints_byte_length_check(::MockPgSpec507, table_name::String, field_name::String) = "t_c_bytes"

# A referential action whose RENDERING explodes, for the fail-safe testset.
#
# Deliberately not a `PormGField` subtype: `subtypes(PormGField)` is walked by `test_db_column.jl`'s
# field-type census, and a throwaway field struct there is a landmine for whichever file happens to
# run first. `sForeignKey.on_delete` is typed `Union{Function, Nothing}`, and a struct may subtype
# `Function` — so this reaches a real slot on a real field without inventing a field type. Every
# other field struct types its `default` too narrowly to hold a foreign value.
struct SpecBoomAction507 <: Function end
Base.print(::IO, ::SpecBoomAction507) = error("on_delete rendering boom (#507 fail-safe probe)")
Base.show(::IO, ::SpecBoomAction507) = error("on_delete rendering boom (#507 fail-safe probe)")

# A foreign key whose `on_delete` cannot be rendered. Assigned after construction so the
# constructor's own validation is not the thing under test.
function _boom_field()
  fk = Models.ForeignKey("Races")
  fk.on_delete = SpecBoomAction507()
  return fk
end

# The corpus every "over all pairs" testset walks. One instance of each shape the planner actually
# meets, including both halves of every pair that has ever churned.
const SPEC_CORPUS = [
  Models.IDField(),
  Models.IntegerField(),
  Models.BigIntegerField(),
  Models.PositiveIntegerField(),
  Models.PositiveSmallIntegerField(),
  Models.CharField(max_length = 40),
  Models.CharField(max_length = 250),
  Models.URLField(max_length = 40),
  Models.SlugField(max_length = 40),
  Models.TextField(),
  Models.EmailField(),
  Models.ImageField(),
  Models.BooleanField(),
  Models.DateField(),
  Models.DateTimeField(),
  Models.TimeField(),
  Models.DurationField(),
  Models.DecimalField(max_digits = 8, decimal_places = 3),
  Models.FloatField(),
  Models.UUIDField(),
  Models.JSONField(),
  Models.BinaryField(max_length = 4),
  Models.BinaryField(),
  Models.ForeignKey("Races"),
  Models.ForeignKey("Races", unique = true),
  Models.ForeignKey("Races", db_constraint = false),
  Models.OneToOneField("Races"),
]

@testset "Canonical column IR (#507)" begin

  # ─────────────────────────────────────────────────────────────────────────────
  # Compiler totality: every field kind compiles on both engines
  # Driven off `subtypes` rather than a hand-written list, so a field type added later shows up here
  # instead of being quietly uncovered. `sManyToManyField` is the one exclusion and it is asserted
  # separately (it declares a join table, not a column).
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "every field kind compiles on both engines" begin
    concrete = filter(T -> isconcretetype(T) && parentmodule(T) === PormG.Models,
                      subtypes(PormG.PormGField))
    @test length(concrete) == 25

    # One constructible instance per struct. Relational types need a target; the bounded ones need
    # their bound. Anything not listed takes its zero-argument constructor.
    instance(T) =
      T === Models.sForeignKey        ? Models.ForeignKey("Races") :
      T === Models.sOneToOneField     ? Models.OneToOneField("Races") :
      T === Models.sManyToManyField   ? Models.ManyToManyField("Races") :
      T === Models.sDecimalField      ? Models.DecimalField(max_digits = 8, decimal_places = 3) :
      getfield(Models, Symbol(String(nameof(T))[2:end]))()

    for T in concrete
      field = instance(T)
      if T === Models.sManyToManyField
        # Not a physical column: refused loudly rather than compiled into a meaningless spec.
        @test_throws PormG.InvalidMigrationError column_spec(field, PG507)
        @test_throws PormG.InvalidMigrationError column_spec(field, SL507)
        continue
      end
      for conn in (PG507, SL507)
        spec = column_spec(field, conn; name = "col")
        # Every declared field type must land on a NAMED canonical type. A `CUnsupported` here would
        # mean PormG renders a type its own parser does not recognise — the degradation path is for
        # foreign schemas, never for PormG's own output.
        @test !(spec.type isa CUnsupported)
        @test spec.name == "col"
        @test spec.raw == _get_column_type(field, conn)
        # Reflexive, and the two slots excluded from equality really are excluded.
        @test spec == column_spec(field, conn; name = "a_completely_different_name")
      end
    end
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # Engine equivalence lives in `parse_canonical_type`, and ONLY there
  # Every collapse is forced by what the renderer writes: two spellings become one canonical type
  # only when PormG renders both as the same string, so the database genuinely cannot tell them
  # apart. Two spellings PormG writes distinctly must stay distinct, or a real declaration change
  # would silently stop being planned.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "engine equivalences are decided in parse, once" begin
    # PostgreSQL keeps integer widths apart; SQLite cannot, because `sqlite_type_map_reverse` maps
    # BOTH "BIGINT" and "INTEGER" onto the literal INTEGER.
    @test parse_canonical_type("integer", PG507) == CInt32()
    @test parse_canonical_type("bigint", PG507)  == CInt64()
    @test parse_canonical_type("INTEGER", SL507) == CInt64()
    @test parse_canonical_type("BIGINT", SL507)  == CInt64()

    # SQLite has no uuid or json type: both render TEXT and read back as text.
    @test parse_canonical_type("TEXT", SL507) == CText()
    @test parse_canonical_type("uuid", PG507) == CUUID()
    @test parse_canonical_type("jsonb", PG507) == CJSON()

    # Case-folded, because PormG's own rendering is not self-consistent: the `else` fallthrough
    # returns the literal "TEXT" while `TextField` goes through the map and returns "text". That
    # inconsistency comparing as a difference is the #325 bug in miniature.
    @test parse_canonical_type("TEXT", PG507) == parse_canonical_type("text", PG507)

    # Parameterized types keep their parameters, and a missing modifier is not defaulted to one.
    @test parse_canonical_type("varchar(120)", PG507) == CVarChar(120)
    @test parse_canonical_type("varchar", PG507) == CVarChar(nothing)
    @test parse_canonical_type("varchar(120)", PG507) != parse_canonical_type("varchar", PG507)
    @test parse_canonical_type("decimal(10, 2)", PG507) == CDecimal(10, 2)
    @test parse_canonical_type("TEXT(40)", SL507) == CVarChar(40)

    # timestamptz vs timestamp is a real distinction on PostgreSQL and no distinction at all on
    # SQLite, where both go through the reverse map to DATETIME.
    @test parse_canonical_type("timestamptz", PG507) == CDateTime(true)
    @test parse_canonical_type("timestamp", PG507)   == CDateTime(false)
    @test parse_canonical_type("timestamptz", PG507) != parse_canonical_type("timestamp", PG507)
    @test parse_canonical_type("DATETIME", SL507) == parse_canonical_type("TIMESTAMP", SL507)

    # NOT collapsed, deliberately. PormG writes "SMALLINT" and "INTEGER UNSIGNED" verbatim on SQLite
    # and `sqlite_type_map` reads both back, so a change between them is observable and must still
    # be planned — even though SQLite gives all three the same INTEGER affinity. The rule is
    # "collapse what the RENDERER makes indistinguishable", not "what the engine stores alike".
    @test parse_canonical_type("SMALLINT", SL507) != parse_canonical_type("INTEGER", SL507)
    @test parse_canonical_type("INTEGER UNSIGNED", SL507) != parse_canonical_type("INTEGER", SL507)

    # The degradation path: an unrecognised type keeps its lower-cased raw string and compares by
    # that — exactly what `Dialect._column_signature` did for EVERY type before #507. So an exotic
    # column loses precision, never correctness, and never aborts `makemigrations`.
    @test parse_canonical_type("tsvector", PG507) == CUnsupported("tsvector")
    @test parse_canonical_type("TSVECTOR", PG507) == CUnsupported("tsvector")
    @test parse_canonical_type("tsvector", PG507) != parse_canonical_type("hstore", PG507)
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # #503 — the issue this PR closes, as a unit test
  # On SQLite a `db_constraint = false` foreign key is introspected as `sIntegerField`, while the
  # planner's #408 escape only recognised `sBigIntegerField`. The pair fell through to a bare
  # `push!(:type)`, which on SQLite means a FULL TABLE REBUILD, on every makemigrations, forever.
  # Under the IR there is nothing to escape: no constraint exists on either side, and both render
  # the same integer column.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "#503: a db_constraint=false foreign key converges on SQLite" begin
    declared = Models.ForeignKey("Migrationtest", on_delete = "CASCADE", db_constraint = false)

    # SQLite reads that column back as sIntegerField (BIGINT and INTEGER are one word here) …
    @test column_spec(declared, SL507) == column_spec(Models.IntegerField(), SL507)
    @test isempty(column_delta(declared, Models.IntegerField(), SL507; name = "test_id"))

    # … and PostgreSQL reads it back as sBigIntegerField. Both converge, which is what #503 asked
    # for ("the escape recognises whatever both readers actually produce").
    @test column_spec(declared, PG507) == column_spec(Models.BigIntegerField(), PG507)
    @test isempty(column_delta(declared, Models.BigIntegerField(), PG507; name = "test_id"))

    # THE REASON, pinned so a future change cannot keep the verdict while losing the mechanism:
    # `db_constraint = false` means no CONSTRAINT exists, so the IR carries no reference at all.
    @test column_spec(declared, SL507).reference === nothing
    @test column_spec(declared, PG507).reference === nothing

    # And the negative control that stops this from being "relational fields equal integers": flip
    # db_constraint back on and the constraint is a difference again.
    constrained = Models.ForeignKey("Migrationtest", on_delete = "CASCADE")
    @test column_spec(constrained, SL507) != column_spec(Models.IntegerField(), SL507)
    @test :reference in column_delta(constrained, Models.IntegerField(), SL507; name = "test_id").changed
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # #437 and #325 — the other pairs that churned
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "#437: ForeignKey(unique=true) and its live OneToOneField are one column" begin
    for conn in (PG507, SL507)
      @test column_spec(Models.ForeignKey("Races", unique = true), conn) ==
            column_spec(Models.OneToOneField("Races"), conn)
      # Not blanket relational equality — the UNIQUE is doing the work.
      @test column_spec(Models.ForeignKey("Races"), conn) != column_spec(Models.OneToOneField("Races"), conn)
    end
  end

  @testset "#325: the CharField / URLField / SlugField family" begin
    for conn in (PG507, SL507)
      for len in (40, 250)
        specs = [column_spec(f, conn) for f in (Models.CharField(max_length = len),
                                                Models.URLField(max_length = len),
                                                Models.SlugField(max_length = len))]
        @test allequal(specs)
      end
      # Different lengths are a real change, reported as `:type` — the IR's type IS the rendered
      # column, so `CVarChar(40)` and `CVarChar(250)` are different types. (Phase 1 reported the
      # narrow `:max_length` here, to keep `alter_field`'s old field-attribute gate firing; phase 2
      # deleted that adapter and the renderer gates on `:type` for every width and precision.)
      @test column_spec(Models.CharField(max_length = 40), conn) !=
            column_spec(Models.CharField(max_length = 250), conn)
      @test column_delta(Models.URLField(max_length = 250), Models.CharField(max_length = 40),
                         conn; name = "url").changed == [:type]
    end
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # Pairs `describes_same_column` used to REFUSE, now answered
  # The retired predicate returned `false` for any relational field and any primary key BEFORE
  # comparing anything. Same verdicts here, but each one now has a reason in the IR — which is what
  # let the FK/O2O pair (#437) and the db_constraint escape (#408/#503) stop needing their own
  # branches.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "a primary key and a relational column are compared, not refused" begin
    for conn in (PG507, SL507)
      # IDField renders exactly what BigIntegerField renders; the identity separates them.
      @test _get_column_type(Models.IDField(), conn) == _get_column_type(Models.BigIntegerField(), conn)
      @test column_spec(Models.IDField(), conn) != column_spec(Models.BigIntegerField(), conn)
      @test column_spec(Models.IDField(), conn).identity !== nothing
      @test column_spec(Models.BigIntegerField(), conn).identity === nothing

      # A constrained key against the plain integer column the database holds.
      @test column_spec(Models.ForeignKey("Races"), conn) != column_spec(Models.BigIntegerField(), conn)
      @test column_spec(Models.ForeignKey("Races"), conn).reference !== nothing
    end

    # Identity is engine-specific and the compiler reads only what the engine can express:
    # PostgreSQL renders GENERATED … AS IDENTITY, SQLite renders PRIMARY KEY AUTOINCREMENT, and
    # neither reads the other's slot. Reading a slot the engine cannot express would manufacture a
    # difference out of a constructor default.
    @test column_spec(Models.IDField(), PG507).identity == ColumnIdentity(true, false, false)
    @test column_spec(Models.IDField(), SL507).identity == ColumnIdentity(false, false, true)
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # ForeignKeyRef: one rule, borrowed rather than copied
  # `reference_delta` must not hold its own copy of "same parent?" — it calls
  # `Models._fk_targets_equal`, the single definition `Models._compare_field_foreign_key` also calls.
  # Two copies drifting apart is the defect class #507 exists to end.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "the foreign-key comparison rule has one definition" begin
    # #390: when BOTH sides name a physical table, compare EXACTLY — case included. PostgreSQL can
    # hold `Driver` and `driver` as two distinct tables in one schema.
    exact_a = ForeignKeyRef("driver", "Driver", "id", "CASCADE")
    exact_b = ForeignKeyRef("Driver", "Driver", "id", "CASCADE")
    @test exact_a != exact_b
    @test reference_delta(exact_a, exact_b) == [:to]

    # The fallback axis: when a side cannot name a physical table (an unresolved String target), the
    # comparison moves to the FOLDED Julia binding, where `uppercasefirst` differences are noise.
    fallback_a = ForeignKeyRef(nothing, "Driver", "id", "CASCADE")
    fallback_b = ForeignKeyRef("driver", "Driver", "id", "CASCADE")
    @test fallback_a == fallback_b

    # Delegation, asserted rather than assumed: the IR and the fast path must agree on every axis.
    @test Models._fk_targets_equal("driver", "Driver", "driver", "Driver")
    @test !Models._fk_targets_equal("driver", "Driver", "Driver", "Driver")
    @test Models._fk_targets_equal(nothing, "Driver", "driver", "Driver")

    # Column and action differences are attributed to their own symbols.
    @test reference_delta(ForeignKeyRef("driver", "Driver", "id", "CASCADE"),
                          ForeignKeyRef("driver", "Driver", "driver_pk", "CASCADE")) == [:pk_field]
    @test reference_delta(ForeignKeyRef("driver", "Driver", "id", "CASCADE"),
                          ForeignKeyRef("driver", "Driver", "id", "SET NULL")) == [:on_delete]

    # `on_delete` is stored RENDERED, through the same function `Models._fk_on_delete_equal` uses —
    # so the pairs that mean one clause fold, and comparing stored values IS that predicate.
    protect = Models.ForeignKey("Races", on_delete = "PROTECT")
    restrict = Models.ForeignKey("Races", on_delete = "RESTRICT")
    @test Models._fk_on_delete_equal(protect, restrict)
    @test column_spec(protect, PG507) == column_spec(restrict, PG507)
    @test column_spec(protect, PG507).reference.on_delete ==
          Models._foreign_key_on_delete_sql(protect.on_delete)

    # …and a genuine action change is still a change (#498).
    cascade = Models.ForeignKey("Races", on_delete = "CASCADE")
    setnull = Models.ForeignKey("Races", on_delete = "SET_NULL")
    # `:reference` is the whole constraint as ONE facet since phase 2 — the planner reads
    # `:add` / `:drop` / `:repoint` off it, and `reference_delta` (asserted above) is what names the
    # part that moved. Phase 1 surfaced the planner's `:on_delete` symbol here so that the pre-IR
    # action code kept working.
    @test column_delta(cascade, setnull, PG507; name = "race_id").changed == [:reference]
    @test reference_delta(column_spec(cascade, PG507).reference,
                          column_spec(setnull, PG507).reference) == [:on_delete]
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # The delta names the FACET that differs — the planner's only input
  #
  # Phase 1 translated these facets back into the field-attribute symbols the action code consumed
  # (`:null`, `:max_length`, `:generated`, `:to`, …) through an `alter_attrs` adapter. #507 phase 2
  # deleted the adapter: `Dialect.alter_field` and the FK helpers read the facets directly, so this
  # vocabulary IS the contract rather than an intermediate representation. One facet per row, and
  # each is asserted as the WHOLE delta so a pair cannot quietly start reporting two things.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "the delta names the facet that differs" begin
    chg(a, b, conn) = column_delta(a, b, conn; name = "c").changed

    @test chg(Models.IntegerField(null = true), Models.IntegerField(), PG507) == [:nullable]
    @test chg(Models.IntegerField(unique = true), Models.IntegerField(), PG507) == [:unique]
    @test chg(Models.CharField(max_length = 40, default = "x"), Models.CharField(max_length = 40), PG507) == [:default]
    @test chg(Models.BigIntegerField(), Models.IntegerField(), PG507) == [:type]

    # A width or precision change is a `:type` change, because the IR's type is the RENDERED column:
    # `CVarChar(40)` vs `CVarChar(250)`, `CDecimal(12,2)` vs `CDecimal(10,2)`. Phase 1 split these
    # into `:max_length` / `:max_digits` / `:decimal_places` for the renderer's benefit; there is one
    # gate now, and the renderer still reads the field for the width it writes.
    @test chg(Models.CharField(max_length = 40), Models.CharField(max_length = 250), PG507) == [:type]
    @test chg(Models.DecimalField(max_digits = 12, decimal_places = 2),
              Models.DecimalField(max_digits = 10, decimal_places = 2), PG507) == [:type]
    @test chg(Models.DecimalField(max_digits = 10, decimal_places = 4),
              Models.DecimalField(max_digits = 10, decimal_places = 2), PG507) == [:type]

    # A CHECK-expressed fact is `:checks`, and on PostgreSQL a positive-integer transition is ONLY
    # that: `IntegerField` and `PositiveIntegerField` both render `integer`. Phase 1 reported `:type`
    # here, which is how a redundant `ALTER COLUMN … TYPE integer` came to ride along with the CHECK.
    @test chg(Models.PositiveIntegerField(), Models.IntegerField(), PG507) == [:checks]
    @test chg(Models.BinaryField(max_length = 8), Models.BinaryField(max_length = 4), PG507) == [:checks]

    # The whole foreign-key constraint is ONE facet. It opens the alteration gate (a moved key IS a
    # column change on SQLite, where the table is rebuilt) while `alter_field` has no branch for it
    # — which is what retired the `_FK_IDENTITY_ATTRS` filter: a slot with no branch renders nothing,
    # and `_fk_constraint_action` renders it as DROP + ADD CONSTRAINT instead.
    @test chg(Models.ForeignKey("Races"), Models.ForeignKey("Drivers"), PG507) == [:reference]
    @test chg(Models.ForeignKey("Races", on_delete = "CASCADE"),
              Models.ForeignKey("Drivers", on_delete = "SET_NULL"), PG507) == [:reference]

    # And every facet a delta can carry is one the closed set declares — the property that let
    # `alter_field` drop its allowlist and its "not implemented" warning.
    for (a, b) in Iterators.product(SPEC_CORPUS, SPEC_CORPUS)
      for conn in (PG507, SL507)
        @test all(f -> f in COLUMN_DELTA_SLOTS, column_delta(a, b, conn; name = "c").changed)
      end
    end
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # No delta the compiler can produce makes the renderer choke
  #
  # THE ORACLE IS `alter_field` ITSELF, not a copy of its allowlist. An earlier version of this
  # testset compared the emitted symbols against a hand-transcribed `IMPLEMENTED` list, and it
  # passed while the diff was emitting `:generated` for a declared `BigIntegerField` over a live
  # identity column — `:generated` IS on that list, but `alter_field` read `new_field.generated` and
  # only `sIDField` has the slot, so the call raised a `FieldError` and killed the whole
  # `makemigrations`. Membership was the wrong property; being CALLABLE is the right one. Found by
  # review, and this is the shape of test that would have caught it.
  #
  # #507 phase 2 removed the list this was paired with, and with it the last reason to check
  # membership at all: `ColumnDelta` validates every facet against `COLUMN_DELTA_SLOTS` at
  # construction, so an unknown facet cannot reach the renderer — it raises at the delta. What is
  # left is the half that was always load-bearing: 729 real pairs, through the real renderer, on the
  # real corpus. Slot COVERAGE (each facet reaching a statement) is asserted in
  # `test_plan_actions_golden.jl`, which walks `COLUMN_DELTA_SLOTS` and reads the SQL back.
  #
  # PostgreSQL only, deliberately: SQLite's `alter_field` ignores the delta entirely and rebuilds
  # from the model (`src/Dialect.jl` — the parameter appears in its signature and nowhere in its
  # body), so invoking it would assert nothing about the facets. The SQLite half is covered instead
  # by the last assertion here, and by the golden plan corpus.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "every delta the compiler produces survives a real alter_field call" begin
    for (a, b) in Iterators.product(SPEC_CORPUS, SPEC_CORPUS)
      delta = column_delta(a, b, PG507; name = "c")
      isempty(delta) && continue
      # No exception, and no warning — the renderer's own verdict on whether it can express what the
      # compiler reported. The FULL delta is handed over, `:reference` included: phase 1 had to
      # filter that facet out first, and needing no filter is the point of the change.
      @test_logs min_level = Logging.Warn PormG.Dialect.alter_field(PG507, "t", "c", a, b, delta)
    end

    # The one facet with no rendering branch must also be the only one that renders NOTHING — that
    # is what makes "a slot with no branch is harmless" true rather than hopeful. A reference-only
    # delta returns "" and `_configure_order_dict_migration_plan` drops the step; the constraint is
    # planned by `_fk_constraint_action` instead.
    ref_only = 0
    for (a, b) in Iterators.product(SPEC_CORPUS, SPEC_CORPUS)
      delta = column_delta(a, b, PG507; name = "c")
      delta.changed == [:reference] || continue
      ref_only += 1
      @test PormG.Dialect.alter_field(PG507, "t", "c", a, b, delta) == ""
    end
    # Guard the guard: a corpus that produced no reference-only pair would pass the loop vacuously.
    @test ref_only > 0

    # SQLite's identity facet is reachable (`PRIMARY KEY AUTOINCREMENT`) and PostgreSQL's is a
    # different fact (`GENERATED … AS IDENTITY`), so the same pair can differ per engine. Both are
    # inside the closed set, which is the only property either renderer relies on.
    for conn in (PG507, SL507)
      for (a, b) in Iterators.product(SPEC_CORPUS, SPEC_CORPUS)
        @test all(f -> f in COLUMN_DELTA_SLOTS, column_delta(a, b, conn; name = "c").changed)
      end
    end
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # …and the ORDER of those statements, which "does it raise" cannot see
  #
  # PostgreSQL restricts an identity column to smallint / integer / bigint and enforces it DURING
  # `ALTER COLUMN … TYPE`. So `TYPE uuid` emitted before `DROP IDENTITY` is accepted by every check
  # above — it neither raises nor warns — and then fails on the database with *"identity column type
  # must be smallint, integer, or bigint"*. The testset above is blind to it by construction: its
  # oracle is that the call SUCCEEDS, not that the statements it returns are executable in sequence.
  #
  # Reachable shape: a models file declaring a natural key over a column introspection reports as
  # `IDField`, which is every non-UUID primary key. Found by review, after the raise it replaced.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "an identity is dropped BEFORE the column is retyped" begin
    for declared in (Models.UUIDField(primary_key = true),
                     Models.CharField(max_length = 40, primary_key = true))
      live = Models.IDField()
      delta = column_delta(declared, live, PG507; name = "c")
      @test :identity in delta
      @test :type in delta

      lines = split(strip(PormG.Dialect.alter_field(PG507, "t", "c", declared, live, delta)), string(Char(10)))
      type_at = findfirst(l -> occursin("TYPE", l), lines)
      drop_at = findfirst(l -> occursin("DROP IDENTITY", l), lines)
      @test type_at !== nothing
      @test drop_at !== nothing
      @test drop_at < type_at
    end

    # The mirror direction must stay AFTER the type change: a column can only BECOME an identity
    # once it is already an integer type. Diffed rather than hand-named, so the pair really does
    # report both facets.
    add_delta = column_delta(Models.IDField(), Models.CharField(max_length = 40), PG507; name = "c")
    @test :identity in add_delta && :type in add_delta
    lines = split(strip(PormG.Dialect.alter_field(PG507, "t", "c", Models.IDField(),
                                                  Models.CharField(max_length = 40), add_delta)), string(Char(10)))
    add_at = findfirst(l -> occursin("ADD GENERATED", l), lines)
    type_at = findfirst(l -> occursin("TYPE", l), lines)
    @test add_at !== nothing && type_at !== nothing
    @test type_at < add_at
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # THE DRIFT GUARD
  # The classification lives in one place now, and this is what keeps it honest: every slot of every
  # concrete field struct must be classified as either read-by-the-compiler or not-a-database-fact.
  # A new field slot that is neither fails here — instead of silently becoming a column difference
  # nobody meant, which is how `auto_add` (#334) and `to_table` (#360) each cost an issue.
  #
  # Same guarantee `fixtures/field_kwargs_snapshot.txt` gives `Model_to_str`, with no snapshot to
  # regenerate: the invariant is derived from the types themselves.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "no PormGField slot escapes classification" begin
    classified = union(Set(NON_DB_ATTRS), Set(SCHEMA_ATTRS))

    # The two halves are a partition, not two overlapping lists: a slot in both would mean the
    # classification does not actually decide anything.
    @test isempty(intersect(Set(NON_DB_ATTRS), Set(SCHEMA_ATTRS)))

    unclassified = Dict{Symbol, Vector{Symbol}}()
    for T in filter(T -> isconcretetype(T) && parentmodule(T) === PormG.Models,
                    subtypes(PormG.PormGField))
      gaps = [s for s in fieldnames(T) if !(s in classified)]
      isempty(gaps) || (unclassified[nameof(T)] = gaps)
    end
    if !isempty(unclassified)
      @error """
      A PormGField slot is neither read by `column_spec` nor listed as a non-database attribute.

      Classify it in `src/migrations/column_spec.jl`: `SCHEMA_ATTRS` if the compiler should read it
      (and then make it read it), `NON_DB_ATTRS` if no DDL path expresses it. Leaving it out means
      the migration diff silently ignores it.
      """ unclassified
    end
    @test isempty(unclassified)

    # Guard the guard: an empty or mis-scoped walk would pass the check above vacuously.
    @test length(classified) >= 30
    @test :db_index in NON_DB_ATTRS      # owned by index_actions; see the ColumnSpec docstring
    @test :on_delete in SCHEMA_ATTRS     # decision 3 of #507
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # THE SPEED PATH IS GONE, and its conservativeness test with it
  #
  # A testset here used to assert that `Models._compare_model_field` — the whole-model early-out
  # `_alter_table_fields` consulted before its diff loop — could only ever answer "equal" when the
  # IR agreed, so it could skip work but never suppress a real change. That was the licence for
  # keeping a second comparator through phase 1.
  #
  # #507 phase 2 retired the early-out, so the licence is not needed and the test would have nothing
  # to compare: `_alter_table_fields` always runs its per-column loop, and an empty `ColumnDelta` is
  # the "nothing changed" answer. The three pairs it exercised were the ones where two comparators
  # could most plausibly disagree — a genuine `on_delete` change, a `PROTECT`/`RESTRICT` fold, and a
  # `:to` pair with a resolved model on one side and a binding string on the other. All three are
  # still covered, as claims about the IR alone, in "the foreign-key comparison rule has one
  # definition" above and in `test_fk_rename_rebuild.jl`.
  # ─────────────────────────────────────────────────────────────────────────────

  # ─────────────────────────────────────────────────────────────────────────────
  # Fail SAFE, not open (#69) — restated on the IR path
  # A schema diff must never answer "equal" because something threw: "equal" means "no change", so a
  # real change whose comparison raised would be dropped with no migration generated. The fast path
  # has carried this rule since #69, but `_alter_table_fields` has no `catch` of its own and the IR
  # now does strictly more work per column than the attribute loop it replaced.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "a raising comparison reports CHANGED, with a warning" begin
    boom_a, boom_b = _boom_field(), _boom_field()

    # The premise: compiling this field really does throw, from inside `_column_reference` where the
    # referential action is rendered.
    @test_throws ErrorException column_spec(boom_a, PG507)

    # The rule: changed, not equal — and audibly. `column_delta` degrades the uncompilable side to a
    # `CUnsupported` marker, which can never equal a rendered type, so the ordinary diff reports
    # `:type`. That is the same answer phase 1 returned as a bare `[:type]` vector; what changed is
    # that the actions now get SPECS on this path too, which they need since they read the delta.
    # The full contract, including the two-failing-sides case, is `test_migration_diff_failsafe.jl`.
    result = @test_logs (:warn,) match_mode = :any column_delta(boom_a, boom_b, PG507; name = "boom")
    @test !isempty(result)
    @test result.changed == [:type]

    # An ordinary pair does not warn, so the guard above is not passing on background noise.
    @test_logs min_level = Logging.Warn column_delta(Models.IntegerField(),
                                                     Models.IntegerField(), PG507; name = "n")
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # Decision 6: classified non-schema, but never silent
  # `on_update` / `deferrable` / `initially_deferred` are declared API no renderer emits, so they
  # cannot be a schema delta — before #507 a declared `deferrable = true` churned an empty ALTER on
  # PostgreSQL and a full rebuild on SQLite, forever. Dropping a declared intent WITHOUT a report is
  # the shape #501 just closed in the importer, so the compiler says so once.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "unrendered foreign-key options converge, and are reported" begin
    plain = Models.ForeignKey("Races", on_delete = "CASCADE")
    deferred = Models.ForeignKey("Races", on_delete = "CASCADE", deferrable = true)

    for attr in (:on_update, :deferrable, :initially_deferred)
      @test attr in NON_DB_ATTRS
    end

    # They converge: no churn.
    for conn in (PG507, SL507)
      @test column_spec(plain, conn) == column_spec(deferred, conn)
      @test isempty(column_delta(plain, deferred, conn; name = "race_id"))
    end

    # And the declaration is reported rather than dropped in silence. `maxlog` means the warning is
    # once per session, so this asserts the message exists rather than counting occurrences.
    @test_logs (:warn, r"does not render") match_mode = :any column_spec(
      Models.ForeignKey("Races", on_delete = "CASCADE", initially_deferred = true), PG507)
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # Value-type shapes: the small pieces the diff is built from
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "the IR value types compare as intended" begin
    # `NoDefault` is not `LiteralDefault(nothing)`, and a literal compares by value.
    @test NoDefault() == NoDefault()
    @test LiteralDefault(5) == LiteralDefault(5)
    @test LiteralDefault(5) != NoDefault()
    # `isequal`, not `==`: a `missing` default would make `==` return `missing`, and `if missing`
    # throws. The pre-#507 attribute loop had no `catch` around its `!=`, so this closes a crash
    # path rather than inheriting it.
    @test LiteralDefault(missing) == LiteralDefault(missing)
    @test !(LiteralDefault(missing) == LiteralDefault(1))

    # ExpressionDefault is unreachable from `column_spec` today — no PormGField can spell one — and
    # exists so #496's `db_default` is a pure addition here rather than a re-shaping. Covered so it
    # cannot rot while it waits.
    @test ExpressionDefault("now()") == ExpressionDefault("now()")
    @test ExpressionDefault("now()") != ExpressionDefault("gen_random_uuid()")
    @test ExpressionDefault("now()") != NoDefault()

    @test NonNegativeCheck() == NonNegativeCheck()
    @test ByteLengthCheck(8) != ByteLengthCheck(16)
    @test ColumnIdentity(true, false, false) != ColumnIdentity(true, true, false)

    # The checks vector is built in a fixed order, so plain `==` on it is a set comparison in
    # practice — asserted rather than assumed, since nothing else would catch a reordering.
    @test column_spec(Models.PositiveIntegerField(), PG507).checks == [NonNegativeCheck()]
    @test column_spec(Models.BinaryField(max_length = 8), PG507).checks == [ByteLengthCheck(8)]
    @test isempty(column_spec(Models.IntegerField(), PG507).checks)

    # `column_delta` names the FACET, and since phase 2 the actions consume those names directly —
    # there is no adapter left to translate them into anything else, so this vocabulary is the
    # contract.
    a = column_spec(Models.IntegerField(null = true), PG507)
    b = column_spec(Models.IntegerField(), PG507)
    @test column_delta(a, b) == [:nullable]
    # And the delta the planner passes around wraps both specs with that facet list, validated
    # against the closed set at construction.
    wrapped = ColumnDelta(a, b, column_delta(a, b))
    @test wrapped.changed == [:nullable]
    @test :nullable in wrapped
    @test !isempty(wrapped)
  end
end
