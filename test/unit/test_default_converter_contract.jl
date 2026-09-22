"""
What a `default=` converter is allowed to RETURN (#631) — the return-typing half of the class
#598 / #602 / #603 / #612 / #614 worked through for argument typing.

Run: `julia --project=test/integration test/unit/test_default_converter_contract.jl`

## The defect

`validate_default(default, expected_type, field_name, converter)` returned `converter(default)`
unchecked. Its `catch` only relabels what the converter THROWS; a converter that returns the wrong
TYPE sailed past, and the failure surfaced later, at the struct's own `convert` on assignment —
outside that `catch`, and therefore outside the #231/#239 taxonomy, as a bare `MethodError`.

`DateField` was the field where it always fired, because it handed `validate_default` its own SQL
**formatter**:

    validate_default(default, Union{Date, Nothing}, "DateField", format_date_sql)

`format_date_sql` renders a value into SQL text, so every arm of it returns a `String` — including
the `::Date` arm. Only `DateField(default = Date(...))` worked, and only because that spelling takes
`validate_default`'s `default isa expected_type` fast path and never reaches the converter at all.
The other three spellings `docs/src/fields.md` advertises each died with a `MethodError`:

    DateField(default = Date(2024, 1, 1))      => Date("2024-01-01")   — fast path
    DateField(default = "2024-01-01")          => MethodError          — the page's own format
    DateField(default = DateTime(2024, 1, 1))  => MethodError
    DateField(default = ZonedDateTime(...))    => MethodError

## The coverage was exactly inverted, which is why it survived

The *invalid* inputs were handled correctly and pinned (`test_introspection_guards.jl`); the *valid*
ones crashed and were pinned nowhere. Every `DateField(default = …)` in `test/` used `Date(...)`,
the one spelling that took the fast path — so no test in the repo ever called the converter.

## Scope of the fix, and why this file sweeps rather than spot-checks

Two changes, and the first is the general one:

  1. `validate_default` re-checks its converter's result against `expected_type`. A full sweep of
     all 19 call sites found exactly three converters whose codomain can fall outside the
     `expected_type` they are paired with — `format_date_sql` on every input, and
     `format_uuid_sql` / `format_json_sql` on `missing`, where both return `missing` into a
     `Union{String, Nothing}` slot. All three were live defects, so the re-check refuses nothing
     that previously worked.
  2. `DateField` gets `normalize_date_default`, a converter whose codomain IS the slot — the shape
     `DateTimeField` has had since #522, and the same function `Migrations._coerce_default`'s
     `CDate` arm now calls instead of open-coding it.

The hole was named three times before it was closed — `_binary_default_bytes` (#296), `_int_kwarg`
(#614) and `_coerce_default`'s docstring — each time as the reason for a local workaround. The
`missing` sweep below is here so the next converter that drifts is caught by the mechanism rather
than by a fourth workaround.

## Mutation gates

Stated per testset, and run one mutant per gated site rather than several at once — a unit file
run standalone aborts at its first failing top-level testset, so a combined mutant only ever proves
the first one. Three of the four sites are genuinely gated; the fourth (the `#472` interrupt
carve-out) is **not**, which was measured rather than assumed and is written out at that testset.

Hermetic throughout — field constructors and `_coerce_default` only, no connection, no database.
"""

using Test
using PormG
using Dates
using TimeZones
using PormG.Models: DateField, DateTimeField, UUIDField, JSONField, IntegerField, CharField,
                    BinaryField, TimeField, BooleanField, FloatField

const Mo631 = PormG.Models
const Mi631 = PormG.Migrations

# One instant, spelled four ways. Every one of them denotes 2024-07-28 as a calendar date, so the
# four `DateField` spellings must land on ONE stored value — that identity is the contract, not
# just "each one is accepted".
const D631 = Date(2024, 7, 28)
const DATE_SPELLINGS_631 = (
    ("Date",          D631),
    ("String",        "2024-07-28"),
    ("DateTime",      DateTime(2024, 7, 28, 10, 30, 15)),
    ("ZonedDateTime", ZonedDateTime(2024, 7, 28, 10, 30, tz"UTC")),
)

