"""
Unit coverage for the mutation fence (#765): every UPDATE/DELETE the ORM emits puts its filters on
the row it writes.

`delete()`, every statement its cascade emits, and a joined `update()` used to scope their rows as
`"pk" IN (SELECT "Tb"."pk" FROM <t> AS "Tb" WHERE <filters>)`. Under PostgreSQL READ COMMITTED a
statement that waits on a row lock re-checks the row's NEW version against its own quals only — a
self-subquery over the target is an independent scan read on the old snapshot, and is never re-run —
so a filter used as a guard (a compare-and-delete) was ignored when a concurrent UPDATE committed
while the statement waited. The race itself is staged for real, on PostgreSQL, in
`test/integration/test_mutation_fence_concurrency.jl`; this file pins the SHAPE that makes the fence
hold, on both dialects, and executes it on a real SQLite file:

  - no joins → `WHERE "Tb"."col" = …`, the filters verbatim on the target alias;
  - joins    → `WHERE "Tb"."pk" IN (SELECT DISTINCT …) AND EXISTS (SELECT 1 FROM (SELECT 1) AS
    "__pormg_anchor" LEFT JOIN … ON "Tb"… )`: the pre-#765 selection kept for its index-driven plan,
    ANDed with a fence correlated to the outer target row, which PostgreSQL re-evaluates.

The discriminating assertions are the absence of a subquery over the statement's OWN table
(`FROM "<target>" as`) for a join-free statement, and the presence of the fence for a joined one.
Every pre-#765 statement carried the first and lacked the second.

Hermetic: mock connections for the shapes, a temp SQLite file for execution.
"""
# julia --project=test/integration test/unit/test_mutation_fence_shape.jl

using Test
using DataFrames
using PormG
using PormG.Models
import PormG.ConnectionPool: fetch, SQLiteConnectionPool

include("helper_marker_alignment.jl")

struct MfMockSQLite <: PormG.PormGSQLite end
struct MfMockPostgres <: PormG.PormGPostgres end
const _MF_SL = MfMockSQLite()
const _MF_PG = MfMockPostgres()
PormG.backend_sqlite_version(::MfMockSQLite) = 3045000

PormG.config["mf_mock"] = PormG.Configuration.Settings(
  connections = _MF_SL,
  change_data = true,
  db_def_folder = "mf_mock",
)

module MfModels
import PormG
import PormG.Models

# A worker store in miniature: runs own tasks (CASCADE), tasks carry notes (SET_NULL) and keyless
# tags. The shape Nitro.jl#379 hit — a compare-and-delete on `mf_task` — plus one of each statement
# kind the deletion collector can emit.
# The org a run belongs to: gives a task filter a second hop (`run__org__name`) for #771.
Mf_org = Models.Model("mf_org",
  id   = Models.IDField(),
  name = Models.CharField(),
)

# An unmanaged view a run points at (models.md → Unmanaged models): #771 must not lock through it.
Mf_run_stats_v = Models.Model("mf_run_stats_v"; managed = false,
  id    = Models.IDField(),
  score = Models.IntegerField(),
)

Mf_run = Models.Model("mf_run",
  id     = Models.IDField(),
  status = Models.CharField(),
  org    = Models.ForeignKey(Mf_org, on_delete = "DO_NOTHING", related_name = "runs", null = true),
  stats  = Models.ForeignKey(Mf_run_stats_v, on_delete = "DO_NOTHING", related_name = "runs",
    null = true, db_constraint = false),
)

Mf_task = Models.Model("mf_task",
  id     = Models.IDField(),
  name   = Models.CharField(),
  status = Models.CharField(),
  run    = Models.ForeignKey(Mf_run, on_delete = "CASCADE", related_name = "tasks", null = true),
)

Mf_note = Models.Model("mf_note",
  id   = Models.IDField(),
  body = Models.CharField(),
  task = Models.ForeignKey(Mf_task, on_delete = "SET_NULL", related_name = "notes", null = true),
)

# #771 — every other way a join can reach an unmanaged model. A reverse hop: an unmanaged audit view
# keyed at tasks. And a many-to-many whose related end is unmanaged, from an unmanaged owner (so the
# auto join table is unmanaged too, Django's rule) and from a managed one (so it is created, and
# locked). Each owner has a CASCADE child, so it is a parent and takes locks at all.
Mf_audit = Models.Model("mf_audit_v"; managed = false,
  id    = Models.IDField(),
  score = Models.IntegerField(),
  task  = Models.ForeignKey(Mf_task, on_delete = "DO_NOTHING", related_name = "audits", null = true),
)

