"""
Unit coverage for #444 — CTE columns get their own namespace, `CTE(name, path)`.

Before this, a `.with()` CTE name and a model field path shared ONE `__`-separated string namespace,
and `_build_row_join` resolved them first-match-wins with the CTE registry checked FIRST. That single
ordering choice manufactured two bugs, and both are now unrepresentable rather than guarded:

  - #431 — `.with("parent" => cte)` on a model that HAS a `parent` ForeignKey made `parent__sku` mean
    the CTE's column; the FK's join was never emitted and every base row was CROSS-joined against
    every CTE row. Silent wrong rows, with the #44 Cartesian warning naming the wrong problem.
  - #434 — `.on()`'s CTE refusal read the registry at `.on()` time, so `.with()`-then-`.on()` was
    refused while `.on()`-then-`.with()` slipped past into a different error at a later stage.

The load-bearing test here is `"#431: a CTE and a ForeignKey may share a name"` — it puts BOTH
references in ONE query and asserts both resolve. That is the thing a construction-time collision
guard (Django's answer, ticket #11256) could never provide, and it is why #444 chose separate
namespaces over refusing the name.

Everything renders through mock connections — no live database.

Sibling coverage:
  - `test_cte_ergonomics.jl`  → #44 correlation of an unkeyed CTE (now via a `CTE(...)` RHS handle).
  - `test_cte_db_column.jl`   → #376, a CTE exposes projection aliases, never `db_column`.
  - `test_order_by_joins.jl`  → #424/#435, the ON-predicate-on-a-CROSS-CTE guard. Three of its four
                                producers survive this change; only the relocation route is gone.
  - `test_cte.jl` (integration) → the same surface against the real F1 dataset, both backends.
"""

using Test
using PormG
using PormG.Models

# Mock connections under a dedicated config key so this file cannot contaminate (or be contaminated
# by) other unit files sharing Main in runtests.jl. Only the connection TYPE matters — dispatch picks
# SQLite `?` / PostgreSQL `$N` rendering.
struct CteRefMockSQLite <: PormG.PormGSQLite end
struct CteRefMockPostgres <: PormG.PormGPostgres end
const _CR_SL = CteRefMockSQLite()
const _CR_PG = CteRefMockPostgres()
PormG.backend_sqlite_version(::CteRefMockSQLite) = 3045000

PormG.config["cte_ref_mock"] = PormG.Configuration.Settings(
  connections = _CR_SL,
  change_data = true,
  db_def_folder = "cte_ref_mock",
)

# The #431/#434 reproduction fixture, verbatim from both issue bodies: `Cj_child.parent` is a real
# ForeignKey, so `.with("parent" => …)` collides with it by NAME. `sku` carries a `db_column` so the
# #376 contract (a CTE exposes its projection ALIAS, never the physical column) stays under test on
# the new spelling too.
module CteRefModels
import PormG
import PormG.Models

Cj_grand = Models.Model("cj_grand", id = Models.IDField(), code = Models.CharField())

Cj_parent = Models.Model("cj_parent",
  id          = Models.IDField(),
  sku         = Models.CharField(db_column = "product_sku"),
  seen        = Models.DateField(null = true),
  meta        = Models.JSONField(null = true),
  grandparent = Models.ForeignKey(Cj_grand, on_delete = "CASCADE", related_name = "cj_pars", null = true),
)

Cj_child = Models.Model("cj_child",
  id     = Models.IDField(),
  parent = Models.ForeignKey(Cj_parent, on_delete = "CASCADE", related_name = "cj_kids", null = true),
  note   = Models.CharField(null = true),
)

PormG.Models.set_models(@__MODULE__, "cte_ref_mock")
end

const CR = CteRefModels
import PormG.QueryBuilder: F, inspect_query, Joined

# CTE bodies reused across cases.
_parent_cte()  = (c = CR.Cj_parent.objects; c.values("id", "sku"); c)
_full_cte()    = (c = CR.Cj_parent.objects; c.values("id", "sku", "seen", "meta", "grandparent"); c)

_sql(q; conn = _CR_SL) = inspect_query(q; connection = conn)[:sql_text]

