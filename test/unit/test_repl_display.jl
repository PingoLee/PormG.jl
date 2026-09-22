"""
Unit coverage for #534 — `Base.show` for the model/query/row types (`src/display.jl`).

Before this, no core PormG type defined `Base.show`, so Julia's `show_default` walked struct slots
with the 2-argument `show` and followed the model graph to exhaustion:
`Model_Type.fields` → `sForeignKey.to` → `Model_Type` → `related_objects` → `ReverseRelation.model_resolved`
→ `Model_Type`. Measured on the 14-model F1 fixture, on ONE line each:

    M.Driver                     1,623,608 chars
    a single PormGRow            1,623,696 chars
    a filtered query handler     1,356,112 chars
    a ReverseRelation            2,310,027 chars
    an sCharField                      146 chars   ← the control: no model reference

The severe case is `list()`: `Vector` display calls the 2-arg `show` per element, so a 100-row
result rendered ~160 MB into the terminal.

**The assertions here are quantitative on purpose.** "Looks nicer" is not a regression test — the
defect is a size, and the only thing that catches its return is a size ceiling. A future field
struct or query slot that gains a model reference must fail THIS file, loudly, rather than merely
make the REPL worse.

The ceilings are per case and tight; see the note above `CEILINGS`. They are calibrated against
*this* file's two-model fixture, where a reverted fix renders single-digit KB — not against the MB
figures above, which come from the much larger F1 schema. Getting that wrong once already produced a
ceiling a fully reverted fix sailed under.

Size is not the only unbounded axis. The first version of `src/display.jl` bounded the characters
printed while leaving the WORK proportional to the data — 11 seconds to render 1,359 characters for
a `list()` of 20 rows holding 1 MB blobs each. The `"a display is bounded in work, not just in
output"` testset pins that.

Two contracts beyond size, both load-bearing and both easy to break one method at a time:

  - **A display never opens a connection.** The fixture's connection is an INERT mock declaring no
    `backend_*` methods, so `show_query` on the very query being displayed raises — asserted here.
    A `show` that reached `get_settings` would raise with it.
  - **A display never throws.** A `show` that raises poisons the REPL for every value printed after
    it, including the exception the user was trying to read.

Hermetic — no live database and no fixture data; the only connection is the inert mock above.
"""

using Test
using PormG
using PormG.Models
import PormG.QueryBuilder
using PormG.QueryBuilder: SQLField, SQLOrder

# ── Fixture ──────────────────────────────────────────────────────────────────
#
# A config entry is required — `set_models` calls `Configuration.load(key)` — so the key is
# registered here the way `test_cte_reference.jl` does, under its own name so this file cannot
# contaminate (or be contaminated by) another unit file sharing `Main` in `runtests.jl`.
#
# The mock connection is deliberately INERT: unlike the sibling files' mocks it declares none of the
# `backend_*` methods, so anything that actually tries to render SQL against it raises. That is what
# turns "a display must not touch the database" from a code-reading claim into a test — the
# "no display method reaches the connection pool" testset below asserts `show_query` raises on this
# exact query while `show` renders it fine.
struct ReplShowInertConn <: PormG.PormGSQLite end

PormG.config["repl_show_no_connection"] = PormG.Configuration.Settings(
  connections = ReplShowInertConn(),
  change_data = true,
  db_def_folder = "repl_show_no_connection",
)

# The model shape is the minimum that reproduces the cycle: a parent, a child with a ForeignKey to
# it (installing a `ReverseRelation` back on the parent), and a self-referencing FK on the child so
# the graph is genuinely cyclic rather than merely deep.
module ReplShowModels
import PormG
import PormG.Models

Rs_team = Models.Model("rs_team",
  id      = Models.IDField(),
  name    = Models.CharField(max_length = 80),
  country = Models.CharField(max_length = 3, null = true),
)

Rs_driver = Models.Model("rs_driver",
  id       = Models.IDField(),
  surname  = Models.CharField(max_length = 50, db_column = "family_name"),
  points   = Models.DecimalField(max_digits = 8, decimal_places = 2, null = true),
  active   = Models.BooleanField(default = true),
  team     = Models.ForeignKey(Rs_team, on_delete = "RESTRICT", related_name = "rs_drivers"),
  mentor   = Models.ForeignKey("Rs_driver", on_delete = "SET_NULL", null = true, related_name = "rs_mentees"),
)

# A ManyToManyField, so the card's handling of a field that owns no column is under test, and so the
# `ManyToManyRelation` / `ManyToManyDescriptor` displays have a real specimen to render.
Rs_tagged = Models.Model("rs_tagged",
  id   = Models.IDField(),
  name = Models.CharField(max_length = 40),
  tags = Models.ManyToManyField("Rs_team", related_name = "rs_tagged_teams"),
)

