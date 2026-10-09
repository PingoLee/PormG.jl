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
      err = @test_throws PormG.InvalidValueError inspect_query(bad)
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
# key. A path projection of the SAME path is the column and is not refused.
#
# #757 then refused `__` in any alias at `values()`, so the aliased half now fails at declaration,
# before a filter can meet it. It used to assert #703's `AmbiguousFieldError` at build time.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#703: a `__` path naming a related column and an alias is ambiguous" begin
  q = QAggPath.Result.objects
  err = @test_throws QueryBuildError q.values("resultid", "driverid__surname" => Upper("driverid__forename"))
  @test occursin("#757", err.value.msg)

  # The path projected under its own name is the column: the filter renders against it.
  q = QAggPath.Result.objects
  q.values("resultid", "driverid__surname")
  q.filter("driverid__surname" => "Senna")
  sql = inspect_query(q)[:sql_text]
  @test occursin(r"WHERE \"Tb_1\"\.\"surname\" = ", sql)
end

# ─────────────────────────────────────────────────────────────────────────────
# #757: a projection alias cannot contain `__`
# Every alias router asks `_alias_filter_key`, which rejects a `__` key, while the render resolves it
# through the projection memo anyway. So `values("win__total" => Sum("points"))` then
# `filter("win__total__@gt" => 5)` printed `WHERE SUM(…) > ?`, a `When` reading it was grouped, and
# a window alias `"r__k"` escaped #685. The alias is refused where it is declared, whatever its right
# side. The same check runs for `aggregate()`, which projects through `values()`.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#757: a projection alias spelled with `__` is refused at values()" begin
  QB = PormG.QueryBuilder
  rank = () -> QB.Rank(over = QB.WindowOver(order_by = ["resultid"]))
  for (label, entry) in (
      ("aggregate", "win__total" => Sum("points")),
      ("F expression", "win__total" => QB.F("points") * 2),
      ("Value", "win__total" => Value(5)),
      ("field path", "win__total" => "points"),
      ("relation path", "win__total" => "driverid__surname"),
      ("function over a path", "win__total" => Upper("driverid__forename")),
      ("window", "r__k" => rank()),
      ("Case reading a condition", "win__big" => Case([When("points__@gte" => 10, then = 1)], default = 0)),
      ("explicit SQLField wrap", QB.SQLField(Sum("points"), "win__total")),
      # A path field is exempt only under its own name; any other `__` name is an alias.
      ("SQLField renaming a column", QB.SQLField("points", "win__total")),
      ("SQLField renaming a relation path", QB.SQLField("driverid__forename", "driverid__surname")),
    )
    @testset "$label" begin
      q = QAggPath.Result.objects
      err = @test_throws QueryBuildError q.values("resultid", entry)
      msg = err.value.msg
      @test occursin("#757", msg)
      # Names the caller's alias and a spelling that works.
      alias = entry isa Pair ? entry.first : entry._as
      @test occursin("\"$(alias)\"", msg)
      @test occursin("\"$(replace(alias, "__" => "_"))\"", msg)
    end
  end

  @testset "aggregate()" begin
    err = @test_throws QueryBuildError QAggPath.Result.objects.aggregate("win__total" => Sum("points"))
    @test occursin("#757", err.value.msg)
  end

  # Not aliases: a bare path projects under PormG's own spelling, a path may sit on the right, and
  # an explicit SQLField over a path carries that path as its name.
  @testset "paths are not aliases" begin
    q = QAggPath.Result.objects
    q.values("resultid", "driverid__surname", "who" => "driverid__forename",
             QB.SQLField("driverid__forename", "driverid__forename"))
    sql = inspect_query(q)[:sql_text]
    @test occursin("as \"driverid__surname\"", sql)
    @test occursin("as \"who\"", sql)
    @test occursin("as \"driverid__forename\"", sql)
  end

  # The rename the refusal suggests is the documented route: the alias filters groups in HAVING.
  @testset "the renamed alias routes to HAVING" begin
    q = QAggPath.Result.objects
    q.values("driverid", "win_total" => Sum("points"))
    q.filter("win_total__@gt" => 5)
    sql = inspect_query(q)[:sql_text]
    @test occursin(r"HAVING SUM\(", sql)
    @test !occursin("WHERE", sql)
  end
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
# #777 fixtures: names PormG generates can still spell `__`
# #757 refuses a `__` alias the caller CHOOSES, but a name PormG generates is exempt by design: a
# transform is named `<path>__<transform>`, and a CTE or `cjoin_on` copy may be named after a model
# field (#492, #484). The race has a `year` so `raceid__@year` collides with the real path
# `raceid__year`, and the result a `race_date` so `race_date__@year` collides with a CTE or joined
# copy named `race_date`. One mock per backend; `inspect_query(…; connection = …)` picks the dialect.
# ─────────────────────────────────────────────────────────────────────────────
struct QAggTxMockSQLite <: PormG.PormGSQLite end
struct QAggTxMockPostgres <: PormG.PormGPostgres end
PormG.backend_sqlite_version(::QAggTxMockSQLite) = 3045000
PormG.config["q_agg_tx_sl"] = PormG.Configuration.Settings(connections = QAggTxMockSQLite(),
                                                           change_data = true,
                                                           db_def_folder = "q_agg_tx_sl")

