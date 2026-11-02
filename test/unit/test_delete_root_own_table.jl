"""
Unit coverage for #1370: a `delete()` whose root filter reads only the root's own columns, while a
`SET_NULL` / `SET_DEFAULT` statement of the cascade writes the root's own table.

The deletion collector runs every `SET_NULL` / `SET_DEFAULT` update before any delete, and the root's
`DELETE` ran last and re-read its own predicate. #1342 resolved the root's keys first only when that
predicate read another table, so an own-column filter was re-read after the update: rows the cascade
only meant to update were deleted, with no error. Since #1370 the keys are read first for every
filtered root with something to cascade:

  1. `SELECT "Tb"."<pk>" FROM <root> AS "Tb" WHERE <filter>` (`FOR UPDATE` on PostgreSQL and MySQL);
  2. every statement after it scoped by `"<pk>__@in" => keys`, nothing re-reading the filter.

Shapes:

  - a second model over the root's table declares the key the root does not: `team` keeps
    `favourite_driver` as an integer, an unmanaged `team_view` over the same table declares it as a
    SET_NULL foreign key to a driver, and a driver CASCADEs from its team. Before #1370 a delete of the
    teams with no favourite driver also deleted the team whose favourite driver the cascade had just
    nulled, and that team's drivers;
  - a self-referential SET_NULL / SET_DEFAULT key, and a cycle through a child: the statement targets
    a model already in the cascade. `topological_sort` refused these as a cycle until #1374, which
    stopped a SET_NULL / SET_DEFAULT relation from ordering the deletes; the key read is what keeps
    them right, and each now gives Django's result. A self-referential CASCADE is still refused;
  - controls: the same schemas over rows that do not cycle, and an unfiltered delete, which keeps its
    statements.

The rows are executed on a temp SQLite file. The mocks render the same plan for each engine; on a mock
the key read returns no keys, so the statements after it render over the empty set.
"""
# julia --project=test/integration -e 'include("test/load_drivers.jl"); include("test/unit/test_delete_root_own_table.jl")'

using Test
using DataFrames
using PormG
using PormG.Models
import PormG.ConnectionPool: fetch, SQLiteConnectionPool

struct LnMockSQLite <: PormG.PormGSQLite end
struct LnMockPostgres <: PormG.PormGPostgres end
struct LnMockMySQL <: PormG.PormGMySQL end
PormG.backend_sqlite_version(::LnMockSQLite) = 3045000
PormG.backend_mysql_parameter_limit(::LnMockMySQL) = 4096

const _LN_DIR  = mktempdir()
const _LN_POOL = SQLiteConnectionPool(joinpath(_LN_DIR, "ln1370.sqlite"); pool_size = 1)
PormG.config["ln1370_sqlite"] = PormG.Configuration.Settings(
  connections = _LN_POOL, db_def_folder = "ln1370_sqlite", change_data = true)

# A constructor lineage, where `predecessor` points at the team a team was renamed from, once per
# on_delete. A team whose favourite driver may race for another team, which a team's drivers CASCADE
# from. And the same teams again, with the favourite driver's key declared on an unmanaged second
# model over the team table instead of on the team.
module LnModels
import PormG
import PormG.Models
Ln_lineage = Models.Model("ln_lineage",
  id          = Models.IDField(),
  name        = Models.CharField(),
  predecessor = Models.ForeignKey("Ln_lineage", on_delete = "SET_NULL", related_name = "successors", null = true),
)
Ln_lineage_default = Models.Model("ln_lineage_default",
  id          = Models.IDField(),
  name        = Models.CharField(),
  predecessor = Models.ForeignKey("Ln_lineage_default", on_delete = "SET_DEFAULT", related_name = "successors", null = true, default = 1),
)
Ln_lineage_cascade = Models.Model("ln_lineage_cascade",
  id          = Models.IDField(),
  name        = Models.CharField(),
  predecessor = Models.ForeignKey("Ln_lineage_cascade", on_delete = "CASCADE", related_name = "successors", null = true),
)
Ln_team = Models.Model("ln_team",
  id               = Models.IDField(),
  name             = Models.CharField(),
  favourite_driver = Models.ForeignKey("Ln_driver", on_delete = "SET_NULL", related_name = "fans", null = true),
)
Ln_driver = Models.Model("ln_driver",
  id      = Models.IDField(),
  surname = Models.CharField(),
  team    = Models.ForeignKey(Ln_team, on_delete = "CASCADE", related_name = "drivers"),
)
Ln_squad = Models.Model("ln_squad",
  id               = Models.IDField(),
  name             = Models.CharField(),
  favourite_driver = Models.IntegerField(null = true),
)
Ln_squad_view = Models.Model("ln_squad_view", db_table = "ln_squad", managed = false,
  id               = Models.IDField(),
  name             = Models.CharField(),
  favourite_driver = Models.ForeignKey("Ln_squad_driver", on_delete = "SET_NULL", related_name = "fans", null = true, db_constraint = false),
)
Ln_squad_driver = Models.Model("ln_squad_driver",
  id      = Models.IDField(),
  surname = Models.CharField(),
  team    = Models.ForeignKey(Ln_squad, on_delete = "CASCADE", related_name = "drivers"),
)
PormG.Models.set_models(@__MODULE__, "ln1370_sqlite")
end