PormG.Models.set_models(@__MODULE__, "repl_show_no_connection")
end

const RS = ReplShowModels

# `repr(MIME"text/plain"(), x)` is exactly what the REPL calls to display a value, and `sprint(show, x)`
# is what `show_default` calls for a NESTED slot. Both routes are asserted for every type — fixing
# only the first leaves the 1.6 MB dump one container away.
_plain(x) = repr(MIME"text/plain"(), x)
_inner(x) = sprint(show, x)

# The ceilings are PER CASE **and per rendering route**, tight — roughly 2-3x each real size.
#
# Two mistakes were made here before this shape, and both are the same mistake: a ceiling a reverted
# fix passes is not a regression test, it is decoration that reads as coverage.
#
#   1. **One loose ceiling for everything.** The MB figures in this file's header come from the
#      14-model F1 fixture; the two-model fixture HERE renders only 2.2-3.4 KB when fully reverted,
#      so a single 4,000-char ceiling caught exactly one of the ten cases.
#   2. **One ceiling for both routes.** A model's card (`_plain`, ~430 chars) and its compact form
#      (`_inner`, ~28 chars) differ by 15x, so a ceiling loose enough for the card was useless for
#      the compact form — and the compact form is precisely where the 2-arg `show(::IO, ::Model_Type)`
#      lives, the method the whole design rests on. Deleting only that method moved `_inner` from 28
#      to 342 and was caught by no ceiling at all.
#
# `(plain, inner)`. Verified by deleting the `show` methods at runtime (`Base.delete_method`) and
# re-measuring — both a full revert and the single-method partial revert fail these.
const CEILING = 4_000                          # the standard-vector case; its real size is ~190
const CEILINGS = Dict{String,Tuple{Int,Int}}(
  #                          plain  inner        real p/i      full revert   partial revert (2-arg model show)
  "Model_Type (parent)"  => ( 600,    60),     # 214/26         2259/2259     215/342
  "Model_Type (child)"   => ( 900,    60),     # 432/28         2259/2259     433/621
  "ObjectHandler"        => ( 700,   120),     # 189/39         3441/3441
  "SQLObjectQuery"       => ( 120,   120),     # 39/39          3407/3407
  "sForeignKey"          => ( 200,   200),     # 68/68          2260/2260
  "sForeignKey (self)"   => ( 200,   200),     # 81/81          2260/2260
  "sCharField (control)" => ( 120,   120),     # 24/24          145/145   ← the control: it never
                                               #   dumped, so this bounds the RENDERER, not the graph
  "sDecimalField"        => ( 120,   120),     # 37/37          143/143   ← same
  "PormGRow"             => ( 400,   200),     # 84/51          2352/2352
  "Vector{PormGRow}"     => (CEILING, CEILING),# 186/167        7089/7070
)

