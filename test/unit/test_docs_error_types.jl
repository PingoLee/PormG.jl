"""
Documented error types are the public contract (#239) — CI-enforced half.

Every user-facing *"this raises `X`"* claim in `docs/src` that can be triggered at query-build
time is asserted here by running the documented failure and checking the type actually raised.

A **docstring** claim counts as `docs/src` for this purpose (#295): since #289, `docs/src/api.md`
renders every `public` docstring onto the API reference, so a sentence written in `src/` is
published to exactly the same page and goes stale exactly the same way. Reference such a case by
its source location, e.g. `"src/Models.jl — Model docstring: …"`.

Why this exists: 26 such claims went stale and shipped in `0.3.0` because the only thing tying a
doc sentence to a throw site was someone remembering. Its sibling
`test/unit/test_docs_error_type_drift.jl` catches a page naming the *retired* `ArgumentError`;
it cannot catch a page naming a plausible-but-wrong `PormGError` subtype. This file can.

Deliberately a **unit** test: `test/integration/` is excluded from CI (see `.github/workflows/CI.yml`
— it needs a live PostgreSQL), so a guard placed there would never run automatically. Mock
`Settings` give a real dialect with no database, the same pattern as `test_complex_queries.jl`.

Claims that genuinely need live data — the unprojected-FK read, `create()` validation, and the
#74 fan-out guard's reverse relation — are asserted in
`test/integration/test_docs_error_types.jl` instead.
"""
# julia --project=. test/unit/test_docs_error_types.jl

using Test
using PormG
using PormG.Models: Model, CharField, IDField, IntegerField, DateTimeField, ForeignKey, JSONField,
                    UniqueConstraint, Index, add_field!
using PormG.QueryBuilder: bulk_insert, bulk_update
import DataFrames

# Mock backends: dialect dispatch is by connection TYPE, so a bare subtype is enough to render
# SQL and to fire the backend-capability guards. No DB, no pool.
struct DocErrMockPostgres <: PormG.PormGPostgres end
struct DocErrMockSQLite <: PormG.PormGSQLite end

PormG.config["docerr_pg"] = PormG.Configuration.Settings(
    connections = DocErrMockPostgres(), change_data = true)
PormG.config["docerr_sl"] = PormG.Configuration.Settings(
    connections = DocErrMockSQLite(), change_data = true)

# One model set per backend. Table/related names are suffixed so the two sets never collide in the
# shared model registry when the whole unit suite runs in one session.
function _docerr_models(key::String)
    status = Model("docerr_status_$key", statusid = IDField(), status = CharField())
    status.connect_key = key; status._module = Main

    driver = Model("docerr_driver_$key",
        driverid = IDField(), surname = CharField(), nationality = CharField())
    driver.connect_key = key; driver._module = Main

    result = Model("docerr_result_$key",
        resultid = IDField(),
        points   = IntegerField(),
        payload  = JSONField(null = true),
        statusid = ForeignKey(status, pk_field = "statusid", null = true),
        driverid = ForeignKey(driver, pk_field = "driverid", null = true,
                              related_name = "results_$key"))
    result.connect_key = key; result._module = Main

    (status, driver, result)
end

const DOCERR_STATUS_PG, DOCERR_DRIVER_PG, DOCERR_RESULT_PG = _docerr_models("docerr_pg")
const DOCERR_STATUS_SL, DOCERR_DRIVER_SL, DOCERR_RESULT_SL = _docerr_models("docerr_sl")

# #331 — a model of its own rather than a `default` bolted onto DOCERR_RESULT_*: a defaulted field
# there would silently change what every other case's model injects on a write.
const DOCERR_STINT_PG = let m = Model("docerr_stint_docerr_pg",
        id = IDField(), driver = CharField(), laps = IntegerField(default = 0))
    m.connect_key = "docerr_pg"; m._module = Main; m
end

# #379 — its own model for the same reason, and one fill kind specifically: an explicit `columns=`
# SUPPRESSES a static `default` on :update, so `auto_now` is the only fill that can still reach
# `_resolve_match_column!` through `match_on=`.
const DOCERR_LAP_PG = let m = Model("docerr_lap_docerr_pg",
        id = IDField(), points = IntegerField(null = true),
        updated_at = DateTimeField(auto_now = true, null = true))
    m.connect_key = "docerr_pg"; m._module = Main; m
