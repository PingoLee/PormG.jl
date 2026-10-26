"""
Unit coverage for #1342: a `delete()` whose root filter reads another table resolves the root's
primary keys first, and scopes every statement of the cascade by them.

The collector deletes children first and the root last, and every statement used to re-read the root
filter: a child through `"<fk>__@in" => <root query>`, the root through its own predicate. A filter
that reads the rows the cascade writes — `filter("results__grid" => 1)` — therefore matched nothing by
the time the root's own DELETE ran: the results were gone and the race stayed, with no error. Now:

  1. `SELECT "Tb"."<pk>" FROM <root> AS "Tb" WHERE <filter>` (`FOR UPDATE` on PostgreSQL and MySQL),
     before any write — a `:select` step on SQLite, the root's `:lock` step elsewhere;
  2. every statement after it scoped by `"<pk>__@in" => keys`, nothing re-reading the filter;
  3. on SQLite and MySQL, which bind a list one value at a time, one plan per chunk of keys.

A filter on the root's own columns, and a root with nothing to cascade to, keep the SQL they had.

The shapes use mock pools; the rows are executed on a temp SQLite file, where the defect reproduces
(it is not PostgreSQL-specific: the order of the statements is the same on every engine). The
PostgreSQL lock shape is pinned in test_mutation_fence_shape.jl.
"""
# julia --project=test/integration -e 'include("test/load_drivers.jl"); include("test/unit/test_delete_root_keys.jl")'

using Test
using DataFrames
using PormG
using PormG.Models
import PormG.ConnectionPool: fetch, SQLiteConnectionPool

const QB = PormG.QueryBuilder

struct RkMockSQLite <: PormG.PormGSQLite end
struct RkMockOldSQLite <: PormG.PormGSQLite end
struct RkMockPostgres <: PormG.PormGPostgres end
struct RkMockMySQL <: PormG.PormGMySQL end
PormG.backend_sqlite_version(::RkMockSQLite) = 3045000
PormG.backend_sqlite_version(::RkMockOldSQLite) = 3031000
PormG.backend_mysql_parameter_limit(::RkMockMySQL) = 4096

const _RK_DIR  = mktempdir()
const _RK_POOL = SQLiteConnectionPool(joinpath(_RK_DIR, "rk1342.sqlite"); pool_size = 1)
PormG.config["rk1342_sqlite"] = PormG.Configuration.Settings(
  connections = _RK_POOL, db_def_folder = "rk1342_sqlite", change_data = true)

# The F1 shape in miniature: a race has results (CASCADE) and laps (CASCADE, the sibling path); a
# result has notes (SET_NULL). A circuit has races through a DO_NOTHING key, so a filter on it that
# reads races has nothing to cascade to.
module RkModels
import PormG
import PormG.Models
Rk_circuit = Models.Model("rk_circuit", id = Models.IDField(), name = Models.CharField())
Rk_race = Models.Model("rk_race",
  id      = Models.IDField(),
  name    = Models.CharField(),
  circuit = Models.ForeignKey(Rk_circuit, on_delete = "DO_NOTHING", related_name = "races", null = true),
)
Rk_result = Models.Model("rk_result",
  id   = Models.IDField(),
  race = Models.ForeignKey(Rk_race, on_delete = "CASCADE", related_name = "results"),
  grid = Models.IntegerField(),
)
Rk_lap = Models.Model("rk_lap",
  id   = Models.IDField(),
  race = Models.ForeignKey(Rk_race, on_delete = "CASCADE", related_name = "laps"),
)
# PROTECT: a flag on a race refuses its delete. No row has one unless a test adds it.
Rk_flag = Models.Model("rk_flag",
  id   = Models.IDField(),
  race = Models.ForeignKey(Rk_race, on_delete = "PROTECT", related_name = "flags"),
)
Rk_note = Models.Model("rk_note",
  id     = Models.IDField(),
  body   = Models.CharField(),
  result = Models.ForeignKey(Rk_result, on_delete = "SET_NULL", related_name = "notes", null = true),
)
PormG.Models.set_models(@__MODULE__, "rk1342_sqlite")
end

const RK = RkModels
_rk_quiet(f) = Base.CoreLogging.with_logger(f, Base.CoreLogging.SimpleLogger(IOBuffer(), Base.CoreLogging.Error))
_rk_steps(q, conn) = (res = q.delete(show_query = :dict, connection = conn); res isa Vector ? res : [res])
_rk_ops(steps) = [(s[:operation], s[:model]) for s in steps]
_rk_ids(table) = sort((fetch(_RK_POOL, "SELECT id FROM $(table);") |> DataFrame).id)

