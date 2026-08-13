"""
Unit coverage for #358: row-level writers (`create`/`insert`, `update_or_create`, `get_or_create`)
no longer auto-resync a PostgreSQL sequence after an explicit-primary-key write, and the new public
`resync_sequences(model)` / `resync_sequences(models)` covers the gap that leaves — repairing a
sequence explicitly, without an accompanying insert.

`bulk_insert`/`bulk_copy` keep their own automatic resync unconditionally (see
test_sequence_sync.jl / test_bulk_on_conflict.jl); this file does not touch those paths.

No live database required for the PostgreSQL half (mocked `fetch`, mirroring
test_sequence_sync.jl's `MockSequencePostgres` pattern). The SQLite half uses a real hermetic temp
database — `sqlite_sequence` semantics are simpler to prove for real than to mock faithfully.
"""

using Test
using DataFrames
using PormG
using PormG.Models: Model, CharField, IDField
import PormG.ConnectionPool: fetch, SQLiteConnectionPool
using PormG: resync_sequences

# ─────────────────────────────────────────────────────────────────────────────
# PostgreSQL mock: records every SQL statement so a test can assert resync
# machinery (`pg_get_serial_sequence` / `setval`) did or did not run.
# ─────────────────────────────────────────────────────────────────────────────
RowLevelDriver = Model("row_level_drivers", id = IDField(), forename = CharField())
RowLevelDriver.connect_key = "resync_row_level_pg"

RowLevelDriver2 = Model("row_level_drivers2", id = IDField(), forename = CharField())
RowLevelDriver2.connect_key = "resync_row_level_pg"

NoPkScratch = Model("resync_no_pk_scratch", forename = CharField())
NoPkScratch.connect_key = "resync_row_level_pg"

struct MockRowLevelPostgres <: PormG.PormGPostgres end
const ROW_LEVEL_SQL = String[]

function fetch(connection::MockRowLevelPostgres, sql::String;
  conn = nothing,
  params = nothing,
  ignore_tx::Bool = false)
  push!(ROW_LEVEL_SQL, sql)

  if occursin("RETURNING", sql)
    # Answers insert()'s "RETURNING *", update_or_create()'s "RETURNING *, (xmax=0) AS
    # __pormg_created", and get_or_create()'s "... ON CONFLICT DO NOTHING RETURNING *" alike —
    # _row_to_field_keyed_dict converts whatever columns are present with no strict validation
    # against model.fields, so the extra __pormg_created column is harmless when unused.
    return DataFrame(:id => [5], :forename => ["Max"], Symbol("__pormg_created") => [true])
  elseif occursin("pg_get_serial_sequence", sql)
    return DataFrame(pg_get_serial_sequence = ["public.row_level_drivers_id_seq"])
  elseif occursin("setval", sql)
    return DataFrame(setval = [6])
  end

  return DataFrame()   # get_or_create's pre-check / raced read-back SELECT — nothing exists yet
end

PormG.config["resync_row_level_pg"] = PormG.Configuration.Settings(
  connections = MockRowLevelPostgres(),
  change_data = true,
)

_no_resync_sql(sqls) = !any(sql -> occursin("pg_get_serial_sequence", sql) || occursin("setval", sql), sqls)

# ─────────────────────────────────────────────────────────────────────────────
# The core regression: going through the PUBLIC fluent API for each row-level writer with an
# explicit primary key must NOT touch sequence-resync machinery anymore.
# ─────────────────────────────────────────────────────────────────────────────
@testset "row-level writers no longer auto-resync (#358)" begin
  empty!(ROW_LEVEL_SQL)
  RowLevelDriver.objects.create("id" => 5, "forename" => "Max")
  @test !isempty(ROW_LEVEL_SQL)     # sanity: the create actually ran
  @test _no_resync_sql(ROW_LEVEL_SQL)

  empty!(ROW_LEVEL_SQL)
  RowLevelDriver.objects.update_or_create("id" => 5; defaults = ["forename" => "Max"])
  @test !isempty(ROW_LEVEL_SQL)
  @test _no_resync_sql(ROW_LEVEL_SQL)

  empty!(ROW_LEVEL_SQL)
  RowLevelDriver.objects.get_or_create("id" => 5; defaults = ["forename" => "Max"])
  @test !isempty(ROW_LEVEL_SQL)
  @test _no_resync_sql(ROW_LEVEL_SQL)
end

