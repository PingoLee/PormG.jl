# ==============================================================================
# #360: a ForeignKey's `to_table` breadcrumb is not schema drift
#
# #360 added a `to_table` slot to `sForeignKey`/`sOneToOneField` — the physical parent table,
# recorded by introspection so the inspectdb importers can rewrite `.to` to the target's final,
# collision-deduped binding before rendering. It is ASYMMETRIC BY CONSTRUCTION:
#
#   * the live/introspected side always has it set (introspection knows the parent table),
#   * the declared/models-file side is always `nothing` (`Model_to_str` never emits it — no
#     `ForeignKey` kwarg accepts one).
#
# So unless it is excluded from the field diff, EVERY foreign key reports a difference on EVERY
# `makemigrations`, forever. That is the same shape as `auto_now`/`auto_now_add`/`auto_add`, and it
# is excluded the same way. Two places had to learn it, not one:
#
#   1. `Migrations._NON_SCHEMA_FIELD_ATTRS` — the detailed per-attribute loop in
#      `_alter_table_fields`, which is what actually builds `colect_not_equal`.
#   2. `Models._compare_model_field` — the `are_model_fields_equal` FAST PATH that runs BEFORE it.
#      That one has no access to the tuple and skips `:on_delete` by hand; `:to_table` joins it.
#      Missing here, the cheap "nothing changed" answer is simply never reachable for a model with
#      foreign keys — the expensive path runs every time and only then finds nothing.
#
# A dedicated file rather than an addition to `test/unit/test_migration_planner.jl`: that file is
# commented out of `test/runtests.jl` (`Mock` struct name collisions) and so gets zero CI
# protection — the same reason `test_migration_planner_auto_add.jl` exists standalone.
#
# On the mutation gate, stated as measured rather than as assumed. The two exclusions are NOT
# independent, and an end-to-end "is the plan empty" check is a weak gate for them:
#
#   * revert the `Models._compare_model_field` skip alone -> testset 1 fails; the plan stays empty,
#     because the detailed loop then runs and the tuple filters `:to_table` out anyway.
#   * revert the `_NON_SCHEMA_FIELD_ATTRS` entry alone   -> testset 2 fails; the plan stays empty,
#     because the fast path short-circuits before the detailed loop is ever reached.
#
# (Both verified by hand, reverting one at a time.) So testsets 1 and 2 are the real gates, one per
# exclusion. Testset 3 is what makes the TUPLE behaviourally load-bearing: it pairs the `to_table`
# asymmetry with a genuine, DDL-visible difference on the same field, which forces the fast path to
# say "changed" and the detailed loop to run for real. Without the tuple entry, `:to_table` then
# rides along in `colect_not_equal` and `Dialect.alter_field` — which has no branch for it — warns
# "not implemented" on every single `makemigrations`.
# ==============================================================================

using Test
using Logging
using PormG
using PormG.Models
using PormG.Migrations
import PormG: PormGModel, PormGPostgres, PormGSQLite
# Testset 5 (#390) opens a real temporary SQLite file — its reader is PRAGMA-driven, and the
# REFERENCES-spelling behaviour under test is the engine's, so a marker struct cannot stand in.
# `runtests.jl` loads the driver extension for the whole suite; this guard keeps the file runnable
# on its own without double-loading under the suite.
isdefined(Main, :SQLite) || include(joinpath(@__DIR__, "..", "load_drivers.jl"))
import PormG.ConnectionPool: SQLiteConnectionPool, fetch
import PormG.Migrations: convert_schema_to_models

struct FkToTablePlannerMockPg <: PormGPostgres end
struct FkToTablePlannerMockSQLite <: PormGSQLite end
# The SQLite rebuild path asks the backend for its version to decide which DDL it may use.
PormG.backend_sqlite_version(::FkToTablePlannerMockSQLite) = 3045000

# One declared FK (as a models file spells it) and one introspected FK for the SAME column,
# differing ONLY in `to_table`. `.to` is deliberately identical: pass 1 has already rewritten it to
# the target's binding by the time any model file exists, so a `.to` difference here would be a
# different bug and would mask the one under test.
function _fk_pair()
  declared = Models.ForeignKey("Driver_profile", pk_field = "id", null = true)
  introspected = Models.ForeignKey("Driver_profile", pk_field = "id", null = true)
  introspected.to_table = "driver profile"   # what `convertSQLToModel` records
  return declared, introspected
