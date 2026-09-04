# julia -t auto  --project=. test/integration/test_cjoin.jl

if !isdefined(Main, :PormG)
    include("common_setup.jl")
end


# ─────────────────────────────────────────────────────────────────────────────
# cjoin
# Custom JOIN from an arbitrary base field to a named model.
# ─────────────────────────────────────────────────────────────────────────────
@testset "cjoin" begin
    # Shared fixture: 3 New_join_position rows pointing to Result ids 1-3.
    # Recreated at the start of this block so all inner testsets see a clean state.
    # Keep integration output quiet here; warning behavior is covered in unit tests.
    M.New_join_position.objects.delete(allow_delete_all=true, show_query=:execute)
    M.New_join_position.objects.create("result" => 1, "description" => "teste 1")
    M.New_join_position.objects.create("result" => 2, "description" => "teste 2")
    M.New_join_position.objects.create("result" => 3, "description" => "teste 3")

    @testset "simple join: all rows returned, deep path resolved" begin
        # A cjoin with no ON filter attaches every matching joined row.
        query = M.New_join_position.objects
        query.cjoin("result" => "Result", warn=false)
        query.values("result__statusid__status", "description", "result")
        df = query |> DataFrame

        @test size(df, 1) == 3
        @test unique(df.result__statusid__status) == ["Finished"]
    end

    @testset "rejects base-model predicates in ON filters" begin
        # Predicates that belong to the calling model (New_join_position) are rejected
        # by cjoin. Allowing them would silently produce WHERE semantics, not ON semantics.
        q1 = M.New_join_position.objects
        @test_throws PormGError q1.cjoin("result" => "Result", filters=["description" => "teste 1"], warn=false)

        q2 = M.New_join_position.objects
        @test_throws PormGError q2.cjoin("result" => "Result", filters=["result__description" => "teste 1"], warn=false)
    end

    @testset "ON filter restricts joined rows (LEFT JOIN default)" begin
        # With resultid=1 in the ON clause only the row that joins to Result 1 gets
        # populated; the other two rows still appear with missing joined columns.
        query = M.New_join_position.objects
        query.cjoin("result" => "Result", filters=["resultid" => 1], warn=false)
        query.values("result__statusid__status", "description", "result")
        df = query |> DataFrame

        @test size(df, 1) == 3
        @test "result__statusid__status" in names(df)
        @test df[df.description.=="teste 1", :result__statusid__status][1] == "Finished"
        @test df[df.description.=="teste 2", :result__statusid__status][1] === missing
    end

    @testset "ON filter with table-prefixed field name" begin
        # The field may be spelled with the joined-model prefix (result__resultid)
        # and must behave identically to the short form (resultid).
        query = M.New_join_position.objects
        query.cjoin("result" => "Result", filters=["result__resultid" => 1], warn=false)
        query.values("result__statusid__status", "description", "result")
        df = query |> DataFrame

        @test size(df, 1) == 3
        @test df[df.description.=="teste 1", :result__statusid__status][1] == "Finished"
        @test df[df.description.=="teste 2", :result__statusid__status][1] === missing
    end

    @testset "ON filter combined with WHERE filter" begin
        # cjoin ON filter restricts which joined columns are populated;
        # .filter(...) on the main query then restricts the overall result set.
        query = M.New_join_position.objects
        query.cjoin("result" => "Result", filters=["resultid" => 1], warn=false)
        query.filter("description" => "teste 1")
        query.values("result__statusid__status", "description", "result")
        df = query |> DataFrame

        @test size(df, 1) == 1
        @test df[1, :description] == "teste 1"
        @test df[1, :result__statusid__status] == "Finished"
    end

    @testset "join_type INNER: only matched rows are returned" begin
        # INNER drops rows whose join partner fails the ON predicate entirely,
        # instead of keeping them with missing columns (LEFT behaviour).
        query = M.New_join_position.objects
        query.cjoin("result" => "Result", filters=["resultid" => 1], join_type="INNER", warn=false)
        query.values("result__statusid__status", "description", "result")
        df = query |> DataFrame

        @test size(df, 1) == 1
        @test df[1, :description] == "teste 1"
        @test df[1, :result__statusid__status] == "Finished"
    end

    @testset "multiple ON filters + wildcard values(*)" begin
        # Multiple filters are AND-combined on the ON clause.
        # Executing a cjoin query without explicit values() must raise ArgumentError
        # to prevent DataFrames from crashing on duplicate column names.
        # The wildcard "*" shorthand selects all native columns of the main model.
        query = M.New_join_position.objects
        query.cjoin("result" => "Result", filters=["resultid" => 1, "statusid" => 1], join_type="INNER", warn=false)

        # Guard: a bare DataFrame() across a multi-table cjoin is rejected
        @test_throws PormGError query |> DataFrame

        # Wildcard selects all New_join_position columns plus the one named from Result
        query.values("*", "result__statusid")
        df = query |> DataFrame

        @test df |> nrow == 1
        @test df[1, :description] == "teste 1"
        @test df[1, :result] == df[1, :result__statusid] == 1
    end

    @testset "chaining multiple cjoins on same query" begin
        # Two cjoins on the same query LEFT-join independently.
        # Parameter bucket order must be: [cjoin1 params, cjoin2 params, WHERE params].
        query = M.Result.objects
        query.cjoin("driverid" => "Driver", filters=["nationality" => "Brazilian"], warn=false)
        query.cjoin("raceid"   => "Race",   filters=["year" => 1991], warn=false)
        query.filter("positionorder" => 1)

        # Guard: missing explicit values() is rejected
        @test_throws PormGError query |> DataFrame

        query.values("*", "driverid__surname", "raceid__name")
        df = query |> DataFrame

        # LEFT-joined custom filters preserve the full winner set while only
        # populating joined columns for rows that satisfy the respective ON predicate.
        @test nrow(df) > 0
        @test any(ismissing.(df.driverid__surname))
        @test any(.!ismissing.(df.driverid__surname))
        @test any(ismissing.(df.raceid__name))
        @test any(.!ismissing.(df.raceid__name))
        @test all(df.positionorder .== 1)
    end

    @testset "Qor filter in ON clause" begin
        # cjoin filters accept Qor (OR logic), not just flat Pairs.
        # The OR is placed in the JOIN ON clause, so all base rows are preserved
        # while only drivers matching either nationality get their column populated.
        query = M.Result.objects
        query.cjoin("driverid" => "Driver",
            filters=[Qor("nationality" => "Brazilian", "nationality" => "German")],
                    warn=false)
        query.filter("positionorder" => 1)
        query.values("*", "driverid__surname", "driverid__nationality")
        df = query |> DataFrame

        # LEFT JOIN default: all winners appear
        @test nrow(df) > 0

        # Rows where the driver is Brazilian or German have their columns populated
        populated = df[.!ismissing.(df.driverid__surname), :]
        @test nrow(populated) > 0
        @test all(in.(populated.driverid__nationality, Ref(["Brazilian", "German"])))

        # At least one winner is neither Brazilian nor German → that row stays missing
        @test any(ismissing.(df.driverid__surname))
    end
