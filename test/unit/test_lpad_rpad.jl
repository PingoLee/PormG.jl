"""
Unit coverage for #122 — `LPad` / `RPad`, string padding in an expression.

Before #122 the catalog had no padding function, so zero-filling an integer into a fixed-width text
column (`SET code = LPAD(number::text, 3, '0')`) needed raw SQL, or a fetch, a Julia `lpad` and a
`bulk_update`. `LPad(x, len, fill = " ")` / `RPad` render PostgreSQL's `LPAD`/`RPAD`; SQLite has
neither, so the SQLite extension registers `pormg_lpad`/`pormg_rpad` on every connection it opens.

What is pinned here, and why each part matters:

  - **The SQL and the parameter vector, exactly, on both engines.** `len` and `fill` are bound, in
    text order; a misbind is silent wrong data. PostgreSQL casts the length to `integer`, because a
    bound `Int` is `bigint` and there is no `lpad(text, bigint, text)`.
  - **The SQLite functions' semantics against PostgreSQL's own answers.** The expected values in the
    UDF testset were read from PostgreSQL 16 (`SELECT lpad('abcdef', 3, '0')`, …), not derived from
    the implementation: truncation keeps the LEFT part for both functions, a multi-character fill is
    cut, an empty fill pads nothing, lengths count characters.
  - **The refusals.** A typed non-text operand (PostgreSQL has no `lpad(integer, …)`), a numeric
    fill, and a negative length are refused when the expression or query is built, on both engines.

Everything renders through mock connections, and the UDFs run on an in-memory SQLite database — no
live database. Run alone:

    julia --project=test/integration test/unit/test_lpad_rpad.jl
"""

using Test
using PormG
using PormG.Models
using PormG.Functions
using PormG.QueryBuilder: inspect_query
import Dates
isdefined(Main, :SQLite) || include(joinpath(@__DIR__, "..", "load_drivers.jl"))

# Dedicated config keys + mock types: `runtests.jl` includes every unit file into one `Main`. Two
# keys, because `update` renders on the model's own connection — one model module per engine.
struct LprMockSQLite <: PormG.PormGSQLite end
struct LprMockPostgres <: PormG.PormGPostgres end
const _LPR_SL = LprMockSQLite()
const _LPR_PG = LprMockPostgres()
PormG.backend_sqlite_version(::LprMockSQLite) = 3045000

PormG.config["lpr_mock_sl"] = PormG.Configuration.Settings(
  connections = _LPR_SL, change_data = true, db_def_folder = "lpr_mock_sl",
)
PormG.config["lpr_mock_pg"] = PormG.Configuration.Settings(
  connections = _LPR_PG, change_data = true, db_def_folder = "lpr_mock_pg",
)

# A driver-shaped table: text, the integer the issue zero-fills, one column of each non-text kind
# PostgreSQL's `lpad` refuses, and two relations — to an integer key and to a text key.
module LprModelsSL
import PormG
import PormG.Models
Lpr_team = Models.Model("lpr_team", id = Models.IDField(), name = Models.CharField())
Lpr_code = Models.Model("lpr_code", code = Models.CharField(primary_key = true), label = Models.CharField())
Lpr_driver = Models.Model("lpr_driver",
  id     = Models.IDField(),
  seen   = Models.DateTimeField(null = true),
  team   = Models.ForeignKey(Lpr_team, on_delete = "CASCADE", null = true),
  cc     = Models.ForeignKey(Lpr_code, on_delete = "CASCADE", null = true),
  code   = Models.CharField(null = true),
  number = Models.IntegerField(null = true),
  points = Models.FloatField(null = true),
  dob    = Models.DateField(null = true),
  clock  = Models.TimeField(null = true),
  active = Models.BooleanField(null = true),
  ref    = Models.UUIDField(null = true),
  extra  = Models.JSONField(null = true),
)
PormG.Models.set_models(@__MODULE__, "lpr_mock_sl")
end

