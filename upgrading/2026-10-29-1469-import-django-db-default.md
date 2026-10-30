## `import_models_from_django` translates Django's `db_default` instead of copying it (#1469)

- **Version**: Unreleased
- **PormG ref**: #1469 ; `src/migrations/importers.jl` (`_translate_django_db_default!`), `src/models/fields.jl` (`_db_default_kwarg`)
- **Recorded**: 2026-10-29
- **Severity**: behavior change. A Django `db_default` written as a string is now text, never SQL: `db_default="CURRENT_DATE"` generates `default="CURRENT_DATE"` on a text field and no default on a date or datetime field, where it used to generate the SQL function. Imports that used to stop on a `db_default` now finish.

### What changed

Django's `db_default` takes a literal, which Django wraps in `Value()`, or an expression. PormG's
`db_default` takes only an expression, and a literal belongs in `default` (#1033). The importer used
to copy Django's value into PormG's `db_default` slot. Now it translates it:

| Django | before | now |
|---|---|---|
| `db_default="CURRENT_DATE"` (or `"CURRENT_TIMESTAMP"`) on a text field | `db_default="CURRENT_DATE"`: today's date, silently | `default="CURRENT_DATE"`: the text, as in Django |
| the same on a `DateField` or `DateTimeField` | `db_default="CURRENT_DATE"`: the function | no default, with a `# PormG:` comment: the text is not a date. Django's spelling for the function is `Now()` |
| `db_default=0`, `db_default=False`, `db_default=Value(0)` | the import stopped (`'db_default' must be a String`) | `default=0`, `default=false` |
| `db_default="Finished"` | the import stopped, advising a pin that rendered a column reference | `default="Finished"` |
| `db_default=Now()` | the import stopped | `db_default="CURRENT_TIMESTAMP"`, or `"CURRENT_DATE"` on a `DateField` |
| `db_default=None` alone | no default | no default (unchanged) |
| `default=1, db_default=None` | `default=1` | no default, with a `# PormG:` comment: `db_default` wins |
| anything else (`Lower("x")`, `Decimal("0.00")`, …) | the import stopped | not imported, with a `# PormG:` comment; the rest of the file imports |
| `default=1, db_default=0` | the import stopped | `default=0`, with a `# PormG:` comment: `db_default` wins |

A literal default that the PormG field refuses is dropped with a comment, as a refused `default`
already was.

The refusal for a hand-written `db_default = "<text>"` now also says to use `default` when the value
is text. The error type is unchanged.

### Who this affects

Projects that import a Django `models.py` declaring `db_default="CURRENT_DATE"` or
`db_default="CURRENT_TIMESTAMP"`, or a `default` beside `db_default=None`. Those were the only
`db_default` values that imported before; every other one stopped the import.

### How to find the calls to migrate

```bash
grep -rnE 'db_default *= *(["'"'"']CURRENT_(DATE|TIMESTAMP)["'"'"']|None)' path/to/django/app/models.py
```

### Migrate your app

Re-run the import. On a text field, the default changes from the function to the text Django
declares:

```julia
# ✗ before — generated from `models.CharField(max_length=20, db_default="CURRENT_DATE")`
status = Models.CharField(max_length=20, db_default="CURRENT_DATE")

# ✓ after — the text Django stores
status = Models.CharField(max_length=20, default="CURRENT_DATE")
```

On a `DateField` or `DateTimeField`, the field now has no default, and a `# PormG:` comment says so.
If the column was migrated from the old generated file, its database default is the function, and
the next `makemigrations` plans to change it (to the text, or to dropping it). If you meant the
function, write `db_default=Now()` in the Django model, which imports as
`db_default="CURRENT_TIMESTAMP"` (`"CURRENT_DATE"` on a `DateField`).

A field declaring `default=X` beside `db_default=None` loses its `default`. The database Django built
has no default on that column, and the generated model now matches it. Declare `default` by hand if
PormG should write the value.
