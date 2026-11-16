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
Rft_circuit::Models.ModelType = Models.Model("rft_circuit",
  circuitid = Models.IDField(),
  name      = Models.CharField(max_length = 50),
  country   = Models.CharField(max_length = 50, db_column = "country_name"),
)
Rft_race::Models.ModelType = Models.Model("rft_race",
  raceid         = Models.IDField(),
  circuitid      = Models.ForeignKey("Rft_circuit"),
  year           = Models.IntegerField(),
  date           = Models.DateField(null = true),
  start_at       = Models.DateTimeField(null = true),
  fastestlaptime = Models.DurationField(null = true),
  time           = Models.TimeField(null = true),
  meta           = Models.JSONField(null = true),
)
Models.@models Rft_circuit Rft_race
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

# What: a literal's kind and a bound literal's (`SQLText`) kind, through the walks, against the calls they replace,
#   under both kind policies.
# Expected: the same kind, or `nothing`, for every literal the walk names and for ones that take its open arm.
# Why: `_infer_kind(::SQLText)` now asks `_null_literal_any` and `_literal_kind_any` instead of calling
#   `_is_null_literal` and `_literal_kind` on its untyped slot; a literal read as another kind would change which
#   comparisons are refused and how an expression is typed.
@testset "a literal's kind reads as it did (#1599 layer 5)" begin
  instruc = _rft_instruc(RftMockSQLite())
  lits = Any["2008-06-01", SubString("Monaco", 1, 3), "NULL", SubString("NULL", 1), 5, Int32(3), Int16(2), true, 2.5,
             Float32(1.5), PormG.Models.Decimals.Decimal(0, 150, -2), Date(2008, 6, 1), DateTime(2008, 6, 1, 14),
             PormG.Models.ZonedDateTime(2008, 6, 1, 14, PormG.Models.TimeZone("UTC")), Time(6), Day(1),
             Month(1) + Day(2), nothing, missing, :symbol, [1, 2]]
  for policy in (_RFT_QB._AllKinds(), _RFT_QB._MeaningKinds()), x in lits
    tag = (typeof(policy), typeof(x))
    x === nothing || x === missing ||
      @test (tag, _rft_outcome(() -> _RFT_QB._literal_kind_any(x, policy))) == (tag, _rft_outcome(() -> _RFT_QB._literal_kind(x, policy)))
    @test (tag, _rft_outcome(() -> _RFT_QB._infer_kind(_RFT_QB.SQLText(x), instruc, policy))) ==
          (tag, _rft_outcome(() -> _RFT_QB._is_null_literal(x) ? nothing : _RFT_QB._literal_kind(x, policy)))
  end
end

# The old projected-path walk, verbatim (#1002), as the oracle for the ORDER BY term's own branch.
function _old_collect_projected_paths!(out::Vector{String}, x, depth::Int)
  QB = _RFT_QB
  depth > 32 && return nothing
  if x isa AbstractString
    occursin("__", x) && push!(out, String(x))
  elseif x isa Pair
    _old_collect_projected_paths!(out, x.second, depth + 1)
  elseif x isa Union{QB.SQLField,QB.SQLOrder}
    QB._with_field_part_open((part, o, d) -> _old_collect_projected_paths!(o, part, d), x.field, out, depth + 1)
  elseif x isa QB.WindowFunction
    _old_collect_projected_paths!(out, x.column, depth + 1)
    _old_collect_projected_paths!(out, x.over.partition_by, depth + 1)
    _old_collect_projected_paths!(out, x.over.order_by, depth + 1)
  elseif x isa QB.OperObject
    _old_collect_projected_paths!(out, QB._oper_column(x), depth + 1)
    rhs = QB._oper_value_node(x)
    rhs isa Union{QB.FExpression,QB.FObject,QB.SubqueryObject,QB.ObjectHandler} && _old_collect_projected_paths!(out, rhs, depth + 1)
  elseif x isa Union{QB.QObject,QB.QorObject}
    _old_collect_projected_paths!(out, QB._q_nodes(x), depth + 1)
  elseif x isa QB.FObject
    _old_collect_projected_paths!(out, x.column, depth + 1)
    for v in values(x.kwargs)
      v isa Union{PormG.Kernel.SQLTypeFunction,QB.FExpression} && _old_collect_projected_paths!(out, v, depth + 1)
    end
  elseif x isa QB.FExpression
    _old_collect_projected_paths!(out, x.field_name, depth + 1)
    _old_collect_projected_paths!(out, x.column, depth + 1)
    _old_collect_projected_paths!(out, x.operand, depth + 1)
  elseif x isa AbstractVector && !(x isa AbstractVector{UInt8})
    for v in x; _old_collect_projected_paths!(out, v, depth + 1); end
  end
  return nothing
end

# What: the paths an `order_by` names (`_projected_paths` over the query's ORDER BY terms), which MySQL and an old
#   SQLite read for their NULL sort key, against the old walk.
# Expected: the same paths, in the same order, for plain, descending, related, transformed, expression and
#   function terms, and for nested projections.
# Why: an `SQLOrder` term now takes its own branch (its slot is an `SQLField`, which the field-part walk has no
#   arm for); the recursion and its depth must be the old one.
@testset "the paths an order_by names are the ones it named (#1599 layer 5)" begin
  QB = _RFT_QB
  queries = Any[
    () -> _RFT_RACE.objects.order_by("date"), () -> _RFT_RACE.objects.order_by("-date", "year"),
    () -> _RFT_RACE.objects.order_by("meta__round"), () -> _RFT_RACE.objects.order_by("-date__@year"),
    () -> _RFT_RACE.objects.order_by(F("year") + 1), () -> _RFT_RACE.objects.order_by(Max("date")),
    () -> (q = _RFT_RACE.objects; q.values("y" => F("year") * 2, "d__x" => "date"); q.order_by("-y", "date"); q),
  ]
  for (i, mk) in enumerate(queries)
    q = try mk() catch e; (:raised, typeof(e)) end
    q isa Tuple && (@test (i, q) == (i, q); continue)
    terms = QB._order_terms(q.object)
    new = String[]; old = String[]
    QB._collect_projected_paths!(new, terms, 0)
    _old_collect_projected_paths!(old, terms, 0)
    @test (i, new) == (i, old)
    for t in terms
      n2 = String[]; o2 = String[]
      QB._collect_projected_paths!(n2, t, 31); _old_collect_projected_paths!(o2, t, 31)   # the depth cut-off
      @test (i, n2) == (i, o2)
    end
  end
