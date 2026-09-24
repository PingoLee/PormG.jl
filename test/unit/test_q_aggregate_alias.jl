using Test
using Dates
using PormG
using PormG.Models: Model, IDField, IntegerField, FloatField, CharField, DateField
using PormG.QueryBuilder: inspect_query, Count, Sum, Max
using PormG.Functions: Case, When, Value, Upper

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
                     surname = CharField(), race_date = DateField())
QAggPgResult.connect_key = "q_agg_pg"
QAggSlResult = Model("q_agg_results", resultid = IDField(), raceid = IntegerField(), points = FloatField(),
                     surname = CharField(), race_date = DateField())
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

# ─────────────────────────────────────────────────────────────────────────────
# #703: a filter key naming a model field AND a projection alias is refused
# `values("raceid", "points" => Sum("points")); filter("points" => 1.0)` rendered
# `WHERE SUM("Tb"."points") = ?` — neither the column nor the projection. The key has two meanings, so
# it raises `AmbiguousFieldError` (the #492 precedent), on every spelling that reaches the leaf:
# top-level and inside `Q`/`Qor`, bare and with a lookup suffix, over an aggregate, a row
# expression, a window and a literal alike. The message names both readings and the rename.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#703: a key naming a field and an alias raises AmbiguousFieldError" begin
  projections = (("an aggregate", Sum("points")),
                 ("a row expression", F("points") * 2),
                 ("a literal", Value(0.0)),
                 # A DIFFERENT column under the field's name. This one used to resolve to the field —
                 # the path projection is memoized under its own path, so nothing shadowed the key —
                 # but the key still has two meanings, and the upgrade entry records the change.
                 ("another column", "raceid"))
  predicates = (("top-level", "points" => 1.0),
                ("a lookup suffix", "points__@gt" => 1.0),
                ("Q", Q("points" => 1.0)),
                ("Qor", Qor("raceid" => 1, "points" => 1.0)))
  for (backend, Model_) in _Q_AGG_MODELS
    for (plabel, projection) in projections, (flabel, pred) in predicates
      @testset "$backend — $plabel, $flabel" begin
        q = Model_.objects
        q.values("raceid", "points" => projection)
        q.filter(pred)
        err = @test_throws AmbiguousFieldError inspect_query(q)
        msg = err.value.msg
        # Both readings are named, and the rename that resolves it.
        @test occursin("points", msg)
        @test occursin("projection alias", msg)
        @test occursin("points_value", msg)
        @test occursin("#703", msg)
      end
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# #703 controls: what is NOT ambiguous still renders
# A projection that IS the column — `values("points")`, `values("points" => "points")`,
# `values("points" => F("points"))` — gives the key one meaning, so the filter renders against the
# column as it always did. A transform key names the field's transform, not the alias. The
# declaration itself is never refused: `values("points" => Sum("points"))` with no filter on the
# name renders unchanged — the shape consuming apps use.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#703 controls: an unambiguous key still renders" begin
  for (backend, Model_) in _Q_AGG_MODELS
    @testset "$backend — the column projected under its own name" begin
      for projection in ("points", "points" => "points", "points" => F("points"))
        q = Model_.objects
        q.values("resultid", projection)
        q.filter("points" => 1.0)
        sql = inspect_query(q)[:sql_text]
        @test occursin(r"WHERE \"Tb\"\.\"points\" = ", sql)
      end
    end
    @testset "$backend — the colliding alias with no filter on its name" begin
      q = Model_.objects
      q.values("raceid", "points" => Sum("points"))
      q.filter("raceid" => 1)
      sql = inspect_query(q)[:sql_text]
      @test occursin("SUM(\"Tb\".\"points\") as \"points\"", sql)
      @test occursin(r"WHERE \"Tb\"\.\"raceid\" = ", sql)
    end
    @testset "$backend — a transform key names the field's transform, not the alias" begin
      q = Model_.objects
      q.values("raceid", "race_date" => Max("race_date"))
      q.filter("race_date__@year" => 2009)
      sql = inspect_query(q)[:sql_text]
      # The year rewrite lands on the column in WHERE; the alias's MAX stays in SELECT.
      @test occursin("\"Tb\".\"race_date\"", _clause(sql, "WHERE"))
      @test !occursin("MAX", _clause(sql, "WHERE"))
    end
    @testset "$backend — a renamed alias filters in HAVING, the field in WHERE" begin
      q = Model_.objects
      q.values("raceid", "points_value" => Sum("points"))
      q.filter("points_value__@gt" => 10.0, "points__@gt" => 0.0)
      sql = inspect_query(q)[:sql_text]
      @test occursin(r"WHERE \"Tb\"\.\"points\" > ", sql)
      @test occursin(r"HAVING SUM\(\"Tb\"\.\"points\"\) > ", sql)
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# #703 fixtures for a `__` path: a registered driver/result pair, so `driverid__surname` resolves
# through the foreign key the way a model path does.
# ─────────────────────────────────────────────────────────────────────────────
struct QAggPathMockSQLite <: PormG.PormGSQLite end
PormG.backend_sqlite_version(::QAggPathMockSQLite) = 3045000
PormG.config["q_agg_path_sl"] = PormG.Configuration.Settings(connections = QAggPathMockSQLite(),
                                                             change_data = true,
                                                             db_def_folder = "q_agg_path_sl")