@testset "REPL display — Base.show for models, queries and rows (#534)" begin

  # ─────────────────────────────────────────────────────────────────────────────
  # Size ceiling: the regression itself.
  # Every model-bearing type, through BOTH display routes. Pre-#534 each of these rendered between
  # 1.35 MB and 2.31 MB; the control (`Rs_team.fields["name"]`, which holds no model reference)
  # rendered 146 chars and is included so a failure here distinguishes "the graph came back" from
  # "the renderer broke".
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "no value serializes the model graph" begin
    q = RS.Rs_driver.objects
    q.filter("team__name" => "Lotus", "points__@gte" => 10)
    q.values("surname", "team" => "team__name")
    q.order_by("-points")

    row = PormG.PormGRow(Dict(:id => 7, :surname => "Senna", :team => "Lotus"), RS.Rs_driver)

    cases = Pair{String,Any}[
      "Model_Type (parent)"      => RS.Rs_team,
      "Model_Type (child)"       => RS.Rs_driver,
      "ObjectHandler"            => q,
      "SQLObjectQuery"           => q.object,
      "sForeignKey"              => RS.Rs_driver.fields["team"],
      "sForeignKey (self)"       => RS.Rs_driver.fields["mentor"],
      "sCharField (control)"     => RS.Rs_team.fields["name"],
      "sDecimalField"            => RS.Rs_driver.fields["points"],
      "PormGRow"                 => row,
      "Vector{PormGRow}"         => [row, row, row],
    ]

    # Per-case `@testset` so a failure NAMES the type that regressed. A bare loop reports
    # `length(plain) < 4000` ten times over with nothing to say which one blew up.
    for (label, value) in cases
      @testset "$label" begin
        cap_plain, cap_inner = CEILINGS[label]
        plain, inner = _plain(value), _inner(value)
        @test length(plain) < cap_plain
        @test length(inner) < cap_inner
      end
    end
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # The cycle: a nested model must render through the compact 2-arg method.
  # This is the mechanism the whole fix rests on — `show_default` reaches a model through the 2-arg
  # `show`, so bounding THAT bounds every container, including ones with no method of their own.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "a nested model renders compactly, not recursively" begin
    # The FK's `to` is a live Model_Type after `set_models` resolved it — this is the exact slot the
    # dump travelled through.
    fk = RS.Rs_driver.fields["team"]
    @test getfield(fk, :to) isa Models.Model_Type
    @test _inner(getfield(fk, :to)) == "Model(\"rs_team\", 3 fields)"

    # And the reverse direction: the parent's `related_objects` hold the child model.
    #
    # An EXACT match, not `occursin("ReverseRelation(", …)` plus a length bound. Both of those pass
    # against the very thing they exist to detect: Julia's default rendering is
    # `PormG.Models.ReverseRelation(:team, :id, …)`, whose qualified type name *ends in* the searched
    # substring, and at 94 characters it sat under a 120 ceiling. An assertion satisfied by the
    # unfixed output is not coverage.
    rel = RS.Rs_team.related_objects["rs_drivers"]
    @test rel isa Models.ReverseRelation
    @test _inner(rel) == "ReverseRelation(rs_driver.team → id)"

    # A container with NO method of its own (`PathJoin` has one; `Dict{String,PormGField}` does not)
    # must still be bounded, purely by inheriting the field method.
    @test length(_inner(RS.Rs_driver.fields)) < CEILING
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # Every `show` this file defines is actually exercised.
  # A method-by-method mutation sweep (delete one `Base.show` from `src/display.jl`, run this file)
  # found 8 of 15 escaping undetected: six of the types were never constructed here at all, and the
  # `ReverseRelation` pair was worse — asserted, but by a substring and a length bound that Julia's
  # DEFAULT rendering also satisfies.
  #
  # They are cosmetic rather than dangerous — the `Model_Type` and `PormGField` compact methods
  # already bound everything these hold, so the megabyte dump cannot return through them — but a file
  # that presents a method as covered when it is not is the thing this repo's review checklist calls
  # green theater. Exact matches, so deleting any one of them fails here.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "every show method is exercised by an exact assertion" begin
    q = RS.Rs_driver.objects
    q.filter("surname" => "Senna")
    q.values("surname")

    # The compact handler form — its own method, distinct from the card below.
    @test _inner(q) == "Query(\"rs_driver\", 1 filter, 1 value)"

    # The join and projection nodes. Built directly: no public chain reaches `AliasJoin` without a
    # live connection, and these are display-only assertions.
    @test _inner(QueryBuilder.SQLField("surname")) == "SQLField(surname)"
    @test _inner(QueryBuilder.SQLOrder(QueryBuilder.SQLField("points"); orientation = "DESC")) ==
          "SQLOrder(points DESC)"
    @test _inner(QueryBuilder.AliasJoin(RS.Rs_team, QueryBuilder.FilterType[], "LEFT")) ==
          "AliasJoin(\"rs_team\", LEFT, 0 ON)"
    @test _inner(QueryBuilder.PathJoin(QueryBuilder.FilterType[], RS.Rs_driver.fields["team"], nothing)) ==
          "PathJoin(ForeignKey)"
    @test _inner(QueryBuilder.PathJoin(QueryBuilder.FilterType[], nothing, "LEFT")) ==
          "PathJoin(on-only, LEFT)"

    # The many-to-many pair. `ManyToManyDescriptor` is what `row.tags` returns.
    m2m_rel = Models.get_many_to_many_relation(RS.Rs_tagged, "tags")
    @test _inner(m2m_rel) == "ManyToManyRelation(\"tags\" via \"$(m2m_rel.through_table)\")"
    @test _inner(QueryBuilder.ManyToManyDescriptor(RS.Rs_tagged, "tags", m2m_rel)) ==
          "ManyToManyDescriptor(\"tags\")"
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # A display never reaches `get_settings`.
  # The config entry is REMOVED for the duration, which makes every route to a connection —
  # `get_settings`, and therefore `show_query`/`inspect_query` and the whole execute path — raise,
  # while leaving the models themselves fully wired (relations resolved at `set_models` time).
  # Display must keep working, which it can only do by never going there.
  #
  # The removal is the whole test. An earlier version asserted `show_query` raised against a mock
  # connection declaring no `backend_*` methods, on the assumption that rendering needed them; it
  # does not, `show_query` returned SQL happily, and the assertion proved nothing. Deleting the
  # config is the version that actually fails when the invariant is broken — verified by checking
  # that `show_query` raises here.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "no display method reaches the connection pool" begin
    # Built while the config still exists — this testset is about DISPLAY, not construction.
    q = RS.Rs_driver.objects
    q.filter("surname" => "Senna")
    q.values("surname")

    saved = PormG.config["repl_show_no_connection"]
    delete!(PormG.config, "repl_show_no_connection")
    try
      # Precondition, and non-vacuous: with the config gone, anything that resolves a connection
      # raises. If this ever stops throwing, every assertion below becomes decoration.
      #
      # The CONCRETE type, not `Exception`: a bare `@test_throws Exception` passes on any failure,
      # including one that has nothing to do with connection resolution, so it could keep passing
      # while the precondition it stands for had quietly stopped holding.
      #
      # `InvalidConfigurationError`, measured — NOT `MissingConfigurationError`. The latter is what a
      # never-configured key raises through `Configuration.load`; a key that is deleted after the
      # models were wired takes the other branch, because the model still carries its `connect_key`
      # and it is the LOOKUP that fails, not the load.
      @test_throws PormG.InvalidConfigurationError PormG.QueryBuilder.show_query(q)

      # The same query, displayed — must not raise.
      @test _plain(q) isa String
      @test _inner(q) isa String
      @test _plain(RS.Rs_driver) isa String
      @test _inner(RS.Rs_driver.fields["team"]) isa String
      @test _plain(PormG.PormGRow(Dict{Symbol,Any}(:id => 1), RS.Rs_driver)) isa String

      # And the card NAMES the escape rather than performing it.
      @test occursin("show_query(q)", _plain(q))
      @test occursin("not executed", _plain(q))
    finally
      # Explicit cleanup: `runtests.jl` shares `Main`, so a config key left deleted would break
      # whatever runs next.
      PormG.config["repl_show_no_connection"] = saved
    end
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # A display never throws — including on half-built and hostile input.
  # These are the shapes a user actually meets: a model built by hand that never went through
  # `set_models` (no `field_names`, no resolved `to`), and values wide enough to blow a line.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "hostile input degrades instead of raising" begin
    # A model that never saw `set_models`: the FK's `to` is still the unresolved String it was
    # declared with. (`field_names` is NOT empty here — `Models.Model(...)` fills it at construction.
    # An earlier version of this testset claimed it was, and asserted it with `... || true`, which is
    # `@test true`. Both are corrected: the claim was false and the assertion could not fail.)
    raw = Models.Model("rs_raw",
      id   = Models.IDField(),
      # A default long enough to blow a terminal line, but legal — `CharField` refuses a default
      # longer than `max_length` at construction, so the oversize value has to fit the declaration.
      note = Models.CharField(max_length = 250, default = "x"^200),
      ref  = Models.ForeignKey("never_resolved", on_delete = "CASCADE", null = true),
    )
    @test getfield(raw, :field_names) == ["id", "note", "ref"]
    @test _plain(raw) isa String
    @test length(_plain(raw)) < 700
    # The unresolved target still names itself on the card rather than vanishing.
    @test occursin("never_resolved", _plain(raw))
    # The 200-char default is truncated on the card, not printed whole.
    @test !occursin("x"^100, _plain(raw))

    # A pathological value must be truncated, not printed whole.
    wide = PormG.PormGRow(Dict(:blob => "y"^50_000), raw)
    @test length(_inner(wide)) < 400
    @test length(_plain(wide)) < 400

    # An empty projection is a real state (`q.values()` never called) and must not divide by zero
    # on the column-width computation.
    empty_row = PormG.PormGRow(Dict{Symbol,Any}(), raw)
    @test _plain(empty_row) isa String

    # A field name wide enough to break `rpad` alignment if truncation counted codepoints instead of
    # display columns. Two-column CJK: 20 characters, 40 columns.
    cjk = Models.Model("rs_cjk", id = Models.IDField())
    cjk.fields["専門分野専門分野専門分野専門分野"] = Models.CharField()
    push!(getfield(cjk, :field_names), "専門分野専門分野専門分野専門分野")
    @test _plain(cjk) isa String
    @test all(l -> textwidth(l) < 200, split(_plain(cjk), '\n'))
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # A display is bounded in WORK, not just in output.
  # The first version of `src/display.jl` truncated the RESULT of `show`, which bounds characters and
  # nothing else: `sprint` still materialized the whole rendering first. Measured then — one row
  # holding a 4 MB BinaryField cell rendered 89 characters in 778 ms, and a `list()` of 20 such rows
  # took 11.0 s to produce 1,359 characters. A REPL that stalls for eleven seconds is the original
  # complaint again, so the bound has to be on the walk, not on the string it returns.
  #
  # The timings are the assertion. They are generous (100x headroom over the fixed version, which
  # renders these in single-digit milliseconds) so this is not a flaky benchmark — it fails only if
  # the work becomes proportional to the DATA again, which is a factor of thousands, not of two.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "a display is bounded in work, not just in output" begin
    blob_model = Models.Model("rs_blob", id = Models.IDField(), blob = Models.BinaryField(null = true))
    cell(v) = PormG.PormGRow(Dict{Symbol,Any}(:id => 1, :blob => v), blob_model)

    # The payload SHAPES matter more than their size, and this list is the finding: an earlier
    # version of this testset used `rand(UInt8, …)` only — the one shape `:limit => true` handles for
    # free — and passed while the string path was still unbounded. `textwidth` is ZERO for newline,
    # tab, NUL and combining marks, so a width-based guard returned those whole; measured at 3.8 s
    # for the 20-row list below, which is over this testset's own budget.
    payloads = [
      "binary"           => rand(UInt8, 1_000_000),
      "plain text"       => "z"^1_000_000,
      "newlines"         => "\n"^1_000_000,       # textwidth 0 — the case that escaped
      "tabs"             => "\t"^1_000_000,       # textwidth 0
      "NULs"             => "\0"^1_000_000,       # textwidth 0
      "combining marks"  => "é"^300_000,    # textwidth 1 per pair, 600k characters
      "wide CJK"         => "日"^500_000,
    ]

    for (label, v) in payloads
      @testset "$label" begin
        row = cell(v)
        _plain(row); _inner(row)                  # warm up compilation before timing
        @test (@elapsed _plain(row)) < 0.25
        @test length(_plain(row)) < 400
        # The rendering must still be a valid string — the byte cap can land mid-character.
        @test isvalid(_plain(row))
        @test isvalid(_inner(row))
      end
    end

    # A `list()` of them: `Vector` display calls the 2-arg `show` once per element, so per-element
    # cost multiplies. This is the 11.0 s case.
    rows = [cell(last(payloads[1 + (i % length(payloads))])) for i in 1:20]
    _plain(rows)
    @test (@elapsed _plain(rows)) < 1.0

    # The same axis through a filter value rather than a row cell.
    q = RS.Rs_driver.objects
    q.filter("id__@in" => collect(1:1_000_000))
    _plain(q)
    @test (@elapsed _plain(q)) < 0.25
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # Content: the query card names the OUTPUT column names, not the field paths.
  # `values("team" => "team__name")` puts the alias in `custom_as` and leaves the PATH in `_as`,
  # while `values("n" => Count("id"))` puts the alias in `_as`. Reading `_as` alone renders
  # `team__name` for a column that comes back as `team` — a card that names columns the result does
  # not have. The precedence is `_reject_duplicate_projection_names`' own (#441).
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "the query card names columns the result will carry" begin
    q = RS.Rs_driver.objects
    q.values("surname", "team" => "team__name")
    card = _plain(q)

    @test occursin("team", card)
    @test !occursin("team__name", card)      # the path must NOT be what the card shows
    @test occursin("surname", card)

    # Filters render with the operator the caller used.
    q2 = RS.Rs_driver.objects
    q2.filter("points__@gte" => 10)
    @test occursin("points", _plain(q2))
    @test occursin(">=", _plain(q2))

    # An EMPTY alias is the one input where a `!isempty` check would diverge from the #441 rule
    # (`custom_as !== nothing ? custom_as : _as`). `values("" => path)` is accepted today, and the
    # card must name the column the rule names — `""` — not fall through to the path.
    q3 = RS.Rs_driver.objects
    q3.values("" => "team__name")
    @test !occursin("team__name", _plain(q3))

    # Structural clauses appear only when set — an untouched query must not claim a limit.
    fresh = RS.Rs_driver.objects
    @test !occursin("limit", _plain(fresh))
    paged = RS.Rs_driver.objects
    paged.limit(20)
    @test occursin("limit 20", _plain(paged))

    # `limit == 0` is PormG's NO-LIMIT sentinel, and `LIMIT 0` in SQL means zero rows. An
    # offset-only query must not claim a limit it does not have.
    offs = RS.Rs_driver.objects
    offs.offset(25)
    @test occursin("offset 25", _plain(offs))
    @test !occursin("limit", _plain(offs))
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # Content: the model card is the `\\d <table>` view — SQL type and schema flags.
  # A card whose every CharField line read `CharField()` would be true and useless; what a reader
  # browsing a model wants is the column as the database holds it.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "the model card shows SQL types and schema flags" begin
    card = _plain(RS.Rs_driver)

    @test occursin("rs_driver", card)
    @test occursin("VARCHAR(50)", card)          # max_length belongs with the type
    @test occursin("DECIMAL(8,2)", card)         # so do precision and scale
    @test occursin("pk", card)                   # the IDField is marked
    @test occursin("→ rs_team", card)            # the relation says where it points
    @test occursin("RESTRICT", card)             # and how it deletes
    @test occursin("family_name", card)          # a db_column rename is visible (#317)
    @test occursin("null", card)                 # nullability is visible
    @test occursin("rs_drivers", _plain(RS.Rs_team))  # reverse accessors are listed on the parent

    # The field's OWN one-liner is the other half: the declaration form, not the schema form.
    @test _inner(RS.Rs_team.fields["name"]) == "CharField(max_length=80)"
    @test occursin("ForeignKey(", _inner(RS.Rs_driver.fields["team"]))
    @test occursin("on_delete=RESTRICT", _inner(RS.Rs_driver.fields["team"]))
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # The card accounts for EVERY field, including the ones `field_names` excludes.
  # `field_names` is documented as "the subset that owns a real column" and `Model(...)` fills it
  # with `!is_many_to_many_field(field) && push!(...)` — so iterating it alone dropped every
  # `ManyToManyField` from the card, silently and with no `⋮ N more` to hint at it, while the compact
  # `show` counted `length(fields)` and reported a number the card could not account for. The forward
  # accessor a user types (`row.tags`) was the invisible half; its reverse twin showed up fine on the
  # other model's `reverse:` line.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "a ManyToManyField appears on the card" begin
    m2m = Models.Model("rs_m2m",
      id      = Models.IDField(),
      surname = Models.CharField(),
      tags    = Models.ManyToManyField("Rs_team", related_name = "rs_tagged"),
    )

    # The precondition this testset exists for: the m2m is in `fields` and NOT in `field_names`.
    @test haskey(getfield(m2m, :fields), "tags")
    @test !("tags" in getfield(m2m, :field_names))

    card = _plain(m2m)
    @test occursin("tags", card)
    @test occursin("ManyToManyField", card)

    # The two renderings must agree on the count. The compact form reports `length(fields)`; the card
    # must show that many rows (or say how many it elided).
    @test _inner(m2m) == "Model(\"rs_m2m\", 3 fields)"
    @test count(l -> startswith(l, "  ") && !startswith(l, "  reverse:") && !startswith(l, "  query:") &&
                     !startswith(l, "  ⋮"), split(card, '\n')) == 3
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # Row display is deterministic.
  # `PormGRow._data` is a `Dict`, so unsorted iteration would order columns by hash — a row that
  # renders its columns differently on the next session, and differently again from the `values(...)`
  # call that produced it. The primary key leads because that is the column a reader looks for.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "row columns render in a stable order, pk first" begin
    data = Dict{Symbol,Any}(:surname => "Senna", :id => 7, :active => true)
    row = PormG.PormGRow(data, RS.Rs_driver)

    first_render = _plain(row)
    @test first_render == _plain(PormG.PormGRow(copy(data), RS.Rs_driver))

    lines = split(first_render, '\n')
    # Line 1 is the header; line 2 is the first column, which must be the pk.
    @test occursin("id", lines[2])
    # The remaining columns are alphabetical, so `active` precedes `surname`.
    @test findfirst(l -> occursin("active", l), lines) < findfirst(l -> occursin("surname", l), lines)
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # `Vector{PormGRow}` keeps STANDARD Julia vector display.
  # A deliberate non-goal, recorded as a test so it is not "fixed" later by accident: there is no
  # custom method for the vector. Standard display already honours `:limit`, elides long vectors on
  # its own, and stays predictable — and it is bounded here purely because the ELEMENT show is.
  # `DataFrame(q)` is the tabular view.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "list() output uses standard vector display" begin
    rows = [PormG.PormGRow(Dict{Symbol,Any}(:id => i, :surname => "D$i"), RS.Rs_driver) for i in 1:200]
    out = _plain(rows)

    @test occursin("200-element Vector", out)
    # `:limit` is what `display` sets; standard vector display elides under it.
    limited = sprint(io -> show(IOContext(io, :limit => true, :displaysize => (24, 80)), MIME"text/plain"(), rows))
    @test occursin("⋮", limited)
    @test length(limited) < CEILING
  end
