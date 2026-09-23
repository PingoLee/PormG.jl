# ============================================================
# test/unit/test_bulk_row_counts.jl
#
# The bulk terminals report how many rows they affected (#670).
#
# CONTRACT being tested:
#   Under `show_query = :execute`, `bulk_insert`, `bulk_update` and `bulk_copy` return
#   `(count = n::Int, rows = nothing)`, where `n` is the rows affected, summed across every chunk:
#     - bulk_insert: rows inserted. With `on_conflict = :nothing`, skipped rows are NOT counted.
#     - bulk_update: rows matched by the merge condition, the handler's scope and `filters=`.
#     - bulk_copy:   rows copied (the `COPY n` command tag).
#   An empty DataFrame returns `(count = 0, rows = nothing)`. `rows` is the slot #671's
#   `returning=` fills, so it is part of the shape now.
#
#   Before #670 all three returned `nothing`, so 10,000 matched rows and 0 looked the same.
#
# Hermetic: the SQLite half runs against a real temp database (the count there is `changes()`,
# which is simpler to prove for real than to mock), and the PostgreSQL half uses a mock pool
# whose driver count is scripted per statement.
# ============================================================

using Test
using DataFrames
using PormG
using PormG.Models: Model, CharField, IDField, IntegerField
using PormG.QueryBuilder: bulk_insert, bulk_update, bulk_copy
import PormG.ConnectionPool: fetch, SQLiteConnectionPool

# Run `f(pool, key)` against a fresh temp SQLite database registered under its own config key, then
# tear everything down. `results` gets a UNIQUE constraint on (driver, year) so a conflicting insert
# can be built without touching the primary key; `id` is AUTOINCREMENT so an explicit-pk insert makes
# `_update_sequence` write `sqlite_sequence` — the statement that would overwrite `changes()` if the
# count were taken after it.
function brc670_with_sqlite(f)
  mktempdir() do dir
    pool = SQLiteConnectionPool(joinpath(dir, "brc670.sqlite"); pool_size = 1)
    key = "brc670_sqlite"
    PormG.config[key] = PormG.Configuration.Settings(
      connections = pool, db_def_folder = dir, change_data = true)
    try
      fetch(pool, """CREATE TABLE brc670_result (
        id INTEGER PRIMARY KEY AUTOINCREMENT, driver TEXT NOT NULL,
        year INTEGER NOT NULL, points INTEGER NOT NULL, UNIQUE (driver, year));""")
      model = Model("brc670_result",
        id = IDField(), driver = CharField(), year = IntegerField(), points = IntegerField())
      model.connect_key = key
      f(pool, model)
    finally
      delete!(PormG.config, key)
      # Release the SQLite handle so mktempdir can delete the temp DB on Windows (WAL keeps it open).
      PormG.ConnectionPool.close_pool!(pool)
    end
  end
end

# The 1988 season, five results — enough for three chunks at chunk_size = 2.
brc670_season() = DataFrame(
  driver = ["Senna", "Prost", "Berger", "Alboreto", "Piquet"],
  year   = fill(1988, 5),
  points = [9, 6, 4, 3, 2])

