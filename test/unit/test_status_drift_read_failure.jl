# =============================================================================
# status() reports a failed live-table read as a drift signal (#1076)
#
# `status()` checks for recorded migrations over a database with no user tables, which reads the
# live table list. When that read failed, the `catch` logged at `@debug` and moved on, so the result
# carried no drift signal: the same as a database with no drift. `status()` is advisory and still
# does not throw; it now says the check could not look, naming the error type and never the server
# text (#1010).
#
# Hermetic: mock connections that answer the history reads and fail (or answer) the live one, and a
# temporary config folder. No live database.
# =============================================================================
# julia --project=test/integration test/unit/test_status_drift_read_failure.jl

using Test
using DataFrames
using PormG
# The SQLite mock reads its table list through the weakdep extension (`backend_sqlite_version`).
# `runtests.jl` loads it for the whole suite; this guard is what makes the file runnable alone.
isdefined(Main, :SQLite) || include(joinpath(@__DIR__, "..", "load_drivers.jl"))
import PormG: Configuration, Migrations, Dialect, PormGPostgres, PormGSQLite
import PormG.ConnectionPool: fetch

# Suffixed names: `runtests.jl` includes every unit file into ONE module.
# Its own type, so the assertion cannot be satisfied by another failure on the way. The message
# stands in for server text, which must not reach the signal.
struct LiveReadFailed1076 <: Exception
    msg::String
end

struct StatusMockPg1076 <: PormGPostgres
    fail::Bool
end
struct StatusMockSqlite1076 <: PormGSQLite
    fail::Bool
end

const _SD1076_SERVER_TEXT = "relation pg_class: permission denied (server text)"

# One applied migration, so the live-table check runs at all.
_sd1076_history() = DataFrame(version = ["20260101000000"], name = ["initial"], checksum = ["abc"],
                              status = ["applied"], is_destructive = [false])

# The PostgreSQL live-table read asks the server version first (#1163), by this exact statement.
const _SD1076_PG_VERSION_SQL = "SELECT current_setting('server_version_num')::integer AS v"

# Answers the history reads and the version read by their exact SQL; any other statement is the
# live-table read, so the failing mock fails there and not on a statement in front of it.
function _sd1076_fetch(c, sql::String, yes)
    sql == Dialect.migrations_table_exists_sql(c) && return DataFrame(x = [yes])
    sql == Dialect.select_all_migrations_sql(c) && return _sd1076_history()
    sql == Dialect.data_steps_table_exists_sql(c) && return DataFrame(x = [zero(yes)])
    # The PostgreSQL fixture stands for PostgreSQL 16.
    sql == _SD1076_PG_VERSION_SQL && return DataFrame(v = [160000])
    c.fail && throw(LiveReadFailed1076(_SD1076_SERVER_TEXT))
    # A database holding one user table: no drift to report.
    occursin("pragma_table_list", sql) && return DataFrame(name = ["circuit"], type = ["table"])
    occursin("sqlite_master", sql) && return DataFrame(name = ["circuit"], sql = ["CREATE TABLE circuit (id INTEGER)"])
    return DataFrame(table_name = ["circuit"])
end
fetch(c::StatusMockPg1076, sql::String; conn = nothing, params = nothing, ignore_tx::Bool = false) =
    _sd1076_fetch(c, sql, true)
fetch(c::StatusMockSqlite1076, sql::String; conn = nothing, params = nothing, ignore_tx::Bool = false) =
    _sd1076_fetch(c, sql, 1)

function _sd1076_status(conn, folder::AbstractString)
    mkpath(folder)
    settings = Configuration.Settings(connections = conn, db_def_folder = folder)
    return Migrations.status(conn, settings)
end

_sd1076_failed_signals(st) = filter(s -> startswith(s, "Drift detection failed"), st.drift_signals)

# ─────────────────────────────────────────────────────────────────────────────
# A failed live read is a visible drift signal, on both engines
# Expected: status() returns (no throw), with exactly one "Drift detection failed" signal that names
# LiveReadFailed1076 and does not contain the server's message. The regression: before #1076 the
# drift_signals were empty, the same as a healthy database.
# ─────────────────────────────────────────────────────────────────────────────
@testset "status(): a failed live-table read is a drift signal, not a @debug (#1076)" begin
    dir = mktempdir()
    try
        cd(dir) do
            for (engine, conn) in (("PostgreSQL", StatusMockPg1076(true)), ("SQLite", StatusMockSqlite1076(true)))
                @testset "$engine" begin
                    st = _sd1076_status(conn, "db1076_fail_$(lowercase(engine))")
                    @test length(st.applied) == 1
                    sig = _sd1076_failed_signals(st)
                    @test length(sig) == 1
                    @test occursin("LiveReadFailed1076", only(sig))
                    # #1010: server text never reaches the signal.
                    @test !occursin("permission denied", only(sig))
                    @test !occursin("server text", sprint(show, st))
                    # Shown with the other drift signals.
                    @test occursin("Drift detection failed", sprint(show, st))
                end
            end
        end
    finally
        rm(dir; recursive = true, force = true)
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# A successful read over a database with user tables gives no such signal
# Expected: drift_signals is empty. This passes before and after #1076; it pins that the new signal
# is tied to the failed read and not to the check itself.
# ─────────────────────────────────────────────────────────────────────────────
@testset "status(): a readable database with user tables has no drift signal (#1076)" begin
    dir = mktempdir()
    try
        cd(dir) do
            for (engine, conn) in (("PostgreSQL", StatusMockPg1076(false)), ("SQLite", StatusMockSqlite1076(false)))
                @testset "$engine" begin
                    st = _sd1076_status(conn, "db1076_ok_$(lowercase(engine))")
                    @test length(st.applied) == 1
                    @test isempty(st.drift_signals)
                end
            end
        end
    finally
        rm(dir; recursive = true, force = true)
    end
end
