"""
Unit coverage for two migration bugs that both come down to a constraint PormG could not see.

#515 — renaming a `unique = true` field destroyed its UNIQUE constraint. The rename branch of
`_resolve_table_fields` calls `_drop_index` for any non-PK renamed column, to remove an index whose
name embeds the OLD column name so `_add_constrains` can re-create it under the new one. It asked
`get_constraints_index` which index that was, and got back the index BACKING the constraint:

    PostgreSQL   `indexdef LIKE '%<col>%'` — unanchored, unparameterized, unordered
    SQLite       every row of `PRAGMA index_list`, `sqlite_autoindex_…` included

`_drop_index` then emitted `ALTER TABLE … DROP CONSTRAINT IF EXISTS` ahead of its `DROP INDEX` —
which is exactly how PostgreSQL lets you drop a constraint-backed index, and exactly why the
constraint disappeared, silently and permanently: `_add_constrains` has no `unique` half, and
introspection reads `unique` back correctly afterwards, so the model compared converged and
`makemigrations` never mentioned it again. SQLite refused the same `DROP INDEX` outright and rolled
the migration back. One input, opposite failures.

Fixed at the LOOKUP, not the call site — `get_constraints_index` now returns only an index PormG may
actually drop — so all three `_drop_index` call sites are covered at once, and the unanchored
PostgreSQL match is closed in the same move. A call-site guard on `new_field.unique` would have read
like the fix while missing a `CREATE UNIQUE INDEX` column, which sets no `field.unique` at all.

#514 — a new `ForeignKey` column on an EXISTING SQLite table got no constraint. `add_field` was a
bare `ADD COLUMN <field_to_column(…)>`, `field_to_column` renders no `REFERENCES` on either backend,
and `_add_constrains`' FK block was PostgreSQL-only. Nothing warned. SQLite accepts an inline
`REFERENCES` on `ADD COLUMN` when the column is nullable with no default — the rule Django's SQLite
schema editor tests before falling back to `_remake_table` — so that is what PormG emits now, and
every other shape routes through the table rebuild.

ONE CORRECTION TO #514's OWN DIAGNOSIS, measured while writing testset 8 rather than assumed. The
issue states that `makemigrations` "converges afterwards, so nothing ever proposes fixing it". It
does not. Introspection reads the constraint-less column back as `sIntegerField` while the declared
side stays `sForeignKey`; no comparator reconciles that pair, so the SECOND `makemigrations` plans a
whole-table rebuild — which does create the key, and even logs #505's `@info` on the way. The real
pre-fix behaviour was therefore a constraint-less window followed by a surprise rebuild on a later,
unrelated run. Testset 8 is what keeps both halves fixed; it fails against the unfixed planner for
exactly that churn.

WHAT THIS FILE PROVES, AND WHAT IT DOES NOT. Every SQLite testset below runs the plan against a real
temp database and then asks the database, not the plan text: a duplicate INSERT must still raise, a
`PRAGMA foreign_key_list` must have a row. A plan-shape assertion alone cannot tell the difference
between a constraint that survived and one that was never there. The PostgreSQL testsets are
plan-shape and query-shape only — a mock has no catalog — so the live-PostgreSQL half is integration
Phase 4j's job. The new PostgreSQL query itself was validated against `db_2` while this was written:
a UNIQUE-not-PK column answers `nothing`, a plain index answers its name.

`_ruq_`-prefixed throughout: `runtests.jl` includes every unit file into ONE module, so a bare
`MockPostgres` or `_parent()` silently redefines a sibling's.
"""

using Test
using DataFrames
using PormG
using PormG.Models
using PormG.Migrations
import PormG: PormGModel, PormGPostgres, PormGSQLite
# Every testset here opens a real (temporary) SQLite file. `runtests.jl` loads the weakdep extension
# for the whole suite; this guard is what makes the file runnable on its own.
isdefined(Main, :SQLite) || include(joinpath(@__DIR__, "..", "load_drivers.jl"))
import PormG.ConnectionPool: SQLiteConnectionPool, fetch, close_pool!
import PormG.Migrations: get_constraints_index, _drop_index, convertSQLToModel

# ─────────────────────────────────────────────────────────────────────────────
# Harness
# ─────────────────────────────────────────────────────────────────────────────

# The PostgreSQL mock. `get_constraints_index` is now PARAMETERIZED, so it arrives here with its
# values in `params` rather than baked into `sql` — which is itself half of what testset 5 asserts.
# The catch-all returning an empty frame means "no live index", keeping these plans to the story
# under test; without it `makemigrations` raises a `MethodError` from inside `_drop_index`.
struct RenameUniqueMockPg515 <: PormGPostgres end
const RUQ_PG = RenameUniqueMockPg515()
const RUQ_LAST_SQL = Ref{String}("")
const RUQ_LAST_PARAMS = Ref{Any}(nothing)

function fetch(connection::RenameUniqueMockPg515, sql::String;
  conn = nothing,
  params = nothing,
  ignore_tx::Bool = false)

  RUQ_LAST_SQL[] = sql
  RUQ_LAST_PARAMS[] = params
  return DataFrame()
end

_ruq_parent() = Models.Model("parent_t", id = Models.IDField(), n = Models.IntegerField())

