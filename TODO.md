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
  - [x] **Integration Tests**: Migration integration tests for SQLite (35/35 tests).
  - [x] **Unit Tests**: Mocked tests for SQL generation in migrations.
  - [ ] **Rename Operations**: Better detection and handling of renamed models/fields.
  - [ ] **Non-Interactive Renames**: Allow explicit rename hints or declarative rename operations so CI does not depend on prompts.
  - [x] **Migration Bootstrap**: Add `init_migrations()` to create/bootstrap the `pormg_migrations` table for new and existing projects.
  - [x] **Migration History Table**: Create `pormg_migrations` table in DB to track applied migrations instead of relying only on filesystem archives.
  - [x] **Migration Status API**: Add `status()` to show pending/applied migrations, failed migrations, and the current schema state.
  - [x] **Dry Run / Plan Review**: Add a no-write mode to inspect or validate the generated plan before applying it in CI or production.
  - [ ] **Targeted Execution**: Support `migrate_to(version)` / `up(version)` instead of only applying the latest pending diff.
  - [ ] **Rollback / Reversible Migrations**: Support `rollback()`, `down`, `last_down`, and rollback-to-version flows for operational recovery.
  - [x] **Migration Integrity**: Record migration IDs and checksums so edited historical files can be detected.
  - [x] **Recovery Operations**: Support repair flows such as `mark_applied`, `mark_failed`, or history reconciliation after manual intervention.
  - [x] **Migration Locking**: Use `AdvisoryLock` to prevent concurrent migration runs during deployment.
  - [ ] **Deployment Safety**: Define startup-safe locking and clear failure semantics for multi-instance deploys.
  - [x] **Destructive Guard**: Prevent `DROP` operations unless a `--force` or `destructive=true` flag is passed.
  - [ ] **Data Migration Support**: Support manual SQL or Julia functions in migrations for complex transformations (e.g., splitting columns).
  - [x] **Docs/API Alignment**: Either implement the documented `MigrationAction` workflow or remove the unsupported docs claim.
  - [x] **Environment Drift Detection**: Compare DB state against model state and applied migration history to surface out-of-band changes.
  - [ ] **Schema Object Coverage**: Add first-class migration support for views, triggers, composite constraints/indexes, and other non-table schema objects.

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

- [ ] **Django Interoperability Integration Tests**
  - **Context**: PormG is used to read and write databases owned by Django apps, so compatibility needs to be validated at the database-behavior level, not only at the model-import level.
  - **Goal**: Add integration tests that exercise the same PostgreSQL tables from both the Django contract perspective and the PormG contract perspective.
  - [ ] **TIMESTAMPTZ Round-Trip**: Verify that Django-style `DateTimeField` columns written by PormG round-trip correctly when interpreted as UTC-backed timestamps.
  - [x] **Naive vs Aware Datetime Semantics**: Define and test how naive Julia `DateTime` values map into Django's `USE_TZ=True` expectations, especially when the Django app timezone is not UTC.
  - [ ] **First Integration Test: Temporal Round-Trip**: Implement a real PostgreSQL test in `test/integration/test_temporal_interop.jl` that:
    1. Creates a `TIMESTAMPTZ` column.
    2. Writes a naive `DateTime`.
    3. Writes a `ZonedDateTime` ("America/Sao_Paulo").
    4. Asserts that the naive value is stored as UTC and the aware value preserves the instant.
  - [ ] **Naive Semantic Check**: Explicitly test that passing a `DateTime(2023, 1, 1, 12, 0)` results in the same database state as `ZonedDateTime(2023, 1, 1, 12, 0, tz"UTC")`.
  - [ ] **Implicit conversion check**: Ensure `DateField` rejects `DateTime` objects to prevent accidental time-truncation bugs without explicit `Date(dt)` calls.
  - [ ] **DateField Round-Trip**: Verify `DateField` inserts/updates remain date-only when read back through Django models.
  - [ ] **auto_now / auto_now_add Compatibility**: Check that PormG-managed timestamp defaults align with Django's expectations for audit fields shared by both applications.
  - [ ] **DecimalField Parity**: Add integration coverage proving PormG numeric validation/serialization matches Django-managed `DecimalField(max_digits, decimal_places)` columns.
  - [ ] **Table Prefix / Sequence Compatibility**: Validate writes against tables using `django_prefix` and confirm primary key/sequence behavior remains consistent after mixed Django/PormG writes.

- [ ] **Advanced Query Expressions**
  - [ ] Support for **Subqueries** (using `OuterRef`).
  - [ ] **Window Functions** (`OVER`, `RANK`, `ROW_NUMBER`).
  - [ ] **Conditional Expressions** (`Case`, `When`) improvements (ensure full PostgreSQL compliance).
  - [ ] **F-Expression** expansion (bitwise operations, complex transformations).
    - [ ] **Date/Time Functions**: add support to `values("fim" => F("transferencia__data_envio__@date") + Day(30))`
    - [ ] **Extend test coverage** for date/time functions to ensure cross-database compatibility and correct SQL generation.

