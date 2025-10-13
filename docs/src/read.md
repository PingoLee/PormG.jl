# Query Examples and Search Operations

This document provides comprehensive examples of how to perform various database operations using PormG.

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

## Value Selection and Joins

### Basic Field Selection

```julia
# Select specific fields
query = M.Result |> object;
query.filter("statusid__status" => "Engine");
query.values("resultid", "statusid");
df = query |> DataFrame
# Returns only the specified columns
2026×2 DataFrame
  Row │ resultid  statusid 
      │ Int64?    Int64?   
──────┼────────────────────
    1 │        7         5
    2 │        8         5
    3 │       13         5
    4 │       40         5
  ⋮   │    ⋮         ⋮
 2024 │    26724         5
 2025 │    26761         5
 2026 │    26763         5
```

### Joined Field Selection

```julia
# Access related table fields through joins
query = M.Result |> object;
query.filter("statusid__status" => "Engine");
query.values("resultid", "driverid__forename", "constructorid__name", 
             "statusid__status", "grid", "laps");
df = query |> DataFrame
# Automatically joins Driver, Constructor, and Status tables
2026×6 DataFrame
  Row │ resultid  driverid__forename  constructorid__name  statusid__status  grid    laps   
      │ Int64?    String?             String?              String?           Int32?  Int32? 
──────┼─────────────────────────────────────────────────────────────────────────────────────
    1 │        7  Sébastien           Toro Rosso           Engine                17      55
    2 │        8  Kimi                Ferrari              Engine                15      53
    3 │       13  Felipe              Ferrari              Engine                 4      29
    4 │       40  Sebastian           Toro Rosso           Engine                15      39
  ⋮   │    ⋮              ⋮                    ⋮                  ⋮            ⋮       ⋮
 2024 │    26724  Pierre              Alpine F1 Team       Engine                 3      15
 2025 │    26761  Liam                RB F1 Team           Engine                12      55
 2026 │    26763  Franco              Williams             Engine                20      26
```

#### How `__` Creates Joins

When PormG encounters `driverid__forename`, it:

1. **Finds the foreign key**: `driverid` in the Result model points to Driver table
2. **Creates a JOIN**: `INNER JOIN "driver" AS "Tb_1" ON "Tb"."driverid" = "Tb_1"."driverid"`  
3. **Selects the field**: `"Tb_1"."forename"` from the joined Driver table

```sql
-- Generated SQL for the above query
SELECT 
    "Tb"."resultid" as resultid,
    "Tb_1"."forename" as driverid__forename,
    "Tb_2"."name" as constructorid__name,
    "Tb_3"."status" as statusid__status,
    "Tb"."grid" as grid,
    "Tb"."laps" as laps
FROM "result" as "Tb"
    INNER JOIN "driver" AS "Tb_1" ON "Tb"."driverid" = "Tb_1"."driverid"
    INNER JOIN "constructor" AS "Tb_2" ON "Tb"."constructorid" = "Tb_2"."constructorid"  
    INNER JOIN "status" AS "Tb_3" ON "Tb"."statusid" = "Tb_3"."statusid"
WHERE "Tb_3"."status" = $1
```



### Reverse Joins

```julia
# Access child records from parent model
query = M.Constructor |> object;
query.values("result__resultid");
query.filter("result__resultid" => 1);
df = query |> DataFrame
# Returns constructor data with related result information
1×1 DataFrame
 Row │ result__resultid 
     │ Int64?           
─────┼──────────────────
   1 │                1
```

When PormG encounters `result__resultid`, it:

1. **Finds the foreign key**: `result` in the Constructor model points to Result table
2. **Creates a JOIN**: `INNER JOIN "result" AS "Tb_1" ON "Tb"."resultid" = "Tb_1"."resultid"`
3. **Selects the field**: `"Tb_1"."resultid"` from the joined Result table

```sql
-- Generated SQL for the above query
SELECT
   "Tb_1"."resultid" as result__resultid
FROM "constructor" as "Tb"
    INNER JOIN "result" AS "Tb_1" ON "Tb"."constructorid" = "Tb_1"."constructorid" 
WHERE "Tb_1"."resultid" = $1
```

### Multi-Level Joins

The `__` operator can chain multiple relationships:

```julia
# Three-level relationship traversal
query = M.Result |> object
query.filter("raceid__circuitid__country" => "Monaco")
query.values("driverid__forename", "raceid__circuitid__name", "raceid__year")
df = query |> DataFrame
```

```sql
-- Generated SQL shows the join chain
SELECT 
    "Tb_1"."forename" as driverid__forename,
    "Tb_3"."name" as raceid__circuitid__name,
    "Tb_2"."year" as raceid__year
FROM "result" as "Tb"
INNER JOIN "driver" AS "Tb_1" ON "Tb"."driverid" = "Tb_1"."driverid"
INNER JOIN "race" AS "Tb_2" ON "Tb"."raceid" = "Tb_2"."raceid"
INNER JOIN "circuit" AS "Tb_3" ON "Tb_2"."circuitid" = "Tb_3"."circuitid"
WHERE "Tb_3"."country" = $1
```

### Join Types

PormG automatically determines the appropriate join type based on field relationships:

- **INNER JOIN**: Default for non-nullable foreign keys
- **LEFT JOIN**: Used for nullable foreign keys (when `null=true`)
- **Join direction**: Determined by foreign key direction

**Note**: For now, PormG does not support complex join conditions (e.g., using `AND`/`OR` within join clauses). And lack optimizations to choice the other types of joins.

### Common Use Cases

#### 1. Filtering by Related Fields
```julia
# Filter results by driver nationality
query = M.Result |> object
query.filter("driverid__nationality" => "British")
```

#### 2. Selecting Related Data
```julia
# Get race results with driver and constructor info
query = M.Result |> object
query.values("position", "driverid__forename", "driverid__surname", 
             "constructorid__name", "raceid__name")
```

