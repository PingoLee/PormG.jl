using Test
using PormG
using PormG.Models: Model, IDField, IntegerField, FloatField
using PormG.QueryBuilder: inspect_query, Count, Sum, Max
using PormG.Functions: Case, When

include("helper_marker_alignment.jl")

# ─────────────────────────────────────────────────────────────────────────────
# #692 fixtures: one standalone results model per mock backend. The bug reproduced on both —
# `WHERE (COUNT(…) = ?)` is rejected by PostgreSQL and SQLite alike — and the split below moves
# values between the `:where` and `:having` buckets, which only a positional backend (SQLite) can
# get wrong silently, so every testset runs on both.
# ─────────────────────────────────────────────────────────────────────────────
struct QAggMockPostgres <: PormG.PormGPostgres end
struct QAggMockSQLite <: PormG.PormGSQLite end

PormG.config["q_agg_pg"] = PormG.Configuration.Settings(connections = QAggMockPostgres(), change_data = true)
PormG.config["q_agg_sl"] = PormG.Configuration.Settings(connections = QAggMockSQLite(), change_data = true)

QAggPgResult = Model("q_agg_results", resultid = IDField(), raceid = IntegerField(), points = FloatField())
QAggPgResult.connect_key = "q_agg_pg"
QAggSlResult = Model("q_agg_results", resultid = IDField(), raceid = IntegerField(), points = FloatField())
QAggSlResult.connect_key = "q_agg_sl"

const _Q_AGG_MODELS = ((:postgres, QAggPgResult), (:sqlite, QAggSlResult))

# The grouped projection every case filters: per-race result count and points total.
function _q_agg_query(Model_)
  q = Model_.objects
  q.values("raceid", "n" => Count("resultid"), "total" => Sum("points"))
  return q
end

# The text of one clause, from its keyword up to the next clause keyword (or the end).
_clause(sql, kw) = (m = match(Regex("$(kw) (.*?)(?:\\s+(?:GROUP BY|HAVING|ORDER BY|LIMIT)\\b|\\z)", "s"), sql);
                    m === nothing ? nothing : strip(m.captures[1]))

