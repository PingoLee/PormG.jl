# ============================================================
# test/unit/test_read_functions_trim_1599.jl
#
# CONTRACT being tested:
#   The typed forms a function's read now goes through in a trimmed read (#1599 layer 5) answer what the forms they
#   replaced answered, value for value, and raise what those raised, with the same text:
#     - `_computed_kind_by_name` against `_computed_kind(Val(Symbol(name)), …)`, and `_output_kind_by_name` against
#       `_output_kind(Val(Symbol(name)), …)`, over every function name a rule states and names none states, both rules,
#       every kind the walk answers and every engine;
#     - `_operand_meaning` (one method over an untyped kind) against its three old methods;
#     - `_operand_kinds_at` against the comprehension it replaces, over each column shape a function holds;
#     - `_check_operand_domain` (its column walked at concrete types) against the loop it replaces, refusals included;
#   each on every engine: the same SQL text and the same parameters bound, or the same error type and text. What the
#   function reads render end to end is pinned by the render suites and the expression-kind matrix.
#
# Hermetic: mock connections, no database.
#
# Run: julia --project=test/integration test/unit/test_read_functions_trim_1599.jl
# ============================================================

using Test
isdefined(Main, :SQLite) || include(joinpath(@__DIR__, "..", "load_drivers.jl"))
using PormG
using Dates
using PormG.QueryBuilder: F, Case, When, Sum, Avg, Count, Max, Min, Abs, Round, Lower, Upper, Coalesce, Greatest, Value
using PormG.Functions: Sqrt, Mod, Power
using PormG.Kernel: CInt16, CInt32, CInt64, CFloat64, CDecimal, CInterval, CBool, CText, CDate, CDateTime

const _RFN_QB = PormG.QueryBuilder

# Dedicated config keys and mock types: `runtests.jl` includes every unit file into one `Main`.
struct RfnMockSQLite <: PormG.PormGSQLite end
struct RfnMockPostgres <: PormG.PormGPostgres end
struct RfnMockMySQL <: PormG.PormGMySQL end
PormG.backend_sqlite_version(::RfnMockSQLite) = 3045000

PormG.config["rfn_mock"] = PormG.Configuration.Settings(connections = RfnMockSQLite(), change_data = true,
                                                        db_def_folder = "rfn_mock")

module RfnModels
import PormG
import PormG.Models
Rfn_race::Models.ModelType = Models.Model("rfn_race",
  raceid    = Models.IDField(),
  year      = Models.IntegerField(),
  round     = Models.IntegerField(),
  name      = Models.CharField(max_length = 80),
  date      = Models.DateField(null = true),
  score     = Models.FloatField(null = true),
  points    = Models.DecimalField(max_digits = 10, decimal_places = 2, null = true),
  lap       = Models.DurationField(null = true),
)
Models.@models Rfn_race
PormG.Models.set_models(@__MODULE__, "rfn_mock")
end
const _RFN_RACE = RfnModels.Rfn_race
const _RFN_CONNS = (RfnMockSQLite(), RfnMockPostgres(), RfnMockMySQL())

# What a call gave: its value, or the type and text of what it raised.
_rfn_outcome(f) = try
  (:value, f())
catch e
  (:raised, typeof(e), sprint(showerror, e))
end

# A fresh instruction over the mock model on `conn`, and the parameters it holds, as text.
_rfn_instruc(conn) = _RFN_QB.build(_RFN_RACE.objects.filter("year" => 2009).object; connection = conn)
_rfn_params(instruc) = sprint(show, instruc.parameters)

# ── The old forms, copied from the code before #1599 layer 5's function slice ──────────────────────────────────
_old_operand_meaning(k::Union{CInt16,CInt32,CInt64,CFloat64,CInterval}) = k
_old_operand_meaning(::CDecimal) = CDecimal(nothing, nothing)
_old_operand_meaning(::Any) = nothing

