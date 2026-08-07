using Test
using DataFrames
using PormG
using PormG.Models: Model, CharField, IDField, IntegerField
import PormG.ConnectionPool: fetch, SQLiteConnectionPool

# Initialize a dummy model for testing sequence synchronization.
SequenceDriver = Model("drivers",
  id=IDField(),
  forename=CharField(),
)
SequenceDriver.connect_key = "sequence_sync_default"

struct MockSequencePostgres <: PormG.PormGPostgres end

const SEQUENCE_SYNC_SQL = String[]
const INSERT_ATTEMPTS = Ref(0)

function fetch(connection::MockSequencePostgres, sql::String;
  conn = nothing,
  params = nothing,
  ignore_tx::Bool = false)
  push!(SEQUENCE_SYNC_SQL, sql)

  if occursin("pg_get_serial_sequence", sql)
    return DataFrame(pg_get_serial_sequence=["public.legacy_driver_id_seq"])
  elseif occursin("setval", sql)
    return DataFrame(setval=[6])
  end

  return DataFrame()
end

# ─────────────────────────────────────────────────────────────────────────────
# Sequence Sync: Resolve owned Postgres sequence names
# Verifies that sequence repair does not assume `<table>_<pk>_seq` and instead
# uses `pg_get_serial_sequence(...)` before issuing `setval(...)` for the PK.
# ─────────────────────────────────────────────────────────────────────────────
@testset "Sequence synchronization uses owned serial sequence" begin
  empty!(SEQUENCE_SYNC_SQL)

  settings = PormG.Configuration.Settings(
    connections=MockSequencePostgres(),
    change_db=true,
    change_data=true,
  )

  PormG.QueryBuilder._update_sequence(SequenceDriver, settings.connections, ["id"], settings)

  @test length(SEQUENCE_SYNC_SQL) == 2
  # The table argument is passed DOUBLE-QUOTED inside the literal since #59. `pg_get_serial_sequence`
  # takes text that it re-parses as an identifier, so an unquoted argument is lowercased — which
  # resolves to nothing for a mixed-case `db_table`. `'"drivers"'` is exactly the identifier
  # `drivers`, so this is semantically identical for an all-lowercase table like this fixture.
  @test SEQUENCE_SYNC_SQL[1] == "SELECT pg_get_serial_sequence('\"drivers\"', 'id');"
  @test occursin("setval('public.legacy_driver_id_seq'", SEQUENCE_SYNC_SQL[2])
  @test occursin("COALESCE((SELECT MAX(\"id\") FROM \"drivers\"), 0) + 1, false", SEQUENCE_SYNC_SQL[2])
end

# ─────────────────────────────────────────────────────────────────────────────
# Sequence Sync: Retry bulk insert after sequence repair
# Verifies that a duplicate PK during `bulk_insert` triggers one sequence sync
# and then retries the same INSERT instead of forcing the caller to rerun it.
# ─────────────────────────────────────────────────────────────────────────────
@testset "bulk_insert retries after sequence synchronization" begin
  empty!(SEQUENCE_SYNC_SQL)
  INSERT_ATTEMPTS[] = 0

  settings = PormG.Configuration.Settings(
    connections=MockSequencePostgres(),
    change_db=true,
    change_data=true,
  )

  params = PormG.QueryBuilder.PgParameterizedQuery("", Any[], 0)
  PormG.QueryBuilder.add_parameter!(params, 9)
  PormG.QueryBuilder.add_parameter!(params, "Lewis")

  original_fetch = fetch
  @eval begin
    function fetch(connection::MockSequencePostgres, sql::String;
      conn = nothing,
      params = nothing,
      ignore_tx::Bool = false)
      push!(SEQUENCE_SYNC_SQL, sql)

      if occursin("INSERT INTO", sql)
        INSERT_ATTEMPTS[] += 1
        INSERT_ATTEMPTS[] == 1 && throw(ErrorException("duplicate key value violates unique constraint"))
        return DataFrame()
      elseif occursin("pg_get_serial_sequence", sql)
        return DataFrame(pg_get_serial_sequence=["public.legacy_driver_id_seq"])
      elseif occursin("setval", sql)
        return DataFrame(setval=[10])
      end

      return DataFrame()
    end
  end

  PormG.QueryBuilder._bulk_insert(
    SequenceDriver,
    settings.connections,
    ["id", "forename"],
    ["(\$1, \$2)"],
    true,
    ["id"],
    settings,
    false,
    :execute,
    params,
  )

  @test INSERT_ATTEMPTS[] == 2
  @test count(sql -> occursin("INSERT INTO", sql), SEQUENCE_SYNC_SQL) == 2
  @test any(sql -> occursin("pg_get_serial_sequence", sql), SEQUENCE_SYNC_SQL)
  @test any(sql -> occursin("setval('public.legacy_driver_id_seq'", sql), SEQUENCE_SYNC_SQL)
