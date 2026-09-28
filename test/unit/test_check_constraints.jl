"""
UNIT TESTS: table-level CHECK constraints — `Models.CheckConstraint` in `constraints = [...]` (#742)

Before #742 `constraints =` took only `UniqueConstraint`: a CHECK could not be declared, rendered,
introspected or diffed, and the Django importer dropped `CheckConstraint` outright. Now:

  * `CheckConstraint(condition = "<SQL>", name = "...")` — the condition is SQL over physical
    columns, the name is REQUIRED because it is the identity (PostgreSQL rewrites a stored
    condition's text);
  * PormG stores an ownership MARKER beside each CHECK it creates, `pormg:check:<hash of the
    condition>` — `COMMENT ON CONSTRAINT` on PostgreSQL, an SQL comment inside the clause on SQLite —
    and the planner reads it: same hash (or the same canonical text) is unchanged, another hash is a
    replace, a marked CHECK no declaration names is dropped, an unmarked one is left alone;
  * SQLite adds, changes and drops a CHECK through the table rebuild; PostgreSQL through
    `ALTER TABLE … ADD/DROP/RENAME CONSTRAINT`.

WHAT THIS FILE PROVES. The SQLite testsets apply every plan to a real temp database in `migrate`'s
order, ask the database what it enforces, and re-plan to prove convergence. The PostgreSQL testsets
are plan-shape only, over a stand-in backend and a synthetic live side — the live PostgreSQL half is
in `test/integration/test_importers_introspection.jl`. The review-driven regressions (rebuild timing,
drop ordering, a table rename, `inspectdb`, a stale condition) each have a testset of their own.

`_ck`-prefixed throughout: `runtests.jl` includes every unit file into ONE module.
"""

using Test
using Logging
using DataFrames
using PormG
using PormG.Models
using PormG.Migrations
import PormG: PormGModel, PormGPostgres, PormGSQLite, model_table_name, check_marker
isdefined(Main, :SQLite) || include(joinpath(@__DIR__, "..", "load_drivers.jl"))
import PormG.ConnectionPool: SQLiteConnectionPool, fetch, close_pool!
import PormG.Migrations: LiveTable, LiveCheck, read_live_schema, live_table, get_migration_plan,
                         is_destructive, convert_schema_to_models

# ─────────────────────────────────────────────────────────────────────────────
# Harness
# ─────────────────────────────────────────────────────────────────────────────

# PostgreSQL stand-in: no catalog, so every planner lookup answers "nothing there".
struct CheckMockPg742 <: PormGPostgres end
const CK_PG = CheckMockPg742()
fetch(::CheckMockPg742, sql::String; conn = nothing, params = nothing, ignore_tx::Bool = false) = DataFrame()

# A PostgreSQL stand-in that records every query and answers each with one canned DataFrame.
mutable struct CheckCapturePg742 <: PormGPostgres
  sqls::Vector{String}
  answer::DataFrame
end
# Keyword-only, like the stub above: `ConnectionPool.fetch` forwards a positional `params` here.
fetch(c::CheckCapturePg742, sql::String; conn = nothing, params = nothing, ignore_tx::Bool = false) =
  (push!(c.sqls, sql); c.answer)

function _ck_schema(models::PormGModel...)
  schema = Dict{Symbol, Dict{Symbol, Union{Bool, PormGModel}}}()
  for m in models
    schema[Symbol(model_table_name(m))] = Dict{Symbol, Union{Bool, PormGModel}}(:model => m, :exist => false)
  end
  return schema
end

_ck_settings() = (s = PormG.Configuration.Settings(); s.change_db = true; s)

function _ck_plan(conn, live, declared::PormGModel...; answers::Union{String, Nothing} = nothing)
  schema = _ck_schema(declared...)
  answers === nothing && return get_migration_plan(live, schema, conn, _ck_settings(); interactive = false)
  path, io = mktemp(); write(io, answers); close(io)
  return open(path) do f
    redirect_stdin(f) do
      redirect_stdout(devnull) do
        get_migration_plan(live, schema, conn, _ck_settings(); interactive = true)
      end
    end
  end
end

_ck_live(pool, tables::String...) = read_live_schema(pool; include_table = collect(tables))

# Apply a plan in `migrate`'s order. Naive `;` splitting is safe: DDL over identifiers and conditions
# this file chose, none of which carries a `;`.
function _ck_apply!(pool, plan)
  ordered, _ = Migrations._order_statements(collect(values(plan)))
  for sql in ordered, stmt in split(sql, ";")
    s = strip(stmt)
    isempty(s) || fetch(pool, s * ";")
  end
  return nothing
end

_ck_keys(plan, t::Symbol) = haskey(plan, t) ? collect(keys(plan[t])) : String[]
_ck_text(plan) = join((join(values(steps), "\n") for steps in values(plan)), "\n")
_ck_converged(pool, tables, declared...) = all(isempty, values(_ck_plan(pool, _ck_live(pool, tables...), declared...)))
_ck_sql(pool, table) = String(DataFrame(fetch(pool, "SELECT sql FROM sqlite_master WHERE name = ?;", [table])).sql[1])

# Does the row go in? Asked of the database.
function _ck_inserts(pool, table, row::NamedTuple)
  ok = try
    cols = join(("\"$(k)\"" for k in keys(row)), ", ")
    fetch(pool, "INSERT INTO \"$(table)\" ($(cols)) VALUES ($(join(("?" for _ in row), ", ")));", collect(values(row)))
    true
  catch
    false
  end
  fetch(pool, "DELETE FROM \"$(table)\";")
  return ok
