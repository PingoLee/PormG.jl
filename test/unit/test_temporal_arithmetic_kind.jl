using Test
using Dates
using PormG
using PormG.Models: Model, IDField, IntegerField, BigIntegerField, DateField, DateTimeField, DurationField
using PormG.QueryBuilder: inspect_query, F, Max, Sum, Avg
using PormG.Functions: Abs, Greatest, Case, When

# ─────────────────────────────────────────────────────────────────────────────
# #1034 phase 3 step 5a: the type walk types F temporal arithmetic, as its render does.
#
# `date - date`, `timestamp - timestamp`, a date shifted by a duration, a day count or an interval, and
# interval arithmetic were typed by the render alone (`_render_expr_typed`), which records the kind it
# computes for a projection (`projection_kinds`). The walk (`_expression_kind`) answered `nothing` for
# all of them, so every reader that is not the render — the value formatter, a pattern lookup's
# refusal, the #1200 temporal mix, the #1111 division leaf, `Abs`/`Round` over an integer — saw no
# type. The walk now answers each one (step 5a), and since step 5b the walk and the render ask one copy
# of the rule (`_temporal_result_kind`), so the two agree by construction.
#
# Every testset runs on both mock backends: the kinds are the same on both, and SQLite holds an
# interval as milliseconds only while it computes.
# ─────────────────────────────────────────────────────────────────────────────
struct TakMockPostgres <: PormG.PormGPostgres end
struct TakMockSQLite <: PormG.PormGSQLite end
PormG.backend_sqlite_version(::TakMockSQLite) = 3045000

PormG.config["tak_pg"] = PormG.Configuration.Settings(connections = TakMockPostgres(), change_data = true)
PormG.config["tak_sl"] = PormG.Configuration.Settings(connections = TakMockSQLite(), change_data = true)

function _tak_model(key)
  m = Model("tak_races", raceid = IDField(), year = IntegerField(), laps_total = BigIntegerField(),
            date = DateField(), start_at = DateTimeField(), laptime = DurationField())
  m.connect_key = key
  return m
end
const _TAK_MODELS = ((:postgres, _tak_model("tak_pg")), (:sqlite, _tak_model("tak_sl")))

# The kind the render itself gives the expression (`_render_expr_typed`, an interval it holds in SQLite
# milliseconds named as the interval it leaves), and the walk's kind for it, both after the one build.
# Not `projection_kinds`: the read path falls back to the walk where the render says nothing, so it
# could not show a kind only the walk names (review of #1034 step 5a).
function _tak_kinds(Model_, expr)
  QB = PormG.QueryBuilder
  q = Model_.objects
  q.values("v" => expr)
  instr = QB.build(q.object)
  source = QB._projected_source(QB.memo_key(:base, "v"), instr).field
  rendered = source isa PormG.QueryBuilder.FExpression ? last(QB._render_expr_typed(source, instr)) : get(instr.projection_kinds, :v, nothing)
  rendered isa QB._IntervalMs && (rendered = PormG.CInterval())
  return rendered, QB._expression_kind(source, instr)
end

# ─────────────────────────────────────────────────────────────────────────────
# Each arm of F temporal arithmetic: the walk's kind is the render's.
# Expected, on both engines: a date shifted by whole days (a `Day`, an integer literal, an integer
# column) is a date, and by a sub-day part a timestamp without time zone; a timestamp shifted keeps its
# own kind; `date - date` is the `integer` day count; `timestamp - timestamp` is an interval; a date or
# a timestamp plus an interval is a timestamp; interval arithmetic, and an interval times or divided by
# a number on either side, is an interval; a function over one (`Max`) has its kind. Before step 5a the
# walk answered `nothing` on every row, while the render recorded the kind shown.
# Why it matters: a reader that asks the walk must see the type the render gives the SQL.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1034 step 5a: the walk types each arm of F temporal arithmetic as its render does" begin
  shapes = (
    (F("date") + Day(1),                  PormG.CDate()),
    (F("date") + 1,                       PormG.CDate()),
    (F("date") - F("year"),               PormG.CDate()),
    (F("date") + Hour(1),                 PormG.CDateTime(false)),
    (F("start_at") - Hour(1),             PormG.CDateTime(true)),
    (F("date") - F("date"),               PormG.CInt32()),
    (F("start_at") - F("start_at"),       PormG.CInterval()),
    (F("date") + F("laptime"),            PormG.CDateTime(false)),
    (F("start_at") + F("laptime"),        PormG.CDateTime(true)),
    (F("laptime") + F("laptime"),         PormG.CInterval()),
    (F("laptime") * 2,                    PormG.CInterval()),
    (F("laptime") / F("year"),            PormG.CInterval()),
    (F("year") * F("laptime"),            PormG.CInterval()),
    (Max(F("start_at") - F("start_at")),  PormG.CInterval()),
  )
  for (backend, Model_) in _TAK_MODELS, (expr, expected) in shapes
    @testset "$backend: $(expected)" begin
      rendered, walked = _tak_kinds(Model_, expr)
      @test rendered == expected
      @test walked == expected
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# What the render leaves untyped, the walk leaves untyped.
# Expected, on PostgreSQL (SQLite refuses each at build): an interval plus a number, and a date times
# a number, are `nothing` to both, so no reader is handed a type the SQL does not have; a date part
# plus a number is the walk's integer, as it was before step 5a.
# Why it matters: the walk must never name a temporal kind the render does not compute.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1034 step 5a: what the render leaves untyped stays untyped to the walk" begin
  pg = _TAK_MODELS[1][2]
  for expr in (F("laptime") + 2, F("date") * 2)
    rendered, walked = _tak_kinds(pg, expr)
    @test rendered === nothing
    @test walked === nothing
  end
  _, walked = _tak_kinds(pg, F("start_at__@year") + 1)
  @test walked isa Union{PormG.CInt32,PormG.CInt64}
