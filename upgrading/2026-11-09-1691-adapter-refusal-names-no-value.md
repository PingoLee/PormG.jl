## `load` refuses an unknown `adapter:` without printing it (#1691)

- **Version**: Unreleased
- **PormG ref**: #1691 ; `src/Configuration.jl`, `src/Generator.jl`
- **Recorded**: 2026-11-09
- **Severity**: behavior change, for code that matches the text of these configuration refusals.
  Every refusal still raises `InvalidConfigurationError` where it did before.

### What changed

`load`'s refusal of an unknown `adapter:` printed the value it read. A connection URL written under
`adapter:` (a misplaced line, or `url:` pasted one key too high) put its password in the message. The
refusal now names the environment and the file, and lists the accepted adapters, as
`register_connection`'s did from 0.10.0 (#1685). A few refusals of other configured values stopped
printing them too:

| refusal | before | now |
|---|---|---|
| `load`, an unknown `adapter:` | `Unsupported adapter: <value>` | ``environment "dev" in <folder>/connection.yml: unsupported `adapter`; expected "PostgreSQL", "SQLite" or "MySQL".`` |
| the same refusal for settings built without `load` (`_build_connection_pool!`) | `Unsupported adapter: <value>` | ``environment "dev" (folder <folder>): unsupported `adapter`; expected …`` |
| `postgres_driver:` or `PORMG_POSTGRES_DRIVER` that names no driver | ``…must be one of LibPQ or Postgres (case-insensitive); got "<value>"`` | ``…must be one of LibPQ or Postgres (case-insensitive).`` |
| an `ignore_tables:` / `unignore_defaults:` entry that is not a string | `…, got 2024` | `…, got a value of type Int64` |
| `register_offline` with an unknown `adapter` | ``…must be :postgres or :sqlite, got :mysql.`` | ``…must be :postgres or :sqlite.`` |
| `create_db_folder_and_yml` with `postgres_driver` on another adapter | `…remove it for adapter = "SQLite".` | `…remove it for a non-PostgreSQL adapter.` |

### How to find the calls to migrate

```
grep -rnE "Unsupported adapter|case-insensitive\); got|:postgres or :sqlite, got|remove it for adapter" --include=*.jl .
```

### Migrate your app

```julia
# ✗ before
@test occursin("Unsupported adapter", sprint(showerror, err))

# ✓ after: match the type, or the new text
@test err isa PormG.InvalidConfigurationError
@test occursin("unsupported `adapter`", sprint(showerror, err))
```
