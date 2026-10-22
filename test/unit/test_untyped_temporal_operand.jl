"""
#1310 — arithmetic or an ordering beside a date, a timestamp or an interval, with a side the type walk
cannot name, is refused on the engines that compute on what they store (SQLite, MySQL), and builds
unchanged on PostgreSQL.

The render writes the SQL of `+`, `-`, `*`, `/` and of `<`, `>`, `<=`, `>=` beside a temporal value by
its type: a whole-day shift, an interval in milliseconds, a date's text. A side `_expression_kind`
cannot name — a JSON key lookup, a `Case` or a `Coalesce` whose values disagree — fell to the generic
`(l op r)`, which SQLite computes on a date's or an interval's text: `Case(<a duration>) * 2` was `0`
(#1301) and `Case(<a date>) + 1` was `2010` (#1307), each fixed by teaching the walk one more shape
after a review found it. #1310 refuses the shape instead, when the walk has not named it:

| shape | PostgreSQL | SQLite, MySQL |
|---|---|---|
| a side the walk cannot name, the other side a date, a timestamp or an interval | builds: the server types the operands | refused |
| a side the walk cannot name that holds one (`Case`, `Coalesce`, `Max` over it), beside anything | builds | refused |
| equality, `@in`, a number beside a number (`F("meta__round") * 2`) | builds | builds |

Which engine refuses is the engine fact `_types_temporal_operands`. MySQL renders the conditionals
(`Case`, `Coalesce`) since #1130 phase 2c-1, so those shapes are checked live on MySQL below; JSON key
lookups, math and window functions are later phases, so the rest of its refusal is pinned through its
constructor here.

Everything renders through mock connections — no live database, no fixture.

julia --project=test/integration test/unit/test_untyped_temporal_operand.jl
"""

using Test
using Dates
using PormG
using PormG.Models
using PormG.QueryBuilder: inspect_query, F, Case, When, Cast, Count, Extract, Max
import PormG: QueryBuildError

# Dedicated config key + mock types: `runtests.jl` includes every unit file into one `Main`, so a
# shared key would let another file's settings decide this file's dialect.
struct UttMockSQLite <: PormG.PormGSQLite end
struct UttMockPostgres <: PormG.PormGPostgres end
struct UttMockMySQL <: PormG.PormGMySQL end
const _UTT_SL = UttMockSQLite()
const _UTT_PG = UttMockPostgres()
const _UTT_MY = UttMockMySQL()
PormG.backend_sqlite_version(::UttMockSQLite) = 3045000

PormG.config["utt_mock"] = PormG.Configuration.Settings(
  connections = _UTT_SL, change_data = true, db_def_folder = "utt_mock",
)

# A race with a date, a timestamp, a fastest-lap duration, an integer and a JSON document.
module UttModels
import PormG
import PormG.Models

Utt_race = Models.Model("utt_race",
  raceid         = Models.IDField(),
  year           = Models.IntegerField(),
  date           = Models.DateField(null = true),
  start_at       = Models.DateTimeField(null = true),
  fastestlaptime = Models.DurationField(null = true),
  meta           = Models.JSONField(null = true),
)

PormG.Models.set_models(@__MODULE__, "utt_mock")
end

const UTT = UttModels
const Fn = PormG.Functions

# A queryset projecting `expr` ("v") or filtering on it, rendered on `conn`: the SQL text on one line
# and the parameters.
function _utt_render(expr; conn, filter::Bool = false)
  q = UTT.Utt_race.objects
  filter ? (q.values("raceid"); q.filter(expr)) : q.values("v" => expr)
  r = inspect_query(q; connection = conn)
  return replace(strip(r[:sql_text]), r"\s+" => " "), r[:parameters]
end
_utt_sql(expr; conn, filter::Bool = false) = first(_utt_render(expr; conn, filter))
function _utt_refusal(expr; conn, filter::Bool = false)
  try
    _utt_render(expr; conn, filter)
  catch e
    return e
  end
  return nothing
end

# A `Case` the walk cannot name, one value a JSON key and the other a duration or a date, and one over an
# integer and a date (#1307's shape, with a column where #1307 had a JSON key).
_utt_case_lap() = Case(When("year" => 2009, then = F("meta__round")), default = F("fastestlaptime"))
_utt_case_date() = Case(When("year" => 2009, then = F("meta__round")), default = F("date"))
_utt_case_year_date() = Case(When("year" => 2009, then = F("year")), default = F("date"))

