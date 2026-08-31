using Test
using Logging
using PormG
using PormG.Models

import PormG: PormGModel

# ═════════════════════════════════════════════════════════════════════════════
# #396 — the reverse-accessor namespace: derivation, determinism, and its guards
#
# UNIT, not integration, on purpose. Every defect #396 closes is a registration-time one — which key
# a relation installs on its target, and whether a collision is detected — and none of it involves a
# database round trip. The render assertions below use `inspect_query`, which returns the SQL text
# before any connection is used, so they belong here too.
#
# What was wrong. `set_models` walked `pairs(model.fields)` and accumulated a per-target counter as
# it went, so in a group of N relations to one target the field VISITED FIRST kept the bare model
# name and the rest were suffixed `<model>_<field>`. `Model_Type.fields` is an unordered `Dict`, so
# which one that was is hash order — and adding an unrelated field to the model rehashed it.
# ManyToManyField never entered the counter at all, so a self-ForeignKey and a self-ManyToManyField
# on one model both derived the bare model name; whichever registered first won, and the other
# either threw or (m2m-first) silently replaced the `ManyToManyRelation` with a `ReverseRelation`.
# ═════════════════════════════════════════════════════════════════════════════

struct RanMockPostgres <: PormG.PormGPostgres end

PormG.config["ran_mock"] = PormG.Configuration.Settings(
  connections = RanMockPostgres(),
  change_data = true,
  db_def_folder = "ran_mock"
)

# Build a module, evaluate `decls` into it, and register it. Returns the module. Kept as a helper
# because every collision testset below needs `set_models` to be a CALL it can wrap in
# `@test_throws` — a `module ... end` block would raise while the file is being parsed.
#
# `Base.invokelatest` is load-bearing, not defensive. `Core.eval` defines the model bindings in a
# NEWER world age than the one this function is executing in, so a direct call reaches `set_models`
# with a world where `getfield(mod, :Driver)` does not resolve yet — it registers nothing and returns
# quietly, leaving every `related_objects` empty. This is the same world-age seam `@import_models`
# handles and the reason for the Julia 1.12 floor (#211). Every later call that has to see these
# bindings (`set_models` re-runs, `add_field!`) needs the same treatment.
function _ran_module(name::Symbol, decls::Expr; register::Bool = true)
  mod = Module(name)
  Core.eval(mod, :(import PormG; import PormG.Models))
  Core.eval(mod, decls)
  register && Base.invokelatest(Models.set_models, mod, "ran_mock")
  return mod
end

# ─────────────────────────────────────────────────────────────────────────────
# 1. Symmetry — in a group of N, NO relation keeps the bare model name.
#
# The pre-#396 behaviour was for ONE of these two to answer to the bare `ran_incident`, and which
# one was hash order over the field names. Asserting the bare key is ABSENT is the load-bearing half:
# a test that only checked the two suffixed keys existed passed before and after.
# ─────────────────────────────────────────────────────────────────────────────
@testset "a multi-FK group is symmetric — no relation keeps the bare model name (#396)" begin
  SYM = _ran_module(:RanSymModels, quote
    Driver = Models.Model("ran_driver",
      id = Models.IDField(),
      surname = Models.CharField(),
    )
    Incident = Models.Model("ran_incident",
      id = Models.IDField(),
      lap = Models.IntegerField(),
      causing_driver_id = Models.ForeignKey(Driver, pk_field = "id"),
      affected_driver_id = Models.ForeignKey(Driver, pk_field = "id"),
    )
  end)

  @test Set(keys(SYM.Driver.related_objects)) ==
        Set(["ran_incident_causing_driver_id", "ran_incident_affected_driver_id"])
  @test !haskey(SYM.Driver.related_objects, "ran_incident")

  # Each accessor points at the field it was named after — the suffix is not decoration.
  @test SYM.Driver.related_objects["ran_incident_causing_driver_id"].fk_field === :causing_driver_id
  @test SYM.Driver.related_objects["ran_incident_affected_driver_id"].fk_field === :affected_driver_id

  # `OneToOneField` travels the same branch as `ForeignKey`, in the pre-scan AND in the registration
  # walk. Those two conditions have to name the same set of types: drop `sOneToOneField` from either
  # one and the walk indexes `targets` with a key the pre-scan never wrote.
  O2O = _ran_module(:RanO2OModels, quote
    Driver = Models.Model("rano2o_driver", id = Models.IDField(), surname = Models.CharField())
    Profile = Models.Model("rano2o_profile",
      id = Models.IDField(),
      driverid = Models.OneToOneField(Driver, pk_field = "id"),
      backup_driverid = Models.ForeignKey(Driver, pk_field = "id"),
    )
  end)
  @test Set(keys(O2O.Driver.related_objects)) ==
        Set(["rano2o_profile_driverid", "rano2o_profile_backup_driverid"])
  @test !haskey(O2O.Driver.related_objects, "rano2o_profile")

  # A LONE relation is untouched: it still gets the bare model name. This is the negative control
  # that keeps the fix from suffixing everything, which would be a far larger rename.
  LONE = _ran_module(:RanLoneModels, quote
    Circuit = Models.Model("ran_circuit", id = Models.IDField(), name = Models.CharField())
    Race = Models.Model("ran_race",
      id = Models.IDField(),
      circuitid = Models.ForeignKey(Circuit, pk_field = "id"),
    )
  end)
  @test collect(keys(LONE.Circuit.related_objects)) == ["ran_race"]
  @test !haskey(LONE.Circuit.related_objects, "ran_race_circuitid")
end

