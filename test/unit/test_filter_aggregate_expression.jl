using Test
using Dates
using PormG
using PormG.Models: Model, IDField, IntegerField, FloatField, CharField, DateTimeField
using PormG.QueryBuilder: inspect_query, F, Q, Qor, Count, Max, Min, Sum
using PormG.Functions: Lower, Upper, Rank, WindowOver, Case, When
using PormG: QueryBuildError

include("helper_marker_alignment.jl")

# ─────────────────────────────────────────────────────────────────────────────
# #895 fixtures: one standalone lap-times model per mock backend. The defect rendered the same
# `WHERE` aggregate on both, and the new function comparisons bind a value, which only a positional
# backend (SQLite) can misplace silently — so every testset runs on both.
# ─────────────────────────────────────────────────────────────────────────────
struct FAggMockPostgres <: PormG.PormGPostgres end
struct FAggMockSQLite <: PormG.PormGSQLite end
# The window case asks the backend for its version; answer like the other mocks.
PormG.backend_sqlite_version(::FAggMockSQLite) = 3045000

PormG.config["f_agg_pg"] = PormG.Configuration.Settings(connections = FAggMockPostgres(), change_data = true)
PormG.config["f_agg_sl"] = PormG.Configuration.Settings(connections = FAggMockSQLite(), change_data = true)

for (key, name) in (("f_agg_pg", :FAggPgLap), ("f_agg_sl", :FAggSlLap))
  m = Model("f_agg_laps", id = IDField(), raceid = IntegerField(), lap = IntegerField(),
            milliseconds = IntegerField(), points = FloatField(), surname = CharField(),
            recorded_at = DateTimeField())
  m.connect_key = key
  @eval const $name = $m
end

const _F_AGG_MODELS = ((:postgres, FAggPgLap), (:sqlite, FAggSlLap))

