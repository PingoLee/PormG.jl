## A cast to `smallint` or `integer` raises 22003 on SQLite for a value outside the type (#1356)

- **Version**: Unreleased
- **PormG ref**: #1356 ; `src/Dialect.jl` (`integer_cast_guard_sql`), `src/querybuilder/select_nodes.jl` (`_integer_cast_guard`), `ext/PormGSQLiteExt.jl` (`backend_error_fields`)
- **Recorded**: 2026-10-27
- **Severity**: behavior change, SQLite. `Cast(x, "smallint")` / `Cast(x, "integer")` (and `IntegerField()`) over a value outside the type raises `StatementError` with `sqlstate == "22003"` where it returned the value. Any SQLite "integer overflow" error now carries `sqlstate == "22003"`. PostgreSQL is unchanged. MySQL is unreleased.

### What changed

A cast to `smallint` or `integer` means the type's range: PostgreSQL raises "integer out of range"
(SQLSTATE 22003) on a value outside it. SQLite's `CAST(x AS INTEGER)` and `CAST(x AS SMALLINT)` apply no
range below 64 bits, so `Cast(F("driverid") * 100_000_000, "integer")` returned `2_200_000_000` for driver 22,
and a filter on it compared that number.

PormG now renders the cast on SQLite as a guard that raises on such a row:

```sql
CASE WHEN CAST(x AS INTEGER) BETWEEN -2147483648 AND 2147483647 THEN CAST(x AS INTEGER)
     ELSE abs(CAST(x AS INTEGER) * 0 - 9223372036854775807 - 1) END
```

SQLite raises "integer overflow" there, which PormG reports as a `StatementError` with
`sqlstate == "22003"`, the error PostgreSQL's cast gives. It raises in a projection, a filter, an
`ORDER BY` or an aggregate alike, and only on the rows outside the range: a value inside it reads back as
itself. An operand that binds a value (`F("driverid") * 100_000_000`) binds it once per occurrence in the
guard.

| `Cast(F("driverid") * 100_000_000, "integer")`, SQLite | before | now |
|---|---|---|
| driver 21 | `2_100_000_000` | `2_100_000_000` |
| driver 22 | `2_200_000_000` | `StatementError`, `sqlstate == "22003"` |
| `filter(cast > 0)` over all drivers | every driver | `StatementError`, `sqlstate == "22003"` |

Every SQLite "integer overflow" error (also `abs()` of the smallest integer, or a `sum()` past 64 bits)
now carries `sqlstate == "22003"`; before it had no SQLSTATE.

A declared `output_field = "integer"` (`Coalesce`, `Greatest`, `Case`) is not guarded: it stays a plain
cast. A `bigint` cast is not guarded on SQLite either. SQLite stores 64-bit integers, and past 64 bits its cast
saturates to the largest (or smallest) integer, which nothing can tell from a real value. That is
documented on the Backends page (`docs/src/backends.md`).

### How to find the calls to migrate

Look for `Cast(…, "smallint")`, `Cast(…, "integer")`, `Cast(…, "int"/"int2"/"int4")` and a field struct
that declares one (`IntegerField()`, `PositiveSmallIntegerField()`, `PositiveIntegerField()`) in queries that run on SQLite over values that can leave the type's range: a product, a
sum, a text column holding large numbers. Also look for a `catch` that tests `e.sqlstate === nothing` on
a SQLite "integer overflow" error.

### Migrate your app

```julia
# ✗ before: on SQLite a value past 2147483647 came back as it was
M.Driver.objects.values("x" => Cast(F("driverid") * 100_000_000, "integer"))

# ✓ cast to the type that holds the value
M.Driver.objects.values("x" => Cast(F("driverid") * 100_000_000, "bigint"))
```
