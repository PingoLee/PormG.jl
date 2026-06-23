# PormG Usage — Migrations, Writing Data & Bulk Operations

Supporting file for [`SKILL.md`](SKILL.md). Read this when **changing data or schema**. For setup, querying, joins, and aggregations see `SKILL.md`; for the field-type table see [`reference.md`](reference.md).

All defaults from `SKILL.md` still apply: write through `M.Model.objects`, never interpolate user data into SQL, prefer parameterized queries.

## Migrations

Always follow this ordered flow:

```julia
using PormG

# 1. First-time initialization (safe to run on existing DBs)
PormG.Migrations.init_migrations("db")

# 2. Check current state
PormG.Migrations.status("db")

# 3. Generate migration plan from current models
PormG.Migrations.makemigrations("db")

# 4. Dry-run: review SQL before executing (check for destructive ops)
PormG.Migrations.dry_run("db")

# 5. Apply migrations
PormG.Migrations.migrate("db")

# For destructive changes (column drops, renames), opt in explicitly:
PormG.Migrations.migrate("db", destructive=true)
```

> **Never** skip `dry_run()` before a destructive migration. If it reports DROP columns, require explicit approval.

## Writing Data

### Create a single record
```julia
driver = M.Driver.objects.create(
    "forename"    => "Ayrton",
    "surname"     => "Senna",
    "nationality" => "Brazilian",
    "driverref"   => "senna"
)
# Returns Dict with all fields including the new PK
```

### Update matching records
```julia
M.Driver.objects.
    filter("driverid" => 1).
    update("nationality" => "Brazil")

# With F-expression (atomic)
M.Result.objects.
    filter("resultid__@in" => [1, 2, 3]).
    update("points" => F("points") * 1.1)
```

### Delete records
```julia
# Delete with filter
M.Result.objects.filter("raceid__year__@lt" => 1960).delete()

# Inspect before deleting (never executes)
sql = M.Result.objects.filter("raceid" => 999).delete(show_query=:sql)

# Delete all (requires explicit opt-in to prevent accidents)
M.Just_a_test_deletion.objects.delete(allow_delete_all=true)
```

## Bulk Operations

For large datasets, always use bulk operations instead of loops:

```julia
using CSV, DataFrames

# Standard batch insert (all dialects)
df = CSV.File("drivers.csv") |> DataFrame
bulk_insert(M.Driver.objects, df)
bulk_insert(M.Driver.objects, df, chunk_size=500)  # custom chunk size

# Ultra-fast COPY (PostgreSQL only — 10-100x faster than bulk_insert)
bulk_copy(M.Driver.objects, df)
bulk_copy(M.Driver.objects, df, chunk_size=10_000)

# Map DataFrame columns to model fields
bulk_copy(M.Driver.objects, df, columns=[
    "first_name" => "forename",
    "last_name"  => "surname"
])

# Batch update from DataFrame
bulk_update(M.Result.objects, df,
    columns  = ["points"],     # fields to SET
    match_on = ["resultid"]    # per-row keys to match on (WHERE)
)
# `filters=` is reserved for *constant* predicates AND'd onto every row
# (e.g. filters = ["constructorid" => 131]). Putting a per-row DataFrame
# column in filters= now raises a migration error — use match_on= for keys.
```

**Pre-process CSV nulls before bulk operations:**
```julia
for col in [:position, :milliseconds, :rank]
    df[!, col] = map(x -> ismissing(x) || x == "\\N" ? missing : x, df[!, col])
end
```

## Transactions

```julia
using PormG

# Wrap multiple operations in a single atomic transaction
PormG.run_in_transaction("db") do
    M.Race.objects.create("year" => 2025, "name" => "New Race", "date" => today())
    bulk_insert(M.Result.objects, results_df)
end
# All operations commit together, or all roll back on error
```