Mf_label = Models.Model("mf_label_v"; managed = false,
  id    = Models.IDField(),
  label = Models.CharField(),
)

Mf_feed = Models.Model("mf_feed_v"; managed = false,
  id     = Models.IDField(),
  labels = Models.ManyToManyField(Mf_label, related_name = "feeds"),
)

Mf_feed_item = Models.Model("mf_feed_item",
  id   = Models.IDField(),
  feed = Models.ForeignKey(Mf_feed, on_delete = "CASCADE", related_name = "items", db_constraint = false),
)

Mf_board = Models.Model("mf_board",
  id     = Models.IDField(),
  labels = Models.ManyToManyField(Mf_label, related_name = "boards"),
)

Mf_pin = Models.Model("mf_pin",
  id    = Models.IDField(),
  board = Models.ForeignKey(Mf_board, on_delete = "CASCADE", related_name = "pins"),
)

# Keyless: no primary key, so a joined update of it cannot go through a pk anyway.
Mf_tag = Models.Model("mf_tag",
  task  = Models.ForeignKey(Mf_task, on_delete = "DO_NOTHING", related_name = "tags", null = true),
  label = Models.CharField(null = true),
)

PormG.Models.set_models(@__MODULE__, "mf_mock")
end

const MF = MfModels
const _MF_BACKENDS = (("PostgreSQL", _MF_PG, :postgres), ("SQLite", _MF_SL, :sqlite))

"""Every statement `delete()` emits for `q`, as a Vector of inspection Dicts."""
function _mf_steps(q, conn)
  res = q.delete(show_query = :dict, connection = conn)
  return res isa Vector ? res : [res]
end

"""
The WRITE step (`DELETE` / `UPDATE`) whose `:model` is `name`, skipping a #770 `:lock` step for the
same model. Fails loudly rather than returning `nothing`.
"""
function _mf_step(steps, name::String)
  idx = findfirst(s -> s[:model] == name && s[:operation] != :lock, steps)
  @assert idx !== nothing "no step for $(name); got $([s[:model] for s in steps])"
  return steps[idx]
end

"""
`q.update(pairs...; show_query = :dict)` rendered against `conn`. The fluent form takes only
`show_query`, so this fills `insert` the way `_update!` does and calls the terminal, which accepts the
same `connection =` override `delete()` does.
"""
function _mf_update(q, pairs::Pair...; conn)
  empty!(q.object.insert)
  for (k, v) in pairs
    q.object.insert[k] = v
  end
  return PormG.QueryBuilder.update(q.object; connection = conn, show_query = :dict)
end

"""True when `sql` scans its own target table in a subquery — the pre-#765 shape."""
_mf_self_subquery(sql::AbstractString, table::String) = occursin("FROM \"$(table)\" as", sql)

