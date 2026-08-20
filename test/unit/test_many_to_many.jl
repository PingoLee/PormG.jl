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

# ─────────────────────────────────────────────────────────────────────────────
# #377 fixture: explicit `through=` models whose FOREIGN KEYS declare a `db_column`.
#
# The column-axis sibling of the block above. `db_table` is pinned here too, on purpose: that is the
# shape a Django import produces for a legacy schema (an app label AND `db_column=` on the FKs), and
# carrying both proves the two axes are independent rather than one accidentally covering the other.
#
# The FIELD names carry Django's `_id` suffix (`driver_id`, not `driver`) because that is exactly
# what `process_class_fields!` emits, and it is the pair that makes the bug visible: the field is
# `driver_id`, the column is `drv`, and every renderer used to reach for the former.
#
# TWO through models again, for the same reason as #363's fixture: `Contract` carries an extra
# column so the mutator guard is exercised on the arm that refuses, `Signing` carries only the two
# foreign keys so it is exercised on the arm that permits — and THAT arm is the one that regresses
# if `_m2m_has_extra_fields` is left reading the column slot.
# ─────────────────────────────────────────────────────────────────────────────
module ManyToManyDbColumnModels
  import PormG
  import PormG.Models

  Marque = Models.Model("marque", db_table = "racing_marque",
    id = Models.IDField(),
    name = Models.CharField(),
  )

  Pilot = Models.Model("pilot", db_table = "racing_pilot",
    id = Models.IDField(),
    surname = Models.CharField(),
    marques = Models.ManyToManyField(Marque, through = "Contract", related_name = "pilots"),
  )

  Contract = Models.Model("contract", db_table = "racing_contract",
    id = Models.IDField(),
    # Field `pilot_id` → column "plt"; field `marque_id` → column "mrq". Deliberately unlike the
    # field names in every character, not merely in case: SQLite compares identifiers
    # case-insensitively, so a case-only difference would address the same column and could not
    # discriminate a fixed tree from a broken one.
    pilot_id = Models.ForeignKey(Pilot, db_column = "plt", on_delete = Models.CASCADE),
    marque_id = Models.ForeignKey(Marque, db_column = "mrq", on_delete = Models.CASCADE),
    signed_year = Models.IntegerField(null = true),   # the extra column that locks the mutators
  )

  Livery = Models.Model("livery", db_table = "racing_livery",
    id = Models.IDField(),
    name = Models.CharField(),
  )

  Scout = Models.Model("scout", db_table = "racing_scout",
    id = Models.IDField(),
    surname = Models.CharField(),
    liveries = Models.ManyToManyField(Livery, through = "Signing", related_name = "scouts"),
  )

  Signing = Models.Model("signing", db_table = "racing_signing",
    id = Models.IDField(),
    scout_id = Models.ForeignKey(Scout, db_column = "sct", on_delete = Models.CASCADE),
    livery_id = Models.ForeignKey(Livery, db_column = "lvr", on_delete = Models.CASCADE),
  )

  PormG.Models.set_models(@__MODULE__, "m2m_mock")
end

