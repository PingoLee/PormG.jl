"""
A NUL in a string value is refused before anything is sent, on a real database (#951).

The unit file `test/unit/test_nul_in_string_values.jl` pins the check against mocks. This one runs
it against the live drivers, where the defect lived: before #951, LibPQ silently cut the value at
the NUL (the filter below matched Senna's rows), Postgres.jl surfaced the server's SQLSTATE 22021 as
a `StatementError`, and SQLite stored every byte but read back only up to the NUL (and cut a
`LIKE` pattern at it). Run it once per
driver:

    julia -t auto --project=test/integration test/integration/test_nul_string_values.jl                                 # LibPQ
    PORMG_POSTGRES_DRIVER=postgres julia -t auto --project=test/integration test/integration/test_nul_string_values.jl  # Postgres.jl
    PORMG_DB=db_sl julia -t 1 --project=test/integration test/integration/test_nul_string_values.jl                     # SQLite

Every write uses scratch rows tagged `nul951`, removed before and after.
"""

if !isdefined(Main, :PormG)
    include("common_setup.jl")
end

const NUL951_POOL = PormG.config[PORMG_DB_FOLDER].connections
const NUL951_IS_PG = NUL951_POOL isa PormG.PormGPostgres
const NUL951_VALUE = "Senna\0hidden"   # the text after the NUL must never appear in a message

nul951_refusal(f) = try f(); nothing catch e e end
nul951_is_refusal(e) = e isa PormG.InvalidValueError && occursin("contains a NUL character", e.msg) &&
                       !occursin("hidden", sprint(showerror, e))

nul951_scratch_names() =
    [r[:name] for r in M.Bulk_copy_fidelity_scratch.objects.filter("name__@startswith" => "nul951").
         values("name").order_by("name").list()]
function nul951_clear!()
    q = M.Bulk_copy_fidelity_scratch.objects.filter("name__@startswith" => "nul951")
    q.exists() && q.delete()
    q = M.Field_validation_scratch.objects.filter("slug__@startswith" => "nul951")
    q.exists() && q.delete()
    return nothing
end

# ─────────────────────────────────────────────────────────────────────────────
# Filters and raw SQL: refused on the live driver, before the statement is sent
# The F1 fixture has drivers named Senna, so on LibPQ before #951 the filter below ran as
# `surname = 'Senna'` and returned them. Now it raises, with the parameter named and the value not.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#951: a NUL in a filter or raw value is refused on $(PORMG_DB_FOLDER)" begin
    # The control: the clean value finds the fixture rows the truncated one used to match.
    @test M.Driver.objects.filter("surname" => "Senna").count() > 0

    @test nul951_is_refusal(nul951_refusal(() -> M.Driver.objects.filter("surname" => NUL951_VALUE).list()))
    @test nul951_is_refusal(nul951_refusal(() -> M.Driver.objects.filter("surname__@in" => ["Prost", NUL951_VALUE]).count()))
    @test nul951_is_refusal(nul951_refusal(() -> M.Driver.objects.filter("surname__@icontains" => NUL951_VALUE).exists()))

    # Raw SQL with the backend's own placeholder, and the statement text itself.
    placeholder = NUL951_IS_PG ? "\$1::text" : "?"
    @test nul951_is_refusal(nul951_refusal(() -> fetch(NUL951_POOL, "SELECT $placeholder AS t", [NUL951_VALUE])))
    @test nul951_is_refusal(nul951_refusal(() -> fetch(NUL951_POOL, "SELECT '$NUL951_VALUE' AS t")))
    # The same raw query with a clean value still runs, so the refusal is about the NUL alone.
    @test (fetch(NUL951_POOL, "SELECT $placeholder AS t", ["Senna"]) |> DataFrame).t[1] == "Senna"

    # The advisory-lock key: on LibPQ it used to lock on "nul951" — another key's lock.
    ran = Ref(false)
    e = nul951_refusal(() -> PormG.with_advisory_lock(() -> (ran[] = true), NUL951_POOL, "nul951\0x";
                                                      on_missing_lock = :ignore))
    @test nul951_is_refusal(e) && !ran[]
