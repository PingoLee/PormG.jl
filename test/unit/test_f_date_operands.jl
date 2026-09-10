"""
Date and DateTime operands on `F` / `Joined` comparisons (#494).

All twelve comparison overloads — six on `F`, six on `Joined` — accepted `Dates.Date` and
`Dates.DateTime` at **dispatch**, through the shared `_CompareOperand` union, and then died inside
the `FExpression` constructor because the `operand` FIELD did not admit either type. The user saw a
bare `MethodError` naming `convert` and an internal union: outside the #231 taxonomy, and pointing
at neither the comparison they wrote nor the date they passed.

The split was exact and is the thing this file pins. `FExpression.operand` carried
`Period`/`CompoundPeriod`/`Interval` — the DURATION operands #25 added for date *arithmetic* — but
never gained `Date`/`DateTime` for date *comparison*. `F("date") + Day(30)` therefore built fine
while `F("date") == Date(2020, 1, 1)` did not, from one union away.

#494 accepts them (Django's answer: `F()` compares against a date without ceremony) rather than
refusing them, so two things need proving and neither is "it builds":

  1. **The signature and the field agree.** Asserted structurally — every member of
     `_CompareOperand` must be storable in `FExpression.operand` — so the two cannot drift apart
     again without a red test. That is the acceptance item the issue spells out.
  2. **The value binds the way a date binds everywhere else.** A widened struct alone would send a
     RAW Julia `Date` to `add_parameter!`, which normalizes nothing. PostgreSQL absorbs that; SQLite
     does not, because its date columns hold the TEXT their field formatter produced — so a raw bind
     would compare against a different representation and return the WRONG ROWS with no error. Every
     case below therefore asserts the bound parameter, not just the SQL shape, and the decisive
     assertion is the equality against the ordinary `filter("col" => value)` pair: the two spellings
     must bind identical bytes.

Why a dedicated file: the defect is one struct shared by two families, so `test_operators.jl` (the
`F` side's home) and `test_joined_reference.jl` (the `Joined` side's) would each have held half of
one story, and neither fixture carries both a `DateField` and a `DateTimeField`. One responsibility
per file, the convention `test_operators.jl`'s own header states.

Everything renders through mock connections — no live database.

Sibling coverage:
  - `test_operators.jl`               → the `__@gte`-style suffix filters, including the #25 date
                                        arithmetic these operands sit beside.
  - `test_joined_reference.jl`        → the `Joined(alias, path)` surface itself.
  - `test_f_expression_immutability.jl` → #457/#508, the other contract on these same nodes.
  - `test/integration/test_field_expressions.jl` → the driver round-trip, which no mock can prove.

julia --project=. test/unit/test_f_date_operands.jl
"""

using Test
using PormG
using PormG.Models
using PormG.QueryBuilder: F, inspect_query
using PormG: Joined
using Dates
import PormG.QueryBuilder as QB

# Dedicated config key + mock types: `runtests.jl` includes every unit file into one `Main`, so a
# shared key would let another file's settings decide this file's dialect.
struct FdMockSQLite <: PormG.PormGSQLite end
struct FdMockPostgres <: PormG.PormGPostgres end
const _FD_SL = FdMockSQLite()
const _FD_PG = FdMockPostgres()
PormG.backend_sqlite_version(::FdMockSQLite) = 3045000

PormG.config["fd_mock"] = PormG.Configuration.Settings(
  connections = _FD_SL, change_data = true, db_def_folder = "fd_mock",
)

# One DATE column and one TIMESTAMP column on the SAME model, plus a ForeignKey so the `Joined`
# family has a joined copy to reference. Both column kinds are needed on both sides: the two
# formatters produce different strings ("2020-01-01" vs the canonical UTC form), and choosing
# between them by the LEFT column is the part of the fix a single-column fixture cannot exercise.
module FdModels
import PormG
import PormG.Models

Fd_race = Models.Model("fd_race",
  id        = Models.IDField(),
  name      = Models.CharField(),
  date      = Models.DateField(null = true),
  starts_at = Models.DateTimeField(null = true),
)

Fd_result = Models.Model("fd_result",
  id        = Models.IDField(),
  race      = Models.ForeignKey(Fd_race, on_delete = "CASCADE", related_name = "fd_results", null = true),
  points    = Models.IntegerField(null = true),
  seen      = Models.DateField(null = true),
  logged_at = Models.DateTimeField(null = true),
)

