# PormG Usage — Errors

Supporting file for [`SKILL.md`](SKILL.md). Read it whenever you write a `try`/`catch` around PormG,
or need to know what a call raises. Full detail:
[Error Handling](https://pingolee.github.io/PormG.jl/stable/errors/),
[Error taxonomy](https://pingolee.github.io/PormG.jl/stable/api/).

## The one rule

**Every failure PormG raises about your query, data, models, configuration or database is a
subtype of `PormGError`, and none of them is an `ArgumentError`.** Catch `PormGError`, or a specific
subtype, and read the text with `error_message(e)`. The exceptions are mistakes in the call itself:
a wrong argument type, or `upgrade_guide()` without `from =`, or a non-literal
`@import_models` path. Those raise Julia's own exceptions (`MethodError`, `ArgumentError`,
`UndefKeywordError`) and should be fixed, not caught.

```julia
try
    M.Result.objects.filter("driverid__surname" => "Senna").update("points" => 25)
catch e
    e isa PormGError || rethrow()          # your own bugs and Julia misuse still propagate
    @error "PormG rejected the write" msg=error_message(e) type=typeof(e)
end
```

- **`catch ArgumentError` never matches a PormG error.** The query builder moved to typed errors in
  0.3.0 (PingoLee/PormG.jl#231), and models, fields, configuration, the pool and migrations followed (PingoLee/PormG.jl#239). A catch
  block written against the old behavior does not fail: it silently stops handling the case.
  Rewrite `e isa ArgumentError` as `e isa PormGError`, or as the specific subtype below.
- **Use `error_message(e)`, not `e.msg`.** `DoesNotExist`, `MultipleObjectsReturned`,
  `PoolTimeoutError`, `PoolConnectError` and the three `DatabaseError` subtypes carry structured
  fields and **no** `msg`, so `e.msg` throws on exactly the errors you tested least.
- Driver failures are wrapped too: never name `LibPQ.Errors.*` or `SQLite.SQLiteException`. The
  driver's own exception stays on `e.cause`.

## The taxonomy

```
PormGError
├── FieldAccessError            (umbrella)
│   ├── UnknownFieldError       field / alias / __ path does not exist (lookups are case-sensitive)
│   ├── AmbiguousFieldError     a __ path's first segment names both a CTE and a model field
│   └── LazyTraversalError      read an unprojected ForeignKey off a row — project it in values()
├── FilterError                 malformed predicate (e.g. a 2-column __@in subquery)
├── QueryBuildError             the long-tail "invalid query shape" bucket
├── UnsafeMutationError         update/delete with no filter, or another shape an UPDATE/DELETE can't express
├── ProtectedError              delete refused: rows still reference it through PROTECT/RESTRICT
├── InvalidValueError           a VALUE failed validation on insert/update (null on non-null, bad alias, …)
├── BackendCapabilityError      the backend cannot do it (PostgreSQL-only feature on SQLite)
├── UnsupportedConnectionError  internal dispatch bug — report it
├── DoesNotExist                get() matched nothing
├── MultipleObjectsReturned     get() matched more than one row
├── DefinitionError             (umbrella) raised when models.jl loads
│   ├── FieldValidationError    bad field argument
│   └── ModelDefinitionError    bad model shape (two PKs, duplicate related_name, unknown FK target)
├── ConfigurationError          (umbrella)
│   ├── InvalidConfigurationError   bad connection.yml, unknown db key, missing driver package
│   ├── WritesDisabledError         the connection has change_data: false
│   └── PormG.Configuration.MissingConfigurationError   no connection.yml (qualified name)
├── MigrationError              (umbrella)
│   ├── InvalidMigrationError
│   └── PormG.Migrations.DestructiveMigrationError      non-interactive destructive plan (qualified name)
├── PoolError                   (umbrella)
│   ├── PoolTimeoutError        pool saturated — raise pool_size / pool_timeout
│   └── PoolConnectError        database unreachable, or a connection string libpq cannot parse
├── DatabaseError               (umbrella) the statement REACHED the database and was refused
│   ├── IntegrityError          UNIQUE / FOREIGN KEY / NOT NULL / CHECK
│   ├── OperationalError        transient: dropped connection, deadlock, advisory-lock timeout
│   └── StatementError          invalid SQL, unknown table, privileges; also the unclassified landing type
└── TransactionError            the transaction API was misused (durable=true nested, wrong connection)
```

Catch an umbrella for a category, and a leaf for a specific reaction:

```julia
try
    M.Driver.objects.create("driverref" => "senna", "code" => "SEN")
catch e
    e isa IntegrityError   && return conflict(error_message(e))   # a constraint refused it
    e isa OperationalError && return retry_whole_transaction()    # transient
    rethrow()
end
```

- `FieldValidationError` fires while **defining** a model. `InvalidValueError` fires while
  **writing a value**.
- `DatabaseError` means the database refused the statement. A value PormG rejects before sending
  raises the query-side type instead.
- Around `migrate()`, catch `DatabaseError` as well as `MigrationError`: a failing `ALTER` arrives
  as a `StatementError`, not re-wrapped.
- On `OperationalError` inside a transaction, retry the **whole transaction**, never one statement.

## What raises what

| Call | Raises |
| :--- | :--- |
| `get(...)` | `DoesNotExist` / `MultipleObjectsReturned` |
| `earliest` / `latest` on an empty queryset | `DoesNotExist` (`first`/`last` return `nothing`) |
| unknown field in `filter`/`values`/`order_by`/`create` | `UnknownFieldError` |
| `update`/`delete` with no filter | `UnsafeMutationError` (`delete(allow_delete_all = true)` to opt in) |
| `delete` of a `PROTECT`-referenced row | `ProtectedError` |
| any write on a `change_data: false` connection | `WritesDisabledError` |
| `create` with `null` on a non-null field | `InvalidValueError` (nothing sent) |
| constraint violation on insert/update | `IntegrityError` |
| a PostgreSQL-only feature on SQLite | `BackendCapabilityError` |
| `atomic(durable = true)` inside a transaction | `TransactionError` |
| pool exhausted / database unreachable | `PoolTimeoutError` / `PoolConnectError` |
| `with_advisory_lock(...; wait = false)` while held | `OperationalError` |
| `Configuration.load` with bad settings | `InvalidConfigurationError` |
| a definition error in `models.jl` | `FieldValidationError` / `ModelDefinitionError` |
| non-interactive `migrate` of a destructive plan | `PormG.Migrations.DestructiveMigrationError` |

## Upgrading an app with old catch blocks

```bash
rg -n 'isa ArgumentError|catch.*ArgumentError|\.msg\b' src/
```

Replace each match around a PormG call with `PormGError`, or the matching subtype, and
`error_message(e)`. For the full list of changes since the version your app pins, run
`PormG.upgrade_guide(from = v"<pinned version>")`.
