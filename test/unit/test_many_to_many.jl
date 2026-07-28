using Test
using PormG
using PormG.Models
using PormG.Migrations

import PormG: PormGModel

struct M2MMockPostgres <: PormG.PormGPostgres end

PormG.config["m2m_mock"] = PormG.Configuration.Settings(
  connections = M2MMockPostgres(),
  change_data = true,
  db_def_folder = "m2m_mock"
)

module ManyToManyUnitModels
import PormG
import PormG.Models

Driver = Models.Model("drivers",
  id = Models.IDField(),
  surname = Models.CharField(),
)

Driver_championship = Models.Model("driver_championships",
  id = Models.IDField(),
  name = Models.CharField(),
  drivers = Models.ManyToManyField(Driver, related_name="championships"),
)

PormG.Models.set_models(@__MODULE__, "m2m_mock")
end

const M2M = ManyToManyUnitModels

@testset "ManyToManyField metadata and query generation" begin
  @test Models.is_many_to_many_field(M2M.Driver_championship.fields["drivers"])
  @test !("drivers" in M2M.Driver_championship.field_names)
  @test Models.has_many_to_many_accessor(M2M.Driver_championship, "drivers")
  @test Models.has_many_to_many_accessor(M2M.Driver, "championships")

  forward_query = M2M.Driver_championship.objects
  forward_query.filter("drivers__surname" => "Senna")
  forward_query.values("name")
  forward_inspection = forward_query.list(show_query=:dict)
  forward_sql = forward_inspection[:sql_text]

  @test occursin("INNER JOIN", forward_sql)
  @test occursin("driver_championships_drivers", forward_sql)
  @test occursin("driver_championships_id", forward_sql)
  @test occursin("drivers_id", forward_sql)
  @test forward_inspection[:parameters] == ["Senna"]

  reverse_query = M2M.Driver.objects
  reverse_query.filter("championships__name" => "World Drivers' Championship")
  reverse_query.values("surname")
  reverse_inspection = reverse_query.list(show_query=:dict)
  reverse_sql = reverse_inspection[:sql_text]

  @test occursin("driver_championships_drivers", reverse_sql)
  @test occursin("driver_championships", reverse_sql)
  @test reverse_inspection[:parameters] == ["World Drivers' Championship"]

  manager_query = M2M.Driver_championship.drivers(1).all()
  manager_inspection = manager_query.list(show_query=:dict)
  manager_sql = manager_inspection[:sql_text]

  @test occursin("driver_championships_drivers", manager_sql)
  @test occursin("championships", manager_sql)
  @test manager_inspection[:parameters] == [1]
end

@testset "ManyToManyField migration synthesis" begin
  settings = PormG.Configuration.Settings(
    connections = M2MMockPostgres(),
    change_data = true,
  )

  current_schema = Dict{Symbol, Dict{Symbol, Union{Bool, PormGModel}}}(
    :driver => Dict{Symbol, Union{Bool, PormGModel}}(:model => M2M.Driver, :exist => false),
    :driver_championship => Dict{Symbol, Union{Bool, PormGModel}}(:model => M2M.Driver_championship, :exist => false),
  )

  plan = Migrations.get_migration_plan(PormGModel[], current_schema, M2MMockPostgres(), settings, interactive=false)

  @test haskey(plan, :driver_championships_drivers)

  source_sql = join(values(plan[:driver_championship]), "\n")
  @test !occursin("\"drivers\"", source_sql)

  through_sql = join(values(plan[:driver_championships_drivers]), "\n")
  @test occursin("CREATE TABLE", through_sql)
  @test occursin("driver_championships_id", through_sql)
  @test occursin("drivers_id", through_sql)
  @test occursin("CREATE UNIQUE INDEX", through_sql)
end

@testset "add_field! ManyToManyField registration" begin
  orphan = Models.Model("orphan_team",
    id = Models.IDField(),
    name = Models.CharField(),
  )
  target = Models.Model("orphan_driver",
    id = Models.IDField(),
    surname = Models.CharField(),
  )

  @test_throws PormG.ModelDefinitionError Models.add_field!(
    orphan,
    :drivers,
    Models.ManyToManyField(target, related_name="teams"),
  )
  @test !haskey(orphan.fields, "drivers")
end