const LN = LnModels
const _LN_LINEAGES = ("ln_lineage", "ln_lineage_default", "ln_lineage_cascade")
const _LN_MOCKS = (("SQLite", LnMockSQLite()), ("PostgreSQL", LnMockPostgres()), ("MySQL", LnMockMySQL()))
_ln_steps(q, conn) = (res = q.delete(show_query = :dict, connection = conn); res isa Vector ? res : [res])
_ln_ops(steps) = [(s[:operation], s[:model]) for s in steps]
_ln_rows(table) = [Tuple(r) for r in eachrow(fetch(_LN_POOL, "SELECT * FROM $(table) ORDER BY id;") |> DataFrame)]
_ln_caught(f) = try f(); nothing catch e; e end
# The key read: a `:select` step on SQLite, the root's `:lock` (`FOR UPDATE`) on PostgreSQL and MySQL.
_ln_key_read(conn) = conn isa PormG.PormGSQLite ? :select : :lock

function _ln_reset!()
  for t in (_LN_LINEAGES..., "ln_driver", "ln_team", "ln_squad_driver", "ln_squad")
    fetch(_LN_POOL, "DROP TABLE IF EXISTS $(t);")
  end
  # Tyrrell <- BAR <- Honda <- Brawn in every lineage table. No ON DELETE clause: only PormG's
  # statements act on the rows.
  for t in _LN_LINEAGES
    fetch(_LN_POOL, "CREATE TABLE $(t) (id INTEGER PRIMARY KEY, name TEXT NOT NULL, predecessor INTEGER REFERENCES $(t) (id));")
    fetch(_LN_POOL, "INSERT INTO $(t) (id, name, predecessor) VALUES (1, 'Tyrrell', NULL), (2, 'BAR', 1), (3, 'Honda', 2), (4, 'Brawn', 3);")
  end
  # Tyrrell has no favourite driver. McLaren's is Stewart, who races for Tyrrell. Williams's is its own.
  for (team, driver) in (("ln_team", "ln_driver"), ("ln_squad", "ln_squad_driver"))
    fetch(_LN_POOL, "CREATE TABLE $(team) (id INTEGER PRIMARY KEY, name TEXT NOT NULL, favourite_driver INTEGER);")
    fetch(_LN_POOL, "CREATE TABLE $(driver) (id INTEGER PRIMARY KEY, surname TEXT NOT NULL, team INTEGER NOT NULL REFERENCES $(team) (id));")
    fetch(_LN_POOL, "INSERT INTO $(team) (id, name, favourite_driver) VALUES (1, 'Tyrrell', NULL), (2, 'McLaren', 10), (3, 'Williams', 30);")
    fetch(_LN_POOL, "INSERT INTO $(driver) (id, surname, team) VALUES (10, 'Stewart', 1), (20, 'Senna', 2), (30, 'Mansell', 3);")
  end
  return nothing
end

const _LN_LINEAGE_ROWS = [(1, "Tyrrell", missing), (2, "BAR", 1), (3, "Honda", 2), (4, "Brawn", 3)]
const _LN_TEAM_ROWS    = [(1, "Tyrrell", missing), (2, "McLaren", 10), (3, "Williams", 30)]
const _LN_DRIVER_ROWS  = [(10, "Stewart", 1), (20, "Senna", 2), (30, "Mansell", 3)]

