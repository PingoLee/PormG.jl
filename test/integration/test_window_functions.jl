# julia -t auto --project=. test/integration/test_window_functions.jl

if !isdefined(Main, :PormG)
    include("common_setup.jl")
end

import PormG.QueryBuilder: WindowOver, Rank, DenseRank, RowNumber, Lag, Lead, FirstValue, LastValue, NthValue, Count, F

# ─────────────────────────────────────────────────────────────────────────────
# Window Functions: row numbers over standings partitions
# Each race keeps all driver-standing rows while ROW_NUMBER ranks rows inside
# that race by points. This verifies the public API emits executable window SQL
# without collapsing rows through GROUP BY.
# ─────────────────────────────────────────────────────────────────────────────
@testset "Window ROW_NUMBER ranks driver standings per race" begin
    q = M.Driver_standings.objects
    q.filter("raceid__year" => 1991)
    q.values(
        "raceid",
        "driverid",
        "points",
        "race_rank" => RowNumber(over=WindowOver(partition_by=["raceid"], order_by=["-points", "driverid"]))
    )
    q.order_by("raceid", "race_rank")

    rows = q.list()

    @test !isempty(rows)
    first_rank_by_race = Dict{Any,Any}()
    for row in rows
        raceid = row[:raceid]
        get!(first_rank_by_race, raceid, row[:race_rank])
    end

    @test all(row -> row[:race_rank] >= 1, rows)
    @test all(==(1), values(first_rank_by_race))
end

# ─────────────────────────────────────────────────────────────────────────────
# Window Functions: LAG reads the previous ordered row
# For one seeded driver/race lap stream, previous_ms should equal the prior row's
# milliseconds value after ordering by lap, while the first row uses the default.
# ─────────────────────────────────────────────────────────────────────────────
@testset "Window LAG returns previous lap milliseconds" begin
    seed_rows = M.Lap_times.objects.values("raceid", "driverid").limit(1).list()
    @test !isempty(seed_rows)

    seed = first(seed_rows)
    q = M.Lap_times.objects
    q.filter("raceid" => seed[:raceid], "driverid" => seed[:driverid])
    q.values(
        "lap",
        "milliseconds",
        "previous_ms" => Lag("milliseconds", offset=1, default=0, over=WindowOver(order_by=["lap"]))
    )
    q.order_by("lap")

    rows = q.list()

    @test !isempty(rows)
    @test rows[1][:previous_ms] == 0
    if length(rows) > 1
        @test rows[2][:previous_ms] == rows[1][:milliseconds]
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# Window Functions: quick-start race ranking matches the documented output
# This exercises the public `Rank` API end to end against the Formula 1
# fixtures, including the per-race reset and the tie gaps described in the docs.
# ─────────────────────────────────────────────────────────────────────────────
@testset "Window RANK matches the documented per-race standings example" begin
    query = M.Driver_standings.objects
    query.filter("raceid__@in" => [305, 306], "points__@gt" => 0)
    query.values(
        "raceid",
        "driverid__surname",
        "points",
        "race_rank" => Rank(over=WindowOver(partition_by=["raceid"], order_by=["-points"]))
    )
    query.order_by("raceid", "race_rank")

    rows = query.list()

    expected = Dict(
        (305, "Senna") => (10.0, 1),
        (305, "Prost") => (6.0, 2),
        (305, "Piquet") => (4.0, 3),
        (305, "Modena") => (3.0, 4),
        (305, "Nakajima") => (2.0, 5),
        (305, "Suzuki") => (1.0, 6),
        (306, "Senna") => (20.0, 1),
        (306, "Prost") => (9.0, 2),
        (306, "Piquet") => (6.0, 3),
        (306, "Patrese") => (6.0, 3),
        (306, "Berger") => (4.0, 5),
        (306, "Modena") => (3.0, 6),
        (306, "Nakajima") => (2.0, 7),
        (306, "Suzuki") => (1.0, 8),
        (306, "Alesi") => (1.0, 8),
    )

    observed = Dict((row[:raceid], row[:driverid__surname]) => (row[:points], row[:race_rank]) for row in rows)
    @test observed == expected
end

