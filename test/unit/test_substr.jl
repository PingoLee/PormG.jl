"""
Unit coverage for #1332 — `Substr(x, pos, len = nothing)`, part of a string in an expression.

Before #1332 the catalog had no substring function, so a prefix — the driver code from the surname,
a comparison of two columns' first letters — needed raw SQL or a fetch and a Julia `first(s, n)`.
`Substr` renders `SUBSTR(x, pos[, len])` on every engine.

What is pinned here, and why each part matters:

  - **The SQL and the parameter vector, exactly, on PostgreSQL and SQLite.** `pos` and `len` are
    bound, in text order; a misbind is silent wrong data. PostgreSQL casts both to `integer`,
    because a bound `Int` is `bigint` and there is no `substr(text, bigint, bigint)`. SQLite's
    flattened vector is checked against PostgreSQL's `\$N` text order (`_pg_text_order`).
  - **Every place the issue names**: `filter` against a literal and against `F(...)`, `values`,
    `update`, an `on()` path condition and a `cjoin_on` condition over `Joined(...)`.
  - **The range the engines agree on.** A position from 1 and a length from 0, both at most
    `typemax(Int32)`. Everything else raises `InvalidValueError` when the expression is built: a
    negative position counts from the end on SQLite and MySQL and gives `''` on PostgreSQL, and a
    negative length raises on PostgreSQL while SQLite returns the characters before `pos`.
  - **The text operand.** A typed operand that is not text raises `QueryBuildError` on every
    engine (PostgreSQL has no `substr(integer, …)`; SQLite takes part of the number's text).
  - **Two prefixes compared.** A filter pair takes a function on its right, so
    `values("initial" => Substr(a, 1, 1)).filter("initial" => Substr(b, 1, 1))` compares them, all
    four values bound in text order. The `==` operator does not take one yet
    (`Substr(a) == Substr(b)` raises, as `Lower(a) == Lower(b)` does); that gap belongs to every
    function, not to `Substr`.

Everything renders through mock connections — no live database. Run alone:

    julia --project=test/integration test/unit/test_substr.jl
"""

using Test
using PormG
using PormG.Models
using PormG.Functions
using PormG.QueryBuilder: inspect_query
using PormG: Joined
import Dates
isdefined(Main, :SQLite) || include(joinpath(@__DIR__, "..", "load_drivers.jl"))
isdefined(Main, :_pg_text_order) || include(joinpath(@__DIR__, "helper_marker_alignment.jl"))

# Dedicated config keys + mock types: `runtests.jl` includes every unit file into one `Main`. Two
# keys, because `update` renders on the model's own connection — one model module per engine.
struct SubMockSQLite <: PormG.PormGSQLite end
struct SubMockPostgres <: PormG.PormGPostgres end
const _SUB_SL = SubMockSQLite()
const _SUB_PG = SubMockPostgres()
PormG.backend_sqlite_version(::SubMockSQLite) = 3045000

PormG.config["sub_mock_sl"] = PormG.Configuration.Settings(
  connections = _SUB_SL, change_data = true, db_def_folder = "sub_mock_sl",
)
PormG.config["sub_mock_pg"] = PormG.Configuration.Settings(
  connections = _SUB_PG, change_data = true, db_def_folder = "sub_mock_pg",
)

