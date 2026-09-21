## `AutoField` is retired, and introspection reports the real field type (#408, #409, #417)

- **Version**: 0.5.0
- **Recorded**: 2026-08-25
- **PormG ref**: #408, #409, #417; `src/models/fields.jl`, `src/Dialect.jl`,
  `src/migrations/introspection.jl`, `src/migrations/importers.jl`, `docs/src/fields.md`,
  `docs/src/models.md`, `docs/src/import_django.md`, `docs/src/write/bulk.md`
- **Severity**: **breaking (source)** for anyone declaring `Models.AutoField()`, and **breaking
  (schema)** for any app that has a `varchar` primary key, a primary key that is also a foreign key,
  or a `OneToOneField` column created by an older PormG — and **source-advisory** for a models file
  that spells a one-to-one as `ForeignKey(…, unique=true)`. Apps keyed entirely on `IDField` with no
  one-to-one relations — the common case — need no change at all. Part of the `0.5.x` wave.

### What changed

**`Models.AutoField()` now raises `FieldValidationError`.** It was documented as a 32-bit
`INTEGER SERIAL` key and never was one: `Dialect._get_column_type` had no branch for it, so it
emitted a **`TEXT`** column on both backends with no sequence, identity or `AUTOINCREMENT` — so
nothing was auto-incrementing and the key was textual. An app that supplied its own key values would
have worked; one that relied on the documented behaviour never did. `IDField` is now PormG's only
integer key type.

**Introspection no longer flattens every primary key to `IDField`.** It previously reported every
non-UUID key as one, whatever the column really was, so a model declaring any other key type could
never equal what the database reported and `makemigrations` proposed the same `ALTER` on that column
on every run — forever, and on SQLite as a full table rebuild. It now reconstructs:

| live column | before | after |
|---|---|---|
| `varchar(n)` primary key | `IDField` | `CharField(primary_key=true, max_length=n)` |
| primary key that is also a foreign key | `IDField`, **relation discarded** | `ForeignKey`/`OneToOneField` with `primary_key=true` |
| any integer width | `IDField` | `IDField` (unchanged — and now correct by construction) |
| `numeric`, lengthless `text` | `IDField` | `IDField` (unchanged — deliberate, see below) |

`numeric` keeps the fallback because `DecimalField` refuses `primary_key` outright; a lengthless
`text` key keeps it because no PormG field type both accepts `primary_key` and carries no length.

**`OneToOneField` now renders a real column.** It had `AutoField`'s exact defect — no
`_get_column_type` branch, so `TEXT` — plus a SQLite `CREATE TABLE` foreign-key clause gated on
`isa sForeignKey`, so **no constraint was emitted at all**. Both are fixed.

This one is **not** additive, and the reason is the second half of the same bug. Because the old
SQLite `CREATE TABLE` emitted no foreign-key clause for a one-to-one, a table PormG created before
this change has a plain `text` column with no constraint — so introspection reads it back as a
`TextField`, not as a relation, and the planner proposes `:type`. It proposed that before too, but
the alteration used to re-render the column as `text` (churn, physically a no-op). It now rewrites
`text` → `bigint`/`INTEGER` **and** newly enforces the foreign key, so it coerces data and can fail
`PRAGMA foreign_key_check`. On PostgreSQL the equivalent `ALTER COLUMN … TYPE bigint` is rejected
outright without a `USING` clause, so the migration errors instead of applying.

A one-to-one column created by an older PormG therefore belongs in the ⚠️ check below alongside the
key shapes.

