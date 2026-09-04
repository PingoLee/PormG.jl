"""
Unit coverage for nested-render parameter alignment (#432).

A value's positional bucket used to be chosen by **which builder phase bound it**, not by **where
its `?` lands in the SQL text**. When a subquery renders inside another clause the two disagree, and
every marker after the divergence misbinds — silently, on SQLite only, with PostgreSQL correct.

Two independent things were wrong, and both had to be fixed for any of these shapes to come out
right:

  1. **Wrong bucket.** `build_row_join_sql_text` switches to `:join` unconditionally in both of its
     phase loops, defeating `build()`'s own `set_contexts` gate on the very next line. A nested
     build's ON values therefore landed in the OUTER `:join` bucket while their `?` rendered inside
     the outer WHERE, and `:join` flattens before `:where`.
  2. **Wrong ORDER, even within one bucket.** A build BINDS in phase order (…joins last) but RENDERS
     in clause order (joins first). At top level the buckets absorb that — it is what they are for.
     A nested run had no such reordering: simply restoring the ambient bucket yields binding order,
     which for `Exists(inner-with-ON)` is `WHEREVAL, ONVAL` against a text order of `ONVAL, WHEREVAL`.

The fix marks every bucket around a nested render, lifts what the inner build bound, and re-emits it
as one contiguous run in the parent's active bucket, concatenated in CLAUSE order
(`nested_parameter_mark` / `detach_nested_run!`). `own_contexts` on `query()` is the other half: the
inner build must file its values under its OWN clauses, or the run has nothing to sort by.

Measured before the fix, and pinned below:

    Rep A  Exists(inner-with-ON) after an outer filter
           text OUTERVAL, ONVAL, WHEREVAL   ->  SQLite bound [ONVAL, OUTERVAL, WHEREVAL]
    C1     the same through `__@in`         ->  SQLite bound [ONVAL, OUTERVAL, WHEREVAL]
    C2     projected Subquery(inner-with-ON), then an outer filter
           text ONVAL, WHEREVAL, TAIL       ->  SQLite bound [WHEREVAL, ONVAL, TAIL]
    H1     projected Subquery whose inner carries a HAVING filter
           text INNERW, 5, TAIL             ->  SQLite bound [INNERW, TAIL, 5]

H1 is a third site the issue did not name: `get_filter_query`'s HAVING branch restored to a
hard-coded `:where` rather than to the ambient bucket, so in a nested build whose ambient is
`:select` it moved every subsequent inner value in with the OUTER query's.

**Declaration order is load-bearing in every test here.** The misbind needs a value whose TEXT
precedes the nested render — declare the `Exists` first and the bug disappears, so a test written
that way passes against the unfixed code. Each shape below therefore filters BEFORE nesting, and one
control pins the reversed order to document why.

Both backends run: `test_alignment_sqlite.jl` is SQLite-only by construction, so a cross-backend
divergence — which is the entire defect class — cannot surface there.
"""
# julia --project=. test/unit/test_parameter_alignment_nested.jl

using Test
using PormG
using PormG.Models

include("helper_marker_alignment.jl")

struct PanMockSQLite <: PormG.PormGSQLite end
struct PanMockPostgres <: PormG.PormGPostgres end
const _PAN_SL = PanMockSQLite()
const _PAN_PG = PanMockPostgres()
PormG.backend_sqlite_version(::PanMockSQLite) = 3045000

PormG.config["pan_mock"] = PormG.Configuration.Settings(
  connections = _PAN_SL,
  change_data = true,
  db_def_folder = "pan_mock",
)

module PanModels
import PormG
import PormG.Models

Pan_grand = Models.Model("pan_grand",
  id   = Models.IDField(),
  code = Models.CharField(),
)

Pan_parent = Models.Model("pan_parent",
  id          = Models.IDField(),
  sku         = Models.CharField(),
  qty         = Models.IntegerField(null = true),
  grandparent = Models.ForeignKey(Pan_grand, on_delete = "CASCADE", related_name = "pan_pars", null = true),
)

Pan_child = Models.Model("pan_child",
  id     = Models.IDField(),
  note   = Models.CharField(null = true),
  parent = Models.ForeignKey(Pan_parent, on_delete = "CASCADE", related_name = "pan_kids", null = true),
)

PormG.Models.set_models(@__MODULE__, "pan_mock")
end

const PAN = PanModels
import PormG.QueryBuilder: F, Exists, Subquery, inspect_query, Sum, Joined

const _PAN_BACKENDS = (("PostgreSQL", _PAN_PG, :postgres), ("SQLite", _PAN_SL, :sqlite))