end

# The old FROM-column walk's per-model loop, verbatim, as the oracle for `_add_from_model!` (`_from_column_names`).
function _old_from_model_columns(start::Vector{PormG.PormGModel}, tables::Set{String})
  cols = Set{String}(); candidates = copy(start); seen = Base.IdSet{PormG.PormGModel}(); order = String[]
  while !isempty(candidates)
    m = pop!(candidates)
    m in seen && continue
    push!(seen, m); push!(order, m.name)
    in_from = PormG.Models.model_table_name(m) in tables
    for (k, fld) in m.fields
      in_from && push!(cols, PormG.Models.field_db_column(fld, k))
      to = hasproperty(fld, :to) ? getproperty(fld, :to) : nothing
      to isa PormG.PormGModel && push!(candidates, to)
    end
    for rel in values(m.related_objects)
      for name in propertynames(rel)
        target = getproperty(rel, name)
        target isa PormG.PormGModel && push!(candidates, target)
      end
    end
  end
  return cols, order
end
function _new_from_model_columns(start::Vector{PormG.PormGModel}, tables::Set{String})
  cols = Set{String}(); candidates = copy(start); seen = Base.IdSet{PormG.PormGModel}(); order = String[]
  while !isempty(candidates)
    m = pop!(candidates)
    m in seen && continue
    push!(seen, m); push!(order, m.name)
    m isa PormG.Models.ModelType ? _RFT_QB._add_from_model!(cols, candidates, m, tables) :
                                   _RFT_QB._add_from_model_other!(cols, candidates, m, tables)
  end
  return cols, order
end

# What: the FROM tables' columns a MySQL `order_by` reads for its NULL sort key (`_from_column_names`), and the
#   per-model step it now calls, against the old loop: from the race, from the circuit, from both, with the race's
#   table, the circuit's, both and neither in the FROM clause; and the full function over orderings that join.
# Expected: the same columns (a `db_column` included), and the same models visited in the same order.
# Why: the loop's body moved into `_add_from_model!`, called at `ModelType`, and the table names go through
#   `_model_table_at`; the set of columns decides whether a term orders by a projection or a column.
@testset "the FROM columns an order_by reads are the ones it read (#1599 layer 5)" begin
  race, circuit = RftModels.Rft_race, RftModels.Rft_circuit
  for start in (PormG.PormGModel[race], PormG.PormGModel[circuit], PormG.PormGModel[race, circuit]),
      tables in (Set(["rft_race"]), Set(["rft_circuit"]), Set(["rft_race", "rft_circuit"]), Set{String}())
    @test (start, tables, _new_from_model_columns(start, tables)) == (start, tables, _old_from_model_columns(start, tables))
  end
  for t in (race, circuit)
    @test _RFT_QB._model_table_at(t) == PormG.Models.model_table_name(t)
  end
  for (orders, conn, from) in ((("date",), RftMockMySQL(), Set(["rft_race"])),
                               (("-circuitid__name", "date"), RftMockMySQL(), Set(["rft_race", "rft_circuit"])),
                               (("circuitid__country",), RftMockSQLiteOld(), Set(["rft_race", "rft_circuit"])))
    q = race.objects; q.order_by(orders...)
    instruc = _RFT_QB.build(q.object; connection = conn)
    @test (orders, sort!(collect(_RFT_QB._from_column_names(q.object, instruc)))) ==
          (orders, sort!(collect(_old_from_model_columns(PormG.PormGModel[race], from)[1])))
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

# What: `_order_term_at` against the two `_order_term_sql` calls `_render_order_terms` made, the plain one and
#   the one with a NULL flag, on every engine, for a term with and without a bound value, each orientation and
#   placement, and a term that is not text (the open arm).
# Expected: the same outcome: the same text, or the same error (MySQL refuses a bound term with no flag).
# Why: a NULL flag of `nothing` is the keyword's default, so the helper calls without it; that must be the
#   same call, and the open arm must take the old calls for anything that is not a `String`.
@testset "an order_by term renders as the calls it replaces rendered (#1599 layer 5)" begin
  for conn in (RftMockSQLite(), RftMockSQLiteOld(), RftMockMySQL(), RftMockPostgres(), nothing),
      expr in Any["\"Tb\".\"date\"", "(\"Tb\".\"year\" + ?)", SubString("\"Tb\".\"date\"", 1), _RFT_QB.SQLText("x")],
      orientation in ("ASC", "DESC"), placement in (:first, :last),
      (null_flag, flagged) in ((nothing, false), (nothing, true), ("\"Tb\".\"date\" * 1", true))
    tag = (conn === nothing ? :nothing : nameof(typeof(conn)), typeof(expr), orientation, placement, null_flag, flagged)
    @test (tag, _rft_outcome(() -> _RFT_QB._order_term_at(expr, orientation, placement, conn, null_flag))) ==
          (tag, _rft_outcome(() -> _old_order_term(expr, orientation, placement, conn, null_flag, flagged)))
  end
end
