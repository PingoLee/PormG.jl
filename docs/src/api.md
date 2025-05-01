# API Documentation for PormG

## Overview

The `PormG` module provides a set of abstractions and functions for working with SQL databases in Julia. It includes various types for SQL operations, models, and migrations, along with utilities for querying and manipulating data.

## Exported Functions

### `object`
- **Description**: Retrieves an object from the database.
- **Usage**: `object(...)`

### `show_query`
- **Description**: Displays the SQL query that will be executed.
- **Usage**: `show_query(...)`

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