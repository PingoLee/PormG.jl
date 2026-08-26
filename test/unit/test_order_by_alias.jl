"""
Unit coverage for #423: `order_by()` on a name declared by `values()`.

`values()` stores the caller's chosen name in **different fields** depending on what is on the
right of the pair:

    values("s" => "parent__sku")  ->  _as = "parent__sku"   custom_as = "s"
    values("c" => Count("id"))    ->  _as = "c"             custom_as = nothing

For a field path the PATH becomes `_as` and the chosen name goes to `custom_as`; for a function the
chosen name becomes `_as` outright. `get_select_query` caches under `_as`, while `get_order_query`
reads `custom_as` first to decide whether the ORDER BY term names a projection.

Those two disagreed, and the disagreement was resolved in the wrong order: the alias test was
nested INSIDE an `instruc.cache` hit, so for `order_by("s")` the cache lookup (keyed by
`"parent__sku"`) missed, control fell through to `_get_select_query("s")`, and `"s"` was resolved as
a physical column of the base model. Two different symptoms came out of the same line:

  - a name that matches no column raises `UnknownFieldError: The field s not found in ao_child`;
  - a name that DOES match one silently sorts the wrong column — `values("note" => "qty")` projects
    `qty` under the name `note`, and `order_by("note")` emitted `ORDER BY "Tb"."note"`, ordering by
    the untouched `note` column while the output column called `note` holds `qty`. No error, wrong
    order, and only visible by reading the SQL.

Aggregate and window aliases were never affected — their chosen name IS `_as`, so the cache key
happened to match. That asymmetry (the same `"name" => value` syntax working or not depending on
what is on the right) is what made this read as a gap rather than a restriction.

The fix tests `found_in_select` FIRST, against the RENDERED projection list rather than the
declared one (see the "never rendered" testset for why that distinction is load-bearing). The
branch inversion moves exactly one combination — `found_in_select` on a cache miss — and the
ambiguity guard, which is not cache-gated, moves a second. Everything else is byte-identical, so
the controls at the bottom of this file are the substance of the change: they pin every path that
must not move, including the ones #404 and #76 depend on.

One deliberate addition: `.values()` allows two projections to share a name, and making that name
resolve would emit an ambiguous `ORDER BY "x"` — which PostgreSQL rejects at execution and SQLite
resolves arbitrarily. Refusing it here keeps the backends aligned rather than trading a loud error
for a silent divergence. It is keyed on OBJECT IDENTITY — two matching slots are safe exactly when
they are the same `SQLField`, which is `get_select_query`'s own dedupe relation — so projecting the
SAME expression twice (`values("note", "note")`) keeps working, by construction rather than by
proxy. Two earlier keys were wrong and both are pinned: `_as` (blind to the `SQLText` branch) and
the rendered SQL (blind on SQLite, where every parameter renders as `?`).

All assertions render through mock PostgreSQL/SQLite connections — no live database. The execution
half lives in `test/integration/test_selection.jl`.

Sibling coverage:
  - `test_order_by_joins.jl`       -> #404 join emission, and the cjoin ON machinery.
  - `test_order_by_nulls.jl`       -> #75 NULL placement.
  - `test_inspect_query.jl`        -> #76 DISTINCT + ORDER BY projection guard.
"""

using Test
using PormG
using PormG.Models

# Dedicated mock connections + config key: `runtests.jl` includes ~50 files into one `Main`, so a
# shared name would let another file's settings decide this file's dialect.
struct AliasOrderMockSQLite <: PormG.PormGSQLite end
struct AliasOrderMockPostgres <: PormG.PormGPostgres end
const _AO_SL = AliasOrderMockSQLite()
const _AO_PG = AliasOrderMockPostgres()
# ORDER BY renders NULL placement via a library-version probe (#75); pin a modern version so
# order_by works on the mock without a live driver.
PormG.backend_sqlite_version(::AliasOrderMockSQLite) = 3045000

PormG.config["alias_order_mock"] = PormG.Configuration.Settings(
  connections = _AO_PG, change_data = true, db_def_folder = "alias_order_mock",
)

# Inline fixtures in their own module: `set_models` is REQUIRED (not style), because
# `_build_row_join` reads `instruct.object.model._module::Module` — a bare `Model(...)` leaves
# `_module === nothing` and TypeErrors the moment a join renders.
module AliasOrderModels
import PormG
import PormG.Models

Ao_parent = Models.Model("ao_parent",
  id  = Models.IDField(),
  sku = Models.CharField(),
)

Ao_child = Models.Model("ao_child",
  id     = Models.IDField(),
  parent = Models.ForeignKey(Ao_parent, on_delete = "CASCADE", related_name = "kids", null = true),
  note   = Models.CharField(null = true),
  qty    = Models.IntegerField(null = true),
)