# The exception a build raises, or `nothing` when it builds. Built through `inspect_query`, which is
# where the filter is rendered — the refusal must come from the build, never from the driver.
function _f_agg_build_error(Model_, setup)
  q = Model_.objects
  setup(q)
  try
    inspect_query(q)
    return nothing
  catch e
    return e
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# Filter expression containing an aggregate: refused at build time
# Every spelling below rendered `WHERE (… COUNT/MAX/MIN …)` with no GROUP BY, which both engines reject
# at execution — or, for a bare `Count("id") > 1`, raised a raw `MethodError: isless`. Each now raises
# `QueryBuildError` naming the alias spelling that renders HAVING, the advice #537 gives `OP(...)`.
# Wrapping in `Q`/`Qor`, an aggregate already in `values()`, and a per-row column beside the
# aggregate are all the same predicate, and all refused.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#895: a filter expression containing an aggregate is refused" begin
  cases = (
    ("arithmetic over an aggregate", q -> q.filter((Count("id") + 1) > 2)),
    ("difference of two aggregates", q -> q.filter((Max("recorded_at") - Min("recorded_at")) > Hour(1))),
    ("bare aggregate > number", q -> q.filter(Count("id") > 1)),
    ("bare aggregate > DateTime", q -> q.filter(Max("recorded_at") > DateTime(2009))),
    ("bare aggregate == number", q -> q.filter(Count("id") == 1)),
    ("bare aggregate != number", q -> q.filter(Sum("points") != 0)),
    ("inside Q", q -> q.filter(Q((Count("id") + 1) > 2))),
    ("inside a mixed Qor", q -> q.filter(Qor(Count("id") > 2, "surname" => "Senna"))),
    ("aggregate plus a row column", q -> q.filter((Count("id") + F("lap")) > 2)),
    ("aggregate already projected", q -> (q.values("raceid", "n" => Count("id")); q.filter(Count("id") > 2))),
  )
  for (backend, Model_) in _F_AGG_MODELS
    @testset "$backend: $label" for (label, setup) in cases
      err = _f_agg_build_error(Model_, q -> (q.values("raceid"); setup(q)))
      @test err isa QueryBuildError
      msg = sprint(showerror, err)
      # The refusal, and the spelling it points at: an alias filter, which renders HAVING.
      @test occursin("an expression containing an aggregate cannot be a WHERE predicate", msg)
      @test occursin("filter(\"span__@gt\" => 1000)", msg)
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# Aggregate on the right-hand side of a WHERE-bound pair: refused
# The pair spelling of the same defect: `filter("lap" => Max("lap"))` rendered
# `WHERE "Tb"."lap" = MAX("Tb"."lap")`. Refused wherever the pair lands in WHERE — a model column at
# top level, a leaf inside a split `Q`, and a ROW alias (one value per row, so its
# predicate is a WHERE one).
# ─────────────────────────────────────────────────────────────────────────────
@testset "#895: an aggregate on the right of a WHERE-bound pair is refused" begin
  cases = (
    ("model column", q -> (q.values("raceid"); q.filter("lap" => Max("lap")))),
    ("lookup suffix", q -> (q.values("raceid"); q.filter("lap__@gt" => Min("lap") + 1))),
    ("leaf of a Q", q -> (q.values("raceid"); q.filter(Q("lap__@gt" => Max("lap"), "surname" => "Senna")))),
    ("row alias", q -> (q.values("raceid", "next_lap" => F("lap") + 1); q.filter("next_lap__@gt" => Max("lap")))),
  )
  for (backend, Model_) in _F_AGG_MODELS
    @testset "$backend: $label" for (label, setup) in cases
      err = _f_agg_build_error(Model_, setup)
      @test err isa QueryBuildError
      msg = sprint(showerror, err)
      @test occursin("the right-hand side contains an aggregate, which cannot be a WHERE predicate", msg)
      @test occursin("filter(\"worst__@gt\" => Min(\"milliseconds\") * 2)", msg)
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# Window function in a filter expression: refused with the CTE advice
# The window twin of the aggregate case, on both sides of the comparison. `Rank() + 1 > 2` rendered
# `WHERE ((RANK() OVER (…) + ?) > ?)`. SQL evaluates windows after WHERE and HAVING, so no clause at
# this level can hold it; the message names the CTE route, as #537 and #685 do.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#895: a window function in a filter expression is refused" begin
  rank = () -> Rank(over = WindowOver(order_by = ["milliseconds"]))
  cases = (
    ("left of an expression", q -> q.filter((rank() + 1) > 2), "an expression containing a window function"),
    ("right of a pair", q -> q.filter("lap" => rank()), "the right-hand side contains a window function"),
  )
  for (backend, Model_) in _F_AGG_MODELS
    @testset "$backend: $label" for (label, setup, needle) in cases
      err = _f_agg_build_error(Model_, q -> (q.values("raceid", "lap"); setup(q)))
      @test err isa QueryBuildError
      msg = sprint(showerror, err)
      @test occursin(needle, msg)
      # The window advice, not the aggregate one: compute it in a CTE.
      @test occursin("Compute it in a CTE and filter on its column", msg)
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# An aggregate or window reached through an alias: refused too
# A `Case` whose condition names an alias holds only the name, so its own flag says "row expression"
# — yet `When("t__@gt" => 1)` over `"t" => Sum("lap")` renders `CASE WHEN SUM(…)`. The refusals ask
# the question after aliases resolve (#722/#789's `_resolved_*`), on both sides of the comparison and
# for both kinds. Without that, all four rendered an aggregate or a window into WHERE.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#895: an aggregate or window read through an alias is refused" begin
  agg_case = () -> Case([When("t__@gt" => 1, then = 1)], default = 0)
  win_case = () -> Case([When("r" => 1, then = 1)], default = 0)
  agg_values = q -> q.values("raceid", "t" => Sum("lap"))
  win_values = q -> q.values("raceid", "lap", "r" => Rank(over = WindowOver(order_by = ["milliseconds"])))
  cases = (
    ("aggregate, left", q -> (agg_values(q); q.filter(agg_case() == 1)),
     "an expression containing an aggregate cannot be a WHERE predicate"),
    ("aggregate, right", q -> (agg_values(q); q.filter("lap" => agg_case())),
     "the right-hand side contains an aggregate"),
    ("window, left", q -> (win_values(q); q.filter(win_case() == 1)),
     "an expression containing a window function"),
    ("window, right", q -> (win_values(q); q.filter("lap" => win_case())),
     "the right-hand side contains a window function"),
  )
  for (backend, Model_) in _F_AGG_MODELS
    @testset "$backend: $label" for (label, setup, needle) in cases
      err = _f_agg_build_error(Model_, setup)
      @test err isa QueryBuildError
      @test occursin(needle, sprint(showerror, err))
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# Aggregate predicates that belong in HAVING still render there
# The refusal must not reach the spellings that were already right. An aggregate alias renders in
# HAVING — compared with a value, and compared with another aggregate expression, top-level or inside
# a `Q` (the advice the right-hand-side refusal gives). A row expression stays in WHERE.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#895: aggregate aliases still filter in HAVING" begin
  for (backend, Model_) in _F_AGG_MODELS
    @testset "$backend" begin
      # The alias spelling the expression refusal recommends.
      q = Model_.objects
      q.values("raceid", "span" => Max("milliseconds") - Min("milliseconds"))
      q.filter("span__@gt" => 1000)
      insp = inspect_query(q)
      @test !occursin("WHERE", insp[:sql_text])
      @test occursin(r"HAVING \(MAX\(\"Tb\"\.\"milliseconds\"\) - MIN\(\"Tb\"\.\"milliseconds\"\)\) > ", insp[:sql_text])
      assert_marker_count(insp, backend)
      backend === :sqlite && assert_bound_in_text_order(insp, Any[1000])

      # The spelling the right-hand-side refusal recommends, top-level and inside a Q.
      for wrap in (identity, Q)
        q = Model_.objects
        q.values("raceid", "worst" => Max("milliseconds"))
        q.filter(wrap("worst__@gt" => Min("milliseconds") * 2))
        insp = inspect_query(q)
        @test !occursin("WHERE", insp[:sql_text])
        @test occursin(r"HAVING \(?MAX\(\"Tb\"\.\"milliseconds\"\) > \(MIN\(\"Tb\"\.\"milliseconds\"\) \* ", insp[:sql_text])
        assert_marker_count(insp, backend)
        backend === :sqlite && assert_bound_in_text_order(insp, Any[2])
      end

      # A row expression is not an aggregate, and still filters rows.
      q = Model_.objects
      q.values("raceid")
      q.filter((F("lap") + 1) > 2)
      insp = inspect_query(q)
      @test occursin(r"WHERE \(\(\"Tb\"\.\"lap\" \+ \S+\) > \S+\)", insp[:sql_text])
      @test !occursin("HAVING", insp[:sql_text])
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# Function on the left of a comparison: a WHERE predicate
# `Lower("surname") == "senna"` fell through to `Base.==` and reached `filter` as a bare `false`
# ("Invalid filter argument: false"). All six operators now build the `F` node arithmetic on a
# function already built, so a row function filters in WHERE with its value bound — in text order
# beside a neighbouring pair. A reused handle builds independent predicates.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#895: a function on the left of a comparison filters in WHERE" begin
  ops = ((==, "="), (!=, "!="), (>, ">"), (<, "<"), (>=, ">="), (<=, "<="))
  for (backend, Model_) in _F_AGG_MODELS
    @testset "$backend: $sym" for (op, sym) in ops
      q = Model_.objects
      q.values("raceid")
      q.filter(op(Lower("surname"), "senna"), "lap" => 3)
      insp = inspect_query(q)
      # PostgreSQL types a text literal compared with an expression (`$1::text`), as `F` does.
      marker = backend === :sqlite ? "\\?" : "\\\$1::text"
      @test occursin(Regex("WHERE \\(LOWER\\(\"Tb\"\\.\"surname\"\\) $(sym) $(marker)\\)"), insp[:sql_text])
      assert_marker_count(insp, backend)
      backend === :sqlite && assert_bound_in_text_order(insp, Any["senna", 3])
    end
    @testset "$backend: reused handle, column operand, SubString" begin
      f = Lower("surname")
      q = Model_.objects
      q.values("raceid")
      q.filter(f >= "a", f <= SubString("mz", 1), f != F("surname"))
      insp = inspect_query(q)
      sql = insp[:sql_text]
      @test occursin(r"\(LOWER\(\"Tb\"\.\"surname\"\) >= \S+\)", sql)
      @test occursin(r"\(LOWER\(\"Tb\"\.\"surname\"\) <= \S+\)", sql)
      @test occursin("(LOWER(\"Tb\".\"surname\") != \"Tb\".\"surname\")", sql)
      assert_marker_count(insp, backend)
      backend === :sqlite && assert_bound_in_text_order(insp, Any["a", "mz"])
    end
  end

  # A value outside the `F` operand vocabulary is refused as it is for `F`, not answered by Base —
  # and so is a function on the RIGHT, which that vocabulary does not hold either.
  for bad in (:senna, Upper("surname"), nothing)
    err = try; Lower("surname") == bad; nothing; catch e; e; end
    @test err isa QueryBuildError
    @test occursin("is not a supported right-hand side for an F/Joined/function comparison",
                   sprint(showerror, err))
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# `isequal` on a function stays total
# `==` on a function now builds a predicate, and Base's `isequal` falls back to `==` — so without the
# guard `Dict`/`Set`/`unique` would be handed a node where they need a `Bool`. Identity between two
# nodes, `false` against anything else, as for `F` (#536).
# ─────────────────────────────────────────────────────────────────────────────
@testset "#895: isequal on a function is identity" begin
  c = Count("id")
  @test isequal(c, c)
  @test !isequal(c, Count("id"))
  @test !isequal(c, 1)
  @test !isequal(c, missing)
  @test length(Set([c, c, Count("id")])) == 2
  d = Dict(c => "count")
  @test d[c] == "count"
