## Multi-app Django import: `ignore_table` removed, `Model_to_str` drops `settings`, unresolvable relations degrade (#346)

- **Version**: 0.5.0
- **PormG ref**: #346; `src/Models.jl`, `src/migrations/importers.jl`, `docs/src/import_django.md`,
  `docs/src/schema_conventions.md`, `docs/src/configuration/connection_yml.md`
- **Recorded**: 2026-08-14
- **Severity**: **breaking (narrow)** — **five** cases. The first two are compile-time: a removed
  keyword and a removed positional argument, so an affected call fails loudly with a `MethodError`
  the first time it runs. The rest fire only when you **regenerate** a Django import — one for
  `ManyToManyField` join tables and columns, one for relations pointing outside the import, and one
  new hard error on a `models.py` that declares two classes differing only in case. The last three
  apply to the **single-app** arity as well, so read them even if you never pass app pairs.
  Everything else in this change is additive: the new `Vector{Pair}` arity, `auth_user_model`,
  `strict_relations`, `binding_overrides`, and the resolution of `"self"` /
  `"<app_label>.<Class>"` / `settings.AUTH_USER_MODEL` targets (all three of which used to reach the
  generated file verbatim and throw at `set_models`). Part of the pre-publish wave.

### 1. `import_models_from_django` no longer accepts `ignore_table`

The keyword was accepted, documented, and **never read** — the Django path has no table list to
filter, unlike `import_models_from_postgres`/`import_models_from_sqlite`, which do use theirs. A
keyword that silently accepts a filter it never applies is worse than no keyword: a caller passing it
believes models were skipped.

*How to find the calls to migrate:*

```bash
rg -n 'import_models_from_django' --glob '*.jl' -A6 | rg -n 'ignore_table'
```

```julia
# before
import_models_from_django(source; db = "sgrh", ignore_table = ["django_migrations"])

# after — delete the keyword; it never did anything
import_models_from_django(source; db = "sgrh")
```

### 2. `Models.Model_to_str` takes no `settings` argument

```julia
# before
Models.Model_to_str(model, settings; name_is_physical_table = true)

# after
Models.Model_to_str(model; name_is_physical_table = true)
```

`settings` was read for exactly one thing: composing `<django_prefix>_<class>` into `db_table` (#345).
That could not survive multi-app import, where the app label is per model and one `Settings` field
cannot hold three of them — and while it lasted, the importer had to *mirror* this function's
`db_table` precedence to pin `ManyToManyField` join tables, a mirror that shipped with a bug caught in
#345's own review. The importer now resolves the physical table and applies it with
`_apply_db_table!` before rendering, so there is one derivation instead of two that had to agree.

*How to find the calls to migrate:*

```bash
rg -n 'Model_to_str\(' --glob '*.jl'
```

The `db_table` on each model is **byte-identical** — the same string, produced by the importer
instead. Two neighbouring values did change: item 3, and one model shape described here.

A model the importer **renames** now carries a `db_table` where it previously carried none. A rename
happens when `binding_overrides` names the model, or when its derived Julia binding is one the
generated module reserves. Since the positional slot is the physical table whenever nothing pins one,
the rename used to *move* the model to a table Django never created:

```julia
# before — the table silently followed the rename
CASCADE2 = Models.Model("cascade2",
  id = Models.IDField())

# after — the handle is renamed, the table is pinned to the one Django made
CASCADE2 = Models.Model("cascade2", db_table = "cascade",
  id = Models.IDField())
```

If such a model owns an auto-derived `ManyToManyField`, its join table follows the pinned name and so
gains a `db_table=` it did not have either — the same rule as item 3, reached a different way.

### 3. Regenerating a model that declares `Meta.db_table` and owns an auto-derived `ManyToManyField`

The join table of an auto-derived `ManyToManyField` is now pinned whenever the owning model has a
`db_table` at all, not only when an app label supplied it. So an **unprefixed** import of

```python
class Season(models.Model):
    circuits = models.ManyToManyField(Circuit)
    class Meta:
        db_table = "legacy_season"
```

now emits `db_table="legacy_season_circuits"` on the field where it previously emitted nothing.

The new value is the one Django actually created — `ManyToManyField._get_m2m_db_table` reads
`opts.db_table`, so the table is `<Meta.db_table>_<field>`. PormG's own derivation was
`<logical name>_<field>` = `season_circuits`, a table nothing creates. This is a **fix**, but it is
DDL-visible on regeneration: if PormG created that join table, `makemigrations` will propose the
rename; if Django created it, the relation was addressing the wrong table until now.

Auto-derived join **columns** are pinned on the same principle, and for one more case: Django names
them `<lowercased class>_id` regardless of the target's primary key, while PormG derived
`<model>_<pk field>`. A model whose primary key is not `id` therefore gains an explicit
`source_field` / `target_field`. Same story — the emitted value is what the database has.

### 4. Regenerating an import whose relations point outside it

A `ForeignKey` naming a model the import cannot see — `"contenttypes.ContentType"`, or a class from an
app you did not pass — used to be emitted verbatim, producing a file that threw
`ModelDefinitionError` at `set_models`. It now **degrades**: the column survives as a plain
`BigIntegerField` and the artifact says what was lost.

```julia
# PormG: field 'created_by_id' on 'imports.ImportBatch' — ForeignKey target
#   'contenttypes.ContentType' is not in the imported app set; imported as a plain column,
#   the relation is lost.
created_by_id = Models.BigIntegerField(blank=true, null=true, db_index=true)
```

The column keeps the shape Django gave it — `null`, `blank`, `unique`, `db_index`, `default`,
`db_column` — so the model still matches the database. That matters most for a `OneToOneField`, which
*is* a unique column: dropping the flag would have the next `makemigrations` propose dropping a
UNIQUE constraint that really exists.

A `ManyToManyField` has no column of its own, so an unresolvable one — target or `through=` — is
dropped and marked instead.

One case is a **hard error** even with `strict_relations = false`: a relation that is also the
model's primary key (Django's shared-primary-key pattern, `OneToOneField(..., primary_key=True)`).
The fallback column type cannot be a primary key, so degrading would emit a model with none at all.

