"""
Bare literal operands in the function constructors (#705).

`Coalesce("points", 0)` — the most natural way to write a default — died in `values()` with
`MethodError: no method matching _check_function(::Int64)`, and so did `Power`, `Mod`, `NullIf`,
`Greatest` and `Least` with a bare number. The constructors turned a string into a column and stored
anything else as is; the build walk had no arm for a Julia number.

A number (and a `Bool`) operand is now a literal: the constructor wraps it as `Value(x)`, which binds
as a parameter — Django's `Func` does the same (`_parse_expressions`). A string is still a column
path. Three things are pinned:

  1. **The SQL.** Each constructor with a bare number renders a marker and binds the value, on both
     engines, with every marker bound in text order on SQLite.
  2. **The refusals are at the constructor.** A value that is not an operand — `nothing`, a
     `BigFloat`, a date or an `Int16` (both of which `Value` would bind as a serialized BLOB on
     SQLite) — raises
     `QueryBuildError` naming the spelling that works, as does a number in `Replace`'s text slots.
  3. **Nothing else moved.** A string is a column, `Value(0)` renders as before, and a wrapped
     aggregate keeps the #702 flag.

Everything renders through mock connections — no live database.

julia --project=test/integration test/unit/test_function_literal_operands.jl
"""

using Test
using Dates
using PormG
using PormG.Models: Model, IDField, FloatField, CharField, DateField
using PormG.QueryBuilder: inspect_query, _is_agg
using PormG.Functions: Coalesce, Greatest, Least, NullIf, Power, Mod, Replace, Concat, Sum, Value

include("helper_marker_alignment.jl")

# ─────────────────────────────────────────────────────────────────────────────
# Fixtures: one results model per mock backend. The literal binds as a parameter, so its bucket
# placement is a positional-parameter question only SQLite can get wrong silently.
# ─────────────────────────────────────────────────────────────────────────────
struct LitOpMockPostgres <: PormG.PormGPostgres end
struct LitOpMockSQLite <: PormG.PormGSQLite end
PormG.backend_sqlite_version(::LitOpMockSQLite) = 3045000

PormG.config["lit_op_pg"] = PormG.Configuration.Settings(connections = LitOpMockPostgres(), change_data = true)
PormG.config["lit_op_sl"] = PormG.Configuration.Settings(connections = LitOpMockSQLite(), change_data = true)

const _LIT_OP_MODELS = map((("lit_op_pg", :postgres), ("lit_op_sl", :sqlite))) do (key, backend)
  m = Model("lit_op_results", resultid = IDField(), points = FloatField(), surname = CharField(),
            race_date = DateField())
  m.connect_key = key
  (backend, m)
end

