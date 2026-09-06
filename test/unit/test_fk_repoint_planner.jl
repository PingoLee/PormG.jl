"""
Unit coverage for #498 — a foreign key whose DEFINITION changes while it stays a constrained foreign
key on both sides. Re-pointed at a different parent model, pointed at a different parent column, or
given a different `ON DELETE`.

Before this fix, PostgreSQL planned NOTHING for any of the three, and said so only through a warning
that never went away. The difference WAS detected — `:to` reached `colect_not_equal` — and then died
four times over:

    _drop_fk_constraint_in_alteration    -> declined: its guard needs the constraint DISAPPEARING
    Dialect.alter_field(::PormGPostgres) -> no `:to` branch; warns "[:to] are not implemented", returns ""
    _configure_order_dict_migration_plan -> `value == "" && return`, so no plan key is created either
    _add_fk_constraint_in_alteration     -> declined: its guard needs the constraint APPEARING

The two guards were MIRRORED XOR TESTS on "does a constraint exist at all", so the fourth state —
both sides constrained, definition moved — was not representable by either. `_fk_constraint_action`
states the decision once and makes `:repoint` a first-class answer; testset 1 is that truth table and
is the mutation gate for the whole change.

TWO THINGS make this subtler than it reads, and both are load-bearing below:

  * `on_delete` cannot be compared with `==`, but NOT for the reason it looks like. The slot is typed
    `Union{Function, Nothing}` and `_get_on_delete_mode(::AbstractString)` normalizes an introspected
    "CASCADE" to the same `Kernel.CASCADE` sentinel a models file declares — so a raw `==` already
    agrees for CASCADE, RESTRICT, SET_NULL, SET_DEFAULT and `nothing`. It is wrong on exactly two
    pairs, and that is what makes it dangerous rather than obvious:

        declared PROTECT    vs live RESTRICT   raw ==  ->  false, render ==  ->  true
        declared DO_NOTHING vs live nothing    raw ==  ->  false, render ==  ->  true

    Neither fails loudly. Answering "changed" for either proposes a destructive DROP + ADD CONSTRAINT
    (a whole-table rebuild on SQLite) on EVERY `makemigrations`, forever, for a key nobody touched —
    so the fold rows in testset 5, not the identity rows, are what that testset is actually for.
  * `Models._compare_model_field` backs `are_model_fields_equal`, the early-out `_alter_table_fields`
    takes BEFORE its diff loop. Fixing the planner alone would have left the whole `on_delete` half
    dead code, so testset 2 asserts the fast path reports the change at all.

MOCK LIMIT, measured — the same one test_relational_column_identity.jl records: a bare SQLite marker
struct cannot serve a NON-EMPTY plan (the rebuild asks the connection for live secondary-index DDL),
so every "a change IS planned" assertion on SQLite runs against a real temp file in testset 8. The
PostgreSQL mock here DOES need a `fetch`: dropping a constraint means asking the catalog for its
name, because `_hash_field_name` mints it with `randstring(8)` and nothing can re-derive it.
"""

using Test
using Logging
using DataFrames
using PormG
using PormG.Models
using PormG.Migrations
import PormG: PormGModel, PormGPostgres, PormGSQLite
# Testset 8 opens a real (temporary) SQLite file, so it needs the weakdep extension. `runtests.jl`
# loads it for the whole suite; this guard is what makes the file runnable on its own.
isdefined(Main, :SQLite) || include(joinpath(@__DIR__, "..", "load_drivers.jl"))
import PormG.ConnectionPool: SQLiteConnectionPool, fetch
import PormG.Migrations: _fk_constraint_action, _fk_definition_changed

# Suffixed name: `runtests.jl` includes every unit file into ONE module, so a bare `MockPostgres`
# silently redefines a sibling's.
struct FkRepointMockPg498 <: PormGPostgres end

const FR_PG = FkRepointMockPg498()

