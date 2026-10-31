"""
Unit coverage for a `.with(...)` declared INSIDE a subquery (#433, narrowed by #1292).

The contract, per consumer:

  - `Subquery(...)` and `"col__@in" => sub` / `__@nin` BUILD. The nested `WITH` renders inside the
    subquery's parentheses, and its values bind in text order on every engine: `build_cte_clause`
    binds under a scoped `:cte` bucket (#936, #939) and the consumer lifts the subquery's whole run,
    `:cte` first, into the clause its text sits in (#432, `detach_nested_run!`).
  - `Exists(...)` is REFUSED with a `QueryBuildError` naming the CTE. `_build_exists_query`
    hand-rolls its own SELECT rather than routing through `query()`, so it renders no `WITH`: the
    first path resolving `<cte>__col` reached an "internal error … please report it" before #433,
    and would now reach `build_joins.jl`'s "emits no WITH clause" refusal, which is about
    `update()`. That is a missing render step, and the refusal stays until the step exists.

History, because the receipts below are #433's. #433 refused all three consumers on every engine,
after measuring a SQLite misbind on this fixture:

    filter("note" => "WHEREVAL", "parent__@in" => <sub declaring .with("gv" => ...)>)
        PostgreSQL  ["WHEREVAL", "CTEVAL", "INNERVAL"]     <- matches the text
        SQLite      ["CTEVAL", "INNERVAL", "WHEREVAL"]     <- wrong rows, no error

    values("a" => Subquery(plain), "b" => Subquery(<sub with .with>))
        PostgreSQL  ["PLAINVAL", "CTEVAL", "INNERVAL"]
        SQLite      ["CTEVAL", "INNERVAL", "PLAINVAL"]

#1292 re-measured both with the guard removed: every engine now binds the text order. Those two
shapes are pinned here as the regression, beside every position a nested `WITH` can sit in.

What is pinned here (deterministic, DB-free — rendered via `inspect_query` on mock connections):
  - Each built shape on PostgreSQL, SQLite and MySQL: the exact parameter vector in text order, the
    marker count, and the positional engines checked against PostgreSQL's `\$N` read back in text
    order (`_pg_text_order`, the cross-backend differential — a source that is neither the test nor
    the change).
  - `Exists` is refused in the filter AND the projected position, with a message that names the
    missing render and the spellings that do render a nested `WITH`.
  - BOUNDARY: a CTE declared inside a CTE **body** renders, with its values in text order.
  - The mutation-path audits #433 found (`update()` with a CTE reference, `delete()` of a
    CTE-scoped queryset) keep refusing — they are about the OUTER query's `.with()`, not a nested one.
  - CONTROLS: the same consumers with no nested CTE still render unchanged.
  - #566, the other half of "a CTE inside a subquery": a subquery that REFERENCES a CTE only its
    enclosing query declares is refused (#444: each query has its own CTE namespace), in both
    spellings, and the message names that rule. A CTE on the outer query beside a subquery that
    does not reference it is legal. Together these pin every shape the *Rules and limitations*
    list in `docs/src/read/subqueries_and_ctes.md` states.

Sibling coverage:
  - `test_cte_ergonomics.jl` (#44)            -> CROSS-joined CTEs and `F()` correlation.
  - `test_alignment_sqlite.jl`                -> the positional bucket contract these values ride on.
  - `test_parameter_alignment_nested.jl` (#432) -> Rep B, a nested `WITH` inside a `cjoin_on` ON list.
"""
# julia --project=test/integration test/unit/test_nested_cte_guard.jl

using Test
using PormG
using PormG.Models
import Logging

# Mock connections under a dedicated key so this file cannot contaminate (or be contaminated by)
# other unit files sharing Main in runtests.jl. Only the connection TYPE matters — dispatch
# selects SQLite `?` vs PostgreSQL `$N` rendering.
struct NcgMockSQLite <: PormG.PormGSQLite end
struct NcgMockPostgres <: PormG.PormGPostgres end
struct NcgMockMySQL <: PormG.PormGMySQL end
const _NCG_SL = NcgMockSQLite()
const _NCG_PG = NcgMockPostgres()
const _NCG_MY = NcgMockMySQL()
# A mock has no driver to ask: a render that reads the SQLite version raises "requires SQLite" on a
# mock connection without this (the ordered-by-Subquery shape below reaches one).
PormG.backend_sqlite_version(::NcgMockSQLite) = 3045000

