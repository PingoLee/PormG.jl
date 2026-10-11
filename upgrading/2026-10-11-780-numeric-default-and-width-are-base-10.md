## A numeric `default=` or width keyword given as a string is read in base 10, like a value (#780)

- **Version**: Unreleased
- **PormG ref**: #780 ; `src/Models.jl` (`format2int64`, `format2float64`), `src/models/fields.jl` (`_int_kwarg`)
- **Recorded**: 2026-10-11
- **Severity**: behavior change. A field declaration that loaded now raises `FieldValidationError`
  when the models file is loaded; a PostgreSQL `DEFAULT 'Infinity'` is introspected as no default.

### What changed

A numeric value written to a column has been read in base 10 since the `0.7.0` train, refusing
`"0x10"`. The same string given at declaration time still went through Julia's bare `parse`:

| Declaration | before | after |
|---|---|---|
| `IntegerField(default = "0x10")`, `FloatField(default = "0x1p4")` | default `16` / `16.0` | `FieldValidationError` ("Invalid default value …") |
| `CharField(max_length = "0x10")` (and `max_digits`, `decimal_places`) | a 16-character column | `FieldValidationError` naming the prefix ("must be written in base 10") |
| `IntegerField(default = "+ 1")` (a space after the sign) | default `1` | `FieldValidationError` |
| `FloatField(default = "Inf")` / `"NaN"` | an infinite / NaN default | `FieldValidationError`, as `default = Inf` already was |
| `IntegerField(default = "16")`, `FloatField(default = "1.5")` | accepted | accepted, unchanged |

Introspection (`inspectdb`, the live read under `makemigrations`) coerces a live default through the
same converters and drops one it refuses, with a warning — so a PostgreSQL float column with
`DEFAULT 'Infinity'` now reads as having no default.

### Who this affects

Models files that give a numeric `default=` or a width keyword as a **string** with a base prefix,
a space after the sign, or a non-finite float. A number literal (`default = 16`) is unaffected.

### How to find the calls to migrate

```bash
grep -rnE '(default|max_length|max_digits|decimal_places) *= *"[+-]? *(0[xXoObB]|[Ii]nf|NaN)' --include=*.jl .
grep -rnE '(default|max_length|max_digits|decimal_places) *= *"[+-] ' --include=*.jl .
```

### Migrate your app

```julia
# ✗ before — "0x10" meant 16
laps = Models.IntegerField(default = "0x10")

# ✓ after — write the number
laps = Models.IntegerField(default = 16)
```
