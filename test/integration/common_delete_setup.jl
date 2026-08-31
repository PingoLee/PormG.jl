# Julia forbids `module` expressions inside any block (if, for, @testset, …),
# so this file must be included at the top level of the calling file — not
# inside a @testset or any other macro body. The module definitions are
# unconditional; only the `const` aliases and `set_models` registrations are
# guarded by `if !@isdefined` to survive Revise re-includes safely.

if !isdefined(Main, :PormG)
    include("common_setup.jl")
end

# ─────────────────────────────────────────────────────────────────────────────
# Scratch module definitions
#
# Julia forbids `module` expressions inside any block (if, for, @testset, …).
# They must appear unconditionally at the top level of the file. To prevent
# Revise re-include from triggering duplicate set_models registrations or const
# rebinding errors, only the registration + const assignment lines are guarded
# by `if !@isdefined`. Module redefinition on re-include produces a harmless
# warning; existing const aliases keep pointing to the first module, which is
# the correct behaviour.
# ─────────────────────────────────────────────────────────────────────────────

module delete_protect_scratch_models
import PormG.Models

Delete_protect_parent_scratch = Models.Model("delete_protect_parent_scratch",
    id   = Models.IDField(),
    name = Models.CharField()
)

# ON DELETE PROTECT — PormG raises before any SQL is sent when child rows exist.
Delete_protect_child_scratch = Models.Model("delete_protect_child_scratch",
    id        = Models.IDField(),
    parent_id = Models.ForeignKey(Delete_protect_parent_scratch,
                    pk_field     = "id",
                    on_delete    = "PROTECT",
                    null         = true,
                    related_name = "protect_children"),
    label     = Models.CharField(null = true)
)

end

if !@isdefined(ProtectM)
    Models.set_models(delete_protect_scratch_models, joinpath(@__DIR__, PORMG_DB_FOLDER))
    const ProtectM = delete_protect_scratch_models
end

module keyless_delete_scratch_models
import PormG.Models

# No IDField — tests the keyless-model delete path.
Keyless_delete_scratch = Models.Model("keyless_delete_scratch",
    bucket = Models.CharField(),
    label  = Models.CharField(null = true)
)

end

if !@isdefined(KeylessM)
    Models.set_models(keyless_delete_scratch_models, joinpath(@__DIR__, PORMG_DB_FOLDER))
    const KeylessM = keyless_delete_scratch_models
end

module keyless_related_delete_scratch_models
import PormG.Models

Keyless_related_parent_scratch = Models.Model("keyless_related_parent_scratch",
    id   = Models.IDField(),
    name = Models.CharField()
)

# No IDField: the deletion collector must fall back to parent_id when this
# keyless child is reached through the parent's CASCADE graph.
Keyless_related_child_scratch = Models.Model("keyless_related_child_scratch",
    parent_id = Models.ForeignKey(Keyless_related_parent_scratch,
                    pk_field     = "id",
                    on_delete    = "CASCADE",
                    null         = false,
                    related_name = "keyless_children"),
    label     = Models.CharField()
)

end

if !@isdefined(KeylessRelatedM)
    Models.set_models(keyless_related_delete_scratch_models, joinpath(@__DIR__, PORMG_DB_FOLDER))
    const KeylessRelatedM = keyless_related_delete_scratch_models
end

module do_nothing_delete_scratch_models
import PormG.Models

Do_nothing_parent_scratch = Models.Model("do_nothing_parent_scratch",
    id   = Models.IDField(),
    name = Models.CharField()
)

# ON DELETE DO_NOTHING — the ORM skips the child during collection and lets
# the database enforce (or ignore) the FK constraint at execution time.
Do_nothing_child_scratch = Models.Model("do_nothing_child_scratch",
    id        = Models.IDField(),
    parent_id = Models.ForeignKey(Do_nothing_parent_scratch,
                    pk_field     = "id",
                    on_delete    = "DO_NOTHING",
                    null         = false,
                    related_name = "do_nothing_children"),
    label     = Models.CharField(null = true)
)

end

if !@isdefined(DoNothingM)
    Models.set_models(do_nothing_delete_scratch_models, joinpath(@__DIR__, PORMG_DB_FOLDER))
    const DoNothingM = do_nothing_delete_scratch_models
end

module set_null_guard_scratch_models
import PormG.Models

Set_null_guard_parent_scratch = Models.Model("set_null_guard_parent_scratch",
    id   = Models.IDField(),
    name = Models.CharField()
)

