## `Greatest`/`Least` skip a `NULL` argument on SQLite, as on PostgreSQL (#844)

- **Version**: Unreleased
- **PormG ref**: #844; `src/querybuilder/build_helpers.jl` (`_null_skipping_operands`)
- **Recorded**: 2026-10-01
- **Severity**: behavior change, on SQLite. PostgreSQL is unchanged.

### What changed

PostgreSQL's `GREATEST`/`LEAST` ignore a `NULL` argument and return `NULL` only when every argument
is `NULL`. On SQLite, PormG rendered the scalar `MAX(a, b)`/`MIN(a, b)`, which return `NULL` when
**any** argument is `NULL`. So the same query gave a different answer per engine.

SQLite now gives PostgreSQL's answer. It renders one `COALESCE` per rotation of the arguments:
`Greatest(a, b)` is `MAX(COALESCE(a, b), COALESCE(b, a))`.

| On SQLite | before | after |
|---|---|---|
| `Greatest("date", "fp1_date")`, race 1000 (no `fp1_date`) | `missing` | `Date("2018-07-29")` |
| `Least("points", 25)` on a row with `NULL` points | `missing` | `25` |
| every argument `NULL` | `missing` | `missing` |
| no argument `NULL` | the value | the same value |

A single-argument `Greatest(x)` / `Least(x)` is not affected.

### How to find the calls to migrate

```bash
grep -rnE '(Greatest|Least)\(' src/
```

Only code that relied on SQLite's `NULL` result needs an edit. That is a call with a nullable
argument whose result the app tested for `missing`.

### Migrate your app

```julia
# ✗ before — on SQLite a NULL fp1_date made the result missing, and the app read that as "no practice"
rows = M.Race.objects.values("raceid", "g" => Greatest("date", "fp1_date")).list(:dict)
no_practice = [r[:raceid] for r in rows if ismissing(r[:g])]

# ✓ after — ask for the NULL directly; Greatest now returns the race date there
rows = M.Race.objects.filter("fp1_date__@isnull" => true).values("raceid").list(:dict)
no_practice = [r[:raceid] for r in rows]
```

To keep the old "any `NULL` gives `NULL`" result on purpose, write it with `Case`: return `NULL`
when any argument is `NULL`, and `Greatest(...)` otherwise.
