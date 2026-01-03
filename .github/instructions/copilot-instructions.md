applyTo: "**"
---
# Project focus
- The package exists to provide a Django-inspired ORM surface in Julia; see [README.MD](../../README.MD) and the generated docs for the current vision.
- Keep the user-facing API expressive (filters, ordering, `values`) so contributors do not drift toward raw SQL unless a new feature explicitly needs it.

# Architecture & data flow
- Load behavior is rooted in [src/PormG.jl](../../src/PormG.jl): it pulls together `Configuration`, `Models`, `QueryBuilder`, `Dialect`, `Migrations`, and exports `object`, `list`, `bulk_update`, etc.
- `src/Configuration.jl` plus [src/constants.jl](../../src/constants.jl) define `DB_PATH`, `PORMG_ENV`, the `config` cache, and the transaction/connection-pool helpers guaranteed to be initialized by `Configuration.load()`.
- `src/Generator.jl` sits beside `PORMG_DB_CONFIG_FILE_NAME`; calling `Generator.create_db_folder_and_yml()` gives you the expected `db/connection.yml` bootstrap before any other workflow touches the file.
- Dialect-specific SQL lives in [src/Dialect.jl](../../src/Dialect.jl); any change to how columns, functions, or migrations render must keep both the PostgreSQL and SQLite helper versions consistent.
# Models & query patterns
- Define models with `Models.Model` and always call `Models.set_models(@__MODULE__, @__DIR__)` after the module so `related_objects`, `connect_key`, and the cache are populated (see [test/db/models/automatic_models.jl](../../test/db/models/automatic_models.jl) for how auto-generated modules look).
- `Models.Model_to_str` is the serialization layer used by migrations and import helpers; it mirrors the kwargs you pass in `Model(...)` and should be updated whenever field structs gain new keyword arguments.
- Query building happens through [src/QueryBuilder.jl](../../src/QueryBuilder.jl); pipe a model module into `object`, then call `filter`, `values`, `order_by`, and `update` on the returned `SQLObjectQuery`.
- `src/Migrations.jl` exposes `get_database_schema`, `convertSQLToModel`, `import_models_from_sql`, and a makemigrations-style diff engine you can call from scripts when schema drift appears.

# Developer workflows

- **Core Architecture (Async-First)**:
  - The system follows an **Async-First** design pattern meant for all adapters (PostgreSQL, SQLite, etc.).
  - **Implementation**: The synchronous `fetch` API is implemented as a wrapper around the asynchronous `fetch_async` core (see `src/Configuration.jl`).
  - **Benefit**: This allows standard synchronous code to automatically yield to the Julia scheduler, ensuring compatibility with asynchronous frameworks like **Genie.jl** without blocking the event loop.
  - **PostgreSQL**: Leverages `LibPQ.jl` for non-blocking I/O (reads and writes).

- **PostgreSQL Development (Active Focus)**:
  - The active development is currently centered on the PostgreSQL implementation.
  - Located in `test/pg/` using the **db_2** environment (`test/pg/db_2/connection.yml`).
  - Run tests: `julia --project=. test/pg/test.jl` (sets `ENV["PORMG_ENV"] = "dev"`).

- **SQLite Development**:
  - Isolated in `test/sqlite/`.
  - Run tests: `julia --project=. test/sqlite/conect.jl`.

- **Pedagogical Testing Guidelines**:
  - Tests act as the primary learning resource.
  - **Requirement**: Code must be heavily commented to explain the logic, expected SQL output, and design decisions (especially the Async-wrapping behavior) for future contributors.

- **Configuration & Docs**:
  - Refresh config: `julia --project=. -e 'using PormG; PormG.Configuration.load()'`.
  - Build docs: `julia --project=. docs/make.jl`.

# Logging & error handling
- Continue the existing habit: log errors with contextual metadata and emit colored CLI output when reporting failures so that regressions remain easy to spot.
- When catching or rethrowing (for example in `Models.deepcopy`), include the `@error` message that captured the original exception so that formatters in `docs` or CI can correlate stack traces.