PormG.Models.set_models(@__MODULE__, "fd_mock")
end

const FD = FdModels

_fd_sql(q; conn = _FD_SL)    = inspect_query(q; connection = conn)[:sql_text]
_fd_params(q; conn = _FD_SL) = inspect_query(q; connection = conn)[:parameters]

# The six operators, paired with the SQL token each must emit. Written out rather than generated so
# a missing overload is a missing row, visible in the file.
const _FD_OPS = (("==", ==, "="), ("!=", !=, "!="), (">", >, ">"),
                 ("<", <, "<"), (">=", >=, ">="), ("<=", <=, "<="))

const _FD_DATE     = Dates.Date(1991, 10, 6)
const _FD_DATETIME = Dates.DateTime(1991, 10, 6, 14, 30)

# The canonical strings the model layer produces for those two values. Spelled literally, not
# computed from the formatter, so a change in the formatter shows up here as a failure rather than
# being tracked silently by a test that recomputes whatever the code now does.
const _FD_DATE_TEXT     = "1991-10-06"
const _FD_TS_TEXT       = "1991-10-06T14:30:00.000+00:00"
const _FD_DATE_AS_TS    = "1991-10-06T00:00:00.000+00:00"

# ─────────────────────────────────────────────────────────────────────────────
# The contract itself: the dispatch union and the storage slot must admit the same types.
# This is the assertion that keeps #494 fixed. Every other testset here checks a consequence; this
# one checks the cause, and it fails the moment someone widens one side alone — which is exactly how
# the defect was introduced.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#494: _CompareOperand and FExpression.operand admit the same types" begin
  slot = fieldtype(QB.FExpression, :operand)
  for member in Base.uniontypes(QB._CompareOperand)
    # `<:` and not `isa`: the union members are TYPES, and a signature member that is not a subtype
    # of the field's union is a value the comparison accepts and the constructor rejects.
    @test member <: slot
  end

  # The two members #494 added, named explicitly — a `uniontypes` loop over an accidentally EMPTIED
  # union would pass vacuously, and these are the two the issue is about.
  @test Dates.Date <: slot
  @test Dates.DateTime <: slot
  @test Dates.Date <: QB._CompareOperand
  @test Dates.DateTime <: QB._CompareOperand

  # The duration operands #25 added are untouched — the fix widens, it does not redraw.
  @test Dates.Period <: slot
  @test Dates.CompoundPeriod <: slot
end