# The mixed-grouping fingerprint as it was, a nested tuple (`build_query.jl` before this slice).
function _old_mixed_node_signature(x, depth::Int = 0)
  depth > 32 && return nothing
  _RFN_QB._is_aggregate_call(x) && return nothing   # a grouped projection never holds one
  x isa AbstractString && return (:path, String(x))
  x isa _RFN_QB.JoinedReference && return (:joined_ref, x.alias, x.path)
  x isa _RFN_QB.CTEReference && return (:cte_ref, x.name, x.path)
  x isa _RFN_QB.SQLTypeText && return (:value, repr(x.field))
  x isa _RFN_QB.SQLTypeField && return _old_mixed_node_signature(x.field, depth + 1)
  x isa Union{Number,Symbol,Nothing,Missing} && return (:literal, repr(x))
  if x isa AbstractVector
    parts = Any[_old_mixed_node_signature(v, depth + 1) for v in x]
    return any(isnothing, parts) ? nothing : (:list, parts...)
  end
  if x isa _RFN_QB.FObject
    col = _old_mixed_node_signature(x.column, depth + 1)
    col === nothing && return nothing
    kws = Any[]
    for k in sort!(collect(keys(x.kwargs)))
      s = _old_mixed_node_signature(x.kwargs[k], depth + 1)
      s === nothing && return nothing
      push!(kws, (k, s))
    end
    return (:fn, x.function_name, col, kws...)
  end
  if x isa _RFN_QB.FExpression
    parts = Any[_old_mixed_node_signature(x.field_name, depth + 1), _old_mixed_node_signature(x.operand, depth + 1)]
    any(isnothing, parts) && return nothing
    return (:f, x.operation === nothing ? "" : x.operation, parts...)
  end
  if x isa _RFN_QB.OperObject
    parts = Any[_old_mixed_node_signature(_RFN_QB._oper_column(x), depth + 1), _RFN_QB.with_oper_value(_old_mixed_node_signature, x, depth + 1)]
    any(isnothing, parts) && return nothing
    return (:op, x.operator, parts...)
  end
  if x isa Union{_RFN_QB.QObject,_RFN_QB.QorObject}
    inner = _old_mixed_node_signature(_RFN_QB._q_nodes(x), depth + 1)   # the closed view (#1698 phase 2)
    return inner === nothing ? nothing : (x isa _RFN_QB.QObject ? :q : :qor, inner)
  end
  return nothing
end

# The mixed-grouping column walk as it was, with a closure for `covered` (`build_query.jl` before this slice).
function _old_each_bare_column(f::Function, node, instruc::_RFN_QB.SQLInstruction, clause::String, depth::Int = 0;
                           covered::Function = _ -> false)
  depth > 32 && return nothing
  walk(x, c = clause; cover = covered) = _old_each_bare_column(f, x, instruc, c, depth + 1; covered = cover)
  if node isa Union{AbstractString,_RFN_QB.CTEReference,_RFN_QB.JoinedReference}
    f(clause, _RFN_QB._mixed_leaf(node))
  elseif node isa AbstractVector
    foreach(walk, node)
  elseif _RFN_QB._is_aggregate_call(node)
    return nothing
  elseif node isa _RFN_QB.WindowFunction
    # An OVER term only when it holds an aggregate: a plain one is grouped by #789. Resolved, so an
    # aggregate reached through an alias (#722) counts.
    for term in node.over.partition_by
      _RFN_QB._resolved_contains_agg(term, instruc) && walk(term, "PARTITION BY")
    end
    for term in node.over.order_by
      t = term isa _RFN_QB.SQLTypeOrder ? _RFN_QB.with_order_term(_RFN_QB._order_term_field, term) : term   # #1599 slice C
      _RFN_QB._resolved_contains_agg(t, instruc) && walk(t, "ORDER BY")
    end
    # The argument always (#809): nothing groups a plain one — `LAG("Tb"."raceid")` beside a `SUM` reads
    # `raceid` once per group exactly as `raceid + SUM(…)` does. `Rank()` and its kin carry none.
    node.column !== nothing && walk(node.column, "argument")
    for (k, v) in node.kwargs   # `Lag`/`Lead`'s `default`, which renders beside the argument
      v isa _RFN_QB.SQLType && walk(v, k == "default" ? "default" : "argument")
    end
  elseif node isa _RFN_QB.FObject
    covered(node) && return nothing
    walk(node.column)
    for v in values(node.kwargs)
      v isa _RFN_QB.SQLType && walk(v)
    end
  elseif node isa _RFN_QB.FExpression
    covered(node) && return nothing
    node.field_name isa Integer || walk(node.field_name)
    op = node.operand
    if op isa AbstractString
      (occursin("__", op) || op in instruc.object.model.field_names) && f(clause, _RFN_QB._mixed_leaf(op))
    elseif op isa Union{_RFN_QB.FExpression,_RFN_QB.SQLTypeFunction,_RFN_QB.CTEReference,_RFN_QB.JoinedReference}
      walk(op)
    end
  elseif node isa _RFN_QB.SQLTypeField
    walk(node.field)
  elseif node isa _RFN_QB.SQLTypeOrder
    walk(_RFN_QB.with_order_term(_RFN_QB._order_term_field, node))   # #1599 slice C
  elseif node isa _RFN_QB.OperObject
    # A condition's column is never matched structurally: a transformed one
    # (`When("born__@year__@gt" => …)`) arrives as `SQLField(EXTRACT(born), …)`, but the #352 sargable
    # rewrite renders it as `"Tb"."born" >= ?`, so a grouped `born__@year` does not cover it. Its base
    # column is yielded with no path key, and only a grouped `born` does.
    col = _RFN_QB._oper_column(node)
    _RFN_QB._alias_filter_key(col, instruc) === nothing && walk(col; cover = _ -> false)
    rhs = _RFN_QB._oper_value_node(node)
    rhs isa Union{_RFN_QB.FExpression,_RFN_QB.FObject,_RFN_QB.WindowFunction,_RFN_QB.CTEReference,_RFN_QB.JoinedReference} && walk(rhs)
  elseif node isa Union{_RFN_QB.QObject,_RFN_QB.QorObject}   # the closed view (#1698 phase 2)
    walk(_RFN_QB._q_nodes(node))
  end
  return nothing
