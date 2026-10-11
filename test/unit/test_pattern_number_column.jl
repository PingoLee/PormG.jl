"""
#1168 — a pattern lookup (`@contains`, `@startswith`, …) on a number column.

Since #1086 the value of a pattern lookup is a text fragment on every column, but a number column was
still rendered as written: `"grid" LIKE \$1`, which PostgreSQL rejects (it has no `LIKE` for a number)
while SQLite matched the number's text. An integer prints the same digits on both engines, so it now
reads as that text — `CAST(col AS text)` on PostgreSQL, the column itself on SQLite, the read #1086
gave a date part. A float or a decimal prints different text per engine (`2.0` is `2` on PostgreSQL
and `2.0` on SQLite), so one fragment would select different rows: it is refused on both engines.

Everything renders through mock connections — no live database, no fixture.

julia --project=test/integration test/unit/test_pattern_number_column.jl
"""

using Test
using PormG
using PormG.Models
using PormG.QueryBuilder: inspect_query
using PormG.Functions: Count, Avg, Sum, Max, Cast
using PormG.QueryBuilder: Subquery, OuterRef, F, CTE

# Dedicated config key + mock types: `runtests.jl` includes every unit file into one `Main`, so a
# shared key would let another file's settings decide this file's dialect.
struct PncMockSQLite <: PormG.PormGSQLite end
struct PncMockPostgres <: PormG.PormGPostgres end
const _PNC_SL = PncMockSQLite()
const _PNC_PG = PncMockPostgres()
PormG.backend_sqlite_version(::PncMockSQLite) = 3045000

PormG.config["pnc_mock"] = PormG.Configuration.Settings(
  connections = _PNC_SL, change_data = true, db_def_folder = "pnc_mock",
)

# The F1 result shape, with one column of each number kind: integer, bigint, a relation (an integer
# key), float and decimal, plus a date for the #1086 date-part arm.
module PncModels
import PormG
import PormG.Models

Pnc_driver = Models.Model("pnc_driver",
  driverid = Models.IDField(),
  surname  = Models.CharField(),
  height   = Models.FloatField(null = true),   # a float one hop away, for the CTE-prefix case
)

Pnc_result = Models.Model("pnc_result",
  resultid        = Models.IDField(),
  driverid        = Models.ForeignKey(Pnc_driver, pk_field = "driverid", on_delete = "CASCADE"),
  grid            = Models.IntegerField(),
  milliseconds    = Models.BigIntegerField(null = true),
  fastestlapspeed = Models.FloatField(null = true),
  points          = Models.DecimalField(max_digits = 8, decimal_places = 2),
  date            = Models.DateField(null = true),
)

PormG.Models.set_models(@__MODULE__, "pnc_mock")
end

const PNC = PncModels
const _PNC_BACKENDS = (("PostgreSQL", _PNC_PG), ("SQLite", _PNC_SL))

_pnc_inspect(f, conn) = inspect_query((q = PNC.Pnc_result.objects; f(q); q); connection = conn)
_pnc_sql(f, conn)     = _pnc_inspect(f, conn)[:sql_text]
_pnc_params(f, conn)  = _pnc_inspect(f, conn)[:parameters]
_pnc_refusal(f, conn) = try _pnc_sql(f, conn); nothing catch e; e end

# The text a pattern lookup reads from `col` on each engine.
_pnc_read(col, conn) = conn isa PormG.PormGPostgres ? "CAST($(col) AS text)" : col