end

# ═════════════════════════════════════════════════════════════════════════════
# #649 — the credential-bearing types: the connection pools and `Settings`.
#
# These are NOT model-bearing, and they are in this file because the failure mode is the same
# absence — no method, so `show_default` walks the slots — with a different consequence. Measured on
# an unpatched build with a fake DSN:
#
#     sprint(show, pool)      196 chars   contains the DSN password
#     _plain(Settings)        382 chars   contains it, plus `db_config_settings`' raw YAML password
#     _plain(config)          439 chars   the same, once per entry
#
# **So there are no CEILINGS entries below, and that is the point.** Everything above this line is
# quantitative because #534's defect was a size; 196 characters is an ordinary display, so a ceiling
# would pass against completely unpatched code. The assertion that discriminates here is per-token
# absence of a credential we invented.
#
# The two routes are asserted separately, because they promise different things — the compact form
# (what `show_default` calls for a NESTED slot) carries no connection string at all, while the card
# carries a REDACTED one. Asserting only the card would miss a nested pool dumping its DSN inside
# some other value's rendering.
# ═════════════════════════════════════════════════════════════════════════════

const D649_PW   = "d649_fake_dsn_password"
const D649_USER = "d649_fake_dsn_username"
const D649_YAML = "d649_fake_yaml_password"
const D649_DSN  = "host=localhost port=5432 password=$D649_PW dbname=f1 user=$D649_USER"

