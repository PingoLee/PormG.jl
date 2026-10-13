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
  # A third, untyped operand does not hide the conflict between the two typed ones.
  _tmx_refused(Fn.Coalesce(F("start_at") - Day(1), "date", zdt), "Coalesce", _DATE, _ZONED_LIT;
               fix = _TMX_DECLARE, julia = true)
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
# type (timestamp arithmetic) or a NULL default; and a number beside a number, which #1150 normalizes — the
# rule is temporal mixes only (the issue's scope). Expected SQL: as before, not pinned here.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1200: same-type, untyped and numeric operands build as before" begin
  zdt = _TMX_ZDT
  for expr in (Fn.Coalesce("date", "circuit__opened"),
               Fn.Coalesce("start_at", zdt),
               Fn.Greatest(zdt, zdt),
               Fn.Least("fp1_time", Time(12)),
               Fn.Coalesce("local_at", DateTime(2021, 1, 1)),
               Fn.Coalesce(F("start_at") - Day(1), "date"),
               Fn.Case(Fn.When("number" => 1, then = F("date")), default = nothing),
               Fn.Lag("start_at"; default = zdt, over = _tmx_over()),
               Fn.Coalesce("number", 1.5),
               Fn.Coalesce("name", "name"))
    @test _tmx_builds(expr)
  end
end
