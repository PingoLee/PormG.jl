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
# An ambiguous alias is refused rather than resolved arbitrarily (#423)
# `.values()` does not reject two projections sharing a name. Once such a name resolves in ORDER BY,
# `ORDER BY "x"` is ambiguous: PostgreSQL raises at execution, SQLite picks one. Refusing at build
# time is what keeps the two aligned — otherwise this fix would trade a loud (if confusing)
# UnknownFieldError for a silent cross-backend divergence.
#
# Keyed on OBJECT IDENTITY, not on a match count and not on the rendered text. Two matching slots
# are safe exactly when they are the same `SQLField` — which is `get_select_query`'s own dedupe
# relation, so collapsed slots render byte-identical SQL, which is what PostgreSQL's `equal()`
# accepts. Naming the same expression twice therefore keeps working, and it keeps working for a
# reason that is true by construction rather than by proxy. Two earlier keys were wrong and both
# are pinned below: `_as` (blind to the SQLText branch) and rendered text (blind on SQLite, where
# every parameter renders as `?`).
#
# Note this guard is not gated on the cache, so it also moves the found_in_select && cache-HIT
# combination: `values("note", "note" => "qty")` used to render `ORDER BY "note"` and is now
# refused. That shape emits two output columns named "note" over different expressions, which
# PostgreSQL rejected at execution anyway, so the refusal is the aligned behavior — but it means
# TWO combinations change, not one. Pinned below so the claim stays honest.
# ─────────────────────────────────────────────────────────────────────────────
@testset "an ambiguous values() alias is refused in order_by() (#423)" begin
  amb = AO.Ao_child.objects
  amb.values("x" => "note", "x" => "qty")
  amb.order_by("x")

  err = try
    inspect_query(amb; connection = _AO_PG)
    nothing
  catch e
    e
  end
  @test err isa PormG.QueryBuildError
  msg = sprint(showerror, err)
  @test occursin("Ambiguous", msg)
  @test occursin("x", msg)
  # Names BOTH sources, so the caller can see which two projections collided.
  @test occursin("note", msg)
  @test occursin("qty", msg)

  # Control: the same expression projected twice shares `_as`, so it is not a new ambiguity. This
  # rendered before the fix and must still render — a guard keyed on the match count would break it.
  dup = AO.Ao_child.objects
  dup.values("note", "note")
  dup.order_by("note")
  @test occursin("ORDER BY \"note\" ASC", inspect_query(dup; connection = _AO_PG)[:sql_text])

  # Two `Value(...)` projections under one name. This is the case an `_as`-keyed guard MISSES: the
  # `SQLText` branch of `get_select_query` assigns unconditionally without consulting the cache, so
  # both entries carry `_as == "lbl"` while rendering two different Params. PostgreSQL sees two
  # unequal expressions under one output name and raises `ORDER BY "lbl" is ambiguous`, while an
  # `_as`-keyed guard sees one name and stays silent. Review finding — that draft justified `_as` as
  # a faithful proxy for PostgreSQL's rule, and it is not one for this branch.
  # BOTH backends, deliberately. A rendered-text key made this throw on PostgreSQL (`$1`/`$2`) and
  # render on SQLite (`?`/`?`) — the guard against divergence introducing one, with the strict
  # engine refusing while the lax engine sorted by an arbitrary one of two DIFFERENT values.
  # Identity keying removes the split, and looping here is what would catch its return.
  for (label, conn) in (("PostgreSQL", _AO_PG), ("SQLite", _AO_SL))
    @testset "$label" begin
      val_amb = AO.Ao_child.objects
      val_amb.values("note", "lbl" => Value("a"), "lbl" => Value("b"))
      val_amb.order_by("lbl")
      val_err = try
        inspect_query(val_amb; connection = conn)
        nothing
      catch e
        e
      end
      @test val_err isa PormG.QueryBuildError
      @test occursin("Ambiguous", sprint(showerror, val_err))
    end
  end

  # A mixed pair — one field path, one Value — must name each side on its own terms. Choosing
  # globally printed the ordered alias back as one of its own sources ("over note and x"), which is
  # circular; the message must read "over note and <expr>" in either declaration order.
  for vals in (("x" => "note", "x" => Value("hi")), ("x" => Value("hi"), "x" => "note"))
    mixed = AO.Ao_child.objects
    mixed.values(vals...)
    mixed.order_by("x")
    mixed_err = try
      inspect_query(mixed; connection = _AO_PG)
      nothing
    catch e
      e
    end
    @test mixed_err isa PormG.QueryBuildError
    mixed_msg = sprint(showerror, mixed_err)
    @test occursin("note", mixed_msg)
    # Never names the ordered alias itself as a source.
    @test !occursin("over x and", mixed_msg)
    @test !occursin("and x.", mixed_msg)
  end

  # The second combination this change moves: an alias that shadows another projection's name over
  # a DIFFERENT expression. `values("note", "note" => "qty")` renders `as "note"` twice, so it was
  # already ambiguous to PostgreSQL at execution; it now fails at build time instead. Pinned so the
  # "only one combination changes" claim cannot quietly reappear.
  shadow_dup = AO.Ao_child.objects
  shadow_dup.values("note", "note" => "qty")
  shadow_dup.order_by("note")
  @test_throws PormG.QueryBuildError inspect_query(shadow_dup; connection = _AO_PG)
