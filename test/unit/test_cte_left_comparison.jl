"""
The operators on a `CTE(...)` column handle: comparisons with the handle on the LEFT (#1529) and
arithmetic, with the handle on either side (#1539).

`CTE("g", "n")` had no comparison methods, so on the left of an operator it fell through to Base:
`CTE("g", "n") == 5` answered a bare `false` (from `Base.==`), which `filter` then reported, and
`CTE("g", "n") > 5` was a raw `MethodError` from `isless`. That is the #536 defect class, closed then
for `F`, `Joined` and the functions by giving each a comparison family and an `isequal` that stays
total; `CTEReference` got neither. As the right side (`F("x") == CTE(…)`, #444) it already worked.

Pinned here:

  1. Each of the six comparisons builds an `FExpression` whose filter renders the predicate the filter
     pair `"g__n__@<op>" => x` renders, with the same parameters, on PostgreSQL and SQLite, against a
     value and against a column. (`F("g__n")` is no oracle: a `__` path cannot reach a declared CTE
     from an `F`, #492, so the handle is the only operator spelling there is.)
  2. `isequal` stays total, so a handle keys a `Dict` and a `Set`.
  3. An operand outside the comparison vocabulary, `missing` and `desc = true` raise `QueryBuildError`.
  4. A CTE column over a JSON key on the left compares as the key lookup does (#1511), as the pair
     `"g__k__@gt" => 5` does, and refuses a column on its right (#811).
  5. `+ - * /` over a handle, on either side, build the SQL the same arithmetic on the model column
     builds (#1539), and a CTE date or timestamp column takes the date arms of the render: SQLite holds
     a date as text, so an untyped side subtracted the years and gave no error. A comparison with a
     date literal binds what the filter pair binds.
  6. An operand outside the arithmetic vocabulary, `desc = true` and a JSON key's column raise
     `QueryBuildError`.

DB-free: mock connections only.

julia --project=test/integration test/unit/test_cte_left_comparison.jl
"""

using Test
using PormG
using PormG.Models

struct CteLeftMockSQLite <: PormG.PormGSQLite end
struct CteLeftMockPostgres <: PormG.PormGPostgres end
const _CLC_SL = CteLeftMockSQLite()
const _CLC_PG = CteLeftMockPostgres()
PormG.backend_sqlite_version(::CteLeftMockSQLite) = 3045000

PormG.config["cte_left_cmp_mock"] = PormG.Configuration.Settings(
  connections = _CLC_PG, change_data = true, db_def_folder = "cte_left_cmp_mock",
)

module CteLeftModels
import PormG
import PormG.Models
# F1-shaped: a result row with points and a JSON document of per-race extras.
Clc_result = Models.Model("clc_result",
  id      = Models.IDField(),
  points  = Models.IntegerField(null = true),
  payload = Models.JSONField(null = true),
  grid    = Models.IntegerField(null = true),
  fl      = Models.FloatField(null = true),
  dt      = Models.DateField(null = true),
  ts      = Models.DateTimeField(null = true),
  du      = Models.DurationField(null = true),
  tm      = Models.TimeField(null = true),
)
PormG.Models.set_models(@__MODULE__, "cte_left_cmp_mock")
end
const CLC = CteLeftModels
import PormG.QueryBuilder: inspect_query, CTE, F, Value, Max, Abs, Lag, WindowOver
using Dates
using Decimals: Decimal

_clc_sql(q, conn) = inspect_query(q; connection = conn)
function _clc_query(cond)
  body = CLC.Clc_result.objects
  body.values("id", "n" => "points", "k" => "payload__n")
  q = CLC.Clc_result.objects
  q.with("g" => body, join_field = "id" => "id", join_type = "INNER")
  q.values("id")
  q.filter(cond)
  return q
end
_clc_where(sql) = strip(split(sql, "WHERE ")[end])
_clc_refusal(f) = Base.CoreLogging.with_logger(() -> (try f(); nothing catch e; e end), Base.CoreLogging.NullLogger())

