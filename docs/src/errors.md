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
| any filter | `FilterError` | The predicate itself is malformed |
| PostgreSQL-only features on SQLite | `BackendCapabilityError` | e.g. `iunaccent_*`, JSONB containment, window `frame=`, `with_advisory_lock(...; on_missing_lock = :error)` |
| anything else about query shape | `QueryBuildError` | The long-tail default |

### Writing

| Call | Raises | When |
|---|---|---|
| `create` / `update` / `delete`, bulk, M2M mutators | `WritesDisabledError` | The connection has `change_data: false` — see [Creating Records](write/create.md) |
| `update` / `delete` with no filter | `UnsafeMutationError` | Refused as unsafe; `delete` accepts `allow_delete_all = true` |
| `delete` with `limit`/`offset`/`order_by`/`distinct`/aggregates | `UnsafeMutationError` | Those shapes make cascade counting unreliable — see [Deleting Records](write/delete.md) |
| `delete` of a row referenced with `on_delete = PROTECT` | `ProtectedError` | The *data* forbids it; reassign or delete the referencing rows first |
| `create` with a `null` value on a non-null field | `InvalidValueError` | Rejected by PormG **before** any statement is sent |
| `create` / `bulk_insert` violating a constraint | `IntegrityError` | The **database** refused it — `UNIQUE`, `FOREIGN KEY`, `NOT NULL`, `CHECK` |

### Transactions and connections

| Call | Raises | When |
|---|---|---|
| `atomic(durable = true)` inside an open transaction | `TransactionError` | It must be the outermost transaction |
| a model bound to another connection, inside a transaction | `TransactionError` | Open the transaction on that model's own connection |
| any query, connection lost mid-flight | `OperationalError` | Transient. Retry the **whole transaction**, never the statement |
| any query, pool saturated | `PoolTimeoutError` | Raise `pool_size`/`pool_timeout` — see [Advanced Configuration](configuration/advanced.md) |
| any query, database unreachable | `PoolConnectError` | Carries the `cause` and a redacted connection string |
| `with_advisory_lock(...; wait = false)` | `OperationalError` | Lock held elsewhere. **Never raised on SQLite** — see [Advisory Locks](advisory_lock.md) |
| `with_advisory_lock(...; on_missing_lock = :error)` on SQLite | `BackendCapabilityError` | SQLite has no advisory locks; the body would run unprotected, so it is refused instead |

### Configuration and migrations

| Call | Raises | When |
|---|---|---|
| `Configuration.load(...)` | `PormG.Configuration.MissingConfigurationError` | No `connection.yml` found; try `PormG.setup(path)` |
| `Configuration.load(...)` | `InvalidConfigurationError` | Unknown or missing adapter, unsupported extension, bad `extensions` shape, an environment block that is not a block of settings |
| model definition | `FieldValidationError` / `ModelDefinitionError` | Bad field argument / bad model shape. Catch `DefinitionError` for both |
| `makemigrations` / `migrate` | `InvalidMigrationError` | The migration or the schema it describes is not valid |
| `migrate` on a destructive plan | `PormG.Migrations.DestructiveMigrationError` | Non-interactive run without `destructive = true`; carries `statements` |

!!! note "Two types need a qualified name"
    `DestructiveMigrationError` and `MissingConfigurationError` are **not** on the `using PormG`
    surface — reach them as `PormG.Migrations.DestructiveMigrationError` and
    `PormG.Configuration.MissingConfigurationError`. Catching their umbrellas (`MigrationError`,
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
| `IntegrityError`, `OperationalError`, `StatementError` | `adapter`, `cause` |
| `DestructiveMigrationError` | `msg`, `statements` |

`error_message` renders any of them to a plain `String`, so it is always safe:

```julia
catch e
    e isa PormGError || rethrow()
    @error "failed" msg=error_message(e)
end
```

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

If you are upgrading an app, `UPGRADING.md` carries the greps and the concrete `before → after`
edits for each step — run `PormG.upgrade_guide(from = v"<your pinned version>")` to see only what
applies to you, and read [Upgrading PormG](upgrading.md) for the workflow.
