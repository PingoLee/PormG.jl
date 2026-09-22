"""
Serializing a `PormGRow` with `JSON.json` (#641).

`PormGRow` is `{_data, _model, _dirty}` and JSON.jl has no method for it, so the writer reflected
over all three slots and walked into `_model` — the model graph. That graph is a dense, cyclic DAG
(`Model_Type.fields` → `sForeignKey.to` → `Model_Type.related_objects` →
`ReverseRelation.model_resolved` → …). JSON.jl breaks true cycles with an ANCESTOR stack, so the
call terminates; what it does NOT do is memoize, so every distinct PATH through the graph is
serialized again. The cost is therefore exponential in the schema's density, not linear in the row:

    this file's 2-model fixture      26 chars of row  →      2,359 chars
    the 14-model F1 fixture          26 chars of row  →  1,843,565 chars, 5.3s of CPU
    a production application schema  one row          →  28.5 GB RSS, oom-kill

which is why the reported symptom is a dead process and an empty request log rather than a big
string. The row itself was never the problem — `JSON.json(getfield(row, :_data))` was always instant.

This is `src/display.jl` (#534) one hop over: the same graph, the same absence of a method,
serialization instead of display. The fix is the same shape too — one method on the type a user
actually hands to a serializer.

**The assertions here are quantitative on purpose**, for #534's reason: the defect is a size, and
only a ceiling catches its return. The ceilings are calibrated against *this* file's two-model
fixture — 2,359 chars for one row when reverted, 26 when fixed — NOT against the MB/GB figures
above, which come from bigger graphs. A ceiling loose enough for those would pass against a full
revert here.

**Nothing below calls `JSON.json` on a row until `HAS_LOWER` has been asserted.** That ordering is
load-bearing rather than tidy: on unpatched code the call is a multi-second, multi-megabyte
allocation storm, and on a real application schema it takes the process with it. A `Task` with a
timeout — the obvious alternative — does not help, because a Julia task cannot be killed: the
deadline would fire while the runaway serialization kept allocating underneath it.

Hermetic — no live database, no fixture data; the only connection is the inert mock below.

julia --project=test/integration test/unit/test_json_serialization.jl
"""

using Test
using PormG
using PormG.Models
using Dates

# JSON is a `[deps]` of PormG but NOT of `[targets].test`, so `using JSON` would fail under
# `Pkg.test()`. Reach the very same module the package serializes with instead.
const J641 = PormG.QueryBuilder.JSON
const SU641 = J641.StructUtils
const STYLE641 = J641.JSONWriteStyle()

# ── Fixture ──────────────────────────────────────────────────────────────────
#
# Its own config key, registered the way `test_repl_display.jl` does, so this file cannot
# contaminate (or be contaminated by) another unit file sharing `Main` under `runtests.jl`. The
# connection is inert: nothing here renders SQL or opens anything.
struct Json641InertConn <: PormG.PormGSQLite end

PormG.config["json_641_no_connection"] = PormG.Configuration.Settings(
  connections = Json641InertConn(),
  change_data = true,
  db_def_folder = "json_641_no_connection",
)

# The minimum shape that reproduces the graph: a parent, a child with a ForeignKey to it (which
# installs a `ReverseRelation` back on the parent), and a self-referencing FK so the graph is
# genuinely cyclic rather than merely deep.
module Json641Models
import PormG
import PormG.Models

J_team = Models.Model("j_team",
  id   = Models.IDField(),
  name = Models.CharField(max_length = 80),
)

# #643 needs a `ManyToManyRelation` specimen, and one only exists once a `ManyToManyField` has been
# declared — the relation object is installed on the TARGET model's `related_objects`, not on the
# declaring one. Same reason `test_repl_display.jl` grew `Rs_tagged`.
J_sponsor = Models.Model("j_sponsor",
  id   = Models.IDField(),
  name = Models.CharField(unique = true),
)

J_driver = Models.Model("j_driver",
  id       = Models.IDField(),
  surname  = Models.CharField(max_length = 50),
  lap      = Models.DurationField(null = true),
  team     = Models.ForeignKey(J_team, on_delete = "RESTRICT", related_name = "j_drivers"),
  mentor   = Models.ForeignKey("J_driver", on_delete = "SET_NULL", null = true, related_name = "j_mentees"),
  sponsors = Models.ManyToManyField(J_sponsor, related_name = "j_drivers_m2m"),
)

PormG.Models.set_models(@__MODULE__, "json_641_no_connection")
end