# ────────────────────────────────────────────────────────────────────────────
# 2. The accessor is a function of (model, field, group size) and of nothing else.
#
# The old derivation read one more input that is not on that list: where the field fell in the walk
# over `pairs(model.fields)`. `Model_Type.fields` is an unordered `Dict`, so hash order decided which
# relation kept the bare model name, and adding an unrelated field to the model could rehash it and
# silently rename a lookup path.
#
# Testing that through fixtures is harder than it looks. `Dict` iteration is a function of the key
# SET, so two models with the same field names walk identically however they were written, and even
# a model with EXTRA fields usually preserves the relative order of the two foreign keys — a pair of
# fixtures built to "perturb the hash" can easily perturb nothing at all. So this asserts the
# property on the pure function directly, and then over a spread of padding sets to show that none
# of them moves the answer. No single padding has to be proven to reorder anything.
# ────────────────────────────────────────────────────────────────────────────
@testset "a derived accessor depends only on model, field and group size (#396)" begin
  # The pure function, both arms. This is the whole contract; everything else is plumbing.
  @test Models._derived_reverse_accessor(:ranp_incident, "causing_driver_id", 1) == "ranp_incident"
  @test Models._derived_reverse_accessor(:ranp_incident, "causing_driver_id", 2) ==
        "ranp_incident_causing_driver_id"
  @test Models._derived_reverse_accessor(:ranp_incident, "causing_driver_id", 7) ==
        "ranp_incident_causing_driver_id"
  # Injective across a group for free, because field names are unique within a model.
  @test Models._derived_reverse_accessor(:ranp_incident, "causing_driver_id", 2) !=
        Models._derived_reverse_accessor(:ranp_incident, "affected_driver_id", 2)

  paddings = [
    "",
    "lap = Models.IntegerField(),",
    "lap = Models.IntegerField(), weather = Models.CharField(), note = Models.CharField(null = true),",
    "a = Models.CharField(), q2 = Models.CharField(), zzz = Models.IntegerField(null = true),",
  ]
  for (i, pad) in enumerate(paddings)
    src = string(
      "Driver = Models.Model(\"ranp", i, "_driver\", id = Models.IDField(), surname = Models.CharField())\n",
      "Incident = Models.Model(\"ranp", i, "_incident\",\n",
      "  id = Models.IDField(),\n  ", pad, "\n",
      "  causing_driver_id = Models.ForeignKey(Driver, pk_field = \"id\"),\n",
      "  affected_driver_id = Models.ForeignKey(Driver, pk_field = \"id\"),\n)\n")
    mod = _ran_module(Symbol("RanPad", i), Meta.parse(string("begin\n", src, "\nend")))
    # `invokelatest` for the same reason `_ran_module` needs it: the binding was defined in a newer
    # world than this loop body is executing in.
    driver = Base.invokelatest(getproperty, mod, :Driver)
    @test Set(keys(driver.related_objects)) ==
          Set(["ranp$(i)_incident_causing_driver_id", "ranp$(i)_incident_affected_driver_id"])
    @test driver.related_objects["ranp$(i)_incident_causing_driver_id"].fk_field ===
          :causing_driver_id
    @test driver.related_objects["ranp$(i)_incident_affected_driver_id"].fk_field ===
          :affected_driver_id
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# 3. The shape #396 reports: a self-ForeignKey and a self-ManyToManyField, neither named.
#
# This is the canonical Django self-relation pairing (`Driver.mentor` + `Driver.teammates`) and it is
# the exact shape `test/unit/fixtures/django_project/racing/models.py` carries — that fixture only
# escapes the collision because its ForeignKey pins `related_name='mentees'`.
#
# Both relations now count toward the group, so they derive two distinct suffixed accessors and both
# register. The `isa ManyToManyRelation` assertion is the regression: on the bug, an m2m-first walk
# left `related_objects` holding a `ReverseRelation` under that key and the many-to-many reverse end
# was gone with no error.
# ─────────────────────────────────────────────────────────────────────────────
# Hoisted to file scope: testset 4 renders queries against this same registration, and `Module(:X)`
# names the module without binding `X` anywhere a later testset could reach.
const RAN_SELF = _ran_module(:RanSelfModels, quote
  Driver = Models.Model("ran_self_driver",
    id = Models.IDField(),
    surname = Models.CharField(),
    mentor_id = Models.ForeignKey("Driver", null = true, pk_field = "id"),
    teammates = Models.ManyToManyField("Driver"),
  )
end)

@testset "a self-ForeignKey and a self-ManyToManyField no longer collide (#396)" begin
  SELF = RAN_SELF

  @test Set(keys(SELF.Driver.related_objects)) ==
        Set(["ran_self_driver_mentor_id", "ran_self_driver_teammates"])

  fk_rev = SELF.Driver.related_objects["ran_self_driver_mentor_id"]
  m2m_rev = SELF.Driver.related_objects["ran_self_driver_teammates"]
  @test fk_rev isa Models.ReverseRelation
  @test fk_rev.fk_field === :mentor_id
  @test m2m_rev isa Models.ManyToManyRelation   # ← the silent-overwrite regression
  @test m2m_rev.reverse == true

  # The forward accessor is intact and distinct from the reverse one. Readers consult
  # `model.cache["many_to_many"]` before `related_objects`, so an equal name would leave the reverse
  # end permanently shadowed rather than merely missing.
  fwd = Models.get_many_to_many_relation(SELF.Driver, "teammates")
  @test fwd.reverse == false

  # The slot the manager filters on and the key that landed in `related_objects` are the SAME string.
  # `_m2m_query` builds its lookup from `relation.inverse_accessor`; if `set_models` derived one name
  # from the group while `_relation_from_many_to_many` re-derived another, every `.all()` on this
  # manager would traverse the join table backwards and silently answer the opposite question.
  @test fwd.inverse_accessor == "ran_self_driver_teammates"

  # The write-back is gone on the MANY-TO-MANY path too, not only the foreign-key one. Both used to
  # assign the derived name onto `field.related_name`; restoring either would put a PormG-invented
  # accessor back into `Model_to_str`'s output for a regenerated model file.
  @test SELF.Driver.fields["teammates"].related_name === nothing
  @test SELF.Driver.fields["mentor_id"].related_name === nothing
end

# ─────────────────────────────────────────────────────────────────────────────
# 4. Both derived accessors are reachable, and they are different queries.
#
# Asserting two distinct keys exist cannot tell you either one resolves. This renders the SQL.
# ─────────────────────────────────────────────────────────────────────────────
@testset "both derived accessors render a join (#396)" begin
  SELF = RAN_SELF

  via_fk = SELF.Driver.objects
  via_fk.filter("ran_self_driver_mentor_id__surname" => "senna")
  via_fk.values("surname")
  fk_sql = inspect_query(via_fk)[:sql_text]

  via_m2m = SELF.Driver.objects
  via_m2m.filter("ran_self_driver_teammates__surname" => "prost")
  via_m2m.values("surname")
  m2m_sql = inspect_query(via_m2m)[:sql_text]

  # The FK reverse is a single join back onto the same table.
  @test occursin("FROM \"ran_self_driver\" as \"Tb\"", fk_sql)
  @test occursin("\"ran_self_driver\" AS \"Tb_1\" ON \"Tb\".\"id\" = \"Tb_1\".\"mentor_id\"", fk_sql)
  @test !occursin("ran_self_driver_teammates\" AS", fk_sql)   # not routed through the join table

  # The m2m reverse is two legs through the synthesized join table.
  @test occursin("\"ran_self_driver_teammates\" AS \"Tb_1\"", m2m_sql)
  @test occursin("\"ran_self_driver\" AS \"Tb_2\"", m2m_sql)

  @test fk_sql != m2m_sql
