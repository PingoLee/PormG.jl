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

