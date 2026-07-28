"""
Integration round-trips for JSON/JSONB path lookups and containment operators (#27).

Reuses the existing `Field_validation_scratch.payload` JSONField (no schema migration). Seeds one
row with a nested payload, then exercises:
  - JSON path lookups (BOTH backends): equality, array-index, numeric comparison, `.values()`
    projection, `__@isnull` on a missing key, and a non-matching negative.
  - JSON containment operators (PostgreSQL ONLY — SQLite has no equivalent): @>, ?, ?|, ?&.

Result-driven: every assertion checks that the right row is (or is not) returned, so a wrong
extraction path or operator fails the test rather than silently returning nothing.
"""

if !isdefined(Main, :PormG)
    include("common_setup.jl")
end

# Active backend: the JSON containment operators are PostgreSQL-only.
_json_backend_is_pg() = PormG.config[PORMG_DB_FOLDER].connections isa PormG.PormGPostgres

@testset "JSON/JSONB lookups and operators (#27)" begin
    slug = "json27-scratch-seed"
    seeded = Dict(
        "driver" => "hamilton",
        "points" => 15,
        "active" => true,
        "standings" => [Dict("name" => "Max"), Dict("name" => "Lewis")],
    )

    # Clean any stale row, then seed exactly one.
    cleanup = M.Field_validation_scratch.objects
    cleanup.filter("slug" => slug)
    cleanup.exists() && cleanup.delete()

    M.Field_validation_scratch.objects.create(
        "uuid_token" => string(UUIDs.uuid4()),
        "canonical_url" => "https://example.com/json27",
        "slug" => slug,
        "payload" => seeded,
    )

    # Narrow every query to the seeded row so counts are deterministic regardless of other data.
    base = () -> (q = M.Field_validation_scratch.objects; q.filter("slug" => slug); q)

    try
        # ── JSON path lookups (both backends) ────────────────────────────────
        @testset "path lookups (both dialects)" begin
            # equality on a top-level key
            q = base(); q.filter("payload__driver" => "hamilton")
            @test q.count() == 1

            # equality that must NOT match (negative discriminates a broken extraction)
            q = base(); q.filter("payload__driver" => "norris")
            @test q.count() == 0

            # equality on a NUMERIC JSON value — SQLite json_extract returns a native number, so the
            # RHS must bind native (5=5), not text (5='5' → 0 rows). Regression for the type bug.
            q = base(); q.filter("payload__points" => 15)
            @test q.count() == 1
            q = base(); q.filter("payload__points" => 99)
            @test q.count() == 0

            # array index + nested key: standings[0].name == "Max"
            q = base(); q.filter("payload__standings__0__name" => "Max")
            @test q.count() == 1
            q = base(); q.filter("payload__standings__1__name" => "Max")
            @test q.count() == 0     # standings[1].name is "Lewis"

            # numeric comparison (PG casts ::numeric; SQLite native)
            q = base(); q.filter("payload__points__@gte" => 10)
            @test q.count() == 1
            q = base(); q.filter("payload__points__@gte" => 100)
            @test q.count() == 0

            # __@isnull on a MISSING key → extraction is NULL → matches
            q = base(); q.filter("payload__missing__@isnull" => true)
            @test q.count() == 1
            q = base(); q.filter("payload__driver__@isnull" => true)
            @test q.count() == 0     # present key is NOT null

            # .values() projection returns the extracted value
            q = base(); q.values("payload__driver")
            row = q.list() |> first
            @test string(row[:payload__driver]) == "hamilton"

            # order_by on a JSON path executes on BOTH backends (the DB-free unit test cannot reach
            # the SQLite ORDER BY path — it trips the #75 version probe on a mock — so a real
            # connection covers that clause-path here).
            q = base(); q.values("id", "payload__driver"); q.order_by("payload__driver")
            ordered = q.list()
            @test length(ordered) == 1
            @test string(ordered[1][:payload__driver]) == "hamilton"
        end

        # ── JSON containment operators (PostgreSQL only) ─────────────────────
        if _json_backend_is_pg()
            @testset "containment operators (PostgreSQL)" begin
                q = base(); q.filter("payload__@has_key" => "driver")
                @test q.count() == 1
                q = base(); q.filter("payload__@has_key" => "nope")
                @test q.count() == 0

                q = base(); q.filter("payload__@jcontains" => Dict("driver" => "hamilton"))
                @test q.count() == 1
                q = base(); q.filter("payload__@jcontains" => Dict("driver" => "norris"))
                @test q.count() == 0

                q = base(); q.filter("payload__@has_any_keys" => ["driver", "nope"])
                @test q.count() == 1
                q = base(); q.filter("payload__@has_any_keys" => ["nope1", "nope2"])
                @test q.count() == 0

                q = base(); q.filter("payload__@has_keys" => ["driver", "points"])
                @test q.count() == 1
                q = base(); q.filter("payload__@has_keys" => ["driver", "nope"])
                @test q.count() == 0
            end
        else
            @testset "containment operators throw on SQLite" begin
                q = base(); q.filter("payload__@has_key" => "driver")
                @test_throws PormG.UnsupportedConnectionError q.count()
            end
        end
    finally
        cleanup = M.Field_validation_scratch.objects
        cleanup.filter("slug" => slug)
        cleanup.exists() && cleanup.delete()
    end
end
