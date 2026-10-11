## `db_default` and `CheckConstraint` SQL text refuses quoting only one engine can read (#934)

- **Version**: Unreleased
- **PormG ref**: #934 ; `src/column_ir.jl` (`is_valid_db_default_sql`)
- **Recorded**: 2026-10-11
- **Severity**: behavior change. A model declaration that loaded now raises when the models file is
  loaded: `FieldValidationError` for a `db_default`, `ModelDefinitionError` for a `CheckConstraint`.

### What changed

The check that guards SQL text in a declaration — a field's `db_default` and a `CheckConstraint`'s
condition — understood only `'…'` and `"…"`. PostgreSQL and SQLite disagree about where some other
spellings end, so text the check took for one literal could be several statements to the server
(`x = E'\'' ; DROP TABLE result ; SELECT E'\''`). It now refuses those spellings instead of lexing
them:

| SQL text in `db_default` or a CHECK condition | before | after |
|---|---|---|
| an `E'…'` escape string | accepted | refused |
| a backslash right before a quote inside a literal (`'it\'s'`) | accepted | refused |
| a dollar quote (`$$…$$`, `$tag$…$tag$`) | accepted | refused |
| a backtick | accepted | refused |
| a `,` inside a SQLite `[…]` identifier | accepted | refused |
| a backslash elsewhere, e.g. a regex CHECK `code ~ '^\d{3}$'` | accepted | accepted, unchanged |

PostgreSQL never prints `E''` or a dollar quote when it reads a default or a CHECK back, so text
`inspectdb` writes is unaffected. Known false refusals: a literal that ends in a backslash, a quote
or `]` in a literal inside brackets, and a two-dimensional array literal.

### Who this affects

Models that declare a `db_default` or a `CheckConstraint` (or an `Index(expressions = …, condition
= …)`) whose SQL text uses one of the refused spellings.

### How to find the calls to migrate

```bash
grep -rnE 'db_default|CheckConstraint|condition *=|expressions *=' --include=*.jl . | grep -E "E'|\\\\'|[$]|\`"
```

Loading the models file is the definitive check: the refusal names the field or constraint.

### Migrate your app

```julia
# ✗ before — a backslash-escaped quote: one literal to PostgreSQL with standard_conforming_strings
#   off, a literal plus trailing text with it on
Models.CheckConstraint(name = "code_set", condition = "code <> 'it\\'s'")

# ✓ after — the standard spelling: a quote inside a literal is doubled
Models.CheckConstraint(name = "code_set", condition = "code <> 'it''s'")
```
