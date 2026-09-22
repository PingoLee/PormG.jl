# ============================================================
# test/unit/test_bulk_update_chunk_parameters.jl
#
# Per-chunk parameter collectors in bulk_update (#73).
#
# CONTRACT being tested:
#   `bulk_update` runs one statement per chunk. Every chunk's statement carries the same fixed
#   prefix — the static `filters=` values `build()` bound, which on PostgreSQL also fixes the
#   `$1…$k` numbering already rendered into the WHERE clause — followed by THAT chunk's rows and
#   nothing else. The loop used to bind rows into the built collector and rewind it with a
#   `deepcopy` snapshot at each chunk boundary, a rewind a row that threw mid-chunk never reached.
#   Each chunk now binds into its own fork of the built collector (`_fork_parameters`), which
#   leaves the source untouched by construction.
#
# Deterministic and DB-free: mock PostgreSQL and SQLite connections; `show_query = :dict` returns
# each chunk's prepared statement before any driver call.
# ============================================================

using Test
using PormG
using PormG.Models: Model, IDField, IntegerField, CharField
using PormG.QueryBuilder: bulk_update
import DataFrames
import Logging

const QB73 = PormG.QueryBuilder

# Dedicated config keys so this file cannot contaminate (or be contaminated by) other unit files
# sharing Main in runtests.jl.
struct BulkChunkParamsMockPg <: PormG.PormGPostgres end
struct BulkChunkParamsMockSl <: PormG.PormGSQLite end
# The chunk cap reads the SQLite version for its bind-parameter limit; a modern build (32766).
PormG.backend_sqlite_version(::BulkChunkParamsMockSl) = 3045000
PormG.config["bcp73_pg"] = PormG.Configuration.Settings(
    connections = BulkChunkParamsMockPg(), change_data = true)
PormG.config["bcp73_sl"] = PormG.Configuration.Settings(
    connections = BulkChunkParamsMockSl(), change_data = true)

# One F1-flavoured results table per backend: `year` carries the static scope filter, `points` is
# the column being SET, `id` is the per-row match key.
bcp73_result(key) = begin
    m = Model("bcp73_result",
        id      = IDField(),
        year    = IntegerField(),
        surname = CharField(null = true),
        points  = IntegerField(),
    )
    m.connect_key = key
    m
end
Bcp73_pg = bcp73_result("bcp73_pg")
Bcp73_sl = bcp73_result("bcp73_sl")

# Five 1988 results: with chunk_size = 2 that is chunks {1,2}, {3,4}, {5}.
const BCP73_IDS    = [11, 12, 13, 14, 15]
const BCP73_POINTS = [9, 6, 4, 3, 2]
bcp73_df() = DataFrames.DataFrame(id = BCP73_IDS, points = BCP73_POINTS)

# The row values a chunk must bind, in the order `bulk_update` binds them: every SET column, then
# every match key — `joined_columns = unique(vcat(fields_df, match_on))`, here `[points, id]`.
bcp73_rows(idx) = reduce(vcat, ([BCP73_POINTS[i], BCP73_IDS[i]] for i in idx); init = Any[])

bcp73_update(model, df) = bulk_update(model.objects, df,
    columns    = ["points"],
    match_on   = ["id"],
    filters    = ["year" => 1988],
    chunk_size = 2,
    show_query = :dict)

