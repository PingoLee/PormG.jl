# ============================================================
# test/unit/test_app_terminals_trim_1599.jl
#
# CONTRACT being tested:
#   The terminals retyped for a trimmed binary (#1599 layer 6) answer as before. `count()` reads its one cell where the driver's result is concrete (`QueryBuilder._FirstCell`, #1599 layer 6) and
#   returns what it returned before, when it read the cell from `fetch`'s result through `hasmethod` and
#   `Tables.rowtable` (`QueryBuilder._first_cell_any`, the old expression, kept as is):
#     - on SQLite, the worker's read of the first cell (`_sqlite_first_cell`) is the value and type the old expression
#       took from the materialized rows, for a count with and without bound parameters;
#     - on MySQL, the extension's read of a `MySQLResult` is the old expression's answer, for an `Int64` column, a
#       column with `missing`, a column of another type (the open arm) and a result with no row;
#     - `count()` itself answers as before on a real SQLite pool;
#     - a raw `fetch`'s parameters bind on SQLite through `_sqlite_bind_manual` as they did through `sqlite_bind_value`
#       on each value read as `Any`: the same bound value and type, or the same refusal, for every value type.
#   Postgres.jl's method reads `ResultRow.data`; a `Postgres.Result` is not built by hand here, so its equivalence is
#   the integration suite's `count()` calls under `PORMG_POSTGRES_DRIVER=Postgres`.
#
# Hermetic: an in-memory SQLite database and hand-built MySQL results; no server.
#
# Run: julia --project=test/integration test/unit/test_app_terminals_trim_1599.jl
# ============================================================

using Test
isdefined(Main, :SQLite) || include(joinpath(@__DIR__, "..", "load_drivers.jl"))
using PormG
using Dates, UUIDs

const _AT_QB = PormG.QueryBuilder
const _AT_MY = Base.get_extension(PormG, :PormGMySQLExt)

module AtModels
import PormG
import PormG.Models
At_race::Models.ModelType = Models.Model("at_race",
  raceid = Models.IDField(),
  year   = Models.IntegerField(),
  round  = Models.IntegerField(),
  name   = Models.CharField(max_length = 80),
)
Models.@models At_race
end

_at_outcome(f) = try
  (:value, f())
catch e
  (:raised, typeof(e), sprint(showerror, e))
end

