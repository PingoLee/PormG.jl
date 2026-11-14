# ============================================================
# test/unit/test_sqlite_materialize.jl
#
# CONTRACT being tested:
#   The SQLite extension materializes every non-typed statement's result (`backend_execute`, what
#   `fetch` returns on SQLite) as exactly what `Tables.rowtable(cursor)` returned: the same `Vector`
#   type, the same row types and values, the same element type for no rows. #1599 replaced the call,
#   which a `juliac --trim` image has no code for, with a construction from builtins
#   (`_sqlite_rowtable`); `Tables.rowtable` is the oracle here.
#
# Hermetic: an in-memory SQLite database, no pool.
#
# Run: julia --project=test/integration test/unit/test_sqlite_materialize.jl
# ============================================================

using Test
using PormG
isdefined(Main, :SQLite) || include(joinpath(@__DIR__, "..", "load_drivers.jl"))

const _SMX = Base.get_extension(PormG, :PormGSQLiteExt)

# What: `_sqlite_execute_materialized(db, sql, params)` against `Tables.rowtable` on the same statement,
#   over: a column of each storage class (INTEGER, REAL, TEXT, BLOB, NULL) and a column without a declared
#   type holding several; a column whose type changes from one row to the next (so the element type
#   widens), and one that never does (so it stays concrete); NULLs; repeated column names (`x`, `x_1`);
#   no rows from a table with declared types (the element type comes from the schema); an INSERT (no
#   columns); a PRAGMA; a bound parameter; a computed column; a statement the server refuses.
# Expected: `typeof` of the result, of each row and each value, and the values themselves (`isequal`)
#   equal the oracle's; a refused statement raises the same error type and message.
# SQL: the statements below, run twice each (once per path) on one in-memory database.
# Why: every non-typed SQLite read and write goes through this result, and about a hundred readers in
#   core take it as `Tables.rowtable` built it (`r.name`, `r[1]`, `pairs(row)`, `Tables.columntable`,
#   `fetch`'s docstring); the construction must change nothing under the JIT (#1599).
@testset "SQLite materializes a result exactly as Tables.rowtable did (#1599)" begin
  Tables = _SMX.Tables
  db = SQLite.DB()
  SQLite.execute(db, "CREATE TABLE t (a INTEGER, b TEXT, c REAL, d BLOB, e, f DATETIME, g NUMERIC(10,2))")
  SQLite.execute(db, "INSERT INTO t VALUES (1, 'Senna', 1.5, x'0102', NULL, '1988-05-15 14:30:00', 2.5), " *
                     "(NULL, 'Prost', 2, NULL, 'z', NULL, 3), (3, NULL, NULL, NULL, 4, NULL, NULL), " *
                     "(4, 'Piquet', 0.25, x'', 1.5, '1990', 7)")
  SQLite.execute(db, "CREATE TABLE same (id INTEGER, name TEXT)")
  SQLite.execute(db, "INSERT INTO same VALUES (1, 'Monaco'), (2, 'Spa'), (3, 'Monza')")
  oracle(sql, params) = begin
    stmt = SQLite.Stmt(db, sql; register = false)
    try
      q = params === nothing ? SQLite.DBInterface.execute(stmt) : SQLite.DBInterface.execute(stmt, params)
      Tables.rowtable(q)
    finally
      SQLite.DBInterface.close!(stmt)
    end
  end
  outcome(f) = try
    r = f()
    (:ok, typeof(r), map(typeof, r), [map(typeof, values(row)) for row in r], r)
  catch e
    (:err, typeof(e), sprint(showerror, e))
  end
  cases = [("SELECT * FROM t", nothing),
           ("SELECT * FROM same", nothing),                          # one row type: a concrete element type
           ("SELECT id FROM same WHERE id > 1", nothing),
           ("SELECT a AS x, a AS x FROM t", nothing),                 # repeated names
           ("SELECT * FROM t WHERE a > 100", nothing),                # no rows: the schema's types
           ("SELECT * FROM same WHERE id > 100", nothing),
           ("SELECT name FROM same WHERE id = ?", Any[2]),
           ("SELECT count(*) AS n, max(c) FROM t", nothing),
           ("SELECT 1", nothing),
           ("PRAGMA table_info(t)", nothing),
           ("INSERT INTO same VALUES (4, 'Suzuka')", nothing),       # no columns
           ("SELECT * FROM pormg_missing", nothing)]                 # refused
  for (sql, params) in cases
    old = outcome(() -> oracle(sql, params))
    new = outcome(() -> _SMX._sqlite_execute_materialized(db, sql, params))
    @test (sql, isequal(new, old)) == (sql, true)
  end
  # The two paths really are two: the construction is reached for the cursor PormG builds.
  stmt = SQLite.Stmt(db, "SELECT * FROM same"; register = false)
  @test SQLite.DBInterface.execute(stmt) isa SQLite.Query{false}
  SQLite.DBInterface.close!(stmt)
  close(db)
end
