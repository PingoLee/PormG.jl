"""
Unit coverage for projection-name collapse and refusal (#441).

`get_select_query` memoises each resolved projection in `instruc.cache`, keyed on `_as`. Two
different defects came out of that, and the fix has a part for each.

**Symptom 1 — a projection is silently discarded, both backends.** For a field-path projection `_as`
holds the PATH, while the name the column renders under lives in `custom_as`. So a bare cache hit
collapsed projections that share an expression but declare DIFFERENT names:

    values("gg" => "note", "hh" => "note")   ->  `as "gg"` twice; `hh` never emitted
    values("note", "gg" => "note")           ->  `as "note"` twice; `gg` gone
    values("s1" => "parent__sku", "s2" => …) ->  `as "s1"` twice

`_cache_join` writes into the same dict keyed by join path, so a projection could also collapse onto
an entry that was never a projection at all. Fixed by reusing the memo only when the cached entry
renders under the SAME output name.

**Symptom 2 — the discarded projection's parameters misalign on SQLite.** The cached field's
ALREADY-RENDERED text carries its `?`, so the statement emitted one marker more than the driver had
values for and everything after it bound one slot early. Measured before the fix:

    values("note", "h" => Exists(a), "h" => Exists(b)) + filter("note" => "TAIL")
        SQLite  3 markers, parameters ["AAA", "TAIL"]   <- "TAIL" bound to the second EXISTS,
                                                           the outer WHERE left unbound
        PostgreSQL  `\$1` twice + `\$2`  — legal, but still the wrong query

Fixed by refusing two projections that would render the same output name, at `.values()`. Refused at
declaration rather than repaired at render, because two columns under one name are indistinguishable
to everything downstream — a DataFrame column, an `order_by` alias — so no reading of the query
keeps both.

**Deliberate consequences, both decided rather than inherited:**

  - `values("lbl" => Value("a"), "lbl" => Value("b"))` is refused even though it renders correctly
    today (the `SQLText` branch bypasses the memo). One rule with no per-kind carve-out — a
    conditional rule is the kind of subtlety this defect family keeps escaping through.
  - The #423 ambiguity guard in `get_order_query` is retired as unreachable: `order_by` can no
    longer be handed a shared alias. See `test_order_by_alias.jl`.

`"*"` is compared as the PHYSICAL columns the database expands it to. A `field_names` check is wrong
in BOTH directions, which the `db_column` testset below demonstrates rather than asserts.
"""
# julia --project=. test/unit/test_projection_names.jl

using Test
using PormG
using PormG.Models

include("helper_marker_alignment.jl")

struct PnMockSQLite <: PormG.PormGSQLite end
struct PnMockPostgres <: PormG.PormGPostgres end
const _PN_SL = PnMockSQLite()
const _PN_PG = PnMockPostgres()
PormG.backend_sqlite_version(::PnMockSQLite) = 3045000

PormG.config["pn_mock"] = PormG.Configuration.Settings(
  connections = _PN_SL,
  change_data = true,
  db_def_folder = "pn_mock",
)

module PnModels
import PormG
import PormG.Models

Pn_parent = Models.Model("pn_parent",
  id  = Models.IDField(),
  sku = Models.CharField(),
)

Pn_child = Models.Model("pn_child",
  id     = Models.IDField(),
  note   = Models.CharField(null = true),
  qty    = Models.IntegerField(null = true),
  parent = Models.ForeignKey(Pn_parent, on_delete = "CASCADE", related_name = "pn_kids", null = true),
)

# `note` renders as the physical column `obs`. This is the fixture that separates a PHYSICAL-name
# check from a `field_names` one — without a `db_column` anywhere, both checks agree and the test
# proves nothing.
Pn_dbc = Models.Model("pn_dbc",
  id   = Models.IDField(),
  note = Models.CharField(db_column = "obs"),
  qty  = Models.IntegerField(null = true),
)

PormG.Models.set_models(@__MODULE__, "pn_mock")
end

const PN = PnModels
import PormG.QueryBuilder: inspect_query, Count, Sum, Exists, Value

const _PN_BACKENDS = (("PostgreSQL", _PN_PG, :postgres), ("SQLite", _PN_SL, :sqlite))

# ─────────────────────────────────────────────────────────────────────────────
# Symptom 1: distinct names over one expression render as TWO columns (#441)
# Each of these emitted the first name twice and dropped the second, on both backends, with no
# error. The `count(...) == 1` assertions are the discriminating half: asserting only that both
# names appear would pass on a build that emitted one of them twice.
# ─────────────────────────────────────────────────────────────────────────────
const _PN_DISTINCT = [
  ("two aliases over one local column", ("gg", "hh"),
   () -> begin q = PN.Pn_child.objects; q.values("gg" => "note", "hh" => "note"); q end),
  ("a bare field then an alias over it", ("note", "gg"),
   () -> begin q = PN.Pn_child.objects; q.values("note", "gg" => "note"); q end),
  ("two aliases over one JOIN path", ("s1", "s2"),
   () -> begin q = PN.Pn_child.objects; q.values("s1" => "parent__sku", "s2" => "parent__sku"); q end),
]

@testset "distinct names over one expression render both (#441)" begin
  for (label, (a, b), build_q) in _PN_DISTINCT
    @testset "$label" begin
      for (backend, conn, kind) in _PN_BACKENDS
        sql = inspect_query(build_q(); connection = conn)[:sql_text]
        @test occursin("as \"$(a)\"", sql)
        @test occursin("as \"$(b)\"", sql)
        # Exactly once each — the bug rendered the first name twice.
        @test count("as \"$(a)\"", sql) == 1
        @test count("as \"$(b)\"", sql) == 1
      end
    end
  end

  # Two aliases over one join path must still produce ONE join, not two. The memo's real job.
  sql = inspect_query(
    (() -> begin q = PN.Pn_child.objects; q.values("s1" => "parent__sku", "s2" => "parent__sku"); q end)();
    connection = _PN_SL)[:sql_text]
  @test count("LEFT JOIN", sql) == 1
