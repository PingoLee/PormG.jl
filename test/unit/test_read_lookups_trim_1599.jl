# ============================================================
# test/unit/test_read_lookups_trim_1599.jl
#
# CONTRACT being tested:
#   The typed forms the common filter lookups now go through in a trimmed read (#1599 layer 5) answer what the
#   forms they replaced answered, value for value, and raise what those raised, with the same text:
#     - `_bind_range_value` (the WHERE `BETWEEN` arm's bind of a formatted pair) against the `_bind_predicate_value`
#       call it replaces: the same placeholders, the same parameters bound, in order, on every engine, over every
#       vector a column formatter returns for a pair and over values that take the open arm;
#     - a `__@range` / `__@nrange` filter end to end on each engine: its SQL, parameters and refusals against the
#       expectations the render suites pin, for a model field, a joined field and values that must refuse.
#   The old call is made directly below as the oracle. What the other lookups render end to end is pinned by the
#   render suites (test_filter_lookups.jl and others), unchanged.
#
# Hermetic: mock connections, no database.
#
# Run: julia --project=test/integration test/unit/test_read_lookups_trim_1599.jl
# ============================================================

using Test
isdefined(Main, :SQLite) || include(joinpath(@__DIR__, "..", "load_drivers.jl"))
using PormG
using Dates

const _RLK_QB = PormG.QueryBuilder

# Dedicated config keys and mock types: `runtests.jl` includes every unit file into one `Main`.
struct RlkMockSQLite <: PormG.PormGSQLite end
struct RlkMockPostgres <: PormG.PormGPostgres end
struct RlkMockMySQL <: PormG.PormGMySQL end
PormG.backend_sqlite_version(::RlkMockSQLite) = 3045000

PormG.config["rlk_mock"] = PormG.Configuration.Settings(connections = RlkMockSQLite(), change_data = true,
                                                        db_def_folder = "rlk_mock")

module RlkModels
import PormG
import PormG.Models
Rlk_circuit::Models.ModelType = Models.Model("rlk_circuit",
  circuitid = Models.IDField(),
  name      = Models.CharField(max_length = 50),
  country   = Models.CharField(max_length = 50),
)
Rlk_race::Models.ModelType = Models.Model("rlk_race",
  raceid    = Models.IDField(),
  circuitid = Models.ForeignKey("Rlk_circuit"),
  year      = Models.IntegerField(),
  round     = Models.IntegerField(),
  name      = Models.CharField(max_length = 80),
  date      = Models.DateField(null = true),
  start_at  = Models.DateTimeField(null = true),
  score     = Models.FloatField(null = true),
)
Models.@models Rlk_circuit Rlk_race
PormG.Models.set_models(@__MODULE__, "rlk_mock")
end
const _RLK_RACE = RlkModels.Rlk_race
const _RLK_CONNS = (RlkMockSQLite(), RlkMockPostgres(), RlkMockMySQL())

# What a call gave: its value, or the type and text of what it raised.
_rlk_outcome(f) = try
  (:value, f())
catch e
  (:raised, typeof(e), sprint(showerror, e))
end

# A fresh instruction over the mock model on `conn`, and the parameters it holds, as text.
_rlk_instruc(conn) = _RLK_QB.build(_RLK_RACE.objects.filter("year" => 2009).object; connection = conn)
_rlk_params(instruc) = sprint(show, instruc.parameters)

# What: `_bind_range_value` against the `_bind_predicate_value` call it replaces, on each engine, for both range
#   operators, over the pairs a column formatter returns (`Vector{String}`, `Vector{Int64}`, `Vector{Float64}`) and over
#   values that take the open arm (a `Vector{Any}`, a tuple, a `Date` pair, one value, an empty vector).
# Expected: the same outcome (placeholders, or the error type and text) and the same parameters bound afterwards.
# Why: the helper exists so a trimmed image can bind the pair; under the JIT it must be invisible. An arm that bound
#   differently would change the statement a `__@range` filter sends.
@testset "a range pair binds as _bind_predicate_value bound it (#1599 layer 5)" begin
  values = Any[["2008-05-01", "2008-06-30"], [1, 10], [1.5, 2.5], Any["a", 2], ("x", "y"), [Date(2008), Date(2009)],
               ["only"], String[], Int[], [Int32(1), Int32(2)]]
  for conn in _RLK_CONNS, op in ("BETWEEN", "NOT BETWEEN"), x in values
    tag = (nameof(typeof(conn)), op, typeof(x))
    new_i = _rlk_instruc(conn)
    old_i = _rlk_instruc(conn)
    @test isequal((tag, _rlk_outcome(() -> _RLK_QB._bind_range_value(new_i, op, x))),
                  (tag, _rlk_outcome(() -> _RLK_QB._bind_predicate_value(old_i, op, x))))
    @test (tag, _rlk_params(new_i)) == (tag, _rlk_params(old_i))
  end
end

# What: a `__@range`, a `__@nrange` and a `__@in` filter end to end on each engine: a date, integer, float and text
#   pair on a model field, a text pair across the foreign key, an integer and a text membership list, and values the
#   formatter refuses.
# Expected: SQL with `BETWEEN` / `IN` (`= ANY` on PostgreSQL) and the formatted values bound in order (a float as its
#   text); the refusals as PormG errors.
# Why: these are the filters that take the asserted field, `_bind_range_value` and the list walk (#1599 layer 5).
@testset "a __@range or __@in filter renders and binds as before (#1599 layer 5)" begin
  dict(q) = q.list(show_query = :dict)
  for conn in _RLK_CONNS
    PormG.config["rlk_mock"].connections = conn
    d = dict(_RLK_RACE.objects.filter("date__@range" => [Date(2008, 5, 1), Date(2008, 6, 30)]))
    @test occursin("BETWEEN", d[:sql_text])
    @test collect(d[:parameters]) == ["2008-05-01", "2008-06-30"]
    n = dict(_RLK_RACE.objects.filter("round__@nrange" => [1, 10]))
    @test occursin("NOT BETWEEN", n[:sql_text])
    @test collect(n[:parameters]) == [1, 10]
    @test collect(dict(_RLK_RACE.objects.filter("score__@range" => [1.5, 2.5]))[:parameters]) == ["1.5", "2.5"]
    @test collect(dict(_RLK_RACE.objects.filter("name__@range" => ["A", "M"]))[:parameters]) == ["A", "M"]
    j = dict(_RLK_RACE.objects.filter("circuitid__name__@range" => ["A", "M"]))
    @test occursin("BETWEEN", j[:sql_text]) && collect(j[:parameters]) == ["A", "M"]
    # A list binds as one array on PostgreSQL (`= ANY($1)`) and one marker per value elsewhere (`IN (?, ?)`).
    member(d) = occursin(" IN (", d[:sql_text]) || occursin("= ANY(", d[:sql_text])
    i = dict(_RLK_RACE.objects.filter("round__@in" => [6, 7]))
    @test member(i) && collect(i[:parameters]) in ([6, 7], [[6, 7]])
    t = dict(_RLK_RACE.objects.filter("name__@in" => ["Brazilian Grand Prix"]))
    @test member(t) && collect(t[:parameters]) in (["Brazilian Grand Prix"], [["Brazilian Grand Prix"]])
    @test_throws PormG.InvalidValueError _RLK_RACE.objects.filter("date__@range" => ["x", "y"]).list(show_query = :sql)
    @test_throws PormG.PormGError _RLK_RACE.objects.filter("round__@range" => ["x", 2]).list(show_query = :sql)
  end
  PormG.config["rlk_mock"].connections = RlkMockSQLite()
end
