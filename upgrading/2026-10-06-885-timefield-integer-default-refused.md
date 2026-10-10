## `TimeField(default = …)` refuses a `Bool` or a bare number (#885)

- **Version**: Unreleased
- **PormG ref**: #885 ; `src/models/fields.jl` (`TimeField`)
- **Recorded**: 2026-10-06
- **Severity**: breaking (narrow). A `Bool` or a number `default` on a `TimeField` used to construct, read as an hour. It now raises `FieldValidationError` when the model is defined.

### What changed

`TimeField` converted its `default` with `Dates.Time(x)`, which takes any real number as the
**hour**, and `Bool` is an integer in Julia:

| declaration | default before | after |
|---|---|---|
| `TimeField(default = 5)` | `05:00:00` | raises `FieldValidationError` |
| `TimeField(default = true)` | `01:00:00` | raises `FieldValidationError` |
| `TimeField(default = false)` | `00:00:00` | raises `FieldValidationError` |
| `TimeField(default = 5.0)` | `05:00:00` | raises `FieldValidationError` |

`5` could as well have meant 5 seconds or 5 minutes, and `true` on a time column is almost certainly
a mistake, so PormG now asks for the time you mean. `Time(…)`, an `HH:MM:SS` string, a `DateTime`
and a period with a named unit (`Hour(5)`, `Minute(30)`) behave exactly as before. `DateField`,
`DateTimeField` and `DurationField` already refused a number default.

### Who this affects

Model files that give a `TimeField` a number or `Bool` default. `inspectdb` never produced a
numeric `TimeField` default, so generated model files are not affected.

### How to find the calls to migrate

```bash
grep -rnE 'TimeField\([^)]*default *= *[0-9tf]' --include='*.jl' <your-app>
```

Or define the models: every remaining declaration raises with this message:

```
TimeField: 'default' must be a Dates.Time or an ISO time string such as "00:01:30"
```

### Migrate your app

Write the time the number stood for, with its unit.

```julia
# A pit-stop window opening at 5 a.m. on a team's garage schedule.

# ✗ before: a number read as the hour
start_time = Models.TimeField(default = 5)

# ✓ after: the same value, spelled explicitly
start_time = Models.TimeField(default = Time(5))      # or "05:00:00", or Hour(5)
```
