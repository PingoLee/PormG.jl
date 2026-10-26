"""
#1200 — a value that is one of several operands' (`Coalesce`, `Greatest`, `Least`, `NullIf`, a `Case`
with no `output_field`, a `Lag`/`Lead` and its `default`) over two different temporal types, or a
temporal type and text, is refused when the query is built, on every engine.

After #1175 a `ZonedDateTime` literal binds as `timestamptz` on PostgreSQL, which matches Django with
`USE_TZ = True`. What remained is the case Django refuses outright (`Expression contains mixed types:
DateField, DateTimeField. You must set output_field.`). With
`zdt = ZonedDateTime(DateTime(2021, 1, 1, 0, 30), FixedTimeZone("UTC+2", 7200))`:

| expression | PostgreSQL | SQLite |
|---|---|---|
| `Coalesce("date", zdt)` | a `ZonedDateTime` on every row | each row's own text: a date, or the UTC timestamp |
| `Coalesce("name", zdt)` | fails at the server (`COALESCE types … cannot be matched`) | builds; returns text |

The query does not say which type it means (#1147's explicit intent), so the refusal names no engine
and gives the spellings that say it: an `output_field`, a `Cast` of one operand (`NullIf`, `Lag`,
`Lead` take no `output_field`), or the literal converted in Julia. A naive and a zoned timestamp are
two types here, as the issue sets it. A number beside a number is #1150's, not this rule's.

#1327 widens the rule to text beside a number (an integer, a float and a decimal are one class): SQLite
ordered any text above any number, MySQL compared the two as strings, PostgreSQL failed at the server.
Refused on every engine, MySQL included, naming a `Cast` of either operand; a declared `output_field`
does not lift it, since it casts the value after the engine has met both operands.

#1321 completes the rule: any two classes that differ are a mix, so a number beside a date, a time, an
interval or a UUID, and a UUID beside anything else, are refused the same way. Neither pair has a
common type, so the message names none, and `output_field` does not lift a pair with a number or a
UUID side.

Everything renders through mock connections — no live database, no fixture.

julia --project=test/integration test/unit/test_temporal_mix_refusal.jl
"""

using Test
using Dates
using TimeZones
using PormG
using PormG.Models
using PormG.QueryBuilder: inspect_query
import PormG: QueryBuildError

# Dedicated config key + mock types: `runtests.jl` includes every unit file into one `Main`, so a
# shared key would let another file's settings decide this file's dialect.
struct TmxMockSQLite <: PormG.PormGSQLite end
struct TmxMockPostgres <: PormG.PormGPostgres end
const _TMX_SL = TmxMockSQLite()
const _TMX_PG = TmxMockPostgres()
PormG.backend_sqlite_version(::TmxMockSQLite) = 3045000

PormG.config["tmx_mock"] = PormG.Configuration.Settings(
  connections = _TMX_SL, change_data = true, db_def_folder = "tmx_mock",
)

# One column of each temporal type, a text and a number column, and a to-one relation so a joined
# path is reachable.
module TmxModels
import PormG
import PormG.Models

Tmx_circuit = Models.Model("tmx_circuit",
  id     = Models.IDField(),
  opened = Models.DateField(null = true),
)
Tmx_race = Models.Model("tmx_race",
  id       = Models.IDField(),
  name     = Models.CharField(),
  number   = Models.IntegerField(null = true),
  date     = Models.DateField(null = true),
  fp1_time = Models.TimeField(null = true),
  start_at = Models.DateTimeField(null = true),                       # TIMESTAMPTZ, the default
  local_at = Models.DateTimeField(type = "TIMESTAMP", null = true),   # naive
  laptime  = Models.DurationField(null = true),
  token    = Models.UUIDField(null = true),                           # #1321
  circuit  = Models.ForeignKey(Tmx_circuit, on_delete = "CASCADE"),
)

PormG.Models.set_models(@__MODULE__, "tmx_mock")
end

const TMX = TmxModels
const Fn = PormG.Functions
const _TMX_ENGINES = (_TMX_PG, _TMX_SL)
const _TMX_ZDT = ZonedDateTime(DateTime(2021, 1, 1, 0, 30), FixedTimeZone("UTC+2", 7200))

_tmx_over() = PormG.QueryBuilder.WindowOver(order_by = "id")
# A fresh queryset projecting `expr`, rendered on `conn`: the SQL text.
_tmx_render(expr; conn) =
  inspect_query((q = TMX.Tmx_race.objects; q.values("x" => expr); q); connection = conn)[:sql_text]
