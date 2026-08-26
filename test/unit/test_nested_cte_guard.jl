"""
Unit coverage for the nested-CTE guard (#433): a `.with(...)` declared INSIDE a subquery that is
consumed by `Exists(...)`, `Subquery(...)` or a `__@in` / `__@nin` membership filter is refused at
query-build time, on BOTH backends.

Why the guard is wider than the reported crash. The three consumers failed in two different ways:

  - `Exists(...)` never rendered a nested CTE at all. `_build_exists_query` hand-rolls its own
    SELECT rather than routing through `query()`, so it emits no `WITH` prefix and never
    materializes the CTE's model. The first path resolving `<cte>__col` then reached an
    "internal error … please report it" — a message reserved for a broken invariant, raised for a
    query shape the user was entitled to write. That is what #433 reported.
  - `Subquery(...)` and `"col__@in" => sub` DO render an inline `WITH`, and on PostgreSQL they are
    correct. On SQLite they can MISBIND, because `build_cte_clause` binds unconditionally into the
    `:cte` bucket and `:cte` is flattened ahead of `:select` and `:where`. Measured on this
    fixture before the guard landed:

        filter("note" => "WHEREVAL", "parent__@in" => <sub declaring .with("gv" => ...)>)
            PostgreSQL  ["WHEREVAL", "CTEVAL", "INNERVAL"]     <- matches the text
            SQLite      ["CTEVAL", "INNERVAL", "WHEREVAL"]     <- wrong rows, no error

        values("a" => Subquery(plain), "b" => Subquery(<sub with .with>))
            PostgreSQL  ["PLAINVAL", "CTEVAL", "INNERVAL"]
            SQLite      ["CTEVAL", "INNERVAL", "PLAINVAL"]

    The misbind is CONDITIONAL, not universal: it needs a value whose text precedes the nested CTE
    but whose bucket flattens later. With no such value the same shapes bind correctly, which is
    why this survived undetected. PostgreSQL never misbinds — its `\$N` numbering has no buckets.

Refusing on BOTH backends is the "keep PostgreSQL and SQLite aligned" rule, not a claim that
PostgreSQL is broken: a query that builds on one engine and is refused on the other is a worse
trap than one refused on both. `UPGRADING.md` records the removal of the working PG shapes.

What is pinned here (deterministic, DB-free — rendered via `inspect_query`, both dialects):
  - Each of the consumers refuses a subquery carrying its own `.with(...)`, with a
    `QueryBuildError` that names the offending CTE and never says "internal"/"report".
  - `Exists` is refused in the PROJECTED position too, not only in a filter.
  - BOUNDARY: a CTE declared inside a CTE **body** still renders, on both backends, with its
    values in text order. This is the control that stops the guard being written one level too
    high — that nesting is correct today and must stay legal.
  - CONTROLS: the same consumers with no nested CTE still render unchanged.

Sibling coverage:
  - `test_cte_ergonomics.jl` (#44)  -> CROSS-joined CTEs and `F()` correlation.
  - `test_alignment_sqlite.jl`      -> the positional bucket contract these values ride on.
"""
# julia --project=. test/unit/test_nested_cte_guard.jl

using Test
using PormG
using PormG.Models
import Logging

# Mock connections under a dedicated key so this file cannot contaminate (or be contaminated by)
# other unit files sharing Main in runtests.jl. Only the connection TYPE matters — dispatch
# selects SQLite `?` vs PostgreSQL `$N` rendering.
struct NcgMockSQLite <: PormG.PormGSQLite end
struct NcgMockPostgres <: PormG.PormGPostgres end
const _NCG_SL = NcgMockSQLite()
const _NCG_PG = NcgMockPostgres()

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
import PormG.QueryBuilder: F, Exists, Subquery, inspect_query

