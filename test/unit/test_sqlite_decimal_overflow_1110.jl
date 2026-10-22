# =============================================================================
# A declared numeric(p, s) is applied on read on SQLite (#1110)
#
# `Cast(x, "numeric(p, s)")` over a value that needs more than `p - s` digits before the point:
# PostgreSQL raises "numeric field overflow" (SQLSTATE 22003) when the query runs, and SQLite, which
# reads `NUMERIC(p, s)` as an affinity only, returned the value as it was (`100` for `numeric(2,0)`).
# Whether a row overflows depends on its value, so nothing can refuse it when the query is built
# (#1087 refuses the literal case). The read path applies the declaration instead: on SQLite the read
# view records the declared `CDecimal(p, s)` of a `Cast` or an `output_field`, and its parser
# (`Dialect._parse_sqlite_decimal`) rounds to `s` places, half away from zero, and raises
# `StatementError` with SQLSTATE 22003 on a value too wide for `p`. Both engines then raise, on the
# same rows, with one error type. The message names the projection and the declared type, never the
# value (#971).
#
# Hermetic: mock connections and the parser itself. The live query is pinned on db_sl and db_2 in
# `test/integration/test_sql_functions.jl`.
# =============================================================================
# julia --project=test/integration test/unit/test_sqlite_decimal_overflow_1110.jl

using Test
using Decimals
using PormG
import PormG: Models, StatementError

struct Mock1110SQLite <: PormG.PormGSQLite end
struct Mock1110Postgres <: PormG.PormGPostgres end
const _SL1110 = Mock1110SQLite()
const _PG1110 = Mock1110Postgres()
PormG.backend_sqlite_version(::Mock1110SQLite) = 3045000

PormG.config["mock1110_sl"] = PormG.Configuration.Settings(
  connections = _SL1110, change_data = true, db_def_folder = "mock1110_sl")
PormG.config["mock1110_pg"] = PormG.Configuration.Settings(
  connections = _PG1110, change_data = true, db_def_folder = "mock1110_pg")

for (modname, key) in ((:M1110SL, "mock1110_sl"), (:M1110PG, "mock1110_pg"))
  @eval module $modname
  import PormG
  import PormG.Models
  Driver = Models.Model(driverid = Models.IDField(), surname = Models.CharField())
  Constructor_results = Models.Model(
    constructorresultsid = Models.IDField(),
    points = Models.DecimalField(max_digits = 10, decimal_places = 2),
  )
  PormG.Models.set_models(@__MODULE__, $key)
  end
end

const _FN1110 = PormG.Functions
parts1110(d) = (Int(d.s), d.c, Int(d.q))
function err1110(f)
  try
    f()
  catch e
    return e
  end
  return nothing
end

# The projection kinds a built query records, and the parsers the read terminals pick from them.
function built1110(mod, build!)
  q = mod.Driver.objects
  build!(q)
  PormG.QueryBuilder.query(q; show_query = :sql)
  return q
end

# ─────────────────────────────────────────────────────────────────────────────
# The parser applies the declaration: rounds to the scale, raises on a value too wide for p
# `numeric(2,0)`: 99 fits, 100 does not, 99.5 rounds to 100 first. PostgreSQL's answers for
# `x::numeric(p, s)`. They used to come back raw, so every assertion below failed before #1110.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1110: a SQLite numeric(p, s) read rounds to s and raises 22003 past p" begin
  p = PormG.value_parser(PormG.CDecimal(2, 0), _SL1110, "x")
  @test p !== nothing

  # Oversized: PostgreSQL's numeric field overflow, as data, and the message never holds the value.
  e = err1110(() -> p(100))
  @test e isa StatementError
  @test e.sqlstate == "22003"
  @test e.adapter == "SQLite"
  msg = sprint(showerror, e)
  @test occursin("`x`", msg)                        # the projection
  @test occursin("numeric(2, 0)", msg)              # the declared type
  @test !occursin("100", msg)                       # never the value (#971)
  @test err1110(() -> p(-100)) isa StatementError   # negative overflow
  @test err1110(() -> p(123.0)) isa StatementError  # a double, as SQLite returns a computed value

  # Exact fit.
  @test parts1110(p(99)) == (0, 99, 0)
  @test parts1110(p(-99)) == (1, 99, 0)

  # Rounded first, checked after: 99.5 is 100 at scale 0 (PostgreSQL overflows it too), 99.4 is 99.
  @test err1110(() -> p(99.5)) isa StatementError
  @test parts1110(p(99.4)) == (0, 99, 0)

  # Needs rounding: half away from zero on the decimal digits, as PostgreSQL rounds a numeric.
  q = PormG.value_parser(PormG.CDecimal(10, 2), _SL1110, "pts")
  @test parts1110(q(1.555)) == (0, 156, -2)
  @test parts1110(q(-1.555)) == (1, 156, -2)
  @test parts1110(q(1.005)) == (0, 101, -2)
  @test parts1110(q(2.5)) == (0, 25, -1)            # fewer places than the scale: unchanged
  @test parts1110(q(0.004)) == (0, 0, 0)            # rounds to zero, which has no sign
  @test parts1110(q(-0.004)) == (0, 0, 0)

  # Still fail-open for what it does not recognise.
  @test p(missing) === missing
  @test p("12.50") == "12.50"
  @test p(true) === true
  @test p(Inf) === Inf

  # No label (a direct call): the message still names the declared type.
  bare = err1110(() -> PormG.value_parser(PormG.CDecimal(2, 0), _SL1110)(100))
  @test bare isa StatementError && occursin("numeric(2, 0)", sprint(showerror, bare))
  @test !occursin('`', sprint(showerror, bare))

  # PostgreSQL applies the declaration itself, and its driver delivers the Decimal: no parser.
  @test PormG.value_parser(PormG.CDecimal(2, 0), _PG1110, "x") === nothing
