"""
Unit coverage for the non-mutating bulk pipeline (#132).

The bulk operations used to `deepcopy` the input DataFrame (`copy=true` default) because
the pipeline mutates its working frame: `_prepare_bulk_df!` injects auto-populated columns
(`auto_now`, static defaults) for every model field the DataFrame does not carry.
#132 replaced the deepcopy with a zero-copy wrapper (`_bulk_working_frame`,
`select(df_o, :; copycols=false)`): the wrapper shares the caller's column vectors, and
because every internal write is a whole-column replacement/addition, nothing ever reaches
the caller's frame — unconditionally, with no `copy=` knob.

Since #331 the pipeline has exactly ONE mutation class: column INJECTION. It used to have a
second — a whole-column default FILL that rewrote `missing`/`nothing` cells of a column the
caller DID supply — and that site is gone: a present column is caller-authored data and is
never rewritten. So this file's model carries `pit_stops` purely to keep an injection live,
and `laps` (present, blank) to pin that the deleted fill site stays deleted.

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

# F1-flavored model exercising both injection kinds plus the #331 no-rewrite rule:
#   - pit_stops has a static default → absent from every df, triggers column INJECTION;
#   - updated_at has auto_now        → absent from every df, triggers column INJECTION;
#   - laps has a static default and IS present in the df with blank cells → since #331 those
#     cells are caller data and stay NULL, so it must be nullable (a NOT NULL field would now
#     raise "null values are not allowed" here, which is the correct behavior but a different
#     test — see test_bulk_default_fill_scope.jl).
Bnm_result = Model("bnm_result",
    id         = IDField(),
    surname    = CharField(),
    points     = IntegerField(null = true),
    laps       = IntegerField(default = 0, null = true),
    pit_stops  = IntegerField(default = 0),
    updated_at = DateTimeField(auto_now = true),
)
Bnm_result.connect_key = "bnm_mock"

# Snapshot the caller-visible state of every column: names, vector identities, values.
snapshot(df) = (names(df), Dict(c => df[!, c] for c in names(df)),
                Dict(c => copy(df[!, c]) for c in names(df)))

# Read a bound value back by COLUMN NAME. An INSERT binds parameters in the order it renders
# its column list, so a column's position there is its parameter index — but that order is
# "present columns first, then injected ones", which a model change can silently reshuffle.
# Indexing by name fails loudly instead of asserting the wrong slot.
function param_for(res, col)
    m = match(r"INSERT INTO\s+\S+\s*\((.*?)\)\s*VALUES"s, res[:sql_text])
    m === nothing && error("could not parse an INSERT column list from: $(res[:sql_text])")
    cols = [strip(c, ['"', ' ', '\n', '\r', '\t']) for c in split(m.captures[1], ",")]
    idx = findfirst(==(col), cols)
    idx === nothing && error("column $(col) is not in the INSERT: $(res[:sql_text])")
    return res[:parameters][idx]
end

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

    @testset "bulk_insert: default + auto_now injections stay internal" begin
        df = DataFrames.DataFrame(
            surname = ["Senna", "Prost"],
            points  = [25, 18],
            laps    = [missing, missing],   # present + blank → #331: stays NULL, never filled
        )
        snap = snapshot(df)
        res = bulk_insert(Bnm_result.objects, df, show_query = :dict)

        assert_untouched(df, snap)
        @test all(ismissing, df[!, "laps"])          # unchanged, and now unchanged internally too
        @test !("pit_stops" in names(df))            # the injection never reached the caller
        @test !("updated_at" in names(df))           # ditto
        # …but the injections DID happen on the working frame: the prepared insert carries them.
        @test occursin("\"laps\"", res[:sql_text])   # present column still participates
        @test occursin("\"pit_stops\"", res[:sql_text])
        @test occursin("\"updated_at\"", res[:sql_text])

        # #331 — prove the values, not just the column list. This is the one assertion in this
        # file that discriminates the #331 fix; the rest of the additions above are controls.
        @test ismissing(param_for(res, "laps"))      # caller's blank survived as NULL
        @test param_for(res, "pit_stops") == 0       # absent column, default injected
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
        @test !("pit_stops" in names(df))
        @test !("updated_at" in names(df))
        @test occursin("COPY", res[:sql_text])
        @test occursin("\"pit_stops\"", res[:sql_text])   # absent default still injected
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
        # …while a static default absent from an explicitly scoped update stays out, so it
        # cannot overwrite live rows. Unchanged by #331; pinned in detail in
        # test_bulk_update_column_scope.jl.
        @test !occursin("\"laps\"", res[:sql_text])
        @test !occursin("\"pit_stops\"", res[:sql_text])
    end

    @testset "allocate_primary_keys clone=true: independent copy, pk on the returned frame only" begin
        # DB-free path: explicit ids present → returns before any backend call, but the
        # clone is already built. Unlike the bulk ops' INTERNAL working frames, this frame
        # is RETURNED to the caller, so clone=true must mean genuinely independent columns
        # (#132 review) — a zero-copy wrapper here would be user-visible aliasing.
        df = DataFrames.DataFrame(id = [10, 20], surname = ["Lauda", "Hunt"])
        snap = snapshot(df)
        out = PormG.allocate_primary_keys(Bnm_result.objects, df)

        assert_untouched(df, snap)
        @test out[!, "id"] == [10, 20]
        @test out[!, "surname"] !== df[!, "surname"]   # independent vectors…
        @test out[!, "surname"] == df[!, "surname"]    # …with equal values
        # Independence is bidirectional: an element write on the returned frame must
        # never reach the caller's frame.
        out[1, "surname"] = "Regazzoni"
        @test df[1, "surname"] == "Lauda"
    end
end