const M2MDBC = ManyToManyDbColumnModels

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

  # ── #377: the arm that a column-axis fix breaks if it is done in ONE slot. `Signing` carries only
  # the two foreign keys, so the mutators must stay open — but both of those keys declare a
  # `db_column`, so a guard reading `owner_column`/`related_column` would match neither field name,
  # count both foreign keys as "extra", and lock a relation that Django and PormG both permit.
  # The guard reads `owner_field`/`related_field` for exactly this reason.
  rel_dbcol_plain = Models.get_many_to_many_relation(M2MDBC.Scout, "liveries")
  @test rel_dbcol_plain.owner_field != rel_dbcol_plain.owner_column      # the two axes really differ
  mgr_dbcol_plain = PormG.QueryBuilder.ManyToManyManager(
    _m2m_detach_module(M2MDBC.Scout), M2MDBC.Livery, rel_dbcol_plain, 1)
  @test PormG.QueryBuilder._m2m_has_extra_fields(mgr_dbcol_plain) == false

  # ...and the guard did not become "always false" on the db_column path either: `Contract` adds
  # `signed_year` on top of two renamed foreign keys, and still refuses.
  rel_dbcol_extras = Models.get_many_to_many_relation(M2MDBC.Pilot, "marques")
  mgr_dbcol_extras = PormG.QueryBuilder.ManyToManyManager(
    _m2m_detach_module(M2MDBC.Pilot), M2MDBC.Marque, rel_dbcol_extras, 1)
  @test PormG.QueryBuilder._m2m_has_extra_fields(mgr_dbcol_extras) == true
  @test_throws PormG.QueryBuildError PormG.QueryBuilder.add(mgr_dbcol_extras)

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
# #377: a `through=` model's foreign keys resolve their `db_column` into the join columns.
#
# `_infer_through_field` returns the through model's FIELD name, and the relation rendered that name
# straight into SQL. It equals the physical column exactly when the field declares no `db_column`,
# which is every fixture that existed before this one — so the slot read as correct while a legacy
# schema (or any Django import carrying `db_column=`) joined and wrote against a column that is not
# there. The relation now records both axes; this asserts the recorded pair AND the rendered SQL, in
# both directions, because `_reverse_many_to_many_relation` is its own code path.
# ─────────────────────────────────────────────────────────────────────────────
@testset "explicit through= resolves the FK db_column into the join column (#377)" begin
  # Preconditions. Without them every assertion below passes vacuously on a fixture whose field names
  # and columns agree — the condition that hid this bug behind every earlier `through=` test.
  @test Models.model_column(M2MDBC.Contract, "pilot_id") == "plt"
  @test Models.model_column(M2MDBC.Contract, "marque_id") == "mrq"
  @test haskey(M2MDBC.Contract.fields, "pilot_id")     # the FIELD really is spelled with `_id`
  @test !haskey(M2MDBC.Contract.fields, "plt")         # ...and the column is not a field at all

  fwd = Models.get_many_to_many_relation(M2MDBC.Pilot, "marques")
  @test fwd.owner_column == "plt"          # was "pilot_id" — the bug
  @test fwd.related_column == "mrq"        # was "marque_id"
  # The field axis is kept, not discarded: it is what `_m2m_has_extra_fields` reads, and what
  # `through_model.fields` is keyed on.
  @test fwd.owner_field == "pilot_id"
  @test fwd.related_field == "marque_id"
  # The table axis (#363) is untouched by this — the two overrides are independent.
  @test fwd.through_table == "racing_contract"

  # The reverse relation is built by its own function; BOTH pairs must follow their side across the
  # flip. A fix that swapped only the columns would leave the mutator guard reading the wrong end.
  rev = Models.get_many_to_many_relation(M2MDBC.Marque, "pilots")
  @test rev.reverse
  @test rev.owner_column == "mrq"
  @test rev.related_column == "plt"
  @test rev.owner_field == "marque_id"
  @test rev.related_field == "pilot_id"

  # ── The half only SQL can prove. Both spellings are asserted as QUOTED identifiers: a bare
  # `occursin("plt", sql)` would be satisfied by any substring, and the field name `pilot_id` is not
  # a substring of anything else here, so the negative assertion is the one that fails pre-fix.
  fwd_sql = M2MDBC.Pilot.objects.filter(
      "marques__name" => "Renault"
    ).values(
      "surname"
    ).list(show_query=:dict)[:sql_text]
  @test occursin("\"plt\"", fwd_sql)
  @test occursin("\"mrq\"", fwd_sql)
  @test !occursin("\"pilot_id\"", fwd_sql)
  @test !occursin("\"marque_id\"", fwd_sql)
  # Both join legs really are present, so the assertions above are about the keys and not about a
  # query that silently lost its joins.
  @test occursin("\"racing_contract\"", fwd_sql)
  @test occursin("\"racing_marque\"", fwd_sql)

  rev_sql = M2MDBC.Marque.objects.filter(
      "pilots__surname" => "Senna"
    ).values(
      "name"
    ).list(show_query=:dict)[:sql_text]
  @test occursin("\"plt\"", rev_sql)
  @test occursin("\"mrq\"", rev_sql)
  @test !occursin("\"pilot_id\"", rev_sql)
  @test !occursin("\"marque_id\"", rev_sql)
end