end

# ─────────────────────────────────────────────────────────────────────────────
# The read view records the declared width on SQLite only, so the parser above is the one picked
# `Cast("driverid", "numeric(2,0)")` records `CDecimal(2, 0)` on SQLite (it was the width-less
# `CDecimal(nothing, nothing)`, read by the 15-digit computed parser, #1212) and stays width-less on
# PostgreSQL. A declaration wider than SQLite stores exactly (15 digits) stays width-less and unchecked.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1110: the read view records a declared numeric(p, s) on SQLite, and the parser names the alias" begin
  sl = built1110(M1110SL, q -> q.values("driverid", "x" => _FN1110.Cast("driverid", "numeric(2,0)")))
  @test sl.object.projection_kinds[:x] == PormG.CDecimal(2, 0)
  pg = built1110(M1110PG, q -> q.values("driverid", "x" => _FN1110.Cast("driverid", "numeric(2,0)")))
  @test pg.object.projection_kinds[:x] == PormG.CDecimal(nothing, nothing)

  wide = built1110(M1110SL, q -> q.values("driverid", "x" => _FN1110.Cast("driverid", "numeric(20,2)")))
  @test wide.object.projection_kinds[:x] == PormG.CDecimal(nothing, nothing)

  # An output_field that declares one is read the same way.
  co = built1110(M1110SL, q -> q.values("driverid", "c" => _FN1110.Coalesce("driverid", 0; output_field = "numeric(4,2)")))
  @test co.object.projection_kinds[:c] == PormG.CDecimal(4, 2)

  # The parser the read terminals (`list`, `DataFrame`) pick names the projection's alias.
  parsers = PormG.QueryBuilder._projection_parsers(sl, _SL1110)
  @test haskey(parsers, :x)
  e = err1110(() -> parsers[:x](100))
  @test e isa StatementError && e.sqlstate == "22003"
  @test occursin("`x`", sprint(showerror, e))
  @test parsers[:x](42) == Decimal(0, 42, 0)

  # The width SQLite stores exactly is the limit: 15 digits are checked, 16 are not.
  at15 = built1110(M1110SL, q -> q.values("driverid", "x" => _FN1110.Cast("driverid", "numeric(15,2)")))
  @test at15.object.projection_kinds[:x] == PormG.CDecimal(15, 2)
  at16 = built1110(M1110SL, q -> q.values("driverid", "x" => _FN1110.Cast("driverid", "numeric(16,2)")))
  @test at16.object.projection_kinds[:x] == PormG.CDecimal(nothing, nothing)

  # A row a write reads back names its field (`create()`'s read-back, `_row_to_field_keyed_dict`).
  model = M1110SL.Constructor_results
  e = err1110(() -> PormG.QueryBuilder._row_to_field_keyed_dict(
    Dict("constructorresultsid" => 1, "points" => 1.0e9), model, _SL1110))
  @test e isa StatementError && occursin("`points`", sprint(showerror, e))
end

