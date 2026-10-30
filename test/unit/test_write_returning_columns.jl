# ============================================================
# test/unit/test_write_returning_columns.jl
#
# A write hands its row back through the model's declared columns, never `*` (#1490).
#
# CONTRACT being tested:
#   `create()`, `update_or_create()` and `get_or_create()` name every declared column that owns one —
#   declaration order, the physical `db_column` name, no many-to-many field — wherever they read the
#   row they wrote: PostgreSQL's `RETURNING`, and the read-backs on SQLite and MySQL.
#
#   Why: under the Postgres.jl statement cache (#1479) an `INSERT … RETURNING *` is a prepared
#   statement whose result type follows the TABLE. A concurrent `ADD COLUMN` (a deploy's `migrate`)
#   then makes PostgreSQL refuse it with 0A000 *cached plan must not change result type*, and inside a
#   transaction the transaction is lost. Naming the columns makes the result type the model's. It also
#   makes the row the model's on every engine: a column the model does not declare is not on it.
#
# DB-free: the PostgreSQL statements are read with `show_query`, and the SQLite/MySQL read-backs are
# the statements `_inserted_row_query` / `_select_by_target` build. The live half — the cached INSERT
# surviving an ADD COLUMN, and the row's keys on each engine — is in
# test/integration/test_postgres_statement_cache.jl and test/integration/test_write_returns_declared_fields.jl.
# ============================================================

using Test
using PormG
using PormG.Models: Model, CharField, IDField, IntegerField, ManyToManyField

const _WRC_QB = PormG.QueryBuilder

struct MockPgWRC <: PormG.PormGPostgres end
struct MockSqliteWRC <: PormG.PormGSQLite end
struct MockMySQLWRC <: PormG.PormGMySQL end
PormG.backend_sqlite_version(::MockSqliteWRC) = 3045000
# No AUTO_INCREMENT id in the OK packet, so MySQL reads the key back by the value the INSERT bound.
PormG.backend_last_insert_id(::MockMySQLWRC, ::Nothing) = 0

PormG.config["wrc_pg"] = PormG.Configuration.Settings(connections = MockPgWRC(), change_data = true)

# The F1 driver, with a `db_column` field and a many-to-many one: `code` lives in `driver_code`, and
# `teams` owns no column of the driver table.
WrcTeam = Model("team", teamid = IDField(), name = CharField())
WrcDriver = Model("driver",
  driverid = IDField(),
  forename = CharField(),
  code = CharField(db_column = "driver_code", null = true),
  number = IntegerField(null = true),
  teams = ManyToManyField(WrcTeam),
)
WrcDriver.connect_key = "wrc_pg"

const WRC_PG_COLUMNS = "\"driverid\", \"forename\", \"driver_code\", \"number\""

# ─────────────────────────────────────────────────────────────────────────────
# The column list itself.
# Expected: `"driverid", "forename", "driver_code", "number"` on PostgreSQL and SQLite, backticked on
# MySQL — declaration order, the physical name for `code`, and no `teams`.
# Why: every site below interpolates this one list, so its shape is the contract for all of them.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1490: the returned columns are the declared ones, physical, in order" begin
  @test _WRC_QB._returned_columns(WrcDriver, MockPgWRC()) == WRC_PG_COLUMNS
  @test _WRC_QB._returned_columns(WrcDriver, MockSqliteWRC()) == WRC_PG_COLUMNS
  @test _WRC_QB._returned_columns(WrcDriver, MockMySQLWRC()) == "`driverid`, `forename`, `driver_code`, `number`"
end

# ─────────────────────────────────────────────────────────────────────────────
# PostgreSQL: the three RETURNING clauses, as `show_query` shows what executes (#48).
# Expected:
#   create()           … RETURNING "driverid", "forename", "driver_code", "number";
#   update_or_create() … RETURNING "driverid", …, "number", (xmax = 0) AS "__pormg_created";
#   get_or_create()    … ON CONFLICT ("forename") DO NOTHING RETURNING "driverid", …, "number";
# Why: these are the statements the Postgres.jl cache keeps per connection; `*` in any of them is the
#      0A000 of #1490. The created sentinel stays last, after the fields, where the reader pops it.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1490: PostgreSQL writes return the declared columns, never *" begin
  sql = WrcDriver.objects.create("forename" => "Ayrton", "code" => "SEN"; show_query = :sql)
  @test endswith(rstrip(sql), "RETURNING $(WRC_PG_COLUMNS);")

  sql = WrcDriver.objects.update_or_create("driverid" => 1; defaults = ["forename" => "Ayrton"], show_query = :sql)
  @test endswith(rstrip(sql), "RETURNING $(WRC_PG_COLUMNS), (xmax = 0) AS \"__pormg_created\";")

  sql = WrcDriver.objects.get_or_create("forename" => "Ayrton"; show_query = :sql)
  @test occursin("DO NOTHING", sql) && endswith(rstrip(sql), "RETURNING $(WRC_PG_COLUMNS);")

  for s in (WrcDriver.objects.create("forename" => "A"; show_query = :sql),
            WrcDriver.objects.update_or_create("driverid" => 1; defaults = ["forename" => "A"], show_query = :sql),
            WrcDriver.objects.get_or_create("forename" => "A"; show_query = :sql))
    @test !occursin("*", s)
    @test !occursin("\"teams\"", s)
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# SQLite and MySQL: the read-backs a write runs instead of RETURNING.
# Expected:
#   SQLite create()  SELECT "driverid", …, "number" FROM "driver" WHERE rowid = last_insert_rowid();
#   MySQL create()   SELECT `driverid`, …, `number` FROM `driver` WHERE `driverid` = ?
#   the by-target read-back (update_or_create's, and get_or_create's miss): SELECT <columns> … LIMIT 1
# Why: the row a write returns must carry the same fields on every engine, or `keys(row)` after
#      `create()` would depend on the backend.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1490: SQLite and MySQL read the written row back by its declared columns" begin
  # A read-back qualifies each column with its table: on SQLite a bare `"x"` that names no column is
  # the string 'x', so a field the table lacks would read back as its own name instead of raising.
  sl = _WRC_QB._inserted_row_query(MockSqliteWRC(), WrcDriver, Dict{String,Any}(), nothing, "\"driver\"")
  @test sl == ("SELECT \"driver\".\"driverid\", \"driver\".\"forename\", \"driver\".\"driver_code\", " *
               "\"driver\".\"number\" FROM \"driver\" WHERE rowid = last_insert_rowid();", nothing)

  my = _WRC_QB._inserted_row_query(MockMySQLWRC(), WrcDriver, Dict{String,Any}("driverid" => 7), nothing, "`driver`")
  @test my[1] == "SELECT `driver`.`driverid`, `driver`.`forename`, `driver`.`driver_code`, `driver`.`number` " *
                 "FROM `driver` WHERE `driverid` = ?"
  @test my[2].where_params == Any[7]