PormG.config["ncg_mock"] = PormG.Configuration.Settings(
  connections = _NCG_SL,
  change_data = true,
  db_def_folder = "ncg_mock",
)

# `set_models(@__MODULE__, ...)` is load-bearing, not stylistic: `_build_row_join` reads
# `instruct.object.model._module`, and a bare `Model(...)` leaves it `nothing`, which TypeErrors
# as soon as a join renders.
module NcgModels
import PormG
import PormG.Models

Ncg_grand = Models.Model("ncg_grand",
  id   = Models.IDField(),
  code = Models.CharField(),
)

Ncg_parent = Models.Model("ncg_parent",
  id          = Models.IDField(),
  sku         = Models.CharField(),
  grandparent = Models.ForeignKey(Ncg_grand, on_delete = "CASCADE", related_name = "ncg_pars", null = true),
)

Ncg_child = Models.Model("ncg_child",
  id     = Models.IDField(),
  parent = Models.ForeignKey(Ncg_parent, on_delete = "CASCADE", related_name = "ncg_kids", null = true),
  note   = Models.CharField(null = true),
)

PormG.Models.set_models(@__MODULE__, "ncg_mock")
end

const NCG = NcgModels
import PormG.QueryBuilder: F, Exists, Subquery, Count, Case, When, inspect_query

include("helper_marker_alignment.jl")

const _NCG_BACKENDS = (("PostgreSQL", _NCG_PG), ("SQLite", _NCG_SL))
# The engines that bind by position (`?`), where a nested run out of text order would match the wrong
# rows (#1292). MySQL is in the binding-order checks only; every other testset runs on `_NCG_BACKENDS`.
const _NCG_POSITIONAL = (("SQLite", _NCG_SL), ("MySQL", _NCG_MY))

# A CTE body. Carries its own parameter ("CTEVAL") so bucket order is observable.
_ncg_grand_cte() = begin
  g = NCG.Ncg_grand.objects
  g.filter("code" => "CTEVAL")
  g.values("id", "code")
  g
end

# The shape under test: a subquery that declares AND references its own CTE.
_ncg_inner_with_cte() = begin
  s = NCG.Ncg_parent.objects
  s.with("gv" => _ncg_grand_cte(), join_field = "grandparent" => "id")
  s.filter(CTE("gv", "code") => "INNERVAL")
  s.values("id")
  s
end

# The same subquery with no CTE — the control arm for every refusal below.
_ncg_inner_plain(v = "PLAINVAL") = begin
  s = NCG.Ncg_parent.objects
  s.filter("sku" => v)
  s.values("id")
  s
end

# Build-and-capture. Logging is silenced because the CONTROL arms project a non-aggregate
# `Subquery` and legitimately emit the multi-row @warn, which is not what this file tests.
_ncg_err(build, conn) = Logging.with_logger(Logging.NullLogger()) do
  try
    inspect_query(build(); connection = conn)
    nothing
  catch e
    e
  end
end

_ncg_sql(build, conn) = Logging.with_logger(Logging.NullLogger()) do
  inspect_query(build(); connection = conn)
end

# ─────────────────────────────────────────────────────────────────────────────
# Exists(...) refuses a subquery that declares its own .with(...) (#433, #1292)
# Both positions: the projected form delegates to the filter form, so guarding `_build_exists_query`
# covers both. Without the projected case, a guard placed in `_get_filter_query` instead would pass
# every other assertion in this file.
# ─────────────────────────────────────────────────────────────────────────────
const _NCG_EXISTS_CONSUMERS = [
  ("Exists(...) in a filter", () -> begin
    q = NCG.Ncg_child.objects
    q.values("note")
    q.filter(Exists(_ncg_inner_with_cte()))
    q
  end),
  ("Exists(...) projected in values()", () -> begin
    q = NCG.Ncg_child.objects
    q.values("note", "has_parent" => Exists(_ncg_inner_with_cte()))
    q
  end),
]

