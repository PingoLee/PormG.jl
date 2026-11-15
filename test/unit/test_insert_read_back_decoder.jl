# ============================================================
# test/unit/test_insert_read_back_decoder.jl
#
# CONTRACT being tested:
#   The row `create()` hands back after SQLite's and MySQL's read-back is decoded as it is read
#   (`QueryBuilder._FieldRowDecoder`, #1599 layer 7, #1694): on SQLite the extension steps the statement
#   straight into the field-keyed Dict; a materialized result (MySQL's, a stand-in pool's) is decoded by
#   the decoder's call. Either way the row is exactly what `_row_to_field_keyed_dict` built from the
#   driver's row before: the same keys (a field's name for its column, a column's own name otherwise),
#   the same values at the same types, and a parser's refusal raised with the same type and text.
#   `_row_to_field_keyed_dict` is the oracle here.
#
# Hermetic: an in-memory SQLite database for the SQLite path; the pools only select each engine's parsers.
#
# Run: julia --project=test/integration test/unit/test_insert_read_back_decoder.jl
# ============================================================

using Test
using PormG
using Dates: Dates
isdefined(Main, :SQLite) || include(joinpath(@__DIR__, "..", "load_drivers.jl"))

const _RBD_QB = PormG.QueryBuilder
const _RBD_M = PormG.Models
const _RBD_CP = PormG.ConnectionPool
const _RBD_X = Base.get_extension(PormG, :PormGSQLiteExt)

# A model with a field of each read kind the read table parses on some engine, and one `db_column`.
_rbd_model(name) = _RBD_M.Model(name, raceid = _RBD_M.IDField(), year = _RBD_M.IntegerField(null = true),
  name = _RBD_M.CharField(null = true), points = _RBD_M.FloatField(null = true),
  price = _RBD_M.DecimalField(max_digits = 5, decimal_places = 2, null = true), date = _RBD_M.DateField(null = true),
  start_at = _RBD_M.DateTimeField(null = true), lap = _RBD_M.TimeField(null = true),
  lap_time = _RBD_M.DurationField(null = true), done = _RBD_M.BooleanField(null = true),
  uid = _RBD_M.UUIDField(null = true), data = _RBD_M.JSONField(null = true), blob = _RBD_M.BinaryField(null = true),
  label = _RBD_M.CharField(db_column = "label_col", null = true))

_rbd_outcome(f) = try
  r = f()
  (:ok, sort!(collect(keys(r))), Dict(k => typeof(v) for (k, v) in r), r)
catch e
  (:err, typeof(e), sprint(showerror, e))
end
_rbd_same(a, b) = a[1] === b[1] && (a[1] === :err ? a[2:3] == b[2:3] : (a[2] == b[2] && a[3] == b[3] && isequal(a[4], b[4])))

# What: the extension's read-back (`_sqlite_field_rows`) against the old path on the same statement
#   (`Tables.rowtable` of the cursor, then `_row_to_field_keyed_dict`), over rows that put each storage class in
#   the model's columns (text dates, timestamps, times and intervals; integers and reals; a boolean as 0/1;
#   a BLOB; NULL everywhere), a `db_column` field, a column that is no field's, and a decimal too wide for its
#   field (the parser's refusal, `StatementError` 22003).
# Expected: the same keys, values and value types, or the same error type and text.
# SQL: `SELECT <the declared columns> FROM race WHERE rowid = ?` (the read-back's shape), one row per case.
# Why: this is the row every `create()` returns on SQLite; the decoder replaced a call a trimmed image has no
#   code for (#1599), and it must change nothing under the JIT.
@testset "the insert's read-back decodes into the row _row_to_field_keyed_dict built (SQLite, #1599 layer 7)" begin
  Tables = _RBD_X.Tables
  model = _rbd_model("rbd_race")
  pool = _RBD_CP.SQLiteConnectionPool(":memory:"; pool_size = 1)
  db = SQLite.DB()
  SQLite.execute(db, "CREATE TABLE rbd_race (raceid INTEGER PRIMARY KEY, year INTEGER, name TEXT, points REAL, " *
                     "price NUMERIC(5,2), date TEXT, start_at TEXT, lap TEXT, lap_time TEXT, done INTEGER, uid TEXT, " *
                     "data TEXT, blob BLOB, label_col TEXT, extra TEXT)")
  SQLite.execute(db, "INSERT INTO rbd_race VALUES " *
    "(1, 2009, 'Monaco Grand Prix', 25.5, '12.30', '2009-05-24', '2009-05-24T14:00:00.000+00:00', '14:00:00', " *
    "'00:01:27.452', 1, '550e8400-e29b-41d4-a716-446655440000', '{\"a\":1}', x'0102', 'M', 'x'), " *
    "(2, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL), " *
    "(3, 2010, 'Spa', 3, 7, '2010-08-29', '2010-08-29 13:00:00', '13:00', '90.5', 0, 'not-a-uuid', '[1,2]', x'', '', 'y'), " *
    "(4, 2011, 'Monza', 1.0, '12345.67', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL)")
  cols = _RBD_QB._returned_columns(model, pool, "\"rbd_race\"")
  oracle(sql) = begin
    stmt = SQLite.Stmt(db, sql; register = false)
    rows = try
      Tables.rowtable(SQLite.DBInterface.execute(stmt))
    finally
      SQLite.DBInterface.close!(stmt)
    end
    _RBD_QB._row_to_field_keyed_dict(rows[1], model, pool)
  end
  decoded(sql) = begin
    d = _RBD_QB._FieldRowDecoder(model, pool)
    _RBD_QB.decoded_on_worker(d, _RBD_X._sqlite_field_rows(db, sql, nothing, d))[1]
  end
  for id in 1:4, select in (cols, cols * ", extra")
    sql = "SELECT $(select) FROM \"rbd_race\" WHERE rowid = $(id)"
    a, b = _rbd_outcome(() -> decoded(sql)), _rbd_outcome(() -> oracle(sql))
    @test _rbd_same(a, b)
  end
  # The refusal is the one the parser raises, not a wrapped one.
  r = _rbd_outcome(() -> decoded("SELECT $(cols) FROM \"rbd_race\" WHERE rowid = 4"))
  @test r[1] === :err && r[2] === PormG.StatementError
  # A bound parameter, as MySQL's read-back binds one, takes the same path.
  d = _RBD_QB._FieldRowDecoder(model, pool)
  rows = _RBD_QB.decoded_on_worker(d, _RBD_X._sqlite_field_rows(db, "SELECT $(cols) FROM \"rbd_race\" WHERE rowid = ?", Any[1], d))
  @test _rbd_same(_rbd_outcome(() -> rows[1]), _rbd_outcome(() -> oracle("SELECT $(cols) FROM \"rbd_race\" WHERE rowid = 1")))
  close(db)
  _RBD_CP.close_pool!(pool)
