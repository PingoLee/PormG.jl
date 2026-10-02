## SQLite orders and compares an interval's value by its milliseconds (#894)

- **Version**: Unreleased
- **Recorded**: 2026-10-02
- **PormG ref**: #894; `src/querybuilder/build_query.jl` (`get_order_query`, `_render_alias_predicate`),
  `src/querybuilder/build_helpers.jl` (`_render_function_typed`, `_sqlite_duration_column_ms`),
  `src/querybuilder/execution.jl` (`_render_interval_ms`, `_render_interval_left`)
- **Severity**: behavior change, mostly on SQLite: a silently wrong order or row set becomes the one
  PostgreSQL returns. PostgreSQL renders and binds exactly what it did before; its only change is the
  Julia type `Max`/`Min` over a difference reads back as (last table row).

### What changed

On SQLite an interval leaves a query as the `[-]HH:MM:SS[.f]` text a `DurationField` stores. #881
made every comparison *inside* an expression numeric, but whatever sorted or compared the value
itself still saw only the text. Text order matches numeric order only below 100 hours and for
non-negative values: `"100:00:00"` sorts before `"99:00:00"`, and `"-01:00:00"` before
`"-02:00:00"`. These now use the milliseconds behind the text (`d` = `F("start_at") - F("date")`):

| Expression, on **SQLite** | before | after |
|---|---|---|
| `values("gap" => d); order_by("gap")` | sorted the text | sorts the milliseconds (the expression is repeated in `ORDER BY`, with its parameters bound again) |
| `values("gap" => d); filter("gap__@gt" => Hour(1))`, and `==`, `@range`, `@in` on the alias | compared the text, bound `"01:00:00"` | compares the milliseconds, binds `3600000` |
| `values("span" => Max("start_at") - Min("start_at")); filter("span__@gt" => Hour(1))` (HAVING) | compared the text | compares the milliseconds |
| `values("gap" => d); filter("gap__@gt" => d - Hour(1))`: an alias against another interval expression | compared two texts | compares the milliseconds |
| `Max(d)`, `Min(d)`, `Max("time")`, `Min("time")` | the last or first value in text order | the longest or shortest interval |
| `order_by("time")` on a `DurationField` | sorted the text | sorts the milliseconds |
| `filter("time__@gt" => Minute(2))`, `@gte`/`@lt`/`@lte`/`@range`/`@nrange`, `"time__@gt" => F("other_duration")`, `F("time") > Minute(2)` | compared the text, bound `"00:02:00"` | compares the milliseconds, binds `120000` |
| `Max(d)`, `Min(d)`, over a difference or interval arithmetic, read back (**both engines**) | SQLite: a `String`; PostgreSQL: the driver's value (a `CompoundPeriod`, or a bare `Period`) | a `Dates.CompoundPeriod`, like the difference itself (#581) |

These comparisons round each side to the nearest millisecond, the precision of a SQLite timestamp.
So two `DurationField` values less than a millisecond apart can order the same on SQLite. Their
texts compared exactly before, and PostgreSQL still tells them apart (it keeps microseconds).

These are unchanged, on purpose:

- A `DurationField`'s `==` and `@in` still compare the stored text. That is exact on the canonical
  form every write stores (#891), and an index on the column still serves them.
- `Greatest`/`Least` over intervals, and an interval with no millisecond form (`Coalesce`, `Case`,
  a window function), still sort the text.
- `Sum`/`Avg` still read the text's leading hours.

### How to find the calls to migrate

Ordering or filtering on a `DurationField` column, or on the alias of a timestamp difference, and
`Max`/`Min` over a difference:

```bash
grep -rnP 'order_by\(|__@(gt|gte|lt|lte|range|nrange|in)"|\b(Max|Min)\(' src/
```

An ordering or filter hit matters only on SQLite, and only if the code sorted or filtered values of
100 hours and above, or negative ones. Such code may compensate for the old text order, for example
by re-sorting in Julia or by padding the hours. That compensation is no longer needed. A
`Max`/`Min` hit over a difference matters if the code reads the value as a `String` (SQLite) or as a
bare `Period` (PostgreSQL). Read it as a `Dates.CompoundPeriod`, and compare it with `==`.

### Migrate your app

```julia
# ✗ before: on SQLite, sorting a difference by its alias put 100 h before 99 h, so apps re-sorted
rows = M.Race.objects.
    values("name", "gap" => F("start_at") - F("date")).
    order_by("gap").
    list()
sort!(rows; by = r -> r[:gap])
# ✓ after: the database order is already numeric, on both engines
rows = M.Race.objects.
    values("name", "gap" => F("start_at") - F("date")).
    order_by("gap").
    list()

# ✗ before: on SQLite the latest start of a season read back as text
latest = M.Race.objects.
    filter("year" => 2009).
    values("year", "latest" => Max(F("start_at") - F("date"))).
    list(:dict)[1][:latest]::String
# ✓ after: a duration on both engines
latest = M.Race.objects.
    filter("year" => 2009).
    values("year", "latest" => Max(F("start_at") - F("date"))).
    list(:dict)[1][:latest]::Dates.CompoundPeriod
```
