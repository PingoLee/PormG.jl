# Focused SQLite regression for allocate_primary_keys transaction-scoped reservations.
# Run with:
#   $env:PORMG_DB="db_sl"; julia -t 1 --project=. test/integration/test_allocate_primary_keys_sqlite.jl

if !isdefined(Main, :PormG)
    include("common_setup.jl")
end

using Test
using DataFrames

PORMG_DB_FOLDER == "db_sl" || throw(ArgumentError(
    "test_allocate_primary_keys_sqlite.jl must be run with PORMG_DB=db_sl"
))

# ─────────────────────────────────────────────────────────────────────────────
# allocate_primary_keys: SQLite repeated reservation workflow
#
# This regression proves the SQLite-specific behavior that motivated the new
# transaction-scoped reservation tracking:
#   1. reserve one id range without inserting it yet
#   2. reserve a second id range before the first DataFrame is inserted
#   3. create a row in between
#   4. bulk insert both reserved DataFrames
#
# All generated and reserved ids must stay disjoint. If any step reuses ids
# from an earlier reservation, SQLite raises a duplicate-key error.
# ─────────────────────────────────────────────────────────────────────────────
@testset "allocate_primary_keys SQLite focused regression" begin
    labels_first = ["alloc-pk-sqlite-fast-first-a", "alloc-pk-sqlite-fast-first-b"]
    labels_second = ["alloc-pk-sqlite-fast-second-a", "alloc-pk-sqlite-fast-second-b"]
    labels_created = ["alloc-pk-sqlite-fast-create-a"]
    labels_next = ["alloc-pk-sqlite-fast-next-a"]
    all_labels = vcat(labels_first, labels_second, labels_created, labels_next)

    cleanup = M.Django_contract_scratch.objects
    cleanup.filter("label__@in" => all_labels)
    cleanup.exists() && cleanup.delete()

    try
        first_reserved, second_reserved, created_row = PormG.run_in_transaction(PORMG_DB_FOLDER) do
            first_reserved = allocate_primary_keys(
                M.Django_contract_scratch.objects,
                DataFrame(label = labels_first)
            )

            second_reserved = allocate_primary_keys(
                M.Django_contract_scratch.objects,
                DataFrame(label = labels_second)
            )

            @test minimum(second_reserved.id) > maximum(first_reserved.id)

            created_row = M.Django_contract_scratch.objects.create("label" => labels_created[1])
            @test created_row[:id] > maximum(second_reserved.id)

            bulk_insert(M.Django_contract_scratch.objects, first_reserved)
            bulk_insert(M.Django_contract_scratch.objects, second_reserved)

            return first_reserved, second_reserved, created_row
        end

        rows = M.Django_contract_scratch.objects.filter(
            "label__@in" => all_labels
        ).values("id", "label").list()

        @test length(rows) == 5

        first_label_set = Set(labels_first)
        second_label_set = Set(labels_second)
        reserved_ids = vcat(first_reserved.id, second_reserved.id)

        @test length(unique(reserved_ids)) == 4
        @test !(created_row[:id] in reserved_ids)
        @test Set(row[:id] for row in rows if row[:label] in first_label_set) == Set(first_reserved.id)
        @test Set(row[:id] for row in rows if row[:label] in second_label_set) == Set(second_reserved.id)
        @test count(row -> row[:label] == labels_created[1] && row[:id] == created_row[:id], rows) == 1

        next_row = M.Django_contract_scratch.objects.create("label" => labels_next[1])
        @test next_row[:id] == maximum(vcat(reserved_ids, [created_row[:id]])) + 1
    finally
        cleanup = M.Django_contract_scratch.objects
        cleanup.filter("label__@in" => all_labels)
        cleanup.exists() && cleanup.delete()
    end
end