**Both readers now report a UNIQUE non-key foreign key as `OneToOneField` (#417).** PostgreSQL
always did; SQLite returned `ForeignKey` by a deliberate #318 decision, taken because PormG could
not then materialize a one-to-one at all — the objection the `_get_column_type` fix above removes.

| live column | before | after |
|---|---|---|
| SQLite: `INTEGER UNIQUE REFERENCES parent(id)` | `ForeignKey(unique=true)` | `OneToOneField` |
| PostgreSQL: `bigint UNIQUE REFERENCES parent(id)` | `OneToOneField` | `OneToOneField` (unchanged) |

This does not fail, it churns — which is what makes it advisory rather than breaking. The two structs
carry identical field-name sets, so `Models._compare_model_field` calls them equal and the planner's
fast path returns early. But that fast path only holds while **nothing else in the table changes**.
As soon as any other column differs, the planner runs its detailed loop, compares struct types, and
pushes `:type` on a column that did not change — an `ALTER` that re-renders it identically, and a
full table rebuild on SQLite, on every `makemigrations`, forever. Cheap to avoid, tedious to live
with.

So: if a models file spells a one-to-one as `ForeignKey(..., unique=true)`, rewrite it. That was
the exposed spelling on PostgreSQL already; #417 makes SQLite agree, which is the point — but it
does mean SQLite-only apps meet it for the first time.

```julia
# before — introspection reports `OneToOneField`, this says `sForeignKey`
driver = Models.ForeignKey("Driver", unique = true, on_delete = "CASCADE")

# after
driver = Models.OneToOneField("Driver", on_delete = "CASCADE")
```

Closing this so that **neither** spelling churns is tracked in #437, and it needs two changes
rather than one: `Dialect.describes_same_column` must stop refusing a pair where both sides are
relational, **and** the planner's cross-type comparison branch must gain the `:to` / `:pk_field`
reconciliations its same-type branch already has. Without that second half the churn only moves —
a declared `.to` is a resolved model where the introspected one is a binding string, so the branch
pushes `:to` instead of `:type` and SQLite rebuilds the table just the same.

### How to find the calls to migrate

```bash
# 1. Source change — declarations of the retired type.
grep -rn "AutoField(" --include="*.jl" .

# 2. Schema risk — a GENERATED models file that declares IDField on a key that is really a
#    varchar or a foreign key. Introspection used to report those as IDField, so the generated
#    file says IDField and the live column does not agree with it.
grep -rn "IDField(" --include="*.jl" db/ src/

# 3. Schema risk — one-to-one columns created by an older PormG (shape 2 below). These will NOT
#    turn up in a key-focused audit: a OneToOneField is not a primary key.
grep -rn "OneToOneField(" --include="*.jl" .

# 4. Source-advisory (#417) — a one-to-one spelled as a unique ForeignKey. Rewrite each hit as
#    OneToOneField(...); that is what both readers now report.
grep -rn "ForeignKey(.*unique *= *true" --include="*.jl" .

#    …and again for declarations wrapped across lines, which the one-line form above cannot see:
grep -rn -A3 "ForeignKey($" --include="*.jl" . | grep "unique"
```

For (2), the reliable check is not a grep but a dry run — see below.

### Before → after

```julia
# before
Part_category = Models.Model(
    id   = Models.AutoField(),
    name = Models.CharField(max_length = 100)
)

# after
Part_category = Models.Model(
    id   = Models.IDField(),
    name = Models.CharField(max_length = 100)
)
```

`IDField` is BIGINT where `AutoField` claimed INTEGER. **The column is not re-typed** — PormG
compares the declared `type` slot rather than the rendered width — but "no `ALTER` at all" would be
too strong a promise, for two reasons worth knowing before you migrate:

- **`:generated`.** Introspection reports `generated=false` for any key column that is not a
  PostgreSQL IDENTITY column, while `IDField()` defaults `generated=true`, and `:generated` carries
  no exemption in the planner. A pre-existing `serial` key therefore attracts
  `ALTER COLUMN … ADD GENERATED BY DEFAULT AS IDENTITY`. That mismatch predates this change and is
  not introduced by it, but it is what you will see.
- **A column a real `AutoField` created is `text`.** That was the bug. PostgreSQL refuses to make a
  `text` column an identity column (*"identity column type must be smallint, integer, or bigint"*),
  so the migration above errors out on exactly the table this entry is telling you to migrate. Such
  a column has to be re-typed by hand — PormG will otherwise go on treating it as a BIGINT
  `IDField` and never propose fixing it.

### ⚠️ Run `dry_run()` before `migrate()` the first time

This is the part that can bite, and it applies even to apps that never touched `AutoField`.

Three column shapes can attract an alteration on the first run. All of them are cases where PormG
previously reported something the database did not contain:

1. **A `varchar` primary key**, or **a primary key that is also a foreign key**, in a **generated**
   models file (`generate_models_from_db`, `import_models_from_postgres`, the Django importer). That
   file says `IDField()` for the column, because that is what introspection used to report.
   Introspection now reports the truth, the two disagree, and the proposed `ALTER` on a `varchar`
   key is **destructive**.
2. **A `OneToOneField` column created by an older PormG.** It is physically `text` with no foreign
   key, so it reads back as a `TextField`; the alteration now re-types it to `bigint`/`INTEGER` and
   adds the constraint. On SQLite that is a full table rebuild that coerces the data; on PostgreSQL
   the `ALTER … TYPE bigint` is rejected without a `USING` clause.
3. **A key column left behind by a real `AutoField`.** It is `text`. PostgreSQL refuses the identity
   clause `IDField` implies (*"identity column type must be smallint, integer, or bigint"*) and the
   migration errors — noisy, but safe. **SQLite does not refuse it.** There the mismatch is
   `:auto_increment` rather than `:generated`, and the rebuild targets
   `INTEGER PRIMARY KEY AUTOINCREMENT`: a non-numeric key aborts the `INSERT … SELECT` mid-rebuild
   with a datatype mismatch, and a zero-padded numeric one is **silently renumbered** (`'0042'`
   becomes `42`, and every external reference to it dangles). Re-type the column by hand.

```julia
using PormG
makemigrations()
dry_run()          # READ THIS. Any ALTER on a primary-key column is the case described above.
```

If you see one, do **not** migrate. Fix the model to describe the column that actually exists —
either regenerate the file, or hand-correct the key. For shapes 2 and 3 the *database* is what is
wrong, so the column has to be re-typed deliberately (with a `USING` clause on PostgreSQL) rather
than the model bent to match it.

```julia
# generated before this change, over a `matricula varchar(20) PRIMARY KEY` column
Funcionario = Models.Model("funcionario",
    matricula = Models.IDField(),                                    # ← wrong, and now visibly so
    nome      = Models.CharField(max_length = 120))

# corrected — describes the column that is really there
Funcionario = Models.Model("funcionario",
    matricula = Models.CharField(primary_key = true, max_length = 20),
    nome      = Models.CharField(max_length = 120))
```

Then `makemigrations()` again; the plan should be empty. That empty second plan is the whole point
of #409 — before it, that column churned on every run and there was no model you could write to
stop it.
