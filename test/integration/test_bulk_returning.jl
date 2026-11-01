if !isdefined(Main, :PormG)
    include("common_setup.jl")
end

# A PostgreSQL TIMESTAMPTZ comes back as a ZonedDateTime; common_setup.jl does not load TimeZones.
using TimeZones

# ─────────────────────────────────────────────────────────────────────────────
# bulk_insert(…; returning=) against a real database, both engines (#671)
#
# The unit file proves the matching logic against a temp SQLite database and a mock PostgreSQL
# pool. What only a real database can show: that PostgreSQL's `RETURNING` and SQLite's read-back
# hand back the values the table actually holds — driver types included (a TIMESTAMPTZ, a
# DECIMAL) — and that the ids a real sequence pre-allocates are the ids the rows are stored under.
#
# The oracle is always an independent read of the table through the ORM, keyed by a unique label:
# `rows[i, :]` must equal what the database holds for input row i's label.
#
# Every row this file writes carries a `br671-` label and is removed in `finally`. Pre-allocation
# draws the sequence exactly as the same inserts without `returning=` would.
# ─────────────────────────────────────────────────────────────────────────────

# The table's own view of the rows, keyed by label: `label => (id, cols...)` as a NamedTuple row.
_br671_by_label(q, labels, cols) = begin
    q.filter("label__@in" => labels)
    q.values("label", cols...)
    Dict(row.label => row for row in eachrow(DataFrames.DataFrame(q)))
end

# ─────────────────────────────────────────────────────────────────────────────
# Auto pk across chunks, with a timestamp and a decimal returned.
# Five rows at chunk_size = 2 are three statements, and the `id` column is absent from the frame, so
# the ids are pre-allocated. `created_at` is filled by PormG (`auto_now_add`) and `price` is a
# DECIMAL — both are driver round-trips, which is what this layer is for.
# ─────────────────────────────────────────────────────────────────────────────
# `returning=` with the pk absent from the frame draws the ids before the INSERT. A backend that cannot
# refuses it, naming the feature, and writes nothing (#1266); the frames below that carry their pk, or
# conflict on a target, still run there.
const BR_PREALLOCATES = requires(:preallocated_keys)
if !BR_PREALLOCATES
    @testset "returning=: an auto pk is refused where keys cannot be drawn ahead (#1266)" begin
        labels = ["br671-refused-$(i)" for i in 1:2]
        df = DataFrames.DataFrame(label = labels, price = [1.5, 2.5])
        err = try
            bulk_insert(M.Django_contract_scratch.objects, df; returning = ["id", "price"])
            nothing
        catch e
            e
        end
        @test err isa PormG.BackendCapabilityError && occursin("drawing auto-increment keys", err.msg)
        q = M.Django_contract_scratch.objects
        q.filter("label__@in" => labels)
        @test !q.exists()
    end
