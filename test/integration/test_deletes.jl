"""
Delete Operation Integration Tests

This file consolidates all write-path DELETE integration coverage for PormG.
It exercises the public `query.delete()` surface against real database adapters
(PostgreSQL via db_2 and SQLite via db_sl) and proves that the deletion
collector, topological sort, and FK constraint handlers all work end-to-end.

Scenarios covered:
  — Delete with no matches: early-exit without mutation
  — Unfiltered delete guard: explicit opt-in required via allow_delete_all
  — Keyless model guard and direct DELETE FROM emission
    — Keyless related CASCADE: FK fallback is used when a child has no PK
  — DO_NOTHING: ORM defers to the database; PostgreSQL rejects, SQLite may permit
  — CASCADE: parent deletion removes dependent children through the collector
  — Nested CASCADE: multi-level dependency graph is walked recursively
  — SET_NULL: FK field on surviving child row is set to NULL
  — SET_NULL guard: deletion is rejected pre-mutation when FK is non-nullable
  — SET_DEFAULT: FK field on surviving child row is reset to the model default
  — RESTRICT: deletion is blocked when live referenced rows exist
  — PROTECT: deletion is blocked when child rows exist, free when orphaned
  — Filtered delete: deleting by a dynamically collected ID list
    — OR-filter delete: Qor predicates remove exactly the OR-matched rows
  — Join-filter delete: delete() respects filters written with __ join notation
    — Pagination guard: limit, offset, and order_by are rejected for delete()

Run with:
  julia -t auto --project=. test/integration/runtests.jl
    \$env:PORMG_DB="db_sl"; julia -t 1 --project=. test/integration/runtests.jl
"""

if !isdefined(Main, :PormG)
    include("common_setup.jl")
end

# When running standalone (julia test_deletes.jl), this include is at top level
# so module definitions are allowed. When running from runtests.jl, the guard
# prevents re-inclusion because runtests.jl already includes this before @testset.
if !@isdefined(ProtectM)
    include("common_delete_setup.jl")
end

# ─────────────────────────────────────────────────────────────────────────────
# Shared helpers
# ─────────────────────────────────────────────────────────────────────────────

"""Strip ANSI escape sequences from a string for plain-text comparison."""
_strip_ansi(text::AbstractString) = replace(String(text), r"\e\[[0-9;]*m" => "")

"""Return the appropriate SQL type for an explicit-ID primary key column."""
_scratch_id_type(pool) = pool isa PormG.PormGPostgres ? "SERIAL" : "INTEGER"

# ── Schema helpers: delete_protect_scratch ──────────────────────────────────

function _drop_delete_protect_scratch_schema!()
    pool = PormG.config[PORMG_DB_FOLDER].connections
    PormG.ConnectionPool.fetch(pool, "DROP TABLE IF EXISTS \"delete_protect_child_scratch\";")
    PormG.ConnectionPool.fetch(pool, "DROP TABLE IF EXISTS \"delete_protect_parent_scratch\";")
    return nothing
end

function _reset_delete_protect_scratch_schema!()
    pool = PormG.config[PORMG_DB_FOLDER].connections
    _drop_delete_protect_scratch_schema!()

    id_type = _scratch_id_type(pool)

    PormG.ConnectionPool.fetch(pool, """
    CREATE TABLE "delete_protect_parent_scratch" (
        "id" $id_type PRIMARY KEY,
        "name" TEXT NOT NULL
    );
    """)

    # Inline REFERENCES is valid on both SQLite and PostgreSQL.
    PormG.ConnectionPool.fetch(pool, """
    CREATE TABLE "delete_protect_child_scratch" (
        "id" $id_type PRIMARY KEY,
        "parent_id" INTEGER REFERENCES "delete_protect_parent_scratch" ("id"),
        "label" TEXT
    );
    """)

    return nothing
end

# ── Schema helpers: keyless_delete_scratch ───────────────────────────────────

function _drop_keyless_delete_scratch_schema!()
    pool = PormG.config[PORMG_DB_FOLDER].connections
    PormG.ConnectionPool.fetch(pool, "DROP TABLE IF EXISTS \"keyless_delete_scratch\";")
    return nothing
end

function _reset_keyless_delete_scratch_schema!()
    pool = PormG.config[PORMG_DB_FOLDER].connections
    _drop_keyless_delete_scratch_schema!()

    PormG.ConnectionPool.fetch(pool, """
    CREATE TABLE "keyless_delete_scratch" (
        "bucket" TEXT NOT NULL,
        "label" TEXT
    );
    """)

    return nothing
end

# ── Schema helpers: keyless_related_* ────────────────────────────────────────

function _drop_keyless_related_delete_scratch_schema!()
    pool = PormG.config[PORMG_DB_FOLDER].connections
    PormG.ConnectionPool.fetch(pool, "DROP TABLE IF EXISTS \"keyless_related_child_scratch\";")
    PormG.ConnectionPool.fetch(pool, "DROP TABLE IF EXISTS \"keyless_related_parent_scratch\";")
    return nothing
end

function _reset_keyless_related_delete_scratch_schema!()
    pool = PormG.config[PORMG_DB_FOLDER].connections
    _drop_keyless_related_delete_scratch_schema!()

    id_type = _scratch_id_type(pool)

    PormG.ConnectionPool.fetch(pool, """
    CREATE TABLE "keyless_related_parent_scratch" (
        "id" $id_type PRIMARY KEY,
        "name" TEXT NOT NULL
    );
    """)

    PormG.ConnectionPool.fetch(pool, """
    CREATE TABLE "keyless_related_child_scratch" (
        "parent_id" INTEGER NOT NULL REFERENCES "keyless_related_parent_scratch" ("id"),
        "label" TEXT NOT NULL
    );
    """)

    return nothing
end

# ── Schema helpers: do_nothing_delete_scratch ────────────────────────────────

function _drop_do_nothing_delete_scratch_schema!()
    pool = PormG.config[PORMG_DB_FOLDER].connections
    PormG.ConnectionPool.fetch(pool, "DROP TABLE IF EXISTS \"do_nothing_child_scratch\";")
    PormG.ConnectionPool.fetch(pool, "DROP TABLE IF EXISTS \"do_nothing_parent_scratch\";")
    return nothing
end

