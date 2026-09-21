## A multi-CTE query renders its `WITH` clause in declaration order

- **Version**: 0.6.0
- **PormG ref**: `src/querybuilder/types.jl`, `src/querybuilder/ctes.jl`, `.github/workflows/CI.yml`
- **Recorded**: 2026-09-10
- **Severity**: **behavior change (very narrow)** — the rendered SQL string for a query with two or
  more CTEs can change. No API change, no app edit, and no query that worked stops working.

### What changed

`SQLObjectQuery.ctes` was a plain `Dict{String,CTEDict}`, and `build_cte_clause` emits the `WITH`
clause by iterating it. `Dict` iteration is hash order, so **the order of the CTEs in the emitted
SQL was decided by how Julia hashed the CTE name strings** — not by the order they were declared in.

```julia
# before → the WITH clause could render either way, depending on the NAMES
q = M.Result.objects
q.with("br_drivers" => brazilian_drivers, join_field = "driverid" => "driverid")
q.with("races_91"   => races_in_1991,     join_field = "raceid"   => "raceid")

# WITH "races_91" AS (...), "br_drivers" AS (...)   ← or the reverse. Same code, same data.

# after → always declaration order
# WITH "br_drivers" AS (...), "races_91" AS (...)
```

Two things follow from that, and only the second was ever visible:

- **Parameter binding was always correct.** The CTE bodies' positional parameters are collected in
  the same pass that renders their text, so the text and the parameter vector moved together. This
  was never a misbinding, and no query returned wrong rows.
- **The same query did not render the same SQL twice.** Renaming a CTE for readability could reorder
  the `WITH` clause, and so could a Julia upgrade: 1.13.0 changed string hashing and reordered a pair
  that 1.12.7 had rendered in declaration order. That is how this was found — `test_alignment_sqlite.jl`'s
  "Multiple CTEs" testset had been asserting declaration order that a `Dict` never promised, and it
  went red on Julia 1.13 with no code change. On 1.12, 241 of 506 sampled two-name pairs already
  rendered against declaration order; the testset's own pair happened to be in the other half.

`ctes` is now an `OrderedDict`, matching `insert` (#97) and `custom_join` / `alias_join` (#449),
which are ordered for the same reason.

### How to find the calls to migrate

None — there is nothing to migrate. The only way to notice is a test that compares generated SQL
**as a string** for a query with two or more CTEs; such a golden may need re-recording once, after
which it is stable across Julia versions instead of tracking the hash of your CTE names.

```bash
git grep -n "\.with(" -- '*.jl'    # multi-CTE queries; zero hits means this entry cannot affect you
```
