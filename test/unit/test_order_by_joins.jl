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

The last four testsets cover two further defects in the same relocation machinery. Both are
pre-existing and neither was caused by #404:

  - #421 — relocation changes the order extras are EMITTED in, while Phase 1 had already bound
    their parameters in `row_join` order. PostgreSQL is immune (`\$N` numbering travels with the
    text); SQLite flattens the `:join` bucket in BINDING order, so a relocated extra bound its
    neighbour's value. Valid SQL, wrong rows, no error, on one backend only.
  - #424 — Phase 2's CROSS-join branch emits and `continue`s without consulting
    `on_clause_extras`, so a predicate that landed there was silently dropped and the join stopped
    filtering. A CROSS-joined CTE acquires one when its NAME collides with a join key (a `cjoin`
    path, a `cjoin_on` alias, or an `on()` path) or when Phase 1b relocates a fragment naming its
    alias. Four producers are pinned; the testset explains why it pins that invariant rather than a
    list of call shapes.

All assertions render through mock PostgreSQL/SQLite connections — no live database. The execution
half (the query actually returning rows on both backends) lives in
`test/integration/test_selection.jl` and `test/integration/test_cjoin.jl`, because the pre-fix
failures were at execution time.

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

# ─────────────────────────────────────────────────────────────────────────────
# A relocated ON extra binds its OWN value (#421)
# Phase 1 walks `row_join` in index order and binds as it resolves; Phase 1b then moves a fragment
# onto a later join, changing EMISSION order. Nothing reconciled the two. PostgreSQL never noticed —
# `$N` numbering travels with the text — but SQLite flattens the `:join` bucket in BINDING order, so
# the first `?` took the relocated fragment's value and the two conditions swapped. Valid SQL, wrong
# rows, no error, and on one backend only.
#
# The control pair is what earns this testset its length: the SAME two filters, only their order in
# the `filters` vector swapped. The deep one relocates and the shallow one does not, so pre-fix (a)
# was wrong while (b) was already right — a "fix" that reversed the bucket wholesale would trade one
# failure for the other and still pass a single-case test.
# ─────────────────────────────────────────────────────────────────────────────
_cj_two_depth(filters) = begin
  q = OBJ.Cj_child.objects
  q.values("note")
  q.cjoin("parent" => "Cj_parent", filters = filters, warn = false)
  q
end

@testset "a relocated ON extra binds its own value (#421)" begin
  # (a) the issue's shape — the deep filter is listed FIRST, so it binds first and emits last.
  sl = inspect_query(_cj_two_depth(["grandparent__code" => "ZZZ", "sku" => "SSS"]); connection = _OBJ_SL)
  sql = sl[:sql_text]

  # Pin the emission order the bucket has to match rather than trusting it: cj_parent's ON carries
  # `sku` and is emitted first, cj_grand's carries `code` and is emitted second.
  @test occursin("\"Tb_1\".\"sku\" = ?", sql)
  @test occursin("\"Tb_2\".\"code\" = ?", sql)
  @test first(findfirst("\"Tb_1\".\"sku\" = ?", sql)) < first(findfirst("\"Tb_2\".\"code\" = ?", sql))

  # ...so the bucket must read the sku value first. Pre-fix it was ["ZZZ", "SSS"] — swapped.
  @test sl[:parameter_buckets][:join] == ["SSS", "ZZZ"]
  @test count(==('?'), sql) == 2                     # no orphan marker, no orphan value

  # (b) control: the same two filters the other way round. Binding order already matched emission
  # order here, so this was correct BEFORE the fix and must be byte-identical after it.
  rev = inspect_query(_cj_two_depth(["sku" => "SSS", "grandparent__code" => "ZZZ"]); connection = _OBJ_SL)
  @test rev[:parameter_buckets][:join] == ["SSS", "ZZZ"]
  @test rev[:sql_text] == sql        # the rendered text never depended on the filter order

  # (c) PostgreSQL is the oracle: it was always right and must not move. The values stay in BIND
  # order and the explicit numbering carries the mapping — which is why $2 lands on sku, not $1.
  pg = inspect_query(_cj_two_depth(["grandparent__code" => "ZZZ", "sku" => "SSS"]); connection = _OBJ_PG)
  @test occursin("\"Tb_1\".\"sku\" = \$2", pg[:sql_text])
  @test occursin("\"Tb_2\".\"code\" = \$1", pg[:sql_text])
  @test pg[:parameters] == ["ZZZ", "SSS"]