# ─────────────────────────────────────────────────────────────────────────────
# #377: a `source_field` / `target_field` pin is a FIELD name, and resolves like an inferred one.
#
# The pin is the only route to the join columns on a self-relation, where `_infer_through_field`
# refuses to guess (#364) — so leaving it unresolved would have fixed the inferred case and left the
# one case that CANNOT use inference still broken. Django reads `through_fields` the same way:
# `_get_m2m_attr` matches each entry against the through FK's `name`, then returns its `column`.
#
# The second half pins the refusal for a pin that names no field. It used to surface as a bare
# `KeyError` from `through_model.fields[…]`, naming neither model nor field — and it is now the
# likeliest mistake anyone will make here, because pinning the COLUMN name was the documented
# workaround for #377 before this commit removed the need for it.
# ─────────────────────────────────────────────────────────────────────────────
@testset "a source_field/target_field pin is a field name and resolves its db_column (#377)" begin
  settings = PormG.Configuration.Settings(connections = M2MMockPostgres(), change_data = true)

  # Pinned to the FIELD names, on a through model whose FKs both rename their column. Identical
  # output to the inferred path — the pin selects WHICH foreign key, it does not bypass resolution.
  pinned = Models._relation_from_many_to_many(
    M2MDBC.Pilot, "Pilot", "marques",
    Models.ManyToManyField(M2MDBC.Marque, through = M2MDBC.Contract,
                           source_field = "pilot_id", target_field = "marque_id"),
    M2MDBC.Marque, "Marque", settings)
  @test pinned.owner_column == "plt"
  @test pinned.related_column == "mrq"
  @test pinned.owner_field == "pilot_id"
  @test pinned.related_field == "marque_id"

  # A pin naming the COLUMN is refused, and the message says which model, which option, which pin,
  # and what it could have written instead.
  err = @test_throws PormG.ModelDefinitionError Models._relation_from_many_to_many(
    M2MDBC.Pilot, "Pilot", "marques",
    Models.ManyToManyField(M2MDBC.Marque, through = M2MDBC.Contract,
                           source_field = "plt", target_field = "marque_id"),
    M2MDBC.Marque, "Marque", settings)
  @test occursin("source_field", err.value.msg)
  @test occursin("plt", err.value.msg)
  @test occursin("contract", err.value.msg)          # the through model, by name
  # The suggestion is scoped to the end that was pinned: `source_field` stands for the owner side, so
  # only the through model's foreign keys TO that side are offered. Listing `marque_id` here would
  # suggest a key that this option cannot legally take.
  @test occursin("pilot_id", err.value.msg)
  @test !occursin("marque_id", err.value.msg)

  # The target side is guarded too, and reports ITS option rather than the source one.
  err2 = @test_throws PormG.ModelDefinitionError Models._relation_from_many_to_many(
    M2MDBC.Pilot, "Pilot", "marques",
    Models.ManyToManyField(M2MDBC.Marque, through = M2MDBC.Contract,
                           source_field = "pilot_id", target_field = "mrq"),
    M2MDBC.Marque, "Marque", settings)
  @test occursin("target_field", err2.value.msg)
  @test !occursin("source_field", err2.value.msg)

  # A pin naming a real field that is NOT a foreign key. `haskey` alone accepts this, and it then
  # died a line later on `sIntegerField` having no `pk_field` — a raw `FieldError`, not a
  # `PormGError`, naming neither model nor field.
  err3 = @test_throws PormG.ModelDefinitionError Models._relation_from_many_to_many(
    M2MDBC.Pilot, "Pilot", "marques",
    Models.ManyToManyField(M2MDBC.Marque, through = M2MDBC.Contract,
                           source_field = "signed_year", target_field = "marque_id"),
    M2MDBC.Marque, "Marque", settings)
  @test occursin("not a foreign key", err3.value.msg)
  @test occursin("signed_year", err3.value.msg)
  @test occursin("pilot_id", err3.value.msg)         # the key it could have named

  # ── The one that never failed at all: BOTH ends pinned to real foreign keys, but to each other's
  # side. Existence holds for both, so a `haskey`-only guard builds a relation with the join keys
  # swapped — SQL that executes and silently returns the wrong rows. Django refuses it as
  # `fields.E339`; so does PormG now.
  err4 = @test_throws PormG.ModelDefinitionError Models._relation_from_many_to_many(
    M2MDBC.Pilot, "Pilot", "marques",
    Models.ManyToManyField(M2MDBC.Marque, through = M2MDBC.Contract,
                           source_field = "marque_id", target_field = "pilot_id"),
    M2MDBC.Marque, "Marque", settings)
  @test occursin("not a foreign key to pilot", err4.value.msg)

  # ...and the check is per-END, not "is it any foreign key": `pilot_id` is a perfectly good pin for
  # the SOURCE side and is refused only when offered as the target.
  @test Models._relation_from_many_to_many(
    M2MDBC.Pilot, "Pilot", "marques",
    Models.ManyToManyField(M2MDBC.Marque, through = M2MDBC.Contract,
                           source_field = "pilot_id", target_field = "marque_id"),
    M2MDBC.Marque, "Marque", settings).owner_field == "pilot_id"
end

