# ============================================================
# test/unit/test_read_subqueries_trim_1599.jl
#
# CONTRACT being tested:
#   The typed forms a subquery's read now goes through in a trimmed read (#1599 layer 5) answer what the forms they
#   replaced answered, value for value, and raise what those raised, with the same text:
#     - the `built` callbacks a scalar `Subquery` and `__@in` a queryset hand their nested `query()`, now callable
#       structs (`_ScalarSubqueryBuilt`, `_MembershipBuilt`), against the closures they replace: the same SQL, the same
#       parameters bound and the same value in every `Ref` they fill;
#     - the readers those callbacks call (`_subquery_projection_textless`/`_whole_numeric`/`_json_key`/`_kind`/
#       `_unapplied`), which now read the projected expression at its member's type, against the direct calls;
#     - a function's formatter over its operands (`_expression_formatter(::SQLTypeFunction)`, its list through
#       `_first_operand_formatter`) against the loop over `(p.column,)` it replaces;
#     - an `OuterRef`'s column under its two scopes (`_render_outer_ref_column`) against the two closures it replaces,
#       the scope restored after;
#     - the multi-row warning's aggregate test against its `hasproperty` form;
#   each on every engine. What the subquery reads render end to end is pinned by the render suites, the subquery
#   integration files and the base-vs-branch differential.
#
# Hermetic: mock connections, no database.
#
# Run: julia --project=test/integration test/unit/test_read_subqueries_trim_1599.jl
# ============================================================

using Test
isdefined(Main, :SQLite) || include(joinpath(@__DIR__, "..", "load_drivers.jl"))
using PormG
using PormG.QueryBuilder: F, Case, When, Sum, Count, Max, Min, Upper, Coalesce, Value, Subquery, OuterRef, Q, Cast
using PormG.Kernel: CanonicalType

const _RSQ_QB = PormG.QueryBuilder

# Dedicated config keys and mock types: `runtests.jl` includes every unit file into one `Main`.
struct RsqMockSQLite <: PormG.PormGSQLite end
struct RsqMockPostgres <: PormG.PormGPostgres end
struct RsqMockMySQL <: PormG.PormGMySQL end
PormG.backend_sqlite_version(::RsqMockSQLite) = 3045000

PormG.config["rsq_mock"] = PormG.Configuration.Settings(connections = RsqMockSQLite(), change_data = true,
                                                        db_def_folder = "rsq_mock")

module RsqModels
import PormG
import PormG.Models
Rsq_circuit::Models.ModelType = Models.Model("rsq_circuit",
  circuitid = Models.IDField(),
  name      = Models.CharField(max_length = 80),
  country   = Models.CharField(max_length = 80),
  lat       = Models.FloatField(null = true),
  alt       = Models.DecimalField(max_digits = 10, decimal_places = 2, null = true),
  meta      = Models.JSONField(null = true),
)
Rsq_race::Models.ModelType = Models.Model("rsq_race",
  raceid    = Models.IDField(),
  year      = Models.IntegerField(),
  round     = Models.IntegerField(),
  circuitid = Models.ForeignKey("Rsq_circuit", pk_field = "circuitid"),
  name      = Models.CharField(max_length = 80),
  date      = Models.DateField(null = true),
  lap       = Models.DurationField(null = true),
)
Models.@models Rsq_circuit Rsq_race
PormG.Models.set_models(@__MODULE__, "rsq_mock")
end
const _RSQ_CIRCUIT = RsqModels.Rsq_circuit
const _RSQ_RACE = RsqModels.Rsq_race
const _RSQ_CONNS = (RsqMockSQLite(), RsqMockPostgres(), RsqMockMySQL())

# What a call gave: its value, or the type and text of what it raised.
_rsq_outcome(f) = try
  (:value, f())
catch e
  (:raised, typeof(e), sprint(showerror, e))
end

# A fresh outer instruction over the race on `conn`: what a subquery correlates with.
_rsq_outer(conn) = _RSQ_QB.build(_RSQ_RACE.objects.filter("year" => 2008).object; connection = conn)