# The delete `make()` builds is refused while planning, under inspection on the live pool and when it
# runs, and no row of `tables` has changed. On each engine's mock the key read comes first; it finds no
# keys there, so the plan after it renders over the empty set and has no cascade to refuse.
function _ln_assert_refused(make, tables::Dict)
  for run in (() -> _ln_steps(make(), nothing), () -> make().delete())
    e = _ln_caught(run)
    @test e isa PormG.QueryBuildError && occursin("Circular dependency", sprint(showerror, e))
  end
  for (_, conn) in _LN_MOCKS
    @test first(_ln_steps(make(), conn))[:operation] == _ln_key_read(conn)
  end
  for (table, rows) in tables
    @test isequal(_ln_rows(table), rows)
  end
end

try

# ─────────────────────────────────────────────────────────────────────────────
# The reproduction: a second model over the root's table writes it
# ─────────────────────────────────────────────────────────────────────────────

# What: the cascade nulls the root's own column through a second model over the root's table, and the
# root filter reads that column.
# SQL: `SELECT "Tb"."id" FROM "ln_squad" AS "Tb" WHERE "Tb"."favourite_driver" IS NULL`, then
#      `UPDATE "ln_squad" … SET "favourite_driver" = NULL WHERE "Tb"."favourite_driver" IN (SELECT …
#      "ln_squad_driver" … "team" IN (SELECT … WHERE "R2"."id" IN (?)))`, the drivers' DELETE, and
#      `DELETE FROM "ln_squad" AS "Tb" WHERE "Tb"."id" IN (?)` with Tyrrell's key.
# Why: before #1370 the root DELETE re-read `"favourite_driver" IS NULL` after the UPDATE had nulled
#      McLaren's, and returned `(4, ln_squad => 2, ln_squad_driver => 2)`: McLaren and Senna were
#      deleted, with no error. The cycle refusal cannot see this shape, because the UPDATE targets
#      another model. Django deletes Tyrrell and Stewart and only updates McLaren.
@testset "a cascade that writes the root's table through a second model deletes only the rows the filter matched (#1370)" begin
  _ln_reset!()
  q = LN.Ln_squad.objects
  q.filter("favourite_driver__@isnull" => true)
  steps = _ln_steps(q, nothing)
  @test _ln_ops(steps) == [(:select, "ln_squad"), (:update, "ln_squad_view"), (:delete, "ln_squad_driver"), (:delete, "ln_squad")]
  @test steps[1][:sql_text] == "SELECT \"Tb\".\"id\" FROM \"ln_squad\" AS \"Tb\" WHERE \"Tb\".\"favourite_driver\" IS NULL"
  @test last(steps)[:sql_text] == "DELETE FROM \"ln_squad\" AS \"Tb\" WHERE \"Tb\".\"id\" IN (?)"
  for s in steps[2:end]
    @test !occursin("IS NULL", s[:sql_text])                          # nothing re-reads the filter
    @test s[:parameters] == [1]                                       # Tyrrell's key, once per statement
  end

  q = LN.Ln_squad.objects
  q.filter("favourite_driver__@isnull" => true)
  total, counts = q.delete()
  @test total == 2 && counts == Dict("ln_squad" => 1, "ln_squad_driver" => 1)
  @test isequal(_ln_rows("ln_squad"), [(2, "McLaren", missing), (3, "Williams", 30)])
  @test _ln_rows("ln_squad_driver") == [(20, "Senna", 2), (30, "Mansell", 3)]
end

# ─────────────────────────────────────────────────────────────────────────────
# A SET_NULL / SET_DEFAULT statement that targets a model already in the cascade (#1374)
#
# These shapes used to close a cycle in the collector's dependencies, and `topological_sort` refused
# them while planning. A SET_NULL / SET_DEFAULT relation no longer orders the deletes
# (`_orders_deletes`): its UPDATE runs before every DELETE. The key read (#1370) keeps the root's DELETE
# from re-reading the column the UPDATE wrote, so each gives Django's result.
# ─────────────────────────────────────────────────────────────────────────────

# Every engine's mock builds the plan, the key read first. A mock reads no keys, so the plan after it
# is over the empty set: the probes find nothing to update, and the root's DELETE is the last step.
function _ln_assert_builds_on_mocks(make)
  for (label, conn) in _LN_MOCKS
    steps = _ln_steps(make(), conn)
    @test first(steps)[:operation] == _ln_key_read(conn)
    @test last(steps)[:operation] == :delete
  end