end

# ─────────────────────────────────────────────────────────────────────────────
# SQLite, against a real temp database whose table has a column the model does not declare (`team`).
# Expected keys: create(), both arms of update_or_create() and a get_or_create() miss → the declared
# fields only; a get_or_create() hit and a get() → `team` too, since those are reads (decided on
# #1490). Why: the SQL-text checks above cannot see which statement a write runs for its read-back;
# get_or_create's miss used to re-read through the lookup (`SELECT *`), and putting that back passes
# every one of them. This catches it without a server.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1490: on SQLite a written row has the model's fields, a found row the table's" begin
  include(joinpath(@__DIR__, "..", "load_drivers.jl"))
  mktempdir() do dir
    pool = PormG.ConnectionPool.SQLiteConnectionPool(joinpath(dir, "wrc_1490.sqlite"); pool_size = 1)
    key = "wrc_sqlite_1490"
    PormG.config[key] = PormG.Configuration.Settings(connections = pool, db_def_folder = dir, change_data = true)
    try
      PormG.ConnectionPool.fetch(pool,
        "CREATE TABLE driver (driverid INTEGER PRIMARY KEY, surname TEXT NOT NULL, team TEXT);")
      m = Model("driver", driverid = IDField(generated = false), surname = CharField())
      m.connect_key = key
      declared = Set([:driverid, :surname])

      @test Set(keys(m.objects.create("driverid" => 1, "surname" => "Senna"))) == declared
      @test :team in keys(m.objects.get("driverid" => 1))

      row, created = m.objects.update_or_create("driverid" => 2; defaults = ["surname" => "Prost"])
      @test created && Set(keys(row)) == declared
      row, created = m.objects.update_or_create("driverid" => 2; defaults = ["surname" => "Alain Prost"])
      @test !created && Set(keys(row)) == declared && row.surname == "Alain Prost"

      row, created = m.objects.get_or_create("driverid" => 3; defaults = ["surname" => "Piquet"])
      @test created && Set(keys(row)) == declared
      row, created = m.objects.get_or_create("driverid" => 3)
      @test !created && :team in keys(row)

      # A declared field the table does not have (code deployed before `migrate`) raises, as on
      # PostgreSQL and MySQL. Unqualified, SQLite read `"nickname"` back as the string 'nickname'.
      ahead = Model("driver", driverid = IDField(generated = false), surname = CharField(),
                    nickname = CharField(null = true))
      ahead.connect_key = key
      # The cause is the missing column, not "the row could not be read back" (also a StatementError).
      for write in (() -> ahead.objects.create("driverid" => 4, "surname" => "Lauda"),
                    () -> ahead.objects.get_or_create("driverid" => 5; defaults = ["surname" => "Hunt"]))
        e = try write(); nothing catch err err end
        @test e isa PormG.StatementError
        @test occursin("no such column", sprint(showerror, e))
      end
    finally
      delete!(PormG.config, key)
      PormG.ConnectionPool.close_pool!(pool)   # release the handle so Windows can delete the temp dir
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# The source: no write path in execution_write.jl or the read-back facts names `*` any more.
# Expected: no `RETURNING *` and no `SELECT *` head in a statement those two files build, apart from
#           the derived-table wrapper `SELECT * FROM (` that update()/delete() materialize, whose
#           columns its own inner SELECT names, and the one named read of a FOUND row,
#           `const _FOUND_ROW_HEAD = "SELECT *"` (get_or_create's locking re-read of a race winner).
# Why: the sites above are the ones known today; a new write path that reached for `*` would pass
#      them and reopen #1490.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1490: no write path builds a wildcard read" begin
  dir = joinpath(pkgdir(PormG), "src", "querybuilder")
  found_row = "const _FOUND_ROW_HEAD = \"SELECT *\""
  for file in ("execution_write.jl", "engine_facts.jl")
    code = join((replace(l, r"#.*$" => "") for l in eachline(joinpath(dir, file))), "\n")
    @test count(found_row, code) == (file == "execution_write.jl" ? 1 : 0)
    code = replace(code, found_row => "")
    @test !occursin("RETURNING *", code)
    heads = [m.match for m in eachmatch(r"SELECT \*[^\n\"]{0,12}", code)]
    @test all(h -> startswith(h, "SELECT * FROM ("), heads) || error("$(file) builds $(heads)")
  end
end