module QAggPath
import PormG, PormG.Models
Driver = Models.Model("q_agg_path_driver", driverid = Models.IDField(), forename = Models.CharField(),
                      surname = Models.CharField())
Result = Models.Model("q_agg_path_result", resultid = Models.IDField(), points = Models.FloatField(),
                      driverid = Models.ForeignKey(Driver, pk_field = "driverid", on_delete = "CASCADE"))
PormG.Models.set_models(@__MODULE__, "q_agg_path_sl")
end

# ─────────────────────────────────────────────────────────────────────────────
# #703: a `__` path naming a relation's column is a model name too
# `values("driverid__surname" => Upper("driverid__forename")); filter("driverid__surname" => …)`
# read the alias through the projection memo — silently, since the text binds nothing — although the
# key names the related column exactly as `"points"` names a local one. It is refused like a field
# key. A path projection of the SAME path is the column and is not refused; a `__` alias whose first
# segment is on no relation is an alias only, and is not this guard's business.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#703: a `__` path naming a related column and an alias is ambiguous" begin
  for pred in ("driverid__surname" => "SENNA", Q("driverid__surname" => "SENNA"),
               "driverid__surname__@startswith" => "SEN")
    q = QAggPath.Result.objects
    q.values("resultid", "driverid__surname" => Upper("driverid__forename"))
    q.filter(pred)
    err = @test_throws AmbiguousFieldError inspect_query(q)
    @test occursin("driverid__surname", err.value.msg)
    @test occursin("#703", err.value.msg)
  end

  # The path projected under its own name is the column: the filter renders against it.
  q = QAggPath.Result.objects
  q.values("resultid", "driverid__surname")
  q.filter("driverid__surname" => "Senna")
  sql = inspect_query(q)[:sql_text]
  @test occursin(r"WHERE \"Tb_1\"\.\"surname\" = ", sql)
end

