# ─────────────────────────────────────────────────────────────────────────────
# Duplicate one-column indexes and deterministic `db_index` names (#1341)
#
# A column can carry the same plain index more than once, under several names. `LiveTable.indexes`
# held ONE name per column, so the planner never saw the extras: `makemigrations` reported nothing,
# and removing `db_index` dropped only the copy the map happened to hold. The copies got in because
# a `db_index` name ended in `randstring(8)` and `IF NOT EXISTS` compares names, not definitions:
# every plan that misread the column as unindexed (#325) created one more.
#
# Hermetic: the planner runs on dispatch-only PostgreSQL and MySQL engines against hand-built live
# tables; the SQLite reader runs against a real temporary file.
#
#   julia --project=test/integration test/unit/test_duplicate_one_column_indexes.jl
# ─────────────────────────────────────────────────────────────────────────────
using Test
using PormG
import OrderedCollections: OrderedDict
# Qualified through prefixed constants: `runtests.jl` includes every file into `Main`, and a later one
# declares its own `Models`.
const _M1341 = PormG.Models
const _MG1341 = PormG.Migrations
const _CP1341 = PormG.ConnectionPool
const LiveTable1341 = _MG1341.LiveTable
isdefined(Main, :SQLite) || include(joinpath(@__DIR__, "..", "load_drivers.jl"))

struct Dup1341MySQL <: PormG.PormGMySQL end
const PG1341 = _MG1341._PostgresEngine()
const MY1341 = Dup1341MySQL()

_settings1341() = (s = PormG.Configuration.Settings(); s.change_db = true; s)
_schema1341(models...) = Dict{Symbol, Dict{Symbol, Union{Bool, PormG.PormGModel}}}(
  Symbol(_M1341.model_table_name(m)) => Dict{Symbol, Union{Bool, PormG.PormGModel}}(:model => m, :exist => false)
  for m in models)
# F1's `result` table, with `grid` indexed or not.
_result1341(; db_index::Bool) = _M1341.Model("result"; resultid = _M1341.IDField(),
                                             grid = _M1341.IntegerField(db_index = db_index),
                                             points = _M1341.FloatField(default = 0.0))
_lap1341() = _M1341.Model("lap"; lapid = _M1341.IDField(), position = _M1341.IntegerField())

# The model's live table with `grid` carrying exactly `names` (nothing: no index at all).
function _live1341(conn, model, names::Union{Vector{String}, Nothing}; others = Dict{String, Vector{String}}())
  t = _MG1341.live_table(model, conn)
  indexes = copy(others)
  names === nothing || (indexes["grid"] = sort(names))
  return LiveTable1341(t.name, t.columns, indexes, t.composites, t.checks)
end

_plan1341(conn, live::Vector{LiveTable1341}, models...) =
  _MG1341.get_migration_plan(live, _schema1341(models...), conn, _settings1341(); interactive = false)
_steps1341(plan, table = :result) = collect(get(plan, table, OrderedDict{String, String}()))

# ─────────────────────────────────────────────────────────────────────────────
# What: a declared `db_index` whose column carries three identical copies keeps one, drops two.
# SQL: DROP INDEX IF EXISTS "result_grid_s21bkzlw_idx"; and the same for "…zndqsv7m…" (PostgreSQL);
#      DROP INDEX `result_grid_s21bkzlw_idx` ON `result`; (MySQL). No CREATE, no "Remove index on grid".
# Why: the reader used to keep one name per column, so this plan was empty and the extras stayed for
# good — every write maintaining three indexes where the model declares one. The copy kept is the
# one under the name PormG now derives, so the next plan agrees with this one.
# ─────────────────────────────────────────────────────────────────────────────
@testset "declared db_index: duplicate copies are dropped, the derived name kept (#1341)" begin
  copies = ["result_grid_s21bkzlw_idx", "result_grid_idx", "result_grid_zndqsv7m_idx"]
  m = _result1341(db_index = true)
  pg = _steps1341(_plan1341(PG1341, [_live1341(PG1341, m, copies)], m))
  @test pg == [
    "Remove duplicate index result_grid_s21bkzlw_idx on grid" => "DROP INDEX IF EXISTS \"result_grid_s21bkzlw_idx\";",
    "Remove duplicate index result_grid_zndqsv7m_idx on grid" => "DROP INDEX IF EXISTS \"result_grid_zndqsv7m_idx\";",
  ]
  my = _steps1341(_plan1341(MY1341, [_live1341(MY1341, m, copies)], m))
  @test my == [
    "Remove duplicate index result_grid_s21bkzlw_idx on grid" => "DROP INDEX `result_grid_s21bkzlw_idx` ON `result`;",
    "Remove duplicate index result_grid_zndqsv7m_idx on grid" => "DROP INDEX `result_grid_zndqsv7m_idx` ON `result`;",
  ]
