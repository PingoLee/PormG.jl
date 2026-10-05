# Defining Models in PormG

PormG models describe the structure of your database tables using Julia code, inspired by Django ORM but tailored for Julia's syntax and performance.

## What is a Model?
A model is a Julia object that defines the fields (columns) and their types for a database table. Each model maps directly to a table in your PostgreSQL or SQLite database.

!!! note "How model and field names become a schema"
    The rules that turn a model into table/column names — table naming, foreign-key columns, primary
    keys, default `on_delete`, and identifier quoting — are a frozen contract documented in
    [Schema Conventions](schema_conventions.md).

## Creating a Model

1. **Edit Your Models File**
   - By default, models are defined in `db/models.jl`.
   - Each model is a Julia struct using PormG field types.

2. **Example Model Definition**

```julia
Driver = Models.Model(
    id = Models.IDField(),
    name = Models.CharField(max_length=100),
    birthdate = Models.DateField(),
    nationality = Models.CharField(max_length=50)
)
```

3. **Example of module construction in `db/models.jl`**

```julia
module models
import PormG.Models
import PormG.Models: RESTRICT, CASCADE, SET_NULL, SET_DEFAULT, DO_NOTHING


Status = Models.Model(
  statusid = Models.IDField(),
  status = Models.CharField()
)

Circuit = Models.Model( # You can create a model like a Django model for each table so that you can define a huge number of tables at once in just one file. Please capitalize the Julia BINDING (`Circuit`) — it is lowercased to derive the table name. A positional table name, when you give one, must itself be lowercase: `Models.Model("Circuit", …)` raises ModelDefinitionError.
  circuitid = Models.IDField(), # House style: declare field names in lowercase snake_case. PormG preserves the case you declare (so mixed-case/uppercase legacy columns are supported) and field lookups are case-sensitive — query fields in the same case you declared them.
  circuitref = Models.CharField(),
  name = Models.CharField(),
  location = Models.CharField(),
  country = Models.CharField(),
  lat = Models.FloatField(),
  lng = Models.FloatField(),
  alt = Models.IntegerField(),
  url = Models.CharField()
)

Race = Models.Model(
  raceid = Models.IDField(),
  year = Models.IntegerField(),
  round = Models.IntegerField(),
  circuitid = Models.ForeignKey(Circuit, pk_field="circuitid", on_delete="CASCADE"),
  name = Models.CharField(),
  date = Models.DateField(),
  time = Models.TimeField(null=true),
  start_at = Models.DateTimeField(null=true),   # race start as a UTC timestamp (derived from date + time)
  url = Models.CharField(),
  fp1_date = Models.DateField(null=true),
  fp1_time = Models.TimeField(null=true),
  fp2_date = Models.DateField(null=true),
  fp2_time = Models.TimeField(null=true),
  fp3_date = Models.DateField(null=true),
  fp3_time = Models.TimeField(null=true),
  quali_date = Models.DateField(null=true),
  quali_time = Models.TimeField(null=true),
  sprint_date = Models.DateField(null=true),
  sprint_time = Models.TimeField(null=true),
)

Driver = Models.Model(
  driverid = Models.IDField(),
  driverref = Models.CharField(),
  number = Models.IntegerField(null=true),
  code = Models.CharField(),
  forename = Models.CharField(),
  surname = Models.CharField(),
  dob = Models.DateField(),
  nationality = Models.CharField(),
  url = Models.CharField()
)

Constructor = Models.Model(
  constructorid = Models.IDField(),
  constructorref = Models.CharField(),
  name = Models.CharField(),
  nationality = Models.CharField(),
  url = Models.CharField()
)

Result = Models.Model(
  resultid = Models.IDField(),
  raceid = Models.ForeignKey(Race, pk_field="raceid", on_delete="CASCADE"),
  driverid = Models.ForeignKey(Driver, pk_field="driverid", on_delete="RESTRICT"),
  constructorid = Models.ForeignKey(Constructor, pk_field="constructorid", on_delete="RESTRICT"),
  number = Models.IntegerField(null=true),
  grid = Models.IntegerField(),
  position = Models.IntegerField(null=true),
  positiontext = Models.CharField(),
  positionorder = Models.IntegerField(),
  points = Models.FloatField(),
  laps = Models.IntegerField(),
  time = Models.CharField(null=true),
  milliseconds = Models.IntegerField(null=true),
  fastestlap = Models.IntegerField(null=true),
  rank = Models.IntegerField(null=true),
  fastestlaptime = Models.DurationField(null=true),
  fastestlapspeed = Models.FloatField(null=true),
  statusid = Models.ForeignKey(Status, pk_field="statusid", on_delete="CASCADE")
)

Just_a_test_deletion = Models.Model(
  id = Models.IDField(),
  name = Models.CharField(),
  test_result = Models.ForeignKey(Result, pk_field="resultid", on_delete="CASCADE", null=true, related_name="test_deletion"),
  test_result2 = Models.ForeignKey(Result, pk_field="resultid", on_delete="CASCADE", null=true, related_name="test_deletion2")
)

end
```