# ─────────────────────────────────────────────────────────────────────────────
# The engine fact: PostgreSQL types the operands of temporal arithmetic itself; SQLite and MySQL do not.
# Expected: `_types_temporal_operands` is true on PostgreSQL, false on SQLite and on MySQL.
# Why it matters: it is the one place that decides which engine refuses; a new backend has no method
# (`test_engine_facts.jl`) and must decide it.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1310: which engines type temporal operands themselves" begin
  @test PormG.QueryBuilder._types_temporal_operands(_UTT_PG) === true
  @test PormG.QueryBuilder._types_temporal_operands(_UTT_SL) === false
  @test PormG.QueryBuilder._types_temporal_operands(_UTT_MY) === false
end

# ─────────────────────────────────────────────────────────────────────────────
# A side the walk cannot name beside a date or an interval: refused on SQLite, unchanged on PostgreSQL.
# Expected SQL on PostgreSQL (each built before #1310 and still does):
#   F("date") * F("meta__round")            -> ("Tb"."date" * "Tb"."meta" #>> '{"round"}')
#   F("meta__round") > F("date")             -> WHERE ("Tb"."meta" #>> '{"round"}' > "Tb"."date")
#   F("fastestlaptime") > F("meta__round")   -> WHERE ("Tb"."fastestlaptime" > "Tb"."meta" #>> '{"round"}')
#   F("meta__round") > Date(2009, 1, 1)      -> WHERE ("Tb"."meta" #>> '{"round"}' > $1), ["2009-01-01"]
# On SQLite each built the generic `(l op r)` before #1310: a JSON value against a date's text, or
# against an interval's `HH:MM:SS` text, where every number sorts before every text. Now each is a
# `QueryBuildError` naming the operator and the side, the key path as the caller wrote it.
# Why it matters: the SQL for a temporal value is chosen by its type, and the JSON key's type is the
# data's; SQLite's answer depends on what the document happens to hold.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1310: a JSON key lookup beside a date or an interval" begin
  @test _utt_sql(F("date") * F("meta__round"); conn = _UTT_PG) ==
        "SELECT (\"Tb\".\"date\" * \"Tb\".\"meta\" #>> '{\"round\"}') as \"v\" FROM \"utt_race\" as \"Tb\""
  @test _utt_sql(F("meta__round") > F("date"); conn = _UTT_PG, filter = true) ==
        "SELECT \"Tb\".\"raceid\" as \"raceid\" FROM \"utt_race\" as \"Tb\" WHERE (\"Tb\".\"meta\" #>> '{\"round\"}' > \"Tb\".\"date\")"
  @test _utt_sql(F("fastestlaptime") > F("meta__round"); conn = _UTT_PG, filter = true) ==
        "SELECT \"Tb\".\"raceid\" as \"raceid\" FROM \"utt_race\" as \"Tb\" WHERE (\"Tb\".\"fastestlaptime\" > \"Tb\".\"meta\" #>> '{\"round\"}')"
  @test _utt_render(F("meta__round") > Date(2009, 1, 1); conn = _UTT_PG, filter = true) ==
        ("SELECT \"Tb\".\"raceid\" as \"raceid\" FROM \"utt_race\" as \"Tb\" WHERE (\"Tb\".\"meta\" #>> '{\"round\"}' > \$1)",
         Any["2009-01-01"])

  for (label, expr, filter, op) in (
      ("date * key",       F("date") * F("meta__round"),           false, "*"),
      ("key > date",       F("meta__round") > F("date"),           true,  ">"),
      ("date > key",       F("date") > F("meta__round"),           true,  ">"),
      ("key > duration",   F("meta__round") > F("fastestlaptime"), true,  ">"),
      ("duration <= key",  F("fastestlaptime") <= F("meta__round"), true, "<="),
      ("key < Date",       F("meta__round") < Date(2009, 1, 1),    true,  "<"),
    )
    @testset "$label" begin
      e = _utt_refusal(expr; conn = _UTT_SL, filter)
      @test e isa QueryBuildError
      @test occursin("`$(op)` beside a date, a timestamp or an interval", e.msg)
      @test occursin("with `meta__round` on one side", e.msg)
      @test occursin("not supported on SQLite", e.msg)
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# A side the walk cannot name that HOLDS a date or an interval, beside a number: refused on SQLite.
# Expected SQL on PostgreSQL (unchanged):
#   Case(When("year" => 2009, then = F("meta__round")), default = F("fastestlaptime")) * 2
#     -> (CASE WHEN "Tb"."year" = $1 THEN "Tb"."meta" #>> '{"round"}' ELSE "Tb"."fastestlaptime" END * $2::bigint)
# On SQLite the same shapes built `(CASE … END * ?)`: #1301's `'00:01:30' * 2 = 0` and #1307's
# `'2009-03-29' + 1 = 2010`, reached through a `Case` the walk cannot name, a `Coalesce`, a `Max` over
# such a `Case`, the `Case` on the right, a date or `0` added to a number, `Floor` of a duration (the
# floor of its text), and an ordering. Each is now refused, naming the function.
# Why it matters: the walk names neither value, so the render cannot know the arithmetic is temporal;
# the fact that a date or a duration is one of the values is enough to know the generic SQL is wrong.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1310: a value the walk cannot name holding a date or a duration" begin
  @test _utt_render(_utt_case_lap() * 2; conn = _UTT_PG) ==
        ("SELECT (CASE WHEN \"Tb\".\"year\" = \$1 THEN \"Tb\".\"meta\" #>> '{\"round\"}' ELSE \"Tb\".\"fastestlaptime\" END * \$2::bigint) as \"v\" FROM \"utt_race\" as \"Tb\"",
         Any[2009, 2])

  for (label, expr, filter, op, named) in (
      ("Case(key | duration) * 2",  _utt_case_lap() * 2,                         false, "*", "`CASE(…)`"),
      ("Case(key | date) + 1",      _utt_case_date() + 1,                        false, "+", "`CASE(…)`"),
      ("Case(year | date) + 1",     _utt_case_year_date() + 1,                   false, "+", "`CASE(…)`"),
      ("year + Case(year | date)",  F("year") + _utt_case_year_date(),           false, "+", "`CASE(…)`"),
      ("Coalesce(key, date) + 1",   Fn.Coalesce("meta__round", "date") + 1,      false, "+", "`COALESCE(…)`"),
      ("Coalesce(key, dur) * 2",    Fn.Coalesce("meta__round", "fastestlaptime") * 2, false, "*", "`COALESCE(…)`"),
      ("Max(Case(key | date)) + 1", Max(_utt_case_date()) + 1,                   false, "+", "`MAX(…)`"),
      ("year + Coalesce(date, 0)",  F("year") + Fn.Coalesce("date", 0),          false, "+", "`COALESCE(…)`"),
      ("Floor(duration) / 2",       Fn.Floor(F("fastestlaptime") * 2) / 2,       false, "/", "`FLOOR(…)`"),
      ("Lag(key, default = date) + 1",
       PormG.QueryBuilder.Lag("meta__round", default = F("date"), over = PormG.QueryBuilder.WindowOver(order_by = "raceid")) + 1,
                                                                                  false, "+", "`LAG(…)`"),
      ("Case(key | duration) > 2",  _utt_case_lap() > 2,                         true,  ">", "`CASE(…)`"),
    )
    @testset "$label" begin
      @test _utt_refusal(expr; conn = _UTT_PG, filter) === nothing
      e = _utt_refusal(expr; conn = _UTT_SL, filter)
      @test e isa QueryBuildError
      @test occursin("`$(op)` beside a date, a timestamp or an interval, with $(named) on one side", e.msg)
      # #1130 phase 2c-1: MySQL renders the conditionals, so a shape with no JSON key, math or window
      # function reaches its refusal live, naming MySQL.
      if !any(w -> occursin(w, label), ("key", "Floor", "Lag"))
        m = _utt_refusal(expr; conn = _UTT_MY, filter)
        @test m isa QueryBuildError
        @test occursin("`$(op)` beside a date, a timestamp or an interval, with $(named) on one side, is not " *
                       "supported on MySQL", m.msg)
      end
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# What keeps building on SQLite: where the value only passes, or the type is named.
# Expected: each builds on SQLite, as before #1310. A JSON key times a number or an integer column, and
# ordered against a number (`json_extract(…) * ?`); a JSON key compared for EQUALITY with a date; a
# function that names its own result over a date (`Count`, `Extract(…, "YEAR")`); the remedies the
# message gives — a `Cast` of the `Case` to a date, and the arithmetic inside each branch.
# Why it matters: the rule is positional, not global. A JSON key lookup is the largest source of "cannot
# name" and is correct as written beside a number; refusing it everywhere would trade one wrong answer
# for a wall of refusals.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1310: shapes that keep building on SQLite" begin
  @test _utt_render(F("meta__round") * 2; conn = _UTT_SL) ==
        ("SELECT (json_extract(\"Tb\".\"meta\", '\$.round') * ?) as \"v\" FROM \"utt_race\" as \"Tb\"", Any[2])
  @test _utt_sql(F("meta__round") == F("date"); conn = _UTT_SL, filter = true) ==
        "SELECT \"Tb\".\"raceid\" as \"raceid\" FROM \"utt_race\" as \"Tb\" WHERE (json_extract(\"Tb\".\"meta\", '\$.round') = \"Tb\".\"date\")"
  for (label, expr, filter) in (
      ("key * year",                    F("meta__round") * F("year"),                      false),
      ("key > 2",                       F("meta__round") > 2,                              true),
      ("Case(key | date) == 2",         _utt_case_date() == 2,                             true),
      ("Count(date) * 2",               Count("date") * 2,                                 false),
      ("Extract(date, YEAR) * 2",       Extract("date", "YEAR") * 2,                       false),
      ("Cast(Case(key | date)) + 1",    Cast(_utt_case_date(), "date") + 1,                false),
      ("arithmetic in each branch",
       Case(When("year" => 2009, then = F("date") + 1), default = F("date") + 2),          false),
      ("date + 1",                      F("date") + 1,                                     false),
      ("date > Date",                   F("date") > Date(2009, 1, 1),                      true),
    )
    @testset "$label" begin
      @test _utt_refusal(expr; conn = _UTT_SL, filter) === nothing
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# An arm that already refused keeps its own message.
# Expected: `F("date") + F("meta__round")` on SQLite raises #882's "`+` between a date and a value PormG
# cannot type", not #1310's: the new check runs only on a shape no arm typed or refused.
# Why it matters: existing refusals name the spelling for their own shape (a day count, a duration).
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1310: an earlier refusal keeps its message" begin
  e = _utt_refusal(F("date") + F("meta__round"); conn = _UTT_SL)
  @test e isa QueryBuildError
  @test occursin("between a date and a value PormG cannot type", e.msg)
  @test !occursin("beside a date, a timestamp or an interval", e.msg)
