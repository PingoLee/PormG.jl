"""
Unit coverage for the two constraint-ACTION bugs in `src/migrations/planner.jl`, which sit a few
lines apart and ship together.

#504 — a field RENAME whose foreign key did not change planned a second constraint. The rename
branch of `_resolve_table_fields` pairs an action-aware DROP with an unconditional ADD:

    _drop_fk_constraint_in_alteration(…)   -> asks `_fk_constraint_action`; `:none` => declines
    Dialect.rename_field(…)                -> ALTER TABLE … RENAME COLUMN …
    _add_constrains(…)                     -> asked nothing; ADDs for any `db_constraint = true`

PostgreSQL's `RENAME COLUMN` carries the live FOREIGN KEY along with the column, so the ADD landed
a SECOND, identical constraint beside it — under a fresh name, while the original kept its
pre-rename one. Nothing ever proposes dropping either: both describe the same parent with the same
action, so `makemigrations` sees a converged model forever. `_add_constrains` now takes the
pre-rename field and consults the SAME decision function the DROP does.

#505 — the SQLite `:add` branch of `_add_fk_constraint_in_alteration` warned that adding a foreign
key "requires recreation. This is not fully automated yet." The recreation happens: the function's
ONE call site is inside `_alter_table_fields`' `if !isempty(colect_not_equal)` block, which has
already emitted the full table rebuild from the DESIRED model, and that rebuild re-renders every
`FOREIGN KEY … REFERENCES` clause. Testset 7 is the measurement, against a real temp SQLite file,
so the false claim cannot come back untested.

TWO THINGS ABOUT THIS HARNESS, both load-bearing:

  * The PostgreSQL mock needs a `fetch` with a CATCH-ALL, not just an answer for the FK catalog
    probe. `_drop_index` fires unconditionally on the rename path and issues its own
    `get_constraints_index` query; a mock that matches only `get_constraints_fk` raises a
    `MethodError` from inside `makemigrations`.
  * Every fixture below uses a plain, NON-UNIQUE `ForeignKey` with a long column name, on purpose.
    When this file was written that was a dodge: `_drop_index` on a `unique` renamed column dropped
    the constraint's backing index — silently destroying the UNIQUE constraint on PostgreSQL and
    aborting the migration on SQLite — and `get_constraints_index` matched `indexdef LIKE '%<col>%'`
    unanchored, so a short name could match a neighbouring index. Either would have failed these
    tests in a way that looked like #504. Both are fixed (#515), and
    `test/unit/test_rename_unique_index.jl` plus integration Phase 4j are what keep them fixed. The
    fixtures stay as they are anyway — this file is #504/#505's, and widening it would blur which
    bug a failure belongs to.

MOCK LIMIT, stated rather than papered over. Both SQLite testsets need a real temp file, for
DIFFERENT reasons: testset 6 because `_drop_index` asks the connection for `PRAGMA index_list`, and
testset 7 because the rebuild additionally asks it for the live secondary-index DDL. A bare marker
struct answers neither.

And EVERY model below is hand-built, on both engines — so a "live" foreign key here exists only in
Julia. These testsets therefore prove what is PLANNED, which is where both bugs live. That the
surviving constraint is really on the table afterwards is integration Phase 4i's job, against a real
catalog on both backends.
"""

using Test
using Logging
using DataFrames
using PormG
using PormG.Models
using PormG.Migrations
import PormG: PormGModel, PormGPostgres, PormGSQLite
# Testsets 6 and 7 open a real (temporary) SQLite file, so they need the weakdep extension.
# `runtests.jl` loads it for the whole suite; this guard is what makes the file runnable alone.
isdefined(Main, :SQLite) || include(joinpath(@__DIR__, "..", "load_drivers.jl"))
import PormG.ConnectionPool: SQLiteConnectionPool, fetch
import PormG.Migrations: _fk_constraint_action

