# =============================================================================
# makemigrations raises when it cannot read the live schema (#1018)
#
# Both `makemigrations` methods wrapped `read_live_schema` in a `try` that logged the failure and
# returned `nothing` — the value a successful run returns — so a script could not tell a plan from a
# broken connection. The PostgreSQL `catch` also matched an "empty database" error text that nothing
# raises, so its `@info` arm never ran. `migrate`'s precondition and `check()` already let the same
# read propagate; `makemigrations` now does too.
#
# Hermetic: mock connections whose `fetch` throws or returns an empty catalog, and temporary config
# folders. No live database.
# =============================================================================
# julia --project=test/integration test/unit/test_makemigrations_read_failure.jl

using Test
using Logging
using DataFrames
using PormG
# The SQLite mock dispatches through the weakdep extension (`backend_sqlite_version`). `runtests.jl`
# loads it for the whole suite; this guard is what makes the file runnable alone.
isdefined(Main, :SQLite) || include(joinpath(@__DIR__, "..", "load_drivers.jl"))
import PormG: Configuration, Migrations, PormGPostgres, PormGSQLite
import PormG.ConnectionPool: fetch

# Suffixed names: `runtests.jl` includes every unit file into ONE module.
# The error a failed catalog read raises — its own type, so the assertion cannot be satisfied by any
# other failure on the way (a missing models file, a bad ignore list).
struct CatalogReadFailed1018 <: Exception
    msg::String
end

struct FailingMockPg1018 <: PormGPostgres end
fetch(::FailingMockPg1018, sql::String; conn = nothing, params = nothing, ignore_tx::Bool = false) =
    throw(CatalogReadFailed1018("catalog unreachable"))

struct FailingMockSqlite1018 <: PormGSQLite end
fetch(::FailingMockSqlite1018, sql::String; conn = nothing, params = nothing, ignore_tx::Bool = false) =
    throw(CatalogReadFailed1018("catalog unreachable"))

# An empty catalog: every reader query comes back with no rows.
struct EmptyMockPg1018 <: PormGPostgres end
fetch(::EmptyMockPg1018, sql::String; conn = nothing, params = nothing, ignore_tx::Bool = false) = DataFrame()

# One F1 table, so an empty database has something to plan.
function _rf1018_write_models(path::AbstractString)
    write(path, "module models\nimport PormG.Models\n" *
                "Circuit1018 = Models.Model(\n    id = Models.IDField(),\n" *
                "    name = Models.CharField(null = true)\n)\nend\n")
end

# Runs `makemigrations` for `conn` in a fresh folder; returns the pending plan's path and the result.
function _rf1018_plan(conn, folder::AbstractString, dir::AbstractString)
    mkpath(folder)
    models_path = joinpath(dir, folder, "models.jl")
    _rf1018_write_models(models_path)
    settings = Configuration.Settings(connections = conn, db_def_folder = folder)
    settings.change_db = true
    pending = joinpath(folder, "migrations", "pending_migrations.jl")
    plan!() = with_logger(NullLogger()) do
        Migrations.makemigrations(conn, settings; path = models_path, interactive = false)
    end
    return pending, plan!
end

# ─────────────────────────────────────────────────────────────────────────────
# A failed read raises, on both engines
# The regression: before #1018 each call below logged the error and returned `nothing`, so
# `@test_throws` failed. The plan must not be written either — there is nothing to diff against.
# ─────────────────────────────────────────────────────────────────────────────
@testset "makemigrations raises when the live schema cannot be read (#1018)" begin
    dir = mktempdir()
    try
        cd(dir) do
            for (engine, conn) in (("PostgreSQL", FailingMockPg1018()), ("SQLite", FailingMockSqlite1018()))
                @testset "$engine" begin
                    pending, plan! = _rf1018_plan(conn, "db1018_fail_$(lowercase(engine))", dir)
                    # The read's own error reaches the caller, not a log line.
                    err = try
                        plan!()
                        nothing
                    catch e
                        e
                    end
                    @test err isa CatalogReadFailed1018
                    @test err isa CatalogReadFailed1018 && err.msg == "catalog unreachable"
                    # And no plan was written.
                    @test !isfile(pending)
                end
            end
        end
    finally
        rm(dir; recursive = true, force = true)
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# An empty database is not a failure: it plans every model
# The dead arm's premise was that an empty database raises. It does not: an empty catalog reads as
# no tables. This passes before and after #1018 — it pins the behavior the arm's removal relies on.
# ─────────────────────────────────────────────────────────────────────────────
@testset "makemigrations on an empty PostgreSQL database plans every model (#1018)" begin
    dir = mktempdir()
    try
        cd(dir) do
            pending, plan! = _rf1018_plan(EmptyMockPg1018(), "db1018_empty", dir)
            @test plan!() === nothing
            # The one declared table is created.
            @test isfile(pending)
            @test occursin(r"CREATE TABLE[^\n]*circuit1018", read(pending, String))
        end
    finally
        rm(dir; recursive = true, force = true)
    end
end
