"""
Field-constructor behavior snapshot (#260).

Pins the **observable result** of every field constructor: for each of the 27 constructors, the
complete struct field set as built (a) with no keyword arguments and (b) with each common keyword
explicitly set to a non-default value, one at a time.

There are **27** constructors, not the 26 the `*Field` naming suggests — `ForeignKey` doesn't end in
`Field`, which is exactly how it escaped the first inventory. If a constructor is added, it must be
added to `FKE_CTORS` or the row-count guard below fails.

Why a frozen snapshot rather than hand-written assertions: #260 collapsed a kwargs preamble that had
been copy-pasted into every constructor, and the one way that refactor could go wrong was *silently* —
by changing a default. Four common keywords do **not** share a default across constructors:

    unique       true in IDField, OneToOneField                               (false elsewhere)
    db_index     true in IDField, OneToOneField, SlugField, ForeignKey         (false elsewhere)
    editable     true in CharField, PasswordField, FileField, UUIDField,
                 URLField, SlugField, JSONField                                (false elsewhere)
    primary_key  true in IDField                                               (false elsewhere)

Ten constructors deviate. (`AutoField` was an eleventh until #408 retired it — it is no longer a
constructor at all, only a stub that raises, so it has no default state to freeze.) A shared helper with hardcoded defaults would have flipped behavior at
those sites with every existing test still green, because nothing else asserts a constructor's
default state field-by-field. This file is that missing guard.

`test_new_field_types.jl` and `test_field_validation_and_operations.jl` cover *validation* — that bad
input is rejected. This covers the complement: that good input produces exactly the same struct it
always did.

The fixture is generated, not authored. If a default legitimately changes, regenerate deliberately
(see the failure message) and review the diff — a one-line fixture change is the signal that a
user-visible default moved.
"""
# julia --project=. test/unit/test_field_kwargs_equivalence.jl

using Test
using PormG
using PormG.Models

const FKE_M = PormG.Models
const FKE_FIXTURE = joinpath(@__DIR__, "fixtures", "field_kwargs_snapshot.txt")

# The two relational fields take a positional target; everything else is kwargs-only.
const FKE_CTORS = Dict{String,Function}(
    "IDField"                   => kw -> FKE_M.IDField(; kw...),
    "CharField"                 => kw -> FKE_M.CharField(; kw...),
    "IntegerField"              => kw -> FKE_M.IntegerField(; kw...),
    "PositiveSmallIntegerField" => kw -> FKE_M.PositiveSmallIntegerField(; kw...),
    "PositiveIntegerField"      => kw -> FKE_M.PositiveIntegerField(; kw...),
    "BigIntegerField"           => kw -> FKE_M.BigIntegerField(; kw...),
    "BooleanField"              => kw -> FKE_M.BooleanField(; kw...),
    "DateField"                 => kw -> FKE_M.DateField(; kw...),
    "DateTimeField"             => kw -> FKE_M.DateTimeField(; kw...),
    "DecimalField"              => kw -> FKE_M.DecimalField(; kw...),
    "EmailField"                => kw -> FKE_M.EmailField(; kw...),
    "PasswordField"             => kw -> FKE_M.PasswordField(; kw...),
    "FloatField"                => kw -> FKE_M.FloatField(; kw...),
    "ImageField"                => kw -> FKE_M.ImageField(; kw...),
    "FileField"                 => kw -> FKE_M.FileField(; kw...),
    "TextField"                 => kw -> FKE_M.TextField(; kw...),
    "TimeField"                 => kw -> FKE_M.TimeField(; kw...),
    "BinaryField"               => kw -> FKE_M.BinaryField(; kw...),
    "DurationField"             => kw -> FKE_M.DurationField(; kw...),
    "UUIDField"                 => kw -> FKE_M.UUIDField(; kw...),
    "URLField"                  => kw -> FKE_M.URLField(; kw...),
    "SlugField"                 => kw -> FKE_M.SlugField(; kw...),
    "JSONField"                 => kw -> FKE_M.JSONField(; kw...),
    "ForeignKey"                => kw -> FKE_M.ForeignKey("Driver"; kw...),
    "ManyToManyField"           => kw -> FKE_M.ManyToManyField("Driver"; kw...),
    "OneToOneField"             => kw -> FKE_M.OneToOneField("Driver"; kw...),
)

# Each probe sets ONE keyword, so a default flip surfaces as a diff on exactly that constructor and
# field rather than smearing across the row. Both polarities are probed for the three keywords whose
# default varies, since only an explicit `false` catches a default wrongly forced to `true`.
const FKE_PROBES = [
    ("bare",           NamedTuple()),
    ("verbose_name",   (verbose_name = "VN",)),
    ("unique_true",    (unique = true,)),
    ("unique_false",   (unique = false,)),
    ("blank_true",     (blank = true,)),
    ("null_true",      (null = true,)),
    ("db_index_true",  (db_index = true,)),
    ("db_index_false", (db_index = false,)),
    ("db_column",      (db_column = "col_x",)),
    ("editable_true",  (editable = true,)),
    ("editable_false", (editable = false,)),
]