# Apply a plan to the live database IN THE ORDER `migrate` would.
#
# Ordering is not a detail here, and replaying the plan dict's own order is a wrong answer that looks
# right. `_order_statements` (`src/migrations/runner.jl`) buckets every step — `New model`, then
# `Drop table`, then `Rename field`, then everything else, and `Create index …` LAST of all. That
# last bucket is #152, and it exists for precisely the shape testset 9 exercises: a SQLite rebuild
# `DROP TABLE`s the table and re-creates only the indexes it snapshotted from the live schema at
# PLAN time, which cannot include an index queued in the same migration. Deferring the CREATE INDEX
# past the rebuild is what lands it on the rebuilt table.
#
# Replayed in plan-dict order the CREATE INDEX runs BEFORE the rebuild and the index is destroyed —
# measured, and it converges afterwards, so a harness that replayed in dict order would report a
# silent permanent index loss that `migrate` does not actually have. Calling the real ordering
# function is what makes these testsets say something about the migration a user would run.
#
# Naive `;` splitting is fine HERE and nowhere else: every statement these plans emit is DDL over
# identifiers this file chose, with no string literal that could contain a semicolon.
function _ruq_apply!(pool, plan, table::Symbol)
  haskey(plan, table) || return nothing
  # `_order_statements` takes a collection of per-table inner dicts, not the outer plan. Scoped to
  # the ONE table named, so the signature does not quietly apply a second model's DDL if a future
  # testset declares one.
  ordered, _all_sql = Migrations._order_statements([plan[table]])
  for sql in ordered
    for stmt in split(sql, ";")
      s = strip(stmt)
      isempty(s) && continue
      fetch(pool, s * ";")
    end
  end
  return nothing
end

_ruq_steps(plan, table::Symbol) = haskey(plan, table) ? collect(keys(plan[table])) : String[]
_ruq_step(plan, table::Symbol, key) = haskey(plan, table) ? get(plan[table], key, "") : ""
_ruq_text(plan, table::Symbol) = haskey(plan, table) ? join(values(plan[table]), "\n") : ""

# Build the two models the planner diffs and return the plan. `get_migration_plan` takes the LIVE
# models first and the DECLARED ones in `current_schema` — the same (deliberately confusing) argument
# order the planner itself uses.
function _ruq_plan(conn, livem::PormGModel, declared::PormGModel; interactive::Bool = false,
                   answer::String = "1")
  settings = PormG.Configuration.Settings()
  settings.change_db = true
  current_schema = Dict{Symbol, Dict{Symbol, Union{Bool, PormGModel}}}(
    :child_t => Dict{Symbol, Union{Bool, PormGModel}}(:model => declared, :exist => false))
  interactive || return Migrations.get_migration_plan(PormGModel[livem], current_schema, conn,
                                                      settings; interactive = false)
  # A rename is only ever PROPOSED interactively. `answer` is the listed option number; EOF would
  # answer "no" and take the add-a-new-field path instead, which fails the assertions loudly rather
  # than hanging. Same technique as integration Phase 4e/4i.
  path, io = mktemp(); write(io, answer * "\n"); close(io)
  return open(path) do stdin_file
    redirect_stdin(stdin_file) do
      Migrations.get_migration_plan(PormGModel[livem], current_schema, conn, settings;
                                    interactive = true)
    end
  end
end