end

# ─────────────────────────────────────────────────────────────────────────────
# Window function on the left of a comparison (#919)
# `Rank(…) > 1` raised a raw `MethodError: isless(::Int64, ::WindowFunction)`: #895 gave `FObject`
# the six comparisons and `WindowFunction` is a separate type. It now builds the node
# `(Rank(…) + 0) > 1` already built, so `filter` refuses it with the CTE advice and a SELECT-side
# `Case` renders `CASE WHEN (RANK() OVER (…) > ?)` with the operand bound in text order.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#919: a window function on the left of a comparison" begin
  rank = () -> Rank(over = WindowOver(order_by = ["milliseconds"]))
  ops = ((==, "="), (!=, "!="), (>, ">"), (<, "<"), (>=, ">="), (<=, "<="))
  for (backend, Model_) in _F_AGG_MODELS
    @testset "$backend: filter($sym) is refused with the CTE advice" for (op, sym) in ops
      err = _f_agg_build_error(Model_, q -> (q.values("raceid", "lap"); q.filter(op(rank(), 1))))
      @test err isa QueryBuildError
      msg = sprint(showerror, err)
      @test occursin("an expression containing a window function", msg)
      @test occursin("Compute it in a CTE and filter on its column", msg)
    end
    @testset "$backend: Case(When(Q(...))) renders $sym" for (op, sym) in ops
      q = Model_.objects
      q.values("lap", "c" => Case([When(Q(op(rank(), 1)), then = 1)], default = 0))
      insp = inspect_query(q)
      # The comparison wraps the whole window call, operand bound rather than inlined.
      @test occursin(Regex("WHEN \\(\\(RANK\\(\\) OVER \\(ORDER BY \"Tb\"\\.\"milliseconds\" ASC\\) " *
                           "$(sym) \\S+\\)\\) THEN"), insp[:sql_text])
      assert_marker_count(insp, backend)
      backend === :sqlite && assert_bound_in_text_order(insp, Any[1, 1, 0])
    end
  end

  # The operand vocabulary is the `F` one: a function on the right is refused, not answered by Base.
  err = try; rank() > Upper("surname"); nothing; catch e; e; end
  @test err isa QueryBuildError
  @test occursin("is not a supported right-hand side for an F/Joined/function comparison",
                 sprint(showerror, err))

  # `isequal` stays total, as for `FObject`: identity between two nodes, `false` against anything else.
  r = rank()
  @test isequal(r, r)
  @test !isequal(r, rank())
  @test !isequal(r, 1)
  @test !isequal(r, missing)
  @test length(Set([r, r, rank()])) == 2
end

