"""
Typed-exception contract tests for the public query surface (#197).

This file tests:
- Representative fluent-surface misuse (filter, values, order_by, distinct, update kwargs,
  With/CTE names, Q/Qor construction) throws a typed `ArgumentError` — previously many of
  these sites threw raw Strings, which are NOT `Exception`s and escape every
  `catch e; e isa Exception` handler a package user can write
- Internal dispatch fallbacks throw `ErrorException` (via `_unsupported_conn`)

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
# Typed exceptions: filter() misuse
# A non-Pair/non-Q filter argument must raise ArgumentError. This site was the
# #197 poster child: filter() threw ErrorException while its values()/order_by()
# siblings threw ArgumentError — same surface, different types.
# ─────────────────────────────────────────────────────────────────────────────
@testset "filter() misuse is ArgumentError" begin
    q = object(typed_errs_model)
    # An Int is neither a Pair nor a Q/Qor/operator object.
    @test_throws ArgumentError q.filter(123)
end

# ─────────────────────────────────────────────────────────────────────────────
# Typed exceptions: values() misuse
# Three rejection paths in up_values!/_up_values, all previously raw-String throws:
# a non-String pair key, an operator suffix inside a projection, and (pre-typed
# since #92, pinned here) a value of an unsupported type.
# ─────────────────────────────────────────────────────────────────────────────
@testset "values() misuse is ArgumentError" begin
    q = object(typed_errs_model)
    # Pair key must be a String alias.
    @test_throws ArgumentError q.values(1 => "points")
    # Operator suffixes belong in filter(), never in a projection.
    @test_throws ArgumentError q.values("points__@gte")
    # Unsupported bare value type (already typed by #92 — regression pin).
    @test_throws ArgumentError q.values(3.14)
end

# ─────────────────────────────────────────────────────────────────────────────
# Typed exceptions: order_by() misuse
# Both order_by! rejection paths: an operator suffix inside an ordering field,
# and an argument that is neither String nor SQLTypeOrder.
# ─────────────────────────────────────────────────────────────────────────────
@testset "order_by() misuse is ArgumentError" begin
    q = object(typed_errs_model)
    # Operator suffixes are meaningless in ORDER BY.
    @test_throws ArgumentError q.order_by("points__@gte")
    # An Int can't name an ordering column (hits the generic fallback method).
    @test_throws ArgumentError q.order_by(1)
end

# ─────────────────────────────────────────────────────────────────────────────
# Typed exceptions: distinct() misuse
# distinct() accepts only Bool (or no argument); anything else hits the typed
# fallback method.
# ─────────────────────────────────────────────────────────────────────────────
@testset "distinct() misuse is ArgumentError" begin
    q = object(typed_errs_model)
    @test_throws ArgumentError q.distinct("yes")
end

# ─────────────────────────────────────────────────────────────────────────────
# Typed exceptions: update() keyword misuse
# up_update! validates keywords BEFORE any build/DB work, so a typo'd kwarg
# (only :show_query is supported) is a pure ArgumentError — no settings needed.
# ─────────────────────────────────────────────────────────────────────────────
@testset "update() bad keyword is ArgumentError" begin
    q = object(typed_errs_model)
    @test_throws ArgumentError q.update("points" => 1, show_querys = :sql)
end

# ─────────────────────────────────────────────────────────────────────────────
# Typed exceptions: Q / Qor construction and push!
# The Q/Qor constructors and Base.push! on Q objects validate their arguments;
# all four rejection paths were raw-String throws before #197.
# ─────────────────────────────────────────────────────────────────────────────
@testset "Q/Qor misuse is ArgumentError" begin
    @test_throws ArgumentError Q(123)
    @test_throws ArgumentError Qor(123)
    # push! onto an existing Q/Qor rejects non-Pair/non-filter entries too.
    @test_throws ArgumentError push!(Q("points" => 1), 123)
    @test_throws ArgumentError push!(Qor("points" => 1, "points" => 2), 123)
end

# ─────────────────────────────────────────────────────────────────────────────
# Typed exceptions: duplicate CTE name via With()
# Registering two CTEs under one alias would render invalid SQL; With() rejects
# the second registration at the call site (integration twin lives in
# test/integration/test_cte.jl "With() duplicate CTE name is rejected").
# ─────────────────────────────────────────────────────────────────────────────
@testset "With() duplicate CTE name is ArgumentError" begin
    q = object(typed_errs_model)
    sub = object(typed_errs_model)
    With(q, "dup", sub)
    @test_throws ArgumentError With(q, "dup", sub)
end

# ─────────────────────────────────────────────────────────────────────────────
# Typed exceptions: ISNULL guard
# ISNULL refuses a function expression as its column operand.
# ─────────────────────────────────────────────────────────────────────────────
@testset "ISNULL on function expression is ArgumentError" begin
    @test_throws ArgumentError QB.ISNULL("lower(points)", true)
end

# ─────────────────────────────────────────────────────────────────────────────
# Typed exceptions: internal dispatch fallback helper
# _unsupported_conn is the shared fallback for execution paths reached with a
# connection that is neither PostgreSQL nor SQLite. It must throw a REAL
# exception (ErrorException) naming the operation and the offending type —
# these sites were raw "Unsupported connection type" String throws before #197.
# ─────────────────────────────────────────────────────────────────────────────
@testset "_unsupported_conn is ErrorException with context" begin
    err = try
        QB._unsupported_conn("unit-test-op", nothing)
    catch e
        e
    end
    @test err isa ErrorException
    @test occursin("unit-test-op", err.msg)     # names the operation
    @test occursin("Nothing", err.msg)          # names the offending type
end
