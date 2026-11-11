# =============================================================================
# Names chosen at run time reach their target through branches built at definition time (#1611)
#
# The query builder picked a `Dialect` operator, a `Dialect` function renderer, a window renderer and a
# `__@` transform constructor with `getfield(<module>, Symbol(name))`, and a related model with
# `getfield(model._module, Symbol(binding))`. Each is a binding looked up by a name at run time, which a
# static compiler cannot follow (`juliac --trim`, #1599). Now each name list (the operator families in
# `constants.jl`, the `Dialect` functions taking `FnOptions`, `PormGtransform`) generates one branch per
# name at definition time, and a related model goes through `Models._resolve_target_model`. These tests
# pin that every admitted name is still reachable, and that an unknown model name is a PormG refusal.
#
# Hermetic: offline connections and an inline model module. No database.
# =============================================================================
# julia --project=test/integration test/unit/test_named_dispatch_1611.jl

using Test
using PormG
import PormG: Configuration, Dialect, Models, QueryBuildError
isdefined(Main, :SQLite) || include(joinpath(@__DIR__, "..", "load_drivers.jl"))

const _ND_QB = PormG.QueryBuilder
const _ND_KEY = normpath(joinpath(@__DIR__, "pormg1611_named"))
PormG.Configuration.register_offline(_ND_KEY; adapter = :postgres)
const _ND_PG = PormG.config[_ND_KEY].connections

PormG.@models_module Named1611 "pormg1611_named" begin
    Circuit::Models.ModelType = Models.Model("nd1611_circuit",
        circuitid = Models.IDField(),
        name      = Models.CharField(max_length = 60))
    Race::Models.ModelType = Models.Model("nd1611_race",
        raceid    = Models.IDField(),
        year      = Models.IntegerField(),
        circuitid = Models.ForeignKey(Circuit, on_delete = "CASCADE"))
end
import .Named1611 as ND

# ─────────────────────────────────────────────────────────────────────────────
# Tests: every operator of each family list renders through its generated dispatcher on PostgreSQL.
# Expected: a `String` for each name in JSON_CONTAINMENT_OPERATORS, ARRAY_CONTAINMENT_OPERATORS,
# NETWORK_LOOKUP_OPERATORS and PATTERN_LOOKUP_OPERATORS; a name outside the list raises `FilterError`.
# Matters: the list is the one place an operator is admitted; a name in it without a branch would be a
# filter that renders nothing.
# ─────────────────────────────────────────────────────────────────────────────
@testset "every operator in each family list reaches its Dialect renderer (#1611)" begin
    for (f, ops) in ((_ND_QB._json_operator_sql, PormG.JSON_CONTAINMENT_OPERATORS),
                     (_ND_QB._array_operator_sql, PormG.ARRAY_CONTAINMENT_OPERATORS),
                     (_ND_QB._network_operator_sql, PormG.NETWORK_LOOKUP_OPERATORS),
                     (_ND_QB._pattern_operator_sql, PormG.PATTERN_LOOKUP_OPERATORS))
        for op in ops
            @test (op, f(op, _ND_PG, "\"Tb\".\"c\"", "\$1") isa String) == (op, true)
        end
        @test_throws PormG.FilterError f("no_such_operator", _ND_PG, "c", "\$1")
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# Tests: the function renderers the generated dispatcher knows.
# Expected: every `function_name` an `FObject` constructor builds, the window functions and `SUBSTR`
# set aside, is in `_FN_OPTIONS_RENDERERS`; `Sum` renders through it; an unknown name raises
# `QueryBuildError`.
# Matters: the list is read from `Dialect`'s method table at load time, so a renderer added there is
# reachable with no list to keep in step. This pins that the read finds them all.
# ─────────────────────────────────────────────────────────────────────────────
@testset "the function-renderer dispatcher covers every built function name (#1611)" begin
    src = join(read.(filter(endswith(".jl"), readdir(joinpath(pkgdir(PormG), "src", "querybuilder"); join = true)), String))
    built = Set(m.captures[1] for m in eachmatch(r"function_name\s*=\s*\"([A-Z_]+)\"", src))
    windows = Set(["RANK", "DENSE_RANK", "ROW_NUMBER", "LAG", "LEAD", "FIRST_VALUE", "LAST_VALUE", "NTH_VALUE"])
    missing_names = sort!(collect(setdiff(built, windows, Set(["SUBSTR"]), Set(_ND_QB._FN_OPTIONS_RENDERERS))))
    @test missing_names == String[]
    @test _ND_QB._dialect_function_sql("SUM", "\"Tb\".\"points\"", Dialect.FnOptions(), _ND_PG) == "SUM(\"Tb\".\"points\")"
    @test_throws QueryBuildError _ND_QB._dialect_function_sql("NO_SUCH_FN", "x", Dialect.FnOptions(), _ND_PG)
end

# ─────────────────────────────────────────────────────────────────────────────
# Tests: the transform constructors and the window renderers.
# Expected: every `PormGtransform` target builds its node through `_transform_call`; `RANK` and
# `FIRST_VALUE` render through their branches; a column given to `RANK` raises `QueryBuildError`.
# Matters: a transform in the map with no constructor would be a lookup that fails only when used.
# ─────────────────────────────────────────────────────────────────────────────
@testset "transform constructors and window renderers by name (#1611)" begin
    for name in unique(String[v for v in values(PormG.PormGtransform) if v isa String])
        @test (name, _ND_QB._transform_call(name, ["racedate"]) isa _ND_QB.FObject) == (name, true)
    end
    @test_throws QueryBuildError _ND_QB._transform_call("NO_SUCH_TRANSFORM", ["racedate"])
    @test _ND_QB._window_no_column_sql("RANK", "ORDER BY x", _ND_PG) == Dialect.RANK("ORDER BY x", _ND_PG)
    @test _ND_QB._window_column_sql("FIRST_VALUE", "c", "ORDER BY x", _ND_PG) == Dialect.FIRST_VALUE("c", "ORDER BY x", _ND_PG)
    @test_throws QueryBuildError _ND_QB._window_column_sql("RANK", "c", "ORDER BY x", _ND_PG)
end

# ─────────────────────────────────────────────────────────────────────────────
# Tests: a related model named by its binding.
# Expected: `_bound_model(Race, "Circuit")` is `Circuit`; an unknown name is `nothing`, and
# `_require_bound_model` and `_relation_target` raise `QueryBuildError` naming the binding (it was
# Julia's `UndefVarError`).
# Matters: the five sites now share one resolver, the one the model-graph registry (#1601) replaces.
# ─────────────────────────────────────────────────────────────────────────────
@testset "a related model by its binding goes through Models' resolver (#1611)" begin
    @test _ND_QB._bound_model(ND.Race, "Circuit") === ND.Circuit
    @test _ND_QB._bound_model(ND.Race, "NoSuchModel") === nothing
    err = try _ND_QB._require_bound_model(ND.Race, "NoSuchModel"); nothing catch e; e end
    @test err isa QueryBuildError
    @test occursin("NoSuchModel", sprint(showerror, err))
    # A relation slot naming no model: Julia's `UndefVarError` before #1611, now the PormG refusal.
    @test_throws QueryBuildError _ND_QB._relation_target(ND.Race, "NoSuchModel")
    @test _ND_QB._relation_target(ND.Race, "Circuit") === ND.Circuit
end