# A driver-shaped table: text, one column of each non-text kind, a relation to an integer key and
# one to a text key; and a result table pointing at it, for the join conditions.
module SubModelsSL
import PormG
import PormG.Models
Sub_team = Models.Model("sub_team", id = Models.IDField(), name = Models.CharField())
Sub_code = Models.Model("sub_code", code = Models.CharField(primary_key = true), label = Models.CharField())
Sub_driver = Models.Model("sub_driver",
  id       = Models.IDField(),
  forename = Models.CharField(),
  surname  = Models.CharField(),
  code     = Models.CharField(null = true),
  team     = Models.ForeignKey(Sub_team, on_delete = "CASCADE", null = true),
  cc       = Models.ForeignKey(Sub_code, on_delete = "CASCADE", null = true),
  number   = Models.IntegerField(null = true),
  points   = Models.FloatField(null = true),
  dob      = Models.DateField(null = true),
  seen     = Models.DateTimeField(null = true),
  active   = Models.BooleanField(null = true),
  ref      = Models.UUIDField(null = true),
  extra    = Models.JSONField(null = true),
)
Sub_result = Models.Model("sub_result",
  id     = Models.IDField(),
  driver = Models.ForeignKey(Sub_driver, on_delete = "CASCADE", null = true),
  note   = Models.CharField(null = true),
)
PormG.Models.set_models(@__MODULE__, "sub_mock_sl")
end

module SubModelsPG
import PormG
import PormG.Models
Sub_team = Models.Model("sub_team", id = Models.IDField(), name = Models.CharField())
Sub_code = Models.Model("sub_code", code = Models.CharField(primary_key = true), label = Models.CharField())
Sub_driver = Models.Model("sub_driver",
  id       = Models.IDField(),
  forename = Models.CharField(),
  surname  = Models.CharField(),
  code     = Models.CharField(null = true),
  team     = Models.ForeignKey(Sub_team, on_delete = "CASCADE", null = true),
  cc       = Models.ForeignKey(Sub_code, on_delete = "CASCADE", null = true),
  number   = Models.IntegerField(null = true),
  points   = Models.FloatField(null = true),
  dob      = Models.DateField(null = true),
  seen     = Models.DateTimeField(null = true),
  active   = Models.BooleanField(null = true),
  ref      = Models.UUIDField(null = true),
  extra    = Models.JSONField(null = true),
)
Sub_result = Models.Model("sub_result",
  id     = Models.IDField(),
  driver = Models.ForeignKey(Sub_driver, on_delete = "CASCADE", null = true),
  note   = Models.CharField(null = true),
)
PormG.Models.set_models(@__MODULE__, "sub_mock_pg")
end

const _SUB_ENGINES = (("SQLite", _SUB_SL, SubModelsSL), ("PostgreSQL", _SUB_PG, SubModelsPG))

_sub_inspect(q, conn) = inspect_query(q; connection = conn)
_sub_flat(s::AbstractString) = replace(s, r"\s+" => " ")

# The rendered statement of a `values` projection over one expression, filtered so a parameter of
# the outer query follows the function's own.
function _sub_values(models, conn, expr)
  q = models.Sub_driver.objects
  q.filter("code" => "HAM")
  q.values("p" => expr)
  return _sub_inspect(q, conn)
end

# The QueryBuildError text a build raises, or `nothing` when it builds.
function _sub_refused(models, conn, expr)
  try
    _sub_values(models, conn, expr)
    nothing
  catch e
    e isa PormG.QueryBuildError || rethrow()
    sprint(showerror, e)
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# Substr renders SUBSTR and binds pos, then len, in text order
# `Substr("surname", 2, 3)` renders `SUBSTR(col, ($1::bigint)::integer, ($2::bigint)::integer)` on
# PostgreSQL and `SUBSTR(col, ?, ?)` on SQLite; with no `len`, the third argument is not rendered and
# nothing is bound for it. Then the outer WHERE value.
# Why: the order is the contract on SQLite's positional `?`, and PostgreSQL has no `bigint` substr.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1332: Substr renders and binds in text order on both engines" begin
  expected = Dict(
    ("SQLite", 3)     => "SUBSTR(\"Tb\".\"surname\", ?, ?) as \"p\"",
    ("SQLite", 2)     => "SUBSTR(\"Tb\".\"surname\", ?) as \"p\"",
    ("PostgreSQL", 3) => "SUBSTR(\"Tb\".\"surname\", (\$1::bigint)::integer, (\$2::bigint)::integer) as \"p\"",
    ("PostgreSQL", 2) => "SUBSTR(\"Tb\".\"surname\", (\$1::bigint)::integer) as \"p\"",
  )
  for (backend, conn, models) in _SUB_ENGINES
    @testset "$backend" begin
      r = _sub_values(models, conn, Substr("surname", 2, 3))
      @test occursin(expected[(backend, 3)], r[:sql_text])
      @test r[:parameters] == Any[2, 3, "HAM"]
      r = _sub_values(models, conn, Substr("surname", 4))
      @test occursin(expected[(backend, 2)], r[:sql_text])
      @test r[:parameters] == Any[4, "HAM"]
    end
  end
  # Two Substr in one projection list, beside a WHERE value: SQLite's vector is PostgreSQL's text order.
  build(models) = (q = models.Sub_driver.objects;
                   q.filter("code" => "HAM");
                   q.values("a" => Substr("surname", 2, 3), "b" => Substr("forename", 5));
                   q)
  pg = _sub_inspect(build(SubModelsPG), _SUB_PG)
  sl = _sub_inspect(build(SubModelsSL), _SUB_SL)
  @test _pg_text_order(pg) == Any[2, 3, 5, "HAM"]
  @test sl[:parameters] == _pg_text_order(pg)
