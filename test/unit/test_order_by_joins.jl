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
    alias. **#444 removed the relocation route** — a predicate could no longer NAME a CTE, since a
    `CTE(...)` handle is refused inside every join clause, including as an `F` comparison operand.
    **#492 restored the `__` string spelling and left that route closed**: a CTE-rooted string is
    refused in `on()` / `cjoin()` / `cjoin_on()` as well, at build time
    (`_refuse_cte_string_in_join`), so the producer count is unchanged — this file pins three where
    it once pinned four. The testset carries the arithmetic.

#982 retired the machinery most of this describes. A `cjoin_on` condition is bound at build like a
path join's (#977): every row it names is built before the JOIN clauses render, each condition renders
on its own row in emission order, and Phases 1, 1b and 1c with `OnExtra` are gone. The testsets that
pinned relocation now pin the shapes it used to move or refuse, and what they render instead.

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
import PormG.QueryBuilder: inspect_query, Q, F, Joined

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
  q.order_by(CTE("ev", "sku"))          # the only reference to the CTE besides the join_field itself

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
# ("invalid reference to FROM-clause entry"). #404 met it with Phase 1b relocation, for a cjoin filter
# keyed past its hop (`cjoin("parent" => …, filters = ["grandparent__code" => "Z"])`). #973 refuses that
# key — it named a further relation, and resolving it added that join silently — so the deep predicate
# is written on its own hop, `on("parent__grandparent", "code" => "Z")`, and lands on cj_grand's ON by
# construction. What #404 pinned still holds and is still pinned: the predicate sits on the join it
# names, reached via order_by() (the shape #404's reordering exposed) and via values().
# ─────────────────────────────────────────────────────────────────────────────
@testset "a deep cjoin ON condition lands on the join it references (#404)" begin
  # #973: the old spelling — a cjoin filter keyed past its hop — is refused at the call.
  @test_throws FilterError OBJ.Cj_child.objects.cjoin("parent" => "Cj_parent",
    filters = ["grandparent__code" => "Z"], warn = false)

  # (a) reached via order_by — the shape #404's reordering exposed.
  ordered = OBJ.Cj_child.objects
  ordered.values("note")
  ordered.cjoin("parent" => "Cj_parent", warn = false)
  ordered.on("parent__grandparent", "code" => "Z")
  ordered.order_by("parent__grandparent__code")

  sql = inspect_query(ordered)[:sql_text]

  # The extra belongs on cj_grand's ON clause (emitted second), not on cj_parent's (emitted first).
  @test occursin("LEFT JOIN \"cj_grand\" AS \"Tb_2\" ON \"Tb_1\".\"grandparent\" = \"Tb_2\".\"id\" AND \"Tb_2\".\"code\" = \$1", sql)
  @test !occursin("\"Tb\".\"parent\" = \"Tb_1\".\"id\" AND \"Tb_2\"", sql)
  @test occursin("ORDER BY \"Tb_2\".\"code\" ASC", sql)
  @test _obj_joins(sql) == 2

  # (b) reached via values() — the same forward reference, and it pre-dates #404: projecting the
  # deep path builds the deeper join up front just as ordering by it now does.
  projected = OBJ.Cj_child.objects
  projected.values("note", "parent__grandparent__code")
  projected.cjoin("parent" => "Cj_parent", warn = false)
  projected.on("parent__grandparent", "code" => "Z")

  psql = inspect_query(projected)[:sql_text]

  @test occursin("LEFT JOIN \"cj_grand\" AS \"Tb_2\" ON \"Tb_1\".\"grandparent\" = \"Tb_2\".\"id\" AND \"Tb_2\".\"code\" = \$1", psql)
  @test !occursin("\"Tb\".\"parent\" = \"Tb_1\".\"id\" AND \"Tb_2\"", psql)
  @test _obj_joins(psql) == 2
end

