# Q Objects: Complex Boolean Logic

`Q` and `Qor` objects let you construct complex queries with `AND`, `OR`, and nested boolean logic — going beyond what simple `filter()` pairs can express.

---

## When to Use Q Objects

Standard `filter()` pairs are always combined with **AND**:

```julia
# WHERE year >= 2000 AND surname = 'Schumacher'
query.filter("raceid__year__@gte" => 2000, "driverid__surname" => "Schumacher")
```

For **OR** conditions, nested boolean groups, or dynamic filter construction, you need `Q` and `Qor`:

```julia
using PormG: Q, Qor

# WHERE year >= 2000 AND (surname = 'Schumacher' OR surname = 'Hamilton')
query.filter(
    "raceid__year__@gte" => 2000,
    Qor(
        "driverid__surname" => "Schumacher",
        "driverid__surname" => "Hamilton"
    )
)
```

### Quick Reference

| Object | Logic | SQL Equivalent |
| :--- | :--- | :--- |
| `Q(a, b, c)` | AND | `a AND b AND c` |
| `Qor(a, b, c)` | OR | `a OR b OR c` |
| `Q(a, Qor(b, c))` | Mixed | `a AND (b OR c)` |
| `Qor(Q(a, b), Q(c, d))` | Grouped OR | `(a AND b) OR (c AND d)` |

---

## OR Logic with `Qor`

Use `Qor` to combine conditions where **at least one** must be true:

```julia
# Results for either Mercedes (ID 1) or Red Bull (ID 9)
query = M.Result.objects
query.filter(Qor("constructorid" => 1, "constructorid" => 9))
df = query |> DataFrame
```

Generated SQL:
```sql
WHERE ("Tb"."constructorid" = $1 OR "Tb"."constructorid" = $2)
```

### OR with Joined Fields

```julia
# Drivers who are either Brazilian or French
query = M.Driver.objects
query.filter(Qor("nationality" => "Brazilian", "nationality" => "French"))
```

### OR with Operators

```julia
# Results with points > 20 OR grid position = 1
query = M.Result.objects
query.filter(Qor("points__@gt" => 20, "grid" => 1))
```

---

## AND Logic with `Q`

While `filter()` pairs are already ANDed, `Q()` is useful for **explicit grouping** inside `Qor`:

```julia
# (Year >= 2014) AND (Hamilton OR Verstappen)
query = M.Result.objects
query.filter(Q(
    "raceid__year__@gte" => 2014,
    Qor(
        "driverid__surname" => "Hamilton",
        "driverid__surname" => "Verstappen"
    )
))
```

Generated SQL:
```sql
WHERE "Tb_1"."year" >= $1 AND ("Tb_2"."surname" = $2 OR "Tb_2"."surname" = $3)
```

---

## Nesting AND Inside OR

Combine `Q()` groups inside `Qor()` to build complex disjunctions:

```julia
# (Ferrari AND Schumacher) OR (Mercedes AND Hamilton)
query = M.Result.objects
query.filter(
    Qor(
        Q("constructorid__name" => "Ferrari", "driverid__surname" => "Schumacher"),
        Q("constructorid__name" => "Mercedes", "driverid__surname" => "Hamilton")
    )
)
```

Generated SQL:
```sql
WHERE 
    ("Tb_1"."name" = $1 AND "Tb_2"."surname" = $2)
    OR
    ("Tb_1"."name" = $3 AND "Tb_2"."surname" = $4)
```

### Mixing Q/Qor with Regular Filters

You can combine `Q`/`Qor` with regular filter pairs — they are all ANDed together:

```julia
query = M.Result.objects
query.filter(
    "positionorder" => 1,                           # AND condition
    Qor("driverid__nationality" => "Brazilian",     # OR group
         "driverid__nationality" => "British")
)
# WHERE positionorder = 1 AND (nationality = 'Brazilian' OR nationality = 'British')
```

---

## Q with F Expressions

`Q()` can group `F()`-based predicates when you need boolean logic around field-to-field comparisons:

```julia
using PormG: Q, F

query = M.Result.objects
query.filter(
    Q(
        F("driverid__dob__@day") == F("raceid__date__@day"),
        F("driverid__dob__@month") == F("raceid__date__@month"),
    ),
    "positionorder__@lte" => 10,   # Regular scalar filter
)
df = query |> DataFrame
```