end

# ─────────────────────────────────────────────────────────────────────────────
# A relocated ON extra carries ALL of its values, in order (#421)
# One fragment can bind more than one value, so "move the fragment's parameter" is not the same
# invariant as "move the fragment's parameter RUN". `@in` over three codes beside a single-valued
# `sku` makes the split 3-and-1: pre-fix the bucket read [Z,Y,X,SSS] against markers emitted
# sku-first, so all four misbound. A fix that relocated only the first value of a run would still
# satisfy the one-value-each testset above.
# ─────────────────────────────────────────────────────────────────────────────
@testset "a relocated ON extra carries its whole parameter run (#421)" begin
  r = inspect_query(_cj_two_depth(["grandparent__code__@in" => ["Z", "Y", "X"], "sku" => "SSS"]);
                    connection = _OBJ_SL)
  @test r[:parameter_buckets][:join] == ["SSS", "Z", "Y", "X"]
  @test count(==('?'), r[:sql_text]) == 4
end

# ─────────────────────────────────────────────────────────────────────────────
# The fix reorders BETWEEN fragments, never WITHIN one (#421 control)
# A single `Q(...)` spanning two depths is ONE fragment: Phase 1b relocates it whole, so its two
# values were always adjacent and in the right order. Splitting the same predicates into two `Q`s
# makes them two fragments, and only then does one relocate past the other. Both are pinned because
# they are the pair that tells "reordered the runs" apart from "reordered the values".
# ─────────────────────────────────────────────────────────────────────────────
@testset "relocation reorders fragments, not values within one (#421 control)" begin
  one_q = inspect_query(_cj_two_depth([Q("grandparent__code" => "Z", "sku" => "S")]); connection = _OBJ_SL)
  @test one_q[:parameter_buckets][:join] == ["Z", "S"]      # unchanged by the fix

  two_q = inspect_query(_cj_two_depth([Q("grandparent__code" => "Z"), Q("sku" => "S")]); connection = _OBJ_SL)
  @test two_q[:parameter_buckets][:join] == ["S", "Z"]      # two fragments, so the deep one moves
end

# ─────────────────────────────────────────────────────────────────────────────
# An ON predicate that lands on a CROSS-joined CTE is refused, not dropped (#424)
# Phase 2's CROSS branch has no ON clause to merge `on_clause_extras[idx]` into, and it `continue`d
# without consulting the dict — so the predicate vanished, the join stopped filtering, and the query
# returned row-multiplied results with no error.
#
# This testset deliberately pins the INVARIANT rather than a list of call shapes. That list was
# written twice and wrong twice: first "unreachable by any query shape", then "two shapes" — each
# time an independent reviewer produced a shape it had missed. The invariant is:
#
#     a CROSS-joined CTE acquires an ON predicate when its NAME collides with a join key, or when
#     Phase 1b relocates a fragment that names its alias.
#
# "Join key" means a `custom_join` key, and `custom_join` is written at three unrelated sites —
# keyed by a `cjoin` PATH, a `cjoin_on` ALIAS, and an `on()` PATH. So a collision with any of them
# produces this, with or without a model-field collision and with or without any relocation at all.
# The producers below cover all four routes; a fifth `custom_join` writer would inherit the same
# behavior, and that is exactly why the emitted message names the collision rather than the method.
#
# Measured pre-fix (route A), this rendered:
#     INNER JOIN "cj_parent" AS "b2" ON ("b2"."sku" = "R1"."note")
#     CROSS JOIN "ev" AS "R1_1"
# — the predicate gone from the SQL while its value stayed orphaned in the `:join` bucket. #421
# makes that strictly worse before this guard makes it better: once values travel with their
# fragment the orphan disappears too, so the wrong query becomes perfectly well-formed. That is why
# the two land together.
# ─────────────────────────────────────────────────────────────────────────────
_ob_cte() = begin
  c = OBJ.Cj_grand.objects
  c.values("id", "code")
  c
