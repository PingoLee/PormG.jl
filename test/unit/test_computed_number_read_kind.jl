"""
A computed number reads back as the type it MEANS, on every engine (#1121).

PostgreSQL computes `Avg` over an integer, and every function PormG renders over `(x)::numeric`
(`Round`, `Mod`, `Sqrt`, `Abs` over a float, …), as a `numeric`, which the driver delivers as a
`Decimal`. SQLite computes the same calls as a REAL, and computes a `Sum`/`Avg`/`Abs`/`Round` over a
`DecimalField` as a REAL too. So one query read back a `Decimal` on PostgreSQL and a `Float64` on
SQLite. The type a call means is Django's `output_field`: a decimal over a `DecimalField`, a float for
`Avg`/`Mod`/`Sqrt`/`Exp`/`Ln`/`Power` over an integer, and the operand's type for `Sum`, `Abs`,
`Floor`, `Ceil` and `Round`. The build records that type as the projection's read kind
(`_numeric_read_kind`), and the read parsers turn either engine's answer into it. A declared decimal
(`Cast(x, "numeric(10,2)")`, a decimal `output_field`) is one too (#1212): its read kind is the
width-less decimal, never the declared width.

This file checks the three halves without a database: the meaning (`_output_kind`, the
`_MeaningKinds` walk), the recorder (`projection_kinds` on mock connections), and the parsers.
`test/integration/test_expression_kind_readback.jl` reads the same shapes back on both engines.

julia --project=test/integration test/unit/test_computed_number_read_kind.jl
"""

using Test
using PormG
using PormG.Models
import Decimals

const _CN_QB = PormG.QueryBuilder

struct CnMockPostgres <: PormG.PormGPostgres end
struct CnMockSQLite <: PormG.PormGSQLite end
PormG.backend_sqlite_version(::CnMockSQLite) = 3045000

PormG.config["cn_pg"] = PormG.Configuration.Settings(connections = CnMockPostgres(), change_data = true, db_def_folder = "cn_pg")
PormG.config["cn_sl"] = PormG.Configuration.Settings(connections = CnMockSQLite(), change_data = true, db_def_folder = "cn_sl")

# The F1 columns the shapes need: a float (`Result.points`), integers (`grid`, `laps`) and a
# `DecimalField` (`Constructor_results.points`), one model set per engine.
for (modname, key) in ((:CnPGModels, "cn_pg"), (:CnSLModels, "cn_sl"))
  @eval module $modname
  import PormG
  import PormG.Models
  Race = Models.Model(raceid = Models.IDField(), year = Models.IntegerField())
  Constructor_results = Models.Model(
    constructorresultsid = Models.IDField(),
    raceid = Models.ForeignKey(Race, pk_field = "raceid", on_delete = "CASCADE"),
    points = Models.DecimalField(),
  )
  Result = Models.Model(
    resultid = Models.IDField(),
    raceid = Models.ForeignKey(Race, pk_field = "raceid", on_delete = "CASCADE"),
    grid = Models.IntegerField(),
    laps = Models.IntegerField(),
    points = Models.FloatField(),
  )
  PormG.Models.set_models(@__MODULE__, $key)
  end
end
const _CN_ENGINES = ((:postgres, CnPGModels), (:sqlite, CnSLModels))

# The read kind the build records for the projection `v`.
function _cn_read_kind(model, node)
  q = model.objects
  q.values("v" => node)
  _CN_QB.query(q; show_query = :sql)
  return get(q.object.projection_kinds, :v, nothing)
end

const _CN_FLOAT = PormG.CFloat64()
const _CN_DECIMAL = PormG.CDecimal(nothing, nothing)

