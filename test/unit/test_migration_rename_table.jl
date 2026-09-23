# =============================================================================
# makemigrations renames a table (#615)
#
# `get_migration_plan`'s interactive table-rename branch could never produce a plan: it called
# `_alter_table_fields` with the PRE-rename name (a `KeyError` on `current_schema`, which is keyed by
# the declared name), and one line later handed `Dialect.rename_table` a `Symbol` with the two names
# swapped (a `MethodError`). #615 repaired both and chose the ordering the #89 pass left open:
#
#   * `"Rename table"` has its own bucket, right after DROP TABLE and before RENAME COLUMN, so the
#     rename executes before anything that names a column;
#   * every statement for the renamed table therefore names the NEW table;
#   * every plan-time CATALOG lookup still asks for the OLD one — the database holds nothing else
#     until the migration runs.
#
# That last split is what the existing mocks could never have caught: they answer on the column
# (`params[2]`) alone, so a lookup by the wrong TABLE got the same answer as a lookup by the right
# one. The PostgreSQL mock below answers only when the table is right, and records every table it is
# asked about. The SQLite testsets apply the plan to a real file, which is the only way to prove the
# index snapshot and the child table's rebuild survive the rename.
#
# Hermetic: a mock connection and temporary SQLite files, no live database.
# =============================================================================

using Test
using DataFrames
using PormG
using PormG.Models
using PormG.Migrations
import PormG: PormGModel, PormGPostgres, PormGSQLite, Dialect
import OrderedCollections: OrderedDict
# The SQLite testsets open a real (temporary) file, so they need the weakdep extension.
# `runtests.jl` loads it for the whole suite; this guard is what makes the file runnable alone.
isdefined(Main, :SQLite) || include(joinpath(@__DIR__, "..", "load_drivers.jl"))
import PormG.ConnectionPool: fetch, close_pool!, SQLiteConnectionPool
import PormG.Migrations: LiveTable, read_live_schema, _sqlite_rewrite_index_table

# ─────────────────────────────────────────────────────────────────────────────
# Harness
# ─────────────────────────────────────────────────────────────────────────────

# Suffixed name: `runtests.jl` includes every unit file into ONE module, so a bare `MockPostgres`
# would silently redefine a sibling's.
struct RenameTableMockPg615 <: PormGPostgres end
const RT_PG = RenameTableMockPg615()

# Every table name a catalog lookup was made with, in call order.
const RT_ASKED = String[]

# The live constraint names — only learnable by asking, since `_hash_field_name` ends in
# `randstring(8)`. Keyed by (table, column) so that a lookup by the NEW table name finds nothing.
const RT_FK = Dict(("old_t", "parent_id") => "old_t_parent_id_live_fk",
                   ("child_t", "tbl_id")  => "child_t_tbl_id_live_fk")
const RT_UNIQUE = Dict(("old_t", "code") => "old_t_code_live_key")
const RT_INDEX = Dict(("old_t", "a") => "old_t_a_live_idx", ("old_t", "c") => "old_t_c_live_idx",
                      ("old_t", "label") => "old_t_label_live_idx")

# The four lookups inside `Dialect.alter_field`, which reach the catalog by table and column.
PormG.get_constraints_pk(::RenameTableMockPg615, t::String, f::String) = (push!(RT_ASKED, t); nothing)
PormG.get_constraints_unique(::RenameTableMockPg615, t::String, f::String) =
    (push!(RT_ASKED, t); get(RT_UNIQUE, (t, f), nothing))
PormG.get_constraints_check(::RenameTableMockPg615, t::String, f::String) = (push!(RT_ASKED, t); nothing)
PormG.get_constraints_byte_length_check(::RenameTableMockPg615, t::String, f::String) =
    (push!(RT_ASKED, t); nothing)

# The parameterized lookups (`get_constraints_fk`, `get_constraints_index`) all bind the table
# first. The 3-positional-arg `fetch(conn, sql, params)` forwards to this keyword form.
function fetch(::RenameTableMockPg615, sql::String; conn = nothing, params = nothing, ignore_tx::Bool = false)
    params === nothing || isempty(params) || push!(RT_ASKED, string(params[1]))
    if occursin("constraint_type = 'FOREIGN KEY'", sql) && params !== nothing && length(params) == 2
        hit = get(RT_FK, (string(params[1]), string(params[2])), nothing)
        hit === nothing || return DataFrame(constraint_name = [hit])
    end
    if occursin("AS indexname", sql) && params !== nothing && length(params) == 2
        hit = get(RT_INDEX, (string(params[1]), string(params[2])), nothing)
        hit === nothing || return DataFrame(indexname = [hit])
    end
    return DataFrame()
