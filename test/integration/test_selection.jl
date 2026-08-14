if !isdefined(Main, :PormG)
    include("common_setup.jl")
end

@testset "Test list query" begin
  query = M.Result.objects;
  query.filter("statusid__status" => "Finished", "resultid" => 26745);
  query.values("resultid", "raceid__circuitid__name", "driverid__forename", "constructorid__name", "statusid__status", "grid", "laps");
  dict = query.list()
  @test length(dict) == 1
  @test dict[1][:resultid] == 26745
  @test dict[1][:laps] == 58

  dict_json = query.list(:json)
  @test isa(dict_json, String)
  @test JSON.parse(dict_json)[1]["resultid"] == 26745
end

# PostgreSQL folds unquoted aliases to lowercase; quote_identifier prevents that.
@testset "values pair aliases preserve mixed case" begin
  query = M.Driver.objects.filter("driverref" => "hamilton")
  query.values("Escala" => "surname")

  inspection = PormG.QueryBuilder.inspect_query(query)
  @test occursin(" as \"Escala\"", inspection[:sql_text])
  @test !occursin(" as Escala", inspection[:sql_text])

  rows = query.list(:dict)
  @test length(rows) == 1
  @test haskey(rows[1], :Escala)
  @test !haskey(rows[1], :escala)
  @test rows[1][:Escala] == "Hamilton"
end

@testset "values pair aliases preserve unicode letters" begin
  query = M.Driver.objects.filter("driverref" => "hamilton")
  query.values("localização" => "surname")

  inspection = PormG.QueryBuilder.inspect_query(query)
  @test occursin(" as \"localização\"", inspection[:sql_text])

  rows = query.list(:dict)
  @test length(rows) == 1
  @test haskey(rows[1], Symbol("localização"))
  @test !haskey(rows[1], :localizao)
  @test rows[1][Symbol("localização")] == "Hamilton"
end

@testset "values plain field names are quoted in SELECT (_as branch)" begin
  # Covers the _as branch (non-Pair string in values()) — quote_identifier is
  # applied there too so future mixed-case _as values won't regress.
  inspection = PormG.QueryBuilder.inspect_query(
    M.Driver.objects.filter("driverref" => "hamilton").values("surname")
  )
  @test occursin(" as \"surname\"", inspection[:sql_text])
end

# ─────────────────────────────────────────────────────────────────────────────
# DataFrame alias quoting: mixed-case and unicode aliases survive the DataFrame
# construction path. Column names come from Tables.rowtable key coercion, which
# is independent of PormG's dict-result path — so this covers the real consumer
# pattern (Base.invokelatest(DataFrame, query.values(alias => field))).
# ─────────────────────────────────────────────────────────────────────────────
@testset "DataFrame column names preserve mixed-case aliases" begin
  df = M.Driver.objects.filter("driverref" => "hamilton").
    values("Escala" => "surname") |> DataFrame
  @test df isa DataFrame
  @test "Escala" in names(df)
  @test !("escala" in names(df))
  @test df[1, :Escala] == "Hamilton"
end

@testset "DataFrame column names preserve unicode aliases" begin
  df = M.Driver.objects.filter("driverref" => "hamilton").
    values("localização" => "surname") |> DataFrame
  @test df isa DataFrame
  @test "localização" in names(df)
  @test !("localizao" in names(df))
  @test df[1, Symbol("localização")] == "Hamilton"
end

@testset ".exists() and .count() guard patterns" begin
  # These are read-side terminal methods and fit better in the selection suite
  # than in a generic production-pattern file.
  #
  # Cleanup at the boundary keeps each subtest deterministic even if this file
  # is run in isolation while developing a regression fix.
  M.Just_a_test_deletion.objects.exists() && M.Just_a_test_deletion.objects.delete(allow_delete_all=true)

  @testset "exists() returns false on empty table" begin
    # Why this matters: guard clauses in application code often branch on
    # `query.exists()` before doing inserts or deletes. A false positive here
    # would be a destructive regression.
    q = M.Just_a_test_deletion.objects.filter("name" => "nonexistent_sentinel")
    @test q.exists() == false
  end

  @testset "count() returns 0 on empty match" begin
    # Why this matters: count() is the numeric sibling of exists(). Keeping both
    # behaviors together makes it easier to spot read-path regressions.
    q = M.Just_a_test_deletion.objects.filter("name" => "nonexistent_sentinel")
    @test q.count() == 0
  end

  @testset "create-if-not-exists pattern" begin
    # Production code frequently does:
    #   if query.exists() == false
    #       query.create(...)
    #   end
    #
    # Maintenance note: the second branch intentionally repeats the same guard so
    # a regression shows up as a duplicate-row failure instead of being hidden by
    # shared fixture state.
    q = M.Just_a_test_deletion.objects.filter("name" => "guard_test_row")

    if q.exists() == false
      M.Just_a_test_deletion.objects.create("name" => "guard_test_row", "test_result" => 1)
    end

    @test M.Just_a_test_deletion.objects.filter("name" => "guard_test_row").exists() == true
    @test M.Just_a_test_deletion.objects.filter("name" => "guard_test_row").count() == 1

    q2 = M.Just_a_test_deletion.objects.filter("name" => "guard_test_row")
    if q2.exists() == false
      M.Just_a_test_deletion.objects.create("name" => "guard_test_row", "test_result" => 2)
    end

    @test M.Just_a_test_deletion.objects.filter("name" => "guard_test_row").count() == 1
  end

  M.Just_a_test_deletion.objects.exists() && M.Just_a_test_deletion.objects.delete(allow_delete_all=true)
