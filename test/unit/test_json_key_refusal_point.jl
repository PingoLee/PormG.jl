"""
The one refusal point for an uncast JSON key's value (#1531).

Since #1458 a JSON key's value is `CJSONValue`, a scalar the document types row by row, and every
position that needs a type refuses it, naming the cast. The rule used to be enforced one position at a
time — six helpers from thirteen sites in six files — and each new position meant one more bug
(#1471 … #1511). It is now stated once, in `src/querybuilder/json_key_refusal.jl`: the two probes
(`_json_key_lookup_operand`, "is the key"; `_json_number_side`, "carries the key"), the positions as
types (`_JSONKeyPosition`), one refusal per position (`_json_key_refusal`), and the entry point
(`_refuse_uncast_json_key`).

Pinned here:

  1. **No carrier probe outside the file.** `_json_number_side(` is called only there, except by the
     three record writers that store its answer for the outer query (a CTE column's, a `Subquery`'s),
     which are listed by count. A `CJSONValue` type test is written only there and in the walk
     (`expression_kind.jl`), so "is this a key's value" has one answer, `_json_key_lookup_operand`,
     which the comparison renders call to route a key to the key lookup's comparison.
  2. **No refusal outside the file.** The refusal texts ("a JSON key's value has no …", "a JSON path
     lookup compares …") occur only there, so a position cannot raise its own copy.
  3. **Every position has its refusal**, and every refusal raises the error type its position
     documents (`QueryBuildError` for a build position, `FilterError` for a filter one).
  4. **A position's exemption is its own rule** (`@isnull` on a carrier filter), not a call site's.

What each position answers per shape is `test_expression_kind_matrix.jl`'s and `test_json_lookups.jl`'s
business; this file pins only that there is one place to answer it.

DB-free: no connection is opened.

julia --project=test/integration test/unit/test_json_key_refusal_point.jl
"""

using Test
using PormG
using InteractiveUtils: subtypes

const _JKR_QB = PormG.QueryBuilder
const _JKR_HOME = joinpath("querybuilder", "json_key_refusal.jl")

# Every `src/`/`ext/` file but the refusal point, with comment lines dropped: the probes and the rule are
# named in comments all over the query builder, and a comment is not a consumer.
function _jkr_code_lines(; exempt::Vector{String} = String[])
  lines = Tuple{String,Int,String}[]
  for dir in ("src", "ext")
    base = joinpath(pkgdir(PormG), dir)
    for (root, _, files) in walkdir(base), file in files
      endswith(file, ".jl") || continue
      rel = relpath(joinpath(root, file), joinpath(pkgdir(PormG), "src"))
      (rel == _JKR_HOME || rel in exempt) && continue
      for (i, line) in enumerate(eachline(joinpath(root, file)))
        startswith(lstrip(line), "#") && continue
        push!(lines, (rel, i, line))
      end
    end
  end
  return lines
end

@testset "#1531 — the uncast-JSON-key probes are called only from the refusal point" begin
  # Expected: `_json_number_side(` appears outside `json_key_refusal.jl` only in the record writers
  # (two in `ctes.jl`, one in `projection_types.jl`). Why: a consumer that probes on its own decides
  # its own refusal, which is how the rule drifted one position at a time (#1531).
  hits = Dict{String,Int}()
  for (rel, _, line) in _jkr_code_lines()
    n = count("_json_number_side(", line)
    n > 0 && (hits[rel] = get(hits, rel, 0) + n)
  end
  @test hits == Dict(joinpath("querybuilder", "ctes.jl") => 2,               # _record_cte_division!, _record_cte_json_key!
                     joinpath("querybuilder", "projection_types.jl") => 1)  # _subquery_projection_json_key

  # Expected: no `isa CJSONValue` (alone or in a `Union`) outside the refusal point and the walk.
  # Why: "is this a key's value" is `_json_key_lookup_operand`'s question; a second copy is a second rule.
  stray = [(rel, i) for (rel, i, line) in _jkr_code_lines(exempt = [joinpath("querybuilder", "expression_kind.jl")])
           if occursin(r"isa\s+(Union\{[^}]*)?CJSONValue", line)]
  @test isempty(stray)
