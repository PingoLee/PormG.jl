# julia -t auto  --project=. test/integration/test_reverse_joins.jl

if !isdefined(Main, :PormG)
    include("common_setup.jl")
end


# ─────────────────────────────────────────────────────────────────────────────
# Reverse joins
# Traversal from a model back to a model that holds the FK pointing at it.
# ─────────────────────────────────────────────────────────────────────────────
@testset "Reverse joins" begin
    # Shared fixture: two Just_a_test_deletion rows tied to the first two live Result ids.
    # Cleaned up and re-created at the top so all inner testsets share the same data.
    seed_ids = [910001, 910002]
    seed_names = ["reverse-join-a", "reverse-join-b"]
    result_id_q = M.Result.objects.order_by("resultid").limit(3).values("resultid")
    result_id_df = result_id_q |> DataFrame
    @test nrow(result_id_df) == 3
    result_ids = collect(result_id_df.resultid)
    matched_result_ids = result_ids[1:2]
    unmatched_result_id = result_ids[3]

    cleanup = M.Just_a_test_deletion.objects
    cleanup.filter("id__@in" => seed_ids)
    cleanup.delete()

    cleanup = M.Just_a_test_deletion.objects
    cleanup.filter("name__@in" => seed_names)
    cleanup.delete()

    seed = M.Just_a_test_deletion.objects
    seed.create("id" => seed_ids[1], "name" => seed_names[1], "test_result" => matched_result_ids[1], "test_result_set_default" => nothing)
    seed.create("id" => seed_ids[2], "name" => seed_names[2], "test_result" => matched_result_ids[2], "test_result_set_default" => nothing)

    @testset "basic: filter on reverse field collapses to matched rows only" begin
        # Normal .filter("reverse_relation__field" => ...) does an INNER-style traversal,
        # so only Result rows that have a matching reverse record are returned.
        query_a = M.Just_a_test_deletion.objects
        query_a.filter("name__@in" => seed_names)
        query_a.values("id", "name", "test_result", "test_result2")
        df_a = query_a |> DataFrame

        query = M.Result.objects
        query.values("test_deletion__id", "test_deletion__name", "resultid")
        query.filter("test_deletion__name__@in" => seed_names)
        df = query |> DataFrame

        @test size(df, 1) == size(df_a, 1)
        @test all(in.(df.test_deletion__id, Ref(df_a.id)))
        @test all(in.(df.test_deletion__name, Ref(df_a.name)))
        @test sort(collect(skipmissing(df.resultid))) == sort(matched_result_ids)
    end

    @testset "on() preserves all base rows (LEFT JOIN)" begin
        # query.on() places the predicate in the ON clause, not WHERE.
        # All three Result rows must appear; only matching reverse rows attach.
        # Compare with the test above: .filter() would have returned only 2 rows.
        query_on = M.Result.objects
        query_on.on("test_deletion", "name__@in" => seed_names)
        query_on.filter("resultid__@in" => result_ids)
        query_on.values("resultid", "test_deletion__name")
        df_on = query_on |> DataFrame

        @test nrow(df_on) == 3
        @test sort(df_on.resultid) == sort(result_ids)
        @test df_on[df_on.resultid.==matched_result_ids[1], :test_deletion__name][1] == "reverse-join-a"
        @test df_on[df_on.resultid.==matched_result_ids[2], :test_deletion__name][1] == "reverse-join-b"
        # The third result id has no matching reverse record → column is missing
        @test df_on[df_on.resultid.==unmatched_result_id, :test_deletion__name][1] === missing
    end

    @testset "on() with join_type=INNER narrows to matched rows" begin
        # Switching to INNER eliminates Result row 3 entirely instead of keeping it
        # with a missing column — without moving the predicate into WHERE.
        query_on_inner = M.Result.objects
        query_on_inner.on("test_deletion", "name__@in" => seed_names, join_type="INNER")
        query_on_inner.filter("resultid__@in" => result_ids)
        query_on_inner.values("resultid", "test_deletion__name")
        df_on_inner = query_on_inner |> DataFrame

        @test nrow(df_on_inner) == 2
        @test sort(df_on_inner.resultid) == sort(matched_result_ids)
        @test sort(collect(df_on_inner.test_deletion__name)) == seed_names
    end

    # ─────────────────────────────────────────────────────────────────────────
    # Reverse joins: update through LEFT anti-join
    # When the join predicate lives in ON and the filter asks for joined rows to
    # be NULL, UPDATE must keep the anti-join semantics and mutate only the base
    # rows with no matching joined record.
    # ─────────────────────────────────────────────────────────────────────────
    @testset "update through reverse anti-join" begin
        before_q = M.Result.objects
        before_q.filter("resultid__@in" => result_ids)
        before_q.values("resultid", "points")
        before_df = before_q |> DataFrame

        original_points = Dict(row.resultid => row.points for row in eachrow(before_df))
        updated_points = original_points[unmatched_result_id] + 11

        anti_join_q = M.Result.objects
        anti_join_q.on("test_deletion", "name__@in" => seed_names)
        anti_join_q.filter("resultid__@in" => result_ids, "test_deletion__id__@isnull" => true)

        @test anti_join_q.count() == 1

        try
            anti_join_q.update("points" => updated_points)

            after_q = M.Result.objects
            after_q.filter("resultid__@in" => result_ids)
            after_q.values("resultid", "points")
            after_df = after_q |> DataFrame

            after_points = Dict(row.resultid => row.points for row in eachrow(after_df))

            @test after_points[matched_result_ids[1]] == original_points[matched_result_ids[1]]
            @test after_points[matched_result_ids[2]] == original_points[matched_result_ids[2]]
            @test after_points[unmatched_result_id] == updated_points
        finally
            M.Result.objects.filter("resultid" => unmatched_result_id).update("points" => original_points[unmatched_result_id])
        end
    end
