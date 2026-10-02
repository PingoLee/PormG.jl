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

julia --project=test/integration test/unit/test_f_date_operands.jl
"""

using Test
using PormG
using PormG.Models
using PormG.QueryBuilder: F, inspect_query
using PormG: Joined
using PormG: Interval   # #527 — the `Interval("HH:MM:SS")` spelling of a sub-day duration
using Dates
import TimeZones   # #536 — the `ZonedDateTime` oracle row; a direct dep of test/integration
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
  # #536 — one column per formatter family the literal arm routes through, so the oracle table below
  # can pair every `_CompareLiteral` member with the COLUMN that decides its representation.
  amount    = Models.FloatField(null = true),
  uid       = Models.UUIDField(null = true),
  flag      = Models.BooleanField(null = true),
  at        = Models.TimeField(null = true),
  code      = Models.CharField(null = true),
  # #814 — the interval family: a duration literal binds through this column's formatter.
  lap       = Models.DurationField(null = true),
)

PormG.Models.set_models(@__MODULE__, "fd_mock")
end

const FD = FdModels
const _FN = PormG.Functions   # #814 — the functions used as sides of a date difference

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
const _FD_SUBDAY_TS     = "1991-10-06T06:00:00.000+00:00"   # #527, the sub-day promotion cases

# #527 — the SQLite wrapper for a TIMESTAMP-valued expression. Spelled literally for the same reason
# the strings above are: `Dialect.SQLITE_CANONICAL_DATETIME_MASK` is the thing under test, so a test
# that interpolated it would agree with any value the constant ever takes. The render contract itself
# (and why this is `strftime(...)` rather than SQLite's `datetime(...)`) is pinned in
# `test_alignment_sqlite.jl`; here it is only the marker the wrapper-choice cases look for.
const _FD_TS_WRAPPER    = "strftime('%Y-%m-%dT%H:%M:%f+00:00', "

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

  # #536 widened the literal half: the three floats `format_number_sql` binds (so `Float32` no
  # longer yields a bare `Bool`), plus the two scalars with working formatters that were never
  # admitted. NOT `AbstractFloat`: a `BigFloat` has no formatter method and must be refused at the
  # operator rather than admitted and then die inside the formatter.
  for T in (Float16, Float32, Float64, Base.UUID, Dates.Time)
    @test T <: QB._CompareLiteral
  end
  @test !(BigFloat <: QB._CompareLiteral)
  @test !(AbstractFloat <: QB._CompareLiteral)
end

# ─────────────────────────────────────────────────────────────────────────────
# #536 — the oracle table: every `(column, literal)` pairing the literal arm must bind IDENTICALLY
# to the pair spelling `filter(column => literal)`. The pairings are the ones that were wrong or
# unrepresentable before the fix, plus controls:
#   - `Float64`/`Float32` against a FloatField bound the RAW Julia value where the pair path bound
#     `format_number_sql`'s "1.5"; `Float32` did not build at all (bare `Bool` from `Base.==`).
#   - `Bool` against an IntegerField: the pair binds `1` (`format_number_sql(::Bool)`); the `F` path
#     hit the Integer arm and bound raw `true`. The BooleanField row is the CONTROL — both spellings
#     already bound `true`, because `format_bool_sql(::Bool)` returns it unchanged.
#   - `UUID` and `Time`: working formatters, never admitted — the bare-`Bool` rows of the issue.
#   - `("race__name", 1)`: a JOINED String path — the column is resolved through the base-namespace
#     memo the left-side render wrote, and its CharField formatter binds `"1"`; a lookup that
#     silently missed would fall back to `format_number_sql` and bind the Int `1`, which the `===`
#     element check below catches. (The independent review found the joined rows were all DATE
#     controls that never reached the new arm; this one does.)
#   - `ZonedDateTime`, `Integer` and `String` rows are controls that must keep binding what they did.
# The testset after the equivalence walks `Base.uniontypes(_CompareLiteral)` against this table, so
# a member added to the union without a row here is a red test rather than an unproven claim.
# ─────────────────────────────────────────────────────────────────────────────
const _FD_ORACLE_ROWS = (
  ("seen", _FD_DATE), ("seen", _FD_DATETIME), ("logged_at", _FD_DATETIME), ("logged_at", _FD_DATE),
  ("logged_at", TimeZones.ZonedDateTime(_FD_DATETIME, TimeZones.tz"UTC")),
  ("amount", 1.5), ("amount", Float32(2.5)), ("amount", Float16(0.5)), ("points", 1.5),
  ("amount", 3), ("points", 7),
  ("uid", Base.UUID("12345678-1234-5678-1234-567812345678")),
  ("at", Dates.Time(9, 30)),
  ("flag", true), ("points", true),
  ("code", "HAM"), ("race__name", 1),
  # #814 — a duration against a DurationField binds `format_duration_sql`'s text, as the pair does.
  # One `Period` and one `CompoundPeriod`, the two members the issue added.
  ("lap", Dates.Hour(1)), ("lap", Dates.Minute(90) + Dates.Second(5)),
)

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
@testset "#494/#536: an F comparison binds what the equivalent filter pair binds" begin
  for (backend, conn) in (("PostgreSQL", _FD_PG), ("SQLite", _FD_SL))
    for (col, value) in _FD_ORACLE_ROWS
      pair = FD.Fd_result.objects
      pair.values("id")
      pair.filter(col => value)

      fexpr = FD.Fd_result.objects
      fexpr.values("id")
      fexpr.filter(F(col) == value)

      # `==` on the two vectors, and `===` on the elements: `1 == true` is true in Julia, so a
      # vector equality alone would pass the Bool-on-IntegerField row with the F path still binding
      # raw `true` — which is the exact defect that row exists to catch.
      @test _fd_params(fexpr; conn = conn) == _fd_params(pair; conn = conn)
      @test all(a === b for (a, b) in zip(_fd_params(fexpr; conn = conn), _fd_params(pair; conn = conn)))
      # Non-empty, so the equality above cannot be satisfied by both sides binding nothing.
      @test length(_fd_params(pair; conn = conn)) == 1
    end

    # The `Joined` family binds the same bytes through its own construction site (#536). The DATE and
    # TIMESTAMP rows are controls (they take the #494 temporal arm); `("name", 1)` is the one that
    # reaches the NEW arm through `_operand_column_field`'s `JoinedReference` branch — the joined
    # copy's CharField formatter binds `"1"`, and a missed memo lookup would bind the Int `1`.
    for (col, value) in (("date", _FD_DATE), ("starts_at", _FD_DATETIME), ("name", 1))
      pair = FD.Fd_race.objects
      pair.values("id")
      pair.filter(col => value)

      joined = FD.Fd_result.objects
      joined.cjoin_on("Fd_race", alias = "r", on = [Joined("r", "id") == F("race")])
      joined.values("id")
      joined.filter(Joined("r", col) == value)

      @test _fd_params(joined; conn = conn) == _fd_params(pair; conn = conn)
      @test all(a === b for (a, b) in zip(_fd_params(joined; conn = conn), _fd_params(pair; conn = conn)))
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
# #536 — the union is exactly as wide as its proof. Every member of `_CompareLiteral` has at least
# one row in the oracle table above, so widening the union without proving the new member binds
# like the pair spelling fails here. This is what lets the comment on `_CompareLiteral` state a
# RULE ("a member binds what the pair binds") instead of listing types.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#536: every _CompareLiteral member has an oracle row" begin
  members = Base.uniontypes(QB._CompareLiteral)
  @test length(members) >= 8   # not vacuous: the union was not accidentally emptied
  for member in members
    @test any(typeof(value) <: member for (_, value) in _FD_ORACLE_ROWS)
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# #536 — an operand OUTSIDE the vocabulary is refused at the operator, on BOTH families, for all
# six operators. Before the fix every one of these fell through to `Base.==` and evaluated to a
# bare `Bool`, so `filter(...)` reported "Invalid filter argument: false" — a value the user never
# wrote. The message names the offending type; `nothing`/`missing` also get the `__@isnull` hint,
# because those two are the ones a user reaches for when they mean NULL.
#
# `WeakRef` and `missing` are here for the Aqua half of the fix: Base defines `==(::Any, ::WeakRef)`
# and `==`/`<`(::Any, ::Missing), so those pairings need their own disambiguation methods, and this
# is what proves each of them refuses rather than falling into Base's arm.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#536: an unsupported operand raises QueryBuildError naming the type" begin
  # `big"1.5"` is the `AbstractFloat` that is NOT a member: no `format_number_sql` method exists for
  # it, so admitting it would trade a typed refusal for a `MethodError` inside the formatter.
  bad_values = (1 // 2, UInt8[1, 2], nothing, missing, Dict("a" => 1), WeakRef(nothing), big"1.5")
  for (name, op, token) in _FD_OPS, bad in bad_values
    for lhs in (F("points"), Joined("r", "date"))
      err = try
        op(lhs, bad)
        nothing
      catch e
        e
      end
      @test err isa PormG.QueryBuildError
      msg = err === nothing ? "" : PormG.error_message(err)
      @test occursin(string(typeof(bad)), msg)
      @test occursin(token, msg)
      # The accepted vocabulary is read live from the union, so the message can never go stale.
      @test occursin("UUID", msg) && occursin("Integer", msg)
      if bad === nothing || bad === missing
        @test occursin("__@isnull", msg)
      end
    end
  end

  # A `Bool` is NOT refused — `Bool <: Integer` — and it still reaches the literal arm.
  q = FD.Fd_result.objects
  q.values("id")
  q.filter(F("flag") == true)
  @test _fd_params(q) == Any[true]
end

# ─────────────────────────────────────────────────────────────────────────────
# #536 — `isequal` answers, it never throws. Base's fallback is `isequal(x, y) = x == y`, so the
# refusing catch-alls above would have turned `isequal(F("a"), nothing)` into a QueryBuildError
# where it used to answer `false` — a regression the independent review caught. `isequal` is the
# total hashing-equality contract (`Dict`, `Set`, `unique`, `findfirst(isequal(x), …)`), so the
# `FExpression` family now carries the same identity guard `JoinedReference` has had since #481.
# Fails on the catch-alls alone (throws); passes on the base tree only for the non-node cases.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#536: isequal on an F handle answers, never throws" begin
  f = F("points")
  @test isequal(f, f) === true
  @test isequal(F("points"), F("points")) === false     # identity, exactly as JoinedReference
  for other in (nothing, missing, :x, 1, "points", Joined("r", "date"))
    @test isequal(f, other) === false
  end
  @test isequal(Joined("r", "date"), nothing) === false  # the precedent is still in place
  d = Dict(f => 1)                                       # the hashing contract holds
  @test d[f] == 1
  @test findfirst(isequal(f), [F("a"), f]) == 2
end

# ─────────────────────────────────────────────────────────────────────────────
# #541 — the node-as-container contract, pinned for BOTH families. The guard above covers `isequal`
# and everything hashed on it; `in` and `findfirst(==(x), …)` reach `==`, which builds a predicate,
# so the caller's boolean context throws. That is the recorded decision, not a gap: a `Bool`-returning
# `==` between nodes would break `F("grid") == F("positionorder")`, and a `Base.in` override was
# declined. Either change makes this testset fail — which is the point: it has to be a decision again.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#541: nodes answer isequal by identity; == stays a predicate, so `in` does not" begin
  for (x, y) in ((F("points"), F("grid")), (Joined("r", "date"), Joined("r", "time")))
    @test isequal(x, x) === true
    @test isequal(x, y) === false
    @test x in Set([x, y])
    @test !(x in Set([y]))
    @test length(unique([x, x, y])) == 2
    @test findfirst(isequal(y), [x, y]) == 2
    @test (x == y) isa QB.FExpression                   # the predicate #457 made `==` build
    @test_throws TypeError x in [x, y]                  # ...so `in`, which asks `==`, cannot answer
    @test_throws TypeError findfirst(==(y), [x, y])
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# #536 — the SQL-text cast follows the COLUMN, the bytes follow the pair. On PostgreSQL a numeric
# literal against a NUMERIC column keeps the explicit cast the raw arm always emitted (that is what
# lets an integer column be compared against a double); against a boolean or text column it binds
# UNCAST like a pair, so PostgreSQL types the parameter from the column. The independent review
# measured the first draft casting by the LITERAL — `"flag" = $1::bigint` with `true` bound.
# SQLite renders no cast at all, so this is a PostgreSQL-mock testset by design.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#536: the cast follows the column, the bytes follow the pair" begin
  cases = (
    ("flag",   1,   false, Any[true]),   # BooleanField: `format_bool_sql(1)` → true, no cast
    ("code",   1,   false, Any["1"]),    # CharField: a text column, no cast
    ("points", 2.5, true,  Any["2.5"]),  # IntegerField vs a float literal: ::double precision kept
    ("amount", 3,   true,  Any[3]),      # FloatField vs an int literal: ::bigint kept
  )
  for (col, value, cast, expected) in cases
    fexpr = FD.Fd_result.objects
    fexpr.values("id")
    fexpr.filter(F(col) == value)
    pair = FD.Fd_result.objects
    pair.values("id")
    pair.filter(col => value)

    sql = _fd_sql(fexpr; conn = _FD_PG)
    @test _fd_params(fexpr; conn = _FD_PG) == expected
    @test all(a === b for (a, b) in zip(_fd_params(fexpr; conn = _FD_PG), _fd_params(pair; conn = _FD_PG)))
    @test occursin("::", sql) == cast
    # The pair spelling never casts — so where the F spelling does, that is the F spelling's own
    # deliberate addition and not parity; assert it directly.
    @test !occursin("::", _fd_sql(pair; conn = _FD_PG))
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

    # A TIMESTAMP column takes the canonical timestamp wrapper either way — the zero-length link must
    # not downgrade it to `date(...)`, which would drop the time-of-day the operand still carries.
    # `date("Tb"` is the exact spelling of the downgrade, and cannot match inside the `strftime(...)`
    # form. #527 changed that wrapper from SQLite's own `datetime(...)` to the canonical mask (see
    # `test_alignment_sqlite.jl` for why); the assertion is the same contract, one spelling later.
    @test occursin(_FD_TS_WRAPPER, sql_chained)
    @test !occursin("date(\"Tb\"", sql_chained)
    @test occursin(_FD_TS_WRAPPER, sql_control)
    # Both bind the canonical timestamp form, so wrapper and bind agree in both spellings.
    @test last(_fd_params(chained; conn = _FD_SL)) == _FD_TS_TEXT
    @test last(_fd_params(control; conn = _FD_SL)) == _FD_TS_TEXT

    # The DATE column keeps `date(...)` — the resolver must not upgrade everything to a timestamp.
    plain = FD.Fd_result.objects
    plain.values("id")
    plain.filter(F("seen") + Dates.Day(1) == _FD_DATE)
    @test occursin("date(\"Tb\"", _fd_sql(plain; conn = _FD_SL))
    @test !occursin(_FD_TS_WRAPPER, _fd_sql(plain; conn = _FD_SL))
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
# #527: a SUB-DAY duration promotes the expression's result kind, so the literal follows what the
# expression EVALUATES TO rather than the column it is rooted in.
#
# `F("seen") + Hour(6)` on a `DateField` is a timestamp — `date + interval` is a `timestamp` in
# SQL:2003 and in PostgreSQL, and Django resolves `DateField + DurationField` to a `DateTimeField`.
# Before #527 the literal bound the column's calendar date (`'1991-10-06'`) against a
# timestamp-valued left side, so the comparison was unsatisfiable for every row — zero rows, no
# error, on BOTH engines. That is why every case here is asserted on PostgreSQL too: this is not a
# SQLite rendering quirk, it is which bytes get bound.
#
# The promotion is deliberately NARROWER than Django's, which promotes on any duration. The three
# negative cases below are the ones that pin that narrowness, and each of them broke a simpler
# implementation of this rule:
#   · whole days must NOT promote — the truncation contract above (line ~516) depends on it;
#   · a ZERO sub-day link must not promote, because the renderer short-circuits it away entirely,
#     so promoting would put the bind back out of step with the wrapper;
#   · the promotion must survive a whole-day link stacked ON TOP of a sub-day one, which a
#     predicate that inspected only the outermost operand would miss.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#527: a sub-day duration promotes a DATE column's result to a timestamp" begin
  _FD_SUBDAY_DT = Dates.DateTime(1991, 10, 6, 6, 0)

  for (backend, conn) in (("PostgreSQL", _FD_PG), ("SQLite", _FD_SL))
    # The case the issue reports: hours on a DATE column.
    q1 = FD.Fd_result.objects
    q1.values("id")
    q1.filter(F("seen") + Dates.Hour(6) == _FD_SUBDAY_DT)
    @test _fd_params(q1; conn = conn) == Any[6, _FD_SUBDAY_TS]

    # `Interval("HH:MM:SS")` is the same duration by another spelling, and it is the one that needs
    # unwrapping before the components can be read — a resolver that only handled bare `Period`s
    # would decline to promote here.
    q2 = FD.Fd_result.objects
    q2.values("id")
    q2.filter(F("seen") + Interval("06:00:00") == _FD_SUBDAY_DT)
    @test last(_fd_params(q2; conn = conn)) == _FD_SUBDAY_TS

    # A whole-day link stacked on top of a sub-day one. The OUTERMOST operand is `Day(1)`, so a
    # predicate that looked only one level down would bind the calendar date here while the SQLite
    # render (which sees the inner wrapper) emitted a timestamp — a fresh wrapper/bind split, the
    # exact class #494 closed.
    q3 = FD.Fd_result.objects
    q3.values("id")
    q3.filter(F("seen") + Dates.Hour(6) + Dates.Day(1) == _FD_SUBDAY_DT)
    @test last(_fd_params(q3; conn = conn)) == _FD_SUBDAY_TS

    # Negative 1: whole days alone must not promote. Same column, same literal, one unit different.
    q4 = FD.Fd_result.objects
    q4.values("id")
    q4.filter(F("seen") + Dates.Day(1) == _FD_SUBDAY_DT)
    @test _fd_params(q4; conn = conn) == Any[1, _FD_DATE_TEXT]

    # Negative 2: a ZERO-length sub-day link. `_decompose_period` drops it, the renderer
    # short-circuits to the bare left side and emits NO wrapper — so promoting on the presence of an
    # `Hour` would bind a timestamp against an untouched DATE column. Asking the decomposer, rather
    # than the operand's Julia type, is what keeps render and bind in step.
    q5 = FD.Fd_result.objects
    q5.values("id")
    q5.filter(F("seen") + Dates.Hour(0) + Dates.Day(1) == _FD_SUBDAY_DT)
    @test _fd_params(q5; conn = conn) == Any[1, _FD_DATE_TEXT]

    # Negative 3: a TIMESTAMP column was already binding the canonical form, and still does — the
    # promotion may only ever widen DATE→TIMESTAMP, never narrow.
    q6 = FD.Fd_result.objects
    q6.values("id")
    q6.filter(F("logged_at") + Dates.Hour(6) == _FD_SUBDAY_DT)
    @test last(_fd_params(q6; conn = conn)) == _FD_SUBDAY_TS
  end

  # And on SQLite the wrapper agrees with every bind above — which is the whole point, since a
  # correct bind against a `date(...)`-wrapped left side still matches nothing.
  @testset "the SQLite wrapper agrees with the promoted bind" begin
    promoted = FD.Fd_result.objects
    promoted.values("id")
    promoted.filter(F("seen") + Dates.Hour(6) == _FD_SUBDAY_DT)
    @test occursin(_FD_TS_WRAPPER, _fd_sql(promoted; conn = _FD_SL))

    # The zero-length negative renders `date(...)`, so its un-promoted bind is the matching one.
    zeroed = FD.Fd_result.objects
    zeroed.values("id")
    zeroed.filter(F("seen") + Dates.Hour(0) + Dates.Day(1) == _FD_SUBDAY_DT)
    @test occursin("date(\"Tb\"", _fd_sql(zeroed; conn = _FD_SL))
    @test !occursin(_FD_TS_WRAPPER, _fd_sql(zeroed; conn = _FD_SL))
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

# ─────────────────────────────────────────────────────────────────────────────
# #568: a bare integer on ± over a temporal left is whole days, at EVERY nesting depth.
#
# The defect was an asymmetry in how the two spellings were dispatched, not in either renderer. The
# DURATION path keys off the OPERAND's type, so it composes over nesting; the two integer-days
# implementations keyed off `v.field_name isa String`, so a nested left (`(F(c) + 7) + 3`) matched
# neither and fell through to plain numeric addition. On SQLite that is `'2009-…' + 3` on TEXT with
# NUMERIC affinity — the silent integer `2012`. On PostgreSQL it is `timestamp with time zone +
# bigint`, which has no operator: loud, but the same wrong rendering.
#
# Both implementations are gone. A bare integer is normalized into `Day(n)` and rendered by the ONE
# temporal renderer, so composition is a property of the renderer rather than of where each guard
# happened to be written.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#568: integer days compose over nesting, on both engines" begin
  # The single-link control. Green since #527 — it must stay byte-identical, or the collapse changed
  # something it had no business changing.
  @testset "single link is unchanged (regression control)" begin
    q = FD.Fd_result.objects
    q.values("x" => F("logged_at") + 7)
    @test occursin(_FD_TS_WRAPPER, _fd_sql(q; conn = _FD_SL))
    @test _fd_params(q; conn = _FD_SL) == Any[7]

    q2 = FD.Fd_result.objects
    q2.values("x" => F("logged_at") + 7)
    @test occursin("make_interval(days => \$1::integer)", _fd_sql(q2; conn = _FD_PG))
    @test _fd_params(q2; conn = _FD_PG) == Any[7]
  end

  # THE DEFECT. Two links, integer spelling. The assertion that matters is that the OUTER link is
  # temporal too — before the fix it rendered `(<temporal inner> + ?)`, which is what made SQLite
  # return an integer and PostgreSQL refuse the statement.
  @testset "nested integer days render temporally at both links" begin
    for (col, sl_marker) in (("logged_at", _FD_TS_WRAPPER), ("seen", "date("))
      q = FD.Fd_result.objects
      q.values("x" => (F(col) + 7) + 3)
      sql = _fd_sql(q; conn = _FD_SL)
      # Two wrappers, not one wrapper and one bare `+ ?`.
      @test length(collect(eachmatch(Regex(replace(sl_marker, r"([().\[\]*+?^$|\\])" => s"\\\1")), sql))) == 2
      @test !occursin("+ ?)", sql)          # the old numeric-addition shape
      @test _fd_params(q; conn = _FD_SL) == Any[7, 3]

      qp = FD.Fd_result.objects
      qp.values("x" => (F(col) + 7) + 3)
      sqlp = _fd_sql(qp; conn = _FD_PG)
      @test length(collect(eachmatch(r"make_interval\(days => \$\d::integer\)", sqlp))) == 2
      @test !occursin("::bigint", sqlp)     # the `timestamptz + bigint` shape PostgreSQL refused
      @test _fd_params(qp; conn = _FD_PG) == Any[7, 3]
    end
  end

  # A mixed chain: integer inside, duration outside. Broken before for the same reason — the inner
  # link escaped, and the duration path then wrapped an already-wrong left.
  @testset "a mixed integer/duration chain composes" begin
    q = FD.Fd_result.objects
    q.values("x" => (F("seen") + 7) + Dates.Day(1))
    @test occursin("date(date(", _fd_sql(q; conn = _FD_SL))
    @test _fd_params(q; conn = _FD_SL) == Any[7, 1]
  end

  # THE ORDERING HAZARD, pinned without a database. Rendering the left is what populates the memo a
  # dotted join key's kind is resolved from, so a guard that asked "is this temporal?" BEFORE the
  # render would see `nothing` here and drop the whole expression to plain arithmetic. That mistake
  # is invisible on this fixture's own columns and only shows on a joined one — which is exactly why
  # it gets its own case rather than being trusted to the integration suite.
  @testset "a dotted join key is still temporal (the render-then-type order)" begin
    q = FD.Fd_result.objects
    q.values("x" => F("race__date") + 30)
    @test occursin("date(\"Tb_1\".\"date\", '+' || ? || ' days')", _fd_sql(q; conn = _FD_SL))
    @test _fd_params(q; conn = _FD_SL) == Any[30]

    qp = FD.Fd_result.objects
    qp.values("x" => F("race__date") + 30)
    @test occursin("make_interval(days => \$1::integer)", _fd_sql(qp; conn = _FD_PG))
    @test !occursin("::bigint", _fd_sql(qp; conn = _FD_PG))
  end

  # A negative integer. Before the collapse SQLite rendered `'+' || ? || ' days'` with the value -3,
  # i.e. the modifier `'+-3 days'`, which SQLite does not parse — `date()` returns NULL, silently.
  # The duration renderer has always carried the sign correctly; inheriting it is a free fix.
  @testset "a negative integer renders a '-' modifier, not '+-'" begin
    q = FD.Fd_result.objects
    q.values("x" => F("seen") + (-3))
    @test occursin("date(\"Tb\".\"seen\", '-' || ? || ' days')", _fd_sql(q; conn = _FD_SL))
    @test _fd_params(q; conn = _FD_SL) == Any[3]      # magnitude bound, sign in the modifier
  end

  # Zero days short-circuits to the bare column and binds NOTHING, matching `Day(0)`. Asserted on the
  # parameter vector because a stray bind here would misalign every SQLite parameter after it.
  @testset "zero days is the identity and binds no parameter" begin
    q = FD.Fd_result.objects
    q.values("x" => F("seen") + 0)
    @test isempty(_fd_params(q; conn = _FD_SL))
    @test !occursin("date(", _fd_sql(q; conn = _FD_SL))
  end

  # `Bool <: Integer` in Julia, so without an explicit exclusion `F("ts") + true` would be rewritten
  # to `Day(true)`. It must stay the arithmetic the caller actually wrote.
  @testset "a Bool is not whole days" begin
    q = FD.Fd_result.objects
    q.values("x" => F("logged_at") + true)
    sql = _fd_sql(q; conn = _FD_SL)
    @test !occursin(_FD_TS_WRAPPER, sql)
    @test !occursin("days", sql)
  end

  # The control that keeps the normalization from swallowing ordinary arithmetic: an integer column
  # plus an integer is not a date shift, and must not reach the temporal renderer (whose soft
  # validation would throw on it).
  @testset "integer arithmetic on a non-temporal column is untouched" begin
    for (backend, conn) in (("PostgreSQL", _FD_PG), ("SQLite", _FD_SL))
      q = FD.Fd_result.objects
      q.values("x" => F("points") + 10)
      sql = _fd_sql(q; conn = conn)
      @test occursin("\"Tb\".\"points\" + ", sql)
      @test !occursin("days", sql)
      @test _fd_params(q; conn = conn) == Any[10]
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# #564: the two kind NARROWINGS, which are the branch's most consequential and least obvious lines.
#
# Since #564 the render carries the column's TRUE canonical kind, so that a projected `TimeField` or
# `DurationField` can be coerced on the way out. Every ARITHMETIC consumer therefore has to re-narrow
# to `CDate`/`CDateTime` itself. Without that, a `CTime` left reaches the temporal renderer, which
# binds one parameter per modifier and then hands the kind to a table cell with no canonical form —
# emitting SQL with fewer placeholders than bound values (`StatementError` on SQLite, a stray `$N` on
# PostgreSQL).
#
# Both narrowings were previously asserted by nothing: reverting either left every test in this
# repository green. These are the cases that close that.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#564: a TIME column is not whole-day arithmetic, and does not decide a date literal" begin
  # `at` is the fixture's `TimeField`.
  @testset "F(time) + <integer> stays ordinary arithmetic" begin
    for (backend, conn) in (("SQLite", _FD_SL), ("PostgreSQL", _FD_PG))
      q = FD.Fd_result.objects
      q.values("x" => F("at") + 7)
      sql = _fd_sql(q; conn = conn)
      # No wrapper, no modifier — and, decisively, a placeholder for the 7 that IS in the text.
      @test occursin("\"Tb\".\"at\" + ", sql)
      @test !occursin("days", sql)
      @test !occursin(_FD_TS_WRAPPER, sql)
      @test _fd_params(q; conn = conn) == Any[7]
      # The regression this pins is a text/parameter MISMATCH, so count the placeholders against the
      # bound vector rather than trusting the shape assertions above.
      n_marks = conn === _FD_SL ? count(==('?'), sql) : length(collect(eachmatch(r"\$\d+", sql)))
      @test n_marks == length(_fd_params(q; conn = conn))
    end
  end

  # A duration on a TIME column must still RAISE — the soft validation in the duration renderer is
  # the only thing refusing it, and widening the kind must not have quietly bypassed that.
  @testset "F(time) ± a duration still raises" begin
    q = FD.Fd_result.objects
    q.values("x" => F("at") + Dates.Day(1))
    @test_throws PormG.InvalidValueError _fd_sql(q; conn = _FD_SL)
  end

  # The literal binder's narrowing: a TIME column has nothing useful to say about how a DATE or
  # TIMESTAMP literal should be represented, so the operand's own type decides.
  #
  # The operand is a `DateTime` DELIBERATELY, and a `Date` will not do. Unnarrowed, the kind is
  # `CTime` and `value_formatter(CTime, …)` is `format_text_sql` — which for a `Date` produces
  # `"1991-10-06"`, byte-identical to `format_date_sql`'s, so a `Date` operand cannot tell the two
  # apart and a test using one passes either way. The two formatters diverge on a `DateTime`:
  # `format_text_sql` gives `"1991-10-06T14:30:00"` and `format_timezone_sql` the canonical
  # `"1991-10-06T14:30:00.000+00:00"`. Measured, after a first version of this case proved unable to
  # fail under mutation.
  @testset "a timestamp literal against a TIME column binds by its own type" begin
    q = FD.Fd_result.objects
    q.values("id")
    q.filter(F("at") == _FD_DATETIME)
    @test _fd_params(q; conn = _FD_SL) == Any[_FD_TS_TEXT]
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# #572: whole-day arithmetic on a DATE column projects a date on PostgreSQL too.
# PostgreSQL's own `date + interval` is a `timestamp` for ANY interval, so `F("seen") + Day(1)`
# read back as a `DateTime` there while SQLite's `date(...)` read back a `Date`. The render is now
# cast back to `date` whenever the RESULT kind is a date — which, by `_shift_result_kind`, is a
# whole-day shift on a DATE. Everything that is not one (a sub-day shift, a TIMESTAMP column, a
# zero-length link) must render exactly as before, and those are the controls below.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#572: a whole-day DATE shift is cast back to date on PostgreSQL" begin
  # The three whole-day spellings on a DATE column. Asserted as the EXACT expression, so the cast's
  # placement (outside the shift, not inside `make_interval`) is part of the contract.
  @testset "every whole-day spelling on a DATE is cast" begin
    for (label, expr, sql, params) in (
        ("Day(1)",   F("seen") + Dates.Day(1),
         "((\"Tb\".\"seen\" + make_interval(days => \$1::integer)))::date",   Any[1]),
        ("bare 7",   F("seen") + 7,
         "((\"Tb\".\"seen\" + make_interval(days => \$1::integer)))::date",   Any[7]),
        ("Month(1)", F("seen") - Dates.Month(1),
         "((\"Tb\".\"seen\" - make_interval(months => \$1::integer)))::date", Any[1]),
      )
      q = FD.Fd_result.objects
      q.values("x" => expr)
      @test occursin(sql, _fd_sql(q; conn = _FD_PG))
      @test _fd_params(q; conn = _FD_PG) == params
    end
  end

  # The controls: each is NOT a date-valued result, so none may carry the cast. A sub-day shift
  # promotes to a timestamp (#527), a TIMESTAMP column was never a date, and a zero-length link
  # emits no shift at all — casting any of them would silently truncate a time of day.
  @testset "non-date results are not cast" begin
    for expr in (F("seen") + Dates.Hour(6), F("logged_at") + Dates.Day(1),
                 F("logged_at") + 7, F("seen") + Dates.Day(0))
      q = FD.Fd_result.objects
      q.values("x" => expr)
      @test !occursin("::date", _fd_sql(q; conn = _FD_PG))
    end
  end

  # A chain casts at every link, so a later sub-day link starts from a `date` and promotes from
  # there — the same value SQL gives for `(date + 1 day) + 6 hours`.
  @testset "a chain casts each whole-day link, and a sub-day link still promotes" begin
    q = FD.Fd_result.objects
    q.values("x" => (F("seen") + 7) + 3)
    @test length(collect(eachmatch(r"\)::date", _fd_sql(q; conn = _FD_PG)))) == 2

    q2 = FD.Fd_result.objects
    q2.values("x" => (F("seen") + Dates.Day(1)) + Dates.Hour(6))
    sql2 = _fd_sql(q2; conn = _FD_PG)
    @test length(collect(eachmatch(r"\)::date", sql2))) == 1        # the inner link only
    # The outer link is the sub-day one, so it wraps the cast date and is itself left uncast.
    @test occursin("(((\"Tb\".\"seen\" + make_interval(days => \$1::integer)))::date " *
                   "+ make_interval(hours => \$2::integer))", sql2)
  end

  # A joined DATE column resolves its kind only after the left is rendered (the render-then-type
  # order); the cast depends on that kind, so it is the case that would silently lose it.
  @testset "a dotted join key to a DATE is cast" begin
    q = FD.Fd_result.objects
    q.values("x" => F("race__date") + 30)
    @test occursin("((\"Tb_1\".\"date\" + make_interval(days => \$1::integer)))::date",
                   _fd_sql(q; conn = _FD_PG))
  end

  # SQLite already projected a date — its render must be byte-identical to before.
  @testset "SQLite is unchanged" begin
    q = FD.Fd_result.objects
    q.values("x" => F("seen") + Dates.Day(1))
    sql = _fd_sql(q; conn = _FD_SL)
    @test occursin("date(\"Tb\".\"seen\", '+' || ? || ' days')", sql)
    @test !occursin("::date", sql)
  end
end

# The kind a projected alias was recorded with — what the read path asks the #564 table about.
function _fd_kinds(build!::Function; conn = _FD_SL)
  q = FD.Fd_result.objects
  build!(q)
  QB.query(q; connection = conn, show_query = :sql)
  return q.object.projection_kinds
end

# ─────────────────────────────────────────────────────────────────────────────
# #801: DATE - DATE is a whole number of days on BOTH engines.
# SQLite stores a DATE as TEXT, and `-` on two TEXT values subtracts their leading numeric
# prefixes — `'2009-04-28' - '2009-03-29'` is `2009 - 2009 = 0`, silently. The difference now
# renders through `julianday` there, cast to the integer PostgreSQL's own `date - date` returns;
# PostgreSQL's text is unchanged. Each case pins the exact expression on both engines, because the
# PostgreSQL half is a promise of NO change and the SQLite half is the fix.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#801: DATE - DATE renders a day count on both engines" begin
  for (label, expr, sl_sql, pg_sql, params) in (
      # Two columns, one through a join — the right side resolves its kind only once rendered.
      ("column - joined column", F("seen") - F("race__date"),
       "CAST(julianday(\"Tb\".\"seen\") - julianday(\"Tb_1\".\"date\") AS INTEGER)",
       "(\"Tb\".\"seen\" - \"Tb_1\".\"date\")", Any[]),
      # The issue's own repro: a whole-day shift is still a DATE, so the difference is days.
      ("shifted - column", (F("seen") + Dates.Day(30)) - F("seen"),
       "CAST(julianday(date(\"Tb\".\"seen\", '+' || ? || ' days')) - julianday(\"Tb\".\"seen\") AS INTEGER)",
       "(((\"Tb\".\"seen\" + make_interval(days => \$1::integer)))::date - \"Tb\".\"seen\")", Any[30]),
      # A field path as a bare String operand is the `F(...)` it names, and is typed as one.
      ("String field operand", F("seen") - "race__date",
       "CAST(julianday(\"Tb\".\"seen\") - julianday(\"Tb_1\".\"date\") AS INTEGER)",
       "(\"Tb\".\"seen\" - \"Tb_1\".\"date\")", Any[]),
    )
    @testset "$label" begin
      q = FD.Fd_result.objects
      q.values("x" => expr)
      @test occursin(sl_sql, _fd_sql(q; conn = _FD_SL))
      @test _fd_params(q; conn = _FD_SL) == params

      q_pg = FD.Fd_result.objects
      q_pg.values("x" => expr)
      @test occursin(pg_sql, _fd_sql(q_pg; conn = _FD_PG))
      @test _fd_params(q_pg; conn = _FD_PG) == params
    end
  end

  # The kind is NAMED, not left `nothing`: an integer on both engines, so the read path parses
  # nothing and the alias arrives as the number the engine returned.
  @testset "the alias is recorded as CInt32 on both engines" begin
    for conn in (_FD_SL, _FD_PG)
      kinds = _fd_kinds(q -> q.values("gap" => F("seen") - F("race__date")); conn = conn)
      @test kinds[:gap] === PormG.CInt32()
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# #814 (was #801's refusal): a TIMESTAMP on either side is an interval on BOTH engines.
# PostgreSQL's `timestamp - timestamp` (and `date - timestamp`) is an `interval`; its text is
# unchanged. SQLite now renders the INTERVAL text a DurationField stores, from a correlated scalar
# subquery that computes the millisecond difference ONCE — so each side's SQL, and each parameter
# inside it, appears exactly once. Both record CInterval, which is what makes the #581 pin read the
# value back as a `Dates.CompoundPeriod` on both.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#814: a timestamp difference is an interval on both engines" begin
  for (label, expr, sl_diff, pg_sql, params) in (
      ("TIMESTAMP - TIMESTAMP", F("logged_at") - F("race__starts_at"),
       "julianday(\"Tb\".\"logged_at\") - julianday(\"Tb_1\".\"starts_at\")",
       "(\"Tb\".\"logged_at\" - \"Tb_1\".\"starts_at\")", Any[]),
      ("DATE - TIMESTAMP", F("seen") - F("logged_at"),
       "julianday(\"Tb\".\"seen\") - julianday(\"Tb\".\"logged_at\")",
       "(\"Tb\".\"seen\" - \"Tb\".\"logged_at\")", Any[]),
      ("TIMESTAMP - DATE", F("logged_at") - F("seen"),
       "julianday(\"Tb\".\"logged_at\") - julianday(\"Tb\".\"seen\")",
       "(\"Tb\".\"logged_at\" - \"Tb\".\"seen\")", Any[]),
      # A sub-day shift promotes a DATE to a timestamp (#527), so this is a timestamp difference
      # even though both roots are the same DATE column. It is also the case that BINDS: the shift's
      # `6` must be bound once, which is the reason the difference is computed in a subquery rather
      # than by repeating each side's text.
      ("sub-day-promoted DATE - DATE", (F("seen") + Dates.Hour(6)) - F("seen"),
       "julianday(strftime('%Y-%m-%dT%H:%M:%f+00:00', \"Tb\".\"seen\", '+' || ? || ' hours')) - julianday(\"Tb\".\"seen\")",
       "((\"Tb\".\"seen\" + make_interval(hours => \$1::integer)) - \"Tb\".\"seen\")", Any[6]),
    )
    @testset "$label" begin
      q = FD.Fd_result.objects
      q.values("x" => expr)
      sql = _fd_sql(q; conn = _FD_SL)
      # The difference, in milliseconds, named once inside the subquery …
      @test occursin("FROM (SELECT CAST(round(($(sl_diff)) * 86400000) AS INTEGER) AS _pormg_ms))", sql)
      # … and formatted as the stored DurationField text: sign, padded hours, minutes, seconds, and a
      # fraction only when there is one.
      @test occursin("printf('%02d:%02d:%02d', abs(_pormg_ms) / 3600000", sql)
      @test occursin("rtrim(printf('%03d', abs(_pormg_ms) % 1000), '0')", sql)
      # Each side appears exactly ONCE: one `julianday(` per side, one `?` per bound value.
      @test count("julianday(", sql) == 2
      @test count("?", sql) == length(params)
      @test _fd_params(q; conn = _FD_SL) == params

      q_pg = FD.Fd_result.objects
      q_pg.values("x" => expr)
      @test occursin(pg_sql, _fd_sql(q_pg; conn = _FD_PG))
      @test _fd_params(q_pg; conn = _FD_PG) == params

      for conn in (_FD_SL, _FD_PG)
        @test _fd_kinds(q -> q.values("x" => expr); conn = conn)[:x] === PormG.CInterval()
      end
    end
  end

  # The text the subquery builds is the text the read path parses: `Dialect._parse_sqlite_interval`
  # is the parser the CInterval kind selects on SQLite, and these are the shapes the SQL emits —
  # hours past 24 kept as hours (never folded into days), a stripped fraction, a sign.
  # A WINDOW side is refused on SQLite: the difference is computed in a subquery whose SELECT has
  # one row, so `LAG(x) OVER (…)` there is NULL on every row and `FIRST_VALUE(x)` is `x` — measured on
  # SQLite 3.45 by the review of #814. PostgreSQL has no subquery and renders it as before.
  @testset "a window function side is refused on SQLite" begin
    w = _FN.WindowOver(order_by = ["id"])
    for expr in (F("logged_at") - _FN.Lag("logged_at", over = w),
                 _FN.FirstValue("logged_at", over = w) - F("seen"),
                 # Nested inside a function: the walker has to reach it through `Coalesce`.
                 F("logged_at") - _FN.Coalesce(_FN.Lead("logged_at", over = w), "logged_at"),
                 # … and through a `When` branch, whose value lives in its kwargs, not its column.
                 F("logged_at") - _FN.Case(_FN.When("points" => 1; then = _FN.Lag("seen", over = w)); output_field = "date"))
      q = FD.Fd_result.objects
      q.values("x" => expr)
      err = try _fd_sql(q; conn = _FD_SL); nothing catch e; e end
      @test err isa PormG.QueryBuildError
      @test occursin("window function", sprint(showerror, err))

      q_pg = FD.Fd_result.objects
      q_pg.values("x" => expr)
      @test occursin(" OVER (ORDER BY \"Tb\".\"id\" ASC)", _fd_sql(q_pg; conn = _FD_PG))
    end
    # A window DAY COUNT is not computed in a subquery, and stays supported on SQLite.
    q = FD.Fd_result.objects
    q.values("x" => F("seen") - _FN.Lag("seen", over = w))
    @test occursin("CAST(julianday(\"Tb\".\"seen\") - julianday(LAG(", _fd_sql(q; conn = _FD_SL))
  end

  # Arithmetic ON a difference is text arithmetic on SQLite (`d + d` is the sum of the leading hours),
  # so it is refused there, on either side and through a duration shift. PostgreSQL's interval
  # arithmetic is native and renders as before.
  @testset "arithmetic on a difference is refused on SQLite" begin
    d() = F("logged_at") - F("race__starts_at")
    for expr in (d() + d(), d() * 2, d() / 2, F("points") * d(), F("lap") + d(), d() + Dates.Hour(1),
                 (F("seen") - F("race__date")) + d())
      q = FD.Fd_result.objects
      q.values("x" => expr)
      err = try _fd_sql(q; conn = _FD_SL); nothing catch e; e end
      @test err isa PormG.QueryBuildError
      @test occursin("on the difference of two timestamps is not supported on SQLite", sprint(showerror, err))

      q_pg = FD.Fd_result.objects
      q_pg.values("x" => expr)
      @test occursin("(\"Tb\".\"logged_at\" - \"Tb_1\".\"starts_at\")", _fd_sql(q_pg; conn = _FD_PG))
    end
  end

  @testset "the SQLite text reads back as a CompoundPeriod" begin
    parse = PormG.value_parser(PormG.CInterval(), _FD_SL)
    @test parse("06:00:00") == Dates.Hour(6)
    @test parse("292:00:00") == Dates.Hour(292)
    @test parse("90:29:59.75") == Dates.Hour(90) + Dates.Minute(29) + Dates.Second(59) + Dates.Millisecond(750)
    @test parse("-01:30:00") == -(Dates.Hour(1) + Dates.Minute(30))
    @test parse("06:00:00") isa Dates.CompoundPeriod
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# #814: comparing a timestamp difference.
# `==`/`!=` are exact on both engines — the SQLite text is the canonical form a duration literal
# binds as. ORDERING is refused on SQLite only: the difference is TEXT there, and "100:00:00" sorts
# before "99:00:00". A duration literal (`Hour(1)`) is a comparison operand now, bound through
# `format_duration_sql`; a `Time` is refused with a hint, and a duration against a non-interval is
# refused at build time rather than reaching a formatter with no method for it.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#814: comparing a timestamp difference" begin
  diff() = F("logged_at") - F("race__starts_at")

  @testset "== and != against a duration bind the stored text, on both engines" begin
    for (op, token) in ((==, "="), (!=, "!=")), conn in (_FD_SL, _FD_PG)
      q = FD.Fd_result.objects
      q.filter(op(diff(), Dates.Hour(6)))
      @test occursin(" $(token) ", _fd_sql(q; conn = conn))
      @test _fd_params(q; conn = conn) == Any["06:00:00"]
    end
  end

  @testset "ordering is refused on SQLite, and binds on PostgreSQL" begin
    for op in (>, <, >=, <=)
      q = FD.Fd_result.objects
      q.filter(op(diff(), Dates.Hour(1)))
      err = try _fd_sql(q; conn = _FD_SL); nothing catch e; e end
      @test err isa PormG.QueryBuildError
      @test occursin("does not order like a duration", sprint(showerror, err))

      q_pg = FD.Fd_result.objects
      q_pg.filter(op(diff(), Dates.Hour(1)))
      @test occursin("(\"Tb\".\"logged_at\" - \"Tb_1\".\"starts_at\")", _fd_sql(q_pg; conn = _FD_PG))
      @test _fd_params(q_pg; conn = _FD_PG) == Any["01:00:00"]
    end
  end

  # The difference on the RIGHT of an ordering is the same comparison, and refused the same way.
  @testset "a difference on the right is refused too" begin
    q = FD.Fd_result.objects
    q.filter(F("lap") < diff())
    err = try _fd_sql(q; conn = _FD_SL); nothing catch e; e end
    @test err isa PormG.QueryBuildError

    q_pg = FD.Fd_result.objects
    q_pg.filter(F("lap") < diff())
    @test occursin("(\"Tb\".\"lap\" < (\"Tb\".\"logged_at\" - \"Tb_1\".\"starts_at\"))", _fd_sql(q_pg; conn = _FD_PG))
  end

  # A DurationField COLUMN compared with `<` is outside this issue: it compared stored TEXT before
  # and still does. Refusing it would take away a comparison that is right below 100 hours.
  @testset "a DurationField column still orders, as before" begin
    q = FD.Fd_result.objects
    q.filter(F("lap") > Dates.Minute(90))
    @test occursin("WHERE (\"Tb\".\"lap\" > ?)", _fd_sql(q; conn = _FD_SL))
    @test _fd_params(q; conn = _FD_SL) == Any["01:30:00"]
  end

  # An interval with no rooted COLUMN — two aggregates — still binds the duration as interval text.
  # Review of #814: it fell to the literal's own family and reached `format_number_sql(::Hour)`, a
  # raw MethodError on both engines.
  @testset "a duration against an interval with no rooted column binds" begin
    for conn in (_FD_SL, _FD_PG)
      q = FD.Fd_result.objects
      q.values("race")
      q.filter((_FN.Max("logged_at") - _FN.Min("logged_at")) == Dates.Hour(1))
      @test _fd_params(q; conn = conn) == Any["01:00:00"]
    end
  end

  # Untyped arithmetic over a DurationField: on PostgreSQL `lap * 2` is an interval and the duration
  # binds as one; on SQLite it is a NUMBER, so a duration bound against it would compare number with
  # text and answer a constant. Review of #814 found SQLite admitting the duration through the rooted
  # column; it is refused there, and only there.
  @testset "untyped arithmetic over a DurationField admits a duration on PostgreSQL only" begin
    for (expr, bound) in (((F("lap") * 2) > Dates.Hour(1), "01:00:00"), ((F("lap") + F("lap")) == Dates.Hour(2), "02:00:00"))
      q = FD.Fd_result.objects
      q.filter(expr)
      err = try _fd_sql(q; conn = _FD_SL); nothing catch e; e end
      @test err isa PormG.QueryBuildError
      @test occursin("compares only against an interval", sprint(showerror, err))

      q_pg = FD.Fd_result.objects
      q_pg.filter(expr)
      @test last(_fd_params(q_pg; conn = _FD_PG)) == bound
    end
    # A Time against it still gets the hint naming the duration to write, on both engines.
    for conn in (_FD_SL, _FD_PG)
      q = FD.Fd_result.objects
      q.filter((F("lap") * 2) == Dates.Time(1))
      err = try _fd_sql(q; conn = conn); nothing catch e; e end
      @test err isa PormG.QueryBuildError
      @test occursin("Hour(1)", sprint(showerror, err))
    end
  end

  @testset "a Time against an interval is refused, naming the duration to write" begin
    for lhs in (diff(), F("lap")), conn in (_FD_SL, _FD_PG)
      q = FD.Fd_result.objects
      q.filter(lhs == Dates.Time(1))
      err = try _fd_sql(q; conn = conn); nothing catch e; e end
      @test err isa PormG.QueryBuildError
      @test occursin("Hour(1)", sprint(showerror, err))
    end
  end

  @testset "a duration against a non-interval is refused" begin
    # A DATE column, an integer column, and a day count (DATE - DATE) — none is an interval.
    for lhs in (F("seen"), F("points"), F("seen") - F("race__date")), conn in (_FD_SL, _FD_PG)
      q = FD.Fd_result.objects
      q.filter(lhs > Dates.Hour(1))
      err = try _fd_sql(q; conn = conn); nothing catch e; e end
      @test err isa PormG.QueryBuildError
      @test occursin("compares only against an interval", sprint(showerror, err))
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# #814: a function, a transform and a date literal are TYPED sides of a difference.
# #801 fixed `-` only when both sides had a kind the build could see, and these three had none, so
# they rendered a bare `-` — on SQLite the difference of two TEXT dates' leading YEARS, silently.
# A function and a transform are now typed by the projection path's own resolver (`Max`/`Min`/`Lag`
# keep their operand's kind, `@date` is a date), a `Date`/`DateTime` literal by its Julia type, and
# each difference renders as #801's day count or #814's interval. A function or transform PormG does
# not type (`Sum`, `@year`) still renders a bare `-`, exactly as before.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#814: functions, transforms and date literals are typed sides" begin
  for (label, expr, kind, sl_sql, pg_sql, params) in (
      # An aggregate on each side: the extremum keeps its operand's kind.
      ("Max - Min of two DATE columns", _FN.Max("seen") - _FN.Min("race__date"), PormG.CInt32(),
       "CAST(julianday(MAX(\"Tb\".\"seen\")) - julianday(MIN(\"Tb_1\".\"date\")) AS INTEGER)",
       "(MAX(\"Tb\".\"seen\") - MIN(\"Tb_1\".\"date\"))", Any[]),
      ("Max of a TIMESTAMP - Min of a DATE", _FN.Max("logged_at") - _FN.Min("seen"), PormG.CInterval(),
       "julianday(MAX(\"Tb\".\"logged_at\")) - julianday(MIN(\"Tb\".\"seen\"))",
       "(MAX(\"Tb\".\"logged_at\") - MIN(\"Tb\".\"seen\"))", Any[]),
      # A window value function on the right: the issue's `F("date") - Max("date")` shape, per row.
      # `Lag` binds its default offset, once, in the side's own render.
      ("column - Lag of the column", F("seen") - _FN.Lag("seen", over = _FN.WindowOver(order_by = ["id"])),
       PormG.CInt32(),
       "CAST(julianday(\"Tb\".\"seen\") - julianday(LAG(\"Tb\".\"seen\", ?) OVER (ORDER BY \"Tb\".\"id\" ASC)) AS INTEGER)",
       "(\"Tb\".\"seen\" - LAG(\"Tb\".\"seen\", \$1::integer) OVER (ORDER BY \"Tb\".\"id\" ASC))", Any[1]),
      # The `@date` transform on both sides — a TIMESTAMP cut to its date, minus a DATE.
      ("@date - @date", F("logged_at__@date") - F("seen__@date"), PormG.CInt32(),
       "CAST(julianday(strftime('%Y-%m-%d', \"Tb\".\"logged_at\")) - julianday(strftime('%Y-%m-%d', \"Tb\".\"seen\")) AS INTEGER)",
       "((\"Tb\".\"logged_at\")::date - (\"Tb\".\"seen\")::date)", Any[]),
      # A date literal, bound in the representation of its own kind and cast on PostgreSQL, where an
      # uncast `date - \$1` has three candidate operators.
      ("DATE column - Date literal", F("seen") - Dates.Date(2009, 3, 1), PormG.CInt32(),
       "CAST(julianday(\"Tb\".\"seen\") - julianday(?) AS INTEGER)",
       "(\"Tb\".\"seen\" - \$1::date)", Any["2009-03-01"]),
      ("TIMESTAMP column - DateTime literal", F("logged_at") - Dates.DateTime(2009, 3, 29, 6), PormG.CInterval(),
       "julianday(\"Tb\".\"logged_at\") - julianday(?)",
       "(\"Tb\".\"logged_at\" - \$1::timestamptz)", Any["2009-03-29T06:00:00.000+00:00"]),
      ("Max - Date literal", _FN.Max("seen") - Dates.Date(2009, 3, 1), PormG.CInt32(),
       "CAST(julianday(MAX(\"Tb\".\"seen\")) - julianday(?) AS INTEGER)",
       "(MAX(\"Tb\".\"seen\") - \$1::date)", Any["2009-03-01"]),
    )
    @testset "$label" begin
      q = FD.Fd_result.objects
      q.values("x" => expr)
      @test occursin(sl_sql, _fd_sql(q; conn = _FD_SL))
      @test _fd_params(q; conn = _FD_SL) == params

      q_pg = FD.Fd_result.objects
      q_pg.values("x" => expr)
      @test occursin(pg_sql, _fd_sql(q_pg; conn = _FD_PG))
      @test _fd_params(q_pg; conn = _FD_PG) == params

      for conn in (_FD_SL, _FD_PG)
        @test _fd_kinds(q -> q.values("x" => expr); conn = conn)[:x] === kind
      end
    end
  end

  # A transformed LEFT is typed in date arithmetic too, not only in a difference: `@date` plus a
  # sub-day duration is a timestamp, so SQLite renders the canonical mask rather than truncating the
  # hours away with `date(...)` — which is what an untyped left rendered.
  @testset "a transformed left of a shift is typed" begin
    q = FD.Fd_result.objects
    q.values("x" => F("logged_at__@date") + Dates.Hour(6))
    @test occursin("strftime('%Y-%m-%dT%H:%M:%f+00:00', strftime('%Y-%m-%d', \"Tb\".\"logged_at\"), '+' || ? || ' hours')",
                   _fd_sql(q; conn = _FD_SL))
  end

  # A timestamp literal is cast to the LEFT's flavour on PostgreSQL: a sub-day-promoted DATE is a
  # `timestamp` without a zone (CDateTime(false)), and the literal is `::timestamp` there.
  @testset "a timestamp literal against a zone-less timestamp is cast to timestamp" begin
    q = FD.Fd_result.objects
    q.values("x" => (F("seen") + Dates.Hour(6)) - Dates.DateTime(2009, 3, 29, 6))
    @test occursin(" - \$2::timestamp)", _fd_sql(q; conn = _FD_PG))
    q2 = FD.Fd_result.objects
    q2.values("x" => F("logged_at") - Dates.DateTime(2009, 3, 29, 6))
    @test occursin(" - \$1::timestamptz)", _fd_sql(q2; conn = _FD_PG))
  end

  # Typing a function or transform side is not confined to a difference: the same call types the
  # LEFT of a shift and of a comparison, so these shapes changed with #814 (recorded in upgrading/).
  # Each now matches what the same expression over a plain column of that kind does.
  @testset "typed sides change shifts and comparisons over them" begin
    # `@date` compared with a DateTime binds the calendar date, exactly as the pair spelling does.
    # Before, it bound the canonical timestamp text: no match on SQLite, while PostgreSQL's date input
    # dropped the time and matched (measured on db_2).
    for conn in (_FD_SL, _FD_PG)
      fq = FD.Fd_result.objects
      fq.filter(F("logged_at__@date") == Dates.DateTime(2009, 3, 1, 12))
      pq = FD.Fd_result.objects
      pq.filter("logged_at__@date" => Dates.DateTime(2009, 3, 1, 12))
      @test _fd_params(fq; conn = conn) == _fd_params(pq; conn = conn) == Any["2009-03-01"]
    end

    # A whole-day shift of `@date` / of `Max(date)` is a date: cast back on PostgreSQL (#572's rule),
    # where it read back as a timestamp; on SQLite `Max(date) + 1` was the YEAR plus one.
    for (expr, sl_sql, pg_sql) in (
        (F("logged_at__@date") + Dates.Day(1), "date(strftime('%Y-%m-%d', \"Tb\".\"logged_at\"), '+' || ? || ' days')",
         "(((\"Tb\".\"logged_at\")::date + make_interval(days => \$1::integer)))::date"),
        (_FN.Max("seen") + 1, "date(MAX(\"Tb\".\"seen\"), '+' || ? || ' days')",
         "((MAX(\"Tb\".\"seen\") + make_interval(days => \$1::integer)))::date"),
      )
      q = FD.Fd_result.objects
      q.values("x" => expr)
      @test occursin(sl_sql, _fd_sql(q; conn = _FD_SL))
      q_pg = FD.Fd_result.objects
      q_pg.values("x" => expr)
      @test occursin(pg_sql, _fd_sql(q_pg; conn = _FD_PG))
      for conn in (_FD_SL, _FD_PG)
        @test _fd_kinds(q -> q.values("x" => expr); conn = conn)[:x] === PormG.CDate()
      end
    end
  end

  # Untyped stays untyped: `@year` is a number and `Sum` is computed, so neither enters the temporal
  # branches, and each renders the bare operator it always did.
  @testset "a function or transform PormG does not type is unchanged" begin
    for (expr, sl_sql) in ((F("seen") - F("logged_at__@year"), "(\"Tb\".\"seen\" - CAST(strftime('%Y', \"Tb\".\"logged_at\") AS INTEGER))"),
                           (F("seen__@year") - 1, "(CAST(strftime('%Y', \"Tb\".\"seen\") AS INTEGER) - ?)"))
      q = FD.Fd_result.objects
      q.values("x" => expr)
      @test occursin(sl_sql, _fd_sql(q; conn = _FD_SL))
    end
  end

  # A text literal is refused on BOTH engines. It bound as text: PostgreSQL has no `date - text` and
  # failed at execution, and SQLite subtracted the years. The message names the `Date` spelling.
  @testset "a text literal on the right of date arithmetic is refused" begin
    for expr in (F("seen") - "2009-03-01", F("logged_at") - "2009-03-29 06:00", _FN.Max("seen") - "2009-03-01"),
        conn in (_FD_SL, _FD_PG)
      q = FD.Fd_result.objects
      q.values("x" => expr)
      err = try _fd_sql(q; conn = conn); nothing catch e; e end
      @test err isa PormG.QueryBuildError
      @test occursin("Date(2009, 3, 1)", sprint(showerror, err))
    end
    # A field name is not a literal, and keeps working (#801's own case).
    q = FD.Fd_result.objects
    q.values("x" => F("seen") - "race__date")
    @test occursin("julianday(\"Tb_1\".\"date\")", _fd_sql(q; conn = _FD_SL))
  end

  # A date literal needs a typed temporal left; against a number, or a function PormG does not
  # type, it is refused rather than rendered as a bare `-`.
  @testset "a date literal subtracted from a non-date is refused" begin
    for expr in (F("points") - Dates.Date(2009, 3, 1), _FN.Sum("points") - Dates.Date(2009, 3, 1),
                 F("seen__@year") - Dates.Date(2009, 3, 1)),
        conn in (_FD_SL, _FD_PG)
      q = FD.Fd_result.objects
      q.values("x" => expr)
      err = try _fd_sql(q; conn = conn); nothing catch e; e end
      @test err isa PormG.QueryBuildError
      @test occursin("needs a date or timestamp on the left", sprint(showerror, err))
    end
  end

  # A date literal is still a COMPARISON operand (#494) — the refusal above is for `-` only.
  @testset "a date comparison is unchanged" begin
    q = FD.Fd_result.objects
    q.filter(F("seen") > Dates.Date(2009, 3, 1))
    @test _fd_params(q; conn = _FD_SL) == Any["2009-03-01"]
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# #814: a day count combined with a date is a whole-day SHIFT, on both engines.
# After #801 a DATE - DATE difference is a day count (CInt32). `date ± count` and `count + date` are
# shifts on PostgreSQL (`date + integer`), while SQLite added the date's YEAR to the integer,
# silently. Both now render the shift and type it as the date side's kind. SQLite goes through the
# julian-day number, so the two sides keep the text order they were bound in, which the `count + date`
# case with a bound parameter on each side pins. `count - date` has no meaning and is refused on both.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#814: a day count combined with a date is a whole-day shift" begin
  count() = F("seen") - F("race__date")   # a day count: DATE - DATE
  for (label, expr, kind, sl_sql, pg_sql) in (
      ("date - count", F("seen") - count(), PormG.CDate(),
       "date(julianday(\"Tb\".\"seen\") - (CAST(julianday(\"Tb\".\"seen\") - julianday(\"Tb_1\".\"date\") AS INTEGER)))",
       "(\"Tb\".\"seen\" - (\"Tb\".\"seen\" - \"Tb_1\".\"date\"))"),
      ("date + count", F("seen") + count(), PormG.CDate(),
       "date(julianday(\"Tb\".\"seen\") + (CAST(julianday(\"Tb\".\"seen\") - julianday(\"Tb_1\".\"date\") AS INTEGER)))",
       "(\"Tb\".\"seen\" + (\"Tb\".\"seen\" - \"Tb_1\".\"date\"))"),
      ("count + date", count() + F("seen"), PormG.CDate(),
       "date((CAST(julianday(\"Tb\".\"seen\") - julianday(\"Tb_1\".\"date\") AS INTEGER)) + julianday(\"Tb\".\"seen\"))",
       "((\"Tb\".\"seen\" - \"Tb_1\".\"date\") + \"Tb\".\"seen\")"),
      # A timestamp has no `+ integer` on PostgreSQL, so the count becomes an interval there; SQLite
      # renders the shifted julian number in the canonical timestamp form.
      ("timestamp + count", F("logged_at") + count(), PormG.CDateTime(true),
       "strftime('%Y-%m-%dT%H:%M:%f+00:00', julianday(\"Tb\".\"logged_at\") + (CAST(julianday(\"Tb\".\"seen\") - julianday(\"Tb_1\".\"date\") AS INTEGER)))",
       "(\"Tb\".\"logged_at\" + make_interval(days => (\"Tb\".\"seen\" - \"Tb_1\".\"date\")))"),
      ("count + timestamp", count() + F("logged_at"), PormG.CDateTime(true),
       "strftime('%Y-%m-%dT%H:%M:%f+00:00', (CAST(julianday(\"Tb\".\"seen\") - julianday(\"Tb_1\".\"date\") AS INTEGER)) + julianday(\"Tb\".\"logged_at\"))",
       "(make_interval(days => (\"Tb\".\"seen\" - \"Tb_1\".\"date\")) + \"Tb\".\"logged_at\")"),
    )
    @testset "$label" begin
      q = FD.Fd_result.objects
      q.values("x" => expr)
      @test occursin(sl_sql, _fd_sql(q; conn = _FD_SL))
      q_pg = FD.Fd_result.objects
      q_pg.values("x" => expr)
      @test occursin(pg_sql, _fd_sql(q_pg; conn = _FD_PG))
      for conn in (_FD_SL, _FD_PG)
        @test _fd_kinds(q -> q.values("x" => expr); conn = conn)[:x] === kind
      end
    end
  end

  # Each side carries its own bound parameter. The cross-backend differential is the oracle for
  # order: PostgreSQL numbers placeholders as it binds them, so walking its `$N` markers left to right
  # gives the true text order, and SQLite's flat vector must equal it. A shift spelled as a modifier,
  # `date(<date>, <count> || ' days')`, would print the count after the date it was bound before.
  @testset "count + date keeps parameter order on SQLite" begin
    expr = ((F("seen") + Dates.Day(3)) - F("race__date")) + (F("seen") + Dates.Day(5))
    q_pg = FD.Fd_result.objects
    q_pg.values("x" => expr)
    pg = inspect_query(q_pg; connection = _FD_PG)
    idx = [parse(Int, m.match[2:end]) for m in eachmatch(r"\$\d+", pg[:sql_text])]
    text_order = [pg[:parameters][i] for i in idx]
    @test text_order == Any[3, 5]

    q = FD.Fd_result.objects
    q.values("x" => expr)
    @test _fd_params(q; conn = _FD_SL) == text_order
    # The differential above sees the BUCKET order, not a swap of the two sides' text inside one
    # bucket — SQLite's vector is in bind order whichever side prints first (the review of #814
    # mutated the render to date-first and this half stayed green). So the text is pinned too: the
    # count's `?` (3) prints before the date's (5).
    @test occursin("date((CAST(julianday(date(\"Tb\".\"seen\", '+' || ? || ' days')) - julianday(\"Tb_1\".\"date\") AS INTEGER)) " *
                   "+ julianday(date(\"Tb\".\"seen\", '+' || ? || ' days')))", _fd_sql(q; conn = _FD_SL))
  end

  @testset "count - date is refused on both engines" begin
    for expr in (count() - F("seen"), count() - Dates.Date(2009, 3, 1)), conn in (_FD_SL, _FD_PG)
      q = FD.Fd_result.objects
      q.values("x" => expr)
      err = try _fd_sql(q; conn = conn); nothing catch e; e end
      @test err isa PormG.QueryBuildError
      @test occursin("day count minus a date has no meaning", sprint(showerror, err))
    end
  end

  # The interval half: `date ± interval` is native on PostgreSQL and was text arithmetic on SQLite —
  # the year plus the hours. Refused on SQLite; `interval - date` is meaningless and refused on both.
  @testset "a date shifted by an interval value is refused on SQLite" begin
    tsdiff() = F("logged_at") - F("race__starts_at")
    for (expr, pg_sql) in ((F("seen") + F("lap"), "(\"Tb\".\"seen\" + \"Tb\".\"lap\")"),
                           (F("logged_at") - F("lap"), "(\"Tb\".\"logged_at\" - \"Tb\".\"lap\")"),
                           (F("lap") + F("seen"), "(\"Tb\".\"lap\" + \"Tb\".\"seen\")"),
                           (F("seen") + tsdiff(), "(\"Tb\".\"seen\" + (\"Tb\".\"logged_at\" - \"Tb_1\".\"starts_at\"))"))
      q = FD.Fd_result.objects
      q.values("x" => expr)
      err = try _fd_sql(q; conn = _FD_SL); nothing catch e; e end
      @test err isa PormG.QueryBuildError
      @test occursin("not supported on SQLite", sprint(showerror, err))

      q_pg = FD.Fd_result.objects
      q_pg.values("x" => expr)
      @test occursin(pg_sql, _fd_sql(q_pg; conn = _FD_PG))
    end
    for conn in (_FD_SL, _FD_PG)
      q = FD.Fd_result.objects
      q.values("x" => F("lap") - F("seen"))
      err = try _fd_sql(q; conn = conn); nothing catch e; e end
      @test err isa PormG.QueryBuildError
      @test occursin("duration minus a date has no meaning", sprint(showerror, err))
    end
  end

  # A count or an interval with a NON-temporal right is arithmetic, exactly as before.
  @testset "a day count or a duration with a number is unchanged" begin
    for (expr, sl_sql, pg_sql) in (
        (count() * 2, "(CAST(julianday(\"Tb\".\"seen\") - julianday(\"Tb_1\".\"date\") AS INTEGER) * ?)",
         "((\"Tb\".\"seen\" - \"Tb_1\".\"date\") * \$1::bigint)"),
        (count() - F("points"), "(CAST(julianday(\"Tb\".\"seen\") - julianday(\"Tb_1\".\"date\") AS INTEGER) - \"Tb\".\"points\")",
         "((\"Tb\".\"seen\" - \"Tb_1\".\"date\") - \"Tb\".\"points\")"),
        (F("lap") + 1, "(\"Tb\".\"lap\" + ?)", "(\"Tb\".\"lap\" + \$1::bigint)"),
      )
      q = FD.Fd_result.objects
      q.values("x" => expr)
      @test occursin(sl_sql, _fd_sql(q; conn = _FD_SL))
      q_pg = FD.Fd_result.objects
      q_pg.values("x" => expr)
      @test occursin(pg_sql, _fd_sql(q_pg; conn = _FD_PG))
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# #801: a day count compares against a number.
# `(F("seen") - F("race__date")) > 30` raised on BOTH engines before: the comparison literal was
# bound through the ROOTED column's formatter, which is a DateField's — `format_date_sql(30)`. The
# left now evaluates to CInt32, which is not the column's kind, so the literal binds as a number.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#801: a date difference compares against an integer" begin
  q = FD.Fd_result.objects
  q.filter((F("seen") - F("race__date")) > 30)
  @test occursin("WHERE (CAST(julianday(\"Tb\".\"seen\") - julianday(\"Tb_1\".\"date\") AS INTEGER) > ?)",
                 _fd_sql(q; conn = _FD_SL))
  @test _fd_params(q; conn = _FD_SL) == Any[30]

  q_pg = FD.Fd_result.objects
  q_pg.filter((F("seen") - F("race__date")) > 30)
  @test occursin("WHERE ((\"Tb\".\"seen\" - \"Tb_1\".\"date\") > \$1::bigint)", _fd_sql(q_pg; conn = _FD_PG))
  @test _fd_params(q_pg; conn = _FD_PG) == Any[30]
end

# ─────────────────────────────────────────────────────────────────────────────
# #801: `+`, `*` and `/` between two temporal values are refused on both engines.
# PostgreSQL has no `date + date` and fails at execution; SQLite added the two years and returned a
# number. Refusing at build time makes the engines agree, and neither answer is silent.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#801: arithmetic other than - between two temporal values is refused" begin
  for expr in (F("seen") + F("race__date"), F("logged_at") * F("seen"), F("seen") / F("logged_at")),
      conn in (_FD_SL, _FD_PG)
    q = FD.Fd_result.objects
    q.values("x" => expr)
    err = try _fd_sql(q; conn = conn); nothing catch e; e end
    @test err isa PormG.QueryBuildError
    @test occursin("has no meaning", sprint(showerror, err))
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# #801 controls: everything that is not a difference of two temporal values renders as before.
# The new branch is entered only for arithmetic over a temporal left, and answers the old way when
# the right is not temporal; a comparison never enters it. Pinned on both engines, as exact text.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#801: non-temporal differences are unchanged" begin
  for (label, expr, sl_sql, pg_sql) in (
      ("integer columns", F("points") - F("points"),
       "(\"Tb\".\"points\" - \"Tb\".\"points\")", "(\"Tb\".\"points\" - \"Tb\".\"points\")"),
      ("a DATE minus whole days", F("seen") - 7,
       "date(\"Tb\".\"seen\", '-' || ? || ' days')",
       "((\"Tb\".\"seen\" - make_interval(days => \$1::integer)))::date"),
      # Nonsense, but it was a bare `-` before and its right side has no temporal kind.
      ("a DATE minus an integer column", F("seen") - F("points"),
       "(\"Tb\".\"seen\" - \"Tb\".\"points\")", "(\"Tb\".\"seen\" - \"Tb\".\"points\")"),
      # A difference used as a number keeps composing as one.
      ("a day count plus one", (F("seen") - F("race__date")) + 1,
       "(CAST(julianday(\"Tb\".\"seen\") - julianday(\"Tb_1\".\"date\") AS INTEGER) + ?)",
       "((\"Tb\".\"seen\" - \"Tb_1\".\"date\") + \$1::bigint)"),
    )
    @testset "$label" begin
      q = FD.Fd_result.objects
      q.values("x" => expr)
      @test occursin(sl_sql, _fd_sql(q; conn = _FD_SL))
      q_pg = FD.Fd_result.objects
      q_pg.values("x" => expr)
      @test occursin(pg_sql, _fd_sql(q_pg; conn = _FD_PG))
    end
  end

  # An UNTYPED left keeps the rooted column's formatter, exactly as #536 left it.
  @testset "untyped arithmetic compared against a literal binds as before" begin
    q = FD.Fd_result.objects
    q.filter(F("points") * 2 > 5)
    @test occursin("WHERE ((\"Tb\".\"points\" * \$1::bigint) > \$2::bigint)", _fd_sql(q; conn = _FD_PG))
    @test _fd_params(q; conn = _FD_PG) == Any[2, 5]

    # The control above cannot tell the rule's `nothing` clause apart: an IntegerField's canonical
    # kind is `nothing` too. A DATE root can — `F("seen") * 2` is untyped arithmetic, so the root
    # still decides and `5` still reaches `format_date_sql`, which refuses it, as it did before.
    q2 = FD.Fd_result.objects
    q2.filter(F("seen") * 2 > 5)
    err = try _fd_sql(q2; conn = _FD_SL); nothing catch e; e end
    @test err isa PormG.FilterError
  end

  # A left whose kind differs from its root binds through the LEFT's kind, not the literal's own
  # type: a sub-day-promoted DATE is a timestamp, so `5` is refused rather than bound as an integer
  # that SQLite would compare against the TEXT timestamp (always true, silently).
  @testset "a promoted timestamp compared against a number is still refused" begin
    for conn in (_FD_SL, _FD_PG)
      q = FD.Fd_result.objects
      q.filter((F("seen") + Dates.Hour(6)) > 5)
      err = try _fd_sql(q; conn = conn); nothing catch e; e end
      @test err isa PormG.FilterError
    end
  end

  # A date comparison is not arithmetic and never enters the new branch.
  @testset "a date-to-date comparison is unchanged" begin
    q = FD.Fd_result.objects
    q.filter(F("seen") > F("race__date"))
    @test occursin("WHERE (\"Tb\".\"seen\" > \"Tb_1\".\"date\")", _fd_sql(q; conn = _FD_SL))
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# #884 — a number on the LEFT keeps the whole expression. `2 * (F("points") - F("amount"))` was
# built from the expression's root column alone, so it rendered `"points" * 2` on both engines and
# the subtraction was gone. Here because a date difference is the case that needed it (`2 * d`, #881).
# ─────────────────────────────────────────────────────────────────────────────
@testset "#884: a number on the left keeps the whole expression" begin
  for (label, expr, sl_sql, pg_sql, params) in (
      ("2 * (a - b)", 2 * (F("points") - F("amount")),
       "((\"Tb\".\"points\" - \"Tb\".\"amount\") * ?)",
       "((\"Tb\".\"points\" - \"Tb\".\"amount\") * \$1::bigint)", Any[2]),
      ("1 + (a * b)", 1 + (F("points") * F("amount")),
       "((\"Tb\".\"points\" * \"Tb\".\"amount\") + ?)",
       "((\"Tb\".\"points\" * \"Tb\".\"amount\") + \$1::bigint)", Any[1]),
      ("2.5 * ((a - b) + c)", 2.5 * ((F("points") - F("amount")) + F("points")),
       "(((\"Tb\".\"points\" - \"Tb\".\"amount\") + \"Tb\".\"points\") * ?)",
       "(((\"Tb\".\"points\" - \"Tb\".\"amount\") + \"Tb\".\"points\") * \$1::double precision)", Any[2.5]),
      # The bare-column control: it was always right, and must stay the same SQL.
      ("2 * F(a)", 2 * F("points"),
       "(\"Tb\".\"points\" * ?)", "(\"Tb\".\"points\" * \$1::bigint)", Any[2]),
    )
    @testset "$label" begin
      q = FD.Fd_result.objects
      q.values("x" => expr)
      @test occursin(sl_sql, _fd_sql(q; conn = _FD_SL))
      @test _fd_params(q; conn = _FD_SL) == params
      q_pg = FD.Fd_result.objects
      q_pg.values("x" => expr)
      @test occursin(pg_sql, _fd_sql(q_pg; conn = _FD_PG))
      @test _fd_params(q_pg; conn = _FD_PG) == params
    end
  end

  # The node is the one `f op n` builds: same operation and operand, and the expression nested.
  inner = F("points") - F("amount")
  outer = 2 * inner
  @test outer.field_name === inner
  @test outer.operation == "*" && outer.operand == 2
  @test inner.operation == "-"   # the operand is not written on
end
