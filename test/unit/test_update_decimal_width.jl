"""
An expression `update` writes into a `DecimalField(p, s)` raises 22003 on SQLite for a row whose value
needs more than `p - s` digits before the point, and writes nothing (#1330).

The column is `numeric(p, s)`. PostgreSQL and MySQL refuse such a value when the `UPDATE` runs ("numeric
field overflow", SQLSTATE 22003). SQLite's NUMERIC affinity stored it, and since #1110 every later read
of the row raised the same error, in a different call. Whether a row overflows depends on its value, so
nothing refuses it at build (#1279 checks the scale, #761 a literal). On SQLite the SET value renders a
guard instead (`Dialect.decimal_assignment_guard_sql`):

    CASE WHEN abs(CAST(replace(printf('%.14e', x), 'Inf', '9e999') AS REAL)) < <10^(p-s) - 0.5·10^-s> THEN x
         ELSE abs(CAST(x AS INTEGER) * 0 - 9223372036854775807 - 1) END

which takes the 15 significant digits the #1110 read takes, so a row the guard lets through always reads
back, and raises SQLite's "integer overflow", reported as 22003, on a row that does not fit. It names `x`
three times, so `x`'s values are bound three times, in step.

The SQL is pinned on mock connections; the raise, on a real SQLite database in a temporary directory.

julia --project=test/integration test/unit/test_update_decimal_width.jl
"""

using Test
using DataFrames
using Logging
import Decimals
using PormG
using PormG.Models
# Standalone runs need the SQLite extension for the real-engine half (runtests.jl loads it too).
include(joinpath(@__DIR__, "..", "load_drivers.jl"))
import PormG.ConnectionPool: fetch, SQLiteConnectionPool
import PormG: StatementError

# Dedicated config key + mock types: `runtests.jl` includes every unit file into one `Main`.
struct UdwMockSQLite <: PormG.PormGSQLite end
struct UdwMockPostgres <: PormG.PormGPostgres end
struct UdwMockMySQL <: PormG.PormGMySQL end
const _UDW_SL = UdwMockSQLite()
const _UDW_PG = UdwMockPostgres()
const _UDW_MY = UdwMockMySQL()
PormG.backend_sqlite_version(::UdwMockSQLite) = 3045000

PormG.config["udw_mock"] = PormG.Configuration.Settings(
  connections = _UDW_SL, change_data = true, db_def_folder = "udw_mock",
)

module UdwModels
import PormG
import PormG.Models

Udw_constructor = Models.Model("udw_constructor",
  constructorid = Models.IDField(),
  wins          = Models.IntegerField(null = true),
)
Udw_result = Models.Model("udw_result",
  resultid      = Models.IDField(),
  constructorid = Models.ForeignKey(Udw_constructor, on_delete = "CASCADE", null = true),
  grid          = Models.IntegerField(null = true),
  milliseconds  = Models.FloatField(null = true),
  narrow        = Models.DecimalField(max_digits = 4, decimal_places = 2, null = true),
  whole         = Models.DecimalField(max_digits = 3, decimal_places = 0, null = true),
  exact         = Models.DecimalField(max_digits = 15, decimal_places = 2, null = true),
  wide          = Models.DecimalField(max_digits = 16, decimal_places = 2, null = true),
)

PormG.Models.set_models(@__MODULE__, "udw_mock")
end

const UDW = UdwModels
const _UdwFn = PormG.Functions
# Not `F`: `runtests.jl` includes every unit file into one `Main`, where `F` is already imported.
const _UF = PormG.QueryBuilder.F

# The statement `update` builds for one pair on `conn`, whitespace collapsed, and its parameters.
function _udw_update(field, value; conn, model = UDW.Udw_result, inner = nothing)
  q = model.objects
  inner === nothing || q.on(inner, join_type = "INNER")   # a nullable path read by SET (#1430)
  q.filter("resultid" => 1)
  q.object.insert[field] = value
  res = PormG.QueryBuilder.update(q.object; connection = conn, show_query = :dict)
  return replace(res[:sql_text], r"\s+" => " ") |> strip, res[:parameters]
end

_udw_guard(x, edge) = "CASE WHEN abs(CAST(replace(printf('%.14e', $(x)), 'Inf', '9e999') AS REAL)) < $(edge) THEN $(x) " *
                      "ELSE abs(CAST($(x) AS INTEGER) * 0 - 9223372036854775807 - 1) END"

