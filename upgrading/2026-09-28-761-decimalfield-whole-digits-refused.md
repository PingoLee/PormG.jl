## `DecimalField` writes — a value with too many digits before the point raises `InvalidValueError` (#761)

- **Version**: 0.7.0
- **Recorded**: 2026-09-28
- **PormG ref**: #761; `src/querybuilder/sanitization.jl` (`_decimal_digit_counts`, `_validate_field_value` step 9)
- **Severity**: behavior change — a write SQLite used to store is refused, and on PostgreSQL the refusal changes type from `StatementError` to `InvalidValueError`

### What changed

A `DecimalField(max_digits = p, decimal_places = s)` column holds at most `p - s` digits before the
decimal point. Write validation checked only the total (`p`) and the fractional digits (`s`), so a
`DecimalField(max_digits = 5, decimal_places = 2)` let `1234.5` through: 5 digits in total and 1
fractional both fit. The engines then disagreed:

| Engine | Before | After |
|---|---|---|
| PostgreSQL | the statement ran and failed: `StatementError` (a `DatabaseError`) wrapping the server's `numeric field overflow` | `InvalidValueError`, before any SQL |
| SQLite | the row was stored; since #648 that cell read back as a raw `Int64`/`Float64` | `InvalidValueError`, before any SQL |

Every writer checks it: `create`, `update`, `get_or_create`, `update_or_create`, `bulk_insert`,
`bulk_update` and `bulk_copy`. This is the third bound of Django's `DecimalValidator`, which PormG was
missing. The message reads `max_digits - decimal_places is 3, so at most 3 digits fit before the
decimal point, but the normalized numeric value uses 4`.

The same fix stops counting the integer part's **leading zeros** as digits, which only accepts more:
`0.55` now fits `DecimalField(max_digits = 2, decimal_places = 2)`, as it does in PostgreSQL's
`numeric(2, 2)`, and it no longer raises `max_digits is 2, but … uses 3 digits`.

### How to find the calls to migrate

On PostgreSQL, look for code that handles the overflow as a database error. It now arrives as
`InvalidValueError` (a `PormGError`, but not a `DatabaseError`), so a `catch` narrowed to
`StatementError` / `DatabaseError` no longer sees it:

```bash
grep -rniE 'numeric field overflow|NumericValueOutOfRange|StatementError|DatabaseError' --include=*.jl .
```

On SQLite, look for rows already stored too wide. They read back as a raw `Int64`/`Float64` where
their neighbours read as `Decimal`. A write that now raises means a value wider than the column was
being stored; widen the field or fix the value. List the declarations with:

```bash
grep -rnE 'DecimalField\(' --include=*.jl .
```

### Migrate your app

```julia
# ✗ before — PostgreSQL: a StatementError after the round trip; SQLite: nothing raised, the row is stored
try
    M.Constructor_results.objects.create("raceid" => 18, "constructorid" => 1, "points" => 123456789)
catch e
    e isa StatementError && occursin("numeric field overflow", sprint(showerror, e)) || rethrow()
    # handle overflow
end

# ✓ after — both engines raise the same PormG type, before any SQL
try
    M.Constructor_results.objects.create("raceid" => 18, "constructorid" => 1, "points" => 123456789)
catch e
    e isa InvalidValueError || rethrow()
    # handle overflow
end
```
