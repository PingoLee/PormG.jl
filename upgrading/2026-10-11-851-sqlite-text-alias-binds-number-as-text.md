## SQLite: a number filtered against a text alias binds as text, so it matches (#851)

- **Version**: 0.8.0
- **PormG ref**: #851 ; `src/querybuilder/projection_types.jl` (`_sqlite_preserve_native_parameter`, `_TEXT_OUTPUT_FUNCTIONS`)
- **Recorded**: 2026-10-11
- **Severity**: behavior change. On SQLite a filter that returned no rows now returns the rows
  PostgreSQL returned. On PostgreSQL only a `ToChar` alias's bound parameter changes (from `2020` to
  `"2020"`), so its `show_query = :params` / `inspect_query` output changes; its rows do not.

### What changed

On SQLite, a number or `Bool` filter value was always bound natively. Against a text expression,
neither side has a column affinity, so `('' || 7) = 7` is false and the filter matched nothing.
PostgreSQL bound `"7"` and matched. SQLite now binds the value as text whenever the alias is a
text expression, and keeps it native against a number alias (`SUM(x) = '1.5'` would be false):

| Filter (SQLite) | before | after |
|---|---|---|
| `values("yr" => ToChar("date", "YYYY")).filter("yr" => 2020)` | binds `2020`, no rows | binds `"2020"`, the 2020 races |
| `M.Result.objects.values("pt" => Lower("positiontext")).filter("pt" => 1)` (and `Upper`, `Trim`, `Replace`, `Concat`, `Coalesce` over text, an `F` over a text column) | binds `1`, no rows | binds `"1"`, the winners |
| `values("pts" => Sum("points")).filter("pts__@in" => [25.5, 1.5])` | each element bound as formatted text, no rows | each element native, as `=` already bound it |

### Who this affects

SQLite queries that filter a text-valued alias (`ToChar`, `Lower`, `Concat`, …) with a number, or
an aggregate alias with an `@in` / `@nin` list of numbers — usually code written against SQLite
whose empty result was worked around. Code that pins the SQLite parameter vector of such a query
sees the value change type.

### How to find the calls to migrate

```bash
grep -rnE 'ToChar|Lower\(|Upper\(|Trim\(|Replace\(|Concat\(|Coalesce\(' --include=*.jl . | grep -E 'values\('
```

For each alias that is filtered, check whether the filter value is a number.

### Migrate your app

```julia
q = M.Race.objects.values("raceid", "yr" => ToChar("date", "YYYY")).filter("yr" => 2020)

# ✗ before — on SQLite, q returned no rows (PostgreSQL returned the 2020 races), so code written
#   against SQLite often filtered with the text instead: .filter("yr" => "2020")

# ✓ after — q returns the 2020 races on both engines. The text spelling still works; nothing has
#   to change, but a test that asserts the empty SQLite result now fails.
```
