"""
A value that is not a boolean, written into or filtered on a `BooleanField`, is refused with a typed
`InvalidValueError` of kind `:type` that names the field (#1290).

`format_bool_sql` had methods for `Bool`, `Integer` and `missing`/`nothing` only, and
`_validate_field_value` had a type arm for every field kind but a boolean. So `3.5`, `"true"`,
`Value(true)` or a `Date` reached the formatter unchecked and raised a raw `MethodError`
(`format_bool_sql(::Float64)`): outside the `PormGError` taxonomy, naming no field. That happened from
`create`, `update`, `get_or_create`, `update_or_create`, `validate_value` and `filter`, on both
engines, and the bulk writers reported "can't be formatted (MethodError)" with kind `:other`. No path
wrote anything.

Two halves, as for every other field type. The validator refuses a non-boolean before the formatter,
with the `expected …, got <type>` text the other kinds use. `format_bool_sql` gains the typed fallback
every other formatter has, so the filter path and the bulk writers' depuration pass locate it too.
An integer other than 0 or 1 keeps its `:range` refusal (#949).

Hermetic: offline keys (`register_offline`) and a mock PostgreSQL pool for `bulk_copy`.

julia --project=test/integration test/unit/test_boolean_field_value.jl
"""

using Test
using Dates
using DataFrames
using PormG
import PormG: InvalidValueError
# The SQLite bulk writers size their chunks by the SQLite version even under `show_query`; the offline
# key states it (#1452), so no library is asked.
isdefined(Main, :SQLite) || include(joinpath(@__DIR__, "..", "load_drivers.jl"))

PormG.Configuration.register_offline("bfv1290_pg"; adapter = :postgres)
PormG.Configuration.register_offline("bfv1290_sl"; adapter = :sqlite, server_version = 3_045_000)

# The F1 results table, with its `finished` flag.
const _BFV_MODEL_EXPR = quote
  import PormG, PormG.Models
  Result = Models.Model("result",
    resultid     = Models.IDField(),
    positiontext = Models.CharField(null = true, unique = true),
    finished     = Models.BooleanField(null = true))
end
module BfvPg end
module BfvSl end
Core.eval(BfvPg, _BFV_MODEL_EXPR); Core.eval(BfvPg, :(PormG.Models.set_models(@__MODULE__, "bfv1290_pg")))
Core.eval(BfvSl, _BFV_MODEL_EXPR); Core.eval(BfvSl, :(PormG.Models.set_models(@__MODULE__, "bfv1290_sl")))
const _BFV_ENGINES = (("PostgreSQL", Base.invokelatest(getfield, BfvPg, :Result)),
                      ("SQLite", Base.invokelatest(getfield, BfvSl, :Result)))

# Each value's own text is one the refusal text never contains, so its absence shows the value is not
# printed (#971): `true` would be indistinguishable from the "true, false, 0 or 1" the reason states.
const _BFV_BAD = (("Float64", () -> 3.25, "3.25"),
                  ("String", () -> "yes", "yes"),
                  ("Value", () -> PormG.Functions.Value("maybe"), "maybe"),
                  ("Date", () -> Date(1991, 10, 13), "1991"))

_bfv_refusal(f) = try f(); nothing catch e; e end
_bfv_msg(e) = replace(sprint(showerror, e), r"\e\[[0-9;]*m" => "")
# The #1290 refusal: typed, kind `:type`, the field named, the accepted values stated, the value not
# printed. Before the fix `err` was a `MethodError`, so the first assertion fails on the old tree.
function _bfv_check(err, value_text; op = nothing)
  msg = err === nothing ? "" : _bfv_msg(err)
  @test err isa InvalidValueError
  err isa InvalidValueError && @test err.kind === :type
  @test occursin("field `finished`", msg)
  @test occursin("true, false, 0 or 1", msg)
  @test !occursin(value_text, msg)
  op === nothing || @test occursin("Error in $(op)", msg)
end

@testset "create / validate_value: a non-boolean into a BooleanField is a typed refusal (#1290)" begin
  # What: `create("finished" => v; show_query = :params)` and `validate_value(Result, "finished", v)`
  # raise `InvalidValueError(:type)` naming the field, for a float, a string, a `Value(x)` and a date,
  # on both engines, before any SQL is built. Why: each one raised a raw `MethodError` from
  # `format_bool_sql`, which `catch PormGError` misses and which named no field.
  for (engine, R) in _BFV_ENGINES, (label, value, text) in _BFV_BAD
    @testset "$engine $label" begin
      _bfv_check(_bfv_refusal(() -> R.objects.create("finished" => value(); show_query = :params)), text; op = "insert")
      _bfv_check(_bfv_refusal(() -> PormG.validate_value(R, "finished", value())), text; op = "validate_value")
    end
  end
end

