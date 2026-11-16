# ============================================================
# test/unit/test_read_filters_trim_1599.jl
#
# CONTRACT being tested:
#   The typed forms a comparison filter's unnamed-temporal check (#1310) and an `order_by` term now go through
#   (#1599 layer 5) answer what the forms they replaced answered, value for value, and raise what those raised,
#   with the same text:
#     - the side walks (`_side_walk_kind_any`, `_null_side`, `_unnamed_side`, `_temporal_inside_any`,
#       `_held_temporal`, `_unnamed_side_label_any`, `_unnamed_temporal_side`, `_time_arithmetic_side`) against
#       the calls they replace, over every side shape the queue holds and over values that take an open arm;
#     - the two refusals (`_unnamed_temporal_refusal`, `_time_arithmetic_refusal`) against their old builders,
#       on SQLite and MySQL, for every temporal kind;
#     - `_order_term_at` against the two `_order_term_sql` calls `_render_order_terms` made, on every engine.
#   The old forms are copied below, verbatim, as the oracle. What the filters and orderings render end to end
#   (their SQL, parameters and refusals) is pinned by the render suites (test_untyped_temporal_operand.jl,
#   test_order_by_nulls.jl, test_mysql_render.jl and others), unchanged.
#
# Hermetic: mock connections, no database.
#
# Run: julia --project=test/integration test/unit/test_read_filters_trim_1599.jl
# ============================================================

using Test
isdefined(Main, :SQLite) || include(joinpath(@__DIR__, "..", "load_drivers.jl"))
using PormG
using Dates
using PormG.QueryBuilder: F, Case, When, Coalesce, Max, Extract, OuterRef, Cast

const _RFT_QB = PormG.QueryBuilder
const _RFT_K = PormG.Kernel

# Dedicated config keys and mock types: `runtests.jl` includes every unit file into one `Main`.
struct RftMockSQLite <: PormG.PormGSQLite end
struct RftMockSQLiteOld <: PormG.PormGSQLite end
struct RftMockPostgres <: PormG.PormGPostgres end
struct RftMockMySQL <: PormG.PormGMySQL end
PormG.backend_sqlite_version(::RftMockSQLite) = 3045000
PormG.backend_sqlite_version(::RftMockSQLiteOld) = 3029000   # before NULLS FIRST/LAST: the emulated arm

PormG.config["rft_mock"] = PormG.Configuration.Settings(connections = RftMockSQLite(), change_data = true,
                                                        db_def_folder = "rft_mock")

module RftModels
import PormG
import PormG.Models
Rft_race = Models.Model("rft_race",
  raceid         = Models.IDField(),
  year           = Models.IntegerField(),
  date           = Models.DateField(null = true),
  start_at       = Models.DateTimeField(null = true),
  fastestlaptime = Models.DurationField(null = true),
  time           = Models.TimeField(null = true),
  meta           = Models.JSONField(null = true),
)
Models.@models Rft_race
PormG.Models.set_models(@__MODULE__, "rft_mock")
end
const _RFT_RACE = RftModels.Rft_race

# ── The old forms, copied from the code before #1599 layer 5 ─────────────────────────────────────────────────
_old_unnamed_side(x, instruc) =
  !_RFT_QB._is_null_literal(x isa _RFT_QB.SQLText ? x.field : x) &&
  (k = _RFT_QB._side_walk_kind(x, instruc); k === nothing || k isa Union{_RFT_K.CJSON,_RFT_QB.CJSONValue})
function _old_unnamed_temporal_side(left, right, instruc)
  for (side, other) in ((left, right), (right, left))
    _old_unnamed_side(side, instruc) || continue
    k = _RFT_QB._side_walk_kind(other, instruc)
    _RFT_QB._is_temporal_kind(k) && return (side, k)
    held = _RFT_QB._temporal_inside(side, instruc)
    held === nothing || return (side, held)
  end
  return nothing
end
function _old_held_temporal(x, instruc)
  _RFT_QB._is_null_literal(x isa _RFT_QB.SQLText ? x.field : x) && return nothing
  k = _RFT_QB._side_walk_kind(x, instruc)
  return _RFT_QB._is_temporal_kind(k) ? k : _RFT_QB._temporal_inside(x, instruc)
