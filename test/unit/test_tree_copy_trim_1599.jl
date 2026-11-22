# ============================================================
# test/unit/test_tree_copy_trim_1599.jl
#
# CONTRACT being tested:
#   The typed copy of a CTE body's query (`_cte_query_copy` through `_tree_copy`, #1599 layer 5) answers what
#   `deepcopy` answered, for the bodies that took `deepcopy` before: a projection holding a `Subquery`, an `Exists`, a
#   window, a `Case`, a `Cast` or a mutable literal, with an ORDER BY, and a body with a CTE of its own:
#     - the main query renders the same SQL and binds the same parameters either way, on every engine;
#     - the caller's later calls on the source (its projection, filter and order, the `Subquery`'s or `Exists`' own
#       handler, a window's `WindowSpec`, a `Case`'s branch list) reach neither copy;
#     - `_tree_copy` shares no mutable node with its source, at any depth the set names.
#   `deepcopy` is the oracle.
#
# Hermetic: mock connections, no database.
#
# Run: julia --project=test/integration test/unit/test_tree_copy_trim_1599.jl
# ============================================================

using Test
isdefined(Main, :SQLite) || include(joinpath(@__DIR__, "..", "load_drivers.jl"))
using PormG
using PormG.QueryBuilder: F, Count, Max, CTE, Subquery, Exists, OuterRef
using PormG.Functions: RowNumber, WindowOver, Case, When, Cast, Value
using Decimals: Decimal

const _TCP_QB = PormG.QueryBuilder

struct TcpMockSQLite <: PormG.PormGSQLite end
struct TcpMockPostgres <: PormG.PormGPostgres end
struct TcpMockMySQL <: PormG.PormGMySQL end
PormG.backend_sqlite_version(::TcpMockSQLite) = 3045000
PormG.config["tcp_mock"] = PormG.Configuration.Settings(connections = TcpMockSQLite(), change_data = true,
                                                        db_def_folder = "tcp_mock")

module TcpModels
import PormG
import PormG.Models
Tcp_circuit::Models.ModelType = Models.Model("tcp_circuit",
  circuitid = Models.IDField(),
  name      = Models.CharField(max_length = 80),
  country   = Models.CharField(max_length = 80),
)
Tcp_race::Models.ModelType = Models.Model("tcp_race",
  raceid    = Models.IDField(),
  year      = Models.IntegerField(),
  round     = Models.IntegerField(),
  circuitid = Models.ForeignKey("Tcp_circuit", pk_field = "circuitid"),
  name      = Models.CharField(max_length = 80),
  date      = Models.DateField(null = true),
)
Models.@models Tcp_circuit Tcp_race
PormG.Models.set_models(@__MODULE__, "tcp_mock")
end
const _TCP_CIRCUIT = TcpModels.Tcp_circuit
const _TCP_RACE = TcpModels.Tcp_race
const _TCP_CONNS = (TcpMockSQLite(), TcpMockPostgres(), TcpMockMySQL())

_tcp_outcome(f) = try
  (:value, f())
catch e
  (:raised, typeof(e), sprint(showerror, e))
end

# Each source returns the body and a function that changes, in place, what the caller still holds of it after
# `.with()` (beyond the body's own fluent calls): the inner handler, the window spec, the branch list.
_tcp_inner() = _TCP_RACE.objects.filter("circuitid" => OuterRef("circuitid")).values("year").order_by("-year")

# a scalar Subquery column, with an ORDER BY in the body
function _tcp_src_subquery()
  inner = _tcp_inner()
  body = _TCP_RACE.objects.values("circuitid", "last" => Subquery(inner)).order_by("circuitid")
  return body, () -> inner.filter("round__@gt" => 9)
end
# an Exists column
function _tcp_src_exists()
  inner = _TCP_RACE.objects.filter("circuitid" => OuterRef("circuitid"), "round__@gt" => 3)
  return _TCP_RACE.objects.values("circuitid", "late" => Exists(inner)), () -> inner.filter("year" => 1999)
end
# a window over a partition
function _tcp_src_window()
  spec = WindowOver(partition_by = ["year"], order_by = ["date"])
  return _TCP_RACE.objects.values("circuitid", "rk" => RowNumber(over = spec)), () -> push!(spec.partition_by, "round")
end
# a Case whose branch list the caller still holds
function _tcp_src_case()
  c = Case(When("round__@gt" => 5, then = 1), default = 0)
  branches = c.column
  poke = () -> (branches isa AbstractVector ? push!(branches, When("year" => 1, then = 9)) : nothing)
  return _TCP_RACE.objects.values("circuitid", "late" => c), poke