# ─────────────────────────────────────────────────────────────────────────────
# Window Functions: constructor partitions rank independently from each other
# This mirrors the partition-only example from the docs and proves the rank
# resets at each constructor boundary while tied zero-point rows share rank 1.
# ─────────────────────────────────────────────────────────────────────────────
@testset "Window RANK restarts independently for each constructor" begin
    query = M.Result.objects
    query.filter("raceid" => 306)
    query.values(
        "constructorid",
        "driverid__surname",
        "points",
        "constructor_rank" => Rank(over=WindowOver(partition_by=["constructorid"], order_by=["-points"]))
    )
    query.order_by("constructorid", "constructor_rank")

    rows = query.list()
    by_pair = Dict((row[:constructorid], row[:driverid__surname]) => row for row in rows)

    @test by_pair[(1, "Senna")][:constructor_rank] == 1
    @test by_pair[(1, "Berger")][:constructor_rank] == 2
    @test by_pair[(3, "Patrese")][:constructor_rank] == 1
    @test by_pair[(3, "Mansell")][:constructor_rank] == 2
    @test by_pair[(6, "Prost")][:constructor_rank] == 1
    @test by_pair[(6, "Alesi")][:constructor_rank] == 2

    jordan_rows = filter(row -> row[:constructorid] == 17, rows)
    @test Set(row[:driverid__surname] for row in jordan_rows) == Set(["Gachot", "de Cesaris"])
    @test all(row[:points] == 0.0 for row in jordan_rows)
    @test all(row[:constructor_rank] == 1 for row in jordan_rows)
end

# ─────────────────────────────────────────────────────────────────────────────
# Window Functions: ranking variants expose gap, dense, and unique numbering
# Race 306 has two tie groups, so it is the cheapest executable check for the
# documented differences between Rank, DenseRank, and RowNumber.
# ─────────────────────────────────────────────────────────────────────────────
@testset "Window ranking variants handle ties as documented" begin
    query = M.Driver_standings.objects
    query.filter("raceid" => 306, "points__@gt" => 0)
    query.values(
        "driverid__surname",
        "points",
        "rank" => Rank(over=WindowOver(partition_by=["raceid"], order_by=["-points"])),
        "dense_rank" => DenseRank(over=WindowOver(partition_by=["raceid"], order_by=["-points"])),
        "row_number" => RowNumber(over=WindowOver(partition_by=["raceid"], order_by=["-points", "driverid"]))
    )
    query.order_by("row_number")

    rows = query.list()
    by_surname = Dict(row[:driverid__surname] => row for row in rows)

    @test by_surname["Senna"][:rank] == 1
    @test by_surname["Prost"][:rank] == 2
    @test by_surname["Piquet"][:rank] == 3
    @test by_surname["Patrese"][:rank] == 3
    @test by_surname["Berger"][:rank] == 5
    @test by_surname["Berger"][:dense_rank] == 4
    @test by_surname["Suzuki"][:dense_rank] == 7
    @test by_surname["Alesi"][:dense_rank] == 7
    @test Set([by_surname["Piquet"][:row_number], by_surname["Patrese"][:row_number]]) == Set([3, 4])
    @test Set([by_surname["Suzuki"][:row_number], by_surname["Alesi"][:row_number]]) == Set([8, 9])
    @test sort([row[:row_number] for row in rows]) == collect(1:length(rows))
end

# ─────────────────────────────────────────────────────────────────────────────
# Window Functions: order-only lag matches the documented eight-lap sample
# This keeps the public example executable by asserting the exact first eight
# laps for the seeded 2011 stream, including the missing first previous value.
# ─────────────────────────────────────────────────────────────────────────────
@testset "Window LAG matches the documented ordered lap stream" begin
    query = M.Lap_times.objects
    query.filter("raceid" => 841, "driverid" => 1, "lap__@lte" => 8)
    query.values(
        "lap",
        "milliseconds",
        "prev_ms" => Lag("milliseconds", over=WindowOver(order_by=["lap"]))
    )
    query.order_by("lap")

    rows = query.list()
    expected = [
        (1, 100573, missing),
        (2, 93774, 100573),
        (3, 92900, 93774),
        (4, 92582, 92900),
        (5, 92471, 92582),
        (6, 92434, 92471),
        (7, 92447, 92434),
        (8, 92310, 92447),
    ]

    observed = [(row[:lap], row[:milliseconds], row[:prev_ms]) for row in rows]
    @test isequal(observed, expected)
end