const JM = Json641Models

# FK targets and reverse relations resolve LAZILY, so a freshly-defined model graph is still open at
# the edges (`sForeignKey.to === nothing`, `ReverseRelation.model_resolved === nothing`). Building a
# query across the FK is what closes it — and an open graph is a fixture that under-represents the
# defect, so the closure is asserted below rather than assumed.
PormG.inspect_query(JM.J_driver.objects.values("surname", "team__name"))

# A row's `_data` is a plain `Dict`, so these values stand in for what a driver hands back; the model
# is only along for the ride (and is exactly what used to get serialized).
const ROW_DATA = Dict{Symbol, Any}(
  :id      => 7,
  :surname => "Senna",
  :lap     => Minute(1) + Second(49) + Millisecond(88),
)
_row(data = ROW_DATA) = PormG.PormGRow(copy(data), JM.J_driver)

# ─────────────────────────────────────────────────────────────────────────────
# The gate: WHO serves `lower(::JSONStyle, ::PormGRow)`.
# Asserted first and on its own, because every behavioural assertion below is guarded on it. Revert
# the fix and this is `StructUtils`' identity fallback — the file goes red in microseconds instead
# of hanging the runner, and nothing hands an unguarded row to `JSON.json`.
# ─────────────────────────────────────────────────────────────────────────────
# `methods(...)`, not `which(...)`: `which` THROWS on an ambiguity rather than returning a method, so
# if JSON ever gained a `lower(::JSONWriteStyle, ::Any)` this line would take the file down as an
# include-time error instead of producing the clean red `@test HAS_LOWER` the design depends on.
#
# The module is part of the question, not decoration: `StructUtils.lower` has an identity fallback, so
# "a method exists" is always true and only "a method WE define exists" is the fix. The two families
# land in different modules on purpose — the row hook stays beside `_json_row` in `QueryBuilder`
# (it shapes data), while #643's graph markers live in `PormG.json_lower` (they bound the schema) —
# so the helper takes the module it expects rather than hard-coding one. (`src/json_lower.jl` is a
# plain include, not a submodule, so its methods report `PormG`.)
_lower_owned_by(T, mod) = any(m -> m.module === mod, methods(SU641.lower, Tuple{Any, T}))

const HAS_LOWER = _lower_owned_by(PormG.PormGRow, PormG.QueryBuilder)

@testset "PormGRow has a JSON lower method (#641)" begin
  @test HAS_LOWER

  # The fixture is only a fixture while the graph is actually closed (see above).
  @test getfield(getfield(JM.J_team, :related_objects)["j_drivers"], :model_resolved) isa Models.Model_Type
  @test getfield(getfield(JM.J_driver, :fields)["mentor"], :to) isa Models.Model_Type
end

# ─────────────────────────────────────────────────────────────────────────────
# What the hook returns: the row's own data, keyed by String, every value through `_json_value`.
# This is the level the fix lives at, and it needs no serializer to assert — which is why it runs
# whether or not the gate above held.
# ─────────────────────────────────────────────────────────────────────────────
@testset "lower() returns the row's data, not its model" begin
  lowered = SU641.lower(STYLE641, _row())

  @test lowered isa Dict{String, Any}
  @test lowered == Dict{String, Any}(
    "id" => 7,
    "surname" => "Senna",
    # #564's formatter, reached through `_json_value` — the same owner `list(:json)` asks.
    "lap" => "00:01:49.088",
  )
  # The model is not reachable from the result at all — no slot, no nesting, nothing to walk.
  @test !haskey(lowered, "_model")
  @test !haskey(lowered, "_data")
  @test !haskey(lowered, "_dirty")

  # FAIL-OPEN is preserved on the new path. `format_duration_sql` REFUSES a month or year component
  # ("Months and years are ambiguous"), and `_json_value` hands such a value back untouched rather
  # than raising — so a PostgreSQL `interval '1 month'` still serializes (poorly) instead of turning
  # a working response into a 500. Asserted with `===`: it can only hold if the call RETURNED.
  refused = SU641.lower(STYLE641, PormG.PormGRow(Dict{Symbol, Any}(:span => Month(1)), JM.J_driver))
  @test refused["span"] === Month(1)
end