# ─────────────────────────────────────────────────────────────────────────────
# What a computed number means: `_output_kind`, Django's `output_field`
# `:promoting` (`Sum`, `Abs`, `Floor`, `Ceil`) and `Round` keep their operand's type, a decimal losing its
# width; `:numeric` (`Avg`, `Mod`, `Power`, `Sqrt`, `Exp`, `Ln`) is a decimal when an operand is one and a
# float otherwise. Why: it is the type every engine must read the value back as. `Avg(<integer>)` is a
# float (Django's `NumericOutputFieldMixin`), not PostgreSQL's `numeric`.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1121: _output_kind states Django's output_field per function and operand" begin
  ok(name, rule, ks...) = _CN_QB._output_kind(Val(name), rule, collect(ks))
  int, big, flt, dec = PormG.CInt32(), PormG.CInt64(), _CN_FLOAT, PormG.CDecimal(10, 2)
  # :numeric — a decimal operand makes a decimal, otherwise a float, whatever the integer width
  @test ok(:AVG, :numeric, int) == _CN_FLOAT
  @test ok(:AVG, :numeric, dec) == _CN_DECIMAL
  @test ok(:AVG, :numeric, flt) == _CN_FLOAT
  @test ok(:MOD, :numeric, int, big) == _CN_FLOAT
  @test ok(:MOD, :numeric, dec, big) == _CN_DECIMAL
  @test ok(:POWER, :numeric, big, dec) == _CN_DECIMAL
  @test ok(:SQRT, :numeric, int) == _CN_FLOAT
  # an interval stays one (`Avg` of a duration); a text operand means nothing
  @test ok(:AVG, :numeric, PormG.CInterval()) == PormG.CInterval()
  @test ok(:SQRT, :numeric, PormG.CText()) === nothing
  # :promoting — the operand's own type, the decimal's width dropped
  @test ok(:ABS, :promoting, flt) == _CN_FLOAT
  @test ok(:ABS, :promoting, int) == int
  @test ok(:SUM, :promoting, dec) == _CN_DECIMAL
  @test ok(:FLOOR, :promoting, PormG.CText()) === nothing
  # Round keeps its operand's type, although its rule is :numeric (PostgreSQL computes a `numeric`)
  @test _CN_QB._result_rule(Val(:ROUND)) === :numeric
  @test ok(:ROUND, :numeric, flt) == _CN_FLOAT
  @test ok(:ROUND, :numeric, dec) == _CN_DECIMAL
  @test ok(:ROUND, :numeric, int) == int
end

