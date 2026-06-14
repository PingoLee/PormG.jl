# TODO List

This document tracks missing features and planned improvements for PormG.jl, with a focus on reaching parity with Django-style ORM capabilities and leveraging PostgreSQL-specific power features.

## 🚀 High Priority: Core ORM Parity

- [ ] **Bulk Operation API Refactoring**
  - **Context**: Currently, `bulk_update(filters=...)` handles both DataFrame column mapping and static SQL filters. While flexible, this leads to ambiguity and potential breaking changes if column names overlap with model fields.
  - **Goal**: Introduce a clearer separation (e.g., `mapping` vs `filters` or explicitly typed objects) to improve type safety and readability without breaking legacy support.

- [/] **Advanced Query Expressions**
  - [x] Support for **Subqueries** (using `OuterRef`). — Correlated `Exists(subquery)`, `OuterRef("field")`, and `__@in` subquery membership tests are fully implemented and tested. Gaps: no scalar subqueries, no UNION/set operations.
  - [x] **Window Functions** (`OVER`, `RANK`, `ROW_NUMBER`). — Implemented inline `OVER` support with `WindowOver`, `Rank`, `DenseRank`, `RowNumber`, `Lag`, `Lead`, `FirstValue`, `LastValue`, and `NthValue`. Remaining gaps: aggregate-over-window helpers, named `WINDOW` clauses, and SQLite explicit frame support.
  - [x] **Conditional Expressions** (`Case`, `When`). — Fully implemented. Works in `values()`, `filter()`, and `update()` SET clauses; nests correctly inside aggregates like `Sum(Case([...]))`.
  - [/] **F-Expression** expansion.
    - [x] Arithmetic (`+`, `-`, `*`, `/`) and comparison operators (`==`, `>`, `<=`, etc.) — fully implemented, including field-to-field arithmetic and chaining.
    - [x] **Bitwise operations** (`&`, `|`, `⊻`/`xor`, `<<`, `>>`) — fully implemented and verified on SQLite & PostgreSQL.
    - [x] **Date/Time extraction**: `Extract()`, `@date`, `@year`, `@month`, `@day`, `@quarter` lookups — implemented and dialect-aware.
    - [/] **Date arithmetic with duration types**: Integer-offset `F("date") + 30` works. Explicit Julia duration types like `Day(30)` / `Interval()` are not recognized — arithmetic relies on bare integers interpreted as days by the dialect.
    - [ ] **Extend test coverage** for date/time functions to ensure cross-database compatibility and correct SQL generation.


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
    - [x] **Testing & Alignment Verification**:
      - [x] **Positional Cross-Check**: Create tests that count the number of `?` in each SQL block (SELECT, JOIN, WHERE) and compare them against the length of the corresponding parameter bucket.
      - [x] **Execution Order Stress Test**: Specifically test queries where JOINs are calculated dynamically based on filters to ensure parameter positions don't drift.
      - [x] **Subquery Isolation**: Verify that nested subqueries correctly restore the parent's `current_context` after execution.
      - [x] **Unit Tests**: Implement these using `inspect_query` and mocked connections in `test/unit/test_parameters.jl`.

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
  - [x] **Dataframes Type Normalization**: Create integration tests for bulk operation type normalization in `execution_bulk.jl`.
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