# ─────────────────────────────────────────────────────────────────────────────
# Predicates two and three hops deep each ride on their own join (#404, #973)
# #404 pinned Phase 1b moving one `Q(...)` that named Tb_2 and Tb_3 onto Tb_3, the later of the two,
# so neither reference pointed forward. #973 refuses that `Q`: both keys reach past the cjoin's hop.
# Written per hop instead, each predicate sits on the join it names and no ON clause refers to a later
# join — the property #404 cared about, now true by construction rather than by relocation.
# ─────────────────────────────────────────────────────────────────────────────
@testset "predicates at two depths ride on their own joins (#404, #973)" begin
  # #973: a `Q` whose keys reach past the hop is refused at the call.
  @test_throws FilterError OBJ.Cj_child.objects.cjoin("parent" => "Cj_parent",
    filters = [Q("grandparent__code" => "Z", "grandparent__great__tag" => "T")], warn = false)

  q = OBJ.Cj_child.objects
  q.values("note")
  q.cjoin("parent" => "Cj_parent", warn = false)
  q.on("parent__grandparent", "code" => "Z")
  q.on("parent__grandparent__great", "tag" => "T")

  sql = inspect_query(q)[:sql_text]

  # Each predicate on the join it names, in emission order...
  @test occursin("LEFT JOIN \"cj_grand\" AS \"Tb_2\" ON \"Tb_1\".\"grandparent\" = \"Tb_2\".\"id\" AND \"Tb_2\".\"code\" = \$1", sql)
  @test occursin("LEFT JOIN \"cj_great\" AS \"Tb_3\" ON \"Tb_2\".\"great\" = \"Tb_3\".\"id\" AND \"Tb_3\".\"tag\" = \$2", sql)
  # ...and the grand join's ON clause names no later join.
  @test !occursin("\"Tb_2\".\"id\" AND \"Tb_3\"", sql)
  @test _obj_joins(sql) == 3
end

# ─────────────────────────────────────────────────────────────────────────────
# A cjoin_on alias spelled like a column takes no other join's predicate (#404)
# Phase 1b's relocation search tested the rendered SQL for each join's alias. Every column reference
# renders as `"alias"."col"`, so a bare `"name"` test also hit the COLUMN half: a `cjoin_on` alias
# spelled like a column (`alias = "code"` vs `"Tb_2"."code"`) then dragged an unrelated LEFT JOIN's ON
# filter onto itself. Valid SQL, wrong rows, no error. #982 deleted the search — placement no longer
# reads SQL text — and this testset now pins that the alias's NAME still decides nothing.
# ─────────────────────────────────────────────────────────────────────────────
@testset "a cjoin_on alias spelled like a column takes no other join's predicate (#404, #982)" begin
  build(alias) = begin
    q = OBJ.Cj_child.objects
    q.values("note", "parent__grandparent__code")
    # #973: the deep predicate on its own hop (it used to be a cjoin filter keyed past the hop).
    q.cjoin("parent" => "Cj_parent", warn = false)
    q.on("parent__grandparent", "code" => "Z")
    q.cjoin_on("Cj_grand", alias = alias, join_type = "INNER", on = [Q(Joined(alias, "id") == F("id"))])
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
# ON predicates at two join depths bind their OWN values (#421)
# #421: Phase 1 bound every ON condition in `row_join` order, and Phase 1b then moved a forward-
# referencing fragment onto a later join, changing EMISSION order. PostgreSQL never noticed — `$N`
# numbering travels with the text — but SQLite flattens the `:join` bucket in BINDING order, so the
# first `?` took the relocated fragment's value and the two conditions swapped. Valid SQL, wrong rows.
#
# #973 refuses the key that relocated (a cjoin filter reaching past its hop); the deep predicate is now
# written on its own hop, `on("parent__grandparent", …)`, and binds where its join is emitted. The swap
# stays pinned as a regression guard: (a) declares the DEEP predicate first, the order the original bug
# needed, and the control pair — the same two predicates declared the other way round — must render the
# same text and bind the same bucket.
# ─────────────────────────────────────────────────────────────────────────────
_cj_two_depth(sku, code; deep_first = true) = begin
  q = OBJ.Cj_child.objects
  q.values("note")
  deep_first && q.on("parent__grandparent", code)
  q.cjoin("parent" => "Cj_parent", filters = [sku], warn = false)
  deep_first || q.on("parent__grandparent", code)
  q
end

