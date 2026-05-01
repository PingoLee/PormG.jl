using Test
using DataFrames
using PormG
using PormG.Models: Model, CharField, IDField
import PormG.ConnectionPool: fetch

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
  @test SEQUENCE_SYNC_SQL[1] == "SELECT pg_get_serial_sequence('drivers', 'id');"
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