# ─────────────────────────────────────────────────────────────────────────────
# `When` takes an `F`/function/window comparison directly (#921)
# `When(F("lap") > 1, then = 1)` raised a raw `MethodError` unless wrapped in `Q(...)`, though the
# docstring promised it. The bare spelling must render the SAME SQL text and bind the SAME parameters
# as the `Q`-wrapped one on both backends — that equality is the contract, so it is what is asserted,
# beside one anchor on the shape so an equal-but-wrong pair cannot pass.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#921: When(expr) renders as When(Q(expr))" begin
  rank = () -> Rank(over = WindowOver(order_by = ["milliseconds"]))
  conditions = (
    ("F vs literal", () -> F("lap") > 1),
    ("F vs F column", () -> F("lap") < F("milliseconds")),
    ("F arithmetic", () -> (F("lap") + 1) >= 3),
    ("function vs literal", () -> Lower("surname") == "senna"),
    ("transform inside F", () -> F("recorded_at__@year") > 2020),
    ("window vs literal", () -> rank() <= 3),
  )
  # Build the same projection twice, once per spelling, and read back what `inspect_query` renders.
  render = (Model_, when) -> begin
    q = Model_.objects
    q.values("raceid", "c" => Case([when], default = 0))
    insp = inspect_query(q)
    (insp[:sql_text], insp[:parameters])
  end
  for (backend, Model_) in _F_AGG_MODELS
    @testset "$backend: $label" for (label, cond) in conditions
      bare = render(Model_, When(cond(), then = 1))
      wrapped = render(Model_, When(Q(cond()), then = 1))
      @test bare == wrapped
      # Anchor: a WHEN branch with the THEN bound, so equality is not two identical failures.
      @test occursin(r"CASE\s+WHEN \(\(.+\)\) THEN \S+\s+ELSE \S+\s+END", bare[1])
    end
    @testset "$backend: standalone otherwise=" begin
      q1 = Model_.objects
      q1.values("raceid", "c" => When(F("lap") > 1, then = 1, otherwise = 0))
      q2 = Model_.objects
      q2.values("raceid", "c" => When(Q(F("lap") > 1), then = 1, otherwise = 0))
      i1, i2 = inspect_query(q1), inspect_query(q2)
      @test i1[:sql_text] == i2[:sql_text]
      @test i1[:parameters] == i2[:parameters]
      @test occursin(r"WHEN \(\(\"Tb\"\.\"lap\" > \S+\)\) THEN", i1[:sql_text])
      backend === :sqlite && assert_bound_in_text_order(i1, Any[1, 1, 0])
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# A window in a `When` CONDITION is a window too (#928)
# The #895 guard saw a window in a `Case` branch (#756) but not in a condition: the condition sits in
# the `FObject`'s column as a `Q`/`Qor` tree or one comparison, which `_is_window_expr` never entered.
# So `filter("lap__@gt" => Case([When(Rank(…) > 1, then = 1)]))` rendered `WHERE "lap" > CASE WHEN
# ((RANK() OVER (…) > ?)) …`, which both engines reject at execution. Every spelling of the condition
# is asked, on both sides of a WHERE-bound comparison; the SELECT-side `Case` keeps rendering.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#928: a window in a When condition is refused in WHERE" begin
  rank = () -> Rank(over = WindowOver(order_by = ["milliseconds"]))
  case_of = cond -> Case([When(cond, then = 1)], default = 0)
  rhs = "the right-hand side contains a window function"
  expr = "an expression containing a window function"
  cases = (
    ("bare comparison condition", q -> q.filter("lap__@gt" => case_of(rank() > 1)), rhs),
    ("Q-wrapped condition", q -> q.filter("lap__@gt" => case_of(Q(rank() > 1))), rhs),
    ("Qor condition", q -> q.filter("lap" => case_of(Qor(rank() > 1, "surname" => "Senna"))), rhs),
    ("window arithmetic in the condition", q -> q.filter("lap" => case_of((rank() + 1) > 2)), rhs),
    ("pair condition whose value is a window", q -> q.filter("lap" => case_of("lap__@gt" => rank())), rhs),
    ("inside a Q filter", q -> q.filter(Q("lap__@gt" => case_of(rank() > 1))), rhs),
    ("Case on the left of an F comparison", q -> q.filter(case_of(rank() > 1) == 1), expr),
  )
  for (backend, Model_) in _F_AGG_MODELS
    @testset "$backend: $label" for (label, setup, needle) in cases
      err = _f_agg_build_error(Model_, q -> (q.values("raceid", "lap"); setup(q)))
      @test err isa QueryBuildError
      msg = sprint(showerror, err)
      @test occursin(needle, msg)
      @test occursin("Compute it in a CTE and filter on its column", msg)
    end
    # The same `Case` as a projection is legal SQL, and is not grouped: a window never is.
    @testset "$backend: the projected Case still renders, ungrouped" begin
      q = Model_.objects
      q.values("raceid", "n" => Count("id"), "c" => case_of(rank() > 1))
      insp = inspect_query(q)
      @test occursin(r"CASE\s+WHEN \(\(RANK\(\) OVER", insp[:sql_text])
      # `raceid` by position and the window's ORDER BY column — never the `Case` itself (position 3).
      @test occursin(r"GROUP BY 1, \"Tb\"\.\"milliseconds\"\s*$", insp[:sql_text])
    end
    # A plain condition beside it keeps filtering in WHERE — the walk did not start refusing rows.
    @testset "$backend: a window-free condition still filters" begin
      err = _f_agg_build_error(Model_, q -> q.filter("lap__@gt" => case_of(F("milliseconds") > 1)))
      @test err === nothing
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# A non-boolean expression used as a CONDITION is refused (#931)
# `When(F("lap") + 1, then = 1)` rendered `CASE WHEN (("Tb"."lap" + ?)) THEN …`: PostgreSQL rejects it,
# SQLite reads the number for truthiness and returns rows, so one query answered differently per engine.
# Every condition position is asked — `When`, `Q`, `Qor`, `push!` onto either, `filter` — for each
# non-comparison operation kind, and the refusal comes at construction, before any backend is involved.
# A bare boolean column and a comparison over the same arithmetic keep building.
# ─────────────────────────────────────────────────────────────────────────────
using PormG.Models: BooleanField

for (key, name) in (("f_agg_pg", :FAggPgFlag), ("f_agg_sl", :FAggSlFlag))
  m = Model("f_agg_flags", id = IDField(), lap = IntegerField(), points = IntegerField(),
            finished = BooleanField())
  m.connect_key = key
  @eval const $name = $m
end

# The exception the construction or the build raises, or `nothing` when both succeed. Unlike
# `_f_agg_build_error`, the setup is inside the `try`: this guard fires while the node is built.
function _f_cond_error(Model_, setup)
  try
    q = Model_.objects
    setup(q)
    inspect_query(q)
    return nothing
  catch e
    return e
  end
