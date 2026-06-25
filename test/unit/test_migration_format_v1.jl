# ==============================================================================
# UNIT TESTS: Migration Format Stability (v1 contract — issue #32)
#
# These tests pin the *frozen* migration-format contract: the format-version marker, the checksum
# algorithm, the version-string shape, and the tracking-table DDL (including the `format_version`
# column and the per-backend idempotent upgrade SQL). They run WITHOUT a live database — the
# round-trip backfill behaviour against a real connection lives in
# test/integration/test_migration_bootstrap.jl.
#
# Why pinned digests: a committed v1 migration's checksum must be reproducible byte-for-byte, so we
# assert the SHA-256 of a fixed input equals a hard-coded value. Computing the expected value with
# the same function would be circular and would NOT catch an algorithm change — the literal is the
# guard.
# ==============================================================================

using Test
using PormG
using PormG.Migrations
using OrderedCollections

# Mock connection singletons for the dialect dispatch (defined at module scope — `include` evaluates
# this file into the test module's global scope, where struct definitions are valid).
struct _FmtMockPG <: PormG.PormGPostgres end
struct _FmtMockSL <: PormG.PormGSQLite end

# Pinned SHA-256 digests for the frozen v1 contract (lower-case hex). See the fixture file for the
# exact `known_sql` text; `_manual_checksum` hashes "manual:<version>:<name>".
const _KNOWN_SQL_DIGEST = "bc223d8635ca3a894b770c45065e097b4dd9ded2d83d3d9dd856fa3b12f6bc92"
const _MANUAL_DIGEST    = "ee7ee5c8ede0b94b23ff384d1f9b2e2f9ac9d87c3be23647d032aa5b98cbb393"

