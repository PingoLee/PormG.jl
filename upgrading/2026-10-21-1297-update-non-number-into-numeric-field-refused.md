## `update` of a non-number expression into a number field is refused on every engine (#1297)

- **Version**: 0.9.0
- **PormG ref**: #1297 ; `src/querybuilder/execution_write.jl` (`_refuse_update_non_number`), which types the operand with the expression-kind walk (`_expression_kind`)
- **Recorded**: 2026-10-21
- **Severity**: breaking. `update(field => <expression>)` into a number field (`IntegerField`, `BigIntegerField`, `PositiveIntegerField`, `PositiveSmallIntegerField`, `FloatField`, `DecimalField`, or a `ForeignKey` to an integer key) raises `QueryBuildError` before any SQL when the expression is a UUID, a date, a timestamp, a time, an interval, binary data, a network address or a full-text document. On SQLite it used to store the value's text, or a blob's bytes. On PostgreSQL it used to fail at execute with a `StatementError`.

### What changed

`update("points" => F("token"))` rendered `SET "points" = "Tb"."token"` with no type check. None of
these types is a number:

| `update("points" => F("token"))`, `points` a `DecimalField`, `token` a `UUIDField` | before | after |
|---|---|---|
| PostgreSQL | `StatementError` when the statement ran (no assignment cast from `uuid` to `numeric`) | `QueryBuildError` at build, `show_query` too |
| SQLite | stored the UUID's text in the NUMERIC column | `QueryBuildError` at build |

No engine gives the call a meaning, so PormG refuses it on every engine. The message names the
operand, its type and the field. It names no `Cast`, because PostgreSQL has none from these types to a
number.

Unchanged: a boolean operand (`true` is `1` on SQLite, a separate question); a text or JSON operand,
which the #1279 entry covers for a `DecimalField` and which a `FloatField` or an `IntegerField` still
takes; a literal value, which the field's validator checks as before; and any operand written into a
field of another type, such as a UUID into a `UUIDField` or a `CharField`.

### Who this affects

Code that updates a number field from a column or function of one of these types. On PostgreSQL such
a call already failed, so only the error type changes: a `catch StatementError` or
`catch DatabaseError` around it no longer matches, while a `catch UsageError` now does. On SQLite the
call used to write text into the number column, so the stored rows may need repair too. A
timestamp difference written into a milliseconds column is the shape most likely to be found.

### How to find the calls to migrate

```bash
grep -rnE '\.update\(' --include=*.jl src/ test/
```

Keep each hit that writes into a number field an `F(...)` of a `UUIDField`, `DateField`,
`DateTimeField`, `TimeField`, `DurationField` or `BinaryField`, a function over one, a `Cast` to such a
type, or arithmetic that keeps the type: `F("dob") + 1` is a date, and the difference of two
`DateTimeField`s is an interval, so writing it into a milliseconds column is refused too. Running
the call on either engine is the definitive check: the refusal names the field and #1297.

On SQLite, rows written this way hold text, or a blob, in a number column. They can be found with
`typeof(<column>) IN ('text', 'blob')` in the SQLite shell.

### Migrate your app

```julia
# ✗ before — SQLite stored the date's text in `number`; PostgreSQL failed at execute
M.Driver.objects.filter("driverid" => 1).update("number" => F("dob"))
# ✓ after — write a number: here, the year of the date
M.Driver.objects.filter("driverid" => 1).update("number" => Extract(F("dob"), "year"))
```