# ─────────────────────────────────────────────────────────────────────────────
# #377: a pin is still honoured when the through model's foreign keys are UNRESOLVED.
#
# The per-end check (`fields.E339`) asks whether the pinned field points at this end's model, and a
# `String` `.to` cannot answer that: it holds the target's Julia BINDING, and case-folding a binding
# back to a model name only works while the binding is `uppercasefirst(model.name)` — the flaw #388
# closed elsewhere. `Driver = Model("drivers", …)` breaks it, and that is this file's own house
# idiom (see `M2M` at the top). Whether a through model's keys are still strings at this point
# depends on where its binding sorts in `set_models`' registration loop, so a strict test here would
# accept or refuse the SAME models file across a rename.
#
# It is also the wrong direction to fail: `_infer_through_field` already refuses this shape, and
# pinning is the documented rescue for exactly that. The pin path is therefore lenient about what it
# cannot verify — while the E338 half, which catches the common slip, still fires.
# ─────────────────────────────────────────────────────────────────────────────
@testset "a pin survives an unresolved through-model foreign key (#377)" begin
  settings = PormG.Configuration.Settings(connections = M2MMockPostgres(), change_data = true)

  # Singular binding, PLURAL model name — so `format_model_name("Driver") != "drivers"` and the
  # string comparison cannot match. This is the precondition; without it the test is vacuous.
  team = Models.Model("teams", id = Models.IDField(), name = Models.CharField())
  driver = Models.Model("drivers", id = Models.IDField(), surname = Models.CharField())
  membership = Models.Model("membership",
    id = Models.IDField(),
    driver = Models.ForeignKey("Driver", on_delete = Models.CASCADE),
    team = Models.ForeignKey("Team", on_delete = Models.CASCADE),
  )
  @test membership.fields["driver"].to isa String        # genuinely unresolved
  @test Models.format_model_name("Driver") != driver.name # ...and unrecoverable by case fold

  pinned = Models._relation_from_many_to_many(
    driver, "Driver", "teams",
    Models.ManyToManyField(team, through = membership, source_field = "driver", target_field = "team"),
    team, "Team", settings)
  @test pinned.owner_field == "driver"
  @test pinned.related_field == "team"
  @test pinned.owner_column == "driver"
  @test pinned.related_column == "team"

  # The leniency is scoped to the UNVERIFIABLE case. With the same models resolved, the per-end check
  # is live again and a pin naming the wrong side is refused — so this is not a blanket opt-out.
  resolved_through = Models.Model("membership_resolved",
    id = Models.IDField(),
    driver = Models.ForeignKey(driver, on_delete = Models.CASCADE),
    team = Models.ForeignKey(team, on_delete = Models.CASCADE),
  )
  @test resolved_through.fields["driver"].to isa PormGModel
  err = @test_throws PormG.ModelDefinitionError Models._relation_from_many_to_many(
    driver, "Driver", "teams",
    Models.ManyToManyField(team, through = resolved_through,
                           source_field = "team", target_field = "team"),
    team, "Team", settings)
  @test occursin("not a foreign key to drivers", err.value.msg)
  # And the suggestion never contradicts the refusal: it lists the key that WOULD have worked rather
  # than claiming there is none. Asserted as the WHOLE clause — a bare `occursin("driver", ...)` is
  # vacuous here, because the owner model is itself named `drivers` and every branch of the message
  # interpolates it, including the "no foreign key at all" branch this is meant to exclude.
  @test occursin("Foreign keys to drivers: driver", err.value.msg)
  @test !occursin("no foreign key to drivers at all", err.value.msg)

  # ── The cost of the leniency, pinned so it is a decision rather than an accident. With `.to`
  # unresolved the per-end check cannot be made, so a SWAPPED pin — the mistake E339 exists to catch
  # — is accepted here. That is the same behavior as before #377 (the pin path never consulted `.to`
  # at all), and refusing instead is exactly what broke a working pin during review. The guard
  # resumes the moment the reference resolves, which the `err` case above proves.
  #
  # Whoever "hardens" this back into a fail-closed check should have to delete this assertion first.
  swapped = Models._relation_from_many_to_many(
    driver, "Driver", "teams",
    Models.ManyToManyField(team, through = membership, source_field = "team", target_field = "driver"),
    team, "Team", settings)
  @test swapped.owner_field == "team"
  @test swapped.related_field == "driver"
end

# ─────────────────────────────────────────────────────────────────────────────
# #377: two DISTINCT through fields that collide on one `db_column` are refused, with the remedy
# that actually applies.
#
# The fail-closed guard on the resolved pair (#364) newly sees this case, because before #377 it
# compared field names and two different fields never collided. Its original message — "set
# source_field and target_field to distinct names" — is the wrong advice here: the NAMES are
# distinct, the columns are not, and no pin can fix a `db_column` clash.
# ─────────────────────────────────────────────────────────────────────────────
@testset "two through fields colliding on one db_column are refused with the right remedy (#377)" begin
  settings = PormG.Configuration.Settings(connections = M2MMockPostgres(), change_data = true)

  marque = Models.Model("collide_marque", id = Models.IDField(), name = Models.CharField())
  pilot = Models.Model("collide_pilot", id = Models.IDField(), surname = Models.CharField())
  clash = Models.Model("collide_contract",
    id = Models.IDField(),
    pilot_id = Models.ForeignKey(pilot, db_column = "shared", on_delete = Models.CASCADE),
    marque_id = Models.ForeignKey(marque, db_column = "shared", on_delete = Models.CASCADE),
  )

  err = @test_throws PormG.ModelDefinitionError Models._relation_from_many_to_many(
    pilot, "Collide_pilot", "marques",
    Models.ManyToManyField(marque, through = clash),
    marque, "Collide_marque", settings)
  @test occursin("shared", err.value.msg)
  @test occursin("both map to that column", err.value.msg)
  @test occursin("db_column", err.value.msg)
  # NOT the pin advice — the two names are already distinct, so re-pinning cannot help.
  @test !occursin("distinct names", err.value.msg)

  # The original remedy is still the one given when the two ends really do name ONE field, which is
  # what the #364 guard was written for.
  same = Models.Model("collide_same", id = Models.IDField(), name = Models.CharField())
  err_same = @test_throws PormG.ModelDefinitionError Models._relation_from_many_to_many(
    same, "Collide_same", "peers",
    Models.ManyToManyField(same, source_field = "peer_id", target_field = "peer_id"),
    same, "Collide_same", settings)
  @test occursin("distinct names", err_same.value.msg)
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

  # #377 left this path byte-identical too, and the two axes COLLAPSE here rather than merely
  # agreeing by luck: `synthesize_many_to_many_through_models` builds the join table from these
  # strings, so the field name IS the column and there is no `db_column` to resolve. That matters for
  # the same reason as the table name above — the unique index is derived from these slots, so a
  # value that shifted would make `makemigrations` propose dropping a live index.
  @test auto.owner_field == auto.owner_column
  @test auto.related_field == auto.related_column
  @test auto.owner_column == "driver_championships_id"
  @test auto.related_column == "drivers_id"

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

