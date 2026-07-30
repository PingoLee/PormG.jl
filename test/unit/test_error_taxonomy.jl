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
using InteractiveUtils: subtypes   # walk the taxonomy by TYPE, not by export list
using PormG
using PormG.Models
using PormG.QueryBuilder: object, Q, Qor, With

const QB = PormG.QueryBuilder

# Every concrete member of the taxonomy (the two get()-cardinality types included).
const TAXONOMY_TYPES = (
    PormG.UnknownFieldError, PormG.LazyTraversalError, PormG.FilterError,
    PormG.QueryBuildError, PormG.UnsafeMutationError, PormG.InvalidValueError,
    PormG.WritesDisabledError, PormG.UnsupportedConnectionError,
    # #268 audit: capability limits split out of UnsupportedConnectionError; PROTECT-delete refusal
    # split out of the QueryBuildError long tail.
    PormG.BackendCapabilityError, PormG.ProtectedError,
    PormG.DoesNotExist, PormG.MultipleObjectsReturned,
    # #239 completion: schema, configuration and migration errors, plus the four
    # pre-existing standalone types reparented under the taxonomy.
    PormG.FieldValidationError, PormG.ModelDefinitionError,
    PormG.InvalidConfigurationError, PormG.InvalidMigrationError,
    PormG.PoolTimeoutError, PormG.PoolConnectError,
    PormG.Configuration.MissingConfigurationError,
    PormG.Migrations.DestructiveMigrationError,
)

# The abstract mid-nodes. Each groups its concrete leaves so `catch <node>` has no holes.
const TAXONOMY_ABSTRACT = (
    PormG.FieldAccessError, PormG.ConfigurationError, PormG.MigrationError,
    # #261: the pool errors were the only concrete subtypes with neither a Kernel home nor an
    # abstract supertype in Kernel. `PoolError` closes that gap.
    PormG.PoolError,
    # #268 audit: definition-time umbrella — one include("models.jl") can raise either member.
    PormG.DefinitionError,
)

# Walk the real type tree. `names(PormG)` only sees EXPORTED names, which silently omits
# `Configuration.MissingConfigurationError` and `Migrations.DestructiveMigrationError` —
# the two types that live mid-include-chain, i.e. exactly the ones a placement guard must inspect.
function _concrete_pormg_errors(T = PormG.PormGError, acc = Any[])
    for S in subtypes(T)
        isabstracttype(S) ? _concrete_pormg_errors(S, acc) : push!(acc, S)
    end
    return acc
end