# ─────────────────────────────────────────────────────────────────────────────
# #1529: each comparison with the handle on the left builds the filter pair's predicate
# Expected: `CTE("g", "n") op x` is an `FExpression` whose left is the handle, and a filter on it renders
# the predicate `"g__n__@<op>" => x` renders, in parentheses, with the same parameters —
# `("R1_1"."n" > $1)` on PostgreSQL — for a value and for a column on the right.
# Why it matters: `filter(CTE("g", "n") == 5)` reported the `false` Base handed it, and `>` was a
# `MethodError`, so the one spelling that disambiguates a colliding CTE name could not sit on the left.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1529: a CTE handle on the left builds the comparison its filter pair builds" begin
  ops = (("==", "g__n", (a, b) -> a == b), ("!=", "g__n__@ne", (a, b) -> a != b),
         (">", "g__n__@gt", (a, b) -> a > b), ("<", "g__n__@lt", (a, b) -> a < b),
         (">=", "g__n__@gte", (a, b) -> a >= b), ("<=", "g__n__@lte", (a, b) -> a <= b))
  for (label, key, cmp) in ops
    node = cmp(CTE("g", "n"), 5)
    @test (label, node isa PormG.QueryBuilder.FExpression) == (label, true)
    @test (label, isequal(node.field_name, CTE("g", "n"))) == (label, true)
    for conn in (_CLC_PG, _CLC_SL), rhs in (5, F("points"))
      got = _clc_sql(_clc_query(cmp(CTE("g", "n"), rhs)), conn)
      ref = _clc_sql(_clc_query(key => rhs), conn)
      tag = (label, nameof(typeof(conn)), rhs isa Int ? "value" : "column")
      # The operator spelling types its parameter on PostgreSQL (`$1::bigint`), as `F("points") > 5`
      # does on a model column, where the pair binds it bare; the predicate is otherwise the pair's.
      @test (tag, occursin("(" * _clc_where(ref[:sql_text]) * ")", replace(got[:sql_text], "::bigint" => ""))) == (tag, true)
      @test (tag, got[:parameters]) == (tag, ref[:parameters])
    end
  end
  @test occursin("(\"R1_1\".\"n\" > \$1::bigint)", _clc_sql(_clc_query(CTE("g", "n") > 5), _CLC_PG)[:sql_text])
  # The same shape as `F` on a model column, which is what the handle replaces.
  @test occursin("(\"R1\".\"points\" > \$1::bigint)", _clc_sql(_clc_query(F("points") > 5), _CLC_PG)[:sql_text])
  # A handle on both sides is a column comparison too.
  @test occursin("\"R1_1\".\"n\" = \"R1_1\".\"id\"",
                 _clc_sql(_clc_query(CTE("g", "n") == CTE("g", "id")), _CLC_PG)[:sql_text])
end

# ─────────────────────────────────────────────────────────────────────────────
# #1529: isequal stays total and the refusals are the F family's
# Expected: `isequal` answers `true` for an equal handle and `false` for anything else without calling
# `==` (so a `Dict` and a `Set` work); an operand outside the comparison vocabulary (`1//2`), `missing`
# and `desc = true` raise `QueryBuildError`, as `F` and `Joined` do.
# Why it matters: once `==` builds a predicate, the generic `isequal` fallback would throw a `TypeError`
# inside `Dict`/`Set`, and an unsupported operand must not answer `false` again.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1529: isequal stays total; unsupported operands and desc are refused" begin
  c = CTE("g", "n")
  @test isequal(c, CTE("g", "n"))
  @test !isequal(c, CTE("g", "k"))
  @test !isequal(c, "g__n") && !isequal(c, 5) && !isequal(c, missing)
  @test length(Set([c, CTE("g", "n"), CTE("g", "k")])) == 2
  @test Dict(c => 1)[CTE("g", "n")] == 1
  @test length(unique([c, CTE("g", "n")])) == 1   # `==` on a Vector reaches `==` and builds (#541)
  for bad in (() -> c == 1 // 2, () -> c > 1 // 2, () -> c == missing, () -> c < missing,
              () -> CTE("g", "n"; desc = true) > 5)
    @test _clc_refusal(bad) isa PormG.QueryBuildError
  end
  @test occursin("desc = true", PormG._emsg(sprint(showerror, _clc_refusal(() -> CTE("g", "n"; desc = true) == 5)); color = false))