@testset "Renaming a unique field keeps its constraint (#515)" begin

  # ───────────────────────────────────────────────────────────────────────────
  # 1. #515, SQLite: a `unique = true` column's backing auto-index is not droppable, so it must not
  #    be offered. `get_constraints_index` answers `nothing`, the rename plans a bare RENAME COLUMN,
  #    and — the assertion that actually matters — the constraint is still ENFORCED afterwards.
  #
  #    Pre-fix this testset fails twice over: the lookup returns `sqlite_autoindex_child_t_2`, and
  #    applying the plan raises *"index associated with UNIQUE or PRIMARY KEY constraint cannot be
  #    dropped"*. Both are what the issue reports; neither can be seen from the plan text alone,
  #    which is why the rows below are inserted rather than reasoned about.
  # ───────────────────────────────────────────────────────────────────────────
  @testset "SQLite: a unique column's auto-index is never dropped, and the constraint survives" begin
    mktempdir() do dir
      pool = SQLiteConnectionPool(joinpath(dir, "ruq515sl.sqlite"); pool_size = 1)
      try
        fetch(pool, """CREATE TABLE "child_t" (
                         "id"       INTEGER PRIMARY KEY AUTOINCREMENT UNIQUE NOT NULL,
                         "old_code" TEXT UNIQUE NULL,
                         "note"     TEXT(40) NOT NULL)""")
        fetch(pool, """INSERT INTO "child_t" ("id", "old_code", "note") VALUES (1, 'X', 'keep-me')""")

        # The lookup itself. `sqlite_autoindex_child_t_2` is right there in `PRAGMA index_list` and
        # is what the old walk returned first.
        @test get_constraints_index(pool, :child_t, "old_code") === nothing
        # …and it really is in the list, so the `nothing` above is a filter and not an empty table.
        idx_list = fetch(pool, """PRAGMA index_list("child_t")""") |> DataFrame
        @test any(startswith(String(n), "sqlite_autoindex") for n in idx_list.name)

        declared = Models.Model("child_t", id = Models.IDField(),
                     new_code = Models.CharField(unique = true, null = true),
                     note = Models.CharField(max_length = 40))
        livem    = Models.Model("child_t", id = Models.IDField(),
                     old_code = Models.CharField(unique = true, null = true),
                     note = Models.CharField(max_length = 40))
        plan = _ruq_plan(pool, livem, declared; interactive = true)

        # No index step at all — asserted on the plan KEY rather than on `DROP INDEX` in the DDL,
        # because the key is what `_drop_index` writes and it names the column it acted on.
        @test !("Remove index on old_code" in _ruq_steps(plan, :child_t))
        @test occursin("RENAME COLUMN", _ruq_step(plan, :child_t, "Rename field: new_code"))
        @test !occursin("sqlite_autoindex", _ruq_text(plan, :child_t))

        # Must not raise: this is the migration abort the issue reports.
        _ruq_apply!(pool, plan, :child_t)

        # THE ASSERTION #515 EXISTS FOR. Ask the database, not the plan.
        @test "new_code" in string.((fetch(pool, """PRAGMA table_info("child_t")""") |> DataFrame).name)
        dup_err = try
          fetch(pool, """INSERT INTO "child_t" ("id", "new_code", "note") VALUES (2, 'X', 'dup')""")
          nothing
        catch e; e; end
        @test dup_err !== nothing
        @test any(tok -> occursin(tok, lowercase(string(dup_err))), ["unique", "constraint"])

        # …and the raise above is the constraint, not collateral damage: a DISTINCT value still goes in.
        fetch(pool, """INSERT INTO "child_t" ("id", "new_code", "note") VALUES (3, 'Y', 'other')""")
        surviving = fetch(pool, """SELECT "new_code", "note" FROM "child_t" ORDER BY "id" """) |> DataFrame
        @test nrow(surviving) == 2
        @test isequal(surviving[1, :new_code], "X")     # the pre-rename row carried its value across
        @test isequal(surviving[1, :note], "keep-me")
      finally
        close_pool!(pool)
      end
    end
  end

  # ───────────────────────────────────────────────────────────────────────────
  # 2. What a rename does to a plain `CREATE INDEX` column — RE-ADJUDICATED BY #507 phase 2.
  #
  #    This testset used to require that the index be found, DROPPED, and RE-CREATED against the new
  #    name, on the stated grounds that index names carry a `randstring(8)` suffix nothing can
  #    re-derive, so an index left behind keeps a name embedding the OLD column forever.
  #
  #    Phase 2 removed the `_drop_index` call from the rename path (decision 5: an empty column
  #    delta means RENAME COLUMN and nothing else), so the drop-and-recreate is gone. That was a
  #    deliberate call by the maintainer, and the reasoning is not "the old test was wrong" — it is
  #    that the exchange bought a cosmetic name at a real price:
  #
  #      * `ALTER TABLE … RENAME COLUMN` updates a column's indexes on BOTH engines, so the index
  #        was never actually lost. Only its NAME went stale. Django behaves the same way (a
  #        renamed field keeps its auto-named index), so this is also the less surprising answer for
  #        someone arriving from there.
  #      * DROP + CREATE INDEX rebuilds the index from scratch — on a large table, minutes of work
  #        to change a name nothing reads.
  #      * And it was the mechanism of #515: `get_constraints_index` answered with the index BACKING
  #        a UNIQUE constraint, which the drop then destroyed. That is fixed where the answer is
  #        produced, but a path that drops no index cannot re-open it at all.
  #
  #    So the assertions below now pin the CURRENT contract, and they pin it BY EXECUTION — the plan
  #    is applied to a real SQLite file and the surviving index is interrogated afterwards. The one
  #    thing that would be a genuine regression, the UNIQUE constraint disappearing, is asserted
  #    exactly as before.
  #
  #    STATED LIMIT, and the reason the stale name is acceptable rather than merely tolerated: the
  #    index still covers the renamed column, so introspection reads `db_index = true` and the model
  #    converges. The only visible residue is the name. A rename that ALSO flips `db_index` is
  #    planned one run later, when the column appears on both sides of the diff — self-healing, and
  #    tracked in the phase-3 follow-up.
  # ───────────────────────────────────────────────────────────────────────────
  @testset "SQLite: a rename leaves a plain db_index alone (it follows the column)" begin
    mktempdir() do dir
      pool = SQLiteConnectionPool(joinpath(dir, "ruq515idx.sqlite"); pool_size = 1)
      try
        fetch(pool, """CREATE TABLE "child_t" (
                         "id"       INTEGER PRIMARY KEY AUTOINCREMENT UNIQUE NOT NULL,
                         "old_code" TEXT UNIQUE NULL,
                         "note"     TEXT(40) NOT NULL)""")
        fetch(pool, """CREATE INDEX "child_t_old_code_ruq00001_idx" ON "child_t" ("old_code")""")
        fetch(pool, """INSERT INTO "child_t" ("id", "old_code", "note") VALUES (1, 'X', 'keep-me')""")

        # Two indexes cover `old_code`: the UNIQUE auto-index and this plain one. The plain one wins.
        @test get_constraints_index(pool, :child_t, "old_code") == "child_t_old_code_ruq00001_idx"

        declared = Models.Model("child_t", id = Models.IDField(),
                     new_code = Models.CharField(unique = true, null = true, db_index = true),
                     note = Models.CharField(max_length = 40))
        livem    = Models.Model("child_t", id = Models.IDField(),
                     old_code = Models.CharField(unique = true, null = true, db_index = true),
                     note = Models.CharField(max_length = 40))
        plan = _ruq_plan(pool, livem, declared; interactive = true)

        # The rename plans the rename, and nothing about the index in either direction.
        @test "Rename field: new_code" in _ruq_steps(plan, :child_t)
        @test !("Remove index on old_code" in _ruq_steps(plan, :child_t))
        @test !("Create index on new_code" in _ruq_steps(plan, :child_t))

        _ruq_apply!(pool, plan, :child_t)

        names = string.((fetch(pool, """PRAGMA index_list("child_t")""") |> DataFrame).name)
        # The index SURVIVES the rename, under its original name…
        @test "child_t_old_code_ruq00001_idx" in names
        # …and it covers the renamed column, which is the part that matters: SQLite rewrote the
        # index definition when the column was renamed, so the lookup by COLUMN still finds it and
        # introspection will read `db_index = true` back for `new_code`. Proven by execution here,
        # not asserted from the plan text.
        plain = get_constraints_index(pool, :child_t, "new_code")
        @test plain == "child_t_old_code_ruq00001_idx"
        idx_cols = string.((fetch(pool, """SELECT name FROM pragma_index_info('child_t_old_code_ruq00001_idx')""") |> DataFrame).name)
        @test idx_cols == ["new_code"]
        # The stale NAME is the whole cost of not re-creating it, and it is named so that anyone
        # tempted to "fix" it has to weigh a full index rebuild against a cosmetic string.
        @test !occursin("new_code", plain)
        # …and the UNIQUE constraint came through the whole exchange untouched.
        dup_err = try
          fetch(pool, """INSERT INTO "child_t" ("id", "new_code", "note") VALUES (2, 'X', 'dup')""")
          nothing
        catch e; e; end
        @test dup_err !== nothing
      finally
        close_pool!(pool)
      end
    end
  end

  # ───────────────────────────────────────────────────────────────────────────
  # 3. The filter is `unique = 0 AND origin = 'c'`, and NOT the `HAVING COUNT(*) = 1` / `partial = 0`
  #    pair that `_sqlite_single_column_indexed_columns` adds. That reader answers "is this column
  #    `db_index = true`?"; this lookup answers "may PormG drop this index?", and a composite or
  #    partial index is droppable AND blocking — SQLite refuses `DROP COLUMN` on ANY indexed column,
  #    so the field-deletion caller needs both found. Copying the reader's filter wholesale would
  #    have broken that path silently, in a file this one never touches.
  # ───────────────────────────────────────────────────────────────────────────
  @testset "SQLite: composite and partial indexes stay visible to the lookup" begin
    mktempdir() do dir
      pool = SQLiteConnectionPool(joinpath(dir, "ruq515arity.sqlite"); pool_size = 1)
      try
        fetch(pool, """CREATE TABLE "t" ("a" INTEGER, "b" INTEGER, "c" INTEGER, "d" INTEGER)""")
        fetch(pool, """CREATE INDEX "t_ab_idx" ON "t" ("a", "b")""")          # composite, plain
        fetch(pool, """CREATE INDEX "t_c_part_idx" ON "t" ("c") WHERE "c" > 0""")  # partial, plain

        @test get_constraints_index(pool, :t, "a") == "t_ab_idx"      # composite member
        @test get_constraints_index(pool, :t, "b") == "t_ab_idx"
        @test get_constraints_index(pool, :t, "c") == "t_c_part_idx"  # partial
        @test get_constraints_index(pool, :t, "d") === nothing        # genuinely unindexed
      finally
        close_pool!(pool)
      end
    end
  end

  # ───────────────────────────────────────────────────────────────────────────
  # 4. The `unique = 0` half, which `origin = 'c'` alone would not give. A `CREATE UNIQUE INDEX` IS
  #    origin `'c'` — PormG did not write it, but a user or an imported schema may have — and
  #    dropping it destroys uniqueness on a column that never set `field.unique`. This is the case a
  #    declared-side `!new_field.unique` guard at the rename call site would have missed entirely,
  #    and the reason the fix went into the lookup instead.
  # ───────────────────────────────────────────────────────────────────────────
  @testset "SQLite: a CREATE UNIQUE INDEX column is refused too, not just an auto-index" begin
    mktempdir() do dir
      pool = SQLiteConnectionPool(joinpath(dir, "ruq515uix.sqlite"); pool_size = 1)
      try
        fetch(pool, """CREATE TABLE "t" ("a" INTEGER, "b" INTEGER)""")
        fetch(pool, """CREATE UNIQUE INDEX "t_a_uq" ON "t" ("a")""")
        fetch(pool, """CREATE INDEX "t_b_idx" ON "t" ("b")""")

        # origin 'c' for both; only `unique` separates them.
        origins = fetch(pool, """PRAGMA index_list("t")""") |> DataFrame
        @test all(String(o) == "c" for o in origins.origin)

        @test get_constraints_index(pool, :t, "a") === nothing   # unique index — not ours to drop
        @test get_constraints_index(pool, :t, "b") == "t_b_idx"  # plain — is
      finally
        close_pool!(pool)
      end
    end
  end

  # ───────────────────────────────────────────────────────────────────────────
  # 5. The PostgreSQL query's SHAPE. A mock has no catalog, so what is provable here is that the
  #    query stopped being the thing the issue describes: it is parameterized (values arrive beside
  #    the SQL rather than interpolated into it), it no longer matches on `indexdef` text, and it
  #    carries the constraint-backing exclusions.
  #
  #    Behaviour against a real catalog was measured separately, against `db_2`, while this was
  #    written: `case_preserve_parent_scratch.driverRef` (UNIQUE, not PK) answers `nothing`, while
  #    `case_preserve_child_scratch.parentRef` (plain index) answers its index name. Integration
  #    Phase 4j is what keeps that true.
  # ───────────────────────────────────────────────────────────────────────────
  @testset "PostgreSQL: the lookup is parameterized and excludes constraint-backed indexes" begin
    RUQ_LAST_SQL[] = ""
    RUQ_LAST_PARAMS[] = nothing
    @test get_constraints_index(RUQ_PG, :child_t, "old_code") === nothing

    sql = RUQ_LAST_SQL[]
    # Parameterized: the table and column arrive as values, not as text spliced into the statement.
    @test RUQ_LAST_PARAMS[] == ["child_t", "old_code"]
    @test !occursin("child_t", sql)
    @test !occursin("old_code", sql)
    # The unanchored substring match is gone, replaced by real column membership.
    @test !occursin("indexdef", sql)
    @test !occursin("LIKE", sql)
    @test occursin("pg_attribute", sql)
    @test occursin("attname", sql)
    # …and the constraint-backing index cannot come back, in any of its three shapes.
    @test occursin("NOT i.indisunique", sql)
    @test occursin("NOT i.indisprimary", sql)
    @test occursin("pg_constraint", sql)
    # Deterministic, so `result[1, …]` means something.
    @test occursin("ORDER BY", sql)
  end

  # ───────────────────────────────────────────────────────────────────────────
  # 6. `_drop_index` no longer emits `ALTER TABLE … DROP CONSTRAINT IF EXISTS` on PostgreSQL. That
  #    statement was the destroyer: it is how you drop a constraint-backed index, and on an ordinary
  #    indexed column it was a harmless NOTICE, which is why it went unnoticed for so long.
  #
  #    Driven through the explicit `index_name` kwarg — the deleted-`db_index` path's spelling —
  #    because the mock's empty catalog would otherwise make `_drop_index` return before emitting
  #    anything, and a testset that asserts on an absent statement by never reaching it is green
  #    theater. Both backends must now render the same single statement.
  # ───────────────────────────────────────────────────────────────────────────
  @testset "PostgreSQL: dropping an index no longer drops a constraint first" begin
    plan = Migrations.OrderedDict{Symbol, Migrations.OrderedDict{String, String}}()
    _drop_index(RUQ_PG, plan, :child_t, "old_code"; index_name = "child_t_old_code_ruq_idx")
    step = _ruq_step(plan, :child_t, "Remove index on old_code")

    @test occursin("DROP INDEX IF EXISTS", step)
    @test occursin("child_t_old_code_ruq_idx", step)
    @test !occursin("DROP CONSTRAINT", step)
    @test !occursin("ALTER TABLE", step)

    # Byte-identical to SQLite's, now that there is no backend branch left in the function.
    mktempdir() do dir
      pool = SQLiteConnectionPool(joinpath(dir, "ruq515par.sqlite"); pool_size = 1)
      try
        sl_plan = Migrations.OrderedDict{Symbol, Migrations.OrderedDict{String, String}}()
        _drop_index(pool, sl_plan, :child_t, "old_code"; index_name = "child_t_old_code_ruq_idx")
        @test _ruq_step(sl_plan, :child_t, "Remove index on old_code") == step
      finally
        close_pool!(pool)
      end
    end
  end