function _rk_reset!()
  for t in ("rk_flag", "rk_note", "rk_lap", "rk_result", "rk_race", "rk_circuit")
    fetch(_RK_POOL, "DROP TABLE IF EXISTS $(t);")
  end
  fetch(_RK_POOL, "CREATE TABLE rk_circuit (id INTEGER PRIMARY KEY, name TEXT NOT NULL);")
  fetch(_RK_POOL, "CREATE TABLE rk_race (id INTEGER PRIMARY KEY, name TEXT NOT NULL, circuit INTEGER REFERENCES rk_circuit (id));")
  fetch(_RK_POOL, "CREATE TABLE rk_result (id INTEGER PRIMARY KEY, race INTEGER NOT NULL REFERENCES rk_race (id), grid INTEGER NOT NULL);")
  fetch(_RK_POOL, "CREATE TABLE rk_lap (id INTEGER PRIMARY KEY, race INTEGER NOT NULL REFERENCES rk_race (id));")
  fetch(_RK_POOL, "CREATE TABLE rk_flag (id INTEGER PRIMARY KEY, race INTEGER NOT NULL REFERENCES rk_race (id));")
  fetch(_RK_POOL, "CREATE TABLE rk_note (id INTEGER PRIMARY KEY, body TEXT NOT NULL, result INTEGER REFERENCES rk_result (id));")
  # Race 1 has a pole result (grid 1), another result, a lap and a note on the pole result. Race 2 has
  # no pole result, so no filter below matches it. Race 3 has no result at all, only a lap.
  fetch(_RK_POOL, "INSERT INTO rk_race (id, name) VALUES (1, 'Monaco'), (2, 'Monza'), (3, 'Spa');")
  fetch(_RK_POOL, "INSERT INTO rk_result (id, race, grid) VALUES (10, 1, 1), (11, 1, 5), (20, 2, 5);")
  fetch(_RK_POOL, "INSERT INTO rk_lap (id, race) VALUES (100, 1), (300, 3);")
  fetch(_RK_POOL, "INSERT INTO rk_note (id, body, result) VALUES (1000, 'pole', 10), (2000, 'other', 20);")
  return nothing
end

# Race 1 and everything under it gone, the note re-pointed to NULL; race 2 and race 3 untouched.
function _rk_assert_race_1_deleted(total, counts)
  @test counts == Dict("rk_race" => 1, "rk_result" => 2, "rk_lap" => 1)
  @test total == 4
  @test _rk_ids("rk_race") == [2, 3]
  @test _rk_ids("rk_result") == [20]
  @test _rk_ids("rk_lap") == [300]
  notes = fetch(_RK_POOL, "SELECT id, result FROM rk_note ORDER BY id;") |> DataFrame
  @test notes.id == [1000, 2000]
  @test isequal(notes.result, [missing, 20])
end

try

# ─────────────────────────────────────────────────────────────────────────────
# The issue's repro, executed: the root filter reads the children the cascade deletes
# Before #1342 this returned `(3, Dict("rk_result" => 2, "rk_lap" => 1, "rk_race" => 0))`: the
# results and laps went, then race 1's own DELETE re-read `results.grid = 1`, found no result, and
# kept the race. The discriminating assertion is `rk_race => 1` and race 1 being gone.
# ─────────────────────────────────────────────────────────────────────────────
@testset "a root filter across a reverse relation deletes the root it matched (#1342)" begin
  _rk_reset!()
  q = RK.Rk_race.objects
  q.filter("results__grid" => 1)
  _rk_assert_race_1_deleted(q.delete()...)
end

# The same defect through every other way a filter reads a child table: a correlated `Exists`, and a
# list subquery (`"id__@in" => <query over rk_result>`). Both rendered a SELECT over `rk_result`
# that every statement re-ran after the results were deleted.
@testset "an Exists or subquery root filter over a child deletes the root it matched (#1342)" begin
  _rk_reset!()
  q = RK.Rk_race.objects
  q.filter(Exists(RK.Rk_result.objects.filter("race" => OuterRef("id"), "grid" => 1)))
  _rk_assert_race_1_deleted(q.delete()...)

  _rk_reset!()
  q = RK.Rk_race.objects
  q.filter("id__@in" => RK.Rk_result.objects.filter("grid" => 1).values("race"))
  _rk_assert_race_1_deleted(q.delete()...)
end

