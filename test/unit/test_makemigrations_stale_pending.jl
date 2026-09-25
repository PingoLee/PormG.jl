# =============================================================================
# An up-to-date makemigrations leaves no stale pending plan behind (#727)
#
# `makemigrations` overwrites `pending_migrations.jl` whenever the diff is non-empty, but on an EMPTY
# diff it only logged "up-to-date … No migrations are pending" and left any earlier plan on disk.
# `status().pending` stayed true and a later `migrate()` applied it: add a field, plan it, take the
# field back, plan again — and `migrate` still added the column the models no longer declare.
#
# The pending file now describes the current diff and nothing else. An empty diff moves an older plan
# aside to `pending_migrations.jl.discarded` through `discard_pending_migration`, the call a user
# would make by hand, so the recovery path is the one already documented.
#
# Hermetic: temporary SQLite files and temporary config folders, no live database. The PostgreSQL
# method is driven by a mock whose catalog is empty, since both methods share the tail under test.
# =============================================================================
# julia --project=test/integration test/unit/test_makemigrations_stale_pending.jl

using Test
using Logging
using DataFrames
using PormG
# The SQLite testset opens a real (temporary) file, so it needs the weakdep extension.
# `runtests.jl` loads it for the whole suite; this guard is what makes the file runnable alone.
isdefined(Main, :SQLite) || include(joinpath(@__DIR__, "..", "load_drivers.jl"))
import PormG: Configuration, Migrations, PormGPostgres
import PormG.ConnectionPool: fetch, close_pool!, SQLiteConnectionPool

# Suffixed name: `runtests.jl` includes every unit file into ONE module. Its catalog is empty, so
# `read_live_schema` returns no tables and an empty models file diffs to an empty plan.
struct StalePendingMockPg727 <: PormGPostgres end
fetch(::StalePendingMockPg727, sql::String; conn = nothing, params = nothing, ignore_tx::Bool = false) = DataFrame()

# The models file `makemigrations` reads: one F1 table, with or without the column under test.
function _sp727_write_models(path::AbstractString; with_nickname::Bool)
    nickname = with_nickname ? "    nickname = Models.CharField(null = true),\n" : ""
    write(path, "module models\nimport PormG.Models\n" *
                "Driver727 = Models.Model(\n    id = Models.IDField(),\n" * nickname *
                "    surname = Models.CharField(null = true)\n)\nend\n")
end

_sp727_columns(pool) = String.(DataFrame(fetch(pool, "PRAGMA table_info(driver727);")).name)

# `makemigrations` and `migrate` report through the logger; the assertions below read the files.
_sp727_quiet(f) = with_logger(f, NullLogger())

