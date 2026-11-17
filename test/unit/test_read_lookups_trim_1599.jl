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

# The old `_format_filter_value`, copied from the code before #1599 layer 5's lookup slice.
function _old_format_filter_value(@nospecialize(formatter), @nospecialize(values), operator::AbstractString)
  ranged = operator in _RLK_QB._RANGE_CHECKED_OPERATORS
  (operator in _RLK_QB._ITERABLE_LOOKUP_OPERATORS && values isa AbstractArray) ||
    return _RLK_QB._format_literal_value(formatter, values, ranged)
  isempty(values) && return _RLK_QB._format_empty_list(formatter, values, ranged)
  return [_RLK_QB._format_literal_value(formatter, v, ranged) for v in values]
end

# What: `_format_filter_value` (now through `_format_list_value` and `_formatted_list`) against its old body, over the
#   column formatters a membership or range list meets, every list type the walk names and lists that take its open
#   arms (an empty list, a mixed list, a list of a type the walk does not name, a range or a tuple), a value of the
#   wrong type, a list the formatter refuses part-way, and a scalar, under each operator.
# Expected: the same outcome (`isequal`): the same value and the same vector type (`typeof`), or the same error type and text.
# Why: the walk builds the vector itself instead of through the comprehension, so a trimmed image can run it; the
#   vector type is a bound parameter's type (an empty list binds as one array on PostgreSQL), and the first value a
#   formatter refuses is the one the refusal names.
@testset "a membership or range list formats as it did (#1599 layer 5)" begin
  M = PormG.Models
  formatters = Any[M.format_date_sql, M.format_number_sql, M.format_text_sql, M.format_uuid_sql,
                   M.format_timezone_sql, M.format_bool_sql, _RLK_QB.format_pattern_text_sql]
  lists = Any[[Date(2008, 5, 1), Date(2008, 6, 30)], [6, 7], ["Monaco Grand Prix", "Brazil"], [1.5, 2.5],
              [DateTime(2008, 5, 25, 14), DateTime(2008, 11, 2, 17)], Any["a", 2], Any[1, 2.5], Any[],
              Int[], String[], Date[], [Int32(1), Int32(2)], [true, false], 1:3, ["2008-05-01", "x"],
              ["2008-05-01", "2008-06-30"], [Date(2008, 5, 1), "2008-13-40"], Any[nothing, 1], ("a", "b"), 7,
              "Monaco", Date(2008, 5, 25)]
  for op in ("IN", "NOT IN", "BETWEEN", "NOT BETWEEN", "="), f in formatters, x in lists
    tag = (op, nameof(f), typeof(x))
    new = _rlk_outcome(() -> _RLK_QB._format_filter_value(f, x, op))
    old = _rlk_outcome(() -> _old_format_filter_value(f, x, op))
    @test isequal((tag, new), (tag, old))
    new[1] === :value && old[1] === :value && @test (tag, typeof(new[2])) == (tag, typeof(old[2]))
  end
end

# What: a filter's value node for the unnamed-temporal check (`_literal_value_node`) against the `_filter_value_node`
#   call it replaces, over the scalars and lists a filter holds, the lists the walk names included, and values that take
#   the open arm.
# Expected: the same node (`isequal`, and the same type), or the same error.
# Why: the walk hands a list to `_filter_value_node` at its type; a list read differently would change which
#   comparisons the check refuses (#1599 layer 5).
@testset "a filter's value node is what _filter_value_node gave (#1599 layer 5)" begin
  values = Any["Monaco", SubString("Monaco", 1, 3), 6, 2.5, Date(2008), DateTime(2008), nothing, missing,
               ["A", "M"], [6, 7], [1.5, 2.5], [Date(2008), Date(2009)], [DateTime(2008), DateTime(2009)], Any["a", 2],
               String[], Int[], ("a", "b"), (1, 2), [Int32(1)], [SubString("ab", 1, 1)], :sym]
  for x in values
    new = _rlk_outcome(() -> _RLK_QB._literal_value_node(x))
    old = _rlk_outcome(() -> _RLK_QB._filter_value_node(x))
    @test isequal((typeof(x), new), (typeof(x), old))
    new[1] === :value && @test (typeof(x), typeof(new[2])) == (typeof(x), typeof(old[2]))
  end