# A legal `Settings.connections` value carrying no slots whatsoever — the shape every dispatch
# marker and pool-shaped mock in the repo has, and the one that exercises the `hasfield` guards in
# `_d_slot` / `_d_redacted_dsn`.
struct D649FieldlessPool <: PormG.PormGPostgres end

# A backend in NEITHER family — legal, since `PormGBackend` can be subtyped directly — which is the
# only thing that reaches `_d_backend_label`'s fallback arm.
struct D649OtherBackend <: PormG.Kernel.PormGBackend end

# Hermetic: a pool constructor allocates slots and opens nothing.
_d649_pg() = PormG.ConnectionPool.PostgresConnectionPool(D649_DSN; pool_size = 2)
_d649_sl() = PormG.ConnectionPool.SQLiteConnectionPool("/tmp/d649.sqlite"; pool_size = 1)

_d649_settings() = PormG.Configuration.Settings(
  # Explicit, NOT inherited: `Settings()` defaults `app_env` from `ENV["PORMG_ENV"]`, and
  # `test/runtests.jl` sets that to "test". Without this the exact renderings below pass when
  # the file is run alone and fail inside the suite.
  app_env            = "dev",
  connections        = _d649_pg(),
  db_def_folder      = "d649_folder",
  change_data        = true,
  db_config_settings = Dict{String, Any}("adapter" => "PostgreSQL", "password" => D649_YAML),
)

