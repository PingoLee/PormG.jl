## `Extract`'s `MILLISECONDS`, `MICROSECONDS` and `JULIAN` are decimals: PostgreSQL casts them to `numeric`, and `Concat` over a fractional one is refused (#1552)

- **Version**: Unreleased
- **PormG ref**: #1552 ; `src/querybuilder/projection_types.jl` (`_decimal_extract_kind`), `src/querybuilder/expression_kind.jl`, `src/Dialect.jl` (`EXTRACT`)
- **Recorded**: 2026-11-01
- **Severity**: behavior change on PostgreSQL and MySQL. `Concat` over `Extract(x, "milliseconds")`, and over `Extract(x, "julian")` of a timestamp, now raises `QueryBuildError`, where it built. A CTE column over any of the three parts now builds, where it raised. PostgreSQL renders the three parts `EXTRACT(… FROM x)::numeric`, so on a server older than 14 they read back as a `Decimal` instead of a `Float64`.

### What changed

#1457 made `EPOCH` a decimal. The other parts PostgreSQL computes as a fractional `numeric` still had
no type, so PormG treated them as values it could not type. They are decimals now, as measured on
PostgreSQL 18.6 (LibPQ and Postgres.jl) and MySQL 8.4, where each reads back as a `Decimal`:

| part | value | whole? |
|---|---|---|
| `MILLISECONDS` | the seconds with their fraction, times 1000 (`1500.000`) | no: below a millisecond it has a fraction |
| `MICROSECONDS` | the seconds times 10^6 (`1500000`) | yes |
| `JULIAN` (PostgreSQL only) | the Julian day | over a date; over a timestamp it carries the day's fraction |

What that changes:

| expression | before | now |
|---|---|---|
| `Concat(Value("t="), Extract("start_at", "milliseconds"))` on PostgreSQL and MySQL | built; each engine wrote its own text (`1500.000`, `1500.0000`) | `QueryBuildError` (#1027): cast it to text |
| `Concat(Value("j="), Extract("start_at", "julian"))` on PostgreSQL | built | `QueryBuildError` (#1027) |
| `Concat` over `MICROSECONDS`, or `JULIAN` of a date | built | builds, unchanged: a whole number writes the integer's text |
| a CTE column projecting one of the three parts | `QueryBuildError`: "the CTE column … cannot be typed" | builds, typed `DecimalField` |
| the SQL on PostgreSQL | `EXTRACT(MILLISECONDS FROM x)` | `EXTRACT(MILLISECONDS FROM x)::numeric` (the same for `MICROSECONDS` and `JULIAN`) |
| the value read back on PostgreSQL 14 or later | `Decimal` | `Decimal`, unchanged |
| the value read back on a PostgreSQL server older than 14 | `Float64` | `Decimal` |

`SECOND` is unchanged: it is the truncated integer it was (`trunc(…)::integer` on PostgreSQL). SQLite
has none of these parts and still raises `BackendCapabilityError`. The older-server row is inferred
from PostgreSQL's cast rules, as #1457's was; it was not measured on a server older than 14.

### Who this affects

Code that concatenates text with `Extract(x, "milliseconds")` or `Extract(<a timestamp>, "julian")`,
and code that reads these parts on a PostgreSQL server older than 14 and expects a `Float64`.

### How to find the calls to migrate

```bash
grep -rniE 'Extract\([^)]*"(milliseconds|microseconds|julian)"' --include=*.jl src/
```

### Migrate your app

```julia
# ✗ before: built, and wrote each engine's own text of the number
q = M.Race.objects
q.values("label" => Concat(Value("ms="), Extract("start_at", "milliseconds")))
# ✓ after: say which text, or round to the number you mean first
q.values("label" => Concat(Value("ms="), Cast(Extract("start_at", "milliseconds"), "text")))
q.values("label" => Concat(Value("ms="), Cast(Round(Extract("start_at", "milliseconds")), IntegerField())))
```

On a PostgreSQL server older than 14, convert where you need a float:
`Float64(row[:ms])`.