end

# ─────────────────────────────────────────────────────────────────────────────
# 5. The previously UNGUARDED branch.
#
# A lone FK with no `related_name` wrote its key with a bare `setindex!` — the one registration path
# of four that did not check first. Here another model's EXPLICIT `related_name` already holds the
# name the derivation lands on, so the old code silently discarded whichever registered second.
# ─────────────────────────────────────────────────────────────────────────────
@testset "a derived accessor cannot silently overwrite an existing one (#396)" begin
  err = @test_throws PormG.ModelDefinitionError _ran_module(:RanTakenModels, quote
    Driver = Models.Model("rant_driver", id = Models.IDField(), surname = Models.CharField())
    # Derives the bare `rant_result` on Driver.
    Result = Models.Model("rant_result",
      id = Models.IDField(),
      driverid = Models.ForeignKey(Driver, pk_field = "id"),
    )
    # ...and claims that same name explicitly.
    Penalty = Models.Model("rant_penalty",
      id = Models.IDField(),
      driverid = Models.ForeignKey(Driver, pk_field = "id", related_name = "rant_result"),
    )
  end)

  msg = err.value.msg
  @test occursin("rant_result", msg)
  # Names BOTH ends. The three pre-#396 messages named the model twice and neither field, which on a
  # self-relation read as "the model collided with itself".
  @test occursin("rant_result.driverid", msg)
  @test occursin("rant_penalty.driverid", msg)
  @test occursin("rant_driver", msg)
  # Whichever of the two registered first, the loser is named as the one that must be given a
  # related_name — so the remedy is actionable regardless of hash order. Matched on the remedy
  # sentence, because a bare `occursin("related_name", ...)` is already satisfied by the origin
  # clause ("declares no related_name") and so cannot tell that the remedy survived at all.
  @test occursin("an explicit", msg)
end

# ─────────────────────────────────────────────────────────────────────────────
# 6. Cross-model field shadowing — the check #364 shipped behind a self-relation gate.
#
# `_build_row_join` resolves a FIELD before a reverse accessor at every hop, so an accessor equal to
# a field name on the model it lands on registers cleanly and is then unreachable — surfacing later
# as a raw internal error about a field with no `how` property, not a definition error.
# ─────────────────────────────────────────────────────────────────────────────
@testset "a reverse accessor that shadows a field on the target is refused (#396)" begin
  err = @test_throws PormG.ModelDefinitionError _ran_module(:RanShadowModels, quote
    Driver = Models.Model("rans_driver",
      id = Models.IDField(),
      surname = Models.CharField(),
      points = Models.IntegerField(),
    )
    Result = Models.Model("rans_result",
      id = Models.IDField(),
      driverid = Models.ForeignKey(Driver, pk_field = "id", related_name = "points"),
    )
  end)

  msg = err.value.msg
  @test occursin("is a FIELD of that model", msg)
  @test occursin("rans_result.driverid", msg)
  @test occursin("rans_driver.points", msg)
  # Not misreported as self-referential — the two ends are on different models.
  @test !occursin("self-referential", msg)
  # The name was the user's, so no "derived" clause.
  @test !occursin("derived", msg)
end

# ─────────────────────────────────────────────────────────────────────────────
# 7. The same shadow reached through a DERIVED name.
#
# The user never wrote `related_name` here, so a message pointing at that option without saying where
# the name came from would send them looking for something that is not in their source.
# ─────────────────────────────────────────────────────────────────────────────
@testset "a shadow via a derived accessor says where the name came from (#396)" begin
  err = @test_throws PormG.ModelDefinitionError _ran_module(:RanShadowDerivedModels, quote
    Driver = Models.Model("rand_driver",
      id = Models.IDField(),
      # A field named after the child model — so the child's DERIVED accessor lands on it.
      rand_result = Models.CharField(),
    )
    Result = Models.Model("rand_result",
      id = Models.IDField(),
      driverid = Models.ForeignKey(Driver, pk_field = "id"),
    )
  end)

  msg = err.value.msg
  @test occursin("is a FIELD of that model", msg)
  @test occursin("declares no related_name", msg)
  @test occursin("rand_result.driverid", msg)
  @test occursin("rand_driver.rand_result", msg)
end

# ─────────────────────────────────────────────────────────────────────────────
# 8. No write-back, and registration is still idempotent.
#
# PormG used to assign the derived name onto `field.related_name`, and THAT is what made a second
# `set_models` run reproduce the first: run two saw an explicit name and took a different branch to
# the same key. The derivation is a pure function of (model name, field name, group size) now, so the
# latch is gone — and with it the reason `Model_to_str` would bake a PormG-invented accessor into a
# regenerated source file, since `related_name === nothing` again means "the declaration named none".
# ─────────────────────────────────────────────────────────────────────────────
@testset "a derived accessor is not written back onto the field (#396)" begin
  IDEM = _ran_module(:RanIdempotentModels, quote
    Driver = Models.Model("rani_driver", id = Models.IDField(), surname = Models.CharField())
    Incident = Models.Model("rani_incident",
      id = Models.IDField(),
      causing_driver_id = Models.ForeignKey(Driver, pk_field = "id"),
      affected_driver_id = Models.ForeignKey(Driver, pk_field = "id"),
    )
    Lap = Models.Model("rani_lap",
      id = Models.IDField(),
      driverid = Models.ForeignKey(Driver, pk_field = "id", related_name = "laps"),
    )
  end)

  # Derived on both arms of the derivation — the group member and the lone relation.
  @test IDEM.Incident.fields["causing_driver_id"].related_name === nothing
  @test IDEM.Incident.fields["affected_driver_id"].related_name === nothing
  # An EXPLICIT one is untouched.
  @test IDEM.Lap.fields["driverid"].related_name == "laps"

  before = Dict(k => v for (k, v) in IDEM.Driver.related_objects)
  Base.invokelatest(Models.set_models, IDEM, "ran_mock")

  @test Set(keys(IDEM.Driver.related_objects)) == Set(keys(before))
  for k in keys(before)
    @test IDEM.Driver.related_objects[k].fk_field === before[k].fk_field
  end
  # Still `nothing` after a second run — the write-back is genuinely gone, not merely unobserved on
  # the first pass.
  @test IDEM.Incident.fields["causing_driver_id"].related_name === nothing
  @test IDEM.Incident.fields["affected_driver_id"].related_name === nothing
