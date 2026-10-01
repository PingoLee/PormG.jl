"""
Migration-history writes bind their values instead of interpolating them (#846).

`_record_migration`, `_update_migration_status` and `remove_migration_record` used to splice
`version`, `name`, `checksum`, `sql_content` and `status` into the SQL text with their quotes
doubled. `version` and `name` reach them from the public repair ops (`mark_applied`,
`mark_failed`, `remove_migration_record`) and `sql_content` is the whole plan's SQL, so that was
caller text in a SQL string — the one thing the parameterized-queries rule forbids. Quote-doubling
is not a defence on PostgreSQL with `standard_conforming_strings = off`, where `\\'` ends the
literal.

Two kinds of assertion, because they fail differently:

  * the round trips prove the bound statements are correct — placeholders and values line up and
    hostile text comes back byte for byte. On SQLite they would ALSO pass against the old
    quote-doubled SQL (doubling is sound there), so on their own they cannot tell the fix apart;
  * the source guard is the assertion that does: it fails while any history write still doubles
    quotes into an interpolated literal.

Hermetic: in-memory SQLite, `pool_size = 1` (the #545 rule — a wider `:memory:` pool is N
databases). The PostgreSQL arm (`\$n` placeholders through LibPQ) runs in
`test/integration/test_migration_bootstrap.jl`, Phase 13.

julia --project=test/integration test/unit/test_migration_history_binding.jl
"""

using Test
using PormG
using PormG.Migrations
import DataFrames: DataFrame, nrow

# Needs the real SQLite extension (runtests.jl loads it too; re-loading is idempotent).
include(joinpath(@__DIR__, "..", "load_drivers.jl"))

const _HB_CP = PormG.ConnectionPool

# Every character a hand-built literal has to survive: a quote, both placeholder spellings, a
# comment opener and a statement terminator. Short enough for the 17-char `version` column.
const _HB_VERSION = "v'1\$1?--;"
const _HB_NAME    = "o'brien \$2 ? -- '); DROP TABLE pormg_migrations; --"

# Every key `_hb_pool` registers, removed from the global `PormG.config` after the run.
const _HB_KEYS = String[]

function _hb_pool(key::String)
  push!(_HB_KEYS, key)
  pool = _HB_CP.SQLiteConnectionPool(":memory:"; pool_size = 1)
  PormG.config[key] = PormG.Configuration.Settings(
      connections = pool, change_data = true, db_def_folder = key)
  Migrations.init_migrations(pool)
  pool
end

# Read one history row back through a BOUND select, so the read cannot share a quoting defect with
# the write it is checking.
function _hb_row(pool, version::String)
  df = DataFrame(_HB_CP.fetch(pool,
    """SELECT "version", "name", "checksum", "sql_content", "status", "is_destructive"
       FROM pormg_migrations WHERE "version" = ?;"""; params = Any[version]))
  nrow(df) == 0 ? nothing : df[1, :]
end

# A PostgreSQL probe pool: its `with_transaction` extends the generic the runner calls and records
# what it was handed — the statement, the value vector, and whether release was asked for. Nothing
# reaches a server.
struct _HBProbePg846 <: PormG.PormGPostgres end
const _HB_PG_LOG = Tuple{String, Any, Bool}[]
function _HB_CP.with_transaction(::_HBProbePg846, sql::String; conn = nothing,
                                 release_conn::Bool = false, params = nothing)
  push!(_HB_PG_LOG, (sql, params, release_conn))
  return DataFrame(), :probe_conn
end

