# Query Examples and Search Operations

This document provides comprehensive examples of how to perform various database operations using PormG.

## Table of Contents

- [Basic Query Operations](#basic-query-operations)
- [Filtering Data](#filtering-data)
- [Value Selection and Joins](#value-selection-and-joins)
- [Aggregations and Grouping](#aggregations-and-grouping)
- [Date Operations](#date-operations)
- [Subqueries](#subqueries)
- [F Expressions](#f-expressions)
- [Bulk Operations](#bulk-operations)
- [Data Export Formats](#data-export-formats)

## Basic Query Operations

### Simple Filtering and Data Retrieval

```julia
# Basic filter by single field
query = M.Status |> object;
query.filter("status" => "Engine");
df = query |> DataFrame

1×2 DataFrame
 Row │ statusid  status  
     │ Int64?    String? 
─────┼───────────────────
   1 │        5  Engine
```

### Count Records

```julia
# Count records matching criteria
query = M.Status |> object;
query.filter("status" => "Engine");

julia> count = query |> do_count
1
```

### Check if Records Exist

```julia
# Check if any records match the criteria
query = M.Status |> object
query.filter("status" => "Engine")
exists = query |> do_exists
```

### Selecting Specific Fields

```julia
# Select specific fields from the query
query = M.Status |> object
query.filter("status" => "Engine")
query.values("status")
df = query |> DataFrame
# Returns: statusid | status
```

### Show Query (don't execute)

```julia
# Show the generated SQL query
query = M.Status |> object
query.filter("status" => "Engine")
sql = query |> show_query
@info sql
# Returns the SQL query string without executing it
```

## Filtering Data

### How to Use Functions and Operators in PormG

PormG uses a special `@` prefix syntax to distinguish between field names and functions/operators:

#### In Filters (WHERE clauses):
- Use `field__@operator` to apply operators to field values
- Use `field__@function` to apply functions to field values before comparison

#### In Values (SELECT clauses):
- Use `field__@function` to apply functions to field values in the result set
- Functions in values typically transform how the data is presented

#### Common Operators for Filters:
- `@lt`, `@lte`, `@gt`, `@gte` - Comparison operators (less than, less than or equal, etc.)
- `@in`, `@nin` - In and not-in operations for arrays
- `@contains`, `@icontains` - String containment (case-sensitive and case-insensitive)
- `@isnull` - Check for null values
- `@neq` - Not equal operator (≠) - *Note: Unlike Django ORM which has separate `.exclude()` method, PormG uses `@neq` in `.filter()` for "not equal" conditions*

#### Common Functions for Both Filters and Values:
- `@year`, `@month`, `@day`, `@quarter` - Date component extraction
- `@date`, `@yyyy_mm` - Date formatting functions

#### Examples of @ Syntax Usage:

```julia
# Using functions in FILTERS (WHERE clause)
query = M.Race |> object
query.filter("date__@year" => 1991)  # Filter where year equals 1991
query.filter("name__@icontains" => "monaco")  # Filter where name contains "monaco"
query.filter("position__@lt" => 5)  # Filter where position is less than 5

# Using functions in VALUES (SELECT clause)  
query.values("date__@year", "date__@month")  # Select year and month components
query.values("raceid", "date__@quarter")  # Select raceid and quarter of the date

# Using operators with aggregated fields in filters (HAVING clause)
query.filter("count_laps__@gt" => 50)  # Filter where count of laps > 50 (HAVING clause)
```

#### Function vs Operator Distinction:
- **Functions** transform the data: `date__@year` extracts the year from a date
- **Operators** compare values: `position__@lt` compares if position is less than a value
- **Aggregation filters** use operators on aggregated fields and create HAVING clauses

### Basic Comparisons

```julia
# Less than comparison
query = M.Result |> object
query.filter("positionorder__@lt" => 3)
df = query |> DataFrame
# Returns results where position order is less than 3
```

### String Operations

```julia
# Case-sensitive contains
query = M.Result |> object
query.filter("raceid__circuitid__name__@contains" => "Monaco")
count = query |> do_count  # Returns: 1664

# Case-insensitive contains
query = M.Result |> object
query.filter("raceid__circuitid__name__@icontains" => "monaco")
count = query |> do_count  # Returns: 1664
```

### In and Not In Operations

```julia
# In operation
query = M.Result |> object
query.filter("raceid__circuitid__name__@in" => ["Circuit de Monaco", "monaco"])
count = query |> do_count  # Returns: 1664

# Not in operation
query = M.Result |> object
query.filter("raceid__circuitid__name__@nin" => ["Circuit de Monaco", "monaco"])
count = query |> do_count  # Returns: 25095
```

### Multiple Filters

```julia
# Multiple conditions (AND logic)
query = M.Result |> object
query.filter("statusid__status" => "Finished", "resultid" => 26745)
query.values("resultid", "raceid__circuitid__name", "driverid__forename", 
             "constructorid__name", "statusid__status", "grid", "laps")
results = query |> list
# Returns records matching both conditions

# Using @neq for exclusion within filters
query = M.Result |> object
query.filter("statusid__status__@neq" => "Retired", "grid__@lte" => 10)
df = query |> DataFrame
# Returns results where status is NOT "Retired" AND grid position <= 10

# Multiple exclusions
query = M.Driver |> object
query.filter("nationality__@neq" => "British", "nationality__@neq" => "German")
# Note: This creates two separate conditions (both must be true)
# Better approach for multiple exclusions:
query.filter("nationality__@nin" => ["British", "German"])
```

## Value Selection and Joins

### Basic Field Selection

```julia
# Select specific fields
query = M.Result |> object
query.filter("statusid__status" => "Engine")
query.values("resultid", "statusid", "statusid__status")
df = query |> DataFrame
# Returns only the specified columns
```

### Joined Field Selection

```julia
# Access related table fields through joins
query = M.Result |> object
query.filter("statusid__status" => "Engine")
query.values("resultid", "driverid__forename", "constructorid__name", 
             "statusid__status", "grid", "laps")
df = query |> DataFrame
# Automatically joins Driver, Constructor, and Status tables
```

### Reverse Joins

```julia
# Access child records from parent model
query = M.Constructor |> object
query.values("result__resultid")
query.filter("result__resultid" => 1)
df = query |> DataFrame
# Returns constructor data with related result information
```

## Aggregations and Grouping

### Count, Min, Max Aggregations

```julia
using PormG.QueryBuilder: Count, Max, Min

query = M.Result |> object
query.values("statusid__status", "raceid__circuitid__name", 
             "driverid__forename", "constructorid__name",
             "count_grid" => Count("grid"), 
             "max_grid" => Max("grid"), 
             "min_grid" => Min("grid"))
query.filter("statusid__status" => "Finished", "driverid__forename" => "Ayrton")
query.order_by("raceid__circuitid__name")
df = query |> DataFrame
# Returns aggregated statistics grouped by the non-aggregated fields
```

### Having Clauses

```julia
# Filter on aggregated values
query = M.Result |> object
query.values("raceid__circuitid__name", "driverid__forename", 
             "constructorid__name", "count_grid" => Count("grid"))
query.filter("statusid__status" => "Finished", "count_grid__@gt" => 1)
df = query |> DataFrame
# Returns grouped results where count_grid is greater than 1
```

## Date Operations

### Understanding Date Functions vs Operators

Date operations in PormG demonstrate the difference between functions and operators clearly:

```julia
# FUNCTIONS in VALUES - Transform data for display
query = M.Race |> object
query.values("raceid", "date", "date__@year", "date__@month", "date__@day")
df = query |> DataFrame
# Returns: raceid | date | date__@year | date__@month | date__@day
#          1      | 2023-03-12 | 2023 | 3 | 12

# OPERATORS in FILTERS - Compare transformed data
query.filter("date__@year" => 2023)  # WHERE EXTRACT(year FROM date) = 2023
query.filter("date__@month__@gte" => 6)  # WHERE EXTRACT(month FROM date) >= 6
```

### Date Component Filtering

```julia
# Filter by year
query = M.Race |> object
query.filter("date__@year" => 1991)
query.values("date__@year", "date__@month", "date__@day", "rows" => Count("raceid"))
query.order_by("date__day")
df = query |> DataFrame
# Returns races from 1991 with date components
```

### Date Format Filtering

```julia
# Filter by year-month format
query = M.Race |> object
query.filter("date__@yyyy_mm" => "1991-10")
df = query |> DataFrame

# Filter by exact date (string)
query = M.Race |> object
query.filter("date__@date" => "1991-10-20")
df = query |> DataFrame

# Filter by exact date (Date object)
using Dates
query = M.Race |> object
query.filter("date__@date" => Date(1991, 10, 20))
df = query |> DataFrame
```

## Subqueries

### Using Subqueries in Filters

```julia
# Create subquery
subquery = M.Status |> object
subquery.filter("status" => "Engine")
subquery.values("statusid")

# Use subquery in main query
query = M.Result |> object
query.filter("statusid__@in" => subquery)
query.values("resultid", "statusid", "statusid__status", "grid", "driverid")
df = query |> DataFrame
# Returns results where statusid is in the subquery results
```

### Complex Subquery with Additional Filters

```julia
# Subquery with additional main query filters
subquery = M.Status |> object
subquery.filter("status" => "Engine")
subquery.values("statusid")

query = M.Result |> object
query.filter("statusid__@in" => subquery, "driverid__@lte" => 7)
query.values("resultid", "statusid", "statusid__status", "grid", "driverid", 
             "raceid__date__@quarter")
query.order_by("raceid__date__quarter")
count = query |> do_count  # Returns: 40
```

## F Expressions

### Field Comparisons

```julia
using PormG.QueryBuilder: F, Q

# Compare fields from different tables
query = M.Result |> object
query.filter(F("driverid__dob__@day") == F("raceid__date__@day"), 
             F("driverid__dob__@month") == F("raceid__date__@month"), 
             "min_grid__@gt" => 0)
query.values("raceid__circuitid__name", "raceid__date", "driverid__forename", 
             "constructorid__name", "count_grid" => Count("grid"), 
             "max_grid" => Max("grid"), "min_grid" => Min("grid"))
query.order_by("min_grid", "-raceid__date")
df = query |> DataFrame
# Returns results where driver's birthday day/month matches race date
```

### Complex F Expressions with Case/When

```julia
using PormG.QueryBuilder: Sum, Case, When

query = M.Result |> object
query.filter("driverid__forename" => "Mika")
query.values("raceid__circuitid__name", 
             "until_30_years" => Sum(Case(When(Q(F("raceid__date") <= F("driverid__dob") + 10950), 
                                              then=1), default=0)))
df = query |> DataFrame
# Complex calculation using F expressions with Case/When logic
```

## Bulk Operations

### Bulk Insert

```julia
using CSV, DataFrames

# Basic bulk insert
query = M.Circuit |> object
df = CSV.File("circuits.csv") |> DataFrame
bulk_insert(query, df)

# Bulk insert with column mapping
query = M.Driver |> object
df = CSV.File("drivers.csv") |> DataFrame
# Handle missing values
for col in [:number]
    df[!, col] = map(x -> ismissing(x) || x == "\\N" ? missing : x, df[!, col])
end
bulk_insert(query, df)
```

### Bulk Update

```julia
# Bulk update with filters
query = M.Just_a_test_deletion |> object
df = query |> DataFrame

# Modify data
for (index, row) in enumerate(eachrow(df))
    row.name = "test_update_$(index)"
end

# Update with specific columns and filters
bulk_update(query, df, columns=["name"], filters=["id"])

# Bulk update with static filters
bulk_update(query, df, columns=["name"], filters=["id", "test_result" => 1])
```

### F Expression Updates

```julia
# Update using F expressions
query = M.Just_a_test_deletion |> object
query.filter("test_result" => 1)

# Simple F expression
query.update("test_result2" => F("test_result"))

# Arithmetic operations
query.update("test_result2" => F("test_result") + 1)
query.update("test_result2" => F("test_result2") * 2)
query.update("test_result2" => F("test_result2") / 2)
query.update("test_result2" => F("test_result") + F("test_result"))
query.update("test_result2" => F("test_result2") - 1)

# Set to missing
query.update("test_result2" => missing)
```

## Data Export Formats

### DataFrame Export

```julia
# Export as DataFrame for analysis
query = M.Result |> object
query.filter("statusid__status" => "Finished")
query.values("resultid", "driverid__forename", "constructorid__name")
df = query |> DataFrame
# Returns DataFrames.DataFrame for data analysis
```

### Dictionary Array Export

```julia
# Export as array of dictionaries
query = M.Result |> object
query.filter("statusid__status" => "Finished", "resultid" => 26745)
query.values("resultid", "raceid__circuitid__name", "driverid__forename", 
             "constructorid__name", "statusid__status", "grid", "laps")
dict_array = query |> list
# Returns: Vector{Dict{Symbol, Any}}
# Example: [Dict(:resultid => 26745, :laps => 58, ...)]
```

### JSON Export

```julia
# Export as JSON string
query = M.Result |> object
query.filter("statusid__status" => "Finished", "resultid" => 26745)
query.values("resultid", "raceid__circuitid__name", "driverid__forename")
json_string = query |> list_json
# Returns: JSON string for API responses
# Example: "[{\"resultid\":26745,\"raceid__circuitid__name\":\"...\"}]"

# Parse JSON back to verify
using JSON
parsed_data = JSON.parse(json_string)
```

## Advanced Query Patterns

### Pagination

```julia
using PormG.QueryBuilder: page

# Basic pagination
query = M.Result |> object
query.filter("statusid__status" => "Finished")
query.values("resultid", "driverid__forename", "constructorid__name")

# Page with limit and offset
df = page(query, limit=20, offset=10) |> DataFrame

# Alternative syntax
df = page(query, 20, 10) |> DataFrame
```

### Ordering

```julia
# Single field ordering
query = M.Result |> object
query.values("resultid", "grid", "laps")
query.order_by("grid")
df = query |> DataFrame

# Multiple field ordering with direction
query.order_by("grid", "-laps")  # grid ascending, laps descending
df = query |> DataFrame
```

### Query Debugging

```julia
# Show generated SQL
query = M.Result |> object
query.filter("statusid__status" => "Finished")
sql_string = query |> show_query
println(sql_string)

# Show query in bulk operations
bulk_insert(query, df, show_query=true)
bulk_update(query, df, columns=["name"], filters=["id"], show_query=true)
```

## Performance Tips

1. **Use Indexes**: Create database indexes on frequently filtered fields
2. **Limit Results**: Use pagination for large datasets
3. **Select Specific Fields**: Use `values()` to select only needed columns
4. **Batch Operations**: Use bulk operations for multiple inserts/updates
5. **Filter Early**: Apply filters before joins when possible
6. **Use Aggregations**: Let the database do calculations instead of Julia

## Error Handling

```julia
# Handle potential errors in bulk operations
try
    query = M.Race |> object
    bulk_insert(query, df)
catch e
    @error "Bulk insert failed" error=e
    # Handle the error appropriately
end

# Validate data before operations
if query |> do_exists
    # Proceed with operations
    df = query |> DataFrame
else
    @warn "No records found matching criteria"
end
```

## Summary of @ Syntax Rules

### Quick Reference Guide

| Context | Syntax | Purpose | Example |
|---------|--------|---------|---------|
| **Filter with Operator** | `field__@operator => value` | Compare field using operator | `"age__@gte" => 18` |
| **Filter with Function** | `field__@function => value` | Apply function then compare | `"date__@year" => 2023` |
| **Value with Function** | `field__@function` | Transform field in result | `"date__@month"` |
| **Aggregation Filter** | `agg_field__@operator => value` | Filter aggregated results (HAVING) | `"count_items__@gt" => 5` |
| **Not Equal Filter** | `field__@neq => value` | Exclude specific values | `"status__@neq" => "Retired"` |
| **Null Check Filter** | `field__@isnull => boolean` | Check for null/missing values | `"number__@isnull" => false` |

### Key Concepts:
1. **@** distinguishes between field names and operations
2. **Operators** (`@lt`, `@gte`, `@in`) compare values
3. **Functions** (`@year`, `@month`, `@icontains`) transform data
4. **Filters** with @ create WHERE or HAVING clauses
5. **Values** with @ transform data in SELECT clauses
6. **Chain operations**: `field__@function__@operator` (function first, then operator)

This documentation covers the most common query patterns and operations available in PormG, providing practical examples that can be adapted for various use cases.