@testset "ON predicates at two depths bind their own values (#421)" begin
  # #973: the issue's original spelling — the deep filter inside the cjoin — is refused at the call.
  @test_throws FilterError OBJ.Cj_child.objects.cjoin("parent" => "Cj_parent",
    filters = ["grandparent__code" => "ZZZ", "sku" => "SSS"], warn = false)

  # (a) the deep predicate is declared FIRST, so declaration order and emission order differ.
  sl = inspect_query(_cj_two_depth("sku" => "SSS", "code" => "ZZZ"); connection = _OBJ_SL)
  sql = sl[:sql_text]

  # Pin the emission order the bucket has to match rather than trusting it: cj_parent's ON carries
  # `sku` and is emitted first, cj_grand's carries `code` and is emitted second.
  @test occursin("\"Tb_1\".\"sku\" = ?", sql)
  @test occursin("\"Tb_2\".\"code\" = ?", sql)
  @test first(findfirst("\"Tb_1\".\"sku\" = ?", sql)) < first(findfirst("\"Tb_2\".\"code\" = ?", sql))

  # ...so the bucket must read the sku value first.
  @test sl[:parameter_buckets][:join] == ["SSS", "ZZZ"]
  @test count(==('?'), sql) == 2                     # no orphan marker, no orphan value

  # (b) control: the same two predicates declared the other way round — byte-identical.
  rev = inspect_query(_cj_two_depth("sku" => "SSS", "code" => "ZZZ"; deep_first = false); connection = _OBJ_SL)
  @test rev[:parameter_buckets][:join] == ["SSS", "ZZZ"]
  @test rev[:sql_text] == sql        # the rendered text never depends on declaration order

  # (c) PostgreSQL is the oracle: its `$N` markers, read in text order, give the order SQLite must bind
  # in. Each predicate binds where it is emitted, so the numbering follows the text.
  pg = inspect_query(_cj_two_depth("sku" => "SSS", "code" => "ZZZ"); connection = _OBJ_PG)
  @test occursin("\"Tb_1\".\"sku\" = \$1", pg[:sql_text])
  @test occursin("\"Tb_2\".\"code\" = \$2", pg[:sql_text])
  @test pg[:parameters] == ["SSS", "ZZZ"]
end

# ─────────────────────────────────────────────────────────────────────────────
# A deep ON predicate carries ALL of its values, in order (#421)
# One fragment can bind more than one value, so "bind the fragment's parameter" is not the same
# invariant as "bind the fragment's parameter RUN". `@in` over three codes beside a single-valued
# `sku` makes the split 3-and-1: pre-#421 the bucket read [Z,Y,X,SSS] against markers emitted
# sku-first, so all four misbound. Declared deep-first, as in the testset above.
# ─────────────────────────────────────────────────────────────────────────────
@testset "a deep ON predicate carries its whole parameter run (#421)" begin
  r = inspect_query(_cj_two_depth("sku" => "SSS", "code__@in" => ["Z", "Y", "X"]); connection = _OBJ_SL)
  @test r[:parameter_buckets][:join] == ["SSS", "Z", "Y", "X"]
  @test count(==('?'), r[:sql_text]) == 4
end