end

# ─────────────────────────────────────────────────────────────────────────────
# What: with no copy under the derived name, the first copy by name is the one kept.
# SQL: DROP INDEX IF EXISTS "result_grid_bbbbbbbb_idx"; — "result_grid_aaaaaaaa_idx" stays.
# Why: a database whose copies all came from the random-suffix era must still converge on one
# copy, and the same one on every run, so the choice cannot depend on the reader's order.
# ─────────────────────────────────────────────────────────────────────────────
@testset "declared db_index: without the derived name, the first copy by name is kept (#1341)" begin
  m = _result1341(db_index = true)
  for copies in (["result_grid_aaaaaaaa_idx", "result_grid_bbbbbbbb_idx"],
                 ["result_grid_bbbbbbbb_idx", "result_grid_aaaaaaaa_idx"])
    steps = _steps1341(_plan1341(PG1341, [_live1341(PG1341, m, copies)], m))
    @test steps == ["Remove duplicate index result_grid_bbbbbbbb_idx on grid" =>
                    "DROP INDEX IF EXISTS \"result_grid_bbbbbbbb_idx\";"]
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# What: a column the model does not index loses every copy in one plan.
# SQL: DROP INDEX IF EXISTS "result_grid_idx"; (labelled "Remove index on grid", as before) plus one
#      "Remove duplicate index … on grid" step per other copy.
# Why: the planner dropped one copy per `makemigrations` run — the others still read as an index —
# so N runs reached this state. One plan reaches it now (maintainer's decision on #1341).
# ─────────────────────────────────────────────────────────────────────────────
@testset "undeclared db_index: every copy is dropped in one plan (#1341)" begin
  m = _result1341(db_index = false)
  copies = ["result_grid_idx", "result_grid_s21bkzlw_idx", "result_grid_zndqsv7m_idx"]
  steps = _steps1341(_plan1341(PG1341, [_live1341(PG1341, m, copies)], m))
  @test steps == [
    "Remove index on grid" => "DROP INDEX IF EXISTS \"result_grid_idx\";",
    "Remove duplicate index result_grid_s21bkzlw_idx on grid" => "DROP INDEX IF EXISTS \"result_grid_s21bkzlw_idx\";",
    "Remove duplicate index result_grid_zndqsv7m_idx on grid" => "DROP INDEX IF EXISTS \"result_grid_zndqsv7m_idx\";",
  ]
  # One copy: the single step it always was.
  one = _steps1341(_plan1341(PG1341, [_live1341(PG1341, m, ["result_grid_s21bkzlw_idx"])], m))
  @test one == ["Remove index on grid" => "DROP INDEX IF EXISTS \"result_grid_s21bkzlw_idx\";"]
end

# ─────────────────────────────────────────────────────────────────────────────
# What: a `db_index` index is created under `<table>_<column>_idx`, and a plan over a column that
# already carries one index plans nothing.
# SQL: CREATE INDEX IF NOT EXISTS "result_grid_idx" ON "result" ("grid"); on a new column's index
#      and on a new table's (PostgreSQL); CREATE INDEX `result_grid_idx` ON `result` (`grid`); (MySQL).
# Why: the name used to end in `randstring(8)`, so a plan repeated over a misread column created a
# second copy instead of hitting `IF NOT EXISTS` — the origin of the duplicates above.
# ─────────────────────────────────────────────────────────────────────────────
@testset "a db_index index is named <table>_<column>_idx, and a repeated plan creates nothing (#1341)" begin
  m = _result1341(db_index = true)
  create = "Create index on grid" => "CREATE INDEX IF NOT EXISTS \"result_grid_idx\" ON \"result\" (\"grid\");"
  @test _steps1341(_plan1341(PG1341, [_live1341(PG1341, m, nothing)], m)) == [create]
  # Twice: the same statement, so a second run against a database the first one missed is a no-op.
  @test _steps1341(_plan1341(PG1341, [_live1341(PG1341, m, nothing)], m)) == [create]
  @test _steps1341(_plan1341(MY1341, [_live1341(MY1341, m, nothing)], m)) ==
        ["Create index on grid" => "CREATE INDEX `result_grid_idx` ON `result` (`grid`);"]
  # A new table: the same name from `_add_new_table`, which used the random base too.
  fresh = _plan1341(PG1341, LiveTable1341[], m)
  @test fresh[:result]["Create index on grid"] == last(create)
  # One copy live: converged, nothing planned for the table.
  @test isempty(_steps1341(_plan1341(PG1341, [_live1341(PG1341, m, ["result_grid_idx"])], m)))