# ─────────────────────────────────────────────────────────────────────────────
# #364 fixture: SELF-referential ManyToManyFields.
#
# Both ends of the relation resolve to one model, which is the case where PormG's ordinary
# `<model>_<pk>` derivation produces the SAME string twice. Registered through `set_models` so the
# join-rendering testset below has a real `_module` to resolve bindings against — the derivation
# testsets call `_relation_from_many_to_many` directly and do not need it.
#
# `Teammate` carries the default `id` primary key (the Django-identical case) and `Rival` a `codigo`
# one, so both spellings the fix has to produce are fixtured.
# ─────────────────────────────────────────────────────────────────────────────
module ManyToManySelfModels
import PormG
import PormG.Models

Teammate = Models.Model("teammate",
  id = Models.IDField(),
  driverref = Models.CharField(),
  teammates = Models.ManyToManyField("Teammate", related_name="teammate_of"),
)

Rival = Models.Model("rival",
  codigo = Models.CharField(primary_key=true),
  rivals = Models.ManyToManyField("Rival", related_name="rival_of"),
)

PormG.Models.set_models(@__MODULE__, "m2m_mock")
end

const M2MSELF = ManyToManySelfModels

# ─────────────────────────────────────────────────────────────────────────────
# ManyToManyField (#364): a self-referential relation derives `from_`/`to_`-prefixed join columns.
# Both ends resolve to the same model, so the plain `<model>_<pk>` rule derives one string twice and
# the join table ends up with a single endpoint column. Django prefixes the ends for exactly this
# reason; PormG keeps its own `<model>_<pk>` STEM rather than Django's hardcoded `_id`, so the two
# agree whenever the primary key is `id` and diverge intentionally when it is not.
# ─────────────────────────────────────────────────────────────────────────────
@testset "a self-referential ManyToManyField derives from_/to_ join columns (#364)" begin
  settings = PormG.Configuration.Settings(connections = M2MMockPostgres(), change_data = true)

  # --- The plain `id` case: byte-identical to Django's from_driver_id / to_driver_id -------------
  driver = Models.Model("driver", id = Models.IDField(), surname = Models.CharField())
  field = Models.ManyToManyField("Driver")
  rel = Models._relation_from_many_to_many(driver, "Driver", "teammates", field, driver, "Driver", settings)

  @test rel.owner_column == "from_driver_id"
  @test rel.related_column == "to_driver_id"
  # The property that actually matters, stated directly rather than implied by the two above.
  @test rel.owner_column != rel.related_column
  # The through TABLE name never carried the collision and is untouched by any of this.
  @test rel.through_table == "driver_teammates"

  # --- A non-`id` primary key keeps PormG's stem ------------------------------------------------
  # Django would spell both ends `_id` regardless; PormG addresses the column its own migration
  # planner creates, which follows the pk field name.
  codigo = Models.Model("piloto", codigo = Models.CharField(primary_key=true))
  codigo_rel = Models._relation_from_many_to_many(
    codigo, "Piloto", "parceiros", Models.ManyToManyField("Piloto"), codigo, "Piloto", settings)
  @test codigo_rel.owner_column == "from_piloto_codigo"
  @test codigo_rel.related_column == "to_piloto_codigo"

  # --- Explicit pins still win, on both sides ---------------------------------------------------
  pinned = Models.ManyToManyField("Driver", source_field="left_id", target_field="right_id")
  pinned_rel = Models._relation_from_many_to_many(driver, "Driver", "teammates", pinned, driver, "Driver", settings)
  @test pinned_rel.owner_column == "left_id"
  @test pinned_rel.related_column == "right_id"

  # --- Pinning ONE side leaves the other on the plain derivation ---------------------------------
  # Deliberate, and the reason the branch is gated on "neither pinned" rather than applied per side:
  # `source_field = "mentor_id"` already yields the valid pair mentor_id / driver_id today, and
  # deriving `to_driver_id` for the unpinned half would rewrite a schema that works.
  half = Models.ManyToManyField("Driver", source_field="mentor_id")
  half_rel = Models._relation_from_many_to_many(driver, "Driver", "teammates", half, driver, "Driver", settings)
  @test half_rel.owner_column == "mentor_id"
  @test half_rel.related_column == "driver_id"

  # --- A NON-self relation is completely unaffected ---------------------------------------------
  # The guard against "fixing" this by prefixing every m2m column.
  sponsor = Models.Model("sponsor", id = Models.IDField())
  plain_rel = Models._relation_from_many_to_many(
    driver, "Driver", "sponsors", Models.ManyToManyField(sponsor), sponsor, "Sponsor", settings)
  @test plain_rel.owner_column == "driver_id"
  @test plain_rel.related_column == "sponsor_id"
end

