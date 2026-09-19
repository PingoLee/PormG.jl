"""
Unit tests for #598 — the value formatters accept any `AbstractString`, not just `String`.

    julia --project=test/integration test/unit/test_formatter_abstractstring.jl

# The contract

Every value formatter in `src/Models.jl` takes the value a user hands the ORM. `split` returns
`SubString` and a CSV reader can return its own string type, so a non-`String` `AbstractString`
arrives through ordinary application code:

    parts = split(line, ",")
    M.Race.objects.create("start_at" => parts[2])   # MethodError before #598

The formatters are the canonical write/bind path — `src/value_repr.jl` names
`format_timezone_sql` and `format_duration_sql` as slot 1 for `CDateTime` and `CInterval` — and
`querybuilder/sanitization.jl` is `AbstractString`-typed throughout, so a non-`String` value
PASSES validation and only fails at the formatter, where a bare `catch` dresses the failure up as
a field-validation message. That is why this is a contract for the whole family and not a
property of one field type, and why it gets its own file.

# Two distinct defects, which is why there are two probe types

1. **A signature typed `::String`.** A non-`String` `AbstractString` never dispatches
   (`MethodError`), or falls through to a generic arm and is rejected with a wrong reason.
2. **A regex applied to a value that is merely `AbstractString`.** Base defines `match` only for
   `String`, `SubString{String}` and `AnnotatedString`; anything else raises
   `ArgumentError: regex matching is only available for the String and AnnotatedString types`.

`SubString` alone cannot test both. It is one of the three types Base's regex engine *does*
accept, so it catches defect 1 and is blind to defect 2. `LazyString` is in `Base` (no new
dependency) and is neither `String`- nor `SubString{String}`-backed, so it is the only
dependency-free way to reach defect 2. **Do not delete either probe as redundant.**

# `String(x)`, not `string(x)` — measured, not assumed

#598's own write-up proposes mirroring `format_uuid_sql`'s `strip(string(value))`. That spelling
does not hold: `string` is the identity for some `AbstractString`s, so `string(::LazyString)`
returns the `LazyString` and `strip` of it is a `SubString{LazyString}` — the regex still throws.
`format_uuid_sql` never failed only because it uses `occursin`, which HAS a generic fallback
where `match` does not. Every conversion on this path is therefore `String(...)`, including in
`format_uuid_sql` and `format_number_sql`, so the exemplar cannot teach the spelling that fails.
The `Base` facts the fix rests on are pinned in the first testset rather than left implicit.

# Mutation gates

Each testset names its own. Re-narrowing any widened signature to `::String` fails the matching
dispatch assertion, and reverting the conversion in `_duration_from_seconds_string`,
`_normalize_duration_string`, `validate_timezone`, `normalize_sqlite_datetime_string` or
`format_yyyy_mm` fails at least one assertion here.

**One of the eight conversion sites is NOT guarded, and saying so is the point.** Reverting
`format_uuid_sql` (`src/Models.jl`) to `string(...)` leaves this file 100% green — measured, not
assumed — because that method regexes with `occursin`, which has a generic fallback, and returns
`lowercase(s)`, a `String` whichever type came in. Its conversion has no observable consequence at
all; it was normalised so the exemplar cannot teach the spelling that fails elsewhere, which is a
readability change, and a guard pinning it would be pinning a coincidence.

`format_number_sql`'s normalisation started out in the same "unguarded" bucket and turned out NOT
to be: it returns its `strip` result, so the conversion IS observable through the return type, and
it is asserted below. Content equality alone passed either way — which is how the gap was found.

Deterministic, DB-free, no network, no connection.
"""

using Test
using Dates
using PormG

const Mo = PormG.Models

# The two probes. Both spell the SAME text as the `String` baseline each assertion compares
# against, so a failure can only mean the formatter treated the type differently.
# The one-byte prefix is not about the TYPE — `SubString(s)` is already a `SubString{String}`. It
# gives the view a non-zero offset into its parent, so every assertion exercises PCRE's
# offset-into-parent path rather than a whole-parent view that behaves like a plain `String`.
_sub(s::String) = SubString("\0" * s, 2)
_lazy(s::String) = LazyString(s)