end


# ─────────────────────────────────────────────────────────────────────────────
# on() forward FK
# on() can also be applied to forward FK paths (not just reverse relations).
# The ON predicate is placed in the JOIN clause, so all base rows are preserved
# even when the joined partner does not satisfy the extra predicate.
#
# #474 — the `join_type = "LEFT"` in this block is REQUIRED, not decorative. `Result.driverid` is a
# NOT NULL ForeignKey, so PormG derives INNER for it; before #474 an `on()` with no join_type of its
# own silently wrote "LEFT" and that value was read as an OVERRIDE, retyping a join the caller never
# asked to retype. #474 removed that, so "all base rows preserved" is now something the test has to
# ASK for — exactly as `UPGRADING.md` tells consuming apps to. Without it these testsets do not fail
# loudly everywhere: the accumulation testset below goes green while its `populated` subset silently
# becomes the whole result (#489).
# ─────────────────────────────────────────────────────────────────────────────
@testset "on() forward FK" begin

    @testset "on() forward FK: all base rows preserved (LEFT JOIN)" begin
        # Using .filter("driverid__nationality" => "Brazilian") would return only
        # Brazilian-winner rows (INNER-style traversal through the FK).
        # Using .on("driverid", ...) places the predicate on the ON clause,
        # keeping ALL winner rows while only populating surname for Brazilian drivers.
        query = M.Result.objects
        query.on("driverid", "nationality" => "Brazilian", join_type = "LEFT")
        query.filter("positionorder" => 1)
        query.values("resultid", "driverid__surname")
        df = query |> DataFrame

        # Compare against the direct-filter approach (INNER-style): fewer rows
        inner_q = M.Result.objects
        inner_q.filter("positionorder" => 1, "driverid__nationality" => "Brazilian")
        inner_q.values("resultid", "driverid__surname")
        df_inner = inner_q |> DataFrame

        # on() (LEFT) returns more rows than the inner-style filter
        @test nrow(df) > nrow(df_inner)

        # The rows that did get surname populated match exactly what the inner filter returned
        populated = df[.!ismissing.(df.driverid__surname), :]
        @test nrow(populated) == nrow(df_inner)
    end

    @testset "on() accumulation: two calls AND their predicates" begin
        # Two on() calls on the same join path accumulate as AND conditions in the ON clause.
        # British AND code HAM means only Lewis Hamilton satisfies both predicates.
        # (Ayrton Senna's code is stored as "\\N" in the dataset, so he cannot be used here.)
        #
        # The join_type goes on the FIRST call only — #474's other half: a later on() with no
        # join_type inherits the earlier explicit one rather than resetting it. Measured without it
        # (#489): INNER, 105 rows, ZERO missing surnames, which makes the `populated` subset below
        # the identity operation and every assertion in this testset trivially true. With it: 1128
        # rows, 1023 missing — so `populated` is a real subset and the test measures something.
        query = M.Result.objects
        query.on("driverid", "nationality" => "British", join_type = "LEFT")
        query.on("driverid", "code" => "HAM")
        query.filter("positionorder" => 1)
        query.values("resultid", "driverid__surname", "driverid__code")
        df = query |> DataFrame

        # LEFT JOIN: all winners appear
        @test nrow(df) > 0

        # Only Hamilton (British + HAM) satisfies both predicates and gets columns populated
        populated = df[.!ismissing.(df.driverid__surname), :]
        @test nrow(populated) > 0
        @test all(populated.driverid__code .== "HAM")
        @test all(populated.driverid__surname .== "Hamilton")

        # Compare with single predicate: double predicate yields ≤ rows populated.
        # Same join_type as the two-predicate query above — the comparison is only meaningful if
        # both sides are the same kind of join.
        query_single = M.Result.objects
        query_single.on("driverid", "nationality" => "British", join_type = "LEFT")
        query_single.filter("positionorder" => 1)
        query_single.values("resultid", "driverid__surname")
        df_single = query_single |> DataFrame
        populated_single = df_single[.!ismissing.(df_single.driverid__surname), :]

        # British includes Hamilton AND other British drivers; the double predicate is stricter
        @test nrow(populated) <= nrow(populated_single)
    end
