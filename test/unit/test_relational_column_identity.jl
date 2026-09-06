"""
Unit coverage for #437 — a declared `ForeignKey(parent, unique = true)` and the `sOneToOneField` its
own live column reads back as are ONE column, and the planner must converge them.

The two spellings render byte-identical DDL, and since #417 BOTH schema readers report a UNIQUE
non-key foreign key as `sOneToOneField`. So a models file that says `ForeignKey(…, unique = true)`
is diffed against a live side that says `sOneToOneField`, forever. Before this fix the planner had
no branch for that pair:

    typeof equal (branch 1 gate)                          -> false
    Models._compare_model_field(declared, live)           -> true      # they ARE equal
    Dialect.describes_same_column(conn, declared, live)   -> false     # …and they are NOT
    db_constraint escape (planner.jl)                     -> false
    => push!(colect_not_equal, :type)

`INTEGER -> INTEGER`, so churn rather than data damage — but a permanent, unavoidable table-rebuild
proposal an operator cannot tell apart from a real one.

WHY IT WAS LATENT, and why testset 3 is shaped the way it is: `Models._compare_model_field` compares
attribute-wise over two structs with identical field-name sets, so the pair compares EQUAL and
`are_model_fields_equal` lets the planner's fast path return early. The bug only bites once ANY
OTHER column in the same table differs — then the detailed loop runs, `typeof` differs, and the
unrelated one-to-one column is swept into the rebuild. A test that changes only the relational
column therefore passes both before and after the fix and proves nothing.

MOCK LIMIT, measured: the SQLite marker struct cannot serve a NON-EMPTY plan. A SQLite alteration is
a full table rebuild, and `_sqlite_rebuild_preserving_indexes` asks the connection for the live
secondary-index DDL (`get_secondary_index_ddls` -> `fetch`), which a bare marker cannot answer. So
every "a change IS still planned" assertion below runs on the PostgreSQL mock, exactly as
`test_fk_to_table_planner.jl` does; SQLite is asserted on the empty-plan cases, where no rebuild is
reached. Testset 6 covers SQLite for real, against a temp file.
"""

using Test
using Logging
using DataFrames
using JSON
using PormG
using PormG.Models
using PormG.Migrations
import PormG: PormGModel, PormGPostgres, PormGSQLite
# Testset 6 opens a real (temporary) SQLite file, so it needs the weakdep extension. `runtests.jl`
# loads it for the whole suite; this guard is what makes the file runnable on its own.
isdefined(Main, :SQLite) || include(joinpath(@__DIR__, "..", "load_drivers.jl"))
import PormG.ConnectionPool: SQLiteConnectionPool, fetch
import PormG.Migrations: convert_schema_to_models

struct RelColMockPg <: PormGPostgres end
struct RelColMockSQLite <: PormGSQLite end
# The SQLite rebuild path asks the backend for its version to decide which DDL it may use.
PormG.backend_sqlite_version(::RelColMockSQLite) = 3045000

const RC_PG = RelColMockPg()
const RC_SL = RelColMockSQLite()

# A one-row "introspection result" for the PostgreSQL reader, which takes a `DataFrameRow` and
# nothing else. Same shape as `_kcol`/`_kfk`/`_key_row` in test_key_type_round_trip.jl and
# `_col`/`_fk`/`_introspection_row` in test_introspection_guards.jl — duplicated rather than shared
# because each of those files is included independently.
_rc_col(name, type; notnull = false, unique = false) =
  Dict{String, Any}("name" => name, "type" => type, "notnull" => notnull, "default" => nothing,
                    "identity" => "", "unique" => unique,
                    "non_negative_check" => false, "byte_limit" => nothing)

_rc_fk(column, table, pk) =
  Dict{String, Any}("column" => column, "table" => table, "pk" => pk, "on_delete" => "a")

_rc_row(; table_name, columns, primary_keys, foreign_keys = missing) =
  DataFrames.DataFrame(
    table_name   = [table_name],
    columns      = [columns isa AbstractVector ? JSON.json(columns) : columns],
    primary_keys = [primary_keys isa AbstractVector ? JSON.json(primary_keys) : primary_keys],
    foreign_keys = [foreign_keys isa AbstractVector ? JSON.json(foreign_keys) : foreign_keys],
    indexes      = [missing])[1, :]

