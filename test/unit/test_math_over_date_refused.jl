"""
#1387 — a number function over a date, a timestamp, a time or a UUID is refused on every engine when
the query is built.

#1324 stated beside each number function which operand kinds it means (`_operand_domain`): `:number`
for `Round`, `Floor`, `Ceil`, `Sqrt`, `Exp`, `Ln`, `Power`, `Mod` and `Abs`, and `:number` and
`:interval` for `Sum` and `Avg`. Its check enforced only the duration half. A date, a timestamp, a time
and a UUID are not numbers either, and no engine computed what the function means over one:
PostgreSQL raised at the server (`round(date)` does not exist), SQLite computed on the stored text (a
date's leading year digits), MySQL on the number a date's digits spell.

They are refused now, on every engine, with the number the caller may mean: a calendar part
(`Extract(d, "year")` or `"date__@year"`), a clock part (`Extract(t, "hour")`), the seconds
(`Extract(d, "epoch")`) on an engine whose `EPOCH` reads that kind, or a day count from a date
difference. A UUID holds no number, and the message says so.

Out of the check, as before: text and a JSON key lookup (their own rules, #1061, #1279), a boolean
(#1386), and an operand the type walk cannot name.

Everything renders through mock connections — no live database, no fixture.

julia --project=test/integration test/unit/test_math_over_date_refused.jl
"""

using Test
using Dates
using PormG
using PormG.Models
using PormG.QueryBuilder: inspect_query
import PormG: QueryBuildError

# Dedicated config key + mock types: `runtests.jl` includes every unit file into one `Main`, so a
# shared key would let another file's settings decide this file's dialect.
struct MdtMockSQLite <: PormG.PormGSQLite end
struct MdtMockPostgres <: PormG.PormGPostgres end
struct MdtMockMySQL <: PormG.PormGMySQL end
const _MDT_SL = MdtMockSQLite()
const _MDT_PG = MdtMockPostgres()
const _MDT_MY = MdtMockMySQL()
PormG.backend_sqlite_version(::MdtMockSQLite) = 3045000
const _MDT_ENGINES = ((_MDT_PG, "PostgreSQL"), (_MDT_SL, "SQLite"), (_MDT_MY, "MySQL"))

PormG.config["mdt_mock"] = PormG.Configuration.Settings(
  connections = _MDT_SL, change_data = true, db_def_folder = "mdt_mock",
)

# The F1 race (a date, a time of day and a start timestamp), its results (a number, a float, the
# fastest-lap duration) and the fixture's one UUID column.
module MdtModels
import PormG
import PormG.Models

Race = Models.Model(
  raceid   = Models.IDField(),
  year     = Models.IntegerField(),
  date     = Models.DateField(),
  time     = Models.TimeField(null = true),
  start_at = Models.DateTimeField(null = true),
)
Result = Models.Model(
  resultid       = Models.IDField(),
  raceid         = Models.ForeignKey(Race, pk_field = "raceid", on_delete = "CASCADE"),
  grid           = Models.IntegerField(),
  points         = Models.FloatField(),
  positiontext   = Models.CharField(),
  fastestlaptime = Models.DurationField(null = true),
)
Field_validation_scratch = Models.Model("field_validation_scratch",
  id         = Models.IDField(),
  uuid_token = Models.UUIDField(unique = true),
  payload    = Models.JSONField(null = true),
)
New_join_position = Models.Model(
  id            = Models.IDField(),
  boolean_field = Models.BooleanField(null = true),
)

PormG.Models.set_models(@__MODULE__, "mdt_mock")
end

const MDT = MdtModels
const Fn = PormG.Functions
# Not `F`: `runtests.jl` includes every unit file into one `Main`, where `F` is already imported.
const _DF = PormG.QueryBuilder.F

# A fresh queryset on `model` projecting `expr`, rendered on `conn`; the exception it raises, or `nothing`.
_mdt_render(model, expr; conn) =
  inspect_query((q = model.objects; q.values("v" => expr); q); connection = conn)[:sql_text]
_mdt_refusal(model, expr; conn) = try _mdt_render(model, expr; conn = conn); nothing catch e; e end
# The message without ANSI colour, so a needle never spans a colourised token.
_mdt_msg(e) = replace(sprint(showerror, e), r"\e\[[0-9;]*m" => "")

