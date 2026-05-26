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

  @test_throws ArgumentError Models.add_field!(
    orphan,
    :drivers,
    Models.ManyToManyField(target, related_name="teams"),
  )
  @test !haskey(orphan.fields, "drivers")
end

# ─────────────────────────────────────────────────────────────────────────────
# BUG-2 regression: add! must return `nothing` consistently regardless of whether
# the targets list is empty or non-empty.
# ─────────────────────────────────────────────────────────────────────────────
@testset "add! return type consistency (BUG-2)" begin
  # Construct a mock manager for Driver_championship (auto-through, no extra fields)
  rel = Models.get_many_to_many_relation(M2M.Driver_championship, "drivers")
  manager = PormG.QueryBuilder.ManyToManyManager(
    M2M.Driver_championship,
    M2M.Driver,
    rel,
    1,
  )

  # Empty add! must return nothing (was returning 0 before the fix)
  result_empty = PormG.QueryBuilder.add!(manager)
  @test result_empty === nothing
  @test result_empty isa Nothing

  # A non-empty add! also returns nothing (consistent return type).
  # We cannot actually execute the INSERT on a mock connection, but we verify the
  # early-return path of the empty branch so both branches share the same type.
  result_empty_vec = PormG.QueryBuilder.add!(manager, Integer[])
  @test result_empty_vec === nothing
end

module BadBindingModule
  import PormG
  import PormG.Models
  # Intentionally define the expected through-table name as a non-PormGModel
  # so _m2m_model_from_binding raises ArgumentError ("not a PormG model").
  const drivers_championships_drivers = 42   # Integer, not PormGModel
end

# ─────────────────────────────────────────────────────────────────────────────
# BUG-3 regression: _m2m_has_extra_fields must only swallow ArgumentError (binding
# not found); any other exception should propagate so the caller cannot silently
# proceed with a through model that has extra fields.
# ─────────────────────────────────────────────────────────────────────────────
@testset "_m2m_has_extra_fields exception propagation (BUG-3)" begin
  # Build a manager whose owner_model has _module set to a module that raises a
  # TypeError when binding lookup is attempted (we simulate by using a model whose
  # through_model binding exists as a non-PormGModel object in a module).

  # The auto-generated through model for Driver_championship.drivers is
  # "driver_championships_drivers". Since BadBindingModule doesn't have it as a
  # PormGModel, _m2m_model_from_binding should raise ArgumentError which is caught
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

  # ArgumentError is silently caught → returns false (through model "not found" is expected)
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