- [ ] **Isolated PostgreSQL migration fixture (`db_test_migration_pg/`)**
  - **Context**: The migration edge-case suite in `test/integration/test_migration_bootstrap.jl` (Phase C) needs a throwaway database. When `test/integration/db_test_migration_pg/connection.yml` is absent, it falls back to hydrating from the *selected* integration DB and runs `_reset_postgres!`, which **drops every table in `public`** ([test_migration_bootstrap.jl:180](test/integration/test_migration_bootstrap.jl#L180)). Running the Postgres edge-case suite against the shared `db_2` (`pormg_teste`) would therefore wipe it.
  - **Goal**: Commit a `db_test_migration_pg/connection.yml` pointing at a dedicated, disposable PostgreSQL database (separate from `db_2`) so the full Postgres edge-case suite — including the `PositiveSmallIntegerField` CHECK lifecycle (Phase 8a2) — runs in isolation without risking the shared integration DB.
  - **Status**: The CHECK lifecycle is already verified — through the real `makemigrations`/`migrate` engine on SQLite (Phase 8a2 passes), and via the live `get_constraints_check` / `alter_field` introspection paths on PostgreSQL. This item only tracks wiring the isolated fixture so Phase 8a2 also runs end-to-end on Postgres in CI.


- [ ] **Investigate PG pool exhaustion under remote-latency integration runs**
  - **Symptom**: Running `test/integration/runtests.jl` against the remote `db_2` (`pormg_teste` @ 187.121.224.221) logs `PG pool expanded beyond initial size (current_size=15, initial_size=3)` followed by repeated `No available PG connections, retrying (N/300)`.
  - **Root cause (current understanding)**: The `dev` section of [test/integration/db_2/connection.yml](test/integration/db_2/connection.yml) sets no `pool_size`, so it defaults to **3** ([Configuration.jl:221](src/Configuration.jl#L221)); the hard expansion cap is `pool_size * 5` = **15** ([ConnectionPool.jl:244](src/ConnectionPool.jl#L244)). The async-first suite saturates the small pool against a high-latency remote DB and parks callers in the 100ms retry loop. All release paths (`await_result`/`run_in_transaction` `finally`, `fetch_async` error path) appear correct — this looks like sizing/contention, not a leak.
  - **To verify**: Confirm whether the suite ever reaches `300/300` and throws (genuine starvation) vs. recovering after a few retries (transient backpressure). If it only recovers, the warnings are cosmetic; if it throws/hangs, sizing is mandatory.
  - **Likely fix**: Add `pool_size: 15` (or higher) under the `dev` section so the initial pool is large enough that it never expands, and the cap rises accordingly. Consider lowering the `@warn`/retry noise or making expansion silent up to the cap.
  - **Also audit**: whether any code path calls `fetch_async` without an `await_result` (would leak a connection), and whether `bulk_*`/`inspect_query`/COPY paths always release.

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

- [ ] **Performance & Type Stability**
  - **Context**: `list()` now returns `Vector{PormGRow}` by default, while `list(:dict)` preserves the dynamic dictionary path for integrations that require real `Dict` values. Fully concrete application structs would still be faster for high-throughput Nitro.jl applications.
  - **Goal**: Allow queries to return concrete Julia `struct` types instead of dynamically typed Dictionaries.
  - [ ] **Strongly Typed Model Returns (Nitro compatibility)**: Implement `list_as(query, MyModel)` or similar to map DB results directly to typed structs.
  - [ ] **Fast JSON Serialization**: Optimize serialization path (e.g., via `JSON3.jl`) to leverage type-stable structs for lightning-fast JSON output.
  - [ ] **Review `OperObject.values` Type Design**: Evaluate whether the large Union in `OperObject.values` should stay as-is, be grouped behind type aliases, or move to a parametric/tagged representation. Only pursue a runtime change if profiling shows it is a real bottleneck.
  - [ ] **Allocation Reduction with IO Strategy**:
    - **Context**: String concatenation (`*=` and interpolation) in the query builder triggers significant GC overhead.
    - [ ] Expand the `IOBuffer` approach used in `query()` to `insert()`, `update()`, `delete()`, `do_count()`, and `do_exists()`.
    - [ ] Refactor internal helper functions (`_query_select`, `build_cte_clause`, etc.) to optionally take an `IO` object.
  - [ ] **Performance Benchmarking**: Establish a baseline for query generation and execution overhead.
  - [ ] **Thread Safety**: Audit connection pool for concurrent `Async` safety.

## 🔍 Review possible issues

Issues identified during the code review of recent main changes

- [ ] **`Base.getproperty(q::ObjectHandler)` — accumulated issues** (`src/querybuilder/object_manager.jl`)
  Several unrelated problems were noticed while working on the `list(format)` / `PormGRow` feature. None are blockers today but should be addressed before a public release.

  - [ ] **`:inspect_query` alias** — `sym === :inspect_query || sym === :inspect` has the same problem as `:all` had for `:list`: two names for one terminal, only the shorter `:inspect` should survive. The alias won't forward new positional args if `:inspect` ever gains them.

  - [ ] **`:count` and `:exists` silently ignore `show_query`** — both are bound as `return () -> do_count(q)` with no kwargs. There is no way to inspect the generated SQL. Should become `return (; show_query=:execute) -> do_count(q; show_query=show_query)` (and same for `:exists`).

  - [ ] **`args...` is widespread and type-unstable** — `:with`, `:cjoin`, `:on`, `:create`, `:update` all use `(args...; kwargs...)`. The compiler cannot infer return types for these closures. For chainable methods this is tolerable (return type is always `ObjectHandler`), but for `:create` and `:update` the return type is unknown. Consider typed signatures where the argument shape is fixed.

  - [ ] **Category 2/3 comment is mis-indented** — the `# === CATEGORY 2: Terminal methods ===` comment sits inside the `elseif sym === :copy` block due to indentation, making the structure misleading when reading the file. Cosmetic but confusing.

- [ ] **`deepcopy(ctes)` → `copy(ctes)` shared-state risk**
  - **Location**: `src/querybuilder/types.jl`, `Base.deepcopy(::SQLObjectQuery)`.
  - **Issue**: Two query objects created via `deepcopy(query)` now share CTE sub-query internal state (filters, values). Mutating a CTE after the copy affects both queries.
  - **Fix**: Document the limitation, or implement a custom deep-copy that clones CTE dict values without traversing Module references.

- [ ] **Think in this aproach** With new aproach:
   # Main query joining CTE
    q = M.Result.objects.with("r91" => races_91).filter(
        "raceid" => F("r91__raceid"),
        "positionorder" => 1
    )


## Future Considerations
- [ ] **Parameterize LIMIT/OFFSET (Future)**
  - **Context**: Currently, `LIMIT` and `OFFSET` are rendered as literal integers in the SQL string. This is safe (Julia enforces `Int` types), but parameterizing them would enable prepared statement caching across different page sizes and improve consistency with the bucket strategy.
  - **Task**: Add a `:limit` bucket to `PormGPositionalParam`, render `LIMIT ?` / `OFFSET ?`, and append values at the tail of `get_final_parameters` (after `:having`).
  
# Better then echo """
Write-Output @'
'@ 

# how review
@workspace /review  review unstaged changes before push