function _tmx_refusal(expr; conn)
  try
    _tmx_render(expr; conn = conn)
    return nothing
  catch e
    return e
  end
end
_tmx_msg(e) = replace(sprint(showerror, e), r"\e\[[0-9;]*m" => "")
_tmx_names_no_engine(msg) = !occursin("PostgreSQL", msg) && !occursin("SQLite", msg)
# Refused on both engines, naming the function, both sides, #1200, and the spelling that works for the
# pair: `output_field` (or, for `NullIf`/`Lag`/`Lead`, a `Cast`) for a date and a timestamp; a cast to
# text beside text; no common type otherwise. The Julia conversion only for a date/timestamp pair with
# a literal side, where converting the literal resolves the mix.
const _TMX_DECLARE = "output_field = "
const _TMX_CAST = "cast one operand to the other's type, Cast(x, "
const _TMX_TEXT = "cast the other operand to text, Cast(x, \"text\")"
const _TMX_NONE = "they have no common type"
function _tmx_refused(expr, fname, a, b; fix, julia::Bool)
  for conn in _TMX_ENGINES
    err = _tmx_refusal(expr; conn = conn)
    @test err isa QueryBuildError
    err isa QueryBuildError || continue
    msg = _tmx_msg(err)
    @test occursin("$(fname) mixes $(a) and $(b), and does not say which type its value has (#1200)", msg)
    @test occursin(fix, msg)
    # Only the fix for the pair: `output_field` is not offered where it cannot unify the operands.
    @test count(f -> occursin(f, msg), (_TMX_DECLARE, _TMX_CAST, _TMX_TEXT, _TMX_NONE)) == 1
    @test occursin("Date(zdt)", msg) == julia
    @test _tmx_names_no_engine(msg)
  end
end
_tmx_builds(expr) = all(conn -> _tmx_refusal(expr; conn = conn) === nothing, _TMX_ENGINES)

const _DATE = "a date (`date`)"
const _ZONED_LIT = "a timestamp with time zone (a ZonedDateTime literal)"

# ─────────────────────────────────────────────────────────────────────────────
# #1200: a date beside a zoned literal is refused in every function whose value is one of its operands'
# The issue's first row, in each place it reaches: `Coalesce`, `Greatest`, `Least`, `NullIf`, a `Case`
# with a date branch and a zoned default, and a `Lag`/`Lead` with a zoned `default`. PostgreSQL
# resolved each to `timestamptz` (or compared the date to the instant), SQLite returned each row's own
# text. Refused on both engines, no engine named; `NullIf`/`Lag`/`Lead`, which take no `output_field`,
# are pointed to a `Cast`. Expected SQL: none.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1200: a date beside a zoned literal is refused on every engine" begin
  zdt = _TMX_ZDT
  for (expr, fname) in ((Fn.Coalesce("date", zdt), "Coalesce"), (Fn.Greatest("date", zdt), "Greatest"),
                        (Fn.Least("date", zdt), "Least"),
                        (Fn.Case(Fn.When("number" => 1, then = F("date")), default = zdt), "Case"))
    _tmx_refused(expr, fname, _DATE, _ZONED_LIT; fix = _TMX_DECLARE, julia = true)
  end
  for (expr, fname) in ((Fn.NullIf("date", zdt), "NullIf"), (Fn.Lag("date"; default = zdt, over = _tmx_over()), "Lag"),
                        (Fn.Lead("date"; default = zdt, over = _tmx_over()), "Lead"))
    _tmx_refused(expr, fname, _DATE, _ZONED_LIT; fix = _TMX_CAST, julia = true)
  end
  # A joined path is typed through the join, and named as written.
  _tmx_refused(Fn.Coalesce("circuit__opened", zdt), "Coalesce", "a date (`circuit__opened`)", _ZONED_LIT;
               fix = _TMX_DECLARE, julia = true)
end