# ─────────────────────────────────────────────────────────────────────────────
# ManyToManyField (#364): the synthesized through table carries THREE columns, not two.
# This is the assertion that catches the real damage. `synthesize_many_to_many_through_models` builds
# the through model from a `Dict{Symbol, Any}` keyed on the two join column names, so when they were
# equal the duplicate key resolved last-wins and the table was planned with `id` plus ONE endpoint —
# silently, with a unique index over the same column twice. Counting the fields is what fails on the
# bug; asserting the two names alone would not, because the Dict collapse happens downstream of them.
# ─────────────────────────────────────────────────────────────────────────────
@testset "a self-referential ManyToManyField synthesizes a three-column through table (#364)" begin
  settings = PormG.Configuration.Settings(connections = M2MMockPostgres(), change_data = true)

  current_schema = Dict{Symbol, Dict{Symbol, Union{Bool, PormGModel}}}(
    :teammate => Dict{Symbol, Union{Bool, PormGModel}}(:model => M2MSELF.Teammate, :exist => false),
  )

  expanded = Models.synthesize_many_to_many_through_models(current_schema, settings)
  @test haskey(expanded, :teammate_teammates)

  through = expanded[:teammate_teammates][:model]
  # `id` + BOTH endpoints. On the bug this was ["id", "teammate_id"] — length 2.
  @test length(through.fields) == 3
  @test sort(collect(keys(through.fields))) == ["from_teammate_id", "id", "to_teammate_id"]

  # The unique index names both columns, so it is a real composite constraint rather than the same
  # column repeated (which capped each row at a single link).
  auto = through.cache["many_to_many_auto"]
  @test auto["owner_column"] == "from_teammate_id"
  @test auto["related_column"] == "to_teammate_id"
  @test auto["unique_index"] == "teammate_teammates_from_teammate_id_to_teammate_id_uniq"

  # And it reaches the emitted DDL, not just the cache.
  plan = Migrations.get_migration_plan(PormGModel[], current_schema, M2MMockPostgres(), settings, interactive=false)
  through_sql = join(values(plan[:teammate_teammates]), "\n")
  @test occursin("CREATE TABLE", through_sql)
  @test occursin("from_teammate_id", through_sql)
  @test occursin("to_teammate_id", through_sql)
  @test occursin("CREATE UNIQUE INDEX", through_sql)
  # The source table gains no column of its own for the relation.
  @test !occursin("\"teammates\"", join(values(plan[:teammate]), "\n"))
end

# ─────────────────────────────────────────────────────────────────────────────
# ManyToManyField (#364): two join columns resolving to one name is refused, not planned.
# The derivation can no longer produce a colliding pair on its own, so what reaches this guard is
# what a user wrote — both sides pinned to one name, or one side pinned to the string the other
# derives. Fail-closed: every downstream consumer (the through model's field Dict, the unique index,
# both join legs, the manager mutators) assumes the two name different columns.
# ─────────────────────────────────────────────────────────────────────────────
@testset "a ManyToManyField whose ends resolve to one column is refused (#364)" begin
  settings = PormG.Configuration.Settings(connections = M2MMockPostgres(), change_data = true)
  driver = Models.Model("driver", id = Models.IDField())

  # Both sides pinned to the same name.
  both = Models.ManyToManyField("Driver", source_field="link_id", target_field="link_id")
  err = @test_throws PormG.ModelDefinitionError Models._relation_from_many_to_many(
    driver, "Driver", "teammates", both, driver, "Driver", settings)
  @test occursin("link_id", err.value.msg)
  @test occursin("source_field", err.value.msg)

  # One side pinned to exactly what the other derives — the residue the "neither pinned" gate leaves.
  # The cause is asserted, not just the type: `ModelDefinitionError` is this file's catch-all (some
  # two dozen throw sites in `Models.jl`), so a future validator firing earlier on the same input
  # would keep a type-only assertion green with THIS guard deleted.
  collide = Models.ManyToManyField("Driver", source_field="driver_id")
  collide_err = @test_throws PormG.ModelDefinitionError Models._relation_from_many_to_many(
    driver, "Driver", "teammates", collide, driver, "Driver", settings)
  @test occursin("cannot carry the same column twice", collide_err.value.msg)

  # The guard sits AFTER the `through` block, so the explicit path is covered too — there
  # `source_field`/`target_field` bypass `_infer_through_field` entirely.
  #
  # A SELF-relation through model, so both ends are legitimately the same model. That is what makes
  # this arm reach the guard at all: since #377 a pin must be a foreign key to the side it stands
  # for, so pinning both ends to one key across DIFFERENT models is caught earlier and more
  # precisely (asserted below). Here both keys point at `driver`, both pins are individually valid,
  # and the collision is the only thing left to catch — a stricter version of what this arm always
  # meant to test.
  rivalry = Models.Model("rivalry",
    id = Models.IDField(),
    challenger = Models.ForeignKey(driver, on_delete=Models.CASCADE),
    defender = Models.ForeignKey(driver, on_delete=Models.CASCADE),
  )
  through_collide = Models.ManyToManyField(driver, through=rivalry,
                                           source_field="challenger", target_field="challenger")
  through_err = @test_throws PormG.ModelDefinitionError Models._relation_from_many_to_many(
    driver, "Driver", "rivals", through_collide, driver, "Driver", settings)
  @test occursin("cannot carry the same column twice", through_err.value.msg)
  # WHICH remedy, not just the shared prefix: one field named twice is the "distinct names" branch,
  # and asserting it here keeps this arm self-contained rather than leaning on the #377 testset.
  @test occursin("distinct names", through_err.value.msg)

  # The shape this arm used to use — one pin naming a foreign key to the OTHER side — is now refused
  # before the guard is reached, by the per-end pin check (#377). Pinned here so the two rules stay
  # distinguishable: a future change that collapsed them would leave the assertion above green while
  # silently widening what the pin check accepts.
  target = Models.Model("team", id = Models.IDField())
  through_model = Models.Model("membership",
    id = Models.IDField(),
    driver = Models.ForeignKey(driver, on_delete=Models.CASCADE),
    team = Models.ForeignKey(target, on_delete=Models.CASCADE),
  )
  wrong_side = Models.ManyToManyField(target, through=through_model,
                                      source_field="driver", target_field="driver")
  wrong_err = @test_throws PormG.ModelDefinitionError Models._relation_from_many_to_many(
    driver, "Driver", "teams", wrong_side, target, "Team", settings)
  @test occursin("not a foreign key to team", wrong_err.value.msg)
  @test !occursin("cannot carry the same column twice", wrong_err.value.msg)
