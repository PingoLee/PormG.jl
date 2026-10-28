## An expression `update` too wide for its `DecimalField` raises 22003 on SQLite as it writes (#1330)

- **Version**: 0.9.0
- **PormG ref**: #1330, amends the #1110 entry (`2026-10-21-1110-sqlite-numeric-overflow-raises-on-read.md`) ; `src/Dialect.jl` (`decimal_assignment_guard_sql`), `src/querybuilder/execution_write.jl` (`_decimal_assignment_guard`), `src/querybuilder/engine_facts.jl` (`_unchecked_decimal_assignment_width`)
- **Recorded**: 2026-10-27
- **Severity**: behavior change, SQLite only. `update(field => <expression>)` into a `DecimalField(max_digits = p, decimal_places = s)` raises `StatementError` with `sqlstate == "22003"` on a row whose value needs more than `p - s` digits before the point, and the `UPDATE` writes nothing, where it used to store the value. PostgreSQL and MySQL are unchanged: their column already refuses it.

### What changed

The column is `numeric(p, s)`. PostgreSQL refuses a value too wide for it when the `UPDATE` runs
("numeric field overflow", SQLSTATE 22003), and MySQL's strict mode refuses it the same way. SQLite's
NUMERIC affinity stored it, and since #1110 every later read of that row raised the same error, in a
different call. Whether a row overflows depends on its value, so it cannot be refused when the query is
built. On SQLite, the value PormG writes now checks itself on each row:

```sql
SET "points" = CASE WHEN abs(CAST(replace(printf('%.14e', x), 'Inf', '9e999') AS REAL)) < 99999999.995 THEN x
                    ELSE abs(CAST(x AS INTEGER) * 0 - 9223372036854775807 - 1) END
```

A row whose value does not fit raises SQLite's "integer overflow", which PormG reports as
`sqlstate == "22003"` (#1356). The check reads the value as the #1110 read does, to 15 significant
digits and then rounded to the field's places, so a value the `UPDATE` stores always reads back, and
one it refuses is one every read would refuse. It rounds before it compares, as PostgreSQL does:
`99.995` into a `DecimalField(max_digits = 4, decimal_places = 2)` is `100.00`, too wide.

| `update("points" => F("raceid") * k)`, `DecimalField(10, 2)`, race 18 | before, SQLite | now, every engine |
|---|---|---|
| `k = 1_000_000` (`18000000`) | stores `18000000.00` | stores `18000000.00` |
| `k = 10_000_000` (`180000000`) | stores `180000000`, and every read of the row raises 22003 | `StatementError`, `sqlstate == "22003"`; nothing is written |

The expression appears three times in the statement, and the values it binds are bound once per
occurrence. The `CASE` evaluates its condition and one arm, so a `Subquery` in that position runs twice
per row. A double that overflows to infinity is refused too. A literal value is unchanged:
`DecimalValidator` refuses one that does not fit on every engine (#761). A `DecimalField` wider than 15
digits is not checked on SQLite, which stores none of its values exactly (#648).

### How to find the calls to migrate

```bash
grep -rnE '(^|[.[:space:]])update\(.*=>' --include=*.jl src/ test/
```

The pattern also matches a trailing-dot chain's `update(` line. Keep the hits that write an expression
(`F(…)`, a function such as `Round(…)` or `Cast(…)`, `Joined(…)`, `Subquery(…)`) into a `DecimalField`
and run on SQLite, and also any `save()` of a row with an expression assigned to one, since `save()`
writes through `update`. The call now raises where it used to store a value no read could return. A
test that expected the update to succeed there and the read to raise now sees the error at the
`update`.

### Migrate your app

```julia
# ✗ before — on SQLite the update stored 180000000, and every read of the row raised 22003
M.Constructor_results.objects.filter("constructorresultsid" => 1).update("points" => F("raceid") * 10_000_000)

# ✓ after — catch the error at the write, as on PostgreSQL, or declare a field wide enough for the value
try
    M.Constructor_results.objects.filter("constructorresultsid" => 1).update("points" => F("raceid") * 10_000_000)
catch e
    e isa StatementError && e.sqlstate == "22003" || rethrow()
    # numeric field overflow: nothing was written
end
```