module QAggTx
import PormG, PormG.Models
# The relation targets the race's DATE (a unique key), not its integer id: since #1068 a date part
# over a relation reads the key it holds, and `raceid__@year` over an integer key is refused. Keyed by
# a date, the spelling these tests use as their vehicle stays legal, and still collides as before.
Race = Models.Model("q_agg_tx_race", raceid = Models.IDField(), year = Models.IntegerField(),
                    date = Models.DateField(unique = true))
Result = Models.Model("q_agg_tx_result", resultid = Models.IDField(), points = Models.FloatField(),
                      race_date = Models.DateField(),
                      raceid = Models.ForeignKey(Race, pk_field = "date", on_delete = "CASCADE"))
PormG.Models.set_models(@__MODULE__, "q_agg_tx_sl")
end

const _Q_AGG_TX_CONNS = ((:sqlite, QAggTxMockSQLite()), (:postgres, QAggTxMockPostgres()))
_q_agg_tx_msg(e) = replace(sprint(showerror, e), r"\e\[[0-9;]*m" => "")
# The WHERE clause, or a named join's line — the text a `Qor` leaf renders into.
_q_agg_tx_where(sql) = (m = match(r"WHERE(.*)"s, sql); m === nothing ? "" : m.captures[1])
_q_agg_tx_join(sql, alias) = (m = match(Regex("JOIN \"[^\"]+\" AS \"$(alias)\" ON ([^\\n]*?)(?:\\s+(?:INNER|LEFT) JOIN|\\s*WHERE|\\s*\\z)", "s"), sql);
                              m === nothing ? "" : m.captures[1])

# ─────────────────────────────────────────────────────────────────────────────
# #777: #703's path half is live — a transform on a foreign key spells a related path
# `values("raceid__@year")` is named `raceid__year`, which is also the path to the race's `year`.
# Without #703 the filter read the projection's memo entry and printed `EXTRACT(YEAR FROM raceid)`
# where the caller named the race's column, with no error at build time (SQLite runs it, too).
# (Since #1004 the memo entry is keyed `raceid__@year`, so the filter no longer reads it; the name
# still has two meanings, which is what this pins. The renamed transform is #1004's, below.)
# ─────────────────────────────────────────────────────────────────────────────
@testset "#777: a transform named like a related path refuses the filter (#703)" begin
  for (backend, conn) in _Q_AGG_TX_CONNS
    @testset "$backend" begin
      q = QAggTx.Result.objects
      q.values("resultid", "raceid__@year")
      q.filter("raceid__year" => 2009)
      err = @test_throws AmbiguousFieldError inspect_query(q; connection = conn)
      msg = _q_agg_tx_msg(err.value)
      @test occursin("filter(\"raceid__year\" => …)", msg)
      @test occursin("#703", msg)

      # Control: the path projected under its own name is the column, so the key has one meaning.
      q = QAggTx.Result.objects
      q.values("resultid", "raceid__year")
      q.filter("raceid__year" => 2009)
      where_text = _q_agg_tx_where(inspect_query(q; connection = conn)[:sql_text])
      @test occursin(r"\"Tb_1\"\.\"year\" = ", where_text)
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# #777: #703's path half is live — a joined copy named after its relation
# #484 lets a `cjoin_on` alias equal a ForeignKey's name, and an explicit `SQLField` over the handle
# keeps the handle's own name (#757's exemption) and the `:base` memo namespace. That is the FK
# path's key exactly: without #703 the filter read the joined copy's `"raceid"."year"` and the FK's
# own join was never emitted — the copy's relation, whatever its ON, under the path the caller named.
# (This fixture's copy joins on the FK's own condition, so the refusal is the contract pinned here.)
# ─────────────────────────────────────────────────────────────────────────────
@testset "#777: a joined copy named after its relation refuses the filter (#703)" begin
  for (backend, conn) in _Q_AGG_TX_CONNS
    @testset "$backend" begin
      q = QAggTx.Result.objects
      q.cjoin_on("Race", alias = "raceid", on = [PormG.Joined("raceid", "raceid") == F("raceid")])
      q.values("resultid", PormG.QueryBuilder.SQLField(PormG.Joined("raceid", "year"), "raceid__year"))
      q.filter("raceid__year" => 2009)
      err = @test_throws AmbiguousFieldError inspect_query(q; connection = conn)
      msg = _q_agg_tx_msg(err.value)
      @test occursin("filter(\"raceid__year\" => …)", msg)
      @test occursin("Joined(\"raceid\", \"year\")", msg)
      @test occursin("#703", msg)
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# #777: #706's twin is live through the same generated name
# A condition inside another projection resolves its key through the same memo, so
# `When("raceid__year" => 2009)` beside `values("raceid__@year")` compared the EXTRACT, not the race's
# year. `_model_filter_key` serves both guards; this pins the SELECT-side reader of it.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#777: a condition on a transform named like a related path refuses (#706)" begin
  for (backend, conn) in _Q_AGG_TX_CONNS
    @testset "$backend" begin
      q = QAggTx.Result.objects
      q.values("resultid", "raceid__@year", "f" => Case([When("raceid__year" => 2009, then = 1)], default = 0))
      err = @test_throws AmbiguousFieldError inspect_query(q; connection = conn)
      msg = _q_agg_tx_msg(err.value)
      @test occursin("values(\"f\" => …)", msg)
      @test occursin("#706", msg)
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# #777: `_alias_lhs`'s namespace check is live — a CTE or joined copy shares a transform's name
# A CTE (#492, via the handle) or a `cjoin_on` copy (#484) may be named after a model field, so
# `CTE("race_date", "year")` / `Joined("race_date", "year")` and `values("race_date__@year")` share the
# name `race_date__year` in different memo namespaces. `_projected_source` matches on the name only;
# without the `:base` check the SECOND `Qor` leaf reused the projection and compared
# `EXTRACT(YEAR FROM race_date)` instead of the column — valid SQL, aligned parameters, wrong rows.
# The ON-clause reading (`fresh = true`, #985) goes through the same check.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#777: a CTE or joined column named like a transform compares the column" begin
  # Both leaves compare `<qualifier>."year"`; no transform appears in the predicate.
  both_leaves(text, qualifier) =
    length(collect(eachmatch(Regex("\"$(qualifier)\"\\.\"year\" = "), text))) == 2 &&
    !occursin("EXTRACT", text) && !occursin("strftime", text)
  for (backend, conn) in _Q_AGG_TX_CONNS
    @testset "$backend — CTE handle in WHERE" begin
      q = QAggTx.Result.objects
      q.with("race_date" => QAggTx.Result.objects.values("resultid", "year" => F("points")),
             join_field = "resultid" => "resultid")
      q.values("resultid", "race_date__@year")
      q.filter(Qor(PormG.CTE("race_date", "year") => 1, PormG.CTE("race_date", "year") => 2))
      insp = inspect_query(q; connection = conn)
      @test both_leaves(_q_agg_tx_where(insp[:sql_text]), "R1_1")
      assert_marker_count(insp, backend)
    end
    @testset "$backend — Joined handle in WHERE" begin
      q = QAggTx.Result.objects
      q.cjoin_on("Race", alias = "race_date", on = [PormG.Joined("race_date", "raceid") == F("raceid")])
      q.values("resultid", "race_date__@year")
      q.filter(Qor(PormG.Joined("race_date", "year") => 1, PormG.Joined("race_date", "year") => 2))
      insp = inspect_query(q; connection = conn)
      @test both_leaves(_q_agg_tx_where(insp[:sql_text]), "race_date")
      assert_marker_count(insp, backend)
    end
    @testset "$backend — Joined handle in another copy's ON clause" begin
      q = QAggTx.Result.objects
      q.cjoin_on("Race", alias = "race_date", on = [PormG.Joined("race_date", "raceid") == F("raceid")])
      q.cjoin_on("Race", alias = "r2",
                 on = [PormG.Joined("r2", "raceid") == F("raceid"),
                       Qor(PormG.Joined("race_date", "year") => 1, PormG.Joined("race_date", "year") => 2)])
      q.values("resultid", "race_date__@year")
      insp = inspect_query(q; connection = conn)
      @test both_leaves(_q_agg_tx_join(insp[:sql_text], "r2"), "race_date")
      assert_marker_count(insp, backend)
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# #1004 helpers: which clause reads the race's `year`, and which reads the transform
# `raceid__@year` projects `EXTRACT(YEAR FROM raceid)` (PostgreSQL) or `strftime('%Y', raceid)`
# (SQLite); `raceid__year` is the race's column, `"Tb_1"."year"` once the FK's join is emitted.
# ─────────────────────────────────────────────────────────────────────────────
_q_agg_tx_transform(text) = occursin("EXTRACT", text) || occursin("strftime", text)
_q_agg_tx_race_year(text) = occursin("\"Tb_1\".\"year\"", text)
_q_agg_tx_order(sql) = (m = match(r"ORDER BY(.*)"s, sql); m === nothing ? "" : m.captures[1])
# Up to the statement's own FROM, which starts a line — not the one inside `EXTRACT(YEAR FROM …)`.
_q_agg_tx_select(sql) = (m = match(r"SELECT(.*?)\nFROM "s, sql); m === nothing ? "" : m.captures[1])

