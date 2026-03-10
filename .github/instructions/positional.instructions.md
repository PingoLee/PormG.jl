# Positional Parameter Buckets (Current Architecture)

## Purpose
This file documents the **implemented** contextual-parameter strategy used by PormG for positional backends (SQLite/MySQL/MariaDB-style `?`) and defines testing boundaries to avoid duplicate coverage.

## Status
The refactor is already implemented in `src/querybuilder/parameters.jl` with a dispatch-based design.

## Parameter Types
1. `AbstractPormGParam`
- Base abstraction for all parameter collectors.

2. `PormGPostgresParam <: AbstractPormGParam`
- Linear collector for PostgreSQL placeholders (`$1`, `$2`, ...).
- `add_parameter!` increments count and appends to a single vector.

3. `PormGPositionalParam <: AbstractPormGParam`
- Bucketed collector for positional placeholders (`?`).
- Buckets currently used:
  - `:cte`
  - `:select`
  - `:update`
  - `:join`
  - `:where`
  - `:having`
- Uses `current_context::Symbol` plus `set_context!` to route values.

## Final Parameter Order (Positional)
Flattening must follow SQL-clause order:
`cte -> select -> update -> join -> where -> having`

`get_final_parameters(::PormGPositionalParam)` must preserve that order.

## Query-Building Context Rules
- Context changes are orchestrated in query-build modules (not in execution code).
- HAVING alias promotion must switch context to `:having` before `add_parameter!`.
- Join ON conditions from `cjoin` must run with `:join` context.
- Subqueries/CTEs must inherit parent collector/context where required.

## Testing Boundaries (Important)
1. Unit tests (`test/unit/test_alignment_sqlite.jl`)
- Own parameter-bucket invariants and ordering checks.
- Validate bucket isolation, flatten order, marker/parameter count alignment, and context transitions.
- This is the canonical place for SQLite positional alignment assertions.

2. Integration tests (`test/integration/*.jl`)
- Focus on behavior and SQL semantics against real datasets.
- HAVING integration should validate:
  - aggregate-alias promotion semantics,
  - result correctness,
  - basic SQL clause presence/order when relevant.
- Avoid duplicating full bucket-order matrix already covered in unit tests unless reproducing a known production regression.

## Practical Guidance for New Tests
- If the question is "Did the query return the right rows?" -> integration.
- If the question is "Did parameters land in the exact right bucket/order?" -> unit.
- If a bug spans both layers, add:
  - one narrow integration regression test, and
  - one deterministic unit alignment test.

## Maintenance Notes
- Keep this file synchronized with `src/querybuilder/parameters.jl` if buckets or ordering change.
- Any new SQL section with parameters must be reflected in:
  - bucket struct fields,
  - `set_context!` usage,
  - `get_final_parameters` order,
  - unit alignment tests.
