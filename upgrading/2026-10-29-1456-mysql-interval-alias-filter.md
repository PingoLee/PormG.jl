## MySQL: a duration filter on a `Cast(<duration>, "interval")` alias compares microseconds (#1456)

- **Version**: Unreleased
- **PormG ref**: #1456 ; `src/querybuilder/expression_render.jl` (`_render_interval_operand`)
- **Recorded**: 2026-10-29
- **Severity**: behavior change, MySQL only. A filter comparing a duration with an alias over `Cast(<duration>, "interval")` now returns the rows it names. It used to compare every duration with `0`, so `>` matched every positive duration and `<` matched none.

### What changed

MySQL stores a `DurationField` as a BIGINT count of microseconds, and a filter on the column binds the
duration it compares as that count. A filter on a projection alias over `Cast(<duration>, "interval")`
bound the duration as its `HH:MM:SS` text instead. MySQL compares the BIGINT with that text as a number,
and the text converts to `0`, whatever duration it spells. So `> Minute(1)` and `>= Minute(1)` matched
every positive duration, `< Minute(1)` and `<= Minute(1)` matched none (or only a zero), and
`== Minute(1)` matched only a zero duration. No error was raised.

The alias now binds the microseconds, as the column does. Examples on `Result`, whose `fastestlaptime`
is a `DurationField`:

| query | bound before | bound now |
|---|---|---|
| `values("v" => Cast("fastestlaptime", "interval")).filter("v__@gt" => Minute(1))` | `"00:01:00"` | `60000000` |
| `filter("fastestlaptime__@gt" => Minute(1))` | `60000000` | unchanged |
| `values("v" => Max("fastestlaptime")).filter("v__@gt" => Minute(1))` | `60000000` | unchanged |

The SQL text is unchanged. PostgreSQL and SQLite are not affected: PostgreSQL binds an interval, and
SQLite refuses the cast.

### Who this affects

Code on MySQL that filters on an alias over `Cast(<duration>, "interval")` with a `<`, `<=`, `>`, `>=`
or `=` against a duration. Those queries now return a different row set, the one the filter names:
fewer rows for `>` and `>=`, more for `<` and `<=`, and for `=` the durations equal to the value
instead of the zero ones.

### How to find the calls to migrate

```bash
grep -rnE 'Cast\([^)]*"interval"' --include=*.jl src/ test/
```

### Migrate your app

No code change is needed for the filter itself. A workaround that filtered the column instead of the
alias can go back to the alias:

```julia
# ✗ before — on MySQL the alias filter matched every positive lap, so the column was filtered instead
q = M.Result.objects
q.values("resultid", "lap" => Cast("fastestlaptime", "interval"))
q.filter("fastestlaptime__@gt" => Minute(1))

# ✓ after — the alias filter binds the microseconds, as the column filter does
q = M.Result.objects
q.values("resultid", "lap" => Cast("fastestlaptime", "interval"))
q.filter("lap__@gt" => Minute(1))
```