# ── The old forms, copied from the code before #1599 layer 5's subquery slice ──────────────────────────────────
# `_expression_formatter(::SQLTypeFunction)` as it was: its operands iterated as `(p.column,)` when one.
function _old_function_formatter(p, instruc)
  p.formatter === nothing || return p.formatter
  name = p.function_name
  declared = get(p.kwargs, name == "CAST" ? "type" : "output_field", nothing)
  if declared isa AbstractString
    formatter = _RSQ_QB._declared_type_formatter(declared, instruc)
    formatter === nothing || return formatter
  end
  if _RSQ_QB._result_rule(p) in (:operand, :one_of, :first_operand)
    for operand in (p.column isa AbstractVector ? p.column : (p.column,))
      formatter = _RSQ_QB._expression_formatter_at(operand, instruc)
      formatter === nothing || return name in ("MAX", "MIN") ? formatter : _RSQ_QB._unranged(formatter)
    end
    return nothing
  end
  formatter = _RSQ_QB._kind_formatter_at(_RSQ_QB._expression_kind(p, instruc), instruc)
  formatter === nothing || return formatter
  return name in ("SUM", "AVG") ? PormG.Models.format_number_sql : nothing
end

# The operand weighing at the end of `_textless_number(::Union{FObject,WindowFunction}, …)` as it was: a generator over the
# operands, gathered by splatting the untyped column.
function _old_textless_operands(p, instruc)
  rule = _RSQ_QB._result_rule(p)
  operands = rule === :first_operand ? Any[_RSQ_QB._first_operand(p)] : Any[(p.column isa AbstractVector ? p.column : (p.column,))...]
  if p isa _RSQ_QB.WindowFunction
    default = get(p.kwargs, "default", nothing)
    literal = default isa _RSQ_QB.SQLText ? default.field : default
    (literal === nothing || literal isa AbstractString || _RSQ_QB._is_null_literal(literal)) || push!(operands, default)
  end
  return _RSQ_QB._division_first((_RSQ_QB._concat_textless_operand(operand, instruc) for operand in operands), instruc.connection)
end

# `_whole_numeric_operand(::Union{FObject,WindowFunction}, …)` as it was: its operands iterated as `(p.column,)` when
# one, each asked by a call on its untyped value.
function _old_whole_numeric_fn(p, instruc)
  name = p.function_name
  declared = get(p.kwargs, name == "CAST" ? "type" : "output_field", nothing)
  declared isa AbstractString && !isempty(declared) && return nothing
  if name in _RSQ_QB._NUMERIC_WHOLE_FUNCTIONS
    operand = p.column isa AbstractVector ? first(p.column) : p.column
    side = _RSQ_QB._whole_numeric_operand(operand, instruc)
    return side === nothing ? nothing : (side[1], "`$(name)(…)` over $(side[2])")
  end
  _RSQ_QB._result_rule(p) in _RSQ_QB._OPERAND_TYPED_RULES || return nothing
  for operand in (p.column isa AbstractVector ? p.column : (p.column,))
    side = name == "SUM" && _RSQ_QB._infer_kind_any(operand, instruc, _RSQ_QB._AllKinds()) === nothing ?
           (:numeric_whole_division, "a value PormG cannot type") : nothing
    side === nothing && (side = _RSQ_QB._whole_numeric_operand(operand, instruc))
    side === nothing || return (side[1], "`$(name)(…)` over $(side[2])")
  end
  return nothing
end

# `_function_held_temporal` as it was: its operands gathered by splatting the untyped column.
function _old_function_held_temporal(p, instruc)
  rule = _RSQ_QB._result_rule(p)
  if p isa _RSQ_QB.FObject && rule in (:declared, :one_of)
    declared = _RSQ_QB._declared_cast(p)
    declared isa AbstractString && !isempty(declared) && return nothing
  end
  operands = Any[(p.column isa AbstractVector ? p.column : (p.column,))...]
  default = p isa _RSQ_QB.WindowFunction ? get(p.kwargs, "default", nothing) : nothing
  default === nothing || push!(operands, default isa AbstractString ? _RSQ_QB.SQLText(default) : default)
  rule in (:operand, :promoting, :one_of) && return _RSQ_QB._first_held(operands, instruc)
  rule === :first_operand && return _RSQ_QB._held_temporal(first(operands), instruc)
  rule === :declared && p isa _RSQ_QB.FObject && p.function_name == "CASE" && return _RSQ_QB._first_held(_RSQ_QB._case_values(p), instruc)
  return nothing