end

# ─────────────────────────────────────────────────────────────────────────────
# What: when another index already holds the derived name, the new index takes the hashed
# alternative `result_grid_<8 hex>_idx` — the same one on every run.
# SQL: CREATE INDEX IF NOT EXISTS "result_grid_<8 hex>_idx" ON "result" ("grid");
# Why: an index name is unique per schema on PostgreSQL and SQLite, and existing indexes are never
# renamed — a renamed column or table leaves its index under the old derived name. Creating a held
# name under `IF NOT EXISTS` would create nothing, and the column would stay unindexed silently.
# ─────────────────────────────────────────────────────────────────────────────
@testset "a derived name another index holds falls back to a hashed one (#1341)" begin
  m = _result1341(db_index = true)
  lap = _lap1341()
  held = LiveTable1341(_MG1341.live_table(lap, PG1341).name, _MG1341.live_table(lap, PG1341).columns,
                   Dict{String, Vector{String}}("position" => ["result_grid_idx"]))
  plans = [_plan1341(PG1341, [_live1341(PG1341, m, nothing), held], m, lap) for _ in 1:2]
  steps = _steps1341(plans[1])
  @test length(steps) == 1 && first(steps[1]) == "Create index on grid"
  name = match(r"^CREATE INDEX IF NOT EXISTS \"(result_grid_[0-9a-f]{8}_idx)\" ON \"result\" \(\"grid\"\);$", last(steps[1]))
  @test name !== nothing
  @test _steps1341(plans[2]) == steps
  # Mutation gate: without the fallback the statement names the held "result_grid_idx".
  @test !occursin("\"result_grid_idx\"", last(steps[1]))
end

# ─────────────────────────────────────────────────────────────────────────────
# What: a long derived name is cut to the engine's limit and given 8 hex digits of its own hash.
# SQL: none — the name itself: ≤ 63 bytes on PostgreSQL, ≤ 64 characters on MySQL, unchanged on SQLite.
# Why: PostgreSQL cuts a long identifier silently, so two long names sharing their first 63 bytes
# would meet under one name and the second `IF NOT EXISTS` would create nothing; MySQL refuses a
# name over 64 characters outright (error 1059).
# ─────────────────────────────────────────────────────────────────────────────
@testset "a long derived name fits the engine and stays distinct (#1341)" begin
  table = "constructor_standings_history"
  a = _MG1341._one_column_index_name(PG1341, table, "fastest_lap_time_in_milliseconds_a")
  b = _MG1341._one_column_index_name(PG1341, table, "fastest_lap_time_in_milliseconds_b")
  @test ncodeunits(a) <= 63 && ncodeunits(b) <= 63 && a != b
  @test occursin(r"_[0-9a-f]{8}$", a)
  @test _MG1341._one_column_index_name(PG1341, table, "fastest_lap_time_in_milliseconds_a") == a
  # A multi-byte column: cut on a character boundary.
  u = _MG1341._one_column_index_name(PG1341, table, "tempo_da_volta_mais_rápida_em_milissegundos")
  @test isvalid(u) && ncodeunits(u) <= 63
  my = _MG1341._one_column_index_name(MY1341, table, "fastest_lap_time_in_milliseconds_a")
  @test length(my) <= 64 && occursin(r"_[0-9a-f]{8}$", my)
  @test _MG1341._one_column_index_name(PG1341, "result", "grid") == "result_grid_idx"
  sl = _MG1341._SQLiteEngine()
  @test _MG1341._one_column_index_name(sl, table, "fastest_lap_time_in_milliseconds_a") ==
        "$(table)_fastest_lap_time_in_milliseconds_a_idx"
end