# ─────────────────────────────────────────────────────────────────────────────
# A `Q` spanning two depths is refused; one `Q` per hop binds in emission order (#421, #973)
# #421's control pinned a single `Q(...)` spanning two depths as ONE fragment that Phase 1b moved
# whole. #973 refuses that `Q` — it names a relation past the cjoin's hop — so the two depths are two
# predicates on two joins, and their values bind in the order those joins are emitted.
# ─────────────────────────────────────────────────────────────────────────────
@testset "a Q spanning two depths is refused; per-hop Qs bind in emission order (#421, #973)" begin
  @test_throws FilterError OBJ.Cj_child.objects.cjoin("parent" => "Cj_parent",
    filters = [Q("grandparent__code" => "Z", "sku" => "S")], warn = false)

  two_q = inspect_query(_cj_two_depth(Q("sku" => "S"), Q("code" => "Z")); connection = _OBJ_SL)
  @test two_q[:parameter_buckets][:join] == ["S", "Z"]
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
# "Join key" means a join-config key, and those were written at three unrelated sites — keyed by a
# `cjoin` PATH, a `cjoin_on` ALIAS, and an `on()` PATH. #484 split the alias half into its own map
# (`alias_join`), so `custom_join` is now the PATH namespace alone.
#
# Measured pre-fix (the deleted route A), this rendered:
#     INNER JOIN "cj_parent" AS "b2" ON ("b2"."sku" = "R1"."note")
#     CROSS JOIN "ev" AS "R1_1"
# — the predicate gone from the SQL while its value stayed orphaned in the `:join` bucket. #421
# makes that strictly worse before this guard makes it better: once values travel with their
# fragment the orphan disappears too, so the wrong query becomes perfectly well-formed. That is why
# the two land together.
#
# ── #424's producer table is gone: #474 made all three of them RENDER ────────────────────────────
#
# The arithmetic, because it has been re-derived wrongly twice in this file already:
#
#   A  went with #444 — a predicate could no longer NAME a CTE, which closed the Phase-1b
#      relocation route. #492 restored the `__` string spelling wherever a COLUMN path is accepted,
#      but deliberately not here: a CTE-rooted string inside `on()` / `cjoin()` / `cjoin_on()` is
#      refused at build time, so A stays closed and this arithmetic is unchanged.
#   B, C, D  were the three NAME-COLLISION routes: a `.with()` label equal to a `cjoin` path, a
#      `cjoin_on` alias, or an `on()` path. All three reached the guard because `_build_row_join`'s
#      shared tail looked a CTE hop up in `custom_join` UNDER THE CTE'S OWN NAME and claimed that
#      name in `row_path`. #474 removed that lookup, so the three are no longer collisions at all —
#      they are two relations that happen to share a name, and both are emitted. Their coexistence
#      is now pinned in `test/unit/test_relation_alias_namespace.jl`, which is where a reader
#      looking for "what happened to #447/#424" should go.
#
# What is left of the guard is a fail-closed backstop with NO constructible producer: nine shapes
# were built against it after the change and none reached it. #982 then deleted the backstop itself
# (Phase 1c in `build_row_join_sql_text`) with the relocation that fed it: a condition renders on its
# own row, and a CROSS row carries none. So what stays here is the control — a CROSS-joined CTE still
# renders with no ON clause.
# ─────────────────────────────────────────────────────────────────────────────
_ob_cte() = begin
  c = OBJ.Cj_grand.objects
  c.values("id", "code")
  c
end

@testset "a CROSS-joined CTE carrying no predicate still renders (#424 control)" begin
  # Without this, a guard written as an unconditional `throw` would break every #44 query while
  # every other assertion in this file kept passing. (`test/unit/test_cte_ergonomics.jl` owns the
  # full #44 coverage; this is the local tripwire.)
  ok = OBJ.Cj_child.objects
  ok.with("ev" => _ob_cte())
  ok.values("note")
  ok.filter(F("note") == CTE("ev", "code"))
  ok_sql = inspect_query(ok; connection = _OBJ_SL)[:sql_text]
  @test occursin("CROSS JOIN \"ev\"", ok_sql)
  @test !occursin(r"CROSS JOIN[^\n]*ON", ok_sql)
end

# ── #982: a cjoin_on predicate stays in the ON clause it was written in ───────────────────────────
#
# `cjoin_on` renders its ON clause entirely from the caller's predicates. A predicate naming a path
# (`"parent__grandparent__code" => "Z"`) used to JOIN that path while it rendered — after the alias's
# own row — and a substring scan of the rendered SQL then moved it onto that later join (Phase 1b). So
# the predicate left the ON clause it was written in, the alias could be left with no ON clause at all
# (#435's refusal, with remedies for each way of getting there), and a forward reference between two
# aliases raised the same refusal.
#
# Binding (`_bind_cjoin_on_conditions!`) now builds every path an ON clause names BEFORE the alias
# rows, and emits the aliases in dependency order. So the predicate renders where it was written, and
# the shapes #435 refused render — the ones whose own predicates name the alias. An ON clause that
# never names its alias is still refused, by #448, below.
#
# STRIP ANSI BEFORE MATCHING. `_emsg` keeps the SGR sequences when `Base.have_color` is true and
# drops them otherwise, so a needle that spans a color boundary matches on a piped run and fails on
# CI's Linux runner. Matching stripped text makes every assertion here mean the same thing on both.
_no_ansi(s::AbstractString) = replace(s, r"\e\[[0-9;]*m" => "")

