## A cast to a time, timestamp, interval or binary type is typed as that type; SQLite refuses `bytea` (#1194)

- **Version**: 0.9.0
- **PormG ref**: #1194 ; `src/querybuilder/projection_types.jl` (`_sql_type_field`), `src/Dialect.jl` (`sqlite_cast_sql`), `src/querybuilder/ctes.jl` (`_declared_type`)
- **Recorded**: 2026-10-20
- **Severity**: behavior change. On PostgreSQL, a pattern lookup or a `Concat` over such a cast raises where it built (and failed when the query ran), an equality value on its alias is checked as the type and can raise `InvalidValueError`, a CTE column declared one of these types builds where it raised, a timestamp cast plus a whole number is shifted by days where it failed when the query ran, and the value reads back through the type's parser (an interval as a `Dates.CompoundPeriod`, where the Postgres.jl driver gave a bare `Period` for a one-part interval). On SQLite, a cast to `bytea` raises `BackendCapabilityError` where it returned an integer, and a filter on a `blob` cast binds bytes where it bound text that never matched.

### What changed

A `Cast` type or an `output_field` names the SQL type of its value. PormG maps the name to a field
to type the value (the read path, the formatter an equality value goes through, the pattern-lookup
rule, `Concat`'s check, the type of a CTE column), and it mapped no name for a time, timestamp,
interval or binary type. So each of these casts was untyped:

- on PostgreSQL, a pattern lookup on its alias rendered a bare `LIKE`, which PostgreSQL has no
  operator for (a server error), an equality value was bound unchecked, and a CTE column declared
  as one was refused (#812, #823);
- on SQLite the time, timestamp and interval casts were already refused (#822), but
  `Cast(x, "bytea")` rendered `CAST(x AS BYTEA)`. SQLite has no type of that name and gives it
  NUMERIC affinity, so it returned an integer (`'abc'` → `0`, `'2009-03-29'` → `2009`), silently.

The names now map:

- `time` to a `TimeField`;
- `timestamp` to a `DateTimeField(type = "TIMESTAMP")`;
- `timestamptz` to a `DateTimeField()`;
- `interval` to a `DurationField`;
- `bytea` and `blob` to a `BinaryField`.

The spellings `time without time zone`, `timestamp with[out] time zone` and a precision
(`timestamp(3)`) map the same way. The value follows the rules of a column of that type:

- a pattern lookup reads a `time` as its text and refuses the others with `FilterError` (#1183);
- `Concat` refuses a timestamp or interval (#1028);
- an equality value is checked and bound by the type's formatter;
- a CTE column declared one of these types is that field on PostgreSQL;
- arithmetic takes the column's path: a timestamp cast plus a whole number is shifted by days;
- the value reads back through the type's parser: an interval as a `Dates.CompoundPeriod`.

A `timestamp` cast binds its value as the UTC text a `DateTimeField(type = "TIMESTAMP")` binds: a
string or `ZonedDateTime` with another offset is converted to UTC first, where PostgreSQL used to drop
the offset.

On SQLite a cast to `bytea` (as `Cast`, or as the `output_field` of `Case`, `Coalesce`, `Greatest` or
`Least`) raises `BackendCapabilityError`, as the temporal casts do. `Cast(x, BinaryField())` and
`Cast(x, "blob")` render `CAST(x AS BLOB)` there and `::bytea` on PostgreSQL.

| expression | engine | before | now |
|---|---|---|---|
| `values("t" => Cast("time", "time"))`, `filter("t__@startswith" => "14:")` | PostgreSQL | built; the query failed when it ran | matches the text, `CAST(… AS text) LIKE` |
| `values("t" => Cast("start_at", "timestamptz"))`, `filter("t__@startswith" => "2009")` | PostgreSQL | built; the query failed when it ran | raises `FilterError` |
| `values("d" => Cast("duration", "interval"))`, `filter("d__@contains" => "1")` | PostgreSQL | built; the query failed when it ran | raises `FilterError` |
| `values("s" => Concat(Value("-"), Cast("start_at", "timestamp")))` | PostgreSQL | built; PostgreSQL's own timestamp text | raises `QueryBuildError` (#1028) |
| `values("d" => Cast("duration", "interval"))`, `filter("d" => 5)` | PostgreSQL | built; the query failed when it ran | raises `InvalidValueError` |
| a CTE body with `"s" => Cast("start_at", "timestamptz")` | PostgreSQL | raised `QueryBuildError` (#812) | builds; the column is a `DateTimeField` |
| `values("n" => Cast("start_at", "timestamp") + 1)`, or a `Case` with `output_field = "timestamp"` plus `1` | PostgreSQL | built `+ $1::bigint`; the query failed when it ran | shifted by one day (`+ make_interval(days => $1::integer)`), typed as a timestamp |
| `values("d" => Cast("duration", "interval"))` | PostgreSQL with the Postgres.jl driver | a one-part interval read back as a bare `Period` | reads back as a `Dates.CompoundPeriod`, as a `DurationField` does |
| `values("b" => Cast("name", "bytea"))` | SQLite | built; read an integer | raises `BackendCapabilityError` |
| `values("b" => Cast("name", "blob"))`, `filter("b" => "abc")` | SQLite | built; compared text with a blob, matched nothing | binds the bytes of `"abc"` |

### Who this affects

Code that casts to `time`, `timestamp`, `timestamptz`, `interval`, `bytea` or `blob` (with `Cast`
or an `output_field`) and then filters the alias with a pattern lookup or with a value that is not of
that type, passes it to `Concat`, or casts to `bytea` on SQLite.

### How to find the calls to migrate

```bash
grep -rnE '(Cast\(|output_field\s*=)[^)]*"(time|timestamp|timestamptz|interval|bytea|blob)' --include=*.jl src/ test/
```

### Migrate your app

```julia
# ✗ before: on SQLite this read an integer; now it raises BackendCapabilityError there
q = M.Driver.objects
q.values("driverid", "b" => Cast("code", "bytea"))

# ✓ after: BinaryField() is BLOB on SQLite and bytea on PostgreSQL
using PormG.Models: BinaryField
q = M.Driver.objects
q.values("driverid", "b" => Cast("code", BinaryField()))

# ✗ before: a pattern lookup on a timestamp cast failed when the query ran on PostgreSQL
q = M.Race.objects
q.values("t" => Cast("start_at", "timestamptz"))
q.filter("t__@startswith" => "2009")

# ✓ after: filter the timestamp by its value, or format it first
q = M.Race.objects
q.values("t" => Cast("start_at", "timestamptz"))
q.filter("t__@gte" => DateTime(2009, 1, 1))
```
