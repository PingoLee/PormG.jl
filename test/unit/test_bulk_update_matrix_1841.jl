# ============================================================
# test/unit/test_bulk_update_matrix_1841.jl
#
# CONTRACT being tested:
#   `bulk_update` renders, for each input the bulk_update unit tests use, the statement and parameters it rendered
#   before #1841, or raises the error it raised, on PostgreSQL, SQLite and MySQL. The one change #1841 makes: an input
#   that leaves the SET list empty (every field the table brings is a key, from `match_on=`, the primary key it falls
#   back to, or `filters=`) is refused with a `QueryBuildError` before any SQL, where it rendered `SET` with nothing
#   after it, a statement every engine rejected as a syntax error once it was sent.
#
#   The expected values live in `fixtures/bulk_update_matrix_expected.jl`, recorded from the code before #1841
#   (`PORMG_BUMX_RECORD=1`), so the change shows as a diff to that file: only the cells named `empty SET …` move.
#
# Hermetic: mock connections and `show_query = :dict`, no database.
#
# Run:    julia --project=test/integration test/unit/test_bulk_update_matrix_1841.jl
# Record: PORMG_BUMX_RECORD=1 julia --project=test/integration test/unit/test_bulk_update_matrix_1841.jl
# ============================================================

using Test
isdefined(Main, :SQLite) || include(joinpath(@__DIR__, "..", "load_drivers.jl"))
using PormG
using PormG.Models: Model, CharField, IDField, IntegerField, DecimalField, DateTimeField, BigIntegerField
using PormG.QueryBuilder: bulk_update

struct BumxMockPg <: PormG.PormGPostgres end
struct BumxMockSl <: PormG.PormGSQLite end
struct BumxMockMy <: PormG.PormGMySQL end
PormG.backend_sqlite_version(::BumxMockSl) = 3045000

# One copy of each model per engine, each on its own key.
function _bumx_models(key::String)
  metric = Model("metrics",
    id           = IDField(),
    city_id      = BigIntegerField(null = true),
    weight       = IntegerField(null = true),
    score        = DecimalField(max_digits = 10, decimal_places = 2, null = true),
    denominator  = IntegerField(default = 0),
    result_value = DecimalField(max_digits = 10, decimal_places = 2, default = "0"),
  )
  metric_ts = Model("metrics_ts",
    id         = IDField(),
    weight     = IntegerField(null = true),
    updated_at = DateTimeField(auto_now = true),
  )
  race = Model("race",
    raceid = IDField(),
    year   = IntegerField(),
    round  = IntegerField(),
    name   = CharField(max_length = 80),
  )
  status = Model("status", statusid = IDField())
  for m in (metric, metric_ts, race, status)
    m.connect_key = key
  end
  return (metric = metric, metric_ts = metric_ts, race = race, status = status)
end
const _BUMX_ENGINES = (:postgres => BumxMockPg(), :sqlite => BumxMockSl(), :mysql => BumxMockMy())
const _BUMX_MODELS = Dict{Symbol, Any}()
for (eng, conn) in _BUMX_ENGINES
  key = "bumx_$(eng)"
  PormG.config[key] = PormG.Configuration.Settings(connections = conn, change_data = true, db_def_folder = key)
  _BUMX_MODELS[eng] = _bumx_models(key)
end

const _BUMX_METRIC_ROW = (id = [1001], city_id = [2009], weight = [1], score = ["0.75"], denominator = [57],
                          result_value = ["18.6"])