end

# ─────────────────────────────────────────────────────────────────────────────
# Substr in every clause #1332 names
# filter against a literal and against a column; update's SET value; an `on()` path condition over
# a related column; a `cjoin_on` condition over `Joined(...)`. Each is checked for its SQL and for
# SQLite's vector against PostgreSQL's text order.
# Why: these are the shapes that needed raw SQL before; a misbind in a join condition is a wrong row.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1332: Substr in filter, update and join conditions" begin
  shapes = (
    ("filter == literal",
     m -> (q = m.Sub_driver.objects; q.filter(Substr("surname", 1, 3) == "Ham"); q),
     ("WHERE (SUBSTR(\"Tb\".\"surname\", ?, ?) = ?)",
      "WHERE (SUBSTR(\"Tb\".\"surname\", (\$1::bigint)::integer, (\$2::bigint)::integer) = \$3::text)"),
     Any[1, 3, "Ham"]),
    ("filter == F(column)",
     m -> (q = m.Sub_driver.objects; q.filter(Upper(Substr("surname", 1, 3)) == F("code")); q),
     ("WHERE (UPPER(SUBSTR(\"Tb\".\"surname\", ?, ?)) = \"Tb\".\"code\")",
      "WHERE (UPPER(SUBSTR(\"Tb\".\"surname\", (\$1::bigint)::integer, (\$2::bigint)::integer)) = \"Tb\".\"code\")"),
     Any[1, 3]),
    ("on() over a related column",
     m -> (q = m.Sub_result.objects;
           q.on("driver", Substr("driver__surname", 1, 1) == "V");
           q.filter("note" => "x");
           q.values("id", "driver__surname"); q),
     ("AND (SUBSTR(\"Tb_1\".\"surname\", ?, ?) = ?)",
      # PostgreSQL numbers as it binds, and a join binds after WHERE: `$1` is the WHERE value.
      "AND (SUBSTR(\"Tb_1\".\"surname\", (\$2::bigint)::integer, (\$3::bigint)::integer) = \$4::text)"),
     Any[1, 1, "V", "x"]),
    ("cjoin_on over Joined(...)",
     m -> (q = m.Sub_result.objects;
           q.cjoin_on("Sub_driver", alias = "d",
                      on = [Joined("d", "id") == F("driver"), Substr(Joined("d", "surname"), 1, 2) == F("note")]);
           q.filter("note" => "x");
           q.values("id", "s" => Substr(Joined("d", "forename"), 2)); q),
     ("SUBSTR(\"d\".\"surname\", ?, ?) = \"Tb\".\"note\"",
      "SUBSTR(\"d\".\"surname\", (\$3::bigint)::integer, (\$4::bigint)::integer) = \"Tb\".\"note\""),
     Any[2, 1, 2, "x"]),
  )
  for (label, build, (sl_sql, pg_sql), params) in shapes
    @testset "$label" begin
      sl = _sub_inspect(build(SubModelsSL), _SUB_SL)
      pg = _sub_inspect(build(SubModelsPG), _SUB_PG)
      @test occursin(sl_sql, _sub_flat(sl[:sql_text]))
      @test occursin(pg_sql, _sub_flat(pg[:sql_text]))
      @test _pg_text_order(pg) == params
      @test sl[:parameters] == _pg_text_order(pg)
    end
  end
  # update(): the issue's own statement, the code filled from the surname.
  expected = Dict(
    "SQLite"     => "SET \"code\" = UPPER(SUBSTR(\"Tb\".\"surname\", ?, ?))",
    "PostgreSQL" => "SET \"code\" = UPPER(SUBSTR(\"Tb\".\"surname\", (\$1::bigint)::integer, (\$2::bigint)::integer))",
  )
  for (backend, conn, models) in _SUB_ENGINES
    q = models.Sub_driver.objects
    q.filter("code__@isnull" => true)
    upd = q.update("code" => Upper(Substr("surname", 1, 3)), show_query = :dict)
    @test occursin(expected[backend], upd[:sql_text])
    @test upd[:parameters] == Any[1, 3]
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# pos and len are checked when the expression is built
# `pos` from 1 and `len` from 0, both at most typemax(Int32), raise `InvalidValueError` otherwise:
# `:range` outside the bounds, `:type` for a Bool, a float or a column path. The message names the
# argument, never the operand.
# Why: outside that range the engines disagree with no error (a negative position counts from the
# end on SQLite and MySQL), and PostgreSQL's `integer` cast raises past typemax(Int32).
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1332: pos and len are checked when the expression is built" begin
  refusal(f) = try f(); nothing catch e; e end
  for (label, f, kind) in (("pos 0", () -> Substr("surname", 0, 2), :range),
                           ("pos -2", () -> Substr("surname", -2, 2), :range),
                           ("len -1", () -> Substr("surname", 2, -1), :range),
                           ("pos past Int32", () -> Substr("surname", 2_147_483_648), :range),
                           ("len past Int32", () -> Substr("surname", 1, 2_147_483_648), :range),
                           ("a Bool pos", () -> Substr("surname", true), :type),
                           ("a Bool len", () -> Substr("surname", 1, false), :type),
                           ("a float pos", () -> Substr("surname", 1.0, 2), :type),
                           ("a column as len", () -> Substr("surname", 1, "number"), :type))
    @testset "$label" begin
      err = refusal(f)
      @test err isa PormG.InvalidValueError
      @test err.kind === kind
      @test occursin("#1332", sprint(showerror, err))
      @test !occursin("surname", sprint(showerror, err))   # the operand is never named
    end
  end
  # The bounds themselves build: the first character, an empty length, the largest integer.
  @test Substr("surname", 1, 0) isa PormG.QueryBuilder.FObject
  @test Substr("surname", 2_147_483_647, 2_147_483_647) isa PormG.QueryBuilder.FObject
  @test Substr("surname", Int16(2), UInt8(3)).column[2].field === 2   # any Integer, bound as an Int
  @test length(Substr("surname", 4).column) == 2                      # no len, nothing bound for it