end

# The old range-bound queue, copied from `_queue_unnamed_temporal!` before #1599 layer 5's lookup slice.
function _old_queue(pending, @nospecialize(left), @nospecialize(right), op)
  pending === nothing && return nothing
  op in _RLK_QB._UNNAMED_TEMPORAL_OPERATIONS || return nothing
  if op in ("BETWEEN", "NOT BETWEEN") && right isa Union{AbstractVector,Tuple}
    foreach(r -> push!(pending, (left, r, "@range")), right)
  else
    push!(pending, (left, right, op))
  end
  return nothing
end

# What: `_queue_unnamed_temporal!` (now through `_queue_range_bounds!`) against its old body, over each operator a
#   filter queues and right sides of each list type the walk names, a tuple, a mixed list, an empty one and a scalar.
# Expected: the same entries queued, in order, and the same return.
# Why: the walk queues each bound at the list's type; a bound queued differently would change which `@range` filters
#   the check refuses (#1599 layer 5).
@testset "a filter's bounds are queued as before (#1599 layer 5)" begin
  left = _RLK_QB.SQLField("date")
  rights = Any[[_RLK_QB.SQLText("a"), _RLK_QB.SQLText("b")], [6, 7], [1.5, 2.5], [Date(2008), Date(2009)],
               [DateTime(2008), DateTime(2009)], (1, 2), Any[1, "a"], Int[], 5, _RLK_QB.SQLText("x")]
  for op in ("BETWEEN", "NOT BETWEEN", ">=", "<", "+", "IN", "="), r in rights
    pn = Tuple{Any,Any,String}[]
    po = Tuple{Any,Any,String}[]
    tag = (op, typeof(r))
    @test (tag, _RLK_QB._queue_unnamed_temporal!(pn, left, r, op)) == (tag, _old_queue(po, left, r, op))
    @test isequal((tag, pn), (tag, po))
  end
  @test _RLK_QB._queue_unnamed_temporal!(nothing, left, [1, 2], "BETWEEN") === nothing
end

# What: `_operand_field_kind` against the `_field_kind` call it replaces, over a field of every type a model can
#   declare (each `AnyField` member) and a value that is no field.
# Expected: the same kind (`isequal`), or `nothing`.
# Why: a pattern lookup reads its operand's kind to decide how the column is read as text and what it refuses; a kind
#   read differently would change the SQL or the refusal (#1599 layer 5).
@testset "a pattern operand's field kind is what _field_kind gave (#1599 layer 5)" begin
  M = PormG.Models
  fields = Any[M.CharField(), M.TextField(), M.SlugField(), M.EmailField(), M.URLField(), M.IntegerField(),
               M.BigIntegerField(), M.PositiveIntegerField(), M.PositiveSmallIntegerField(),
               M.IDField(), M.ForeignKey("Rlk_circuit"), M.OneToOneField("Rlk_circuit"), M.DateField(), M.DateTimeField(),
               M.DateTimeField(type = "TIMESTAMP"), M.TimeField(), M.DurationField(), M.UUIDField(), M.FloatField(),
               M.DecimalField(max_digits = 8, decimal_places = 3), M.BooleanField(), M.BinaryField(), M.JSONField(),
               M.ImageField(), M.PasswordField(), M.GenericIPAddressField(), M.CIDRField(),
               M.ArrayField(M.IntegerField()), M.SearchVectorField(), "not a field", nothing]
  for f in fields
    @test isequal((typeof(f), _RLK_QB._operand_field_kind(f)), (typeof(f), _RLK_QB._field_kind(f)))
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