# Each cell: a name and the call, given the engine's models. The inputs of the bulk_update unit tests
# (column scope, the PostgreSQL unnest source, the MySQL render, the row counts, the handler scope), then the shapes
# that leave the SET list empty.
const _BUMX_CELLS = Pair{String, Function}[
  "columns weight,score; match_on id; filters city_id" =>
    m -> bulk_update(m.metric.objects, _BUMX_METRIC_ROW; columns = ["weight", "score"], match_on = ["id"], filters = ["city_id" => 2009], show_query = :dict),
  "columns weight,result_value; match_on id; filters city_id" =>
    m -> bulk_update(m.metric.objects, _BUMX_METRIC_ROW; columns = ["weight", "result_value"], match_on = ["id"], filters = ["city_id" => 2009], show_query = :dict),
  "auto_now model; columns weight; match_on id" =>
    m -> bulk_update(m.metric_ts.objects, (id = [7], weight = [3]); columns = ["weight"], match_on = ["id"], show_query = :dict),
  "columns omitted; match_on id" =>
    m -> bulk_update(m.metric.objects, (id = [1001], weight = [1], score = ["0.75"]); match_on = ["id"], show_query = :dict),
  "mapped columns new_w=>weight, record_id=>id; match_on id" =>
    m -> bulk_update(m.metric.objects, (record_id = [1001], new_w = [5]); columns = ["new_w" => "weight", "record_id" => "id"], match_on = ["id"], show_query = :dict),
  "columns weight; match_on id; filters city_id" =>
    m -> bulk_update(m.metric.objects, _BUMX_METRIC_ROW; columns = ["weight"], match_on = ["id"], filters = ["city_id" => 2009], show_query = :dict),
  "bare filters city_id with match_on (refused)" =>
    m -> bulk_update(m.metric.objects, _BUMX_METRIC_ROW; columns = ["weight"], match_on = ["id"], filters = ["city_id"], show_query = :dict),
  "bare filters id, no match_on (migration refusal)" =>
    m -> bulk_update(m.metric.objects, _BUMX_METRIC_ROW; columns = ["weight"], filters = ["id"], show_query = :dict),
  "filters record_id=>id pair (refused)" =>
    m -> bulk_update(m.metric.objects, (record_id = [1001], weight = [1]); columns = ["weight"], filters = ["record_id" => "id"], show_query = :dict),
  "primary-key fallback; columns weight" =>
    m -> bulk_update(m.metric.objects, _BUMX_METRIC_ROW; columns = ["weight"], show_query = :dict),
  "primary-key fallback; columns weight; filters city_id" =>
    m -> bulk_update(m.metric.objects, _BUMX_METRIC_ROW; columns = ["weight"], filters = ["city_id" => 2009], show_query = :dict),
  "composite match_on id,city_id" =>
    m -> bulk_update(m.metric.objects, _BUMX_METRIC_ROW; columns = ["weight"], match_on = ["id", "city_id"], show_query = :dict),
  "columns weight, ID=>id (case); match_on id" =>
    m -> bulk_update(m.metric.objects, (ID = [1001], weight = [1]); columns = ["weight", "ID" => "id"], match_on = ["id"], show_query = :dict),
  "repeated mapping c1=>weight twice" =>
    m -> bulk_update(m.metric.objects, (id = [1001], c1 = [2]); columns = ["c1" => "weight", "c1" => "weight"], match_on = ["id"], show_query = :dict),
  "repeated column weight twice" =>
    m -> bulk_update(m.metric.objects, (id = [1001], weight = [2]); columns = ["weight", "weight"], match_on = ["id"], show_query = :dict),
  "field mapped from two columns weight, c2=>weight (refused)" =>
    m -> bulk_update(m.metric.objects, (id = [1001], weight = [2], c2 = [3]); columns = ["weight", "c2" => "weight"], match_on = ["id"], show_query = :dict),
  "filters lookup city_id__@in" =>
    m -> bulk_update(m.metric.objects, _BUMX_METRIC_ROW; columns = ["weight"], match_on = ["id"], filters = ["city_id__@in" => [2009, 2010]], show_query = :dict),
  "unknown column nosuch (refused)" =>
    m -> bulk_update(m.metric.objects, (id = [1001], nosuch = [1]); columns = ["nosuch"], match_on = ["id"], show_query = :dict),
  "primary key set: columns id; match_on city_id (refused)" =>
    m -> bulk_update(m.metric.objects, (id = [1001], city_id = [2009]); columns = ["id"], match_on = ["city_id"], show_query = :dict),
  "two rows; columns year,round; match_on raceid" =>
    m -> bulk_update(m.race.objects, (raceid = [1, 2], year = [2008, 2009], round = [3, 4]); columns = ["year", "round"], match_on = ["raceid"], show_query = :dict),
  "lookup key keeps year in SET: columns year; match_on raceid; filters year__@in" =>
    m -> bulk_update(m.race.objects, (raceid = [1], year = [2008]); columns = ["year"], match_on = ["raceid"], filters = ["year__@in" => [2008]], show_query = :dict),
  "empty table" =>
    m -> bulk_update(m.race.objects, (raceid = Int[], year = Int[]); columns = ["year"], match_on = ["raceid"], show_query = :dict),
  "auto_now keeps SET: columns weight; match_on weight" =>
    m -> bulk_update(m.metric_ts.objects, (weight = [3],); columns = ["weight"], match_on = ["weight"], show_query = :dict),
  # The shapes that leave the SET list empty (#1841).
  "empty SET: filters= keys alone (primary-key fallback)" =>
    m -> bulk_update(m.race.objects, (raceid = [1], year = [2008]); columns = ["year"], filters = ["year" => 2008], show_query = :dict),
  "empty SET: match_on keys alone (the primary key)" =>
    m -> bulk_update(m.race.objects, (raceid = [1],); columns = ["raceid"], match_on = ["raceid"], show_query = :dict),
  "empty SET: match_on keys alone (another field)" =>
    m -> bulk_update(m.race.objects, (year = [2008],); columns = ["year"], match_on = ["year"], show_query = :dict),
  "empty SET: match_on and filters= together" =>
    m -> bulk_update(m.race.objects, (raceid = [1], year = [2008]); columns = ["year"], match_on = ["raceid"], filters = ["year" => 2008], show_query = :dict),
  "empty SET: columns omitted, every column a key" =>
    m -> bulk_update(m.status.objects, (statusid = [1],); show_query = :dict),
  "empty SET: primary-key fallback, columns raceid" =>
    m -> bulk_update(m.race.objects, (raceid = [1],); columns = ["raceid"], show_query = :dict),
]