end

_ob_parent_cte() = begin
  c = OBJ.Cj_parent.objects
  c.values("id", "sku")
  c
end

# (label, the CTE name the message must report, builder). Each must reach the SAME guard.
const _OB_424_PRODUCERS = [
  (
    "A: cjoin_on `on` names a CTE path (via Phase 1b relocation)", "ev",
    () -> begin
      q = OBJ.Cj_child.objects
      q.with("ev" => _ob_cte())                       # no join_field => CROSS JOIN (#44)
      q.values("note")
      # ONE predicate, and that is the point. This case used to need a second one as padding:
      # relocating the only predicate away emptied `b2`'s extras, and because `b2` sits at a lower
      # `row_join` index than the CTE, Phase 2 reached its "produced no ON conditions" guard before
      # the CROSS branch could report the actual cause. #435 hoisted this guard into Phase 1c, so
      # the cause now wins on ordering-independent grounds and the padding is gone. This is also
      # the issue's own reproduction, verbatim.
      q.cjoin_on("Cj_parent", alias = "b2", on = ["ev__code" => "Z"])
      q
    end,
  ),
  (
    "B: CTE name collides with a cjoin PATH (a model field; no relocation)", "parent",
    () -> begin
      q = OBJ.Cj_child.objects
      # "parent" is a ForeignKey field of Cj_child. Join resolution consults the CTE registry BEFORE
      # the model-field branch, so the CTE shadows the field's join entirely, and the cjoin then
      # hangs its filters on the CROSS entry as its own `on_conditions` — one row_join entry, empty
      # relocation window, `on_clause_extras` filled in Phase 1.
      q.with("parent" => _ob_parent_cte())
      q.values("note")
      q.cjoin("parent" => "Cj_parent", filters = ["sku" => "S"], warn = false)
      q
    end,
  ),
  (
    "C: CTE name collides with a cjoin_on ALIAS (no model field involved)", "b2",
    () -> begin
      q = OBJ.Cj_child.objects
      # "b2" is NOT a field of Cj_child — nothing is shadowed. The collision is with the cjoin_on
      # ALIAS, which is what `_cjoin_on` uses as its `custom_join` key. This is the producer that
      # proved a message blaming "a CTE named after a model FIELD" asserts something false.
      q.with("b2" => _ob_cte())
      q.values("note")
      q.cjoin_on("Cj_parent", alias = "b2", on = [F("b2.sku") == F("note")])
      q.filter("b2__code" => "X")                     # forces the CTE join to be built first
      q
    end,
  ),
  (
    "D: CTE name collides with an on() PATH declared BEFORE the .with()", "parent",
    () -> begin
      q = OBJ.Cj_child.objects
      # Order matters: `.with()` then `.on()` is refused earlier by `_resolve_join_target_model`,
      # which only sees CTEs declared so far. Reversed, that check never fires.
      q.on("parent", "sku" => "S")
      q.with("parent" => _ob_parent_cte())
      q.values("note", "parent__sku")
      q
    end,
  ),
]

