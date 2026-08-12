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

# ─────────────────────────────────────────────────────────────────────────────
# ManyToManyField migration synthesis: `strip_many_to_many_fields` returns a physical-only clone
# Every model in `current_schema` passes through this helper before the planner diffs it
# (`get_migration_plan` → `synthesize_many_to_many_through_models`, first loop), because a
# ManyToManyField owns no column and must never reach CREATE TABLE. So it owes two things: rebuild
# `fields`/`field_names` filtered, and carry the untouched slots onto the clone the planner then
# works from — `name`, `related_objects`, `_module`, `connect_key` and `cache`. The one carried
# slot with a proven downstream reader is `cache`: `_add_unique_constraints`
# (`src/migrations/planner.jl:206`) pulls `cache["unique_constraints"]` off this returned model, so
# dropping the copy silently deletes every user-declared UniqueConstraint from the CREATE TABLE plan
# — a regression `test_unique_constraints.jl` catches and this file's assertions below also trip.
# It must also leave its input alone: that input is the user's live registered model, which the
# session treats as immutable shared schema state (`deepcopy` SHARES it, #157).
# The function had no direct test until #299 removed the dead `verbose_name` slot from its copy list.
# ─────────────────────────────────────────────────────────────────────────────
@testset "strip_many_to_many_fields returns a physical-only clone" begin
  source = M2M.Driver_championship

  # Preconditions — plus one explicit vacuity note. Without these, assertions below would pass
  # vacuously: a "preserved" connect_key proves nothing if both sides are `nothing`.
  @test haskey(source.fields, "drivers")      # there IS a M2M field to drop
  @test source._module !== nothing            # set_models ran, so the carried slots hold real values
  @test source.connect_key !== nothing
  # The relation cache is populated. This key is query-builder state, NOT something the planner
  # reads — planner code touches only "many_to_many_auto", "unique_constraints" and "index".
  @test haskey(source.cache, "many_to_many")
  # This model's `related_objects` is EMPTY: nothing points an FK at `driver_championships`, and a
  # M2M installs its reverse accessor on the *related* model (`src/Models.jl:1733`), i.e. on `Driver`.
  # So any `related_objects` assertion here would pass vacuously — the honest carry-over check for
  # that slot is on the `Driver` side below, and this precondition is what says so out loud.
  @test isempty(source.related_objects)
  names_before = copy(source.field_names)

  stripped = Models.strip_many_to_many_fields(source)

  # ── The M2M field is dropped from `fields` (an `identity` implementation fails right here) ──
  @test !haskey(stripped.fields, "drivers")
  @test haskey(stripped.fields, "id")
  @test haskey(stripped.fields, "name")
  @test length(stripped.fields) == length(source.fields) - 1

  # ── `field_names` holds exactly the physical columns ──
  # It never contained "drivers" to begin with (`Model(...)` excludes M2M at construction), so this
  # pins the invariant, not the drop; the drop itself is exercised on a dirty input further down.
  @test Set(stripped.field_names) == Set(["id", "name"])
  @test all(n -> haskey(stripped.fields, n), stripped.field_names)

  # ── Every remaining slot is carried onto the clone ──
  @test stripped.name == "driver_championships"
  @test stripped._module === source._module
  @test stripped.connect_key === source.connect_key
  # `copy(model.cache)` is shallow, so the inner relation table is the SAME object — which is why the
  # relation still resolves off the stripped model even though the field that declared it is gone.
  # (The through table itself does NOT depend on this: the second loop of
  # `synthesize_many_to_many_through_models` rebuilds it from the ORIGINAL unstripped model and sets
  # `cache["many_to_many_auto"]` on a freshly-built through model. Nor does `_add_unique_constraints`
  # depend on identity — it needs only that the outer Dict was copied at all. Inner-table identity is
  # what the next two assertions pin, and nothing else.)
  @test stripped.cache["many_to_many"] === source.cache["many_to_many"]
  @test Models.get_many_to_many_relation(stripped, "drivers") ===
        Models.get_many_to_many_relation(source, "drivers")

  # ── It is a clone: distinct model, distinct containers ──
  # `related_objects` is deliberately absent here — empty on this model, so `!==` would hold for any
  # freshly-allocated Dict and prove nothing. It is checked on the populated `Driver` side below.
  @test stripped !== source
  @test stripped.fields !== source.fields
  @test stripped.field_names !== source.field_names
  @test stripped.cache !== source.cache      # outer Dict copied; inner tables shared, asserted above

  # ── …and the live input is untouched ──
  @test sort(collect(keys(source.fields))) == ["drivers", "id", "name"]
  @test source.field_names == names_before

  # ── The target side: no M2M field of its own, but the reverse accessor must survive the copy ──
  # `Driver` holds the reverse relation in `related_objects["championships"]` rather than in `cache`,
  # so this is the only place the `related_objects` copy can be checked non-vacuously. Nothing under
  # `src/migrations/` reads `related_objects` today; this pins the clone's fidelity, so a caller that
  # keeps hold of a stripped model still resolves the same reverse accessor as the original.
  driver_stripped = Models.strip_many_to_many_fields(M2M.Driver)
  @test haskey(M2M.Driver.related_objects, "championships")             # precondition
  @test driver_stripped.related_objects !== M2M.Driver.related_objects  # copied container…
  @test driver_stripped.related_objects["championships"] ===
        M2M.Driver.related_objects["championships"]                     # …sharing the relation object
  @test Models.has_many_to_many_accessor(driver_stripped, "championships")
  @test Set(driver_stripped.field_names) == Set(["id", "surname"])      # nothing to drop on this side
  @test driver_stripped._module === M2M.Driver._module

  # ── The `field_names` filter itself, on an input only a hand-built model can produce ──
  # The filter keeps a name by membership in the SURVIVING `fields`, it does not re-test the field
  # type. No production path puts a M2M name into `field_names` (`Model(...)` and `add_field!` both
  # exclude it), so without this synthetic input the filter itself is never exercised: every
  # `field_names` *content* assertion above holds just as well for a function that drops the filter
  # and copies `field_names` verbatim. This is the assertion that catches that.
  dirty = Models.Model_Type(
    name = "dirty_championships",
    fields = copy(source.fields),
    field_names = ["id", "drivers", "name"],
  )
  dirty_stripped = Models.strip_many_to_many_fields(dirty)
  @test dirty_stripped.field_names == ["id", "name"]    # dropped in place, surrounding order kept
  @test !haskey(dirty_stripped.fields, "drivers")
  @test dirty.field_names == ["id", "drivers", "name"]  # the input is still untouched
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
# `_find_model_binding_name`'s `uppercasefirst` fallback is load-bearing (#343).
#
# The fallback looks like dead defensive code — an identity scan that already walked the module,
# followed by a guess. #343 deleted it for a throw on exactly that reading, and the whole 6118-test
# suite stayed green, because nothing exercised the shape that needs it. This is that test.
#
# The shape: a model declared in one module and pulled into the REGISTERING module with `using`.
# `names(mod; all=true, imported=true)` does not list `using`-brought bindings (only explicitly
# `import`ed ones), so the identity scan misses — but `isdefined`/`getfield` do reach them, and
# `_resolve_m2m_side_model` tests `isdefined`. So the binding resolves and the layout works.
#
# Deleting the fallback breaks it QUIETLY: the injected `__init__` in `Utils.jl` and the Revise
# callback both swallow a `set_models` throw, so the symptom is "no models registered at all", not an
# error anyone can read. That is why this is pinned by a test and not only by a comment.
# ─────────────────────────────────────────────────────────────────────────────
# #354: the `usings=true` miss-path in `_find_model_binding_name` and `_collect_models_and_bindings`
# now finds `using`-scoped bindings directly. For `Xxxxx`-style bindings like `Uschampionship`, the
# scan result is identical to the old `uppercasefirst` guess. The mixed-case fixture below
# (`Dim_CNES`) is the case that discriminates — only the scan can spell it correctly.
module UsingScopedSharedModels
  import PormG
  import PormG.Models
  export Uschampionship
  Uschampionship = Models.Model("uschampionship",
    id = Models.IDField(),
    nome = Models.CharField(),
  )