function _reset_do_nothing_delete_scratch_schema!()
    pool = PormG.config[PORMG_DB_FOLDER].connections
    _drop_do_nothing_delete_scratch_schema!()

    id_type = _scratch_id_type(pool)

    PormG.ConnectionPool.fetch(pool, """
    CREATE TABLE "do_nothing_parent_scratch" (
        "id" $id_type PRIMARY KEY,
        "name" TEXT NOT NULL
    );
    """)

    PormG.ConnectionPool.fetch(pool, """
    CREATE TABLE "do_nothing_child_scratch" (
        "id" $id_type PRIMARY KEY,
        "parent_id" INTEGER NOT NULL REFERENCES "do_nothing_parent_scratch" ("id"),
        "label" TEXT
    );
    """)

    return nothing
end

# ── Schema helpers: set_null_guard_scratch ────────────────────────────────────

function _drop_set_null_guard_scratch_schema!()
    pool = PormG.config[PORMG_DB_FOLDER].connections
    PormG.ConnectionPool.fetch(pool, "DROP TABLE IF EXISTS \"set_null_guard_child_scratch\";")
    PormG.ConnectionPool.fetch(pool, "DROP TABLE IF EXISTS \"set_null_guard_parent_scratch\";")
    return nothing
end

function _reset_set_null_guard_scratch_schema!()
    pool = PormG.config[PORMG_DB_FOLDER].connections
    _drop_set_null_guard_scratch_schema!()

    id_type = _scratch_id_type(pool)

    PormG.ConnectionPool.fetch(pool, """
    CREATE TABLE "set_null_guard_parent_scratch" (
        "id" $id_type PRIMARY KEY,
        "name" TEXT NOT NULL
    );
    """)

    PormG.ConnectionPool.fetch(pool, """
    CREATE TABLE "set_null_guard_child_scratch" (
        "id" $id_type PRIMARY KEY,
        "parent_id" INTEGER NOT NULL REFERENCES "set_null_guard_parent_scratch" ("id"),
        "label" TEXT
    );
    """)

    return nothing
end

# ── Schema helpers: set_default_guard_scratch ─────────────────────────────────

function _drop_set_default_guard_scratch_schema!()
    pool = PormG.config[PORMG_DB_FOLDER].connections
    PormG.ConnectionPool.fetch(pool, "DROP TABLE IF EXISTS \"set_default_guard_child_scratch\";")
    PormG.ConnectionPool.fetch(pool, "DROP TABLE IF EXISTS \"set_default_guard_parent_scratch\";")
    return nothing
end

function _reset_set_default_guard_scratch_schema!()
    pool = PormG.config[PORMG_DB_FOLDER].connections
    _drop_set_default_guard_scratch_schema!()

    id_type = _scratch_id_type(pool)

    PormG.ConnectionPool.fetch(pool, """
    CREATE TABLE "set_default_guard_parent_scratch" (
        "id" $id_type PRIMARY KEY,
        "name" TEXT NOT NULL
    );
    """)

    PormG.ConnectionPool.fetch(pool, """
    CREATE TABLE "set_default_guard_child_scratch" (
        "id" $id_type PRIMARY KEY,
        "parent_id" INTEGER NOT NULL REFERENCES "set_default_guard_parent_scratch" ("id"),
        "label" TEXT
    );
    """)

    return nothing
end

# ── Fixture helpers ───────────────────────────────────────────────────────────

"""
Remove any residual scratch rows from the three-level deletion graph
(Just_a_nested_roll_back → Just_a_test_deletion → Result).
Pass result_id=0 to skip the Result cleanup.
"""
function _cleanup_scratch_delete_graph!(result_id::Int; deletion_ids::Vector{Int}=Int[], nested_ids::Vector{Int}=Int[])
    if !isempty(nested_ids)
        q = M.Just_a_nested_roll_back.objects
        q.filter("id__@in" => nested_ids)
        q.exists() && q.delete()
    end

    if !isempty(deletion_ids)
        q = M.Just_a_test_deletion.objects
        q.filter("id__@in" => deletion_ids)
        q.exists() && q.delete()
    end

    if result_id > 0
        q = M.Result.objects
        q.filter("resultid" => result_id)
        q.exists() && q.delete()
    end

    return nothing
end

"""
Clone Result row 1 under a new `result_id` to provide a scratch FK target
without touching any seeded fixture data.
"""
function _seed_scratch_result!(result_id::Int)
    template = M.Result.objects.filter("resultid" => 1).list() |> first

    scratch_q = M.Result.objects
    scratch_q.filter("resultid" => result_id)
    scratch_q.exists() && scratch_q.delete()

    return M.Result.objects.create(
        "resultid"        => result_id,
        "raceid"          => template[:raceid],
        "driverid"        => template[:driverid],
        "constructorid"   => template[:constructorid],
        "number"          => template[:number],
        "grid"            => template[:grid],
        "position"        => template[:position],
        "positiontext"    => "scratch-$(result_id)",
        "positionorder"   => result_id % 1000,
        "points"          => template[:points],
        "laps"            => template[:laps],
        "time"            => template[:time],
        "milliseconds"    => template[:milliseconds],
        "fastestlap"      => template[:fastestlap],
        "rank"            => template[:rank],
        "fastestlaptime"  => template[:fastestlaptime],
        "fastestlapspeed" => template[:fastestlapspeed],
        "statusid"        => template[:statusid]
    )
end

# ─────────────────────────────────────────────────────────────────────────────
# Test suites
# ─────────────────────────────────────────────────────────────────────────────

