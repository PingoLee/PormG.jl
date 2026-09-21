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
