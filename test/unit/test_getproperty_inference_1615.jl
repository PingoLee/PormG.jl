# =============================================================================
# Every `getproperty` overload infers a concrete type for a literal property name (#1615, #1599 I4)
#
# PormG overloads `getproperty` on five types: `ModelType` (the `M.Model.objects` entry), `ObjectHandler`
# (the fluent ladder), `PormGRow`, `ManyToManyManager` and `_BucketedQuery`. A literal name constant-
# propagates through the overload, so `q.filter` can be a concrete value — but only if every slot the
# arm reads is concrete. Before #1615 `ObjectHandler.object` was the abstract `SQLObject`, so the
# `object` arm returned an abstract type and every fluent call behind it (`_filter!(q.object, …)`)
# was a dynamic dispatch, which `juliac --trim` has no compiled target for (round 3 of #1600, W13).
#
# What each arm's CALL returns is a second question, recorded below. A typed read (`list(T)` and its
# family, `test_typed_read_1352.jl`) and the chain return concrete types; the arms that return a
# `PormGRow`, a `Dict` row or an inspection shape chosen by `show_query` are `Any` by contract. Those are
# JIT-only: a trimmed build reads through `list(T)` (#1605).
#
# Hermetic: an in-memory SQLite database with an inline model module. No live database.
# =============================================================================
# julia --project=test/integration test/unit/test_getproperty_inference_1615.jl

using Test
using PormG
isdefined(Main, :SQLite) || include(joinpath(@__DIR__, "..", "load_drivers.jl"))
import PormG: Configuration, Dialect, Models
import PormG.ConnectionPool: fetch, SQLiteConnectionPool

const _GI_QB = PormG.QueryBuilder
const _GI_KEY = normpath(joinpath(@__DIR__, "pormg1615_getproperty"))
const _GI_POOL = SQLiteConnectionPool(":memory:"; pool_size = 1)
PormG.config[_GI_KEY] = Configuration.Settings(
    connections = _GI_POOL, change_data = true, db_def_folder = _GI_KEY)

# F1-shaped: circuits, races on a circuit, and drivers who won races (a many-to-many).
PormG.@models_module GetProp1615 "pormg1615_getproperty" begin
    Circuit::Models.ModelType = Models.Model("gp1615_circuit",
        circuitid = Models.IDField(),
        name      = Models.CharField(max_length = 60))
    Race::Models.ModelType = Models.Model("gp1615_race",
        raceid    = Models.IDField(),
        year      = Models.IntegerField(),
        circuitid = Models.ForeignKey(Circuit, on_delete = "CASCADE"))
    Driver::Models.ModelType = Models.Model("gp1615_driver",
        driverid  = Models.IDField(),
        surname   = Models.CharField(max_length = 40),
        wins      = Models.ManyToManyField(Race, related_name = "winners"))
end
import .GetProp1615 as GP

# The property's inferred type, for a literal name: a closure per name, so the name is a constant in
# each, exactly as `q.filter` is in user code.
_gi_property_type(::Type{H}, name::Symbol) where H =
    only(Base.return_types(@eval(h -> h.$name), (H,)))

# The 31 names `getproperty(::ObjectHandler, …)` answers: 30 arms plus the `object` slot the last
# `getfield` arm reaches (`object_manager.jl`, the ladder's own count).
const _GI_HANDLER_NAMES = (
    :filter, :db, :values, :order_by, :limit, :offset, :page, :distinct, :select_for_update, :with,
    :cjoin, :on, :cjoin_on, :copy, :create, :update, :update_or_create, :get_or_create, :count,
    :aggregate, :exists, :first, :last, :earliest, :latest, :get, :list, :inspect, :explain, :delete,
    :object)

