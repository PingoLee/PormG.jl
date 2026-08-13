# Schema Conventions

When PormG generates a database schema from your Julia models, it follows a small set of **naming
and structural conventions**. The moment you run `migrate()` these choices are physically in
your database — a later change would mean the ORM no longer matches your existing schema, with no
version-pin escape. They are therefore a **stability contract**, documented here as **final**.

The guiding principle is *no magic*: **what you declare is what you get**. PormG does not pluralize,
does not invent column names, and does not auto-add fields to a native model. This makes the
generated schema predictable and — importantly for PormG's ETL/secondary-app role — easy to point
at a database whose table and column names already exist.

!!! note "Native vs. imported models"
    Two paths produce models, and they intentionally differ. **Native** models are ones you write
    and whose schema PormG *owns* (it runs the migrations). **Imported** models come from
    [`import_models_from_django`](import_django.md), where **Django owns the schema** and PormG is a
    reader/ETL client — so the importer matches Django's conventions instead of PormG's. Each
    convention below calls out the difference where it exists.

## Table names

A table name is the model's `name` **verbatim** — no pluralization, no Inflector, no snake-casing —
and that `name` is always **lowercase**:

```julia
Result = Models.Model("result", …)   # → table  result
Driver = Models.Model("driver", …)   # → table  driver
```

The Julia binding stays capitalized (`Result`), while the stored `name` ("result") is what becomes
the table. To use a different physical table name (e.g. to match an existing database), name the
model accordingly: `Models.Model("f1_results", …)` → table `f1_results`.

Lowercase is **enforced, not merely conventional**. A name given positionally must already be
lowercase — `Models.Model("Driver_Profile", …)` raises `ModelDefinitionError` — while a name derived
from the Julia binding is lowercased as it is filled in. Both routes therefore produce the same
guarantee, which is what lets the DDL and the query builder agree on one spelling:

```julia
Models.Model("Driver_Profile", driverid = Models.IDField())
# ModelDefinitionError: The model name 'Driver_Profile' must be lowercase; …
```

