using Test
using DataFrames
using PormG
using PormG.Models: Model, CharField, IDField
import PormG.ConnectionPool: fetch

# ─────────────────────────────────────────────────────────────────────────────
# bulk_insert ON CONFLICT (#123)
#
# DB-free: `show_query=:dict` returns the rendered SQL before any database call,
# so the clause text, parameter alignment, and validation errors are all
# assertable against bare mock connections. The retry-skip testset uses a
# recording mock `fetch` like test_sequence_sync.jl.
# ─────────────────────────────────────────────────────────────────────────────

# Mirrors esus_back's dash_dim_cbo — the concrete use case from issue #123 —
# with a db_column-mapped field to prove the clause renders physical names.
ConflictCbo = Model("dash_dim_cbo",
  id = IDField(),
  co_cbo = CharField(),
  no_cbo = CharField(db_column = "nome_cbo"),
)
ConflictCbo.connect_key = "on_conflict_pg"

ConflictCboSl = Model("dash_dim_cbo",
  id = IDField(),
  co_cbo = CharField(),
  no_cbo = CharField(db_column = "nome_cbo"),
)
ConflictCboSl.connect_key = "on_conflict_sqlite"

struct MockPgConflict <: PormG.PormGPostgres end
struct MockSqliteConflict <: PormG.PormGSQLite end
# The bare mock has no driver body; answer the version probe (#84 bind-parameter
# limit math) with a modern SQLite so the end-to-end :dict path needs no database.
PormG.backend_sqlite_version(::MockSqliteConflict) = 3045000

PormG.config["on_conflict_pg"] = PormG.Configuration.Settings(
  connections = MockPgConflict(),
  change_data = true,
)
PormG.config["on_conflict_sqlite"] = PormG.Configuration.Settings(
  connections = MockSqliteConflict(),
  change_data = true,
)

const CBO_DF_123 = DataFrame(
  id = [1, 2],
  co_cbo = ["225125", "225130"],
  no_cbo = ["Cardiologista", "Neurologista"],
)

_cbo_sql(on_conflict; model = ConflictCbo, kwargs...) =
  PormG.QueryBuilder.bulk_insert(model, CBO_DF_123;
    show_query = :dict, on_conflict = on_conflict, kwargs...)[:sql_text]

@testset "on_conflict SQL rendering (PostgreSQL mock)" begin
  # Default stays a bare INSERT — regression guard for existing callers.
  @test !occursin("ON CONFLICT", _cbo_sql(nothing))

  # Untargeted DO NOTHING via the Symbol shorthand.
  sql_nothing = _cbo_sql(:nothing)
  @test occursin("ON CONFLICT DO NOTHING", sql_nothing)
  @test !occursin("ON CONFLICT (", sql_nothing)

  # Targeted DO NOTHING.
  @test occursin("ON CONFLICT (\"id\") DO NOTHING",
    _cbo_sql((action = :nothing, target = ["id"])))

  # Upsert: multi-column set, db_column field rendered by its physical name.
  sql_update = _cbo_sql((action = :update, target = ["id"], set = ["co_cbo", "no_cbo"]))
  @test occursin("ON CONFLICT (\"id\") DO UPDATE SET " *
    "\"co_cbo\" = EXCLUDED.\"co_cbo\", \"nome_cbo\" = EXCLUDED.\"nome_cbo\"", sql_update)
  @test !occursin("no_cbo\" = EXCLUDED", sql_update)   # logical name must not leak

  # db_column field as the conflict target resolves to the physical column too.
  @test occursin("ON CONFLICT (\"nome_cbo\") DO UPDATE SET \"co_cbo\" = EXCLUDED.\"co_cbo\"",
    _cbo_sql((action = :update, target = ["no_cbo"], set = ["co_cbo"])))

  # Documented allowance: `set` may overlap `target` (harmless self-assignment; PG/SQLite permit it).
  @test occursin("ON CONFLICT (\"id\") DO UPDATE SET \"id\" = EXCLUDED.\"id\", \"co_cbo\" = EXCLUDED.\"co_cbo\"",
    _cbo_sql((action = :update, target = ["id"], set = ["id", "co_cbo"])))

  # Documented allowance: a `target` column need NOT participate in the INSERT — only `set` must.
  # Here `columns=` drops no_cbo from the insert, yet it is a valid conflict target (existence-only).
  @test occursin("ON CONFLICT (\"nome_cbo\") DO UPDATE SET \"co_cbo\" = EXCLUDED.\"co_cbo\"",
    _cbo_sql((action = :update, target = ["no_cbo"], set = ["co_cbo"]); columns = ["id", "co_cbo"]))