#### 3. Complex Filtering with Multiple Joins
```julia
# Find results for British drivers at Monaco
query = M.Result |> object
query.filter(
    "driverid__nationality" => "British",
    "raceid__circuitid__name__@icontains" => "monaco"
)
```

#### 4. Aggregations Across Joins
```julia
# Count wins by constructor
query = M.Result |> object
query.filter("position" => 1)
query.values("constructorid__name", "wins" => Count("resultid"))
```

### Custom Field Aliases

You can assign custom aliases to fields in your query results using the `=>` syntax in the `values()` method. This allows you to rename columns in the output DataFrame or dictionary.

```julia
# Basic field aliasing
query = M.Result |> object;
query.filter("statusid__status" => "Finished", "resultid" => 26745);
query.values("resultid", "circuit" => "raceid__circuitid__name");
df = query |> DataFrame
# The column "raceid__circuitid__name" will be renamed to "circuit"

# Multiple aliases including functions
query = M.Result |> object;
query.filter("statusid__status" => "Finished", "resultid" => 26745);
query.values("resultid", "circuit" => "raceid__circuitid__name", "quarter" => "raceid__date__@quarter");
df = query |> DataFrame
# Both "raceid__circuitid__name" and "raceid__date__@quarter" are aliased
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
- `@year`, `@month`, `@day`, `@quarter`, `@quadrimester` - Date component extraction
- `@date`, `@yyyy_mm` - Date formatting functions

#### Examples of @ Syntax Usage:

```julia
# Using functions in FILTERS (WHERE clause)
query = M.Race |> object
query.filter("date__@year" => 2009)  # Filter where year equals 2009
query.filter("name__@icontains" => "Malaysian")  # Filter where name contains "Malaysian"

df = query |> DataFrame
1×18 DataFrame
 Row │ raceid  fp2_date  time      sprint_date  quali_date  name                  fp3_time  round   fp1_date  fp2_time  year    date        url                                fp3_date  quali_time  circuitid  fp1_time  sprint_time 
     │ Int64?  Date?     Time?     Date?        Date?       String?               Time?     Int32?  Date?     Time?     Int32?  Date?       String?                            Date?     Time?       Int64?     Time?     Time?       
─────┼────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
   1 │      2  missing   09:00:00  missing      missing     Malaysian Grand Prix  missing        2  missing   missing     2009  2009-04-05  http://en.wikipedia.org/wiki/200…  missing   missing             2  missing   missing 

# How you can see, each filter adds to the WHERE clause
@info query |> show_query

# Using functions in VALUES (SELECT clause)  
query.values("date__@year", "date__@month")  # Select year and month components
df = query |> DataFrame
1×2 DataFrame
 Row │ date__year  date__month 
     │ Decimal?    Decimal?    
─────┼─────────────────────────
   1 │       2009            4

# However, if you reapply values, the previous ones will be replaced
query.values("raceid", "date__@quarter")  # Select raceid and quarter of the date
df = query |> DataFrame
1×2 DataFrame
 Row │ raceid  date__quarter 
     │ Int64?  String?       
─────┼───────────────────────
   1 │      2  2009-Q2
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
2262×18 DataFrame
  Row │ fastestlapspeed  points    raceid  number  time         fastestlaptime  driverid  position  laps    rank    statusid  resultid  fastestlap  grid    milliseconds  positionorder  positiontext  constructorid 
      │ Float64?         Float64?  Int64?  Int32?  String?      Time?           Int64?    Int32?    Int32?  Int32?  Int64?    Int64?    Int32?      Int32?  Int32?        Int32?         String?       Int64?        
──────┼──────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
    1 │         217.586       8.0      18       3  +5.478       00:01:27.739           2         2      58       3         1         2          41       5       5696094              2  2                         2
    2 │         209.158      10.0      19       1  1:31:18.555  00:01:35.405           8         1      56       2         1        23          37       2       5478555              1  1                         6
    3 │         208.033       8.0      19       4  +19.570      00:01:35.921           9         2      56       6         1        24          39       4       5498125              2  2                         2
    4 │         208.153      10.0      20       2  1:31:06.970  00:01:33.6            13         1      57       3         1        45          38       2       5466970              1  1                         6
  ⋮   │        ⋮            ⋮        ⋮       ⋮          ⋮             ⋮            ⋮         ⋮        ⋮       ⋮        ⋮         ⋮          ⋮         ⋮          ⋮              ⋮             ⋮              ⋮
 2260 │         217.429      25.0    1144       4  1:26:33.291  00:01:27.438         846         1      58       3         1     26745          52       1       5193291              1  1                         1
 2261 │         216.619      18.0    1144      55  +5.832       00:01:27.765         832         2      58       5         1     26746          55       3       5199123              2  2                         6
 2262 │         218.3        10.0      18      22  1:34:50.616  00:01:27.452           1         1      58       2         1         1          39       1       5690616              1  1                         1
```

### String Operations

```julia
# Case-sensitive contains
query = M.Result |> object
query.filter("raceid__circuitid__name__@contains" => "Monaco")
count = query |> do_count  # Returns: 1664

query = M.Result |> object
query.filter("raceid__circuitid__name__@contains" => "monaco")
count = query |> do_count  # Returns: 0

# Case-insensitive contains
query = M.Result |> object
query.filter("raceid__circuitid__name__@icontains" => "monaco")
count = query |> do_count  # Returns: 1664

query = M.Result |> object
query.filter("raceid__circuitid__name__@icontains" => "MONACO")
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


## Aggregations and Grouping

### Count, Min, Max Aggregations

