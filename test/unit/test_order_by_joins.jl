"""
Unit coverage for #404: `order_by()` on a join path that is NEITHER filtered NOR projected must emit
the join it needs.

`build` (`src/querybuilder/build_query.jl`) used to render `instruct.row_join` into SQL *before*
resolving ORDER BY. A path named only by `order_by()` falls past `get_order_query`'s `instruc.cache`
branch into `_get_select_query` -> `_build_row_join`, which APPENDS a new `row_join` entry and hands
back a selector qualified with a brand-new alias. The render had already run, so that entry never
became SQL and the alias survived only in the ORDER BY text:

    SELECT "Tb"."note" as "note"
    FROM "obj_child" as "Tb"
    ORDER BY "Tb_1"."sku" ASC NULLS LAST     -- "Tb_1" is never joined

PostgreSQL rejects that with `missing FROM-clause entry for table "tb_1"`, SQLite with
`no such column` — a loud failure at execution, not silent wrong rows. The fix moves
`get_order_query` ahead of `build_row_join_sql_text`.

Moving it exposed further defects in `build_row_join_sql_text`, all covered by the `cjoin` testsets
at the bottom of this file and none reachable before, because nothing in the suite combined `cjoin`
with `order_by`:

  - resolving ORDER BY early let it poison `instruc.cache`, which Phase 1 reads to render ON
    conditions, putting a bare projection alias inside an ON clause;
  - it defeated Phase 1b's forward-reference relocation, which keyed on *when* a join was appended
    rather than on the order it is emitted in;
  - and repairing that exposed two more in the relocation itself — it moved an extra to the FIRST
    later join it named rather than the LAST, and it matched an alias by a bare `"name"` test that
    also hits a like-named COLUMN.

The last three are all reachable on `origin/main` too (through `values()` rather than `order_by()`),
so those repairs fix pre-existing bugs as well as the ones this change would have introduced.

Why it survived this long: the COMMON shapes never reach the discovery branch. Ordering a column you
also `values()` or also `filter()` finds the path in `instruc.cache` and reuses the already-rendered
selector. Both are pinned below as controls, and both must stay byte-identical — a "fix" that works
by making every order term build its own join would satisfy the first three testsets here and
quietly double-join the rest of the suite.

All assertions render through mock PostgreSQL/SQLite connections — no live database. The execution
half (the query actually returning rows on both backends) lives in
`test/integration/test_selection.jl`, because the pre-fix failure was at execution time.

Sibling coverage:
  - `test_order_by_nulls.jl`        -> #75 NULL placement on the rendered term.
  - `test_sqlorder_orientation.jl`  -> #77 orientation whitelist.
  - `test_inspect_query.jl`         -> #76 DISTINCT + ORDER BY projection guard.
  - `test_cte_db_column.jl`         -> the same CTE order_by path, with `db_column` in play.
"""

using Test
using PormG
using PormG.Models

# Dedicated mock connections + config key: `runtests.jl` includes ~50 files into one `Main`, so a
# shared name would let another file's settings decide this file's dialect. Only the connection TYPE
# matters — dispatch picks SQLite vs PostgreSQL rendering.
struct ObjJoinMockSQLite <: PormG.PormGSQLite end
struct ObjJoinMockPostgres <: PormG.PormGPostgres end
const _OBJ_SL = ObjJoinMockSQLite()
const _OBJ_PG = ObjJoinMockPostgres()
# ORDER BY renders NULL placement via a library-version probe (#75); pin a modern version so
# order_by works on the mock without a live driver (same pattern as test_cte_db_column.jl).
PormG.backend_sqlite_version(::ObjJoinMockSQLite) = 3045000

PormG.config["obj_join_mock"] = PormG.Configuration.Settings(
  connections = _OBJ_PG, change_data = true, db_def_folder = "obj_join_mock",
)

# Inline fixtures in their own module: `set_models` is REQUIRED here (not a style choice), because
# `_build_row_join` reads `instruct.object.model._module::Module` — a bare `Model(...)` leaves
# `_module === nothing` and TypeErrors the moment a join renders.
module ObjJoinModels
import PormG
import PormG.Models

Par = Models.Model("obj_parent",
  id   = Models.IDField(),
  sku  = Models.CharField(),
  name = Models.CharField(null = true),
)

