"""
Kernel layering contract.

Pins the two structural facts the `PormG.Kernel` extraction exists to guarantee. Both are
invisible to every other test in the suite — the failure modes they guard show up as a
mysterious `UndefVarError` during precompilation, or as an error that only fires when a user
runs `using LibPQ`.

No database required.
"""
# julia -t auto --project=. test/unit/test_kernel_layering.jl

using Test
using PormG

@testset "Kernel layering" begin

    @testset "shared vocabulary is owned by Kernel (layer 1)" begin
        # The whole point of the extraction: vocabulary is defined BEFORE any submodule is
        # included, so `Models` / `Configuration` / `Dialect` can name it regardless of their
        # own position in the include chain. If someone moves these back into the PormG module
        # body, they land after Configuration(4)/ConnectionPool(6)/Models(7) again and the next
        # shared-vocabulary addition breaks with an UndefVarError at precompile time.
        @test parentmodule(PormG.PormGError) === PormG.Kernel
        @test parentmodule(PormG.PormGModel) === PormG.Kernel
        @test parentmodule(PormG.PormGField) === PormG.Kernel
        @test parentmodule(PormG._emsg) === PormG.Kernel

        # Kernel must not reach back into PormG — that is what makes it safe to include first.
        # `using PormG` inside Kernel would create the cycle this design removes.
        @test !isdefined(PormG.Kernel, :PormG)
    end

    # ─────────────────────────────────────────────────────────────────────────
    # The layering RULE, not today's inventory (#261, #262)
    # The assertions above pin four names by hand, so they only catch a regression in those four.
    # This derives the check from the export list instead, so a taxonomy type added later is
    # covered without anyone remembering to extend a list — the same "assert the invariant, not
    # the inventory" approach as the #259 drift guards.
    #
    # The rule: every concrete PormGError subtype either lives in Kernel, or has a DEDICATED
    # Kernel-owned abstract umbrella above it. Nothing may sit mid-include-chain as a bare child
    # of the root — that is exactly the shape that made #239 need the Kernel extraction, and it
    # recurred with PoolTimeoutError / PoolConnectError until #261 added `PoolError`.
    #
    # "Dedicated" is load-bearing: `PormGError` itself is always Kernel-owned, so accepting any
    # Kernel-parented supertype would make this check vacuous — it would pass for every subtype
    # ever, including the violation it exists to catch. Verified by mutation: reverting
    # PoolTimeoutError to `<: PormGError` must fail this testset.
    # ─────────────────────────────────────────────────────────────────────────
    @testset "every taxonomy type is reachable from Kernel (#261)" begin
        offenders = String[]
        checked = 0
        for n in names(PormG)
            T = try getfield(PormG, n) catch; continue end
            (T isa Type && T <: Exception && !isabstracttype(T)) || continue
            checked += 1
            parentmodule(T) === PormG.Kernel && continue
            S = supertype(T)
            (S !== PormG.PormGError && parentmodule(S) === PormG.Kernel) && continue
            push!(offenders, "$(n): defined in $(parentmodule(T)), supertype $(S) " *
                             "in $(parentmodule(S))")
        end

        if !isempty(offenders)
            @error """
            Exported exception type(s) reachable from neither Kernel nor a Kernel-owned umbrella.
            Define the type in src/exceptions.jl (Kernel), or give it an abstract supertype there —
            the pattern ConfigurationError / MigrationError / PoolError already follow. A type left
            mid-include-chain cannot be named by any submodule included before it.
            """ offenders
        end
        @test isempty(offenders)

        # Guard the guard: if the export list or the filter ever stops matching anything, the loop
        # above passes vacuously. There are 16 concrete exported exception types as of #261.
        @test checked >= 16
    end

    @testset "backend generics stay owned by PormG (layer 2)" begin
        # ext/PormGLibPQExt.jl and ext/PormGSQLiteExt.jl define their methods as
        # `PormG.backend_execute(...) = ...`. Julia only accepts a qualified method definition
        # on the module that OWNS the binding, so moving these generics into Kernel breaks every
        # extension method with "function Kernel.backend_execute must be explicitly imported to
        # be extended" — and it fails at `using LibPQ` / `using SQLite`, NOT at `using PormG`,
        # so precompiling the package would not catch it. This assertion would.
        for fn in (:backend_connect, :backend_renew_connection, :backend_is_alive,
                   :backend_execute, :backend_execute_async, :backend_is_connection_error,
                   :backend_is_permanent_connect_error, :backend_num_affected_rows,
                   :backend_num_rows, :backend_copy_in!, :backend_sqlite_version)
            @test parentmodule(getfield(PormG, fn)) === PormG
        end
    end

    @testset "public surface is unaffected by where a name is defined" begin
        # `using .Kernel` binds Kernel's exports in PormG without re-exporting them, so PormG's
        # own `export` list stays the single definition of the public surface. Spot-check the
        # one public name that actually moved modules (it is defined in constants.jl, which
        # Kernel now includes) — it must still be exported bare by `using PormG`.
        @test :register_ignore_tables! in names(PormG)
        @test parentmodule(PormG.register_ignore_tables!) === PormG.Kernel
    end

end