end

@testset "Test As functionality for custom alias" begin
  query = M.Result.objects;
  query.filter("statusid__status" => "Finished", "resultid" => 26745);
  query.values("resultid", "circuit" => "raceid__circuitid__name");
  df = query |> DataFrame
  @test "circuit" in names(df)

  query = M.Result.objects;
  query.filter("statusid__status" => "Finished", "resultid" => 26745);
  query.values("resultid", "circuit" => "raceid__circuitid__name", "quarter" => "raceid__date__@quarter");
  df = query |> DataFrame
  @test "quarter" in names(df)

  dict = query.list()
  @test haskey(dict[1], :circuit) && haskey(dict[1], :quarter)
end

@testset "One-liner fluent chain to DataFrame" begin
  @testset "filter + values + order_by piped to DataFrame" begin
    # This covers the production pattern where the entire read query is built in
    # one expression and executed immediately as a DataFrame.
    #
    # Maintenance note: keeping this as a single expression protects the chaining
    # surface itself, not just the underlying SQL behavior.
    df = M.Result.objects.filter(
      "statusid__status" => "Finished",
      "raceid__year" => 1991,
    ).values(
      "resultid", "driverid__surname", "raceid__name"
    ).order_by(
      "resultid"
    ) |> DataFrame

    @test df isa DataFrame
    @test "resultid" in names(df)
    @test "driverid__surname" in names(df)
    @test "raceid__name" in names(df)
    @test nrow(df) > 0
    @test issorted(df.resultid)
  end

  @testset "filter + order_by piped to DataFrame (no explicit values)" begin
    # This covers the simpler full-row read shape used in app code.
    df = M.Circuit.objects.filter("country" => "Japan").order_by("name") |> DataFrame

    @test df isa DataFrame
    @test nrow(df) > 0
    @test "name" in names(df)
    @test "country" in names(df)
  end
end

@testset "Filtering and Value Selection" begin
  # Filter by status
  query = M.Status.objects;
  query.filter("status" => "Engine");
  @test query.count() ==  1
  df = query |> DataFrame
  @test "status" in names(df)
  @test length(names(df)) == 2  # statusid and status

  # Join filter
  query = M.Result.objects;
  query.filter("statusid__status" => "Engine");
  query.values("resultid", "statusid", "statusid__status");
  df = query |> DataFrame;
  @test query.count() == 2026
  @test filter(r -> r.statusid__status == "Engine", df) |> x -> nrow(x) == 2026

  # Chained values
  query.values("resultid", "driverid__forename", "constructorid__name", "statusid__status", "grid", "laps");
  df = query |> DataFrame
  @test length(names(df)) == 6
  @test filter(r -> r.statusid__status == "Engine", df) |> x -> nrow(x) == 2026

  # Deep FK traversal on a leaf string field should work with lookup operators.
  deep_query = M.Result.objects
  deep_query.filter("raceid__circuitid__country__@icontains" => "united")
  deep_query.values("resultid", "raceid__circuitid__country", "driverid__surname")
  deep_query.order_by("resultid")
  deep_df = deep_query.page(10, 0) |> DataFrame

  @test nrow(deep_df) > 0
  @test all(row -> occursin("United", row.raceid__circuitid__country) ||
                   occursin("united", lowercase(row.raceid__circuitid__country)),
           eachrow(deep_df))
end

