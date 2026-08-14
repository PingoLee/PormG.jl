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

# ─────────────────────────────────────────────────────────────────────────────
# #363 fixture: explicit `through=` models that declare a `db_table`.
#
# Every model here pins a physical table that differs from its logical name — the shape the Django
# importer produces for an app-labelled project (#345/#346) and the one a hand-written model gets
# from `db_table` (#59). No fixture in this file combined `through=` with `db_table` before, which is
# exactly why #363 survived: the two spellings were always equal, so a slot that confused them read
# as correct.
#
# TWO through models on purpose. `Membership` carries an extra column (`joined_year`) and
# `Enrolment` carries only the two foreign keys, so the mutator guard is tested on both arms rather
# than only on the one that refuses.
# ─────────────────────────────────────────────────────────────────────────────
module ManyToManyDbTableModels
  import PormG
  import PormG.Models

  Team = Models.Model("team", db_table = "racing_team",
    id = Models.IDField(),
    name = Models.CharField(),
  )

  Driver = Models.Model("driver", db_table = "racing_driver",
    id = Models.IDField(),
    surname = Models.CharField(),
    # A string forward reference, the documented form — `Membership` is declared below.
    teams = Models.ManyToManyField(Team, through = "Membership", related_name = "drivers"),
  )

  Membership = Models.Model("membership", db_table = "racing_membership",
    id = Models.IDField(),
    driver = Models.ForeignKey(Driver, on_delete = Models.CASCADE),
    team = Models.ForeignKey(Team, on_delete = Models.CASCADE),
    joined_year = Models.IntegerField(null = true),   # the extra column that locks the mutators
  )

  Squad = Models.Model("squad", db_table = "racing_squad",
    id = Models.IDField(),
    name = Models.CharField(),
  )

  Tester = Models.Model("tester", db_table = "racing_tester",
    id = Models.IDField(),
    surname = Models.CharField(),
    squads = Models.ManyToManyField(Squad, through = "Enrolment", related_name = "testers"),
  )

  Enrolment = Models.Model("enrolment", db_table = "racing_enrolment",
    id = Models.IDField(),
    tester = Models.ForeignKey(Tester, on_delete = Models.CASCADE),
    squad = Models.ForeignKey(Squad, on_delete = Models.CASCADE),
  )

  PormG.Models.set_models(@__MODULE__, "m2m_mock")
end

const M2MDBT = ManyToManyDbTableModels

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

# Detach a registered model from its module, keeping everything else. Severing `_module` cuts EVERY
# module-reflection route at once, which is the hostile input for the guard below.
function _m2m_detach_module(model::PormGModel)
  return Models.Model_Type(
    name = model.name,
    db_table = Models.model_has_db_table(model) ? Models.model_table_name(model) : nothing,
    fields = model.fields,
    field_names = model.field_names,
    related_objects = model.related_objects,
    connect_key = model.connect_key,
    _module = nothing,
    cache = Dict{String, Any}(),
  )
end