# A catalog that reports NO foreign-key constraint for the column, while the introspected model still
# says `db_constraint = true`. Not hypothetical: `get_constraints_fk` restricts to
# `current_schemas(false)` while `get_database_schema` reads `public` explicitly, so a `search_path`
# without `public` puts the two out of step. Testset 3c is what this exists for.
struct FkRepointBlindCatalogPg498 <: PormGPostgres end
const FR_BLIND = FkRepointBlindCatalogPg498()
function fetch(connection::FkRepointBlindCatalogPg498, sql::String;
  conn = nothing,
  params = nothing,
  ignore_tx::Bool = false)
  return DataFrame()
end

# The name the catalog hands back for the LIVE constraint. `_drop_fk_constraint_in_alteration` can
# only learn it by asking (`get_constraints_fk`), never by re-deriving it — `_hash_field_name` ends
# in `randstring(8)`. Which is also why the ADD below can never collide with the DROP.
const FR_LIVE_CONSTRAINT = "child_t_parent_id_0ld00001_fk"

# `get_constraints_fk` is PARAMETERIZED since #498, so the query text carries the placeholders and
# the values arrive separately. The 3-positional-arg `fetch(conn, sql, params)` forwards to this
# keyword form, so matching on `params` is what identifies the call.
function fetch(connection::FkRepointMockPg498, sql::String;
  conn = nothing,
  params = nothing,
  ignore_tx::Bool = false)

  if occursin("constraint_type = 'FOREIGN KEY'", sql)
    # Answer only for the column under test, so a stray lookup cannot silently satisfy an assertion.
    params !== nothing && length(params) == 2 && params[2] == "parent_id" &&
      return DataFrame(constraint_name = [FR_LIVE_CONSTRAINT])
    return DataFrame()
  end

  return DataFrame()
end

# The two parents every key below points at. `declared` carries a RESOLVED `PormGModel` in `.to`
# (what `set_models` leaves behind); `live` carries the target's binding STRING plus the `to_table`
# breadcrumb (what introspection records).
_fr_parent()       = Models.Model("parent_t",       id = Models.IDField(), n = Models.IntegerField())
_fr_other_parent() = Models.Model("other_parent_t", id = Models.IDField(), n = Models.IntegerField())

# A parent whose key is renamed through `db_column` (#50) — for the `:pk_field` case, where the
# declared side spells the FIELD name and the live side the PHYSICAL column.
_fr_renamed_parent() = Models.Model("parent_t",
                         id = Models.IDField(db_column = "parent_pk"), n = Models.IntegerField())

# The live (introspected) side: a constrained ForeignKey, shaped the way a reader produces one.
function _fr_live_fk(; to_table = "parent_t", pk_field = "id", on_delete = nothing,
                       null = true, unique = false)
  live = Models.ForeignKey("Parent_t"; pk_field = pk_field, null = null, unique = unique,
                           on_delete = on_delete)
  live.to_table = to_table
  return live
end

# The cross-type shape #437 settled: a UNIQUE non-key foreign key reads back as `sOneToOneField`.
function _fr_live_o2o(; to_table = "parent_t", pk_field = "id", on_delete = nothing, null = true)
  live = Models.OneToOneField("Parent_t"; pk_field = pk_field, unique = true, null = null,
                              on_delete = on_delete)
  live.to_table = to_table
  return live
end

# Build the two models the planner diffs and return the plan for `child_t`. `get_migration_plan`
# takes the LIVE models first and the DECLARED ones in `current_schema` — the same (deliberately
# confusing) argument order the planner itself uses.
function _fr_plan(conn, declared_rel, live_rel; declared_note = Models.CharField(max_length = 40),
                                                live_note     = Models.CharField(max_length = 40))
  settings = PormG.Configuration.Settings()
  settings.change_db = true
  declared_model = Models.Model("child_t", id = Models.IDField(), parent_id = declared_rel, note = declared_note)
  live_model     = Models.Model("child_t", id = Models.IDField(), parent_id = live_rel,     note = live_note)
  current_schema = Dict{Symbol, Dict{Symbol, Union{Bool, PormGModel}}}(
    :child_t => Dict{Symbol, Union{Bool, PormGModel}}(:model => declared_model, :exist => false))
  return Migrations.get_migration_plan(PormGModel[live_model], current_schema, conn, settings)
