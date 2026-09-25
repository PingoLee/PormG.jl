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
# A scripted driver result carrying an INSERT's affected-row count (#670).
struct SequenceRetryResult
  n::Int
end

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

  # No `change_db=true` here since #344 — it used to be load-bearing (the only way past the
  # `!(settings.change_db || settings.django_prefix !== nothing)` gate), and it is now noise.
  # `_update_sequence` reads no setting at all on the PostgreSQL path.
  settings = PormG.Configuration.Settings(
    connections=MockSequencePostgres(),
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
# Sequence Sync: no configuration gate (#344)
# `_update_sequence` used to open with
#   !(settings.change_db || settings.django_prefix !== nothing) && return nothing
# which silently disabled PostgreSQL sequence repair for every connection with
# `change_db: false` (the documented production posture) and every connection built
# by `register_connection`, which defaults both flags off. Nothing logged, nothing
# returned — a skipped sync was indistinguishable from a performed one, so the
# sequence drifted until an auto-pk insert raised a duplicate-key error.
#
# The drift condition is already decided by the CALLERS (`pk_exist`), so the gate
# could only ever suppress a needed sync. These assertions pin its absence: restoring
# the line must turn the `change_db=false` case red.
# ─────────────────────────────────────────────────────────────────────────────
@testset "Sequence synchronization ignores change_db and django_prefix (#344)" begin
  # (a) The configuration the old gate silenced: writes allowed, no DDL rights, no prefix.
  #     This is what `register_connection` produces and what the docs' own `prod:` block sets.
  empty!(SEQUENCE_SYNC_SQL)
  gated_settings = PormG.Configuration.Settings(
    connections  = MockSequencePostgres(),
    change_db    = false,
    change_data  = true,
  )
  @test gated_settings.django_prefix === nothing   # the other half of the old gate, unset

  PormG.QueryBuilder._update_sequence(SequenceDriver, gated_settings.connections, ["id"], gated_settings)

  # Both statements must be issued — the resolve and the repair. Under the old gate this was 0.
  @test length(SEQUENCE_SYNC_SQL) == 2
  @test occursin("pg_get_serial_sequence", SEQUENCE_SYNC_SQL[1])
  @test occursin("setval('public.legacy_driver_id_seq'", SEQUENCE_SYNC_SQL[2])

  # (b) Setting a django_prefix must not change anything. It used to be one of the two ways to
  #     switch syncing ON, which is exactly the coupling #344 removes: a naming knob that
  #     silently doubled as a correctness switch.
  empty!(SEQUENCE_SYNC_SQL)
  prefixed_settings = PormG.Configuration.Settings(
    connections   = MockSequencePostgres(),
    change_db     = false,
    change_data   = true,
    django_prefix = "f1",
  )

  PormG.QueryBuilder._update_sequence(SequenceDriver, prefixed_settings.connections, ["id"], prefixed_settings)

  @test length(SEQUENCE_SYNC_SQL) == 2
  # Identical SQL: the prefix shapes generated model names, never the physical table read here.
  @test occursin("setval('public.legacy_driver_id_seq'", SEQUENCE_SYNC_SQL[2])
  @test occursin("FROM \"drivers\"", SEQUENCE_SYNC_SQL[2])
end

# ─────────────────────────────────────────────────────────────────────────────
# Sequence Sync: the unowned-sequence fallback cannot hit a NEIGHBOURING table (#344)
# When `pg_get_serial_sequence` returns NULL — a Django-managed table, or a natural key —
# PormG falls back to the catalog. That lookup used to be
#   WHERE sequencename LIKE '<table>%'
# with no ORDER BY and row 1 taken blind. `f1_driver` and `f1_driverstanding` BOTH answer
# `LIKE 'f1_driver%'`, so the resync could setval a different table's sequence to this
# table's MAX(pk); with is_called=false that table then issues a colliding id on its next
# insert. Removing the configuration gate made this reachable on every connection, so the
# lookup is now an exact match on PostgreSQL's conventional `<table>_<column>_seq`,
# restricted to the search path.
# ─────────────────────────────────────────────────────────────────────────────
struct MockUnownedSequence <: PormG.PormGPostgres end

function fetch(connection::MockUnownedSequence, sql::String;
  conn = nothing,
  params = nothing,
  ignore_tx::Bool = false)
  push!(SEQUENCE_SYNC_SQL, sql)

  if occursin("pg_get_serial_sequence", sql)
    return DataFrame(pg_get_serial_sequence=[missing])          # no OWNED sequence
  elseif occursin("pg_class", sql)
    # MIXED CASE on purpose. An all-lowercase fixture cannot see the case-folding bug below:
    # `setval` takes regclass, so an unquoted `public.Drivers_Id_seq` is re-parsed and folded to
    # `public.drivers_id_seq`, which does not exist. PostgreSQL names the implicit sequence of a
    # quoted `"Db_Table"` this way, which is exactly the #59 case the lookup preserves.
    return DataFrame(schemaname=["public"], sequencename=["Drivers_Id_seq"])
  end

  return DataFrame()
end

@testset "Unowned-sequence fallback matches the exact sequence name (#344)" begin
  empty!(SEQUENCE_SYNC_SQL)

  settings = PormG.Configuration.Settings(
    connections = MockUnownedSequence(),
    change_data = true,
  )

  PormG.QueryBuilder._update_sequence(SequenceDriver, settings.connections, ["id"], settings)

  @test length(SEQUENCE_SYNC_SQL) == 3          # resolve, catalog fallback, setval
  fallback = SEQUENCE_SYNC_SQL[2]

  # The exact conventional name, not a prefix match. This is the assertion that fails if the
  # `LIKE '<table>%'` form ever comes back.
  @test occursin("c.relname = 'drivers_id_seq'", fallback)
  @test !occursin("LIKE", fallback)
  # Pinned to the TABLE'S OWN namespace via to_regclass — not merely to some schema on the
  # search path. A membership test would let `tenant.drivers` match `public.drivers_id_seq`
  # (which belongs to `public.drivers`) and resync it from MAX(tenant.drivers.id).
  @test occursin("to_regclass", fallback)
  @test occursin("c.relnamespace = ", fallback)
  # Sequences only — `relname` is unique per namespace per relkind, so this also guarantees at
  # most one row and makes any ORDER BY/tiebreak unnecessary.
  @test occursin("c.relkind = 'S'", fallback)
  # The table is passed as a quoted identifier inside the literal, so a mixed-case db_table
  # resolves instead of folding to nothing (#59).
  @test occursin("to_regclass('\"drivers\"')", fallback)

  # Schema-qualified AND quoted. Bare `public.Drivers_Id_seq` would be case-folded by regclass
  # parsing into a relation that does not exist — silently outside a transaction, and as a hard
  # failure inside one.
  @test occursin("setval('\"public\".\"Drivers_Id_seq\"'", SEQUENCE_SYNC_SQL[3])
end

# ─────────────────────────────────────────────────────────────────────────────
# Sequence Sync: a setval failure is reported, not propagated — IN AUTOCOMMIT (#344)
# Scoped to the no-transaction case on purpose: inside a transaction the same failure
# propagates instead, which the testset further down asserts. Here the INSERT was its own
# committed statement, so the row is durable and only the NEXT auto-generated key is at
# risk; raising would make a succeeded create() look failed. The expected cause is a role
# holding USAGE but not UPDATE on the sequence (PostgreSQL requires UPDATE for setval,
# while nextval accepts either), so the role can insert rows and still be unable to resync.
# ─────────────────────────────────────────────────────────────────────────────
struct MockSetvalDenied <: PormG.PormGPostgres end

# What `setval` throws. Production NEVER surfaces a bare driver exception here: every failure
# leaving the pool crosses `_as_database_error`, which wraps anything that is not already a
# PormGError in a `DatabaseError` subtype. A mock that throws a raw `ErrorException` would let a
# `catch e; e isa InterruptException` test look correct while being unreachable in production, so
# the mock reproduces the wrapper.
const SETVAL_DENIED = Ref{Any}(
  PormG.StatementError("PostgreSQL", ErrorException("ERROR:  permission denied for sequence legacy_driver_id_seq")))

function fetch(connection::MockSetvalDenied, sql::String;
  conn = nothing,
  params = nothing,
  ignore_tx::Bool = false)
  push!(SEQUENCE_SYNC_SQL, sql)

  if occursin("pg_get_serial_sequence", sql)
    return DataFrame(pg_get_serial_sequence=["public.legacy_driver_id_seq"])
  elseif occursin("setval", sql)
    throw(SETVAL_DENIED[])
  end

  return DataFrame()
end

@testset "Sequence resync failure warns instead of throwing (#344)" begin
  empty!(SEQUENCE_SYNC_SQL)

  settings = PormG.Configuration.Settings(
    connections = MockSetvalDenied(),
    change_data = true,
  )

  # match_mode=:any so an unrelated @debug/@info from the call path cannot fail the assertion.
  @test_logs (:warn, r"Sequence resync failed") match_mode = :any begin
    PormG.QueryBuilder._update_sequence(SequenceDriver, settings.connections, ["id"], settings)
  end

  # It still ATTEMPTED the repair — the warning is not a substitute for trying.
  @test length(SEQUENCE_SYNC_SQL) == 2
  @test occursin("setval", SEQUENCE_SYNC_SQL[2])
end

# ─────────────────────────────────────────────────────────────────────────────
# Sequence Sync: only DATABASE failures are tolerated (#344)
# The try covers the whole loop body, so it also covers every non-database way the body can fail.
# Relabelling one of those as "sequence resync failed, check your GRANTs" would bury a real error.
# The catch allowlists `DatabaseError` and `PoolError`; everything else propagates.
#
# The driver used to be a `db_table` that PormG's own identifier validator refused — an
# `InvalidValueError` raised inside the try. #394 removed that producer: a physical table name is
# escaped rather than validated now, so an odd `db_table` no longer raises anywhere. The ALLOWLIST is
# unchanged and is still what this pins, so the error is injected through the mock instead. Picking
# `InvalidValueError` keeps the original premise exactly — a PormGError that is not a DatabaseError.
# ─────────────────────────────────────────────────────────────────────────────
@testset "A non-database error during resync is not swallowed (#344)" begin
  empty!(SEQUENCE_SYNC_SQL)

  settings = PormG.Configuration.Settings(
    connections = MockSetvalDenied(),
    change_data = true,
  )

  original = SETVAL_DENIED[]
  SETVAL_DENIED[] = PormG.InvalidValueError("not a database failure — must not be relabelled")
  try
    @test !(SETVAL_DENIED[] isa PormG.DatabaseError)   # the premise: outside the allowlist
    @test !(SETVAL_DENIED[] isa PormG.PoolError)

    # No transaction, so the warn path is the one being bypassed here — this raises because of the
    # allowlist, not because of the transaction check.
    #
    # The message is checked, not just the type: `@test_throws InvalidValueError` alone cannot tell
    # "the injected error propagated" from "some other InvalidValueError fired anywhere", and that
    # distinction is the whole point of the assertion.
    try
      PormG.QueryBuilder._update_sequence(SequenceDriver, settings.connections, ["id"], settings)
      @test false   # unreachable: the allowlist must let this through
    catch e
      @test e isa PormG.InvalidValueError
      @test occursin("must not be relabelled", sprint(showerror, e))
    end
  finally
    SETVAL_DENIED[] = original
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# Sequence Sync: a `db_table` the DDL accepts is one the resync can address (#394)
# The inverse of what the testset above used to assert. `db_table` is deliberately NOT
# shape-validated at declaration (#59) because naming a table PormG's conventions could not produce
# is the point of the option — and until #394 the query side refused the very names it exists for, so
# `_update_sequence` raised `InvalidValueError` on a table `create_table` had rendered happily.
# Both spellings now agree: escape, do not validate.
# ─────────────────────────────────────────────────────────────────────────────
@testset "A resync addresses an odd db_table instead of refusing it (#394)" begin
  empty!(SEQUENCE_SYNC_SQL)

  settings = PormG.Configuration.Settings(
    connections = MockSequencePostgres(),
    change_data = true,
  )

  odd = Model("badseq", db_table = "no spaces allowed!", id = IDField(), forename = CharField())
  odd.connect_key = "sequence_sync_default"

  PormG.QueryBuilder._update_sequence(odd, settings.connections, ["id"], settings)

  @test length(SEQUENCE_SYNC_SQL) == 2
  # `pg_get_serial_sequence` takes TEXT it re-parses as an identifier, so the name is quoted INSIDE
  # a string literal — an unquoted mixed-case or spaced name would fold and resolve to nothing.
  @test occursin("pg_get_serial_sequence('\"no spaces allowed!\"'", SEQUENCE_SYNC_SQL[1])
  @test occursin("FROM \"no spaces allowed!\"", SEQUENCE_SYNC_SQL[2])
end

# ─────────────────────────────────────────────────────────────────────────────
# Sequence Sync: the allowlist's POSITIVE half (#344)
# The testset above proves the allowlist rejects what it must. This one proves it still
# accepts what it should: a `PoolError` — the one family that reaches the catch UN-wrapped,
# because `acquire_connection` runs outside `fetch`'s own try and never crosses
# `_as_database_error`. Without this, only the negative half of the guard is pinned and
# narrowing the allowlist to `DatabaseError` alone would go unnoticed.
# ─────────────────────────────────────────────────────────────────────────────
@testset "A pool failure during resync is tolerated (#344)" begin
  empty!(SEQUENCE_SYNC_SQL)

  settings = PormG.Configuration.Settings(
    connections = MockSetvalDenied(),
    change_data = true,
  )

  original = SETVAL_DENIED[]
  SETVAL_DENIED[] = PormG.ConnectionPool.PoolTimeoutError("PostgreSQL", 4, 4, 3, 5.0)
  try
    @test SETVAL_DENIED[] isa PormG.PoolError
    @test !(SETVAL_DENIED[] isa PormG.DatabaseError)   # genuinely the other allowlist branch

    @test_logs (:warn, r"Sequence resync failed") match_mode = :any begin
      PormG.QueryBuilder._update_sequence(SequenceDriver, settings.connections, ["id"], settings)
    end
  finally
    SETVAL_DENIED[] = original
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# Sequence Sync: a CANCELLATION is never swallowed (#344)
# The warn path must not eat a Ctrl-C. The subtlety is that the obvious guard,
# `e isa InterruptException`, is unreachable: every failure leaving the pool crosses
# `_as_database_error`, which wraps the interrupt in a `StatementError`. So the guard
# has to see through the taxonomy wrapper — `_await_abandoned` is the helper that does
# (ConnectionPool.jl:176, "It sees through a DatabaseError too").
# ─────────────────────────────────────────────────────────────────────────────
@testset "A cancellation during resync is never swallowed (#344)" begin
  empty!(SEQUENCE_SYNC_SQL)

  settings = PormG.Configuration.Settings(
    connections = MockSetvalDenied(),
    change_data = true,
  )

  original = SETVAL_DENIED[]
  SETVAL_DENIED[] = PormG.StatementError("PostgreSQL", InterruptException())
  try
    # The premise: this value is NOT an InterruptException, so a naive `e isa InterruptException`
    # guard reads false and drops through to the warning. That is the bug being pinned.
    @test !(SETVAL_DENIED[] isa InterruptException)

    # No transaction context here, so the ONLY thing that can make this raise is the
    # cancellation check — otherwise it takes the warn-and-continue path.
    thrown = try
      PormG.QueryBuilder._update_sequence(SequenceDriver, settings.connections, ["id"], settings)
      nothing
    catch e
      e
    end

    @test thrown !== nothing
    @test PormG.ConnectionPool._await_abandoned(thrown)
  finally
    SETVAL_DENIED[] = original
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# Sequence Sync: inside a transaction the failure must PROPAGATE (#344)
# The warn-instead-of-throw rule above holds only in autocommit, where the INSERT
# was its own committed statement. Inside a transaction PostgreSQL poisons the whole
# transaction as soon as any statement errors — every later statement returns
# "current transaction is aborted" and the COMMIT is answered with a rollback.
# Swallowing there would return a PormGRow for a row that is already doomed.
#
# This is the BULK writers' normal path: `bulk_insert` and `bulk_copy` always run in a
# transaction (execution_bulk.jl:1004, :1176). The row-level PostgreSQL writers are the
# opposite — `insert`, `_update_or_create` and `_get_or_create` deliberately run
# transaction-free (execution.jl:924-928 wraps in run_in_transaction only for SQLite),
# so they take the warn path unless the caller opened an `atomic` block.
# ─────────────────────────────────────────────────────────────────────────────
@testset "Sequence resync failure inside a transaction propagates (#344)" begin
  empty!(SEQUENCE_SYNC_SQL)

  settings = PormG.Configuration.Settings(
    connections = MockSetvalDenied(),
    change_data = true,
  )

  # Stand in for the caller already being inside run_in_transaction on THIS pool.
  thrown = PormG.Configuration.with_tx_context(settings.connections, :mock_tx_conn) do
    # Precondition: the helper `_update_sequence` consults must actually see the context,
    # otherwise this testset would pass for the wrong reason.
    @test PormG.Configuration.transaction_connection_for(settings) !== nothing
    try
      PormG.QueryBuilder._update_sequence(SequenceDriver, settings.connections, ["id"], settings)
      nothing
    catch e
      e
    end
  end

  @test thrown !== nothing                                                   # it raised, not warned
  @test occursin("permission denied for sequence", sprint(showerror, thrown))  # the ORIGINAL cause
end

# ─────────────────────────────────────────────────────────────────────────────
# Sequence Sync: Retry bulk insert after sequence repair
# Verifies that a duplicate PK during `bulk_insert` triggers one sequence sync
# and then retries the same INSERT instead of forcing the caller to rerun it.
# ─────────────────────────────────────────────────────────────────────────────
@testset "bulk_insert retries after sequence synchronization" begin
  empty!(SEQUENCE_SYNC_SQL)
  INSERT_ATTEMPTS[] = 0

  # `change_db` deliberately left at its `false` default (#344): the self-heal must work on the
  # connections the old gate silenced, which is exactly where a drifted sequence shows up.
  settings = PormG.Configuration.Settings(
    connections=MockSequencePostgres(),
    change_data=true,
  )

  # One row, bound as PostgreSQL binds a chunk: one array per column (#672).
  params = PormG.QueryBuilder.PgParameterizedQuery("", Any[], 0)
  PormG.QueryBuilder.add_parameter!(params, Any[9]; sql_type = "bigint[]")
  PormG.QueryBuilder.add_parameter!(params, Any["Lewis"]; sql_type = "varchar[]")

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
        return SequenceRetryResult(7)   # the retry's own result: the only one there is to count (#670)
      elseif occursin("pg_get_serial_sequence", sql)
        return DataFrame(pg_get_serial_sequence=["public.legacy_driver_id_seq"])
      elseif occursin("setval", sql)
        return DataFrame(setval=[10])
      end

      return DataFrame()
    end
  end

  # The INSERT's driver count (#670). `_bulk_insert` reads it from the result of the statement that
  # landed, which here is the retry; the first attempt threw and has no result to count. Defined for
  # the marker type ONLY, so counting anything else — `nothing`, a SAVEPOINT's DataFrame — is a
  # MethodError rather than a pass.
  @eval PormG.backend_num_affected_rows(::MockSequencePostgres, r::SequenceRetryResult) = r.n

  # Inside a transaction on this pool, as `bulk_insert` always calls it (#85): the chunk count is
  # `changes()`/the driver count on the transaction's pinned connection, and outside one there is no
  # connection to take it from. This also puts the first attempt under its savepoint, the path
  # `bulk_insert` really takes.
  inserted = PormG.Configuration.with_tx_context(settings.connections, :mock_tx_conn) do
    PormG.QueryBuilder._bulk_insert(
      SequenceDriver,
      settings.connections,
      ["id", "forename"],
      "SELECT * FROM unnest(\$1::bigint[], \$2::varchar[])",
      ["id"],
      settings,
      :execute,
      params,
    )
  end

  @test inserted == 7
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

    try
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
    finally
      # Release the SQLite handle so mktempdir can delete the temp DB on Windows (WAL keeps it open).
      PormG.ConnectionPool.close_pool!(pool)
    end
  end
end

# Run `f(pool, model)` against a fresh temp SQLite database registered under its own config key.
# `autoincrement = false` builds the #674 shape: a legacy `INTEGER PRIMARY KEY` table in a database
# with no AUTOINCREMENT table anywhere, so SQLite never created `sqlite_sequence`.
function seq674_with_sqlite(f; autoincrement::Bool)
  mktempdir() do dir
    pool = SQLiteConnectionPool(joinpath(dir, "seq674.sqlite"); pool_size = 1)
    key = "seq674_sqlite"
    PormG.config[key] = PormG.Configuration.Settings(
      connections = pool, db_def_folder = dir, change_data = true)
    try
      pk_decl = autoincrement ? "INTEGER PRIMARY KEY AUTOINCREMENT" : "INTEGER PRIMARY KEY"
      fetch(pool, "CREATE TABLE seq674_circuit (circuitid $(pk_decl), name TEXT NOT NULL);")
      model = Model("seq674_circuit", circuitid = IDField(), name = CharField(max_length = 255))
      model.connect_key = key
      f(pool, model)
    finally
      delete!(PormG.config, key)
      # Release the SQLite handle so mktempdir can delete the temp DB on Windows (WAL keeps it open).
      PormG.ConnectionPool.close_pool!(pool)
    end
  end
end

seq674_has_sequence_table(pool) = nrow(fetch(pool,
  "SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'sqlite_sequence';") |> DataFrame) > 0

# ─────────────────────────────────────────────────────────────────────────────
# SQLite Sequence Sync: bulk_insert with explicit ids when `sqlite_sequence` does not exist (#674)
# `_update_sequence` wrote `sqlite_sequence` unconditionally, so on a database with no AUTOINCREMENT
# table the resync raised "no such table: sqlite_sequence" and rolled the whole bulk insert back.
# Without the table there is no counter to keep in step (SQLite picks MAX(rowid) + 1), so the resync
# is skipped and the rows land.
# ─────────────────────────────────────────────────────────────────────────────
@testset "SQLite bulk_insert with explicit ids works without sqlite_sequence (#674)" begin
  seq674_with_sqlite(autoincrement = false) do pool, model
    @test !seq674_has_sequence_table(pool)   # precondition: the #674 shape, not an AUTOINCREMENT db

    model.objects.create("circuitid" => 1, "name" => "Monza")
    r = bulk_insert(model.objects, DataFrame(circuitid = [2, 3], name = ["Spa", "Suzuka"]))
    @test r.count == 2
    @test model.objects.count() == 3        # pre-fix: 1, the bulk rows were rolled back

    # The skip did not work by creating the table.
    @test !seq674_has_sequence_table(pool)

    # A later auto-id insert still gets the next free id: SQLite's own MAX(rowid) + 1.
    model.objects.create("name" => "Imola")
    @test model.objects.filter("name" => "Imola").values("circuitid").list()[1][:circuitid] == 4
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# SQLite Sequence Sync: explicit resync_sequences when `sqlite_sequence` does not exist (#674)
# The explicit repair calls the same `_update_sequence`, so it crashed the same way. It now returns
# the pk fields it considered, like any other resync, and writes nothing.
# ─────────────────────────────────────────────────────────────────────────────
@testset "SQLite resync_sequences is a no-op without sqlite_sequence (#674)" begin
  seq674_with_sqlite(autoincrement = false) do pool, model
    fetch(pool, "INSERT INTO seq674_circuit (circuitid, name) VALUES (7, 'Monaco');")
    @test resync_sequences(model) == ["circuitid"]
    @test !seq674_has_sequence_table(pool)
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# SQLite Sequence Sync: allocate_primary_keys when `sqlite_sequence` does not exist (#674)
# `_allocate_sqlite_ids` read and bumped `sqlite_sequence`, so it failed the same way. Without the
# table it starts from MAX(pk) + 1 and keeps the reservation in the transaction's in-memory
# overlay, so two allocations inside one transaction still hand out disjoint ranges.
# ─────────────────────────────────────────────────────────────────────────────
@testset "SQLite allocate_primary_keys works without sqlite_sequence (#674)" begin
  seq674_with_sqlite(autoincrement = false) do pool, model
    fetch(pool, "INSERT INTO seq674_circuit (circuitid, name) VALUES (10, 'Monza');")

    # Standalone call: starts right after MAX(pk).
    first_df = allocate_primary_keys(model.objects, DataFrame(name = ["Spa", "Suzuka"]))
    @test first_df.circuitid == [11, 12]
    bulk_insert(model.objects, first_df)
    @test model.objects.count() == 3

    # Inside one transaction, the second range starts after the first even though neither is
    # inserted yet: the overlay, not sqlite_sequence, carries the reservation here.
    run_in_transaction("seq674_sqlite") do
      a = allocate_primary_keys(model.objects, DataFrame(name = ["Imola"]))
      b = allocate_primary_keys(model.objects, DataFrame(name = ["Interlagos", "Hungaroring"]))
      @test a.circuitid == [13]
      @test b.circuitid == [14, 15]
      bulk_insert(model.objects, vcat(a, b))
    end
    @test model.objects.count() == 6
    @test !seq674_has_sequence_table(pool)
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# SQLite Sequence Sync: allocate_primary_keys keeps one sqlite_sequence row per table (#674 sibling)
# The reservation bump was `INSERT OR REPLACE INTO sqlite_sequence`, but sqlite_sequence.name has
# no UNIQUE constraint, so every call after the first APPENDED a row instead of replacing it: two
# rows, and SQLite's own AUTOINCREMENT bookkeeping could read the stale one. The bump now uses the
# same UPDATE-then-INSERT upsert as `_update_sequence`.
# ─────────────────────────────────────────────────────────────────────────────
@testset "SQLite allocate_primary_keys does not duplicate sqlite_sequence rows" begin
  seq674_with_sqlite(autoincrement = true) do pool, model
    allocate_primary_keys(model.objects, DataFrame(name = ["Monza", "Spa"]))                 # 1:2
    ids = allocate_primary_keys(model.objects, DataFrame(name = ["Suzuka", "Imola", "Monaco"]))
    @test ids.circuitid == [3, 4, 5]

    rows = fetch(pool, "SELECT seq FROM sqlite_sequence WHERE name = 'seq674_circuit';") |> DataFrame
    @test nrow(rows) == 1           # pre-fix: 2, one appended per call
    @test rows[1, :seq] == 5        # the end of the second range
  end
end

# PostgreSQL mock that records every statement in order, so a test can see how many sequence
# syncs a multi-chunk `bulk_insert` issued and where they fell relative to the INSERTs (#704).
struct MockSyncPerCall <: PormG.PormGPostgres end
struct SyncPerCallResult
  n::Int
end
const SYNC_PER_CALL_SQL = String[]
PormG.config["seq704_pg"] = PormG.Configuration.Settings(connections = MockSyncPerCall(), change_data = true)

function fetch(connection::MockSyncPerCall, sql::String; conn = nothing, params = nothing, ignore_tx::Bool = false)
  push!(SYNC_PER_CALL_SQL, sql)
  occursin("INSERT INTO", sql) && return SyncPerCallResult(2)
  occursin("pg_get_serial_sequence", sql) && return DataFrame(pg_get_serial_sequence = ["public.seq704_driver_id_seq"])
  occursin("setval", sql) && return DataFrame(setval = [7])
  return DataFrame()   # SAVEPOINT / RELEASE
end
PormG.backend_num_affected_rows(::MockSyncPerCall, r::SyncPerCallResult) = r.n

const Seq704Driver = Model("seq704_driver", id = IDField(), forename = CharField())
Seq704Driver.connect_key = "seq704_pg"

# ─────────────────────────────────────────────────────────────────────────────
# Sequence Sync: bulk_insert resyncs once per call, after the last chunk (#704)
# Six rows at chunk_size = 2 are three INSERTs. With explicit ids the sequence is synced ONCE,
# after all three — it used to be synced after every chunk, two round trips each, which was ~1.9 s
# of a 100k-row insert. Without an id column no row sets the pk, so nothing is synced at all.
# ─────────────────────────────────────────────────────────────────────────────
@testset "bulk_insert syncs the sequence once per call, not per chunk (#704)" begin
  drivers = DataFrame(id = 1:6, forename = ["Ayrton", "Alain", "Nelson", "Nigel", "Michael", "Mika"])
  # Run as `bulk_insert` really runs: inside a transaction on this pool.
  in_tx(f) = PormG.Configuration.with_tx_context(f, PormG.config["seq704_pg"].connections, :mock_tx_conn)

  empty!(SYNC_PER_CALL_SQL)
  r = in_tx(() -> bulk_insert(Seq704Driver.objects, drivers; chunk_size = 2))
  @test r.count == 6                                                          # 3 chunks × 2
  inserts = findall(sql -> occursin("INSERT INTO", sql), SYNC_PER_CALL_SQL)
  lookups = findall(sql -> occursin("pg_get_serial_sequence", sql), SYNC_PER_CALL_SQL)
  setvals = findall(sql -> occursin("setval", sql), SYNC_PER_CALL_SQL)
  @test length(inserts) == 3                                                  # precondition: three chunks ran
  @test length(lookups) == 1 && length(setvals) == 1                          # pre-fix: 3 of each
  @test only(lookups) > last(inserts) && only(setvals) > last(inserts)        # after the last chunk

  # No id column: the database allocates every id, so there is nothing to resync.
  empty!(SYNC_PER_CALL_SQL)
  in_tx(() -> bulk_insert(Seq704Driver.objects, drivers[:, [:forename]]; chunk_size = 2))
  @test count(sql -> occursin("INSERT INTO", sql), SYNC_PER_CALL_SQL) == 3
  @test !any(sql -> occursin("pg_get_serial_sequence", sql) || occursin("setval", sql), SYNC_PER_CALL_SQL)

  # A dry run executes nothing, so it syncs nothing either.
  empty!(SYNC_PER_CALL_SQL)
  bulk_insert(Seq704Driver.objects, drivers; chunk_size = 2, show_query = :sql)
  @test isempty(SYNC_PER_CALL_SQL)
end

# ─────────────────────────────────────────────────────────────────────────────
# SQLite Sequence Sync: a multi-chunk explicit-id insert still counts and continues right (#704)
# The sync moved from every chunk to the end of the call, so the per-chunk `changes()` counts no
# longer interleave with it. This pins the OUTCOME on a real database, with the ids spread over three
# chunks: the summed count, and the next auto id continuing after the largest explicit one. It is not
# a guard on the sync call itself — SQLite also advances an AUTOINCREMENT counter natively on an
# explicit-id insert; the call count is pinned by the PostgreSQL testset above.
# ─────────────────────────────────────────────────────────────────────────────
@testset "SQLite multi-chunk explicit-id bulk_insert counts and continues right (#704)" begin
  seq674_with_sqlite(autoincrement = true) do pool, model
    circuits = DataFrame(circuitid = [10, 11, 12, 13, 14], name = ["Monza", "Spa", "Suzuka", "Interlagos", "Imola"])
    @test bulk_insert(model.objects, circuits; chunk_size = 2).count == 5
    seq = fetch(pool, "SELECT seq FROM sqlite_sequence WHERE name = 'seq674_circuit';") |> DataFrame
    @test seq.seq == [14]

    # The next auto-id insert continues after the largest explicit id.
    model.objects.create("name" => "Silverstone")
    @test model.objects.filter("name" => "Silverstone").values("circuitid").list()[1][:circuitid] == 15
  end
end
