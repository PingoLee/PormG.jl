# TODO List

This document tracks missing features and planned improvements for PormG.jl, with a focus on reaching parity with Django-style ORM capabilities and leveraging PostgreSQL-specific power features.

## 🚀 High Priority: Core ORM Parity

- [ ] **Bulk Operation API Refactoring**
  - **Context**: Currently, `bulk_update(filters=...)` handles both DataFrame column mapping and static SQL filters. While flexible, this leads to ambiguity and potential breaking changes if column names overlap with model fields.
  - **Goal**: Introduce a clearer separation (e.g., `mapping` vs `filters` or explicitly typed objects) to improve type safety and readability without breaking legacy support.

- [ ] **Advanced Query Expressions**
  - [ ] Support for **Subqueries** (using `OuterRef`).
  - [ ] **Window Functions** (`OVER`, `RANK`, `ROW_NUMBER`).
  - [ ] **Conditional Expressions** (`Case`, `When`) improvements (ensure full PostgreSQL compliance).
  - [ ] **F-Expression** expansion (bitwise operations, complex transformations).
    - [ ] **Date/Time Functions**: add support to `values("fim" => F("transferencia__data_envio__@date") + Day(30))`
    - [ ] **Extend test coverage** for date/time functions to ensure cross-database compatibility and correct SQL generation.

- [ ] **Performance & Type Stability**
  - **Context**: Current `list()` returns `Vector{Dict{Symbol, Any}}`. While flexible for JSON-first SPAs, this triggers dynamic dispatch in Julia, hitting a "performance ceiling" for high-throughput Nitro.jl applications.
  - **Goal**: Allow queries to return concrete Julia `struct` types instead of dynamically typed Dictionaries.
  - [ ] **Strongly Typed Model Returns (Nitro compatibility)**: Implement `list_as(query, MyModel)` or similar to map DB results directly to typed structs.
  - [ ] **Fast JSON Serialization**: Optimize serialization path (e.g., via `JSON3.jl`) to leverage type-stable structs for lightning-fast JSON output.
  - [ ] **Allocation Reduction with IO Strategy**:
    - **Context**: String concatenation (`*=` and interpolation) in the query builder triggers significant GC overhead.
    - [ ] Expand the `IOBuffer` approach used in `query()` to `insert()`, `update()`, `delete()`, `do_count()`, and `do_exists()`.
    - [ ] Refactor internal helper functions (`_query_select`, `build_cte_clause`, etc.) to optionally take an `IO` object.
  - [ ] **Performance Benchmarking**: Establish a baseline for query generation and execution overhead.
  - [ ] **Thread Safety**: Audit connection pool for concurrent `Async` safety.

- [x] **Refactor QueryBuilder Parameter Handling (Contextual Buckets Strategy)**
  - **Context:** Currently, the query builder generates PostgreSQL parameters (`$1`, `$2`...) sequentially. MySQL/MariaDB and SQLite use positional parameters (`?`), which require a "Bucket" strategy because code execution order (e.g., Processing `WHERE` before `JOIN` to determine needs) doesn't match SQL string order.
  - **Goal:** Implement this in [src/querybuilder/parameters.jl](src/querybuilder/parameters.jl) using Multiple Dispatch.
  - **Implementation Details:**
    1. **Abstract Base Type**: `AbstractPormGParam`.
    2. **PostgreSQL**: `PormGPostgresParam <: AbstractPormGParam` (single vector/counter).
    3. **Positional (MySQL/SQLite)**: `PormGPositionalParam <: AbstractPormGParam` with distinct buckets for `cte_params`, `select_params`, `join_params`, `where_params`, `having_params`.
    4. **Context Control**: `set_context!(params, context::Symbol)` to direct parameters to the correct bucket.
    5. **Finalization**: `get_final_parameters` returns `vcat` of buckets in standard SQL order.
    - [x] **show_query**: Update to support new parameter structure and ensure correct SQL string generation for each dialect. Finishing the concept of Symbol-based `show_query` modes for flexible inspection.
    - [ ] **Testing & Alignment Verification**:
      - [ ] **Positional Cross-Check**: Create tests that count the number of `?` in each SQL block (SELECT, JOIN, WHERE) and compare them against the length of the corresponding parameter bucket.
      - [ ] **Execution Order Stress Test**: Specifically test queries where JOINs are calculated dynamically based on filters to ensure parameter positions don't drift.
      - [ ] **Subquery Isolation**: Verify that nested subqueries correctly restore the parent's `current_context` after execution.
      - [ ] **Unit Tests**: Implement these using `inspect_query` and mocked connections in `test/unit/test_parameters.jl`.

