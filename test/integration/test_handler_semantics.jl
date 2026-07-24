if !isdefined(Main, :PormG)
    include("common_setup.jl")
end

# This file pins the fluent-surface mutation semantics settled in #199:
#   - chain methods mutate the handler in place; filter() ACCUMULATES across calls,
#     while values()/order_by() REPLACE their previous call (Django parity);
#   - read terminals (count/exists/list/first/get) NEVER mutate the handler — they
#     execute on an internal copy, so a handler stays reusable after any of them.
# Flipping either behavior after publish would be silently breaking, so these tests
# are the contract.

# ─────────────────────────────────────────────────────────────────────────────
# Handler semantics: filter() re-call accumulates
# Two successive filter() calls must AND together (narrowing the result), not
# replace each other — both predicates stay on the handler and in the SQL.
# ─────────────────────────────────────────────────────────────────────────────
@testset "filter() re-call accumulates" begin
    q = M.Result.objects
    q.filter("raceid__year" => 2021)
    n_year = q.count()
    @test n_year > 1                       # sanity: 2021 season is seeded

    q.filter("positionorder" => 1)         # second call must narrow, not reset
    n_both = q.count()

    @test length(q.object.filter) == 2     # both predicates live on the handler
    @test 0 < n_both < n_year              # ANDed: strictly narrower than year alone

    # SQL shape: both predicates render in the same WHERE clause
    sql = q.list(show_query=:sql)
    @test occursin("year", sql)
    @test occursin("positionorder", sql)
end

# ─────────────────────────────────────────────────────────────────────────────
# Handler semantics: values() re-call is last-call-wins
# A second values() call replaces the projection entirely (Django parity) — the
# result exposes only the columns of the last call.
# ─────────────────────────────────────────────────────────────────────────────
@testset "values() re-call replaces the projection" begin
    q = M.Driver.objects.filter("driverref" => "hamilton")
    q.values("forename")
    q.values("surname")                    # replaces the "forename" projection

    @test length(q.object.values) == 1     # only the last projection remains

    row = q.list()[1]
    @test haskey(row, :surname)            # last call's column is selected …
    @test !haskey(row, :forename)          # … the first call's column is gone
end

# ─────────────────────────────────────────────────────────────────────────────
# Handler semantics: order_by() re-call is last-call-wins
# A second order_by() call clears the previous ordering (Django: "each order_by()
# call will clear any previous ordering") — only the last sort key applies.
# ─────────────────────────────────────────────────────────────────────────────
@testset "order_by() re-call replaces the ordering" begin
    q = M.Driver.objects.filter("nationality" => "British").values("surname")
    q.order_by("surname")
    q.order_by("-surname")                 # replaces ASC ordering with DESC

    @test length(q.object.order) == 1      # only the last ordering remains

    surnames = [r[:surname] for r in q.list()]
    @test length(surnames) > 1             # sanity: enough rows to observe order

    # Behavioral proof that the ASC call was CLEARED (not composed into a secondary
    # sort key): the re-called handler must return rows in the same order as a fresh
    # handler ordered only by "-surname". Comparing two DB queries — rather than to
    # Julia's `sort` — keeps this collation-robust: SQLite (BINARY) and PostgreSQL
    # (locale collation) order mixed-case names like "di Resta" differently, and only
    # the database's own ordering is the contract here. Had order_by accumulated, the
    # composed `surname ASC, surname DESC` would sort ascending and diverge from this.
    reference = [r[:surname] for r in
        M.Driver.objects.filter("nationality" => "British").values("surname").
            order_by("-surname").list()]
    @test surnames == reference
end

# ─────────────────────────────────────────────────────────────────────────────
# Handler semantics: first() does not mutate the handler (#199)
# first() used to permanently set limit(1) on the handler, breaking reuse (and
# making a follow-up update() throw "UPDATE with LIMIT"). It now executes on an
# internal copy: the handler keeps limit=0 and re-executes with all rows.
# ─────────────────────────────────────────────────────────────────────────────
@testset "first() leaves the handler unchanged" begin
    q = M.Driver.objects.filter("nationality" => "British")
    total = q.count()
    @test total > 1                        # sanity: first() must actually truncate

    d = q.first()
    @test d isa PormGRow

    @test q.object.limit == 0              # no limit(1) leaked into the handler
    @test length(q.list()) == total        # re-execution still returns every row
end

# ─────────────────────────────────────────────────────────────────────────────
# Handler semantics: first() then update() on the same handler (#199)
# The old mutate-first behavior made this exact sequence throw ("UPDATE with
# LIMIT/OFFSET is not supported"). With copy-first terminals it is valid. Uses
# the scratch model so the F1 fixture data stays untouched; explicit cleanup.
# ─────────────────────────────────────────────────────────────────────────────
@testset "first() then update() on the same handler" begin
    row = M.Just_a_test_deletion.objects.create("name" => "handler_semantics_199")
    try
        q = M.Just_a_test_deletion.objects.filter("name" => "handler_semantics_199")
        @test q.first() isa PormGRow

        # The former footgun: this threw because first() had left limit=1 behind
        q.update("name" => "handler_semantics_199_updated")

        updated = M.Just_a_test_deletion.objects.get("id" => row.id)
        @test updated.name == "handler_semantics_199_updated"
    finally
        M.Just_a_test_deletion.objects.filter("id" => row.id).delete()
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# Handler semantics: get() inline filters do not persist (#199)
# get(q, filters...) used to append its inline filters to the handler before
# copying — reusing the handler afterwards silently kept them. Now the filters
# apply to the internal copy only, while error messages still report them.
# ─────────────────────────────────────────────────────────────────────────────
@testset "get() inline filters stay off the handler" begin
    q = M.Driver.objects
    driver = q.get("driverref" => "hamilton")
    @test driver.surname == "Hamilton"

    @test isempty(q.object.filter)         # inline filter did not persist
    @test q.count() > 1                    # handler still matches every driver

    # The typed errors still describe the inline filters (taken from the copy)
    err = try
        M.Driver.objects.get("driverref" => "pormg_missing_199")
    catch e
        e
    end
    @test err isa DoesNotExist
    @test occursin("driverref", err.filters)
end
