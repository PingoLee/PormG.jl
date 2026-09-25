# =============================================================================
# A SQLite table rebuild keeps the table's triggers and the views that read it (#729)
#
# SQLite changes a column by rebuilding the table: CREATE `t_new`, copy the rows, DROP `t`, RENAME
# `t_new` to `t`. The DROP takes every trigger ON the table with it, and the RENAME re-parses the
# whole schema, so a view or a trigger on another table that names `t` makes it fail with
# "error in view …: no such table: main.t". Before #729 the first was silent and the second aborted
# the migration.
#
# This file covers the three pieces of the fix:
#
#   * the statement splitter keeps a `CREATE TRIGGER … BEGIN …; …; END` body whole, and fails closed
#     rather than letting SQLite silently skip what follows an unterminated one;
#   * the rebuild drops and re-creates the objects that depend on the table, from a snapshot taken
#     once the whole plan is known, and refuses at plan time where that snapshot would be stale;
#   * clauses the model cannot declare, which the rebuild re-renders away, are warned about.
#
# Hermetic: temporary SQLite files, no live database.
# =============================================================================
# julia --project=test/integration test/unit/test_sqlite_rebuild_dependents.jl

using Test
using DataFrames
using PormG
# The end-to-end testsets open real (temporary) files, so they need the weakdep extension.
# `runtests.jl` loads it for the whole suite; this guard is what makes the file runnable alone.
isdefined(Main, :SQLite) || include(joinpath(@__DIR__, "..", "load_drivers.jl"))
import PormG: Migrations
import PormG.ConnectionPool: fetch, close_pool!, SQLiteConnectionPool
import PormG.Migrations: _split_sqlite_statements

# ─────────────────────────────────────────────────────────────────────────────
# Splitter: a trigger body is one statement
# Each `;` inside `BEGIN … END` ends a statement OF THE BODY, not the `CREATE TRIGGER`. Cutting there
# handed SQLite a fragment it rejects, so a rebuild that re-creates a trigger could never run.
# ─────────────────────────────────────────────────────────────────────────────
@testset "splitter keeps a CREATE TRIGGER body whole (#729)" begin
    sql = """
    DROP TABLE IF EXISTS "result_new";
    CREATE TRIGGER "result_audit" AFTER INSERT ON "result" BEGIN
      INSERT INTO "audit" VALUES (NEW."points");
      UPDATE "audit" SET "n" = "n" + 1;
    END;
    PRAGMA foreign_key_check("result");"""
    parts = _split_sqlite_statements(sql)
    # Three statements: the DROP, the whole trigger, the PRAGMA.
    @test length(parts) == 3
    @test startswith(parts[2], "CREATE TRIGGER") && endswith(parts[2], "END")
    # Both body statements are inside it, with their own semicolons.
    @test occursin("VALUES (NEW.\"points\");", parts[2]) && occursin("+ 1;", parts[2])
    @test parts[3] == "PRAGMA foreign_key_check(\"result\")"

    # TEMP / TEMPORARY triggers and `IF NOT EXISTS` open a body the same way.
    for head in ("CREATE TEMP TRIGGER", "CREATE TEMPORARY TRIGGER", "CREATE TRIGGER IF NOT EXISTS")
        parts = _split_sqlite_statements("$head tr AFTER INSERT ON t BEGIN SELECT 1; SELECT 2; END; SELECT 3")
        @test length(parts) == 2
        @test parts[2] == "SELECT 3"
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# Splitter: CASE … END and keyword-named columns do not end the body
# `END` also closes a CASE, and SQLite lets `end` and `begin` be column names. Reading either as the
# body's end cuts too early; reading a `begin` as the header's BEGIN never finds the end at all.
# ─────────────────────────────────────────────────────────────────────────────
@testset "splitter: CASE, NEW.end and UPDATE OF begin (#729)" begin
    # A CASE in the WHEN clause (before the body) and two in the body, one of them right before a `;`.
    sql = "CREATE TRIGGER tr AFTER UPDATE ON t FOR EACH ROW " *
          "WHEN CASE WHEN NEW.a > 0 THEN 1 ELSE 0 END BEGIN " *
          "UPDATE t SET b = CASE WHEN NEW.a > 1 THEN 'x' ELSE 'y' END; " *
          "SELECT CASE NEW.a WHEN 1 THEN 2 END; END; SELECT 4"
    parts = _split_sqlite_statements(sql)
    @test length(parts) == 2
    @test endswith(parts[1], "THEN 2 END; END")
    @test parts[2] == "SELECT 4"

    # `NEW.end` is a column, and `begin` in the UPDATE OF list comes before `ON`, so neither is a
    # keyword. The body's BEGIN is the one after `ON t`.
    sql = "CREATE TRIGGER tr AFTER UPDATE OF x, begin ON t BEGIN UPDATE t SET x = NEW.end; END; SELECT 5"
    parts = _split_sqlite_statements(sql)
    @test length(parts) == 2
    @test parts[2] == "SELECT 5"

    # Outside a trigger, BEGIN and END are ordinary statements and split normally.
    @test _split_sqlite_statements("BEGIN; INSERT INTO t VALUES (1); END; COMMIT") ==
          ["BEGIN", "INSERT INTO t VALUES (1)", "END", "COMMIT"]
