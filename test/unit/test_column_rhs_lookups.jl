"""
A column expression on the right of a filter lookup whose value is not a column (#811, #793).

A **column expression** — `F(…)`, `Joined(…)`, `CTE(…)`, a function, `Case` — on the right of a
lookup is handled by arms written for a column-to-column comparison. That is right for `=`, `>`,
`<`, …, and #635 made it right for the verbatim pattern lookups (`@regex`, `@iunaccent_exact`). It is
wrong for every lookup whose right-hand side is a *value of a fixed shape*, and each one failed
differently:

  1. **A JSON path equality bound the expression's Julia `repr`.** `"payload__kind" => F("grid")` sent
     `"PormG.QueryBuilder.FExpression(\"grid\", …)"` to PostgreSQL as text: valid SQL, zero rows, no
     error. SQLite refused the same value as an unbindable parameter, so the engines disagreed.
  2. **`@in` / `@nin` rendered `IN "Tb"."grid"`** — invalid SQL on both engines, found by the server.
  3. **`When("points__@gt" => F("grid"))` was a `MethodError`**: that `When` method skipped
     `_check_filter`, the only route to the column-expression arms. `Q(...)` around the same pair worked.

The approved decision for 1 and 2 is **refuse, at the call, on both engines** — a `FilterError` naming
the lookup — rather than invent a rendering (see #811 → *Decide*). 3 is a missing route, fixed by
taking it, so the pair renders.

Pinned here on mock PostgreSQL and SQLite connections (no live database):

julia --project=test/integration test/unit/test_column_rhs_lookups.jl
"""

using Test
using PormG
using PormG.Models
using PormG.QueryBuilder: inspect_query, F
using PormG.Functions: Case, When, Lower
using PormG: Joined, Q

# Dedicated config key + mock types: `runtests.jl` includes every unit file into one `Main`, so a
# shared key would let another file's settings decide this file's dialect.
struct CrlMockSQLite <: PormG.PormGSQLite end
struct CrlMockPostgres <: PormG.PormGPostgres end
const _CRL_SL = CrlMockSQLite()
const _CRL_PG = CrlMockPostgres()
PormG.backend_sqlite_version(::CrlMockSQLite) = 3045000

PormG.config["crl_mock"] = PormG.Configuration.Settings(
  connections = _CRL_SL, change_data = true, db_def_folder = "crl_mock",
)

# A result row with the F1 columns the issues' examples read, a driver to join as a `Joined` copy,
# a text column for the pattern lookups, and a JSON column for the JSON-path arm.
module CrlModels
import PormG
import PormG.Models

Crl_driver = Models.Model("crl_driver",
  id       = Models.IDField(),
  surname  = Models.CharField(),
  forename = Models.CharField(),
  points   = Models.IntegerField(null = true),
)

Crl_result = Models.Model("crl_result",
  id            = Models.IDField(),
  driver        = Models.ForeignKey(Crl_driver, on_delete = "CASCADE", related_name = "crl_results", null = true),
  points        = Models.IntegerField(null = true),
  grid          = Models.IntegerField(null = true),
  positionorder = Models.IntegerField(null = true),
  payload       = Models.JSONField(null = true),
)

PormG.Models.set_models(@__MODULE__, "crl_mock")
end

const CRL = CrlModels
const _CRL_BACKENDS = (("PostgreSQL", _CRL_PG), ("SQLite", _CRL_SL))

_crl_inspect(q, conn) = inspect_query(q; connection = conn)
# The SQL on one line, and without PostgreSQL's `::type` bind casts, so one needle serves both engines.
_crl_sql(q, conn) = replace(replace(_crl_inspect(q, conn)[:sql_text], r"\s+" => " "), r"::\w+" => "")
_crl_params(q, conn) = _crl_inspect(q, conn)[:parameters]

# Build AND render, returning the exception or `nothing`. The JSON-path refusal can only happen at
# render time — whether a path is JSON is not known until the column resolves — so a test that stopped
# after `filter(...)` would pass against the unpatched code.
function _crl_err(build, conn)
  try
    _crl_inspect(build(), conn)
    nothing
  catch e
    e
  end
end
# The message of whatever `_crl_err` returned — `""` when it rendered, so a message assertion fails
# rather than errors against the unpatched code.
_crl_msg(err) = err isa PormG.PormGError ? PormG.error_message(err) : err === nothing ? "" : sprint(showerror, err)

_crl_results() = CRL.Crl_result.objects
_crl_drivers() = CRL.Crl_driver.objects
function _crl_joined_results()
  q = CRL.Crl_result.objects
  q.cjoin_on("Crl_driver", alias = "d", on = [Joined("d", "id") == F("driver")])
  q
end