@testset "Delete Operations with FK Constraints" begin

    # ─────────────────────────────────────────────────────────────────────────
    # A filtered delete that matches no rows should short-circuit cleanly and
    # report zero work instead of warning, mutating state, or building a bogus
    # deletion plan. This covers the execute-time do_exists early return.
    # ─────────────────────────────────────────────────────────────────────────
    @testset "Delete with No Matches: Returns Empty Count" begin
        # This slug cannot exist because the cleanup runs first and no seed
        # creates it, so we can reliably test the zero-row early exit.
        missing_slug = "delete-missing-990508"

        delete_query = M.Field_validation_scratch.objects
        delete_query.filter("slug" => missing_slug)
        delete_query.exists() && delete_query.delete()  # idempotent ensure-absent

        total_deleted, deleted_counter = delete_query.delete()

        @test total_deleted == 0
        @test isempty(deleted_counter)
        @test !M.Field_validation_scratch.objects.filter("slug" => missing_slug).exists()
    end

    # ─────────────────────────────────────────────────────────────────────────
    # Public delete should refuse unfiltered destructive operations unless the
    # caller explicitly opts in with allow_delete_all=true.
    # This proves the guard runs in the executing code path, not just in tests
    # that use it for cleanup.
    # ─────────────────────────────────────────────────────────────────────────
    @testset "Delete Guard: Unfiltered Delete is Rejected" begin
        # Seed one row so the table is non-empty — the guard must reject the
        # delete regardless of row count.
        scratch_slug = "delete-guard-990507"

        try
            M.Field_validation_scratch.objects.create(
                "uuid_token"   => string(uuid4()),
                "canonical_url" => "https://f1.example.com/delete-guard",
                "slug"         => scratch_slug,
                "payload"      => Dict("kind" => "guard")
            )

            # No filter applied → must throw an informative error.
            err = try
                M.Field_validation_scratch.objects.delete()
                nothing
            catch e
                e
            end

            @test err !== nothing
            # The guard message reads: "delete must have a filter"
            @test occursin("delete must have a filter", lowercase(string(err)))

            # The seed row must still be present — no rows should have been touched.
            @test M.Field_validation_scratch.objects.filter("slug" => scratch_slug).count() == 1
        finally
            q = M.Field_validation_scratch.objects
            q.filter("slug" => scratch_slug)
            q.exists() && q.delete()
        end
    end

    # ─────────────────────────────────────────────────────────────────────────
    # Keyless fixture tables have a dedicated delete path:
    #   • A filtered delete on a keyless model must be rejected with
    #     ArgumentError (no PK to build a WHERE … IN subquery).
    #   • allow_delete_all=true must emit a bare DELETE FROM … and remove all rows.
    #   • show_query=:dict on the unfiltered path must return meaningful SQL
    #     without touching data.
    # ─────────────────────────────────────────────────────────────────────────
    @testset "Delete on Keyless Models: Guard and Direct SQL" begin
        # Verify that a seeded Lap_times row is present but cannot be deleted
        # through a filtered query because the model has no PK field.
        lap_query = M.Lap_times.objects
        lap_query.filter("raceid" => 841, "driverid" => 20, "lap" => 1)

        @test lap_query.count() == 1
        @test_throws PormGError lap_query.delete()
        @test lap_query.count() == 1   # Row must still be there after the rejected attempt.

        # Inspection of the delete-all path must produce well-formed SQL without
        # executing any mutation (show_query=:dict).
        inspection = M.Lap_times.objects.delete(allow_delete_all = true, show_query = :dict)
        @test inspection[:operation] === :delete
        @test inspection[:parameter_count] == 0
        @test isempty(inspection[:parameters])
        @test occursin("delete from lap_times", lowercase(inspection[:sql_text]))

        # Now exercise the actual delete-all path against the scratch table so
        # we do not touch the seeded F1 fixture data.
        _reset_keyless_delete_scratch_schema!()

        try
            KeylessM.Keyless_delete_scratch.objects.create("bucket" => "alpha", "label" => "row-a")
            KeylessM.Keyless_delete_scratch.objects.create("bucket" => "beta",  "label" => "row-b")

            @test KeylessM.Keyless_delete_scratch.objects.count() == 2

            total_deleted, deleted_counter = KeylessM.Keyless_delete_scratch.objects.delete(allow_delete_all = true)

            @test total_deleted == 2
            @test deleted_counter == Dict("keyless_delete_scratch" => 2)
            @test !KeylessM.Keyless_delete_scratch.objects.exists()
        finally
            _drop_keyless_delete_scratch_schema!()
        end
    end

    # ─────────────────────────────────────────────────────────────────────────
    # Keyless related CASCADE: when a child table has no primary key, the
    # collector must use the FK field that points at the deleted parent. This
    # exercises the fallback delete-key path that direct keyless DELETE cannot.
    # ─────────────────────────────────────────────────────────────────────────
    @testset "Delete with CASCADE: Keyless related child uses FK fallback" begin
        parent_id = 940001

        _reset_keyless_related_delete_scratch_schema!()

        try
            KeylessRelatedM.Keyless_related_parent_scratch.objects.create(
                "id"   => parent_id,
                "name" => "keyless-parent"
            )
            KeylessRelatedM.Keyless_related_child_scratch.objects.create(
                "parent_id" => parent_id,
                "label"     => "child-a"
            )
            KeylessRelatedM.Keyless_related_child_scratch.objects.create(
                "parent_id" => parent_id,
                "label"     => "child-b"
            )

            @test KeylessRelatedM.Keyless_related_child_scratch.objects.filter("parent_id" => parent_id).count() == 2

            delete_q = KeylessRelatedM.Keyless_related_parent_scratch.objects
            delete_q.filter("id" => parent_id)
            total_deleted, deleted_counter = delete_q.delete()

            @test total_deleted == 3
            @test deleted_counter["keyless_related_parent_scratch"] == 1
            @test deleted_counter["keyless_related_child_scratch"] == 2
            @test !KeylessRelatedM.Keyless_related_parent_scratch.objects.filter("id" => parent_id).exists()
            @test !KeylessRelatedM.Keyless_related_child_scratch.objects.filter("parent_id" => parent_id).exists()
        finally
            _drop_keyless_related_delete_scratch_schema!()
        end
    end

    # ─────────────────────────────────────────────────────────────────────────
    # DO_NOTHING should not be preemptively handled by the collector.  The ORM
    # attempts the parent delete directly and defers the final outcome to the
    # backend — and since #276 both backends reject the FK violation, so there is
    # no longer an adapter branch here. (SQLite used to permit it: PormG never set
    # PRAGMA foreign_keys, so the delete succeeded and orphaned the child.)
    # ─────────────────────────────────────────────────────────────────────────
    @testset "Delete with DO_NOTHING: ORM Defers to Database" begin
        parent_id = 920001
        child_id  = 920101

        _reset_do_nothing_delete_scratch_schema!()

        try
            DoNothingM.Do_nothing_parent_scratch.objects.create(
                "id"   => parent_id,
                "name" => "do-nothing-parent"
            )
            DoNothingM.Do_nothing_child_scratch.objects.create(
                "id"       => child_id,
                "parent_id" => parent_id,
                "label"    => "db-protected-child"
            )

            # Inspection must not raise and must return a DELETE from the parent table.
            inspect_q = DoNothingM.Do_nothing_parent_scratch.objects
            inspect_q.filter("id" => parent_id)
            inspection = inspect_q.delete(show_query = :dict)

            @test inspection isa Dict
            @test inspection[:operation] == :delete
            @test occursin("delete from do_nothing_parent_scratch", lowercase(inspection[:sql_text]))

            # Live delete — the database refuses it on both backends since #276.
            delete_q = DoNothingM.Do_nothing_parent_scratch.objects
            delete_q.filter("id" => parent_id)

            delete_result = try
                delete_q.delete()
            catch e
                e
            end

            # #276: both backends now enforce the FK at execute time, so the branch is gone. SQLite
            # used to permit the dangling row (`PRAGMA foreign_keys` defaults OFF and PormG never
            # turned it on), which meant a DO_NOTHING delete quietly orphaned children on SQLite and
            # failed on PostgreSQL — the divergence #276 removed. The ORM defers to the database
            # either way; the difference was only whether the database bothered to check.
            @test delete_result isa PormG.IntegrityError   # the constraint, not merely "something threw"
            @test !(delete_result isa Tuple)               # pre-#276 SQLite returned (1, Dict(...))
            @test DoNothingM.Do_nothing_parent_scratch.objects.filter("id" => parent_id).exists()

            # The child must still be present — the ORM did not touch it.
            @test DoNothingM.Do_nothing_child_scratch.objects.filter("id" => child_id).exists()
        finally
            _drop_do_nothing_delete_scratch_schema!()
        end
    end

    # ─────────────────────────────────────────────────────────────────────────
    # CASCADE: deleting a scratch Result should cascade through the collector
    # to the Just_a_test_deletion rows that reference it via the FK
    # test_result → Result(resultid).
    # ─────────────────────────────────────────────────────────────────────────
    @testset "Delete with CASCADE: Verify Related Records are Removed" begin
        scratch_result_id = 990001
        child_ids         = [990101, 990102, 990103]

        _cleanup_scratch_delete_graph!(scratch_result_id; deletion_ids=child_ids)
        _seed_scratch_result!(scratch_result_id)

        try
            for (index, child_id) in enumerate(child_ids)
                M.Just_a_test_deletion.objects.create(
                    "id"          => child_id,
                    "name"        => "cascade-child-$(index)",
                    "test_result" => scratch_result_id
                )
            end

            child_query = M.Just_a_test_deletion.objects
            child_query.filter("id__@in" => child_ids)
            @test child_query.count() == 3

            inspect_q = M.Result.objects
            inspect_q.filter("resultid" => scratch_result_id)
            inspection = inspect_q.delete(show_query = :dict)

            @test inspection isa Vector
            @test any(item -> item[:operation] == :delete && item[:model] == "result", inspection)
            @test any(item -> item[:operation] == :delete && item[:model] == "just_a_test_deletion", inspection)
            @test M.Result.objects.filter("resultid" => scratch_result_id).count() == 1
            @test M.Just_a_test_deletion.objects.filter("id__@in" => child_ids).count() == 3

            # Deleting the parent Result must cascade to all three children.
            delete_query = M.Result.objects
            delete_query.filter("resultid" => scratch_result_id)
            total_deleted, deleted_counter = delete_query.delete()

            # 1 parent + 3 children = 4 minimum; there may be more if other FK
            # columns on Just_a_test_deletion also pointed to this result_id.
            @test total_deleted >= 4
            @test haskey(deleted_counter, "result")
            @test haskey(deleted_counter, "just_a_test_deletion")
            @test M.Result.objects.filter("resultid" => scratch_result_id).count() == 0
            @test M.Just_a_test_deletion.objects.filter("id__@in" => child_ids).count() == 0
        finally
            _cleanup_scratch_delete_graph!(scratch_result_id; deletion_ids=child_ids)
        end
    end

    # ─────────────────────────────────────────────────────────────────────────
    # SET_NULL: deleting a parent row must nullify the FK field on every
    # surviving child row that points at it through the test_result_set_null column.
    # ─────────────────────────────────────────────────────────────────────────
    @testset "Delete with SET_NULL: Verify FK Field Nullified" begin
        scratch_result_id = 990003
        survivor_id       = 990401

        _cleanup_scratch_delete_graph!(scratch_result_id; deletion_ids=[survivor_id])
        _seed_scratch_result!(scratch_result_id)

        try
            M.Just_a_test_deletion.objects.create(
                "id"                    => survivor_id,
                "name"                  => "set-null-child",
                "test_result_set_null"  => scratch_result_id
            )

            seeded_q = M.Just_a_test_deletion.objects
            seeded_q.filter("id" => survivor_id)
            @test seeded_q.count() == 1

            seeded_row = seeded_q.values("test_result_set_null").list() |> first
            @test seeded_row[:test_result_set_null] == scratch_result_id

            # Delete the parent — the collector must UPDATE the child FK to NULL,
            # not cascade-delete the child row.
            delete_q = M.Result.objects
            delete_q.filter("resultid" => scratch_result_id)
            total_deleted, deleted_counter = delete_q.delete()

            @test total_deleted == 1
            @test deleted_counter == Dict("result" => 1)
            @test M.Result.objects.filter("resultid" => scratch_result_id).count() == 0

            # Child must still exist; its FK column must now be NULL.
            survivor_q = M.Just_a_test_deletion.objects
            survivor_q.filter("id" => survivor_id)
            @test survivor_q.count() == 1

            survivor_row = survivor_q.values("id", "test_result_set_null").list() |> first
            @test survivor_row[:id] == survivor_id
            @test ismissing(survivor_row[:test_result_set_null]) || isnothing(survivor_row[:test_result_set_null])
        finally
            _cleanup_scratch_delete_graph!(scratch_result_id; deletion_ids=[survivor_id])
        end
    end

    # ─────────────────────────────────────────────────────────────────────────
    # SET_NULL guard: if the FK field is declared non-nullable (null=false),
    # the collector must raise ArgumentError before sending any SQL.
    # ─────────────────────────────────────────────────────────────────────────
    @testset "Delete with SET_NULL: Non-null FK is Rejected" begin
        parent_id = 930001
        child_id  = 930101

        _reset_set_null_guard_scratch_schema!()

        try
            SetNullGuardM.Set_null_guard_parent_scratch.objects.create(
                "id"   => parent_id,
                "name" => "set-null-guard-parent"
            )
            SetNullGuardM.Set_null_guard_child_scratch.objects.create(
                "id"       => child_id,
                "parent_id" => parent_id,
                "label"    => "nonnull-child"
            )

            delete_q = SetNullGuardM.Set_null_guard_parent_scratch.objects
            delete_q.filter("id" => parent_id)

            err = try
                delete_q.delete()
                nothing
            catch e
                e
            end

            # #268 audit: SET_NULL on a null=false FK is a schema self-contradiction — typed
            # ModelDefinitionError, and the message names the contradiction rather than the row.
            @test err isa ModelDefinitionError
            msg = _strip_ansi(lowercase(sprint(showerror, err)))
            # The error must identify the field name and the schema contradiction.
            @test occursin("parent_id", msg)
            @test occursin("null=true", msg)

            # Both rows must be untouched.
            @test SetNullGuardM.Set_null_guard_parent_scratch.objects.filter("id" => parent_id).exists()
            @test SetNullGuardM.Set_null_guard_child_scratch.objects.filter("id" => child_id).exists()
        finally
            _drop_set_null_guard_scratch_schema!()
        end
    end

    # ─────────────────────────────────────────────────────────────────────────
    # SET_DEFAULT guard (#287): a FK declared SET_DEFAULT with no default is the
    # mirror image of the SET_NULL contradiction. Before #287 the missing default
    # flowed into update_field as a bare NULL — SET_DEFAULT silently acted as
    # SET_NULL and then violated the column's NOT NULL constraint. The collector
    # must now refuse before any SQL is sent.
    # ─────────────────────────────────────────────────────────────────────────
    @testset "Delete with SET_DEFAULT: Missing default is Rejected" begin
        parent_id = 940001
        child_id  = 940101

        _reset_set_default_guard_scratch_schema!()

        try
            SetDefaultGuardM.Set_default_guard_parent_scratch.objects.create(
                "id"   => parent_id,
                "name" => "set-default-guard-parent"
            )
            SetDefaultGuardM.Set_default_guard_child_scratch.objects.create(
                "id"        => child_id,
                "parent_id" => parent_id,
                "label"     => "no-default-child"
            )

            delete_q = SetDefaultGuardM.Set_default_guard_parent_scratch.objects
            delete_q.filter("id" => parent_id)

            err = try
                delete_q.delete()
                nothing
            catch e
                e
            end

            # Typed, and the message must name the contradiction rather than the row.
            # NB: the table is named set_default_guard_child_scratch, so `occursin("default")` or
            # `occursin("parent_id")` would be satisfied by any database error that merely mentions
            # the table. Match on wording only this guard produces.
            @test err isa ModelDefinitionError
            msg = _strip_ansi(lowercase(sprint(showerror, err)))
            @test occursin("no default", msg)
            @test occursin("default=", msg)

            # The negative half — this is what proves it refused BEFORE writing. If the guard
            # regressed to the old behaviour the child's FK would have been nulled (or the
            # statement would have failed mid-transaction), so asserting both rows survive
            # intact is what actually fails on a regression.
            @test SetDefaultGuardM.Set_default_guard_parent_scratch.objects.filter("id" => parent_id).exists()
            survivor = SetDefaultGuardM.Set_default_guard_child_scratch.objects.
                filter("id" => child_id).values("id", "parent_id").list() |> first
            @test survivor[:parent_id] == parent_id
        finally
            _drop_set_default_guard_scratch_schema!()
        end
    end

    # ─────────────────────────────────────────────────────────────────────────
    # SET_DEFAULT: deleting a parent row must reset the FK column on surviving
    # children to the declared default value (default=1 → Result row 1).
    # ─────────────────────────────────────────────────────────────────────────
    @testset "Delete with SET_DEFAULT: Verify FK Field Reset" begin
        scratch_result_id = 990004
        survivor_id       = 990402

        _cleanup_scratch_delete_graph!(scratch_result_id; deletion_ids=[survivor_id])
        _seed_scratch_result!(scratch_result_id)

        try
            M.Just_a_test_deletion.objects.create(
                "id"                      => survivor_id,
                "name"                    => "set-default-child",
                "test_result_set_default" => scratch_result_id
            )

            seeded_q = M.Just_a_test_deletion.objects
            seeded_q.filter("id" => survivor_id)
            @test seeded_q.count() == 1

            seeded_row = seeded_q.values("test_result_set_default").list() |> first
            @test seeded_row[:test_result_set_default] == scratch_result_id

            delete_q = M.Result.objects
            delete_q.filter("resultid" => scratch_result_id)
            total_deleted, deleted_counter = delete_q.delete()

            # Only the one Result row should appear in the deletion counter;
            # the child row is preserved with the FK reset to the default.
            @test total_deleted == 1
            @test deleted_counter == Dict("result" => 1)
            @test M.Result.objects.filter("resultid" => scratch_result_id).count() == 0

            survivor_q = M.Just_a_test_deletion.objects
            survivor_q.filter("id" => survivor_id)
            @test survivor_q.count() == 1

            survivor_row = survivor_q.values("id", "test_result_set_default").list() |> first
            @test survivor_row[:id] == survivor_id
            # The FK must now point at the default value declared on the model (resultid=1).
            @test survivor_row[:test_result_set_default] == 1
        finally
            cleanup_q = M.Just_a_test_deletion.objects
            cleanup_q.filter("id" => survivor_id)
            cleanup_q.exists() && cleanup_q.delete()
            _cleanup_scratch_delete_graph!(scratch_result_id)
        end
    end

    # ─────────────────────────────────────────────────────────────────────────
    # RESTRICT uses existing seeded Driver relationships. Any Driver row is
    # referenced by Lap_times, Driver_standings, and several other tables that
    # declare ON DELETE RESTRICT, so the collector must raise before any rows
    # are mutated.
    # ─────────────────────────────────────────────────────────────────────────
    @testset "Delete with RESTRICT: Verify Deletion is Blocked" begin
        restricted_q = M.Driver.objects
        restricted_q.filter("driverid" => 1)

        @test restricted_q.count() == 1

        err = try
            restricted_q.delete()
            nothing
        catch e
            e
        end

        # #268 audit: PROTECT/RESTRICT refusal is ProtectedError — the data forbids the delete,
        # distinct from a malformed call. A supertype assertion here would pass for the old
        # QueryBuildError too, proving nothing about the retype.
        @test err isa ProtectedError
        msg = _strip_ansi(lowercase(sprint(showerror, err)))
        # The error must name the parent table, the offending FK field,
        # and the on_delete constraint type.
        @test occursin("cannot delete driver", msg)
        @test occursin("on delete restrict", msg)
        @test occursin(".driverid", msg)

        # The driver row must still be present.
        @test M.Driver.objects.filter("driverid" => 1).count() == 1
    end

    # ─────────────────────────────────────────────────────────────────────────
    # PROTECT should only block delete when matching child rows exist; an
    # orphaned parent (no children) must be deletable through the public API.
    # This also confirms that show_query=:dict inspection does not raise PROTECT
    # errors when the reverse relation happens to be empty at inspect time.
    # ─────────────────────────────────────────────────────────────────────────
    @testset "Delete with PROTECT: Empty reverse relation does not block inspection" begin
        orphan_parent_id    = 910001
        protected_parent_id = 910002
        child_id            = 910101

        _reset_delete_protect_scratch_schema!()

        try
            # Case 1: parent with no children — delete must succeed.
            ProtectM.Delete_protect_parent_scratch.objects.create(
                "id"   => orphan_parent_id,
                "name" => "orphan-parent"
            )

            @test !ProtectM.Delete_protect_child_scratch.objects.filter("parent_id" => orphan_parent_id).exists()

            # Inspection must not raise even though PROTECT is declared.
            inspect_q = ProtectM.Delete_protect_parent_scratch.objects
            inspect_q.filter("id" => orphan_parent_id)
            inspection = inspect_q.delete(show_query = :dict)

            @test inspection isa Dict
            @test inspection[:operation] == :delete
            @test occursin("delete from delete_protect_parent_scratch", lowercase(inspection[:sql_text]))

            # Live delete of the orphaned parent must succeed.
            delete_q = ProtectM.Delete_protect_parent_scratch.objects
            delete_q.filter("id" => orphan_parent_id)
            total_deleted, deleted_counter = delete_q.delete()

            @test total_deleted == 1
            @test deleted_counter == Dict("delete_protect_parent_scratch" => 1)
            @test !ProtectM.Delete_protect_parent_scratch.objects.filter("id" => orphan_parent_id).exists()

            # Case 2: parent with a child — delete must be blocked by PROTECT.
            ProtectM.Delete_protect_parent_scratch.objects.create(
                "id"   => protected_parent_id,
                "name" => "protected-parent"
            )
            ProtectM.Delete_protect_child_scratch.objects.create(
                "id"       => child_id,
                "parent_id" => protected_parent_id,
                "label"    => "blocking-child"
            )

            protected_q = ProtectM.Delete_protect_parent_scratch.objects
            protected_q.filter("id" => protected_parent_id)

            err = try
                protected_q.delete()
                nothing
            catch e
                e
            end

            @test err isa PormGError
            msg = _strip_ansi(sprint(showerror, err))
            # Error must identify the parent table, the child FK field, and the constraint.
            @test occursin("Cannot delete delete_protect_parent_scratch", msg)
            @test occursin("delete_protect_child_scratch.parent_id", msg)
            @test occursin("ON DELETE PROTECT", msg)
            # Parent row must still be present.
            @test ProtectM.Delete_protect_parent_scratch.objects.filter("id" => protected_parent_id).exists()
        finally
            _drop_delete_protect_scratch_schema!()
        end
    end

    # ─────────────────────────────────────────────────────────────────────────
    # Nested CASCADE: deleting a Just_a_test_deletion parent must also remove
    # its Just_a_nested_roll_back descendants (two levels deep), while leaving
    # sibling branches of the Just_a_test_deletion graph intact.
    # ─────────────────────────────────────────────────────────────────────────
    @testset "Nested CASCADE Delete: Multiple Levels Deep" begin
        scratch_result_id = 990002
        child_ids         = [990201, 990202]
        nested_ids        = [990301, 990302, 990303]

        _cleanup_scratch_delete_graph!(scratch_result_id; deletion_ids=child_ids, nested_ids=nested_ids)
        _seed_scratch_result!(scratch_result_id)

        try
            # Level 1: two Just_a_test_deletion rows that reference the scratch Result.
            M.Just_a_test_deletion.objects.create("id" => child_ids[1], "name" => "nested-parent-a", "test_result" => scratch_result_id)
            M.Just_a_test_deletion.objects.create("id" => child_ids[2], "name" => "nested-parent-b", "test_result" => scratch_result_id)

            # Level 2: nested rolls — two children under child_ids[1], one under child_ids[2].
            M.Just_a_nested_roll_back.objects.create("id" => nested_ids[1], "test" => child_ids[1], "description" => "nested-child-a")
            M.Just_a_nested_roll_back.objects.create("id" => nested_ids[2], "test" => child_ids[1], "description" => "nested-child-b")
            M.Just_a_nested_roll_back.objects.create("id" => nested_ids[3], "test" => child_ids[2], "description" => "nested-child-c")

            child_q  = M.Just_a_test_deletion.objects; child_q.filter("id__@in" => child_ids)
            nested_q = M.Just_a_nested_roll_back.objects; nested_q.filter("id__@in" => nested_ids)
            @test child_q.count()  == 2
            @test nested_q.count() == 3

            # Delete only child_ids[1] — its two nested rows must be removed,
            # but child_ids[2] and nested_ids[3] must survive.
            delete_q = M.Just_a_test_deletion.objects
            delete_q.filter("id" => child_ids[1])
            total_deleted, deleted_counter = delete_q.delete()

            # 1 Just_a_test_deletion + 2 Just_a_nested_roll_back = 3 rows.
            @test total_deleted == 3
            @test haskey(deleted_counter, "just_a_test_deletion")
            @test haskey(deleted_counter, "just_a_nested_roll_back")

            # The scratch Result is untouched (it was not in the delete scope).
            @test M.Result.objects.filter("resultid" => scratch_result_id).count() == 1

            # The deleted branch is gone; the sibling branch survives.
            @test M.Just_a_test_deletion.objects.filter("id" => child_ids[1]).count() == 0
            @test M.Just_a_test_deletion.objects.filter("id" => child_ids[2]).count() == 1
            @test M.Just_a_nested_roll_back.objects.filter("id__@in" => nested_ids[1:2]).count() == 0
            @test M.Just_a_nested_roll_back.objects.filter("id" => nested_ids[3]).count() == 1
        finally
            _cleanup_scratch_delete_graph!(scratch_result_id; deletion_ids=child_ids, nested_ids=nested_ids)
        end
    end