```julia
using PormG.QueryBuilder: Count, Max, Min

query = M.Result |> object;
query.values("statusid__status", "raceid__circuitid__name", 
             "driverid__forename", "constructorid__name",
             "count_grid" => Count("grid"), 
             "max_grid" => Max("grid"), 
             "min_grid" => Min("grid"));
query.filter("statusid__status" => "Finished", "driverid__forename" => "Ayrton");
query.order_by("raceid__circuitid__name");
df = query |> DataFrame
# Returns aggregated statistics grouped by the non-aggregated fields
39×7 DataFrame
 Row │ statusid__status  raceid__circuitid__name        driverid__forename  constructorid__name  count_grid  max_grid  min_grid 
     │ String?           String?                        String?             String?              Int64?      Int32?    Int32?   
─────┼──────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
   1 │ Finished          Adelaide Street Circuit        Ayrton              McLaren                       3         1         1
   2 │ Finished          Autódromo do Estoril           Ayrton              McLaren                       3         3         2
   3 │ Finished          Autódromo do Estoril           Ayrton              Team Lotus                    1         1         1
   4 │ Finished          Autódromo do Estoril           Ayrton              Toleman                       1         3         3
  ⋮  │        ⋮                        ⋮                        ⋮                    ⋮               ⋮          ⋮         ⋮
  37 │ Finished          Silverstone Circuit            Ayrton              McLaren                       2         3         2
  38 │ Finished          Suzuka Circuit                 Ayrton              McLaren                       3         2         1
  39 │ Finished          Suzuka Circuit                 Ayrton              Team Lotus                    1         7         7

@info query |> show_query
┌ Info: SELECT
│    "Tb_1"."status" as statusid__status, 
│   "Tb_3"."name" as raceid__circuitid__name, 
│   "Tb_4"."forename" as driverid__forename, 
│   "Tb_5"."name" as constructorid__name, 
│   COUNT("Tb"."grid") as count_grid, 
│   MAX("Tb"."grid") as max_grid, 
│   MIN("Tb"."grid") as min_grid
│ FROM "result" as "Tb"
│  INNER JOIN "status" AS "Tb_1" ON "Tb"."statusid" = "Tb_1"."statusid" 
│  INNER JOIN "race" AS "Tb_2" ON "Tb"."raceid" = "Tb_2"."raceid" 
│  INNER JOIN "circuit" AS "Tb_3" ON "Tb_2"."circuitid" = "Tb_3"."circuitid" 
│  INNER JOIN "driver" AS "Tb_4" ON "Tb"."driverid" = "Tb_4"."driverid" 
│  INNER JOIN "constructor" AS "Tb_5" ON "Tb"."constructorid" = "Tb_5"."constructorid" 
│ WHERE "Tb_1"."status" = $1 AND 
│    "Tb_4"."forename" = $2
│ GROUP BY 1, 2, 3, 4 
└ ORDER BY "Tb_3"."name" ASC
```

### Having Clauses

```julia
# Filter on aggregated values
query = M.Result |> object
query.values("raceid__circuitid__name", "driverid__forename", 
             "constructorid__name", "count_grid" => Count("grid"))
query.filter("statusid__status" => "Finished", "count_grid__@lte" => 3)
df = query |> DataFrame
# Returns grouped results where count_grid is less than or equal to 3
4023×4 DataFrame
  Row │ raceid__circuitid__name         driverid__forename      constructorid__name     count_grid 
      │ Union{Missing, String}          Union{Missing, String}  Union{Missing, String}  Int64?     
──────┼────────────────────────────────────────────────────────────────────────────────────────────
    1 │ Shanghai International Circuit  Paul                    Force India                      3
    2 │ Marina Bay Street Circuit       Fernando                Aston Martin                     1
    3 │ Autodromo Nazionale di Monza    Emerson                 Team Lotus                       2
    4 │ Hungaroring                     Giancarlo               Jordan                           1
  ⋮   │               ⋮                           ⋮                       ⋮                 ⋮
 4021 │ Autodromo Nazionale di Monza    Vitaly                  Renault                          1
 4022 │ Red Bull Ring                   Jean-Pierre             Renault                          1
 4023 │ Miami International Autodrome   Daniel                  RB F1 Team                       1

@info query |> show_query 
┌ Info: SELECT
│    "Tb_2"."name" as raceid__circuitid__name, 
│   "Tb_3"."forename" as driverid__forename, 
│   "Tb_4"."name" as constructorid__name, 
│   COUNT("Tb"."grid") as count_grid
│ FROM "result" as "Tb"
│  INNER JOIN "race" AS "Tb_1" ON "Tb"."raceid" = "Tb_1"."raceid" 
│  INNER JOIN "circuit" AS "Tb_2" ON "Tb_1"."circuitid" = "Tb_2"."circuitid" 
│  INNER JOIN "driver" AS "Tb_3" ON "Tb"."driverid" = "Tb_3"."driverid" 
│  INNER JOIN "constructor" AS "Tb_4" ON "Tb"."constructorid" = "Tb_4"."constructorid" 
│  INNER JOIN "status" AS "Tb_5" ON "Tb"."statusid" = "Tb_5"."statusid" 
│ WHERE "Tb_5"."status" = $1
│ GROUP BY 1, 2, 3 
└ HAVING COUNT("Tb"."grid") <= 3

```


## Date Operations

### Understanding Date Functions vs Operators

Date operations in PormG demonstrate the difference between functions and operators clearly:

