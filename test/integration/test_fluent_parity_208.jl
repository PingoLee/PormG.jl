# test/integration/test_fluent_parity_208.jl
#
# End-to-end coverage for the #208 fluent parity terminals against real adapters (db_2 =
# PostgreSQL, db_sl = SQLite). Row correctness — the questions the unit SQL-rendering tests
# cannot answer: does get_or_create actually match-or-insert without updating on a hit; does
# last()/earliest()/latest() return the right extreme row; does aggregate() compute the right
# scalars; does row.delete() actually remove the row through the shared collector.
#
# Ordering is asserted only on NUMERIC columns (points / integer pk) — never on text — because
# PostgreSQL's locale collation and SQLite's BINARY collation disagree on string order.

if !isdefined(Main, :PormG)
    include("common_setup.jl")
end

@testset "get_or_create (#208)" begin
    # M.Status: pk `statusid` is UNIQUE (the ON CONFLICT target); `status` is a plain, non-unique
    # column used below to prove the missing-unique-constraint guard. High pk avoids seeded data.
    sid = 360001
    cleanup() = (q = M.Status.objects.filter("statusid" => sid); q.exists() && q.delete())
    cleanup()
    try
        # 1. Miss → INSERT, created == true, PormGRow carries the inserted values.
        row, created = M.Status.objects.get_or_create("statusid" => sid; defaults = ["status" => "First"])
        @test created === true
        @test row isa PormG.QueryBuilder.PormGRow
        @test row.statusid == sid
        @test row.status == "First"
        @test M.Status.objects.filter("statusid" => sid).count() == 1

        # 2. Hit → NO update (the defining difference from update_or_create). New defaults are
        #    ignored; the existing row is returned unchanged, count is unchanged.
        row2, created2 = M.Status.objects.get_or_create("statusid" => sid; defaults = ["status" => "Second"])
        @test created2 === false
        @test row2.status == "First"          # unchanged — NOT "Second"
        @test M.Status.objects.filter("statusid" => sid).count() == 1
        persisted = M.Status.objects.filter("statusid" => sid).values("status").list() |> first
        @test persisted[:status] == "First"

        # 3. Pure get-or-create (no defaults) on a hit also returns the existing row.
        row3, created3 = M.Status.objects.get_or_create("statusid" => sid)
        @test created3 === false
        @test row3.status == "First"
    finally
        cleanup()
    end
end

@testset "get_or_create requires a unique constraint on the lookup (#208)" begin
    # `status` has no unique constraint, so ON CONFLICT (status) has no matching target — PormG
    # re-raises the driver error as an actionable PormGError (the Django-divergence edge). The
    # statement is rejected before inserting, so nothing is created; clean up defensively anyway.
    marker = "pormg_no_unique_status_208"
    err = try
        M.Status.objects.get_or_create("status" => marker); nothing
    catch e
        e
    end
    @test err isa PormGError
    @test occursin("unique constraint", PormG._emsg(sprint(showerror, err); color = false))
    residual = M.Status.objects.filter("status" => marker)
    residual.exists() && residual.delete()
end

@testset "last / earliest / latest (#208)" begin
    # A populated, bounded subset: one race's results, ordered by the numeric `points` column.
    raceid = (M.Result.objects.values("raceid").list() |> first)[:raceid]
    fresh() = M.Result.objects.filter("raceid" => raceid)

    pts = [r[:points] for r in fresh().values("points").list()]
    @test !isempty(pts)
    lo, hi = minimum(pts), maximum(pts)

    # first()/last() under an explicit ordering are exact mirrors: last() == first() reversed.
    @test fresh().order_by("points").first().points == lo
    @test fresh().order_by("points").last().points == hi     # last() inverts ASC → DESC

    # earliest()/latest() order by the given field; a leading "-" flips it (latest("f")==earliest("-f")).
    @test fresh().earliest("points").points == lo
    @test fresh().latest("points").points == hi
    @test fresh().latest("points").points == fresh().earliest("-points").points

    # last() with NO order_by falls back to primary-key (resultid) DESC → the max-pk row.
    max_pk = maximum(r[:resultid] for r in fresh().values("resultid").list())
    @test fresh().last().resultid == max_pk

    # Empty queryset: earliest/latest RAISE (like get()); first/last RETURN nothing.
    empty = M.Result.objects.filter("raceid" => -999_999)
    @test empty.last() === nothing
    @test empty.first() === nothing
    @test_throws PormG.DoesNotExist M.Result.objects.filter("raceid" => -999_999).earliest("points")
    @test_throws PormG.DoesNotExist M.Result.objects.filter("raceid" => -999_999).latest("points")
end

@testset "aggregate (#208)" begin
    raceid = (M.Result.objects.values("raceid").list() |> first)[:raceid]
    fresh() = M.Result.objects.filter("raceid" => raceid)

    # Whole-queryset aggregation → a single-row NamedTuple with dot-access.
    agg = fresh().aggregate(
        "total" => Sum("points"),
        "n"     => Count("resultid"),
        "avg"   => Avg("points"),
    )
    raw = [r[:points] for r in fresh().values("points").list()]
    @test agg.total ≈ sum(raw)
    @test agg.n == length(raw)
    @test agg.avg ≈ sum(raw) / length(raw)

    # aggregate() must match the blessed values()+single-row list() workaround it sugars over.
    viaValues = fresh().values("total" => Sum("points"), "n" => Count("resultid")).list() |> first
    @test agg.total ≈ viaValues[:total]
    @test agg.n == viaValues[:n]

    # Refuses to silently discard values() grouping columns.
    @test_throws PormGError fresh().values("driverid").aggregate("total" => Sum("points"))
end

@testset "row.delete() (#208)" begin
    # Create a disposable Status row, fetch it, and delete THROUGH the row — the same collector
    # path as queryset delete, so it returns the (total, per-model counts) tuple. High pk keeps it
    # clear of both seeded data and the get_or_create block above.
    sid = 360002
    cleanup() = (q = M.Status.objects.filter("statusid" => sid); q.exists() && q.delete())
    cleanup()
    try
        M.Status.objects.create("statusid" => sid, "status" => "ToDelete")
        row = M.Status.objects.get("statusid" => sid)
        @test row isa PormG.QueryBuilder.PormGRow

        total, counts = row.delete()
        @test total >= 1
        @test counts isa AbstractDict
        @test M.Status.objects.filter("statusid" => sid).exists() == false
    finally
        cleanup()
    end
end
