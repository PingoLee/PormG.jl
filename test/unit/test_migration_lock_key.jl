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
import PormG: PormGPostgres

# A probe pool that intercepts the lock instead of taking one. Suffixed name: `runtests.jl` includes
# every unit file into ONE module.
#
# This exists because asserting on `_migration_lock_key` alone does NOT test the fix. Review found
# that a variant which added the constant and the helper but left `_run_locked_lifecycle` calling
# `"pormg_migrations_$(settings.db_def_folder)"` passed every other assertion in this file. The
# defect #90 reports is at the CALL SITE, so one test has to reach it.
#
# Defining a method on `PormG.AdvisoryLock.with_advisory_lock` for our own type is an ordinary
# qualified definition, and it dispatches on nothing else in the suite. It deliberately does NOT
# invoke `f`, so no migration lifecycle runs.
struct LockKeyProbePg89 <: PormGPostgres end
const LOCK_KEY_OBSERVED = Ref{String}("")
function PormG.AdvisoryLock.with_advisory_lock(f::Function, pool::LockKeyProbePg89,
                                               key::AbstractString; kwargs...)
    LOCK_KEY_OBSERVED[] = String(key)
    return :intercepted
end

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
    # THE CALL SITE — `migrate()` actually locks on this key
    # The three testsets around this one pin `_migration_lock_key`; this is the only one that pins
    # the behaviour #90 is about. `_run_locked_lifecycle` is the sole consumer, and nothing in the
    # suite referenced it before this file existed.
    # Mutation gate: restore `lock_key = "pormg_migrations_$(settings.db_def_folder)"` at the call
    # site and this fails while every other assertion here still passes — which is exactly the hole
    # review found.
    # ─────────────────────────────────────────────────────────────────────────
    @testset "the migration runner locks on that key, not on the folder" begin
        LOCK_KEY_OBSERVED[] = ""
        settings = Settings(db_def_folder = "db_prod_a")

        # The lifecycle never runs: the probe returns without invoking the body.
        result = Migrations._run_locked_lifecycle(LockKeyProbePg89(), settings,
                                                  String[], "", "v", "n", "checksum", false)
        @test result === :intercepted
        @test LOCK_KEY_OBSERVED[] == Migrations.MIGRATION_LOCK_KEY
        @test !occursin("db_prod_a", LOCK_KEY_OBSERVED[])

        # And a second folder reaches the lock under the SAME key — the mutual exclusion #90 asks
        # for, observed at the call site rather than inferred from the helper.
        LOCK_KEY_OBSERVED[] = ""
        Migrations._run_locked_lifecycle(LockKeyProbePg89(), Settings(db_def_folder = "db_prod_b"),
                                         String[], "", "v", "n", "checksum", false)
        @test LOCK_KEY_OBSERVED[] == Migrations.MIGRATION_LOCK_KEY
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
