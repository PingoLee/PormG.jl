## The Django app prefix moves to `db_table`, and short-form join paths stop needing it (#345)

- **Version**: 0.5.0
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