end

# A caller's own projection node and function types: PormG reads their slots as it did, through its open arms.
struct RsqOwnFunction <: PormG.Kernel.SQLTypeFunction
  function_name::String
  aggregate::Bool
end
mutable struct RsqOwnField <: PormG.Kernel.SQLTypeField
  field::Any
end

# The subquery readers as they were: the reader called on the projected expression's untyped field.
function _old_sub_read(reader, h, inner, empty)
  vals = h.object.values
  length(vals) == 1 || return empty
  v = only(vals)
  return reader(v isa _RSQ_QB.SQLText ? v : v.field, inner)
end

# The scalar `Subquery`'s `built` closure as it was (`_render_scalar_subquery`).
_old_scalar_built(h, f, t, w, j, k, u, pk) =
  inner -> (f[] = _RSQ_QB._subquery_projection_formatter(h, inner);
            t[] = _old_sub_read(_RSQ_QB._concat_textless_operand, h, inner, nothing);
            w[] = _old_sub_read(_RSQ_QB._whole_numeric_operand, h, inner, nothing);
            j[] = _old_sub_read(_RSQ_QB._json_number_side, h, inner, nothing);
            k[] = _old_sub_read(_RSQ_QB._expression_kind, h, inner, nothing);
            u[] = _old_sub_read(_RSQ_QB._reads_unapplied_declaration, h, inner, false);
            pk[] = inner.projection_kinds)
# `__@in` a queryset's `built` closure as it was (`_render_filter_oper`).
_old_membership_built(h, k) = inner -> (k[] = _old_sub_read(_RSQ_QB._expression_kind, h, inner, nothing))

# The `OuterRef` column render as it was (`_get_filter_query(::OuterRefObject, …)`).
_old_outer_ref_column(column, outer) =
  _RSQ_QB._with_render_scope(() -> _RSQ_QB._on_join_right(() -> _RSQ_QB._get_filter_query(column, outer), outer), outer;
                             introducer = :outer_ref)

_old_projection_is_aggregate(v)::Bool =
  v isa _RSQ_QB.SQLTypeField && v.field isa _RSQ_QB.SQLTypeFunction &&
  hasproperty(v.field, :aggregate) && getproperty(v.field, :aggregate) === true

# The nested `query()` a subquery opens, with `mk(handler, refs...)` as its callback: the SQL, the parameters the outer
# instruction then holds, and every `Ref` the callback filled.
function _rsq_scalar_run(conn, h, mk)
  outer = _rsq_outer(conn)
  refs = (Base.RefValue{Any}(nothing), Base.RefValue{Union{Nothing,Tuple{Symbol,String}}}(nothing), Base.RefValue{Any}(nothing),
          Base.RefValue{Union{Nothing,Tuple{String,String}}}(nothing), Base.RefValue{Any}(nothing), Base.RefValue{Bool}(false),
          Base.RefValue{Dict{Symbol,CanonicalType}}(Dict{Symbol,CanonicalType}()))
  sql = _RSQ_QB.query(h; table_alias = outer.table_alias, connection = outer.connection, parameters = outer.parameters,
                      outer = outer, built = mk(h, refs...))
  return (sql, sprint(show, outer.parameters), map(r -> r[], refs)...)
end
function _rsq_membership_run(conn, h, mk)
  outer = _rsq_outer(conn)
  kind = Base.RefValue{Any}(nothing)
  sql = _RSQ_QB.query(h; table_alias = outer.table_alias, connection = outer.connection, parameters = outer.parameters,
                      outer = outer, semi_join = true, built = mk(h, kind))
  return (sql, sprint(show, outer.parameters), kind[])
end