# ─────────────────────────────────────────────────────────────────────────────
# The issue's shape: a compare-and-delete on the target's own columns
# `filter("id" => k, "status__@in" => terminal).delete()` must put both predicates on the row being
# deleted. Pre-#765: `DELETE FROM "mf_task" WHERE "id" IN (SELECT "Tb"."id" FROM "mf_task" as "Tb"
# WHERE …)`, which PostgreSQL never re-checks.
# ─────────────────────────────────────────────────────────────────────────────
@testset "a root delete filters the target row itself (#765)" begin
  for (backend, conn, kind) in _MF_BACKENDS
    @testset "$backend" begin
      q = MF.Mf_task.objects
      q.filter("id" => 7, "status__@in" => ["COMPLETED", "FAILED"])
      root = _mf_step(_mf_steps(q, conn), "mf_task")
      sql = root[:sql_text]

      @test startswith(sql, "DELETE FROM \"mf_task\" AS \"Tb\" WHERE \"Tb\".\"id\" = ")
      # `__@in` is `IN (?, ?)` on SQLite and `= ANY($2)` with one array value on PostgreSQL.
      @test occursin(" AND \"Tb\".\"status\" ", sql)
      @test !_mf_self_subquery(sql, "mf_task")
      @test !occursin("SELECT", sql)
      @test root[:parameters] == (kind === :sqlite ? [7, "COMPLETED", "FAILED"] : [7, ["COMPLETED", "FAILED"]])
      assert_marker_count(root, kind)
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# The cascade: each statement fences on the child's OWN foreign key
# A task re-parented to another run mid-delete must not be deleted on the old run's account, and a
# note re-pointed at another task must not be nulled. Both statements now compare the child's FK on
# the target row; the parent set is still a subquery, which is correct — it is not the target.
# ─────────────────────────────────────────────────────────────────────────────
@testset "cascade DELETE and SET_NULL UPDATE filter on the child's own foreign key (#765)" begin
  for (backend, conn, kind) in _MF_BACKENDS
    @testset "$backend" begin
      q = MF.Mf_run.objects
      q.filter("status" => "GONE")
      steps = _mf_steps(q, conn)

      task = _mf_step(steps, "mf_task")
      @test task[:operation] == :delete
      @test startswith(task[:sql_text], "DELETE FROM \"mf_task\" AS \"Tb\" WHERE \"Tb\".\"run\" IN (SELECT")

      note = _mf_step(steps, "mf_note")
      @test note[:operation] == :update
      @test startswith(note[:sql_text], "UPDATE \"mf_note\" AS \"Tb\" SET \"task\" = NULL WHERE \"Tb\".\"task\" IN (SELECT")

      run = _mf_step(steps, "mf_run")
      @test startswith(run[:sql_text], "DELETE FROM \"mf_run\" AS \"Tb\" WHERE \"Tb\".\"status\" = ")

      # No statement scans its own table: the discriminator against the pre-#765 renderer.
      for s in steps
        @test !_mf_self_subquery(s[:sql_text], s[:model])
        @test s[:parameters] == ["GONE"]
        assert_marker_count(s, kind)
      end
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# #770: the parents are locked, top-down, before any statement touches their children
# Children go before their parent, and a child's statement reads its parents when IT runs. A parent
# that stopped matching after its children were gone kept its own row (the #765 fence skipped it) but
# lost them. So on PostgreSQL every collected model that is a parent of an emitted statement is locked
# `FOR UPDATE` first, root first, through the very predicate its DELETE renders. The race itself is
# staged on db_2 in test_mutation_fence_concurrency.jl; this pins the sequence and the shape.
# ─────────────────────────────────────────────────────────────────────────────
"""The predicate a write step renders after `WHERE`, i.e. what its lock must carry verbatim."""
function _mf_predicate(step, table::String)
  prefix = "DELETE FROM \"$(table)\" AS \"Tb\" WHERE "
  @assert startswith(step[:sql_text], prefix) "unexpected write shape: $(step[:sql_text])"
  return step[:sql_text][ncodeunits(prefix)+1:end]
end

_mf_lock_sql(table::String, predicate::String) =
  "SELECT count(*) FROM (SELECT 1 FROM \"$(table)\" AS \"Tb\"" *
  (isempty(predicate) ? "" : " WHERE $(predicate)") * " FOR UPDATE) AS \"__pormg_lock\""

_mf_ops(steps) = [(s[:operation], s[:model]) for s in steps]