# `_fca_`-prefixed throughout: `runtests.jl` includes every unit file into ONE module, so a bare
# `MockPostgres` or `_parent()` silently redefines a sibling's.
struct FkConstraintActionsMockPg504 <: PormGPostgres end
const FCA_PG = FkConstraintActionsMockPg504()

# The name the catalog hands back for the LIVE constraint on the OLD column. A DROP can only learn
# it by asking — `_hash_field_name` ends in `randstring(8)`, so nothing can re-derive it.
const FCA_LIVE_CONSTRAINT = "child_t_old_ref_id_0ld00504_fk"

function fetch(connection::FkConstraintActionsMockPg504, sql::String;
  conn = nothing,
  params = nothing,
  ignore_tx::Bool = false)

  if occursin("constraint_type = 'FOREIGN KEY'", sql)
    # `get_constraints_fk` is parameterized, so the values arrive separately. Answer only for the
    # column under test, so a stray lookup cannot silently satisfy an assertion.
    params !== nothing && length(params) == 2 && params[2] == "old_ref_id" &&
      return DataFrame(constraint_name = [FCA_LIVE_CONSTRAINT])
    return DataFrame()
  end

  # The catch-all. `get_constraints_index(::PormGPostgres)` lands here — since #515 a parameterized
  # `pg_index` join, so its values arrive in `params` and are ignored along with everything else —
  # and an empty frame means "no live index", which keeps these plans to the FK story.
  return DataFrame()
end

# The two parents every key below points at. `declared` carries a RESOLVED `PormGModel` in `.to`
# (what `set_models` leaves behind); `live` carries the target's binding STRING plus the `to_table`
# breadcrumb (what introspection records).
_fca_parent()       = Models.Model("parent_t",       id = Models.IDField(), n = Models.IntegerField())
_fca_other_parent() = Models.Model("other_parent_t", id = Models.IDField(), n = Models.IntegerField())

_fca_declared_fk(parent = _fca_parent(); kwargs...) =
  Models.ForeignKey(parent; pk_field = "id", null = true, kwargs...)

# The live (introspected) side: a constrained ForeignKey shaped the way a reader produces one.
function _fca_live_fk(; to_table = "parent_t", pk_field = "id", on_delete = nothing, null = true)
  live = Models.ForeignKey("Parent_t"; pk_field = pk_field, null = null, on_delete = on_delete)
  live.to_table = to_table
  return live
end

# Build the two models the planner diffs and return the plan for `child_t`. `get_migration_plan`
# takes the LIVE models first and the DECLARED ones in `current_schema` — the same (deliberately
# confusing) argument order the planner itself uses.
#
# The declared side calls the column `new_ref_id` and the live side `old_ref_id`: one addition plus
# one deletion on the same table is what offers the rename. Driven through stdin because a rename is
# only ever PROPOSED interactively — `interactive = false` answers "no" and takes the add-a-new-field
# path instead. Same technique as integration Phase 4e.
function _fca_rename_plan(conn, declared_rel, live_rel)
  settings = PormG.Configuration.Settings()
  settings.change_db = true
  # `note` is identical on both sides: the RENAME is the only difference, so nothing else can open
  # the alteration gate and contribute a step these assertions might mistake for the FK's.
  declared = Models.Model("child_t", id = Models.IDField(), new_ref_id = declared_rel, note = Models.CharField(max_length = 40))
  livem    = Models.Model("child_t", id = Models.IDField(), old_ref_id = live_rel,     note = Models.CharField(max_length = 40))
  current_schema = Dict{Symbol, Dict{Symbol, Union{Bool, PormGModel}}}(
    :child_t => Dict{Symbol, Union{Bool, PormGModel}}(:model => declared, :exist => false))

  # "1" is the only rename candidate on offer (`old_ref_id`); EOF would answer "no" instead.
  path, io = mktemp(); write(io, "1\n"); close(io)
  return open(path) do stdin_file
    redirect_stdin(stdin_file) do
      Migrations.get_migration_plan(PormGModel[livem], current_schema, conn, settings; interactive = true)
    end
  end
