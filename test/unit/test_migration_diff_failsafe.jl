"""
Unit coverage for the migration-diff FAIL-SAFE contract (#69).

The schema diff compares two model fields attribute-by-attribute in
`_compare_model_field`. If any attribute comparison *throws*, the diff must treat the
field as **changed** (so a migration is generated), never fall through to "equal".
Reporting "equal" on an error means "no change" — which silently drops a needed
migration and corrupts the schema contract.

Before the #69 fix the per-attribute `catch` swallowed the error (`@pormg_debug false`,
a no-op) and the loop reached `return true`. These tests pin the corrected direction:
on a throwing comparison, `_compare_model_field` returns `false` (changed), emits a
structured `@warn`, and `are_model_fields_equal` classifies the models as different.

No live database required — the comparison tools operate purely on in-memory models.
"""

using Test
using PormG
using PormG.Models: CharField, are_model_fields_equal, _compare_model_field

# A value whose equality comparison RAISES. `!=` falls back to `!(==)`, so overriding
# `==` to error makes any `!=` on two of these throw — exactly the "comparison that
# throws rather than merely differs" case #69 is about. Defining `==` on a type we own
# is not type piracy.
struct _CompareBoom end
Base.:(==)(::_CompareBoom, ::_CompareBoom) = error("comparison boom (#69 regression)")

# A minimal field whose single attribute holds a _CompareBoom, so `_compare_model_field`
# reaches `getfield(new, :payload) != getfield(old, :payload)` and that comparison throws.
struct _ThrowingField <: PormG.PormGField
  payload::Any
end

# Exercises the OTHER throwing site inside the same `catch`: the `:to` ForeignKey branch.
# When the two `.to` targets normalize equal, `_compare_field_foreign_key` calls
# `fk_target_column`, which does `String(field.pk_field)` — and a _CompareBoom has no String
# conversion, so that raises a clean MethodError. (We keep a real `pk_field` field rather than
# omitting it: accessing a *missing* property on a model recurses through the getproperty
# override and stack-overflows — a separate latent bug we don't want to trip here.) The FK
# comparison must fail safe (changed) just like the generic branch; this guards against a
# refactor that moves _compare_field_foreign_key outside the try.
struct _ThrowingFKField <: PormG.PormGField
  to::Any
  pk_field::Any
end

# Build a bare Model_Type around a fields dict — bypasses the Model() constructor (and
# any config/FK resolution) so the test isolates the comparison logic only.
_mk_model(fields::Dict{String, PormG.PormGField}) =
  PormG.Models.Model_Type(name = "diff_failsafe_scratch", fields = fields)

@testset "Migration diff fail-safe (#69)" begin

  # ─────────────────────────────────────────────────────────────────────────────
  # Criterion 1: a field comparison that throws → "changed" (false), never "equal".
  # Pre-fix this returned `true` (the swallow-and-continue reached `return true`).
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "throwing comparison → not equal" begin
    nf = _ThrowingField(_CompareBoom())
    of = _ThrowingField(_CompareBoom())

    # Sanity: the attribute comparison really does throw (guards the test itself —
    # if it silently returned a Bool, the regression would be untestable here).
    @test_throws ErrorException (getfield(nf, :payload) != getfield(of, :payload))

    # The fix: the diff fails SAFE, treating the field as changed.
    @test _compare_model_field(nf, of) == false
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # Criterion 1 (second throwing site): the `:to` ForeignKey-comparison branch is
  # inside the same catch and must fail safe too. This guards against a refactor that
  # pulls _compare_field_foreign_key out of the try.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "throwing FK comparison also fails safe" begin
    nf = _ThrowingFKField("SameParent", _CompareBoom())
    of = _ThrowingFKField("SameParent", _CompareBoom())

    # Guard: the FK comparison really raises for these fields (equal targets → it
    # reaches fk_target_column → String(pk_field::_CompareBoom) has no method).
    @test_throws MethodError PormG.Models._compare_field_foreign_key(nf, of)

    # And the field-level diff treats them as changed, not equal.
    @test _compare_model_field(nf, of) == false
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # Criterion 2: the caught path logs structured context instead of a silent no-op.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "throwing comparison emits a warning" begin
    nf = _ThrowingField(_CompareBoom())
    of = _ThrowingField(_CompareBoom())
    # A :warn must be emitted on the caught path (match_mode=:any tolerates any
    # incidental logs); the expression still evaluates and returns false.
    @test_logs (:warn,) match_mode = :any _compare_model_field(nf, of)
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # Criterion 3: at the model level, a field whose comparison throws makes the two
  # models compare UNEQUAL — i.e. the diff plan includes the field (a migration is
  # generated), rather than being silently skipped.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "are_model_fields_equal is not fooled by a throwing field" begin
    throwing_a = Dict{String, PormG.PormGField}("payload" => _ThrowingField(_CompareBoom()))
    throwing_b = Dict{String, PormG.PormGField}("payload" => _ThrowingField(_CompareBoom()))
    # Throwing field present → models must be reported different (migration emitted).
    # Pre-fix this returned `true` (equal → migration silently dropped).
    @test are_model_fields_equal(_mk_model(throwing_a), _mk_model(throwing_b)) == false

    # Control: identical NORMAL fields still compare equal, proving the `false` above
    # is attributable to the throwing field and not to over-eager inequality.
    normal_a = Dict{String, PormG.PormGField}("payload" => CharField())
    normal_b = Dict{String, PormG.PormGField}("payload" => CharField())
    @test are_model_fields_equal(_mk_model(normal_a), _mk_model(normal_b)) == true
  end

end