# An OR of an own-column arm and an arm that reads a child: before #1342 only the own-column race
# (3, 'Spa') survived the re-read and was deleted — race 1 lost its result and lap and stayed. The
# key read takes both races at once.
@testset "an OR across own columns and a child deletes every root either arm matched (#1342)" begin
  _rk_reset!()
  # Spa gets a result of its own: the OR's join to rk_result is an INNER join (the foreign key is
  # NOT NULL), so a race with no result could not match either arm.
  fetch(_RK_POOL, "INSERT INTO rk_result (id, race, grid) VALUES (30, 3, 7);")
  q = RK.Rk_race.objects
  q.filter(Qor("name" => "Spa", "results__grid" => 1))
  total, counts = q.delete()
  @test counts == Dict("rk_race" => 2, "rk_result" => 3, "rk_lap" => 2)
  @test _rk_ids("rk_race") == [2]
  @test _rk_ids("rk_result") == [20]
  @test _rk_ids("rk_lap") == Int[]
end

# ─────────────────────────────────────────────────────────────────────────────
# The statements: one key read, then nothing re-reads the filter
# Inspection against a LIVE pool reads the keys, as the cascade's existence probes already do there,
# so the statements show the keys that would run: `"Tb"."race" IN (SELECT … WHERE "R1"."id" IN (?))`
# with the key bound, never `rk_result`'s `grid` again.
# ─────────────────────────────────────────────────────────────────────────────
@testset "inspection on a live pool shows the key read, then statements scoped by the keys (#1342)" begin
  _rk_reset!()
  q = RK.Rk_race.objects
  q.filter("results__grid" => 1)
  steps = _rk_steps(q, nothing)
  key = steps[1]
  @test key[:operation] == :select && key[:model] == "rk_race"
  @test startswith(key[:sql_text], "SELECT \"Tb\".\"id\" FROM \"rk_race\" AS \"Tb\" WHERE \"Tb\".\"id\" IN (SELECT DISTINCT \"Tb\".\"id\"")
  @test !occursin("FOR UPDATE", key[:sql_text])                     # SQLite takes no row lock
  @test key[:parameters] == [1, 1]                                  # the IN's grid, then the fence's
  @test Set(_rk_ops(steps[2:end])) == Set([(:update, "rk_note"), (:delete, "rk_result"), (:delete, "rk_lap"), (:delete, "rk_race")])
  @test last(_rk_ops(steps)) == (:delete, "rk_race")
  @test last(steps)[:sql_text] == "DELETE FROM \"rk_race\" AS \"Tb\" WHERE \"Tb\".\"id\" IN (?)"
  for s in steps[2:end]
    @test !occursin("grid", s[:sql_text])
    @test s[:parameters] == [1]                                       # race 1's key, once per statement
  end
  @test _rk_ids("rk_race") == [1, 2, 3]                               # inspection wrote nothing
end

# Inspection on a mock pool cannot read keys, so the statements render over the empty set — on SQLite
# `(1 = 0)` — with the same step sequence that runs. PostgreSQL binds the list as one array marker.
@testset "inspection on a mock pool renders the key read and statements over an empty key set (#1342)" begin
  q = RK.Rk_race.objects
  q.filter("results__grid" => 1)
  sl = _rk_steps(q, RkMockSQLite())
  @test sl[1][:operation] == :select
  @test last(sl)[:sql_text] == "DELETE FROM \"rk_race\" AS \"Tb\" WHERE (1 = 0)"

  q = RK.Rk_race.objects
  q.filter("results__grid" => 1)
  pg = _rk_steps(q, RkMockPostgres())
  @test pg[1][:operation] == :lock && endswith(pg[1][:sql_text], " FOR UPDATE")
  @test last(pg)[:sql_text] == "DELETE FROM \"rk_race\" AS \"Tb\" WHERE \"Tb\".\"id\" = ANY(\$1)"
  @test last(pg)[:parameters] == [Int[]]
end

