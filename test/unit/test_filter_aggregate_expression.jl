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