```julia
# FUNCTIONS in VALUES - Transform data for display
query = M.Race |> object
query.values("raceid", "date", "date__@year", "date__@month", "date__@day")
df = query |> DataFrame
# Returns:
1125×5 DataFrame
  Row │ raceid  date        date__year  date__month  date__day 
      │ Int64?  Date?       Decimal?    Decimal?     Decimal?  
──────┼────────────────────────────────────────────────────────
    1 │      1  2009-03-29        2009            3         29
    2 │      2  2009-04-05        2009            4          5
    3 │      3  2009-04-19        2009            4         19
    4 │      4  2009-04-26        2009            4         26
  ⋮   │   ⋮         ⋮           ⋮            ⋮           ⋮
 1123 │   1142  2024-11-23        2024           11         23
 1124 │   1143  2024-12-01        2024           12          1
 1125 │   1144  2024-12-08        2024           12          8

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
16×4 DataFrame
 Row │ date__year  date__month  date__day  rows   
     │ Decimal?    Decimal?     Decimal?   Int64? 
─────┼────────────────────────────────────────────
   1 │       1991            6          2       1
   2 │       1991           11          3       1
   3 │       1991            7          7       1
   4 │       1991            9          8       1
  ⋮  │     ⋮            ⋮           ⋮        ⋮
  14 │       1991            4         28       1
  15 │       1991            7         28       1
  16 │       1991            9         29       1
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
subquery = M.Status |> object;
subquery.filter("status" => "Engine");
subquery.values("statusid");

# Use subquery in main query
query = M.Result |> object;
query.filter("statusid__@in" => subquery);
query.values("resultid", "statusid", "statusid__status", "grid", "driverid");
df = query |> DataFrame
# Returns results where statusid is in the subquery results
2026×5 DataFrame
  Row │ resultid  statusid  statusid__status  grid    driverid 
      │ Int64?    Int64?    String?           Int32?  Int64?   
──────┼────────────────────────────────────────────────────────
    1 │        7         5  Engine                17         7
    2 │        8         5  Engine                15         8
    3 │       13         5  Engine                 4        13
    4 │       40         5  Engine                15        20
  ⋮   │    ⋮         ⋮             ⋮            ⋮        ⋮
 2024 │    26724         5  Engine                 3       842
 2025 │    26761         5  Engine                12       859
 2026 │    26763         5  Engine                20       861

 @info query |> show_query
┌ Info: SELECT
│    "Tb"."resultid" as resultid, 
│   "Tb"."statusid" as statusid, 
│   "Tb_1"."status" as statusid__status, 
│   "Tb"."grid" as grid, 
│   "Tb"."driverid" as driverid
│ FROM "result" as "Tb"
│  INNER JOIN "status" AS "Tb_1" ON "Tb"."statusid" = "Tb_1"."statusid" 
│ WHERE "Tb"."statusid" in (SELECT
│           "R1"."statusid" as statusid
│       FROM "status" as "R1"
│ 
│       WHERE "R1"."status" = $1
└ )
```

### Complex Subquery with Additional Filters

```julia
# Subquery with additional main query filters
subquery = M.Status |> object;
subquery.filter("status" => "Engine");
subquery.values("statusid");

query = M.Result |> object;
query.filter("statusid__@in" => subquery, "driverid__@lte" => 7)
query.values("resultid", "statusid", "statusid__status", "grid", "driverid", 
             "raceid__date__@quarter");
query.order_by("raceid__date__quarter");
count = query |> do_count  # Returns: 40
df = query |> DataFrame
# Returns results where statusid is in the subquery and driverid is less than or equal to 7
40×6 DataFrame
 Row │ resultid  statusid  statusid__status  grid    driverid  raceid__date__quarter 
     │ Int64?    Int64?    String?           Int32?  Int64?    String?               
─────┼───────────────────────────────────────────────────────────────────────────────
   1 │     2971         5  Engine                19         2  2000-Q1
   2 │     3103         5  Engine                21         2  2000-Q2
   3 │     3014         5  Engine                17         2  2000-Q2
   4 │     3213         5  Engine                14         2  2000-Q3
  ⋮  │    ⋮         ⋮             ⋮            ⋮        ⋮                ⋮
  38 │    25743         5  Engine                 5         4  2022-Q4
  39 │    25804         5  Engine                 9         4  2022-Q4
  40 │    26343         5  Engine                11         1  2024-Q1
```

## Common Table Expressions (CTE)

Common Table Expressions (CTEs) provide a way to define temporary named result sets that can be referenced within your main query. In PormG, CTEs are particularly useful for breaking down complex queries into more readable parts and for reusing query logic. Unlike subqueries, CTEs are defined once and can be joined with the main query, making them ideal for aggregations and complex data transformations.

### What are CTEs?

CTEs act as virtual tables that exist only during the execution of a query. They are defined using the `With()` function and can be joined with your main query using the `join_field` parameter. This allows you to:

1. **Pre-aggregate data** and join it with the main table
2. **Simplify complex queries** by breaking them into logical steps
3. **Reference the same subquery multiple times** without repetition
4. **Improve query readability** with descriptive CTE names

### Basic CTE with JOIN

The most common use case is creating a CTE with aggregated data and joining it with your main query:

```julia
using PormG.QueryBuilder: Count

# Create a CTE that counts results per driver
duplicates = M.Result |> object;
duplicates.filter("statusid" => 1);  # Only finished results
duplicates.values("driverid", "dias" => Count("resultid"));

# Main query that joins with the CTE
main_query = M.Result |> object;
With(main_query.object, "tb_dup", duplicates, join_field="driverid" => "driverid");

# Now you can filter and select using CTE fields
main_query.filter("resultid__@lte" => 100);
main_query.values("resultid", "driverid", "tb_dup__dias");

df = main_query |> DataFrame

# Example output:
100×3 DataFrame
 Row │ resultid  driverid  tb_dup__dias 
     │ Int64?    Int64?    Int64?       
─────┼──────────────────────────────────
   1 │        1         1          312
   2 │        2         2          228
   3 │        3         3          161
   4 │        4         4          223
  ⋮  │    ⋮         ⋮          ⋮
  98 │       98        19          153
  99 │       99        20           82
 100 │      100         5          275
```

**How it works:**
1. The CTE `tb_dup` aggregates results per driver
2. `With()` creates the CTE and joins it to the main query using `driverid`
3. You can reference CTE fields using the `__` syntax: `tb_dup__dias`
4. The join happens automatically based on the `join_field` parameter

### CTE with Multiple Aggregated Fields

CTEs can include multiple aggregated fields, making them powerful for complex analytics:

