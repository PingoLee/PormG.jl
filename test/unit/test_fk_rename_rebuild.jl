# ─────────────────────────────────────────────────────────────────────────────
# #150: the gate that decides whether a *renamed* FK field also needs a SQLite table rebuild.
#
# On SQLite a foreign-key clause lives inside `CREATE TABLE`, and a plain `ALTER TABLE … RENAME
# COLUMN` keeps the OLD clause. So renaming an FK field whose FK *definition* also changes has to
# route through a full table rebuild (like the #83 alteration and #116 deletion paths), while a plain
# FK rename must keep the cheap RENAME COLUMN path — SQLite updates the FK's local-column reference
# natively. The gate must fire for every kind of FK-definition change and stay quiet otherwise.
#
# WHAT CHANGED IN #507 phase 2. The predicate this file was written for, `_fk_definition_changed`, is
# gone. It was `Models._compare_field_foreign_key` + `fk_target_column` + `_fk_on_delete_equal` —
# which is `reference_delta` by another name, reached through three field reads instead of one spec
# comparison — and it was one of TWO functions answering "did this reference move?". The other,
# `_fk_constraint_action`, is now the only one, and it reads the canonical column IR.
#
# So this file keeps its truth table and re-points it at that function. Every row still means what it
# meant; `true` (rebuild) is now spelled as an action other than `:none`, and each row additionally
# pins WHICH action, which the boolean could not express. Two rows are new: the `:repoint` fold that
# `_fk_definition_changed` needed a helper for, and the field-deletion path.
#
# The gate is also strictly WIDER now, and that is deliberate rather than incidental: the planner asks
# "is the delta empty?" before it asks about the reference, so a rename that changes the column's TYPE
# rebuilds too. It did not before — measured on the base commit, such a rename planned the RENAME
# alone and dropped the type change on the floor until the next `makemigrations` re-proposed it.
#
# Pure logic over two `ColumnSpec`s — no DB — so every branch is covered deterministically here; the
# end-to-end rebuild is exercised by test/integration Phase 4e/4f.
# ─────────────────────────────────────────────────────────────────────────────
using Test
using PormG
const _M = PormG.Models
import PormG.Migrations: _fk_constraint_action, column_spec, column_delta

# A marker connection is enough: `column_spec` needs only the engine to render a type through.
struct MockSlRenameRebuild150 <: PormG.PormGSQLite end
const _RR_SL = MockSlRenameRebuild150()

# `column_spec` compiles a field into what the DATABASE can hold. `_rr` keeps the call short and
# names every column the same, since `ColumnSpec.name` is excluded from the comparison (a name change
# is a RENAME, planned from the field-key sets rather than by the column diff).
_rr(field) = column_spec(field, _RR_SL; name = "parent_id")

@testset "the rename-rebuild gate (#150, over the column IR since #507)" begin
    fk       = _M.ForeignKey("MigrationTest", on_delete=_M.CASCADE, null=true)
    fk_same  = _M.ForeignKey("MigrationTest", on_delete=_M.CASCADE, null=true)                 # identical FK
    fk_nocon = _M.ForeignKey("MigrationTest", on_delete=_M.CASCADE, null=true, db_constraint=false)
    fk_retgt = _M.ForeignKey("SecondTable",   on_delete=_M.CASCADE, null=true)                 # different parent
    fk_ondel = _M.ForeignKey("MigrationTest", on_delete=_M.SET_NULL, null=true)                # different on_delete
    fk_prot  = _M.ForeignKey("MigrationTest", on_delete=_M.PROTECT, null=true)                 # renders RESTRICT
    fk_restr = _M.ForeignKey("MigrationTest", on_delete=_M.RESTRICT, null=true)
    ch       = _M.CharField(null=true)

    # No change ⇒ `:none`, so a plain FK rename keeps the cheap RENAME COLUMN path (no needless
    # rebuild). The delta is empty too, which is what the planner actually gates the rebuild on.
    @test _fk_constraint_action(_rr(fk_same), _rr(fk)) === :none
    @test isempty(column_delta(fk_same, fk, _RR_SL; name = "parent_id"))

    # A non-FK-to-non-FK rename is never a rebuild trigger. `CharField()` defaults to
    # `null = false`, so the delta pair is spelled with a matching `null = true` — otherwise this
    # row would be asserting nullability, not FK-ness.
    @test _fk_constraint_action(_rr(ch), _rr(_M.CharField())) === :none
    @test isempty(column_delta(ch, _M.CharField(null = true), _RR_SL; name = "parent_id"))

    # Every genuine FK-definition change fires — each would otherwise silently keep the old clause on
    # SQLite — and now says which DDL it means.
    @test _fk_constraint_action(_rr(fk_nocon), _rr(fk)) === :drop     # db_constraint true→false
    @test _fk_constraint_action(_rr(fk), _rr(ch))       === :add      # FK added by the rename
    @test _fk_constraint_action(_rr(ch), _rr(fk))       === :drop     # FK removed by the rename
    @test _fk_constraint_action(_rr(fk_retgt), _rr(fk)) === :repoint  # a different parent (the headline case)
    @test _fk_constraint_action(_rr(fk_ondel), _rr(fk)) === :repoint  # on_delete change, both sides live

    # NEW ROW: two spellings of one clause are NOT a change. `PROTECT` renders `RESTRICT`, so the
    # pair is the same constraint however it was declared. `_fk_definition_changed` needed
    # `Models._fk_on_delete_equal` for this; the IR gets it by storing the RENDERED clause, so there
    # is no second predicate to keep in step.
    @test _fk_constraint_action(_rr(fk_prot), _rr(fk_restr)) === :none
    @test isempty(column_delta(fk_prot, fk_restr, _RR_SL; name = "parent_id"))

    # NEW ROW: the field-DELETION path. `nothing` on the new side means the column is going away, so
    # a constraint on it is dropped — and a column that never had one needs nothing.
    @test _fk_constraint_action(nothing, _rr(fk)) === :drop
    @test _fk_constraint_action(nothing, _rr(ch)) === :none

    # The WIDENING, asserted rather than described. A rename that also changes the COLUMN — here its
    # nullability — has an unchanged reference, so the FK decision is `:none`, while the delta is NOT
    # empty, and that is what now routes it through the rebuild. The old boolean gate saw only the
    # first half and let the column change slip. (Nullability rather than the type, because the
    # `.to` slot fixes the rendered type for a foreign key; the type axis is covered by the
    # `rename_and_retype` pair in `test_plan_actions_golden.jl`.)
    retyped = _M.ForeignKey("MigrationTest", on_delete=_M.CASCADE, null=false)
    @test _fk_constraint_action(_rr(retyped), _rr(fk)) === :none
    @test !isempty(column_delta(retyped, fk, _RR_SL; name = "parent_id"))
    @test column_delta(retyped, fk, _RR_SL; name = "parent_id").changed == [:nullable]
end
