# Error Handling

Every failure PormG raises for a *domain* problem is a subtype of `PormGError`, so one `catch`
clause covers the whole surface:

```julia
try
    M.Result.objects.filter("driverid__surname" => "Senna").update("points" => 25)
catch e
    e isa PormGError || rethrow()
    @error "PormG rejected the write" msg=error_message(e) type=typeof(e)
end
```

`rethrow()` on anything that is not a `PormGError` matters: your own exceptions, and Julia-level
misuse such as a missing keyword argument, still propagate as themselves. Only *driver* failures
are wrapped into the taxonomy.

This page is the **task-oriented** view — which operation raises what, and how to react. For the
full type-by-type reference, including every umbrella and the fields each type carries, see
[Error taxonomy](api.md#Error-taxonomy) in the API reference.

## Which operation raises what

Catch the umbrella when you want a category, the concrete type when you want a reaction.

### Reading

| Call | Raises | When |
|---|---|---|
| `get(...)` | `DoesNotExist` | No row matched |
| `get(...)` | `MultipleObjectsReturned` | More than one row matched; carries `count` |
| `earliest(...)` / `latest(...)` | `DoesNotExist` | Empty queryset — unlike `first()`/`last()`, which return `nothing` |
| `row.driverid` on an unprojected `ForeignKey` / `OneToOneField` | `LazyTraversalError` | PormG never lazily loads a relation — project it with `values(...)` |
| any filter, `values` or `order_by` | `UnknownFieldError` | The field name does not exist on the model (lookups are case-sensitive). Names the table searched and its available fields |
| any filter | `FilterError` | The predicate itself is malformed — an unknown lookup, an operator misused, a list where one value belongs, an `isnull` that is not a `Bool` |
| any filter, with a value its field cannot take | `InvalidValueError` | Text in a number column, a malformed date or UUID, a date part outside its range under `=` or `@in` (a `@year` outside 1–9999 included), a `@yyyy_mm` that is not a calendar month, a `@family` other than 4 or 6, a JSON path compared with a value that is not a base-10 number, or with `Inf` / `NaN`. The same type a write raises (it was a `FilterError` until #971 and #988); the message names the field, never the value |
| PostgreSQL-only features on SQLite | `BackendCapabilityError` | e.g. `iunaccent_*`, the `regex` / `iregex` lookups and their negated twins, full-text search (`@search`, `SearchRank`, `SearchHeadline`), JSONB containment, window `frame=`, `with_advisory_lock(...; on_missing_lock = :error)`, a `ToChar` format outside the portable table, a `Cast`, or a `Case`/`Coalesce`/`Greatest`/`Least` `output_field`, to `timestamp`, `time` or `interval` |
| `makemigrations` on SQLite | `BackendCapabilityError` | A `DecimalField` declares `max_digits` above 15, which SQLite cannot store exactly — see [`DecimalField`](fields.md#DecimalField(max_digits,-decimal_places)) |
| anything else about query shape | `QueryBuildError` | The long-tail default |

Between `FilterError` and `InvalidValueError` on a filter, the rule is: **a value that would be
bound as a parameter is refused with `InvalidValueError`; an argument that shapes the SQL is refused
with `FilterError`.** So a bad value — the part of a filter an end user usually supplies — is an
`InvalidValueError` whichever check refuses it, the field's or the lookup's own (#988).

### Writing

| Call | Raises | When |
|---|---|---|
| `create` / `update` / `delete`, bulk, M2M mutators | `WritesDisabledError` | The connection has `change_data: false` — see [Creating Records](write/create.md) |
| `update` / `delete` with no filter | `UnsafeMutationError` | Refused as unsafe; `delete` accepts `allow_delete_all = true` |
| `delete` with `limit`/`offset`/`order_by`/`distinct`/aggregates | `UnsafeMutationError` | Those shapes make cascade counting unreliable — see [Deleting Records](write/delete.md) |
| `update` on a handler with a filter on a `values()` alias | `UnsafeMutationError` | The filter resolves through the projection, which an `UPDATE` does not carry; a plain `values()` is ignored — see [Updating Records](write/update.md) |
| `bulk_update` on a handler with `limit`/`offset`/`order_by`/`distinct`/aggregates, a CTE, a `cjoin`, or a filter on a `values()` alias | `UnsafeMutationError` | An `UPDATE` cannot express them; the handler's plain filters are kept — see [Bulk Operations](write/bulk.md) |
| `delete` of a row referenced with `on_delete = PROTECT` | `ProtectedError` | The *data* forbids it; reassign or delete the referencing rows first |
| `create` / `update` naming a field that does not exist | `UnknownFieldError` | Same message as the read path above — names the table searched and its available fields. Reverse accessors are **not** listed: they are addressable in a filter path, but they are not columns you can write |
| bulk writers, `get_or_create` / `update_or_create` naming a field that does not exist | `UnknownFieldError` | Same type, with their own wording and no available-field list — usually the model and the field, and for a `bulk_update` `columns=` mapping the DataFrame's columns instead |
| `create` with a `null` value on a non-null field | `InvalidValueError` | Rejected by PormG **before** any statement is sent |
| `create` / `update` / the bulk writers with a value its field cannot take | `InvalidValueError` | Rejected **before** any statement is sent. The message names the operation, the field and, for a bulk write, the row — never the value, which could be a secret. The same facts are fields on the error: `e.kind` (`:type`, `:format`, `:range`, `:nul`, `:json_nul`, `:other`), `e.field`, `e.row` |
| a text value containing a NUL character (`'\0'`): in a filter, a write (`create`, `update`, the bulk writers), a raw `fetch` value or an advisory-lock key | `InvalidValueError` | Rejected **before** any statement is sent, the same on every backend: PostgreSQL text cannot store a NUL, and the drivers would truncate the value or fail. A write names the field, a bulk write the row too; binary values are not affected. A `JSONField` value is the next row |
| a `JSONField` value containing a NUL character (JSON writes it as `\u0000`): in a write, a `@jcontains` filter or a `get_or_create` lookup | `InvalidValueError` | Rejected **before** any statement is sent, the same on every backend: PostgreSQL `jsonb` cannot store `\u0000`, and SQLite is refused too so the engines agree. A write names the field, a bulk write the row too. The six-character text `\u0000` — a backslash followed by `u0000` — is not a NUL and is stored as written |
| `create` / `bulk_insert` violating a constraint | `IntegrityError` | The **database** refused it — `UNIQUE`, `FOREIGN KEY`, `NOT NULL`, `CHECK` |

### Transactions and connections

| Call | Raises | When |
|---|---|---|
| `atomic(durable = true)` inside an open transaction on the same database | `TransactionError` | It must be the outermost transaction |
| an ORM call on a database with no open transaction — by the model's binding or routed with `.db()` — while a transaction is open on another | `TransactionError` | Wrap the call in `atomic` on the database it runs on, or move it outside the transaction |
| `without_foreign_keys` inside an open transaction on the same database | `TransactionError` | It must be the outermost transaction, on both engines |
| any query, connection lost mid-flight | `OperationalError` | Transient. Retry the **whole transaction**, never the statement |
| any query, pool saturated | `PoolTimeoutError` | Raise `pool_size`/`pool_timeout` — see [Advanced Configuration](configuration/advanced.md) |
| any query, database unreachable | `PoolConnectError` | Carries the `cause` and a redacted connection string |
| any query, PostgreSQL connection string libpq cannot parse | `PoolConnectError` | Fails fast; `cause` is an `InvalidConfigurationError` with the quoted fragment masked — see [Advanced Configuration](configuration/advanced.md) |
| `with_advisory_lock(...; wait = false)` | `OperationalError` | Lock held elsewhere. **Never raised on SQLite** — see [Advisory Locks](advisory_lock.md) |
| `with_advisory_lock(...; on_missing_lock = :error)` on SQLite | `BackendCapabilityError` | SQLite has no advisory locks; the body would run unprotected, so it is refused instead |

### Configuration and migrations

| Call | Raises | When |
|---|---|---|
| `Configuration.load(...)` | `PormG.Configuration.MissingConfigurationError` | No `connection.yml` found; try `PormG.setup(path)` |
| `Configuration.load(...)` | `InvalidConfigurationError` | Unknown or missing adapter, unsupported extension, bad `extensions` shape, an environment block that is not a block of settings, an absolute `path` together with `root` |
| `upgrade_guide(...)` | `InvalidConfigurationError` | The `upgrading/` log bundled with the install is missing or holds no entries — a broken install, reported so it cannot read as *"nothing to port"* |
| model definition | `FieldValidationError` / `ModelDefinitionError` | Bad field argument / bad model shape. Catch `DefinitionError` for both |
| `makemigrations` / `migrate` / `dry_run` | `InvalidMigrationError` | The migration or the schema it describes is not valid — a plan file that does not parse, say, or a label that reads like a data step (`Data (Pre):`, `data (post):`) but is neither `Data (pre):` nor `Data (post):`, or a `# pormg-lossy-alter:` line marked `handled=pre` that is misspelt, sits on a change that cannot take it, or is in a plan with no `Data (pre):` step. No pending plan is **not** one: `migrate` returns `outcome = :nothing_pending` |
| `makemigrations` over a pending plan holding data steps | `InvalidMigrationError` | The plan has hand-written `Data (pre):`/`Data (post):` steps, which `makemigrations` cannot regenerate, so it neither overwrites nor discards it. Apply it with `migrate` first, or move the steps out |
| `run_once` inside an open transaction | `TransactionError` | A data step commits on its own, with its record. Call it outside the transaction block |
| `makemigrations` / `migrate` / `status` / `dry_run` / `discard_pending_migration` / `import_models_from_*` | `InvalidConfigurationError` | The key is a `register_connection` entry, which has no models folder — see [Dynamic Multi-Tenancy](configuration/dynamic.md) |
| `migrate` on a destructive plan | `PormG.Migrations.DestructiveMigrationError` | Non-interactive run without `destructive = true`; carries `statements`, and `lossy_alters` for a column change that alters existing values |
| `migrate` on a plan whose column or constraint change would fail on existing rows | `PormG.Migrations.MigrationPrecheckError` | Non-interactive run; nothing was written. `destructive = true` does not bypass it. Carries `findings`; a change marked `handled=pre` is never among them |
| `migrate` on a database that no longer holds the schema the plan was generated against | `PormG.Migrations.PlanPreconditionError` | No statement of the plan ran and no `failed` row was recorded. Regenerate the plan against this database, or remove its `# pormg-schema-table:` lines. Carries `tables` |

!!! note "Four types need a qualified name"
    `DestructiveMigrationError`, `MigrationPrecheckError`, `PlanPreconditionError` and
    `MissingConfigurationError` are **not** on the `using PormG` surface — reach them as
    `PormG.Migrations.DestructiveMigrationError`, `PormG.Migrations.MigrationPrecheckError`,
    `PormG.Migrations.PlanPreconditionError` and `PormG.Configuration.MissingConfigurationError`. Catching their umbrellas (`MigrationError`,
    `ConfigurationError`) works unqualified.

## Reading a caught error

Use `error_message(e)`, not `e.msg`. Most types carry a `msg` field, but eight do not — they carry
structured fields instead, and `e.msg` on those is a `FieldError`:

| Type | Fields instead of `msg` |
|---|---|
| `DoesNotExist` | `model_name`, `filters` |
| `MultipleObjectsReturned` | `model_name`, `count`, `filters` |
| `PoolTimeoutError` | `adapter`, `pool_size`, `max_size`, `attempts`, `elapsed_seconds` |
| `PoolConnectError` | `adapter`, `cause`, `connection`, `attempts`, `elapsed_seconds` |
| `IntegrityError`, `OperationalError`, `StatementError` | `adapter`, `cause`, and the reason as data: `sqlstate`, `constraint`, `table`, `column`, `message` |
| `DestructiveMigrationError` | `msg`, `statements`, `lossy_alters` |
| `MigrationPrecheckError` | `msg`, `findings` |
| `PlanPreconditionError` | `msg`, `tables` |

`error_message` renders any of them to a plain `String`, so it is always safe:

```julia
catch e
    e isa PormGError || rethrow()
    @error "failed" msg=error_message(e)
end
```

### A database error is safe to show

`IntegrityError`, `OperationalError` and `StatementError` carry the reason the database gave as
data, and their text is built from those fields alone: `error_message(e)`, `showerror` and
`string(e)` never contain the database's `DETAIL`, `HINT` or `LINE n:` excerpt, which quote the
row. So `error_message(e)` is safe to return to a client (#987).

| Field | What | LibPQ | Postgres.jl | SQLite |
|---|---|---|---|---|
| `sqlstate` | The SQLSTATE, e.g. `"23505"` for a unique violation | ✓ | ✓ | — |
| `constraint` | The constraint that refused the row | ✓ | ✓ | — |
| `table`, `column` | The table and column the server named | ✓ | ✓ | — |
| `message` | The server's primary message | ✓ | ✓ | ✓ |

A field the driver does not report is `nothing`, and so is one the server did not send for that
error: a unique violation names its `constraint` and `table`, a `NOT NULL` violation its `table` and
`column`, a syntax error none of the three. The same holds for a `bulk_copy` that violates a
constraint.

`message` is `nothing` for SQLSTATE class `22`, a data exception: PostgreSQL builds that message from
the input (`invalid input syntax for type uuid: "<value>"`), so the error states only the SQLSTATE.
A value PormG binds as a parameter never appears. Text your app wrote itself still can — the message
of a trigger's `RAISE EXCEPTION` (SQLSTATE `P0001`), or a literal typed into raw SQL that a syntax
error quotes back.

Branch on the fields, not on the message:

```julia
catch e
    e isa IntegrityError && e.sqlstate == "23505" && return conflict(error_message(e))
    rethrow()
end
```

The driver's own exception, with the full text the server sent, is in `e.cause`. Log
`sprint(showerror, e.cause)` only to a sink you trust with the row's data.

## What reaches your logs

PormG's own log lines never carry the database's DETAIL or the value it refused: a driver message
can quote the value, and a value can be a password or a token. When `with_transaction` fails it logs
the classified type, the driver's exception type, the SQLSTATE and `error_message(e)` — the safe text
above — then raises the error to you. A failed `ROLLBACK` is logged with the driver's own exception;
that statement binds no values.

The LibPQ driver logs separately, through its own [Memento](https://github.com/invenia/Memento.jl)
logger. Every failed statement prints the server's full message there at `warn` — `DETAIL`
included, which on a unique violation names the value:

```text
[warn | LibPQ]: UniqueViolation: ERROR:  duplicate key value violates unique constraint "drivers_code_key"
DETAIL:  Key (code)=(SEN) already exists.
```

PormG does not reconfigure a driver's logging. To keep that text out of your logs, raise the
logger's level once at startup — the error is still raised to your code:

```julia
using LibPQ
LibPQ.Memento.setlevel!(LibPQ.LOGGER, "critical")
```

The SQLite driver does not log a failed statement, and Postgres.jl logs one only in its debug mode.

## Catching a whole category

The abstract umbrellas exist so a handler can name a family without listing its members:

```julia
try
    PormG.Configuration.load("db_2")
    PormG.Migrations.migrate()
catch e
    if e isa ConfigurationError
        @error "Fix connection.yml and retry" msg=error_message(e)
    elseif e isa MigrationError
        @error "The migration plan was rejected" msg=error_message(e)
    else
        rethrow()
    end
end
```

The umbrellas are `FieldAccessError`, `DefinitionError`, `ConfigurationError`, `MigrationError`,
`PoolError` and `DatabaseError`, all under `PormGError`.

`DatabaseError` is the boundary worth understanding: it means the statement **reached** the
database and was refused there. A value PormG rejects before sending — a null on a non-null field,
an unknown column — never gets that far and raises the query-side type instead.

## Coming from an older PormG

The taxonomy replaced the untyped errors and driver-native exceptions PormG used to raise, across
several releases — so a `catch` block written against an older version may no longer match. The
deliberate clean break is spelled out in [Error taxonomy](api.md#Error-taxonomy).

If you are upgrading an app, the change log carries the greps and the concrete `before → after`
edits for each step — run `PormG.upgrade_guide(from = v"<your pinned version>")` to see only what
applies to you, and read [Upgrading PormG](upgrading.md) for the workflow.