end
BR_PREALLOCATES && @testset "returning=: auto pk, timestamp and decimal, correlated to the input (#671)" begin
    labels = ["br671-auto-$(i)" for i in 1:5]
    purge() = (q = M.Django_contract_scratch.objects; q.filter("label__@in" => labels); q.exists() && q.delete())
    purge()
    try
        # Deliberately NOT in label order, so input order and any natural table order disagree.
        order = [3, 1, 5, 2, 4]
        df = DataFrames.DataFrame(label = labels[order], price = [10.5, 20.25, 30.0, 40.75, 50.5][order])
        r = bulk_insert(M.Django_contract_scratch.objects, df;
            returning = ["id", "created_at", "price"], chunk_size = 2)
        @test r.count == 5
        @test DataFrames.nrow(r.rows) == 5

        stored = _br671_by_label(M.Django_contract_scratch.objects, labels, ["id", "created_at", "price"])
        @test r.rows.id == [stored[l].id for l in df.label]
        @test r.rows.created_at == [stored[l].created_at for l in df.label]
        @test Float64.(r.rows.price) == Float64.([stored[l].price for l in df.label])
        @test r.rows.created_at[1] isa ZonedDateTime
        # The caller's frame gained no id column.
        @test names(df) == ["label", "price"]
    finally
        purge()
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# ON CONFLICT by target: DO NOTHING leaves skipped rows missing; DO UPDATE returns the existing id.
# `label` is UNIQUE. One label exists before the call, and one is repeated inside the frame, so the
# DO NOTHING call writes two of four rows. The DO UPDATE call then rewrites a price and must hand
# back the id the row already had — which the pk could never have matched.
# ─────────────────────────────────────────────────────────────────────────────
@testset "returning=: on_conflict by target (#671)" begin
    labels = ["br671-oc-a", "br671-oc-b", "br671-oc-c"]
    purge() = (q = M.Django_contract_scratch.objects; q.filter("label__@in" => labels); q.exists() && q.delete())
    purge()
    try
        existing_id = M.Django_contract_scratch.objects.create("label" => "br671-oc-a", "price" => 1.0).id

        df = DataFrames.DataFrame(label = ["br671-oc-a", "br671-oc-b", "br671-oc-c", "br671-oc-b"],
                                  price = [2.0, 3.0, 4.0, 5.0])
        r = bulk_insert(M.Django_contract_scratch.objects, df; returning = ["id", "price"], chunk_size = 2,
            on_conflict = (action = :nothing, target = ["label"]))
        stored = _br671_by_label(M.Django_contract_scratch.objects, labels, ["id", "price"])
        @test r.count == 2
        @test isequal(r.rows.id, [missing, stored["br671-oc-b"].id, stored["br671-oc-c"].id, missing])
        # The written b is the first occurrence (3.0), and a keeps the price it had (1.0).
        @test Float64(stored["br671-oc-b"].price) == 3.0
        @test Float64(stored["br671-oc-a"].price) == 1.0

        up = DataFrames.DataFrame(label = ["br671-oc-a"], price = [9.5])
        r = bulk_insert(M.Django_contract_scratch.objects, up; returning = ["id", "price"],
            on_conflict = (action = :update, target = ["label"], set = ["price"]))
        @test r.rows.id == [existing_id]
        @test Float64.(r.rows.price) == [9.5]
    finally
        purge()
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# #1344 phase 4: `rows` is a table of the kind the caller passed. The same DO NOTHING call as above,
# from a `Vector` of `NamedTuple`s and from a `NamedTuple` of vectors, on every engine (keyed by the
# UNIQUE `label`, so MySQL needs no pre-allocation). Expected: a `Vector` of `NamedTuple`s and a
# `NamedTuple` of vectors back, each row holding what the table stores for its input row, a skipped
# row `missing`. Why it matters: each engine's own RETURNING or read-back result now reaches PormG's
# code without a DataFrame in between.
# ─────────────────────────────────────────────────────────────────────────────
@testset "returning=: rows come back as the caller's kind of table (#1344)" begin
    labels = ["br671-kind-a", "br671-kind-b", "br671-kind-c"]
    purge() = (q = M.Django_contract_scratch.objects; q.filter("label__@in" => labels); q.exists() && q.delete())
    purge()
    try
        existing_id = M.Django_contract_scratch.objects.create("label" => "br671-kind-a", "price" => 1.0).id
        rows = [(label = "br671-kind-a", price = 2.0), (label = "br671-kind-b", price = 3.0)]
        r = bulk_insert(M.Django_contract_scratch.objects, rows; returning = ["id", "price"],
            on_conflict = (action = :nothing, target = ["label"]))
        stored = _br671_by_label(M.Django_contract_scratch.objects, labels, ["id", "price"])
        @test r.count == 1
        @test r.rows isa Vector{<:NamedTuple} && length(r.rows) == 2
        @test isequal(getproperty.(r.rows, :id), [missing, stored["br671-kind-b"].id])
        @test Float64(r.rows[2].price) == 3.0

        cols = (label = ["br671-kind-c", "br671-kind-a"], price = [4.0, 9.5])
        r = bulk_insert(M.Django_contract_scratch.objects, cols; returning = ["id", "price"],
            on_conflict = (action = :update, target = ["label"], set = ["price"]))
        stored = _br671_by_label(M.Django_contract_scratch.objects, labels, ["id", "price"])
        @test r.rows isa NamedTuple && keys(r.rows) == (:id, :price)
        @test r.rows.id == [stored["br671-kind-c"].id, existing_id]
        @test Float64.(r.rows.price) == [4.0, 9.5]
    finally
        purge()
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# Foreign-key wiring from returned ids: the use case `allocate_primary_keys` used to be the only
# answer to. Parents are inserted with `returning = ["id"]`, and children are built from those ids;
# every child must then point at the parent carrying its intended label.
# ─────────────────────────────────────────────────────────────────────────────
BR_PREALLOCATES && @testset "returning=: wire child rows from returned parent ids (#671)" begin
    parent_labels = ["br671-fk-$(i)" for i in 1:3]
    parents = () -> (q = M.Bulk_update_required_parent_scratch.objects; q.filter("label__@in" => parent_labels); q)
    children = () -> (q = M.Bulk_update_payload_scratch.objects; q.filter("label__@in" => parent_labels); q)
    purge() = (children().exists() && children().delete(); parents().exists() && parents().delete())
    purge()
    try
        pdf = DataFrames.DataFrame(label = parent_labels)
        r = bulk_insert(M.Bulk_update_required_parent_scratch.objects, pdf; returning = ["id"])
        # Each child carries its parent's label, so the join below can check the wiring.
        cdf = DataFrames.DataFrame(label = parent_labels, required_parent_id = r.rows.id)
        @test bulk_insert(M.Bulk_update_payload_scratch.objects, cdf).count == 3

        q = children()
        q.values("label", "required_parent_id__label")
        wired = DataFrames.DataFrame(q)
        @test sort(collect(zip(wired.label, wired.required_parent_id__label))) ==
              [(l, l) for l in parent_labels]
    finally
        purge()
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# A PormG-minted UUID pk (PostgreSQL only: db_sl/models.jl deliberately declares no
# `Bulk_uuid_pk_scratch`, and its comment says why). Recorded as a skip elsewhere (#1179).
# The pk is filled before the INSERT, so it is the key as it stands; nothing is allocated.
# ─────────────────────────────────────────────────────────────────────────────
if only_on(:postgres, "db_sl/models.jl declares no UUID-pk scratch table (see its comment)")
    @testset "returning=: UUID auto_add pk (#671)" begin
        labels = ["br671-uuid-$(i)" for i in 1:3]
        purge() = (q = M.Bulk_uuid_pk_scratch.objects; q.filter("label__@in" => labels); q.exists() && q.delete())
        purge()
        try
            r = bulk_insert(M.Bulk_uuid_pk_scratch.objects, DataFrames.DataFrame(label = labels);
                returning = ["token", "label"])
            @test r.rows.label == labels
            stored = _br671_by_label(M.Bulk_uuid_pk_scratch.objects, labels, ["token"])
            @test string.(r.rows.token) == [string(stored[l].token) for l in labels]
            @test length(unique(r.rows.token)) == 3
        finally
            purge()
        end
    end
end
