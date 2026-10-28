## A `numeric(p, s)` value that overflows on SQLite raises `StatementError` as it is read, as on PostgreSQL (#1110)

- **Version**: 0.9.0
- **PormG ref**: #1110, supersedes the "overflow of a column or a computed value" gap the 0.8.0 entry for #1040 records ; `src/Dialect.jl` (`_parse_sqlite_decimal`), `src/value_repr.jl` (`value_parser`), `src/querybuilder/expression_kind.jl` (`_unapplied_declared_decimal`), `src/querybuilder/engine_facts.jl` (`_unapplied_decimal_width`)
- **Recorded**: 2026-10-21
- **Severity**: behavior change, SQLite only. A value read through a declared `numeric(p, s)` (a `Cast`, a decimal `output_field`, a `DecimalField` column) that needs more than `p - s` digits before the point raises `StatementError` with `sqlstate == "22003"` where it used to come back as it was, and a value with more than `s` places comes back rounded to `s`. PostgreSQL is unchanged: it already rounds, and raises the same error when the query runs. MySQL is unchanged.

### What changed

SQLite reads `NUMERIC(p, s)` as an affinity and nothing more, so a cast that overflows on a row
returned the value unchanged there, where PostgreSQL raises "numeric field overflow" (SQLSTATE 22003).
Whether a row overflows depends on its value, so it cannot be refused when the query is built (#1087
refuses the one certain case, a literal). PormG now applies the declaration as it reads the row on
SQLite, the way Django's SQLite backend `quantize`s a `DecimalField` column: it rounds the value to
`s` places, half away from zero as PostgreSQL rounds, and raises on a value that then does not fit.
Measured on the F1 fixture, PostgreSQL 16 and SQLite 3.45:

| `values("x" => Cast("driverid", "numeric(2,0)"))` | PostgreSQL | SQLite, before | SQLite, now |
|---|---|---|---|
| drivers 1 to 99 | `Decimal` `1` … `99` | `Decimal` `1` … `99` | `Decimal` `1` … `99` |
| a driver from 100 | `StatementError` (SQLSTATE `22003`) | `Decimal` `100`, `101`, … | `StatementError` (SQLSTATE `22003`) |

The raise is the same `StatementError` on both engines, from `list()`, `DataFrame(query)` and every
other read, and only the rows that overflow raise. Its message names the projection and the declared
type, never the value (#971).

On SQLite a declared `numeric(p, s)` of at most 15 digits now reads through the parser of a
`DecimalField` column (#648), which applies the width, not the parser of a computed decimal (#1212),
which keeps 15 significant digits. The two agree on every value that has at most `s` places and fits
`p`. Both read a double to 15 significant digits first, as PostgreSQL converts a `float8` to a
`numeric`, so a tie a double cannot hold exactly rounds as PostgreSQL rounds it. A cast whose operand has more places than `s` is
still refused when the query is built (#1040). So this changes a value read back only where the
operand is one PormG cannot type (a JSON key lookup), or where a `DecimalField` column holds a value
that does not fit it: such a value is rounded to the column's scale, and one too wide for its
precision raises on every read, where both used to come back as the raw `Float64` or `Int64` SQLite
stored. A column holds such a value when a tool other than PormG wrote it. An expression `update` too
wide for its `DecimalField` no longer stores one: it raises the same SQLSTATE as it writes, on every
engine (#1330, its own entry). A value composed over a declaration (`Max`,
`Coalesce`, arithmetic) is the computed number it means and keeps the 15-significant-digit read, as
before. A `Lag`/`Lead` with a non-NULL default over a `DecimalField` reads width-less on SQLite: its
default is a value no column holds (PostgreSQL's `lag(numeric(4,2), 1, 999)` returns `999`), so the
column's width neither rounds nor refuses it. The column's values read the same `Decimal`s as before;
a stored cell that does not fit the column now reads as a 15-digit `Decimal` there, where it was the
raw `Float64`.

Not covered, by design: a cast used only in a filter, an `ORDER BY` or a `GROUP BY` is never read
back, so SQLite compares the value as it is there. A declaration wider than 15 digits keeps the
15-significant-digit read and is not checked. MySQL clamps an overflowing cast to the largest value
the type holds, with only a warning, so a read cannot tell it from a value that fits.

### Who this affects

On SQLite, code that projects a `Cast` to `numeric(p, s)`, `decimal(p, s)` or `DecimalField(…)`, or
a `Coalesce`/`Greatest`/`Least`/`Case` with such an `output_field`, over values that can exceed
`p - s` whole digits; and code that reads a `DecimalField` column a tool other than PormG wrote to,
or one an expression `update` wrote before #1330.

### How to find the calls to migrate

```bash
grep -rnE '(numeric|decimal|dec) *\( *[0-9]|output_field *= *DecimalField|Cast\([^)]*DecimalField' --include=*.jl src/ test/
```

Read each hit that is a `Cast` type or an `output_field`, and give it a precision that holds every
value it can see. A test that expected the unchanged value on SQLite now sees the error PostgreSQL
raises.

### Migrate your app

```julia
# ✗ before — on SQLite driver 100 read as 100; on PostgreSQL the query raised
M.Driver.objects.values("driverid", "x" => Cast("driverid", "numeric(2,0)"))
# now it raises on both engines, on the rows from driver 100:
try
    M.Driver.objects.values("driverid", "x" => Cast("driverid", "numeric(2,0)")) |> DataFrame
catch e
    e isa StatementError && e.sqlstate == "22003" || rethrow()
    # numeric field overflow, on PostgreSQL and SQLite alike
end

# ✓ after — a precision that holds the values
M.Driver.objects.values("driverid", "x" => Cast("driverid", "numeric(4,0)"))
```
