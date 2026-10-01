## `Coalesce`/`Greatest`/`Least` now cast to their `output_field` on both engines (#852)

- **Version**: Unreleased
- **PormG ref**: #852 ; `src/Dialect.jl`
- **Recorded**: 2026-10-01
- **Severity**: breaking (narrow). A temporal or array `output_field` on these three functions now raises `BackendCapabilityError` on SQLite, where it used to be ignored. Every other declared type now changes the SQL on SQLite, and for `Greatest`/`Least` on PostgreSQL too.

### What changed

`Coalesce`, `Greatest` and `Least` take an `output_field`, and PormG trusted it everywhere. A filter on
the alias was checked against that type, and a CTE column built from it was typed as that type. The SQL
did not always apply it, though, so the value could be the operand's own:

| engine | function | before | after |
|---|---|---|---|
| PostgreSQL | `Coalesce` | `(COALESCE(…))::type` | unchanged |
| PostgreSQL | `Greatest`, `Least` | no cast | `(GREATEST(…))::type`, `(LEAST(…))::type` |
| SQLite | all three | no cast | `CAST(… AS TYPE)`, or `date(…)` for a `date` |
| SQLite | a `timestamp`, `time`, `interval` or array type | ignored | raises `BackendCapabilityError`, as `Cast(x, type)` does (#822) |
| SQLite | a CTE column declared `date` on these three | raised `QueryBuildError` | accepted: the column is a date |
| PostgreSQL | a CTE column typed by a sized array, e.g. `Cast(x, "numeric(10,2)[]")` or `"varchar(20)[]"` | typed as the scalar (a decimal, a varchar) | raises `QueryBuildError`, as `"integer[]"` always did |

On SQLite, the missing cast meant that a filter typed by the declaration compared the operand's own
value with a value of the declared type. A `start_at` timestamp declared `date` never equalled a date,
and text declared `integer` never equalled a number. The filter returned no rows, with no error.

A real cast also behaves like `Cast`. `CAST(2.7 AS INTEGER)` truncates to `2` on SQLite, while
PostgreSQL's `::integer` rounds to `3`. That divergence already applied to `Cast`, and now applies to
these three functions too.

### Who this affects

Apps that pass `output_field` to `Coalesce`, `Greatest` or `Least`. Before the change, the consuming
apps were measured at **0** such call sites, so none needs an edit.

### How to find the calls to migrate

```bash
grep -rnE '(Coalesce|Greatest|Least)\(' --include='*.jl' <your-app>/src | grep 'output_field'
```

A multi-line call can hide from that grep. On SQLite the error is raised when the query is built,
so a test run surfaces every temporal or array one that remains. A temporal type raises
`output_field: SQLite cannot cast to …`, and an array raises `output_field: SQLite has no array types; …`.
A CTE column typed by an array raises `A CTE column cannot be typed from the SQL type …`.

### Migrate your app

A temporal `output_field` on SQLite has no exact rendering. Project the column itself, or declare
`date` or `text`:

```julia
# ✗ before: declared timestamp, ignored on SQLite; now raises BackendCapabilityError there
M.Race.objects.values("raceid", "start" => Coalesce("start_at", "date"; output_field = "timestamp"))

# ✓ after: a date renders date(…) on SQLite and ::date on PostgreSQL
M.Race.objects.values("raceid", "day" => Coalesce("start_at", "date"; output_field = "date"))
```

Every other declared type needs no source change. Check that the cast is the type you meant,
because it now applies to the value.
