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
    # #239 completion: schema, configuration and migration errors, plus the four
    # pre-existing standalone types reparented under the taxonomy.
    PormG.FieldValidationError, PormG.ModelDefinitionError,
    PormG.InvalidConfigurationError, PormG.InvalidMigrationError,
    PormG.PoolTimeoutError, PormG.PoolConnectError,
    PormG.Configuration.MissingDatabaseConfigurationException,
    PormG.Migrations.DestructiveMigrationError,
)

# The abstract mid-nodes. Each groups its concrete leaves so `catch <node>` has no holes.
const TAXONOMY_ABSTRACT = (
    PormG.FieldAccessError, PormG.ConfigurationError, PormG.MigrationError,
)

@testset "Error taxonomy (#231, #239)" begin

    @testset "root and hierarchy" begin
        @test PormG.PormGError <: Exception
        # every concrete subtype is under the root
        for T in TAXONOMY_TYPES
            @test T <: PormG.PormGError
        end
        # every abstract mid-node is under the root too
        for T in TAXONOMY_ABSTRACT
            @test T <: PormG.PormGError
            @test isabstracttype(T)
        end
        # the field-access mid-node groups the two field-lookup errors, so
        # `catch FieldAccessError` catches both "no such field" and "no lazy traversal".
        @test PormG.UnknownFieldError <: PormG.FieldAccessError
        @test PormG.LazyTraversalError <: PormG.FieldAccessError
        # get() cardinality errors were reparented from Exception to PormGError.
        @test PormG.DoesNotExist <: PormG.PormGError
        @test PormG.MultipleObjectsReturned <: PormG.PormGError
    end

    @testset "mid-nodes have no holes (#239)" begin
        # ConfigurationError / MigrationError are abstract precisely so the pre-existing
        # standalone types sit INSIDE the bucket rather than beside it. A user who writes
        # `catch ConfigurationError` must not miss a missing connection.yml — that class of
        # surprise is what this taxonomy exists to remove. Concrete buckets would have made
        # these subtypings impossible ("can only subtype abstract types").
        @test PormG.InvalidConfigurationError <: PormG.ConfigurationError
        @test PormG.Configuration.MissingDatabaseConfigurationException <: PormG.ConfigurationError
        @test PormG.InvalidMigrationError <: PormG.MigrationError
        @test PormG.Migrations.DestructiveMigrationError <: PormG.MigrationError

        # Reparented from bare `Exception` (#239) so `catch PormGError` covers the pool too.
        @test PormG.PoolTimeoutError <: PormG.PormGError
        @test PormG.PoolConnectError <: PormG.PormGError

        # …and the buckets stay disjoint: a config error is not a migration error.
        @test !(PormG.InvalidConfigurationError <: PormG.MigrationError)
        @test !(PormG.InvalidMigrationError <: PormG.ConfigurationError)
    end

    @testset "clean break — NOT <: ArgumentError" begin
        # The whole point of #231: callers stop catching ArgumentError. Pin the clean break
        # so a future accidental `PormGError <: ArgumentError` fails loudly here.
        for T in TAXONOMY_TYPES
            @test !(T <: ArgumentError)
        end
        for T in TAXONOMY_ABSTRACT
            @test !(T <: ArgumentError)
        end
        @test !(PormG.PormGError <: ArgumentError)
    end

    @testset "exported bare after `using PormG`" begin
        # Each name resolves unqualified (exported) and points at the same binding. Since #239
        # the types are defined in `Kernel`, and `QueryBuilder` imports them from `PormG` — so
        # this also pins that there is exactly ONE set of types, not a shadowed second copy.
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
        @test FieldValidationError === PormG.FieldValidationError
        @test ModelDefinitionError === PormG.ModelDefinitionError
        @test ConfigurationError === PormG.ConfigurationError
        @test InvalidConfigurationError === PormG.InvalidConfigurationError
        @test MigrationError === PormG.MigrationError
        @test InvalidMigrationError === PormG.InvalidMigrationError

        # QueryBuilder must see the SAME objects it imported, not redefinitions.
        @test QB.QueryBuildError === PormG.QueryBuildError
        @test QB.DoesNotExist === PormG.DoesNotExist
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