end

# ─────────────────────────────────────────────────────────────────────────────
# #1529: a CTE column over a JSON key on the left compares as the key lookup does
# Expected: `CTE("g", "k") > 5` renders and binds as the pair `"g__k__@gt" => 5` (the #1511 key
# comparison: `::numeric` on PostgreSQL, the native value on SQLite), and a column on its right raises
# #811's `FilterError`, as the pair `"g__k__@gt" => F("points")` does.
# Why it matters: the new left side must reach the key path the string spelling reaches, or the two
# spellings of one comparison would bind differently.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1529: a CTE column over a JSON key on the left compares as the key lookup" begin
  for conn in (_CLC_PG, _CLC_SL)
    got = _clc_sql(_clc_query(CTE("g", "k") > 5), conn)
    ref = _clc_sql(_clc_query("g__k__@gt" => 5), conn)
    @test occursin("(" * _clc_where(ref[:sql_text]) * ")", got[:sql_text])
    @test got[:parameters] == ref[:parameters]
    e = _clc_refusal(() -> _clc_sql(_clc_query(CTE("g", "k") > F("points")), conn))
    @test e isa PormG.FilterError
    @test _clc_refusal(() -> _clc_sql(_clc_query("g__k__@gt" => F("points")), conn)) isa PormG.FilterError
  end
  @test occursin("::numeric > \$1", _clc_sql(_clc_query(CTE("g", "k") > 5), _CLC_PG)[:sql_text])
end

# ── #1539: arithmetic on a CTE handle ─────────────────────────────────────────
# The body projects one column per kind the render types: an integer (`n`), a JSON key (`k`), a float
# (`x`), a date (`d`), a timestamp (`t`), a duration (`u`) and a time (`m`). `node` is projected as `v`;
# with `filter`, it filters instead.
function _clc_arith(node; filter = nothing)
  body = CLC.Clc_result.objects
  body.values("id", "n" => "points", "k" => "payload__n", "x" => "fl", "d" => "dt", "t" => "ts",
              "u" => "du", "m" => "tm")
  q = CLC.Clc_result.objects
  q.with("g" => body, join_field = "id" => "id", join_type = "INNER")
  if filter === nothing
    q.values("id", "v" => node)
  else
    q.values("id")
    q.filter(filter)
  end
  return q
end
# The projected expression `v`, as the SELECT list renders it, its whitespace collapsed (SQLite's
# millisecond form of an interval spans lines).
_clc_proj(sql) = replace(strip(match(r"\"R1\"\.\"id\" as \"id\",\s*(.*?) as \"v\"\s*\nFROM"s, sql)[1]), r"\s+" => " ")
# The model column each CTE column projects: the same arithmetic on it is the oracle for the handle.
const _CLC_COLUMN = ("\"R1_1\".\"n\"" => "\"R1\".\"points\"", "\"R1_1\".\"x\"" => "\"R1\".\"fl\"",
                     "\"R1_1\".\"d\"" => "\"R1\".\"dt\"", "\"R1_1\".\"t\"" => "\"R1\".\"ts\"",
                     "\"R1_1\".\"u\"" => "\"R1\".\"du\"")
# Whether `handle_node` renders and binds what `column_node` does, once each handle is read as its column.
function _clc_same(handle_node, column_node, conn)
  got = _clc_sql(_clc_arith(handle_node), conn)
  ref = _clc_sql(_clc_arith(column_node), conn)
  return replace(_clc_proj(got[:sql_text]), _CLC_COLUMN...) == _clc_proj(ref[:sql_text]) &&
         got[:parameters] == ref[:parameters]