end

module UsingScopedAppModels
  import PormG
  import PormG.Models
  # `using`, NOT `import` — this is the entire point of the fixture.
  using ..UsingScopedSharedModels

  Usdriver = Models.Model("usdriver",
    id = Models.IDField(),
    surname = Models.CharField(),
    championships = Models.ManyToManyField(Uschampionship, related_name = "drivers"),
  )
  PormG.Models.set_models(@__MODULE__, "m2m_mock")
end

module UsingScopedMixedCaseSharedModels
  import PormG
  import PormG.Models
  export Dim_CNES
  Dim_CNES = Models.Model("dim_cnes",
    id = Models.IDField(),
    code = Models.CharField(),
  )
end

module UsingScopedMixedCaseAppModels
  import PormG
  import PormG.Models
  # `using`, NOT `import` — testing mixed-case using-scoped model visibility (#354).
  using ..UsingScopedMixedCaseSharedModels

  UsUser = Models.Model("ususer",
    id = Models.IDField(),
    name = Models.CharField(),
    cnes_units = Models.ManyToManyField(Dim_CNES, related_name = "users"),
  )
  PormG.Models.set_models(@__MODULE__, "m2m_mock")
end

@testset "using-scoped M2M target resolved via usings=true scan (#343/#354)" begin
  # Preconditions: `using`-scoped names are invisible to `imported=true` but reachable via
  # the `usings=true` miss-path added in #354.
  @test !(:Uschampionship in names(UsingScopedAppModels; all=true, imported=true))
  @test isdefined(UsingScopedAppModels, :Uschampionship)

  # The binding is found by the `usings=true` scan (not the `uppercasefirst` fallback).
  # Before #354 this was a guess; now it is an exact match. The string is identical either way
  # for `Xxxxx`-style bindings, but the code path is different.
  rel = Models.get_many_to_many_relation(UsingScopedAppModels.Usdriver, "championships")
  @test rel.related_binding == "Uschampionship"

  # The binding resolves via `isdefined`, which sees `using`-scoped names.
  @test isdefined(UsingScopedAppModels, Symbol(rel.related_binding))
  @test PormG.QueryBuilder._resolve_m2m_side_model(
      UsingScopedAppModels, rel.related_binding, "uschampionship", "championships"
    ) === UsingScopedSharedModels.Uschampionship
