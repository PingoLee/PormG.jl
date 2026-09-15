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
using PormG: Interval   # #527 — the `Interval("HH:MM:SS")` spelling of a sub-day duration
using Dates
import TimeZones   # #536 — the `ZonedDateTime` oracle row; a PormG dependency, so `--project=.` resolves it
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