# Full struct state as a stable string. Functions (the `formatter` field) compare by name — two
# closures are not usefully `==`, but a changed formatter must still be caught.
function _fke_render(x)
    io = IOBuffer()
    for f in fieldnames(typeof(x))
        v = getfield(x, f)
        print(io, f, "=", v isa Function ? string(nameof(v)) : repr(v), ";")
    end
    return String(take!(io))
end

function _fke_actual()
    rows = String[]
    for name in sort(collect(keys(FKE_CTORS)))
        for (label, kw) in FKE_PROBES
            line = try
                _fke_render(FKE_CTORS[name](kw))
            catch e
                "ERROR:" * string(typeof(e))
            end
            push!(rows, string(name, "|", label, "|", line))
        end
    end
    return rows
end

if get(ENV, "FKE_REGEN", "") == "1"
    # Deliberate regeneration — for when a default INTENTIONALLY changes. The fixture diff is part
    # of the change and gets reviewed like code.
    rows = _fke_actual()
    open(FKE_FIXTURE, "w") do io
        foreach(r -> println(io, r), rows)
    end
    @info "Regenerated field-kwargs fixture" file = FKE_FIXTURE rows = length(rows)
else

# ─────────────────────────────────────────────────────────────────────────────
# Field constructors produce byte-identical structs before and after #260
# Compares every constructor's full struct state against the frozen fixture. A mismatch means a
# default or a stored value moved — deliberate or not.
# ─────────────────────────────────────────────────────────────────────────────
@testset "field constructor kwargs equivalence (#260)" begin
    @test isfile(FKE_FIXTURE)

    expected = readlines(FKE_FIXTURE)
    actual = _fke_actual()

    # Guard the guard: an empty or truncated harness would pass a naive comparison.
    @test length(actual) == length(FKE_CTORS) * length(FKE_PROBES)
    # 26 constructors x 11 probes. Was 297 until #408 retired AutoField, which took 11 rows with it.
    @test length(actual) >= 286
    # No probe may error — every common keyword must remain accepted (or ignored with a warning) by
    # every constructor. An ERROR row would mean a keyword stopped being accepted, which breaks the
    # `Model_to_str` round-trip contract (generated model files reload through this kwargs form).
    @test all(r -> !startswith(split(r, "|"; limit = 3)[3], "ERROR:"), actual)

    if actual != expected
        # Report only the differing rows — 286 identical lines are noise.
        diffs = String[]
        for (a, e) in zip(actual, expected)
            a == e || push!(diffs, string("  expected: ", e, "\n  actual:   ", a))
        end
        length(actual) != length(expected) &&
            push!(diffs, "  row count changed: $(length(expected)) → $(length(actual))")
        @error """
        A field constructor's observable result changed.

        If this was NOT intended, a default was flipped — check the per-constructor overrides in
        `_common_kwargs` against the table in this file's docstring.

        If it WAS intended, regenerate the fixture and review its diff as part of the change:
          FKE_REGEN=1 julia --project=. test/unit/test_field_kwargs_equivalence.jl
        """ * join(diffs, "\n")
    end
    @test actual == expected
end

# ─────────────────────────────────────────────────────────────────────────────
# Unaccepted keywords are warned about and GENUINELY ignored (#260 review finding)
# The pre-#260 preambles never extracted a keyword outside the accepted set, so even a wrongly-typed
# value slid by with just the "It will be ignored" warning. The first version of `_common_kwargs`
# read every common keyword from kwargs regardless, which turned that into warn-then-throw — the
# warning lied. The snapshot testset above cannot see this (it probes valid inputs only), so it is
# pinned here. Mutation: revert `_take` to a plain `get(kwargs, …)` and this fails.
# ─────────────────────────────────────────────────────────────────────────────
@testset "unaccepted keywords are warned and ignored (#260)" begin
    # IntegerField does not accept primary_key: a wrongly-typed value must not reach a guard.
    f = @test_logs (:warn, r"Unexpected parameter for IntegerField") FKE_M.IntegerField(primary_key = "not-a-bool")
    @test f.primary_key === false          # the constructor's hardcoded value, untouched

    # A correctly-typed unaccepted keyword is equally ignored — not silently honored.
    f2 = @test_logs (:warn, r"Unexpected parameter for IntegerField") FKE_M.IntegerField(primary_key = true)
    @test f2.primary_key === false
end

end # FKE_REGEN
