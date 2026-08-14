# ==============================================================================
# #334: `auto_add` alone is not schema drift
#
# Introspection can never read `auto_add` back — PormG mints a UUID in Julia on write, never
# as a column DEFAULT (same reasoning `_NON_SCHEMA_FIELD_ATTRS`'s header comment already gives
# for `auto_now`/`auto_now_add`, in `src/migrations/planner.jl`), so the "live" side of a
# live-vs-declared comparison always reconstructs `auto_add = false` regardless of what the
# declared model says. Before #334, `auto_add` was simply missing from that exclusion tuple —
# unnoticed only because no fixture anywhere declared `auto_add = true` on a field a diff ever
# had to reconcile.
#
# A dedicated file rather than an addition to `test/unit/test_migration_planner.jl`: that file
# is commented out of `test/runtests.jl` (unrelated to #334, predates it, no comment explaining
# why) and so gets zero CI protection — this narrow check needs its own registered home.
#
# THREE assertions, not one, because a single end-to-end "does the plan stay empty" check turns
# out NOT to be a mutation gate here: `Dialect.alter_field` has no SQL-emitting branch for
# `:auto_add` at all (checked directly, `IMPLEMENTED` list), so an `:auto_add`-only diff renders
# to an empty alteration string regardless of whether `_NON_SCHEMA_FIELD_ATTRS` excludes it —
# `_configure_order_dict_migration_plan`'s `value == "" && return` silently drops it either way.
# Reverting the exclusion (confirmed by hand: `git stash` on `planner.jl` alone, same test file,
# same PostgreSQL bootstrap) still produces an empty plan — just with a spurious `@warn "The
# attributes [:auto_add] are not implemented in alter_field function"` on every single
# `makemigrations` run. So the exclusion's real, provable effect is suppressing that warning, not
# preventing a plan-level regression (an unrelated safety net already does that). Assertion 1
# below is the actual mutation gate — a direct membership check on what #334 changed; assertion 2
# proves the log-silence consequence; assertion 3 is the plan-emptiness end state, kept because
# it IS the user-visible outcome, with its limits stated rather than overclaimed.
# ==============================================================================

using Test
using Logging
using PormG
using PormG.Models
using PormG.Migrations
import PormG: PormGModel, PormGPostgres

struct MigrationPlannerAutoAddMockPg <: PormGPostgres end

@testset "#334: a UUIDField primary key differing only in auto_add is not proposed as drift" begin
    mock_conn_pg = MigrationPlannerAutoAddMockPg()
    settings = PormG.Configuration.Settings()
    settings.change_db = true

    # 1. THE mutation gate: direct membership check on the tuple #334 actually changed. Reverting
    # the fix fails this immediately and unconditionally, independent of `alter_field`/`Dialect`
    # downstream behavior.
    @test :auto_add in Migrations._NON_SCHEMA_FIELD_ATTRS

    live_table = Models.Model("uuid_pk_test",
        token = Models.UUIDField(primary_key=true, auto_add=false, unique=false, null=false, db_index=true),
        label = Models.CharField(max_length=100),
    )
    declared_table = Models.Model("uuid_pk_test",
        token = Models.UUIDField(primary_key=true, auto_add=true, unique=false, null=false, db_index=true),
        label = Models.CharField(max_length=100),
    )
    current_schema = Dict{Symbol, Dict{Symbol, Union{Bool, PormGModel}}}(
        :uuid_pk_test => Dict{Symbol, Union{Bool, PormGModel}}(:model => declared_table, :exist => false)
    )

    # 2. The behavioral consequence that DOES distinguish "excluded" from "not excluded": with the
    # exclusion, `_compare_model_field`-style diffing never puts `:auto_add` in `colect_not_equal`,
    # so `Dialect.alter_field` is never asked to render it and never logs its "not implemented"
    # warning. `min_level = Logging.Warn` with no expected specs asserts ZERO Warn-or-above log
    # records — the same idiom `test/unit/test_connection_pool_leak.jl` uses for "no warn expected".
    plan = @test_logs min_level = Logging.Warn Migrations.get_migration_plan(
        PormGModel[live_table], current_schema, mock_conn_pg, settings)

    # 3. The end-state outcome, stated honestly: an EMPTY plan here is the correct, user-visible
    # result — but per the header comment, `Dialect.alter_field`'s missing `:auto_add`
    # implementation plus the empty-string guard in `_configure_order_dict_migration_plan` would
    # ALSO produce an empty plan even without the exclusion above. This assertion documents the
    # outcome; assertions 1 and 2 are what actually prove the exclusion did something.
    @test !haskey(plan, :uuid_pk_test) || isempty(plan[:uuid_pk_test])

    # Negative control: the SAME two models, but now also disagreeing on `null` — a real,
    # DDL-visible difference `alter_field` DOES implement. Proves the comparison is genuinely
    # exercised (both models route through the "same type" branch and get compared field-by-field)
    # rather than `get_migration_plan` short-circuiting to an empty result for some other reason.
    live_table_null_mismatch = Models.Model("uuid_pk_test",
        token = Models.UUIDField(primary_key=true, auto_add=false, unique=false, null=true, db_index=true),
        label = Models.CharField(max_length=100),
    )
    plan_with_real_diff = Migrations.get_migration_plan(PormGModel[live_table_null_mismatch], current_schema, mock_conn_pg, settings)
    @test haskey(plan_with_real_diff, :uuid_pk_test) && !isempty(plan_with_real_diff[:uuid_pk_test])
end
