using Test
using Dates
using PormG
using PormG.Models: Model, IDField, IntegerField, BigIntegerField, DateField, DateTimeField, DurationField
using PormG.QueryBuilder: inspect_query, F, Max, Sum
using PormG.Functions: Abs, Greatest, Case, When

# ─────────────────────────────────────────────────────────────────────────────
# #1034 phase 3 step 5a: the type walk types F temporal arithmetic, as its render does.
#
# `date - date`, `timestamp - timestamp`, a date shifted by a duration, a day count or an interval, and
# interval arithmetic were typed by the render alone (`_render_expr_typed`), which records the kind it
# computes for a projection (`projection_kinds`). The walk (`_expression_kind`) answered `nothing` for
# all of them, so every reader that is not the render — the value formatter, a pattern lookup's
# refusal, the #1200 temporal mix, the #1111 division leaf, `Abs`/`Round` over an integer — saw no
# type. The walk now answers each one through the render's own rules (`_shift_result_kind`,
# `_difference_result_kind`, the day-count and number-side readers), so the two agree by construction.
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
# plus a number is the walk's integer, as it was before step 5a. A function side the render does not
# type an interval (`Case` over a duration) leaves the arithmetic untyped to both, on both engines.
# Why it matters: the walk must never name a temporal kind the render does not compute.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1034 step 5a: what the render leaves untyped stays untyped to the walk" begin
  pg = _TAK_MODELS[1][2]
  for expr in (F("laptime") + 2, F("date") * 2)
    rendered, walked = _tak_kinds(pg, expr)
    @test rendered === nothing
    @test walked === nothing
  end
  # A function side the render does not compute as an interval (`_render_function_body` does so only
  # for the interval candidates): a `Case` over a duration, and a `Sum` of one, times a number, and a
  # date plus one, on both engines where they build (review of #1034 step 5a). That the render leaves
  # them untyped is #1301; when it types them, these rows become positive ones.
  dur_case = Case([When("year" => 2009, then = F("laptime"))], default = F("laptime"))
  for (backend, Model_) in _TAK_MODELS, expr in (dur_case * 2, F("year") * dur_case, Sum(dur_case) * 2)
    rendered, walked = _tak_kinds(Model_, expr)
    @test rendered === nothing
    @test walked === nothing
  end
  rendered, walked = _tak_kinds(pg, F("date") + dur_case)
  @test rendered === nothing
  @test walked === nothing
  _, walked = _tak_kinds(pg, F("start_at__@year") + 1)
  @test walked isa Union{PormG.CInt32,PormG.CInt64}
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
# the whole is the walk's: an interval, and a date. Each render level asks the walk once its sides
# have rendered (`_arith_result_kind`), so a regression to a walk per path per level would show here;
# measured at 0.2 ms on SQLite at depth 32, the same as before step 5b.
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
        @test (@elapsed build()) < 0.05
        rendered, walked = _tak_kinds(Model_, e)
        @test rendered == expected
        @test walked == expected
      end
    end
  end
end