# ─────────────────────────────────────────────────────────────────────────────
# Exact renderings. Both methods, both routes, so a change to either is a deliberate act rather
# than something noticed later — the same standard the model-graph methods are held to above.
# ─────────────────────────────────────────────────────────────────────────────
@testset "pools and Settings render exactly (#649)" begin
  @test _inner(_d649_pg()) == "Pool(PostgreSQL, 2 slots)"
  # Singular, because "1 slots" is the kind of thing that survives forever once shipped.
  @test _inner(_d649_sl()) == "Pool(SQLite, 1 slot)"
  # A fieldless dispatch marker has no `pool_size` and no `connection_string`; the abstract method
  # must survive it rather than raise from inside a display (rule 1).
  @test _inner(PormG.Migrations._PostgresEngine()) == "Pool(PostgreSQL)"
  @test _plain(PormG.Migrations._PostgresEngine()) == "Pool(PostgreSQL)"

  # The card carries the DSN, redacted by the one owner of that rule.
  @test _plain(_d649_pg()) ==
        "Pool(PostgreSQL, 2 slots)\n  dsn: host=localhost port=5432 password=**** dbname=f1 user=****"

  @test _inner(_d649_settings()) == "Settings(\"dev\", PostgreSQL)"
  # A `Settings` with no pool still renders, and says so rather than omitting the line.
  @test _inner(PormG.Configuration.Settings(app_env = "dev")) == "Settings(\"dev\")"
  @test occursin("connection: none", _plain(PormG.Configuration.Settings(app_env = "dev")))