@testset "bulk terminals return affected-row counts (#670)" begin

  # ─────────────────────────────────────────────────────────────────────────────
  # SQLite bulk_insert: the count is summed across chunks.
  # Five rows at chunk_size = 2 are three INSERT statements; a count taken from the last chunk
  # alone would be 1, and the pre-#670 return was `nothing`.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "SQLite bulk_insert sums its chunks" begin
    brc670_with_sqlite() do pool, model
      r = bulk_insert(model.objects, brc670_season(); chunk_size = 2)
      @test r == (count = 5, rows = nothing)
      @test r.count isa Int
      # The count is the rows really written, not the frame's length restated.
      @test (fetch(pool, "SELECT COUNT(*) AS n FROM brc670_result;") |> DataFrame).n[1] == 5
    end
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # SQLite bulk_insert with an explicit primary key: counted before the sequence sync.
  # An explicit `id` makes `_update_sequence` run after the INSERT and write `sqlite_sequence`.
  # Those statements reset `changes()` (the last one inserts nothing), so counting after the sync
  # reports 0 rows for 3.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "SQLite bulk_insert counts before the sequence sync" begin
    brc670_with_sqlite() do pool, model
      df = DataFrame(id = [10, 11, 12], driver = ["Senna", "Prost", "Berger"],
                     year = fill(1988, 3), points = [9, 6, 4])
      @test bulk_insert(model.objects, df).count == 3
      # Precondition: the sync really ran, so the ordering above was actually exercised.
      seq = fetch(pool, "SELECT seq FROM sqlite_sequence WHERE name = 'brc670_result';") |> DataFrame
      @test seq.seq[1] == 12
    end
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # SQLite bulk_insert with on_conflict = :nothing: skipped duplicates are not counted.
  # Two of the five rows already exist, so three are inserted; `nrow(df) - count` is how many
  # were duplicates, which is the question the issue says the count must answer.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "SQLite on_conflict = :nothing counts inserted rows only" begin
    brc670_with_sqlite() do pool, model
      bulk_insert(model.objects, brc670_season()[1:2, :])      # Senna, Prost already present
      r = bulk_insert(model.objects, brc670_season(); on_conflict = :nothing, chunk_size = 2)
      @test r.count == 3
      @test nrow(brc670_season()) - r.count == 2
    end
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # SQLite bulk_update: matched rows summed across chunks, and a zero match reports 0.
  # The zero-match cases are the "silent no-op" #670 exists for: a handler scoped to a season the
  # frame's keys do not belong to (#665), and a `filters=` predicate that matches nothing.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "SQLite bulk_update counts matched rows" begin
    brc670_with_sqlite() do pool, model
      bulk_insert(model.objects, brc670_season())
      rescored = transform(brc670_season(), :points => ByRow(p -> p + 1) => :points)
      keys = ["driver", "year"]

      # Three chunks, all five rows matched.
      r = bulk_update(model.objects, rescored; columns = ["points"], match_on = keys, chunk_size = 2)
      @test r == (count = 5, rows = nothing)

      # Only rows whose key exists count: two of these three drivers never raced here.
      partial = DataFrame(driver = ["Senna", "Mansell", "Patrese"], year = fill(1988, 3), points = [1, 1, 1])
      @test bulk_update(model.objects, partial; columns = ["points"], match_on = keys).count == 1

      # A handler scoped to another season matches nothing, and says so.
      q = model.objects
      q.filter("year" => 1989)
      @test bulk_update(q, rescored; columns = ["points"], match_on = keys).count == 0

      # The same through filters=.
      @test bulk_update(model.objects, rescored; columns = ["points"], match_on = keys,
                        filters = ["points__@gte" => 100]).count == 0
    end
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # Empty DataFrame: every terminal returns a zero count in the same shape.
  # The early return used to be `nothing`, a second shape callers would have to special-case.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "an empty DataFrame returns count = 0" begin
    brc670_with_sqlite() do pool, model
      empty_df = brc670_season()[1:0, :]
      @test (@test_logs (:warn,) bulk_insert(model.objects, empty_df)) == (count = 0, rows = nothing)
      @test (@test_logs (:warn,) bulk_update(model.objects, empty_df;
        columns = ["points"], match_on = ["driver", "year"])) == (count = 0, rows = nothing)
    end
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # Dry runs are unchanged: a show_query mode still returns the statement, not a count.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "show_query modes still return the statement" begin
    brc670_with_sqlite() do pool, model
      @test bulk_insert(model.objects, brc670_season(); show_query = :sql) isa AbstractString
      # Nothing was written by the dry run.
      @test (fetch(pool, "SELECT COUNT(*) AS n FROM brc670_result;") |> DataFrame).n[1] == 0
      # An empty frame under a dry run has no statement, and returns `nothing` as it always did.
      @test isnothing(@test_logs (:warn,) bulk_insert(model.objects, brc670_season()[1:0, :]; show_query = :sql))
      @test isnothing(@test_logs (:warn,) bulk_update(model.objects, brc670_season()[1:0, :];
        columns = ["points"], match_on = ["driver", "year"], show_query = :sql))
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# PostgreSQL mock: the driver count is scripted per write statement.
# `BRC670_COUNTS` holds what `backend_num_affected_rows` / `backend_copy_in!` report for each
# statement in turn, so a sum across chunks is distinguishable from any single chunk's count.
# The calls run inside `with_tx_context`, standing in for `run_in_transaction` — the mock pool has
# no real connection to pin, and every bulk loop executes inside a transaction anyway (#85).
# ─────────────────────────────────────────────────────────────────────────────
struct BulkRowCountsMockPg <: PormG.PormGPostgres end
PormG.config["brc670_pg"] = PormG.Configuration.Settings(
  connections = BulkRowCountsMockPg(), change_data = true)

