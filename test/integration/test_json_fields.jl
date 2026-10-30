"""
Integration round-trips for JSON/JSONB path lookups and containment operators (#27).

Reuses the existing `Field_validation_scratch.payload` JSONField (no schema migration). Seeds one
row with a nested payload, then exercises:
  - JSON path lookups (BOTH backends): equality, array-index, numeric comparison, `.values()`
    projection, `__@isnull` on a missing key, and a non-matching negative.
  - JSON containment operators (PostgreSQL ONLY — SQLite has no equivalent): @>, ?, ?|, ?&.
  - A NUL in a JSON value (#954): refused on both backends before the statement is sent.

Result-driven: every assertion checks that the right row is (or is not) returned, so a wrong
extraction path or operator fails the test rather than silently returning nothing.
"""

if !isdefined(Main, :PormG)
    include("common_setup.jl")
end

# The JSON containment and key operators are the `:jsonb_operators` row of the capability table:
# each use below asks `requires(:jsonb_operators)`, never which engine this is.

@testset "JSON/JSONB lookups and operators (#27)" begin
    slug = "json27-scratch-seed"
    seeded = Dict(
        "driver" => "hamilton",
        "points" => 15,
        "active" => true,
        "standings" => [Dict("name" => "Max"), Dict("name" => "Lewis")],
        "sponsor" => nothing,
        "team" => "Mercedes ",
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

            # A key that HOLDS JSON null extracts to NULL too, on every engine: MySQL's JSON_UNQUOTE
            # alone reads it as the text 'null' (#1130 phase 5b), which `@isnull` would not match and
            # an equality with "null" would.
            q = base(); q.filter("payload__sponsor__@isnull" => true)
            @test q.count() == 1
            q = base(); q.filter("payload__sponsor" => "null")
            @test q.count() == 0

            # A trailing space is part of the text on every engine: MySQL's JSON text pads in its own
            # `utf8mb4_bin` collation, so `"Mercedes "` equalled "Mercedes" there (#1130 phase 5b).
            q = base(); q.filter("payload__team" => "Mercedes")
            @test q.count() == 0
            q = base(); q.filter("payload__team" => "Mercedes ")
            @test q.count() == 1

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

        # ── get_or_create by a whole JSON document (both backends, #717) ─────
        # The hit read binds the document as the one JSON string the INSERT bound. Only a live
        # server proves PostgreSQL types that untyped parameter as jsonb for `payload = $1`, and
        # that SQLite's text comparison finds the row written from the same value. `payload` has no
        # UNIQUE constraint, so a hit that failed to match would fall through to an INSERT that
        # raises the missing-constraint error: this assertion cannot pass by creating a row.
        @testset "get_or_create matches a JSON document lookup (#717)" begin
            row, created = M.Field_validation_scratch.objects.get_or_create("payload" => seeded)
            @test created == false
            @test row.slug == slug
        end

        # A plain filter on the whole document matches its row, and a different document does not
        # (#1130 phase 5b): on MySQL the bare marker compared the JSON column with a JSON string, so
        # no document matched even its own text, and get_or_create above missed into an INSERT.
        @testset "a whole JSON document matches its own row" begin
            q = base(); q.filter("payload" => PormG.Models.format_json_sql(seeded))
            @test q.count() == 1
            q = base(); q.filter("payload" => PormG.Models.format_json_sql(merge(seeded, Dict("points" => 16))))
            @test q.count() == 0
        end

        # The same comparison through a projection alias and through `F("payload") ==` (#1360). Both
        # bound a bare marker on MySQL, a JSON string no stored document equals, so each matched no
        # row with no error. Expected: the seeded document matches its own row through either spelling
        # on every engine, a different document matches none, and `!=` is the complement.
        @testset "a whole JSON document through an alias or F(...) == (#1360)" begin
            doc = PormG.Models.format_json_sql(seeded)
            other = PormG.Models.format_json_sql(merge(seeded, Dict("points" => 16)))
            via_alias(d) = (q = base(); q.values("id", "p" => F("payload")); q.filter("p" => d); q)
            @test length(via_alias(doc).list()) == 1
            @test length(via_alias(other).list()) == 0
            q = base(); q.filter(F("payload") == doc)
            @test q.count() == 1
            q = base(); q.filter(F("payload") == other)
            @test q.count() == 0
            q = base(); q.filter(F("payload") != other)
            @test q.count() == 1
        end

        # #1382: a projection alias over a key lookup holds the key's value, and a filter on it compares as
        # `filter("payload__driver" => …)` does. Before, it ran the JSON formatter: "hamilton" raised
        # InvalidValueError on every engine, a number bound as text matched no row on SQLite, and an
        # ordering compared text. Expected: the seeded row through each spelling, none for another value.
        @testset "an alias over a key lookup compares as the key lookup does (#1382)" begin
            keyed(alias, path, k, v) = (q = base(); q.values("id", alias => F(path)); q.filter(k => v); q)
            @test length(keyed("d", "payload__driver", "d", "hamilton").list()) == 1
            @test length(keyed("d", "payload__driver", "d", "verstappen").list()) == 0
            @test length(keyed("pts", "payload__points", "pts", 15).list()) == 1
            @test length(keyed("pts", "payload__points", "pts__@gte", 9).list()) == 1     # 15 >= 9, as numbers
            @test length(keyed("pts", "payload__points", "pts__@gt", 15).list()) == 0
            @test length(keyed("sp", "payload__sponsor", "sp__@isnull", true).list()) == 1
            # A `When` on the alias (#1381) matches the same row, a number ordered as a number: on
            # PostgreSQL the When arm compared the text '15' with '9', which is false.
            q = base(); q.values("id", "pts" => F("payload__points"))
            q.filter(Case([When("pts__@gte" => 9, then = 1)], default = 0) == 1)
            @test length(q.list()) == 1
        end

        # #954: a NUL in a JSON value is refused before the statement is sent, on both engines.
        # Before, PostgreSQL's jsonb rejected the `\u0000` escape on the server (a StatementError,
        # under LibPQ and Postgres.jl alike) while SQLite stored it — so this is the one place a real
        # server proves the refusal comes first. Every refused write leaves the seeded row alone.
        @testset "a NUL in a JSON value is refused on both engines (#954)" begin
            nul = Dict("driver" => "hamilton\0box")
            @test_throws PormG.InvalidValueError M.Field_validation_scratch.objects.create(
                "uuid_token" => string(UUIDs.uuid4()), "canonical_url" => "https://example.com/json954",
                "slug" => "json954-scratch", "payload" => nul)
            q = base()
            @test_throws PormG.InvalidValueError q.update("payload" => nul)
            @test_throws PormG.InvalidValueError M.Field_validation_scratch.objects.get_or_create("payload" => nul)
            # A JSON string carrying the escape, on the filter path (a plain lookup and get_or_create's).
            nul_text = raw"""{"driver":"hamilton\u0000box"}"""
            @test_throws PormG.InvalidValueError (q = base(); q.filter("payload" => nul_text); q.list())
            @test_throws PormG.InvalidValueError M.Field_validation_scratch.objects.get_or_create("payload" => nul_text)
            # Asked of the table directly: the operator's refusal on a backend without it is asserted
            # in the containment testset below, so this is no skip to record.
            if PormG.Kernel._supports(PormG.config[PORMG_DB_FOLDER].connections, :jsonb_operators)
                # Refused at `filter()` itself: the document is serialized when the filter is parsed.
                q = base()
                @test_throws PormG.InvalidValueError q.filter("payload__@jcontains" => nul)
            end
            # Nothing was written: no new row, and the seeded document is untouched.
            q = M.Field_validation_scratch.objects; q.filter("slug" => "json954-scratch")
            @test q.count() == 0
            q = base(); q.filter("payload__driver" => "hamilton")
            @test q.count() == 1
        end

        # #1483 (was #1471): a JSON key's value has no declared type, so arithmetic on it, and a `Sum`
        # of it, do not say which number they compute on. `points` holds 15. SQLite's `json_extract`
        # handed over the integer and `FLOOR(…) / ?` divided it as one (`7`, #1471); PostgreSQL's `#>>`
        # is text, which `+` and `sum` reject at the server (#1483). Expected: `QueryBuildError` on every
        # engine when the query is built, naming the explicit spelling, and no SQL sent. The explicit
        # spelling, `Cast(key, "numeric") / 2`, is 7.5 on every engine, and its sum is 15.
        @testset "arithmetic and Sum over an uncast JSON key are refused on every engine (#1483)" begin
            plain(e) = replace(sprint(showerror, e), r"\e\[[0-9;]*m" => "")
            for expr in (Floor("payload__points") / 2, F("payload__points") + 1, Sum("payload__points"))
                q = base(); q.values("v" => expr)
                e = try q.list(); nothing catch err; err end
                @test e isa PormG.QueryBuildError
                @test occursin("(#1483)", plain(e))
                @test occursin("Cast(\"payload__points\", \"numeric\")", plain(e))
            end
            q = base(); q.values("v" => Cast("payload__points", "numeric") / 2)
            @test only(q.list())["v"] == 7.5
            q = base(); q.values("v" => Sum(Cast("payload__points", "numeric")))
            @test only(q.list())["v"] == 15
        end

        # #1491: a `Max` or a `Min` over an uncast key orders a value the query does not type. On
        # PostgreSQL `#>>` is text, so over 9 and 10 `Max` was `"9"`; SQLite's `json_extract` orders the
        # numbers and gave 10. Expected: `QueryBuildError` on every engine when the query is built, naming
        # both spellings, and no SQL sent. Each spelling reads back on every engine as what it names:
        # `Cast(key, "numeric")` the number 15, `Cast(key, "text")` the text "15".
        @testset "Max and Min over an uncast JSON key are refused on every engine (#1491)" begin
            plain(e) = replace(sprint(showerror, e), r"\e\[[0-9;]*m" => "")
            for expr in (Max("payload__points"), Min("payload__driver"))
                q = base(); q.values("v" => expr)
                e = try q.list(); nothing catch err; err end
                @test e isa PormG.QueryBuildError
                @test e !== nothing && occursin("(#1491)", plain(e)) && occursin("\"text\")", plain(e))
            end
            q = base(); q.values("v" => Max(Cast("payload__points", "numeric")))
            @test only(q.list())["v"] == 15
            q = base(); q.values("v" => Max(Cast("payload__points", "text")))
            @test only(q.list())["v"] == "15"
            q = base(); q.values("v" => Min(Cast("payload__driver", "text")))
            @test only(q.list())["v"] == "hamilton"
        end

        # #1472: a filter on a CTE column whose body projects a key lookup compares as the key lookup
        # does. Equality on text was refused by the document's JSON formatter, and an ordering bound
        # the number as text, so `points` (15) `> 9` compared `'15' > '9'` on PostgreSQL, false.
        # Expected: the seeded row matches each filter, and a non-matching value matches none.
        @testset "a filter on a CTE column over a JSON key matches as the key lookup does (#1472)" begin
            function cte_filtered(col, filt)
                body = base(); body.values("id", "k" => col)
                q = base(); q.with("g" => body, join_field = "id" => "id", join_type = "INNER")
                q.values("id", "g__k"); q.filter(filt)
                return q
            end
            @test length(cte_filtered("payload__driver", "g__k" => "hamilton").list()) == 1
            @test length(cte_filtered("payload__driver", "g__k" => "norris").list()) == 0
            @test length(cte_filtered("payload__points", "g__k__@gt" => 9).list()) == 1
            @test length(cte_filtered("payload__points", "g__k__@gt" => 20).list()) == 0
        end

        # #1492: a filter on a projection alias over a `Subquery` that projects a key lookup compares as
        # the key lookup does. It bound through the document's JSON formatter, so `points` (15) `> 9`
        # bound the text "9": a text comparison on PostgreSQL ('15' > '9' is false), and never true on
        # SQLite, where a number is never greater than text. Expected: the seeded row matches each
        # filter, and a non-matching value matches none.
        @testset "a filter on a Subquery alias over a JSON key matches as the key lookup does (#1492)" begin
            function sub_filtered(col, filt)
                s = M.Field_validation_scratch.objects
                s.filter("id" => OuterRef("id")); s.values("k" => col)
                q = base(); q.values("id", "w" => Subquery(s)); q.filter(filt)
                return q
            end
            @test length(sub_filtered("payload__points", "w__@gt" => 9).list()) == 1
            @test length(sub_filtered("payload__points", "w__@gt" => 20).list()) == 0
            @test length(sub_filtered("payload__driver", "w" => "hamilton").list()) == 1
            @test length(sub_filtered("payload__driver", "w" => "norris").list()) == 0
            # `@in` binds its values as given, as on an `F` alias over the key: it bound the text "15",
            # which SQLite's number never equals.
            @test length(sub_filtered("payload__points", "w__@in" => [15, 99]).list()) == 1
            @test length(sub_filtered("payload__points", "w__@in" => [16, 99]).list()) == 0
        end

        # ── JSON containment and key operators (`:jsonb_operators`) ──────────
        if requires(:jsonb_operators)
            @testset "containment and key operators" begin
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
            @testset "a backend without JSONB operators refuses them" begin
                q = base(); q.filter("payload__@has_key" => "driver")
                @test_throws PormG.BackendCapabilityError q.count()
            end
        end
    finally
        cleanup = M.Field_validation_scratch.objects
        cleanup.filter("slug" => slug)
        cleanup.exists() && cleanup.delete()
    end
end
