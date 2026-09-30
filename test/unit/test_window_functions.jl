using Test
using PormG
using PormG.Models: Model, IDField, IntegerField, FloatField, DateField
using PormG.QueryBuilder: WindowOver, Rank, DenseRank, RowNumber, Lag, NthValue, inspect_query, Count, Sum, Q,
                            WindowSpec, SQLOrder, SQLField, F, Max
using PormG.Functions: Case, When, Coalesce, Value, FirstValue, Lead

struct WindowMockPostgres <: PormG.PormGPostgres end
struct WindowMockSQLite <: PormG.PormGSQLite end

# SQLite window support is gated behind a live version probe (`_assert_sqlite_window_support` →
# `backend_sqlite_version`), which throws "requires SQLite" unless the extension is loaded. Under
# `runtests.jl` it is, via `test/load_drivers.jl`; run this file on its own — as the issue workflow's
# rung-2 slice does — and the LAG testset errored instead. Pinning a version here makes the file
# self-contained on both paths, the same stub `test_cte_db_column.jl` and `test_order_by_joins.jl`
# use for ORDER BY's NULL-placement probe. 3.28 is the floor window functions need.
PormG.backend_sqlite_version(::WindowMockSQLite) = 3045000

PormG.config["window_pg"] = PormG.Configuration.Settings(
  connections=WindowMockPostgres(),
  change_data=true
)
PormG.config["window_sl"] = PormG.Configuration.Settings(
  connections=WindowMockSQLite(),
  change_data=true
)

WindowPgResult = Model("window_results",
  resultid=IDField(),
  raceid=IntegerField(),
  constructorid=IntegerField(),
  points=FloatField(),
  milliseconds=IntegerField(),
)
WindowPgResult.connect_key = "window_pg"

WindowSlResult = Model("window_results",
  resultid=IDField(),
  raceid=IntegerField(),
  constructorid=IntegerField(),
  points=FloatField(),
  milliseconds=IntegerField(),
)
WindowSlResult.connect_key = "window_sl"

# #776's binding ORDER BY term needs a date column, which the result fixtures do not carry.
Window776SlRace = Model("window_races", raceid = IDField(), points = FloatField(), date = DateField())
Window776SlRace.connect_key = "window_sl"
Window789PgRace = Model("window_races", raceid = IDField(), points = FloatField(), date = DateField())
Window789PgRace.connect_key = "window_pg"

# ─────────────────────────────────────────────────────────────────────────────
# Window Functions: RANK renders a partitioned OVER clause without GROUP BY
# This verifies that window-scoped expressions are annotations over each row,
# not aggregate projections that collapse rows or force GROUP BY generation.
# ─────────────────────────────────────────────────────────────────────────────
@testset "Window RANK renders partition/order without GROUP BY" begin
  q = WindowPgResult.objects.values(
    "resultid",
    "team_rank" => Rank(over=WindowOver(partition_by=["constructorid"], order_by=["-points", "resultid"]))
  )

  sql = q.list(show_query=:sql)

  @test contains(sql, "RANK() OVER")
  @test contains(sql, "PARTITION BY \"Tb\".\"constructorid\"")
  @test contains(sql, "ORDER BY \"Tb\".\"points\" DESC, \"Tb\".\"resultid\" ASC")
  @test contains(sql, "as \"team_rank\"")
  @test !contains(sql, "GROUP BY")
end

# ─────────────────────────────────────────────────────────────────────────────
# Window Functions: arithmetic over a window result remains window-scoped
# The result of RowNumber(...) - 1 should render as an expression over the
# window function and still avoid GROUP BY because it does not aggregate rows.
# ─────────────────────────────────────────────────────────────────────────────
@testset "Window functions compose inside FExpression arithmetic" begin
  q = WindowPgResult.objects.values(
    "zero_based_row" => RowNumber(over=WindowOver(order_by=["resultid"])) - 1
  )

  inspection = q |> inspect_query
  sql = inspection[:sql_text]

  @test contains(sql, "ROW_NUMBER() OVER (ORDER BY \"Tb\".\"resultid\" ASC)")
  @test contains(sql, "- \$1::bigint")
  @test inspection[:parameters] == [1]
  @test !contains(sql, "GROUP BY")
end

# ─────────────────────────────────────────────────────────────────────────────
# Window Functions: SELECT-bucket parameters preserve SQLite positional order
# LAG's offset/default parameters appear in the SELECT list before WHERE, so
# they must land in the :select bucket and flatten before WHERE parameters.
# ─────────────────────────────────────────────────────────────────────────────
@testset "Window LAG parameters land in SQLite SELECT bucket" begin
  q = WindowSlResult.objects
  q.values(
    "resultid",
    "previous_points" => Lag(
      "points",
      offset=2,
      default=0.0,
      over=WindowOver(partition_by=["constructorid"], order_by=["raceid"])
    )
  )
  q.filter("raceid__@gte" => 10)

  inspection = q |> inspect_query
  sql = inspection[:sql_text]

  @test contains(sql, "LAG(\"Tb\".\"points\", ?, ?) OVER")
  @test inspection[:parameter_buckets][:select] == [2, 0.0]
  @test inspection[:parameter_buckets][:where] == [10]
  @test inspection[:parameters] == [2, 0.0, 10]
end

# ─────────────────────────────────────────────────────────────────────────────
# Window Functions: NTH_VALUE offset is deliberately a literal integer
# PostgreSQL and SQLite do not accept a bound placeholder in the NTH_VALUE n
# slot, so this verifies the builder does not add it to any parameter bucket.
# ─────────────────────────────────────────────────────────────────────────────
@testset "Window NTH_VALUE renders n as literal integer" begin
  q = WindowSlResult.objects.values(
    "second_points" => NthValue("points", 2, over=WindowOver(order_by=["raceid"]))
  )

  inspection = q |> inspect_query
  sql = inspection[:sql_text]

  @test contains(sql, "NTH_VALUE(\"Tb\".\"points\", 2) OVER")
  @test isempty(inspection[:parameter_buckets][:select])
  @test inspection[:parameters] == []
end

# ─────────────────────────────────────────────────────────────────────────────
# Window Functions: SQLite frame specifications fail early with a clear error
# SQLite support starts with basic OVER clauses here. Explicit frame specs are
# PostgreSQL-only for this phase, so the builder must reject them before SQL IO.
# ─────────────────────────────────────────────────────────────────────────────
@testset "SQLite rejects explicit window frame specifications" begin
  q = WindowSlResult.objects.values(
    "row_number" => RowNumber(over=WindowOver(order_by=["resultid"], frame="ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW"))
  )

  # #268 audit: frame= on SQLite is a capability limit; PormGError alone would also pass for
  # the pre-split QueryBuildError.
  @test_throws PormG.BackendCapabilityError q.list(show_query=:dict)