# ─────────────────────────────────────────────────────────────────────────────
# End to end through `JSON.json`, and the size ceiling that is the actual regression test.
# Guarded on the gate — see the file header for why that guard is not optional.
# ─────────────────────────────────────────────────────────────────────────────
if HAS_LOWER
  @testset "JSON.json(row) serializes the row" begin
    # An EXACT match, on a single-key row so no `Dict` iteration order is being asserted. (Julia
    # 1.13 changed string hashing — #544 — and CI runs 1.12 and 1.13, so an exact multi-key string
    # is a cross-version flake waiting to happen.)
    @test J641.json(PormG.PormGRow(Dict{Symbol, Any}(:id => 7), JM.J_driver)) == "{\"id\":7}"

    # For the full row, exact equality of the PARSED document — same strictness, no key order.
    @test J641.parse(J641.json(_row())) ==
      Dict{String, Any}("id" => 7, "surname" => "Senna", "lap" => "00:01:49.088")

    # A `Vector{PormGRow}` is what `list()` actually returns, and it is the shape a handler hands to
    # a response. JSON's own `lower(::JSONStyle, ::AbstractVector)` walks it element by element, so
    # the one method above covers it — asserted, because "should follow" is not coverage.
    @test J641.parse(J641.json([_row(), _row()])) == [
      Dict{String, Any}("id" => 7, "surname" => "Senna", "lap" => "00:01:49.088"),
      Dict{String, Any}("id" => 7, "surname" => "Senna", "lap" => "00:01:49.088"),
    ]
  end

  # ───────────────────────────────────────────────────────────────────────────
  # The ceilings. Tight against THIS fixture: one row measures 26 chars fixed and 2,359 reverted, so
  # 200 separates them by an order of magnitude at both ends. A ceiling calibrated against the MB
  # figures in the header would sail straight over a full revert.
  # ───────────────────────────────────────────────────────────────────────────
  @testset "a row's JSON is bounded by its data, not by its schema" begin
    one = J641.json(_row())
    @test length(one) < 200                                            # fixed: 47; reverted: 2,359

    # SCALE-RELATIVE on purpose, where the absolute ceilings above are calibrated constants. This
    # one states the property rather than a measurement — twenty rows cost twenty rows, not twenty
    # schemas — so it keeps its meaning if the fixture ever grows a column.
    @test length(J641.json([_row() for _ in 1:20])) < 25 * length(one)  # fixed: 961

    # The control, and the assertion that names the defect directly: the serialized row carries none
    # of the schema vocabulary that the reflected model dump is made of. Implied by the exact
    # document above, and kept anyway for its failure MESSAGE — schema bleed reports one token here
    # instead of a megabyte-wide diff there.
    for schema_token in ("formatter", "related_objects", "connect_key", "field_names", "j_team")
      @test !occursin(schema_token, one)
    end
  end
end

# ═════════════════════════════════════════════════════════════════════════════
# #643 — the rest of the model graph. `PormGRow` was the type a web handler hits by accident; these
# have to be typed on purpose, which is why #641 shipped the narrow fix and left them here.
#
# Every one of them lowers to a ONE-KEY MARKER object, so the assertions can be EXACT DOCUMENTS
# rather than only ceilings — and that matters most for the small cases. An unfixed `sCharField`
# measures 244 chars against this fixture, so no honest ceiling distinguishes it from a fixed 27;
# equality does. The ceiling's job is different: it catches a type that starts walking the graph
# again, including one added later.
#
# Measured against THIS fixture (3 models), fixed vs. reverted — the revert being the
# `include("json_lower.jl")` line commented out of `src/PormG.jl`:
#
#     Model_Type               26  /  5,476        ObjectHandler         26  /  5,741
#     Model_Type (parent)      24  /  5,476        SQLObjectQuery        26  /  5,730
#     sCharField               27  /    244        InstructionObject     32  /  6,415
#     sForeignKey              28  /  5,476        ManyToManyRelation    48  / 10,268
#     sForeignKey (self)       28  /  5,476        ReverseRelation       42  /  5,575
#     sManyToManyField         33  /  4,337
#
# ONE ceiling constant covers all of it, where `test_repl_display.jl` needed a per-case table. That is
# not laziness: `show` renders content, so its real sizes ranged 24–432 and a single number was either
# loose or wrong. Here every document is a one-key marker, so the fixed range is 24–48 against a
# reverted minimum of 244 — a single bound sits an order of magnitude clear at both ends.
#
# At the 14-model F1 scale the same reverts measure 2,175,304 (`Model_Type`), 2,158,654 (one
# `sForeignKey`), 3,087,881 (`ReverseRelation`) and 2,177,351 (`InstructionObject`). This fixture
# cannot reach those; `test/integration/test_row_and_get.jl` carries the real-scale assertion.
# ═════════════════════════════════════════════════════════════════════════════