@testset "a cascade locks its parents top-down before any write (#770)" begin
  @testset "PostgreSQL: every parent, root first, each on its DELETE's own predicate" begin
    q = MF.Mf_run.objects
    q.filter("status" => "GONE")
    steps = _mf_steps(q, _MF_PG)

    # mf_run and mf_task are parents of a statement; mf_note is a leaf (SET_NULL) and mf_tag emits
    # nothing (DO_NOTHING), so neither is locked. The locks come before every write.
    @test _mf_ops(steps)[1:2] == [(:lock, "mf_run"), (:lock, "mf_task")]
    @test count(s -> s[:operation] == :lock, steps) == 2
    @test last(_mf_ops(steps)) == (:delete, "mf_run")

    for table in ("mf_run", "mf_task")
      lock = steps[findfirst(s -> s[:operation] == :lock && s[:model] == table, steps)]
      write = _mf_step(steps, table)
      @test lock[:sql_text] == _mf_lock_sql(table, _mf_predicate(write, table))
      @test lock[:parameters] == write[:parameters] == ["GONE"]
      assert_marker_count(lock, :postgres)
    end
  end

  @testset "PostgreSQL: a SET_NULL target's parent is locked before it is nulled" begin
    q = MF.Mf_task.objects
    q.filter("status" => "DONE")
    @test _mf_ops(_mf_steps(q, _MF_PG)) == [(:lock, "mf_task"), (:update, "mf_note"), (:delete, "mf_task")]
  end

  @testset "PostgreSQL: a joined root locks through the same IN + EXISTS, FOR UPDATE once, outermost" begin
    q = MF.Mf_task.objects
    q.filter("id" => 7, "run__status" => "OPEN")
    steps = _mf_steps(q, _MF_PG)
    lock = steps[1]
    @test lock[:operation] == :lock
    @test lock[:sql_text] == _mf_lock_sql("mf_task", _mf_predicate(_mf_step(steps, "mf_task"), "mf_task"))
    @test occursin("AS \"__pormg_anchor\"", lock[:sql_text])
    @test count("FOR UPDATE", lock[:sql_text]) == 1
    @test lock[:parameters] == [7, "OPEN", 7, "OPEN"]
    assert_marker_count(lock, :postgres)
  end

  @testset "PostgreSQL: an unfiltered root (allow_delete_all) locks the whole table" begin
    res = MF.Mf_run.objects.delete(show_query = :dict, connection = _MF_PG, allow_delete_all = true)
    steps = res isa Vector ? res : [res]
    @test steps[1][:operation] == :lock
    @test steps[1][:sql_text] == _mf_lock_sql("mf_run", "")
    @test isempty(steps[1][:parameters])
  end

  @testset "PostgreSQL: a delete with nothing to cascade takes no lock" begin
    q = MF.Mf_note.objects
    q.filter("id" => 3)
    @test _mf_ops(_mf_steps(q, _MF_PG)) == [(:delete, "mf_note")]
  end

  @testset "SQLite: no lock at all — writers are already serialized" begin
    q = MF.Mf_run.objects
    q.filter("status" => "GONE")
    @test !any(s -> s[:operation] == :lock, _mf_steps(q, _MF_SL))
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# #771: a root filter across a relation — the tables it JOINS are locked too
# #770's lock pins the root's own row, and a joined filter also reads another table: a concurrent
# rename of that row flipped the root after its children were gone (staged on db_2 in
# test_mutation_fence_concurrency.jl). So right after the root's own lock comes one `FOR SHARE` per
# hop, in chain order. Each sits on a plain scan of the hop's table, keyed through the join, never on
# the nullable side of the LEFT JOIN, which PostgreSQL refuses to lock.
# ─────────────────────────────────────────────────────────────────────────────
_mf_locks(steps) = [s for s in steps if s[:operation] == :lock]

