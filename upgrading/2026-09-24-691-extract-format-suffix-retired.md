## `Extract` — the 3-arg `format` suffix is removed, and an unknown part raises `InvalidValueError` (#691)

- **Version**: Unreleased
- **Recorded**: 2026-09-24
- **PormG ref**: #691; `src/Dialect.jl` (`PG_EXTRACT_FIELDS`, `extract_part`, `EXTRACT`), `src/querybuilder/functions.jl` (`Extract`)
- **Severity**: breaking — one arity removed, and a string that is not a date/time field now raises when the expression is built

### What changed

On PostgreSQL, `Extract(x, part)` wrote `part` into the SQL as written, and
`Extract(x, part, format)` appended `format` as a raw cast suffix. An app that built either one
from request input could inject SQL, on PostgreSQL only. SQLite already refused unknown parts.

1. **`part` must be a PostgreSQL `EXTRACT` field**, in any case: `CENTURY`, `DAY`, `DECADE`, `DOW`,
   `DOY`, `EPOCH`, `HOUR`, `ISODOW`, `ISOYEAR`, `JULIAN`, `MICROSECONDS`, `MILLENNIUM`,
   `MILLISECONDS`, `MINUTE`, `MONTH`, `QUARTER`, `SECOND`, `TIMEZONE`, `TIMEZONE_HOUR`,
   `TIMEZONE_MINUTE`, `WEEK`, `YEAR`. Anything else raises `InvalidValueError` from `Extract(...)`
   itself, on both engines. That includes PostgreSQL's plural and abbreviated synonyms (`years`,
   `mon`, `hr`, `msec`, …), which PostgreSQL used to run: spell the canonical field instead. Any
   other string used to fail at execution with a driver error on PostgreSQL, and with
   `BackendCapabilityError` on SQLite. A real field SQLite cannot compute (`WEEK`, `EPOCH`, …) still
   raises `BackendCapabilityError` there.
2. **PostgreSQL renders the field in upper case** (`EXTRACT(YEAR FROM …)` for `Extract(x, "year")`).
   The value is unchanged. Only the generated SQL text differs.
3. **`Extract(x, part, format)` is gone.** Calling it is a `MethodError`. Use `Cast` to change the
   result type.

Measured before the change: 0 `Extract(` calls of any arity in the five consuming apps.

### How to find the calls to migrate

```bash
grep -rn 'Extract(' --include=*.jl .
```

For each hit, check two things: whether it passes a third positional argument, and whether its
`part` is a variable or a synonym (`years`, `hr`) rather than a canonical field. A leftover 3-arg
call fails loudly with `MethodError`.

### Migrate your app

```julia
# Before: the suffix was pasted after EXTRACT(...) unchecked
M.Race.objects.values("t" => Extract("date", "epoch", "::bigint"))

# After: Cast renders the same (EXTRACT(EPOCH FROM …))::bigint
M.Race.objects.values("t" => Cast(Extract("date", "epoch"), "bigint"))
```

```julia
# Before: an unknown part reached PostgreSQL and failed there
Extract("date", "fortnight")

# After: raises InvalidValueError when built, naming the valid fields
```
