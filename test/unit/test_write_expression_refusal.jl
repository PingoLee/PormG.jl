"""
An SQL expression (an `F` expression, a SQL function) written by any writer but `update` is refused
with a typed `InvalidValueError` that names the field and says `update` writes expressions (#1283).

`update` writes an expression into its SET clause as SQL. Every other writer binds values. Before
#1283 an expression reached the field's formatter there: a numeric, boolean or foreign-key field
raised a raw `MethodError` (`format_number_sql(::FExpression)`), outside the `PormGError` taxonomy
and naming no field, from `create`, `get_or_create`, `update_or_create` and `validate_value`; a text,
date or JSON field raised that formatter's own refusal; and the bulk writers reported "can't be
formatted (MethodError)". Measured on both engines with the same outcome. No path wrote anything.

Now each one raises one refusal, kind `:type`, from `_validate_field_value` (step 4), which the bulk
writers' depuration pass repeats as it does the collection refusal (#716). Django refuses an `F()`
the same way: "F() expressions can only be used to update, not to insert". A `get_or_create` hit
reads the row through a filter, which takes an expression; only the INSERT a miss builds refuses it.

Hermetic: offline keys (`register_offline`) and a mock PostgreSQL pool for `bulk_copy`.

julia --project=test/integration test/unit/test_write_expression_refusal.jl
"""

using Test
using DataFrames
using PormG
import PormG: InvalidValueError
# The SQLite bulk writers need the driver extension even under `show_query` (they reserve ids).
isdefined(Main, :SQLite) || include(joinpath(@__DIR__, "..", "load_drivers.jl"))

for (key, adapter) in (("wer1283_pg", :postgres), ("wer1283_sl", :sqlite))
  PormG.Configuration.register_offline(key; adapter = adapter)
end

# The F1 results table, one column of each formatter the refusal used to reach.
const _WER_MODEL_EXPR = quote
  import PormG, PormG.Models
  Constructor = Models.Model("constructor", constructorid = Models.IDField(), name = Models.CharField(null = true))
  Result = Models.Model("result",
    resultid     = Models.IDField(),
    grid         = Models.IntegerField(null = true),
    points       = Models.FloatField(null = true),
    milliseconds = Models.BigIntegerField(null = true),
    fee          = Models.DecimalField(max_digits = 10, decimal_places = 2, null = true),
    positiontext = Models.CharField(null = true, unique = true),
    racedate     = Models.DateField(null = true),
    payload      = Models.JSONField(null = true),
    finished     = Models.BooleanField(null = true),
    constructorid = Models.ForeignKey(Constructor, on_delete = "CASCADE", null = true))
end
module WerPg end
module WerSl end
Core.eval(WerPg, _WER_MODEL_EXPR); Core.eval(WerPg, :(PormG.Models.set_models(@__MODULE__, "wer1283_pg")))
Core.eval(WerSl, _WER_MODEL_EXPR); Core.eval(WerSl, :(PormG.Models.set_models(@__MODULE__, "wer1283_sl")))
const _WER_ENGINES = (("PostgreSQL", Base.invokelatest(getfield, WerPg, :Result)),
                      ("SQLite", Base.invokelatest(getfield, WerSl, :Result)))

# Not `F`: `runtests.jl` includes every unit file into one `Main`, where `F` is already imported.
const _WF = PormG.QueryBuilder.F
const _WFn = PormG.Functions
const _WER_EXPRESSIONS = (("F(\"points\") + 1", () -> _WF("points") + 1),
                          ("F(\"grid\")", () -> _WF("grid")),
                          ("Abs(\"grid\")", () -> _WFn.Abs("grid")))

_wer_refusal(f) = try f(); nothing catch e; e end
_wer_msg(e) = replace(sprint(showerror, e), r"\e\[[0-9;]*m" => "")
# The #1283 refusal for `field` under `op`: typed, kind `:type`, the field named, the reason given,
# and the expression itself never printed (its operands are `points`/`grid`, absent from the text
# for every other field).
function _wer_check(err, op, field)
  msg = err === nothing ? "" : _wer_msg(err)
  @test err isa InvalidValueError
  err isa InvalidValueError && @test err.kind === :type
  @test occursin("field `$(field)`", msg)
  @test occursin("is not a value: `update` writes one into the column as SQL, and $(op) takes values only", msg)
  @test occursin("filter(…).update(\"$(field)\" => expression)", msg)
  field in ("grid", "points") || @test !occursin("points", msg) && !occursin("grid", msg)
end

@testset "create: an expression into any field is a typed refusal (#1283)" begin
  # What: `create(field => expr; show_query = :params)` raises `InvalidValueError(:type)` before any
  # SQL is built, for a numeric, boolean, foreign-key, decimal, text, date and JSON field, on both
  # engines. Why: a numeric field raised a raw `MethodError` from `format_number_sql`, which
  # `catch PormGError` misses and which named no field; the text field's refusal named the field but
  # not the reason, that `update` is the writer that takes an expression.
  for (engine, R) in _WER_ENGINES, (label, expr) in _WER_EXPRESSIONS,
      field in ("grid", "points", "milliseconds", "fee", "finished", "constructorid", "positiontext", "racedate", "payload")
    @testset "$engine $field <= $label" begin
      _wer_check(_wer_refusal(() -> R.objects.create(field => expr(); show_query = :params)), "insert", field)
    end
  end
end

