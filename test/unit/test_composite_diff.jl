"""
UNIT TESTS: model-level composite indexes are diffed on an existing table (#161, closing #19)

`Models.UniqueConstraint` and `Models.Index` used to be materialized only when their table was
first created. Adding, removing or changing one on a table that already existed planned nothing —
and no reader returned composite UNIQUENESS at all, so nothing could have noticed. Since #161
`makemigrations` diffs them like columns:

  * IDENTITY is `(unique, ordered physical columns)`, never the name — a Django-adopted
    `UNIQUE (a, b)` satisfies a declared `UniqueConstraint`, and a table renamed under #615 keeps its
    `<old>_a_b_uniq` without churn;
  * an undeclared READABLE composite is DROPPED (state-based, like `db_index`), which the runner
    flags destructive;
  * an explicit `name=` the live index does not carry is a RENAME;
  * creates carry no `IF NOT EXISTS`, so a name another object holds fails loudly instead of
    re-planning forever.

WHAT THIS FILE PROVES, AND WHAT IT DOES NOT. Every SQLite testset applies its plan to a real temp
database IN `migrate`'s ORDER (`_order_statements`) and then asks the database — a duplicate INSERT
must raise, or must not — and re-plans against a fresh read to prove convergence. The PostgreSQL
testsets are plan-shape only, over a hand-built live side: a mock has no catalog. The live
PostgreSQL half is integration Phase 21.

`_cd`-prefixed throughout: `runtests.jl` includes every unit file into ONE module.
"""

using Test
using Logging
using DataFrames
using PormG
using PormG.Models
using PormG.Migrations
import PormG: PormGModel, PormGPostgres, PormGSQLite, model_table_name
isdefined(Main, :SQLite) || include(joinpath(@__DIR__, "..", "load_drivers.jl"))
import PormG.ConnectionPool: SQLiteConnectionPool, fetch, close_pool!
import PormG.Migrations: LiveTable, LiveComposite, read_live_schema, live_table, get_migration_plan,
                         is_destructive

# ─────────────────────────────────────────────────────────────────────────────
# Harness
# ─────────────────────────────────────────────────────────────────────────────

# The PostgreSQL mock has no catalog: every lookup the planner makes answers "nothing there", which
# keeps these plans to the composite statements under test.
struct CompositeDiffMockPg161 <: PormGPostgres end
const CD_PG = CompositeDiffMockPg161()
fetch(::CompositeDiffMockPg161, sql::String; conn = nothing, params = nothing, ignore_tx::Bool = false) =
  DataFrame()

function _cd_schema(models::PormGModel...)
  schema = Dict{Symbol, Dict{Symbol, Union{Bool, PormGModel}}}()
  for m in models
    schema[Symbol(model_table_name(m))] = Dict{Symbol, Union{Bool, PormGModel}}(:model => m, :exist => false)
  end
  return schema
end

function _cd_settings()
  settings = PormG.Configuration.Settings()
  settings.change_db = true
  return settings
end

# Plan `declared` against `live`. With `answers`, the planner's rename prompts read them from stdin
# (a table rename is "no\n<n>\n", a column rename "<n>\n"); EOF answers "no".
function _cd_plan(conn, live, declared::PormGModel...; answers::Union{String, Nothing} = nothing)
  schema = _cd_schema(declared...)
  answers === nothing && return get_migration_plan(live, schema, conn, _cd_settings(); interactive = false)
  path, io = mktemp(); write(io, answers); close(io)
  return open(path) do f
    redirect_stdin(f) do
      get_migration_plan(live, schema, conn, _cd_settings(); interactive = true)
    end
  end
end

# The live side exactly as `makemigrations` reads it, limited to the tables under test.
_cd_live(pool, tables::String...) = read_live_schema(pool; include_table = collect(tables))