# `related_name = "kids"` is the accessor the reverse-relation testset orders through.
Chi = Models.Model("obj_child",
  id     = Models.IDField(),
  parent = Models.ForeignKey(Par, on_delete = "CASCADE", related_name = "kids", null = true),
  note   = Models.CharField(null = true),
)

# A three-level chain for the `cjoin` cases. Separate from Par/Chi above because `cjoin`'s target
# check compares against `Model.name` (the TABLE name) while its lookup goes by module binding, so
# the two only agree when the binding is spelled like the table — PormG's own generated convention.
# Four levels, because pinning "relocate to the LAST referenced join" needs an ON extra that names
# TWO joins emitted after the one it starts on.
Cj_great = Models.Model("cj_great",
  id  = Models.IDField(),
  tag = Models.CharField(),
)

Cj_grand = Models.Model("cj_grand",
  id    = Models.IDField(),
  code  = Models.CharField(),
  great = Models.ForeignKey(Cj_great, on_delete = "CASCADE", related_name = "cj_grands", null = true),
)

Cj_parent = Models.Model("cj_parent",
  id          = Models.IDField(),
  sku         = Models.CharField(),
  grandparent = Models.ForeignKey(Cj_grand, on_delete = "CASCADE", related_name = "cj_pars", null = true),
)

Cj_child = Models.Model("cj_child",
  id     = Models.IDField(),
  parent = Models.ForeignKey(Cj_parent, on_delete = "CASCADE", related_name = "cj_kids", null = true),
  note   = Models.CharField(null = true),
)

PormG.Models.set_models(@__MODULE__, "obj_join_mock")
end

const OBJ = ObjJoinModels
import PormG.QueryBuilder: inspect_query, Q, F

# `count` over a literal String, not a Regex — a needle carrying regex syntax would otherwise
# silently change what is matched. "JOIN" is a substring of "LEFT JOIN", so this counts joins.
_obj_joins(sql::AbstractString) = count("JOIN", sql)

# ─────────────────────────────────────────────────────────────────────────────
# ORDER BY join emission: a forward ForeignKey path named ONLY by order_by()
# The ordered column is in neither `values()` nor `filter()`, so `get_order_query` resolves it for
# the first time and discovers the join. Asserting the JOIN clause explicitly is the whole point:
# an `occursin("Tb_1", sql)` alone passed BEFORE the fix too — the alias was always in the ORDER BY.
# ─────────────────────────────────────────────────────────────────────────────
@testset "order_by() on a forward-FK path emits its join (#404)" begin
  for (label, conn) in (("PostgreSQL", _OBJ_PG), ("SQLite", _OBJ_SL))
    @testset "$label" begin
    q = OBJ.Chi.objects
    q.values("note")
    q.order_by("parent__sku")

    sql = inspect_query(q; connection = conn)[:sql_text]

    # The join the ORDER BY term needs, carrying the alias the term actually references.
    @test occursin("LEFT JOIN \"obj_parent\" AS \"Tb_1\" ON \"Tb\".\"parent\" = \"Tb_1\".\"id\"", sql)
    @test occursin("ORDER BY \"Tb_1\".\"sku\" ASC", sql)
    # Exactly one — resolving the path must not add a second copy beside a cached one.
    @test _obj_joins(sql) == 1
    # The path is ordered, not selected: it must not leak into the projection.
    @test occursin("\"Tb\".\"note\" as \"note\"", sql)
    @test !occursin("as \"parent__sku\"", sql)
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# ORDER BY join emission: a REVERSE relation named only by order_by()
# The same defect with the join direction flipped — the ON sides swap to
# `"Tb"."id" = "Tb_1"."parent"`. Covered separately because a reverse path takes a different branch
# of `_build_row_join` than a forward FK, and only the branch that runs can be vouched for.
# ─────────────────────────────────────────────────────────────────────────────
@testset "order_by() on a reverse-relation path emits its join (#404)" begin
  q = OBJ.Par.objects
  q.values("name")
  q.order_by("kids__note")

  sql = inspect_query(q)[:sql_text]

  @test occursin("LEFT JOIN \"obj_child\" AS \"Tb_1\" ON \"Tb\".\"id\" = \"Tb_1\".\"parent\"", sql)
  @test occursin("ORDER BY \"Tb_1\".\"note\" ASC", sql)
  @test _obj_joins(sql) == 1