# ─────────────────────────────────────────────────────────────────────────────
# Tests: `getproperty(::ObjectHandler, name)` for every literal name.
# Expected: a concrete type each, and `object` exactly `SQLObjectQuery`.
# Matters: an abstract property type is a dynamic dispatch at every fluent call, and a trimmed build has
# no target for it (round 3 of #1600, W13). Before #1615 `object` inferred `SQLObject`.
# ─────────────────────────────────────────────────────────────────────────────
@testset "every ObjectHandler property infers a concrete type (#1615)" begin
    @test length(_GI_HANDLER_NAMES) == 31
    for name in _GI_HANDLER_NAMES
        rt = _gi_property_type(_GI_QB.ObjectHandler, name)
        @test (name, isconcretetype(rt)) == (name, true)
    end
    @test fieldtype(_GI_QB.ObjectHandler, :object) === _GI_QB.SQLObjectQuery
    @test _gi_property_type(_GI_QB.ObjectHandler, :object) === _GI_QB.SQLObjectQuery
    q = GP.Race.objects
    @test (@inferred (h -> h.object)(q)) isa _GI_QB.SQLObjectQuery
    @test (@inferred (h -> h.filter)(q)) isa _GI_QB.ChainCaller
end

# ─────────────────────────────────────────────────────────────────────────────
# Tests: the CALL behind each arm. The chain and `copy()` are inferred as `ObjectHandler`, run for real.
# The arms that return `Any` by contract are exactly the recorded set.
# Expected: the chain infers `ObjectHandler`. The `Any` set is create/update/update_or_create/
# get_or_create/count/aggregate/exists/first/last/earliest/latest/get/list/inspect/explain/delete,
# each called with no type argument.
# Matters: the recorded set is the JIT-only surface #1605 names. A chain arm that stops inferring
# fails here, and an arm that starts inferring fails too, until it is moved out of the set.
# ─────────────────────────────────────────────────────────────────────────────
@testset "chain calls infer ObjectHandler; the untyped terminals are the recorded set (#1615)" begin
    q() = GP.Race.objects
    OH = _GI_QB.ObjectHandler
    @test (@inferred (h -> h.filter("year" => 2009))(q())) isa OH
    @test (@inferred (h -> h.values("year"))(q())) isa OH
    @test (@inferred (h -> h.order_by("-year"))(q())) isa OH
    @test (@inferred (h -> h.limit(2))(q())) isa OH
    @test (@inferred (h -> h.offset(1))(q())) isa OH
    @test (@inferred (h -> h.page(2, 1))(q())) isa OH
    @test (@inferred (h -> h.distinct())(q())) isa OH
    @test (@inferred (h -> h.select_for_update())(q())) isa OH
    @test (@inferred (h -> h.db(_GI_KEY))(q())) isa OH
    @test (@inferred (h -> h.copy())(q())) isa OH
    @test (@inferred (h -> h.filter("year" => 2009).order_by("year").limit(1))(q())) isa OH

    # The terminals' inferred return types, no `T` given. `Any` (or a union of the inspection shapes)
    # because the result is a `PormGRow`, a `Dict` row, a driver value read through raw `fetch`, or an
    # inspection shape chosen by `show_query` at run time: JIT-only by #1605's contract.
    calls = (
        create           = h -> h.create("year" => 2009),
        update           = h -> h.update("year" => 2009),
        update_or_create = h -> h.update_or_create("raceid" => 1),
        get_or_create    = h -> h.get_or_create("raceid" => 1),
        count            = h -> h.count(),
        aggregate        = h -> h.aggregate("n" => _GI_QB.Count("raceid")),
        exists           = h -> h.exists(),
        first            = h -> h.first(),
        last             = h -> h.last(),
        earliest         = h -> h.earliest("year"),
        latest           = h -> h.latest("year"),
        get              = h -> h.get("raceid" => 1),
        list             = h -> h.list(),
        inspect          = h -> h.inspect(),
        explain          = h -> h.explain(),
        delete           = h -> h.delete(),
    )
    untyped = Symbol[]
    for (name, f) in pairs(calls)
        isconcretetype(only(Base.return_types(f, (OH,)))) || push!(untyped, name)
    end
    @test Set(untyped) == Set(keys(calls))
end

