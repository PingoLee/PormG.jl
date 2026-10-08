using Test
using DataFrames
using PormG
using PormG.QueryBuilder: OuterRef, Subquery, Count, Sum, Qor, F, bulk_insert, bulk_update
import PormG.QueryBuilder: _format_sql, _sql_tokens

# ─────────────────────────────────────────────────────────────────────────────
# show_query = :pretty (#48)
#
# DB-free: every statement here is rendered against bare mock connections and never executed. The
# contract under test is that `:pretty` changes WHITESPACE BETWEEN TOKENS and nothing else, so the
# pretty text runs exactly as the compact text does (test/integration/test_explain.jl executes both
# and compares the rows). The oracle for "nothing else" is deliberately not the formatter's own
# tokenizer: stripping every whitespace character from both strings must give the same text, which
# holds for every statement in this corpus because none of them carries a literal with a space in it.
# ─────────────────────────────────────────────────────────────────────────────

struct MockPgFormat <: PormG.PormGPostgres end
struct MockSqliteFormat <: PormG.PormGSQLite end
# The bare SQLite mock has no driver body; answer the bind-parameter-limit probe (#84) so bulk
# statements render without a database.
PormG.backend_sqlite_version(::MockSqliteFormat) = 3045000

PormG.config["fmt_pg"] = PormG.Configuration.Settings(
  connections = MockPgFormat(), change_data = true, db_def_folder = "fmt_pg")
PormG.config["fmt_sqlite"] = PormG.Configuration.Settings(
  connections = MockSqliteFormat(), change_data = true, db_def_folder = "fmt_sqlite")

# One F1-shaped schema per engine, each in its own module so `set_models` resolves the foreign keys
# and binds the models to that engine's mock.
const FMT_MODELS = quote
  import PormG
  import PormG.Models
  Circuit = Models.Model("fmt_circuit",
    circuitid = Models.IDField(),
    name = Models.CharField(),
    country = Models.CharField(),
  )
  Race = Models.Model("fmt_race",
    raceid = Models.IDField(),
    year = Models.IntegerField(),
    name = Models.CharField(),
    circuitid = Models.ForeignKey(Circuit, pk_field = "circuitid"),
  )
  Result = Models.Model("fmt_result",
    resultid = Models.IDField(),
    raceid = Models.ForeignKey(Race, pk_field = "raceid"),
    points = Models.IntegerField(),
    positionorder = Models.IntegerField(),
  )
end
module FmtPG end
module FmtSL end
Core.eval(FmtPG, FMT_MODELS)
Core.eval(FmtSL, FMT_MODELS)
PormG.Models.set_models(FmtPG, "fmt_pg")
PormG.Models.set_models(FmtSL, "fmt_sqlite")

# Every statement shape the builders emit that the formatter has a rule for: projections, joins,
# AND/OR, BETWEEN, CASE-free aggregates, a correlated subquery, a CTE, IN (subquery), LIMIT/OFFSET,
# INSERT … RETURNING, UPDATE, DELETE and the bulk forms. Rendered with `:sql`, so this is the exact
# text `:pretty` reflows.
function _fmt_corpus(M)
  sqls = String[]
  push!(sqls, show_query(M.Result.objects.filter("raceid__year__@gte" => 1990, "points__@gt" => 0).
    values("raceid__name", "points").order_by("-points").limit(5).offset(10), :sql))
  push!(sqls, show_query(M.Result.objects.filter(Qor("points" => 10, "positionorder" => 1)).
    values("raceid__circuitid__country", "total" => Sum("points")), :sql))
  push!(sqls, show_query(M.Race.objects.filter("year__@range" => [1988, 1993]).values("name"), :sql))
  wins = M.Result.objects.filter("raceid" => OuterRef("raceid"), "positionorder" => 1).values("n" => Count("resultid"))
  push!(sqls, show_query(M.Race.objects.values("name", "winners" => Subquery(wins)), :sql))
  push!(sqls, show_query(M.Race.objects.filter("circuitid__@in" => M.Circuit.objects.filter("country" => "Brazil").values("circuitid")).values("name"), :sql))
  push!(sqls, M.Race.objects.create("year" => 1991, "name" => "Brazilian GP", "circuitid" => 1, show_query = :sql))
  push!(sqls, M.Result.objects.filter("raceid__year" => 1991).update("points" => F("points") + 1, show_query = :sql))
  push!(sqls, M.Result.objects.filter("points" => 0).update("points" => 1, show_query = :sql))
  deleted = M.Result.objects.filter("raceid" => 7).delete(show_query = :sql)
  append!(sqls, deleted isa AbstractVector ? deleted : [deleted])
  df = DataFrame(raceid = [1, 2], points = [10, 6], positionorder = [1, 2])
  push!(sqls, bulk_insert(M.Result, df; show_query = :sql) |> (x -> x isa AbstractVector ? Base.first(x) : x))
  df_up = DataFrame(resultid = [1, 2], points = [9, 5])
  push!(sqls, bulk_update(M.Result, df_up; columns = ["points"], show_query = :sql) |> (x -> x isa AbstractVector ? Base.first(x) : x))
  return sqls
