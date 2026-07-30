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
    # The lookup requires the PostgreSQL unaccent extension; on SQLite the dialect raises a
    # clear BackendCapabilityError (#239) rather than silently producing wrong SQL.
    # ─────────────────────────────────────────────────────────────────────────────
    @testset "iunaccent_contains rejected on SQLite" begin
        conn = PormG.config[PORMG_DB_FOLDER].connections
        @test_throws PormG.BackendCapabilityError PormG.Dialect.iunaccent_contains(conn, "surname", "raikkonen")
        @test_throws PormG.BackendCapabilityError PormG.Dialect.iunaccent_exact(conn, "surname", "raikkonen")
    end

else
    @warn "Skipping unaccent extension tests for unknown adapter" adapter = _UNACCENT_ADAPTER
end

# ─────────────────────────────────────────────────────────────────────────────
# icontains is Unicode-case-insensitive on BOTH backends (#78)
# PostgreSQL ILIKE folds Unicode case; SQLite historically used ASCII-only LOWER(),
# so an all-caps accented query ("RÄIKKÖNEN") matched on PG but returned 0 rows on
# SQLite. With the per-connection pormg_lower UDF, SQLite folds Unicode too, so both
# backends return the SAME row for any casing. Runs unconditionally (outside the
# adapter branch above) so the alignment is asserted on whichever backend is under test.
# Mutation gate: reverting the SQLite renderer to bare LOWER makes the all-caps/mixed
# assertions return no rows on SQLite, failing this testset.
# ─────────────────────────────────────────────────────────────────────────────
@testset "icontains Unicode case-insensitivity aligns PG and SQLite (#78)" begin
    # Stored surname is "Räikkönen" (ä/ö). Every casing of the accented spelling must
    # match it — this is the bug: "RÄIKKÖNEN" returned 0 rows on SQLite before the fix.
    for term in ("RÄIKKÖNEN", "räikkönen", "RäiKkönen")  # upper / lower / mixed
        q = M.Driver.objects
        q.filter("surname__@icontains" => term)
        df = q |> DataFrame
        @test "Räikkönen" in df.surname
    end

    # A second accented surname with a different diacritic (ü/Ü) — guards that the fix
    # is general Unicode case folding, not a one-off for ä/ö.
    q_h = M.Driver.objects
    q_h.filter("surname__@icontains" => "HÜLKENBERG")
    df_h = q_h |> DataFrame
    @test "Hülkenberg" in df_h.surname

    # The alignment contract: upper- and lower-case accented queries return the SAME rows.
    up = M.Driver.objects
    up.filter("surname__@icontains" => "RÄIKKÖNEN")
    lo = M.Driver.objects
    lo.filter("surname__@icontains" => "räikkönen")
    @test Set((up |> DataFrame).surname) == Set((lo |> DataFrame).surname)

    # Negative / accent sensitivity: pormg_lower folds CASE, not ACCENTS. The ASCII
    # spelling "raikkonen" must NOT match the accented "Räikkönen" — accent-insensitive
    # matching remains the job of the PG-only iunaccent_* lookups (see ~line 59-64 above).
    q_ascii = M.Driver.objects
    q_ascii.filter("surname__@icontains" => "raikkonen")
    df_ascii = q_ascii |> DataFrame
    @test !("Räikkönen" in (nrow(df_ascii) > 0 ? df_ascii.surname : String[]))
end