# Every column-expression spelling a right-hand side can take, each with the query that can resolve
# it. `CTE("c", …)` is never resolved: the refusals below are parse-time, so no `with(...)` is needed —
# and if one of them regressed to render time, the unresolved CTE would fail with a DIFFERENT error
# type, which the `isa FilterError` assertion catches.
const _CRL_RESULT_RHS = (
  ("F",        _crl_results,        () -> F("grid")),
  ("function", _crl_results,        () -> Lower("grid")),
  ("Case",     _crl_results,        () -> Case([When("grid" => 1, then = 1)], default = 0)),
  ("Joined",   _crl_joined_results, () -> Joined("d", "points")),
  ("CTE",      _crl_results,        () -> PormG.CTE("c", "x")),
)

# ─────────────────────────────────────────────────────────────────────────────
# #811.1: a JSON path equality refuses a column expression instead of binding its repr
# `_render_json_lookup_comparison` bound `string(v.values)` on PostgreSQL whatever `v.values` was, so
# `"payload__kind" => F("grid")` compared the extracted text against the expression's Julia `repr` and
# silently matched nothing. It now raises a FilterError on both engines, and PostgreSQL binds nothing.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#811: a JSON path equality refuses a column expression" begin
  for (backend, conn) in _CRL_BACKENDS
    @testset "$backend" begin
      # `=` is the bare path; `@ne` is the `!=` arm the same branch served.
      for key in ("payload__kind", "payload__kind__@ne"), (label, query, rhs) in _CRL_RESULT_RHS
        label == "CTE" && continue   # parse-time CTE resolution is not the arm under test here
        @testset "$key => $label" begin
          err = _crl_err(() -> (q = query(); q.filter(key => rhs()); q), conn)
          @test err isa PormG.FilterError
          # The message names the path the user wrote and says what the lookup compares against.
          @test occursin("payload__kind", _crl_msg(err))
          @test occursin("column expression", _crl_msg(err))
        end
      end

      # The numeric arm already refused; it must keep refusing, now through the same guard.
      err = _crl_err(() -> (q = _crl_results(); q.filter("payload__kind__@gt" => F("grid")); q), conn)
      @test err isa PormG.FilterError

      # The value forms are unchanged: the text/native value still binds, one parameter.
      q = _crl_results()
      q.filter("payload__kind" => "pole")
      @test occursin("payload", _crl_sql(q, conn))
      @test _crl_params(q, conn) == ["pole"]
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# #811.2 / #793: @in / @nin refuse a column expression at the call
# A single column is not a list, so `"points__@in" => F("grid")` rendered `IN "Tb"."grid"` — invalid SQL
# the server rejected. Every column-expression arm now refuses it at parse time with a FilterError that
# names the lookup and the two shapes it takes. Lists and subqueries still render.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#811: @in / @nin refuse a column expression" begin
  for (backend, conn) in _CRL_BACKENDS
    @testset "$backend" begin
      for op in ("in", "nin"), (label, query, rhs) in _CRL_RESULT_RHS
        @testset "@$op => $label" begin
          err = _crl_err(() -> (q = query(); q.filter("points__@$op" => rhs()); q), conn)
          @test err isa PormG.FilterError
          msg = _crl_msg(err)
          @test occursin("points__@$op", msg)
          @test occursin("list of values or a subquery", msg)
        end
      end

      # The same refusal through `Q(...)`: one parse arm serves every spelling.
      err = _crl_err(() -> (q = _crl_results(); q.filter(Q("points__@in" => F("grid"))); q), conn)
      @test err isa PormG.FilterError

      # A list and a subquery are still what `@in` takes.
      q = _crl_results()
      q.filter("points__@in" => [1, 2])
      @test _crl_err(() -> q, conn) === nothing
      q = _crl_results()
      q.filter("driver__@in" => _crl_drivers().filter("surname" => "Senna").values("id"))
      @test occursin(" IN (SELECT", _crl_sql(q, conn))
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# #811.3: When("<path>__@<op>" => column) takes the column-expression arms
# `When(::Pair{String})` called `_get_pair_to_oper` on the raw pair, which has no method for a string
# key with an expression value — a MethodError naming an internal function. It now goes through
# `_check_filter`, as the CTE and Joined `When` methods already did, so the branch renders as a column
# comparison and the refusals above reach `When` too.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#811: When with a column-expression pair renders" begin
  for (backend, conn) in _CRL_BACKENDS
    @testset "$backend" begin
      q = _crl_results()
      q.values("id", "gained" => When("points__@gt" => F("grid"), then = 1, otherwise = 0))
      sql = _crl_sql(q, conn)
      # The condition compares two columns: no placeholder on its right-hand side.
      @test occursin("CASE WHEN \"Tb\".\"points\" > \"Tb\".\"grid\" THEN", sql)

      # The bare path (no operator) is an equality between the columns.
      q = _crl_results()
      q.values("id", "same" => When("points" => F("grid"), then = 1, otherwise = 0))
      @test occursin("CASE WHEN \"Tb\".\"points\" = \"Tb\".\"grid\" THEN", _crl_sql(q, conn))

      # The route is shared, so the #811 refusal reaches `When` as well.
      err = _crl_err(() -> (q = _crl_results();
                            q.values("id", "x" => When("points__@in" => F("grid"), then = 1)); q), conn)
      @test err isa PormG.FilterError

      # A value pair binds exactly as before: the condition's 10, then `then`, then `otherwise`.
      q = _crl_results()
      q.values("id", "big" => When("points__@gt" => 10, then = 1, otherwise = 0))
      @test _crl_params(q, conn) == [10, 1, 0]
    end
  end
