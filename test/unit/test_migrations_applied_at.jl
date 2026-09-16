"""
`pormg_migrations.applied_at` holds the canonical timestamp text on SQLite (#570).

Sibling 3 of the #564 family. The audit table's SQLite DDL defaulted `applied_at` to
`datetime('now')` — `YYYY-MM-DD HH:MM:SS`, no `T`, no fraction, no offset — the one representation
no PormG reader anchors on, while every `DateTimeField` stores `YYYY-MM-DDTHH:MM:SS.sss+00:00`.

Three things had to change, and this file measures each on its own because each fails on its own:

  1. the DDL default, for a table created by this release;
  2. the explicit `applied_at` value every migration-record INSERT writes — because
     `CREATE TABLE IF NOT EXISTS` never revisits an existing table's default, and SQLite cannot
     alter one in place, so a pre-#570 database would otherwise keep writing the old form forever;
  3. the idempotent repair `init_migrations` runs over rows written before the change.

Hermetic: one in-memory SQLite database per scenario (`SQLiteConnectionPool(":memory:";
pool_size = 1)` — the #545 rule, a wider `:memory:` pool is N databases), each registered in
`PormG.config` under its own key. The DDL path against a real file and the PostgreSQL arm are
`test/integration/test_migration_bootstrap.jl`'s (the format-version backfill testset).

julia --project=. test/unit/test_migrations_applied_at.jl
"""

using Test
using PormG
using PormG.Models
using PormG.Migrations
using Dates
import TimeZones
import DataFrames: DataFrame, nrow

# Needs the real SQLite extension (runtests.jl loads it too; re-loading is idempotent).
include(joinpath(@__DIR__, "..", "load_drivers.jl"))

const _MA_CP = PormG.ConnectionPool
const _MA_CANONICAL = r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}\+00:00$"
const _MA_LEGACY    = r"^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}$"

# One fresh in-memory database per scenario, so a repair in one cannot mask a defect in another.
function _ma_pool(key::String)
  pool = _MA_CP.SQLiteConnectionPool(":memory:"; pool_size = 1)
  PormG.config[key] = PormG.Configuration.Settings(
      connections = pool, change_data = true, db_def_folder = key)
  pool
end

# The pre-#570 table, byte for byte what an older release created: `datetime('now')` default and no
# `format_version` column, so `init_migrations` has both repairs to do.
const _MA_LEGACY_DDL = """CREATE TABLE pormg_migrations (
  "id" INTEGER PRIMARY KEY AUTOINCREMENT,
  "version" VARCHAR(17) NOT NULL UNIQUE,
  "name" VARCHAR(255) NOT NULL,
  "checksum" VARCHAR(64) NOT NULL,
  "sql_content" TEXT NOT NULL DEFAULT '',
  "applied_at" DATETIME NOT NULL DEFAULT (datetime('now')),
  "status" VARCHAR(20) NOT NULL DEFAULT 'applied',
  "is_destructive" BOOLEAN NOT NULL DEFAULT 0
);"""

_ma_applied_at(pool, version) = begin
  rows = DataFrame(_MA_CP.fetch(pool,
    """SELECT "applied_at" FROM pormg_migrations WHERE "version" = '$(version)';"""))
  nrow(rows) == 1 || error("expected one row for $(version), got $(nrow(rows))")
  String(rows[1, :applied_at])
end

