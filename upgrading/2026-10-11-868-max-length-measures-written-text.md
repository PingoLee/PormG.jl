## A text field's `max_length` also measures an integer or a date written into it (#868)

- **Version**: 0.8.0
- **PormG ref**: #868 ; `src/querybuilder/value_validation.jl` (`_validate_field_value`)
- **Recorded**: 2026-10-11
- **Severity**: behavior change. A write that SQLite stored, and PostgreSQL refused at the server (a
  `StatementError`, a `DatabaseError`), now raises `InvalidValueError` before any statement is sent,
  on both engines.

### What changed

A `CharField` (or any text field with `max_length`) checked the length only of a `String`. PormG
also writes an integer, a `Date`, a `DateTime`, a `ZonedDateTime` or a `Time` into a text field as
its text, and that text was never measured:

| Write to `code = CharField(max_length = 3)` | before | after |
|---|---|---|
| `"code" => 12345` | SQLite stored `"12345"`; PostgreSQL's server refused it (`StatementError`) | `InvalidValueError`, naming the text it measured |
| `"code" => Date(2020, 1, 1)` | the same | `InvalidValueError` |
| `"code" => 123` / `"code" => "HAM"` | stored | stored, unchanged |

It applies to `create`, `update`, `update_or_create`, `get_or_create` and the three bulk writers. A
`Bool` and a field with its own `formatter` are not measured.

### Who this affects

Code that writes numbers or dates into a length-limited text column without converting them, and
in particular SQLite data that already holds an over-length value written that way: re-writing the
same value now raises.

### How to find the calls to migrate

There is no pattern that finds the value at the call; run the write paths' tests on SQLite, or check
the data:

```bash
grep -rnE 'max_length *=' --include=*.jl .
```

For each such text field (`CharField`, `SlugField`, `URLField`, …), look for writes whose value can
be an integer or a date.

### Migrate your app

```julia
# With code = Models.CharField(max_length = 3):

# ✗ before — SQLite stored "12345" in a three-character column
M.Driver.objects.filter("driverid" => 1).update("code" => 12345)

# ✓ after — write a value that fits, or widen the column
M.Driver.objects.filter("driverid" => 1).update("code" => "HAM")
```
