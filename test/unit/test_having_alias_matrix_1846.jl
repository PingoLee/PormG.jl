# ============================================================
# test/unit/test_having_alias_matrix_1846.jl
#
# CONTRACT being tested:
#   A filter on a projection alias (`values("n" => Count(…)).filter("n__@gt" => …)`, which renders in `HAVING`, or in
#   `WHERE` for a row alias) renders, on PostgreSQL, SQLite and MySQL, the statement and the parameters (their values and
#   element types) it rendered before #1846 typed its decision and its bind, or raises the error it raised, through
#   `filter`, `Q` and `Qor`. The alias kinds, operators and values each path reads, empty lists included.
#
#   The expected values live in `fixtures/having_alias_matrix_expected.jl`, recorded from the code before the change
#   (`PORMG_HVMX_RECORD=1`); no cell may move.
#
# Hermetic: mock connections and `show_query = :dict`, no database.
#
# Run:    julia --project=test/integration test/unit/test_having_alias_matrix_1846.jl
# Record: PORMG_HVMX_RECORD=1 julia --project=test/integration test/unit/test_having_alias_matrix_1846.jl
# ============================================================

using Test
isdefined(Main, :SQLite) || include(joinpath(@__DIR__, "..", "load_drivers.jl"))
using PormG
using PormG.QueryBuilder: F, Q, Qor, Count, Sum, Max
using PormG.Functions: Avg, Cast, Value
using Dates
using Decimals: Decimal

struct HvmxMockPg <: PormG.PormGPostgres end
struct HvmxMockSl <: PormG.PormGSQLite end
struct HvmxMockMy <: PormG.PormGMySQL end
PormG.backend_sqlite_version(::HvmxMockSl) = 3045000
PormG.config["hvmx"] = PormG.Configuration.Settings(connections = HvmxMockPg(), change_data = true, db_def_folder = "hvmx")

module HvmxModels
import PormG
import PormG.Models
Hvmx_race::Models.ModelType = Models.Model("hvmx_race",
  raceid = Models.IDField(),
  year   = Models.IntegerField(),
  round  = Models.IntegerField(),
  name   = Models.CharField(max_length = 80),
  date   = Models.DateField(null = true),
  points = Models.FloatField(null = true),
)
Models.@models Hvmx_race
PormG.Models.set_models(@__MODULE__, "hvmx")
end
const _HVMX_R = HvmxModels.Hvmx_race
const _HVMX_ENGINES = (:postgres => HvmxMockPg(), :sqlite => HvmxMockSl(), :mysql => HvmxMockMy())

# The aliases: an aggregate of each read kind, a text aggregate, a row expression, a cast and a literal.
const _HVMX_ALIASES = (
  "n"  => () -> Count("raceid"),
  "s"  => () -> Sum("round"),
  "a"  => () -> Avg("points"),
  "mx" => () -> Max("date"),
  "mn" => () -> Max("name"),
  "r1" => () -> F("round") + 1,
  "ct" => () -> Cast(Count("raceid"), "text"),
  "v"  => () -> Value(3),
)
# Each cell: a lookup suffix and a value.
const _HVMX_CELLS = Pair{String, Any}[
  "gt" => 1, "gte" => 24, "lt" => 2.5, "lte" => Decimal(3.5), "" => 2, "ne" => 3, "gt" => "abc", "gt" => "7",
  "gt" => true, "gt" => Date(2008, 5, 25), "gt" => nothing, "gt" => Int32(4),
  "isnull" => true, "isnull" => false,
  "in" => [1, 2], "in" => [1.5, 2.5], "in" => ["7", "x"], "in" => [Date(2008, 5, 25)], "in" => Any[1, "2"],
  "in" => Int64[], "in" => String[], "in" => Any[], "nin" => [3], "nin" => Int64[],
  "range" => [1, 10], "range" => [1.5, 9.5], "range" => [Date(2008, 1, 1), Date(2008, 12, 31)], "range" => [1],
  "contains" => "Mon", "icontains" => "mon", "startswith" => "M", "gt" => F("round"), "gt" => Max("round"),
]