@testset "Ordering and Aggregations" begin
    query = M.Result.objects;
    query.values("statusid__status", "raceid__circuitid__name", "driverid__forename", "constructorid__name", "count_grid" => Count("grid"), "max_grid" => Max("grid"), "min_grid" => Min("grid"));
    query.order_by("raceid__circuitid");
    query.filter("statusid__status" => "Finished", "driverid__forename" => "Ayrton");
    df = query |> DataFrame
    # query |> show_query
    @test df[2, :count_grid] == 5
    @test df[2, :max_grid] == 3
    @test df[2, :min_grid] == 1
    @test df[4, :max_grid] == 13
    @test df[4, :min_grid] == 13
    @test size(df, 1) == 39
    @test df[1, :raceid__circuitid__name] == "Circuit de Barcelona-Catalunya"
    @test df[39, :raceid__circuitid__name] == "Red Bull Ring"

    # Regression: FK aliases plus aggregates in the same values() call should
    # still group correctly and expose the aliased columns in the DataFrame.
    query = M.Result.objects
    query.filter("statusid__status" => "Finished")
    query.values("circuit_name" => "raceid__circuitid__name", "race_count" => Count("resultid"))
    query.order_by("-race_count")
    df = query |> DataFrame

    @test "circuit_name" in names(df)
    @test "race_count" in names(df)
    @test nrow(df) > 0
    @test df[1, :race_count] >= df[end, :race_count]

    # Regression: multiple joined fields plus multiple aggregates should coexist
    # without breaking grouping or alias propagation.
    query = M.Result.objects
    query.filter("positionorder__@lte" => 3)
    query.values(
      "driverid__surname",
      "constructorid__name",
      "podiums" => Count("resultid"),
      "best_points" => Max("points"),
    )
    query.order_by("-podiums")
    df = query |> DataFrame

    @test "driverid__surname" in names(df)
    @test "constructorid__name" in names(df)
    @test "podiums" in names(df)
    @test "best_points" in names(df)
    @test nrow(df) > 0
    @test any(df.podiums .> 50)

    # Regression: mixed ascending joined field and descending aggregate alias in
    # order_by(...) should render a stable ORDER BY clause.
    query = M.Result.objects
    query.values(
      "driverid__nationality",
      "cnt" => Count("resultid"),
    )
    query.filter("positionorder" => 1)
    query.order_by("driverid__nationality", "-cnt")
    df = query |> DataFrame
    inspection = PormG.QueryBuilder.inspect_query(query)
    sql_upper = uppercase(inspection[:sql_text])

    @test nrow(df) > 0
    @test occursin("ORDER BY", sql_upper)
    @test occursin("DESC", sql_upper)
end


# ─────────────────────────────────────────────────────────────────────────────
# ORDER BY NULL placement is normalized across backends (#75).
#
# PostgreSQL and SQLite default NULLs to OPPOSITE ends of an ORDER BY, so ordering a
# nullable column used to return different rows on each backend — and with .first()/.page()
# that changed WHICH row you got, not just its position. PormG now emits an explicit
# NULLS clause matching PostgreSQL's default on both backends: ASC → NULLS LAST,
# DESC → NULLS FIRST, overridable per term via SQLOrder(field; nulls=:first|:last).
#
# This test asserts the (now backend-independent) expected order on whichever backend is
# running. Pre-fix it FAILS on SQLite (NULLs would sort first for ASC) — the cross-backend
# mutation gate. It uses the permanent `bulk_update_payload_scratch` fixture (nullable_int
# column) with try/finally cleanup so the F1 tables are untouched.
# ─────────────────────────────────────────────────────────────────────────────
@testset "ORDER BY NULL placement normalized across backends (#75)" begin
    # Scratch helpers are loaded in-suite by runtests.jl; load them for standalone runs too.
    if !isdefined(Main, :_clear_bulk_update_scratch_rows!)
        include("common_bulk_scratch_setup.jl")
    end

    _is_nullish(x) = x === nothing || ismissing(x)

    _clear_bulk_update_scratch_rows!()
    try
        required_ids, _ = _seed_bulk_update_scratch_parents!(["req-nulls-75"], String[])
        pid = required_ids["req-nulls-75"]

        # Four rows: three non-NULL sort keys plus one NULL. Labels identify rows regardless
        # of how a NULL integer renders back (nothing/missing).
        M.Bulk_update_payload_scratch.objects.create("label" => "n75-a", "required_parent_id" => pid, "nullable_int" => 30)
        M.Bulk_update_payload_scratch.objects.create("label" => "n75-b", "required_parent_id" => pid, "nullable_int" => 10)
        M.Bulk_update_payload_scratch.objects.create("label" => "n75-c", "required_parent_id" => pid)  # nullable_int → NULL
        M.Bulk_update_payload_scratch.objects.create("label" => "n75-d", "required_parent_id" => pid, "nullable_int" => 20)

        our_labels = ["n75-a", "n75-b", "n75-c", "n75-d"]
        labels_of(rows) = [r[:label] for r in rows]

        # Ascending: non-NULL keys ascend, NULL sorts LAST (PostgreSQL's default, now on SQLite too).
        asc_rows = M.Bulk_update_payload_scratch.objects.
            filter("label__@in" => our_labels).
            order_by("nullable_int").
            values("label", "nullable_int").
            list()
        @test labels_of(asc_rows) == ["n75-b", "n75-d", "n75-a", "n75-c"]
        @test _is_nullish(asc_rows[end][:nullable_int])          # the NULL row is last

        # The concrete #75 symptom: .first() over the ascending nullable key must return the
        # smallest non-NULL row (n75-b / 10) on BOTH backends — pre-fix SQLite returned the NULL row.
        first_asc = M.Bulk_update_payload_scratch.objects.
            filter("label__@in" => our_labels).
            order_by("nullable_int").
            first()
        @test first_asc !== nothing
        @test first_asc[:label] == "n75-b"

        # Descending: NULL sorts FIRST (matches PostgreSQL DESC default).
        desc_rows = M.Bulk_update_payload_scratch.objects.
            filter("label__@in" => our_labels).
            order_by("-nullable_int").
            values("label", "nullable_int").
            list()
        @test labels_of(desc_rows) == ["n75-c", "n75-a", "n75-d", "n75-b"]
        @test _is_nullish(desc_rows[1][:nullable_int])           # the NULL row is first

        # Override: ascending order but NULLs forced to the FRONT via SQLOrder(...; nulls=:first).
        ovr_rows = M.Bulk_update_payload_scratch.objects.
            filter("label__@in" => our_labels).
            order_by(PormG.QueryBuilder.SQLOrder(
                PormG.QueryBuilder.SQLField("nullable_int", "nullable_int");
                orientation = "ASC", nulls = :first)).
            values("label", "nullable_int").
            list()
        @test labels_of(ovr_rows) == ["n75-c", "n75-b", "n75-d", "n75-a"]
        @test _is_nullish(ovr_rows[1][:nullable_int])            # override put the NULL row first
    finally
        _clear_bulk_update_scratch_rows!()
    end