end

@testset "#931: a non-boolean expression as a condition is refused" begin
  # (label, condition expression, the hint the message must carry)
  exprs = (
    ("addition", () -> F("lap") + 1, "(F(\"lap\") + 1) > 0"),
    ("multiplication", () -> F("lap") * 2, "(F(\"lap\") + 1) > 0"),
    ("nested arithmetic", () -> (F("lap") + 1) * F("points"), "(F(\"lap\") + 1) > 0"),
    ("bitwise AND", () -> F("points") & 4, "(F(\"points\") & 4) > 0"),
    ("bitwise OR of two comparisons", () -> (F("lap") > 1) | (F("points") > 2), "Qor(…)"),
    ("bitwise NOT", () -> ~F("finished"), "F(\"flag\") == false"),
    ("shift", () -> F("points") << 1, "(F(\"points\") & 4) > 0"),
  )
  positions = (
    ("When(expr)", (q, e) -> q.values("c" => Case([When(e, then = 1)], default = 0))),
    ("When(Q(expr))", (q, e) -> q.values("c" => Case([When(Q(e), then = 1)], default = 0))),
    ("When(expr; otherwise)", (q, e) -> q.values("c" => When(e, then = 1, otherwise = 0))),
    ("filter(expr)", (q, e) -> q.filter(e)),
    ("filter(Q(expr))", (q, e) -> q.filter(Q(e))),
    ("filter(Qor(expr, pair))", (q, e) -> q.filter(Qor(e, "lap" => 3))),
    ("push! onto a Q", (q, e) -> q.filter(push!(Q("lap" => 3), e))),
    ("push! onto a Qor", (q, e) -> q.filter(push!(Qor("lap" => 3), e))),
  )
  for (backend, Model_) in ((:postgres, FAggPgFlag), (:sqlite, FAggSlFlag))
    @testset "$backend: $plabel / $elabel" for (plabel, place) in positions, (elabel, expr, hint) in exprs
      err = _f_cond_error(Model_, q -> place(q, expr()))
      @test err isa QueryBuildError
      msg = sprint(showerror, err)
      @test occursin("used as a condition", msg)
      @test occursin(hint, msg)
      @test occursin("#931", msg)
    end
    # The legal neighbours: a bare boolean column, a comparison over the refused arithmetic, and the
    # arithmetic where it IS a value — a projection, a `then`, a right-hand side.
    @testset "$backend: boolean conditions and arithmetic values still build" begin
      @test _f_cond_error(Model_, q -> q.filter(F("finished"))) === nothing
      @test _f_cond_error(Model_, q -> q.values("c" => Case([When(F("finished"), then = 1)], default = 0))) === nothing
      @test _f_cond_error(Model_, q -> q.filter((F("lap") + 1) > 0)) === nothing
      @test _f_cond_error(Model_, q -> q.filter(Q((F("points") & 4) > 0))) === nothing
      @test _f_cond_error(Model_, q -> q.values("c" => Case([When((F("lap") + 1) > 0, then = F("lap") * 2)], default = 0))) === nothing
      @test _f_cond_error(Model_, q -> q.values("d" => F("lap") + 1)) === nothing
      @test _f_cond_error(Model_, q -> q.filter("points__@gt" => F("lap") + 1)) === nothing
      q = Model_.objects
      q.filter(F("finished"))
      @test occursin(r"WHERE \(?\"Tb\"\.\"finished\"\)?", inspect_query(q)[:sql_text])
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# A non-boolean FUNCTION used as a `When` condition is refused (#942)
# `When(Lower("surname"), then = 1)` rendered `CASE WHEN LOWER("Tb"."surname") THEN …`: PostgreSQL
# rejects it, SQLite coerces the text to a number and reads it for truthiness, so every row silently
# took the default. A function's node type cannot decide it the way #931 decides arithmetic — a
# `Cast(…, "boolean")` is a legitimate condition — so the RESULT type does: fixed by the name or a
# declared type at construction, read from the operands at render. Each refused function is asked in
# every `When` spelling; a function whose type cannot be named keeps building, unchecked, by design.
# ─────────────────────────────────────────────────────────────────────────────
using PormG.Functions: Length, Cast, Coalesce, Lag, Concat, NullIf, Greatest
using PormG.QueryBuilder: MONTH, OP
using PormG.QueryBuilder: Avg
using PormG.Models: DateField

for (key, name) in (("f_agg_pg", :FAggPgFn), ("f_agg_sl", :FAggSlFn))
  m = Model("f_agg_fn", id = IDField(), lap = IntegerField(), points = IntegerField(),
            surname = CharField(), recorded = DateField(), finished = BooleanField())
  m.connect_key = key
  @eval const $name = $m
end