```julia
using PormG.QueryBuilder: Count, Sum

# Create CTE with multiple aggregations
stats = M.Result |> object;
stats.filter("raceid__@lte" => 100);
stats.values(
    "driverid",
    "total_results" => Count("resultid"),
    "total_grid_positions" => Sum("grid")
);

# Main query joins driver information with statistics
query = M.Driver |> object;
With(query.object, "driver_stats", stats, join_field="driverid" => "driverid");

query.filter("driverid__@lte" => 50);
query.values(
    "driverid",
    "forename",
    "surname",
    "driver_stats__total_results",
    "driver_stats__total_grid_positions"
);

df = query |> DataFrame

# Example output shows drivers with their statistics:
50×5 DataFrame
 Row │ driverid  forename    surname      driver_stats__total_results  driver_stats__total_grid_positions 
     │ Int64?    String?     String?      Int64?                       Int64?                             
─────┼──────────────────────────────────────────────────────────────────────────────────────────────────
   1 │        1  Lewis       Hamilton                          missing                            missing
   2 │        2  Nick        Heidfeld                              100                                986
  ⋮  │    ⋮          ⋮           ⋮                     ⋮                                    ⋮
  50 │       50  Piero       Taruffi                               100                                524
```

**Note:** Drivers without results in the filtered race range will have `missing` values for CTE fields (depending on join type).

### Multiple CTEs

You can use multiple CTEs in a single query, each serving a different purpose:

```julia
# First CTE: Filter recent races
recent_races = M.Race |> object;
recent_races.filter("year__@gte" => 2020);
recent_races.values("raceid", "name", "year");

# Second CTE: Filter top drivers
top_drivers = M.Driver |> object;
top_drivers.filter("driverid__@lte" => 100);
top_drivers.values("driverid", "forename", "surname");

# Main query uses both CTEs
query = M.Result |> object;
With(query.object, "recent", recent_races, join_field="raceid" => "raceid");
With(query.object, "top_d", top_drivers, join_field="driverid" => "driverid");

query.values(
    "resultid",
    "recent__name",
    "top_d__forename",
    "points"
);
query.filter("recent__name__@isnull" => false, "top_d__forename__@isnull" => false);

df = query |> DataFrame

# Returns results combining both CTE filters:
294×4 DataFrame
 Row │ resultid  recent__name              top_d__forename  points   
     │ Int64?    String?                   String?          Float64? 
─────┼────────────────────────────────────────────────────────────────
   1 │    25568  Bahrain Grand Prix        Lewis                 25.0
   2 │    25570  Bahrain Grand Prix        Sergio                18.0
   3 │    25574  Bahrain Grand Prix        Lance                  1.0
  ⋮  │    ⋮              ⋮                      ⋮             ⋮
 294 │    26753  Abu Dhabi Grand Prix      Lando                 10.0
```

### CTE with Join Types

By default, PormG uses `LEFT JOIN` for CTEs, but you can specify the join type:

```julia
using PormG.QueryBuilder: Sum

# Create CTE for high-scoring drivers
high_scorers = M.Result |> object;
high_scorers.filter("points__@gte" => 10);
high_scorers.values("driverid", "max_points" => Sum("points"));

# Use INNER JOIN to only include drivers with high scores
query = M.Driver |> object;
With(query.object, "high_scorers", high_scorers, 
     join_field="driverid" => "driverid", 
     join_type="INNER");

query.values("driverid", "forename", "max_points" => "high_scorers__max_points");
query.filter("driverid__@lte" => 100);

df = query |> DataFrame

# Only returns 29 drivers who scored 10+ points:
29×3 DataFrame
 Row │ driverid  forename     max_points 
     │ Int64?    String?      Int64?     
─────┼──────────────────────────────────
   1 │        1  Lewis              4865
   2 │        4  Fernando           2046
   3 │        8  Kimi               1859
  ⋮  │    ⋮          ⋮           ⋮
  29 │       22  Jenson              132
```

**Available join types:**
- `"LEFT"` (default): Includes all records from main table
- `"INNER"`: Only includes records that match both tables
- `"RIGHT"`: Includes all records from CTE
- `"FULL"`: Includes all records from both tables


## F Expressions

### Field Comparisons

```julia
using PormG.QueryBuilder: F, Q

# Compare fields from different tables
query = M.Result |> object;
query.filter(F("driverid__dob__@day") == F("raceid__date__@day"), 
             F("driverid__dob__@month") == F("raceid__date__@month"), 
             "min_grid__@gt" => 0);
query.values("raceid__circuitid__name", "raceid__date", "driverid__dob", "driverid__forename", 
             "constructorid__name", "count_grid" => Count("grid"), 
             "max_grid" => Max("grid"), "min_grid" => Min("grid"));
query.order_by("min_grid", "-raceid__date");
df = query |> DataFrame
# Returns results where driver's birthday day/month matches race date
75×8 DataFrame
 Row │ raceid__circuitid__name        raceid__date  driverid__dob  driverid__forename      constructorid__name     count_grid  max_grid  min_grid 
     │ Union{Missing, String}         Date?         Date?          Union{Missing, String}  Union{Missing, String}  Int64?      Int32?    Int32?   
─────┼────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
   1 │ Nürburgring                    1997-09-28    1968-09-28     Mika                    McLaren                          1         1         1
   2 │ Circuit de Spa-Francorchamps   1995-08-27    1959-08-27     Gerhard                 Ferrari                          1         1         1
   3 │ Circuit de Monaco              1991-05-12    1963-05-12     Stefano                 Tyrrell                          1         2         2
   4 │ Circuit Park Zandvoort         1976-08-29    1947-08-29     James                   McLaren                          1         2         2
  ⋮  │               ⋮                     ⋮              ⋮                  ⋮                       ⋮                 ⋮          ⋮         ⋮
  73 │ Indianapolis Motor Speedway    1959-05-30    1926-05-30     Chuck                   Kurtis Kraft                     1        21        21
  74 │ Nürburgring                    1995-10-01    1963-10-01     Jean-Denis              Pacific                          1        24        24
  75 │ Watkins Glen                   1971-10-03    1941-10-03     Andrea                  March-Alfa Romeo                 1        26        26
```

