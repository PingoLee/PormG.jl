# ============================================================
# test/unit/test_read_exprs_trim_1599.jl
#
# CONTRACT being tested:
#   The typed forms a comparison against an expression now goes through in a trimmed read (#1599 layer 5) answer what
#   the forms they replaced answered, value for value, and raise what those raised, with the same text:
#     - `_each_condition_leaf` (node unspecialized, vectors through `_each_condition_leaf_in`) against its old body:
#       the same leaves, in the same order, over every node shape a projection or a filter value holds;
#     - `_column_rhs_sql` against the `_on_join_right(() -> _get_filter_query(rhs, instruc), instruc)` call it
#       replaces, for each column right side;
#     - `_render_column_rhs` (right side unspecialized) against its old body, over each operator and right side;
#     - `_set_update_query_left_at` against the `_set_update_query_left` call it replaces, over the left sides an
#       expression holds;
#   each on every engine: the same SQL text and the same parameters bound, or the same error type and text. What the
#   expression filters render end to end is pinned by the render suites (test_field_expressions*.jl and others).
#
# Hermetic: mock connections, no database.
#
# Run: julia --project=test/integration test/unit/test_read_exprs_trim_1599.jl
# ============================================================

using Test
isdefined(Main, :SQLite) || include(joinpath(@__DIR__, "..", "load_drivers.jl"))
using PormG
using Dates
using PormG.QueryBuilder: F, Q, Qor, Case, When, Extract, Coalesce, Sum, Count, Lower, OuterRef, CTE, Joined

const _REX_QB = PormG.QueryBuilder

# Dedicated config keys and mock types: `runtests.jl` includes every unit file into one `Main`.
struct RexMockSQLite <: PormG.PormGSQLite end
struct RexMockPostgres <: PormG.PormGPostgres end
struct RexMockMySQL <: PormG.PormGMySQL end
PormG.backend_sqlite_version(::RexMockSQLite) = 3045000

PormG.config["rex_mock"] = PormG.Configuration.Settings(connections = RexMockSQLite(), change_data = true,
                                                        db_def_folder = "rex_mock")

module RexModels
import PormG
import PormG.Models
Rex_circuit::Models.ModelType = Models.Model("rex_circuit",
  circuitid = Models.IDField(),
  name      = Models.CharField(max_length = 50),
)
Rex_race::Models.ModelType = Models.Model("rex_race",
  raceid    = Models.IDField(),
  circuitid = Models.ForeignKey("Rex_circuit"),
  year      = Models.IntegerField(),
  round     = Models.IntegerField(),
  name      = Models.CharField(max_length = 80),
  date      = Models.DateField(null = true),
  score     = Models.FloatField(null = true),
)
Models.@models Rex_circuit Rex_race
PormG.Models.set_models(@__MODULE__, "rex_mock")
end
const _REX_RACE = RexModels.Rex_race
const _REX_CONNS = (RexMockSQLite(), RexMockPostgres(), RexMockMySQL())

# What a call gave: its value, or the type and text of what it raised.
_rex_outcome(f) = try
  (:value, f())
catch e
  (:raised, typeof(e), sprint(showerror, e))
end

# A fresh instruction over the mock model on `conn`, and the parameters it holds, as text.
_rex_instruc(conn) = _REX_QB.build(_REX_RACE.objects.filter("year" => 2009).object; connection = conn)
_rex_params(instruc) = sprint(show, instruc.parameters)

# ── The old forms, copied from the code before #1599 layer 5's expression slice ─────────────────────────────────
function _old_each_condition_leaf(f::Function, node, depth::Int = 0)
  depth > 32 && return nothing
  if node isa _REX_QB.OperObject
    f(node)
  elseif node isa Union{_REX_QB.QObject,_REX_QB.QorObject}
    foreach(x -> _old_each_condition_leaf(f, x, depth + 1), _REX_QB._q_nodes(node))
  elseif node isa AbstractVector
    foreach(x -> _old_each_condition_leaf(f, x, depth + 1), node)
  elseif node isa Union{_REX_QB.FObject,_REX_QB.WindowFunction}
    _old_each_condition_leaf(f, node.column, depth + 1)
    foreach(x -> _old_each_condition_leaf(f, x, depth + 1), values(node.kwargs))
    if node isa _REX_QB.WindowFunction
      _old_each_condition_leaf(f, node.over.partition_by, depth + 1)
      _old_each_condition_leaf(f, node.over.order_by, depth + 1)
    end
  elseif node isa Union{_REX_QB.SQLField,_REX_QB.SQLOrder}
    _old_each_condition_leaf(f, node.field, depth + 1)
  elseif node isa _REX_QB.FExpression
    _old_each_condition_leaf(f, node.field_name, depth + 1)
    _old_each_condition_leaf(f, node.operand, depth + 1)
  end
  return nothing
end

function _old_render_column_rhs(column::AbstractString, v, rhs, instruc)::String
  rhs_node = _REX_QB._oper_value_node(v)
  rhs_node === nothing || _REX_QB._refuse_json_key_right_operand(rhs_node, instruc)
  operator = v.operator
  operator in _REX_QB.VERBATIM_PATTERN_OPERATORS &&
    return _REX_QB._render_predicate(column, operator, rhs, instruc)
  operator in ("=", ">", "<", ">=", "<=", "<>", "!=") ||
    throw(PormG.FilterError("Invalid filter operator: $(operator) does not take a column expression."))
  return string(column, " ", operator, " ", rhs)
end

