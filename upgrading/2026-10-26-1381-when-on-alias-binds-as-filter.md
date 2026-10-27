## A `When` condition on a projection alias checks and binds its value as a filter on the alias does (#1381)

- **Version**: Unreleased
- **PormG ref**: #1381 ; `src/querybuilder/filter_nodes.jl` (`_render_filter_oper`), `src/querybuilder/projection_types.jl` (`_bind_alias_value`)
- **Recorded**: 2026-10-26
- **Severity**: behavior change, PostgreSQL and SQLite. A `When` condition on a projection alias with a value the alias's type refuses now raises `InvalidValueError` when the query is built, as `filter`/`Q` on the alias does; it was sent to the database. A valid value is bound as the alias's filter binds it, which changes the bound value in a few cases (below). MySQL is unreleased.

### What changed

`values("d" => F("date"))` then `Case([When("d" => v, then = 1)], default = 0)`, in a filter or in the
projection, bound `v` raw. `filter("d" => v)` and `Q("d" => v)` on the same alias run it through the
alias's formatter, which checks the value and binds it in the form that type takes. The `When`
condition now does the same, so the three spellings agree:

| `values("d" => F("date"), "n" => F("laps"), "k" => F("metadata__wins"))` then `When(…)` | before | now |
|---|---|---|
| `When("d" => "not-a-date", …)` | bound `"not-a-date"`: the database raised, or compared text | `InvalidValueError` |
| `When("n" => "five", …)` | bound `"five"` | `InvalidValueError` |
| `When("n" => 2.5, …)`, PostgreSQL | bound `2.5` | bound `"2.5"`, as `Q("n" => 2.5)` binds it (SQLite keeps `2.5`, as `Q` does) |
| `When("d__@in" => [Date(2020, 1, 2)], …)` | bound a `Date` | bound `"2020-01-02"`, as `Q` binds it |
| `When("k__@gt" => 100, …)`, PostgreSQL | `… #>> '{"wins"}' > $1`, a text comparison | `(… #>> '{"wins"}')::numeric > $1` |
| `When("k__@isnull" => true, …)`, SQLite | `FilterError` | `json_extract(…) IS NULL` |

A `When` condition on a model field, or on a path that is not a projection alias, is unchanged.

### How to find the calls to migrate

Look for `When("<alias>" => …)` (inside `Case(...)`) whose key names an alias from the same query's
`values(...)` rather than a field, and for a `try` around such a query that expects a database error
for a value of the wrong type.

### Migrate your app

```julia
q = M.Result.objects
q.values("resultid", "pts" => F("points"))

# ✗ before: sent to the database; now InvalidValueError when the query is built
q.filter(Case([When("pts" => "ten", then = 1)], default = 0) == 1)

# ✓ a value of the alias's type
q.filter(Case([When("pts" => 10, then = 1)], default = 0) == 1)
```