end

# ─────────────────────────────────────────────────────────────────────────────
# Mixed aggregate + window function: GROUP BY contract
#
# This is the critical interaction: when a query mixes a real aggregate (Count)
# with a window function (Rank), the GROUP BY must:
#   - BE emitted  (because there is an aggregate)
#   - include plain fields (raceid at position 1)
#   - NOT include the window function alias or position
#
# Standard SQL allows window functions alongside GROUP BY aggregates. The window
# function expression is evaluated per-row AFTER grouping, so it must never
# appear in GROUP BY itself.
#
# Before the _is_window_expr guard in build_query.jl, a window function would
# fall through to `push!(instruc.group, ...)` — emitting invalid SQL like
# `GROUP BY 1, 3` where position 3 is RANK() OVER (...), which databases reject.
# ─────────────────────────────────────────────────────────────────────────────
@testset "Mixed Count + Rank: GROUP BY includes plain fields, excludes window alias" begin
  q = WindowPgResult.objects.values(
    "raceid",
    "total" => Count("resultid"),
    "top_rank" => Rank(over=WindowOver(partition_by=["raceid"], order_by=["-points"]))
  )

  inspection = q |> inspect_query
  sql = inspection[:sql_text]

  # Generated SQL (verified against actual output):
  #
  #   SELECT
  #     "Tb"."raceid" as raceid,
  #     COUNT("Tb"."resultid") as total,
  #     RANK() OVER (PARTITION BY "Tb"."raceid" ORDER BY "Tb"."points" DESC) as top_rank
  #   FROM "window_results" as "Tb"
  #   GROUP BY 1
  #
  # This is syntactically valid SQL and matches Django's behavior for the same combination.
  #
  # ⚠ Semantic trap: after GROUP BY raceid, each partition contains exactly one row, so
  # RANK() OVER (PARTITION BY raceid ...) always returns 1. The combination is valid SQL
  # but semantically useless. PormG generates it faithfully (same as Django). The user is
  # responsible for choosing a meaningful window partition that differs from the GROUP BY key.

  # Aggregate and window both appear in SELECT
  @test contains(sql, "COUNT(")
  @test contains(sql, "RANK() OVER")
  @test contains(sql, "as \"top_rank\"")

  # GROUP BY must be present (because Count is an aggregate) and include raceid (position 1).
  # It must NOT include position 3 (the window alias) — that would be invalid SQL.
  @test contains(sql, "GROUP BY 1")
  @test !contains(sql, "GROUP BY 1, 2, 3")
  @test !contains(sql, "GROUP BY 1, 3")
  # The GROUP BY clause itself must not reference the window alias by name —
  # extract the GROUP BY line and check it doesn't contain "top_rank"
  group_by_line = match(r"GROUP BY[^\n]+", sql)
  @test group_by_line !== nothing
  @test !contains(group_by_line.match, "top_rank")
end

# ─────────────────────────────────────────────────────────────────────────────
# Mixed aggregate + window: FExpression arithmetic over window is also excluded
# from GROUP BY. `RowNumber() - 1` produces an FExpression that wraps a
# WindowFunction — _is_window_expr must propagate through the FExpression so
# the GROUP BY guard fires on the outer FExpression, not just on bare
# WindowFunction nodes.
# ─────────────────────────────────────────────────────────────────────────────
@testset "Mixed Sum + window arithmetic: GROUP BY excludes FExpression wrapping window" begin
  q = WindowPgResult.objects.values(
    "constructorid",
    "total_points" => Sum("points"),
    "zero_based_row" => RowNumber(over=WindowOver(order_by=["constructorid"])) - 1
  )

  inspection = q |> inspect_query
  sql = inspection[:sql_text]

  # Both aggregate and window render in SELECT
  @test contains(sql, "SUM(")
  @test contains(sql, "ROW_NUMBER() OVER")

  # GROUP BY must exist (Sum is aggregate) and cover only constructorid (position 1).
  # Positions 2 (Sum) and 3 (window arithmetic) must be absent from GROUP BY.
  @test contains(sql, "GROUP BY 1")
  @test !contains(sql, "GROUP BY 1, 3")
  @test !contains(sql, "GROUP BY 1, 2, 3")
end

# ─────────────────────────────────────────────────────────────────────────────
# Window-only with plain fields: GROUP BY must NOT be emitted
#
# When there is no aggregate (instruc.aggregate stays false), GROUP BY must be
# suppressed entirely — even if instruc.group has entries from plain fields.
# This verifies the guard condition `aggregate && !isempty(group)`.
# ─────────────────────────────────────────────────────────────────────────────
@testset "Window-only with multiple plain fields: no GROUP BY" begin
  q = WindowPgResult.objects.values(
    "raceid",
    "constructorid",
    "rn" => RowNumber(over=WindowOver(partition_by=["raceid"], order_by=["constructorid"]))
  )

  inspection = q |> inspect_query
  sql = inspection[:sql_text]

  @test contains(sql, "ROW_NUMBER() OVER")
  # Both plain fields are in SELECT but no aggregate → GROUP BY must be absent
  @test !contains(sql, "GROUP BY")
end

# ─────────────────────────────────────────────────────────────────────────────
# Column-taking window functions: DenseRank, Lead, FirstValue, LastValue
# These are imported and exported but had no rendering coverage. Each generates
# a distinct SQL function name — verified here to prevent silent regressions.
# ─────────────────────────────────────────────────────────────────────────────
@testset "DenseRank renders DENSE_RANK without GROUP BY" begin
  q = WindowPgResult.objects.values(
    "raceid",
    "dr" => DenseRank(over=WindowOver(partition_by=["constructorid"], order_by=["points"]))
  )
  sql = (q |> inspect_query)[:sql_text]
  @test contains(sql, "DENSE_RANK() OVER (PARTITION BY")
  @test !contains(sql, "GROUP BY")
end

@testset "Lead renders LEAD(col, offset, default) OVER" begin
  import PormG.QueryBuilder: Lead
  q = WindowPgResult.objects.values(
    "resultid",
    "next_ms" => Lead("milliseconds", offset=2, default=0,
                      over=WindowOver(order_by=["resultid"]))
  )
  sql = (q |> inspect_query)[:sql_text]
  @test contains(sql, "LEAD(\"Tb\".\"milliseconds\",")
  @test contains(sql, "OVER (ORDER BY \"Tb\".\"resultid\" ASC)")
  @test !contains(sql, "GROUP BY")
end

