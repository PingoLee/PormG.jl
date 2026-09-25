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
using Logging
using DataFrames
using PormG
# The end-to-end testsets open real (temporary) files, so they need the weakdep extension.
# `runtests.jl` loads it for the whole suite; this guard is what makes the file runnable alone.
isdefined(Main, :SQLite) || include(joinpath(@__DIR__, "..", "load_drivers.jl"))
import PormG: Configuration, Migrations
import PormG.ConnectionPool: fetch, close_pool!, SQLiteConnectionPool
import PormG.Migrations: _split_sqlite_statements

# ─────────────────────────────────────────────────────────────────────────────
# Harness for the end-to-end testsets
# ─────────────────────────────────────────────────────────────────────────────
# They run the whole operator flow: write a models file, `makemigrations`, `migrate`. So the plan
# travels through the plan-file writer and reader (#710) and is applied in the order `migrate` uses —
# buckets first, then tables by binding name — which is the order a rebuild's statements really run in.

# A fresh project folder, SQLite file and settings per testset; `f(pool, settings, models_path)`.
function _rd729_project(f)
    dir = mktempdir()
    pool = nothing
    try
        cd(dir) do
            mkpath("db729")
            pool = SQLiteConnectionPool(joinpath(dir, "rd729.sqlite"); pool_size = 1)
            settings = Configuration.Settings(connections = pool, db_def_folder = "db729")
            settings.change_db = true
            # Absolute: `makemigrations` `include`s it, and a relative include resolves against the
            # including source file, not the working directory.
            f(pool, settings, joinpath(dir, "db729", "models.jl"))
        end
    finally
        pool === nothing || close_pool!(pool)
        rm(dir; recursive = true, force = true)
    end
end

_rd729_models(path, body) = write(path, "module models\nimport PormG.Models\n" * body * "\nend\n")

# `makemigrations`, with `answers` fed to the rename prompts — renames are only ever proposed
# interactively. No answers means `interactive = false`, which never asks and never renames.
function _rd729_plan!(pool, settings, models_path; answers::String = "")
    path, io = mktemp()
    write(io, answers)
    close(io)
    return open(path) do input
        redirect_stdin(input) do
            redirect_stdout(devnull) do
                with_logger(NullLogger()) do
                    Migrations.makemigrations(pool, settings; path = models_path, interactive = !isempty(answers))
                end
            end
        end
    end
end

# `destructive = true`: every SQLite rebuild carries a DROP TABLE.
_rd729_migrate!(pool, settings) =
    with_logger(() -> Migrations.migrate(pool, settings; interactive = false, destructive = true), NullLogger())

_rd729_pending(settings) = joinpath(settings.db_def_folder, "migrations", "pending_migrations.jl")
# The pending plan's SQL, read back the way `migrate` reads it — as data, through `_read_migration_plan`.
_rd729_plan_sql(settings) =
    join((sql for step in Migrations._read_migration_plan(_rd729_pending(settings)) for sql in values(step)), "\n")
_rd729_rows(pool, sql, params = nothing) =
    DataFrame(params === nothing ? fetch(pool, sql) : fetch(pool, sql, params))
_rd729_objects(pool, type) =
    sort(String.(_rd729_rows(pool, "SELECT name FROM sqlite_master WHERE type = ?", [type]).name))
_rd729_definition(pool, name) =
    String(only(_rd729_rows(pool, "SELECT sql FROM sqlite_master WHERE name = ?", [name]).sql))
_rd729_count(pool, relation) = only(_rd729_rows(pool, "SELECT count(*) AS n FROM \"$relation\"").n)
_rd729_columns(pool, table) = String.(_rd729_rows(pool, "SELECT name FROM pragma_table_info(?)", [table]).name)
_rd729_error(f) = try
    f()
    nothing
catch e
    e
end

# The F1 models file the end-to-end testsets start from and vary. `result` is what they rebuild;
# `points` is NOT NULL, so declaring it nullable is the smallest change that forces a rebuild — the
# issue's own repro. `driver = nothing` leaves the Driver model out, so its table is dropped.
function _rd729_schema(; result = "points = Models.IntegerField(), grid = Models.IntegerField(null = true)",
                         driver = "surname = Models.CharField(max_length = 40, null = true)",
                         extra = "")
    lines = String[]
    driver === nothing || push!(lines, "Driver = Models.Model(id = Models.IDField(), $driver)")
    push!(lines, "Result = Models.Model(id = Models.IDField(), $result)")
    push!(lines, "Audit = Models.Model(id = Models.IDField(), n = Models.IntegerField(null = true), " *
                 "note = Models.CharField(max_length = 40, null = true))")
    isempty(extra) || push!(lines, extra)
    return join(lines, "\n")