# ─────────────────────────────────────────────────────────────────────────────
# What: the schema fingerprint lists every copy, and a table without duplicates digests as before.
# SQL: none — the digest `migrate` compares against the plan header.
# Why: the fingerprint is a persisted format (plans in flight carry it); one line per (column, name)
# keeps every existing digest, while a duplicate the plan drops is part of the schema it assumed.
# ─────────────────────────────────────────────────────────────────────────────
@testset "schema fingerprint: one line per copy, unchanged without duplicates (#1341)" begin
  m = _result1341(db_index = true)
  one = _live1341(PG1341, m, ["result_grid_idx"])
  two = _live1341(PG1341, m, ["result_grid_idx", "result_grid_s21bkzlw_idx"])
  @test _MG1341._schema_table_fingerprint(one) != _MG1341._schema_table_fingerprint(two)
  # The digests origin/main computed for these two tables before #1341, when the map held one name or
  # `nothing` per column. Equal here, or every plan in flight is refused by `migrate`.
  @test _MG1341._schema_table_fingerprint(one) == "e968ef2e39c760fe"
  # An empty vector (an index known only as a fact) writes the `~` the `nothing` slot wrote.
  fact = _live1341(PG1341, m, String[])
  @test _MG1341._schema_table_fingerprint(fact) == "e0da3e18ee633e89"
end

# ─────────────────────────────────────────────────────────────────────────────
# What: a `db_index` column whose derived name equals a composite's — `result.driver_race` and an
# `Index` over `driver` and `race` both derive `result_driver_race_idx` — plans the same on an empty
# database and on an existing table: the composite keeps the name, the `db_index` takes the hashed one.
# A composite created under a name a live `db_index` index holds is refused at plan time.
# SQL: CREATE INDEX IF NOT EXISTS "result_driver_race_<8 hex>_idx" ON "result" ("driver_race"); beside
#      the composite's CREATE INDEX "result_driver_race_idx" ON "result" ("driver", "race");
# Why: the two used to be claimed in a different order on a new table and an existing one, so a models
# file planned on one database and was refused on another; and the composite CREATE has no
# `IF NOT EXISTS`, so a name a live `db_index` index held failed at `migrate`, inside its transaction.
# ─────────────────────────────────────────────────────────────────────────────
@testset "a db_index name that a composite derives too: one answer everywhere (#1341)" begin
  model(ix) = _M1341.Model("result"; resultid = _M1341.IDField(), driver = _M1341.IntegerField(),
                           race = _M1341.IntegerField(),
                           driver_race = _M1341.IntegerField(db_index = true),
                           indexes = ix ? [_M1341.Index(fields = ("driver", "race"))] : _M1341.Index[])
  hashed = r"^CREATE INDEX IF NOT EXISTS \"result_driver_race_[0-9a-f]{8}_idx\" ON \"result\" \(\"driver_race\"\);$"
  fresh = _plan1341(PG1341, LiveTable1341[], model(true))[:result]
  @test occursin(hashed, fresh["Create index on driver_race"])
  @test occursin("\"result_driver_race_idx\" ON \"result\" (\"driver\", \"race\")", fresh["Create index: result_driver_race_idx"])
  # The existing table, nothing indexed yet: the same two statements.
  bare = _MG1341.live_table(model(false), PG1341)
  existing = _plan1341(PG1341, [LiveTable1341(bare.name, bare.columns, Dict{String, Vector{String}}())], model(true))[:result]
  @test existing["Create index on driver_race"] == fresh["Create index on driver_race"]
  @test existing["Create index: result_driver_race_idx"] == fresh["Create index: result_driver_race_idx"]
  # The `db_index` index is live under the derived name already: the composite cannot take it.
  held = LiveTable1341(bare.name, bare.columns, Dict{String, Vector{String}}("driver_race" => ["result_driver_race_idx"]))
  err = try; _plan1341(PG1341, [held], model(true)); nothing; catch e; e; end
  @test err isa PormG.InvalidMigrationError
  @test occursin("db_index index of column 'driver_race'", sprint(showerror, err))

  # Across two tables — `result_driver.race` (`db_index`) and `result`'s `Index` over `driver` and
  # `race` derive one name — the answer must not depend on which table the live catalog lists first.
  other = _M1341.Model("result_driver"; id = _M1341.IDField(), race = _M1341.IntegerField(db_index = true))
  owner = _M1341.Model("result"; resultid = _M1341.IDField(), driver = _M1341.IntegerField(),
                       race = _M1341.IntegerField(), indexes = [_M1341.Index(fields = ("driver", "race"))])
  bare_t(m) = (t = _MG1341.live_table(m, PG1341); LiveTable1341(t.name, t.columns, Dict{String, Vector{String}}()))
  plain_owner = _M1341.Model("result"; resultid = _M1341.IDField(), driver = _M1341.IntegerField(),
                             race = _M1341.IntegerField())
  for live in ([bare_t(plain_owner), bare_t(other)], [bare_t(other), bare_t(plain_owner)])
    plan = _plan1341(PG1341, live, owner, other)
    @test occursin("\"result_driver_race_idx\" ON \"result\" (\"driver\", \"race\")", plan[:result]["Create index: result_driver_race_idx"])
    @test occursin(r"\"result_driver_race_[0-9a-f]{8}_idx\" ON \"result_driver\"", plan[:result_driver]["Create index on race"])
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# What: renaming an indexed column whose index has copies keeps the copy and drops the extras, keyed
# on the PRE-rename column the catalog knows.
# SQL: ALTER TABLE "result" RENAME COLUMN "grid" TO "position"; and
#      DROP INDEX IF EXISTS "result_grid_s21bkzlw_idx"; — no CREATE INDEX.
# Why: the rename branch reads `live.indexes` by the old column (#556); reading the new one would
# see no index, plan a CREATE on top of the copies and leave them all.
# ─────────────────────────────────────────────────────────────────────────────
@testset "a renamed column drops its index's extra copies, keeps the index (#1341)" begin
  old = _result1341(db_index = true)
  new = _M1341.Model("result"; resultid = _M1341.IDField(), position = _M1341.IntegerField(db_index = true),
                     points = _M1341.FloatField(default = 0.0))
  live = _live1341(PG1341, old, ["result_grid_idx", "result_grid_s21bkzlw_idx"])
  plan = _MG1341.get_migration_plan([live], _schema1341(new), PG1341, _settings1341(); interactive = false,
                                    renames = ["result.grid" => "result.position"])
  steps = Dict(_steps1341(plan))
  @test steps["Remove duplicate index result_grid_s21bkzlw_idx on position"] == "DROP INDEX IF EXISTS \"result_grid_s21bkzlw_idx\";"
  @test !any(startswith("Create index"), keys(steps))
  @test !haskey(steps, "Remove index on position")
  @test any(v -> occursin("RENAME COLUMN \"grid\" TO \"position\"", v), values(steps))
