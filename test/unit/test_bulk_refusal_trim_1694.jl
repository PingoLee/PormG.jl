# ============================================================
# test/unit/test_bulk_refusal_trim_1694.jl
#
# CONTRACT being tested:
#   The bulk writers' error pass, `_depuration_values_bulk_insert`, which runs when a row fails and names the cell
#   that cannot be formatted, answers what it answered before #1599's layer-7 retyping, cell for cell: it returns
#   `nothing` on the same rows, and on the others raises the same error type, with the same message, kind, row and
#   field, from the same cell. The old pass is copied below, verbatim, as the oracle. What `bulk_insert` and
#   `bulk_update` send and refuse end to end is pinned by the bulk suite (test_bulk_*.jl,
#   test_single_row_collection_value.jl), unchanged.
#
# Hermetic: a mock connection and hand-built frames, no database.
#
# Run: julia --project=test/integration test/unit/test_bulk_refusal_trim_1694.jl
# ============================================================

using Test
isdefined(Main, :SQLite) || include(joinpath(@__DIR__, "..", "load_drivers.jl"))
using PormG
using Dates

const _BRT_QB = PormG.QueryBuilder
const _BRT_M = PormG.Models

struct BrtMockSQLite <: PormG.PormGSQLite end
PormG.backend_sqlite_version(::BrtMockSQLite) = 3045000
PormG.config["brt_mock"] = PormG.Configuration.Settings(connections = BrtMockSQLite(), change_data = true,
                                                        db_def_folder = "brt_mock")

module BrtModels
import PormG
import PormG.Models
Brt_race::Models.ModelType = Models.Model("brt_race",
  raceid   = Models.IDField(),
  year     = Models.IntegerField(),
  name     = Models.CharField(max_length = 20),
  date     = Models.DateField(null = true),
  start_at = Models.DateTimeField(null = true),
  laptime  = Models.TimeField(null = true),
  points   = Models.DecimalField(max_digits = 6, decimal_places = 2, null = true),
  speed    = Models.FloatField(null = true),
  finished = Models.BooleanField(null = true),
  token    = Models.UUIDField(null = true),
  meta     = Models.JSONField(null = true),
  fastest  = Models.DurationField(null = true),
)
Models.@models Brt_race
PormG.Models.set_models(@__MODULE__, "brt_mock")
end
const _BRT_RACE = BrtModels.Brt_race

# ── The old pass, copied from the code before #1599 layer 7's retyping ───────────────────────────────────────
function _old_depuration(fields::Vector{String}, mapping::Dict{String, String}, model::PormG.PormGModel,
                         df::_BRT_QB._BulkFrame, index::Integer; op::AbstractString = "bulk_insert")
  for field in fields
    col_name = get(mapping, field, field)
    if !(_BRT_QB._has_bulk_column(df, col_name))
      continue
    end
    value = _BRT_QB._bulk_column(df, col_name)[index]
    try
      model.fields[field].formatter(value)
    catch e
      (e isa InterruptException || e isa StackOverflowError) && rethrow()
      try
        _BRT_QB._refuse_collection(model.fields[field], field, value, op)
        _BRT_QB._refuse_expression_value(model, field, value, op)
      catch refusal
        refusal isa PormG.InvalidValueError && throw(_BRT_QB._bulk_cell_error(refusal, op, model, field, index))
        rethrow()
      end
      source = _BRT_QB._is_injected_fill_column(col_name) ?
        "a PormG-supplied default/auto value" : "column $(col_name)"
      refusal = e isa PormG.InvalidValueError ?
        PormG.InvalidValueError("$(rstrip(e.reason, '.')) (from $(source)).", e.kind) :
        PormG.InvalidValueError("The value from $(source) can't be formatted ($(typeof(e))).", :other)
      throw(_BRT_QB._bulk_cell_error(refusal, op, model, field, index))
    end
  end
end

# What the pass gave: `nothing`, or what it raised, with every part of an `InvalidValueError` a caller reads.
_brt_outcome(f) = try
  (:value, f())
catch e
  e isa PormG.InvalidValueError ? (:raised, :InvalidValueError, e.msg, e.kind, e.reason, e.op, e.model, e.field, e.row) :
                                  (:raised, typeof(e), sprint(showerror, e))