end

# ─────────────────────────────────────────────────────────────────────────────
# A function side over a duration with no millisecond form is an interval (#1301).
# Expected on PostgreSQL: a `Case` over durations, and a function over one (`Sum`, `Max`, `Greatest`),
# times or divided by a number,
# beside another interval, or shifting a date, are typed by the render and the walk alike — an
# interval, and a timestamp for the shift — and the SQL is unchanged:
#   (CASE WHEN "Tb"."year" = $1 THEN "Tb"."laptime" ELSE "Tb"."laptime" END * $2::bigint)
# Expected on SQLite: each is refused when the query is built, as an interval with no millisecond form
# (#881). Before, the side was untyped on both engines, so SQLite multiplied the duration's stored
# text — `'00:01:30' * 2` is `0` — and returned that number, with no error.
# Why it matters: a silent wrong value on SQLite, and on PostgreSQL an interval no reader could see.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1301: a Case over a duration in arithmetic is an interval; SQLite refuses it" begin
  pg_model, sl_model = _TAK_MODELS[1][2], _TAK_MODELS[2][2]
  dur_case() = Case([When("year" => 2009, then = F("laptime"))], default = F("laptime"))
  shapes = (
    (dur_case() * 2,                PormG.CInterval()),
    (F("year") * dur_case(),        PormG.CInterval()),
    (dur_case() / 2,                PormG.CInterval()),
    (Sum(dur_case()) * 2,           PormG.CInterval()),
    (Max(dur_case()) * 2,           PormG.CInterval()),
    (Greatest("laptime", dur_case()) * 2, PormG.CInterval()),
    (dur_case() + F("laptime"),     PormG.CInterval()),
    (F("laptime") - dur_case(),     PormG.CInterval()),
    (F("date") + dur_case(),        PormG.CDateTime(false)),
    (F("start_at") + dur_case(),    PormG.CDateTime(true)),
  )
  for (expr, expected) in shapes
    rendered, walked = _tak_kinds(pg_model, expr)
    @test rendered == expected
    @test walked == expected
    q = sl_model.objects
    q.values("v" => expr)
    err = try inspect_query(q); nothing catch e; e end
    @test err isa PormG.QueryBuildError
    @test occursin("that is not a timestamp difference or a DurationField column is not supported on SQLite",
                   err === nothing ? "" : sprint(showerror, err))
  end
  q = pg_model.objects
  q.values("v" => dur_case() * 2)
  @test occursin("(CASE WHEN \"Tb\".\"year\" = \$1 THEN \"Tb\".\"laptime\" ELSE \"Tb\".\"laptime\" END * \$2::bigint) as \"v\"",
                 replace(inspect_query(q)[:sql_text], r"\s+" => " "))
  # On PostgreSQL the typed result follows a duration's rules, as other duration arithmetic does: a
  # filter on its alias binds a duration's text and refuses a number, a pattern lookup is refused
  # (#1183), and `Concat` refuses it (#1028). Each built before, and failed when the query ran.
  pg_q(build!) = (q = pg_model.objects; q.values("d" => dur_case() * 2); build!(q); q)
  @test inspect_query(pg_q(q -> q.filter("d__@gt" => Hour(1))))[:parameters][end] == "01:00:00"
  refusal(q) = try inspect_query(q); nothing catch e; e end
  msg(e) = e === nothing ? "" : replace(sprint(showerror, e), r"\e\[[0-9;]*m" => "")
  err = refusal(pg_q(q -> q.filter("d__@gt" => 5)))
  @test err isa PormG.InvalidValueError
  @test occursin("the `d` projection alias (duration)", msg(err))
  err = refusal(pg_q(q -> q.filter("d__@startswith" => "0")))
  @test err isa PormG.FilterError
  @test occursin("a pattern lookup", msg(err)) && occursin("this is a duration", msg(err))
  q = pg_model.objects
  q.values("s" => PormG.Functions.Concat(PormG.Functions.Value("-"), dur_case() * 2))
  err = refusal(q)
  @test err isa PormG.QueryBuildError
  @test occursin("an interval expression is not text", msg(err)) && occursin("(#1028)", msg(err))
  # A function SQLite does compute in milliseconds keeps that form (#900): unchanged.
  q = sl_model.objects
  q.values("v" => Max("laptime") * 2)
  @test occursin("_pormg_ms", inspect_query(q)[:sql_text])
