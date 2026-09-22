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
# julia --project=test/integration test/unit/test_docs_error_types.jl

using Test
using PormG
using PormG.Models: Model, CharField, IDField, IntegerField, DateField, DateTimeField, ForeignKey,
                    JSONField, UniqueConstraint, Index, add_field!
# #612 — the text fields whose `default=` policy the filters page states, plus `UUIDField`,
# which the page deliberately holds to a STRICTER rule than that shared policy.
using PormG.Models: TextField, URLField, UUIDField
# #614 — the numeric half of the same page bullet.
using PormG.Models: FloatField
# #632 — the same bullet's `Decimal` rule, which needs the type to state its refusing half.
import Decimals
using PormG.QueryBuilder: bulk_insert, bulk_update
# #509 — the ordering wrapper and the window constructor, for the two window-page claims below.
using PormG.QueryBuilder: SQLOrder
using PormG.Functions: WindowOver, Rank
# #535 — a scalar function wrapping an `OuterRef`, for the subqueries-page claim below.
using PormG.Functions: Lower
# #194 — an outer aggregate, for the grouped-correlation claim below. `Count` is deliberately not a
# top-level PormG export (it would collide with Base/user code), so it is named here explicitly.
using PormG.Functions: Count
# #569 — a text format outside the portable table, for the ToChar docstring claim below.
using PormG.Functions: ToChar
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

# #576 — the period-transform claims on read/functions_and_dates.md and read/filters_and_aggregates.md
# name an error TYPE, and both named the wrong one: the transform ladder formatted outside the
# filter path's re-raise, so it reported the write path's `InvalidValueError`. Its own model because
# no other fixture here carries a `DateField`, and a period transform needs one.
const DOCERR_RACE_PG = let m = Model("docerr_race_docerr_pg",
        raceid = IDField(), name = CharField(), date = DateField())
    m.connect_key = "docerr_pg"; m._module = Main; m
end

# #459 — the cascade depth ceiling. Unlike every other fixture in this file, this one needs a real
# `set_models` registration: the guard fires inside `find_related_objects!`, which walks
# `model.related_objects`, and that map is populated by reverse-accessor registration. Hand-built
# `Model(...)` values with `connect_key` assigned — the pattern above — have none, so a cascade
# cannot traverse them at all.
#
# A two-model cycle rather than a 51-link chain: it reaches the ceiling by the shortest route, and a
# cycle is the shape the error message names first.
#
# It also needs a config key of its own, carrying `db_def_folder`. `set_models(mod, key)` resolves
# `key` through the registered settings and falls back to READING A connection.yml FROM DISK when no
# entry matches; the two mock settings above omit `db_def_folder`, so passing "docerr_pg" here sends
# it looking for a file that does not exist and raises MissingConfigurationError.
PormG.config["docerr_cycle"] = PormG.Configuration.Settings(
    connections = DocErrMockPostgres(), change_data = true, db_def_folder = "docerr_cycle")

# The forward reference is by NAME because Julia cannot mention `Docerr_cycle_b` before it exists.
# `module` must be top level — Julia rejects it inside `@testset`, `if` or `for`.
module DocErrCycleModels
import PormG
import PormG.Models

Docerr_cycle_a = Models.Model("docerr_cycle_a",
    id   = Models.IDField(),
    code = Models.CharField(),
    b    = Models.ForeignKey("Docerr_cycle_b", on_delete = "CASCADE",
               related_name = "docerr_cycle_as", null = true),
)

Docerr_cycle_b = Models.Model("docerr_cycle_b",
    id = Models.IDField(),
    a  = Models.ForeignKey(Docerr_cycle_a, on_delete = "CASCADE",
             related_name = "docerr_cycle_bs", null = true),
)