end

@testset "#1531 — the uncast-JSON-key refusal texts are written only at the refusal point" begin
  # Expected: none of the refusal phrases appears in code outside `json_key_refusal.jl`. Why: a position
  # that writes its own message is a position with its own rule — the pre-#1531 shape.
  # One phrase per message: #1483/#1491/#1497/#1510/#1506/#1528 share the first, #811 has the second,
  # and #1499's text splits "a JSON key's value" across a concatenation, so its operator list is its own.
  phrases = ("a JSON key's value has no", "JSON path lookup compares the extracted value",
             "compares only with =, @ne, @gt")
  stray = [(rel, i) for (rel, i, line) in _jkr_code_lines() if any(p -> occursin(p, line), phrases)]
  @test isempty(stray)
end

@testset "#1531 — every JSON-key position has one refusal, of the documented error type" begin
  # Expected: each concrete `_JSONKeyPosition` has a `_json_key_refusal` method, a carrier position on
  # `(position, side)` and a key position on `(position)`; build positions raise `QueryBuildError`,
  # filter positions `FilterError`. Why: a position added without its refusal would fall through to a
  # `MethodError` at query build — the loud failure this file exists to make impossible.
  side = ("the JSON key `metadata__wins`", "metadata__wins")
  build = Dict(
    _JKR_QB._JSONKeyArithmetic => _JKR_QB._JSONKeyArithmetic("`+`"),
    _JKR_QB._JSONKeyExtremum   => _JKR_QB._JSONKeyExtremum("Max"),
    _JKR_QB._JSONKeyOrdering   => _JKR_QB._JSONKeyOrdering("`order_by`", true),
    _JKR_QB._JSONKeyNullIf     => _JKR_QB._JSONKeyNullIf(1),
  )
  filter_side = Dict(_JKR_QB._JSONKeyCarrierFilter => _JKR_QB._JSONKeyCarrierFilter("wins", "="),
                     _JKR_QB._JSONKeyRightOperand  => _JKR_QB._JSONKeyRightOperand())
  filter_key = Dict(
    _JKR_QB._JSONKeyOperator  => _JKR_QB._JSONKeyOperator("IN", "metadata__wins"),
    _JKR_QB._JSONKeyColumnRHS => _JKR_QB._JSONKeyColumnRHS("metadata__wins"),
  )
  all_positions = Set(Iterators.flatten((keys(build), keys(filter_side), keys(filter_key))))
  declared = Set{Any}()
  pending = Any[_JKR_QB._JSONKeyPosition]
  while !isempty(pending)
    T = pop!(pending)
    sub = subtypes(T)
    isempty(sub) ? push!(declared, T) : append!(pending, sub)
  end
  @test declared == all_positions   # a new position must be added to this table, with its error type

  for (_, p) in build
    err = _JKR_QB._json_key_refusal(p, side)
    @test err isa PormG.QueryBuildError
    @test occursin("metadata__wins", err.msg)
  end
  for (_, p) in filter_side
    @test _JKR_QB._json_key_refusal(p, side) isa PormG.FilterError
  end
  for (_, p) in filter_key
    @test _JKR_QB._json_key_refusal(p) isa PormG.FilterError
  end
end

@testset "#1531 — a carrier filter exempts @isnull before the probe runs" begin
  # Expected: `_JSONKeyCarrierFilter` does not apply under `ISNULL` and applies under every comparison.
  # Why: `@isnull` binds nothing, so a carrier's untyped value cannot be misread there (#1506); the
  # exemption is the position's own rule, stated once instead of at each of its call sites.
  @test !_JKR_QB._json_key_position_applies(_JKR_QB._JSONKeyCarrierFilter("wins", "ISNULL"))
  for op in ("=", "!=", ">", ">=", "<", "<=")
    @test _JKR_QB._json_key_position_applies(_JKR_QB._JSONKeyCarrierFilter("wins", op))
  end
  @test _JKR_QB._json_key_position_applies(_JKR_QB._JSONKeyArithmetic("`+`"))
end