end

# ─────────────────────────────────────────────────────────────────────────────
# ORDER BY join emission: a CTE column named only by order_by()
# A CTE join is an ordinary `row_join` entry emitted by `build_row_join_sql_text` like any other —
# there is no separate CTE join-rendering path that could have rescued this shape. The outer query
# is aliased "R1", not "Tb", because `build_cte_clause` runs first and the CTE body consumes the
# base alias. `test_cte_db_column.jl` orders through a CTE too but filters it as well; this is the
# unfiltered, unprojected shape that testset deliberately avoided depending on.
# ─────────────────────────────────────────────────────────────────────────────
@testset "order_by() on a CTE column emits its join (#404)" begin
  cte = OBJ.Par.objects
  cte.values("id", "sku")

  q = OBJ.Par.objects
  q.with("ev" => cte, join_field = "id" => "id")
  q.values("name")
  q.order_by("ev__sku")          # the only reference to the CTE besides the join_field itself

  sql = inspect_query(q)[:sql_text]

  @test occursin("WITH \"ev\" AS (", sql)
  @test occursin("LEFT JOIN \"ev\" AS \"R1_1\" ON \"R1\".\"id\" = \"R1_1\".\"id\"", sql)
  @test occursin("ORDER BY \"R1_1\".\"sku\" ASC", sql)
  @test _obj_joins(sql) == 1
end

# ─────────────────────────────────────────────────────────────────────────────
# Control: ordering a PROJECTED join column is unchanged
# This shape always worked — `get_select_query` built the join and cached the path, so
# `get_order_query` reuses the resolved selector and discovers nothing. Pinned because the failure
# mode of a careless fix is a SECOND join for the same path, which no assertion above would catch.
# ─────────────────────────────────────────────────────────────────────────────
@testset "ordering a projected join column still emits exactly one join (#404 control)" begin
  q = OBJ.Chi.objects
  q.values("note", "s" => "parent__sku")
  q.order_by("parent__sku")

  sql = inspect_query(q)[:sql_text]

  @test occursin("LEFT JOIN \"obj_parent\" AS \"Tb_1\" ON \"Tb\".\"parent\" = \"Tb_1\".\"id\"", sql)
  @test occursin("\"Tb_1\".\"sku\" as \"s\"", sql)
  @test occursin("ORDER BY \"Tb_1\".\"sku\" ASC", sql)
  @test _obj_joins(sql) == 1
end

# ─────────────────────────────────────────────────────────────────────────────
# Control: ordering a FILTERED join column is unchanged
# The other always-correct shape, and the one the issue used to expose the defect: adding a filter
# on the same path was the single difference that made the join appear. The WHERE placeholder and
# the bound value are asserted too — `get_order_query` now runs across the `:where`/`:join` context
# switches, and that move must not re-route a parameter, drop one, or bind the same value twice.
# ─────────────────────────────────────────────────────────────────────────────
@testset "ordering a filtered join column still emits exactly one join (#404 control)" begin
  q = OBJ.Chi.objects
  q.values("note")
  q.filter("parent__sku" => "X")
  q.order_by("parent__sku")

  res = inspect_query(q)
  sql = res[:sql_text]

  @test occursin("LEFT JOIN \"obj_parent\" AS \"Tb_1\" ON \"Tb\".\"parent\" = \"Tb_1\".\"id\"", sql)
  @test occursin("WHERE \"Tb_1\".\"sku\" = \$1", sql)
  @test occursin("ORDER BY \"Tb_1\".\"sku\" ASC", sql)
  @test _obj_joins(sql) == 1
  # Bound once: the ORDER BY term reuses the cached selector rather than re-parameterizing the path
  # it shares with the WHERE clause.
  @test res[:parameters] == ["X"]
end