PormG.Models.set_models(@__MODULE__, "docerr_cycle")
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
        # #441 moved this refusal upstream. It was #423's ORDER BY ambiguity guard — a name shared by
        # two projections emitted an ambiguous `ORDER BY "x"` that PostgreSQL rejects and SQLite
        # resolves arbitrarily. `values()` now refuses the DECLARATION, so `order_by` can never see a
        # shared alias and that guard is retired as unreachable. Same type, earlier site; the
        # `order_by` call is kept in the shape so this still covers the doc sentence's full example.
        #
        # The doc sentence uses `grid`/`points` (F1); this model has no `grid` and adding one would
        # change what every other case's model injects on a write (#331). Same shape, different
        # column pair — what is pinned is the error TYPE for a duplicated output name.
        "read/values_and_joins.md — two projections may not share an output name",
        QueryBuildError,
        () -> DOCERR_RESULT_PG.objects.values("x" => "points", "x" => "resultid").
            order_by("x").list(show_query = :dict),
    ),
    (
        # #441. The star is compared as the PHYSICAL columns the database expands it to, which the
        # doc states explicitly. `statusid` is a real column of this model, so `values("*", …)` under
        # that name collides with the star's own contribution.
        "read/values_and_joins.md — a values() name colliding with a star-expanded column",
        QueryBuildError,
        () -> DOCERR_RESULT_PG.objects.values("*", "statusid" => "points").list(show_query = :dict),
    ),
    (
        # #444. A CTE column reference cannot appear in a JOIN's ON clause at all — `cjoin_on`'s
        # `on` is the whole ON clause, and a CTE is joined by its own `.with()` declaration, not by
        # someone else's join. Refused at the call, before any SQL is planned. FilterError rather
        # than QueryBuildError because this is about what a FILTER element may reference.
        "read/custom_joins.md — a CTE(...) reference inside a join ON clause is refused",
        FilterError,
        () -> begin
            ev = DOCERR_STATUS_PG.objects
            ev.values("statusid", "status")
            q = DOCERR_RESULT_PG.objects
            q.with("ev" => ev)
            q.values("resultid")
            q.cjoin_on("DOCERR_DRIVER_PG", alias = "d", on = [CTE("ev", "status") => "Finished"])
            q.list(show_query = :dict)
        end,
    ),
    (
        # #492 restored the `"<cte>__<column>"` string, which re-opens the route the entry above
        # closes, so the same admonition now claims the refusal for BOTH spellings and both are
        # pinned. The check runs at build time rather than at the `.cjoin_on()` call: the CTE
        # registry is complete only then, and a call-time check was order-dependent — `.with()`
        # before `.on()` refused while the reverse sailed past, which was #434.
        "read/custom_joins.md — a CTE-rooted string inside a join ON clause is refused",
        FilterError,
        () -> begin
            ev = DOCERR_STATUS_PG.objects
            ev.values("statusid", "status")
            q = DOCERR_RESULT_PG.objects
            q.with("ev" => ev)
            q.values("resultid")
            q.cjoin_on("DOCERR_DRIVER_PG", alias = "d", on = ["ev__status" => "Finished"])
            q.list(show_query = :dict)
        end,
    ),
    (
        # #492. The docs warn that a CTE-rooted string on the RIGHT of a filter pair is a VALUE and
        # not a column. On a TEXT column that is silent (it matches the literal, i.e. nothing), which
        # is exactly why the sentence exists; on a NUMERIC one the field's type check catches it, and
        # that is the half with an error type to pin. Measured against the F1 data before it was
        # written: `filter("raceid" => "r91__raceid")` raises, `filter("surname" => "d91__surname")`
        # returns zero rows.
        "read/subqueries_and_ctes.md — a CTE-rooted string on a filter's right is a value, not a column",
        FilterError,
        () -> begin
            ev = DOCERR_STATUS_PG.objects
            ev.values("statusid", "status")
            q = DOCERR_RESULT_PG.objects
            q.with("ev" => ev)
            q.values("resultid")
            q.filter("statusid" => "ev__statusid")   # an integer field, so the value is type-checked
            q.list(show_query = :dict)
        end,
    ),
    (
        # #492. With the string spelling back as the default, a CTE named after a model field gives
        # the shared `__` path two readings, and PormG refuses instead of choosing — choosing is the
        # #431 defect, whose symptom was wrong rows and no error. `driverid` is a ForeignKey of the
        # result model, so `"driverid__surname"` could mean the FK hop or the CTE's column.
        #
        # Its own type rather than UnknownFieldError, and the doc says so: the name is known TWICE,
        # not unknown, and an app's typo handler should not also fire when a schema change makes an
        # existing CTE name collide.
        "read/subqueries_and_ctes.md — a CTE name colliding with a model field makes the path ambiguous",
        AmbiguousFieldError,
        () -> begin
            totals = DOCERR_DRIVER_PG.objects.values("driverid", "surname")
            q = DOCERR_RESULT_PG.objects
            q.with("driverid" => totals)
            q.values("resultid", "driverid__surname")
            q.list(show_query = :dict)
        end,
    ),
    (
        # #509. The window-function page states that the same ambiguity applies to an `SQLOrder`
        # entry inside a window's `order_by` — "exactly as it applies to values(), filter() and
        # order_by()". That sentence is the whole point of the fix: this was the one clause where a
        # shadowing CTE name RESOLVED to the model side and rendered, silently, while every other
        # clause already refused it. A page claiming parity that the code does not provide would be
        # worse than no page, so the claim is executed rather than trusted.
        "read/window_functions.md — a shadowing CTE name in an SQLOrder window entry is ambiguous",
        AmbiguousFieldError,
        () -> begin
            totals = DOCERR_DRIVER_PG.objects.values("driverid", "surname")
            q = DOCERR_RESULT_PG.objects
            q.with("driverid" => totals)
            q.values("resultid",
                     "rk" => Rank(over = WindowOver(
                         order_by = [SQLOrder("driverid__surname")])))
            q.list(show_query = :dict)
        end,
    ),
    (
        # #509. The same page's note that `desc = true` cannot be combined with an `SQLOrder`, which
        # carries the direction in its own `orientation`. Refused at CONSTRUCTION — no query is
        # needed — because two spellings for one direction is a tie-break the caller would never see
        # resolved.
        "read/window_functions.md — desc = true inside an SQLOrder is refused",
        QueryBuildError,
        () -> SQLOrder(CTE("season", "season_points"; desc = true)),
    ),
    (
        # #481. A `Joined(...)` handle names a `cjoin_on` joined copy, so it cannot appear in
        # `on(...)` / `cjoin(...)` — those add predicates to a join derived from a relation, and
        # every reference in them targets that joined model. The mirror of #444's CTE refusal above,
        # and documented in the same admonition.
        "read/custom_joins.md — a Joined(...) reference inside on()/cjoin() is refused",
        FilterError,
        () -> begin
            q = DOCERR_RESULT_PG.objects
            q.on("driverid", Joined("d", "surname") == F("resultid"))
            q.values("resultid")
            q.list(show_query = :dict)
        end,
    ),
    (
        # #479. A CTE named after a physical table is refused at the `.with()` call: SQL resolves an
        # unqualified table reference to a same-named CTE for the whole statement, so every join
        # PormG generates to that table would silently read the CTE. The CTE body here is the driver
        # model itself, so the name is caught against the body's base model as well as the module walk.
        "read/subqueries_and_ctes.md — a CTE named after a physical table is refused",
        QueryBuildError,
        () -> begin
            best = DOCERR_DRIVER_PG.objects.values("driverid", "surname")
            DOCERR_RESULT_PG.objects.with("docerr_driver_docerr_pg" => best,
                                          join_field = "driverid" => "driverid")
        end,
    ),
    (
        # #435. Resolving `driverid__surname` builds the driver join DURING Phase 1, so it lands at
        # a higher `row_join` index than `d` — a forward reference. Phase 1b moves the predicate
        # onto it, and since it is `d`'s only one, `d` is left with no ON clause. The doc note tells
        # the reader this raises and names the alias the predicates went to.
        "read/custom_joins.md — a cjoin_on whose predicates all relocate away is refused",
        QueryBuildError,
        () -> begin
            q = DOCERR_RESULT_PG.objects
            q.values("resultid")
            q.cjoin_on("DOCERR_STATUS_PG", alias = "d", on = ["driverid__surname" => "Senna"])
            q.list(show_query = :dict)
        end,
    ),
    (
        # #448. The neighbour of the case above, and the one that used to RENDER. `points` is a
        # column of the base model, so this predicate resolves against the base alias and stays put
        # — nothing relocates, so #435 cannot fire and `extras` is not empty. Before #448 that was
        # enough: the join emitted with an ON clause naming everything except itself, pairing every
        # `docerr_status` row with every matched base row. The docs use this exact `points__@gt`
        # shape, so the case is the doc sentence made executable.
        "read/custom_joins.md — a cjoin_on ON clause that never names its own alias is refused",
        QueryBuildError,
        () -> begin
            q = DOCERR_RESULT_PG.objects
            q.values("resultid")
            q.cjoin_on("DOCERR_STATUS_PG", alias = "d", on = ["points__@gt" => 10])
            q.list(show_query = :dict)
        end,
    ),
    # #474 removed TWO cases that stood here, and the removals are the point rather than a
    # tidy-up. Both pinned doc sentences about a CTE name colliding with a join key:
    #
    #   - "an ON predicate on a CROSS-joined CTE is refused" (#424) — its producer was the ALIAS
    #     collision, `.with("d" => …)` unkeyed against a `cjoin_on` also aliased `"d"`.
    #   - "a join key colliding with a keyed CTE name is refused" (#447) — the same shape, keyed.
    #
    # #474 made both RENDER: the CTE hop no longer reads the base model's join-config registry
    # under its own name, so the two are simply two relations sharing a name and both are emitted.
    # Their coexistence is pinned in `test/unit/test_relation_alias_namespace.jl`, and the doc
    # sentences they mirrored are gone from `read/custom_joins.md` and `read/subqueries_and_ctes.md`.
    #
    # #424's `throw` still stands in `build_query.jl` as a fail-closed backstop for the relocation
    # route, but nine shapes were built against it after the change and none reached it — so there
    # is no producer to pin here. Re-add a case the moment one exists.
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
            inner.filter(CTE("fast", "status") => "Finished")
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
            q.filter(CTE("fast", "status") => "Finished")
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
            q.filter(CTE("ev", "status") => "Finished")
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
    # #576. Both pages state the type for a period transform's rejected value, and both said
    # `InvalidValueError` — the write path's type, on a read. Neither claim was executed here
    # before, which is why it survived #411 and #467 untouched: the transform ladder is a different
    # branch from the scalar and `BETWEEN` arms those issues converted.
    (
        "read/filters_and_aggregates.md — a period number outside its range",
        FilterError,
        () -> DOCERR_RACE_PG.objects.filter("date__@quarter" => 9).list(show_query = :dict),
    ),
    (
        "read/functions_and_dates.md — a period transform compared against a non-number",
        FilterError,
        () -> DOCERR_RACE_PG.objects.filter("date__@quarter" => "abc").list(show_query = :dict),
    ),
    # #654 — the *Which Lookups Work on an Aggregate Alias* section says `@isnull` on a `Count` alias
    # raises when the query is built: COUNT never returns NULL, so the lookup could never match. (The
    # three #618 entries that stood here — `@range` / `@nrange` / `@isnull` being WHERE-only — went
    # with the claim when #654 supported them.) Type claim only, per this harness's design; the
    # message is pinned in `test/unit/test_alignment_sqlite.jl`'s #654 testset.
    (
        "read/filters_and_aggregates.md — @isnull on a Count alias can never match",
        FilterError,
        () -> DOCERR_RACE_PG.objects.values("n" => Count("raceid")).
            filter("n__@isnull" => true).list(show_query = :dict),
    ),
    # The JSONB lookups are still `WHERE`-only on an alias, and the same section says so.
    (
        "read/filters_and_aggregates.md — a JSONB lookup on a projection alias is WHERE-only",
        FilterError,
        () -> DOCERR_RACE_PG.objects.values("n" => Count("raceid")).
            filter("n__@has_key" => "a").list(show_query = :dict),
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
    # #569 — the same claim in four places: the `ToChar` docstring, `read/functions_and_dates.md`,
    # and the `BackendCapabilityError` rows of `api.md` and `errors.md`. A format outside the
    # portable table is passed through on PostgreSQL and refused on SQLite with the supported list.
    (
        "ToChar docstring + read/functions_and_dates.md + errors.md — an unmapped ToChar format raises on SQLite",
        BackendCapabilityError,
        () -> DOCERR_RESULT_SL.objects.values("x" => ToChar("resultid", "HH12:MI AM")).
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
    # #459 — one entry, two documents. `write/delete.md`'s "A cascade descends at most 50 levels"
    # warning and the `delete` docstring's "Beyond that it raises `QueryBuildError`" name the SAME
    # throw site, so unlike the five guards above — which are five independent checks — splitting
    # this in two would only run one closure twice. Both references are in the label so either
    # sentence is findable from here.
    (
        "write/delete.md + src/querybuilder/deletion.jl delete docstring — " *
            "a cascade past 50 levels raises",
        QueryBuildError,
        () -> DocErrCycleModels.Docerr_cycle_a.objects.filter("code" => "DELME").
            delete(show_query = :dict),
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
    # #496. Two claims the *Column defaults* section makes about `db_default`, and both are
    # triggerable with no database, which is why they belong in this file rather than its
    # integration twin. The second is the one that matters most: the whole promise of the pinned
    # form is that a models file can never emit DDL the target engine would reject, and a page
    # saying so is worthless if the type it names has drifted.
    (
        "schema_conventions.md — `default` and `db_default` together raise (#496)",
        FieldValidationError,
        () -> IntegerField(default = 5, db_default = "CURRENT_DATE"),
    ),
    (
        "schema_conventions.md — a non-portable bare-String db_default raises (#496)",
        FieldValidationError,
        () -> DateTimeField(db_default = "now()"),
    ),
    (
        "schema_conventions.md — rendering an engine-pinned db_default on the other engine raises (#496)",
        BackendCapabilityError,
        () -> PormG.Dialect.field_to_column("uid", UUIDField(db_default = (postgres = "gen_random_uuid()",)),
                                            DocErrMockSQLite()),
    ),
    # #446. `errors.md` has promised `UnknownFieldError` for "the field name does not exist on the
    # model" since the taxonomy landed, and until now the code raised a bare `KeyError` for every one
    # of these shapes — an untyped error naming an internal dict lookup, for the single most common
    # mistake a user makes against this API. The claim was never pinned here, which is exactly how it
    # drifted. All five shapes, because they reach four different raw dict accesses.
    (
        "errors.md — an unknown PLAIN field name in filter()",
        UnknownFieldError,
        () -> DOCERR_RESULT_PG.objects.filter("nope" => 1).list(show_query = :dict),
    ),
    (
        "errors.md — an unknown field on a JOINED model in filter()",
        UnknownFieldError,
        () -> DOCERR_RESULT_PG.objects.filter("driverid__nope" => 1).list(show_query = :dict),
    ),
    (
        "errors.md — an unknown joined field carrying an operator suffix",
        UnknownFieldError,
        () -> DOCERR_RESULT_PG.objects.filter("driverid__nope__@lt" => 1).list(show_query = :dict),
    ),
    (
        "errors.md — an unknown field in values()",
        UnknownFieldError,
        () -> DOCERR_RESULT_PG.objects.values("driverid__nope").list(show_query = :dict),
    ),
    # #462. The same claim on the WRITE path, which #446 left out of its scope deliberately: the
    # five shapes above are `filter`/`values`/`order_by`, while `create()`/`update()` reported the
    # identical mistake as `InvalidValueError` — a type whose own docstring scopes it to a bad
    # *value*. `api.md`'s `UnknownFieldError` row carves out no exception for writes, and
    # `get_or_create`/`update_or_create` already raised it, so the write path disagreed with itself.
    #
    # `points` is supplied in the create case on purpose: `_prepare_row_insert!` refuses a missing
    # NOT NULL field BEFORE it validates the field names, so omitting it would pin that unrelated
    # (and correctly typed) `InvalidValueError` instead of the one this case is about.
    (
        "errors.md + write/create.md — an unknown field name in create()",
        UnknownFieldError,
        () -> DOCERR_RESULT_PG.objects.create("points" => 1, "nope" => 2, show_query = :dict),
    ),
    (
        # Filtered, because an unfiltered `update()` is refused as unsafe before it ever looks at
        # the field names — that guard is pinned separately.
        "errors.md — an unknown field name in update()",
        UnknownFieldError,
        () -> DOCERR_RESULT_PG.objects.filter("resultid" => 1).
            update("nope" => 2, show_query = :dict),
    ),
    (
        "errors.md — an unknown field in order_by()",
        UnknownFieldError,
        () -> begin
            q = DOCERR_RESULT_PG.objects
            q.values("resultid")
            q.order_by("driverid__nope")
            q.list(show_query = :dict)
        end,
    ),
    (
        # #420. The page states BOTH halves of this rule; only the explicit one is a plain
        # constructor call and therefore pinnable here. The derived half — where the accessor
        # inherits `__` from a legacy column name and `set_models` raises `ModelDefinitionError` —
        # needs a registered model module, so it is pinned in
        # `test_reverse_accessor_namespace.jl` -> "a derived accessor containing __ is refused …".
        "read/values_and_joins.md — a related_name containing `__` is refused (#420)",
        FieldValidationError,
        () -> ForeignKey("Docerr_Driver", pk_field = "id", related_name = "incident__driver"),
    ),
    (
        # #536. The page states that a comparison literal outside the accepted vocabulary is refused
        # AT THE OPERATOR — before any query is built — and never evaluates to a bare `Bool`. A plain
        # constructor-level call, so no model or connection is involved.
        "read/field_expressions.md — an unsupported comparison literal is refused (#536)",
        QueryBuildError,
        () -> F("points") == 1 // 2,
    ),
    (
        # #535. The subqueries page states that an `OuterRef` outside a correlated build raises
        # `QueryBuildError` "wrapped or not" — the WRAPPED half is the one this pins, because before
        # #535 it was a raw `MethodError` at `values()` time while the bare half was already typed.
        "read/subqueries_and_ctes.md — a function-wrapped OuterRef outside a correlated build is refused (#535)",
        QueryBuildError,
        () -> begin
            q = DOCERR_DRIVER_PG.objects
            q.values("l" => Lower(OuterRef("surname")))
            q.list(show_query = :dict)
        end,
    ),
    (
        # #194. The subqueries page promises a build-time refusal when a projected correlated
        # Subquery/Exists references an outer column the query does not GROUP BY — the shape that
        # PostgreSQL rejects outright and SQLite answers from an arbitrary row of each group.
        "read/subqueries_and_ctes.md — a correlated Subquery on an ungrouped outer column is refused (#194)",
        QueryBuildError,
        () -> begin
            inner = DOCERR_RESULT_PG.objects
            inner.filter("driverid" => OuterRef("driverid"))
            inner.values("t" => Count("resultid"))
            q = DOCERR_DRIVER_PG.objects
            # Groups by nationality; the subquery correlates on the ungrouped driverid.
            q.values("nationality", "n" => Count("driverid"), "s" => Subquery(inner))
            q.list(show_query = :dict)
        end,
    ),
    # #566. The page states that a subquery cannot see a CTE its enclosing query declares (#444:
    # one CTE namespace per query), and names both spellings — so both are pinned. The page used to
    # call this "not blocked, but not validated"; every spelling was already refused.
    (
        "read/subqueries_and_ctes.md — a subquery cannot reference its enclosing query's CTE (handle) (#566)",
        UnknownFieldError,
        () -> begin
            ev = DOCERR_STATUS_PG.objects
            ev.values("statusid", "status")
            q = DOCERR_RESULT_PG.objects
            q.with("ev" => ev, join_field = "statusid" => "statusid")
            inner = DOCERR_RESULT_PG.objects
            inner.filter(CTE("ev", "status") => "Finished")
            inner.filter("resultid" => OuterRef("resultid"))
            q.filter(Exists(inner))
            q.values("resultid")
            q.list(show_query = :dict)
        end,
    ),
    (
        "read/subqueries_and_ctes.md — a subquery cannot reference its enclosing query's CTE (string) (#566)",
        UnknownFieldError,
        () -> begin
            ev = DOCERR_STATUS_PG.objects
            ev.values("statusid", "status")
            q = DOCERR_RESULT_PG.objects
            q.with("ev" => ev, join_field = "statusid" => "statusid")
            inner = DOCERR_RESULT_PG.objects
            inner.filter("ev__status" => "Finished")
            inner.filter("resultid" => OuterRef("resultid"))
            q.filter(Exists(inner))
            q.values("resultid")
            q.list(show_query = :dict)
        end,
    ),
    (
        # #488. A `cjoin_on` target given as a model OBJECT may come from anywhere, so a model
        # registered on a different connection from the one the query runs on is refused when the
        # query is BUILT: the join would name a table that lives in another database. Build time,
        # not call time, because a `.db("key")` override may follow the `cjoin_on` call. The name
        # form cannot reach this — it resolves inside the query's own module.
        "read/custom_joins.md — a cjoin_on target registered on another connection is refused (#488)",
        QueryBuildError,
        () -> begin
            q = DOCERR_RESULT_PG.objects
            q.cjoin_on(DOCERR_DRIVER_SL, alias = "d", on = [Joined("d", "driverid") == F("driverid")])
            q.values("resultid")
            q.list(show_query = :dict)
        end,
    ),
    (
        # #612. The page states the `default=` policy — any AbstractString, or an Integer as its
        # decimal text — and then names what happens to everything else. That last clause is the
        # claim pinned here, and it is worth pinning because the refusal is NEW for `URLField` and
        # `SlugField`: their old `string(x)` converter stringified a Symbol silently, so a reader of
        # the old page could reasonably have believed the opposite.
        "read/filters_and_aggregates.md — a Symbol `default=` is refused (#612)",
        FieldValidationError,
        () -> URLField(default = :not_a_string),
    ),
    (
        # #612, the other half of the same sentence. For the four fields whose dead
        # `parse(String, x)` converter refused every non-`String` spelling, the page's claim is now
        # about which values are refused rather than that anything is — a `Float64` is the nearest
        # miss to the `Integer` the policy does accept.
        "read/filters_and_aggregates.md — a Float64 `default=` on a text field is refused (#612)",
        FieldValidationError,
        () -> TextField(default = 3.5),
    ),
    (
        # #612 review. The bullet originally lumped UUIDField and JSONField in with the seven
        # plain-text fields, which was false in BOTH directions — `JSONField(default = 3.5)` stores
        # "3.5" where the bullet promised a refusal, and `UUIDField(default = 5)` refuses where it
        # promised acceptance. The two cases above could not catch it because neither touches these
        # fields. This one pins the stricter rule the page now states for them: the value must BE a
        # valid UUID, so a string that is merely a string is not enough.
        "read/filters_and_aggregates.md — UUIDField requires a valid UUID, not just a string (#612)",
        FieldValidationError,
        () -> UUIDField(default = "abc"),
    ),
    (
        # #614. The numeric paragraph the page gained states that `Bool` is refused "throughout,
        # exactly as it is for the plain-text fields". Worth pinning for the same reason the #612
        # Symbol case above is: `Bool <: Integer`, so the widening that made `Int32` work would
        # have made `true` work too had the carve-out not been written deliberately — and a stored
        # `1` is a silent wrong default, not a visible one.
        "read/filters_and_aggregates.md — a Bool `default=` on a numeric field is refused (#614)",
        FieldValidationError,
        () -> IntegerField(default = true),
    ),
    (
        # #614, the width half of the same sentence. Same reasoning, different keyword: without the
        # carve-out `max_length = true` is a one-character column.
        "read/filters_and_aggregates.md — a Bool `max_length` is refused (#614)",
        FieldValidationError,
        () -> CharField(max_length = true),
    ),
    (
        # #614. The page's last claim: a value too large for a 64-bit integer is refused rather
        # than wrapped. This is the one the implementation has to work for — `Int64(big(2)^70)` is
        # an `InexactError`, which would otherwise reach the caller raw, outside the #231/#239
        # taxonomy the page's own error table promises.
        "read/filters_and_aggregates.md — an out-of-range Integer `default=` is refused (#614)",
        FieldValidationError,
        () -> IntegerField(default = big(2)^70),
    ),
    (
        # #614, the width half again — `_int_kwarg`'s `try` is what makes this a
        # `FieldValidationError` rather than an `InexactError`.
        "read/filters_and_aggregates.md — an out-of-range `max_length` is refused (#614)",
        FieldValidationError,
        () -> CharField(max_length = big(2)^70),
    ),
    (
        # #614 review. The page's out-of-range sentence covers the float half too, and that half is
        # the one the implementation had to be CORRECTED for: `Float64(big"1e400")` saturates to
        # `Inf` instead of raising the way `Int64(big(2)^70)` does, so the first pass of the
        # widening silently stored `DEFAULT Inf` where `main` had refused the value outright.
        "read/filters_and_aggregates.md — an out-of-range Real `default=` is refused, not saturated (#614)",
        FieldValidationError,
        () -> FloatField(default = big"1e400"),
    ),
    (
        # #632. The page's numeric paragraph now states the `Decimal` rule explicitly, in both
        # directions. Only the refusing half can be a DOCERR case (this table asserts raises); the
        # accepting half — `FloatField(default = Decimal(...))` — is pinned by value in
        # `test_numeric_default_and_widths.jl`, which is where the two sides are compared.
        #
        # Worth pinning rather than trusting: until #632 this exact call SUCCEEDED and stored 5,
        # while the page said nothing about `Decimal` at all. The sentence and the code agreeing is
        # new, and this is the thing that keeps them agreeing.
        "read/filters_and_aggregates.md — a Decimal `default=` on an integer field is refused (#632)",
        FieldValidationError,
        () -> IntegerField(default = Decimals.Decimal(0, 5, 0)),
    ),
    # #631. `fields.md` → DateField now states the four accepted `default=` spellings AND what a
    # value outside them does. The positive half is pinned by value in
    # `test_default_converter_contract.jl`; the three cases below are the error-TYPE half, which is
    # this file's job. They matter more than the usual doc claim: until #631 each of them reached
    # the caller as a bare `MethodError`, i.e. the page named a type the code could not raise.
    (
        "fields.md — a malformed DateField `default=` string is refused (#631)",
        FieldValidationError,
        () -> DateField(default = "28/07/2024"),
    ),
    (
        # Separate from the malformed case on purpose: this string has the right SHAPE, so it is
        # the one that proves the calendar is checked rather than a regex.
        "fields.md — an impossible calendar date as a DateField `default=` is refused (#631)",
        FieldValidationError,
        () -> DateField(default = "2023-02-29"),
    ),
    (
        "fields.md — a numeric DateField `default=` is refused (#631)",
        FieldValidationError,
        () -> DateField(default = 42),
    ),
    # #639 — `errors.md`'s row and `upgrade_guide`'s `# Throws` docstring both promise this. A
    # broken install cannot be staged on the real one, so an empty temp directory stands in for the
    # shipped log; `upgrade_guide` reaches the same guard through `_read_upgrading_entries`.
    (
        "errors.md / src/tools.jl — upgrade_guide docstring: an empty upgrade log is a broken install (#639)",
        InvalidConfigurationError,
        () -> mktempdir(PormG._read_upgrading_entries),
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

# ─────────────────────────────────────────────────────────────────────────────
# The unknown-field message itself: field, model, and SORTED choices (#446)
#
# The table above pins the TYPE for five shapes. This pins what the message says, which is the half
# that makes the error useful — a bare `@test_throws UnknownFieldError` would pass on any unknown-name
# error raised anywhere in the builder.
#
# Lives here rather than in `test_typed_exceptions.jl` beside #433's precedent, because these shapes
# only fail at RENDER, and rendering needs a connection-bound model — which is what the DOCERR mocks
# above already provide.
# ─────────────────────────────────────────────────────────────────────────────
@testset "unknown-field message names the field, the model and sorted choices (#446)" begin
    err = try
        DOCERR_RESULT_PG.objects.filter("driverid__no_such_column" => 1).list(show_query = :dict)
        nothing
    catch e
        e
    end
    @test err isa PormG.UnknownFieldError
    msg = sprint(showerror, err)
    # The offending segment, and the model actually searched — the JOINED one, not the base model.
    # Naming the base model would send the reader to the wrong table's column list.
    @test occursin("no_such_column", msg)
    @test occursin(PormG.model_table_name(DOCERR_DRIVER_PG), msg)
    @test !occursin("not found in $(PormG.model_table_name(DOCERR_RESULT_PG))", msg)

    # The choices are SORTED. `field_names` is declaration order, so on a wide model the name the
    # user typo'd sits at an unpredictable offset; Django sorts the same list for the same reason.
    # Asserting the PROPERTY, not a literal list, so adding a field to the fixture cannot break this
    # for the wrong reason.
    # Strip ANSI before parsing STRUCTURE out of the message. `_emsg` keeps the escapes when
    # `Base.have_color` is set, so under `--color=yes` the captured names carry `\e[4m\e[32m` and a
    # membership assertion silently fails — the exact local-passes/CI-fails split this repo has hit
    # before. Content assertions above are matched on ANSI-free runs of text instead.
    plain = replace(msg, r"\e\[[0-9;]*m" => "")
    listed = [strip(x) for x in split(match(r"fields: ([^;]+)", plain).captures[1], ",")]
    @test listed == sort(listed)
    @test length(listed) > 1
    @test "surname" in listed
end

# ─────────────────────────────────────────────────────────────────────────────
# The write path's unknown-field message: same funnel as the read path, minus the accessors (#462)
#
# The two cases in the table above pin the TYPE. This pins the half that decides whether the error
# is useful — and the one deliberate difference between the two paths.
#
# `create("results" => …)` can never work: a reverse accessor is addressable in a filter/values path
# but is not a column, so listing the accessors in a WRITE error would advertise a capability that
# does not exist. `_unknown_field(...; include_accessors = false)` drops that tail and keeps
# everything else, so the read and write messages stay one funnel rather than two wordings that
# drift apart.
#
# `DocErrCycleModels` rather than the `DOCERR_*` fixtures: `related_objects` is populated by
# reverse-accessor REGISTRATION, which only `set_models` does. The hand-built models above have an
# empty map, so asserting "no accessors listed" against one would pass no matter what this keyword
# did — the assertion needs a model that has accessors to omit.
# ─────────────────────────────────────────────────────────────────────────────
@testset "the write path's unknown-field message omits reverse accessors (#462)" begin
    model = DocErrCycleModels.Docerr_cycle_a
    accessors = collect(keys(model.related_objects))
    # Guard the fixture, not the contract: with no accessor to omit the two assertions below are
    # vacuous, so fail on the fixture instead of passing silently.
    @test !isempty(accessors)

    write_err = try
        model.objects.create("code" => "x", "nope" => 2, show_query = :dict)
        nothing
    catch e
        e
    end
    @test write_err isa UnknownFieldError

    # Strip ANSI before parsing structure: `_emsg` keeps the escapes under `--color=yes`, which is
    # the local-passes/CI-fails split this file has hit before.
    write_msg = replace(sprint(showerror, write_err), r"\e\[[0-9;]*m" => "")
    @test occursin("nope", write_msg)
    @test occursin(PormG.model_table_name(model), write_msg)
    # Sorted, same property the read-path testset above asserts — the funnel is shared, so this
    # would only diverge if the write path stopped using it.
    listed = [strip(x) for x in split(match(r"fields: ([^;]+)", write_msg).captures[1], ",")]
    @test listed == sort(listed)
    @test "code" in listed
    # The difference: no accessor tail.
    @test !occursin("reverse accessors", write_msg)
    for a in accessors
        @test !occursin(a, write_msg)
    end

    # The control. The SAME model, the SAME unknown name, read instead of written — the accessors
    # are listed there, which is what makes the omission above a deliberate choice rather than an
    # empty map.
    read_err = try
        model.objects.filter("nope" => 2).list(show_query = :dict)
        nothing
    catch e
        e
    end
    @test read_err isa UnknownFieldError
    read_msg = replace(sprint(showerror, read_err), r"\e\[[0-9;]*m" => "")
    @test occursin("reverse accessors", read_msg)
    @test all(a -> occursin(a, read_msg), accessors)
end
