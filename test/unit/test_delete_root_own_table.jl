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
    them right, and each now gives Django's result. A self-referential CASCADE is walked by keys and
    deleted deepest level first (#1377);
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
# The cascade lineage's drivers, with no constraint (`db_constraint = false`): only PormG's statements
# delete them, so a driver left behind shows a DELETE whose scope read rows already gone (#1377).
Ln_lineage_driver = Models.Model("ln_lineage_driver",
  id      = Models.IDField(),
  surname = Models.CharField(),
  team    = Models.ForeignKey(Ln_lineage_cascade, on_delete = "CASCADE", related_name = "drivers", db_constraint = false),
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
Models.@models Ln_lineage Ln_lineage_default Ln_lineage_cascade Ln_lineage_driver Ln_team Ln_driver Ln_squad Ln_squad_view Ln_squad_driver
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
  for t in (_LN_LINEAGES..., "ln_lineage_driver", "ln_driver", "ln_team", "ln_squad_driver", "ln_squad")
    fetch(_LN_POOL, "DROP TABLE IF EXISTS $(t);")
  end
  # Tyrrell <- BAR <- Honda <- Brawn in every lineage table. No ON DELETE clause on the SET_NULL /
  # SET_DEFAULT ones: only PormG's statements act on the rows. The CASCADE lineage's key carries
  # `ON DELETE CASCADE`, as PormG's migrations write it (#1377): a DELETE of a row that still has
  # children then makes the database delete them too, which the walk's order must never let happen.
  for t in _LN_LINEAGES
    on_delete = t == "ln_lineage_cascade" ? " ON DELETE CASCADE" : ""
    fetch(_LN_POOL, "CREATE TABLE $(t) (id INTEGER PRIMARY KEY, name TEXT NOT NULL, predecessor INTEGER REFERENCES $(t) (id)$(on_delete));")
    fetch(_LN_POOL, "INSERT INTO $(t) (id, name, predecessor) VALUES (1, 'Tyrrell', NULL), (2, 'BAR', 1), (3, 'Honda', 2), (4, 'Brawn', 3);")
  end
  # Stewart races for Tyrrell, Barrichello for Honda, Button for Brawn.
  fetch(_LN_POOL, "CREATE TABLE ln_lineage_driver (id INTEGER PRIMARY KEY, surname TEXT NOT NULL, team INTEGER NOT NULL);")
  fetch(_LN_POOL, "INSERT INTO ln_lineage_driver (id, surname, team) VALUES (10, 'Stewart', 1), (30, 'Barrichello', 3), (40, 'Button', 4);")
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

# ─────────────────────────────────────────────────────────────────────────────
# A self-referential CASCADE: walked by keys, deepest level first (#1377)
#
# A CASCADE relation orders the deletes, so a self-referential one used to be a cycle and was refused.
# The delete's own model is now walked by keys: one read per level below the root's keys, each child
# with its parent, every key on its deepest level, then one plan per level, deepest first. The tree's
# key carries `ON DELETE CASCADE`, as PormG's migrations write it, and its drivers no constraint, so a
# DELETE that ran while a row still had children would show as a short count or a driver left behind.
# ─────────────────────────────────────────────────────────────────────────────

_ln_cascade(name) = (q = LN.Ln_lineage_cascade.objects; q.filter("name" => name); q)
_ln_cascade_ids() = [r[1] for r in _ln_rows("ln_lineage_cascade")]
_ln_driver_ids() = [r[1] for r in _ln_rows("ln_lineage_driver")]
_ln_tree_deletes(q) = [s[:parameters] for s in _ln_steps(q, nothing) if s[:operation] == :delete && s[:model] == "ln_lineage_cascade"]

# What: an inner node, Honda, whose successor is Brawn; each has a driver.
# SQL: the key read `… WHERE "Tb"."name" = ?`, the level reads `SELECT "Tb"."id", "Tb"."predecessor"
#      FROM "ln_lineage_cascade" AS "Tb" WHERE "Tb"."predecessor" IN (?)` with Honda's key, then
#      Brawn's (which finds none), then Brawn's driver and Brawn, then Honda's driver and Honda.
# Why: Django deletes Honda, Brawn and both drivers. The deepest row goes first, so the database's own
#      ON DELETE CASCADE never fires and no engine needs a deferred key.
@testset "a self-referential CASCADE deletes an inner node, its descendants and their drivers, deepest first (#1377)" begin
  _ln_reset!()
  steps = _ln_steps(_ln_cascade("Honda"), nothing)
  @test _ln_ops(steps) == [(:select, "ln_lineage_cascade"), (:select, "ln_lineage_cascade"), (:select, "ln_lineage_cascade"),
                           (:delete, "ln_lineage_driver"), (:delete, "ln_lineage_cascade"),
                           (:delete, "ln_lineage_driver"), (:delete, "ln_lineage_cascade")]
  @test steps[2][:sql_text] ==
        "SELECT \"Tb\".\"id\", \"Tb\".\"predecessor\" FROM \"ln_lineage_cascade\" AS \"Tb\" WHERE \"Tb\".\"predecessor\" IN (?)"
  @test [s[:parameters] for s in steps[2:3]] == [[3], [4]]
  @test [s[:parameters] for s in steps if s[:operation] == :delete && s[:model] == "ln_lineage_cascade"] == [[4], [3]]
  for s in steps
    @test count("?", s[:sql_text]) == length(s[:parameters])
  end

  @test _ln_cascade("Honda").delete() == (4, Dict("ln_lineage_cascade" => 2, "ln_lineage_driver" => 2))
  @test _ln_cascade_ids() == [1, 2]
  @test _ln_driver_ids() == [10]
end

# What: the root of the tree, a leaf, and a filter that matches a node and one of its descendants.
# SQL: Tyrrell: three levels read, the tree deleted Brawn, Honda, BAR, Tyrrell. Brawn: one level read
#      that finds none. Tyrrell and Honda together: Honda is found again below BAR and moves down to its
#      own level, so the order is the same as for Tyrrell alone.
# Why: every level is collected and the counts add up across them. A matched row that descends from
#      another matched row is deleted at its depth, not with its ancestor: deleted with Tyrrell, the
#      database would cascade it away first and the count and the drivers would be wrong.
@testset "a self-referential CASCADE deletes a whole tree, a leaf, and nested matches at their own depth (#1377)" begin
  _ln_reset!()
  @test _ln_tree_deletes(_ln_cascade("Tyrrell")) == [[4], [3], [2], [1]]
  @test _ln_cascade("Tyrrell").delete() == (7, Dict("ln_lineage_cascade" => 4, "ln_lineage_driver" => 3))
  @test isempty(_ln_cascade_ids()) && isempty(_ln_driver_ids())

  _ln_reset!()
  @test _ln_cascade("Brawn").delete() == (2, Dict("ln_lineage_cascade" => 1, "ln_lineage_driver" => 1))
  @test _ln_cascade_ids() == [1, 2, 3]

  _ln_reset!()
  nested() = (q = LN.Ln_lineage_cascade.objects; q.filter("name__@in" => ["Tyrrell", "Honda"]); q)
  @test _ln_tree_deletes(nested()) == [[4], [3], [2], [1]]
  @test nested().delete() == (7, Dict("ln_lineage_cascade" => 4, "ln_lineage_driver" => 3))
  @test isempty(_ln_cascade_ids()) && isempty(_ln_driver_ids())
end

# What: rows in a loop: Tyrrell's predecessor set to Brawn, so the four teams reference each other.
# SQL: the level reads find Brawn, Tyrrell, BAR, and then Honda again below BAR: a loop. SQLite checks
#      the key at COMMIT, so after the drivers the four teams go in one `DELETE … IN (?, ?, ?, ?)`.
# Why: no order of statements satisfies a loop under a per-statement check, and with ON DELETE
#      CASCADE a loop split over several statements would be cascaded away by the first one. Where the
#      key is checked at COMMIT the delete runs, as in Django; on MySQL it is refused before any write,
#      naming `deferred_foreign_keys` (the refusal itself is checked here, since a mock reads no keys).
@testset "rows in a self-referential loop are deleted in one statement where the key is checked at COMMIT (#1377)" begin
  _ln_reset!()
  fetch(_LN_POOL, "UPDATE ln_lineage_cascade SET predecessor = 4 WHERE id = 1;")
  @test _ln_tree_deletes(_ln_cascade("Honda")) == [[1, 2, 3, 4]]
  @test _ln_cascade("Honda").delete() == (7, Dict("ln_lineage_cascade" => 4, "ln_lineage_driver" => 3))
  @test isempty(_ln_cascade_ids()) && isempty(_ln_driver_ids())

  e = PormG.QueryBuilder._self_loop_refusal(LnMockMySQL(), LN.Ln_lineage_cascade, "predecessor", [3, 1, 2, 4, 5, 6])
  @test e isa PormG.BackendCapabilityError
  msg = sprint(showerror, e)
  @test occursin("foreign keys checked at COMMIT", msg) && occursin("MySQL does not support", msg)
  @test occursin("keys 3, 1, 2, 4, 5, … 6 in all", msg)
  @test occursin("update(\"predecessor\" => nothing)", msg)
  @test !PormG.Kernel._supports(LnMockMySQL(), :deferred_foreign_keys)
  @test PormG.Kernel._supports(LnMockSQLite(), :deferred_foreign_keys) && PormG.Kernel._supports(LnMockPostgres(), :deferred_foreign_keys)
end

# Replace the cascade lineage with `(id, predecessor)` rows, each with one driver (id × 10). The keys are
# set after every row exists, so the rows may reference each other in loops.
function _ln_load_tree!(rows::Vector{Tuple{Int,Int}})
  fetch(_LN_POOL, "DELETE FROM ln_lineage_driver;")
  fetch(_LN_POOL, "UPDATE ln_lineage_cascade SET predecessor = NULL;")
  fetch(_LN_POOL, "DELETE FROM ln_lineage_cascade;")
  fetch(_LN_POOL, "INSERT INTO ln_lineage_cascade (id, name, predecessor) VALUES " *
    join(("($(id), 'Team $(id)', NULL)" for (id, _) in rows), ", ") * ";")
  for (id, predecessor) in rows
    predecessor == 0 || fetch(_LN_POOL, "UPDATE ln_lineage_cascade SET predecessor = $(predecessor) WHERE id = $(id);")
  end
  fetch(_LN_POOL, "INSERT INTO ln_lineage_driver (id, surname, team) VALUES " *
    join(("($(10id), 'Driver $(id)', $(id))" for (id, _) in rows), ", ") * ";")
  return nothing
end
_ln_ids_in(names...) = (q = LN.Ln_lineage_cascade.objects; q.filter("name__@in" => collect(names)); q)

# What: a loop with tails: Team 1 and Team 2 name each other; Team 3 succeeds 1, Team 4 succeeds 3,
#       Team 5 succeeds 2. Deleted from the loop, from two roots both on the loop, from a tail, and two
#       separate loops at once.
# SQL: the tails' levels first, deepest first, then the loop's rows in one DELETE; a tail alone never
#      reaches the loop.
# Why: the order the rows come back in decides how the levels split, but every split must delete each
#      row after its children, count every row, and leave no driver behind (the drivers have no key).
@testset "self-referential loops with tails, roots on the loop, and two loops at once (#1377)" begin
  loop_with_tails = [(1, 2), (2, 1), (3, 1), (4, 3), (5, 2)]
  for (label, q, tree, kept) in (("from the loop", () -> _ln_ids_in("Team 1"), 5, Int[]),
                                 ("all roots on the loop", () -> _ln_ids_in("Team 1", "Team 2"), 5, Int[]),
                                 ("a nested root and the loop", () -> _ln_ids_in("Team 1", "Team 4"), 5, Int[]),
                                 ("from a tail", () -> _ln_ids_in("Team 3"), 2, [1, 2, 5]))
    @testset "$(label)" begin
      _ln_reset!()
      _ln_load_tree!(loop_with_tails)
      @test q().delete() == (2tree, Dict("ln_lineage_cascade" => tree, "ln_lineage_driver" => tree))
      @test _ln_cascade_ids() == kept
      @test _ln_driver_ids() == 10 .* kept
    end
  end

  _ln_reset!()
  _ln_load_tree!([(1, 2), (2, 1), (5, 6), (6, 5), (7, 5), (8, 0)])
  @test _ln_ids_in("Team 1", "Team 5").delete() == (10, Dict("ln_lineage_cascade" => 5, "ln_lineage_driver" => 5))
  @test _ln_cascade_ids() == [8]
end

# What: a loop of 52 rows, and one of 51.
# SQL: a cycle of n rows reaches n - 1 levels below its root. The 52-row loop's 51st read finds a row
#      and is refused before any write; the 51-row loop closes at its 51st read and goes in one DELETE.
# Why: a loop can only go in one DELETE (split over two, the first one's ON DELETE CASCADE would remove
#      the second one's rows before their statements ran). The depth cap is what keeps every loop
#      within one key chunk on every engine: at most 51 rows.
@testset "a self-referential loop deeper than MAX_CASCADE_DEPTH is refused; one at the cap is deleted (#1377)" begin
  _ln_reset!()
  _ln_load_tree!([(i, i == 52 ? 1 : i + 1) for i in 1:52])
  e = _ln_caught(() -> _ln_ids_in("Team 1").delete())
  @test e isa PormG.QueryBuildError && occursin("more than 50 levels", sprint(showerror, e))
  @test length(_ln_cascade_ids()) == 52 && length(_ln_driver_ids()) == 52

  _ln_reset!()
  _ln_load_tree!([(i, i == 51 ? 1 : i + 1) for i in 1:51])
  @test _ln_tree_deletes(_ln_ids_in("Team 1")) == [collect(1:51)]
  @test _ln_ids_in("Team 1").delete() == (102, Dict("ln_lineage_cascade" => 51, "ln_lineage_driver" => 51))
end

# What: a level wider than one SQLite bind chunk (2047 keys): 2100 more teams succeed Tyrrell.
# SQL: the level's children are read in two chunks, and the level is deleted by two plans.
# Why: the walk's reads and the level plans chunk like the root's keys, and the counts add up.
@testset "a self-referential CASCADE level wider than one bind chunk is read and deleted in chunks (#1377)" begin
  _ln_reset!()
  values_sql = join(("($(i), 'Privateer $(i)', 1)" for i in 1001:3100), ", ")
  fetch(_LN_POOL, "INSERT INTO ln_lineage_cascade (id, name, predecessor) VALUES $(values_sql);")
  steps = _ln_steps(_ln_cascade("Tyrrell"), nothing)
  @test count(s -> s[:operation] == :select && occursin("\"predecessor\" IN", s[:sql_text]), steps) == 5
  @test _ln_cascade("Tyrrell").delete() == (2107, Dict("ln_lineage_cascade" => 2104, "ln_lineage_driver" => 3))
  @test isempty(_ln_cascade_ids())
end

# What: a chain exactly 50 levels below its root, and one 51 levels below.
# SQL: 51 level reads (the last finds none) and 51 DELETEs; the deeper chain is refused when its 51st
#      level read finds a row, before any write.
# Why: `MAX_CASCADE_DEPTH` bounds the levels below the deleted rows, inclusive: 50 levels are allowed.
@testset "a self-referential CASCADE stops at MAX_CASCADE_DEPTH levels, inclusive (#1377)" begin
  for (below, allowed) in ((50, true), (51, false))
    _ln_reset!()
    rows = join(("($(100 + i), 'Chain $(i)', $(i == 0 ? "NULL" : string(99 + i)))" for i in 0:below), ", ")
    fetch(_LN_POOL, "INSERT INTO ln_lineage_cascade (id, name, predecessor) VALUES $(rows);")
    if allowed
      @test _ln_cascade("Chain 0").delete() == (below + 1, Dict("ln_lineage_cascade" => below + 1))
    else
      e = _ln_caught(() -> _ln_cascade("Chain 0").delete())
      @test e isa PormG.QueryBuildError && occursin("more than 50 levels", sprint(showerror, e))
      @test length(_ln_cascade_ids()) == 4 + below + 1
    end
  end
end

# What: the same delete on each engine's mock, an unfiltered delete of the tree, and a self-referential
#       DO_NOTHING.
# SQL: on a mock the key read reads no keys, so no level is read and the plan is the root's alone.
#      `allow_delete_all` takes no key read, so there is no walk, and the collector refuses the cycle.
# Why: inspection on a mock shows the first statements only; the unfiltered shape stays refused, and
#      the refusal names the model, the cycle and the way out, with the tree hint only for a CASCADE.
@testset "a self-referential CASCADE on a mock, and unfiltered, which stays refused (#1377)" begin
  _ln_reset!()
  for (_, conn) in _LN_MOCKS
    steps = _ln_steps(_ln_cascade("Honda"), conn)
    @test first(steps)[:operation] == _ln_key_read(conn)
    @test last(steps)[:operation] == :delete
  end
  e = _ln_caught(() -> LN.Ln_lineage_cascade.objects.delete(allow_delete_all = true))
  @test e isa PormG.QueryBuildError
  msg = replace(sprint(showerror, e), r"\e\[[0-9;]*m" => "")
  @test occursin("Circular dependency", msg)
  @test occursin("ln_lineage_cascade -> ln_lineage_cascade", msg)
  @test occursin("allow_delete_all", msg)
  @test _ln_cascade_ids() == [1, 2, 3, 4]
  # The level-by-level hint is for a CASCADE key to itself only.
  plain = PormG.QueryBuilder._delete_cycle_message(PormG.PormGModel[LN.Ln_team, LN.Ln_team])
  @test !occursin("level by level", plain)
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