end

# ─────────────────────────────────────────────────────────────────────────────
# Writes: refused, naming the field (and the row for a bulk write), and nothing is stored
# On LibPQ each of these used to store "nul951 Senna" — a different value than the one given —
# with no error. Afterwards the scratch table holds exactly the clean rows written on purpose.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#951: a NUL in a write value is refused and nothing is stored on $(PORMG_DB_FOLDER)" begin
    nul951_clear!()
    try
        M.Bulk_copy_fidelity_scratch.objects.create("name" => "nul951 clean")
        M.Bulk_copy_fidelity_scratch.objects.create("name" => "nul951 clean 2")
        scratch_id(name) = only(M.Bulk_copy_fidelity_scratch.objects.filter("name" => name).values("id").list())[:id]
        clean_id, clean_id2 = scratch_id("nul951 clean"), scratch_id("nul951 clean 2")
        bad = "nul951 " * NUL951_VALUE

        e = nul951_refusal(() -> M.Bulk_copy_fidelity_scratch.objects.create("name" => bad))
        @test nul951_is_refusal(e) && occursin("field `name`", e.msg)
        e = nul951_refusal(() -> M.Bulk_copy_fidelity_scratch.objects.filter("id" => clean_id).update("name" => bad))
        @test nul951_is_refusal(e) && occursin("field `name`", e.msg)

        # Bulk writers: row 1 clean, row 2 not. The whole call is refused, naming row 2. (bulk_update
        # gets two distinct keys: a repeated key is a `QueryBuildError` of its own, raised first.)
        e = nul951_refusal(() -> bulk_insert(M.Bulk_copy_fidelity_scratch.objects,
                                             DataFrame(name = ["nul951 bulk", bad])))
        @test nul951_is_refusal(e) && occursin("row 2", e.msg)
        e = nul951_refusal(() -> bulk_update(M.Bulk_copy_fidelity_scratch.objects,
                                             DataFrame(id = [clean_id, clean_id2], name = ["nul951 changed", bad])))
        @test nul951_is_refusal(e) && occursin("row 2", e.msg)
        if NUL951_IS_PG
            # COPY never passes `fetch`: it is refused at the same format step as every other write.
            e = @test_logs (:error,) match_mode = :any nul951_refusal(() ->
                bulk_copy(M.Bulk_copy_fidelity_scratch.objects, DataFrame(name = ["nul951 copy", bad])))
            @test nul951_is_refusal(e) && occursin("row 2", e.msg)
        end

        # Nothing but the clean rows was stored, and neither was changed — not even row 1 of the
        # refused bulk_update, which was valid on its own.
        @test nul951_scratch_names() == ["nul951 clean", "nul951 clean 2"]
    finally
        nul951_clear!()
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# Binary is not text: a NUL byte still round-trips
# The refusal is for text only. A `BinaryField` value with a NUL in the middle is written through
# `create`, `update` and a filter on another column, and read back byte for byte.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#951: binary bytes containing a NUL still round-trip on $(PORMG_DB_FOLDER)" begin
    nul951_clear!()
    try
        bytes = UInt8[0x61, 0x00, 0x62, 0x00]
        M.Field_validation_scratch.objects.create(
            "uuid_token" => "951a0000-0000-4000-8000-000000000951",
            "canonical_url" => "https://www.formula1.com/en/drivers/ayrton-senna",
            "slug" => "nul951-senna",
            "blob_payload" => bytes)
        read_back() = only(M.Field_validation_scratch.objects.filter("slug" => "nul951-senna").
                               values("blob_payload").list())[:blob_payload]
        @test Vector{UInt8}(read_back()) == bytes

        updated = UInt8[0x00, 0x00, 0x7a]
        M.Field_validation_scratch.objects.filter("slug" => "nul951-senna").update("blob_payload" => updated)
        @test Vector{UInt8}(read_back()) == updated
    finally
        nul951_clear!()
    end
end