end


@testset "Filtering" begin
    # Contains and icontains
    query = M.Result.objects.filter("raceid__circuitid__name__@contains" => "Monaco");
    @test query.count() == 1664
    query = M.Result.objects.filter("raceid__circuitid__name__@contains" => "monaco");
    @test query.count() == 0
    query = M.Result.objects.filter("raceid__circuitid__name__@icontains" => "monaco");
    @test query.count() == 1664
    query = M.Result.objects.filter("raceid__circuitid__name__@in" => ["Monaco", "Monza"]);
    @test query.count() == 0
    query = M.Result.objects.filter("raceid__circuitid__name__@in" => ["Circuit de Monaco", "monaco"]);
    @test query.count() == 1664
    query = M.Result.objects.filter("raceid__circuitid__name__@nin" => ["Circuit de Monaco", "monaco"]);
    @test query.count() == 25095
end


@testset "Date Operations" begin
    query = M.Race.objects;
    query.filter("date__@year" => 1991);
    query.values("date__@year", "date__@month", "date__@day", "rows" => Count("raceid"));
    query.order_by("date__day");
    df = query |> DataFrame
    @test size(df, 1) == 16
    @test df[16, :date__day] == 29

    query = M.Race.objects;
    query.filter("date__@yyyy_mm" => "1991-10");
    query.values("date__@year", "date__@month", "date__@day", "rows" => Count("raceid"));
    query.order_by("date__day");
    df = query |> DataFrame
    @test size(df, 1) == 1
    @test df[1, :date__day] == 20 && df[1, :rows] == 1

    query = M.Race.objects;
    query.filter("date__@date" => "1991-10-20");
    query.values("date__@year", "date__@month", "date__@day", "rows" => Count("raceid"));
    query.order_by("date__day");
    df = query |> DataFrame
    @test size(df, 1) == 1

    query = M.Race.objects;
    query.filter("date__@date" => Date(1991, 10, 20));
    query.values("date__@year", "date__@month", "date__@day", "rows" => Count("raceid"));
    query.order_by("date__day");
    df = query |> DataFrame
    @test size(df, 1) == 1
end