end

# What: a self-referential SET_NULL key, with a root filter on the very column the cascade nulls.
# SQL: `SELECT "Tb"."id" FROM "ln_lineage" AS "Tb" WHERE "Tb"."predecessor" IS NULL`, then
#      `UPDATE "ln_lineage" … SET "predecessor" = NULL …` scoped by Tyrrell's key, then
#      `DELETE FROM "ln_lineage" AS "Tb" WHERE "Tb"."id" IN (?)`.
# Why: Django deletes Tyrrell and nulls BAR. Before #1374 this was refused as a cycle on every engine;
#      before #1370 the root DELETE re-read `IS NULL` after the UPDATE and would have taken BAR too.
@testset "a self-referential SET_NULL under a filter on the nulled column deletes the root and nulls its successor (#1374)" begin
  _ln_reset!()
  make() = (q = LN.Ln_lineage.objects; q.filter("predecessor__@isnull" => true); q)
  steps = _ln_steps(make(), nothing)
  @test _ln_ops(steps) == [(:select, "ln_lineage"), (:update, "ln_lineage"), (:delete, "ln_lineage")]
  @test last(steps)[:sql_text] == "DELETE FROM \"ln_lineage\" AS \"Tb\" WHERE \"Tb\".\"id\" IN (?)"
  for s in steps[2:end]
    @test !occursin("IS NULL", s[:sql_text])
    @test s[:parameters] == [1]
  end
  _ln_assert_builds_on_mocks(make)

  @test make().delete() == (1, Dict("ln_lineage" => 1))
  @test isequal(_ln_rows("ln_lineage"), [(2, "BAR", missing), (3, "Honda", 2), (4, "Brawn", 3)])
end

# What: the same with SET_DEFAULT (default 1), and a filter on the default value.
# SQL: the key read `… WHERE "Tb"."predecessor" = ?` with `[1]`, which finds BAR; `UPDATE … SET
#      "predecessor" = 1` over BAR's successors; `DELETE … WHERE "Tb"."id" IN (?)` with BAR's key.
# Why: the UPDATE re-points Honda to the value the filter matches, so a root DELETE that re-read the
#      filter would take Honda along with BAR. Django deletes BAR and re-points Honda to Tyrrell.
@testset "a self-referential SET_DEFAULT under a filter on the default deletes the root and re-points its successor (#1374)" begin
  _ln_reset!()
  make() = (q = LN.Ln_lineage_default.objects; q.filter("predecessor" => 1); q)
  steps = _ln_steps(make(), nothing)
  @test _ln_ops(steps) == [(:select, "ln_lineage_default"), (:update, "ln_lineage_default"), (:delete, "ln_lineage_default")]
  @test last(steps)[:parameters] == [2]
  _ln_assert_builds_on_mocks(make)

  @test make().delete() == (1, Dict("ln_lineage_default" => 1))
  @test isequal(_ln_rows("ln_lineage_default"), [(1, "Tyrrell", missing), (3, "Honda", 1), (4, "Brawn", 3)])
end

# What: the SET_DEFAULT lineage, deleting the default row itself (Tyrrell, 1) while BAR points at it.
# SQL: the key read, `UPDATE … SET "predecessor" = 1` over Tyrrell's successors, `DELETE … IN (?)`;
#      SQLite checks the key at COMMIT, which fails, and the transaction rolls back.
# Why: the UPDATE re-points BAR at the row being deleted, so no plan can succeed; Django raises
#      IntegrityError here too. Before #1374 this was a QueryBuildError cycle refusal, so the type
#      changed (the upgrade entry says so).
@testset "a self-referential SET_DEFAULT delete of the default row itself raises IntegrityError, nothing written (#1374)" begin
  _ln_reset!()
  e = _ln_caught(() -> (q = LN.Ln_lineage_default.objects; q.filter("id" => 1); q.delete()))
  @test e isa PormG.IntegrityError
  @test isequal(_ln_rows("ln_lineage_default"), _LN_LINEAGE_ROWS)
end

