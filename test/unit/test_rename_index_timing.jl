# =============================================================================
# Rename index timing: plan a db_index flip in the same migration, and share one rename map (#556)
#
# #522 (phase 3 of #507) left two index-timing gaps around a column rename. They read as two
# problems and are one: two per-table accumulators lived at the wrong scope.
#
#   GAP 1 — a rename that ALSO flips `db_index` planned no index action. `index_actions` was
#           declared in `_alter_table_fields` AFTER its call to `_resolve_table_fields`, so the
#           rename branch had no sink to record into. It self-healed one `makemigrations` later.
#
#   GAP 2 — on SQLite a rename co-occurring with an ordinary column alteration, or with a new
#           column, produces ONE shared rebuild under the key "Alter table: <model>". The surviving
#           entry is whichever registration lands last, and it rendered with only the
#           `column_renames` its own call was given — so when the alteration loop or
#           `_add_new_field` won, the renamed column's secondary index was not re-created.
#
# Both are fixed by hoisting `index_actions` and `sqlite_rename_map` into `_alter_table_fields` and
# threading them through. These tests are the oracle for that: every SQLite case APPLIES the plan to
# a real temporary database and reads the indexes back with `PRAGMA`, because neither gap is visible
# in the plan text alone — gap 2 in particular is a rebuild that is perfectly correct except for the
# index DDL appended to it.
#
# The companion guard lives in `test_rename_unique_index.jl`: a rename with `db_index` UNCHANGED
# must still plan nothing in either direction, so that the index keeps following its column instead
# of being dropped and re-created under a fresh hashed name on every rename.
# =============================================================================

using Test
using DataFrames
using PormG
using PormG.Models
using PormG.Migrations
import PormG: PormGModel, PormGPostgres, PormGSQLite
isdefined(Main, :SQLite) || include(joinpath(@__DIR__, "..", "load_drivers.jl"))
import PormG.ConnectionPool: SQLiteConnectionPool, fetch, close_pool!
import PormG.Migrations: get_constraints_index

# Suffixed names: `runtests.jl` includes every unit file into ONE module.
struct RenameIdxMockPg556 <: PormGPostgres end
const RIT_PG = RenameIdxMockPg556()
# Catch-all empty frame = "no live index / no live constraint", which keeps these plans to the story
# under test; without it `_drop_index` raises a MethodError.
fetch(::RenameIdxMockPg556, sql::String; conn = nothing, params = nothing, ignore_tx::Bool = false) =
    DataFrame()

# Same argument order as the planner: LIVE models first, DECLARED ones in `current_schema`.
# `answers` is fed on stdin — one line per interactive rename prompt. EOF would answer "no" and take
# the add-a-new-field path, which fails the assertions loudly rather than hanging.
function _rit_plan(conn, livem::PormGModel, declared::PormGModel; answers::String = "1\n")
    settings = PormG.Configuration.Settings()
    settings.change_db = true
    current_schema = Dict{Symbol, Dict{Symbol, Union{Bool, PormGModel}}}(
        :child_t => Dict{Symbol, Union{Bool, PormGModel}}(:model => declared, :exist => false))
    path, io = mktemp(); write(io, answers); close(io)
    return open(path) do stdin_file
        redirect_stdin(stdin_file) do
            redirect_stdout(devnull) do
                Migrations.get_migration_plan(PormGModel[livem], current_schema, conn, settings;
                                              interactive = true)
            end
        end
    end
end

_rit_steps(plan, table::Symbol = :child_t) = haskey(plan, table) ? collect(keys(plan[table])) : String[]

# Apply in the order `migrate` would — through the REAL `_order_statements`, which defers every
# "Create index on …" past the rebuild (#152). Replaying the plan dict's own order is a wrong answer
# that looks right: the rebuild would destroy an index created before it.
function _rit_apply!(pool, plan, table::Symbol = :child_t)
    haskey(plan, table) || return nothing
    ordered, _ = Migrations._order_statements([plan[table]])
    for sql in ordered, stmt in split(sql, ";")
        s = strip(stmt)
        isempty(s) && continue
        startswith(uppercase(s), "PRAGMA FOREIGN_KEY_CHECK") && continue
        fetch(pool, s * ";")
    end
    return nothing
end

_rit_index_names(pool) = string.((fetch(pool, """PRAGMA index_list("child_t")""") |> DataFrame).name)
_rit_index_cols(pool, name) =
    string.((fetch(pool, """SELECT name FROM pragma_index_info('$(name)')""") |> DataFrame).name)

