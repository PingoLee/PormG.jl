## A string value containing a NUL character raises (#951)

- **Version**: Unreleased
- **PormG ref**: #951 ; `src/ConnectionPool.jl` (`_refuse_nul`), `src/querybuilder/sanitization.jl` (`_format_single`), `src/AdvisoryLock.jl` (`_refuse_nul_key`)
- **Recorded**: 2026-10-05
- **Severity**: breaking (narrow). A string with an embedded NUL (`'\0'`) used to reach the driver, and each driver handled it differently, none correctly. It now raises `InvalidValueError` before any statement is sent, on every backend.

### What changed

PostgreSQL `text` cannot hold a NUL character, and the three drivers disagreed about what to do
with one:

| value containing `'\0'` | LibPQ before | Postgres.jl before | SQLite before | after, every backend |
|---|---|---|---|---|
| filter value (`filter("surname" => "Senna\0x")`) | **silently cut** at the NUL: matched `"Senna"` | `StatementError` (SQLSTATE 22021) | `=` compared every byte; a `LIKE` lookup (`@contains`, `@icontains`, `@startswith`, …) **silently cut** the pattern (`@icontains` on `"Senna\0x"` matched `"Ayrton Senna"`) | raises `InvalidValueError` |
| write value (`create`, `update`, `bulk_insert`, `bulk_update`, `bulk_copy`) | **silently cut**: stored `"Senna"` | `StatementError` | stored every byte, read back cut short | raises `InvalidValueError`, naming the field (and the row, for a bulk write) |
| raw `fetch(…, params = [...])` value | silently cut | `StatementError` | bound every byte (a `LIKE` pattern cut at the NUL) | raises `InvalidValueError` |
| a NUL in the SQL text itself (a raw statement, or a value rendered inline such as a `ToChar` format) | `StatementError` whose message quoted the whole statement | `StatementError` (the driver fails internally) | prepare stopped at the NUL: a syntax error, or the rest of the text dropped silently | raises `InvalidValueError`, quoting nothing |
| `with_advisory_lock` key | locked on the text before the NUL — another key's lock | `StatementError` | ignored (no-op) | raises `InvalidValueError` |

The message names the parameter position or the field, never the value. Binary values
(`BinaryField`, `Vector{UInt8}`) are not affected: a NUL byte is valid data there and still
round-trips. A `JSONField` value is not affected either: JSON escapes a NUL as `\u0000`, so no NUL
character reaches the driver. PostgreSQL `jsonb` refuses that escape on its own, which #954 handles
in its own entry: *A NUL in a JSONField value raises*.

### Who this affects

Apps that pass client input with a NUL in it, most often a web route whose query string carries
`%00`. On LibPQ — and on SQLite for a `LIKE` lookup — that input used to run silently against a
different value; on Postgres.jl it was already an error, now a typed one. The value is runtime input, so a grep cannot find every call site.

### How to find the calls to migrate

Run the app's tests and look for this message:

```
contains a NUL character (\0). PostgreSQL text cannot store one and SQLite cannot read it back past it
```

Then check where request input reaches a filter or a write without validation.

### Migrate your app

Decide at the input boundary what a NUL means, and either reject the request (a 400) or strip it.

```julia
# A driver search route: `q` comes straight from the query string.

# ✗ before: "Senna\0x" matched "Senna" on LibPQ, a 500 on Postgres.jl
M.Driver.objects.filter("surname__@icontains" => q).list()

# ✓ after: reject it as bad input…
occursin('\0', q) && return bad_request("invalid search text")
M.Driver.objects.filter("surname__@icontains" => q).list()

# ✓ …or catch the refusal where the request is handled
try
    M.Driver.objects.filter("surname__@icontains" => q).list()
catch e
    e isa PormG.InvalidValueError ? bad_request(e.msg) : rethrow()
end
```