end

# ─────────────────────────────────────────────────────────────────────────────
# Ordering an interval with no millisecond form is refused on SQLite (#1301 review).
# Expected on SQLite: a `Case` over durations, a function over one, `Lag` or `NullIf` over a duration,
# ORDERED (`>`, `<`, …) against a duration or an interval, raises `QueryBuildError` when the query is
# built; `==` still compares the stored text: `(CASE … END = ?)`. Expected on PostgreSQL: each builds,
# `(CASE WHEN "Tb"."year" = $1 THEN "Tb"."laptime" ELSE "Tb"."laptime" END > $2)` with `"100:00:00"`.
# Before, SQLite compared the `HH:MM:SS` text (`'99:00:00' > '100:00:00'`), wrong at 100 hours and for
# negative values, or (for the `Case`, untyped before #1301) the comparison raised on both engines.
# Why it matters: a filter must keep the same rows on both engines; text order silently does not.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1301: ordering an interval with no millisecond form is refused on SQLite" begin
  pg_model, sl_model = _TAK_MODELS[1][2], _TAK_MODELS[2][2]
  QB = PormG.QueryBuilder
  dc() = Case([When("year" => 2009, then = F("laptime"))], default = F("laptime"))
  lag() = QB.Lag("laptime"; over = QB.WindowOver(order_by = ["raceid"]))
  flag(cond) = q -> q.values("f" => Case([When(cond, then = 1)], default = 0))
  ordered = (q -> q.filter(dc() > Hour(100)), q -> q.filter(dc() < F("laptime")),
             flag(dc() >= Hour(1)), flag(Max(dc()) > Hour(1)), flag(lag() > Hour(1)),
             q -> q.filter(PormG.Functions.NullIf("laptime", F("laptime")) <= "01:00:00"))
  build(model, f) = (q = model.objects; f(q); inspect_query(q))
  for f in ordered
    err = try build(sl_model, f); nothing catch e; e end
    @test err isa PormG.QueryBuildError
    @test occursin("an interval with no millisecond form", err === nothing ? "" : sprint(showerror, err))
    @test build(pg_model, f) isa AbstractDict
  end
  # Equality compares the stored text on SQLite, as for a `DurationField` column.
  @test occursin("END = ?)", replace(build(sl_model, q -> q.filter(dc() == Hour(1)))[:sql_text], r"\s+" => " "))
  # PostgreSQL binds the duration as its text against the typed interval.
  r = build(pg_model, q -> q.filter(dc() > Hour(100)))
  @test occursin("ELSE \"Tb\".\"laptime\" END > \$2)", replace(r[:sql_text], r"\s+" => " "))
  @test r[:parameters][end] == "100:00:00"
  # A DurationField keeps its millisecond comparison on SQLite.
  @test build(sl_model, q -> q.filter(F("laptime") > Hour(1)))[:parameters] == Any[3_600_000]
end

