# ============================================================
# test/unit/test_lookup_bind_matrix_1599.jl
#
# CONTRACT being tested:
#   The JSON, array and network lookups render, on PostgreSQL, SQLite and MySQL, the statement and parameters they
#   rendered before #1599's follow-ups typed their binds (`_json_document_text`, `_json_key_text`, `_json_key_strings`,
#   `_add_parameter_at`, `_network_int_operand`, the network render's field argument), or raise the error they raised:
#   the same functions are called on the same values, at their types.
#
#   The expected values live in `fixtures/lookup_bind_matrix_expected.jl`, recorded from the code before the change
#   (`PORMG_LBMX_RECORD=1`); no cell may move.
#
# Hermetic: mock connections and `show_query = :dict`, no database.
#
# Run:    julia --project=test/integration test/unit/test_lookup_bind_matrix_1599.jl
# Record: PORMG_LBMX_RECORD=1 julia --project=test/integration test/unit/test_lookup_bind_matrix_1599.jl
# ============================================================

using Test
isdefined(Main, :SQLite) || include(joinpath(@__DIR__, "..", "load_drivers.jl"))
using PormG
using Sockets

struct LbmxMockPg <: PormG.PormGPostgres end
struct LbmxMockSl <: PormG.PormGSQLite end
struct LbmxMockMy <: PormG.PormGMySQL end
PormG.backend_sqlite_version(::LbmxMockSl) = 3045000
PormG.config["lbmx"] = PormG.Configuration.Settings(connections = LbmxMockPg(), change_data = true, db_def_folder = "lbmx")

module LbmxModels
import PormG
import PormG.Models
Lbmx_telemetry::Models.ModelType = Models.Model("lbmx_telemetry",
  id       = Models.IDField(),
  payload  = Models.JSONField(null = true),
  pit_laps = Models.ArrayField(Models.IntegerField()),
  pit_ip   = Models.GenericIPAddressField(),
  lan      = Models.CIDRField(null = true),
)
Models.@models Lbmx_telemetry
PormG.Models.set_models(@__MODULE__, "lbmx")
end
const _LBMX_T = LbmxModels.Lbmx_telemetry
const _LBMX_ENGINES = (:postgres => LbmxMockPg(), :sqlite => LbmxMockSl(), :mysql => LbmxMockMy())

# Each cell: a filter key and its value. The value types each bind reads at its type, and the ones it does not.
const _LBMX_CELLS = Pair{String, Any}[
  "payload__@jcontains" => Dict{String, Any}("drs" => true, "lap" => 12),
  "payload__@jcontains" => Dict("drs" => true),
  "payload__@jcontains" => Dict("tyre" => "soft"),
  "payload__@jcontains" => Dict("lap" => 12),
  "payload__@jcontains" => Dict("speed" => 301.5),
  "payload__@jcontains" => Any[1, "a"],
  "payload__@jcontains" => ["a", "b"],
  "payload__@jcontains" => [1, 2],
  "payload__@jcontains" => "{\"drs\": true}",
  "payload__@jcontains" => (drs = true,),
  "payload__@jcontains" => Dict(:drs => true),
  "payload__@jcontains" => Set([1]),
  "payload__@has_key" => "tyre",
  "payload__@has_key" => :tyre,
  "payload__@has_key" => 12,
  "payload__@has_key" => 2.5,
  "payload__@has_any_keys" => ["ers", "tyre"],
  "payload__@has_any_keys" => Any["ers", "tyre"],
  "payload__@has_any_keys" => [:ers, :tyre],
  "payload__@has_any_keys" => Any["ers", 1],
  "payload__@has_keys" => ["drs", "tyre"],
  "payload__@has_keys" => SubString("drs", 1, 3),
  "pit_laps__@acontains" => [12],
  "pit_laps__@contained_by" => [12, 31, 50],
  "pit_laps__@overlap" => [31, 40],
  "pit_laps__@overlap" => Int[],
  "pit_laps__@acontains" => ["x"],
  "pit_ip__@net_contained" => "10.0.0.0/8",
  "pit_ip__@net_contained_or_equal" => "10.0.0.0/8",
  "pit_ip__@net_contains" => "10.0.0.7",
  "pit_ip__@net_contains_or_equals" => ip"10.0.0.7",
  "pit_ip__@net_overlaps" => "10.0.0.0/24",
  "pit_ip__@net_contains" => "not an address",
  "lan__@net_contains" => "10.0.0.7",
  "pit_ip__@family" => 4,
  "pit_ip__@family" => 6,
  "pit_ip__@family" => 5,
  "pit_ip__@family" => true,
  "pit_ip__@family" => "4",
  "pit_ip__@family" => Int32(4),
  "pit_ip__@family" => big(6),
  "pit_ip__@prefixlen" => 32,
  "pit_ip__@prefixlen" => 0,
  "pit_ip__@prefixlen" => 129,
  "pit_ip__@prefixlen" => -1,
  "pit_ip__@prefixlen" => UInt8(24),
  "pit_ip__@prefixlen" => big(2)^70,
]