# ─────────────────────────────────────────────────────────────────────────────
# cjoin + order_by: the ORDER BY term must not poison the cached selector (#404)
# `get_order_query` degrades `field` to the bare SELECT alias when the ordered path is also
# projected — legal in ORDER BY, invalid anywhere else. Because #404 moved that call ahead of
# `build_row_join_sql_text`, the render now READS that cache: Phase 1 resolves cjoin ON conditions
# through `_get_filter_query(::SQLTypeField)`, which returns `instruc.cache[_as].field` verbatim.
# Caching the degraded form put a projection alias inside an ON clause, which both backends reject.
# Nothing in the suite combined cjoin with order_by, which is exactly why that shipped green once.
# ─────────────────────────────────────────────────────────────────────────────
@testset "order_by() on a projected path does not corrupt a cjoin ON clause (#404)" begin
  q = OBJ.Cj_child.objects
  q.values("note", "parent__sku")                                   # unaliased -> _as == the path
  q.cjoin("parent" => "Cj_parent", filters = ["sku" => "X"], warn = false)
  q.order_by("parent__sku")                                         # same path, so found_in_select

  sql = inspect_query(q)[:sql_text]

  # The ON condition must name the qualified column, never the SELECT alias.
  @test occursin("ON \"Tb\".\"parent\" = \"Tb_1\".\"id\" AND \"Tb_1\".\"sku\" = \$1", sql)
  @test !occursin("AND \"parent__sku\" = ", sql)
  # The ORDER BY may still use the alias — that is the one place it is valid.
  @test occursin("ORDER BY \"parent__sku\" ASC", sql)
  @test _obj_joins(sql) == 1
end

# ─────────────────────────────────────────────────────────────────────────────
# cjoin + order_by: a deep ON condition must not forward-reference a later join (#404)
# Phase 2 emits joins in `row_join` order, so an ON extra naming a join emitted LATER is invalid SQL
# ("invalid reference to FROM-clause entry"). Phase 1b relocates such extras — but it used to scope
# the search to entries created DURING Phase 1 (`dep_idx > n_before`). Once order_by resolves the
# deep path up front, Phase 1 dedups onto the existing entry instead of creating one, the window is
# empty, and the extra stays on the wrong join. Phase 1b now keys on index order, which covers this
# and the pre-existing `values()` shape below identically.
# ─────────────────────────────────────────────────────────────────────────────
@testset "a deep cjoin ON condition lands on the join it references (#404)" begin
  # (a) reached via order_by — the shape #404's reordering exposed.
  ordered = OBJ.Cj_child.objects
  ordered.values("note")
  ordered.cjoin("parent" => "Cj_parent", filters = ["grandparent__code" => "Z"], warn = false)
  ordered.order_by("parent__grandparent__code")

  sql = inspect_query(ordered)[:sql_text]

  # The extra belongs on cj_grand's ON clause (emitted second), not on cj_parent's (emitted first).
  @test occursin("LEFT JOIN \"cj_grand\" AS \"Tb_2\" ON \"Tb_1\".\"grandparent\" = \"Tb_2\".\"id\" AND \"Tb_2\".\"code\" = \$1", sql)
  @test !occursin("\"Tb\".\"parent\" = \"Tb_1\".\"id\" AND \"Tb_2\"", sql)
  @test occursin("ORDER BY \"Tb_2\".\"code\" ASC", sql)
  @test _obj_joins(sql) == 2

  # (b) reached via values() — the same forward reference, and it pre-dates #404: projecting the
  # deep path builds the deeper join up front just as ordering by it now does. Fixed by the same
  # Phase 1b change, so it is pinned here rather than left to regress silently.
  projected = OBJ.Cj_child.objects
  projected.values("note", "parent__grandparent__code")
  projected.cjoin("parent" => "Cj_parent", filters = ["grandparent__code" => "Z"], warn = false)

  psql = inspect_query(projected)[:sql_text]

  @test occursin("LEFT JOIN \"cj_grand\" AS \"Tb_2\" ON \"Tb_1\".\"grandparent\" = \"Tb_2\".\"id\" AND \"Tb_2\".\"code\" = \$1", psql)
  @test !occursin("\"Tb\".\"parent\" = \"Tb_1\".\"id\" AND \"Tb_2\"", psql)
  @test _obj_joins(psql) == 2
end