end

# ─────────────────────────────────────────────────────────────────────────────
# THE ASSERTION THIS SECTION EXISTS FOR. Per token, absence only, over both routes and over the
# containers these are actually met in — a `Settings` inside `PormG.config` is the shape a health
# check dumps, and it reaches the pool two hops down.
# ─────────────────────────────────────────────────────────────────────────────
@testset "no display route leaks a credential (#649)" begin
  settings = _d649_settings()
  cases = Pair{String, Any}[
    "pool"               => _d649_pg(),
    "sqlite pool"        => _d649_sl(),
    "Settings"           => settings,
    "config-shaped Dict" => Dict{String, PormG.PormGSettings}("d649" => settings),
    "pool in a Vector"   => [_d649_pg(), _d649_sl()],
    "pool in a Dict"     => Dict("held" => _d649_pg()),
  ]

  for (label, value) in cases
    @testset "$label" begin
      for (route, rendered) in ("compact" => _inner(value), "card" => _plain(value))
        # The credentials themselves…
        @test !occursin(D649_PW, rendered)
        @test !occursin(D649_USER, rendered)
        @test !occursin(D649_YAML, rendered)
        # …and the slot names that only appear if `show_default` reflected.
        @test !occursin("db_config_settings", rendered)
        @test !occursin("connection_string", rendered)
        @test !occursin("ReentrantLock", rendered)
        # The compact route promises MORE than absence of the secret: no DSN at all, redacted or
        # not. `password=****` on a nested value would satisfy every assertion above and still be
        # the wrong contract.
        route == "compact" && @test !occursin("password", rendered)
      end
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# The card's DSN goes through `redact_secret` rather than through a second pattern living here.
# Asserted on the URL dialect specifically: that form was invisible to the rule before #649, so a
# display that quietly kept its own copy of the old pattern would pass the DSN cases above and leak
# here.
# ─────────────────────────────────────────────────────────────────────────────
@testset "the card redacts both DSN dialects (#649)" begin
  url_pool = PormG.ConnectionPool.PostgresConnectionPool(
    "postgresql://$D649_USER:$D649_PW@localhost:5432/f1"; pool_size = 1)

  card = _plain(url_pool)
  @test !occursin(D649_PW, card)
  @test !occursin(D649_USER, card)
  @test occursin("postgresql://****:****@localhost:5432/f1", card)