# An inner query that binds ONE value in a JOIN ON clause and ONE in WHERE — the two-factor
# combination the whole bug needs, and the one no existing testset combined with a nested render.
_pan_inner_on() = begin
  s = PAN.Pan_parent.objects
  s.values("id")
  s.filter("sku" => "WHEREVAL")
  s.cjoin("grandparent" => "Pan_grand", filters = ["code" => "ONVAL"], warn = false)
  s
end

# ─────────────────────────────────────────────────────────────────────────────
# A nested render binds in TEXT order, on both backends (#432)
# Driven from one table so a fourth nesting site added later inherits the assertions rather than
# getting a hand-written near-copy. `text` lists the sentinels in the order their markers appear in
# the rendered SQL — the whole point of the fix.
# ─────────────────────────────────────────────────────────────────────────────
const _PAN_SHAPES = [
  (
    "Rep A — Exists(inner-with-ON) in WHERE, after an outer filter",
    ["OUTERVAL", "ONVAL", "WHEREVAL"],
    () -> begin
      q = PAN.Pan_child.objects
      q.values("note")
      q.filter("note" => "OUTERVAL")     # MUST precede the nesting — see the file docstring
      q.filter(Exists(_pan_inner_on()))
      q
    end,
  ),
  (
    "C1 — __@in over inner-with-ON, after an outer filter",
    ["OUTERVAL", "ONVAL", "WHEREVAL"],
    () -> begin
      q = PAN.Pan_child.objects
      q.values("note")
      q.filter("note" => "OUTERVAL")
      q.filter("parent__@in" => _pan_inner_on())
      q
    end,
  ),
  (
    "C2 — projected Subquery(inner-with-ON), then an outer filter",
    ["ONVAL", "WHEREVAL", "TAIL"],
    () -> begin
      q = PAN.Pan_child.objects
      q.values("note", "p" => Subquery(_pan_inner_on()))
      q.filter("note" => "TAIL")
      q
    end,
  ),
  (
    "H1 — projected Subquery whose inner carries a HAVING filter",
    ["INNERW", 5, "TAIL"],
    () -> begin
      inner = PAN.Pan_parent.objects
      inner.values("t" => Sum("qty"))
      inner.filter("t__@gt" => 5)        # -> HAVING, and the switch that used to clobber :select
      inner.filter("sku" => "INNERW")    # -> bound AFTER that switch
      q = PAN.Pan_child.objects
      q.values("note", "p" => Subquery(inner))
      q.filter("note" => "TAIL")
      q
    end,
  ),
]

@testset "a nested render binds in text order (#432)" begin
  for (label, text_order, build_q) in _PAN_SHAPES
    @testset "$label" begin
      for (backend, conn, kind) in _PAN_BACKENDS
        insp = inspect_query(build_q(); connection = conn)

        # Half one: no orphan markers. Holds on both backends and held before the fix too — it is
        # #441's invariant, asserted here so a future change cannot trade one half for the other.
        assert_marker_count(insp, kind)

        if kind === :sqlite
          # Half two: the flattened vector IS the text order. This is what was broken.
          assert_bound_in_text_order(insp, text_order)
        else
          # PostgreSQL's control: same values, and `$N` travels with the text by construction. The
          # binding ORDER differs from SQLite's and that is correct — the numbering compensates.
          @test sort(string.(insp[:parameters])) == sort(string.(text_order))
        end
      end
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# Declaration order is what makes the bug visible (#432)
# Reversing it — nesting BEFORE the outer filter — made the misbind vanish on the unfixed code,
# because nothing bound earlier was left to overtake. Pinned so nobody "simplifies" a shape above
# into this order and quietly turns it into a test that passes either way.
# ─────────────────────────────────────────────────────────────────────────────
@testset "the reversed declaration order was never broken (#432 control)" begin
  reversed = () -> begin
    q = PAN.Pan_child.objects
    q.values("note")
    q.filter(Exists(_pan_inner_on()))   # nested FIRST
    q.filter("note" => "OUTERVAL")
    q
  end
  insp = inspect_query(reversed(); connection = _PAN_SL)
  assert_marker_count(insp, :sqlite)
  assert_bound_in_text_order(insp, ["ONVAL", "WHEREVAL", "OUTERVAL"])
end