# ─────────────────────────────────────────────────────────────────────────────
# Phase 1b settles an ON extra on the last join it references, however many hops away (#404)
# One `Q(...)` extra can name several joins emitted after the one carrying it, and it has to end up
# on the last of them or the rest stay forward-referenced. This shape is broken on origin/main —
# it emits `"Tb_3"` inside `Tb_2`'s ON clause — so this is a pre-existing fix, not just a guard on
# #404's own change. What it pins is the FIXED POINT, not the search direction: the relocation loop
# searches descending to get there in one move, but ascending would cascade to the same place via
# the outer loop's revisit, so no test can tell the two apart. Do not read this as pinning "descending".
# ─────────────────────────────────────────────────────────────────────────────
@testset "an ON extra relocates onto the last join it references (#404)" begin
  q = OBJ.Cj_child.objects
  q.values("note")
  q.cjoin("parent" => "Cj_parent",
          filters = [Q("grandparent__code" => "Z", "grandparent__great__tag" => "T")], warn = false)

  sql = inspect_query(q)[:sql_text]

  # The extra names Tb_2 and Tb_3; it must ride on Tb_3, the later of the two.
  @test occursin("LEFT JOIN \"cj_great\" AS \"Tb_3\" ON \"Tb_2\".\"great\" = \"Tb_3\".\"id\" AND (\"Tb_2\".\"code\" = \$1 AND \"Tb_3\".\"tag\" = \$2)", sql)
  # ...and Tb_2's own ON clause must be left bare, with no forward reference to Tb_3.
  @test occursin("LEFT JOIN \"cj_grand\" AS \"Tb_2\" ON \"Tb_1\".\"grandparent\" = \"Tb_2\".\"id\" \n", sql)
  @test !occursin("\"Tb_1\".\"grandparent\" = \"Tb_2\".\"id\" AND", sql)
  @test _obj_joins(sql) == 3
end

# ─────────────────────────────────────────────────────────────────────────────
# Phase 1b matches an ALIAS, not a column that happens to share its name (#404)
# The relocation search tests the rendered extra for the dependency's alias. Every column reference
# renders as `"alias"."col"`, so a bare `"name"` test also hits the COLUMN half: a `cjoin_on` alias
# spelled like a column (`alias = "code"` vs `"Tb_2"."code"`) then drags an unrelated LEFT JOIN's ON
# filter onto itself. Valid SQL, wrong rows, no error — strictly worse than the forward reference it
# replaced. The guard is the trailing dot, and this testset is what holds it in place.
# ─────────────────────────────────────────────────────────────────────────────
@testset "relocation matches an alias, not a like-named column (#404)" begin
  build(alias) = begin
    q = OBJ.Cj_child.objects
    q.values("note", "parent__grandparent__code")
    q.cjoin("parent" => "Cj_parent", filters = ["grandparent__code" => "Z"], warn = false)
    q.cjoin_on("Cj_grand", alias = alias, join_type = "INNER", on = [Q(F("$alias.id") == F("id"))])
    inspect_query(q)[:sql_text]
  end

  # `zz` collides with nothing; `code` is spelled exactly like cj_grand's column. The two must
  # render identically apart from the alias itself — the alias name cannot decide where a filter goes.
  control   = build("zz")
  colliding = build("code")

  for (label, sql) in (("zz", control), ("code", colliding))
    # The cjoin's filter belongs on the LEFT JOIN that owns the column, in both cases.
    @test occursin("LEFT JOIN \"cj_grand\" AS \"Tb_2\" ON \"Tb_1\".\"grandparent\" = \"Tb_2\".\"id\" AND \"Tb_2\".\"code\" = \$1", sql)
  end
  # And the cjoin_on join must carry only its own ON condition, never the migrated filter.
  @test occursin("INNER JOIN \"cj_grand\" AS \"code\" ON ((\"code\".\"id\" = \"Tb\".\"id\")) \n", colliding)
  @test !occursin("\"code\".\"id\" = \"Tb\".\"id\")) AND", colliding)
  # Same shape either way: the alias name must not change how many joins are emitted, nor which one
  # the filter rides on. (A whole-string comparison is not available here — swapping "code" for "zz"
  # would also rewrite the like-named COLUMN, which is the very ambiguity under test.)
  @test _obj_joins(control) == _obj_joins(colliding) == 3
  @test count("= \$1", control) == count("= \$1", colliding) == 1
end