const BRC670_COUNTS = Int[]
const BRC670_WRITES = String[]

# A scripted driver result: the count the statement "affected".
struct BulkRowCountsResult
  n::Int
end

function fetch(connection::BulkRowCountsMockPg, sql::String;
  conn = nothing, params = nothing, ignore_tx::Bool = false)
  if occursin(r"^\s*(INSERT|UPDATE)"i, sql)
    push!(BRC670_WRITES, sql)
    return BulkRowCountsResult(popfirst!(BRC670_COUNTS))
  end
  return DataFrame()   # SAVEPOINT / RELEASE and anything else
end
PormG.backend_num_affected_rows(::BulkRowCountsMockPg, r::BulkRowCountsResult) = r.n
function PormG.backend_copy_in!(::BulkRowCountsMockPg, conn, sql::String, data_itr)
  push!(BRC670_WRITES, sql)
  return popfirst!(BRC670_COUNTS)
end

const BRC670_PG_RESULT = Model("brc670_pg_result",
  id = IDField(), driver = CharField(), year = IntegerField(), points = IntegerField())
BRC670_PG_RESULT.connect_key = "brc670_pg"

# Run `f()` as if inside run_in_transaction on the mock pool, with `counts` scripted.
function brc670_pg(f, counts)
  empty!(BRC670_WRITES)
  empty!(BRC670_COUNTS)
  append!(BRC670_COUNTS, counts)
  PormG.Configuration.with_tx_context(f, PormG.config["brc670_pg"].connections, :mock_tx_conn)
end

@testset "PostgreSQL bulk terminals return the driver's counts (#670)" begin

  # ─────────────────────────────────────────────────────────────────────────────
  # PostgreSQL bulk_insert / bulk_update: the driver count of every chunk, summed.
  # Three chunks scripted to report 2, 1 and 1 (bulk_insert — a row skipped as a conflict, so the
  # sum is not the frame length) or 2, 0 and 1 (bulk_update — a middle chunk matching nothing).
  # Any single chunk's count, `nrow(df)`, or `nothing` fails the assertion.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "bulk_insert and bulk_update sum the driver counts" begin
    r = brc670_pg([2, 1, 1]) do
      bulk_insert(BRC670_PG_RESULT.objects, brc670_season(); chunk_size = 2)
    end
    @test r == (count = 4, rows = nothing)
    @test length(BRC670_WRITES) == 3   # precondition: three chunks really ran

    r = brc670_pg([2, 0, 1]) do
      bulk_update(BRC670_PG_RESULT.objects, brc670_season();
        columns = ["points"], match_on = ["driver", "year"], chunk_size = 2)
    end
    @test r == (count = 3, rows = nothing)
    @test length(BRC670_WRITES) == 3
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # PostgreSQL bulk_copy: the count `backend_copy_in!` reads from the COPY command tag, summed.
  # bulk_copy streams fixed 10,000-row chunks, so 10,001 rows are two COPY statements; they are
  # scripted to report 10,000 and 1. The mock stands in for the LibPQ extension (it never parses the
  # CSV); the real tag is asserted by the integration suite.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "bulk_copy returns the COPY count" begin
    many = DataFrame(driver = fill("Senna", 10_001), year = fill(1988, 10_001), points = fill(9, 10_001))
    r = brc670_pg([10_000, 1]) do
      bulk_copy(BRC670_PG_RESULT.objects, many)
    end
    @test r == (count = 10_001, rows = nothing)
    @test length(BRC670_WRITES) == 2 && all(sql -> startswith(sql, "COPY"), BRC670_WRITES)
    @test (@test_logs (:warn,) bulk_copy(BRC670_PG_RESULT.objects, brc670_season()[1:0, :])) ==
          (count = 0, rows = nothing)
  end
end
