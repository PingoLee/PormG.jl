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

# Intentionally invalid: SET_NULL on a non-null FK. set_models emits a
# warning at registration time; the model exists only to exercise the
# pre-mutation guard in the delete collector.
Set_null_guard_child_scratch = Models.Model("set_null_guard_child_scratch",
    id        = Models.IDField(),
    parent_id = Models.ForeignKey(Set_null_guard_parent_scratch,
                    pk_field     = "id",
                    on_delete    = "SET_NULL",
                    null         = false,
                    related_name = "nonnull_children"),
    label     = Models.CharField(null = true)
)

end

if !@isdefined(SetNullGuardM)
    Models.set_models(set_null_guard_scratch_models, joinpath(@__DIR__, PORMG_DB_FOLDER))
    const SetNullGuardM = set_null_guard_scratch_models
end
