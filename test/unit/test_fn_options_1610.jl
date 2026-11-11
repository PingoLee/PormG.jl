# =============================================================================
# The function renderers' options: `Dialect.FnOptions`, one typed slot per key (#1610)
#
# The Dialect renderers took their options as a `format::Dict{String,Any}`; since #1610 they take
# `FnOptions`, built once from a node's resolved options at `QueryBuilder._function_sql`. The builders
# store a value of the right type for every key, but a node's options are a mutable `Dict` a caller can
# edit by hand, so the one boundary refuses a value of a type no renderer takes, naming the option and
# never the value (#971).
#
# Hermetic: no connection.
# =============================================================================
# julia --project=test/integration test/unit/test_fn_options_1610.jl

using Test
using PormG
import PormG: Dialect, InvalidValueError, CInt32
isdefined(Main, :SQLite) || include(joinpath(@__DIR__, "..", "load_drivers.jl"))

const _FO_BOOL_KEYS = ("distinct", "bigint", "integer", "boolean", "decimal_operand", "empty_fill",
                       "propagate_null", "cover_density")
const _FO_STRING_KEYS = ("output_field", "then", "else", "type", "part", "format", "config", "combinator",
                         "search_type", "weight")

_fo_err(kv::Pair) = try Dialect.FnOptions(kv); nothing catch e; e end

# ─────────────────────────────────────────────────────────────────────────────
# Tests: every one of the 23 keys, holding a value of a type no renderer takes.
# Expected: `InvalidValueError` naming the key (the two FTS keys keep #31/#1021's own refusal text),
# and never the value.
# Matters: a hand-edited node is refused at the boundary, as each renderer refused it before #1610. A
# boolean key read `=== true` used to take a non-`Bool` as `false` and render as if unset.
# ─────────────────────────────────────────────────────────────────────────────
@testset "a wrongly typed value is refused for every FnOptions key (#1610)" begin
    hostile = "1); DROP TABLE driver; --"
    cases = Pair{String,Any}[]
    for k in _FO_BOOL_KEYS
        push!(cases, k => 1, k => "true", k => nothing)
    end
    for k in _FO_STRING_KEYS
        push!(cases, k => 1, k => :plain)
    end
    push!(cases, "integer_kind" => "int", "temporal_kind" => "date", "precision" => 1.5,
          "precision" => nothing, "weights" => hostile, "normalization" => hostile)
    @test length(unique(first.(cases))) == 23
    for kv in cases
        err = _fo_err(kv)
        @test err isa InvalidValueError
        msg = sprint(showerror, err)
        if first(kv) in ("weights", "normalization")
            @test occursin(first(kv), msg)
        else
            @test occursin("`$(first(kv))`", msg)
        end
        @test !occursin("DROP TABLE", msg)
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# Tests: the values the builders store.
# Expected: a boolean key reads `true`/`false`, and absent as `false`; a string key keeps its text;
# `precision` takes an integer or its rendered SQL; `search_type` defaults to "plain".
# Matters: the refusal above must not refuse what a builder writes.
# ─────────────────────────────────────────────────────────────────────────────
@testset "FnOptions reads every value a builder stores (#1610)" begin
    for k in _FO_BOOL_KEYS
        s = Symbol(k)
        @test getfield(Dialect.FnOptions(k => true), s) === true
        @test getfield(Dialect.FnOptions(k => false), s) === false
        @test getfield(Dialect.FnOptions(), s) === false
    end
    o = Dialect.FnOptions("then" => "1", "else" => "0", "type" => "integer", "precision" => 2,
                          "integer_kind" => CInt32(), "temporal_kind" => :date, "normalization" => true,
                          "weights" => [0.1, 0.2, 0.4, 1.0])
    @test (o.then, o.else_, o.type, o.precision) == ("1", "0", "integer", 2)
    @test o.integer_kind isa CInt32 && o.temporal_kind === :date
    @test o.normalization == 1          # `true` is the bitmask 1, as SEARCH_RANK took it (#31)
    @test o.weights == [0.1, 0.2, 0.4, 1.0]
    @test Dialect.FnOptions("precision" => "\$1").precision == "\$1"
    @test Dialect.FnOptions().search_type == "plain"
end