- [ ] **Full Transaction Control**
  - [ ] **Savepoints**: Support for nested transactions/atomic blocks.
  - [ ] **Row-Level Locking**: `select_for_update()` with `SKIP LOCKED` and `OF` support.

- [x] **Query Inspection & Developer Tooling**
  - [x] **Intent Detection**: Improve the `:operation` heuristic in `inspect_query` to distinguish between `:select` and `:delete` without explicit overrides.
  - [ ] **Finalize `show_query` with `:inspection` mode**: Ensure it returns a comprehensive metadata dictionary with consistent keys across all operations (select, insert, update, delete) for use in debugging and potential future tooling (e.g., query logging middleware).
  - [ ] **Metadata Enrichment**: Include additional context in the inspection dict, such as estimated execution time (using EXPLAIN), potential indexes used, and warnings about missing indexes or inefficient queries.
  - [ ] **SQL Formatting**: Add a `:pretty` mode to `show_query` to return formatted/indented SQL for better readability in logs.
  - [ ] **Explain Support**: Add an `explain_query()` API to return the database's `EXPLAIN (ANALYZE, BUFFERS)` output directly as metadata.

- [ ] **Revise API before publication from app**
  - [ ] **Revise the function names**: `list()`, `bulk_insert()`, `bulk_update()`, `delete()`, `do_count()`, and `do_exists()` for consistency and clarity.
  - [ ] **Check alingnment with Julia conventions**: Ensure that the API follows Julia's naming conventions and best practices for function design.
  - [ ] **Revome exportation form functions covered by functors**: If we have functors for certain operations, we might want to remove the corresponding functions exportation from the API to avoid confusion and encourage the use of functors.

- [ ] **Turn CTEs allow to be called by functor like filters**: 
  - [ ] **With**: improve function
  - [ ] **cjoin**: improve function
  - [ ] **Contract**: throw an explicit ArgumentError when join_field is nothing
  - [ ] **Explicit JOIN `ON` predicate API**: add a dedicated API for predicates that must be attached to the join condition itself, instead of reusing `.filter(...)`. This is mainly for cases like reverse joins where users want to keep all base rows and only restrict which related rows are attached.
  - [ ] **Keep `.filter(...)` semantics stable**: relation filters expressed through `.filter(...)` should continue to compile to `WHERE` predicates with Django-style existence semantics, rather than silently moving those predicates into `ON`.
  - [ ] **JOIN semantics docs/tests**: document and test the difference between:
    - relation filters in `WHERE` that restrict the final result set,
    - join predicates in `ON` that preserve base rows but limit joined rows.

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

- [x] **Field Validation Test Coverage Gaps - Unit Tests** (COMPLETED: 358 tests passing)
  - **Focus**: Validation logic in `validate_field_data()` without database round-trips.
  - [x] **Relationship Fields**: ForeignKey & OneToOneField validation in `sanitization.jl`.
  - [x] **Unique Constraint Validation**: `unique=true` enforcement in validator.
  - [x] **String Field Boundaries**: CharField/TextField max_length with Unicode edge cases.
  - [x] **Boolean Edge Cases**: BooleanField truthiness and coercion handling.
  - [x] **Temporal Field Gaps**: TimeField, DateTimeField (timezone-aware), DateField (string formats, boundary times, bulk operations).
  - [x] **Numeric Validation**: FloatField, DecimalField (finite-ness, scale/precision checks).

- [ ] **Field Validation Test Coverage Gaps - Integration Tests**
  - **Focus**: Database write/read validation (complementary to unit tests), missing field types, delete operations.
  - [ ] **Field DB Round-Trip Tests**: Verify all field types persist and retrieve correctly from PostgreSQL/SQLite.
    - Test that ORM-written values match their database representation when read back.
    - Validate type coerccion during write and type recovery during read for each field type.
  - [ ] **Missing Field Types DB Tests**: Integration tests for:
    - `TimeField`: Persist time-only values, verify no date contamination.
    - `UUIDField`: Native UUID support, UUID string parsing and round-trip.
    - `URLField`: URL validation at model level and database storage.
    - `SlugField`: Slug validation (alphanumeric + hyphens/underscores) and storage.
    - `JSONField`: JSON serialization, query support (`@>`, `?` operators), round-trip integrity.
  - [ ] **Delete Operations with Constraints**: Test cascading deletes and FK relationship cleanup.
    - Verify `on_delete=CASCADE` removes related records atomically.
    - Verify `on_delete=SET_NULL` nullifies FK fields in related records.
    - Verify `on_delete=PROTECT` prevents deletion when related records exist.
    - Test nested cascade scenarios (3+ levels deep).
  - [ ] **DELETE Inspection**: Test query inspection for DELETE operations (currently only SELECT/UPDATE inspected).
    - Verify `inspect_query(:delete)` returns correct SQL and metadata.

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
  
