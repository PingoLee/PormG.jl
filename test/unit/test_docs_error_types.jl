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
using PormG.Models: Model, CharField, IDField, IntegerField, ForeignKey, JSONField, UniqueConstraint,
                    add_field!

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
        "write/update.md — UPDATE cannot carry LIMIT/OFFSET/ORDER BY",
        UnsafeMutationError,
        () -> DOCERR_RESULT_PG.objects.filter("resultid" => 1).limit(5).
            update("points" => 0, show_query = :dict),
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
