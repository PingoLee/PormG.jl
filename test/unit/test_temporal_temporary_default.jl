"""
A nullable `DateTimeField` / `DateField` added to a populated table stays NULL (#607).

`_add_new_field` writes a TEMPORARY default into `ADD COLUMN` for a new temporal column and then
drops it again, so that a NOT NULL column can be added to a table that already has rows — SQLite
refuses `ADD COLUMN … NOT NULL` without a default, PostgreSQL refuses it on a non-empty table.
`_get_temporary_default_value` used to hand that value to EVERY `sDateTimeField` / `sDateField`,
`null = true` included, and the migration then backfilled every existing row with the moment
`migrate` ran: 1125 of 1125 `race` rows on the fixture, 731 of which should have stayed NULL.
Nothing errored, the audit trail recorded only the ADD COLUMN, and the value is indistinguishable
from real data afterwards.

Since #607 the helper returns `nothing` unless the column is NOT NULL *and* has no declared
`default` — the one shape that needs a backfill value. A declared `default` is a different slot
(`field_to_column` already prefers it), so it keeps backfilling on its own, now without the
redundant cleanup step (a `SET DEFAULT` on PostgreSQL, a full table rebuild on SQLite).

Three layers, because each catches a different way of being wrong:

1. The helper's return value directly — the mutation gate on the line that changed.
2. The PLAN on both engines — the nullable shape must produce a bare `ADD COLUMN` and no cleanup
   step; the NOT NULL, defaultless shape must still produce the temporary default and its cleanup
   (regression control for the path Phase 8b/8c of `test_migration_bootstrap.jl` rely on).
3. EXECUTION against a real temporary SQLite file — the only oracle that sees DATA. Plan text can
   read correctly and still backfill; the row count of NULLs after `migrate` cannot.

Hermetic: a marker mock for PostgreSQL (the plan is text; no server is consulted for a new
column), a real temporary SQLite file for SQLite (its rebuild path queries `PRAGMA index_list`,
and the execution oracle needs a database anyway). The live-database half on both engines is
`test/integration/test_migration_bootstrap.jl` → Phase 8c2.

    julia --project=test/integration test/unit/test_temporal_temporary_default.jl
"""

using Test
using Dates
using DataFrames
using PormG
using PormG.Models
using PormG.Migrations
import PormG: PormGModel, PormGPostgres
# The SQLite half opens a real (temporary) file, so it needs the weakdep extension. `runtests.jl`
# loads it for the whole suite; this guard is what makes the file runnable on its own.
isdefined(Main, :SQLite) || include(joinpath(@__DIR__, "..", "load_drivers.jl"))
import PormG.ConnectionPool: fetch, SQLiteConnectionPool
import PormG.Migrations: _get_temporary_default_value

# Suffixed name: `runtests.jl` includes every unit file into ONE module, so a bare `MockPostgres`
# would silently redefine a sibling's. No constraint-name stubs: a NEW column has no live
# constraints for `alter_field` to look up, and the one delta this path renders (`:default`) sits in
# no lookup branch — a `MethodError` here would therefore be a real finding, not a missing stub.
struct TemporalDefaultMockPg607 <: PormGPostgres end
const PG607 = TemporalDefaultMockPg607()

# The live side every testset starts from: a table with rows and no temporal column yet. The
# declared side adds the columns under test to it. Built fresh per call — `Models.Model` returns a
# mutable struct and a shared instance would let one testset's `fields` leak into the next.
_live_race() = Models.Model("race"; id = Models.IDField(), name = Models.CharField(max_length = 40))
function _declared_race(; kwargs...)
  Models.Model("race"; id = Models.IDField(), name = Models.CharField(max_length = 40), kwargs...)
end
function _schema_for(declared::PormGModel)
  Dict{Symbol, Dict{Symbol, Union{Bool, PormGModel}}}(
    :race => Dict{Symbol, Union{Bool, PormGModel}}(:model => declared, :exist => false))
end
function _settings()
  s = PormG.Configuration.Settings()
  s.change_db = true
  return s
end
# The plan for `race` as an ordered (step ⇒ SQL) list, so tests can assert on step NAMES — the
# planner's cleanup step is registered under `Alter field: <col>` on PostgreSQL and under the
# table-wide `Alter table: race` on SQLite, and its ABSENCE is what #607 asserts.
_race_plan(conn, declared) = Migrations.get_migration_plan(
  PormGModel[_live_race()], _schema_for(declared), conn, _settings(); interactive = false)[:race]

