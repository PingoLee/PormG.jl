"""
An expression `update` writes into a `DecimalField(p, s)` is refused on SQLite when it can carry
more than `s` places, and builds on PostgreSQL (#1279).

The column is `numeric(p, s)` on both engines, and assigning a value to it means the value rounded to
`s` places, the meaning of the #1040 cast to `numeric(p, s)`. PostgreSQL's assignment cast rounds it.
SQLite's NUMERIC affinity keeps every digit its double arithmetic produced, and the read path returns
such a cell as a `Float64`. Measured on PostgreSQL 16 and SQLite 3.54 through `update` on a
`DecimalField(10, 2)`:

| write            | from    | PostgreSQL reads | SQLite reads                    |
|------------------|---------|------------------|---------------------------------|
| `F * 1.005`      | `1.00`  | `Decimal 1.01`   | `Float64 1.005`                 |
| `F / 3`          | `1.00`  | `Decimal 0.33`   | `Float64 0.3333333333333333`    |
| `F - 1`          | `1.10`  | `Decimal 0.1`    | `Float64 0.10000000000000009`   |
| `F + 0.20`       | `0.10`  | `Decimal 0.3`    | `Float64 0.30000000000000004`   |
| `Round(F / 3, 2)`| `1.00`  | `Decimal 0.33`   | `Decimal 0.33`                  |

So the operand is classified by the cast's own `_scale_divergent_operand` and the engine by the
departure table's `:scale` row, and the refusal names the `Round(x, s)` that stores the same value on
both. A literal is not this path: `DecimalValidator`'s width check refuses one on every engine (#761).

Everything renders through mock connections — no live database, no fixture.

julia --project=test/integration test/unit/test_update_decimal_scale.jl
"""

using Test
using PormG
using PormG.Models
import PormG: QueryBuildError, InvalidValueError

# Dedicated config key + mock types: `runtests.jl` includes every unit file into one `Main`.
struct UdsMockSQLite <: PormG.PormGSQLite end
struct UdsMockPostgres <: PormG.PormGPostgres end
const _UDS_SL = UdsMockSQLite()
const _UDS_PG = UdsMockPostgres()
PormG.backend_sqlite_version(::UdsMockSQLite) = 3045000

PormG.config["uds_mock"] = PormG.Configuration.Settings(
  connections = _UDS_SL, change_data = true, db_def_folder = "uds_mock",
)

module UdsModels
import PormG
import PormG.Models

Uds_team = Models.Model("uds_team",
  id     = Models.IDField(),
  budget = Models.DecimalField(max_digits = 12, decimal_places = 3, null = true),
  rating = Models.FloatField(null = true),
)
Uds_driver = Models.Model("uds_driver",
  id      = Models.IDField(),
  surname = Models.CharField(null = true),
  number  = Models.IntegerField(null = true),
  points  = Models.FloatField(null = true),
  price   = Models.DecimalField(max_digits = 10, decimal_places = 2, null = true),
  fee     = Models.DecimalField(max_digits = 10, decimal_places = 1, null = true),
  grid    = Models.DecimalField(max_digits = 4, decimal_places = 0, null = true),
  team    = Models.ForeignKey(Uds_team, on_delete = "CASCADE"),
)

PormG.Models.set_models(@__MODULE__, "uds_mock")
end

const UDS = UdsModels
const Fn = PormG.Functions
# Not `F`: `runtests.jl` includes every unit file into one `Main`, where `F` is already imported.
const _UF = PormG.QueryBuilder.F

# The SET clause `update` builds for one pair, on `conn`, filtered so it has a WHERE.
function _uds_update(field, value; conn)
  q = UDS.Uds_driver.objects
  q.filter("id" => 1)
  q.object.insert[field] = value
  return PormG.QueryBuilder.update(q.object; connection = conn, show_query = :sql)
end
_uds_refusal(field, value; conn) = try _uds_update(field, value; conn = conn); nothing catch e; e end
_uds_msg(e) = replace(sprint(showerror, e), r"\e\[[0-9;]*m" => "")

@testset "update: an expression into a DecimalField is refused on SQLite only (#1279)" begin
  # What: each expression below can carry more than `price`'s 2 places. SQLite refuses it, naming
  # itself, the field and `Round(x, 2)`; PostgreSQL builds `SET "price" = <expr>`, whose column
  # rounds. Why: SQLite would store every digit, and a later filter would match other rows than on
  # PostgreSQL — the silent different answer #1279 measured.
  for (label, value, named) in (
      ("F * 1.005", _UF("price") * 1.005, "arithmetic over the DecimalField `price`"),
      ("F / 3", _UF("price") / 3, "DecimalField `price`"),
      ("F + 1", _UF("price") + 1, "arithmetic over the DecimalField `price`"),
      ("F - 1", _UF("price") - 1, "arithmetic over the DecimalField `price`"),
      ("F * 2", _UF("price") * 2, "arithmetic over the DecimalField `price`"),
      ("F + 0.20", _UF("price") + 0.20, "arithmetic over the DecimalField `price`"),
      ("a float column", _UF("points"), "the FloatField `points`"),
      ("a 3-place column over a join", _UF("team__budget"), "3 decimal places"),
      ("a Case over a float literal", Fn.Case(Fn.When("number" => 1, then = 1.555), default = 0),
       "`CASE(…)` over a Float64 literal with 3 decimal places"))
    @testset "$label" begin
      err = _uds_refusal("price", value; conn = _UDS_SL)
      msg = err === nothing ? "" : _uds_msg(err)
      @test err isa QueryBuildError
      @test occursin("update(\"price\" => …)", msg)
      @test occursin(named, msg)
      @test occursin("so PormG refuses it on SQLite (#1279)", msg)
      @test occursin("Round(x, 2)", msg)
      @test !occursin("PostgreSQL", msg)
      @test occursin("SET \"price\" = ", _uds_update("price", value; conn = _UDS_PG))
    end
  end
