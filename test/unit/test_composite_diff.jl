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
PostgreSQL half is integration Phase 22.

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
# (a table rename is "<n>\n" or "no\n<n>\n", a column rename "<n>\n"); running out of answers raises
# `InvalidMigrationError` at the next question (#726).
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
      # Its historical step label, and — now that it is diffed on every run — no IF NOT EXISTS: a
      # name something else holds would otherwise no-op and re-plan forever, like any composite.
      @test p[:car_driver]["Create many-to-many unique index"] ==
            """CREATE UNIQUE INDEX "car_driver_car_id_driver_id_uniq" ON "car_driver" ("car_id", "driver_id");"""
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
# Without IF NOT EXISTS a name another object holds fails the migration — here a UNIQUE partial index
# the readers refuse (so the diff never sees it) already owns the derived name. (A plain partial index
# was the fixture until #29 part 2 made it readable; its name clash is now refused at plan time — see
# the expression and partial index testset below.) Before, the CREATE was a
# silent no-op and the next makemigrations planned it again, forever. Collisions the plan CAN see —
# one name created twice on any tables, SQLite's reserved `sqlite_` prefix, a name that differs only
# in case on SQLite (which folds identifiers) — are refused before anything runs.
# ─────────────────────────────────────────────────────────────────────────────
@testset "SQLite: a name collision fails loudly, and the registry spans the whole plan (#161)" begin
  mktempdir() do dir
    pool = SQLiteConnectionPool(joinpath(dir, "cd_collide.sqlite"); pool_size = 1)
    try
      _cd_apply!(pool, _cd_plan(pool, LiveTable[], _cd_result()))
      fetch(pool, """CREATE UNIQUE INDEX "result_raceid_driverid_uniq" ON "result" ("grid") WHERE "grid" > 0;""")
      p = _cd_plan(pool, _cd_live(pool, "result"),
                   _cd_result(constraints = [Models.UniqueConstraint(fields = ("raceid", "driverid"))]))
      # The database's own refusal, naming the index — not some unrelated failure of the harness.
      err = try
        _cd_apply!(pool, p)
        nothing
      catch e
        sprint(showerror, e)
      end
      @test err !== nothing && occursin("result_raceid_driverid_uniq", err) &&
            occursin("already exists", lowercase(err))
    finally
      close_pool!(pool)
    end
  end

  shared(table, name = "shared_ix") = Models.Model(table; id = Models.IDField(), a = Models.IntegerField(),
                                                   b = Models.IntegerField(),
                                                   indexes = [Models.Index(fields = ("a", "b"), name = name)])
  @test_throws PormG.InvalidMigrationError _cd_plan(CD_PG, LiveTable[], shared("pit_stop"), shared("lap_time"))
  reserved = Models.Model("pit_stop"; id = Models.IDField(), a = Models.IntegerField(), b = Models.IntegerField(),
                          constraints = [Models.UniqueConstraint(fields = ("a", "b"), name = "sqlite_mine")])
  mktempdir() do dir
    pool = SQLiteConnectionPool(joinpath(dir, "cd_reserved.sqlite"); pool_size = 1)
    try
      @test_throws PormG.InvalidMigrationError _cd_plan(pool, LiveTable[], reserved)
      # SQLite folds identifier case, so `Pit_ix` and `pit_ix` are ONE name there…
      @test_throws PormG.InvalidMigrationError _cd_plan(pool, LiveTable[], shared("pit_stop", "Pit_ix"),
                                                        shared("lap_time", "pit_ix"))
    finally
      close_pool!(pool)
    end
  end
  @test _cd_plan(CD_PG, LiveTable[], reserved) isa AbstractDict   # PostgreSQL has no such reservation
  # …and two names on PostgreSQL, where PormG quotes every identifier.
  @test _cd_plan(CD_PG, LiveTable[], shared("pit_stop", "Pit_ix"), shared("lap_time", "pit_ix")) isa AbstractDict
end

