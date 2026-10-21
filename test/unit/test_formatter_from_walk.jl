using Test
using Dates
using PormG
using PormG.Models: Model, IDField, IntegerField, FloatField, DateField, DurationField, BooleanField, CharField
using PormG.QueryBuilder: inspect_query, Max, Min, Sum, Q, Qor, F, Subquery, OuterRef, WindowOver
using PormG.Functions: Case, When, Coalesce, Lag, Rank, LPad, Concat

# ─────────────────────────────────────────────────────────────────────────────
# #1034 step 4: the value formatter is a view of the type walk.
#
# A filter on a projection alias checks its value with the formatter of the projected expression
# (`_expression_formatter`), and binds what that formatter writes. The formatter used to be its own
# inference, and it typed less than the walk does: a `Case` with no `output_field`, a window value
# function, and a condition as a function's operand (`Max(Q(…))`) had no formatter, so a filter on
# such an alias was not checked at all, and the value reached the engine as given. Now the formatter
# is the walk's kind, so these aliases are checked and bound as the column they hold would be.
#
# Every testset runs on both mock backends: the checks are the same on both, and only what a number
# or a boolean binds as differs (`_sqlite_preserve_native_parameter`).
# ─────────────────────────────────────────────────────────────────────────────
struct FmtWalkMockPostgres <: PormG.PormGPostgres end
struct FmtWalkMockSQLite <: PormG.PormGSQLite end
PormG.backend_sqlite_version(::FmtWalkMockSQLite) = 3045000

PormG.config["fmt_walk_pg"] = PormG.Configuration.Settings(connections = FmtWalkMockPostgres(), change_data = true)
PormG.config["fmt_walk_sl"] = PormG.Configuration.Settings(connections = FmtWalkMockSQLite(), change_data = true)

function _fmt_walk_model(key)
  m = Model("fmt_walk_results", resultid = IDField(), raceid = IntegerField(), grid = IntegerField(),
            points = FloatField(), fastestlaptime = DurationField(), race_date = DateField(),
            classified = BooleanField(null = true), surname = CharField(null = true))
  m.connect_key = key
  return m
end
const _FMT_WALK_MODELS = ((:postgres, _fmt_walk_model("fmt_walk_pg")), (:sqlite, _fmt_walk_model("fmt_walk_sl")))

# The last bound parameter: the value the alias filter compares with.
_last_param(q) = last(inspect_query(q)[:parameters])
_sql(q) = inspect_query(q)[:sql_text]

# One correlated subquery over the same table, projecting `e` for the outer row.
function _fmt_walk_sub(Model_, e)
  s = Model_.objects
  s.filter("resultid" => OuterRef("resultid"))
  s.values("t" => e)
  s.limit(1)
  return s
end

