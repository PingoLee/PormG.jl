## A positional model name may not start with an underscore (#306)

- **Version**: 0.4.0
- **PormG ref**: #306; `src/Models.jl`, `docs/src/schema_conventions.md`
- **Recorded**: 2026-08-06
- **Severity**: **breaking (definition time, narrow)** — only declarations using a leading-underscore
  positional model name. Part of the `0.3.x` pre-publish wave.

### What changed

The same split as #300, one character away. `Models.Model("_order", …)` stored the name **verbatim**,
but a `ForeignKey` targeting it rendered its `REFERENCES` through `format_model_name`, which stripped
one leading underscore — inherited from the FIELD-name reserved-word escape hatch (`_end = ...` then
declared the column `end`; that hatch was itself retired later in this wave, see
[#317](#the-leading-underscore-field-name-escape-hatch-is-retired-317)), which a positional model name
never actually needed, since it is a plain string literal and never a Julia kwarg key. So the model
created table `_order` while any foreign key pointing at it referenced `order` instead — **a different
table**, or a failed constraint if `order` did not exist.

On PostgreSQL this either fails the migration outright (`order` does not exist) or, worse, silently
binds the foreign key to an unrelated table that happens to share that name. SQLite carries the same
inline-FK split (see `create_table(::PormGSQLite, …)`), so it is not backend-specific the way #300 was.

A positional name starting with `_` is now rejected at declaration:

```
ModelDefinitionError: The model name '_order' starts with '_'; a PormG model name is a lowercase
logical identifier and never carries one. Declare it as 'order'. If the physical table really is
named '_order', pin it explicitly: Models.Model("order", db_table = "_order", …). A leading
underscore used to be the escape hatch for FIELD names colliding with a Julia keyword; that was
retired in #317 in favour of db_column, and it never applied to model names — a positional name is
a plain string, never a Julia kwarg key.
```

It rejects rather than silently stripping, for the same reason as #300: folding the name would
discard a stated intent with no signal it happened. Model-level `db_table` (#59) landed alongside it
as the way to express a physical name PormG's own naming rules would not produce, and the message
above points at it.

**Only the positional form is affected.** `inspectdb` introspection and the Django importer still
accept a leading-underscore name — they read it from a live database or a Python class, where it is
legitimate — and `Model_to_str` round-trips it through the guarded path on reload, same as it does
for case (#300).

### Before → after

```julia
# before — created table `_order`, but a ForeignKey referencing it queried `"order"`
Order = Models.Model("_order",
  id = Models.IDField(),
)

# after — drop the leading underscore; there is no escape hatch for model names
Order = Models.Model("order",
  id = Models.IDField(),
)
```

**If the physical table really is named with a leading underscore**, pin it with `db_table` (#59):

```julia
Order = Models.Model("order", db_table = "_order", id = Models.IDField())
```

Check what `makemigrations` actually created first: it wrote the name **verbatim** (unlike the case
split, nothing here folds it), so `_order` is the table you already have — and the rejected
declaration was never able to reference it correctly in the first place.

### How to find the calls to migrate

```bash
rg -nU --multiline-dotall -g '*.jl' '(^|[^A-Za-z_])Model\(\s*"_'
```

An app that follows the documented lowercase, no-leading-underscore house style has nothing to find.