### F Expressions in Filters

```julia
# Compare fields within the same record
query = M.Race |> object
query.filter(F("fp1_date") <= F("date"))

df = query |> DataFrame
90×18 DataFrame
 Row │ raceid  fp2_date    time      sprint_date  quali_date  name                       fp3_time  round   fp1_date    fp2_time  year    date        url                                fp3_date    quali_time  circuitid  fp1_time  sprint_time 
     │ Int64?  Date?       Time?     Date?        Date?       String?                    Time?     Int32?  Date?       Time?     Int32?  Date?       String?                            Date?       Time?       Int64?     Time?     Time?       
─────┼───────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
   1 │   1053  2021-04-16  13:00:00  missing      2021-04-17  Emilia Romagna Grand Prix  missing        2  2021-04-16  missing     2021  2021-04-18  http://en.wikipedia.org/wiki/202…  2021-04-17  missing            21  missing   missing     
   2 │   1074  2022-03-18  15:00:00  missing      2022-03-19  Bahrain Grand Prix         12:00:00       1  2022-03-18  15:00:00    2022  2022-03-20  http://en.wikipedia.org/wiki/202…  2022-03-19  15:00:00            3  12:00:00  missing     
   3 │   1052  2021-03-26  15:00:00  missing      2021-03-27  Bahrain Grand Prix         missing        1  2021-03-26  missing     2021  2021-03-28  http://en.wikipedia.org/wiki/202…  2021-03-27  missing             3  missing   missing     
   4 │   1051  2021-11-19  14:00:00  missing      2021-11-20  Qatar Grand Prix           missing       20  2021-11-19  missing     2021  2021-11-21  http://en.wikipedia.org/wiki/202…  2021-11-20  missing            78  missing   missing     
  ⋮  │   ⋮         ⋮          ⋮           ⋮           ⋮                   ⋮                 ⋮        ⋮         ⋮          ⋮        ⋮         ⋮                       ⋮                      ⋮           ⋮           ⋮         ⋮           ⋮
  88 │   1142  2024-11-21  06:00:00  missing      2024-11-22  Las Vegas Grand Prix       02:30:00      22  2024-11-21  06:00:00    2024  2024-11-23  https://en.wikipedia.org/wiki/20…  2024-11-22  06:00:00           80  02:30:00  missing     
  89 │   1143  2024-11-29  17:00:00  2024-11-30   2024-11-30  Qatar Grand Prix           missing       23  2024-11-29  17:30:00    2024  2024-12-01  https://en.wikipedia.org/wiki/20…  missing     17:00:00           78  13:30:00  13:00:00
  90 │   1144  2024-12-06  13:00:00  missing      2024-12-07  Abu Dhabi Grand Prix       10:30:00      24  2024-12-06  13:00:00    2024  2024-12-08  https://en.wikipedia.org/wiki/20…  2024-12-07  14:00:00           24  09:30:00  missing   

# Use F expressions with other operators
query = M.Result |> object
query.filter(F("position") == F("rank"))
df = query |> DataFrame
929×18 DataFrame
 Row │ fastestlapspeed  points    raceid  number  time         fastestlaptime  driverid  position  laps    rank    statusid  resultid  fastestlap  grid    milliseconds  positionorder  positiontext  constructorid 
     │ Float64?         Float64?  Int64?  Int32?  String?      Time?           Int64?    Int32?    Int32?  Int32?  Int64?    Int64?    Int32?      Int32?  Int32?        Int32?         String?       Int64?        
─────┼──────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
   1 │         204.323       6.0      21       1  +4.187       00:01:22.017           1         3      66       3         1        69          20       5       5902238              3  3                         1
   2 │         222.085       8.0      22       1  +3.779       00:01:26.529           1         2      58       2         1        90          31       3       5212230              2  2                         1
   3 │         197.285       8.0      29       1  +5.611       00:01:38.884           1         2      57       2         1       230          16       2       5736950              2  2                         1
   4 │         203.722      10.0      34       1  1:31:57.403  00:01:36.325           1         1      56       1         1       329          13       1       5516403              1  1                         1
  ⋮  │        ⋮            ⋮        ⋮       ⋮          ⋮             ⋮            ⋮         ⋮        ⋮       ⋮        ⋮         ⋮          ⋮         ⋮          ⋮              ⋮             ⋮              ⋮
 927 │         233.167       6.0    1143      14  +19.867      00:01:23.667           4         7      57       7         1     26731          57       8       5484190              7  7                       117
 928 │         216.619       8.0    1144       1  +49.847      00:01:27.765         830         6      58       6         1     26750          56       4       5242138              6  6                         9
 929 │         233.803      18.0    1142       1  +7.313       00:01:35.48            1         2      50       2         1     26706          41      10       4932282              2  2                       131
```

### F Expressions in Annotations

