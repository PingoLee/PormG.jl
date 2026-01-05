if !isdefined(Main, :PormG)
    include("common_setup.jl")
end

@testset "Test list query" begin
  query = M.Result |> object;
  query.filter("statusid__status" => "Finished", "resultid" => 26745);
  query.values("resultid", "raceid__circuitid__name", "driverid__forename", "constructorid__name", "statusid__status", "grid", "laps");
  dict = query |> list
  @test length(dict) == 1
  @test dict[1][:resultid] == 26745
  @test dict[1][:laps] == 58

  dict_json = query |> list_json
  @test isa(dict_json, String)
  @test JSON.parse(dict_json)[1]["resultid"] == 26745
end

@testset "Test As functionality for custom alias" begin
  query = M.Result |> object;
  query.filter("statusid__status" => "Finished", "resultid" => 26745);
  query.values("resultid", "circuit" => "raceid__circuitid__name");
  df = query |> DataFrame
  @test "circuit" in names(df)

  query = M.Result |> object;
  query.filter("statusid__status" => "Finished", "resultid" => 26745);
  query.values("resultid", "circuit" => "raceid__circuitid__name", "quarter" => "raceid__date__@quarter");
  df = query |> DataFrame
  @test "quarter" in names(df)

  dict = query |> list
  @test haskey(dict[1], :circuit) && haskey(dict[1], :quarter)
end

@testset "Filtering and Value Selection" begin
  # Filter by status
  query = M.Status |> object;
  query.filter("status" => "Engine");
  @test query |> do_count ==  1
  df = query |> DataFrame
  @test "status" in names(df)
  @test length(names(df)) == 2  # statusid and status

  # Join filter
  query = M.Result |> object;
  query.filter("statusid__status" => "Engine");
  query.values("resultid", "statusid", "statusid__status");
  df = query |> DataFrame;
  @test query |> do_count == 2026
  @test filter(r -> r.statusid__status == "Engine", df) |> x -> nrow(x) == 2026

  # Chained values
  query.values("resultid", "driverid__forename", "constructorid__name", "statusid__status", "grid", "laps");
  df = query |> DataFrame
  @test length(names(df)) == 6
  @test filter(r -> r.statusid__status == "Engine", df) |> x -> nrow(x) == 2026
end

@testset "Ordering and Aggregations" begin
    query = M.Result |> object;
    query.values("statusid__status", "raceid__circuitid__name", "driverid__forename", "constructorid__name", "count_grid" => Count("grid"), "max_grid" => Max("grid"), "min_grid" => Min("grid"));
    query.order_by("raceid__circuitid__name");
    query.filter("statusid__status" => "Finished", "driverid__forename" => "Ayrton");
    df = query |> DataFrame
    @test df[2, :count_grid] == 3
    @test df[2, :max_grid] == 3
    @test df[2, :min_grid] == 2
    @test size(df, 1) == 39
    @test df[1, :raceid__circuitid__name] == "Adelaide Street Circuit"
    @test df[39, :raceid__circuitid__name] == "Suzuka Circuit"
end


@testset "Filtering" begin
    # Contains and icontains
    query = M.Result |> object;
    query.filter("raceid__circuitid__name__@contains" => "Monaco");
    @test query |> do_count == 1664
    query = M.Result |> object;
    query.filter("raceid__circuitid__name__@contains" => "monaco");
    @test query |> do_count == 0
    query = M.Result |> object;
    query.filter("raceid__circuitid__name__@icontains" => "monaco");
    @test query |> do_count == 1664
    query = M.Result |> object;
    query.filter("raceid__circuitid__name__@in" => ["Monaco", "Monza"]);
    @test query |> do_count == 0
    query = M.Result |> object;
    query.filter("raceid__circuitid__name__@in" => ["Circuit de Monaco", "monaco"]);
    @test query |> do_count == 1664
    query = M.Result |> object;
    query.filter("raceid__circuitid__name__@nin" => ["Circuit de Monaco", "monaco"]);
    @test query |> do_count == 25095
end


@testset "Date Operations" begin
    query = M.Race |> object;
    query.filter("date__@year" => 1991);
    query.values("date__@year", "date__@month", "date__@day", "rows" => Count("raceid"));
    query.order_by("date__day");
    df = query |> DataFrame
    @test size(df, 1) == 16
    @test df[16, :date__day] == 29

    query = M.Race |> object;
    query.filter("date__@yyyy_mm" => "1991-10");
    query.values("date__@year", "date__@month", "date__@day", "rows" => Count("raceid"));
    query.order_by("date__day");
    df = query |> DataFrame
    @test size(df, 1) == 1
    @test df[1, :date__day] == 20 && df[1, :rows] == 1

    query = M.Race |> object;
    query.filter("date__@date" => "1991-10-20");
    query.values("date__@year", "date__@month", "date__@day", "rows" => Count("raceid"));
    query.order_by("date__day");
    df = query |> DataFrame
    @test size(df, 1) == 1

    query = M.Race |> object;
    query.filter("date__@date" => Date(1991, 10, 20));
    query.values("date__@year", "date__@month", "date__@day", "rows" => Count("raceid"));
    query.order_by("date__day");
    df = query |> DataFrame
    @test size(df, 1) == 1
end

@testset "Comparison and In Operations" begin
  query = M.Result |> object;
  query.filter("positionorder__@lt" => 3);
  query.values("raceid__circuitid__name", "positionorder", "driverid__forename", "constructorid__name");
  query.order_by("-positionorder");
  df = query |> DataFrame
  @test df[1, :positionorder] == 2

  query = M.Result |> object;
  query.filter("positionorder__@in" => [1, 2]);
  query.values("raceid__circuitid__name", "positionorder",  "driverid__forename", "constructorid__name");
  @test query |> do_count == size(df, 1)

  query = M.Result |> object;
  query.filter("positionorder__@nin" => df.positionorder |> unique);
  query.values("raceid__circuitid__name", "positionorder", "driverid__forename", "constructorid__name");
  @test query |> do_count == 24497
  df = query |> DataFrame
  @test filter(r -> r.positionorder == 1 || r.positionorder == 2, df) |> x -> nrow(x) == 0

end


@testset "filters with having" begin
  query = M.Result |> object;    
  query.values("raceid__circuitid__name", "driverid__forename", "constructorid__name", "count_grid" => Count("grid"));
  query.filter("statusid__status" => "Finished", "count_grid__@gt" => 1);
  df = query |> DataFrame
  # @info query |> show_query
  # ┌ Info: SELECT
  # │    Tb_2.name as raceid__circuitid__name,
  # │   Tb_3.forename as driverid__forename,
  # │   Tb_4.name as constructorid__name,
  # │   COUNT(Tb.grid) as count_grid
  # │ FROM result as Tb
  # │  INNER JOIN race Tb_1 ON Tb.raceid = Tb_1.raceid
  # │  INNER JOIN circuit Tb_2 ON Tb_1.circuitid = Tb_2.circuitid
  # │  INNER JOIN driver Tb_3 ON Tb.driverid = Tb_3.driverid
  # │  INNER JOIN constructor Tb_4 ON Tb.constructorid = Tb_4.constructorid
  # │  INNER JOIN status Tb_5 ON Tb.statusid = Tb_5.statusid
  # │ WHERE Tb_5.status = 'Finished'
  # │ GROUP BY 1, 2, 3
  # └ HAVING COUNT(Tb.grid) > 1
  @test size(df, 1) == 1637
  sort!(df, [:count_grid])
  @test df[1, :count_grid] == 2
end