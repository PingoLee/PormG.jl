# API Documentation for PormG

## Overview

The `PormG` module provides a set of abstractions and functions for working with SQL databases in Julia. It includes various types for SQL operations, models, and migrations, along with utilities for querying and manipulating data.

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

