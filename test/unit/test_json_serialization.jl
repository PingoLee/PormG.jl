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

J_driver = Models.Model("j_driver",
  id      = Models.IDField(),
  surname = Models.CharField(max_length = 50),
  lap     = Models.DurationField(null = true),
  team    = Models.ForeignKey(J_team, on_delete = "RESTRICT", related_name = "j_drivers"),
  mentor  = Models.ForeignKey("J_driver", on_delete = "SET_NULL", null = true, related_name = "j_mentees"),
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
const HAS_LOWER =
  any(m -> m.module === PormG.QueryBuilder, methods(SU641.lower, Tuple{Any, PormG.PormGRow}))

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