# ─────────────────────────────────────────────────────────────────────────────
# SQLite: a name one declaration writes is never kept by another (#161)
# The live table has `result_entry_uq` over (raceid, driverid) and `result_grid_uq` over
# (raceid, grid). The models give `result_entry_uq` to (raceid, grid) and leave (raceid, driverid)
# nameless. Matching by columns alone would let the nameless declaration keep `result_entry_uq`,
# and the rename that needs the name would fail with "already exists" on every run. The claimed
# name is dropped instead, so the rename finds it free; the nameless one gets its derived name.
# ─────────────────────────────────────────────────────────────────────────────
@testset "SQLite: a name one declaration writes is never kept by another (#161)" begin
  mktempdir() do dir
    pool = SQLiteConnectionPool(joinpath(dir, "cd_claimed.sqlite"); pool_size = 1)
    try
      v1 = _cd_result(constraints = [Models.UniqueConstraint(fields = ("raceid", "driverid"), name = "result_entry_uq"),
                                     Models.UniqueConstraint(fields = ("raceid", "grid"), name = "result_grid_uq")])
      _cd_apply!(pool, _cd_plan(pool, LiveTable[], v1))
      v2 = _cd_result(constraints = [Models.UniqueConstraint(fields = ("raceid", "driverid")),
                                     Models.UniqueConstraint(fields = ("raceid", "grid"), name = "result_entry_uq")])
      p = _cd_plan(pool, _cd_live(pool, "result"), v2)
      _cd_apply!(pool, p)                                      # no "already exists"
      names = _cd_index_names(pool, "result")
      @test "result_entry_uq" in names && "result_raceid_driverid_uniq" in names && !("result_grid_uq" in names)
      # Both rules still hold, each under its declared name.
      @test !_cd_both_insert(pool, "result", (raceid = 1, driverid = 1, grid = 1), (raceid = 1, driverid = 1, grid = 2))
      @test !_cd_both_insert(pool, "result", (raceid = 1, driverid = 1, grid = 1), (raceid = 1, driverid = 2, grid = 1))
      @test _cd_converged(pool, ("result",), v2)
    finally
      close_pool!(pool)
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# PostgreSQL: a name another table's index holds is refused at plan time (#161)
# Every composite DROP, RENAME and unique CREATE shares one execution bucket in TABLE order, so a
# name moved from one table to another would fail mid-migration on some orders and not others. The
# plan refuses it and says to take two migrations. A table the plan drops entirely is exempt — its
# DROP TABLE runs first — and a name only DECLARED, never created, claims nothing: two long derived
# names that collide as stored are fine while both already exist under other names.
# ─────────────────────────────────────────────────────────────────────────────
@testset "PostgreSQL: a name held on another table is refused; one never created claims nothing (#161)" begin
  pit(; kw...) = Models.Model("pit_stop"; id = Models.IDField(), a = Models.IntegerField(), b = Models.IntegerField(), kw...)
  lap(; kw...) = Models.Model("lap_time"; id = Models.IDField(), a = Models.IntegerField(), b = Models.IntegerField(), kw...)
  live_with(model, composites...) = begin
    t = live_table(model, CD_PG)
    LiveTable(t.name, t.columns, t.indexes, collect(LiveComposite, composites), t.checks)
  end
  held = LiveComposite("stint_uq", ["a", "b"], true, false)

  # `lap_time` still holds `stint_uq` (undeclared, so dropped in this very plan); `pit_stop` creates it.
  err = try
    _cd_plan(CD_PG, LiveTable[live_with(lap(), held), live_with(pit())], lap(),
             pit(constraints = [Models.UniqueConstraint(fields = ("a", "b"), name = "stint_uq")]))
    nothing
  catch e
    e
  end
  @test err isa PormG.InvalidMigrationError && occursin("lap_time", err.msg) && occursin("stint_uq", err.msg)

  # Exempt: `lap_time` is dropped as a table, and DROP TABLE runs before every index statement.
  p = _cd_plan(CD_PG, LiveTable[live_with(lap(), held), live_with(pit())],
               pit(constraints = [Models.UniqueConstraint(fields = ("a", "b"), name = "stint_uq")]))
  @test haskey(p[:lap_time], "Drop table")
  @test haskey(p[:pit_stop], "Create unique constraint: stint_uq")

  # Never created, never claimed: both long derived names already exist under Django's own names.
  wide = Models.Model("result_" * repeat("w", 50); id = Models.IDField(),
                      a_column_with_a_long_name = Models.IntegerField(), b = Models.IntegerField(), c = Models.IntegerField(),
                      indexes = [Models.Index(fields = ("a_column_with_a_long_name", "b")),
                                 Models.Index(fields = ("a_column_with_a_long_name", "c"))])
  adopted = live_with(wide, LiveComposite("django_idx_1", ["a_column_with_a_long_name", "b"], false, false),
                            LiveComposite("django_idx_2", ["a_column_with_a_long_name", "c"], false, false))
  @test all(isempty, values(_cd_plan(CD_PG, LiveTable[adopted], wide)))
  # …while CREATING both still collides as stored.
  @test_throws PormG.InvalidMigrationError Logging.with_logger(Logging.NullLogger()) do
    _cd_plan(CD_PG, LiveTable[], wide)
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# PostgreSQL: a name an index KEPT on the same table holds is refused at plan time (#161)
# The cross-table check exempts a table's own indexes, trusting its pass to drop them first. An index
# kept because it matched its own declaration by name is not dropped, so a second declaration
# claiming that name would plan a CREATE that fails "already exists" on every run. Two shapes: an
# explicit name reused by a new declaration, and an explicit name equal to a live sibling's derived
# one. Found in the delta review — the registry that replaced the pre-plan check had lost them.
# ─────────────────────────────────────────────────────────────────────────────
@testset "PostgreSQL: a new declaration cannot take a name a kept index holds (#161)" begin
  live_with(model, composites...) = begin
    t = live_table(model, CD_PG)
    LiveTable[LiveTable(t.name, t.columns, t.indexes, collect(LiveComposite, composites), t.checks)]
  end
  refused(live, declared) = try
    _cd_plan(CD_PG, live, declared)
    nothing
  catch e
    e
  end

  # `result_entry_uq` over (raceid, grid) is declared and live; a new Index claims the same name.
  reused = _cd_result(constraints = [Models.UniqueConstraint(fields = ("raceid", "grid"), name = "result_entry_uq")],
                      indexes = [Models.Index(fields = ("driverid", "grid"), name = "result_entry_uq")])
  err = refused(live_with(reused, LiveComposite("result_entry_uq", ["raceid", "grid"], true, false)), reused)
  @test err isa PormG.InvalidMigrationError && occursin("result_entry_uq", err.msg) && occursin("raceid, grid", err.msg)

  # A nameless sibling is live under its derived name, which a new declaration writes explicitly.
  derived = _cd_result(constraints = [Models.UniqueConstraint(fields = ("raceid", "driverid"))],
                       indexes = [Models.Index(fields = ("driverid", "grid"), name = "result_raceid_driverid_uniq")])
  err = refused(live_with(derived, LiveComposite("result_raceid_driverid_uniq", ["raceid", "driverid"], true, false)), derived)
  @test err isa PormG.InvalidMigrationError && occursin("result_raceid_driverid_uniq", err.msg)

  # Control: the same live index DROPPED (undeclared) frees the name, so the create is planned.
  freed = _cd_result(indexes = [Models.Index(fields = ("driverid", "grid"), name = "result_entry_uq")])
  p = _cd_plan(CD_PG, live_with(freed, LiveComposite("result_entry_uq", ["raceid", "grid"], true, false)), freed)
  @test _cd_keys(p, :result) == ["Remove composite index: result_entry_uq", "Create index: result_entry_uq"]
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
    LiveTable[LiveTable(t.name, t.columns, t.indexes, collect(LiveComposite, composites), t.checks)]
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

  # 70 bytes declared, 63 stored: converged — compared as stored, so no rename is re-planned…
  long = "result_" * repeat("x", 63)
  declared = _cd_result(constraints = [Models.UniqueConstraint(fields = ("raceid", "driverid"), name = long)])
  live = with_live(declared, LiveComposite(first(long, 63), ["raceid", "driverid"], true, false))
  @test all(isempty, values(_cd_plan(CD_PG, live, declared)))
  # …and creating it says out loud that it will be stored truncated.
  @test_logs (:warn, r"63-byte") match_mode = :any _cd_plan(CD_PG, LiveTable[], declared)