end

# ─────────────────────────────────────────────────────────────────────────────
# Rule 1, for the two new methods: a display never throws. These types are reachable mid-
# construction and from downstream code, and a `show` that raises poisons the REPL for every value
# printed afterwards — including the exception you were trying to read.
# ─────────────────────────────────────────────────────────────────────────────
@testset "a credential display never throws (#649)" begin
  broken = _d649_pg()
  # A slot holding a value whose own display would be unhelpful, and one that is outright the wrong
  # type for the slot's usual contents.
  setfield!(broken, :connections, Any[ErrorException("must not be rendered"), nothing])
  @test _inner(broken) isa String
  @test !occursin("must not be rendered", _plain(broken))

  # A backend with NO slots at all. `Settings.connections` is typed
  # `Union{Nothing, PormGPostgres, PormGSQLite}`, so "a slot holding something that is not a pool"
  # is unrepresentable — `setfield!` raises — and an earlier draft of this block wrote
  # `setfield!(odd, :connections, nothing)` on a field that was already `nothing`, which tested
  # precisely nothing. A fieldless mock is the real edge: it IS a legal `connections` value and it
  # answers `hasfield` false for every slot the two methods read.
  settings = PormG.Configuration.Settings(app_env = "dev", connections = D649FieldlessPool())
  # Labelled by FAMILY, not by struct name — a `PormGPostgres` subtype reads "PostgreSQL" whatever
  # it is called, which is what makes one method cover every present and future pool type.
  @test _inner(settings) == "Settings(\"dev\", PostgreSQL)"
  card = _plain(settings)
  @test occursin("connection: Pool(PostgreSQL)", card)
  # No slot count, because there is no `pool_size` to read…
  @test !occursin("slot", card)
  # …and no `dsn:` line, because there is no connection string to redact. Neither is a `nothing`
  # rendered into the output, and neither is a raise from reading an absent slot.
  @test !occursin("dsn:", card)

  # The fallback arm of `_d_backend_label`, which nothing else reaches: a backend that is neither
  # of the two families. It names the struct rather than guessing one of them — a mislabelled
  # engine is a worse answer than an unfamiliar one.
  @test _inner(D649OtherBackend()) == "Pool(D649OtherBackend)"
end
