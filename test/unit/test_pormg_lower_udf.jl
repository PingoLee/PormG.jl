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

# ─────────────────────────────────────────────────────────────────────────────
# The renderers this UDF exists for actually emit it (#604)
# The header above has always asserted in prose that the SQLite
# icontains/istartswith/iendswith renderers emit `pormg_lower(...)`. That was true of the renderers
# themselves even before #604 — what was missing was any way to REACH two of them, so nothing in the
# suite tied the UDF to two of the three lookups it was built for. These assertions call the Dialect
# renderers directly, which is the narrowest way to pin the emitter side of the contract; the
# reachability half is gated in test_operators.jl and test_alignment_sqlite.jl.
#
# Note what that means for the mutation gate: the six case-sensitive rows and the icontains /
# istartswith / iendswith rows pass against unpatched code too — only the nistartswith / niendswith
# rows are new behavior. They earn their place as a same-shape check on all twelve, not as a #604
# regression test.
# ─────────────────────────────────────────────────────────────────────────────
struct _PormgLowerMockSQLite <: PormG.PormGSQLite end

@testset "The SQLite i* renderers emit pormg_lower (#604)" begin
    conn = _PormgLowerMockSQLite()
    col, ph = "\"Tb\".\"surname\"", "?"

    # Case-INSENSITIVE LIKE family: the column AND the pattern are both folded, or the comparison
    # would be asymmetric and match nothing for a mixed-case value.
    for op in (:icontains, :istartswith, :iendswith, :nicontains, :nistartswith, :niendswith)
        sql = getfield(PormG.Dialect, op)(conn, col, ph)
        @test count("pormg_lower", sql) == 2
        @test contains(sql, "pormg_lower($(col))")
        @test contains(sql, "pormg_lower($(ph))")
        # The negated twins must fold AND negate — "NOT LIKE" contains "LIKE", so check the prefix.
        if startswith(String(op), "n")
            @test contains(sql, "NOT LIKE")
        else
            @test !contains(sql, "NOT LIKE")
        end
    end

    # Case-SENSITIVE family: folding here would silently make `@contains` case-insensitive, which is
    # the whole reason `PRAGMA case_sensitive_like = ON` is set beside the UDF registration.
    for op in (:contains, :startswith, :endswith, :ncontains, :nstartswith, :nendswith)
        sql = getfield(PormG.Dialect, op)(conn, col, ph)
        @test !contains(sql, "pormg_lower")
    end
end