end  # @testset "Delete Operations with FK Constraints"


# ─────────────────────────────────────────────────────────────────────────────
# Filtered delete — basic execution sanity
# Verifies that a filtered delete actually removes the matching record and that
# nothing else is mutated. Complements the pure SQL inspection in unit tests.
# ─────────────────────────────────────────────────────────────────────────────
@testset "DELETE: Filtered Delete Removes Exactly the Matching Row" begin
    scratch_id = 880002

    # Ensure the row is absent, then seed it.
    M.Just_a_test_deletion.objects.filter("id" => scratch_id).exists() &&
        M.Just_a_test_deletion.objects.filter("id" => scratch_id).delete()

    M.Just_a_test_deletion.objects.create("id" => scratch_id, "name" => "to-be-deleted")
    @test M.Just_a_test_deletion.objects.filter("id" => scratch_id).exists()

    # Execute the filtered delete.
    total, counter = M.Just_a_test_deletion.objects.filter("id" => scratch_id).delete()

    @test !M.Just_a_test_deletion.objects.filter("id" => scratch_id).exists()
    @test total == 1
    @test counter["just_a_test_deletion"] == 1
end


# ─────────────────────────────────────────────────────────────────────────────
# Filtered delete by dynamically collected ID list
# This pattern is common in ETL code: query a result set, extract PKs, then
# delete exactly those rows. The test proves that `id__@in` filtering works
# correctly through the public delete surface rather than allow_delete_all.
# ─────────────────────────────────────────────────────────────────────────────
@testset "DELETE: Delete by Dynamically Collected ID List" begin
    # Ensure a clean slate.
    M.Just_a_test_deletion.objects.exists() &&
        M.Just_a_test_deletion.objects.delete(allow_delete_all = true)

    M.Just_a_test_deletion.objects.create("name" => "del_1", "test_result" => 1)
    M.Just_a_test_deletion.objects.create("name" => "del_2", "test_result" => 2)
    M.Just_a_test_deletion.objects.create("name" => "del_3", "test_result" => 3)
    M.Just_a_test_deletion.objects.create("name" => "del_keep", "test_result" => 4)

    # Collect the IDs for the rows that should be removed.
    df  = M.Just_a_test_deletion.objects.filter("name__@icontains" => "del_").order_by("id") |> DataFrame
    ids = df.id[1:3] |> collect |> unique |> sort

    M.Just_a_test_deletion.objects.filter("id__@in" => ids).delete()

    # The three targeted rows must be gone; the keeper row must survive.
    @test M.Just_a_test_deletion.objects.filter("id__@in" => ids).count() == 0
    @test M.Just_a_test_deletion.objects.filter("name" => "del_keep").count() == 1

    # Cleanup
    M.Just_a_test_deletion.objects.exists() &&
        M.Just_a_test_deletion.objects.delete(allow_delete_all = true)
