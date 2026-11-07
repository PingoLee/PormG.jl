"""
The model graph is concretely typed; a model holds PormG's own field types only (#1604).

`ModelType.fields` holds the closed union `Models.AnyField`, `related_objects` the union of the two
relation types, and `name` a `String` — so a field read such as `field.type` has one concrete type, as
a `juliac --trim` binary needs (#1599 round 3, rows 6, 8 and 13). A `PormGField` subtype of the
user's own is refused where a model is built, naming it.

No SQL, no database.

    julia --project=test/integration test/unit/test_closed_field_set.jl
"""

using Test
using PormG
import PormG.Models

struct _ClosedSetLapTime <: PormG.PormGField
  type::String
end

# ─────────────────────────────────────────────────────────────────────────────
# The slot types
# What it tests: `ModelType.name` is `String`, `fields` is `OrderedDict{String, Models.AnyField}`,
#   `related_objects` is `Dict{String, Union{ReverseRelation, ManyToManyRelation}}`; a `SubString`
#   name is stored as a `String`; every PormG field type is in `AnyField`. No SQL.
# Why it matters: these are the slot types the trimmed binary's registration and insert path read.
# ─────────────────────────────────────────────────────────────────────────────
@testset "the model graph's slots are concrete (#1604)" begin
  @test fieldtype(Models.ModelType, :name) === String
  @test fieldtype(Models.ModelType, :fields) === PormG.OrderedCollections.OrderedDict{String, Models.AnyField}
  @test fieldtype(Models.ModelType, :related_objects) ===
        Dict{String, Union{Models.ReverseRelation, Models.ManyToManyRelation}}
  m = Models.Model(SubString("lap_times_x", 1, 9), lapid = Models.IDField())
  @test m.name === "lap_times" && m.name isa String
  for f in (Models.IDField(), Models.CharField(), Models.ForeignKey("Race"), Models.ArrayField(Models.IntegerField()),
            Models.ManyToManyField("Driver"), Models.JSONField(), Models.SearchVectorField())
    @test f isa Models.AnyField
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# A field type of the user's own is refused, naming it
# What it tests: `Model(…; time = <own PormGField>)`, `Model(name, Dict(…))` and `add_field!` each raise
#   `ModelDefinitionError` naming the field (`time`), the model and the type (`_ClosedSetLapTime`). No SQL.
# Why it matters: such a field used to be accepted and fail later, deep in rendering or migration.
# ─────────────────────────────────────────────────────────────────────────────
@testset "a PormGField subtype of one's own is refused where a model is built (#1604)" begin
  own = _ClosedSetLapTime("INTERVAL")
  for build in (() -> Models.Model("lap_x", lapid = Models.IDField(), time = own),
                () -> Models.Model("lap_x", Dict{String, PormG.PormGField}("lapid" => Models.IDField(), "time" => own)),
                () -> Models.add_field!(Models.Model("lap_x", lapid = Models.IDField()), "time", own))
    err = try build(); nothing catch e; e end
    @test err isa PormG.ModelDefinitionError
    @test occursin("time", err.msg) && occursin("lap_x", err.msg) && occursin("_ClosedSetLapTime", err.msg)
  end
end