end
const RD729_NULLABLE = "points = Models.IntegerField(null = true), grid = Models.IntegerField(null = true)"

# The v1 schema, applied: every end-to-end testset starts from a migrated database.
function _rd729_start!(pool, settings, models, schema = _rd729_schema())
    _rd729_models(models, schema)
    _rd729_plan!(pool, settings, models)
    _rd729_migrate!(pool, settings)
end

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

# ─────────────────────────────────────────────────────────────────────────────
# Rebuild: triggers and views survive, and still work (#729's repro)
# A nullability change rebuilds `result`. Before #729 its trigger was dropped without a word and the
# view made the rebuild's RENAME fail. Covered at once: the table's own trigger, a view, a view on
# that view, an INSTEAD OF trigger on the view (DROP VIEW takes it along), and a trigger on ANOTHER
# table whose body names `result` — which fails the RENAME exactly like a view.
# ─────────────────────────────────────────────────────────────────────────────
@testset "a rebuild keeps the table's triggers and the views that read it (#729)" begin
    _rd729_project() do pool, settings, models
        _rd729_start!(pool, settings, models)
        fetch(pool, """CREATE TRIGGER "result_audit" AFTER INSERT ON "result" BEGIN
                         INSERT INTO "audit" ("n", "note") VALUES (NEW."points", 'result');
                       END;""")
        fetch(pool, """CREATE VIEW "result_v" AS SELECT "id", "points" FROM "result";""")
        fetch(pool, """CREATE VIEW "result_top" AS SELECT "id" FROM "result_v" WHERE "points" > 10;""")
        fetch(pool, """CREATE TRIGGER "result_v_ins" INSTEAD OF INSERT ON "result_v" BEGIN
                         INSERT INTO "result" ("id", "points") VALUES (NEW."id", NEW."points");
                       END;""")
        fetch(pool, """CREATE TRIGGER "driver_touch" AFTER UPDATE ON "driver" BEGIN
                         UPDATE "result" SET "grid" = "grid" WHERE "id" = NEW."id";
                       END;""")
        fetch(pool, """INSERT INTO "result" ("id", "points") VALUES (1, 25);""")
        @test _rd729_count(pool, "audit") == 1

        _rd729_models(models, _rd729_schema(result = RD729_NULLABLE))
        _rd729_plan!(pool, settings, models)
        plan = _rd729_plan_sql(settings)
        # The dependents are dropped ahead of the rebuild; everything comes back after it.
        @test occursin("DROP VIEW IF EXISTS \"result_top\";", plan)
        @test occursin("DROP TRIGGER IF EXISTS \"driver_touch\";", plan)
        @test occursin("CREATE TRIGGER \"result_audit\"", plan)
        _rd729_migrate!(pool, settings)

        # The column changed…
        info = _rd729_rows(pool, "SELECT name, \"notnull\" FROM pragma_table_info(?)", ["result"])
        @test only(info[info.name .== "points", :notnull]) == 0
        # …and every object is back.
        @test _rd729_objects(pool, "trigger") == ["driver_touch", "result_audit", "result_v_ins"]
        @test _rd729_objects(pool, "view") == ["result_top", "result_v"]
        # They work, not merely exist: the table trigger fires, the INSTEAD OF trigger routes an insert
        # through the view (firing the table trigger again), and both views read the new table.
        fetch(pool, """INSERT INTO "result" ("id", "points") VALUES (2, NULL);""")
        fetch(pool, """INSERT INTO "result_v" ("id", "points") VALUES (3, 30);""")
        @test _rd729_count(pool, "audit") == 3
        @test _rd729_count(pool, "result_v") == 3
        @test _rd729_count(pool, "result_top") == 2
        # The trigger on `driver` still runs against the rebuilt `result`.
        fetch(pool, """INSERT INTO "driver" ("id", "surname") VALUES (1, 'Senna');""")
        fetch(pool, """UPDATE "driver" SET "surname" = 'Prost' WHERE "id" = 1;""")
        @test _rd729_count(pool, "result") == 3

        # Converged: the next makemigrations has nothing to plan.
        _rd729_plan!(pool, settings, models)
        @test !isfile(_rd729_pending(settings))
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# Rebuild: a trigger that updates its own table
# The commonest trigger there is (`updated_at`-style) names its own table in its body. It must survive
# a plain rebuild, and one that renames an UNRELATED column, verbatim. A TABLE rename leaves the bare
# `UPDATE "result"` stale, which PormG cannot rewrite safely, so that plan is refused.
# ─────────────────────────────────────────────────────────────────────────────
@testset "a self-updating trigger survives, and a table rename is refused (#729)" begin
    touch = """CREATE TRIGGER "result_touch" AFTER UPDATE OF "points" ON "result" BEGIN
                 UPDATE "result" SET "grid" = NEW."points" WHERE "id" = NEW."id";
               END"""
    fields = "points = Models.IntegerField(), grid = Models.IntegerField(null = true), laps = Models.IntegerField(null = true)"
    _rd729_project() do pool, settings, models
        _rd729_start!(pool, settings, models, _rd729_schema(result = fields))
        fetch(pool, touch)
        fetch(pool, """INSERT INTO "result" ("id", "points") VALUES (1, 10);""")

        # `laps` becomes `laps_done` (answer "1": the only column that disappeared) and `points` turns
        # nullable, so the rename rides a rebuild. The trigger never mentions `laps`.
        renamed = replace(fields, "laps =" => "laps_done =", "points = Models.IntegerField()" => "points = Models.IntegerField(null = true)")
        _rd729_models(models, _rd729_schema(result = renamed))
        _rd729_plan!(pool, settings, models; answers = "1\n")
        _rd729_migrate!(pool, settings)
        @test "laps_done" in _rd729_columns(pool, "result")
        # Verbatim — nothing in it needed rewriting — and it still fires.
        @test _rd729_definition(pool, "result_touch") == touch
        fetch(pool, """UPDATE "result" SET "points" = 18 WHERE "id" = 1;""")
        @test only(_rd729_rows(pool, """SELECT "grid" FROM "result" WHERE "id" = 1""").grid) == 18

        # Now rename the TABLE, in a rebuild (`points` back to NOT NULL). The body's bare
        # `UPDATE "result"` would come back naming a table that no longer exists, so makemigrations
        # refuses and says which trigger and why. The answer "1" is the table-rename prompt's.
        moved = replace(_rd729_schema(result = replace(renamed, "points = Models.IntegerField(null = true)" => "points = Models.IntegerField()")),
                        "Result = Models.Model(" => "RaceResult = Models.Model(")
        _rd729_models(models, moved)
        err = _rd729_error(() -> _rd729_plan!(pool, settings, models; answers = "1\n"))
        @test err isa PormG.InvalidMigrationError
        msg = sprint(showerror, err)
        @test occursin("result_touch", msg) && occursin("renames to \"raceresult\"", msg)
        # Nothing was written, so nothing can be applied: the table and its trigger are as they were.
        @test !isfile(_rd729_pending(settings))
        @test _rd729_objects(pool, "trigger") == ["result_touch"]
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# Rebuild + column rename: qualified references follow, anything else is refused
# `RENAME COLUMN` runs before the rebuild and rewrites the live trigger itself, but the rebuild
# re-creates it from the plan-time snapshot. PormG rewrites only the references it can prove are the
# trigger's own table's — `NEW.`, `OLD.`, the table name, the `UPDATE OF` list — and refuses the rest.
# SQLite resolves scope with its parser; a token rewrite that guessed would silently rename a different
# table's column of the same name.
# ─────────────────────────────────────────────────────────────────────────────
@testset "a renamed column is rewritten where it is provably the trigger's own (#729)" begin
    renamed = "race_points = Models.IntegerField(null = true), grid = Models.IntegerField(null = true)"
    _rd729_project() do pool, settings, models
        _rd729_start!(pool, settings, models)
        fetch(pool, """CREATE TRIGGER "result_audit" AFTER UPDATE OF "points" ON "result" BEGIN
                         INSERT INTO "audit" ("n", "note") VALUES (NEW."points", 'points');
                       END;""")

        _rd729_models(models, _rd729_schema(result = renamed))
        _rd729_plan!(pool, settings, models; answers = "1\n")
        _rd729_migrate!(pool, settings)
        definition = _rd729_definition(pool, "result_audit")
        # Both the UPDATE OF list and NEW."points" follow the rename; the string 'points' is not a
        # column and is left alone.
        @test occursin("UPDATE OF \"race_points\"", definition)
        @test occursin("NEW.\"race_points\"", definition)
        @test occursin("'points'", definition)
        fetch(pool, """INSERT INTO "result" ("id", "race_points") VALUES (1, 6);""")
        fetch(pool, """UPDATE "result" SET "race_points" = 8 WHERE "id" = 1;""")
        @test only(_rd729_rows(pool, """SELECT "n" FROM "audit" """).n) == 8
        _rd729_plan!(pool, settings, models)
        @test !isfile(_rd729_pending(settings))
    end

    # An unqualified use — here inside a subquery — cannot be attributed by a token scan: refused. So is
    # a view that names the renamed column. Dropping the object is the way through the message offers.
    for (kind, name, ddl) in (
            ("TRIGGER", "result_sum", """CREATE TRIGGER "result_sum" AFTER INSERT ON "result" BEGIN
                                           UPDATE "audit" SET "n" = (SELECT sum(points) FROM "result");
                                         END;"""),
            ("VIEW", "result_v", """CREATE VIEW "result_v" AS SELECT "id", "points" FROM "result";"""))
        _rd729_project() do pool, settings, models
            _rd729_start!(pool, settings, models)
            fetch(pool, ddl)
            _rd729_models(models, _rd729_schema(result = renamed))
            err = _rd729_error(() -> _rd729_plan!(pool, settings, models; answers = "1\n"))
            @test err isa PormG.InvalidMigrationError
            msg = sprint(showerror, err)
            @test occursin(name, msg) && occursin("\"points\"", msg) && occursin("race_points", msg)
            # The remedy works: drop it, and the same change plans and applies.
            fetch(pool, "DROP $kind \"$name\";")
            _rd729_plan!(pool, settings, models; answers = "1\n")
            _rd729_migrate!(pool, settings)
            @test "race_points" in _rd729_columns(pool, "result")
        end
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# A rebuild registered BEFORE a rename is answered (#556's remaining gap)
# A new NOT NULL datetime column registers the table's rebuild (to drop its temporary default); the
# rename of `points`, declared after it, is answered later and registers nothing of its own. Every
# producer used to render the rebuild as it registered it, so this one rendered with no renames: the
# index on `points` read as "on a dropped column" and was silently not re-created. The rebuild is
# rendered after the whole plan now, with the complete map — and the trigger follows the rename too.
# ─────────────────────────────────────────────────────────────────────────────
@testset "a rebuild registered before a rename renders with that rename (#729, #556)" begin
    _rd729_project() do pool, settings, models
        _rd729_start!(pool, settings, models, _rd729_schema(
            result = "points = Models.IntegerField(db_index = true), grid = Models.IntegerField(null = true)"))
        fetch(pool, """CREATE TRIGGER "result_audit" AFTER INSERT ON "result" BEGIN
                         INSERT INTO "audit" ("n") VALUES (NEW."points");
                       END;""")
        index_sql = "SELECT name, sql FROM sqlite_master WHERE type = 'index' AND tbl_name = 'result' AND sql IS NOT NULL"
        index_before = only(_rd729_rows(pool, index_sql).name)

        # `created_at` is asked about first ("no": it is new), then `race_points` ("1": it was `points`).
        _rd729_models(models, _rd729_schema(result = "created_at = Models.DateTimeField(), " *
            "race_points = Models.IntegerField(db_index = true), grid = Models.IntegerField(null = true)"))
        _rd729_plan!(pool, settings, models; answers = "no\n1\n")
        _rd729_migrate!(pool, settings)

        # The index survived the rebuild, under its own name, on the renamed column.
        index = _rd729_rows(pool, index_sql)
        @test only(index.name) == index_before
        @test occursin("\"race_points\"", only(index.sql))
        @test occursin("NEW.\"race_points\"", _rd729_definition(pool, "result_audit"))
        # Converged — a lost index would be planned again here.
        _rd729_plan!(pool, settings, models)
        @test !isfile(_rd729_pending(settings))
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# Two rebuilt tables sharing a trigger and a view
# `migrate` runs the rebuild blocks in binding-name order, and each block drops and re-creates what
# depends on its table. A trigger ON `race` that also writes `result` belongs to both blocks; `race`
# renames a column, so only the rewritten definition is right — and `result`'s block, which runs
# LAST, must put back that one, not the snapshot.
# ─────────────────────────────────────────────────────────────────────────────
@testset "an object shared by two rebuilt tables comes back from one definition (#729)" begin
    result_v1 = "points = Models.IntegerField(), grid = Models.IntegerField(null = true), race_id = Models.IntegerField(null = true)"
    result_v2 = "points = Models.IntegerField(null = true), grid = Models.IntegerField(null = true), race_id = Models.IntegerField(null = true)"
    _rd729_project() do pool, settings, models
        _rd729_start!(pool, settings, models, _rd729_schema(result = result_v1,
            extra = "Race = Models.Model(id = Models.IDField(), round = Models.IntegerField())"))
        fetch(pool, """CREATE TRIGGER "race_log" AFTER UPDATE OF "round" ON "race" BEGIN
                         UPDATE "result" SET "grid" = NEW."round" WHERE "race_id" = NEW."id";
                       END;""")
        fetch(pool, """CREATE VIEW "race_results" AS SELECT r."id", r."points", ra."id" AS "race"
                       FROM "result" r JOIN "race" ra ON ra."id" = r."race_id";""")
        fetch(pool, """INSERT INTO "race" ("id", "round") VALUES (1, 1);""")
        fetch(pool, """INSERT INTO "result" ("id", "points", "race_id") VALUES (1, 25, 1);""")

        # Both tables rebuild: `result` for nullability, `race` for a rename that also turns nullable.
        _rd729_models(models, _rd729_schema(result = result_v2,
            extra = "Race = Models.Model(id = Models.IDField(), race_round = Models.IntegerField(null = true))"))
        _rd729_plan!(pool, settings, models; answers = "1\n")
        plan = _rd729_plan_sql(settings)
        # Both blocks re-create the trigger, and neither from its pre-rename definition.
        @test count("CREATE TRIGGER \"race_log\"", plan) == 2
        @test !occursin("OF \"round\"", plan)
        _rd729_migrate!(pool, settings)

        @test occursin("NEW.\"race_round\"", _rd729_definition(pool, "race_log"))
        fetch(pool, """UPDATE "race" SET "race_round" = 7 WHERE "id" = 1;""")
        @test only(_rd729_rows(pool, """SELECT "grid" FROM "result" WHERE "id" = 1""").grid) == 7
        @test _rd729_count(pool, "race_results") == 1
        _rd729_plan!(pool, settings, models)
        @test !isfile(_rd729_pending(settings))
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# Refused: a dependent that would name what this migration takes away
# A dropped indexed column (the rebuild is what removes it, #519), a dropped table, and another
# table's renamed column. Each object would be re-created naming something gone, which SQLite accepts
# and then fails every later RENAME on — so makemigrations refuses and writes no plan.
# ─────────────────────────────────────────────────────────────────────────────
@testset "a trigger or view on something the migration removes is refused (#729)" begin
    indexed_grid = "points = Models.IntegerField(), grid = Models.IntegerField(null = true, db_index = true)"
    no_grid = "points = Models.IntegerField()"
    joined = """CREATE VIEW "result_driver" AS SELECT r."id", d."surname" FROM "result" r JOIN "driver" d ON d."id" = r."id";"""
    cases = [
        # (what, v1 schema, hand-made object, v2 schema, prompt answers, words the message must carry)
        ("trigger on a dropped column", _rd729_schema(result = indexed_grid),
         """CREATE TRIGGER "result_grid" AFTER INSERT ON "result" BEGIN INSERT INTO "audit" ("n") VALUES (NEW."grid"); END;""",
         _rd729_schema(result = no_grid), "", ["result_grid", "\"grid\"", "removes"]),
        ("view on a dropped column", _rd729_schema(result = indexed_grid),
         """CREATE VIEW "result_grid_v" AS SELECT "id", "grid" FROM "result";""",
         _rd729_schema(result = no_grid), "", ["result_grid_v", "\"grid\"", "removes"]),
        ("view on a dropped table", _rd729_schema(), joined,
         _rd729_schema(result = RD729_NULLABLE, driver = nothing), "", ["result_driver", "\"driver\"", "drops"]),
        ("view on another table's renamed column", _rd729_schema(), joined,
         _rd729_schema(result = RD729_NULLABLE, driver = "family_name = Models.CharField(max_length = 40, null = true)"),
         "1\n", ["result_driver", "\"surname\"", "family_name"]),
    ]
    for (what, v1, ddl, v2, answers, words) in cases
        @testset "$what" begin
            _rd729_project() do pool, settings, models
                _rd729_start!(pool, settings, models, v1)
                fetch(pool, ddl)
                _rd729_models(models, v2)
                err = _rd729_error(() -> _rd729_plan!(pool, settings, models; answers = answers))
                @test err isa PormG.InvalidMigrationError
                msg = sprint(showerror, err)
                @test all(w -> occursin(w, msg), words)
                # No plan was written, so nothing can be applied by accident.
                @test !isfile(_rd729_pending(settings))
            end
        end
    end
end