# ─────────────────────────────────────────────────────────────────────────────
# SQLite, end to end: plan, take the change back, plan again, migrate
# The issue's own sequence. The stale plan is additive — an ADD COLUMN — which is the case the
# destructive guard cannot catch, so before the fix the final `migrate` applied it silently.
# ─────────────────────────────────────────────────────────────────────────────
@testset "an up-to-date makemigrations moves a stale pending plan aside (#727)" begin
    dir = mktempdir()
    pool = nothing
    try
        cd(dir) do
            mkpath("db727")
            # Absolute: `makemigrations` `include`s it, and a relative include resolves against the
            # including source file, not the working directory.
            models_path = joinpath(dir, "db727", "models.jl")
            pending = joinpath("db727", "migrations", "pending_migrations.jl")
            pool = SQLiteConnectionPool(joinpath(dir, "sp727.sqlite"); pool_size = 1)
            settings = Configuration.Settings(connections = pool, db_def_folder = "db727")
            settings.change_db = true
            plan!() = _sp727_quiet(() -> Migrations.makemigrations(pool, settings; path = models_path, interactive = false))

            # The table exists as declared, without the column.
            _sp727_write_models(models_path; with_nickname = false)
            plan!()
            _sp727_quiet(() -> Migrations.migrate(pool, settings; interactive = false))
            @test !("nickname" in _sp727_columns(pool))

            # An empty diff with nothing pending writes nothing, and backs nothing up.
            plan!()
            @test !isfile(pending)
            @test !isfile(pending * ".discarded")

            # Add the field: the plan to add it is pending.
            _sp727_write_models(models_path; with_nickname = true)
            plan!()
            @test isfile(pending)
            stale = read(pending, String)
            @test occursin("nickname", stale)

            # Take it back. The diff is empty, so that plan no longer describes anything.
            _sp727_write_models(models_path; with_nickname = false)
            plan!()
            @test !isfile(pending)
            @test isfile(pending * ".discarded") && read(pending * ".discarded", String) == stale
            @test Migrations.status(pool, settings).pending == false

            # And `migrate` applies nothing: with no pending plan it refuses, where it used to apply the
            # stale ADD COLUMN — so the column the models took back never appears.
            @test_throws PormG.InvalidMigrationError _sp727_quiet(() -> Migrations.migrate(pool, settings; interactive = false))
            @test !("nickname" in _sp727_columns(pool))
        end
    finally
        pool === nothing || close_pool!(pool)
        rm(dir; recursive = true, force = true)
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# An applied-but-unarchived plan is kept, not discarded (#727 × #81)
# A `migrate` that COMMITs and then fails to archive leaves its plan as `pending_migrations.jl`, and
# the next `migrate` archives it by checksum without re-applying. The diff is empty in exactly that
# state — the plan's own effect — so discarding it would lose its archive and models snapshot. The
# state is reproduced by moving the archived plan back, which is what a failed archive leaves.
# ─────────────────────────────────────────────────────────────────────────────
@testset "an applied but unarchived plan survives an up-to-date makemigrations (#727)" begin
    dir = mktempdir()
    pool = nothing
    try
        cd(dir) do
            mkpath("db727b")
            models_path = joinpath(dir, "db727b", "models.jl")
            pending = joinpath("db727b", "migrations", "pending_migrations.jl")
            applied_dir = joinpath("db727b", "migrations", "applied_migrations")
            pool = SQLiteConnectionPool(joinpath(dir, "sp727b.sqlite"); pool_size = 1)
            settings = Configuration.Settings(connections = pool, db_def_folder = "db727b")
            settings.change_db = true
            archived() = filter(f -> endswith(f, "_migration.jl"), readdir(applied_dir))

            _sp727_write_models(models_path; with_nickname = true)
            _sp727_quiet(() -> Migrations.makemigrations(pool, settings; path = models_path, interactive = false))
            _sp727_quiet(() -> Migrations.migrate(pool, settings; interactive = false))
            @test length(archived()) == 1
            applied_plan = read(joinpath(applied_dir, only(archived())), String)

            # The archive "failed": the applied plan is still the pending file.
            mv(joinpath(applied_dir, only(archived())), pending)

            _sp727_quiet(() -> Migrations.makemigrations(pool, settings; path = models_path, interactive = false))
            @test isfile(pending) && read(pending, String) == applied_plan
            @test !isfile(pending * ".discarded")

            # And the next `migrate` archives it without applying it again.
            _sp727_quiet(() -> Migrations.migrate(pool, settings; interactive = false))
            @test !isfile(pending)
            @test length(archived()) == 1 && read(joinpath(applied_dir, only(archived())), String) == applied_plan
            @test "nickname" in _sp727_columns(pool)
        end
    finally
        pool === nothing || close_pool!(pool)
        rm(dir; recursive = true, force = true)
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# PostgreSQL: the same move, through the other method
# The two `makemigrations` methods used to carry their own copy of the write-or-log tail, which is
# how one engine could be fixed and the other not. An empty catalog and an empty models file diff to
# an empty plan, so a hand-placed pending file is the stale one.
# ─────────────────────────────────────────────────────────────────────────────
@testset "the PostgreSQL makemigrations moves a stale pending plan aside too (#727)" begin
    dir = mktempdir()
    try
        cd(dir) do
            mkpath(joinpath("db727pg", "migrations"))
            models_path = joinpath(dir, "db727pg", "models.jl")
            write(models_path, "module models\nimport PormG.Models\nend\n")
            pending = joinpath("db727pg", "migrations", "pending_migrations.jl")
            stale = "module pending_migrations\nimport OrderedCollections: OrderedDict\nend\n"
            write(pending, stale)
            settings = Configuration.Settings(connections = StalePendingMockPg727(), db_def_folder = "db727pg")
            settings.change_db = true

            _sp727_quiet(() -> Migrations.makemigrations(StalePendingMockPg727(), settings; path = models_path, interactive = false))
            @test !isfile(pending)
            @test isfile(pending * ".discarded") && read(pending * ".discarded", String) == stale
        end
    finally
        rm(dir; recursive = true, force = true)
    end
end