@testset "Exists(...) over a subquery declaring its own .with(...) is refused, naming the missing WITH (#433, #1292)" begin
  # Expected: QueryBuildError, no SQL. Why: `_build_exists_query` renders no WITH, so the CTE would
  # never be declared — #433's reported crash. The message names that reason (a missing render step,
  # not a binding order, which #1292 measured correct) and the spellings that do render it.
  for (label, build_q) in _NCG_EXISTS_CONSUMERS
    @testset "$label" begin
      for (backend, conn) in _NCG_BACKENDS
        err = _ncg_err(build_q, conn)
        # Before #433 this was an `ErrorException` ("internal error … please report it").
        @test err isa PormG.QueryBuildError
        msg = sprint(showerror, err)
        @test occursin("Exists(...)", msg)
        # Names the offending CTE by the name the caller gave it.
        @test occursin("gv", msg)
        @test occursin(".with(", msg)
        # The true reason — and never #433's positional-binding one, which #1292 retired.
        @test occursin("is rendered without a", msg)
        @test !occursin("binds parameters by position", msg)
        # The remedies: fold the predicate, or a consumer that renders a nested WITH.
        @test occursin(".filter(", msg)
        @test occursin("__@in\" => subquery", msg) && occursin("Subquery(...)", msg)
        @test !occursin("internal", lowercase(msg))
        @test !occursin("report", lowercase(msg))
        @test !occursin("PostgreSQL", msg) && !occursin("SQLite", msg) && !occursin("MySQL", msg)
      end
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# Subquery(...) and __@in / __@nin build over a subquery declaring its own .with(...) (#1292)
# Every position a nested WITH can sit in, each with the values listed IN TEXT ORDER. Three checks
# per engine, which fail independently: the vector itself (the order a reader of the SQL expects),
# the marker count (#441's half), and — on the positional engines — equality with PostgreSQL's `$N`
# read back in text order (`_pg_text_order`), the cross-backend differential.
#
# G and H are #433's measured misbinds. With the guard removed and the binding unfixed, SQLite bound
# them `["CTEVAL", "INNERVAL", "WHEREVAL"]` / `["CTEVAL", "INNERVAL", "PLAINVAL"]`; these rows are the
# regression for that.
# ─────────────────────────────────────────────────────────────────────────────
const _NCG_BUILT_SHAPES = [
  ("G: a WHERE value, then __@in (#433's misbind)", ["WHEREVAL", "CTEVAL", "INNERVAL"], () -> begin
    q = NCG.Ncg_child.objects
    q.values("note")
    q.filter("note" => "WHEREVAL")
    q.filter("parent__@in" => _ncg_inner_with_cte())
    q
  end),
  ("H: a plain Subquery, then one with a CTE (#433's misbind)", ["PLAINVAL", "CTEVAL", "INNERVAL"], () -> begin
    q = NCG.Ncg_child.objects
    q.values("note",
             "a" => Subquery(_ncg_inner_plain("PLAINVAL")),
             "b" => Subquery(_ncg_inner_with_cte()))
    q
  end),
  ("a WHERE value, then __@nin", ["WHEREVAL", "CTEVAL", "INNERVAL"], () -> begin
    q = NCG.Ncg_child.objects
    q.values("note")
    q.filter("note" => "WHEREVAL", "parent__@nin" => _ncg_inner_with_cte())
    q
  end),
  ("__@in, then a WHERE value", ["CTEVAL", "INNERVAL", "AFTERVAL"], () -> begin
    q = NCG.Ncg_child.objects
    q.values("note")
    q.filter("parent__@in" => _ncg_inner_with_cte())
    q.filter("note" => "AFTERVAL")
    q
  end),
  ("Subquery(...) in a filter", ["WHEREVAL", "CTEVAL", "INNERVAL"], () -> begin
    q = NCG.Ncg_child.objects
    q.values("note")
    q.filter("note" => "WHEREVAL", "parent" => Subquery(_ncg_inner_with_cte()))
    q
  end),
  ("Subquery(...) in HAVING", ["WHEREVAL", "CTEVAL", "INNERVAL"], () -> begin
    q = NCG.Ncg_child.objects
    q.filter("note" => "WHEREVAL")
    q.values("note", "n" => Count("id"))
    q.filter("n__@gt" => Subquery(_ncg_inner_with_cte()))
    q
  end),
  ("__@in inside a When condition", ["CTEVAL", "INNERVAL", 1, 0, "WHEREVAL"], () -> begin
    q = NCG.Ncg_child.objects
    q.filter("note" => "WHEREVAL")
    q.values("note", "flag" => Case(When("parent__@in" => _ncg_inner_with_cte(), then = 1), default = 0))
    q
  end),
  ("a projected Subquery(...) the query orders by", ["CTEVAL", "INNERVAL", "WHEREVAL"], () -> begin
    q = NCG.Ncg_child.objects
    q.filter("note" => "WHEREVAL")
    q.values("note", "s" => Subquery(_ncg_inner_with_cte()))
    q.order_by("-s")
    q
  end),
  # ON prints before WHERE, so the nested run comes first in the text; PostgreSQL numbers the WHERE
  # value `$1` because it binds first, which is why the vectors differ there and only the text-order
  # readback is compared.
  ("__@in in an on() join condition", ["CTEVAL", "INNERVAL", "WHEREVAL"], () -> begin
    q = NCG.Ncg_child.objects
    q.filter("note" => "WHEREVAL")
    q.on("parent", "parent__id__@in" => _ncg_inner_with_cte())
    q.values("note", "parent__sku")
    q
  end),
  ("__@in over a subquery whose own __@in declares the CTE", ["WHEREVAL", "MIDVAL", "CTEVAL", "INNERVAL"], () -> begin
    mid = NCG.Ncg_parent.objects
    mid.filter("sku" => "MIDVAL", "id__@in" => _ncg_inner_with_cte())
    mid.values("id")
    q = NCG.Ncg_child.objects
    q.filter("note" => "WHEREVAL", "parent__@in" => mid)
    q.values("note")
    q
  end),
  # The nested query binds in its SELECT list as well as its WHERE. Its CTE body's value must come
  # first: that is what the `:cte` scope in `build_cte_clause` gives a nested render, where `query()`
  # does not set `:cte` itself. Without it the body's value would file under the ambient `:where`
  # and be lifted AFTER the projection's `"PROJVAL", 1, 0`.
  ("__@in over a CTE subquery that binds in its own SELECT", ["WHEREVAL", "CTEVAL", "PROJVAL", 1, 0, "INNERVAL"], () -> begin
    s = NCG.Ncg_parent.objects
    s.with("gv" => _ncg_grand_cte(), join_field = "grandparent" => "id")
    s.filter(CTE("gv", "code") => "INNERVAL")
    s.values("v" => Case(When("sku" => "PROJVAL", then = 1), default = 0))
    q = NCG.Ncg_child.objects
    q.values("note")
    q.filter("note" => "WHEREVAL", "parent__@in" => s)
    q
  end),
  # The nested name shadows the outer one. Each query has its own CTE namespace (#444), and SQL
  # scopes a WITH name to its own SELECT, so both resolve to their own declaration.
  ("a nested CTE named like the outer query's", ["CTEVAL", "OUTERVAL", "CTEVAL", "INNERVAL"], () -> begin
    q = NCG.Ncg_parent.objects
    q.with("gv" => _ncg_grand_cte(), join_field = "grandparent" => "id")
    q.filter("gv__code" => "OUTERVAL", "id__@in" => _ncg_inner_with_cte())
    q.values("sku")
    q
  end),
  ("__@in with a nested CTE, inside a CTE body", ["BODYVAL", "CTEVAL", "INNERVAL", "MAINVAL"], () -> begin
    body = NCG.Ncg_child.objects
    body.filter("note" => "BODYVAL", "parent__@in" => _ncg_inner_with_cte())
    body.values("id", "parent")
    q = NCG.Ncg_parent.objects
    q.with("cb" => body, join_field = "id" => "parent")
    q.filter("sku" => "MAINVAL")
    q.values("sku", "cb__id")
    q
  end),
]