@testset "an ON predicate landing on a CROSS-joined CTE is refused, not dropped (#424)" begin
  for (label, cte_name, build_q) in _OB_424_PRODUCERS
    @testset "$label" begin
      for (backend, conn) in (("PostgreSQL", _OBJ_PG), ("SQLite", _OBJ_SL))
        err = try
          inspect_query(build_q(); connection = conn)
          nothing
        catch e
          e
        end
        @test err isa PormG.QueryBuildError
        msg = sprint(showerror, err)

        # The message must describe the COLLISION, which is true of every producer — not the call
        # method, which is true of at most one. An earlier draft asserted "shadows a field"; that
        # passed here and was false for producer C.
        @test occursin("CROSS", msg)
        @test occursin("collides", msg)
        @test occursin("#44", msg)                # points at where the correlation belongs
        @test occursin(".filter(", msg)           # ...and at one of the three remedies
        # Names the offending CTE by the name the caller wrote, so they can find the
        # `.with(...)` to rename. This is per-producer on purpose: a message that named the CTE's
        # TABLE instead would be useless for renaming, and a hardcoded name would not notice.
        @test occursin(cte_name, msg)
        # Never blames the caller for a PormG bug: these are user-writable shapes, and the first
        # draft of this guard said "internal: ... please report" (review finding).
        @test !occursin("internal", lowercase(msg))
        @test !occursin("report", lowercase(msg))
      end
    end
  end

  # Control: a CROSS-joined CTE that never acquired a predicate must still render. Without this, a
  # guard written as an unconditional `throw` would satisfy every assertion above while breaking
  # every #44 query. (`test/unit/test_cte_ergonomics.jl` owns the full #44 coverage; this is the
  # local tripwire that the new `haskey` check did not turn every CROSS join into an error.)
  ok = OBJ.Cj_child.objects
  ok.with("ev" => _ob_cte())
  ok.values("note")
  ok.filter(F("note") == F("ev__code"))
  ok_sql = inspect_query(ok; connection = _OBJ_SL)[:sql_text]
  @test occursin("CROSS JOIN \"ev\"", ok_sql)
  @test !occursin(r"CROSS JOIN[^\n]*ON", ok_sql)
end

# ── #435: the anchor-less guard must say WHICH of two things went wrong ──────────────────────────
#
# `cjoin_on` renders its ON clause entirely from the caller's predicates — there is no equi-anchor
# to fall back on — so an empty extras list at emission time is fatal. Two unrelated causes reach
# that state, and one message described only the first:
#
#   1. the caller passed no predicates at all;
#   2. the caller passed some, and Phase 1b relocated every one onto a join emitted later.
#
# In case 2 the old text — "cjoin_on produced no ON conditions for alias 'b2'" — describes the
# internal state after relocation, and flatly contradicts what the caller wrote. It sent you looking
# for a missing argument that is right there in the call.
#
# Phase 1b mutates only the local `on_clause_extras`; `row_join` keeps its `on_conditions`. So the
# two cases stay distinguishable at the raise site with no extra bookkeeping, and `relocated_to`
# (recorded in Phase 1b) supplies the destination alias for the message.
#
# STRIP ANSI BEFORE MATCHING. `_emsg` keeps the SGR sequences when `Base.have_color` is true and
# drops them otherwise, so a needle that spans a color boundary — `"another cjoin_on"`, which is
# really `"another \e[4m\e[32mcjoin_on\e[0m"` — matches on a piped Windows run and fails on CI's
# Linux runner. That is exactly how these two testsets went green locally and red on CI, and the
# NEGATIVE assertions are worse: they pass for free wherever the escapes survive. Matching stripped
# text makes every assertion here mean the same thing on both.
_no_ansi(s::AbstractString) = replace(s, r"\e\[[0-9;]*m" => "")