# ─────────────────────────────────────────────────────────────────────────────
# The read kind a computed number records, on both engines
# `values("v" => <shape>)` on a mock connection: `projection_kinds[:v]` is the type the call means, the
# SAME on PostgreSQL and SQLite. A shape that is not a computed number — a column, an integer meaning,
# a `Coalesce` of operands — records nothing new. Why: this record is what selects the read parser,
# so it is the whole of the fix on the build side.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1121: a computed number records the read kind it means, on both engines" begin
  F = _CN_QB.F
  cases = [
    # (base, shape, read kind)
    (:Result,              () -> _CN_QB.Avg("grid"),                _CN_FLOAT),
    (:Result,              () -> _CN_QB.Avg("points"),              _CN_FLOAT),
    (:Constructor_results, () -> _CN_QB.Avg("points"),              _CN_DECIMAL),
    (:Constructor_results, () -> _CN_QB.Sum("points"),              _CN_DECIMAL),
    (:Result,              () -> _CN_QB.Sum("points"),              _CN_FLOAT),
    (:Result,              () -> _CN_QB.Round("points", 1),         _CN_FLOAT),
    (:Constructor_results, () -> _CN_QB.Round("points", 1),         _CN_DECIMAL),
    (:Result,              () -> _CN_QB.Mod("grid", 2),             _CN_FLOAT),
    (:Result,              () -> _CN_QB.Sqrt("grid"),               _CN_FLOAT),
    (:Result,              () -> _CN_QB.Power("points", 2),         _CN_FLOAT),
    (:Result,              () -> _CN_QB.Floor("points"),            _CN_FLOAT),
    (:Constructor_results, () -> _CN_QB.Abs("points"),              _CN_DECIMAL),
    (:Constructor_results, () -> F("points") * 2,                   _CN_DECIMAL),
    (:Result,              () -> F("points") / 2,                   _CN_FLOAT),
    # arithmetic over a computed number composes its MEANING, not one engine's `numeric`
    (:Result,              () -> _CN_QB.Avg("grid") * 2,            _CN_FLOAT),
    (:Result,              () -> _CN_QB.Max(F("points") * 2),       _CN_FLOAT),
    # a value that is one of its operands', one of which is a computed number (review of #1121)
    (:Result,              () -> _CN_QB.Coalesce(_CN_QB.Avg("grid"), 0),             _CN_FLOAT),
    (:Result,              () -> _CN_QB.Greatest(_CN_QB.Avg("grid"), _CN_QB.Avg("laps")), _CN_FLOAT),
    (:Constructor_results, () -> _CN_QB.NullIf(_CN_QB.Sum("points"), 0),              _CN_DECIMAL),
    (:Result,              () -> _CN_QB.Abs(_CN_QB.Coalesce(_CN_QB.Avg("grid"), 0)),  _CN_FLOAT),
    (:Result,              () -> _CN_QB.Case([_CN_QB.When(_CN_QB.Avg("grid") > 1, then = _CN_QB.Avg("points"))], default = 0), _CN_FLOAT),
    # a declared `output_field` is the cast both engines render, and the aggregate in a `When`
    # CONDITION is not a value of the `Case`: neither is a computed number's read kind
    (:Result,              () -> _CN_QB.Coalesce(_CN_QB.Avg("grid"), 0; output_field = "float"), nothing),
    (:Result,              () -> _CN_QB.Case([_CN_QB.When(_CN_QB.Avg("grid") > 1, then = 1.5)], default = 0), nothing),
    # not a computed float or decimal: unchanged
    (:Result,              () -> _CN_QB.Sum("grid"),                nothing),
    (:Result,              () -> _CN_QB.Abs("grid"),                nothing),
    (:Result,              () -> F("grid") / F("laps"),             nothing),
    (:Result,              () -> _CN_QB.Max("points"),              nothing),
    (:Result,              () -> _CN_QB.Coalesce("grid", "points"), nothing),
    (:Result,              () -> "points",                          nothing),
  ]
  for (engine, mod) in _CN_ENGINES, (base, shape, expected) in cases
    node = shape()
    @testset "$engine: $(sprint(show, node; context = :compact => true) |> s -> first(s, 60))" begin
      @test _cn_read_kind(getfield(mod, base), node) == expected
    end
  end
  # The width-less decimal the walk records is not a column's: a `DecimalField` keeps its declared
  # width, and #648's exact parser.
  for (engine, mod) in _CN_ENGINES
    @test _cn_read_kind(mod.Constructor_results, "points") == PormG.CDecimal(10, 2)
    @test _cn_read_kind(mod.Constructor_results, _CN_QB.Max("points")) == PormG.CDecimal(10, 2)
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# A CTE column and a Subquery read as what their body computed, and the binder does not see it
# The outer projection of a CTE column (`"g__a"`) over `Avg("grid")` records `CFloat64` (the body's read kind),
# and so does a `Subquery` of one; `_operand_kind` — the comparison binder's and `_is_number_side`'s
# view (#882) — still answers `nothing` for both. Why: the read path must see the meaning, and a float
# read kind must not change how a filter against that column binds.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1121: a CTE column and a Subquery read as their computed number; the binder view is unchanged" begin
  for (engine, mod) in _CN_ENGINES
    @testset "$engine" begin
      q = mod.Result.objects
      q.with("g" => mod.Result.objects.values("resultid", "a" => _CN_QB.Avg("grid")),
             join_field = "resultid" => "resultid", join_type = "INNER")
      q.values("resultid", "v" => "g__a")
      instr = Ref{Any}(nothing)
      _CN_QB.query(q; show_query = :sql, built = i -> (instr[] = i))
      @test q.object.projection_kinds[:v] == _CN_FLOAT
      handle = instr[].object.values[findfirst(v -> _CN_QB._projection_output_name(v) == "v", instr[].object.values)].field
      @test handle isa _CN_QB.CTEReference
      @test _CN_QB._operand_kind(handle, instr[]) === nothing

      inner = mod.Result.objects
      inner.filter("resultid" => _CN_QB.OuterRef("resultid"))
      inner.values("t" => _CN_QB.Avg("grid"))
      s = mod.Result.objects
      s.values("v" => _CN_QB.Subquery(inner))
      sinstr = Ref{Any}(nothing)
      _CN_QB.query(s; show_query = :sql, built = i -> (sinstr[] = i))
      @test s.object.projection_kinds[:v] == _CN_FLOAT
      node = only(sinstr[].object.values).field
      @test _CN_QB._operand_kind(node, sinstr[]) === nothing

      # A function over a Subquery whose inner value is one of its operands' (review of #1121): the
      # inner `Coalesce` records its meaning, so the outer `Abs` composes the meaning, not one
      # engine's `numeric` — the same kind as `Abs(Coalesce(Avg("grid"), 0))` unwrapped.
      inner2 = mod.Result.objects
      inner2.filter("resultid" => _CN_QB.OuterRef("resultid"))
      inner2.values("t" => _CN_QB.Coalesce(_CN_QB.Avg("grid"), 0))
      @test _cn_read_kind(mod.Result, _CN_QB.Abs(_CN_QB.Subquery(inner2))) == _CN_FLOAT
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# A declared decimal records the width-less decimal read kind, on both engines (#1212)
# `Cast(x, "numeric(10,2)")` renders `(x)::numeric(10,2)` on PostgreSQL and `CAST(x AS NUMERIC(10,2))`
# on SQLite; `Coalesce(…; output_field = DecimalField())` wraps its call the same way. PostgreSQL's
# driver hands back a `Decimal`, SQLite its REAL (or INTEGER, over a whole operand). The record is
# `CDecimal(nothing, nothing)` — never the declared width, so SQLite reads through the 15-digit
# computed parser, not #648's exact one — and a `Coalesce` over columns that agree keeps the column's
# own kind. Why: the cast declares the type, as Django's `Cast(x, output_field=DecimalField())` does,
# and `x isa Decimal` must hold on every engine. A declared float or integer reads as it did.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1212: a declared decimal records the read kind it declares, on both engines" begin
  F = _CN_QB.F
  dec = Models.DecimalField()
  cases = [
    # (base, shape, read kind)
    (:Result,              () -> _CN_QB.Cast(F("points") * 1.5, "numeric"),                    _CN_DECIMAL),
    (:Result,              () -> _CN_QB.Cast(_CN_QB.Round(F("points") * 1.5, 2), "numeric(10,2)"), _CN_DECIMAL),
    (:Constructor_results, () -> _CN_QB.Cast("points", "numeric(10,2)"),                       _CN_DECIMAL),
    (:Result,              () -> _CN_QB.Cast("grid", dec),                                     _CN_DECIMAL),
    (:Result,              () -> _CN_QB.Cast("grid", "decimal"),                               _CN_DECIMAL),
    (:Result,              () -> _CN_QB.Coalesce(F("points") * 1.5, 0; output_field = dec),    _CN_DECIMAL),
    (:Result,              () -> _CN_QB.Greatest("points", "grid"; output_field = dec),        _CN_DECIMAL),
    (:Result,              () -> _CN_QB.Least("grid", "laps"; output_field = "numeric(10,2)"), _CN_DECIMAL),
    (:Result,              () -> _CN_QB.Case([_CN_QB.When("grid" => 1, then = 1.5)], default = 0, output_field = dec), _CN_DECIMAL),
    # a value over a declared decimal composes it, and drops the declared width
    (:Result,              () -> _CN_QB.Max(_CN_QB.Cast(_CN_QB.Round(F("points") * 1.5, 2), "numeric(10,2)")), _CN_DECIMAL),
    (:Result,              () -> _CN_QB.NullIf(_CN_QB.Cast("grid", dec), 0),                   _CN_DECIMAL),
    (:Result,              () -> _CN_QB.Cast("grid", dec) * 2,                                 _CN_DECIMAL),
    # columns that agree on the declared decimal keep their own kind, and #648's exact parser
    (:Constructor_results, () -> _CN_QB.Coalesce("points", "points"; output_field = dec),      PormG.CDecimal(10, 2)),
    # a declared float or integer is not a decimal: unchanged
    (:Result,              () -> _CN_QB.Cast("grid", "float8"),                                nothing),
    (:Result,              () -> _CN_QB.Cast("grid", "integer"),                               nothing),
    (:Result,              () -> _CN_QB.Coalesce(F("points") * 1.5, 0; output_field = "float"), nothing),
  ]
  for (engine, mod) in _CN_ENGINES, (base, shape, expected) in cases
    node = shape()
    @testset "$engine: $(sprint(show, node; context = :compact => true) |> s -> first(s, 60))" begin
      @test _cn_read_kind(getfield(mod, base), node) == expected
    end
  end
  # The kind selects the computed parser on SQLite (15 significant digits, an INTEGER to a `Decimal`),
  # never the width-bound one, and PostgreSQL's `Decimal` passes through.
  @test PormG.value_parser(_CN_DECIMAL, CnMockSQLite()) === PormG.Dialect._parse_sqlite_computed_decimal
  @test PormG.value_parser(_CN_DECIMAL, CnMockPostgres()) === nothing
