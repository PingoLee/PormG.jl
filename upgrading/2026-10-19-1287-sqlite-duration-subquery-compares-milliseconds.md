## A duration `Subquery`, or a duration CTE column on the right, compares its length on SQLite, not its text (#1287)

- **Version**: Unreleased
- **PormG ref**: #1287 ; `src/querybuilder/expression_render.jl` (`_render_interval_operand`, `_render_interval_left`), `src/querybuilder/filter_nodes.jl`, `src/Dialect.jl` (`_sqlite_interval_text_ms`)
- **Recorded**: 2026-10-19
- **Severity**: behavior change, SQLite only. Comparing a `DurationField` with a `Subquery` or a CTE column that holds a duration, ordering by a duration `Subquery` alias, a filter on that alias, and `Greatest`/`Least`/`Coalesce` over a duration `Subquery` can return other rows, in another order, or another value, and bind milliseconds instead of text. A timestamp difference ordered against one builds where it was refused. PostgreSQL is unchanged.

### What changed

SQLite stores a duration as text (`HH:MM:SS[.sss]`), and a `Subquery(...)` that projects one returns
that text, as a CTE column does. The text sorts wrongly at 100 hours and above (`"100:00:00"` sorts
before `"99:00:00"`) and for negative durations. A model `DurationField` has been compared and
ordered by its milliseconds since #894, and a CTE column since #1219 and #1285, but only on the
**left** of a comparison. These still used the text:

- a `DurationField` ordered against a `Subquery` that projects a duration:
  `"fastestlaptime__@gt" => Subquery(…)`, `F("fastestlaptime") > Subquery(…)`;
- a `DurationField` ordered against a CTE column that holds a duration:
  `"fastestlaptime__@gt" => CTE("r", "fast")`, `F("fastestlaptime") > CTE("r", "fast")`;
- `order_by` on a projected `Subquery` alias that holds a duration, and a filter on that alias
  (`"best__@gt" => Minute(1)`);
- `Greatest`, `Least` and `Coalesce` with a duration `Subquery` operand
  (`Greatest(Subquery(…), "fastestlaptime")`), which picked by the text and now picks by length,
  returning the text of the value it picked;
- a timestamp difference ordered against a duration `Subquery` or CTE column (on `Race`,
  `(F("start_at") - F("date")) > Subquery(…)`), which was refused as an ordering against a value with
  no millisecond form and now builds.

Each now compares milliseconds on both sides. A `Subquery` binds its correlation and its filters,
so its text is read once, in a scalar subquery around it; its parameters keep their order. The
lookups are `@gt`, `@gte`, `@lt` and `@lte`, and `>`/`<`/`>=`/`<=` between `F` expressions.
Equality still compares the stored text, which is exact for a value written in the canonical form.

Examples on `Result`, whose `fastestlaptime` is a `DurationField`, with `best` a correlated
`Subquery` projecting another result's `fastestlaptime`:

| query | SQLite before | SQLite now |
|---|---|---|
| `filter("fastestlaptime__@gt" => Subquery(best))` | `"Tb"."fastestlaptime" > (SELECT …)`: text against text | the milliseconds of each side |
| `values("b" => Subquery(best)); order_by("b")` | `ORDER BY "b"`: the text | `ORDER BY` the subquery's milliseconds |
| `values("b" => Subquery(best)); filter("b__@gt" => Minute(1))` | `(SELECT …) > ?` with `"00:01:00"` | the milliseconds `> ?` with `60000` |
| `filter("fastestlaptime__@gt" => CTE("r", "fast"))` | `"R1"."fastestlaptime" > "R1_1"."fast"`: text | the milliseconds of each column |

### Who this affects

On SQLite, code that orders a `DurationField` against a `Subquery` or a CTE column holding a
duration, or orders or filters a projected duration `Subquery` alias, where a value is 100 hours or
longer, or negative. Shorter non-negative values were already ordered the same way by their text,
so their rows do not change; only the SQL and the bound value do.

### How to find the calls to migrate

```bash
grep -rnE 'Subquery\(|CTE\(' --include=*.jl src/ test/
```

For each, check whether it holds a duration and whether a comparison or an `order_by` orders it.

### Migrate your app

```julia
# Before: on SQLite a 100 h lap sorted below a 99 h one as text
# Now: ordered by length, as the column is; no change is needed to get PostgreSQL's order
best = M.Result.objects
best.filter("raceid" => OuterRef("raceid"))
best.values("t" => Min("fastestlaptime"))
q = M.Result.objects
q.values("resultid", "b" => Subquery(best))
q.order_by("b")
```
