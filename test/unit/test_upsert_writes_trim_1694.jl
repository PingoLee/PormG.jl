# ============================================================
# test/unit/test_upsert_writes_trim_1694.jl
#
# CONTRACT being tested:
#   The typed forms `bulk_update`, `get_or_create` and `update_or_create` now go through in a trimmed binary (#1599
#   layer 7, #1694) answer what the forms they replaced answered, value for value, and raise what those raised:
#     - `_copy_insert`, the insert map of a copied query, against `deepcopy`: the same map (an emptied one included),
#       iterated in the same order, grown the same way afterwards, never the original.
#   The old call is made directly below as the oracle.
#
# Hermetic: no database.
#
# Run: julia --project=test/integration test/unit/test_upsert_writes_trim_1694.jl
# ============================================================

using Test
isdefined(Main, :SQLite) || include(joinpath(@__DIR__, "..", "load_drivers.jl"))
using PormG
using Dates
import OrderedCollections

const _UPS_QB = PormG.QueryBuilder

# What: `_copy_insert` against `deepcopy` over an empty map, a map emptied by a deletion and a filled one.
# Expected: an equal map of the same type, a different object, the same order after the same inserts; a filled map's
#   mutable values copied, not shared.
# Why: the copy of every handler `bulk_update` (and every other copying terminal) makes went through `deepcopy` of an
#   `OrderedDict`, whose generic field walk a trimmed image has no code for (`deepcopy_internal(::Vector{Int32}, …)`).
@testset "an insert map is copied as deepcopy copied it (#1599 layer 7)" begin
  empty_map = OrderedCollections.OrderedDict{String,Any}()
  emptied = OrderedCollections.OrderedDict{String,Any}("year" => 2010, "round" => 6)
  delete!(emptied, "year"); delete!(emptied, "round")
  for d in (empty_map, emptied)
    new, old = _UPS_QB._copy_insert(d), deepcopy(d)
    @test typeof(new) === typeof(old) && new == old && new !== d
    for (k, v) in (("round", 7), ("year", 2011), ("name", "Monaco Grand Prix"))
      new[k] = v; old[k] = v
    end
    @test collect(new) == collect(old)
    @test isempty(d)
  end
  filled = OrderedCollections.OrderedDict{String,Any}("year" => 2010, "name" => "Monaco Grand Prix",
                                                      "date" => Date(2010, 5, 16), "laps" => [78, 77])
  new, old = _UPS_QB._copy_insert(filled), deepcopy(filled)
  @test typeof(new) === typeof(old) && new == old && collect(keys(new)) == collect(keys(old))
  @test new !== filled && new["laps"] !== filled["laps"]
end

# What a call gave: its value, or the type and text of what it raised.
_ups_outcome(f) = try
  (:value, f())
catch e
  (:raised, typeof(e), sprint(showerror, e))
end

# The old `_ensure_unique_bulk_update_keys!` (base `91a66a381`), as the oracle.
function _old_ensure_unique_bulk_update_keys!(df, mapping::Dict{String, String}, dynamic_filters::Vector{String})
  isempty(dynamic_filters) && return nothing
  seen_keys = Dict{Tuple, Int}()
  key_columns = [_UPS_QB._bulk_column(df, mapping[field]) for field in dynamic_filters]
  for index in 1:df.row_count
    key = Tuple(column[index] for column in key_columns)
    if haskey(seen_keys, key)
      filters_text = join(dynamic_filters, ", ")
      throw(PormG.QueryBuildError("Error in bulk_update, duplicate dynamic filter key values detected for filters [$filters_text] at rows $(seen_keys[key]) and $(index)."))
    end
    seen_keys[key] = index
  end
  return nothing
end

# What: `_ensure_unique_bulk_update_keys!` against the old check, over one-column keys of integers and of text (the
#   typed arm), with and without a duplicate, and keys the open arm takes (two columns, floats, a `missing`).
# Expected: the same outcome, `nothing` or the same `QueryBuildError` naming the same two rows.
# Why: the tuple keys of a run-time length and their hash had no compiled target in a trimmed `bulk_update`.
@testset "a bulk_update's match keys are checked for duplicates as before (#1599 layer 7)" begin
  tables = Any[
    [(raceid = 1, round = 7), (raceid = 2, round = 8)],
    [(raceid = 1, round = 7), (raceid = 2, round = 8), (raceid = 1, round = 9)],
    [(name = "Monaco", round = 7), (name = "Brazil", round = 8)],
    [(name = "Monaco", round = 7), (name = "Monaco", round = 8)],
    [(raceid = 1, year = 2008, round = 7), (raceid = 1, year = 2009, round = 8), (raceid = 1, year = 2008, round = 9)],
    [(score = 1.5, round = 7), (score = 1.5, round = 8)],
    [(raceid = missing, round = 7), (raceid = 1, round = 8), (raceid = missing, round = 9)],
    [(raceid = 1, round = 7)],
  ]
  for t in tables
    df = _UPS_QB._bulk_frame(t, "bulk_update")
    cols = String[string(c) for c in keys(t[1]) if c !== :round]
    mapping = Dict{String, String}(c => c for c in vcat(cols, ["round"]))
    for keys_ in (cols, String[])
      @test (cols, keys_, _ups_outcome(() -> _UPS_QB._ensure_unique_bulk_update_keys!(df, mapping, keys_))) ==
            (cols, keys_, _ups_outcome(() -> _old_ensure_unique_bulk_update_keys!(df, mapping, keys_)))
    end
  end
end

# What: `_fork_parameters` on a PostgreSQL collector (#1599 layer 7) against the expression it replaces, over a
#   `Vector{Any}` of bindings (the typed arm) and other containers (the open arm).
# Expected: a new collector with the same SQL, an equal but distinct `Vector{Any}` and the same count.
# Why: `collect(Any, …)` over the collector's abstractly typed slot dispatched at run time on every `bulk_update` chunk.
@testset "a PostgreSQL collector forks as before (#1599 layer 7)" begin
  for params in Any[Any[1, "Monaco", Date(2008, 5, 25)], Any[], Int[1, 2], (1, "x")]
    pq = _UPS_QB.PgParameterizedQuery("SELECT 1", params, length(params))
    new, old = _UPS_QB._fork_parameters(pq), _UPS_QB.PgParameterizedQuery(pq.sql, collect(Any, pq.parameters), pq.parameter_count)
    @test (typeof(params), new.sql, typeof(new.parameters), new.parameters, new.parameter_count) ==
          (typeof(params), old.sql, typeof(old.parameters), old.parameters, old.parameter_count)
    @test new.parameters !== pq.parameters
  end
end
