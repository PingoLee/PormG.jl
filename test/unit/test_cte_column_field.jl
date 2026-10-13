"""
A computed CTE column binds a compared value as the type it means (#1034 phase 3, step 1).

The outer query treats each CTE column as a field, and that field formats the value a filter compares
with the column. For a computed column the CTE model used to infer the field from the function's name
alone: `Count` and `Sum` an integer whatever they sum, `F` arithmetic an integer or a float. So a
`Sum` of a duration bound a `Period` through the number formatter, which raised a raw `MethodError`,
and bound a bare `60` as a number against an interval; a comparison column bound `true` as `1` and let
`2` through. The field now comes from what the column's expression means (`_MeaningKinds`, the same on
every engine) whenever the inferred one names another family; a field that agrees is kept, with its
width, its char length and its foreign key.

Everything renders through mock connections — no live database, no fixture.

julia --project=test/integration test/unit/test_cte_column_field.jl
"""

using Test
using Dates
using Decimals
using PormG
using PormG.Models
using PormG.QueryBuilder: inspect_query
import PormG: InvalidValueError

# Dedicated config key + mock types: `runtests.jl` includes every unit file into one `Main`.
struct CcfMockSQLite <: PormG.PormGSQLite end
struct CcfMockPostgres <: PormG.PormGPostgres end
const _CCF_SL = CcfMockSQLite()
const _CCF_PG = CcfMockPostgres()
PormG.backend_sqlite_version(::CcfMockSQLite) = 3045000

PormG.config["ccf_mock"] = PormG.Configuration.Settings(
  connections = _CCF_SL, change_data = true, db_def_folder = "ccf_mock",
)

module CcfModels
import PormG
import PormG.Models

Ccf_driver = Models.Model("ccf_driver",
  driverid = Models.IDField(),
  surname  = Models.CharField(),
)
Ccf_result = Models.Model("ccf_result",
  resultid       = Models.IDField(),
  raceid         = Models.IntegerField(),
  driverid       = Models.ForeignKey(Ccf_driver, pk_field = "driverid", on_delete = "RESTRICT"),
  grid           = Models.IntegerField(),
  positionorder  = Models.IntegerField(),
  points         = Models.FloatField(),
  fastestlaptime = Models.DurationField(null = true),
)
Ccf_constructor_result = Models.Model("ccf_constructor_result",
  constructorresultsid = Models.IDField(),
  raceid               = Models.IntegerField(),
  points               = Models.DecimalField(max_digits = 10, decimal_places = 2),
)

PormG.Models.set_models(@__MODULE__, "ccf_mock")
end

const CCF = CcfModels
const _CCF_Fn = PormG.Functions
const _CCF_F = PormG.QueryBuilder.F
const _CCF_ENGINES = (_CCF_PG, _CCF_SL)

# One query per race over a CTE of per-race aggregates of `Ccf_result`, filtered by `pair`.
function _ccf_query(pair = nothing)
  body = CCF.Ccf_result.objects
  body.values("raceid", "driverid",
              "fast"     => _CCF_Fn.Sum("fastestlaptime"),
              "pts"      => _CCF_Fn.Sum("points"),
              "avg_grid" => _CCF_Fn.Avg("grid"),
              "ahead"    => _CCF_F("grid") < _CCF_F("positionorder"),
              "starters" => _CCF_Fn.Count("resultid"),
              "best"     => _CCF_Fn.Max("points"))
  q = CCF.Ccf_result.objects
  q.with("r" => body, join_field = "raceid" => "raceid")
  pair === nothing || q.filter(pair)
  q.values("resultid")
  return q
end
# The field the CTE model gives each column, read off the built instruction.
function _ccf_fields(q; conn)
  fields = Ref{Any}(nothing)
  PormG.QueryBuilder.query(q; show_query = :sql, connection = conn,
                           built = instr -> (fields[] = instr.object.ctes["r"]["model"].fields))
  return fields[]
end
_ccf_params(pair; conn) = inspect_query(_ccf_query(pair); connection = conn)[:parameters]
_ccf_refusal(pair; conn) = try _ccf_params(pair; conn = conn); nothing catch e; e end
_ccf_msg(e) = replace(sprint(showerror, e), r"\e\[[0-9;]*m" => "")