# ─────────────────────────────────────────────────────────────────────────────
# Tests: `getproperty(::ModelType, name)`: `objects`, the struct fields, an M2M accessor.
# Expected: `objects` → `ObjectHandler`; each struct field → its declared field type; the accessor
# `wins` → `ManyToManyDescriptor`.
# Matters: `M.Race.objects` is the first call of every query an app writes.
# ─────────────────────────────────────────────────────────────────────────────
@testset "ModelType properties infer: objects, struct fields, an M2M accessor (#1615)" begin
    MT = Models.ModelType
    @test _gi_property_type(MT, :objects) === _GI_QB.ObjectHandler
    @test (@inferred (m -> m.objects)(GP.Race)) isa _GI_QB.ObjectHandler
    for name in fieldnames(MT)
        @test (name, _gi_property_type(MT, name)) == (name, fieldtype(MT, name))
    end
    @test _gi_property_type(MT, :wins) === _GI_QB.ManyToManyDescriptor
    @test (@inferred (m -> m.wins)(GP.Driver)) isa _GI_QB.ManyToManyDescriptor
end

# ─────────────────────────────────────────────────────────────────────────────
# Tests: `getproperty(::PormGRow, …)`, `(::ManyToManyManager, …)` and `(::_BucketedQuery, …)`.
# Expected: the row's `_data`/`_model`/`_dirty`/`save`/`delete` and the manager's five verbs are
# concrete. A row's column read is `Any` (its `Dict{Symbol,Any}` cell: JIT-only, #1605). The bucketed
# collector's `parameters` is `Vector{Any}` and `parameter_count` is `Int`.
# Matters: the other overloads were never audited. Their literal names fold, and the column read is
# the documented exception.
# ─────────────────────────────────────────────────────────────────────────────
@testset "PormGRow, ManyToManyManager and _BucketedQuery properties (#1615)" begin
    R = _GI_QB.PormGRow
    @test fieldtype(R, :_model) === Models.ModelType
    @test _gi_property_type(R, :_data) === Dict{Symbol,Any}
    @test _gi_property_type(R, :_model) === Models.ModelType
    @test _gi_property_type(R, :_dirty) === Set{Symbol}
    @test isconcretetype(_gi_property_type(R, :save))
    @test isconcretetype(_gi_property_type(R, :delete))
    @test _gi_property_type(R, :surname) === Any          # a column: JIT-only by contract

    MM = _GI_QB.ManyToManyManager
    @test fieldtype(MM, :owner_model) === Models.ModelType
    @test fieldtype(MM, :related_model) === Models.ModelType
    for name in (:all, :add, :remove, :clear, :set)
        @test (name, isconcretetype(_gi_property_type(MM, name))) == (name, true)
    end
    @test _gi_property_type(MM, :relation) === Models.ManyToManyRelation

    for BQ in (_GI_QB.SQLiteParameterizedQuery, _GI_QB.MySQLParameterizedQuery)
        @test _gi_property_type(BQ, :parameters) === Vector{Any}
        @test _gi_property_type(BQ, :parameter_count) === Int
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# Tests: the query state's model slot, and the constructor without a model.
# Expected: `SQLObjectQuery.model::ModelType`; `SQLObjectQuery()` raises (no model, no query).
# Matters: W15 of round 3; the `model = nothing` default could only ever build a broken query.
# ─────────────────────────────────────────────────────────────────────────────
@testset "SQLObjectQuery.model is ModelType and is required (#1615)" begin
    @test fieldtype(_GI_QB.SQLObjectQuery, :model) === Models.ModelType
    @test fieldtype(_GI_QB.SQLObjectQuery, :limit) === Union{Nothing,Int}
    @test fieldtype(_GI_QB.SQLObjectQuery, :offset) === Int
    @test_throws UndefKeywordError _GI_QB.SQLObjectQuery()
    @test GP.Race.objects.object.model === GP.Race
    # A count past the `Int` slot is a `QueryBuildError`, not the slot conversion's `InexactError`.
    @test_throws PormG.QueryBuildError GP.Race.objects.limit(typemax(UInt64))
    @test_throws PormG.QueryBuildError GP.Race.objects.offset(big(typemax(Int)) + 1)
    @test GP.Race.objects.limit(Int32(5)).object.limit === 5
end