end

# ─────────────────────────────────────────────────────────────────────────────
# ManyToManyField (#364): on a self-relation the reverse accessor may not collide with a field.
# The two accessors for a self-relation land on ONE model but in two different dicts — the forward in
# `model.cache["many_to_many"]`, the reverse in `related_objects` — so the pre-existing duplicate
# `related_name` check cannot see a collision between them. Since every reader resolves the cache (and
# the join builder resolves `fields`) FIRST, an equal name leaves the reverse relation permanently
# shadowed, and the manager then traverses the join table backwards while reporting no error at all.
# Same silent-collapse class as the column bug this issue is about, one dict over.
# ─────────────────────────────────────────────────────────────────────────────
@testset "a self-referential ManyToMany refuses a reverse accessor that shadows a field (#364)" begin
  settings = PormG.Configuration.Settings(connections = M2MMockPostgres(), change_data = true)

  # `related_name` equal to the m2m field's OWN name — the natural spelling for a relation a user
  # thinks of as symmetric, and the one the docs steer toward by recommending `related_name`.
  shadow_module = Module(:M2MShadowSelf)
  Core.eval(shadow_module, :(import PormG; import PormG.Models))
  Core.eval(shadow_module, :(Teammate = Models.Model("teammate_shadow",
    id = Models.IDField(),
    driverref = Models.CharField(),
    teammates = Models.ManyToManyField("Teammate", related_name="teammates"),
  )))
  shadow = Core.eval(shadow_module, :(Teammate))
  err = @test_throws PormG.ModelDefinitionError Models._register_many_to_many_relation!(
    shadow_module, settings, shadow, "teammates", shadow.fields["teammates"])
  @test occursin("self-referential", err.value.msg)
  @test occursin("related_name", err.value.msg)

  # Any OTHER field name shadows it identically, because the join builder resolves a field before a
  # reverse accessor — so the guard checks `model.fields`, not just the m2m field's own name.
  other_module = Module(:M2MShadowOther)
  Core.eval(other_module, :(import PormG; import PormG.Models))
  Core.eval(other_module, :(Teammate = Models.Model("teammate_shadow2",
    id = Models.IDField(),
    driverref = Models.CharField(),
    teammates = Models.ManyToManyField("Teammate", related_name="driverref"),
  )))
  other = Core.eval(other_module, :(Teammate))
  other_err = @test_throws PormG.ModelDefinitionError Models._register_many_to_many_relation!(
    other_module, settings, other, "teammates", other.fields["teammates"])
  # This case covers the WIDENED half of the guard, so it is the one where a masquerading
  # `ModelDefinitionError` from somewhere else would hide the most. Assert the cause.
  @test occursin("collides with a field", other_err.value.msg)

  # A DISTINCT related_name registers both ends, and they stay distinguishable. This is the
  # assertion that keeps the guard from being over-broad.
  @test Models.get_many_to_many_relation(M2MSELF.Teammate, "teammates").reverse == false
  @test M2MSELF.Teammate.related_objects["teammate_of"].reverse == true

  # A NON-self relation is untouched: its two accessors land on DIFFERENT models, so a related_name
  # matching a field on the OWNER is not a collision at all.
  #
  # `chassis` exists on the owner and NOT on the target, deliberately. The reverse accessor is
  # installed on the TARGET, so a name that also exists there would be a genuine shadow — the same
  # failure this guard closes, one model over — and asserting success on it would pin a broken
  # configuration as correct. That cross-model half is pre-existing and out of this issue's scope
  # (the correct general check is `haskey(related_model.fields, …)`, equivalent to the shipped
  # `haskey(model.fields, …)` only under the self gate); this fixture must not bless it either way.
  sponsor = Models.Model("shadow_sponsor", id = Models.IDField(), name = Models.CharField())
  cross_module = Module(:M2MShadowCross)
  Core.eval(cross_module, :(import PormG; import PormG.Models))
  Core.eval(cross_module, :(Sponsor = $sponsor))
  Core.eval(cross_module, :(Racer = Models.Model("shadow_racer",
    id = Models.IDField(),
    chassis = Models.CharField(),
    sponsors = Models.ManyToManyField(Sponsor, related_name="chassis"),
  )))
  racer = Core.eval(cross_module, :(Racer))
  @test !haskey(sponsor.fields, "chassis")   # precondition: not a shadow on the target either
  @test Models._register_many_to_many_relation!(
    cross_module, settings, racer, "sponsors", racer.fields["sponsors"]) === nothing
  # And the reverse accessor it installed is genuinely reachable.
  @test sponsor.related_objects["chassis"] isa Models.ManyToManyRelation