end

# ─────────────────────────────────────────────────────────────────────────────
# #1539: `+ - * /` over a CTE handle build what the same arithmetic on the model column builds
# Expected: with the handle on the left (against a number, `Value(n)`, a column path, an `F`, another
# handle) and on the right (of a number, an `F`, a scalar function, a window function), the projection is the
# one `F("points")` gives once `"R1_1"."n"` reads `"R1"."points"`, with the same parameters, on
# PostgreSQL and SQLite: `("R1_1"."n" + $1::bigint)`, `(? - "R1_1"."n")`. One pinned difference: on SQLite
# a quotient over a float CTE column casts the dividend, `(CAST("R1_1"."x" AS REAL) / ?)`, where a
# `FloatField` does not. #1150 normalizes a fractional quotient that way unless a side is REAL on every
# row, which a CTE column is not known to be; the value is the same, so the cast is kept.
# Why it matters: `CTE("g", "n") + 1` was a raw `MethodError` and `F("points") + CTE(…)` a refusal, so a
# CTE column entered arithmetic only inside a function, and `F("g__n")` cannot name a declared CTE (#492).
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1539: arithmetic on a CTE handle builds what it builds on the model column" begin
  win = WindowOver(order_by = "id")
  for (label, op) in (("+", +), ("-", -), ("*", *), ("/", /)), conn in (_CLC_PG, _CLC_SL)
    tag = (label, nameof(typeof(conn)))
    cases = (
      :number      => (op(CTE("g", "n"), 2),                   op(F("points"), 2)),
      :float32     => (op(CTE("g", "n"), Float32(2.5)),        op(F("points"), Float32(2.5))),
      :value       => (op(CTE("g", "n"), Value(2)),            op(F("points"), Value(2))),
      :path        => (op(CTE("g", "n"), "grid"),              op(F("points"), "grid")),
      :f           => (op(CTE("g", "n"), F("grid")),           op(F("points"), F("grid"))),
      :cte         => (op(CTE("g", "n"), CTE("g", "n")),       op(F("points"), F("points"))),
      :number_left => (op(10, CTE("g", "n")),                  op(10, F("points"))),
      :f_left      => (op(F("grid"), CTE("g", "n")),           op(F("grid"), F("points"))),
      :function    => (op(Abs("grid"), CTE("g", "n")),         op(Abs("grid"), F("points"))),
      :window      => (op(Lag("grid", over = win), CTE("g", "n")), op(Lag("grid", over = win), F("points"))),
    )
    for (case, (handle_node, column_node)) in cases
      @test (tag, case, _clc_same(handle_node, column_node, conn)) == (tag, case, true)
    end
  end
  # Pinned text, so the oracle cannot drift together with its subject.
  @test _clc_proj(_clc_sql(_clc_arith(CTE("g", "n") + 1), _CLC_PG)[:sql_text]) == "(\"R1_1\".\"n\" + \$1::bigint)"
  @test _clc_proj(_clc_sql(_clc_arith(10 - CTE("g", "n")), _CLC_SL)[:sql_text]) == "(? - \"R1_1\".\"n\")"
  @test _clc_proj(_clc_sql(_clc_arith(CTE("g", "x") / 2), _CLC_SL)[:sql_text]) == "(CAST(\"R1_1\".\"x\" AS REAL) / ?)"
  @test _clc_proj(_clc_sql(_clc_arith(CTE("g", "n") / CTE("g", "x")), _CLC_SL)[:sql_text]) ==
        "(CAST(\"R1_1\".\"n\" AS REAL) / \"R1_1\".\"x\")"
  @test _clc_proj(_clc_sql(_clc_arith(CTE("g", "n") / CTE("g", "x")), _CLC_PG)[:sql_text]) == "(\"R1_1\".\"n\" / \"R1_1\".\"x\")"
  @test _clc_proj(_clc_sql(_clc_arith(F("grid") * CTE("g", "n")), _CLC_PG)[:sql_text]) == "(\"R1\".\"grid\" * \"R1_1\".\"n\")"
  # In a filter, on both sides of a comparison.
  for conn in (_CLC_PG, _CLC_SL)
    got = _clc_sql(_clc_arith(nothing; filter = CTE("g", "n") + 1 > F("grid") * 2), conn)
    @test occursin(r"WHERE \(\(\"R1_1\"\.\"n\" \+ (\$1::bigint|\?)\) > \(\"R1\"\.\"grid\" \* (\$2::bigint|\?)\)\)", got[:sql_text])
    @test got[:parameters] == [1, 2]
  end
  # A new node each time; the handle is a value the caller may reuse.
  c = CTE("g", "n")
  node = c + 1
  @test node isa PormG.QueryBuilder.FExpression
  @test isequal(node.field_name, CTE("g", "n")) && node.operation == "+" && node.operand == 1
  @test (c - 1).operation == "-" && (c + 1) !== node
  @test (2 * c).operation == "*" && isequal((2 * c).field_name, c)   # `*` commutes
  @test (10 / c).field_name == 10 && isequal((10 / c).operand, c)    # `/` keeps the number on the left
  @test (Max("grid") + c).aggregate && (c + Max("grid")).aggregate   # an aggregate operand makes it one