@testset "a joined root locks the tables its filter reads (#771)" begin
  @testset "PostgreSQL: one hop, FOR SHARE after the root's own lock, before any write" begin
    q = MF.Mf_task.objects
    q.filter("id" => 7, "run__status" => "OPEN")
    steps = _mf_steps(q, _MF_PG)
    @test _mf_ops(steps) == [(:lock, "mf_task"), (:lock, "mf_run"), (:update, "mf_note"), (:delete, "mf_task")]

    hop = steps[2]
    @test hop[:sql_text] ==
      "SELECT count(*) FROM (SELECT 1 FROM \"mf_run\" AS \"__pormg_locked\" " *
      "WHERE \"__pormg_locked\".\"id\" IN (SELECT DISTINCT \"Tb_1\".\"id\"\n" *
      "  FROM \"mf_task\" as \"Tb\"\n" *
      "   LEFT JOIN \"mf_run\" AS \"Tb_1\" ON \"Tb\".\"run\" = \"Tb_1\".\"id\" \n" *
      "  WHERE \"Tb\".\"id\" = \$1 AND \"Tb_1\".\"status\" = \$2) FOR SHARE) AS \"__pormg_lock\""
    @test hop[:parameters] == [7, "OPEN"]
    assert_marker_count(hop, :postgres)
    # The root's own lock is the #770 statement, untouched: FOR UPDATE, once.
    @test count("FOR UPDATE", steps[1][:sql_text]) == 1
    @test !occursin("FOR SHARE", steps[1][:sql_text])
  end

  @testset "PostgreSQL: two hops lock in chain order, each keyed through its own alias" begin
    q = MF.Mf_task.objects
    q.filter("run__org__name" => "ACME")
    locks = _mf_locks(_mf_steps(q, _MF_PG))
    @test [s[:model] for s in locks] == ["mf_task", "mf_run", "mf_org"]
    @test startswith(locks[2][:sql_text],
      "SELECT count(*) FROM (SELECT 1 FROM \"mf_run\" AS \"__pormg_locked\" WHERE \"__pormg_locked\".\"id\" IN (SELECT DISTINCT \"Tb_1\".\"id\"\n")
    @test startswith(locks[3][:sql_text],
      "SELECT count(*) FROM (SELECT 1 FROM \"mf_org\" AS \"__pormg_locked\" WHERE \"__pormg_locked\".\"id\" IN (SELECT DISTINCT \"Tb_2\".\"id\"\n")
    for hop in locks[2:3]
      @test endswith(hop[:sql_text], " FOR SHARE) AS \"__pormg_lock\"")
      @test hop[:parameters] == ["ACME"]
      assert_marker_count(hop, :postgres)
    end
  end

  # An ON value binds ahead of the WHERE value in the text. PostgreSQL numbers `$N` as values bind
  # (WHERE first), so the pin is that each number still names its own value.
  @testset "PostgreSQL: a join carrying an ON value binds each marker to its own value" begin
    q = MF.Mf_task.objects
    q.filter("status" => "WHEREVAL")
    q.cjoin("run" => "Mf_run", filters = ["status" => "ONVAL"], warn = false)
    hop = _mf_locks(_mf_steps(q, _MF_PG))[2]
    @test occursin("ON \"Tb\".\"run\" = \"Tb_1\".\"id\" AND \"Tb_1\".\"status\" = \$2 \n  WHERE \"Tb\".\"status\" = \$1)", hop[:sql_text])
    @test hop[:parameters] == ["WHEREVAL", "ONVAL"]
    assert_marker_count(hop, :postgres)
  end

  # A view cannot always be locked (`FOR SHARE` fails on an aggregating or materialized one, and needs
  # UPDATE privilege), so a hop into an unmanaged model is left unpinned — the managed hop before it
  # in the same chain is still locked.
  @testset "PostgreSQL: a hop into an unmanaged model is not locked" begin
    q = MF.Mf_task.objects
    q.filter("run__status" => "OPEN", "run__stats__score__@gt" => 10)
    locks = _mf_locks(_mf_steps(q, _MF_PG))
    @test [s[:model] for s in locks] == ["mf_task", "mf_run"]
    @test !any(s -> occursin("\"mf_run_stats_v\" AS \"__pormg_locked\"", s[:sql_text]), locks)
    # ...but the view is still in the join the managed hop's selection reads.
    @test occursin("JOIN \"mf_run_stats_v\"", locks[2][:sql_text])
    assert_marker_count(locks[2], :postgres)
  end

  # The same skip through every other producer of a join row, each pinned on its own.
  @testset "PostgreSQL: the skip holds for a reverse hop, a cjoin and a many-to-many" begin
    lock_models(q) = [s[:model] for s in _mf_locks(_mf_steps(q, _MF_PG))]

    # A reverse hop into the unmanaged audit view (`_reverse_hop`).
    q = MF.Mf_task.objects
    q.filter("id" => 7, "audits__score__@gt" => 10)
    @test lock_models(q) == ["mf_task"]

    # A cjoin into it, which rebuilds the row by copy (`_with_config`).
    q = MF.Mf_run.objects
    q.cjoin("stats" => "Mf_run_stats_v", filters = ["score" => 5], warn = false)
    q.filter("status" => "OPEN")
    # mf_task is the #770 lock of the next level down; no mf_run_stats_v hop sits between them.
    @test lock_models(q) == ["mf_run", "mf_task"]

    # Both ends unmanaged: the auto join table is unmanaged as well, so neither hop is locked.
    q = MF.Mf_feed.objects
    q.filter("labels__label" => "x")
    @test lock_models(q) == ["mf_feed_v"]

    # A managed owner: its auto join table is created by PormG, so it is locked; the unmanaged
    # related end is not.
    q = MF.Mf_board.objects
    q.filter("labels__label" => "x")
    locks = lock_models(q)
    @test length(locks) == 2 && locks[1] == "mf_board"
    @test !("mf_label_v" in locks)
  end

  @testset "PostgreSQL: a join-free root takes no FOR SHARE" begin
    q = MF.Mf_run.objects
    q.filter("status" => "GONE")
    @test !any(s -> occursin("FOR SHARE", s[:sql_text]), _mf_steps(q, _MF_PG))
  end

  @testset "PostgreSQL: a joined root with nothing to cascade takes no lock at all" begin
    q = MF.Mf_note.objects
    q.filter("task__run__status" => "OPEN")
    @test _mf_ops(_mf_steps(q, _MF_PG)) == [(:delete, "mf_note")]
  end

  @testset "SQLite: a joined root takes no lock" begin
    q = MF.Mf_task.objects
    q.filter("id" => 7, "run__status" => "OPEN")
    @test isempty(_mf_locks(_mf_steps(q, _MF_SL)))
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# A filter that crosses a relation: a correlated EXISTS, joins kept as LEFT JOINs
# The join's ON references the OUTER "Tb", which is what makes PostgreSQL re-evaluate it against the
# new row version. The one-row anchor keeps the join tree the read builder rendered, LEFT JOINs and
# all — flattening them into FROM would silently turn an `__@isnull` anti-join into an inner join.
#
# A joined statement carries the pre-#765 pk selection AND the fence: `"Tb"."id" IN (SELECT DISTINCT
# …) AND EXISTS (…)`. The IN keeps the index-driven plan (a correlated EXISTS whose correlation sits
# in a JOIN's ON is not flattened by PostgreSQL, so alone it scans the whole target); the EXISTS is
# what gets re-checked. They are two builds of the query, so every value is bound twice, in text order.
# The discriminator against the unfixed renderer is the fence: the old statement had no EXISTS at all.
# ─────────────────────────────────────────────────────────────────────────────
const _MF_FENCE = "EXISTS (SELECT 1 FROM (SELECT 1) AS \"__pormg_anchor\""