# ─────────────────────────────────────────────────────────────────────────────
# Ordering such an interval through its ALIAS is refused on SQLite too (#1311).
# Expected on SQLite: an ordering filter (`d__@gt`, `@lte`, `@range`, in `filter`, `Q` or a `When`
# condition) or an `order_by` on the alias of a `Case` whose value is a duration, a `NullIf` or `Max`
# over one, or a `Lag` over a duration (`order_by` only: a window alias is refused in any filter, #685)
# raises `QueryBuildError` naming the alias and the CTE spelling; so does a labelled order term of the
# expression itself, `order_by(SQLOrder(SQLField(<Case>, "d")))`, which never names the alias. `==` and `@in` still compare the text:
#   WHERE CASE WHEN "Tb"."year" = ? THEN "Tb"."laptime" ELSE "Tb"."laptime" END = ?   ["01:00:00"]
# Expected on PostgreSQL: each builds, comparing the `interval` (`ORDER BY "d" DESC`).
# Before, SQLite compared and sorted the `HH:MM:SS` text — `'99:00:00' > '100:00:00'` — wrong at 100
# hours and for negative values, while the same comparison written inside an expression was refused
# (#1301), so the rows kept depended on the spelling.
# Why it matters: a filter or a sort must keep the same rows on both engines; text order silently does not.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1311: ordering an interval alias with no millisecond form is refused on SQLite" begin
  pg_model, sl_model = _TAK_MODELS[1][2], _TAK_MODELS[2][2]
  QB = PormG.QueryBuilder
  FN = PormG.Functions
  dc() = Case([When("year" => 2009, then = F("laptime"))], default = F("laptime"))
  lag() = QB.Lag("laptime"; over = QB.WindowOver(order_by = ["raceid"]))
  nullif() = FN.NullIf("laptime", F("laptime"))
  projected(mk) = q -> q.values("raceid", "d" => mk())
  then(f, g) = q -> (f(q); g(q))
  build(model, f) = (q = model.objects; f(q); inspect_query(q))
  refusal(model, f) = try build(model, f); nothing catch e; e end
  ordered = (
    then(projected(dc), q -> q.filter("d__@gt" => Hour(1))),
    then(projected(dc), q -> q.filter("d__@lte" => "100:00:00")),
    then(projected(dc), q -> q.filter("d__@range" => (Hour(1), Hour(2)))),
    then(projected(dc), q -> q.filter(PormG.QueryBuilder.Q("d__@gt" => Hour(1)))),
    q -> q.values("raceid", "d" => dc(),
                  "f" => Case([When(PormG.QueryBuilder.Q("d__@gt" => Hour(1)), then = 1)], default = 0)),
    then(projected(nullif), q -> q.filter("d__@gt" => Hour(1))),
    q -> (q.values("raceid", "d" => Max(dc())); q.filter("d__@gt" => Hour(1))),
    then(projected(dc), q -> q.order_by("-d")),
    then(projected(nullif), q -> q.order_by("d")),
    then(projected(lag), q -> q.order_by("d")),
  )
  for f in ordered
    err = refusal(sl_model, f)
    @test err isa PormG.QueryBuildError
    msg = err === nothing ? "" : replace(sprint(showerror, err), r"\e\[[0-9;]*m" => "")
    @test occursin("on the `d` alias is not supported on SQLite", msg)
    @test occursin("project it in a CTE", msg)
    # PostgreSQL compares and sorts the interval itself.
    @test build(pg_model, f) isa AbstractDict
  end
  # PostgreSQL compares the interval itself: `CASE … END > $3` with the duration's text.
  r = build(pg_model, then(projected(dc), q -> q.filter("d__@gt" => Hour(1))))
  @test occursin("ELSE \"Tb\".\"laptime\" END > \$3", replace(r[:sql_text], r"\s+" => " "))
  @test r[:parameters][end] == "01:00:00"
  # A labelled order term renders the expression itself rather than the alias (review of #1311): the
  # same refusal on SQLite, under the projection's own label or another one.
  for label in ("d", "x")
    labelled = then(projected(dc), q -> q.order_by(QB.SQLOrder(QB.SQLField(dc(), label))))
    err = refusal(sl_model, labelled)
    @test err isa PormG.QueryBuildError
    msg = err === nothing ? "" : replace(sprint(showerror, err), r"\e\[[0-9;]*m" => "")
    @test occursin("`order_by` on the `$(label)` alias is not supported on SQLite", msg)
    @test occursin("project it in a CTE", msg)
    @test build(pg_model, labelled) isa AbstractDict
  end
  # Equality and membership compare the stored text on SQLite, as for a `DurationField` column.
  r = build(sl_model, then(projected(dc), q -> q.filter("d" => Hour(1))))
  @test occursin("ELSE \"Tb\".\"laptime\" END = ?", replace(r[:sql_text], r"\s+" => " "))
  @test r[:parameters][end] == "01:00:00"
  @test build(sl_model, then(projected(dc), q -> q.filter("d__@in" => [Hour(1), Hour(2)]))) isa AbstractDict
  # An interval alias WITH a millisecond form keeps its millisecond order and comparison (#894).
  r = build(sl_model, q -> (q.values("raceid", "d" => Max("laptime")); q.order_by("d")))
  @test occursin("ORDER BY MAX(((CASE WHEN substr(\"Tb\".\"laptime\", 1, 1) = '-' THEN -1 ELSE 1 END)",
                 replace(r[:sql_text], r"\s+" => " "))
  @test build(sl_model, then(projected(() -> F("laptime")), q -> q.filter("d__@gt" => Hour(1))))[:parameters] == Any[3_600_000]
