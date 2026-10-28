## A number cast to a date is refused on SQLite and MySQL (#1417)

- **Version**: Unreleased
- **PormG ref**: #1417 ; `src/querybuilder/engine_departures.jl` (the `:date` row), `src/querybuilder/projection_types.jl` (`_number_operand`, `_cast_divergent_operand`)
- **Recorded**: 2026-10-27
- **Severity**: behavior change. On SQLite, `Cast(x, "date")` over a number used to build and return a date the number never meant. It now raises `QueryBuildError` when the query is built. On PostgreSQL the query is unchanged and still fails at the server.

### What changed

A number has no calendar date, so its cast to one is an error: PostgreSQL has no `integer::date`,
`float8::date` or `numeric::date`, and rejects the query when it runs. SQLite's `date()` reads the
number as a Julian day: `date(5)` is `-4713-11-29` and `date(2455000)` is `2009-06-17` (measured on
3.54.0). MySQL reads its digits as a date (`20090329` is `2009-03-29`), and NULL where they spell
none. Both are silent different answers, so the cast is refused on SQLite and on MySQL (unreleased)
when the query is built, as #1325 refuses a duration or a time cast to a date.

The refusal covers any operand the type walk names a number cast to a date: an integer, a float or
a decimal column, a literal, a number function (`Floor`), an aggregate (`Sum`), arithmetic, and the
`output_field = "date"` of `Coalesce`/`Greatest`/`Least`/`Case`. A date or a timestamp cast to a
date builds as before, and so does a number cast to text or to another number.

Examples on `Result`, whose `grid` is an `IntegerField`:

| expression | before (SQLite) | before (PostgreSQL) | now (SQLite) |
|---|---|---|---|
| `Cast("grid", "date")` | `-4713-11-29` for grid 5 | fails at the server | `QueryBuildError` (#1417) |
| `Cast(Value(5.5), DateField())` | `-4713-11-30` | fails at the server | `QueryBuildError` (#1417) |
| `Cast("raceid__date", "date")` | the date | the date | builds, unchanged |

### Who this affects

Code that casts a number to a date on SQLite, typically to turn a stored day count or a `YYYYMMDD`
integer into a date.

### How to find the calls to migrate

```bash
grep -rn -E 'Cast\(.*("date"|DateField\(\))' --include=*.jl src/ test/
```

For each match, check whether the operand is a number.

### Migrate your app

```julia
# ✗ before — a day in 4713 BC on SQLite; now raises QueryBuildError (#1417)
q = M.Result.objects
q.values("d" => Cast("grid", "date"))

# ✓ after — add a number of days to a date, or build the Date in Julia and bind it
q = M.Race.objects
q.values("d" => F("date") + Day(1))
```