# ─────────────────────────────────────────────────────────────────────────────
# The `F` family: all six operators, both date types, both backends.
# The SQL token is asserted alongside the bound parameter, because a comparison that renders the
# right operator and binds the wrong representation is precisely the silent failure this fix exists
# to prevent on SQLite.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#494: F comparisons accept Date and DateTime" begin

  @testset "a DATE column binds the calendar-date string" begin
    for (name, op, token) in _FD_OPS, (backend, conn) in (("PostgreSQL", _FD_PG), ("SQLite", _FD_SL))
      q = FD.Fd_result.objects
      q.values("id")
      q.filter(op(F("seen"), _FD_DATE))
      sql = _fd_sql(q; conn = conn)
      @test occursin("\"Tb\".\"seen\" $(token) ", sql)
      @test _fd_params(q; conn = conn) == Any[_FD_DATE_TEXT]
    end
  end

  @testset "a DATE column truncates a DateTime, as the ordinary filter does" begin
    for (name, op, token) in _FD_OPS, (backend, conn) in (("PostgreSQL", _FD_PG), ("SQLite", _FD_SL))
      q = FD.Fd_result.objects
      q.values("id")
      q.filter(op(F("seen"), _FD_DATETIME))
      @test occursin("\"Tb\".\"seen\" $(token) ", _fd_sql(q; conn = conn))
      # `format_date_sql(::DateTime)` coerces to the calendar date — the time-of-day is dropped, on
      # this path exactly as on the pair path.
      @test _fd_params(q; conn = conn) == Any[_FD_DATE_TEXT]
    end
  end

  @testset "a TIMESTAMP column binds the canonical UTC string" begin
    for (name, op, token) in _FD_OPS, (backend, conn) in (("PostgreSQL", _FD_PG), ("SQLite", _FD_SL))
      q = FD.Fd_result.objects
      q.values("id")
      q.filter(op(F("logged_at"), _FD_DATETIME))
      @test occursin("\"Tb\".\"logged_at\" $(token) ", _fd_sql(q; conn = conn))
      @test _fd_params(q; conn = conn) == Any[_FD_TS_TEXT]
    end
  end

  @testset "a Date against a TIMESTAMP column is promoted to midnight" begin
    # SQL's own reading of a date literal compared to a timestamp, and the only representation the
    # timestamp formatter can produce from a `Date` — it has no `::Date` method.
    for (backend, conn) in (("PostgreSQL", _FD_PG), ("SQLite", _FD_SL))
      q = FD.Fd_result.objects
      q.values("id")
      q.filter(F("logged_at") >= _FD_DATE)
      @test _fd_params(q; conn = conn) == Any[_FD_DATE_AS_TS]
    end
  end

  @testset "a joined field path resolves the column on the far side" begin
    # `race__date` is a DATE column on `fd_race`, reached through the ForeignKey. The formatter is
    # chosen from the memoized field, so a joined path must not silently fall back to the operand's
    # own type — that fallback is for expressions with no column at all.
    for (backend, conn) in (("PostgreSQL", _FD_PG), ("SQLite", _FD_SL))
      q = FD.Fd_result.objects
      q.values("id")
      q.filter(F("race__date") == _FD_DATETIME)
      sql = _fd_sql(q; conn = conn)
      @test occursin("JOIN \"fd_race\"", sql)
      # Truncated, because the far-side column is a DATE — the same answer the local DATE column
      # gives. A fallback on the operand's type would bind the timestamp form here.
      @test _fd_params(q; conn = conn) == Any[_FD_DATE_TEXT]
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# The `Joined` family: the same twelve-method story on the other side of the shared struct.
# These are `@eval`-generated from one loop and construct `FExpression` directly — a second,
# independent throw site — so they are asserted separately rather than assumed to follow.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#494: Joined comparisons accept Date and DateTime" begin

  _fd_joined_query() = begin
    q = FD.Fd_result.objects
    q.cjoin_on("Fd_race", alias = "r", on = [Joined("r", "id") == F("race")])
    q.values("id")
    q
  end

  @testset "every operator renders against the joined copy and binds the column's form" begin
    for (name, op, token) in _FD_OPS, (backend, conn) in (("PostgreSQL", _FD_PG), ("SQLite", _FD_SL))
      q = _fd_joined_query()
      q.filter(op(Joined("r", "date"), _FD_DATE))
      sql = _fd_sql(q; conn = conn)
      @test occursin("\"r\".\"date\" $(token) ", sql)
      @test _fd_params(q; conn = conn) == Any[_FD_DATE_TEXT]
    end
  end

  @testset "the joined column decides the representation, not the operand's type" begin
    # The half that was asymmetric until the joined arm read the memo: a `DateTime` against the
    # joined copy's DATE column must truncate exactly as the `F` twin does. Binding the timestamp
    # form here would mean one query's two spellings disagreeing about the same column.
    for (backend, conn) in (("PostgreSQL", _FD_PG), ("SQLite", _FD_SL))
      qj = _fd_joined_query()
      qj.filter(Joined("r", "date") == _FD_DATETIME)

      qf = FD.Fd_result.objects
      qf.values("id")
      qf.filter(F("seen") == _FD_DATETIME)

      @test _fd_params(qj; conn = conn) == _fd_params(qf; conn = conn) == Any[_FD_DATE_TEXT]
    end

    # And the joined TIMESTAMP column takes the timestamp form, so the choice is the column's and
    # not a constant.
    for (backend, conn) in (("PostgreSQL", _FD_PG), ("SQLite", _FD_SL))
      q = _fd_joined_query()
      q.filter(Joined("r", "starts_at") <= _FD_DATETIME)
      @test _fd_params(q; conn = conn) == Any[_FD_TS_TEXT]
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# The decisive equivalence: an `F` comparison and the ordinary `filter("col" => value)` pair must
# bind the SAME bytes for the same column and value.
#
# This is what makes the fix correct rather than merely non-throwing. The pair spelling is the one
# that has always worked and the one the issue lists as the workaround, so it is the oracle: if the
# two disagree, one of them is querying a representation the column does not hold — and on SQLite,
# where the comparison is lexicographic over TEXT, that is wrong rows and not an error.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#494: an F comparison binds what the equivalent filter pair binds" begin
  for (backend, conn) in (("PostgreSQL", _FD_PG), ("SQLite", _FD_SL))
    for (col, value) in (("seen", _FD_DATE), ("seen", _FD_DATETIME),
                         ("logged_at", _FD_DATETIME), ("logged_at", _FD_DATE))
      pair = FD.Fd_result.objects
      pair.values("id")
      pair.filter(col => value)

      fexpr = FD.Fd_result.objects
      fexpr.values("id")
      fexpr.filter(F(col) == value)

      @test _fd_params(fexpr; conn = conn) == _fd_params(pair; conn = conn)
      # Non-empty, so the equality above cannot be satisfied by both sides binding nothing.
      @test length(_fd_params(pair; conn = conn)) == 1
    end

    # The suffix spelling too — the issue's second listed workaround.
    suffix = FD.Fd_result.objects
    suffix.values("id")
    suffix.filter("seen__@gte" => _FD_DATE)

    fexpr = FD.Fd_result.objects
    fexpr.values("id")
    fexpr.filter(F("seen") >= _FD_DATE)

    @test _fd_params(fexpr; conn = conn) == _fd_params(suffix; conn = conn)
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# Controls. Date ARITHMETIC was never broken — it is the other half of the union and the reason the
# defect was localized so precisely — so it must still render its dialect-specific form. And a
# comparison against an arithmetic result is the shape where both halves meet.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#494: date arithmetic is unaffected, and composes with a date comparison" begin
  # The #25 control, both dialects.
  q_pg = FD.Fd_result.objects; q_pg.values("id"); q_pg.filter(F("seen") + Dates.Day(30) <= _FD_DATE)
  @test occursin("make_interval(days =>", _fd_sql(q_pg; conn = _FD_PG))
  @test _fd_params(q_pg; conn = _FD_PG) == Any[30, _FD_DATE_TEXT]

  q_sl = FD.Fd_result.objects; q_sl.values("id"); q_sl.filter(F("seen") + Dates.Day(30) <= _FD_DATE)
  @test occursin("' days')", _fd_sql(q_sl; conn = _FD_SL))
  @test _fd_params(q_sl; conn = _FD_SL) == Any[30, _FD_DATE_TEXT]

  # The duration operand still takes its own branch — it must never reach the value binder, which is
  # what the arithmetic gate ahead of the infix branch exists to guarantee.
  @test !occursin("30 days", _fd_sql(q_pg; conn = _FD_PG))