end

# Whitespace-insensitive text: the independent oracle for "only whitespace changed".
_squash(s) = replace(s, r"\s+" => "")

# ─────────────────────────────────────────────────────────────────────────────
# :pretty: token preservation over the builder corpus, both engines
# For every statement the builders render, the pretty text differs from the compact text only in
# whitespace, formatting it twice changes nothing, and it really did reflow (a statement with a
# FROM gains a line break before it). Run on PostgreSQL ($n) and SQLite (?) placeholders.
# ─────────────────────────────────────────────────────────────────────────────
@testset "show_query = :pretty: only whitespace changes ($(nameof(M)))" for M in (FmtPG, FmtSL)
  corpus = _fmt_corpus(M)
  @test length(corpus) >= 10
  for sql in corpus
    pretty = _format_sql(sql)
    # Same characters once whitespace is ignored — nothing added, dropped or reordered.
    @test _squash(pretty) == _squash(sql)
    # Same significant tokens, in order, by the formatter's own tokenizer as a second view.
    sig(s) = [t for t in _sql_tokens(s) if t[1] !== :ws]
    @test sig(pretty) == sig(sql)
    # Idempotent: formatting pretty text is a no-op.
    @test _format_sql(pretty) == pretty
    # No line ends in whitespace — the formatter never writes a space before a break.
    @test !any(l -> endswith(l, ' '), split(pretty, '\n'))
    # A reflow actually happened: a WHERE clause always starts its own line, and so does a FROM
    # clause — except `DELETE FROM`, where FROM belongs to the statement head.
    occursin(r"\bWHERE\b", sql) && @test occursin(r"\n\s*WHERE\b", pretty)
    occursin(r"\bFROM\b", sql) && !startswith(sql, "DELETE") && @test occursin(r"\n\s*FROM\b", pretty)
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# :pretty: the clause layout
# Pins the shape users read in a log: one clause per line, the SELECT list one item per line, each
# extra WHERE condition on its own indented line, and a subquery indented inside its parentheses
# with the closing parenthesis back at the opening line's indent.
# ─────────────────────────────────────────────────────────────────────────────
@testset "show_query = :pretty: clause layout" begin
  sql = """SELECT "Tb"."name" as "name", (SELECT COUNT("R1"."resultid") as "n" FROM "fmt_result" as "R1" WHERE "R1"."raceid" = "Tb"."raceid") as "winners" FROM "fmt_race" as "Tb" INNER JOIN "fmt_circuit" AS "Tb_1" ON "Tb"."circuitid" = "Tb_1"."circuitid" WHERE "Tb"."year" >= \$1 AND "Tb_1"."country" = \$2 ORDER BY "name" LIMIT \$3"""
  @test _format_sql(sql) == """
SELECT
  "Tb"."name" as "name",
  (
    SELECT
      COUNT("R1"."resultid") as "n"
    FROM "fmt_result" as "R1"
    WHERE "R1"."raceid" = "Tb"."raceid"
  ) as "winners"
FROM "fmt_race" as "Tb"
INNER JOIN "fmt_circuit" AS "Tb_1" ON "Tb"."circuitid" = "Tb_1"."circuitid"
WHERE "Tb"."year" >= \$1
  AND "Tb_1"."country" = \$2
ORDER BY "name"
LIMIT \$3"""
end

