# =============================================================================
# Migration advisory-lock identity (#90)
#
# `migrate()` serializes concurrent PostgreSQL migrations on an advisory lock. The key used to be
# "pormg_migrations_$(settings.db_def_folder)" — the CONFIG FOLDER name, which is not database
# identity. Two config folders resolving to one physical database therefore took two different
# locks and migrated it concurrently, silently defeating the only guarantee the lock provides.
#
# The fix is subtractive, and these tests pin why it is allowed to be: a PostgreSQL advisory lock
# is tagged (database OID, key), so the database is ALREADY the lock's namespace. The key needs no
# qualifier at all — and the folder-shaped one it carried was actively splitting one database's
# lock into per-folder shards.
#
# Hermetic on purpose: `_migration_lock_key` takes settings and touches no connection, so the
# guarantee is checkable without a live server. The other half of the claim — that PostgreSQL
# really does scope advisory locks per database — is not assertable here and is verified by
# execution in test/integration/test_advisorylock.jl.
# =============================================================================

using Test
using PormG
import PormG.Migrations
import PormG.Configuration: Settings

@testset "Migration advisory-lock identity (#90)" begin

    # ─────────────────────────────────────────────────────────────────────────
    # Lock identity: the config folder does not participate
    # Two Settings differing ONLY in `db_def_folder` must produce the same lock key. This is the
    # whole issue: those two configs may point at one database, and before the fix they took
    # "pormg_migrations_db_prod_a" and "pormg_migrations_db_prod_b" and never excluded each other.
    # ─────────────────────────────────────────────────────────────────────────
    @testset "two config folders yield one lock key" begin
        a = Settings(db_def_folder = "db_prod_a")
        b = Settings(db_def_folder = "db_prod_b")

        # Mutation gate: against the unpatched key this is
        # "pormg_migrations_db_prod_a" == "pormg_migrations_db_prod_b" — false.
        @test Migrations._migration_lock_key(a) == Migrations._migration_lock_key(b)

        # And neither key smuggles the folder in by another spelling.
        for s in (a, b)
            key = Migrations._migration_lock_key(s)
            @test !occursin(s.db_def_folder, key)
        end
    end

    # ─────────────────────────────────────────────────────────────────────────
    # The key is the documented constant
    # `MIGRATION_LOCK_KEY` is what an operator sees in pg_locks and what the docs name, so it is
    # pinned rather than merely "some constant": changing it would silently stop excluding a
    # migration already running under the old key during a rolling deploy.
    # ─────────────────────────────────────────────────────────────────────────
    @testset "the key is the documented constant" begin
        @test Migrations.MIGRATION_LOCK_KEY == "pormg::migrations"
        @test Migrations._migration_lock_key(Settings()) === Migrations.MIGRATION_LOCK_KEY

        # A path separator in the key would be the tell that a folder crept back in.
        @test !occursin('/', Migrations.MIGRATION_LOCK_KEY)
        @test !occursin('\\', Migrations.MIGRATION_LOCK_KEY)
    end

    # ─────────────────────────────────────────────────────────────────────────
    # Folder-independence holds for the paths a real deployment uses
    # `db_def_folder` is a filesystem path, so it varies by checkout, OS separator and deploy
    # root even when two processes target the identical database. Every one of these has to
    # collapse to one key, or a rolling deploy from two directories migrates concurrently.
    # ─────────────────────────────────────────────────────────────────────────
    @testset "folder-independence across realistic deploy paths" begin
        folders = ["db", "db/", "./db", "/srv/app/db", "C:\\deploy\\app\\db",
                   "db_2", "test/integration/db_2"]
        keys = Set(Migrations._migration_lock_key(Settings(db_def_folder = f)) for f in folders)
        @test length(keys) == 1
    end
end
