# Writing Data with PormG: Overview

This section covers all data manipulation operations in PormG, including creating, updating, and deleting records. PormG provides both single-record and bulk operations for efficient data management.

## Async-First Philosophy

PormG is designed as **Async-First**. All database operations must utilize non-blocking I/O where possible. Synchronous APIs (like `create()`, `update()`, `delete()`) are strictly wrappers around an asynchronous core. This ensures that even synchronous code yields to the Julia scheduler, preventing the blocking of the event loop—essential for integration with web frameworks like Genie.jl.

## Section Contents

- [**Creating Records**](create.md): Learn how to insert individual records and handle relationships.
- [**Updating Records**](update.md): Update existing data using filters and efficient `F-expressions`.
- [**Deleting Records**](delete.md): Safely remove records with cascading support.
- [**Bulk Operations**](bulk.md): Efficiently handle large datasets with `bulk_insert`, `bulk_copy`, and `bulk_update`.

## Performance Overview

| Operation | Best For | Speed | Protocol |
| :--- | :--- | :--- | :--- |
| `create()` | Single rows | Standard | SQL INSERT |
| `row.save()` | Persisting one fetched row | Standard | SQL UPDATE |
| `bulk_insert()` | Medium datasets (< 10k rows) | Fast | Multi-row INSERT |
| `bulk_copy()` ⭐ | Massive datasets | Ultra-Fast | Postgres COPY |
| `update()` | Selective updates | Standard | SQL UPDATE |
| `bulk_update()` | Modifying many rows | Fast | Multi-row UPDATE |

⭐ **PostgreSQL Only**: `bulk_copy()` uses PostgreSQL's native `COPY FROM STDIN` protocol and is not available for SQLite. For SQLite, use `bulk_insert()` instead.
