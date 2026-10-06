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
# #648 — the SQLite width refusal `fields.md`, `postgres.md` and `errors.md` name.
using PormG.Models: DecimalField
# #28 — the network-address claims on `fields.md` and `postgres.md`.
using PormG.Models: GenericIPAddressField, CIDRField
# #28 — the ArrayField claims on `fields.md` and `postgres.md`, and the element fields they name.
using PormG.Models: ArrayField
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
# #867 — an aggregate wrapping a `Subquery`, for the subqueries-page claim below.
using PormG.Functions: Max
# #569 — a text format outside the portable table, for the ToChar docstring claim below.
using PormG.Functions: ToChar
# #40 — the `Extract` part-spelling claim on the PostgreSQL guide.
using PormG.Functions: Extract
# #696 — the `Cast` type-string claims on the functions page.
using PormG.Functions: Cast
# #903 — the `Value(ip"…")` SQLite claim on the fields page.
using PormG.Functions: Value
import Sockets
import DataFrames
# #733 — the repair-op claim reads a history table, so it needs the SQLite driver (idempotent reload).
include(joinpath(@__DIR__, "..", "load_drivers.jl"))

# #953 — an aggregate over a BooleanField, for the filters-page and Sum/Avg docstring claims below.
using PormG.Models: BooleanField
using PormG.Functions: Sum, Avg
# Mock backends: dialect dispatch is by connection TYPE, so a bare subtype is enough to render
# SQL and to fire the backend-capability guards. No DB, no pool.
struct DocErrMockPostgres <: PormG.PormGPostgres end
struct DocErrMockSQLite <: PormG.PormGSQLite end
# #742 — a PostgreSQL stand-in whose catalog is empty, for the one claim whose plan asks it
# something (a column rename looks up the old column's constraints) before the error fires.
struct DocErrCatalogFreePg742 <: PormG.PormGPostgres end
PormG.ConnectionPool.fetch(::DocErrCatalogFreePg742, sql::String; conn = nothing, params = nothing,
                           ignore_tx::Bool = false) = DataFrames.DataFrame()

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

# #801 — a date AND a timestamp column on SQLite. Since #814 a timestamp difference renders there, and
# since #881 it orders and takes arithmetic; what SQLite refuses is what has no millisecond form.
const DOCERR_RACE801_SL = let m = Model("docerr_race801_docerr_sl",
        raceid = IDField(), date = DateField(), start_at = DateTimeField(null = true))
    m.connect_key = "docerr_sl"; m._module = Main; m
end

# #671 — a primary key the database generates by some means other than an auto-increment PormG can
# pre-allocate, which is what `returning=` refuses to guess about. Its own model because every other
# fixture here has an `IDField` pk.
const DOCERR_CIRCUIT_PG = let m = Model("docerr_circuit_docerr_pg",
        circuitref = CharField(primary_key = true), name = CharField())
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