end

# ─────────────────────────────────────────────────────────────────────────────
# 9. An explicit `related_name` wins inside a group, and does not disturb its sibling.
# ─────────────────────────────────────────────────────────────────────────────
@testset "an explicit related_name wins inside a group (#396)" begin
  MIX = _ran_module(:RanMixedModels, quote
    Driver = Models.Model("ranm_driver", id = Models.IDField(), surname = Models.CharField())
    Incident = Models.Model("ranm_incident",
      id = Models.IDField(),
      causing_driver_id = Models.ForeignKey(Driver, pk_field = "id", related_name = "caused"),
      affected_driver_id = Models.ForeignKey(Driver, pk_field = "id"),
    )
  end)

  @test Set(keys(MIX.Driver.related_objects)) ==
        Set(["caused", "ranm_incident_affected_driver_id"])
  @test MIX.Driver.related_objects["caused"].fk_field === :causing_driver_id
end

# ─────────────────────────────────────────────────────────────────────────────
# 10. `add_field!` counts what the model holds now, and `set_models` normalizes afterwards.
#
# A runtime addition cannot rename an accessor that is already registered and possibly in use, so the
# group is briefly mixed. That is deliberate: the alternative is mutating other relations' keys out
# from under whatever already resolved them.
# ─────────────────────────────────────────────────────────────────────────────
@testset "add_field! derives against the current group, set_models normalizes it (#396)" begin
  ADD = _ran_module(:RanAddFieldModels, quote
    Driver = Models.Model("rana_driver", id = Models.IDField(), surname = Models.CharField())
    Team = Models.Model("rana_team",
      id = Models.IDField(),
      lead_driver_id = Models.ForeignKey(Driver, pk_field = "id"),
    )
  end)

  # One relation to Driver so far → the bare name.
  @test collect(keys(ADD.Driver.related_objects)) == ["rana_team"]

  Base.invokelatest(Models.add_field!, ADD.Team, "reserves", Models.ManyToManyField("Driver"))

  # The new relation sees a group of two and suffixes itself; the already-registered sibling keeps
  # the name it was published under.
  @test Set(keys(ADD.Driver.related_objects)) == Set(["rana_team", "rana_team_reserves"])
  @test ADD.Driver.related_objects["rana_team_reserves"] isa Models.ManyToManyRelation
  # The manager filters on `inverse_accessor`; it has to be the key that was registered, on this
  # path as much as on the `set_models` one.
  @test Models.get_many_to_many_relation(ADD.Team, "reserves").inverse_accessor == "rana_team_reserves"
  @test ADD.Team.fields["reserves"].related_name === nothing

  # A full re-registration rebuilds `related_objects` from scratch and normalizes the whole group.
  Base.invokelatest(Models.set_models, ADD, "ran_mock")
  @test Set(keys(ADD.Driver.related_objects)) ==
        Set(["rana_team_lead_driver_id", "rana_team_reserves"])
end

# ─────────────────────────────────────────────────────────────────────────────
# 11. The @info announces exactly the derived group members.
#
# It has to fire for a name PormG chose out of a group — that is the only way a user learns the
# accessor without reading the source of `set_models`. It must NOT fire for a lone relation (whose
# bare name is documented and stable) or for an explicit `related_name` (which the user wrote), or it
# becomes noise on every model load and gets filtered out.
# ─────────────────────────────────────────────────────────────────────────────
@testset "the derived-accessor @info fires only for a group member (#396)" begin
  # `collect_test_logs` returns `(logs, value)` — the records are the FIRST element.
  logs, _ = Test.collect_test_logs() do
    _ran_module(:RanLogModels, quote
      Driver = Models.Model("ranl_driver", id = Models.IDField(), surname = Models.CharField())
      Circuit = Models.Model("ranl_circuit", id = Models.IDField(), name = Models.CharField())
      Incident = Models.Model("ranl_incident",
        id = Models.IDField(),
        causing_driver_id = Models.ForeignKey(Driver, pk_field = "id"),
        affected_driver_id = Models.ForeignKey(Driver, pk_field = "id"),
        circuitid = Models.ForeignKey(Circuit, pk_field = "id"),
        stewardid = Models.ForeignKey(Driver, pk_field = "id", related_name = "stewarded"),
      )
    end)
  end

  derived = [r for r in logs if r.level == Logging.Info &&
                                occursin("declares no related_name", string(r.message))]
  msgs = join(string.(getfield.(derived, :message)), "\n")

  # Two derived group members, and only those two.
  @test length(derived) == 2
  @test occursin("ranl_incident_causing_driver_id", msgs)
  @test occursin("ranl_incident_affected_driver_id", msgs)
  # The lone relation to Circuit keeps the bare name silently.
  @test !occursin("ranl_incident_circuitid", msgs)
  # The explicit one is never announced.
  @test !occursin("stewarded", msgs)
  # It names the group size, so the user can tell why the name is not the bare one.
  @test occursin("one of 3 relations", msgs)
end

# ═════════════════════════════════════════════════════════════════════════════
# #420 — a reverse accessor containing `__` (the lookup-path separator)
#
# Every resolver splits a lookup path on `__` BEFORE looking the pieces up, so an accessor whose own
# name contains `__` can register cleanly and then never be addressed: the dict is only ever probed
# with a fragment. The old failure was an `UnknownFieldError` naming a truncated string
# (`the column a not found in …`) that appears nowhere in the user's source, which reads as a
# corrupted model rather than an illegal name.
#
# Same defect class as sections 6 and 7 above — "registers cleanly and is then permanently
# unreachable" is literally the sentence `_reverse_accessor_shadows_field` already used — reached
# through the separator instead of through field precedence.
#
# TWO guards, on purpose, and the tests below cover both arms rather than only the one that fires
# first. The constructor guard (`_validate_related_name`) reports an explicit `related_name` at the
# line the user wrote; the registration funnel (`_reverse_accessor_for`) is the total one, because it
# is the only place a DERIVED accessor exists. Their exception types differ by design and by each
# file's own convention — `FieldValidationError` for a bad constructor argument,
# `ModelDefinitionError` for a model that cannot register — and both are `<: DefinitionError`.
# ═════════════════════════════════════════════════════════════════════════════