### Qor with Plain Scalar Pairs

For OR conditions on scalar values, use `Qor()` directly:

```julia
query = M.Result.objects
query.filter(
    Qor(
        "points__@gt" => 20,
        "grid" => 1,
    )
)
# WHERE points > 20 OR grid = 1
```

---

## Deep Nesting

PormG supports arbitrary nesting depth:

```julia
# (Constructor is Ferrari AND (points > 5 OR finished on the podium))
# OR
# (Constructor is Mercedes AND year >= 2014)
query = M.Result.objects
query.filter(
    Qor(
        Q(
            "constructorid__name" => "Ferrari",
            Qor("points__@gt" => 5, "positionorder__@lte" => 3)
        ),
        Q(
            "constructorid__name" => "Mercedes",
            "raceid__year__@gte" => 2014
        )
    )
)
```

---

## Dynamic Construction

Build filters incrementally from user input using `push!`. This is ideal for search forms and API endpoints:

```julia
q_obj = Q()

if !isnothing(search_name)
    push!(q_obj, "driverid__surname__@icontains" => search_name)
end

if only_winners
    push!(q_obj, "positionorder" => 1)
end

if !isnothing(min_year)
    push!(q_obj, "raceid__year__@gte" => min_year)
end

query = M.Result.objects
query.filter(q_obj)
query.values("driverid__surname", "raceid__name", "positionorder")
df = query |> DataFrame
```

### Dynamic OR with Qor

```julia
or_conditions = Qor()

for nationality in user_selected_nationalities
    push!(or_conditions, "driverid__nationality" => nationality)
end

query = M.Result.objects
query.filter(or_conditions, "positionorder" => 1)
```

---

## Empty Q Objects

An empty `Q()` or `Qor()` acts as a **no-op** filter that matches everything. This makes it a safe starting point for dynamic loops — if no conditions are pushed, the query simply returns all rows.

```julia
q = Q()
# No conditions pushed
query.filter(q)   # Matches everything — equivalent to no filter
```

---

## Common Patterns

### Search with Multiple Optional Criteria

```julia
function search_results(; driver=nothing, team=nothing, year=nothing, winner_only=false)
    q = Q()
    
    !isnothing(driver) && push!(q, "driverid__surname__@icontains" => driver)
    !isnothing(team)   && push!(q, "constructorid__name__@icontains" => team)
    !isnothing(year)   && push!(q, "raceid__year" => year)
    winner_only        && push!(q, "positionorder" => 1)
    
    return M.Result.objects.
        filter(q).
        values("driverid__surname", "constructorid__name", "raceid__year", "positionorder").
        order_by("-raceid__year") |> DataFrame
end
```

### Multi-Value OR Filter

```julia
# Equivalent to: WHERE nationality IN ('Brazilian', 'French', 'British')
# But built dynamically:
nationalities = ["Brazilian", "French", "British"]
or_q = Qor()
for nat in nationalities
    push!(or_q, "nationality" => nat)
end
df = M.Driver.objects.filter(or_q) |> DataFrame

# Or more simply, use @in:
df = M.Driver.objects.filter("nationality__@in" => nationalities) |> DataFrame
```

!!! tip
    For simple set-membership checks, `@in` is preferred over dynamically building a `Qor`. Use `Qor` when conditions span **different fields** or involve **different operators**.

---

## Q vs Filter API Decision Guide

| Scenario | Use |
| :--- | :--- |
| All conditions are AND | `.filter(a, b, c)` |
| Need OR between conditions | `Qor(a, b)` |
| Grouped boolean logic | `Q(a, Qor(b, c))` |
| Dynamic conditions from user input | `Q()` + `push!` |
| Set membership (`IN`) | `"field__@in" => [values]` |
| NOT operator | `"field__@ne"` or `"field__@nin"` |

!!! warning
    PormG does **not** define `|` or `&` operators between Q objects. Use `Qor(...)` for OR logic and `Q(...)` or multiple `filter()` arguments for AND logic.

---

## Next Steps

- **[Field Expressions](field_expressions.md)** — Use `F()` for column-to-column comparisons and arithmetic.
- **[Filters and Aggregates](filters_and_aggregates.md)** — Lookup operators, grouping, and HAVING.
- **[Custom Joins](custom_joins.md)** — Q/Qor in `cjoin()` filter conditions.