# ─────────────────────────────────────────────────────────────────────────────
# #1200: the other mixes — naive vs zoned, date vs timestamp column, time vs interval, text vs temporal
# A naive and a zoned timestamp are two types (the issue's scope, confirmed by the maintainer): a
# `DateTimeField` defaults to `TIMESTAMPTZ`, so `Coalesce("start_at", DateTime(…))` is refused too, as
# is a `Case` with a zoned and a naive branch. A text column or a text literal (a `Case` branch, a
# window `default`: strings there are literals, not paths) beside a temporal value is refused —
# PostgreSQL failed it at the server, SQLite returned text. Expected SQL: none.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1200: naive vs zoned, two temporal columns, and text vs temporal are refused" begin
  zdt = _TMX_ZDT
  naive_lit = "a timestamp without time zone (a DateTime literal)"
  _tmx_refused(Fn.Coalesce("start_at", DateTime(2021, 1, 1)), "Coalesce",
               "a timestamp with time zone (`start_at`)", naive_lit; fix = _TMX_DECLARE, julia = true)
  _tmx_refused(Fn.Coalesce("start_at", "local_at"), "Coalesce",
               "a timestamp with time zone (`start_at`)", "a timestamp without time zone (`local_at`)";
               fix = _TMX_DECLARE, julia = false)
  _tmx_refused(Fn.Case(Fn.When("number" => 1, then = Fn.Value(zdt)), default = Fn.Value(DateTime(2021, 1, 1))),
               "Case", _ZONED_LIT, naive_lit; fix = _TMX_DECLARE, julia = true)
  _tmx_refused(Fn.Coalesce("date", "start_at"), "Coalesce", _DATE, "a timestamp with time zone (`start_at`)";
               fix = _TMX_DECLARE, julia = false)
  # A time and an interval, or a date and a time, have no common type on PostgreSQL even under an
  # `output_field` (it casts OUTSIDE the function), so none is offered.
  _tmx_refused(Fn.Greatest("fp1_time", "laptime"), "Greatest", "a time (`fp1_time`)", "an interval (`laptime`)";
               fix = _TMX_NONE, julia = false)
  _tmx_refused(Fn.Coalesce("date", "fp1_time"), "Coalesce", _DATE, "a time (`fp1_time`)"; fix = _TMX_NONE, julia = false)
  # A literal outside a date/timestamp pair gets no Julia conversion: `Date(zdt)` would not resolve it.
  _tmx_refused(Fn.Coalesce("laptime", Time(1)), "Coalesce", "an interval (`laptime`)", "a time (a Time literal)";
               fix = _TMX_NONE, julia = false)
  # Beside text, the other operand is cast to text.
  _tmx_refused(Fn.Coalesce("name", zdt), "Coalesce", "text (`name`)", _ZONED_LIT; fix = _TMX_TEXT, julia = false)
  _tmx_refused(Fn.Case(Fn.When("number" => 1, then = "2021-01-01"), default = F("date")), "Case",
               "text (a String literal)", _DATE; fix = _TMX_TEXT, julia = false)
  _tmx_refused(Fn.Lag("date"; default = "2021-01-01", over = _tmx_over()), "Lag", _DATE, "text (a String literal)";
               fix = _TMX_TEXT, julia = false)
  # A third, untyped operand (a timestamp times a number) does not hide the conflict between the two
  # typed ones.
  _tmx_refused(Fn.Coalesce(F("start_at") * 2, "date", zdt), "Coalesce", _DATE, _ZONED_LIT;
               fix = _TMX_DECLARE, julia = true)
  # #1034 step 5a: timestamp arithmetic is typed by the walk, as its render types it, so a shifted
  # timestamp beside a date is the same mix as the column beside it. It built before as untyped.
  _tmx_refused(Fn.Coalesce(F("start_at") - Day(1), "date"), "Coalesce",
               "a timestamp with time zone (an expression)", _DATE; fix = _TMX_DECLARE, julia = false)
end