# The parent every foreign key below points at, and the two sides of the pair under test. `declared`
# carries a RESOLVED `PormGModel` in `.to` (what `set_models` leaves behind); `live` carries the
# target's binding STRING plus the `to_table` breadcrumb (what introspection records) — which is
# precisely why raw `==` on `:to` is always false for a foreign key and why branch 1 reconciles it
# through `_compare_field_foreign_key`.
_rc_parent() = Models.Model("parent_t", id = Models.IDField(), n = Models.IntegerField())

function _rc_live_o2o(; unique = true, null = true, to_table = "parent_t", pk_field = "id")
  live = Models.OneToOneField("Parent_t"; pk_field = pk_field, unique = unique, null = null)
  live.to_table = to_table
  return live
end

# Build the two models the planner diffs and return the plan's keys for `child_t`.
# `get_migration_plan(models, current_schema, …)` takes the LIVE models first and the DECLARED ones
# in `current_schema` — the same (deliberately confusing) argument order the planner itself uses.
function _rc_plan(conn, declared_rel, live_rel; declared_note = Models.CharField(max_length = 40),
                                               live_note     = Models.CharField(max_length = 40))
  settings = PormG.Configuration.Settings()
  settings.change_db = true
  declared_model = Models.Model("child_t", id = Models.IDField(), parent_id = declared_rel, note = declared_note)
  live_model     = Models.Model("child_t", id = Models.IDField(), parent_id = live_rel,     note = live_note)
  current_schema = Dict{Symbol, Dict{Symbol, Union{Bool, PormGModel}}}(
    :child_t => Dict{Symbol, Union{Bool, PormGModel}}(:model => declared_model, :exist => false))
  return Migrations.get_migration_plan(PormGModel[live_model], current_schema, conn, settings)
end

_rc_plan_keys(args...; kwargs...) =
  let plan = _rc_plan(args...; kwargs...)
    haskey(plan, :child_t) ? collect(keys(plan[:child_t])) : String[]
  end

# The DDL the plan actually carries for the relational column, or "" when nothing was planned for it.
# Asserting the SQL rather than the KEY matters for the negative controls below: the key is
# `"Alter field: parent_id"` both before and after #437, so a key-only assertion passes against the
# broken code. What changed is the STATEMENT under it.
_rc_parent_sql(plan) =
  haskey(plan, :child_t) ? get(plan[:child_t], "Alter field: parent_id", "") : ""