@testset "a joined delete selects by pk AND fences through a correlated EXISTS (#765)" begin
  for (backend, conn, kind) in _MF_BACKENDS
    @testset "$backend" begin
      q = MF.Mf_task.objects
      q.filter("id" => 7, "run__status" => "OPEN")
      root = _mf_step(_mf_steps(q, conn), "mf_task")
      sql = root[:sql_text]

      @test startswith(sql, "DELETE FROM \"mf_task\" AS \"Tb\" WHERE \"Tb\".\"id\" IN (SELECT DISTINCT \"Tb\".\"id\"")
      @test occursin(")\n  AND " * _MF_FENCE, sql)
      # The fence's join hangs off the OUTER target row — the correlation PostgreSQL re-checks.
      @test occursin(_MF_FENCE * "\n   LEFT JOIN \"mf_run\" AS \"Tb_1\" ON \"Tb\".\"run\" = \"Tb_1\".\"id\"", sql)
      # Two builds, each binding its own values, IN first: text order on both dialects.
      @test root[:parameters] == [7, "OPEN", 7, "OPEN"]
      assert_marker_count(root, kind)
    end
  end
end

@testset "a joined update selects by pk AND fences through a correlated EXISTS (#765)" begin
  for (backend, conn, kind) in _MF_BACKENDS
    @testset "$backend" begin
      q = MF.Mf_task.objects
      q.filter("run__status" => "OPEN")
      insp = _mf_update(q, "name" => "requeued"; conn = conn)
      sql = insp[:sql_text]

      @test startswith(sql, "UPDATE \"mf_task\" AS \"Tb\"")
      @test occursin("WHERE \"Tb\".\"id\" IN (SELECT DISTINCT \"Tb\".\"id\"", sql)
      @test occursin(")\n  AND " * _MF_FENCE, sql)
      @test occursin("LEFT JOIN \"mf_run\" AS \"Tb_1\" ON \"Tb\".\"run\" = \"Tb_1\".\"id\"", sql)
      # SQLite binds in TEXT order: SET, the IN's value, then the fence's. PostgreSQL numbers `$N` as
      # values bind (WHERE is built first), and the number travels with the text, so its order is free.
      kind === :sqlite && assert_bound_in_text_order(insp, ["requeued", "OPEN", "OPEN"])
      assert_marker_count(insp, kind)
    end
  end
end

# A root that binds in BOTH ON and WHERE, built twice: without the per-build mark/detach, `:join`
# would flatten the two ON values ahead of the first WHERE value — ONVAL, ONVAL, WHEREVAL, WHEREVAL
# against a text order of ONVAL, WHEREVAL, ONVAL, WHEREVAL. That is a silent wrong write on SQLite.
@testset "a joined delete / update binds both builds in text order on SQLite (#765 / #432)" begin
  q = MF.Mf_task.objects
  q.filter("status" => "WHEREVAL")
  q.cjoin("run" => "Mf_run", filters = ["status" => "ONVAL"], warn = false)
  root = _mf_step(_mf_steps(q, _MF_SL), "mf_task")
  assert_marker_count(root, :sqlite)
  assert_bound_in_text_order(root, ["ONVAL", "WHEREVAL", "ONVAL", "WHEREVAL"])

  # update(): the selection is the top-level build (its `:join` then `:where`), the fence a second
  # build lifted behind it. SET first, then IN(ON, WHERE), then EXISTS(ON, WHERE).
  q = MF.Mf_task.objects
  q.filter("status" => "WHEREVAL")
  q.cjoin("run" => "Mf_run", filters = ["status" => "ONVAL"], warn = false)
  insp = _mf_update(q, "name" => "SETVAL"; conn = _MF_SL)
  assert_marker_count(insp, :sqlite)
  assert_bound_in_text_order(insp, ["SETVAL", "ONVAL", "WHEREVAL", "ONVAL", "WHEREVAL"])