# ─────────────────────────────────────────────────────────────────────────────
# Rep B is refused, not fixed (#432 / #433)
# The issue's second reproduction is `__@in` over a subquery declaring its own `.with(...)`, nested
# in a `cjoin_on` ON list. #433's guard refuses any subquery that declares a CTE, so that shape can
# no longer be built and its acceptance criterion is met by REFUSAL rather than by correct binding.
#
# Pinned deliberately: if that guard is ever relaxed, this fails here rather than silently restoring
# a misbind. A CTE BODY's own parameters are now routed correctly (`build_cte_clause` marks and
# re-emits them the same way, which fixed a live shape nothing refused — a plain `.with(...)` whose
# body carries a parameterized join). What is still unhandled is narrower: a `WITH` rendered INLINE
# inside a subquery's parentheses, where the values belong in the parent's clause rather than `:cte`.
# #433's guard is the only thing keeping that unreachable.
# ─────────────────────────────────────────────────────────────────────────────
@testset "Rep B stays refused by #433's guard (#432)" begin
  sub_with_cte = () -> begin
    gv = PAN.Pan_grand.objects
    gv.values("id", "code")
    s = PAN.Pan_parent.objects
    s.with("gv" => gv, join_field = "grandparent" => "id")
    s.filter(CTE("gv", "code") => "CTEVAL")
    s.values("id")
    s
  end

  for (backend, conn, _) in _PAN_BACKENDS
    err = try
      q = PAN.Pan_child.objects
      q.values("note")
      q.cjoin_on("Pan_parent", alias = "b2",
                 on = [Joined("b2", "sku") == F("note"), "id__@gt" => 7,
                       "parent__@in" => sub_with_cte()])
      inspect_query(q; connection = conn)
      nothing
    catch e
      e
    end
    @test err isa PormG.QueryBuildError
    @test occursin("gv", sprint(showerror, err))
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# Shapes with no nesting are untouched (#432 controls)
# The fix adds a mark/detach around three call sites. If it disturbed ordinary rendering, these
# would move — they are the same bucket behaviour `test_alignment_sqlite.jl` pins at length, kept
# here as a local tripwire so this file fails on its own.
# ─────────────────────────────────────────────────────────────────────────────
@testset "un-nested queries are unaffected (#432 control)" begin
  # A top-level cjoin ON value still belongs in :join, flattened before :where.
  q = PAN.Pan_parent.objects
  q.values("id")
  q.filter("sku" => "PLAINWHERE")
  q.cjoin("grandparent" => "Pan_grand", filters = ["code" => "PLAINON"], warn = false)
  insp = inspect_query(q; connection = _PAN_SL)
  assert_marker_count(insp, :sqlite)
  assert_bound_in_text_order(insp, ["PLAINON", "PLAINWHERE"])
  @test insp[:parameter_buckets][:join] == ["PLAINON"]
  @test insp[:parameter_buckets][:where] == ["PLAINWHERE"]

  # A nested render that binds nothing in an ON clause was already correct, and stays so.
  plain_inner = PAN.Pan_parent.objects
  plain_inner.values("id")
  plain_inner.filter("sku" => "INNERONLY")
  q2 = PAN.Pan_child.objects
  q2.values("note")
  q2.filter("note" => "OUTERONLY")
  q2.filter(Exists(plain_inner))
  insp2 = inspect_query(q2; connection = _PAN_SL)
  assert_marker_count(insp2, :sqlite)
  assert_bound_in_text_order(insp2, ["OUTERONLY", "INNERONLY"])
end

# ─────────────────────────────────────────────────────────────────────────────
# A CTE BODY is the fourth nested-render site (#432)
# Found by review, and NOT a variant of Rep B: no subquery, no `Exists`/`Subquery`/`__@in`, nothing
# refuses it. A plain documented `.with(...)` whose body carries a parameterized join scattered its
# values across `:cte` (its own WHERE) and `:join` (the body's ON), while the whole thing renders
# inside the leading `WITH`. `:cte` flattens ahead of `:join`, so they came out reversed.
#
# Measured before the fix: SQLite bound ["CTEWHERE", "CTEON"] against a text order of
# CTEON, CTEWHERE. Correct on PostgreSQL. Silent wrong rows.
# ─────────────────────────────────────────────────────────────────────────────
@testset "a CTE body binds in text order (#432)" begin
  build_q = () -> begin
    cte = PAN.Pan_parent.objects
    cte.values("id", "sku")
    cte.cjoin("grandparent" => "Pan_grand", filters = ["code" => "CTEON"], warn = false)
    cte.filter("sku" => "CTEWHERE")
    q = PAN.Pan_child.objects
    q.with("cq" => cte, join_field = "parent" => "id")
    q.values("note", "s" => CTE("cq", "sku"))
    q.filter("note" => "TAIL")
    q
  end

  for (backend, conn, kind) in _PAN_BACKENDS
    insp = inspect_query(build_q(); connection = conn)
    assert_marker_count(insp, kind)
    if kind === :sqlite
      # Text: the CTE body's JOIN ON, then its WHERE, then the outer WHERE.
      assert_bound_in_text_order(insp, ["CTEON", "CTEWHERE", "TAIL"])
      # Both of the body's values belong to the WITH, so both land in :cte — in text order.
      @test insp[:parameter_buckets][:cte] == ["CTEON", "CTEWHERE"]
      @test insp[:parameter_buckets][:where] == ["TAIL"]
      @test isempty(insp[:parameter_buckets][:join])
    end
  end
end
