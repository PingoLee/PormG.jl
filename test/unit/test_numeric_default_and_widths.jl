"""
Numeric `default=` and the integer width keywords accept any `Integer` (#614) — the
`::Int`-not-`Integer` slice of the class #598 / #602 / #603 / #612 worked through for `::String`.

Run: `julia --project=test/integration test/unit/test_numeric_default_and_widths.jl`

## The contract

#612 gave the seven plain-text fields one `default=` policy: any `AbstractString`, or an `Integer`
written as its decimal text. `Integer`, not `Int64` — so `CharField(default = Int32(5))` stores
`"5"`. The numeric fields did not move, and the result was backwards: a width that is fine in a
TEXT column was refused by an INTEGER one.

    CharField(default = Int32(5))          => "5"
    IntegerField(default = Int32(5))       => FieldValidationError
    CharField(max_length = Int32(50))      => FieldValidationError, "must be an integer"

Three spellings of one mistake, all naming a concrete type where the abstract one was meant:

  1. `format2int64` had NO `Integer` method — only `AbstractString` and `Decimals.Decimal`. A plain
     `Int64` never reached it (it satisfies `validate_default`'s `default isa expected_type` fast
     path), so every other integral spelling missed both methods, raised `MethodError`, and
     `validate_default`'s bare `catch` relabelled it as "Expected type: …, got: Int32" — blaming
     the value's TYPE for a missing CONVERSION, the same shape as the dead `parse(String, x)` #612
     removed from the text family.
  2. `format2float64(x::Union{Int, AbstractString})` — `Int` is the concrete `Int64` alias, in a
     signature that reads as though it accepts "an integer".
  3. `max_length isa Int` in front of the field structs' `::Int` slots, whose refusal said
     something simply untrue about an `Int32`.

## Why this file is a per-field sweep rather than a spot check

The same reason `test_constructor_abstractstring.jl`'s #612 matrix is: the defect IS per-field
divergence. Nine constructors share `format2int64`, two share `format2float64`, five share the
width guard, and nothing but an exhaustive pass catches one of them drifting back out.

## The reference implementation is in the repo, on the other side of the seam

`Migrations._coerce_default` (`src/migrations/introspection.jl`) has always done exactly this
policy — `Bool` refused, `Integer` to `Int64`, `Real` to `Float64` — and its docstring says it
applies "the coercion each field constructor's `validate_default` converter applies". It did not.
The last testset here pins the two sides together.

#614 left one arm diverging and pinned it as such: `format2int64(::Decimals.Decimal)` let the
declared side take a `Decimal` on an integer column where `_coerce_default` refused one. #632 closed
it by dropping that method — the declared side narrowed, because `_coerce_default` is the stated
owner of the policy, `docs/src/read/filters_and_aggregates.md` already documented the integer
contract without `Decimal`, and the old acceptance was spelling-dependent rather than
value-dependent (`Int64(::Decimal)` works only at scale 0, so an integral `Decimal(0, 50, -1)` was
refused while `Decimal(0, 5, 0)` was not). `FloatField` / `DecimalField` still take a `Decimal` on
both sides; that asymmetry is the columns differing, not a second gap.

## Mutation gates

Stated per testset. Hermetic throughout — field constructors only, no connection, no database.
"""

using Test
using PormG
using Decimals
using PormG.Models: IDField, ForeignKey, OneToOneField, IntegerField, PositiveSmallIntegerField,
                    PositiveIntegerField, BigIntegerField, FloatField, DecimalField, CharField,
                    URLField, SlugField, PasswordField, BinaryField, TextField

const Mo614 = PormG.Models

