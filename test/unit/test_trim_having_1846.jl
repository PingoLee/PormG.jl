# ============================================================
# test/unit/test_trim_having_1846.jl
#
# CONTRACT being tested:
#   A filter on an aggregate alias (`values("n" => Count(…)).filter("n__@gt" => …)`, which renders in `HAVING`) formats
#   and checks its value at its types since #1846 (#1599 layers 5-6), and answers what the old code answered:
#     - `_resolve_having_filter_value` returns the same value, of the same type, or raises the same error type and text,
#       for every alias kind × operator × value below, on every engine (the SQLite native-number rule included);
#     - the whole statement renders the same SQL and binds the same parameters, or raises the same refusal, through the
#       filter and the `Q`/`Qor` spelling (checked here against the base's recorded answers is the PR's differential;
#       this file checks the statements render and the refusals keep their type and text).
#   The old `_resolve_having_filter_value` (base `20b8ad664`) is vendored below as the oracle.
#
# Hermetic: mock connections, no database.
#
# Run: julia --project=test/integration test/unit/test_trim_having_1846.jl
# ============================================================

using Test
isdefined(Main, :SQLite) || include(joinpath(@__DIR__, "..", "load_drivers.jl"))
using PormG
using PormG.QueryBuilder: Q, Qor, Count, Sum, Max
using PormG.Functions: Avg
using Dates
using Decimals: Decimal

const _HV_QB = PormG.QueryBuilder

struct HvMockSQLite <: PormG.PormGSQLite end
struct HvMockPostgres <: PormG.PormGPostgres end
struct HvMockMySQL <: PormG.PormGMySQL end
PormG.backend_sqlite_version(::HvMockSQLite) = 3045000
PormG.config["hv1846"] = PormG.Configuration.Settings(connections = HvMockSQLite(), change_data = true,
                                                      db_def_folder = "hv1846")

module Hv1846Models
import PormG
import PormG.Models
Hv_race::Models.ModelType = Models.Model("hv1846_race",
  raceid = Models.IDField(),
  year   = Models.IntegerField(),
  round  = Models.IntegerField(),
  name   = Models.CharField(max_length = 80),
  date   = Models.DateField(null = true),
  points = Models.FloatField(null = true),
)
Models.@models Hv_race
PormG.Models.set_models(@__MODULE__, "hv1846")
end
const _HV_RACE = Hv1846Models.Hv_race
const _HV_CONNS = (HvMockSQLite(), HvMockPostgres(), HvMockMySQL())

# The old `_resolve_having_filter_value` (base `20b8ad664`), with the call through `_lookup_formatter` dispatched.
function _hv_old_resolve(alias, raw_value, instruc, operator::AbstractString)
  QB = _HV_QB
  operator == "ISNULL" && return raw_value
  formatter = QB._lookup_formatter(QB._having_alias_formatter(alias, instruc), operator)
  formatter === nothing && return raw_value
  formatted_value = QB._guarded_format(formatter, raw_value, operator, alias[2], QB._formatter_type_label(formatter);
                                       subject = "projection alias")
  operator in QB._ITERABLE_LOOKUP_OPERATORS && raw_value isa AbstractArray &&
    return [QB._sqlite_preserve_native_parameter(r, f, formatter, instruc) for (r, f) in zip(raw_value, formatted_value)]
  return QB._sqlite_preserve_native_parameter(raw_value, formatted_value, formatter, instruc)
end

_hv_outcome(f) = try
  v = f()
  (:value, typeof(v), v)
catch e
  (:raised, typeof(e), sprint(showerror, e))
end

# An alias of each kind, projected beside `year` and grouped by it.
const _HV_ALIASES = (
  "n" => () -> Count("raceid"),
  "s" => () -> Sum("round"),
  "a" => () -> Avg("points"),
  "mx" => () -> Max("date"),
  "mn" => () -> Max("name"),
)
const _HV_CASES = (
  ("GT", 1), ("GT", 1.5), ("GT", Decimal(1.5)), ("GT", "abc"), ("GT", "7"), ("GT", true), ("GT", Date(2008, 5, 25)),
  ("GTE", 24), ("LT", 2.0), ("=", 2), ("ISNULL", true), ("ISNULL", false),
  ("IN", [1, 2]), ("IN", [1.5, 2.5]), ("IN", ["7", "8"]), ("IN", [Date(2008, 5, 25)]), ("NOT IN", [3]),
  ("BETWEEN", [1, 10]), ("BETWEEN", [1.5, 9.5]), ("BETWEEN", [Date(2008, 1, 1), Date(2008, 12, 31)]),
  ("LIKE", "Mon"), ("ILIKE", "mon"),
)

# What: `_resolve_having_filter_value` against the old one, for each alias kind × operator × value, on every engine.
# Expected: the same value of the same type (the SQLite native-number rule, a membership list's per-element rule), or
#   the same error type and text.
# Why: the function now takes the literal unspecialized and the alias's formatter through the generic
#   `_lookup_formatter` method, which a trimmed image can follow (#1846); neither may change what it answers.
@testset "an alias's value is formatted and checked as before (#1846)" begin
  for conn in _HV_CONNS, (name, mk) in _HV_ALIASES
    h = _HV_RACE.objects.values("year", name => mk())
    r = _HV_QB._render_select(h; connection = conn, show_query = :sql)
    instruc = r.instruction
    key = _HV_QB.memo_key(:base, name)
    for (op, value) in _HV_CASES
      new = _hv_outcome(() -> _HV_QB._resolve_having_filter_value(key, value, instruc, op))
      old = _hv_outcome(() -> _hv_old_resolve(key, value, instruc, op))
      @test (typeof(conn), name, op, value, new) == (typeof(conn), name, op, value, old)
    end
  end
end

# What: the full statement for a filter on each alias, through `filter` and through `Q`/`Qor`, on every engine.
# Expected: a statement renders for a value of the alias's type, in `HAVING`, and a value of the wrong type is refused
#   with `InvalidValueError` naming the alias and its type label (the text the fixture prints).
# Why: the clause choice (`_resolved_agg` through `_with_field_part_open`) and the bind (`_bind_alias_predicate`) are the
#   other two walls; the base-against-branch render differential in the PR covers their SQL and parameters.
@testset "a filter on an aggregate alias renders in HAVING (#1846)" begin
  for conn in _HV_CONNS
    for q in (_HV_RACE.objects.values("year", "n" => Count("raceid")).filter("n__@gt" => 1),
              _HV_RACE.objects.values("year", "n" => Count("raceid")).filter(Q("n__@gt" => 1)),
              _HV_RACE.objects.values("year", "n" => Count("raceid")).filter(Qor("n__@gt" => 1, "n__@lt" => 0)),
              _HV_RACE.objects.values("year", "s" => Sum("round")).filter("s__@gte" => 24),
              _HV_RACE.objects.values("year", "s" => Sum("round")).filter("s__@range" => [1, 30]))
      sql = _HV_QB.query(q; connection = conn, show_query = :sql)
      @test (typeof(conn), occursin("HAVING", sql)) == (typeof(conn), true)
    end
    e = try
      _HV_QB.query(_HV_RACE.objects.values("year", "n" => Count("raceid")).filter("n__@gt" => "abc");
                   connection = conn, show_query = :sql)
      nothing
    catch err
      err
    end
    @test e isa PormG.InvalidValueError
    @test (e::PormG.InvalidValueError).msg ==
          "Error in filter on the `n` projection alias (number): The value is not a valid number"
  end
end