@testset "Migration history writes bind their values (#846)" begin

  # ───────────────────────────────────────────────────────────────────────────
  # Source guard: no history write doubles quotes into an interpolated literal.
  # The one assertion here that fails on the pre-#846 runner — see the file header for why the
  # round trips below cannot. It scans for the doubling idiom itself, which every one of the old
  # writes used, rather than for a function name a refactor could move.
  # ───────────────────────────────────────────────────────────────────────────
  @testset "runner.jl interpolates no quote-doubled literal" begin
    src = read(joinpath(pkgdir(PormG), "src", "migrations", "runner.jl"), String)
    @test count("\"'\" => \"''\"", src) == 0
  end

  # ───────────────────────────────────────────────────────────────────────────
  # Templates: each history write has a parameterized statement per engine, and the INSERT's
  # placeholder count matches the seven values `_record_migration` binds. PostgreSQL cannot run
  # here, so the count is what catches a template and a value vector drifting apart on that engine.
  # ───────────────────────────────────────────────────────────────────────────
  @testset "history templates carry one placeholder per bound value" begin
    struct _HBMockPG <: PormG.PormGPostgres end
    struct _HBMockSL <: PormG.PormGSQLite end
    pg, sl = _HBMockPG(), _HBMockSL()
    D = PormG.Dialect

    @test length(collect(eachmatch(r"\$\d+", D.insert_migration_record_sql(pg)))) == 7
    @test count('?', D.insert_migration_record_sql(sl)) == 7
    @test length(collect(eachmatch(r"\$\d+", D.update_migration_status_sql(pg)))) == 2
    @test count('?', D.update_migration_status_sql(sl)) == 2
    # The DELETE had two identical interpolating branches; it is one template per engine now.
    @test D.delete_migration_record_sql(pg) == """DELETE FROM pormg_migrations WHERE "version" = \$1;"""
    @test D.delete_migration_record_sql(sl) == """DELETE FROM pormg_migrations WHERE "version" = ?;"""
  end

  # ───────────────────────────────────────────────────────────────────────────
  # Repair ops round trip: mark_applied → mark_failed → remove_migration_record on a version and
  # name full of quote, placeholder and comment characters. Each value comes back byte for byte,
  # and each later op finds the row by that same hostile version — a misbound or truncated value
  # would make `_require_recorded_version` refuse it.
  # ───────────────────────────────────────────────────────────────────────────
  @testset "hostile version and name survive every repair op" begin
    pool = _hb_pool("hb846_repair")
    settings = PormG.config["hb846_repair"]
    sql = "DROP TABLE \"it's\"; -- '\$1' ?"

    Migrations.mark_applied(pool, settings, _HB_VERSION, _HB_NAME; sql_content = sql)
    row = _hb_row(pool, _HB_VERSION)
    @test row !== nothing
    @test row[:version] == _HB_VERSION
    @test row[:name] == _HB_NAME
    @test row[:sql_content] == sql
    @test row[:checksum] == Migrations.compute_checksum(sql)
    @test row[:status] == "applied"
    # A DROP is destructive; SQLite stores the flag as the integer it always has (1/0).
    @test row[:is_destructive] == 1
    # The history table is still the only thing touched — the DROP in `name` did not run.
    @test nrow(DataFrame(_HB_CP.fetch(pool, "SELECT * FROM pormg_migrations;"))) == 1

    Migrations.mark_failed(pool, settings, _HB_VERSION)
    @test _hb_row(pool, _HB_VERSION)[:status] == "failed"

    Migrations.remove_migration_record(pool, settings, _HB_VERSION)
    @test _hb_row(pool, _HB_VERSION) === nothing
  end

  # ───────────────────────────────────────────────────────────────────────────
  # Connection ownership: `_record_migration` releases a connection only when it acquired one
  # (`release_conn = conn === nothing`, the #203-era contract Phase 13 pins on a real backend).
  # On the caller's connection, inside the caller's transaction, it must leave the lease alone —
  # and the write must belong to that transaction, so a ROLLBACK removes it.
  # ───────────────────────────────────────────────────────────────────────────
  @testset "_record_migration releases only the connection it acquired" begin
    pool = _hb_pool("hb846_conn")
    @test _HB_CP.pool_stats(pool).in_use == 0

    # No conn: acquires, writes, releases.
    Migrations._record_migration(pool, "20310101000000000", "own_conn", "c", "-- sql", "applied", false)
    @test _HB_CP.pool_stats(pool).in_use == 0
    @test _hb_row(pool, "20310101000000000")[:is_destructive] == 0

    # Caller's conn, inside the caller's transaction: still leased afterwards, and rolled back with it.
    _, conn = _HB_CP.with_transaction(pool, "BEGIN IMMEDIATE TRANSACTION;")
    try
      Migrations._record_migration(pool, "20310101000001000", "tx_conn", "c", "-- sql", "applied", false;
                                   conn = conn)
      @test _HB_CP.pool_stats(pool).in_use == 1
      _HB_CP.with_transaction(pool, "ROLLBACK;"; conn = conn)
    finally
      _HB_CP.release_connection(pool, conn)
    end
    @test _HB_CP.pool_stats(pool).in_use == 0
    @test _hb_row(pool, "20310101000001000") === nothing
  end

  # ───────────────────────────────────────────────────────────────────────────
  # with_transaction takes a raw value vector, as `fetch` does since #218, and normalizes it the
  # same way: `nothing` binds as NULL. This is what lets a history write bind on a connection the
  # caller holds — `fetch(…; conn)` would hand that connection back to the pool (#139).
  # ───────────────────────────────────────────────────────────────────────────
  @testset "with_transaction binds a raw value vector" begin
    pool = _hb_pool("hb846_raw")
    rows, _ = _HB_CP.with_transaction(pool, "SELECT ? AS a, ? AS b;";
                                      params = Any["it's", nothing], release_conn = true)
    df = DataFrame(rows)
    @test df[1, :a] == "it's"
    @test ismissing(df[1, :b])
    @test _HB_CP.pool_stats(pool).in_use == 0
  end

  # ───────────────────────────────────────────────────────────────────────────
  # with_transaction: a raw value SQLite refuses to bind (#721) still releases a caller's
  # connection when the caller asked for `release_conn = true`. The normalization runs inside the
  # statement's `try`, so the release in its `finally` covers it like any driver failure.
  # ───────────────────────────────────────────────────────────────────────────
  @testset "with_transaction releases on a refused raw value" begin
    pool = _hb_pool("hb846_refused")
    conn = _HB_CP.acquire_connection(pool; mode = :write)
    @test _HB_CP.pool_stats(pool).in_use == 1
    @test_throws PormG.InvalidValueError _HB_CP.with_transaction(pool, "SELECT ? AS a;";
        conn = conn, release_conn = true, params = Any[1 // 2])
    @test _HB_CP.pool_stats(pool).in_use == 0
  end

  # ───────────────────────────────────────────────────────────────────────────
  # PostgreSQL probe: what the two writers hand the driver. No server runs here, so a probe pool
  # records the statement and the value vector instead. This pins the PostgreSQL side at unit level —
  # the `$n` template and the seven values in column order, `is_destructive` as a `Bool` for the
  # BOOLEAN column — and fails on the pre-#846 code for a reason other than a text match: it sent the
  # values inside the SQL and no `params` at all.
  # ───────────────────────────────────────────────────────────────────────────
  @testset "PostgreSQL writers bind the template's values in order" begin
    empty!(_HB_PG_LOG)
    pg = _HBProbePg846()
    D = PormG.Dialect

    Migrations._record_migration(pg, _HB_VERSION, _HB_NAME, "sum", "-- sql", "applied", true)
    sql, params, release = _HB_PG_LOG[end]
    @test sql == D.insert_migration_record_sql(pg)
    @test params == Any[_HB_VERSION, _HB_NAME, "sum", "-- sql", "applied", true,
                        Migrations.MIGRATION_FORMAT_VERSION]
    @test params[6] isa Bool
    # No caller connection, so the writer asked for its own to be released (#203).
    @test release

    Migrations._update_migration_status(pg, _HB_VERSION, "failed"; conn = :tx_conn)
    sql, params, release = _HB_PG_LOG[end]
    @test sql == D.update_migration_status_sql(pg)
    @test params == Any["failed", _HB_VERSION]
    # The caller owns the connection, so the writer leaves it leased.
    @test !release
  end
end

foreach(k -> delete!(PormG.config, k), _HB_KEYS)