# ─────────────────────────────────────────────────────────────────────────────
# 12. An explicit `related_name` is refused at the field constructor, on all three relation types.
#
# All three are covered rather than one plus an assumption: `related_name` reaches its slot by a
# different expression in each constructor, and before #420 not one of them validated its shape while
# all three already routed `pk_field` / `source_field` / `target_field` through `format_fild_name`.
# ─────────────────────────────────────────────────────────────────────────────
@testset "an explicit related_name containing __ is refused at declaration (#420)" begin
  for (label, build) in (
        ("ForeignKey",      () -> Models.ForeignKey("Driver", pk_field = "id", related_name = "a__b")),
        ("OneToOneField",   () -> Models.OneToOneField("Driver", pk_field = "id", related_name = "a__b")),
        ("ManyToManyField", () -> Models.ManyToManyField("Driver", related_name = "a__b")))
    err = @test_throws PormG.FieldValidationError build()
    msg = err.value.msg
    # Names the field type, so a stack of relation declarations points at the right line.
    @test occursin(label, msg)
    # Names the ACCESSOR the user actually wrote — never a fragment such as a bare "a".
    @test occursin("a__b", msg)
    # Says WHY, so the remedy is not a guess — and specifically the SEPARATOR mechanism, not the
    # trailing-underscore one (section 21 covers that, and they must not share a sentence).
    @test occursin("lookup-path separator", msg)
    @test !occursin("traversing an accessor appends", msg)
  end

  # `@` is refused by the same rule and for the same reason: it opens an operator suffix, and an
  # accessor shares one namespace with the target's fields, where `format_fild_name` has refused both
  # characters since #317.
  at_err = @test_throws PormG.FieldValidationError Models.ForeignKey("Driver", pk_field = "id",
                                                                     related_name = "a@b")
  # Assert the CAUSE, not just the type: a constructor has many ways to raise this type, and without
  # this the assertion would pass on an unrelated failure.
  @test occursin("a@b", at_err.value.msg)

  # Control — a clean name is untouched and normalizes to `String` on every route.
  for build in (() -> Models.ForeignKey("Driver", pk_field = "id", related_name = "incidents"),
                () -> Models.OneToOneField("Driver", pk_field = "id", related_name = "incidents"),
                () -> Models.ManyToManyField("Driver", related_name = "incidents"))
    field = build()
    @test field.related_name == "incidents"
    @test field.related_name isa String
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# 13. The registration funnel refuses it too, for a field the constructor never vetted.
#
# The constructor guard is the better error LOCATION, not the complete one. `_reverse_accessor_for` is
# the single point every accessor passes through exactly once, and this test enters behind the
# constructor — the way a mutated field, or one built before the guard existed, arrives — to prove the
# funnel is not dead code shadowed by the eager check.
# ─────────────────────────────────────────────────────────────────────────────
@testset "the registration funnel refuses an explicit __ accessor the constructor never saw (#420)" begin
  err = @test_throws PormG.ModelDefinitionError _ran_module(:RanSepExplicitModels, quote
    Driver = Models.Model("ranse_driver", id = Models.IDField(), surname = Models.CharField())
    Result = Models.Model("ranse_result",
      id = Models.IDField(),
      driverid = Models.ForeignKey(Driver, pk_field = "id"),
    )
    # The struct is mutable, so this is the shape a field that bypassed the constructor arrives in.
    Result.fields["driverid"].related_name = "a__b"
  end)

  msg = err.value.msg
  @test occursin("a__b", msg)
  @test occursin("ranse_result.driverid", msg)
  @test occursin("lookup-path separator", msg)
  # The name was the user's, so no "derived" clause and no invitation to rename the field.
  @test !occursin("derived", msg)
end

# ─────────────────────────────────────────────────────────────────────────────
# 14. A DERIVED accessor inherits `__` from the field name — the route introspection can reach.
#
# `_derived_reverse_accessor` is `<model>_<field>` for a group of two or more, so a legacy column
# literally named `caused__by_id` produces `<model>_caused__by_id`. This is the half nobody can fix by
# choosing a better `related_name` before the fact, because the user never wrote a name at all — so
# the message has to say where the name came from and offer BOTH remedies.
#
# The `Model_Type(; fields = Dict(...))` spelling is deliberate: it is the shape `inspectdb`
# introspection and the Django importer build, and it is the reason this route is reachable without
# anyone hand-writing a `__` field name.
# ─────────────────────────────────────────────────────────────────────────────
@testset "a derived accessor containing __ is refused and names the whole accessor (#420)" begin
  err = @test_throws PormG.ModelDefinitionError _ran_module(:RanSepDerivedModels, quote
    Driver = Models.Model("ransd_driver", id = Models.IDField(), surname = Models.CharField())
    Incident = Models.Model_Type(name = "ransd_incident",
      fields = Dict{String, PormG.PormGField}(
        "id"             => Models.IDField(),
        "lap"            => Models.IntegerField(),
        "caused__by_id"  => Models.ForeignKey("Driver", pk_field = "id"),
        "affected_by_id" => Models.ForeignKey("Driver", pk_field = "id")),
      field_names = ["id", "lap", "caused__by_id", "affected_by_id"])
  end)

  msg = err.value.msg
  # The load-bearing assertion: the WHOLE accessor, not the `ransd_incident_caused` fragment the old
  # UnknownFieldError reported. A test matching only "caused" would have passed before the fix.
  @test occursin("ransd_incident_caused__by_id", msg)
  @test occursin("declares no related_name", msg)
  # The remedy clause, pinned specifically. `occursin("related_name", msg)` would be a tautology here
  # — the assertion above already guarantees that substring — and `occursin("rename the field", msg)`
  # was wrong advice for this route in the first place: the separator is in the FIELD name, so the
  # message must name that rather than tell the user to rename something unspecified.
  @test occursin("The separator comes from the field name", msg)
  # Matched on a run with no ANSI in it. `related_name` is wrapped in \e[1m…\e[0m in this message,
  # so a substring spanning it passes under --color=no and fails under --color=yes (and on CI).
  @test occursin("Rename whichever carries it", msg)
end