# ─────────────────────────────────────────────────────────────────────────────
# Window Functions: a window binds its own arguments before a binding OVER term
# `LAG(col, ?, ?) OVER (PARTITION BY <label>)` prints the offset and default first, but the OVER
# clause used to render (and so bind) first. A `date__@yyyy_q` partition binds nine values, so on
# SQLite every value shifted by one and the offset read the label's "-Q". A binding column
# (`FirstValue(F("points") * 3)`) was shifted the same way. Found beside #789.
# ─────────────────────────────────────────────────────────────────────────────
@testset "A window binds its own arguments before a binding OVER term" begin
  label_ops = Any["-Q", 3, 1, 6, 2, 9, 3, 12, 4]
  by_quarter = () -> WindowOver(partition_by = ["date__@yyyy_q"], order_by = ["raceid"])
  for (label, window, own) in (
      ("Lag, default offset", () -> Lag("points", over = by_quarter()), Any[1]),
      ("Lead, offset and default", () -> PormG.QueryBuilder.Lead("points", offset = 2, default = 0, over = by_quarter()), Any[2, 0]),
      ("FirstValue, binding column", () -> PormG.QueryBuilder.FirstValue(PormG.QueryBuilder.F("points") * 3, over = by_quarter()), Any[3]),
    )
    @testset "SQLite — $label" begin
      q = Window776SlRace.objects
      q.values("raceid", "prev" => window())
      inspection = inspect_query(q)
      # Text order is: the function's own arguments, then the nine label operands inside OVER.
      @test inspection[:parameters] == vcat(own, label_ops)
    end
    @testset "PostgreSQL — $label" begin
      q = Window789PgRace.objects
      q.values("raceid", "prev" => window())
      sql = inspect_query(q)[:sql_text]
      # `$N` numbers in render order, so the label's first operand comes right after the function's own.
      @test occursin(r"PARTITION BY CONCAT\([^$]*\$" * string(length(own) + 1) * r"::text", sql)
    end
  end
end

@testset "FirstValue renders FIRST_VALUE(col) OVER" begin
  import PormG.QueryBuilder: FirstValue
  q = WindowPgResult.objects.values(
    "resultid",
    "first_pts" => FirstValue("points",
                              over=WindowOver(partition_by=["raceid"], order_by=["resultid"]))
  )
  sql = (q |> inspect_query)[:sql_text]
  @test contains(sql, "FIRST_VALUE(\"Tb\".\"points\") OVER")
  @test !contains(sql, "GROUP BY")
end

@testset "LastValue renders LAST_VALUE(col) OVER" begin
  import PormG.QueryBuilder: LastValue
  q = WindowPgResult.objects.values(
    "resultid",
    "last_pts" => LastValue("points",
                            over=WindowOver(partition_by=["raceid"], order_by=["resultid"]))
  )
  sql = (q |> inspect_query)[:sql_text]
  @test contains(sql, "LAST_VALUE(\"Tb\".\"points\") OVER")
  @test !contains(sql, "GROUP BY")
end

# ─────────────────────────────────────────────────────────────────────────────
# ORDER BY window alias: alias is quoted in ORDER BY, not pushed to GROUP BY
#
# When a window function alias is used in order_by(), the builder must:
#   - quote the alias and add it to ORDER BY  (found_in_select == true path)
#   - NOT push it to instruc.group            (would be invalid SQL)
# ─────────────────────────────────────────────────────────────────────────────
@testset "order_by on window alias: quoted in ORDER BY, absent from GROUP BY" begin
  q = WindowPgResult.objects
  q.values(
    "raceid",
    "rn" => RowNumber(over=WindowOver(partition_by=["raceid"], order_by=["resultid"]))
  )
  q.order_by("rn")  # order by the window alias

  inspection = q |> inspect_query
  sql = inspection[:sql_text]

  # The alias must appear in ORDER BY
  @test contains(sql, "ORDER BY")
  normalized = replace(sql, r"\s+" => " ")
  @test contains(normalized, "ORDER BY \"rn\"")
  # No aggregate → no GROUP BY at all
  @test !contains(sql, "GROUP BY")
end

@testset "order_by on window alias mixed with aggregate: alias not in GROUP BY" begin
  q = WindowPgResult.objects
  q.values(
    "raceid",
    "total" => Count("resultid"),
    "rn" => RowNumber(over=WindowOver(order_by=["resultid"]))
  )
  q.order_by("rn")

  inspection = q |> inspect_query
  sql = inspection[:sql_text]

  # Aggregate present → GROUP BY must exist (raceid at position 1)
  @test contains(sql, "GROUP BY 1")
  # The window alias must be in ORDER BY but NOT leaked into GROUP BY
  normalized = replace(sql, r"\s+" => " ")
  @test contains(normalized, "ORDER BY \"rn\"")
  group_by_line = match(r"GROUP BY[^\n]+", sql)
  @test group_by_line !== nothing
  @test !contains(group_by_line.match, "rn")
end

# ─────────────────────────────────────────────────────────────────────────────
# #685 fixtures. `_window_err` builds AND renders, returning the exception or `nothing`: a refusal
# must happen by render time at the latest, and construction alone proves nothing. Both mock
# backends, because the bug reproduced on both — PostgreSQL rejects a window in HAVING outright and
# SQLite rejects HAVING on a query with no aggregate.
# ─────────────────────────────────────────────────────────────────────────────
const _WINDOW_685_MODELS = (("PostgreSQL", WindowPgResult), ("SQLite", WindowSlResult))

_window_err(build) = try
  inspect_query(build())
  nothing
catch e
  e
end

_window_msg(err) = err === nothing ? "" : PormG.error_message(err)