end

_rt_settings() = (s = PormG.Configuration.Settings(); s.change_db = true; s)

_rt_schema(models...) = Dict{Symbol, Dict{Symbol, Union{Bool, PormGModel}}}(
    Symbol(Models.model_table_name(m)) => Dict{Symbol, Union{Bool, PormGModel}}(:model => m, :exist => false)
    for m in models)

# Run the planner with scripted answers on stdin — the rename is only ever PROPOSED interactively.
# EOF answers "no", which takes the drop-and-create path and fails the assertions loudly rather than
# hanging.
function _rt_plan(live, current_schema, conn, answers::String)
    path, io = mktemp(); write(io, answers); close(io)
    return open(path) do stdin_file
        redirect_stdin(stdin_file) do
            redirect_stdout(devnull) do
                Migrations.get_migration_plan(live, current_schema, conn, _rt_settings(); interactive = true)
            end
        end
    end
end

_rt_ordered(plan) = first(Migrations._order_statements([plan[k] for k in keys(plan)]))

# The live (introspected) side of a constrained key: the target's binding STRING plus the `to_table`
# breadcrumb, the way a reader produces one.
function _rt_live_fk(to_table::String)
    live = Models.ForeignKey(uppercasefirst(to_table); pk_field = "id", null = true)
    live.to_table = to_table
    return live
end

# Apply every table's plan IN THE ORDER `migrate` would, with foreign keys suspended as the runner
# does (#276). Naive `;` splitting is fine here: these plans are DDL over identifiers this file chose,
# plus integer INSERTs, with no string literal that could contain a semicolon.
function _rt_apply!(pool, plan)
    fetch(pool, "PRAGMA foreign_keys = OFF;")
    for sql in _rt_ordered(plan), stmt in split(sql, ";")
        s = strip(stmt)
        isempty(s) || fetch(pool, s * ";")
    end
    return nothing
end