end

# The temporal-mix label and values as they were (`projection_types.jl` before this slice).
function _old_temporal_mix_label(p::_RFN_QB.SQLText)
  t = string(nameof(typeof(p.field)))
  return "$(first(t) in "AEIO" ? "an" : "a") $(t) literal"
end
function _old_temporal_mix_label(p)
  label = _RFN_QB._concat_operand_label(p)
  label === nothing || return "`$(label)`"
  p isa Union{_RFN_QB.FObject,_RFN_QB.WindowFunction} && return "`$(p.function_name)(…)`"
  return "an expression"
end
function _old_temporal_mix_values(p)
  p.function_name == "CASE" && return _RFN_QB._case_values(p)
  values = Any[]
  if p isa _RFN_QB.WindowFunction
    push!(values, p.column isa AbstractVector ? first(p.column) : p.column)
    default = get(p.kwargs, "default", nothing)
    default === nothing || push!(values, default isa Union{_RFN_QB.SQLObject,_RFN_QB.SQLType} ? default : _RFN_QB.SQLText(default))
  else
    append!(values, p.column isa AbstractVector ? p.column : (p.column,))
  end
  return Any[v isa Union{_RFN_QB.SQLObject,_RFN_QB.SQLType,AbstractString} ? v : _RFN_QB.SQLText(v) for v in values
             if !_RFN_QB._is_null_literal(v isa _RFN_QB.SQLText ? v.field : v)]
end

function _old_check_operand_domain(p, instruc)
  domain = _RFN_QB._operand_domain(p)
  domain === nothing && return nothing
  for x in (p.column isa AbstractVector ? p.column : (p.column,))
    _RFN_QB._is_null_literal(x isa _RFN_QB.SQLText ? x.field : x) && continue
    kind = _RFN_QB._expression_kind(x, instruc)
    if kind isa CInterval
      :interval in domain || throw(_RFN_QB._duration_math_refusal(p.function_name, instruc.connection))
    elseif kind isa _RFN_QB._NonNumberKind
      throw(_RFN_QB._non_number_math_refusal(p.function_name, kind, _RFN_QB._concat_operand_label(x), instruc.connection))
    elseif kind isa Union{CText,PormG.Kernel.CVarChar}
      throw(_RFN_QB._text_math_refusal(p.function_name))
    end
  end
  return nothing
