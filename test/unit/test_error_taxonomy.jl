"""
Semantic error taxonomy contract (#231).

Pins the SHAPE of the `PormGError` taxonomy — the abstract root, the `FieldAccessError`
mid-node, subtype membership, the `get()`-cardinality reparenting, and the deliberate clean
break (subtypes are NOT `<: ArgumentError`). A representative fluent-surface misuse per bucket
confirms the right subtype is thrown; deeper behavioral coverage lives in the subsystem
integration tests (test_row_and_get, test_cjoin, test_deletes, …).

No database required: every assertion fires at query-build/validation time.
"""
# julia -t auto --project=. test/unit/test_error_taxonomy.jl

using Test
using PormG
using PormG.Models
using PormG.QueryBuilder: object, Q, Qor, With

const QB = PormG.QueryBuilder

# Every concrete member of the taxonomy (the two get()-cardinality types included).
const TAXONOMY_TYPES = (
    PormG.UnknownFieldError, PormG.LazyTraversalError, PormG.FilterError,
    PormG.QueryBuildError, PormG.UnsafeMutationError, PormG.InvalidValueError,
    PormG.PermissionError, PormG.UnsupportedConnectionError,
    PormG.DoesNotExist, PormG.MultipleObjectsReturned,
)

@testset "Error taxonomy (#231)" begin

    @testset "root and hierarchy" begin
        @test PormG.PormGError <: Exception
        @test PormG.FieldAccessError <: PormG.PormGError
        # every concrete subtype is under the root
        for T in TAXONOMY_TYPES
            @test T <: PormG.PormGError
        end
        # the field-access mid-node groups the two field-lookup errors, so
        # `catch FieldAccessError` catches both "no such field" and "no lazy traversal".
        @test PormG.UnknownFieldError <: PormG.FieldAccessError
        @test PormG.LazyTraversalError <: PormG.FieldAccessError
        # get() cardinality errors were reparented from Exception to PormGError.
        @test PormG.DoesNotExist <: PormG.PormGError
        @test PormG.MultipleObjectsReturned <: PormG.PormGError
    end

    @testset "clean break — NOT <: ArgumentError" begin
        # The whole point of #231: callers stop catching ArgumentError. Pin the clean break
        # so a future accidental `PormGError <: ArgumentError` fails loudly here.
        for T in TAXONOMY_TYPES
            @test !(T <: ArgumentError)
        end
        @test !(PormG.PormGError <: ArgumentError)
        @test !(PormG.FieldAccessError <: ArgumentError)
    end

    @testset "exported bare after `using PormG`" begin
        # Each name resolves unqualified (exported) and points at the QueryBuilder binding.
        @test PormGError === PormG.PormGError
        @test FieldAccessError === PormG.FieldAccessError
        @test UnknownFieldError === PormG.UnknownFieldError
        @test LazyTraversalError === PormG.LazyTraversalError
        @test FilterError === PormG.FilterError
        @test QueryBuildError === PormG.QueryBuildError
        @test UnsafeMutationError === PormG.UnsafeMutationError
        @test InvalidValueError === PormG.InvalidValueError
        @test PermissionError === PormG.PermissionError
        @test UnsupportedConnectionError === PormG.UnsupportedConnectionError
    end

    # A model with no connection is enough — every assertion below fires at
    # build/validation time, before any DB work.
    taxo_model = Models.Model_Type(
        name = "taxonomy_test",
        fields = Dict("id" => Models.IDField(), "points" => Models.IntegerField()),
        field_names = ["id", "points"],
    )

    @testset "representative misuse → specific subtype" begin
        # FilterError: a bad filter argument (Int is not a Pair/Q/Qor/operator).
        @test_throws PormG.FilterError object(taxo_model).filter(123)
        # QueryBuildError: projection-shape misuse (operator suffix in a projection).
        @test_throws PormG.QueryBuildError object(taxo_model).values("points__@gte")
        # UnsupportedConnectionError: a connection that is neither PG nor SQLite.
        @test_throws PormG.UnsupportedConnectionError QB._unsupported_conn("op", nothing)
    end

    @testset "showerror renders the message; catch the root works" begin
        e = PormG.FilterError("bad filter arg")
        @test occursin("bad filter arg", sprint(showerror, e))
        # A caller can catch the abstract root regardless of the specific subtype.
        caught = try; object(taxo_model).filter(123); catch err; err; end
        @test caught isa PormG.PormGError
        @test caught isa PormG.FilterError
    end
end