end

# ─────────────────────────────────────────────────────────────────────────────
# A Case over dates is the date side of F temporal arithmetic (#1307).
# Expected, on both engines: an untyped `Case` whose branches are one date (or timestamp) column
# combines as that column does — shifted by a whole number or an integer column it is the date, minus
# a date it is the `integer` day count, plus an interval it is a timestamp, and a timestamp `Case`
# minus a timestamp is an interval. The render and the walk agree. The SQL is the date-shift arm's:
#   PostgreSQL ((CASE WHEN "Tb"."year" = $1 THEN "Tb"."date" ELSE "Tb"."date" END + make_interval(days => $2::integer)))::date
#   SQLite     date(CASE WHEN "Tb"."year" = ? THEN "Tb"."date" ELSE "Tb"."date" END , '+' || ? || ' days')
# Before, the side was untyped: SQLite added the number to the date's `YYYY-MM-DD` text
# (`'2009-03-29' + 1` is `2010`) with no error, and PostgreSQL rendered `date + $2::bigint`, which it
# has no operator for. A filter on the alias now checks its value as a date, as for `F("date") + 1`.
# Why it matters: a silent wrong value on SQLite, and on PostgreSQL a statement that failed to run.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1307: a Case over dates in date arithmetic is typed as the date it holds" begin
  date_case() = Case([When("year" => 2009, then = F("date"))], default = F("date"))
  zoned_case() = Case([When("year" => 2009, then = F("start_at"))], default = F("start_at"))
  shapes = (
    (date_case() + 1,                 PormG.CDate()),
    (Max(date_case()) + 1,            PormG.CDate()),
    (date_case() - 1,                 PormG.CDate()),
    (1 + date_case(),                 PormG.CDate()),
    (date_case() + F("year"),         PormG.CDate()),
    (date_case() + F("laps_total"),   PormG.CDate()),
    (date_case() - F("date"),         PormG.CInt32()),
    (F("date") - date_case(),         PormG.CInt32()),
    (date_case() + F("laptime"),      PormG.CDateTime(false)),
    (zoned_case() + 1,                PormG.CDateTime(true)),
    (zoned_case() + F("laptime"),     PormG.CDateTime(true)),
    (zoned_case() - F("start_at"),    PormG.CInterval()),
  )
  for (backend, Model_) in _TAK_MODELS, (expr, expected) in shapes
    @testset "$backend: $(expected)" begin
      rendered, walked = _tak_kinds(Model_, expr)
      @test rendered == expected
      @test walked == expected
    end
  end
  # The exact SQL of the issue's shape, per engine: the date-shift arm over the whole `Case`.
  sql(Model_, expr) = (q = Model_.objects; q.values("v" => expr); replace(inspect_query(q)[:sql_text], r"\s+" => " "))
  pg_model, sl_model = _TAK_MODELS[1][2], _TAK_MODELS[2][2]
  @test occursin("((CASE WHEN \"Tb\".\"year\" = \$1 THEN \"Tb\".\"date\" ELSE \"Tb\".\"date\" END + " *
                 "make_interval(days => \$2::integer)))::date as \"v\"", sql(pg_model, date_case() + 1))
  @test occursin("date(CASE WHEN \"Tb\".\"year\" = ? THEN \"Tb\".\"date\" ELSE \"Tb\".\"date\" END , " *
                 "'+' || ? || ' days') as \"v\"", sql(sl_model, date_case() + 1))
  # A filter on the alias checks its value as a date, as it does for `F("date") + 1`.
  for (_, Model_) in _TAK_MODELS
    q = Model_.objects
    q.values("v" => date_case() + 1)
    q.filter("v__@gt" => 10)
    @test_throws PormG.InvalidValueError inspect_query(q)
  end
  # Beside a value PormG cannot type as a day count, the date `Case` is refused on SQLite, as a
  # `DateField` column is: `'2009-03-29' + 1.5` would be `2010.5`.
  q = sl_model.objects
  q.values("v" => date_case() + 1.5)
  @test_throws PormG.QueryBuildError inspect_query(q)
  # A `Case` that mixes a date and a timestamp still says nothing about its type, and is refused (#1200).
  q = sl_model.objects
  q.values("v" => Case([When("year" => 2009, then = F("date"))], default = F("start_at")) + 1)
  @test_throws PormG.QueryBuildError inspect_query(q)