end

# ─────────────────────────────────────────────────────────────────────────────
# Substr over an operand that is not text is refused on both engines
# PostgreSQL has no `substr` over an integer, a float, a date, a timestamp, a boolean, a uuid or a
# JSON document; SQLite takes part of the value's text. Refused when the query is built, pointing to
# `Cast`/`ToChar`; a literal is told to be a string. Text passes: a text column, a cast, a text
# function, a JSON key lookup, a relation whose key is text.
# Why: the query does not say which text it means, so neither engine may pick one.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1332: a non-text operand is refused, and Cast lets it through" begin
  for (backend, conn, models) in _SUB_ENGINES
    @testset "$backend" begin
      for operand in ("number", "points", "dob", "seen", "active", "ref", "extra", F("number"), 5)
        msg = _sub_refused(models, conn, Substr(operand, 1, 2))
        @test msg !== nothing
        @test occursin("Substr", msg) && occursin("is not text", msg)
        @test occursin(operand isa Integer ? "string(x)" : "Cast(x, \"text\")", msg)
      end
      @test occursin("the IntegerField `number`", _sub_refused(models, conn, Substr("number", 1, 2)))
      @test occursin("the DateField `dob`", _sub_refused(models, conn, Substr("dob", 1)))
      @test occursin("the JSONField `extra`", _sub_refused(models, conn, Substr("extra", 1, 2)))
      @test occursin("the ForeignKey `team`, whose key is of type IDField",
                     _sub_refused(models, conn, Substr("team", 1, 2)))
      for operand in ("surname", Cast("number", "text"), Lower("code"), Value("abc"), F("code"),
                      "extra__name", "cc", Value(missing))
        @test _sub_refused(models, conn, Substr(operand, 1, 2)) === nothing
      end
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# Two prefixes compared through an alias: the issue's `Substr(a) == Substr(b)`
# `values("initial" => Substr("forename", 1, 1))` then `filter("initial" => Substr("surname", 1, 1))`
# renders `WHERE SUBSTR(forename, ?, ?) = SUBSTR(surname, ?, ?)`, binding the four values in text
# order after the projection's two.
# Why: a filter pair is the spelling that takes a function on its right; the `==` operator is not.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1332: two prefixes compared through an alias and a filter pair" begin
  build(models) = (q = models.Sub_driver.objects;
                   q.values("id", "initial" => Substr("forename", 1, 1));
                   q.filter("initial" => Substr("surname", 1, 1));
                   q)
  pg = _sub_inspect(build(SubModelsPG), _SUB_PG)
  sl = _sub_inspect(build(SubModelsSL), _SUB_SL)
  @test occursin("WHERE SUBSTR(\"Tb\".\"forename\", ?, ?) = SUBSTR(\"Tb\".\"surname\", ?, ?)", _sub_flat(sl[:sql_text]))
  @test occursin("SUBSTR(\"Tb\".\"surname\", (\$5::bigint)::integer, (\$6::bigint)::integer)", _sub_flat(pg[:sql_text]))
  @test _pg_text_order(pg) == Any[1, 1, 1, 1, 1, 1]
  @test sl[:parameters] == _pg_text_order(pg)
  # Distinct values, so a swapped pair would show: the WHERE side binds 2, 3 then 4, 5.
  distinct(models) = (q = models.Sub_driver.objects;
                      q.values("id", "initial" => Substr("forename", 2, 3));
                      q.filter("initial" => Substr("surname", 4, 5));
                      q)
  pg = _sub_inspect(distinct(SubModelsPG), _SUB_PG)
  @test _pg_text_order(pg) == Any[2, 3, 2, 3, 4, 5]
  @test _sub_inspect(distinct(SubModelsSL), _SUB_SL)[:parameters] == _pg_text_order(pg)
end

# ─────────────────────────────────────────────────────────────────────────────
# Substr is text, and a function stays refused on the right of the == operator
# `_TEXT_OUTPUT_FUNCTIONS` types the value as text, so `When` refuses it as a condition; the type
# walk names it `CText` on both engines. `Substr(a) == Substr(b)` raises `QueryBuildError` as
# `Lower(a) == Lower(b)` does: the `==` operator takes no function on its right yet.
# Why: a text value used as a boolean reads as truthiness on SQLite and fails on PostgreSQL.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1332: Substr is typed as text" begin
  @test_throws PormG.QueryBuildError When(Substr("code", 1, 1); then = 1)
  @test PormG.QueryBuilder._result_rule(Substr("code", 1, 1)) isa PormG.CText
  @test_throws PormG.QueryBuildError Substr("forename", 1, 1) == Substr("surname", 1, 1)
  @test_throws PormG.QueryBuildError Lower("forename") == Lower("surname")
end