# ─────────────────────────────────────────────────────────────────────────────
# The extra-fields mutator guard is STRUCTURAL, not reflective (#363).
#
# `_m2m_has_extra_fields` decides whether `add`/`remove`/`clear`/`set` may write to the through table
# at all. It used to answer by re-resolving the through model out of the owner's module by name and
# reading a `QueryBuildError` as "not registered ⇒ auto-generated ⇒ safe" — fail-OPEN: every way the
# lookup could miss silently unlocked the mutators on a table with columns PormG cannot fill.
#
# This replaces the old BUG-3 testset, whose premise (only swallow `QueryBuildError`) died with the
# try/catch. Worth recording why that testset was weaker than it looked: its `BadBindingModule`
# defined `drivers_championships_drivers`, but the real auto table is `driver_championships_drivers`
# (singular `driver`), so the "binding exists but is not a model" path it claimed to exercise was
# never reached — resolution failed at the name scan instead. It passed for the wrong reason, which
# is the standing hazard of pinning a reflective mechanism rather than the property it should have.
#
# The property, now that the relation carries the through model itself: the answer does not depend on
# module state at all. Every case below runs with `_module = nothing`.
# ─────────────────────────────────────────────────────────────────────────────
@testset "the extra-fields mutator guard is structural, not reflective (#363)" begin
  # ── The money assertion. Explicit `through=` + an extra column + a `db_table`, with no module to
  # reflect through. Pre-#363 this returned `false` on the function's first line and the mutators
  # went through, writing rows with `joined_year` unset.
  rel_extras = Models.get_many_to_many_relation(M2MDBT.Driver, "teams")
  severed_driver = _m2m_detach_module(M2MDBT.Driver)
  mgr_extras = PormG.QueryBuilder.ManyToManyManager(severed_driver, M2MDBT.Team, rel_extras, 1)
  @test PormG.QueryBuilder._m2m_has_extra_fields(mgr_extras) == true

  # All four mutators refuse, and they refuse BEFORE touching the connection: the guard is the first
  # statement in each, ahead of `_m2m_target_ids`/`_m2m_settings`. That ordering is what makes the
  # refusal testable without a database, so it is asserted rather than assumed.
  @test_throws PormG.QueryBuildError PormG.QueryBuilder.add(mgr_extras)
  @test_throws PormG.QueryBuildError PormG.QueryBuilder.remove(mgr_extras)
  @test_throws PormG.QueryBuildError PormG.QueryBuilder.clear(mgr_extras)
  @test_throws PormG.QueryBuildError PormG.QueryBuilder.set(mgr_extras)

  # ── Negative control 1: the guard did not simply become "always true". An explicit `through=` whose
  # model carries ONLY the two foreign keys still permits the mutators, `db_table` and all.
  rel_plain = Models.get_many_to_many_relation(M2MDBT.Tester, "squads")
  mgr_plain = PormG.QueryBuilder.ManyToManyManager(
    _m2m_detach_module(M2MDBT.Tester), M2MDBT.Squad, rel_plain, 1)
  @test PormG.QueryBuilder._m2m_has_extra_fields(mgr_plain) == false

  # ── Negative control 2: the auto-generated join table. `through_model_resolved === nothing` is the
  # signal, and the answer is a fact about how the planner builds that table (`id` + the two FKs),
  # not a lookup that failed.
  rel_auto = Models.get_many_to_many_relation(M2M.Driver_championship, "drivers")
  @test rel_auto.through_model_resolved === nothing
  mgr_auto = PormG.QueryBuilder.ManyToManyManager(
    _m2m_detach_module(M2M.Driver_championship), M2M.Driver, rel_auto, 1)
  @test PormG.QueryBuilder._m2m_has_extra_fields(mgr_auto) == false

  # ── `_m2m_model_from_binding` keeps exactly one caller (the descriptor) and still signals a miss
  # with `QueryBuildError` (#231). It is no longer a SIGNAL anyone branches on — pinned here so the
  # type does not drift now that the guard stopped catching it.
  @test_throws PormG.QueryBuildError PormG.QueryBuilder._m2m_model_from_binding(
    ManyToManyDbTableModels, "NoSuchBinding", "no_such_model")
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

  # #363's `through_model_resolved` is a third resolved slot and rides the same hook — checked here
  # rather than given its own `deepcopy_internal`, which is what #343's comment asks of a new slot.
  through_rel = Models.get_many_to_many_relation(M2MDBT.Driver, "teams")
  @test deepcopy(through_rel).through_model_resolved === M2MDBT.Membership

  # A relation-bearing model whose own fields are all scalar (Driver is the M2M target) still
  # deep-copies cleanly — its related_objects reverse relation routes through the same override.
  # Guards that adding the resolved slots did not regress model deepcopy for such models.
  dc_driver = deepcopy(M2M.Driver)
  @test Models.get_many_to_many_relation(dc_driver, "championships").related_model_resolved === M2M.Driver_championship
end

