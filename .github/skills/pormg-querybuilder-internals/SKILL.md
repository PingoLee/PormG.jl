---
name: pormg-querybuilder-internals
description: Work on QueryBuilder internals such as SQL generation, parameter routing, joins, CTEs, functions, and inspection paths, with deterministic unit coverage.
user-invocable: true
---

# PormG QueryBuilder Internals

## Purpose

Use this skill when the task is inside the SQL builder itself: parameter collection, SQL rendering, join generation, CTE behavior, function translation, deletion planning, or internal inspection behavior.

This skill is for implementation and regression analysis inside `src/querybuilder/`.

## Use This Skill For

- Editing `src/QueryBuilder.jl`
- Editing files under `src/querybuilder/`
- Fixing SQL rendering regressions
- Fixing parameter ordering and bucket routing
- Fixing `With`, `cjoin`, `on`, `having`, alias promotion, and join planning internals
- Working with `inspect_query`, `show_query`, and builder metadata

## Boundary With Public API Work

- If the bug is user-visible, add one integration regression through the fluent public API
- Then add a narrow internal unit test if the root cause is builder-specific
- Do not replace behavior tests with internals-only tests

## Internal Focus Areas

### Parameter routing

For positional backends, preserve bucket semantics and flatten order:

`cte -> select -> update -> join -> where -> having`

Parameter collector model:

- `AbstractPormGParam`: base abstraction for all collectors
- `PormGPostgresParam`: linear collector for `$1`, `$2`, ... placeholders
- `PormGPositionalParam`: bucketed collector for positional `?` placeholders

Current positional buckets:

- `:cte`
- `:select`
- `:update`
- `:join`
- `:where`
- `:having`

When changing parameter behavior, verify:

- context switching through `set_context!`
- marker and parameter count alignment
- parent and subquery inheritance behavior
- HAVING alias promotion placement
- custom join parameter routing into the join bucket
- flattening through `get_final_parameters(::PormGPositionalParam)` in SQL-clause order

Query-building context rules:

- context changes belong in query-build modules, not in execution code
- HAVING alias promotion must switch context to `:having` before `add_parameter!`
- join `on` conditions from `cjoin` must run with `:join` context
- subqueries and CTEs must inherit the parent collector and context when required

Canonical unit files:

- `test/unit/test_alignment_sqlite.jl`
- `test/unit/test_parameters.jl`

Integration touchpoints:

- `test/integration/test_having.jl`
- `test/integration/test_joins_cte.jl`

Testing boundary:

- use unit tests for exact bucket placement, flatten order, marker alignment, and context transitions
- use integration tests for user-visible semantics such as HAVING alias promotion correctness or join behavior against real data
- if a bug spans both layers, add one narrow integration regression and one deterministic unit alignment test

### Query generation

Focus on:

- `build_helpers.jl`
- `build_joins.jl`
- `build_query.jl`
- `ctes.jl`
- `execution.jl`
- `deletion.jl`

### Inspection tools

Useful internal tools:

- `inspect_query(q)`
- `show_query=:sql`
- `show_query=:dict`
- direct builder inspection when debugging parameter state

### Maintenance checklist

When introducing a new parameterized SQL clause or changing clause order, update all of the following together:

- bucket struct fields in `parameters.jl`
- `set_context!` call sites in builder modules
- `get_final_parameters` flatten order
- unit coverage in the canonical alignment tests
- integration coverage if the behavior is user-visible

## Test Placement Rules

### Unit tests

Prefer unit tests when the question is:

- Did the SQL text render correctly?
- Did parameters land in the right bucket and order?
- Did alias promotion happen in the right clause?
- Did `cjoin`, `With`, or custom join wiring produce the intended internal metadata?

### Integration tests

Use integration tests when the question is:

- Did the query return the right rows?
- Did update/delete/join semantics behave correctly end to end?

Integration regressions should still use the public fluent API unless the bug only reproduces through a lower-level path.

## Workflow

1. Reproduce the failure with the smallest relevant query
2. Inspect the built query or parameters before editing code
3. Fix the root cause in the smallest internal module possible
4. Add deterministic unit coverage
5. Add a public-API integration regression if user-visible behavior changed
6. Re-run the narrow test slice before broader suites

## Verification Commands

```powershell
julia --project=. test/unit/test_alignment_sqlite.jl
julia --project=. test/unit/test_inspect_query.jl
julia -t auto --project=. test/integration/test_joins_cte.jl
julia -t auto --project=. test/integration/test_having.jl
```

## Anti-Patterns

- Do not duplicate the full parameter bucket matrix in integration tests
- Do not fix SQL shape bugs only by changing test expectations without validating semantics
- Do not bypass public API regressions when the failure is visible to package users
- Do not mix unrelated SQL formatting changes into a targeted regression fix