end

# (docs claim this test pins, expected type, the call that must raise it).
# Keep the doc reference exact — it is how a maintainer finds the sentence to update when a type
# legitimately changes.
const DOCERR_CASES = [
    (
        "read/subqueries_and_ctes.md — `@in` subquery must project exactly one column",
        FilterError,
        () -> begin
            bad_sub = DOCERR_STATUS_PG.objects.values("statusid", "status")
            DOCERR_RESULT_PG.objects.filter("statusid__@in" => bad_sub).list(show_query = :dict)
        end,
    ),
    (
        "read/subqueries_and_ctes.md — scalar `Subquery(...)` must project exactly one column",
        QueryBuildError,
        () -> begin
            inner = DOCERR_STATUS_PG.objects.values("statusid", "status")
            DOCERR_RESULT_PG.objects.values("resultid", "x" => Subquery(inner)).
                list(show_query = :dict)
        end,
    ),
    (
        "read/values_and_joins.md — alias identifiers reject spaces and punctuation",
        InvalidValueError,
        () -> DOCERR_RESULT_PG.objects.values("bad alias!" => "points").list(show_query = :dict),
    ),
    (
        # #423. Making a values() alias resolve in ORDER BY means a name shared by two projections
        # would emit an ambiguous `ORDER BY "x"` — PostgreSQL rejects it at execution, SQLite picks
        # one. Refused at build time so the backends stay aligned.
        #
        # The doc sentence uses `grid`/`points` (F1); this model has no `grid` and adding one would
        # change what every other case's model injects on a write (#331). Same shape, different
        # column pair — what is pinned is the error TYPE for a duplicated alias, which is what the
        # doc names.
        "read/values_and_joins.md — two projections sharing an alias cannot be ordered by it",
        QueryBuildError,
        () -> DOCERR_RESULT_PG.objects.values("x" => "points", "x" => "resultid").
            order_by("x").list(show_query = :dict),
    ),
    (
        # #424. `cjoin_on`'s `on` is the whole ON clause and is NOT path-prefixed, so a bare
        # `"ev__col" => v` resolves against a `join_field`-less (CROSS-joined) CTE — which has no ON
        # clause to carry it. Two predicates: with only one, the "produced no ON conditions" guard
        # fires first and the case would pin the wrong error.
        "read/custom_joins.md — a cjoin_on ON predicate on a CROSS-joined CTE is refused",
        QueryBuildError,
        () -> begin
            ev = DOCERR_STATUS_PG.objects
            ev.values("statusid", "status")
            q = DOCERR_RESULT_PG.objects
            q.with("ev" => ev)                       # no join_field => CROSS JOIN (#44)
            q.values("resultid")
            q.cjoin_on("DOCERR_DRIVER_PG", alias = "d",
                       on = [F("d.driverid") == F("driverid"), "ev__status" => "Finished"])
            q.list(show_query = :dict)
        end,
    ),
    (
        # #433. A subquery consumed by @in / Subquery / Exists must not declare a CTE: the nested
        # WITH binds into the `:cte` bucket, which flattens ahead of `:select`/`:where`, so on
        # SQLite its values overtake any value whose text comes first. Refused on both backends so
        # the same query does not build on one and misbind on the other.
        "read/subqueries_and_ctes.md — a subquery consumed by @in cannot declare its own .with(...)",
        QueryBuildError,
        () -> begin
            fast = DOCERR_STATUS_PG.objects
            fast.values("statusid", "status")
            inner = DOCERR_RESULT_PG.objects
            inner.with("fast" => fast, join_field = "statusid" => "statusid")
            inner.filter("fast__status" => "Finished")
            inner.values("driverid")
            q = DOCERR_DRIVER_PG.objects
            q.values("driverid")
            q.filter("driverid__@in" => inner)
            q.list(show_query = :dict)
        end,
    ),
    (
        # #433. Only a statement that emits a WITH clause can reference a CTE. Reads do; update()
        # does not, and used to reach an "internal error … please report it" instead of saying so.
        "read/subqueries_and_ctes.md — update() cannot reference a CTE (it emits no WITH clause)",
        QueryBuildError,
        () -> begin
            fast = DOCERR_STATUS_PG.objects
            fast.values("statusid", "status")
            q = DOCERR_RESULT_PG.objects
            q.with("fast" => fast, join_field = "statusid" => "statusid")
            q.filter("fast__status" => "Finished")
            q.update("points" => 0, show_query = :dict)
        end,
    ),
    (
        # #433. delete() re-uses the queryset being deleted as a scoping subquery
        # (`DELETE ... WHERE pk IN (<query>)`), which puts a declared CTE in exactly the nested
        # position that misbinds on SQLite. Refused on the cascade and leaf paths alike.
        # UnsafeMutationError, not QueryBuildError: the same query is legal on a read path, so the
        # discriminator is that it is a mutation — matching delete()'s four other shape guards.
        "read/subqueries_and_ctes.md — delete() refuses a CTE-scoped queryset",
        UnsafeMutationError,
        () -> begin
            ev = DOCERR_STATUS_PG.objects
            ev.values("statusid", "status")
            q = DOCERR_RESULT_PG.objects
            q.with("ev" => ev, join_field = "statusid" => "statusid")
            q.filter("ev__status" => "Finished")
            q.delete(show_query = :dict)
        end,
    ),
    (
        "write/update.md — UPDATE cannot carry LIMIT/OFFSET/ORDER BY",
        UnsafeMutationError,
        () -> DOCERR_RESULT_PG.objects.filter("resultid" => 1).limit(5).
            update("points" => 0, show_query = :dict),
    ),
    # #331 — `write/bulk.md` → Defaults and Auto Values promises that a blank cell in a PRESENT,
    # `null=false` column raises "null values are not allowed" as *PormG's own validation, not a
    # database constraint error*, and that it is the same error `create()` raises. Build-time:
    # bulk_insert runs its per-row validation sweep even under show_query, so the mock is enough —
    # which is also what makes the "not a database error" half of the claim demonstrable here.
    (
        "write/bulk.md — a blank cell in a present NOT NULL defaulted column is a null, not the default",
        InvalidValueError,
        () -> bulk_insert(DOCERR_STINT_PG.objects,
                          DataFrames.DataFrame(driver = ["Senna"], laps = [missing]),
                          show_query = :dict),
    ),
    # A control, not a regression: create() already behaved this way, and #331 aligned the bulk
    # paths onto it. It is here so the two halves of the documented equivalence are pinned
    # together — if create() ever drifts, the claim in write/bulk.md becomes false too.
    (
        "write/create.md — an explicit `nothing` on a NOT NULL defaulted field is a null, not the default",
        InvalidValueError,
        () -> DOCERR_STINT_PG.objects.create("driver" => "Senna", "laps" => nothing,
                                             show_query = :dict),
    ),
    (
        "read/filters_and_aggregates.md — a JSON path key with spaces is not addressable",
        InvalidValueError,
        () -> DOCERR_RESULT_PG.objects.filter("payload__bad key" => 1).list(show_query = :dict),
    ),
    # Intentional PG/SQLite divergence: these pages tell the reader the lookup is PostgreSQL-only
    # and raises on SQLite. Asserting it on the SQLite mock keeps the documented divergence honest.
    (
        "read/filters_and_aggregates.md — iunaccent_* lookups require PostgreSQL",
        BackendCapabilityError,
        () -> DOCERR_DRIVER_SL.objects.filter("surname__@iunaccent_contains" => "sena").
            list(show_query = :dict),
    ),
    (
        "read/filters_and_aggregates.md — JSONB key-existence operators require PostgreSQL",
        BackendCapabilityError,
        () -> DOCERR_RESULT_SL.objects.filter("payload__@has_key" => "wins").
            list(show_query = :dict),
    ),
    # #213 — the delete guards. `write/delete.md` and `errors.md` both promise UnsafeMutationError
    # for each of these query shapes; every one is refused before SQL is generated, so a mock
    # connection is enough. The four are separate cases on purpose: they are four independent
    # checks in `deletion.jl`, and collapsing them would let three regress unnoticed.
    (
        "write/delete.md — delete() rejects limit()",
        UnsafeMutationError,
        () -> DOCERR_RESULT_PG.objects.filter("points" => 0).limit(10).delete(show_query = :dict),
    ),
    (
        "write/delete.md — delete() rejects offset()",
        UnsafeMutationError,
        () -> DOCERR_RESULT_PG.objects.filter("points" => 0).offset(5).delete(show_query = :dict),
    ),
    (
        "write/delete.md — delete() rejects order_by()",
        UnsafeMutationError,
        () -> DOCERR_RESULT_PG.objects.filter("points" => 0).order_by("-points").
            delete(show_query = :dict),
    ),
    (
        "write/delete.md — delete() rejects distinct()",
        UnsafeMutationError,
        () -> DOCERR_RESULT_PG.objects.filter("points" => 0).distinct().
            delete(show_query = :dict),
    ),
    (
        "write/delete.md — a filterless delete() needs allow_delete_all = true",
        UnsafeMutationError,
        () -> DOCERR_RESULT_PG.objects.delete(show_query = :dict),
    ),
    (
        "read/index.md — `.page(...)` takes one or two Integers; anything else raises",
        QueryBuildError,
        () -> DOCERR_RESULT_PG.objects.page("20", "10"),
    ),
    # ── Definition-time claims from the Models docstrings (#295) ──────────────
    # These are not query-build failures, but they are published on the same api.md page and rot
    # the same way. The first is the load-bearing one: the `Model` docstring tells users PormG has
    # no Django `Meta` block, and the whole reason that sentence is safe to write is that a
    # model-level option is indistinguishable from a field declaration. If a future PR ever peels
    # a second name off the `fields...` slurp, this case stops throwing and says so.
    (
        "src/Models.jl — Model docstring: no Django `Meta` block, so `ordering =` reads as a field",
        ModelDefinitionError,
        () -> Model("docerr_meta_probe", ordering = ["-year"], raceid = IDField()),
    ),
    (
        "src/Models.jl — UniqueConstraint docstring: no fields is rejected in the constructor",
        ModelDefinitionError,
        () -> UniqueConstraint(fields = ()),
    ),
    # models.md and the Index docstring both promise this REJECTION in a warning admonition, and it
    # is the promise that keeps composite indexes from churning: a one-column CREATE INDEX reads
    # back as `db_index`, so accepting a one-field Index would make makemigrations propose dropping
    # its own index forever (#347).
    (
        "models.md + src/Models.jl — Index docstring: a single-column Index is rejected (#347)",
        ModelDefinitionError,
        () -> Index(fields = ("lap",)),
    ),
    # The other half of the same #347 warning: `indexes` is a model-level option, so a COLUMN of
    # that name is unreachable and must say so rather than raising a bare MethodError.
    (
        "models.md + src/Models.jl — Model docstring: a field named `indexes` is refused (#347)",
        ModelDefinitionError,
        () -> Model("docerr_indexes_probe", raceid = IDField(), indexes = CharField(max_length = 10)),
    ),
    (
        "schema_conventions.md + src/Models.jl — Model docstring: a positional name must be lowercase (#300)",
        ModelDefinitionError,
        () -> Model("Driver_Profile", driverid = IDField()),
    ),
    (
        "schema_conventions.md + src/Models.jl — Model docstring: a positional name may not start with '_' (#306)",
        ModelDefinitionError,
        () -> Model("_docerr_underscore_probe", driverid = IDField()),
    ),
    (
        "fields.md + src/Models.jl — Model docstring: a declared FIELD name may not start with '_'; use db_column (#317)",
        ModelDefinitionError,
        () -> Model("docerr_field_underscore_probe", _id = IDField()),
    ),
    (
        "src/Models.jl — add_field! docstring: a leading-underscore field name raises (#317)",
        ModelDefinitionError,
        () -> add_field!(Model("docerr_addfield_probe", id = IDField()), :_end, CharField()),
    ),
    # #379 — `write/bulk.md` → Matching and Execution Rules ("Missing column errors") and
    # `api.md` both promise that a `match_on` field PormG *would* auto-populate, but that the
    # caller supplied no source column for, raises rather than binding the auto-populated value.
    # The frame deliberately has NO `updated_at` column: with one, the caller's column wins and
    # there is nothing to raise about — which is the other half of the same documented rule and
    # is pinned by value in test_bulk_update_column_scope.jl.
    (
        "write/bulk.md + api.md — an auto-populated match_on field with no caller source raises (#379)",
        UnknownFieldError,
        () -> bulk_update(DOCERR_LAP_PG.objects,
                          DataFrames.DataFrame(new_points = [9]),
                          columns = ["new_points" => "points"],
                          match_on = ["updated_at"], show_query = :dict),
    ),
    (
        "write/bulk.md — conflicting columns= target mappings raise QueryBuildError (#380)",
        QueryBuildError,
        () -> begin
            df = DataFrames.DataFrame(c1 = ["active"], c2 = ["disabled"])
            bulk_insert(DOCERR_STATUS_PG.objects, df,
                columns = ["c1" => "status", "c2" => "status"], show_query = :dict)
        end,
    ),
    (
        # The page's claim is about `makemigrations`, which needs a database. This pins it one layer
        # down, at a DDL renderer that reaches the same throw with no connection.
        #
        # SQLite specifically, and that is not arbitrary: `create_table(::PormGPostgres, …)` renders
        # columns only and never calls `fk_target_table`, so the PG arm of this call would assert
        # nothing. PG reaches the throw through the planner's `add_foreign_key` paths instead, which
        # `test_fk_unresolved_target.jl` covers. The throw itself lives in `fk_target_table` and is
        # engine-agnostic, so one engine is enough to pin the TYPE — which is all this table claims.
        "schema_conventions.md — a foreign key whose target is not in the models module raises (#388)",
        ModelDefinitionError,
        () -> PormG.Dialect.create_table(DocErrMockSQLite(),
            Model("docerr_orphan_child_probe",
                id       = IDField(),
                parentid = ForeignKey("Docerr_Never_Declared", pk_field = "id"))),
    ),
]