# ─────────────────────────────────────────────────────────────────────────────
# 15. CONTROL — an `a__b` COLUMN still loads. This pins the #317 exemption.
#
# #420's own issue text proposed applying `format_fild_name`'s `__` check to the `Model_Type` Dict
# constructor. That is exactly what #317 deliberately removed: an `a__b` column used to abort the
# whole import from inside that loop, before `Model_to_str` could render it (and `Model_to_str` DOES
# handle it — `_julia_field_identifier` renames the field and pins `db_column`). The guard is on the
# ACCESSOR, never on the column, and this testset is what fails if someone later "completes" #420 by
# moving it onto the field name.
#
# Same column as section 14, one relation instead of two — so the derived accessor is the bare model
# name and contains no separator.
# ─────────────────────────────────────────────────────────────────────────────
@testset "a column named a__b still loads when its accessor has no separator (#420, pins #317)" begin
  CTL = _ran_module(:RanSepControlModels, quote
    Driver = Models.Model("ransc_driver", id = Models.IDField(), surname = Models.CharField())
    Incident = Models.Model_Type(name = "ransc_incident",
      fields = Dict{String, PormG.PormGField}(
        "id"            => Models.IDField(),
        "caused__by_id" => Models.ForeignKey("Driver", pk_field = "id")),
      field_names = ["id", "caused__by_id"])
  end)

  # `Base.invokelatest`: the bindings were defined by `Core.eval` in a newer world age than this
  # function body — the same seam `_ran_module` documents for `set_models`.
  driver = Base.invokelatest(getfield, CTL, :Driver)
  incident = Base.invokelatest(getfield, CTL, :Incident)

  # The column survived verbatim — no rename, no strip.
  @test "caused__by_id" in incident.field_names
  @test haskey(incident.fields, "caused__by_id")
  # And the relation registered, under the bare model name.
  @test collect(keys(driver.related_objects)) == ["ransc_incident"]
end

# ─────────────────────────────────────────────────────────────────────────────
# 16. The MODEL NAME route — and it needs only ONE relation.
#
# `_derived_reverse_accessor` returns the bare model name for a lone relation, so a model named
# `…__…` produces an unaddressable accessor with a single ForeignKey. This is the widest arm of the
# rule and the one that is reachable from GENERATED code: `Model_to_str` renames an illegal COLUMN
# and pins `db_column`, so a generated file can never carry a `__` field identifier — but it writes
# the model name verbatim.
#
# Django validates the identical case: `related_query_name()` falls back to `opts.model_name`, so
# `fields.E309` fires on a Django class named `A__B` too.
# ─────────────────────────────────────────────────────────────────────────────
@testset "a model name containing __ is refused with a single relation (#420)" begin
  err = @test_throws PormG.ModelDefinitionError _ran_module(:RanSepModelNameModels, quote
    Driver = Models.Model("ransm_driver", id = Models.IDField(), surname = Models.CharField())
    # ONE relation. The derived accessor is the bare model name, not `<model>_<field>`.
    Incident = Models.Model("ransm__incident",
      id = Models.IDField(),
      driverid = Models.ForeignKey(Driver, pk_field = "id"),
    )
  end)

  msg = err.value.msg
  @test occursin("ransm__incident", msg)
  # The remedy must point at the MODEL name. Before this was fixed the message said "rename the
  # field", which is dead advice here — renaming `driverid` changes nothing.
  @test occursin("The separator comes from the model name", msg)
  @test !occursin("the field name", msg)
end

# ─────────────────────────────────────────────────────────────────────────────
# 17. The BOUNDARY route — neither name contains `__`, their junction does.
#
# `_id` is a legitimate introspected column (`format_fild_name`'s own comment blesses it), and
# `<model>` + `_` + `_id` is `<model>__id`. A message that blamed either name alone would be wrong,
# so this pins the third branch of the remedy.
# ─────────────────────────────────────────────────────────────────────────────
@testset "a derived accessor whose separator is at the model/field boundary (#420)" begin
  err = @test_throws PormG.ModelDefinitionError _ran_module(:RanSepBoundaryModels, quote
    Driver = Models.Model("ransb_driver", id = Models.IDField(), surname = Models.CharField())
    Incident = Models.Model_Type(name = "ransb_incident",
      fields = Dict{String, PormG.PormGField}(
        "id"   => Models.IDField(),
        "_id"  => Models.ForeignKey("Driver", pk_field = "id"),
        "b_id" => Models.ForeignKey("Driver", pk_field = "id")),
      field_names = ["id", "_id", "b_id"])
  end)

  msg = err.value.msg
  @test occursin("ransb_incident__id", msg)
  @test occursin("the boundary between", msg)
  # Neither name is blamed on its own, because neither carries the separator. Matched WITHOUT the
  # model name: that name is wrapped in \e[1m…\e[0m, so including it would make this negative pass
  # vacuously under --color=yes — the exact mode it is here to defend.
  @test !occursin("comes from the model name", msg)
  @test !occursin("comes from the field name", msg)
end

# ─────────────────────────────────────────────────────────────────────────────
# 18. The funnel covers ManyToManyField too, not only ForeignKey.
#
# This is section 13's assertion for the other relation kind: `set_models` calls
# `_reverse_accessor_for` for m2m fields on a different branch, so covering only the FK branch would
# leave half the funnel untested. It does NOT reach the write-time guard in
# `_register_many_to_many_relation!` — `set_models` funnels first — which is why section 20 exists.
# ─────────────────────────────────────────────────────────────────────────────
@testset "an m2m explicit __ accessor is refused by the funnel (#420)" begin
  err = @test_throws PormG.ModelDefinitionError _ran_module(:RanSepM2MModels, quote
    Driver = Models.Model("ransx_driver", id = Models.IDField(), surname = Models.CharField())
    Championship = Models.Model("ransx_championship",
      id = Models.IDField(),
      drivers = Models.ManyToManyField(Driver),
    )
    # Behind the constructor guard, as in section 13.
    Championship.fields["drivers"].related_name = "a__b"
  end)

  msg = err.value.msg
  @test occursin("a__b", msg)
  @test occursin("ransx_championship.drivers", msg)
  @test !occursin("derived", msg)
end

# ─────────────────────────────────────────────────────────────────────────────
# 19. A definition-time guard must not fire from a READ path.
#
# `_cjoin` synthesizes a ForeignKey at query time to describe an auto-discovered join. It used to
# hand that field a `related_name` built as `"$(model.name)_$(target)_join"` — a string the user
# never wrote — and once `related_name` became shape-validated, a model whose name ends in `_`
# rendered `tb__Circuit_join` and turned an ordinary `.cjoin(...)` into a `FieldValidationError`.
#
# A trailing underscore is legal: `_validate_positional_model_name` rejects mixed case and a LEADING
# underscore, nothing else. The synthetic name is never read back, so it is simply not set any more.
# ─────────────────────────────────────────────────────────────────────────────
@testset "cjoin on a model whose name ends in _ still builds (#420 regression)" begin
  CJ = _ran_module(:RanSepCjoinModels, quote
    Circuit = Models.Model("ranscj_circuit", id = Models.IDField(), name = Models.CharField())
    # Trailing underscore — legal, and the shape that produced `tb__Circuit_join`.
    Lap_ = Models.Model("ranscj_lap_", id = Models.IDField(), circuit = Models.IntegerField())
  end)

  sql = Base.invokelatest() do
    q = getfield(CJ, :Lap_).objects
    q.cjoin("circuit" => "Circuit"; warn = false)
    q.values("id", "circuit__name")
    inspect_query(q)[:sql_text]
  end

  # It builds at all — that is the regression. Then: it really did join.
  @test occursin("ranscj_circuit", sql)
  @test occursin("JOIN", uppercase(sql))