# What: a cycle through a child: deleting a team CASCADEs to its drivers, and a team whose favourite
# driver is one of them is nulled (SET_NULL on the root's own model).
# SQL: the key read, `UPDATE "ln_team" … SET "favourite_driver" = NULL` over the favourites among
#      Tyrrell's drivers, `DELETE FROM "ln_driver" …`, then `DELETE FROM "ln_team" … IN (?)`.
# Why: the order a cycle used to hide. Only the CASCADE relation orders the deletes, so the drivers go
#      before their team, and MySQL's check at each statement holds. Measured with the refusal switched
#      off before the key read: `(4, ln_team => 2, ln_driver => 2)`; Django deletes Tyrrell and Stewart
#      and nulls McLaren's favourite.
@testset "a cycle through a child that nulls the root's own column deletes the drivers, then the team (#1374)" begin
  _ln_reset!()
  make() = (q = LN.Ln_team.objects; q.filter("favourite_driver__@isnull" => true); q)
  steps = _ln_steps(make(), nothing)
  @test _ln_ops(steps) == [(:select, "ln_team"), (:update, "ln_team"), (:delete, "ln_driver"), (:delete, "ln_team")]
  for s in steps[2:end]
    @test !occursin("IS NULL", s[:sql_text])
  end
  _ln_assert_builds_on_mocks(make)

  total, counts = make().delete()
  @test total == 2 && counts == Dict("ln_team" => 1, "ln_driver" => 1)
  @test isequal(_ln_rows("ln_team"), [(2, "McLaren", missing), (3, "Williams", 30)])
  @test _ln_rows("ln_driver") == [(20, "Senna", 2), (30, "Mansell", 3)]
end

# What: a self-referential CASCADE under a filter on the root's own name.
# SQL: none on the live pool; the same refusal.
# Why: the control for the shapes above. A CASCADE relation orders the deletes, so a self-referential
#      one with dependent rows is still a cycle (`docs/src/backends.md`).
@testset "a self-referential CASCADE with dependent rows is refused (#1370)" begin
  _ln_reset!()
  _ln_assert_refused(Dict("ln_lineage_cascade" => _LN_LINEAGE_ROWS)) do
    q = LN.Ln_lineage_cascade.objects
    q.filter("name" => "Honda")
    q
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# Controls: the same schemas over rows that do not cycle
# ─────────────────────────────────────────────────────────────────────────────

# What: the cycle schema, with no team favouring a driver the cascade deletes, so the SET_NULL path is
# probed empty and pruned.
# SQL: `SELECT "Tb"."id" FROM "ln_team" AS "Tb" WHERE "Tb"."favourite_driver" IS NULL`, the drivers'
#      DELETE scoped by Tyrrell's key, then `DELETE FROM "ln_team" AS "Tb" WHERE "Tb"."id" IN (?)`.
# Why: the refusal is decided by the rows. A schema that could cycle, over rows that do not, deletes
#      exactly what its filter matched; the key read is the one statement #1370 adds.
@testset "the cycle schema over rows that do not cycle reads the keys, then deletes what they name (#1370)" begin
  _ln_reset!()
  fetch(_LN_POOL, "UPDATE ln_team SET favourite_driver = 20 WHERE id = 2;")   # McLaren favours Senna
  q = LN.Ln_team.objects
  q.filter("favourite_driver__@isnull" => true)
  steps = _ln_steps(q, nothing)
  @test _ln_ops(steps) == [(:select, "ln_team"), (:delete, "ln_driver"), (:delete, "ln_team")]
  @test last(steps)[:sql_text] == "DELETE FROM \"ln_team\" AS \"Tb\" WHERE \"Tb\".\"id\" IN (?)"
  @test last(steps)[:parameters] == [1]

  q = LN.Ln_team.objects
  q.filter("favourite_driver__@isnull" => true)
  total, counts = q.delete()
  @test total == 2 && counts == Dict("ln_team" => 1, "ln_driver" => 1)
  @test isequal(_ln_rows("ln_team"), [(2, "McLaren", 20), (3, "Williams", 30)])
  @test _ln_rows("ln_driver") == [(20, "Senna", 2), (30, "Mansell", 3)]
end

