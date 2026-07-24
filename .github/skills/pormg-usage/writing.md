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
# Returns a PormGRow (since #166) — the same row object get()/first()/list() return,
# fully populated (including the new PK) and ready to mutate and save().
new_id = driver[:driverid]
```

### Mutate a fetched row and persist with `row.save()`
`get()`, `first()`, `list()`, and `create()` return `PormGRow` values (and `update_or_create()`
returns `(row::PormGRow, created::Bool)`). Assigning a field marks it dirty; `save()` writes only
the changed columns.
```julia
driver = M.Driver.objects.get("driverref" => "senna")   # a PormGRow
driver.nationality = "Brazil"        # dirty-tracked on assignment
driver.save()                        # UPDATE ... WHERE <pk> = ...; returns the PormGRow
# save() is a no-op (returns the row unchanged) when nothing was mutated.
# Inspect without executing: driver.save(show_query=:sql)
```

### Update matching records (queryset)
```julia
n = M.Driver.objects.
    filter("driverid" => 1).
    update("nationality" => "Brazil")
# Queryset .update() returns the matched-row count (Int), not a row.

# With F-expression (atomic, at the database)
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

## Many-to-Many Relationships

Access a `ManyToMany` field on a fetched row to get a relation manager, then call its
bang-free methods (`add`/`remove`/`clear`/`set`/`all` — renamed from `add!`/… in 0.3.0).
Targets may be primary keys or row objects. (The example assumes the model declares the
relation — here `Driver` has a `sponsors` `ManyToManyField`.)
```julia
driver = M.Driver.objects.get("driverref" => "senna")

driver.sponsors.add(1, 2)                 # link sponsors 1 and 2
driver.sponsors.remove(2)                 # unlink sponsor 2
changes = driver.sponsors.set(1, 4, 5)    # replace the whole set → (added=…, removed=…)
driver.sponsors.clear()                   # unlink all
rows = driver.sponsors.all() |> DataFrame # query the related rows
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
    columns  = ["points"],     # participating fields (+ any "df_col" => "field" mappings)
    match_on = ["resultid"]    # per-row merge keys, bare model field names (WHERE)
)
# `columns=` is the ONLY place a df column is mapped to a model field; a field
# selected by match_on= is used for matching, never SET. `filters=` is reserved
# for *constant* predicates AND'd onto every row (e.g. filters =
# ["constructorid" => 131]). Putting a per-row DataFrame column in filters=,
# or a "df_col" => "field" pair in match_on=, raises a migration error.
```

**Pre-process CSV nulls before bulk operations:**
```julia
for col in [:position, :milliseconds, :rank]
    df[!, col] = map(x -> ismissing(x) || x == "\\N" ? missing : x, df[!, col])
end
```

## Transactions

Wrap multiple writes so they commit together or all roll back on error. `atomic(db) do … end`
is the friendly alias of `run_in_transaction`; both take a db-key `String`.
```julia
using PormG

atomic("db") do
    M.Race.objects.create("year" => 2025, "name" => "New Race", "date" => today())
    bulk_insert(M.Result.objects, results_df)
end
# All operations commit together, or all roll back on error.
```

**Nested `atomic` = SAVEPOINT.** A nested `atomic`/`run_in_transaction` on the same db becomes
a savepoint (partial rollback), not a second top-level transaction:
```julia
atomic("db") do
    M.Race.objects.create("year" => 2025, "name" => "New Race", "date" => today())
    try
        atomic("db") do                       # SAVEPOINT
            M.Result.objects.create("raceid" => 1, "driverid" => 1, "points" => 25)
        end                                    # rolls back to the savepoint on error…
    catch
        # …leaving the outer Race insert intact; the outer transaction continues.
    end
end

# Force a real top-level transaction (throws if one is already active):
atomic("db"; durable=true) do
    # ...
end
```

**Row locking — `select_for_update()`** (PostgreSQL; silent no-op on SQLite). Chainable; must
run inside a transaction, and locks the matched rows until COMMIT:
```julia
atomic("db") do
    standing = M.Constructor_standings.objects.
        filter("constructorid" => 131, "raceid" => 1120).
        select_for_update().                   # kwargs: nowait, skip_locked, no_key
        list() |> first
    M.Constructor_standings.objects.
        filter("constructorstandingsid" => standing[:constructorstandingsid]).
        update("points" => standing[:points] + 25)
end
```