end
# a Cast and a computed column
_tcp_src_cast() = (_TCP_RACE.objects.values("circuitid", "r" => Cast("round", "text"), "m" => Max(F("round") + 1)), () -> nothing)
# a mutable literal (a Decimal value) beside a Case over it
function _tcp_src_literal()
  c = Case(When("round__@lt" => 3, then = Value(Decimal(2.5))), default = Value(Decimal(0)))
  return _TCP_RACE.objects.values("circuitid", "d" => Value(Decimal(1.5)), "c" => c), () -> nothing
end
# a body with a CTE of its own
function _tcp_src_nested()
  inner_cte = _TCP_RACE.objects.values("circuitid", "n" => Count("raceid"))
  body = _TCP_RACE.objects.with("ic" => inner_cte, join_field = "circuitid" => "circuitid")
  body = body.values("circuitid", "k" => "ic__n", "last" => Subquery(_tcp_inner()))
  return body, () -> inner_cte.filter("year" => 1999)
end
_tcp_sources() = Function[_tcp_src_subquery, _tcp_src_exists, _tcp_src_window, _tcp_src_case, _tcp_src_cast,
                          _tcp_src_literal, _tcp_src_nested]

# What: the CTE's stored copy (`_cte_query_copy`, now the typed tree copy for these bodies) against `deepcopy`.
# Expected: the same rendering before and after the caller changes the source, and the copy unchanged by it, on
#   every engine, for every body above.
# Why: `deepcopy` walked these trees by run-time dispatch, which a trimmed image cannot run (#1828 wall 4); the typed
#   copy must render and isolate exactly as the deep copy did.
@testset "a CTE body's typed copy renders and isolates as deepcopy did (#1599 layer 5)" begin
  render(conn, mk, copier, mutate) = begin
    src, poke = mk()
    cte = _TCP_QB._preset_cte_fields("st", src; join_field = "circuitid" => "circuitid")
    cte["query"] = copier(src)
    before = _TCP_QB.query(cte["query"]; connection = conn, show_query = :dict)
    if mutate
      src.values("name"); src.filter("year" => 1999); src.order_by("-round"); poke()
    end
    after = _TCP_QB.query(cte["query"]; connection = conn, show_query = :dict)
    (before, after)
  end
  for conn in _TCP_CONNS, (i, mk) in enumerate(_tcp_sources()), mutate in (false, true)
    new = _tcp_outcome(() -> render(conn, mk, _TCP_QB._cte_query_copy, mutate))
    old = _tcp_outcome(() -> render(conn, mk, deepcopy, mutate))
    @test (typeof(conn), i, mutate, new) == (typeof(conn), i, mutate, old)
    @test (typeof(conn), i, old[1]) == (typeof(conn), i, :value)
    old[1] === :value && @test old[2][1] == old[2][2]
  end
  # The whole read through `.with()`, the main query rendering a CTE over each body.
  for conn in _TCP_CONNS, (i, mk) in enumerate(_tcp_sources())
    src, _ = mk()
    main = _TCP_CIRCUIT.objects.with("st" => src, join_field = "circuitid" => "circuitid").values("name", "k" => "st__circuitid")
    got = _tcp_outcome(() -> _TCP_QB.query(main; connection = conn, show_query = :dict))
    @test (typeof(conn), i, got[1]) == (typeof(conn), i, :value)
  end
end

# What: `_tree_copy` over each node kind, against its source: a fresh object for every mutable node, at every depth.
# Expected: no mutable object the copy reaches is `===` one the source reaches (strings, symbols, bits values and the
#   immutable column references may be shared), and `deepcopy` of the same tree agrees on every non-mutable leaf.
# Why: a shared mutable node is how a caller's later call reaches the CTE (#43).
@testset "_tree_copy shares no mutable node with its source (#1599 layer 5)" begin
  function mutables(x, acc = IdDict{Any,Nothing}(), seen = IdDict{Any,Nothing}())
    haskey(seen, x) && return acc
    seen[x] = nothing
    T = typeof(x)
    (x isa Module || x isa PormG.PormGModel || x isa DataType || x isa Function) && return acc
    # A `Symbol` is interned and a `BigInt` is the inside of an immutable `Decimal`: neither is changed in place.
    ismutable(x) && !(x isa Union{String,Symbol,BigInt}) && (acc[x] = nothing)
    if x isa AbstractArray || x isa AbstractDict
      for e in (x isa AbstractDict ? values(x) : x)
        mutables(e, acc, seen)
      end
    elseif isstructtype(T) && !(x isa Symbol)
      for f in fieldnames(T)
        isdefined(x, f) && mutables(getfield(x, f), acc, seen)
      end
    end
    return acc
  end
  for (i, mk) in enumerate(_tcp_sources())
    src, _ = mk()
    copy = _TCP_QB._tree_copy_handler(src)   # the typed copy itself, whichever path `.with()` takes for this body
    a, b = mutables(getfield(src, :object).values), mutables(getfield(copy, :object).values)
    shared = [typeof(k) for k in keys(b) if haskey(a, k)]
    @test (i, shared) == (i, DataType[])
  end
end