# What: an own-column filter whose cascade writes another table only: McLaren and its driver.
# SQL: SQLite `SELECT "Tb"."id" FROM "ln_team" AS "Tb" WHERE "Tb"."name" = ?`, the drivers' DELETE,
#      then `DELETE FROM "ln_team" AS "Tb" WHERE "Tb"."id" IN (?)`; PostgreSQL and MySQL read the keys
#      `FOR UPDATE`, in place of the team's own lock (#770).
# Why: the key read takes every filtered root with something to cascade (#1370), not only one whose
#      filter reads another table (#1342), because the filter's text cannot tell the shapes apart.
@testset "an own-column filter with something to cascade reads the root's keys first (#1370)" begin
  _ln_reset!()
  for (label, conn) in _LN_MOCKS
    @testset "$(label)" begin
      q = LN.Ln_team.objects
      q.filter("name" => "McLaren")
      steps = _ln_steps(q, conn)
      @test first(steps)[:operation] == _ln_key_read(conn)
      @test first(steps)[:parameters] == ["McLaren"]
      @test endswith(first(steps)[:sql_text], " FOR UPDATE") == !(conn isa PormG.PormGSQLite)
      @test last(_ln_ops(steps)) == (:delete, "ln_team")
      @test !occursin("name", last(steps)[:sql_text])
    end
  end
  q = LN.Ln_team.objects
  q.filter("name" => "McLaren")
  steps = _ln_steps(q, nothing)
  @test _ln_ops(steps) == [(:select, "ln_team"), (:delete, "ln_driver"), (:delete, "ln_team")]
  @test steps[1][:sql_text] == "SELECT \"Tb\".\"id\" FROM \"ln_team\" AS \"Tb\" WHERE \"Tb\".\"name\" = ?"
  @test last(steps)[:parameters] == [2]

  q = LN.Ln_team.objects
  q.filter("name" => "McLaren")
  total, counts = q.delete()
  @test total == 2 && counts == Dict("ln_team" => 1, "ln_driver" => 1)
  @test isequal(_ln_rows("ln_team"), [(1, "Tyrrell", missing), (3, "Williams", 30)])
  @test _ln_rows("ln_driver") == [(10, "Stewart", 1), (30, "Mansell", 3)]
end

# What: the last team of a self-referential SET_NULL lineage, which no team names as its predecessor.
# SQL: `SELECT "Tb"."id" FROM "ln_lineage" AS "Tb" WHERE "Tb"."name" = ?`, then
#      `DELETE FROM "ln_lineage" AS "Tb" WHERE "Tb"."id" IN (?)`.
# Why: the root has a reverse relation that writes, so its keys are read, though the probe then finds
#      no successor to update: the key read is decided before the cascade is probed.
@testset "a self-referential row with no successor is deleted by its keys (#1370)" begin
  _ln_reset!()
  q = LN.Ln_lineage.objects
  q.filter("name" => "Brawn")
  @test _ln_ops(_ln_steps(q, nothing)) == [(:select, "ln_lineage"), (:delete, "ln_lineage")]

  q = LN.Ln_lineage.objects
  q.filter("name" => "Brawn")
  @test q.delete() == (1, Dict("ln_lineage" => 1))
  @test isequal(_ln_rows("ln_lineage"), _LN_LINEAGE_ROWS[1:3])
end

# What: an unfiltered delete (`allow_delete_all`) of a root with something to cascade.
# SQL: no key read; the cascade's statements, then `DELETE FROM "ln_squad" AS "Tb"` with no WHERE.
# Why: an unfiltered DELETE takes every row, whatever the cascade wrote, so there is nothing to
#      resolve, and reading every key of the table would cost a round trip for nothing.
@testset "an unfiltered delete takes no key read (#1370)" begin
  for (label, conn) in _LN_MOCKS
    res = LN.Ln_squad.objects.delete(show_query = :dict, connection = conn, allow_delete_all = true)
    steps = res isa Vector ? res : [res]
    # A key read projects the key (`SELECT "Tb"."id" …`); the #770 parent lock on PostgreSQL and
    # MySQL is a `SELECT count(*) …` and stays.
    @test !any(s -> occursin(r"^SELECT [\"`]Tb[\"`]\.", s[:sql_text]), steps)
    @test last(steps)[:sql_text] == (conn isa PormG.PormGMySQL ? "DELETE FROM `ln_squad` AS `Tb`" : "DELETE FROM \"ln_squad\" AS \"Tb\"")
  end
end

finally
  delete!(PormG.config, "ln1370_sqlite")
  # Release the SQLite handle so the temp dir can be removed on Windows (WAL keeps it open).
  PormG.ConnectionPool.close_pool!(_LN_POOL)
end