# An `InstructionObject` built DIRECTLY through its `@kwdef` constructor, never through `build()` —
# which reaches `get_settings` and would make this file non-hermetic. `connection` is the inert mock,
# which is the whole point of the case: that slot is why this type is a credential surface and not
# merely a big one.
function _instruction()
  ta = PormG.QueryBuilder.SQLTbAlias()
  return PormG.QueryBuilder.InstructionObject(
    text        = "",
    table_alias = ta,
    alias       = PormG.QueryBuilder.get_alias(ta),
    object      = JM.J_driver.objects.object,
    connection  = Json641InertConn(),
  )
end

# label => (value, the exact document it must produce)
const GRAPH_CASES = Pair{String, Tuple{Any, String}}[
  "Model_Type"          => (JM.J_driver,                                               "{\"pormg_model\":\"j_driver\"}"),
  "Model_Type (parent)" => (JM.J_team,                                                 "{\"pormg_model\":\"j_team\"}"),
  "sCharField"          => (getfield(JM.J_driver, :fields)["surname"],                 "{\"pormg_field\":\"CharField\"}"),
  "sForeignKey"         => (getfield(JM.J_driver, :fields)["team"],                    "{\"pormg_field\":\"ForeignKey\"}"),
  "sForeignKey (self)"  => (getfield(JM.J_driver, :fields)["mentor"],                  "{\"pormg_field\":\"ForeignKey\"}"),
  "sManyToManyField"    => (getfield(JM.J_driver, :fields)["sponsors"],                "{\"pormg_field\":\"ManyToManyField\"}"),
  "ReverseRelation"     => (getfield(JM.J_team, :related_objects)["j_drivers"],        "{\"pormg_reverse_relation\":\"j_driver.team\"}"),
  "ManyToManyRelation"  => (getfield(JM.J_sponsor, :related_objects)["j_drivers_m2m"], "{\"pormg_many_to_many\":\"j_sponsor.j_drivers_m2m\"}"),
  "ObjectHandler"       => (JM.J_driver.objects,                                       "{\"pormg_query\":\"j_driver\"}"),
  "SQLObjectQuery"      => (JM.J_driver.objects.object,                                "{\"pormg_query\":\"j_driver\"}"),
  "InstructionObject"   => (_instruction(),                                            "{\"pormg_instruction\":\"j_driver\"}"),
]

const GRAPH_CEILING = 120     # fixed range 24–48; reverted minimum 244

# ─────────────────────────────────────────────────────────────────────────────
# The gate, asserted before ANY `JSON.json` call on a graph-bearing value, for the reason in the file
# header: on unpatched code these are multi-megabyte allocation storms, and at application scale the
# process dies. A Julia task cannot be killed, so a timeout cannot rescue it.
#
# The abstract field method is queried TWICE — once as `PormGField`, once as concrete structs. Only
# the concrete query proves the abstract method is what a real field dispatches to; the abstract query
# alone would still pass if someone narrowed the signature to one struct.
# ─────────────────────────────────────────────────────────────────────────────
const GRAPH_TYPES = [
  Models.Model_Type, PormG.PormGField, Models.sCharField, Models.sForeignKey,
  Models.sManyToManyField, Models.ReverseRelation, Models.ManyToManyRelation,
  PormG.QueryBuilder.SQLObjectQuery, PormG.QueryBuilder.ObjectHandler,
  PormG.QueryBuilder.InstructionObject,
]

const HAS_GRAPH_LOWER = all(T -> _lower_owned_by(T, PormG), GRAPH_TYPES)

@testset "every model-graph type has a JSON lower method (#643)" begin
  @test HAS_GRAPH_LOWER
  # Named individually so a failure says WHICH type lost its method, rather than just `false`.
  for T in GRAPH_TYPES
    @testset "$(nameof(T))" begin
      @test _lower_owned_by(T, PormG)
    end
  end

  # The fixture has to actually contain a ManyToManyRelation, or its case above is vacuous.
  @test getfield(JM.J_sponsor, :related_objects)["j_drivers_m2m"] isa Models.ManyToManyRelation
end