# ─────────────────────────────────────────────────────────────────────────────
# A bare number operand binds as a parameter
# Every constructor the issue names, with the number in the position a user writes it. The value is
# bound — never interpolated — and the statement carries exactly one marker per bound value.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#705: a bare number operand binds as a parameter" begin
  cases = (("Coalesce", Coalesce("points", 0), 0),
           ("Greatest", Greatest("points", 0.5), 0.5),
           ("Least", Least("points", 100), 100),
           ("an Int32", Power("points", Int32(3)), Int32(3)),
           ("a Float32", Greatest("points", 0.25f0), 0.25f0),
           ("NullIf", NullIf("points", 0), 0),
           ("Power", Power("points", 2), 2),
           ("Mod", Mod("points", 2), 2),
           ("a Bool", Coalesce("points", true), true),
           ("Concat's number part", Concat("surname", 7), 7))
  for (backend, Model_) in _LIT_OP_MODELS, (label, expr, literal) in cases
    @testset "$backend — $label" begin
      q = Model_.objects
      q.values("resultid", "x" => expr)
      insp = inspect_query(q)
      # The column is still a column…
      @test occursin("\"Tb\".\"$(label == "Concat's number part" ? "surname" : "points")\"", insp[:sql_text])
      # …and the literal is a bound parameter, in text order.
      assert_marker_count(insp, backend)
      assert_bound_in_text_order(insp, Any[literal])
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# The bare spelling and the Value spelling are one query
# `Coalesce("points", 0)` must be exactly what `Coalesce("points", Value(0))` always was — the same
# SQL and the same parameters — so the wrap is a convenience, not a second code path.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#705: a bare literal renders as its Value spelling does" begin
  for (backend, Model_) in _LIT_OP_MODELS
    for (bare, wrapped) in ((Coalesce("points", 0), Coalesce("points", Value(0))),
                            (Power("points", 2), Power("points", Value(2))),
                            (Greatest("points", 1.5), Greatest("points", Value(1.5))))
      a = Model_.objects; a.values("resultid", "x" => bare)
      b = Model_.objects; b.values("resultid", "x" => wrapped)
      ia, ib = inspect_query(a), inspect_query(b)
      @test ia[:sql_text] == ib[:sql_text]
      @test ia[:parameters] == ib[:parameters]
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# What is not an operand is refused at the constructor
# The failure used to surface in `values()`, as a `MethodError` naming an internal function. Each
# case now raises `QueryBuildError` when the expression is BUILT, before any query exists, and the
# message names what to write instead. A date is refused rather than wrapped: `Value` binds its
# literal raw, and SQLite.jl serializes a `Date` into a BLOB, so the comparison would be silently
# wrong on that engine.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#705: a value that is not an operand is refused at construction" begin
  for (label, build, needle) in (("nothing", () -> Coalesce("points", nothing), "Value(x)"),
                                 ("a BigFloat", () -> Power("points", big(2.0)), "Value(x)"),
                                 # Found in review: these bind as a BLOB on SQLite, like a Date.
                                 ("an Int16", () -> Power("points", Int16(2)), "Int64(2)"),
                                 ("a UInt8", () -> Mod("points", 0x02), "Int64(2)"),
                                 ("a Date", () -> Least("race_date", Date(2020, 1, 1)), "date column"),
                                 ("a DateTime", () -> Greatest("race_date", DateTime(2020)), "date column"),
                                 ("a number in Replace's find", () -> Replace("surname", 1, "x"), "\"1\""),
                                 ("a number in Replace's replacement", () -> Replace("surname", "a", 2), "\"2\""),
                                 # Every integer type gets the string hint there, not `Int64(x)`,
                                 # which the same slot would refuse (found in the delta review).
                                 ("an Int16 in Replace's find", () -> Replace("surname", Int16(1), "x"), "\"1\""))
    @testset "$label" begin
      err = @test_throws PormG.QueryBuildError build()
      @test occursin(needle, err.value.msg)
      @test occursin("#705", err.value.msg)
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# Controls: strings, nodes and the aggregate flag are untouched
# A string operand is still a column path (a string literal needs `Value`), an expression operand
# passes through, and a literal next to an aggregate leaves the wrapper an aggregate (#702), so it
# groups and a filter on its alias still goes to HAVING.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#705 controls: strings, nodes and the aggregate flag" begin
  node = Coalesce("points", "surname")
  @test all(c -> c isa PormG.SQLTypeField, node.column)
  @test Replace("surname", "a", "b").column[2] isa PormG.SQLTypeText
  @test _is_agg(Power(Sum("points"), 2))
  @test !_is_agg(Power("points", 2))
  for (backend, Model_) in _LIT_OP_MODELS
    q = Model_.objects
    q.values("surname", "sq" => Power(Sum("points"), 2))
    q.filter("sq__@gt" => 100)
    insp = inspect_query(q)
    @test occursin("GROUP BY", insp[:sql_text])
    @test occursin(r"HAVING POWER\(", insp[:sql_text])
    assert_marker_count(insp, backend)
    # SELECT's exponent, HAVING's re-bound exponent, then the compared value.
    assert_bound_in_text_order(insp, Any[2, 2, 100])
  end
end