# The number functions, each over `x` (the operand first where a function takes two).
const _MDT_FUNCTIONS = (
  (x -> Fn.Round(x), "Round"), (x -> Fn.Round(x, 2), "Round"), (x -> Fn.Floor(x), "Floor"),
  (x -> Fn.Ceil(x), "Ceil"), (x -> Fn.Sqrt(x), "Sqrt"), (x -> Fn.Exp(x), "Exp"), (x -> Fn.Ln(x), "Ln"),
  (x -> Fn.Power(x, 2), "Power"), (x -> Fn.Power(2, x), "Power"), (x -> Fn.Mod(x, 3), "Mod"),
  (x -> Fn.Abs(x), "Abs"), (x -> Fn.Sum(x), "Sum"), (x -> Fn.Avg(x), "Avg"),
)

# The refusal on every engine: the function and the kind by name, the reason that holds everywhere,
# #1387, and the number the caller may mean — `EPOCH` only where the engine reads that kind's seconds.
function _mdt_refused(model, expr, name, kind; label = nothing)
  for (conn, engine) in _MDT_ENGINES
    err = _mdt_refusal(model, expr; conn = conn)
    @test err isa QueryBuildError
    err isa QueryBuildError || continue
    msg = _mdt_msg(err)
    noun = kind === :uuid ? "a UUID" : kind === :date ? "a date" : kind === :datetime ? "a timestamp" : "a time"
    @test occursin("`$(name)` of $(noun) is not supported: $(noun) is not a number, so `$(name)` has no " *
                   "meaning over one on any engine (#1387).", msg)
    @test !occursin('\e', sprint(showerror, err; context = :color => false))
    if kind === :uuid
      @test occursin("A UUID holds no number", msg) && !occursin("Extract", msg)
      continue
    end
    epoch = kind === :time ? conn === _MDT_PG : conn !== _MDT_SL
    @test occursin("Extract(", msg) && occursin("\"epoch\")", msg) == epoch
    if kind === :time
      @test occursin("a clock part (Extract(t, \"hour\"))", msg)
      @test !occursin("calendar part", msg)
    else
      @test occursin("a calendar part (Extract(d, \"year\")", msg)
      label === nothing || @test occursin("\"$(label)__@year\"", msg)
      kind === :date && @test occursin("a day count (the difference of two DateFields, F(a) - F(b))", msg)
      kind === :datetime && @test occursin("a clock part (Extract(d, \"hour\"))", msg)
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# #1387: every number function over a DateField column is refused on every engine
# `Round` (with and without places), `Floor`, `Ceil`, `Sqrt`, `Exp`, `Ln`, `Power` (the date as either
# operand), `Mod`, `Abs`, `Sum` and `Avg` over `Race.date`. PostgreSQL has no `round(date)`, SQLite
# computed on the `YYYY-MM-DD` text (its leading year digits), MySQL on the number the digits spell.
# The message names a calendar part, the column's own `__@year` transform and a day count; `EPOCH`
# where the engine reads a date's (PostgreSQL, MySQL). Expected SQL: none.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1387: a number function over a date column is refused on every engine" begin
  for (fn, name) in _MDT_FUNCTIONS
    _mdt_refused(MDT.Race, fn("date"), name, :date; label = "date")
  end
  # Across a foreign key, the path is the label the transform is named on.
  _mdt_refused(MDT.Result, Fn.Round("raceid__date"), "Round", :date; label = "raceid__date")
end