# ─────────────────────────────────────────────────────────────────────────────
# A `Case` with no `output_field` is the type its branches agree on.
# Expected: `"fast__@gt" => Minute(1)` over `Case(When("grid" => 1, then = F("fastestlaptime")))`
# binds the duration as `format_duration_sql` writes it on PostgreSQL (`"00:01:00"`), as a filter on
# the `fastestlaptime` column does; `10` is refused at build on both engines, naming the alias and
# the duration it holds, as it is for the column. On SQLite the ordering lookup itself is refused
# (#1311: the alias is the duration's text there), so the value is checked through `==`. Before, the alias had no formatter: PostgreSQL got
# `10` against an `interval` and failed at the server, SQLite compared `10` with the duration's text.
# Why it matters: the alias holds the column's values, so it must take the values the column takes.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1034 step 4: a filter on an untyped Case alias checks the value as its branches' type" begin
  for (backend, Model_) in _FMT_WALK_MODELS
    @testset "$backend" begin
      fast() = (q = Model_.objects;
                q.values("resultid", "fast" => Case([When("grid" => 1, then = F("fastestlaptime"))]));
                q)
      q = fast(); q.filter("fast__@gt" => Minute(1))
      if backend === :postgres
        @test _last_param(q) == "00:01:00"
        @test occursin("END\n > ", _sql(q))
      else
        # #1311: SQLite holds such a `Case` as its `HH:MM:SS` text, so an ordering filter on its
        # alias is refused there; equality still compares the text, and still checks the value.
        err = try _sql(q); nothing catch e; e end
        @test err isa PormG.QueryBuildError
        q = fast(); q.filter("fast" => Minute(1))
        @test occursin("END\n = ", _sql(q))
      end

      q = fast(); q.filter((backend === :postgres ? "fast__@gt" : "fast") => 10)
      err = try _sql(q); nothing catch e; e end
      @test err isa PormG.InvalidValueError
      @test occursin("`fast` projection alias (duration)", sprint(showerror, err))

      on_date() = (q = Model_.objects;
                   q.values("resultid", "d" => Case([When("grid" => 1, then = F("race_date"))], default = F("race_date")));
                   q)
      q = on_date(); q.filter("d__@gt" => Date(2009, 3, 29))
      @test _last_param(q) == "2009-03-29"
      q = on_date(); q.filter("d__@gt" => 10)
      @test_throws PormG.InvalidValueError _sql(q)

      # #942: a number is no condition. An untyped `Case` of numbers named none before, so it passed
      # the check that a `When` condition is boolean; it is refused now, as `Count(…)` is.
      q = Model_.objects
      q.values("resultid", "x" => Case([When(Case([When("grid" => 1, then = 1)], default = 0), then = "a")], default = "b"))
      err = try _sql(q); nothing catch e; e end
      @test err isa PormG.QueryBuildError
      @test occursin("used as a condition", sprint(showerror, err))
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# A window value function is its operand's type, and `Rank` an integer.
# Expected: a `Subquery` projecting `Lag("race_date")` compares as a date: `"w__@gt" => 10` is refused
# at build, and a `Date` binds as its text; a `Subquery` of `Rank()` is a number, so `"abc"` is refused.
# Before, both had no formatter and bound the value as given.
# Why it matters: `Lag`/`Lead`/`FirstValue` return one of their operand's own values (Django gives them
# their expression's `output_field`), so the value compared with one is the operand's type.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1034 step 4: a window value function compares as its operand's type" begin
  for (backend, Model_) in _FMT_WALK_MODELS
    @testset "$backend" begin
      over = WindowOver(order_by = "resultid")
      lagged() = (q = Model_.objects;
                  q.values("resultid", "w" => Subquery(_fmt_walk_sub(Model_, Lag("race_date", over = over))));
                  q)
      q = lagged(); q.filter("w__@gt" => 10)
      err = try _sql(q); nothing catch e; e end
      @test err isa PormG.InvalidValueError
      @test occursin("`w` projection alias (date)", sprint(showerror, err))
      q = lagged(); q.filter("w__@gt" => Date(2009, 3, 29))
      @test _last_param(q) == "2009-03-29"

      ranked() = (q = Model_.objects;
                  q.values("resultid", "r" => Subquery(_fmt_walk_sub(Model_, Rank(over = over))));
                  q)
      q = ranked(); q.filter("r__@gt" => "abc")
      @test_throws PormG.InvalidValueError _sql(q)
      q = ranked(); q.filter("r__@gt" => 2)
      @test _last_param(q) == 2   # `format_number_sql` returns an integer as is
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# A condition as a function's operand is a boolean.
# Expected: `Max(Q("grid__@gt" => 1))` renders PostgreSQL's `BOOL_OR` (#953: `max(boolean)` does not
# exist there) and SQLite's `MAX`, and a filter on its alias takes `true`/`false` and refuses `5`;
# `Coalesce(Q(…), false)` is a boolean too; `Sum(Q(…))` is refused on both engines, naming the explicit
# count, as `Sum` over a `BooleanField` is (#953). Before, the formatter typed no `Q`/`Qor` operand:
# `Max(Q(…))` rendered `MAX(…)`, which PostgreSQL rejects, `Sum(Q(…))` added up SQLite's 0/1, and an
# alias filter bound `5` as given.
# Why it matters: a condition is a boolean on every engine; the query says so as plainly as a
# `BooleanField` does, and the same rules must apply to it.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1034 step 4: a Q or Qor operand is a boolean" begin
  for (backend, Model_) in _FMT_WALK_MODELS
    @testset "$backend" begin
      ahead() = (q = Model_.objects; q.values("raceid", "ahead" => Max(Q("grid__@gt" => 1))); q)
      q = ahead()
      @test occursin(backend === :postgres ? "BOOL_OR(" : "MAX(", _sql(q))
      q = ahead(); q.filter("ahead" => true)
      @test _last_param(q) === true
      q = ahead(); q.filter("ahead" => 5)
      err = try _sql(q); nothing catch e; e end
      @test err isa PormG.InvalidValueError
      @test occursin("`ahead` projection alias (bool)", sprint(showerror, err))

      q = Model_.objects
      q.values("raceid", "front" => Min(Qor("grid" => 1, "grid" => 2)))
      @test occursin(backend === :postgres ? "BOOL_AND(" : "MIN(", _sql(q))

      q = Model_.objects
      q.values("resultid", "c" => Coalesce(Q("grid__@gt" => 1), false))
      q.filter("c" => 5)
      @test_throws PormG.InvalidValueError _sql(q)

      q = Model_.objects
      q.values("raceid", "n" => Sum(Q("grid__@gt" => 1)))
      err = try _sql(q); nothing catch e; e end
      @test err isa PormG.QueryBuildError
      @test occursin("`Sum` over a boolean", sprint(showerror, err))
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# What the walk cannot type keeps its number; what it types takes its own formatter (#1034 step 5a).
# Expected: `F("grid") * F("fastestlaptime")`, a number times a duration, and a `Sum` of it, are
# durations: the walk types temporal arithmetic since step 5a, so the formatter is the duration's,
# where the step-4 fallback said a number. `Sum`/`Avg` of the duration column itself is a duration too.
# `F("grid") + Extract("race_date", "EPOCH")` is a number the walk still cannot type (`EPOCH` has no
# stated type), so the formatter's own rule answers, a number when the left side is one, and a `Sum`
# of it stays a number: PostgreSQL only, as SQLite has no `EPOCH` part. A formatter is never lost here:
# a step that drops one stops checking the value (fail-open).
# Why it matters: the fallback is for what the walk does not type, and only for that.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1034 step 5a: the formatter takes the walk's temporal kind, and the fallback the rest" begin
  QB = PormG.QueryBuilder
  for (backend, Model_) in _FMT_WALK_MODELS
    @testset "$backend" begin
      q = Model_.objects
      q.values("resultid", "x" => F("grid") * F("fastestlaptime"), "s" => Sum(F("grid") * F("fastestlaptime")),
               "total" => Sum("fastestlaptime"), "mean" => QB.Avg("fastestlaptime"))
      instr = PormG.QueryBuilder.build(q.object)   # renders the projection, filling the memos
      f(alias) = QB._expression_formatter(QB._projected_source(QB.memo_key(:base, alias), instr).field, instr)
      @test f("x") === PormG.Models.format_duration_sql
      @test f("s") === PormG.Models.format_duration_sql
      @test f("total") === PormG.Models.format_duration_sql
      @test f("mean") === PormG.Models.format_duration_sql
      backend === :postgres || continue
      q = Model_.objects
      epoch = PormG.Functions.Extract("race_date", "EPOCH")
      q.values("resultid", "e" => F("grid") + epoch, "se" => Sum(F("grid") + epoch))
      instr = PormG.QueryBuilder.build(q.object)
      @test f("e") === PormG.Models.format_number_sql
      @test f("se") === PormG.Models.format_number_sql
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# A newly typed operand is held to the rules its type has elsewhere.
# Expected: `When(Lag("grid", over = …))` is refused as a condition (#942: a number does not say
# which rows it means), and `When(Lag("classified", over = …))` builds, its operand a boolean;
# `LPad(<untyped Case of numbers>, 3, "0")` is refused (#122: `LPad` pads text), where SQLite padded
# the number before; `Concat("surname", Lag("classified", …))` is refused naming `LAG(…)` over the
# BooleanField, not "a boolean expression". Before step 4 the window value and the untyped `Case` had
# no type, so neither check saw them.
# Why it matters: the check reads the same formatter the binder does, so a type gained there is a type
# every rule that asks about it now sees.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1034 step 4: a newly typed operand is held to the When, LPad and Concat rules" begin
  for (backend, Model_) in _FMT_WALK_MODELS
    @testset "$backend" begin
      over = WindowOver(order_by = "resultid")
      build(e) = (q = Model_.objects; q.values("resultid", "x" => e); _sql(q))
      refusal(e) = (try build(e); nothing catch err; err end)
      err = refusal(Case([When(Lag("grid", over = over), then = 1)], default = 0))
      @test err isa PormG.QueryBuildError
      @test occursin("`LAG(…)` used as a condition", sprint(showerror, err))
      @test occursin("CASE", build(Case([When(Lag("classified", over = over), then = 1)], default = 0)))
      err = refusal(LPad(Case([When("grid" => 1, then = 5)], default = 0), 3, "0"))
      @test err isa PormG.QueryBuildError
      @test occursin("pads TEXT, and the value it pads, a non-text expression", sprint(showerror, err))
      err = refusal(Concat("surname", Lag("classified", over = over)))
      @test err isa PormG.QueryBuildError
      @test occursin("`LAG(…)` over the BooleanField `classified` is not text", sprint(showerror, err))
    end
  end
end