- [ ] **Full Transaction Control**
  - [ ] **Savepoints**: Support for nested transactions/atomic blocks.
  - [ ] **Row-Level Locking**: `select_for_update()` with `SKIP LOCKED` and `OF` support.

- [x] **Query Inspection & Developer Tooling**
  - [x] **Intent Detection**: Improve the `:operation` heuristic in `inspect_query` to distinguish between `:select` and `:delete` without explicit overrides.
  - [ ] **Finalize `show_query` with `:inspection` mode**: Ensure it returns a comprehensive metadata dictionary with consistent keys across all operations (select, insert, update, delete) for use in debugging and potential future tooling (e.g., query logging middleware).
  - [ ] **Metadata Enrichment**: Include additional context in the inspection dict, such as estimated execution time (using EXPLAIN), potential indexes used, and warnings about missing indexes or inefficient queries.
  - [ ] **SQL Formatting**: Add a `:pretty` mode to `show_query` to return formatted/indented SQL for better readability in logs.
  - [ ] **Explain Support**: Add an `explain_query()` API to return the database's `EXPLAIN (ANALYZE, BUFFERS)` output directly as metadata.


## 🐘 PostgreSQL Specific Enhancements

- [ ] **JSONB Support**
  - [ ] Implement `JSONField`.
  - [ ] Support for JSON lookups (`data__key`, `data__0__key`).
  - [ ] JSON containment and overlap operators (`@>`, `?`, `?|`, `?&`).

- [ ] **Specialized Data Types**
  - [ ] `UUIDField` (using native `uuid` type).
  - [ ] `ArrayField` (PostgreSQL native arrays).
  - [ ] `IntervalField` (PostgreSQL `interval`).
  - [ ] `INET`/`CIDR` Fields for network addresses.

- [ ] **Advanced Indexing**
  - [ ] Support for `GIN`, `GIST`, and `BRIN` indexes in migrations.
  - [ ] Functional indexes (indexing the result of a function).
  - [ ] Partial indexes (indexing a subset of rows via `WHERE`).

- [ ] **Performance Bulk Operations**
  - [x] **COPY command**: Implement high-speed bulk inserts using PostgreSQL's `COPY` protocol.
  - [ ] **Dataframes Type Normalization**: Create integration tests for bulk operation type normalization in `execution_bulk.jl`.
    - Validate edge cases for `bulk_insert`, `bulk_update`, and `bulk_copy`:
      - Float to Integer coercion (e.g., `14.0` in `Vector{Float64}` to `Int64`).
      - Mixed types in column (Strings that are numeric).
      - Null/Missing handling in required vs optional fields.
      - Foreign key violation reporting in bulk contexts.
      - Duplicate key handling.
  - [ ] **Upsert (`ON CONFLICT`)**: Support for `update_or_create` using `INSERT ... ON CONFLICT DO UPDATE`.

- [ ] **Full-Text Search (FTS)**
  - [ ] Integration with `tsvector` and `tsquery`.
  - [ ] ORM lookups for `search`, `rank`, and `headline`.

## 🛠 Project Infrastructure & Quality

- [x] **Field Validation Test Coverage Gaps - Integration Tests**
  - **Focus**: Database write/read validation (complementary to unit tests), missing field types, delete operations.
  - [x] **Field DB Round-Trip Tests**: Verify all field types persist and retrieve correctly from PostgreSQL/SQLite.
    - Test that ORM-written values match their database representation when read back.
    - Validate type coerccion during write and type recovery during read for each field type.
  - [x] **Missing Field Types DB Tests**: Integration tests for:
    - [x] `TimeField`: Persist time-only values, verify no date contamination.
    - [x] `UUIDField`: Native UUID support, UUID string parsing and round-trip.
    - [x] `URLField`: URL validation at model level and database storage.
    - [x] `SlugField`: Slug validation (alphanumeric + hyphens/underscores) and storage.
    - [/] `JSONField`: JSON serialization and round-trip integrity. (Query support `@>`, `?` operators still missing).
  - [x] **Delete Operations with Constraints**: Test cascading deletes and FK relationship cleanup.
    - [x] Verify `on_delete=CASCADE` removes related records atomically.
    - [x] Verify `on_delete=SET_NULL` nullifies FK fields in related records.
    - [x] Verify `on_delete=PROTECT` prevents deletion when related records exist.
    - [x] Test nested cascade scenarios (3+ levels deep).
  - [x] **DELETE Inspection**: Test query inspection for DELETE operations (currently only SELECT/UPDATE inspected).
    - [x] Verify `query.delete(show_query=:dict)` returns correct SQL and metadata.


