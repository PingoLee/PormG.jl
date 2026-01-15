@doc """
Add a Common Table Expression (CTE) to the query object.

CTEs can be joined like regular tables using their field names.

# Arguments
- `q::SQLObject`: The SQL object to add the CTE to (available as `query.object`)
- `name::String`: The name of the CTE (will be used as table name in JOINs and Lookups)
- `query::SQLObjectHandler`: The subquery that defines the CTE

# Keyword Arguments
- `join_field::Pair{String, String}`: The relationship for joining (e.g., `"local_field" => "cte_field"`). 
- `join_type::String`: The SQL join type (`"LEFT"`, `"INNER"`, etc). Default is `"LEFT"`.

# Returns
- The modified `SQLObject` with the CTE added.

# Examples
```julia
import PormG.models as M

# Example 1: Basic CTE with JOIN (Finding total results per driver)
drivers_stats = M.Result.objects
drivers_stats.values("driverid", "total_races" => Count("resultid"))

main_query = M.Result.objects
With(main_query.object, "stats", drivers_stats, join_field="driverid" => "driverid")

# Filter and select using CTE fields with "cte_name__" prefix
main_query.filter("resultid__@lte" => 100)
main_query.values("resultid", "driverid", "stats__total_races")

df = main_query |> DataFrame
```

```julia
# Example 2: CTE with INNER JOIN and Multiple Aggregations
high_scorers = M.Result.objects
high_scorers.filter("points__@gte" => 10)
high_scorers.values("driverid", "max_points" => Sum("points"))

query = M.Driver.objects
With(query.object, "hs", high_scorers, join_field="driverid" => "driverid", join_type="INNER")

query.values("driverid", "surname", "hs_points" => "hs__max_points")
query.filter("driverid__@lte" => 50)

df = query |> DataFrame
```
""" With