@testset "update: an expression into a DecimalField renders the width guard on SQLite (#1330)" begin
  # What: `update("narrow" => F("grid") * 100)` into DecimalField(4, 2) builds on SQLite
  # `SET "narrow" = CASE WHEN abs(CAST(replace(printf('%.14e', ("Tb"."grid" * ?)), 'Inf', '9e999') AS REAL)) < 99.995 THEN ("Tb"."grid" * ?)
  # ELSE abs(CAST(("Tb"."grid" * ?) AS INTEGER) * 0 - 9223372036854775807 - 1) END`, the factor bound three
  # times ahead of the WHERE's 1. PostgreSQL and MySQL keep `SET "narrow" = ("Tb"."grid" * $2::bigint)`: their column
  # refuses the value itself. Why: SQLite stored `2000` into a numeric(4, 2) column, which every later read
  # of the row refused (#1110); one bind for three markers would misbind silently.
  sql, params = _udw_update("narrow", _UF("grid") * 100; conn = _UDW_SL)
  x = "(\"Tb\".\"grid\" * ?)"
  @test sql == "UPDATE \"udw_result\" AS \"Tb\" SET \"narrow\" = $(_udw_guard(x, "99.995")) " *
               "WHERE \"Tb\".\"resultid\" = ?"
  @test params == Any[100, 100, 100, 1]
  sql, params = _udw_update("narrow", _UF("grid") * 100; conn = _UDW_PG)
  @test sql == "UPDATE \"udw_result\" AS \"Tb\" SET \"narrow\" = (\"Tb\".\"grid\" * \$2::bigint) " *
               "WHERE \"Tb\".\"resultid\" = \$1"
  @test params == Any[1, 100]
  sql, params = _udw_update("narrow", _UF("grid") * 100; conn = _UDW_MY)
  @test sql == "UPDATE `udw_result` AS `Tb` SET `narrow` = (`Tb`.`grid` * ?) WHERE `Tb`.`resultid` = ?"
  @test params == Any[100, 1]
end

@testset "update: the guard's edge is the smallest value numeric(p, s) refuses (#1330)" begin
  # What: the edge is `10^(p-s) - 0.5·10^-s` as decimal text: 99.995 for (4, 2), 999.5 for (3, 0). A
  # column with no bound value names no marker. Why: PostgreSQL rounds to `s` before it checks the width,
  # so `99.995` into numeric(4, 2) is `100.00`, an overflow, and `99.994` is `99.99`, which fits.
  sql, params = _udw_update("whole", _UF("grid"); conn = _UDW_SL)
  @test occursin("SET \"whole\" = $(_udw_guard("\"Tb\".\"grid\"", "999.5")) WHERE", sql)
  @test params == Any[1]
  @test PormG.Dialect.decimal_assignment_guard_sql(_UDW_SL, "x", 4, 2) == (_udw_guard("x", "99.995"), 3)
  @test PormG.Dialect.decimal_assignment_guard_sql(_UDW_SL, "x", 2, 2) == (_udw_guard("x", "0.995"), 3)
  @test PormG.Dialect.decimal_assignment_guard_sql(_UDW_SL, "x", 15, 0) ==
    (_udw_guard("x", "999999999999999.5"), 3)
end

@testset "update: the guard covers a joined column and a Subquery, bound in step (#1330)" begin
  # What: `F("constructorid__wins")` renders `"R1"."wins"` three times through UPDATE … FROM; a
  # `Subquery` names its SELECT three times, its values bound once per occurrence, all ahead of the WHERE's
  # 1. Why: those are the other two SET shapes that reach this arm, and the Subquery's values come from a
  # nested run the guard must bind again whole.
  sql, params = _udw_update("narrow", _UF("constructorid__wins"); conn = _UDW_SL, inner = "constructorid")
  @test count("abs(CAST(replace(printf('%.14e', ", sql) == 1 && count("\"wins\"", sql) == 3
  @test params == Any[1]
  s = UDW.Udw_constructor.objects
  s.filter("constructorid" => PormG.QueryBuilder.OuterRef("constructorid"), "wins" => 7)
  s.values("wins")
  s.limit(1)
  sql, params = _udw_update("narrow", PormG.QueryBuilder.Subquery(s); conn = _UDW_SL)
  @test count("(SELECT", sql) == 3 && count(==('?'), sql) == 7
  @test params == Any[7, 1, 7, 1, 7, 1, 1]
  sql, params = _udw_update("narrow", PormG.QueryBuilder.Subquery(s); conn = _UDW_PG)
  @test count("(SELECT", sql) == 1 && params == Any[1, 7, 1]
end

@testset "update: no guard for a literal, a field of another type, or a field SQLite reads unchecked (#1330)" begin
  # What: a literal still binds once (`DecimalValidator` checks it on every engine, #761); an expression
  # into an IntegerField or FloatField renders as it is; a DecimalField of 16 digits renders as it is too,
  # where one of 15 is guarded. Why: only a decimal declaration has a width to apply, and past 15 digits
  # SQLite stores no value exactly and its read applies no width either (#648, #1110).
  sql, params = _udw_update("narrow", 12.5; conn = _UDW_SL)
  @test sql == "UPDATE \"udw_result\" AS \"Tb\" SET \"narrow\" = ? WHERE \"Tb\".\"resultid\" = ?"
  @test params == Any["12.5", 1]   # a decimal binds as its text
  for (field, value) in (("grid", _UF("grid") * 100), ("milliseconds", _UF("grid") * 100),
                         ("wide", _UF("grid") * 100))
    sql, _ = _udw_update(field, value; conn = _UDW_SL)
    @test !occursin("printf", sql)
  end
  sql, _ = _udw_update("exact", _UF("grid") * 100; conn = _UDW_SL)
  @test occursin("SET \"exact\" = $(_udw_guard("(\"Tb\".\"grid\" * ?)", "9999999999999.995")) WHERE", sql)
