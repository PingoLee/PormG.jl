# ============================================================
# test/unit/test_typed_copy_1684.jl
#
# CONTRACT being tested:
#   `.copy()` (and every `deepcopy` of a handler: `Exists`, `inspect_query`) copies the query's slots at their types
#   (#1684, #1599 layers 4 and 7) and answers what the `deepcopy` walk it replaced answered:
#     - the copy renders the same SQL and binds the same parameters, on every engine, before and after the caller
#       changes the source through its fluent calls and through what it still holds (an inner queryset, a literal
#       vector), and after the caller changes the copy;
#     - a predicate's queryset value (`"circuitid__@in" => q2`) is still SHARED by the copy, as `deepcopy` shared it;
#     - a filled insert map (a handler `create` or `update` wrote through) is copied pair by pair in its order, its
#       mutable values not shared, and grows as `deepcopy`'s copy grew;
#     - the copy shares no other mutable object with its source.
#   The oracle is the old `_query_copy` (base `a9255fc05`), vendored below: `deepcopy` of the projection, the filter,
#   the ORDER BY terms and the three name lists, and of a filled insert map.
#
# Hermetic: mock connections, no database.
#
# Run: julia --project=test/integration test/unit/test_typed_copy_1684.jl
# ============================================================

using Test
isdefined(Main, :SQLite) || include(joinpath(@__DIR__, "..", "load_drivers.jl"))
using PormG
using PormG.QueryBuilder: F, Count, Sum, Q, Qor, Subquery, Exists, OuterRef
using Dates
using Decimals: Decimal
import OrderedCollections

const _TC84_QB = PormG.QueryBuilder
const _TC84_OD = OrderedCollections.OrderedDict{String,Any}

struct Tc84MockSQLite <: PormG.PormGSQLite end
struct Tc84MockPostgres <: PormG.PormGPostgres end
struct Tc84MockMySQL <: PormG.PormGMySQL end
PormG.backend_sqlite_version(::Tc84MockSQLite) = 3045000
PormG.config["tc84_mock"] = PormG.Configuration.Settings(connections = Tc84MockSQLite(), change_data = true,
                                                         db_def_folder = "tc84_mock")

module Tc84Models
import PormG
import PormG.Models
Tc84_circuit::Models.ModelType = Models.Model("tc84_circuit",
  circuitid = Models.IDField(),
  name      = Models.CharField(max_length = 80),
  country   = Models.CharField(max_length = 80),
)
Tc84_race::Models.ModelType = Models.Model("tc84_race",
  raceid    = Models.IDField(),
  year      = Models.IntegerField(),
  round     = Models.IntegerField(),
  circuitid = Models.ForeignKey("Tc84_circuit", pk_field = "circuitid"),
  name      = Models.CharField(max_length = 80),
  date      = Models.DateField(null = true),
)
Models.@models Tc84_circuit Tc84_race
PormG.Models.set_models(@__MODULE__, "tc84_mock")
end
const _TC84_RACE = Tc84Models.Tc84_race
const _TC84_CONNS = (Tc84MockSQLite(), Tc84MockPostgres(), Tc84MockMySQL())

# The old `_query_copy(obj, nothing)` (base `a9255fc05`): `deepcopy` of every slot `deepcopy` walked.
function _tc84_old_query_copy(obj::_TC84_QB.SQLObjectQuery)
  return _TC84_QB.SQLObjectQuery(
    model = obj.model, connect_key = obj.connect_key,
    values = deepcopy(obj.values), filter = deepcopy(obj.filter),
    insert = isempty(obj.insert) ? _TC84_OD() : deepcopy(obj.insert),
    limit = obj.limit, offset = obj.offset, order = deepcopy(_TC84_QB._order_terms(obj)),
    group = deepcopy(obj.group), having = deepcopy(obj.having), list_joins = deepcopy(obj.list_joins),
    distinct = obj.distinct, for_update = obj.for_update, ctes = _TC84_QB._copy_ctes(obj.ctes),
    custom_join = _TC84_QB._copy_path_joins(obj.custom_join), alias_join = _TC84_QB._copy_alias_joins(obj.alias_join))
end
_tc84_old_copy(h) = _TC84_QB.ObjectHandler(object = _tc84_old_query_copy(getfield(h, :object)))
_tc84_new_copy(h) = h.copy()

_tc84_outcome(f) = try
  (:value, f())
catch e
  (:raised, typeof(e), sprint(showerror, e))
end

# Each source returns the handler and a function that changes, in place, what the caller still holds of it beyond the
# handler's own fluent calls.
_tc84_inner() = _TC84_RACE.objects.filter("circuitid" => OuterRef("circuitid")).values("year")

