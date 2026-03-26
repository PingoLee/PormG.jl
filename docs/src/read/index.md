# Reading Data with PormG

This section covers the read side of PormG in smaller, task-focused pages.

Use these pages as a map:

- [Values and Joins](values_and_joins.md): selecting columns, traversing relations with `__`, aliases, and common join patterns.
- [Filters and Aggregates](filters_and_aggregates.md): `filter()`, lookup operators, grouping, and `HAVING`.
- [Functions and Dates](functions_and_dates.md): field modifiers, SQL functions, and date-oriented querying.
- [Subqueries and CTEs](subqueries_and_ctes.md): `IN` subqueries, `With(...)`, and query decomposition.
- [F Expressions](field_expressions.md): field-to-field comparisons, computed expressions, and aggregate arithmetic.
- [Q Objects](q_objects.md): Complex boolean logic with `AND`, `OR`, and `NOT`.

## Query Execution and Outputs

PormG provides several ways to execute a query and return data.

| Method | Return Type | Description |
| :--- | :--- | :--- |
| `.list()` | `Vector{Dict{Symbol, Any}}` | Returns all rows as a collection of dictionaries. |
| `.all()` | `Vector{Dict}` | Alias for `.list()`. |
| `query |> DataFrame` | `DataFrame` | Returns results as a Julia `DataFrame` (recommended for analysis). |
| `.count()` | `Int` | Returns the number of rows matching the query. |
| `.exists()` | `Bool` | Returns `true` if at least one row matches. |
| `.first()` | `Dict` or `nothing` | Returns the first matching record or `nothing`. |

## Query Styles

PormG supports both a fluent interface and a legacy pipe-oriented style.

### Fluent Interface

```julia
# Chain methods and finish with a terminal call like .list(), .count(), or .exists()
drivers = M.Driver.objects.filter("nationality" => "Brazilian").order_by("surname").list()

# Route a query to another configured pool
results = M.Result.objects.db("client_42").filter("points__@gt" => 10).all()
```

### Pipe Style

The pipe style is still supported, but the fluent `query.method()` form is the
public style to prefer in docs, tests, and user-facing examples.

```julia
query = M.Driver.objects |> filter("nationality" => "Brazilian")
df = query |> DataFrame
```

## Basic Retrieval

```julia
# Return a Vector of Dicts
data = M.Status.objects.filter("status" => "Engine").list()

# Return a DataFrame
df = M.Status.objects.filter("status" => "Engine") |> DataFrame

# Count and existence checks
count = M.Status.objects.filter("status" => "Engine").count()
exists = M.Status.objects.filter("status" => "Engine").exists()
```

## Database Routing

If you use multiple configured pools, select the pool per query:

```julia
q = M.Driver.objects.db("staging").filter("code" => "SEN")
```

## Reading Roadmap

If you are learning the API from scratch, the usual order is:

1. Start with values and joins.
2. Add filters and lookup operators.
3. Move to grouping and `HAVING`.
4. Use functions, dates, or subqueries when the query becomes more analytical.
5. Reach for `F()` and `Q()` only when plain pairs stop being expressive enough.