## 🏗 Phase 2: Operational Maturity

- [ ] **Advanced Migration Support**
  - [ ] **Rename Operations**: Better detection and handling of renamed models/fields.
  - [ ] **Non-Interactive Renames**: Allow explicit rename hints or declarative rename operations so CI does not depend on prompts.
  - [ ] **Targeted Execution**: Support `migrate_to(version)` / `up(version)` instead of only applying the latest pending diff.
  - [ ] **Rollback / Reversible Migrations**: Support `rollback()`, `down`, `last_down`, and rollback-to-version flows for operational recovery.
  - [ ] **Deployment Safety**: Define startup-safe locking and clear failure semantics for multi-instance deploys.
  - [ ] **Data Migration Support**: Support manual SQL or Julia functions in migrations for complex transformations (e.g., splitting columns).
  - [ ] **Schema Object Coverage**: Add first-class migration support for views, triggers, composite constraints/indexes, and other non-table schema objects.

- [ ] **SQLite Parity**: Carry over PostgreSQL improvements to the SQLite adapter where possible.
- [ ] **Documentation Expansion**:
  - [ ] Expand the Formula 1 dataset examples in the docs.
  - [ ] Add a "PostgreSQL Power User" guide.

## 🔍 Review possible issues

Issues identified during the code review of recent main changes

- [ ] **`do_exists` silently swallows database errors**
  - **Location**: `src/querybuilder/execution.jl`, `do_exists` catch block.
  - **Issue**: Non-`ArgumentError` exceptions (connection failures, SQL errors, permission errors) return `false` instead of propagating. This masks real problems as "does not exist".
  - **Fix**: Rethrow all exceptions except `ArgumentError`; only return `false` when the query legitimately produces zero rows.

- [ ] **`deepcopy(ctes)` → `copy(ctes)` shared-state risk**
  - **Location**: `src/querybuilder/types.jl`, `Base.deepcopy(::SQLObjectQuery)`.
  - **Issue**: Two query objects created via `deepcopy(query)` now share CTE sub-query internal state (filters, values). Mutating a CTE after the copy affects both queries.
  - **Fix**: Document the limitation, or implement a custom deep-copy that clones CTE dict values without traversing Module references.

- [ ] **`resolve_fill_value` DATE/TIMESTAMPTZ asymmetry**
  - **Location**: `src/querybuilder/execution_bulk.jl`, inner `resolve_fill_value` closure.
  - **Issue**: `TIMESTAMPTZ` auto-now values go through `f_meta.formater(now(), tz)` but `DATE` auto-now returns bare `today()` without any formatter. If a `DateField` ever gains a custom formatter, it would be silently bypassed.
  - **Fix**: Pass `DATE` auto-now values through the field formatter for consistency, or add a comment documenting why it's intentionally skipped.

- [x] **`SafeTestsets` is dead weight**
  - **Issue**: Commented out of the only usage (`test/integration/common_setup.jl`) but still declared in `Project.toml` under `[compat]`, `[extras]`, and `[targets]`.
  - **Fix**: Remove from all three `Project.toml` sections.

- [ ] **Think in this aproach** With new aproach:
   # Main query joining CTE
    q = M.Result.objects.with("r91" => races_91).filter(
        "raceid" => F("r91__raceid"),
        "positionorder" => 1
    )

- [ ] **Check name of operators**: `__@ne` or `__@neq`?

## Future Considerations
- [ ] **Parameterize LIMIT/OFFSET (Future)**
  - **Context**: Currently, `LIMIT` and `OFFSET` are rendered as literal integers in the SQL string. This is safe (Julia enforces `Int` types), but parameterizing them would enable prepared statement caching across different page sizes and improve consistency with the bucket strategy.
  - **Task**: Add a `:limit` bucket to `PormGPositionalParam`, render `LIMIT ?` / `OFFSET ?`, and append values at the tail of `get_final_parameters` (after `:having`).
  
# Better then echo """
Write-Output @'
'@ 