# The ON clause of the join aliased `alias`: the text between `AS "<alias>" ON ` and the next JOIN.
function _on_clause_of(sql::AbstractString, alias::AbstractString)
  at = findfirst("AS \"$(alias)\" ON ", sql)
  at === nothing && return nothing
  rest = sql[last(at)+1:end]
  stop = findfirst(r"\s(INNER|LEFT|CROSS) JOIN", rest)
  return strip(stop === nothing ? rest : rest[1:first(stop)-1])
end

# ─────────────────────────────────────────────────────────────────────────────
# cjoin_on: a predicate naming a path renders in the alias's own ON clause (#982)
# The path's joins are built first, so the alias's ON clause can name them where it was written.
# Each shape below is one #435 used to refuse or relocate, with the SQL it renders now.
# ─────────────────────────────────────────────────────────────────────────────
@testset "cjoin_on: a predicate naming a path stays in its own ON clause (#982)" begin

  # ── a path predicate beside a self-naming one ─────────────────────────────
  # Used to relocate the path predicate into `Tb_2`'s ON. Now `Tb_2` is joined before `b2`, keeps
  # its bare equi-anchor, and `b2` carries both predicates. One value binds, on both backends.
  @testset "the path predicate is not moved onto the path's join" begin
    for (backend, conn) in (("PostgreSQL", _OBJ_PG), ("SQLite", _OBJ_SL))
      q = OBJ.Cj_child.objects
      q.values("note")
      q.cjoin_on("Cj_parent", alias = "b2",
                 on = [Joined("b2", "sku") == F("note"), "parent__grandparent__code" => "Z"])
      r = inspect_query(q; connection = conn)
      sql = r[:sql_text]
      # The path's join comes first, so the alias's ON clause may name it.
      @test findfirst("AS \"Tb_2\"", sql).start < findfirst("AS \"b2\"", sql).start
      # Its own ON clause is the equi-anchor alone — the predicate did not land there.
      @test _on_clause_of(sql, "Tb_2") == "\"Tb_1\".\"grandparent\" = \"Tb_2\".\"id\""
      on_b2 = _on_clause_of(sql, "b2")
      @test occursin("(\"b2\".\"sku\" = \"Tb\".\"note\")", on_b2)
      @test occursin("\"Tb_2\".\"code\" = ", on_b2)
      @test r[:parameters] == ["Z"]
    end
  end

  # ── a correlation with a path renders without projecting it ──────────────
  # #435 refused this and told the caller to project the path so it was built first. Binding builds
  # it first anyway, so both spellings render the same ON clause.
  @testset "a correlation with an unprojected path renders" begin
    unprojected = OBJ.Cj_child.objects
    unprojected.values("note")
    unprojected.cjoin_on("Cj_parent", alias = "b2", on = [Joined("b2", "sku") == F("parent__grandparent__code")])
    projected = OBJ.Cj_child.objects
    projected.values("note", "parent__grandparent__code")
    projected.cjoin_on("Cj_parent", alias = "b2", on = [Joined("b2", "sku") == F("parent__grandparent__code")])
    for q in (unprojected, projected)
      sql = inspect_query(q; connection = _OBJ_SL)[:sql_text]
      @test _on_clause_of(sql, "b2") == "(\"b2\".\"sku\" = \"Tb_2\".\"code\")"
    end
  end

  # ── a forward reference to another alias is reordered ─────────────────────
  # `b3` names `b2`, declared after it. #435 refused it with a "declare it on the other join"
  # remedy; now `b2` is simply emitted first.
  @testset "a forward reference to another cjoin_on is reordered" begin
    q = OBJ.Cj_child.objects
    q.values("note")
    q.cjoin_on("Cj_parent", alias = "b3", on = [Joined("b3", "sku") == Joined("b2", "sku")])
    q.cjoin_on("Cj_parent", alias = "b2", on = [Joined("b2", "sku") == F("note")])
    sql = inspect_query(q; connection = _OBJ_SL)[:sql_text]
    @test findfirst("AS \"b2\"", sql).start < findfirst("AS \"b3\"", sql).start
    @test _on_clause_of(sql, "b2") == "(\"b2\".\"sku\" = \"Tb\".\"note\")"
    @test _on_clause_of(sql, "b3") == "(\"b3\".\"sku\" = \"b2\".\"sku\")"
  end

  # ── both at once: a path and a later alias ────────────────────────────────
  # #435 gave two remedies here (project the path, reorder the aliases). Both are now what binding
  # does, and every predicate stays in `b3`'s ON clause.
  @testset "a path and a later alias in one ON clause" begin
    q = OBJ.Cj_child.objects
    q.values("note")
    q.cjoin_on("Cj_parent", alias = "b3",
               on = [Joined("b3", "sku") == Joined("b2", "sku"), Joined("b3", "sku") == F("parent__grandparent__code")])
    q.cjoin_on("Cj_parent", alias = "b2", on = [Joined("b2", "sku") == F("note")])
    sql = inspect_query(q; connection = _OBJ_SL)[:sql_text]
    @test _on_clause_of(sql, "b3") == "(\"b3\".\"sku\" = \"b2\".\"sku\") AND (\"b3\".\"sku\" = \"Tb_2\".\"code\")"
    @test findfirst("AS \"Tb_2\"", sql).start < findfirst("AS \"b2\"", sql).start < findfirst("AS \"b3\"", sql).start
  end

  # ── a predicate list naming no alias of its own is #448's, whatever it names ──
  # The old #435 fixture. With nothing relocated, what is left is an ON clause that never names `b2`.
  @testset "a path predicate alone is refused as unconstrained" begin
    for (backend, conn) in (("PostgreSQL", _OBJ_PG), ("SQLite", _OBJ_SL))
      q = OBJ.Cj_child.objects
      q.values("note")
      q.cjoin_on("Cj_parent", alias = "b2", on = ["parent__grandparent__code" => "Z"])
      err = try inspect_query(q; connection = conn); nothing catch e; e end
      @test err isa PormG.QueryBuildError
      msg = _no_ansi(sprint(showerror, err))
      @test occursin("never references", msg)
      @test occursin("#448", msg)
      @test !occursin("resolved onto", msg)
    end
  end

  # ── an emptied ON list is refused the same way ────────────────────────────
  # Not reachable through the public API — `_cjoin_on` refuses an empty `on` at the call — so reach
  # it white-box. An empty list names no alias, so binding refuses it before anything renders, and
  # the renderer never sees an AnchorlessJoin with no ON clause.
  @testset "an emptied ON list is refused at binding" begin
    q = OBJ.Cj_child.objects
    q.values("note")
    q.cjoin_on("Cj_parent", alias = "b2", on = [Joined("b2", "sku") == F("note")])
    empty!(q.object.alias_join["b2"].filters)   # #484: cjoin_on entries live in `alias_join`
    err = try inspect_query(q; connection = _OBJ_PG); nothing catch e; e end
    @test err isa PormG.QueryBuildError
    @test occursin("never references", _no_ansi(sprint(showerror, err)))
  end

  # ── control: an ordinary cjoin_on still renders ───────────────────────────
  ok = OBJ.Cj_child.objects
  ok.values("note")
  ok.cjoin_on("Cj_parent", alias = "b2", on = [Joined("b2", "sku") == F("note")])
  ok_sql = inspect_query(ok; connection = _OBJ_SL)[:sql_text]
  @test _on_clause_of(ok_sql, "b2") == "(\"b2\".\"sku\" = \"Tb\".\"note\")"