end

# ─────────────────────────────────────────────────────────────────────────────
# The message names the engine at hand and the spellings that exist there.
# Expected: on SQLite it offers the branch spelling and a cast to a number or a date, and no timestamp
# cast (SQLite refuses one, #822); on MySQL it names MySQL's reading of a date and offers a timestamp
# cast too. Neither names another engine.
# Why it matters: a remedy that is itself a `BackendCapabilityError` on this engine is a dead end.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1310: the refusal's remedies are the engine's own" begin
  # A date at stake: the branch spelling, or a cast to a date, which SQLite renders (`date(x)`).
  sl = _utt_refusal(_utt_case_date() + 1; conn = _UTT_SL).msg
  @test occursin("inside each branch", sl) && occursin("Cast(…, \"date\")", sl)
  # A duration at stake: SQLite casts an interval to nothing, and to a number refuses it (#1259), so the
  # one spelling is the branch one, with a duration where `0` was.
  lap = _utt_refusal(_utt_case_lap() * 2; conn = _UTT_SL).msg
  @test occursin("inside each branch", lap) && occursin("default = Second(0)", lap)
  @test !occursin("Cast(", lap)
  # A timestamp at stake: SQLite cannot cast to one (#822).
  ts = _utt_refusal(F("start_at") > F("meta__round"); conn = _UTT_SL, filter = true).msg
  @test !occursin("Cast(", ts)
  for msg in (sl, lap, ts)
    @test !occursin("Cast(…, \"integer\")", msg)
    @test !occursin("PostgreSQL", msg) && !occursin("MySQL", msg)
  end

  QB = PormG.QueryBuilder
  my = QB._unnamed_temporal_refusal(_UTT_MY, "+", "`CASE(…)`", PormG.CDateTime(false))
  @test my isa QueryBuildError
  @test occursin("not supported on MySQL", my.msg)
  @test occursin("the number its digits spell", my.msg)
  @test occursin("Cast(…, \"timestamp\")", my.msg)
  @test !occursin("PostgreSQL", my.msg) && !occursin("SQLite", my.msg)
  @test !occursin("Cast(", QB._unnamed_temporal_refusal(_UTT_MY, "*", "`CASE(…)`", PormG.CInterval()).msg)
