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
import OrderedCollections: OrderedDict
import PormG.ConnectionPool: fetch, close_pool!, SQLiteConnectionPool
import PormG.Migrations: _split_sqlite_statements, _sqlite_unmodellable_table_clauses

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

    # The body ends at an END that FOLLOWS a `;` — `sqlite3_complete`'s rule. A column called `end`
    # just before a `;` is not it (this cut the body early while CASE was counted instead).
    parts = _split_sqlite_statements("CREATE TRIGGER tr AFTER INSERT ON t BEGIN SELECT a FROM t ORDER BY end; END; SELECT 6")
    @test length(parts) == 2 && endswith(parts[1], "ORDER BY end; END")

    # Found in review: `x·case` is ONE identifier to SQLite, which reads every byte from 0x80 up as part
    # of a name. Read as `x` and `case`, it opened a CASE that never closed, so the first trigger's END
    # was missed and both triggers came out as ONE statement — whose second half SQLite.jl skips silently.
    two = "CREATE TRIGGER a AFTER INSERT ON t BEGIN UPDATE t SET x·case = 1; END; " *
          "CREATE TRIGGER b AFTER INSERT ON t BEGIN SELECT 1; END"
    parts = _split_sqlite_statements(two)
    @test length(parts) == 2
    @test all(p -> startswith(p, "CREATE TRIGGER"), parts)
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
# Rebuild: a trigger and a view with the same name
# Triggers have a namespace of their own, so `result_v` can name both at once. Identified by name,
# finding the trigger marked the view as found too: the view was left in place to fail the rebuild's
# RENAME, and one re-create statement could be handed back for both. Objects are keyed by rowid.
# ─────────────────────────────────────────────────────────────────────────────
@testset "a trigger and a view sharing a name are both carried (#729)" begin
    _rd729_project() do pool, settings, models
        _rd729_start!(pool, settings, models)
        fetch(pool, """CREATE VIEW "result_v" AS SELECT "id", "points" FROM "result";""")
        fetch(pool, """CREATE TRIGGER "result_v" AFTER INSERT ON "result" BEGIN
                         INSERT INTO "audit" ("n") VALUES (NEW."points");
                       END;""")

        _rd729_models(models, _rd729_schema(result = RD729_NULLABLE))
        _rd729_plan!(pool, settings, models)
        _rd729_migrate!(pool, settings)

        # Both are back, each as itself.
        @test _rd729_objects(pool, "view") == ["result_v"]
        @test _rd729_objects(pool, "trigger") == ["result_v"]
        by_type = _rd729_rows(pool, "SELECT type, sql FROM sqlite_master WHERE name = 'result_v' ORDER BY type")
        @test startswith(String(by_type.sql[by_type.type .== "trigger"][1]), "CREATE TRIGGER")
        @test startswith(String(by_type.sql[by_type.type .== "view"][1]), "CREATE VIEW")
        fetch(pool, """INSERT INTO "result" ("id", "points") VALUES (1, 4);""")
        @test _rd729_count(pool, "audit") == 1
        @test _rd729_count(pool, "result_v") == 1
        _rd729_plan!(pool, settings, models)
        @test !isfile(_rd729_pending(settings))
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# Rebuild: definitions ending in a line comment, a trigger on a dropped table, a table rename
# Three paths review found unpinned:
#   * `sqlite_master` keeps a definition's trailing `-- comment`, so a `;` appended on the same line
#     is commented out and the next statement is joined on — for a view and for an index alike;
#   * a trigger ON a table this migration drops names the rebuilt table, but goes with its own table
#     and must not be re-created (it would fail with "no such table");
#   * a table rename in a rebuild re-targets its own triggers' `ON`, which is safe when nothing else in
#     the trigger names the old table.
# ─────────────────────────────────────────────────────────────────────────────
@testset "trailing comments, triggers on dropped tables, and ON after a table rename (#729)" begin
    # Trailing comments. `grid` is indexed in the model, so a second, hand-made index on it with a
    # comment is part of the declared state and the plan leaves it alone.
    indexed = "points = Models.IntegerField(), grid = Models.IntegerField(null = true, db_index = true)"
    _rd729_project() do pool, settings, models
        _rd729_start!(pool, settings, models, _rd729_schema(result = indexed))
        fetch(pool, """CREATE VIEW "podium" AS SELECT "id" FROM "result" WHERE "points" > 15 -- podium only""")
        fetch(pool, """CREATE INDEX "result_grid_note_idx" ON "result" ("grid") -- grid lookups""")
        _rd729_models(models, _rd729_schema(result = replace(indexed, "points = Models.IntegerField()" => "points = Models.IntegerField(null = true)")))
        _rd729_plan!(pool, settings, models)
        _rd729_migrate!(pool, settings)
        @test _rd729_objects(pool, "view") == ["podium"]
        @test "result_grid_note_idx" in _rd729_objects(pool, "index")
        fetch(pool, """INSERT INTO "result" ("id", "points") VALUES (1, 25);""")
        @test _rd729_count(pool, "podium") == 1
    end

    # A trigger on `driver`, which the migration drops, that writes the rebuilt `result`.
    _rd729_project() do pool, settings, models
        _rd729_start!(pool, settings, models)
        fetch(pool, """CREATE TRIGGER "driver_touch" AFTER UPDATE ON "driver" BEGIN
                         UPDATE "result" SET "grid" = "grid" WHERE "id" = NEW."id";
                       END;""")
        _rd729_models(models, _rd729_schema(result = RD729_NULLABLE, driver = nothing))
        _rd729_plan!(pool, settings, models)
        @test !occursin("driver_touch", _rd729_plan_sql(settings))
        _rd729_migrate!(pool, settings)
        @test isempty(_rd729_objects(pool, "trigger"))
        @test !("driver" in _rd729_objects(pool, "table"))
    end

    # A table rename in a rebuild: the trigger's `ON "result"` follows it; its body names no table.
    _rd729_project() do pool, settings, models
        _rd729_start!(pool, settings, models)
        fetch(pool, """CREATE TRIGGER "result_audit" AFTER INSERT ON "result" BEGIN
                         INSERT INTO "audit" ("n") VALUES (NEW."points");
                       END;""")
        _rd729_models(models, replace(_rd729_schema(result = RD729_NULLABLE), "Result = Models.Model(" => "RaceResult = Models.Model("))
        _rd729_plan!(pool, settings, models; answers = "1\n")
        _rd729_migrate!(pool, settings)
        @test occursin("ON \"raceresult\"", _rd729_definition(pool, "result_audit"))
        fetch(pool, """INSERT INTO "raceresult" ("id", "points") VALUES (1, 12);""")
        @test only(_rd729_rows(pool, """SELECT "n" FROM "audit" """).n) == 12
        _rd729_plan!(pool, settings, models)
        @test !isfile(_rd729_pending(settings))
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# The rebuild pass never leaves a step bare
# Every producer of "Alter table:" registers the BARE rebuild, and the pass wraps it. A step with no
# context entry — none exists today, since every producer runs inside `_alter_table_fields` — must
# still be wrapped: a bare rebuild drops the table's indexes and skips the foreign-key gate silently.
# ─────────────────────────────────────────────────────────────────────────────
@testset "a rebuild step with no recorded context is still wrapped (#729)" begin
    mktempdir() do dir
        pool = SQLiteConnectionPool(joinpath(dir, "bare729.sqlite"); pool_size = 1)
        try
            model = PormG.Models.Model("lap_time"; id = PormG.Models.IDField(),
                                       ms = PormG.Models.IntegerField(null = true))
            fetch(pool, """CREATE TABLE "lap_time" ("id" INTEGER PRIMARY KEY AUTOINCREMENT, "ms" INTEGER NOT NULL);""")
            fetch(pool, """CREATE INDEX "lap_time_ms_idx" ON "lap_time" ("ms");""")
            plan = OrderedDict{Symbol, OrderedDict{String, String}}(
                :lap_time => OrderedDict("Alter table: lap_time" => PormG.Dialect.rebuild_table(pool, model)))
            schema = Dict{Symbol, Dict{Symbol, Union{Bool, PormG.PormGModel}}}(
                :lap_time => Dict{Symbol, Union{Bool, PormG.PormGModel}}(:model => model, :exist => true))
            Migrations._finalize_sqlite_rebuilds!(pool, plan, schema, Dict{Symbol, Tuple{Symbol, Dict{String, String}}}())
            step = plan[:lap_time]["Alter table: lap_time"]
            @test occursin("CREATE INDEX \"lap_time_ms_idx\"", step)
            @test endswith(step, "PRAGMA foreign_key_check(\"lap_time\");")
        finally
            close_pool!(pool)
        end
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
        # The other two provable spellings: OLD. (in the WHEN clause) and the table's own name.
        fetch(pool, """CREATE TRIGGER "result_prev" AFTER UPDATE OF "points" ON "result"
                       WHEN OLD."points" IS NOT NULL BEGIN
                         UPDATE "result" SET "grid" = OLD."points"
                         WHERE "result"."id" = NEW."id" AND "result"."points" = NEW."points";
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
        previous = _rd729_definition(pool, "result_prev")
        @test occursin("WHEN OLD.\"race_points\" IS NOT NULL", previous)
        @test occursin("\"result\".\"race_points\" = NEW.\"race_points\"", previous)
        @test !occursin("\"points\"", previous)
        fetch(pool, """INSERT INTO "result" ("id", "race_points") VALUES (1, 6);""")
        fetch(pool, """UPDATE "result" SET "race_points" = 8 WHERE "id" = 1;""")
        @test only(_rd729_rows(pool, """SELECT "n" FROM "audit" """).n) == 8
        # `result_prev` fired too, and copied the OLD value.
        @test only(_rd729_rows(pool, """SELECT "grid" FROM "result" WHERE "id" = 1""").grid) == 6
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
# A dropped indexed column (the rebuild is what removes it, #519), a dropped table, another table's
# renamed column, and a generated column (which only `table_xinfo` lists). Then the shapes review found
# slipping through: a column reached through a `SELECT *` view — from a view on it, from an INSTEAD OF
# trigger on it, from a trigger on another table — and through an alias that shares a live table's name.
# Each object would be re-created naming something gone, which SQLite accepts and then fails every later
# RENAME on (or, with a quoted name, silently reads as a string) — so makemigrations refuses.
# ─────────────────────────────────────────────────────────────────────────────
@testset "a trigger or view on something the migration removes is refused (#729)" begin
    indexed_grid = "points = Models.IntegerField(), grid = Models.IntegerField(null = true, db_index = true)"
    no_grid = "points = Models.IntegerField()"
    joined = """CREATE VIEW "result_driver" AS SELECT r."id", d."surname" FROM "result" r JOIN "driver" d ON d."id" = r."id";"""
    star = """CREATE VIEW "rv" AS SELECT * FROM "result";"""
    cases = [
        ("view reading a dropped column through a SELECT * view", _rd729_schema(result = indexed_grid),
         star * """CREATE VIEW "rv2" AS SELECT "grid" FROM "rv";""",
         _rd729_schema(result = no_grid), "", ["rv2", "\"grid\"", "removes"]),
        ("INSTEAD OF trigger on a SELECT * view using a dropped column", _rd729_schema(result = indexed_grid),
         star * """CREATE TRIGGER "rv_del" INSTEAD OF DELETE ON "rv" BEGIN INSERT INTO "audit" ("n") VALUES (OLD."grid"); END;""",
         _rd729_schema(result = no_grid), "", ["rv_del", "\"grid\"", "removes"]),
        ("trigger on another table reading a dropped column through a view", _rd729_schema(result = indexed_grid),
         star * """CREATE TRIGGER "audit_peek" AFTER INSERT ON "audit" BEGIN UPDATE "audit" SET "n" = (SELECT max("grid") FROM "rv"); END;""",
         _rd729_schema(result = no_grid), "", ["audit_peek", "\"grid\"", "removes"]),
        ("alias sharing another live table's name", _rd729_schema(result = indexed_grid),
         """CREATE VIEW "va" AS SELECT "driver"."grid" FROM "result" AS "driver";""",
         _rd729_schema(result = no_grid), "", ["va", "\"grid\"", "removes"]),
        ("view on a generated column the rebuild drops", _rd729_schema(),
         """ALTER TABLE "result" ADD COLUMN "label" TEXT GENERATED ALWAYS AS ('P' || "points") VIRTUAL;""" *
         """CREATE VIEW "result_label" AS SELECT "id", "label" FROM "result";""",
         _rd729_schema(result = RD729_NULLABLE), "", ["result_label", "\"label\"", "removes"]),
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
                for stmt in _split_sqlite_statements(ddl)
                    fetch(pool, stmt)
                end
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

# ─────────────────────────────────────────────────────────────────────────────
# Clauses the rebuild re-renders away: each shape is recognised
# The rebuild renders the table from its model, so a clause the live CREATE TABLE carries beyond what
# PormG writes is gone afterwards. One table carries every shape; PormG's own `>= 0` CHECK on `points`
# sits among them and must NOT be reported, since the plan carries that one as a column fact.
# ─────────────────────────────────────────────────────────────────────────────
@testset "every clause shape a rebuild drops is reported, and PormG's own are not (#729)" begin
    mktempdir() do dir
        pool = SQLiteConnectionPool(joinpath(dir, "clauses729.sqlite"); pool_size = 1)
        try
            fetch(pool, """CREATE TABLE "result" (
                "id" INTEGER PRIMARY KEY,
                "grid" INTEGER CHECK ("grid" BETWEEN 0 AND 30),
                "points" INTEGER NOT NULL CHECK ("points" >= 0),
                "code" TEXT COLLATE NOCASE,
                "label" TEXT GENERATED ALWAYS AS ('P' || "grid") VIRTUAL,
                "driverid" INTEGER REFERENCES "driver"("id") ON UPDATE CASCADE,
                "raceid" INTEGER REFERENCES "race"("id") DEFERRABLE INITIALLY DEFERRED,
                "a" INTEGER, "b" INTEGER,
                "note" TEXT NOT NULL ON CONFLICT REPLACE DEFAULT '',
                CONSTRAINT "grid_vs_points" CHECK ("grid" <= "points" + 30),
                FOREIGN KEY ("a", "b") REFERENCES "pair"("x", "y")
            ) STRICT;""")
            found = _sqlite_unmodellable_table_clauses(pool, "result")
            @test found == [
                "column CHECK on \"grid\": CHECK (\"grid\" BETWEEN 0 AND 30)",
                "COLLATE: \"code\" TEXT COLLATE NOCASE",
                "generated column: \"label\" TEXT GENERATED ALWAYS AS ('P' || \"grid\") VIRTUAL",
                "foreign-key ON UPDATE / DEFERRABLE / MATCH: \"driverid\" INTEGER REFERENCES \"driver\"(\"id\") ON UPDATE CASCADE",
                "foreign-key ON UPDATE / DEFERRABLE / MATCH: \"raceid\" INTEGER REFERENCES \"race\"(\"id\") DEFERRABLE INITIALLY DEFERRED",
                "ON CONFLICT: \"note\" TEXT NOT NULL ON CONFLICT REPLACE DEFAULT ''",
                "table CHECK: CHECK (\"grid\" <= \"points\" + 30)",
                "composite FOREIGN KEY: FOREIGN KEY (\"a\", \"b\") REFERENCES \"pair\"(\"x\", \"y\")",
                "table option: STRICT",
            ]
            # The table name is resolved as SQLite resolves it, case-insensitively (#57).
            @test _sqlite_unmodellable_table_clauses(pool, "RESULT") == found

            fetch(pool, """CREATE TABLE "lap" ("id" INTEGER PRIMARY KEY, "ms" INTEGER) WITHOUT ROWID;""")
            @test _sqlite_unmodellable_table_clauses(pool, "lap") == ["table option: WITHOUT ROWID"]
            # A keyword-named column is a name, not the keyword: `"collate"` reports nothing.
            fetch(pool, """CREATE TABLE "odd" ("id" INTEGER PRIMARY KEY, "collate" TEXT, "as" INTEGER);""")
            @test isempty(_sqlite_unmodellable_table_clauses(pool, "odd"))
        finally
            close_pool!(pool)
        end
    end

    # A table PormG created — its own CHECKs (non-negative, byte length) and a foreign key — reports
    # nothing, so an ordinary rebuild never warns.
    _rd729_project() do pool, settings, models
        _rd729_start!(pool, settings, models, _rd729_schema(
            result = "points = Models.PositiveIntegerField(), grid = Models.IntegerField(null = true), " *
                     "driverid = Models.ForeignKey(\"Driver\"), photo = Models.BinaryField(max_length = 16, null = true)"))
        definition = String(only(_rd729_rows(pool, "SELECT sql FROM sqlite_master WHERE name = 'result'").sql))
        # The shapes really are there, so "nothing reported" is not vacuous.
        @test occursin(">= 0)", definition) && occursin("length(", definition) && occursin("REFERENCES", definition)
        @test isempty(_sqlite_unmodellable_table_clauses(pool, "result"))
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# Clauses the rebuild re-renders away: one warning, from makemigrations
# A hand-added column CHECK the model cannot declare: the rebuild drops it, and makemigrations says so
# ONCE, naming the table and quoting the clause — then the migration really does drop it.
# ─────────────────────────────────────────────────────────────────────────────
@testset "makemigrations warns once about a clause the rebuild drops (#729)" begin
    with_lap = "points = Models.IntegerField(), grid = Models.IntegerField(null = true), fastest_lap = Models.IntegerField(null = true)"
    _rd729_project() do pool, settings, models
        _rd729_start!(pool, settings, models, _rd729_schema(result = replace(with_lap, ", fastest_lap = Models.IntegerField(null = true)" => "")))
        # Added by hand, with a CHECK no field declaration expresses; declared plainly in the model, so
        # this column itself converges and only the nullability change below plans anything.
        fetch(pool, """ALTER TABLE "result" ADD COLUMN "fastest_lap" INTEGER NULL CHECK ("fastest_lap" > 0);""")
        _rd729_models(models, _rd729_schema(result = with_lap))
        _rd729_plan!(pool, settings, models)
        @test !isfile(_rd729_pending(settings))

        _rd729_models(models, _rd729_schema(result = replace(with_lap, "points = Models.IntegerField()" => "points = Models.IntegerField(null = true)")))
        records, _ = Test.collect_test_logs() do
            redirect_stdout(devnull) do
                Migrations.makemigrations(pool, settings; path = models, interactive = false)
            end
        end
        warns = [r for r in records if r.level == Logging.Warn && haskey(r.kwargs, :clauses)]
        @test length(warns) == 1
        @test warns[1].kwargs[:table] == "result"
        @test warns[1].kwargs[:clauses] == ["column CHECK on \"fastest_lap\": CHECK (\"fastest_lap\" > 0)"]

        # The warning is true: after the rebuild the CHECK is gone and a value it refused goes in.
        _rd729_migrate!(pool, settings)
        fetch(pool, """INSERT INTO "result" ("id", "points", "fastest_lap") VALUES (1, 0, -1);""")
        @test only(_rd729_rows(pool, """SELECT "fastest_lap" FROM "result" """).fastest_lap) == -1
    end
end