end
function _old_time_arithmetic_side(left, right, op, instruc)
  op in _RFT_QB._ARITHMETIC_OPERATIONS || return nothing
  for side in (left, right)
    _RFT_QB._is_null_literal(side isa _RFT_QB.SQLText ? side.field : side) && continue
    _RFT_QB._side_walk_kind(side, instruc) isa _RFT_K.CTime && return side
  end
  return nothing
end
function _old_unnamed_temporal_remedy(conn, kind)
  kind isa _RFT_K.CTime && return "give every value of a `Case` or `Coalesce` the one type (then = F(\"time\"), " *
                           "default = Time(0)), and compare a time with a time (a Time literal)"
  values = "give every value of a `Case` or `Coalesce` the one type, and do the arithmetic inside each " *
           "branch"
  kind isa _RFT_K.CInterval && return values * " (then = F(\"fastestlaptime\") * 2, default = Second(0))"
  kind isa _RFT_K.CDate && return values * " (then = F(\"date\") + 1), or cast the value to a date (Cast(…, \"date\"))"
  return values * _old_timestamp_remedy(conn)
end
_old_timestamp_remedy(::PormG.PormGSQLite) = " (then = F(\"start_at\") + Hour(1))"
_old_timestamp_remedy(::PormG.PormGMySQL) = ", or cast the value to a timestamp (Cast(…, \"timestamp\"))"
_old_temporal_beside(kind) = kind isa _RFT_K.CTime ? "a time of day" : "a date, a timestamp or an interval"
_old_unnamed_temporal_refusal(conn::PormG.PormGSQLite, op, label, kind) =
  PormG.QueryBuildError("`$(op)` beside $(_old_temporal_beside(kind)), with $(label) on one side, is not " *
                  "supported on SQLite: PormG cannot type $(label), and the SQL depends on the type, since a " *
                  (kind isa _RFT_K.CTime ? "time is its `HH:MM:SS` text there" :
                                    "date is text there and an interval is its `HH:MM:SS` text") *
                  ". State the type: " * _old_unnamed_temporal_remedy(conn, kind) * ".")
_old_unnamed_temporal_refusal(conn::PormG.PormGMySQL, op, label, kind) =
  PormG.QueryBuildError("`$(op)` beside $(_old_temporal_beside(kind)), with $(label) on one side, is not " *
                  "supported on MySQL: PormG cannot type $(label), and the SQL depends on the type, since " *
                  (kind isa _RFT_K.CTime ? "MySQL reads a time there as the number its digits spell (06:00:00 is 60000)" :
                                    "MySQL reads a date there as the number its digits spell (2009-03-29 is 20090329)") *
                  ". State the type: " * _old_unnamed_temporal_remedy(conn, kind) * ".")
_old_order_term(expr, orientation, placement, conn, null_flag, flagged::Bool) =
  flagged ? _RFT_QB._order_term_sql(expr, orientation, placement, conn; null_flag = null_flag) :
            _RFT_QB._order_term_sql(expr, orientation, placement, conn)

# What a call gave: its value, or the type and text of what it raised.
_rft_outcome(f) = try
  (:value, f())
catch e
  (:raised, typeof(e), sprint(showerror, e))
end

# An instruction the walks can read: a built query over the mock model, on `conn`.
_rft_instruc(conn) = _RFT_QB.build(_RFT_RACE.objects.filter("year" => 2009).object; connection = conn)

# The sides a queued comparison holds: the column and value nodes a filter queues, an `F` expression's sides, a
# function, an outer reference, a path, literals of each kind the walks name, and values that take the open arms.
function _rft_sides()
  Any[
    _RFT_QB.SQLField("date"), _RFT_QB.SQLField("year"), _RFT_QB.SQLField("time"), _RFT_QB.SQLField("start_at"),
    _RFT_QB.SQLField("fastestlaptime"), _RFT_QB.SQLField("meta__round"),
    _RFT_QB.SQLText(Date(2009, 1, 1)), _RFT_QB.SQLText(5), _RFT_QB.SQLText("2009-01-01"), _RFT_QB.SQLText(nothing),
    _RFT_QB.SQLText("NULL"), _RFT_QB.SQLText(missing), _RFT_QB.SQLText(SubString("NULL", 1)),
    F("date") + 1, F("year") * 2, F("meta__round") * 2, F("date"),
    Max("date"), Extract("date", "year"), Coalesce("date", "start_at"),
    Case(When("year__@gt" => 2000, then = F("date")), default = F("meta__round")),
    OuterRef("date"),
    "date", "year", "Monaco", SubString("NULL", 1), "NULL",
    5, 2.5, true, Int32(3), Date(2009, 5, 24), DateTime(2009, 5, 24, 14), Time(6), Day(1), Hour(2),
    PormG.Models.Decimals.Decimal(0, 150, -2), nothing, missing, :symbol,
  ]