# Apply a plan to a real SQLite pool, statement by statement. `PRAGMA foreign_key_check` is a probe
# the runner treats separately, not DDL, so it is skipped here as `test_plan_actions_golden.jl` does.
function _apply!(pool, plan)
  for (_, sql) in plan
    for stmt in split(sql, ";")
      trimmed = strip(stmt)
      isempty(trimmed) && continue
      startswith(uppercase(trimmed), "PRAGMA FOREIGN_KEY_CHECK") && continue
      fetch(pool, String(trimmed))
    end
  end
end
function _seed_race!(pool)
  fetch(pool, """CREATE TABLE "race" (
                   "id" INTEGER PRIMARY KEY AUTOINCREMENT UNIQUE NOT NULL,
                   "name" TEXT(40) NOT NULL)""")
  for (i, n) in enumerate(("Monza", "Spa", "Suzuka"))
    fetch(pool, """INSERT INTO "race" ("id", "name") VALUES ($i, '$n')""")
  end
end
_null_count(pool, col) = (fetch(pool, """SELECT count(*) AS n FROM "race" WHERE "$col" IS NULL""") |> DataFrame)[1, :n]
_row_count(pool) = (fetch(pool, """SELECT count(*) AS n FROM "race" """) |> DataFrame)[1, :n]
function _dflt_value(pool, col)
  info = fetch(pool, """PRAGMA table_info("race")""") |> DataFrame
  row = info[info.name .== col, :]
  @assert nrow(row) == 1 "column $col missing from race"
  return row[1, :dflt_value]
end

