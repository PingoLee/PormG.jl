# julia -t auto --project=. test/integration/test_docs_error_types.jl

if !isdefined(Main, :PormG)
    include("common_setup.jl")
end

"""
Documented error types that need live data (#239).

Companion to `test/unit/test_docs_error_types.jl`, which pins every `docs/src` "this raises `X`"
claim that fires at query-build time against mock connections — that file is the CI-enforced half,
since `test/integration/` is excluded from CI (it needs a live PostgreSQL).

What lands here is only what a mock genuinely cannot reach: a claim needing a *fetched row*, a
real *insert* path, or a real *reverse relation*. Three of them.
"""

# ─────────────────────────────────────────────────────────────────────────────
# read/index.md + read/values_and_joins.md — unprojected ForeignKey read
# Both pages promise a LazyTraversalError when a FK that was not projected is read off a fetched
# row. Needs a real row, so it cannot move to the unit half.
# ─────────────────────────────────────────────────────────────────────────────
@testset "docs: unprojected FK read raises LazyTraversalError" begin
    row = M.Result.objects.values("resultid", "points").first()
    # Guard the fixture, not the contract: an empty results table would make the assertion below
    # vacuous, so fail on the fixture rather than pass silently.
    @test row !== nothing

    err = try
        row.driverid
        nothing
    catch e
        e
    end
    @test err !== nothing
    @test err isa LazyTraversalError
    @test !(err isa ArgumentError)
end

# ─────────────────────────────────────────────────────────────────────────────
# write/create.md — create() rejects a missing NOT NULL field
# The page prints the exact message, so assert the text as well as the type: a different
# InvalidValueError (a coercion failure, say) would otherwise satisfy the type check and let the
# documented message rot. Validation fires before any SQL, so nothing is inserted and there is
# nothing to clean up.
# ─────────────────────────────────────────────────────────────────────────────
@testset "docs: create() missing required field raises InvalidValueError" begin
    err = try
        M.Driver.objects.create(
            "forename" => "Docs", "surname" => "Guard", "nationality" => "British")
        nothing
    catch e
        e
    end
    @test err !== nothing
    @test err isa InvalidValueError
    @test !(err isa ArgumentError)
    # docs/src/write/create.md shows: "Error in insert, the field driverref not allow null"
    @test occursin("driverref", err.msg)
end

# ─────────────────────────────────────────────────────────────────────────────
# read/filters_and_aggregates.md — #74 fan-out guard refuses an inflated aggregate
# Needs a real reverse relation (driver_standings), which a synthetic mock model set does not
# provide. Existing coverage in test_sql_functions.jl / test_subqueries.jl asserts
# `isa PormGError` + the message; this pins the concrete subtype the docs now name.
# ─────────────────────────────────────────────────────────────────────────────
@testset "docs: fan-out guard raises QueryBuildError" begin
    query = M.Driver.objects
    query.values("nationality", "n" => Count("driverid"))
    query.filter("driver_standings__position__@gte" => 1)

    err = try
        query.list()
        nothing
    catch e
        e
    end
    @test err !== nothing
    @test err isa QueryBuildError
    @test !(err isa ArgumentError)
    # Confirm it is the fan-out guard, not an unrelated QueryBuildError from the same call.
    @test occursin("fan-out", err.msg)
end