!!! note "Mapping a model to a mixed-case legacy table"
    Use [`db_table`](#Pinning-an-explicit-table-name-with-db_table) (below). The positional name is
    rejected rather than quietly folded precisely so that this intent has one unambiguous spelling:
    before the check existed, such a model migrated `driver_profile` and then queried
    `"Driver_Profile"` — two different tables on PostgreSQL.

A positional name given with a **leading underscore** is rejected the same way, and for the same
reason: a model name is a lowercase **logical** identifier, and an underscore-prefixed name is not a
shape PormG generates.

```julia
Models.Model("_order", id = Models.IDField())
# ModelDefinitionError: The model name '_order' starts with '_'; …
```

If the physical table really is called `_order`, pin it — the same escape valve as for case:

```julia
Order = Models.Model("order", db_table = "_order", id = Models.IDField())
```

!!! note "This rejection used to guard a bug; it is now a convention"
    It arrived as #306, when a `ForeignKey` targeting the model rendered its `REFERENCES` through
    `format_model_name`, which stripped one leading underscore — the escape hatch borrowed from
    field-name handling — while the table itself was created with the name as stored. So
    `Model("_order", …)` created table `_order` and referenced `order`: a different table, or a failed
    constraint. #317 retired the field-name hatch, so `format_model_name` is now a pure case fold with
    nothing to inherit and the two sides agree. The rejection was kept because "lowercase logical name,
    explicit `db_table` for anything else" is the convention — not because the split is still reachable.

Field names follow the same principle one level down, with `db_column` in place of `db_table`: a
leading underscore is rejected there too (#317). See
[Field Naming Rules](fields.md#Field-Naming-Rules).

### Pinning an explicit table name with `db_table`

The rules above constrain the **logical** model name. When the physical table is something those
rules would reject — a mixed-case legacy table, a name PormG would never generate — pass `db_table`.
It is the table-level sibling of [`db_column`](fields.md#Database-Column-Mapping) (#50): the model
name stays a lowercase logical identifier, and `db_table` carries the physical one, **verbatim**.

```julia
DriverProfile = Models.Model("driver_profile",
  db_table  = "Driver_Profile_Legacy",   # ← the table that actually exists
  driverid  = Models.IDField(),
  surname   = Models.CharField(max_length = 100),
)
```

`db_table` is **authoritative** wherever a table identifier is rendered:

| Path | Uses `db_table` |
| :--- | :--- |
| `CREATE TABLE`, `ALTER TABLE`, `CREATE INDEX`, `ADD CONSTRAINT` | ✔ |
| `SELECT` / `INSERT` / `UPDATE` / `DELETE` | ✔ |
| `JOIN` targets, including through a foreign key | ✔ |
| A `ForeignKey`'s `REFERENCES` target, when it points at this model | ✔ |
| Migration add/drop/rename detection | ✔ |

The value is stored exactly as written — no case fold, no leading-underscore strip, no identifier
validation. That is deliberate: the option exists to name a table PormG's own conventions could not
produce. It is also **purely opt-in** — a model that does not set `db_table` derives its table name
exactly as it always has, so no existing schema changes and nothing needs re-migrating.

!!! note "Changing `db_table` on a migrated model is a table rename"
    The migration planner matches the live schema against your models by **physical** table name, so
    editing `db_table` on a model that is already migrated presents as "one table disappeared, another
    appeared" — the same prompt you get for any table rename. Answer it as a rename to keep your data.

!!! note "`ManyToManyField` takes its own `db_table`"
    That option names the auto-generated **through** table, not the model's own table, and follows the
    same case-preserving rule. An auto-derived through-table name (no `db_table` given) is still built
    from the models' *logical* names, so pinning `db_table` on a model does not silently rename a join
    table PormG generated for you.

### Generated files: colliding bindings and names are disambiguated

`inspectdb`-style import (`import_models_from_sqlite` / `import_models_from_postgres` /
`import_models_from_django`) derives both the Julia **binding** and — when the positional name would
otherwise be empty, e.g. an all-underscore table — the **positional name** from the table name. Two
tables can independently arrive at the same one: `driver profile` sanitizes to the same binding an
already-legal `driver_profile` also produces; a table literally named `models` collides with the
generated file's own `import PormG.Models` line.

Within a single generated file, each newly-derived binding and positional name is checked against
everything already emitted into that file and, on a collision, suffixed with a digit — never another
underscore, mirroring how a hostile *field* name is disambiguated (see
[Field Naming Rules](fields.md#Field-Naming-Rules)). Without this, the second colliding
`Binding = Models.Model(...)` line would silently overwrite the first Julia global when the file is
loaded — no error, no warning, one model just gone.

!!! note "`db_table` is pinned automatically when disambiguation would otherwise be wrong"
    The positional name can *be* the physical table (whenever `db_table` is not otherwise set,
    PormG falls back to it at query time). Suffixing it blindly would leave a model that loads
    cleanly but queries a table that does not exist — worse than the collision it replaces. So when
    disambiguating the positional name changes it and nothing already pins `db_table`, PormG pins
    the original name to `db_table` for you — the same escape valve described above.

!!! note "Residual limitation: `ForeignKey` target resolution"
    A `ForeignKey`'s `.to` is derived independently, from the live parent table name, and resolved by
    binding-name lookup alone. If disambiguation suffixes the binding a `.to` was counting on, the
    reference still resolves — just to whichever sibling kept the un-suffixed binding, not necessarily
    the table the key originally pointed at. This is not new: before disambiguation existed, every such
    reference was already ambiguous, since both tables shared one binding. Review a generated file's
    foreign keys by hand when your schema has tables whose names collide after sanitizing.

### `django_prefix` interop

A connection may set `django_prefix` in its `connection.yml` (default: unset). It is a convenience
for working alongside a Django app, whose tables are named `<app_label>_<model>`:

- When PormG **generates** a model file (e.g. via the Django importer), it prepends `<prefix>_` to
  the stored model `name`, so the physical table matches Django's `f1_results`.
- When PormG derives **relationship accessor names**, it strips the prefix so Julia-side names stay
  clean.

The physical-table rule is unchanged: the table is still `name`, which is always lowercase —
`django_prefix` only shapes how `name` is generated and how accessors read.

!!! note "Naming only — it does not switch any behaviour on"
    That list is exhaustive. In particular, `django_prefix` has **no** effect on PostgreSQL sequence
    synchronisation: setting it does not enable the repair, and leaving it unset does not disable it.
    Earlier versions silently did both, so a connection that dropped the prefix also stopped
    resyncing its `id` sequences and eventually failed inserts with a duplicate-key error. Sequence
    repair is now decided by the call site — see [Sequence synchronisation](#Sequence-synchronisation)
    below — never by `django_prefix`.

## Sequence synchronisation

A PostgreSQL `SERIAL`/`IDENTITY` column only advances its sequence when the **database** generates
the value. Insert a row with an explicit primary key and the sequence stays where it was; a later
auto-generated key then collides with the row you inserted by hand.

**PormG repairs this automatically only where drift is produced in bulk** — `bulk_insert` and
`bulk_copy` resynchronise the sequence afterwards whenever the write supplied explicit primary keys,
to `MAX(pk) + 1` on PostgreSQL and by rewriting `sqlite_sequence` on SQLite. `bulk_insert` also
resyncs (once) before retrying an unexpected duplicate-key error.

**Row-level writers — `create`/`insert`, `update_or_create`, `get_or_create` — do NOT auto-resync.**
Matching every comparable ORM checked when this was decided (Django, Rails, SQLAlchemy, Ecto, Prisma:
none resyncs on a row-level write), the cost of two extra round-trips is not paid on every explicit-pk
row write. Call [`resync_sequences`](#Explicit-repair:-resync_sequences) yourself after one of these
writes an explicit primary key, if a later auto-generated write to the same table needs to be safe.

**No configuration governs any of this.** The repair is not gated by `change_db` or `django_prefix` on
either engine. (`change_data: false` is a different matter — it rejects the write itself, long before
any resync would run, on both the automatic bulk paths and an explicit `resync_sequences` call.)

### What differs between the engines

| | PostgreSQL | SQLite |
| :--- | :--- | :--- |
| Mechanism | resolve the column's owned sequence, then `setval` it to `MAX(pk) + 1` | upsert into `sqlite_sequence` |
| `bulk_copy` | supported | not supported — raises `BackendCapabilityError` |
| `bulk_insert` self-heal | on an unexpected duplicate-key error, repairs and retries the chunk once | no retry; the error propagates |
| A failed repair | see below | always propagates |

### When the repair itself fails

On PostgreSQL the handling depends on whether the write is inside a transaction, because a failed
statement there is not a local event — PostgreSQL marks the whole transaction aborted, rejects every
later statement, and answers the `COMMIT` with a rollback.

- **Inside a transaction the error propagates.** Returning a row that the pending rollback is about
  to erase would be worse than raising. This is always the case for `bulk_insert` and `bulk_copy`,
  which run in a transaction by construction, and for any write inside your own `atomic` block.
- **Outside one, PormG logs a warning and continues** — naming the table, the column, and the
  sequence when it got as far as resolving one. This applies to a failure of the database round-trip
  or the connection pool; anything else (including a cancellation) still raises. The row (or, for a
  standalone repair, nothing) is already committed and only the *next* auto-generated key is at risk.
  A standalone [`resync_sequences`](#Explicit-repair:-resync_sequences) call takes this path unless you
  wrap it in your own `atomic` block — row-level writers no longer call this machinery at all (see
  above), so it is reached almost exclusively through an explicit call now.

If the primary-key column has no *owned* sequence — a table PormG did not create, or a natural key —
PormG looks for PostgreSQL's conventional `<table>_<column>_seq` **in the table's own schema**, and
does nothing if it is absent. One consequence is worth knowing: PostgreSQL truncates generated object
names at 63 bytes, so a table and column whose combined name exceeds that owns a sequence under a
shortened name this lookup will not find. The skipped resync is logged at debug level together with
the name it expected — run with `JULIA_DEBUG=PormG` to see it.

A recurring cause is a role holding `USAGE` but not `UPDATE` on the sequence: PostgreSQL requires
`UPDATE` for `setval` while `nextval` accepts either, so such a role inserts rows perfectly well and
can never resync. The logged exception tells you whether that is what happened.

### Explicit repair: `resync_sequences`

`resync_sequences(model)` runs the same repair `bulk_insert`/`bulk_copy` run automatically, on
demand, with no accompanying insert. Reach for it after:

- a row-level write (`create`, `update_or_create`, `get_or_create`) that supplied an explicit
  primary key, if a later auto-generated write to the same table needs to be safe;
- a `pg_restore`, a manual `COPY`, or any load that wrote rows outside PormG entirely.

```julia
# A migration replays historical drivers with their original ids.
for row in eachrow(legacy_drivers)
    M.Driver.objects.create("driverid" => row.id, "forename" => row.forename)
end
resync_sequences(M.Driver)   # once, after the batch — not per row

# A later ordinary create() is safe again:
M.Driver.objects.create("forename" => "Auto")
```

`resync_sequences(models)` (a collection) resyncs each in turn. Both forms return the pk field
name(s) the repair was attempted for (empty if the model declares none); a per-field failure follows
the same warn-or-propagate rule described above, not an exception from `resync_sequences` itself.
Accepts a bare model (`M.Driver`) or its handler (`M.Driver.objects`) — same dual form as
`bulk_insert`/`bulk_copy`.

## Primary keys

PormG does **not** auto-create an `id` primary key for a native model. You declare one explicitly:

```julia
Driver = Models.Model("driver",
  driverid = Models.IDField(),                 # explicit PK
  surname  = Models.CharField(max_length=255),
)
```

A model with no declared primary key simply has none (`get_model_pk_field` returns `nothing`).
The `IDField` renders as an auto-incrementing key per backend:

| Backend | Generated PK |
| :--- | :--- |
| PostgreSQL | `BIGINT … GENERATED BY DEFAULT AS IDENTITY` (or `GENERATED ALWAYS` when `generated_always=true`) |
| SQLite | `INTEGER PRIMARY KEY AUTOINCREMENT` |

!!! note "Imported models differ"
    The Django importer **does** auto-add `id = Models.IDField()` when the Django model declares no
    primary key — because it is matching Django's implicit `id`. This asymmetry is intentional:
    native models own their schema and stay explicit; imported models mirror Django's.

## Foreign-key columns

A foreign-key column is the **declared field name, verbatim (case preserved)** — PormG never appends
`_id`, lowercases, or otherwise transforms it:

```julia
Result = Models.Model("result",
  resultid = Models.IDField(),
  driverid = Models.ForeignKey("driver", pk_field="driverid"),  # → column  driverid
)
```

Whatever you name the field is the column. To interoperate with an existing schema that uses
`driver_id`, name the field `driver_id`. This "verbatim" rule is deliberate and final: it keeps the
ORM honest against externally-owned schemas, where an automatic `_id` suffix would fight the real
column names.

Two consequences worth noting:

- The FK field name is also the **join/lookup prefix**: `Result.objects.filter("driverid__surname"
  => "Senna")`. There is no separate "related object vs. raw id" split like Django's
  `obj.author` / `obj.author_id` — the one field name serves both, by design.
- By default a column equals its field name. To map a field to a **differently-named** column, set
  `db_column` — it is **authoritative** (#50) across generated DDL, queries (SELECT/WHERE/ORDER BY/
  INSERT/UPDATE, and the bulk APIs), and the migration diff. The field name stays the identity you
  declare and query by; only the physical column changes, and results stay keyed by the field name:

  ```julia
  sku = Models.CharField(db_column="product_sku")   # field `sku` → column "product_sku"
  ```

  This is non-breaking: the default (column == field name) is unchanged, so existing schemas are
  unaffected. On a `ForeignKey`/`OneToOneField`, `db_column` renames the **local** FK column; the
  **referenced** parent column follows `pk_field`, resolved through the parent field's own
  `db_column`. This works for both model-instance and **string** targets
  (`ForeignKey(Driver, pk_field="code")` or `ForeignKey("Driver", pk_field="code")`), and whether or
  not `pk_field` is spelled out — string targets are resolved to the model object once, up front
  ([#62](https://github.com/PingoLee/PormG.jl/issues/62)).

  !!! note "Limitation: ManyToMany through-table column names"
      `db_column` is honored across the whole stack — CRUD (create/get/update, bulk, sequence sync),
      FK constraints and joins (model-instance or string targets, a renamed parent PK), **and**
      ManyToMany / CTE join keys when a participating model's primary key uses `db_column`
      ([#64](https://github.com/PingoLee/PormG.jl/issues/64)). The one surface that is **not**
      configurable is the **auto-generated ManyToMany through-table column names** (`<model>_<pk>`).

!!! note "Imported models differ"
    The Django importer appends `_id` to a `ForeignKey`/`OneToOneField` field and points it at the
    referenced `id` — e.g. Django's `category = ForeignKey(...)` becomes a `category_id` column —
    because it is matching Django's column naming. PormG does not run migrations for imported
    models, so it is reading that schema, not defining it.

### Default `on_delete`

When a `ForeignKey` is declared **without** `on_delete`, the constraint is generated as
`ON DELETE NO ACTION`. (Django, by contrast, requires you to choose.) Set it explicitly to change
the behavior:

```julia
author   = Models.ForeignKey("driver")                       # → ON DELETE NO ACTION (default)
category = Models.ForeignKey("constructor", on_delete=CASCADE)
```

| `on_delete` value | Generated SQL |
| :--- | :--- |
| *(unset)* | `NO ACTION` |
| `CASCADE` | `CASCADE` |
| `RESTRICT` | `RESTRICT` |
| `SET_NULL` | `SET NULL` (requires `null=true`) |
| `SET_DEFAULT` | `SET DEFAULT` (requires a `default`) |
| `DO_NOTHING` | `NO ACTION` |
| `PROTECT` | `RESTRICT` |

## Timestamp fields

PormG does **not** implicitly add `created` / `modified` columns. Auto-managed timestamps are
opt-in, via `auto_now_add` / `auto_now` on a `DateField` or `DateTimeField`, and the **column name
is whatever you declare**:

```julia
Driver = Models.Model("driver",
  driverid     = Models.IDField(),
  created_at   = Models.DateTimeField(auto_now_add=true),  # set once, on insert
  modified_at  = Models.DateTimeField(auto_now=true),      # refreshed on every save
)
```

`auto_now_add` writes the value on creation only; `auto_now` updates it on every save. Both attach
`settings.time_zone` when generating the value.

## Identifier quoting and case

**Column** identifiers are always emitted with **double quotes** (`"…"`) on **both** PostgreSQL and
SQLite (no backticks, no backend-specific quoting), and they **preserve the declared field-name case**
(#57) — so a field declared `driverId` becomes `"driverId"`.

The **table** identifier is *not* uniformly quoted. Some statements quote it (the
SELECT/INSERT/UPDATE builder, `REFERENCES`) and others write it bare (`CREATE TABLE`, `CREATE INDEX`,
the DELETE/cascade paths, PostgreSQL's `ADD CONSTRAINT`) — the split does not follow a
DDL-versus-query line, so do not rely on one. What makes the mixture safe is that a model name is
lowercase (see [Table names](#Table-names)): an unquoted lowercase identifier folds to itself on
PostgreSQL, so the bare and quoted spellings address the same table either way.

That is precisely what a mixed-case name used to break — one declaration migrating `driver_profile`
and querying `"Driver_Profile"` — and why such a name is now rejected at declaration.

!!! warning "Lowercase is necessary, not sufficient"
    Because the table is written bare in `CREATE TABLE`, a model name must also be a valid unquoted
    identifier. That part is **not** checked: `Models.Model("order", …)` (a reserved word) and
    `Models.Model("driver profile", …)` (a space) are accepted and then emit invalid DDL. Stick to
    lowercase `snake_case`.

**Column** identifiers, by contrast, are quoted everywhere, so a column may be named anything the
database accepts — including a SQL reserved word or a Julia keyword. Declare the field under a legal
Julia identifier and name the column with `db_column`; that is the sanctioned way to address a column
whose name is not a legal PormG field name (#317):

```julia
end_ = Models.DateTimeField(db_column = "end")   # field `end_` → column "end"
```

Declaring lowercase snake_case (the house style) yields all-lowercase identifiers. The example below
is the **SQLite** shape, which carries its foreign keys inline in `CREATE TABLE`. PostgreSQL renders
its own column types (`bigint`, `float`, `… GENERATED BY DEFAULT AS IDENTITY`) and emits **no** inline
`FOREIGN KEY` — there, foreign keys arrive as separate statements in the migration plan. The
identifier quoting is identical on both:

```sql
CREATE TABLE IF NOT EXISTS result (
  "resultid" INTEGER PRIMARY KEY AUTOINCREMENT UNIQUE NOT NULL,
  "driverid" INTEGER NOT NULL,
  "points"   REAL NOT NULL,
  FOREIGN KEY ("driverid") REFERENCES "driver"("driverid") ON DELETE NO ACTION
);
```

## Summary

| Convention | Rule (final) |
| :--- | :--- |
| Table name | `model.name` verbatim — no pluralization. The name is always lowercase: enforced at declaration for a positional name, derived lowercase from the Julia binding otherwise |
| `django_prefix` | optional Django-interop prefix; shapes generated `name`/accessors, not the physical-table rule |
| Primary key | explicit `IDField` on native models; no implicit `id` (importer auto-adds `id`) |
| FK column | declared field name, verbatim (case preserved), or `db_column` when set — no `_id` suffix (importer adds `_id`) |
| `db_column` | authoritative: maps a field to a differently-named column (default: column == field name) |
| Default `on_delete` | `NO ACTION` |
| Timestamps | opt-in `auto_now` / `auto_now_add`; no implicit `created`/`modified` |
| Quoting | columns always double-quoted on both backends (case-preserved); the table is quoted in some statements and bare in others — consistent only because the name is lowercase |

The migration *format* that records these schemas (file layout, checksum, tracking table) is a
separate frozen contract — see [Migration Format Stability](migrations/stability.md).