# The integer constructors that share `format2int64`. `ForeignKey` / `OneToOneField` take a
# positional target, so each entry is a thunk of `default` rather than a bare constructor — the
# same shape `_PROBES603` uses for a surface whose call sites are not uniform.
const _INT_FIELDS614 = (
  ("IDField",                   d -> IDField(default = d)),
  ("ForeignKey",                d -> ForeignKey("drivers", default = d)),
  ("OneToOneField",             d -> OneToOneField("drivers", default = d)),
  ("IntegerField",              d -> IntegerField(default = d)),
  ("PositiveSmallIntegerField", d -> PositiveSmallIntegerField(default = d)),
  ("PositiveIntegerField",      d -> PositiveIntegerField(default = d)),
  ("BigIntegerField",           d -> BigIntegerField(default = d)),
)

# The two that share `format2float64`.
const _FLOAT_FIELDS614 = (
  ("FloatField",   d -> FloatField(default = d)),
  ("DecimalField", d -> DecimalField(default = d)),
)

# The width keywords that share `_int_kwarg`. `PasswordField` has a 64 floor and `SlugField` a 255
# ceiling, so the probe width is one every site accepts.
const _WIDTH_FIELDS614 = (
  ("CharField",     w -> CharField(max_length = w)),
  ("URLField",      w -> URLField(max_length = w)),
  ("SlugField",     w -> SlugField(max_length = w)),
  ("PasswordField", w -> PasswordField(max_length = w)),
  ("BinaryField",   w -> BinaryField(max_length = w)),
)

# Construct and hand back the stored slot, or the exception itself. Without this a re-narrowed
# converter throws out of the loop body and aborts the testset at its first row, so one broken
# field would mask every field after it — the sweep would report ONE error where the defect is
# per-field divergence.
_stored614(ctor, probe, slot) = try getproperty(ctor(probe), slot) catch e; e end