@testset "Migration Format Stability (v1)" begin

    # The frozen format-version constant. Bumping it is a deliberate contract change that must ship a
    # forward migration; this guards an accidental edit.
    @testset "Format-version constant" begin
        @test Migrations.MIGRATION_FORMAT_VERSION == 1
    end

    # The checksum algorithm is part of the contract: re-hashing a committed v1 migration's SQL must
    # reproduce its stored digest. Pinning the SHA-256 of fixed inputs catches any change to the hash
    # function or its byte encoding.
    @testset "Checksum algorithm is frozen" begin
        known_sql = "CREATE TABLE drivers (\n  \"driverid\" BIGINT PRIMARY KEY,\n  \"surname\" VARCHAR(255) NOT NULL\n);"
        @test Migrations.compute_checksum(known_sql) == _KNOWN_SQL_DIGEST
        @test length(Migrations.compute_checksum(known_sql)) == 64  # SHA-256 hex

        # Manual fallback used by mark_applied() when no SQL is supplied.
        @test Migrations._manual_checksum("20260101120000000", "freeze_format_v1") == _MANUAL_DIGEST
    end

    # The committed 0.1.0-era fixture must still parse and validate under the current engine.
    @testset "Committed v1 fixture still applies/validates" begin
        fixture_file = joinpath(@__DIR__, "..", "fixtures", "migration_format_v1",
                                "2026-01-01_12-00-00_migration.jl")
        @test isfile(fixture_file)

        text = read(fixture_file, String)

        # 1. The on-disk format marker is present and parses to version 1 (read by line-scan, exactly
        #    as a future engine would detect the format before executing the file).
        m = match(r"(?m)^# pormg-migration-format: (\d+)$", text)
        @test m !== nothing
        @test parse(Int, m.captures[1]) == 1

        # 2. The file still parses as a Julia module exposing its OrderedDict plan (format unchanged).
        mod = include(fixture_file)
        @test isdefined(mod, :drivers)
        plan = getfield(mod, :drivers)
        @test plan isa OrderedDict{String, String}

        # 3. Re-hashing the committed migration's SQL reproduces the pinned v1 checksum — the file
        #    content and the checksum algorithm are jointly stable.
        @test Migrations.compute_checksum(plan["New model"]) == _KNOWN_SQL_DIGEST
    end

    # The generator must EMIT the format marker into newly generated files. The fixture test above
    # only guards a *static* committed file, so without this a refactor of `generate_migration_plan`
    # could silently drop the header and no test would fail.
    @testset "generate_migration_plan emits the format marker" begin
        plan = OrderedDict{Symbol, OrderedDict{String, String}}(
            :drivers => OrderedDict{String, String}(
                "New model" => "CREATE TABLE drivers (\"driverid\" BIGINT PRIMARY KEY);"))

        mktempdir() do dir
            PormG.Generator.generate_migration_plan("emitted_plan.jl", plan, dir)
            text = read(joinpath(dir, "emitted_plan.jl"), String)

            # Header present, parses to the current format version.
            @test occursin("# pormg-migration-format: $(Migrations.MIGRATION_FORMAT_VERSION)", text)
            m = match(r"(?m)^# pormg-migration-format: (\d+)$", text)
            @test m !== nothing
            @test parse(Int, m.captures[1]) == Migrations.MIGRATION_FORMAT_VERSION

            # The marker sits inside the module, on the line right under `module …`, and the plan body
            # was still written. (Parse/apply round-trip of a real v1 file is covered by the committed
            # fixture above; we avoid include() here to dodge the world-age visibility of a freshly
            # included module's bindings inside this closure — the same reason the loader uses
            # Base.invokelatest.)
            @test occursin(r"(?m)^module .*\n# pormg-migration-format:", text)
            @test occursin("drivers = OrderedDict", text)
        end
    end

    # The version string is frozen at 17 chars (yyyymmddHHMMSSsss) — the width of the VARCHAR(17)
    # `version` column.
    @testset "Version-string format is frozen" begin
        v = Migrations.generate_version()
        @test length(v) == 17
        @test occursin(r"^\d{17}$", v)
    end

    # Tracking-table DDL carries `format_version INTEGER NOT NULL DEFAULT 1` on both backends, and the
    # idempotent upgrade DDL differs per backend (PG has ADD COLUMN IF NOT EXISTS; SQLite does not and
    # must be gated by a PRAGMA probe).
    @testset "Tracking-table DDL + upgrade SQL" begin
        pg = _FmtMockPG(); sl = _FmtMockSL()

        for ddl in (PormG.Dialect.create_migrations_table(pg), PormG.Dialect.create_migrations_table(sl))
            @test occursin("\"format_version\"", ddl)
            @test occursin("INTEGER NOT NULL DEFAULT 1", ddl)
        end

        pg_alter = PormG.Dialect.add_format_version_column_sql(pg)
        @test occursin("ADD COLUMN IF NOT EXISTS", pg_alter)
        @test occursin("\"format_version\"", pg_alter)

        sl_alter = PormG.Dialect.add_format_version_column_sql(sl)
        @test occursin("ADD COLUMN", sl_alter)
        @test !occursin("IF NOT EXISTS", sl_alter)  # SQLite lacks it — caller gates via PRAGMA

        # Both backends expose a column probe (a `name` column) so `_ensure_format_version_column`
        # can gate the ALTER and avoid a routine NOTICE on PostgreSQL.
        @test occursin("PRAGMA table_info(pormg_migrations)", PormG.Dialect.migrations_table_info_sql(sl))
        pg_info = PormG.Dialect.migrations_table_info_sql(pg)
        @test occursin("information_schema.columns", pg_info)
        @test occursin("pormg_migrations", pg_info)
    end

    # Insert/select templates round-trip the new column so the runtime history exposes format_version.
    @testset "Insert/select templates carry format_version" begin
        pg = _FmtMockPG(); sl = _FmtMockSL()
        @test occursin("format_version", PormG.Dialect.insert_migration_record_sql(pg))
        @test occursin("format_version", PormG.Dialect.insert_migration_record_sql(sl))
        @test occursin("format_version", PormG.Dialect.select_all_migrations_sql(pg))
        @test occursin("format_version", PormG.Dialect.select_migration_by_version_sql(sl))
    end

end
