# Minimal regression test for SQLite DateTimeField normalization (Option 2).
# Run with: $env:PORMG_DB="db_sl"; julia -t 1 --project=. test/integration/test_sqlite_datetime_normalize.jl

include(joinpath(@__DIR__, "common_setup.jl"))
using Dates, TimeZones, Test

label = "copilot-dt-normalize-test"

# ── cleanup helper ──────────────────────────────────────────────────────────
function cleanup!(lbl)
    q = M.Django_contract_scratch.objects
    q.filter("label" => lbl)
    q.exists() && q.delete()
end

cleanup!(label)
try
    before = now(UTC)
    M.Django_contract_scratch.objects.create("label" => label)
    after = now(UTC)

    # Confirm list() returns ZonedDateTime (not String) for DateTimeField columns
    row = M.Django_contract_scratch.objects.filter("label" => label).values("created_at", "updated_at").list() |> first

    @testset "SQLite DateTimeField normalization" begin
        @test row[:created_at] isa ZonedDateTime
        @test row[:updated_at] isa ZonedDateTime

        created_utc = DateTime(astimezone(row[:created_at], TimeZone("UTC")))
        updated_utc = DateTime(astimezone(row[:updated_at], TimeZone("UTC")))

        @test before <= created_utc <= after
        @test before <= updated_utc <= after
    end
finally
    cleanup!(label)
end