# ─────────────────────────────────────────────────────────────────────────────
# An integer column reads as its digits on both engines. Before #1168 PostgreSQL got the bare column
# — `"Tb"."grid" LIKE $1`, a server error, as there is no `LIKE` for `integer` — while SQLite ran
# the same `LIKE` over the number's text. The cast is the read #1086 gave a date part; the value is
# the same text fragment on both, with the wildcards the lookup adds.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1168: a pattern lookup on an integer column reads its digits" begin
  for (backend, conn) in _PNC_BACKENDS
    @testset "$backend" begin
      for col in ("grid", "milliseconds", "driverid")
        read = _pnc_read("\"Tb\".\"$(col)\"", conn)
        sql = _pnc_sql(q -> q.filter("$(col)__@contains" => "x"), conn)
        @test occursin("$(read) LIKE ", sql)
        @test _pnc_params(q -> q.filter("$(col)__@contains" => "x"), conn) == ["%x%"]
        # The other pattern spellings take the same read: a prefix, a negation, a case-insensitive one.
        @test occursin("$(read) LIKE ", _pnc_sql(q -> q.filter("$(col)__@startswith" => "1"), conn))
        @test occursin("$(read) NOT LIKE ", _pnc_sql(q -> q.filter("$(col)__@ncontains" => "1"), conn))
        @test occursin(read, _pnc_sql(q -> q.filter("$(col)__@iendswith" => "1"), conn))
        # The verbatim pattern lookups read the same text: `@iexact` on both engines, `@regex` where
        # the engine has it (PostgreSQL; SQLite refuses it as a missing feature).
        @test occursin(read, _pnc_sql(q -> q.filter("$(col)__@iexact" => "1"), conn))
        conn isa PormG.PormGPostgres &&
          @test occursin("$(read) ~ ", _pnc_sql(q -> q.filter("$(col)__@regex" => "^1"), conn))
      end
      # A non-pattern lookup still compares the number itself: no cast, and the value is a number.
      sql = _pnc_sql(q -> q.filter("grid" => 1), conn)
      @test occursin("\"Tb\".\"grid\" = ", sql)
      @test !occursin("CAST", sql)
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# A float or a decimal column is refused on both engines, with `FilterError`. Its text differs per
# engine — `2.0` prints `2` on PostgreSQL and `2.0` on SQLite, a `numeric(8,2)` `2.00` against the `2`
# SQLite stores — so one fragment would select different rows. Before #1168 PostgreSQL failed at the
# server and SQLite ran it. The refusal names the column and the explicit spelling, a `Cast` to text.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1168: a pattern lookup on a float or decimal column is refused" begin
  for (backend, conn) in _PNC_BACKENDS
    @testset "$backend" begin
      for col in ("fastestlapspeed", "points"), op in ("contains", "startswith", "nicontains", "iexact")
        e = _pnc_refusal(q -> q.filter("$(col)__@$(op)" => "2"), conn)
        @test e isa PormG.FilterError
        msg = sprint(showerror, e)
        @test occursin("'$(col)'", msg)
        @test occursin("not an integer", msg)
        @test occursin("Cast(", msg)
      end
      # A comparison on the same column still builds: only the pattern lookups are refused.
      @test occursin("\"Tb\".\"points\" >= ", _pnc_sql(q -> q.filter("points__@gte" => 2), conn))
      # The explicit spelling builds: a text alias, matched as the engine's own text.
      sql = _pnc_sql(q -> (q.values("resultid", "t" => Cast("fastestlapspeed", "text"));
                           q.filter("t__@startswith" => "2")), conn)
      @test occursin("LIKE", sql)
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# A number reached through a relation is the joined column's kind: an integer key reads as its
# digits, a joined float is refused. The joined arm resolves the field from the #474 memo, not the
# model's own fields, so it is a separate path from the testsets above.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1168: a joined number column takes the same rule" begin
  for (backend, conn) in _PNC_BACKENDS
    @testset "$backend" begin
      q = PNC.Pnc_driver.objects
      sql = inspect_query((q.filter("pnc_result__grid__@startswith" => "1"); q.distinct(); q); connection = conn)[:sql_text]
      @test occursin(_pnc_read("\"Tb_1\".\"grid\"", conn) * " LIKE ", sql)
      q = PNC.Pnc_driver.objects
      e = try inspect_query((q.filter("pnc_result__fastestlapspeed__@contains" => "2"); q.distinct(); q); connection = conn); nothing catch err; err end
      @test e isa PormG.FilterError
      @test occursin("pnc_result__fastestlapspeed", sprint(showerror, e))
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# A projection alias decides by its expression's kind, in both clauses an alias filter reaches: a
# `Count` is an integer and reads as its digits; an `Avg` or a decimal `Sum` is refused. This is the
# HAVING arm (`_render_alias_predicate`), which has no field to ask — only the alias's kind tells an
# integer from a float there, as both resolve to the number formatter.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1168: a number alias reads or refuses by its kind" begin
  for (backend, conn) in _PNC_BACKENDS
    @testset "$backend" begin
      sql = _pnc_sql(q -> (q.values("driverid", "n" => Count("resultid")); q.filter("n__@startswith" => "1")), conn)
      @test occursin(_pnc_read("COUNT(\"Tb\".\"resultid\")", conn) * " LIKE ", sql)
      for agg in (Avg("grid"), Sum("points"))
        e = _pnc_refusal(q -> (q.values("driverid", "a" => agg); q.filter("a__@startswith" => "1")), conn)
        @test e isa PormG.FilterError
        @test occursin("'a'", sprint(showerror, e))
      end
      # A non-aggregate alias filters in WHERE, and takes the kind its cast declares: an integer
      # reads as its digits, a float is refused.
      sql = _pnc_sql(q -> (q.values("resultid", "g" => Cast("milliseconds", "integer"));
                           q.filter("g__@startswith" => "1")), conn)
      cast = conn isa PormG.PormGPostgres ? "(\"Tb\".\"milliseconds\")::integer" :
                                             "CAST(\"Tb\".\"milliseconds\" AS INTEGER)"
      @test occursin("WHERE " * _pnc_read(cast, conn) * " LIKE ", sql)
      e = _pnc_refusal(q -> (q.values("resultid", "s" => Cast("grid", "float8"));
                             q.filter("s__@startswith" => "1")), conn)
      @test e isa PormG.FilterError
      @test occursin("not an integer", sprint(showerror, e))
      # Arithmetic over a decimal column is a decimal, refused like the column itself.
      e = _pnc_refusal(q -> (q.values("resultid", "m" => F("points") + 1); q.filter("m__@startswith" => "1")), conn)
      @test e isa PormG.FilterError
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# The #1086 date-part read is unchanged: a date part is an integer through its own formatter, ahead
# of the number rule, so `@year__@startswith` still reads its digits on both engines.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1168: a date part still reads as its digits (#1086)" begin
  for (backend, conn) in _PNC_BACKENDS
    @testset "$backend" begin
      sql = _pnc_sql(q -> q.filter("date__@year__@startswith" => "200"), conn)
      @test occursin("LIKE", sql)
      @test _pnc_params(q -> q.filter("date__@year__@startswith" => "200"), conn) == ["200%"]
      conn isa PormG.PormGPostgres && @test occursin("AS text) LIKE", sql)
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# A number PormG cannot type is refused too: it cannot say which text the engine would match. A
# `Subquery` alias is one today — the walk gives a subquery its READ kind, which names no integer —
# so even an integer subquery is refused, on both engines (SQLite used to match its text). This pins
# the untyped half of the rule: a mutant reading an untyped number as an integer turns it into a cast.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1168: a number PormG cannot type is refused" begin
  for (backend, conn) in _PNC_BACKENDS
    @testset "$backend" begin
      e = _pnc_refusal(q -> (q.values("resultid", "s" => Subquery(PNC.Pnc_result.objects.
                               filter("resultid" => OuterRef("resultid")).values("grid")));
                             q.filter("s__@startswith" => "1")), conn)
      @test e isa PormG.FilterError
      @test occursin("cannot type", sprint(showerror, e))
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# A CTE column takes the kind of the CTE body's expression. Its memo field is a surrogate, which types
# every `Count`/`Sum` as an `IntegerField` and an `Avg` as its operand, so before the review fix a
# CTE's `Avg("grid")` — a numeric, printed `5.5000000000000000` on PostgreSQL and `5.5` on SQLite —
# read as an integer's digits on PostgreSQL and answered different rows per engine, silently. An
# integer CTE column (`Count`, `Max` over an integer, a plain key) still reads as its digits.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1168: a CTE column reads or refuses by its body's kind" begin
  with_best(q, agg) = (q.with("best" => PNC.Pnc_result.objects.values("driverid", "best" => agg),
                              join_field = "driverid" => "driverid", join_type = "INNER");
                       q.values("resultid"))
  for (backend, conn) in _PNC_BACKENDS
    @testset "$backend" begin
      for agg in (Avg("grid"), Sum("points"), Sum("fastestlapspeed"))
        e = _pnc_refusal(q -> (with_best(q, agg); q.filter("best__best__@endswith" => "0")), conn)
        @test e isa PormG.FilterError
        @test occursin("not an integer", sprint(showerror, e))
      end
      for agg in (Count("resultid"), Max("grid"))
        sql = _pnc_sql(q -> (with_best(q, agg); q.filter("best__best__@startswith" => "1")), conn)
        @test occursin(_pnc_read("\"R1_1\".\"best\"", conn) * " LIKE ", sql)
      end
      # A CTE name may hold `__`, which only the handle can address: the CTE is the longest declared
      # name, so `my__cte`'s `Avg` is refused rather than read through a CTE named `my`.
      e = _pnc_refusal(q -> (q.with("my__cte" => PNC.Pnc_result.objects.values("driverid", "best" => Avg("grid")),
                                    join_field = "driverid" => "driverid", join_type = "INNER");
                             q.values("resultid"); q.filter(CTE("my__cte", "best__@startswith") => "1")), conn)
      @test e isa PormG.FilterError
      # Two CTE names where one is a `__`-prefix of the other: the memo name cannot say which one the
      # SQL reads (the string spelling resolves `best`, a handle may name `best__driverid`), so when the
      # two columns disagree the operand is untyped and refused — never cast on a guess, which could
      # read a float as an integer's digits.
      e = _pnc_refusal(q -> (q.with("best" => PNC.Pnc_result.objects.values("driverid", "n" => Count("resultid")),
                                    join_field = "driverid" => "driverid", join_type = "INNER");
                             q.with("best__driverid" => PNC.Pnc_result.objects.values("resultid", "driverid" => Avg("grid")),
                                    join_field = "resultid" => "resultid", join_type = "INNER");
                             q.values("resultid"); q.filter("best__driverid__driverid__@startswith" => "1")), conn)
      @test e isa PormG.FilterError
      # The silent direction of the same ambiguity: the string path reads `best`'s key hop to the
      # driver's FLOAT `height`, while `best__driverid` projects an integer `height`. Trusting either
      # one alone could cast the float on PostgreSQL; they disagree, so it is refused.
      e = _pnc_refusal(q -> (q.with("best" => PNC.Pnc_result.objects.values("driverid", "n" => Count("resultid")),
                                    join_field = "driverid" => "driverid", join_type = "INNER");
                             q.with("best__driverid" => PNC.Pnc_result.objects.values("resultid", "height" => Count("grid")),
                                    join_field = "resultid" => "resultid", join_type = "INNER");
                             q.values("resultid"); q.filter("best__driverid__height__@startswith" => "1")), conn)
      @test e isa PormG.FilterError
      # The handle spelling of an integer CTE column reads as its digits, like the string path.
      sql = _pnc_sql(q -> (with_best(q, Count("resultid")); q.filter(CTE("best", "best__@startswith") => "1")), conn)
      @test occursin(_pnc_read("\"R1_1\".\"best\"", conn) * " LIKE ", sql)
    end
  end
end
