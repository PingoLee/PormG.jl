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
    # This covers: any DROP (every object kind, and ALTER TABLE … DROP [COLUMN] /
    # DROP CONSTRAINT) except the ALTER COLUMN property sub-clauses, TRUNCATE with or
    # without TABLE, and DELETE with no WHERE (#728).
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

    # ─────────────────────────────────────────────────────────────────────────────
    # Destructive guard: statements a hand-edited plan can carry (#728)
    # The generator never writes these; they reach a plan through the manual-SQL
    # recipe in docs/src/migrations/advanced.md, where the guard is the only review.
    # Each one ran without `destructive = true` before #728.
    # ─────────────────────────────────────────────────────────────────────────────
    @testset "Destructive Detection: every DROP, TRUNCATE, unqualified DELETE (#728)" begin
        # Every DROP object kind the guard used to miss — one pattern covers them,
        # so a kind no list would name (DROP POLICY, DROP RULE, …) is caught too.
        for sql in ["DROP VIEW driver_standings_v;",
                    "DROP MATERIALIZED VIEW season_points_mv;",
                    "DROP SCHEMA archive CASCADE;",
                    "DROP FUNCTION immutable_unaccent(text);",
                    "DROP TYPE race_status;",
                    "DROP SEQUENCE results_resultid_seq;",
                    "DROP TRIGGER results_audit ON results;",
                    "DROP EXTENSION unaccent;",
                    "DROP POLICY driver_rows ON drivers;"]
            @test Migrations.is_destructive(sql) == true
        end

        # ALTER TABLE … DROP without the COLUMN keyword: both engines accept it and it
        # drops the column exactly like DROP COLUMN, but the old pattern needed the word.
        @test Migrations.is_destructive("""ALTER TABLE "drivers" DROP "nationality";""") == true
        @test Migrations.is_destructive("ALTER TABLE drivers DROP nationality;") == true

        # TRUNCATE with or without TABLE — PostgreSQL does not require the keyword.
        @test Migrations.is_destructive("TRUNCATE drivers;") == true
        @test Migrations.is_destructive("truncate only results;") == true
        @test Migrations.is_destructive("TRUNCATE results, lap_times RESTART IDENTITY;") == true

        # DELETE with no WHERE: TRUNCATE by another name, and on SQLite (which has no
        # TRUNCATE) the only way to write it — so the two engines are guarded alike.
        @test Migrations.is_destructive("DELETE FROM results;") == true
        @test Migrations.is_destructive("delete from \"results\"") == true        # no `;`
        @test Migrations.is_destructive("DELETE FROM results RETURNING resultid;") == true

        # A multi-statement string (what `mark_applied` classifies) is destructive when
        # ANY statement is — including when the destructive one is not the first.
        @test Migrations.is_destructive("""
            CREATE TABLE "driver_notes" ("id" INTEGER);
            DROP VIEW driver_standings_v;""") == true
        # The WHERE on the first DELETE must not cover the second, unqualified one.
        @test Migrations.is_destructive(
            "DELETE FROM results WHERE raceid = 18; DELETE FROM lap_times;") == true
    end

    # ─────────────────────────────────────────────────────────────────────────────
    # Destructive guard: what it must NOT flag (#728)
    # The widened DROP rule would otherwise catch the ALTER COLUMN sub-clauses the
    # generator emits for ordinary nullability/default/identity changes — and a
    # non-interactive `migrate` would then refuse routine plans.
    # ─────────────────────────────────────────────────────────────────────────────
    @testset "Destructive Detection: property drops, names, and qualified DML (#728)" begin
        # `ALTER [COLUMN] <col> DROP NOT NULL | DEFAULT | IDENTITY | EXPRESSION` removes a
        # property, not data. The first three are emitted by `Dialect.alter_field`.
        for sql in ["""ALTER TABLE "drivers" ALTER COLUMN "code" DROP NOT NULL;""",
                    """ALTER TABLE "drivers" ALTER COLUMN "code" DROP DEFAULT;""",
                    """ALTER TABLE "drivers" ALTER COLUMN "driverid" DROP IDENTITY;""",
                    """ALTER TABLE "drivers" ALTER COLUMN "driverid" DROP IDENTITY IF EXISTS;""",
                    """ALTER TABLE drivers ALTER code DROP EXPRESSION;""",   # COLUMN is optional
                    # A doubled quote inside the identifier (`_quote_table_ddl` emits one) is still
                    # ONE identifier; a `"[^"]*"` anchor would stop at it and miss the exception.
                    """ALTER TABLE "drivers" ALTER COLUMN "a""b" DROP NOT NULL;"""]
            @test Migrations.is_destructive(sql) == false
        end

        # The exception is anchored on the ALTER COLUMN that owns it, not on the word
        # after DROP: this drops a COLUMN named `identity`, so it is still a drop.
        @test Migrations.is_destructive("ALTER TABLE drivers DROP identity;") == true
        # And a property drop does not excuse a column drop in the same statement.
        @test Migrations.is_destructive(
            """ALTER TABLE "drivers" ALTER COLUMN "code" DROP DEFAULT, DROP COLUMN "url";""") == true

        # Identifiers that merely CONTAIN a keyword are not the keyword.
        @test Migrations.is_destructive("""ALTER TABLE "races" ADD COLUMN "drop_zone" TEXT;""") == false
        @test Migrations.is_destructive(
            """CREATE TABLE "truncate_log" ("x_drop" INTEGER, "deleted_at" TEXT);""") == false
        # A foreign key's ON DELETE action is not a DELETE statement.
        @test Migrations.is_destructive(
            """CREATE TABLE "results" ("raceid" INTEGER REFERENCES "races"("raceid") ON DELETE CASCADE);""") == false

        # A DELETE with a WHERE is a targeted data step, not a table wipe.
        @test Migrations.is_destructive("DELETE FROM results WHERE statusid = 31;") == false

        # Decision recorded (#728): UPDATE without WHERE is NOT flagged. It is the
        # ordinary shape of a backfill, and whether it loses data depends on the SET
        # expression — `upper(code)` below loses nothing — which no regex can judge.
        @test Migrations.is_destructive("UPDATE drivers SET code = upper(code);") == false
        # The planner's own backfill (`planner.jl`, SQLite db_default rebuild) stays clean.
        @test Migrations.is_destructive(
            """UPDATE "drivers" SET "code" = 'UNK' WHERE "code" IS NULL;""") == false
    end

    # ─────────────────────────────────────────────────────────────────────────────
    # Destructive guard: the limits of a text heuristic, pinned as decisions (#728)
    # The guard reads SQL text and does not parse it. These assertions record which
    # way it errs on purpose, so a later "fix" in either direction is a visible choice
    # rather than a silent one.
    # ─────────────────────────────────────────────────────────────────────────────
    @testset "Destructive Detection: text-heuristic limits, both directions (#728)" begin
        # Errs toward flagging: a literal that reads like a statement flags the plan. It
        # reaches GENERATED plans too, through `default = "Drop zone"`, and costs an
        # explicit `destructive = true`.
        @test Migrations.is_destructive(
            """ALTER TABLE "drivers" ALTER COLUMN "code" SET DEFAULT 'Drop zone';""") == true
        # Why literals are NOT stripped first: conditional DDL runs its DROP from a string
        # inside a DO block, and stripping would turn this into a silent miss.
        @test Migrations.is_destructive(
            "DO \$\$ BEGIN EXECUTE 'DROP TABLE ' || quote_ident('lap_times'); END \$\$;") == true

        # Known misses in the other direction, for hand-written spellings. The old guard
        # caught none of these either, and each is documented in `is_destructive`, in
        # workflow.md and in the upgrade entry.
        # Any WHERE excuses a DELETE, even one that filters nothing:
        @test Migrations.is_destructive("DELETE FROM results WHERE true;") == false
        # A keyword glued to a quoted name is not seen: every pattern needs whitespace
        # after the keyword, the same as before #728. Catching it with `\bDROP\b` would
        # newly flag generated plans with a quoted column named "drop".
        @test Migrations.is_destructive("""ALTER TABLE drivers DROP"nationality";""") == false
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
    # Supplying neither is refused with an InvalidMigrationError — a made-up digest can never
    # be verified and silently defeats drift detection. _resolve_mark_checksum is the
    # pure, DB-free core of that guardrail, so we can exercise it without a connection.
    # ==============================================================================

    @testset "mark_applied Checksum Guardrail" begin
        # Neither sql_content nor checksum → refuse (do NOT fabricate).
        @test_throws PormG.InvalidMigrationError Migrations._resolve_mark_checksum("", "")

        # The refusal message must point the caller at the fix (supply sql_content).
        err = try
            Migrations._resolve_mark_checksum("", "")
            nothing
        catch e
            e
        end
        @test err isa PormG.InvalidMigrationError
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

    # ─────────────────────────────────────────────────────────────────────────────
    # Removed surface: `migrate_to` and `migrate`'s dead `path` keyword (#732)
    # `migrate_to` could never succeed — the state-based engine has one pending plan, so there is
    # no version to migrate "to" — and it wrote `pormg_migrations` even under `change_db: false`.
    # `migrate(conn, settings; path=…)` accepted a keyword it never read. Both were removed rather
    # than kept as stubs; the two upgrade entries promise `UndefVarError` / `MethodError`, and this
    # pins that the names really are gone so a stub cannot quietly return.
    # ─────────────────────────────────────────────────────────────────────────────
    @testset "Removed: migrate_to and migrate's path keyword (#732)" begin
        # Gone entirely — neither defined nor exported, so `migrate_to(...)` is an UndefVarError.
        @test !isdefined(PormG.Migrations, :migrate_to)
        @test :migrate_to ∉ names(PormG.Migrations)

        # `migrate`'s connection-level method no longer declares `path`, so passing it is a
        # MethodError. Reflection rather than a call: the call would need a real connection and
        # settings, and a MethodError from WRONG positional types would pass without proving anything.
        ms = methods(Migrations.migrate, (PormG.PormGBackend, PormG.PormGSettings))
        @test length(ms) == 1
        kws = Base.kwarg_decl(only(ms))
        @test :path ∉ kws
        # Non-vacuity: the keywords that remain are still read by name.
        @test :destructive in kws && :interactive in kws
    end

end
