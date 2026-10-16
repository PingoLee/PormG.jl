## `update` of an expression into a scaled `DecimalField` is refused on SQLite when it can carry more places than the field (#1279)

- **Version**: Unreleased
- **PormG ref**: #1279 ; `src/querybuilder/execution_write.jl` (`_refuse_update_scale_departure`), which reuses the #1040 classifier `_scale_divergent_operand` and the `:scale` row of `_MEANING_DEPARTURES`
- **Recorded**: 2026-10-16
- **Severity**: breaking, on SQLite. `update(field => <expression>)` into a `DecimalField(max_digits, decimal_places)` raises `QueryBuildError` there, before any SQL, when the expression can carry more than `decimal_places` fractional digits. It used to write every digit. PostgreSQL builds it as before, and its column rounds the value.

### What changed

A `DecimalField(max_digits = 10, decimal_places = 2)` column is `numeric(10, 2)` on both engines, and
assigning a value to it means the value rounded to 2 places. PostgreSQL's column rounds it. SQLite's
column has NUMERIC affinity: it stores the double its arithmetic produced, every digit of it, and the
read path returns such a cell as a `Float64` rather than a `Decimal`. A later filter then matches
different rows on each engine. A literal was already refused on every engine when it had too many
places (#761); an expression was not checked. Measured through `update` on PostgreSQL 16 and SQLite
3.54:

| `update("price" => …)` | from | PostgreSQL reads | SQLite read, before |
|---|---|---|---|
| `F("price") * 1.005` | `1.00` | `Decimal` `1.01` | `Float64` `1.005` |
| `F("price") / 3` | `1.00` | `Decimal` `0.33` | `Float64` `0.3333333333333333` |
| `F("price") + 0.20` | `0.10` | `Decimal` `0.3` | `Float64` `0.30000000000000004` |
| `Round(F("price") / 3, 2)` | `1.00` | `Decimal` `0.33` | `Decimal` `0.33` |

So SQLite now refuses the expression, and the message names the field and the spelling that stores
the same value on every engine: `Round(x, decimal_places)`, or `Round(Cast(x, FloatField()),
decimal_places)` over text, which #1061 does not round until it is cast to a number. The rule is the one a `Cast` to
`numeric(p, s)` follows (#1040). Refused: arithmetic over a `DecimalField` (with an integer too,
since SQLite computes in doubles), a float or text column, a float literal with more places than the
field, a `numeric` function, a `DecimalField` with more places, and a `Case` over any of them.
`F("price") * 2` is refused as well, although doubling happens to be exact.

Unchanged: a literal value (the #761 width check, on every engine); a `FloatField`, an
`IntegerField` or a text column, whatever expression it takes; and an expression with at most the
field's places: the column itself, an integer column, `Round(x, d)` with `d` at most the field's
places, a narrower `DecimalField`, and `Coalesce`/`Greatest`/`Least` of one.

### Who this affects

Code that updates a `DecimalField` with an `F` expression or a SQL function and runs on SQLite, such
as a test suite on SQLite for an app that runs on PostgreSQL.

### How to find the calls to migrate

```bash
grep -rnE '=> *([A-Za-z_]+\.)*(F|Round|Coalesce|Case|Cast|Greatest|Least|Abs|Sqrt|Power|Floor|Ceil|Exp|Ln|Mod)\(' --include=*.jl src/ test/
```

It matches qualified calls (`Fn.Round(`, `PormG.F(`) and a pair on its own line. Keep each hit that
is a value passed to `update` for a `DecimalField`. Running it on SQLite is the definitive check: the
refusal names the field, SQLite and #1279.

### Migrate your app

```julia
# ✗ before — PostgreSQL stored 0.33, SQLite stored 0.3333333333333333; now refused on SQLite
M.Constructor_results.objects.filter("constructorresultsid" => 1).update("points" => F("points") / 3)
# ✓ after — round to the field's places, which stores the same Decimal on every engine
M.Constructor_results.objects.filter("constructorresultsid" => 1).update("points" => Round(F("points") / 3, 2))

# ✗ before — an increment kept SQLite's double digits (0.10 + 0.20 stored 0.30000000000000004)
M.Constructor_results.objects.filter("constructorresultsid" => 1).update("points" => F("points") + 0.2)
# ✓ after
M.Constructor_results.objects.filter("constructorresultsid" => 1).update("points" => Round(F("points") + 0.2, 2))
```

`Round(x, d)` renders each engine's own `ROUND` (#1061). Only a decimal tie can come out differently,
in its last digit (`2.675` gives `2.68` on PostgreSQL and `2.67` on SQLite), which is documented
rather than refused.