# ─────────────────────────────────────────────────────────────────────────────
# Same proof on SQLite, against a real hermetic temp database. Deliberately NOT an AUTOINCREMENT
# column: SQLite's own AUTOINCREMENT bookkeeping updates `sqlite_sequence` natively on ANY insert
# (explicit pk or not) as a side effect of the constraint itself, independent of PormG entirely —
# so an AUTOINCREMENT table can't distinguish "SQLite did it" from "_update_sequence did it". A
# plain `INTEGER PRIMARY KEY` (no AUTOINCREMENT) is never touched by SQLite itself, and this
# database has no AUTOINCREMENT table anywhere, so `sqlite_sequence` does not exist at all yet.
# PormG's `_update_sequence` does not check for the keyword, or create the table, before writing
# to it — pre-#358, the automatic call from this exact create() would have thrown
# "no such table: sqlite_sequence" (it has no try/catch on the SQLite side), crashing an insert
# that otherwise succeeded. Post-#358 `sqlite_sequence` simply never comes up, since row-level
# writers no longer call it at all.
# ─────────────────────────────────────────────────────────────────────────────
@testset "SQLite row-level writers no longer auto-resync (#358)" begin
  mktempdir() do dir
    pool = SQLiteConnectionPool(joinpath(dir, "resync_rowlevel.sqlite"); pool_size = 1)
    key = "resync_row_level_sqlite"
    PormG.config[key] = PormG.Configuration.Settings(
      connections   = pool,
      db_def_folder = dir,
      change_data   = true,
    )
    try
      fetch(pool, "CREATE TABLE rl_sqlite (id INTEGER PRIMARY KEY, forename TEXT);")
      m = Model("rl_sqlite", id = IDField(), forename = CharField())
      m.connect_key = key

      m.objects.create("id" => 100, "forename" => "Max")

      # `sqlite_sequence` is itself created lazily by SQLite, only the first time an AUTOINCREMENT
      # table is touched — with none in this database, its continued absence is the strongest
      # possible proof nothing (SQLite natively, or _update_sequence) ever wrote to it.
      exists = fetch(pool, "SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'sqlite_sequence';") |> DataFrame
      @test nrow(exists) == 0   # _update_sequence never ran — the table doesn't even exist
    finally
      delete!(PormG.config, key)
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# The gap #358 fills: resync_sequences(model) performs the repair standalone.
# ─────────────────────────────────────────────────────────────────────────────
@testset "resync_sequences(model) performs the repair and returns the pk field name(s)" begin
  empty!(ROW_LEVEL_SQL)
  result = resync_sequences(RowLevelDriver)
  @test result == ["id"]
  @test any(sql -> occursin("pg_get_serial_sequence", sql), ROW_LEVEL_SQL)
  @test any(sql -> occursin("setval", sql), ROW_LEVEL_SQL)

  # The SQLObjectHandler form (M.Model.objects) resolves identically.
  empty!(ROW_LEVEL_SQL)
  result2 = resync_sequences(RowLevelDriver.objects)
  @test result2 == ["id"]
  @test any(sql -> occursin("setval", sql), ROW_LEVEL_SQL)
end

@testset "resync_sequences(models) resyncs each and returns nothing" begin
  empty!(ROW_LEVEL_SQL)
  out = resync_sequences([RowLevelDriver, RowLevelDriver2])
  @test out === nothing
  @test count(sql -> occursin("pg_get_serial_sequence", sql), ROW_LEVEL_SQL) == 2
  @test count(sql -> occursin("setval", sql), ROW_LEVEL_SQL) == 2
end

@testset "resync_sequences on a model with no primary key issues no SQL" begin
  empty!(ROW_LEVEL_SQL)
  result = resync_sequences(NoPkScratch)
  @test result == String[]
  @test isempty(ROW_LEVEL_SQL)   # the early return — not a repair that happened to find nothing
end

@testset "resync_sequences respects change_data = false" begin
  PormG.config["resync_no_write"] = PormG.Configuration.Settings(
    connections = MockRowLevelPostgres(),
    change_data = false,
  )
  m = Model("row_level_drivers", id = IDField(), forename = CharField())
  m.connect_key = "resync_no_write"
  try
    @test_throws PormG.WritesDisabledError resync_sequences(m)
  finally
    delete!(PormG.config, "resync_no_write")
  end
end

@testset "resync_sequences(model) on SQLite repairs sqlite_sequence" begin
  mktempdir() do dir
    pool = SQLiteConnectionPool(joinpath(dir, "resync_explicit.sqlite"); pool_size = 1)
    key = "resync_explicit_sqlite"
    PormG.config[key] = PormG.Configuration.Settings(
      connections   = pool,
      db_def_folder = dir,
      change_data   = true,
    )
    try
      # AUTOINCREMENT here (unlike the testset above): sqlite_sequence must already exist for
      # _update_sequence's SQLite implementation to UPDATE it (it does not create the table itself).
      # To still prove resync_sequences — not SQLite's own native tracking — did the work, corrupt
      # the value by hand afterward: nothing but an actual resync recomputing MAX(pk) could correct
      # it back. SQLite's own bookkeeping never revisits a row once written.
      fetch(pool, "CREATE TABLE rl_explicit (id INTEGER PRIMARY KEY AUTOINCREMENT, forename TEXT);")
      m = Model("rl_explicit", id = IDField(), forename = CharField())
      m.connect_key = key

      m.objects.create("id" => 100, "forename" => "Max")   # no auto-resync (#358, pinned above)
      fetch(pool, "UPDATE sqlite_sequence SET seq = 1 WHERE name = 'rl_explicit';")  # deliberately stale
      corrupted = fetch(pool, "SELECT seq FROM sqlite_sequence WHERE name = 'rl_explicit';") |> DataFrame
      @test corrupted[1, :seq] == 1   # sanity: the corruption took

      resync_sequences(m)       # explicit repair — recomputes from MAX(pk), overwriting the corruption

      seq = fetch(pool, "SELECT seq FROM sqlite_sequence WHERE name = 'rl_explicit';") |> DataFrame
      @test nrow(seq) == 1
      @test seq[1, :seq] == 100   # corrected back — only resync_sequences could have done this
    finally
      delete!(PormG.config, key)
    end
  end
end