- Each field uses a PormG field constructor (e.g., `IDField`, `CharField`, `DateField`).
- You can use keyword arguments to customize field options (e.g., `max_length`, `unique`, `null`).

## Composite Uniqueness (`unique_together`)

A single-column uniqueness rule is a field option (`unique=true`). To require a combination
of **two or more** columns to be unique together — Django's `Meta.unique_together` — declare a
model-level `constraints=[...]` list of `Models.UniqueConstraint` objects (the same shape as
Django 2.2+ / SQLAlchemy named constraints):

```julia
Constructor_engine = Models.Model("constructor_engines",
  id = Models.IDField(),
  constructorid = Models.ForeignKey(Constructor, pk_field="constructorid", on_delete="CASCADE"),
  year = Models.IntegerField(),
  engine_manufacturer = Models.CharField(max_length=50),
  constraints = [
    Models.UniqueConstraint(fields=("constructorid", "year"), name="uniq_constructor_year"),
  ],
)
```

Each `UniqueConstraint` takes:

- `fields` — a tuple (or vector) of **field names** on this model. Foreign-key fields are
  referenced by the field name; PormG resolves each to its physical column (honoring
  `db_column`).
- `name` — the index name (optional). When omitted, PormG derives `<table>_<cols>_uniq`,
  matching the auto-generated many-to-many index convention. See
  [Index names](#Index-names) for how a name is matched, renamed and length-checked.

A model may carry several constraints (each its own tuple). At migration time each becomes a
`CREATE UNIQUE INDEX` — identical on PostgreSQL and SQLite:

```sql
CREATE UNIQUE INDEX "uniq_constructor_year"
  ON "constructor_engines" ("constructorid", "year");
```

Adding, removing or changing a constraint later is planned like any other schema change — see
[Changing composites on an existing table](#Changing-composites-on-an-existing-table).

### Partial and functional unique constraints

Django's `UniqueConstraint` also takes a `condition` and expressions, and so does PormG's — the SQL
text of an [expression or partial index](#Expression-and-partial-indexes), made unique:

```julia
Sprint_result = Models.Model("sprint_results",
  sprintid = Models.IDField(),
  raceid   = Models.ForeignKey(Race, pk_field="raceid", on_delete="CASCADE"),
  position = Models.IntegerField(null=true),
  constraints = [
    # one classified finisher per position in a sprint — a retirement has no position
    Models.UniqueConstraint(fields=("raceid", "position"), condition="position IS NOT NULL",
                            name="sprint_one_per_position"),
  ],
)

Driver = Models.Model("driver",
  driverid  = Models.IDField(),
  driverref = Models.CharField(),
  constraints = [
    # "hamilton" and "Hamilton" are the same driver reference
    Models.UniqueConstraint(expressions=("lower(driverref)",), name="driver_ref_ci_uniq"),
  ],
)
```

```sql
CREATE UNIQUE INDEX "sprint_one_per_position" ON "sprint_results" ("raceid", "position") WHERE position IS NOT NULL;
COMMENT ON INDEX "sprint_one_per_position" IS 'pormg:index:837d515127295d74';

CREATE UNIQUE INDEX "driver_ref_ci_uniq" ON "driver" (lower(driverref));
COMMENT ON INDEX "driver_ref_ci_uniq" IS 'pormg:index:35ba2c95a4f30f95';
```

The text follows the `Index` rules exactly: `fields` or `expressions`, not both; a **`name`** is
required; the SQL is checked only for what would change the statement it lands in; both engines
support both kinds. It is owned the same way too — through the hash of its text in the
`pormg:index:<hash>` marker — so changing the condition or an expression is a drop and a create,
and a hand-made unique partial or functional index is adopted by a declaration of its own text and
never planned away undeclared.

`migrate` counts a new partial constraint's duplicates **among the rows its condition matches** before
it runs, as it does for a plain one. A functional one is not counted ahead of time — it has no
columns to group by — so duplicates surface as the database's own error when the plan runs, which
rolls the migration back.

## Composite Indexes (`Meta.indexes`)

A plain single-column index is a field option (`db_index=true`). To index a combination of **two or
more** columns — Django's `Meta.indexes` — or to give an index a direction, an access method or an
operator class, declare a model-level `indexes=[...]` list of `Models.Index` objects:

```julia
Lap_times = Models.Model("lap_times",
  raceid   = Models.ForeignKey(Race, pk_field="raceid", on_delete="CASCADE"),
  driverid = Models.ForeignKey(Driver, pk_field="driverid", on_delete="RESTRICT"),
  lap      = Models.IntegerField(),
  position = Models.IntegerField(),
  indexes = [
    Models.Index(fields=("raceid", "lap"), name="lap_times_race_lap_idx"),
  ],
)
```

Each `Index` takes:

- `fields` — a tuple (or vector) of field names on this model: **two or more** for a plain index.
  Foreign-key fields are referenced by the field name; PormG resolves each to its physical column
  (honoring `db_column`). **The order matters**: an index over `("raceid", "lap")` serves a lookup
  by `raceid`, or by `raceid` *and* `lap` together, but not one by `lap` alone. A leading `-` makes
  a column descending, as in Django — see
  [Methods, operator classes and descending columns](#Methods,-operator-classes-and-descending-columns).
- `name` — the index name (optional). When omitted, PormG derives `<table>_<cols>_idx`, the plain
  sibling of the composite-unique convention. See [Index names](#Index-names).
- `method`, `opclasses` — a PostgreSQL access method and operator classes, described in the same
  section.

An `Index` speeds up reads and constrains nothing. For a composite *uniqueness guarantee*, use
[Composite Uniqueness](#Composite-Uniqueness-(unique_together)) instead — that is a
`CREATE UNIQUE INDEX` and rejects duplicate rows. Each `Index` becomes a plain `CREATE INDEX`,
identical on PostgreSQL and SQLite:

```sql
CREATE INDEX "lap_times_race_lap_idx"
  ON "lap_times" ("raceid", "lap");
```

!!! warning "One plain column is `db_index`, not a one-field `Index`"
    `Models.Index(fields=("lap",))` raises `ModelDefinitionError`. A plain one-column `CREATE INDEX`
    is byte-identical whether `db_index=true` or an `Index` emitted it, and introspection has no way
    to tell them apart — so a one-field `Index` would read back as `db_index`, never match its own
    declaration, and make `makemigrations` propose **dropping** the index on every run. Declare
    `db_index=true` on the field instead. A one-column index that is descending, has a `method` or
    names an operator class is a different index, and `Models.Index` accepts it.

### Methods, operator classes and descending columns

Three options make an index more than a plain b-tree over ascending columns — the shapes Django
spells `Index(fields=["-points"])`, `GinIndex(...)` and `opclasses=[...]`:

```julia
Result = Models.Model("result",
  resultid = Models.IDField(),
  raceid   = Models.ForeignKey(Race, pk_field="raceid", on_delete="CASCADE"),
  driverid = Models.ForeignKey(Driver, pk_field="driverid", on_delete="RESTRICT"),
  points   = Models.FloatField(),
  indexes = [
    # the race's finishing order, highest score first
    Models.Index(fields=("raceid", "-points"), name="result_race_points_idx"),
  ],
)

Driver = Models.Model("driver",
  driverid = Models.IDField(),
  surname  = Models.CharField(max_length=255),
  dob      = Models.DateField(null=true),
  indexes = [
    # `surname LIKE 'Sen%'` under a database locale other than C — PostgreSQL only
    Models.Index(fields=("surname",), opclasses=("varchar_pattern_ops",), name="driver_surname_pattern_idx"),
    # a tiny block-range index over a column that grows with insertion order — PostgreSQL only
    Models.Index(fields=("dob",), method="brin"),
  ],
)
```

- **A leading `-`** makes that column descending. It works on both engines, and only with the
  b-tree method: PostgreSQL orders no other kind of index.
- **`method`** is the PostgreSQL access method: `"btree"` (the default), `"hash"`, `"gist"`,
  `"spgist"`, `"gin"` or `"brin"`; a `Symbol` works too. `hash` and `spgist` index one column.
- **`opclasses`** gives each field an operator class — one entry per field, `nothing` for a column
  that keeps its default class, as in `opclasses=(nothing, "varchar_pattern_ops")`. Each is a
  lower-case, unqualified name such as `jsonb_path_ops`, and an index that names one needs a `name`
  (Django's rule: a derived name would not say which class it uses).

`method` and `opclasses` are PostgreSQL features. On SQLite `makemigrations` refuses a model that
declares either with `BackendCapabilityError` — it does not create a plain index in its place, which
would give the model an index other than the one it declared. A descending column is portable.

The planner renders each one in full, with a derived name that carries the direction and the method
(`<table>_<cols>[_<method>]_idx`, where a descending column contributes `<col>_desc`):

```sql
CREATE INDEX "result_race_points_idx" ON "result" ("raceid", "points" DESC);
COMMENT ON INDEX "result_race_points_idx" IS 'pormg:index';

CREATE INDEX "driver_surname_pattern_idx" ON "driver" ("surname" varchar_pattern_ops);
COMMENT ON INDEX "driver_surname_pattern_idx" IS 'pormg:index';

CREATE INDEX "driver_dob_brin_idx" ON "driver" USING brin ("dob");
COMMENT ON INDEX "driver_dob_brin_idx" IS 'pormg:index';
```

The comment is PormG's **ownership marker**, the one a [`CheckConstraint`](#Check-Constraints) gets
for the same reason: it is how `makemigrations` tells an index it created from one written by hand
(next section). On SQLite, which has no comments on indexes, the marker is an SQL comment closing
the column list — `("raceid", "points" DESC /* pormg:index */)` — which SQLite stores with the index.
Plain indexes carry no marker and render exactly as above.

!!! note "A GIN or BRIN build holds a lock"
    `CREATE INDEX` runs inside `migrate`'s transaction and blocks writes to the table while it builds,
    which on a large table can take a while for any method. For a table that cannot pause its writes,
    create the index with `CREATE INDEX CONCURRENTLY` as a
    `run_once` step ([Data Migrations](migrations/advanced.md#Data-Migrations)), then declare it as it stands — the declaration adopts it
    (below), and nothing is rebuilt.

### Expression and partial indexes

Two more options take **SQL text**, the way a [`CheckConstraint`](#Check-Constraints)'s condition
does — Django's `Index(Lower("surname"))` and `Index(..., condition=Q(...))`:

```julia
Driver = Models.Model("driver",
  driverid = Models.IDField(),
  surname  = Models.CharField(max_length=255),
  indexes = [
    # case-insensitive lookups: `WHERE lower(surname) = 'senna'`
    Models.Index(expressions=("lower(surname)",), name="driver_surname_lower_idx"),
  ],
)

Result = Models.Model("result",
  resultid = Models.IDField(),
  raceid   = Models.ForeignKey(Race, pk_field="raceid", on_delete="CASCADE"),
  position = Models.IntegerField(null=true),
  points   = Models.FloatField(),
  indexes = [
    # only the classified finishers — a retirement has no position
    Models.Index(fields=("raceid", "-points"), condition="position IS NOT NULL",
                 name="result_finishers_idx"),
  ],
)
```

- **`expressions`** indexes the result of SQL expressions instead of columns — a *functional*
  index. Give `fields` or `expressions`, not both. Each entry is one index member, in PostgreSQL's
  index-element syntax: a function call (`"lower(surname)"`), or any other expression in parentheses
  (`"(points * 2)"`). A collation, an operator class or a direction goes inside the text —
  `"surname COLLATE \"C\""`, `"lower(surname) text_pattern_ops"`, `"lower(surname) DESC"` — so
  `opclasses` is refused beside `expressions`. PostgreSQL requires every function used to be
  `IMMUTABLE`.
  A `NULLS` placement other than the direction's default is spelled the same way:
  `"points DESC NULLS LAST"` (PostgreSQL only — SQLite's `CREATE INDEX` has no `NULLS`).
- **`condition`** makes the index *partial*: only the rows it matches are indexed. It combines with
  either `fields` or `expressions`, and with one field too — a partial one-column index is a
  different index from `db_index`.
- Either one needs a **`name`** (Django's rule: a derived name could not say what the text indexes).

The text is **SQL, sent to both engines as written** — over the table's physical, unqualified column
names, and never a `Q(...)`, because DDL takes no bind parameters. PormG checks it only for what would
silently change the statement it lands in: a `--` or `/*` comment, an unterminated quote, a top-level
`;` — or a top-level `,`, so each entry of `expressions` is exactly one member — and an `E'…'` string,
a backslash right before a quote, a dollar quote or a backtick, whose end only one engine can find.
Both engines have
expression and partial indexes; write SQL both understand when a model runs on both.

```sql
CREATE INDEX "driver_surname_lower_idx" ON "driver" (lower(surname));
COMMENT ON INDEX "driver_surname_lower_idx" IS 'pormg:index:599190475f20d2a4';

CREATE INDEX "result_finishers_idx" ON "result" ("raceid", "points" DESC) WHERE position IS NOT NULL;
COMMENT ON INDEX "result_finishers_idx" IS 'pormg:index:837d515127295d74';
```

The marker carries a **hash of the declared text**. PostgreSQL stores a rewritten form of it —
`lower(surname::text)` — so a declaration can never be compared with the catalog's text; the hash
is what `makemigrations` compares instead. So:

- **Changing the text** — an expression, or the condition — is a drop and a create of the index,
  which `migrate` treats as destructive. Changing only `name` is a rename, as for any index.
- **Renaming or removing a column the text names** is refused by `makemigrations` with
  `InvalidMigrationError`, until the text no longer names it. PormG does not rewrite your SQL: write
  the new name into the text in the same edit, and the plan re-creates the index.
- A declaration over **fields** never claims a functional or partial index over the same columns:
  `fields=("raceid", "-points")` without a `condition` is another index.

`inspectdb` reads expression and partial indexes back with the database's own text, and the
declarations it writes match the live indexes — adopting a database plans nothing. A hand-made one
follows the ownership rule below: declared under its catalog text, it is adopted; undeclared, it is
never planned away.

### Covering indexes (`include`)

`include` names fields whose values the index **carries** without sorting by them — Django's
`Index(include=...)`, PostgreSQL's `INCLUDE (…)`. A query that filters on the key and reads only the
carried columns is answered from the index alone, without visiting the table:

```julia
Result = Models.Model("result",
  resultid = Models.IDField(),
  raceid   = Models.ForeignKey(Race, pk_field="raceid", on_delete="CASCADE"),
  points   = Models.FloatField(),
  position = Models.IntegerField(null=true),
  indexes = [
    # a race's points table, read from the index alone — PostgreSQL only
    Models.Index(fields=("raceid",), include=("points", "position"), name="result_race_points_cov"),
  ],
)
```

```sql
CREATE INDEX "result_race_points_cov" ON "result" ("raceid") INCLUDE ("points", "position");
COMMENT ON INDEX "result_race_points_cov" IS 'pormg:index';
```

- It needs a **`name`** (Django's rule), and combines with `fields` or `expressions` and with a
  `condition`. One key field is enough: the payload makes it a different index from `db_index`.
- A field is either part of the key or included, not both. `include` works with the `btree`, `gist`
  and `spgist` methods (`spgist` from PostgreSQL 14); `hash`, `gin` and `brin` refuse it.
- The payload is part of the index: changing it, or its order, is a drop and a create.
- It is **PostgreSQL-only**: SQLite has no covering indexes, so `makemigrations` refuses a model that
  declares one there with `BackendCapabilityError`, as it does a `method` or an operator class.

A covering index is owned the way an index with a `method` is: PormG marks the ones it creates, a
hand-made one is adopted by its declaration and never planned away undeclared, and `inspectdb` writes
`include` back. A *unique* covering index stays unread — `UniqueConstraint` has no `include`.

## Changing composites on an existing table

`makemigrations` diffs `UniqueConstraint` and `Index` declarations against the live database the way
it diffs columns — on a table that already exists, not only when the table is first created:

| You change | `makemigrations` plans |
|---|---|
| add a `UniqueConstraint` / `Index` | `CREATE UNIQUE INDEX` / `CREATE INDEX` |
| remove one | `DROP INDEX` — or, when a table constraint backs the index, `ALTER TABLE … DROP CONSTRAINT` on PostgreSQL and a table rebuild on SQLite |
| change its `fields`, a direction, its `method`, its `opclasses`, its `expressions` or its `condition` | the drop, then the create |
| change an explicit `name` | `ALTER INDEX … RENAME TO` on PostgreSQL (`ALTER TABLE … RENAME CONSTRAINT` for a constraint); a drop and a create on SQLite, which cannot rename an index |

A declaration is matched to a live index by **what it is** — unique or not, its columns in order,
and each column's direction, the access method and each column's operator class, and for an
expression or partial index the hash of its text — and never by its name. So an index some other tool created counts as the one you declared: a schema adopted from Django
keeps its `unique_together` constraint instead of gaining a second index beside it, and `inspectdb`
writes every composite it reads into the generated model, so adopting a database plans nothing. A
declaration naming a column's *default* operator class (`opclasses=("jsonb_ops",)` on a GIN index)
matches a live index built with that default.

!!! warning "An undeclared plain composite is dropped"
    The models file is the schema. A plain composite index or uniqueness constraint on a
    PormG-managed table — b-tree, ascending, default operator classes — that no `UniqueConstraint`
    or `Index` declares, including one a DBA added by hand and a one-column `CREATE UNIQUE INDEX`,
    is planned for removal, exactly as an undeclared `db_index` is. The removal is **destructive**:
    `dry_run()` lists it, and `migrate()` refuses it without `destructive=true`. Declare the index to
    keep it.

    An index with a **method, a descending column, an operator class, an expression or a
    condition** follows the [`CheckConstraint`](#How-a-CHECK-migrates) rule instead, because those
    are exactly the indexes people write by hand (a trigram GIN index, a `varchar_pattern_ops` one, a
    `lower(email)` one):

    | The live index | Declared | Not declared |
    |---|---|---|
    | carries PormG's `pormg:index` marker | kept | dropped — **destructive** |
    | has no marker (written by hand, or by Django) | **adopted** — on PostgreSQL a `COMMENT ON INDEX` adds the marker after any comment already there; on SQLite nothing is planned | **never planned away** |

    A hand-made expression or partial index is adopted only by a declaration of **its own text**, as
    the database spells it — `inspectdb`'s text, which PostgreSQL rewrites (`lower(surname::text)`).
    When a declaration asks for such an index's name with other text, the refusal prints the
    declaration that would adopt it instead, ready to paste.

    An index adopted on SQLite stays unmarked, so removing its declaration later leaves it in place;
    an explicit `name=` that renames it re-creates it, marked. A declaration cannot take the *name*
    of a hand-made index for a different shape: `makemigrations` refuses it with
    `InvalidMigrationError`, since `CREATE INDEX` would fail on the name. The marker lives in the
    index's comment on PostgreSQL, so a later `COMMENT ON INDEX` that replaces it — or a restore
    with `pg_restore --no-comments` — turns PormG's index into a hand-made one: never dropped, until
    a declaration adopts it again.

    Indexes PormG cannot reproduce are never read, so they are never dropped either: an access
    method other than the six above, `INCLUDE (…)` on a unique index, storage parameters on an advanced index (`WITH (fastupdate = off)`),
    `NULLS NOT DISTINCT`, a `DEFERRABLE` constraint, a unique index with a method, direction or
    operator class (a unique expression or condition is a `UniqueConstraint`, read like any other), and an invalid index (which
    [`check`](migrations/workflow.md#Finding-Invalid-Indexes) reports). The
    [PostgreSQL guide](postgres.md#Production-notes) lists them. A **one-column non-unique** index
    with one of those properties is skipped the same way, rather than read as a `db_index`, so it is
    never dropped either — including a one-column `EXCLUDE` constraint (see
    [What `makemigrations` manages](migrations/index.md#What-makemigrations-Manages,-Ignores,-and-Would-Drop)).

A composite over a column you are dropping goes with the column — nothing extra is planned for it.

### Index names

- A declaration **without** a `name` accepts whatever the live index is called. A table renamed by
  `makemigrations` keeps its old `<table>_<cols>_uniq` index, and that is not a change.
- An **explicit** `name` is intent: a live index over the same columns under another name is renamed
  to it.
- Index names share one namespace per PostgreSQL schema (with tables and sequences) and per SQLite
  database. `makemigrations` refuses a plan that would create (or rename to) one name twice on any
  tables, or a name an index on another table still holds — move a name between tables in two
  migrations, freeing it first. On SQLite it also refuses an explicit name starting with the reserved
  `sqlite_`. PormG creates composites without `IF NOT EXISTS`, so a name some object PormG cannot
  see already holds fails the migration instead of silently leaving the table without its index.
- PostgreSQL stores at most 63 bytes of a name and truncates the rest. `makemigrations` compares the
  truncated form, so a long name does not re-plan a rename on every run, and warns when it creates
  one — two long names that share their first 63 bytes collide, so shorten one.

## Check Constraints

A table-level `CHECK` — Django's `CheckConstraint` — goes in the same `constraints=[...]` list as
`UniqueConstraint`:

```julia
Result = Models.Model(
  resultid = Models.IDField(),
  raceid   = Models.ForeignKey(Race, pk_field="raceid", on_delete="CASCADE"),
  driverid = Models.ForeignKey(Driver, pk_field="driverid", on_delete="RESTRICT"),
  grid     = Models.IntegerField(),
  laps     = Models.IntegerField(),
  points   = Models.FloatField(),
  constraints = [
    Models.UniqueConstraint(fields = ("raceid", "driverid")),
    Models.CheckConstraint(condition = "grid >= 0 AND grid <= 40", name = "result_grid_range"),
    Models.CheckConstraint(condition = "laps >= 0", name = "result_laps_non_negative"),
  ],
)
```

- **`condition` is SQL**, sent to both engines as written. It names the table's *physical* columns
  (`db_column`, where a field sets one), unqualified: `grid >= 0`, never `result.grid >= 0`, which
  does not survive a SQLite table rebuild. It is not a `Q(...)` — a CHECK is DDL, which takes no bind
  parameters. Write SQL both engines accept, as you would for `db_default`. PormG checks it only for
  the typos that would silently change the statement it lands in: a `--` or `/*` comment, an
  unterminated quote, a `;` or a `,` outside parentheses — and for quoting whose end only one engine
  can find: an `E'…'` string, a backslash right before a quote, a dollar quote or a backtick. The
  rules are the `db_default` ones, spelled out in
  [Schema Conventions](schema_conventions.md#db_default-is-rendered-verbatim,-and-that-is-a-deliberate-exception).
- **`name` is required** — it is the constraint's identity — and at most 63 bytes, PostgreSQL's limit.
  Names are unique within a model across `UniqueConstraint` and `CheckConstraint`. On PostgreSQL a
  constraint name is also unique per *table*, so `makemigrations` refuses one that another constraint
  on the table already holds — its primary key, a foreign key, or the CHECK PostgreSQL names
  `<table>_<column>_check` for a `PositiveIntegerField`.

### How a CHECK migrates

PostgreSQL rewrites a stored condition (`grid >= 0 AND grid <= 40` comes back as
`((grid >= 0) AND (grid <= 40))`), so the text in the database cannot be compared with your
declaration. Instead PormG stores a short hash of the declared condition beside every CHECK it
creates — as the constraint's `COMMENT` on PostgreSQL, as an SQL comment inside the constraint on
SQLite — and `makemigrations` reads it back:

| Change | PostgreSQL | SQLite |
|---|---|---|
| add a `CheckConstraint` | `ALTER TABLE … ADD CONSTRAINT … CHECK (…)` + `COMMENT ON CONSTRAINT` | table rebuild |
| change its `condition` | drop, then add | table rebuild |
| change only its `name` | `ALTER TABLE … RENAME CONSTRAINT` | table rebuild |
| remove it from the model | `ALTER TABLE … DROP CONSTRAINT` | table rebuild |
| declare a hand-written CHECK under its own name and condition | `COMMENT ON CONSTRAINT` only (adopts it; an existing comment is kept, the marker appended) | nothing — the next rebuild of the table writes the marker |

A new table gets its CHECKs with its `CREATE TABLE` on SQLite, and right after it on PostgreSQL.

- **Removing or replacing a CHECK is destructive**, like any `DROP` — and on SQLite so is every
  change, because it is a table rebuild. Pass `migrate(destructive = true)` after reviewing `dry_run()`.
- **Rows that break a new condition fail the migration** on both engines, inside its transaction.
- **A CHECK written by hand is never planned away.** It carries no marker, so `makemigrations` does
  not treat it as PormG's. On SQLite, though, any table rebuild — including one for a declared CHECK —
  re-creates the table from your model and drops it, with a warning that quotes it; see
  [the migrations guide](migrations/index.md#SQLite:-Table-Recreation). To keep one, declare it: a
  `CheckConstraint` under the CHECK's own name and with the same condition is adopted as it stands —
  PormG writes its marker (on PostgreSQL at once, as a `COMMENT`, which changes nothing about the
  constraint; on SQLite at the table's next rebuild), and from then on the CHECK is PormG's, re-created
  by every rebuild and dropped when the declaration goes. `generate_models_from_db` writes those
  declarations for you: on PostgreSQL every CHECK other than PormG's own column CHECKs (PostgreSQL
  names each one), on SQLite every CHECK written with `CONSTRAINT <name>`, on the table or on a column.
  An unnamed SQLite CHECK has no name to declare it under.

  One shape is not adopted in place: a hand-written CHECK that reads exactly like PormG's own column
  CHECK (`col >= 0` on an integer column, `octet_length(col) <= n` on a binary one) on a field that
  does not declare that fact. The column diff removes it as a stray and the declaration adds it back,
  marked — a drop and an add on PostgreSQL, a rebuild on SQLite, destructive either way. On a field that
  *does* declare the fact (a `PositiveIntegerField`), the column already keeps that CHECK: declare
  nothing more, or pick another name. PostgreSQL requires that (constraint names are unique per
  table, and `makemigrations` refuses the clash); SQLite has no such rule and would simply keep both —
  the column's own CHECK and the declared one.
- **A renamed or removed column must leave the condition too.** `makemigrations` refuses a plan that
  renames or removes a column a declared condition still names, with `InvalidMigrationError`. For a
  rename, PostgreSQL would keep the old condition working, but the next time the declaration is
  rendered it would name a column that no longer exists; for a removal, PostgreSQL drops the CHECK with
  the column and SQLite refuses the `DROP COLUMN`.
- A declared `condition = "grid >= 0"` is a table CHECK, not the column CHECK a
  `PositiveIntegerField` renders, even where the two read the same — the stored marker is what tells
  them apart.

## Unmanaged models

`managed = false` declares a model PormG **queries but never migrates** — Django's `Meta.managed =
False`. Use it for a view, or for a table another system owns:

```julia
# A view the database already holds, e.g.
#   CREATE VIEW driver_points_v AS
#     SELECT driverid AS id, driverid, SUM(points) AS points FROM result GROUP BY driverid;
Driver_points = Models.Model("driver_points_v"; managed = false,
  id       = Models.IDField(),
  driverid = Models.ForeignKey(Driver, pk_field = "driverid", db_constraint = false),
  points   = Models.FloatField(),
)

M.Driver_points.objects.
  filter("driverid__driverref" => "senna").
  values("points", "driverid__surname").
  list()
```

- **Migrations leave it alone.** `makemigrations` never creates, alters, renames or drops the table of
  an unmanaged model, and never offers it as the old name of a renamed table. Without the option a
  model over a view was planned as `CREATE TABLE` on every run (a view is not a table, so the table
  never "exists"), and a table another system owns was either altered — rebuilt, on SQLite — or,
  left undeclared, dropped.
- **Queries do not change.** Filters, joins, `__` traversal, and writes where the table accepts them
  work exactly as for any other model. The model declares only the columns it reads.
- **A foreign key into an unmanaged model needs `db_constraint = false`.** The target may be a view,
  which a foreign key cannot reference. A constrained key raises `ModelDefinitionError` at
  `set_models`, and `InvalidMigrationError` at `makemigrations`, which loads models without
  registering them. A key *from* an unmanaged model needs nothing: its table is never migrated.
- **Many-to-many:** the automatic join table is unmanaged only when **both** ends are, as in Django.
  With one managed end the join table is created, and its key into the unmanaged end carries no
  constraint.
- **Declared `indexes` and `constraints` are not migrated either.** They may still document the
  table, but PormG does not create, compare or drop them.
- **Nothing checks the declaration against the database yet.** A declared column the view lacks is
  found by the first query that reads it; reporting it from `Migrations.check()` is tracked in #738.
- `managed` is a model option, like `db_table`, so a *column* named `managed` is declared with
  `db_column` — see the warning under [`Model`](@ref PormG.Models.Model).

The view itself is yours to create and change, for example as manual SQL in a migration.

### Generating models for existing views

The live-database importers skip views by default, as `makemigrations` does. Pass
`include_views = true` to also write each view (and, on PostgreSQL, each materialized view) as an
unmanaged model, after the tables:

```julia
PormG.Migrations.import_models_from_postgres("db"; include_views = true)
PormG.Migrations.import_models_from_sqlite("db_sl"; include_views = true)
```

`include_table` and the ignore lists filter views by name, as they filter tables. A view has no
primary key, and PormG does not guess one: nothing in a view guarantees that a column is unique, and a
guessed key would return duplicate rows as if they were one. So the generated model is keyless, and a
marker above it says so. For
`CREATE VIEW driver_points_v AS SELECT driverid, SUM(points) AS points FROM result GROUP BY driverid`
on PostgreSQL:

```julia
# PormG: generated from the view 'driver_points_v' — managed = false, so migrations never create, alter or drop it. A view has no primary key, so none is declared: reads work, but writes that address rows by key (a filtered delete, bulk_update without match_on) need one — mark a column that is unique in the view primary_key = true.
Driver_points_v = Models.Model("driver_points_v", managed = false,
  driverid = Models.BigIntegerField(null=true),
  points = Models.FloatField(null=true))
```

Reads, filters and aggregates work on a keyless model. The writes that address rows by key — a
filtered `delete()`, `bulk_update` without `match_on`, an upsert without a conflict `target` — raise,
naming the fix. A foreign key a view exposes is generated as a plain column, because a view has no
foreign-key constraint to read; declare it as a `ForeignKey` with `db_constraint = false` by hand to
traverse it.

On SQLite, a view column computed by an expression — `SUM(points)`, `COUNT(*)` — has no declared type,
so it is generated as a `TextField`, and a second marker names those columns. Declare each one's real
type by hand (`FloatField`, `IntegerField`, …). As a `TextField` the column still reads, but a filter
on it compares text: `filter("points__@gt" => 10)` matches nothing. On SQLite, a view that no longer
resolves — it reads a table or column dropped since it was created — is skipped with a warning and a
marker instead of stopping the import.

## Naming Conventions and Considerations

### Model Naming Rules
- **Use snake_case with capitalized first letter**: `User`, `Product`, `Order_item`
- **Use singular nouns**: `User` not `Users`, `Product` not `Products`
- **Be descriptive and clear**: `User_profile`, `Product_category`, `Order_history`

### Model Organization
- **Keep models in `db/models.jl`** or similar organized structure
- **Group related models together** in logical sections
- **Use meaningful comments** to explain complex relationships

## Development Workflow

PormG supports two primary workflows for model creation:

### 1. Model-First (Recommended for New Projects)
1. Define your models in a `models.jl` file.
2. Use `PormG.Migrations.makemigrations()` to detect changes.
3. Use `PormG.Migrations.migrate()` to apply them to your database.

### 2. DB-First (Legacy or Existing Databases)
If you already have a database, you can use the **`PormG.setup()`** utility to generate your model code automatically:

```julia
using PormG
# This will introspect the DB and create a basic models.jl for you
PormG.setup("path/to/my/db") 
```

---

## Loading Models in Your Application

### Using `@import_models` (Recommended)
The `@import_models` macro is the recommended way to load models in your application:

```julia
# In your main module (e.g., mypkg.jl):
module MyApp
    using PormG
    
    # Load models from external file with hot-reload support
    PormG.@import_models "db/models.jl" my_models
    import .my_models as M
    
    # Now use M.Driver, M.Race, M.Result, etc.
    # Models automatically update when you edit db/models.jl and save
end
```

#### What `@import_models` Does
1. **Resolves the model file path** relative to your source file
2. **Tracks the file with Revise** (if available) for hot-reloading in interactive sessions
3. **Registers models** with PormG so fields and metadata are indexed
4. **Injects `__init__()`** to re-register models after package precompilation
5. **Enables hot-reloading**: Edit your `models.jl`, save, and model changes appear instantly in the REPL

### Inline Models (without a separate file)
If you define models directly in code rather than a separate file, use the `@models_module` macro:

```julia
PormG.@models_module my_models "db" begin
    import PormG.Models as M

    Driver = M.Model("drivers",
        driverid = M.IDField(),
        forename = M.CharField()
    )
end
import .my_models as M
```

`@models_module` handles registration automatically — no manual `set_models()` call is needed.


## Hot-Reloading Model Definitions

When using `@import_models` with `Revise.jl`, model changes are automatically detected and applied:

```julia
# Your REPL session (with Revise.jl loaded):
julia> using MyApp
julia> M.Driver.fields  # Shows current fields: id, name

# Edit db/models.jl to add a field, save the file...

julia> M.Driver.fields  # Automatically updated with new field!
```

This enables rapid development and testing without restarting Julia. When you modify models:
- Add new fields
- Remove fields
- Change field types
- Adjust field parameters

All changes are automatically reloaded and available in the next REPL command.

## Supported Field Types

PormG provides comprehensive field types for all common database scenarios:

- **Primary Key Fields**: `IDField` (`CharField`, `UUIDField`, `ForeignKey` and `OneToOneField` also accept `primary_key=true`)
- **Text Fields**: `CharField`, `TextField`, `EmailField`
- **Numeric Fields**: `IntegerField`, `BigIntegerField`, `FloatField`, `DecimalField`
- **Date/Time Fields**: `DateField`, `DateTimeField`, `TimeField`, `DurationField`
- **Other Types**: `BooleanField`, `ImageField`, `BinaryField`, `UUIDField`, `JSONField`
- **Network Address Fields** (PostgreSQL only): `GenericIPAddressField`, `CIDRField`
- **Relationship Fields**: `ForeignKey`, `OneToOneField`

For detailed documentation on each field type, including parameters, examples, and best practices, see [Field Types Reference](fields.md).




## Post-Precompilation Behavior

When your package is precompiled (e.g., after `import MyPkg`), the `@import_models` macro ensures models are **automatically re-registered** via injected `__init__()` functions. This means:

- Models are available in package code without manual registration
- Hot-reloading continues to work in interactive sessions
- No additional setup is required for REPL users

---
For more details, see the [PormG Documentation](index.md) or the example scripts in the `test/integration/` folder.