@testset "get_or_create / update_or_create: the INSERT refuses an expression (#1283)" begin
  # What: the INSERT a `get_or_create` miss builds and the upsert `update_or_create` builds both go
  # through `create`'s row preparation, so an expression in a lookup, a default or a set value is
  # the same refusal. Why: the issue measured only `create`; these raised the same raw `MethodError`.
  for (engine, R) in _WER_ENGINES, (label, expr) in _WER_EXPRESSIONS
    @testset "$engine $label" begin
      _wer_check(_wer_refusal(() -> R.objects.get_or_create("positiontext" => "1", "grid" => expr(); show_query = :params)),
                 "insert", "grid")
      _wer_check(_wer_refusal(() -> R.objects.get_or_create("positiontext" => expr(); show_query = :params)),
                 "insert", "positiontext")
      _wer_check(_wer_refusal(() -> R.objects.get_or_create("positiontext" => "1"; defaults = Dict("grid" => expr()), show_query = :params)),
                 "insert", "grid")
      _wer_check(_wer_refusal(() -> R.objects.update_or_create("positiontext" => "1"; defaults = Dict("grid" => expr()), show_query = :params)),
                 "insert", "grid")
    end
  end
end

@testset "get_or_create: the lookup a hit reads is a filter, which takes an expression (#1283)" begin
  # What: the lookup `get_or_create` reads first (`_get_or_create_lookup`) builds
  # `WHERE "grid" = ("points" + 1)` with the refusal in place. It does not run the hit itself, which
  # needs a database; it guards against the refusal reaching the filter. Why: only the INSERT a miss
  # builds writes values, as in Django, whose `get_or_create` filters by an `F()` too.
  for (engine, R) in _WER_ENGINES
    q = PormG.QueryBuilder._get_or_create_lookup(R, ["grid"], Dict{String,Any}("grid" => _WF("points") + 1))
    sql = q.list(show_query = :sql)
    @test occursin("\"grid\" = (\"Tb\".\"points\" + ", sql)
  end
end

@testset "validate_value: refuses an expression as create does (#1283)" begin
  # What: `validate_value(Result, field, expr)` raises the same refusal, under its own operation
  # name. Why: it mirrors `create` (#1239), so it raised the same raw `MethodError` for a numeric
  # field; its docstring cited this issue.
  for (engine, R) in _WER_ENGINES, (label, expr) in _WER_EXPRESSIONS, field in ("grid", "positiontext", "payload")
    @testset "$engine $field <= $label" begin
      _wer_check(_wer_refusal(() -> PormG.validate_value(R, field, expr())), "validate_value", field)
    end
  end
end

@testset "bulk_insert / bulk_update: an expression cell is the same refusal, with its row (#1283)" begin
  # What: a DataFrame cell holding an expression raises `InvalidValueError(:type)` naming row 2 and
  # the field. Why: the depuration pass ran the bare formatter first and reported "can't be
  # formatted (MethodError)" (kind `:other`), which said neither why nor what to write instead.
  for (engine, R) in _WER_ENGINES, field in ("grid", "positiontext", "payload")
    @testset "$engine $field" begin
      df = DataFrame(:resultid => [1, 2], Symbol(field) => Any[nothing, _WF("points") + 1])
      for (op, run) in (("bulk_insert", () -> PormG.bulk_insert(R.objects, df; show_query = :params)),
                        ("bulk_update", () -> PormG.bulk_update(R.objects, df; columns = [field], match_on = ["resultid"], show_query = :params)))
        err = _wer_refusal(run)
        _wer_check(err, op, field)
        @test occursin("row 2", _wer_msg(err))
      end
    end
  end
end

# bulk_copy is PostgreSQL-only and returns before its row loop under `show_query`, so it runs on a
# mock pool inside a transaction context, as `test_bulk_copy_cell_errors.jl` does.
struct WerMockPg <: PormG.PormGPostgres end
PormG.config["wer1283_copy"] = PormG.Configuration.Settings(connections = WerMockPg(), change_data = true)
const _WER_COPY = PormG.Models.Model("wer1283_copy", id = PormG.Models.IDField(), grid = PormG.Models.IntegerField(null = true))
_WER_COPY.connect_key = "wer1283_copy"

@testset "bulk_copy: an expression cell is the same refusal, with its row (#1283)" begin
  # What: `bulk_copy` validates each cell before it formats it, so an expression cell raises the
  # refusal naming row 2. Why: the three bulk writers refuse it alike.
  err = @test_logs (:error, "Error in bulk_copy") match_mode = :any try
    PormG.Configuration.with_tx_context(PormG.config["wer1283_copy"].connections, :mock_tx_conn) do
      PormG.bulk_copy(_WER_COPY.objects, DataFrame(grid = Any[1, _WF("grid") + 1]))
    end
    nothing
  catch e
    e
  end
  _wer_check(err, "bulk_copy", "grid")
  @test occursin("row 2", _wer_msg(err))
end

@testset "update: an expression is still written as SQL (#1283)" begin
  # What: `update("grid" => F("points") + 1)` builds `SET "grid" = ("Tb"."points" + $1)`, and a
  # literal there is still checked. Why: the refusal is for the writers that bind values only.
  for (engine, R) in _WER_ENGINES
    q = R.objects
    q.filter("resultid" => 1)
    @test occursin("SET \"grid\" = ", q.update("grid" => _WF("points") + 1; show_query = :sql))
    q = R.objects
    q.filter("resultid" => 1)
    @test _wer_refusal(() -> q.update("grid" => "x"; show_query = :sql)) isa InvalidValueError
  end
end