# ─────────────────────────────────────────────────────────────────────────────
# Q on an aggregate alias: renders in HAVING, not WHERE
# `filter(Q("n" => 1))` printed the projection's memoized `COUNT(…)` text into WHERE, a driver
# error on both engines. It must render the predicate the unwrapped `filter("n" => 1)` renders, in
# HAVING, with no WHERE clause at all — parenthesised as a Q is in WHERE, and bound identically.
# Covers a lookup suffix too, which reaches the same leaf with a different operator.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#692: Q on an aggregate alias renders in HAVING" begin
  for (backend, Model_) in _Q_AGG_MODELS
    @testset "$backend" begin
      for (label, wrapped, bare) in (("equality", Q("n" => 11), "n" => 11),
                                     ("lookup suffix", Q("n__@gt" => 12), "n__@gt" => 12))
        q = _q_agg_query(Model_); q.filter(wrapped)
        insp = inspect_query(q)
        sql = insp[:sql_text]
        @test !occursin("WHERE", sql)
        having_sql = _clause(sql, "HAVING")
        assert_marker_count(insp, backend)
        # A one-term Q renders the unwrapped key's predicate inside the Q's parentheses, and binds
        # the same value.
        ref = _q_agg_query(Model_); ref.filter(bare)
        ref_insp = inspect_query(ref)
        @test having_sql == "(" * _clause(ref_insp[:sql_text], "HAVING") * ")"
        @test occursin(r"^\(COUNT\(\"Tb\"\.\"resultid\"\) [>=] ", having_sql)
        @test insp[:parameters] == ref_insp[:parameters]
      end
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# Qor across aggregate aliases: one HAVING disjunction
# This is the spelling routing buys: top-level keys only ever AND together, so before #692 there was
# no way to say "at least 20 results OR at least 100 points" on a grouped query. Both terms render in
# HAVING inside one parenthesised OR, and SQLite binds them in text order.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#692: Qor across aggregate aliases renders one HAVING OR" begin
  for (backend, Model_) in _Q_AGG_MODELS
    @testset "$backend" begin
      q = _q_agg_query(Model_); q.filter(Qor("n__@gte" => 21, "total__@gte" => 22.5))
      insp = inspect_query(q)
      sql = insp[:sql_text]
      @test !occursin("WHERE", sql)
      @test occursin(r"HAVING \(COUNT\(\"Tb\"\.\"resultid\"\) >= \S+ OR SUM\(\"Tb\"\.\"points\"\) >= \S+\)", sql)
      assert_marker_count(insp, backend)
      backend === :sqlite && assert_bound_in_text_order(insp, Any[21, 22.5])
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# Mixed Q: the AND splits between WHERE and HAVING
# `Q("n" => 31, "raceid" => 32)` means what the top-level `filter("n" => 31, "raceid" => 32)` means:
# the column term filters rows before grouping (WHERE), the aggregate term filters groups (HAVING).
# The values cross buckets, so the SQLite vector must follow the TEXT: the WHERE value first even
# though it was written second. PostgreSQL numbers them in the same order.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#692: a mixed Q splits between WHERE and HAVING" begin
  for (backend, Model_) in _Q_AGG_MODELS
    @testset "$backend" begin
      q = _q_agg_query(Model_); q.filter(Q("n" => 31, "raceid" => 32))
      insp = inspect_query(q)
      sql = insp[:sql_text]
      where_sql, having_sql = _clause(sql, "WHERE"), _clause(sql, "HAVING")
      @test where_sql !== nothing && occursin("\"Tb\".\"raceid\" = ", where_sql)
      @test !occursin("COUNT", where_sql)
      @test having_sql !== nothing && occursin("COUNT(\"Tb\".\"resultid\") = ", having_sql)
      @test !occursin("raceid", having_sql)
      assert_marker_count(insp, backend)
      if backend === :sqlite
        assert_bound_in_text_order(insp, Any[32, 31])
      else
        @test occursin("\$1", where_sql) && occursin("\$2", having_sql)
      end
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# Nested split: a column term AND a Qor of aggregate aliases
# The AND splits at the top; the Qor, being all-aggregate, moves to HAVING whole. A later top-level
# column filter must still bind under WHERE — the HAVING render restores the bucket context — so on
# SQLite the three WHERE-side values precede the two HAVING-side ones in text order.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#692: a nested Q splits at the AND and keeps the OR whole" begin
  for (backend, Model_) in _Q_AGG_MODELS
    @testset "$backend" begin
      q = _q_agg_query(Model_)
      q.filter(Q("raceid__@gt" => 41, Qor("n" => 42, "total__@lt" => 43.5)))
      q.filter("resultid__@gte" => 44)
      insp = inspect_query(q)
      sql = insp[:sql_text]
      where_sql, having_sql = _clause(sql, "WHERE"), _clause(sql, "HAVING")
      @test occursin("\"Tb\".\"raceid\" > ", where_sql)
      @test occursin("\"Tb\".\"resultid\" >= ", where_sql)
      @test !occursin(r"COUNT|SUM", where_sql)
      @test occursin(r"^\(COUNT\(\"Tb\"\.\"resultid\"\) = \S+ OR SUM\(\"Tb\"\.\"points\"\) < \S+\)$", having_sql)
      assert_marker_count(insp, backend)
      backend === :sqlite && assert_bound_in_text_order(insp, Any[41, 44, 42, 43.5])
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# A binding projection inside a mixed Q
# `Count(Case([When(…)]))` carries its own values, so the HAVING copy renders afresh and binds them
# a second time (#595) — now from inside a split Q, beside a WHERE term and a later top-level filter.
# SQLite's vector must still follow the text: SELECT's two, the WHERE pair, then HAVING's three.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#692: a binding aggregate projection inside a mixed Q binds in text order" begin
  for (backend, Model_) in _Q_AGG_MODELS
    @testset "$backend" begin
      q = Model_.objects
      q.values("raceid", "late" => Count(Case([When("raceid__@gt" => 91, then = 92)])))
      q.filter(Q("late__@gt" => 93, "raceid" => 94))
      q.filter("resultid__@gte" => 95)
      insp = inspect_query(q)
      sql = insp[:sql_text]
      having_sql = _clause(sql, "HAVING")
      @test having_sql !== nothing && occursin("CASE", having_sql)
      @test !occursin("CASE", _clause(sql, "WHERE"))
      assert_marker_count(insp, backend)
      backend === :sqlite && assert_bound_in_text_order(insp, Any[91, 92, 94, 95, 91, 92, 93])
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# Aggregate arithmetic alias inside Q
# `Sum(…) / Count(…)` is an FExpression whose aggregate flag propagates from its operands; the
# routing reads that flag, so an arithmetic alias goes to HAVING like a bare aggregate.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#692: an aggregate-arithmetic alias inside Q renders in HAVING" begin
  for (backend, Model_) in _Q_AGG_MODELS
    @testset "$backend" begin
      q = Model_.objects
      q.values("raceid", "avg_pts" => Sum("points") / Count("resultid"))
      q.filter(Q("avg_pts__@gt" => 51.5))
      insp = inspect_query(q)
      sql = insp[:sql_text]
      @test !occursin("WHERE", sql)
      having_sql = _clause(sql, "HAVING")
      @test having_sql !== nothing && occursin("SUM(", having_sql) && occursin("COUNT(", having_sql)
      assert_marker_count(insp, backend)
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# Mixed Qor: refused at build time, and the advised spelling works
# An OR cannot be split between WHERE and HAVING, so `Qor(aggregate alias, column)` is a
# `QueryBuildError` naming the alias — not the driver error it was. The message's advice (project the
# grouped column as an aggregate alias too) is executed here, so it cannot name a route that raises.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#692: a mixed Qor is refused, and its advice renders" begin
  for (backend, Model_) in _Q_AGG_MODELS
    @testset "$backend — refused" begin
      for f in (Qor("n" => 61, "raceid" => 62), Qor("raceid" => 62, Q("n" => 61)))
        q = _q_agg_query(Model_); q.filter(f)
        err = try inspect_query(q); nothing catch e; e end
        @test err isa PormG.QueryBuildError
        msg = err === nothing ? "" : PormG.error_message(err)
        @test occursin("\"n\"", msg) && occursin("Qor", msg) && occursin("#692", msg)
      end
    end
    @testset "$backend — advice" begin
      q = Model_.objects
      q.values("raceid", "n" => Count("resultid"), "race" => Max("raceid"))
      q.filter(Qor("n" => 20, "race" => 1))
      sql = inspect_query(q)[:sql_text]
      @test !occursin("WHERE", sql)
      @test occursin(r"HAVING \(COUNT\(\"Tb\"\.\"resultid\"\) = \S+ OR MAX\(\"Tb\"\.\"raceid\"\) = \S+\)", sql)
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# Controls: no aggregate-alias term, no change
# A Q of plain columns, and a Q on a NON-aggregate alias, rendered correctly in WHERE before #692 and
# must render the same way now. The split hands back the original object when one side takes all of
# it, so the text is the pre-#692 text: one parenthesised WHERE group.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#692 controls: Q without an aggregate alias stays in WHERE" begin
  for (backend, Model_) in _Q_AGG_MODELS
    @testset "$backend — plain columns on a grouped query" begin
      q = _q_agg_query(Model_); q.filter(Q("raceid" => 71, "points__@gt" => 72.0))
      sql = inspect_query(q)[:sql_text]
      @test occursin(r"WHERE \(\"Tb\"\.\"raceid\" = \S+ AND \"Tb\"\.\"points\" > \S+\)", sql)
      @test !occursin("HAVING", sql)
    end
    @testset "$backend — a non-aggregate expression alias" begin
      # `F("raceid") + 1` is an alias with no aggregate in it: a row value, so WHERE is right.
      q = Model_.objects
      q.values("resultid", "next_race" => F("raceid") + 1)
      q.filter(Q("next_race" => 73))
      sql = inspect_query(q)[:sql_text]
      @test occursin(r"WHERE \(\(\"Tb\"\.\"raceid\" \+ \S+\) = \S+\)", sql)
      @test !occursin("HAVING", sql)
    end
  end
end