end

# ─────────────────────────────────────────────────────────────────────────────
# #1539: a CTE date or timestamp column takes the date arms of the render
# Expected: the handle is typed by its column's kind, so a date minus a date is the day count
# (`CAST(julianday(…) - julianday(…) AS INTEGER)` on SQLite), a date plus a period or a whole number of
# days is a shift, and a date literal subtracted from it builds — each exactly as the model column's.
# Why it matters: an untyped side fell to the generic `-`/`+`, and SQLite, which holds a date as text,
# subtracted or added the YEARS with no error: `CTE("g", "d") - CTE("g", "d")` rendered
# `("R1_1"."d" - "R1_1"."d")`. And `CTE("g", "d") - Date(…)` was refused as "not a date". A CTE
# duration multiplies as milliseconds on SQLite, and a CTE time is refused there as a TimeField is. A
# duration added to a CTE column that is not a date or timestamp raises `InvalidValueError`, as it does on
# the model column: unchecked, SQLite read an integer as a Julian day number (`date("n", '+1 days')`).
# A duration compared with a CTE duration compares milliseconds on SQLite, on either side.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1539: a CTE date or timestamp column takes the date arms of the render" begin
  for conn in (_CLC_PG, _CLC_SL)
    tag = nameof(typeof(conn))
    cases = (
      :date_minus_cte  => (CTE("g", "d") - CTE("g", "d"),     F("dt") - F("dt")),
      :date_minus_col  => (CTE("g", "d") - F("dt"),           F("dt") - F("dt")),
      :col_minus_date  => (F("dt") - CTE("g", "d"),           F("dt") - F("dt")),
      :ts_minus_ts     => (CTE("g", "t") - CTE("g", "t"),     F("ts") - F("ts")),
      :date_literal    => (CTE("g", "d") - Date(2009, 3, 1),  F("dt") - Date(2009, 3, 1)),
      :plus_period     => (CTE("g", "d") + Day(1),            F("dt") + Day(1)),
      :period_left     => (Day(1) + CTE("g", "d"),            Day(1) + F("dt")),
      :ts_minus_period => (CTE("g", "t") - Hour(6),           F("ts") - Hour(6)),
      :plus_int_column => (CTE("g", "d") + F("grid"),         F("dt") + F("grid")),
      # A CTE duration takes the interval arms (SQLite's millisecond form), as a DurationField does.
      :interval_times  => (CTE("g", "u") * 2,                 F("du") * 2),
      :interval_sum    => (CTE("g", "u") + CTE("g", "u"),     F("du") + F("du")),
      :ts_minus_interval => (CTE("g", "t") - CTE("g", "u"),   F("ts") - F("du")),
    )
    for (case, (handle_node, column_node)) in cases
      @test (tag, case, _clc_same(handle_node, column_node, conn)) == (tag, case, true)
    end
  end
  sl = _clc_proj(_clc_sql(_clc_arith(CTE("g", "d") - CTE("g", "d")), _CLC_SL)[:sql_text])
  @test sl == "CAST(julianday(\"R1_1\".\"d\") - julianday(\"R1_1\".\"d\") AS INTEGER)"
  # An integer CTE column beside a date is not read as a whole number of days (#882 types a model
  # IntegerField so, never a handle): SQLite, which would add it to the date's text, refuses it loudly,
  # and PostgreSQL computes `date + integer` itself, as the day shift the expression means.
  @test _clc_refusal(() -> _clc_sql(_clc_arith(F("dt") + CTE("g", "n")), _CLC_SL)) isa PormG.QueryBuildError
  @test _clc_refusal(() -> _clc_sql(_clc_arith(CTE("g", "m") - CTE("g", "m")), _CLC_SL)) isa PormG.QueryBuildError
  @test _clc_refusal(() -> _clc_sql(_clc_arith(F("tm") - F("tm")), _CLC_SL)) isa PormG.QueryBuildError
  @test _clc_proj(_clc_sql(_clc_arith(F("dt") + CTE("g", "n")), _CLC_PG)[:sql_text]) == "(\"R1\".\"dt\" + \"R1_1\".\"n\")"
  # ± a duration on a column that is no date or timestamp: the handle refuses where the model column does.
  for conn in (_CLC_PG, _CLC_SL), (handle_node, column_node) in (
      (CTE("g", "n") + Day(1), F("points") + Day(1)), (Day(1) + CTE("g", "n"), Day(1) + F("points")),
      (CTE("g", "x") - Hour(1), F("fl") - Hour(1)), (CTE("g", "m") + Hour(1), F("tm") + Hour(1)))
    tag = (nameof(typeof(conn)), handle_node.operation, string(handle_node.field_name))
    @test (tag, _clc_refusal(() -> _clc_sql(_clc_arith(column_node), conn)) isa PormG.InvalidValueError) == (tag, true)
    e = _clc_refusal(() -> _clc_sql(_clc_arith(handle_node), conn))
    @test (tag, e isa PormG.InvalidValueError) == (tag, true)
    @test (tag, occursin("requires a DATE/TIMESTAMP column", PormG._emsg(sprint(showerror, e); color = false))) == (tag, true)
  end
  # #1553: a DURATION column ± a duration is an interval, not a date shift, so it builds; the handle renders
  # what its model column renders. It raised the date-column `InvalidValueError` above until #1553.
  for conn in (_CLC_PG, _CLC_SL), (handle_node, column_node) in (
      (CTE("g", "u") + Day(1), F("du") + Day(1)), (CTE("g", "u") * 2 - Hour(1), F("du") * 2 - Hour(1)),
      (Hour(1) - CTE("g", "u"), Hour(1) - F("du")), (CTE("g", "n") * Hour(1), F("points") * Hour(1)))
    @test (nameof(typeof(conn)), string(handle_node.operation), _clc_same(handle_node, column_node, conn)) ==
          (nameof(typeof(conn)), string(handle_node.operation), true)
  end
  # A duration compared with a CTE duration: the handle on the left compares what it does on the right.
  for conn in (_CLC_PG, _CLC_SL)
    left  = _clc_where(_clc_sql(_clc_arith(nothing; filter = CTE("g", "u") > F("du")), conn)[:sql_text])
    right = _clc_where(_clc_sql(_clc_arith(nothing; filter = F("du") > CTE("g", "u")), conn)[:sql_text])
    ref   = _clc_where(_clc_sql(_clc_arith(nothing; filter = F("du") > F("du")), conn)[:sql_text])
    @test replace(left, _CLC_COLUMN...) == ref
    @test replace(right, _CLC_COLUMN...) == ref
  end
  @test occursin("3600000", _clc_where(_clc_sql(_clc_arith(nothing; filter = CTE("g", "u") > F("du")), _CLC_SL)[:sql_text]))