# ─────────────────────────────────────────────────────────────────────────────
# #345: the derived join COLUMN follows the logical model name, and that name is
# now un-prefixed.
#
# CHARACTERIZATION test, not a regression test for #345: it pins behaviour of
# `_many_to_many_column_name` / `_many_to_many_table_name`, which #345 does not
# modify, so it passes against the pre-#345 tree too. It earns its place because
# #345 changes what `model.name` CONTAINS, which makes this derivation newly
# load-bearing and its output DDL-visible — the assertion that the column follows
# `name` and not `db_table` is the one a future refactor would break. The
# discriminating test for #345's own M2M behaviour is the importer round-trip in
# `test_import_django_models.jl`.
#
# `_many_to_many_table_name` strips `django_prefix` (via `get_model_name`) but
# `_many_to_many_column_name` never did — it reads `model.name` raw. So a model
# named `dash_dim_uf` derived the column `dash_dim_uf_id` while Django's real
# through-table column is `dim_uf_id`: PormG queried a column that did not exist.
# After #345 the importer emits `Model("dim_uf", db_table = "dash_dim_uf")`, and
# the derivation lands on Django's spelling. This pins that the column follows
# `name` (the logical handle) and NOT `db_table` (the physical table).
# ─────────────────────────────────────────────────────────────────────────────
@testset "ManyToMany join columns follow the logical name, not db_table (#345)" begin
  no_prefix = PormG.Configuration.Settings(connections = M2MMockPostgres(), change_data = true)

  # The post-#345 shape: logical name un-prefixed, physical table pinned.
  post = Models.Model("dim_uf", db_table = "dash_dim_uf", id = Models.IDField())
  @test Models._many_to_many_column_name(post, "id") == "dim_uf_id"   # == Django's column

  # The pre-#345 shape, for contrast: prefix fused into the name.
  pre = Models.Model("dash_dim_uf", id = Models.IDField())
  @test Models._many_to_many_column_name(pre, "id") == "dash_dim_uf_id"

  # The derived join TABLE reads the logical name too, so it is unchanged by the move — with the
  # prefix out of `name`, `get_model_name`'s strip is simply a no-op on the same string.
  m2m = Models.ManyToManyField("Dim_uf")
  @test Models._many_to_many_table_name(post, "ufs", m2m, no_prefix) == "dim_uf_ufs"
  prefixed = PormG.Configuration.Settings(connections = M2MMockPostgres(), change_data = true,
                                          django_prefix = "dash")
  @test Models._many_to_many_table_name(post, "ufs", m2m, prefixed) == "dim_uf_ufs"

  # ...which is exactly why the importer pins `db_table` on the field: PormG's derivation is
  # `<logical model>_<field>`, Django's is `<the owning model's table>_<field>` (its `opts.db_table`,
  # which is `<app>_<model>` only by default and follows `Meta.db_table` otherwise), and only a pin
  # reconciles them.
  pinned = Models.ManyToManyField("Dim_uf", db_table = "dash_dimibge_ufs")
  @test Models._many_to_many_table_name(post, "ufs", pinned, prefixed) == "dash_dimibge_ufs"
end

# ─────────────────────────────────────────────────────────────────────────────
# #363: an explicit `through=` model's `db_table` IS the join table.
#
# `ManyToManyRelation` recorded the through model's LOGICAL name and six of its seven readers
# rendered that string as a table — the four manager mutators and both through-side slots of
# `_insert_many_to_many_joins`. So `Model("membership", db_table = "racing_membership")` produced a
# relation addressing `membership`, and every read and every write hit a table that does not exist.
#
# The slot is now `through_table` and is always physical; the model it used to stand in for is
# recorded separately. This is the discriminating test: it asserts the recorded value AND the
# rendered SQL, in both directions, because `_reverse_many_to_many_relation` is its own code path.
# ─────────────────────────────────────────────────────────────────────────────
@testset "explicit through= records the physical table, not the logical name (#363)" begin
  # Precondition — without it every assertion below would pass vacuously on a fixture whose logical
  # and physical spellings happen to agree, which is the condition that hid this bug for so long.
  @test M2MDBT.Membership.name == "membership"
  @test Models.model_table_name(M2MDBT.Membership) == "racing_membership"

  fwd = Models.get_many_to_many_relation(M2MDBT.Driver, "teams")
  @test fwd.through_table == "racing_membership"          # was "membership" — the bug
  @test fwd.through_model_resolved === M2MDBT.Membership

  # The reverse relation is built by a separate function and stores the swapped sides. The through
  # table is NOT a side — one join table serves both directions — so it must be carried unchanged.
  rev = Models.get_many_to_many_relation(M2MDBT.Team, "drivers")
  @test rev.reverse
  @test rev.through_table == "racing_membership"
  @test rev.through_model_resolved === M2MDBT.Membership

  # ── The half only SQL can prove. Note the shape of the negative assertion: a bare
  # `occursin("membership", sql)` is vacuous here because "racing_membership" contains it, and a
  # bare `!occursin("membership", sql)` can never pass. Both spellings must be tested as quoted
  # identifiers, which is how every table reaches the rendered statement.
  fwd_sql = M2MDBT.Driver.objects.filter(
      "teams__name" => "Renault"
    ).values(
      "surname"
    ).list(show_query=:dict)[:sql_text]
  @test occursin("\"racing_membership\"", fwd_sql)
  @test !occursin("\"membership\"", fwd_sql)
  # The two sides join through it, so their physical tables are in the statement too (#59).
  @test occursin("\"racing_driver\"", fwd_sql)
  @test occursin("\"racing_team\"", fwd_sql)

  rev_sql = M2MDBT.Team.objects.filter(
      "drivers__surname" => "Senna"
    ).values(
      "name"
    ).list(show_query=:dict)[:sql_text]
  @test occursin("\"racing_membership\"", rev_sql)
  @test !occursin("\"membership\"", rev_sql)