_lbmx_strip(s) = replace(s, r"\e\[[0-9;]*m" => "")
_lbmx_canon(r) = r isa AbstractDict ? sort!([string(k) => _lbmx_canon(v) for (k, v) in r]; by = first) :
                 r isa AbstractVector ? map(_lbmx_canon, r) : r
function _lbmx_observe(key, value, conn)
  try
    q = _LBMX_T.objects.filter(key => value).values("id")
    return (stage = :ok, result = _lbmx_strip(repr(_lbmx_canon(PormG.QueryBuilder.query(q; connection = conn, show_query = :dict)))))
  catch e
    # A `MethodError`'s first line names the call; its candidate list carries file paths and line numbers.
    msg = _lbmx_strip(sprint(showerror, e))
    e isa MethodError && (msg = first(split(msg, '\n')))
    return (stage = :raised, error = string(nameof(typeof(e))), message = msg)
  end
end
_lbmx_id(i, key, value) = string(i, " ", key, " => ", typeof(value), " ", repr(value))

const _LBMX_FIXTURE = joinpath(@__DIR__, "fixtures", "lookup_bind_matrix_expected.jl")

if get(ENV, "PORMG_LBMX_RECORD", "") == "1"
  # Record mode: write the fixture from the current code and stop. Not a test run.
  open(_LBMX_FIXTURE, "w") do io
    println(io, "# GENERATED by test/unit/test_lookup_bind_matrix_1599.jl with PORMG_LBMX_RECORD=1 — do not edit by hand.")
    println(io, "# One entry per (cell, engine): what the lookup renders or raises. A diff here is a behaviour change (#1599).")
    println(io, "const _LBMX_EXPECTED = Dict{Tuple{String,Symbol},Any}(")
    for (i, (key, value)) in enumerate(_LBMX_CELLS), (eng, conn) in _LBMX_ENGINES
      println(io, "  ", repr((_lbmx_id(i, key, value), eng)), " =>\n    ", repr(_lbmx_observe(key, value, conn)), ",")
    end
    println(io, ")")
  end
  @info "lookup bind matrix recorded" path = _LBMX_FIXTURE cells = length(_LBMX_CELLS)
else
  include(_LBMX_FIXTURE)

  # What: every JSON, array and network lookup cell, on every engine, against its recorded outcome.
  # Expected: the recorded statement and parameters, or the recorded error type and text; the fixture holds exactly the
  #   cells this file defines.
  # Why: the binds now read the value at its type so a trimmed image has code for them; a different bound value, SQL
  #   or refusal would change what a caller sends or reads.
  @testset "the JSON, array and network lookups bind as recorded (#1599)" begin
    defined = Set((_lbmx_id(i, k, v), eng) for (i, (k, v)) in enumerate(_LBMX_CELLS) for (eng, _) in _LBMX_ENGINES)
    @test defined == Set(keys(_LBMX_EXPECTED))
    for (i, (key, value)) in enumerate(_LBMX_CELLS), (eng, conn) in _LBMX_ENGINES
      id = _lbmx_id(i, key, value)
      @test (id, eng, _lbmx_observe(key, value, conn)) == (id, eng, _LBMX_EXPECTED[(id, eng)])
    end
  end
end