end


# ─────────────────────────────────────────────────────────────────────────────
# Delete with Qor filters
# Mirrors the update-path Qor coverage and proves OR filters feed the DELETE
# subquery without widening the target set to unrelated rows.
# ─────────────────────────────────────────────────────────────────────────────
@testset "DELETE: Qor filters remove exactly OR-matched rows" begin
    M.Just_a_test_deletion.objects.exists() &&
        M.Just_a_test_deletion.objects.delete(allow_delete_all = true)

    try
        result_rows = M.Result.objects.order_by("resultid").limit(3).values("resultid").list()
        @test length(result_rows) == 3
        result_ids = [row[:resultid] for row in result_rows]

        M.Just_a_test_deletion.objects.create("name" => "delete-qor-a", "test_result" => result_ids[1])
        M.Just_a_test_deletion.objects.create("name" => "delete-qor-b", "test_result" => result_ids[2])
        M.Just_a_test_deletion.objects.create("name" => "delete-qor-keep", "test_result" => result_ids[3])

        delete_q = M.Just_a_test_deletion.objects
        delete_q.filter(Qor("name" => "delete-qor-a", "test_result" => result_ids[2]))
        total_deleted, deleted_counter = delete_q.delete()

        @test total_deleted == 2
        @test deleted_counter["just_a_test_deletion"] == 2
        @test !M.Just_a_test_deletion.objects.filter("name" => "delete-qor-a").exists()
        @test !M.Just_a_test_deletion.objects.filter("name" => "delete-qor-b").exists()
        @test M.Just_a_test_deletion.objects.filter("name" => "delete-qor-keep").count() == 1
    finally
        M.Just_a_test_deletion.objects.exists() &&
            M.Just_a_test_deletion.objects.delete(allow_delete_all = true)
    end