@testset "SECTION: Value formatters accept any AbstractString (#598)" begin

  # ─────────────────────────────────────────────────────────────────────────────
  # Base facts the fix rests on: what each probe actually is, and why `string` is not `String`
  # These are assertions about Base, not about PormG. They are here because the whole fix turns
  # on them, and because a future Base change that made `string(::LazyString)` return a `String`
  # would silently turn every `LazyString` assertion below into a `String` assertion — i.e. this
  # file would keep passing while testing nothing. Pinned so that change surfaces as a failure
  # here, naming itself, rather than as a mystery months later.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "The probes are what this file claims they are (Base)" begin
    # Defect 2 needs a string type the regex engine refuses. `SubString{String}` is accepted by
    # it; `LazyString` is not — that asymmetry is the entire reason for two probes.
    @test _sub("1:27.452") isa SubString{String}
    @test _sub("1:27.452") == "1:27.452"
    @test _lazy("1:27.452") isa LazyString
    @test _lazy("1:27.452") == "1:27.452"
    @test match(r"^\d", _sub("1:27.452")) !== nothing
    @test_throws ArgumentError match(r"^\d", _lazy("1:27.452"))

    # `string` is the identity for LazyString; `String` is not. This is the measurement that
    # sends the fix to `String(...)` — mirror it and the fix regresses without any signature
    # changing. Mutation gate: `strip(string(l))` is a SubString{LazyString}, which still throws.
    @test string(_lazy("x")) isa LazyString
    @test String(_lazy("x")) isa String
    @test strip(string(_lazy(" x "))) isa SubString{LazyString}
    @test strip(String(_lazy(" x "))) isa SubString{String}

    # ...and why `occursin` masked it in `format_uuid_sql` while `match` did not.
    @test occursin(r"^x$", _lazy("x"))
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # DurationField: `format_duration_sql` normalises any AbstractString spelling identically
  # The headline repro from #598 — `results.csv`'s `fastestlaptime` is a DurationField, and a
  # CSV reader that returns its own string type made `bulk_insert` die on row 1. Covers all
  # three accepted shapes (HH:MM:SS, M:SS, bare seconds), because the bare-seconds branch takes
  # a DIFFERENT path: `occursin` clears its guard and the throw happens one frame down inside
  # `_duration_from_seconds_string`, which is a separate conversion site.
  # Mutation gate: reverting either `String(value)` in the two duration helpers fails the
  # LazyString rows with `ArgumentError`.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "format_duration_sql (DurationField)" begin
    for (text, expected) in (
      ("1:27.452", "00:01:27.452"),   # M:SS.sss  — the issue's literal value
      ("01:27:30", "01:27:30"),       # HH:MM:SS
      ("1:27:30.5", "1:27:30.5"),     # HH:MM:SS.s
      ("90", "00:00:90"),             # bare seconds → `_duration_from_seconds_string`
      ("12.25", "00:00:12.25"),       # bare seconds with a fraction
    )
      # Equality with the `String` spelling, not merely "does not throw": for a defect whose
      # symptom is a wrong ERROR, a no-throw assertion would pass against the unpatched code.
      @test Mo.format_duration_sql(text) == expected
      @test Mo.format_duration_sql(_sub(text)) == expected
      @test Mo.format_duration_sql(_lazy(text)) == expected
    end

    # Widening a signature must not widen what is ACCEPTED. An invalid value raises the same
    # taxonomy type in every spelling — otherwise the fix silently changes an error contract.
    for probe in (identity, _sub, _lazy)
      @test_throws PormG.InvalidValueError Mo.format_duration_sql(probe("not a duration"))
      @test_throws PormG.InvalidValueError Mo.format_duration_sql(probe(""))
      @test_throws PormG.InvalidValueError Mo.format_duration_sql(probe("   "))
    end

    # Non-string arms are untouched by the widening.
    @test Mo.format_duration_sql(Dates.Minute(1) + Dates.Second(27)) == "00:01:27"
    @test Mo.format_duration_sql(missing) === missing
    @test Mo.format_duration_sql(nothing) === missing
    @test_throws PormG.InvalidValueError Mo.format_duration_sql(1.5)
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # DateTimeField: `format_timezone_sql` dispatches on AbstractString, and so does its callee
  # The half of #598 that was live on `main`: the method was typed `::String` and there was no
  # generic arm at all, so `format_timezone_sql(::SubString)` was a bare MethodError. Widening
  # the entry point alone is not enough — `validate_timezone` carries the real work and was
  # typed `::String` too, which just moves the MethodError one frame down. Both are asserted.
  # Mutation gate: re-narrowing either signature fails the corresponding row with a MethodError;
  # reverting `validate_timezone`'s `String(value)` fails only the LazyString rows.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "format_timezone_sql / validate_timezone (DateTimeField)" begin
    # Canonical UTC ISO-8601 (issue #79) is spelling-independent; that must stay true across
    # string TYPES as well, which is what makes SQLite's TEXT ordering agree with PostgreSQL.
    for (text, expected) in (
      ("2021-03-26T06:00:00",        "2021-03-26T06:00:00.000+00:00"),  # naive → UTC
      ("2021-03-26 06:00:00",        "2021-03-26T06:00:00.000+00:00"),  # space separator
      ("2021-03-26T06:00:00Z",       "2021-03-26T06:00:00.000+00:00"),  # Z offset
      ("2021-03-26T03:00:00-03:00",  "2021-03-26T06:00:00.000+00:00"),  # real offset → UTC
      ("2021-03-26T06:00:00.123456", "2021-03-26T06:00:00.123+00:00"),  # sub-ms truncation
    )
      @test Mo.format_timezone_sql(text) == expected
      @test Mo.format_timezone_sql(_sub(text)) == expected
      @test Mo.format_timezone_sql(_lazy(text)) == expected
      # The callee directly: `format_timezone_sql` is a one-line delegation, so an assertion
      # only on the caller cannot show which of the two signatures was actually fixed.
      @test Mo.validate_timezone(_sub(text), Mo.DATETIME_FORMAT) == expected
      @test Mo.validate_timezone(_lazy(text), Mo.DATETIME_FORMAT) == expected
    end

    # Rejections keep their type in every spelling, including the out-of-range-offset branch,
    # which is the one that reaches `match` rather than `occursin`.
    for probe in (identity, _sub, _lazy)
      @test_throws PormG.InvalidValueError Mo.format_timezone_sql(probe("not a datetime"))
      @test_throws PormG.InvalidValueError Mo.format_timezone_sql(probe("2021-03-26T06:00:00+25:00"))
      @test_throws PormG.InvalidValueError Mo.format_timezone_sql(probe("2021-03-26T06:00:00+00:60"))
    end

    # The generic arm this formatter was missing (#598): every sibling had one, so an unhandled
    # value here used to escape the #231 taxonomy as a bare MethodError.
    # Mutation gate: delete `format_timezone_sql(value)` and these three become MethodErrors.
    @test_throws PormG.InvalidValueError Mo.format_timezone_sql(42)
    @test_throws PormG.InvalidValueError Mo.format_timezone_sql(1.5)
    @test_throws PormG.InvalidValueError Mo.format_timezone_sql(:symbol)
    @test PormG.InvalidValueError <: PormG.PormGError   # it really is in the taxonomy
    # The keyword form lands on the arm too. Nothing in `src/`, `test/` or `docs/` passes
    # `format=` today, which is exactly why an arm without the keyword would look complete and
    # leave a `MethodError` hole behind it.
    # Mutation gate: drop `; format::AbstractString=DATETIME_FORMAT` from the generic arm and this
    # row becomes a MethodError.
    @test_throws PormG.InvalidValueError Mo.format_timezone_sql(42; format = "yyyy-mm-dd")
    # ...and the keyword still reaches the string arm, which is the one that uses it.
    @test Mo.format_timezone_sql("2021-03-26T06:00:00"; format = "custom") == "2021-03-26T06:00:00.000+00:00"

    # Typed arms are untouched.
    @test Mo.format_timezone_sql(missing) === missing
    @test Mo.format_timezone_sql(nothing) === missing
    @test Mo.format_timezone_sql(Dates.DateTime(2021, 3, 26, 6)) == "2021-03-26T06:00:00.000+00:00"
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # `format_yyyy_mm`: the `__@yyyy_mm` filter-value normaliser
  # Not named in #598's checklist — found by sweeping the class, and the failure mode is the
  # nastiest of the three: a `SubString` fell to the generic arm and was rejected as "not a
  # String or Integer", so the user was told their value had the wrong TYPE when it was a
  # perfectly good `"YYYY-MM"` string out of `split`.
  # Mutation gate: re-narrowing to `::String` makes every `_sub`/`_lazy` row throw.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "format_yyyy_mm (__@yyyy_mm filter values)" begin
    for probe in (identity, _sub, _lazy)
      @test Mo.format_yyyy_mm(probe("1991-10")) == "1991-10"
      # The return is a `String` whatever came in, so the caller's string type cannot leak into
      # the range math in `querybuilder/build_helpers.jl`.
      @test Mo.format_yyyy_mm(probe("1991-10")) isa String
      # These three are rejected BOTH before and after the fix — the old generic arm raised the
      # same `InvalidValueError` type — so asserting the type alone is theater. What changed is the
      # REASON: a `SubString` used to be told it was "a String or Integer" problem, i.e. that its
      # TYPE was wrong, when the type was fine and only the shape was not.
      #
      # The discriminator is that the shape arm INTERPOLATES THE VALUE ("The value 1991 is
      # invalid…") and the type arm cannot, because it never looked at one. Naive substring checks
      # do not work here and were tried first: both messages contain the literal "format YYYY-MM",
      # since the generic one reads "…in the format YYYY-MM or YYYYMM".
      for bad in ("1991", "199110", " 1991-10 ")   # the last: the fix widened the accepted TYPE,
                                                   # never the accepted SHAPE
        err = try
          Mo.format_yyyy_mm(probe(bad))
          nothing
        catch e
          e
        end
        @test err isa PormG.InvalidValueError
        msg = sprint(showerror, err)
        # Mutation gate: re-narrow to `::String` and these two rows fail — the generic arm's
        # message names neither the value nor a bare "YYYY-MM" without "YYYYMM" beside it.
        @test occursin("The value $(bad) is invalid", msg)
        @test !occursin("YYYYMM", msg)
      end
    end

    # The Integer arm and the generic arm are untouched.
    @test Mo.format_yyyy_mm(199110) == "1991-10"
    @test_throws PormG.InvalidValueError Mo.format_yyyy_mm(2025)
    @test_throws PormG.InvalidValueError Mo.format_yyyy_mm(2025.0)
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # `normalize_sqlite_datetime_string` fails open, as its own docstring promises
  # The only member of this set whose bug was a CONTRACT violation rather than a rejection: it
  # documents "returns the string unchanged when it does not match any expected pattern" and
  # `-> String`, and it did neither on a non-`String`. It is on the write path
  # (`validate_timezone`) AND the SQLite read path (`Dialect._parse_sqlite_timestamp`, itself
  # documented as never throwing), which is why the return type matters and not just the throw:
  # the read path feeds this result to a further regex.
  # Mutation gate: reverting `String(value)` makes both LazyString rows throw ArgumentError.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "normalize_sqlite_datetime_string fail-open contract" begin
    for probe in (identity, _sub, _lazy)
      # Pads to exactly 3 sub-second digits...
      @test Mo.normalize_sqlite_datetime_string(probe("2021-03-26T06:00:00.1Z")) == "2021-03-26T06:00:00.100Z"
      # ...truncates beyond 3...
      @test Mo.normalize_sqlite_datetime_string(probe("2021-03-26T06:00:00.123456Z")) == "2021-03-26T06:00:00.123Z"
      # ...injects when absent...
      @test Mo.normalize_sqlite_datetime_string(probe("2021-03-26T06:00:00-03:00")) == "2021-03-26T06:00:00.000-03:00"
      # ...and fails OPEN on anything else, rather than throwing.
      @test Mo.normalize_sqlite_datetime_string(probe("not a timestamp")) == "not a timestamp"
      # The documented `-> String`, on every arm including the fail-open one — this is what
      # keeps `Dialect._parse_sqlite_timestamp`'s own `match` safe on the read path.
      @test Mo.normalize_sqlite_datetime_string(probe("2021-03-26T06:00:00.1Z")) isa String
      @test Mo.normalize_sqlite_datetime_string(probe("not a timestamp")) isa String
    end
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # The rest of the family, locked as a contract rather than left to chance
  # These four were measured OK and needed no dispatch change — but "OK today" is exactly the
  # status the two broken ones had until someone passed the wrong string type, and two of them
  # survive only through `occursin`'s generic fallback. Asserting them here means the contract
  # is "the whole family takes any AbstractString", enforced, rather than a property four
  # formatters happen to have.
  # `format_date_sql` additionally returns a `String` now (#598): it always accepted any
  # AbstractString but returned the ARGUMENT, so the caller's type reached the parameter binder.
  # Mutation gate: reverting `return String(value)` to `return value` fails the `isa String` row.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "Siblings already on the right side of the contract" begin
    for probe in (identity, _sub, _lazy)
      @test Mo.format_uuid_sql(probe("550E8400-E29B-41D4-A716-446655440000")) == "550e8400-e29b-41d4-a716-446655440000"
      @test_throws PormG.InvalidValueError Mo.format_uuid_sql(probe("not-a-uuid"))

      @test Mo.format_number_sql(probe("42")) == "42"
      @test Mo.format_number_sql(probe("12.5")) == "12.5"
      # The `string` → `String` normalisation, asserted through the only place it is observable:
      # this method returns its `strip` result, so a missed conversion surfaces as the WRAPPED
      # type. Mutation gate: revert `value |> String |> strip` to `value |> string |> strip` and
      # the `_lazy` row is a `SubString{LazyString}`. (Content equality above passes either way,
      # which is exactly why this row exists.)
      @test Mo.format_number_sql(probe("42")) isa SubString{String}
      @test_throws PormG.InvalidValueError Mo.format_number_sql(probe("12,5"))
      @test_throws PormG.InvalidValueError Mo.format_number_sql(probe("abc"))

      @test Mo.format_date_sql(probe("2021-03-26")) == "2021-03-26"
      @test Mo.format_date_sql(probe("2021-03-26")) isa String
      @test_throws PormG.InvalidValueError Mo.format_date_sql(probe("2023-02-29"))
      @test_throws PormG.InvalidValueError Mo.format_date_sql(probe("26/03/2021"))

      @test Mo.format_text_sql(probe("Senna")) == "Senna"
    end
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # End to end: the QUERY path, not just the formatter in isolation
  # Everything above calls the formatters directly, which cannot show that a `SubString` survives
  # the trip from a user's `filter(...)` down to a bound parameter — and the read path is where
  # the new generic `format_timezone_sql` arm actually earns its keep. `querybuilder/sanitization.jl`
  # guards the WRITE path with `value isa AbstractString` before it ever calls a formatter, so a
  # non-string never reached one on an insert; `_format_filter_value` has no such guard and hands
  # the raw value straight over, with `_rethrow_as_filter_error` converting `InvalidValueError`
  # into `FilterError` and rethrowing anything else untouched.
  #
  # A mock Postgres connection under its OWN key — never `config["default"]`, which several other
  # unit files write to and which `runtests.jl` shares one process across.
  # Mutation gate: delete the generic arm and the `Date` row below raises `MethodError` instead of
  # `FilterError`; re-narrow `format_timezone_sql` to `::String` and the SubString/LazyString rows
  # raise `MethodError` instead of building SQL.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "The query path carries a non-String AbstractString to a bound parameter" begin
    struct _MockPgFormatter598 <: PormG.PormGPostgres end
    PormG.config["fmt_abstractstring_598"] = PormG.Configuration.Settings(
      connections = _MockPgFormatter598(),
      change_data = true,
    )
    laps = PormG.Models.Model("laps",
      id        = PormG.Models.IDField(),
      recorded  = PormG.Models.DateField(),
      logged_at = PormG.Models.DateTimeField(),
    )
    laps.connect_key = "fmt_abstractstring_598"

    # The issue's own motivating shape: a field value straight out of `split`.
    line = "1991-10-27T14:30:00,Senna"
    parts = split(line, ",")
    @test parts[1] isa SubString{String}

    baseline = laps.objects.filter("logged_at" => "1991-10-27T14:30:00").list(show_query = :dict)
    from_split = laps.objects.filter("logged_at" => parts[1]).list(show_query = :dict)
    lazy = laps.objects.filter("logged_at" => LazyString("1991-10-27T14:30:00")).list(show_query = :dict)

    # Identical SQL *and* identical bound parameters — the canonical UTC form must not depend on
    # which string type the caller happened to hold.
    @test from_split[:sql_text] == baseline[:sql_text]
    @test lazy[:sql_text] == baseline[:sql_text]
    @test from_split[:parameters] == baseline[:parameters]
    @test lazy[:parameters] == baseline[:parameters]
    @test baseline[:parameters] == ["1991-10-27T14:30:00.000+00:00"]

    # The `__@yyyy_mm` bucket, whose normaliser is the sibling #598 did not name.
    ym_baseline = laps.objects.filter("recorded__@yyyy_mm" => "1991-10").list(show_query = :dict)
    ym_split = laps.objects.filter("recorded__@yyyy_mm" => SubString("x1991-10", 2)).list(show_query = :dict)
    @test ym_split[:parameters] == ym_baseline[:parameters] == ["1991-10-01", "1991-11-01"]

    # The generic arm's real payoff: a value the DateTimeField cannot bind is now reported inside
    # the #231 taxonomy. `_rethrow_as_filter_error` converts `InvalidValueError` to `FilterError`
    # and rethrows everything else untouched, so before the arm existed the formatter's bare
    # `MethodError` escaped the filter path verbatim.
    #
    # `42` and not a `Date`: the filter path resolves `Date` against a DateTimeField ITSELF, before
    # any formatter runs (it binds "2020-01-01T00:00:00.000+00:00" quite happily), so a `Date` never
    # reaches the arm and would make this row assert nothing. Measured, having first written it the
    # other way.
    @test_throws PormG.FilterError laps.objects.filter("logged_at" => 42).list(show_query = :dict)
    @test_throws PormG.FilterError laps.objects.filter("logged_at" => 1.5).list(show_query = :dict)

    delete!(PormG.config, "fmt_abstractstring_598")
  end
end