@testset "pormg_migrations.applied_at canonical form (#570)" begin

  # ───────────────────────────────────────────────────────────────────────────
  # DDL default: a table created by THIS release writes the canonical text when the INSERT
  # omits `applied_at`. Round-trips through the same reader every `DateTimeField` uses — the
  # #564 property, not a shape match.
  # ───────────────────────────────────────────────────────────────────────────
  @testset "a fresh table defaults applied_at to the canonical text" begin
    pool = _ma_pool("ma570_fresh")
    Migrations.init_migrations(pool)
    _MA_CP.fetch(pool, """INSERT INTO pormg_migrations ("version", "name", "checksum")
                          VALUES ('20310704123045123', 'fresh_default', 'x');""")
    stamp = _ma_applied_at(pool, "20310704123045123")
    @test occursin(_MA_CANONICAL, stamp)
    parsed = PormG.Dialect._parse_sqlite_timestamp(stamp)
    @test parsed isa TimeZones.ZonedDateTime
    @test Models.format_timezone_sql(parsed) == stamp
    # Recorded through the runner's own INSERT too — the path `migrate` and `mark_applied` use.
    Migrations._record_migration(pool, "20310704123046000", "fresh_explicit", "y", "-- sql",
                                 "applied", false)
    @test occursin(_MA_CANONICAL, _ma_applied_at(pool, "20310704123046000"))
  end

  # ───────────────────────────────────────────────────────────────────────────
  # Explicit write: a pre-#570 table keeps its `datetime('now')` default forever, so only an
  # INSERT that names `applied_at` can write the canonical text there. Asserted against the
  # stale default directly — an INSERT that omits the column still yields the OLD form on this
  # table, which is what proves the explicit value (and not a rebuilt default) is doing the work.
  # ───────────────────────────────────────────────────────────────────────────
  @testset "_record_migration writes applied_at explicitly under a stale default" begin
    pool = _ma_pool("ma570_stale")
    _MA_CP.fetch(pool, _MA_LEGACY_DDL)
    Migrations.init_migrations(pool)        # adds format_version; cannot alter the default
    # Control: the stale default is still in force after init_migrations.
    _MA_CP.fetch(pool, """INSERT INTO pormg_migrations ("version", "name", "checksum")
                          VALUES ('20310704120000000', 'control_default', 'c');""")
    @test occursin(_MA_LEGACY, _ma_applied_at(pool, "20310704120000000"))
    # The runner's INSERT names the column, so it is canonical regardless of that default.
    Migrations._record_migration(pool, "20310704120001000", "explicit", "e", "-- sql",
                                 "applied", false)
    @test occursin(_MA_CANONICAL, _ma_applied_at(pool, "20310704120001000"))
    # `mark_applied` is the public entry point over the same INSERT; it needs a checksum basis.
    Migrations.mark_applied(pool, PormG.config["ma570_stale"], "20310704120002000", "marked";
                            sql_content = "-- marked after upgrade")
    @test occursin(_MA_CANONICAL, _ma_applied_at(pool, "20310704120002000"))
  end

  # ───────────────────────────────────────────────────────────────────────────
  # Repair: rows written by the old default are rewritten into the canonical text by
  # `init_migrations`, once. The rewrite is `strftime(mask, old)`, so the instant is preserved —
  # `2026-06-04 17:23:01` becomes `2026-06-04T17:23:01.000+00:00`, not "now".
  # ───────────────────────────────────────────────────────────────────────────
  @testset "init_migrations repairs rows in the old form, preserving the instant" begin
    pool = _ma_pool("ma570_repair")
    _MA_CP.fetch(pool, _MA_LEGACY_DDL)
    _MA_CP.fetch(pool, """INSERT INTO pormg_migrations ("version", "name", "checksum", "applied_at")
                          VALUES ('20260604172301000', 'legacy_row', 'l', '2026-06-04 17:23:01');""")
    @test _ma_applied_at(pool, "20260604172301000") == "2026-06-04 17:23:01"
    Migrations.init_migrations(pool)
    @test _ma_applied_at(pool, "20260604172301000") == "2026-06-04T17:23:01.000+00:00"
    # The repaired text reads back as the instant the old text denoted.
    parsed = PormG.Dialect._parse_sqlite_timestamp(_ma_applied_at(pool, "20260604172301000"))
    @test parsed == TimeZones.ZonedDateTime(2026, 6, 4, 17, 23, 1, TimeZones.tz"UTC")
  end

  # ───────────────────────────────────────────────────────────────────────────
  # Idempotence: a second `init_migrations` leaves every row byte-identical — a canonical row is
  # never touched (the `NOT GLOB '*T*'` guard), and an already-repaired row is canonical. A value
  # `strftime` cannot parse is left alone rather than nulled under `NOT NULL`.
  # ───────────────────────────────────────────────────────────────────────────
  @testset "the repair is idempotent and leaves unparseable text alone" begin
    pool = _ma_pool("ma570_idempotent")
    _MA_CP.fetch(pool, _MA_LEGACY_DDL)
    _MA_CP.fetch(pool, """INSERT INTO pormg_migrations ("version", "name", "checksum", "applied_at") VALUES
      ('20260604172301000', 'legacy_row',    'l', '2026-06-04 17:23:01'),
      ('20310704123045123', 'canonical_row', 'c', '2031-07-04T12:30:45.123+00:00'),
      ('20250101000000000', 'garbage_row',   'g', 'not a timestamp');""")
    # The probe sees the legacy row before the first pass…
    probe() = nrow(DataFrame(_MA_CP.fetch(pool, PormG.Dialect.legacy_applied_at_exists_sql(pool))))
    @test probe() == 1
    Migrations.init_migrations(pool)
    first_pass = Dict(v => _ma_applied_at(pool, v) for v in
                      ("20260604172301000", "20310704123045123", "20250101000000000"))
    @test first_pass["20260604172301000"] == "2026-06-04T17:23:01.000+00:00"
    @test first_pass["20310704123045123"] == "2031-07-04T12:30:45.123+00:00"   # untouched
    @test first_pass["20250101000000000"] == "not a timestamp"                 # left alone, not NULL
    # …and nothing after it: the unparseable row must not keep the probe hot, or every later
    # `init_migrations` would issue a write for a row it can never repair.
    @test probe() == 0
    Migrations.init_migrations(pool)
    for (v, text) in first_pass
      @test _ma_applied_at(pool, v) == text
    end
  end

  # ───────────────────────────────────────────────────────────────────────────
  # Read-only database: a no-op `init_migrations` must stay a no-op. SQLite opens the write
  # transaction at `UPDATE` statement start even when the WHERE matches nothing, so an
  # unconditional repair would fail with "attempt to write a readonly database" on a file the
  # process may only read — review finding on #570. The table already carries `format_version`
  # and a canonical row, so every step of `init_migrations` has nothing to write.
  # ───────────────────────────────────────────────────────────────────────────
  @testset "init_migrations on a read-only file with nothing to repair does not write" begin
    # `chmod 0o444` is void for root, where the unpatched code would pass too. Skip loudly
    # rather than record a hollow pass; CI runs unprivileged (no `container:` job) so this only
    # fires in an ad-hoc root shell.
    if !Sys.iswindows() && ccall(:geteuid, Cuint, ()) == 0
      @info "read-only applied_at scenario skipped: running as root, chmod cannot deny writes"
    else
      dir = mktempdir()
      path = joinpath(dir, "readonly.sqlite")
      seed = _MA_CP.SQLiteConnectionPool(path; pool_size = 1)
      _MA_CP.fetch(seed, PormG.Dialect.create_migrations_table(seed))
      _MA_CP.fetch(seed, """INSERT INTO pormg_migrations ("version", "name", "checksum", "applied_at")
                            VALUES ('20310704123045123', 'canonical_row', 'c', '2031-07-04T12:30:45.123+00:00');""")
      _MA_CP.close_pool!(seed)
      chmod(path, 0o444)
      pool = nothing
      try
        pool = _MA_CP.SQLiteConnectionPool(path; pool_size = 1)
        PormG.config["ma570_readonly"] = PormG.Configuration.Settings(
            connections = pool, change_data = true, db_def_folder = "ma570_readonly")
        # Nothing to repair, so no write is attempted and the call succeeds on the read-only file.
        @test Migrations.init_migrations(pool) === nothing
        @test _ma_applied_at(pool, "20310704123045123") == "2031-07-04T12:30:45.123+00:00"
      finally
        # Close before `rm`: an open handle makes the removal itself fail on Windows and would
        # mask the real failure with a filesystem error.
        pool === nothing || _MA_CP.close_pool!(pool)
        chmod(path, 0o644)
        rm(dir; recursive = true, force = true)
      end
    end
  end
end

# The scenario keys are registered in the shared `PormG.config`; drop them so a later unit file
# resolving connect keys does not see four `:memory:` pools it never registered.
for key in ("ma570_fresh", "ma570_stale", "ma570_repair", "ma570_idempotent", "ma570_readonly")
  delete!(PormG.config, key)
end
