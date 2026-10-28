## Field constructors refuse a keyword they do not accept (#1333)

- **Version**: 0.9.0
- **PormG ref**: #1333 ; `src/models/fields.jl` (`_common_kwargs`, `_FIELD_KWARG_SPECS`, `_SCHEMA_NEUTRAL_FIELD_KWARGS`), `src/migrations/importers.jl` (`_drop_unaccepted_django_options!`)
- **Recorded**: 2026-10-26
- **Severity**: breaking. A model that loaded with an "Unexpected parameter … It will be ignored" warning now raises `FieldValidationError` when it is defined.

### What changed

A field constructor used to warn about a keyword it does not take and drop it. A dropped keyword
can be a schema the table then lacks. `BigIntegerField(primary_key = true)` loaded, and
`makemigrations` planned `"circuitid" bigint NOT NULL` with no `PRIMARY KEY`, so the first upsert
or `save()` on that key failed at runtime instead of where the model was written.

Every keyword a constructor does not accept now raises `FieldValidationError`, typos included
(`nul = true`). That covers `primary_key` on any field other than `IDField`, `CharField`,
`UUIDField`, `ForeignKey` and `OneToOneField` (`DecimalField` and `FloatField` take it only to
refuse `true`, as before), a `max_length` on a field without one
(`TextField`, `EmailField`, `ImageField`, the integer fields), `unique`, `db_index` or `default` on a
`PasswordField`, `db_default` on an `IDField`, and `null` or `db_index` on a `ManyToManyField`. The
message names every such keyword at once. For `primary_key` it names the declarations that work.

The keywords that cannot change any column are still only warned about and ignored: `help_text`,
`verbose_name`, `blank`, `editable`, `choices`, `related_name`, `how`, `auto_now`, `auto_now_add`,
`auto_add`, `auto_hash`, `upload_to`, `unpack_ipv4`, `protocol` and `size`.

`import_models_from_django` drops a Django option the PormG field does not take before it builds the
field, and records it in the generated file as a `# PormG:` comment naming the class, field and
option: an `EmailField`'s `max_length`, a `ForeignKey`'s `to_field` or `db_comment`, a
`ManyToManyField`'s `symmetrical`. Without that, the refusal would abort the whole import. A
`primary_key=True` on a field type PormG cannot key on is still imported without the key and
reported by the lost-key comment, which now advises `IDField(generated = false)` for an integer key
(it advised a `CharField`/`UUIDField` key, which retypes an integer column).

| Declaration | before | now |
|---|---|---|
| `BigIntegerField(primary_key = true)` | warning; `bigint NOT NULL`, no primary key | `FieldValidationError` |
| `TextField(max_length = 500)` | warning; `text` | `FieldValidationError` |
| `CharField(max_length = 10, nul = true)` | warning; `varchar(10) NOT NULL` | `FieldValidationError` |
| `IntegerField(help_text = "…")` | warning | warning (unchanged) |

### How to find the calls to migrate

Load the models on the version you run now and look for `Unexpected parameter for` in the log: each
line names the field type and the keyword. Every one whose keyword is not in the list above raises
now. Or search the model files:

```
grep -nE '(Integer|BigInteger|PositiveInteger|PositiveSmallInteger|Boolean|Date|DateTime|Time|Duration|Text|Email|Image|File|Binary|Slug|URL|JSON|Password|Array|GenericIPAddress|CIDR|SearchVector)Field\([^)]*primary_key' models/
```

A model file `generate_models_from_db` or `import_models_from_django` writes carries no such
keyword: `Model_to_str` writes the slots that differ from the bare field, and every slot it can
write is an accepted keyword. One import path could write `PasswordField(db_index=true)` (a
`Meta.indexes` entry on a `PasswordField`); it now drops that index with a comment, as it
already said it did. A file written before this change with that line raises on load: delete
`db_index=true` there.

### Migrate your app

```julia
# ✗ before: loaded with a warning; the table had no primary key
circuitid = Models.BigIntegerField(primary_key = true)
# ✓ after: an integer key the caller supplies
circuitid = Models.IDField(generated = false)        # PostgreSQL: bigint PRIMARY KEY UNIQUE NOT NULL

# ✗ before: the width was ignored
description = Models.TextField(max_length = 500)
# ✓ after: a width the column enforces, or no width
description = Models.CharField(max_length = 500)
description = Models.TextField()
```

For a text key, use `CharField(primary_key = true, max_length = …)` or `UUIDField(primary_key = true)`.
Declaring the key creates a `PRIMARY KEY` the table did not have, so the next `makemigrations` plans it.