end

# ─────────────────────────────────────────────────────────────────────────────
# What: the SQLite reader returns every identical copy, and the plan drops the extras; applied, the
# next plan is empty.
# SQL: three `CREATE INDEX … ON "result" ("grid")` set up the copies; the plan is
#      DROP INDEX IF EXISTS "result_grid_s21bkzlw_idx"; and the same for "…zndqsv7m…".
# Why: the reader kept the first name an unordered query yielded (`get!`), so the copies were
# invisible to every plan.
# ─────────────────────────────────────────────────────────────────────────────
@testset "SQLite reader: every identical copy is read, the extras planned away (#1341)" begin
  mktempdir() do dir
    pool = _CP1341.SQLiteConnectionPool(joinpath(dir, "dup1341.sqlite"); pool_size = 1)
    try
      m = _result1341(db_index = true)
      plan = _MG1341.get_migration_plan(LiveTable1341[], _schema1341(m), pool, _settings1341(); interactive = false)
      for (_, sql) in plan[:result]
        _CP1341.fetch(pool, sql)
      end
      # The copies a random-suffix era left behind.
      for n in ("result_grid_zndqsv7m_idx", "result_grid_s21bkzlw_idx")
        _CP1341.fetch(pool, "CREATE INDEX \"$(n)\" ON \"result\" (\"grid\")")
      end
      live = only(_MG1341.read_live_schema(pool; include_table = ["result"]))
      @test live.indexes == Dict("grid" => ["result_grid_idx", "result_grid_s21bkzlw_idx", "result_grid_zndqsv7m_idx"])
      steps = _steps1341(_MG1341.get_migration_plan([live], _schema1341(m), pool, _settings1341(); interactive = false))
      @test steps == [
        "Remove duplicate index result_grid_s21bkzlw_idx on grid" => "DROP INDEX IF EXISTS \"result_grid_s21bkzlw_idx\";",
        "Remove duplicate index result_grid_zndqsv7m_idx on grid" => "DROP INDEX IF EXISTS \"result_grid_zndqsv7m_idx\";",
      ]
      foreach(s -> _CP1341.fetch(pool, last(s)), steps)
      after = only(_MG1341.read_live_schema(pool; include_table = ["result"]))
      @test after.indexes == Dict("grid" => ["result_grid_idx"])
      @test isempty(_steps1341(_MG1341.get_migration_plan([after], _schema1341(m), pool, _settings1341(); interactive = false)))
    finally
      _CP1341.close_pool!(pool)
    end
  end
end