# ─────────────────────────────────────────────────────────────────────────────
# Window alias filter (#685): refused at build time instead of rendered as HAVING
# A projection alias is routed to HAVING — right for an aggregate, never right for a window, since
# SQL evaluates windows after WHERE AND HAVING. Before the fix every spelling here rendered
# `HAVING RANK() OVER (…) = ?` and failed at the driver; now each is a typed `QueryBuildError` naming
# the alias and the CTE route. Covers the bare alias, a window nested in arithmetic (the detection
# walks the expression), a value function, a lookup suffix, and the Q/Qor wrappers that reach the
# alias through the WHERE path rather than the HAVING branch.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#685: filter on a window alias is refused, not rendered as HAVING" begin
  for (backend, Model_) in _WINDOW_685_MODELS
    rank = () -> Rank(over = WindowOver(order_by = ["-points"]))
    for (label, alias, build) in (
        ("bare Rank alias", "r", () -> (q = Model_.objects; q.filter("raceid" => 306);
                                        q.values("points", "r" => rank()); q.filter("r" => 1); q)),
        ("Rank nested in arithmetic", "r", () -> (q = Model_.objects;
                                        q.values("points", "r" => rank() + 1); q.filter("r" => 2); q)),
        ("Lag value alias", "prev", () -> (q = Model_.objects;
                                        q.values("points", "prev" => Lag("points", over = WindowOver(order_by = ["raceid"])));
                                        q.filter("prev__@gt" => 5.0); q)),
        ("lookup suffix on a Rank alias", "r", () -> (q = Model_.objects;
                                        q.values("points", "r" => rank()); q.filter("r__@lte" => 3); q)),
        # Inside Q/Qor the alias skips the HAVING branch and resolves through the memo instead, which
        # printed `RANK() OVER (…)` into WHERE — the same late failure by another spelling.
        ("Rank alias inside Q", "r", () -> (q = Model_.objects;
                                        q.values("points", "r" => rank()); q.filter(Q("r" => 1)); q)),
        ("Rank alias inside Qor", "r", () -> (q = Model_.objects;
                                        q.values("points", "r" => rank()); q.filter(Qor("r" => 1, "r" => 2)); q)),
      )
      @testset "$backend — $label" begin
        err = _window_err(build)
        @test err isa PormG.QueryBuildError
        msg = _window_msg(err)
        # The message names the caller's own alias and the route that works.
        @test occursin("\"$(alias)\"", msg)
        @test occursin(".with(", msg)
        @test occursin("#685", msg)
      end
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# Window alias filter (#685) controls: the refusal is exactly as wide as the window case
# An aggregate alias beside a window alias must still filter through HAVING, and ordering on the
# window alias must still work — the guard looks at what the FILTERED alias projects, not at whether
# a window exists anywhere in the projection.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#685 controls: aggregate alias HAVING and window-alias ORDER BY still render" begin
  for (backend, Model_) in _WINDOW_685_MODELS
    @testset "$backend" begin
      q = Model_.objects
      q.values("constructorid", "total" => Count("resultid"),
               "rk" => Rank(over = WindowOver(order_by = ["constructorid"])))
      q.filter("total__@gte" => 2)
      q.order_by("rk")
      sql = replace(inspect_query(q)[:sql_text], r"\s+" => " ")
      @test occursin("HAVING COUNT(", sql)
      @test !occursin(r"HAVING[^\n]*OVER", sql)
      @test occursin("ORDER BY \"rk\"", sql)
    end

    @testset "$backend — a window alias inside a SELECT-side CASE still renders" begin
      # `When("r" => 1)` is a predicate on the window alias too, but in the select list, where a
      # window is legal. The refusal is for filter clauses only; this rendered before #685 and must
      # keep rendering.
      q = Model_.objects
      q.values("points", "r" => Rank(over = WindowOver(order_by = ["-points"])),
               "top" => Case([When("r" => 1, then = 1)], default = 0))
      sql = inspect_query(q)[:sql_text]
      @test occursin(r"CASE\s+WHEN RANK\(\) OVER", sql)
      @test !occursin("WHERE", sql)
    end

    @testset "$backend — a model field sharing a window alias's name is ambiguous (#703)" begin
      # "points" names a model field AND the window's output alias. This used to assert that the
      # key filters the column, and it did — but only because `"r" => "points"` claimed the memo
      # entry for "points" first. With an aggregate under the same name the key printed `SUM(…)`
      # into WHERE (#703), so "the field wins" was never a rule. The key has two meanings, and it is
      # refused on both spellings, as #492 refuses a `__` path that names a CTE and a field.
      for wrap in (identity, Q)
        q = Model_.objects
        q.values("r" => "points", "points" => Rank(over = WindowOver(order_by = ["raceid"])))
        q.filter(wrap("points" => 5.0))
        err = @test_throws AmbiguousFieldError inspect_query(q)
        @test occursin("#703", err.value.msg)
      end
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# #722 window twin: a projection that reads a window alias is a window
# `"top" => Case([When("rk" => 1, then = 1)])` renders `CASE WHEN RANK() OVER (…) = ?`, but its
# condition holds only the name "rk", so nothing on the node says window. Beside an aggregate it was
# grouped — `GROUP BY 1, 4`, and neither engine allows a window in GROUP BY — and a filter on its
# alias printed the window into WHERE, past #685's refusal. It now stays out of GROUP BY like the
# window alias it reads, and a filter on it is refused like one. The SELECT-side CASE itself is legal
# SQL and still renders (the #685 control above).
# ─────────────────────────────────────────────────────────────────────────────
@testset "#722: a projection reading a window alias is a window" begin
  for (backend, Model_) in _WINDOW_685_MODELS
    project! = q -> q.values("constructorid", "n" => Count("resultid"),
                             "rk" => Rank(over = WindowOver(order_by = ["constructorid"])),
                             "top" => Case([When("rk" => 1, then = 1)], default = 0))
    @testset "$backend — not grouped beside an aggregate" begin
      q = Model_.objects
      project!(q)
      sql = inspect_query(q)[:sql_text]
      @test occursin(r"CASE\s+WHEN RANK\(\) OVER", sql)
      # Grouped by the plain column alone: neither the window nor the CASE that reads it.
      @test occursin(r"GROUP BY 1\s*$", sql)
    end
    for (label, pred) in (("top-level", "top" => 1), ("Q", Q("top" => 1)))
      @testset "$backend — a $label filter on it is refused (#685)" begin
        q = Model_.objects
        project!(q)
        q.filter(pred)
        err = _window_err(() -> q)
        @test err isa PormG.QueryBuildError
        msg = _window_msg(err)
        @test occursin("\"top\"", msg)
        @test occursin("#685", msg)
      end
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# #756: a window written directly in a Case branch is a window
# #722's direct twin. The window is not reached through an alias but written inside the branch, so it
# sits in a keyword slot — `When`'s `then`, `Case`'s `else` — which `_is_window_expr` did not walk.
# Beside an aggregate the CASE was grouped (`GROUP BY 1, 3`: a window in GROUP BY, rejected by both
# engines), and a filter on its alias printed `RANK() OVER` into WHERE, past #685's refusal.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#756: a window inside a Case branch is a window" begin
  rank = () -> Rank(over = WindowOver(order_by = ["raceid"]))
  for (backend, Model_) in _WINDOW_685_MODELS
    for (slot, top) in (("then", () -> Case([When("raceid" => 1, then = rank())], default = 0)),
                        ("default", () -> Case([When("raceid" => 1, then = 0)], default = rank())))
      @testset "$backend — window in `$slot`: not grouped beside an aggregate" begin
        q = Model_.objects
        q.values("raceid", "n" => Count("resultid"), "top" => top())
        sql = inspect_query(q)[:sql_text]
        @test occursin("RANK() OVER", sql)
        @test occursin(r"GROUP BY 1\s*$", sql)
      end
      for (label, pred) in (("top-level", "top" => 1), ("Q", Q("top" => 1)))
        @testset "$backend — window in `$slot`: a $label filter on it is refused (#685)" begin
          q = Model_.objects
          q.values("raceid", "top" => top())
          q.filter(pred)
          err = _window_err(() -> q)
          @test err isa PormG.QueryBuildError
          msg = _window_msg(err)
          @test occursin("\"top\"", msg)
          @test occursin("#685", msg)
        end
      end
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# #756 review: a projection that is both an aggregate and a window keeps GROUP BY
# Answering "window" first skipped the aggregate flag, so the plain column's GROUP BY vanished and
# PostgreSQL would reject the statement. #756 widened that to a `Case` with a window in one branch;
# the arithmetic shape predates it.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#756 review: a projection that is both an aggregate and a window keeps GROUP BY" begin
  rank = () -> Rank(over = WindowOver(order_by = ["raceid"]))
  for (backend, Model_) in _WINDOW_685_MODELS
    for (label, mixed) in (
        ("Case: aggregate branch, window default", () -> Case([When("raceid" => 1, then = Sum("points"))], default = rank())),
        ("arithmetic", () -> rank() + Sum("points")),
      )
      @testset "$backend — $label" begin
        q = Model_.objects
        q.values("raceid", "x" => mixed())
        sql = inspect_query(q)[:sql_text]
        @test occursin(r"GROUP BY 1\s*$", sql)
      end
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# #776: a window over an aggregate makes the statement aggregate
# `_is_agg(::WindowFunction)` is `false`, and the GROUP BY decision asked only that, so `Lag(Sum(…))`
# or `PARTITION BY Sum(…)` beside a plain column printed no GROUP BY at all: SQLite collapsed the
# filter into one row with an arbitrary `raceid`. The window itself stays out of GROUP BY, and a
# filter on its alias is still refused as a window (#685), not routed to HAVING as an aggregate.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#776: a window over an aggregate keeps GROUP BY for the plain columns" begin
  lag_sum = () -> Lag(Sum("points"), over = WindowOver(order_by = ["raceid"]))
  for (backend, Model_) in _WINDOW_685_MODELS
    for (label, window) in (
        ("aggregate argument", lag_sum),
        ("aggregate in PARTITION BY", () -> Rank(over = WindowOver(partition_by = [Sum("points")], order_by = ["raceid"]))),
        ("wrapped in a function", () -> Coalesce(lag_sum(), Value(0))),
        ("wrapped in arithmetic", () -> lag_sum() + 1),
        # A `When` branch sits in a keyword slot, the one `_contains_agg` reads besides `column`.
        ("in a Case branch", () -> Case([When("raceid__@gt" => 0, then = lag_sum())], default = 0)),
        # `WindowOver` refuses a function in `order_by`; an exported `WindowSpec` does not check.
        ("aggregate in a WindowSpec's ORDER BY",
         () -> Rank(over = WindowSpec(order_by = [SQLOrder(SQLField(Sum("points"), "s"); orientation = "DESC")]))),
      )
      @testset "$backend — $label" begin
        q = Model_.objects
        q.filter("raceid__@lte" => 5)
        q.values("raceid", "prev" => window())
        sql = inspect_query(q)[:sql_text]
        @test occursin(" OVER (", sql)
        @test occursin(r"GROUP BY 1\s*$", sql)
      end
    end

    @testset "$backend — a condition reading the window's alias" begin
      q = Model_.objects
      q.values("raceid", "prev" => lag_sum(), "up" => Case([When("prev__@gt" => 0, then = 1)], default = 0))
      @test occursin(r"GROUP BY 1\s*$", inspect_query(q)[:sql_text])
    end

    @testset "$backend — a window over a plain column still has no GROUP BY" begin
      q = Model_.objects
      q.values("raceid", "prev" => Lag("points", over = WindowOver(order_by = ["raceid"])))
      @test !occursin("GROUP BY", inspect_query(q)[:sql_text])
    end

    for (label, pred) in (("top-level", "prev" => 1), ("Q", Q("prev" => 1)))
      @testset "$backend — a $label filter on the alias is still refused as a window (#685)" begin
        q = Model_.objects
        q.values("raceid", "prev" => lag_sum())
        q.filter(pred)
        err = _window_err(() -> q)
        @test err isa PormG.QueryBuildError
        msg = _window_msg(err)
        @test occursin("\"prev\"", msg)
        @test occursin("#685", msg)
      end
    end
  end

  # #587: GROUP BY now prints, so an ORDER BY term that binds is printed — and bound — twice. On
  # SQLite every `?` needs its own value; the label below binds nine.
  @testset "SQLite — a binding ORDER BY term is bound under GROUP BY too" begin
    q = Window776SlRace.objects
    q.values("raceid", "prev" => lag_sum())
    q.order_by("date__@yyyy_q")
    inspection = inspect_query(q)
    label_ops = Any["-Q", 3, 1, 6, 2, 9, 3, 12, 4]
    @test count("?", inspection[:sql_text]) == length(inspection[:parameters])
    @test inspection[:parameter_buckets][:group] == label_ops
    @test inspection[:parameters] == vcat(Any[1], label_ops, label_ops)
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# #789: an aggregating statement groups the columns a window's OVER (…) reads
# #776 grouped the projected columns beside `Lag(Sum(…))`, but a column named only inside `OVER (…)`
# stayed ungrouped: PostgreSQL raised `GroupingError`, SQLite returned one arbitrary row per group.
# Every non-aggregate PARTITION BY / ORDER BY term now joins GROUP BY (Django's
# `Window.get_group_by_cols`), once, and never when it is already grouped.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#789: the columns a window reads join GROUP BY" begin
  lag_sum = (; partition_by = String[]) ->
    Lag(Sum("points"), over = WindowOver(partition_by = partition_by, order_by = ["raceid"]))
  group_clause(q) = match(r"GROUP BY (.*?)\s*(ORDER BY.*)?$"s, inspect_query(q)[:sql_text])
  grouped(q) = (m = group_clause(q); m === nothing ? nothing : strip(m.captures[1]))
  for (backend, Model_) in _WINDOW_685_MODELS
    @testset "$backend — the OVER column is the only column read" begin
      # The issue's shape 1: nothing projected but the window, so GROUP BY is the OVER column alone.
      q = Model_.objects
      q.filter("raceid__@lte" => 5)
      q.values("prev" => lag_sum())
      @test grouped(q) == "\"Tb\".\"raceid\""
    end

    @testset "$backend — a projected column that is not the OVER column" begin
      # Shape 2: the projection is grouped by position, the OVER column beside it by expression.
      q = Model_.objects
      q.values("constructorid", "prev" => lag_sum())
      @test grouped(q) == "1, \"Tb\".\"raceid\""
    end

    @testset "$backend — a PARTITION BY column" begin
      q = Model_.objects
      q.values("raceid", "prev" => lag_sum(partition_by = ["constructorid"]))
      @test grouped(q) == "1, \"Tb\".\"constructorid\""
    end

    @testset "$backend — a plain window beside an aggregate" begin
      # Not a window over an aggregate at all: `Sum` makes the statement aggregate, and `Rank`'s
      # ORDER BY column was ungrouped for the same reason.
      q = Model_.objects
      q.values("constructorid", "total" => Sum("points"), "rk" => Rank(over = WindowOver(order_by = ["raceid"])))
      @test grouped(q) == "1, \"Tb\".\"raceid\""
    end

    @testset "$backend — an aggregate PARTITION BY term is not grouped" begin
      q = Model_.objects
      q.values("rk" => Rank(over = WindowOver(partition_by = [Sum("points")], order_by = ["raceid"])))
      @test grouped(q) == "\"Tb\".\"raceid\""
    end

    @testset "$backend — a PARTITION BY term that reads an aggregate alias is not grouped" begin
      # The condition holds only the name "total", but renders `SUM(…)`: it must be resolved (#722)
      # before it is grouped, since an aggregate in GROUP BY is an error on both engines.
      q = Model_.objects
      q.values("constructorid", "total" => Sum("points"),
               "rk" => Rank(over = WindowOver(partition_by = [Case([When("total__@gte" => 100, then = 1)], default = 0)],
                                               order_by = ["constructorid"])))
      @test grouped(q) == "1"
    end

    @testset "$backend — a term already grouped is not repeated" begin
      # Projected OVER columns: the *Mixing with Aggregates* docs shape keeps its clause.
      q = Model_.objects
      q.values("constructorid", "points", "c" => Count("resultid"),
               "rk" => Rank(over = WindowOver(partition_by = ["constructorid"], order_by = ["-points"])))
      @test grouped(q) == "1, 2"
      # Two windows that read the same column group it once.
      q = Model_.objects
      q.values("prev" => lag_sum(), "rk" => Rank(over = WindowOver(order_by = ["-raceid"])))
      @test grouped(q) == "\"Tb\".\"raceid\""
      # A query-level ORDER BY term, which `get_order_query` groups first, is not grouped twice.
      q = Model_.objects
      q.values("prev" => lag_sum())
      q.order_by("raceid")
      @test grouped(q) == "\"Tb\".\"raceid\""
    end

  end

  # A binding OVER term is printed a second time under GROUP BY, so on SQLite its nine label values
  # are bound a second time too — under `:group`, after WHERE's, where the clause prints (#587).
  @testset "SQLite — a binding PARTITION BY term is bound under GROUP BY too" begin
    q = Window776SlRace.objects
    q.filter("raceid__@lte" => 5)
    q.values("prev" => lag_sum(partition_by = ["date__@yyyy_q"]))
    inspection = inspect_query(q)
    label_ops = Any["-Q", 3, 1, 6, 2, 9, 3, 12, 4]
    @test count("?", inspection[:sql_text]) == length(inspection[:parameters])
    @test inspection[:parameter_buckets][:group] == label_ops
    # LAG's offset, the label inside OVER, WHERE's bound, then the label again under GROUP BY.
    @test inspection[:parameters] == vcat(Any[1], label_ops, Any[5], label_ops)
  end

  # Without an aggregate no GROUP BY prints, so nothing may be bound for one: a copy under `:group`
  # would leave SQLite with more values than markers.
  @testset "SQLite — a statement that does not aggregate binds the OVER term once" begin
    q = Window776SlRace.objects
    q.values("raceid", "prev" => Lag("points", over = WindowOver(partition_by = ["date__@yyyy_q"], order_by = ["raceid"])))
    inspection = inspect_query(q)
    @test isempty(inspection[:parameter_buckets][:group])
    @test count("?", inspection[:sql_text]) == length(inspection[:parameters])
  end

  # PostgreSQL binds once and prints the same `$N` twice, so GROUP BY carries the OVER term verbatim.
  @testset "PostgreSQL — a binding PARTITION BY term reuses its own numbering" begin
    q = Window789PgRace.objects
    q.values("prev" => lag_sum(partition_by = ["date__@yyyy_q"]))
    inspection = inspect_query(q)
    sql = inspection[:sql_text]
    partition = match(r"PARTITION BY (.*) ORDER BY \"Tb\"\.\"raceid\" ASC\)"s, sql).captures[1]
    # The partition term verbatim, then the window's own ORDER BY column.
    @test grouped(q) == strip(partition) * ", \"Tb\".\"raceid\""
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# #798: a window term mixing a column and an aggregate needs that column grouped
# #789 groups a plain OVER term and leaves an aggregate one out; a MIXED term — `raceid + SUM(points)`
# — was left out whole, so `raceid` inside it was never grouped: PostgreSQL raised `GroupingError`
# and SQLite ranked by an arbitrary row's `raceid`. It is now refused at build time naming the column
# and where it sits, and still builds whenever the statement groups that column by any route.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#798: a mixed window term reads a column that must be grouped" begin
  mixed = () -> F("raceid") + Sum("points")
  rank_partition = () -> Rank(over = WindowOver(partition_by = [mixed()], order_by = ["constructorid"]))
  # `WindowOver` refuses a function in `order_by`; the exported `WindowSpec` spelling reaches it.
  rank_order = (; partition_by = String[]) ->
    Rank(over = WindowSpec(partition_by = partition_by,
                           order_by = [SQLOrder(SQLField(mixed(), "s"); orientation = "DESC")]))
  grouped(q) = (m = match(r"GROUP BY (.*?)\s*$"s, inspect_query(q)[:sql_text]); m === nothing ? nothing : strip(m.captures[1]))
  for (backend, Model_) in _WINDOW_685_MODELS
    for (label, clause, window) in (
        # The issue's shape.
        ("a mixed PARTITION BY term", "PARTITION BY", rank_partition),
        ("a mixed ORDER BY term", "ORDER BY", rank_order),
        # The window's own argument is the same kind of read, one slot over.
        ("a mixed window argument", "argument", () -> Lag(mixed(), over = WindowOver(order_by = ["constructorid"]))),
      )
      @testset "$backend — refused: $label" begin
        q = Model_.objects
        q.values("constructorid", "rk" => window())
        err = _window_err(() -> q)
        @test err isa PormG.QueryBuildError
        # Colour is on under CI and stripped off a TTY, so match the plain text either way.
        msg = replace(_window_msg(err), r"\e\[[0-9;]*m" => "")
        @test occursin("#798", msg)
        @test occursin("projection rk reads the column \"raceid\"", msg)
        @test occursin(clause, msg)
        # The fix line names the paste-able column and the clause to put it in.
        @test occursin("add \"raceid\" to values(...)", msg)
      end
    end

    @testset "$backend — refused: a column added to a window beside an aggregate" begin
      # The window itself is plain, but `raceid +` sits outside every aggregate call.
      q = Model_.objects
      q.values("constructorid", "t" => Sum("points"), "x" => F("raceid") + Rank(over = WindowOver(order_by = ["constructorid"])))
      err = _window_err(() -> q)
      @test err isa PormG.QueryBuildError
      @test occursin("in its expression", _window_msg(err))
    end

    @testset "$backend — builds: the column is projected" begin
      q = Model_.objects
      q.values("raceid", "rk" => rank_partition())
      sql = inspect_query(q)[:sql_text]
      @test occursin("PARTITION BY (\"Tb\".\"raceid\" + SUM(\"Tb\".\"points\"))", sql)
      # The projected `raceid` by position, and #789's plain ORDER BY column by expression.
      @test grouped(q) == "1, \"Tb\".\"constructorid\""
    end

    @testset "$backend — builds: the column is grouped by a plain #789 term" begin
      # Only `_group_window_terms!` groups `raceid` here, so this pins the check AFTER it.
      q = Model_.objects
      q.values("constructorid", "rk" => rank_order(partition_by = ["raceid"]))
      @test grouped(q) == "1, \"Tb\".\"raceid\""
    end

    @testset "$backend — builds: a statement that does not aggregate" begin
      q = Model_.objects
      q.values("constructorid", "x" => F("raceid") + Rank(over = WindowOver(order_by = ["constructorid"])))
      @test !occursin("GROUP BY", inspect_query(q)[:sql_text])
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# #809: a window's PLAIN argument beside an aggregate needs its column grouped
# `LAG("Tb"."raceid") OVER (…)` beside `SUM(…)` reads `raceid` once per group, and nothing grouped it:
# #789 groups OVER terms only, and #798 entered the argument only when it held an aggregate.
# PostgreSQL raised `GroupingError`; SQLite answered with an arbitrary row's `raceid`. Refused now,
# like #798, and it still builds whenever the statement groups the column by any route.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#809: a plain window argument reads a column that must be grouped" begin
  by_team = () -> WindowOver(order_by = ["constructorid"])
  for (backend, Model_) in _WINDOW_685_MODELS
    for (label, window) in (
        # The issue's shape, then the other functions that take an argument.
        ("Lag", () -> Lag("raceid", over = by_team())),
        ("Lead", () -> Lead("raceid", over = by_team())),
        ("FirstValue over an F expression", () -> FirstValue(F("raceid") * 2, over = by_team())),
        ("NthValue", () -> NthValue("raceid", 2, over = by_team())),
        ("LastValue", () -> PormG.QueryBuilder.LastValue("raceid", over = by_team())),
      )
      @testset "$backend — refused: $label" begin
        q = Model_.objects
        q.values("constructorid", "t" => Sum("points"), "prev" => window())
        err = _window_err(() -> q)
        @test err isa PormG.QueryBuildError
        msg = replace(_window_msg(err), r"\e\[[0-9;]*m" => "")
        @test occursin("projection prev reads the column \"raceid\"", msg)
        @test occursin("in its window function's argument", msg)
        @test occursin("add \"raceid\" to values(...)", msg)
      end
    end

    @testset "$backend — refused: a plain default beside an aggregated argument" begin
      # The argument is `SUM(points)`, which #798 already entered; `default` renders beside it and
      # reads `raceid` per group just the same.
      # (`default = F("raceid")` is the natural spelling, but it crashes before this check: #808.)
      q = Model_.objects
      q.values("constructorid", "prev" => Lag(Sum("points"), default = Coalesce("raceid", 0), over = by_team()))
      err = _window_err(() -> q)
      @test err isa PormG.QueryBuildError
      msg = replace(_window_msg(err), r"\e\[[0-9;]*m" => "")
      @test occursin("reads the column \"raceid\"", msg)
      @test occursin("in its window function's default", msg)
    end

    @testset "$backend — refused: the window inside an expression" begin
      q = Model_.objects
      q.values("constructorid", "t" => Sum("points"), "d" => Lag("raceid", over = by_team()) - F("constructorid"))
      err = _window_err(() -> q)
      @test err isa PormG.QueryBuildError
      @test occursin("in its window function's argument", _window_msg(err))
    end

    @testset "$backend — builds: the argument is projected" begin
      q = Model_.objects
      q.values("constructorid", "raceid", "t" => Sum("points"), "prev" => Lag("raceid", over = by_team()))
      @test occursin(r"GROUP BY 1, 2\s*$", inspect_query(q)[:sql_text])
    end

    @testset "$backend — builds: the argument is grouped by a plain #789 term" begin
      q = Model_.objects
      q.values("constructorid", "t" => Sum("points"),
               "prev" => Lag("raceid", over = WindowOver(partition_by = ["raceid"], order_by = ["constructorid"])))
      @test occursin(r"GROUP BY 1, \"Tb\"\.\"raceid\"\s*$", inspect_query(q)[:sql_text])
    end

    @testset "$backend — builds: the argument is grouped through order_by" begin
      q = Model_.objects
      q.values("constructorid", "t" => Sum("points"), "prev" => Lag("raceid", over = by_team()))
      q.order_by("raceid")
      @test occursin("GROUP BY 1, \"Tb\".\"raceid\"", inspect_query(q)[:sql_text])
    end

    @testset "$backend — builds: the argument is aggregated" begin
      q = Model_.objects
      q.values("constructorid", "t" => Sum("points"), "prev" => Lag(Max("raceid"), over = by_team()))
      sql = inspect_query(q)[:sql_text]
      @test occursin("LAG(MAX(\"Tb\".\"raceid\")", sql)
      @test occursin(r"GROUP BY 1\s*$", sql)
    end

    @testset "$backend — builds: a literal default is a bound value, not a column" begin
      q = Model_.objects
      q.values("constructorid", "prev" => Lag(Sum("points"), default = 0, over = by_team()))
      @test occursin(r"GROUP BY 1\s*$", inspect_query(q)[:sql_text])
    end
  end

  # A transform argument is grouped by its own projected path or by the column under it.
  for (backend, Race) in (("PostgreSQL", Window789PgRace), ("SQLite", Window776SlRace))
    @testset "$backend — builds: a transform argument grouped by path or by column" begin
      for grouped in ("date__@year", "date")
        q = Race.objects
        q.values(grouped, "t" => Sum("points"), "prev" => Lag("date__@year", over = WindowOver(order_by = [grouped])))
        @test occursin(r"GROUP BY 1\s*$", inspect_query(q)[:sql_text])
      end
    end

    @testset "$backend — refused: a transform argument over an ungrouped column" begin
      q = Race.objects
      q.values("raceid", "t" => Sum("points"), "prev" => Lag("date__@year", over = WindowOver(order_by = ["raceid"])))
      err = _window_err(() -> q)
      @test err isa PormG.QueryBuildError
      @test occursin("reads the column \"date\"", replace(_window_msg(err), r"\e\[[0-9;]*m" => ""))
    end
  end
