## `Extract(x, "EPOCH")` is a decimal: PostgreSQL casts it to `numeric`, and MySQL builds its quotient (#1457)

- **Version**: Unreleased
- **PormG ref**: #1457 ; `src/Dialect.jl` (`EXTRACT`), `src/querybuilder/projection_types.jl` (`_epoch_extract`), `src/querybuilder/expression_kind.jl`
- **Recorded**: 2026-10-29
- **Severity**: behavior change on PostgreSQL and MySQL. Queries over `EPOCH` that raised `QueryBuildError` now build. PostgreSQL renders `EXTRACT(EPOCH FROM x)::numeric`. On a PostgreSQL server older than 14, the value reads back as a `Decimal` instead of a `Float64`.

### What changed

`EPOCH` was the one date part with no type of its own, so PormG treated it as a value it could not
type. It is now a decimal: the seconds, with their fraction.

- **MySQL builds a quotient over it.** MySQL's `EPOCH` is already a DECIMAL. A division over it used to
  raise `QueryBuildError` ("`/` over a side whose type PormG cannot name"); it now builds and keeps the
  fraction.
- **PostgreSQL and MySQL build an integer cast of a sum over it.** `Cast(Sum(F("year") + Extract(…,
  "epoch")) / 2, "integer")` used to raise `QueryBuildError`, because the sum's type was unknown. The sum
  is now a decimal, and the cast rounds it as it rounds any decimal.
- **PostgreSQL casts it to `numeric`.** `extract` returns a `numeric` from PostgreSQL 14 and a
  `double precision` before that. PormG now renders `EXTRACT(EPOCH FROM x)::numeric`, so the value is a
  decimal on every server version. On 14 and later the cast changes nothing. On an older server, the
  value reads back as a `Decimal` instead of a `Float64`, and the cast rounds the `double` to 15
  significant digits: a current timestamp's seconds keep 5 decimals (10 microseconds), one fewer than
  the `Float64` had. A `Cast(…, "integer")` of it then rounds a half away from zero, where the
  `double` rounded it to even. These points are inferred from PostgreSQL's cast rules; they were not
  measured on a server older than 14.
- **A CTE column over a sum of it is a `DecimalField`.** It used to be an `IntegerField`. A filter on
  that column now takes a decimal value.

SQLite has no `EPOCH` part and still raises `BackendCapabilityError`.

Examples on `Race`, whose `start_at` is a `DateTimeField`, and `Result`, whose `fastestlaptime` is a
`DurationField`:

| query | before | now |
|---|---|---|
| `values("v" => Extract("start_at", "epoch") / 2)` on MySQL | `QueryBuildError` | builds; the value is a `Decimal` |
| `values("v" => Sum(Extract("fastestlaptime", "epoch")) / 2)` on MySQL | `QueryBuildError` | builds |
| `values("v" => Cast(Sum(F("year") + Extract("start_at", "epoch")) / 2, "integer"))` on PostgreSQL or MySQL | `QueryBuildError` | builds |
| `values("v" => Extract("start_at", "epoch"))` on PostgreSQL, SQL | `EXTRACT(EPOCH FROM "Tb"."start_at")` | `EXTRACT(EPOCH FROM "Tb"."start_at")::numeric` |
| the same, value on PostgreSQL 14+ | `Decimal` | `Decimal` (unchanged) |
| the same, value on PostgreSQL 13 or older | `Float64` | `Decimal` |

### Who this affects

- Code on MySQL that worked around the refusal, for example by casting `EPOCH` before dividing it.
- Code that compares PostgreSQL SQL text containing `EXTRACT(EPOCH FROM …)`.
- Code on a PostgreSQL server older than 14 that expects `EPOCH` to read back as a `Float64`, or
  needs its last microsecond digit.

### How to find the calls to migrate

```bash
grep -rniE 'Extract\([^)]*"epoch"' --include=*.jl src/ test/
```

### Migrate your app

A cast that only worked around the MySQL refusal can go:

```julia
# ✗ before — MySQL refused the quotient, so the seconds were cast first
q = M.Race.objects
q.values("raceid", "half" => Cast(Extract("start_at", "epoch"), "numeric(20,6)") / 2)

# ✓ after — the seconds are a decimal on PostgreSQL and MySQL
q = M.Race.objects
q.values("raceid", "half" => Extract("start_at", "epoch") / 2)
```

On a PostgreSQL server older than 14, if code needs the `Float64` it used to get, convert the
`Decimal` it reads (`Float64(row["s"])`), or cast in the query: `Cast(Extract("start_at", "epoch"), "float")`.
