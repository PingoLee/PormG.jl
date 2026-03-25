# API Documentation for PormG

## Overview

The `PormG` module provides a set of abstractions and functions for working with SQL databases in Julia. It includes various types for SQL operations, models, and migrations, along with utilities for querying and manipulating data. Detailed documentation for reading operations can be found in the [Reading Overview](read/index.md).

## Query Chaining (Functor API)

PormG embraces a Django-style, object-oriented query builder approach.
Most database operations are not standalone functions, but rather methods chained directly from the `Model.objects` entrypoint.

### Chainable Methods (Return Handler)
These methods modify the query builder and allow further chaining:
- `filter(key => value)`
- `values("field1", "field2")` — or use `"*"` to select all main-table columns: `.values("*", "joined_model__field")`
- `order_by("-field")`
- `limit(10)`, `offset(5)`
- `with("cte_name" => sub_query)`
- `cjoin("field" => "TargetModel")`
- `on("join_path", "field" => value)`

> [!IMPORTANT]
> Queries that use `cjoin()` **must** call `.values(...)` explicitly before execution.
> A bare `SELECT *` across joined tables causes `DataFrames.jl` to crash with
> `ArgumentError: Duplicate variable names`. PormG will throw a clear error if you forget.
> Use `.values("*", "joined_model__field")` to quickly select all main-table columns
> plus specific fields from the joined table.

### Terminal Methods (Execute Query)
These methods finalize the query and execute it against the database:
- `list()`: Returns the result set
- `list_json()`: Returns results as a JSON string
- `count()`: Runs a `SELECT COUNT(*)` and returns an integer
- `exists()`: Returns a boolean indicating if matching records exist
- `create(key => value)`: Inserts a single record and returns it
- `update(key => value)`: Updates matching records
- `delete()`: Deletes matching records

**Example:**
```julia
M.Driver.objects.filter("nationality" => "British").order_by("surname").list()
```

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

### `bulk_insert`
- **Description**: Inserts multiple records into the database in a single operation.
- **Usage**: `bulk_insert(...)`

### `bulk_update`
- **Description**: Updates multiple records in the database in a single operation.
- **Usage**: `bulk_update(...)`

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
# Single insert via functor
record = M.Driver.objects.create("surname" => "Hamilton", "nationality" => "British")

# Bulk insert remains a free function
bulk_insert(M.Driver.objects, data)  # data is a Vector of NamedTuples or Dicts
```

### Querying Records
```julia
# Django-style chaining (preferred API)
results = M.Driver.objects.filter("nationality" => "British").list()

# With a custom join — must specify values() to avoid duplicate columns
results = M.Result.objects
  .cjoin("driverid" => "Driver", filters=["nationality" => "Brazilian"])
  .values("*", "driverid__surname")
  .list()
```

## Conclusion

This documentation provides an overview of the API for the `PormG` module. For more detailed information on each function and type, please refer to the source code and additional documentation files.
# API Reference

```@autodocs
Modules = [PormG, PormG.QueryBuilder, PormG.Models]
Order   = [:function, :type]
```

