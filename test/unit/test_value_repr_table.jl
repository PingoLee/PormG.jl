"""
The value-representation table (#564).

`src/value_repr.jl` is the owner #564 asked for: one table keyed by `(CanonicalType, backend)` with
three slots — the Julia formatter, the SQL canonicalizer, and the read parser. Before it, those three
lived in three files (`Models.format_*_sql`, `Dialect.SQLITE_CANONICAL_DATETIME_MASK`, the query
builder's `_parse_sqlite_datetime`) and nothing made them agree. On PostgreSQL a disagreement fails at
execution because the types are real; on SQLite everything temporal is TEXT with NUMERIC affinity, so
it becomes a wrong answer instead of an error — which is the whole #527 family.

**The assertion this file exists for is `value_formatter(field_canonical_kind(f), backend) === f.formatter`.**
That is #564's acceptance item — *"a single declaration per field type that both the Julia formatter
and the SQL renderer derive from"* — stated as an identity rather than described in prose. If someone
gives a field a new formatter and forgets the table, or adds a table row that disagrees with the
field, this is the test that fails.

Its sibling `test/unit/test_value_repr_property.jl` asserts the PROPERTY end to end against a live
engine; this file asserts the TABLE's own shape, hermetically. Neither replaces the other: the
property test would still pass if the table were bypassed entirely, and this one would still pass if
the renderers never consulted it.

The census (`length(concrete) == 25`) deliberately lives in `test_value_repr_property.jl` only —
two copies of one census is the allowlist mistake, where the second copy is updated and the first
quietly stops meaning anything.

No database.

julia --project=test/integration test/unit/test_value_repr_table.jl
"""

using Test
using PormG
using PormG.Models
using Dates
import TimeZones
import InteractiveUtils: subtypes

# Mock backends: the table dispatches on the abstract `PormGPostgres` / `PormGSQLite`, so a bare
# subtype is enough and no driver is loaded. Named for this file, since `runtests.jl` includes every
# unit file into one `Main`.
struct VrtMockSQLite <: PormG.PormGSQLite end
struct VrtMockPostgres <: PormG.PormGPostgres end
const _VRT_SL = VrtMockSQLite()
const _VRT_PG = VrtMockPostgres()

# The four temporal kinds the table owns, paired with a probe value and the field struct that
# declares them. Written out rather than derived, so a row that disappears is visible in the diff.
const _VRT_KINDS = [
  (PormG.CDateTime(true),  Models.DateTimeField(),                   TimeZones.ZonedDateTime(2031, 7, 4, 12, 30, 45, 123, TimeZones.tz"UTC")),
  (PormG.CDateTime(false), Models.DateTimeField(type = "TIMESTAMP"), TimeZones.ZonedDateTime(2031, 7, 4, 12, 30, 45, 123, TimeZones.tz"UTC")),
  (PormG.CDate(),          Models.DateField(),                       Date(2031, 7, 4)),
  (PormG.CTime(),          Models.TimeField(),                       Time(12, 30, 45, 123)),
  (PormG.CInterval(),      Models.DurationField(),                   Minute(1) + Second(49) + Millisecond(88)),
]