end

# ─────────────────────────────────────────────────────────────────────────────
# SQLite Sequence Sync: tolerate non-integer MAX(pk) values
# _update_sequence (SQLite) reads MAX(pk) and writes it into sqlite_sequence. A
# non-integer maximum — a TEXT primary key, or a value SQLite hands back as a float —
# previously crashed on `Int64(max_id)` (MethodError / InexactError) inside the insert
# path. The coercion (`max_id isa Real ? floor(Int64, max_id) : tryparse(Int64, string(max_id))`)
# now syncs any numeric maximum (integer or float) while turning a non-numeric one into a
# safe skip. Hermetic temp SQLite — no external setup.
# ─────────────────────────────────────────────────────────────────────────────
@testset "SQLite _update_sequence tolerates non-integer MAX(pk)" begin
  mktempdir() do dir
    pool = SQLiteConnectionPool(joinpath(dir, "seq.sqlite"); pool_size = 1)
    settings = PormG.Configuration.Settings(
      connections   = pool,
      db_def_folder = dir,
      change_data   = true,
    )

    # (a) Integer AUTOINCREMENT PK: _update_sequence upserts MAX(id) into sqlite_sequence —
    #     it corrects a deliberately stale value and, crucially, NEVER appends duplicate rows
    #     even when called repeatedly. (The old INSERT OR REPLACE appended a row each time,
    #     since sqlite_sequence.name has no UNIQUE constraint.)
    fetch(pool, "CREATE TABLE seq_int (id INTEGER PRIMARY KEY AUTOINCREMENT, n INTEGER);")
    fetch(pool, "INSERT INTO seq_int (id, n) VALUES (5, 1);")
    fetch(pool, "UPDATE sqlite_sequence SET seq = 1 WHERE name = 'seq_int';")   # deliberately stale

    PormG.QueryBuilder._update_sequence(Model("seq_int", id=IDField(), n=IntegerField()), pool, ["id"], settings)
    PormG.QueryBuilder._update_sequence(Model("seq_int", id=IDField(), n=IntegerField()), pool, ["id"], settings)  # idempotent

    rows = fetch(pool, "SELECT seq FROM sqlite_sequence WHERE name = 'seq_int';") |> DataFrame
    @test nrow(rows) == 1        # upsert never appends duplicate rows (the quirk this guards)
    @test rows[1, :seq] == 5     # stale value corrected to MAX(id)

    # (b) TEXT PK: MAX(code) is non-numeric → tryparse returns nothing → must NOT throw (graceful skip).
    fetch(pool, "CREATE TABLE seq_text (code TEXT PRIMARY KEY);")
    fetch(pool, "INSERT INTO seq_text (code) VALUES ('abc');")

    @test (PormG.QueryBuilder._update_sequence(Model("seq_text", code=CharField()), pool, ["code"], settings); true)

    # (c) Float MAX (REAL column): a Real value is coerced via floor(Int64, …), not skipped —
    #     `tryparse(Int64, "5.0")` would have returned nothing. Exercises the numeric branch.
    fetch(pool, "CREATE TABLE seq_real (id REAL PRIMARY KEY);")
    fetch(pool, "INSERT INTO seq_real (id) VALUES (5.0);")

    PormG.QueryBuilder._update_sequence(Model("seq_real", id=IDField()), pool, ["id"], settings)

    real_rows = fetch(pool, "SELECT seq FROM sqlite_sequence WHERE name = 'seq_real';") |> DataFrame
    @test nrow(real_rows) == 1
    @test real_rows[1, :seq] == 5    # 5.0 floored to an integer seq, not silently skipped
  end
end