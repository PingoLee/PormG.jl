# Q Objects: Complex Boolean Logic

`Q` objects allow you to construct complex queries using `AND`, `OR`, and `NOT` logic, especially when simple `filter()` keyword arguments (which are always `AND`ed) aren't enough.

## Why use Q Objects?

Standard filters are combined using `AND`:
```julia
# WHERE year >= 2000 AND surname == "Schumacher"
query.filter("raceid__year__@gte" => 2000, "driverid__surname" => "Schumacher")
```

`Q` objects allow for `OR` conditions and explicit grouping:
```julia
using PormG.QueryBuilder: Q, Qor

# WHERE year >= 2000 AND (surname == "Schumacher" OR surname == "Hamilton")
query.filter(
    "raceid__year__@gte" => 2000,
    Qor(
        "driverid__surname" => "Schumacher",
        "driverid__surname" => "Hamilton"
    )
)
```

## OR Logic with `Qor`

Use `Qor` to combine multiple conditions where at least one must be true.

```julia
# Find results for either Mercedes (1) or Red Bull (9)
query = M.Result.objects
query.filter(Qor("constructorid" => 1, "constructorid" => 9))
```

### Nesting AND inside OR

You can nest `Q()` (which represents `AND`) inside `Qor()` to build complex disjunctions of groups.

```julia
# Find results where:
# (Constructor is Ferrari AND Driver is Schumacher)
# OR
# (Constructor is Mercedes AND Driver is Hamilton)
query = M.Result.objects
query.filter(
    Qor(
        Q("constructorid__name" => "Ferrari", "driverid__surname" => "Schumacher"),
        Q("constructorid__name" => "Mercedes", "driverid__surname" => "Hamilton")
    )
)
```

!!! warning "Do not use | or & between Q objects"
    PormG does not define boolean composition with `|` or `&` for query objects. Use `Qor(...)` for OR logic, and use either multiple `filter(...)` arguments or nested `Q(...)` groups for AND logic.

## AND Logic and Nesting

While `filter()` already performs `AND`, using `Q()` explicitly is helpful for nested logic.

```julia
# (Year >= 2014) AND (Hamilton OR Verstappen)
query.filter(Q(
    "raceid__year__@gte" => 2014,
    Qor(
        "driverid__surname" => "Hamilton",
        "driverid__surname" => "Verstappen"
    )
))
```

## Q with F Expressions

`Q(...)` can still be useful when you need grouping around field-to-field or field-to-expression predicates.

```julia
query = M.Result.objects
query.filter(
    Q(
        F("driverid__dob__@day") == F("raceid__date__@day"),
        F("driverid__dob__@month") == F("raceid__date__@month"),
    ),
    "positionorder__@lte" => 10,
)
```

For plain scalar predicates, prefer the normal filter form inside `Qor(...)`:

```julia
query = M.Result.objects
query.filter(
    Qor(
        "points__@gt" => 20,
        "grid" => 1,
    )
)
```

## Dynamic Construction

You can build a `Q` object incrementally using `push!`. This is useful for building search filters based on user input.

```julia
q_obj = Q()

if !isnothing(search_name)
    push!(q_obj, "driverid__surname__@icontains" => search_name)
end

if only_winners
    push!(q_obj, "positionorder" => 1)
end

query.filter(q_obj)
```

## Empty Q Objects

An empty `Q()` object acts as a "no-op" filter that matches everything, making it a safe starting point for dynamic loops.