end

_fr_keys(args...; kwargs...) =
  let plan = _fr_plan(args...; kwargs...)
    haskey(plan, :child_t) ? collect(keys(plan[:child_t])) : String[]
  end

_fr_step(plan, key) = haskey(plan, :child_t) ? get(plan[:child_t], key, "") : ""
_fr_drop(plan) = _fr_step(plan, "Remove foreign key: parent_id")
_fr_add(plan)  = _fr_step(plan, "New foreign key: parent_id")

@testset "#498: a re-pointed foreign key is planned as DROP + ADD CONSTRAINT" begin

  # ───────────────────────────────────────────────────────────────────────────
  # 1. THE MUTATION GATE for the whole change: `_fk_constraint_action`'s truth table. It replaced two
  #    mirrored XOR guards that, between them, had no way to say `:repoint` — which is the entire
  #    bug. Asserted with no connection at all, so a failure here localizes to the decision and not
  #    to any SQL.
  #
  #    The first four groups are the BEHAVIOUR-PRESERVATION half: they are exactly what the two old
  #    guards answered, and `_drop_fk_constraint_in_alteration`'s other two call sites (the
  #    field-deletion and rename paths) depend on them being unchanged.
  # ───────────────────────────────────────────────────────────────────────────
  @testset "the constraint decision is stated once, and can say :repoint" begin
    declared = Models.ForeignKey(_fr_parent(), pk_field = "id", null = true)

    # Preserved: the constraint is going away.
    @test _fk_constraint_action(nothing, _fr_live_fk())                    === :drop   # field deleted
    @test _fk_constraint_action(Models.BigIntegerField(), _fr_live_fk())   === :drop   # became a plain column
    @test _fk_constraint_action(Models.ForeignKey(_fr_parent(), pk_field = "id", db_constraint = false),
                                _fr_live_fk())                             === :drop   # db_constraint true -> false

    # Preserved: the constraint is appearing.
    @test _fk_constraint_action(declared, Models.BigIntegerField())        === :add

    # Preserved: nothing to do.
    @test _fk_constraint_action(declared, _fr_live_fk())                   === :none
    @test _fk_constraint_action(Models.IntegerField(), Models.BigIntegerField()) === :none

    # NEW — the state neither old guard could express.
    @test _fk_constraint_action(declared, _fr_live_fk(to_table = "other_parent_t")) === :repoint
    @test _fk_constraint_action(Models.ForeignKey(_fr_parent(), pk_field = "id", on_delete = Models.CASCADE),
                                _fr_live_fk())                             === :repoint
  end

  # ───────────────────────────────────────────────────────────────────────────
  # 2. Why testset 5 would otherwise be dead code. `Models._compare_model_field` backs
  #    `are_model_fields_equal`, which `_alter_table_fields` consults BEFORE its diff loop — and it
  #    used to `continue` on `:on_delete` unconditionally. An on_delete-only change therefore made
  #    the two models compare EQUAL and the planner returned without reaching anything #498 touches.
  #    Revert the `Models.jl` half alone and this testset fails while the planner half still "works".
  # ───────────────────────────────────────────────────────────────────────────
  @testset "the fast-path comparison reports an on_delete change" begin
    declared_same = Models.ForeignKey(_fr_parent(), pk_field = "id", null = true)
    declared_casc = Models.ForeignKey(_fr_parent(), pk_field = "id", null = true, on_delete = Models.CASCADE)

    @test Models._compare_model_field(declared_same, _fr_live_fk())                         # unchanged
    @test !Models._compare_model_field(declared_casc, _fr_live_fk())                        # CASCADE vs NO ACTION
    # Control, not a gate: the slot normalizes "CASCADE" to the declared sentinel, so a raw `==`
    # agrees here too. The fold this function actually needs `_fk_on_delete_equal` for is below.
    @test Models._compare_model_field(declared_casc, _fr_live_fk(on_delete = "CASCADE"))
    # THE GATE: a fold, where a raw `==` would report a change and make every `makemigrations`
    # propose a destructive re-point for a key nobody touched.
    @test Models._compare_model_field(
      Models.ForeignKey(_fr_parent(), pk_field = "id", null = true, on_delete = Models.PROTECT),
      _fr_live_fk(on_delete = "RESTRICT"))
  end

  # ───────────────────────────────────────────────────────────────────────────
  # 3. THE HEADLINE CASE: the same column, re-pointed at a different parent model.
  #
  #    Asserted on the SQL, not on the plan keys alone — and the ABSENCE of an "Alter field" step is
  #    asserted too. Before #437 this pair fell to the planner's final `else` and emitted a no-op
  #    `ALTER COLUMN … TYPE bigint`; excluding that cast is as much the point as including the
  #    constraint statements. The warning assertion is acceptance criterion 2 of the issue: the
  #    permanent "[:to] are not implemented" report has to STOP, not merely be joined by real DDL.
  # ───────────────────────────────────────────────────────────────────────────
  @testset "a different parent model plans DROP then ADD, and stops warning" begin
    plan = @test_logs min_level = Logging.Warn _fr_plan(FR_PG,
             Models.ForeignKey(_fr_other_parent(), pk_field = "id", null = true),
             _fr_live_fk(to_table = "parent_t"))

    @test occursin("DROP CONSTRAINT \"$(FR_LIVE_CONSTRAINT)\"", _fr_drop(plan))
    @test occursin("REFERENCES \"other_parent_t\" (\"id\")", _fr_add(plan))
    @test occursin("FOREIGN KEY (\"parent_id\")", _fr_add(plan))

    # No column ALTER: nothing about the COLUMN changed, only the constraint on it. This is the
    # assertion that `_FK_IDENTITY_ATTRS` is filtered out of what reaches `Dialect.alter_field`
    # rather than merely being ignored by it.
    keys_ = collect(keys(plan[:child_t]))
    @test !("Alter field: parent_id" in keys_)

    # DROP strictly before ADD. The plan's inner OrderedDict preserves insertion order and
    # `_order_statements` keeps both in one bucket, so this ordering is what actually executes.
    @test findfirst(==("Remove foreign key: parent_id"), keys_) <
          findfirst(==("New foreign key: parent_id"), keys_)
  end

  # ───────────────────────────────────────────────────────────────────────────
  # 3b. The cross-type pair, which is the second row the issue MEASURED: a declared
  #     `ForeignKey(unique = true)` against the `sOneToOneField` its own live column reads back as
  #     (#417/#437). It must behave EXACTLY like the same-type pair above — that equivalence is what
  #     #437 established, and #498 must not re-open a gap between them.
  # ───────────────────────────────────────────────────────────────────────────
  @testset "the cross-type FK/OneToOne pair re-points identically" begin
    plan = @test_logs min_level = Logging.Warn _fr_plan(FR_PG,
             Models.ForeignKey(_fr_other_parent(), unique = true, pk_field = "id", null = true),
             _fr_live_o2o(to_table = "parent_t"))

    @test occursin("DROP CONSTRAINT \"$(FR_LIVE_CONSTRAINT)\"", _fr_drop(plan))
    @test occursin("REFERENCES \"other_parent_t\" (\"id\")", _fr_add(plan))
    @test !occursin("TYPE bigint", _fr_step(plan, "Alter field: parent_id"))
  end

  # ───────────────────────────────────────────────────────────────────────────
  # 3c. A re-point NEVER adds without dropping. The two emitters derive `:repoint` independently, so
  #     if the DROP silently declines — `get_constraints_fk` finds no live constraint name, which it
  #     returns `nothing` for rather than raising — the ADD would otherwise still fire and leave TWO
  #     constraints on one column: every row then has to satisfy both parents, and the next
  #     `makemigrations` sees a converged model with a stale constraint it can never remove.
  #
  #     Reachable in production, not just in a mock: `get_constraints_fk` restricts to
  #     `current_schemas(false)` while `get_database_schema` reads `public` explicitly, so a
  #     `search_path` that excludes `public` puts introspection and the catalog lookup out of step.
  #     Refusing the whole re-point degrades to the pre-#498 behaviour (nothing planned) plus a
  #     warning naming the column, which is recoverable; a duplicate constraint is not.
  # ───────────────────────────────────────────────────────────────────────────
  @testset "a re-point never adds a constraint it could not drop" begin
    keys_ = @test_logs (:warn,) match_mode = :any _fr_keys(FR_BLIND,
              Models.ForeignKey(_fr_other_parent(), pk_field = "id", null = true),
              _fr_live_fk(to_table = "parent_t"))
    @test !("New foreign key: parent_id" in keys_)
    @test !("Remove foreign key: parent_id" in keys_)
  end

  # ───────────────────────────────────────────────────────────────────────────
  # 4. The same parent TABLE, a different parent COLUMN — `:pk_field`, reconciled through
  #    `Models.fk_target_column` so a `db_column`-renamed parent key (#50) does not read as a change.
  #    Here it genuinely IS one, so it must re-point, and the new `REFERENCES` must name the PHYSICAL
  #    column rather than the field name.
  # ───────────────────────────────────────────────────────────────────────────
  @testset "a different parent column re-points at the physical column" begin
    plan = @test_logs min_level = Logging.Warn _fr_plan(FR_PG,
             Models.ForeignKey(_fr_renamed_parent(), pk_field = "id", null = true),
             _fr_live_fk(pk_field = "id"))

    @test occursin("DROP CONSTRAINT \"$(FR_LIVE_CONSTRAINT)\"", _fr_drop(plan))
    @test occursin("REFERENCES \"parent_t\" (\"parent_pk\")", _fr_add(plan))
  end

  # ───────────────────────────────────────────────────────────────────────────
  # 5. `ON DELETE`, which was a silent no-op on BOTH engines: it never reached the alteration gate at
  #    all, because it sat in `_NON_SCHEMA_FIELD_ATTRS` behind a comment claiming the FK helpers
  #    already planned it. They did not.
  #
  #    The NEGATIVE CONTROL below is the more important half. Comparing `on_delete` wrongly does not
  #    fail loudly — it proposes a destructive DROP + ADD CONSTRAINT on every single
  #    `makemigrations`, forever. Both folds are asserted because both are places a hand-written
  #    comparison gets wrong: PROTECT renders RESTRICT and can only ever read back as RESTRICT, and
  #    DO_NOTHING is indistinguishable from "no action declared" once it is in a database.
  # ───────────────────────────────────────────────────────────────────────────
  @testset "a changed ON DELETE re-points; an equivalent one plans nothing" begin
    plan = @test_logs min_level = Logging.Warn _fr_plan(FR_PG,
             Models.ForeignKey(_fr_parent(), pk_field = "id", null = true, on_delete = Models.CASCADE),
             _fr_live_fk(on_delete = nothing))

    @test occursin("DROP CONSTRAINT \"$(FR_LIVE_CONSTRAINT)\"", _fr_drop(plan))
    @test occursin("ON DELETE CASCADE", _fr_add(plan))

    # ── the churn controls ──
    # `on_delete` is typed `Union{Function, Nothing}` and `_get_on_delete_mode(::AbstractString)`
    # normalizes an introspected "CASCADE" to the same `Kernel.CASCADE` sentinel a models file
    # declares — so a raw `==` ALREADY agrees for the first two rows and the last. They are here as
    # controls on the comparator not over-reporting, not as gates.
    #
    # The two FOLDS are the gates, and they are the reason a rendered comparison is used everywhere
    # `on_delete` is diffed: a raw comparison answers "changed" for both, and a schema diff that does
    # that proposes a destructive DROP + ADD CONSTRAINT on every run, forever, for a key nobody
    # touched. Neither fails loudly — that is exactly why they need pinning.
    for (declared_od, live_od) in ((Models.CASCADE,    "CASCADE"),    # raw == already agrees
                                   (Models.SET_NULL,   "SET NULL"),   # raw == already agrees
                                   (Models.PROTECT,    "RESTRICT"),   # FOLD: one-way by construction
                                   (Models.DO_NOTHING, nothing),      # FOLD: both render NO ACTION
                                   (nothing,           nothing))      # raw == already agrees
      quiet = @test_logs min_level = Logging.Warn _fr_keys(FR_PG,
                Models.ForeignKey(_fr_parent(), pk_field = "id", null = true, on_delete = declared_od),
                _fr_live_fk(on_delete = live_od))
      @test isempty(quiet)
    end
  end

  # ───────────────────────────────────────────────────────────────────────────
  # 5c. `_fk_definition_changed` (#150) directly. It is the SQLite rename path's gate and the body of
  #     `_fk_constraint_action`'s `:repoint` answer, and it compared `on_delete` with a raw `!=` until
  #     #498 — so a renamed key declared `PROTECT` against its own live `RESTRICT` reported "changed"
  #     and forced a whole-table rebuild that a plain `RENAME COLUMN` covers. Asserted here rather
  #     than through a plan because the predicate has exactly one other consumer, which makes a
  #     regression in it invisible everywhere else.
  # ───────────────────────────────────────────────────────────────────────────
  @testset "_fk_definition_changed folds equivalent ON DELETE values (#150 + #498)" begin
    fk(od) = Models.ForeignKey(_fr_parent(), pk_field = "id", null = true, on_delete = od)
    @test _fk_definition_changed(fk(Models.PROTECT),    _fr_live_fk(on_delete = "RESTRICT")) == false
    @test _fk_definition_changed(fk(Models.DO_NOTHING), _fr_live_fk(on_delete = nothing))    == false
    @test _fk_definition_changed(fk(Models.CASCADE),    _fr_live_fk(on_delete = "CASCADE"))  == false
    # Positive control: a genuine action change is still reported.
    @test _fk_definition_changed(fk(Models.CASCADE),    _fr_live_fk(on_delete = "SET NULL")) == true
  end

  # ───────────────────────────────────────────────────────────────────────────
  # 6. A re-point that ALSO changes the column. The constraint statements and the column ALTER are
  #    different DDL and must both appear — and in the order DROP, ALTER, ADD. That order is why the
  #    two emitters straddle the alter step instead of being collapsed into one call: a column TYPE
  #    or NOT NULL change running underneath a freshly-added constraint is a different, worse plan.
  # ───────────────────────────────────────────────────────────────────────────
  @testset "a re-point alongside a column change keeps all three steps, in order" begin
    plan = @test_logs min_level = Logging.Warn _fr_plan(FR_PG,
             Models.ForeignKey(_fr_other_parent(), pk_field = "id", null = false),
             _fr_live_fk(to_table = "parent_t", null = true))

    @test occursin("DROP CONSTRAINT", _fr_drop(plan))
    @test occursin("SET NOT NULL", _fr_step(plan, "Alter field: parent_id"))
    @test occursin("REFERENCES \"other_parent_t\"", _fr_add(plan))

    keys_ = collect(keys(plan[:child_t]))
    @test findfirst(==("Remove foreign key: parent_id"), keys_) <
          findfirst(==("Alter field: parent_id"), keys_) <
          findfirst(==("New foreign key: parent_id"), keys_)
  end

  # ───────────────────────────────────────────────────────────────────────────
  # 7. THE RENAME PATH, which this change also alters and which no assertion covered.
  #
  #    `_drop_fk_constraint_in_alteration` has two callers besides the alteration loop, and stating
  #    the decision once reaches both. On the rename path the old code asked its XOR guard, got
  #    "no" for two constrained sides, and emitted no DROP — while `_add_constrains` further down
  #    unconditionally ADDS one. So renaming a column whose key ALSO moved left the old constraint
  #    in place (PostgreSQL's `RENAME COLUMN` carries it along) and added a second one pointing
  #    somewhere else. `:repoint` fixes that here for free.
  #
  #    ORDERING, stated as measured rather than as it reads: the plan dict's insertion order is DROP,
  #    RENAME, ADD, but `runner._order_statements` hoists any key containing "Rename field" into an
  #    earlier bucket than the rest, so what EXECUTES is RENAME, DROP, ADD. That is still correct —
  #    PostgreSQL's `DROP CONSTRAINT` is by constraint name and a renamed column carries its
  #    constraint along — and the assertion below pins the insertion order, which is what this
  #    planner-level test can see. Testsets 3 and 6 assert the same shape and there the two orders
  #    coincide, because every key they produce lands in one bucket.
  #
  #    Driven through stdin because a rename is only ever proposed interactively — `interactive =
  #    false` answers "no" to the prompt and takes the add-a-new-field path instead (planner.jl).
  #    Same technique as integration Phase 4e.
  #
  #    NOT COVERED HERE, and deliberately: a rename whose FK definition is UNCHANGED still emits an
  #    ADD with no DROP, so PostgreSQL ends up with two constraints on the column. Measured on this
  #    same harness. That is pre-existing, `_fk_constraint_action` correctly answers `:none` for it,
  #    and fixing it means changing what `_add_constrains` does on a rename — a different bug in a
  #    different function, filed separately rather than folded in here.
  # ───────────────────────────────────────────────────────────────────────────
  @testset "a rename that also re-points drops the old constraint first" begin
    settings = PormG.Configuration.Settings()
    settings.change_db = true
    # The declared side calls the column `new_parent_id` and points it at a DIFFERENT parent; the
    # live side still calls it `parent_id`. One addition + one deletion is what offers the rename.
    declared = Models.Model("child_t", id = Models.IDField(),
                 new_parent_id = Models.ForeignKey(_fr_other_parent(), pk_field = "id", null = true))
    livem    = Models.Model("child_t", id = Models.IDField(), parent_id = _fr_live_fk())
    current_schema = Dict{Symbol, Dict{Symbol, Union{Bool, PormGModel}}}(
      :child_t => Dict{Symbol, Union{Bool, PormGModel}}(:model => declared, :exist => false))

    answer, io = mktemp(); write(io, "1\n"); close(io)
    plan = open(answer) do stdin_file
      redirect_stdin(stdin_file) do
        Migrations.get_migration_plan(PormGModel[livem], current_schema, FR_PG, settings; interactive = true)
      end
    end

    steps = collect(keys(plan[:child_t]))
    # The DROP names the OLD column, because that is what the live catalog knows it by.
    @test occursin("DROP CONSTRAINT \"$(FR_LIVE_CONSTRAINT)\"", plan[:child_t]["Remove foreign key: parent_id"])
    @test occursin("REFERENCES \"other_parent_t\" (\"id\")", plan[:child_t]["New foreign key: new_parent_id"])
    @test findfirst(==("Remove foreign key: parent_id"), steps) <
          findfirst(==("Rename field: new_parent_id"), steps) <
          findfirst(==("New foreign key: new_parent_id"), steps)
  end

  # ───────────────────────────────────────────────────────────────────────────
  # 8. ACCEPTANCE CRITERION 3 — SQLite. The issue asks for the two engines to be confirmed equivalent
  #    or the divergence documented; this is the confirmation. SQLite expresses the same change by
  #    rebuilding the table from the DESIRED model, which re-renders the whole
  #    `FOREIGN KEY … REFERENCES … ON DELETE` clause, so no separate constraint DDL exists there —
  #    and both FK emitters are silent no-ops on SQLite by design.
  #
  #    A real temp file, not the marker struct: a SQLite alteration is a whole-table rebuild and
  #    `_sqlite_rebuild_preserving_indexes` asks the connection for the live secondary-index DDL.
  # ───────────────────────────────────────────────────────────────────────────
  @testset "SQLite expresses the same change through its table rebuild" begin
    mktempdir() do dir
      pool = SQLiteConnectionPool(joinpath(dir, "fkrepoint.sqlite"); pool_size = 1)
      try
        fetch(pool, """CREATE TABLE "parent_t" (
                         "id" INTEGER PRIMARY KEY AUTOINCREMENT UNIQUE NOT NULL,
                         "n"  INTEGER NOT NULL)""")
        fetch(pool, """CREATE TABLE "other_parent_t" (
                         "id" INTEGER PRIMARY KEY AUTOINCREMENT UNIQUE NOT NULL,
                         "n"  INTEGER NOT NULL)""")
        fetch(pool, """CREATE TABLE "child_t" (
                         "id"        INTEGER PRIMARY KEY AUTOINCREMENT UNIQUE NOT NULL,
                         "parent_id" INTEGER NULL,
                         "note"      TEXT(40) NOT NULL,
                         FOREIGN KEY ("parent_id") REFERENCES "parent_t"("id"))""")

        # A different parent: the rebuild names the new one, and no longer the old one.
        repoint = _fr_step(_fr_plan(pool,
                    Models.ForeignKey(_fr_other_parent(), pk_field = "id", null = true),
                    _fr_live_fk(to_table = "parent_t")), "Alter table: child_t")
        @test occursin("REFERENCES \"other_parent_t\"(\"id\")", repoint)
        @test !occursin("REFERENCES \"parent_t\"(\"id\")", repoint)

        # A different ON DELETE: the rebuild carries it. This one is entirely new behaviour —
        # `:on_delete` never opened the alteration gate before, so SQLite planned nothing either.
        ondelete = _fr_step(_fr_plan(pool,
                     Models.ForeignKey(_fr_parent(), pk_field = "id", null = true, on_delete = Models.CASCADE),
                     _fr_live_fk(on_delete = nothing)), "Alter table: child_t")
        @test occursin("ON DELETE CASCADE", ondelete)

        # And the equivalent-clause control again, on the engine that cannot express a no-op cheaply:
        # a whole-table rebuild proposed forever is exactly the churn #437 and #325 were about.
        @test isempty(@test_logs min_level = Logging.Warn _fr_keys(pool,
                Models.ForeignKey(_fr_parent(), pk_field = "id", null = true, on_delete = Models.PROTECT),
                _fr_live_fk(on_delete = "RESTRICT")))

        # THE GATE for the planner's `:on_delete` reconciliation, and the only shape that reaches it.
        # Measured while writing this: with `on_delete` as the ONLY difference, `are_model_fields_equal`
        # folds through the same comparator and returns early, so the diff loop never runs; and on
        # PostgreSQL the two constraint emitters fold independently through `_fk_constraint_action`,
        # so nothing is planned there either way. Deleting the reconciliation therefore passes every
        # other assertion in this file.
        #
        # What it costs is visible only HERE: an INDEX-only change elsewhere on the table defeats the
        # early-out (`db_index` is in `_NON_SCHEMA_FIELD_ATTRS`, so it plans a CREATE INDEX and no
        # rebuild) while the diff loop still runs — and without the reconciliation the FK's harmless
        # `PROTECT`/`RESTRICT` fold lands in `colect_not_equal`, which on SQLite means a FULL TABLE
        # REBUILD instead of one CREATE INDEX. Forever, on every `makemigrations`.
        index_only = @test_logs min_level = Logging.Warn _fr_keys(pool,
          Models.ForeignKey(_fr_parent(), pk_field = "id", null = true, on_delete = Models.PROTECT),
          _fr_live_fk(on_delete = "RESTRICT");
          declared_note = Models.CharField(max_length = 40, db_index = true),
          live_note     = Models.CharField(max_length = 40, db_index = false))
        @test "Create index on note" in index_only      # the diff loop DID run
        @test !("Alter table: child_t" in index_only)   # …and did not drag the table into a rebuild
      finally
        # Windows will not remove the temp dir while the file handle is open, so `mktempdir` prints
        # a cleanup error and leaks the directory — the same leak test_key_type_round_trip.jl has.
        PormG.ConnectionPool.close_pool!(pool)
      end
    end
  end

end
