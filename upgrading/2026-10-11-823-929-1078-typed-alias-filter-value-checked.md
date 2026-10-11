## A value filtered against a `Cast` or `Subquery` alias is checked against its type (#823, #929, #1078)

- **Version**: Unreleased
- **PormG ref**: #823, #929, #1078 ; `src/querybuilder/projection_types.jl` (`_sql_type_field`, `subquery_formatters`)
- **Recorded**: 2026-10-11
- **Severity**: behavior change. A filter that bound its value unchecked now raises
  `InvalidValueError` when the value does not fit the alias's type; on SQLite a few such filters
  now match where they did not.

### What changed

A filter on a projection alias formats its value by the alias's type. Three kinds of alias had no
type PormG knew, so the value went to the engine as given — on SQLite a non-number against a number
matched nothing, on PostgreSQL it failed at the server:

| Alias | `filter(alias => "abc")` before | after |
|---|---|---|
| `Cast(x, "int2" / "int4" / "int8" / "float4" / "float8")`, or a `PositiveIntegerField` type name (#823) | bound `"abc"` | `InvalidValueError` (not a valid number) |
| `Cast(x, "dec")` / `"dec(p, s)"`, PostgreSQL's third spelling of `numeric` (#1078) | bound `"abc"` | `InvalidValueError` |
| `Subquery(…)` projecting one number column (#929) | bound `"abc"` | `InvalidValueError` |
| SQLite: a `Subquery` over a `UUIDField`, with an uppercase UUID | bound as written: **no rows** | normalized to lowercase: matches |

A value that fits is bound as before. The pattern lookups (`@startswith`, …) on a `uuid`, `inet` or
`cidr` cast alias now read the text on PostgreSQL, where they used to fail at the server.

### Who this affects

Queries that filter a `Cast` alias of those type names, or a `Subquery` alias, with a value of
another type — usually a string where a number is meant.

### How to find the calls to migrate

```bash
grep -rnE 'Cast\([^)]*"(int[248]|float[48]|dec|uuid)' --include=*.jl .
grep -rnE '=> *Subquery\(' --include=*.jl .
```

For each alias, check the type of the values its filters receive.

### Migrate your app

```julia
q = M.Result.objects.values("g" => Cast("grid", "int8"))

# A numeric string ("12") still binds and matches, as before. A non-number is what changed:

# ✗ before — "abc" bound as given: no rows on SQLite, a server error on PostgreSQL
q.filter("g" => "abc")

# ✓ after — it raises InvalidValueError before the query runs; validate free text first
n = tryparse(Int, form_value)
n === nothing || q.filter("g" => n)
```