if HAS_GRAPH_LOWER
  # ───────────────────────────────────────────────────────────────────────────
  # Exact documents. The primary assertion: it pins the marker SHAPE (one key, `pormg_` prefixed) and
  # the content, and it is what catches the small cases a ceiling cannot.
  # ───────────────────────────────────────────────────────────────────────────
  @testset "each model-graph type lowers to its marker document" begin
    for (label, (value, expected)) in GRAPH_CASES
      @testset "$label" begin
        @test J641.json(value) == expected
      end
    end
  end

  # ───────────────────────────────────────────────────────────────────────────
  # The ceiling, and the containers. A bare value is not how these are met in practice — they are met
  # nested inside something a handler is serializing, which is the whole reason a marker on
  # `Model_Type` and on the ABSTRACT field type bounds everything holding one.
  # ───────────────────────────────────────────────────────────────────────────
  @testset "a model-graph value is bounded wherever it appears" begin
    for (label, (value, _)) in GRAPH_CASES
      @testset "$label" begin
        @test length(J641.json(value)) < GRAPH_CEILING
        @test length(J641.json(Dict("held" => value))) < GRAPH_CEILING + 40
        @test length(J641.json([value, value])) < 3 * GRAPH_CEILING
      end
    end

    # The whole fields collection at once: an `OrderedDict{String,PormGField}` is what a `Model_Type`
    # holds, and before the abstract method every entry expanded the graph again.
    @test length(J641.json(getfield(JM.J_driver, :fields))) < 6 * GRAPH_CEILING
  end

  # ───────────────────────────────────────────────────────────────────────────
  # THE INVARIANT, not an inventory. The marker shape closes the defect by making every lowered value
  # a LEAF — if nothing returned from a PormG `lower` can hold a PormG type, the serializer has no
  # edge to explode along, for these types and for any added later. Asserted structurally rather than
  # by listing the types, which is the difference between this and the block above.
  #
  # It is deliberately NOT demonstrable by mutating one of the cases above, and that was checked:
  # break a marker into a nested return and the exact-document assertion fires first and aborts the
  # file, so this block never runs. Its job is the case that does NOT yet exist — someone adding a
  # `lower` method and recording its OBSERVED output as the expected document, which is how green
  # theater is written. The exact documents pin what each case emits; this pins what a correct
  # expected document is allowed to look like, which no amount of recording can satisfy by accident.
  # ───────────────────────────────────────────────────────────────────────────
  @testset "no lowered value holds a PormG type" begin
    _is_pormg(x) = (m = parentmodule(typeof(x)); m === PormG || parentmodule(m) === PormG)

    function leaves_only(x, depth = 0)
      depth > 6 && return false          # a marker is 1 level deep; anything deeper is a walk
      x === nothing && return true
      x isa Union{AbstractString, Number, Bool, Symbol} && return true
      x isa AbstractDict && return all(p -> leaves_only(last(p), depth + 1), collect(x))
      x isa AbstractVector && return all(v -> leaves_only(v, depth + 1), x)
      return !_is_pormg(x)
    end

    for (label, (value, _)) in GRAPH_CASES
      @testset "$label" begin
        @test leaves_only(SU641.lower(STYLE641, value))
      end
    end
  end

  # (The `methods`-swept coverage assertion that used to sit here moved to the FOOT of this file
  # with #649: it now has to be satisfied by GRAPH_CASES *and* CONFIG_CASES together, and
  # CONFIG_CASES is defined below. Keeping it here would have silently checked half the methods.)

  # ───────────────────────────────────────────────────────────────────────────
  # Controls. `sCharField` is no longer one — it IS a `PormGField`, so it is covered now and has moved
  # into the exact-document block above. What remains to control for is the opposite risk: that these
  # methods intercept something JSON already handled correctly.
  # ───────────────────────────────────────────────────────────────────────────
  @testset "ordinary values are untouched" begin
    @test J641.json(Dict("a" => 1)) == "{\"a\":1}"
    @test J641.json([1, 2, 3]) == "[1,2,3]"
    @test J641.json("text") == "\"text\""
    # And #641 is unaffected: a row still serializes its DATA through its own hook.
    @test J641.json(PormG.PormGRow(Dict{Symbol, Any}(:id => 7), JM.J_driver)) == "{\"id\":7}"
  end

  # ───────────────────────────────────────────────────────────────────────────
  # The credential contract, and the reason the `InstructionObject` arm is not merely a size fix. That
  # type holds a live `connection`, so reflection walked into the pool and out through
  # `connection_string` — measured on a live PostgreSQL run, the 2.18 MB document contained
  # `password`. `Configuration.redact_secret` exists because that string is a secret and is applied at
  # every logging site; struct reflection was the same egress with none of it.
  #
  # NOTE the scope, because this must not be read as more than it is: it covers the path THROUGH THE
  # MODEL GRAPH. `JSON.json` on a pool, a `Settings`, or `PormG.config` reaches none of these methods
  # and is not closed here.
  # ───────────────────────────────────────────────────────────────────────────
  @testset "no lowered value leaks connection state" begin
    for (label, (value, _)) in GRAPH_CASES
      @testset "$label" begin
        doc = J641.json(value)
        for token in ("connection", "connection_string", "password", "Json641InertConn",
                      "pool_size", "available")
          @test !occursin(token, doc)
        end
      end
    end
  end

  # ───────────────────────────────────────────────────────────────────────────
  # Two contracts that are not about size.
  #
  # The no-connection one mirrors `test_repl_display.jl`, whose header records that asserting it
  # against an inert MOCK proved nothing — a mock connection is still a connection. Removing the
  # config entry is what makes the claim real: nothing here may reach `get_settings`.
  #
  # A CONTENT bound rather than a wall-clock one for the work check: under the marker shape the
  # content bound IMPLIES the work bound (a 4 MB default cannot be in a 120-char document without
  # having been read), and it does not flake on a loaded CI runner.
  # ───────────────────────────────────────────────────────────────────────────
  @testset "lowering never reaches configuration, and never reads a value" begin
    saved = PormG.config["json_641_no_connection"]
    try
      delete!(PormG.config, "json_641_no_connection")
      for (label, (value, expected)) in GRAPH_CASES
        @testset "$label" begin
          @test J641.json(value) == expected
        end
      end
    finally
      PormG.config["json_641_no_connection"] = saved
    end

    # A field carrying a 4 MB default. The marker names the field's TYPE, so the value is never
    # touched — where `show(::PormGField)` would render `default=` and truncate it, which is exactly
    # why these methods are not `sprint(show, x)`.
    big = Models.CharField(max_length = 4_000_000, default = repeat("x", 4_000_000))
    @test J641.json(big) == "{\"pormg_field\":\"CharField\"}"

    # A half-built graph — a model defined but not yet `set_models`-ed, so its FK target is still
    # `nothing`. This is the introspection-time shape, and a marker must survive it rather than throw
    # from inside a serializer.
    half = Models.Model("j_half", id = Models.IDField(), other = Models.ForeignKey("J_missing"))
    @test J641.json(half) == "{\"pormg_model\":\"j_half\"}"
    @test J641.json(getfield(half, :fields)["other"]) == "{\"pormg_field\":\"ForeignKey\"}"
  end