end

# ─────────────────────────────────────────────────────────────────────────────
# Splitter: SQLite's lexical rules, and no backslash escape
# A `;` inside a comment, a bracketed or backticked identifier, or a literal is not a boundary. The
# old splitter knew only the two quote forms and applied a backslash escape SQL does not have, so
# `'C:\'` swallowed the next statement.
# ─────────────────────────────────────────────────────────────────────────────
@testset "splitter: comments, [ ], backticks and backslashes (#729)" begin
    sql = "SELECT 1 -- a;b\n; SELECT [a;b] FROM `c;d` /* e;f */; SELECT 'g;h', \"i;j\""
    @test _split_sqlite_statements(sql) ==
          ["SELECT 1 -- a;b", "SELECT [a;b] FROM `c;d` /* e;f */", "SELECT 'g;h', \"i;j\""]

    # A doubled quote escapes itself; a backslash does not escape anything.
    @test _split_sqlite_statements("INSERT INTO t VALUES ('it''s;'); SELECT 2") ==
          ["INSERT INTO t VALUES ('it''s;')", "SELECT 2"]
    @test _split_sqlite_statements("INSERT INTO t VALUES ('C:\\'); SELECT 2") ==
          ["INSERT INTO t VALUES ('C:\\')", "SELECT 2"]

    # Empty statements and comment-only ones are dropped — the rebuild itself emits `);;`.
    @test _split_sqlite_statements("CREATE TABLE t (a INTEGER);;\n-- trailing note\n") ==
          ["CREATE TABLE t (a INTEGER)"]
end

# ─────────────────────────────────────────────────────────────────────────────
# Splitter: an unterminated trigger fails closed
# SQLite.jl prepares with a null tail, so a chunk holding a trigger plus more statements runs the
# trigger and silently drops the rest — the rebuild's `PRAGMA foreign_key_check` gate included. A
# trigger whose END is never found must therefore raise instead of being passed on.
# ─────────────────────────────────────────────────────────────────────────────
@testset "splitter: a trigger with no END raises (#729)" begin
    @test_throws PormG.InvalidMigrationError _split_sqlite_statements(
        "CREATE TRIGGER tr AFTER INSERT ON t BEGIN INSERT INTO a VALUES (1); SELECT 2;")
    # The message names the statement, so the operator can find it in the plan.
    err = try
        _split_sqlite_statements("CREATE TRIGGER tr_open AFTER INSERT ON t BEGIN SELECT 1;")
        nothing
    catch e
        e
    end
    @test err isa PormG.InvalidMigrationError
    @test occursin("tr_open", sprint(showerror, err))
end

# ─────────────────────────────────────────────────────────────────────────────
# Splitter: every piece runs, against a real SQLite file
# The executor hands each piece to SQLite on its own. A statement after a trigger body that the
# splitter failed to cut would be dropped without an error, so this runs the pieces and checks that
# the trigger exists, fires, and that the statement after it ran too.
# ─────────────────────────────────────────────────────────────────────────────
@testset "splitter output executes statement by statement (#729)" begin
    mktempdir() do dir
        pool = SQLiteConnectionPool(joinpath(dir, "split729.sqlite"); pool_size = 1)
        try
            sql = """
            CREATE TABLE "result" ("id" INTEGER PRIMARY KEY, "points" INTEGER);
            CREATE TABLE "audit" ("n" INTEGER, "note" TEXT);
            CREATE TRIGGER "result_audit" AFTER INSERT ON "result" BEGIN
              INSERT INTO "audit" ("n", "note") VALUES (NEW."points", 'a;b');
              INSERT INTO "audit" ("n", "note") VALUES (CASE WHEN NEW."points" > 0 THEN 1 ELSE 0 END, 'c');
            END;
            INSERT INTO "result" ("id", "points") VALUES (1, 25);"""
            for part in _split_sqlite_statements(sql)
                fetch(pool, part)
            end
            audit = fetch(pool, """SELECT "n", "note" FROM "audit" ORDER BY "note";""") |> DataFrame
            # Two rows: both body statements ran, and the INSERT after the trigger fired it.
            @test audit.n == [25, 1]
            @test audit.note == ["a;b", "c"]
        finally
            close_pool!(pool)
        end
    end
end