@testset "#607: a nullable DateTimeField / DateField is added as NULL, not backfilled" begin
  settings = _settings()

  # ───────────────────────────────────────────────────────────────────────────
  # Layer 1 — the helper: a value ONLY for a NOT NULL column with no declared default
  # The mutation gate on the changed line. Before #607 every temporal field got a value here.
  # ───────────────────────────────────────────────────────────────────────────
  @testset "the temporary default is minted only for a NOT NULL, defaultless temporal column" begin
    # The two shapes that used to be backfilled and must not be.
    @test _get_temporary_default_value(Models.DateTimeField(null = true), settings) === nothing
    @test _get_temporary_default_value(Models.DateField(null = true), settings) === nothing
    # The sibling shape: a declared default backfills on its own (`field_to_column` prefers it), so
    # no temporary value — and therefore no cleanup step — is owed.
    @test _get_temporary_default_value(Models.DateTimeField(default = DateTime(2024, 3, 1, 12)), settings) === nothing
    @test _get_temporary_default_value(Models.DateField(default = Date(2024, 3, 1)), settings) === nothing
    # THE CONTROL: the shape the value exists for. Without this, an implementation returning
    # `nothing` unconditionally would pass the four assertions above.
    @test _get_temporary_default_value(Models.DateTimeField(), settings) !== nothing
    @test _get_temporary_default_value(Models.DateField(), settings) !== nothing
    # Every other field type is untouched — `nothing` before and after.
    @test _get_temporary_default_value(Models.TimeField(), settings) === nothing
    @test _get_temporary_default_value(Models.IntegerField(), settings) === nothing
  end

  # ───────────────────────────────────────────────────────────────────────────
  # Layer 2 — the plan on PostgreSQL (marker mock)
  # A nullable temporal column is ONE step, `ADD COLUMN … NULL` with no `DEFAULT`, and no
  # `Alter field:` cleanup. The NOT NULL, defaultless control keeps `DEFAULT '<ts>'` and the
  # `DROP DEFAULT` step — that is the path `test_migration_bootstrap.jl` Phase 8b/(d2) execute.
  # ───────────────────────────────────────────────────────────────────────────
  @testset "PostgreSQL plan: bare ADD COLUMN, no DROP DEFAULT" begin
    plan = _race_plan(PG607, _declared_race(start_at = Models.DateTimeField(null = true),
                                            held_on = Models.DateField(null = true)))
    @test sort(collect(keys(plan))) == ["Add field: held_on", "Add field: start_at"]
    for col in ("start_at", "held_on")
      sql = plan["Add field: $col"]
      @test occursin("ADD COLUMN \"$col\"", sql)
      @test occursin(" NULL", sql)
      @test !occursin("DEFAULT", sql)
    end
    @test !any(occursin("DROP DEFAULT", sql) for sql in values(plan))

    # The sibling shape: the DECLARED default reaches the DDL, and nothing follows it.
    plan = _race_plan(PG607, _declared_race(held_on = Models.DateField(default = Date(2024, 3, 1))))
    @test collect(keys(plan)) == ["Add field: held_on"]
    @test occursin("NOT NULL DEFAULT '2024-03-01'", plan["Add field: held_on"])
    @test !any(occursin("SET DEFAULT", sql) || occursin("DROP DEFAULT", sql) for sql in values(plan))

    # THE CONTROL: NOT NULL and defaultless still gets the temporary default and its cleanup.
    plan = _race_plan(PG607, _declared_race(start_at = Models.DateTimeField()))
    @test collect(keys(plan)) == ["Add field: start_at", "Alter field: start_at"]
    @test occursin("NOT NULL DEFAULT '", plan["Add field: start_at"])
    @test occursin("ALTER COLUMN \"start_at\" DROP DEFAULT", plan["Alter field: start_at"])
  end

  # ───────────────────────────────────────────────────────────────────────────
  # Layer 2 + 3 — the plan on SQLite, and its EXECUTION against a real file
  # SQLite's cleanup is a full table rebuild registered under `Alter table: race`; for a nullable
  # column there must be none. Then the plan is APPLIED to a 3-row table and the NULL count is the
  # assertion — the only check that fails by DATA rather than by text.
  # ───────────────────────────────────────────────────────────────────────────
  @testset "SQLite plan and execution: existing rows stay NULL, no rebuild" begin
    mktempdir() do dir
      pool = SQLiteConnectionPool(joinpath(dir, "temporal607.sqlite"); pool_size = 1)
      try
        _seed_race!(pool)
        plan = _race_plan(pool, _declared_race(start_at = Models.DateTimeField(null = true),
                                               held_on = Models.DateField(null = true)))
        @test sort(collect(keys(plan))) == ["Add field: held_on", "Add field: start_at"]
        @test !haskey(plan, "Alter table: race")
        for col in ("start_at", "held_on")
          @test !occursin("DEFAULT", plan["Add field: $col"])
        end

        # THE ORACLE. Before #607 this read 0 for both columns: every row carried `migrate`'s own
        # timestamp, and the table had been rebuilt to hide the default that wrote it.
        _apply!(pool, plan)
        @test _null_count(pool, "start_at") == 3
        @test _null_count(pool, "held_on") == 3
        @test _dflt_value(pool, "start_at") === missing
        @test _dflt_value(pool, "held_on") === missing
        # The rows themselves are untouched — no rebuild ran.
        @test _row_count(pool) == 3
      finally
        PormG.ConnectionPool.close_pool!(pool)
      end
    end
  end

  @testset "SQLite control: a NOT NULL, defaultless column still backfills and drops the default" begin
    mktempdir() do dir
      pool = SQLiteConnectionPool(joinpath(dir, "temporal607ctl.sqlite"); pool_size = 1)
      try
        _seed_race!(pool)
        plan = _race_plan(pool, _declared_race(start_at = Models.DateTimeField()))
        steps = collect(keys(plan))
        # ADD COLUMN with the temporary default, then the rebuild that removes it — in that order.
        @test steps == ["Add field: start_at", "Alter table: race"]
        @test occursin("NOT NULL DEFAULT '", plan["Add field: start_at"])
        @test occursin("DROP TABLE IF EXISTS \"race_new\"", plan["Alter table: race"])

        _apply!(pool, plan)
        # Every existing row was backfilled (the column is NOT NULL, so it had to be) …
        @test _null_count(pool, "start_at") == 0
        # … and the rebuilt table no longer carries the temporary default.
        @test _dflt_value(pool, "start_at") === missing
        @test _row_count(pool) == 3
      finally
        PormG.ConnectionPool.close_pool!(pool)
      end
    end
  end

  # The sibling shape on SQLite: the declared default backfills, and the plan is ONE statement —
  # before #607 it was followed by a full table rebuild that changed nothing.
  @testset "SQLite: a declared default backfills without a rebuild" begin
    mktempdir() do dir
      pool = SQLiteConnectionPool(joinpath(dir, "temporal607dflt.sqlite"); pool_size = 1)
      try
        _seed_race!(pool)
        plan = _race_plan(pool, _declared_race(held_on = Models.DateField(default = Date(2024, 3, 1))))
        @test collect(keys(plan)) == ["Add field: held_on"]
        @test occursin("NOT NULL DEFAULT '2024-03-01'", plan["Add field: held_on"])

        _apply!(pool, plan)
        @test _null_count(pool, "held_on") == 0
        # The DECLARED default is a real column default and must survive — it is not temporary.
        @test _dflt_value(pool, "held_on") == "'2024-03-01'"
        rows = fetch(pool, """SELECT "held_on" FROM "race" """) |> DataFrame
        @test all(==("2024-03-01"), string.(rows.held_on))
      finally
        PormG.ConnectionPool.close_pool!(pool)
      end
    end
  end
end