# ─────────────────────────────────────────────────────────────────────────────
# #1004: a renamed transform does not answer for the related path
# A transform's memo key used to drop the `@`: `values("yr" => "raceid__@year")` was keyed
# `raceid__year`, the path to the race's `year`, so a filter, `Q`, `Qor`, `When` or `order_by` on that
# path read the transform back. #703 compares output names (`yr`), so nothing refused it, and SQLite
# runs `strftime` over the integer key without an error. Each now reads the race's column, and the
# projection keeps its transform.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1004: a renamed transform does not answer for the related path" begin
  renamed() = (q = QAggTx.Result.objects; q.values("resultid", "yr" => "raceid__@year"); q)
  for (backend, conn) in _Q_AGG_TX_CONNS
    @testset "$backend — $label" for (label, add!) in (
        ("filter", q -> q.filter("raceid__year" => 2009)),
        ("Q", q -> q.filter(Q("raceid__year" => 2009))),
        ("Qor", q -> q.filter(Qor("raceid__year" => 2009, "raceid__year" => 2010))))
      q = renamed(); add!(q)
      insp = inspect_query(q; connection = conn)
      where_text = _q_agg_tx_where(insp[:sql_text])
      @test _q_agg_tx_race_year(where_text)
      @test !_q_agg_tx_transform(where_text)
      # The projection is untouched: still the transform, under the caller's name.
      @test occursin(r"\"raceid\".*as \"yr\""s, _q_agg_tx_select(insp[:sql_text]))
      @test _q_agg_tx_transform(_q_agg_tx_select(insp[:sql_text]))
      assert_marker_count(insp, backend)
    end
    @testset "$backend — order_by" begin
      q = renamed(); q.order_by("raceid__year")
      order_text = _q_agg_tx_order(inspect_query(q; connection = conn)[:sql_text])
      @test _q_agg_tx_race_year(order_text)
      @test !_q_agg_tx_transform(order_text)
    end
    @testset "$backend — a When in another projection" begin
      q = QAggTx.Result.objects
      q.values("resultid", "yr" => "raceid__@year",
               "f" => Case([When("raceid__year" => 2009, then = 1)], default = 0))
      sql = inspect_query(q; connection = conn)[:sql_text]
      @test occursin(r"CASE\s+WHEN \"Tb_1\"\.\"year\" = ", sql)
      # ...and `yr` is still the transform, not the column the condition read.
      @test occursin(r"\"raceid\"\)(::integer| AS INTEGER\))? as \"yr\"", sql)
    end
    # Control: the transform spelling still finds the projection by key (#587) and orders by its name.
    @testset "$backend — order_by the transform spelling" begin
      q = renamed(); q.order_by("raceid__@year")
      @test occursin(r"ORDER BY \"yr\" ASC", inspect_query(q; connection = conn)[:sql_text])
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# #1004: a transform rendered in one place does not answer for the path in another
# The memo is shared by every clause of one build, so the transform's old key leaked across them
# with no projection at all: a filter on `raceid__@year` wrote the entry, and a later `order_by` or
# a second filter on `raceid__year` read the transform. The mirror ran the other way: a projected
# `raceid__year` claimed the key, and `order_by("raceid__@year")` sorted by the race's column.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1004: a transform rendered in one clause does not answer for the path in another" begin
  for (backend, conn) in _Q_AGG_TX_CONNS
    @testset "$backend — filter, then order_by the path" begin
      q = QAggTx.Result.objects
      q.values("resultid"); q.filter("raceid__@year" => 2009); q.order_by("raceid__year")
      sql = inspect_query(q; connection = conn)[:sql_text]
      @test _q_agg_tx_transform(_q_agg_tx_where(sql))
      @test _q_agg_tx_race_year(_q_agg_tx_order(sql))
      @test !_q_agg_tx_transform(_q_agg_tx_order(sql))
    end
    @testset "$backend — two filters" begin
      q = QAggTx.Result.objects
      q.values("resultid"); q.filter("raceid__@year" => 2009, "raceid__year" => 2010)
      insp = inspect_query(q; connection = conn)
      where_text = _q_agg_tx_where(insp[:sql_text])
      @test _q_agg_tx_transform(where_text)
      @test occursin(r"\"Tb_1\"\.\"year\" = ", where_text)
      assert_marker_count(insp, backend)
    end
    @testset "$backend — two order terms" begin
      q = QAggTx.Result.objects
      q.values("resultid"); q.order_by("raceid__@year", "raceid__year")
      # Split at the term boundary: `strftime('%Y', …)` has a comma of its own.
      terms = split(_q_agg_tx_order(inspect_query(q; connection = conn)[:sql_text]), "NULLS LAST,")
      @test length(terms) == 2
      @test _q_agg_tx_transform(terms[1])
      @test _q_agg_tx_race_year(terms[2]) && !_q_agg_tx_transform(terms[2])
    end
    @testset "$backend — a When on the transform, then the path projected" begin
      q = QAggTx.Result.objects
      q.values("f" => Case([When("raceid__@year" => 2009, then = 1)], default = 0), "raceid__year")
      select_text = _q_agg_tx_select(inspect_query(q; connection = conn)[:sql_text])
      @test occursin(r"\"Tb_1\"\.\"year\" as \"raceid__year\"", select_text)
    end
    @testset "$backend — the path projected, then order_by the transform" begin
      q = QAggTx.Result.objects
      q.values("resultid", "raceid__year"); q.order_by("raceid__@year")
      order_text = _q_agg_tx_order(inspect_query(q; connection = conn)[:sql_text])
      @test _q_agg_tx_transform(order_text)
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# #1004: ordering by a transform's generated name that is also a related path
# `values("raceid__@year")` is output as `raceid__year`, and ORDER BY matched a projection by output
# name alone, so `order_by("raceid__year")` sorted by the transform whatever the caller meant. Two
# meanings, refused as #703 refuses the filter. A generated name that is NOT a path keeps ordering by
# the projection — `values("race_date__@day"); order_by("race_date__day")` is documented and
# integration-tested — and so does the transform spelling.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1004: ordering by a transform's generated name that is also a related path" begin
  for (backend, conn) in _Q_AGG_TX_CONNS
    @testset "$backend" begin
      q = QAggTx.Result.objects
      q.values("resultid", "raceid__@year"); q.order_by("raceid__year")
      err = @test_throws AmbiguousFieldError inspect_query(q; connection = conn)
      msg = _q_agg_tx_msg(err.value)
      @test occursin("order_by(\"raceid__year\") is ambiguous", msg)
      @test occursin("order_by(\"raceid__@year\")", msg)
      @test occursin("values(\"raceid_year\" => \"raceid__@year\")", msg)
      @test occursin("#1004", msg)

      # The transform spelling orders by the projection's name.
      q = QAggTx.Result.objects
      q.values("resultid", "raceid__@year"); q.order_by("raceid__@year")
      @test occursin(r"ORDER BY \"raceid__year\" ASC", inspect_query(q; connection = conn)[:sql_text])

      # The advice, followed: the named projection frees the path for the column.
      q = QAggTx.Result.objects
      q.values("resultid", "raceid_year" => "raceid__@year"); q.order_by("raceid__year")
      order_text = _q_agg_tx_order(inspect_query(q; connection = conn)[:sql_text])
      @test _q_agg_tx_race_year(order_text) && !_q_agg_tx_transform(order_text)

      # Control: a generated name that reaches no related column still orders by the projection.
      q = QAggTx.Result.objects
      q.values("race_date__@day"); q.order_by("race_date__day")
      @test occursin(r"ORDER BY \"race_date__day\" ASC", inspect_query(q; connection = conn)[:sql_text])
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# #1004: what the ORDER BY refusal leaves alone, and the handle twin of the transform term
# The refusal is for a TRANSFORM's generated name. A joined copy named after its foreign key (#484)
# keeps ordering by the copy's alias, as it always did — out of #1004's scope. A handle term is the
# transform term's twin: `order_by(Joined("raceid", "year"))` beside a projected `raceid__year` path
# matched that projection by name and sorted by the FOREIGN KEY's race, not the joined copy.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1004: the ORDER BY refusal is for transforms; a handle term is not matched by name" begin
  copy_on(q) = q.cjoin_on("Race", alias = "raceid", on = [PormG.Joined("raceid", "raceid") == F("raceid")])
  for (backend, conn) in _Q_AGG_TX_CONNS
    @testset "$backend" begin
      q = QAggTx.Result.objects; copy_on(q)
      q.values("resultid", PormG.Joined("raceid", "year")); q.order_by("raceid__year")
      @test occursin(r"ORDER BY \"raceid__year\" ASC", inspect_query(q; connection = conn)[:sql_text])

      q = QAggTx.Result.objects; copy_on(q)
      q.values("resultid", "raceid__year"); q.order_by(PormG.Joined("raceid", "year"))
      @test occursin(r"ORDER BY \"raceid\"\.\"year\" ASC", inspect_query(q; connection = conn)[:sql_text])
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# #1004: an UPDATE filters the related path beside a transform projection
# A read refuses `filter("raceid__year")` beside `values("raceid__@year")` (#703: the name means the
# column and the projection). An UPDATE has no projection (#668), so only the column is left — and the
# filter no longer resolves through the projection memo, which is what #668's refusal guards. It
# filters the race's year, as the same filter does with no projection at all.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1004: an UPDATE beside a transform projection filters the related column" begin
  q = QAggTx.Result.objects
  q.values("resultid", "raceid__@year"); q.filter("raceid__year" => 2009)
  sql = q.update("points" => 0.0, show_query = :dict)[:sql_text]
  @test occursin(r"\"Tb_1\"\.\"year\" = \?", sql)
  @test !_q_agg_tx_transform(sql)