@testset "#942: a non-boolean function as a When condition is refused" begin
  order = WindowOver(order_by = ["lap"])
  # (label, the condition, :construct when the node alone decides / :render when the operands do,
  #  whether it may sit in a WHERE at all — an aggregate or window there is #895's refusal, not this one)
  refused = (
    ("Lower (text by name)", () -> Lower("surname"), :construct, true),
    ("Concat (text by name)", () -> Concat(["surname", "surname"]), :construct, true),
    ("Length (number formatter)", () -> Length("surname"), :construct, true),
    ("MONTH (number formatter)", () -> MONTH("recorded"), :construct, true),
    ("Sum (number by name)", () -> Sum("points"), :construct, true),
    ("Avg (number by name)", () -> Avg("points"), :construct, true),
    ("Count (PormGTypeField)", () -> Count("id"), :construct, true),
    ("Rank (window, number by name)", () -> Rank(over = order), :construct, true),
    ("Cast to integer (declared)", () -> Cast("finished", "integer"), :construct, true),
    # A declared type PormG has no field for is still a declared type, and not boolean (review of #942).
    ("Cast to timestamp (declared, no field)", () -> Cast("recorded", "timestamp"), :construct, true),
    ("Case with an integer output_field", () -> Case([When("lap" => 1, then = 1)], default = 0, output_field = "integer"), :construct, true),
    ("Coalesce over an integer column", () -> Coalesce("lap", 0), :render, true),
    ("NullIf over a text column", () -> NullIf("surname", Lower("surname")), :render, true),
    ("Max over an integer column", () -> Max("points"), :render, false),
  )
  positions = (
    ("Case([When(fn)])", (q, c) -> q.values("c" => Case([When(c, then = 1)], default = 0))),
    ("When(fn; otherwise)", (q, c) -> q.values("c" => When(c, then = 1, otherwise = 0))),
    ("a Case on a filter's right-hand side", (q, c) -> q.filter("lap" => Case([When(c, then = 1)], default = 0))),
  )
  # Every refused function in every spelling, except an aggregate in the WHERE spelling.
  cases = [(plabel, place, label, cond, phase) for (plabel, place) in positions
           for (label, cond, phase, in_where) in refused if in_where || !occursin("filter", plabel)]
  for (backend, Model_) in ((:postgres, FAggPgFn), (:sqlite, FAggSlFn))
    @testset "$backend: $plabel / $label" for (plabel, place, label, cond, phase) in cases
      # The construction-time half raises from `When` itself, before any query exists; the render half
      # only once `inspect_query` resolves the operand's column.
      if phase === :construct
        @test_throws QueryBuildError When(cond(), then = 1)
      else
        @test When(cond(), then = 1) isa PormG.QueryBuilder.SQLTypeFunction
      end
      err = _f_cond_error(Model_, q -> place(q, cond()))
      @test err isa QueryBuildError
      msg = sprint(showerror, err)
      @test occursin("used as a condition", msg)
      @test occursin("When(Lower(\"surname\") == \"senna\")", msg)
      @test occursin("#942", msg)
    end

    # A boolean-valued function, a comparison over the refused one, and a function whose type cannot
    # be named all build — the exact SQL is the proof the condition reaches the CASE untouched.
    @testset "$backend: boolean and untyped function conditions still build" begin
      pg = backend === :postgres
      # PostgreSQL types each bound value (`$1::bigint`); SQLite binds a bare `?`.
      ph(n, t) = pg ? "\$$(n)::$(t)" : "?"
      built = (
        # Boolean by its declared type: PostgreSQL renders the `::boolean` shorthand.
        (() -> Cast("lap", "boolean"),
          pg ? "WHEN (\"Tb\".\"lap\")::boolean THEN \$1::bigint" : "WHEN CAST(\"Tb\".\"lap\" AS BOOLEAN) THEN ?"),
        # Boolean through its operand: the first operand is the BooleanField.
        (() -> Coalesce(F("finished"), false),
          "WHEN COALESCE(\"Tb\".\"finished\", $(ph(1, "boolean"))) THEN $(ph(2, "bigint"))"),
        # Boolean by `output_field`: the inner CASE is cast to it.
        (() -> Case([When("lap" => 1, then = true)], default = false, output_field = "boolean"),
          pg ? "WHEN (CASE\nWHEN \"Tb\".\"lap\" = \$1 THEN \$2::boolean\nELSE \$3::boolean\nEND)::boolean\n THEN \$4::bigint" :
               "WHEN CAST(CASE\nWHEN \"Tb\".\"lap\" = ? THEN ?\nELSE ?\nEND\n AS BOOLEAN) THEN ?"),
        # Untyped: `LAG` names no type, so it is not checked — it builds as written.
        (() -> Lag("finished", over = order),
          "WHEN LAG(\"Tb\".\"finished\", $(ph(1, "integer"))) OVER (ORDER BY \"Tb\".\"lap\" ASC) THEN $(ph(2, "bigint"))"),
        # A comparison over the refused function is an `F` comparison node (#895), not a function.
        (() -> Lower("surname") == "senna",
          "WHEN ((LOWER(\"Tb\".\"surname\") = $(ph(1, "text")))) THEN $(ph(2, "bigint"))"),
      )
      for (cond, needle) in built
        q = Model_.objects
        q.values("c" => Case([When(cond(), then = 1)], default = 0))
        @test occursin(needle, inspect_query(q)[:sql_text])
      end
      # A comparison is boolean whatever it compares, so a function over comparisons is boolean too.
      # These typed as numbers before the review of #942 (`F("lap") > 0` took the arithmetic rule).
      for cond in (() -> Coalesce(F("lap") > 0, false), () -> Greatest(F("lap") > 0, F("points") > 0),
                   () -> NullIf(F("lap") > 0, false), () -> Coalesce(F("lap") == F("points"), false))
        @test _f_cond_error(Model_, q -> q.values("c" => Case([When(cond(), then = 1)], default = 0))) === nothing
      end
      # The same typing reaches an alias filter: a projected comparison is no longer read as a number,
      # so `true` binds as itself. As a number it bound `1`, which PostgreSQL cannot compare with a
      # boolean.
      q = Model_.objects
      q.values("ahead" => F("lap") > F("points"))
      q.filter("ahead" => true)
      insp = inspect_query(q)
      @test occursin(pg ? r"WHERE \(+\"Tb\"\.\"lap\" > \"Tb\"\.\"points\"\)+ = \$1" : r"WHERE \(+\"Tb\"\.\"lap\" > \"Tb\"\.\"points\"\)+ = \?",
                     insp[:sql_text])
      @test insp[:parameters] == Any[true]
      # #949: the comparison is typed as a boolean now that `format_bool_sql` refuses an integer other
      # than 0/1. Until then it was left untyped and `5` bound as written. #942 pinned that here on
      # purpose, so this assertion is the deliberate reversal, not a goalpost moved: a boolean alias
      # compared with 5 is a mistake to report.
      q = Model_.objects
      q.values("ahead" => F("lap") > F("points"))
      q.filter("ahead" => 5)
      @test_throws PormG.FilterError inspect_query(q)
      q = Model_.objects
      q.values("ahead" => F("lap") > F("points"))
      q.filter("ahead" => 1)
      @test inspect_query(q)[:parameters] == Any[pg ? true : 1]
      # `OP` is a comparison node, not a function: the internal `Y_Q` path builds `When(OP(MONTH(…), …))`.
      q = Model_.objects
      q.values("c" => Case([When(OP(MONTH("recorded"), "<=", 4), then = 1)], default = 0))
      @test occursin(pg ? "WHEN EXTRACT(MONTH FROM \"Tb\".\"recorded\")::integer <= \$1 THEN" :
                          "WHEN CAST(strftime('%m', \"Tb\".\"recorded\") AS INTEGER) <= ? THEN", inspect_query(q)[:sql_text])
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# #953: an aggregate over a BooleanField
#
# `MAX`/`MIN`/`SUM`/`AVG` rendered as written whatever the column type. PostgreSQL has none of them
# for a boolean, so the statement failed there when it ran ("function max(boolean) does not exist"),
# while SQLite answered over its stored 0/1 — and `When(Max("finished"))`, which #942 types as a
# boolean condition, was accepted and then failed on PostgreSQL. An extremum now renders
# `BOOL_OR`/`BOOL_AND` on PostgreSQL and stays `MAX`/`MIN` on SQLite, where 0/1 gives the same answer;
# a sum or mean is refused on both, because it turns a boolean into a number.
# ─────────────────────────────────────────────────────────────────────────────
using PormG.Models: ForeignKey