const _NCG_BACKENDS = (("PostgreSQL", _NCG_PG), ("SQLite", _NCG_SL))

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
  s.filter("gv__code" => "INNERVAL")
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
# The consumers refuse a subquery that declares its own .with(...) (#433)
# Driven from one table so a fourth consumer added later inherits the same assertions rather than
# getting its own hand-written near-copy. Each entry names the spelling the message must open
# with, so a guard wired to the wrong site fails loudly instead of passing on a sibling's message.
# ─────────────────────────────────────────────────────────────────────────────
const _NCG_CONSUMERS = [
  (
    "Exists(...) in a filter", "Exists(...)",
    () -> begin
      q = NCG.Ncg_child.objects
      q.values("note")
      q.filter(Exists(_ncg_inner_with_cte()))
      q
    end,
  ),
  (
    "Exists(...) projected in values()", "Exists(...)",
    () -> begin
      q = NCG.Ncg_child.objects
      # The projected form delegates to the filter form, so guarding `_build_exists_query` covers
      # both positions. Without this case, a guard placed in `_get_filter_query` instead would
      # pass every other assertion in this file.
      q.values("note", "has_parent" => Exists(_ncg_inner_with_cte()))
      q
    end,
  ),
  (
    "Subquery(...) projected in values()", "Subquery(...)",
    () -> begin
      q = NCG.Ncg_child.objects
      q.values("note", "pid" => Subquery(_ncg_inner_with_cte()))
      q
    end,
  ),
  (
    "__@in membership filter", "A membership filter",
    () -> begin
      q = NCG.Ncg_child.objects
      q.values("note")
      q.filter("parent__@in" => _ncg_inner_with_cte())
      q
    end,
  ),
  (
    "__@nin membership filter", "A membership filter",
    () -> begin
      q = NCG.Ncg_child.objects
      q.values("note")
      q.filter("parent__@nin" => _ncg_inner_with_cte())
      q
    end,
  ),
]

@testset "a subquery declaring its own .with(...) is refused (#433)" begin
  for (label, opening, build_q) in _NCG_CONSUMERS
    @testset "$label" begin
      for (backend, conn) in _NCG_BACKENDS
        err = _ncg_err(build_q, conn)

        # Before the fix this was an `ErrorException` for Exists and NO error at all for
        # Subquery/@in, so the type assertion is meaningful in both directions.
        @test err isa PormG.QueryBuildError
        msg = sprint(showerror, err)

        # Names the consumer the caller actually wrote, so the message points at the line to edit.
        @test occursin(opening, msg)
        # Names the offending CTE by the name the caller gave it — per-consumer on purpose; a
        # hardcoded name would not notice a message that reported the wrong one.
        @test occursin("gv", msg)
        # Points at the API that caused it and at the remedy.
        @test occursin(".with(", msg)
        @test occursin(".filter(", msg)
        # Never blames the caller for a PormG bug: this is a user-writable shape, and the message
        # it replaced was exactly the "internal ... please report it" antipattern (#424's lesson).
        @test !occursin("internal", lowercase(msg))
        @test !occursin("report", lowercase(msg))
      end
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# The reported reproduction, and the two measured misbind shapes, are each refused
# These are the exact queries from #433 and from the bucket measurement in this file's header.
# Pinning them separately from the table above means a future narrowing of the guard (say, to
# SQLite only, or to Exists only) fails here rather than silently re-opening a wrong-rows bug.
# ─────────────────────────────────────────────────────────────────────────────
@testset "the reported and misbinding shapes are refused (#433)" begin
  for (backend, conn) in _NCG_BACKENDS
    # #433's reproduction: Exists(sub) where sub declares .with(...).
    @test _ncg_err(() -> begin
      q = NCG.Ncg_child.objects
      q.values("note")
      q.filter(Exists(_ncg_inner_with_cte()))
      q
    end, conn) isa PormG.QueryBuildError

    # Misbind shape G: a WHERE value textually PRECEDES the nested CTE, so on SQLite it was
    # bound behind it — `note` was matched against "CTEVAL" and `gv.code` against "WHEREVAL".
    @test _ncg_err(() -> begin
      q = NCG.Ncg_child.objects
      q.values("note")
      q.filter("note" => "WHEREVAL")
      q.filter("parent__@in" => _ncg_inner_with_cte())
      q
    end, conn) isa PormG.QueryBuildError

    # Misbind shape H: a plain Subquery in the SELECT list textually precedes the one carrying
    # the CTE, and its `:select` value was flattened after the nested CTE's `:cte` values.
    @test _ncg_err(() -> begin
      q = NCG.Ncg_child.objects
      q.values("note",
               "a" => Subquery(_ncg_inner_plain("PLAINVAL")),
               "b" => Subquery(_ncg_inner_with_cte()))
      q
    end, conn) isa PormG.QueryBuildError
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
    q.values("note", "pid" => "pc__id")
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
    q.filter("gv__code" => "CTEVAL")
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
# `DELETE ... WHERE pk IN (<objct>)` directly. Those paths reach different amounts of the builder,
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
    q.filter("gv__code" => "CTEVAL")
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
        # load-bearing half there. On the CASCADE path the pre-guard behaviour was the `__@in`
        # guard's QueryBuildError, so the type assertion discriminates there too — but
        # `occursin("delete()")` is what pins that it came from THIS guard. Do not "tidy" that line
        # away: a mutation test showed the cascade arm drops to 6 pass / 2 fail without the guard,
        # and that single assertion is one of the two.
        @test err isa PormG.UnsafeMutationError
        msg = sprint(showerror, err)
        @test occursin("delete()", msg)
        @test occursin("gv", msg)
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