const _NCG_NESTED_WITH = r"\(WITH [\"`]gv[\"`] AS"

@testset "Subquery(...) / __@in over a subquery declaring its own .with(...) build, values in text order (#1292)" begin
  # Expected SQL: `… IN (WITH "gv" AS (SELECT … WHERE code = ?) SELECT … WHERE "gv".code = ?)` with
  # the nested WITH inside the consumer's parentheses, and every value bound where its marker prints.
  # Why: #433 refused these on every engine for a misbind that no longer exists; a regression in the
  # nested-run lift would bind them out of text order on SQLite and MySQL, silently.
  for (label, expected, build_q) in _NCG_BUILT_SHAPES
    @testset "$label" begin
      pg = _ncg_sql(build_q, _NCG_PG)
      @test occursin(_NCG_NESTED_WITH, pg[:sql_text])
      assert_marker_count(pg, :postgres)
      @test _pg_text_order(pg) == expected
      for (backend, conn) in _NCG_POSITIONAL
        insp = _ncg_sql(build_q, conn)
        @test occursin(_NCG_NESTED_WITH, insp[:sql_text])
        assert_marker_count(insp, :sqlite)
        assert_bound_in_text_order(insp, expected)
        @test insp[:parameters] == _pg_text_order(pg)
      end
    end
  end