# ─────────────────────────────────────────────────────────────────────────────
# DateField default=: all four documented spellings store a Date (#631)
# `docs/src/fields.md` → DateField → *Current Contract* and the `DateField` docstring both state
# these four. Three of them raised a bare MethodError before #631, and nothing in `test/` exercised
# them — every existing fixture used `Date(...)`, the spelling that skips the converter entirely.
# The `isa Date` assertion is the load-bearing one: a String that merely COMPARED equal would still
# be the original defect, since the struct slot is `Union{Date, Nothing}`.
#
# Mutation gate: point `DateField` back at `format_date_sql` (`src/models/fields.jl`) and the
# String / DateTime / ZonedDateTime rows raise.
# ─────────────────────────────────────────────────────────────────────────────
@testset "DateField default= honors all four documented spellings (#631)" begin
    for (label, spelling) in DATE_SPELLINGS_631
        @testset "$label" begin
            stored = DateField(default = spelling).default
            # The TYPE is the contract. `Date("2024-07-28") == "2024-07-28"` is false in Julia, so
            # the equality below would already catch a String — but say it explicitly, because the
            # defect was a type escaping into the slot and a future converter could return
            # something that compares equal while still being wrong.
            @test stored isa Date
            @test stored == D631
        end
    end

    # The time component is dropped, not rejected and not rounded — `docs/src/fields.md` states
    # this, and `format_date_sql`'s DateTime arm did the same before the swap. 10:30 does not push
    # the date forward.
    @test DateField(default = DateTime(2024, 7, 28, 23, 59, 59)).default == D631

    # A ZonedDateTime yields its LOCAL calendar date. Pinned because the alternative reading (the
    # UTC date) is just as plausible and would silently shift the default by a day for anything
    # east of UTC. The old converter took the local date; so does the new one.
    @test DateField(default = ZonedDateTime(2024, 7, 28, 22, 0, tz"America/Sao_Paulo")).default == D631

    # `nothing` still means "no default", via `validate_default`'s fast path rather than the
    # converter. Cheap, and it is the value every other field in the suite passes.
    @test DateField(default = nothing).default === nothing
    @test DateField().default === nothing
end

# ─────────────────────────────────────────────────────────────────────────────
# DateField default=: the negatives still refuse, and stay inside the taxonomy
# The fix widens what is ACCEPTED; nothing about it should widen what is stored silently. Each case
# below was already a FieldValidationError before #631 except the last, which was the MethodError
# this file exists for. `isa PormGError` is asserted rather than implied: the reported symptom of
# #631 was specifically that `e isa PormG.PormGError` came back `false`.
#
# Mutation gate: delete the `else` arm of `normalize_date_default` and the Int/Symbol rows raise a
# MethodError instead.
# ─────────────────────────────────────────────────────────────────────────────
@testset "DateField default= refuses a non-date, in the taxonomy (#631)" begin
    for bad in ("nope", "28/07/2024", "2024-07-28T10:30:00", "2023-02-29", 42, :today, missing)
        @testset "$(repr(bad))" begin
            err = try
                DateField(default = bad)
                nothing
            catch e
                e
            end
            @test err !== nothing
            @test err isa PormG.FieldValidationError
            @test err isa PormG.PormGError
            # The #231/#239 clean break: no field-constructor refusal is an ArgumentError.
            @test !(err isa ArgumentError)
        end
    end

    # "2023-02-29" above is the case that separates a calendar check from a shape check — it has
    # the right shape and is not a real date. Stated here so the loop's intent is not lost: the
    # converter parses, it does not pattern-match.
    @test_throws PormG.FieldValidationError DateField(default = "2023-02-31")

    # A separator Julia's `Date(::String)` accepts but the strict `YYYY-MM-DD` regex does not.
    # Accepted on purpose, and pinned so the widening is visible rather than incidental: this is
    # what `Migrations._coerce_default`'s `CDate` arm has always accepted, and the two sides now
    # share one definition, so the declared side had to move to meet it.
    @test DateField(default = "2024-7-28").default == D631
end