# ─────────────────────────────────────────────────────────────────────────────
# #614 — `default=` on the integer-field family
# Every integral spelling now lands on the same `Int64`, on all seven constructors. Before this,
# only a literal `Int64` and a decimal String worked: `Int32`, `Int16`, `UInt8` and `BigInt` each
# raised a FieldValidationError whose text blamed the value's type.
# Mutation gate: delete `format2int64(x::Integer)` from `src/Models.jl` and every non-`Int64` row
# below raises; re-narrow it to `::Int` and the same rows raise.
# ─────────────────────────────────────────────────────────────────────────────
@testset "default= takes any Integer across the integer-field family (#614)" begin
  for (name, ctor) in _INT_FIELDS614
    # The spellings a web layer, a config loader or another package's return type actually produce.
    # Each asserts the VALUE and the stored TYPE: `validate_default` does not re-check its
    # converter's result, so a converter returning the wrong type would land in the slot unnoticed
    # (the #296 hole `_binary_default_bytes` documents).
    for probe in (Int32(5), Int16(5), Int8(5), UInt8(5), UInt32(5), Int128(5), big(5))
      @testset "$name / $(typeof(probe))" begin
        @test _stored614(ctor, probe, :default) === Int64(5)
      end
    end

    # The two spellings that already worked, pinned so the widening cannot displace them.
    @test ctor(5).default === Int64(5)
    @test ctor("5").default === Int64(5)
    @test ctor(nothing).default === nothing

    # Negative and zero are ordinary integers for the fields that allow them; the positive family
    # enforces its own floor separately (test_positive_small_integer_check.jl) and is skipped here.
    if !startswith(name, "Positive")
      @test ctor(Int32(-7)).default === Int64(-7)
    end
    @test ctor(Int32(0)).default === Int64(0)
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# #614 — the refusals that must NOT move
# Widening the accepted TYPE is not widening the accepted SHAPE. `Bool` is carved out deliberately
# (`Bool <: Integer`, and `true` in an integer column is far likelier a mistake than an intent —
# the same call `_default_string` makes for the text family), a Float is still not an integer, and
# a value past `typemax(Int64)` is still a refusal rather than a wraparound.
# Mutation gate: drop the `x isa Bool && throw(…)` line from `format2int64` and the `true` rows
# below start returning 1.
# ─────────────────────────────────────────────────────────────────────────────
@testset "default= still refuses Bool, Float and out-of-range on the integer fields (#614)" begin
  for (name, ctor) in _INT_FIELDS614
    @test_throws PormG.FieldValidationError ctor(true)
    @test_throws PormG.FieldValidationError ctor(false)
    @test_throws PormG.FieldValidationError ctor(5.0)
    @test_throws PormG.FieldValidationError ctor(3.5)
    @test_throws PormG.FieldValidationError ctor(:five)
    @test_throws PormG.FieldValidationError ctor([1, 2])
    @test_throws PormG.FieldValidationError ctor("not a number")

    # `Int64(big(2)^70)` is an InexactError inside the converter. It must surface as the field
    # taxonomy's error, not as a raw InexactError and not as a silently truncated width.
    @test_throws PormG.FieldValidationError ctor(big(2)^70)
    @test_throws PormG.FieldValidationError ctor(typemax(UInt64))
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# #614 — `default=` on FloatField / DecimalField
# `format2float64` was `Union{Int, AbstractString}`, so it refused `Float32`, `Int32`, `Rational`
# and `BigInt` alike. Widened to `Real`, which also picks up `Decimals.Decimal` — closing an
# asymmetry, since `format2int64` has had a `Decimal` method all along and its float sibling had
# none.
# Mutation gate: restore the `Union{Int, AbstractString}` signature and every row but the `Int64`
# and String ones raises.
# ─────────────────────────────────────────────────────────────────────────────
@testset "default= takes any non-Bool Real on the float fields (#614)" begin
  for (name, ctor) in _FLOAT_FIELDS614
    for probe in (Int32(5), UInt8(5), big(5), Float32(5.0), 5.0, Decimal(0, 5, 0))
      @testset "$name / $(typeof(probe))" begin
        @test _stored614(ctor, probe, :default) === 5.0
      end
    end

    # A Rational is a Real and converts exactly here; it was refused before.
    @test ctor(1//4).default === 0.25
    # Decimals with a scale, so the `Decimal` arm is not passing only on integral values.
    @test ctor(Decimal(0, 5, -1)).default === 0.5

    @test ctor(5).default === 5.0
    @test ctor("5.5").default === 5.5
    @test ctor(nothing).default === nothing

    # Bool stays refused on the float side too — `Bool <: Real`, so it needs its own carve-out.
    @test_throws PormG.FieldValidationError ctor(true)
    @test_throws PormG.FieldValidationError ctor(false)

    # Out of range is a REFUSAL, not a saturation. `Float64(big"1e400")` returns `Inf` rather than
    # raising the way `Int64(big(2)^70)` does, so without the explicit `isfinite` check in
    # `format2float64` the widening would turn a value `main` refused into a stored `DEFAULT Inf`.
    # Caught in review, and the reason these four rows exist.
    @test_throws PormG.FieldValidationError ctor(big"1e400")
    @test_throws PormG.FieldValidationError ctor(big"-1e400")
    @test_throws PormG.FieldValidationError ctor(BigFloat(Inf))
    @test_throws PormG.FieldValidationError ctor(BigFloat(NaN))

    # The pre-existing fast-path hole, pinned as it IS rather than as it ought to be: a literal
    # `Float64` satisfies `validate_default`s `default isa expected_type` check and never reaches
    # a converter, so `Inf` is still storable by that one spelling. #614 did not open it and does
    # not close it; this row exists so closing it later is a visible change, not a surprise.
    @test ctor(Inf).default === Inf

    @test_throws PormG.FieldValidationError ctor(:five)
    @test_throws PormG.FieldValidationError ctor("not a number")
    @test_throws PormG.FieldValidationError ctor("not a number")
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# #614 — the integer width keywords
# `max_length` / `max_digits` / `decimal_places` are `::Int` slots, and the guards in front of them
# were written to the annotation rather than the concept. The refusal was not merely unhelpful, it
# was FALSE: `CharField(max_length = Int32(50))` was rejected with "The max_length must be an
# integer" about a value that is one.
# Mutation gate: re-narrow `_int_kwarg`'s check to `value isa Int` and every `Int32` row raises;
# delete the `try` around `Int(value)` and the `big(2)^70` row raises `InexactError` instead of
# `FieldValidationError`.
# ─────────────────────────────────────────────────────────────────────────────
@testset "integer width keywords take any Integer (#614)" begin
  for (name, ctor) in _WIDTH_FIELDS614
    for probe in (Int32(100), Int16(100), UInt8(100), UInt32(100), big(100))
      @testset "$name / $(typeof(probe))" begin
        @test _stored614(ctor, probe, :max_length) === 100
      end
    end

    # The Int64 spelling, pinned.
    @test _stored614(ctor, 100, :max_length) === 100

    # Bool and Float stay refused, and the message now names the keyword and the type that arrived
    # rather than asserting something untrue about it.
    @test_throws PormG.FieldValidationError ctor(true)
    @test_throws PormG.FieldValidationError ctor(3.5)
    @test_throws PormG.FieldValidationError ctor(:wide)

    # Out of range is a refusal inside the taxonomy, not a raw InexactError.
    @test_throws PormG.FieldValidationError ctor(big(2)^70)
    @test_throws PormG.FieldValidationError ctor(typemax(UInt64))
  end

  # Each site keeps its own accepted SHAPE — the widening is about the integer type only.
  # CharField / URLField / SlugField parse a numeric String on the line above the guard;
  # BinaryField accepts `nothing` as "no limit" and parses a numeric String of its own.
  @test CharField(max_length = "50").max_length === 50
  @test URLField(max_length = "50").max_length === 50
  @test SlugField(max_length = "50").max_length === 50
  @test BinaryField(max_length = nothing).max_length === nothing
  @test BinaryField(max_length = "50").max_length === 50

  # `DecimalField`'s two precision keywords ride `format2int64` through `validate_default`, so they
  # are fixed by the converter widening rather than by `_int_kwarg` — covered here because the user
  # cannot tell the two mechanisms apart and both were broken the same way.
  @test DecimalField(max_digits = Int32(8)).max_digits === 8
  @test DecimalField(decimal_places = Int32(3)).decimal_places === 3
  @test DecimalField(max_digits = UInt8(8)).max_digits === 8
  @test_throws PormG.FieldValidationError DecimalField(max_digits = 3.5)
end

# ─────────────────────────────────────────────────────────────────────────────
# #614 — the declared side and the live side agree on the Integer / Real arms
# `Migrations._coerce_default` is the coercion the INTROSPECTED side applies, and its docstring
# claims it is "the coercion each field constructor's `validate_default` converter applies". Until
# this fix that was false for every integral spelling but `Int64`: the live side accepted an
# `Integer` and the declared side refused it, which is the drift that helper exists to prevent.
#
# #632 closed the last arm. This testset was written under #614 with a caveat — it asserted
# agreement on the `Integer` / `Real` arms and pinned `Decimals.Decimal` on an integer column as a
# KNOWN divergence, "so that closing the gap later is a visible change to this file rather than a
# silent one". That is what happened: the `Decimal` rows below are now agreement rows, and the
# caveat is gone rather than reworded.
#
# Mutation gates, one per site:
#   - revert either converter in `src/Models.jl`            -> the Integer / Real loop raises
#   - restore `format2int64(::Decimals.Decimal)`            -> the Decimal refusal rows fail
# ─────────────────────────────────────────────────────────────────────────────
@testset "constructor default= agrees with Migrations._coerce_default (#614, #632)" begin
  coerce = PormG.Migrations._coerce_default

  for probe in (Int32(5), Int16(5), UInt8(5), big(5), 5)
    # Integer side: both land on the same Int64.
    declared = IntegerField(default = probe).default
    live     = coerce(probe, PormG.CInt64())
    @test declared === live === Int64(5)

    # Float side: both land on the same Float64.
    declared_f = FloatField(default = probe).default
    live_f     = coerce(probe, PormG.CFloat64())
    @test declared_f === live_f === 5.0
  end

  # And they agree on the refusal, too — both carve `Bool` out rather than storing it as 1.
  @test_throws PormG.FieldValidationError IntegerField(default = true)
  @test_throws PormG.FieldValidationError coerce(true, PormG.CInt64())
  @test_throws PormG.FieldValidationError FloatField(default = true)
  @test_throws PormG.FieldValidationError coerce(true, PormG.CFloat64())

  # #632 — the arm that used to diverge. `format2int64(::Decimals.Decimal)` is gone, so BOTH sides
  # refuse a `Decimal` on an integer column. Four spellings rather than one, because the old
  # acceptance was spelling-dependent rather than value-dependent — `Int64(::Decimal)` only worked
  # at scale 0, so `Decimal(0, 50, -1)` (= 5.0, integral) was refused while `Decimal(0, 5, 0)`
  # (= 5) was accepted. Sweeping all four is what pins the new rule as one rule.
  for d in (Decimal(0, 5, 0),     # 5    — used to be ACCEPTED as 5 on the declared side
            Decimal(0, 50, -1),   # 5.0  — integral, and refused anyway: the wart
            Decimal(0, 5, -1),    # 0.5  — an integer column cannot hold it
            Decimal(1, 5, 0))     # -5   — the sign arm, in case a future fix forgets it
    @test_throws PormG.FieldValidationError IntegerField(default = d)
    @test_throws PormG.FieldValidationError coerce(d, PormG.CInt64())
  end

  # The refusal reaches every constructor that shares `format2int64`, not just `IntegerField`.
  # Cheap, and it is the assertion that would catch someone re-adding the method for one field.
  @test_throws PormG.FieldValidationError IDField(default = Decimal(0, 5, 0))
  @test_throws PormG.FieldValidationError BigIntegerField(default = Decimal(0, 5, 0))
  @test_throws PormG.FieldValidationError PositiveIntegerField(default = Decimal(0, 5, 0))
  @test_throws PormG.FieldValidationError PositiveSmallIntegerField(default = Decimal(0, 5, 0))

  # The FLOAT family is deliberately untouched and still takes a `Decimal` on both sides. This is
  # the control that keeps the rows above from being read as "PormG refuses Decimals": the two
  # families differ because the COLUMNS differ, not because one of them was overlooked.
  for d in (Decimal(0, 5, 0), Decimal(0, 50, -1), Decimal(0, 5, -1))
    @test FloatField(default = d).default === coerce(d, PormG.CFloat64())
  end
  @test FloatField(default = Decimal(0, 5, -1)).default === 0.5
end

# ─────────────────────────────────────────────────────────────────────────────
# #614 — the #612 text policy is untouched
# This fix sits one type family over from #612 and must not disturb it. Pinned here rather than
# left to `test_constructor_abstractstring.jl` alone, because the shared `_int_kwarg` helper now
# runs inside three of the same constructors.
# Mutation gate: route `_default_string`'s `Integer` arm through `format2int64` and the decimal-text
# rows below start storing an Int64 instead of a String.
# ─────────────────────────────────────────────────────────────────────────────
@testset "the #612 text-family default= policy does not move (#614)" begin
  for ctor in (CharField, TextField, URLField, SlugField)
    @test ctor(default = 5).default === "5"
    @test ctor(default = Int32(7)).default === "7"
    @test ctor(default = nothing).default === nothing
    @test_throws PormG.FieldValidationError ctor(default = true)
    @test_throws PormG.FieldValidationError ctor(default = 3.5)
  end
end
