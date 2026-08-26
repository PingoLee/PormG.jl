# ─────────────────────────────────────────────────────────────────────────────
# Shared marker/parameter alignment assertions (#432, #441)
#
# The invariant this family keeps escaping through, stated once:
#
#     on a positional backend, the number of `?` a statement renders must equal the number of
#     values bound, and the Nth value must be the one whose marker is Nth IN THE TEXT.
#
# Both halves matter and they fail independently. #441's severe symptom broke the COUNT (a
# discarded projection left its `?` behind with no value); #432 broke the ORDER while the count
# stayed right (a nested render bound into a bucket that flattens somewhere else). An assertion
# that only checked one of them would have passed against the other bug.
#
# Counting `?` is sound on SQLite: the only SQL operators carrying a bare `?` are PostgreSQL's JSONB
# `?|` and `?&`, and both raise `BackendCapabilityError` on this backend.
#
# NOT retrofitted onto the ~31 hand-written `count(==('?'), …)` assertions already scattered through
# test_alignment_sqlite.jl / test_json_lookups.jl / test_order_by_joins.jl. They assert the same
# thing correctly; rewriting them is churn with real risk and no coverage gain. New alignment tests
# should use these.
# ─────────────────────────────────────────────────────────────────────────────

"""
    marker_count(sql, backend) -> Int

Placeholders rendered in `sql`. `backend` is `:sqlite` (`?`) or `:postgres` (`\$N`).
"""
marker_count(sql::AbstractString, backend::Symbol) =
  backend === :sqlite ? count(==('?'), sql) : length(collect(eachmatch(r"\$\d+", sql)))

"""
    assert_marker_count(insp, backend)

Every rendered placeholder has a bound value and vice versa. This is #441's half.

On PostgreSQL a repeated `\$1` is legal and deliberate, so the count is compared against the number
of DISTINCT indices rather than occurrences — otherwise a legitimately reused parameter reads as a
mismatch.
"""
function assert_marker_count(insp::Dict, backend::Symbol)
  sql = insp[:sql_text]
  n = length(insp[:parameters])
  if backend === :sqlite
    @test marker_count(sql, backend) == n
  else
    idx = Set(parse(Int, m.match[2:end]) for m in eachmatch(r"\$\d+", sql))
    @test length(idx) == n
  end
end

"""
    assert_bound_in_text_order(insp, sentinels)

`sentinels` lists the bound values in the order their markers appear IN THE TEXT. Asserts SQLite's
flattened parameter vector matches. This is #432's half.

SQLite only: PostgreSQL's `\$N` travels with the text by construction, so there is nothing to check
there — which is precisely why every bug in this family has been SQLite-only.
"""
function assert_bound_in_text_order(insp::Dict, sentinels::Vector)
  @test insp[:parameters] == sentinels
end
