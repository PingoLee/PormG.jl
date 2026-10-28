## A number function over a date, a time or a UUID is refused on every engine (#1387)

- **Version**: Unreleased
- **PormG ref**: #1387 ; `src/querybuilder/projection_types.jl` (`_check_operand_domain`, `_non_number_math_refusal`), `src/querybuilder/engine_facts.jl` (`_extracts_epoch_of`), `src/querybuilder/select_nodes.jl`
- **Recorded**: 2026-10-27
- **Severity**: behavior change. On SQLite, `Round`, `Floor`, `Ceil`, `Sqrt`, `Exp`, `Ln`, `Power`, `Mod`, `Abs`, `Sum` and `Avg` over a `DateField`, a `DateTimeField`, a `TimeField` or a `UUIDField`, or over an expression that is one of those, used to build and return a number computed on the stored text, or `NULL`. They now raise `QueryBuildError` when the query is built. On PostgreSQL the same query used to fail at the server and now fails at build time.

### What changed

A math function means a number, and a date, a timestamp, a time or a UUID is not one. #1324 refused a
duration under these functions; this refuses the other kinds the type walk can name, including under
`Sum` and `Avg`, which mean a duration's total and mean but no date's. Measured on SQLite for the 2009
Australian Grand Prix (`date` 2009-03-29, `time` 06:00:00) and the 17 races of 2009:

| expression on `Race` | SQLite before | PostgreSQL before | now, every engine |
|---|---|---|---|
| `values("v" => Round("date"))` | `2009.0`, the year's digits | fails at the server | `QueryBuildError` |
| `values("v" => Round("time"))` | `6.0`, the hour | fails at the server | `QueryBuildError` |
| `values("v" => Sqrt("date"))`, `Floor("start_at")` | `NULL` | fails at the server | `QueryBuildError` |
| `values("v" => Sum("date"))` over 2009 | `34153.0`, 17 × 2009 | fails at the server | `QueryBuildError` |
| `values("v" => Avg("start_at"))` over 2009 | `2009.0` | fails at the server | `QueryBuildError` |
| `values("v" => Round(F("date") + Day(1)))`, `Floor(Max("date"))` | computed on the text | fails at the server | `QueryBuildError` |
| `values("v" => Round(<a UUIDField>))` | computed on the text | fails at the server | `QueryBuildError` |
| `values("v" => Round("time", 2))` | `QueryBuildError` naming text (#1061) | `QueryBuildError` naming text | `QueryBuildError`, new message |
| `values("v" => Round(Extract("date", "year")))`, `Sum("fastestlaptime")` on `Result` | built | built | builds, unchanged |

The refusal says why on every engine and names the number you may mean, applied before the function:

- a calendar part of a date or a timestamp: `Extract(d, "year")`, or the column's transform
  (`"date__@year"`);
- a clock part of a timestamp or a time: `Extract(t, "hour")`;
- a day count, the difference of two dates (`F("raceid__date") - F("driverid__dob")` on `Result`);
- the seconds, `Extract(d, "epoch")`, only where the engine's `EPOCH` reads that kind: a date or a
  timestamp on PostgreSQL and MySQL, a time on PostgreSQL. SQLite has no `EPOCH` part.

A UUID holds no number, and the message says so. Text is refused by its own rule under every number
function (#1293), a JSON key lookup keeps its own (#1061, #1279), and so does a boolean (#1386). An operand PormG cannot type is let through, as before.
MySQL (unreleased) refuses the same shapes.

### Who this affects

Code that applies `Round`, `Floor`, `Ceil`, `Sqrt`, `Exp`, `Ln`, `Power`, `Mod`, `Abs`, `Sum` or `Avg`
to a `DateField`, a `DateTimeField`, a `TimeField` or a `UUIDField`, across a relation
(`"raceid__date"`), or to an expression over one (`F("date") + Day(1)`, `Max("date")`, a `Coalesce` of
dates).

### How to find the calls to migrate

```bash
grep -rnE '\b(Round|Floor|Ceil|Sqrt|Exp|Ln|Power|Mod|Abs|Sum|Avg)\(' --include=*.jl src/ test/
```

For each match, check whether its operand is a date, a timestamp, a time or a UUID column, or an
expression that is one.

### Migrate your app

```julia
# ✗ before — SQLite averaged the leading digits of each `HH:MM:SS` text
q = M.Race.objects
q.filter("year" => 2009)
q.values("v" => Avg("time"))

# ✓ after — average the start hour, a number on every engine
q = M.Race.objects
q.filter("year" => 2009)
q.values("v" => Avg(Extract("time", "hour")))
```