end

# The F1 result shape the testsets share, with the CHECKs under test.
_ck_result(checks...; kw...) = Models.Model("result"; resultid = Models.IDField(), raceid = Models.IntegerField(),
  driverid = Models.IntegerField(), grid = Models.IntegerField(), laps = Models.IntegerField(),
  constraints = collect(checks), kw...)
const CK_GRID = Models.CheckConstraint(condition = "grid >= 0 AND grid <= 40", name = "result_grid_range")
const CK_LAPS = Models.CheckConstraint(condition = "laps >= 0", name = "result_laps_non_negative")

# ─────────────────────────────────────────────────────────────────────────────
# CheckConstraint: construction and model-level validation (#742)
# The name is the identity, so it is required, non-blank and at most 63 bytes (PostgreSQL would
# truncate a longer one and it would never match its declaration again). The condition is SQL, checked
# only for the typos that would silently change the statement it lands in. On the model, names are one
# namespace across both constraint kinds, and a model declaring only CHECKs stores no UniqueConstraint.
# ─────────────────────────────────────────────────────────────────────────────
@testset "CheckConstraint: construction and model-level validation (#742)" begin
  @test CK_GRID.condition == "grid >= 0 AND grid <= 40"
  @test CK_GRID.name == "result_grid_range"

  refused(; kw...) = try Models.CheckConstraint(; kw...); nothing catch e; e end
  @test refused(condition = "grid >= 0") isa PormG.ModelDefinitionError                       # no name
  @test refused(condition = "grid >= 0", name = "  ") isa PormG.ModelDefinitionError           # blank
  @test refused(condition = "grid >= 0", name = "x"^64) isa PormG.ModelDefinitionError         # 64 bytes
  @test refused(condition = "grid >= 0", name = "é"^32) isa PormG.ModelDefinitionError         # 64 BYTES, 32 chars
  @test Models.CheckConstraint(condition = "grid >= 0", name = "x"^63).name == "x"^63
  @test refused(name = "c") isa PormG.ModelDefinitionError                                     # no condition
  # The typos that change the statement silently: a comment, a statement break, an injected clause,
  # an unterminated literal. Each is legal inside a literal.
  for bad in ("grid >= 0 -- all good", "grid >= 0 /* x */", "grid >= 0); DROP TABLE result; (",
              "grid >= 0, CHECK (1 = 1)", "status <> 'x")
    err = refused(condition = bad, name = "c")
    @test err isa PormG.ModelDefinitionError
    @test occursin("not well-formed SQL", sprint(showerror, err))
  end
  @test Models.CheckConstraint(condition = "status IN ('a;b', 'c,d')", name = "c").condition == "status IN ('a;b', 'c,d')"

  # One object, or a mixed collection; each kind lands under its own cache key.
  m = _ck_result(CK_GRID)
  @test Models.declared_check_constraints(m) == [CK_GRID]
  @test !haskey(m.cache, "unique_constraints")
  mixed = _ck_result(Models.UniqueConstraint(fields = ("raceid", "driverid")), CK_GRID, CK_LAPS)
  @test Models.declared_check_constraints(mixed) == [CK_GRID, CK_LAPS]
  @test length(mixed.cache["unique_constraints"]["constraints"]) == 1
  single = Models.Model("result"; resultid = Models.IDField(), grid = Models.IntegerField(), constraints = CK_GRID)
  @test Models.declared_check_constraints(single) == [CK_GRID]

  # One namespace per model, whichever kind comes first.
  dup(cs...) = try _ck_result(cs...); nothing catch e; e end
  @test dup(CK_GRID, Models.CheckConstraint(condition = "laps >= 0", name = "result_grid_range")) isa PormG.ModelDefinitionError
  @test dup(Models.UniqueConstraint(fields = ("raceid",), name = "result_grid_range"), CK_GRID) isa PormG.ModelDefinitionError
  # Anything else in the list names both accepted types.
  err = dup(Models.Index(fields = ("raceid", "driverid")))
  @test err isa PormG.ModelDefinitionError
  @test occursin("UniqueConstraint or CheckConstraint", sprint(showerror, err))
end

# ─────────────────────────────────────────────────────────────────────────────
# CheckConstraint: Model_to_str writes one constraints list, and it reloads (#742)
# A second `constraints =` keyword would not parse, so both kinds share one list — and a model that
# declares only CHECKs still gets one. The condition is emitted verbatim and escaped: a quoted
# identifier and a `$` must survive the round trip unchanged.
# ─────────────────────────────────────────────────────────────────────────────
@testset "CheckConstraint: Model_to_str writes one constraints list, and it reloads (#742)" begin
  quoted = Models.CheckConstraint(condition = "\"grid\" >= 0 AND positiontext <> '\$'", name = "result_grid_quoted")
  m = _ck_result(Models.UniqueConstraint(fields = ("raceid", "driverid")), CK_GRID, quoted)
  src = Models.Model_to_str(m)
  @test count("constraints =", src) == 1
  @test occursin("Models.CheckConstraint(condition = \"grid >= 0 AND grid <= 40\", name = \"result_grid_range\")", src)
  mod = Module()
  Core.eval(mod, :(import PormG.Models))
  back = Core.eval(mod, Meta.parse(src))
  @test Models.declared_check_constraints(back) == [CK_GRID, quoted]
  @test length(back.cache["unique_constraints"]["constraints"]) == 1

  only_checks = Models.Model_to_str(_ck_result(CK_LAPS))
  @test occursin("constraints = [Models.CheckConstraint(condition = \"laps >= 0\", name = \"result_laps_non_negative\")]", only_checks)
  @test !haskey(Core.eval(mod, Meta.parse(only_checks)).cache, "unique_constraints")