# ─────────────────────────────────────────────────────────────────────────────
# Date Operations: sargable comparison rewrite (#352)
# `date__@yyyy_mm`/`date__@year`/`date__@date` comparisons (`=`/`@gte`/`@gt`/`@lte`/`@lt`) against
# `Race.date` (a plain DateField) rewrite to a range/comparison directly on the column — no
# to_char/EXTRACT — instead of the previous non-sargable rendering. Each bucket comparison is
# pinned against an INDEPENDENT baseline — the same window written as a plain date comparison,
# which never goes through the bucket-transform path — so the asymmetric boundary mapping
# (`@lte`/`@gt` bind the FOLLOWING period's start; `@lt`/`@gte` bind the bucket's OWN start) is
# verified absolutely, not just for internal self-consistency, against live data on both backends.
# ─────────────────────────────────────────────────────────────────────────────
@testset "Date Operations — sargable comparison rewrite (#352)" begin
    # The 1991 season's sole October race is the Japanese GP, 1991-10-20 (pinned above: 1 row).
    # No to_char (PostgreSQL) / strftime (SQLite) should appear — the comparison runs on the raw
    # column now, dialect-agnostic.
    sql_lte = M.Race.objects.filter("date__@yyyy_mm__@lte" => "1991-10").list(show_query=:sql)
    @test !occursin("to_char", lowercase(sql_lte)) && !occursin("strftime", lowercase(sql_lte))

    query = M.Race.objects.filter("date__@yyyy_mm__@lte" => "1991-10")
    count_lte = query.count()
    query = M.Race.objects.filter("date__@yyyy_mm__@lt" => "1991-10")
    count_lt = query.count()
    query = M.Race.objects.filter("date__@yyyy_mm__@gte" => "1991-10")
    count_gte = query.count()
    query = M.Race.objects.filter("date__@yyyy_mm__@gt" => "1991-10")
    count_gt = query.count()
    query = M.Race.objects.filter("date__@yyyy_mm" => "1991-10")
    count_eq = query.count()

    @test count_eq == 1                # only the Japanese GP falls in October 1991
    @test count_lte == count_lt + 1    # @lte INCLUDES the October race that @lt EXCLUDES
    @test count_gte == count_gt + 1    # @gte INCLUDES the October race that @gt EXCLUDES

    # Independent baseline: the same windows expressed as plain date comparisons, which never
    # went through the bucket-transform path at all. The delta assertions above are only
    # self-consistent (both sides could be wrong by the same amount and still pass); these pin
    # the ABSOLUTE boundary, so a strict/non-strict slip on the upper bound fails here.
    @test count_lte == M.Race.objects.filter("date__@lt" => "1991-11-01").count()
    @test count_lt  == M.Race.objects.filter("date__@lt" => "1991-10-01").count()
    @test count_gte == M.Race.objects.filter("date__@gte" => "1991-10-01").count()
    @test count_gt  == M.Race.objects.filter("date__@gte" => "1991-11-01").count()

    # The 1991 season has 16 races (pinned above). Same asymmetry check, at year granularity.
    sql_year = M.Race.objects.filter("date__@year__@gte" => 1991).list(show_query=:sql)
    @test !occursin("extract", lowercase(sql_year)) && !occursin("strftime", lowercase(sql_year))

    query = M.Race.objects.filter("date__@year__@lte" => 1991)
    y_lte = query.count()
    query = M.Race.objects.filter("date__@year__@lt" => 1991)
    y_lt = query.count()
    query = M.Race.objects.filter("date__@year__@gte" => 1991)
    y_gte = query.count()
    query = M.Race.objects.filter("date__@year__@gt" => 1991)
    y_gt = query.count()

    @test y_lte == y_lt + 16
    @test y_gte == y_gt + 16
    # Absolute boundary, same reasoning as the yyyy_mm case above.
    @test y_lte == M.Race.objects.filter("date__@lt" => "1992-01-01").count()
    @test y_lt  == M.Race.objects.filter("date__@lt" => "1991-01-01").count()
    @test y_gte == M.Race.objects.filter("date__@gte" => "1991-01-01").count()
    @test y_gt  == M.Race.objects.filter("date__@gte" => "1992-01-01").count()

    # `@date` is already at column granularity: no range needed, the operator passes straight
    # through against the parsed literal.
    query = M.Race.objects.filter("date__@date__@lte" => "1991-10-20")
    d_lte = query.count()
    query = M.Race.objects.filter("date__@date__@lt" => "1991-10-20")
    d_lt = query.count()
    @test d_lte == d_lt + 1            # exactly the Japanese GP itself
end