end

# The column-expression spellings against the driver's text columns, for the pattern lookups.
_crl_joined_drivers() = (q = CRL.Crl_driver.objects;
                         q.cjoin_on("Crl_driver", alias = "d2", on = [Joined("d2", "id") == F("id")]); q)
const _CRL_DRIVER_RHS = (
  ("F",        _crl_drivers,        () -> F("forename")),
  ("function", _crl_drivers,        () -> Lower("forename")),
  ("Joined",   _crl_joined_drivers, () -> Joined("d2", "forename")),
  ("CTE",      _crl_drivers,        () -> PormG.CTE("c", "x")),
)

# ─────────────────────────────────────────────────────────────────────────────
# #793: the LIKE-family lookups refuse a column expression by name
# A LIKE lookup's value is a text fragment that gets `%` decoration and LIKE escaping, neither of which
# can happen to a column. So `"surname__@contains" => F("forename")` concatenated the lookup NAME into
# the SQL (`"surname" contains "forename"`), and `iunaccent_contains` skipped its SQLite capability
# error. Every `LIKE_WILDCARD_OPERATORS` lookup now raises a FilterError at the call, on both engines.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#793: LIKE-family lookups refuse a column expression" begin
  # The constant, not a hand-written list: a LIKE lookup added later is covered without editing this.
  @test length(PormG.LIKE_WILDCARD_OPERATORS) == 14
  for (backend, conn) in _CRL_BACKENDS
    @testset "$backend" begin
      for op in PormG.LIKE_WILDCARD_OPERATORS, (label, query, rhs) in _CRL_DRIVER_RHS
        @testset "@$op => $label" begin
          err = _crl_err(() -> (q = query(); q.filter("surname__@$op" => rhs()); q), conn)
          @test err isa PormG.FilterError
          msg = _crl_msg(err)
          @test occursin("surname__@$op", msg)
          @test occursin("matches a text value, not a column expression", msg)
        end
      end
    end
  end

  # The value forms render exactly as before: a `%`-wrapped bound fragment.
  q = _crl_drivers()
  q.filter("surname__@contains" => "enn")
  @test _crl_params(q, _CRL_SL) == ["%enn%"]

  # The SQLite capability refusal is still what a VALUE gets. For a column, the shape is refused
  # before the engine is consulted, so both engines report the same FilterError, as asserted above.
  err = _crl_err(() -> (q = _crl_drivers(); q.filter("surname__@iunaccent_contains" => "sena"); q), _CRL_SL)
  @test err isa PormG.BackendCapabilityError
end

# ─────────────────────────────────────────────────────────────────────────────
# #793: the lookups that DO take a column still render
# The refusals above must not reach the comparisons, or the verbatim pattern lookups #635 routed
# through `Dialect` (a column is a valid regex / unaccented-equality operand).
# ─────────────────────────────────────────────────────────────────────────────
@testset "#793: comparisons and verbatim pattern lookups still take a column" begin
  for (backend, conn) in _CRL_BACKENDS
    @testset "$backend" begin
      for (key, sqlop) in (("points", "="), ("points__@gt", ">"), ("points__@lte", "<="), ("points__@ne", "!="))
        q = _crl_results()
        q.filter(key => F("grid"))
        @test occursin("\"Tb\".\"points\" $(sqlop) \"Tb\".\"grid\"", _crl_sql(q, conn))
      end
    end
  end
  q = _crl_drivers()
  q.filter("surname__@regex" => F("forename"))
  @test occursin("\"Tb\".\"surname\" ~ \"Tb\".\"forename\"", _crl_sql(q, _CRL_PG))
  q = _crl_drivers()
  q.filter("surname__@iunaccent_exact" => F("forename"))
  @test occursin("immutable_unaccent(\"Tb\".\"forename\")", _crl_sql(q, _CRL_PG))
end
