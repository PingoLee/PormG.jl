## `makemigrations` leaves hand-made indexes and CHECKs alone, and stops re-planning a PostgreSQL expression default (#847, #934, #1037)

- **Version**: 0.8.0
- **PormG ref**: #847, #934, #1037 ; `src/migrations/introspection.jl` (one-column index readers, `get_constraints_index`), `src/migrations/planner.jl`, `src/migrations/column_spec.jl` (`CHECK_MARKER_RE`, `db_default_owner`)
- **Recorded**: 2026-10-11
- **Severity**: behavior change. `makemigrations` writes a different plan for the same models and
  the same database. Some plans that used to drop an index or a CHECK the models never declared no
  longer do; some gain a statement.

### What changed

| Live schema | Plan before | Plan after |
|---|---|---|
| A one-column index made by hand that PormG cannot write: DESC, GIN or another non-btree method, a non-default operator class, its own collation, INCLUDE, an EXCLUDE constraint, an invalid index (#847) | read as the column's `db_index`; a model without `db_index` on that column planned `DROP INDEX` | not read as `db_index`, never planned away |
| The same hand-made index on a column whose field **does** declare `db_index = true` (#847, #934) | it satisfied the declaration; nothing was planned | PostgreSQL plans PormG's own `CREATE INDEX` beside it. On SQLite a hand-made DESC or collated index still satisfies it |
| A hand-made **partial** or **expression** index that is a column's only index, the field declaring `db_index = true` (#934) | SQLite: it satisfied the declaration | SQLite plans PormG's own `CREATE INDEX` too (PostgreSQL already did) |
| The `_drop_index` fallback (a removed `db_index`) naming a hand-made partial, expression, GIN, DESC or opclass index on the column (#934) | could pick that index by name and drop it | skips it, on both engines |
| A hand-made CHECK whose comment only contains PormG's marker inside a longer token — `xpormg:check:<16 hex>`, or the marker followed by a 17th hex digit (#934) | read as PormG-owned; an undeclared one was planned `DROP` | unowned: never planned away |
| PostgreSQL: a `db_default` expression the server prints back with casts (`lower('OPEN')` → `lower('OPEN'::text)`) (#1037) | `SET DEFAULT` planned on every `makemigrations` run | one more `SET DEFAULT`, carrying a `DO` block that writes a `pormg:default:…` marker into the column comment; after that, no plan |
| PostgreSQL: a new expression `db_default` (in `CREATE TABLE`, `ADD COLUMN` or `SET DEFAULT`) (#1037) | the statement alone | the same plan entry also carries that `DO` block — a golden plan test sees it |

The CHECK case only reaches CHECKs made outside PormG; the comment PormG writes is unchanged. The
`db_default` marker keeps any comment already on the column, and SQLite's `db_default` is
unchanged.

### Who this affects

- A database carrying indexes or CHECKs that a DBA or another tool created, migrated with
  `makemigrations` / `migrate`.
- A PostgreSQL model with a `db_default` expression, whose next plan holds one `SET DEFAULT` with a
  `DO` block in it — expected once per column.

### How to find the calls to migrate

There is no call to change. Before the next deploy, plan and read the plan:

```bash
grep -rnE 'makemigrations\(|migrate\(' --include=*.jl .
```

```julia
PormG.Migrations.makemigrations("db")
PormG.Migrations.dry_run("db")
```

### Migrate your app

```julia
# ✗ before — an undeclared hand-made DESC index on result(grid) was planned away
# DROP INDEX "result_grid_desc_idx";

# ✓ after — it is left alone. To have PormG manage it, declare its shape and let the next
#   makemigrations adopt it:
Result = Models.Model(…, indexes = [Models.Index(fields = ["-grid"], name = "result_grid_desc_idx")])
```