end

# ─────────────────────────────────────────────────────────────────────────────
# SQLite: a descending Index is PormG's by its marker; a hand-made one never is (#29)
# The ownership rule end to end. A declared `-grid` index is created with `/* pormg:index */` in its
# column list and converges. A hand-made DESC index beside it — what an adopted Django schema carries
# — is read, but carries no marker, so it is never planned away; declaring it adopts it without a
# statement (SQLite cannot comment an index, and a drop-and-create would make the first plan after
# inspectdb destructive). Undeclaring PormG's own is a destructive drop. Flipping a direction is the
# drop of one derived name and the create of another. A create that wants a hand-made index's name is
# refused at plan time — `migrate` would otherwise fail with "already exists" on every run. And the
# marked index survives a table rebuild, marker included, and still converges after it.
# Mutation gate: make `composite_is_owned` return true and the hand-made indexes are planned for
# removal; drop the `unowned` name check and the clash plans a CREATE SQLite refuses.
# ─────────────────────────────────────────────────────────────────────────────
@testset "SQLite: a descending Index is PormG's by its marker; a hand-made one never is (#29)" begin
  mktempdir() do dir
    pool = SQLiteConnectionPool(joinpath(dir, "cd_desc29.sqlite"); pool_size = 1)
    try
      v1 = _cd_result()
      _cd_apply!(pool, _cd_plan(pool, LiveTable[], v1))

      v2 = _cd_result(indexes = [Models.Index(fields = ("raceid", "-grid"))])
      p2 = _cd_plan(pool, _cd_live(pool, "result"), v2)
      @test _cd_keys(p2, :result) == ["Create index: result_raceid_grid_desc_idx"]
      @test p2[:result]["Create index: result_raceid_grid_desc_idx"] ==
            "CREATE INDEX \"result_raceid_grid_desc_idx\" ON \"result\" (\"raceid\", \"grid\" DESC /* pormg:index */);"
      _cd_apply!(pool, p2)
      @test _cd_converged(pool, ("result",), v2)

      # Hand-made, unmarked: a one-column DESC index and a composite one. Read, never planned away.
      fetch(pool, "CREATE INDEX hand_grid_desc ON result(grid DESC);")
      fetch(pool, "CREATE INDEX hand_driver_desc ON result(driverid DESC, raceid);")
      live = only(_cd_live(pool, "result"))
      byname = Dict(c.name => c for c in live.composites)
      @test byname["result_raceid_grid_desc_idx"].marker == PormG.INDEX_MARKER
      @test byname["hand_grid_desc"].marker === nothing
      @test _cd_converged(pool, ("result",), v2)

      # Declaring a hand-made one adopts it — by shape, whatever it is called — and plans nothing.
      adopt = _cd_result(indexes = [Models.Index(fields = ("raceid", "-grid")),
                                    Models.Index(fields = ("-driverid", "raceid"), name = "hand_driver_desc")])
      @test _cd_converged(pool, ("result",), adopt)

      # A declaration that wants a hand-made index's NAME for another shape is refused at plan time.
      clash = _cd_result(indexes = [Models.Index(fields = ("raceid", "-grid")),
                                    Models.Index(fields = ("grid", "driverid"), name = "hand_grid_desc")])
      err = try; _cd_plan(pool, _cd_live(pool, "result"), clash); nothing; catch e; e; end
      @test err isa PormG.InvalidMigrationError
      @test occursin("hand_grid_desc", err.msg) && occursin("does not own", err.msg)

      # Flipping the direction: drop one derived name, create the other.
      v3 = _cd_result(indexes = [Models.Index(fields = ("raceid", "grid"))])
      p3 = _cd_plan(pool, _cd_live(pool, "result"), v3)
      @test _cd_keys(p3, :result) == ["Remove composite index: result_raceid_grid_desc_idx",
                                      "Create index: result_raceid_grid_idx"]
      @test !occursin("pormg:index", p3[:result]["Create index: result_raceid_grid_idx"])   # plain: no marker
      _cd_apply!(pool, p3)
      @test _cd_converged(pool, ("result",), v3)

      # Undeclaring PormG's own DESC index is a destructive drop; the hand-made ones stay.
      v4 = _cd_result(indexes = [Models.Index(fields = ("raceid", "-grid"))])
      _cd_apply!(pool, _cd_plan(pool, _cd_live(pool, "result"), v4))
      p5 = _cd_plan(pool, _cd_live(pool, "result"), v1)
      @test sort(_cd_keys(p5, :result)) == ["Remove composite index: result_raceid_grid_desc_idx"]
      @test is_destructive(p5[:result]["Remove composite index: result_raceid_grid_desc_idx"])
      _cd_apply!(pool, p5)
      @test issubset(["hand_grid_desc", "hand_driver_desc"], _cd_index_names(pool, "result"))
      @test _cd_converged(pool, ("result",), v1)

      # A rebuild (a column change) re-creates the marked index verbatim — marker included — and the
      # table converges after it, with the hand-made ones still there and still unmarked.
      _cd_apply!(pool, _cd_plan(pool, _cd_live(pool, "result"), v4))
      v6 = Models.Model("result"; id = Models.IDField(), raceid = Models.IntegerField(),
                        driverid = Models.IntegerField(), grid = Models.IntegerField(null = true),
                        laps = Models.IntegerField(null = true), indexes = [Models.Index(fields = ("raceid", "-grid"))])
      v7 = Models.Model("result"; id = Models.IDField(), raceid = Models.IntegerField(),
                        driverid = Models.IntegerField(), grid = Models.IntegerField(),
                        laps = Models.IntegerField(null = true), indexes = [Models.Index(fields = ("raceid", "-grid"))])
      _cd_apply!(pool, _cd_plan(pool, _cd_live(pool, "result"), v6))
      p7 = _cd_plan(pool, _cd_live(pool, "result"), v7)          # NULL → NOT NULL: a rebuild
      @test any(startswith("Alter"), _cd_keys(p7, :result))
      _cd_apply!(pool, p7)
      ddl = DataFrame(fetch(pool, "SELECT sql FROM sqlite_master WHERE name = 'result_raceid_grid_desc_idx';"))
      @test occursin("/* pormg:index */", string(ddl[1, :sql]))
      @test issubset(["hand_grid_desc", "hand_driver_desc"], _cd_index_names(pool, "result"))
      @test _cd_converged(pool, ("result",), v7)
    finally
      close_pool!(pool)
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# SQLite: inspectdb keeps a hand-made index hand-made (#29)
# A model READ from the database carries each advanced index's live ownership beside its
# declaration (`cache["composite_index_owners"]`). Read back as a live table — the model-vector plan
# entry point every older test uses — a hand-made DESC index must stay unowned, or the first plan
# after inspectdb that drops the declaration would drop an index PormG never made.
# Mutation gate: delete the `composite_index_owners` lookup in `live_table` and the plan below holds a
# `Remove composite index`.
# ─────────────────────────────────────────────────────────────────────────────
@testset "SQLite: inspectdb keeps a hand-made index hand-made (#29)" begin
  mktempdir() do dir
    pool = SQLiteConnectionPool(joinpath(dir, "cd_owners29.sqlite"); pool_size = 1)
    try
      _cd_apply!(pool, _cd_plan(pool, LiveTable[], _cd_result()))
      fetch(pool, "CREATE INDEX hand_grid_desc ON result(grid DESC);")
      read_back = only(m for m in Migrations.convert_schema_to_models(pool) if lowercase(string(m.name)) == "result")
      @test read_back.cache["composite_index_owners"]["hand_grid_desc"] == (nothing, nothing)
      lc = only(c for c in live_table(read_back, pool).composites if c.name == "hand_grid_desc")
      @test lc.marker === nothing && !Migrations.composite_is_owned(lc)
      # The model-vector entry point, a declaration that no longer names it: nothing planned.
      p = get_migration_plan(PormGModel[read_back], _cd_schema(_cd_result()), pool, _cd_settings(); interactive = false)
      @test !any(k -> occursin("hand_grid_desc", k), _cd_keys(p, :result))
    finally
      close_pool!(pool)
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# PostgreSQL: method, opclasses and ownership over a hand-built live side (#29)
# Plan shape only — a mock has no catalog; the live half is test_importers_introspection.jl. A
# hand-made GIN index the model declares is ADOPTED: a COMMENT ON INDEX that appends the marker to the
# DBA's comment rather than replacing it. Undeclared, a marked index is dropped and an unmarked one is
# not. A declaration naming the default class explicitly matches a live index built with it, so it
# converges. Changing the method is a drop and a create.
# Mutation gate: drop the `adopts` loop and the adoption step vanishes; compare opclasses by
# `opclass_default` alone and the explicit `jsonb_ops` declaration re-plans forever.
# ─────────────────────────────────────────────────────────────────────────────
@testset "PostgreSQL: method, opclasses and ownership over a hand-built live side (#29)" begin
  with_live(model, composites...) = begin
    t = live_table(model, CD_PG)
    LiveTable[LiveTable(t.name, t.columns, t.indexes, collect(LiveComposite, composites), t.checks)]
  end
  gin(name, opc, dflt; marker = nothing, comment = marker) =
    LiveComposite(name, ["driverid"], false, false, "gin", [false], Union{String, Nothing}[opc], [dflt], marker, comment)
  base = _cd_result()

  # Adoption keeps a DBA's comment and appends the marker; a rename after it carries the comment along.
  declared = _cd_result(indexes = [Models.Index(fields = ("driverid",), method = "gin")])
  p = _cd_plan(CD_PG, with_live(declared, gin("result_driver_gin", "jsonb_ops", true; comment = "built by ops, 2026")), declared)
  @test _cd_keys(p, :result) == ["Adopt index: result_driver_gin"]
  @test p[:result]["Adopt index: result_driver_gin"] ==
        """COMMENT ON INDEX "result_driver_gin" IS 'built by ops, 2026 pormg:index';"""
  named = _cd_result(indexes = [Models.Index(fields = ("driverid",), method = "gin", name = "result_driverid_gin2")])
  p = _cd_plan(CD_PG, with_live(named, gin("result_driver_gin", "jsonb_ops", true)), named)
  @test _cd_keys(p, :result) == ["Adopt index: result_driver_gin", "Rename composite index: result_driver_gin"]
  # A quote in the kept comment is doubled, never closes the literal.
  p = _cd_plan(CD_PG, with_live(declared, gin("result_driver_gin", "jsonb_ops", true; comment = "ops' note")), declared)
  @test p[:result]["Adopt index: result_driver_gin"] == """COMMENT ON INDEX "result_driver_gin" IS 'ops'' note pormg:index';"""
  # An index PormG already marked is not adopted again.
  @test all(isempty, values(_cd_plan(CD_PG, with_live(declared, gin("result_driver_gin", "jsonb_ops", true; marker = "pormg:index")), declared)))

  # Undeclared: the marked one is dropped, the hand-made one is not.
  p = _cd_plan(CD_PG, with_live(base, gin("result_mine", "jsonb_ops", true; marker = "pormg:index"),
                                      gin("result_theirs", "jsonb_ops", true)), base)
  @test _cd_keys(p, :result) == ["Remove composite index: result_mine"]

  # An explicit default class matches a live index built with that class: converged.
  explicit = _cd_result(indexes = [Models.Index(fields = ("driverid",), method = "gin", opclasses = ("jsonb_ops",), name = "result_driver_gin")])
  @test all(isempty, values(_cd_plan(CD_PG, with_live(explicit, gin("result_driver_gin", "jsonb_ops", true; marker = "pormg:index")), explicit)))
  # …and a different named class does not.
  path = _cd_result(indexes = [Models.Index(fields = ("driverid",), method = "gin", opclasses = ("jsonb_path_ops",), name = "result_driver_gin")])
  p = _cd_plan(CD_PG, with_live(path, gin("result_driver_gin", "jsonb_ops", true; marker = "pormg:index")), path)
  @test _cd_keys(p, :result) == ["Remove composite index: result_driver_gin", "Create index: result_driver_gin"]
  @test occursin("USING gin (\"driverid\" jsonb_path_ops)", p[:result]["Create index: result_driver_gin"])

  # Changing the method: the derived names differ, so it is a drop of one and a create of the other.
  brin = _cd_result(indexes = [Models.Index(fields = ("driverid",), method = "brin")])
  p = _cd_plan(CD_PG, with_live(brin, gin("result_driverid_gin_idx", "jsonb_ops", true; marker = "pormg:index")), brin)
  @test _cd_keys(p, :result) == ["Remove composite index: result_driverid_gin_idx", "Create index: result_driverid_brin_idx"]

  # A hand-made index's name cannot be taken by a different declaration.
  taker = _cd_result(indexes = [Models.Index(fields = ("raceid", "grid"), name = "result_theirs")])
  err = try; _cd_plan(CD_PG, with_live(taker, gin("result_theirs", "jsonb_ops", true)), taker); nothing; catch e; e; end
  @test err isa PormG.InvalidMigrationError && occursin("does not own", err.msg)
