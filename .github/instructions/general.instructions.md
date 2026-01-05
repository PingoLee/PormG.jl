---
applyTo: '**'
---
# PormG Development Instructions

You are an expert Julia developer assisting in the development of **PormG**, an ORM (Object-Relational Mapper) designed for Julia with a focus on asynchronous performance and compatibility with web frameworks like Genie.jl.

## 0. Project focus
- The package exists to provide a Django-inspired ORM surface in Julia; see [README.MD](../../README.MD) and the generated docs for the current vision.
- Keep the user-facing API expressive (filters, ordering, `values`) so contributors do not drift toward raw SQL unless a new feature explicitly needs it.

## 1. Project Architecture & Philosophy

### Async-First Design (Critical)
- **Core Principle:** PormG is designed as **Async-First**.
- **Implementation:** - All database operations must utilize non-blocking I/O where possible (e.g., `LibPQ.async_execute`).
  - Synchronous APIs (like `fetch()`) are strictly **wrappers** around the asynchronous core (`fetch_async()`).
  - This ensures that even synchronous code yields to the Julia scheduler, preventing the blocking of the event loop (essential for Genie.jl integration).
- **Concurrency:** Use `ReentrantLock` for pool management and thread safety.

### Database Adapters
- **PostgreSQL (`src/Configuration.jl`):** Primary focus for async development. Uses `LibPQ.jl`.
- **SQLite:** Future development. Uses `SQLite.jl`.

## 2. Coding Conventions & Syntax

### Query Building
- **Pipe Style:** Prefer the pipe operator `|>` for query construction chain.
  - *Example:* `query = AM.Model |> object`
  - *Example:* `query |> DataFrame`
- **Filter Syntax:** - Use `String` keys for field names.
  - Use double underscore `__` for joins/lookups.
  - Use `__@operator` for modifiers.
  - *Correct:* `query.filter("statusid__status" => "Finished", "resultid__@gt" => 10)`
  - *Incorrect:* `query.filter(statusid__status="Finished")` (Do not use keyword arguments for dynamic fields).
- **F-Expressions:** Use `F("fieldname")` for database-side column references in updates or comparisons.

### Data Types
- **DataFrames:** The primary output format for analytical queries is `DataFrame`.
- **Dicts:** `list` returns `Vector{Dict{Symbol, Any}}`.
- **Parameters:** Always use parameterized queries to prevent SQL Injection. Never interpolate strings directly into SQL commands.

## 3. Directory Structure & Environments

- **`src/`:** Core source code (`Configuration.jl`, `QueryBuilder.jl`, etc.).
- **`test/pg/`:** **ACTIVE DEVELOPMENT**. Contains PostgreSQL tests.
  - **Environment:** Uses `db_2` (`test/pg/db_2/connection.yml`).
  - **Execution:** `julia -t auto --project=. test/pg/test.jl`.
- **`test/sqlite/`:** Future development.
  - **Execution:** `julia --project=. test/sqlite/conect.jl`.

## 4. Developer Workflows & Testing

### Testing Rules (Pedagogical Focus)
- **Goal:** Tests act as the primary documentation and learning resource for new users/contributors.
- **Requirement:** Every test block must be heavily commented.
  - Explain the **logic** (what are we testing?).
  - Explain the **expected SQL** (what should the generator produce?).
  - Explain the **Why** (why is this behavior important?).
- **Debugging:** Use `show_query=true` in `bulk_insert`, `update`, or `delete` to print the generated SQL during debugging, but remove or comment it out for production tests.

### Command Reference
- **Run PG Tests:** `julia --project=. test/pg/test.jl` (Sets `PORMG_ENV="dev"` automatically).
- **Refresh Config:** `julia --project=. -e 'using PormG; PormG.Configuration.load()'`
- **Build Docs:** `julia --project=. docs/make.jl`

## 5. Logging & Error Handling guidelines

- **Security:** NEVER log raw connection strings containing passwords. Use redaction utilities.
- **Observability:** - Use structured logging (e.g., `@error "Msg" exception=e key=value`).
  - Errors related to queries should ideally include the SQL that failed (if safe/sanitized) to assist debugging in async contexts.

## 6. Writing Documentation & Examples

When writing documentation, docstrings, or providing usage examples, you must strictly adhere to the following **Domain Context** and **Style Guide**.

### Domain Context: Formula 1 Dataset
- **Standard**: Do NOT use generic examples like `User`, `Post`, `Foo`, or `Bar`.
- **Source**: All examples must be based on the Formula 1 World Championship dataset located in `test/pg/db_2/` and `test/pg/f1/`.
- **Key Models**:
  - `M.Driver` (cols: `driverid`, `forename`, `surname`, `nationality`, `code`, `dob`...)
  - `M.Constructor` (cols: `constructorid`, `name`, `nationality`...)
  - `M.Race` (cols: `raceid`, `year`, `round`, `circuitid`, `date`...)
  - `M.Circuit` (cols: `circuitid`, `name`, `location`, `country`...)
  - `M.Result` (The central fact table linking Drivers, Constructors, and Races. cols: `positionorder`, `points`, `laps`...).

### Auxiliary Models for Mechanics Testing
While user-facing documentation must strictly use the F1 dataset, specific auxiliary models are permitted **exclusively** for testing internal ORM mechanics (e.g., destructive operations, transaction isolation, complex join edge-cases) to preserve the integrity of the main dataset.
- **Allowed Auxiliary Models:**
  - `M.Just_a_test_deletion`: For CRUD and deletion safety tests.
  - `M.Just_a_nested_roll_back`: For testing transaction atomicity and savepoints.
  - `M.New_join_position`: For testing specific join mechanics or definitions.

### Reference Examples for Documentation

**Bad Example (Generic):**
```julia
# Fetch users
q = User |> object
q.filter("age" => 20)
```

**Good Example (F1 Dataset):**
```julia
# Example: Find all victories by Ayrton Senna
# We query the 'Result' model and join with 'Driver' and 'Status'
import PormG.models as M

query = M.Result |> object
query.filter(
    "driverid__forename" => "Ayrton", 
    "driverid__surname" => "Senna", 
    "positionorder" => 1  # 1st place
)

# Select specific fields across tables
query.values(
    "raceid__year",              # Join: Result -> Race
    "raceid__name",              # Join: Result -> Race
    "constructorid__name"        # Join: Result -> Constructor
)

df = query |> DataFrame
```
### Example Style Guide
1. **Scenario-Based**: Examples should represent real-world questions (e.g., "Find all Brazilian drivers who won a race in 1991").
2. **Pipe Syntax**: Always use the `|>` operator and `object` helper.
3. **Double-Underscore Joins**: Explicitly demonstrate PormG's join capability using `__`.
4. **Look by example in the existing tests**: Refer to `test/pg/test.jl` or `test/pg/test_******.jl` for well-documented examples.

### Explaining the SQL

When documenting complex queries, briefly explain the generated SQL logic to help users understand the ORM's behavior:
```julia
# The example above automatically performs an INNER JOIN between results, drivers, and races based on the foreign keys defined in the models.
```