end


# ─────────────────────────────────────────────────────────────────────────────
# Pagination guard on delete(): the deletion collector counts and cascades full
# object sets, so limit, offset, and order_by are rejected instead of silently
# producing adapter-specific bounded-delete semantics.
# ─────────────────────────────────────────────────────────────────────────────
@testset "delete() rejects limit, offset, and order_by" begin
    M.Just_a_test_deletion.objects.exists() &&
        M.Just_a_test_deletion.objects.delete(allow_delete_all = true)

    try
        M.Just_a_test_deletion.objects.create("name" => "delete-guard-a", "test_result" => 1)
        M.Just_a_test_deletion.objects.create("name" => "delete-guard-b", "test_result" => 2)

        err_limit = try
            M.Just_a_test_deletion.objects.filter("name__@contains" => "delete-guard").limit(1).delete()
            nothing
        catch e
            e
        end
        @test err_limit isa PormGError
        @test occursin("limit", lowercase(sprint(showerror, err_limit)))

        err_offset = try
            M.Just_a_test_deletion.objects.filter("name__@contains" => "delete-guard").offset(1).delete()
            nothing
        catch e
            e
        end
        @test err_offset isa PormGError
        @test occursin("offset", lowercase(sprint(showerror, err_offset)))

        err_order = try
            M.Just_a_test_deletion.objects.filter("name__@contains" => "delete-guard").order_by("id").delete()
            nothing
        catch e
            e
        end
        @test err_order isa PormGError
        @test occursin("order_by", lowercase(sprint(showerror, err_order)))

        @test M.Just_a_test_deletion.objects.filter("name__@contains" => "delete-guard").count() == 2
    finally
        M.Just_a_test_deletion.objects.exists() &&
            M.Just_a_test_deletion.objects.delete(allow_delete_all = true)
    end