# ─────────────────────────────────────────────────────────────────────────────
# #1200: the spellings that say the type build, with their SQL, on both engines
# The literal converted in Julia (`Date(zdt)`), an `output_field` naming one of a date/timestamp pair,
# which renders the declared cast (#852), and a cast to text of the non-text side. Expected SQL:
#   PostgreSQL  COALESCE("Tb"."date", $1::date)            and  (COALESCE("Tb"."date", $1::timestamptz))::date
#   SQLite      COALESCE("Tb"."date", ?)                   and  the date cast SQLite renders for `output_field = "date"`
# Why: the refusal must point to spellings that work; a refusal of them would leave no way through.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1200: the explicit spellings build on both engines" begin
  zdt = _TMX_ZDT
  @test occursin("COALESCE(\"Tb\".\"date\", \$1::date) as \"x\"", _tmx_render(Fn.Coalesce("date", Date(zdt)); conn = _TMX_PG))
  @test occursin("COALESCE(\"Tb\".\"date\", ?) as \"x\"", _tmx_render(Fn.Coalesce("date", Date(zdt)); conn = _TMX_SL))
  @test occursin("(COALESCE(\"Tb\".\"date\", \$1::timestamptz))::date as \"x\"",
                 _tmx_render(Fn.Coalesce("date", zdt; output_field = "date"); conn = _TMX_PG))
  for expr in (Fn.Coalesce("date", zdt; output_field = "date"),
               Fn.Greatest("date", zdt; output_field = "date"),
               Fn.Coalesce("start_at", "local_at"; output_field = "text"),   # two timestamps, as text on both
               Fn.Case(Fn.When("number" => 1, then = F("date")), default = zdt, output_field = "date"),
               Fn.Coalesce("name", Fn.Cast(Fn.Value(zdt), "text")),       # text beside text
               Fn.Greatest(Fn.Cast("fp1_time", "text"), Fn.Cast("laptime", "text")),
               Fn.NullIf("date", Date(zdt)),
               Fn.Lag("date"; default = Date(zdt), over = _tmx_over()),
               Fn.Coalesce("start_at", ZonedDateTime(DateTime(2021, 1, 1), tz"UTC")))
    @test _tmx_builds(expr)
  end
  # A timestamp type declared builds on PostgreSQL; SQLite cannot cast to one, a feature it lacks that
  # #822 refuses there (not this rule), which is why the message leads with the Julia conversion.
  for expr in (Fn.Coalesce("date", zdt; output_field = "timestamptz"),
               Fn.Least("start_at", DateTime(2021, 1, 1); output_field = "timestamptz"))
    @test _tmx_refusal(expr; conn = _TMX_PG) === nothing
    @test occursin("#822", _tmx_msg(_tmx_refusal(expr; conn = _TMX_SL)))
  end
  # An `output_field` is not checked by this rule, so text beside a timestamp under one builds as it did
  # (the issue's acceptance). The message does not offer it: PostgreSQL still unifies the operands
  # inside `COALESCE` first and fails that at the server.
  @test _tmx_builds(Fn.Coalesce("name", zdt; output_field = "text"))
end

# ─────────────────────────────────────────────────────────────────────────────
# #1200: same-type operands, an untyped operand, and numbers are left as they were
# Two dates (one across the join), two zoned values, two times; a date beside an operand PormG cannot
# type (a timestamp times a number) or a NULL default; and a number beside a number, which #1150 normalizes — the
# rule is temporal mixes only (the issue's scope). Expected SQL: as before, not pinned here.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1200: same-type, untyped and numeric operands build as before" begin
  zdt = _TMX_ZDT
  for expr in (Fn.Coalesce("date", "circuit__opened"),
               Fn.Coalesce("start_at", zdt),
               Fn.Greatest(zdt, zdt),
               Fn.Least("fp1_time", Time(12)),
               Fn.Coalesce("local_at", DateTime(2021, 1, 1)),
               Fn.Coalesce(F("start_at") * 2, "date"),
               Fn.Case(Fn.When("number" => 1, then = F("date")), default = nothing),
               Fn.Lag("start_at"; default = zdt, over = _tmx_over()),
               Fn.Coalesce("number", 1.5),
               Fn.Coalesce("name", "name"))
    @test _tmx_builds(expr)
  end
end

# ── #1327: text beside a number ───────────────────────────────────────────────────────────────────
# MySQL renders the conditionals since #1130 phase 2c-1, so the #1327 rows assert on all three engines.
# Window functions are a later MySQL phase, so `Lag`/`Lead` stay on the two engines above.
struct TmxMockMySQL <: PormG.PormGMySQL end
const _TMX_MY = TmxMockMySQL()
const _TMX_ALL = (_TMX_PG, _TMX_SL, _TMX_MY)
const _TMX_NUMBER_FIX = ("Cast(x, \"text\")", "Cast(x, \"integer\")")
const _TMX_NOT_DECLARED = "An `output_field` does not say it"
function _tmx_number_refused(expr, fname, a, b; engines = _TMX_ALL, declared::Bool = false)
  for conn in engines
    err = _tmx_refusal(expr; conn = conn)
    @test err isa QueryBuildError
    err isa QueryBuildError || continue
    msg = _tmx_msg(err)
    @test occursin("$(fname) mixes $(a) and $(b), and does not say which type its value has (#1327)", msg)
    # Both casts are named: either one says which comparison, and which type, is meant.
    @test all(f -> occursin(f, msg), _TMX_NUMBER_FIX)
    @test !occursin("output_field = ", msg)
    @test occursin(_TMX_NOT_DECLARED, msg) == declared
    @test _tmx_names_no_engine(msg) && !occursin("MySQL", msg)
  end