end

# ─────────────────────────────────────────────────────────────────────────────
# Rendering: SQLite inlines the clause with its marker; PostgreSQL adds it and comments it (#742)
# The marker is `pormg:check:` plus the first 16 hex digits of the SHA-256 of the canonical condition
# — insensitive to surrounding whitespace and outer parentheses, sensitive to anything else.
# ─────────────────────────────────────────────────────────────────────────────
@testset "Rendering: SQLite inlines the clause with its marker; PostgreSQL adds it and comments it (#742)" begin
  h = check_marker("grid >= 0 AND grid <= 40")
  @test occursin(r"^pormg:check:[0-9a-f]{16}$", h)
  @test check_marker("  (grid >= 0 AND grid <= 40)  ") == h
  @test check_marker("grid >= 0 AND grid <= 41") != h

  mktempdir() do dir
    pool = SQLiteConnectionPool(joinpath(dir, "ck_render.sqlite"); pool_size = 1)
    try
      m = _ck_result(CK_GRID)
      clause = "CONSTRAINT \"result_grid_range\" CHECK (grid >= 0 AND grid <= 40 /* $(h) */)"
      @test occursin(clause, PormG.Dialect.create_table(pool, m))
      @test occursin(clause, PormG.Dialect.rebuild_table(pool, m))
      # A model with no CHECK renders exactly as before.
      @test !occursin("CONSTRAINT", PormG.Dialect.create_table(pool, _ck_result()))
      # `migrate` splits a rebuild with `_split_sqlite_statements`, which reads SQLite's lexical rules:
      # the marker is a comment, so no `;`-like character inside it can cut the CREATE in two.
      stmts = Migrations._split_sqlite_statements(PormG.Dialect.rebuild_table(pool, m))
      @test count(st -> occursin("CREATE TABLE", st), stmts) == 1
      @test occursin(clause, only(filter(st -> occursin("CREATE TABLE", st), stmts)))
    finally
      close_pool!(pool)
    end
  end

  @test PormG.Dialect.add_check_constraint(CK_PG, "result", CK_GRID) ==
        "ALTER TABLE \"result\" ADD CONSTRAINT \"result_grid_range\" CHECK (grid >= 0 AND grid <= 40);\n" *
        "COMMENT ON CONSTRAINT \"result_grid_range\" ON \"result\" IS '$(h)';"
  @test PormG.Dialect.drop_check_constraint(CK_PG, "result", "result_grid_range") ==
        "ALTER TABLE \"result\" DROP CONSTRAINT IF EXISTS \"result_grid_range\";"
end