end

# ─────────────────────────────────────────────────────────────────────────────
# 20. The check at the WRITE, reached the only way it can be.
#
# Testset 18 above goes through `set_models`, which calls `_reverse_accessor_for` BEFORE the
# registrar — so the funnel refuses first and the write-time check in
# `_register_many_to_many_relation!` is never reached. Deleting that check leaves testset 18 green.
# This one calls the registrar directly with no `reverse_accessor`, which is the shape that makes
# `_relation_from_many_to_many` derive an accessor of its own, bypassing the funnel entirely — the
# second producer the write-time check exists for. It is the only assertion in this file that turns
# red if `Models.jl`'s write-time `_accessor_has_separator` guard is removed.
#
# Same direct-registrar idiom as `test/unit/test_many_to_many.jl`'s shadow testsets, which is where
# that call shape is already exercised.
# ─────────────────────────────────────────────────────────────────────────────
@testset "the m2m write-time guard is reached when the funnel is bypassed (#420)" begin
  settings = PormG.Configuration.Settings(connections = RanMockPostgres(), change_data = true)

  reg_module = Module(:RanSepM2MDirect)
  Core.eval(reg_module, :(import PormG; import PormG.Models))
  Core.eval(reg_module, :(Driver = Models.Model("ransy_driver",
    id = Models.IDField(), surname = Models.CharField())))
  Core.eval(reg_module, :(Championship = Models.Model("ransy_championship",
    id = Models.IDField(),
    drivers = Models.ManyToManyField("Driver"),
  )))
  champ = Core.eval(reg_module, :(Championship))
  # Behind the constructor guard, as in sections 13 and 18.
  champ.fields["drivers"].related_name = "a__b"

  err = @test_throws PormG.ModelDefinitionError Models._register_many_to_many_relation!(
    reg_module, settings, champ, "drivers", champ.fields["drivers"])

  msg = err.value.msg
  @test occursin("a__b", msg)
  @test occursin("ransy_championship.drivers", msg)
  # Assert the CAUSE: this call shape can also raise ModelDefinitionError for a shadowed or taken
  # accessor, and either would satisfy a bare type check.
  @test occursin("lookup-path separator", msg)
  @test !occursin("is a FIELD of that model", msg)
end

# ═════════════════════════════════════════════════════════════════════════════
# #420, second mechanism — an accessor that ENDS with `_`
#
# The same defect, reached the other way. An accessor is only ever looked up as one segment of a
# `__`-split path, and traversing it APPENDS the separator: `incidents_` reached as
# `incidents___lap` splits into `incidents` and `_lap`, so the registered key is never probed. The
# user sees `the column incidents not found` — the identical truncated-fragment message the
# `__`-containing case produces.
#
# Measured before this was implemented: `related_name = "incidents_"` registered as `incidents_`, and
# BOTH `filter("incidents___lap")` and `filter("incidents__lap")` failed with that message.
#
# Django separates the two as `fields.E309` (must not contain) and `fields.E308` (must not end with
# an underscore); PormG treats them as one rule because they have one consequence.
# ═════════════════════════════════════════════════════════════════════════════

# ─────────────────────────────────────────────────────────────────────────────
# 21. An explicit `related_name` ending in `_`, refused at the constructor.
# ─────────────────────────────────────────────────────────────────────────────
@testset "an explicit related_name ending in _ is refused at declaration (#420)" begin
  for (label, build) in (
        ("ForeignKey",      () -> Models.ForeignKey("Driver", pk_field = "id", related_name = "incidents_")),
        ("OneToOneField",   () -> Models.OneToOneField("Driver", pk_field = "id", related_name = "incidents_")),
        ("ManyToManyField", () -> Models.ManyToManyField("Driver", related_name = "incidents_")))
    err = @test_throws PormG.FieldValidationError build()
    msg = err.value.msg
    @test occursin(label, msg)
    @test occursin("incidents_", msg)
    # The explanation is the TRAILING-underscore one, rendered with the user's own name, not the
    # separator explanation — those are different mechanisms and a shared sentence would fit neither.
    @test occursin("traversing an accessor appends the separator", msg)
    @test occursin("incidents___<column>", msg)
    @test !occursin("is the lookup-path separator", msg)
  end

  # A single trailing underscore is the whole rule — a name merely CONTAINING one is fine.
  @test Models.ForeignKey("Driver", pk_field = "id", related_name = "in_ci_dents").related_name ==
        "in_ci_dents"
  # And a LEADING underscore is addressable: `_acc__lap` splits to ["_acc", "lap"], so it is legal.
  @test Models.ForeignKey("Driver", pk_field = "id", related_name = "_incidents").related_name ==
        "_incidents"
end

# ─────────────────────────────────────────────────────────────────────────────
# 22. A DERIVED accessor ending in `_`, from the field name.
#
# In a group, the accessor is `<model>_<field>`, so a field named `lap_` puts the underscore at the
# end. The culprit is unambiguous here — the accessor ends with whatever the last component ends
# with — which is why this branch of the message names it outright instead of listing candidates.
# ─────────────────────────────────────────────────────────────────────────────
@testset "a derived accessor ending in _ names the field it came from (#420)" begin
  err = @test_throws PormG.ModelDefinitionError _ran_module(:RanTrailFieldModels, quote
    Driver = Models.Model("rantf_driver", id = Models.IDField(), surname = Models.CharField())
    Incident = Models.Model("rantf_incident",
      id   = Models.IDField(),
      lap_ = Models.ForeignKey(Driver, pk_field = "id"),
      b_id = Models.ForeignKey(Driver, pk_field = "id"),
    )
  end)

  msg = err.value.msg
  @test occursin("rantf_incident_lap_", msg)
  @test occursin("The trailing", msg)
  @test occursin("comes from the field name", msg)
  @test !occursin("comes from the model name", msg)
end