end


# ─────────────────────────────────────────────────────────────────────────────
# Delete with JOIN filter (double-underscore traversal)
#
# PormG translates `delete()` to `DELETE FROM … WHERE pk IN (SELECT pk FROM …)`.
# The inner SELECT is constructed by the standard query builder and therefore
# supports the same __ join notation as `filter()` on read queries.
#
# This testset proves that join-based predicates survive the translation into
# a delete-path subquery on both PostgreSQL and SQLite — a regression surface
# that is invisible to pure SQL inspection tests.
# ─────────────────────────────────────────────────────────────────────────────
@testset "DELETE: Filter via JOIN notation (__ traversal)" begin
    # Ensure a clean slate.
    M.Just_a_test_deletion.objects.exists() &&
        M.Just_a_test_deletion.objects.delete(allow_delete_all = true)

    # Seed rows with FK pointers into the F1 fixture data:
    #   - test_result=1  → Result 1 → Driver 1 (Lewis Hamilton, British, Australian GP, Australia)
    #   - test_result=2  → Result 2 → Driver 2 (Nick Heidfeld, German)
    # Both results exist in the seeded F1 dataset.
    M.Just_a_test_deletion.objects.create("name" => "british-driver-row",  "test_result" => 1)
    M.Just_a_test_deletion.objects.create("name" => "non-british-row",     "test_result" => 2)

    @test M.Just_a_test_deletion.objects.count() == 2

    # Delete only the row whose result FK leads to a British driver.
    # The ORM must generate a correlated subquery that walks:
    #   just_a_test_deletion → result → driver (nationality = 'British')
    M.Just_a_test_deletion.objects.filter(
        "test_result__driverid__nationality" => "British"
    ).delete()

    # The British-driver row must be gone; the German-driver row must survive.
    @test M.Just_a_test_deletion.objects.filter("name" => "british-driver-row").count() == 0
    @test M.Just_a_test_deletion.objects.filter("name" => "non-british-row").count() == 1

    # Cleanup
    M.Just_a_test_deletion.objects.exists() &&
        M.Just_a_test_deletion.objects.delete(allow_delete_all = true)