# ─────────────────────────────────────────────────────────────────────────────
# SQLite: a CHECK is created, added, changed and dropped — and enforced (#742)
# The core lifecycle on a real database. A new table renders its CHECK inline, and that plan is not
# destructive. On the existing table, each change is a rebuild (SQLite has no ALTER … CONSTRAINT),
# which `migrate` treats as destructive; after each step the database is asked whether the condition
# holds, and a re-plan must be empty.
# ─────────────────────────────────────────────────────────────────────────────
@testset "SQLite: a CHECK is created, added, changed and dropped — and enforced (#742)" begin
  mktempdir() do dir
    pool = SQLiteConnectionPool(joinpath(dir, "ck_life.sqlite"); pool_size = 1)
    try
      row(grid, laps) = (raceid = 1, driverid = 1, grid = grid, laps = laps)

      # Created with the table: inline, and not destructive.
      v1 = _ck_result(CK_LAPS)
      p1 = _ck_plan(pool, LiveTable[], v1)
      @test _ck_keys(p1, :result) == ["New model"]
      @test !any(is_destructive, values(p1[:result]))
      _ck_apply!(pool, p1)
      @test !_ck_inserts(pool, "result", row(1, -1))
      @test _ck_converged(pool, ("result",), v1)
      live = only(_ck_live(pool, "result"))
      @test [(c.name, c.sql, c.marker) for c in live.checks] ==
            [("result_laps_non_negative", "laps >= 0", check_marker("laps >= 0"))]

      # Added to the existing table: a rebuild.
      v2 = _ck_result(CK_LAPS, CK_GRID)
      p2 = _ck_plan(pool, _ck_live(pool, "result"), v2)
      @test _ck_keys(p2, :result) == ["Alter table: result"]
      @test is_destructive(p2[:result]["Alter table: result"])
      _ck_apply!(pool, p2)
      @test !_ck_inserts(pool, "result", row(41, 1))
      @test _ck_inserts(pool, "result", row(40, 1))
      @test _ck_converged(pool, ("result",), v2)

      # Changed under the same name: the marker no longer matches, so the rebuild replaces it.
      v3 = _ck_result(CK_LAPS, Models.CheckConstraint(condition = "grid >= 1 AND grid <= 30", name = "result_grid_range"))
      p3 = _ck_plan(pool, _ck_live(pool, "result"), v3)
      @test _ck_keys(p3, :result) == ["Alter table: result"]
      _ck_apply!(pool, p3)
      @test !_ck_inserts(pool, "result", row(31, 1))
      @test !_ck_inserts(pool, "result", row(0, 1))
      @test _ck_converged(pool, ("result",), v3)

      # No longer declared: it carries PormG's marker, so it is PormG's to drop.
      v4 = _ck_result(CK_LAPS)
      p4 = _ck_plan(pool, _ck_live(pool, "result"), v4)
      @test _ck_keys(p4, :result) == ["Alter table: result"]
      _ck_apply!(pool, p4)
      @test _ck_inserts(pool, "result", row(99, 1))
      @test !occursin("result_grid_range", _ck_sql(pool, "result"))
      @test _ck_converged(pool, ("result",), v4)
    finally
      close_pool!(pool)
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# SQLite: rows that violate a new CHECK fail the migration loudly (#742)
# The rebuild copies every row into the new table, which carries the CHECK — so a row that breaks it
# stops the copy instead of being dropped or kept silently.
# ─────────────────────────────────────────────────────────────────────────────
@testset "SQLite: rows that violate a new CHECK fail the migration loudly (#742)" begin
  mktempdir() do dir
    pool = SQLiteConnectionPool(joinpath(dir, "ck_violate.sqlite"); pool_size = 1)
    try
      _ck_apply!(pool, _ck_plan(pool, LiveTable[], _ck_result()))
      fetch(pool, "INSERT INTO \"result\" (\"raceid\", \"driverid\", \"grid\", \"laps\") VALUES (1, 1, 50, 3);")
      plan = _ck_plan(pool, _ck_live(pool, "result"), _ck_result(CK_GRID))
      err = try _ck_apply!(pool, plan); nothing catch e; e end
      @test err !== nothing
      @test occursin("CHECK constraint failed", sprint(showerror, err))
    finally
      close_pool!(pool)
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# SQLite: hand-written CHECKs are never planned away, adopted when declared, warned about on a rebuild
# A CHECK with no marker was not created by PormG: undeclared, the planner leaves it alone. Declared
# under its own name with the same text, it is adopted as it stands. Declared with a different text,
# the declaration replaces it — and the rebuild's "clauses no model can express" warning leaves it out,
# because it is not lost. Any OTHER hand-written CHECK is dropped by a rebuild, as it always has been,
# and the warning names it (the maintainer's call for SQLite, 2026-09-26). Neither condition may read
# like PormG's own `>= 0`: the warning skips that shape as a column fact, which would hide the case.
# ─────────────────────────────────────────────────────────────────────────────
@testset "SQLite: hand-written CHECKs are never planned away, adopted when declared, warned about on a rebuild (#742)" begin
  mktempdir() do dir
    pool = SQLiteConnectionPool(joinpath(dir, "ck_hand.sqlite"); pool_size = 1)
    try
      sql = PormG.Dialect.create_table(pool, _ck_result())
      cut = findlast(')', sql)
      fetch(pool, replace(sql[1:prevind(sql, cut)], "\"grid\" INTEGER NOT NULL" =>
                          "\"grid\" INTEGER NOT NULL CONSTRAINT \"result_grid_col\" CHECK (grid < 90)") *
                  ",\n  CONSTRAINT \"result_laps_hand\" CHECK (laps < 500),\n" *
                  "  CONSTRAINT \"result_driver_hand\" CHECK (driverid > 0)\n" * sql[cut:end])
      live = only(_ck_live(pool, "result"))
      # Named CHECKs are read wherever they sit — on the table, or inside a column definition.
      @test Set((c.name, c.marker) for c in live.checks) ==
            Set([("result_laps_hand", nothing), ("result_driver_hand", nothing), ("result_grid_col", nothing)])

      # Undeclared: left alone.
      @test _ck_converged(pool, ("result",), _ck_result())
      # Declared under its name with the same text: adopted, nothing planned — a column's own named
      # CHECK as much as a table-level one.
      adopt = Models.CheckConstraint(condition = "laps < 500", name = "result_laps_hand")
      col = Models.CheckConstraint(condition = "grid < 90", name = "result_grid_col")
      @test _ck_converged(pool, ("result",), _ck_result(adopt))
      @test _ck_converged(pool, ("result",), _ck_result(adopt, col))

      # Declared with another text: replaced by the rebuild, and not reported as lost — while the
      # other hand-written CHECK, which the rebuild does drop, is.
      replaced = Models.CheckConstraint(condition = "laps < 400", name = "result_laps_hand")
      logs, plan = Test.collect_test_logs() do
        _ck_plan(pool, _ck_live(pool, "result"), _ck_result(replaced, col))
      end
      @test _ck_keys(plan, :result) == ["Alter table: result"]
      warned = [r for r in logs if r.level == Logging.Warn && occursin("DROP clauses", string(r.message))]
      @test length(warned) == 1
      clauses = Dict(warned[1].kwargs)[:clauses]
      @test any(c -> occursin("driverid > 0", c), clauses)
      @test !any(c -> occursin("laps", c), clauses)
      @test !any(c -> occursin("grid < 90", c), clauses)      # declared on its column: not lost either
      _ck_apply!(pool, plan)
      @test _ck_converged(pool, ("result",), _ck_result(replaced, col))
      @test !occursin("result_driver_hand", _ck_sql(pool, "result"))
    finally
      close_pool!(pool)
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# SQLite: a declared `grid >= 0` is a table CHECK, not PormG's own column CHECK (#742)
# A `PositiveIntegerField` renders `CHECK ("grid" >= 0)` and the reader turns it into the column fact
# `NonNegativeCheck`. A declared CheckConstraint with the same condition must not: an `IntegerField`
# column would then read as positive, and the diff would plan a retype. Its marker is what separates
# them. The positive field is the control — the reader still claims PormG's own clause.
# ─────────────────────────────────────────────────────────────────────────────
@testset "SQLite: a declared `grid >= 0` is a table CHECK, not PormG's own column CHECK (#742)" begin
  mktempdir() do dir
    pool = SQLiteConnectionPool(joinpath(dir, "ck_own.sqlite"); pool_size = 1)
    try
      declared = Models.Model("race_grid"; id = Models.IDField(), grid = Models.IntegerField(),
        pos = Models.PositiveIntegerField(),
        constraints = [Models.CheckConstraint(condition = "grid >= 0", name = "race_grid_non_negative")])
      _ck_apply!(pool, _ck_plan(pool, LiveTable[], declared))
      live = only(_ck_live(pool, "race_grid"))
      @test isempty(live.columns["grid"].checks)
      @test any(c -> c isa PormG.NonNegativeCheck, live.columns["pos"].checks)
      @test [c.name for c in live.checks] == ["race_grid_non_negative"]
      @test _ck_converged(pool, ("race_grid",), declared)

      # The other way round: a hand-written, UNMARKED CHECK of exactly that shape — named, on its
      # column — is the column's fact and nothing else, as it is on PostgreSQL. Read as a table CHECK
      # too, inspectdb would write it twice.
      # PormG's own DDL for a positive column, with its CHECK given a name — so the column type is
      # exactly the one the reader keeps a `NonNegativeCheck` on.
      own = PormG.Dialect.create_table(pool, Models.Model("lap_nn"; id = Models.IDField(), lap = Models.PositiveIntegerField()))
      @test occursin("CHECK (\"lap\" >= 0)", own)
      fetch(pool, replace(own, "CHECK (\"lap\" >= 0)" => "CONSTRAINT \"lap_nn_lap\" CHECK (\"lap\" >= 0)"))
      hand = only(_ck_live(pool, "lap_nn"))
      @test any(c -> c isa PormG.NonNegativeCheck, hand.columns["lap"].checks)
      @test isempty(hand.checks)
    finally
      close_pool!(pool)
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# SQLite: the CHECK rebuild absorbs a column drop, and keeps an adopted table-level UNIQUE (#742)
# Two consequences of WHEN the CHECK rebuild is registered — before the column pass. SQLite refuses
# `DROP COLUMN` for a column a table CHECK names, so dropping `laps` together with its CHECK must be
# ONE rebuild and no `DROP COLUMN`. And a Django-adopted `UNIQUE (raceid, driverid)` clause is not
# rendered by a rebuild, so the composite pass must see the rebuild coming and re-create it.
# ─────────────────────────────────────────────────────────────────────────────
@testset "SQLite: the CHECK rebuild absorbs a column drop, and keeps an adopted table-level UNIQUE (#742)" begin
  mktempdir() do dir
    pool = SQLiteConnectionPool(joinpath(dir, "ck_timing.sqlite"); pool_size = 1)
    try
      # The column goes, and so does the CHECK naming it.
      _ck_apply!(pool, _ck_plan(pool, LiveTable[], _ck_result(CK_LAPS)))
      without_laps = Models.Model("result"; resultid = Models.IDField(), raceid = Models.IntegerField(),
        driverid = Models.IntegerField(), grid = Models.IntegerField())
      p = _ck_plan(pool, _ck_live(pool, "result"), without_laps)
      @test _ck_keys(p, :result) == ["Alter table: result"]
      _ck_apply!(pool, p)
      @test _ck_converged(pool, ("result",), without_laps)
      fetch(pool, "DROP TABLE \"result\";")

      # An adopted UNIQUE clause survives a CHECK being added.
      sql = PormG.Dialect.create_table(pool, _ck_result())
      cut = findlast(')', sql)
      fetch(pool, sql[1:prevind(sql, cut)] * ",\n  UNIQUE (\"raceid\", \"driverid\")\n" * sql[cut:end])
      uniq = Models.UniqueConstraint(fields = ("raceid", "driverid"))
      @test _ck_converged(pool, ("result",), _ck_result(uniq))
      p = _ck_plan(pool, _ck_live(pool, "result"), _ck_result(uniq, CK_GRID))
      @test "Alter table: result" in _ck_keys(p, :result)
      @test "Create unique constraint: result_raceid_driverid_uniq" in _ck_keys(p, :result)
      _ck_apply!(pool, p)
      fetch(pool, "INSERT INTO \"result\" (\"raceid\", \"driverid\", \"grid\", \"laps\") VALUES (1, 1, 1, 1);")
      dup = try fetch(pool, "INSERT INTO \"result\" (\"raceid\", \"driverid\", \"grid\", \"laps\") VALUES (1, 1, 2, 2);"); false catch; true end
      @test dup
      fetch(pool, "DELETE FROM \"result\";")
      @test _ck_converged(pool, ("result",), _ck_result(uniq, CK_GRID))
    finally
      close_pool!(pool)
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# SQLite: a CHECK added in the same plan as a column runs after the ADD COLUMN (#742)
# The CHECK rebuild is registered before the column pass but must RUN after it: it copies every
# declared column out of the old table, and one added in this very plan exists there only once its
# `ADD COLUMN` has run. `_add_new_field` moves a queued rebuild behind the column it adds (#514); this
# pins that the early registration relies on it.
# ─────────────────────────────────────────────────────────────────────────────
@testset "SQLite: a CHECK added in the same plan as a column runs after the ADD COLUMN (#742)" begin
  mktempdir() do dir
    pool = SQLiteConnectionPool(joinpath(dir, "ck_add_col.sqlite"); pool_size = 1)
    try
      _ck_apply!(pool, _ck_plan(pool, LiveTable[], _ck_result()))
      v2 = _ck_result(Models.CheckConstraint(condition = "points >= 0", name = "result_points_non_negative");
                      points = Models.FloatField(null = true))
      p = _ck_plan(pool, _ck_live(pool, "result"), v2)
      @test last(_ck_keys(p, :result)) == "Alter table: result"
      _ck_apply!(pool, p)
      @test _ck_converged(pool, ("result",), v2)
    finally
      close_pool!(pool)
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# SQLite: a table rename keeps its CHECKs, and inspectdb reads them back (#742)
# `_retarget_references` rebuilds every live table of a plan with a table rename; a copy that dropped
# the CHECKs would read each declared one as missing. And `inspectdb` must carry the CHECKs into the
# models it writes, or the first `makemigrations` after adopting a schema would drop every one PormG
# owns — the plan against its own output must be empty, for an owned CHECK and a hand-written one.
# ─────────────────────────────────────────────────────────────────────────────
@testset "SQLite: a table rename keeps its CHECKs, and inspectdb reads them back (#742)" begin
  mktempdir() do dir
    pool = SQLiteConnectionPool(joinpath(dir, "ck_rename.sqlite"); pool_size = 1)
    try
      old = Models.Model("results_old"; resultid = Models.IDField(), grid = Models.IntegerField(),
        constraints = [Models.CheckConstraint(condition = "grid >= 0", name = "result_grid_non_negative")])
      _ck_apply!(pool, _ck_plan(pool, LiveTable[], old))
      renamed = Models.Model("result"; resultid = Models.IDField(), grid = Models.IntegerField(),
        constraints = [Models.CheckConstraint(condition = "grid >= 0", name = "result_grid_non_negative")])
      p = _ck_plan(pool, _ck_live(pool, "results_old"), renamed; answers = "1\n")
      @test _ck_keys(p, :result) == ["Rename table"]
      _ck_apply!(pool, p)
      @test _ck_converged(pool, ("result",), renamed)

      # inspectdb: an owned CHECK and a hand-written one both come back as declarations.
      fetch(pool, "CREATE TABLE \"lap_times\" (\"id\" INTEGER PRIMARY KEY, \"lap\" INTEGER NOT NULL, " *
                  "CONSTRAINT \"lap_times_lap_positive\" CHECK (lap > 0));")
      models = convert_schema_to_models(pool; include_table = ["result", "lap_times"])
      byname = Dict(model_table_name(m) => m for m in models)
      @test [(c.name, c.condition) for c in Models.declared_check_constraints(byname["result"])] ==
            [("result_grid_non_negative", "grid >= 0")]
      @test [(c.name, c.condition) for c in Models.declared_check_constraints(byname["lap_times"])] ==
            [("lap_times_lap_positive", "lap > 0")]
      @test occursin("Models.CheckConstraint(condition = \"lap > 0\", name = \"lap_times_lap_positive\")",
                     Models.Model_to_str(byname["lap_times"]; name_is_physical_table = true))
      @test all(isempty, values(_ck_plan(pool, _ck_live(pool, "result", "lap_times"), models...)))
    finally
      close_pool!(pool)
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# A column renamed or removed under a CHECK that still names it is refused (#742)
# PostgreSQL rewrites the stored expression on RENAME COLUMN, so the hash would still match and
# nothing be planned — until the declaration is rendered again (a SQLite rebuild, a replace) and names
# a column that no longer exists. Refused at plan time; with the condition updated, the plan goes
# through. Applies on both engines, since it is about the declaration, not the database.
# ─────────────────────────────────────────────────────────────────────────────
@testset "A column renamed or removed under a CHECK that still names it is refused (#742)" begin
  mktempdir() do dir
    pool = SQLiteConnectionPool(joinpath(dir, "ck_stale.sqlite"); pool_size = 1)
    try
      v1 = Models.Model("result"; resultid = Models.IDField(), laps = Models.IntegerField(),
        constraints = [Models.CheckConstraint(condition = "laps >= 0", name = "result_laps_non_negative")])
      _ck_apply!(pool, _ck_plan(pool, LiveTable[], v1))
      stale = Models.Model("result"; resultid = Models.IDField(), laps_done = Models.IntegerField(),
        constraints = [Models.CheckConstraint(condition = "laps >= 0", name = "result_laps_non_negative")])
      err = try _ck_plan(pool, _ck_live(pool, "result"), stale; answers = "1\n"); nothing catch e; e end
      @test err isa PormG.InvalidMigrationError
      @test occursin("still names column 'laps'", sprint(showerror, err))

      # Removed rather than renamed: PostgreSQL would drop the CHECK with the column and fail to re-add
      # it next time; SQLite refuses the DROP COLUMN. Refused too.
      gone = Models.Model("result"; resultid = Models.IDField(),
        constraints = [Models.CheckConstraint(condition = "laps >= 0", name = "result_laps_non_negative")])
      err = try _ck_plan(pool, _ck_live(pool, "result"), gone); nothing catch e; e end
      @test err isa PormG.InvalidMigrationError
      @test occursin("which this migration removes", sprint(showerror, err))

      fixed = Models.Model("result"; resultid = Models.IDField(), laps_done = Models.IntegerField(),
        constraints = [Models.CheckConstraint(condition = "laps_done >= 0", name = "result_laps_non_negative")])
      p = _ck_plan(pool, _ck_live(pool, "result"), fixed; answers = "1\n")
      _ck_apply!(pool, p)
      @test _ck_converged(pool, ("result",), fixed)
    finally
      close_pool!(pool)
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# PostgreSQL: add, keep, replace, rename and drop — in the order the database needs (#742)
# Plan shape over a synthetic live side (the stand-in has no catalog). A replace drops BEFORE the
# column pass and adds after it, so on a table that also loses a column the CHECK drop precedes the
# `DROP COLUMN` — PostgreSQL would otherwise take the CHECK with the column. A marked CHECK under a
# new declared name is a rename, not a drop and an add; an unmarked one nobody declares is left alone.
# ─────────────────────────────────────────────────────────────────────────────
@testset "PostgreSQL: add, keep, replace, rename and drop — in the order the database needs (#742)" begin
  base = _ck_result(CK_LAPS)
  live = live_table(base, CK_PG)
  @test [(c.name, c.marker) for c in live.checks] == [("result_laps_non_negative", check_marker("laps >= 0"))]

  # Kept.
  @test all(isempty, values(_ck_plan(CK_PG, [live], base)))

  # Added: the constraint, then its marker.
  p = _ck_plan(CK_PG, [live], _ck_result(CK_LAPS, CK_GRID))
  @test _ck_keys(p, :result) == ["Create check constraint: result_grid_range"]
  @test occursin("COMMENT ON CONSTRAINT \"result_grid_range\" ON \"result\" IS '$(check_marker(CK_GRID.condition))'", _ck_text(p))

  # Replaced, on a table that also loses `grid`: the drop comes before the column's removal.
  changed = Models.Model("result"; resultid = Models.IDField(), raceid = Models.IntegerField(),
    driverid = Models.IntegerField(), laps = Models.IntegerField(),
    constraints = [Models.CheckConstraint(condition = "laps >= 1", name = "result_laps_non_negative")])
  p = _ck_plan(CK_PG, [live], changed)
  keys_ = _ck_keys(p, :result)
  @test first(keys_) == "Remove check constraint: result_laps_non_negative"
  @test findfirst(==("Remove check constraint: result_laps_non_negative"), keys_) <
        findfirst(k -> startswith(k, "Remove field"), keys_)
  @test last(keys_) == "Create check constraint: result_laps_non_negative"
  @test occursin("DROP CONSTRAINT IF EXISTS \"result_laps_non_negative\"", _ck_text(p))
  @test all(is_destructive(p[:result][k]) for k in keys_ if startswith(k, "Remove check"))

  # Renamed: the same condition under a new name.
  moved = _ck_result(Models.CheckConstraint(condition = "laps >= 0", name = "result_laps_ok"))
  p = _ck_plan(CK_PG, [live], moved)
  @test _ck_keys(p, :result) == ["Rename check constraint: result_laps_non_negative"]
  @test occursin("RENAME CONSTRAINT \"result_laps_non_negative\" TO \"result_laps_ok\"", _ck_text(p))

  # Adopted: an unmarked live CHECK with the declared text becomes PormG's through a COMMENT alone —
  # nothing about the constraint changes, so the step is not destructive — and is then unchanged.
  unowned = LiveTable(live.name, live.columns, live.indexes, live.composites,
                      [LiveCheck("result_laps_non_negative", "(laps >= 0)", nothing)])
  p = _ck_plan(CK_PG, [unowned], base)
  @test _ck_keys(p, :result) == ["Adopt check constraint: result_laps_non_negative"]
  @test _ck_text(p) == "COMMENT ON CONSTRAINT \"result_laps_non_negative\" ON \"result\" IS '$(check_marker("laps >= 0"))';"
  @test !is_destructive(_ck_text(p))
  # A comment a DBA left on the CHECK is kept: `COMMENT ON` replaces the whole comment, so the marker is
  # appended to it, the quote doubled.
  noted = LiveTable(live.name, live.columns, live.indexes, live.composites,
                    [LiveCheck("result_laps_non_negative", "(laps >= 0)", nothing, "FIA's lap rule")])
  @test _ck_text(_ck_plan(CK_PG, [noted], base)) ==
        "COMMENT ON CONSTRAINT \"result_laps_non_negative\" ON \"result\" IS 'FIA''s lap rule $(check_marker("laps >= 0"))';"

  # Renamed by text as well as by marker: an owned CHECK whose marker is of another spelling of the
  # condition (inspectdb wrote the declaration in PostgreSQL's) is still a rename, not a drop and an add.
  respelled = LiveTable(live.name, live.columns, live.indexes, live.composites,
                        [LiveCheck("result_laps_non_negative", "(laps >= 0)", check_marker("laps>=0 "))])
  p = _ck_plan(CK_PG, [respelled], _ck_result(Models.CheckConstraint(condition = "(laps >= 0)", name = "result_laps_ok")))
  @test _ck_keys(p, :result) == ["Rename check constraint: result_laps_non_negative"]

  # Dropped: owned and no longer declared. Left alone: unowned and undeclared.
  hand = LiveCheck("result_hand", "grid < 100", nothing)
  with_hand = LiveTable(live.name, live.columns, live.indexes, live.composites, vcat(live.checks, hand))
  p = _ck_plan(CK_PG, [with_hand], _ck_result())
  @test _ck_keys(p, :result) == ["Remove check constraint: result_laps_non_negative"]

  # A name PostgreSQL already gives one of PormG's own column CHECKs is refused before the plan is
  # written, on a new table as on an existing one.
  clash = Models.Model("race_grid"; id = Models.IDField(), grid = Models.PositiveIntegerField(),
    constraints = [Models.CheckConstraint(condition = "grid <= 40", name = "race_grid_grid_check")])
  err = try _ck_plan(CK_PG, LiveTable[], clash); nothing catch e; e end
  @test err isa PormG.InvalidMigrationError
  @test occursin("race_grid_grid_check", sprint(showerror, err))
  # On an existing table, a hand-written CHECK of PormG's own `laps >= 0` shape holds the name unless
  # the column pass drops it: it does when the declared `laps` is a plain IntegerField (the CHECK is
  # then a stray column fact), not when it is a PositiveIntegerField (the column keeps it).
  catalog = CheckCapturePg742(String[], DataFrame(col = ["laps"], nonneg = [true], bytelen = [false]))
  nn = Models.CheckConstraint(condition = "laps >= 0", name = "laps_nn")
  plain = Models.Model("result"; resultid = Models.IDField(), laps = Models.IntegerField(), constraints = [nn])
  positive = Models.Model("result"; resultid = Models.IDField(), laps = Models.PositiveIntegerField(), constraints = [nn])
  @test Migrations._refuse_check_name_clash(catalog, plain, "result", :result, "laps_nn") === nothing
  @test_throws PormG.InvalidMigrationError Migrations._refuse_check_name_clash(catalog, positive, "result", :result, "laps_nn")
  other = CheckCapturePg742(String[], DataFrame(col = [missing], nonneg = [false], bytelen = [false]))
  @test_throws PormG.InvalidMigrationError Migrations._refuse_check_name_clash(other, plain, "result", :result, "laps_nn")

  # A new table: every declared CHECK is added after the CREATE TABLE.
  p = _ck_plan(CK_PG, LiveTable[], _ck_result(CK_GRID))
  @test _ck_keys(p, :result) == ["New model", "Create check constraint: result_grid_range"]