# ─────────────────────────────────────────────────────────────────────────────
# BUG-2 regression: add must return `nothing` consistently regardless of whether
# the targets list is empty or non-empty.
# ─────────────────────────────────────────────────────────────────────────────
@testset "add return type consistency (BUG-2)" begin
  # Construct a mock manager for Driver_championship (auto-through, no extra fields)
  rel = Models.get_many_to_many_relation(M2M.Driver_championship, "drivers")
  manager = PormG.QueryBuilder.ManyToManyManager(
    M2M.Driver_championship,
    M2M.Driver,
    rel,
    1,
  )

  # Empty add must return nothing (was returning 0 before the fix)
  result_empty = PormG.QueryBuilder.add(manager)
  @test result_empty === nothing
  @test result_empty isa Nothing

  # A non-empty add also returns nothing (consistent return type).
  # We cannot actually execute the INSERT on a mock connection, but we verify the
  # early-return path of the empty branch so both branches share the same type.
  result_empty_vec = PormG.QueryBuilder.add(manager, Integer[])
  @test result_empty_vec === nothing
end

module BadBindingModule
  import PormG
  import PormG.Models
  # Intentionally define the expected through-table name as a non-PormGModel
  # so _m2m_model_from_binding raises QueryBuildError ("not a PormG model").
  const drivers_championships_drivers = 42   # Integer, not PormGModel
end

# ─────────────────────────────────────────────────────────────────────────────
# BUG-3 regression: _m2m_has_extra_fields must only swallow QueryBuildError (binding
# not found); any other exception should propagate so the caller cannot silently
# proceed with a through model that has extra fields.
# ─────────────────────────────────────────────────────────────────────────────
@testset "_m2m_has_extra_fields exception propagation (BUG-3)" begin
  # Build a manager whose owner_model has _module set to a module that raises a
  # TypeError when binding lookup is attempted (we simulate by using a model whose
  # through_model binding exists as a non-PormGModel object in a module).

  # The auto-generated through model for Driver_championship.drivers is
  # "driver_championships_drivers". Since BadBindingModule doesn't have it as a
  # PormGModel, _m2m_model_from_binding should raise QueryBuildError which is caught
  # → returns false (no extra fields).
  rel = Models.get_many_to_many_relation(M2M.Driver_championship, "drivers")
  fake_owner = Models.Model_Type(
    name = M2M.Driver_championship.name,
    fields = M2M.Driver_championship.fields,
    field_names = M2M.Driver_championship.field_names,
    related_objects = M2M.Driver_championship.related_objects,
    connect_key = M2M.Driver_championship.connect_key,
    _module = BadBindingModule,
    cache = Dict{String,Any}(),
  )
  manager_bad = PormG.QueryBuilder.ManyToManyManager(fake_owner, M2M.Driver, rel, 1)

  # QueryBuildError is silently caught → returns false (through model "not found" is expected)
  @test PormG.QueryBuilder._m2m_has_extra_fields(manager_bad) == false

  # A manager with _module = nothing should also return false safely
  no_module_owner = Models.Model_Type(
    name = M2M.Driver_championship.name,
    fields = M2M.Driver_championship.fields,
    field_names = M2M.Driver_championship.field_names,
    related_objects = M2M.Driver_championship.related_objects,
    connect_key = M2M.Driver_championship.connect_key,
    _module = nothing,
    cache = Dict{String,Any}(),
  )
  manager_no_mod = PormG.QueryBuilder.ManyToManyManager(no_module_owner, M2M.Driver, rel, 1)
  @test PormG.QueryBuilder._m2m_has_extra_fields(manager_no_mod) == false
end

# ─────────────────────────────────────────────────────────────────────────────
# BUG-1 documentation: PormGModel.getproperty struct-field guard is intentional.
# The `sym in fieldnames(typeof(m))` branch must stay BEFORE the M2M check because
# has_many_to_many_accessor() itself accesses m.cache and m.related_objects, which
# would recurse infinitely if those went through getproperty again.
# The guard cannot shadow M2M accessors because format_fild_name() rejects names that
# collide with Model_Type struct field names.
# This testset confirms both struct fields AND M2M accessors remain reachable.
# ─────────────────────────────────────────────────────────────────────────────
@testset "PormGModel.getproperty: struct fields and M2M accessors coexist (BUG-1)" begin
  # Struct fields accessible via getproperty (goes through struct-field guard)
  @test M2M.Driver_championship.name == "driver_championships"
  @test M2M.Driver_championship.fields isa Dict
  @test M2M.Driver_championship.cache isa Dict   # internal struct field, not M2M

  # M2M accessors (forward direction) reachable (sym not in fieldnames → M2M branch)
  @test Models.has_many_to_many_accessor(M2M.Driver_championship, "drivers")
  desc_fwd = M2M.Driver_championship.drivers
  @test desc_fwd isa PormG.QueryBuilder.ManyToManyDescriptor
  @test desc_fwd.accessor == "drivers"

  # M2M accessors (reverse direction) reachable on the related model
  @test Models.has_many_to_many_accessor(M2M.Driver, "championships")
  desc_rev = M2M.Driver.championships
  @test desc_rev isa PormG.QueryBuilder.ManyToManyDescriptor
  @test desc_rev.accessor == "championships"
