"""
Typed-exception contract tests for the public query surface (#197, taxonomy #231).

This file tests:
- Representative fluent-surface misuse (filter, values, order_by, distinct, update kwargs,
  With/CTE names, Q/Qor construction) throws the RIGHT `PormGError` subtype — previously many
  of these sites threw raw Strings (not `Exception`s), then bare `ArgumentError` (#197); #231
  gives each a semantic type so callers `catch` a type instead of matching a message string.
- The internal dispatch fallback (`_unsupported_conn`) throws `UnsupportedConnectionError`
  (a `PormGError`), not the old `ErrorException`.

Every subtype below is `<: PormG.PormGError`, so `catch PormGError` still catches them all;
the specific-subtype/hierarchy contract lives in `test/unit/test_error_taxonomy.jl`.

No database is required: every assertion fires at query-build/validation time.
"""
# julia -t auto --project=. test/unit/test_typed_exceptions.jl

using Test
using PormG
using PormG.Models
using PormG.QueryBuilder: object, Q, Qor, With

const QB = PormG.QueryBuilder

# Minimal in-memory model — mirrors the mock-model pattern from
# test_field_validation_and_operations.jl. No connection, no settings needed:
# all the misuse below is rejected before any DB work.
typed_errs_model = Models.Model_Type(
    name = "typed_errs_test",
    fields = Dict(
        "id" => Models.IDField(),
        "points" => Models.IntegerField(),
    ),
    field_names = ["id", "points"]
)

# ─────────────────────────────────────────────────────────────────────────────
# filter() misuse → FilterError
# This site was the #197 poster child: filter() threw ErrorException while its
# values()/order_by() siblings threw ArgumentError. #231 gives it FilterError.
# ─────────────────────────────────────────────────────────────────────────────
@testset "filter() misuse is FilterError" begin
    q = object(typed_errs_model)
    # An Int is neither a Pair nor a Q/Qor/operator object.
    @test_throws PormG.FilterError q.filter(123)
end

# ─────────────────────────────────────────────────────────────────────────────
# values() misuse → QueryBuildError (projection-shape misuse)
# Three rejection paths in up_values!/_up_values: a non-String pair key, an
# operator suffix inside a projection, and a value of an unsupported type.
# ─────────────────────────────────────────────────────────────────────────────
@testset "values() misuse is QueryBuildError" begin
    q = object(typed_errs_model)
    # Pair key must be a String alias.
    @test_throws PormG.QueryBuildError q.values(1 => "points")
    # Operator suffixes belong in filter(), never in a projection.
    @test_throws PormG.QueryBuildError q.values("points__@gte")
    # Unsupported bare value type.
    @test_throws PormG.QueryBuildError q.values(3.14)
end

# ─────────────────────────────────────────────────────────────────────────────
# order_by() misuse → QueryBuildError
# Both order_by! rejection paths: an operator suffix inside an ordering field,
# and an argument that is neither String nor SQLTypeOrder.
# ─────────────────────────────────────────────────────────────────────────────
@testset "order_by() misuse is QueryBuildError" begin
    q = object(typed_errs_model)
    # Operator suffixes are meaningless in ORDER BY.
    @test_throws PormG.QueryBuildError q.order_by("points__@gte")
    # An Int can't name an ordering column (hits the generic fallback method).
    @test_throws PormG.QueryBuildError q.order_by(1)
end

# ─────────────────────────────────────────────────────────────────────────────
# distinct() misuse → QueryBuildError
# distinct() accepts only Bool (or no argument); anything else hits the typed
# fallback method.
# ─────────────────────────────────────────────────────────────────────────────
@testset "distinct() misuse is QueryBuildError" begin
    q = object(typed_errs_model)
    @test_throws PormG.QueryBuildError q.distinct("yes")
end

# ─────────────────────────────────────────────────────────────────────────────
# update() keyword misuse → QueryBuildError
# up_update! validates keywords BEFORE any build/DB work, so a typo'd kwarg
# (only :show_query is supported) is rejected with no settings needed.
# ─────────────────────────────────────────────────────────────────────────────
@testset "update() bad keyword is QueryBuildError" begin
    q = object(typed_errs_model)
    @test_throws PormG.QueryBuildError q.update("points" => 1, show_querys = :sql)
end

# ─────────────────────────────────────────────────────────────────────────────
# Q / Qor construction and push! → FilterError
# The Q/Qor constructors and Base.push! on Q objects validate their arguments;
# a non-Pair/non-filter entry is a filter-shape error.
# ─────────────────────────────────────────────────────────────────────────────
@testset "Q/Qor misuse is FilterError" begin
    @test_throws PormG.FilterError Q(123)
    @test_throws PormG.FilterError Qor(123)
    # push! onto an existing Q/Qor rejects non-Pair/non-filter entries too.
    @test_throws PormG.FilterError push!(Q("points" => 1), 123)
    @test_throws PormG.FilterError push!(Qor("points" => 1, "points" => 2), 123)
end

# ─────────────────────────────────────────────────────────────────────────────
# Duplicate CTE name via With() → QueryBuildError
# Registering two CTEs under one alias would render invalid SQL; With() rejects
# the second registration at the call site (integration twin lives in
# test/integration/test_cte.jl "With() duplicate CTE name is rejected").
# ─────────────────────────────────────────────────────────────────────────────
@testset "With() duplicate CTE name is QueryBuildError" begin
    q = object(typed_errs_model)
    sub = object(typed_errs_model)
    With(q, "dup", sub)
    @test_throws PormG.QueryBuildError With(q, "dup", sub)
end

# ─────────────────────────────────────────────────────────────────────────────
# ISNULL guard → FilterError
# ISNULL refuses a function expression as its column operand.
# ─────────────────────────────────────────────────────────────────────────────
@testset "ISNULL on function expression is FilterError" begin
    @test_throws PormG.FilterError QB.ISNULL("lower(points)", true)
end

# ─────────────────────────────────────────────────────────────────────────────
# Internal dispatch fallback helper → UnsupportedConnectionError
# _unsupported_conn is the shared fallback for execution paths reached with a
# connection that is neither PostgreSQL nor SQLite. #231 upgrades it from a bare
# ErrorException to the catchable UnsupportedConnectionError, still naming the
# operation and the offending type.
# ─────────────────────────────────────────────────────────────────────────────
@testset "_unsupported_conn is UnsupportedConnectionError with context" begin
    err = try
        QB._unsupported_conn("unit-test-op", nothing)
    catch e
        e
    end
    @test err isa PormG.UnsupportedConnectionError
    @test err isa PormG.PormGError               # still under the taxonomy root
    @test !(err isa ErrorException)              # #231: no longer a bare ErrorException
    @test occursin("unit-test-op", err.msg)      # names the operation
    @test occursin("Nothing", err.msg)           # names the offending type
end