# ─────────────────────────────────────────────────────────────────────────────
# validate_default re-checks its converter's result (#631)
# The general half. Three converters could return outside their paired `expected_type`, and all
# three reached the caller as a bare MethodError from the struct's `convert`. `missing` is the one
# input that triggers the other two: `format_uuid_sql(missing)` and `format_json_sql(missing)` both
# return `missing` into a `Union{String, Nothing}` slot.
#
# The sweep over every constructor is the point. A spot check on the three known cases would pass
# just as well with the re-check deleted, because each of them is ALSO fixed at its own converter;
# what the re-check buys is that a converter added later cannot reintroduce the class silently.
#
# Mutation gate: delete the `converted isa expected_type` check in `validate_default`
# (`src/Models.jl`) and the UUIDField / JSONField rows raise a MethodError.
# ─────────────────────────────────────────────────────────────────────────────
@testset "no default= converter can return outside its expected_type (#631)" begin
    constructors_631 = (
        ("IDField",        () -> Mo631.IDField(default = missing)),
        ("IntegerField",   () -> IntegerField(default = missing)),
        ("BigIntegerField", () -> Mo631.BigIntegerField(default = missing)),
        ("BooleanField",   () -> BooleanField(default = missing)),
        ("FloatField",     () -> FloatField(default = missing)),
        ("DecimalField",   () -> Mo631.DecimalField(default = missing)),
        ("CharField",      () -> CharField(max_length = 10, default = missing)),
        ("TextField",      () -> Mo631.TextField(default = missing)),
        ("TimeField",      () -> TimeField(default = missing)),
        ("BinaryField",    () -> BinaryField(default = missing)),
        ("DateField",      () -> DateField(default = missing)),
        ("DateTimeField",  () -> DateTimeField(default = missing)),
        ("UUIDField",      () -> UUIDField(default = missing)),
        ("JSONField",      () -> JSONField(default = missing)),
    )

    for (name, build) in constructors_631
        @testset "$name" begin
            err = try
                build()
                nothing
            catch e
                e
            end
            # `missing` is not a valid default for any field. What is being pinned is not the
            # refusal — most of these refused already — but that EVERY refusal is in the taxonomy.
            # Before #631 the last three rows escaped it.
            @test err isa PormG.PormGError
            @test !(err isa MethodError)
        end
    end

    # The message distinguishes the two failure modes, because they have different audiences. A
    # converter that THREW blames the caller's value; a converter that returned the wrong type is a
    # PormG bug and the text has to say so, or the next maintainer cannot tell which fired.
    internal = try
        UUIDField(default = missing)
    catch e
        sprint(showerror, e)
    end
    # `UUIDField` and `Missing` alone would NOT pin this: both appear in the ordinary
    # "Expected type: …, got: Missing" text too, so asserting only those leaves the testset green
    # if the second `throw` is ever collapsed back into the first. The discriminating strings are
    # the ones below — the maintainer-facing phrasing on one side, its absence on the other.
    @test occursin("UUIDField", internal)
    @test occursin("Missing", internal)
    @test occursin("PormG bug", internal)
    @test !occursin("Expected type", internal)

    # The control: an ordinary bad value still gets the ordinary message, not the internal one.
    ordinary = try
        IntegerField(default = "not a number")
    catch e
        sprint(showerror, e)
    end
    @test occursin("Expected type", ordinary)
    @test !occursin("PormG bug", ordinary)
end