end

# ─────────────────────────────────────────────────────────────────────────────
# PostgreSQL reader: the marker keeps a declared CHECK out of PormG's own, and is read back (#742)
# The two exact-clause matchers (#731, #747) gain the unmarked predicate in the reader AND the dropper
# — with COALESCE, because PormG's own CHECKs carry no comment and a bare NULL comparison would lose
# them all. The table-CHECK reader strips `CHECK ( … )` and a `NOT VALID`, and finds the marker
# anywhere in a comment a user may have added to.
# ─────────────────────────────────────────────────────────────────────────────
@testset "PostgreSQL reader: the marker keeps a declared CHECK out of PormG's own, and is read back (#742)" begin
  pred = Migrations._PG_UNMARKED_CHECK
  @test occursin("COALESCE(obj_description(con.oid, 'pg_constraint'), '')", pred)

  cap = CheckCapturePg742(String[], DataFrame())
  PormG.get_constraints_check(cap, "result", "grid")
  PormG.get_constraints_byte_length_check(cap, "result", "thumb")
  @test all(sql -> occursin(pred, sql), cap.sqls)

  h = check_marker("grid >= 0 AND grid <= 40")
  cap = CheckCapturePg742(String[], DataFrame(
    table_name = ["result", "result", "result"],
    constraint_name = ["result_grid_range", "result_hand", "result_legacy"],
    def = ["CHECK (((grid >= 0) AND (grid <= 40)))", "CHECK ((laps < 100))", "CHECK ((points >= (0)::double precision)) NOT VALID"],
    comment = ["$(h) — added by the team", missing, "no marker here"]))
  checks = Migrations._pg_table_checks(cap)["result"]
  @test [(c.name, c.sql, c.marker) for c in checks] ==
        [("result_grid_range", "(grid >= 0) AND (grid <= 40)", h),
         ("result_hand", "laps < 100", nothing),
         ("result_legacy", "points >= (0)::double precision", nothing)]
  @test occursin(pred, only(cap.sqls))
  # And a declared model whose marker matches plans nothing, though the texts differ.
  live = LiveTable("result", live_table(_ck_result(), CK_PG).columns, Dict{String, Union{String, Nothing}}(),
                   PormG.Migrations.LiveComposite[], checks[1:1])
  @test all(isempty, values(_ck_plan(CK_PG, [live], _ck_result(CK_GRID))))
end