# The inner projections a subquery reads: a column, aggregates over each kind of column, arithmetic, a text function,
# a `Coalesce` of two operands, a `Case`, a literal.
_rsq_projections() = Any["name", "n" => Max("name"), "n" => Count("circuitid"), "n" => Max(F("circuitid") + 1),
                         "n" => Upper("name"), "n" => Coalesce("name", "country"), "n" => Max("lat"), "n" => Sum("lat"),
                         "n" => Max("alt"), "n" => Min("alt"), "n" => Max(Upper("name")),
                         "n" => Case(When("country" => "Monaco", then = 1), default = 0), "n" => Value("x"),
                         # a slot each: a whole number a division splits, an uncast JSON key, a declaration an engine
                         # leaves to the read path, a float's text
                         "n" => Max(PormG.QueryBuilder.Floor("circuitid")), "n" => Sum("circuitid"), "n" => Max(F("circuitid") / 2),
                         "n" => Sum(Value(nothing)), "n" => Sum(Case(When("country" => "Monaco", then = Value(nothing)), default = Value(nothing))),
                         "n" => "meta__n", "n" => Cast("circuitid", "numeric(2,0)"), "n" => Cast("alt", "numeric(6,2)"),
                         "n" => Coalesce("lat", 0)]

@testset "Subquery reads in a trimmed build answer as before (#1599 layer 5)" begin

  # What: a scalar `Subquery`'s nested build with the callable struct, against the closure it replaces.
  # Expected: the same SQL, the same parameters bound and the same value in each of the seven `Ref`s, correlated or not,
  #   over every inner projection and engine; the same error where the closure raised.
  # Why: the closure's anonymous type could not be named to root the nested build's keyword call, and the readers it
  #   called dispatched at run time on the projected expression (the trimmed `Subquery(… Max("name"))` stopped at
  #   `_concat_textless_operand(::FObject, …)`).
  @testset "_ScalarSubqueryBuilt fills what the closure filled" begin
    filled = falses(7)   # each `Ref` holds something other than its empty value for some shape, or its check is vacuous
    for conn in _RSQ_CONNS, (i, p) in enumerate(_rsq_projections()), correlated in (true, false)
      qs = correlated ? _RSQ_CIRCUIT.objects.filter("circuitid" => OuterRef("circuitid")) :
                        _RSQ_CIRCUIT.objects.filter("country" => "Brazil")
      h = qs.values(p)
      old = _rsq_outcome(() -> _rsq_scalar_run(conn, h, _old_scalar_built))
      new = _rsq_outcome(() -> _rsq_scalar_run(conn, h, (h, refs...) -> _RSQ_QB._ScalarSubqueryBuilt(h, refs...)))
      @test (typeof(conn), i, correlated, new) == (typeof(conn), i, correlated, old)
      @test old[1] === :value   # each shape builds: a raise on both sides would compare equal and test nothing
      if new[1] === :value
        for (s, v) in enumerate(new[2][3:9])
          filled[s] |= !(v === nothing || v === false || (v isa AbstractDict && isempty(v)))
        end
      end
    end
    @test filled == trues(7)
  end

  # What: `__@in` a queryset's nested build with the callable struct, against the closure it replaces.
  # Expected: the same SQL, parameters and kind over every inner projection and engine.
  # Why: as above; the trimmed `"circuitid__@in" => queryset` stopped at the nested build's keyword call.
  @testset "_MembershipBuilt fills what the closure filled" begin
    for conn in _RSQ_CONNS, (i, p) in enumerate(Any["circuitid", "n" => Max("circuitid"), "n" => F("circuitid") + 1, "name"])
      h = _RSQ_CIRCUIT.objects.filter("country" => "Monaco").values(p)
      old = _rsq_outcome(() -> _rsq_membership_run(conn, h, _old_membership_built))
      new = _rsq_outcome(() -> _rsq_membership_run(conn, h, (h, k) -> _RSQ_QB._MembershipBuilt(h, k)))
      @test (typeof(conn), i, new) == (typeof(conn), i, old)
      @test old[1] === :value
    end
  end

  # What: a function's formatter over its operands, against the loop over `(p.column,)`.
  # Expected: the same formatter (by identity) for one operand and for a list, of each element type the walk names and
  #   of one it does not (a `Vector{Union{String,FObject}}`), on every engine.
  # Why: the one operand was wrapped in a tuple and iterated untyped (the trimmed `Max("name")` inside a `Subquery`
  #   stopped at `iterate(::Tuple{String})`).
  @testset "_expression_formatter(::SQLTypeFunction) answers what the loop answered" begin
    base = Any[Max("name"), Min("round"), Max("date"), Max("lap"), Max(F("round")), Max(F("round") + 1), Max(Upper("name")),
               Coalesce("lap", "lap"), Coalesce("name", "round"), Coalesce(F("round"), 0), Coalesce(Q("round__@lt" => 3), false),
               Coalesce(Value(nothing), "date"), Upper("name"), Sum("round"), Count("raceid"),
               Max(Case(When("round__@lt" => 10, then = 1), default = 0))]
    # The same functions with their column as each list type the walk names, and one it does not.
    fobj_fields = fieldnames(_RSQ_QB.FObject)
    with_column(f, c) = _RSQ_QB.FObject(; NamedTuple{fobj_fields}(Tuple(getfield(f, k) for k in fobj_fields))..., column = c)
    lists = Any[with_column(Coalesce("lap", "lap"), String["lap", "lap"]),
                with_column(Coalesce("name", "round"), String["round", "name"]),
                with_column(Coalesce("lap", "lap"), _RSQ_QB.FObject[Max("lap"), Max("lap")]),
                with_column(Coalesce("lap", "lap"), Any[Value(nothing), "lap"]),
                with_column(Coalesce("lap", "lap"), Union{String,_RSQ_QB.FObject}["lap", Max("round")])]
    for conn in _RSQ_CONNS, (i, p) in enumerate(vcat(base, lists))
      instruc = _RSQ_QB.build(_RSQ_RACE.objects.filter("year" => 2009).object; connection = conn)
      old = _rsq_outcome(() -> _old_function_formatter(p, instruc))
      new = _rsq_outcome(() -> _RSQ_QB._expression_formatter(p, instruc))
      @test (typeof(conn), i, new) == (typeof(conn), i, old)
    end
  end

  # What: a function's operands gathered from its column (`_append_operands!`, read by `_textless_number`,
  #   `_function_held_temporal` and `_whole_numeric_operand`), against the splat into `Any[…]` it replaces; and the
  #   readers over every function, `_whole_numeric_operand` and `_textless_number`'s weighing against old copies.
  # Expected: the same elements, by identity and in order, in a `Vector{Any}`, for one operand of each node type and for
  #   a list of each element type; the readers answer what their old copies answered, on every engine.
  # Why: splatting the untyped column into `Any[…]` dispatched at run time, and the trimmed `Subquery(… Max("name"))`
  #   stopped at `getindex(::Type, ::String)`.
  @testset "a function's operands are gathered as the splat gathered them" begin
    cols = Any["name", F("round"), F("round") + 1, Max("round"), Value(3), Subquery(_RSQ_CIRCUIT.objects.values("name")),
               Q("round__@lt" => 3), String["lap", "round"], _RSQ_QB.FObject[Max("lap"), Upper("name")],
               Any["lap", Value(nothing), F("round")], Union{String,_RSQ_QB.FObject}["lap", Max("round")]]
    for (i, c) in enumerate(cols)
      old = Any[(c isa AbstractVector ? c : (c,))...]
      new = _RSQ_QB._append_operands!(Any[], c)
      @test (i, typeof(new), length(new), all(map(===, new, old))) == (i, Vector{Any}, length(old), true)
    end
    fns = Any[Max("name"), Max("lap"), Max("date"), Coalesce("date", "date"), PormG.QueryBuilder.Lag("date"), Coalesce("lap", "lap"), Coalesce("name", "round"), Coalesce(F("round"), 0),
              Upper("name"), Sum("round"), Max(F("round") / 2), Max(F("round") / 2.0), Coalesce(Sum("round") / 2, 1.5),
              Max(Coalesce(F("round") / 2, 0)), PormG.QueryBuilder.Lag("round"),
              PormG.QueryBuilder.Lag("lap"; default = 3.5), PormG.QueryBuilder.Lag("round"; default = 3.5),
              PormG.QueryBuilder.NullIf("round", 0.5), Sum(F("round") / 2), Max(PormG.QueryBuilder.Floor("round")),
              Coalesce(Sum("round"), F("round")), Max(Sum("round") / 2)]
    for conn in _RSQ_CONNS, (i, p) in enumerate(fns)
      instruc = _RSQ_QB.build(_RSQ_RACE.objects.filter("year" => 2009).object; connection = conn)
      for reader in (_RSQ_QB._textless_number, _RSQ_QB._function_held_temporal)
        r = _rsq_outcome(() -> reader(p, instruc))
        @test (typeof(conn), i, nameof(reader), r[1]) == (typeof(conn), i, nameof(reader), :value)
      end
      @test (typeof(conn), i, _rsq_outcome(() -> _RSQ_QB._function_held_temporal(p, instruc))) ==
            (typeof(conn), i, _rsq_outcome(() -> _old_function_held_temporal(p, instruc)))
      @test (typeof(conn), i, _rsq_outcome(() -> _RSQ_QB._whole_numeric_operand(p, instruc))) ==
            (typeof(conn), i, _rsq_outcome(() -> _old_whole_numeric_fn(p, instruc)))
      # The operands' weighing, against the generator: the functions whose rule weighs their operands (a declared
      # type, `ROUND` and the walk's leaf answer before it, unchanged).
      if _RSQ_QB._result_rule(p) in _RSQ_QB._OPERAND_TYPED_RULES
        new = _rsq_outcome(() -> _RSQ_QB._textless_number(p, instruc))
        @test (typeof(conn), i, new) == (typeof(conn), i, _rsq_outcome(() -> begin
          s = _old_textless_operands(p, instruc)
          s === nothing ? nothing : (s[1], "`$(p.function_name)(…)` over $(s[2])")
        end))
      end
    end
  end

  # What: an `OuterRef`'s column under the `:outer_ref` introducer and, inside an ON clause, the join's right side,
  #   against the two closures it replaces.
  # Expected: the same SQL, the same scope while it renders (outside an ON clause, on a left or unset side, already on
  #   the right) and the instruction's scope restored to the same value after, on every engine.
  # Why: the closures re-entered `_with_render_scope` and `_on_join_right` from inside the render's own scopes, and the
  #   trimmed `Exists(… OuterRef("circuitid") …)` stopped in type inference of `_on_join_right`.
  @testset "_render_outer_ref_column renders what the closures rendered" begin
    scopes = [(;), (join_hop = "Tb_1", join_side = :left), (join_hop = "Tb_1", join_side = :right),
              (join_hop = "Tb_1", join_side = :none), (join_hop = nothing, join_side = :left)]
    for conn in _RSQ_CONNS, (i, kw) in enumerate(scopes), column in ("circuitid", "name", "circuitid__country")
      run(f) = begin
        outer = _rsq_outer(conn)
        outer.scope = _RSQ_QB._with_scope(outer.scope; kw...)
        before = outer.scope
        sql = f(column, outer)
        (sql, outer.scope == before, sprint(show, outer.parameters))
      end
      old = _rsq_outcome(() -> run(_old_outer_ref_column))
      new = _rsq_outcome(() -> run(_RSQ_QB._render_outer_ref_column))
      @test (typeof(conn), i, column, new) == (typeof(conn), i, column, old)
    end
  end

  # What: the multi-row warning's aggregate test, against its `hasproperty` form.
  # Expected: the same answer for every node shape a projection holds, a caller's own node and function types included.
  # Why: `hasproperty`/`getproperty` over the abstract member dispatched at run time in a trimmed `Subquery(...)`'s
  #   multi-row warning.
  @testset "the multi-row warning's aggregate test answers as before" begin
    nodes = Any[only(_RSQ_RACE.objects.values(p).object.values)
                for p in Any["name", "n" => Max("name"), "n" => Count("raceid"), "n" => Upper("name"), "n" => F("round") + 1,
                             "n" => PormG.QueryBuilder.Lag("round"), "n" => PormG.QueryBuilder.Rank(), "n" => Value("x")]]
    append!(nodes, Any["name", 7, nothing, Max("name"),
                       _RSQ_QB.SQLField(RsqOwnFunction("MYAGG", true)), _RSQ_QB.SQLField(RsqOwnFunction("MYFN", false)),
                       RsqOwnField(RsqOwnFunction("MYAGG", true)), RsqOwnField(Max("name")), RsqOwnField("name")])
    for (i, v) in enumerate(nodes)
      @test (i, _RSQ_QB._projection_is_aggregate(v)) == (i, _old_projection_is_aggregate(v))
    end
  end
end