end


# ─────────────────────────────────────────────────────────────────────────────
# cjoin_on emission order follows the declaration and the references, not alias hashing (#449, #982)
# `build()` materializes `row_join` from `alias_join`, so the container's order decides which of two
# `cjoin_on` aliases is emitted first. While it was a plain `Dict` that order came from hashing the
# ALIAS STRINGS: measured across five name pairs, the first-listed of each pair was emitted first no
# matter which was declared first, so renaming an alias for readability could flip a working query
# into a QueryBuildError or the reverse.
#
# Since #982 the order is DEPENDENCY order — an alias after every alias its ON clause names — with
# declaration order breaking the ties. The pairs below are the ones #449 measured, kept verbatim, and
# the test asserts the OUTCOME is a function of declaration and references ALONE: every pair behaves
# identically, in both directions.
# ─────────────────────────────────────────────────────────────────────────────
@testset "cjoin_on is emitted in dependency, then declaration, order — not alias-hash order (#449, #982)" begin
  # #449 lists these pairs in the order the OLD `Dict` emitted them — `b3` before `b2`, `zz` before
  # `aa`, and so on, whichever way they were declared. So each pair is exercised in BOTH declaration
  # directions; the reversed one is where hash order and declaration order DISAGREE.
  _449_HASH_ORDER = (("b3", "b2"), ("zz", "aa"), ("j9", "j1"), ("omega", "alpha"), ("w", "q"))
  _449_PAIRS = collect(Iterators.flatten(((a, b), (b, a)) for (a, b) in _449_HASH_ORDER))

  for (first_alias, second_alias) in _449_PAIRS
    @testset "$(first_alias) declared before $(second_alias)" begin

      # ── shape A: independent aliases keep declaration order ───────────────
      # Each ON clause names only itself and the base row, so nothing orders them but the declaration.
      q = OBJ.Cj_child.objects
      q.values("note")
      q.cjoin_on("Cj_parent", alias = first_alias,  on = [Joined(first_alias, "sku") == F("note")])
      q.cjoin_on("Cj_parent", alias = second_alias, on = [Joined(second_alias, "sku") == F("note")])
      sql = inspect_query(q; connection = _OBJ_PG)[:sql_text]
      first_at  = findfirst("AS \"$(first_alias)\"", sql)
      second_at = findfirst("AS \"$(second_alias)\"", sql)
      @test first_at !== nothing
      @test second_at !== nothing
      # THE assertion. Under the old `Dict` it fails for whichever pairs hash the other way round.
      @test first(first_at) < first(second_at)

      # ── shape B: a reference overrides the declaration ────────────────────
      # The first-declared alias now names the second, so the second must be emitted first, for
      # every pair in both directions. Before #982 this raised #435 instead.
      q2 = OBJ.Cj_child.objects
      q2.values("note")
      q2.cjoin_on("Cj_parent", alias = first_alias,
                  on = [Joined(first_alias, "sku") == Joined(second_alias, "sku")])
      q2.cjoin_on("Cj_parent", alias = second_alias, on = [Joined(second_alias, "sku") == F("note")])
      sql2 = inspect_query(q2; connection = _OBJ_PG)[:sql_text]
      @test first(findfirst("AS \"$(second_alias)\"", sql2)) < first(findfirst("AS \"$(first_alias)\"", sql2))
      @test _on_clause_of(sql2, first_alias) ==
            "(\"$(first_alias)\".\"sku\" = \"$(second_alias)\".\"sku\")"
    end
  end

  # ── a cycle has no order, and is refused ────────────────────────────────────
  # Each alias names the other. No emission order puts both references backwards, so binding
  # refuses it and names both aliases rather than picking one to leave dangling.
  @testset "two aliases naming each other are refused" begin
    q = OBJ.Cj_child.objects
    q.values("note")
    q.cjoin_on("Cj_parent", alias = "b2", on = [Joined("b2", "sku") == Joined("b3", "sku")])
    q.cjoin_on("Cj_parent", alias = "b3", on = [Joined("b3", "id") == Joined("b2", "id")])
    err = try inspect_query(q; connection = _OBJ_PG); nothing catch e; e end
    @test err isa PormG.QueryBuildError
    msg = _no_ansi(sprint(showerror, err))
    @test occursin("b2 and b3 name each other", msg)
    @test occursin("#982", msg)

    # An alias that only names a member of the cycle is blocked by it, not part of it, and the message
    # names the cycle alone — even with the blocked one declared first, where the search starts.
    q2 = OBJ.Cj_child.objects
    q2.values("note")
    q2.cjoin_on("Cj_parent", alias = "b4", on = [Joined("b4", "sku") == Joined("b2", "sku")])
    q2.cjoin_on("Cj_parent", alias = "b2", on = [Joined("b2", "sku") == Joined("b3", "sku")])
    q2.cjoin_on("Cj_parent", alias = "b3", on = [Joined("b3", "id") == Joined("b2", "id")])
    msg2 = _no_ansi(sprint(showerror, try inspect_query(q2; connection = _OBJ_PG); nothing catch e; e end))
    @test occursin("of b2 and b3 name each other", msg2)
    @test !occursin("b4", msg2)
  end