PormG.Models.set_models(@__MODULE__, "alias_order_mock")
end

const AO = AliasOrderModels
import PormG.QueryBuilder: inspect_query, Count, Value, Rank, WindowOver

_ao_joins(sql::AbstractString) = count("JOIN", sql)

# ─────────────────────────────────────────────────────────────────────────────
# A local-column alias is usable in ORDER BY (#423)
# The simplest form, and the one that shows the defect is not about joins at all: `values("n" =>
# "note")` needs no join, and `order_by("n")` still raised. Both backends, because nothing here is
# dialect-specific — only the NULL-placement suffix differs.
# ─────────────────────────────────────────────────────────────────────────────
@testset "order_by() can name a values() alias over a local column (#423)" begin
  for (label, conn) in (("PostgreSQL", _AO_PG), ("SQLite", _AO_SL))
    @testset "$label" begin
      q = AO.Ao_child.objects
      q.values("n" => "note")
      q.order_by("n")

      sql = inspect_query(q; connection = conn)[:sql_text]

      @test occursin("\"Tb\".\"note\" as \"n\"", sql)
      @test occursin("ORDER BY \"n\" ASC", sql)
      # The alias must not be re-resolved as a column: that is the pre-fix failure.
      @test !occursin("ORDER BY \"Tb\".\"n\"", sql)
      @test _ao_joins(sql) == 0
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# A join-path alias is usable in ORDER BY, and emits exactly one join (#423)
# The issue's headline shape. The join count is the assertion that matters most: a "fix" that made
# the alias resolve by re-running path resolution would satisfy the ORDER BY text and quietly
# double-join, which no other assertion here would catch.
# ─────────────────────────────────────────────────────────────────────────────
@testset "order_by() can name a values() alias over a join path (#423)" begin
  for (label, conn) in (("PostgreSQL", _AO_PG), ("SQLite", _AO_SL))
    @testset "$label" begin
      q = AO.Ao_child.objects
      q.values("note", "s" => "parent__sku")
      q.order_by("s")

      sql = inspect_query(q; connection = conn)[:sql_text]

      @test occursin("LEFT JOIN \"ao_parent\" AS \"Tb_1\" ON \"Tb\".\"parent\" = \"Tb_1\".\"id\"", sql)
      @test occursin("\"Tb_1\".\"sku\" as \"s\"", sql)
      @test occursin("ORDER BY \"s\" ASC", sql)
      @test _ao_joins(sql) == 1
    end
  end

  # Descending, and DISTINCT — the two modifiers that route through different code below the fix.
  # `distinct()` matters specifically: the #76 guard refuses an ORDER BY term that is not in the
  # projection, and it is gated on `!found_in_select`. An alias IS in the projection by definition,
  # so the guard must not fire here — pre-fix this raised UnknownFieldError before ever reaching it.
  desc = AO.Ao_child.objects
  desc.values("note", "s" => "parent__sku")
  desc.order_by("-s")
  @test occursin("ORDER BY \"s\" DESC", inspect_query(desc; connection = _AO_SL)[:sql_text])

  dis = AO.Ao_child.objects
  dis.values("note", "s" => "parent__sku")
  dis.distinct(true)
  dis.order_by("s")
  dis_sql = inspect_query(dis; connection = _AO_PG)[:sql_text]
  @test occursin("DISTINCT", dis_sql)
  @test occursin("ORDER BY \"s\" ASC", dis_sql)
end