# ─────────────────────────────────────────────────────────────────────────────
# Date Operations: sargable rewrite through a JOIN (#373)
# #352 covered bare columns only, because a dotted path's terminal field type is not readable
# before the join renders. #373 answers that by rendering the path first and reading the terminal
# field back out of `tab_field_cache` — the same walk that produced the alias — so the rewrite now
# fires on `raceid__date__@yyyy_mm` too. That is the larger half of the exposure: a joined date
# filter sits on a fact table reached through a join, exactly where a row-count misestimate does
# the most damage to the plan above it.
#
# Same verification shape as the #352 block: every bucket comparison pinned against an INDEPENDENT
# plain-date baseline over the SAME join path, which never routes through the rewrite — so the
# asymmetric boundary mapping is verified absolutely against live data on both backends, not just
# for internal self-consistency.
# ─────────────────────────────────────────────────────────────────────────────
@testset "Date Operations — sargable rewrite through a join (#373)" begin
    # `Result.raceid` → `Race.date` (a plain DateField on the JOINED table). No to_char
    # (PostgreSQL) / strftime (SQLite): the comparison runs on the joined column itself.
    sql_join = M.Result.objects.filter("raceid__date__@yyyy_mm__@lte" => "1991-10").list(show_query=:sql)
    @test !occursin("to_char", lowercase(sql_join)) && !occursin("strftime", lowercase(sql_join))
    # The join the predicate depends on is still emitted — the rewrite moves the comparison onto
    # the joined column, it never drops the join.
    @test occursin("join", lowercase(sql_join))

    j_lte = M.Result.objects.filter("raceid__date__@yyyy_mm__@lte" => "1991-10").count()
    j_lt  = M.Result.objects.filter("raceid__date__@yyyy_mm__@lt"  => "1991-10").count()
    j_gte = M.Result.objects.filter("raceid__date__@yyyy_mm__@gte" => "1991-10").count()
    j_gt  = M.Result.objects.filter("raceid__date__@yyyy_mm__@gt"  => "1991-10").count()
    j_eq  = M.Result.objects.filter("raceid__date__@yyyy_mm"       => "1991-10").count()

    # Absolute boundaries, against plain-date comparisons over the same join path.
    @test j_lte == M.Result.objects.filter("raceid__date__@lt"  => "1991-11-01").count()
    @test j_lt  == M.Result.objects.filter("raceid__date__@lt"  => "1991-10-01").count()
    @test j_gte == M.Result.objects.filter("raceid__date__@gte" => "1991-10-01").count()
    @test j_gt  == M.Result.objects.filter("raceid__date__@gte" => "1991-11-01").count()
    @test j_eq  == M.Result.objects.filter("raceid__date__@gte" => "1991-10-01",
                                           "raceid__date__@lt"  => "1991-11-01").count()
    # The October 1991 rows are what @lte includes and @lt excludes — a non-trivial delta, so the
    # equalities above are not all comparing zero to zero.
    @test j_eq > 0
    @test j_lte == j_lt + j_eq
    @test j_gte == j_gt + j_eq

    # A SECOND join target, so the coverage is not one FK's accident: `Result.driverid` →
    # `Driver.dob`, a DateField on a different table, at year granularity.
    sql_dob = M.Result.objects.filter("driverid__dob__@year__@gte" => 1960).list(show_query=:sql)
    @test !occursin("extract", lowercase(sql_dob)) && !occursin("strftime", lowercase(sql_dob))

    d_gte = M.Result.objects.filter("driverid__dob__@year__@gte" => 1960).count()
    d_lt  = M.Result.objects.filter("driverid__dob__@year__@lt"  => 1960).count()
    @test d_gte == M.Result.objects.filter("driverid__dob__@gte" => "1960-01-01").count()
    @test d_lt  == M.Result.objects.filter("driverid__dob__@lt"  => "1960-01-01").count()
    @test d_gte > 0 && d_lt > 0

    # Two joined bucket filters over DIFFERENT join paths in one query: each must rewrite onto its
    # own alias, and both joins must still be emitted. (The TIMESTAMPTZ exclusion through a join is
    # pinned in test/unit/test_sargable_date_range.jl — the F1 schema has no DateTimeField reachable
    # by a join from a seeded table.)
    both = M.Result.objects.filter("raceid__date__@yyyy_mm__@lte" => "1991-10",
                                   "driverid__dob__@year__@gte" => 1960)
    sql_both = both.list(show_query=:sql)
    @test !occursin("to_char", lowercase(sql_both)) && !occursin("extract", lowercase(sql_both))
    @test both.count() == M.Result.objects.filter("raceid__date__@lt"  => "1991-11-01",
                                                  "driverid__dob__@gte" => "1960-01-01").count()
end

@testset "Comparison and In Operations" begin
  query = M.Result.objects;
  query.filter("positionorder__@lt" => 3);
  query.values("raceid__circuitid__name", "positionorder", "driverid__forename", "constructorid__name");
  query.order_by("-positionorder");
  df = query |> DataFrame
  @test df[1, :positionorder] == 2

  query = M.Result.objects;
  query.filter("positionorder__@in" => [1, 2]);
  query.values("raceid__circuitid__name", "positionorder",  "driverid__forename", "constructorid__name");
  @test query.count() == size(df, 1)

  query = M.Result.objects;
  query.filter("positionorder__@nin" => df.positionorder |> unique);
  query.values("raceid__circuitid__name", "positionorder", "driverid__forename", "constructorid__name");
  @test query.count() == 24497
  df = query |> DataFrame
  @test filter(r -> r.positionorder == 1 || r.positionorder == 2, df) |> x -> nrow(x) == 0

end

