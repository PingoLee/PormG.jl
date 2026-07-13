# ─────────────────────────────────────────────────────────────────────────────
# pormg_lower UDF: Unicode-aware case folding for SQLite i* lookups (#78)
# The SQLite icontains/istartswith/iendswith renderers emit `pormg_lower(...)`, a
# scalar UDF registered per-connection in PormGSQLiteExt and backed by Julia's
# Unicode-aware `lowercase`. SQLite marshals a TEXT argument to Julia as a String,
# a SQL NULL as `missing`, and numeric/other values as Int64/Float64/bytes. The UDF
# must: fold text case for the FULL Unicode range (not ASCII-only, as SQLite's
# built-in LOWER did), pass NULL through as `missing` (→ SQL NULL, never throw), and
# coerce non-text to text (mirroring SQLite LOWER's text affinity).
#
# This gates all three `_pormg_lower` methods directly. It matters because the query
# unit tests only inspect rendered SQL (`show_query`), never execute it, and the F1
# integration schema has no nullable text column — so the `missing`/non-text branches
# are otherwise never exercised. Mutation gate: dropping the `::Missing` method (or
# reverting the text method to an ASCII fold) fails the corresponding assertion here.
# ─────────────────────────────────────────────────────────────────────────────
@testset "pormg_lower UDF (#78)" begin
    # The SQLite weakdep is activated by test/load_drivers.jl, so the extension module
    # (and its non-exported _pormg_lower) is reachable via Base.get_extension.
    ext = Base.get_extension(PormG, :PormGSQLiteExt)
    @test ext !== nothing
    pl = ext._pormg_lower

    # Unicode case folding — the fix. Accented uppercase folds to accented lowercase,
    # which ASCII-only SQLite LOWER() could not do (this is exactly the #78 bug).
    @test pl("RÄIKKÖNEN") == "räikkönen"
    @test pl("HÜLKENBERG") == "hülkenberg"
    @test pl("PÉREZ")      == "pérez"
    # ASCII text still folds (unchanged from the old behavior).
    @test pl("HAMILTON")   == "hamilton"
    # Folds CASE but preserves ACCENTS — accent-insensitive matching stays the job of
    # the PostgreSQL-only iunaccent_* lookups, so the ASCII spelling must NOT be produced.
    @test pl("RÄIKKÖNEN") != "raikkonen"

    # SQL NULL arrives as `missing` and must round-trip to `missing` (→ SQL NULL), never throw.
    @test pl(missing) === missing

    # Non-text values are coerced to text (mirrors SQLite's built-in LOWER text affinity),
    # so an i* lookup accidentally applied to a numeric column can't crash the query.
    @test pl(42) == "42"
end