@testset "Error taxonomy (#231, #239)" begin

    # TAXONOMY_TYPES is hand-maintained, and every testset below iterates it — so if it drifts out
    # of sync with the real hierarchy, all of them narrow silently instead of failing. Pin it to the
    # type tree so adding a subtype without listing it here is a test failure, not a coverage hole.
    @testset "TAXONOMY_TYPES is the whole taxonomy (#262)" begin
        @test Set(TAXONOMY_TYPES) == Set(_concrete_pormg_errors())
    end

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
        @test PormG.Configuration.MissingConfigurationError <: PormG.ConfigurationError
        @test PormG.InvalidMigrationError <: PormG.MigrationError
        @test PormG.Migrations.DestructiveMigrationError <: PormG.MigrationError

        # #268 audit: the definition-time pair grouped under one umbrella, and the write-switch
        # error reparented under ConfigurationError (its remedy is a connection.yml edit).
        @test PormG.FieldValidationError <: PormG.DefinitionError
        @test PormG.ModelDefinitionError <: PormG.DefinitionError
        @test PormG.WritesDisabledError <: PormG.ConfigurationError
        @test !(PormG.DefinitionError <: PormG.ConfigurationError)

        # Reparented from bare `Exception` (#239) so `catch PormGError` covers the pool too,
        # then grouped under the `PoolError` umbrella (#261) so `catch PoolError` handles
        # saturation and connect failure without naming each.
        @test PormG.PoolTimeoutError <: PormG.PormGError
        @test PormG.PoolConnectError <: PormG.PormGError
        @test PormG.PoolTimeoutError <: PormG.PoolError
        @test PormG.PoolConnectError <: PormG.PoolError
        # …and PoolError stays disjoint from the other umbrellas.
        @test !(PormG.PoolError <: PormG.ConfigurationError)
        @test !(PormG.InvalidConfigurationError <: PormG.PoolError)

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
        @test WritesDisabledError === PormG.WritesDisabledError
        @test UnsupportedConnectionError === PormG.UnsupportedConnectionError
        @test FieldValidationError === PormG.FieldValidationError
        @test ModelDefinitionError === PormG.ModelDefinitionError
        @test ConfigurationError === PormG.ConfigurationError
        @test InvalidConfigurationError === PormG.InvalidConfigurationError
        @test MigrationError === PormG.MigrationError
        @test InvalidMigrationError === PormG.InvalidMigrationError
        @test PoolError === PormG.PoolError
        @test error_message === PormG.error_message

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

    # ─────────────────────────────────────────────────────────────────────────
    # #268 audit reclassifications: each gets ONE discriminating representative, because a
    # supertype assertion (isa PormGError) passes for the pre-audit type too and proves nothing.
    # ─────────────────────────────────────────────────────────────────────────
    @testset "audit reclassifications raise their promised types (#268)" begin
        # Missing driver: every backend generic funnels to InvalidConfigurationError. This cannot
        # be probed by plain dispatch in the suite: load_drivers.jl loads BOTH extensions, and the
        # SQLite ext types some methods on the ABSTRACT PormGSQLite with fixed arity — which
        # shadows the fallback for one-argument calls entirely (even via `invoke`). The extra
        # positional argument below matches ONLY the varargs fallback, so this pins the fallback
        # method's behavior deterministically with or without any driver loaded.
        struct _DriverlessSQLite <: PormG.PormGSQLite end
        err = try
            PormG.backend_connect(_DriverlessSQLite(), :force_varargs_fallback)
            nothing
        catch e; e; end
        @test err isa PormG.InvalidConfigurationError
        @test occursin("using SQLite", PormG.error_message(err))

        # Config entry exists but its pool was never built → typed, not a downstream MethodError.
        PormG.config["docerr_nopool"] = PormG.Configuration.Settings(change_data = true)
        nopool = Models.Model_Type(name = "np_probe",
            fields = Dict("id" => Models.IDField()), field_names = ["id"])
        nopool.connect_key = "docerr_nopool"
        err = try; object(nopool).filter("id" => 1).list(show_query = :dict); nothing; catch e; e; end
        @test err isa PormG.InvalidConfigurationError
        @test occursin("no pool yet", PormG.error_message(err))

        # SQLite too old for window functions → BackendCapabilityError (capability, not dispatch).
        struct _OldSQLite_Taxo <: PormG.PormGSQLite end
        PormG.backend_sqlite_version(::_OldSQLite_Taxo) = 3024000
        err = try; PormG.Dialect._assert_sqlite_window_support(_OldSQLite_Taxo()); nothing; catch e; e; end
        @test err isa PormG.BackendCapabilityError
        @test occursin("3.25.0", PormG.error_message(err))

        # Migration engine: no pending plan / unparseable introspected DDL → InvalidMigrationError.
        mktempdir() do d
            st = PormG.Configuration.Settings(change_data = true)
            st.db_def_folder = d
            err = try; PormG.Migrations._load_migration_plan(st); nothing; catch e; e; end
            @test err isa PormG.InvalidMigrationError
            @test occursin("No pending migrations", PormG.error_message(err))
        end
        err = try; PormG.Migrations.convertSQLToModel("CREATE TABLE noquotes (x INTEGER)"); nothing; catch e; e; end
        @test err isa PormG.InvalidMigrationError
    end

    @testset "representative misuse → specific subtype" begin
        # FilterError: a bad filter argument (Int is not a Pair/Q/Qor/operator).
        @test_throws PormG.FilterError object(taxo_model).filter(123)
        # QueryBuildError: projection-shape misuse (operator suffix in a projection).
        @test_throws PormG.QueryBuildError object(taxo_model).values("points__@gte")
        # UnsupportedConnectionError: a connection that is neither PG nor SQLite. Asserted with
        # `isa`, not `@test_throws … throw(…)` — the latter reduces to `@test_throws T throw(T(…))`,
        # which passes whether the funnel returns OR throws, so it says nothing about the #262
        # convention it was edited for. test_typed_exceptions.jl pins the returning behavior.
        @test QB._unsupported_conn("op", nothing) isa PormG.UnsupportedConnectionError
    end

    # ─────────────────────────────────────────────────────────────────────────
    # error_message: one accessor for every subtype (#261)
    # `api.md` and `UPGRADING.md` both tell callers to `catch PormGError`. The obvious next line
    # is `e.msg`, which throws on the four subtypes built from structured fields. `error_message`
    # is the uniform reader; this pins that it works for EVERY concrete member, so a subtype added
    # later cannot quietly reintroduce the gap.
    # ─────────────────────────────────────────────────────────────────────────
    @testset "error_message covers every concrete subtype (#261)" begin
        # A representative instance per concrete type. The four structured ones are constructed
        # through their real field signatures precisely because they have no `msg`.
        samples = Any[
            PormG.DoesNotExist("Driver", "(driverref = \"senna\")"),
            PormG.MultipleObjectsReturned("Driver", 3, "(nationality = \"British\")"),
            PormG.PoolTimeoutError("SQLite", 1, 10, 3, 1.5),
            PormG.PoolConnectError("SQLite", "disk I/O error", "f1.sqlite", 2, 0.5),
            # carries the blocked statements alongside its message
            PormG.Migrations.DestructiveMigrationError("boom", ["DROP TABLE \"drivers\""]),
        ]
        for T in TAXONOMY_TYPES
            # the msg-carrying majority share one constructor shape
            T in (PormG.DoesNotExist, PormG.MultipleObjectsReturned,
                  PormG.PoolTimeoutError, PormG.PoolConnectError,
                  PormG.Migrations.DestructiveMigrationError) && continue
            push!(samples, T("boom"))
        end

        for e in samples
            msg = PormG.error_message(e)
            @test msg isa String
            @test !isempty(msg)
        end

        # Shape-only checks above would survive an `error_message` that returned, say, the type
        # name. Assert the actual text reaches the caller for every sample built from a known
        # message — that is the contract, and it is knowable.
        for T in TAXONOMY_TYPES
            T in (PormG.DoesNotExist, PormG.MultipleObjectsReturned,
                  PormG.PoolTimeoutError, PormG.PoolConnectError,
                  PormG.Migrations.DestructiveMigrationError) && continue
            @test occursin("boom", PormG.error_message(T("boom")))
        end

        # For the structured types `.msg` does not exist — that is the whole reason this accessor
        # exists. Assert on the FIELD SET rather than `@test_throws Exception …msg`: the latter also
        # matches a MethodError from a changed constructor arity, so it could pass while the thing
        # it documents had moved.
        for T in (PormG.PoolTimeoutError, PormG.PoolConnectError,
                  PormG.DoesNotExist, PormG.MultipleObjectsReturned)
            @test :msg ∉ fieldnames(T)
        end

        # For subtypes using the GENERIC showerror it is exactly `e.msg` — the accessor is a
        # drop-in replacement, not a reformatting.
        e = PormG.FilterError("bad filter arg")
        @test PormG.error_message(e) == e.msg

        # For subtypes with their OWN showerror it is a superset: they carry a `msg` but render it
        # with the error name prefixed. Pinned because the docs promise `error_message` never
        # returns *less* than `.msg` — a future showerror that dropped the message would break that
        # promise silently.
        for e2 in (PormG.Configuration.MissingConfigurationError("no connection.yml"),
                   PormG.Migrations.DestructiveMigrationError("refused", ["DROP TABLE \"drivers\""]))
            # `occursin` already implies the result is no shorter, so one assertion suffices.
            @test occursin(e2.msg, PormG.error_message(e2))
        end

        # And it reflects the structured fields rather than a placeholder.
        @test occursin("SQLite", PormG.error_message(PormG.PoolTimeoutError("SQLite", 1, 10, 3, 1.5)))
        @test occursin("Driver", PormG.error_message(PormG.DoesNotExist("Driver", "(id = 1)")))
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