module LprModelsPG
import PormG
import PormG.Models
Lpr_team = Models.Model("lpr_team", id = Models.IDField(), name = Models.CharField())
Lpr_code = Models.Model("lpr_code", code = Models.CharField(primary_key = true), label = Models.CharField())
Lpr_driver = Models.Model("lpr_driver",
  id     = Models.IDField(),
  seen   = Models.DateTimeField(null = true),
  team   = Models.ForeignKey(Lpr_team, on_delete = "CASCADE", null = true),
  cc     = Models.ForeignKey(Lpr_code, on_delete = "CASCADE", null = true),
  code   = Models.CharField(null = true),
  number = Models.IntegerField(null = true),
  points = Models.FloatField(null = true),
  dob    = Models.DateField(null = true),
  clock  = Models.TimeField(null = true),
  active = Models.BooleanField(null = true),
  ref    = Models.UUIDField(null = true),
  extra  = Models.JSONField(null = true),
)
PormG.Models.set_models(@__MODULE__, "lpr_mock_pg")
end

const _LPR_ENGINES = (("SQLite", _LPR_SL, LprModelsSL), ("PostgreSQL", _LPR_PG, LprModelsPG))

# The rendered statement of a `values` projection over one expression, filtered so a parameter of
# the outer query follows the function's own.
function _lpr_values(models, conn, expr)
  q = models.Lpr_driver.objects
  q.filter("code" => "HAM")
  q.values("p" => expr)
  return inspect_query(q; connection = conn)
end

# ─────────────────────────────────────────────────────────────────────────────
# LPad/RPad: the SQL and the bound parameters on both engines
# `LPad("code", 6, "0")` renders `LPAD(col, ($n::bigint)::integer, $m)` on PostgreSQL and
# `pormg_lpad(col, ?, ?)` on SQLite, binding the length, then the fill, then the outer WHERE value.
# Pinned exactly: the order is the contract on SQLite's positional `?`.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#122: LPad/RPad render and bind in text order on both engines" begin
  expected = Dict(
    ("SQLite", "LPad")     => "pormg_lpad(\"Tb\".\"code\", ?, ?)",
    ("SQLite", "RPad")     => "pormg_rpad(\"Tb\".\"code\", ?, ?)",
    ("PostgreSQL", "LPad") => "LPAD(\"Tb\".\"code\", (\$1::bigint)::integer, \$2::text)",
    ("PostgreSQL", "RPad") => "RPAD(\"Tb\".\"code\", (\$1::bigint)::integer, \$2::text)",
  )
  for (backend, conn, models) in _LPR_ENGINES
    @testset "$backend" begin
      for (label, f) in (("LPad", LPad), ("RPad", RPad))
        r = _lpr_values(models, conn, f("code", 6, "0"))
        @test occursin(expected[(backend, label)], r[:sql_text])
        # Length, fill, then the WHERE value.
        @test r[:parameters] == Any[6, "0", "HAM"]
      end
      # The default fill is one space, PostgreSQL's own default.
      @test _lpr_values(models, conn, LPad("code", 5))[:parameters] == Any[5, " ", "HAM"]
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# LPad in update(): the issue's own statement
# `update("code" => LPad(Cast(F("number"), "text"), 3, "0"))` is the set-based zero-fill #122 was
# filed for. The integer is converted explicitly; the SET value renders as the projection does.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#122: update() zero-fills an integer through Cast and LPad" begin
  expected = Dict(
    "SQLite"     => "SET \"code\" = pormg_lpad(CAST(\"Tb\".\"number\" AS TEXT), ?, ?)",
    "PostgreSQL" => "SET \"code\" = LPAD((\"Tb\".\"number\")::text, (\$1::bigint)::integer, \$2::text)",
  )
  for (backend, conn, models) in _LPR_ENGINES
    q = models.Lpr_driver.objects
    q.filter("code__@isnull" => true)
    upd = q.update("code" => LPad(Cast(F("number"), "text"), 3, "0"), show_query = :dict)
    @test occursin(expected[backend], upd[:sql_text])
    @test upd[:parameters][1:2] == Any[3, "0"]
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# LPad/RPad over an operand that is not text is refused on both engines
# PostgreSQL has no `lpad` over an integer, a float, a date, a time, a boolean, a uuid or a JSON
# document and fails the statement; SQLite's UDF would pad the value's text. Refused when the query
# is built, pointing to `Cast`. A `TimeField` formats as text, so its declared type is what refuses it.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#122: a non-text operand is refused, and Cast lets it through" begin
  for (backend, conn, models) in _LPR_ENGINES
    @testset "$backend" begin
      for operand in ("number", "points", "dob", "clock", "active", "ref", "extra", F("number"), 5)
        err = try
          _lpr_values(models, conn, LPad(operand, 3, "0")); nothing
        catch e
          e
        end
        @test err isa PormG.QueryBuildError
        @test occursin("is not text", sprint(showerror, err))
        # A literal is told to be a string; a column or expression to be converted.
        @test occursin(operand isa Integer ? "string(x)" : "Cast(x, \"text\")", sprint(showerror, err))
      end
      # The message names the column and its declared type.
      err = try _lpr_values(models, conn, RPad("number", 3, "0")) catch e; e end
      @test occursin("the IntegerField `number`", sprint(showerror, err))
      @test occursin("RPad", sprint(showerror, err))
      # Text passes: a text column, an explicit cast, a text function, a string literal.
      for operand in ("code", Cast("number", "text"), Lower("code"), Value("abc"), F("code"))
        @test _lpr_values(models, conn, LPad(operand, 3, "0"))[:sql_text] isa String
      end
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# LPad/RPad constructor refusals: the length and the fill
# A negative or out-of-`integer` length raises `InvalidValueError`; a number as the fill raises
# `QueryBuildError` naming the function. `Replace` shares the fill's text-slot reader, and keeps its
# own wording.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#122: the length and the fill are checked when the expression is built" begin
  @test_throws PormG.InvalidValueError LPad("code", -1, "0")
  # PostgreSQL's own limit in a UTF-8 database: 268435455 is "requested length too large" there.
  @test_throws PormG.InvalidValueError RPad("code", 268_435_455)
  @test RPad("code", 268_435_454) isa PormG.QueryBuilder.FObject
  @test_throws PormG.InvalidValueError LPad("code", true)   # a Bool is an Integer, never a width
  @test LPad("code", 0, "0") isa PormG.QueryBuilder.FObject   # 0 is a valid width: the empty string

  for f in (LPad, RPad)
    err = try f("code", 3, 0) catch e; e end
    @test err isa PormG.QueryBuildError
    @test occursin(f === LPad ? "LPad" : "RPad", sprint(showerror, err))
    @test occursin("pads with TEXT", sprint(showerror, err))
  end
  # The fill is a literal, not a column path; an expression is accepted as is.
  @test LPad("code", 3, "number").column[3] isa PormG.QueryBuilder.SQLText
  @test LPad("code", 3, F("code")).column[3] isa PormG.QueryBuilder.SQLTypeF

  err = try Replace("code", 1, "x") catch e; e end
  @test occursin("Replace", sprint(showerror, err))
  @test occursin("searches and replaces TEXT", sprint(showerror, err))
