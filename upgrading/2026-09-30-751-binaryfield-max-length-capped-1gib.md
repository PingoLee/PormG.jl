## `BinaryField(max_length = …)` is capped at 1 GiB (#751)

- **Version**: Unreleased
- **Recorded**: 2026-09-30
- **PormG ref**: #751; `src/models/fields.jl` (`BinaryField`, `BINARY_FIELD_MAX_BYTES`), `src/migrations/introspection.jl` (`_reader_checks`)
- **Severity**: behavior change. A `max_length` above 1 GiB that used to construct a field now raises

### What changed

`BinaryField` only required `max_length > 0`, so any bound was accepted. Above `2147483647`,
PostgreSQL parses the bound in `CHECK (octet_length(col) <= n)` as a `bigint` literal and
`pg_get_constraintdef` returns it as `<= '3000000000'::bigint`. The reader never matched that form,
so the declared bound always looked missing, and every `makemigrations` added the same CHECK again.

A `bytea` value is at most 1 GiB, so a bound above that constrains nothing. `BinaryField` now
refuses one:

- `max_length` above `1073741824` (1 GiB) raises `FieldValidationError`.
  `max_length = 1073741824` is still accepted, and `max_length = nothing` still means no limit.
- The live-schema readers on **both** engines leave a byte-length CHECK above 1 GiB **unread**.
  `makemigrations` and `generate_models_from_db` treat such a column as an unbounded
  `BinaryField()` and plan nothing against one. A CHECK created before this change stays in the
  database untouched, and still constrains nothing.

### How to find the calls to migrate

```bash
# -A3 also catches a constructor whose keywords continue on the next lines
grep -rn -A3 'BinaryField(' --include=*.jl . | grep 'max_length'
```

Any `max_length` above `1073741824`, including one written with `_` separators or as a string,
refuses at model load with:

```
The 'max_length' of a BinaryField cannot exceed 1073741824 bytes (1 GiB, PostgreSQL's limit for one bytea value), got 3000000000; …
```

### Migrate your app

```julia
# ✗ before: accepted, and on PostgreSQL re-planned on every makemigrations
payload = Models.BinaryField(max_length = 3_000_000_000)

# ✓ after: no bound (the value is already limited to 1 GiB by the database)
payload = Models.BinaryField()

# ✓ after: or a real bound, at most 1 GiB
payload = Models.BinaryField(max_length = 500_000_000)
```

Switching to `BinaryField()` plans nothing: the old CHECK is left unread and stays in place. To
remove it, drop the constraint by hand.