# ─────────────────────────────────────────────────────────────────────────────
# The declared side and the live side agree on CDate (#631)
# `Migrations._coerce_default`'s whole purpose is that the live side lands on the value a
# declaration stores, so `LiteralDefault`'s `isequal` is a real comparison (#522). Its `CDateTime`
# arm has been pinned since then (`test_live_schema_reader.jl`); `CDate` never was, and it was the
# one arm that did NOT share the constructor's converter — it open-coded `Date(String(value))`
# precisely because the constructor's converter was broken.
#
# Mutation gate, measured: revert the `CDate` arm to the three open-coded lines and this testset
# goes RED on two assertions — the `@test_throws FieldValidationError` for an unparseable literal
# (the open-coded `Date(String(value))` raises a raw `ArgumentError` instead) and the `occursin`
# that requires the message to name the offending date (`ArgumentError` says only
# "Day: 29 out of range (1:28)").
#
# Note WHICH assertions those are: the refusal block at the end, not the value-equality loops
# above it. An open-coded arm produces exactly the same VALUES for every accepted spelling — that
# is the point of lifting it verbatim — so the loops pass under the mutant and cannot be the gate.
# ─────────────────────────────────────────────────────────────────────────────
@testset "DateField default= === _coerce_default(CDate) (#631)" begin
    for (label, spelling) in DATE_SPELLINGS_631
        @testset "$label" begin
            declared = DateField(default = spelling).default
            live     = Mi631._coerce_default(spelling, PormG.CDate())
            @test declared === live
            @test declared === D631
        end
    end

    # One definition, not two that happen to agree today. `_coerce_default`'s `CDate` arm calls
    # `normalize_date_default`, so a change to the converter reaches both sides at once — the
    # property #522 established for `CDateTime` and that `CDate` lacked until now.
    for (_, spelling) in DATE_SPELLINGS_631
        @test Mi631._coerce_default(spelling, PormG.CDate()) ===
              Mo631.normalize_date_default(spelling)
    end

    # The live side's refusals moved into the taxonomy. An unparseable literal used to leave
    # `_coerce_default` as a raw `ArgumentError` from `Date(…)`, and a wrong-typed one fell through
    # to the catch-all; both are now FieldValidationError. This is a TYPE change, not a
    # reachability one — `_default_or_drop`'s `catch` is bare, so both were already warned and
    # dropped, and neither aborted a schema read. Pinned because "the readers throw the category
    # the constructors throw" is `_coerce_default`'s documented contract, and `CDate` was the arm
    # that did not honour it.
    @test_throws PormG.FieldValidationError Mi631._coerce_default("not-a-date", PormG.CDate())
    @test_throws PormG.FieldValidationError Mi631._coerce_default(42, PormG.CDate())

    # And the warn-and-drop message still names the offending date. `validate_default`'s bare
    # `catch` discards this text on the CONSTRUCTOR path, but `_coerce_default` calls the converter
    # directly, so this is the one caller that sees it — the same asymmetry `format2int64`'s
    # comment block in `Models.jl` records for the numeric converters.
    msg = try
        Mi631._coerce_default("2023-02-29", PormG.CDate())
    catch e
        sprint(showerror, e)
    end
    @test occursin("2023-02-29", msg)
    # Single line: `_default_or_drop` truncates the message into a structured `@warn` field, and an
    # embedded newline there breaks the log line rather than the test.
    @test !occursin('\n', msg)
end

# ─────────────────────────────────────────────────────────────────────────────
# The #472 interrupt carve-out survives the converter swap (#631)
# `InterruptOnRead` raises the moment its contents are read, which is inside the converter's own
# `try` — exactly where a real Ctrl-C during a large `convert_schema_to_models` run would land. An
# interrupt is a program-state failure, not a bad default: relabelling it as a
# FieldValidationError would let introspection's warn-and-drop guard swallow the cancellation,
# retry the constructor, and report the interrupted import as a bad column default.
#
# This mirrors `test_introspection_guards.jl`, which pins the same property for the converter
# `DateField` used to hold. The carve-out had to be rewritten into the new function, so it is
# re-pinned here rather than assumed to have come along.
#
# MEASURED COVERAGE, stated rather than implied — the same caveat `test_introspection_guards.jl`
# records for two of its own three lines. Deleting the
# `(e isa InterruptException || …) && rethrow()` line from `normalize_date_default` does NOT make
# this testset red, and it was run to find that out rather than assumed either way. The mechanism:
# this fixture raises on EVERY read, so with the carve-out gone the interrupt is caught and the
# replacement `_fielderr` message interpolates `$(value)` — which reads the fixture again and
# re-raises the same InterruptException out of the `catch`. No fixture can do better, because
# every route into that `catch` goes through a read that throws.
#
# So what these two assertions pin is the OUTCOME (an interrupt reaches the caller as an
# interrupt, never relabelled as a bad default) rather than the line that produces it. The
# carve-out stays because the case it actually guards is the one no fixture reproduces: a real
# Ctrl-C landing inside `Date(::String)` on an ordinary, perfectly readable string, where nothing
# else would rethrow. That is the #472 scenario verbatim.
# ─────────────────────────────────────────────────────────────────────────────
@testset "an interrupt inside the date converter is not a bad default (#472, #631)" begin
    # Same fixture shape as `test_introspection_guards.jl`: a string-like whose every read throws.
    struct InterruptOnRead631 <: AbstractString end
    Base.ncodeunits(::InterruptOnRead631) = throw(InterruptException())
    Base.codeunit(::InterruptOnRead631) = UInt8
    Base.codeunit(::InterruptOnRead631, ::Integer) = throw(InterruptException())
    Base.isvalid(::InterruptOnRead631, ::Integer) = throw(InterruptException())
    Base.iterate(::InterruptOnRead631, i::Integer = 1) = throw(InterruptException())
    Base.String(::InterruptOnRead631) = throw(InterruptException())

    @test_throws InterruptException DateField(default = InterruptOnRead631())
    @test_throws InterruptException Mi631._coerce_default(InterruptOnRead631(), PormG.CDate())
end
