using Test
using PormG
using PormG.Models: Model, IDField, IntegerField, FloatField
using PormG.QueryBuilder: WindowOver, Rank, DenseRank, RowNumber, Lag, NthValue, inspect_query, Count, Sum

struct WindowMockPostgres <: PormG.PormGPostgres end
struct WindowMockSQLite <: PormG.PormGSQLite end

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

  @test_throws ArgumentError q.list(show_query=:dict)
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
# When there is no aggregate (instruc.agregate stays false), GROUP BY must be
# suppressed entirely — even if instruc.group has entries from plain fields.
# This verifies the guard condition `agregate && !isempty(group)`.
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
