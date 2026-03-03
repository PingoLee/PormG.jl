# TODO List

This document tracks missing features and planned improvements for PormG.jl, with a focus on reaching parity with Django-style ORM capabilities and leveraging PostgreSQL-specific power features.

## 🚀 High Priority: Core ORM Parity

- [x] **SQLite Migration Improvements**
  - [x] Use PRAGMA for introspection (reliable schema reading).
  - [x] Support multiple dispatch for Dialect (Postgres vs SQLite separation).
  - [x] Consistent type mapping using `type_map`.

- [ ] **Bulk Operation API Refactoring**
  - **Context**: Currently, `bulk_update(filters=...)` handles both DataFrame column mapping and static SQL filters. While flexible, this leads to ambiguity and potential breaking changes if column names overlap with model fields.
  - **Goal**: Introduce a clearer separation (e.g., `mapping` vs `filters` or explicitly typed objects) to improve type safety and readability without breaking legacy support.

- [x] **Complete Migration Support**
  - [x] **Integration Tests**: Migration integration tests for SQLite (15/15 tests).
  - [ ] **Unit Tests**: Mocked tests for SQL generation in migrations.
  - [ ] **Rename Operations**: Better detection and handling of renamed models/fields.
  - [ ] **Migration Locking**: Use `AdvisoryLock` to prevent concurrent migration runs during deployment.  
  - [ ] **Destructive Guard**: Prevent `DROP` operations unless a `--force` or `destructive=true` flag is passed.
  - [ ] **Data Migration Support**: Support manual SQL or Julia functions in `pending_migrations.jl` for complex transformations (e.g., splitting columns).  

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

- [ ] **Modern Testing & CI**
  - [x] Create root `test/runtests.jl` for unified test entry.
  - [x] Implement **Unit Tests** for SQL generation (Mocked migrations).
  - [ ] Add **GitHub Actions CI** configuration to run unit tests on push.
  - [ ] Move existing DB tests to `test/integration`.

- [ ] **Advanced Query Expressions**
  - [ ] Support for **Subqueries** (using `OuterRef`).
  - [ ] **Window Functions** (`OVER`, `RANK`, `ROW_NUMBER`).
  - [ ] **Conditional Expressions** (`Case`, `When`) improvements (ensure full PostgreSQL compliance).
  - [ ] **F-Expression** expansion (bitwise operations, complex transformations).

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
  - [ ] **Upsert (`ON CONFLICT`)**: Support for `update_or_create` using `INSERT ... ON CONFLICT DO UPDATE`.

- [ ] **Full-Text Search (FTS)**
  - [ ] Integration with `tsvector` and `tsquery`.
  - [ ] ORM lookups for `search`, `rank`, and `headline`.

## 🛠 Project Infrastructure & Quality

- [ ] **SQLite Parity**: Carry over PostgreSQL improvements to the SQLite adapter where possible.
- [ ] **Performance Benchmarking**: Establish a baseline for query generation and execution overhead.
- [ ] **Allocation Reduction with IO Strategy** - **priority**: -------------------------------------------------
  - **Context**: String concatenation (`*=` and interpolation) in the query builder triggers significant GC overhead.
  - **Task**: Expand the `IOBuffer` approach used in `query()` to `insert()`, `update()`, `delete()`, `do_count()`, and `do_exists()`.
  - **Task**: Refactor internal helper functions (`_query_select`, `build_cte_clause`, etc.) to optionally take an `IO` object to enable end-to-end string building with minimal allocations.
  - **Testing**: Profile with `@time` and `BenchmarkTools` to confirm allocation reduction across dialects.
- [ ] **Documentation**:
  - [ ] Expand the Formula 1 dataset examples in the docs.
  - [ ] Add a "PostgreSQL Power User" guide.
- [ ] **Thread Safety**: Audit connection pool for concurrent `Async` safety.

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
- [ ] **Advanced Migration Architecture (Future)**
  - [ ] **Migration History Table**: Create `pormg_migrations` table in DB to track applied migrations (stop relying only on filesystem).
  - [ ] **State-based Rollback**: Implement `rollback()` to automatically restore schema from `old_models.jl` history.