end

# ─────────────────────────────────────────────────────────────────────────────
# SQLite: expression and partial indexes are PormG's by their hashed marker (#29 part 2)
# A functional index and a partial one, end to end on a real database. Each is created under the
# hashed marker `pormg:index:<hash>` of its declared TEXT, reads back with that text and converges.
# Changing a condition's text is a drop and a create (destructive); a plain declaration over the same
# columns does not claim a partial index. A hand-made functional+partial index is read, never planned
# away, and declaring it under its own text adopts it with no statement; declaring its name for other
# text is refused with the declaration that would adopt it, ready to paste. A column a declared
# expression names cannot be renamed or removed under it; with the text updated the rename converges.
# A table rebuild re-creates the marked indexes verbatim and the table still converges.
# Mutation gate: drop `_composite_text_matches` from `composite_shape_matches` and v2 re-plans
# forever; mark hand-made text indexes owned (`composite_is_owned` → true) and `hand_abs` is planned
# away; return early from the index half of `_refuse_stale_check_conditions` and the rename plans.
# ─────────────────────────────────────────────────────────────────────────────
@testset "SQLite: expression and partial indexes are PormG's by their hashed marker (#29 part 2)" begin
  mktempdir() do dir
    pool = SQLiteConnectionPool(joinpath(dir, "cd_text29.sqlite"); pool_size = 1)
    try
      _cd_apply!(pool, _cd_plan(pool, LiveTable[], _cd_result()))
      grid_abs = Models.Index(expressions = ("abs(grid)",), name = "result_grid_abs_idx")
      finishers(cond) = Models.Index(fields = ("raceid", "-grid"), condition = cond, name = "result_finishers_idx")
      v2 = _cd_result(indexes = [grid_abs, finishers("grid IS NOT NULL")])
      p2 = _cd_plan(pool, _cd_live(pool, "result"), v2)
      @test sort(_cd_keys(p2, :result)) == ["Create index: result_finishers_idx", "Create index: result_grid_abs_idx"]
      m_abs = PormG.index_text_marker(["abs(grid)"], nothing)
      m_fin = PormG.index_text_marker(String[], "grid IS NOT NULL")
      @test m_abs != m_fin && startswith(m_abs, "pormg:index:")
      # The marker closes the member list, so a partial index's WHERE follows it.
      @test p2[:result]["Create index: result_grid_abs_idx"] ==
            "CREATE INDEX \"result_grid_abs_idx\" ON \"result\" (abs(grid) /* $(m_abs) */);"
      @test p2[:result]["Create index: result_finishers_idx"] ==
            "CREATE INDEX \"result_finishers_idx\" ON \"result\" (\"raceid\", \"grid\" DESC /* $(m_fin) */) WHERE grid IS NOT NULL;"
      _cd_apply!(pool, p2)

      # Read back: the functional one as text, the partial one as its columns plus the condition.
      byname = Dict(c.name => c for c in only(_cd_live(pool, "result")).composites)
      @test byname["result_grid_abs_idx"].expressions == ["abs(grid)"]
      @test byname["result_grid_abs_idx"].marker == m_abs
      @test byname["result_finishers_idx"].columns == ["raceid", "grid"]
      @test byname["result_finishers_idx"].descending == [false, true]
      @test byname["result_finishers_idx"].condition == "grid IS NOT NULL"
      @test byname["result_finishers_idx"].marker == m_fin
      @test _cd_converged(pool, ("result",), v2)

      # A changed condition is a drop and a create of the one name, and the drop is destructive.
      v3 = _cd_result(indexes = [grid_abs, finishers("grid > 0")])
      p3 = _cd_plan(pool, _cd_live(pool, "result"), v3)
      @test _cd_keys(p3, :result) == ["Remove composite index: result_finishers_idx", "Create index: result_finishers_idx"]
      @test is_destructive(p3[:result]["Remove composite index: result_finishers_idx"])
      _cd_apply!(pool, p3)
      @test _cd_converged(pool, ("result",), v3)

      # A plain declaration over the same columns is a different index: it never claims the partial one.
      plain = _cd_result(indexes = [grid_abs, Models.Index(fields = ("raceid", "-grid"), name = "result_finishers_idx")])
      @test _cd_keys(_cd_plan(pool, _cd_live(pool, "result"), plain), :result) ==
            ["Remove composite index: result_finishers_idx", "Create index: result_finishers_idx"]

      # Hand-made, functional AND partial: read, unmarked, never planned away.
      fetch(pool, "CREATE INDEX hand_abs ON result(abs(driverid)) WHERE grid > 1;")
      hand = only(c for c in only(_cd_live(pool, "result")).composites if c.name == "hand_abs")
      @test hand.expressions == ["abs(driverid)"] && hand.condition == "grid > 1" && hand.marker === nothing
      @test _cd_converged(pool, ("result",), v3)
      # Declared under its own text, it is adopted — on SQLite with no statement at all.
      adopt = _cd_result(indexes = [grid_abs, finishers("grid > 0"),
                                    Models.Index(expressions = ("abs(driverid)",), condition = "grid > 1", name = "hand_abs")])
      @test _cd_converged(pool, ("result",), adopt)
      # Its name for other text is refused, and the message carries the declaration that adopts it.
      clash = _cd_result(indexes = [grid_abs, finishers("grid > 0"),
                                    Models.Index(expressions = ("abs(raceid)",), name = "hand_abs")])
      err = try; _cd_plan(pool, _cd_live(pool, "result"), clash); nothing; catch e; e; end
      @test err isa PormG.InvalidMigrationError
      @test occursin("does not own", err.msg)
      @test occursin("Models.Index(expressions = (\"abs(driverid)\",), condition = \"grid > 1\", name = \"hand_abs\")", err.msg)

      # A column the declared text names cannot be renamed under it, nor removed.
      renamed(text) = Models.Model("result"; id = Models.IDField(), raceid = Models.IntegerField(),
                                   driverid = Models.IntegerField(), start_grid = Models.IntegerField(null = true),
                                   indexes = [Models.Index(expressions = (text,), name = "result_grid_abs_idx")])
      err = try; _cd_plan(pool, _cd_live(pool, "result"), renamed("abs(grid)"); answers = "1\n"); nothing; catch e; e; end
      @test err isa PormG.InvalidMigrationError
      @test occursin("Index 'result_grid_abs_idx'", err.msg) && occursin("still names column 'grid'", err.msg)
      gone = Models.Model("result"; id = Models.IDField(), raceid = Models.IntegerField(), driverid = Models.IntegerField(),
                          indexes = [grid_abs])
      err = try; _cd_plan(pool, _cd_live(pool, "result"), gone); nothing; catch e; e; end
      @test err isa PormG.InvalidMigrationError && occursin("which this migration removes", err.msg)
      # With the text updated, the rename converges in one plan: the old index is re-created.
      fixed = renamed("abs(start_grid)")
      p = _cd_plan(pool, _cd_live(pool, "result"), fixed; answers = "1\n")
      @test "Create index: result_grid_abs_idx" in _cd_keys(p, :result)
      _cd_apply!(pool, p)
      @test _cd_converged(pool, ("result",), fixed)
      @test only(c for c in only(_cd_live(pool, "result")).composites if c.name == "result_grid_abs_idx").expressions ==
            ["abs(start_grid)"]

      # A rebuild (NULL → NOT NULL) re-creates the marked text index verbatim and still converges.
      rebuilt = Models.Model("result"; id = Models.IDField(), raceid = Models.IntegerField(),
                             driverid = Models.IntegerField(), start_grid = Models.IntegerField(),
                             indexes = [Models.Index(expressions = ("abs(start_grid)",), name = "result_grid_abs_idx")])
      p = _cd_plan(pool, _cd_live(pool, "result"), rebuilt)
      @test any(startswith("Alter"), _cd_keys(p, :result))
      _cd_apply!(pool, p)
      @test _cd_converged(pool, ("result",), rebuilt)
    finally
      close_pool!(pool)
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# PostgreSQL: expression and partial indexes over a hand-built live side (#29 part 2)
# Plan shape only — the catalog half (PostgreSQL's rewritten text, `pg_get_indexdef`) is
# test_importers_introspection.jl. The create renders `USING`, the expressions verbatim and the
# `WHERE`, then the hashed marker as the index's comment. A live index whose marker is the hash of the
# declared text converges even though its catalog text differs (`lower(surname::text)`); one whose
# hash is stale is dropped and re-created. A hand-made index declared under its catalog text is
# adopted with the HASHED marker, the DBA's comment kept; renamed, it is `ALTER INDEX`.
# Mutation gate: adopt with the bare `INDEX_MARKER` instead of `composite_marker(d)` and the adoption
# assertion fails; drop the marker half of `_composite_text_matches` and the rewritten-text index
# re-plans forever.
# ─────────────────────────────────────────────────────────────────────────────
@testset "PostgreSQL: expression and partial indexes over a hand-built live side (#29 part 2)" begin
  with_live(model, composites...) = begin
    t = live_table(model, CD_PG)
    LiveTable[LiveTable(t.name, t.columns, t.indexes, collect(LiveComposite, composites), t.checks)]
  end
  text_ix(name, exprs, cond; method = "btree", marker = nothing, comment = marker) =
    LiveComposite(name, String[], false, false, method, Bool[], Union{String, Nothing}[], Bool[], marker, comment;
                  expressions = exprs, condition = cond)
  base = _cd_result()
  decl = Models.Index(expressions = ("abs(grid)",), condition = "grid IS NOT NULL", name = "result_grid_abs_idx",
                      method = "brin")
  declared = _cd_result(indexes = [decl])
  m = PormG.index_text_marker(["abs(grid)"], "grid IS NOT NULL")

  # Created from nothing: USING, the text verbatim, the WHERE, then the hashed marker.
  p = _cd_plan(CD_PG, with_live(base), declared)
  @test p[:result]["Create index: result_grid_abs_idx"] ==
        "CREATE INDEX \"result_grid_abs_idx\" ON \"result\" USING brin (abs(grid)) WHERE grid IS NOT NULL;\n" *
        "COMMENT ON INDEX \"result_grid_abs_idx\" IS '$(m)';"

  # The catalog's rewritten text, under the marker of the declared text: unchanged.
  rewritten = text_ix("result_grid_abs_idx", ["abs(grid)"], "(grid IS NOT NULL)"; method = "brin", marker = m)
  @test all(isempty, values(_cd_plan(CD_PG, with_live(declared, rewritten), declared)))
  odd = text_ix("result_grid_abs_idx", ["abs((grid)::integer)"], "grid IS NOT NULL"; method = "brin", marker = m)
  @test all(isempty, values(_cd_plan(CD_PG, with_live(declared, odd), declared)))
  # A stale hash under the same name: drop, then create.
  stale = text_ix("result_grid_abs_idx", ["abs((grid)::integer)"], "grid > 0"; method = "brin",
                  marker = PormG.index_text_marker(["abs(grid)"], "grid > 0"))
  @test _cd_keys(_cd_plan(CD_PG, with_live(declared, stale), declared), :result) ==
        ["Remove composite index: result_grid_abs_idx", "Create index: result_grid_abs_idx"]
  # Another method is another index, whatever the text says.
  btree = text_ix("result_grid_abs_idx", ["abs(grid)"], "grid IS NOT NULL"; marker = m)
  @test _cd_keys(_cd_plan(CD_PG, with_live(declared, btree), declared), :result) ==
        ["Remove composite index: result_grid_abs_idx", "Create index: result_grid_abs_idx"]

  # Hand-made, declared under its catalog text: adopted with the HASHED marker, the DBA's comment kept.
  hand = text_ix("result_grid_abs_idx", ["abs(grid)"], "(grid IS NOT NULL)"; method = "brin", comment = "ops note")
  p = _cd_plan(CD_PG, with_live(declared, hand), declared)
  @test _cd_keys(p, :result) == ["Adopt index: result_grid_abs_idx"]
  @test p[:result]["Adopt index: result_grid_abs_idx"] == "COMMENT ON INDEX \"result_grid_abs_idx\" IS 'ops note $(m)';"
  # Under a new explicit name it is adopted, then renamed in place.
  moved = _cd_result(indexes = [Models.Index(expressions = ("abs(grid)",), condition = "grid IS NOT NULL",
                                             name = "result_grid_abs_brin", method = "brin")])
  p = _cd_plan(CD_PG, with_live(moved, rewritten), moved)
  @test _cd_keys(p, :result) == ["Rename composite index: result_grid_abs_idx"]
  @test p[:result]["Rename composite index: result_grid_abs_idx"] ==
        "ALTER INDEX \"result_grid_abs_idx\" RENAME TO \"result_grid_abs_brin\";"

  # The refusal's adopting declaration carries a hand-made partial index's operator classes too.
  pattern = LiveComposite("result_hand_part", ["raceid", "driverid"], false, false, "btree", [false, false],
                          Union{String, Nothing}["int4_ops", "int4_minmax_ops"], [true, false], nothing, nothing;
                          condition = "grid > 0")
  taker = _cd_result(indexes = [Models.Index(fields = ("raceid", "grid"), condition = "grid > 1", name = "result_hand_part")])
  err = try; _cd_plan(CD_PG, with_live(taker, pattern), taker); nothing; catch e; e; end
  @test err isa PormG.InvalidMigrationError
  @test occursin("Models.Index(fields = (\"raceid\", \"driverid\",), condition = \"grid > 0\", " *
                 "name = \"result_hand_part\", opclasses = (nothing, \"int4_minmax_ops\",))", err.msg)

  # Undeclared: PormG's is dropped, a hand-made one never is.
  @test _cd_keys(_cd_plan(CD_PG, with_live(base, rewritten), base), :result) == ["Remove composite index: result_grid_abs_idx"]
  @test all(isempty, values(_cd_plan(CD_PG, with_live(base, hand), base)))