end

# ─────────────────────────────────────────────────────────────────────────────
# #363 did not disturb the AUTO-derived path.
#
# That path already stored a physical name (`_many_to_many_table_name` returns `field.db_table`
# verbatim when the field pins one), so the fix had to leave it byte-identical. This matters beyond
# tidiness: `synthesize_many_to_many_through_models` builds the join table's name AND its unique
# index from this slot, so a value that shifted by even one character would make `makemigrations`
# propose dropping a live index and creating a differently-named twin.
# ─────────────────────────────────────────────────────────────────────────────
@testset "the auto-derived through table is unchanged by #363" begin
  auto = Models.get_many_to_many_relation(M2M.Driver_championship, "drivers")
  @test auto.through_table == "driver_championships_drivers"
  @test auto.through_model_resolved === nothing          # the "no through model" tag

  # A field-level `db_table` pin still wins on the auto path — it names the synthesized join table,
  # and it must NOT be confused with a through MODEL's `db_table` (#345, and the note in
  # `docs/src/schema_conventions.md`).
  owner = Models.Model("dim_uf", db_table = "dash_dim_uf", id = Models.IDField())
  target = Models.Model("regiao", db_table = "dash_regiao", id = Models.IDField())
  pinned = Models.ManyToManyField(target, db_table = "dash_dimibge_ufs")
  pinned_rel = Models._relation_from_many_to_many(
    owner, "Dim_uf", "ufs", pinned, target, "Regiao",
    PormG.Configuration.Settings(connections = M2MMockPostgres(), change_data = true),
    model_map = Dict{Symbol, Dict{Symbol, Union{Bool, PormGModel}}}(),
  )
  @test pinned_rel.through_table == "dash_dimibge_ufs"
  @test pinned_rel.through_model_resolved === nothing
end

# ─────────────────────────────────────────────────────────────────────────────
# CHARACTERIZATION test, not a #363 regression test — it passes against the pre-#363 tree too, and
# saying so is the point. `synthesize_many_to_many_through_models` skips every relation that declares
# `through=` (`field.through === nothing || continue`), so it never constructs one and never reads
# the slot #363 changed; the planned table name comes from `model_table_name` (#59), which was
# already correct. Nothing here can go red on the bug.
#
# It earns its place as the no-churn pin on the OTHER side of that `continue`. #363 rewrote what
# `_relation_from_many_to_many` returns, and this loop consumes that return value to name both the
# auto join table and its unique index — so this fixes the planner's output for the explicit path
# while that rewrite lands.
#
# What the two `!haskey` assertions guard is narrower than "someone deletes the gate": deleting it
# does not reach them at all. `through_key` would become `Symbol(model_table_name(Membership))` —
# already in `expanded` from the first loop, with no `many_to_many_auto` cache — so
# `synthesize_many_to_many_through_models` throws `ModelDefinitionError` and the testset fails by
# erroring out. The assertions catch the quieter regression: the explicit branch starting to derive
# an auto table name ALONGSIDE the real through model, which plans a phantom table instead of
# throwing.
# ─────────────────────────────────────────────────────────────────────────────
@testset "an explicit through= model is planned as itself, not as a synthesized join table" begin
  settings = PormG.Configuration.Settings(connections = M2MMockPostgres(), change_data = true)

  # Keyed by PHYSICAL table, which is how the planner keys both sides of its diff (#59).
  current_schema = Dict{Symbol, Dict{Symbol, Union{Bool, PormGModel}}}(
    :racing_driver     => Dict{Symbol, Union{Bool, PormGModel}}(:model => M2MDBT.Driver,     :exist => false),
    :racing_team       => Dict{Symbol, Union{Bool, PormGModel}}(:model => M2MDBT.Team,       :exist => false),
    :racing_membership => Dict{Symbol, Union{Bool, PormGModel}}(:model => M2MDBT.Membership, :exist => false),
  )

  plan = Migrations.get_migration_plan(PormGModel[], current_schema, M2MMockPostgres(), settings, interactive=false)

  @test haskey(plan, :racing_membership)
  through_sql = join(values(plan[:racing_membership]), "\n")
  @test occursin("CREATE TABLE", through_sql)
  @test occursin("racing_membership", through_sql)

  # No auto join table was synthesized alongside it: the through model IS the join table.
  @test !haskey(plan, :driver_teams)
  @test !haskey(plan, :racing_driver_teams)

  # And the M2M field still owns no column on the source table.
  source_sql = join(values(plan[:racing_driver]), "\n")
  @test !occursin("\"teams\"", source_sql)
end