# ─────────────────────────────────────────────────────────────────────────────
# #1387: every number function over a DateTimeField column is refused on every engine
# Over `Race.start_at`: PostgreSQL has no `floor(timestamp)`, SQLite read the text's year, MySQL the
# `YYYYMMDDhhmmss` number. The message adds a clock part to the calendar part. Expected SQL: none.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1387: a number function over a timestamp column is refused on every engine" begin
  for (fn, name) in _MDT_FUNCTIONS
    _mdt_refused(MDT.Race, fn("start_at"), name, :datetime; label = "start_at")
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# #1387: every number function over a TimeField column is refused on every engine
# Over `Race.time`: SQLite read the `HH:MM:SS` text's hours, MySQL the `hhmmss` number. A time has no
# calendar part; the message names a clock part, and its seconds since midnight only on PostgreSQL,
# whose `EPOCH` reads a time (MySQL refuses it, SQLite has no `EPOCH`). Expected SQL: none.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1387: a number function over a time column is refused on every engine" begin
  for (fn, name) in _MDT_FUNCTIONS
    _mdt_refused(MDT.Race, fn("time"), name, :time)
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# #1387: every number function over a UUIDField column is refused on every engine
# A UUID holds no number, so the message names no spelling for one. Expected SQL: none.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1387: a number function over a UUID column is refused on every engine" begin
  for (fn, name) in _MDT_FUNCTIONS
    _mdt_refused(MDT.Field_validation_scratch, fn("uuid_token"), name, :uuid)
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# #1387: a date EXPRESSION is a date too
# The type walk names date arithmetic, an extremum of a date and `F` over a date column as a date, so
# a number function over one is refused as over the column. An expression has no column to name a
# `__@year` transform on, so the message names `Extract` only. Expected SQL: none.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1387: a number function over a date expression is refused on every engine" begin
  for (fn, name) in _MDT_FUNCTIONS
    _mdt_refused(MDT.Race, fn(_DF("date") + Day(1)), name, :date)
  end
  _mdt_refused(MDT.Race, Fn.Floor(Fn.Max("date")), "Floor", :date)
  _mdt_refused(MDT.Race, Fn.Round(_DF("date")), "Round", :date; label = "date")
  for (conn, _) in _MDT_ENGINES
    err = _mdt_refusal(MDT.Race, Fn.Round(_DF("date") + Day(1)); conn = conn)
    @test err isa QueryBuildError && !occursin("__@year", _mdt_msg(err))
  end
  # A transform path is a date too (`start_at__@date`); it already ends in a transform, so no
  # `__@year` is appended to it.
  _mdt_refused(MDT.Race, Fn.Power("start_at__@date", 2), "Power", :date)
  _mdt_refused(MDT.Race, Fn.Round(_DF("start_at__@date")), "Round", :date)
  for (conn, _) in _MDT_ENGINES
    err = _mdt_refusal(MDT.Race, Fn.Round(_DF("start_at__@date")); conn = conn)
    @test err isa QueryBuildError && !occursin("__@date__@year", _mdt_msg(err))
  end
  # Under arithmetic too: `Round(<a date>) / 2` is refused at the `Round`, before the quotient.
  _mdt_refused(MDT.Race, Fn.Round(_DF("date") + Day(1)) / 2, "Round", :date)
end

# ─────────────────────────────────────────────────────────────────────────────
# #1387: what a number function means keeps building
# Every function over a number builds as before, `Sum` and `Avg` over a duration still build (their
# domain holds `:interval`), and each spelling the refusal names builds where the engine has it: a
# calendar part, a clock part, a day count and, on PostgreSQL and MySQL, a date's `EPOCH`. Expected
# SQL: as before.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1387: math over numbers and durations, and the named spellings, build" begin
  for (conn, _) in _MDT_ENGINES
    for (fn, _) in _MDT_FUNCTIONS
      @test _mdt_refusal(MDT.Result, fn("points"); conn = conn) === nothing
      @test _mdt_refusal(MDT.Result, fn("grid"); conn = conn) === nothing
    end
    @test _mdt_refusal(MDT.Result, Fn.Sum("fastestlaptime"); conn = conn) === nothing
    @test _mdt_refusal(MDT.Result, Fn.Avg("fastestlaptime"); conn = conn) === nothing
    @test _mdt_refusal(MDT.Race, Fn.Round(Fn.Extract("date", "year")); conn = conn) === nothing
    @test _mdt_refusal(MDT.Race, Fn.Sum("start_at__@year"); conn = conn) === nothing
    @test _mdt_refusal(MDT.Race, Fn.Sum(Fn.Extract("time", "hour")); conn = conn) === nothing
    @test _mdt_refusal(MDT.Race, Fn.Abs(_DF("date") - _DF("date")); conn = conn) === nothing
  end
  for conn in (_MDT_PG, _MDT_MY)
    @test _mdt_refusal(MDT.Race, Fn.Round(Fn.Extract("date", "epoch")); conn = conn) === nothing
  end
  @test _mdt_refusal(MDT.Race, Fn.Round(Fn.Extract("time", "epoch")); conn = _MDT_PG) === nothing
end