end

# ─────────────────────────────────────────────────────────────────────────────
# ManyToManyField (#364): a self-relation renders a correct self-join in BOTH directions.
# Asserting the two column names differ passes for any two distinct strings — it cannot tell whether
# the join builder puts them on the right legs. This renders the SQL instead: the base table appears
# twice under DIFFERENT aliases with the through table between them, the forward direction leaves on
# `from_` and arrives on `to_`, and the reverse direction swaps exactly those two.
# ─────────────────────────────────────────────────────────────────────────────
@testset "a self-referential ManyToMany renders a correct self-join both ways (#364)" begin
  # --- Forward: the field's own accessor ---------------------------------------------------------
  forward = M2MSELF.Teammate.objects
  forward.filter("teammates__driverref" => "senna")
  forward.values("driverref")
  forward_sql = inspect_query(forward)[:sql_text]

  @test occursin("FROM \"teammate\" as \"Tb\"", forward_sql)
  @test occursin("\"teammate_teammates\" AS \"Tb_1\" ON \"Tb\".\"id\" = \"Tb_1\".\"from_teammate_id\"", forward_sql)
  @test occursin("\"teammate\" AS \"Tb_2\" ON \"Tb_1\".\"to_teammate_id\" = \"Tb_2\".\"id\"", forward_sql)

  # --- Reverse: the related_name accessor, which must mirror the two legs ------------------------
  reverse = M2MSELF.Teammate.objects
  reverse.filter("teammate_of__driverref" => "prost")
  reverse.values("driverref")
  reverse_sql = inspect_query(reverse)[:sql_text]

  @test occursin("\"teammate_teammates\" AS \"Tb_1\" ON \"Tb\".\"id\" = \"Tb_1\".\"to_teammate_id\"", reverse_sql)
  @test occursin("\"teammate\" AS \"Tb_2\" ON \"Tb_1\".\"from_teammate_id\" = \"Tb_2\".\"id\"", reverse_sql)

  # The two directions are genuinely different queries — on the bug both legs referenced one column,
  # so traversing forward and traversing back were indistinguishable.
  @test forward_sql != reverse_sql

  # --- The relation is registered on ONE model, forward and reverse both -------------------------
  fwd_rel = Models.get_many_to_many_relation(M2MSELF.Teammate, "teammates")
  rev_rel = M2MSELF.Teammate.related_objects["teammate_of"]
  @test fwd_rel.owner_column == "from_teammate_id"
  @test fwd_rel.related_column == "to_teammate_id"
  @test rev_rel isa Models.ManyToManyRelation
  @test rev_rel.reverse
  # The reverse relation swaps the two ends; the through table is the same one read backwards.
  @test rev_rel.owner_column == fwd_rel.related_column
  @test rev_rel.related_column == fwd_rel.owner_column
  @test rev_rel.through_table == fwd_rel.through_table

  # --- The non-`id` primary key fixture reaches the same place ----------------------------------
  rival_rel = Models.get_many_to_many_relation(M2MSELF.Rival, "rivals")
  @test rival_rel.owner_column == "from_rival_codigo"
  @test rival_rel.related_column == "to_rival_codigo"
end

# ─────────────────────────────────────────────────────────────────────────────
# ManyToManyField (#364, adjacent): an explicit `through=` on a self-relation still fails LOUDLY.
# Nothing here changed, and pinning it says so. `_infer_through_field` scans the through model for
# foreign keys to the target; on a self-relation both sides find the same TWO, so it refuses rather
# than guessing which end is which. That matches Django, which requires `through_fields` in exactly
# this case, and the message names the escape hatch.
# ─────────────────────────────────────────────────────────────────────────────
@testset "an explicit through= on a self-relation demands explicit source/target fields (#364)" begin
  settings = PormG.Configuration.Settings(connections = M2MMockPostgres(), change_data = true)

  driver = Models.Model("racer", id = Models.IDField(), surname = Models.CharField())
  rivalry = Models.Model("rivalry",
    id = Models.IDField(),
    challenger = Models.ForeignKey(driver, on_delete=Models.CASCADE),
    defender = Models.ForeignKey(driver, on_delete=Models.CASCADE),
  )

  err = @test_throws PormG.ModelDefinitionError Models._relation_from_many_to_many(
    driver, "Racer", "rivals", Models.ManyToManyField(driver, through=rivalry), driver, "Racer", settings)
  @test occursin("multiple foreign keys", err.value.msg)
  @test occursin("source_field", err.value.msg)

  # And pinning both ends resolves it. The pin names the through model's own FK FIELDS; each is then
  # resolved to its physical column (#377), which is a no-op here because neither declares a
  # `db_column` — the `db_column`-carrying case is covered by its own testset above.
  resolved = Models._relation_from_many_to_many(
    driver, "Racer", "rivals",
    Models.ManyToManyField(driver, through=rivalry, source_field="challenger", target_field="defender"),
    driver, "Racer", settings)
  @test resolved.owner_column == "challenger"
  @test resolved.related_column == "defender"
  @test resolved.through_table == "rivalry"
end