end

# ═════════════════════════════════════════════════════════════════════════════
# #649 — the credential types. `JSON.json` on a connection pool, on a `Settings`, or on
# `PormG.config` never touches the model graph, so it reached NONE of the methods above; #643 said
# so in its own header and left this to a follow-up.
#
# **These cases are kept apart from GRAPH_CASES on purpose, because the defect is a different kind
# of thing.** Above, reverting the fix costs megabytes and a ceiling catches it. Here, measured on
# an unpatched build with a fake DSN:
#
#     JSON.json(pool)        355 chars   contains the password
#     JSON.json(Settings)    616 chars   contains the DSN password AND the raw YAML password
#     JSON.json(config)      630 chars   same, once per entry
#
# 355 characters. No honest ceiling separates that from a fixed 33, so a ceiling assertion here
# would pass against completely unpatched code — green theater of exactly the kind this file's
# header warns about. PER-TOKEN ABSENCE is the only assertion that discriminates, and it is also
# what the issue asked for independently.
#
# The tokens below are ours: this fixture's DSN is invented, so asserting on the VALUE is both safe
# to print in a CI failure and strictly stronger than asserting on the key names around it. The
# integration half (`test/integration/test_internals.jl`) faces a real DSN and can only assert on
# tokens and shapes; it never prints what it is looking for.
# ═════════════════════════════════════════════════════════════════════════════

# Invented, and deliberately distinctive: a substring that could occur in ordinary output would make
# the absence assertions below unfalsifiable.
const FAKE_DSN_PW   = "j649_fake_dsn_password"
const FAKE_DSN_USER = "j649_fake_dsn_username"
const FAKE_YAML_PW  = "j649_fake_yaml_password"
const FAKE_DSN = "host=localhost port=5432 password=$FAKE_DSN_PW dbname=f1 user=$FAKE_DSN_USER"

