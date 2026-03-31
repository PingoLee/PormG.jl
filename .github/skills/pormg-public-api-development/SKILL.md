---
name: pormg-public-api-development
description: Implement or refactor PormG features through the public API, write regression tests, and keep user-facing examples aligned with the fluent query surface.
user-invocable: true
---

# PormG Public API Development

## Purpose

Use this skill when changing PormG behavior, adding regression coverage, or writing examples that should reflect how a real package user interacts with the ORM.

The core discipline is simple: prefer the public fluent API in user-facing code and integration tests, and only drop into internal helpers when the test is explicitly about internals.

Use `pormg-migrations-development` instead when the task centers on `src/Migrations.jl` or `src/migrations/`.

Use `pormg-querybuilder-internals` instead when the task centers on `src/QueryBuilder.jl`, files under `src/querybuilder/`, SQL rendering, or parameter bucket routing.

## Use This Skill For

- Implementing feature work in `src/` when the change is expressed through the public ORM surface rather than the migration subsystem or low-level QueryBuilder internals
- Fixing ORM regressions discovered in integration tests
- Writing or refactoring tests in `test/integration/`
- Writing examples and docs that should mirror package usage
- Deciding whether a regression belongs in unit tests, integration tests, or both

## Public API First

### Preferred query style

Use the fluent surface exposed by `ObjectHandler` and `model.objects`:

```julia
query = M.Result.objects
query.filter("driverid__surname" => "Senna", "positionorder" => 1)
query.values("raceid__year", "raceid__name", "constructorid__name")

rows = query.list()
exists = query.exists()
count = query.count()
```

### For terminal operations, prefer fluent methods

- Use `query.list()` instead of piping to a free `list` helper
- Use `query.list_json()` instead of a free `list_json` helper
- Use `query.delete()` instead of a free `delete(query, ...)` call
- Use `query.count()` and `query.exists()` for behavior-focused tests

### When direct helper calls are acceptable

Use internal or function-style helpers only when the test is explicitly about internals or when no fluent equivalent exists:

- `inspect_query(q)` for query inspection
- `bulk_insert`, `bulk_update`, `bulk_copy` for bulk APIs
- direct `PormG.QueryBuilder` imports in unit tests targeting builders, buckets, or planner behavior

## Test Placement Rules

### Integration tests

Put behavior tests in `test/integration/` when the real question is:

- Did the ORM return the correct rows?
- Did joins, filters, updates, deletes, and transactions behave correctly?
- Did the public API remain stable for package users?

Integration tests should use:

- `M.Model.objects`
- fluent query methods
- real Formula 1 models unless the test is about auxiliary mechanics

### Unit tests

Put tests in `test/unit/` when the real question is:

- Did SQL text render correctly?
- Did parameter ordering or bucket routing stay correct?
- Did a low-level validator or planner behave deterministically?

For positional parameter regressions, the canonical unit target is `test/unit/test_alignment_sqlite.jl`.

### If a bug spans both layers

Add both:

1. one narrow integration regression proving the user-visible failure
2. one deterministic unit test proving the internal root cause

## Test Writing Standard

- **Use standardized block headers for all `@testset` blocks**:
  ```julia
  # ─────────────────────────────────────────────────────────────────────────────
  # [Feature/Area]: [Specific scenario being tested]
  # [1-2 sentences explaining what the test verifies, the expected SQL shape, 
  # and why the behavior matters to users or future maintainers]
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "..." begin
  ```
- Heavily comment test logic within the block
- Prefer isolated setup and explicit cleanup over hidden shared state
- Do not weaken model contracts just to accommodate dirty fixtures; normalize fixtures in the import layer instead

## Domain Rules

- Use Formula 1 dataset examples for user-facing docs and examples
- Keep Julia model bindings capitalized even when SQL tables are snake_case
- Prefer expressive ORM filters and joins over raw SQL
- Preserve async-first assumptions and transaction safety

## Workflow

1. Read the relevant source and failing tests first
2. Fix the root cause, not just the symptom
3. Add or adjust tests through the public API when behavior changed
4. Add unit coverage when the bug lives in builder/rendering/validation internals
5. Run the smallest relevant test slice first
6. Run the broader suite only after targeted failures are green

## Verification Commands

```powershell
julia --project=. test/runtests.jl
julia -t auto --project=. test/integration/runtests.jl
julia -t auto --project=. test/integration/test_bulk_copy.jl
julia -t auto --project=. test/integration/test_joins_cte.jl
```

## Anti-Patterns

- Do not write integration tests against internal helper functions when the public API can express the same behavior
- Do not document unsupported APIs as if they were stable
- Do not use generic `User` or `Post` examples in docs
- Do not duplicate SQLite parameter bucket coverage in integration tests unless reproducing a known production regression