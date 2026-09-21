## The leading-underscore field-name escape hatch is retired (#317)

- **Version**: 0.4.0
- **PormG ref**: #317; `src/Models.jl`, `src/constants.jl`, `src/Kernel.jl`,
  `src/models/fields.jl`, `src/querybuilder/types.jl`, `docs/src/fields.md`,
  `docs/src/schema_conventions.md`
- **Recorded**: 2026-08-08
- **Severity**: **breaking (definition time, wide)** — every model declaring a field with a leading
  underscore needs a source edit. **No database migration.** Part of the `0.4.x` pre-publish wave.

### What changed

A single leading underscore used to be an escape hatch: `format_fild_name` stripped it, so
`_end = CharField()` declared the column `end`. It existed because `end = CharField()` is a Julia
**syntax** error — a real problem, but one PormG now solves explicitly.

The hatch is gone. A declared field name starting with `_` raises at load time:

```
ModelDefinitionError: The field name '_id' on model 'b1_proc' starts with '_'. One leading underscore
used to be the escape hatch for a column whose name is a Julia keyword — `_end = CharField()` declared
the column `end` — retired in #317 because db_column (#50) states the same thing explicitly and
composes with db_table (#59). Declare the column you meant:
  • for the column 'id': id = Models.CharField(db_column = "id")
  • for a column literally named '_id': id = Models.CharField(db_column = "_id")
```

It **rejects** rather than silently meaning the literal column `_id`, for the same reason #300/#306
reject a bad model name: quietly changing which column a declaration addresses is the failure mode
worth preventing. A rejection is a load-time error; the silent version would be a wrong `SELECT`.

Why it had to go: it encoded the Julia identity and the SQL identity in **one** string with a decoding
rule, where `db_column` (#50) states them separately and composes with `db_table` (#59). It cost
[#306](#a-positional-model-name-may-not-start-with-an-underscore-306) — `format_model_name` inherited
the strip, so a model named `_order` created that table and referenced `order` — and it made
`Model_to_str` generate files that would not reload. It also forced a grammar restriction on everyone:
a name with two leading underscores was rejected outright, and `inspectdb` **aborted the entire
import** on a single column named `_foo`.

Three things fall out of it, all improvements:

- **`id` is an ordinary identifier again.** PormG's `reserved_words` list wrongly carried `id` (plus
  eleven other legal words: `type`, `where`, `in`, `isa`, `throw`, `nothing`, `missing`, `mutable`,
  `abstract`, `primitive`, `importall`). That is why every doc example and every generated model file
  said `_id = IDField()`. The list is now exactly the words Julia will not accept as a
  keyword-argument name.
- **`format_model_name` is a pure case fold.** It no longer inherits the strip, so the FK
  `REFERENCES` target and `CREATE TABLE` render the same identifier for any name.
- **Introspection can read any column.** A column named `end`, `_id`, `a__b`, `2fast` or
  `db_table` is generated under a legal Julia identity with `db_column` pinning the truth, and the
  generated file reloads to the same physical schema.

### Before → after

```julia
# before                                    # after
_id       = Models.IDField()                id         = Models.IDField()
_end      = Models.CharField()              end_       = Models.CharField(db_column = "end")
_function = Models.CharField()              function_  = Models.CharField(db_column = "function")
_db_table = Models.CharField()              table_kind = Models.CharField(db_column = "db_table")
```

**The physical column is unchanged in every row above, so `makemigrations` proposes nothing.**
`db_column` is in the planner's non-schema attribute set and the code side of the diff is keyed by
physical column, so renaming the Julia identity while pinning the same column is invisible to the
migration engine. `_id` → `id` needs no `db_column` at all: the hatch was already stripping it, so the
column was always `id`.

Field **references** follow the field's new name — `pk_field`, `UniqueConstraint(fields = …)`,
ManyToMany `source_field`/`target_field`, `values()`, `filter()`, `order_by()`. Anything that already
referred to the *stripped* name (`.filter("id" => …)`, `.filter("function" => …)`) keeps working
unchanged if you keep that name as the field identity, and needs the new identity if you rename it —
`function_` in the table above, since `function` is not a legal kwarg.

Two more spellings that also work, for completeness. `var"end" = CharField()` — Julia's own
non-standard identifier syntax — declares the field `end` directly, and the `Dict` form
(`Model("t", Dict("end" => CharField()))`) takes any string. Neither escapes a **model-option**
collision: `var"db_table"` still parses to the kwarg `:db_table` and is peeled as the option, so
`db_column` is the one spelling that covers every case.

### How to find the calls to migrate

```bash
rg -n --pcre2 '(?<![\w.])_\w+\s*(::\w+\s*)?=\s*(Models\.)?[A-Z]\w*(Field|Key)\(' -g '*.jl'
rg -n 'add_field!\([^,]+,\s*[:"]_' -g '*.jl'
```

The first finds declarations; the second finds the `add_field!` arity, which is guarded the same way.
Row **reads** need a look too — `row._id` used to resolve to the key `id` and now resolves to `_id`:

```bash
rg -n --pcre2 '(?<![\w])row\._\w+|\[\s*:_\w+\s*\]' -g '*.jl'
```

### Two more things you may hit

- **Regenerate `inspectdb` / Django-importer output, or hand-edit it.** The spelling changed: `id` is
  no longer emitted as `_id`, and a keyword or otherwise-illegal column now emits
  `end_ = Models.CharField(db_column = "end")`. The columns are identical either way — this is a
  cosmetic change to generated files, not a schema change.
- **A model binding starting with `_` changes its table.** `_Order = Models.Model(id = IDField())`
  derived the table `order`; it now derives `_order`, because `format_model_name` no longer strips.
  Rename the binding (`Order = …`) to keep the old table, or pin `db_table = "order"`. The positional
  form was already rejected (#306), so this only affects the binding-derived form.