# ─────────────────────────────────────────────────────────────────────────────
# Which deletes resolve keys, and which keep their SQL
# Only a root filter that reads another table AND a root with a dependent the cascade writes
# (CASCADE / SET_NULL / SET_DEFAULT). Everything else must render exactly as before #1342.
# ─────────────────────────────────────────────────────────────────────────────
@testset "a filter on the root's own columns, or nothing to cascade, takes no key read (#1342)" begin
  for conn in (RkMockSQLite(), RkMockPostgres())
    # Own columns: the cascade cannot change what it matches.
    q = RK.Rk_race.objects
    q.filter("name" => "Monaco")
    steps = _rk_steps(q, conn)
    @test !any(s -> s[:operation] == :select, steps)
    @test last(steps)[:sql_text] == "DELETE FROM \"rk_race\" AS \"Tb\" WHERE \"Tb\".\"name\" = " *
      (conn isa PormG.PormGPostgres ? "\$1" : "?")

    # A joined root whose only dependent is DO_NOTHING: one statement, its own fenced predicate.
    q = RK.Rk_circuit.objects
    q.filter("races__name" => "Monaco")
    @test _rk_ops(_rk_steps(q, conn)) == [(:delete, "rk_circuit")]

    # A joined root with no dependent at all.
    q = RK.Rk_note.objects
    q.filter("result__grid" => 1)
    @test _rk_ops(_rk_steps(q, conn)) == [(:delete, "rk_note")]
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# Chunks: SQLite and MySQL bind one marker per key
# A cascaded statement binds the keys once per path into its model, so a chunk is the bind limit ÷ 16
# (`ROOT_KEY_PATH_BUDGET`). PostgreSQL binds the list as one array and never chunks.
# ─────────────────────────────────────────────────────────────────────────────
@testset "the key set is chunked to each engine's bind limit (#1342)" begin
  keys = collect(1:5000)
  @test length(QB._root_key_chunks(RkMockPostgres(), keys)) == 1
  @test length.(QB._root_key_chunks(RkMockSQLite(), keys)) == [2047, 2047, 906]      # 32766 ÷ 16
  @test all(==(62), length.(QB._root_key_chunks(RkMockOldSQLite(), keys))[1:end-1])  # 999 ÷ 16
  @test all(==(256), length.(QB._root_key_chunks(RkMockMySQL(), keys))[1:end-1])     # 4096 ÷ 16
  @test vcat(QB._root_key_chunks(RkMockSQLite(), keys)...) == keys
  @test QB._root_key_chunks(RkMockSQLite(), Int[]) == [Int[]]
end

# Executed: more races than one chunk holds on this SQLite (2047). Every race and result goes, and
# the per-table counts add up across the chunks rather than the last chunk overwriting the first.
@testset "a root set larger than one chunk deletes every row and counts across chunks (#1342)" begin
  _rk_reset!()
  n = 2100
  fetch(_RK_POOL, "DELETE FROM rk_note;")
  fetch(_RK_POOL, """INSERT INTO rk_race (id, name)
    WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM c WHERE x < $(n)) SELECT 10000 + x, 'r' FROM c;""")
  fetch(_RK_POOL, """INSERT INTO rk_result (id, race, grid)
    WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM c WHERE x < $(n)) SELECT 10000 + x, 10000 + x, 1 FROM c;""")
  @test length(QB._root_key_chunks(_RK_POOL, collect(1:n))) == 2

  q = RK.Rk_race.objects
  q.filter("results__grid" => 1)
  total, counts = q.delete()
  @test counts == Dict("rk_race" => n + 1, "rk_result" => n + 2, "rk_lap" => 1)
  @test total == 2n + 4
  @test _rk_ids("rk_race") == [2, 3]
  @test _rk_ids("rk_result") == [20]
end

# A `cjoin_on` join reads another table with no `filter()` at all: under `allow_delete_all` the join
# still renders inside the root's predicate, so it is resolved to keys like a filter would be. Before
# the trigger read the rendered predicate (it read `filter`), this kept race 1 and deleted its results.
@testset "an unfiltered cjoin_on root is resolved to keys too (#1342)" begin
  _rk_reset!()
  q = RK.Rk_race.objects
  q.cjoin_on("Rk_result", alias = "c", join_type = "INNER", on = [Joined("c", "race") == F("id"), Joined("c", "grid") == 1])
  _rk_assert_race_1_deleted(q.delete(allow_delete_all = true)...)
end

# Every chunk is planned before any runs, so a PROTECT refusal found while planning a LATER chunk
# still comes before the first write. Caught inside the caller's own transaction (which then
# commits), nothing may have been deleted: the 2047 races of the first chunk used to be.
@testset "a refusal planned in a later chunk comes before any chunk writes (#1342)" begin
  _rk_reset!()
  n = 2100
  fetch(_RK_POOL, """INSERT INTO rk_race (id, name)
    WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM c WHERE x < $(n)) SELECT 10000 + x, 'r' FROM c;""")
  fetch(_RK_POOL, """INSERT INTO rk_result (id, race, grid)
    WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM c WHERE x < $(n)) SELECT 10000 + x, 10000 + x, 1 FROM c;""")
  fetch(_RK_POOL, "INSERT INTO rk_flag (id, race) VALUES (1, $(10000 + n));")   # in the second chunk

  raised = false
  PormG.run_in_transaction("rk1342_sqlite") do
    try
      q = RK.Rk_race.objects
      q.filter("results__grid" => 1)
      q.delete()
    catch e
      e isa PormG.ProtectedError || rethrow()
      raised = true
    end
  end
  @test raised
  @test length(_rk_ids("rk_race")) == n + 3
  @test length(_rk_ids("rk_result")) == n + 3
end

finally
  delete!(PormG.config, "rk1342_sqlite")
  # Release the SQLite handle so the temp dir can be removed on Windows (WAL keeps it open).
  PormG.ConnectionPool.close_pool!(_RK_POOL)
end