end

# ─────────────────────────────────────────────────────────────────────────────
# Every spelling of an ordering takes the rule: a filter pair, an alias, a `Q`, a `When` condition, and
# an `update()` value.
# Expected on SQLite: `filter("date__@gt" => F("meta__round"))`, `filter("fastestlaptime__@gt" =>
# <Case(key | duration)>)`, a projected `Case(key | date)` filtered by its alias against a date, the same
# pair inside `Q(...)`, a `When` comparing the key with a date, and `update("date" => Case(key | date) + 1)`
# each raise the refusal; PostgreSQL builds each. A typed alias (`F("date") + 1`) filtered against a date,
# and `"date__@range" => [Date, Date]`, build on SQLite.
# Why it matters: one comparison spelled two ways must not build in one and be refused in the other
# (#1311 fixed that asymmetry for duration aliases).
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1310: filter pairs, aliases, Q, When and update take the rule" begin
  QB = PormG.QueryBuilder
  refused = (
    ("pair date > key",       q -> q.filter("date__@gt" => F("meta__round")),                        "`meta__round`"),
    ("pair duration > Case",  q -> q.filter("fastestlaptime__@gt" => _utt_case_lap()),               "`CASE(…)`"),
    ("alias Case > Date",     q -> (q.values("raceid", "c" => _utt_case_date()); q.filter("c__@gt" => Date(2009, 1, 1))), "`CASE(…)`"),
    ("Q pair",                q -> q.filter(QB.Q("date__@lt" => F("meta__round"))),                  "`meta__round`"),
    ("When condition",        q -> q.values("w" => Case(When(F("meta__round") > F("date"), then = 1), default = 0)), "`meta__round`"),
  )
  for (label, build, named) in refused
    @testset "$label" begin
      for (conn, refuses) in ((_UTT_PG, false), (_UTT_SL, true))
        q = UTT.Utt_race.objects
        e = try build(q); inspect_query(q; connection = conn); nothing catch err; err end
        if refuses
          @test e isa QueryBuildError
          @test e isa QueryBuildError && occursin("with $(named) on one side", e.msg)
        else
          @test e === nothing
        end
      end
    end
  end
  # update(): the SET value is an F render of its own (`_set_update_query_typed`).
  upd = try
    q = UTT.Utt_race.objects
    q.filter("raceid" => 1)
    q.update("date" => _utt_case_date() + 1; show_query = :sql)
    nothing
  catch err
    err
  end
  @test upd isa QueryBuildError && occursin("with `CASE(…)` on one side", upd.msg)
  # A typed alias and a date range on a date column keep building, with the SQL they had.
  q = UTT.Utt_race.objects
  q.values("raceid"); q.filter("date__@range" => [Date(2009, 1, 1), Date(2010, 1, 1)])
  @test occursin("WHERE \"Tb\".\"date\" BETWEEN ? AND ?", inspect_query(q; connection = _UTT_SL)[:sql_text])
  q = UTT.Utt_race.objects
  q.values("raceid", "c" => F("date") + 1); q.filter("c__@gt" => Date(2009, 1, 1))
  @test occursin("WHERE date(\"Tb\".\"date\", '+' || ? || ' days') > ?", inspect_query(q; connection = _UTT_SL)[:sql_text])