# ─────────────────────────────────────────────────────────────────────────────
# A double is read to 15 significant digits before it is rounded to the scale
# `99.475 * 8.2` is the double `815.6949999999999`: 15 significant digits make it `815.695`, which
# rounds to `815.70`, as PostgreSQL's `float8` to `numeric` conversion (15 digits) then rounds it.
# Rounding the shortest rendering instead read `815.69`. A stored 15-digit value has the same digits
# either way.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1110: a double is rounded from its 15 significant digits, as PostgreSQL converts it" begin
  q = PormG.value_parser(PormG.CDecimal(10, 2), _SL1110, "pts")
  @test 99.475 * 8.2 == 815.6949999999999
  @test parts1110(q(99.475 * 8.2)) == (0, 8157, -1)
  @test parts1110(q(99999999.99)) == (0, 9999999999, -2)        # a stored 10-digit value, exact
  @test parts1110(PormG.value_parser(PormG.CDecimal(15, 4), _SL1110)(99999999999.9999)) == (0, 999999999999999, -4)
end

# ─────────────────────────────────────────────────────────────────────────────
# A value composed over a CTE column or a Subquery that declares numeric(p, s) is the computed number
# The plain projection of `CTE("g", "v")` over `Cast("driverid", "numeric(4,1)")` records the width on
# SQLite, so its rows are rounded and checked. `Coalesce(…, 0)`, `Least(…, 1)` and `Max(…)` over it are
# values the outer query computes from it: the width-less decimal on every engine, as before #1110
# (#1212), so they keep the `Decimal` read on SQLite. The comparison binder sees no read kind there.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1110: a value composed over a declared-decimal CTE column or Subquery stays the computed number" begin
  cast() = _FN1110.Cast("driverid", "numeric(4,1)")
  for (engine, mod) in ((:sqlite, M1110SL), (:postgres, M1110PG))
    @testset "$engine" begin
      plain = engine === :sqlite ? PormG.CDecimal(4, 1) : PormG.CDecimal(nothing, nothing)
      q = built1110(mod, q -> begin
        q.with("g" => mod.Driver.objects.values("driverid", "v" => cast()),
               join_field = "driverid" => "driverid", join_type = "INNER")
        q.values("driverid", "w" => "g__v", "c" => _FN1110.Coalesce("g__v", 0),
                 "l" => _FN1110.Least("g__v", 1), "m" => _FN1110.Max("g__v"))
      end)
      @test q.object.projection_kinds[:w] == plain
      @test q.object.projection_kinds[:c] == PormG.CDecimal(nothing, nothing)
      @test q.object.projection_kinds[:l] == PormG.CDecimal(nothing, nothing)
      @test q.object.projection_kinds[:m] == PormG.CDecimal(nothing, nothing)

      sub() = (inner = mod.Driver.objects;
               inner.filter("driverid" => PormG.QueryBuilder.OuterRef("driverid"));
               inner.values("t" => cast());
               PormG.QueryBuilder.Subquery(inner))
      s = built1110(mod, q -> q.values("driverid", "w" => sub(), "c" => _FN1110.Coalesce(sub(), 0)))
      @test s.object.projection_kinds[:w] == plain
      @test s.object.projection_kinds[:c] == PormG.CDecimal(nothing, nothing)
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# A Lag/Lead default is not covered by its column's width on SQLite
# `Lag("points", default = 999)` over a `DecimalField(10, 2)`: PostgreSQL's `lag(numeric(10,2), 1, 999)`
# is a plain `numeric` and returns `999` on the first row. On SQLite the column's width would round or
# refuse the default (#1110), so the call reads as the width-less decimal there: the same `Decimal`s
# for the column's values, and the default as it is. With no default, or a NULL one, it keeps the
# column's width; PostgreSQL records the column's width either way (#1034 step 3).
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1110: a Lag/Lead default over a decimal column reads width-less on SQLite" begin
  over = _FN1110.WindowOver(order_by = "constructorresultsid")
  kinds(mod) = (q = mod.Constructor_results.objects;
                q.values("constructorresultsid",
                         "d" => _FN1110.Lag("points", default = 999, over = over),
                         "f" => _FN1110.Lead("points", default = PormG.QueryBuilder.F("points"), over = over),
                         "z" => _FN1110.Lag("points", default = missing, over = over),
                         "n" => _FN1110.Lag("points", over = over));
                PormG.QueryBuilder.query(q; show_query = :sql);
                q.object.projection_kinds)
  sl, pg = kinds(M1110SL), kinds(M1110PG)
  @test sl[:d] == PormG.CDecimal(nothing, nothing)
  @test sl[:f] == PormG.CDecimal(nothing, nothing)
  @test sl[:z] == PormG.CDecimal(10, 2)
  @test sl[:n] == PormG.CDecimal(10, 2)
  @test all(k -> pg[k] == PormG.CDecimal(10, 2), (:d, :f, :z, :n))
  # The width-less parser reads the default as PostgreSQL returns it.
  @test PormG.value_parser(sl[:d], _SL1110, "d")(999) == Decimal(0, 999, 0)
end