end


# ─────────────────────────────────────────────────────────────────────────────
# cjoin error paths
# Guard tests: ArgumentError / throw for invalid cjoin usage patterns.
# ─────────────────────────────────────────────────────────────────────────────
@testset "cjoin error paths" begin

    @testset "cjoin duplicate join path is rejected" begin
        # cjoin stores state in q.custom_join keyed by the join path.
        # Adding the same path twice would silently overwrite the first ON filter,
        # so it is rejected with an explicit error.
        q = M.Result.objects
        q.cjoin("driverid" => "Driver", warn=false)
        @test_throws PormGError q.cjoin("driverid" => "Driver", warn=false)
    end

    @testset "cjoin to unknown model name is rejected" begin
        # Model names are looked up via isdefined/getfield in the model's module;
        # a typo or wrong casing produces a clear error rather than a runtime crash.
        q = M.New_join_position.objects
        @test_throws PormGError q.cjoin("result" => "NonExistentModel")
    end

    @testset "cjoin mismatched FK target is rejected" begin
        # When the base field is already a FK (driverid → Driver), attempting to cjoin
        # it to a different model is rejected before any SQL is generated.
        q = M.Result.objects
        @test_throws PormGError q.cjoin("driverid" => "Constructor", warn=false)
    end

    @testset "cjoin_on self-join executes and correlates correctly (#45)" begin
        # End-to-end proof that an anchor-less cjoin_on self-join actually FILTERS/correlates rows
        # on a live database — not just that it renders. Self-join Result within one race to find
        # teammates (same race + same constructor, different driver). The expected pair set is
        # derived from the base data, so the assertion validates ON semantics without hard-coding.
        raceid = 841
        base = M.Result.objects.filter("raceid" => raceid).values("driverid", "constructorid") |> DataFrame

        by_constructor = Dict{Any,Vector{Any}}()
        for r in eachrow(base)
            push!(get!(by_constructor, r.constructorid, Any[]), r.driverid)
        end
        expected_pairs = 0
        drivers_with_teammate = Set{Any}()
        for (_, drivers) in by_constructor
            u = unique(drivers)
            length(u) >= 2 || continue
            expected_pairs += length(u) * (length(u) - 1)   # ordered (driver, teammate) pairs
            union!(drivers_with_teammate, u)
        end

        q = M.Result.objects
        q.cjoin_on("Result", alias = "b2", join_type = "INNER", on = [
            Q(Joined("b2", "raceid") == F("raceid"),
              Joined("b2", "constructorid") == F("constructorid"),
              Joined("b2", "driverid") != F("driverid")),
        ])
        q.filter("raceid" => raceid)
        q.values("driverid")
        got = q |> DataFrame

        # There ARE teammates in this race (guards against a vacuously-true 0 == 0).
        @test expected_pairs > 0
        # INNER self-join yields exactly one row per (driver, teammate) ordered pair.
        @test nrow(got) == expected_pairs
        # Every base driver that appears is one that genuinely has a teammate in the race.
        @test Set(got.driverid) == drivers_with_teammate
    end

