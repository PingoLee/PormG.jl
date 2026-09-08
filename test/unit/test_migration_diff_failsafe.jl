"""
Unit coverage for the migration-diff FAIL-SAFE contract (#69).

If comparing two model fields *throws*, the diff must treat the column as **changed** — so a
migration is generated — and never fall through to "equal". Reporting "equal" on an error means "no
change", which silently drops a needed migration and corrupts the schema contract.

Before the #69 fix the per-attribute `catch` swallowed the error (`@pormg_debug false`, a no-op) and
the loop reached `return true`.

WHERE THIS CONTRACT LIVES NOW. #69 was written against `Models._compare_model_field`, the
attribute-wise comparator. #507 phase 1 moved *changed / unchanged* onto the canonical column IR and
restated the rule there; phase 2 retired the comparator entirely, along with the whole-model
early-out `are_model_fields_equal`. So this file is re-pointed at the IR entry point,
`Migrations.column_delta(new_field, old_field, conn)`.

The rule also had to change SHAPE, not just address, and that is the half worth reading. Phase 1's
fail-safe returned the symbol vector `[:type]`, which sufficed while the plan's actions re-read the
two field structs to decide what to do. Phase 2 derives every action from the delta, so the failure
path has to produce a *`ColumnSpec`*: an action that reads the delta must still get a
truthful-enough delta when half of it could not be built. It does that by degrading the uncompilable
side to a `CUnsupported` marker, and criteria 3 and 4 below are what make that safe rather than
merely quiet.

No live database required — the compiler needs only an engine marker to render a type through.
"""

using Test
using Logging
using PormG
using PormG.Models: CharField, BigIntegerField, ForeignKey
import PormG.Migrations: column_delta, column_spec, _degraded_spec, _spec_or_degraded,
                         _fk_constraint_action

# A marker connection: `column_spec` dispatches on the engine and needs nothing else.
struct MockPgFailsafe69 <: PormG.PormGPostgres end
const _FS_PG = MockPgFailsafe69()

# A value whose RENDERING raises, reached through a real slot on a real field.
#
# Deliberately not a `PormGField` subtype: `subtypes(PormGField)` is walked by `test_db_column.jl`'s
# field-type census, so a throwaway field struct is a landmine for whichever file runs first.
# `sForeignKey.on_delete` is typed `Union{Function, Nothing}` and a struct may subtype `Function`,
# which reaches the compiler's reference path without inventing a field type. (A custom field struct
# would not even work here: `Dialect._get_column_type`'s `else` arm returns the literal `"TEXT"`
# without touching the field, so an unrecognised field type compiles CLEANLY rather than raising —
# the fail-safe has to be probed through a slot the compiler actually reads.)
struct FailsafeBoomAction69 <: Function end
Base.print(::IO, ::FailsafeBoomAction69) = error("on_delete rendering boom (#69 fail-safe probe)")
Base.show(::IO, ::FailsafeBoomAction69) = error("on_delete rendering boom (#69 fail-safe probe)")

# A foreign key whose `on_delete` cannot be rendered. Assigned after construction so the
# constructor's own validation is not the thing under test.
function _fs_boom_field()
  fk = ForeignKey("Races")
  fk.on_delete = FailsafeBoomAction69()
  return fk
end

@testset "Migration diff fail-safe (#69)" begin

  # ─────────────────────────────────────────────────────────────────────────────
  # Criterion 1: a comparison that throws → "changed", never "equal".
  # Pre-fix this reported equal (the swallow-and-continue reached `return true`). The modern answer
  # is a non-empty delta reporting `:type`, which is exactly what phase 1's `[:type]` said — so the
  # plan text on this path did not move when the shape did.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "an uncompilable column is reported as changed" begin
    boom_a, boom_b = _fs_boom_field(), _fs_boom_field()

    # The premise: compiling this field really does throw, from inside `_column_reference` where the
    # referential action is rendered. Guards the test itself — a fixture that compiled cleanly would
    # make the regression untestable here, which is exactly what a hand-rolled field struct does.
    @test_throws ErrorException column_spec(boom_a, _FS_PG)

    delta = column_delta(boom_a, boom_b, _FS_PG; name = "boom")
    @test !isempty(delta)
    @test delta.changed == [:type]
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # Criterion 2: the caught path logs structured context instead of a silent no-op.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "an uncompilable column emits a warning" begin
    boom_a, boom_b = _fs_boom_field(), _fs_boom_field()
    # A :warn must be emitted on the caught path (match_mode=:any tolerates any incidental logs);
    # the expression still evaluates and returns a delta.
    @test_logs (:warn,) match_mode = :any column_delta(boom_a, boom_b, _FS_PG; name = "boom")

    # An ordinary pair does not warn, so the guard above is not passing on background noise.
    @test_logs min_level = Logging.Warn column_delta(CharField(), CharField(), _FS_PG; name = "n")
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # Criterion 3: TWO failing sides must not cancel out.
  #
  # The criterion the old model-level test could not express, and the one that matters most for
  # phase 2. A degraded spec carries a `CUnsupported` marker as its type, and the two sides are
  # given DIFFERENT markers on purpose: with one shared marker they would compare EQUAL, the delta
  # would be empty, and a column nobody could read would be planned as unchanged. That is failing
  # OPEN — the one outcome a schema diff may never have.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "two uncompilable sides still differ" begin
    boom_a, boom_b = _fs_boom_field(), _fs_boom_field()

    new_spec = _spec_or_degraded(boom_a, _FS_PG, "<uncompilable:new>"; name = "boom")
    old_spec = _spec_or_degraded(boom_b, _FS_PG, "<uncompilable:old>"; name = "boom")
    @test new_spec != old_spec
    @test PormG.column_delta(new_spec, old_spec) == [:type]

    # The mutation this guards, spelled out: give both sides the SAME marker and they compare equal,
    # which is why the entry point passes two different ones.
    same_a = _degraded_spec(boom_a, "<uncompilable>"; name = "boom")
    same_b = _degraded_spec(boom_b, "<uncompilable>"; name = "boom")
    @test same_a == same_b
    @test isempty(PormG.column_delta(same_a, same_b))

    # Control: a column that DOES compile is unaffected, so the `:type` verdicts above are
    # attributable to the failure and not to over-eager inequality.
    @test isempty(column_delta(CharField(), CharField(), _FS_PG; name = "boom"))
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # Criterion 4: a degraded column still plans its CONSTRAINT correctly.
  #
  # Phase 2's actions read the delta, so the fail-safe has to keep the foreign-key decision usable —
  # this is what the old `[:type]` return could not carry. A degraded spec keeps the key's PRESENCE
  # (so `:add` / `:drop` stay right) with an unresolvable target (so a key that may have moved is
  # re-issued rather than assumed intact).
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "a degraded foreign key is re-issued, not assumed intact" begin
    bad_fk = _degraded_spec(_fs_boom_field(), "<uncompilable:new>"; name = "parent_id")
    plain  = column_spec(BigIntegerField(null = true), _FS_PG; name = "parent_id")

    @test bad_fk.reference !== nothing
    @test _fk_constraint_action(bad_fk, plain) === :add
    @test _fk_constraint_action(plain, bad_fk) === :drop

    live = column_spec(ForeignKey("Races"; pk_field = "id", null = true), _FS_PG; name = "parent_id")
    @test _fk_constraint_action(bad_fk, live) === :repoint

    # And the deletion path still drops it: a column being removed takes its constraint with it,
    # even when the column could not be compiled (the shape most likely to fail is a key whose
    # PARENT was removed from the models file in the same change).
    @test _fk_constraint_action(nothing, bad_fk) === :drop
  end

end