end


# ─────────────────────────────────────────────────────────────────────────────
# cjoin_on: an ON clause that never names its own alias is refused (#448)
# `cjoin_on` used to check only that the join ended up WITH an ON clause, never that the clause
# CONSTRAINED it. A predicate list mentioning the alias nowhere rendered a well-formed, unconstrained
# join — every row of the joined table paired with every matched base row, with no error and no
# warning (the #44 Cartesian warning covers CROSS entries only).
#
# The check used to read the rendered ON clause for `"<alias>".`. Since #982 binding decides it from
# the conditions — a `Joined("<alias>", …)` somewhere in them — before anything renders, so a
# projection that builds a path first can no longer change the outcome.
# ─────────────────────────────────────────────────────────────────────────────
@testset "cjoin_on refuses an ON clause that never names its own alias (#448)" begin
  for (backend, conn) in (("PostgreSQL", _OBJ_PG), ("SQLite", _OBJ_SL))
    @testset "$backend" begin

      # ── a base column only ────────────────────────────────────────────────
      # `"note"` is a column of the BASE model: nothing in this ON clause names `b2`.
      q1 = OBJ.Cj_child.objects
      q1.values("note")
      q1.cjoin_on("Cj_parent", alias = "b2", on = ["note" => "Z"])
      err1 = try
        inspect_query(q1; connection = conn); nothing
      catch e
        e
      end
      @test err1 isa PormG.QueryBuildError
      msg1 = _no_ansi(sprint(showerror, err1))
      @test occursin("never references", msg1)
      @test occursin("b2", msg1)
      @test occursin("#448", msg1)
      # The remedy names the typed handle — `F("b2.<column>")` was retired by #481.
      @test occursin("Joined(\"b2\", \"<column>\")", msg1)
      @test !occursin("F(\"b2.", msg1)
      # A user-writable shape is never reported as an internal fault (same rule as #424).
      @test !occursin("internal", lowercase(msg1))
      @test !occursin("please report", lowercase(msg1))

      # ── a projected path: the outcome no longer depends on projection ─────
      # Before #448 this rendered `INNER JOIN "cj_parent" AS "b2" ON "Tb_2"."code" = ?`; before #982
      # its unprojected twin raised #435 instead. Both are #448's now.
      q2 = OBJ.Cj_child.objects
      q2.values("note", "parent__grandparent__code")
      q2.cjoin_on("Cj_parent", alias = "b2", on = ["parent__grandparent__code" => "Z"])
      err2 = try
        inspect_query(q2; connection = conn); nothing
      catch e
        e
      end
      @test err2 isa PormG.QueryBuildError
      msg2 = _no_ansi(sprint(showerror, err2))
      @test occursin("never references", msg2)
      @test occursin("#448", msg2)

      # ── an alias spelled like a column ────────────────────────────────────
      # `Cj_grand` has a column `code`; aliasing the join `code` puts the text `code` in the ON
      # clause without ever naming THIS join. The text check needed a trailing dot to tell them apart;
      # the typed check never sees the text.
      q3 = OBJ.Cj_child.objects
      q3.values("note", "parent__grandparent__code")
      q3.cjoin_on("Cj_parent", alias = "code", on = ["parent__grandparent__code" => "Z"])
      err3 = try
        inspect_query(q3; connection = conn); nothing
      catch e
        e
      end
      @test err3 isa PormG.QueryBuildError
      @test occursin("never references", _no_ansi(sprint(showerror, err3)))

      # ── control: a genuinely constrained join still renders ───────────────
      # Without this, the guard could refuse everything and every assertion above would still pass.
      ok = OBJ.Cj_child.objects
      ok.values("note")
      ok.cjoin_on("Cj_parent", alias = "b2", on = [Joined("b2", "sku") == F("note")])
      ok_sql = inspect_query(ok; connection = conn)[:sql_text]
      @test occursin("JOIN \"cj_parent\" AS \"b2\" ON ", ok_sql)

      # ── control: constrained via a column whose NAME matches the alias ────
      ok2 = OBJ.Cj_child.objects
      ok2.values("note")
      ok2.cjoin_on("Cj_parent", alias = "sku", on = [Joined("sku", "sku") == F("note")])
      ok2_sql = inspect_query(ok2; connection = conn)[:sql_text]
      @test occursin("JOIN \"cj_parent\" AS \"sku\" ON ", ok2_sql)
    end
  end
end