end

# ─────────────────────────────────────────────────────────────────────────────
# A real SQLite database: the overflowing row raises 22003, and the statement writes nothing
# ─────────────────────────────────────────────────────────────────────────────
function udw_with_sqlite(f)
  mktempdir() do dir
    pool = SQLiteConnectionPool(joinpath(dir, "udw1330.sqlite"); pool_size = 1)
    key = "udw_sqlite"
    PormG.config[key] = PormG.Configuration.Settings(connections = pool, db_def_folder = dir, change_data = true)
    try
      fetch(pool, """CREATE TABLE udw_result (resultid INTEGER PRIMARY KEY, grid INTEGER,
                     milliseconds REAL, narrow NUMERIC(4,2));""")
      fetch(pool, """INSERT INTO udw_result (resultid, grid, milliseconds, narrow) VALUES
                     (1, 20, 99.995, 1), (2, 0, 99.994, 1), (3, NULL, -99.995, 1), (4, -20, NULL, 1),
                     (5, 1, 0.5, 1);""")
      model = Models.Model("udw_result", resultid = Models.IDField(), grid = Models.IntegerField(null = true),
                           milliseconds = Models.FloatField(null = true),
                           narrow = Models.DecimalField(max_digits = 4, decimal_places = 2, null = true))
      model.connect_key = key
      f(pool, model)
    finally
      delete!(PormG.config, key)
      PormG.ConnectionPool.close_pool!(pool)   # release the handle so mktempdir can clean up (Windows)
    end
  end
end

# `update` logs the statement it failed to execute; the failure is the expectation here.
udw_err(f) = Logging.with_logger(Logging.NullLogger()) do
  try f(); nothing catch e; e end
end
udw_overflow(e) = e isa StatementError && e.sqlstate == "22003"
udw_raw(pool) = [r.narrow for r in eachrow(fetch(pool, "SELECT narrow FROM udw_result ORDER BY resultid;") |> DataFrame)]

@testset "update: SQLite raises 22003 on the row too wide for the DecimalField, and writes nothing (#1330)" begin
  # What: `F("grid") * 100` into DecimalField(4, 2): grid 20 (2000) and -20 raise StatementError with
  # sqlstate 22003; a statement over every row raises and leaves every row as it was; grid 1 (100) raises
  # too; grid 0 stores 0 and a NULL grid stores NULL. `Round(F("milliseconds"), 2)`: 99.994 stores 99.99,
  # and 99.995 and -99.995, which round to ±100.00, raise. Why: before #1330 SQLite stored 2000, and the
  # row then raised 22003 on every read (#1110); PostgreSQL refuses the UPDATE.
  udw_with_sqlite() do pool, model
    q(id) = model.objects.filter("resultid" => id)
    for id in (1, 4, 5)
      @test udw_overflow(udw_err(() -> q(id).update("narrow" => _UF("grid") * 100)))
    end
    @test udw_overflow(udw_err(() -> model.objects.filter("resultid__@gte" => 1).update("narrow" => _UF("grid") * 100)))
    @test udw_raw(pool) == [1, 1, 1, 1, 1]
    @test q(2).update("narrow" => _UF("grid") * 100) == 1
    @test q(3).update("narrow" => _UF("grid") * 100) == 1
    @test isequal(udw_raw(pool), [1, 0, missing, 1, 1])
    @test q(2).update("narrow" => _UdwFn.Round(_UF("milliseconds"), 2)) == 1
    @test only(q(2).values("narrow").list())[:narrow] == Decimals.decimal("99.99")
    for id in (1, 3)
      @test udw_overflow(udw_err(() -> q(id).update("narrow" => _UdwFn.Round(_UF("milliseconds"), 2))))
    end
    # A double that overflows to ±Inf prints as `Inf`, which SQLite reads back as 0.0: still refused.
    for factor in (1e308, -1e308)
      @test udw_overflow(udw_err(() -> q(2).update("narrow" => _UdwFn.Round(_UF("milliseconds") * factor * 10, 2))))
    end
    # A row that fits is written while the guard's raising arm is never reached: no row matched, or all fit.
    @test model.objects.filter("resultid" => 99).update("narrow" => _UF("grid") * 100) == 0
    @test model.objects.filter("resultid__@in" => [2, 3]).update("narrow" => _UF("grid") * 4) == 2
    @test isequal(udw_raw(pool)[1:3], [1, 0, missing])
  end
end