end


# ─────────────────────────────────────────────────────────────────────────────
# on() error paths
# Guard tests for invalid on() usage patterns.
# ─────────────────────────────────────────────────────────────────────────────
@testset "on() error paths" begin

    @testset "on() on a non-relational field is rejected" begin
        # on() requires the first segment of the join path to be a FK or reverse relation.
        # Scalars like `points` (FloatField) cannot be traversed.
        q = M.Result.objects
        @test_throws PormGError q.on("points", "points__@gt" => 0)
    end

    @testset "on() with no filters and no join_type is rejected" begin
        # An on() call with nothing to contribute is meaningless and is rejected early.
        q = M.Result.objects
        @test_throws PormGError q.on("driverid")
    end

end


# ─────────────────────────────────────────────────────────────────────────────
# related_objects Coverage: Second related_name (test_deletion2)
# Verifies that a second FK from the same model to the same target, using an
# explicit related_name, resolves correctly for filter, values, and on().
# ─────────────────────────────────────────────────────────────────────────────
@testset "Reverse joins - second related_name (test_deletion2)" begin
    # Shared fixture: two Just_a_test_deletion rows using the second FK (test_result2).
    seed_ids = [920001, 920002]
    seed_names = ["rev2-join-a", "rev2-join-b"]
    result_id_q = M.Result.objects
    result_id_q.order_by("resultid")
    result_id_q.limit(3)
    result_id_q.values("resultid")
    result_id_df = result_id_q |> DataFrame
    @test nrow(result_id_df) == 3
    result_ids = collect(result_id_df.resultid)
    matched_result_ids = result_ids[1:2]
    unmatched_result_id = result_ids[3]

    cleanup = M.Just_a_test_deletion.objects
    cleanup.filter("id__@in" => seed_ids)
    cleanup.delete()

    cleanup = M.Just_a_test_deletion.objects
    cleanup.filter("name__@in" => seed_names)
    cleanup.delete()

    seed = M.Just_a_test_deletion.objects
    seed.create("id" => seed_ids[1], "name" => seed_names[1], "test_result2" => matched_result_ids[1], "test_result_set_default" => nothing)
    seed.create("id" => seed_ids[2], "name" => seed_names[2], "test_result2" => matched_result_ids[2], "test_result_set_default" => nothing)

    @testset "filter on test_deletion2 reverse field" begin
        # .filter("test_deletion2__name" => ...) must resolve via the second related_name.
        query = M.Result.objects
        query.values("test_deletion2__id", "test_deletion2__name", "resultid")
        query.filter("test_deletion2__name__@in" => seed_names)
        df = query |> DataFrame

        @test size(df, 1) == 2
        @test sort(collect(skipmissing(df.resultid))) == sort(matched_result_ids)
        @test all(in.(df.test_deletion2__name, Ref(seed_names)))
    end

    @testset "on() with test_deletion2 (LEFT JOIN)" begin
        # on() places the predicate in the ON clause, preserving all base rows.
        query_on = M.Result.objects.on("test_deletion2", "name__@in" => seed_names)
        query_on.filter("resultid__@in" => result_ids)
        query_on.values("resultid", "test_deletion2__name")
        df_on = query_on |> DataFrame

        # insp = query_on |> inspect_query
        # @info insp[:sql_text]

        @test nrow(df_on) == 3
        @test sort(df_on.resultid) == sort(result_ids)
        @test df_on[df_on.resultid.==matched_result_ids[1], :test_deletion2__name][1] == "rev2-join-a"
        @test df_on[df_on.resultid.==matched_result_ids[2], :test_deletion2__name][1] == "rev2-join-b"
        # The third result id has no matching reverse record → column is missing
        @test df_on[df_on.resultid.==unmatched_result_id, :test_deletion2__name][1] === missing
    end