# ─────────────────────────────────────────────────────────────────────────────
# #1387: what stays out of the check
# Text has its own refusal (#1293, below) and a boolean its own (#1386, #953): neither meets the #1387
# message. A JSON key lookup is a value the walk cannot type, which is let through:
# `Round("payload__lap")` builds, as before. Expected: no #1387 message; the JSON key and
# `Round`/`Abs` over a boolean build, and `Sum` of a boolean keeps #953.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1387: text, booleans and untyped operands are not this check's" begin
  for (conn, _) in _MDT_ENGINES
    for expr in (Fn.Round("positiontext"), Fn.Abs("positiontext"), Fn.Sum("positiontext"))
      err = _mdt_refusal(MDT.Result, expr; conn = conn)
      @test err === nothing || !occursin("#1387", _mdt_msg(err))
    end
    for expr in (Fn.Round("payload__lap"), Fn.Sum("payload__lap"), Fn.Abs("payload__lap"))
      @test _mdt_refusal(MDT.Field_validation_scratch, expr; conn = conn) === nothing
    end
    for expr in (Fn.Round("boolean_field"), Fn.Abs("boolean_field"))
      @test _mdt_refusal(MDT.New_join_position, expr; conn = conn) === nothing
    end
    err = _mdt_refusal(MDT.New_join_position, Fn.Sum("boolean_field"); conn = conn)
    @test err isa QueryBuildError && occursin("(#953)", _mdt_msg(err)) && !occursin("#1387", _mdt_msg(err))
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# #1293: every number function over text is refused on every engine
# EXPLICIT INTENT: PostgreSQL rejects text that is no number (or computes the number it spells), and
# SQLite reads it as 0, so the query must say the text holds numbers. Every number function in
# `_MDT_FUNCTIONS` over a `CharField` column, a `Concat`, an `Upper`, a `__@yyyy_mm` label and a string
# literal, the text as either operand of `Power`. `Round(x, 2)` meets the #1061 refusal first. A cast
# around the text says it holds numbers and builds; a JSON key lookup is untyped and builds, as before.
# Expected SQL (the remedy, PostgreSQL): FLOOR((("Tb"."positiontext")::float)::numeric)
# Why: before #1293 `Round("positiontext")` and `Floor("positiontext")` built, and SQLite answered 0.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1293: a number function over text is refused on every engine" begin
  texts = (("column", "positiontext", "`positiontext`"), ("Concat", Fn.Concat("positiontext", "positiontext"), "the value"),
           ("Upper", Fn.Upper("positiontext"), "the value"), ("label", "raceid__date__@yyyy_mm", "the value"),
           ("literal", Fn.Value("12"), "the value"))
  for (conn, engine) in _MDT_ENGINES, (fn, name) in _MDT_FUNCTIONS, (what, operand, named) in texts
    err = _mdt_refusal(MDT.Result, fn(operand); conn = conn)
    label = (engine, name, what)
    @test (label, err isa QueryBuildError) == (label, true)
    err isa QueryBuildError || continue
    msg = _mdt_msg(err)
    if occursin("Round(…, 2)", msg)
      @test (label, occursin("(#1061)", msg)) == (label, true)
      continue
    end
    @test (label, occursin("`$(name)` of text is not supported: $(named) is text", msg) &&
                  occursin("on any engine (#1293)", msg) && occursin("Cast(x, FloatField())", msg)) == (label, true)
    @test !any(n -> occursin(n, msg), ("PostgreSQL", "SQLite", "MySQL"))
  end
  for (conn, engine) in _MDT_ENGINES
    # Wherever the function is nested: a cast over it is refused too.
    err = _mdt_refusal(MDT.Result, Fn.Cast(Fn.Floor("positiontext"), "integer"); conn = conn)
    @test (engine, err isa QueryBuildError && occursin("(#1293)", _mdt_msg(err))) == (engine, true)
    # The remedy builds, and a JSON key lookup is untyped and builds as before.
    for expr in (Fn.Floor(Fn.Cast("positiontext", Models.FloatField())), Fn.Round(Fn.Cast("positiontext", Models.FloatField())))
      @test (engine, _mdt_refusal(MDT.Result, expr; conn = conn)) == (engine, nothing)
    end
    for expr in (Fn.Round("payload__lap"), Fn.Floor("payload__lap"), Fn.Mod("payload__lap", 2))
      @test (engine, _mdt_refusal(MDT.Field_validation_scratch, expr; conn = conn)) == (engine, nothing)
    end
  end
  @test occursin("FLOOR(((\"Tb\".\"positiontext\")::float)::numeric)",
                 _mdt_render(MDT.Result, Fn.Floor(Fn.Cast("positiontext", Models.FloatField())); conn = _MDT_PG))
end

# ─────────────────────────────────────────────────────────────────────────────
# #1387: which engines read the EPOCH of each temporal kind
# The engine fact the refusal reads: PostgreSQL reads a date's, a timestamp's and a time's; MySQL a
# date's and a timestamp's (its `Extract` refuses a time's); SQLite has no `EPOCH` part.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1387: the engine fact for EPOCH by kind" begin
  QB = PormG.QueryBuilder
  K = PormG.Kernel
  for kind in (K.CDate(), K.CDateTime(true), K.CDateTime(false), K.CTime())
    @test QB._extracts_epoch_of(_MDT_PG, kind)
    @test !QB._extracts_epoch_of(_MDT_SL, kind)
  end
  @test QB._extracts_epoch_of(_MDT_MY, K.CDate())
  @test QB._extracts_epoch_of(_MDT_MY, K.CDateTime(true))
  @test !QB._extracts_epoch_of(_MDT_MY, K.CTime())
end