@testset "Qor Filtering" begin
  @testset "nested Q branches with mixed lookups" begin
    # The public API uses Qor(...) to join OR branches and Q(...) to group
    # AND conditions inside each branch. Verify both the combined count and
    # a sampled result set without emitting one assertion per returned row.
    #
    # Maintenance note: counting each branch separately makes the expected row
    # count explicit, while the paged sample checks that the returned rows still
    # satisfy the logical shape of the filter after future refactors.
    query = M.Result.objects
    query.filter(Qor(
      Q("positionorder" => 1, "driverid__nationality__@ne" => "British"),
      Q("positionorder" => 2, "driverid__nationality" => "German")
    ))

    branch_a = M.Result.objects.filter(
      "positionorder" => 1,
      "driverid__nationality__@ne" => "British",
    ).count()
    branch_b = M.Result.objects.filter(
      "positionorder" => 2,
      "driverid__nationality" => "German",
    ).count()

    sample = query.copy()
    sample.values("resultid", "positionorder", "driverid__nationality")
    sample.order_by("resultid")
    df = sample.page(25, 0) |> DataFrame

    @test query.count() == branch_a + branch_b
    @test all(row -> (
      (row.positionorder == 1 && row.driverid__nationality != "British") ||
      (row.positionorder == 2 && row.driverid__nationality == "German")
    ), eachrow(df))
  end

  @testset "Qor with @in branch preserves OR semantics" begin
    # Maintenance note: this case guards OR-set logic where one branch is a plain
    # equality check and the other uses an array lookup. The overlap calculation
    # matters because OR semantics should deduplicate rows matched by both sides.
    query = M.Result.objects
    query.filter(Qor(
      Q("raceid__year" => 1991),
      Q("raceid__circuitid__country__@in" => ["Japan", "Italy"])
    ))

    branch_a = M.Result.objects.filter("raceid__year" => 1991).count()
    branch_b = M.Result.objects.filter("raceid__circuitid__country__@in" => ["Japan", "Italy"]).count()
    overlap = M.Result.objects.filter(
      "raceid__year" => 1991,
      "raceid__circuitid__country__@in" => ["Japan", "Italy"],
    ).count()

    sample = query.copy()
    sample.values("resultid", "raceid__year", "raceid__circuitid__country")
    sample.order_by("resultid")
    df = sample.page(25, 0) |> DataFrame

    @test query.count() == branch_a + branch_b - overlap
    @test all(row -> (
      row.raceid__year == 1991 || row.raceid__circuitid__country in ["Japan", "Italy"]
    ), eachrow(df))
  end

  @testset "distinct().count() executes and matches plain count" begin
    # Regression: distinct().count() used to render COUNT(DISTINCT *), which is a
    # syntax error in both PostgreSQL and SQLite — so this call would throw at
    # execution. It must now run on a live DB. For a PK'd table every row is unique,
    # so the distinct count must equal the plain count (cross-check, not just "it ran").
    @test M.Driver.objects.distinct().count() == M.Driver.objects.count()

    # Same with a WHERE filter: the bound parameter must survive the subquery wrapping.
    @test M.Driver.objects.filter("nationality" => "British").distinct().count() ==
          M.Driver.objects.filter("nationality" => "British").count()

    # With a JOIN (FK-traversal filter): the inner `SELECT DISTINCT *` now spans
    # multiple tables, which can surface duplicate column names in the subquery —
    # engines differ, so exercise it live on both backends.
    @test M.Result.objects.filter("driverid__surname" => "Senna").distinct().count() ==
          M.Result.objects.filter("driverid__surname" => "Senna").count()
  end

  @testset "count(column, distinct=true) counts distinct column values" begin
    # COUNT(DISTINCT col) as a scalar Int (the efficient flat form). Cross-check the
    # value independently and prove dedup actually happens — nationality is non-null,
    # so many drivers share one, making distinct strictly less than the total.
    total = M.Driver.objects.count()
    n_nat = M.Driver.objects.count("nationality", distinct=true)

    nats = (M.Driver.objects.values("nationality") |> DataFrame).nationality
    @test n_nat == length(unique(nats))   # exact value, computed independently
    @test n_nat < total                   # dedup genuinely happened

    # count("col") on a non-null column counts every row (no DISTINCT).
    @test M.Driver.objects.count("nationality") == total
  end

  @testset "Qor fallback branch with impossible id is a no-op" begin
    # Production code uses an impossible id branch as a safe fallback when an
    # input array may be empty. This test ensures that pattern keeps the real
    # branch intact instead of broadening or collapsing the query.
    query = M.Result.objects
    query.filter(Qor(
      Q("driverid__surname" => "Senna"),
      "resultid" => 0,
    ))

    sample = query.copy()
    sample.values("resultid", "driverid__surname")
    sample.order_by("resultid")
    df = sample.page(20, 0) |> DataFrame

    @test query.count() == M.Result.objects.filter("driverid__surname" => "Senna").count()
    @test all(df.driverid__surname .== "Senna")
  end

  @testset "Qor with repeated field names on string lookups" begin
    # This mirrors repeated icontains clauses on the same field family. The test
    # stays intentionally small: one assertion for non-empty output and one that
    # verifies every returned row still satisfies one of the OR branches.
    query = M.Circuit.objects
    query.filter(Qor(
      "name__@icontains" => "monaco",
      "name__@icontains" => "monza",
      "country__@icontains" => "japan",
    ))
    query.values("circuitid", "name", "country")
    query.order_by("name")
    df = query |> DataFrame

    @test nrow(df) > 0
    @test all(row -> (
      occursin("monaco", lowercase(row.name)) ||
      occursin("monza", lowercase(row.name)) ||
      occursin("japan", lowercase(row.country))
    ), eachrow(df))
  end
