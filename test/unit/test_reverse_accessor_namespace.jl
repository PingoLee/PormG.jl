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
