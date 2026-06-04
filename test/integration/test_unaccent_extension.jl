# test/integration/test_unaccent_extension.jl
# Validates the PostgreSQL `unaccent` extension support and the `iunaccent_contains`
# accent-insensitive lookup end to end against a live database.
#
# On PostgreSQL this exercises the real DDL path that PormG.migrate() invokes
# (Configuration._install_configured_extensions!): the `unaccent` extension plus the
# IMMUTABLE `public.immutable_unaccent(text)` helper that backs the lookup. On SQLite
# the lookup is intentionally unsupported and must raise a clear error.

if !isdefined(Main, :PormG)
    include("common_setup.jl")
end

const _UNACCENT_ADAPTER = haskey(PormG.config, PORMG_DB_FOLDER) ?
    PormG.config[PORMG_DB_FOLDER].db_config_settings["adapter"] : "Unknown"

if _UNACCENT_ADAPTER == "PostgreSQL"
    _settings = PormG.Configuration.get_settings(PORMG_DB_FOLDER)

    # ─────────────────────────────────────────────────────────────────────────────
    # Extensions: migrate-time install provisions unaccent + immutable_unaccent
    # Exercises the exact DDL helper migrate() calls. Verifies the extension is present
    # and the IMMUTABLE wrapper strips diacritics, since that wrapper is what every
    # iunaccent_contains query depends on. Must be idempotent across repeated runs.
    # ─────────────────────────────────────────────────────────────────────────────
    @testset "unaccent extension install" begin
        # Declare the extension as the YAML config would, then run the same install the
        # migration runner performs. Idempotent: safe to call even if already installed.
        _settings.db_config_settings["extensions"] = ["unaccent"]
        PormG.Configuration._install_configured_extensions!(_settings)
        PormG.Configuration._install_configured_extensions!(_settings)  # idempotent re-run

        ext = DataFrame(PormG.ConnectionPool.fetch(_settings,
            "SELECT 1 FROM pg_extension WHERE extname = 'unaccent';"))
        @test nrow(ext) == 1

        # The IMMUTABLE wrapper (explicit dictionary form) is what the lookup emits.
        wrapped = DataFrame(PormG.ConnectionPool.fetch(_settings,
            "SELECT public.immutable_unaccent('São José') AS r;"))
        @test wrapped[1, :r] == "Sao Jose"

        # Detection (run by load()) does no DDL and should not warn when installed.
        @test PormG.Configuration._check_configured_extensions!(_settings) === nothing
    end

    # ─────────────────────────────────────────────────────────────────────────────
    # iunaccent_contains: accent-insensitive matching on real F1 driver data
    # "Räikkönen" must be found by the accent-insensitive lookup using the ASCII
    # spelling "raikkonen", while the accent-sensitive icontains must NOT match it.
    # This is the core user-facing contract of the new lookup.
    # ─────────────────────────────────────────────────────────────────────────────
    @testset "iunaccent_contains matches accented data" begin
        q = M.Driver.objects
        q.filter("surname__@iunaccent_contains" => "raikkonen")
        df = q |> DataFrame
        q |> show_query
        @test "Räikkönen" in df.surname

        # Accent-sensitive icontains lowercases but keeps diacritics, so the ASCII
        # query cannot match the accented surname — proving the divergence is real.
        q2 = M.Driver.objects
        q2.filter("surname__@icontains" => "raikkonen")
        df2 = q2 |> DataFrame
        @test !("Räikkönen" in (nrow(df2) > 0 ? df2.surname : String[]))

        # SQL shape sanity: emits the indexable IMMUTABLE wrapper, not bare unaccent.
        rendered = M.Driver.objects.
            filter("surname__@iunaccent_contains" => "raikkonen").
            list(show_query = :dict)
        @test occursin("public.immutable_unaccent", rendered[:sql_text])
        @test occursin("ILIKE", rendered[:sql_text])
    end

    # ─────────────────────────────────────────────────────────────────────────────
    # iunaccent_exact: accent- AND case-insensitive equality on real F1 driver data
    # The accented "Räikkönen" must be matched by the ASCII, differently-cased query
    # "RAIKKONEN", while accent-sensitive exact equality must not. Confirms the lookup
    # is a true equality (no substring/wildcard semantics).
    # ─────────────────────────────────────────────────────────────────────────────
    @testset "iunaccent_exact matches accented data" begin
        q = M.Driver.objects
        q.filter("surname__@iunaccent_exact" => "RAIKKONEN")
        df = q |> DataFrame
        @test "Räikkönen" in df.surname
        # Exact, not substring: a partial value must NOT match.
        q2 = M.Driver.objects
        q2.filter("surname__@iunaccent_exact" => "raikko")
        df2 = q2 |> DataFrame
        @test !("Räikkönen" in (nrow(df2) > 0 ? df2.surname : String[]))

        rendered = M.Driver.objects.
            filter("surname__@iunaccent_exact" => "raikkonen").
            list(show_query = :dict)
        @test occursin("public.immutable_unaccent", rendered[:sql_text])
        @test occursin("LOWER", rendered[:sql_text])
        @test !occursin("ILIKE", rendered[:sql_text])
    end

    # ─────────────────────────────────────────────────────────────────────────────
    # Accent-insensitive set membership via Qor (the documented iunaccent_in workaround)
    # PormG has no dedicated `iunaccent_in`; OR-ing iunaccent_exact lookups is the
    # supported way to match a set of values ignoring accents/case. This guards that
    # recommendation so the docs and reality stay in sync.
    # ─────────────────────────────────────────────────────────────────────────────
    @testset "Qor of iunaccent_exact covers accent-insensitive IN" begin
        q = M.Driver.objects
        q.filter(Qor(
            "surname__@iunaccent_exact" => "raikkonen",
            "surname__@iunaccent_exact" => "hakkinen",
        ))
        df = q |> DataFrame
        @test "Räikkönen" in df.surname   # matched via ASCII "raikkonen"
        @test "Häkkinen" in df.surname    # matched via ASCII "hakkinen"
    end

elseif _UNACCENT_ADAPTER == "SQLite"
    # ─────────────────────────────────────────────────────────────────────────────
    # iunaccent_contains is unsupported on SQLite and must fail loudly
    # The lookup requires the PostgreSQL unaccent extension; on SQLite the dialect
    # raises a clear ArgumentError rather than silently producing wrong SQL.
    # ─────────────────────────────────────────────────────────────────────────────
    @testset "iunaccent_contains rejected on SQLite" begin
        conn = PormG.config[PORMG_DB_FOLDER].connections
        @test_throws ArgumentError PormG.Dialect.iunaccent_contains(conn, "surname", "raikkonen")
        @test_throws ArgumentError PormG.Dialect.iunaccent_exact(conn, "surname", "raikkonen")
    end

else
    @warn "Skipping unaccent extension tests for unknown adapter" adapter = _UNACCENT_ADAPTER
end
