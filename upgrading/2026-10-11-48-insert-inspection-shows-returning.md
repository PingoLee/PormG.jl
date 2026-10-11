## `create()` / `get_or_create()` inspection on PostgreSQL shows the `RETURNING *` it executes (#48)

- **Version**: Unreleased
- **PormG ref**: #48 ; `src/querybuilder/execution_write.jl` (`insert`, `_get_or_create`)
- **Recorded**: 2026-10-11
- **Severity**: behavior change. The executed SQL did not change. The SQL text that inspection
  returns for a PostgreSQL INSERT did: `show_query = :sql` / `:dict` / `:inspection` on
  `create()` and `get_or_create()`, and `inspect_query(q; operation = :insert)`.

### What changed

On PostgreSQL, `create()` and the insert half of `get_or_create()` have always executed the INSERT
with ` RETURNING *;` appended — that is how the new row comes back. Inspection used to show the
INSERT without it, so it showed a statement that never ran. It now shows what executes:

| | before | after |
|---|---|---|
| `M.Driver.objects.create(…; show_query = :sql)` | `INSERT INTO "driver" (…) VALUES ($1, $2, …)` | `INSERT INTO "driver" (…) VALUES ($1, $2, …) RETURNING *;` |
| `get_or_create(…; show_query = :sql)` | `… ON CONFLICT ("code") DO NOTHING` | `… ON CONFLICT ("code") DO NOTHING RETURNING *;` |
| `inspect_query(q; operation = :insert)[:sql_text]` | no `RETURNING` | ends `RETURNING *;` |

The parameter vector is unchanged. SQLite is unchanged: it runs the plain INSERT and reads the row
back with a separate SELECT, so its inspected INSERT still has no `RETURNING`. `update_or_create()`
already showed its `RETURNING` and is unchanged.

### Who this affects

Only code that asserts the inspected SQL text of a PostgreSQL `create()` / `get_or_create()` —
a golden-SQL test that compares the whole string, or one that checks how it ends. Application
code that executes these calls needs no change.

### How to find the calls to migrate

```bash
grep -rnE -B3 'show_query *= *:(sql|dict|inspection)' --include=*.jl test/ | grep -E 'create\('
grep -rnE 'inspect_query|\.inspect\(' --include=*.jl test/
```

The second grep is broad: `inspect_query` picks the INSERT on its own when the handle carries values
and no filter. For each hit that runs against a PostgreSQL connection, look at the expected-SQL
string or the `endswith` / `==` assertion beside it.

### Migrate your app

```julia
sql = M.Driver.objects.create("driverref" => "senna", "forename" => "Ayrton",
                              "surname" => "Senna"; show_query = :sql)

# ✗ before
@test endswith(rstrip(sql), ")")

# ✓ after
@test endswith(rstrip(sql), "RETURNING *;")
```
