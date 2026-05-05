# Implement ManyToManyField in PormG.jl

This plan details the implementation of a Django-style `ManyToManyField` in PormG.jl. It relies on the blueprint established in `manytomany.md`, refined for Julia's constraints and PormG's specific architecture (async-first execution, state-based migrations).

## Goal
To allow users to define many-to-many relationships naturally on models, auto-generate intermediate join tables via migrations, and traverse these relationships efficiently via the ORM using double-underscore `__` syntax and fluent manager methods.

> [!NOTE]
> As discussed, **Migrations** (creating the tables) will remain a synchronous, developer-driven operation, while **Querying and Mutating** (manager methods) will strictly follow the async-first PormG mandate.

## Proposed Implementation Plan

The implementation is split into two phases to ensure stability: Phase 1 (Explicit Through Models) and Phase 2 (Implicit Through Models). 

---

### Phase 1: Core Functionality & Explicit `through` Models

In this phase, we establish the field metadata, the double-join logic in the QueryBuilder, and the manager methods. We will require the user to define an explicit `through` model to manage the join table.

#### 1. Field Definition
- **[NEW/MODIFY] `src/models/fields.jl` (or equivalent)**
  - Define `ManyToManyField <: PormGField`.
  - Attributes: `to` (target model), `through` (optional join model), `related_name` (string).
  - Modify `PormG.Models_to_str` serialization so migrations can detect field changes.

#### 2. Query Builder Integration
- **[MODIFY] `src/querybuilder/build_joins.jl`**
  - Update `_build_row_join()` to detect when a join targets a `ManyToManyField`.
  - Instead of injecting a single `INNER JOIN`, inject **two** sequential `INNER JOIN`s:
    1. From the source table to the intermediary `through` table.
    2. From the intermediary `through` table to the target table.
  - Ensure reverse relations (via `related_name`) also trigger the double-join logic.

#### 3. M2M Manager (Async-First)
- **[NEW] `src/models/m2m_manager.jl`**
  - Create a `ManyToManyManager` struct bound to a model instance and the field metadata.
  - Implement async-first mutators utilizing `ConnectionPool` locks and transactions:
    - `add_async!(manager, instances...)`
    - `remove_async!(manager, instances...)`
    - `clear_async!(manager)`
    - `set_async!(manager, instances...)` (diff logic wrapped in a transaction)
  - Implement synchronous wrappers (`add!`, `remove!`, etc.) that yield to the Julia scheduler.

#### 4. Reverse Relations
- **[MODIFY] `src/Models.jl`**
  - Update `set_models` or the internal model registration loop to detect `ManyToManyField` and attach the `related_name` manager to the target model, similar to how `ForeignKey` reverse relations are currently handled.

---

### Phase 2: Implicit `through` Generation (Auto-Table)

In this phase, we make `through=nothing` work by synthesizing the join table at the migration layer, removing the need for a physical Julia `struct` for the join table.

#### 1. Migration Synthesis (Synchronous)
- **[MODIFY] `src/migrations/planner.jl` & `src/migrations/introspection.jl`**
  - Update the state-based migration engine.
  - When diffing the current Julia state against the DB schema, if a `ManyToManyField` has `through=nothing`, synthesize a `CreateTable` operation.
  - The table name should follow `<app>_<model>_<field>` convention.
  - The table schema should include an `id` (primary key) and two `ForeignKeyField` references with a composite `UniqueConstraint`.
  - Ensure this is recognized correctly by the `.yml` generated plan and the raw SQL executor.

#### 2. Query Builder Fallback
- **[MODIFY] `src/querybuilder/build_joins.jl`**
  - Ensure the double-join logic built in Phase 1 can fall back to using string table names and explicit column keys when no physical `PormGModel` exists for the `through` table.

## Django Compatibility & Manager Access

Based on the feedback, we will prioritize **Django compatibility** and use the natural `getproperty` syntax (`book.authors.add(author)`). 

### 1. Django Schema Compatibility
To ensure PormG can interface with databases where migrations were originally run by Django (and vice-versa):
- The implicit join table name must follow Django's exact convention: `<app_label>_<model_name>_<field_name>`.
- The foreign key columns in the join table must be named `<source_model>_id` and `<target_model>_id`.
- The join table must have an integer primary key column named `id`.
- The `makemigrations` and `status` commands will reconcile this expected schema against the live database without throwing false positive drift errors.

### 2. Manager Access via `getproperty`
We will implement the manager access via `getproperty` so `book.authors` returns the `ManyToManyManager`.
- **Mitigation for Serialization:** The `Model` struct is indeed lightweight. The only edge case is when PormG serializes a model instance (e.g., during `list_json()`). We will update the serialization logic to ignore properties that evaluate to a `ManyToManyManager` to prevent accidental N+1 query execution or circular references during JSON dumping.

## Verification Plan

### Automated Tests
- Create `test/integration/db_2/m2m_tests.jl` using a Formula 1 fixture (e.g., `Driver` and `Team` with a many-to-many relationship tracking drivers who have tested for multiple teams).
- Test forward and reverse `__` filtering.
- Test `add!`, `remove!`, `clear!`, and `set!` operations, ensuring the DB state is accurately modified.
- Verify that synchronous methods do not block the thread (using `@async` checks).
- Verify `makemigrations()` generates the correct `CREATE TABLE` and `CREATE INDEX` SQL operations for implicit M2M tables.