end

@testset "the read and write terminals bind a nested CTE in text order (#1292)" begin
  # Expected: `count`/`exists` render `… WHERE note = ? AND parent IN (WITH "gv" AS …)`, and the
  # UPDATE/DELETE carry the same nested WITH in their WHERE (or in SET). Why: each terminal renders
  # its own statement around the same filter render, so a terminal-specific bucket switch would
  # misbind only there. On the model's own SQLite connection, the engine whose order is at stake.
  _filtered(note) = begin
    q = NCG.Ncg_child.objects
    q.filter("note" => note, "parent__@in" => _ncg_inner_with_cte())
    q
  end
  for (label, expected, run) in [
    ("count()", ["WHEREVAL", "CTEVAL", "INNERVAL"], () -> _filtered("WHEREVAL").count(show_query = :inspection)),
    ("exists()", ["WHEREVAL", "CTEVAL", "INNERVAL"], () -> _filtered("WHEREVAL").exists(show_query = :inspection)),
    ("update(), the CTE in WHERE", ["SETVAL", "WHEREVAL", "CTEVAL", "INNERVAL"],
     () -> _filtered("WHEREVAL").update("note" => "SETVAL", show_query = :inspection)),
    ("update(), the CTE in SET", ["CTEVAL", "INNERVAL", "WHEREVAL"], () -> begin
      q = NCG.Ncg_child.objects
      q.filter("note" => "WHEREVAL")
      q.update("parent" => Subquery(_ncg_inner_with_cte()), show_query = :inspection)
    end),
    ("delete()", ["WHEREVAL", "CTEVAL", "INNERVAL"],
     () -> _filtered("WHEREVAL").delete(show_query = :inspection, connection = _NCG_SL)),
  ]
    @testset "$label" begin
      insp = Logging.with_logger(run, Logging.NullLogger())
      @test occursin(_NCG_NESTED_WITH, insp[:sql_text])
      assert_marker_count(insp, :sqlite)
      assert_bound_in_text_order(insp, expected)
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# BOUNDARY: a CTE declared inside a CTE BODY still renders (#433)
# This nesting is CORRECT today and must stay legal. It routes through
# `build_cte_clause` -> `query(..., cte=...)`, so its values bind in `:cte` during the same pass
# that emits their text, all of it inside the leading WITH. Without this control, a guard written
# one level too high — say, on `build_cte_clause` itself, or on any `.ctes` seen during a nested
# build — would satisfy every refusal assertion above while breaking a working feature.
# ─────────────────────────────────────────────────────────────────────────────
@testset "a CTE inside a CTE body still renders (#433 boundary)" begin
  _boundary() = begin
    q = NCG.Ncg_child.objects
    q.with("pc" => _ncg_inner_with_cte(), join_field = "parent" => "id")
    q.values("note", "pid" => CTE("pc", "id"))
    q
  end

  for (backend, conn) in _NCG_BACKENDS
    insp = _ncg_sql(_boundary, conn)
    sql = insp[:sql_text]
    # A WITH nested inside another WITH — the shape the guard must not touch.
    @test occursin("\"pc\" AS", sql)
    @test occursin("\"gv\" AS", sql)
    # Values arrive in text order: the inner CTE body renders first, then its filter.
    @test insp[:parameters] == ["CTEVAL", "INNERVAL"]
  end

  # On SQLite both land in :cte, which is flattened first — and that is textually correct here,
  # because the whole construct IS the leading WITH clause. This is the precise difference from
  # the refused shapes, where the same bucket choice puts values ahead of text that precedes them.
  insp_sl = _ncg_sql(_boundary, _NCG_SL)
  @test insp_sl[:parameter_buckets][:cte] == ["CTEVAL", "INNERVAL"]
  @test isempty(insp_sl[:parameter_buckets][:where])