end
_tmx_builds_all(expr) = all(conn -> _tmx_refusal(expr; conn = conn) === nothing, _TMX_ALL)

# ─────────────────────────────────────────────────────────────────────────────
# #1327: a conditional over text and a number is refused on every engine
# `Coalesce`, `Greatest`, `Least`, `NullIf` and a `Case` whose values include text and a number, a
# column or a literal on either side. SQLite answered by its type order (any text above any number),
# MySQL compared as strings (`GREATEST('10', 9)` is `'9'`) and returned a VARCHAR, PostgreSQL failed
# at the server: the query does not say which comparison or which type it means (explicit intent), so
# each engine refuses it when it is built, naming both operands and both casts. Expected SQL: none.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1327: text beside a number is refused on every engine" begin
  name, number = "text (`name`)", "a number (`number`)"
  _tmx_number_refused(Fn.Coalesce("name", "number"), "Coalesce", name, number)
  _tmx_number_refused(Fn.Coalesce("name", 0), "Coalesce", name, "a number (an Int64 literal)")
  _tmx_number_refused(Fn.Greatest("name", Fn.Value(9)), "Greatest", name, "a number (an Int64 literal)")
  _tmx_number_refused(Fn.Least("number", "name"), "Least", number, name)
  _tmx_number_refused(Fn.NullIf("name", F("number")), "NullIf", name, number)
  _tmx_number_refused(Fn.Case(Fn.When("number" => 1, then = 1), default = "x"), "Case",
                      "a number (an Int64 literal)", "text (a String literal)")
  _tmx_number_refused(Fn.Case(Fn.When("number" => 1, then = "x"), default = F("number")), "Case",
                      "text (a String literal)", number)
  # A float or a decimal is a number as an integer is.
  _tmx_number_refused(Fn.Coalesce("name", 1.5), "Coalesce", name, "a number (a Float64 literal)")
  # A third, untyped operand does not hide the conflict between the two typed ones.
  _tmx_number_refused(Fn.Coalesce(F("start_at") * 2, "name", "number"), "Coalesce", name, number)
  # A window default is a literal, as in #1200: text beside the operand's number.
  _tmx_number_refused(Fn.Lag("number"; default = "x", over = _tmx_over()), "Lag", number,
                      "text (a String literal)"; engines = _TMX_ENGINES)
end

# ─────────────────────────────────────────────────────────────────────────────
# #1327: an `output_field` does not lift the refusal for text beside a number
# Since #852 `output_field` casts the result outside the call: `(COALESCE("name", 0))::text`. The
# engine still meets text and a number inside it, so PostgreSQL still raises and MySQL still compares
# as strings before the cast. Refused as without one, and the message says why the declaration is not
# the spelling. Expected SQL: none.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1327: output_field does not lift text beside a number" begin
  _tmx_number_refused(Fn.Coalesce("name", 0; output_field = "text"), "Coalesce", "text (`name`)",
                      "a number (an Int64 literal)"; declared = true)
  _tmx_number_refused(Fn.Greatest("name", "number"; output_field = "integer"), "Greatest", "text (`name`)",
                      "a number (`number`)"; declared = true)
  _tmx_number_refused(Fn.Case(Fn.When("number" => 1, then = 1), default = "x", output_field = "text"), "Case",
                      "a number (an Int64 literal)", "text (a String literal)"; declared = true)
end