end

# ─────────────────────────────────────────────────────────────────────────────
# #1549: a date or timestamp literal on the LEFT of `-` over a CTE handle
# Expected: `Date(2009, 3, 29) - CTE("g", "d")` renders and binds what `Date(2009, 3, 29) - F("dt")` does
# on the model column, once `"R1_1"."d"` reads `"R1"."dt"`, on PostgreSQL and SQLite: a day count
# (`($1::date - "R1_1"."d")`, `CAST(julianday(?) - julianday("R1_1"."d") AS INTEGER)`); a timestamp
# literal against a CTE timestamp is an interval, cast on PostgreSQL by the column's zone as #814 casts the
# date on the right. An integer CTE column is not read as a day count beside it, as it is not beside a
# date column (the #1539 testset above): SQLite refuses it.
# Why it matters: it was a raw `MethodError` (`-(::Date, ::CTEReference)`), while the date on the right
# built since #1539.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1549: a date literal on the left of a CTE handle builds what it builds on the column" begin
  for conn in (_CLC_PG, _CLC_SL)
    tag = nameof(typeof(conn))
    cases = (
      :date_left      => (Date(2009, 3, 29) - CTE("g", "d"),         Date(2009, 3, 29) - F("dt")),
      :datetime_left  => (DateTime(2009, 3, 29, 6) - CTE("g", "t"),  DateTime(2009, 3, 29, 6) - F("ts")),
      :date_left_ts   => (Date(2009, 3, 29) - CTE("g", "t"),         Date(2009, 3, 29) - F("ts")),
    )
    for (case, (handle_node, column_node)) in cases
      @test (tag, case, _clc_same(handle_node, column_node, conn)) == (tag, case, true)
    end
  end
  @test _clc_proj(_clc_sql(_clc_arith(Date(2009, 3, 29) - CTE("g", "d")), _CLC_PG)[:sql_text]) ==
        "(\$1::date - \"R1_1\".\"d\")"
  @test _clc_proj(_clc_sql(_clc_arith(Date(2009, 3, 29) - CTE("g", "d")), _CLC_SL)[:sql_text]) ==
        "CAST(julianday(?) - julianday(\"R1_1\".\"d\") AS INTEGER)"
  @test _clc_refusal(() -> _clc_sql(_clc_arith(Date(2009, 3, 29) - CTE("g", "n")), _CLC_SL)) isa PormG.QueryBuildError
  # A number literal minus a CTE date is a count minus a date, refused on every engine as it is beside
  # `F("dt")`. It rendered `(? - "R1_1"."d")` before, which SQLite computed as `10 - 2009` silently.
  for conn in (_CLC_PG, _CLC_SL), n in (10, 10.5), col in ("d", "t")
    e = _clc_refusal(() -> _clc_sql(_clc_arith(n - CTE("g", col)), conn))
    @test (nameof(typeof(conn)), n, col, e isa PormG.QueryBuildError &&
           occursin("A day count minus a date", PormG._emsg(sprint(showerror, e); color = false))) ==
          (nameof(typeof(conn)), n, col, true)
  end
  # An untyped left beside a CTE date is refused on SQLite, as `(F("points") * 2) - F("dt")` is (#882).
  for node in ((F("points") * 2) - CTE("g", "d"), (F("points") * 2) + CTE("g", "d"))
    @test _clc_refusal(() -> _clc_sql(_clc_arith(node), _CLC_SL)) isa PormG.QueryBuildError
    twin = node.operation == "+" ? node.field_name + F("dt") : node.field_name - F("dt")
    @test _clc_refusal(() -> _clc_sql(_clc_arith(twin), _CLC_SL)) isa PormG.QueryBuildError
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# #1539: a date literal against a CTE date or timestamp column binds what the filter pair binds
# Expected: `CTE("g", "t") > Date(2009, 3, 1)` binds the canonical midnight instant
# `"2009-03-01T00:00:00.000+00:00"`, as `"g__t__@gt" => Date(2009, 3, 1)` does, and every comparison
# below binds the pair's parameters on PostgreSQL and SQLite.
# Why it matters: #1529's comparisons bound the literal by its own type (`"2009-03-01"`), because the
# handle side was untyped. On SQLite the comparison is textual, so a row at exactly midnight matched the
# operator spelling and not the pair: two spellings of one predicate, two row sets (the #494 contract).
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1539: a date literal against a CTE date or timestamp column binds what the pair binds" begin
  cases = ((>, "t", "g__t__@gt", Date(2009, 3, 1)), (==, "t", "g__t", DateTime(2009, 3, 1, 10)),
           (>, "d", "g__d__@gt", DateTime(2009, 3, 1, 10)), (<=, "d", "g__d__@lte", Date(2009, 3, 1)))
  for conn in (_CLC_PG, _CLC_SL), (cmp, col, key, lit) in cases
    tag = (nameof(typeof(conn)), key, typeof(lit))
    got = _clc_sql(_clc_arith(nothing; filter = cmp(CTE("g", col), lit)), conn)
    ref = _clc_sql(_clc_arith(nothing; filter = key => lit), conn)
    @test (tag, got[:parameters]) == (tag, ref[:parameters])
  end
  got = _clc_sql(_clc_arith(nothing; filter = CTE("g", "t") > Date(2009, 3, 1)), _CLC_SL)
  @test got[:parameters] == ["2009-03-01T00:00:00.000+00:00"]
