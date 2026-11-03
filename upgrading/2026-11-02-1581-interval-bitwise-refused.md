## A bitwise operator on an interval raises `QueryBuildError` at build on every engine (#1581)

- **Version**: Unreleased
- **PormG ref**: #1581 ; `src/querybuilder/expression_render.jl` (`_render_interval_left`, `_refuse_bitwise_interval`)
- **Recorded**: 2026-11-02
- **Severity**: behavior change on every engine. A bitwise operator with a `DurationField` column, a timestamp difference or any other interval on either side built. It now raises `QueryBuildError` when the query is built.

### What changed

An interval has no bits, so `&`, `|`, `~`, `<<`, `>>` and `xor` have no meaning over one. PormG
rendered them anyway. PostgreSQL then rejected the SQL when it ran, because it has no `interval &
bigint` operator. SQLite and MySQL computed on what they store and returned a number with no
meaning: SQLite on the `HH:MM:SS` text, MySQL on the count of microseconds.

Here `time` is a `DurationField` and `lap` an `IntegerField` on `Lap_times`:

| expression | before | now |
|---|---|---|
| `F("time") & 1`, `1 & F("time")` | PostgreSQL: `StatementError` when run. SQLite, MySQL: a number | `QueryBuildError` at build, every engine |
| `F("lap") \| F("time")`, `F("time") << 1`, `F("lap") >> F("time")` | the same | `QueryBuildError` at build, every engine |
| `~F("time")`, `xor(F("time"), 1)` | the same | `QueryBuildError` at build, every engine |
| `(F("raceid__date") - F("raceid__date")) & 1` (a timestamp difference) | the same | `QueryBuildError` at build, every engine |

Bitwise operators over integers are unchanged.

### Who this affects

Code that applies a bitwise operator to a `DurationField` column or to an interval expression. On
PostgreSQL such a query never returned rows. On SQLite and MySQL it returned numbers that do not
depend on the duration in any meaningful way.

### How to find the calls to migrate

```bash
grep -rnE 'F\("[a-z_]+"\) *(&|\||<<|>>)|xor\(|~F\(' --include=*.jl .
```

For each hit, check whether a side is a `DurationField` column or a difference of two dates.

### Migrate your app

Say which number you mean. For the interval's length in seconds, extract it first (PostgreSQL and
MySQL), and apply the bitwise operator to an integer:

```julia
# ✗ before: built; a value with no meaning on SQLite and MySQL
q = M.Lap_times.objects
q.values("mask" => F("time") & 1)

# ✓ after: the lap time's milliseconds, an integer column, is the number to test
q = M.Lap_times.objects
q.values("mask" => F("milliseconds") & 1)
```