end

@testset "DELETE: Filter via deep JOIN chain (3 levels)" begin
    # Ensure a clean slate.
    M.Just_a_test_deletion.objects.exists() &&
        M.Just_a_test_deletion.objects.delete(allow_delete_all = true)

    # Result 1: Australian GP → Albert Park Grand Prix Circuit → Australia
    # Result 2: Australian GP → Albert Park Grand Prix Circuit → Australia (same race)
    # Use a circuit-country filter that matches Result 1 but not Result 2.
    # We filter by both country AND driver nationality so exactly one row is hit.
    M.Just_a_test_deletion.objects.create("name" => "australia-british",  "test_result" => 1)
    M.Just_a_test_deletion.objects.create("name" => "australia-german",   "test_result" => 2)

    @test M.Just_a_test_deletion.objects.count() == 2

    # three-level chain: just_a_test_deletion → result → race → circuit (country)
    # combined with driver nationality to uniquely target row 1.
    M.Just_a_test_deletion.objects.filter(
        "test_result__raceid__circuitid__country" => "Australia",
        "test_result__driverid__nationality"      => "British"
    ).delete()

    @test M.Just_a_test_deletion.objects.filter("name" => "australia-british").count() == 0
    @test M.Just_a_test_deletion.objects.filter("name" => "australia-german").count() == 1

    # Cleanup
    M.Just_a_test_deletion.objects.exists() &&
        M.Just_a_test_deletion.objects.delete(allow_delete_all = true)
end

# ─────────────────────────────────────────────────────────────────────────────
# Delete guards: distinct() and group_by()
#
# delete() must reject queries that have distinct() or group_by() set because
# those clauses collapse the result set, making the deletion collector's
# cascade counting and constraint handling unreliable.
# ─────────────────────────────────────────────────────────────────────────────
@testset "DELETE: Guard rejects distinct()" begin
    M.Just_a_test_deletion.objects.exists() &&
        M.Just_a_test_deletion.objects.delete(allow_delete_all = true)

    M.Just_a_test_deletion.objects.create("name" => "distinct-guard", "test_result" => 1)
    M.Just_a_test_deletion.objects.create("name" => "distinct-guard", "test_result" => 2)

    try
        err = try
            M.Just_a_test_deletion.objects.
                filter("name" => "distinct-guard").
                distinct().
                delete()
            nothing
        catch e
            e
        end
        @test err isa PormGError
        @test occursin("distinct", lowercase(sprint(showerror, err)))

        # Rows must survive — the delete was rejected.
        @test M.Just_a_test_deletion.objects.filter("name" => "distinct-guard").count() == 2
    finally
        M.Just_a_test_deletion.objects.exists() &&
            M.Just_a_test_deletion.objects.delete(allow_delete_all = true)
    end
end

@testset "DELETE: Guard rejects group_by()" begin
    M.Just_a_test_deletion.objects.exists() &&
        M.Just_a_test_deletion.objects.delete(allow_delete_all = true)

    M.Just_a_test_deletion.objects.create("name" => "group-guard", "test_result" => 1)
    M.Just_a_test_deletion.objects.create("name" => "group-guard", "test_result" => 2)

    try
        q = M.Just_a_test_deletion.objects.
            filter("name" => "group-guard").
            values("name" => Count("id"))
        err = try
            q.delete()
            nothing
        catch e
            e
        end
        @test err isa PormGError
        @test occursin("group", lowercase(sprint(showerror, err)))

        # Rows must survive — the delete was rejected.
        @test M.Just_a_test_deletion.objects.filter("name" => "group-guard").count() == 2
    finally
        M.Just_a_test_deletion.objects.exists() &&
            M.Just_a_test_deletion.objects.delete(allow_delete_all = true)
    end
end