end

# What: the decoder's call on a materialized result (MySQL's read-back, and a stand-in pool's through
#   `backend_execute_rows`' fallback), against `_row_to_field_keyed_dict` on each of its rows, with each engine's
#   parsers (MySQL, PostgreSQL, SQLite): text and typed temporal values, a decimal, a boolean as 0/1, NULLs, a
#   `db_column` field and a column that is no field's.
# Expected: the same rows; `decode_on_worker` records a parser's refusal and `decoded_on_worker` raises it.
# Why: the MySQL read-back now decodes through this call (`fetch(…; _decode)`); before, it went through
#   `Tables.rowtable` and `_row_to_field_keyed_dict` after `fetch`.
@testset "a materialized read-back decodes into the row _row_to_field_keyed_dict built (#1599 layer 7)" begin
  model = _rbd_model("rbd_race_m")
  rows = [(raceid = 1, year = 2009, name = "Monaco", points = 25.5, price = "12.30", date = "2009-05-24",
           start_at = "2009-05-24 14:00:00", lap = "14:00:00", lap_time = "00:01:27.452", done = 1,
           uid = "550e8400-e29b-41d4-a716-446655440000", data = "{\"a\":1}", blob = UInt8[1, 2], label_col = "M",
           extra = "x"),
          (raceid = 2, year = missing, name = missing, points = missing, price = missing, date = missing,
           start_at = missing, lap = missing, lap_time = missing, done = missing, uid = missing, data = missing,
           blob = missing, label_col = missing, extra = missing),
          (raceid = 3, year = 2010, name = "Spa", points = 3.0, price = _RBD_M.Decimals.Decimal(0, 7, 0),
           date = Dates.Date(2010, 8, 29), start_at = Dates.DateTime(2010, 8, 29, 13), lap = Dates.Time(13),
           lap_time = Dates.Second(90), done = true, uid = "x", data = "[1,2]", blob = UInt8[], label_col = "",
           extra = "y")]
  pools = (_RBD_CP.MySQLConnectionPool("host='x'"; pool_size = 1), _RBD_CP.PostgresConnectionPool("host=x dbname=y"),
           _RBD_CP.SQLiteConnectionPool(":memory:"; pool_size = 1))
  for pool in pools, row in rows
    d = _RBD_QB._FieldRowDecoder(model, pool)
    a = _rbd_outcome(() -> _RBD_QB.decoded_on_worker(d, _RBD_QB.decode_on_worker(d, [row]))[1])
    b = _rbd_outcome(() -> _RBD_QB._row_to_field_keyed_dict(row, model, pool))
    @test _rbd_same(a, b)
  end
  # A refusal (SQLite's declared-decimal parser on a value too wide): recorded, then raised as it was.
  pool = pools[3]
  wide = [(raceid = 4, price = 12345.67)]
  d = _RBD_QB._FieldRowDecoder(model, pool)
  @test _RBD_QB.decode_on_worker(d, wide) == Dict{Symbol,Any}[]
  a = _rbd_outcome(() -> _RBD_QB.decoded_on_worker(d, Dict{Symbol,Any}[]))
  b = _rbd_outcome(() -> _RBD_QB._row_to_field_keyed_dict(wide[1], model, pool))
  @test a[1] === :err && a[2:3] == b[2:3]
  foreach(p -> _RBD_CP.close_pool!(p), pools)
end