# ─────────────────────────────────────────────────────────────────────────────
# #1327: a cast on the operand that differs builds on every engine; numbers and untyped operands too
# The spellings the refusal names (a `Cast` of the number to text, or of the text to an integer) give
# both operands one class, so each engine meets one type. An integer beside a float or a decimal keeps
# the widening it has (`:promoting`, #1150), and an operand the walk cannot type is let through, as in
# #1200. Expected SQL on PostgreSQL: `COALESCE("Tb"."name", CAST($1 AS TEXT))`-shaped, not pinned here
# beyond building.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1327: the explicit spellings, numbers and untyped operands build" begin
  for expr in (Fn.Coalesce("name", Fn.Cast(Fn.Value(0), "text")),
               Fn.Coalesce(Fn.Cast("name", "integer"), 0),
               Fn.Greatest(Fn.Cast("number", "text"), "name"),
               Fn.Case(Fn.When("number" => 1, then = "1"), default = "x"),
               Fn.Coalesce("number", 1.5),
               Fn.Coalesce("number", Fn.Value(2)),
               Fn.Greatest("number", "number"),
               Fn.Coalesce(F("start_at") * 2, "name"),
               Fn.Case(Fn.When("number" => 1, then = "x"), default = nothing))   # a NULL is never the value
    @test _tmx_builds_all(expr)
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# #1321: a number beside a date, a time, an interval or a UUID is refused on every engine
# PostgreSQL has no common type for these (`COALESCE types integer and date cannot be matched`, at the
# server); SQLite returned whichever operand was not NULL, a number on one row and a date's text on
# another, and stored that text in a number column through `update`. Refused when the query is built,
# on every engine, naming both operands and #1321; no common type is offered, and an `output_field`
# does not lift it. A UUID beside text is the same question as a date beside text. Expected SQL: none.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1321: a number or a UUID beside another class is refused on every engine" begin
  function refused(expr, fname, a, b; engines = _TMX_ALL, fix = _TMX_NONE, declared::Bool = false)
    for conn in engines
      err = _tmx_refusal(expr; conn = conn)
      @test err isa QueryBuildError
      err isa QueryBuildError || continue
      msg = _tmx_msg(err)
      @test occursin("$(fname) mixes $(a) and $(b), and does not say which type its value has (#1321)", msg)
      @test occursin(fix, msg)
      @test !occursin("output_field = ", msg)
      @test occursin(_TMX_NOT_DECLARED, msg) == declared
      @test _tmx_names_no_engine(msg) && !occursin("MySQL", msg)
    end
  end
  number, token = "a number (`number`)", "a UUID (`token`)"
  refused(Fn.Coalesce("number", "date"), "Coalesce", number, _DATE)
  refused(Fn.Greatest("date", "number"), "Greatest", _DATE, number)
  refused(Fn.Coalesce("fp1_time", 0), "Coalesce", "a time (`fp1_time`)", "a number (an Int64 literal)")
  refused(Fn.Least("laptime", "number"), "Least", "an interval (`laptime`)", number)
  refused(Fn.NullIf("number", F("start_at")), "NullIf", number, "a timestamp with time zone (`start_at`)")
  refused(Fn.Case(Fn.When("number" => 1, then = F("date")), default = 0), "Case", _DATE, "a number (an Int64 literal)")
  refused(Fn.Coalesce("number", "token"), "Coalesce", number, token)
  refused(Fn.Coalesce("token", "date"), "Coalesce", token, _DATE)
  # A UUID beside text: cast the other operand to text, as for a date beside text.
  refused(Fn.Coalesce("token", "name"), "Coalesce", token, "text (`name`)"; fix = _TMX_TEXT)
  # An `output_field` does not lift a pair with a number or a UUID side.
  refused(Fn.Coalesce("number", "date"; output_field = "date"), "Coalesce", number, _DATE; declared = true)
  refused(Fn.Coalesce("token", "name"; output_field = "text"), "Coalesce", token, "text (`name`)";
          fix = _TMX_TEXT, declared = true)
  # A window `default` of another class than the operand.
  refused(Fn.Lag("number"; default = Date(2021, 1, 1), over = _tmx_over()), "Lag", number,
          "a date (a Date literal)"; engines = _TMX_ENGINES)
end

# ─────────────────────────────────────────────────────────────────────────────
# #1321: one class, or a spelling that states one, builds on every engine
# Two UUIDs, a number beside the year of a date (an integer), a date cast to text beside text, and the
# #1200 date/timestamp pair under an `output_field`, which it still lifts. Expected SQL: as before.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1321: one class, and the spellings that state one, build" begin
  for expr in (Fn.Coalesce("token", "token"),
               Fn.Coalesce("number", Fn.Extract("date", "year")),
               Fn.Coalesce(Fn.Cast("date", "text"), "name"),
               Fn.Coalesce("date", "start_at"; output_field = "date"))
    @test _tmx_builds_all(expr)
  end
end