end

_fca_keys(plan) = haskey(plan, :child_t) ? collect(keys(plan[:child_t])) : String[]
_fca_step(plan, key) = haskey(plan, :child_t) ? get(plan[:child_t], key, "") : ""
_fca_drop(plan) = _fca_step(plan, "Remove foreign key: old_ref_id")
_fca_add(plan)  = _fca_step(plan, "New foreign key: new_ref_id")

# #507 phase 2: `_fk_constraint_action` reads the canonical column IR rather than two field
# structs, so the preconditions below compile their pair first. That compile step is what the
# planner itself now does, and it is why the decision cannot disagree with the delta the same
# action path renders from.
_fca_action(declared, live) =
  _fk_constraint_action(PormG.Migrations.column_spec(declared, FCA_PG; name = "new_ref_id"),
                        PormG.Migrations.column_spec(live, FCA_PG; name = "old_ref_id"))

@testset "#504/#505: foreign-key constraint actions on the rename and alteration paths" begin

  # ───────────────────────────────────────────────────────────────────────────
  # 1. THE MUTATION GATE for #504: a rename whose FK definition is UNCHANGED must plan the rename
  #    and NOTHING about the constraint. `_fk_constraint_action` already answered `:none` here
  #    before the fix — the DROP declined correctly and `_add_constrains` ADDed anyway, so
  #    PostgreSQL ended up with the carried-along original plus a fresh duplicate. Against the
  #    unfixed code the "no ADD" assertion below fails.
  #
  #    #507 phase 2 changed WHY it passes, and this testset is the reason to record that. #504
  #    fixed it by teaching `_add_constrains` to consult the pre-rename field; phase 2 removed the
  #    caller instead. The rename branch routes through `_plan_column_change!` — the same ordered
  #    path the alteration loop uses — so the ADD is `_fk_constraint_action`'s `:none` and emits
  #    nothing, and `_add_constrains` no longer has a parameter for a live column at all. The
  #    assertions are unchanged because the behaviour is; what moved is that there is now no way to
  #    express the bug.
  # ───────────────────────────────────────────────────────────────────────────
  @testset "a rename with an unchanged FK definition adds no second constraint" begin
    # Same parent, same target column, same (absent) ON DELETE — only the column NAME moves.
    declared = _fca_declared_fk()
    live     = _fca_live_fk()
    # Precondition, asserted rather than assumed: this pair really is the `:none` state. If the
    # comparators ever stopped agreeing, the testset below would pass for the wrong reason.
    @test _fca_action(declared, live) === :none

    plan = _fca_rename_plan(FCA_PG, declared, live)

    # The rename itself is planned, and names both columns.
    @test occursin("RENAME COLUMN \"old_ref_id\" TO \"new_ref_id\"",
                   _fca_step(plan, "Rename field: new_ref_id"))
    # THE assertion #504 exists for: no ADD CONSTRAINT beside the one RENAME COLUMN carried over.
    @test !("New foreign key: new_ref_id" in _fca_keys(plan))
    # …and still no DROP, which is what makes skipping the ADD correct rather than merely quieter.
    @test !("Remove foreign key: old_ref_id" in _fca_keys(plan))
  end

  # ───────────────────────────────────────────────────────────────────────────
  # 2. BEHAVIOUR PRESERVATION — `:repoint`. A rename that ALSO moves the key to another parent is
  #    the case #498 fixed, and the #504 gate must not over-reach past it: the DROP names the OLD
  #    column (that is what the live catalog knows it by) and the ADD the NEW one.
  # ───────────────────────────────────────────────────────────────────────────
  @testset "a rename that also re-points still plans DROP + ADD" begin
    declared = _fca_declared_fk(_fca_other_parent())
    live     = _fca_live_fk()
    @test _fca_action(declared, live) === :repoint

    plan = _fca_rename_plan(FCA_PG, declared, live)

    @test occursin("DROP CONSTRAINT \"$(FCA_LIVE_CONSTRAINT)\"", _fca_drop(plan))
    @test occursin("REFERENCES \"other_parent_t\" (\"id\")", _fca_add(plan))
    # Insertion order: DROP, RENAME, ADD. (`runner._order_statements` later hoists "Rename field"
    # into an earlier bucket, so what EXECUTES is RENAME, DROP, ADD — also correct, since
    # `DROP CONSTRAINT` is by constraint name and a renamed column carries its constraint along.)
    steps = _fca_keys(plan)
    @test findfirst(==("Remove foreign key: old_ref_id"), steps) <
          findfirst(==("Rename field: new_ref_id"), steps) <
          findfirst(==("New foreign key: new_ref_id"), steps)
  end

  # ───────────────────────────────────────────────────────────────────────────
  # 3. BEHAVIOUR PRESERVATION — `:add`. Renaming a plain column into a constrained foreign key must
  #    still ADD: there was no live constraint for `RENAME COLUMN` to carry along.
  # ───────────────────────────────────────────────────────────────────────────
  @testset "a rename that turns a plain column into a foreign key still adds the constraint" begin
    declared = _fca_declared_fk()
    live     = Models.BigIntegerField(null = true)
    @test _fca_action(declared, live) === :add

    plan = _fca_rename_plan(FCA_PG, declared, live)

    @test occursin("REFERENCES \"parent_t\" (\"id\")", _fca_add(plan))
    @test !("Remove foreign key: old_ref_id" in _fca_keys(plan))
  end

  # ───────────────────────────────────────────────────────────────────────────
  # 4. BEHAVIOUR PRESERVATION — `:drop`. A rename that flips `db_constraint` true→false drops the
  #    live constraint and adds nothing. This was already correct (`_add_constrains`' own
  #    `field.db_constraint` test refuses it), and pinning it is what proves the new gate did not
  #    become the only thing standing between this case and a spurious ADD.
  # ───────────────────────────────────────────────────────────────────────────
  @testset "a rename that drops the constraint plans the DROP and no ADD" begin
    declared = _fca_declared_fk(; db_constraint = false)
    live     = _fca_live_fk()
    @test _fca_action(declared, live) === :drop

    plan = _fca_rename_plan(FCA_PG, declared, live)

    @test occursin("DROP CONSTRAINT \"$(FCA_LIVE_CONSTRAINT)\"", _fca_drop(plan))
    @test !("New foreign key: new_ref_id" in _fca_keys(plan))
  end

  # ───────────────────────────────────────────────────────────────────────────
  # 5. THE GATE FOR A BRAND-NEW COLUMN. `_add_constrains` must always add the key for a column this
  #    migration is creating — there is no live constraint to inherit. #504 expressed that as the
  #    default of an `old_field` keyword; #507 phase 2 deleted the keyword, because after the rename
  #    branch moved to `_plan_column_change!` every remaining caller (`_add_new_table`,
  #    `_add_new_field`) is creating the column. So the property is no longer "the default means
  #    always add" but "this function only ever sees new columns" — and it still needs pinning,
  #    because a regression here silently stops creating foreign keys on ADD COLUMN, which no other
  #    testset in this file would notice.
  #
  #    No rename is offered: there is an addition and NO deletion, so this runs non-interactively.
  # ───────────────────────────────────────────────────────────────────────────
  @testset "adding a brand-new foreign-key field still creates the constraint" begin
    settings = PormG.Configuration.Settings()
    settings.change_db = true
    declared = Models.Model("child_t", id = Models.IDField(),
                 old_ref_id   = _fca_declared_fk(),
                 note         = Models.CharField(max_length = 40),
                 extra_ref_id = _fca_declared_fk())
    livem    = Models.Model("child_t", id = Models.IDField(),
                 old_ref_id = _fca_live_fk(),
                 note       = Models.CharField(max_length = 40))
    current_schema = Dict{Symbol, Dict{Symbol, Union{Bool, PormGModel}}}(
      :child_t => Dict{Symbol, Union{Bool, PormGModel}}(:model => declared, :exist => false))

    plan = Migrations.get_migration_plan(PormGModel[livem], current_schema, FCA_PG, settings;
                                         interactive = false)

    @test occursin("ADD COLUMN", _fca_step(plan, "Add field: extra_ref_id"))
    @test occursin("REFERENCES \"parent_t\" (\"id\")", _fca_step(plan, "New foreign key: extra_ref_id"))
    # The untouched sibling column is not dragged along. Note WHY, because it is not this gate:
    # `_add_constrains` is never called from the ordinary diff loop at all (its three call sites are
    # `_add_new_table`, `_add_new_field` and the rename). `old_ref_id` compares equal to its live
    # side, so `colect_not_equal` stays empty, the alteration gate never opens, and
    # `_add_fk_constraint_in_alteration` is never reached either. The assertion is still worth
    # keeping — it is what would catch an ADD leaking onto every converged foreign key.
    @test !("New foreign key: old_ref_id" in _fca_keys(plan))
  end

  # ───────────────────────────────────────────────────────────────────────────
  # 6. ACCEPTANCE CRITERION 3 of #504 — SQLite, confirmed rather than assumed.
  #
  #    SQLite could never produce the duplicate, and the reason is structural: the rename's `else`
  #    branch is reachable there ONLY when `_fk_definition_changed` is false (the guard above it),
  #    and that is exactly the condition under which `_fk_constraint_action` answers `:none` —
  #    the action function delegates to the same predicate. So the only FK state that ever reaches
  #    `_add_constrains` from a SQLite rename is `:none`, and its FK block is `PormGPostgres`-only
  #    regardless. The live constraint survives because SQLite (≥ 3.25, `legacy_alter_table` off)
  #    rewrites the stored `FOREIGN KEY … REFERENCES` clause as part of `RENAME COLUMN`; there is
  #    no `ALTER TABLE ADD CONSTRAINT` in the SQLite dialect to add a second one with anyway.
  #
  #    A real temp file, not a marker struct: `_drop_index` asks the connection for `PRAGMA
  #    index_list`, and a SQLite alteration would ask for live secondary-index DDL.
  # ───────────────────────────────────────────────────────────────────────────
  @testset "SQLite plans only the rename, and no foreign-key DDL at all" begin
    mktempdir() do dir
      pool = SQLiteConnectionPool(joinpath(dir, "fkactions504.sqlite"); pool_size = 1)
      try
        fetch(pool, """CREATE TABLE "parent_t" (
                         "id" INTEGER PRIMARY KEY AUTOINCREMENT UNIQUE NOT NULL,
                         "n"  INTEGER NOT NULL)""")
        fetch(pool, """CREATE TABLE "child_t" (
                         "id"         INTEGER PRIMARY KEY AUTOINCREMENT UNIQUE NOT NULL,
                         "old_ref_id" INTEGER NULL,
                         "note"       TEXT(40) NOT NULL,
                         FOREIGN KEY ("old_ref_id") REFERENCES "parent_t"("id"))""")

        plan = _fca_rename_plan(pool, _fca_declared_fk(), _fca_live_fk())

        @test occursin("RENAME COLUMN \"old_ref_id\" TO \"new_ref_id\"",
                       _fca_step(plan, "Rename field: new_ref_id"))
        @test !("New foreign key: new_ref_id" in _fca_keys(plan))
        # And no whole-table rebuild either: an unchanged FK definition takes the CHEAP path, which
        # is what makes SQLite's outcome equivalent to PostgreSQL's rather than merely similar.
        @test !("Alter table: child_t" in _fca_keys(plan))
        # Nothing in the entire plan re-states the constraint — the clause is the live table's, and
        # SQLite keeps it.
        @test !any(occursin("REFERENCES", sql) for sql in values(plan[:child_t]))
      finally
        # Windows keeps the file handle until the pool is closed, so `mktempdir` cannot clean up.
        PormG.ConnectionPool.close_pool!(pool)
      end
    end
  end

  # ───────────────────────────────────────────────────────────────────────────
  # 7. #505 — the SQLite `:add` message, and the measurement that makes it honest.
  #
  #    A declared `ForeignKey` against a live plain `sBigIntegerField` column, with a second column
  #    changed so the alteration gate opens for the table. The rebuild emitted from the DESIRED
  #    model renders the `FOREIGN KEY … REFERENCES` clause — the key IS added — so the old text
  #    ("requires recreation. This is not fully automated yet.") told the operator to do by hand
  #    something that had already happened.
  #
  #    Asserted three ways off ONE run, via `Test.collect_test_logs` rather than `@test_logs`: the
  #    rebuild renders the clause, nothing is logged at Warn or above, and the retired sentence is
  #    absent. The last one is the issue's own acceptance wording — the claim cannot come back
  #    untested.
  # ───────────────────────────────────────────────────────────────────────────
  @testset "adding a foreign key on SQLite renders the clause and reports it accurately" begin
    mktempdir() do dir
      pool = SQLiteConnectionPool(joinpath(dir, "fkactions505.sqlite"); pool_size = 1)
      try
        fetch(pool, """CREATE TABLE "parent_t" (
                         "id" INTEGER PRIMARY KEY AUTOINCREMENT UNIQUE NOT NULL,
                         "n"  INTEGER NOT NULL)""")
        # `child_ref_id` is a PLAIN column here — no FOREIGN KEY clause. That is the live state the
        # declared model is about to add a key to.
        fetch(pool, """CREATE TABLE "child_t" (
                         "id"           INTEGER PRIMARY KEY AUTOINCREMENT UNIQUE NOT NULL,
                         "child_ref_id" BIGINT NULL,
                         "note"         TEXT(40) NOT NULL)""")

        settings = PormG.Configuration.Settings()
        settings.change_db = true
        declared = Models.Model("child_t", id = Models.IDField(),
                     child_ref_id = _fca_declared_fk(),
                     note         = Models.CharField(max_length = 40))
        livem    = Models.Model("child_t", id = Models.IDField(),
                     child_ref_id = Models.BigIntegerField(null = true),
                     note         = Models.CharField(max_length = 60))
        current_schema = Dict{Symbol, Dict{Symbol, Union{Bool, PormGModel}}}(
          :child_t => Dict{Symbol, Union{Bool, PormGModel}}(:model => declared, :exist => false))

        logs, plan = Test.collect_test_logs() do
          Migrations.get_migration_plan(PormGModel[livem], current_schema, pool, settings;
                                        interactive = false)
        end

        # 1. The rebuild really does add the key. This is the measurement #505 turns on: if this
        #    fails, the retired warning was telling the truth and the fix is wrong.
        rebuild = _fca_step(plan, "Alter table: child_t")
        @test occursin("FOREIGN KEY (\"child_ref_id\")", rebuild)
        @test occursin("REFERENCES \"parent_t\"(\"id\")", rebuild)

        # 2. Nothing at Warn or above. The message was the only Warn this path produced, and
        #    `Dialect.alter_field(::PormGSQLite, …)` ignores the difference vector rather than
        #    complaining about it (the "not implemented" warning is PostgreSQL's).
        @test !any(r -> r.level >= Logging.Warn, logs)

        # 3. The heads-up survives, at Info, and says what actually happens.
        @test any(r -> r.level == Logging.Info && occursin("rebuild", string(r.message)), logs)

        # 4. The retired claim is gone from the run, not merely from the source.
        @test !any(r -> occursin("not fully automated", string(r.message)), logs)
      finally
        PormG.ConnectionPool.close_pool!(pool)
      end
    end
  end
end