end

# ─────────────────────────────────────────────────────────────────────────────
# The alias set comes from what is RENDERED, not from what was declared (#423)
# `get_select_query` collapses a projection whose `_as` is already cached onto the cached SQLField
# and discards its `custom_as`, so a declared name can fail to reach the SQL entirely. Deriving
# `found_in_select` from `object.values` therefore trusted a name that is never emitted.
#
# This is the defect an independent review caught in the first draft of this fix, and it was
# strictly worse than the bug being fixed: `ORDER BY "gg"` names neither an output nor an input
# column, so PostgreSQL raises `column "gg" does not exist` while SQLite's double-quoted-string
# fallback degrades it to the literal 'gg' — a constant sort key — and returns the rows UNSORTED
# with no error. Silent wrong answer on one backend, runtime error on the other, replacing a clean
# build-time `UnknownFieldError`. Scanning `instruc.select` is what keeps it on the loud path.
# ─────────────────────────────────────────────────────────────────────────────
@testset "a declared alias that is never rendered is not treated as projected (#423)" begin
  # `"gg" => "note"` has `_as == "note"`, which the bare `"note"` entry already cached, so the
  # second projection collapses onto the first and renders `as "note"` — `gg` never appears.
  collapsed = AO.Ao_child.objects
  collapsed.values("note", "gg" => "note")

  # Confirm the premise rather than assuming it: if the collapse ever stops happening, this testset
  # is testing nothing and should be rewritten, not silently pass.
  @test !occursin("as \"gg\"", inspect_query(collapsed; connection = _AO_PG)[:sql_text])

  # These two are the discriminating assertions: under the declared-list scan, `order_by("gg")`
  # took the `found_in_select` branch and rendered `ORDER BY "gg"` without throwing at all.
  # The cause is asserted too — this function raises more than one error type, so a bare type check
  # would not prove the right one fired.
  for (label, conn) in (("PostgreSQL", _AO_PG), ("SQLite", _AO_SL))
    @testset "$label" begin
      ordered = AO.Ao_child.objects
      ordered.values("note", "gg" => "note")
      ordered.order_by("gg")
      err = try
        inspect_query(ordered; connection = conn)
        nothing
      catch e
        e
      end
      @test err isa PormG.UnknownFieldError
      @test occursin("gg", sprint(showerror, err))
    end
  end

  # ...and the ambiguity guard must not fire on a name only ONE rendered column carries. Here
  # `"z" => "note"` collapses away, so exactly one `as "z"` is emitted and the sort is unambiguous.
  # Scanning the declared list reported a collision between `note` and `qty` that the SQL does not
  # contain — the same review finding, in its false-positive direction.
  #
  # The discriminating part is that this RENDERS AT ALL: under the declared-list scan the guard
  # raised here. The `count == 1` below is a premise check like the one above — it describes
  # `get_select_query`'s collapse, which this fix does not touch, so it holds in either state.
  single = AO.Ao_child.objects
  single.values("note", "z" => "note", "z" => "qty")
  single.order_by("z")
  single_sql = inspect_query(single; connection = _AO_PG)[:sql_text]
  @test count("as \"z\"", single_sql) == 1
  @test occursin("ORDER BY \"z\" ASC", single_sql)
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