end

# A keyless model has no pk to select through, so it takes the fence alone. It used to take
# UPDATE … FROM, which flattened LEFT JOINs to inner; the anchored EXISTS keeps them.
@testset "a joined update of a keyless model takes the fence alone (#765)" begin
  for (backend, conn, kind) in _MF_BACKENDS
    q = MF.Mf_tag.objects
    q.filter("task__status" => "FAILED")
    insp = _mf_update(q, "label" => "retry"; conn = conn)
    @test occursin("WHERE " * _MF_FENCE, insp[:sql_text])
    @test !occursin("IN (SELECT DISTINCT", insp[:sql_text])
    @test !occursin("\nFROM ", insp[:sql_text])
    assert_marker_count(insp, kind)
  end
end

# RIGHT / FULL inside the fence. The anchor stands where the target stood, so a verbatim RIGHT JOIN
# would keep every right-side row and make the EXISTS true for every target row (a silent widening);
# a FULL JOIN whose ON names only the outer row is refused by PostgreSQL. The old `pk IN (…)` dropped
# rows where the target was null-extended, which is exactly INNER / LEFT — so the fence renders those.
# The selection half keeps the join type verbatim: there the target is a real table, as before.
@testset "a RIGHT / FULL join renders INNER / LEFT inside the fence (#765)" begin
  for (backend, conn, kind) in _MF_BACKENDS
    for (how, fenced) in (("RIGHT", "INNER"), ("FULL", "LEFT"))
      q = MF.Mf_tag.objects
      q.cjoin("task" => "Mf_task", join_type = how, warn = false)
      q.filter("task__status" => "FAILED")
      sql = _mf_update(q, "label" => "retry"; conn = conn)[:sql_text]
      @test occursin(_MF_FENCE * "\n   $(fenced) JOIN \"mf_task\"", sql)
      @test !occursin("$(how) JOIN", sql)

      q = MF.Mf_task.objects
      q.cjoin("run" => "Mf_run", join_type = how, warn = false)
      q.filter("run__status" => "OPEN")
      sql = _mf_update(q, "name" => "x"; conn = conn)[:sql_text]
      @test occursin("$(how) JOIN \"mf_run\"", sql)                     # the selection, verbatim
      @test occursin(_MF_FENCE * "\n   $(fenced) JOIN \"mf_run\"", sql)  # the fence, rewritten
    end
  end
end

# Control: a SET that READS a joined column still needs the join in the statement's own FROM, so it
# keeps UPDATE … FROM — whose target predicates are already on the target, and so already re-checked.
@testset "an update whose SET reads a join keeps UPDATE … FROM (#765 control)" begin
  for (backend, conn, kind) in _MF_BACKENDS
    q = MF.Mf_task.objects
    q.filter("id" => 3)
    insp = _mf_update(q, "name" => F("run__status"); conn = conn)
    @test occursin("FROM \"mf_run\" AS \"Tb_1\"", insp[:sql_text])
    @test !occursin("__pormg_anchor", insp[:sql_text])
    assert_marker_count(insp, kind)
  end
end


# ─────────────────────────────────────────────────────────────────────────────
# Execution on a real SQLite file: the new shapes run, and select the rows the old ones did
# SQLite is not exposed to the race, but it runs the identical text, so this is where "the statement
# is accepted" and "the row set did not change" are proven for both shapes. The anti-join is the
# case a flattened (inner) join would get wrong: task 12 has no run at all.
#
# The models are registered (`set_models`) against a config key of their own, because a join
# traversal resolves its foreign key through the registered module.
# ─────────────────────────────────────────────────────────────────────────────
const _MF_DIR  = mktempdir()
const _MF_POOL = SQLiteConnectionPool(joinpath(_MF_DIR, "mf765.sqlite"); pool_size = 1)
PormG.config["mf765_sqlite"] = PormG.Configuration.Settings(
  connections = _MF_POOL, db_def_folder = "mf765_sqlite", change_data = true)  # set_models resolves the key through it

