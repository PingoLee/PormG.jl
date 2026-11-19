# test/unit/test_untyped_read_order_1599.jl
#
#   julia --project=test/integration test/unit/test_untyped_read_order_1599.jl
#
# #1599 layer 6: the untyped read's decoder (`_ProjectionRowDecoder`) against the old read, `_rows_from_result` with the
# same parsers, on a MySQL result built in memory (`MySQLResult` is the extension's own materialized type, so no server
# is needed). The integration file `test/integration/test_untyped_read_equivalence_1599.jl` compares the two on every
# engine against real results; this one pins what a real result rarely shows: the order a parser's error fires in.

using Test
isdefined(Main, :SQLite) || include(joinpath(@__DIR__, "..", "load_drivers.jl"))
using PormG
using PormG.Decimals: Decimal

const _UO_QB = PormG.QueryBuilder
const _UO_X = Base.get_extension(PormG, :PormGMySQLExt)

# A declared `numeric(3, 1)` read parser labelled `label`: it refuses a value that needs more than 2 integer digits.
_uo_decimal(label::String) = PormG.ReadParser(PormG._RP_MYSQL_DECLARED_DECIMAL, 3, 1, nothing, label)

function _uo_decoder(parsers::Dict{Symbol,PormG.ReadParser})
  functions = Dict{Symbol,Function}(k => PormG._as_function(v)::Function for (k, v) in parsers)
  return _UO_QB._ProjectionRowDecoder(parsers, functions, Base.RefValue{Union{Nothing,Exception}}(nothing))
end

_uo_caught(f) = try f(); nothing catch e; e end

@testset "the untyped read keeps the old read's rows and error order on MySQL (#1599 layer 6)" begin
  # What: a 13-column MySQL result (more keys than a `Dict`'s first table holds), with missing cells, untyped and
  #   decimal columns and two parsed ones, read by the decoder and by `_rows_from_result`.
  # Expected: the same rows: keys in the same iteration order, the same values of the same types.
  # Why: the decoder replaces `_rows_from_result` on MySQL, which filled each row sized to the column count, column
  #   by column; a row filled any other way can iterate its keys in another order.
  names = Symbol[Symbol("c", i) for i in 1:11]
  push!(names, :a, :b)
  cols = AbstractVector[]
  for i in 1:11
    push!(cols, isodd(i) ? Union{Missing,Int64}[i, missing] : Any["x$(i)", 2.5])
  end
  push!(cols, [Decimal(1.5), Decimal(2.5)], [Decimal(10.5), missing])
  result = _UO_X.MySQLResult(names, cols, 2, 0, UInt64(0), "")
  d = _uo_decoder(Dict{Symbol,PormG.ReadParser}(:a => _uo_decimal("a"), :b => _uo_decimal("b")))
  old = _UO_QB._rows_from_result(result, d.functions)
  new = d(result)
  @test length(old) == length(new) == 2
  for (x, y) in zip(old, new)
    @test collect(keys(x)) == collect(keys(y))
    @test all(k -> typeof(x[k]) === typeof(y[k]) && isequal(x[k], y[k]), keys(x))
  end

  # What: two declared-decimal cells that both overflow, `a` on row 2 and `b` on row 1.
  # Expected: the same error type and text as the old read, which filled column by column and so raised on `a`.
  # Why: a row-by-row fill would raise on `b` first: the same type, but another label in the message.
  result = _UO_X.MySQLResult([:a, :b], AbstractVector[[Decimal(1.0), Decimal(1000.0)], [Decimal(1000.0), Decimal(1.0)]],
                             2, 0, UInt64(0), "")
  d = _uo_decoder(Dict{Symbol,PormG.ReadParser}(:a => _uo_decimal("a"), :b => _uo_decimal("b")))
  e_old = _uo_caught(() -> _UO_QB._rows_from_result(result, d.functions))
  e_new = _uo_caught(() -> d(result))
  @test e_old !== nothing
  @test typeof(e_new) === typeof(e_old)
  @test sprint(showerror, e_new) == sprint(showerror, e_old)
end