# Apply a plan the way `migrate` does: `_order_statements` buckets every step (and puts "Create
# index…" last, #152), so replaying the plan dict's own order would test a migration nobody runs.
# Naive `;` splitting is safe here only: every statement is DDL over identifiers this file chose.
function _cd_apply!(pool, plan)
  ordered, _ = Migrations._order_statements(collect(values(plan)))
  for sql in ordered, stmt in split(sql, ";")
    s = strip(stmt)
    isempty(s) || fetch(pool, s * ";")
  end
  return nothing
end

_cd_keys(plan, t::Symbol) = haskey(plan, t) ? collect(keys(plan[t])) : String[]
_cd_text(plan, t::Symbol) = haskey(plan, t) ? join(values(plan[t]), "\n") : ""
_cd_converged(pool, tables, declared...) = all(isempty, values(_cd_plan(pool, _cd_live(pool, tables...), declared...)))

# Can both rows go in? Asked of the database, not the plan. Rows are COMPLETE — every NOT NULL column
# given — so a refusal can only come from a uniqueness rule, and two rows that differ outside the
# columns under test isolate that one rule from the others on the table.
function _cd_both_insert(pool, table, rows::NamedTuple...)
  ok = try
    for r in rows
      cols = join(("\"$(k)\"" for k in keys(r)), ", ")
      marks = join(("?" for _ in r), ", ")
      fetch(pool, "INSERT INTO \"$(table)\" ($(cols)) VALUES ($(marks));", collect(values(r)))
    end
    true
  catch
    false
  end
  fetch(pool, "DELETE FROM \"$(table)\";")
  return ok
end

# A live table carrying table-level clauses PormG never writes — what a Django-adopted schema holds.
# Built from the planner's own CREATE TABLE so every column matches its declaration exactly, and only
# the clauses differ.
function _cd_create_with_clauses(pool, model::PormGModel, clauses::String...)
  sql = PormG.Dialect.create_table(pool, model)
  cut = findlast(')', sql)
  fetch(pool, sql[1:prevind(sql, cut)] * ",\n  " * join(clauses, ",\n  ") * "\n" * sql[cut:end])
  return nothing
end

_cd_index_names(pool, table) =
  Set(String(r.name) for r in eachrow(DataFrame(fetch(pool, "SELECT name FROM pragma_index_list(?);", [table]))))

# The F1 shape every testset starts from: one row per driver per race.
_cd_result(; kw...) = Models.Model("result"; id = Models.IDField(), raceid = Models.IntegerField(),
                                   driverid = Models.IntegerField(), grid = Models.IntegerField(null = true), kw...)

