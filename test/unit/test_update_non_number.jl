"""
An expression of a type that is no number, written by `update` into a numeric field, is refused on
every engine before any SQL (#1297).

`update("points" => F("token"))` rendered `SET "points" = "Tb"."token"` unchecked. A UUID, a date, a
timestamp, a time, an interval, binary data, a network address or a full-text document is no number:

- PostgreSQL has no assignment cast from any of them to `numeric`, `integer` or `double precision`,
  so the statement failed only when it ran, as a `StatementError`;
- SQLite stored the value's text (a blob's bytes) in the INTEGER, REAL or NUMERIC column, a silent
  different value.

No engine gives the call a meaning, so it is explicit intent (#1147): refused on every engine. The
refusal names no `Cast`, because PostgreSQL has none from these types to a number. A boolean is left
out (`true` against `1` is a meaning question), and so are text and JSON, which #1279 reads as numbers
to round.

Everything renders through mock connections — no live database, no fixture.

julia --project=test/integration test/unit/test_update_non_number.jl
"""

using Test
using PormG
using PormG.Models
import PormG: QueryBuildError

# Dedicated config key + mock types: `runtests.jl` includes every unit file into one `Main`.
struct UnnMockSQLite <: PormG.PormGSQLite end
struct UnnMockPostgres <: PormG.PormGPostgres end
const _UNN_SL = UnnMockSQLite()
const _UNN_PG = UnnMockPostgres()
PormG.backend_sqlite_version(::UnnMockSQLite) = 3045000

PormG.config["unn_mock"] = PormG.Configuration.Settings(
  connections = _UNN_SL, change_data = true, db_def_folder = "unn_mock",
)

module UnnModels
import PormG
import PormG.Models

# The F1 driver, with a few columns of the types under test.
Unn_driver = Models.Model("unn_driver",
  driverid = Models.IDField(),
  token    = Models.UUIDField(null = true),
  dob      = Models.DateField(null = true),
)
Unn_result = Models.Model("unn_result",
  resultid        = Models.IDField(),
  driverid        = Models.ForeignKey(Unn_driver, on_delete = "CASCADE"),
  points          = Models.DecimalField(max_digits = 10, decimal_places = 2, null = true),
  grid            = Models.IntegerField(null = true),
  milliseconds    = Models.BigIntegerField(null = true),
  fastestlapspeed = Models.FloatField(null = true),
  laps            = Models.PositiveIntegerField(null = true),
  positionorder   = Models.PositiveSmallIntegerField(null = true),
  positiontext    = Models.CharField(null = true),
  finished        = Models.BooleanField(null = true),
  token           = Models.UUIDField(null = true),
  racedate        = Models.DateField(null = true),
  recorded        = Models.DateTimeField(null = true),
  fastestlaptime  = Models.TimeField(null = true),
  duration        = Models.DurationField(null = true),
  telemetry       = Models.BinaryField(null = true),
)

PormG.Models.set_models(@__MODULE__, "unn_mock")
end

const UNN = UnnModels
const Fn = PormG.Functions
# Not `F`: `runtests.jl` includes every unit file into one `Main`, where `F` is already imported.
const _NF = PormG.QueryBuilder.F

# The statement `update` builds for one pair, on `conn`, filtered so it has a WHERE.
function _unn_update(field, value; conn)
  q = UNN.Unn_result.objects
  q.filter("resultid" => 1)
  q.object.insert[field] = value
  return PormG.QueryBuilder.update(q.object; connection = conn, show_query = :sql)
end
_unn_refusal(field, value; conn) = try _unn_update(field, value; conn = conn); nothing catch e; e end
_unn_msg(e) = replace(sprint(showerror, e), r"\e\[[0-9;]*m" => "")

@testset "update: a non-number column into a numeric field is refused on every engine (#1297)" begin
  # What: each column below written into the DecimalField `points`, the IntegerField `grid`, the
  # BigIntegerField `milliseconds` and the FloatField `fastestlapspeed` raises `QueryBuildError` on
  # PostgreSQL and SQLite, naming the call, the column, its type, the field and #1297. Why: SQLite
  # stored the value's text in the number column, and PostgreSQL failed only at execute.
  targets = (("points", "DecimalField"), ("grid", "IntegerField"),
             ("milliseconds", "BigIntegerField"), ("fastestlapspeed", "FloatField"),
             ("laps", "PositiveIntegerField"), ("positionorder", "PositiveSmallIntegerField"))
  for (column, what) in (("token", "a UUID"), ("racedate", "a date"), ("recorded", "a timestamp"),
                         ("fastestlaptime", "a time of day"), ("duration", "an interval"),
                         ("telemetry", "binary data"))
    @testset "$column" begin
      for (field, declared) in targets, conn in (_UNN_PG, _UNN_SL)
        err = _unn_refusal(field, _NF(column); conn = conn)
        msg = err === nothing ? "" : _unn_msg(err)
        @test err isa QueryBuildError
        @test occursin("update(\"$(field)\" => …) writes `$(column)`, which is $(what), into the $(declared) `$(field)`", msg)
        @test occursin("no number on any engine, so PormG refuses it (#1297)", msg)
        @test !occursin("PostgreSQL", msg) && !occursin("SQLite", msg)
      end
    end
  end