@testset "makemigrations renames a table (#615)" begin

    # ─────────────────────────────────────────────────────────────────────────
    # PostgreSQL: DDL names the new table, catalog lookups name the old one
    # A rename plus the four kinds of column work the renamed table can carry — a column rename, a
    # dropped UNIQUE (its constraint name comes from the catalog), a re-pointed foreign key (ditto)
    # and a new column — and a second table whose key points at the renamed one. Every lookup that
    # returns a name is keyed on the OLD table, so a planner asking for the new name drops nothing.
    # ─────────────────────────────────────────────────────────────────────────
    @testset "PostgreSQL: statements target the new name, lookups the old one" begin
        empty!(RT_ASKED)
        parent       = Models.Model("parent_t";       id = Models.IDField(), n = Models.IntegerField())
        other_parent = Models.Model("other_parent_t"; id = Models.IDField(), n = Models.IntegerField())
        declared = Models.Model("new_t"; id = Models.IDField(),
                                code = Models.CharField(max_length = 20, db_index = true),  # UNIQUE dropped, index gained
                                m = Models.IntegerField(),                                  # renamed from n
                                parent_id = Models.ForeignKey(other_parent; pk_field = "id", null = true),
                                flag = Models.IntegerField(null = true))                    # new
        child = Models.Model("child_t"; id = Models.IDField(),
                             tbl_id = Models.ForeignKey(declared; pk_field = "id", null = true))

        livem = Models.Model("old_t"; id = Models.IDField(),
                             code = Models.CharField(max_length = 20, unique = true),
                             n = Models.IntegerField(),
                             parent_id = _rt_live_fk("parent_t"))
        live_child = Models.Model("child_t"; id = Models.IDField(), tbl_id = _rt_live_fk("old_t"))

        # "no" (not a new table), "1" (its former name is old_t), "1" (`m` is the old `n`).
        plan = _rt_plan(PormGModel[parent, other_parent, livem, live_child],
                        _rt_schema(parent, other_parent, declared, child), RT_PG, "no\n1\n1\n")
        steps = plan[:new_t]

        # The rename itself — old ⇒ new, and nothing drops the old table.
        @test steps["Rename table"] == "ALTER TABLE \"old_t\" RENAME TO \"new_t\";"
        @test !haskey(plan, :old_t)
        @test !any(s -> occursin("DROP TABLE", s), values(steps))

        # Column work, all against the NEW table.
        @test steps["Rename field: m"] == "ALTER TABLE \"new_t\" RENAME COLUMN \"n\" TO \"m\";"
        @test occursin("ALTER TABLE \"new_t\" ADD COLUMN \"flag\"", steps["Add field: flag"])
        @test occursin("ON \"new_t\"", steps["Create index on code"])
        @test occursin("REFERENCES \"other_parent_t\"", steps["New foreign key: parent_id"])
        @test occursin("ALTER TABLE \"new_t\"", steps["New foreign key: parent_id"])

        # The two names that exist ONLY in the catalog, under the old table. Present means the lookup
        # asked for `old_t`; the statement naming `new_t` means it will run after the rename.
        @test steps["Remove foreign key: parent_id"] ==
              "ALTER TABLE \"new_t\" DROP CONSTRAINT IF EXISTS \"old_t_parent_id_live_fk\";"
        @test occursin("ALTER TABLE \"new_t\" DROP CONSTRAINT \"old_t_code_live_key\"", steps["Alter field: code"])

        # No lookup ever asked for the table the database does not have yet.
        @test "old_t" in RT_ASKED
        @test !("new_t" in RT_ASKED)

        # The other table re-points its key at the new name (redundant — a PostgreSQL rename carries
        # the constraint along — but correct, provided it runs after the rename).
        @test occursin("REFERENCES \"new_t\"", plan[:child_t]["New foreign key: tbl_id"])

        # Ordering: the rename precedes every other statement that names `new_t`, including the
        # child's key, whatever order the tables were planned in.
        ordered = _rt_ordered(plan)
        i_rename = findfirst(==(steps["Rename table"]), ordered)
        @test i_rename !== nothing
        for (i, s) in enumerate(ordered)
            i == i_rename && continue
            occursin("\"new_t\"", s) && @test i > i_rename
        end
    end

    # ─────────────────────────────────────────────────────────────────────────
    # PostgreSQL: the deletion path and the index lookups ask for the old name too
    # The three places the first testset does not reach, each of which can only learn a live name
    # by asking the catalog: a deleted foreign-key column's constraint, a deleted indexed column's
    # index, and an index dropped by a `db_index` flip — on a kept column and on a renamed one (the
    # rename branch resolves that name itself, keyed on the pre-rename column). Asking with the new
    # table name finds nothing and silently plans no drop at all.
    # ─────────────────────────────────────────────────────────────────────────
    @testset "PostgreSQL: deletions and index drops look up the old name" begin
        empty!(RT_ASKED)
        livem = Models.Model("old_t"; id = Models.IDField(),
                             a = Models.IntegerField(db_index = true),
                             c = Models.IntegerField(db_index = true),
                             label = Models.IntegerField(db_index = true),
                             parent_id = _rt_live_fk("parent_t"))
        declared = Models.Model("new_t"; id = Models.IDField(),
                                b = Models.IntegerField(),        # renamed from `a`, index dropped
                                c = Models.IntegerField())        # index dropped
        # Table rename, then `b` is candidate 1 of (a, label, parent_id) — numbered by name.
        plan = _rt_plan(PormGModel[livem], _rt_schema(declared), RT_PG, "no\n1\n1\n")
        steps = plan[:new_t]

        @test steps["Rename field: b"] == "ALTER TABLE \"new_t\" RENAME COLUMN \"a\" TO \"b\";"
        # Each index name is known only to the catalog, under the old table.
        @test steps["Remove index on b"] == "DROP INDEX IF EXISTS \"old_t_a_live_idx\";"
        @test steps["Remove index on c"] == "DROP INDEX IF EXISTS \"old_t_c_live_idx\";"
        @test steps["Remove index on label"] == "DROP INDEX IF EXISTS \"old_t_label_live_idx\";"
        # The deleted key's constraint likewise — and the statements name the new table.
        @test steps["Remove foreign key: parent_id"] ==
              "ALTER TABLE \"new_t\" DROP CONSTRAINT IF EXISTS \"old_t_parent_id_live_fk\";"
        @test steps["Remove field: label"] == "ALTER TABLE \"new_t\" DROP COLUMN \"label\";"
        @test steps["Remove field: parent_id"] == "ALTER TABLE \"new_t\" DROP COLUMN \"parent_id\";"
        @test !("new_t" in RT_ASKED)
    end

    # ─────────────────────────────────────────────────────────────────────────
    # The prompt still offers the other two answers
    # "yes" (a new table) and "no" + "no" (not a rename after all) both plan a CREATE of the new
    # table and a DROP of the old one — the paths that worked before #615 must not change.
    # ─────────────────────────────────────────────────────────────────────────
    @testset "declining the rename still plans drop + create" begin
        declared = Models.Model("new_t"; id = Models.IDField(), n = Models.IntegerField())
        livem    = Models.Model("old_t"; id = Models.IDField(), n = Models.IntegerField())
        for answers in ("yes\n", "no\nno\n")
            plan = _rt_plan(PormGModel[livem], _rt_schema(declared), RT_PG, answers)
            @test haskey(plan[:new_t], "New model")
            @test !haskey(plan[:new_t], "Rename table")
            @test haskey(plan[:old_t], "Drop table")
        end
    end

    # ─────────────────────────────────────────────────────────────────────────
    # The rename prompt numbers candidates in catalog order
    # `futher_processing[:drop_table]` was a `Dict`, so with several vanished tables the number the
    # user typed picked whichever one hash order had put there. It is ordered now: the candidates are
    # numbered as the live side lists them, so "2" is always the second vanished table.
    # ─────────────────────────────────────────────────────────────────────────
    @testset "the rename candidates are numbered in live-schema order" begin
        declared = Models.Model("new_t"; id = Models.IDField(), n = Models.IntegerField())
        gone = [Models.Model("gone_$(c)_t"; id = Models.IDField(), n = Models.IntegerField()) for c in 'a':'h']
        # Pick the fifth; the other seven are dropped.
        plan = _rt_plan(PormGModel[gone...], _rt_schema(declared), RT_PG, "no\n5\n")
        @test plan[:new_t]["Rename table"] == "ALTER TABLE \"gone_e_t\" RENAME TO \"new_t\";"
        @test !haskey(plan, :gone_e_t)
        @test count(k -> haskey(plan[k], "Drop table"), collect(keys(plan))) == 7
    end

    # ─────────────────────────────────────────────────────────────────────────
    # SQLite, applied: data, index, child key and a converged re-diff
    # The end-to-end proof on the engine that REBUILDS. The renamed table's column rename + nullability
    # change forces a rebuild, whose index snapshot is read from the catalog under the OLD name and
    # must be re-emitted `ON "new_t"`; the child table rebuilds for its re-pointed key and runs
    # `PRAGMA foreign_key_check`, which reports a missing parent if it runs before the rename.
    # ─────────────────────────────────────────────────────────────────────────
    @testset "SQLite: the rename applies, keeps rows, index and child key, and converges" begin
        mktempdir() do dir
            pool = SQLiteConnectionPool(joinpath(dir, "rt615.sqlite"); pool_size = 1)
            try
                # v1, created by the planner itself from an empty database.
                parent = Models.Model("parent_t"; id = Models.IDField(), name = Models.CharField(max_length = 20))
                old_v1 = Models.Model("old_t"; id = Models.IDField(),
                                      code = Models.CharField(max_length = 20, db_index = true),
                                      n = Models.IntegerField(),
                                      parent_id = Models.ForeignKey(parent; pk_field = "id", null = true))
                child_v1 = Models.Model("child_t"; id = Models.IDField(),
                                        tbl_id = Models.ForeignKey(old_v1; pk_field = "id", null = true))
                _rt_apply!(pool, Migrations.get_migration_plan(LiveTable[], _rt_schema(parent, old_v1, child_v1),
                                                              pool, _rt_settings(); interactive = false))
                fetch(pool, """INSERT INTO "parent_t" ("id", "name") VALUES (1, 'p')""")
                fetch(pool, """INSERT INTO "old_t" ("id", "code", "n", "parent_id") VALUES (1, 'a', 10, 1), (2, 'b', 20, 1)""")
                fetch(pool, """INSERT INTO "child_t" ("id", "tbl_id") VALUES (1, 2)""")
                idx_before = fetch(pool, """SELECT name FROM sqlite_master WHERE type = 'index' AND tbl_name = 'old_t' AND sql IS NOT NULL""") |> DataFrame
                # `code`'s `db_index` and the key column's index — both must come through the rebuild.
                @test nrow(idx_before) == 2

                # v2: old_t becomes new_t, `n` becomes a NULLABLE `m` (rename + a delta ⇒ a rebuild).
                new_v2 = Models.Model("new_t"; id = Models.IDField(),
                                      code = Models.CharField(max_length = 20, db_index = true),
                                      m = Models.IntegerField(null = true),
                                      parent_id = Models.ForeignKey(parent; pk_field = "id", null = true))
                child_v2 = Models.Model("child_t"; id = Models.IDField(),
                                        tbl_id = Models.ForeignKey(new_v2; pk_field = "id", null = true))
                schema_v2 = _rt_schema(parent, new_v2, child_v2)
                plan = _rt_plan(read_live_schema(pool), schema_v2, pool, "no\n1\n1\n")
                @test plan[:new_t]["Rename table"] == "ALTER TABLE \"old_t\" RENAME TO \"new_t\";"
                @test haskey(plan[:new_t], "Alter table: new_t")
                # The rebuild re-creates the snapshotted index against the NEW table.
                rebuild = plan[:new_t]["Alter table: new_t"]
                @test occursin("ON \"new_t\"", rebuild)
                @test !occursin("\"old_t\"", rebuild)

                _rt_apply!(pool, plan)

                tables = (fetch(pool, "SELECT name FROM sqlite_master WHERE type = 'table'") |> DataFrame).name
                @test "new_t" in tables
                @test !("old_t" in tables)

                # Rows carried across, the renamed column included.
                rows = fetch(pool, """SELECT "id", "code", "m", "parent_id" FROM "new_t" ORDER BY "id" """) |> DataFrame
                @test rows.id == [1, 2]
                @test rows.code == ["a", "b"]
                @test rows.m == [10, 20]

                # Both indexes survived the rebuild, under their original names, on the new table.
                idx_after = fetch(pool, """SELECT name FROM sqlite_master WHERE type = 'index' AND tbl_name = 'new_t' AND sql IS NOT NULL""") |> DataFrame
                @test sort(idx_after.name) == sort(idx_before.name)

                # The child's key points at the new table and nothing dangles.
                fks = fetch(pool, """PRAGMA foreign_key_list("child_t")""") |> DataFrame
                @test fks.table == ["new_t"]
                @test isempty(fetch(pool, "PRAGMA foreign_key_check;") |> DataFrame)

                # Converged: the next makemigrations proposes nothing and asks nothing.
                again = Migrations.get_migration_plan(read_live_schema(pool), schema_v2, pool, _rt_settings();
                                                      interactive = false)
                @test isempty(again)
            finally
                close_pool!(pool)
            end
        end
    end

    # ─────────────────────────────────────────────────────────────────────────
    # SQLite: the two other rebuilds a renamed table can take keep its indexes
    # Beside the alteration rebuild above, a renamed table is rebuilt by (A) deleting an indexed
    # column — the deletion is routed to a rebuild by two catalog probes — and (B) adding a NOT NULL
    # column that needs a temporary default. Both snapshot the table's indexes from the catalog. Asked
    # under the NEW name that snapshot is empty and nothing errors: the rebuild simply re-creates no
    # index, so the surviving `code` index would vanish without a word.
    # ─────────────────────────────────────────────────────────────────────────
    @testset "SQLite: a deletion rebuild and a new-column rebuild keep the renamed table's indexes" begin
        variants = (
            # (A) `gone` is indexed, so SQLite cannot DROP COLUMN it in place.
            (:deletion, Models.Model("new_t"; id = Models.IDField(),
                                     code = Models.CharField(max_length = 20, db_index = true),
                                     n = Models.IntegerField()),
             ["code"]),
            # (B) a NOT NULL datetime with no default gets a temporary one, removed by a rebuild.
            (:new_column, Models.Model("new_t"; id = Models.IDField(),
                                       code = Models.CharField(max_length = 20, db_index = true),
                                       gone = Models.IntegerField(db_index = true),
                                       n = Models.IntegerField(),
                                       stamp = Models.DateTimeField()),
             ["code", "gone"]),
        )
        for (label, new_v2, indexed) in variants
            mktempdir() do dir
                pool = SQLiteConnectionPool(joinpath(dir, "rt615_$(label).sqlite"); pool_size = 1)
                try
                    old_v1 = Models.Model("old_t"; id = Models.IDField(),
                                          code = Models.CharField(max_length = 20, db_index = true),
                                          gone = Models.IntegerField(db_index = true),
                                          n = Models.IntegerField())
                    _rt_apply!(pool, Migrations.get_migration_plan(LiveTable[], _rt_schema(old_v1), pool,
                                                                  _rt_settings(); interactive = false))
                    fetch(pool, """INSERT INTO "old_t" ("id", "code", "gone", "n") VALUES (1, 'a', 7, 10)""")

                    plan = _rt_plan(read_live_schema(pool), _rt_schema(new_v2), pool, "no\n1\n")
                    @test haskey(plan[:new_t], "Alter table: new_t")
                    @test !occursin("\"old_t\"", plan[:new_t]["Alter table: new_t"])
                    _rt_apply!(pool, plan)

                    @test only((fetch(pool, """SELECT "code" FROM "new_t" """) |> DataFrame).code) == "a"
                    # Every index the declared model still wants is on the new table.
                    live_new = only(filter(t -> t.name == "new_t", read_live_schema(pool)))
                    for col in indexed
                        @test haskey(live_new.indexes, col)
                    end
                    @test isempty(Migrations.get_migration_plan(read_live_schema(pool), _rt_schema(new_v2), pool,
                                                               _rt_settings(); interactive = false))
                finally
                    close_pool!(pool)
                end
            end
        end
    end

    # ─────────────────────────────────────────────────────────────────────────
    # _sqlite_rewrite_index_table: only the table token after ON moves
    # The snapshot is verbatim `sqlite_master` DDL, so the table can be spelled any of SQLite's five
    # ways (bare, three identifier quotes, and a legacy string literal), and the same word can
    # legitimately appear as the index name, a column or a literal.
    # ─────────────────────────────────────────────────────────────────────────
    @testset "_sqlite_rewrite_index_table rewrites the ON target and nothing else" begin
        rw(s) = _sqlite_rewrite_index_table(s, "new_t")
        # Every spelling of the table.
        @test rw("CREATE INDEX \"i\" ON \"old_t\" (\"code\")") == "CREATE INDEX \"i\" ON \"new_t\" (\"code\")"
        @test rw("CREATE INDEX i ON old_t (code)")             == "CREATE INDEX i ON \"new_t\" (code)"
        @test rw("CREATE INDEX i ON [old_t](code)")            == "CREATE INDEX i ON \"new_t\"(code)"
        @test rw("CREATE INDEX i ON `old_t` (code)")           == "CREATE INDEX i ON \"new_t\" (code)"
        # SQLite's legacy single-quoted table spelling, which the tokenizer skips as a string literal.
        @test rw("CREATE INDEX i on 'old_t'(code)")            == "CREATE INDEX i on \"new_t\"(code)"
        @test rw("CREATE INDEX i ON  'old_t'  (code)")         == "CREATE INDEX i ON  \"new_t\"  (code)"
        # UNIQUE, IF NOT EXISTS and a partial WHERE clause are untouched.
        @test rw("CREATE UNIQUE INDEX IF NOT EXISTS i ON old_t (code) WHERE n > 0") ==
              "CREATE UNIQUE INDEX IF NOT EXISTS i ON \"new_t\" (code) WHERE n > 0"
        # The same word as the index name, a column and a string literal: only the target moves.
        @test rw("CREATE INDEX old_t ON old_t (old_t) WHERE old_t <> 'old_t'") ==
              "CREATE INDEX old_t ON \"new_t\" (old_t) WHERE old_t <> 'old_t'"
        # An embedded quote in the new name is doubled.
        @test _sqlite_rewrite_index_table("CREATE INDEX i ON t (c)", "we\"ird") == "CREATE INDEX i ON \"we\"\"ird\" (c)"
        # Not CREATE INDEX shape: returned unchanged rather than guessed at.
        @test rw("CREATE INDEX i ON old_t") == "CREATE INDEX i ON old_t"
    end
end