_hvmx_strip(s) = replace(s, r"\e\[[0-9;]*m" => "")
_hvmx_canon(r) = r isa AbstractDict ? sort!([string(k) => _hvmx_canon(v) for (k, v) in r]; by = first) : r
# The parameters with their element types: an empty list bound as `String[]` and as `Any[]` are different parameters.
_hvmx_typed(r) = r isa AbstractDict ? [string(k) => (k in (:params, "params") ? repr(v) : _hvmx_canon(v)) for (k, v) in r] : r
_hvmx_spellings(key, value) = (
  :filter => () -> (key => value,),
  :Q => () -> (Q(key => value),),
  :Qor => () -> (Qor(key => value, "year" => 1900),),
)
function _hvmx_observe(alias, mk, key, value, spelling, conn)
  try
    q = _HVMX_R.objects.values("year", alias => mk()).filter(spelling()...)
    d = PormG.QueryBuilder.query(q; connection = conn, show_query = :dict)
    return (stage = :ok, result = _hvmx_strip(repr(sort!(_hvmx_typed(d); by = first))))
  catch e
    msg = _hvmx_strip(sprint(showerror, e))
    e isa MethodError && (msg = first(split(msg, '\n')))   # its candidate list carries file paths
    return (stage = :raised, error = string(nameof(typeof(e))), message = msg)
  end
end
_hvmx_id(alias, key, value, spelling) = string(alias, " ", key, " => ", typeof(value), " ", repr(value), " ", spelling)
_hvmx_cases() = [(alias, mk, isempty(op) ? alias : string(alias, "__@", op), value, sp, spf)
                 for (alias, mk) in _HVMX_ALIASES for (op, value) in _HVMX_CELLS
                 for (sp, spf) in _hvmx_spellings(isempty(op) ? alias : string(alias, "__@", op), value)]

const _HVMX_FIXTURE = joinpath(@__DIR__, "fixtures", "having_alias_matrix_expected.jl")

if get(ENV, "PORMG_HVMX_RECORD", "") == "1"
  # Record mode: write the fixture from the current code and stop. Not a test run.
  open(_HVMX_FIXTURE, "w") do io
    println(io, "# GENERATED by test/unit/test_having_alias_matrix_1846.jl with PORMG_HVMX_RECORD=1 — do not edit by hand.")
    println(io, "# One entry per (case, engine): what a filter on the alias renders or raises. A diff is a behaviour change (#1846).")
    println(io, "const _HVMX_EXPECTED = Dict{Tuple{String,Symbol},Any}(")
    for (alias, mk, key, value, sp, spf) in _hvmx_cases(), (eng, conn) in _HVMX_ENGINES
      println(io, "  ", repr((_hvmx_id(alias, key, value, sp), eng)), " =>\n    ",
              repr(_hvmx_observe(alias, mk, key, value, spf, conn)), ",")
    end
    println(io, ")")
  end
  @info "having alias matrix recorded" path = _HVMX_FIXTURE cases = length(_hvmx_cases())
else
  include(_HVMX_FIXTURE)

  # What: every alias kind × lookup × value × spelling, on every engine, against its recorded outcome.
  # Expected: the recorded statement and parameters (values and element types), or the recorded error type and text;
  #   the fixture holds exactly the cases this file defines.
  # Why: #1846 typed the clause choice (`_resolved_agg` through `_with_field_part_open`), the value's format and check
  #   (`_resolve_having_filter_value`) and its bind (`_bind_alias_predicate`) so a trimmed image has code for them; a
  #   different statement, parameter or refusal would change what a caller sends or reads.
  @testset "a filter on a projection alias renders and binds as recorded (#1846)" begin
    seen = Set{Tuple{String,Symbol}}()
    for (alias, mk, key, value, sp, spf) in _hvmx_cases(), (eng, conn) in _HVMX_ENGINES
      id = (_hvmx_id(alias, key, value, sp), eng)
      push!(seen, id)
      @test (id, _hvmx_observe(alias, mk, key, value, spf, conn)) == (id, get(_HVMX_EXPECTED, id, :missing_from_fixture))
    end
    @test Set(keys(_HVMX_EXPECTED)) == seen
  end
end