@testset "bulk_update per-chunk parameter collectors (#73)" begin

    # ─────────────────────────────────────────────────────────────────────────────
    # _fork_parameters: a fork starts from the source's bindings, and binding into it never
    # reaches the source.
    # This is the property the chunk loop relies on instead of a snapshot/restore: the collector
    # `build()` returned is the fixed prefix of every chunk, so it must survive any number of forks
    # being filled — or abandoned half-filled by a row that throws.
    # ─────────────────────────────────────────────────────────────────────────────
    @testset "fork is independent of its source" begin
        @testset "PostgreSQL" begin
            base = QB73.get_parameter(BulkChunkParamsMockPg())
            @test QB73.add_parameter!(base, 1988) == "\$1"

            fork = QB73._fork_parameters(base)
            @test fork !== base
            @test fork.parameters == Any[1988]
            @test fork.parameter_count == 1
            # Numbering continues from the source's count, which is what keeps the `$1` already
            # rendered into the WHERE clause pointing at the filter value in every chunk.
            @test QB73.add_parameter!(fork, 9) == "\$2"

            @test base.parameters == Any[1988]      # source untouched…
            @test base.parameter_count == 1         # …including its counter
            @test fork.parameters == Any[1988, 9]
        end

        @testset "SQLite" begin
            base = QB73.get_parameter(BulkChunkParamsMockSl())
            QB73.set_context!(base, :where)
            QB73.add_parameter!(base, 1988)

            fork = QB73._fork_parameters(base)
            @test fork.current_context === :where   # context travels with the fork
            QB73.set_context!(fork, :select)
            QB73.add_parameter!(fork, 9)

            @test base.where_params == Any[1988]
            @test isempty(base.select_params)       # the fork's bucket is a new vector
            @test base.current_context === :where  # switching the fork's context did not reach it
            @test fork.where_params == Any[1988]
            @test fork.select_params == Any[9]
            # Clause order: the VALUES source (:select) precedes the WHERE filter.
            @test QB73.get_final_parameters(fork) == Any[9, 1988]
        end
    end

    # ─────────────────────────────────────────────────────────────────────────────
    # bulk_update: every chunk binds the static-filter prefix plus its own rows — nothing from an
    # earlier chunk.
    # With chunk_size = 2 and five rows there are three statements. A collector reused across
    # chunks (the defect class a missed rewind produces) would show chunk 1's rows inside chunk 2,
    # and on PostgreSQL would number chunk 2's placeholders from $6 instead of $2.
    # ─────────────────────────────────────────────────────────────────────────────
    @testset "each chunk carries only the fixed prefix and its own rows" begin
        chunks = [[1, 2], [3, 4], [5]]

        @testset "PostgreSQL" begin
            res = bcp73_update(Bcp73_pg, bcp73_df())
            @test res isa AbstractVector
            @test length(res) == 3
            for (r, idx) in zip(res, chunks)
                # The static filter binds first (at build time), so it is $1 in every chunk.
                @test r[:parameters] == vcat(Any[1988], bcp73_rows(idx))
                @test occursin(r"\"year\"\s*=\s*\$1\b", r[:sql_text])
                # Row placeholders restart at $2 each chunk and stop at this chunk's own count.
                n = 1 + 2 * length(idx)
                @test occursin("\$$n", r[:sql_text])
                @test !occursin("\$$(n + 1)", r[:sql_text])
            end
        end

        @testset "SQLite" begin
            res = bcp73_update(Bcp73_sl, bcp73_df())
            @test res isa AbstractVector
            @test length(res) == 3
            for (r, idx) in zip(res, chunks)
                # Positional: the CTE's VALUES rows render before the WHERE filter.
                @test r[:parameters] == vcat(bcp73_rows(idx), Any[1988])
                @test count("?", r[:sql_text]) == length(r[:parameters])
            end
        end
    end

    # ─────────────────────────────────────────────────────────────────────────────
    # bulk_update: a row that fails mid-chunk raises a clean error, and the next call is unaffected.
    # Row 4 is invalid (NULL into the NOT NULL `points`), so the failure lands in chunk 2 after row 3
    # has been bound. CHARACTERIZATION, not a gate: the collector being abandoned is local to the
    # call on both the old and the new code, so this pins the observable contract — error type and
    # message, and a clean follow-up call on the same handler — rather than the internal state.
    # ─────────────────────────────────────────────────────────────────────────────
    @testset "a mid-chunk failure raises cleanly and leaves nothing behind" begin
        # Each backend's first-chunk parameters in its own clause order (see the testset above).
        first_chunk = Dict(Bcp73_pg => vcat(Any[1988], bcp73_rows([1, 2])),
                           Bcp73_sl => vcat(bcp73_rows([1, 2]), Any[1988]))
        for model in (Bcp73_pg, Bcp73_sl)
            bad = DataFrames.DataFrame(id = BCP73_IDS,
                                       points = Union{Int, Missing}[9, 6, 4, missing, 2])
            err = try
                # The depuration log for the failing row is expected noise here.
                Logging.with_logger(Logging.NullLogger()) do
                    bcp73_update(model, bad)
                end
                nothing
            catch e
                e
            end
            @test err isa PormG.PormGError
            @test occursin("null", lowercase(sprint(showerror, err)))

            # A fresh call on the same model binds exactly the prefix plus its rows.
            res = bcp73_update(model, bcp73_df())
            @test length(res) == 3
            @test res[1][:parameters] == first_chunk[model]
        end
    end
end