# ─────────────────────────────────────────────────────────────────────────────
# Window Functions: FIRST_VALUE broadcasts the winner's points to each row
# This is the global-frame example from the docs: no partitioning, just one
# ordered result set where every row can see the same first finisher.
# ─────────────────────────────────────────────────────────────────────────────
@testset "Window FIRST_VALUE broadcasts winner points across a race result" begin
    query = M.Result.objects
    query.filter("raceid" => 306, "positionorder__@lte" => 8)
    query.values(
        "driverid__surname",
        "positionorder",
        "points",
        "winner_pts" => FirstValue("points", over=WindowOver(order_by=["positionorder"]))
    )
    query.order_by("positionorder")

    rows = query.list()
    expected = [
        ("Senna", 1, 10.0, 10.0),
        ("Patrese", 2, 6.0, 10.0),
        ("Berger", 3, 4.0, 10.0),
        ("Prost", 4, 3.0, 10.0),
        ("Piquet", 5, 2.0, 10.0),
        ("Alesi", 6, 1.0, 10.0),
        ("Moreno", 7, 0.0, 10.0),
        ("Morbidelli", 8, 0.0, 10.0),
    ]

    @test [(row[:driverid__surname], row[:positionorder], row[:points], row[:winner_pts]) for row in rows] == expected
end

# ─────────────────────────────────────────────────────────────────────────────
# Window Functions: LEAD and arithmetic stay aligned with the ordered lap rows
# This verifies the public API computes both the forward lookup and the derived
# arithmetic expressions inside SQL rather than post-processing in Julia.
# ─────────────────────────────────────────────────────────────────────────────
@testset "Window LEAD and arithmetic expressions follow the lap order" begin
    spec = WindowOver(order_by=["lap"])

    query = M.Lap_times.objects
    query.filter("raceid" => 841, "driverid" => 1)
    query.values(
        "lap",
        "milliseconds",
        "zero_based" => RowNumber(over=spec) - 1,
        "delta_ms" => Lag("milliseconds", over=spec) - F("milliseconds"),
        "next_ms" => Lead("milliseconds", offset=1, default=0, over=spec)
    )
    query.order_by("lap")

    rows = query.list()

    @test !isempty(rows)
    @test rows[1][:lap] == 1
    @test rows[1][:zero_based] == 0
    @test isequal(rows[1][:delta_ms], missing)
    @test rows[1][:next_ms] == rows[2][:milliseconds]
    @test rows[2][:zero_based] == 1
    @test rows[2][:delta_ms] == rows[1][:milliseconds] - rows[2][:milliseconds]
    @test rows[end][:zero_based] == length(rows) - 1
    @test rows[end][:next_ms] == 0
end

# ─────────────────────────────────────────────────────────────────────────────
# Window Functions: FIRST/LAST/NTH value semantics match the docs example
# The same race proves three different behaviors at once: broadcast-first,
# current-frame-last, and nth-value becoming visible once the frame is large enough.
# ─────────────────────────────────────────────────────────────────────────────
@testset "Window value functions expose first, current-frame last, and nth value semantics" begin
    spec = WindowOver(partition_by=["raceid"], order_by=["positionorder"])

    query = M.Result.objects
    query.filter("raceid" => 841)
    query.values(
        "raceid",
        "driverid",
        "positionorder",
        "points",
        "winner_pts" => FirstValue("points", over=spec),
        "last_pts" => LastValue("points", over=spec),
        "second_pts" => NthValue("points", 2, over=spec)
    )
    query.order_by("positionorder")

    rows = query.list()
    first_ten = rows[1:10]
    expected = [
        (1, 25.0, 25.0, 25.0, missing),
        (2, 18.0, 25.0, 18.0, 18.0),
        (3, 15.0, 25.0, 15.0, 18.0),
        (4, 12.0, 25.0, 12.0, 18.0),
        (5, 10.0, 25.0, 10.0, 18.0),
        (6, 8.0, 25.0, 8.0, 18.0),
        (7, 6.0, 25.0, 6.0, 18.0),
        (8, 4.0, 25.0, 4.0, 18.0),
        (9, 2.0, 25.0, 2.0, 18.0),
        (10, 1.0, 25.0, 1.0, 18.0),
    ]

    observed = [
        (row[:positionorder], row[:points], row[:winner_pts], row[:last_pts], row[:second_pts])
        for row in first_ten
    ]
    @test isequal(observed, expected)