@testset "cjoin_on distinguishes 'you passed none' from 'they all relocated' (#435)" begin

  # ── case 2: predicates given, all relocated away ──────────────────────────
  # The trigger is purely POSITIONAL: `b2`'s only predicate names a join that sits at a HIGHER
  # `row_join` index, so Phase 1b moves it there and `b2` is left holding nothing. Two ways to get
  # there, and the review of this change refuted a narrower claim that only the first counts:
  #
  #   - the referenced join does not exist yet and is created during Phase 1's resolution of that
  #     very condition (this fixture: an UNPROJECTED deep path), or
  #   - it already exists but is ordered later. For two `cjoin_on` aliases that ordering comes from
  #     `Dict` iteration over `custom_join`, i.e. from the alias STRINGS — declaring `b3` before
  #     `b2` and after it both yield `[b3, b2]`. Which of a pair raises is therefore decided by
  #     hashing, which is why this fixture uses the deep path instead: it is deterministic.
  #
  # For THIS fixture, projecting the path first would build those joins at LOWER indices and nothing
  # would relocate — but the query then renders an ON clause that never mentions `b2`, an
  # unconstrained join, so the error is the better outcome and neither the docs nor the message
  # offer projecting here. That is specific to a predicate naming no alias of its own; when the
  # predicate DOES name the join, projecting is the correct fix and both do recommend it — see the
  # branch testset below. A real join, not a CROSS CTE, so Phase 1c does not intercept.
  @testset "all predicates relocated onto a later join" begin
    for (backend, conn) in (("PostgreSQL", _OBJ_PG), ("SQLite", _OBJ_SL))
      q = OBJ.Cj_child.objects
      q.values("note")
      q.cjoin_on("Cj_parent", alias = "b2", on = ["parent__grandparent__code" => "Z"])

      err = try
        inspect_query(q; connection = conn)
        nothing
      catch e
        e
      end
      @test err isa PormG.QueryBuildError
      msg = _no_ansi(sprint(showerror, err))

      # The regression itself: it must NOT claim the caller supplied nothing.
      @test !occursin("produced no ON conditions", msg)

      @test occursin("b2", msg)          # the join left without an ON clause
      @test occursin("Tb_2", msg)        # …and where its predicate actually went
      @test occursin("#435", msg)
      # Same vocabulary as the #424 guard, which reaches this relocation from the other side.
      @test occursin("resolved onto", msg)
      @test occursin(".filter(", msg)    # one of the remedies
      # A user-writable shape is never the user's fault to report (see the #424 testset).
      @test !occursin("internal", lowercase(msg))
      @test !occursin("report", lowercase(msg))
    end
  end

  # ── the boundary: ONE predicate relocating is not an error ────────────────
  # Same deep path, plus a predicate that stays. `b2` keeps an ON clause, the relocated fragment
  # lands on the join it names, and nothing raises. Without this, a guard that fired whenever
  # ANY predicate relocated would pass every assertion above while breaking a working shape.
  @testset "a surviving predicate keeps the join renderable" begin
    for (backend, conn) in (("PostgreSQL", _OBJ_PG), ("SQLite", _OBJ_SL))
      q = OBJ.Cj_child.objects
      q.values("note")
      q.cjoin_on("Cj_parent", alias = "b2",
                 on = [F("b2.sku") == F("note"), "parent__grandparent__code" => "Z"])
      r = inspect_query(q; connection = conn)
      sql = r[:sql_text]
      @test occursin("JOIN \"cj_parent\" AS \"b2\" ON ", sql)
      @test occursin("\"b2\".\"sku\" = \"Tb\".\"note\"", sql)
      # the relocated fragment is merged into the ON of the join it references, not dropped
      @test occursin("\"Tb_2\".\"code\" = ", sql)
      # …and its value travels with it rather than being dropped or orphaned. Only ONE predicate
      # binds here, so this cannot observe #421-style REORDERING — `_cj_two_depth` above owns that.
      # What it does pin is that a relocated fragment still consumes exactly its own value, on both
      # backends, which is the half a text-only assertion cannot see.
      @test r[:parameters] == ["Z"]
    end
  end

  # ── the two branches give OPPOSITE advice, and the code must pick ─────────
  # Review of this change caught the message asserting one branch's remedy at both. The bit that
  # decides it: did any predicate that relocated ALSO name the join it left?
  #
  #   names its own alias too → a real correlation whose other side is built later. Projecting that
  #     path in `values(...)` builds it first and the clause renders AS WRITTEN. Verified below.
  #   names no alias of its own → nothing correlates the join. Projecting renders an ON clause that
  #     never mentions the alias — an unconstrained join, silent row multiplication (#448).
  #
  # So the same message must NOT recommend projecting in both cases, and these two testsets are
  # what stop it drifting back.
  @testset "the remedy branches on whether a relocated predicate named the alias" begin
    # self-referencing: predicate names b2 AND the deeper join
    q = OBJ.Cj_child.objects
    q.values("note")
    q.cjoin_on("Cj_parent", alias = "b2", on = [F("b2.sku") == F("parent__grandparent__code")])
    msg = try
      inspect_query(q; connection = _OBJ_SL); ""
    catch e
      _no_ansi(sprint(showerror, e))
    end
    @test occursin("does correlate", msg)
    @test occursin("Project that path", msg)
    @test !occursin("Do NOT", msg)            # projecting is the RIGHT fix here
    @test !occursin("No predicate you gave names", msg)
    # Second tripwire on the partition: with every destination a model join, the `cjoin_on`
    # sentence must be absent. Without this, misclassifying destinations the other way leaves
    # only one assertion standing (review finding).
    @test !occursin("another cjoin_on", msg)
    @test occursin("nothing relocates", msg)  # projecting IS the whole fix here, so promise it

    # …and projecting really does render it as written, which is what the advice promises
    ok = OBJ.Cj_child.objects
    ok.values("note", "parent__grandparent__code")
    ok.cjoin_on("Cj_parent", alias = "b2", on = [F("b2.sku") == F("parent__grandparent__code")])
    ok_sql = inspect_query(ok; connection = _OBJ_SL)[:sql_text]
    @test occursin("JOIN \"cj_parent\" AS \"b2\" ON (\"b2\".\"sku\" = \"Tb_2\".\"code\")", ok_sql)

    # non-self-referencing: the fixture shape, which must get the opposite advice
    q2 = OBJ.Cj_child.objects
    q2.values("note")
    q2.cjoin_on("Cj_parent", alias = "b2", on = ["parent__grandparent__code" => "Z"])
    msg2 = try
      inspect_query(q2; connection = _OBJ_SL); ""
    catch e
      _no_ansi(sprint(showerror, e))
    end
    @test occursin("No predicate you gave names", msg2)
    @test occursin("Do NOT instead project", msg2)
    @test !occursin("does correlate", msg2)
    # the remedy must not send them to .filter() without saying the cjoin_on has to go too —
    # `_cjoin_on` refuses an empty `on`, so moving every predicate out and leaving the call raises
    @test occursin("drop the", msg2)
  end

  # ── self-ref, but the destination has no path to project ──────────────────
  # "Project it in values(...)" is unactionable when the predicate relocated onto ANOTHER cjoin_on:
  # `values("b2…")` is not a thing. Caught in review — the self-ref remedy was written for a
  # model-path destination and asserted at both. The actionable move is the reverse: declare the
  # predicate on the join PormG emits LATER, so the reference points backwards.
  @testset "a cjoin_on destination gets the reorder remedy, not 'project it'" begin
    q = OBJ.Cj_child.objects
    q.values("note")
    q.cjoin_on("Cj_parent", alias = "b3", on = [F("b3.sku") == F("b2.sku")])
    q.cjoin_on("Cj_parent", alias = "b2", on = [F("b2.sku") == F("note")])
    msg = try
      inspect_query(q; connection = _OBJ_SL); ""
    catch e
      _no_ansi(sprint(showerror, e))
    end

    @test occursin("does correlate", msg)              # still the self-ref branch
    @test occursin("another cjoin_on", msg)            # …and it says why projecting is not it
    @test occursin("declare this predicate on", msg)
    @test !occursin("Project that path", msg)          # the unactionable advice must be absent
    @test !occursin("Project those paths", msg)

    # Moving the predicate is only HALF the rewrite, and the message must say the other half.
    # This branch fires only when the relocated predicates were ALL of them, so moving them out
    # leaves `b3` with an empty `on` — which `_cjoin_on` refuses — while dropping `b3` entirely
    # makes `b3.sku` unresolvable in the predicate that referenced it. Both dead ends were
    # reachable by following the first draft of this remedy literally (review finding); the same
    # omission had already been fixed once in the `.filter(...)` remedy.
    @test occursin("an ON predicate of its own", msg)
    @test occursin("requires at least one", msg)

    # …and the full rewrite the message describes actually renders: the shared predicate declared
    # on the LATER join, and `b3` given a predicate of its own.
    ok = OBJ.Cj_child.objects
    ok.values("note")
    ok.cjoin_on("Cj_parent", alias = "b3", on = [F("b3.sku") == F("note")])
    ok.cjoin_on("Cj_parent", alias = "b2", on = [F("b2.sku") == F("b3.sku")])
    ok_sql = inspect_query(ok; connection = _OBJ_SL)[:sql_text]
    @test occursin("JOIN \"cj_parent\" AS \"b3\" ON (\"b3\".\"sku\" = \"Tb\".\"note\")", ok_sql)
    @test occursin("JOIN \"cj_parent\" AS \"b2\" ON (\"b2\".\"sku\" = \"b3\".\"sku\")", ok_sql)
  end

  # ── mixed destinations: both remedies, and the projecting half must not overclaim ──
  # With one predicate relocating onto a model join and another onto a `cjoin_on`, projecting is
  # only half the fix. The tail "then nothing relocates and the ON clause renders as you wrote it"
  # is false there — the other predicate still moves — and it contradicts the sentence appended
  # right after it. Verified: projecting this shape does render, but `b3`'s ON is not as written.
  @testset "mixed destinations get both remedies without contradicting each other" begin
    q = OBJ.Cj_child.objects
    q.values("note")
    q.cjoin_on("Cj_parent", alias = "b3",
               on = [F("b3.sku") == F("b2.sku"), F("b3.sku") == F("parent__grandparent__code")])
    q.cjoin_on("Cj_parent", alias = "b2", on = [F("b2.sku") == F("note")])
    msg = try
      inspect_query(q; connection = _OBJ_SL); ""
    catch e
      _no_ansi(sprint(showerror, e))
    end

    @test occursin("Project that path", msg)             # the model-path destination
    @test occursin("another cjoin_on", msg)              # …and the cjoin_on one
    @test occursin("that predicate stays", msg)          # scoped promise
    @test !occursin("nothing relocates and the ON clause renders as you wrote it", msg)
  end

  # ── case 1: genuinely no predicates ───────────────────────────────────────
  # Not reachable through the public API — `_cjoin_on` refuses an empty `on` at the call site — so
  # reach it white-box by emptying the stored filters. `_build_cjoin_on_row_join` then omits the
  # `on_conditions` key entirely, which IS the state this branch is about.
  @testset "no predicates passed keeps its own message" begin
    q = OBJ.Cj_child.objects
    q.values("note")
    q.cjoin_on("Cj_parent", alias = "b2", on = [F("b2.sku") == F("note")])
    empty!(q.object.custom_join["b2"]["filters"])

    err = try
      inspect_query(q; connection = _OBJ_PG)
      nothing
    catch e
      e
    end
    @test err isa PormG.QueryBuildError
    msg = _no_ansi(sprint(showerror, err))
    @test occursin("produced no ON conditions", msg)   # unchanged wording
    @test occursin("b2", msg)
    @test !occursin("#435", msg)                       # not the relocation story
  end

  # ── control: an ordinary cjoin_on still renders ───────────────────────────
  # Without this, splitting the guard into two throws could satisfy every assertion above while
  # breaking the feature — the same trap the #424 testset's control covers.
  ok = OBJ.Cj_child.objects
  ok.values("note")
  ok.cjoin_on("Cj_parent", alias = "b2", on = [F("b2.sku") == F("note")])
  ok_sql = inspect_query(ok; connection = _OBJ_SL)[:sql_text]
  @test occursin("JOIN \"cj_parent\" AS \"b2\" ON ", ok_sql)
end
