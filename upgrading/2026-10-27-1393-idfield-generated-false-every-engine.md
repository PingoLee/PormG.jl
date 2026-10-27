## `IDField(generated = false)` is a key no engine fills: SQLite and MySQL DDL change, and the write paths refuse to generate it (#1393)

- **Version**: Unreleased
- **PormG ref**: #1393 ; `src/models/fields.jl` (`_database_generates`), `src/Dialect.jl` (`field_to_column`), `src/migrations/column_spec.jl` (`_column_identity`, `_inspectdb_id_pk`), `src/migrations/introspection.jl` (`_sqlite_rowid_alias`), `src/querybuilder/execution_bulk.jl` (`allocate_primary_keys`)
- **Recorded**: 2026-10-27
- **Severity**: breaking. A model with an `IDField(generated = false)` key gets a planned migration on SQLite and MySQL, and some calls on it now raise.

### What changed

`IDField(generated = false)` declares a key the caller supplies. Only PostgreSQL's DDL read
`generated`. SQLite and MySQL rendered the same auto-increment key as `IDField()`, and the write paths
treated every `IDField` key as one the database generates. So on PostgreSQL `allocate_primary_keys`
asked for `nextval` from a sequence that does not exist and returned the DataFrame with the ids
missing, and no error. `bulk_insert` left an all-blank key column out of the `INSERT`, which then
failed NOT NULL.

`generated` now decides the key on every engine, in the DDL and on the write path:

| `IDField(generated = false)` | before | now |
|---|---|---|
| PostgreSQL column | `bigint PRIMARY KEY UNIQUE NOT NULL` | unchanged |
| SQLite column | `INTEGER PRIMARY KEY AUTOINCREMENT UNIQUE NOT NULL`, filled by SQLite | `BIGINT PRIMARY KEY UNIQUE NOT NULL`, not a rowid alias |
| MySQL column | `BIGINT NOT NULL AUTO_INCREMENT PRIMARY KEY` | `BIGINT NOT NULL PRIMARY KEY` |
| `allocate_primary_keys(df)` | PostgreSQL: the frame with the ids missing; SQLite: ids filled; MySQL: `BackendCapabilityError` | `QueryBuildError`, on every engine, whatever `df` holds |
| `bulk_insert`/`bulk_copy` with every key cell blank | the column is left out; the database raises NOT NULL (SQLite and MySQL filled the ids) | `InvalidValueError` (the key does not allow null), nothing sent |
| `bulk_insert`/`bulk_copy` with some key cells blank | `QueryBuildError` (mixed blank and explicit values) | `InvalidValueError`, nothing sent |
| `bulk_insert(df; returning = …)` with no key column | SQLite: ids pre-allocated, rows written; PostgreSQL: an allocation from a sequence that does not exist; MySQL: `BackendCapabilityError` | `QueryBuildError` (no key to match the rows by), nothing sent |
| `create()`, `bulk_insert` or a raw `INSERT` without the key, on SQLite or MySQL | the database generated an id | the database refuses the row |

`IDField()` (a key the database generates) is unchanged on every engine. A SQLite `INTEGER PRIMARY
KEY` is a rowid alias, which SQLite fills with or without `AUTOINCREMENT`, so a caller-supplied key
must have another type there: `BIGINT`, the same 64-bit integer.

**The planned migration.** On a table created before this change, the next `makemigrations` plans
the key's identity change: a table rebuild on SQLite (the twelve-step copy, ids kept), and
`ALTER TABLE … MODIFY COLUMN` dropping `AUTO_INCREMENT` on MySQL. MySQL refuses that `MODIFY` on a key
another table's foreign key references, so PormG runs it with `FOREIGN_KEY_CHECKS = 0` for that one
statement: only the identity changes, never a stored value. PostgreSQL plans nothing: its column
already had no identity.

**`generate_models_from_db`** writes `IDField(generated = false)` for a primary key the database does
not fill: on SQLite, an integer key that is not a rowid alias (a `BIGINT` or `INT` key, a `WITHOUT
ROWID` table), and a key of a type PormG has no field for, such as `REAL`; on MySQL, a `BIGINT` key
without `AUTO_INCREMENT`. Such a SQLite key used to be written as `IDField(auto_increment = false)`,
and since #1334 as `IDField()`. A rowid alias without `AUTOINCREMENT` stays `IDField()`.

`allocate_primary_keys` on a SQLite key holding a value that is not a 64-bit integer (a `REAL` key
declared `IDField()` by hand) raises `QueryBuildError`, where it raised `InexactError`.

### How to find the calls to migrate

```
grep -rn 'generated *= *false' models/ db/
grep -rn 'allocate_primary_keys' src/
```

Include generated model files. For each `IDField(generated = false)` model, check its
`allocate_primary_keys`, `bulk_insert` and `create()` calls: each must carry the key. A file
`generate_models_from_db` wrote on SQLite or MySQL can change when regenerated (see above).

### Migrate your app

```julia
# The model: a key copied from the source system
Circuit_source = Models.Model("circuit_source",
  circuitid = Models.IDField(generated = false),
  name = Models.CharField(max_length = 255))

# ✗ before: on PostgreSQL the ids came back missing; on SQLite they were allocated
df = allocate_primary_keys(M.Circuit_source.objects, DataFrame(name = ["Monza", "Spa"]))
# ✓ after: the key comes with the data
df = DataFrame(circuitid = [14, 13], name = ["Monza", "Spa"])
bulk_insert(M.Circuit_source.objects, df)

# A key the database should generate is IDField():
circuitid = Models.IDField()
```

Then run `makemigrations` and `migrate` on each SQLite and MySQL database, to rebuild or alter the
existing tables.