# ─────────────────────────────────────────────────────────────────────────────
# CTE column field: a computed column is typed by what it means, the same on every engine
# `Sum` of a duration is a `DurationField`, `Sum` of a float and `Avg` of integers a `FloatField`, a
# comparison a `BooleanField` — before, the first two were `IntegerField`s and the comparison a
# `FloatField`. A field that already agrees stays: `Count` an integer, `Max` of a float its operand's
# own `FloatField`, a plain path its column (a foreign key keeps its target). The body's SQL does not
# change — PostgreSQL still renders `SUM("Tb"."fastestlaptime") as "fast"`; only the outer query's
# field for the column does, read here off the built instruction.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1034: a computed CTE column's field is the type it means" begin
  for conn in _CCF_ENGINES
    fields = _ccf_fields(_ccf_query(); conn = conn)
    @test fields["fast"] isa Models.sDurationField
    @test fields["pts"] isa Models.sFloatField
    @test fields["avg_grid"] isa Models.sFloatField
    @test fields["ahead"] isa Models.sBooleanField
    # Kept: the inferred field agrees with the meaning.
    @test fields["starters"] isa Models.sIntegerField
    @test fields["best"] isa Models.sFloatField
    @test fields["driverid"] isa Models.sForeignKey
  end
  # A `Sum` of a `DecimalField` is a decimal, not an integer.
  for conn in _CCF_ENGINES
    body = CCF.Ccf_constructor_result.objects
    body.values("raceid", "pts" => _CCF_Fn.Sum("points"))
    q = CCF.Ccf_constructor_result.objects
    q.with("r" => body, join_field = "raceid" => "raceid")
    q.values("constructorresultsid")
    @test _ccf_fields(q; conn = conn)["pts"] isa Models.sDecimalField
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# CTE column filter: a value compared with a computed column is bound as that column's type
# Expected SQL, PostgreSQL: `WHERE "R1_1"."fast" > $1` with `["00:01:00"]` — a duration, where the
# number formatter raised `MethodError` on a `Period` — and `WHERE "R1_1"."ahead" = $1` with `[true]`,
# where it bound `1`. A value that is not one of the column's type is refused as it is on a model
# column of that type: `60` against the duration (it bound `60`), `2` against the boolean (it bound `2`).
# Number columns bind as before: every number field formats through the same formatter.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1034: a filter on a computed CTE column binds the column's type" begin
  for conn in _CCF_ENGINES
    @test _ccf_params("r__fast__@gt" => Minute(1); conn = conn) == Any["00:01:00"]
    @test _ccf_params("r__ahead" => true; conn = conn) == Any[true]
    @test _ccf_params("r__ahead" => 1; conn = conn) == Any[true]
    # Refused by the column type's own validator, which names it — not by some other check.
    duration = _ccf_refusal("r__fast__@gt" => 60; conn = conn)
    @test duration isa InvalidValueError
    @test occursin("`r__fast` (INTERVAL)", _ccf_msg(duration))
    boolean = _ccf_refusal("r__ahead" => 2; conn = conn)
    @test boolean isa InvalidValueError
    @test occursin("`r__ahead` (BOOLEAN)", _ccf_msg(boolean))
    # Unchanged: a float and a computed average bind as numbers.
    @test _ccf_params("r__pts__@gt" => 10.5; conn = conn) == Any["10.5"]
    @test _ccf_params("r__avg_grid__@gt" => 1.5; conn = conn) == Any["1.5"]
    @test _ccf_params("r__starters__@gte" => 20; conn = conn) == Any[20]
  end
  sql = inspect_query(_ccf_query("r__fast__@gt" => Minute(1)); connection = _CCF_PG)[:sql_text]
  @test occursin("\"R1_1\".\"fast\" > \$1", sql)
end

# ─────────────────────────────────────────────────────────────────────────────
# CTE column functions: a function over a computed column treats it as a column of its type
# The outer query types `Sum`, `Max` or `Extract` over `CTE("r", col)` by the column's field, so the
# rules for that type apply. Over a comparison column, `Sum`/`Avg` are refused as over a `BooleanField`
# (#953) — they built before — and `Max` renders `BOOL_OR("R1_1"."ahead")` on PostgreSQL, which has no
# `max(boolean)`; it rendered `MAX(…)`. Over a summed duration, `Extract(…, "EPOCH")` builds on
# PostgreSQL and is a `BackendCapabilityError` on SQLite, as over a `DurationField`; it was refused on
# both as a non-temporal column. A `When` on the comparison column binds `true`, where it bound `1`.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1034: a function over a computed CTE column treats it as a column of its type" begin
  over(expr) = (q = _ccf_query(); q.values("x" => expr); q)
  ahead, fast = PormG.CTE("r", "ahead"), PormG.CTE("r", "fast")
  for conn in _CCF_ENGINES, f in (_CCF_Fn.Sum, _CCF_Fn.Avg)
    err = try inspect_query(over(f(ahead)); connection = conn); nothing catch e; e end
    @test err isa PormG.QueryBuildError
    @test occursin("over a boolean is not supported", _ccf_msg(err))
  end
  @test occursin("BOOL_OR(\"R1_1\".\"ahead\")", inspect_query(over(_CCF_Fn.Max(ahead)); connection = _CCF_PG)[:sql_text])
  @test occursin("MAX(\"R1_1\".\"ahead\")", inspect_query(over(_CCF_Fn.Max(ahead)); connection = _CCF_SL)[:sql_text])
  @test occursin("EXTRACT(EPOCH FROM \"R1_1\".\"fast\")",
                 inspect_query(over(_CCF_Fn.Extract(fast, "EPOCH")); connection = _CCF_PG)[:sql_text])
  @test_throws PormG.BackendCapabilityError inspect_query(over(_CCF_Fn.Extract(fast, "EPOCH")); connection = _CCF_SL)
  # A `When` on the comparison column binds its value as a boolean, as on a `BooleanField` (it bound `1`).
  for conn in _CCF_ENGINES
    flagged = over(_CCF_Fn.Case([_CCF_Fn.When(ahead => true, then = 1)], default = 0))
    @test inspect_query(flagged; connection = conn)[:parameters] == Any[true, 1, 0]
  end
end
