# Upgrading PormG — consumer-app rollout log

Tracks **breaking / behavior changes in PormG** that require source-code changes in the internal apps that depend on it. PormG is pre-publish (single maintainer, ~4 internal apps, no external users), so breaking changes are intentional and cheap on the *PormG* side — but each one still has to be rolled out by hand in every consuming app. This file is that rollout checklist.

> ⚠️ **Not database migrations.** This file is about migrating **app source code** to keep up with the PormG API. It is unrelated to the `makemigrations` / `migrate` schema engine that manages your database tables.

> 🚀 **Upgrading an app? Don't read this file top to bottom.** Run
> `PormG.upgrade_guide(from = v"<your pinned version>")` — it renders only the entries newer than
> your pin, newest-first. The full how-to (versioning model, the apply recipe, driving it with an AI
> agent) lives in the docs: **[Upgrading PormG](https://pingolee.github.io/PormG.jl/dev/upgrading/)**.
> This file is the change log those tools read; the sections below are the rules for *writing* an
> entry.

## Writing an entry

- One `##` entry per breaking change, **newest first**. New entries land in **`## Unreleased`** with
  `- **Version**: Unreleased` and **no `Project.toml` bump**; the maintainer stamps them with a
  release number when cutting a train (`/pormg-cut-release`).
- Each entry records: the PormG **version** it shipped in, what changed, why, a *"How to find the
  calls to migrate"* grep, and the concrete **before → after** code edit.
- **Not for additive features.** This log is only what **forces** an app edit. A new opt-in
  capability (operator, kwarg, function) requires no change to keep an app working → document it in
  `docs/`, not here.
- **No per-entry rollout tables.** An app's own PormG dependency pin *is* its rollout state, and
  `upgrade_guide(from = <that pin>)` derives what it still needs — so there is nothing to maintain
  per app.
- **Keep the prose version-neutral.** Write *"part of the `0.3.x` pre-publish wave"*, never *"part of
  the current `## Unreleased` wave"* — stamping rewrites the `- **Version**:` bullet, not the body,
  so self-referential prose ships stale (this bit #201).
- Entries are version-stamped from **`0.2.0`** onward; those below the `pre-0.2 history` marker
  predate the versioning policy and are unstamped (treat them as already shipped before `0.2.0`).

---

## Unreleased — next `0.5.0`

_Changes merged but not yet cut into a release. A consumer dev'ing PormG at HEAD is running these,
and `PormG.upgrade_guide` surfaces them by default. When the maintainer next rolls changes into a
consuming app, `/pormg-cut-release` stamps every entry below with `0.5.0`, dates them, and tags it._

## Multi-app Django import: `ignore_table` removed, `Model_to_str` drops `settings`, unresolvable relations degrade (#346)

- **Version**: Unreleased
- **PormG ref**: #346; `src/Models.jl`, `src/migrations/importers.jl`, `docs/src/import_django.md`,
  `docs/src/schema_conventions.md`, `docs/src/configuration/connection_yml.md`
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

---

## The Django app prefix moves to `db_table`, and short-form join paths stop needing it (#345)

- **Version**: Unreleased
- **PormG ref**: #345; `src/Models.jl`, `src/migrations/importers.jl`,
  `src/querybuilder/build_joins.jl`, `src/querybuilder/build_query.jl`,
  `docs/src/schema_conventions.md`, `docs/src/import_django.md`,
  `docs/src/configuration/connection_yml.md`
- **Recorded**: 2026-08-13
- **Severity**: **breaking (narrow)** — **two** cases, both below. The first **is a database
  migration**, and fires only when you **regenerate** a prefixed Django import that has a
  `ManyToManyField`. The second needs no regeneration and changes a query on **read**, so read it
  even if you never regenerate — it is narrow (prefixed connections with a `related_name` that
  collides with a foreign key's short form) but silent. Everything else in this change is additive.
  Part of the pre-publish wave.

### What changed

`Settings.django_prefix` is one `Union{Nothing, String}` per connection, and the Django importer used
to fuse it into the generated model's **positional name**:

```julia
# before — the app label is part of the logical name
Dim_uf = Models.Model("dash_dim_uf", …)

# after — the logical handle and the physical table are separate
Dim_uf = Models.Model("dim_uf", db_table = "dash_dim_uf", …)
```

One value cannot express the `core_` / `access_` / `imports_` of a real multi-app Django project, and
PormG is structurally one models file per *database*, not per app. Carrying the prefix per model in
`db_table` (#59) is what lets one generated file hold every app — the prerequisite for multi-app
import (#346).

The Julia **binding is unchanged**: it was always derived from the Python class name and never saw
the prefix. `M.Dim_uf` keeps working.

### The one forced case — regenerating a prefixed import that has a `ManyToManyField`

**Existing generated files keep working untouched.** `Models.Model("dash_dim_uf", …)` still means the
table `dash_dim_uf`; nothing forces you to regenerate. The new spelling only appears when you do.

When you regenerate, a model with an **auto-derived** `ManyToManyField` (no `db_table` of its own, no
`through=`) changes all three names of its join table. For `class DimIbge` with `ufs =
ManyToManyField(Dim_uf)` under `django_prefix = "dash"`:

| | before | after | Django's actual |
| :--- | :--- | :--- | :--- |
| join table | `dimibge_ufs` | `dash_dimibge_ufs` | `dash_dimibge_ufs` |
| owner column | `dash_dimibge_id` | `dimibge_id` | `dimibge_id` |
| target column | `dash_dim_uf_id` | `dim_uf_id` | `dim_uf_id` |

The right-hand columns are what changed and why: **before, PormG agreed with Django on none of the
three.** The table dropped the app label (`get_model_name` stripped it) while the columns kept it
(`_many_to_many_column_name` did not) — so the two halves of one derivation disagreed with each other
as well.

If the owning class declares `Meta.db_table`, the join table follows **that** rather than the app
prefix — Django derives it from `opts.db_table`, not from `<app>_<model>`. For
`Meta.db_table = "rh_matricula_legado"` with `setores = ManyToManyField(...)`:

```
matricula_setores   →   rh_matricula_legado_setores
```

Which way this bites depends on who created the through table:

- **Django created it** — the relation was already broken; PormG was reading a table and columns that
  do not exist. Regenerating fixes it and needs no migration.
- **PormG created it** (`makemigrations` on the generated file) — the live table matches the old
  spelling, so `makemigrations` will now propose a table rename plus two column renames.

  On **PostgreSQL**, answer them as renames to keep the rows. On **SQLite**, do not: this is a table
  rename *plus* two column renames on that same table, and because both columns are foreign keys
  whose targets changed, the plan takes the table-rebuild path, which does not support a second
  rename on one table in a single pass (`src/migrations/planner.jl` documents the limitation). Either
  migrate in two passes — the table rename first, then the columns — or recreate the join table and
  copy the rows across by hand.

If the field declares its own `db_table`, or uses `through=`, nothing changes — both are left alone,
as in Django.

**How to find the calls to migrate.** In each generated models file:

```bash
grep -n "ManyToManyField" db/*/models.jl
```

Regenerate, then run `makemigrations` + `dry_run()` and read the plan before `migrate()`. A model
with no `ManyToManyField` has no schema consequence — its regeneration is cosmetic.

### Django-style join paths no longer need the prefix

`filter("driver__forename" => …)` resolves to the FK column `driver_id` on **every** connection now.
It used to be gated on `settings.django_prefix`, so unsetting the prefix — which is precisely what
this change makes possible — silently turned a working join into an `UnknownFieldError`.

The explicit `filter("driver_id__forename" => …)` spelling keeps working exactly as before, on every
connection. Both forms render the same join. Nothing to migrate.

**One narrow exception, for prefixed connections only.** If a model has a foreign key `x_id` *and*
some other model declares `related_name = "x"` pointing back at it, the path `x__col` is ambiguous.
PormG resolved it both ways before, depending on the prefix: prefix-less connections read the reverse
relation, prefixed ones read the forward foreign key. It is now the reverse relation for everyone —
an author's explicit `related_name` outranks the short form this ORM invents.

So a connection that sets `django_prefix` **and** has such a clash will read a different table for
that one path. Nothing else changes, and the clash is rare because it needs the reverse name to
collide with a forward FK's short form on the same model.

**How to find it.** For each `related_name` you declare, check whether the model it points *at* has a
field of that name plus `_id`:

```bash
grep -rn 'related_name' --include=*.jl db/
```

If one matches, spell the path you meant explicitly: `x_id__col` for the forward foreign key, or
rename the `related_name` for the reverse.

---

## Row-level writes no longer auto-resync PostgreSQL sequences (#358)

- **Version**: Unreleased
- **PormG ref**: #358; `src/querybuilder/execution.jl`, `src/querybuilder/execution_bulk.jl`,
  `src/QueryBuilder.jl`, `src/PormG.jl`, `docs/src/schema_conventions.md`, `docs/src/postgres.md`
- **Recorded**: 2026-08-13
- **Severity**: **breaking (behavioral, PostgreSQL-only)** — an app relying on `create`/
  `update_or_create`/`get_or_create` to auto-repair a drifted sequence after an explicit-primary-key
  write silently loses that protection. **No database migration.** Part of the `0.5.x` pre-publish
  wave.

### What changed

`create`/`insert`, `update_or_create`, and `get_or_create` no longer resynchronize the PostgreSQL
sequence after a write that supplies an explicit primary key. Automatic resync now runs only where
drift is actually produced in bulk — `bulk_insert` (including its own duplicate-key self-heal) and
`bulk_copy` — matching every comparable ORM checked when this was decided (Django, Rails, SQLAlchemy,
Ecto, Prisma: none resyncs on a row-level write; Django's `sqlsequencereset`/Rails'
`reset_pk_sequence!` are the closest precedent, both explicit operations, never automatic).

A new `resync_sequences(model)` / `resync_sequences(models)` closes the gap this leaves: there was
previously no way to repair a sequence without an accompanying insert — after a `pg_restore`, a
manual `COPY`, or any load that happened outside PormG entirely, or simply after a row-level write
that needs one. See [Sequence synchronisation](https://pingolee.github.io/PormG.jl/dev/schema_conventions/#Sequence-synchronisation)
in the docs.

### How to find the calls to migrate

A row-level write supplying its own primary key used to auto-resync; it no longer does. The primary
key field is not necessarily named `*id` — `db_column`/natural-key models can call it anything — so
this matches any row-level write with an explicit first argument, not just an `id`-suffixed one:

```bash
rg -n --pcre2 '\.(create|get_or_create|update_or_create)\(\s*"[a-zA-Z_]+"\s*=>' -g '*.jl'
```

This over-matches on purpose — it also flags a `create()` whose first explicit argument is not the
primary key — because a silent miss on a differently-named pk field is worse than a few hits you
discard by hand. For each hit, check two things: (1) is the argument actually the model's primary
key, and (2) does a **later** write to the same table rely on an auto-generated key not colliding
with the explicit one just inserted. Only when both hold does it need a `resync_sequences()` call.
`bulk_insert`/`bulk_copy` call sites are unaffected; skip them.

### Before → after

```julia
# before — a later auto-pk create() was protected automatically
M.Driver.objects.create("driverid" => 999, "forename" => "Max")
# ...
next = M.Driver.objects.create("forename" => "Auto")   # never collided

# after — call resync_sequences() yourself after the explicit-pk row-level write
M.Driver.objects.create("driverid" => 999, "forename" => "Max")
resync_sequences(M.Driver)
next = M.Driver.objects.create("forename" => "Auto")   # protected again
```

A data migration that creates many rows with explicit ids pays this **once**, after the batch —
not per row, which is the whole point of moving the repair off the write path.

---

## 0.4.0 — 2026-08-10

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

---

## Bulk writes — a `default` / `auto_now` no longer overwrites a blank cell in a column the DataFrame carries (#331)

- **Version**: 0.4.0
- **PormG ref**: #331; `src/querybuilder/execution_bulk.jl`
- **Recorded**: 2026-08-08
- **Severity**: **behavior change** — persisted values can differ, and a `null=false` column can now
  raise where the write used to succeed. Part of the `0.4.x` wave.

### What changed

`create()` and the bulk paths disagreed about what an explicit "no value" meant on a field carrying a
static `default`. `create()` honored it and stored `NULL`; `bulk_insert` / `bulk_copy` / `bulk_update`
rewrote the cell with the default. There was no spelling of `NULL` that survived, so the two insert
paths were not substitutable: swapping a `create()` loop for one `bulk_insert` silently changed what
was stored.

There is now one rule, shared by all three bulk operations:

> **For a field the write touches, PormG supplies a value only when the `DataFrame` has no column
> for it. A column that *is* present is caller-authored data, and PormG never rewrites its cells.**

That covers every fill kind — a static `default`, `auto_now`, `auto_now_add`, and a UUID `auto_add` —
on `:insert`, `:copy` and `:update` alike, nullable or not. Four consequences:

- A blank cell (`missing`/`nothing`) in a present, **nullable** defaulted or auto column now persists
  as SQL `NULL` instead of the fill value. On `bulk_update` that turns what used to be a silent no-op
  — writing the default back over the live value — into an actual null-out.
- A blank cell in a present **`null=false`** defaulted or auto column now raises `InvalidValueError`
  (*"null values are not allowed"*) — PormG's own validation naming the field, not a database
  constraint error, and nothing is persisted (the write is wrapped in a transaction, so a row that
  fails part-way rolls back the chunks already sent). That is the same error `create()` has always
  raised for an explicit `"field" => nothing`.
- A blank cell in a `match_on` key column is no longer back-filled from that field's `default`. Match
  keys are exempt from the per-row null check, so this changes **which rows are updated** rather than
  raising: a row keyed on a blank no longer merges into the default-valued row by accident.
- A `UUIDField(auto_add = true)` **primary key** carried in the frame with blank cells now raises
  instead of being minted in place. The old behavior was not usable anyway — it reused a single UUID
  for every row in the batch, so any multi-row insert violated the key. **Fill the column yourself**
  — `df[!, :token] = [UUIDs.uuid4() for _ in 1:DataFrames.nrow(df)]` — which works precisely because
  a present column is now honored verbatim. Do **not** drop the column instead: the absent path
  currently mints one UUID for the whole batch (#334), so a multi-row insert collides on the key.
  (The all-blank-means-absent rescue applies to `auto_increment` primary keys only; it does not
  cover UUID ones.)

**Absent columns are unchanged.** A defaulted or auto column the `DataFrame` does not carry is still
injected exactly as before — including that `bulk_update(..., columns = [...])` does not synthesize a
static `default`, and that an all-blank auto-increment primary key column still counts as absent.

**A field you leave out of `columns=` is also unchanged.** It is out of scope by your own
instruction, so its cells are not read from the frame even when the frame carries them; on
`bulk_insert`/`bulk_copy` PormG still supplies its default, which is what keeps a partial `columns=`
insert satisfying the model's `null=false` fields.

### How to find the calls to migrate

The `null=false` half announces itself: run the app or its tests and the new `InvalidValueError` names
the model and the field. The nullable half is silent, so grep for it:

```bash
# 1. Which of your models declare a fill? Only these fields are affected.
rg -n --glob '**/models*.jl' 'default\s*=|auto_now(_add)?\s*=\s*true|auto_add\s*=\s*true'

# 2. Which files build a DataFrame for a bulk write AND can produce blanks?
rg -l '\b(bulk_insert|bulk_copy|bulk_update)\s*\(' \
  | xargs rg -n 'missing|nothing|CSV\.(File|read)|allowmissing'
```

Cross-check each hit's column list against the field names from step 1. A CSV import is the common
case: an empty cell parses to `missing`, so a column that was silently receiving the model default now
receives `NULL` — or raises, if the field is `null=false`.

### Migrate your app

```julia
# Stint = Models.Model("stint",
#     driver    = Models.CharField(),
#     laps      = Models.IntegerField(default = 0),               # null = false
#     note      = Models.CharField(default = "", null = true))

df = DataFrames.DataFrame(
    driver = ["Senna", "Prost"],
    laps   = [missing, 71],      # ✗ before: stored 0 and 71
    note   = [missing, "wet"],   # ✗ before: stored "" and "wet"
)

# ✗ before — the blanks silently became the model defaults
bulk_insert(M.Stint.objects, df)

# ✓ after, option A — you WANTED the default: write it yourself, explicitly.
df[!, :laps] = coalesce.(df.laps, 0)
df[!, :note] = coalesce.(df.note, "")
bulk_insert(M.Stint.objects, df)

# ✓ after, option B — you wanted PormG to supply it: drop the column.
#   An ABSENT column is still filled from the model default, exactly as before.
bulk_insert(M.Stint.objects, DataFrames.select(df, DataFrames.Not([:laps, :note])))

# ✓ after, option C — you wanted NULL: change nothing. That is now what the nullable
#   `note` stores, matching what create() always gave you. On the null=false `laps`
#   it is now an InvalidValueError instead of a silent 0 — fix that one with A or B.
```

---

## The migration diff compares the physical column, not the Julia field type (#325)

- **Version**: 0.4.0
- **PormG ref**: #325; `src/Dialect.jl`, `src/migrations/introspection.jl`,
  `src/migrations/planner.jl`, `src/models/fields.jl`, `src/constants.jl`
- **Recorded**: 2026-08-07
- **Severity**: **behavior-visible (one-time migration plan against existing databases)** — no source
  edit is required. Part of the `0.4.x` wave.

### What changed

The remainder of the churn [#318](#introspection-now-reads-single-column-unique-back-318) fixed for
`unique`. A model declaring `URLField`, `SlugField`, `UUIDField`, `JSONField`, `ImageField`,
`FileField` or a `varchar` longer than 255 never compared equal to its own live table, so
`makemigrations` proposed the same alteration **on every run** — on SQLite the full
`CREATE new → INSERT SELECT → DROP old → RENAME` table rebuild. The same held for **every**
`db_index=true` field on both backends.

The root cause is that introspection *cannot* reproduce the declared Julia type: several field types
render the same column, so the information is not in the schema to read. PostgreSQL renders
`CharField`, `URLField` and `SlugField` all as `varchar(n)` and `ImageField`/`FileField` as `text`;
SQLite renders `UUIDField`, `JSONField`, `ImageField` and `TextField` all as bare `TEXT`. The diff
now compares **what the database actually holds** — the rendered column type plus the bounds only a
CHECK can express — and falls back to Julia struct identity only when the two structs match. Two
fields that render the same column are the same column, and an ALTER between them was always a no-op.

Six lossy reads are fixed alongside it:

- **PostgreSQL `max_length`** — any `varchar(n > 255)` was retyped to `text` with no length, because
  `CharField` refused a `max_length` above 255. That ceiling is gone (a MySQL-ism; PostgreSQL takes
  up to 10,485,760 characters and SQLite ignores the length), so `varchar(n)` now round-trips as
  `CharField(n)`, symmetric with `text` ⇒ `TextField`.
- **SQLite `max_length`** — a bare `TEXT` column read back as `CharField`, whose constructor invents
  `max_length = 250`. A lengthless textual column is now a `TextField`; only a declared `TEXT(n)`
  (or a hand-written `VARCHAR(n)`/`CHAR(n)`, now recognized) is a `CharField`.
- **`db_index`** — never read on either backend. PostgreSQL probed a `Dict{String,String}` with a
  `Symbol` key, which never matches; SQLite did not look at indexes at all. Both now read the
  single-column, non-unique, non-partial secondary indexes that `db_index=true` actually emits.
- **`get_constraints_unique`** — returned the first row of an unordered result matching any
  constraint the column merely belonged to, so a column in both `UNIQUE(a)` and `UNIQUE(a, b)` could
  drop the composite one. It is now restricted to single-column constraints and ordered.
- **`auto_now` / `auto_now_add`** — these emit **no DDL at all**: PormG stamps the timestamp in Julia
  on write, it is not a column `DEFAULT` and not a trigger. So they can never be read back, and
  `alter_field` had nothing to emit for them. Every `DateTimeField(auto_now_add=true)` was producing
  an empty alteration on every run — a full table rebuild on SQLite. They are now recognized as
  model-layer-only, like `blank` and `editable`.
- **The introspection ignore list** (`postgres_ignore_table` / `sqlite_ignore_schema`) now matches a
  **prefix** on both backends. PostgreSQL used `occursin`, so a user table merely *containing* an
  entry — `oauth_tokens` contains `auth_`, `company_admin_log` contains `admin_` — vanished from the
  live schema entirely. A table PormG cannot see does not read as "ignored" downstream, it reads as
  "does not exist", so `makemigrations` proposed `CREATE TABLE` for it forever. (SQLite used `==`,
  which could never match `sqlite_autoindex`, only ever a prefix.)

An index difference is also no longer routed through a column `ALTER`: it emits `CREATE INDEX` /
`DROP INDEX` alone. On SQLite that removes a full table rebuild that did nothing.

### What you may see once

Nothing to edit — but the **first** `makemigrations` after upgrading can propose a one-time plan:

- A live secondary index on a field declaring `db_index=false` is now visible as drift, so PormG will
  propose **dropping** it. Previously it was invisible. If the index should stay, add
  `db_index=true` to the field before applying.
- Conversely, a field declaring `db_index=true` whose index never actually got created (the create
  path could be skipped while the attribute was unreadable) now gets one `CREATE INDEX`, once.
- On SQLite, a **hand-written** lengthless `TEXT` column that your model declares as
  `CharField(max_length=n)` now reads back as a `TextField`, so PormG will propose rebuilding it as
  `TEXT(n)`. Tables PormG created are unaffected — it has always emitted the length.
- On PostgreSQL, a table whose name merely *contained* a framework prefix — `oauth_tokens`,
  `company_admin_log`, `my_social_graph` — used to be invisible, so `makemigrations` re-proposed
  `CREATE TABLE` for it every run and any real drift on it was never reported. It is now
  introspected normally, so the **first** run after upgrading may propose genuine changes that were
  being hidden. Tables that actually *start* with a framework prefix (`django_*`, `auth_*`,
  `celery_*`, …) are still skipped, exactly as before.

Review that plan before applying it, as always. After it converges, `makemigrations` on an unchanged
model set proposes **nothing** — which is the point: a clean baseline is what makes real drift
visible.

---

## Introspection now reads single-column `UNIQUE` back (#318)

- **Version**: 0.4.0
- **PormG ref**: #318; `src/migrations/introspection.jl`, `src/migrations/planner.jl`
- **Recorded**: 2026-08-07
- **Severity**: **behavior-visible (one-time migration plan against existing databases)** — no source
  edit is required. Part of the `0.4.x` wave.

### What changed

Neither backend read a column's `UNIQUE` constraint back, so a model declaring `unique=true` never
compared equal to its own live table. `makemigrations` proposed the same alteration **on every run**
— on SQLite that alteration is the full `CREATE new → INSERT SELECT → DROP old → RENAME` table
rebuild. It also masked genuine drift: with a permanently-dirty baseline, a real schema change was
indistinguishable from the standing false positive.

Two independent root causes, both fixed:

- **SQLite** — `PRAGMA table_info` has no uniqueness column, so `unique` was never populated at all.
  Introspection now reads it from `PRAGMA index_list`/`index_info`.
- **PostgreSQL** — the `unique_constraints` CTE grouped by *table*, merging every unique constraint's
  columns into one array; the consumer then required that array to have length 1. So a table with
  **two separate single-column `UNIQUE`s** reported **neither** as unique. The single-column test now
  applies per *constraint*.

Composite uniqueness is deliberately **not** read as a per-field `unique`: PormG models it as a
model-level `UniqueConstraint` (#19), and marking a member column would churn in the other direction.
For the same reason a bare `CREATE UNIQUE INDEX` (including a single-field `UniqueConstraint`) is not
read back — that keeps both backends symmetric, since PostgreSQL reads `pg_constraint`, which cannot
see an index either.

### What you may see once

Nothing to edit — but the **first** `makemigrations` after upgrading can propose a one-time plan:

- A live single-column `UNIQUE` your model does **not** declare is now visible as drift, so PormG will
  propose removing it (on SQLite, via the table rebuild). Previously it was silently ignored. Review
  that plan before applying it: if the constraint should stay, add `unique=true` to the field.
- On PostgreSQL this newly affects every table carrying **two or more** unique constraints — those
  columns previously introspected as `unique=false` regardless of what the model said.

After that one plan, re-running `makemigrations` is clean, which is the point of the fix.

### How to find the calls to migrate

```bash
# Models declaring column-level uniqueness — the ones whose diff behavior changes.
rg -n 'unique\s*=\s*true' --glob '*.jl'
```

Then run `makemigrations` and **read the plan** before `migrate`.

---

## Model-level `db_table`, and DDL now quotes the table identifier (#59)

- **Version**: 0.4.0
- **PormG ref**: #59; `src/Kernel.jl`, `src/Models.jl`, `src/Dialect.jl`, `src/migrations/planner.jl`,
  `src/querybuilder/{execution,build_joins,deletion,execution_bulk}.jl`, `src/Configuration.jl`,
  `src/models/fields.jl`, `docs/src/schema_conventions.md`, `docs/src/fields.md`
- **Recorded**: 2026-08-06
- **Severity**: **mostly additive**, with two narrow behavior changes — a `ManyToManyField(db_table =
  …)` that was relying on being silently lowercased, and generated model files for
  **introspected mixed-case tables**. Neither requires a source edit for a schema that follows the
  documented lowercase house style.

### What changed

**The feature (additive).** A model can now pin its physical table name:

```julia
DriverProfile = Models.Model("driver_profile",
  db_table = "Driver_Profile_Legacy",   # ← the table that actually exists
  driverid = Models.IDField(),
)
```

The positional name stays the lowercase logical identifier; `db_table` carries the physical one,
**verbatim** — no case fold, no leading-underscore strip. It is authoritative in DDL, in
`SELECT`/`INSERT`/`UPDATE`/`DELETE`, in `JOIN` targets, in a `ForeignKey`'s `REFERENCES` target, and
in migration add/drop/rename detection. A model that does not set it derives its table name exactly
as before, so **no existing schema changes and nothing needs re-migrating**.

This is the escape valve #300 and #306 were built to point at: a positional name that is mixed-case
or underscore-prefixed is still rejected, and `db_table` is now where that intent goes.

**DDL quotes the table identifier.** `CREATE TABLE IF NOT EXISTS driver (…)` is now
`CREATE TABLE IF NOT EXISTS "driver" (…)`. Necessary for the feature — an unquoted mixed-case name
folds to lowercase on PostgreSQL, which would have split the DDL from every (already-quoted)
query-side site. Semantically identical for a lowercase name on both backends. Only affects code that
**string-matches generated DDL**; migrations themselves are unchanged in effect.

**`ManyToManyField(db_table = …)` now preserves case.** It previously ran the value through
`format_model_name`, silently lowercasing it (and stripping a leading underscore) — the opposite
policy from the new model-level option, for the same user intent. Both now carry the value verbatim.

```julia
Models.ManyToManyField(Driver, db_table = "Driver_Races")
# before → through table `driver_races`
# after  → through table `Driver_Races`
```

**Generated model files pin an introspected mixed-case table.** `inspectdb` on a table named
`Driver_Profile` used to generate `Models.Model("driver_profile", …)` — a declaration addressing a
*different* table than the one it was read from. It now also emits the original spelling:

```julia
Driver_profile = Models.Model("driver_profile", db_table = "Driver_Profile", …)
```

**A field named `db_table` must now be declared with `db_column`.** `db_table` is peeled off
before the `fields...` slurp (exactly like `constraints`), so it is read as the option:

```julia
# before — declared a column called `db_table`
Models.Model("thing", id = Models.IDField(), db_table = Models.CharField())
# after  → ModelDefinitionError: The 'db_table' option on model 'thing' must be a String or nothing,
#          got PormG.Models.sCharField

# migrate to db_column — still the column `db_table`:
Models.Model("thing", id = Models.IDField(), table_kind = Models.CharField(db_column = "db_table"))
```

`var"db_table" = Models.CharField()` does **not** work either: it parses to the keyword-argument
name `:db_table`, and the peel keys on that name however it was spelled. (This entry originally
prescribed the leading-underscore escape hatch, `_db_table = Models.CharField()`; that hatch was
retired later in the same pre-publish wave — see
[the #317 entry](#the-leading-underscore-field-name-escape-hatch-is-retired-317) — so `db_column`
is the spelling to migrate to.)

It fails loudly at load time, never silently. A *table* named `db_table` is unaffected —
`Models.Model("db_table", …)` needs no change.

### How to find the calls to migrate

```bash
# 1. M2M through-table overrides whose value is not already lowercase — the only ones whose
#    physical table name changes.
rg -n 'ManyToManyField\([^)]*db_table\s*=\s*"[^"]*[A-Z_]' --glob '*.jl'

# 2. Anything asserting on generated DDL text (the quoting change).
rg -n 'CREATE TABLE IF NOT EXISTS [a-z_]' --glob '*.jl'

# 3. A FIELD named db_table — now read as the model option. Matches `db_table = <something>(`,
#    i.e. a field constructor rather than a string literal, so it does not flag legitimate uses.
rg -n 'db_table\s*=\s*Models\.' --glob '*.jl'
```

An app whose M2M `db_table` values are already lowercase, and which does not string-match DDL, has
nothing to change. If hit 1 returns a match, the through table it names is being renamed — either
lowercase the value to keep the current table, or migrate the table to the new spelling.

---

## The join/CTE free-function form is withdrawn — fluent only (#305)

- **Version**: 0.4.0
- **PormG ref**: #305; `src/QueryBuilder.jl`, `src/querybuilder/ctes.jl`,
  `src/querybuilder/object_manager.jl`, `docs/src/api.md`,
  `docs/src/read/subqueries_and_ctes.md`
- **Recorded**: 2026-08-04
- **Severity**: **breaking (name removal)** — narrow: it affects only code that calls `With(...)` or
  `cjoin(...)` as free functions. Part of the `0.3.x` pre-publish wave.

### What changed

The join/CTE builders had two surfaces: the fluent `.with(...)` / `.cjoin(...)` / `.cjoin_on(...)` /
`.on(...)`, and a free-function form. Only two of the four ever had the second one documented
(`With` was `export`ed from `PormG.QueryBuilder`, `cjoin` was declared `public`), which is why
`on`/`cjoin_on` had to be carved out as permanent exceptions to the naming rule #281 introduced.

**The fluent form is now the only public surface.** All four are internal, renamed under that rule:

```
With  →  _with        cjoin     →  _cjoin
on    →  _on          cjoin_on  →  _cjoin_on
```

A second parallel API is not free: it has to keep working, keep being documented, and keep being
kept in step with the fluent one. #272 is what the drift looks like when it is not — `page` and
`page!` diverged silently until a user hit it. Withdrawing the form before the General-registry
publish is cheap; afterwards it would not be.

`on` and `cjoin_on` lose nothing user-visible — they were never exported, never `public`, and never
documented as functions.
# `With(...)` as a free function — the only form that was exported, so the only one likely in an app
rg -n '(^|[^.\w])With\(' --glob '*.jl'

# the explicit import that made it reachable
rg -n 'using PormG\.QueryBuilder: .*With|import PormG\.QueryBuilder: .*With' --glob '*.jl'

# `cjoin(...)` as a free function. Over-matches: the fluent `.cjoin(` in a trailing-dot chain
# lands on its own line, so read the hits rather than assuming every one needs an edit.
rg -n '(^|[^.\w])cjoin\(' --glob '*.jl'

# The QUALIFIED form. The two patterns above exclude anything preceded by `.`, so they cannot
# see this one — and it is the spelling the old docs offered as the alternative
# ("or qualify: PormG.QueryBuilder.With(...)"), so it is the likeliest to be in an app.
rg -n 'QueryBuilder\.(With|cjoin|cjoin_on|on)\(' --glob '*.jl'
```

### Before → after

```julia
# before — free-function form, needing an explicit import
using PormG.QueryBuilder: With

races_91 = M.Race.objects.filter("year" => 1991).values("raceid")
q = M.Result.objects
With(q.object, "r91", races_91, join_field = "raceid" => "raceid")
q.filter("positionorder" => 1)

# after — the fluent method, no import needed
races_91 = M.Race.objects.filter("year" => 1991).values("raceid")
q = M.Result.objects.
    with("r91" => races_91, join_field = "raceid" => "raceid").
    filter("positionorder" => 1)
```

Note the argument shape differs: the free function took the CTE name and sub-query as two positional
arguments plus `q.object` (the underlying `SQLObject`); the fluent method takes a `Pair` and operates
on the handler. Same for `cjoin(query, "result" => "Result")` → `query.cjoin("result" => "Result")`.
## A positional model name must be lowercase (#300)

- **Version**: 0.4.0
- **PormG ref**: #300; `src/Models.jl`, `docs/src/schema_conventions.md`, `docs/src/models.md`
- **Recorded**: 2026-08-04
- **Severity**: **breaking (definition time, SQLite-only apps in practice)** — a declaration that
  loaded now raises. Part of the `0.3.x` pre-publish wave.

### What changed

`Models.Model("Driver_Profile", …)` stored the name **verbatim**, and the two groups of consumers
disagreed about its case: `makemigrations` lowercased it into the DDL, while the query builder quoted
it as declared. So the model migrated a table named `driver_profile` and then addressed
`"Driver_Profile"` in every `SELECT`/`INSERT`/`UPDATE` — **one declaration, two tables**. The
generated `DELETE` contained both spellings at once.

On PostgreSQL a quoted identifier is case-sensitive, so every read and write failed with
`relation "Driver_Profile" does not exist` *after a migration that succeeded*. SQLite's identifiers
compare case-insensitively, so it masked the split completely: a green SQLite suite and a broken
PostgreSQL deployment — the same wrong-way-round shape as #276.

A positional name containing any uppercase character is now rejected at declaration:

```
ModelDefinitionError: The model name 'Driver_Profile' must be lowercase; PormG lowercases table
names when generating DDL but quotes them as declared in queries, so this model would migrate the
table 'driver_profile' and then query 'Driver_Profile'. Declare it as 'driver_profile'.
```

It rejects rather than silently lowercasing because folding the name would discard a stated intent
with no signal it happened. At the time there was also no way to *express* that intent; #59 has since
added model-level `db_table`, which is where it goes: `Model("driver_profile", db_table =
"Driver_Profile", …)`.

**Only the positional form is affected.** A name derived from the Julia binding
(`Race = Models.Model(…)`) was already lowercased when `set_models` filled it in, and is unchanged.
`inspectdb` introspection and the Django importer also still accept a mixed-case name — they read it
from a live database or a Python class, and `Model_to_str` lowercases it when writing the generated
model file, so `import` → `makemigrations` → reload keeps working.
grep -rnE '(^|[^A-Za-z_])Model\(\s*"[^"]*[A-Z]' --include=*.jl .
```

The leading `(^|[^A-Za-z_])` keeps `PormGModel(` and `convertSQLToModel(` out of the results. Any hit
is a model that was already broken on PostgreSQL and silently working on SQLite.

!!! warning "A clean result is not proof — this grep is line-based"
    It only matches when the name is on the **same line** as `Model(`. A declaration written across
    lines, which is house-normal, is missed entirely:

    ```julia
    Driver_Profile = Models.Model(
      "Driver_Profile",          # ← the grep above does not see this
      driverid = Models.IDField(),
    )
    ```

    Use the multi-line form to be sure. Ripgrep is the reliable option here; `grep -Pzo` is not, as
    many builds accept `-P` only in unibyte/UTF-8 locales:

    ```bash
    rg -nU --multiline-dotall -g '*.jl' '(^|[^A-Za-z_])Model\(\s*"[^"]*[A-Z]'
    ```

An app that follows the documented lowercase house style has nothing to find either way.

### Before → after

```julia
# before — loaded fine, migrated `driver_profile`, queried `"Driver_Profile"`
Driver_Profile = Models.Model("Driver_Profile",
  driverid = Models.IDField(),
  surname  = Models.CharField(),
)

# after — the positional name is lowercase; the Julia binding keeps its capitalization
Driver_Profile = Models.Model("driver_profile",
  driverid = Models.IDField(),
  surname  = Models.CharField(),
)
```

**If the physical table really is mixed-case**, there is no mapping for it yet — that is
[#59](https://github.com/PingoLee/PormG.jl/issues/59). On SQLite the rename above is a no-op because
identifiers compare case-insensitively. On PostgreSQL, check what `makemigrations` actually created:
it emitted the **lowercased** name, so `driver_profile` is almost certainly the table you already
have, and the corrected declaration now points at it instead of at a table that never existed.

### How to find the calls to migrate

```bash

---

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

---

## Introspected foreign keys now carry `on_delete` (PostgreSQL) and the column default (SQLite) (#292)

- **Version**: 0.4.0
- **PormG ref**: #292; `src/migrations/introspection.jl`, `UPGRADING.md`
- **Recorded**: 2026-08-04
- **Severity**: **breaking (generated model files change; a contradictory PostgreSQL schema now
  fails at registration)** — narrow: it affects only apps that generate models by introspecting a
  database. Part of the `0.3.x` pre-publish wave.

### What changed

Introspection lost a different half of each foreign-key declaration per backend, and the two halves
were mirror images:

- **PostgreSQL never queried the referential action at all.** A table whose FK was
  `ON DELETE CASCADE` introspected to a model claiming no cascade, and a migration generated from
  that model dropped the action from the schema. Silent round-trip infidelity.
- **SQLite carried the action but dropped the column default.** Since #287 that is a hard failure:
  an `ON DELETE SET DEFAULT` FK introspected to `on_delete=SET_DEFAULT` with no `default=`, which
  `set_models` rejects — and regenerating produced the identical broken file.

Both are fixed. `OneToOneField` had the same omission as `ForeignKey` and is fixed with it.

Two consequences for existing apps:

**1. Regenerated model files change.** PostgreSQL-generated files gain `on_delete=` on every FK that
declares an action. SQLite-generated files lose a spurious `on_delete=DO_NOTHING` on FKs that never
declared one — both backends now render "no action declared" as an omitted `on_delete`, which is
what PormG already emitted as SQL (`ON DELETE NO ACTION`) for both spellings. `makemigrations` does
not diff `on_delete`, so **regenerating produces no `ALTER` and no migration**; it is a source-file
change only.

One narrow exception, on SQLite: the *field-rename* path does compare the action. So an app that
keeps an explicit `on_delete=DO_NOTHING` in its models file instead of regenerating, and then renames
that FK field, now gets a table rebuild it would not have got before. It is data- and
index-preserving, and it disappears as soon as the file is regenerated.

**2. A self-contradictory PostgreSQL schema now fails at registration.** Because the PostgreSQL path
never emitted `on_delete` before, it could not contradict anything. Now it can, and #287's guards
apply to introspected models as they already did to hand-written ones:

- `ON DELETE SET NULL` on a `NOT NULL` column → `ModelDefinitionError` at `set_models`
- `ON DELETE SET DEFAULT` on a column with no default (or a default PormG cannot represent as an
  `Int64` — a text default, a `nextval(...)` expression) → `ModelDefinitionError`

Both are legal PostgreSQL DDL that only fails at delete time, so a database can genuinely be in this
state. Introspection **warns** naming the table and column when it drops an unrepresentable default,
and never throws from inside the import itself.

### How to find the calls to migrate

```bash
# 1. Regenerate your models and diff — expect on_delete= to appear (PostgreSQL) or a spurious
#    DO_NOTHING to disappear (SQLite). No migration is generated either way.
git diff -- <your models file>
```

```sql
-- 2. Contradictory FKs, if your generated module now fails to register. Run against the DATABASE,
--    not the model file — these are schema states, not code. Reports the two columns you need to
--    judge each row: `attnotnull` and the column default.
--      * confdeltype 'n' (SET NULL)    + attnotnull = t          → contradictory
--      * confdeltype 'd' (SET DEFAULT) + col_default NULL, or a
--        default PormG cannot read as an Int64 (text, nextval)   → contradictory
--    A multi-column FK yields one row per column.
SELECT c.relname, a.attname, con.confdeltype, a.attnotnull,
       pg_get_expr(ad.adbin, ad.adrelid) AS col_default
FROM pg_constraint con
JOIN pg_class c ON c.oid = con.conrelid
JOIN pg_attribute a ON a.attrelid = con.conrelid AND a.attnum = ANY(con.conkey)
LEFT JOIN pg_attrdef ad ON ad.adrelid = a.attrelid AND ad.adnum = a.attnum
WHERE con.contype = 'f' AND con.confdeltype IN ('n', 'd');
```

### Before → after

Copy-exact `Model_to_str` output — kwarg order is struct-field order and there are no spaces around
`=`, so this is what `git diff` on a regenerated file actually shows:

```julia
# before — PostgreSQL introspection produced this for an ON DELETE CASCADE column
fk_cascade = Models.ForeignKey("Pormg_it_fk_parent", null=true, pk_field="id")

# after — the action it actually declared is carried through
fk_cascade = Models.ForeignKey("Pormg_it_fk_parent", null=true, pk_field="id", on_delete=CASCADE)
```

If a regenerated model now raises `ModelDefinitionError`, fix the **schema**, not the generated file
— the alternative is re-editing it by hand after every regeneration:

```sql
-- SET NULL needs a nullable column
ALTER TABLE results ALTER COLUMN driverid DROP NOT NULL;
-- SET DEFAULT needs something to set
ALTER TABLE results ALTER COLUMN statusid SET DEFAULT 1;
```

---

## `BinaryField` stores real bytes — reads return `Vector{UInt8}`, not `String` (#296)

- **Version**: 0.4.0
- **PormG ref**: #296; `src/Kernel.jl`, `src/Models.jl`, `src/constants.jl`, `src/Dialect.jl`,
  `src/models/fields.jl`, `src/querybuilder/parameters.jl`, `src/querybuilder/sanitization.jl`,
  `src/migrations/introspection.jl`, `docs/src/fields.md`
- **Recorded**: 2026-08-03
- **Severity**: **breaking (runtime behavior + column type, both backends)** — narrow: it affects
  only apps that declare a `BinaryField`. Part of the `0.3.x` pre-publish wave.

### What changed

`BinaryField` never stored binary data. `_get_column_type` had no branch for it, so it fell through
to the `TEXT` fallthrough on **both** backends; `default=` raised for every non-`nothing` value; and
`max_length` was enforced as a *character* count on strings only, never reaching the schema. It now
renders `BYTEA` on PostgreSQL and `BLOB` on SQLite.

Three consequences for an app:

1. **Reads return `Vector{UInt8}`.** A column that handed back a `String` now hands back bytes, so
   any `occursin` / `parse` / string concatenation on that value stops compiling or silently changes
   meaning. This is the change most likely to need a source edit.
2. **Writes accept bytes or a `String`.** A `String` is stored as its UTF-8 code units, so existing
   write sites keep working unchanged. Anything else (an `Int`, a `Dict`) now raises
   `InvalidValueError` instead of being coerced.
3. **`default=` takes `Vector{UInt8}` only.** It used to raise for everything, so nothing that
   worked before breaks — but a `String` still raises, now with a message naming the two decodings.

Separately, and worth knowing even if you never touch the API: on PostgreSQL a binary value used to
be handed to LibPQ as a raw vector, which LibPQ renders as a PG *array literal* in text format.
`UInt8[0x00, 0xFF]` reached the server as the five characters `{0,255}` and `bytea` stored those
ASCII bytes. It raised no error. Any bytes written through the old path are already corrupt in the
database and cannot be recovered by this migration.

**The schema change needs review before you apply it.** This file is normally not about database
migrations, but this one is not mechanical. The next `makemigrations` proposes:

- PostgreSQL — `ALTER TABLE … ALTER COLUMN … TYPE bytea USING convert_to("col", 'UTF8')`
- SQLite — a table rebuild whose copy step is `CAST("col" AS BLOB)`

Both **reinterpret** the existing text as its UTF-8 bytes; neither decodes it. That is correct for a
column that held plain text, and wrong for one that held hex or Base64 — PormG cannot tell which.
If yours held an encoding, edit `pending_migrations.jl` to use `decode(col, 'hex')` /
`decode(col, 'base64')` before running `migrate()`. If the column was really text all along, the
honest fix is to retype the field as `TextField` and skip the conversion entirely.

### How to find the calls to migrate

```bash
# 1. Which models declare one at all — if this is empty, nothing below applies.
grep -rn "BinaryField" --include=*.jl .

# 2. Read sites for those columns: the value is now Vector{UInt8}, not String.
#    Substitute your own field names from step 1.
grep -rn "file_data\|encrypted_content" --include=*.jl .
```

### Before → after

```julia
# before — the column was TEXT, so reads came back as a String
row = M.Technical_document.objects.filter("id" => 1).values("file_data").list() |> first
occursin("PDF", row[:file_data])
write("out.pdf", row[:file_data])

# after — reads are raw bytes
row = M.Technical_document.objects.filter("id" => 1).values("file_data").list() |> first
occursin("PDF", String(copy(row[:file_data])))   # decode explicitly when you want text
write("out.pdf", row[:file_data])                # already the right type for binary I/O

# writes are unchanged for String values, and now also take bytes directly
M.Technical_document.objects.create("file_data" => "still works, stored as UTF-8 bytes")
M.Technical_document.objects.create("file_data" => read("aero.pdf"))
```

---

## SQLite now enforces foreign keys (#276)

- **Version**: 0.4.0
- **PormG ref**: #276; `ext/PormGSQLiteExt.jl`, `src/ConnectionPool.jl`, `src/migrations/runner.jl`,
  `src/querybuilder/deletion.jl`, `docs/src/write/create.md`, `docs/src/write/delete.md`
- **Recorded**: 2026-08-02
- **Severity**: **breaking (runtime behavior, SQLite only)** — statements that silently succeeded now
  raise. Part of the `0.3.x` pre-publish wave.

### What changed

SQLite ships with `PRAGMA foreign_keys` **off** and PormG never turned it on, so the `REFERENCES`
clauses `makemigrations` emits were declared and never enforced. A dangling foreign key inserted
cleanly on SQLite and raised `IntegrityError` on PostgreSQL.

That is the wrong way round for a project that recommends SQLite for local/test and PostgreSQL for
production: **a referential-integrity bug passed a green SQLite suite and only surfaced in
production.** PormG now issues `PRAGMA foreign_keys = ON` on every SQLite connection, so both
backends enforce the same contract.

Two consequences for existing code:

- Inserting or updating a row whose foreign key has no parent now raises `IntegrityError` on SQLite,
  as it always has on PostgreSQL.
- Deleting a parent that still has children raises, unless the relation says otherwise
  (`on_delete = "CASCADE"`/`SET_NULL` behave as declared). Notably `DO_NOTHING` now defers to a
  database that actually checks.

**Enforcement is not retroactive.** Rows that are already dangling stay where they are; only new
statements are constrained. So an existing database does not start failing on read — it fails the
next time something writes a bad reference, which is the point.

Migrations are unaffected: the SQLite table-rebuild suspends enforcement for the duration of the
migration transaction (SQLite's own documented ALTER procedure), and the connection is renewed
afterwards so enforcement is never left off.

### How to find the calls to migrate

```bash
grep -rn "on_delete" --include=*.jl .
grep -rn "bulk_insert\|bulk_update" --include=*.jl .
```

Look for anything that writes related rows **children-first**, or that relied on SQLite tolerating a
reference to a row that does not exist — fixture loaders and data-repair scripts are the usual
places. A load whose order is genuinely parent-last needs the escape hatch below.

### Before → after

```julia
# before — succeeded on SQLite, raised on PostgreSQL
M.Race.objects.create("year" => 2025, "circuitid" => 999_999, …)

# after — raises IntegrityError on both. Either insert the parent first…
M.Circuit.objects.create("circuitid" => 999_999, …)
M.Race.objects.create("year" => 2025, "circuitid" => 999_999, …)
```

```julia
# …or, if the order genuinely cannot be parent-first, wrap it in a transaction. Checks are deferred
# to COMMIT on BOTH backends, so a transiently inconsistent block commits fine. Usually all you need.
atomic(pool) do
    bulk_insert(M.Result, results_df)   # children
    bulk_insert(M.Race,   races_df)     # parents
end
```

```julia
# Only when a transaction is not enough — a load too big to hold in one, a repair that must leave a
# violation standing — suspend enforcement outright. A PRAGMA foreign_key_check runs before COMMIT,
# so the result is still verified. Pass check_on_exit = false when the violation is deliberate, or
# when the database already contains orphans (the check is whole-database, not scoped to the block).
without_foreign_keys(pool) do
    …
end
```

### Two timing details worth knowing

**Inside a transaction, an FK error now surfaces at `COMMIT`, not at the statement.** PormG's
PostgreSQL foreign keys have always been `DEFERRABLE INITIALLY DEFERRED`, and SQLite now matches
(`PRAGMA defer_foreign_keys`). If you wrapped a single `create()` in its own `try`/`catch` expecting
the `IntegrityError` there, it will now arrive when the surrounding transaction commits. Outside a
transaction — an autocommit `create()` — nothing changes: the error still comes from the statement.

**`on_delete = "PROTECT"` (`ON DELETE RESTRICT`) differs slightly.** PostgreSQL never defers
`RESTRICT`, so it raises at the `DELETE`; SQLite defers it with everything else and raises at
`COMMIT`. The error type is the same (`IntegrityError`) and PormG's own collector raises
`ProtectedError` before any SQL in the usual path, so this only shows up if you reach the database
directly.

---

## Contradictory `on_delete` declarations now raise, and the `SET` sentinel is gone (#287)

- **Version**: 0.4.0
- **PormG ref**: #287; `src/constants.jl`, `src/Kernel.jl`, `src/Models.jl`, `src/QueryBuilder.jl`,
  `src/models/fields.jl`, `src/querybuilder/deletion.jl`
- **Recorded**: 2026-08-01
- **Severity**: **breaking (raises where it previously warned or silently continued)** — narrow: it
  affects only models whose `on_delete` declaration was already self-contradictory or used the
  unimplemented `SET`. Part of the `0.3.x` pre-publish wave.

### What changed

Three `on_delete` states that used to be accepted, and then misbehaved later, are now rejected at the
earliest point they can be detected.

**1. `SET` is removed.** It was exported and accepted but no branch of the deletion collector
implemented it, and the DDL renderer emitted the syntactically invalid `ON DELETE SET`. It could not
be implemented coherently: Django's `SET(value)` carries a value or callable, and PormG's `on_delete`
is a bare sentinel with nowhere to put one.

Removing it also removes the `contains(on_delete, "SET")` fallback that produced it, which had been
swallowing near-miss typos — `"SET-NULL"`, `"SETNULL"` and Django's `models.SET(fn)` all became `SET`
silently. Those now raise `FieldValidationError` at field construction, with `models.SET(...)` getting
a message that names it specifically.

**2. `SET_NULL` on a `null=false` field** and **3. `SET_DEFAULT` with no `default`** now raise
`ModelDefinitionError` from `set_models` at registration. Both checks already existed there as
`@error` logs: they printed the problem and let the model through, so the contradiction resurfaced
later as a database constraint violation, or — for `SET_DEFAULT` — as a silent `UPDATE … SET col =
NULL`, i.e. `SET_DEFAULT` quietly behaving as `SET_NULL`. The deletion collector keeps its own copy of
both guards for models that never pass through `set_models`.

The throw is only reachable from `set_models`, and the migration planner deliberately does not call it
(`src/migrations/planner.jl` loads models into a throwaway module), so `makemigrations` / `migrate` are
unaffected.

**Generated model files are affected, though.** Django's `on_delete=models.SET_DEFAULT, default=None`
on a nullable FK used to import verbatim as `SET_DEFAULT` with no default — a shape that now fails at
registration, so the generated file would not load and regenerating produced the identical broken file.
The importer translates it to `SET_NULL` (which is what Django's combination denotes) and warns.

Importing from a **database** needed a hand edit for a while: the introspector rendered
`on_delete=SET_DEFAULT` without carrying the column default through, so the generated module failed
to register and regenerating reproduced the same broken file. #292 fixed that — introspection now
carries the default (and, on PostgreSQL, the referential action it never used to query), so no hand
edit is required.

### How to find the calls to migrate

```bash
# 1. the removed sentinel, and any string that used to fall through to it.
# Over-matches slightly: it also lists the still-valid "SET NULL" / "SET DEFAULT" spellings, so
# read the hits rather than assuming every one needs an edit.
rg -n 'on_delete\s*=\s*("?SET"?[,)\s]|"[^"]*SET\()' --glob '!*.md'

# 2. SET_NULL fields that are not nullable
rg -n -U 'ForeignKey\([^)]*SET_NULL[^)]*null\s*=\s*false' --glob '*.jl'

# 3. SET_DEFAULT fields — check each one actually declares a default=
rg -n 'on_delete\s*=\s*"?SET_DEFAULT' --glob '*.jl'
```

### Before → after

```julia
# before — all three were accepted and then misbehaved later
parent = Models.ForeignKey(Team,   pk_field = "id",       on_delete = "SET",         null = true)
driver = Models.ForeignKey(Driver, pk_field = "driverid", on_delete = "SET_NULL",    null = false)
status = Models.ForeignKey(Status, pk_field = "statusid", on_delete = "SET_DEFAULT", null = true)

# after — SET has no replacement, so pick the action you actually meant;
#         SET_NULL needs a nullable column; SET_DEFAULT needs something to set
parent = Models.ForeignKey(Team,   pk_field = "id",       on_delete = "SET_NULL",    null = true)
driver = Models.ForeignKey(Driver, pk_field = "driverid", on_delete = "SET_NULL",    null = true)
status = Models.ForeignKey(Status, pk_field = "statusid", on_delete = "SET_DEFAULT", null = true, default = 1)
```

If a model trips check 2 or 3 at `set_models`, the message names the model and field.

---

## `PormG.Migrations` no longer exports its schema-introspection helpers (#274)

- **Version**: 0.4.0
- **PormG ref**: #274; `src/Migrations.jl`
- **Recorded**: 2026-08-01
- **Severity**: **breaking (export surface)** — narrow: it affects only code that does
  `using PormG.Migrations` *and* calls one of nine names unqualified. Part of the `0.3.x`
  pre-publish wave.

### What changed

Nine names were exported by `PormG.Migrations` that are schema-introspection and module-scanning
plumbing, not API. None appears anywhere in the documentation, every call site outside
`src/migrations/` was already qualified, and `get_sequence_name` had no caller anywhere in the repo.
Exporting them made them read as public, and put them on the docstring-coverage guard for a surface
nobody consumes.

They are **still there and still work** — they are just no longer exported, so reach them qualified:

```
get_database_schema   get_all_models        get_all_dicts
get_constraints_fk    get_constraints_index get_sequence_name
get_constraints_pk    get_constraints_unique get_constraints_check
```

The last three are a special case: they are `PormG.Kernel` generics that `Kernel` already exports,
so `Migrations` was re-exporting a name it did not own. **`PormG.get_constraints_check(...)` and
friends keep resolving as qualified calls** — including extending them with your own method for a
mock.

> **Amended by #283:** one exception to "unchanged". `get_constraints_pk`'s second parameter was
> narrowed from `Symbol` to `String`, so a qualified call passing a `Symbol` table name — or a mock
> method typed `(::MyMock, ::Symbol, ::String)` — no longer dispatches. Pass a `String` instead. It
> was unreachable through PormG itself (its only caller passed the wrong arity and always raised
> `MethodError`), which is why it is recorded here rather than as its own entry.

`names(PormG)` is unchanged (63), so nothing that only does `using PormG` is affected.

### How to find the calls to migrate

```bash
# Only files that pull the module in wholesale can be affected:
rg -l 'using PormG\.Migrations|using PormG: Migrations' --type julia
# …then, within those, look for the nine bare names:
rg -n '\b(get_database_schema|get_all_models|get_all_dicts|get_constraints_fk|get_constraints_index|get_sequence_name|get_constraints_pk|get_constraints_unique|get_constraints_check)\s*\(' --type julia
```

An already-qualified call (`Migrations.get_migration_plan(...)`, `PormG.get_constraints_check(...)`)
needs no change.

### Before → after

```julia
# before — relied on the export
using PormG.Migrations
schema = get_database_schema(conn)
models = get_all_models(my_models_module)

# after — qualify
using PormG.Migrations
schema = PormG.Migrations.get_database_schema(conn)
models = PormG.Migrations.get_all_models(my_models_module)
```

Note `get_all_models` also collides with a *different* `Models.get_all_models`; qualifying removes
the ambiguity as a side effect.

---

## Database failures now raise `DatabaseError`, not the driver's exception type (#268)

- **Version**: 0.4.0
- **PormG ref**: #268; `src/exceptions.jl`, `src/Backend.jl`, `src/ConnectionPool.jl`,
  `src/AdvisoryLock.jl`, `src/Configuration.jl`, `ext/PormGLibPQExt.jl`, `ext/PormGSQLiteExt.jl`,
  `docs/src/api.md`
- **Recorded**: 2026-07-31
- **Severity**: **breaking (error contract)** — closes the last hole in `catch PormGError`. Part of
  the `0.3.x` pre-publish wave.

### What changed

Once a statement reached the database, failures used to propagate as the **driver's own exception
type**. Handling a UNIQUE violation therefore meant `catch SQLite.SQLiteException` /
`catch LibPQ.Errors.*` — a hard dependency on the driver package purely to *name* the type, which
fights the `[weakdeps]` design that keeps LibPQ/SQLite optional. `docs/src/api.md` meanwhile
promised "`catch PormGError` catches them all", which was simply false for this class.

Those failures are now wrapped at the pool's own seams:

| New type | Covers |
|---|---|
| `DatabaseError` *(abstract)* | umbrella for all three below |
| `IntegrityError` | `UNIQUE` / `FOREIGN KEY` / `NOT NULL` / `CHECK` / exclusion violations |
| `OperationalError` | connection dropped mid-query, deadlock, serialization failure, lock timeout (incl. `with_advisory_lock`) |
| `StatementError` | invalid SQL, unknown table/column, rejected type, insufficient privilege — and the unclassified fallback |
| `TransactionError` | transaction-**API** misuse; not a database error |

The driver's exception is preserved on `.cause`, so nothing is lost. Classification is exact on
PostgreSQL (LibPQ parameterizes its exception type on the SQLSTATE) and message-based on SQLite
(`SQLiteException` carries only a message).

**User code is untouched.** `run_in_transaction` / `atomic` / `with_savepoint` run your closure
inside their `try`; an exception *you* raise still propagates as itself. Only driver failures wrap.

### How to find the calls to migrate

```bash
grep -rn "SQLiteException\|LibPQ.Errors\|PQResultError" --include=*.jl .
grep -rn "duplicate key\|UNIQUE constraint\|violates foreign key" --include=*.jl .
```

Also check any `catch` that matched a database failure by message substring — a type now exists.

### Before → after

```julia
# before — needs `using SQLite` (or LibPQ) purely to name the type, and is backend-specific
try
    M.Driver.objects.create("driverref" => "senna", "code" => "SEN")
catch e
    if e isa SQLite.SQLiteException && occursin("UNIQUE constraint failed", e.msg)
        return conflict()
    end
    rethrow()
end

# after — backend-agnostic, no driver dependency
try
    M.Driver.objects.create("driverref" => "senna", "code" => "SEN")
catch e
    e isa IntegrityError   && return conflict(error_message(e))
    e isa OperationalError && return retry_later()
    rethrow()
end
```

Two further retypings in the same pass, both previously uncatchable via `PormGError`:

```julia
# before                                        # after
catch e; e isa ErrorException && …              catch e; e isa OperationalError && …
#   with_advisory_lock acquisition timeout

catch e; e isa QueryBuildError && …             catch e; e isa TransactionError && …
#   atomic(durable=true) nested in a transaction
catch e; e isa InvalidConfigurationError && …   catch e; e isa TransactionError && …
#   model bound to another connection during an open transaction
```

Read any of these with `error_message(e)`, **not** `e.msg` — like `PoolConnectError`, the three
`DatabaseError` subtypes are built from structured fields and have no `msg`.

---

## Error contract, final pass: renames, capability split, and closed escape hatches (audit / #268)

- **Version**: 0.4.0
- **PormG ref**: the 2026-07-30 taxonomy audit; `src/exceptions.jl`, `src/Backend.jl`,
  `src/Configuration.jl`, `src/ConnectionPool.jl`, `src/Dialect.jl`, `src/migrations/*`,
  `src/querybuilder/*`, `docs/src/api.md`; boundary decision deferred to #268
- **Recorded**: 2026-07-30
- **Severity**: **breaking (error contract)** — the last pre-publish pass over error types. Three
  renames, one type split, two new types, one umbrella, and ~20 formerly-untyped escape hatches now
  raise taxonomy types. Part of the `0.3.x` pre-publish wave.

### Renames (mechanical)

| Before | After | Why |
|---|---|---|
| `PermissionError` | `WritesDisabledError` (now `<: ConfigurationError`) | The old name read as OS/file permissions or DB GRANTs; it means PormG's own `change_data: false` switch, and its remedy is a `connection.yml` edit |
| `MissingDatabaseConfigurationException` | `MissingConfigurationError` | The sole `*Exception` that survived the #231 clean break |
| `UnsupportedConnectionError` (capability cases) | `BackendCapabilityError` | See the split below |

### The `UnsupportedConnectionError` split

One type covered three disjoint remedies, distinguishable only by message text:

- **Backend capability limits** → **`BackendCapabilityError`** (new): JSONB / `iunaccent_*` lookups
  on SQLite, window `frame=` on SQLite (was `QueryBuildError`), `bulk_copy` on SQLite, too-old
  SQLite library, an importer pointed at the wrong backend.
- **Model not bound to a connection** → **`InvalidConfigurationError`** (whose docstring always
  claimed this case). All three former entry-path variants now agree, and a fourth path that
  produced a raw `MethodError` (config entry present but pool never built) is typed too.
- **Internal dispatch bugs** keep `UnsupportedConnectionError` — "please report" cases only.

### New types and umbrella

- **`ProtectedError`** (new): `delete()` refused because rows reference the target via
  `on_delete = PROTECT`/`RESTRICT`. Was the long-tail `QueryBuildError`, which made "the data
  forbids this" indistinguishable from "your delete call is malformed". Mirrors Django.
- **`DefinitionError`** (new abstract): umbrella over `FieldValidationError` +
  `ModelDefinitionError` — one `include("models.jl")` can raise either. Non-breaking to catch.

### Formerly untyped escapes — `catch PormGError` now actually covers these

- **Bulk row validation** (`bulk_insert`/`bulk_copy`/`bulk_update`): a failing row now rethrows
  PormG's own error (e.g. `InvalidValueError`) instead of stringifying it into `ErrorException` —
  `catch InvalidValueError` now behaves the same for `insert()` and `bulk_insert()`.
- **Missing driver** (`using SQLite`/`using LibPQ` forgotten): all backend generics now raise
  `InvalidConfigurationError` instead of `ErrorException` (message unchanged).
- **Migration engine**: no-pending-plan, SQLite PK-column deletion, missing models file
  (`MissingConfigurationError`), unparseable introspected DDL, importer field failures — all typed
  (`InvalidMigrationError` unless noted); a wrapped `FieldValidationError` now rethrows as itself.
- **`before_connect` hook abort** → `PoolConnectError` (so `catch PoolError` covers it).
- **`get_or_create` unknown lookup/defaults field** → `UnknownFieldError`, matching
  `update_or_create` (they disagreed).
- **`SET_NULL` on a `null=false` FK** → `ModelDefinitionError` (schema self-contradiction; was
  `InvalidValueError`).

**Still outside the taxonomy, deliberately:** runtime database failures (constraint violations,
rejected SQL, dropped connections) still propagate as raw driver exceptions — that boundary is the
open pre-publish decision in **#268**, now stated honestly in `api.md`. `with_advisory_lock`'s
timeout stays `ErrorException` pending the same decision.

### How to find the calls to migrate

```
rg -n 'PermissionError|MissingDatabaseConfigurationException' <app>
rg -n 'UnsupportedConnectionError' <app>   # decide per site: capability → BackendCapabilityError
rg -n 'catch|@test_throws|isa' <app> | rg 'ErrorException'   # bulk/migration/driver-hint catches
```

### Migrate your app

```julia
# ✗ before
catch e
    e isa PermissionError && fall_back_to_readonly()

# ✓ after
catch e
    e isa WritesDisabledError && fall_back_to_readonly()
```

A `catch UnsupportedConnectionError` around a query that might hit a backend limit must become
`catch BackendCapabilityError`; one guarding against a missing driver becomes
`catch InvalidConfigurationError`.

---

## Read a caught `PormGError` with `error_message`, not `e.msg` (#261)

- **Version**: 0.4.0
- **PormG ref**: issue #261 ; `src/exceptions.jl` (`error_message`, `PoolError`), `src/Kernel.jl`
  and `src/PormG.jl` (exports), `src/ConnectionPool.jl` (reparenting), `docs/src/api.md`
- **Recorded**: 2026-07-29
- **Severity**: **corrective** — no PormG behavior changed, so nothing that worked before stops
  working. It is logged here rather than treated as an additive feature (which this file excludes)
  because **apps that followed #239's advice may already carry a latent bug**: #239 told you to
  `catch PormGError`, and the natural next line, `e.msg`, throws a `FieldError` on four of the
  sixteen subtypes. Fixing that is a real app edit, which is what this entry exists to prompt.

### What changed

**1. `error_message(e)` is the uniform way to read any PormG error.**

#239 told you to `catch PormGError`. The obvious next line is `e.msg` — and that works for 12 of
the 16 concrete subtypes, then throws a `FieldError` on the four built from structured fields:
`DoesNotExist`, `MultipleObjectsReturned`, `PoolTimeoutError`, `PoolConnectError`. Those four
carry richer data (`model_name`, `adapter`, `pool_size`, `attempts`, …) instead of a flat string,
which is better design — there was just no uniform way to get text out of them.

`error_message` is defined through `showerror`, which every subtype implements, so it also stays
correct for subtypes added later. It never returns less than `e.msg` did: for most subtypes it is
exactly that field, and for the few with their own `showerror` it returns the richer rendering.

**2. `PoolError` is the new abstract umbrella over `PoolTimeoutError` / `PoolConnectError`.**

Matching `ConfigurationError` and `MigrationError`. `catch PoolError` now handles pool saturation
and connect failure without naming both; catching either concrete type still works unchanged.

### How to find the calls to migrate

```
rg -n '\.msg' <app> | rg -i 'catch|err|exception'
```

Look for anything reading `.msg` off a **caught** PormG error. A site that catches a specific
`msg`-carrying subtype (`FilterError`, `QueryBuildError`, …) is fine as-is; the risk is a site that
catches the broad `PormGError` and then reads `.msg`, because that path can now receive one of the
four structured types.

### Migrate your app

```julia
# ✗ before — throws FieldError if `e` is a pool/cardinality error
try
    M.Result.objects.filter("driverid__surname" => "Senna").update("points" => 25)
catch e
    e isa PormGError && @error "write failed" msg=e.msg
    rethrow()
end

# ✓ after — one accessor, every subtype
try
    M.Result.objects.filter("driverid__surname" => "Senna").update("points" => 25)
catch e
    e isa PormGError && @error "write failed" msg=error_message(e) type=typeof(e)
    rethrow()
end
```

And, optionally, collapse a two-branch pool catch:

```julia
# ✗ before
catch e
    (e isa PoolTimeoutError || e isa PoolConnectError) && back_off()

# ✓ after
catch e
    e isa PoolError && back_off()
```

---

## The `PormGError` taxonomy now covers all of PormG — not just the query builder (#239)

- **Version**: 0.4.0
- **PormG ref**: issue #239 ; `src/exceptions.jl` (the taxonomy), `src/models/fields.jl`,
  `src/Models.jl`, `src/Dialect.jl`, `src/Configuration.jl`, `src/ConnectionPool.jl`,
  `src/migrations/*`, `src/PormG.jl`, `src/querybuilder/execution.jl`, `docs/src/api.md`
- **Recorded**: 2026-07-28
- **Severity**: **breaking (error contract)** — completes what #231 started. Field constructors,
  model definition, configuration, the SQL dialect, the connection pool and the migration engine now
  raise `PormGError` subtypes instead of bare `ArgumentError`. Part of the `0.3.x` pre-publish wave.

### What changed

#231 typed the query builder and explicitly left the rest as `ArgumentError`. That half-migrated state
was the worst of both worlds: `catch PormGError` *looked* like it covered PormG, then a model-definition
mistake sailed straight past it. Every `throw(ArgumentError(...))` in `src/` is now a semantic type,
except two genuine Julia-level API misuses in `src/tools.jl` (a missing kwarg, a missing path).

| Subtype | Now raised by |
|---------|---------------|
| `ModelDefinitionError` | model/schema definition — more than one primary key, duplicate `related_name`, illegal field name, a `UniqueConstraint` naming an unknown or M2M field, an unresolvable `ForeignKey`/`ManyToManyField` target, `Model(...)` given a non-`PormGField` |
| `FieldValidationError` | **every** field-constructor rejection — a kwarg of the wrong type (`unique="yes"`), an out-of-range `max_length`, a `default=` violating the field's own contract, a malformed `choices`, `decimal_places > max_digits`, or a `FloatField`/`DecimalField` used as a primary key |
| `InvalidValueError` | the `Models.format_*_sql` coercion family — duration, UUID, JSON, number, bool, date, timezone, `yyyy_mm` — plus `Dialect`'s "the value must be a String" guards |
| `ConfigurationError` *(abstract)* | umbrella; `InvalidConfigurationError` for an unsupported adapter, unknown connection key, malformed `extensions`, a pool that was never built; `MissingDatabaseConfigurationException` is now **inside** this bucket |
| `MigrationError` *(abstract)* | umbrella; `InvalidMigrationError` for a duplicate index name, an invalid interactive `makemigrations` answer, an unimplemented `migrate_to(version)`; `DestructiveMigrationError` is now **inside** this bucket |
| `UnsupportedConnectionError` | backend-capability rejections — the PG-only JSONB `@jcontains`/`@has_key`/`@has_any_keys`/`@has_keys` lookups, `iunaccent_*`/`niunaccent_*`, an extract part SQLite lacks, too old a SQLite library, an importer pointed at the wrong backend |
| `QueryBuildError` | `on_conflict_clause` argument shape; `atomic(durable=true)` nested inside another transaction |

**Definition-time vs value-time.** `FieldValidationError` fires while *defining* a model
(`IntegerField(unique="yes")`, `UUIDField(default="nope")`); `InvalidValueError` fires while coercing a *value* on the insert/update
path (`Models.format_uuid_sql("nope")`). Both were `ArgumentError` before, so an app that lumped them
together must now decide which it meant.

### How to find the calls to migrate

```
rg -n 'catch|@test_throws|isa' <app> | rg 'ArgumentError|ErrorException'
```

After #231 you were told to leave field- and model-definition catches alone. **Revisit exactly those** —
they are what changed here. Also check `catch` blocks around `Configuration.load`, `register_connection`,
`makemigrations`/`migrate`, `import_models_from_*`, `pool_stats`, and any model-definition module.

Field constructors are the largest single group (248 throw sites across the 26 `*Field` types), so any
app that builds models dynamically and guards the call is affected:

```julia
# ✗ before
try; Models.CharField(max_length = user_supplied); catch e; e isa ArgumentError && fallback(); end
# ✓ after
try; Models.CharField(max_length = user_supplied); catch e; e isa PormG.FieldValidationError && fallback(); end
```

### Migrate your app

```julia
# ✗ before — model/config/migration failures were plain ArgumentErrors
try
    PormG.Configuration.load("db_2")
    include("db/models.jl")
    PormG.Migrations.migrate("db_2")
catch e
    e isa ArgumentError && @error "setup failed" exception=e
    rethrow(e)
end

# ✓ after — catch the category, or PormGError for anything PormG rejected
try
    PormG.Configuration.load("db_2")
    include("db/models.jl")
    PormG.Migrations.migrate("db_2")
catch e
    e isa PormG.ConfigurationError    && return fix_connection_yml(e)   # incl. a missing connection.yml
    e isa PormG.ModelDefinitionError  && return report_bad_model(e)
    e isa PormG.MigrationError        && return halt_deploy(e)          # incl. a refused destructive plan
    e isa PormG.PormGError            && return handle_pormg_error(e)
    rethrow(e)
end
```

The two abstract umbrellas are deliberate: `catch ConfigurationError` also catches a missing
`connection.yml`, and `catch MigrationError` also catches `DestructiveMigrationError`. Catching the
bucket has no holes.

---

## 0.3.0 — 2026-07-24

## Query-builder errors are a typed `PormGError` taxonomy — stop catching `ArgumentError` (#231)

- **Version**: 0.3.0
- **PormG ref**: issue #231 ; `src/PormG.jl` (abstract root + exports), `src/querybuilder/exceptions.jl`
  (subtypes + `showerror` + `_write_not_allowed`), the throw sites across `src/querybuilder/*.jl`,
  `docs/src/api.md`
- **Recorded**: 2026-07-24
- **Severity**: **breaking (error contract)** — every query-builder misuse now raises a subtype of
  `PormGError` (`<: Exception`) instead of a bare `ArgumentError`/`ErrorException`. The subtypes are
  **NOT** `<: ArgumentError` (a clean break), so `catch ArgumentError` / `occursin(text, e.msg)` blocks
  around PormG query calls stop matching. Part of the `0.3.x` pre-publish wave; extends the #197
  typed-exception lineage. **Supersedes the type in the #205 entry below:** the standardized
  write-disabled error is now `PermissionError`, not `ArgumentError`.

### What changed

Query-builder failures now carry a semantic **type**, so callers react programmatically instead of
matching a message string. The root is `PormGError <: Exception`; catch it for any query-builder
failure, or a specific subtype:

| Subtype | Raised when |
|---------|-------------|
| `UnknownFieldError` / `LazyTraversalError` (both `<: FieldAccessError`) | field/column/`__`-path not found; or an unprojected `ForeignKey` read off a fetched row (steer to `values(...)`) |
| `FilterError` | invalid filter argument/shape; operator misuse on a JSON/subquery column |
| `QueryBuildError` | structural/API misuse (joins, CTEs, projection, ordering, window/bulk config) — the long-tail default |
| `UnsafeMutationError` | `update()`/`delete()` without a filter (or another unsafe shape) |
| `InvalidValueError` | value coercion/type mismatch on insert/update; identifier-safety guard; interval/duration parse |
| `PermissionError` | connection not allowed to insert/update/delete (`change_data=false`) — this is the #205 write-disabled error, now typed |
| `UnsupportedConnectionError` | connection is neither PostgreSQL nor SQLite, or a model is not bound to a connection |
| `DoesNotExist` / `MultipleObjectsReturned` | `get()` found zero / more than one row (reparented under `PormGError`) |

**Out of scope in `0.3.0` (still `ArgumentError` at the time):** field-constructor validation
(`src/models/fields.jl`) and model/schema-definition errors (`src/Models.jl`). ⚠️ **This is no longer
true** — #239 migrated them; see *"The `PormGError` taxonomy now covers all of PormG"* above. Do not
plan a migration from this paragraph.

### How to find the calls to migrate

```
rg -n 'catch|@test_throws|isa' <app> | rg 'ArgumentError|ErrorException'
```

Focus on blocks wrapping PormG query calls (`filter`/`values`/`update`/`delete`/`get`/row access/`bulk_*`).
Field-definition and model-definition errors still throw `ArgumentError` — leave those. ⚠️ **This is no
longer true** — #239 retyped them to `FieldValidationError` / `ModelDefinitionError`. If you already
migrated on this instruction, revisit exactly those catches; see *"The `PormGError` taxonomy now covers
all of PormG"* above.

### Migrate your app

```julia
# ✗ before — coupled to the message wording (incl. the #205 write-disabled catch)
try
    run_query()
catch e
    e isa ArgumentError && occursin("not allowed to write", e.msg) && fall_back_to_readonly()
    rethrow(e)
end

# ✓ after — catch the semantic type, or the abstract root for any query-builder misuse
try
    run_query()
catch e
    e isa PormG.PermissionError    && return fall_back_to_readonly()  # the #205 write-disabled case
    e isa PormG.LazyTraversalError && return steer_to_projection()    # unprojected FK read
    e isa PormG.PormGError         && return handle_pormg_error(e)    # anything the QB rejected
    rethrow(e)
end
```

---

## `connection.yml` env selection: `env:` → `default_env:`; `load()` fails loud on a missing config (#205)

- **Version**: 0.3.0
- **PormG ref**: issue #205 ; `src/Configuration.jl`, `src/Generator.jl`,
  `src/querybuilder/{exceptions,execution,execution_bulk,many_to_many,deletion}.jl`,
  `README.md`, `docs/src/{index,configuration/connection_yml,configuration/setup}.md`
- **Recorded**: 2026-07-24
- **Severity**: **behavior change** — three parts, all with clear, cheap migrations. Most apps: just
  rename the yaml key. Part of the `0.3.x` pre-publish wave — roll it forward together with the
  other `0.3.*` entries.

### What changed

1. **`env:` → `default_env:` (yaml).** The top-level `env:` key was always **inert** — the code that
   read it had been commented out, so `env: prod` silently did nothing. It is renamed to
   `default_env:` and given a real job: the **lowest-priority** environment default. Resolution
   precedence, first wins: **`env=` kwarg › `ENV["PORMG_ENV"]` › file `default_env:` › `"dev"`.**
   A leftover bare `env:` key is ignored and PormG **warns once per file** to rename it. `default_env:`
   is optional — omit it and PormG uses `dev`.
2. **`load()` fails loud on a missing config.** `PormG.Configuration.load(path)` used to scaffold a
   skeleton, log an `@error`, and `return nothing` when the folder/yml was missing — a typo'd path
   became a silent no-op that resurfaced later as a confusing settings-lookup error. It now **throws**
   `MissingDatabaseConfigurationException` (newly defined; the name was previously thrown-but-undefined,
   so a missing env block raised `UndefVarError`). First-run scaffolding is now explicit:
   `PormG.setup(path)` or `load(path; scaffold=true)`. A missing env block error now lists the
   available blocks.
3. **Write-disabled message standardized.** The `change_data: false` guard's error is unified across
   all write paths (insert / update / delete / update_or_create / bulk_insert|copy|update /
   many-to-many add|remove|clear / primary-key allocation): it now reads *"…is not allowed to write.
   … set `change_data: true` under the `config:` block…"* Only code that **string-matched** the old
   per-operation wording (`not allowed to insert`/`update`/`delete`) is affected.

### How to find the calls to migrate

```
rg -n '^env:' <app>/**/connection.yml                    # 1. rename the dead key → default_env: (or delete)
rg -n 'Configuration\.load\(' <app>/src                  # 2. any load() that relied on auto-scaffold-on-missing (rare)
rg -n 'not allowed to (insert|update|delete)' <app>/src  # 3. catch blocks string-matching the old write message
```

### Migrate your app

```yaml
# ✗ before — inert; selected nothing
env: dev

# ✓ after — an optional lowest-priority default; omit it entirely and PormG uses `dev`
default_env: dev
```

```julia
# load() on a missing/typo'd path was a silent no-op (scaffold + nothing) → it now THROWS.
# If you relied on load() creating the skeleton, be explicit:
PormG.Configuration.load("db"; scaffold=true)      # or: PormG.setup("db")

# A catch that keyed on the old per-op write message → match the TYPE. #231 (same 0.3.0 train)
# retyped this error to `PormG.PermissionError`, which is deliberately NOT <: ArgumentError —
# so an `e isa ArgumentError` catch here would silently stop matching. No message check needed.
catch e
    e isa PormG.PermissionError && handle()
```

The recommended server pattern is unchanged and preferred: let the host resolve its environment and
pass it explicitly — `load(...; env=current_env())` — so `connection.yml` is identical across
environments. `default_env:` is a convenience for scripts/single-env apps.

---

## Public naming settled — ToChar, formatter, aggregate, M2M `add`/`remove`/`clear`/`set`, setup unexported (#201)

- **Version**: 0.3.0
- **PormG ref**: issue #201 ; `src/querybuilder/{functions,types,many_to_many}.jl`, `src/models/fields.jl`,
  `src/PormG.jl` exports, `docs/src/{api,many_to_many,import_django}.md`
- **Recorded**: 2026-07-24
- **Severity**: **breaking (renames)** — pre-publish naming pass; every rename is old-name-gone, no aliases.
  Part of the `0.3.x` pre-publish wave — roll it forward together with the other `0.3.*` entries.

### What changed

| Old | New | Surface |
|-----|-----|---------|
| `To_char(x, fmt; formater=…)` | `ToChar(x, fmt; formatter=…)` | `PormG.Functions` export (only non-PascalCase name in the library) |
| `formater` (kwarg + struct field) | `formatter` | `Extract`/`ToChar`/math-function kwarg; fields on `FObject`/`WindowFunction` **and** all model-field structs |
| `agregate` (struct field) | `aggregate` | `InstructionObject`/`FExpression`/`FObject`/`WindowFunction` internals |
| `manager.add!/remove!/clear!/set!` | `manager.add/remove/clear/set` | M2M manager mutators (Django parity; bang implied "mutates a Julia arg", which these don't — they mutate the DB; see the rationale note in `docs/src/many_to_many.md`) |
| `setup` / `install_ai_skills` (exported) | `PormG.setup()` / `PormG.install_ai_skills()` (qualified-only) | top-level exports removed; behavior unchanged |
| `InstrucObject` | `InstructionObject` | internal QB struct (public-adjacent docstrings) |

**Deliberate non-change:** `bulk_insert` keeps its name (Django's `bulk_create` is a different API —
DataFrame-first, `on_conflict=` kwarg; documented in `docs/src/import_django.md`, "API Naming
Differences from Django").

### How to find the calls to migrate

```
rg -n 'To_char|formater|agregate|InstrucObject'        # renames: mechanical old → new
rg -n '\.(add|remove|clear|set)!\('                    # M2M mutators: drop the !
rg -n '(^|[^.\w])(setup|install_ai_skills)\('           # bare calls → prefix with PormG.
```

The first two are safe find-and-replace (whole-word). For the third, only *unqualified* calls need
the `PormG.` prefix — `PormG.setup()` calls keep working as-is.

---

## `PormG.QueryBuilder` export prune — `query`/`update`/`page` no longer dumped; `OP` internal; `With` import-only (#202)

- **Version**: 0.3.0
- **PormG ref**: issue #202 (follow-up to #35) ; `src/QueryBuilder.jl`, `src/documentation/querybuilder.jl`, `docs/src/{api,read/subqueries_and_ctes}.md`
- **Recorded**: 2026-07-25
- **Severity**: **breaking (submodule export surface)** — affects only code that does a **bare**
  `using PormG.QueryBuilder` and relied on the dumped names, or imported `OP`. The top-level
  `using PormG` surface is unchanged, and the idiomatic `.with()` / `"field__@op"` forms are unchanged.

### What changed

Curating the `#35` export surface one level deeper, inside the `PormG.QueryBuilder` submodule:

- **`query`, `update`, `page` are no longer exported** — a bare `using PormG.QueryBuilder` no longer
  dumps these three generic names into scope (the exact collision class `#35` removed at top level).
  They stay **defined**: explicit `import PormG.QueryBuilder: page` / `using PormG.QueryBuilder: update`
  still work, and the fluent `.page()` / `.update()` methods are unaffected.
- **`OP` is now internal** — un-exported *and* un-documented. Build operator predicates with the
  public string form `"field__@op" => value`; `OP` stays reachable as `PormG.QueryBuilder.OP` for the
  rare function-expression case.
- **`With` is import-only** — reachable via `using PormG.QueryBuilder: With` (the docs teach this); the
  idiomatic form is the fluent `.with(name => subquery; join_field=…)`.

### How to find the calls to migrate

```
rg -n 'using +PormG\.QueryBuilder\s*$' <app>/src     # bare submodule dump that relied on query/update/page
rg -n '\bOP\(' <app>/src                              # OP used after a bare submodule `using`
```

### Migrate your app

```julia
# ✗ before — the bare dump brought query/update/page (+ OP/With) into scope
using PormG.QueryBuilder

# ✓ after — import exactly the names you use
using PormG.QueryBuilder: page, With        # (whichever you actually reference)
q.filter("points__@gte" => 20)              # operator predicates: prefer the string form over OP(...)
```

Apps that use only the top-level `using PormG` surface, or the fluent `.page()` / `.update()` /
`.with()` methods, need **no** change.

---

## Removed `Base.first` type piracy — curried `first(; kwargs…)` form (#200)

- **Version**: 0.3.0
- **PormG ref**: issue #200 ; `src/querybuilder/execution.jl`
- **Recorded**: 2026-07-24
- **Severity**: **breaking (method removal)** — but the removed form was undocumented, unexported, and
  used nowhere in-repo, so real impact is expected to be nil. Bumped `y` anyway because the method was
  globally reachable, so `compat = "0.2"` should reject it.

### What changed

The convenience method

```julia
first(; kwargs...) = (objct) -> first(objct; kwargs...)   # removed
```

was **type piracy**: a zero-positional method on `Base.first` with no PormG type in its signature, so
after `using PormG` it claimed the global `Base.first(; kwargs…)` call for every module in the process.
There is no piracy-free version (a nullary method on someone else's function has no owned type to
anchor it), so it was removed. The normal ergonomics are unaffected — only passing keywords *inside a
pipe* is gone, and it has a direct equivalent:

```julia
# ✗ before — curried, kwargs-in-a-pipe (the only removed form):
sql = M.Driver.objects.filter("nationality" => "British") |> first(show_query = :sql)

# ✓ after — pass the handler explicitly (or use the method form):
sql = first(M.Driver.objects.filter("nationality" => "British"); show_query = :sql)
sql = M.Driver.objects.filter("nationality" => "British").first(show_query = :sql)
```

Still valid, untouched: `q.first()`, `first(q)`, `q.first(show_query=:sql)`, the bare pipe
`q |> first` (that's `first(q)`), and `list() |> first` (that's `Base.first(::Vector)`). The sibling
curried forms `delete(; kwargs…)` / `inspect_query(; kwargs…)` are **not** affected — those functions
are package-owned, so a kwargs-only method on them is not piracy.

### How to find the calls to migrate

Grep each app for a `first` that is piped **with keyword arguments** (bare `|> first` is fine):

```
rg -n '\|>\s*first\(' <app>/src        # curried first(...) in a pipe — the only form to change
```

---

## `first()` / `get()` no longer mutate the handler (#199)

- **Version**: 0.2.3
- **PormG ref**: issue #199 ; `src/querybuilder/execution.jl` (`first`, `get`),
  `docs/src/read/index.md` (new *Handler Mutation Model* section)
- **Recorded**: 2026-07-24
- **Severity**: footgun fix — **no action expected**. Classified non-breaking: the only affected
  code exploits `first()`'s documented limit-leak workaround or `get()`'s *undocumented*
  filter-persistence side effect.

### What changed

All read terminals now share one contract: they execute on an internal copy and never mutate the
handler. Previously `first()` permanently set `limit(1)` on the handler and `get(q, filters...)`
permanently appended its inline filters to it — `count`/`exists`/`list` already copied. Re-call
semantics of chain methods are unchanged (and now documented): `filter` accumulates,
`values`/`order_by` replace their previous call.

```julia
# ✗ before — handler reuse after first()/get() silently carried leaked state:
q = M.Driver.objects.filter("nationality" => "British")
q.first()                                # left limit=1 on q
q.list()                                 # returned 1 row (leaked limit)
q.update("nationality" => "English")     # threw: UPDATE with LIMIT is not supported

r = M.Result.objects
r.get("resultid" => 1)                   # appended the inline filter to r
r.count()                                # counted WHERE resultid = 1 (leaked filter)

# ✓ after — the handler is untouched; same calls, no leaked state:
q.first()                                # q unchanged (limit stays 0)
q.list()                                 # all matching rows
q.update("nationality" => "English")     # valid on the same handler

r.get("resultid" => 1)                   # r unchanged
r.count()                                # counts ALL results
```

### How to find the calls to migrate

Nothing to migrate unless an app **reuses a handler after** `.first()`/`.get()` *and relies on the
leaked state* (a limit-1 `list()`, or inline `get` filters narrowing later calls). Grep each app for
a handler variable used again after one of these terminals:

```
rg -n '\.(first|get)\(' <app>/src        # then eyeball: is that handler variable used again below?
```

One-handler-per-query code (the documented style) is unaffected.

---

## Typed exceptions across the query surface — raw-`String` throws are now `ArgumentError`/`ErrorException` (#197)

- **Version**: 0.2.0
- **PormG ref**: issue #197 ; `src/querybuilder/` (`build_helpers.jl`, `build_joins.jl`, `build_query.jl`,
  `ctes.jl`, `deletion.jl`, …), `src/Configuration.jl`, `src/migrations/planner.jl`
- **Recorded**: 2026-07-23
- **Severity**: **breaking (error type)** — ~46 raw-string `throw("...")` sites now raise typed
  exceptions. No new exported types (existing `ArgumentError`/`ErrorException` +
  `DoesNotExist`/`MultipleObjectsReturned`/pool errors cover the surface).

### What changed

Every `throw("...")` in the query builder — a bare `String`, which is **not** an `Exception` — plus
stragglers in `Configuration.jl` and `migrations/planner.jl` now throws a typed exception:

- `ArgumentError` for user misuse (bad args, unsupported `values()` pairs, malformed lookups, …);
- `ErrorException` (via the internal `_unsupported_conn` helper) for internal dispatch fallbacks;
- `bulk_insert`'s catch blocks now `@error` + `rethrow()`, so the original driver exception survives
  instead of being reduced to a string.

A raw `String` throw escaped every `catch e; e isa Exception` a package user could write — so any
error handling that expected a real exception silently failed to match. Now `e isa Exception` (and
`e isa ArgumentError`) behave as expected.

### How to find the calls to migrate

Grep each app for `catch` blocks that **string-match** a PormG error rather than catching a type:

```
rg -n "catch" <app>/src | rg -iE "isa String|occursin\("
```

Only handlers that string-matched a PormG throw are affected. A `catch e … rethrow()`, or a handler
already keyed on `ArgumentError`/`ErrorException`/`DoesNotExist`/`PoolTimeoutError`, needs no change.

### Migrate your app

```julia
# ✗ before — the throw was a bare String; `e isa String` was the only way to match, and
#            `e isa Exception` never fired
catch e
    e isa String && occursin("<PormG error text>", e) && handle()

# ✓ after — catch the typed exception; read the text off `.msg`
catch e
    e isa ArgumentError && occursin("<PormG error text>", e.msg) && handle()
```

If a handler only needs "PormG rejected this call", `e isa Exception` (or the narrower
`e isa ArgumentError`) now suffices — no string matching required.

---

<!-- ───────────────────────── pre-0.2 history (unstamped) ───────────────────────── -->

## Scalar correlated subqueries: `Subquery(...)` in `values()`; unsupported `values()` pairs now throw (#92)

- **PormG ref**: issue #92 (the supported fix for the #74 fan-out guard) ; `src/querybuilder/types.jl`,
  `src/querybuilder/object_manager.jl`, `src/querybuilder/build_query.jl`, `src/querybuilder/build_helpers.jl`,
  `src/QueryBuilder.jl`, `src/PormG.jl`
- **Recorded**: 2026-07-22
- **Severity**: **additive feature + one latent-bug fix to check.** New top-level export `Subquery`;
  `Exists(...)` is now also projectable in `values()`. The check: `values()` used to **silently drop** an
  unsupported `"alias" => <value>` pair — that column just vanished from the result. It now throws an
  `ArgumentError`. Only code that was already getting a wrong/missing column is affected.

### What changed

- **New:** `"alias" => Subquery(inner)` inside `values()` projects a scalar correlated subquery as a
  column. The inner query correlates via `OuterRef(...)` and must project exactly **one** column; an
  aggregate (`Count`, `Sum`, …) or a plain column with `order_by` + `limit(1)` both work. This is the
  fan-out-safe way to attach related-set aggregates — the construct the #74 guard's error message points
  to. Multiple independent `Subquery` columns compose in one query with no fan-out interaction.
- **New:** `"alias" => Exists(inner)` inside `values()` projects a per-row boolean column (SQLite `0`/`1`,
  PostgreSQL booleans). Previously `Exists` was filter-only.
- **Fail-loud fix:** an unsupported right side in a `values()` pair (e.g. `"x" => 42`, or any type the
  projection doesn't handle) now raises `ArgumentError` at `values()` time instead of being silently
  dropped from the SELECT list. Likewise, a **function pair that fails validation** (e.g.
  `"x" => Concat("surname", 42)` — constructs, but `_check_function` rejects the `Int`) used to be
  logged and silently dropped; it now propagates the original error (typically a `MethodError`) after
  logging the failing alias.
- Guard rails: the inner query must project exactly one column (else `ArgumentError`); the alias is
  mandatory (bare `Subquery(...)` throws); a `Subquery`/`Exists` projected *inside another subquery*
  throws (`OuterRef` resolves one level only); a non-aggregate inner with no `LIMIT` emits a build-time
  `@warn` (possible multi-row scalar).

### How to find the calls to migrate

Nothing to migrate for the new feature (additive). For the silent-drop fix, look for `values()` pairs whose
right side is not a field name, SQL function, `Value(x)`, `Subquery(...)`, or `Exists(...)`:

```
rg -n 'values\(' <app> | rg '=>'      # then eyeball non-standard right-hand sides
```

An affected call site was already broken (the column silently missing from results) — the throw makes it
visible.

### Migrate your app

- Nothing required. Optionally adopt `Subquery` where an app worked around the #74 guard with a
  CTE-aggregate join that only needed one scalar per row.

---

## `migrate()` is non-interactive-safe — throws `DestructiveMigrationError` in CI instead of hanging (#87)

- **PormG ref**: issue #87 ; `src/migrations/runner.jl`, `src/Migrations.jl`
- **Recorded**: 2026-07-21
- **Severity**: **behavior change (automation only)** — new exported `DestructiveMigrationError`. Affects
  only code that calls `migrate()` in a **non-interactive** context (CI, `Pkg.test`, deploy/cron script,
  piped stdin). Interactive `migrate()` at a real terminal is unchanged.

### What changed

`migrate()` defaulted `interactive=true` and called a bare `readline()` to confirm — with **no TTY
detection**. In a non-interactive process that either **hung** on stdin or read EOF and **silently applied
nothing** ("Migrations were not applied"). The safe-looking workaround `migrate(...; interactive=false,
destructive=true)` disabled *both* guardrails at once.

Now:

- The confirmation prompt shows **only when stdin is a real terminal** (`interactive && stdin isa
  Base.TTY`). `migrate()` never blocks on `readline()` in CI / `Pkg.test` / a deploy script.
- A **non-destructive** plan applies directly in a non-interactive context (previously a silent no-op).
- A **destructive** plan in a non-interactive context now **throws `DestructiveMigrationError`** (exported)
  unless `destructive=true` is passed — instead of silently returning `nothing`. Automation fails loudly
  with an actionable message.
- **Piped stdin** (`echo yes | julia … migrate("db")`) counts as non-interactive — it no longer bypasses
  the destructive gate; pass `destructive=true`.

Interactive terminal behavior is unchanged: you still get the yes/no prompt, and a destructive plan without
`destructive=true` still prints a red `@error` and aborts.

### How to find the calls to migrate

Grep each app for `migrate(` in automated contexts — CI steps, deploy/bootstrap scripts, anything run
without a TTY:

```
rg -n "migrate\(" <app>                 # focus on CI / deploy / cron entry points
rg -n "interactive\s*=\s*false" <app>
```

Two things to check at each non-interactive call site:

1. A `catch` / return-value check that assumed a destructive plan **silently returns `nothing`** — it now
   throws `DestructiveMigrationError`.
2. A call that passed `interactive=false` only to avoid a hang — that is now optional (auto-detected), but
   harmless to keep.

### Migrate your app

- Automated apply of a plan that *may* be destructive: pass the explicit opt-in —
  `migrate("db"; destructive=true)`. CI no longer hangs, and a missing opt-in is now a loud error, not a
  silent skip.
- If a script must tolerate "destructive plan present → skip, don't fail", catch it:
  ```julia
  try
      migrate("db")
  catch e
      e isa PormG.Migrations.DestructiveMigrationError || rethrow()
      @warn "Destructive migration skipped; apply manually with destructive=true" exception=e
  end
  ```
- Non-destructive automated migrations need no change — `migrate("db")` now applies them instead of
  silently no-op'ing.

---

## Connect fast-fail (`PoolConnectError`, `fail_fast_on_connect`)

- **PormG ref**: issue #72 (AC2; follow-up to #37/#124) ; `src/ConnectionPool.jl`, `src/Configuration.jl`,
  `src/Backend.jl`, `ext/PormGLibPQExt.jl`, `ext/PormGSQLiteExt.jl`, `src/PormG.jl`
- **Recorded**: 2026-07-18
- **Severity**: **mostly additive** (new exported `PoolConnectError`, opt-in `fail_fast_on_connect`, default
  on). **One behavior change to check:** an unopenable pool now raises `PoolConnectError`, not
  `PoolTimeoutError`. Only apps that *catch `PoolTimeoutError` specifically* around a connection failure
  need a look.

### What changed

`acquire_connection` used to treat "can't open a connection" (bad password, missing role/database,
unopenable SQLite path) the same as "healthy pool saturated": it waited the full `pool_timeout` (~30 s),
then threw `PoolTimeoutError` ("raise pool_size"). It now:

- **classifies** the driver error via a new backend hook (`backend_is_permanent_connect_error`): permanent
  = PostgreSQL auth / missing role|database, SQLite `unable to open database file`;
- **fast-fails** a permanent error immediately with a new catchable **`PoolConnectError`** (exported)
  carrying the driver `cause` + a redacted connection string (remedy: fix credentials, not `pool_size`);
- surfaces `PoolConnectError` (not `PoolTimeoutError`) for *any* connect failure that reaches the deadline,
  including ambiguous host/DNS errors (which are still waited out, not fast-failed);
- adds a `fail_fast_on_connect` config key (`connection.yml` + `register_connection` kwarg; default `true`)
  to opt out;
- (fix) redacts the connection string in SQLite pool logs, matching the PostgreSQL path.

A healthy-but-saturated pool still raises `PoolTimeoutError` — unchanged.

### How to find the calls to migrate

Grep each app for a `catch` that special-cases pool saturation on a connection acquire/fetch:

```
rg -n "PoolTimeoutError" <app>/src
```

If a handler means "the database is unreachable / misconfigured", widen it to also catch
`PoolConnectError` (or catch both). If it only means "pool is saturated, back off and retry", leave it —
`PoolConnectError` is intentionally a *different*, non-retryable signal.

---

## Connection-pool wait is now direct-handoff (event-driven), not a busy-poll

- **PormG ref**: issue #124 (follow-up to #37) ; `src/ConnectionPool.jl`
- **Recorded**: 2026-07-16
- **Severity**: internal mechanism — **no action needed**. `acquire_connection`'s signature
  (`timeout_seconds`, `max_retries`, SQLite `mode`) and the `PoolTimeoutError` fields are unchanged.

### What changed

When the pool is saturated, `acquire_connection` used to `sleep(0.1)` and rescan (up to the
timeout/retry budget). It now **parks** the caller and is woken the instant a connection is
released — the returner hands the freed slot *directly* to the oldest compatible waiter (FIFO, no
barging; HikariCP / Go `database/sql` style). Handoff latency drops from up to ~100 ms to
sub-millisecond, waiters are served fairly, and there is no more per-100 ms rescan spam. A genuine
saturation still throws the same catchable `PoolTimeoutError`.

### Nothing to grep

No API changed. One **diagnostic** nuance: `PoolTimeoutError.attempts` now counts scan iterations
(typically `1` on a clean saturated timeout) rather than the old ~`timeout/0.1s` poll count. If you
log or assert on `attempts`, expect a much smaller number; it remains `>= 1`.

---

## `create()` / `insert()` return a `PormGRow` (was `Dict`)

- **PormG ref**: issue #166 ; `src/querybuilder/execution.jl`
- **Recorded**: 2026-07-16
- **Severity**: **breaking (return type)** / behavior improvement — the row surface is now uniform.

### What changed

`create()` / `insert()` now return a **`PormGRow`** on the execute path — the same row object
`get()`, `first()`, `list()`, and `update_or_create()` already return — instead of a bare
`Dict{Symbol,Any}`. This makes the row surface consistent and lets a created row be mutated and
`.save()`d:

```julia
row = M.Driver.objects.create("forename" => "Ayrton", "surname" => "Senna")
row[:driverid]        # unchanged — PormGRow delegates indexing/haskey/keys/get/pairs/iterate
row.surname           # now also works (dot-access)
row.surname = "SENNA"; row.save()   # and it round-trips
```

`show_query=:sql/:dict/:params` still return their inspection shapes (String/Dict/Vector) — only the
`:execute` return changed. `list(:dict)` and `values()` still return plain dicts. `update()` still
returns a matched-row count.

### How to find the calls to migrate

Because `PormGRow` delegates `getindex`/`haskey`/`get`/`keys`/`values`/`pairs`/`iterate`, the common
patterns (`row[:id]`, `haskey(row, :x)`, iterating pairs) keep working unchanged. Only these break:

```
# 1. Type checks that assumed a Dict:
grep -rn "create(" src/ | grep -i "isa Dict"
grep -rn "= .*\.create(" src/            # then check for `isa Dict`, `merge(`, `delete!(`

# 2. Dict-only MUTATION of a create() result (PormGRow has no setindex!):
grep -rn "\.create(" src/ | ...          # then look for `result[:x] = ...` on that result
```

### Migrate your app

- `@assert result isa Dict` → `@assert result isa PormG.QueryBuilder.PormGRow` (or drop the type
  check — field access is unchanged).
- Adding/overwriting a key on the result: `result[:x] = v` → `result.x = v` (dot-assign), and
  `result.save()` if you want it persisted. (Read access `result[:x]` is unchanged.)
- Passing the result somewhere typed `::Dict`, or `merge(result, …)` / `collect(result)` /
  `length(result)` / `result == Dict(…)`: convert first with `Dict(pairs(result))`.

---

## Connection errors inside `run_in_transaction` now propagate (no silent statement retry)

- **PormG ref**: issue #138 ; `src/ConnectionPool.jl`
- **Recorded**: 2026-07-13
- **Severity**: behavior change (error now surfaces instead of a silent, broken retry)

### What changed

`fetch()`'s lost-connection recovery (renew the pooled connection, re-run the statement once)
no longer fires **inside a transaction context** or on a caller-pinned `conn`. Previously a
connection drop during e.g. `q.create(...)` inside `run_in_transaction` silently re-ran the
statement on a **fresh autocommit session** — committing a write that should have died with the
transaction — and released the transaction's pooled connection to the pool mid-transaction. Now
the connection error propagates out of the transaction block like any other failure; the wrapper
rolls back and renews/discards the pooled connection (#71). Plain `fetch()` outside transactions
keeps the transparent one-shot retry. This matches Django / SQLAlchemy / Rails 7.1 /
Go `database/sql`: never retry a statement inside a transaction — the application retries the
whole transaction.

### How to find the calls to migrate

Nothing to grep — no API changed. Only code that (unknowingly) relied on the mid-transaction
retry is affected: if a transaction block now fails with a driver connection error where it
previously appeared to succeed (with silently corrupted transactional semantics), wrap the
**whole** `run_in_transaction` call in an application-level retry.

### Migrate your app

```julia
# ✗ before: a connection drop mid-block silently committed the create OUTSIDE the transaction
# ✓ after: the block raises; retry the whole transaction if the work must survive reconnects
for attempt in 1:3
  try
    PormG.run_in_transaction("db_2") do
      (M.Pit_stops.objects).create(
        "raceid" => 841, "driverid" => 153, "stop" => 3, "lap" => 42,
        "time" => "17:05:23", "duration" => "22.500", "milliseconds" => 22500,
      )
    end
    break   # committed
  catch e
    attempt == 3 && rethrow()
  end
end
```

---

## `DateTimeField` values are canonicalized to UTC — existing **SQLite** rows must be re-normalized once

- **PormG ref**: issue #79 ; `src/Models.jl` (`format_timezone_sql` / `validate_timezone`)
- **Recorded**: 2026-07-13
- **Severity**: breaking (SQLite stored-data format) / behavior fix
- **This is a data change, not a code change** — the PormG API is unchanged; there are no call
  sites to edit. The rollout is a one-time SQLite data re-normalization.

### What changed

`DateTimeField` values are now canonicalized to a single UTC ISO-8601 string
(`yyyy-mm-ddTHH:MM:SS.sss+00:00`) on **both** the write/bind path and the filter path — the
convention Django (`USE_TZ=True`), Rails, and SQLAlchemy already use. Previously PormG stored
offset-bearing strings verbatim (e.g. `auto_now` under `America/Sao_Paulo` was written as
`…-03:00`, and a `Z` / `.0` filter value was passed through unchanged).

- **PostgreSQL** is transparent: `TIMESTAMPTZ` compares by instant, so filters were already
  correct and stored data is unaffected — nothing to do.
- **SQLite** stores datetimes as TEXT and compares them lexicographically, so the old
  non-canonical strings made equality/range filters **diverge from PostgreSQL** whenever the
  filter value's spelling differed from the stored spelling (issue #79). Going forward both the
  stored value and the filter value are canonical UTC, so the comparison is correct — **but
  rows written by the old code are still in their old spelling** and must be re-normalized once.

### Who is affected

- PostgreSQL-only apps → mark `—`.
- SQLite apps whose `DateTimeField` columns are empty or freshly created after this bump → mark `—`.
- SQLite apps with **pre-existing** `DateTimeField` data → run the one-time re-normalization below.

### Re-normalize existing SQLite data (one time)

The read path already reconstructs the correct instant from any offset spelling, so a
read-modify-write through PormG reuses PormG's own parser/formatter and is the safest recipe.
For each SQLite model + `DateTimeField` column:

```julia
# `col` is any DateTimeField column on `M.Thing` (SQLite backend).
for row in M.Thing.objects.values("id", "col").list()
    (ismissing(row[:col]) || row[:col] === nothing) && continue   # skip SQL NULL (surfaces as missing)
    q = M.Thing.objects
    q.filter("id" => row[:id])
    q.update("col" => row[:col])                # re-writing stores the canonical UTC form
end
```

(An equivalent single SQL `UPDATE` that converts each value to canonical UTC works too, but the
read-modify-write above avoids hand-rolling the offset math.) Verify with a `Z`-spelled value
that previously missed on SQLite:

```julia
@assert M.Thing.objects.filter("col" => "2020-01-01T10:00:00Z").exists()  # a known stored instant
```

---

## `distinct().order_by()` — the sort key must be in the projection (raises otherwise)

- **PormG ref**: issue #76 ; `src/querybuilder/build_query.jl`
- **Recorded**: 2026-07-13
- **Severity**: behavior change (new `ArgumentError`)

### What changed

A `DISTINCT` query that orders by a column outside its projection —
`.values("a").distinct().order_by("b")` with `b` not in `values(...)` — now raises a clear
`ArgumentError` on **both** backends. Previously PostgreSQL rejected it with a raw DB error while
SQLite silently ran it, returning rows in a nondeterministic `DISTINCT`/order interaction. Ordering a
`DISTINCT` result by an unprojected column is rejected by PostgreSQL and the SQL standard (SQL Server,
Oracle, DB2, and default-mode MySQL all reject it); PormG now makes SQLite conform too. The guard
matches the resolved SQL *expression*, so ordering by a *function of* a projected column
(`order_by("created_at__@date")` while only `created_at` is selected) is likewise rejected — that too
is a PostgreSQL error.

### How to find the calls to migrate

Run the app or its tests: the new error reads
`DISTINCT query cannot ORDER BY <col>: it is not in the SELECT DISTINCT projection`. Grep for
`.distinct()` and check each one's `order_by(...)` — every ordered column (or the exact ordering
expression) must also appear in `values(...)`. **Postgres-backed apps already errored on these; only
SQLite-tested queries could have been running silently.**

### Migrate your app

```julia
# ✗ raises: surname is ordered but not projected
M.Driver.objects.values("nationality").distinct().order_by("surname").list()

# ✓ include the sort key in values() (distinct is now over both columns) …
M.Driver.objects.values("nationality", "surname").distinct().order_by("surname").list()

# ✓ … or drop distinct() if you meant "one row per nationality, ordered by an aggregate"
M.Driver.objects.values("nationality", "n" => Count("driverid")).order_by("n").list()
```

---

## bulk ops `copy=` kwarg removed — the pipeline never mutates (and never copies) your DataFrame

- **PormG ref**: issue #132 / PR #137 ; `src/querybuilder/execution_bulk.jl`
- **Recorded**: 2026-07-12
- **Severity**: breaking (kwarg removed) / behavior improvement

### What changed

`bulk_insert`, `bulk_copy`, and `bulk_update` no longer accept `copy::Bool`. The old
default (`copy=true`) deep-copied the entire DataFrame on every call; `copy=false` let
ORM-side normalization (default fills, `auto_now` columns) leak into the caller's frame.
The pipeline now works on a **zero-copy wrapper** (shared column vectors): the caller's
DataFrame is **never mutated and never copied**, unconditionally — strictly better than
both old modes. `allocate_primary_keys` is unchanged: `clone=true` still returns an
independent copy (that frame is *returned* to the caller, so it must not alias your
data), and `clone=false` still writes the pk column in place.

### How to find the calls to migrate

Grep each app for `copy=` / `copy =` on `bulk_insert`/`bulk_copy`/`bulk_update` calls
(or just run the app: passing the removed kwarg raises
`MethodError: ... got unsupported keyword argument "copy"`).

### Migrate your app

```julia
# ✗ before
bulk_insert(query, df, copy=true)    # paid a full deepcopy
bulk_update(query, df, columns=["points"], match_on=["id"], copy=false)  # mutated df

# ✓ after — just drop the kwarg; no-mutation is now the unconditional contract
bulk_insert(query, df)
bulk_update(query, df, columns=["points"], match_on=["id"])
```

If an app relied on `copy=false` to *receive* the injected columns (e.g. reading
`df.updated_at` after the call), that back-channel is gone — read the values back
through a query instead.

One subtle semantics shift: the old `copy=true` gave the bulk op a private *snapshot*
of your data; the zero-copy wrapper reads your live column vectors **during** the call.
Don't mutate the DataFrame from another task while a bulk op is executing on it (this
was never supported — it just happened to be masked by the default deepcopy).

---

## `bulk_update(match_on=)` — pairs removed; `columns=` is the single df→field mapping point

- **PormG ref**: issue #107 / PR #135 ; `src/querybuilder/execution_bulk.jl`
- **Recorded**: 2026-07-12
- **Severity**: breaking

### What changed

`match_on=` no longer accepts `"df_col" => "model_field"` pairs. It takes **bare model
field names** only; `columns=` is now the **single place** a DataFrame column is mapped
to a model field ("one border crossing"). A field listed in both `columns=` and
`match_on=` is used for **matching only — it is never SET** (this was already true).
A bare `match_on` name resolves its source column **mapping-first**: the `columns=`
mapping when declared (authoritative — a same-named DataFrame column is ignored with a
warning), otherwise a DataFrame column with the field's own name.

### How to find the calls to migrate

Run the app or its tests: every old pair raises
`bulk_update: match_on= no longer accepts "df_col" => "model_field" pairs (DEPRECATED API)`
with the exact rewrite. Or grep for `match_on` and inspect any entry containing `=>`.

### Migrate your app

```julia
# ✗ before
bulk_update(query, df,
    columns  = ["new_score" => "points"],
    match_on = ["record_id" => "id"])

# ✓ after — the pair moves to columns=; match_on keeps the bare field name
bulk_update(query, df,
    columns  = ["new_score" => "points", "record_id" => "id"],
    match_on = ["id"])
```

Bare-name calls (`match_on = ["id"]` with an `id` DataFrame column, or relying on the
primary-key fallback) need no change.

---

## `SQLOrder` orientation is now whitelisted — only `"ASC"`/`"DESC"` (case-insensitive) construct and render

- **PormG ref**: issue #77 / PR #133 ; `src/querybuilder/types.jl`, `src/querybuilder/build_query.jl`
- **Recorded**: 2026-07-12
- **Severity**: behavior change (new `ArgumentError`; closes an injection seam)

### What changed

A directly constructed `SQLOrder` used to accept **any** string as `orientation` and interpolate
it verbatim into the rendered `ORDER BY` — a SQL-injection seam for apps forwarding a
user-controlled sort direction. Every construction path (and render, guarding post-construction
mutation) now normalizes (`uppercase` + `strip`) and whitelists against `"ASC"`/`"DESC"`, raising
`ArgumentError` for anything else. The documented string API — `.order_by("field")` /
`.order_by("-field")` — was always safe and is unchanged.

### How to find the calls to migrate

Grep the app for direct `SQLOrder(` construction. Only call sites passing a *dynamic*
(user- or data-derived) `orientation` need action; literal `"ASC"`/`"DESC"` in any case keep
working.

### Migrate your app

```julia
# ✗ before — a user-controlled direction string reached the SQL verbatim
dir = params["dir"]   # e.g. "ASC; DROP TABLE results" used to render as-is
query.order_by(SQLOrder(SQLField("points", "points"); orientation = dir))

# ✓ after — map untrusted input onto the whitelist yourself (or handle the ArgumentError)
query.order_by(SQLOrder(SQLField("points", "points");
    orientation = lowercase(dir) == "desc" ? "DESC" : "ASC"))
```

---

## Pool exhaustion now raises typed `PoolTimeoutError`; expansion ceiling raised to `pool_size × 10`

- **PormG ref**: issue #37 / PR #129 ; `src/ConnectionPool.jl`
- **Recorded**: 2026-07-12
- **Severity**: behavior change (error type changed; pool sizing change)

### What changed

Exhausting the connection pool used to throw a **bare `String`** after a noisy busy-retry loop.
Both the PostgreSQL and SQLite acquire paths now throw `PormG.PoolTimeoutError` (exported; fields
`adapter` / `pool_size` / `max_size` / `attempts` / `elapsed`, with a "raise pool_size" remedy in
`showerror`). The lazy expansion ceiling grew from `pool_size × 5` to `pool_size × 10` (default
pool: 3 base → up to 30 on demand; idle footprint unchanged), and per-retry logging dropped to
`@debug` — a single actionable `@warn` fires only when the pool hits its ceiling.

### How to find the calls to migrate

Grep the app for `catch` blocks that match the old exhaustion message as a string
(e.g. `occursin("No available"` …). Most apps have none — then there is nothing to change; the
new error type and quieter logs just apply.

### Migrate your app

```julia
# ✗ before — the only way to detect exhaustion was string-matching a bare String throw
catch e
    e isa String && occursin("No available", e) && back_off()

# ✓ after — catch the typed error; consider raising pool_size in connection.yml if it fires
catch e
    e isa PormG.PoolTimeoutError || rethrow()
    back_off()
```

---

## `order_by` on nullable columns — NULL placement normalized to PostgreSQL's convention on both backends

- **PormG ref**: issue #75 / PR #120 ; `src/querybuilder/build_query.jl`
- **Recorded**: 2026-07-12
- **Severity**: behavior change (result order can change on SQLite)

### What changed

Top-level `ORDER BY` used to render a bare `expr ASC|DESC`, and PostgreSQL and SQLite default
NULLs to **opposite ends** — so ordering a nullable column returned different rows per backend,
and with `.first()` / `.page()` that changed *which* rows you got. PormG now emits an explicit
NULLS clause matching PostgreSQL's default on **both** backends: ASC → `NULLS LAST`,
DESC → `NULLS FIRST` (SQLite < 3.30.0 gets an equivalent portable `(expr IS NULL)` prefix).
Per-term override: `SQLOrder(field; nulls = :first | :last)`. Window `OVER(...)` ordering is
**not** yet normalized (follow-up pending).

**PostgreSQL-backed apps see no change.** SQLite-backed apps: any `order_by` on a nullable key
may now sort NULL rows to the other end.

### How to find the calls to migrate

No API change and nothing errors. In SQLite-backed apps, review `order_by` calls on **nullable**
columns whose consumers depend on row order — `.first()`, pagination, "top N" reports.

### Migrate your app

```julia
# Only if the app depended on SQLite's old NULLS-first-on-ASC ordering — pin it explicitly:
using PormG.QueryBuilder: SQLOrder, SQLField

M.Driver.objects.values("surname", "nationality").order_by(
    SQLOrder(SQLField("nationality", "nationality"); orientation = "ASC", nulls = :first)
).list()
```

---

## `bulk_copy` — field formatters now applied; `""` and `missing` no longer collapse to NULL

- **PormG ref**: issue #86 / PR #115 ; `src/querybuilder/execution_bulk.jl`
- **Recorded**: 2026-07-12
- **Severity**: behavior change (persisted values can differ)

### What changed

`bulk_copy` wrote **raw** DataFrame values (each field's formatter result was validated, then
discarded), so datetime/bool/float values could silently diverge from what `bulk_insert` /
`create()` store; and the COPY payload carried no NULL marker, collapsing `""` and `missing`
into the same NULL. It now formats every cell exactly like `bulk_insert` and serializes with a
`\N` NULL sentinel: `missing` → SQL `NULL`, `""` → empty string, and the two round-trip
distinctly.

### How to find the calls to migrate

No API change. Review `bulk_copy` call sites that (a) pre-formatted datetimes/bools/floats to
compensate for the old raw write — the workaround is now redundant (but harmless), or
(b) relied on empty strings being stored as NULL.

### Migrate your app

```julia
# The old behavior stored NULL for BOTH of these; they now persist differently:
df = DataFrames.DataFrame(surname = ["Senna", "Prost"], code = ["", missing])
bulk_copy(M.Driver.objects, df)   # row 1 code → '' (empty string), row 2 code → NULL

# Keep the NULL semantics only where you actually want it — coerce before the call:
df[!, :code] = map(x -> !ismissing(x) && x == "" ? missing : x, df[!, :code])
```

---

## Template for new entries

<!--
Copy the block below into the `## Unreleased` section at the top of the log for each new
breaking/behavior change. Do NOT bump `Project.toml` — the version moves once, at cut time
(the `/pormg-cut-release` skill rewrites `Version: Unreleased` → the release number).

## `<api>` — <one-line summary of the change>

- **Version**: Unreleased
- **PormG ref**: <issue / PR / commit> ; <src file>
- **Recorded**: <YYYY-MM-DD>
- **Severity**: breaking | behavior change | deprecation

### What changed
<what the old API did vs. the new contract>

### How to find the calls to migrate
<error message to grep for, or the call pattern>

### Migrate your app
```julia
# ✗ before
...
# ✓ after
...
```

-->