end

@testset "update: a joined or wrapped non-number operand is refused too (#1297)" begin
  # What: the driver's UUID over the join, a `Coalesce` over the result's own UUID and a `Max` over a
  # date are refused into `points` on both engines; an expression with no label is named "the
  # expression". Why: the check reads the operand's type through the walk, whatever wraps it.
  for conn in (_UNN_PG, _UNN_SL)
    msg = _unn_msg(_unn_refusal("points", _NF("driverid__token"); conn = conn))
    @test occursin("writes `driverid__token`, which is a UUID", msg)
    for value in (Fn.Coalesce("token", "token"), Fn.Max("racedate"))
      err = _unn_refusal("points", value; conn = conn)
      @test err isa QueryBuildError
      @test occursin("writes the expression, which is", _unn_msg(err))
    end
  end
end

@testset "update: temporal arithmetic and a declared non-number cast are refused too (#1297)" begin
  # What: `recorded - recorded` (an interval), `racedate + 1` (a date) and `duration * 2` (an
  # interval) into the BigIntegerField `milliseconds`, and `Cast(token, "uuid")` / `Cast(…, "inet")`
  # into `grid`, raise `QueryBuildError` on both engines. Why: the arithmetic is the likeliest real
  # shape (a timestamp difference into a milliseconds column), and on SQLite a uuid or network cast
  # renders `CAST(x AS TEXT)`, which the walk types as text there, yet it still means a UUID; read by
  # the walk alone it built on SQLite and stored the text.
  for conn in (_UNN_PG, _UNN_SL)
    for (value, what) in ((_NF("recorded") - _NF("recorded"), "an interval"),
                          (_NF("racedate") + 1, "a date"),
                          (_NF("duration") * 2, "an interval"))
      err = _unn_refusal("milliseconds", value; conn = conn)
      @test err isa QueryBuildError
      @test occursin("which is $(what), into the BigIntegerField `milliseconds`", _unn_msg(err))
    end
    for (type, what) in (("uuid", "a UUID"), ("inet", "a network address"))
      err = _unn_refusal("grid", Fn.Cast(_NF("token"), type); conn = conn)
      @test err isa QueryBuildError
      @test occursin("which is $(what), into the IntegerField `grid`", _unn_msg(err))
    end
  end
end

@testset "update: an integer ForeignKey is a number field too (#1297)" begin
  # What: a UUID into the `driverid` ForeignKey (a `bigint` column) is refused on both engines, naming
  # the ForeignKey. Why: the key column is a number column, and SQLite would store the UUID's text in
  # it as it did for any other.
  for conn in (_UNN_PG, _UNN_SL)
    msg = _unn_msg(_unn_refusal("driverid", _NF("token"); conn = conn))
    @test occursin("writes `token`, which is a UUID, into the ForeignKey `driverid`", msg)
  end
end

@testset "update: a number, a boolean, text or a non-number field builds as before (#1297)" begin
  # What: these build `SET "<field>" = …` on both engines. Why: the refusal is for a non-number
  # operand into a number field only — a number column, a rounded expression, a boolean (a #1147
  # meaning question), text (#1279's, which a FloatField takes) and a UUID into a UUIDField are
  # untouched.
  for (field, value) in (
      ("points", _NF("points")),
      ("points", Fn.Round(_NF("fastestlapspeed"), 2)),
      ("grid", Fn.Extract(_NF("racedate"), "year")),   # the upgrade entry's ✓ spelling
      ("fastestlapspeed", _NF("grid")),
      ("grid", _NF("milliseconds")),
      ("grid", _NF("finished")),
      ("fastestlapspeed", _NF("positiontext")),
      ("token", _NF("driverid__token")),
      ("racedate", _NF("racedate")),
      ("positiontext", _NF("token")))
    for conn in (_UNN_PG, _UNN_SL)
      @test occursin("SET \"$(field)\" = ", _unn_update(field, value; conn = conn))
    end
  end
end