# ─────────────────────────────────────────────────────────────────────────────
# An alias that shadows a real column orders the ALIAS, not the column (#423)
# The silent half of the bug, and the only shape whose behavior CHANGES rather than starting to
# work. `values("note" => "qty")` projects qty under the name note; pre-fix `order_by("note")`
# emitted `ORDER BY "Tb"."note"` — the untouched note column, not the projected value. No error.
#
# Both backends resolve a SELECT alias in ORDER BY in preference to a same-named source column, so
# emitting the bare alias is what makes the sort agree with the projection the caller wrote.
# ─────────────────────────────────────────────────────────────────────────────
@testset "an alias shadowing a real column sorts the alias, not the column (#423)" begin
  for (label, conn) in (("PostgreSQL", _AO_PG), ("SQLite", _AO_SL))
    @testset "$label" begin
      q = AO.Ao_child.objects
      q.values("note" => "qty")
      q.order_by("note")

      sql = inspect_query(q; connection = conn)[:sql_text]

      @test occursin("\"Tb\".\"qty\" as \"note\"", sql)
      @test occursin("ORDER BY \"note\" ASC", sql)
      # Pre-fix this is what was emitted. It is valid SQL and returns rows in the wrong order.
      @test !occursin("ORDER BY \"Tb\".\"note\"", sql)
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# RETIRED by #441 — the ambiguity guard this file was written for is gone
# #423 refused `order_by("x")` when `values(...)` projected `x` twice over two different
# expressions, because PostgreSQL rejects an ambiguous ORDER BY alias while SQLite picks one
# arbitrarily. #441 moved the refusal upstream: `values()` now rejects two projections that would
# render the same output name, so `order_by` can no longer be handed a shared alias and the guard
# became unreachable.
#
# Six blocks went with it, all because their SETUP is now refused at `.values()` rather than at
# `order_by`: the guard's primary assertion (`values("x" => "note", "x" => "qty")`), its
# `values("note", "note")` identity control, the both-backends `Value("a")/Value("b")` pair, the
# mixed-pair message loop, `shadow_dup`, and the false-positive control below. Their coverage moves
# to `test_projection_names.jl`, which pins the refusal at its new site.
#
# Everything BELOW and above this note is untouched #423 behaviour and must keep passing — alias
# over a local column, alias over a join path, an alias shadowing a real column, a declared alias
# that is never rendered, and the controls block.
# ─────────────────────────────────────────────────────────────────────────────

