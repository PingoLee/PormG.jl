"""
The public CONSTRUCTOR surface accepts any `AbstractString` (#603) — the third and widest slice of
the `::String`-not-`AbstractString` class that #598 opened and #602 continued.

Run: `julia --project=test/integration test/unit/test_constructor_abstractstring.jl`

## The contract

A Julia web app hands PormG the strings its framework produced. `split(query_string, "=")[2]` is a
`SubString{String}`; interpolation helpers yield a `LazyString`. Neither is a `String`, and a
signature that demands one refuses a value that is already exactly what it asked for.

#598 fixed the value formatters and #602 the Dialect renderers, so the FILTER path has held since
then. What did not was everything a caller CONSTRUCTS, and it failed in two distinguishable ways:

  - **A hard `MethodError`**, naming an internal signature the caller never wrote: `F`, the 13
    scalar SQL functions, `Cast`, `Extract`, `ToChar`, `_check_function`, and the positional `to`
    of `ForeignKey` / `OneToOneField` / `ManyToManyField`.
  - **A WRONG-REASON refusal**, where a generic `else` arm exists and answers with a diagnosis that
    was never true of the value: `values(split(s, ",")[1])` was told to "use a string field name"
    when it had passed one, and `F("surname") == split(s, ",")[1]` was told its TYPE was
    unsupported when only its spelling was.

Two measurements recorded here because they changed the shape of the fix:

  1. **Conversion at the seam is mandatory, not stylistic.** A struct slot typed `Union{String, …}`
     WITHOUT `Nothing` has no `convert` fallback and rejects a `SubString` outright. Four such
     containers sit directly downstream — `FieldPart`, `WindowPartitionPart`, `WindowOrderPart` and
     the bulk-filter accumulator — so widening a signature without converting only moves the
     `MethodError` one frame deeper. Slots that ARE `Union{…,Nothing}` convert for free.
  2. **`fields.jl`'s `!(type isa String)` guard is deleted rather than widened**, because the two
     lines around it already do its whole job. No STRING spelling could reach it — `DateTimeField`
     pipes `type` through `uppercase` first, which returns a plain `String` for any `AbstractString`.
     It was not dead for every input, though: `uppercase` has an `AbstractChar` method, so
     `type = 'T'` DID reach it, and the shape check below absorbs that with the same exception type.
     Both halves pinned below — the deletion's safety argument is the `Char` row, not the string one.

`String(x)`, never `string(x)`, at every conversion site — `string` is the identity for a
`LazyString` (measured in #598; the Base-level assertions live in that file and are not repeated
here).

## Two probe types, as in `test_formatter_abstractstring.jl` and `test_dialect_abstractstring.jl`

`SubString{String}` catches the dispatch defect; `LazyString` is neither `String`- nor
`SubString{String}`-backed and so is the only dependency-free way to reach a value the `convert`
fallbacks and the regex engine both refuse. Do not delete either as redundant — the sibling files
explain why at length.

## Mutation gates

Stated per testset. The dominant one is structural: every rendered-SQL testset asserts equality
against the **`String` baseline**, so re-narrowing any widened signature turns the comparison into a
thrown exception. Deterministic, DB-free, no connection — every query renders through a mock.
"""

using Test
using PormG
using PormG.Functions

const Mo603 = PormG.Models
const QB603 = PormG.QueryBuilder

# Probes. `_sub603` is a view with a NON-zero offset into its parent (see the sibling files);
# `_lazy603` is the spelling that is neither `String` nor `SubString{String}`. Named with the issue
# number because all three AbstractString files load into `Main` under `runtests.jl`.
_sub603(s::String) = SubString("\0" * s, 2)
_lazy603(s::String) = LazyString(s)

# The three spellings every surface is swept with. `identity` is the `String` baseline arm.
const _PROBES603 = (identity, _sub603, _lazy603)

struct _MockPg603 <: PormG.PormGPostgres end

# Build the F1-shaped model this file renders against. A helper rather than a global, so each
# testset owns its own handle and none can mutate another's `connect_key`.
function _drivers603(key::String)
  d = Mo603.Model("drivers",
    id      = Mo603.IDField(),
    surname = Mo603.CharField(max_length = 100),
    points  = Mo603.FloatField(),
    wins    = Mo603.IntegerField(),
  )
  d.connect_key = key
  return d
end

# Register a mock connection under its OWN config key, run `f`, and always clean up — `finally`, so
# an error mid-block cannot leak the key into the shared `runtests.jl` process.
function _with_mock603(f, key::String)
  PormG.config[key] = PormG.Configuration.Settings(connections = _MockPg603(), change_data = true)
  try
    f(_drivers603(key))
  finally
    delete!(PormG.config, key)
  end
end

# The workhorse assertion: render `build(probe)` for all three spellings and require the SQL text
# and the bound parameters to be identical. Returns the baseline so a caller can assert its shape.
function _same_render603(build)
  base = build(identity)
  for probe in (_sub603, _lazy603)
    wide = build(probe)
    @test wide[:sql_text]   == base[:sql_text]
    @test wide[:parameters] == base[:parameters]
  end
  return base
end