# Pools construct without connecting — the constructors only allocate slots — so this stays
# hermetic. Nothing below opens a socket or reads a configuration file.
_pg_pool() = PormG.ConnectionPool.PostgresConnectionPool(FAKE_DSN; pool_size = 2)
_sl_pool() = PormG.ConnectionPool.SQLiteConnectionPool("/tmp/j649.sqlite"; pool_size = 1)

_settings649() = PormG.Configuration.Settings(
  # Explicit, NOT inherited — see the note in `test_repl_display.jl`: `ENV["PORMG_ENV"]` is
  # "test" under `Pkg.test()` and unset when this file is run alone.
  app_env            = "dev",
  connections        = _pg_pool(),
  db_def_folder      = "j649_folder",
  change_data        = true,
  # The second, INDEPENDENT egress: the raw parsed YAML block, which is not reached through the
  # pool. `redact_secret` reads a connection string and cannot see a `password:` key at all, which
  # is why the fix omits this dict rather than filtering it.
  db_config_settings = Dict{String, Any}(
    "adapter"  => "PostgreSQL",
    "password" => FAKE_YAML_PW,
    "url"      => "postgres://u:$(FAKE_YAML_PW)@h/db",
  ),
)

const CONFIG_CASES = Pair{String, Tuple{Any, String}}[
  "PostgresConnectionPool" => (_pg_pool(), "{\"pormg_connection\":\"PostgreSQL\"}"),
  "SQLiteConnectionPool"   => (_sl_pool(), "{\"pormg_connection\":\"SQLite\"}"),
  # A fieldless dispatch marker is a legitimate member of the family — the abstract method has to
  # survive one, which is the case that would throw if a slot were read unguarded.
  "engine marker"          => (PormG.Migrations._PostgresEngine(), "{\"pormg_connection\":\"PostgreSQL\"}"),
  "Settings"               => (_settings649(),
    "{\"pormg_settings\":{\"app_env\":\"dev\",\"change_data\":true,\"change_db\":false," *
    "\"connection\":\"PostgreSQL\",\"db_def_folder\":\"j649_folder\",\"django_prefix\":null," *
    "\"implicit\":false,\"model_file\":\"models.jl\",\"time_zone\":\"UTC\"}}"),
]

const CONFIG_TYPES = [
  PormG.Kernel.PormGBackend, PormG.Kernel.PormGSettings,
  PormG.ConnectionPool.PostgresConnectionPool, PormG.ConnectionPool.SQLiteConnectionPool,
  PormG.Configuration.Settings,
]

# The gate, same shape as the model-graph one above: assert the methods exist before anything calls
# `JSON.json` on a value that would otherwise reflect a credential into this process's output.
const HAS_CONFIG_LOWER = all(T -> _lower_owned_by(T, PormG), CONFIG_TYPES)

@testset "every credential type has a JSON lower method (#649)" begin
  @test HAS_CONFIG_LOWER
  # The abstract types are queried alongside the concrete ones. Only the concrete query proves a
  # real pool dispatches to the abstract method; the abstract query alone would still pass if
  # someone narrowed the signature to one struct.
  for T in CONFIG_TYPES
    @testset "$(nameof(T))" begin
      @test _lower_owned_by(T, PormG)
    end
  end
end

