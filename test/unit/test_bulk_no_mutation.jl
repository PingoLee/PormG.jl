"""
Unit coverage for the non-mutating bulk pipeline (#132).

The bulk operations used to `deepcopy` the input DataFrame (`copy=true` default) because
the pipeline mutates its working frame: `_prepare_bulk_df!` fills defaults in place
(whole-column replacement) and injects auto-populated columns (`auto_now`, defaults).
#132 replaced the deepcopy with a zero-copy wrapper (`_bulk_working_frame`,
`select(df_o, :; copycols=false)`): the wrapper shares the caller's column vectors, and
because every internal write is a whole-column replacement/addition, nothing ever reaches
the caller's frame — unconditionally, with no `copy=` knob.

This file pins that contract for all three bulk ops, asserting three things after each
call: the caller's column SET is unchanged (no injected `updated_at`/`laps`), the column
VECTOR OBJECTS are identical (`===` — the wrapper shares, never rebinds, caller slots),
and the VALUES are unchanged (a `.=`-style write-through would keep the vector identical
but change its contents, so identity alone is not enough).

Deterministic and DB-free: a mock PostgreSQL connection; `show_query = :dict` returns the
prepared statement before any network call — but only AFTER `_prepare_bulk_df!` has run,
so the default-fill and auto-now mutations this test guards against have already happened.
"""

using Test
using PormG
using PormG.Models: Model, IDField, IntegerField, CharField, DateTimeField
using PormG.QueryBuilder: bulk_copy, bulk_insert, bulk_update
import DataFrames

# Mock connection under a dedicated key so this file cannot contaminate (or be
# contaminated by) other unit files sharing Main in runtests.jl.
struct BulkNoMutationMockPg <: PormG.PormGPostgres end
PormG.config["bnm_mock"] = PormG.Configuration.Settings(
    connections = BulkNoMutationMockPg(),
    change_data = true,
)

# F1-flavored model exercising BOTH mutation classes of _prepare_bulk_df!:
#   - laps has a static default  → present-with-missings triggers the default FILL
#     (whole-column replacement on the working frame);
#   - updated_at has auto_now    → absent from the df, triggers column INJECTION.
Bnm_result = Model("bnm_result",
    id         = IDField(),
    surname    = CharField(),
    points     = IntegerField(null = true),
    laps       = IntegerField(default = 0),
    updated_at = DateTimeField(auto_now = true),
)
Bnm_result.connect_key = "bnm_mock"

# Snapshot the caller-visible state of every column: names, vector identities, values.
snapshot(df) = (names(df), Dict(c => df[!, c] for c in names(df)),
                Dict(c => copy(df[!, c]) for c in names(df)))

# Assert the caller's frame is untouched: same column set, same vector objects (===),
# same values (catches a write-through into a shared vector, which === alone misses).
function assert_untouched(df, snap)
    cols, ids, vals = snap
    @test names(df) == cols
    for c in cols
        @test df[!, c] === ids[c]
        @test isequal(df[!, c], vals[c])
    end
end

@testset "bulk ops never mutate the caller DataFrame (#132)" begin

    @testset "bulk_insert: default fill + auto_now injection stay internal" begin
        df = DataFrames.DataFrame(
            surname = ["Senna", "Prost"],
            points  = [25, 18],
            laps    = [missing, missing],   # default=0 fills these — on the working frame only
        )
        snap = snapshot(df)
        res = bulk_insert(Bnm_result.objects, df, show_query = :dict)

        assert_untouched(df, snap)
        @test all(ismissing, df[!, "laps"])          # the fill never reached the caller
        @test !("updated_at" in names(df))           # the injection never reached the caller
        # …but both DID happen on the working frame: the prepared insert carries them.
        @test occursin("\"laps\"", res[:sql_text])
        @test occursin("\"updated_at\"", res[:sql_text])
    end

    @testset "bulk_copy: same contract on the COPY path" begin
        df = DataFrames.DataFrame(
            surname = ["Piquet"],
            points  = [15],
            laps    = [missing],
        )
        snap = snapshot(df)
        res = bulk_copy(Bnm_result.objects, df, show_query = :dict)

        assert_untouched(df, snap)
        @test all(ismissing, df[!, "laps"])
        @test !("updated_at" in names(df))
        @test occursin("COPY", res[:sql_text])
    end

    @testset "bulk_update: auto_now injection stays internal" begin
        df = DataFrames.DataFrame(id = [1, 2], points = [26, 19])
        snap = snapshot(df)
        res = bulk_update(Bnm_result.objects, df,
            columns    = ["points"],
            match_on   = ["id"],
            show_query = :dict,
        )

        assert_untouched(df, snap)
        @test !("updated_at" in names(df))
        # auto_now must still inject into the UPDATE itself (the intentional ORM
        # side-effect the old copy=true existed to keep away from the caller).
        @test occursin("\"updated_at\"", res[:sql_text])
    end

    @testset "allocate_primary_keys clone=true: pk lands on the returned frame only" begin
        # DB-free path: explicit ids present → returns before any backend call, but the
        # clone wrapper is already built, pinning that clone= stays zero-copy and safe.
        df = DataFrames.DataFrame(id = [10, 20], surname = ["Lauda", "Hunt"])
        snap = snapshot(df)
        out = PormG.allocate_primary_keys(Bnm_result.objects, df)

        assert_untouched(df, snap)
        @test out[!, "id"] == [10, 20]
        @test out[!, "surname"] === df[!, "surname"]   # zero-copy: vectors are shared
    end
end