# a filter, an ORDER BY and a projection, with a literal vector the caller still holds
function _tc84_src_plain()
  rounds = [6, 18]
  q = _TC84_RACE.objects.filter("year" => 2008, "round__@in" => rounds).order_by("date").values("name", "round")
  return q, () -> push!(rounds, 7)
end
# Q and Qor groups, an F expression predicate, a date range and a NULL test
function _tc84_src_groups()
  q = _TC84_RACE.objects.filter(Qor("round__@gt" => 10, Q("year" => 2008, "name__@icontains" => "monaco")),
                                F("round") > F("year") - 2000,
                                "date__@range" => [Date(2008, 5, 1), Date(2008, 6, 30)], "date__@isnull" => false)
  return q.order_by("-round"), () -> nothing
end
# a queryset value (shared by the copy, as `deepcopy` shared it): the caller's later filter on it reaches both
function _tc84_src_queryset()
  inner = Tc84Models.Tc84_circuit.objects.filter("country" => "Monaco").values("circuitid")
  return _TC84_RACE.objects.filter("circuitid__@in" => inner), () -> inner.filter("name__@icontains" => "monte")
end
# an Exists predicate and a scalar Subquery value (both copied)
function _tc84_src_exists()
  inner = _tc84_inner()
  sub = _TC84_RACE.objects.filter("circuitid" => OuterRef("circuitid")).values("round").order_by("-round")
  q = _TC84_RACE.objects.filter(Exists(inner), "round" => Subquery(sub))
  return q, () -> (inner.filter("round__@gt" => 3); sub.filter("year" => 1999))
end
# a grouped projection with an aggregate filtered by its alias (the GROUP BY and HAVING lists)
function _tc84_src_grouped()
  q = _TC84_RACE.objects.values("year", "n" => Count("raceid"), "s" => Sum("round")).filter("n__@gt" => 1).
    order_by("year")
  return q, () -> nothing
end
# a decimal, a text and a timestamp value, and a function column compared
_tc84_src_values() = (_TC84_RACE.objects.filter("round__@gte" => Decimal(5.5), "name__@startswith" => "Mon",
                                                "date__@lt" => Date(2009, 1, 1)), () -> nothing)
_tc84_sources() = Function[_tc84_src_plain, _tc84_src_groups, _tc84_src_queryset, _tc84_src_exists,
                           _tc84_src_grouped, _tc84_src_values]

# What: `.copy()` against the old `deepcopy` copy, for every source above, on every engine.
# Expected: the same SQL and parameters for the copy before any change, after the caller changes the source (its
#   filter, order and projection, and what it still holds), and for the source after the caller changes the copy.
# Why: `.copy()` walked the projection, the filter, the ORDER BY terms and the name lists through `deepcopy`'s generic
#   walk, which a trimmed image has no code for (#1684); the typed copy must render and isolate exactly as it did.
@testset ".copy() renders and isolates as deepcopy did (#1684)" begin
  render(conn, mk, copier, mutate) = begin
    src, poke = mk()
    dup = copier(src)
    before = _TC84_QB.query(dup; connection = conn, show_query = :dict)
    if mutate === :source
      src.filter("year" => 1999); src.order_by("-raceid"); src.values("raceid"); poke()
      return (before, _TC84_QB.query(dup; connection = conn, show_query = :dict))
    elseif mutate === :copy
      src_before = _TC84_QB.query(src; connection = conn, show_query = :dict)
      dup.filter("year" => 1999); dup.order_by("-raceid"); dup.values("raceid")
      return (before, src_before, _TC84_QB.query(src; connection = conn, show_query = :dict))
    end
    return (before,)
  end
  for conn in _TC84_CONNS, (i, mk) in enumerate(_tc84_sources()), mutate in (:none, :source, :copy)
    new = _tc84_outcome(() -> render(conn, mk, _tc84_new_copy, mutate))
    old = _tc84_outcome(() -> render(conn, mk, _tc84_old_copy, mutate))
    @test (typeof(conn), i, mutate, new) == (typeof(conn), i, mutate, old)
    @test (typeof(conn), i, mutate, old[1]) == (typeof(conn), i, mutate, :value)
  end
  # The queryset value stays shared (the caller's later filter on it reaches the copy), as before; the literal
  # vector the caller holds does not.
  src, poke = _tc84_src_queryset()
  dup = src.copy()
  before = _TC84_QB.query(dup; connection = _TC84_CONNS[1], show_query = :sql)
  poke()
  @test _TC84_QB.query(dup; connection = _TC84_CONNS[1], show_query = :sql) != before
  src, poke = _tc84_src_plain()
  dup = src.copy()
  before = _TC84_QB.query(dup; connection = _TC84_CONNS[1], show_query = :dict)
  poke()
  @test _TC84_QB.query(dup; connection = _TC84_CONNS[1], show_query = :dict) == before