# ─────────────────────────────────────────────────────────────────────────────
# A declared alias is always rendered, and orderable (#441 — was the inverse, #423)
# This testset used to pin the OPPOSITE. `values("note", "gg" => "note")` collapsed the second
# projection onto the first — `"gg" => "note"` has `_as == "note"`, which the bare `"note"` entry
# already cached — so `gg` never reached the SQL, and `order_by("gg")` had to raise
# `UnknownFieldError` rather than emit `ORDER BY "gg"` against a column that does not exist.
#
# That collapse WAS #441's symptom 1. It is fixed: the memo is reused only when the cached entry
# renders under the same OUTPUT name, so two names over one expression are now two output columns
# and `gg` is emitted. The scenario this testset guarded can no longer arise.
#
# Rewritten rather than deleted, on the instruction its own premise-check carried: "if the collapse
# ever stops happening, this testset is testing nothing and should be rewritten, not silently pass."
# What survives is the reason the old assertion mattered — `order_by` resolves against what is
# RENDERED, not what was declared. It still does; it now finds `gg` there.
# ─────────────────────────────────────────────────────────────────────────────
@testset "a declared alias is rendered and orderable (#441)" begin
  # The file docstring's contract that a name matching NO column still raises `UnknownFieldError`
  # lost its only assertion when the collapse-dependent testsets were retired. Restored here: the
  # branch is still live and still the loud path.
  for (label, conn) in (("PostgreSQL", _AO_PG), ("SQLite", _AO_SL))
    unknown = AO.Ao_child.objects
    unknown.values("note")
    unknown.order_by("no_such_name")
    err = try; inspect_query(unknown; connection = conn); nothing; catch e; e end
    @test err isa PormG.UnknownFieldError
    # Assert the CAUSE, not just the type: this function raises UnknownFieldError from more than
    # one site, so a bare type check would not prove the right one fired.
    @test occursin("no_such_name", sprint(showerror, err))
  end

  rendered = AO.Ao_child.objects
  rendered.values("note", "gg" => "note")
  sql = inspect_query(rendered; connection = _AO_PG)[:sql_text]
  # The same expression under two names is two output columns, not one emitted twice.
  @test occursin("as \"note\"", sql)
  @test occursin("as \"gg\"", sql)
  @test count("as \"gg\"", sql) == 1

  for (label, conn) in (("PostgreSQL", _AO_PG), ("SQLite", _AO_SL))
    @testset "$label" begin
      ordered = AO.Ao_child.objects
      ordered.values("note", "gg" => "note")
      ordered.order_by("gg")
      osql = inspect_query(ordered; connection = conn)[:sql_text]
      # `gg` is a real output column now, so ordering by it is legal on both backends — where it
      # previously had to be refused to keep PostgreSQL (which errors) aligned with SQLite (which
      # silently degrades `"gg"` to a constant string sort key and returns rows unsorted).
      @test occursin("as \"gg\"", osql)
      @test occursin("ORDER BY \"gg\"", osql)
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# Controls: every path that must stay byte-identical
# Two combinations change — `found_in_select` on a cache MISS (the branch inversion) and
# `found_in_select` on a cache HIT where the alias is genuinely ambiguous (the guard, which is not
# cache-gated). These pin the rest, and they are the real content of this file: the risk of this fix
# is not that the new shapes fail, it is that an old one moves.
# ─────────────────────────────────────────────────────────────────────────────
@testset "shapes that already worked are unchanged (#423 controls)" begin
  # Aggregate alias — worked before only because its chosen name IS `_as`, so the cache key matched.
  agg = AO.Ao_child.objects
  agg.values("note", "c" => Count("id"))
  agg.order_by("c")
  agg_sql = inspect_query(agg; connection = _AO_PG)[:sql_text]
  @test occursin("COUNT(\"Tb\".\"id\") as \"c\"", agg_sql)
  @test occursin("ORDER BY \"c\" ASC", agg_sql)
  # The aggregate must NOT be pushed into GROUP BY — that is what the dead `SQLTypeFunction` skip in
  # the projection scan would cause if someone "repaired" it. Assert the EXACT clause: an earlier
  # draft asserted `!occursin("GROUP BY 1, 2", …)`, which is unreachable by construction (this
  # function pushes resolved SQL expressions into `instruc.group`, never ordinals — a non-projected
  # order term renders `GROUP BY 1, "Tb"."qty"`), so it passed unconditionally. Review finding.
  @test occursin("GROUP BY 1 ", agg_sql)
  @test !occursin("COUNT", split(agg_sql, "GROUP BY")[2])

  # Window alias — same reason, different type.
  win = AO.Ao_child.objects
  win.values("note", "r" => Rank(over = WindowOver(partition_by = "parent", order_by = "qty")))
  win.order_by("r")
  @test occursin("ORDER BY \"r\" ASC", inspect_query(win; connection = _AO_PG)[:sql_text])

  # Value() alias — an SQLText projection, which caches under `custom_as` in the OTHER branch of
  # get_select_query. Its parameter must still be bound exactly once.
  val = AO.Ao_child.objects
  val.values("note", "lbl" => Value("hi"))
  val.order_by("lbl")
  val_res = inspect_query(val; connection = _AO_PG)
  @test occursin("ORDER BY \"lbl\" ASC", val_res[:sql_text])
  @test val_res[:parameters] == ["hi"]

  # Ordering by the UNDERLYING path while it is aliased: `_as` is the path, so `found_in_select` is
  # false and the cache branch resolves it to the qualified selector. Exactly one join.
  path = AO.Ao_child.objects
  path.values("note", "s" => "parent__sku")
  path.order_by("parent__sku")
  path_sql = inspect_query(path; connection = _AO_PG)[:sql_text]
  @test occursin("ORDER BY \"Tb_1\".\"sku\" ASC", path_sql)
  @test _ao_joins(path_sql) == 1

  # Unaliased projection: `_as` IS the path, so this took the alias branch before the fix too.
  bare = AO.Ao_child.objects
  bare.values("note", "parent__sku")
  bare.order_by("parent__sku")
  bare_sql = inspect_query(bare; connection = _AO_PG)[:sql_text]
  @test occursin("ORDER BY \"parent__sku\" ASC", bare_sql)
  @test _ao_joins(bare_sql) == 1

  # #404: a path named ONLY by order_by() still discovers and emits its join.
  only = AO.Ao_child.objects
  only.values("note")
  only.order_by("parent__sku")
  only_sql = inspect_query(only; connection = _AO_PG)[:sql_text]
  @test occursin("LEFT JOIN \"ao_parent\" AS \"Tb_1\"", only_sql)
  @test occursin("ORDER BY \"Tb_1\".\"sku\" ASC", only_sql)
  @test _ao_joins(only_sql) == 1

  # A filtered path ordered by the same path: bound once, one join.
  filt = AO.Ao_child.objects
  filt.values("note")
  filt.filter("parent__sku" => "X")
  filt.order_by("parent__sku")
  filt_res = inspect_query(filt; connection = _AO_PG)
  @test occursin("ORDER BY \"Tb_1\".\"sku\" ASC", filt_res[:sql_text])
  @test filt_res[:parameters] == ["X"]
  @test _ao_joins(filt_res[:sql_text]) == 1

  # #76: DISTINCT + an ORDER BY term that is genuinely NOT projected must still raise. The guard is
  # gated on `!found_in_select`, so inverting the branches must not have bypassed it.
  #
  # The message is asserted, not just the type: this change adds a SECOND `QueryBuildError` to this
  # same function (the ambiguity guard), so a bare `@test_throws QueryBuildError` would pass even if
  # the #76 guard had been bypassed and something else raised. Review finding.
  d = AO.Ao_child.objects
  d.values("note")
  d.distinct(true)
  d.order_by("qty")
  d_err = try
    inspect_query(d; connection = _AO_PG)
    nothing
  catch e
    e
  end
  @test d_err isa PormG.QueryBuildError
  @test occursin("DISTINCT query cannot ORDER BY", sprint(showerror, d_err))
end