# ─────────────────────────────────────────────────────────────────────────────
# SQLite: an existing table gains, loses and reshapes composites (#161)
# The core of the issue, end to end. v1 has no composite; v2 adds a UniqueConstraint and an Index to
# the EXISTING table (both used to plan nothing); v3 moves the uniqueness to other columns and drops
# the Index. Each step is applied, the database is asked what it enforces, and a re-plan must be
# empty. The drops are destructive, and the creates carry no IF NOT EXISTS.
# ─────────────────────────────────────────────────────────────────────────────
@testset "SQLite: an existing table gains, loses and reshapes composites (#161)" begin
  mktempdir() do dir
    pool = SQLiteConnectionPool(joinpath(dir, "cd_core.sqlite"); pool_size = 1)
    try
      v1 = _cd_result()
      _cd_apply!(pool, _cd_plan(pool, LiveTable[], v1))
      @test _cd_converged(pool, ("result",), v1)

      # v2: add both kinds to the existing table.
      v2 = _cd_result(constraints = [Models.UniqueConstraint(fields = ("raceid", "driverid"))],
                      indexes = [Models.Index(fields = ("driverid", "grid"))])
      p2 = _cd_plan(pool, _cd_live(pool, "result"), v2)
      @test _cd_keys(p2, :result) == ["Create unique constraint: result_raceid_driverid_uniq",
                                      "Create index: result_driverid_grid_idx"]
      @test occursin("CREATE UNIQUE INDEX \"result_raceid_driverid_uniq\" ON \"result\" (\"raceid\", \"driverid\")", _cd_text(p2, :result))
      @test !occursin("IF NOT EXISTS", _cd_text(p2, :result))
      _cd_apply!(pool, p2)
      @test !_cd_both_insert(pool, "result", (raceid = 1, driverid = 1, grid = 1), (raceid = 1, driverid = 1, grid = 2))
      @test "result_driverid_grid_idx" in _cd_index_names(pool, "result")
      @test _cd_converged(pool, ("result",), v2)

      # v3: the uniqueness moves to (raceid, grid); the Index is removed.
      v3 = _cd_result(constraints = [Models.UniqueConstraint(fields = ("raceid", "grid"))])
      p3 = _cd_plan(pool, _cd_live(pool, "result"), v3)
      @test sort(_cd_keys(p3, :result)) == sort(["Remove composite index: result_driverid_grid_idx",
                                                 "Remove composite index: result_raceid_driverid_uniq",
                                                 "Create unique constraint: result_raceid_grid_uniq"])
      # The drops come first: a create of a reused name would otherwise meet the old index.
      @test last(_cd_keys(p3, :result)) == "Create unique constraint: result_raceid_grid_uniq"
      @test is_destructive(p3[:result]["Remove composite index: result_driverid_grid_idx"])
      _cd_apply!(pool, p3)
      @test _cd_both_insert(pool, "result", (raceid = 1, driverid = 1, grid = 1), (raceid = 1, driverid = 1, grid = 2))
      @test !_cd_both_insert(pool, "result", (raceid = 1, driverid = 1, grid = 1), (raceid = 1, driverid = 2, grid = 1))
      @test _cd_converged(pool, ("result",), v3)
    finally
      close_pool!(pool)
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# SQLite: names — a reused explicit name, an explicit rename, a derived name accepts any (#161)
# A changed column set under the SAME explicit name is a drop and a create of one name, so the drop
# must run first. An explicit rename is a drop and a create too (SQLite cannot rename an index). A
# declaration WITHOUT a name matches whatever the live index is called — deriving a name is not
# intent — so it plans nothing.
# ─────────────────────────────────────────────────────────────────────────────
@testset "SQLite: a reused name, an explicit rename, and a derived name that accepts any (#161)" begin
  mktempdir() do dir
    pool = SQLiteConnectionPool(joinpath(dir, "cd_names.sqlite"); pool_size = 1)
    try
      named(cols, name) = _cd_result(constraints = [Models.UniqueConstraint(fields = cols, name = name)])
      _cd_apply!(pool, _cd_plan(pool, LiveTable[], named(("raceid", "driverid"), "result_entry_uq")))

      # Same name, new columns: drop, then create.
      v2 = named(("raceid", "grid"), "result_entry_uq")
      p2 = _cd_plan(pool, _cd_live(pool, "result"), v2)
      @test _cd_keys(p2, :result) == ["Remove composite index: result_entry_uq",
                                      "Create unique constraint: result_entry_uq"]
      _cd_apply!(pool, p2)
      @test !_cd_both_insert(pool, "result", (raceid = 1, driverid = 1, grid = 1), (raceid = 1, driverid = 2, grid = 1))
      @test _cd_converged(pool, ("result",), v2)

      # Same columns, new explicit name: SQLite renames by drop and create.
      v3 = named(("raceid", "grid"), "result_grid_uq")
      p3 = _cd_plan(pool, _cd_live(pool, "result"), v3)
      @test _cd_keys(p3, :result) == ["Remove composite index: result_entry_uq",
                                      "Create unique constraint: result_grid_uq"]
      _cd_apply!(pool, p3)
      @test "result_grid_uq" in _cd_index_names(pool, "result")
      @test _cd_converged(pool, ("result",), v3)

      # No name at all: the live `result_grid_uq` satisfies it. Nothing to plan.
      @test _cd_converged(pool, ("result",), named(("raceid", "grid"), nothing))
    finally
      close_pool!(pool)
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# SQLite: a Django-adopted UNIQUE (a, b) clause (#161)
# Django's `Meta.constraints` renders a table-level `UNIQUE (…)` on SQLite, which the catalog lists
# as an `origin = 'u'` autoindex. Declared, it must be matched rather than duplicated by a second
# index. Undeclared, it can only be removed by rebuilding the table — SQLite cannot drop an autoindex.
# ─────────────────────────────────────────────────────────────────────────────
@testset "SQLite: an adopted UNIQUE (a, b) clause is matched when declared and rebuilt away when not (#161)" begin
  mktempdir() do dir
    pool = SQLiteConnectionPool(joinpath(dir, "cd_adopt.sqlite"); pool_size = 1)
    try
      _cd_create_with_clauses(pool, _cd_result(), "UNIQUE (\"raceid\", \"driverid\")")
      declared = _cd_result(constraints = [Models.UniqueConstraint(fields = ("raceid", "driverid"))])
      @test _cd_converged(pool, ("result",), declared)   # matched: no second index

      undeclared = _cd_result()
      p = _cd_plan(pool, _cd_live(pool, "result"), undeclared)
      @test _cd_keys(p, :result) == ["Alter table: result"]      # a rebuild, and no DROP INDEX
      @test !occursin("DROP INDEX", _cd_text(p, :result))
      _cd_apply!(pool, p)
      @test _cd_both_insert(pool, "result", (raceid = 1, driverid = 1, grid = 1), (raceid = 1, driverid = 1, grid = 2))
      @test _cd_converged(pool, ("result",), undeclared)
    finally
      close_pool!(pool)
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# SQLite: a rebuild for an unrelated column change keeps every declared composite (#161)
# A rebuild re-creates the live BARE indexes from its snapshot and none of the table-level UNIQUE
# clauses. So a declared bare composite survives on its own, a declared UNIQUE (…) clause must be
# re-created as an index after the rebuild, and — the mixed case — one undeclared clause forcing the
# rebuild must not take the declared one down with it.
# ─────────────────────────────────────────────────────────────────────────────
@testset "SQLite: a rebuild keeps the declared composites, however each is backed (#161)" begin
  mktempdir() do dir
    pool = SQLiteConnectionPool(joinpath(dir, "cd_rebuild.sqlite"); pool_size = 1)
    try
      _cd_create_with_clauses(pool, _cd_result(), "UNIQUE (\"raceid\", \"driverid\")",
                              "UNIQUE (\"driverid\", \"grid\")")
      fetch(pool, """CREATE INDEX "result_grid_raceid_ix" ON "result" ("grid", "raceid");""")
      # Declares one clause and the bare index; the second clause is undeclared, AND `grid` becomes
      # NOT NULL with a default — an unrelated column change that forces a rebuild of its own.
      declared = Models.Model("result"; id = Models.IDField(), raceid = Models.IntegerField(),
                              driverid = Models.IntegerField(), grid = Models.IntegerField(default = 0),
                              constraints = [Models.UniqueConstraint(fields = ("raceid", "driverid"))],
                              indexes = [Models.Index(fields = ("grid", "raceid"), name = "result_grid_raceid_ix")])
      p = _cd_plan(pool, _cd_live(pool, "result"), declared)
      @test "Create unique constraint: result_raceid_driverid_uniq" in _cd_keys(p, :result)
      @test !any(startswith("Remove composite index"), _cd_keys(p, :result))
      _cd_apply!(pool, p)
      # re-created: equal on (raceid, driverid) only → refused
      @test !_cd_both_insert(pool, "result", (raceid = 1, driverid = 1, grid = 1), (raceid = 1, driverid = 1, grid = 2))
      # gone: equal on (driverid, grid) only → accepted
      @test _cd_both_insert(pool, "result", (raceid = 1, driverid = 1, grid = 1), (raceid = 2, driverid = 1, grid = 1))
      @test "result_grid_raceid_ix" in _cd_index_names(pool, "result")               # survived
      @test _cd_converged(pool, ("result",), declared)
    finally
      close_pool!(pool)
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# SQLite: renames — a column rename carries its composite, a table rename keeps derived names (#161)
# `RENAME COLUMN` carries the index with it, so the live composite has to be read through the
# rename map or it would look undeclared and be dropped and re-created. A #615 table rename keeps
# `result_raceid_driverid_uniq` under the new table; its declaration derives `race_result_…`, and a
# derived name accepts whatever the live index is called.
# ─────────────────────────────────────────────────────────────────────────────
@testset "SQLite: column and table renames plan no composite statement (#161)" begin
  mktempdir() do dir
    pool = SQLiteConnectionPool(joinpath(dir, "cd_renames.sqlite"); pool_size = 1)
    try
      uq(cols) = [Models.UniqueConstraint(fields = cols)]
      v1 = _cd_result(constraints = uq(("raceid", "driverid")))
      _cd_apply!(pool, _cd_plan(pool, LiveTable[], v1))

      # Column rename driverid → driver_ref (answered "1" at the prompt).
      v2 = Models.Model("result"; id = Models.IDField(), raceid = Models.IntegerField(),
                        driver_ref = Models.IntegerField(), grid = Models.IntegerField(null = true),
                        constraints = uq(("raceid", "driver_ref")))
      p2 = _cd_plan(pool, _cd_live(pool, "result"), v2; answers = "1\n")
      @test !any(k -> occursin("composite", k) || startswith(k, "Create unique constraint"), _cd_keys(p2, :result))
      _cd_apply!(pool, p2)
      @test !_cd_both_insert(pool, "result", (raceid = 1, driver_ref = 1, grid = 1), (raceid = 1, driver_ref = 1, grid = 2))
      @test _cd_converged(pool, ("result",), v2)

      # Table rename result → race_result (answered "no", then the old table's number).
      v3 = Models.Model("race_result"; id = Models.IDField(), raceid = Models.IntegerField(),
                        driver_ref = Models.IntegerField(), grid = Models.IntegerField(null = true),
                        constraints = uq(("raceid", "driver_ref")))
      p3 = _cd_plan(pool, _cd_live(pool, "result"), v3; answers = "no\n1\n")
      @test _cd_keys(p3, :race_result) == ["Rename table"]
      _cd_apply!(pool, p3)
      @test !_cd_both_insert(pool, "race_result", (raceid = 1, driver_ref = 1, grid = 1), (raceid = 1, driver_ref = 1, grid = 2))
      @test _cd_converged(pool, ("race_result",), v3)
    finally
      close_pool!(pool)
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# SQLite: the join-table index, and a db_index whose only cover is being dropped (#161)
# The synthesized ManyToManyField join table's unique index is DECLARED, so the new drop path must not
# propose removing it — including when a Django-adopted join table carries it under Django's name.
# And the `db_index` flush's SQLite probe also sees composite MEMBERS; when the composite covering a
# newly-indexed column is the one being dropped, the column's own index must still be created.
# ─────────────────────────────────────────────────────────────────────────────
@testset "SQLite: the join-table index is kept, and a dropped cover does not swallow a db_index (#161)" begin
  mktempdir() do dir
    pool = SQLiteConnectionPool(joinpath(dir, "cd_join.sqlite"); pool_size = 1)
    try
      join_model() = begin
        m = Models.Model("car_driver"; id = Models.IDField(), car_id = Models.IntegerField(),
                         driver_id = Models.IntegerField())
        m.cache["many_to_many_auto"] = Dict{String, Any}(
          "owner_column" => "car_id", "related_column" => "driver_id",
          "unique_index" => "car_driver_car_id_driver_id_uniq")
        m
      end
      p = _cd_plan(pool, LiveTable[], join_model())
      # Created exactly as it always was — label and statement both.
      @test p[:car_driver]["Create many-to-many unique index"] ==
            """CREATE UNIQUE INDEX IF NOT EXISTS "car_driver_car_id_driver_id_uniq" ON "car_driver" ("car_id", "driver_id");"""
      _cd_apply!(pool, p)
      @test _cd_converged(pool, ("car_driver",), join_model())

      # Adopted under Django's own name: matched by columns, never renamed.
      fetch(pool, "DROP INDEX car_driver_car_id_driver_id_uniq;")
      fetch(pool, "CREATE UNIQUE INDEX car_driver_car_id_driver_id_5a1b2c3d_uniq ON car_driver (car_id, driver_id);")
      @test _cd_converged(pool, ("car_driver",), join_model())

      # A composite over (raceid, driverid) is dropped while `raceid` gains its own db_index.
      _cd_apply!(pool, _cd_plan(pool, LiveTable[], _cd_result(indexes = [Models.Index(fields = ("raceid", "driverid"))])))
      v2 = Models.Model("result"; id = Models.IDField(), raceid = Models.IntegerField(db_index = true),
                        driverid = Models.IntegerField(), grid = Models.IntegerField(null = true))
      p2 = _cd_plan(pool, _cd_live(pool, "result"), v2)
      @test "Remove composite index: result_raceid_driverid_idx" in _cd_keys(p2, :result)
      @test "Create index on raceid" in _cd_keys(p2, :result)
      _cd_apply!(pool, p2)
      @test _cd_converged(pool, ("result",), v2)
    finally
      close_pool!(pool)
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# SQLite: a create collides loudly, and names are checked once per plan (#161)
# Without IF NOT EXISTS a name another object holds fails the migration — here a partial index the
# readers refuse (so the diff never sees it) already owns the derived name. Before, the CREATE was a
# silent no-op and the next makemigrations planned it again, forever. Collisions the plan CAN see —
# two tables declaring one name, SQLite's reserved `sqlite_` prefix — are refused before planning.
# ─────────────────────────────────────────────────────────────────────────────
@testset "SQLite: a name collision fails loudly, and the registry spans the whole plan (#161)" begin
  mktempdir() do dir
    pool = SQLiteConnectionPool(joinpath(dir, "cd_collide.sqlite"); pool_size = 1)
    try
      _cd_apply!(pool, _cd_plan(pool, LiveTable[], _cd_result()))
      fetch(pool, """CREATE INDEX "result_raceid_driverid_uniq" ON "result" ("grid") WHERE "grid" > 0;""")
      p = _cd_plan(pool, _cd_live(pool, "result"),
                   _cd_result(constraints = [Models.UniqueConstraint(fields = ("raceid", "driverid"))]))
      @test_throws Exception _cd_apply!(pool, p)
    finally
      close_pool!(pool)
    end
  end

  shared(table) = Models.Model(table; id = Models.IDField(), a = Models.IntegerField(), b = Models.IntegerField(),
                               indexes = [Models.Index(fields = ("a", "b"), name = "shared_ix")])
  @test_throws PormG.InvalidMigrationError _cd_plan(CD_PG, LiveTable[], shared("pit_stop"), shared("lap_time"))
  reserved = Models.Model("pit_stop"; id = Models.IDField(), a = Models.IntegerField(), b = Models.IntegerField(),
                          constraints = [Models.UniqueConstraint(fields = ("a", "b"), name = "sqlite_mine")])
  mktempdir() do dir
    pool = SQLiteConnectionPool(joinpath(dir, "cd_reserved.sqlite"); pool_size = 1)
    try
      @test_throws PormG.InvalidMigrationError _cd_plan(pool, LiveTable[], reserved)
    finally
      close_pool!(pool)
    end
  end
  @test _cd_plan(CD_PG, LiveTable[], reserved) isa AbstractDict   # PostgreSQL has no such reservation