end

# ─────────────────────────────────────────────────────────────────────────────
# Symptom 2: two projections may not share an output name (#441)
# The parameter-carrying shape is the severe one — it is why this is priority:high rather than a
# cosmetic drop. `_aggregate` is included because it forwards user pairs into `_values!` and
# validated everything EXCEPT uniqueness, so it rode the same collapse.
# ─────────────────────────────────────────────────────────────────────────────
const _PN_DUPES = [
  ("two aggregates under one name", "n",
   () -> begin q = PN.Pn_child.objects; q.values("note", "n" => Count("id"), "n" => Sum("qty")); q end),
  ("two Exists under one name", "h",
   () -> begin
     i1 = PN.Pn_parent.objects; i1.values("id"); i1.filter("sku" => "AAA")
     i2 = PN.Pn_parent.objects; i2.values("id"); i2.filter("sku" => "BBB")
     q = PN.Pn_child.objects; q.values("note", "h" => Exists(i1), "h" => Exists(i2)); q
   end),
  ("the same field named twice", "note",
   () -> begin q = PN.Pn_child.objects; q.values("note", "note"); q end),
  # Renders correctly today — the SQLText branch never consults the memo. Refused anyway, by
  # decision, so the rule has no per-kind exception. This is a capability removal, not a bug fix.
  ("two Value() literals under one name", "lbl",
   () -> begin q = PN.Pn_child.objects; q.values("lbl" => Value("a"), "lbl" => Value("b")); q end),
]

@testset "duplicate output names are refused (#441)" begin
  for (label, name, build_q) in _PN_DUPES
    @testset "$label" begin
      for (backend, conn, kind) in _PN_BACKENDS
        err = try
          inspect_query(build_q(); connection = conn)
          nothing
        catch e
          e
        end
        @test err isa PormG.QueryBuildError
        msg = sprint(showerror, err)
        @test occursin(name, msg)          # names the colliding output column
        @test occursin("values()", msg)    # and where to fix it
      end
    end
  end

  # aggregate() forwards its pairs into _values!, so it inherits the check rather than needing
  # its own. Without this, a duplicate alias there would still collapse.
  @test_throws PormG.QueryBuildError PN.Pn_parent.objects.aggregate("t" => Sum("id"), "t" => Count("id"))
end

# ─────────────────────────────────────────────────────────────────────────────
# `"*"` is compared as PHYSICAL columns, not declared field names (#441)
# `Pn_dbc.note` carries `db_column = "obs"`, so the star's contribution is `obs`. That makes a
# `field_names`-based check wrong in BOTH directions, and this testset pins both — a check that
# compared declared names would fail the first assertion and the second.
# ─────────────────────────────────────────────────────────────────────────────
@testset "the star is compared by physical column name (#441)" begin
  @test PN.Pn_dbc.field_names == ["id", "note", "qty"]
  @test [Models.field_db_column(PN.Pn_dbc.fields[f], f) for f in PN.Pn_dbc.field_names] ==
        ["id", "obs", "qty"]

  # FALSE-NEGATIVE direction: `obs` is not a declared field name, but the star emits it — collision.
  @test_throws PormG.QueryBuildError inspect_query(
    (() -> begin q = PN.Pn_dbc.objects; q.values("*", "obs" => "qty"); q end)(); connection = _PN_SL)

  # FALSE-POSITIVE direction: `note` IS a declared field name, but the star emits `obs`, so the
  # output columns are id/obs/qty/note — all distinct, and the query is legal.
  sql = inspect_query(
    (() -> begin q = PN.Pn_dbc.objects; q.values("*", "note" => "qty"); q end)(); connection = _PN_SL)[:sql_text]
  @test occursin("\"Tb\".*", sql)
  @test occursin("as \"note\"", sql)

  # A field with no db_column collides with the star under its own name.
  @test_throws PormG.QueryBuildError inspect_query(
    (() -> begin q = PN.Pn_dbc.objects; q.values("*", "qty"); q end)(); connection = _PN_SL)

  # Two stars collide with themselves.
  @test_throws PormG.QueryBuildError inspect_query(
    (() -> begin q = PN.Pn_dbc.objects; q.values("*", "*"); q end)(); connection = _PN_SL)
end

# ─────────────────────────────────────────────────────────────────────────────
# Non-colliding shapes are unaffected (#441 controls)
# A check that refused too much would satisfy every assertion above. `values("*", "<joined path>")`
# is the shape every real caller in this repo and its docs actually uses.
# ─────────────────────────────────────────────────────────────────────────────
@testset "non-colliding projections still render (#441 control)" begin
  for (backend, conn, kind) in _PN_BACKENDS
    for build_q in (
      () -> begin q = PN.Pn_child.objects; q.values("n" => "note"); q end,
      () -> begin q = PN.Pn_child.objects; q.values("note", "s" => "parent__sku"); q end,
      () -> begin q = PN.Pn_child.objects; q.values("*", "parent__sku"); q end,
      () -> begin q = PN.Pn_child.objects; q.values("note", "n" => Count("id")); q end,
      () -> begin q = PN.Pn_child.objects; q.values("lbl" => Value("a")); q end,
    )
      insp = inspect_query(build_q(); connection = conn)
      @test !isempty(insp[:sql_text])
      assert_marker_count(insp, kind)
    end
  end
end