# ─────────────────────────────────────────────────────────────────────────────
# 23. A DERIVED accessor ending in `_`, from the MODEL name, on one relation.
#
# The lone-relation accessor IS the model name, so this needs no group — the same widening the
# `__`-in-a-model-name case has (section 16).
# ─────────────────────────────────────────────────────────────────────────────
@testset "a model name ending in _ is refused with a single relation (#420)" begin
  err = @test_throws PormG.ModelDefinitionError _ran_module(:RanTrailModelModels, quote
    Driver = Models.Model("rantm_driver", id = Models.IDField(), surname = Models.CharField())
    Incident = Models.Model("rantm_incident_",
      id = Models.IDField(),
      driverid = Models.ForeignKey(Driver, pk_field = "id"),
    )
  end)

  msg = err.value.msg
  @test occursin("rantm_incident_", msg)
  @test occursin("comes from the model name", msg)
  @test !occursin("comes from the field name", msg)
end

# ─────────────────────────────────────────────────────────────────────────────
# 24. CONTROL — a model named `..._` with NO relation still loads.
#
# The guard is on the ACCESSOR, so a trailing-underscore model name is only a problem when something
# derives an accessor from it. This is also the fixture shape testset 19 uses for the cjoin
# regression, so it pins that that testset's model stays constructible.
# ─────────────────────────────────────────────────────────────────────────────
@testset "a model name ending in _ loads when nothing derives an accessor from it (#420)" begin
  CTL = _ran_module(:RanTrailControlModels, quote
    Circuit = Models.Model("rantc_circuit", id = Models.IDField(), name = Models.CharField())
    Lap_ = Models.Model("rantc_lap_", id = Models.IDField(), circuit = Models.IntegerField())
  end)

  lap = Base.invokelatest(getfield, CTL, :Lap_)
  circuit = Base.invokelatest(getfield, CTL, :Circuit)
  @test lap.name == "rantc_lap_"
  # Nothing points at Circuit, so it has no reverse accessors and nothing was refused.
  @test isempty(circuit.related_objects)
end

# ─────────────────────────────────────────────────────────────────────────────
# 25. The trailing-underscore culprit is decided by the ACCESSOR's shape, not by which name
#     happens to end in `_`.
#
# A lone relation whose model AND field both end in `_`. The accessor is the model name — the field
# never enters it — so the model is the only thing worth renaming. The first implementation asked
# `endswith(field_name, "_")`, which is a different question, and told the user to rename `caused_`;
# doing that leaves the identical error in place because the accessor does not change.
#
# Paired with the group case below so the two cannot both be satisfied by a constant answer.
# ─────────────────────────────────────────────────────────────────────────────
@testset "a trailing-underscore accessor names the component it actually ends with (#420)" begin
  # (a) LONE relation, BOTH names end in `_` → the model is at fault.
  lone = @test_throws PormG.ModelDefinitionError _ran_module(:RanTailLoneModels, quote
    Driver = Models.Model("rantl_driver", id = Models.IDField(), surname = Models.CharField())
    Incident = Models.Model("rantl_incident_",
      id = Models.IDField(),
      caused_ = Models.ForeignKey(Driver, pk_field = "id"),
    )
  end)
  lone_msg = lone.value.msg
  @test occursin("rantl_incident_", lone_msg)
  @test occursin("comes from the model name", lone_msg)
  # The load-bearing negative: `caused_` also ends in `_`, and blaming it is the bug this pins.
  @test !occursin("comes from the field name", lone_msg)

  # (b) GROUP, only the field ends in `_` → the field is at fault. Same guard, opposite answer, so a
  #     constant "always blame the model" would fail here.
  grp = @test_throws PormG.ModelDefinitionError _ran_module(:RanTailGroupModels, quote
    Driver = Models.Model("rantg_driver", id = Models.IDField(), surname = Models.CharField())
    Incident = Models.Model("rantg_incident",
      id   = Models.IDField(),
      lap_ = Models.ForeignKey(Driver, pk_field = "id"),
      b_id = Models.ForeignKey(Driver, pk_field = "id"),
    )
  end)
  grp_msg = grp.value.msg
  @test occursin("rantg_incident_lap_", grp_msg)
  @test occursin("comes from the field name", grp_msg)
  @test !occursin("comes from the model name", grp_msg)
end

# ─────────────────────────────────────────────────────────────────────────────
# 26. The shape `Model_to_str` itself produces — a reserved-word relation column.
#
# `_julia_field_identifier` escapes a column named after a Julia keyword by APPENDING `_`, so a
# column `end` is emitted as `end_ = Models.ForeignKey(…, db_column="end", …)`. In a group of two or
# more relations to one target that derives `<model>_end_`, which this rule refuses — meaning a
# GENERATED file can stop loading. That is the opposite of the `__` half, where `Model_to_str`'s
# renaming makes a generated file safe by construction, and it is why the migration note tells
# readers to run the field-name grep on generated code too.
#
# `end`, `local`, `do`, `for` and `if` are all in the escaped set and all plausible legacy columns.
# ─────────────────────────────────────────────────────────────────────────────
@testset "a generator-escaped reserved-word relation column is refused in a group (#420)" begin
  err = @test_throws PormG.ModelDefinitionError _ran_module(:RanReservedModels, quote
    Driver = Models.Model("ranrw_driver", id = Models.IDField(), surname = Models.CharField())
    # Exactly what Model_to_str emits for a FK column literally named `end`.
    Incident = Models.Model("ranrw_incident",
      id   = Models.IDField(),
      end_ = Models.ForeignKey(Driver, db_column = "end", pk_field = "id"),
      b_id = Models.ForeignKey(Driver, pk_field = "id"),
    )
  end)

  msg = err.value.msg
  @test occursin("ranrw_incident_end_", msg)
  @test occursin("comes from the field name", msg)
  # The remedy is actionable without renaming the physical column, which `db_column` still pins.
  # Matched on a run with no ANSI in it — `related_name` is wrapped in \e[1m…\e[0m, so a substring
  # spanning it passes under --color=no and fails under --color=yes.
  @test occursin("Rename it, or give ranrw_incident.end_ an explicit ", msg)

  # Control: the SAME escaped column with a single relation loads — the accessor is then the model
  # name, which is clean. This is what keeps the refusal scoped to the group case.
  OK = _ran_module(:RanReservedLoneModels, quote
    Driver = Models.Model("ranrl_driver", id = Models.IDField(), surname = Models.CharField())
    Incident = Models.Model("ranrl_incident",
      id   = Models.IDField(),
      end_ = Models.ForeignKey(Driver, db_column = "end", pk_field = "id"),
    )
  end)
  driver = Base.invokelatest(getfield, OK, :Driver)
  @test collect(keys(driver.related_objects)) == ["ranrl_incident"]
end