end

# ─────────────────────────────────────────────────────────────────────────────
# #1004: #703 and #706's advice for a generated `__` name can be followed
# Both used to say "rename the alias — `values("raceid__year_value" => …)`", which #757 refuses, and
# called the projection `values("raceid__year" => EXTRACT(...))`, a declaration the caller never
# wrote. The advice now names a projection `values()` accepts, and how to reach each meaning.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1004: #703 and #706 advice for a generated name can be followed" begin
  for (backend, conn) in _Q_AGG_TX_CONNS
    @testset "$backend — #703" begin
      q = QAggTx.Result.objects
      q.values("resultid", "raceid__@year"); q.filter("raceid__year" => 2009)
      err = @test_throws AmbiguousFieldError inspect_query(q; connection = conn)
      msg = _q_agg_tx_msg(err.value)
      @test occursin("the projection values(\"raceid__@year\")", msg)
      @test occursin("values(\"raceid_year\" => \"raceid__@year\")", msg)
      @test occursin("filter \"raceid__@year\" for the projection", msg)
      @test !occursin("_value", msg)
      @test occursin("#703", msg)
    end
    @testset "$backend — #706" begin
      q = QAggTx.Result.objects
      q.values("resultid", "raceid__@year", "f" => Case([When("raceid__year" => 2009, then = 1)], default = 0))
      err = @test_throws AmbiguousFieldError inspect_query(q; connection = conn)
      msg = _q_agg_tx_msg(err.value)
      @test occursin("values(\"raceid_year\" => \"raceid__@year\")", msg)
      @test occursin("write \"raceid__@year\" in the condition", msg)
      @test !occursin("_value", msg)
      @test occursin("#706", msg)
    end
    @testset "$backend — the advice, followed" begin
      # `values()` accepts the suggested name, the transform spelling filters the transform, and the
      # path filters the race's column — in one query, each where the advice said.
      q = QAggTx.Result.objects
      q.values("resultid", "raceid_year" => "raceid__@year")
      q.filter("raceid__@year" => 2009, "raceid__year" => 2010)
      insp = inspect_query(q; connection = conn)
      where_text = _q_agg_tx_where(insp[:sql_text])
      @test _q_agg_tx_transform(where_text)
      @test occursin(r"\"Tb_1\"\.\"year\" = ", where_text)
      assert_marker_count(insp, backend)
    end
    @testset "$backend — a generated name that reaches no column" begin
      # #703 keys a path on its first segment, so it refuses this too; the message must not offer
      # `race_date__day` as a column — a date has no `day` field.
      q = QAggTx.Result.objects
      q.values("resultid", "race_date__@day"); q.filter("race_date__day" => 5)
      err = @test_throws AmbiguousFieldError inspect_query(q; connection = conn)
      msg = _q_agg_tx_msg(err.value)
      @test occursin("a generated name is not a filter key", msg)
      @test occursin("Filter \"race_date__@day\" for the projection's value", msg)
      @test !occursin("for the column", msg)
      q = QAggTx.Result.objects
      q.values("resultid", "race_date__@day", "f" => Case([When("race_date__day" => 5, then = 1)], default = 0))
      err = @test_throws AmbiguousFieldError inspect_query(q; connection = conn)
      msg = _q_agg_tx_msg(err.value)
      @test occursin("a generated name is not a condition key", msg)
      @test occursin("Write \"race_date__@day\" in the condition", msg)
    end
    @testset "$backend — a joined copy is reached through its handle" begin
      q = QAggTx.Result.objects
      q.cjoin_on("Race", alias = "raceid", on = [PormG.Joined("raceid", "raceid") == F("raceid")])
      q.values("resultid", PormG.QueryBuilder.SQLField(PormG.Joined("raceid", "year"), "raceid__year"))
      q.filter("raceid__year" => 2009)
      err = @test_throws AmbiguousFieldError inspect_query(q; connection = conn)
      msg = _q_agg_tx_msg(err.value)
      @test occursin("values(\"raceid_year\" => Joined(\"raceid\", \"year\"))", msg)
      @test occursin("filter Joined(\"raceid\", \"year\") for the projection", msg)
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# #1004: the unknown-field message lists the names the caller declared
# It used to list the memo's keys, and a path projection is memoized under its path:
# `values("yr" => "race_date__@year")` showed up as `race_date__year`, a name the caller never wrote.
# It now lists the declaration, and explains the one declared name it cannot filter on.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1004: the unknown-field message lists the names the caller declared" begin
  for (backend, conn) in _Q_AGG_TX_CONNS
    @testset "$backend" begin
      declared() = (q = QAggTx.Result.objects;
                    q.values("resultid", "yr" => "race_date__@year", "pts" => Sum("points")); q)
      q = declared(); q.filter("nope" => 1)
      err = @test_throws PormG.UnknownFieldError inspect_query(q; connection = conn)
      msg = _q_agg_tx_msg(err.value)
      @test occursin("declared aliases: pts, yr", msg)
      @test !occursin("race_date__year", msg)
      @test !occursin("race_date__@year", msg)

      # The chosen name of a path projection is listed, and filtering on it says how to reach it.
      q = declared(); q.filter("yr" => 2020)
      err = @test_throws PormG.UnknownFieldError inspect_query(q; connection = conn)
      msg = _q_agg_tx_msg(err.value)
      @test occursin("Filter \"race_date__@year\" instead", msg)
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# #1004: a function node's own `__` name is refused as a Pair alias is (#757)
# `values()` checked the alias of a Pair and of an explicit `SQLField`, but a function node built with
# its own `_as` reached the projection list unchecked — the internal `WindowFunction(…; _as =
# "ev__seen")` projected under a `__` name every router misreads.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1004: a function node's own `__` name is refused (#757)" begin
  with_as(f, name) = PormG.QueryBuilder.FObject(function_name = f.function_name, column = f.column,
                                                aggregate = f.aggregate, formatter = f.formatter,
                                                _as = name, kwargs = f.kwargs)
  err = @test_throws PormG.QueryBuildError QAggTx.Result.objects.values("resultid", with_as(Sum("points"), "season__points"))
  @test occursin("#757", _q_agg_tx_msg(err.value))
  # A single underscore is a name like any other.
  q = QAggTx.Result.objects
  q.values("resultid", with_as(Sum("points"), "season_points"))
  @test occursin("as \"season_points\"", inspect_query(q; connection = QAggTxMockSQLite())[:sql_text])
  # No name at all is still the "requires an alias" error, not a MethodError from the check.
  q = QAggTx.Result.objects
  q.values(Sum("points"))
  err = @test_throws PormG.QueryBuildError inspect_query(q; connection = QAggTxMockSQLite())
  @test occursin("requires an alias", _q_agg_tx_msg(err.value))