end

# ─────────────────────────────────────────────────────────────────────────────
# A statement kind that emits no WITH clause refuses a CTE reference (#433 audit)
# Found by auditing the `internal error … please report it` sites, which #433 asks for. That message
# claimed a broken invariant, but `cte_dict["model"]` is written in exactly one place —
# `_build_cte_custom_model`, reached only from `build_cte_clause` — so its absence means only that
# THIS statement never rendered a WITH. `update()` is such a statement, and the shape below reached
# the internal error from ordinary user input.
#
# `update()`'s own CTE refusal (#394) cannot catch it: that guard inspects `row_join` entries, and
# `_build_row_join` raises while still producing them. Reads are the control — they DO render a CTE
# and must keep working.
# ─────────────────────────────────────────────────────────────────────────────
@testset "a statement with no WITH clause refuses a CTE reference (#433 audit)" begin
  _upd_q() = begin
    q = NCG.Ncg_child.objects
    q.with("gv" => _ncg_grand_cte(), join_field = "parent" => "id")
    q.filter(CTE("gv", "code") => "CTEVAL")
    q
  end

  err = try
    _upd_q().update("note" => "n", show_query = :sql)
    nothing
  catch e
    e
  end

  # Was an untyped ErrorException before; the type assertion is the load-bearing half.
  @test err isa PormG.QueryBuildError
  msg = sprint(showerror, err)
  @test occursin("gv", msg)
  @test occursin("WITH", msg)
  @test occursin("update(", msg)
  @test !occursin("internal", lowercase(msg))
  @test !occursin("report", lowercase(msg))

  # Control: the SAME query shape on a read path renders the CTE and is untouched. Without this,
  # a guard that simply refused every CTE reference would satisfy the assertions above.
  count_sql = _upd_q().count(show_query = :sql)
  @test occursin("WITH \"gv\" AS", count_sql)
end