end

@testset "update: a text operand is refused with the cast its fix needs (#1279)" begin
  # What: a text column into `price` is refused on SQLite, and the fix names
  # `Round(Cast(x, FloatField()), 2)`, not `Round(x, 2)`, which #1061 refuses over text on every
  # engine; for a 0-place field it names `Round(Cast(x, FloatField()))`. Both spellings build on both
  # engines. Why: the suggested spelling must itself build, or the refusal sends the caller to a
  # second one.
  err = _uds_refusal("price", _UF("surname"); conn = _UDS_SL)
  msg = err === nothing ? "" : _uds_msg(err)
  @test err isa QueryBuildError
  @test occursin("the text column `surname`", msg) && occursin("so PormG refuses it on SQLite (#1279)", msg)
  @test occursin("update(\"price\" => Round(Cast(x, FloatField()), 2))", msg)
  @test !occursin("Round(x, 2)", msg) && !occursin("PostgreSQL", msg)
  @test occursin("SET \"price\" = ", _uds_update("price", _UF("surname"); conn = _UDS_PG))
  @test occursin("update(\"grid\" => Round(Cast(x, FloatField())))", _uds_msg(_uds_refusal("grid", _UF("surname"); conn = _UDS_SL)))
  for conn in (_UDS_PG, _UDS_SL)
    @test _uds_refusal("price", Fn.Round(Fn.Cast(_UF("surname"), Models.FloatField()), 2); conn = conn) === nothing
    @test _uds_refusal("grid", Fn.Round(Fn.Cast(_UF("surname"), Models.FloatField())); conn = conn) === nothing
  end
end

@testset "update: the fix names the field's own places (#1279)" begin
  # What: a 1-place field names `Round(x, 1)` and "1 decimal place"; a 0-place field names `Round(x)`,
  # which the classifier passes as a whole number. Why: the suggested spelling must itself build.
  msg = _uds_msg(_uds_refusal("fee", _UF("fee") / 3; conn = _UDS_SL))
  @test occursin("Round(x, 1)", msg) && occursin("1 decimal place first", msg)
  msg = _uds_msg(_uds_refusal("grid", _UF("points"); conn = _UDS_SL))
  @test occursin("update(\"grid\" => Round(x))", msg)
  @test _uds_refusal("fee", Fn.Round(_UF("fee") / 3, 1); conn = _UDS_SL) === nothing
  @test _uds_refusal("grid", Fn.Round(_UF("points")); conn = _UDS_SL) === nothing
end

@testset "update: an expression with at most the field's places builds on both engines (#1279)" begin
  # What: these write the same value on both engines, so both build `SET "price" = …`. Why: the
  # refusal must leave the explicit spelling (`Round(…, 2)`) and the bounded operands writable —
  # the column itself, an integer column, a 1-place float literal (#1050), a narrower DecimalField.
  for (label, value) in (
      ("the column itself", _UF("price")),
      ("Round(F / 3, 2)", Fn.Round(_UF("price") / 3, 2)),
      ("Round(F * 1.005, 2)", Fn.Round(_UF("price") * 1.005, 2)),
      ("Round over a float column", Fn.Round(_UF("points"), 2)),
      ("an integer column", _UF("number")),
      ("Coalesce of the column and 0", Fn.Coalesce("price", 0)),
      ("a Case over a 1-place float literal", Fn.Case(Fn.When("number" => 1, then = 1.5), default = 0)),
      ("a 1-place DecimalField", _UF("fee")))
    @testset "$label" begin
      for conn in (_UDS_PG, _UDS_SL)
        @test occursin("SET \"price\" = ", _uds_update("price", value; conn = conn))
      end
    end
  end
end

@testset "update: a float or text column takes any expression (#1279)" begin
  # What: only a `DecimalField` has a scale to keep; `points` (a FloatField) and `surname` take the
  # expression on both engines. Why: the check must not reach columns where the engines agree.
  for conn in (_UDS_PG, _UDS_SL)
    @test occursin("SET \"points\" = ", _uds_update("points", _UF("points") * 1.005; conn = conn))
    @test occursin("SET \"points\" = ", _uds_update("points", _UF("price") / 3; conn = conn))
    @test occursin("SET \"surname\" = ", _uds_update("surname", _UF("price") / 3; conn = conn))
  end
end

@testset "update: a literal into a DecimalField is still the width check's, on every engine (#1279)" begin
  # What: a plain value with 3 places raises `InvalidValueError` from `DecimalValidator` (#761) on
  # both engines, not this refusal. Why: the new check is for expressions only.
  for conn in (_UDS_PG, _UDS_SL)
    err = _uds_refusal("price", 1.234; conn = conn)
    @test err isa InvalidValueError
    @test occursin("decimal_places is 2", _uds_msg(err))
  end
end