end

# A CTE joins back through the model registry, which the standalone `Model(...)` fixtures above
# never enter — so the CTE route gets its own `set_models` module, one config key per backend.
PormG.config["window_685_pg"] = PormG.Configuration.Settings(connections = WindowMockPostgres(), change_data = true,
                                                                  db_def_folder = "window_685_pg")
PormG.config["window_685_sl"] = PormG.Configuration.Settings(connections = WindowMockSQLite(), change_data = true,
                                                                  db_def_folder = "window_685_sl")

module Window685Pg
import PormG, PormG.Models
Result = Models.Model("window_results", resultid = Models.IDField(), raceid = Models.IntegerField(),
                      points = Models.FloatField(), surname = Models.CharField())
PormG.Models.set_models(@__MODULE__, "window_685_pg")
end

module Window685Sl
import PormG, PormG.Models
Result = Models.Model("window_results", resultid = Models.IDField(), raceid = Models.IntegerField(),
                      points = Models.FloatField(), surname = Models.CharField())
PormG.Models.set_models(@__MODULE__, "window_685_sl")
end

# ─────────────────────────────────────────────────────────────────────────────
# Window columns in a CTE body (#685): the route the refusal points at really works
# `_set_field_from_sql_function` could not type a window column, so a CTE body projecting `Rank`
# raised "RANK is not a recognized function" — the #537 message named a route that did not exist.
# A ranking column types as an integer; a value function types as its column, so the outer filter
# binds its value with that column's formatter. The outer predicate lands in WHERE, on the CTE's
# joined column, with the parameters in print order.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#685: a window column in a CTE body is typed and filterable from the outer query" begin
  for (backend, Model_) in (("PostgreSQL", Window685Pg.Result), ("SQLite", Window685Sl.Result))
    @testset "$backend — Rank" begin
      ranked = Model_.objects
      ranked.values("resultid", "rk" => Rank(over = WindowOver(partition_by = "raceid", order_by = ["-points"])))
      q = Model_.objects
      q.with("ranked" => ranked, join_field = "resultid" => "resultid")
      q.filter("raceid" => 306)
      q.values("raceid", "points")
      q.filter("ranked__rk" => 1)
      inspection = inspect_query(q)
      sql = replace(inspection[:sql_text], r"\s+" => " ")
      @test occursin("RANK() OVER (PARTITION BY", sql)
      @test occursin(r"WHERE \"R1\"\.\"raceid\" = (\?|\$1) AND \"R1_1\"\.\"rk\" = (\?|\$2)", sql)
      @test !occursin("HAVING", sql)
      @test inspection[:parameters] == Any[306, 1]
    end

    @testset "$backend — Lag types as its column" begin
      # A text column is the discriminating case: typed as an integer (the fallback every other
      # arm uses), the outer filter would refuse "Senna" as "not a valid number".
      prev = Model_.objects
      prev.values("resultid", "prev" => Lag("surname", over = WindowOver(order_by = ["raceid"])))
      q = Model_.objects
      q.with("lagged" => prev, join_field = "resultid" => "resultid")
      q.values("raceid", "points")
      q.filter("lagged__prev" => "Senna")
      inspection = inspect_query(q)
      # LAG's default offset binds first, inside the CTE body; the outer value follows it.
      @test occursin(r"WHERE \"R1_1\"\.\"prev\" = (\?|\$2)", inspection[:sql_text])
      @test inspection[:parameters] == Any[1, "Senna"]
    end

    @testset "$backend — an untypeable window argument is a typed refusal" begin
      # `Lag(F("points"))` carries an FExpression, which names no column the arm can type from. It
      # must be a QueryBuildError inside the taxonomy, never a MethodError from a missing arm.
      prev = Model_.objects
      prev.values("resultid", "prev" => Lag(F("points"), over = WindowOver(order_by = ["raceid"])))
      q = Model_.objects
      q.with("lagged" => prev, join_field = "resultid" => "resultid")
      q.values("raceid")
      err = _window_err(() -> q)
      @test err isa PormG.QueryBuildError
      @test occursin("LAG", _window_msg(err))
    end
  end