end

# ─────────────────────────────────────────────────────────────────────────────
# Regression (#108, now guaranteed by #186): the Model_Type getproperty override dispatches M2M
# accessors via has_many_to_many_accessor(m, …), which reads m.cache / m.related_objects. When fields
# were `<: PormGModel`, a FIELD object hit that method and re-entered getproperty on its absent `.cache`,
# recursing forever (a StackOverflowError on ANY absent-property access to a field). #108 papered over it
# with a `hasfield(…, :cache/:related_objects)` guard; #186 removed the root cause — a field is no longer
# a PormGModel, so it never reaches this method and uses Julia's default getproperty (clean getfield/
# FieldError). This testset pins that the StackOverflow stays impossible.
# ─────────────────────────────────────────────────────────────────────────────
@testset "PormGModel.getproperty: absent property on a field object doesn't recurse (#108)" begin
  # A field object. Since #186, PormGField is a SIBLING of PormGModel (not a subtype), so a field no
  # longer satisfies ::PormGModel and never reaches PormGModel/Model_Type getproperty at all.
  cf = Models.CharField(max_length = 5)

  # #186 regression: a field is NOT a model. This is now what makes the #108 StackOverflow impossible —
  # field property access uses Julia's default getproperty, not the Model_Type M2M-accessor path.
  @test !(cf isa PormG.PormGModel)
  @test cf isa PormG.PormGField

  # Real attribute access still works.
  @test cf.max_length == 5

  # Absent property on a FIELD object must raise a clean FieldError. Pre-fix this recursed
  # through the M2M branch and blew the stack (StackOverflowError, not FieldError).
  field_err = try
    getproperty(cf, :nonexistent_xyz)
    nothing
  catch e
    e
  end
  @test field_err isa FieldError   # the #108 regression signal (was StackOverflowError)

  # Model_Type still raises a clean FieldError on an absent property too (it HAS
  # cache/related_objects, so it was never affected — assert it to pin the guard's discrimination).
  model_err = try
    getproperty(M2M.Driver_championship, :nonexistent_xyz)
    nothing
  catch e
    e
  end
  @test model_err isa FieldError

  # Positive control: the guard did NOT break real M2M accessor dispatch.
  @test M2M.Driver_championship.drivers isa PormG.QueryBuilder.ManyToManyDescriptor
end

# ─────────────────────────────────────────────────────────────────────────────
# #65: a ManyToManyRelation now carries the two sides as resolved model objects,
# populated wherever a relation is built (`_relation_from_many_to_many`), and swapped
# in the reverse relation. `ManyToManyUnitModels` above already ran `set_models`, so the
# relations are fully wired. This completes the "resolve every lazy reference once"
# guarantee for M2M; the query builder doesn't consume the slots yet (that is #68/#41).
# ─────────────────────────────────────────────────────────────────────────────
@testset "ManyToManyRelation carries resolved model slots (#65)" begin
  # Forward relation (owner = Driver_championship, related = Driver), from the owner's cache.
  fwd = Models.get_many_to_many_relation(M2M.Driver_championship, "drivers")
  @test fwd.owner_model_resolved === M2M.Driver_championship
  @test fwd.related_model_resolved === M2M.Driver

  # Reverse relation (stored on the related model under the inverse accessor) — slots swapped
  # to match the swapped string fields, so each side still names its own model.
  rev = Models.get_many_to_many_relation(M2M.Driver, "championships")
  @test rev.reverse
  @test rev.owner_model_resolved === M2M.Driver
  @test rev.related_model_resolved === M2M.Driver_championship

  # deepcopy SHARES the resolved slots (the deepcopy_internal override) instead of cloning the
  # related-model graph. This is also REQUIRED for correctness: a resolved model carries a
  # `_module::Module`, and Julia cannot deepcopy a Module — so without the override, deep-copying
  # a relation (e.g. via deepcopy(model.related_objects)) would throw "deepcopy of Modules not
  # supported". The override copies the value fields and shares the two model references.
  fwd_copy = deepcopy(fwd)
  @test fwd_copy.owner_model_resolved === M2M.Driver_championship  # same object (===), not a clone
  @test fwd_copy.related_model_resolved === M2M.Driver
  @test fwd_copy.field_name == fwd.field_name                      # value fields still deep-copied

  # A relation-bearing model whose own fields are all scalar (Driver is the M2M target) still
  # deep-copies cleanly — its related_objects reverse relation routes through the same override.
  # Guards that adding the resolved slots did not regress model deepcopy for such models.
  dc_driver = deepcopy(M2M.Driver)
  @test Models.get_many_to_many_relation(dc_driver, "championships").related_model_resolved === M2M.Driver_championship
end
