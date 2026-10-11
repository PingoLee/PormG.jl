## A column expression on the right of a LIKE, JSON or `@in` lookup is refused with `FilterError` (#811, #793)

- **Version**: Unreleased
- **PormG ref**: #811, #793 ; `src/querybuilder/filter_pairs.jl` (`_check_column_rhs_lookup`), `src/querybuilder/filter_nodes.jl` (`_render_column_rhs`), `src/querybuilder/filter_operators.jl` (`_render_json_lookup_comparison`)
- **Recorded**: 2026-10-11
- **Severity**: behavior change. Queries that silently returned no rows, or failed at the server,
  now raise `FilterError` when they are built, on both engines.

### What changed

These lookups take a **value** — a text fragment, a JSON key, a list — never a column. Given a
column expression (`F(…)`, a function, a `Case`, a joined or CTE column) they went through code
written for a column-to-column comparison:

| Filter | before | after |
|---|---|---|
| `"payload__key" => F("grid")` — a JSON path equality | PostgreSQL bound the expression's Julia text as the key value: valid SQL, **zero rows, no error**; SQLite failed to bind | `FilterError` |
| `"payload__@has_key" => F("grid")` | PostgreSQL: valid SQL, **zero rows**; `@jcontains` raised `InvalidValueError`, `@has_keys` / `@has_any_keys` said "got a single value" | `FilterError` for all four containment lookups |
| `"surname__@contains" => F("forename")` — every LIKE lookup (`@contains`, `@icontains`, `@startswith`, `@endswith`, their `i`/`n` forms, `@iunaccent_*`) | invalid SQL, failed at the server (`DatabaseError`) | `FilterError` naming the lookup, at the call |
| `"grid__@in" => F("number")`, `@nin` | invalid SQL (`IN "Tb"."number"`), failed at the server | `FilterError` |

The same refusals apply in `Q` / `Qor`, `When`, `cjoin_on` and a `HAVING` alias. A plain
comparison against a column (`"grid" => F("number")`, `@gt`, …) is unchanged.

### Who this affects

Queries that pass a column expression to a LIKE lookup, a JSON lookup or `@in` — usually by
mistake, since none of them could return the intended rows. Code that caught the server's error
around such a query now sees `FilterError` instead.

### How to find the calls to migrate

```bash
grep -rnE '__@(n?i?(contains|startswith|endswith)|iunaccent_[a-z]+|has_key|has_keys|has_any_keys|jcontains|n?in)" *=> *(F|Lower|Upper|Coalesce|Concat|Case)\(' --include=*.jl .
grep -rnE '"[a-z_]+__[a-z0-9_]+" *=> *F\(' --include=*.jl .
```

The second grep is broad: it lists every column-path key compared with an `F`; a hit matters only
when the key's first segment is a `JSONField` (a JSON path equality).

### Migrate your app

```julia
# ✗ before — "surname contains forename" failed at the server
M.Driver.objects.filter("surname__@contains" => F("forename"))

# ✓ after — a LIKE lookup takes a text value. To match one column against another, fetch both
#   and compare in Julia (or write the comparison as a plain `=` / `@gt` lookup, which takes F)
rows = M.Driver.objects.values("driverid", "surname", "forename").list()
filter(r -> occursin(r["forename"], r["surname"]), rows)
```