# ─────────────────────────────────────────────────────────────────────────────
# :pretty: words that only look like clause keywords
# A keyword-shaped word must not break a line where it is not a clause: inside a literal or a quoted
# identifier, inside a function call's parentheses, in `IS DISTINCT FROM`, in `BETWEEN … AND`, in a
# CASE expression, in `LEFT(…)`, and in `FOR UPDATE`. Each of these would still be SQL-equivalent if
# broken (it is only whitespace), so the assertions pin the layout, not just the token sequence.
# ─────────────────────────────────────────────────────────────────────────────
@testset "show_query = :pretty: keyword look-alikes stay inline" begin
  # A literal and a quoted identifier keep every byte, newlines and keywords included.
  lit = "SELECT 'a FROM b\nWHERE c' AS \"order by\" FROM t"
  out = _format_sql(lit)
  @test occursin("'a FROM b\nWHERE c'", out)
  @test occursin("\"order by\"", out)
  @test _squash(out) == _squash(lit)
  # A doubled quote is an escaped quote, not the end of the literal.
  @test occursin("'it''s FROM here'", _format_sql("SELECT 'it''s FROM here' FROM t"))
  # A dollar-quoted body is one token.
  @test occursin("\$\$ WHERE x \$\$", _format_sql("SELECT \$\$ WHERE x \$\$ FROM t"))
  # Inside a function call FROM does not break, nor does ORDER BY inside OVER (…).
  inline = _format_sql("SELECT EXTRACT(YEAR FROM \"d\") AS y, ROW_NUMBER() OVER (PARTITION BY \"a\" ORDER BY \"b\") AS r FROM t")
  @test occursin("EXTRACT(YEAR FROM \"d\")", inline)
  @test occursin("OVER (PARTITION BY \"a\" ORDER BY \"b\")", inline)
  # IS DISTINCT FROM is an operator, BETWEEN's AND is not a condition, CASE's AND stays put.
  ops = _format_sql("SELECT a FROM t WHERE a IS DISTINCT FROM b AND c BETWEEN 1 AND 2 AND (CASE WHEN x AND y THEN 1 END) = 1")
  @test occursin("a IS DISTINCT FROM b", ops)
  @test occursin("c BETWEEN 1 AND 2", ops)
  @test occursin("CASE WHEN x AND y THEN 1 END", ops)
  @test count("\n  AND", ops) == 2
  # LEFT( is a function, LEFT JOIN is a clause; FOR UPDATE is one clause, not an UPDATE statement.
  joins = _format_sql("SELECT LEFT(\"n\", 3) FROM t LEFT JOIN u ON t.a = u.a FOR UPDATE")
  @test occursin("LEFT(\"n\", 3)", joins)
  @test occursin("\nLEFT JOIN u ON", joins)
  @test occursin("\nFOR UPDATE", joins)
  @test !occursin("\nUPDATE", joins)
  # A data-modifying CTE: the UPDATE after the CTE's closing parenthesis starts the statement.
  cte = _format_sql("WITH source(a) AS (SELECT 1) UPDATE t SET a = source.a FROM source WHERE t.id = 1")
  @test occursin("\nUPDATE t", cte)
  # SELECT DISTINCT keeps DISTINCT on the head line.
  @test startswith(_format_sql("SELECT DISTINCT \"a\", \"b\" FROM t"), "SELECT DISTINCT\n  \"a\",\n  \"b\"\nFROM t")
  # A qualified name is a column, not a clause: `Tb.from` must not break before `from`.
  @test occursin("Tb.from", _format_sql("SELECT Tb.from FROM t"))
  # `WITH TIME ZONE` after a type's `(3)` is part of the type, not a CTE list.
  # At statement level, where PostgreSQL renders a cast as `(…)::type` — inside CAST(…) clause
  # keywords are never checked, so only this spelling exercises the rule.
  @test occursin("TIMESTAMP(3) WITH TIME ZONE AS t,", _format_sql("SELECT (\"d\")::TIMESTAMP(3) WITH TIME ZONE AS t, b FROM t"))
  # Empty and whitespace-only input.
  @test _format_sql("") == ""
  @test _format_sql("   \n ") == ""
