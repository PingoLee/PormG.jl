# ─────────────────────────────────────────────────────────────────────────────
# #150: `_fk_definition_changed` — the gate that decides whether a *renamed* FK field also needs a SQLite
# table rebuild.
#
# On SQLite a foreign-key clause lives inside `CREATE TABLE`, and a plain `ALTER TABLE … RENAME COLUMN`
# keeps the OLD clause. So renaming an FK field whose FK *definition* also changes has to route through a
# full table rebuild (like the #83 alteration and #116 deletion paths), while a plain FK rename must keep
# the cheap RENAME COLUMN path — SQLite updates the FK's local-column reference natively. This predicate is
# what distinguishes the two: it must fire for every kind of FK-definition change and stay quiet otherwise.
#
# Pure logic over two field structs — no DB, no dispatch — so every branch is covered deterministically
# here; the end-to-end rebuild is exercised by test/integration Phase 4e/4f.
# ─────────────────────────────────────────────────────────────────────────────
using Test
using PormG
const _M = PormG.Models
import PormG.Migrations: _fk_definition_changed

@testset "_fk_definition_changed (#150)" begin
    fk       = _M.ForeignKey("MigrationTest", on_delete=_M.CASCADE, null=true)
    fk_same  = _M.ForeignKey("MigrationTest", on_delete=_M.CASCADE, null=true)                 # identical FK
    fk_nocon = _M.ForeignKey("MigrationTest", on_delete=_M.CASCADE, null=true, db_constraint=false)
    fk_retgt = _M.ForeignKey("SecondTable",   on_delete=_M.CASCADE, null=true)                 # different parent
    fk_ondel = _M.ForeignKey("MigrationTest", on_delete=_M.SET_NULL, null=true)                # different on_delete
    ch       = _M.CharField(null=true)

    # No change ⇒ false, so a plain FK rename keeps the cheap RENAME COLUMN path (no needless rebuild).
    @test _fk_definition_changed(fk_same, fk) == false
    # A non-FK-to-non-FK rename is never a rebuild trigger.
    @test _fk_definition_changed(ch, _M.CharField()) == false

    # Every genuine FK-definition change ⇒ true (each would otherwise silently keep the old clause on SQLite).
    @test _fk_definition_changed(fk_nocon, fk) == true    # db_constraint flip true→false (drop the constraint)
    @test _fk_definition_changed(fk, ch)       == true    # FK added by the rename   (old non-FK → new FK)
    @test _fk_definition_changed(ch, fk)       == true    # FK removed by the rename (old FK → new non-FK)
    @test _fk_definition_changed(fk_retgt, fk) == true    # repoint to a different parent (the issue's headline case)
    @test _fk_definition_changed(fk_ondel, fk) == true    # on_delete change, both sides still live FKs
end
