## `Sum` / `Avg` over a `BooleanField` are refused; `Max` / `Min` over one read back a `Bool` (#953)

- **Version**: Unreleased
- **PormG ref**: #953 ; `src/querybuilder/select_nodes.jl` (`_render_function_body`), `src/value_repr.jl` (`value_parser(::CBool)` on SQLite)
- **Recorded**: 2026-10-11
- **Severity**: behavior change. Two aggregates that answered on SQLite now raise on both engines;
  two others change their SQL on PostgreSQL and their read-back type on SQLite.

### What changed

PostgreSQL has no `SUM`, `AVG`, `MAX` or `MIN` for a boolean, so all four failed there when the
query ran, while SQLite answered over the stored `0`/`1`:

| Aggregate over `flag = BooleanField()` | before | after |
|---|---|---|
| `Sum("flag")`, `Avg("flag")` | SQLite: the count / share of `true` rows; PostgreSQL: failed at the server | `QueryBuildError` on both, naming `Sum(When("flag" => true, then = 1, otherwise = 0))` |
| `Max("flag")`, `Min("flag")` | SQLite: `1` / `0` (an `Int`); PostgreSQL: failed at the server | SQLite: `true` / `false` (a `Bool`); PostgreSQL: `BOOL_OR` / `BOOL_AND`, a `Bool` |

### Who this affects

Code that sums or averages a boolean column to count or measure `true` rows — it worked on SQLite
only — and code that compares a boolean `Max`/`Min` with `1` / `0`.

### How to find the calls to migrate

```bash
grep -rnE '(Sum|Avg|Max|Min)\("[a-z_]+"' --include=*.jl .
```

For each hit, check whether the column is a `BooleanField`.

### Migrate your app

```julia
# flag = Models.BooleanField() on some model M.Entry

# ✗ before — worked on SQLite only
M.Entry.objects.values("n_true" => Sum("flag"))

# ✓ after — say what is summed
M.Entry.objects.values("n_true" => Sum(When("flag" => true, then = 1, otherwise = 0)))
```