end

# ─────────────────────────────────────────────────────────────────────────────
# Readers that ask the walk see the type now.
# Expected: `Abs(F("date") - F("date"))` keeps the integer day count (#1147), so PostgreSQL renders a
# bare `ABS(…)`, not `ABS((…)::numeric)`; `Greatest("date", F("date") + 1)` agrees on a date, so the
# read path records `CDate` (#824) and SQLite's text reads back as a `Date`.
# Why it matters: the type the render computed reaches every reader, not only the render.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1034 step 5a: Abs over a day count keeps the integer, and a shifted date agrees with a date" begin
  for (backend, Model_) in _TAK_MODELS
    @testset "$backend" begin
      q = Model_.objects
      q.values("v" => Abs(F("date") - F("date")))
      sql = inspect_query(q)[:sql_text]
      @test !occursin("::numeric", sql)
      _, walked = _tak_kinds(Model_, Abs(F("date") - F("date")))
      @test walked isa Union{PormG.CInt32,PormG.CInt64}
      rendered, _ = _tak_kinds(Model_, Greatest("date", F("date") + 1))
      @test rendered == PormG.CDate()
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# The walk asks each node once per question.
# Expected: a sixteen-level nest of a function over arithmetic (`Abs(… * 2) * 2`) is typed in well under
# a second, and so is one over a duration (`Max(… * 2) * 2`), on both engines. Before the memo
# (`_memo_kind`) the walk asked a side once as the render types it and again for the numeric rule, so
# each level doubled the work: 155 ms at depth 16 for the walk alone, measured in review.
# Why it matters: the walk runs on every projection and filter that asks a type.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1034 step 5a: the walk is no longer exponential in the depth of nested arithmetic over functions" begin
  QB = PormG.QueryBuilder
  for (backend, Model_) in _TAK_MODELS
    @testset "$backend" begin
      for (seed, wrap) in ((F("year") * 2, e -> Abs(e) * 2), (F("laptime") * 2, e -> Max(e) * 2))
        e = seed
        for _ in 1:16
          e = wrap(e)
        end
        q = Model_.objects
        q.values("v" => e)
        instr = QB.build(q.object)
        source = QB._projected_source(QB.memo_key(:base, "v"), instr).field
        QB._expression_kind(source, instr)                       # compile
        @test (@elapsed QB._expression_kind(source, instr)) < 0.05
      end
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# The render takes its kind from the walk's one copy of the rule, at every level (#1034 step 5b).
# Expected: a thirty-two-level chain of interval arithmetic (`(… * 2) + F("laptime")`) and of date
# shifts (`… + Day(1)`) builds in well under a second on both engines, and the kind the render gives
# the whole is the walk's: an interval, and a date. Each render level asks the rule once its sides have
# rendered (`_arith_result_kind`), and a side the walk types is memoized (`_memo_kind`); a regression
# that loses the memo would show here as a cost exponential in the depth. Measured at 0.2 ms on SQLite
# at depth 32, the same as before step 5b. The bound takes the fastest of three builds, so a GC pause
# in a long suite is no failure.
# Why it matters: one copy of the rule must not cost what two copies did not.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1034 step 5b: the render's kind is the walk's, at every depth, at no extra cost" begin
  QB = PormG.QueryBuilder
  for (backend, Model_) in _TAK_MODELS
    @testset "$backend" begin
      for (seed, wrap, expected) in ((F("laptime"), e -> e * 2 + F("laptime"), PormG.CInterval()),
                                     (F("date"), e -> e + Day(1), PormG.CDate()))
        e = seed
        for _ in 1:32
          e = wrap(e)
        end
        build() = (q = Model_.objects; q.values("v" => e); QB.build(q.object))
        build()                                                    # compile
        @test minimum(@elapsed(build()) for _ in 1:3) < 0.05
        rendered, walked = _tak_kinds(Model_, e)
        @test rendered == expected
        @test walked == expected
      end
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# The #1027/#1028 classifier reads a temporal operand's kind from the walk (#1034 step 5c).
# Expected, on both engines: `F` arithmetic that is a timestamp or an interval is classified as one
# and named "a timestamp expression" / "an interval expression"; `Avg` and `Sum` of a duration are an
# interval, named by their structure (`` `AVG(…)` ``, `` `SUM(…)` over the DurationField `laptime` ``),
# and so is a function over interval arithmetic; a date and a day count have one text and pass. Before
# step 5c the classifier asked `_operand_kind`, which types no `F` arithmetic, so every arithmetic row
# was `nothing` projected alone (only the render's kind caught it, at the sites it reaches) while the
# same expression in a `Subquery` was an interval, and `Avg(duration)` was a `numeric`.
# Why it matters: `Concat`, `Cast` and `Round` must see the type the walk gives every other reader.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1034 step 5c: the Concat classifier reads F temporal arithmetic and interval aggregates from the walk" begin
  QB = PormG.QueryBuilder
  shapes = (
    (F("start_at") - F("start_at"),      (:interval, "an interval expression")),
    (F("laptime") * 2,                   (:interval, "an interval expression")),
    (F("date") + Hour(1),                (:timestamp, "a timestamp expression")),
    (F("start_at") + F("laptime"),       (:timestamp, "a timestamp expression")),
    (Avg("laptime"),                     (:interval, "`AVG(…)`")),
    (Sum("laptime"),                     (:interval, "`SUM(…)` over the DurationField `laptime`")),
    (Max(F("start_at") - F("start_at")), (:interval, "`MAX(…)` over an interval expression")),
    (Case(When("year" => 2009, then = F("laptime") * 2)), (:interval, "`CASE(…)` over an interval expression")),
    (F("date") + Day(1),                 nothing),
    (F("date") - F("date"),              nothing),
  )
  for (backend, Model_) in _TAK_MODELS
    @testset "$backend" begin
      for (expr, expected) in shapes
        q = Model_.objects
        q.values("v" => expr)
        instr = QB.build(q.object)
        source = QB._projected_source(QB.memo_key(:base, "v"), instr).field
        @test QB._concat_textless_operand(source, instr) == expected
      end
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# #1459: a side of the render's arithmetic is the walk's kind, narrowed to a temporal one
# The render types a side of F arithmetic or a comparison (`_side_kind`, `_side_function_kind`) from
# the walk, keeping only a date, a timestamp, a time or an interval. Expected, on both engines:
# `Max("date")` and `"start_at__@date"` are dates; `"date__@year"` is an integer to the walk and no
# kind as a side, so an integer date part is never a day count (#882); `Max(<DecimalField>)` is a
# decimal to the walk and no kind as a side, which `_is_number_side` reads as a number side, as it read
# the `CDecimal(10, 2)` the read-kind policy named before #1459. Why it matters: the side readers lost
# their own policy of the walk (`_ReadKinds`) in #1459, and these are the answers that policy gave.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1459: a side's kind is the walk's, narrowed to a temporal kind" begin
  QB = PormG.QueryBuilder
  for (backend, key) in ((:postgres, "tak_pg"), (:sqlite, "tak_sl"))
    @testset "$backend" begin
      m = Model("tak_side_races", raceid = IDField(), date = DateField(), start_at = DateTimeField(),
                points = PormG.Models.DecimalField(max_digits = 10, decimal_places = 2))
      m.connect_key = key
      q = m.objects
      q.values("d" => Max("date"), "t" => "start_at__@date", "y" => "date__@year", "p" => Max("points"))
      instr = QB.build(q.object)
      node(name) = QB._projected_source(QB.memo_key(:base, name), instr).field
      # Temporal kinds reach the side.
      @test QB._side_kind(node("d"), instr) == PormG.CDate()
      @test QB._side_kind(node("t"), instr) == PormG.CDate()
      # An integer date part: the walk names it, the side does not (#882).
      @test QB._expression_kind(node("y"), instr) isa Union{PormG.CInt32,PormG.CInt64}
      @test QB._side_kind(node("y"), instr) === nothing
      # `Max(<DecimalField>)`: a decimal to the walk, no side kind, and still a number side.
      @test QB._expression_kind(node("p"), instr) == PormG.CDecimal(10, 2)
      @test QB._side_kind(node("p"), instr) === nothing
      @test QB._is_number_side(node("p"), QB._side_kind(node("p"), instr), instr)
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# #1465: a window function over a duration on the RIGHT of `*` is typed as it is on the left
# `Lag(<duration>) * F("year")` was an interval and `F("year") * Lag(<duration>)` was nothing: the walk
# (`_temporal_result_kind`) and the render (`_render_expr_typed`) typed a right side only when it was an
# expression, a function or a path, and a `WindowFunction` is none of the three. Expected: on
# PostgreSQL both orders are an interval to the walk and the render (`"year" * LAG(…)`); on MySQL both
# are an interval rendered as the rounded microseconds (`CAST(ROUND((…) * (LAG(…))) AS SIGNED)`); on
# SQLite both orders raise `QueryBuildError` (#881: a window over a duration has no millisecond form),
# for a window over the column and over a `Case` of it alike. Why it matters: on SQLite the right-hand
# order multiplied the duration's `HH:MM:SS` text and returned a wrong number, silently.
# ─────────────────────────────────────────────────────────────────────────────
struct TakMockMySQL <: PormG.PormGMySQL end
PormG.config["tak_my"] = PormG.Configuration.Settings(connections = TakMockMySQL(), change_data = true)