end

# ─────────────────────────────────────────────────────────────────────────────
# :pretty: lexical edge cases that would change a value or throw
# Each of these was found by the #48 review fuzzing the formatter. An E'…' string escapes with a
# backslash, so `\'` must not end it (else a keyword inside gains a line break and the value
# changes). Two literals separated by a newline are one literal in PostgreSQL, and a space there
# is a syntax error. A no-break space is an identifier byte to PostgreSQL, not a separator. And a
# malformed UTF-8 byte must pass through as a token instead of throwing.
# ─────────────────────────────────────────────────────────────────────────────
@testset "show_query = :pretty: escape strings, continuation, non-ASCII, malformed bytes" begin
  estr = "SELECT E'it\\'s FROM here' FROM t"
  @test occursin("E'it\\'s FROM here'", _format_sql(estr))
  cont = "SELECT 'foo'\n'bar' FROM t"
  @test occursin("'foo'\n", _format_sql(cont)) && !occursin("'foo' 'bar'", _format_sql(cont))
  @test _format_sql(_format_sql(cont)) == _format_sql(cont)
  nbsp = "SELECT a b FROM t"
  @test occursin("a b", _format_sql(nbsp))
  # Glued to a keyword: `a FROM` is ONE identifier to PostgreSQL, so no break may split it.
  @test occursin("a FROM", _format_sql("SELECT a FROM t"))
  bad = "SELECT \"x\" FROM t WHERE a = '\xc1\x91' AND b\xff = 1"
  out = _format_sql(bad)
  # PCRE cannot scan malformed UTF-8, so compare with whitespace filtered character by character.
  ascii_squash(x) = filter(c -> !(c in (' ', '\t', '\n', '\r')), x)
  @test ascii_squash(out) == ascii_squash(bad)
  @test occursin('\n', out)   # it still reflowed: WHERE is on its own line
end

# ─────────────────────────────────────────────────────────────────────────────
# :pretty through every terminal
# `:pretty` is one arm of the `_show_query_result` dispatcher, so every terminal that takes
# `show_query` reaches it: reads, count/exists, writes, delete and bulk. Each returns the formatted
# string of exactly the statement `:sql` returns.
# ─────────────────────────────────────────────────────────────────────────────
@testset "show_query = :pretty reaches every terminal" begin
  M = FmtPG
  q = M.Race.objects.filter("year" => 1991).values("name")
  @test show_query(q, :pretty) == _format_sql(show_query(q, :sql))
  @test q.list(show_query = :pretty) == _format_sql(q.list(show_query = :sql))
  @test M.Race.objects.filter("year" => 1991).count(show_query = :pretty) ==
        _format_sql(M.Race.objects.filter("year" => 1991).count(show_query = :sql))
  @test M.Race.objects.filter("year" => 1991).exists(show_query = :pretty) ==
        _format_sql(M.Race.objects.filter("year" => 1991).exists(show_query = :sql))
  @test M.Race.objects.create("year" => 1991, "name" => "x", "circuitid" => 1, show_query = :pretty) ==
        _format_sql(M.Race.objects.create("year" => 1991, "name" => "x", "circuitid" => 1, show_query = :sql))
  @test M.Race.objects.filter("year" => 1991).update("name" => "y", show_query = :pretty) ==
        _format_sql(M.Race.objects.filter("year" => 1991).update("name" => "y", show_query = :sql))
  @test M.Result.objects.filter("raceid" => 7).delete(show_query = :pretty) ==
        _format_sql(M.Result.objects.filter("raceid" => 7).delete(show_query = :sql))
  df = DataFrame(raceid = [1], points = [10], positionorder = [1])
  @test bulk_insert(M.Result, df; show_query = :pretty) == _format_sql(bulk_insert(M.Result, df; show_query = :sql))
  # An unknown mode names :pretty among the valid ones.
  err = try show_query(q, :prettty); nothing catch e; e end
  @test err isa PormG.PormGError
  @test occursin(":pretty", sprint(showerror, err))
end