end

@testset "on_conflict binds no parameters and reaches every chunk" begin
  res_plain = PormG.QueryBuilder.bulk_insert(ConflictCbo, CBO_DF_123; show_query = :dict)
  res_clause = PormG.QueryBuilder.bulk_insert(ConflictCbo, CBO_DF_123;
    show_query = :dict, on_conflict = (action = :update, target = ["id"], set = ["no_cbo"]))
  @test res_clause[:parameters] == res_plain[:parameters]

  # chunk_size=1 splits the 2-row frame into 2 statements — each carries the clause.
  chunked = PormG.QueryBuilder.bulk_insert(ConflictCbo, CBO_DF_123;
    show_query = :dict, chunk_size = 1, on_conflict = :nothing)
  @test chunked isa Vector
  @test length(chunked) == 2
  @test all(res -> occursin("ON CONFLICT DO NOTHING", res[:sql_text]), chunked)
end

@testset "on_conflict SQLite end-to-end and shared renderer" begin
  # Same clause through the SQLite mock end-to-end (syntax is shared, SQLite ≥3.24).
  @test occursin("ON CONFLICT (\"id\") DO UPDATE SET \"co_cbo\" = EXCLUDED.\"co_cbo\"",
    _cbo_sql((action = :update, target = ["id"], set = ["co_cbo"]); model = ConflictCboSl))

  # The Dialect renderer is one Union method: identical output for both backends.
  for (action, target, set, expected) in (
    (:nothing, String[], String[], "ON CONFLICT DO NOTHING"),
    (:nothing, ["\"id\""], String[], "ON CONFLICT (\"id\") DO NOTHING"),
    (:update, ["\"id\""], ["\"co_cbo\"", "\"nome_cbo\""],
      "ON CONFLICT (\"id\") DO UPDATE SET \"co_cbo\" = EXCLUDED.\"co_cbo\", \"nome_cbo\" = EXCLUDED.\"nome_cbo\""),
  )
    pg_clause = PormG.Dialect.on_conflict_clause(action, target, set, MockPgConflict())
    sl_clause = PormG.Dialect.on_conflict_clause(action, target, set, MockSqliteConflict())
    @test pg_clause == expected
    @test sl_clause == expected
  end

  # Renderer guards (PR 2 will call it directly, so they must hold without the
  # bulk_insert normalization in front).
  @test_throws ArgumentError PormG.Dialect.on_conflict_clause(:merge, ["\"id\""], String[], MockPgConflict())
  @test_throws ArgumentError PormG.Dialect.on_conflict_clause(:update, String[], ["\"co_cbo\""], MockPgConflict())
  @test_throws ArgumentError PormG.Dialect.on_conflict_clause(:update, ["\"id\""], String[], MockPgConflict())
end

# Runs bulk_insert with :dict (validation fires before any DB call) and hands
# back the ArgumentError message for assertion.
function _cbo_error(on_conflict; kwargs...)
  err = try
    PormG.QueryBuilder.bulk_insert(ConflictCbo, CBO_DF_123;
      show_query = :dict, on_conflict = on_conflict, kwargs...)
    nothing
  catch e
    e
  end
  @test err isa PormGError
  return err === nothing ? "" : sprint(showerror, err)
end

