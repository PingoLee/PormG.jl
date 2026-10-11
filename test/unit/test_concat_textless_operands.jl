"""
`Concat` refuses an operand that is not text: a boolean, a float or a decimal (#1027).

#1006 made both engines skip a NULL operand. The second question is which text a non-text operand
becomes. PostgreSQL's `CONCAT` calls the type's output function; SQLite's `||` uses its own number
formatting, on top of PormG's SQLite storage (a boolean is `0`/`1`, a decimal an integer or a REAL,
#648):

| operand                         | PostgreSQL (measured on 16.15) | SQLite 3.45.1 |
|---------------------------------|--------------------------------|---------------|
| `true`                          | `t`                            | `1`           |
| float `25.0`                    | `25`                           | `25.0`        |
| `DecimalField` `1.50` / `3`     | `1.50` / `3.00`                | `1.5` / `3`   |
| `Mod(7, 3)`, `Avg`, `Round`, …  | `numeric`                      | a REAL (`1.0`)|

Each of those is one engine's own spelling of the value, and neither is what the query asked for:
`Concat("surname", "-", "points")` does not say which text of `points` it means. #1147 step 2 files
this under EXPLICIT INTENT — Django's `output_field` rule, not parity — so it is refused on every
engine, the message naming no engine and the spelling that says it: `Cast("points", "text")`, which
builds everywhere and writes each engine's own text, or a `Case` for a boolean. A literal is refused
when the `Concat` is built, a column once its path resolves. Integer, text and date operands pass
unchanged.

One operand is a question of MEANING instead: an integer quotient PostgreSQL computes as `numeric`
(`sum(bigint)` the type walk cannot name, divided — `7.5` where the quotient means `7`). That one is
refused on PostgreSQL only (#1111) and built on SQLite.

Everything renders through mock connections — no live database, no fixture.

julia -O0 --project=test/integration test/unit/test_concat_textless_operands.jl
"""

using Test
using Dates
using Decimals
using PormG
using PormG.Models
using PormG.QueryBuilder: inspect_query
import PormG: QueryBuildError

# Dedicated config key + mock types: `runtests.jl` includes every unit file into one `Main`, so a
# shared key would let another file's settings decide this file's dialect.
struct CtoMockSQLite <: PormG.PormGSQLite end
struct CtoMockPostgres <: PormG.PormGPostgres end
const _CTO_SL = CtoMockSQLite()
const _CTO_PG = CtoMockPostgres()
PormG.backend_sqlite_version(::CtoMockSQLite) = 3045000

PormG.config["cto_mock"] = PormG.Configuration.Settings(
  connections = _CTO_SL, change_data = true, db_def_folder = "cto_mock",
)

# One column of every kind the rule names, plus the kinds it lets through, and a to-one relation so
# a joined path to a float is reachable.
module CtoModels
import PormG
import PormG.Models

Cto_team = Models.Model("cto_team",
  id     = Models.IDField(),
  name   = Models.CharField(),
  rating = Models.FloatField(null = true),
)
Cto_driver = Models.Model("cto_driver",
  id      = Models.IDField(),
  surname = Models.CharField(),
  number  = Models.IntegerField(null = true),
  born    = Models.DateField(null = true),
  active  = Models.BooleanField(null = true),
  points  = Models.FloatField(null = true),
  price   = Models.DecimalField(max_digits = 10, decimal_places = 2, null = true),
  team    = Models.ForeignKey(Cto_team, on_delete = "CASCADE"),
)

PormG.Models.set_models(@__MODULE__, "cto_mock")
end

const CTO = CtoModels
const Fn = PormG.Functions

_cto_sql(q; conn) = inspect_query(q; connection = conn)[:sql_text]
# A fresh queryset projecting `expr`, rendered on `conn`.
_cto_render(expr; conn) = _cto_sql((q = CTO.Cto_driver.objects; q.values("x" => expr); q); conn = conn)
# The refusal, on one engine, as the message text (ANSI-free off-TTY, so compare without it).
function _cto_refusal(expr; conn)
  err = try
    _cto_render(expr; conn = conn)
    nothing
  catch e
    e
  end
  return err
