# PormG.jl TODO List

This document tracks missing features and planned improvements for PormG.jl, with a focus on reaching parity with Django-style ORM capabilities and leveraging PostgreSQL-specific power features.

## 🚀 High Priority: Core ORM Parity

- [x] **SQLite Migration Improvements**
  - [x] Use PRAGMA for introspection (reliable schema reading).
  - [x] Support multiple dispatch for Dialect (Postgres vs SQLite separation).
  - [x] Consistent type mapping using `type_map`.

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

- [ ] **Complete Migration Support**
  - [ ] **Rename Operations**: Better detection and handling of renamed models/fields.
  - [ ] **Forward/Backward migrations**: Ensure all operations are reversible.

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
- [ ] **Documentation**:
  - [ ] Expand the Formula 1 dataset examples in the docs.
  - [ ] Add a "PostgreSQL Power User" guide.
- [ ] **Thread Safety**: Audit connection pool for concurrent `Async` safety.