@testset "Rename index timing (#556)" begin

    # ─────────────────────────────────────────────────────────────────────────
    # GAP 1 — a rename that turns db_index ON plans the CREATE INDEX in the same migration
    # Before #556 the rename branch could not reach `index_actions`, so this planned a bare RENAME
    # COLUMN and the index appeared only on the NEXT makemigrations.
    # Mutation gate: `@test "Create index on new_code" in steps` fails against the unpatched planner.
    # ─────────────────────────────────────────────────────────────────────────
    @testset "SQLite: rename + db_index false -> true creates the index now" begin
        mktempdir() do dir
            pool = SQLiteConnectionPool(joinpath(dir, "rit556on.sqlite"); pool_size = 1)
            try
                fetch(pool, """CREATE TABLE "child_t" (
                                 "id"       INTEGER PRIMARY KEY AUTOINCREMENT UNIQUE NOT NULL,
                                 "old_code" TEXT(40) NULL,
                                 "note"     TEXT(40) NOT NULL)""")
                fetch(pool, """INSERT INTO "child_t" ("id", "old_code", "note") VALUES (1, 'X', 'keep')""")
                # Nothing indexes `old_code` to begin with — that is the "false" side of the flip.
                @test get_constraints_index(pool, :child_t, "old_code") === nothing

                declared = Models.Model("child_t", id = Models.IDField(),
                             new_code = Models.CharField(max_length = 40, null = true, db_index = true),
                             note = Models.CharField(max_length = 40))
                livem = Models.Model("child_t", id = Models.IDField(),
                             old_code = Models.CharField(max_length = 40, null = true),
                             note = Models.CharField(max_length = 40))
                plan = _rit_plan(pool, livem, declared)
                steps = _rit_steps(plan)

                @test "Rename field: new_code" in steps
                @test "Create index on new_code" in steps

                _rit_apply!(pool, plan)

                # THE ORACLE: the index exists, and it covers the renamed column.
                idx = get_constraints_index(pool, :child_t, "new_code")
                @test idx !== nothing
                @test _rit_index_cols(pool, idx) == ["new_code"]
                # …and the row survived, so this is a test of a migration rather than of some SQL.
                rows = fetch(pool, """SELECT "new_code", "note" FROM "child_t" """) |> DataFrame
                @test nrow(rows) == 1 && rows[1, :note] == "keep"
            finally
                close_pool!(pool)
            end
        end
    end

    # ─────────────────────────────────────────────────────────────────────────
    # GAP 1, the other direction — a rename that turns db_index OFF drops the index now
    # The DROP must key on the LIVE index name, which the rename does not change: RENAME COLUMN
    # carries an index with it, so the index is still there afterwards under its original name.
    # ─────────────────────────────────────────────────────────────────────────
    @testset "SQLite: rename + db_index true -> false drops the index now" begin
        mktempdir() do dir
            pool = SQLiteConnectionPool(joinpath(dir, "rit556off.sqlite"); pool_size = 1)
            try
                fetch(pool, """CREATE TABLE "child_t" (
                                 "id"       INTEGER PRIMARY KEY AUTOINCREMENT UNIQUE NOT NULL,
                                 "old_code" TEXT(40) NULL,
                                 "note"     TEXT(40) NOT NULL)""")
                fetch(pool, """CREATE INDEX "child_t_old_code_rit00001_idx" ON "child_t" ("old_code")""")
                fetch(pool, """INSERT INTO "child_t" ("id", "old_code", "note") VALUES (1, 'X', 'keep')""")
                @test get_constraints_index(pool, :child_t, "old_code") == "child_t_old_code_rit00001_idx"

                declared = Models.Model("child_t", id = Models.IDField(),
                             new_code = Models.CharField(max_length = 40, null = true),
                             note = Models.CharField(max_length = 40))
                livem = Models.Model("child_t", id = Models.IDField(),
                             old_code = Models.CharField(max_length = 40, null = true, db_index = true),
                             note = Models.CharField(max_length = 40))
                plan = _rit_plan(pool, livem, declared)
                steps = _rit_steps(plan)

                @test "Rename field: new_code" in steps
                @test "Remove index on new_code" in steps

                _rit_apply!(pool, plan)

                @test !("child_t_old_code_rit00001_idx" in _rit_index_names(pool))
                @test get_constraints_index(pool, :child_t, "new_code") === nothing
            finally
                close_pool!(pool)
            end
        end
    end

    # ─────────────────────────────────────────────────────────────────────────
    # GAP 1 on PostgreSQL — the same plan, from the plan text
    # PostgreSQL has no rebuild, so the flip is a plain CREATE INDEX beside the RENAME COLUMN. The
    # acceptance criterion says "on both engines", and this is the half a mock can answer.
    # ─────────────────────────────────────────────────────────────────────────
    @testset "PostgreSQL: rename + db_index false -> true creates the index now" begin
        declared = Models.Model("child_t", id = Models.IDField(),
                     new_code = Models.CharField(max_length = 40, null = true, db_index = true),
                     note = Models.CharField(max_length = 40))
        livem = Models.Model("child_t", id = Models.IDField(),
                     old_code = Models.CharField(max_length = 40, null = true),
                     note = Models.CharField(max_length = 40))
        plan = _rit_plan(RIT_PG, livem, declared)
        steps = _rit_steps(plan)

        @test "Rename field: new_code" in steps
        @test "Create index on new_code" in steps
        # The CREATE INDEX names the POST-rename column — it executes after the RENAME COLUMN, which
        # `_order_statements` guarantees by putting every "Create index on …" in the last bucket.
        @test occursin("\"new_code\"", plan[:child_t]["Create index on new_code"])
        @test !occursin("old_code", plan[:child_t]["Create index on new_code"])
    end

    # ─────────────────────────────────────────────────────────────────────────
    # GAP 2 — a rename co-occurring with an ordinary column ALTERATION on the same table
    # Both register the shared "Alter table: child_t" key; the alteration loop lands last. Before
    # #556 its registration carried an EMPTY rename map, so `get_secondary_index_ddls` filtered the
    # renamed column's index out as referencing a column that does not survive — and the index was
    # silently gone. One rebuild is still correct; only the appended index DDL differs, which is
    # why this can only be caught by applying and reading back.
    # ─────────────────────────────────────────────────────────────────────────
    @testset "SQLite: rename + a co-occurring alteration keeps the renamed column's index" begin
        mktempdir() do dir
            pool = SQLiteConnectionPool(joinpath(dir, "rit556alt.sqlite"); pool_size = 1)
            try
                fetch(pool, """CREATE TABLE "child_t" (
                                 "id"       INTEGER PRIMARY KEY AUTOINCREMENT UNIQUE NOT NULL,
                                 "old_code" TEXT(40) NULL,
                                 "note"     TEXT(40) NOT NULL)""")
                fetch(pool, """CREATE INDEX "child_t_old_code_rit00002_idx" ON "child_t" ("old_code")""")
                fetch(pool, """INSERT INTO "child_t" ("id", "old_code", "note") VALUES (1, 'X', '42')""")

                # `note` changes TEXT -> INTEGER: a non-empty delta on a field present on BOTH sides,
                # so the alteration loop registers the rebuild after the rename branch did.
                declared = Models.Model("child_t", id = Models.IDField(),
                             new_code = Models.CharField(max_length = 40, null = true, db_index = true),
                             note = Models.IntegerField())
                livem = Models.Model("child_t", id = Models.IDField(),
                             old_code = Models.CharField(max_length = 40, null = true, db_index = true),
                             note = Models.CharField(max_length = 40))
                plan = _rit_plan(pool, livem, declared)
                steps = _rit_steps(plan)

                # Exactly ONE rebuild, and it is last within the table's plan.
                @test count(==("Alter table: child_t"), steps) == 1
                @test steps[end] == "Alter table: child_t"

                _rit_apply!(pool, plan)

                # THE ORACLE: the renamed column still has an index after the shared rebuild.
                # Mutation gate: against the unpatched planner this is `nothing`.
                idx = get_constraints_index(pool, :child_t, "new_code")
                @test idx !== nothing
                @test _rit_index_cols(pool, idx) == ["new_code"]
                # The alteration really happened too, so the rebuild is not merely a no-op.
                rows = fetch(pool, """SELECT "new_code", "note" FROM "child_t" """) |> DataFrame
                @test nrow(rows) == 1 && rows[1, :note] == 42
            finally
                close_pool!(pool)
            end
        end
    end

    # ─────────────────────────────────────────────────────────────────────────
    # GAP 2, the producer the first pass MISSED — a rebuild-forcing DELETION
    # `_resolve_table_fields`' deletion loop renders the same shared key when SQLite cannot drop a
    # column in place (here: the doomed column is indexed). Its guard only skips when a rebuild is
    # ALREADY registered, and a PURE rename — empty delta — registers none, so this branch runs and
    # is the last writer. It passed no rename map at all, so the renamed column's index was filtered
    # out as referencing a column that does not survive.
    #
    # Found by review, by execution, after the first pass had asserted in four places that "all
    # three producers" were covered. There are four.
    # Mutation gate: drop `column_renames` from the deletion rebuild and the index assertion fails.
    # ─────────────────────────────────────────────────────────────────────────
    @testset "SQLite: rename + a rebuild-forcing deletion keeps the renamed column's index" begin
        mktempdir() do dir
            pool = SQLiteConnectionPool(joinpath(dir, "rit556del.sqlite"); pool_size = 1)
            try
                fetch(pool, """CREATE TABLE "child_t" (
                                 "id"       INTEGER PRIMARY KEY AUTOINCREMENT UNIQUE NOT NULL,
                                 "old_code" TEXT(40) NULL,
                                 "doomed"   TEXT(40) NULL)""")
                fetch(pool, """CREATE INDEX "child_t_old_code_rit00004_idx" ON "child_t" ("old_code")""")
                # An index on `doomed` is what makes SQLite refuse a plain DROP COLUMN and forces the
                # rebuild — the branch under test.
                fetch(pool, """CREATE INDEX "child_t_doomed_rit00004_idx" ON "child_t" ("doomed")""")
                fetch(pool, """INSERT INTO "child_t" ("id", "old_code", "doomed") VALUES (1, 'X', 'bye')""")

                # A PURE rename (same type, same everything) so the rename plans no rebuild of its
                # own and the deletion's rebuild is the only — hence last — registration.
                declared = Models.Model("child_t", id = Models.IDField(),
                             new_code = Models.CharField(max_length = 40, null = true, db_index = true))
                livem = Models.Model("child_t", id = Models.IDField(),
                             old_code = Models.CharField(max_length = 40, null = true, db_index = true),
                             doomed = Models.CharField(max_length = 40, null = true, db_index = true))
                plan = _rit_plan(pool, livem, declared)

                @test "Alter table: child_t" in _rit_steps(plan)

                _rit_apply!(pool, plan)

                idx = get_constraints_index(pool, :child_t, "new_code")
                @test idx !== nothing
                @test _rit_index_cols(pool, idx) == ["new_code"]
                # The deletion really happened, so the rebuild is not a no-op.
                cols = sort(string.((fetch(pool, """PRAGMA table_info("child_t")""") |> DataFrame).name))
                @test cols == ["id", "new_code"]
            finally
                close_pool!(pool)
            end
        end
    end

    # ─────────────────────────────────────────────────────────────────────────
    # GAP 2, the other producer — a rename co-occurring with a NEW column
    # `_add_new_field` re-renders the same key when the new column needs a temporary default (a
    # NOT NULL column with no default), and it passed no rename map at all. Whichever of the two
    # registrations lands last must still carry the rename.
    # ─────────────────────────────────────────────────────────────────────────
    @testset "SQLite: rename + a co-occurring new column keeps the renamed column's index" begin
        mktempdir() do dir
            pool = SQLiteConnectionPool(joinpath(dir, "rit556new.sqlite"); pool_size = 1)
            try
                fetch(pool, """CREATE TABLE "child_t" (
                                 "id"       INTEGER PRIMARY KEY AUTOINCREMENT UNIQUE NOT NULL,
                                 "old_code" TEXT(40) NULL)""")
                fetch(pool, """CREATE INDEX "child_t_old_code_rit00003_idx" ON "child_t" ("old_code")""")
                fetch(pool, """INSERT INTO "child_t" ("id", "old_code") VALUES (1, 'X')""")

                declared = Models.Model("child_t", id = Models.IDField(),
                             new_code = Models.CharField(max_length = 40, null = true, db_index = true),
                             # NOT NULL and defaultless, and a TEMPORAL type -- which is what
                             # `_get_temporary_default_value` answers for, and therefore what makes
                             # `_add_new_field` re-render the shared rebuild rather than merely
                             # relocate it. A NOT NULL IntegerField would take the plain ADD COLUMN
                             # path, which SQLite refuses outright and which never touches the map.
                             added = Models.DateTimeField())
                livem = Models.Model("child_t", id = Models.IDField(),
                             old_code = Models.CharField(max_length = 40, null = true, db_index = true))
                # Two additions (`new_code`, `added`) are offered against one deletion (`old_code`),
                # in model field order, so the prompts are answered "this one" then "no".
                plan = _rit_plan(pool, livem, declared; answers = "1\nno\n")
                steps = _rit_steps(plan)

                @test "Rename field: new_code" in steps
                @test "Add field: added" in steps

                _rit_apply!(pool, plan)

                idx = get_constraints_index(pool, :child_t, "new_code")
                @test idx !== nothing
                @test _rit_index_cols(pool, idx) == ["new_code"]
                cols = sort(string.((fetch(pool, """PRAGMA table_info("child_t")""") |> DataFrame).name))
                @test cols == ["added", "id", "new_code"]
            finally
                close_pool!(pool)
            end
        end
    end
end