end

# ─────────────────────────────────────────────────────────────────────────────
# PostgreSQL: the statements a mock can pin (#161)
# Over a hand-built live side (a mock has no catalog): a constraint-backed composite is dropped with
# DROP CONSTRAINT, never DROP INDEX (PostgreSQL refuses to drop an index a constraint owns); an
# explicit rename is ALTER INDEX for a bare index and RENAME CONSTRAINT for a constraint-backed one;
# a composite over a column that is being DROPPED plans nothing, because DROP COLUMN takes it along;
# and a long explicit name compares as PostgreSQL stores it — truncated — so it does not re-plan a
# rename forever.
# ─────────────────────────────────────────────────────────────────────────────
@testset "PostgreSQL: drop, rename, dropped-column and truncation shapes (#161)" begin
  with_live(model, composites...) = begin
    t = live_table(model, CD_PG)
    LiveTable[LiveTable(t.name, t.columns, t.indexes, collect(LiveComposite, composites))]
  end
  base = _cd_result()

  # Undeclared, both backings.
  p = _cd_plan(CD_PG, with_live(base, LiveComposite("result_django_uq", ["raceid", "driverid"], true, true),
                                      LiveComposite("result_grid_ix", ["grid", "raceid"], false, false)), base)
  @test p[:result]["Remove composite index: result_django_uq"] ==
        """ALTER TABLE "result" DROP CONSTRAINT IF EXISTS "result_django_uq";"""
  @test p[:result]["Remove composite index: result_grid_ix"] == """DROP INDEX IF EXISTS "result_grid_ix";"""

  # Explicit renames, both backings.
  renamed = _cd_result(constraints = [Models.UniqueConstraint(fields = ("raceid", "driverid"), name = "result_entry_uq")],
                       indexes = [Models.Index(fields = ("grid", "raceid"), name = "result_grid_ix2")])
  p = _cd_plan(CD_PG, with_live(renamed, LiveComposite("result_django_uq", ["raceid", "driverid"], true, true),
                                         LiveComposite("result_grid_ix", ["grid", "raceid"], false, false)), renamed)
  @test p[:result]["Rename composite index: result_django_uq"] ==
        """ALTER TABLE "result" RENAME CONSTRAINT "result_django_uq" TO "result_entry_uq";"""
  @test p[:result]["Rename composite index: result_grid_ix"] ==
        """ALTER INDEX "result_grid_ix" RENAME TO "result_grid_ix2";"""
  @test length(p[:result]) == 2

  # `driverid` is dropped (interactive = false: no rename): its composite goes with the column.
  shrunk = Models.Model("result"; id = Models.IDField(), raceid = Models.IntegerField(),
                        grid = Models.IntegerField(null = true))
  p = _cd_plan(CD_PG, with_live(base, LiveComposite("result_raceid_driverid_uniq", ["raceid", "driverid"], true, false)), shrunk)
  @test !any(k -> occursin("composite", k), _cd_keys(p, :result))
  @test any(startswith("Remove field"), _cd_keys(p, :result))

  # 70 bytes declared, 63 stored: converged, with the truncation said out loud.
  long = "result_" * repeat("x", 63)
  declared = _cd_result(constraints = [Models.UniqueConstraint(fields = ("raceid", "driverid"), name = long)])
  live = with_live(declared, LiveComposite(first(long, 63), ["raceid", "driverid"], true, false))
  p = @test_logs (:warn, r"63-byte") match_mode = :any _cd_plan(CD_PG, live, declared)
  @test all(isempty, values(p))
  # …and two long DERIVED names that share their first 63 bytes collide as stored.
  wide = Models.Model("result_" * repeat("w", 50); id = Models.IDField(),
                      a_column_with_a_long_name = Models.IntegerField(), b = Models.IntegerField(), c = Models.IntegerField(),
                      indexes = [Models.Index(fields = ("a_column_with_a_long_name", "b")),
                                 Models.Index(fields = ("a_column_with_a_long_name", "c"))])
  @test_throws PormG.InvalidMigrationError Logging.with_logger(Logging.NullLogger()) do
    _cd_plan(CD_PG, LiveTable[], wide)
  end
end
