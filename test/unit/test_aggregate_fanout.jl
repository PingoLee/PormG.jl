# test/unit/test_aggregate_fanout.jl
# Unit coverage for the #74 fan-out guard's alias-extraction helper. `_extract_leading_alias` must
# recover the single source table alias from a fully-resolved bare column reference, and return
# `nothing` for any expression spanning more than one column so the guard conservatively refuses.

using Test
using PormG
import PormG.QueryBuilder: _extract_leading_alias

@testset "_extract_leading_alias (#74)" begin
    # Logic: a bare "alias"."col" reference yields its (unquoted) alias.
    # Why: the guard maps an aggregate's resolved column to the table alias it reads.
    @test _extract_leading_alias("\"Tb\".\"driverid\"") == "Tb"
    @test _extract_leading_alias("\"Tb_1\".\"points\"") == "Tb_1"

    # Logic: a COUNT(*)-style "alias".* reference also resolves to the alias.
    # Why: Count("*") and Count("rel__*") must be attributable to detect/permit correctly.
    @test _extract_leading_alias("\"Tb\".*") == "Tb"
    @test _extract_leading_alias("\"Tb_2\".*") == "Tb_2"

    # Logic: anything that is not a single column → nothing (ambiguous → conservative raise).
    # Why: nested aggregates / F-expressions can't be attributed to one table; the guard must not guess.
    @test _extract_leading_alias("\"Tb\".\"a\" + \"Tb\".\"b\"") === nothing
    @test _extract_leading_alias("SUM(\"Tb\".\"x\")") === nothing
    @test _extract_leading_alias("COUNT(DISTINCT \"Tb\".\"x\")") === nothing
    @test _extract_leading_alias("") === nothing

    # Logic: non-string input (e.g. a Vector column for multi-arg functions) → nothing.
    @test _extract_leading_alias(["a", "b"]) === nothing

    # Logic: an identifier containing escaped (doubled) quotes is unescaped in the returned alias.
    # Why: `safe_column_identifier` escapes embedded quotes as "" — extraction must reverse that
    # faithfully. Reachable in practice since #394: the query path escapes a physical column rather
    # than refusing it, so a `db_column` carrying a quote now reaches this extractor.
    @test _extract_leading_alias("\"we\"\"ird\".\"c\"") == "we\"ird"
end