end

# ─────────────────────────────────────────────────────────────────────────────
# A declared decimal in a CTE body or a Subquery reads as one outside it; the binder view is unchanged
# A CTE column over `Cast(Round(F("points") * 1.5, 2), "numeric(10,2)")` — the body renders
# `(ROUND((("points" * $1::double precision))::numeric, $2::integer))::numeric(10,2)` on PostgreSQL,
# `CAST(ROUND(("points" * ?), ?) AS NUMERIC(10,2))` on SQLite — and a `Subquery` projecting it record `CDecimal(nothing, nothing)` for the outer
# projection, while `_operand_kind` — the comparison binder's view (#882) — still answers `nothing`. Why: the read kind is the read path's alone
# (`_without_numeric_read`); a filter against the column must bind exactly as it did before #1212.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1212: a declared decimal in a CTE or a Subquery reads as one; the binder view is unchanged" begin
  cast() = _CN_QB.Cast(_CN_QB.Round(_CN_QB.F("points") * 1.5, 2), "numeric(10,2)")
  for (engine, mod) in _CN_ENGINES
    @testset "$engine" begin
      q = mod.Result.objects
      q.with("g" => mod.Result.objects.values("resultid", "a" => cast()),
             join_field = "resultid" => "resultid", join_type = "INNER")
      q.values("resultid", "v" => "g__a")
      instr = Ref{Any}(nothing)
      _CN_QB.query(q; show_query = :sql, built = i -> (instr[] = i))
      @test q.object.projection_kinds[:v] == _CN_DECIMAL
      handle = instr[].object.values[findfirst(v -> _CN_QB._projection_output_name(v) == "v", instr[].object.values)].field
      @test _CN_QB._operand_kind(handle, instr[]) === nothing

      inner = mod.Result.objects
      inner.filter("resultid" => _CN_QB.OuterRef("resultid"))
      inner.values("t" => cast())
      s = mod.Result.objects
      s.values("v" => _CN_QB.Subquery(inner))
      sinstr = Ref{Any}(nothing)
      _CN_QB.query(s; show_query = :sql, built = i -> (sinstr[] = i))
      @test s.object.projection_kinds[:v] == _CN_DECIMAL
      @test _CN_QB._operand_kind(only(sinstr[].object.values).field, sinstr[]) === nothing
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# The parsers: a computed decimal on SQLite, a computed float on every engine
# `value_parser(CDecimal(nothing, nothing), SQLite)` builds the `Decimal` from SQLite's double through
# 15 significant digits (Django's `create_decimal_from_float`), and `value_parser(CFloat64, …)` turns
# PostgreSQL's `Decimal` (and SQLite's whole INTEGER) into a `Float64`. Both are fail-open. Why: these
# are what make the two engines' values one type; a declared-width decimal column keeps #648's
# exact parser, which refuses a value it cannot have stored.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1121: the computed-number parsers, and which kind selects them" begin
  sl, pg = CnMockSQLite(), CnMockPostgres()
  dec(s) = parse(Decimals.Decimal, s)
  pdec = PormG.value_parser(_CN_DECIMAL, sl)
  @test pdec !== nothing
  @test PormG.value_parser(_CN_DECIMAL, pg) === nothing          # LibPQ delivers a Decimal already
  @test pdec(0.1 + 0.2) isa Decimals.Decimal
  @test pdec(0.1 + 0.2) == dec("0.3")                             # not 0.30000000000000004
  @test string(pdec(11.0)) == "11"
  @test pdec(11) == dec("11")                                     # SQLite stored a whole value as INTEGER
  @test pdec(5.5) == dec("5.5")
  @test pdec(-2.75) == dec("-2.75")
  @test pdec(-0.0) == dec("0")
  @test pdec(2.718281828459045) == dec("2.71828182845905")        # 15 significant digits
  @test pdec(3.3333333333333333e-21) == Decimals.Decimal(0, 333333333333333, -35)
  @test pdec(1.0e20) == Decimals.Decimal(0, big(10)^20, 0)   # canonical: never a positive exponent
  @test ismissing(pdec(missing))
  @test pdec(true) === true
  @test isnan(pdec(NaN))
  @test pdec("text") == "text"
  # a column's declared width is still #648's exact parser: a value it cannot have stored stays raw
  exact = PormG.value_parser(PormG.CDecimal(10, 2), sl)
  @test exact(0.1 + 0.2) === 0.1 + 0.2

  for conn in (pg, sl)
    pf = PormG.value_parser(_CN_FLOAT, conn)
    @test pf !== nothing
    @test pf(dec("1.00")) === 1.0
    @test pf(dec("22026.465794806716516957900645")) === 22026.465794806718   # nearest, through the text
    @test pf(3) === 3.0
    @test pf(2.5) === 2.5
    @test pf(true) === true
    @test ismissing(pf(missing))
    @test pf("text") == "text"
    # past the double's range: ±Inf and ±0.0, as Python's `float()` gives Django — never the Decimal
    @test pf(Decimals.Decimal(0, 1, 400)) === Inf
    @test pf(Decimals.Decimal(1, 1, 400)) === -Inf
    @test pf(Decimals.Decimal(0, 1, -400)) === 0.0
    @test pf(Decimals.Decimal(1, 1, -400)) === -0.0
  end
end