# ─────────────────────────────────────────────────────────────────────────────
# delete() refuses a CTE-scoped queryset, on BOTH cascade and leaf paths (#433)
# The deletion collector re-uses the queryset being deleted as a scoping subquery, two different
# ways: for a model WITH dependents it synthesizes `"<fk>__@in" => objct`, and for a LEAF it renders
# the query into its own statement (`DELETE ... WHERE pk IN (<objct>)` until #765; now its filters on
# the target row, plus a pk-IN selection when joined). Those paths reach different amounts of the builder,
# so a downstream guard made the same user code succeed or fail depending on whether the target
# model happened to have a reverse relation. Both are pinned here — Ncg_parent has dependents
# (Ncg_child), Ncg_child has none — so a future guard that only covers one path fails.
#
# An exemption was tried and measured to re-open the misbind for deletes (SQLite bound
# ["CTEVAL","INNERVAL","NOTEVAL"] against a text order of NOTEVAL, CTEVAL, INNERVAL — a silent
# WRONG DELETE), which is why this refuses instead.
# ─────────────────────────────────────────────────────────────────────────────
@testset "delete() refuses a CTE-scoped queryset on both paths (#433)" begin
  _cte_scoped(model, fk) = begin
    q = model.objects
    q.with("gv" => _ncg_grand_cte(), join_field = fk => "id")
    q.filter(CTE("gv", "code") => "CTEVAL")
    q
  end

  for (path, model, fk) in (("cascade (has dependents)", NCG.Ncg_parent, "grandparent"),
                            ("leaf (no dependents)",     NCG.Ncg_child,  "parent"))
    @testset "$path" begin
      for (backend, conn) in _NCG_BACKENDS
        err = try
          _cte_scoped(model, fk).delete(show_query = :sql, connection = conn)
          nothing
        catch e
          e
        end
        # UnsafeMutationError, not QueryBuildError: the same query is legal on a read path, so what
        # makes it illegal is that it is a mutation — the axis this type names, and the one its four
        # neighbouring guards in `delete()` use.
        #
        # The leaf path RENDERED successfully before this guard, so the type assertion is the
        # load-bearing half there. On the CASCADE path, without this guard, the root statement reaches
        # `build_joins.jl`'s "emits no WITH clause" QueryBuildError (the `__@in` refusal that used to
        # fire first was lifted by #1292), so the type assertion discriminates there too — and
        # `occursin("delete()")` pins that it came from THIS guard, not that fallback.
        @test err isa PormG.UnsafeMutationError
        msg = sprint(showerror, err)
        @test occursin("delete()", msg)
        @test occursin("gv", msg)
        # #1292: the reason is the statement (a DELETE renders no WITH), not a binding order.
        @test occursin("never be declared", msg)
        @test !occursin(":cte", msg)
        @test !occursin("internal", lowercase(msg))
      end
    end
  end

  # Control: delete() on the same models WITHOUT a CTE still builds, on both paths. Without this,
  # a guard that refused every delete would satisfy the assertions above.
  for (model, conn) in ((NCG.Ncg_parent, _NCG_SL), (NCG.Ncg_child, _NCG_SL))
    q = model.objects
    q.filter("id" => 1)
    @test q.delete(show_query = :sql, connection = conn) !== nothing
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# CONTROLS: the same consumers with NO nested CTE are unaffected (#433)
# A guard that refused every subquery would pass every assertion above. These pin that only the
# nested-`.with(...)` case moved.
# ─────────────────────────────────────────────────────────────────────────────
@testset "subqueries without a nested CTE still render (#433 control)" begin
  for (backend, conn) in _NCG_BACKENDS
    exists_sql = _ncg_sql(() -> begin
      q = NCG.Ncg_child.objects
      q.values("note")
      q.filter(Exists(_ncg_inner_plain()))
      q
    end, conn)[:sql_text]
    @test occursin("EXISTS (SELECT 1", exists_sql)

    sub_insp = _ncg_sql(() -> begin
      q = NCG.Ncg_child.objects
      q.values("note", "pid" => Subquery(_ncg_inner_plain()))
      q
    end, conn)
    @test occursin("as \"pid\"", sub_insp[:sql_text])
    @test sub_insp[:parameters] == ["PLAINVAL"]

    in_insp = _ncg_sql(() -> begin
      q = NCG.Ncg_child.objects
      q.values("note")
      q.filter("parent__@in" => _ncg_inner_plain())
      q
    end, conn)
    @test occursin("IN (SELECT", in_insp[:sql_text])
    @test in_insp[:parameters] == ["PLAINVAL"]
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# #566: a subquery cannot see its ENCLOSING query's CTE, and the refusal says why
# The docs used to call "a CTE inside a subquery" an unblocked-but-untested edge. It is refused in
# every spelling: declared inside (#433, above) or reached for from inside (here, #444's per-query
# namespace). The refusal was already correct; what #566 changed is the message, which read
# "declared CTEs: none" (or "column gv not found") while the caller's `.with()` was in plain sight.
# ─────────────────────────────────────────────────────────────────────────────
import PormG.QueryBuilder: OuterRef

# The outer query declares `gv`; the inner one does not.
_ncg_outer_with_cte() = begin
  q = NCG.Ncg_parent.objects
  q.with("gv" => _ncg_grand_cte(), join_field = "grandparent" => "id")
  q
end

# The inner query reaches for `gv` in one of the two spellings a caller can write.
_ncg_inner_reaching(spelling::Symbol) = begin
  s = NCG.Ncg_child.objects
  s.filter(spelling === :handle ? (CTE("gv", "code") => "X") : ("gv__code" => "X"))
  s
end

const _NCG_REACHING_CONSUMERS = [
  ("Exists(...) in a filter", spelling -> begin
    q = _ncg_outer_with_cte()
    s = _ncg_inner_reaching(spelling)
    s.filter("parent" => OuterRef("id"))
    q.filter(Exists(s))
    q.values("sku")
    q
  end),
  ("Subquery(...) projected in values()", spelling -> begin
    q = _ncg_outer_with_cte()
    s = _ncg_inner_reaching(spelling)
    s.filter("parent" => OuterRef("id"))
    s.values("id")
    s.limit(1)
    q.values("sku", "cid" => Subquery(s))
    q
  end),
  ("__@in membership filter", spelling -> begin
    q = _ncg_outer_with_cte()
    s = _ncg_inner_reaching(spelling)
    s.values("parent")
    q.filter("id__@in" => s)
    q.values("sku")
    q
  end),
]