end

# ─────────────────────────────────────────────────────────────────────────────
# cjoin ON filters at two join depths bind the right values (#421)
# `build_row_join_sql_text` bound ON conditions in `row_join` order (Phase 1) but emitted them in
# relocated order (Phase 1b/2). PostgreSQL was unaffected — `$N` numbering travels with the text —
# while SQLite flattens the `:join` bucket positionally, so the two conditions swapped values.
#
# The failure was at EXECUTION and completely silent: SQLite is dynamically typed, so binding
# "Italy" into `year` and 2009 into `country` raises nothing. It just matches no row. A caller sees
# an empty result and concludes there were no Italian races that season.
#
# This runs on BOTH engines on purpose. `db_2` is the control that was always correct, and the two
# must agree — which is the assertion that would have caught the divergence in the first place.
# Rendering/bucket coverage is in `test/unit/test_order_by_joins.jl` and
# `test/unit/test_alignment_sqlite.jl`.
# ─────────────────────────────────────────────────────────────────────────────
@testset "cjoin ON filters across two join depths bind correctly (#421)" begin
    # `circuitid__country` is one hop deeper than `year`, so its ON fragment forward-references the
    # circuit join and gets relocated onto it. Listing it FIRST is what made binding order differ
    # from emission order. INNER so the ON predicate actually restricts the returned rows.
    deep_first = M.Result.objects
    deep_first.values("resultid")
    deep_first.cjoin("raceid" => "Race", join_type = "INNER",
                     filters = ["circuitid__country" => "Italy", "year" => 2009], warn = false)
    got = Set((deep_first |> DataFrame).resultid)

    # Oracle: the same restriction written as WHERE predicates, which never relocate and so were
    # never affected. Comparing against a live query rather than a hardcoded count keeps this
    # independent of exactly how many Italian races the fixture holds.
    oracle = M.Result.objects
    oracle.values("resultid")
    oracle.filter("raceid__circuitid__country" => "Italy", "raceid__year" => 2009)
    expected = Set((oracle |> DataFrame).resultid)

    # Guard against a vacuously-true Set() == Set(): pre-fix the cjoin returned EMPTY on SQLite,
    # which would match an empty oracle without either being right.
    @test !isempty(expected)
    @test got == expected

    # Control: the same two filters listed the other way round. Binding order already matched
    # emission order for this ordering, so it was correct before the fix too — and must stay so.
    shallow_first = M.Result.objects
    shallow_first.values("resultid")
    shallow_first.cjoin("raceid" => "Race", join_type = "INNER",
                        filters = ["year" => 2009, "circuitid__country" => "Italy"], warn = false)
    @test Set((shallow_first |> DataFrame).resultid) == expected

    # A fragment can bind more than one value: `@in` over three countries beside a single-valued
    # `year` makes the split 3-and-1, so a fix that moved only the first value of a run would still
    # pass everything above. The set must widen to exactly the three countries' 2009 races.
    multi = M.Result.objects
    multi.values("resultid")
    multi.cjoin("raceid" => "Race", join_type = "INNER",
                filters = ["circuitid__country__@in" => ["Italy", "Monaco", "Brazil"], "year" => 2009],
                warn = false)
    multi_oracle = M.Result.objects
    multi_oracle.values("resultid")
    multi_oracle.filter("raceid__circuitid__country__@in" => ["Italy", "Monaco", "Brazil"],
                        "raceid__year" => 2009)
    multi_expected = Set((multi_oracle |> DataFrame).resultid)

    @test length(multi_expected) > length(expected)   # the wider filter really is wider
    @test Set((multi |> DataFrame).resultid) == multi_expected
end
