# ============================================================
# test/unit/test_write_residue_trim_1694.jl
#
# CONTRACT being tested:
#   The typed forms layer 7's residue now goes through in a trimmed write (#1694, #1599 layer 7) answer what the forms
#   they replaced answered, and raise what those raised:
#     - two `match_on` columns of integers or text checked by a typed tuple (`_ensure_unique_bulk_update_key2`) against
#       the run-time tuple of `_ensure_unique_bulk_update_keys_other`: the same duplicates, reported by the same two rows;
#     - the self-referential children read from decoded rows (`_self_children_rows`, `_key_as`) against
#       `K[k for k in column]` over the same values;
#     - `SET_DEFAULT`'s value (`_value_sql(apply_formatter(_field_formatter(field), v))`) against
#       `"$(apply_formatter(field.formatter, v))"` for each field kind a key can be;
#     - `_self_cascade_fields` against a copy of the old loop.
#   The old forms, copied below, are the oracles.
#
# Hermetic: no database.
#
# Run: julia --project=test/integration test/unit/test_write_residue_trim_1694.jl
# ============================================================

using Test
isdefined(Main, :SQLite) || include(joinpath(@__DIR__, "..", "load_drivers.jl"))
using PormG
using Dates

const _WR_QB = PormG.QueryBuilder
const _WR_M = PormG.Models

_wr_outcome(f) = try
  (:ok, f())
catch e
  (:err, typeof(e), sprint(showerror, e))
end

# The old run-time tuple check, over plain vectors (`_ensure_unique_bulk_update_keys_other`'s loop).
function _wr_old_unique(cols::Vector{AbstractVector}, n::Int, filters::Vector{String})
  seen_keys = Dict{Tuple, Int}()
  for index in 1:n
    key = Tuple(column[index] for column in cols)
    if haskey(seen_keys, key)
      filters_text = join(filters, ", ")
      throw(PormG.QueryBuildError("Error in bulk_update, duplicate dynamic filter key values detected for filters [$filters_text] at rows $(seen_keys[key]) and $(index)."))
    end
    seen_keys[key] = index
  end
  return nothing
end

# What: the two-column key check, typed against the run-time tuple, over integer and text columns with no duplicate,
#   one duplicate, several, and a value equal in one column only.
# Expected: the same outcome (nothing, or the same `QueryBuildError` text naming the same two rows) from both.
# Why: the run-time tuple and its hash were calls a trimmed image had no code for; the typed tuple must flag the same rows.
@testset "two match_on columns are checked as the run-time tuple was (#1694)" begin
  filters = ["year", "round"]
  cases = Any[
    ([2010, 2011], [6, 6]), ([2010, 2010], [6, 6]), ([2010, 2010, 2011, 2010], [6, 7, 6, 6]),
    ([2010, 2011, 2010], [6, 6, 6]), (["a", "b", "a"], [1, 2, 1]), ([1, 2, 1], ["x", "y", "x"]),
    (["a", "a"], ["b", "c"]), (Int[], Int[]), ([5], [5]),
  ]
  for (a, b) in cases
    new = _wr_outcome(() -> _WR_QB._ensure_unique_bulk_update_key2(a, b, length(a), filters))
    old = _wr_outcome(() -> _wr_old_unique(AbstractVector[a, b], length(a), filters))
    @test (a, b, new) == (a, b, old)
  end
end

# What: the self-referential children read from decoded rows, against `K[k for k in column]` over the same values.
# Expected: the same keys and parents, in row order, at `K`, for `Int64`, `Int32` and `String` cells and keys.
# Why: the columnar read over an untyped result dispatched at run time; the decoded read must hand the walk the same keys.
@testset "the self-referential children are read as the columnar read read them (#1694, #1377)" begin
  for (K, ks, ps) in ((Int64, Any[3, 4, 5], Any[2, 3, 4]), (Int64, Any[Int32(3), Int32(4)], Any[Int32(2), Int32(3)]),
                      (Int32, Any[Int32(7)], Any[Int32(6)]), (String, Any["c", "d"], Any["b", "c"]))
    rows = [Dict{Symbol, Any}(:constructorid => ks[i], :parentid => ps[i]) for i in eachindex(ks)]
    new = _WR_QB._self_children_rows(rows, :constructorid, :parentid, K)
    old = (K[k for k in ks], K[p for p in ps])
    @test (K, new) == (K, old)
    @test typeof(new) == Tuple{Vector{K}, Vector{K}}
  end
  @test _WR_QB._self_children_rows(Dict{Symbol, Any}[], :constructorid, :parentid, Int64) == (Int64[], Int64[])
end

# What: `SET_DEFAULT`'s SQL value, read at the field's type and kept a `String`, against the old interpolation of the
#   formatter read on the field.
# Expected: the same text for an integer key, a text key, a big-integer and a UUID field's default.
# Why: the formatter slot read on the field union and the interpolation of an untyped value were run-time calls.
@testset "SET_DEFAULT's value is written as before (#1694)" begin
  for (field, v) in ((_WR_M.IntegerField(), 7), (_WR_M.BigIntegerField(), Int64(9_000_100)), (_WR_M.CharField(), "pit"),
                     (_WR_M.IDField(), 3), (_WR_M.UUIDField(), "8f0e1b6a-3c3d-4e8a-9a0f-0123456789ab"))
    new = _wr_outcome(() -> _WR_QB._value_sql(_WR_M.apply_formatter(_WR_QB._field_formatter(field), v)))
    old = _wr_outcome(() -> "$(_WR_M.apply_formatter(field.formatter, v))")
    @test (typeof(field), new) == (typeof(field), old)
  end
end

module WrModels
import PormG
import PormG.Models
Wr_team::Models.ModelType = Models.Model("wr_team",
  teamid = Models.IDField(), name = Models.CharField(),
  parentid = Models.ForeignKey("Wr_team", pk_field = "teamid", on_delete = "CASCADE", null = true),
  rivalid = Models.ForeignKey("Wr_team", pk_field = "teamid", on_delete = "SET_NULL", null = true))
Models.@models Wr_team
end

function _wr_old_self_cascade_fields(model)
  fields = String[]
  for related_value in values(model.related_objects)
    related_value isa _WR_M.ManyToManyRelation && continue
    rel = related_value::_WR_M.ReverseRelation
    rel.model_resolved === model || continue
    fk = String(rel.fk_field)
    model.fields[fk].on_delete === _WR_QB.CASCADE && push!(fields, fk)
  end
  return fields
end

# What: the self-referential CASCADE keys of a model with one CASCADE and one SET_NULL key to itself.
# Expected: the same keys as the old loop (`parentid` only).
# Why: `on_delete` read on the field union was a run-time call; the walk must pick the same keys.
@testset "the self-referential CASCADE keys are the old loop's (#1694, #1377)" begin
  model = WrModels.Wr_team
  PormG.Models.ensure_model_initialized(model)
  @test _WR_QB._self_cascade_fields(model) == _wr_old_self_cascade_fields(model)
end