@testset "Value representation table (#564)" begin

  # ───────────────────────────────────────────────────────────────────────────
  # The adapter: a field's own `.type` tag resolves to exactly one canonical noun, and a
  # non-temporal field resolves to none. `CDateTime`'s timezone flag must SURVIVE — collapsing the
  # two flavours is an engine fact that belongs in `parse_canonical_type`, not here, and a table
  # method written for one flavour would let the other fall through to a generic arm.
  # ───────────────────────────────────────────────────────────────────────────
  @testset "field_canonical_kind maps the declared type, and keeps the tz flag" begin
    for (kind, field, _) in _VRT_KINDS
      @test PormG.field_canonical_kind(field) == kind
    end
    # The two DateTimeField flavours are DISTINCT keys, not one.
    @test PormG.field_canonical_kind(Models.DateTimeField()) !=
          PormG.field_canonical_kind(Models.DateTimeField(type = "TIMESTAMP"))
    # Non-temporal fields are not this table's business.
    for f in (Models.CharField(), Models.IntegerField(), Models.FloatField(),
              Models.BooleanField(), Models.UUIDField(), Models.TextField())
      @test PormG.field_canonical_kind(f) === nothing
    end
  end

  # ───────────────────────────────────────────────────────────────────────────
  # THE HEADLINE. Slot 1 is not a second copy of the formatter — it IS the field's own formatter,
  # reached by canonical kind instead of by re-deriving the choice from a `.type` string (which is
  # what the `if ftype == "DATE" … elseif ftype == "TIMESTAMP" …` ladder in `_format_date_operand`
  # used to do). Identity comparison, not equality: it must be the same function object.
  # ───────────────────────────────────────────────────────────────────────────
  @testset "value_formatter IS the field's own formatter, for every temporal field" begin
    for (kind, field, _) in _VRT_KINDS, backend in (_VRT_SL, _VRT_PG)
      @test PormG.value_formatter(kind, backend) === field.formatter
    end
    # A kind the table does not own has no formatter — the honest answer, and the same one the
    # codebase gave before this file existed.
    @test PormG.value_formatter(PormG.CText(), _VRT_SL) === nothing
    @test PormG.value_formatter(PormG.CInt64(), _VRT_PG) === nothing
  end

  # ───────────────────────────────────────────────────────────────────────────
  # Slot 2. On SQLite the wrapper is the only thing making an expression comparable to what the
  # column holds; on PostgreSQL the column has a real type, so its value already IS its canonical
  # form and there is nothing to wrap. That asymmetry is the subject of #564, so it is asserted here
  # rather than left as an `if` at a call site.
  # ───────────────────────────────────────────────────────────────────────────
  @testset "sql_canonicalize renders the stored form per backend" begin
    # A timestamp wraps in the canonical mask — the exact text `Dialect` owns, so the two cannot
    # drift into two spellings of one idea.
    for kind in (PormG.CDateTime(true), PormG.CDateTime(false))
      sql = PormG.sql_canonicalize(kind, _VRT_SL, "\"Tb\".\"ts\"", ["'+' || ? || ' days'"])
      @test occursin(PormG.Dialect.SQLITE_CANONICAL_DATETIME_MASK, sql)
      @test occursin("\"Tb\".\"ts\"", sql)
      @test occursin("'+' || ? || ' days'", sql)
      # With no modifiers it still canonicalizes — that is what makes a bare projection comparable.
      @test occursin(PormG.Dialect.SQLITE_CANONICAL_DATETIME_MASK,
                     PormG.sql_canonicalize(kind, _VRT_SL, "\"Tb\".\"ts\""))
    end

    # A DATE column wraps in `date(...)`, whose output already equals `format_date_sql`'s — the claim
    # #527 made in a comment and left unasserted.
    @test PormG.sql_canonicalize(PormG.CDate(), _VRT_SL, "\"Tb\".\"d\"", ["'+' || ? || ' days'"]) ==
          "date(\"Tb\".\"d\", '+' || ? || ' days')"
    # …and with nothing to apply it is the identity, so a no-op interval never truncates a column.
    @test PormG.sql_canonicalize(PormG.CDate(), _VRT_SL, "\"Tb\".\"d\"") == "\"Tb\".\"d\""

    # PostgreSQL: identity for every kind.
    for (kind, _, _) in _VRT_KINDS
      @test PormG.sql_canonicalize(kind, _VRT_PG, "\"Tb\".\"c\"") == "\"Tb\".\"c\""
    end
    # SQLite-style modifiers on PostgreSQL are a caller bug, not a rendering choice: PostgreSQL
    # composes durations with `make_interval`. Fail loudly rather than emit something plausible.
    @test_throws PormG.QueryBuildError PormG.sql_canonicalize(
      PormG.CDateTime(true), _VRT_PG, "\"Tb\".\"ts\"", ["'+' || ? || ' days'"])

    # An unowned kind is left alone rather than mangled.
    @test PormG.sql_canonicalize(PormG.CText(), _VRT_SL, "\"Tb\".\"s\"") == "\"Tb\".\"s\""
  end

  # ───────────────────────────────────────────────────────────────────────────
  # Slot 3, as far as it is populated in this commit: the timestamp parser on SQLite, and `nothing`
  # everywhere PostgreSQL is concerned because LibPQ delivers typed values already. The remaining
  # three SQLite parsers arrive with the read-path commit.
  # ───────────────────────────────────────────────────────────────────────────
  @testset "value_parser answers per backend, and never lossily" begin
    # PostgreSQL delivers typed values — asking for a parser there must yield none, for EVERY kind,
    # or the read path would re-parse a value the driver already typed.
    for (kind, _, _) in _VRT_KINDS
      @test PormG.value_parser(kind, _VRT_PG) === nothing
    end

    parse_ts = PormG.value_parser(PormG.CDateTime(true), _VRT_SL)
    @test parse_ts !== nothing
    # Both flavours resolve to the same parser: the stored text is identical, only the DDL differs.
    @test PormG.value_parser(PormG.CDateTime(false), _VRT_SL) === parse_ts

    # The inverse property, which is the point of pairing the slots: what slot 1 wrote, slot 3 reads.
    instant = TimeZones.ZonedDateTime(2031, 7, 4, 12, 30, 45, 123, TimeZones.tz"UTC")
    text = PormG.value_formatter(PormG.CDateTime(true), _VRT_SL)(instant)
    @test parse_ts(text) == instant

    # Fail-open, which is what makes a wrong caller harmless rather than lossy. A non-String is
    # handed straight back — including the integer `CAST(col AS DATE)` yields on SQLite (#562) — and
    # so is text in no shape this parser wrote.
    @test parse_ts(2031) === 2031
    @test parse_ts(missing) === missing
    @test parse_ts("not a timestamp") == "not a timestamp"
  end

  # ───────────────────────────────────────────────────────────────────────────
  # The sniff cannot come back (#564). `_render_date_period_arithmetic` used to decide the SQLite
  # wrapper partly by reading its own RENDERED TEXT:
  #
  #     use_datetime = <resolver> === :timestamp || occursin(SQLITE_CANONICAL_DATETIME_MASK, left_side)
  #
  # C0 measured that clause firing where the resolver had not: 0 times in 519 renders across four
  # corpora. It is deleted, and the kind now travels with the render instead. This scan is what stops
  # a future change from reintroducing a text sniff instead of asking the table — the mechanical form
  # of the same guard `test_memo_interface.jl` applies to inline memo keys.
  #
  # `Dialect` is the only module allowed to NAME the mask: it owns the constant and the one function
  # that emits it. Comment lines are excluded, so the deletion note left behind at the old site (and
  # this block) do not trip it — the rule is about emitted code, not about discussing it.
  #
  # KNOWN LIMIT, stated rather than papered over: this bans the constant's NAME, so someone who
  # re-spelled the mask as a literal (`"strftime('%Y-%m-%dT%H:%M:%f+00:00'"`) would slip past it. That
  # is a mechanical guard against the sniff being *reinstated*, not a proof that no text sniff can
  # exist. The reason it is enough: the sniff it replaced read the constant by name, and anyone
  # reaching for a literal copy of a mask that already has a named owner has a larger problem than
  # this test can catch.
  # ───────────────────────────────────────────────────────────────────────────
  @testset "no file under src/querybuilder/ names the canonical mask" begin
    qb = joinpath(dirname(@__DIR__), "..", "src", "querybuilder")
    offenders = String[]
    for file in filter(f -> endswith(f, ".jl"), readdir(qb; join = true))
      for (n, line) in enumerate(eachline(file))
        startswith(strip(line), "#") && continue
        occursin("SQLITE_CANONICAL_DATETIME_MASK", line) &&
          push!(offenders, "$(basename(file)):$(n): $(strip(line))")
      end
    end
    @test isempty(offenders) || (@error "A text sniff of the canonical mask came back" offenders; false)
  end

  # ───────────────────────────────────────────────────────────────────────────
  # Totality. Every temporal field struct must reach a populated cell — a new one fails here until
  # it is taught to the table, which is the same forcing function `test_column_spec.jl` applies to
  # the column IR. The subtype walk is what makes this fire on a struct nobody added to `_VRT_KINDS`.
  # ───────────────────────────────────────────────────────────────────────────
  @testset "every temporal field struct reaches a populated cell" begin
    concrete = filter(T -> isconcretetype(T) && parentmodule(T) === PormG.Models,
                      subtypes(PormG.PormGField))
    instance(T) =
      T === Models.sForeignKey      ? Models.ForeignKey("Races") :
      T === Models.sOneToOneField   ? Models.OneToOneField("Races") :
      T === Models.sManyToManyField ? Models.ManyToManyField("Races") :
      T === Models.sDecimalField    ? Models.DecimalField(max_digits = 8, decimal_places = 3) :
      getfield(Models, Symbol(String(nameof(T))[2:end]))()

    seen = Set{PormG.CanonicalType}()
    for T in concrete
      kind = PormG.field_canonical_kind(instance(T))
      kind === nothing && continue
      push!(seen, kind)
      # Slot 1 and slot 2 must both answer for a kind a real field declares. Slot 3 is deliberately
      # NOT required here: PostgreSQL legitimately has no parser, and the SQLite half is filled in
      # a later commit — requiring it now would pin a hole as if it were a contract.
      @test PormG.value_formatter(kind, _VRT_SL) !== nothing
      @test PormG.value_formatter(kind, _VRT_PG) !== nothing
      @test PormG.sql_canonicalize(kind, _VRT_SL, "\"c\"") isa String
      @test PormG.sql_canonicalize(kind, _VRT_PG, "\"c\"") isa String
    end
    # Guard the guard: the walk must actually have reached every kind a DEFAULT-constructed field
    # declares, or it silently stopped finding fields and every assertion above became vacuous.
    #
    # `CDateTime(false)` is deliberately absent. The no-tz flavour is a KEYWORD on `sDateTimeField`
    # (`DateTimeField(type = "TIMESTAMP")`), not a struct of its own, so no subtype walk can produce
    # it — which is precisely why it is the flavour a table method forgets. It gets its own
    # assertion below rather than being quietly folded into this set.
    @test seen == Set([PormG.CDateTime(true), PormG.CDate(), PormG.CTime(), PormG.CInterval()])

    # The flavour the walk cannot see. A method written for `CDateTime(true)` alone would let this
    # one fall through to a generic arm and lose its representation — on the render side that is the
    # #527 truncation, reachable only through `DateTimeField(type = "TIMESTAMP")`.
    notz = PormG.field_canonical_kind(Models.DateTimeField(type = "TIMESTAMP"))
    @test notz == PormG.CDateTime(false)
    @test PormG.value_formatter(notz, _VRT_SL) !== nothing
    @test PormG.value_formatter(notz, _VRT_PG) !== nothing
    @test PormG.value_parser(notz, _VRT_SL) !== nothing
    @test occursin(PormG.Dialect.SQLITE_CANONICAL_DATETIME_MASK,
                   PormG.sql_canonicalize(notz, _VRT_SL, "\"c\""))
  end
end