if HAS_CONFIG_LOWER
  # ───────────────────────────────────────────────────────────────────────────
  # Exact documents. `Settings` is the one marker in the file with a body rather than a name — the
  # issue asked for the non-secret fields — so the assertion pins WHICH fields, and equally which
  # are absent.
  # ───────────────────────────────────────────────────────────────────────────
  @testset "each credential type lowers to its marker document" begin
    for (label, (value, expected)) in CONFIG_CASES
      @testset "$label" begin
        # Parsed equality rather than string equality for the multi-key `Settings` document: Julia
        # 1.13 changed string hashing (#544) and CI runs 1.12 and 1.13, so an exact multi-key
        # string is a cross-version flake. The single-key markers are compared as strings.
        if label == "Settings"
          @test J641.parse(J641.json(value)) == J641.parse(expected)
        else
          @test J641.json(value) == expected
        end
      end
    end
  end

  # ───────────────────────────────────────────────────────────────────────────
  # THE ASSERTION THIS ISSUE EXISTS FOR. Per token, absence only, on values we invented.
  #
  # `Dict("held" => …)` and the vector are not padding: a pool is met nested inside something a
  # handler is serializing far more often than on its own, and the whole point of putting the
  # method on the ABSTRACT type is that every container holding one is bounded by it.
  # ───────────────────────────────────────────────────────────────────────────
  @testset "no credential survives serialization" begin
    settings = _settings649()
    # `PormG.config` is a `Dict{String,PormGSettings}`; JSON's own `lower(::AbstractDict)` walks it
    # to our method, so the real global needs no separate arm — asserted here with a stand-in of
    # the same type rather than by mutating the process-wide config.
    config_like = Dict{String, PormG.PormGSettings}("j649" => settings)

    holders = Pair{String, Any}[
      "pool"                => _pg_pool(),
      "pool in a Dict"      => Dict("held" => _pg_pool()),
      "pool in a Vector"    => [_pg_pool(), _sl_pool()],
      "Settings"            => settings,
      "Settings in a Dict"  => Dict("held" => settings),
      "config-shaped Dict"  => config_like,
    ]

    for (label, value) in holders
      @testset "$label" begin
        doc = J641.json(value)
        # The credentials themselves, and then the slot names that only appear if reflection ran.
        for token in (FAKE_DSN_PW, FAKE_DSN_USER, FAKE_YAML_PW,
                      "connection_string", "db_config_settings",
                      "password", "available", "pool_size", "localhost", "postgres://")
          @test !occursin(token, doc)
        end
      end
    end
  end

  # ───────────────────────────────────────────────────────────────────────────
  # The leaf invariant, extended to this family. Same argument as the model-graph block: the marker
  # shape is what removes the EDGE, and a `Settings` returns a nested Dict, so "leaves only" is a
  # live claim here rather than a trivially satisfied one.
  # ───────────────────────────────────────────────────────────────────────────
  @testset "no lowered credential value holds a PormG type" begin
    _is_pormg2(x) = (m = parentmodule(typeof(x)); m === PormG || parentmodule(m) === PormG)

    function leaves_only2(x, depth = 0)
      depth > 6 && return false
      x === nothing && return true
      x isa Union{AbstractString, Number, Bool, Symbol} && return true
      x isa AbstractDict && return all(p -> leaves_only2(last(p), depth + 1), collect(x))
      x isa AbstractVector && return all(v -> leaves_only2(v, depth + 1), x)
      return !_is_pormg2(x)
    end

    for (label, (value, _)) in CONFIG_CASES
      @testset "$label" begin
        @test leaves_only2(SU641.lower(STYLE641, value))
      end
    end
  end

  # ───────────────────────────────────────────────────────────────────────────
  # Lowering a `Settings` must not reach the pool for anything — no connection checkout, no driver.
  # A pool whose slots were never filled is the ordinary case; one holding a value that raises on
  # access is the case that proves nothing walked into it.
  # ───────────────────────────────────────────────────────────────────────────
  @testset "lowering a Settings never walks into the pool" begin
    pool = _pg_pool()
    # A slot holding a value whose own serialization would throw. If anything below reflected into
    # `connections`, this would surface as an error rather than a marker.
    setfield!(pool, :connections, Any[ErrorException("must not be serialized"), nothing])
    st = PormG.Configuration.Settings(connections = pool, db_def_folder = "j649_folder")

    @test J641.json(pool) == "{\"pormg_connection\":\"PostgreSQL\"}"
    doc = J641.json(st)
    @test !occursin("must not be serialized", doc)
    @test !occursin(FAKE_DSN_PW, doc)
  end
end

# ═════════════════════════════════════════════════════════════════════════════
# Coverage swept from `methods`, not from either list above — and it runs LAST, because it must see
# both. `test_repl_display.jl` records the outcome this prevents: a `Base.delete_method` sweep there
# found 8 of 15 methods with no assertion behind them at all. A hand-maintained case list cannot
# notice the method it forgot, which is precisely how #649's two methods could have arrived with
# exact-document tests and no credential test.
# ═════════════════════════════════════════════════════════════════════════════
@testset "every lower method PormG defines is exercised" begin
  ours = [m for m in methods(SU641.lower) if m.module === PormG]
  @test !isempty(ours)

  covered = Set{Any}(typeof(value) for (_, (value, _)) in vcat(GRAPH_CASES, CONFIG_CASES))
  for m in ours
    T = m.sig.parameters[3]
    # `any(<:)` rather than set membership, so the abstract `PormGField`, `PormGBackend` and
    # `PormGSettings` methods are satisfied by a concrete specimen rather than demanding a value of
    # the abstract type itself.
    @testset "$(T)" begin
      @test any(C -> C <: T, covered)
    end
  end
end