for (key, name, parent) in (("f_agg_pg", :FAggPgEntry, FAggPgFn), ("f_agg_sl", :FAggSlEntry, FAggSlFn))
  m = Model("f_agg_entry", id = IDField(), grid = IntegerField(),
            fnid = ForeignKey(parent, pk_field = "id", related_name = "f_agg_entries"))
  m.connect_key = key
  m._module = Main
  @eval const $name = $m
end

_f953_plain(s) = replace(s, r"\e\[[0-9;]*m" => "")

@testset "#953: an aggregate over a BooleanField" begin
  for (backend, Model_, Entry_) in ((:postgres, FAggPgFn, FAggPgEntry), (:sqlite, FAggSlFn, FAggSlEntry))
    pg = backend === :postgres
    sql(setup; model = Model_) = (q = model.objects; setup(q); inspect_query(q)[:sql_text])
    any_of(col) = pg ? "BOOL_OR($(col))" : "MAX($(col))"
    all_of(col) = pg ? "BOOL_AND($(col))" : "MIN($(col))"

    @testset "$backend: Max/Min render the engine's boolean extremum" begin
      s = sql(q -> q.values("lap", "any_fin" => Max("finished"), "all_fin" => Min("finished")))
      @test occursin(any_of("\"Tb\".\"finished\""), s)
      @test occursin(all_of("\"Tb\".\"finished\""), s)
      pg && @test !occursin("MAX(", s) && !occursin("MIN(", s)
      # The `F` handle and a comparison are booleans too; a comparison is what `Max(F(a) > F(b))` is.
      @test occursin(any_of("\"Tb\".\"finished\""), sql(q -> q.values("lap", "m" => Max(F("finished")))))
      @test occursin(pg ? "BOOL_OR(" : "MAX(", sql(q -> q.values("lap", "m" => Max(F("lap") > F("points")))))
      # Across a join: the field is resolved through the join memo, not the root model's fields.
      @test occursin(r"" * (pg ? "BOOL_OR" : "MAX") * r"\(\"Tb_\d+\"\.\"finished\"\)",
                     sql(q -> q.values("grid", "m" => Max("fnid__finished")); model = Entry_))
      # The projection is typed a boolean on both engines, so SQLite's 0/1 reads back as a `Bool`
      # (`value_parser(::CBool, ::PormGSQLite)`), as PostgreSQL's `BOOL_OR` does by the driver.
      q = Model_.objects
      q.values("lap", "a" => Max("finished"), "b" => Min(F("finished")), "p" => Max("points"))
      PormG.QueryBuilder.query(q; show_query = :sql)
      @test q.object.projection_kinds[:a] == PormG.CBool()
      @test q.object.projection_kinds[:b] == PormG.CBool()
      @test get(q.object.projection_kinds, :p, nothing) === nothing
      # Controls: an extremum over a non-boolean is untouched on both engines.
      s = sql(q -> q.values("lap", "m" => Max("points"), "n" => Min("points")))
      @test occursin("MAX(\"Tb\".\"points\")", s) && occursin("MIN(\"Tb\".\"points\")", s)
      @test !occursin("BOOL_", s)
    end

    @testset "$backend: the boolean extremum in HAVING and as a When condition" begin
      # The alias filter re-renders the aggregate in HAVING, through the same site, and binds a Bool.
      q = Model_.objects
      q.values("lap", "any_fin" => Max("finished"))
      q.filter("any_fin" => true)
      insp = inspect_query(q)
      @test occursin("HAVING " * any_of("\"Tb\".\"finished\""), insp[:sql_text])
      @test insp[:parameters] == Any[true]
      # #942 accepts it as a condition, and now it renders one PostgreSQL can run.
      s = sql(q -> q.values("lap", "c" => Case([When(Max("finished"), then = 1)], default = 0)))
      @test occursin("WHEN " * any_of("\"Tb\".\"finished\"") * " THEN", s)
    end

    @testset "$backend: Sum/Avg over a boolean are refused" begin
      # The hint names the caller's own column when the operand is one, a placeholder otherwise.
      for (label, agg, path) in (("Sum", () -> Sum("finished"), "finished"), ("Avg", () -> Avg("finished"), "finished"),
                                 ("Sum distinct", () -> Sum("finished", distinct = true), "finished"),
                                 ("Avg of F", () -> Avg(F("finished")), "finished"),
                                 ("Sum of a comparison", () -> Sum(F("lap") > F("points")), "is_active"))
        err = _f_agg_build_error(Model_, q -> q.values("lap", "s" => agg()))
        @test err isa QueryBuildError
        msg = _f953_plain(sprint(showerror, err))
        @test occursin("over a boolean is not supported", msg)
        @test occursin("When(\"$(path)\" => true, then = 1, otherwise = 0))", msg)
      end
      err = _f_agg_build_error(Entry_, q -> q.values("grid", "s" => Sum("fnid__finished")))
      @test err isa QueryBuildError
      @test occursin("When(\"fnid__finished\" => true", _f953_plain(sprint(showerror, err)))
      # The spellings the refusal points to build — a complete CASE, not a bare `WHEN … THEN`, which no
      # engine parses as an aggregate's operand — and so does an explicit cast.
      for (fn, name) in ((Sum, "SUM"), (Avg, "AVG"))
        s = sql(q -> q.values("lap", "n" => fn(When("finished" => true, then = 1, otherwise = 0))))
        @test occursin(Regex(name * raw"\(CASE WHEN .*\"Tb\"\.\"finished\" = " * (pg ? raw"\$1" : raw"\?") *
                             raw" THEN .* ELSE .* END\)"), replace(s, r"\s+" => " "))
      end
      @test occursin("SUM(", sql(q -> q.values("lap", "n" => Sum(Cast("finished", "integer")))))
      # Controls: a sum over a number still builds on both engines.
      @test occursin("SUM(\"Tb\".\"points\")", sql(q -> q.values("lap", "n" => Sum("points"))))
      @test occursin("AVG(\"Tb\".\"points\")", sql(q -> q.values("lap", "n" => Avg("points"))))
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# #964: a bare When outside a Case
#
# `When(cond; then = x)` with no `otherwise` is a Case branch: `WHEN … THEN …`, with no ELSE and no END.
# Used as a value, it rendered exactly that, so `Count(When("lap" => 1, then = 1))` became
# `COUNT(WHEN … THEN …)`, which no engine parses, and the failure came from the driver. The build
# refuses it now, in every value position. The branch spellings render the SQL they always did.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#964: a bare When outside a Case is refused at build" begin
  bare() = When("lap" => 1, then = 1)
  positions = (
    ("a projection", q -> q.values("lap", "c" => bare())),
    ("Count's operand", q -> q.values("lap", "c" => Count(bare()))),
    ("Sum's operand", q -> q.values("lap", "c" => Sum(bare()))),
    ("a function argument", q -> q.values("lap", "c" => Coalesce(bare(), 0))),
    ("F arithmetic", q -> q.values("lap", "c" => F("points") + bare())),
    ("a window's operand", q -> q.values("lap", "c" => Lag(bare(), over = WindowOver(order_by = ["lap"])))),
    ("a Case branch's then", q -> q.values("lap", "c" => Case([When("points" => 2, then = bare())], default = 0))),
    ("a Case's default", q -> q.values("lap", "c" => Case([When("points" => 2, then = 2)], default = bare()))),
    ("a filter value", q -> q.filter("points" => bare())),
    ("a lookup's value", q -> q.filter("points__@gt" => bare())),
    ("a Subquery's projection", q -> (s = q.object.model.objects; s.values("c" => bare()); s.limit(1);
                                      q.values("lap", "c" => PormG.QueryBuilder.Subquery(s)))),
  )
  for (backend, Model_) in ((:postgres, FAggPgFn), (:sqlite, FAggSlFn))
    pg = backend === :postgres
    @testset "$backend: refused as $label" for (label, setup) in positions
      err = _f_agg_build_error(Model_, setup)
      @test err isa QueryBuildError
      msg = _f953_plain(sprint(showerror, err))
      @test occursin("When with no `otherwise` is a branch of a Case", msg)
      @test occursin("When(…, then = x, otherwise = y)", msg)
      @test occursin("Case([When(…, then = x)], default = y)", msg)
    end

    # The branch spellings, by exact SQL and parameters: a vector of branches, the single bare
    # `Case(When(…))`, and `When(…; otherwise)`, which is a CASE holding one branch.
    @testset "$backend: a When as a Case branch renders as before" begin
      m(n) = pg ? "\$$n" : "?"
      t(n) = pg ? "\$$n::bigint" : "?"
      insp(setup) = (q = Model_.objects; setup(q); inspect_query(q))
      i = insp(q -> q.values("lap", "c" => Case([When("lap" => 1, then = 1), When("points" => 2, then = 2)], default = 0)))
      @test occursin("CASE\nWHEN \"Tb\".\"lap\" = $(m(1)) THEN $(t(2))\nWHEN \"Tb\".\"points\" = $(m(3)) THEN $(t(4))\nELSE $(t(5))\nEND\n as \"c\"", i[:sql_text])
      @test i[:parameters] == Any[1, 1, 2, 2, 0]
      single = "CASE WHEN \"Tb\".\"lap\" = $(m(1)) THEN $(t(2)) ELSE $(t(3)) END as \"c\""
      for (label, value) in (("Case(When(…))", () -> Case(When("lap" => 1, then = 1), default = 0)),
                             ("When(…; otherwise)", () -> When("lap" => 1, then = 1, otherwise = 0)))
        i = insp(q -> q.values("lap", "c" => value()))
        @test occursin(single, i[:sql_text])
        @test i[:parameters] == Any[1, 1, 0]
      end
      i = insp(q -> q.values("lap", "c" => Count(When("lap" => 1, then = 1, otherwise = nothing))))
      @test occursin("COUNT(CASE WHEN \"Tb\".\"lap\" = $(m(1)) THEN $(t(2)) ELSE NULL END)", i[:sql_text])
    end
  end
end