end

# #809 through a CTE handle: the argument is a `CTE(...)` column, which is grouped only when the
# query projects that handle or its `"<cte>__<col>"` path. Here, beside the #685 CTE fixtures, because
# a CTE joins back through the model registry.
@testset "#809: a CTE handle as a plain window argument" begin
  for (backend, Model_) in (("PostgreSQL", Window685Pg.Result), ("SQLite", Window685Sl.Result))
    with_ranked = () -> begin
      ranked = Model_.objects
      ranked.values("resultid", "rk" => Rank(over = WindowOver(partition_by = "raceid", order_by = ["-points"])))
      q = Model_.objects
      q.with("ranked" => ranked, join_field = "resultid" => "resultid")
      q
    end
    by_race = WindowOver(order_by = ["raceid"])

    @testset "$backend — refused: the handle is not grouped" begin
      q = with_ranked()
      q.values("raceid", "t" => Sum("points"), "prev" => Lag(PormG.CTE("ranked", "rk"), over = by_race))
      err = _window_err(() -> q)
      @test err isa PormG.QueryBuildError
      msg = replace(_window_msg(err), r"\e\[[0-9;]*m" => "")
      @test occursin("reads the column CTE(\"ranked\", \"rk\")", msg)
      @test occursin("in its window function's argument", msg)
    end

    for (label, grouped) in (("the handle", PormG.CTE("ranked", "rk")), ("its path", "ranked__rk"))
      @testset "$backend — builds: $label is projected" begin
        q = with_ranked()
        q.values(grouped, "t" => Sum("points"), "prev" => Lag(PormG.CTE("ranked", "rk"), over = by_race))
        # The handle by position; `raceid` by #789, since the window orders by it.
        @test occursin(r"GROUP BY 1, \"R1\"\.\"raceid\"\s*$", inspect_query(q)[:sql_text])
      end
    end
  end
end
