# ==============================================================================
# UNIT TESTS: Migration Runner
# Tests for migration history, checksum, versioning, destructive detection,
# dry-run behavior, status reporting, and repair flows.
#
# These tests validate the runner logic WITHOUT requiring a live database.
# They use mock connections and in-memory SQLite for history table operations.
# ==============================================================================

using Test
using PormG
using PormG.Models
using PormG.Migrations
using OrderedCollections
using Dates

# ==============================================================================
# SECTION 1: Checksum and Version Generation
#
# These are pure functions with no DB dependency. They ensure:
# - Deterministic checksum for identical SQL content
# - Different checksums for different content
# - Version strings follow the expected timestamp format
# ==============================================================================

@testset "Migration Runner Unit Tests" begin

    @testset "Checksum Generation" begin
        # Same input always produces the same SHA-256 hash.
        # This is critical for integrity verification: if a migration file
        # is modified after being applied, the checksum mismatch signals drift.
        sql1 = "CREATE TABLE test (id INTEGER PRIMARY KEY);"
        checksum1 = Migrations.compute_checksum(sql1)
        checksum2 = Migrations.compute_checksum(sql1)
        @test checksum1 == checksum2
        @test length(checksum1) == 64  # SHA-256 hex = 64 chars

        # Different SQL must produce different checksums.
        sql2 = "CREATE TABLE test2 (id INTEGER PRIMARY KEY);"
        checksum3 = Migrations.compute_checksum(sql2)
        @test checksum1 != checksum3

        # Empty string should still produce a valid checksum (edge case).
        checksum_empty = Migrations.compute_checksum("")
        @test length(checksum_empty) == 64
        @test checksum_empty != checksum1
    end

    @testset "Version Generation" begin
        # Versions are timestamp-based: YYYYMMDDHHmmssSSS (17 digits).
        # This ensures natural ordering by creation time and avoids sub-second collisions.
        version = Migrations.generate_version()
        @test length(version) == 17
        @test all(isdigit, version)

        # Two versions generated in sequence should differ (unless sub-second).
        # We test format only since the exact value depends on wall-clock time.
        @test tryparse(Int, version) !== nothing
    end

    # ==============================================================================
    # SECTION 2: Destructive Operation Detection
    #
    # The destructive guard is a safety mechanism that prevents accidental
    # data loss by requiring explicit opt-in for DROP operations.
    # This covers: DROP TABLE, DROP COLUMN, DROP INDEX, TRUNCATE TABLE.
    # ==============================================================================

    @testset "Destructive Detection" begin
        # DROP TABLE should be detected regardless of case
        @test Migrations.is_destructive("DROP TABLE users;") == true
        @test Migrations.is_destructive("drop table users;") == true
        @test Migrations.is_destructive("Drop   Table users;") == true

        # DROP COLUMN (ALTER TABLE ... DROP COLUMN) should be detected
        @test Migrations.is_destructive("""ALTER TABLE "users" DROP COLUMN "age";""") == true

        # DROP INDEX
        @test Migrations.is_destructive("""DROP INDEX IF EXISTS "idx_name";""") == true

        # DROP CONSTRAINT
        @test Migrations.is_destructive("""ALTER TABLE "users" DROP CONSTRAINT "fk_name";""") == true

        # TRUNCATE TABLE
        @test Migrations.is_destructive("TRUNCATE TABLE results;") == true

        # Safe operations should NOT be flagged
        @test Migrations.is_destructive("CREATE TABLE test (id INTEGER);") == false
        @test Migrations.is_destructive("""ALTER TABLE "test" ADD COLUMN "name" VARCHAR(100);""") == false
        @test Migrations.is_destructive("""ALTER TABLE "test" ALTER COLUMN "name" TYPE TEXT;""") == false
        @test Migrations.is_destructive("""CREATE INDEX "idx_name" ON "test" ("name");""") == false

        # detect_destructive_actions filters a list of statements
        stmts = [
            "CREATE TABLE test (id INTEGER);",
            """DROP TABLE "old_table" CASCADE;""",
            """ALTER TABLE "test" ADD COLUMN "name" TEXT;""",
            """ALTER TABLE "test" DROP COLUMN "age";""",
        ]
        destructive = Migrations.detect_destructive_actions(stmts)
        @test length(destructive) == 2
        @test any(s -> occursin("DROP TABLE", s), destructive)
        @test any(s -> occursin("DROP COLUMN", s), destructive)
    end

    # ==============================================================================
    # SECTION 2b: Non-interactive confirmation gate (#87)
    #
    # `_confirm_migration` is the DB-free core of the migrate() safety gate. It must:
    #   - NEVER block on readline() without a real terminal, even when interactive=true;
    #   - THROW DestructiveMigrationError for a destructive plan in a non-interactive
    #     context (so CI/deploy scripts fail loudly instead of hanging or silently
    #     skipping) unless destructive=true is passed;
    #   - return `true` (proceed) for a safe plan, or a destructive plan opted-in.
    #
    # Every call is wrapped in `redirect_stdin(devnull)` so `stdin isa Base.TTY` is
    # deterministically `false` regardless of how the suite is launched (a dev running
    # `Pkg.test` from a terminal would otherwise have a real TTY and hit the prompt).
    # ==============================================================================

    @testset "Non-interactive confirmation gate (#87)" begin
        drop = ["""DROP TABLE "drivers" CASCADE;"""]

        redirect_stdin(devnull) do
            # A destructive plan with NO opt-in must throw — even with interactive=true,
            # because there is no TTY to prompt on (this is the anti-hang guarantee).
            @test_throws Migrations.DestructiveMigrationError Migrations._confirm_migration(
                true, false, drop; interactive=true)

            # Same with the explicit non-interactive flag.
            @test_throws Migrations.DestructiveMigrationError Migrations._confirm_migration(
                true, false, drop; interactive=false)

            # Opting in with destructive=true proceeds (returns true), no prompt.
            @test Migrations._confirm_migration(true, true, drop; interactive=true) == true

            # A non-destructive plan proceeds directly in a non-interactive context —
            # previously this path read EOF and silently no-op'd.
            @test Migrations._confirm_migration(false, false, String[]; interactive=true) == true
            @test Migrations._confirm_migration(false, false, String[]; interactive=false) == true
        end

        # The thrown error is actionable: it names the count, carries the offending
        # statements, and renders them via showerror.
        err = try
            redirect_stdin(devnull) do
                Migrations._confirm_migration(true, false, drop; interactive=false)
            end
        catch e
            e
        end
        @test err isa Migrations.DestructiveMigrationError
        @test occursin("destructive operation", err.msg)
        @test occursin("destructive=true", err.msg)
        @test err.statements == drop
        buf = IOBuffer()
        showerror(buf, err)
        rendered = String(take!(buf))
        @test occursin("DestructiveMigrationError", rendered)
        @test occursin("DROP TABLE", rendered)

        # showerror truncates a long statement safely, even across a multibyte UTF-8 boundary
        # (regression guard: byte-slicing `s[1:120]` throws StringIndexError when byte 120 lands
        # mid-character; `first(s, 120)` is character-safe).
        long_unicode = "DROP TABLE " * ("π"^200) * ";"   # >120 chars, multibyte
        long_err = Migrations.DestructiveMigrationError("boom", [long_unicode])
        buf2 = IOBuffer()
        showerror(buf2, long_err)                        # must not throw
        @test occursin("...", String(take!(buf2)))       # and it truncated
    end

    # ==============================================================================
    # SECTION 3: Statement Ordering
    #
    # Migration statements are ordered for safety:
    # 1. CREATE TABLE (new models) — must exist before FKs reference them
    # 2. DROP TABLE — remove tables that are no longer in the models
    # 3. RENAME FIELD — rename before altering to avoid referencing old names
    # 4. Everything else — ALTER, ADD COLUMN, indexes, constraints
    # ==============================================================================

    @testset "Statement Ordering" begin
        # Build a mock migration plan as the runner would receive it
        plan = [
            OrderedDict{String,String}(
                "Alter field: age" => """ALTER TABLE "drivers" ALTER COLUMN "age" TYPE INTEGER;""",
                "New model" => """CREATE TABLE IF NOT EXISTS "circuits" (id INTEGER PRIMARY KEY);""",
            ),
            OrderedDict{String,String}(
                "Drop table" => """DROP TABLE IF EXISTS "old_table" CASCADE;""",
                "Rename field: code" => """ALTER TABLE "drivers" RENAME COLUMN "old_code" TO "code";""",
            ),
        ]

        ordered, all_sql = Migrations._order_statements(plan)

        # First should be CREATE TABLE (New model)
        @test occursin("CREATE TABLE", ordered[1])
        # Second should be DROP TABLE
        @test occursin("DROP TABLE", ordered[2])
        # Third should be RENAME
        @test occursin("RENAME COLUMN", ordered[3])
        # Last should be the ALTER
        @test occursin("ALTER COLUMN", ordered[4])

        # all_sql should contain all statements joined
        @test occursin("CREATE TABLE", all_sql)
        @test occursin("DROP TABLE", all_sql)
        @test occursin("RENAME COLUMN", all_sql)
        @test occursin("ALTER COLUMN", all_sql)
    end

    @testset "Statement Ordering: CREATE INDEX after rebuild (#152)" begin
        # #152: a newly-added db_index field queues its "Create index on X" BEFORE the same-table rebuild
        # ("Alter table: t") in insertion order. On SQLite the rebuild DROP TABLEs the table (dropping every
        # secondary index) and only re-creates the planning-time live-snapshot indexes — which exclude the
        # just-queued one — so a fresh index is silently lost. _order_statements must defer every field
        # CREATE INDEX to run AFTER the rebuild (and keep the ADD COLUMN before it, so the rebuild's
        # INSERT..SELECT can still copy the new column).
        plan = [
            OrderedDict{String,String}(
                "Add field: flag"      => """ALTER TABLE "t" ADD COLUMN "flag" INTEGER;""",
                "Create index on flag" => """CREATE INDEX IF NOT EXISTS "t_flag_ab12cd34_idx" ON "t" ("flag");""",
                "Alter table: t"       => """DROP TABLE IF EXISTS "t_new";\nCREATE TABLE "t_new" (...);\nINSERT INTO "t_new" SELECT * FROM "t";\nDROP TABLE "t";\nALTER TABLE "t_new" RENAME TO "t";""",
            ),
        ]

        ordered, _ = Migrations._order_statements(plan)

        add_pos     = findfirst(s -> occursin("ADD COLUMN", s), ordered)
        rebuild_pos = findfirst(s -> occursin("RENAME TO", s), ordered)   # last step of the rebuild block
        index_pos   = findfirst(s -> occursin("CREATE INDEX", s), ordered)

        @test add_pos !== nothing && rebuild_pos !== nothing && index_pos !== nothing
        # ADD COLUMN stays BEFORE the rebuild (so the rebuild's INSERT..SELECT finds the new column).
        @test add_pos < rebuild_pos
        # The #152 fix: CREATE INDEX runs AFTER the rebuild — otherwise the rebuild's DROP TABLE loses it.
        # Mutation gate: without the index_execution bucket, index_pos (2) < rebuild_pos (3) and this fails.
        @test index_pos > rebuild_pos

        # A "Remove index …" key must NOT be swept into the deferred bucket (different prefix); it stays in
        # its normal (last_execution) position, and a "Create many-to-many unique index" is likewise not a
        # field index — neither should collide with the "Create index on <field>" match.
        plan2 = [
            OrderedDict{String,String}(
                "Remove index on old" => """DROP INDEX IF EXISTS "t_old_idx";""",
                "Alter table: t"      => """ALTER TABLE "t_new" RENAME TO "t";""",
                "Create index on new" => """CREATE INDEX IF NOT EXISTS "t_new_zz_idx" ON "t" ("new");""",
            ),
        ]
        ordered2, _ = Migrations._order_statements(plan2)
        remove_pos  = findfirst(s -> occursin("DROP INDEX", s), ordered2)
        rebuild2    = findfirst(s -> occursin("RENAME TO", s), ordered2)
        create2     = findfirst(s -> occursin("CREATE INDEX", s), ordered2)
        @test remove_pos < rebuild2          # DROP INDEX not deferred — runs before the rebuild
        @test create2 > rebuild2             # CREATE INDEX deferred past the rebuild
    end

    # ==============================================================================
    # SECTION 4: History Table DDL Generation
    #
    # The pormg_migrations table DDL must be correct for both PostgreSQL and SQLite.
    # These tests validate the generated SQL contains the expected columns and types.
    # ==============================================================================

    @testset "History Table DDL" begin
        # Mock connections for dispatch
        struct MockPG <: PormG.PormGPostgres end
        struct MockSL <: PormG.PormGSQLite end

        pg_ddl = PormG.Dialect.create_migrations_table(MockPG())
        sl_ddl = PormG.Dialect.create_migrations_table(MockSL())

        # Both should create the pormg_migrations table
        @test occursin("pormg_migrations", pg_ddl)
        @test occursin("pormg_migrations", sl_ddl)

        # Both should have the required columns
        for ddl in [pg_ddl, sl_ddl]
            @test occursin("\"version\"", ddl)
            @test occursin("\"name\"", ddl)
            @test occursin("\"checksum\"", ddl)
            @test occursin("\"sql_content\"", ddl)
            @test occursin("\"applied_at\"", ddl)
            @test occursin("\"status\"", ddl)
            @test occursin("\"is_destructive\"", ddl)
            # format_version pins the frozen migration-format contract (issue #32); every
            # freshly-created tracking table carries it with a DEFAULT of 1.
            @test occursin("\"format_version\"", ddl)
            @test occursin("INTEGER NOT NULL DEFAULT 1", ddl)
        end

        # PostgreSQL should use SERIAL and TIMESTAMP
        @test occursin("SERIAL", pg_ddl)
        @test occursin("TIMESTAMP", pg_ddl)
        @test occursin("VARCHAR(17)", pg_ddl)

        # SQLite should use AUTOINCREMENT and DATETIME
        @test occursin("AUTOINCREMENT", sl_ddl)
        @test occursin("DATETIME", sl_ddl)
        @test occursin("VARCHAR(17)", sl_ddl)
    end

    # ==============================================================================
    # SECTION 5: Migration Status Structure
    #
    # Validate that MigrationStatus correctly represents different states:
    # - Empty (no history table)
    # - Applied migrations exist
    # - Failed migrations present
    # - Pending file detected
    # ==============================================================================

    @testset "MigrationStatus Structure" begin
        # Empty state — no history table
        s = Migrations.MigrationStatus(
            NamedTuple[],
            NamedTuple[],
            false,
            false,
            ["History table pormg_migrations does not exist."]
        )
        @test s.has_history_table == false
        @test length(s.applied) == 0
        @test length(s.failed) == 0
        @test s.pending == false
        @test !isempty(s.drift_signals)

        # With applied migrations
        mock_applied = [(version="20260310120000", name="test", checksum="abc123",
                         sql_content="", applied_at="2026-03-10", status="applied", 
                         is_destructive=false)]
        s2 = Migrations.MigrationStatus(
            mock_applied,
            NamedTuple[],
            false,
            true,
            String[]
        )
        @test s2.has_history_table == true
        @test length(s2.applied) == 1
        @test s2.pending == false

        # With failed migrations — should trigger drift signal
        mock_failed = [(version="20260310130000", name="bad_migration", checksum="def456",
                        sql_content="", applied_at="2026-03-10", status="failed",
                        is_destructive=true)]
        s3 = Migrations.MigrationStatus(
            mock_applied,
            mock_failed,
            true,  # pending file also exists
            true,
            ["Pending migrations file exists alongside applied history"]
        )
        @test length(s3.failed) == 1
        @test s3.pending == true
    end

    # ==============================================================================
    # SECTION 6: DryRunResult Structure
    #
    # Validate that DryRunResult accurately reports migration analysis
    # without requiring actual database execution.
    # ==============================================================================

    @testset "DryRunResult Structure" begin
        stmts = [
            """CREATE TABLE IF NOT EXISTS "test" ("id" INTEGER PRIMARY KEY);""",
            """ALTER TABLE "test" ADD COLUMN "name" VARCHAR(100);""",
        ]
        
        result = Migrations.DryRunResult(
            Migrations.compute_checksum(join(stmts, "\n")),
            stmts,
            String[]  # no destructive statements
        )
        @test Migrations.is_destructive(result) == false
        @test Migrations.total_statements(result) == 2
        @test length(result.destructive_statements) == 0
        @test length(result.checksum) == 64

        # With destructive operations
        stmts_destr = [
            """DROP TABLE "old_table" CASCADE;""",
            """CREATE TABLE "new_table" ("id" INTEGER PRIMARY KEY);""",
        ]
        destr_stmts = Migrations.detect_destructive_actions(stmts_destr)
        result2 = Migrations.DryRunResult(
            Migrations.compute_checksum(join(stmts_destr, "\n")),
            stmts_destr,
            destr_stmts
        )
        @test Migrations.is_destructive(result2) == true
        @test length(result2.destructive_statements) == 1
    end

    @testset "Manual Checksum Generation" begin
        checksum = Migrations._manual_checksum("20260311112233444", "manual_fix")
        @test length(checksum) == 64
        @test all(c -> isdigit(c) || c in ['a','b','c','d','e','f'], checksum)
    end

    # ==============================================================================
    # SECTION 6b: mark_applied checksum guardrail (#81)
    #
    # mark_applied must never fabricate a checksum. A manually-reconciled migration
    # has to carry a *verifiable* digest, so the caller must supply either the real
    # `sql_content` (from which the checksum is computed) or an explicit `checksum`.
    # Supplying neither is refused with an ArgumentError — a made-up digest can never
    # be verified and silently defeats drift detection. _resolve_mark_checksum is the
    # pure, DB-free core of that guardrail, so we can exercise it without a connection.
    # ==============================================================================

    @testset "mark_applied Checksum Guardrail" begin
        # Neither sql_content nor checksum → refuse (do NOT fabricate).
        @test_throws ArgumentError Migrations._resolve_mark_checksum("", "")

        # The refusal message must point the caller at the fix (supply sql_content).
        err = try
            Migrations._resolve_mark_checksum("", "")
            nothing
        catch e
            e
        end
        @test err isa ArgumentError
        @test occursin("sql_content", err.msg)

        # sql_content supplied, no explicit checksum → checksum is COMPUTED from the SQL
        # and equals compute_checksum of the same content (verifiable, not fabricated).
        sql = """ALTER TABLE "drivers" ADD COLUMN "points" INTEGER;"""
        resolved = Migrations._resolve_mark_checksum("", sql)
        @test resolved == Migrations.compute_checksum(sql)
        @test length(resolved) == 64

        # Explicit checksum supplied → trusted and returned unchanged, even with no SQL.
        @test Migrations._resolve_mark_checksum("deadbeef", "") == "deadbeef"

        # When both are supplied the explicit checksum wins (caller's stated intent).
        @test Migrations._resolve_mark_checksum("deadbeef", sql) == "deadbeef"
    end

    @testset "SQLite Statement Splitting" begin
        statements = Migrations._split_sqlite_statements("INSERT INTO test VALUES ('alpha;beta'); UPDATE test SET name = \"gamma;delta\";")
        @test length(statements) == 2
        @test occursin("'alpha;beta'", statements[1])
        @test occursin("\"gamma;delta\"", statements[2])
    end

    # ==============================================================================
    # SECTION 7: Dialect SQL Generation for History Operations
    #
    # Validate that the parameterized SQL templates for migration history
    # are syntactically correct for each dialect.
    # ==============================================================================

    @testset "History SQL Templates" begin
        struct MockPG2 <: PormG.PormGPostgres end
        struct MockSL2 <: PormG.PormGSQLite end

        pg = MockPG2()
        sl = MockSL2()

        # INSERT templates should use correct parameter style
        pg_insert = PormG.Dialect.insert_migration_record_sql(pg)
        @test occursin("\$1", pg_insert)  # PostgreSQL uses $1, $2, ...
        @test occursin("pormg_migrations", pg_insert)

        sl_insert = PormG.Dialect.insert_migration_record_sql(sl)
        @test occursin("?", sl_insert)  # SQLite uses ?
        @test occursin("pormg_migrations", sl_insert)

        # UPDATE templates
        pg_update = PormG.Dialect.update_migration_status_sql(pg)
        @test occursin("\$1", pg_update)
        @test occursin("status", pg_update)

        sl_update = PormG.Dialect.update_migration_status_sql(sl)
        @test occursin("?", sl_update)

        # SELECT templates
        pg_select = PormG.Dialect.select_all_migrations_sql(pg)
        @test occursin("ORDER BY", pg_select)

        # EXISTS check
        pg_exists = PormG.Dialect.migrations_table_exists_sql(pg)
        @test occursin("information_schema", pg_exists)

        sl_exists = PormG.Dialect.migrations_table_exists_sql(sl)
        @test occursin("sqlite_master", sl_exists)
    end

end