end

# ─────────────────────────────────────────────────────────────────────────────
# #1539: arithmetic outside the vocabulary, `desc = true` and a JSON key's column are refused
# Expected: a `Decimal`, a `Rational`, text in `Value`, a period under `*`, `nothing` and a number type the
# operators do not take on the left each raise `QueryBuildError` naming a CTE(...) column's operands;
# `desc = true` on a handle on either side raises it; a CTE column over a JSON key in arithmetic raises
# the #1483 refusal when the query builds.
# Why it matters: the #536 class is a raw `MethodError` or a silent `false`; every refusal must name a
# spelling that works, and a key's value has no declared type for arithmetic to compute on.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1539: arithmetic outside the vocabulary, desc and a JSON key's column are refused" begin
  c = CTE("g", "n")
  d = CTE("g", "n"; desc = true)
  for bad in (() -> c + Decimal(1), () -> c - 1 // 2, () -> c * Value("10"), () -> c / Day(1),
              () -> c / nothing, () -> 1 // 2 + c, () -> d + 1, () -> 10 - d, () -> F("grid") + d,
              () -> Max("grid") * d, () -> d - Day(1), () -> c + d)
    @test _clc_refusal(bad) isa PormG.QueryBuildError
  end
  msg = PormG._emsg(sprint(showerror, _clc_refusal(() -> c / nothing)); color = false)
  @test occursin("a CTE(...) column", msg) && occursin("a number", msg)
  @test occursin("desc = true", PormG._emsg(sprint(showerror, _clc_refusal(() -> d + 1)); color = false))
  for conn in (_CLC_PG, _CLC_SL), node in (CTE("g", "k") + 1, F("grid") + CTE("g", "k"))
    e = _clc_refusal(() -> _clc_sql(_clc_arith(node), conn))
    @test e isa PormG.QueryBuildError
    @test occursin("JSON key", PormG._emsg(sprint(showerror, e); color = false))   # #1483's, not another guard's
  end
  # The spelling the refusal names: cast the key's value to the number meant, then compute on it.
  @test _clc_proj(_clc_sql(_clc_arith(PormG.QueryBuilder.Cast(CTE("g", "k"), "integer") + 1), _CLC_PG)[:sql_text]) ==
        "((\"R1_1\".\"k\")::integer + \$1::bigint)"
end