end
_cto_msg(e) = replace(sprint(showerror, e), r"\e\[[0-9;]*m" => "")
# An explicit-intent refusal names no engine: the query is refused for what it does not say, on all.
_cto_names_no_engine(msg) = !occursin("PostgreSQL", msg) && !occursin("SQLite", msg)

# ─────────────────────────────────────────────────────────────────────────────
# Concat: a boolean, float or decimal COLUMN operand is refused on every engine (explicit intent)
# The column's type is known only once its path resolves, so the refusal comes from the render
# (`_render_function_body`), not the constructor. Each is a `QueryBuildError` naming the column and
# #1027, raised on PostgreSQL and on SQLite alike because the QUERY is ambiguous, not an engine: the
# message names no engine (#1147 step 2) and gives the explicit spelling. Expected SQL: none.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1027: a Bool, Float or Decimal column operand is refused on every engine (explicit intent)" begin
  cases = [
    "active"        => (:bool,    "BooleanField `active`"),
    "points"        => (:float,   "FloatField `points`"),
    "price"         => (:decimal, "DecimalField `price`"),
    # A joined path ends at the related model's field (the join walk memoises it).
    "team__rating"  => (:float,   "FloatField `team__rating`"),
  ]
  for (path, (kind, named)) in cases, conn in (_CTO_PG, _CTO_SL)
    # The column is also built into the constructor fine — only the render can type it.
    expr = Fn.Concat("surname", Fn.Value("-"), path)
    err = _cto_refusal(expr; conn = conn)
    @test err isa QueryBuildError
    msg = _cto_msg(err)
    @test occursin("Concat joins text, and the $(named) is not text", msg)
    @test occursin("(#1027)", msg)
    # The advice matches the kind: a `Case` for a boolean (its cast to text is SQLite's `1`, a
    # question of meaning, #1028), and a cast to text naming the column for a number — which builds on
    # every engine and writes each one's own text (representation, #1147 step 2).
    @test occursin(kind === :bool ? "Case(When(\"$(path)\" => true" : "Cast(\"$(path)\", \"text\")", msg)
    @test _cto_names_no_engine(msg)
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# Concat: a boolean, float or decimal LITERAL is refused when the expression is built
# `_function_operand` turns `true` and `1.5` into `Value(...)`; an explicit `Value(Decimal)` is the
# third spelling. Their type is known at construction, so the `Concat(...)` call itself throws,
# before any queryset exists.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1027: a Bool, Float or Decimal literal is refused at construction" begin
  # Named by its type, never its value (#971, #1057).
  for (lit, named) in (true => "a Bool literal", false => "a Bool literal",
                       1.5 => "a Float64 literal", Float32(2) => "a Float32 literal",
                       Fn.Value(true) => "a Bool literal", Fn.Value(25.0) => "a Float64 literal",
                       Fn.Value(Decimal(1.5)) => "a Decimal literal")
    err = try
      Fn.Concat("surname", lit)
      nothing
    catch e
      e
    end
    @test err isa QueryBuildError
    @test occursin("Concat joins text, and $(named) is not text", _cto_msg(err))
    @test _cto_names_no_engine(_cto_msg(err))
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# Concat: an EXPRESSION whose type is a boolean, float or decimal is refused on every engine
# The rule is the operand's type, not its spelling: a comparison and `Exists`-like booleans, an
# extremum or sum over a float, a cast or `output_field` naming one, arithmetic over one, and the
# functions PostgreSQL computes as `numeric` (`Avg`, `Round`, `Mod`, …) while SQLite answers a REAL.
# Explicit intent (#1147 step 2): one refusal per engine, the message naming neither.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1027: an expression typed boolean, float or decimal is refused on every engine (explicit intent)" begin
  F = PormG.QueryBuilder.F
  refused = [
    F("number") > 0,                                   # a comparison is a boolean (#949)
    Fn.Max("active"),                                  # an extremum keeps its operand's type
    Fn.Sum("points"),
    Fn.Coalesce("points", 0),                          # numeric promotion: any float operand
    Fn.Cast("number", "double precision"),             # a declared type decides
    Fn.Cast("number", Models.DecimalField()),
    Fn.Coalesce("number", 0; output_field = Models.FloatField()),
    F("points") * 2,                                   # arithmetic over a float
    Fn.Avg("number"),                                  # numeric on PostgreSQL, REAL on SQLite
    Fn.Round("number"),
    Fn.Mod("number", 3),
    Fn.Sqrt("number"),
    Fn.Floor("points"),                                # numeric over a float operand
    # Review of #1027: one per arm, so each survives no mutant.
    F("number") * 1.5,                                 # the RIGHT side decides arithmetic too
    Fn.Min("price"),                                   # an extremum over a decimal
    Fn.Greatest("number", "points"),                   # any operand decides, not the first
    Fn.Abs("points"), Fn.Ceil("points"), Fn.NullIf("points", 0), Fn.Least("number", "price"),
    Fn.Lag("points"), Fn.FirstValue("price"),          # window value functions return the operand
    Fn.Lead("points"), Fn.LastValue("price"), Fn.NthValue("points", 2),
    Fn.Lag("active"),                                  # ... a boolean one too
    Fn.Power("number", 2), Fn.Exp("number"), Fn.Ln("number"),
    PormG.Q("active" => true),                         # a predicate is a boolean
  ]
  for expr in refused, conn in (_CTO_PG, _CTO_SL)
    err = _cto_refusal(Fn.Concat("surname", Fn.Value("-"), expr); conn = conn)
    @test err isa QueryBuildError
    @test occursin("(#1027)", _cto_msg(err))
    @test _cto_names_no_engine(_cto_msg(err))
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# Concat: the refusal names the operand and the spelling that says which text it means
# The message is the same on every engine: the operand is not text, so say which text (#1147 step 2).
# A number is pointed to a cast to text — naming the column when it is one, `<flag>` for a computed
# value — and never given an engine's own spelling of it (no `1` vs `1.0`, no `3.00` vs `3`). A
# boolean written as `F("active")` still names its column in the `Case` suggestion.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1027: the message fits the operand" begin
  F = PormG.QueryBuilder.F
  for conn in (_CTO_PG, _CTO_SL)
    msg(expr) = _cto_msg(_cto_refusal(Fn.Concat(Fn.Value("-"), expr); conn = conn))
    for (expr, named) in ((Fn.Mod("number", 3), "`MOD(…)`"), (Fn.Avg("number"), "`AVG(…)`"), (Fn.Round("number"), "`ROUND(…)`"))
      m = msg(expr)
      @test occursin("Concat joins text, and $(named) is not text: say which text you mean (#1027)", m)
      @test occursin("Cast it to text first: Cast(\"<flag>\", \"text\")", m)
      @test !occursin("3.00", m) && !occursin("1.0", m)
      @test _cto_names_no_engine(m)
    end
    @test occursin("the DecimalField `price` is not text", msg("price"))
    @test occursin("Cast(\"price\", \"text\")", msg("price"))
    @test occursin("`MAX(…)` over the FloatField `points`", msg(Fn.Max("points")))
    @test occursin("Case(When(\"active\" => true", msg(F("active")))
    @test occursin("Case(When(\"<flag>\" => true", msg(F("number") > 0))
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# Concat: a Joined(...) or CTE(...) handle to a float is refused, and named as written
# A handle resolves to a column through its own memo namespace (`memo_key(ref)`), not the model's
# fields, so it is a separate arm of the classifier. A text column through the same handle passes.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1027: Joined and CTE handles" begin
  joined() = (q = CTO.Cto_driver.objects;
              q.cjoin_on("Cto_team", alias = "t", on = [PormG.Joined("t", "id") == PormG.QueryBuilder.F("team")]); q)
  withcte() = (q = CTO.Cto_driver.objects;
               c = CTO.Cto_team.objects; c.values("id", "name", "rating");
               q.with("tc" => c, join_field = "team" => "id"); q)
  for conn in (_CTO_PG, _CTO_SL)
    for (mk, float_ref, text_ref, named) in (
        (joined, PormG.Joined("t", "rating"), PormG.Joined("t", "name"), "FloatField `Joined(\"t\", \"rating\")`"),
        (withcte, PormG.CTE("tc", "rating"), PormG.CTE("tc", "name"), "FloatField `CTE(\"tc\", \"rating\")`"))
      q = mk(); q.values("x" => Fn.Concat(Fn.Value("-"), float_ref))
      err = try _cto_sql(q; conn = conn); nothing catch e; e end
      @test err isa QueryBuildError
      @test occursin(named, _cto_msg(err))
      q = mk(); q.values("x" => Fn.Concat(Fn.Value("-"), text_ref))
      @test !isempty(_cto_sql(q; conn = conn))
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# Concat: a Subquery operand is classified by the one expression it projects (#1124)
# The classifier had no `Subquery` arm: a subquery was typed only through the read kind and the
# formatter its render records, and neither names a float (no read kind; the number formatter is
# the integer's too), a decimal or a literal. So `Concat(…, Subquery(<float>))` built — and the two
# engines printed the number differently — while the same float directly was refused. The inner
# build now records its projection's own classification under the node (as #929 records the
# formatter), so the subquery answers what its expression answers alone. The way out is the cast
# INSIDE the subquery, where the #1028 rules already decide what reads the same.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1124: a Subquery operand is classified by its projection" begin
  team(expr) = (s = CTO.Cto_team.objects; s.filter("id" => PormG.OuterRef("team")); s.values("t" => expr); PormG.Subquery(s))
  self(expr) = (s = CTO.Cto_driver.objects; s.filter("id" => PormG.OuterRef("id")); s.values("t" => expr); PormG.Subquery(s))
  for conn in (_CTO_PG, _CTO_SL)
    for (sub, named) in ((team("rating"), "a Subquery projecting the FloatField `rating`"),
                         (team(Fn.Max("rating")), "a Subquery projecting `MAX(…)` over the FloatField `rating`"),
                         (team(Fn.Avg("rating")), "a Subquery projecting `AVG(…)`"),
                         (self("price"), "a Subquery projecting the DecimalField `price`"),
                         (self("active"), "a Subquery projecting the BooleanField `active`"),
                         (team(Fn.Value(true)), "a Subquery projecting a Bool literal"),
                         (team(Fn.Value(1.5)), "a Subquery projecting a Float64 literal"),
                         # A subquery projecting a subquery: the record is read through the inner one.
                         (self(team("rating")), "a Subquery projecting a Subquery projecting the FloatField `rating`"))
      err = _cto_refusal(Fn.Concat("surname", Fn.Value(": "), sub); conn = conn)
      @test err isa QueryBuildError
      @test occursin("(#1027)", _cto_msg(err))
      @test occursin(named, _cto_msg(err))
    end
    # The same subquery with a projection that has one text builds: a text or integer column, a
    # count, and the float rounded to an integer inside the subquery (#1028's own escape).
    for sub in (team("name"), team(Fn.Count("id")), self("number"),
                team(Fn.Cast(Fn.Round("rating"), Models.IntegerField())))
      sql = _cto_render(Fn.Concat("surname", Fn.Value(": "), sub); conn = conn)
      @test occursin(conn === _CTO_PG ? "CONCAT(" : "COALESCE(", sql)
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# Concat: integer, text and date operands, and explicit text, pass unchanged
# The refusal is narrow by design: an integer has one base-10 text and a date its ISO text on both
# engines, and a cast to text or an integer passes when its operand has one text (#1028 refuses the
# rest at the cast). Each renders on both engines, and the SQLite form is the #1006 COALESCE
# shape, so the check added no SQL.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1027: integer, text, date and explicit-text operands pass" begin
  F = PormG.QueryBuilder.F
  allowed = [
    "number", "surname", "born", "born__@year", "team__name", F("number"), F("number") + 1,
    Fn.Value("-"), Fn.Value(7), 7, Date(2024, 1, 5),
    # A cast to text is the explicit spelling, and builds on every engine: over an integer, and over a
    # float or a decimal too, each engine writing its own text (`'25'` / `'25.0'`, representation,
    # #1147 step 2). A boolean's cast to text is refused on SQLite only — `test_cast_divergent_operands.jl`.
    Fn.Cast("number", Models.CharField()),             # explicit text over an integer
    Fn.Cast("points", Models.CharField()),             # explicit text over a float
    Fn.Cast("price", "text"),                          # explicit text over a decimal
    Fn.Cast(Fn.Round("price"), Models.IntegerField()), # explicit integer, rounded first
    Fn.Floor("number"),                                # integer operand: '7' on both
    Fn.Max("number"), Fn.Count("id"), Fn.Length("surname"),
    Fn.Case(Fn.When("active" => true, then = Fn.Value("yes")), default = "no"),  # the documented escape
  ]
  for expr in allowed, conn in (_CTO_PG, _CTO_SL)
    # No bare column beside the operand: an aggregate one (`Max`, `Count`) would otherwise trip the
    # #798 mixed-grouping guard, which is not what this file tests.
    sql = _cto_render(Fn.Concat(Fn.Value("-"), expr); conn = conn)
    @test occursin(conn === _CTO_PG ? "CONCAT(" : "COALESCE(", sql)
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# Concat: an integer quotient is an integer on both engines, a shifted sum included (#1111, #1147, #1153)
# The one `Concat` operand that is a question of MEANING, not explicit intent: an integer divided is
# an integer quotient (`15 / 2` is `7`), and the operand's text is that integer's. PostgreSQL widens
# `sum(bigint)` to `numeric`, which kept the half once divided (`7.5`), so #1111 refused it there.
# A `Sum` the type walk names a `bigint` renders `SUM(x)::bigint` on PostgreSQL (#1147), and since
# #1153 the walk names a shift too (`F("id") << 1` has its left operand's type), so both divide as
# integers and build. Expected SQL, PostgreSQL: `(SUM(("Tb"."id" << $2::integer))::bigint / $3::bigint)`.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1111, #1153: Concat over an integer quotient builds on both engines, a shifted sum included" begin
  F = PormG.QueryBuilder.F
  shifted = Fn.Concat(Fn.Value("-"), Fn.Sum(F("id") << 1) / 2)
  for conn in (_CTO_PG, _CTO_SL)
    @test _cto_refusal(shifted; conn = conn) === nothing
    # The sum the walk named before #1153 is normalized on PostgreSQL the same way.
    @test _cto_refusal(Fn.Concat(Fn.Value("-"), Fn.Sum("id") / 2); conn = conn) === nothing
  end
  @test occursin("(SUM((\"Tb\".\"id\" << \$2::integer))::bigint / \$3::bigint)", _cto_render(shifted; conn = _CTO_PG))
  @test occursin("SUM((\"Tb\".\"id\" << ?)) / ?", _cto_render(shifted; conn = _CTO_SL))
  @test occursin("(SUM(\"Tb\".\"id\")::bigint / \$2::bigint)", _cto_render(Fn.Concat(Fn.Value("-"), Fn.Sum("id") / 2); conn = _CTO_PG))
end

# ─────────────────────────────────────────────────────────────────────────────
# Concat: the year-qualified labels (#997) are unaffected
# `@yyyy_q` / `@yyyy_quad` expand to a `Concat` of `Cast(Year(x), CharField())`, `Value("-Q")` and
# a `Case` of text labels. They render through the same arm, so this pins that none of their
# operands is read as a number or a boolean.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1027: the @yyyy_q / @yyyy_quad labels still render" begin
  for key in ("yyyy_q", "yyyy_quad"), conn in (_CTO_PG, _CTO_SL)
    # A bare `||` chain on both engines (`propagate_null`, #997), projected and filtered.
    @test occursin(" ||", _cto_sql((q = CTO.Cto_driver.objects; q.values("x" => "born__@$(key)"); q); conn = conn))
    q = CTO.Cto_driver.objects
    q.filter("born__@$(key)" => "2024-Q1")
    @test occursin(" ||", _cto_sql(q; conn = conn))
  end
end