end

# A filled insert map's value, as a comparable leaf: an expression through its display.
_tc84_leaf(v) = v isa Union{PormG.PormGModel, _TC84_QB.SQLTypeF, _TC84_QB.SQLTypeFunction} ? sprint(show, v) : v

# What: a handler whose insert map is filled (scalars, a date, a decimal, a vector, an `F` expression), copied, against
#   the old copy.
# Expected: the same pairs in the same order, the same map after the same later inserts and deletions, the vector and
#   the expression not shared, and neither the source nor the copy changed by a change to the other.
# Why: `_copy_insert` deep-copied a filled map through `deepcopy`'s walk (#1684): a trimmed binary that copied a handler
#   `create` or `update` had written through stopped there.
@testset "a filled insert map is copied as deepcopy copied it (#1684)" begin
  mk() = begin
    q = _TC84_RACE.objects.filter("year" => 2010)
    ins = getfield(q, :object).insert
    for (k, v) in ("year" => 2010, "round" => 6, "name" => "Monaco Grand Prix", "date" => Date(2010, 5, 16),
                   "points" => Decimal(2.5), "laps" => [78, 77], "missing" => missing, "none" => nothing,
                   "next" => F("round") + 1)
      ins[k] = v
    end
    q
  end
  new, old = mk().copy(), _tc84_old_copy(mk())
  ni, oi = getfield(new, :object).insert, getfield(old, :object).insert
  @test typeof(ni) === typeof(oi)
  @test collect(keys(ni)) == collect(keys(oi))
  @test isequal([_tc84_leaf(v) for v in values(ni)], [_tc84_leaf(v) for v in values(oi)])   # `missing` among them
  for d in (ni, oi)
    delete!(d, "round"); d["grid"] = 3; d["round"] = 7
  end
  @test collect(keys(ni)) == collect(keys(oi))
  # isolation, both ways
  src = mk()
  dup = src.copy()
  si, di = getfield(src, :object).insert, getfield(dup, :object).insert
  @test si !== di && si["laps"] !== di["laps"] && si["next"] !== di["next"]
  push!(si["laps"], 1); si["year"] = 1999
  @test di["laps"] == [78, 77] && di["year"] == 2010
  push!(di["laps"], 2)
  @test si["laps"] == [78, 77, 1]
  # an empty map: a fresh empty map, as before
  e = _TC84_RACE.objects.filter("year" => 2010)
  @test isempty(getfield(e.copy(), :object).insert) && getfield(e.copy(), :object).insert !== getfield(e, :object).insert
end

# What: `.copy()` against its source, slot by slot: every mutable object the copy reaches, at any depth.
# Expected: nothing mutable is `===` between source and copy, except the queryset a predicate holds as its value
#   (shared on purpose, as `deepcopy` shared it) and the models.
# Why: a shared mutable object is how a caller's later call on one reaches the other (#43, #112).
@testset ".copy() shares no mutable object with its source (#1684)" begin
  function mutables(x, acc = IdDict{Any,Nothing}(), seen = IdDict{Any,Nothing}())
    haskey(seen, x) && return acc
    seen[x] = nothing
    T = typeof(x)
    (x isa Module || x isa PormG.PormGModel || x isa DataType || x isa Function || x isa PormG.PormGField) && return acc
    ismutable(x) && !(x isa Union{String,Symbol,BigInt}) && (acc[x] = nothing)
    if x isa AbstractArray || x isa AbstractDict
      for e in (x isa AbstractDict ? values(x) : x)
        mutables(e, acc, seen)
      end
    elseif isstructtype(T)
      for f in fieldnames(T)
        isdefined(x, f) && mutables(getfield(x, f), acc, seen)
      end
    end
    return acc
  end
  for (i, mk) in enumerate(_tc84_sources())
    i == 3 && continue   # the shared queryset value, checked above
    src, _ = mk()
    getfield(src, :object).insert["laps"] = [78, 77]
    dup = src.copy()
    a, b = mutables(getfield(src, :object)), mutables(getfield(dup, :object))
    shared = [typeof(k) for k in keys(b) if haskey(a, k)]
    @test (i, shared) == (i, DataType[])
  end
end