end

const _RFT_CONNS = (RftMockSQLite(), RftMockMySQL(), RftMockPostgres())

# What: the side walks against the calls they replace, over every side shape on each engine.
# Expected: the same outcome: the same value (`isequal`), or the same error type and text.
# Why: the walks exist so a trimmed image can run the check; under the JIT they must be invisible. An arm that
#   answered differently (a `SubString` "NULL" not seen as NULL, a path read as text) would change which
#   comparisons are refused.
@testset "the unnamed-temporal side walks answer what the calls they replace answered (#1599 layer 5)" begin
  for conn in _RFT_CONNS
    instruc = _rft_instruc(conn)
    sides = _rft_sides()
    for x in sides
      tag = (nameof(typeof(conn)), typeof(x))
      @test (tag, _rft_outcome(() -> _RFT_QB._side_walk_kind_any(x, instruc))) ==
            (tag, _rft_outcome(() -> _RFT_QB._side_walk_kind(x, instruc)))
      @test (tag, _RFT_QB._null_side(x)) == (tag, _RFT_QB._is_null_literal(x isa _RFT_QB.SQLText ? x.field : x))
      @test (tag, _rft_outcome(() -> _RFT_QB._unnamed_side(x, instruc))) == (tag, _rft_outcome(() -> _old_unnamed_side(x, instruc)))
      @test (tag, _rft_outcome(() -> _RFT_QB._temporal_inside_any(x, instruc))) ==
            (tag, _rft_outcome(() -> _RFT_QB._temporal_inside(x, instruc)))
      @test (tag, _rft_outcome(() -> _RFT_QB._held_temporal(x, instruc))) == (tag, _rft_outcome(() -> _old_held_temporal(x, instruc)))
      @test (tag, _rft_outcome(() -> _RFT_QB._unnamed_side_label_any(x))) == (tag, _rft_outcome(() -> _RFT_QB._unnamed_side_label(x)))
    end
    # Pairs: every column node against every side, both ways, under an ordering and an arithmetic operator.
    for left in sides[1:6], right in sides, op in (">=", "<", "+", "*")
      tag = (nameof(typeof(conn)), typeof(left), typeof(right), op)
      @test (tag, _rft_outcome(() -> _RFT_QB._unnamed_temporal_side(left, right, instruc))) ==
            (tag, _rft_outcome(() -> _old_unnamed_temporal_side(left, right, instruc)))
      @test (tag, _rft_outcome(() -> _RFT_QB._unnamed_temporal_side(right, left, instruc))) ==
            (tag, _rft_outcome(() -> _old_unnamed_temporal_side(right, left, instruc)))
      @test (tag, _rft_outcome(() -> _RFT_QB._time_arithmetic_side(left, right, op, instruc))) ==
            (tag, _rft_outcome(() -> _old_time_arithmetic_side(left, right, op, instruc)))
    end
  end
end

# What: the two refusals the check raises, new builders against old, on the two engines that refuse.
# Expected: the same error type and the same text, for every temporal kind, operator and label.
# Why: the builders now take the kind unspecialized and read the timestamp remedy in the refusal, at the
#   engine's type; the message a caller reads must not change by one character.
@testset "the unnamed-temporal refusals read as they did (#1599 layer 5)" begin
  for conn in (RftMockSQLite(), RftMockMySQL()),
      kind in (_RFT_K.CDate(), _RFT_K.CDateTime(false), _RFT_K.CDateTime(true), _RFT_K.CTime(),
              _RFT_K.CInterval(false), _RFT_K.CInterval(true)),
      op in (">=", "+", "@range"), label in ("`meta__round`", "`CASE(…)`", "a value")
    new = _RFT_QB._unnamed_temporal_refusal(conn, op, label, kind)
    old = _old_unnamed_temporal_refusal(conn, op, label, kind)
    @test (typeof(new), new.msg) == (typeof(old), old.msg)
    @test _RFT_QB._unnamed_temporal_remedy(kind, _RFT_QB._timestamp_remedy(conn)) == _old_unnamed_temporal_remedy(conn, kind)
    @test _RFT_QB._temporal_beside(kind) == _old_temporal_beside(kind)
  end
end