```julia
# Calculate values in SELECT
query = M.Result |> object;
query.filter("statusid__status" => "Finished", "driverid__forename" => "Mika");
query.values(
    "driverid__forename",
    "points",
    "bonus_points" => F("points") * 0.1,
    "total_points" => F("points") + (F("points") * 0.1)
)
df = query |> DataFrame
84×4 DataFrame
 Row │ driverid__forename  points    bonus_points  total_points 
     │ String?             Float64?  Float64?      Float64?     
─────┼──────────────────────────────────────────────────────────
   1 │ Mika                     1.0           0.1           1.1
   2 │ Mika                     3.0           0.3           3.3
   3 │ Mika                     4.0           0.4           4.4
   4 │ Mika                     1.0           0.1           1.1
  ⋮  │         ⋮              ⋮           ⋮             ⋮
  82 │ Mika                     3.0           0.3           3.3
  83 │ Mika                     0.0           0.0           0.0
  84 │ Mika                     0.0           0.0           0.0

@info query |> show_query
┌ Info: SELECT
│    "Tb_1"."forename" as driverid__forename, 
│   "Tb"."points" as points, 
│   ("Tb"."points" * $1) as bonus_points, 
│   ("Tb"."points" + ("Tb"."points" * $2)) as total_points
│ FROM "result" as "Tb"
│  INNER JOIN "driver" AS "Tb_1" ON "Tb"."driverid" = "Tb_1"."driverid" 
│  INNER JOIN "status" AS "Tb_2" ON "Tb"."statusid" = "Tb_2"."statusid" 
│ WHERE "Tb_2"."status" = $3 AND 
└    "Tb_1"."forename" = $4
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
25×2 DataFrame
 Row │ raceid__circuitid__name         until_30_years 
     │ Union{Missing, String}          Int64?         
─────┼────────────────────────────────────────────────
   1 │ Adelaide Street Circuit                      7
   2 │ Albert Park Grand Prix Circuit               4
   3 │ Autódromo do Estoril                         8
   4 │ Autodromo Enzo e Dino Ferrari                9
  ⋮  │               ⋮                       ⋮
  23 │ Sepang International Circuit                 0
  24 │ Silverstone Circuit                          9
  25 │ Suzuka Circuit                              10
  
```

## Q Object

Q objects in PormG provide a way to create complex query conditions using logical operators (`AND`, `OR`). They are similar to Django's Q objects and allow you to build sophisticated filtering logic that goes beyond simple field-value pairs.

### Basic Q Usage

```julia
using PormG.QueryBuilder: Q, Qor

# Simple Q expression (equivalent to regular filter)
query = M.Result |> object;
query.filter(Q("driverid__forename" => "Lewis", "statusid__status" => "Finished"));
query.values("resultid", "driverid__forename", "statusid__status");
df = query |> DataFrame
# Same as: query.filter("driverid__forename" => "Lewis", "statusid__status" => "Finished")
```

### OR Logic with Qor

```julia
# Find results where driver is either Lewis or Sebastian
query = M.Result |> object
query.filter(Qor("driverid__forename" => "Lewis", "driverid__forename" => "Sebastian"))
query.values("resultid", "driverid__forename", "statusid__status");
df = query |> DataFrame

656×3 DataFrame
 Row │ resultid  driverid__forename  statusid__status 
     │ Int64?    String?             String?          
─────┼────────────────────────────────────────────────
   1 │       27  Lewis               Finished
   2 │       57  Lewis               +1 Lap
   3 │       69  Lewis               Finished
   4 │       90  Lewis               Finished
  ⋮  │    ⋮              ⋮                  ⋮
 654 │    25799  Sebastian           +1 Lap
 655 │    25816  Sebastian           Finished
 656 │    25835  Sebastian           Finished

# Multiple OR conditions
query = M.Result |> object;
query.values("resultid", "driverid__forename", "statusid__status");
query.filter(Qor(
    "statusid__status" => "Finished",
    "statusid__status" => "Engine", 
    "statusid__status" => "+1 Lap"
));
df = query |> DataFrame

13737×3 DataFrame
   Row │ resultid  driverid__forename  statusid__status 
       │ Int64?    String?             String?          
───────┼────────────────────────────────────────────────
     1 │        2  Nick                Finished
     2 │        3  Nico                Finished
     3 │        4  Fernando            Finished
     4 │        5  Heikki              Finished
   ⋮   │    ⋮              ⋮                  ⋮
 13735 │    26761  Liam                Engine
 13736 │    26763  Franco              Engine
 13737 │        1  Lewis               Finished
```

### Complex AND/OR Combinations

```julia
# Combine Q and Qor for complex logic
# Find British drivers who either finished or had engine problems
query = M.Result |> object;
query.filter(
    Q("driverid__nationality" => "British"),  # AND condition
    Qor("statusid__status" => "Finished", "statusid__status" => "Engine")  # OR condition
);
query.values("resultid", "driverid__forename", "statusid__status");
df = query |> DataFrame

# Equivalent SQL: WHERE nationality = 'British' AND (status = 'Finished' OR status = 'Engine')
1783×3 DataFrame
  Row │ resultid  driverid__forename  statusid__status 
      │ Int64?    String?             String?          
──────┼────────────────────────────────────────────────
    1 │       27  Lewis               Finished
    2 │       31  David               Finished
    3 │       32  Jenson              Finished
    4 │       69  Lewis               Finished
  ⋮   │    ⋮              ⋮                  ⋮
 1781 │    25124  George              Engine
 1782 │    25903  George              Engine
 1783 │    26343  Lewis               Engine
```

### Nested Q Expressions

```julia
# Complex nested conditions
query = M.Result |> object;
query.filter(Q(
    "raceid__year__@gte" => 2000,  # After year 2000
    Qor(  # AND (condition1 OR condition2)
        Q("driverid__forename" => "Michael", "driverid__surname" => "Schumacher"),
        Q("driverid__forename" => "Lewis", "driverid__surname" => "Hamilton")
    )
));
query.values("resultid", "driverid__forename", "statusid__status");
# Equivalent SQL: 
# WHERE year >= 2000 AND 
#   ((forename = 'Michael' AND surname = 'Schumacher') OR 
#    (forename = 'Lewis' AND surname = 'Hamilton'))
```

### Q in Complex Filtering Scenarios