end

@testset "#360: a ForeignKey differing only in to_table is not schema drift" begin

  # ───────────────────────────────────────────────────────────────────────────
  # 1. The fast path (`Models._compare_model_field`, reached via `are_model_fields_equal`).
  #    Mutation gate: drop the `:to_table` branch and both of these flip to `false`.
  # ───────────────────────────────────────────────────────────────────────────
  @testset "are_model_fields_equal ignores to_table" begin
    declared_fk, introspected_fk = _fk_pair()

    @test Models._compare_model_field(introspected_fk, declared_fk)

    declared_model = Models.Model("pit_stop", id = Models.IDField(), profile_id = declared_fk)
    live_model     = Models.Model("pit_stop", id = Models.IDField(), profile_id = introspected_fk)
    @test Models.are_model_fields_equal(live_model, declared_model)

    # Negative control: a REAL difference on the same field must still register, so the assertion
    # above is proving "to_table is ignored", not "this comparison always says equal".
    changed_fk = Models.ForeignKey("Driver_profile", pk_field = "id", null = false)
    changed_fk.to_table = "driver profile"
    @test !Models._compare_model_field(changed_fk, declared_fk)
  end

  # ───────────────────────────────────────────────────────────────────────────
  # 2. The detailed loop's exclusion tuple — a direct membership check, the same mutation gate
  #    `test_migration_planner_auto_add.jl` uses for `:auto_add`.
  # ───────────────────────────────────────────────────────────────────────────
  @testset "to_table is excluded from the per-attribute diff" begin
    @test :to_table in Migrations._NON_SCHEMA_FIELD_ATTRS
  end

  # ───────────────────────────────────────────────────────────────────────────
  # 3a. The user-visible end state: a `to_table`-only difference proposes nothing at all, on both
  #     engines. Per the header this is satisfied by EITHER exclusion, so it documents the outcome
  #     rather than gating a specific line — it is still the thing a user would notice break.
  # ───────────────────────────────────────────────────────────────────────────
  @testset "makemigrations proposes nothing for a to_table-only difference" begin
    settings = PormG.Configuration.Settings()
    settings.change_db = true

    for conn in (FkToTablePlannerMockSQLite(), FkToTablePlannerMockPg())
      declared_fk, introspected_fk = _fk_pair()
      declared_model = Models.Model("pit_stop", id = Models.IDField(), profile_id = declared_fk)
      live_model     = Models.Model("pit_stop", id = Models.IDField(), profile_id = introspected_fk)

      current_schema = Dict{Symbol, Dict{Symbol, Union{Bool, PormGModel}}}(
        :pit_stop => Dict{Symbol, Union{Bool, PormGModel}}(:model => declared_model, :exist => false))

      # `min_level = Logging.Warn` with no expected specs asserts ZERO Warn-or-above records.
      plan = @test_logs min_level = Logging.Warn Migrations.get_migration_plan(
        PormGModel[live_model], current_schema, conn, settings)

      @test !haskey(plan, :pit_stop) || isempty(plan[:pit_stop])
    end
  end

  # ───────────────────────────────────────────────────────────────────────────
  # 3b. THE behavioural gate for the tuple entry. A real, DDL-visible difference on the same field
  #     (`null`) forces the fast path to report "changed", so the detailed per-attribute loop runs
  #     for real and `:to_table` has to be filtered there or it rides along in `colect_not_equal`.
  #     `Dialect.alter_field` has no branch for it, so it would warn "not implemented" every run.
  #
  #     Asserting BOTH halves matters: the migration must still be produced (the real change is not
  #     swallowed) AND no warning is emitted (the breadcrumb did not ride along).
  # ───────────────────────────────────────────────────────────────────────────
  @testset "a real change alongside to_table alters cleanly, with no spurious warning" begin
    settings = PormG.Configuration.Settings()
    settings.change_db = true

    declared_fk = Models.ForeignKey("Driver_profile", pk_field = "id", null = true)
    introspected_fk = Models.ForeignKey("Driver_profile", pk_field = "id", null = false)  # REAL diff
    introspected_fk.to_table = "driver profile"

    declared_model = Models.Model("pit_stop", id = Models.IDField(), profile_id = declared_fk)
    live_model     = Models.Model("pit_stop", id = Models.IDField(), profile_id = introspected_fk)

    current_schema = Dict{Symbol, Dict{Symbol, Union{Bool, PormGModel}}}(
      :pit_stop => Dict{Symbol, Union{Bool, PormGModel}}(:model => declared_model, :exist => false))

    plan = @test_logs min_level = Logging.Warn Migrations.get_migration_plan(
      PormGModel[live_model], current_schema, FkToTablePlannerMockPg(), settings)

    # The genuine `null` change still reaches the plan — the exclusion narrowed the diff, not the
    # migration.
    @test haskey(plan, :pit_stop) && !isempty(plan[:pit_stop])
  end

  # ───────────────────────────────────────────────────────────────────────────
  # 4. The FK TARGET comparison itself, for a parent whose name needs sanitizing.
  #
  #    `makemigrations` runs `convert_schema_to_models` directly — `_plan_inspectdb_bindings!` never
  #    executes there — so the live side keeps introspection's `.to` (now the sanitized BINDING)
  #    while the declared side has been resolved to a model object. `_compare_field_foreign_key`
  #    used to recover the table by LOWERCASING `.to`, which only works while `.to` is exactly
  #    `uppercasefirst(<table>)`:
  #
  #        live "Driver_profile"  -> "driver_profile"   |  declared "driver profile"
  #
  #    …a mismatch, so `:to` entered `colect_not_equal` and every such foreign key proposed an
  #    alteration forever (a FULL TABLE REBUILD on SQLite). Comparing the physical tables directly —
  #    `to_table` on the live side, `model_table_name` on the declared one — removes the guesswork.
  #
  #    The parents are built the way a generated models file really spells them: the positional name
  #    is validated lowercase (#300), so a mixed-case physical table reaches the declared side as
  #    `db_table`, NOT as `model.name`. Constructing `Model("Driver_Profile", …)` to test that case
  #    would only work because the `Dict` form bypasses that guard — it would pin a model shape no
  #    loaded file can hold, which is why the mixed-case case is expressed through `db_table` below.
  # ───────────────────────────────────────────────────────────────────────────
  @testset "an FK whose parent name needs sanitizing is not proposed as drift" begin
    settings = PormG.Configuration.Settings()
    settings.change_db = true

    # (declared positional name, declared db_table, live physical table as introspection sees it)
    #
    # #390 REMOVED a fourth row here: `("driver", nothing, "DRIVER")`, the SQLite `REFERENCES DRIVER`
    # spelling. It pinned the CASE FOLD this comparison used to apply, and the fold is gone — the
    # SQLite reader now resolves that spelling against `sqlite_master` before recording `to_table`
    # (`Migrations._sqlite_canonical_table_name`), so introspection can no longer PRODUCE
    # `to_table = "DRIVER"` for a table created as `driver` — provided that parent EXISTS in
    # `sqlite_master` at read time. A dangling foreign key (SQLite permits one) still keeps the
    # REFERENCES spelling; that is self-healing, since the first `migrate` creates the parent and the
    # next read canonicalizes. The row pinned a state the system does
    # not reach any more, and keeping it would have pinned the defect instead: on PostgreSQL, where
    # identifiers are case-sensitive, folding hides a key genuinely repointed between two real tables.
    #
    # The guard relocated rather than vanished — it is now `#390: the SQLite REFERENCES spelling is
    # canonicalized at the reader` below, asserted against a real SQLite file where the engine
    # behaviour is observable, plus a PostgreSQL counterpart proving the case-distinct pair is now
    # DETECTED. Verified by measurement before the row was touched, not inferred.
    parents = [("driver profile",  nothing,          "driver profile"),
               ("driver_profile",  nothing,          "driver_profile"),
               ("driver_profile",  "Driver_Profile", "Driver_Profile")]  # mixed case, pinned (#59)

    for (declared_name, declared_db_table, live_table) in parents
      # The kwargs form on purpose — it is what a generated models file emits, and it ENFORCES the
      # #300 lowercase positional-name guard that the `Dict` form bypasses.
      parent = declared_db_table === nothing ?
        Models.Model(declared_name; id = Models.IDField()) :
        Models.Model(declared_name; db_table = declared_db_table, id = Models.IDField())

      declared_fk = Models.ForeignKey(parent, pk_field = "id", null = true)  # resolved, as set_models leaves it
      live_fk = Models.ForeignKey(Models._model_binding_name(live_table), pk_field = "id", null = true)
      live_fk.to_table = live_table                                          # as introspection records it

      declared_model = Models.Model("pit_stop", id = Models.IDField(), profile_id = declared_fk)
      live_model     = Models.Model("pit_stop", id = Models.IDField(), profile_id = live_fk)

      @test Models._compare_field_foreign_key(live_fk, declared_fk)

      current_schema = Dict{Symbol, Dict{Symbol, Union{Bool, PormGModel}}}(
        :pit_stop => Dict{Symbol, Union{Bool, PormGModel}}(:model => declared_model, :exist => false))

      for conn in (FkToTablePlannerMockSQLite(), FkToTablePlannerMockPg())
        plan = @test_logs min_level = Logging.Warn Migrations.get_migration_plan(
          PormGModel[live_model], current_schema, conn, settings)
        @test !haskey(plan, :pit_stop) || isempty(plan[:pit_stop])
      end
    end

    # Negative control: a key genuinely pointing at a DIFFERENT table must still compare unequal, or
    # the assertions above would be satisfied by a comparison that always says "same". The pair
    # differs by more than case, so the case folding above cannot mask it.
    other_parent = Models.Model("driver profile"; id = Models.IDField())
    declared_other = Models.ForeignKey(other_parent, pk_field = "id", null = true)
    live_other = Models.ForeignKey("Driver_profile", pk_field = "id", null = true)
    live_other.to_table = "driver_profile"
    @test !Models._compare_field_foreign_key(live_other, declared_other)
  end

  # ───────────────────────────────────────────────────────────────────────────
  # 5. #390: the SQLite `REFERENCES` spelling is canonicalized AT THE READER.
  #
  #    `PRAGMA foreign_key_list` reports a foreign key's parent table as the `REFERENCES` clause
  #    spelled it, not as `CREATE TABLE` did — SQLite identifiers are case-insensitive, so
  #    `REFERENCES DRIVER(id)` against a table created as `driver` is legal and used to introspect
  #    as `DRIVER`. `_compare_field_foreign_key` absorbed that by folding case unconditionally,
  #    which was safe here and WRONG on PostgreSQL, where `Driver` and `driver` can be two distinct
  #    tables and a key repointed between them then generated no migration at all.
  #
  #    The engine's case rules now live in the reader, which is the only layer that knows the
  #    engine — the same division SQLAlchemy draws with `normalize_name`/`denormalize_name` at
  #    reflection. Both readers therefore hand the comparison a canonical name, and the comparison
  #    is exact on both engines.
  #
  #    A REAL SQLite file, not a mock: the whole point is what the engine reports, and a marker
  #    struct cannot answer a PRAGMA.
  # ───────────────────────────────────────────────────────────────────────────
  @testset "#390: a REFERENCES spelling is resolved to the sqlite_master spelling" begin
    mktempdir() do dir
      pool = SQLiteConnectionPool(joinpath(dir, "case390.sqlite"); pool_size = 1)
      try
        # Created lowercase; referenced in caps. Both legal, and they disagree on purpose.
        fetch(pool, """CREATE TABLE "driver" ("id" INTEGER PRIMARY KEY AUTOINCREMENT UNIQUE NOT NULL)""")
        fetch(pool, """CREATE TABLE "pit_stop" (
                         "id"        INTEGER PRIMARY KEY AUTOINCREMENT UNIQUE NOT NULL,
                         "driver_id" INTEGER NULL,
                         FOREIGN KEY ("driver_id") REFERENCES "DRIVER"("id"))""")

        # The engine really does report the REFERENCES spelling — the premise of the whole issue.
        # Without this the assertions below could pass on a database that never posed the problem.
        fk_rows = fetch(pool, """PRAGMA foreign_key_list("pit_stop")""")
        @test String(first(fk_rows).table) == "DRIVER"

        models = convert_schema_to_models(pool; include_table = ["driver", "pit_stop"])
        by = Dict(lowercase(string(m.name)) => m for m in models)
        live_fk = by["pit_stop"].fields["driver_id"]

        # THE assertion: the breadcrumb carries the CATALOG spelling, and `.to` the binding derived
        # from it — not `DRIVER` / `DRIVER` as before.
        @test live_fk.to_table == "driver"
        @test live_fk.to == "Driver"

        # …so an exact comparison against the declared model succeeds with no fold in sight.
        parent = Models.Model("driver"; id = Models.IDField())
        declared_fk = Models.ForeignKey(parent, pk_field = "id", null = true)
        @test Models._compare_field_foreign_key(declared_fk, live_fk)
        @test Models._compare_field_foreign_key(live_fk, declared_fk)   # order-independent
      finally
        # Windows will not remove the temp dir while the handle is open; same leak as
        # test_key_type_round_trip.jl, not copied here.
        PormG.ConnectionPool.close_pool!(pool)
      end
    end
  end

  # ───────────────────────────────────────────────────────────────────────────
  # 5c. The IMPORTER half of #390, which the issue names as a reason to fix this at the reader:
  #     `_plan_inspectdb_bindings!` resolves each foreign key's target by looking `to_table` up in a
  #     PHYSICAL-TABLE ⇒ binding map. A `REFERENCES` spelling the catalog does not use missed that
  #     lookup, and `.to` was deliberately left unresolvable — a loud `set_models` failure was
  #     preferred to a case-insensitive guess that could silently bind the wrong table.
  #
  #     Two parents that COLLIDE on their derived binding, so `_dedupe_taken` has to suffix one.
  #     That makes the assertion sharp: the expected `.to` is a binding no naive derivation from the
  #     REFERENCES spelling could produce, so this cannot pass by string coincidence.
  # ───────────────────────────────────────────────────────────────────────────
  @testset "#390: a case-differing REFERENCES target now resolves to its imported binding" begin
    mktempdir() do dir
      pool = SQLiteConnectionPool(joinpath(dir, "bindings390.sqlite"); pool_size = 1)
      try
        # `driver_profile` and `driver profile` both derive the binding `Driver_profile`, so the
        # second one imported gets the dedupe suffix.
        fetch(pool, """CREATE TABLE "driver_profile" ("id" INTEGER PRIMARY KEY AUTOINCREMENT UNIQUE NOT NULL)""")
        fetch(pool, """CREATE TABLE "driver profile" ("id" INTEGER PRIMARY KEY AUTOINCREMENT UNIQUE NOT NULL)""")
        # …and the child references the SPACE-BEARING one in a case it was not created with.
        fetch(pool, """CREATE TABLE "pit_stop" (
                         "id"         INTEGER PRIMARY KEY AUTOINCREMENT UNIQUE NOT NULL,
                         "profile_id" INTEGER NULL,
                         FOREIGN KEY ("profile_id") REFERENCES "DRIVER PROFILE"("id"))""")

        models = Migrations.convert_schema_to_models(pool;
                   include_table = ["driver_profile", "driver profile", "pit_stop"])
        Migrations._plan_inspectdb_bindings!(models)

        fk = only(m for m in models if lowercase(string(m.name)) == "pit_stop").fields["profile_id"]

        # The breadcrumb is canonical, which is what let the lookup hit at all.
        @test fk.to_table == "driver profile"
        # And `.to` is the target's FINAL, collision-deduped binding — resolvable, not a dead string.
        # Pre-#390 this stayed "DRIVER_PROFILE": the lookup missed and `.to` was left as derived.
        @test fk.to == "Driver_profile2"
        @test fk.to != "DRIVER_PROFILE"
      finally
        PormG.ConnectionPool.close_pool!(pool)
      end
    end
  end

  # ───────────────────────────────────────────────────────────────────────────
  # 5b. The PostgreSQL half #390 asks for, and the reason the fold had to go rather than be kept.
  #
  #     PostgreSQL identifiers ARE case-sensitive: `Driver` and `driver` can be two distinct tables
  #     in one schema, and its reader has always reported the catalog spelling (`cf.relname`). With
  #     the fold in place, a key repointed from one to the other compared EQUAL and `makemigrations`
  #     generated nothing — a migration silently not proposed, which is worse than a spurious one.
  #
  #     This is the mutation gate for removing the fold: restore the `lowercase(...)` in
  #     `_compare_field_foreign_key` and the first assertion flips to `true`.
  # ───────────────────────────────────────────────────────────────────────────
  @testset "#390: a case-distinct PostgreSQL parent is a different table" begin
    # Mixed case reaches the declared side through `db_table`, never through the positional name —
    # `Model(...)` validates that lowercase (#300), as testset 4's header explains.
    lower_parent = Models.Model("driver"; id = Models.IDField())
    upper_parent = Models.Model("driver"; db_table = "Driver", id = Models.IDField())

    declared_lower = Models.ForeignKey(lower_parent, pk_field = "id", null = true)
    declared_upper = Models.ForeignKey(upper_parent, pk_field = "id", null = true)

    # Two live keys, each pointing at one of the two real tables.
    live_lower = Models.ForeignKey("Driver", pk_field = "id", null = true); live_lower.to_table = "driver"
    live_upper = Models.ForeignKey("Driver", pk_field = "id", null = true); live_upper.to_table = "Driver"

    # THE assertion #390 exists for: repointing between them is a genuine change and is detected.
    @test !Models._compare_field_foreign_key(declared_lower, live_upper)
    @test !Models._compare_field_foreign_key(declared_upper, live_lower)

    # Positive controls — each still matches its OWN table, so the above is not "always unequal".
    @test Models._compare_field_foreign_key(declared_lower, live_lower)
    @test Models._compare_field_foreign_key(declared_upper, live_upper)

    # And end to end, so this is not confined to the comparator: the repoint reaches the planner.
    # `:to` is not in `alter_field`'s IMPLEMENTED list, so it warns rather than rendering DDL (#498);
    # the assertion is that the difference is DETECTED, which is what #390 is about.
    settings = PormG.Configuration.Settings()
    settings.change_db = true
    declared_model = Models.Model("pit_stop", id = Models.IDField(), driver_id = declared_lower)
    live_model     = Models.Model("pit_stop", id = Models.IDField(), driver_id = live_upper)
    current_schema = Dict{Symbol, Dict{Symbol, Union{Bool, PormGModel}}}(
      :pit_stop => Dict{Symbol, Union{Bool, PormGModel}}(:model => declared_model, :exist => false))

    logs, _ = Test.collect_test_logs() do
      Migrations.get_migration_plan(PormGModel[live_model], current_schema, FkToTablePlannerMockPg(), settings)
    end
    # `"[:to]"`, not `":to"`. The bare substring also matches `:to_table` — the very attribute
    # testset 2 exists to keep OUT of `colect_not_equal` — so a regression that let the breadcrumb
    # ride along would have kept this assertion green. Match the rendered vector exactly.
    @test any(l -> l.level == Logging.Warn && occursin("[:to]", string(l.message)), logs)

    # Negative control for the planner half: the MATCHING pair must reach the planner silently, or
    # the assertion above would be satisfied by a planner that warns about everything.
    matched_model = Models.Model("pit_stop", id = Models.IDField(), driver_id = live_lower)
    matched_schema = Dict{Symbol, Dict{Symbol, Union{Bool, PormGModel}}}(
      :pit_stop => Dict{Symbol, Union{Bool, PormGModel}}(:model => declared_model, :exist => false))
    quiet_logs, _ = Test.collect_test_logs() do
      Migrations.get_migration_plan(PormGModel[matched_model], matched_schema, FkToTablePlannerMockPg(), settings)
    end
    @test !any(l -> l.level >= Logging.Warn, quiet_logs)
  end
end