end

# ─────────────────────────────────────────────────────────────────────────────
# SQLite: an expression index that SQLite stores as a plain column still reads back as its text (#29 part 2)
# `"(grid)"`, `"grid ASC"` and `"'grid'"` are expressions to the declaration, but SQLite records each
# as the column `grid`. Read as columns, a one-column index of that shape has no `fields` spelling, so
# `inspectdb` declared nothing and the generated model's first plan dropped the index. SQLite keeps
# the DDL verbatim, so an index whose stored members hash to its own marker is read as that text.
# Mutation gate: drop the marker-hash arm from `_sqlite_composite_indexes`' `as_text` and the
# read-back model plans `Remove composite index` for each.
# ─────────────────────────────────────────────────────────────────────────────
@testset "SQLite: an expression index stored as a plain column reads back as its text (#29 part 2)" begin
  for (k, text) in enumerate(("(grid)", "grid ASC", "'grid'"))
    mktempdir() do dir
      pool = SQLiteConnectionPool(joinpath(dir, "cd_plaintext29_$(k).sqlite"); pool_size = 1)
      try
        _cd_apply!(pool, _cd_plan(pool, LiveTable[], _cd_result()))
        declared = _cd_result(indexes = [Models.Index(expressions = (text,), name = "result_grid_text_idx")])
        _cd_apply!(pool, _cd_plan(pool, _cd_live(pool, "result"), declared))
        @test _cd_converged(pool, ("result",), declared)
        lc = only(c for c in only(_cd_live(pool, "result")).composites if c.name == "result_grid_text_idx")
        @test (text, lc.expressions) == (text, [text])
        # inspectdb writes that text back, and its model plans nothing — the index is not dropped.
        read_back = only(m for m in Migrations.convert_schema_to_models(pool) if lowercase(string(m.name)) == "result")
        p = get_migration_plan(_cd_live(pool, "result"), _cd_schema(read_back), pool, _cd_settings(); interactive = false)
        @test (text, _cd_keys(p, :result)) == (text, String[])
      finally
        close_pool!(pool)
      end
    end
  end
end