# The needles are plain-text runs of the hint, chosen so none spans an ANSI-colorized token: an
# `occursin` across a color escape passes off-TTY and fails on every CI job.
_ncg_names_outer_rule(msg) =
  occursin("is declared on an ENCLOSING query", msg) && occursin("has its own CTE namespace", msg)

@testset "a subquery reaching for its enclosing query's CTE is refused, and says why (#566)" begin
  for (label, build_for) in _NCG_REACHING_CONSUMERS, spelling in (:handle, :string)
    @testset "$label, $(spelling) spelling" begin
      for (backend, conn) in _NCG_BACKENDS
        err = _ncg_err(() -> build_for(spelling), conn)
        # The type did not change with #566 — only the text — so no caller catching it moves.
        @test err isa PormG.UnknownFieldError
        msg = sprint(showerror, err)
        @test occursin("gv", msg)
        # Unpatched, both spellings raise with no mention of the enclosing query at all.
        @test _ncg_names_outer_rule(msg)
        @test occursin("#444", msg)
        # …and never offers the remedy #433 refuses: declaring the CTE on the subquery itself.
        @test !occursin("Add it with", msg)
      end
    end
  end
end

@testset "the #566 hint walks past an intermediate subquery" begin
  # Exists inside Exists, both in filters, is legal — so the query declaring `gv` can sit two
  # levels up. A one-level lookup would miss it and fall back to the bare message.
  for (backend, conn) in _NCG_BACKENDS
    err = _ncg_err(() -> begin
      q = _ncg_outer_with_cte()
      mid = NCG.Ncg_child.objects
      mid.filter("parent" => OuterRef("id"))
      leaf = NCG.Ncg_child.objects
      leaf.filter(CTE("gv", "code") => "X")
      leaf.filter("id" => OuterRef("id"))
      mid.filter(Exists(leaf))
      q.filter(Exists(mid))
      q.values("sku")
      q
    end, conn)
    @test err isa PormG.UnknownFieldError
    @test _ncg_names_outer_rule(sprint(showerror, err))
  end
end

@testset "the #566 hint appears only when an enclosing query declares the CTE" begin
  for (backend, conn) in _NCG_BACKENDS
    # Top level, no enclosing query: the plain message, unchanged.
    top = _ncg_err(() -> begin
      q = NCG.Ncg_child.objects
      q.filter(CTE("gv", "code") => "X")
      q.values("note")
      q
    end, conn)
    @test top isa PormG.UnknownFieldError
    @test !_ncg_names_outer_rule(sprint(showerror, top))
    # At the top level declaring it IS the fix, so that advice stays.
    @test occursin("Add it with", sprint(showerror, top))

    # Inside a subquery, but the enclosing query declares nothing: blaming a parent that has no
    # such CTE would send the reader after a `.with()` that is not there.
    bare = _ncg_err(() -> begin
      q = NCG.Ncg_parent.objects
      s = _ncg_inner_reaching(:string)
      s.filter("parent" => OuterRef("id"))
      q.filter(Exists(s))
      q.values("sku")
      q
    end, conn)
    @test bare isa PormG.UnknownFieldError
    @test !_ncg_names_outer_rule(sprint(showerror, bare))
  end
end

@testset "a CTE on the outer query beside a subquery that ignores it builds (#566)" begin
  # Shape (b) of #566. It is NOT "a CTE inside a subquery", but it is the legal neighbour of every
  # refusal above, and the doc names it so a reader knows where the line is.
  for (backend, conn) in _NCG_BACKENDS
    insp = _ncg_sql(() -> begin
      q = _ncg_outer_with_cte()
      q.values("sku", "gv__code", "pid" => Subquery(_ncg_inner_plain()))
      q
    end, conn)
    @test startswith(insp[:sql_text], "WITH \"gv\" AS (")
    @test occursin("as \"pid\"", insp[:sql_text])
    # CTE body first, then the subquery's value — text order, on both engines.
    @test insp[:parameters] == ["CTEVAL", "PLAINVAL"]
  end
end