@testset "#437: a ForeignKey(unique=true) and its live OneToOneField are one column" begin

  # ───────────────────────────────────────────────────────────────────────────
  # 1. The invariant the fix RESTS ON: `sForeignKey` and `sOneToOneField` carry the same attribute
  #    NAMES. That is what makes the planner's attribute-wise branch safe to index into either
  #    struct unguarded — `_diffs_attribute_wise` admits the pair, and the loop then does
  #    `getfield(old_field, attr)` for every `attr in fieldnames(typeof(field))`.
  #
  #    Asserted as SETS, not tuples, and that distinction is load-bearing rather than pedantic:
  #    `unique` is declared FIRST on `sOneToOneField` and THIRD on `sForeignKey`, so the tuples are
  #    genuinely unequal. The loop iterates by name, so order cannot matter — but a future field
  #    added to only one of the two structs would break the fix silently, and this is what catches it.
  # ───────────────────────────────────────────────────────────────────────────
  @testset "the two relational structs share one attribute vocabulary" begin
    fk_names  = Set(fieldnames(Models.sForeignKey))
    o2o_names = Set(fieldnames(Models.sOneToOneField))

    @test fk_names == o2o_names
    @test isempty(setdiff(fk_names, o2o_names))
    @test isempty(setdiff(o2o_names, fk_names))

    # Both are the alias the planner gates on, which is what `_diffs_attribute_wise` reuses instead
    # of re-spelling the pair (#408 renderer, #409 readers, #418 builder, #437 planner diff).
    # (No `sForeignKey !== sOneToOneField` assertion here: the two are distinct concrete structs at
    # parse time, so it could never fail and would only look like coverage.)
    @test Models.ForeignKey("Parent_t") isa Models.sRelationalColumn
    @test Models.OneToOneField("Parent_t") isa Models.sRelationalColumn
  end

  # ───────────────────────────────────────────────────────────────────────────
  # 2. WHY THE BUG WAS LATENT. The fast path already answered "equal" for this pair, which is why no
  #    user saw it until an unrelated column changed. Documents the shape; it is not a gate for the
  #    fix (it passed before the fix too) and it must not be mistaken for one.
  # ───────────────────────────────────────────────────────────────────────────
  @testset "the fast path already called the pair equal (why it stayed hidden)" begin
    declared = Models.ForeignKey(_rc_parent(), unique = true, pk_field = "id", null = true)
    live     = _rc_live_o2o()

    @test Models._compare_model_field(declared, live)
    @test Models._compare_field_foreign_key(declared, live)
    # And the predicate that disagreed with it — unchanged by #437, deliberately. See testset 5.
    @test !PormG.Dialect.describes_same_column(RC_PG, declared, live)
    @test !PormG.Dialect.describes_same_column(RC_SL, declared, live)
  end

  # ───────────────────────────────────────────────────────────────────────────
  # 3. THE GATE. A second column (`note`) carries a genuine, DDL-visible change, which forces the
  #    fast path to say "changed" and makes the detailed per-attribute loop run for real. That is
  #    the ONLY configuration in which #437 is observable.
  #
  #    Before the fix the PostgreSQL plan was ["Alter field: note", "Alter field: parent_id"];
  #    after it, only `note`. Asserting the ABSENCE of the `parent_id` key is the mutation gate —
  #    revert `_diffs_attribute_wise` and this testset fails while everything else still passes.
  # ───────────────────────────────────────────────────────────────────────────
  @testset "an unrelated column change does not sweep the relational column in" begin
    keys_pg = _rc_plan_keys(RC_PG,
                Models.ForeignKey(_rc_parent(), unique = true, pk_field = "id", null = true),
                _rc_live_o2o();
                declared_note = Models.CharField(max_length = 40),
                live_note     = Models.CharField(max_length = 80))

    # The real change is still planned — the fix narrowed the diff, not the migration.
    @test "Alter field: note" in keys_pg
    # …and the one-to-one column is NOT dragged along with it.
    @test !("Alter field: parent_id" in keys_pg)
    @test length(keys_pg) == 1
  end

  # ───────────────────────────────────────────────────────────────────────────
  # 3b. The same pair with NOTHING else differing proposes nothing at all, on both engines. This is
  #     the state a user actually lives in between changes, and the SQLite half is reachable here
  #     precisely because an empty plan means no table rebuild and so no connection call.
  #
  #     `min_level = Logging.Warn` with no expected specs asserts ZERO Warn-or-above records: a
  #     `:to` or `:type` riding along in `colect_not_equal` would reach `Dialect.alter_field`, which
  #     has no branch for `:to`, and warn "not implemented" on every single `makemigrations`.
  #
  #     NOT A MUTATION GATE, stated as measured: revert `_diffs_attribute_wise` and this testset
  #     still passes, because with no other column differing `are_model_fields_equal` short-circuits
  #     before the detailed loop is ever reached — which is #437's whole latency story. It documents
  #     the steady state; testsets 3, 4 and 4b are what actually catch a regression.
  # ───────────────────────────────────────────────────────────────────────────
  @testset "with nothing else changed the plan is empty on both engines" begin
    for conn in (RC_PG, RC_SL)
      keys_ = @test_logs min_level = Logging.Warn _rc_plan_keys(conn,
                Models.ForeignKey(_rc_parent(), unique = true, pk_field = "id", null = true),
                _rc_live_o2o())
      @test isempty(keys_)
    end
  end

  # ───────────────────────────────────────────────────────────────────────────
  # 4. NEGATIVE CONTROLS — so testset 3 proves "this pair converges" and not "this comparison always
  #    says equal". Each of these is a REAL schema difference on the same cross-type pair and must
  #    still be reported.
  #
  #    All on PostgreSQL, per the mock limit in the file header. `unique` is asserted in the
  #    true-ward direction on purpose: `Dialect.alter_field` answers a unique-DROP by asking the
  #    connection for the live constraint name (`get_constraints_unique`), which a marker cannot serve.
  # ───────────────────────────────────────────────────────────────────────────
  @testset "a real difference on the same pair is still reported" begin
    # Asserted on the SQL, not on the plan KEY. The key is `"Alter field: parent_id"` in both the
    # fixed and the broken code, so a key-only assertion would pass either way — and it would miss
    # what #437 actually repairs here. Before the fix this pair fell to the planner's final `else`
    # and carried `[:type]`, so `Dialect.alter_field` emitted a no-op `ALTER COLUMN … TYPE bigint`
    # and NEVER added the UNIQUE constraint or set NOT NULL: a migration that announced an
    # alteration and silently did not perform it. Excluding the old cast is therefore as much the
    # point as including the new statement.

    # `unique` — a declared one-to-one against a live PLAIN foreign key is a UNIQUE constraint the
    # database does not have yet.
    sql_unique = _rc_parent_sql(_rc_plan(RC_PG,
                   Models.OneToOneField(_rc_parent(), pk_field = "id", unique = true, null = true),
                   let f = Models.ForeignKey("Parent_t", pk_field = "id", null = true)
                     f.to_table = "parent_t"; f
                   end))
    @test occursin("ADD UNIQUE", sql_unique)
    @test !occursin("TYPE bigint", sql_unique)

    # `null` — the same pair as testset 3, differing only in nullability.
    sql_null = _rc_parent_sql(_rc_plan(RC_PG,
                 Models.ForeignKey(_rc_parent(), unique = true, pk_field = "id", null = false),
                 _rc_live_o2o(null = true)))
    @test occursin("SET NOT NULL", sql_null)
    @test !occursin("TYPE bigint", sql_null)

    # A DIFFERENT PARENT — and this one is asserted through the WARNING rather than a plan key,
    # because measuring it turned up a pre-existing gap worth stating plainly (now tracked as #498):
    #
    #   an FK re-pointed at another parent is NOT planned as DDL, on EITHER path. `:to` lands in
    #   `colect_not_equal`, but `Dialect.alter_field` has no `:to` branch, so it emits no SQL and
    #   `_configure_order_dict_migration_plan` drops the empty string; `_drop_fk_constraint_in_alteration`
    #   declines too (both sides still carry a live `db_constraint`, so this is a RE-POINT, not a
    #   drop). Measured for a same-type `sForeignKey`-vs-`sForeignKey` pair as well — the plan is
    #   empty there too, on unmodified code. The gap is pre-existing and orthogonal to #437.
    #
    # What #437 changed is that the cross-type pair now behaves EXACTLY like the same-type pair.
    # Before, it fell to the planner's final `else` and pushed `:type`, so it emitted a no-op
    # `ALTER COLUMN TYPE bigint` cast — noise, not a re-point. The assertion is therefore the
    # invariant (`:to` is what reaches `alter_field`, on both paths alike), not a plan key that
    # cannot exist.
    declared_other = Models.ForeignKey(_rc_parent(), unique = true, pk_field = "id", null = true)
    live_other     = _rc_live_o2o(to_table = "other_parent_t")
    @test !Models._compare_field_foreign_key(declared_other, live_other)

    cross_logs, _ = Test.collect_test_logs() do
      _rc_plan_keys(RC_PG, declared_other, live_other)
    end
    # `:to` reached `alter_field` — i.e. the difference WAS detected and carried into the diff.
    @test any(l -> l.level == Logging.Warn && occursin(":to", string(l.message)), cross_logs)

    # The same-type baseline, for the same parent change. Identical outcome — which is the point.
    same_live = Models.ForeignKey("Parent_t", pk_field = "id", unique = true, null = true)
    same_live.to_table = "other_parent_t"
    same_logs, _ = Test.collect_test_logs() do
      _rc_plan_keys(RC_PG,
        Models.ForeignKey(_rc_parent(), unique = true, pk_field = "id", null = true), same_live)
    end
    @test any(l -> l.level == Logging.Warn && occursin(":to", string(l.message)), same_logs)
  end

  # ───────────────────────────────────────────────────────────────────────────
  # 4b. The #50 reconciliation the fix INHERITS by routing into branch 1 rather than relaxing
  #     `describes_same_column`. A parent whose key is renamed through `db_column` is spelled by its
  #     FIELD name on the declared side (`pk_field = "id"`) and by its PHYSICAL column on the
  #     introspected one (`pk_field = "parent_pk"`), so `:pk_field` differs verbatim and is
  #     reconciled through `Models.fk_target_column`.
  #
  #     Branch 2 has no such reconciliation, which is the concrete reason #437's other candidate fix
  #     — relaxing the predicate — would have swapped one spurious symbol for another. This case
  #     needs no second changed column: the fast path has no `:pk_field` exemption either, so it
  #     reports "changed" on its own and the detailed loop runs.
  # ───────────────────────────────────────────────────────────────────────────
  @testset "a db_column-renamed parent key still converges (#50 via branch 1)" begin
    parent = Models.Model("parent_t",
               id = Models.IDField(db_column = "parent_pk"),
               n  = Models.IntegerField())
    declared = Models.ForeignKey(parent, unique = true, pk_field = "id", null = true)
    live     = _rc_live_o2o(pk_field = "parent_pk")

    # The attribute really does differ verbatim — otherwise this proves nothing.
    @test declared.pk_field != live.pk_field
    # …and resolves to the same physical column on both sides.
    @test Models.fk_target_column(declared) == Models.fk_target_column(live) == "parent_pk"

    @test isempty(@test_logs min_level = Logging.Warn _rc_plan_keys(RC_PG, declared, live))
  end

  # ───────────────────────────────────────────────────────────────────────────
  # 5. THE TRAP the issue names explicitly. `describes_same_column` must STAY `false` for a
  #    relational-vs-NON-relational pair: `sForeignKey` and `sBigIntegerField` both render `bigint`,
  #    and the FK constraint add/drop is planned AFTER the planner's `isempty(colect_not_equal)`
  #    early-out — so equating them would silently stop planning the constraint entirely.
  #
  #    #437 routed the relational PAIR one branch earlier instead of narrowing this predicate, and
  #    this testset is what pins that decision: it fails if a future change "simplifies" the fix by
  #    relaxing `describes_same_column` after all.
  # ───────────────────────────────────────────────────────────────────────────
  @testset "a relational vs non-relational pair still reports a change" begin
    for conn in (RC_PG, RC_SL)
      @test !PormG.Dialect.describes_same_column(conn, Models.ForeignKey("Parent_t"), Models.BigIntegerField())
      @test !PormG.Dialect.describes_same_column(conn, Models.BigIntegerField(), Models.ForeignKey("Parent_t"))
      @test !PormG.Dialect.describes_same_column(conn, Models.OneToOneField("Parent_t"), Models.BigIntegerField())
    end

    # And end to end: a declared foreign key over a column the database holds as a plain integer is
    # still an alteration, so the constraint gets planned. `db_constraint` is left at its default
    # `true` — the `false` case is the deliberate escape at the planner's final `else` (#408).
    keys_ = Logging.with_logger(Logging.NullLogger()) do
      _rc_plan_keys(RC_PG,
        Models.ForeignKey(_rc_parent(), unique = true, pk_field = "id", null = true),
        Models.BigIntegerField(null = true))
    end
    @test "Alter field: parent_id" in keys_
  end

  # ───────────────────────────────────────────────────────────────────────────
  # 6. THE ISSUE'S OWN ACCEPTANCE CRITERION: convergence against a REAL live column, on both
  #    backends. Everything above builds the live side by hand; this builds it the way the product
  #    does, by reading a database back.
  #
  #    SQLite is a hermetic temp file (the reader is PRAGMA-driven and needs one); PostgreSQL uses
  #    the row-shaped reader, which takes a `DataFrameRow` and no connection at all. Both must
  #    reconstruct `sOneToOneField` for a UNIQUE non-key foreign key (#417) and both must converge
  #    against a models file that spells it `ForeignKey(…, unique = true)`.
  # ───────────────────────────────────────────────────────────────────────────
  @testset "converges against its own live column on both backends" begin
    # ── SQLite, from a real file ────────────────────────────────────────────
    mktempdir() do dir
      pool = SQLiteConnectionPool(joinpath(dir, "relcol.sqlite"); pool_size = 1)
      try
        fetch(pool, """CREATE TABLE "parent_t" (
                         "id" INTEGER PRIMARY KEY AUTOINCREMENT UNIQUE NOT NULL,
                         "n"  INTEGER NOT NULL)""")
        # A UNIQUE non-key foreign key — the shape both readers report as `sOneToOneField` (#417).
        fetch(pool, """CREATE TABLE "child_t" (
                         "id"        INTEGER PRIMARY KEY AUTOINCREMENT UNIQUE NOT NULL,
                         "parent_id" INTEGER UNIQUE NULL,
                         "note"      TEXT(40) NOT NULL,
                         FOREIGN KEY ("parent_id") REFERENCES "parent_t"("id"))""")

        live = convert_schema_to_models(pool; include_table = ["parent_t", "child_t"])
        by = Dict(lowercase(string(m.name)) => m for m in live)
        live_rel = by["child_t"].fields["parent_id"]

        # What the reader reconstructs — the premise of the whole issue.
        @test live_rel isa Models.sOneToOneField
        @test live_rel.unique
        @test live_rel.to_table == "parent_t"

        # What a models file declares for that same column, and the assertion #437 asks for.
        parent   = Models.Model("parent_t", id = Models.IDField(), n = Models.IntegerField())
        declared = Models.Model("child_t",
                     id        = Models.IDField(),
                     parent_id = Models.ForeignKey(parent, unique = true, pk_field = "id", null = true),
                     note      = Models.CharField(max_length = 40))
        @test Models.are_model_fields_equal(declared, by["child_t"])
      finally
        # Windows will not remove the temp dir while the file handle is open, so `mktempdir` prints
        # a cleanup error and leaks the directory — the same leak test_key_type_round_trip.jl has.
        PormG.ConnectionPool.close_pool!(pool)
      end
    end

    # ── PostgreSQL, from the row-shaped reader (no connection needed) ────────
    pg_rel = Migrations.convertSQLToModel(_rc_row(
      table_name   = "child_t",
      columns      = [_rc_col("id", "bigint"; notnull = true),
                      _rc_col("parent_id", "bigint"; unique = true)],
      primary_keys = ["id"],
      foreign_keys = [_rc_fk("parent_id", "parent_t", "id")])).fields["parent_id"]

    # `fk_is_o2o = unique || primary_key` — the rule the SQLite reader was aligned to in #417.
    @test pg_rel isa Models.sOneToOneField
    @test pg_rel.to_table == "parent_t"

    # And the planner converges it against the declared `ForeignKey(unique = true)` with no plan.
    parent = Models.Model("parent_t", id = Models.IDField(), n = Models.IntegerField())
    @test isempty(@test_logs min_level = Logging.Warn _rc_plan_keys(RC_PG,
      Models.ForeignKey(parent, unique = true, pk_field = "id", null = true), pg_rel))

    # THE GATE for this testset, and the reason it is not just testset 3 again: the live side here
    # is what the READER actually produced, not a field built by hand to look like one. Add the
    # second changed column so the fast path cannot short-circuit, and the reader-produced column
    # must stay out of the plan exactly as the hand-built one does.
    #
    # (The SQLite half above cannot be gated the same way. A SQLite alteration is one whole-table
    # rebuild under a single "Alter table: …" key, so a plan with a genuine `note` change looks
    # identical whether or not `parent_id` was swept in. `are_model_fields_equal` is the strongest
    # per-column assertion available there, and it is the one #409/#417 use.)
    reader_keys = _rc_plan_keys(RC_PG,
      Models.ForeignKey(parent, unique = true, pk_field = "id", null = true), pg_rel;
      declared_note = Models.CharField(max_length = 40),
      live_note     = Models.CharField(max_length = 80))
    @test "Alter field: note" in reader_keys
    @test !("Alter field: parent_id" in reader_keys)
  end

end