end

function _old_operand_kinds(col, instruc, policy)
  operands = col isa AbstractVector ? col : (col,)
  return [_RFN_QB._arithmetic_side_kind(o, instruc, policy) for o in operands]
end

# Every function name a rule states, and names none states (a number function, an aggregate, a text function).
_rfn_stated(rule) = sort!(unique!([String(Base.unwrap_unionall(m.sig).parameters[2].parameters[1])
                                    for m in methods(rule)
                                    if (V = Base.unwrap_unionall(m.sig).parameters[2]) isa DataType && V <: Val &&
                                       length(V.parameters) == 1]))
const _RFN_NAMES = unique!(vcat(_rfn_stated(_RFN_QB._computed_kind), _rfn_stated(_RFN_QB._output_kind),
                                ["MOD", "POWER", "SQRT", "EXP", "LN", "COUNT", "MAX", "UPPER", "NOT_A_FUNCTION"]))
const _RFN_KINDS = Any[nothing, CInt16(), CInt32(), CInt64(), CFloat64(), CDecimal(nothing, nothing), CDecimal(10, 2),
                       CDecimal(4, 0), CInterval(), CInterval(true), CBool(), CText(), CDate(), CDateTime(true)]

@testset "Function reads in a trimmed build answer as before (#1599 layer 5)" begin

  # What: the by-name ladder of `_computed_kind` (the engine walk, the kind walk, and `invoke` on `Any` for a kind no
  #   method names) against the `Val` built from the name at run time.
  # Expected: the same kind for every name, rule, operand kind and engine.
  # Why: `_number_kind` computed a function's kind through `Val(Symbol(name))`, which a trimmed image had no target
  #   for; the ladder must pick exactly the method run-time dispatch picked (#1599 layer 5).
  @testset "_computed_kind_by_name answers what the Val dispatch answered" begin
    for conn in _RFN_CONNS, name in _RFN_NAMES, rule in (:promoting, :numeric), k in _RFN_KINDS
      old = _rfn_outcome(() -> _RFN_QB._computed_kind(Val(Symbol(name)), rule, k, conn))
      new = _rfn_outcome(() -> _RFN_QB._computed_kind_by_name(name, rule, k, conn))
      @test (typeof(conn), name, rule, k, new) == (typeof(conn), name, rule, k, old)
    end
  end

  # What: the by-name ladder of `_output_kind` against the `Val` built from the name at run time.
  # Expected: the same kind for every name, rule and list of operand kinds.
  # Why: the meaning of a computed number (`_number_kind` under `_MeaningKinds`) went through the same run-time `Val`.
  @testset "_output_kind_by_name answers what the Val dispatch answered" begin
    lists = [Any[k] for k in _RFN_KINDS]
    append!(lists, [Any[CInt64(), CFloat64()], Any[CInt32(), CDecimal(10, 2)], Any[CInterval(), CInterval()],
                    Any[CInt64(), nothing], Any[CText(), CInt64()]])
    for name in _RFN_NAMES, rule in (:promoting, :numeric), ks in lists
      old = _rfn_outcome(() -> _RFN_QB._output_kind(Val(Symbol(name)), rule, copy(ks)))
      new = _rfn_outcome(() -> _RFN_QB._output_kind_by_name(name, rule, copy(ks)))
      @test (name, rule, ks, new) == (name, rule, ks, old)
    end
    # A name no `Symbol` can be raises what `Val(Symbol(name))` raised.
    @test _rfn_outcome(() -> _RFN_QB._output_kind_by_name("A\0B", :numeric, Any[CInt64()])) ==
          _rfn_outcome(() -> _RFN_QB._output_kind(Val(Symbol("A\0B")), :numeric, Any[CInt64()]))
    @test _rfn_outcome(() -> _RFN_QB._computed_kind_by_name("A\0B", :numeric, CInt64(), RfnMockSQLite())) ==
          _rfn_outcome(() -> _RFN_QB._computed_kind(Val(Symbol("A\0B")), :numeric, CInt64(), RfnMockSQLite()))
  end

  # What: `_operand_meaning`, now one method over an untyped kind, against its three old methods.
  # Expected: the same answer for every kind.
  # Why: the three methods dispatched on `first(ks)`, held untyped, at run time.
  @testset "_operand_meaning answers what its three methods answered" begin
    for k in _RFN_KINDS
      @test (k, _RFN_QB._operand_meaning(k)) == (k, _old_operand_meaning(k))
    end
  end

  # What: each operand's kind over a function's column held untyped, against the comprehension it replaced.
  # Expected: the same kinds, in the same order, for each column shape and engine.
  # Why: iterating `(p.column,)` or a `Vector` of an unknown element type dispatched at run time; the trimmed read
  #   stopped at `iterate(::Tuple{FExpression})` on `Abs(F("round") - 10)` (#1599 layer 5).
  @testset "_operand_kinds_at answers what the comprehension answered" begin
    columns = Any["round", "score", "points", F("round") - 10, F("score") * 2, Abs("round"),
                  Any["round", 2], Any["points", 1.5], ["round", "year"], _RFN_QB.FObject[Abs("round"), Abs("score")],
                  Any[F("round") + 1, "points"]]
    for conn in _RFN_CONNS, (i, col) in enumerate(columns)
      instruc = _rfn_instruc(conn)
      old = _rfn_outcome(() -> _old_operand_kinds(col, instruc, _RFN_QB._MeaningKinds()))
      new = _rfn_outcome(() -> _RFN_QB._operand_kinds_at(col, instruc, _RFN_QB._MeaningKinds()))
      # A column is named by its index: `==` over an `F` builds a filter expression rather than comparing.
      @test old[1] === :value
      @test (typeof(conn), i, new[1], Any[new[2]...]) == (typeof(conn), i, old[1], Any[old[2]...])
    end
  end

  # What: whether a function's column can have a millisecond form, through the walk, against the methods it reaches.
  # Expected: the same answer for every column shape, and the walk names every method's argument type.
  # Why: the call over the untyped column dispatched at run time; the trimmed `Sum("round")` stopped at
  #   `_interval_ms_candidate(::String)` (#1599 layer 5).
  @testset "_interval_ms_candidate_at answers what the methods answered" begin
    columns = Any["round", "lap", "Tb.lap", F("lap") + F("lap"), Sum("lap"), Max("lap"), Coalesce("lap", "lap"),
                  Abs("round"), _RFN_QB.SQLText("01:00:00"), _RFN_QB.SQLText(3), 7, nothing, Any["lap"]]
    for (i, c) in enumerate(columns)
      @test (i, _RFN_QB._interval_ms_candidate_at(c)) == (i, _RFN_QB._interval_ms_candidate(c))
    end
    walked = Set{Any}()
    for m in methods(_RFN_QB._interval_ms_candidate)
      T = Base.unwrap_unionall(m.sig).parameters[2]
      T === Any || push!(walked, T)
    end
    src = string(only(code_lowered(_RFN_QB._interval_ms_candidate_at)))
    for T in walked
      @test (T, occursin(string(nameof(T)), src)) == (T, true)
    end
  end

  # What: an operand's formatter through the walk, against the methods it reaches.
  # Expected: the same formatter for every operand shape and engine, and the walk names every method's argument type.
  # Why: the call over a function's untyped column dispatched at run time; the trimmed `Sum("round")` stopped at
  #   `_expression_formatter(::String, …)` (#1599 layer 5).
  @testset "_expression_formatter_at answers what the methods answered" begin
    operands = Any["round", "name", "lap", "Tb.round", F("round"), F("round") + 1, F("lap") + F("lap"), Abs("round"),
                   Sum("round"), Max("name"), Coalesce("lap", "lap"), Upper("name"), Case(When("round__@lt" => 10, then = 1), default = 0),
                   PormG.QueryBuilder.Q("round__@lt" => 10), 7, nothing, Any["round"]]
    for conn in _RFN_CONNS, (i, x) in enumerate(operands)
      instruc = _rfn_instruc(conn)
      old = _rfn_outcome(() -> _RFN_QB._expression_formatter(x, instruc))
      new = _rfn_outcome(() -> _RFN_QB._expression_formatter_at(x, instruc))
      @test (typeof(conn), i, new) == (typeof(conn), i, old)
    end
    src = string(only(code_lowered(_RFN_QB._expression_formatter_at)))
    for m in methods(_RFN_QB._expression_formatter)
      T = Base.unwrap_unionall(m.sig).parameters[2]
      T === Any && continue
      for U in Base.uniontypes(T)
        n = string(nameof(U === PormG.Kernel.SQLTypeFunction ? _RFN_QB.FObject : U))
        @test (n, occursin(n, src)) == (n, true)
      end
    end
  end

  # What: the mixed-grouping fingerprint, now a `String`, against the nested tuple it was.
  # Expected: over every pair of nodes, the two fingerprints are equal exactly when the tuples were, and a node has none
  #   exactly when it had none.
  # Why: the tuples were stored in a `Set{Any}`, and `push!`/`in` on them dispatched at run time on each tuple's type
  #   (the trimmed `values("year", "n" => Count(…))` stopped at `push!(::Set{Any}, ::Tuple{Symbol,String})`), so the
  #   fingerprint must match what it matched before (#1599 layer 5).
  @testset "_mixed_node_signature matches what the tuple fingerprint matched" begin
    nodes = Any["round", "year", "date__@year", F("round"), F("round") + 1, F("round") + 2, F("round") * 1,
                F("round") * F("year"), F("year") * F("round"), Abs("round"), Abs("year"), Round("round", 2), Round("round", 1),
                Upper(Lower("name")), Lower(Upper("name")), Coalesce("round", 0), Coalesce("round", "0"), Sum("round"),
                Case(When("round__@lt" => 10, then = F("round")), default = 0),
                Case(When("round__@lt" => 11, then = F("round")), default = 0),
                PormG.QueryBuilder.Q("round__@lt" => 10), PormG.QueryBuilder.Qor("round__@lt" => 10, "year" => 2008),
                _RFN_QB.SQLText(3), _RFN_QB.SQLText("3"), 3, 3.0, :a, nothing, missing, Any["round", 1], ["round", "year"],
                _RFN_QB.CTEReference(name = "c", path = "round"), _RFN_QB.JoinedReference("j", "round", false)]
    old = [_rfn_outcome(() -> _old_mixed_node_signature(n)) for n in nodes]
    new = [_rfn_outcome(() -> _RFN_QB._mixed_node_signature(n)) for n in nodes]
    for i in eachindex(nodes)
      @test (i, old[i][1], new[i][1]) == (i, :value, :value)
      @test (i, old[i][2] === nothing) == (i, new[i][2] === nothing)
      for j in eachindex(nodes)
        @test (i, j, isequal(old[i][2], old[j][2])) == (i, j, isequal(new[i][2], new[j][2]))
      end
    end
  end

  # What: the mixed-grouping column walk, now positional with the grouped fingerprints as data, against the walk with a
  #   `covered` closure it replaces.
  # Expected: the same `(clause, leaf)` sequence for each node, with no grouped projection and with grouped ones.
  # Why: re-entered with an untyped node it made a keyword call per node type, and with another closure a call inference
  #   limits; the trimmed `values("year", "n" => Count(…))` stopped at that keyword call (#1599 layer 5).
  @testset "_each_bare_column visits what the closure walk visited" begin
    nodes = Any[Abs("round"), F("round") + 1, F("round") * F("year"), Coalesce("round", Sum("round")), Upper(Lower("name")),
                Case(When("round__@lt" => 10, then = F("round")), default = 0), Abs(F("round") - 10) + Sum("year"),
                F("round") + Sum("year"), Coalesce(F("round") * F("year"), Sum("round")), Any["round", Abs("year")]]
    groups = Any[String[], ["round"], [F("round") * F("year")], [Abs("round"), Upper(Lower("name"))]]
    for conn in _RFN_CONNS, (i, node) in enumerate(nodes), (g, grouped) in enumerate(groups)
      instruc = _rfn_instruc(conn)
      sigs = Set{String}(s for s in (_RFN_QB._mixed_node_signature(x) for x in grouped) if s !== nothing)
      oldsigs = Set{Any}(s for s in (_old_mixed_node_signature(x) for x in grouped) if s !== nothing)
      seen_old = Any[]; seen_new = Any[]
      old = _rfn_outcome(() -> _old_each_bare_column((c, l) -> push!(seen_old, (c, l)), node, instruc, "";
                                                      covered = n -> !isempty(oldsigs) && _old_mixed_node_signature(n) in oldsigs))
      new = _rfn_outcome(() -> _RFN_QB._each_bare_column((c, l) -> push!(seen_new, (c, l)), node, instruc, ""; covered = sigs))
      @test (typeof(conn), i, g, old[1], sprint(show, seen_old)) == (typeof(conn), i, g, new[1], sprint(show, seen_new))
    end
  end

  # What: a value's label in the temporal-mix refusal (`_temporal_mix_label`/`_temporal_mix_label_expr`, through
  #   `_concat_operand_label_at`) and the values it labels (`_temporal_mix_values`), against the old methods.
  # Expected: the same label for every value shape, and the same values for each function.
  # Why: each dispatched on the untyped value or iterated the untyped column; the trimmed
  #   `Case(When(…, then = F("round")), default = 0)` stopped at `_temporal_mix_label(::FExpression)` (#1599 layer 5).
  @testset "the temporal-mix labels and values are what they were" begin
    vals = Any["round", SubString("round", 1), F("round"), F("round") + 1, Abs("round"), _RFN_QB.SQLText(0),
               _RFN_QB.SQLText("x"), _RFN_QB.SQLText(Date(2008, 1, 1)), _RFN_QB.SQLText(1.5),
               _RFN_QB.CTEReference(name = "c", path = "round"), _RFN_QB.JoinedReference("j", "round", false), 7, nothing]
    for (i, v) in enumerate(vals)
      @test (i, _RFN_QB._concat_operand_label_at(v)) == (i, _RFN_QB._concat_operand_label(v))
      old = v isa _RFN_QB.SQLText ? _old_temporal_mix_label(v) : _old_temporal_mix_label(v)
      new = v isa _RFN_QB.SQLText ? _RFN_QB._temporal_mix_label(v) : _RFN_QB._temporal_mix_label_expr(v)
      @test (i, new) == (i, old)
    end
    for (i, p) in enumerate(Any[Coalesce("date", "round"), Coalesce(F("round"), 0), Greatest("date", Value(nothing)),
                                Case(When("round__@lt" => 10, then = F("round")), default = 0), Max("date")])
      @test (i, sprint(show, _RFN_QB._temporal_mix_values(p))) == (i, sprint(show, _old_temporal_mix_values(p)))
    end
  end

  # What: a number function's operand check (`_check_operand_domain`), its column walked at concrete types, against the
  #   loop it replaces.
  # Expected: the same answer or the same refusal (type and text), operand by operand in the same order, for each
  #   function, column shape and engine.
  # Why: the loop iterated `(p.column,)` held untyped; the trimmed MySQL read stopped at `iterate(::Tuple{FExpression})`
  #   on `Abs(F("round") - 10)` (#1599 layer 5).
  @testset "_check_operand_domain refuses what the loop refused" begin
    nodes = Any[Abs("round"), Abs(F("round") - 10), Abs("lap"), Abs("name"), Abs("date"), Sum("lap"), Sum("name"),
                Round("score"), Round("date"), Sqrt(F("score") * 2), Greatest("round", "lap"), Greatest("round", "score"),
                Coalesce("lap", "round"), Mod("round", 3), Power("name", 2), Abs(Upper("name")), Sum(Abs("round")),
                Avg("date"), Abs(Value(nothing)), Max("name")]
    for conn in _RFN_CONNS, (i, node) in enumerate(nodes)
      instruc = _rfn_instruc(conn)
      old = _rfn_outcome(() -> _old_check_operand_domain(node, instruc))
      new = _rfn_outcome(() -> _RFN_QB._check_operand_domain(node, instruc))
      @test (typeof(conn), i, new) == (typeof(conn), i, old)
    end
  end
end
