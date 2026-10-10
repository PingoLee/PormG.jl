## A NUL in a JSONField value raises (#954)

- **Version**: Unreleased
- **PormG ref**: #954 ; `src/Models.jl` (`format_json_sql`, `_json_has_nul_escape`), `src/querybuilder/sanitization.jl` (`_format_json_named`), `src/querybuilder/execution_bulk.jl` (`_depuration_values_bulk_insert`)
- **Recorded**: 2026-10-05
- **Severity**: breaking (narrow). A `JSONField` value containing a NUL character (`'\0'`) used to fail on PostgreSQL's server and be stored on SQLite. It now raises `InvalidValueError` before any statement is sent, on every backend.

### What changed

JSON writes a NUL as the escape `\u0000`, so the #951 check for text never sees one. PostgreSQL
`jsonb` cannot store that escape (SQLSTATE 22P05, *unsupported Unicode escape sequence*), so the
statement failed on the server; SQLite stored the escape and read it back.

| `JSONField` value containing `'\0'` (or a JSON string carrying `\u0000`) | PostgreSQL before (LibPQ and Postgres.jl) | SQLite before | after, every backend |
|---|---|---|---|
| write (`create`, `update`, `bulk_insert`, `bulk_update`, `bulk_copy`) | `StatementError` | stored, escape included | raises `InvalidValueError`, naming the field (and the row, for a bulk write) |
| `get_or_create` / `update_or_create` lookup on the document | `StatementError` | matched or created by the escaped text | raises `InvalidValueError`, naming the field |
| `@jcontains` filter | `StatementError` | not supported on SQLite (`BackendCapabilityError`, unchanged) | raises `InvalidValueError` |
| plain filter on a JSON string (`filter("telemetry" => "{…\\u0000…}")`) | `StatementError` | matched by the escaped text | raises `InvalidValueError`, naming the field |
| `JSONField(default = …)` | accepted when the model was defined | accepted | raises `FieldValidationError` when the model is defined |

Introspection (`generate_models_from_db`, `inspectdb`) reads a column default through the same check,
so an existing SQLite JSON column whose default holds the escape is now generated without that
default, with a warning, rather than with it.

The message never contains the value. The NUL is found in the serialized document, so a key, a nested
element and a value JSON.jl lowers from a struct are all covered. The six-character text `\u0000` —
a backslash followed by `u0000`, which JSON writes as `\\u0000` — is not a NUL and is still stored as
written.

### Who this affects

Apps that store client-supplied JSON in a `JSONField`. On PostgreSQL that input was already an error,
now a typed one raised before the round trip. On SQLite it used to be stored: a dev database built
on SQLite accepted a document that the production PostgreSQL database rejected, and now both refuse
it. The value is runtime input, so a grep cannot find every call site.

### How to find the calls to migrate

Run the app's tests and look for this message:

```
contains a NUL character (\0, written \u0000 in JSON). PostgreSQL jsonb cannot store one
```

Then check where request input reaches a `JSONField` without validation. Existing SQLite rows that
already hold the escape are not touched; find them with `WHERE <column> LIKE '%\u0000%'` and check
each match, since that pattern also matches the escaped-backslash text.

### Migrate your app

Decide at the input boundary what a NUL means, and either reject the request (a 400) or strip it
before the document reaches PormG.

```julia
# A pit-stop telemetry route, on an app's `Pit_stops` model carrying `telemetry = Models.JSONField()`.
# `note` comes straight from the request body.

# ✗ before: a 500 on PostgreSQL, stored on SQLite
M.Pit_stops.objects.create("raceid" => race, "driverid" => driver, "stop" => 1,
                           "telemetry" => Dict("note" => note))

# ✓ after: strip the NUL…
M.Pit_stops.objects.create("raceid" => race, "driverid" => driver, "stop" => 1,
                           "telemetry" => Dict("note" => replace(note, '\0' => "")))

# ✓ …or catch the refusal where the request is handled
try
    M.Pit_stops.objects.create("raceid" => race, "driverid" => driver, "stop" => 1,
                               "telemetry" => Dict("note" => note))
catch e
    e isa PormG.InvalidValueError ? bad_request(e.msg) : rethrow()
end
```
