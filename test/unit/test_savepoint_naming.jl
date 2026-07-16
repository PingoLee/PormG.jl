# ==============================================================================
# UNIT TEST: Deterministic savepoint naming (#26)
#
# `_savepoint_name(depth)` builds the fixed `pormg_sp_<int>` identifier used by the reentrant
# run_in_transaction / atomic savepoint path. The fixed prefix + integer suffix means the name
# is never user-controlled (safe to interpolate as a SQL identifier), and keying it on the
# transaction nesting depth makes savepoint names unique and LIFO-safe across nesting levels.
#
# Pure function — no database, no mocks.
# ==============================================================================

using Test
using PormG

@testset "Savepoint naming (#26)" begin
    # Exact format for representative depths.
    @test PormG.ConnectionPool._savepoint_name(1) == "pormg_sp_1"
    @test PormG.ConnectionPool._savepoint_name(2) == "pormg_sp_2"
    @test PormG.ConnectionPool._savepoint_name(10) == "pormg_sp_10"

    # Fixed prefix + integer suffix only → no identifier-injection surface.
    for d in 1:6
        name = PormG.ConnectionPool._savepoint_name(d)
        @test startswith(name, "pormg_sp_")
        @test occursin(r"^pormg_sp_\d+$", name)
    end

    # Distinct depths yield distinct names (uniqueness across nesting levels).
    names = [PormG.ConnectionPool._savepoint_name(d) for d in 1:6]
    @test length(unique(names)) == 6
end
