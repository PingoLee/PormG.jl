## SQLite: a cast to `date` returns a date; a cast to a timestamp, time or interval is refused (#822)

- **Version**: Unreleased
- **PormG ref**: #822 ; `src/Dialect.jl` (`sqlite_cast_sql`, the CASE arms), `src/querybuilder/ctes.jl`, `src/querybuilder/build_query.jl`
- **Recorded**: 2026-10-11
- **Severity**: behavior change. On SQLite one cast returns a different value and the others raise;
  on both engines a single-`When` `Case` with an `output_field` now renders its cast.

### What changed

SQLite has no temporal types: every temporal type name gets numeric affinity, so `CAST('2020-03-29'
AS DATE)` is the integer `2020`. PormG rendered exactly that:

| Expression | before | after |
|---|---|---|
| SQLite: `Cast("date", "date")`, `Cast(x, DateField())`, `Case(…; output_field = DateField())` | `CAST(… AS DATE)`, the integer `2020`; a date filter on it matched nothing | `date(…)`, read back as a `Date`, as on PostgreSQL |
| SQLite: `Cast(x, "timestamp")` / `"time"` / `"interval"`, `Cast(x, DateTimeField())`, `TimeField()`, `DurationField()` (and the same `output_field` on a `Case`) | a number (`2020`, `10`, `1`) | `BackendCapabilityError` |
| Both engines: `Case(When(…), default = …; output_field = DateField())` — a **single** `When`, not a vector | the result was not cast (PostgreSQL cast only the `default` branch) | the cast is rendered, as the vector form `Case([When(…)], …)` always did: `(CASE … END)::date` on PostgreSQL, `date(CASE … END)` on SQLite |

`Coalesce`, `Greatest`, `Least` and `Concat` render no cast on SQLite, so a declared date there is
still refused. PostgreSQL's casts are unchanged.

### Who this affects

SQLite code that casts to a temporal type (and either used the number it got back or worked around
it), and code on either engine that passes `output_field` to a single-`When` `Case`.

### How to find the calls to migrate

```bash
grep -rnE 'Cast\([^)]*(date|time|interval|DateField|DateTimeField|TimeField|DurationField)' --include=*.jl .
grep -rnE 'output_field *= *(Date|DateTime|Time|Duration)Field' --include=*.jl .
```

### Migrate your app

```julia
# ✗ before — on SQLite this was the year as a number; a timestamp cast was a number too
M.Race.objects.values("d" => Cast("start_at", "date"))
M.Race.objects.values("t" => Cast("start_at", "timestamp"))

# ✓ after — the date cast reads back a Date on both engines. For a timestamp on SQLite, project
#   the DateTimeField itself: it reads back as a DateTime
M.Race.objects.values("d" => Cast("start_at", "date"))
M.Race.objects.values("t" => "start_at")
```