end

# ─────────────────────────────────────────────────────────────────────────────
# Window Functions: explicit frames change LastValue semantics on PostgreSQL
# The documented frame trap is backend-specific, so this executable regression
# runs only where explicit frames are supported and skips cleanly on SQLite.
# ─────────────────────────────────────────────────────────────────────────────
if adapter_name == "SQLite"
    @info "Skipping PostgreSQL-only LastValue frame integration test on SQLite"
else
    @testset "Window LastValue full-frame semantics match the PostgreSQL example" begin
        spec_default = WindowOver(
            partition_by=["constructorid"],
            order_by=["positionorder"]
        )
        spec_full = WindowOver(
            partition_by=["constructorid"],
            order_by=["positionorder"],
            frame="ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING"
        )

        query = M.Result.objects
        query.filter("raceid" => 841, "constructorid__@in" => [1, 3])
        query.values(
            "constructorid",
            "driverid__surname",
            "positionorder",
            "points",
            "last_default" => LastValue("points", over=spec_default),
            "last_full" => LastValue("points", over=spec_full)
        )
        query.order_by("constructorid", "positionorder")

        rows = query.list()
        expected = [
            (1, "Hamilton", 2, 18.0, 18.0, 8.0),
            (1, "Button", 6, 8.0, 8.0, 8.0),
            (3, "Barrichello", 16, 0.0, 0.0, 0.0),
            (3, "Maldonado", 20, 0.0, 0.0, 0.0),
        ]

        observed = [
            (row[:constructorid], row[:driverid__surname], row[:positionorder], row[:points], row[:last_default], row[:last_full])
            for row in rows
        ]
        @test observed == expected
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# Window Functions: aggregates and windows coexist through the public API
# This proves the HAVING-on-aggregate path still returns executable rows while
# the window rank resets per constructor and the alias remains usable in ORDER BY.
# ─────────────────────────────────────────────────────────────────────────────
@testset "Window Rank coexists with Count and HAVING through the public API" begin
    query = M.Result.objects
    query.filter("driverid__@in" => [1, 20], "points__@gt" => 0)
    query.values(
        "constructorid",
        "driverid__surname",
        "points",
        "total_results" => Count("resultid"),
        "pts_rank" => Rank(over=WindowOver(partition_by=["constructorid"], order_by=["-points"]))
    )
    query.filter("total_results__@gt" => 1)
    query.order_by("constructorid", "pts_rank")

    rows = query.list()

    @test !isempty(rows)
    @test all(row[:total_results] > 1 for row in rows)

    grouped_rows = Dict{Any,Vector{typeof(first(rows))}}()
    for row in rows
        push!(get!(()->Vector{typeof(first(rows))}(), grouped_rows, row[:constructorid]), row)
    end

    @test all(group_rows -> group_rows[1][:pts_rank] == 1, values(grouped_rows))
    @test all(group_rows -> issorted([row[:points] for row in group_rows]; rev=true), values(grouped_rows))
    @test length(grouped_rows) >= 2
end

# ─────────────────────────────────────────────────────────────────────────────
# Window Functions: ORDER BY accepts a window alias on a plain standings query
# This mirrors the docs example and checks the user-visible effect directly:
# rows are ordered first by driver and then by the computed per-race rank.
# ─────────────────────────────────────────────────────────────────────────────
@testset "Window aliases can drive ORDER BY on driver standings" begin
    query = M.Driver_standings.objects
    query.filter("raceid__@lt" => 3, "points__@gt" => 0)
    query.values(
        "raceid",
        "driverid",
        "points",
        "race_rank" => Rank(over=WindowOver(partition_by=["raceid"], order_by=["-points"]))
    )
    query.order_by("driverid", "race_rank")

    rows = query.list()

    @test !isempty(rows)
    ordered_by_driver_and_rank = all(index -> begin
        previous_row = rows[index - 1]
        current_row = rows[index]
        current_row[:driverid] > previous_row[:driverid] ||
        (current_row[:driverid] == previous_row[:driverid] && current_row[:race_rank] >= previous_row[:race_rank])
    end, 2:length(rows))
    @test ordered_by_driver_and_rank

    driver_18_rows = filter(row -> row[:driverid] == 18, rows)
    @test !isempty(driver_18_rows)
    @test issorted([row[:race_rank] for row in driver_18_rows])
end
