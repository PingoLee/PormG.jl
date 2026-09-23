# PormG Usage — Setup, Models, Fields & Migrations

Supporting file for [`SKILL.md`](SKILL.md). Read it when **setting up a project, defining or
changing models, choosing a field type, or running migrations**. Full detail:
[Models](https://pingolee.github.io/PormG.jl/stable/models/),
[Fields](https://pingolee.github.io/PormG.jl/stable/fields/),
[Migrations](https://pingolee.github.io/PormG.jl/stable/migrations/workflow/).

## Project setup

```julia
using PormG, LibPQ   # or SQLite — a driver package is required, PormG does not bundle one

PormG.setup()        # first time only, interactive: writes db/connection.yml and db/models.jl

PormG.Configuration.load("db")                  # BEFORE importing models
PormG.@import_models "db/models.jl" models      # hot-reload-aware (Revise) import
import .models as M
```

`@import_models` resolves its path relative to the file that calls it. It evaluates the models
module and registers every model with PormG. Prefer it to `include` — it is what makes a model
edit reload cleanly under Revise.

To define a few models inline — a script, a test — `@models_module` builds and registers the
module in one step:

```julia
PormG.@models_module Scratch "db" begin
    Driver = Models.Model("drivers",
        driverid = Models.IDField(),
        surname  = Models.CharField(max_length = 50),
    )
end
```

## Defining models

Models live in a module, one `Models.Model(...)` per table, and the module ends with
`Models.set_models`:

```julia
module models
import PormG.Models

Circuit = Models.Model("circuits",
    circuitid = Models.IDField(),
    name      = Models.CharField(max_length = 255),
    country   = Models.CharField(max_length = 100),
)

Driver = Models.Model("drivers",
    driverid    = Models.IDField(),
    driverref   = Models.CharField(max_length = 255),
    forename    = Models.CharField(max_length = 50),
    surname     = Models.CharField(max_length = 50),
    nationality = Models.CharField(max_length = 50, null = true),
    dob         = Models.DateField(null = true),
)

Race = Models.Model("races",
    raceid    = Models.IDField(),
    year      = Models.IntegerField(),
    name      = Models.CharField(max_length = 255),
    date      = Models.DateField(),
    circuitid = Models.ForeignKey(Circuit, on_delete = "CASCADE"),
)

Result = Models.Model("results",
    resultid      = Models.IDField(),
    raceid        = Models.ForeignKey(Race, on_delete = "CASCADE"),
    driverid      = Models.ForeignKey(Driver, on_delete = "RESTRICT"),
    positionorder = Models.IntegerField(),
    points        = Models.FloatField(null = true),
)

Models.set_models(@__MODULE__, @__DIR__)   # always required, at the end
end
```

The first positional argument is the table name. A `ForeignKey` names its target model (the object,
or its name as a string for a forward reference). Its column holds the target's primary key, and
`__` traverses it in queries (`"raceid__circuitid__country"`).

### Naming rules

- **Models**: capitalized, singular, snake_case for multi-word names: `Driver`, `Driver_standings`.
- **Fields**: lowercase snake_case. Lookups are **case-sensitive**: query a field in the case it
  was declared.
- **Never use `__`** in a field or table name — it is the traversal separator.
- **A field name may not start with `_`.** For a column named like a Julia keyword, or one that
  begins with an underscore, declare a legal identifier and set `db_column`:
  `end_ = Models.CharField(db_column = "end")`.

A bad definition raises when the module loads: `FieldValidationError` for a bad field argument,
`ModelDefinitionError` for a bad model shape (two primary keys, a duplicate `related_name`, an
unresolvable `ForeignKey`). Catch `DefinitionError` to get both.

## Field types

| Field | PostgreSQL / SQLite | Key parameters |
| :--- | :--- | :--- |
| `IDField()` | `BIGINT` identity / `INTEGER` PK | `generated_always` |
| `CharField(max_length)` | `VARCHAR(n)` | `max_length`, `choices`, `default` |
| `TextField()` | `TEXT` | |
| `EmailField()` / `URLField()` / `SlugField()` | `VARCHAR` | `max_length`; `SlugField` indexes by default |
| `UUIDField()` | `UUID` / `TEXT` | `auto_add = true` generates one |
| `IntegerField()` / `BigIntegerField()` | `INTEGER` / `BIGINT` | |
| `FloatField()` | `DOUBLE PRECISION` / `REAL` | rejects `Inf`, `NaN` |
| `DecimalField()` | `NUMERIC(p,s)` | `max_digits`, `decimal_places` |
| `BooleanField()` | `BOOLEAN` | |
| `DateField()` / `TimeField()` | `DATE` / `TIME` | `auto_now_add`, `auto_now` |
| `DateTimeField()` | `TIMESTAMPTZ` / `DATETIME` (UTC text) | `auto_now_add`, `auto_now`; stored in UTC on both |
| `DurationField()` | `INTERVAL` | |
| `JSONField()` | `JSONB` / `TEXT` | `Dict`, `Vector` or a scalar; the JSONB lookups are PostgreSQL-only |
| `BinaryField()` | `BYTEA` / `BLOB` | `Vector{UInt8}`; `max_length` counts **bytes** |
| `PasswordField()` | `VARCHAR(128)` | **storage only — PormG does not hash.** Hash in your app (Django `pbkdf2_sha256$…` format) and assign the string; `auto_hash` is accepted for Django compatibility and does nothing |
| `ImageField()` | `VARCHAR` | stores a path |
| `ForeignKey(Model)` | `BIGINT` + FK constraint | `on_delete`, `related_name`, `null` |
| `OneToOneField(Model)` | `BIGINT UNIQUE` + FK | `on_delete` |
| `ManyToManyField(Model)` | a join table | managed from a row — see [`writing.md`](writing.md) |

**On every field:** `null = false`, `blank = false`, `unique = false`, `default = nothing`,
`db_index = false`, `db_column = nothing`, `editable = true`.

**`on_delete`:** `"CASCADE"`, `"RESTRICT"`, `"PROTECT"`, `"SET_NULL"`, `"SET_DEFAULT"`,
`"DO_NOTHING"`. Deleting a row that a `PROTECT`/`RESTRICT` key still references raises
`ProtectedError`.

Composite uniqueness, indexes and database defaults (`UniqueConstraint`, `Index`, `db_default`) are
in [Models](https://pingolee.github.io/PormG.jl/stable/models/).

## Migrations

PormG migrations are **state-based**: `makemigrations` diffs your models against the live schema and
plans the SQL to reconcile them. There is no dependency chain to replay. Always run the flow in
this order:

```julia
PormG.Migrations.init_migrations("db")   # once per database; safe on an existing one
PormG.Migrations.status("db")            # what is applied, what is pending
PormG.Migrations.makemigrations("db")    # plan the diff from models.jl
PormG.Migrations.dry_run("db")           # REVIEW the SQL before running it
PormG.Migrations.migrate("db")           # apply
```

- **Never skip `dry_run`.** If the plan drops a column or a table, stop and ask before applying.
  A non-interactive `migrate` refuses a destructive plan (`PormG.Migrations.DestructiveMigrationError`);
  opt in with `migrate("db", destructive = true)` only after approval.
- **Renames are only detected interactively.** When a field or table disappears and a new one
  appears, `makemigrations` asks whether it is a rename. `makemigrations("db", interactive = false)`
  answers "no" to all of them, so it plans a drop plus an add, which loses the data.
- `PormG.Migrations.discard_pending_migration("db")` throws away a planned draft (with a backup by
  default).
- `migrate` serializes on a PostgreSQL advisory lock, so two app instances starting together
  cannot both migrate. On SQLite a column change is a table rebuild — expect that in the plan.