@testset "update / get_or_create / update_or_create: the same refusal (#1290)" begin
  # What: `filter(…).update("finished" => v)`, the INSERT a `get_or_create` miss builds from its
  # defaults, and `update_or_create`'s defaults all refuse a non-boolean the same way. Why: each
  # reaches `_validate_field_value` and then the formatter, where the `MethodError` came from.
  for (engine, R) in _BFV_ENGINES, (label, value, text) in _BFV_BAD
    @testset "$engine $label" begin
      q = R.objects
      q.filter("resultid" => 1)
      _bfv_check(_bfv_refusal(() -> q.update("finished" => value(); show_query = :sql)), text; op = "update")
      _bfv_check(_bfv_refusal(() -> R.objects.get_or_create("positiontext" => "1";
                   defaults = Dict("finished" => value()), show_query = :params)), text; op = "insert")
      _bfv_check(_bfv_refusal(() -> R.objects.update_or_create("positiontext" => "1";
                   defaults = Dict("finished" => value()), show_query = :params)), text; op = "insert")
    end
  end
end

@testset "filter: a non-boolean on a BooleanField is a located refusal (#1290)" begin
  # What: `filter("finished" => v)` raises `InvalidValueError(:type)` naming the field and its type,
  # `Error in filter, field `finished` (BOOLEAN): A boolean value must be true, false, 0 or 1. Got a
  # Float64.` Why: the filter path formats the value with `format_bool_sql` and locates only an
  # `InvalidValueError`; the raw `MethodError` passed its guard untouched. `Value(x)` is left out: a
  # function on the right of a filter is an expression there, not a value. The type the message names
  # is the one the formatter sees, after the filter's own normalization (a `Date` arrives as text).
  for (engine, R) in _BFV_ENGINES, (label, value, text) in _BFV_BAD
    label == "Value" && continue
    @testset "$engine $label" begin
      err = _bfv_refusal(() -> R.objects.filter("finished" => value()).list(show_query = :sql))
      _bfv_check(err, text; op = "filter")
      @test occursin("field `finished` (BOOLEAN): A boolean value must be true, false, 0 or 1. Got a ", _bfv_msg(err))
    end
  end
end

@testset "bulk_insert / bulk_update: a non-boolean cell is the same refusal, with its row (#1290)" begin
  # What: a DataFrame cell holding a non-boolean raises `InvalidValueError(:type)` naming row 2 and the
  # field. Why: the depuration pass runs the bare formatter first, and reported "can't be formatted
  # (MethodError)" with kind `:other`; the formatter's typed refusal now carries its reason and kind.
  for (engine, R) in _BFV_ENGINES, (label, value, text) in _BFV_BAD
    @testset "$engine $label" begin
      df = DataFrame(:resultid => [1, 2], :finished => Any[true, value()])
      for (op, run) in (("bulk_insert", () -> PormG.bulk_insert(R.objects, df; show_query = :params)),
                        ("bulk_update", () -> PormG.bulk_update(R.objects, df; columns = ["finished"], match_on = ["resultid"], show_query = :params)))
        err = _bfv_refusal(run)
        _bfv_check(err, text; op = op)
        @test occursin("row 2", _bfv_msg(err))
      end
    end
  end
end

# bulk_copy is PostgreSQL-only and returns before its row loop under `show_query`, so it runs on a
# mock pool inside a transaction context, as `test_bulk_copy_cell_errors.jl` does.
struct BfvMockPg <: PormG.PormGPostgres end
PormG.config["bfv1290_copy"] = PormG.Configuration.Settings(connections = BfvMockPg(), change_data = true)
const _BFV_COPY = PormG.Models.Model("bfv1290_copy", id = PormG.Models.IDField(), finished = PormG.Models.BooleanField(null = true))
_BFV_COPY.connect_key = "bfv1290_copy"

@testset "bulk_copy: a non-boolean cell is the same refusal, with its row (#1290)" begin
  # What: `bulk_copy` validates each cell before it formats it, so a float cell raises the refusal
  # naming row 2. Why: the three bulk writers refuse it alike.
  err = @test_logs (:error, "Error in bulk_copy") match_mode = :any try
    PormG.Configuration.with_tx_context(PormG.config["bfv1290_copy"].connections, :mock_tx_conn) do
      PormG.bulk_copy(_BFV_COPY.objects, DataFrame(finished = Any[true, 3.25]))
    end
    nothing
  catch e
    e
  end
  _bfv_check(err, "3.25"; op = "bulk_copy")
  @test occursin("row 2", _bfv_msg(err))
end

@testset "a boolean, 0, 1 and nothing still bind; another integer keeps its :range refusal (#1290)" begin
  # What: `create("finished" => v; show_query = :params)` binds `true`, `false`, `false`, `true`,
  # `missing` for `true`, `false`, `0`, `1`, `nothing`, and `2` is still `InvalidValueError(:range)`
  # (#949). The filter binds the same. Why: the new arm accepts exactly what `format_bool_sql` takes,
  # so no write or filter that worked before #1290 raises now.
  for (engine, R) in _BFV_ENGINES
    @testset "$engine" begin
      for (v, bound) in ((true, true), (false, false), (0, false), (1, true), (nothing, missing))
        @test isequal(R.objects.create("finished" => v; show_query = :params), Any[bound])
        @test isequal(PormG.validate_value(R, "finished", v), bound)
      end
      @test R.objects.filter("finished" => 0).list(show_query = :dict)[:parameters] == [false]
      err = _bfv_refusal(() -> R.objects.create("finished" => 2; show_query = :params))
      @test err isa InvalidValueError
      err isa InvalidValueError && @test err.kind === :range
    end
  end
end