end

# ─────────────────────────────────────────────────────────────────────────────
# The representation follows the COLUMN even when the left side is an arithmetic expression.
#
# Found by the independent review, and it was a live silent-wrong-rows bug rather than a tidiness
# point. `F("dob") + Year(0) == DateTime(1985, 1, 7)` on a `DateField` bound the canonical UTC
# timestamp — because the nested `FExpression` on the left answered "no column here" and the
# fallback took the LITERAL's Julia type — while SQLite's `date(...)` wrapper rendered
# `'1985-01-07'`. The two can never be equal, so the query returned zero rows with no error: exactly
# the failure the operand arm exists to prevent, one hop away from where it was being prevented.
#
# Both wrong pairings are pinned, because the fallback agreed with the column in precisely the one
# combination the original tests happened to use (DATE column + `Date` literal), which is how it
# shipped green.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#494: arithmetic on the left still binds the column's representation" begin
  for (backend, conn) in (("PostgreSQL", _FD_PG), ("SQLite", _FD_SL))
    # DATE column + DateTime literal → truncated, exactly as without the arithmetic.
    # A NON-zero duration on purpose: `_render_date_period_arithmetic` short-circuits a zero-length
    # interval to the bare left side and emits no parameter for it, which would make the assertion
    # below about a shape that never reaches the operand branch at all.
    q1 = FD.Fd_result.objects
    q1.values("id")
    q1.filter(F("seen") + Dates.Day(1) == _FD_DATETIME)
    @test _fd_params(q1; conn = conn) == Any[1, _FD_DATE_TEXT]

    # TIMESTAMP column + Date literal → promoted to midnight, exactly as without the arithmetic.
    q2 = FD.Fd_result.objects
    q2.values("id")
    q2.filter(F("logged_at") + Dates.Day(1) >= _FD_DATE)
    @test _fd_params(q2; conn = conn) == Any[1, _FD_DATE_AS_TS]

    # The arithmetic-free twin binds the same representation — that equality is the contract, and
    # asserting it directly means the two paths cannot drift apart without a red test.
    plain1 = FD.Fd_result.objects; plain1.values("id"); plain1.filter(F("seen") == _FD_DATETIME)
    plain2 = FD.Fd_result.objects; plain2.values("id"); plain2.filter(F("logged_at") >= _FD_DATE)
    @test last(_fd_params(q1; conn = conn)) == only(_fd_params(plain1; conn = conn))
    @test last(_fd_params(q2; conn = conn)) == only(_fd_params(plain2; conn = conn))

    # Two hops deep, so the walk recurses rather than unwrapping exactly one level.
    q3 = FD.Fd_result.objects
    q3.values("id")
    q3.filter(F("seen") + Dates.Year(1) - Dates.Day(2) == _FD_DATETIME)
    @test last(_fd_params(q3; conn = conn)) == _FD_DATE_TEXT
  end

  # The RENDER side resolves the same column this binder does, so the SQLite wrapper and the bound
  # representation cannot disagree. The delta review found they could: a zero-length link in a chain
  # short-circuits to the bare left side, erasing the `datetime(` marker the wrapper choice used to
  # sniff for textually — so `F(ts) + Day(0) + Day(1)` truncated a TIMESTAMP with `date(...)` while
  # the binder (correctly) bound the canonical form, and the two could then never match.
  @testset "the SQLite wrapper follows the rooted column, not the rendered text" begin
    chained = FD.Fd_result.objects
    chained.values("id")
    chained.filter(F("logged_at") + Dates.Day(0) + Dates.Day(1) == _FD_DATETIME)
    sql_chained = _fd_sql(chained; conn = _FD_SL)

    control = FD.Fd_result.objects
    control.values("id")
    control.filter(F("logged_at") + Dates.Day(1) == _FD_DATETIME)
    sql_control = _fd_sql(control; conn = _FD_SL)

    # A TIMESTAMP column takes `datetime(...)` either way — the zero-length link must not downgrade
    # it to `date(...)`, which would drop the time-of-day the operand still carries. `date("Tb"` is
    # the exact spelling of the downgrade, and cannot match inside `datetime("Tb"`.
    @test occursin("datetime(", sql_chained)
    @test !occursin("date(\"Tb\"", sql_chained)
    @test occursin("datetime(", sql_control)
    # Both bind the canonical timestamp form, so wrapper and bind agree in both spellings.
    @test last(_fd_params(chained; conn = _FD_SL)) == _FD_TS_TEXT
    @test last(_fd_params(control; conn = _FD_SL)) == _FD_TS_TEXT

    # The DATE column keeps `date(...)` — the resolver must not upgrade everything to datetime.
    plain = FD.Fd_result.objects
    plain.values("id")
    plain.filter(F("seen") + Dates.Day(1) == _FD_DATE)
    @test occursin("date(\"Tb\"", _fd_sql(plain; conn = _FD_SL))
    @test !occursin("datetime(", _fd_sql(plain; conn = _FD_SL))
  end

  # A joined PATH under arithmetic resolves the far-side column too.
  for (backend, conn) in (("PostgreSQL", _FD_PG), ("SQLite", _FD_SL))
    q = FD.Fd_result.objects
    q.values("id")
    q.filter(F("race__date") + Dates.Day(1) == _FD_DATETIME)
    @test last(_fd_params(q; conn = conn)) == _FD_DATE_TEXT
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# Column-to-column comparison — the shape `F(...)`-on-the-left exists for — still binds nothing.
# A date member in the operand union must not turn a column reference into a bound value.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#494: a field-to-field comparison still binds no parameter" begin
  for (backend, conn) in (("PostgreSQL", _FD_PG), ("SQLite", _FD_SL))
    q = FD.Fd_result.objects
    q.values("id")
    q.filter(F("seen") == F("race__date"))
    @test isempty(_fd_params(q; conn = conn))
    @test occursin("\"Tb\".\"seen\" = ", _fd_sql(q; conn = conn))
  end
end
