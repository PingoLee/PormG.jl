# PormG Usage — Writing Data, Bulk Operations & Transactions

Supporting file for [`SKILL.md`](SKILL.md). Read it when **changing data**: create, update, delete,
upserts, bulk loads, many-to-many, transactions, primary-key allocation. Schema changes (migrations)
are in [`models.md`](models.md). Full detail:
[Writing](https://pingolee.github.io/PormG.jl/stable/write/),
[Transactions](https://pingolee.github.io/PormG.jl/stable/write/transaction/).

## Rows and single-record writes

`create`, `get`, `first`, `last` and `list` return `PormGRow` values. A row is dirty-tracked:
assign a field, then `save()` writes only the changed columns.

```julia
row = M.Status.objects.create("statusid" => 900, "status" => "Provisional")  # a PormGRow
row.pk                        # the primary key, whatever the column is called
row.status = "Confirmed"      # marks the field dirty
row.save()                    # UPDATE … WHERE pk; a no-op when nothing changed
row.delete()                  # (total, per-table counts), cascading like query.delete()
```

- `save()` needs a model with exactly one primary key, and a row fetched with that key projected.
- `row.save(show_query = :sql)` shows the planned `UPDATE` without running it.

### Upserts

```julia
# Fetch-or-insert; never modifies an existing row. `defaults` are used only on insert.
row, created = M.Status.objects.get_or_create("statusid" => 900;
                                              defaults = ["status" => "Provisional"])

# Insert-or-update in one INSERT … ON CONFLICT … DO UPDATE. `defaults` is the SET.
row, created = M.Status.objects.update_or_create("statusid" => 900;
                                                 defaults = ["status" => "Confirmed"])
```

The lookup pairs become the `ON CONFLICT` target, so a real `UNIQUE`/primary-key constraint must
back them.

## Update and delete querysets

```julia
n = M.Result.objects.
    filter("raceid" => 1, "positionorder" => 1).
    update("points" => F("points") + 1)          # returns the matched-row count (Int)

M.Result.objects.filter("raceid__year__@lt" => 1960).delete()
M.Result.objects.filter("raceid" => 999).delete(show_query = :sql)   # inspect, never runs
```

Safety guards (each raises; see [`errors.md`](errors.md)):

- `update`/`delete` with **no filter** → `UnsafeMutationError`. To delete every row, opt in:
  `M.Model.objects.delete(allow_delete_all = true)`.
- `delete` with `limit`/`offset`/`order_by`/`distinct`/aggregates → `UnsafeMutationError`.
- Deleting a row a `PROTECT`/`RESTRICT` key still references → `ProtectedError`.
- A connection with `change_data: false` refuses every write → `WritesDisabledError`.

## Many-to-many

Reading a `ManyToManyField` off a fetched row gives a manager. Its methods take primary keys or rows.
In this example, `Driver` declares `sponsors = Models.ManyToManyField(Sponsor, related_name = "drivers")`:

```julia
driver = M.Driver.objects.get("driverref" => "senna")
driver.sponsors.add(1, 2)
driver.sponsors.remove(2)
changes = driver.sponsors.set(1, 4, 5)       # replace the whole set → (added = …, removed = …)
driver.sponsors.clear()
rows = driver.sponsors.all() |> DataFrame
```

Filter across the relation with `__` like any other: `filter("sponsors__name" => "Marlboro")`.

## Bulk operations

Never loop `create()` over a batch. The bulk writers take a `DataFrame`:

```julia
bulk_insert(M.Status.objects, df)                         # every backend
bulk_insert(M.Status.objects, df, chunk_size = 500)
bulk_insert(M.Status.objects, df, on_conflict = :nothing) # skip rows that violate a unique key
bulk_insert(M.Status.objects, df,                         # upsert
    on_conflict = (action = :update, target = ["statusid"], set = ["status"]))

bulk_copy(M.Lap_times.objects, laps_df)                   # PostgreSQL COPY: much faster, no ON CONFLICT

bulk_update(M.Result.objects, df,
    columns  = ["points"],        # the fields to SET (a "df_col" => "field" pair maps a column)
    match_on = ["resultid"])      # per-row match keys, bare field names
```

- `columns = ["df_col" => "field"]` is the only place a DataFrame column is mapped to a field.
  `filters = [...]` on `bulk_update` holds **constant** predicates ANDed onto every row.
- `bulk_copy` on SQLite raises `BackendCapabilityError`. Use `bulk_insert` there.
- Omit the auto primary-key column, or leave it all `missing`, and the database assigns the ids.
  **Never** prefill `max(id) + 1`. A column mixing blank and explicit ids is rejected.
- Normalize CSV sentinels such as `"\N"` to `missing` before loading. Never weaken a field to
  accept dirty data.

### Primary keys and sequences

```julia
# Reserve ids BEFORE inserting — to wire a child table's FK in the same load
drivers_df = allocate_primary_keys(M.Driver.objects, drivers_df)   # fills the driverid column
atomic("db") do
    bulk_insert(M.Driver.objects, drivers_df)
    bulk_insert(M.Result.objects, results_df)    # built from drivers_df.driverid
end

# After writing EXPLICIT primary keys row by row, repair the sequence once
resync_sequences(M.Driver)
```

`bulk_insert`/`bulk_copy` resync automatically after explicit ids. The row-level writers (`create`,
`get_or_create`, `update_or_create`) do not, so a later auto-id insert collides until you call
`resync_sequences`.

## Transactions

`atomic(db) do … end` is the friendly name for `run_in_transaction`. `db` is a db-key `String`
(or a settings/pool object). Everything inside commits together or rolls back together.

```julia
atomic("db") do
    race = M.Race.objects.create("year" => 2025, "round" => 1, "circuitid" => 1,
                                 "name" => "Test GP", "date" => Date(2025, 3, 16))
    bulk_insert(M.Result.objects, results_df)
end
```

- **A nested `atomic` on the same db is a SAVEPOINT.** If it throws, only its own work rolls
  back, and the outer transaction continues when you catch the error:
  ```julia
  atomic("db") do
      M.Status.objects.create("statusid" => 901, "status" => "Kept")
      try
          atomic("db") do                        # SAVEPOINT
              M.Status.objects.create("statusid" => 902, "status" => "Discarded")
              error("validation failed")
          end
      catch
      end                                        # 901 commits, 902 does not
  end
  ```
- `with_savepoint(f, settings, "name")` is the explicit form, with a fixed, non-user-controlled
  name. It is a no-op outside a transaction. Prefer nested `atomic`.
- `atomic("db"; durable = true)` insists on being the outermost transaction and raises
  `TransactionError` inside another one.
- **Retry the whole transaction, never a statement.** A lost connection inside one raises
  `OperationalError` and the transaction is gone.
- `in_transaction_context()` reports whether the current task is inside one. Tasks spawned
  inside a transaction join it — see [`async.md`](async.md).

**Row locking** (PostgreSQL; a silent no-op on SQLite). Inside a transaction, `select_for_update()`
locks the matched rows until `COMMIT`:

```julia
atomic("db") do
    standing = M.Constructor_standings.objects.
        filter("constructorid" => 131, "raceid" => 1120).
        select_for_update().                   # also: nowait = true, skip_locked = true
        first()
    M.Constructor_standings.objects.
        filter("constructorstandingsid" => standing.constructorstandingsid).
        update("points" => F("points") + 25)
end
```

**Suspending foreign keys** — you almost never need it. Inside a transaction, foreign-key checks
already wait until `COMMIT` on both backends, so a plain `atomic` handles writing children before
parents. `without_foreign_keys` is still **one** transaction; it does not commit in chunks. It exists
for repairing a database that is already inconsistent, or for deliberately planting a violation in
a SQLite test. Write it as the outermost block: `without_foreign_keys("db") do … end`.

The two engines differ. On SQLite it sets `PRAGMA foreign_keys = OFF`, refuses to nest inside
another transaction (`TransactionError`), and with `check_on_exit = true` rolls back with
`UnsafeMutationError` if orphans remain. On PostgreSQL it defers the constraints: it nests without
complaint, and an orphan is refused at `COMMIT` as an `IntegrityError` (PingoLee/PormG.jl#686).