# Declared VALID (null = true) so registration succeeds, then flipped to null = false below.
# Since #287 `set_models` throws ModelDefinitionError on SET_NULL + null=false, so a model
# declared contradictory here would fail at module load and take the whole Deletes suite with
# it. Flipping after registration is also the more faithful fixture: the delete-collector guard
# exists precisely for models that reach delete() in a state `set_models` never vetted.
Set_null_guard_child_scratch = Models.Model("set_null_guard_child_scratch",
    id        = Models.IDField(),
    parent_id = Models.ForeignKey(Set_null_guard_parent_scratch,
                    pk_field     = "id",
                    on_delete    = "SET_NULL",
                    null         = true,
                    related_name = "nonnull_children"),
    label     = Models.CharField(null = true)
)

end

if !@isdefined(SetNullGuardM)
    Models.set_models(set_null_guard_scratch_models, joinpath(@__DIR__, PORMG_DB_FOLDER))
    # Introduce the contradiction the delete collector must catch, after set_models (which would
    # now reject it). Only the ORM-side view of the field changes; the table DDL is hand-written
    # in test_deletes.jl's _reset_set_null_guard_scratch_schema! and already says NOT NULL.
    set_null_guard_scratch_models.Set_null_guard_child_scratch.fields["parent_id"].null = false
    const SetNullGuardM = set_null_guard_scratch_models
end

module set_default_guard_scratch_models
import PormG.Models

Set_default_guard_parent_scratch = Models.Model("set_default_guard_parent_scratch",
    id   = Models.IDField(),
    name = Models.CharField()
)

# Mirror of the SET_NULL guard fixture above, for the SET_DEFAULT contradiction (#287).
# Declared VALID (default = 1) so set_models accepts it, then the default is stripped below.
# Before #287 the missing default flowed into update_field as a bare NULL, so SET_DEFAULT
# silently behaved as SET_NULL; now the collector refuses before any SQL is sent.
Set_default_guard_child_scratch = Models.Model("set_default_guard_child_scratch",
    id        = Models.IDField(),
    parent_id = Models.ForeignKey(Set_default_guard_parent_scratch,
                    pk_field     = "id",
                    on_delete    = "SET_DEFAULT",
                    default      = 1,
                    null         = true,
                    related_name = "no_default_children"),
    label     = Models.CharField(null = true)
)

end

if !@isdefined(SetDefaultGuardM)
    Models.set_models(set_default_guard_scratch_models, joinpath(@__DIR__, PORMG_DB_FOLDER))
    # Strip the default after registration to create the contradiction the collector must catch.
    set_default_guard_scratch_models.Set_default_guard_child_scratch.fields["parent_id"].default = nothing
    const SetDefaultGuardM = set_default_guard_scratch_models
end

module multipath_set_null_scratch_models
import PormG.Models

# A SET_NULL child hanging off a MULTI-PATH parent (#459). The F1 fixture cannot express this: its
# SET_NULL / SET_DEFAULT foreign keys point at `result`, which is the delete ROOT and therefore
# single-path, while the only multi-path model there (`just_a_test_deletion`) has no SET_NULL child.
#
# `mp_mid_scratch` reaches `mp_root_scratch` twice, so `handle_on_delete!` resolves `mp_leaf_scratch`
# once per path with a different scoping query each time. `collector.field_updates` used to ASSIGN
# where `collector.objects` appends, so the second path silently replaced the first and one path's
# leaves were never nulled.
Mp_root_scratch = Models.Model("mp_root_scratch",
    id   = Models.IDField(),
    name = Models.CharField()
)

Mp_mid_scratch = Models.Model("mp_mid_scratch",
    id     = Models.IDField(),
    owner  = Models.ForeignKey(Mp_root_scratch, pk_field = "id", on_delete = "CASCADE",
                 null = true, related_name = "mp_owned"),
    backup = Models.ForeignKey(Mp_root_scratch, pk_field = "id", on_delete = "CASCADE",
                 null = true, related_name = "mp_backups"),
    label  = Models.CharField()
)

Mp_leaf_scratch = Models.Model("mp_leaf_scratch",
    id    = Models.IDField(),
    mid   = Models.ForeignKey(Mp_mid_scratch, pk_field = "id", on_delete = "SET_NULL",
                null = true, related_name = "mp_leaves"),
    label = Models.CharField()
)

end

if !@isdefined(MultipathSetNullM)
    Models.set_models(multipath_set_null_scratch_models, joinpath(@__DIR__, PORMG_DB_FOLDER))
    const MultipathSetNullM = multipath_set_null_scratch_models
end