# ─────────────────────────────────────────────────────────────────────────────
# Documented error types: every build-time claim raises the type its page names
# Runs each documented failure and asserts the raised type. The `!isa ArgumentError` assertion is
# independent rather than redundant: it pins the #231/#239 clean break that both `api.md` and
# `UPGRADING.md` promise, and would fail if a subtype were reparented under `ArgumentError` to
# soften the break.
# ─────────────────────────────────────────────────────────────────────────────
@testset "Documented error types (build-time)" begin
    for (doc_ref, expected, call) in DOCERR_CASES
        @testset "$doc_ref" begin
            err = try
                call()
                nothing
            catch e
                e
            end
            # A doc that promises an error for something which now succeeds is drift too, and
            # would otherwise pass silently — so assert the failure happens before its type.
            @test err !== nothing
            @test err isa expected
            @test err isa PormGError
            @test !(err isa ArgumentError)
        end
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# Quoted error TEXT stays accurate (#295)
# The table above pins types, not wording — deliberately, since messages are free to be reworded.
# But a docstring that QUOTES a message is making a second, finer claim, and a reword would leave
# the quote stale with every type assertion still green. `Model`'s "no Django `Meta` block" note
# shows the message verbatim, because it is the string a user lands on and searches for. Pin the
# part that is quoted, not the whole sentence, so the surrounding wording stays free to change.
# ─────────────────────────────────────────────────────────────────────────────
@testset "Quoted error text in docstrings (#295)" begin
    err = try
        Model("docerr_text_probe", ordering = ["-year"], raceid = IDField())
        nothing
    catch e
        e
    end
    # Same guard order as the harness above: a claim whose failure stopped happening is drift too,
    # and without this `error_message(nothing)` would report a MethodError instead of the reason.
    @test err !== nothing
    @test err isa ModelDefinitionError
    @test occursin("All fields must be of type PormGField", error_message(err))
end