end

@testset "Pagination" begin
  @testset "page functor with limit and offset" begin
    # The chainable API is query.page(limit, offset). This belongs with
    # the read/selection tests because pagination is a selection concern.
    query = M.Result.objects
    query.filter("statusid__status" => "Finished")
    query.values("resultid", "driverid__forename")
    query.order_by("resultid")
    df = query.page(5, 0) |> DataFrame

    @test nrow(df) == 5
    @test "resultid" in names(df)
    @test "driverid__forename" in names(df)
    @test issorted(df.resultid)
  end

  @testset "page functor with limit only (#272)" begin
    # #272: `query.page(n)` — the single-argument form the docs had always advertised — raised a
    # bare MethodError, because only _page!(::SQLObject, ::Tuple{Integer, Integer}) existed. It sets
    # LIMIT and must leave any OFFSET already on the handler alone.
    query = M.Result.objects
    query.filter("statusid__status" => "Finished")
    query.values("resultid")
    query.order_by("resultid")

    first_four = query.copy().page(4) |> DataFrame
    @test nrow(first_four) == 4
    @test issorted(first_four.resultid)

    # An offset set before the call survives it — page(n) is limit-only, not a pagination reset.
    next_four = query.copy().offset(4).page(4) |> DataFrame
    @test nrow(next_four) == 4
    @test isempty(intersect(first_four.resultid, next_four.resultid))
    @test minimum(next_four.resultid) > maximum(first_four.resultid)
  end

  @testset "page functor with offset skips rows" begin
    query = M.Result.objects
    query.filter("statusid__status" => "Finished")
    query.values("resultid")
    query.order_by("resultid")

    first_page = query.copy().page(3, 0) |> DataFrame
    second_page = query.copy().page(3, 3) |> DataFrame

    @test nrow(first_page) == 3
    @test nrow(second_page) == 3
    @test isempty(intersect(first_page.resultid, second_page.resultid))
    @test minimum(second_page.resultid) > maximum(first_page.resultid)
  end

  @testset "limit and offset functors compose" begin
    # The current public API also exposes limit() and offset() as chainable
    # functors. This verifies the fully fluent pagination path.
    query = M.Result.objects
    query.filter("statusid__status" => "Finished")
    query.values("resultid", "driverid__forename")
    query.order_by("resultid")
    df = query.limit(1).offset(0) |> DataFrame

    @test nrow(df) == 1
    @test df[1, :resultid] == 1
  end

  @testset "page in one-liner query chain" begin
    df = M.Circuit.objects.filter(
      "country__@icontains" => "a"
    ).values(
      "circuitid", "name", "country"
    ).order_by(
      "-name"
    ).page(10, 0) |> DataFrame

    @test nrow(df) <= 10
    @test "country" in names(df)
  end
end


@testset "filters with having" begin
  query = M.Result.objects;    
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

@testset "filters after aggregates stay in WHERE" begin
  # Reproduce the regression: we demand a HAVING clause but also need the subsequent
  # non-aggregate predicate to stay in the WHERE clause instead of being dropped.
  query = M.Result.objects.filter("raceid__year" => 1992);
  query.values("statusid__status", "count_grid" => Count("grid"));
  query.filter(
    "count_grid__@gt" => 1,
    "milliseconds__@isnull" => true,
  );

  df = query |> DataFrame

  @test nrow(filter(r -> r.statusid__status == "Finished", df)) == 0

  @test nrow(df) == 20
end

@testset "Test copy method" begin
  query = M.Result.objects;
  query.filter("statusid__status" => "Finished", "resultid" => 26745);
  query.values("resultid", "raceid__circuitid__name", "driverid__forename", "constructorid__name", "statusid__status", "grid", "laps");
  
  query_copy = query.copy()
  df_original = query |> DataFrame
  df_copy = query_copy |> DataFrame

  @test df_original == df_copy

  # Modify the copy and ensure original is unchanged
  query_copy.filter("grid__@gt" => 5)
  df_modified_copy = query_copy |> DataFrame
  df_original = query |> DataFrame

  @test nrow(df_modified_copy) == 0
  @test nrow(df_original) == 1
end