@testset "the app's terminals answer as before under their trimmed paths (#1599 layer 6)" begin

  # What: `count()` on a real SQLite pool, and its cell read both ways.
  # Expected: the same value and type through `_fetch_first_cell` as through the old expression over `fetch`'s rows.
  # Why: the trimmed read replaced the old expression on every PormG pool; a count is what the caller reads.
  @testset "SQLite: the worker's first cell is the old expression's" begin
    dir = mktempdir()
    PormG.Configuration.register_connection("at_sqlite", joinpath(dir, "f1.sqlite"); adapter = "SQLite", env = "prod",
                                            pool_size = 1, change_db = true, change_data = true)
    PormG.Models.set_models(AtModels; key = "at_sqlite")
    R = AtModels.At_race
    PormG.Migrations.ensure_table!(R, "at_sqlite")
    for (y, rd) in ((2008, 6), (2008, 18), (2009, 6))
      R.objects.create("year" => y, "round" => rd, "name" => "Grand Prix $(y) $(rd)")
    end
    settings = PormG.Configuration.get_settings("at_sqlite")
    sql = "SELECT COUNT(*) FROM at_race"
    old = _AT_QB._first_cell_any(fetch(settings, sql))
    new = _AT_QB._fetch_first_cell(settings, sql, nothing)
    @test (new, typeof(new)) == (old, typeof(old)) == (3, Int64)
    # With bound parameters, through `count()`'s own collector.
    q = R.objects.filter("year" => 2008, "round__@gte" => 6)
    @test q.count() === 2
    @test R.objects.filter("year" => 1900).count() === 0
    @test R.objects.filter("year" => 2008).values("year").distinct().count() === 1
    @test R.objects.filter("round" => 6).limit(1).count() === 1
    # A statement with no row takes the old expression, so it raises as the old read did.
    @test _at_outcome(() -> _AT_QB._fetch_first_cell(settings, "SELECT 1 WHERE 0", nothing))[1] ==
          _at_outcome(() -> _AT_QB._first_cell_any(fetch(settings, "SELECT 1 WHERE 0")))[1]
    PormG.Configuration.close_pool!("at_sqlite")
  end

  # What: the MySQL extension's read of a `MySQLResult`, against the old expression over the same result.
  # Expected: the same answer (value and type, or the same refusal) for each column shape.
  # Why: the extension reads `columns[1][1]` at the column's type; the old expression read the first row's first cell
  #   through `Tables.rowtable`.
  @testset "MySQL: the extension's first value is the old expression's" begin
    @test _AT_MY !== nothing
    if _AT_MY !== nothing
      MR = _AT_MY.MySQLResult
      cases = (MR([Symbol("COUNT(*)")], AbstractVector[Int64[7]], 1, 0, UInt64(0), ""),
               MR([Symbol("COUNT(*)")], AbstractVector[Union{Missing, Int64}[7]], 1, 0, UInt64(0), ""),
               MR([:n], AbstractVector[Int32[5]], 1, 0, UInt64(0), ""),
               MR([:n], AbstractVector[Int64[]], 0, 0, UInt64(0), ""))
      for r in cases
        @test (eltype(r.columns[1]), _at_outcome(() -> _AT_QB._FirstCell()(r))) ==
              (eltype(r.columns[1]), _at_outcome(() -> _AT_QB._first_cell_any(r)))
      end
      @test _AT_QB._FirstCell()(cases[1]) === 7
      @test _AT_QB._FirstCell()(cases[3]) === Int32(5)
    end
  end

  # What: `_sqlite_bind_manual` against `sqlite_bind_value` (the bind it wraps) over every value type a raw array can
  #   carry, and `_normalize_manual_params` against the comprehension it replaced.
  # Expected: the same bound value and type, or the same refusal, for each value.
  # Why: the walk replaced a call made at run time on each raw value; a different bind would store a different value.
  @testset "SQLite: a raw parameter binds as sqlite_bind_value bound it" begin
    CP = PormG.ConnectionPool
    pool = CP.SQLiteConnectionPool(":memory:")
    values = Any[Int64(7), "Monaco Grand Prix", 2.5, true, missing, Int32(5), Date(2008, 5, 25), DateTime(2008, 5, 25, 14),
                 UInt8[0x01, 0x02], Int16(3), UUID("4c1a4c55-9b3f-4a6e-8f00-1fa7a9b0c0de"), Time(14, 0),
                 typemax(Int128), Float32(1.5), SubString("Monaco", 1, 3), Dates.Hour(2)]
    for v in values
      # `isequal`, not `==`: a `missing` value would make `==` return `missing`.
      @test isequal((typeof(v), _at_outcome(() -> CP._sqlite_bind_manual(v, pool))),
                    (typeof(v), _at_outcome(() -> PormG.sqlite_bind_value(v, pool))))
      r = _at_outcome(() -> CP._sqlite_bind_manual(v, pool))
      r[1] === :value && @test typeof(r[2]) === typeof(PormG.sqlite_bind_value(v, pool))
    end
    old_norm(params, conn) = Any[PormG.sqlite_bind_value(v, conn) for v in CP._normalize_manual_params(params)]
    for params in (Any[2008, "Monaco Grand Prix"], [1, 2, 3], (2008, nothing, Date(2008, 5, 25)), Any[])
      @test isequal(_at_outcome(() -> CP._normalize_manual_params(params, pool)), _at_outcome(() -> old_norm(params, pool)))
    end
    @test _at_outcome(() -> CP._normalize_manual_params(Any[typemax(Int128)], pool)) ==
          _at_outcome(() -> old_norm(Any[typemax(Int128)], pool))
  end
end