end

@testset "using-scoped model with mixed-case binding is fully registered (#354)" begin
  # Preconditions: Dim_CNES is brought in via using, so it is invisible to `imported=true`
  @test !(:Dim_CNES in names(UsingScopedMixedCaseAppModels; all=true, imported=true))
  @test isdefined(UsingScopedMixedCaseAppModels, :Dim_CNES)

  # get_all_models includes the using-scoped model
  all_models = Models.get_all_models(UsingScopedMixedCaseAppModels)
  @test UsingScopedMixedCaseSharedModels.Dim_CNES in all_models

  # Registration set _module and connect_key on the using-scoped model
  @test UsingScopedMixedCaseSharedModels.Dim_CNES._module === UsingScopedMixedCaseAppModels
  @test UsingScopedMixedCaseSharedModels.Dim_CNES.connect_key == "m2m_mock"

  # M2M relation correctly recorded the exact binding, NOT the lossy "Dim_cnes" guess
  rel = Models.get_many_to_many_relation(UsingScopedMixedCaseAppModels.UsUser, "cnes_units")
  @test rel.related_binding == "Dim_CNES"

  # The exact binding resolves cleanly in _resolve_m2m_side_model
  @test PormG.QueryBuilder._resolve_m2m_side_model(
      UsingScopedMixedCaseAppModels, rel.related_binding, "dim_cnes", "cnes_units"
    ) === UsingScopedMixedCaseSharedModels.Dim_CNES
end

@testset "_find_model_binding_name uppercasefirst fallback when both scans miss" begin
  # The fallback is the last resort when a model object is not bound by name in the module.
  # Construct a model that is not assigned to any binding in any module.
  unbound_model = Models.Model("orphan_test",
    id = Models.IDField(),
  )
  # Neither scan can find it — the fallback produces uppercasefirst("orphan_test") = "Orphan_test".
  @test PormG.Models._find_model_binding_name(UsingScopedAppModels, unbound_model) == "Orphan_test"
end

# ─────────────────────────────────────────────────────────────────────────────
# BUG-1 documentation: PormGModel.getproperty struct-field guard is intentional.
# The `sym in fieldnames(typeof(m))` branch must stay BEFORE the M2M check because
# has_many_to_many_accessor() itself accesses m.cache and m.related_objects, which
# would recurse infinitely if those went through getproperty again.
# The `fieldnames` branch is itself why an M2M accessor cannot shadow a struct field —
# a struct field always wins there, whatever the accessor is called. (This used to be
# attributed to format_fild_name rejecting such names; that was never the mechanism, and
# since #317 that function rewrites nothing.)
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

  # deepcopy SHARES the resolved slots instead of cloning the related-model graph, and this is
  # REQUIRED for correctness: a resolved model carries a `_module::Module`, and Julia cannot deepcopy
  # a Module — so without sharing, deep-copying a relation (e.g. via deepcopy(model.related_objects))
  # would throw "deepcopy of Modules not supported".
  #
  # The sharing comes from the `Model_Type` deepcopy hook (#157), NOT from a hook on this struct.
  # #65 shipped a hand-written `deepcopy_internal(::ManyToManyRelation, …)`; #157 later made it
  # redundant (a relation is immutable, so Base rebuilds one whose every field is `===` the
  # original's once the model slots share), and #343 removed it. These assertions are unchanged and
  # still hold — they now pin the DEFAULT behavior, which is the point.
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