module MfSqlite
import PormG
import PormG.Models
Mf_run = Models.Model("mf_run", id = Models.IDField(), status = Models.CharField())
Mf_task = Models.Model("mf_task",
  id     = Models.IDField(),
  name   = Models.CharField(),
  status = Models.CharField(),
  run    = Models.ForeignKey(Mf_run, on_delete = "DO_NOTHING", related_name = "tasks", null = true),
)
# Keyless: a joined update of it takes the fence alone (no pk to select through).
Mf_tag = Models.Model("mf_tag",
  task  = Models.ForeignKey(Mf_task, on_delete = "DO_NOTHING", related_name = "tags", null = true),
  label = Models.CharField(null = true),
)
PormG.Models.set_models(@__MODULE__, "mf765_sqlite")
end

@testset "the fenced shapes execute on SQLite with unchanged row sets (#765)" begin
  try
    fetch(_MF_POOL, "CREATE TABLE mf_run (id INTEGER PRIMARY KEY, status TEXT NOT NULL);")
    fetch(_MF_POOL, """CREATE TABLE mf_task (id INTEGER PRIMARY KEY, name TEXT NOT NULL,
      status TEXT NOT NULL, run INTEGER REFERENCES mf_run (id));""")
    fetch(_MF_POOL, "INSERT INTO mf_run (id, status) VALUES (1, 'OPEN'), (2, 'DONE');")
    fetch(_MF_POOL, """INSERT INTO mf_task (id, name, status, run) VALUES
      (10, 't10', 'COMPLETED', 1), (11, 't11', 'PENDING', 2), (12, 't12', 'FAILED', NULL);""")
    # No REFERENCES on purpose: the task deletes below must not trip a constraint on these rows.
    fetch(_MF_POOL, "CREATE TABLE mf_tag (task INTEGER, label TEXT);")
    fetch(_MF_POOL, "INSERT INTO mf_tag (task, label) VALUES (10, 'a'), (11, 'b'), (NULL, 'c');")

    names() = sort((fetch(_MF_POOL, "SELECT name FROM mf_task;") |> DataFrame).name)
    labels() = sort((fetch(_MF_POOL, "SELECT label FROM mf_tag;") |> DataFrame).label)

    # Keyless, fence alone: the anti-join through a LEFT JOIN matches only the tag with no task. The
    # pre-#765 UPDATE … FROM flattened the join to inner and matched nothing.
    orphan_tags = MfSqlite.Mf_tag.objects
    orphan_tags.filter("task__status__@isnull" => true)
    @test orphan_tags.update("label" => "orphan") == 1
    @test labels() == ["a", "b", "orphan"]

    # Keyless, RIGHT join: only the tag whose task is COMPLETED. Rendered verbatim inside the fence,
    # the RIGHT JOIN would make the EXISTS true for every tag (one COMPLETED task exists) — all 3.
    right = MfSqlite.Mf_tag.objects
    right.cjoin("task" => "Mf_task", join_type = "RIGHT", warn = false)
    right.filter("task__status" => "COMPLETED")
    @test right.update("label" => "right") == 1
    @test labels() == ["b", "orphan", "right"]
    quiet(f) = Base.CoreLogging.with_logger(f, Base.CoreLogging.SimpleLogger(IOBuffer(), Base.CoreLogging.Error))

    # A fence that no longer matches removes nothing (delete() warns on zero rows; kept quiet).
    miss = MfSqlite.Mf_task.objects
    miss.filter("id" => 10, "status__@in" => ["FAILED"])
    @test first(quiet(() -> miss.delete())) == 0
    @test names() == ["t10", "t11", "t12"]

    # Joined update through the anchored EXISTS: only the task whose run is DONE.
    upd = MfSqlite.Mf_task.objects
    upd.filter("run__status" => "DONE")
    @test upd.update("name" => "moved") == 1
    @test names() == ["moved", "t10", "t12"]

    # Anti-join through a LEFT JOIN: only task 12, which has no run. An inner join matches none.
    orphan = MfSqlite.Mf_task.objects
    orphan.filter("run__status__@isnull" => true)
    total, _ = orphan.delete()
    @test total == 1
    @test names() == ["moved", "t10"]

    # A fence that does match deletes exactly its row.
    hit = MfSqlite.Mf_task.objects
    hit.filter("id" => 10, "status__@in" => ["COMPLETED"])
    @test first(hit.delete()) == 1
    @test names() == ["moved"]
  finally
    delete!(PormG.config, "mf765_sqlite")
    # Release the SQLite handle so the temp dir can be removed on Windows (WAL keeps it open).
    PormG.ConnectionPool.close_pool!(_MF_POOL)
  end
end