end

# ─────────────────────────────────────────────────────────────────────────────
# A correlated subquery ordering a date, a timestamp or a duration against its `OuterRef` keeps building.
# Expected on SQLite: `Exists(<races with "date__@gt" => OuterRef("date")>)` renders
# `EXISTS (SELECT 1 … WHERE "U1"."date" > "Tb"."date" …)`-shaped SQL (no refusal), and so do the
# timestamp and duration columns, and a `Subquery` correlated the same way.
# Why it matters: the walk names an `OuterRef` through the outer query's column; read as a value PormG
# cannot type, every temporal correlation would be refused (found in review of #1310).
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1310: a temporal OuterRef correlation keeps building" begin
  QB = PormG.QueryBuilder
  for path in ("date", "start_at", "fastestlaptime")
    @testset "$path" begin
      inner = UTT.Utt_race.objects
      inner.filter("$(path)__@gt" => QB.OuterRef(path))
      q = UTT.Utt_race.objects
      q.values("raceid"); q.filter(QB.Exists(inner))
      sql = inspect_query(q; connection = _UTT_SL)[:sql_text]
      @test occursin("EXISTS", sql) && occursin("\"Tb\".\"$(path)\"", sql)
    end
  end
  inner = UTT.Utt_race.objects
  inner.filter("date__@lt" => QB.OuterRef("date"))
  inner.values("raceid")
  inner.limit(1)
  q = UTT.Utt_race.objects
  q.values("raceid", "earlier" => QB.Subquery(inner))
  sql = inspect_query(q; connection = _UTT_SL)[:sql_text]
  @test occursin("< \"Tb\".\"date\"", sql)
end
