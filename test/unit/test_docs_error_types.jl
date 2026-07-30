"""
Documented error types are the public contract (#239) — CI-enforced half.

Every user-facing *"this raises `X`"* claim in `docs/src` that can be triggered at query-build
time is asserted here by running the documented failure and checking the type actually raised.

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
using PormG.Models: Model, CharField, IDField, IntegerField, ForeignKey, JSONField

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