@testset "on_conflict validation errors" begin
  @test occursin("only accepts :nothing", _cbo_error(:ignore))
  @test occursin("must be nothing, :nothing or a NamedTuple", _cbo_error(42))
  @test occursin("requires an action key", _cbo_error((target = ["id"],)))
  @test occursin("unknown key", _cbo_error((action = :nothing, taget = ["id"])))
  @test occursin("must be :nothing or :update", _cbo_error((action = :merge, target = ["id"], set = ["co_cbo"])))
  @test occursin("non-empty target", _cbo_error((action = :update, set = ["co_cbo"])))
  @test occursin("non-empty target", _cbo_error((action = :update, target = String[], set = ["co_cbo"])))
  @test occursin("non-empty set", _cbo_error((action = :update, target = ["id"])))
  @test occursin("only valid with action :update", _cbo_error((action = :nothing, target = ["id"], set = ["co_cbo"])))
  @test occursin("must be a vector of field-name strings", _cbo_error((action = :nothing, target = "id")))
  @test occursin("duplicate column entries", _cbo_error((action = :update, target = ["id", "id"], set = ["co_cbo"])))
  @test occursin("is not a field", _cbo_error((action = :nothing, target = ["not_a_field"])))
  @test occursin("is not a field", _cbo_error((action = :update, target = ["id"], set = ["not_a_field"])))
  # `set` must participate in the INSERT: EXCLUDED.col for a non-inserted column
  # would silently write the column default instead of a caller value.
  @test occursin("does not participate",
    _cbo_error((action = :update, target = ["id"], set = ["no_cbo"]); columns = ["id", "co_cbo"]))
end

# ─────────────────────────────────────────────────────────────────────────────
# Retry-skip (#123 × sequence resync): with on_conflict active, a surviving
# duplicate-key error means a DIFFERENT constraint than the clause target
# conflicted — the resync-and-retry path must NOT run (it would fail
# identically), and the error must propagate after exactly one attempt.
# Contrast: test_sequence_sync.jl pins the retry WITHOUT on_conflict.
# ─────────────────────────────────────────────────────────────────────────────
struct MockPgConflictRetry <: PormG.PormGPostgres end

const ON_CONFLICT_RETRY_SQL = String[]
const ON_CONFLICT_INSERT_ATTEMPTS = Ref(0)

function fetch(connection::MockPgConflictRetry, sql::String;
  conn = nothing,
  params = nothing,
  ignore_tx::Bool = false)
  push!(ON_CONFLICT_RETRY_SQL, sql)

  if occursin("INSERT INTO", sql)
    ON_CONFLICT_INSERT_ATTEMPTS[] += 1
    throw(ErrorException("duplicate key value violates unique constraint"))
  elseif occursin("pg_get_serial_sequence", sql)
    return DataFrame(pg_get_serial_sequence = ["public.dash_dim_cbo_id_seq"])
  elseif occursin("setval", sql)
    return DataFrame(setval = [3])
  end

  return DataFrame()
end

@testset "on_conflict skips the duplicate-key sequence-resync retry" begin
  empty!(ON_CONFLICT_RETRY_SQL)
  ON_CONFLICT_INSERT_ATTEMPTS[] = 0

  settings = PormG.Configuration.Settings(
    connections = MockPgConflictRetry(),
    change_db = true,
    change_data = true,
  )

  params = PormG.QueryBuilder.PgParameterizedQuery("", Any[], 0)
  PormG.QueryBuilder.add_parameter!(params, 1)
  PormG.QueryBuilder.add_parameter!(params, "225125")

  err = try
    PormG.QueryBuilder._bulk_insert(
      ConflictCbo,
      settings.connections,
      ["id", "co_cbo"],
      ["(\$1, \$2)"],
      true,
      ["id"],
      settings,
      false,
      :execute,
      params;
      on_conflict_sql = "ON CONFLICT DO NOTHING",   # pre-rendered clause; non-nothing gates the retry off
    )
    nothing
  catch e
    e
  end

  # The duplicate-key error propagates untouched after a single attempt…
  @test err !== nothing
  @test occursin("duplicate key value violates unique constraint", string(err))
  @test ON_CONFLICT_INSERT_ATTEMPTS[] == 1
  # …the executed statement really carried the clause…
  @test any(sql -> occursin("ON CONFLICT DO NOTHING", sql), ON_CONFLICT_RETRY_SQL)
  # …and no sequence-resync machinery ever ran.
  @test !any(sql -> occursin("pg_get_serial_sequence", sql), ON_CONFLICT_RETRY_SQL)
  @test !any(sql -> occursin("setval", sql), ON_CONFLICT_RETRY_SQL)
end