# ─────────────────────────────────────────────────────────────────────────────
# #706: a condition inside a projection on a field-and-alias key raises AmbiguousFieldError
# `values("f" => Case([When("points" => 4, then = 1)]), "points" => Sum("points"))` resolved the
# condition by declaration order: `When` first rendered the column and then silently REPLACED the
# SUM projection with it; SUM first made the condition compare the SUM. #703's refusal, for the
# SELECT side: both orders raise, whether the condition is a `When` pair or a `Q` in a `Case`, and
# whatever the colliding projection is. The message names the projection holding the condition.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#706: a SELECT-side condition naming a field and an alias raises" begin
  conditions = (("a When pair", Case([When("points" => 4.0, then = 1)], default = 0)),
                ("a Q in a Case", Case([When(Q("points" => 4.0), then = 1)], default = 0)),
                ("a lookup suffix", Case([When("points__@gt" => 4.0, then = 1)], default = 0)),
                ("a Qor in a Case", Case([When(Qor("raceid" => 1, "points" => 4.0), then = 1)], default = 0)),
                # A window's PARTITION BY resolves through the same memo (found in review).
                ("a Case in a window's partition_by",
                 PormG.Functions.Rank(over = PormG.Functions.WindowOver(
                     partition_by = [Case([When("points" => 4.0, then = 1)], default = 0)]))),
                # An explicit `SQLField(…)` wrap, in a function operand and in a window's ORDER BY
                # (found in the delta review).
                ("an SQLField-wrapped Case in a function",
                 PormG.Functions.Coalesce(PormG.QueryBuilder.SQLField(
                     Case([When("points" => 4.0, then = 1)], default = 0), "k"), 0)),
                ("an SQLField-wrapped Case in a window's order_by",
                 PormG.Functions.Rank(over = PormG.Functions.WindowOver(
                     order_by = [PormG.QueryBuilder.SQLOrder(PormG.QueryBuilder.SQLField(
                         Case([When("points" => 4.0, then = 1)], default = 0), "k"))]))))
  projections = (("an aggregate", Sum("points")), ("a row expression", F("points") * 2),
                 ("another column", "raceid"))
  for (backend, Model_) in _Q_AGG_MODELS
    for (clabel, condition) in conditions, (plabel, projection) in projections
      # Both declaration orders: the defect was that each order got a different answer.
      for (olabel, pairs) in (("condition first", ("f" => condition, "points" => projection)),
                              ("alias first", ("points" => projection, "f" => condition)))
        @testset "$backend — $clabel, $plabel, $olabel" begin
          q = Model_.objects
          q.values("resultid", pairs...)
          err = @test_throws AmbiguousFieldError inspect_query(q)
          msg = err.value.msg
          # The projection holding the condition, both readings, and the rename.
          @test occursin("values(\"f\" => …)", msg)
          @test occursin("projection alias", msg)
          @test occursin("points_value", msg)
          @test occursin("#706", msg)
        end
      end
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# #706 controls: a condition with one meaning still renders
# A projection that names ITSELF in its own condition (`"points" => Case([When("points" => …)])`)
# means the column there — no SQL reads an alias inside the expression that defines it. A
# projection that IS the column gives the key one meaning. A condition on a key that names no
# field is a plain alias read, legal in a SELECT (the #685 note), and reads the projection.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#706 controls: an unambiguous condition still renders" begin
  for (backend, Model_) in _Q_AGG_MODELS
    @testset "$backend — a projection naming itself in its own condition" begin
      q = Model_.objects
      q.values("raceid", "points" => Case([When("points" => 4.0, then = 1)], default = 0))
      insp = inspect_query(q)
      @test occursin(r"CASE\s+WHEN \"Tb\"\.\"points\" = ", insp[:sql_text])
      assert_marker_count(insp, backend)
    end
    @testset "$backend — the column projected under its own name" begin
      for projection in ("points", "points" => "points", "points" => F("points"))
        q = Model_.objects
        q.values("raceid", "f" => Case([When("points" => 4.0, then = 1)], default = 0), projection)
        sql = inspect_query(q)[:sql_text]
        @test occursin(r"WHEN \"Tb\"\.\"points\" = ", sql)
        @test occursin("\"Tb\".\"points\" as \"points\"", sql)
      end
    end
    @testset "$backend — a condition on an alias-only key reads the projection" begin
      q = Model_.objects
      q.values("raceid", "doubled" => F("points") * 2, "f" => Case([When("doubled" => 4.0, then = 1)], default = 0))
      insp = inspect_query(q)
      @test occursin(r"WHEN \(\"Tb\"\.\"points\" \* [?$]", insp[:sql_text])
      assert_marker_count(insp, backend)
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# #707: a text function alias types as text, on both spellings
# `_having_alias_formatter` knew only aggregates, the `PormGTypeField` functions and a bare `F`, and
# guessed "number" for everything else — so `filter("nm" => "hamilton")` over `Lower("surname")` was
# refused, while `filter(Q("nm" => "hamilton"))` rendered. Both spellings now render the same WHERE
# predicate and bind the same value, and a text alias refuses nothing a text column would accept.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#707: a text function alias types as text on both spellings" begin
  text_projections = (("Lower", PormG.Functions.Lower("surname")),
                      ("Upper", Upper("surname")),
                      ("Trim", PormG.Functions.Trim("surname")),
                      ("Replace", PormG.Functions.Replace("surname", "a", "b")),
                      ("Concat", PormG.Functions.Concat(["surname", Value("-")])),
                      ("Coalesce over a text column", PormG.Functions.Coalesce("surname", Value("?"))))
  for (backend, Model_) in _Q_AGG_MODELS, (plabel, projection) in text_projections
    @testset "$backend — $plabel" begin
      rendered = map(("top-level" => "nm" => "hamilton", "Q" => Q("nm" => "hamilton"))) do (_, pred)
        q = Model_.objects
        q.values("resultid", "nm" => projection)
        q.filter(pred)
        insp = inspect_query(q)
        assert_marker_count(insp, backend)
        # A row alias: WHERE, never HAVING, with the term bound as given.
        @test _clause(insp[:sql_text], "HAVING") === nothing
        @test last(insp[:parameters]) == "hamilton"
        insp
      end
      # One rule: the two spellings bind the same vector.
      @test rendered[1][:parameters] == rendered[2][:parameters]
      # Typed AS TEXT, not merely unrefused: a number compared with a text alias is formatted as
      # text, which is what makes `LOWER(…) = $1` executable on PostgreSQL (it has no `text = integer`
      # operator). SQLite keeps native numbers by design (`_sqlite_preserve_native_parameter`).
      for pred in ("nm" => 5, Q("nm" => 5))
        q = Model_.objects
        q.values("resultid", "nm" => projection)
        q.filter(pred)
        @test last(inspect_query(q)[:parameters]) == (backend === :postgres ? "5" : 5)
      end
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# #707: a Q alias leaf is typed and guarded like the top-level spelling
# A row-alias leaf inside `Q`/`Qor` rendered through the WHERE path, which has no field to type the
# value against: `Q("pts" => "not-a-number")` over `F("points")` bound the string unchecked, and the
# #596 bytes guard and #618 JSON-operator refusal never ran. It now renders through the same
# `_render_alias_predicate` the top-level key does, so each case raises the SAME error either way.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#707: a Q alias leaf is typed and guarded like the top-level key" begin
  cases = (("a wrong-typed value", "pts" => "not-a-number", PormG.FilterError, "projection alias"),
           ("a byte payload (#596)", "pts" => UInt8[0x01, 0x02], PormG.FilterError, "vector value but no operator"),
           ("a JSON operator (#618)", "pts__@has_key" => "a", PormG.FilterError, "@has_key"))
  for (backend, Model_) in _Q_AGG_MODELS, (clabel, pair, errtype, needle) in cases
    @testset "$backend — $clabel" begin
      messages = map((pair, Q(pair), Qor("raceid" => 1, pair))) do pred
        q = Model_.objects
        q.values("resultid", "raceid", "pts" => F("points"))
        q.filter(pred)
        err = @test_throws errtype inspect_query(q)
        @test occursin(needle, err.value.msg)
        err.value.msg
      end
      @test allequal(messages)
    end
  end
  # Control, not a regression: a well-typed date already bound the column's representation on
  # both spellings, and must keep doing so now that `Q` takes the typed renderer.
  for (backend, Model_) in _Q_AGG_MODELS
    params = map(("d" => Date(2009, 3, 29), Q("d" => Date(2009, 3, 29)))) do pred
      q = Model_.objects
      q.values("resultid", "d" => F("race_date"))
      q.filter(pred)
      inspect_query(q)[:parameters]
    end
    @test params[1] == params[2] == Any["2009-03-29"]
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# #707: a Value alias filters in WHERE, with its literal bound
# A `Value(...)` projection had no `_projected_source`, so its filter kept the HAVING route and
# reprinted the SELECT's memoized `?` with nothing behind it: `HAVING ? = ?`, three markers for two
# values on SQLite (and `WHERE (? = ?)` inside `Q`). The literal is now re-bound in the clause it
# prints in: `WHERE ? = ?`, three markers, three values, in text order on both engines.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#707: a Value alias filters in WHERE with its literal bound" begin
  for (backend, Model_) in _Q_AGG_MODELS, pred in ("v" => 7, Q("v" => 7))
    @testset "$backend — $(pred isa Pair ? "top-level" : "Q")" begin
      q = Model_.objects
      q.values("resultid", "v" => Value(5))
      q.filter(pred)
      insp = inspect_query(q)
      @test _clause(insp[:sql_text], "HAVING") === nothing
      @test _clause(insp[:sql_text], "WHERE") !== nothing
      assert_marker_count(insp, backend)
      # SELECT's literal, WHERE's re-bound literal, then the compared value.
      assert_bound_in_text_order(insp, Any[5, 5, 7])
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# #707: a declared type is used, and an unknown one is not guessed
# `Cast` and `output_field=` name the result type, so the alias is typed from it. A projection whose
# type cannot be named (a `Case` with no `output_field`) is no longer typed as a number by default:
# the guess refused a text `Case` outright. It binds the value as given — what the WHERE path does
# for any column-less expression.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#707: a declared alias type is used; an unknown one is not guessed" begin
  for (backend, Model_) in _Q_AGG_MODELS
    # A declared integer refuses a non-number, on both spellings — as the alias's type, not as
    # some other failure that happens to share the exception type.
    for pred in ("pi" => "abc", Q("pi" => "abc"))
      q = Model_.objects
      q.values("resultid", "pi" => PormG.Functions.Cast("points", IntegerField()))
      q.filter(pred)
      err = @test_throws PormG.FilterError inspect_query(q)
      @test occursin("projection alias", err.value.msg)
    end
    # A `Value` alias holds a literal, never a column: `Value("points")` is the text "points", so
    # it is not typed as the `points` column (a number) and a text value is not refused.
    q = Model_.objects
    q.values("resultid", "v" => Value("points"))
    q.filter(Q("v" => "abc"))
    insp = inspect_query(q)
    assert_bound_in_text_order(insp, Any["points", "points", "abc"])
    # A declared text type accepts text.
    q = Model_.objects
    q.values("resultid", "lbl" => Case([When("points__@gte" => 15.0, then = "podium")], default = "other",
                                       output_field = CharField()))
    q.filter("lbl" => "podium")
    @test last(inspect_query(q)[:parameters]) == "podium"
    # No declared type: a text value is not refused as "not a number".
    q = Model_.objects
    q.values("resultid", "lbl" => Case([When("points__@gte" => 15.0, then = "podium")], default = "other"))
    q.filter(Q("lbl" => "podium"))
    insp = inspect_query(q)
    @test last(insp[:parameters]) == "podium"
    assert_marker_count(insp, backend)
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# #707: an expression on the right of an alias filter is a column comparison, not a value
# `Q("pts" => F("grid"))` over `F("points")` rendered `WHERE ("Tb"."points" = "Tb"."grid")` before
# #707, through the WHERE path. Routing every row-alias leaf to the typed renderer handed the `F`
# to a value formatter — a `MethodError`, or, over a `Case` alias, the node bound AS A PARAMETER.
# An expression right-hand side keeps the WHERE path on both spellings (found in the security pass;
# the top-level spelling had always died with the `MethodError`, and now agrees with `Q`).
# ─────────────────────────────────────────────────────────────────────────────
@testset "#707: an expression on the right of an alias filter renders as a comparison" begin
  cases = (("F alias = F column", "pts" => F("points"), "pts" => F("raceid"),
            "\"Tb\".\"points\" = \"Tb\".\"raceid\""),
           ("F alias > F column", "pts" => F("points"), "pts__@gt" => F("raceid"),
            "\"Tb\".\"points\" > \"Tb\".\"raceid\""),
           ("text alias = function", "nm" => PormG.Functions.Lower("surname"),
            "nm" => PormG.Functions.Lower("surname"), "LOWER(\"Tb\".\"surname\") = LOWER(\"Tb\".\"surname\")"),
           ("Case alias = F column", "c" => Case([When("raceid" => 1, then = 1)], default = 0),
            "c" => F("raceid"), "END = \"Tb\".\"raceid\""))
  for (backend, Model_) in _Q_AGG_MODELS, (label, projection, pair, needle) in cases
    for pred in (pair, Q(pair))
      @testset "$backend — $label, $(pred isa Pair ? "top-level" : "Q")" begin
        q = Model_.objects
        q.values("resultid", projection)
        q.filter(pred)
        insp = inspect_query(q)
        @test occursin(needle, replace(insp[:sql_text], r"\s+" => " "))
        # Nothing but real values is bound — never the expression node.
        @test !any(p -> p isa PormG.SQLType, insp[:parameters])
        assert_marker_count(insp, backend)
      end
    end
  end
end