@testset "CTE reference object — CTE(name, path) (#444)" begin

  # ─────────────────────────────────────────────────────────────────────────────
  # #431: a CTE and a ForeignKey may share a name — THE test for this issue.
  # `.with("parent" => …)` on a model whose `parent` IS a ForeignKey. Both references appear in one
  # projection: `"parent__sku"` must emit the FK's join to `cj_parent`, and `CTE("parent","sku")`
  # must emit the join to the CTE. Two joins, two distinct aliases, no error, no CROSS JOIN.
  # Pre-#444 the CTE won outright and the FK's join was never emitted at all.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "#431: a CTE and a ForeignKey may share a name" begin
    for (backend, conn) in (("PostgreSQL", _CR_PG), ("SQLite", _CR_SL))
      q = CR.Cj_child.objects
      q.with("parent" => _parent_cte(), join_field = "id" => "id")
      q.values("note", "parent__sku", "cte_sku" => CTE("parent", "sku"))
      sql = _sql(q; conn = conn)

      # Both assertions name the JOIN keyword deliberately. `occursin("\"parent\" AS", sql)` alone
      # is VACUOUS — the `WITH "parent" AS (` header satisfies it even when the CTE is declared and
      # never joined at all (measured: that query gives `true` with zero JOINs). An assertion that
      # cannot fail is worse than no assertion, because it reads as coverage.
      @test occursin("JOIN \"cj_parent\" AS", sql)   # the ForeignKey's join — #431's missing one
      @test occursin("JOIN \"parent\" AS", sql)      # the CTE's join, separately
      # Two joins, not one: the FK hop and the CTE hop are distinct relations.
      @test length(collect(eachmatch(r"LEFT JOIN", sql))) == 2
      # #44's Cartesian shape must NOT appear — the CTE is keyed by join_field here.
      @test !occursin("CROSS JOIN", sql)
      # #376: the CTE exposes the projection ALIAS `sku`, never the `db_column` "product_sku"; the
      # FK path, reaching a real table, resolves its db_column as always. Both are in this one SQL.
      @test occursin("\"product_sku\"", sql)   # the FK-joined real column
      @test occursin("as \"parent__sku\"", sql)
      @test occursin("as \"cte_sku\"", sql)
    end
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # #431 control: with the two references swapped in meaning, each still resolves to its own side.
  # A filter on the FK path must constrain `cj_parent`; a filter on the CTE handle must constrain
  # the CTE's alias. If the namespaces ever re-merge, one of these two predicates moves table.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "#431: filters route to the side they name" begin
    q = CR.Cj_child.objects
    q.with("parent" => _parent_cte(), join_field = "id" => "id")
    q.values("note")
    q.filter("parent__sku" => "FK-SIDE")
    q.filter(CTE("parent", "sku") => "CTE-SIDE")
    r = inspect_query(q; connection = _CR_PG)

    # Both values bind, in the order they were declared — neither predicate was dropped or merged.
    @test "FK-SIDE" in r[:parameters]
    @test "CTE-SIDE" in r[:parameters]
    # Two separate joins carry them.
    @test length(collect(eachmatch(r"LEFT JOIN", r[:sql_text]))) == 2
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # Reference classes A/B/D: projection (bare + aliased), filter, ordering.
  # The unaliased projection name is `name__path` (#444 decision 2), which is byte-identical to the
  # column the pre-#444 string spelling emitted — that is what keeps result-side code (DataFrame
  # accessors like `df[1, :ev__sku]`) working unchanged across the break.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "classes A/B/D: values, filter, order_by" begin
    @testset "A — unaliased projection is named name__path" begin
      q = CR.Cj_child.objects
      q.with("ev" => _parent_cte(), join_field = "id" => "id")
      q.values("note", CTE("ev", "sku"))
      @test occursin("as \"ev__sku\"", _sql(q))
    end

    @testset "A — aliased projection uses the caller's alias" begin
      q = CR.Cj_child.objects
      q.with("ev" => _parent_cte(), join_field = "id" => "id")
      q.values("note", "s" => CTE("ev", "sku"))
      sql = _sql(q)
      @test occursin("as \"s\"", sql)
      @test !occursin("as \"ev__sku\"", sql)
    end

    @testset "B — filter on a CTE column" begin
      q = CR.Cj_child.objects
      q.with("ev" => _parent_cte(), join_field = "id" => "id")
      q.values("note")
      q.filter(CTE("ev", "sku") => "ABC")
      r = inspect_query(q; connection = _CR_SL)
      @test occursin("WHERE", r[:sql_text])
      @test r[:parameters] == Any["ABC"]
    end

    @testset "B2 — operator suffix inside the path" begin
      q = CR.Cj_child.objects
      q.with("ev" => _parent_cte(), join_field = "id" => "id")
      q.values("note")
      q.filter(CTE("ev", "sku__@icontains") => "AB")
      r = inspect_query(q; connection = _CR_SL)
      @test occursin("LIKE", r[:sql_text])
      @test r[:parameters] == Any["%AB%"]
    end

    @testset "B2b — the #352/#373 sargable date rewrite still fires through a CTE handle" begin
      # This is the shape that silently regressed while #444 was being built: the rewrite gate reads
      # `FObject.column`, which is a CTE handle now rather than a String, so without an explicit
      # admission it returned `nothing` and the predicate degraded to a non-sargable
      # `to_char(col,'YYYY-MM') <= '1991-10'`. Asserting the REWRITTEN shape (a range on the raw
      # column, bound to the first day of the following month) is what pins it.
      q = CR.Cj_child.objects
      q.with("ev" => _full_cte(), join_field = "id" => "id")
      q.values("note")
      q.filter(CTE("ev", "seen__@yyyy_mm__@lte") => "1991-10")
      r = inspect_query(q; connection = _CR_PG)
      @test !occursin("to_char", r[:sql_text])          # the function call is GONE from the predicate
      @test occursin("\"seen\" <", r[:sql_text])        # ranged directly on the column
      @test r[:parameters] == Any["1991-11-01"]         # first day of the FOLLOWING period
    end

    @testset "B2c — a COMPOSITE transform over a CTE column renders (#481)" begin
      # `@quarter` and `@quadrimester` do not build one function over the column: they expand to
      # `Concat([Cast(Year(x)), Value("-Q"), Case([When(...)])])`, so the retag walk meets an
      # `SQLText` literal, an `SQLField` wrapper and the `OperObject` inside each `When`. The walk
      # handled only functions and vectors, so both keys raised
      # `QueryBuildError("Internal: a CTE reference resolved to an unexpected column expression")`
      # — telling the caller to report a bug for a documented transform. Found while building the
      # `Joined` twin (#481), which had inherited the same hole; fixed on both.
      for key in ("quarter", "quadrimester")
        q = CR.Cj_child.objects
        q.with("ev" => _full_cte(), join_field = "id" => "id")
        q.values("note", "bucket" => CTE("ev", "seen__@$(key)"))
        sql = inspect_query(q; connection = _CR_PG)[:sql_text]
        # It reads the CTE's own column under the CTE's generated alias, not the base model's.
        @test occursin("\"R1_1\".\"seen\"", sql)
        @test occursin("as \"bucket\"", sql)
      end
    end

    @testset "B3 — JSON sub-path inside the path" begin
      q = CR.Cj_child.objects
      q.with("ev" => _full_cte(), join_field = "id" => "id")
      q.values("note")
      q.filter(CTE("ev", "meta__driver") => "senna")
      r = inspect_query(q; connection = _CR_PG)
      @test occursin("meta", r[:sql_text])
      @test "senna" in r[:parameters]
    end

    @testset "D — order_by, ASC and DESC" begin
      # A reference object cannot carry the string form's leading `-`, so the direction is a keyword
      # on the constructor (#444 decision 4). ASC/DESC also pick up the #75 NULLS placement default.
      q = CR.Cj_child.objects
      q.with("ev" => _parent_cte(), join_field = "id" => "id")
      q.values("note", "s" => CTE("ev", "sku"))
      q.order_by(CTE("ev", "sku"))
      @test occursin("ASC", _sql(q))

      q2 = CR.Cj_child.objects
      q2.with("ev" => _parent_cte(), join_field = "id" => "id")
      q2.values("note", "s" => CTE("ev", "sku"))
      q2.order_by(CTE("ev", "sku"; desc = true))
      @test occursin("DESC", _sql(q2))
    end

    @testset "D — #404: order_by on a CTE column that is neither filtered nor projected" begin
      # The join must still be emitted. Pre-#404 the ORDER BY named an alias nothing joined.
      q = CR.Cj_child.objects
      q.with("ev" => _parent_cte(), join_field = "id" => "id")
      q.values("note")
      q.order_by(CTE("ev", "sku"))
      sql = _sql(q)
      @test occursin("LEFT JOIN \"ev\"", sql)
      @test occursin("ORDER BY", sql)
    end
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # Class C: correlating an UNKEYED CTE (#44). Declared without `join_field`, the CTE is CROSS
  # JOINed and the correlation is supplied by a predicate in WHERE. Pre-#444 that predicate was
  # spelled `filter("parent" => F("r91__id"))`; the CTE handle now says the same thing directly, on
  # the RIGHT-hand side of the pair, where it means "a column" exactly as `F(...)` does.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "class C: RHS handle correlates an unkeyed CTE (#44)" begin
    q = CR.Cj_child.objects
    q.with("r91" => _parent_cte())
    q.values("note")
    q.filter("parent" => CTE("r91", "id"))
    r = inspect_query(q; connection = _CR_SL)
    @test occursin("CROSS JOIN \"r91\"", r[:sql_text])
    # Column-to-column: the correlation renders verbatim, binding NO parameter.
    @test isempty(r[:parameters])
    @test occursin("WHERE", r[:sql_text])
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # `F(col) == CTE(...)` — the comparison-operator spelling of the same correlation.
  # This is pinned because it silently broke twice while #444 was being built, each time producing
  # VALID SQL rather than an error:
  #   1. `CTEReference` was not in the operand union of `Base.:(==)(::FExpression, …)`, so the call
  #      fell through to `Base.==` and evaluated to `false` — `filter(false)`.
  #   2. Once admitted, `_set_update_query_operand`'s `isa` chain had no arm for it, so it fell to
  #      `add_parameter!` and bound the handle as a VALUE: `"R1"."note" = ?`, with the CTE never
  #      joined at all. A query that runs and compares a column against a stringified struct.
  # Both are the exact failure class this issue exists to eliminate, so they get an assertion each:
  # the CROSS JOIN must appear, and NO parameter may be bound.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "F(col) == CTE(...) is a column comparison, not a bound value" begin
    for (op, label) in ((==, "=="), (!=, "!="))
      q = CR.Cj_child.objects
      q.with("ev" => _parent_cte())
      q.values("note")
      q.filter(op(F("note"), CTE("ev", "sku")))
      r = inspect_query(q; connection = _CR_SL)
      @test occursin("CROSS JOIN \"ev\"", r[:sql_text])   # the CTE IS joined
      @test isempty(r[:parameters])                       # nothing was bound as a value
    end
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # The path is a PATH, not a bare column: it hops out of the CTE through a projected ForeignKey.
  # `CTE("ev","grandparent__code")` joins cj_grand off the CTE's projected FK column.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "path hops out of the CTE through a projected ForeignKey" begin
    q = CR.Cj_child.objects
    q.with("ev" => _full_cte(), join_field = "id" => "id")
    q.values("note", "gc" => CTE("ev", "grandparent__code"))
    sql = _sql(q)
    @test occursin("\"cj_grand\" AS", sql)
    @test occursin("as \"gc\"", sql)
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # #434: `.on()` is order-independent, in BOTH directions.
  # The pre-#444 check read the CTE registry at `.on()` time, so only one ordering was caught. The
  # check is deleted, not moved: `on()`'s argument is now unambiguously a FIELD path, so a segment
  # naming only a CTE is simply not a relation — and that verdict cannot depend on declaration order.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "#434: on() targeting a CTE name is refused in both orderings" begin
    core = "is not a relation on model"

    # Ordering 1 — `.with()` first (the one that WAS caught).
    err1 = try
      q = CR.Cj_child.objects
      q.with("recent" => _parent_cte())
      q.on("recent", "sku" => "S")
      nothing
    catch e; e end
    @test err1 isa PormG.QueryBuildError
    @test occursin(core, err1.msg)

    # Ordering 2 — `.on()` first (the one that ESCAPED, and later died with a different, wrong
    # message about CROSS-joined CTEs from #424's guard). Same type, same core sentence, same stage.
    err2 = try
      q = CR.Cj_child.objects
      q.on("recent", "sku" => "S")
      q.with("recent" => _parent_cte())
      nothing
    catch e; e end
    @test err2 isa PormG.QueryBuildError
    @test occursin(core, err2.msg)

    # The refusal happens at `.on()` in both orderings — not deferred to build in one of them.
    @test occursin("Join path 'recent'", err1.msg)
    @test occursin("Join path 'recent'", err2.msg)

    # The CTE-aware hint is best-effort and additive: it appears only when the CTE is already
    # declared at that instant. In ordering 2 the CTE does not exist yet, so there is nothing
    # truthful to say about it — the absence is correct, not a gap. What #434 reported (a DIFFERENT
    # outcome per ordering) is gone either way.
    @test occursin("is a CTE declared on this query", err1.msg)
    @test !occursin("is a CTE declared on this query", err2.msg)
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # #434/#431 control: `on()` on a path that names a real ForeignKey now WORKS even when a CTE of
  # the same name is declared. Pre-#444 this exact call was refused outright ("on() does not target
  # CTE names") — the field was unreachable because the CTE had taken its name.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "#434: on() reaches a ForeignKey whose name a CTE also uses" begin
    q = CR.Cj_child.objects
    q.with("parent" => _parent_cte())
    q.on("parent", "sku" => "S")
    q.values("note", "parent__sku")
    r = inspect_query(q; connection = _CR_SL)
    # The ON predicate landed on the ForeignKey's join, against the real table.
    @test occursin("\"cj_parent\" AS", r[:sql_text])
    @test occursin("ON ", r[:sql_text])
    @test "S" in r[:parameters]
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # SCALAR functions and window clauses accept a CTE handle — the aggregates are the ONLY refusal.
  #
  # These regressed silently while #444 was being built: the reference used to be a plain String,
  # which the `Union{String, SQLTypeField, SQLTypeText, SQLTypeFunction, SQLTypeF}` signatures in
  # functions.jl (and `WindowPartitionPart` / `WindowOrderPart`) already admitted. Swapping in a
  # typed handle without widening them turned three WORKING shapes into a bare `MethodError` —
  # outside the #231 taxonomy, and a capability loss nobody asked for. Caught by rendering the same
  # shapes against `main` and diffing, not by reading the code.
  #
  # The aggregate refusal is unaffected: `Sum`/`Avg`/`Count`/`Max`/`Min` carry explicit
  # `::CTEReference` methods, and a concrete method beats a union on dispatch.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "scalar functions and window clauses accept a CTE handle" begin
    @testset "Lower / Upper / Cast wrap a CTE column" begin
      q = CR.Cj_child.objects
      q.with("ev" => _parent_cte(), join_field = "id" => "id")
      q.values("note", "l" => PormG.Functions.Lower(CTE("ev", "sku")))
      @test occursin("LOWER(", uppercase(_sql(q)))

      q2 = CR.Cj_child.objects
      q2.with("ev" => _parent_cte(), join_field = "id" => "id")
      q2.values("note", "c" => PormG.Functions.Cast(CTE("ev", "sku"), "text"))
      @test occursin("CAST", uppercase(_sql(q2)))
    end

    @testset "ToChar / Extract / When accept a CTE column" begin
      # Found by the delta re-review: the widening pass missed these three. `ToChar` and `Extract`
      # carry a `Vector{String}` member their siblings do not, so they did not match the pattern the
      # script swept; `When` dispatches on the PAIR KEY type, so it needed a new method rather than a
      # widened union. `Case`/`When` is the one that stings — a CASE over a CTE column has no other
      # spelling, so a MethodError there is a capability loss with no workaround.
      @test PormG.Functions.ToChar(CTE("ev", "seen"), "YYYY-MM") isa PormG.SQLTypeFunction
      @test PormG.Functions.Extract(CTE("ev", "seen"), "YEAR") isa PormG.SQLTypeFunction
      @test PormG.Functions.When(CTE("ev", "sku") => "A", then = 1) isa PormG.SQLTypeFunction

      q = CR.Cj_child.objects
      q.with("ev" => _full_cte(), join_field = "id" => "id")
      q.values("note", "b" => PormG.Functions.Case(
        PormG.Functions.When(CTE("ev", "sku") => "A", then = 1), default = 0))
      sql = _sql(q)
      @test occursin("CASE", uppercase(sql))
      @test occursin("JOIN \"ev\" AS", sql)     # the CASE's CTE column really emitted its join
    end

    @testset "window PARTITION BY / ORDER BY over a CTE column" begin
      q = CR.Cj_child.objects
      q.with("ev" => _parent_cte(), join_field = "id" => "id")
      q.values("note", "rk" => PormG.Functions.Rank(
        over = PormG.Functions.WindowOver(partition_by = CTE("ev", "sku"))))
      @test occursin("PARTITION BY", _sql(q))

      # A window ORDER BY is the SECOND legitimate home for `desc = true` (the fluent `order_by` is
      # the first), so the handle must be accepted there WITH the flag rather than refused by the
      # generic "desc only in order_by" guard.
      q2 = CR.Cj_child.objects
      q2.with("ev" => _parent_cte(), join_field = "id" => "id")
      q2.values("note", "rn" => PormG.Functions.RowNumber(
        over = PormG.Functions.WindowOver(order_by = CTE("ev", "sku"; desc = true))))
      sql = _sql(q2)
      @test occursin("ORDER BY", sql) && occursin("DESC", sql)
    end
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # Refusals. Each one exists because the alternative is a silently wrong query or an untyped
  # MethodError outside the #231 taxonomy.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "refusals" begin
    @testset "a CTE handle cannot appear in on() / cjoin()" begin
      err = try
        q = CR.Cj_child.objects
        q.with("ev" => _parent_cte())
        q.on("parent", CTE("ev", "sku") => "S")
        nothing
      catch e; e end
      @test err isa PormG.FilterError
      @test occursin("cannot be used in", err.msg)
      @test occursin("ON clause", err.msg)
    end

    @testset "a CTE handle cannot appear in a cjoin_on `on` expression" begin
      # `_cjoin_on` deliberately skips `_prefix_join_filter` (it must reference BOTH sides), so it
      # carries its own copy of the refusal. Without it this arm would silently accept the handle.
      err = try
        q = CR.Cj_child.objects
        q.with("ev" => _parent_cte())
        q.cjoin_on("Cj_parent", alias = "b2", on = [CTE("ev", "sku") => "S"])
        nothing
      catch e; e end
      @test err isa PormG.FilterError
      @test occursin("cjoin_on", err.msg)
    end

    @testset "a CTE handle nested inside Q() is refused too" begin
      # A Q element reaches the join machinery already converted to an OperObject, so the refusal
      # has to look inside it as well as at raw Pairs.
      err = try
        q = CR.Cj_child.objects
        q.with("ev" => _parent_cte())
        q.on("parent", PormG.Q(CTE("ev", "sku") => "S"))
        nothing
      catch e; e end
      # Assert the SPECIFIC type and message: `err isa PormGError` would be satisfied by any PormG
      # error at all, including one raised for an unrelated reason before the guard was reached.
      @test err isa PormG.FilterError
      @test occursin("cannot be used in", err.msg)
    end

    @testset "an F comparison cannot smuggle a handle into a join ON clause" begin
      # Found by review. `F("sku") == CTE("ev","sku")` builds an FExpression, which IS a FilterType,
      # so on()/cjoin()/cjoin_on() accepted it as an element — and the guards enumerated Pair, Q,
      # Qor and OperObject but had no FExpression arm. The predicate was accepted and then resolved
      # onto the CTE'''s OWN join instead of the join the caller named:
      #
      #   LEFT JOIN "cj_parent" AS "R1_1" ON "R1"."parent" = "R1_1"."id"
      #   LEFT JOIN "ev"        AS "R1_2" ON "R1"."id" = "R1_2"."id" AND ("R1_1"."sku" = "R1_2"."sku")
      #                                                                 ^ the caller put this on R1_1
      #
      # Valid SQL, different result set, no error — the exact class #444 exists to close.
      for (label, build) in (
        ("on()",       () -> (q = CR.Cj_child.objects;
                              q.with("ev" => _parent_cte(), join_field = "id" => "id");
                              q.on("parent", F("sku") == CTE("ev", "sku")))),
        ("cjoin()",    () -> (q = CR.Cj_child.objects;
                              q.with("ev" => _parent_cte(), join_field = "id" => "id");
                              q.cjoin("parent" => "Cj_parent",
                                      filters = [F("sku") == CTE("ev", "sku")], warn = false))),
        ("cjoin_on()", () -> (q = CR.Cj_child.objects;
                              q.with("ev" => _parent_cte());
                              q.cjoin_on("Cj_parent", alias = "b2",
                                         on = [Joined("b2", "sku") == CTE("ev", "sku")]))),
        ("!= operator", () -> (q = CR.Cj_child.objects;
                              q.with("ev" => _parent_cte(), join_field = "id" => "id");
                              q.on("parent", F("sku") != CTE("ev", "sku")))),
      )
        err = try; build(); nothing; catch e; e end
        @test err isa PormG.FilterError
        @test occursin("cannot be used in", err.msg)
      end
    end

    @testset "a handle NESTED in a pair's RHS cannot reach a join ON clause either" begin
      # Found by the delta re-review, after the first fix. The guards' `Pair` arm tested
      # `filter.second isa CTEReference` — a FLAT test, which walks straight past a handle sitting
      # inside an expression on the RHS. The predicate was accepted, relocated onto the CTE's own
      # join, and rendered SQL that is not merely mis-routed but type-nonsense:
      #
      #   ON … AND "R1_1"."product_sku" = ("R1"."note" = "R1_2"."sku")
      #             varchar             =  boolean
      #
      # (PostgreSQL raises; SQLite silently compares against 0/1.) Both arms now recurse.
      for (label, build) in (
        ("on(), keyed CTE",   () -> (q = CR.Cj_child.objects;
                                     q.with("ev" => _parent_cte(), join_field = "id" => "id");
                                     q.on("parent", "sku" => (F("note") == CTE("ev", "sku"))))),
        ("on(), UNKEYED CTE", () -> (q = CR.Cj_child.objects;
                                     q.with("zz" => _parent_cte());
                                     q.on("parent", "sku" => (F("note") == CTE("zz", "sku"))))),
        ("cjoin()",           () -> (q = CR.Cj_child.objects;
                                     q.with("ev" => _parent_cte(), join_field = "id" => "id");
                                     q.cjoin("parent" => "Cj_parent",
                                             filters = ["sku" => (F("note") == CTE("ev", "sku"))],
                                             warn = false))),
        ("inside Q()",        () -> (q = CR.Cj_child.objects;
                                     q.with("ev" => _parent_cte(), join_field = "id" => "id");
                                     q.on("parent", PormG.Q("sku" => (F("note") == CTE("ev", "sku")))))),
      )
        err = try; build(); nothing; catch e; e end
        @test err isa PormG.FilterError
        @test occursin("cannot be used in", err.msg)
      end
    end

    @testset "the join guard terminates on a self-referential F expression" begin
      # A cycle in the expression graph makes the recursive sweep a StackOverflowError — which Julia
      # reports as "program state may be corrupted" — so it needs a depth cap. `cjoin_on` is the path
      # that matters: it never recursed before #444, so this exposure is new here.
      #
      # #457 changed how the cycle has to be BUILT, not whether the cap is needed. The comparison
      # overloads used to mutate their left operand, so `f = F("x"); g = (f == f)` returned an object
      # containing itself and any user could write one by accident. They build a new expression now,
      # so that route is gone (`test_f_expression_immutability.jl` owns it) — but `FExpression` is a
      # mutable struct, so an internal `g.operand = g` is still one assignment away. Hand-build it,
      # which is the only thing the cap defends against any more.
      g = F("sku")
      g.operation = "="
      g.operand = g
      @test g.operand === g          # the cycle really is a cycle, or this test proves nothing
      q = CR.Cj_child.objects
      q.with("ev" => _parent_cte())
      @test_nowarn q.cjoin_on("Cj_parent", alias = "b2", on = [g])
    end

    @testset "Value() refuses a CTE handle" begin
      # Found by review. `Value(x::Any)` wraps a LITERAL, so the handle was bound as a parameter:
      # `SELECT ? as "x"` with the struct itself in the parameter vector and no join emitted.
      err = try; PormG.Functions.Value(CTE("ev", "sku")); nothing; catch e; e end
      @test err isa PormG.QueryBuildError
      @test occursin("wraps a literal", err.msg)
    end

    @testset "a CTE handle as an update() SET value raises the accurate #433 error" begin
      # Found by review. It reached the field formatter and died with a bare MethodError — outside
      # the #231 taxonomy. A handle is unambiguously a COLUMN, and `update()` emits no WITH clause,
      # so the right answer is #433'''s message, which is what `F("<cte>__col")` produced pre-#444.
      err = try
        q = CR.Cj_child.objects
        q.with("ev" => _parent_cte(), join_field = "id" => "id")
        q.filter("note" => "keep")
        q.update("note" => CTE("ev", "sku"), show_query = :sql)
        nothing
      catch e; e end
      @test err isa PormG.QueryBuildError
      @test occursin("emits no", err.msg) && occursin("WITH", err.msg)
    end

    @testset "the #441 duplicate-name message spells the handle as the caller wrote it" begin
      # Found by review. It fell through to `nameof(typeof(f))` and printed a bare `CTEReference` —
      # a spelling that appears nowhere in the caller'''s source, which is precisely what
      # `_describe_projection` exists to avoid.
      err = try
        q = CR.Cj_child.objects
        q.with("parent" => _parent_cte(), join_field = "id" => "id")
        q.values("parent__sku", CTE("parent", "sku"))
        nothing
      catch e; e end
      @test err isa PormG.QueryBuildError
      @test occursin("CTE(\"parent\", \"sku\")", err.msg)
      @test !occursin("CTEReference", err.msg)
    end

    @testset "desc = true is refused outside order_by" begin
      for build in (
        () -> (q = CR.Cj_child.objects; q.with("ev" => _parent_cte()); q.values(CTE("ev", "sku"; desc = true))),
        () -> (q = CR.Cj_child.objects; q.with("ev" => _parent_cte()); q.filter(CTE("ev", "sku"; desc = true) => "X")),
      )
        err = try; build(); nothing; catch e; e end
        @test err isa PormG.QueryBuildError
        @test occursin("only", err.msg) && occursin("order_by", err.msg)
      end
    end

    @testset "construction validates name and path" begin
      err_path = try; CTE("ev", ""); nothing; catch e; e end
      @test err_path isa PormG.QueryBuildError
      @test occursin("requires a column path", err_path.msg)

      err_name = try; CTE("", "sku"); nothing; catch e; e end
      @test err_name isa PormG.QueryBuildError
      @test occursin("non-empty CTE name", err_name.msg)
    end

    @testset "an undeclared CTE name is refused, and the message lists what IS declared" begin
      err = try
        q = CR.Cj_child.objects
        q.with("ev" => _parent_cte(), join_field = "id" => "id")
        q.values("note", "x" => CTE("nope", "sku"))
        inspect_query(q; connection = _CR_SL)
        nothing
      catch e; e end
      @test err isa PormG.UnknownFieldError
      @test occursin("not declared on this query", err.msg)
      @test occursin("ev", err.msg)          # the declared one is named, so the typo is visible
    end

    @testset "operator suffixes stay out of projections and ordering" begin
      err_v = try
        q = CR.Cj_child.objects
        q.with("ev" => _parent_cte()); q.values(CTE("ev", "sku__@lte"))
        nothing
      catch e; e end
      @test err_v isa PormG.QueryBuildError
      @test occursin("not allowed in a projection", err_v.msg)

      err_o = try
        q = CR.Cj_child.objects
        q.with("ev" => _parent_cte()); q.order_by(CTE("ev", "sku__@lte"))
        nothing
      catch e; e end
      @test err_o isa PormG.QueryBuildError
      @test occursin("not allowed in ordering", err_o.msg)
    end
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # Aggregates over a CTE column WORK. An earlier draft of #444 refused them on the grounds that the
  # shape "does not need to compose on day one" — #444 having measured `Sum("<cte>__col")` at ZERO
  # call sites. That was a measurement of CALL SITES, not of CAPABILITY: rendering the same shape
  # against `main` shows it always worked, GROUP BY and HAVING included. The refusal would have been
  # a regression wearing a deferral'''s clothes, and an incoherent one, since `Sum(Length(CTE(...)))`
  # renders regardless of what the outer method does. Pinned so it is not "deferred" again.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "aggregates accept a CTE column" begin
    for (fn, sql_name) in ((PormG.Functions.Sum, "SUM"), (PormG.Functions.Count, "COUNT"),
                           (PormG.Functions.Max, "MAX"), (PormG.Functions.Min, "MIN"),
                           (PormG.Functions.Avg, "AVG"))
      q = CR.Cj_child.objects
      q.with("ev" => _parent_cte(), join_field = "id" => "id")
      q.values("note", "agg" => fn(CTE("ev", "sku")))
      sql = _sql(q)
      @test occursin(sql_name * "(", sql)
      @test occursin("JOIN \"ev\" AS", sql)      # the CTE is joined, not left dangling
      @test occursin("GROUP BY", sql)             # and the aggregate groups, as it does for a field
    end

    # Wrapped form, which renders whatever the outer aggregate method does — the incoherence that
    # made refusing the direct form indefensible.
    q = CR.Cj_child.objects
    q.with("ev" => _parent_cte(), join_field = "id" => "id")
    q.values("note", "x" => PormG.Functions.Sum(PormG.Functions.Length(CTE("ev", "sku"))))
    @test occursin("SUM(LENGTH(", _sql(q))
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # Migration diagnostic. The `"<cte>__col"` spelling is DELETED, not aliased — it now resolves as
  # an ordinary field path and fails. The generic "column not found" would send the reader looking
  # for a missing model field rather than at the spelling that changed, so the CTE case gets its own
  # message. It still THROWS: nothing here re-opens the ambiguous resolution.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "the old \"cte__col\" string spelling throws a migration diagnostic" begin
    err = try
      q = CR.Cj_child.objects
      q.with("ev" => _parent_cte(), join_field = "id" => "id")
      q.values("note", "s" => "ev__sku")
      inspect_query(q; connection = _CR_SL)
      nothing
    catch e; e end
    @test err isa PormG.UnknownFieldError
    @test occursin("CTE(\"ev\", \"sku\")", err.msg)
    @test occursin("#444", err.msg)
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # A CTE name that shadows a model field no longer changes ANY string path's meaning. With
  # `.with("parent" => …)` declared, `"parent__sku"` and a plain `.filter("parent" => 1)` behave
  # exactly as they do with no CTE at all — this is #431 stated as an invariant rather than a case.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "#431: declaring a shadowing CTE does not alter any field path" begin
    without = begin
      q = CR.Cj_child.objects
      q.values("note", "parent__sku")
      q.filter("parent__sku" => "V")
      inspect_query(q; connection = _CR_PG)
    end
    with = begin
      q = CR.Cj_child.objects
      q.with("parent" => _parent_cte(), join_field = "id" => "id")
      q.values("note", "parent__sku")
      q.filter("parent__sku" => "V")
      inspect_query(q; connection = _CR_PG)
    end
    # The CTE adds its WITH clause and its join, and changes nothing about how `parent__sku` renders.
    @test without[:parameters] == with[:parameters]
    @test occursin("\"product_sku\"", without[:sql_text])
    @test occursin("\"product_sku\"", with[:sql_text])
    @test !occursin("WITH ", without[:sql_text])
    @test occursin("WITH ", with[:sql_text])
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # deepcopy independence (#43): a query carrying CTE handles must be copyable without the copy and
  # the original sharing mutable reference objects — the retag mutates SQLField.field in place.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "#43: a query holding CTE handles deep-copies independently" begin
    q = CR.Cj_child.objects
    q.with("ev" => _parent_cte(), join_field = "id" => "id")
    q.values("note", "s" => CTE("ev", "sku"))
    q.filter(CTE("ev", "sku") => "X")

    # Rendering twice must give the same SQL — the first render must not consume the handles.
    first_render = _sql(q)
    @test _sql(q) == first_render

    copy_q = deepcopy(q)
    @test _sql(copy_q) == first_render
    @test _sql(q) == first_render
  end
end