@testset "#1465: a window over a duration on the right of `*` is an interval" begin
  QB = PormG.QueryBuilder
  over = QB.WindowOver(order_by = "raceid")
  # Each window both ways round: over the column, and over a `Case` of it.
  windows = (() -> PormG.Functions.Lag("laptime", over = over),
             () -> PormG.Functions.Lag(Case([When("year" => 1, then = F("laptime"))]), over = over))
  for (i, window) in enumerate(windows)
    exprs = (left = () -> window() * F("year"), right = () -> F("year") * window())
    for side in (:left, :right)
      @testset "window $i, $side" begin
        # PostgreSQL: the walk and the render both name an interval.
        @test _tak_kinds(_tak_model("tak_pg"), exprs[side]()) == (PormG.CInterval(), PormG.CInterval())
        # MySQL: an interval, rendered as whole microseconds (the left form's spelling, mirrored).
        my = _tak_model("tak_my")
        @test _tak_kinds(my, exprs[side]()) == (PormG.CInterval(), PormG.CInterval())
        q = my.objects
        q.values("v" => exprs[side]())
        @test occursin("CAST(ROUND(", QB.query(q; show_query = :sql))
        # SQLite: refused, never the text multiplied.
        q = _tak_model("tak_sl").objects
        q.values("v" => exprs[side]())
        @test_throws PormG.QueryBuildError QB.query(q; show_query = :sql)
      end
    end
    # A number divided by a duration window: SQLite divided by its `HH:MM:SS` text; now refused.
    @testset "window $i, a number / the window on SQLite" begin
      q = _tak_model("tak_sl").objects
      q.values("v" => F("year") / window())
      @test_throws PormG.QueryBuildError QB.query(q; show_query = :sql)
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# #1465 (review): a window over a date or a duration on the right of `+`/`-`, beside a float or text
# The right side of `+` and `-` is typed through the same predicate as `*`, so beside a left that is
# neither a date nor an integer column (a float, a text) a window over a date or a duration is a typed
# side too. Expected: SQLite and MySQL raise `QueryBuildError` — the #882 "a date and a value PormG
# cannot type" and #881 "an interval on the right of a value that is not one" refusals a plain column
# there gets — and PostgreSQL renders the same `"points" + LAG(…)` as before. Why it matters: both
# engines built these and computed on the date's text or number (`points + '2009-03-29'`), silently.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1465: a date or duration window on the right of `+`/`-` beside a float or text" begin
  QB = PormG.QueryBuilder
  over = QB.WindowOver(order_by = "raceid")
  function model(key)
    m = Model("tak_mixed", raceid = IDField(), date = DateField(), laptime = DurationField(),
              points = PormG.Models.FloatField(), label = PormG.Models.CharField())
    m.connect_key = key
    return m
  end
  shapes = (
    "points + Lag(date)"    => () -> F("points") + PormG.Functions.Lag("date", over = over),
    "points - Lag(date)"    => () -> F("points") - PormG.Functions.Lag("date", over = over),
    "points + Lag(laptime)" => () -> F("points") + PormG.Functions.Lag("laptime", over = over),
    "points - Lag(laptime)" => () -> F("points") - PormG.Functions.Lag("laptime", over = over),
    "label + Lag(laptime)"  => () -> F("label") + PormG.Functions.Lag("laptime", over = over),
  )
  for (label, expr) in shapes
    @testset "$label" begin
      for key in ("tak_sl", "tak_my")
        q = model(key).objects
        q.values("v" => expr())
        @test_throws PormG.QueryBuildError QB.query(q; show_query = :sql)
      end
      q = model("tak_pg").objects
      q.values("v" => expr())
      @test occursin(r"\"Tb\"\.\"(points|label)\" [+-] LAG\(", QB.query(q; show_query = :sql))
    end
  end
end