end

# One column per field, five rows: a good row, then rows each holding cells the formatters refuse or that take the
# open arms (text where a type is wanted, a collection, an SQL expression, a narrower integer, `missing`, `nothing`).
function _brt_frames()
  F = _BRT_QB.F
  good = (year = 2009, name = "Monaco", date = Date(2009, 5, 24), start_at = DateTime(2009, 5, 24, 14), laptime = Time(1, 14),
          points = _BRT_M.Decimals.Decimal(0, 1000, -2), speed = 160.5, finished = true,
          token = _BRT_M.UUIDs.UUID("550e8400-e29b-41d4-a716-446655440000"), meta = "{\"r\": 1}", fastest = Second(80))
  rows = Any[
    good,
    merge(good, (date = "2013-02-30",)),
    merge(good, (meta = "{not json",)),
    merge(good, (token = "not-a-uuid", points = "abc")),
    merge(good, (name = ["A", "B"], speed = "fast")),
    merge(good, (year = F("raceid") + 1,)),
    merge(good, (date = missing, start_at = nothing, year = Int32(7), finished = "yes")),
    merge(good, (laptime = "25:99:00", fastest = "nope", start_at = "2009-05-24T14:00:00")),
    merge(good, (date = [Date(2009, 5, 24), Date(2010, 5, 16)],)),          # a collection a formatter refuses (#716)
    merge(good, (points = [1, 2], meta = Dict("r" => 1))),
    merge(good, (year = :sym,)),                                           # formatters that raise another error
    merge(good, (token = 42, laptime = 3.5)),
  ]
  names = String.(collect(keys(good)))
  # Typed columns where every row agrees, `Vector{Any}` where it does not: the frames a table hands over.
  typed = Dict{String, AbstractVector}()
  for n in names
    vals = Any[getfield(r, Symbol(n)) for r in rows]
    T = mapreduce(typeof, typejoin, vals)
    typed[n] = isconcretetype(T) ? convert(Vector{T}, vals) : vals
  end
  untyped = Dict{String, AbstractVector}(n => Any[getfield(r, Symbol(n)) for r in rows] for n in names)
  return names, [_BRT_QB._BulkFrame(names, typed, length(rows)), _BRT_QB._BulkFrame(names, untyped, length(rows))]
end

# What: the error pass, new against old, over every row of a typed and an untyped frame, under each writer's
#   name, with an identity mapping, with one field mapped to PormG's own fill column (#335), and with a field the
#   frame does not have.
# Expected: the same outcome for every row: `nothing`, or the same error with the same message, kind, reason, op,
#   model, field and row, from the same cell.
# Why: the pass reads its cell, calls the field's formatter and checks the value at concrete types so a trimmed
#   image can run it (#1599 layer 7); under the JIT it must be invisible. The refusal it raises is the message a
#   bulk caller reads.
@testset "the bulk error pass names the same cell with the same refusal (#1599 layer 7, #1694)" begin
  names, frames = _brt_frames()
  fill_col = _BRT_QB._BULK_FILL_PREFIX * "token"
  for df in frames, op in ("bulk_insert", "bulk_update")
    mappings = Dict{String, String}[Dict(n => n for n in names)]
    # PormG's fill column for `token`: the frame holds the value under the private name.
    filled = _BRT_QB._BulkFrame(vcat(names, fill_col), merge(df.columns, Dict{String, AbstractVector}(fill_col => df.columns["token"])), df.row_count)
    for (frame, mapping, fields) in ((df, mappings[1], names),
                                     (filled, merge(mappings[1], Dict("token" => fill_col)), names),
                                     (df, mappings[1], vcat(names, ["raceid"])))
      for index in 1:frame.row_count
        tag = (op, eltype(frame.columns["year"]), index, get(mapping, "token", "token"))
        @test (tag, _brt_outcome(() -> _BRT_QB._depuration_values_bulk_insert(fields, mapping, _BRT_RACE, frame, index; op = op))) ==
              (tag, _brt_outcome(() -> _old_depuration(fields, mapping, _BRT_RACE, frame, index; op = op)))
      end
    end
  end
end