_bumx_strip(s) = replace(s, r"\e\[[0-9;]*m" => "")
# A dictionary's entries sorted by key, so the record does not depend on its hash order.
_bumx_canon(r) = r isa AbstractDict ? sort!([string(k) => _bumx_canon(v) for (k, v) in r]; by = first) :
                 r isa AbstractVector ? map(_bumx_canon, r) : r
function _bumx_observe(f, models)
  try
    # An `auto_now` field binds the time of the call: masked, so the record is the statement, not the clock.
    text = replace(_bumx_strip(repr(_bumx_canon(f(models)))), r"\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}:\d{2}(\.\d+)?(\+\d{2}:\d{2}|Z)?" => "<now>")
    return (stage = :ok, result = text)
  catch e
    return (stage = :raised, error = string(nameof(typeof(e))), message = _bumx_strip(sprint(showerror, e)))
  end
end

const _BUMX_FIXTURE = joinpath(@__DIR__, "fixtures", "bulk_update_matrix_expected.jl")

if get(ENV, "PORMG_BUMX_RECORD", "") == "1"
  # Record mode: write the fixture from the current code and stop. Not a test run.
  open(_BUMX_FIXTURE, "w") do io
    println(io, "# GENERATED by test/unit/test_bulk_update_matrix_1841.jl with PORMG_BUMX_RECORD=1 — do not edit by hand.")
    println(io, "# One entry per (cell, engine): what bulk_update renders or raises. A diff here is a behaviour change (#1841).")
    println(io, "const _BUMX_EXPECTED = Dict{Tuple{String,Symbol},Any}(")
    for (name, f) in _BUMX_CELLS, (eng, _) in _BUMX_ENGINES
      println(io, "  ", repr((name, eng)), " =>\n    ", repr(_bumx_observe(f, _BUMX_MODELS[eng])), ",")
    end
    println(io, ")")
  end
  @info "bulk_update matrix recorded" path = _BUMX_FIXTURE cells = length(_BUMX_CELLS)
else
  include(_BUMX_FIXTURE)

  # What: every cell, on every engine, against its recorded outcome.
  # Expected: the recorded statement and parameters, or the recorded error type and text; the fixture holds exactly the
  #   cells this file defines.
  # Why: #1841 adds one refusal where the SET list is computed; every other input must render and refuse as before.
  @testset "#1841: bulk_update matrix" begin
    defined = Set((name, eng) for (name, _) in _BUMX_CELLS for (eng, _) in _BUMX_ENGINES)
    @test defined == Set(keys(_BUMX_EXPECTED))
    for (name, f) in _BUMX_CELLS, (eng, _) in _BUMX_ENGINES
      got = _bumx_observe(f, _BUMX_MODELS[eng])
      @test (name, eng, got) == (name, eng, _BUMX_EXPECTED[(name, eng)])
    end
  end
end