end

@testset "A new ForeignKey column on an existing SQLite table gets its constraint (#514)" begin

  # ───────────────────────────────────────────────────────────────────────────
  # 7. The issue's own measurement, inverted. It reported the emitted plan and then
  #    `ANY REFERENCES: false`; this asserts the clause is there AND that the database agrees after
  #    the plan runs. The `PRAGMA foreign_key_list` row is the assertion — the DDL string could be
  #    right and the constraint still absent if SQLite quietly declined the `ADD COLUMN`.
  # ───────────────────────────────────────────────────────────────────────────
  @testset "SQLite: a nullable new key is inlined on ADD COLUMN and is live afterwards" begin
    mktempdir() do dir
      pool = SQLiteConnectionPool(joinpath(dir, "ruq514ok.sqlite"); pool_size = 1)
      try
        fetch(pool, """CREATE TABLE "parent_t" (
                         "id" INTEGER PRIMARY KEY AUTOINCREMENT UNIQUE NOT NULL,
                         "n"  INTEGER NOT NULL)""")
        fetch(pool, """CREATE TABLE "child_t" (
                         "id"   INTEGER PRIMARY KEY AUTOINCREMENT UNIQUE NOT NULL,
                         "note" TEXT(40) NOT NULL)""")
        fetch(pool, """INSERT INTO "parent_t" ("id", "n") VALUES (7, 70)""")
        fetch(pool, """INSERT INTO "child_t" ("id", "note") VALUES (1, 'keep-me')""")

        declared = Models.Model("child_t", id = Models.IDField(),
                     note = Models.CharField(max_length = 40),
                     fresh_ref_id = Models.ForeignKey(_ruq_parent(); pk_field = "id", null = true))
        livem    = Models.Model("child_t", id = Models.IDField(),
                     note = Models.CharField(max_length = 40))
        plan = _ruq_plan(pool, livem, declared)

        add_step = _ruq_step(plan, :child_t, "Add field: fresh_ref_id")
        @test occursin("ADD COLUMN", add_step)
        @test occursin("REFERENCES \"parent_t\"(\"id\")", add_step)
        @test occursin("ON DELETE", add_step)
        # The cheap path, NOT a rebuild — a rebuild would render the clause too and satisfy the
        # count below, so the phase must not pass by quietly rebuilding the whole table.
        @test !("Alter table: child_t" in _ruq_steps(plan, :child_t))
        @test !occursin("CREATE TABLE", _ruq_text(plan, :child_t))

        _ruq_apply!(pool, plan, :child_t)

        fks = fetch(pool, """PRAGMA foreign_key_list("child_t")""") |> DataFrame
        @test nrow(fks) == 1
        @test String(fks[1, :table]) == "parent_t"
        @test String(fks[1, :from]) == "fresh_ref_id"
        @test String(fks[1, :to]) == "id"

        # The existing row is untouched, and the new column is nullable as declared.
        rows = fetch(pool, """SELECT "note", "fresh_ref_id" FROM "child_t" WHERE "id" = 1""") |> DataFrame
        @test nrow(rows) == 1
        @test isequal(rows[1, :note], "keep-me")
      finally
        close_pool!(pool)
      end
    end
  end

  # ───────────────────────────────────────────────────────────────────────────
  # 8. Convergence, which matters more than the acceptance list says. This bug class — the DDL is
  #    right and the next `makemigrations` proposes it again forever — is the one #507 exists to end,
  #    and a fix that emits a correct clause the readers cannot recognise trades a silent gap for
  #    permanent churn. Re-plans against the LIVE schema read back by introspection, not against a
  #    hand-built model, because reading it back is exactly the step that could disagree.
  #
  #    This is also the testset that corrected #514's diagnosis (see the file header): against the
  #    unfixed planner it fails, because round two plans `Alter table: child_t` — the whole-table
  #    rebuild the issue believed would never be proposed.
  #
  #    Scoped to the column this issue adds rather than asserting an empty plan: unrelated
  #    reader/renderer asymmetries on this fixture are #507's business, and an empty-plan assertion
  #    would fail on them rather than on anything #514 did.
  # ───────────────────────────────────────────────────────────────────────────
  @testset "SQLite: the newly added key does not churn on the next makemigrations" begin
    mktempdir() do dir
      pool = SQLiteConnectionPool(joinpath(dir, "ruq514conv.sqlite"); pool_size = 1)
      try
        fetch(pool, """CREATE TABLE "parent_t" (
                         "id" INTEGER PRIMARY KEY AUTOINCREMENT UNIQUE NOT NULL,
                         "n"  INTEGER NOT NULL)""")
        fetch(pool, """CREATE TABLE "child_t" (
                         "id"   INTEGER PRIMARY KEY AUTOINCREMENT UNIQUE NOT NULL,
                         "note" TEXT(40) NOT NULL)""")

        declared = Models.Model("child_t", id = Models.IDField(),
                     note = Models.CharField(max_length = 40),
                     fresh_ref_id = Models.ForeignKey(_ruq_parent(); pk_field = "id", null = true))
        livem    = Models.Model("child_t", id = Models.IDField(),
                     note = Models.CharField(max_length = 40))
        _ruq_apply!(pool, _ruq_plan(pool, livem, declared), :child_t)

        # Round two, against what the database actually holds now.
        live_again = convertSQLToModel(pool, "child_t")
        settled = _ruq_plan(pool, live_again, declared)
        @test !occursin("fresh_ref_id", _ruq_text(settled, :child_t))
      finally
        close_pool!(pool)
      end
    end
  end

  # ───────────────────────────────────────────────────────────────────────────
  # 9. The other half of the fix. SQLite will not take an inline `REFERENCES` on a column that has a
  #    default — its rule is that such a column "must have a default value of NULL" — so a NOT NULL
  #    key with a default routes through the table rebuild instead, which re-renders every
  #    `FOREIGN KEY` clause from the desired model.
  #
  #    STATED LIMIT, so this testset is not read as covering more than it does: the rebuild is queued
  #    AFTER the `ADD COLUMN`, and SQLite separately refuses `ADD COLUMN … UNIQUE` and
  #    `ADD COLUMN … NOT NULL`-without-a-default whether or not a key is involved. Those two shapes
  #    still abort on the first statement, exactly as before #514 — that refusal is about the column,
  #    not the constraint, and is filed rather than widened into here.
  # ───────────────────────────────────────────────────────────────────────────
  @testset "SQLite: a key SQLite cannot inline is routed through the table rebuild" begin
    mktempdir() do dir
      pool = SQLiteConnectionPool(joinpath(dir, "ruq514rebuild.sqlite"); pool_size = 1)
      try
        fetch(pool, """CREATE TABLE "parent_t" (
                         "id" INTEGER PRIMARY KEY AUTOINCREMENT UNIQUE NOT NULL,
                         "n"  INTEGER NOT NULL)""")
        fetch(pool, """CREATE TABLE "child_t" (
                         "id"   INTEGER PRIMARY KEY AUTOINCREMENT UNIQUE NOT NULL,
                         "note" TEXT(40) NOT NULL)""")
        fetch(pool, """INSERT INTO "parent_t" ("id", "n") VALUES (7, 70)""")
        fetch(pool, """INSERT INTO "child_t" ("id", "note") VALUES (1, 'keep-me')""")

        declared = Models.Model("child_t", id = Models.IDField(),
                     note = Models.CharField(max_length = 40),
                     hard_ref_id = Models.ForeignKey(_ruq_parent(); pk_field = "id",
                                                     null = false, default = 7))
        livem    = Models.Model("child_t", id = Models.IDField(),
                     note = Models.CharField(max_length = 40))
        plan = _ruq_plan(pool, livem, declared)

        # The bare column, with no inline clause SQLite would have rejected…
        add_step = _ruq_step(plan, :child_t, "Add field: hard_ref_id")
        @test occursin("ADD COLUMN", add_step)
        @test !occursin("REFERENCES", add_step)
        # …and the rebuild that carries the key instead.
        rebuild = _ruq_step(plan, :child_t, "Alter table: child_t")
        @test occursin("FOREIGN KEY (\"hard_ref_id\")", rebuild)
        @test occursin("REFERENCES \"parent_t\"(\"id\")", rebuild)

        _ruq_apply!(pool, plan, :child_t)

        fks = fetch(pool, """PRAGMA foreign_key_list("child_t")""") |> DataFrame
        @test nrow(fks) == 1
        @test String(fks[1, :from]) == "hard_ref_id"
        # The rebuild copied the data across rather than starting the table over.
        rows = fetch(pool, """SELECT "note", "hard_ref_id" FROM "child_t" WHERE "id" = 1""") |> DataFrame
        @test nrow(rows) == 1
        @test isequal(rows[1, :note], "keep-me")
        @test isequal(rows[1, :hard_ref_id], 7)

        # The new column's OWN index survives the rebuild. `ForeignKey` defaults `db_index = true`,
        # so this path queues a CREATE INDEX and a whole-table rebuild in one migration — and the
        # rebuild re-creates only the indexes it snapshotted BEFORE that CREATE INDEX existed. #152's
        # deferral is what saves it, and this assertion is what proves the new rebuild trigger did
        # not step outside that protection. Replay the same plan in plan-dict order instead and the
        # index is gone, permanently and silently, with `makemigrations` converged afterwards.
        idx_names = string.((fetch(pool, """PRAGMA index_list("child_t")""") |> DataFrame).name)
        @test any(n -> occursin("hard_ref_id", n), idx_names)
        @test get_constraints_index(pool, :child_t, "hard_ref_id") !== nothing
      finally
        close_pool!(pool)
      end
    end
  end

  # ───────────────────────────────────────────────────────────────────────────
  # 10. `db_constraint = false` means "an integer column that happens to hold a key" — the model
  #     declares the relationship for the query builder and asks the database to enforce nothing.
  #     A fix that renders `REFERENCES` for every relational field would enforce it anyway, silently
  #     reversing an explicit opt-out, and would then churn against a reader that correctly sees no
  #     constraint. Neither the inline clause nor a rebuild may appear.
  # ───────────────────────────────────────────────────────────────────────────
  @testset "SQLite: db_constraint = false still creates no constraint and no rebuild" begin
    mktempdir() do dir
      pool = SQLiteConnectionPool(joinpath(dir, "ruq514nocon.sqlite"); pool_size = 1)
      try
        fetch(pool, """CREATE TABLE "parent_t" (
                         "id" INTEGER PRIMARY KEY AUTOINCREMENT UNIQUE NOT NULL,
                         "n"  INTEGER NOT NULL)""")
        fetch(pool, """CREATE TABLE "child_t" (
                         "id"   INTEGER PRIMARY KEY AUTOINCREMENT UNIQUE NOT NULL,
                         "note" TEXT(40) NOT NULL)""")

        declared = Models.Model("child_t", id = Models.IDField(),
                     note = Models.CharField(max_length = 40),
                     loose_ref_id = Models.ForeignKey(_ruq_parent(); pk_field = "id", null = true,
                                                      db_constraint = false))
        livem    = Models.Model("child_t", id = Models.IDField(),
                     note = Models.CharField(max_length = 40))
        plan = _ruq_plan(pool, livem, declared)

        @test !occursin("REFERENCES", _ruq_text(plan, :child_t))
        @test !("Alter table: child_t" in _ruq_steps(plan, :child_t))

        _ruq_apply!(pool, plan, :child_t)
        @test nrow(fetch(pool, """PRAGMA foreign_key_list("child_t")""") |> DataFrame) == 0
      finally
        close_pool!(pool)
      end
    end
  end

  # ───────────────────────────────────────────────────────────────────────────
  # 11b. Two new columns in one migration, one of them rebuild-triggering.
  #
  #     The rebuild's `CREATE TABLE` is rendered from the DESIRED model, so it already declares every
  #     new column — which means every `ADD COLUMN` for the table has to run BEFORE it. The plan kept
  #     that true only while the field being processed was itself rebuild-triggering; a plain column
  #     processed afterwards appended its `ADD COLUMN` past the rebuild and aborted with
  #     `duplicate column name`. `colect_addition` comes from a `Set`, so which field lands first is
  #     hash order — the same migration failed or passed depending on the column names.
  #
  #     Pre-existing (the only trigger used to be a new `sDateTimeField`/`sDateField`), but #514
  #     widened the trigger set to every new SQLite key that cannot be inlined, and adding a keyed
  #     column beside an ordinary one is routine. Several column names are swept because a single
  #     name only samples one hash order and would pass by luck.
  # ───────────────────────────────────────────────────────────────────────────
  @testset "SQLite: a rebuild-triggering key and a plain column can be added together" begin
    for extra in ("atag", "b", "zz", "tag", "extra")
      mktempdir() do dir
        pool = SQLiteConnectionPool(joinpath(dir, "ruq514two_$extra.sqlite"); pool_size = 1)
        try
          fetch(pool, """CREATE TABLE "parent_t" (
                           "id" INTEGER PRIMARY KEY AUTOINCREMENT UNIQUE NOT NULL,
                           "n"  INTEGER NOT NULL)""")
          fetch(pool, """CREATE TABLE "child_t" (
                           "id"   INTEGER PRIMARY KEY AUTOINCREMENT UNIQUE NOT NULL,
                           "note" TEXT(40) NOT NULL)""")
          fetch(pool, """INSERT INTO "parent_t" ("id", "n") VALUES (7, 70)""")
          fetch(pool, """INSERT INTO "child_t" ("id", "note") VALUES (1, 'keep-me')""")

          # `Model(name; fields...)` splatted, so the plain column's NAME can vary per iteration.
          declared = Models.Model("child_t"; NamedTuple{(:id, :note, :hard_ref_id, Symbol(extra))}((
            Models.IDField(), Models.CharField(max_length = 40),
            Models.ForeignKey(_ruq_parent(); pk_field = "id", null = false, default = 7),
            Models.CharField(null = true)))...)
          livem = Models.Model("child_t", id = Models.IDField(),
                    note = Models.CharField(max_length = 40))
          plan = _ruq_plan(pool, livem, declared)

          # Every ADD COLUMN precedes the rebuild in the plan dict — the invariant, asserted directly
          # so a failure names the cause rather than only the SQLite error it produces.
          steps = _ruq_steps(plan, :child_t)
          rebuild_at = findfirst(==("Alter table: child_t"), steps)
          @test rebuild_at !== nothing
          @test all(i -> !startswith(steps[i], "Add field:"),
                    (rebuild_at + 1):length(steps))

          # And it really applies: pre-fix this raised `duplicate column name: <extra>`.
          _ruq_apply!(pool, plan, :child_t)

          cols = string.((fetch(pool, """PRAGMA table_info("child_t")""") |> DataFrame).name)
          @test "hard_ref_id" in cols
          @test extra in cols
          @test nrow(fetch(pool, """PRAGMA foreign_key_list("child_t")""") |> DataFrame) == 1
          # The pre-existing row came through the rebuild intact.
          rows = fetch(pool, """SELECT "note" FROM "child_t" WHERE "id" = 1""") |> DataFrame
          @test nrow(rows) == 1
          @test isequal(rows[1, :note], "keep-me")
        finally
          close_pool!(pool)
        end
      end
    end
  end

  # ───────────────────────────────────────────────────────────────────────────
  # 11. The PostgreSQL control. #514 is a SQLite divergence, so the measure of the fix is that
  #     PostgreSQL is exactly as it was: its key still arrives as a separate, NAMED
  #     `ADD CONSTRAINT … FOREIGN KEY … DEFERRABLE INITIALLY DEFERRED`, and its `ADD COLUMN` carries
  #     no inline clause. An inline clause here would be a SECOND constraint on the same column, the
  #     shape #504 spent a whole issue removing.
  # ───────────────────────────────────────────────────────────────────────────
  @testset "PostgreSQL: unchanged — a separate ADD CONSTRAINT, no inline clause" begin
    declared = Models.Model("child_t", id = Models.IDField(),
                 note = Models.CharField(max_length = 40),
                 fresh_ref_id = Models.ForeignKey(_ruq_parent(); pk_field = "id", null = true))
    livem    = Models.Model("child_t", id = Models.IDField(),
                 note = Models.CharField(max_length = 40))
    plan = _ruq_plan(RUQ_PG, livem, declared)

    add_step = _ruq_step(plan, :child_t, "Add field: fresh_ref_id")
    @test occursin("ADD COLUMN", add_step)
    @test !occursin("REFERENCES", add_step)          # the `model` kwarg is accepted and ignored here

    fk_step = _ruq_step(plan, :child_t, "New foreign key: fresh_ref_id")
    @test occursin("ADD CONSTRAINT", fk_step)
    @test occursin("FOREIGN KEY", fk_step)
    @test occursin("REFERENCES", fk_step)
    @test occursin("DEFERRABLE INITIALLY DEFERRED", fk_step)
    # And no rebuild: `_add_new_field`'s new branch is gated on `conn isa PormGSQLite`.
    @test !("Alter table: child_t" in _ruq_steps(plan, :child_t))
  end
end
