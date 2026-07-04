# ============================================================
# test/unit/test_bulk_param_limit.jl
#
# Parameter-limit-aware chunking (#84).
#
# CONTRACT being tested:
#   Bulk insert/update flush `chunk_rows × ncols` bind parameters per statement.
#   Backends cap that per statement (PostgreSQL 65535; SQLite 999 before v3.32.0,
#   32766 from v3.32.0 on). The effective chunk must be derived from the column
#   count and the backend ceiling so a wide table (PG) or the SQLite 999 build no
#   longer overflows the driver at the default chunk_size. When a single row cannot
#   fit under the limit no matter the chunk size, the helper must fail closed with an
#   actionable error naming the limit — never silently truncate.
#
# These are pure-function tests of the chunking math: they take the backend limit as
# an argument, so they gate BOTH backends' ceilings without a live database and fail
# the moment the cap is reverted.
# ============================================================

using Test
using PormG

# Internal helpers live in the QueryBuilder submodule (execution_bulk.jl), unexported.
const _sqlite_param_limit    = PormG.QueryBuilder._sqlite_param_limit
const _effective_chunk_size  = PormG.QueryBuilder._effective_chunk_size

@testset "Bulk parameter-limit-aware chunking (#84)" begin

    # ─────────────────────────────────────────────────────────────────────────
    # SQLite variable-limit version boundary.
    # SQLITE_MAX_VARIABLE_NUMBER default jumped 999 → 32766 at v3.32.0 (packed
    # integer 3032000). The helper is a pure function of the packed version so the
    # exact boundary is provable without an old SQLite build.
    # ─────────────────────────────────────────────────────────────────────────
    @testset "SQLite param limit tracks the 3.32.0 boundary" begin
        @test _sqlite_param_limit(3031999) == 999      # 3.31.x → old default
        @test _sqlite_param_limit(3032000) == 32766    # exactly 3.32.0 → new default
        @test _sqlite_param_limit(3039000) == 32766    # 3.39.0 → new default
        @test _sqlite_param_limit(3000000) == 999      # very old
    end

    # ─────────────────────────────────────────────────────────────────────────
    # Effective chunk = min(requested, fld(limit - fixed, per_row)).
    # ─────────────────────────────────────────────────────────────────────────
    @testset "Effective chunk caps to the bind-parameter budget" begin
        # PostgreSQL, wide table (66 columns) at the default chunk_size: 66 × 1000 =
        # 66000 > 65535 pre-fix. The cap must bring it to fld(65535, 66) = 992
        # (66 × 993 = 65538 would overflow).
        @test _effective_chunk_size(1000, 66, 0, 65535, :bulk_insert, "PostgreSQL") == 992

        # SQLite old build (limit 999), single-column table: 1 × 1000 = 1000 > 999.
        # Cap must land at exactly 999, one below the requested 1000.
        @test _effective_chunk_size(1000, 1, 0, 999, :bulk_insert, "SQLite") == 999

        # No cap needed: 8 columns on the modern SQLite build (32766) fits 1000 rows
        # (8 × 1000 = 8000 < 32766) → the requested chunk_size passes through untouched.
        @test _effective_chunk_size(1000, 8, 0, 32766, :bulk_insert, "SQLite") == 1000

        # Cap needed: a larger requested chunk on the same table gets trimmed to
        # fld(32766, 8) = 4095.
        @test _effective_chunk_size(5000, 8, 0, 32766, :bulk_insert, "SQLite") == 4095

        # Degenerate requested chunk (0 or negative) must NOT collapse to a single
        # un-chunked statement — the cap stays unconditional at the backend-safe max.
        @test _effective_chunk_size(0,  8, 0, 32766, :bulk_insert, "SQLite") == 4095
        @test _effective_chunk_size(-5, 8, 0, 32766, :bulk_insert, "SQLite") == 4095

        # Defensive branch: nothing bound per row (empty field set) → no cap applies and
        # the requested chunk passes through unchanged (no division by zero).
        @test _effective_chunk_size(1000, 0, 0, 999, :bulk_insert, "SQLite") == 1000

        # bulk_update carries a per-statement fixed overhead (static WHERE filters
        # re-included on every chunk). With 5 fixed params the budget is 65535 - 5 =
        # 65530, so 8-column rows cap at fld(65530, 8) = 8191.
        @test _effective_chunk_size(1000, 8, 5, 65535, :bulk_update, "PostgreSQL") ==
              min(1000, fld(65530, 8))
        @test _effective_chunk_size(20000, 8, 5, 65535, :bulk_update, "PostgreSQL") == 8191
    end

    # ─────────────────────────────────────────────────────────────────────────
    # Fail-closed: a single row that can't fit under the limit. No chunk_size can
    # help, so the helper must throw an actionable error — never return 0 and never
    # silently drop columns.
    # ─────────────────────────────────────────────────────────────────────────
    @testset "Impossible single row raises an actionable error" begin
        # 1000-column table on the SQLite 999 build: even one row (1000 params) blows
        # the 999 ceiling. Assert both that it throws AND that the message names the
        # concrete limit — a bare @test_throws would pass on any unrelated ArgumentError.
        err = try
            _effective_chunk_size(1000, 1000, 0, 999, :bulk_insert, "SQLite")
            nothing
        catch e
            e
        end
        @test err isa ArgumentError
        @test occursin("999", string(err))              # names the backend limit
        @test occursin("chunk_size", string(err))        # points at the lever
        @test occursin(r"bulk_insert"i, string(err))     # names the operation

        # The fixed overhead alone can exhaust the budget too (per_row still ≥ 1) —
        # assert the message, not just the type, so an unrelated ArgumentError can't pass.
        err_fixed = try
            _effective_chunk_size(1000, 1, 999, 999, :bulk_update, "SQLite")
            nothing
        catch e
            e
        end
        @test err_fixed isa ArgumentError
        @test occursin("999", string(err_fixed))
        @test occursin(r"bulk_update"i, string(err_fixed))
    end
end