```julia
# Example: Find race results with specific criteria
query = M.Result |> object
query.filter(Q(
    "raceid__circuitid__country__@in" => ["Monaco", "Italy", "United Kingdom"],
    Qor(
        Q("position__@lte" => 3, "statusid__status" => "Finished"),  # Podium finishers
        Q("fastestlap__@isnull" => false, "rank" => 1)              # OR fastest lap holders
    )
))
query.values(
    "raceid__name", 
    "driverid__forename", 
    "driverid__surname",
    "position", 
    "statusid__status",
    "fastestlap",
    "rank"
)
df = query |> DataFrame
523×7 DataFrame
 Row │ raceid__name               driverid__forename  driverid__surname  position  statusid__status  fastestlap  rank   
     │ String?                    String?             String?            Int32?    String?           Int32?      Int32? 
─────┼──────────────────────────────────────────────────────────────────────────────────────────────────────────────────
   1 │ Monaco Grand Prix          Jenson              Button                    1  Finished                  49       2
   2 │ Monaco Grand Prix          Rubens              Barrichello               2  Finished                  46       7
   3 │ Monaco Grand Prix          Kimi                Räikkönen                 3  Finished                  47       5
   4 │ Monaco Grand Prix          Felipe              Massa                     4  Finished                  50       1
  ⋮  │             ⋮                      ⋮                   ⋮             ⋮             ⋮              ⋮         ⋮
 521 │ Italian Grand Prix         Charles             Leclerc                   1  Finished                  33      10
 522 │ Italian Grand Prix         Oscar               Piastri                   2  Finished                  53       4
 523 │ Italian Grand Prix         Lando               Norris                    3  Finished                  53       1
```

<!-- 
### Q with Aggregations and HAVING

```julia
# Use Q expressions in HAVING clauses
query = M.Result |> object
query.values(
    "driverid__forename",
    "driverid__surname", 
    "race_count" => Count("raceid"),
    "avg_position" => Avg("position")
)
query.filter(Q(
    "statusid__status" => "Finished",
    "race_count__@gte" => 10,  # At least 10 races
    Qor(
        "avg_position__@lte" => 5.0,  # Good average position
        "race_count__@gte" => 50      # OR many races
    )
))
df = query |> DataFrame
``` 
-->

### Appending condition in Q

Eventually you will need to append conditions to your Q expressions. This can be done using `push!`.

```julia
q_object = Q("position__@lte" => 3)
push!(q_object, "statusid__status" => "Finished")

q_object2 = Q("fastestlap__@isnull" => false)
push!(q_object2, "rank" => 1)

q_combined = Qor(q_object)
push!(q_combined, q_object2)

query = M.Result |> object;
query.filter("raceid__year" => 2000)  # After year 2000
query.filter(q_combined)
query.values("resultid", "driverid__forename", "statusid__status");
df = query |> DataFrame

50×3 DataFrame
 Row │ resultid  driverid__forename  statusid__status 
     │ Int64?    String?             String?          
─────┼────────────────────────────────────────────────
   1 │     2931  Michael             Finished
   2 │     2932  Rubens              Finished
   3 │     2933  Ralf                Finished
   4 │     2953  Michael             Finished
  ⋮  │    ⋮              ⋮                  ⋮
  48 │     3282  Michael             Finished
  49 │     3283  David               Finished
  50 │     3284  Rubens              Finished

# That is equivalent to
query = M.Result |> object;
query.filter(Q(
    "raceid__year" => 2000,  # After year 2000
    Qor(
        Q("position__@lte" => 3, "statusid__status" => "Finished"),  # Podium finishers
        Q("fastestlap__@isnull" => false, "rank" => 1)              # OR fastest lap holders
    )
));
query.values("resultid", "driverid__forename", "statusid__status");
df = query |> DataFrame

50×3 DataFrame
 Row │ resultid  driverid__forename  statusid__status 
     │ Int64?    String?             String?          
─────┼────────────────────────────────────────────────
   1 │     2931  Michael             Finished
   2 │     2932  Rubens              Finished
   3 │     2933  Ralf                Finished
   4 │     2953  Michael             Finished
  ⋮  │    ⋮              ⋮                  ⋮
  48 │     3282  Michael             Finished
  49 │     3283  David               Finished
  50 │     3284  Rubens              Finished
```


## Data Export Formats

### DataFrame Export

```julia
# Export as DataFrame for analysis
query = M.Result |> object;
query.filter("statusid__status" => "Finished");
query.values("resultid", "driverid__forename", "constructorid__name");
df = query |> DataFrame
# Returns DataFrames.DataFrame for data analysis
```

### Dictionary Array Export

```julia
# Export as array of dictionaries
query = M.Result |> object;
query.filter("statusid__status" => "Finished", "resultid" => 26745);
query.values("resultid", "raceid__circuitid__name", "driverid__forename", 
             "constructorid__name", "statusid__status", "grid", "laps");
dict_array = query |> list
# Returns: Vector{Dict{Symbol, Any}}
1-element Vector{Dict{Symbol, Any}}:
 Dict(:laps => 58, :resultid => 26745, :grid => 1, :raceid__circuitid__name => "Yas Marina Circuit", :driverid__forename => "Lando", :statusid__status => "Finished", :constructorid__name => "McLaren")
```

### JSON Export

```julia
# Export as JSON string
query = M.Result |> object;
query.filter("statusid__status" => "Finished", "resultid" => 26745);
query.values("resultid", "raceid__circuitid__name", "driverid__forename");
json_string = query |> list_json
# Returns: JSON string for API responses
"[{\"raceid__circuitid__name\":\"Yas Marina Circuit\",\"resultid\":26745,\"driverid__forename\":\"Lando\"}]"

# Parse JSON back to verify
using JSON
parsed_data = JSON.parse(json_string)
1-element Vector{Any}:
 Dict{String, Any}("raceid__circuitid__name" => "Yas Marina Circuit", "resultid" => 26745, "driverid__forename" => "Lando")
```

## Advanced Query Patterns

### Pagination

```julia
using PormG.QueryBuilder: page

# Basic pagination
query = M.Result |> object;
query.filter("statusid__status" => "Finished");
query.values("resultid", "driverid__forename", "constructorid__name");

# Page with limit and offset
df = page(query, limit=20, offset=10) |> DataFrame

# Alternative syntax
df = page(query, 20, 10) |> DataFrame

# Just limit
df = page(query, 20) |> DataFrame
# or
df = page(query, limit=20) |> DataFrame
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