@testset "SECTION: The public constructor surface accepts any AbstractString (#603)" begin

  # ─────────────────────────────────────────────────────────────────────────────
  # Probes: the two spellings are what this file claims they are
  # `_sub603` must be a genuine view at a non-zero offset (a whole-parent view behaves like a plain
  # `String` and would hide the dispatch defect), and `_lazy603` must be neither `String` nor
  # `SubString{String}` — that asymmetry is why there are two probes rather than one.
  # Mutation gate: none — this is a Base-facts pin, asserted so the rest of the file means what it
  # says. The `string`/`String` measurement itself lives in `test_formatter_abstractstring.jl`.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "The probes are what this file claims they are" begin
    @test _sub603("points") isa SubString{String}
    @test _sub603("points").offset == 1          # a real view into "\0points", not a whole-parent one
    @test _sub603("points") == "points"
    @test _lazy603("points") isa LazyString
    @test _lazy603("points") == "points"
    @test !(_lazy603("points") isa Union{String, SubString{String}})
    # The conversion the whole fix rests on, and the reason it is `String` and not `string`.
    @test String(_lazy603("points")) isa String
    @test String(_lazy603("points")) == "points"
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # Structural pin: the containers that make conversion mandatory rather than stylistic
  # A `Union{String, …}` slot WITHOUT `Nothing` has no `convert` fallback, so widening a signature
  # and storing the value unconverted only relocates the `MethodError` one frame deeper. This is the
  # measurement the fix's shape was derived from, asserted rather than left in prose.
  # Mutation gate: none — a Base/`types.jl` fact. It fails if one of those unions ever gains
  # `Nothing`, which would make every conversion in this file look redundant when it is not.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "A Union slot without Nothing rejects a view, which is why every seam converts" begin
    @test_throws MethodError convert(Union{String, Int}, _sub603("x"))
    @test convert(Union{String, Nothing}, _sub603("x")) == "x"   # …but with `Nothing` it converts
    @test convert(Union{String, Nothing}, _sub603("x")) isa String
    # The real slot, reached through its real constructor: `SQLField`'s `FieldPart`.
    @test QB603.SQLField(String(_sub603("points"))).field == "points"
    @test_throws MethodError QB603.SQLField(_sub603("points"))  # unconverted — the deeper death
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # `F`: the single most-used constructor on the surface
  # `F(field_name::String)` was the ONLY method, so every non-`String` spelling was a bare
  # `MethodError` — while its two siblings `CTE(::AbstractString, …)` and `Joined(::AbstractString, …)`
  # had already been widened. The slots it fills (`field_name`, `column`) are `String`-typed, so the
  # value is normalized at entry and the built node must be indistinguishable from the `String` one.
  # Mutation gate: re-narrow `F` to `::String` and both probe rows raise `MethodError`.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "F(::AbstractString)" begin
    base = F("points")
    for probe in _PROBES603
      f = F(probe("points"))
      @test f.field_name == base.field_name == "points"
      @test f.column == base.column
      # Normalized, not merely accepted: a view stored in the node would reach the renderer.
      @test f.field_name isa String
      @test f.column isa String
    end
    # Widening the accepted TYPE never widened what is accepted.
    @test_throws MethodError F(42)
    @test_throws MethodError F(:points)
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # The 13 single-method scalar constructors, plus Cast / Extract / ToChar / Concat
  # Each was hand-written with the identical 7-member union naming `String`, and each stores its
  # argument RAW into `FObject.column` — so the fix is the signature AND a conversion. Swept as a
  # table rather than one testset each: they are one defect with 13 instances, and a table makes a
  # newly-added constructor that forgets the widening visible as a missing row.
  # Mutation gate: re-narrow any one of them and its row raises `MethodError`.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "The scalar SQL function constructors" begin
    unary = (Lower, Upper, Length, Abs, Trim, LTrim, RTrim, Floor, Ceil, Sqrt, Exp, Ln)
    @test length(unary) == 12          # + `Round`, which takes a precision, = the 13 of the issue
    for ctor in unary
      base = ctor("points")
      for probe in _PROBES603
        wide = ctor(probe("points"))
        @test wide.function_name == base.function_name
        @test wide.column == base.column == "points"
        @test wide.column isa String   # normalized, not stored as a view
      end
      @test_throws MethodError ctor(42)
    end

    for probe in _PROBES603
      @test Round(probe("points"), 2).column == "points"
      @test Round(probe("points")).column isa String          # the defaulted-arity method too

      @test Cast(probe("points"), probe("INTEGER")).kwargs["type"] == "INTEGER"
      @test Cast(probe("points"), probe("INTEGER")).kwargs["type"] isa String
      @test Cast(probe("points"), "INTEGER").column isa String

      @test Extract(probe("date"), probe("year")).kwargs["part"] == "year"
      @test Extract(probe("date"), probe("year")).kwargs["part"] isa String
      # (The 3-arg `Extract(x, part, format)` arity was retired by #691.)

      @test ToChar(probe("date"), probe("YYYY")).kwargs["format"] == "YYYY"
      @test ToChar(probe("date"), probe("YYYY")).kwargs["format"] isa String

      # `Concat`'s Class-B slots are its KEYWORDS — keywords do not dispatch, so a wrong type is a
      # `TypeError` rather than a wrong-reason message.
      @test Concat(["a", "b"]; _as = probe("z")).kwargs["as"] == "z"
      @test Concat(["a", "b"]; _as = probe("z")).kwargs["as"] isa String
      @test Coalesce("points", "wins"; output_field = probe("INTEGER")).kwargs["output_field"] == "INTEGER"
    end

    # `Concat`'s vector ELEMENTS, and the container that holds them.
    #
    # These rows used to pin `Vector{String}` and said so explicitly: the homogeneous vector could
    # not be rendered at all, before or after #603, because it reached
    # `_check_function(::Vector{String})` — the arm that reads a whole vector as one already-split
    # `__@` path — and raised `FilterError: "forename__@surname" is invalid`. That was recorded here
    # as a PRE-EXISTING defect measured identical on both sides of the #603 diff, and filed
    # separately. #612 is that filing, so the recorded expectation is now the fixed one: the
    # container is `Vector{Any}` and every spelling renders.
    #
    # Elements are still normalized to `String` — that half of #603 is unchanged and still gated,
    # because `_check_function`'s walk assigns back into this vector in place.
    @test Concat(["forename", "surname"]).column isa Vector{Any}
    @test Concat(["forename", "surname"]).column == ["forename", "surname"]
    @test all(e -> e isa String, Concat(collect(split("forename,surname", ","))).column)
    @test Concat(collect(split("forename,surname", ","))).column == ["forename", "surname"]
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # The five aggregates, and the five window VALUE functions — found by review, not by the sweep
  # Two different shapes of the same defect, and neither was in the issue's table:
  #
  #   - `Sum`/`Avg`/`Count`/`Max`/`Min` take `x` UNTYPED, so there is no signature to refuse a view;
  #     it rides straight into `FObject.column` and dies in `convert` there. Plausibly the
  #     most-called constructors in the library, and the doc page that promises this behaviour uses
  #     them 21 times in its own examples.
  #   - `Lag`/`Lead`/`FirstValue`/`LastValue`/`NthValue` dispatch on `WindowColumnPart`, which names
  #     the concrete `String`. The inconsistency was visible inside a single expression: after the
  #     first pass `WindowOver(partition_by = sub(...))` worked while `FirstValue(sub(...))` in the
  #     same `values(...)` call did not.
  # Mutation gate: drop `_norm_fn_arg` from any aggregate body, or re-narrow `WindowColumnArg` to
  # `WindowColumnPart`, and the matching rows raise `MethodError`.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "The aggregates and the window value functions" begin
    # Structural rows FIRST. A testset aborts at its first exception, so a mutation run that
    # re-narrows an aggregate would never reach these if they sat at the bottom — and they are the
    # two that describe the design, not just the behaviour.
    # `WindowColumnPart` stays the STORAGE slot's type and must NOT have been widened: the
    # constructors normalize instead. Collapsing the two would re-admit a view into the node.
    @test !(SubString{String} <: QB603.WindowColumnPart)
    @test SubString{String} <: QB603.WindowColumnArg
    # Derived, never restated — the drift direction `test_node_admission.jl` cannot see is a member
    # added to the ARG union alone, which would be admitted and then die inside `convert` on the
    # slot. Deriving makes that unrepresentable; this row is what keeps it derived.
    @test QB603.WindowColumnArg === Union{QB603.WindowColumnPart, AbstractString}

    for (ctor, sqlname) in ((Sum, "SUM"), (Avg, "AVG"), (Count, "COUNT"), (Max, "MAX"), (Min, "MIN"))
      base = ctor("points")
      for probe in _PROBES603
        wide = ctor(probe("points"))
        @test wide.function_name == base.function_name == sqlname
        @test wide.column == base.column == "points"
        @test wide.column isa String        # normalized, not a view stored in the node
        @test wide.aggregate
      end
    end

    for ctor in (Lag, Lead, FirstValue, LastValue)
      base = ctor("points")
      for probe in _PROBES603
        wide = ctor(probe("points"))
        @test wide.function_name == base.function_name
        @test wide.column == base.column == "points"
        @test wide.column isa String
      end
    end
    for probe in _PROBES603
      @test NthValue(probe("points"), 2).column == "points"
      @test NthValue(probe("points"), 2).column isa String
    end
    # `nothing` is a member of both unions and must stay one — `Rank()`-style windows carry no column.
    @test FirstValue(nothing).column === nothing
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # Keyword ANNOTATIONS do not convert — they raise `TypeError`, outside the taxonomy
  # A struct slot converts an `AbstractString` when its type is `Union{String,Nothing}`; a keyword
  # type annotation never does. So `WindowOver(frame = …)` — the third keyword on a constructor
  # whose other two were widened in the first pass — and `SQLOrder`'s `orientation` / `_as` raised a
  # bare `TypeError`, which `catch PormGError` does not catch. That is the same taxonomy escape as
  # the bulk-filter `push!`, in a different disguise.
  # Mutation gate: re-narrow any of the three annotations and its row raises `TypeError`. The two
  # Base-fact rows are PINS, not gates — they pass either way, and say so where they sit.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "Keyword annotations: WindowOver(frame=) and SQLOrder(orientation=, _as=)" begin
    # The #77 orientation whitelist must survive the widening — the security-shaped row in this
    # file, so it runs FIRST: a testset aborts at its first exception, and a mutation run that
    # re-narrows the annotation would otherwise never reach it.
    err = try
      QB603.SQLOrder("points"; orientation = _sub603("DESC; DROP TABLE driver"))
      nothing
    catch e
      e
    end
    @test err isa PormG.QueryBuildError            # the taxonomy subtype, not the root
    @test occursin("orientation", sprint(showerror, err))
    @test_throws PormG.QueryBuildError QB603.SQLOrder("points"; orientation = _lazy603("SIDEWAYS"))

    # Two PINS, not gates: they document the premise the rest of this testset rests on — a keyword
    # ANNOTATION does not convert, while a struct SLOT of the same type does.
    @test_throws TypeError (((; k::String = "") -> k)(k = _sub603("x")))
    @test convert(Union{String, Nothing}, _sub603("x")) isa String

    for probe in _PROBES603
      spec = WindowOver(partition_by = "surname", frame = probe("ROWS UNBOUNDED PRECEDING"))
      @test spec.frame == "ROWS UNBOUNDED PRECEDING"
      @test spec.frame isa String

      asc = QB603.SQLOrder("points"; orientation = probe("ASC"), _as = probe("p"))
      desc = QB603.SQLOrder("points"; orientation = probe("DESC"))
      @test asc.orientation == "ASC" && desc.orientation == "DESC"
      @test asc.orientation isa String
      @test asc._as == "p" && asc._as isa String
      # The whitelist normalizes as well as refusing — lowercase in, canonical out.
      @test QB603.SQLOrder("points"; orientation = probe("desc")).orientation == "DESC"
    end
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # `_normalize_bulk_columns`: the twin of `_normalize_bulk_filters`, 130 lines up in one file
  # Same two failure modes as its sibling — the `AbstractString` guard admitted a view the
  # `String`-typed accumulator then refused on `push!` with a raw `MethodError`, and the
  # `Pair{String,String}` guard refused a `SubString`-keyed rename as an "Invalid column
  # specification". `columns` is the adjacent keyword to `filters` on the same `bulk_*` call.
  # Mutation gate: revert either guard or the normalization — the scalar row raises `MethodError`
  # and the pair row the wrong-reason `QueryBuildError`.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "_normalize_bulk_columns: scalar, rename pair and vector spellings" begin
    for probe in _PROBES603
      @test QB603._normalize_bulk_columns(probe("surname")) == ["surname"]
      @test QB603._normalize_bulk_columns(probe("surname"))[1] isa String
      @test QB603._normalize_bulk_columns([probe("surname"), probe("pts") => probe("points")]) ==
            ["surname", "pts" => "points"]
      renamed = QB603._normalize_bulk_columns([probe("pts") => probe("points")])[1]
      @test renamed.first isa String && renamed.second isa String
    end
    @test isempty(QB603._normalize_bulk_columns(nothing))
    # `_normalize_bulk_match_on` was ALREADY safe — its accumulator is a concrete `Vector{String}`,
    # which converts on `push!`. Pinned so a later "consistency" edit does not break what works.
    @test QB603._normalize_bulk_match_on(_sub603("driverid")) == ["driverid"]
    @test_throws PormG.QueryBuildError QB603._normalize_bulk_columns(42)
    @test_throws PormG.QueryBuildError QB603._normalize_bulk_columns([42])
    # The rename pair needs its negative side too, and here it earns one: this normalizer converts
    # `.second` while its sibling `_normalize_bulk_filters` deliberately leaves it alone, so the two
    # `_norm` closures are NOT interchangeable. The `<:AbstractString` bound on `.second` is the only
    # thing stopping a "consistency" edit from coercing `"pts" => :sym` into `"pts" => "sym"` while
    # `"pts" => 1` dies in `String(1)` with a raw `MethodError`.
    @test_throws PormG.QueryBuildError QB603._normalize_bulk_columns("pts" => 1)
    @test_throws PormG.QueryBuildError QB603._normalize_bulk_columns("pts" => :sym)
    @test_throws PormG.QueryBuildError QB603._normalize_bulk_columns([:pts => "points"])
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # `_check_function`: the single consumer arm the widened surface owes under #533
  # #533's rule is "a consumer per admitted member" — widening a union is half a change. This is the
  # other half for the string member, and the point every Class-C site of #602 used to die at.
  # The `Vector{<:AbstractString}` arm is the subtle one: without it a `Vector{SubString}` lands on
  # the generic `Vector{T}` arm and is resolved ELEMENT BY ELEMENT, which is different semantics
  # from the `Vector{String}` arm that reads the vector as ONE already-split `__@` path. Widening
  # the scalar arm alone would have turned today's `MethodError` into a silently wrong answer.
  # Mutation gate: delete either arm — the scalar rows raise `MethodError`, and the vector rows stop
  # resolving `"date__@year"` through the transform.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "_check_function(::AbstractString) and the vector arm" begin
    # `FObject` is a struct holding a `Dict`, so the default `==` compares field identities and two
    # structurally identical nodes never compare equal. Compare the SHAPE instead — which is also
    # the only part that decides the rendered SQL.
    _shape603(x) = x isa QB603.FObject ? (x.function_name, _shape603(x.column), x.kwargs) : x

    base_plain     = QB603._check_function("surname")
    base_transform = QB603._check_function("date__@year")
    @test base_plain == "surname"                              # the no-transform path returns the name
    @test _shape603(base_transform)[1] == "EXTRACT"            # …and the transform path an FObject
    for probe in _PROBES603
      @test QB603._check_function(probe("surname")) == base_plain
      @test _shape603(QB603._check_function(probe("date__@year"))) == _shape603(base_transform)
    end
    # An already-split path must take the `Vector{String}` semantics whatever its element type —
    # ONE `__@` path, not a vector of independently resolved names.
    @test _shape603(QB603._check_function(String.(split("date__@year", "__@")))) == _shape603(base_transform)
    @test _shape603(QB603._check_function(collect(split("date__@year", "__@")))) == _shape603(base_transform)
    @test _shape603(QB603._check_function(LazyString[_lazy603("date"), _lazy603("year")])) == _shape603(base_transform)
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # `OP`: internal (#202), but both of its arguments were `::String`
  # Not user-reachable by the public spelling — `"field__@op" => value` is the documented form — so
  # this is a type-contract row, not a live repro. Widening only the column would have left
  # `OP("col", SubString(">="), v)` a `MethodError`, which is why the operator is asserted too.
  # Mutation gate: re-narrow either parameter and the matching row raises `MethodError`.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "OP(::AbstractString, [::AbstractString,] value)" begin
    for probe in _PROBES603
      two = QB603.OP(probe("points"), 1)
      @test two.operator == "="
      @test two.column.field == "points"
      three = QB603.OP(probe("points"), probe(">="), 1)
      @test three.operator == ">="
      @test three.operator isa String            # normalized into the `String`-typed slot
      @test three.column.field == "points"
    end
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # `values()`: the wrong-reason arm, on all three of its branches
  # `_values!` refuses a non-`String` at the pair KEY, the pair VALUE and the BARE value, and for the
  # last two a generic `else` arm answers "use a string field name" — a diagnosis that was never true
  # of a `SubString`. Rendered SQL is compared against the `String` baseline, so the gate is not
  # "does not throw" but "produces the identical query".
  # Mutation gate: re-narrow any of the three `isa` tests and the matching row throws
  # `QueryBuildError` instead of rendering.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "values(): bare, pair key and pair value" begin
    _with_mock603("constructor_abstractstring_603_values") do d
      _same_render603(p -> d.objects.values(p("surname")).list(show_query = :dict))
      _same_render603(p -> d.objects.values(p("alias") => "surname").list(show_query = :dict))
      _same_render603(p -> d.objects.values("alias" => p("surname")).list(show_query = :dict))
      _same_render603(p -> d.objects.values("l" => Lower(p("surname"))).list(show_query = :dict))
      # The variadic `Concat` — the documented spelling, and the one that carries the rendering
      # guarantee the vector form cannot (see the note in the scalar-constructor testset).
      _same_render603(p -> d.objects.values(
        "c" => Concat(p("surname"), Value(" "), p("surname"))
      ).list(show_query = :dict))

      # The widened TYPE did not widen the accepted SHAPE — and this is the wrong-reason
      # discriminator for the whole testset. The SHAPE arm interpolates the offending value; the
      # generic TYPE arm cannot, because it never looked at one. Before the fix a `SubString` got
      # the type message, so both assertions below failed.
      for probe in _PROBES603
        err = try
          d.objects.values(probe("surname__@lte")).list(show_query = :dict)
          nothing
        catch e
          e
        end
        @test err isa PormG.QueryBuildError
        msg = sprint(showerror, err)
        @test occursin("Invalid values() field \"surname__@lte\"", msg)
        @test !occursin("use a string field name", msg)
      end

      # Genuinely wrong types keep their own refusals, unchanged.
      @test_throws PormG.QueryBuildError d.objects.values(42).list(show_query = :dict)
      @test_throws PormG.QueryBuildError d.objects.values(:sym => 1).list(show_query = :dict)
      @test_throws PormG.QueryBuildError d.objects.values("k" => 42).list(show_query = :dict)
    end
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # `order_by()`: refused at DISPATCH, not in a branch
  # The typed method's `NTuple{N,Union{String,…}}` element bound means one `SubString` anywhere in
  # the tuple sends the WHOLE call to the catch-all — so a mixed `("surname", split(s,",")[1])` was
  # refused too, which the mixed row below pins. The leading `-` marker also matters: `v[2:end]` on a
  # `SubString` yields another `SubString`, so normalizing late would still hand `SQLField` a view.
  # Mutation gate: re-narrow the signature or the branch and every row throws `QueryBuildError`.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "order_by(): ascending, descending and mixed tuples" begin
    _with_mock603("constructor_abstractstring_603_order") do d
      asc  = _same_render603(p -> d.objects.order_by(p("surname")).list(show_query = :dict))
      desc = _same_render603(p -> d.objects.order_by(p("-points")).list(show_query = :dict))
      @test occursin("ASC", asc[:sql_text])
      @test occursin("DESC", desc[:sql_text])
      # The mixed tuple: one wide element used to poison the whole call at dispatch.
      _same_render603(p -> d.objects.order_by("surname", p("-points")).list(show_query = :dict))

      for probe in _PROBES603
        err = try
          d.objects.order_by(probe("surname__@lte")).list(show_query = :dict)
          nothing
        catch e
          e
        end
        @test err isa PormG.QueryBuildError
        msg = sprint(showerror, err)
        @test occursin("Invalid order_by() field \"surname__@lte\"", msg)
        @test !occursin("Invalid order_by() argument", msg)   # NOT the generic catch-all
      end

      @test_throws PormG.QueryBuildError d.objects.order_by(42).list(show_query = :dict)
    end
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # `db()`: one guard conflating three failures
  # `_db!` refuses empty / too-many / wrong-type with a single message, so a `SubString` database key
  # was told it was the wrong ARITY as much as the wrong type. `connect_key` is `OptionalString` and
  # would have converted for free — the guard above it was the only thing in the way.
  # Mutation gate: re-narrow the `isa` and the probe rows throw instead of rendering.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "db(::AbstractString)" begin
    _with_mock603("constructor_abstractstring_603_db") do d
      _same_render603(p -> d.objects.db(p("constructor_abstractstring_603_db")).values("surname").list(show_query = :dict))
      # The arity half of the same guard is untouched.
      @test_throws PormG.QueryBuildError d.objects.db(42).list(show_query = :dict)
      @test_throws PormG.QueryBuildError d.objects.db("a", "b").list(show_query = :dict)
    end
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # Bulk filters: the taxonomy ESCAPE, which is worse than the issue described
  # `_normalize_bulk_filters` already said `AbstractString` at its scalar guard — so a bare
  # `SubString` PASSED validation and then died on the `push!` into the `String`-typed accumulator
  # with a raw `MethodError`, outside the PormG error taxonomy entirely. The same value inside a
  # `Vector` hit the other guard, which said `String`, and got the wrong-reason message instead. One
  # function, both failure modes.
  # Mutation gate: revert either guard or the normalization — the scalar row raises `MethodError`
  # and the vector row raises the "Invalid filter specification" `QueryBuildError`.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "_normalize_bulk_filters: scalar, pair and vector spellings" begin
    for probe in _PROBES603
      @test QB603._normalize_bulk_filters(probe("surname")) == ["surname"]
      @test QB603._normalize_bulk_filters([probe("surname"), probe("points") => 1]) ==
            ["surname", "points" => 1]
      # Normalized on the way in: a view must not survive into the accumulator, which is the half
      # that used to raise a bare `MethodError` rather than a PormG error.
      @test all(f -> f isa String || f.first isa String,
                QB603._normalize_bulk_filters([probe("surname"), probe("points") => 1]))
      @test QB603._normalize_bulk_filters(probe("surname"))[1] isa String
    end
    @test isempty(QB603._normalize_bulk_filters(nothing))
    # The real refusals are untouched, and they are still taxonomy types rather than `MethodError`s.
    @test_throws PormG.QueryBuildError QB603._normalize_bulk_filters(42)
    @test_throws PormG.QueryBuildError QB603._normalize_bulk_filters([42])
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # The window path: two container blockers upstream of the resolver
  # `WindowPartitionPart` / `WindowOrderPart` are `Union{String,…}` without `Nothing`, and the
  # vectors built from them reject a view on `push!` — so `_window_part_vector`'s guard refused a
  # `SubString` with "entries must be strings", which it plainly was. `_resolve_window_expression`
  # is the second site, reached at build time rather than at construction.
  # Mutation gate: remove either normalization and the probe rows throw `QueryBuildError`
  # ("must be strings"), or "Unsupported window expression … of type SubString{String}".
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "WindowOver partition_by / order_by" begin
    _with_mock603("constructor_abstractstring_603_window") do d
      base = _same_render603(p -> d.objects.values(
        "r" => Rank(over = WindowOver(partition_by = p("surname"), order_by = p("-points")))
      ).list(show_query = :dict))
      @test occursin("OVER", base[:sql_text])
      @test occursin("PARTITION BY", base[:sql_text])

      # Normalized into the spec itself, not merely accepted at the call.
      for probe in _PROBES603
        spec = WindowOver(partition_by = probe("surname"), order_by = probe("-points"))
        @test spec.partition_by == ["surname"]
        @test all(x -> x isa String, spec.partition_by)
        @test all(x -> x isa String, spec.order_by)
      end
      @test_throws PormG.QueryBuildError WindowOver(partition_by = 42)
    end
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # `F(...) == value`: the operand vocabulary, normalized at the operator
  # `_CompareLiteral` names `String`, so a `SubString` right-hand side missed `_CompareOperand` and
  # landed on the generated catch-all — a TYPED error, but the wrong reason: it listed the supported
  # operand types as though the value were a `Rational`. The fix branches inside that existing
  # catch-all rather than admitting `AbstractString` into the union, because a new member owes an
  # oracle row (#533) and a method on `::AbstractString` beside one on `::_CompareOperand` (which
  # contains `String`) would be ambiguous in both directions.
  # Mutation gate: drop the branch and every probe row raises "is not a supported right-hand side".
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "F and Joined comparisons against a non-String AbstractString" begin
    _with_mock603("constructor_abstractstring_603_cmp") do d
      for op in (==, !=, >, <, >=, <=)
        base = op(F("surname"), "Senna")
        for probe in (_sub603, _lazy603)
          wide = op(F("surname"), probe("Senna"))
          @test wide.operation == base.operation
          @test wide.operand == base.operand == "Senna"
          @test wide.operand isa String     # normalized into the `String`-typed operand slot
        end
      end
      # End to end: the comparison must bind exactly the bytes the `String` spelling binds.
      _same_render603(p -> d.objects.filter(F("surname") == p("Senna")).list(show_query = :dict))

      # A `Joined` handle is the second, independently generated family — asserted, not assumed.
      jbase = Joined("d", "surname") == "Senna"
      for probe in (_sub603, _lazy603)
        @test (Joined("d", "surname") == probe("Senna")).operand == jbase.operand
      end

      # Types genuinely outside the vocabulary keep the refusal, with its own message.
      @test_throws PormG.QueryBuildError F("surname") == 1 // 2
      @test_throws PormG.QueryBuildError F("surname") == missing
      @test_throws PormG.QueryBuildError Joined("d", "surname") == 1 // 2
    end
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # The `fields.jl` family: one helper gating every field constructor, plus the relations
  # `_common_kwargs._str_or_nothing` is the widest single site in this whole class — it validates
  # `verbose_name` and `db_column` for EVERY field type. The relation constructors were split against
  # themselves: `ForeignKey`'s `how`/`related_name` were already `AbstractString` while
  # `OneToOneField`'s identical kwargs were `String`, and `ForeignKey`'s `how` had no conversion at
  # all — so it passed validation and died inside the struct's `Union{String,Nothing}` slot.
  # Mutation gate: re-narrow `_str_or_nothing` and every `verbose_name`/`db_column` row raises
  # `FieldValidationError`; re-narrow a relation kwarg and its row raises `FieldValidationError` or
  # `MethodError`; drop `ForeignKey`'s `how` conversion and the concreteness sweep raises.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "Field constructors: common kwargs and the relation family" begin
    for probe in _PROBES603
      c = Mo603.CharField(max_length = 10, verbose_name = probe("Sobrenome"), db_column = probe("surname"))
      @test c.verbose_name == "Sobrenome"
      @test c.db_column == "surname"
      # Concrete `String`, so nothing hands the DDL path a view.
      @test c.verbose_name isa String
      @test c.db_column isa String

      fk = Mo603.ForeignKey(probe("Driver"); how = probe("LEFT JOIN"),
                            related_name = probe("results"), pk_field = probe("driverid"))
      @test fk.to == "Driver" && fk.how == "LEFT JOIN"
      @test fk.related_name == "results" && fk.pk_field == "driverid"

      o2o = Mo603.OneToOneField(probe("Driver"); how = probe("LEFT JOIN"),
                                related_name = probe("profile"), pk_field = probe("driverid"))
      @test o2o.to == "Driver" && o2o.how == "LEFT JOIN"
      @test o2o.related_name == "profile" && o2o.pk_field == "driverid"

      m2m = Mo603.ManyToManyField(probe("Driver"); through = probe("entries"),
                                  verbose_name = probe("Pilotos"), db_table = probe("driver_race"),
                                  source_field = probe("driverid"), target_field = probe("raceid"))
      @test m2m.to == "Driver" && m2m.through == "entries"
      @test m2m.db_table == "driver_race" && m2m.source_field == "driverid"

      # Every string-bearing slot on all three must be concrete, or a view reaches the migration
      # planner — the failure `ForeignKey`'s unconverted `how` actually produced.
      for field in (fk, o2o, m2m), slot in fieldnames(typeof(field))
        value = getfield(field, slot)
        if value isa AbstractString
          @test value isa String
        end
      end
    end

    # Wrong types keep the taxonomy error they always raised.
    @test_throws PormG.FieldValidationError Mo603.CharField(max_length = 10, verbose_name = 42)
    @test_throws PormG.FieldValidationError Mo603.ForeignKey("Driver"; how = 42)
    @test_throws MethodError Mo603.ForeignKey(42)
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # The deleted guard: what `DateTimeField`'s `!(type isa String)` line actually covered
  # The issue listed it as a site to widen; it is deleted instead, because the two lines around it
  # already do its whole job. No STRING spelling could reach it — `uppercase` one line above returns
  # a plain `String` for every `AbstractString`.
  #
  # It was not dead for every input, though, and that is pinned here rather than glossed: `uppercase`
  # has an `AbstractChar` method, so `type = 'T'` DID reach the guard. The shape check below absorbs
  # it with the same exception type, which is what makes the deletion safe — asserted, not assumed.
  # Mutation gate: deliberately none for the deletion itself — restoring the guard leaves this green.
  # What these rows DO gate is the assumption the deletion rests on: they fail if `uppercase` stops
  # normalizing, or if the shape check stops covering the `Char` the guard used to catch.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "DateTimeField: the lines around the deleted guard cover everything it did" begin
    # The Base facts the deletion rests on.
    @test uppercase(_sub603("timestamp")) isa String
    @test uppercase(_lazy603("timestamp")) isa String
    @test uppercase('t') === 'T'          # …and `uppercase` does NOT raise on a Char

    for probe in _PROBES603
      @test Mo603.DateTimeField(type = probe("TIMESTAMP")).type == "TIMESTAMP"
      @test Mo603.DateTimeField(type = probe("timestamptz")).type == "TIMESTAMPTZ"   # folded, as before
      @test Mo603.DateTimeField(type = probe("TIMESTAMP")).type isa String
      # The SHAPE check below the deleted line still refuses an unsupported type name.
      @test_throws PormG.FieldValidationError Mo603.DateTimeField(type = probe("DATE"))
    end
    # The one input that DID reach the deleted guard: still refused, still the same exception type,
    # now by the shape check instead. This row is the deletion's actual safety argument.
    @test_throws PormG.FieldValidationError Mo603.DateTimeField(type = 'T')
    # And a type `uppercase` has no method for never reached the guard at all — it raises above it.
    @test_throws MethodError Mo603.DateTimeField(type = :TIMESTAMP)
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # Dispatch shape: widening ~45 signatures must not move where a `String` argument lands
  # Aqua's suite-wide ambiguity check in `runtests.jl` is the real backstop. What these rows add is
  # the property Aqua cannot express: that a `String` still reaches the SAME method it always did
  # (so no rendered query can have moved), and that the comparison fix added NO new method — the
  # branch lives inside the pre-existing catch-all, which is what keeps it unambiguous against
  # `_CompareOperand`.
  # Mutation gate: implement the comparison fix as a separate `::AbstractString` method instead and
  # the last two rows fail — the `SubString` call would resolve to a different method than the
  # `Rational` one, and Aqua would report the ambiguity against the `_CompareOperand` arm.
  # ─────────────────────────────────────────────────────────────────────────────
  # #612 — `default=` on the string-field family
  # #603 widened what a field constructor accepts for `verbose_name` / `db_column`; it left
  # `default=` alone, where the accepted spelling was decided by whichever converter lambda each
  # constructor happened to carry. That split the family FIVE ways for one keyword, and the two
  # extremes were opposite failures rather than one shared gap:
  #
  #   - `x -> parse(String, x)`  TextField, EmailField, FileField, ImageField. DEAD CODE:
  #     `parse(String, …)` has no method, so the converter could never run. Every non-`String`
  #     default was refused, and refused with a message blaming the value's TYPE for what was
  #     really a missing conversion.
  #   - `x -> string(x)`  URLField, SlugField. `string` has a method for everything, so NOTHING was
  #     refused: `URLField(default = :nope)` stored `"nope"` and `URLField(default = CharField())`
  #     stored `"CharField()"`. Both measured on the #603 branch, both pinned below as gone.
  #   - an inline `isa` ladder  CharField — the only one that was right.
  #
  # One helper (`_default_string`) is now the whole policy, so the matrix below is deliberately
  # exhaustive rather than spot-checked: the defect was precisely that per-field behaviour diverged,
  # and only a per-field sweep can catch it diverging again.
  # Mutation gate: re-narrow `_default_string`'s first arm to `value isa String` and every probe row
  # for all seven fields raises `FieldValidationError`; drop its `Integer` arm and the numeric rows
  # raise; drop the `Bool` exclusion and the `true` rows stop raising.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "default= is one policy across the string-field family (#612)" begin
    # `max_length` is passed where the field has one so a long default cannot fail for an unrelated
    # reason; every field below stores its `default` in a `Union{String, Nothing}` slot.
    text_fields = (
      ("CharField",  (; kw...) -> Mo603.CharField(; max_length = 100, kw...)),
      ("TextField",  (; kw...) -> Mo603.TextField(; kw...)),
      ("EmailField", (; kw...) -> Mo603.EmailField(; kw...)),
      ("URLField",   (; kw...) -> Mo603.URLField(; kw...)),
      ("SlugField",  (; kw...) -> Mo603.SlugField(; kw...)),
      ("FileField",  (; kw...) -> Mo603.FileField(; kw...)),
      ("ImageField", (; kw...) -> Mo603.ImageField(; kw...)),
    )

    for (name, ctor) in text_fields
      base = ctor(default = "forename")
      @test base.default == "forename"

      for probe in _PROBES603
        f = ctor(default = probe("forename"))
        # Identical to the `String` baseline — the whole point is that the seven now agree.
        @test f.default == base.default == "forename"
        # Normalized, not merely accepted. `String`, never `string`: the latter is the identity for
        # a `LazyString`, so the old `string` spelling only produced a `String` because the struct
        # slot re-converted two frames later.
        @test f.default isa String
      end

      # An Integer rides through as its decimal text. Not new latitude — CharField has always had
      # `default isa Int && (default = string(default))`; the other six now match it instead of
      # refusing (the `parse` four) or accepting far more (the `string` two).
      @test ctor(default = 5).default == "5"
      @test ctor(default = 5).default isa String
      @test ctor(default = Int32(7)).default == "7"      # generalized off Int64

      # `nothing` is still the no-default spelling and is not stringified.
      @test ctor(default = nothing).default === nothing

      # Everything else is refused, by all seven. This is the half that NARROWS URLField and
      # SlugField: before #612 their `string` converter accepted each of these silently.
      @test_throws PormG.FieldValidationError ctor(default = :nope)
      @test_throws PormG.FieldValidationError ctor(default = 3.5)
      @test_throws PormG.FieldValidationError ctor(default = [1, 2])
      # `Bool` stays refused exactly as CharField refused it — `true` in a text column is far more
      # likely a mistake than an intent, and `Bool <: Integer` would otherwise have admitted it.
      @test_throws PormG.FieldValidationError ctor(default = true)
    end

    # The message names the policy rather than a type union the policy no longer matches. Before
    # #612 this came from `validate_default`'s bare `catch`, which reported
    # "Expected type: Union{Nothing, String}" — accurate then, misleading once an Integer is taken.
    err = try Mo603.TextField(default = :nope) catch e; e end
    @test err isa PormG.FieldValidationError
    @test occursin("TextField", sprint(showerror, err))
    @test occursin("Integer", sprint(showerror, err))

    # UUIDField and JSONField are audited, NOT routed through the shared helper: their converters
    # validate the value's SHAPE, a stronger contract than "is it stringy". Measured already clean
    # for all three spellings before #612 — pinned so routing them here later is a deliberate act.
    uuid = "123e4567-e89b-12d3-a456-426614174000"
    for probe in _PROBES603
      @test Mo603.UUIDField(default = probe(uuid)).default == uuid
      @test Mo603.JSONField(default = probe("{\"a\":1}")).default == "{\"a\":1}"
    end
    # …and their VALUE contract is intact, which is why they keep their own converters. Pinned in
    # both directions, because "stricter" is a one-directional word and these two are not: each is
    # stricter than `_default_string` on some inputs and looser on others. The doc bullet for them
    # was wrong twice — once for lumping them into the shared policy, once for calling them merely
    # stricter — and both times because nothing here asserted what they actually accept.
    @test_throws PormG.FieldValidationError Mo603.UUIDField(default = "not-a-uuid")
    @test_throws PormG.FieldValidationError Mo603.JSONField(default = "{not json")
    # UUIDField is stricter in BOTH directions than the text family: an Integer is refused too.
    @test_throws PormG.FieldValidationError Mo603.UUIDField(default = 5)
    # JSONField is LOOSER: it serializes anything `format_json_sql` handles, where the seven
    # plain-text fields refuse every one of these.
    @test Mo603.JSONField(default = 3.5).default == "3.5"
    @test Mo603.JSONField(default = true).default == "true"
    @test Mo603.JSONField(default = [1, 2]).default == "[1,2]"
    @test Mo603.JSONField(default = Dict("a" => 1)).default == "{\"a\":1}"
    for v in Any[3.5, true, [1, 2]]
      @test_throws PormG.FieldValidationError Mo603.TextField(default = v)
    end
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # #612 — `PormGRow`'s read accessors, the READ side of the #603 pattern
  # A value travels out of a row the same way it went into the query: `row[split(spec, ",")[1]]`.
  # `getindex`/`haskey`/`get` were typed `key::String`, so that was a raw `MethodError` naming an
  # internal signature — the identical failure #603 fixed on the write side, one half-turn later.
  # The bodies already did `Symbol(key)`, which takes any `AbstractString`, so the annotation was
  # the entire defect.
  #
  # No conversion needed here, unlike every other seam in this file: the Symbol IS the storage key,
  # so nothing string-typed is retained and no view can reach a slot.
  # Mutation gate: re-narrow any of the three to `::String` and its probe rows raise `MethodError`.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "PormGRow read accessors take any AbstractString (#612)" begin
    model = _drivers603("_612_row")
    row = QB603.PormGRow(Dict{Symbol, Any}(:surname => "Senna", :points => 614.0), model)

    for probe in _PROBES603
      @test row[probe("surname")] == "Senna"
      @test row[probe("points")] == 614.0
      @test haskey(row, probe("surname"))
      @test !haskey(row, probe("nonexistent"))
      @test get(row, probe("surname"), "missing") == "Senna"
      @test get(row, probe("nonexistent"), "fallback") == "fallback"
    end

    # The Symbol methods are untouched and still resolve to their own arms.
    @test row[:surname] == "Senna"
    @test which(getindex, Tuple{QB603.PormGRow, Symbol}) !==
          which(getindex, Tuple{QB603.PormGRow, String})
    # …while all three string spellings now share ONE method, rather than two of them having none.
    @test which(getindex, Tuple{QB603.PormGRow, String}) ===
          which(getindex, Tuple{QB603.PormGRow, SubString{String}}) ===
          which(getindex, Tuple{QB603.PormGRow, LazyString})

    # Widening the accepted TYPE did not widen the accepted SHAPE: an empty `__` segment is still
    # refused, whichever spelling reaches it.
    for probe in _PROBES603
      @test_throws PormG.UnknownFieldError row[probe("driverid__")]
    end
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # #612 — `Model(name)`'s no-fields guard was skipped by a view
  # `Model(name::String)` threw a helpful `ModelDefinitionError`; a `SubString` or `LazyString` fell
  # PAST it to `Model(name::AbstractString; fields...)` with an empty keyword slurp and silently
  # built a fieldless model. `grep "You need to add fields" test/` returned nothing before #612 —
  # the guard had no coverage at all, which is how it stayed half-applied.
  #
  # Not a mechanical widening, and that shaped the fix: Julia identifies a method by its POSITIONAL
  # signature and keywords are not part of it, so `Model(name::AbstractString)` would REDEFINE the
  # kwargs method rather than sit beside it. The check had to move INSIDE — which also closed the
  # arity the old guard never covered, `Model("x", db_table = "t")` with no fields.
  # Mutation gate: move the check back out to a `Model(name::String)` method and the SubString and
  # LazyString rows build a fieldless model instead of throwing; delete it and every row does.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "Model(name) with no fields is refused for every string spelling (#612)" begin
    for probe in _PROBES603
      @test_throws PormG.ModelDefinitionError Mo603.Model(probe("drivers"))
      # The arities the old `Model(name::String)` method could never see, because a method is
      # identified by its positional signature and those calls carry keywords.
      @test_throws PormG.ModelDefinitionError Mo603.Model(probe("drivers"); db_table = "Drivers")
      @test_throws PormG.ModelDefinitionError Mo603.Model(probe("drivers");
                                                          constraints = [], db_table = "Drivers")
    end

    # The message survived the move — it is the one piece of this guard users actually read.
    err = try Mo603.Model("drivers") catch e; e end
    @test err isa PormG.ModelDefinitionError
    @test occursin("You need to add fields to the model", sprint(showerror, err))

    # A model WITH fields is unaffected by the new early return, for every spelling.
    for probe in _PROBES603
      m = Mo603.Model(probe("drivers"), surname = Mo603.CharField(max_length = 100))
      @test m.name == "drivers"
      @test length(m.fields) == 1
      # …and the name is NORMALIZED, not merely accepted (#612 review). `Model_Type.name` is an
      # `AbstractString` slot, so an unconverted view is retained for the model's process lifetime
      # together with its whole parent buffer — a name sliced out of a request string keeps the
      # request. This is the same seam rule the header calls mandatory rather than stylistic.
      @test m.name isa String
    end

    # The measurement that rule exists for: a view into a long buffer must not survive into the
    # model. Asserted on the parent's length, because equality alone cannot see the retention.
    request = "GET /api?table=drivers&" * repeat("x", 120)
    held = Mo603.Model(SubString(request, 16, 22), surname = Mo603.CharField(max_length = 100))
    @test held.name == "drivers"
    @test held.name isa String

    # The three paths that legitimately build from an already-collected field set are NOT gated:
    # `Model(; fields...)` routes through the `NTuple` method, and introspection / the Django
    # importer hand in a Dict. Gating those would break `inspectdb` and `set_models`.
    m = Mo603.Model(surname = Mo603.CharField(max_length = 100))
    @test m.name == "" && length(m.fields) == 1
    d = Mo603.Model("drivers", Dict{String, PormG.PormGField}("surname" => Mo603.CharField(max_length = 100)))
    @test length(d.fields) == 1
  end

  # ─────────────────────────────────────────────────────────────────────────────
  @testset "A String argument still resolves to the same method it always did" begin
    @test which(F, Tuple{String}) === which(F, Tuple{SubString{String}})
    @test which(Lower, Tuple{String}) === which(Lower, Tuple{SubString{String}})
    @test which(Cast, Tuple{String, String}) === which(Cast, Tuple{SubString{String}, SubString{String}})
    @test which(QB603._check_function, Tuple{String}) ===
          which(QB603._check_function, Tuple{SubString{String}})

    # The comparison catch-all serves the wide spelling and the unsupported one from ONE method…
    @test which(==, Tuple{QB603.FExpression, SubString{String}}) ===
          which(==, Tuple{QB603.FExpression, Rational{Int}})
    # …while a `String` keeps taking the specific `_CompareOperand` arm, untouched by this change.
    @test which(==, Tuple{QB603.FExpression, String}) !==
          which(==, Tuple{QB603.FExpression, SubString{String}})
  end
end