# The nodes a condition walk meets: filter pairs, `Q`/`Qor`, `Case`/`When` (one and a list), arithmetic over columns
# and literals, functions, a window, vectors of each element type the walk names, and values that take the open arm.
function _rex_nodes()
  w1 = When("round__@lt" => 10, then = 1)
  w2 = When(Q("name" => "Monaco Grand Prix"), then = 2)
  Any[
    Case(w1, default = 0), Case([w1, w2], default = 0), w1, Q("round__@gt" => 1, "year" => 2008),
    Qor("round" => 1, "round" => 2), F("round") + 2000, F("round") + 1 == 19, (F("round") + 1) * F("year"),
    Extract("date", "month"), Lower("name"), Coalesce("score", 0), Sum(Case(w1, default = 0)),
    Case(When("round__@gte" => Case(w1, default = 0), then = 1), default = Case(w2, default = 3)),
    Any[w1, "round", 5], _REX_QB.FObject[w1, w2], [1, 2], ["a", "b"], 2000, "round", nothing, Date(2008),
    _REX_QB.SQLField("round"), _REX_QB.SQLField(Case(w1, default = 0)),
  ]
end

# What: `_each_condition_leaf` against its old body, over every node shape above.
# Expected: the same leaves (each `OperObject`, by identity), in the same order.
# Why: the walk decides whether a projection or a filter value reads an alias, an aggregate or a window; a leaf missed
#   or added would change which statements are refused or how they group (#1599 layer 5).
@testset "the condition walk visits the leaves it visited (#1599 layer 5)" begin
  for node in _rex_nodes()
    new_leaves, old_leaves = Any[], Any[]
    _REX_QB._each_condition_leaf(x -> push!(new_leaves, x), node)
    _old_each_condition_leaf(x -> push!(old_leaves, x), node)
    @test (typeof(node), length(new_leaves)) == (typeof(node), length(old_leaves))
    @test all(i -> new_leaves[i] === old_leaves[i], eachindex(new_leaves, old_leaves))
  end
end

# What: `_column_rhs_sql` against the call it replaces, for an `F` right side, a CTE column, a joined column and an
#   `OuterRef` with no outer query (a refusal), on each engine.
# Expected: the same SQL (or error) and the same parameters bound.
# Why: the helper renders the same call at the right side's concrete type so a trimmed image can (#1599 layer 5).
@testset "a column right side renders as _on_join_right rendered it (#1599 layer 5)" begin
  rights = Any[F("round") + 2000, F("year"), F("round") * 2 + F("year"), CTE("r", "round"), Joined("d", "round"),
               OuterRef("round")]
  for conn in _REX_CONNS, r in rights
    tag = (nameof(typeof(conn)), typeof(r))
    ni, oi = _rex_instruc(conn), _rex_instruc(conn)
    new = _rex_outcome(() -> _REX_QB._column_rhs_sql(r, ni))
    old = _rex_outcome(() -> _REX_QB._on_join_right(() -> _REX_QB._get_filter_query(r, oi), oi))
    @test (tag, new) == (tag, old)
    @test (tag, _rex_params(ni)) == (tag, _rex_params(oi))
  end
end

# What: `_render_column_rhs` against its old body, for each comparison operator, a pattern operator (`iexact`) and one
#   that takes no column right side, with a `String` right side and with values that take the open arm.
# Expected: the same text, or the same error type and text.
# Why: the right side is now taken unspecialized and joined at its type (#1599 layer 5).
@testset "a column comparison joins its sides as before (#1599 layer 5)" begin
  for conn in _REX_CONNS, op in ("=", ">", "<", ">=", "<=", "<>", "!=", "IEXACT", "LIKE", "BETWEEN"),
      rhs in Any["\"Tb\".\"year\"", SubString("(\"Tb\".\"round\" + ?)", 1), 7, :sym]
    v = _REX_QB.OperObject(column = _REX_QB.SQLField("round"), operator = op, values = F("year"))
    tag = (nameof(typeof(conn)), op, typeof(rhs))
    ni, oi = _rex_instruc(conn), _rex_instruc(conn)
    @test (tag, _rex_outcome(() -> _REX_QB._render_column_rhs("\"Tb\".\"round\"", v, rhs, ni))) ==
          (tag, _rex_outcome(() -> _old_render_column_rhs("\"Tb\".\"round\"", v, rhs, oi)))
  end
end

# What: `_set_update_query_left_at` against the `_set_update_query_left` call it replaces, over the left sides an
#   expression holds (a column, a joined path, an integer, a float, a date, an `Int32`, an `F` expression, a function)
#   and each arithmetic operator, on each engine.
# Expected: the same SQL (or error) and the same parameters bound.
# Why: the walk hands the left side to the call at its type so a trimmed image can (#1599 layer 5).
@testset "an expression's left side renders as before (#1599 layer 5)" begin
  lefts = Any["round", "circuitid__name", 2000, 2.5, Date(2008, 5, 25), Int32(3), F("round") + 1, Extract("date", "month"),
              true]
  for conn in _REX_CONNS, op in ("+", "-", "*", "/", "<<", "%"), x in lefts
    tag = (nameof(typeof(conn)), op, typeof(x))
    ni, oi = _rex_instruc(conn), _rex_instruc(conn)
    @test (tag, _rex_outcome(() -> _REX_QB._set_update_query_left_at(x, op, ni))) ==
          (tag, _rex_outcome(() -> _REX_QB._set_update_query_left(x, op, oi)))
    @test (tag, _rex_params(ni)) == (tag, _rex_params(oi))
  end
end

