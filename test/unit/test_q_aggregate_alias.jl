using Test
using PormG
using PormG.Models: Model, IDField, IntegerField, FloatField, CharField
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
# A window function (#701's guard case) asks the backend for its version; answer like the other mocks.
PormG.backend_sqlite_version(::QAggMockSQLite) = 3045000

PormG.config["q_agg_pg"] = PormG.Configuration.Settings(connections = QAggMockPostgres(), change_data = true)
PormG.config["q_agg_sl"] = PormG.Configuration.Settings(connections = QAggMockSQLite(), change_data = true)

QAggPgResult = Model("q_agg_results", resultid = IDField(), raceid = IntegerField(), points = FloatField(),
                     surname = CharField())
QAggPgResult.connect_key = "q_agg_pg"
QAggSlResult = Model("q_agg_results", resultid = IDField(), raceid = IntegerField(), points = FloatField(),
                     surname = CharField())
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
      insp = inspect_query(q)
      sql = insp[:sql_text]
      @test occursin(r"WHERE \(\(\"Tb\"\.\"raceid\" \+ \S+\) = \S+\)", sql)
      @test !occursin("HAVING", sql)
      # #701: the WHERE copy reprinted the projection's `?` with its value still in `:select` —
      # three markers, two values on SQLite, while the text assertion above passed regardless. The
      # copy now binds its own `1`, in text order.
      assert_marker_count(insp, backend)
      backend === :sqlite && assert_bound_in_text_order(insp, Any[1, 1, 73])
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# #701: a top-level filter on a row-level alias renders in WHERE
# `values("resultid", "next_race" => F("raceid") + 1); filter("next_race" => 73)` printed
# `HAVING ("Tb"."raceid" + ?) = ?` on a query with no GROUP BY — rejected by both engines. A row
# alias belongs in WHERE, exactly as the `Q(...)` spelling already rendered it; the two spellings
# must now print the same predicate and bind the same values. The projection's `1` binds again for
# the WHERE copy, in text order.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#701: a row-level alias filters in WHERE, not HAVING" begin
  for (backend, Model_) in _Q_AGG_MODELS
    @testset "$backend" begin
      q = Model_.objects
      q.values("resultid", "next_race" => F("raceid") + 1)
      q.filter("next_race" => 73)
      insp = inspect_query(q)
      sql = insp[:sql_text]
      @test !occursin("HAVING", sql)
      @test !occursin("GROUP BY", sql)
      @test _clause(sql, "WHERE") !== nothing
      @test occursin(r"^\(\"Tb\"\.\"raceid\" \+ \S+\) = \S+$", _clause(sql, "WHERE"))
      assert_marker_count(insp, backend)
      # SELECT's `1`, the WHERE copy's own `1`, then the comparison value.
      backend === :sqlite && assert_bound_in_text_order(insp, Any[1, 1, 73])

      # The `Q` spelling renders the same predicate, parenthesised, with the same values.
      qq = Model_.objects
      qq.values("resultid", "next_race" => F("raceid") + 1)
      qq.filter(Q("next_race" => 73))
      q_insp = inspect_query(qq)
      @test _clause(q_insp[:sql_text], "WHERE") == "(" * _clause(sql, "WHERE") * ")"
      @test q_insp[:parameters] == insp[:parameters]
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# #701: a row alias on a grouped query still filters rows
# Beside an aggregate the query has a GROUP BY, and a row alias over a grouped column rendered in
# HAVING did execute. It now filters the rows in WHERE — the same groups survive, since the value
# is constant within each group — while the aggregate alias in the same call stays in HAVING.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#701: a row alias beside an aggregate alias splits WHERE / HAVING" begin
  for (backend, Model_) in _Q_AGG_MODELS
    @testset "$backend" begin
      q = Model_.objects
      q.values("raceid", "n" => Count("resultid"), "next_race" => F("raceid") + 1)
      q.filter("next_race" => 73, "n__@gt" => 5)
      insp = inspect_query(q)
      sql = insp[:sql_text]
      @test occursin(r"^\(\"Tb\"\.\"raceid\" \+ \S+\) = \S+$", _clause(sql, "WHERE"))
      @test occursin(r"^COUNT\(\"Tb\"\.\"resultid\"\) > \S+$", _clause(sql, "HAVING"))
      assert_marker_count(insp, backend)
      # SELECT's `1`, WHERE's own `1` and `73`, then HAVING's `5`.
      backend === :sqlite && assert_bound_in_text_order(insp, Any[1, 1, 73, 5])
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# #701: only the clause moves — the alias's value is still typed from its projection
# A top-level alias filter renders through `_render_alias_predicate` in either clause, because that
# is where the value is checked against the projection's type (#576). Rendering a row alias through
# the untyped WHERE path instead would have bound a wrong-typed value as given, silently, in a
# statement that — unlike the old HAVING one — now executes. So a float alias refuses text, naming
# the alias, and still accepts a number, in WHERE.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#701: a row alias's value is still typed from its projection" begin
  for (backend, Model_) in _Q_AGG_MODELS
    @testset "$backend" begin
      bad = Model_.objects
      bad.values("resultid", "pts" => F("points"))
      bad.filter("pts" => "not-a-number")
      err = @test_throws PormG.FilterError inspect_query(bad)
      @test occursin("projection alias", err.value.msg)

      ok = Model_.objects
      ok.values("resultid", "pts" => F("points"))
      ok.filter("pts__@gte" => 10.5)
      sql = inspect_query(ok)[:sql_text]
      @test occursin(r"^\"Tb\"\.\"points\" >= \S+$", _clause(sql, "WHERE"))
      @test !occursin("HAVING", sql)
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# #701: the top-level alias guards still refuse in the WHERE route
# The window refusal (#685) and the byte-payload refusal (#596) ran at the top of the old HAVING
# branch. Routing a row alias to WHERE must not drop them: a window cannot be filtered in the query
# that computes it, and a byte payload against a non-binary alias matches nothing.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#701: the alias guards still apply to a row alias" begin
  for (backend, Model_) in _Q_AGG_MODELS
    @testset "$backend" begin
      # #596: a byte payload against a non-binary alias — refused by the bytes guard itself, not by
      # the value formatter (which would also raise a FilterError, with a different message).
      q = Model_.objects
      q.values("resultid", "next_race" => F("raceid") + 1)
      q.filter("next_race" => UInt8[0x01, 0x02])
      err = @test_throws PormG.FilterError inspect_query(q)
      @test occursin("vector value but no operator", err.value.msg)
      # #685: a window is a row value too (`_is_agg` is false for it), so it takes the new WHERE
      # route — and is refused there exactly as it was in HAVING.
      w = Model_.objects
      w.values("resultid", "rk" => PormG.Functions.Rank())
      w.filter("rk" => 1)
      werr = @test_throws PormG.QueryBuildError inspect_query(w)
      @test occursin("#685", werr.value.msg)
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# #701: the cross-backend differential agrees on every alias spelling
# The oracle for parameter order (querybuilder skill → *Parameter routing*): PostgreSQL numbers `$N`
# as it binds, so walking the markers left to right through its vector gives the true text order,
# and SQLite's flattened vector must equal it. Covers the top-level row alias, its `Q` twin, the
# grouped split, and a SELECT-side `When` on a binding alias — the other reader of the memo the
# WHERE copy used to reprint, which bound one value short in the SELECT list the same way.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#701: PostgreSQL and SQLite bind every alias spelling in text order" begin
  shapes = (
    ("top-level", q -> (q.values("resultid", "next_race" => F("raceid") + 1); q.filter("next_race" => 73))),
    ("Q",         q -> (q.values("resultid", "next_race" => F("raceid") + 1); q.filter(Q("next_race" => 73)))),
    ("grouped",   q -> (q.values("raceid", "n" => Count("resultid"), "next_race" => F("raceid") + 1);
                        q.filter("next_race" => 73, "n__@gt" => 5))),
    ("SELECT-side When", q -> q.values("resultid", "x" => F("points") * 2,
                                       "flag" => Case([When("x" => 4, then = 1)], default = 0))),
  )
  for (label, build!) in shapes
    @testset "$label" begin
      pg = (q = QAggPgResult.objects; build!(q); inspect_query(q))
      sl = (q = QAggSlResult.objects; build!(q); inspect_query(q))
      idx = [parse(Int, m.match[2:end]) for m in eachmatch(r"\$\d+", pg[:sql_text])]
      @test sl[:parameters] == [pg[:parameters][i] for i in idx]
      assert_marker_count(sl, :sqlite)
    end
  end
end