end


# ─────────────────────────────────────────────────────────────────────────────
# related_objects Coverage: Chained (multi-hop) reverse joins
# Result ← Just_a_test_deletion (via test_deletion) ← Just_a_nested_roll_back (via auto-name)
# This exercises the while-loop branch at build_joins.jl:L238-L259.
# ─────────────────────────────────────────────────────────────────────────────
@testset "Chained reverse joins (Result → test_deletion → nested)" begin
    # Fixture: create a Just_a_test_deletion row tied to the first live Result id,
    # then a Just_a_nested_roll_back row tied to that deletion row.
    nested_del_id = 930001
    nested_rb_id = 940001
    result_id_q = M.Result.objects
    result_id_q.order_by("resultid")
    result_id_q.limit(4)
    result_id_q.values("resultid")
    result_id_df = result_id_q |> DataFrame
    @test nrow(result_id_df) >= 4
    result_ids = collect(result_id_df.resultid)
    matched_result_id = result_ids[3]
    other_result_id = result_ids[4]

    # Clean up any previous test data — including rows left by earlier testsets
    # (e.g., "Reverse joins" seeds rows with test_result => 1 and 2)
    cleanup_rb = M.Just_a_nested_roll_back.objects
    cleanup_rb.filter("id" => nested_rb_id)
    cleanup_rb.delete()

    cleanup_del = M.Just_a_test_deletion.objects
    cleanup_del.filter("id" => nested_del_id)
    cleanup_del.delete()

    # Seed: Just_a_test_deletion → a later live Result id so earlier reverse-join
    # fixtures in this file do not overlap with the chain-specific assertions.
    seed_del = M.Just_a_test_deletion.objects
    seed_del.create("id" => nested_del_id, "name" => "chain-parent", "test_result" => matched_result_id, "test_result_set_default" => nothing)

    # Seed: Just_a_nested_roll_back → Just_a_test_deletion (id=nested_del_id)
    seed_rb = M.Just_a_nested_roll_back.objects
    seed_rb.create("id" => nested_rb_id, "test" => nested_del_id, "description" => "chain-nested-a")

    @testset "filter traversing two reverse hops" begin
        # Result → test_deletion → just_a_nested_roll_back → description
        query = M.Result.objects
        query.values("resultid", "test_deletion__just_a_nested_roll_back__description")
        query.filter("test_deletion__just_a_nested_roll_back__description" => "chain-nested-a")
        df = query |> DataFrame

        @test nrow(df) >= 1
        @test all(df.test_deletion__just_a_nested_roll_back__description .== "chain-nested-a")
        @test matched_result_id in df.resultid
    end

    @testset "on() through chained reverse path" begin
        # on() with a filter that traverses the chained reverse relation.
        # Only Result rows whose test_deletion child has a matching nested grandchild
        # should get the test_deletion columns populated.
        query_on = M.Result.objects
        query_on.on("test_deletion", "just_a_nested_roll_back__description" => "chain-nested-a")
        query_on.filter("resultid__@in" => [matched_result_id, other_result_id])
        query_on.values("resultid", "test_deletion__name")
        df_on = query_on |> DataFrame

        @test nrow(df_on) == 2
        # The first live Result id has the matching chain → name is populated
        @test df_on[df_on.resultid.==matched_result_id, :test_deletion__name][1] == "chain-parent"
        # The second live Result id has no matching nested record → name is missing
        @test df_on[df_on.resultid.==other_result_id, :test_deletion__name][1] === missing
    end

    # Cleanup
    cleanup_rb2 = M.Just_a_nested_roll_back.objects
    cleanup_rb2.filter("id" => nested_rb_id)
    cleanup_rb2.delete()

    cleanup_del2 = M.Just_a_test_deletion.objects
    cleanup_del2.filter("id" => nested_del_id)
    cleanup_del2.delete()
end