# #953 — a boolean column on both engines: the refusal of `Sum`/`Avg` over one is engine-independent.
const DOCERR_ENTRY953_PG, DOCERR_ENTRY953_SL = map(("docerr_pg", "docerr_sl")) do key
    m = Model("docerr_entry953_$key", id = IDField(), raceid = IntegerField(),
              is_rookie = BooleanField())
    m.connect_key = key; m._module = Main; m
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
        "read/subqueries_and_ctes.md — an aggregate cannot wrap a `Subquery(...)` (#867)",
        QueryBuildError,
        () -> begin
            inner = DOCERR_STATUS_PG.objects.values("status")
            DOCERR_RESULT_PG.objects.values("resultid", "x" => Max(Subquery(inner))).
                list(show_query = :dict)
        end,
    ),
    (
        "read/subqueries_and_ctes.md — `@in` takes the query itself, not a scalar `Subquery(...)` (#926)",
        FilterError,
        () -> begin
            inner = DOCERR_STATUS_PG.objects.values("statusid")
            DOCERR_RESULT_PG.objects.filter("statusid__@in" => Subquery(inner)).list(show_query = :dict)
        end,
    ),
    (
        "read/subqueries_and_ctes.md — a pattern lookup refuses a scalar `Subquery(...)` (#926)",
        FilterError,
        () -> begin
            inner = DOCERR_STATUS_PG.objects.values("status")
            DOCERR_RESULT_PG.objects.filter("statusid__@contains" => Subquery(inner)).list(show_query = :dict)
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
        # #703. A projection alias named after a model field makes a filter on that name two-valued —
        # the column in WHERE or the projected sum in HAVING — and PormG refuses rather than choose.
        # Choosing either way was silent: the aggregate printed into WHERE (a driver error), and
        # "the field wins" would have filtered rows the caller meant to filter as groups. The
        # declaration alone stays legal; only the filter on the shared name raises.
        "read/filters_and_aggregates.md — a filter key naming a field and a projection alias is ambiguous",
        AmbiguousFieldError,
        () -> begin
            q = DOCERR_RESULT_PG.objects
            q.values("driverid", "points" => PormG.Functions.Sum("points"))
            q.filter("points__@gt" => 100)
            q.list(show_query = :dict)
        end,
    ),
    (
        # #757. `__` is the path separator, so an alias spelled with it was invisible to every alias
        # router while the render still resolved it: an aggregate printed into WHERE, a window
        # escaped #685. It is refused where it is declared.
        "read/filters_and_aggregates.md — a projection alias cannot contain `__`",
        QueryBuildError,
        () -> DOCERR_RESULT_PG.objects.values("driverid", "season__points" => PormG.Functions.Sum("points")),
    ),
    (
        "src/querybuilder/types.jl — object docstring: a `.values()` alias cannot contain `__`",
        QueryBuildError,
        () -> DOCERR_RESULT_PG.objects.values("driverid", "win__total" => PormG.Functions.Sum("points")),
    ),
    (
        # #706. The same two meanings, met by a `When` inside another projection rather than by a
        # filter. The page shows the condition declared BEFORE the colliding SUM, the order that
        # used to drop the SUM silently; the other order compared the SUM, and both now raise.
        "read/filters_and_aggregates.md — a condition inside a projection naming a field and an alias is ambiguous",
        AmbiguousFieldError,
        () -> begin
            q = DOCERR_RESULT_PG.objects
            q.values("driverid",
                     "podium_finish" => PormG.Functions.Case(
                         [PormG.Functions.When("points__@gte" => 15, then = 1)], default = 0),
                     "points" => PormG.Functions.Sum("points"))
            q.list(show_query = :dict)
        end,
    ),
    (
        # #707. The page states one typing rule for an alias filter, top-level or inside `Q`. The
        # `Q` spelling is the half that used to bind a wrong-typed value unchecked, so it is the one
        # pinned here: a number alias refuses a string, naming the alias.
        "read/filters_and_aggregates.md — a wrong-typed alias filter value raises FilterError on every spelling",
        FilterError,
        () -> begin
            q = DOCERR_RESULT_PG.objects
            q.values("driverid", "double_points" => F("points") * 2)
            q.filter(Q("double_points__@gte" => "fifteen"))
            q.list(show_query = :dict)
        end,
    ),
    (
        # #705. The function pages say an operand that is not a column path, a number, a `Bool`, a
        # date or time, or an expression raises `QueryBuildError` when the expression is built — at
        # the constructor, not as a `MethodError` from the build walk. This case pinned a `Date` until
        # #721 made dates operands (the SQLite binder stores them as their column's text); a bare
        # `Period` is the value the page still refuses, so it is the one pinned now.
        "read/functions_and_dates.md — a function operand that is not a column, number, date or expression raises QueryBuildError",
        QueryBuildError,
        () -> PormG.Functions.Least("dob", PormG.Dates.Day(1)),
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
        # #685. *Filtering on a Window Result* says a filter on a window alias raises at build time
        # rather than rendering `HAVING RANK() OVER (…)`, which both engines rejected at execution.
        "read/window_functions.md — filter() on a window alias is refused",
        QueryBuildError,
        () -> begin
            q = DOCERR_RESULT_PG.objects
            q.values("points", "r" => Rank(over = WindowOver(order_by = ["-points"])))
            q.filter("r" => 1)
            q.list(show_query = :dict)
        end,
    ),
    (
        # #722. The same section says a projection whose condition READS a window alias is refused
        # the same way: it renders the window, though its own node holds only the alias's name.
        "read/window_functions.md — filter() on a projection reading a window alias is refused",
        QueryBuildError,
        () -> begin
            q = DOCERR_RESULT_PG.objects
            q.values("points", "r" => Rank(over = WindowOver(order_by = ["-points"])),
                     "top" => PormG.Functions.Case(
                         [PormG.Functions.When("r" => 1, then = 1)], default = 0))
            q.filter("top" => 1)
            q.list(show_query = :dict)
        end,
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
        # #812. *How a CTE Column Is Typed*: a `Case` whose branches do not agree (here text beside a
        # number) raises rather than being typed text, because the type decides how a filter on the
        # column binds its value. Raised when the outer query builds the CTE model.
        "read/subqueries_and_ctes.md — a CTE Case column whose branches disagree is refused (#812)",
        QueryBuildError,
        () -> begin
            body = DOCERR_RESULT_PG.objects
            body.values("resultid", "top" => PormG.Functions.Case(
                [PormG.Functions.When("points__@gte" => 15, then = 1)], default = "none"))
            q = DOCERR_RESULT_PG.objects
            q.with("c" => body, join_field = "resultid" => "resultid")
            q.values("resultid", "c__top")
            q.list(show_query = :dict)
        end,
    ),
    (
        # #852 (was #822's Coalesce-date refusal, which #852 lifted). `Coalesce`, `Greatest` and
        # `Least` cast to their `output_field` on SQLite too, so a temporal type other than `date`
        # raises there, as `Cast` does.
        "read/functions_and_dates.md — a timestamp output_field on Coalesce raises on SQLite (#852)",
        BackendCapabilityError,
        () -> DOCERR_RESULT_SL.objects.
            values("resultid", "t" => PormG.Functions.Coalesce("points", 0; output_field = "timestamp")).
            list(show_query = :dict),
    ),
    (
        # #835. `Concat` renders no cast on either engine, so a non-text `output_field` is refused
        # when the expression is built — before any query or connection exists.
        "read/functions_and_dates.md — a non-text output_field on Concat raises (#835)",
        InvalidValueError,
        () -> PormG.Functions.Concat("year", PormG.Functions.Value("0"), "round"; output_field = "integer"),
    ),
    (
        # #859. `Coalesce`, `Greatest` and `Least` take two or more arguments; one argument is
        # refused when the expression is built (on SQLite it rendered the aggregate `MAX(x)`).
        "read/functions_and_dates.md — Greatest with fewer than two arguments raises (#859)",
        QueryBuildError,
        () -> PormG.Functions.Greatest("dob"),
    ),
    (
        # #822. A temporal cast target other than `date` raises on SQLite, which has no time types:
        # `CAST(… AS TIMESTAMP)` there turns '2020-03-29 10:11:12' into the number 2020.
        "read/functions_and_dates.md — a timestamp cast raises on SQLite (#822)",
        BackendCapabilityError,
        () -> begin
            q = DOCERR_RESULT_SL.objects
            q.values("resultid", "t" => PormG.Functions.Cast("points", "timestamp"))
            q.list(show_query = :dict)
        end,
    ),
    (
        # #812. The same section: a function outside the table, with no declared type, raises.
        "read/subqueries_and_ctes.md — a CTE column from an untyped function is refused (#812)",
        QueryBuildError,
        () -> begin
            body = DOCERR_RESULT_PG.objects
            body.values("resultid", "nm" => Lower("driverid__surname"))
            q = DOCERR_RESULT_PG.objects
            q.with("c" => body, join_field = "resultid" => "resultid")
            q.values("resultid", "c__nm")
            q.list(show_query = :dict)
        end,
    ),
    (
        # #823. The same section: `F` arithmetic on a value that is not a number, projected straight
        # into the body, raises rather than being typed as its column (it was a raw MethodError).
        # A JSON column stands in for the page's text one; the fixture has no text column of its own.
        "read/subqueries_and_ctes.md — CTE F arithmetic on a non-number is refused (#823)",
        QueryBuildError,
        () -> begin
            body = DOCERR_RESULT_PG.objects
            body.values("resultid", "later" => F("payload") + 1)
            q = DOCERR_RESULT_PG.objects
            q.with("c" => body, join_field = "resultid" => "resultid")
            q.values("resultid", "c__later")
            q.list(show_query = :dict)
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
    (
        # #917. The shape of the doc's refused example — an aggregate beside a legal self-join
        # correlation — on this file's model. It rendered `ON … AND (COUNT(…) > ?)`, which both
        # engines reject at execution.
        "read/custom_joins.md — an aggregate or window function in a join ON clause is refused",
        QueryBuildError,
        () -> begin
            q = DOCERR_RESULT_PG.objects
            q.values("resultid")
            q.cjoin_on(DOCERR_RESULT_PG, alias = "r2",
                       on = [Joined("r2", "points") == F("points"), Count("resultid") > 1])
            q.list(show_query = :dict)
        end,
    ),
    (
        # #962. The doc's constructor/driver shape, on this file's two sibling relations: a right
        # side on the status join that reaches the driver, which landed in whichever join was later.
        "read/custom_joins.md — a right side reaching a relation off the join path is refused",
        FilterError,
        () -> begin
            q = DOCERR_RESULT_PG.objects
            q.on("statusid", "status" => F("driverid__nationality"))
            q.values("resultid", "statusid__status")
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
        # #433. delete() re-uses the queryset being deleted as a scoping subquery (each cascade
        # statement's `"<fk>" IN (<query>)`), which puts a declared CTE in exactly the nested
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
    # #672 — `write/bulk.md` → How rows reach the database: a cell must hold a single value on
    # both backends. A `Vector` in a text column passes validation (the text formatter maps it
    # element-wise), and neither a PostgreSQL column array nor a SQLite VALUES row can store it.
    # Build-time, like the case above: the refusal runs in the per-row sweep, before any SQL.
    (
        "write/bulk.md — a collection in a bulk cell raises InvalidValueError",
        InvalidValueError,
        () -> bulk_insert(DOCERR_STINT_PG.objects,
                          DataFrames.DataFrame(driver = [["Senna", "Prost"]]),
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
    # #712 — the single-row half of the #672 rule above. Before it, `create()` bound the `Vector`
    # as one array parameter on PostgreSQL (stored as `{"Senna","Prost"}` text) and as extra `?`s
    # on SQLite. Build-time: the refusal runs at the bind site, before any SQL executes.
    (
        "write/create.md — a Vector in a text-like field raises InvalidValueError",
        InvalidValueError,
        () -> DOCERR_STINT_PG.objects.create("driver" => ["Senna", "Prost"], show_query = :dict),
    ),
    (
        "write/update.md — Automatic Validation: a Vector set on a text-like field raises InvalidValueError",
        InvalidValueError,
        () -> DOCERR_STINT_PG.objects.filter("id" => 1).update("driver" => ["Senna", "Prost"],
                                                              show_query = :dict),
    ),
    # #716 — "whatever its elements": a collection `format_text_sql` cannot map crashed inside the
    # formatter as a raw `MethodError` before the #712 check ran.
    (
        "write/create.md — a collection of non-text elements in a text-like field raises InvalidValueError",
        InvalidValueError,
        () -> DOCERR_STINT_PG.objects.create("driver" => [1.5, 2.5], show_query = :dict),
    ),
    (
        "read/filters_and_aggregates.md — a JSON path key with spaces is not addressable",
        InvalidValueError,
        () -> DOCERR_RESULT_PG.objects.filter("payload__bad key" => 1).list(show_query = :dict),
    ),
    # #811 — the JSON path section and *A column is not a list* say a column expression on the right
    # raises `FilterError`. Before #811 the path lookup bound the expression's `repr` on PostgreSQL
    # (zero rows, no error) and `@in` rendered `IN "Tb"."points"` for the server to reject.
    (
        "read/filters_and_aggregates.md — a JSON path lookup against a column expression",
        FilterError,
        () -> DOCERR_RESULT_PG.objects.filter("payload__wins" => F("points")).list(show_query = :dict),
    ),
    (
        "read/filters_and_aggregates.md — @in against a column expression",
        FilterError,
        () -> DOCERR_RESULT_PG.objects.filter("points__@in" => F("resultid")).list(show_query = :dict),
    ),
    # #918 — the same section says a LIST of column expressions raises `FilterError` too. It was a raw
    # `MethodError` naming `_get_pair_to_oper`.
    (
        "read/filters_and_aggregates.md — @in against a list of column expressions",
        FilterError,
        () -> DOCERR_RESULT_PG.objects.filter("points__@in" => [F("resultid"), F("points")]).list(show_query = :dict),
    ),
    # #811 (review) — the containment section says a column expression raises `FilterError` on both
    # backends; it is refused at parse, ahead of the SQLite capability check, so the SQLite mock too.
    (
        "read/filters_and_aggregates.md — a JSONB containment lookup against a column expression",
        FilterError,
        () -> DOCERR_RESULT_SL.objects.filter("payload__@has_key" => F("points")).list(show_query = :dict),
    ),
    # #793 — *String Matching* says a LIKE-family lookup against a column raises `FilterError`; it used
    # to concatenate the lookup name into the SQL (`"surname" contains "forename"`).
    (
        "read/filters_and_aggregates.md — a LIKE-family lookup against a column expression",
        FilterError,
        () -> DOCERR_DRIVER_PG.objects.filter("surname__@contains" => F("nationality")).list(show_query = :dict),
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
    # #692 — *`Q` and `Qor` on Aggregate Aliases* says a `Qor` mixing an aggregate alias with a column
    # condition raises when the query is built: an OR cannot be split between WHERE and HAVING. The
    # rendering half (a `Q`/`Qor` of aggregate aliases goes to HAVING) is pinned in
    # `test/unit/test_q_aggregate_alias.jl`.
    (
        "read/filters_and_aggregates.md — a Qor mixing an aggregate alias with a column is refused",
        QueryBuildError,
        () -> DOCERR_RACE_PG.objects.values("name", "n" => Count("raceid")).
            filter(Qor("n__@lt" => 20, "name" => "Monaco Grand Prix")).list(show_query = :dict),
    ),
    # #895 — *Filter the alias, not the expression* (field_expressions.md) and the HAVING section of
    # filters_and_aggregates.md say an aggregate written straight into `filter` raises when the query
    # is built, in each spelling the warning lists. Every message, and the HAVING spellings that
    # still render, are pinned in `test/unit/test_filter_aggregate_expression.jl`.
    (
        "read/field_expressions.md — an expression containing an aggregate is refused in filter (#895)",
        QueryBuildError,
        () -> DOCERR_RACE_PG.objects.values("name").
            filter((Max("raceid") - Count("raceid")) > 3).list(show_query = :dict),
    ),
    (
        "read/field_expressions.md + read/filters_and_aggregates.md — a bare aggregate comparison is refused in filter (#895)",
        QueryBuildError,
        () -> DOCERR_RACE_PG.objects.values("name").filter(Count("raceid") <= 3).list(show_query = :dict),
    ),
    (
        "read/field_expressions.md — an aggregate inside Q is refused in filter (#895)",
        QueryBuildError,
        () -> DOCERR_RACE_PG.objects.values("name").filter(Q(Count("raceid") > 3)).list(show_query = :dict),
    ),
    (
        "read/field_expressions.md — an aggregate on the right of a pair is refused in filter (#895)",
        QueryBuildError,
        () -> DOCERR_RACE_PG.objects.values("name").filter("raceid" => Max("raceid")).list(show_query = :dict),
    ),
    # #931 — *Arithmetic is not a condition* (field_expressions.md) and the `When` docstring say an
    # arithmetic or bitwise expression used as a condition raises at construction. Every position and
    # operation kind is pinned in `test/unit/test_filter_aggregate_expression.jl`.
    (
        "read/field_expressions.md + src/querybuilder/functions.jl — When docstring: an arithmetic condition is refused (#931)",
        QueryBuildError,
        () -> DOCERR_RACE_PG.objects.values("name",
            "c" => PormG.Functions.Case([PormG.Functions.When(F("raceid") + 1, then = 1)], default = 0)).list(show_query = :dict),
    ),
    (
        "read/field_expressions.md — a bitwise expression is refused in filter (#931)",
        QueryBuildError,
        () -> DOCERR_RACE_PG.objects.filter(F("raceid") & 4).list(show_query = :dict),
    ),
    # #938 — `subqueries_and_ctes.md` and the `OuterRef` docstring say Django's two-levels-up spelling
    # raises.
    (
        "read/subqueries_and_ctes.md + src/querybuilder/types.jl — OuterRef docstring: OuterRef(OuterRef(…)) is refused (#938)",
        QueryBuildError,
        () -> PormG.QueryBuilder.OuterRef(PormG.QueryBuilder.OuterRef("raceid")),
    ),
    # #942 — the same section and the `When` docstring say a function whose result is not boolean is
    # refused as a `When` condition. Every refused function and spelling is pinned in
    # `test/unit/test_filter_aggregate_expression.jl`.
    (
        "read/field_expressions.md + src/querybuilder/functions.jl — When docstring: a non-boolean function condition is refused (#942)",
        QueryBuildError,
        () -> DOCERR_RACE_PG.objects.values("name",
            "c" => PormG.Functions.Case([PormG.Functions.When(PormG.Functions.Lower("name"), then = 1)], default = 0)).list(show_query = :dict),
    ),
    (
        "read/field_expressions.md — a Coalesce over a number column is refused as a When condition (#942)",
        QueryBuildError,
        () -> DOCERR_RACE_PG.objects.values("name",
            "c" => PormG.Functions.Case([PormG.Functions.When(PormG.Functions.Coalesce("raceid", 0), then = 1)], default = 0)).list(show_query = :dict),
    ),
    # Intentional PG/SQLite divergence: these pages tell the reader the lookup is PostgreSQL-only
    # and raises on SQLite. Asserting it on the SQLite mock keeps the documented divergence honest.
    (
        "read/filters_and_aggregates.md — iunaccent_* lookups require PostgreSQL",
        BackendCapabilityError,
        () -> DOCERR_DRIVER_SL.objects.filter("surname__@iunaccent_contains" => "sena").
            list(show_query = :dict),
    ),
    # #635 — the regex family refuses on SQLite (the filters page, `postgres.md`'s list and
    # divergence row, and `errors.md`). One positive and one negated spelling: both arms are
    # separate Dialect methods, so pinning one would not hold the other.
    (
        "read/filters_and_aggregates.md + postgres.md + errors.md — `@regex` / `@iregex` require PostgreSQL",
        BackendCapabilityError,
        () -> DOCERR_DRIVER_SL.objects.filter("surname__@iregex" => "^ver").
            list(show_query = :dict),
    ),
    (
        "postgres.md — `@nregex` / `@niregex` raise on SQLite",
        BackendCapabilityError,
        () -> DOCERR_DRIVER_SL.objects.filter("surname__@nregex" => "nen\$").
            list(show_query = :dict),
    ),
    # #635 — the filters page says a Julia `Regex` value is refused with `FilterError`.
    (
        "read/filters_and_aggregates.md — a Julia `Regex` value is refused",
        FilterError,
        () -> DOCERR_DRIVER_SL.objects.filter("surname__@regex" => r"^Ver").
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
    # #40 — `postgres.md`'s *PostgreSQL-only lookups and functions* section and its divergence table
    # promise `BackendCapabilityError` on SQLite for each of these. `@has_key` and `@iunaccent_contains`
    # are pinned above for the filters page; the three sibling JSONB operators, the negated unaccent
    # lookups and the `Extract` part spelling were stated nowhere else, so nothing held them.
    (
        "postgres.md — `@jcontains` raises on SQLite",
        BackendCapabilityError,
        () -> DOCERR_RESULT_SL.objects.filter("payload__@jcontains" => Dict("wins" => 1)).
            list(show_query = :dict),
    ),
    (
        "postgres.md — `@has_any_keys` raises on SQLite",
        BackendCapabilityError,
        () -> DOCERR_RESULT_SL.objects.filter("payload__@has_any_keys" => ["wins", "poles"]).
            list(show_query = :dict),
    ),
    (
        "postgres.md — `@has_keys` raises on SQLite",
        BackendCapabilityError,
        () -> DOCERR_RESULT_SL.objects.filter("payload__@has_keys" => ["wins", "poles"]).
            list(show_query = :dict),
    ),
    (
        "postgres.md — `@niunaccent_*` lookups raise on SQLite",
        BackendCapabilityError,
        () -> DOCERR_DRIVER_SL.objects.filter("surname__@niunaccent_exact" => "raikkonen").
            list(show_query = :dict),
    ),
    # A part SQLite has no equivalent for. The spelling is case-blind since #684, so a lower-case
    # portable part renders instead — `test_date_functions_sql.jl` pins that half.
    (
        "postgres.md + read/functions_and_dates.md — an `Extract` part outside the portable eight raises on SQLite",
        BackendCapabilityError,
        () -> DOCERR_RESULT_SL.objects.values("x" => Extract("resultid", "EPOCH")).
            list(show_query = :dict),
    ),
    # #691: a string that is no `EXTRACT` field is refused when the expression is built, before any
    # engine is consulted — so the PostgreSQL half of the claim is the one that used to be false.
    (
        "postgres.md + read/functions_and_dates.md — an `Extract` part that is no field raises on both engines",
        InvalidValueError,
        () -> DOCERR_RESULT_PG.objects.values("x" => Extract("resultid", "fortnight")).
            list(show_query = :dict),
    ),
    # #696: a `Cast` type string outside the grammar is refused when the expression is built, on
    # both engines — the PostgreSQL arm used to write it verbatim after `::`.
    (
        "read/functions_and_dates.md — a `Cast` type string outside the grammar raises on both engines",
        InvalidValueError,
        () -> DOCERR_RESULT_PG.objects.values("x" => Cast("resultid", "integer OR TRUE")).
            list(show_query = :dict),
    ),
    # #713: a window frame outside the grammar is refused when `WindowOver` is called, on both
    # engines — including one PostgreSQL would refuse itself, which is the example the page shows.
    (
        "read/window_functions.md + WindowOver docstring — a `frame=` outside the grammar raises on both engines",
        InvalidValueError,
        () -> DOCERR_RESULT_SL.objects.values("x" => Rank(over = WindowOver(order_by = ["resultid"],
            frame = "ROWS BETWEEN 1 FOLLOWING AND CURRENT ROW"))).list(show_query = :dict),
    ),
    # #696: array brackets pass the grammar but SQLite has no array type to cast to.
    (
        "read/functions_and_dates.md — a `Cast` to an array type raises on SQLite",
        BackendCapabilityError,
        () -> DOCERR_RESULT_SL.objects.values("x" => Cast("resultid", "integer[]")).
            list(show_query = :dict),
    ),
    # `without_foreign_keys` refuses to nest before touching the database, so a mock pool bound as
    # the ambient transaction connection is enough to reach the guard. One case per engine: the
    # PostgreSQL method used to nest silently as a SAVEPOINT (#686), and the docs now promise the
    # refusal on both.
    (
        "postgres.md + without_foreign_keys docstring — nesting it inside a transaction raises on SQLite",
        TransactionError,
        () -> with_tx_context(DocErrMockSQLite(), nothing) do
            without_foreign_keys(() -> nothing, DocErrMockSQLite())
        end,
    ),
    (
        "postgres.md + without_foreign_keys docstring — nesting it inside a transaction raises on PostgreSQL (#686)",
        TransactionError,
        () -> with_tx_context(DocErrMockPostgres(), nothing) do
            without_foreign_keys(() -> nothing, DocErrMockPostgres())
        end,
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
    # #29: the Index docstring lists what the constructor refuses; models.md states the first and
    # third, and Django's opclass rule.
    (
        "models.md + src/Models.jl — Index docstring: a descending column on a method other than btree is rejected (#29)",
        ModelDefinitionError,
        () -> Index(fields = ("-points",), method = "gin"),
    ),
    (
        "models.md + src/Models.jl — Index docstring: hash indexes a single column (#29)",
        ModelDefinitionError,
        () -> Index(fields = ("raceid", "lap"), method = "hash"),
    ),
    (
        "models.md + src/Models.jl — Index docstring: an Index naming an opclass needs a name (#29)",
        ModelDefinitionError,
        () -> Index(fields = ("surname",), opclasses = ("varchar_pattern_ops",)),
    ),
    # models.md, postgres.md and the Index docstring: `makemigrations` refuses a method or an operator
    # class on SQLite. Driven at the SQLite renderer every create path shares, the way the #648 row
    # below is; the planner-entry half is pinned in `test_indexes.jl`.
    (
        "models.md + src/Models.jl — Index docstring: a method or an opclass is refused on SQLite (#29)",
        BackendCapabilityError,
        () -> PormG.Dialect.create_index(DocErrMockSQLite(), "\"driver_dob_brin_idx\"", "\"driver\"", ["\"dob\""];
                                         method = "brin"),
    ),
    # models.md: a declaration that wants a hand-made index's NAME for another shape is refused.
    (
        "models.md — a declaration cannot take a hand-made index's name (#29)",
        InvalidMigrationError,
        () -> let m = Model("docerr_result_29", id = IDField(), raceid = IntegerField(), grid = IntegerField(),
                            indexes = [Index(fields = ("raceid", "grid"), name = "result_hand_gin")])
            t = PormG.Migrations.live_table(m, DocErrCatalogFreePg742())
            hand = PormG.Migrations.LiveComposite("result_hand_gin", ["raceid"], false, false, "gin", [false],
                                                  Union{String, Nothing}["int4_ops"], [true], nothing, nothing)
            live = [PormG.Migrations.LiveTable(t.name, t.columns, t.indexes, [hand], t.checks)]
            schema = Dict{Symbol, Dict{Symbol, Union{Bool, PormG.PormGModel}}}(
                :docerr_result_29 => Dict{Symbol, Union{Bool, PormG.PormGModel}}(:model => m, :exist => false))
            settings = PormG.Configuration.Settings(); settings.change_db = true
            PormG.Migrations.get_migration_plan(live, schema, DocErrCatalogFreePg742(), settings; interactive = false)
        end,
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
    # #665 — `write/bulk.md` → Matching and Execution Rules, `api.md` and `errors.md` promise that a
    # handler carrying state an UPDATE cannot express raises `UnsafeMutationError` rather than being
    # dropped, and that a handler filter traversing a relation raises `QueryBuildError`. One case per
    # documented family: the `update()` guards bulk_update now shares, and the two it adds.
    (
        "write/bulk.md + errors.md — bulk_update on a handler with limit() raises (#665)",
        UnsafeMutationError,
        () -> bulk_update(DOCERR_RESULT_PG.objects.filter("points" => 0).limit(5),
                          DataFrames.DataFrame(resultid = [1], points = [9]),
                          columns = ["points"], match_on = ["resultid"], show_query = :dict),
    ),
    (
        "write/bulk.md + errors.md — bulk_update on a handler with a CTE raises (#665)",
        UnsafeMutationError,
        () -> bulk_update(DOCERR_RESULT_PG.objects.with(
                              "zero" => DOCERR_RESULT_PG.objects.filter("points" => 0).values("resultid")),
                          DataFrames.DataFrame(resultid = [1], points = [9]),
                          columns = ["points"], match_on = ["resultid"], show_query = :dict),
    ),
    # #668 — `write/update.md` → Projections Are Ignored, `write/bulk.md` and `errors.md` promise that
    # a filter on a `values()` alias raises `UnsafeMutationError` from `update()` and `bulk_update()`:
    # it is a HAVING predicate, and an UPDATE would otherwise drop it.
    (
        "write/update.md + errors.md — update() with a filter on a values() alias raises (#668)",
        UnsafeMutationError,
        () -> DOCERR_RESULT_PG.objects.filter("points" => 0).
                  values("resultid", "double_points" => PormG.QueryBuilder.F("points") * 2).
                  filter("double_points__@gt" => 20).
                  update("points" => 1, show_query = :dict),
    ),
    (
        "write/bulk.md + errors.md — bulk_update with a filter on a values() alias raises (#668)",
        UnsafeMutationError,
        () -> bulk_update(DOCERR_RESULT_PG.objects.filter("points" => 0).
                              values("resultid", "double_points" => PormG.QueryBuilder.F("points") * 2).
                              filter("double_points__@gt" => 20),
                          DataFrames.DataFrame(resultid = [1], points = [9]),
                          columns = ["points"], match_on = ["resultid"], show_query = :dict),
    ),
    (
        "write/bulk.md — a bulk_update handler filter that traverses a relation raises (#665)",
        QueryBuildError,
        () -> bulk_update(DOCERR_RESULT_PG.objects.filter("driverid__surname" => "Senna"),
                          DataFrames.DataFrame(resultid = [1], points = [9]),
                          columns = ["points"], match_on = ["resultid"], show_query = :dict),
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
    # #671 — `write/bulk.md` → Returning Generated Values names three refusals. All are build-time:
    # the key is chosen before any statement runs, so a dry run reaches every one of them.
    (
        "write/bulk.md — returning= naming an unknown field raises UnknownFieldError (#671)",
        UnknownFieldError,
        () -> bulk_insert(DOCERR_STATUS_PG.objects, DataFrames.DataFrame(status = ["Finished"]),
                          returning = ["statuz"], show_query = :dict),
    ),
    (
        "write/bulk.md — returning= with an on_conflict target the INSERT does not carry raises (#671)",
        QueryBuildError,
        () -> bulk_insert(DOCERR_STATUS_PG.objects, DataFrames.DataFrame(status = ["Finished"]),
                          returning = ["statusid"], show_query = :dict,
                          on_conflict = (action = :nothing, target = ["statusid"])),
    ),
    (
        "write/bulk.md — returning= with a database-generated non-auto pk and no target raises (#671)",
        QueryBuildError,
        () -> bulk_insert(DOCERR_CIRCUIT_PG.objects, DataFrames.DataFrame(name = ["Monza"]),
                          returning = ["circuitref"], show_query = :dict),
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
        "schema_conventions.md + postgres.md — rendering an engine-pinned db_default on the other engine raises (#496)",
        BackendCapabilityError,
        () -> PormG.Dialect.field_to_column("uid", UUIDField(db_default = (postgres = "gen_random_uuid()",)),
                                            DocErrMockSQLite()),
    ),
    # #648. `fields.md`, `postgres.md` and `errors.md` all name the type a too-wide DecimalField
    # raises on SQLite. Driven one layer down, at the SQLite renderer every DDL path shares, the way
    # the #496 row above is; the `makemigrations` path it surfaces through is pinned end to end in
    # `test_sqlite_decimal_648.jl`.
    (
        "fields.md + postgres.md + errors.md — a DecimalField wider than 15 digits raises on SQLite (#648)",
        BackendCapabilityError,
        () -> PormG.Dialect.field_to_column("amount", DecimalField(max_digits = 16, decimal_places = 2),
                                            DocErrMockSQLite()),
    ),
    # #761. `fields.md` → DecimalField *Write validation* names the type a value with too many digits
    # before the point raises. Driven through `create`, the public writer; the other writers are
    # pinned in `test_decimal_whole_digits_761.jl`.
    (
        "fields.md — a DecimalField value with more whole digits than max_digits - decimal_places raises (#761)",
        InvalidValueError,
        () -> let m = Model("docerr_invoice_761", id = IDField(),
                            amount = DecimalField(max_digits = 5, decimal_places = 2))
            m.connect_key = "docerr_pg"; m._module = Main
            m.objects.create("amount" => "1000", show_query = :dict)
        end,
    ),
    # #773. `fields.md` → *Numeric Fields* names the type a `0x`/`0b`/`0o` numeric string raises on a
    # write and in a filter. The other writers and field kinds are pinned in `test_numeric_prefix_773.jl`.
    (
        "fields.md — a numeric string with a 0x/0b/0o prefix raises on a write (#773)",
        InvalidValueError,
        () -> let m = Model("docerr_laps_773", id = IDField(), laps = IntegerField())
            m.connect_key = "docerr_pg"; m._module = Main
            m.objects.create("laps" => "0x10", show_query = :dict)
        end,
    ),
    (
        "fields.md — a numeric string with a 0x/0b/0o prefix raises in a filter (#773)",
        FilterError,
        () -> let m = Model("docerr_laps_773f", id = IDField(), laps = IntegerField())
            m.connect_key = "docerr_pg"; m._module = Main
            q = m.objects; q.filter("laps" => "0x10"); q.list(show_query = :dict)
        end,
    ),
    # #860. `fields.md` → *Text Fields* names the type a float or a `Decimal` raises against a text
    # field, on a write and in a filter. Every route and both engines are pinned in
    # `test_text_value_types.jl`.
    (
        "fields.md — a float in a text field raises on a write (#860)",
        InvalidValueError,
        () -> let m = Model("docerr_postext_860", id = IDField(), positiontext = CharField())
            m.connect_key = "docerr_pg"; m._module = Main
            m.objects.create("positiontext" => 1.0, show_query = :dict)
        end,
    ),
    (
        "fields.md — a float compared with a text field raises in a filter (#860)",
        FilterError,
        () -> let m = Model("docerr_postext_860f", id = IDField(), positiontext = CharField())
            m.connect_key = "docerr_pg"; m._module = Main
            q = m.objects; q.filter("positiontext" => 1.0); q.list(show_query = :dict)
        end,
    ),
    # #28. `fields.md` → *Network Address Fields* names the type each refusal raises. The write
    # refusals are driven through `create`, the public writer; every writer is pinned live in
    # `test/integration/test_network_address_fields.jl`, the rest in `test_network_address_fields.jl`.
    (
        "fields.md — a GenericIPAddressField value with a /prefix raises on a write (#28)",
        InvalidValueError,
        () -> let m = Model("docerr_pitwall_28a", id = IDField(), client_ip = GenericIPAddressField())
            m.connect_key = "docerr_pg"; m._module = Main
            m.objects.create("client_ip" => "10.0.0.0/8", show_query = :dict)
        end,
    ),
    (
        "fields.md — a write of the other family raises under protocol = \"IPv4\" (#28)",
        InvalidValueError,
        () -> let m = Model("docerr_pitwall_28b", id = IDField(), relay_ip = GenericIPAddressField(protocol = "IPv4"))
            m.connect_key = "docerr_pg"; m._module = Main
            m.objects.create("relay_ip" => "2001:db8::1", show_query = :dict)
        end,
    ),
    (
        "fields.md — a CIDRField value with host bits set raises on a write (#28)",
        InvalidValueError,
        () -> let m = Model("docerr_pitwall_28c", id = IDField(), garage_lan = CIDRField())
            m.connect_key = "docerr_pg"; m._module = Main
            m.objects.create("garage_lan" => "10.20.0.1/16", show_query = :dict)
        end,
    ),
    (
        "fields.md — unpack_ipv4 with a protocol other than \"both\" raises when the model is defined (#28)",
        FieldValidationError,
        () -> GenericIPAddressField(protocol = "IPv6", unpack_ipv4 = true),
    ),
    (
        "fields.md — an invalid GenericIPAddressField default raises when the model is defined (#28)",
        FieldValidationError,
        () -> GenericIPAddressField(default = "10.1"),
    ),
    (
        "fields.md — a filter value that is not a valid address raises (#28)",
        FilterError,
        () -> let m = Model("docerr_pitwall_28f", id = IDField(), client_ip = GenericIPAddressField())
            m.connect_key = "docerr_pg"; m._module = Main
            q = m.objects; q.filter("client_ip" => "10.1"); q.list(show_query = :dict)
        end,
    ),
    # Driven at the SQLite renderer every DDL path shares, the way the #648 row above is; the
    # `makemigrations` path it surfaces through is pinned live in the integration file.
    (
        "fields.md + postgres.md + src/models/fields.jl — a GenericIPAddressField raises on SQLite when its column is rendered (#28)",
        BackendCapabilityError,
        () -> PormG.Dialect.field_to_column("client_ip", GenericIPAddressField(), DocErrMockSQLite()),
    ),
    (
        "fields.md + postgres.md + src/models/fields.jl — a CIDRField raises on SQLite when its column is rendered (#28)",
        BackendCapabilityError,
        () -> PormG.Dialect.field_to_column("garage_lan", CIDRField(), DocErrMockSQLite()),
    ),
    # #28. `fields.md` → *Array Fields* names the type each ArrayField refusal raises. The write
    # refusals go through `create`; every writer and both drivers are pinned live in
    # `test/integration/test_array_field.jl`, the rest in `test/unit/test_array_field.jl`.
    (
        "fields.md — an element field ArrayField cannot hold raises when the model is defined (#28)",
        FieldValidationError,
        () -> ArrayField(JSONField()),
    ),
    (
        "fields.md — a nested ArrayField raises when the model is defined (#28)",
        FieldValidationError,
        () -> ArrayField(ArrayField(IntegerField())),
    ),
    (
        "fields.md — a column keyword on the element field raises when the model is defined (#28)",
        FieldValidationError,
        () -> ArrayField(IntegerField(unique = true)),
    ),
    (
        "fields.md — a function default raises when the model is defined (#28)",
        FieldValidationError,
        () -> ArrayField(IntegerField(); default = () -> Int[]),
    ),
    (
        "fields.md — an element past the element field's max_length raises on a write (#28)",
        InvalidValueError,
        () -> let m = Model("docerr_strategy_28a", id = IDField(), tyre_compounds = ArrayField(CharField(max_length = 12)))
            m.connect_key = "docerr_pg"; m._module = Main
            m.objects.create("tyre_compounds" => ["INTERMEDIATE!"], show_query = :dict)
        end,
    ),
    (
        "fields.md — a pattern lookup on an ArrayField raises (#28)",
        FilterError,
        () -> let m = Model("docerr_strategy_28b", id = IDField(), tyre_compounds = ArrayField(CharField(max_length = 12)))
            m.connect_key = "docerr_pg"; m._module = Main
            q = m.objects; q.filter("tyre_compounds__@contains" => "SOFT"); q.list(show_query = :dict)
        end,
    ),
    (
        "fields.md — a membership list of whole arrays raises (#28)",
        FilterError,
        () -> let m = Model("docerr_strategy_28c", id = IDField(), pit_laps = ArrayField(IntegerField()))
            m.connect_key = "docerr_pg"; m._module = Main
            q = m.objects; q.filter("pit_laps__@in" => [[12], [12, 30]]); q.list(show_query = :dict)
        end,
    ),
    (
        "fields.md + postgres.md + src/models/fields.jl — an ArrayField raises on SQLite when its column is rendered (#28)",
        BackendCapabilityError,
        () -> PormG.Dialect.field_to_column("pit_laps", ArrayField(IntegerField()), DocErrMockSQLite()),
    ),
    # #28, part 2. `fields.md` → *Containment, overlap and length* and *Index and slice* name the type
    # each array-lookup refusal raises; `filters_and_aggregates.md` → *Array Lookups* and `postgres.md`
    # the SQLite refusal. The SQL each lookup renders is pinned in `test_array_lookups.jl`.
    (
        "fields.md — a single value for an array lookup raises (#28)",
        FilterError,
        () -> let m = Model("docerr_strategy_28d", id = IDField(), tyre_compounds = ArrayField(CharField(max_length = 12)))
            m.connect_key = "docerr_pg"; m._module = Main
            q = m.objects; q.filter("tyre_compounds__@acontains" => "SOFT"); q.list(show_query = :dict)
        end,
    ),
    (
        "fields.md — a NULL element in an array lookup raises (#28)",
        FilterError,
        () -> let m = Model("docerr_strategy_28e", id = IDField(), pit_laps = ArrayField(IntegerField(null = true)))
            m.connect_key = "docerr_pg"; m._module = Main
            q = m.objects; q.filter("pit_laps__@overlap" => [12, missing]); q.list(show_query = :dict)
        end,
    ),
    (
        "fields.md — @len on a column that is not an ArrayField raises (#28)",
        FilterError,
        () -> let m = Model("docerr_strategy_28f", id = IDField(), team = CharField(max_length = 100))
            m.connect_key = "docerr_pg"; m._module = Main
            q = m.objects; q.filter("team__@len" => 2); q.list(show_query = :dict)
        end,
    ),
    (
        "fields.md — another column as an array lookup's value raises (#28)",
        FilterError,
        () -> let m = Model("docerr_strategy_28g", id = IDField(), pit_laps = ArrayField(IntegerField()),
                            stops = ArrayField(IntegerField()))
            m.connect_key = "docerr_pg"; m._module = Main
            q = m.objects; q.filter("pit_laps__@acontains" => PormG.F("stops")); q.list(show_query = :dict)
        end,
    ),
    (
        "fields.md — a second segment after an array index raises (#28)",
        QueryBuildError,
        () -> let m = Model("docerr_strategy_28h", id = IDField(), pit_laps = ArrayField(IntegerField()))
            m.connect_key = "docerr_pg"; m._module = Main
            q = m.objects; q.filter("pit_laps__0__1" => 12); q.list(show_query = :dict)
        end,
    ),
    (
        "fields.md — an array path segment that is not an index or a slice raises (#28)",
        QueryBuildError,
        () -> let m = Model("docerr_strategy_28i", id = IDField(), pit_laps = ArrayField(IntegerField()))
            m.connect_key = "docerr_pg"; m._module = Main
            q = m.objects; q.filter("pit_laps__first" => 12); q.list(show_query = :dict)
        end,
    ),
    (
        "fields.md — an empty array slice raises (#28)",
        QueryBuildError,
        () -> let m = Model("docerr_strategy_28j", id = IDField(), pit_laps = ArrayField(IntegerField()))
            m.connect_key = "docerr_pg"; m._module = Main
            q = m.objects; q.filter("pit_laps__2_2" => [12]); q.list(show_query = :dict)
        end,
    ),
    (
        "fields.md — a reversed array slice raises (#28)",
        QueryBuildError,
        () -> let m = Model("docerr_strategy_28k", id = IDField(), pit_laps = ArrayField(IntegerField()))
            m.connect_key = "docerr_pg"; m._module = Main
            q = m.objects; q.filter("pit_laps__2_1" => [12]); q.list(show_query = :dict)
        end,
    ),
    (
        "filters_and_aggregates.md + postgres.md — an array containment lookup raises on SQLite (#28)",
        BackendCapabilityError,
        () -> let m = Model("docerr_strategy_28l", id = IDField(), tyre_compounds = ArrayField(CharField(max_length = 12)))
            m.connect_key = "docerr_sl"; m._module = Main
            q = m.objects; q.filter("tyre_compounds__@acontains" => ["SOFT"]); q.list(show_query = :dict)
        end,
    ),
    (
        "filters_and_aggregates.md + postgres.md — @len raises on SQLite (#28)",
        BackendCapabilityError,
        () -> let m = Model("docerr_strategy_28m", id = IDField(), pit_laps = ArrayField(IntegerField()))
            m.connect_key = "docerr_sl"; m._module = Main
            q = m.objects; q.filter("pit_laps__@len__@gte" => 2); q.list(show_query = :dict)
        end,
    ),
    (
        "filters_and_aggregates.md + postgres.md — an array index raises on SQLite (#28)",
        BackendCapabilityError,
        () -> let m = Model("docerr_strategy_28n", id = IDField(), tyre_compounds = ArrayField(CharField(max_length = 12)))
            m.connect_key = "docerr_sl"; m._module = Main
            q = m.objects; q.filter("tyre_compounds__0" => "SOFT"); q.list(show_query = :dict)
        end,
    ),
    # #902. `fields.md` → *UUID Fields* names the type a malformed UUID raises in an equality filter —
    # the half of the paragraph the pattern lookups (which take a fragment) do not change. The
    # rendering is pinned in `test_uuid_pattern_lookups.jl`.
    (
        "fields.md — a malformed UUID in an equality filter raises (#902)",
        FilterError,
        () -> let m = Model("docerr_token_902", id = IDField(), token = UUIDField())
            m.connect_key = "docerr_pg"; m._module = Main
            q = m.objects; q.filter("token" => "550e"); q.list(show_query = :dict)
        end,
    ),
    # #903. `fields.md` → *Querying network fields* and the `Value` docstring name the type a
    # `Sockets` literal raises on SQLite, which has no network type. The PostgreSQL bind is pinned in
    # `test_network_address_fields.jl`.
    (
        "fields.md + src/querybuilder/functions.jl — Value(ip\"…\") raises on SQLite (#903)",
        InvalidValueError,
        () -> let q = DOCERR_STATUS_SL.objects
            q.values("statusid", "probe" => Value(Sockets.IPv4("10.0.0.1"))); q.list(show_query = :dict)
        end,
    ),
    # #876. The same *Text Fields* section names the types a `Bool` raises against a text field: on a
    # write, in a filter, and as a `default=`. Every route and both engines are pinned in
    # `test_text_value_types.jl`.
    (
        "fields.md — a Bool in a text field raises on a write (#876)",
        InvalidValueError,
        () -> let m = Model("docerr_postext_876", id = IDField(), positiontext = CharField())
            m.connect_key = "docerr_pg"; m._module = Main
            m.objects.create("positiontext" => true, show_query = :dict)
        end,
    ),
    (
        "fields.md — a Bool compared with a text field raises in a filter (#876)",
        FilterError,
        () -> let m = Model("docerr_postext_876f", id = IDField(), positiontext = CharField())
            m.connect_key = "docerr_pg"; m._module = Main
            q = m.objects; q.filter("positiontext" => true); q.list(show_query = :dict)
        end,
    ),
    (
        "fields.md — a text field's default = true raises (#876)",
        FieldValidationError,
        () -> CharField(default = true),
    ),
    # #868. The same *Text Fields* section says `max_length` counts the text an integer is written
    # as. Every writer, value type and both engines are pinned in `test_text_value_types.jl`.
    (
        "fields.md — an integer longer than a text field's max_length raises on a write (#868)",
        InvalidValueError,
        () -> let m = Model("docerr_code_868", id = IDField(), code = CharField(max_length = 3))
            m.connect_key = "docerr_pg"; m._module = Main
            m.objects.create("code" => 12345, show_query = :dict)
        end,
    ),
    # #780. The same *Numeric Fields* paragraph names the type a declaration raises: a prefixed string
    # `default=`, a prefixed string width, and a non-finite string float default. Every constructor
    # and width keyword is pinned in `test_numeric_prefix_773.jl`.
    (
        "fields.md — a numeric field default= with a 0x/0b/0o prefix raises (#780)",
        FieldValidationError,
        () -> IntegerField(default = "0x10"),
    ),
    (
        "fields.md — a string width with a 0x/0b/0o prefix raises (#780)",
        FieldValidationError,
        () -> CharField(max_length = "0x10"),
    ),
    (
        "fields.md — a non-finite string FloatField default raises (#780)",
        FieldValidationError,
        () -> FloatField(default = "Inf"),
    ),
    # #751. `fields.md` → *BinaryField* and the constructor docstring name the type a byte bound
    # above 1 GiB raises; the boundary itself is pinned in `test_binary_field_bytes.jl`.
    (
        "fields.md + src/models/fields.jl — BinaryField docstring: a max_length above 1 GiB raises (#751)",
        FieldValidationError,
        () -> PormG.Models.BinaryField(max_length = 1_073_741_825),
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
    # #798. Three pages say an expression mixing a plain column with an aggregate raises unless the
    # query groups that column — the shape PostgreSQL rejected with `GroupingError` and SQLite
    # answered from an arbitrary row of each group. The window page states it for an OVER term, the
    # aggregates and field-expressions pages for a projection.
    (
        "read/window_functions.md — a window term mixing a column and an aggregate is refused (#798)",
        QueryBuildError,
        () -> begin
            q = DOCERR_RESULT_PG.objects
            q.values("driverid", "rk" => Rank(over = WindowOver(
                partition_by = [F("resultid") + PormG.Functions.Sum("points")], order_by = ["driverid"])))
            q.list(show_query = :dict)
        end,
    ),
    (
        "read/filters_and_aggregates.md + read/field_expressions.md — a projection mixing a column and an aggregate is refused (#798)",
        QueryBuildError,
        () -> begin
            q = DOCERR_RESULT_PG.objects
            q.values("driverid", "x" => F("resultid") - PormG.Functions.Avg("points"))
            q.list(show_query = :dict)
        end,
    ),
    # #809. The window page (and its Current Limitations bullet) says a window's PLAIN argument beside
    # an aggregate raises unless the query groups it — `Lag("raceid__round")` next to `Sum("points")`.
    (
        "read/window_functions.md + read/filters_and_aggregates.md — a plain window argument beside an aggregate is refused (#809)",
        QueryBuildError,
        () -> begin
            q = DOCERR_RESULT_PG.objects
            q.values("driverid", "t" => PormG.Functions.Sum("points"),
                     "prev" => PormG.Functions.Lag("resultid", over = WindowOver(order_by = ["driverid"])))
            q.list(show_query = :dict)
        end,
    ),
    # #801/#814/#881. The date-arithmetic section states these refusals: what a SQLite interval has no
    # millisecond form for, or no PostgreSQL operator either (#881 — ordering, arithmetic and interval
    # shifts render there since #881, so #814's rows for them are gone), a duration against something
    # that is not an interval (#814), and `+`/`*`/`/` between two temporal values (#801).
    (
        "read/field_expressions.md — a month added to a timestamp difference is refused on SQLite (#881)",
        QueryBuildError,
        () -> begin
            q = DOCERR_RACE801_SL.objects
            q.values("x" => (F("start_at") - F("date")) + PormG.Dates.Month(1))
            q.list(show_query = :dict)
        end,
    ),
    (
        "read/field_expressions.md — d * d is refused on SQLite (#881)",
        QueryBuildError,
        () -> begin
            q = DOCERR_RACE801_SL.objects
            q.values("x" => (F("start_at") - F("date")) * (F("start_at") - F("date")))
            q.list(show_query = :dict)
        end,
    ),
    (
        "read/field_expressions.md — a window function side of a timestamp difference is refused on SQLite (#814)",
        QueryBuildError,
        () -> begin
            q = DOCERR_RACE801_SL.objects
            q.values("x" => F("start_at") - PormG.Functions.Lag("start_at", over = WindowOver(order_by = ["raceid"])))
            q.list(show_query = :dict)
        end,
    ),
    (
        "read/field_expressions.md — a duration compares only against an interval (#814)",
        QueryBuildError,
        () -> begin
            q = DOCERR_RACE801_SL.objects
            q.filter(F("date") > PormG.Dates.Hour(1))
            q.list(show_query = :dict)
        end,
    ),
    (
        "read/field_expressions.md — a string on the right of date arithmetic is refused (#814)",
        QueryBuildError,
        () -> begin
            q = DOCERR_RACE801_SL.objects
            q.values("x" => F("date") - "2009-03-29")
            q.list(show_query = :dict)
        end,
    ),
    (
        "read/field_expressions.md — a date literal subtracted from a non-date is refused (#814)",
        QueryBuildError,
        () -> begin
            q = DOCERR_RACE801_SL.objects
            q.values("x" => F("raceid") - PormG.Dates.Date(2009, 3, 29))
            q.list(show_query = :dict)
        end,
    ),
    (
        "read/field_expressions.md — a day count minus a date is refused (#814)",
        QueryBuildError,
        () -> begin
            q = DOCERR_RACE801_SL.objects
            q.values("x" => (F("date") - F("date")) - F("date"))
            q.list(show_query = :dict)
        end,
    ),
    (
        "read/field_expressions.md — a number plus an interval is refused on SQLite (#881)",
        QueryBuildError,
        () -> begin
            q = DOCERR_RACE801_SL.objects
            q.values("x" => (F("start_at") - F("date")) + 5)
            q.list(show_query = :dict)
        end,
    ),
    (
        "read/field_expressions.md — `+` between two dates is refused (#801)",
        QueryBuildError,
        () -> begin
            q = DOCERR_RACE801_SL.objects
            q.values("x" => F("date") + F("date"))
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
    # #857 — `root` with an absolute path. Refused before the filesystem is consulted, so no folder
    # needs to exist and `config` is never touched.
    (
        "configuration/setup.md / errors.md — load(path; root) with an absolute path is refused (#857)",
        InvalidConfigurationError,
        () -> PormG.Configuration.load(abspath("docerr_857_db"); root = pwd()),
    ),
    # #683 — a `register_connection` entry has no models folder. The entry is added and removed
    # inside the call so no other case sees a dynamic key in `config`; the refusal fires before
    # the mock connection is ever touched.
    (
        "configuration/dynamic.md / errors.md — migrations on a dynamic connection are refused (#683)",
        InvalidConfigurationError,
        () -> begin
            PormG.config["docerr_dynamic"] = PormG.Configuration.Settings(
                connections = DocErrMockPostgres(), dynamic = true, db_def_folder = "dynamic_connection")
            try
                PormG.Migrations.dry_run("docerr_dynamic")
            finally
                delete!(PormG.config, "docerr_dynamic")
            end
        end,
    ),
    # #710: a plan file is parsed, never run. The error fires while the plan loads, before the
    # mock connection is touched; the `$` payload would throw an UndefVarError if it were evaluated.
    (
        "migrations/stability.md — a plan file with `\$` interpolation raises InvalidMigrationError (#710)",
        InvalidMigrationError,
        () -> mktempdir() do dir
            mkpath(joinpath(dir, "migrations"))
            write(joinpath(dir, "migrations", "pending_migrations.jl"),
                  "module pending_migrations\nt = OrderedDict(\"Drop\" => \"DROP INDEX \\\"ix\$(docerr_undefined_710)\\\";\")\nend\n")
            st = PormG.Configuration.Settings(change_data = true)
            st.db_def_folder = dir
            PormG.Migrations.dry_run(DocErrMockPostgres(), st)
        end,
    ),
    # #733: a label repeated within one table's dict. Before #733 the reader kept the last SQL and
    # the first statement vanished; now the plan is refused while it loads, as #710's case is.
    (
        "migrations/stability.md — a plan file repeating a label within one entry raises InvalidMigrationError (#733)",
        InvalidMigrationError,
        () -> mktempdir() do dir
            mkpath(joinpath(dir, "migrations"))
            write(joinpath(dir, "migrations", "pending_migrations.jl"),
                  "module pending_migrations\nt = OrderedDict(\"Drop\" => \"SELECT 1;\", \"Drop\" => \"SELECT 2;\")\nend\n")
            st = PormG.Configuration.Settings(change_data = true)
            st.db_def_folder = dir
            PormG.Migrations.dry_run(DocErrMockPostgres(), st)
        end,
    ),
    # #733: the two repair ops that change an existing record. The only case here that needs a
    # database, because the lookup reads the history table; an in-memory SQLite one is enough.
    (
        "migrations/advanced.md — mark_failed on a version with no record raises InvalidMigrationError (#733)",
        InvalidMigrationError,
        () -> begin
            pool = PormG.ConnectionPool.SQLiteConnectionPool(":memory:"; pool_size = 1)
            st = PormG.Configuration.Settings(connections = pool, change_data = true)
            PormG.Migrations.mark_failed(pool, st, "20310101000000999")
        end,
    ),
    (
        "migrations/advanced.md — remove_migration_record on a version with no record raises InvalidMigrationError (#733)",
        InvalidMigrationError,
        () -> begin
            pool = PormG.ConnectionPool.SQLiteConnectionPool(":memory:"; pool_size = 1)
            st = PormG.Configuration.Settings(connections = pool, change_data = true)
            PormG.Migrations.remove_migration_record(pool, st, "20310101000000999")
        end,
    ),
    # #740: a label that looks like a data step and is not one. Refused while the plan is ordered,
    # before the mock connection is touched — it would otherwise land in the catch-all bucket.
    (
        "migrations/advanced.md / stability.md — a `Data (` label that is not `Data (pre):`/`Data (post):` raises InvalidMigrationError (#740)",
        InvalidMigrationError,
        () -> mktempdir() do dir
            mkpath(joinpath(dir, "migrations"))
            write(joinpath(dir, "migrations", "pending_migrations.jl"),
                  "module pending_migrations\nt = OrderedDict(\"Data (Pre): fill\" => \"UPDATE t SET a = 1;\")\nend\n")
            st = PormG.Configuration.Settings(change_data = true)
            st.db_def_folder = dir
            PormG.Migrations.dry_run(DocErrMockPostgres(), st)
        end,
    ),
    # #740: makemigrations will not replace a pending plan holding data steps. The models declare a
    # table the empty in-memory database lacks, so the diff is non-empty: the overwrite path.
    (
        "migrations/advanced.md — makemigrations on a pending plan with data steps raises InvalidMigrationError (#740)",
        InvalidMigrationError,
        () -> mktempdir() do dir
            mkpath(joinpath(dir, "migrations"))
            write(joinpath(dir, "migrations", "pending_migrations.jl"),
                  "module pending_migrations\nt = OrderedDict(\"Data (post): fill\" => \"UPDATE t SET a = 1;\")\nend\n")
            models = joinpath(dir, "models.jl")
            write(models, "module models\nimport PormG.Models\nDocErr740 = Models.Model(id = Models.IDField())\nend\n")
            pool = PormG.ConnectionPool.SQLiteConnectionPool(":memory:"; pool_size = 1)
            st = PormG.Configuration.Settings(connections = pool, db_def_folder = dir)
            st.change_db = true
            try
                PormG.Migrations.makemigrations(pool, st; path = models, interactive = false)
            finally
                PormG.ConnectionPool.close_pool!(pool)
            end
        end,
    ),
    # #740: a data step commits on its own, so it refuses to run inside an open transaction.
    (
        "migrations/advanced.md / src/migrations/runner.jl — run_once docstring: run_once inside an open transaction raises TransactionError (#740)",
        TransactionError,
        () -> begin
            pool = PormG.ConnectionPool.SQLiteConnectionPool(":memory:"; pool_size = 1)
            st = PormG.Configuration.Settings(connections = pool)
            st.change_db = true
            try
                PormG.ConnectionPool.run_in_transaction(pool) do
                    PormG.Migrations.run_once(_ -> nothing, pool, st, "docerr_740")
                end
            finally
                PormG.ConnectionPool.close_pool!(pool)
            end
        end,
    ),
    # #726: a rename question with nothing left on stdin. `devnull` is end of input at once — the
    # CI shape the page describes — and the error fires at the question, before any DDL is planned.
    (
        "migrations/workflow.md / src/migrations/planner.jl — makemigrations docstring: a rename question at end of input raises InvalidMigrationError (#726)",
        InvalidMigrationError,
        () -> begin
            live = Model("docerr_result_726", resultid = IDField(), points = IntegerField())
            declared = Model("docerr_race_result_726", resultid = IDField(), points = IntegerField())
            schema = Dict{Symbol, Dict{Symbol, Union{Bool, PormG.PormGModel}}}(
                Symbol(PormG.Models.model_table_name(declared)) =>
                    Dict{Symbol, Union{Bool, PormG.PormGModel}}(:model => declared, :exist => false))
            redirect_stdin(devnull) do
                redirect_stdout(devnull) do
                    PormG.Migrations.get_migration_plan(PormG.PormGModel[live], schema, DocErrMockPostgres(),
                                                        PormG.Configuration.Settings(); interactive = true)
                end
            end
        end,
    ),
    # #734: `interactive = false` refuses a same-definition pair it was given no hint for — the table
    # holds exactly the model's columns — instead of dropping its rows.
    (
        "migrations/workflow.md — Automation & CI/CD: an unhinted same-definition pair under interactive = false raises InvalidMigrationError (#734)",
        InvalidMigrationError,
        () -> begin
            live = Model("docerr_result_734", resultid = IDField(), points = IntegerField())
            declared = Model("docerr_race_result_734", resultid = IDField(), points = IntegerField())
            schema = Dict{Symbol, Dict{Symbol, Union{Bool, PormG.PormGModel}}}(
                Symbol(PormG.Models.model_table_name(declared)) =>
                    Dict{Symbol, Union{Bool, PormG.PormGModel}}(:model => declared, :exist => false))
            PormG.Migrations.get_migration_plan(PormG.PormGModel[live], schema, DocErrMockPostgres(),
                                                PormG.Configuration.Settings(); interactive = false)
        end,
    ),
    # #734: a hint that contradicts the schema — here, a new table no model declares.
    (
        "migrations/workflow.md — Automation & CI/CD: a renames hint that contradicts the schema raises InvalidMigrationError (#734)",
        InvalidMigrationError,
        () -> begin
            live = Model("docerr_result_734", resultid = IDField(), points = IntegerField())
            declared = Model("docerr_race_result_734", resultid = IDField(), points = IntegerField())
            schema = Dict{Symbol, Dict{Symbol, Union{Bool, PormG.PormGModel}}}(
                Symbol(PormG.Models.model_table_name(declared)) =>
                    Dict{Symbol, Union{Bool, PormG.PormGModel}}(:model => declared, :exist => false))
            PormG.Migrations.get_migration_plan(PormG.PormGModel[live], schema, DocErrMockPostgres(),
                                                PormG.Configuration.Settings(); interactive = false,
                                                renames = ["docerr_result_734" => "docerr_undeclared_734"])
        end,
    ),
    # #741: a managed model's constrained key into an unmanaged one. Two raise sites, because
    # `makemigrations` loads models without registering them.
    (
        "models.md — Unmanaged models: a constrained key into an unmanaged model raises ModelDefinitionError at set_models (#741)",
        ModelDefinitionError,
        () -> begin
            view = Model("docerr_points_v_741"; managed = false, id = IDField(), points = IntegerField())
            award = Model("docerr_award_741"; id = IDField(), standing = ForeignKey(view, pk_field = "id"))
            mod = Module(:DocErrManaged741)
            Core.eval(mod, :(import PormG))
            Core.eval(mod, :(Points = $view))
            Core.eval(mod, :(Award = $award))
            # `set_models` resolves its key through `db_def_folder`, which `docerr_pg` does not set.
            # `invokelatest`: this closure runs in the world the case list was built in, where the two
            # bindings `Core.eval` just made do not exist yet, and `set_models` would see no models.
            PormG.config["docerr_managed_741"] = PormG.Configuration.Settings(
                connections = DocErrMockPostgres(), change_data = true, db_def_folder = "docerr_managed_741")
            try
                Base.invokelatest(PormG.Models.set_models, mod, "docerr_managed_741")
            finally
                delete!(PormG.config, "docerr_managed_741")
            end
        end,
    ),
    (
        "models.md — Unmanaged models: a constrained key into an unmanaged model raises InvalidMigrationError at makemigrations (#741)",
        InvalidMigrationError,
        () -> begin
            view = Model("docerr_points_v_741"; managed = false, id = IDField(), points = IntegerField())
            award = Model("docerr_award_741"; id = IDField(), standing = ForeignKey(view, pk_field = "id"))
            schema = Dict{Symbol, Dict{Symbol, Union{Bool, PormG.PormGModel}}}(
                Symbol(PormG.Models.model_table_name(m)) => Dict{Symbol, Union{Bool, PormG.PormGModel}}(:model => m, :exist => false)
                for m in (view, award))
            PormG.Migrations.get_migration_plan(PormG.Migrations.LiveTable[], schema, DocErrMockPostgres(),
                                                PormG.Configuration.Settings(); interactive = false)
        end,
    ),
    # #742: the CheckConstraint docstring's constructor and model-time rejections.
    (
        "src/Models.jl — CheckConstraint docstring: a missing name is rejected in the constructor (#742)",
        ModelDefinitionError,
        () -> PormG.Models.CheckConstraint(condition = "grid >= 0"),
    ),
    (
        "src/Models.jl — CheckConstraint docstring: a name over 63 bytes is rejected (#742)",
        ModelDefinitionError,
        () -> PormG.Models.CheckConstraint(condition = "grid >= 0", name = "x"^64),
    ),
    (
        "src/Models.jl + models.md — CheckConstraint: a condition with a comment or a top-level `;` is rejected (#742)",
        ModelDefinitionError,
        () -> PormG.Models.CheckConstraint(condition = "grid >= 0; DROP TABLE result", name = "result_grid"),
    ),
    (
        "src/Models.jl + models.md — CheckConstraint: two constraints sharing a name on one model are rejected (#742)",
        ModelDefinitionError,
        () -> Model("docerr_check_dup_742"; id = IDField(), grid = IntegerField(),
                    constraints = [UniqueConstraint(fields = ("grid",), name = "grid_rule"),
                                   PormG.Models.CheckConstraint(condition = "grid >= 0", name = "grid_rule")]),
    ),
    (
        "models.md — Check Constraints: a name another constraint on the table holds is refused by makemigrations (#742)",
        InvalidMigrationError,
        () -> begin
            m = Model("docerr_check_clash_742"; id = IDField(), grid = PormG.Models.PositiveIntegerField(),
                      constraints = [PormG.Models.CheckConstraint(condition = "grid <= 40",
                                                                  name = "docerr_check_clash_742_grid_check")])
            schema = Dict{Symbol, Dict{Symbol, Union{Bool, PormG.PormGModel}}}(
                :docerr_check_clash_742 => Dict{Symbol, Union{Bool, PormG.PormGModel}}(:model => m, :exist => false))
            PormG.Migrations.get_migration_plan(PormG.Migrations.LiveTable[], schema, DocErrMockPostgres(),
                                                PormG.Configuration.Settings(); interactive = false)
        end,
    ),
    (
        "models.md — Check Constraints: renaming a column a declared condition still names raises InvalidMigrationError (#742)",
        InvalidMigrationError,
        () -> begin
            check = PormG.Models.CheckConstraint(condition = "laps >= 0", name = "docerr_laps_742")
            live = Model("docerr_stale_742"; id = IDField(), laps = IntegerField(), constraints = [check])
            declared = Model("docerr_stale_742"; id = IDField(), laps_done = IntegerField(), constraints = [check])
            schema = Dict{Symbol, Dict{Symbol, Union{Bool, PormG.PormGModel}}}(
                :docerr_stale_742 => Dict{Symbol, Union{Bool, PormG.PormGModel}}(:model => declared, :exist => false))
            path, io = mktemp(); write(io, "1\n"); close(io)
            open(path) do f
                redirect_stdin(f) do
                    redirect_stdout(devnull) do
                        PormG.Migrations.get_migration_plan(PormG.PormGModel[live], schema, DocErrCatalogFreePg742(),
                                                            PormG.Configuration.Settings(); interactive = true)
                    end
                end
            end
        end,
    ),
    # #749: the per-connection `ignore_tables:` list. A blank entry is refused as it is read, and a
    # managed model on a listed table is refused as the plan is built — before any live read.
    (
        "configuration/connection_yml.md — Tables PormG leaves alone: a blank ignore_tables entry raises InvalidConfigurationError (#749)",
        InvalidConfigurationError,
        () -> PormG.Configuration._configured_ignore_tables(
            PormG.Configuration.Settings(db_config_settings = Dict{String,Any}("ignore_tables" => ["legacy_timing_", ""]))),
    ),
    (
        "configuration/connection_yml.md — Tables PormG leaves alone: a managed model on an ignored table raises InvalidConfigurationError (#749)",
        InvalidConfigurationError,
        () -> begin
            m = Model("legacy_timing_laps"; id = IDField(), lap = IntegerField())
            schema = Dict{Symbol, Dict{Symbol, Union{Bool, PormG.PormGModel}}}(
                :legacy_timing_laps => Dict{Symbol, Union{Bool, PormG.PormGModel}}(:model => m, :exist => false))
            st = PormG.Configuration.Settings(db_config_settings = Dict{String,Any}("ignore_tables" => ["legacy_timing_"]))
            PormG.Migrations.get_migration_plan(PormG.Migrations.LiveTable[], schema, DocErrMockPostgres(), st;
                                                interactive = false)
        end,
    ),
    # #805: the same refusal under the backend default and the registry, which have no
    # `ignore_tables:` entry to point at.
    (
        "configuration/connection_yml.md — Tables PormG leaves alone: a managed model on an auth_ table is refused on PostgreSQL with InvalidConfigurationError (#805)",
        InvalidConfigurationError,
        () -> begin
            m = Model("auth_user"; id = IDField())
            schema = Dict{Symbol, Dict{Symbol, Union{Bool, PormG.PormGModel}}}(
                :auth_user => Dict{Symbol, Union{Bool, PormG.PormGModel}}(:model => m, :exist => false))
            PormG.Migrations.get_migration_plan(PormG.Migrations.LiveTable[], schema, DocErrMockPostgres(),
                                                PormG.Configuration.Settings(); interactive = false)
        end,
    ),
    (
        "extending.md — register_ignore_tables!: a managed model on a registered table raises InvalidConfigurationError (#805)",
        InvalidConfigurationError,
        () -> begin
            saved = copy(PormG._EXTRA_IGNORE_TABLES[])
            try
                PormG._EXTRA_IGNORE_TABLES[] = ["legacy_timing_"]
                m = Model("legacy_timing_laps"; id = IDField())
                schema = Dict{Symbol, Dict{Symbol, Union{Bool, PormG.PormGModel}}}(
                    :legacy_timing_laps => Dict{Symbol, Union{Bool, PormG.PormGModel}}(:model => m, :exist => false))
                PormG.Migrations.get_migration_plan(PormG.Migrations.LiveTable[], schema, DocErrMockPostgres(),
                                                    PormG.Configuration.Settings(); interactive = false)
            finally
                PormG._EXTRA_IGNORE_TABLES[] = saved
            end
        end,
    ),
    # #818: `unignore_defaults:` takes only exact built-in entries, checked when the file loads; and
    # SQLite's built-in list has no removable entry at all.
    (
        "configuration/connection_yml.md — Switching a built-in entry off: an entry that is not a built-in entry raises InvalidConfigurationError (#818)",
        InvalidConfigurationError,
        () -> PormG.Configuration._configured_unignore_defaults(
            PormG.Configuration.Settings(db_config_settings = Dict{String,Any}("unignore_defaults" => ["account_profile"])),
            PormG.postgres_ignore_table),
    ),
    (
        "configuration/connection_yml.md — Switching a built-in entry off: any entry on SQLite raises InvalidConfigurationError (#818)",
        InvalidConfigurationError,
        () -> PormG.Configuration._configured_unignore_defaults(
            PormG.Configuration.Settings(db_config_settings = Dict{String,Any}("unignore_defaults" => ["sqlite_sequence"])),
            PormG.sqlite_ignore_schema),
    ),
    # #951 — the NUL refusal row of `errors.md` and the raw-hatch paragraph of `async.md`. Each
    # fires before the driver, which is what lets a mock stand in: a write at its format step, a
    # filter and a raw value at the execution funnel.
    (
        "errors.md — a write value containing a NUL character raises InvalidValueError (#951)",
        InvalidValueError,
        () -> DOCERR_DRIVER_PG.objects.create("surname" => "Senna\0", "nationality" => "Brazilian"),
    ),
    (
        "errors.md — a filter value containing a NUL character raises InvalidValueError (#951)",
        InvalidValueError,
        () -> DOCERR_DRIVER_SL.objects.filter("surname" => "Senna\0").list(),
    ),
    (
        "async.md + errors.md — a raw manual-params value containing a NUL character raises InvalidValueError (#951)",
        InvalidValueError,
        () -> PormG.ConnectionPool.fetch(DocErrMockPostgres(), "SELECT \$1::text", ["Senna\0"]),
    ),
    # #954 — the JSONField row of `errors.md`. The refusal lives in the JSON formatter every write,
    # document filter and `get_or_create` lookup passes, so the formatter is the documented claim.
    (
        "errors.md + fields.md — a JSONField value containing a NUL character raises InvalidValueError (#954)",
        InvalidValueError,
        () -> PormG.Models.format_json_sql(Dict("pit_note" => "box\0box")),
    ),
    (
        "read/filters_and_aggregates.md — `Sum`/`Avg` over a boolean raise QueryBuildError on both engines (#953)",
        QueryBuildError,
        () -> DOCERR_ENTRY953_SL.objects.values("raceid", "n" => Sum("is_rookie")).list(show_query = :dict),
    ),
    (
        "src/querybuilder/functions.jl — Sum docstring: a `Sum` over a `BooleanField` is refused (#953)",
        QueryBuildError,
        () -> DOCERR_ENTRY953_PG.objects.values("raceid", "n" => Sum("is_rookie")).list(show_query = :dict),
    ),
    (
        "src/querybuilder/functions.jl — Avg docstring: an `Avg` over a `BooleanField` is refused (#953)",
        QueryBuildError,
        () -> DOCERR_ENTRY953_PG.objects.values("raceid", "n" => Avg("is_rookie")).list(show_query = :dict),
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
