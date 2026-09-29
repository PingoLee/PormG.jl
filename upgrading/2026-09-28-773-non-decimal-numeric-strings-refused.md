## Numeric strings — a `0x` / `0b` / `0o` prefix raises instead of being bound as text (#773)

- **Version**: 0.7.0
- **Recorded**: 2026-09-28
- **PormG ref**: #773; `src/Models.jl` (`format_number_sql`, `is_base10_number`), `src/querybuilder/sanitization.jl` (`_validate_integer_value`, `_validate_float_value`), `src/querybuilder/build_helpers.jl` (`_json_numeric_rhs`), `src/querybuilder/execution_bulk.jl` (the bulk refusal now carries the reason)
- **Severity**: behavior change — a string that was accepted and bound as raw text now raises before any SQL

### What changed

A numeric field (`IntegerField`, `BigIntegerField`, `FloatField`, `DecimalField`, and the integer
keys) takes its value as a string too. PormG checked that string with Julia's parsers, which also
read `0x`, `0b` and `0o` prefixes (`"0x10"` is 16) and hexadecimal floats (`"0x1p4"`), but it
bound the **original text**. So `"0x10"` passed validation as 16 and reached the database as the
string `'0x10'`:

| Path | Before | After |
|---|---|---|
| writes — `create`, `update`, `get_or_create`, `update_or_create`, `bulk_insert`, `bulk_update`, `bulk_copy` | SQLite stored a TEXT cell in the numeric column; PostgreSQL refused the text, or may parse it on a server that reads non-decimal integers | `InvalidValueError`, before any SQL, naming the prefix |
| a filter on a numeric field — `filter("laps" => "0x10")` | the text was bound and compared | `FilterError` |
| a JSON numeric comparison — `filter("payload__laps__@gte" => "0x10")` | coerced to `16` | `FilterError` |

Base-10 strings are unchanged: an optional sign, digits, at most one `.`, an optional exponent
(`"44"`, `"-3"`, `"12.50"`, `".5e3"`). Django's `int(str)` and `Decimal(str)` accept no prefix
either; PormG does not convert the string for you.

The same grammar also refuses a space between the sign and the digits (`"+ 1"`), which Julia's
integer parser accepted and the text then reached the database as written.

### How to find the calls to migrate

The prefixed spelling usually arrives in **data**, not in source, so a grep finds only the
literals. Look for them first:

```bash
grep -rnE '"[+-]?0[xXbBoO][0-9A-Fa-f]' --include=*.jl .
```

Then check the inputs that feed numeric fields as strings — CSV and spreadsheet imports, form
values, a DataFrame column read as `String` — for values starting with `0x`, `0b` or `0o`. On SQLite,
rows already written this way hold TEXT in a numeric column.

### Migrate your app

```julia
# ✗ before — accepted; the cell got the text '0x10'
M.Lap_times.objects.create("raceid" => 18, "driverid" => 1, "lap" => "0x10", "position" => 1,
    "time" => Dates.Millisecond(98109), "milliseconds" => 98109)

# ✓ after — convert the value before the write
M.Lap_times.objects.create("raceid" => 18, "driverid" => 1, "lap" => parse(Int, "0x10"), "position" => 1,
    "time" => Dates.Millisecond(98109), "milliseconds" => 98109)
```