Why this is a *degrade* rather than an error: any project touching `django.contrib` references models
it did not hand you, so erroring would make the importer unusable there. But if you previously
regenerated a single app of a multi-app project and hand-added the missing models to the generated
file, **regenerating now replaces those foreign keys with plain columns.** Two ways to handle it:

- **Preferred** — import the whole project at once, so the relations resolve for real:

  ```julia
  import_models_from_django(
    ["core"    => "server/core/models.py",
     "access"  => "server/access/models.py",
     "imports" => "server/imports/models.py"];
    db = "sgrh", file = "models.jl", force_replace = true)
  ```

- Or pass `strict_relations = true` to make every such target an `InvalidMigrationError` naming the
  field and the target, so nothing degrades without you deciding it should.

### 5. One new hard error reaches the single-app arity too

Regenerating an **unchanged** `models.py` now raises `InvalidMigrationError` in one case that used to
produce a file: two classes whose names differ only in case.

```python
class Pessoa(models.Model): ...
class pessoa(models.Model): ...     # same Django model name, same derived table
```

Both name the model `pessoa` and derive the same table, so the second used to overwrite the first in
the index — leaving two declarations pointing at one table and a binding nothing could reach. Django
refuses such a project outright (*"Conflicting 'pessoa' models in application"*), so the fix is to
rename one of the classes; there is no spelling of this that was ever going to work.

*How to find it before regenerating:*

```bash
rg -n '^class (\w+)' --replace '$1' models.py | sort -f | uniq -Di
```

*How to find what would degrade:* grep the **generated** file after regenerating —

```bash
rg -n '# PormG: field .* is not in the imported app set' db/models.jl
```

`settings.AUTH_USER_MODEL` is the one target the importer refuses to GUESS at: with no
`auth_user_model` keyword and not exactly one `AbstractUser` subclass, it raises
`InvalidMigrationError` naming the candidates rather than degrading. Nearly every model in a real
project points at the user model, so one omitted keyword would quietly turn the whole user graph into
integer columns.

Passing the keyword always resolves it — **including for a stock-Django project**, whose
`AUTH_USER_MODEL` is `"auth.User"` and which therefore has no `AbstractUser` subclass to find and no
app you could add to the import. `auth_user_model = "auth.User"` names a model outside the import, so
those relations degrade to plain columns like any other external target, with a `@warn` up front and
a marker each. That is the intended way in for a project that never subclassed `AbstractUser`.