end

# ─────────────────────────────────────────────────────────────────────────────
# #1004: a grouped transform does not group the related path (#798)
# The GROUP BY leaf keys folded `__@` into `__` too, so a grouped `values("raceid__@year")` made a
# mixed term reading the plain path `raceid__year` look grouped — PostgreSQL rejects the statement,
# SQLite answers with an arbitrary row's year. Both directions are refused now; the transform read
# whole beside its own grouping still builds.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1004: a grouped transform does not group the related path (#798)" begin
  for (backend, conn) in _Q_AGG_TX_CONNS
    @testset "$backend" begin
      q = QAggTx.Result.objects
      q.values("raceid__@year", "x" => F("raceid__year") + Sum("points"))
      err = @test_throws PormG.QueryBuildError inspect_query(q; connection = conn)
      @test occursin("#798", _q_agg_tx_msg(err.value))

      q = QAggTx.Result.objects
      q.values("raceid__year", "x" => F("raceid__@year") + Sum("points"))
      err = @test_throws PormG.QueryBuildError inspect_query(q; connection = conn)
      @test occursin("#798", _q_agg_tx_msg(err.value))

      # Control: the grouped transform read again is grouped.
      q = QAggTx.Result.objects
      q.values("raceid__@year", "x" => F("raceid__@year") + Sum("points"))
      @test occursin("GROUP BY 1", inspect_query(q; connection = conn)[:sql_text])
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# #1004: the memo key keeps the transform's `@`
# The key is the mechanism the testsets above observe; pinned directly so a construction site that
# rebuilds an `SQLField` and drops the name is caught where it happens.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1004: a transform's memo key keeps its `@`; its output name does not" begin
  QB = PormG.QueryBuilder
  f = QB._values_field("raceid__@year")
  @test f._as == "raceid__year"
  @test QB.memo_key(f) == (:base, "raceid__@year")
  @test QB.memo_key(deepcopy(f)) == (:base, "raceid__@year")
  # A plain path's key is its name, as before.
  @test QB.memo_key(QB._values_field("raceid__year")) == (:base, "raceid__year")
  # The CTE and joined-copy spellings move the `@` with their prefix.
  @test QB.memo_key(QB._values_field(PormG.CTE("ev", "seen__@year"))) == (:cte, "ev__seen__@year")
  @test QB.memo_key(QB._values_field(PormG.Joined("d", "seen__@year"))) == (:joined, "d__seen__@year")
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
      # operator). On SQLite too since #851: this cell asserted the native `5` there, which a text
      # expression never equals (`('' || 5) = 5` is 0 — no affinity on either side).
      for pred in ("nm" => 5, Q("nm" => 5))
        q = Model_.objects
        q.values("resultid", "nm" => projection)
        q.filter(pred)
        @test last(inspect_query(q)[:parameters]) == "5"
      end
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# #851: SQLite keeps a number native only for a NUMBER-typed alias
# `_sqlite_preserve_native_parameter` kept every Number native on SQLite, whatever the alias's type,
# so a number compared with a text expression bound `7` against `'7'` and matched no rows (neither
# side has affinity). A text alias now binds the number as text on both engines; a number alias
# (an aggregate, a cast to integer) still binds it native on SQLite, which its `SUM(…) = '1.5'`
# counterpart needs. The last block executes the SQLite SQL, so the cell is the rows, not a vector.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#851: SQLite binds a number as text against a text alias, native against a number alias" begin
  # The alias keyed like a race code: the race id as text. `Concat` is text on both engines.
  race_code() = PormG.Functions.Concat(["raceid", Value("")])
  # The bound value of `filter(pred)` over `values(alias => projection)`, for a backend's model.
  function bound(Model_, projection, pred)
    q = Model_.objects
    q.values("resultid", "rk" => projection)
    q.filter(pred)
    return inspect_query(q)[:parameters]
  end
  # A two-element `@in` list as bound: ONE array parameter on PostgreSQL, two `?` on SQLite.
  in_list(params, backend) = backend === :postgres ? last(params) : params[end-1:end]

  @testset "$backend — a text alias binds the number as text" for (backend, Model_) in _Q_AGG_MODELS
    # Both spellings, and both operands of a range: each is the right-hand side of a comparison.
    @test last(bound(Model_, race_code(), "rk" => 7)) == "7"
    @test last(bound(Model_, race_code(), Q("rk" => 7))) == "7"
    @test bound(Model_, race_code(), "rk__@gte" => 7)[end] == "7"
    @test bound(Model_, race_code(), "rk__@range" => [1, 9])[end-1:end] == ["1", "9"]
    @test in_list(bound(Model_, race_code(), "rk__@in" => [7, 9]), backend) == ["7", "9"]
    # `ToChar` is text too: its alias had no type at all, so the year bound as the number 2020.
    @test last(bound(Model_, PormG.QueryBuilder.ToChar("race_date", "YYYY"), "rk" => 2020)) == "2020"
  end

  @testset "$backend — a number alias keeps its native value on SQLite" for (backend, Model_) in _Q_AGG_MODELS
    # `format_number_sql(1.5)` is the string "1.5": PostgreSQL binds it (`$1` is typed by the
    # column), SQLite keeps the Float64, because `SUM(points) = '1.5'` is false there.
    @test last(bound(Model_, Sum("points"), "rk__@gt" => 1.5)) == (backend === :postgres ? "1.5" : 1.5)
    # An integer is native on both: `format_number_sql(::Integer)` returns it as is.
    # #1028: over `Floor`, because a float cast to an integer rounds on one engine and truncates on
    # the other, and is refused.
    @test last(bound(Model_, PormG.QueryBuilder.Cast(PormG.Functions.Floor("points"), "integer"), "rk" => 7)) === 7
    # A membership list keeps each element native on SQLite, as a range does: before, the list
    # reached the scalar rule whole, was never a `Number`, and bound `["25.5", "1.5"]`.
    @test in_list(bound(Model_, Sum("points"), "rk__@in" => [25.5, 1.5]), backend) ==
          (backend === :postgres ? ["25.5", "1.5"] : [25.5, 1.5])
  end

  # The rows, not the vector: run the SQLite SQL the builder emits against an in-memory table. The
  # fix is a match where there was none; the PostgreSQL side is the matching row by construction.
  @testset "SQLite — the filter matches the row" begin
    isdefined(Main, :SQLite) || include(joinpath(@__DIR__, "..", "load_drivers.jl"))
    db = Main.SQLite.DB()
    # Read inside the iteration: a SQLite row is a view of the cursor, gone once it advances.
    column(sql, name, params = ()) = [getproperty(row, name) for row in Main.SQLite.DBInterface.execute(db, sql, params)]
    try
      Main.SQLite.DBInterface.execute(db, "CREATE TABLE q_agg_results (resultid INTEGER, raceid INTEGER, " *
                                          "points REAL, surname TEXT, race_date TEXT)")
      Main.SQLite.DBInterface.execute(db, "INSERT INTO q_agg_results VALUES (1, 7, 25.0, 'Hamilton', '2020-03-29')")
      # The issue's premise, stated directly: a text expression never equals a native integer.
      @test column("SELECT ('' || 7) = 7 AS v", :v) == [0]
      @test column("SELECT ('' || 7) = '7' AS v", :v) == [1]
      for pred in ("rk" => 7, Q("rk" => 7))
        q = QAggSlResult.objects
        q.values("resultid", "rk" => race_code())
        q.filter(pred)
        insp = inspect_query(q)
        # One row, the race-7 result; the native `7` matched none before #851.
        @test column(insp[:sql_text], :resultid, insp[:parameters]) == [1]
      end
      # The two siblings the review of #851 found, executed the same way.
      sibling_cases = (
        # `strftime('%Y', …) = 2020` against the text '2020': no row while the year bound native.
        ("ToChar", "rk" => PormG.QueryBuilder.ToChar("race_date", "YYYY"), "rk" => 2020),
        # `SUM(points) IN ('25.0')`: a REAL never equals text, so no row while the list bound text.
        ("Sum @in", "rk" => Sum("points"), "rk__@in" => [25.0, 1.5]),
      )
      for (label, projection, pred) in sibling_cases
        q = QAggSlResult.objects
        q.values("resultid", projection)
        q.filter(pred)
        insp = inspect_query(q)
        @test column(insp[:sql_text], :resultid, insp[:parameters]) == [1]
      end
    finally
      close(db)
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
  cases = (("a wrong-typed value", "pts" => "not-a-number", PormG.InvalidValueError, "projection alias"),
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
      q.values("resultid", "pi" => PormG.Functions.Cast(PormG.Functions.Round("points"), IntegerField()))   # #1028: rounded first
      q.filter(pred)
      err = @test_throws PormG.InvalidValueError inspect_query(q)
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

# ─────────────────────────────────────────────────────────────────────────────
# #707: an expression on the right of an AGGREGATE alias filter is a HAVING comparison
# `filter("total__@gt" => F("raceid"))` over `Sum("points")` handed the `F` to the number formatter
# and died with `MethodError: format_number_sql(::FExpression)`, top-level and inside `Q` — on
# `main` too. It renders `HAVING SUM(…) > "Tb"."raceid"`, an aggregate on the right included. An
# aggregate alias that BINDS re-renders its values in HAVING, in text order after the SELECT's.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#707: an expression on the right of an aggregate alias filter renders in HAVING" begin
  for (backend, Model_) in _Q_AGG_MODELS
    for (label, pred, needle) in (("an F column", "total__@gt" => F("raceid"),
                                   "HAVING SUM(\"Tb\".\"points\") > \"Tb\".\"raceid\""),
                                  ("an aggregate", "total__@gt" => Max("raceid"),
                                   "HAVING SUM(\"Tb\".\"points\") > MAX(\"Tb\".\"raceid\")"))
      for spelled in (pred, Q(pred))
        @testset "$backend — $label, $(spelled isa Pair ? "top-level" : "Q")" begin
          q = Model_.objects
          q.values("raceid", "total" => Sum("points"))
          q.filter(spelled)
          insp = inspect_query(q)
          sql = replace(insp[:sql_text], r"\s+" => " ")
          @test occursin(needle, replace(sql, r"HAVING \((.*)\)" => s"HAVING \1"))
          @test _clause(insp[:sql_text], "WHERE") === nothing
          @test isempty(insp[:parameters])
          assert_marker_count(insp, backend)
        end
      end
    end
    @testset "$backend — a binding aggregate alias, split from a row filter" begin
      q = Model_.objects
      q.values("raceid", "wins" => Count(Case([When("points__@gte" => 25.0, then = 1)])))
      q.filter(Q("wins__@gt" => F("raceid"), "raceid__@gte" => 3))
      insp = inspect_query(q)
      sql = replace(insp[:sql_text], r"\s+" => " ")
      @test occursin(r"HAVING COUNT\(CASE WHEN .* END \) > \"Tb\"\.\"raceid\"", sql)
      @test occursin(r"WHERE \"Tb\"\.\"raceid\" >= ", sql)
      assert_marker_count(insp, backend)
      # Text order: SELECT's two CASE operands, WHERE's 3, then HAVING's re-render binding the SAME
      # two operands (as the column formatter shaped them) — never a reprinted marker with no value.
      params = insp[:parameters]
      @test length(params) == 5
      @test params[3] == 3
      @test params[4:5] == params[1:2]
    end
    @testset "$backend — a binding right-hand side after a binding alias" begin
      # Both sides bind in HAVING: the alias's re-rendered operands, then the `+ 1` (review nit).
      q = Model_.objects
      q.values("raceid", "wins" => Count(Case([When("points__@gte" => 25.0, then = 1)])))
      q.filter("wins__@gt" => F("raceid") + 1)
      insp = inspect_query(q)
      @test occursin(r"HAVING COUNT\(CASE WHEN .* END \) > \(\"Tb\"\.\"raceid\" \+ [?$]",
                     replace(insp[:sql_text], r"\s+" => " "))
      assert_marker_count(insp, backend)
      params = insp[:parameters]
      @test length(params) == 5
      @test params[3:4] == params[1:2]
      @test params[5] == 1
    end
  end
end
