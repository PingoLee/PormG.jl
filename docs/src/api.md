# API Documentation for PormG

## Overview

The `PormG` module provides a set of abstractions and functions for working with SQL databases in Julia. It includes various types for SQL operations, models, and migrations, along with utilities for querying and manipulating data. Detailed documentation for reading operations can be found in the [Reading Overview](read/index.md).

## Exported Functions

### `object`
- **Description**: Retrieves an object from the database.
- **Usage**: `query = M.Model_name.objects;`

### `show_query`
- **Description**: Integrated switch in all query execution methods to toggle between execution and inspection.
- **Modes**: 
  - `:execute` (default) - Executes the query and returns results
  - `:sql` - Returns SQL **string** only (Minimal overhead for benchmarking)
  - `:dict` - Returns full metadata dictionary (sql, parameters, dialect, model, operation, etc.)
  - `:params` - Returns parameters array only
  - `:none` - Returns `nothing` (Zero-overhead mode for benchmarking the builder itself)
- **Usage**: 
  ```julia
  query = M.Driver.objects.filter("nationality" => "British")
  # Benchmark the builder without execution or return overhead
  @time query.list(show_query=:none) 
  ```

### `inspect_query`
- **Description**: Dedicated API for comprehensive query inspection without executing. It returns rich metadata and features a **heuristic intent detector** that guesses the operation type (select, insert, update) based on the object state.
- **Returns**: A `Dict` with full metadata (sql, parameters, dialect, model, operation, bucketing, etc.)
- **Usage**: 
  ```julia
  query = M.Driver.objects.filter("nationality" => "Brazilian").order_by("surname")
  inspection = query |> inspect_query()
  println(inspection[:operation]) # Automatically detects :select
  ```
- **Note on parameter buckets:** `LIMIT` and `OFFSET` values are rendered as literal integers in the SQL string and do **not** appear in `inspection[:parameter_buckets]` or `inspection[:parameters]`. This is by design.

### `list`
- **Description**: Lists records from the database.
- **Usage**: `list(...)`

### `bulk_insert`
- **Description**: Inserts multiple records into the database in a single operation.
- **Usage**: `bulk_insert(...)`

### `bulk_update`
- **Description**: Updates multiple records in the database in a single operation.
- **Usage**: `bulk_update(...)`

### `delete`
- **Description**: Deletes records from the database.
- **Usage**: `delete(...)`

### `do_count`
- **Description**: Counts the number of records that match a query.
- **Usage**: `do_count(...)`

### `do_exists`
- **Description**: Checks if any records exist that match a query.
- **Usage**: `do_exists(...)`

### `with_advisory_lock`
- **Description**: Executes a function while holding a PostgreSQL advisory lock.
- **Usage**: `with_advisory_lock(db_key, lock_key) do ... end`

## Server-Facing Configuration API

The following entries document the server-facing configuration API for applications that bootstrap multiple databases and expose health endpoints.

### `Configuration.load(path; env=nothing)`
- **Description**: Loads or reloads a static database folder using an explicit environment override when provided.
- **Why**: Prevents server startup from relying entirely on global `ENV["PORMG_ENV"]` mutation.
- **Target usage**:
  ```julia
  PormG.Configuration.load("db"; env="prod")
  PormG.Configuration.load("db_sch"; env="prod")
  ```

### `Configuration.load_many(paths; env=nothing)`
- **Description**: Bootstraps several static configuration folders in one call.
- **Why**: Server applications frequently load multiple model folders and should not need custom loops over `Configuration.load(...)`.
- **Target usage**:
  ```julia
  PormG.Configuration.load_many(["db", "db_sch"]; env=config.env)
  ```

### `Configuration.is_loaded(path_or_key)`
- **Description**: Reports whether PormG has already registered settings for a given folder path or connection key.
- **Why**: Applications should not use `get_settings(...)` as a proxy for registration checks.

### `Configuration.ping(path_or_key)`
- **Description**: Performs a real reachability check against the configured database.
- **Why**: A health endpoint must distinguish "settings exist" from "database is actually reachable".

### `Configuration.status(path_or_key)`
- **Description**: Returns a richer status payload combining loaded state, reachability, adapter, and environment.
- **Why**: Worker diagnostics and HTTP health handlers often need more than a `Bool`.

For the design rationale and the environment-order hazard caused by eager `@import_models` loading, see [configuration.md](configuration.md).

## Abstract Types

### `PormGAbstractType`
- **Description**: The base abstract type for all types in the PormG module.

### `SQLConn`
- **Description**: Represents a connection to a SQL database.

### `SQLObject`
- **Description**: Represents an object that can be stored in the database.

### `SQLObjectHandler`
- **Description**: Handles operations related to SQL objects.

### `SQLTableAlias`
- **Description**: Manages table aliases in SQL queries.

### `SQLInstruction`
- **Description**: Represents an instruction to build a SQL query.

### `SQLType`
- **Description**: Base type for SQL-related types.

### `SQLTypeField`
- **Description**: Represents a field to be used in SQL queries.

## Usage Examples

### Connecting to a Database
```julia
conn = SQLConn(...)  # Create a connection to the database
```

### Inserting Records
```julia
bulk_insert(conn, data)  # Insert multiple records
```

### Querying Records
```julia
results = list(conn, query)  # Retrieve records based on a query
```

## Conclusion

This documentation provides an overview of the API for the `PormG` module. For more detailed information on each function and type, please refer to the source code and additional documentation files.
# API Reference

```@autodocs
Modules = [PormG, PormG.QueryBuilder, PormG.Models]
Order   = [:function, :type]
```