end

# ─────────────────────────────────────────────────────────────────────────────
# LPad/RPad are text: a When condition over one is refused
# `_TEXT_OUTPUT_FUNCTIONS` types the value as text, which is what lets `When` refuse a padded
# string as a condition (it is not a boolean) instead of sending it to the database.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#122: LPad is typed as text" begin
  @test_throws PormG.QueryBuildError When(LPad("code", 3, "0"); then = 1)
end

# ─────────────────────────────────────────────────────────────────────────────
# The SQLite functions agree with PostgreSQL, value for value
# Every expected value below was read from PostgreSQL 16 (`SELECT lpad(…), rpad(…)`), so this pins
# the UDFs to PostgreSQL's semantics rather than to their own implementation. Run both directly and
# through SQL on an in-memory database opened by the extension, so the registration is covered too.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#122: pormg_lpad/pormg_rpad match PostgreSQL" begin
  ext = Base.get_extension(PormG, :PormGSQLiteExt)
  @test ext !== nothing
  # (function, string, length, fill) => PostgreSQL's answer
  cases = (
    (:l, "abc", 6, "0")         => "000abc",
    (:r, "abc", 6, "0")         => "abc000",
    (:l, "abcdef", 3, "0")      => "abc",          # truncation keeps the left part…
    (:r, "abcdef", 3, "0")      => "abc",          # …for RPAD too
    (:l, "abc", 8, "xy")        => "xyxyxabc",     # a multi-character fill repeats and is cut
    (:r, "abc", 8, "xy")        => "abcxyxyx",
    (:l, "abc", 5, "")          => "abc",          # an empty fill pads nothing
    (:r, "abcdef", 4, "")       => "abcd",         # …but still truncates
    (:l, "abc", 0, "0")         => "",
    (:r, "abc", 0, "0")         => "",
    (:l, "Räikkönen", 12, "*")  => "***Räikkönen", # characters, not bytes
    (:r, "Räikkönen", 4, "*")   => "Räik",
    (:l, "abc", 5, " ")         => "  abc",
    (:l, "", 3, "z")            => "zzz",
    (:l, "ab", 5, "ñé")         => "ñéñab",
    (:l, "abc", -1, "0")        => "",             # PostgreSQL's reading of a negative length
  )
  for ((side, s, n, fill), want) in cases
    f = side === :l ? ext._pormg_lpad : ext._pormg_rpad
    @test f(s, n, fill) == want
  end
  # NULL in any argument is NULL.
  @test ext._pormg_lpad(missing, 5, "0") === missing
  @test ext._pormg_rpad("abc", 5, missing) === missing
  @test ext._pormg_lpad("abc", missing, "0") === missing

  # Through SQL, on a connection the extension opened — the registration itself.
  db = ext._create_sqlite_connection(":memory:")
  try
    row(sql) = first(SQLite.DBInterface.execute(db, sql))
    r = row("SELECT pormg_lpad('44', 3, '0') AS a, pormg_rpad('HAM', 5, '.') AS b, " *
            "pormg_lpad(NULL, 3, '0') AS c, pormg_lpad('abcdef', 3, '0') AS d")
    @test r.a == "044"
    @test r.b == "HAM.."
    @test ismissing(r.c)
    @test r.d == "abc"
  finally
    SQLite.close(db)
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# LPad/RPad: what the text check reads beyond a column's formatter (#122 review)
# A JSON key lookup and the `@yyyy_mm` label render text and pass; a relation is its target key's
# type; timestamp arithmetic is caught by the kind its render computed; the fill is checked like the
# value; and a NULL literal is no type at all. A refused literal is named by its type, never its
# value (#971).
# ─────────────────────────────────────────────────────────────────────────────
@testset "#122: the text check — key lookups, labels, relations, arithmetic, the fill" begin
  refused(models, conn, expr) = try
    _lpr_values(models, conn, expr); nothing
  catch e
    e isa PormG.QueryBuildError || rethrow()
    sprint(showerror, e)
  end
  for (backend, conn, models) in _LPR_ENGINES
    @testset "$backend" begin
      # Text on both engines: `#>>` / `json_extract`, `to_char` / `strftime`, a text primary key, NULL.
      for expr in (LPad("extra__driver", 3, "0"), LPad(F("extra__driver"), 3, "0"),
                   LPad("dob__@yyyy_mm", 9, "*"), LPad("cc", 3, "0"),
                   LPad(Value(nothing), 3, "0"), LPad(Value(missing), 3, "0"))
        @test refused(models, conn, expr) === nothing
      end
      # Not text: the whole document, an integer key, timestamp arithmetic.
      @test occursin("the JSONField `extra`", refused(models, conn, LPad("extra", 3, "0")))
      @test occursin("the ForeignKey `team`, whose key is of type IDField", refused(models, conn, LPad("team", 3, "0")))
      # A time of day formats as text; its kind refuses it through the functions that keep it.
      for expr in (LPad(Max("clock"), 9, "0"), LPad(Coalesce("clock", "clock"), 9, "0"))
        @test occursin("a time of day", refused(models, conn, expr))
      end
      # A named time column keeps its name in the message.
      @test occursin("the TimeField `clock`", refused(models, conn, LPad("clock", 9, "0")))
      @test occursin("a timestamp expression", refused(models, conn, LPad(F("seen") + Dates.Day(1), 3, "0")))
      # The fill: a column, a date literal, a boolean literal.
      msg = refused(models, conn, LPad("code", 6, F("number")))
      @test occursin("its fill", msg) && occursin("the IntegerField `number`", msg)
      @test occursin("a literal of type Date", refused(models, conn, LPad("code", 6, Dates.Date(2020, 1, 1))))
      msg = refused(models, conn, RPad("code", 6, Value(true)))
      @test occursin("a literal of type Bool", msg)
      @test !occursin("true", msg)   # the type, never the bound value
      # A text fill passes: a column, a function.
      @test refused(models, conn, LPad("code", 6, F("code"))) === nothing
      @test refused(models, conn, LPad("code", 6, Lower("code"))) === nothing
    end
  end
end

# The SQLite functions read a blob as its bytes, not as `string(Vector{UInt8})` (#122 review).
@testset "#122: pormg_lpad reads a blob as its bytes" begin
  ext = Base.get_extension(PormG, :PormGSQLiteExt)
  @test ext._pormg_lpad(Vector{UInt8}("ab"), 4, "0") == "00ab"
  @test ext._pormg_rpad("ab", 4, Vector{UInt8}("-")) == "ab--"
end
