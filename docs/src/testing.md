# Testing Your App

An application that depends on PormG wants to know, before an upgrade reaches production, whether
the new version builds different SQL for the queries the application actually runs. The cheapest
check is an **offline golden-SQL suite**: the application's real model files, a connection that
renders SQL and never connects, `inspect_query` on the application's real query shapes, and the
expected SQL pinned in the test. It opens no socket, it is deterministic, and it runs in seconds.

This page is the recipe. It pairs the offline suite with a small integration test that covers what
SQL text cannot show, and it ends with the upgrade loop that uses both.

## The fixture: `register_offline`

One call per connection key, before anything touches `.objects`:

```julia
using Test, PormG

PormG.Configuration.register_offline("db"; adapter = :postgres)
```

`Configuration.register_offline` ([API reference](api.md)) registers `key` as a connection that
renders the dialect's SQL and refuses to run anything. Its keywords are:

| Keyword | Default | Meaning |
| :--- | :--- | :--- |
| `adapter` | `:postgres` | The dialect: `:postgres` or `:sqlite`. MySQL has no offline form yet, and `:mysql` raises `InvalidConfigurationError`. |
| `django_prefix` | `nothing` | The table prefix, when the app's models were imported from Django with one: the same value its `connection.yml` would give. |
| `change_data` | `true` | The `connection.yml` setting of the same name, which defaults to `false` there. Leave it `true` to inspect `update` and `create`. |

An application with several keys registers each one: `register_offline("db")`,
`register_offline("db_archive")`, and so on. `Configuration.unregister_connection(key)` removes one.
Registering the same key again replaces the offline entry.

**PostgreSQL needs no driver package.** An offline **SQLite** key needs `using SQLite`. A few clauses
depend on the SQLite library's version. `NULLS FIRST`/`LAST` renders natively from 3.30 and is
emulated below it, while window functions and `RIGHT`/`FULL` joins are refused below their versions.
Without the package that version cannot be read, so building such a query raises
`InvalidConfigurationError`. With the package, the SQL follows the SQLite library the environment
resolves, so pin it on the environment CI runs (#1452).

### Load the model files after it

```julia
PormG.@import_models "db/models.jl" models
import .models as M
```

The models bind to the offline key the same way they bind to a loaded configuration: the folder
`"db"` matches the key `"db"`. `Models.set_models(mod, "db")` does the same for a module that is
already defined.

**Import the model files, not the application.** When `using App` runs the app's own
`Configuration.load("db"; env = …)`, in its module body or its `__init__`, that `load` raises
`InvalidConfigurationError`: a key registered offline is never replaced by a live pool, and
`force = true` does not change that (#1451). Point `@import_models` at the app's models files, and
keep whatever the suite needs from the app (a function that builds a query, say) in a file that does
not load a configuration.

Without the fixture, the suite does not quietly reach a database either. Outside a REPL, registering
models against a folder that nothing loaded raises `InvalidConfigurationError` (#1226). Before
0.9.0, PormG loaded the folder itself, so an "offline" suite opened a real pool on its first
`.objects`. If your suite hits that error, add `register_offline`. Do not add a `load`, and do not
pass `implicit = true`. A REPL still loads the folder implicitly, with a warning, so a suite you
`include` from one needs `register_offline` there too.

## Pin the SQL

[`inspect_query`](api.md) builds a query without running it and returns
its SQL text and its bound parameters. Pin both. Squash the whitespace first, so that a release that
only reflows the SQL does not fail the suite:

```julia
squash(sql) = replace(strip(sql), r"\s+" => " ")

@testset "Senna's results from 1988: two joins, two bound values" begin
    q = M.Result.objects.
        filter("driverid__surname" => "Senna", "raceid__year__@gte" => 1988).
        values("raceid__year", "points")
    info = inspect_query(q)
    @test squash(info[:sql_text]) ==
          "SELECT \"Tb_1\".\"year\" as \"raceid__year\", \"Tb\".\"points\" as \"points\" " *
          "FROM \"result\" as \"Tb\" " *
          "INNER JOIN \"race\" AS \"Tb_1\" ON \"Tb\".\"raceid\" = \"Tb_1\".\"raceid\" " *
          "INNER JOIN \"driver\" AS \"Tb_2\" ON \"Tb\".\"driverid\" = \"Tb_2\".\"driverid\" " *
          "WHERE \"Tb_2\".\"surname\" = \$1 AND \"Tb_1\".\"year\" >= \$2"
    @test info[:parameters] == ["Senna", 1988]
end
```

Pin a query where the application builds it, in the shape the application uses. One testset per
distinct shape is enough. The point is to cover each join path, aggregate, subquery and write the
application issues, not each value it binds.

**Writes are pinned the same way.** Every terminal takes `show_query = :dict`, which returns the same
dictionary as `inspect_query` without running anything:

```julia
@testset "Zeroing one race's points: an UPDATE with the WHERE bound first" begin
    info = M.Result.objects.filter("raceid" => 1).update("points" => 0, show_query = :dict)
    @test squash(info[:sql_text]) ==
          "UPDATE \"result\" AS \"Tb\" SET \"points\" = \$2 WHERE \"Tb\".\"raceid\" = \$1"
    @test info[:parameters] == [1, 0]
end
```

The order of `info[:parameters]` is the order the placeholders are numbered. On PostgreSQL it can
differ from the order the values appear in the text. Above, `$1` is the `WHERE` value. Pinning both
is what catches a value bound to the wrong placeholder.

**A cascading `delete()` cannot be pinned offline yet.** When other models reference the one being
deleted, the planner reads the database to plan the statements it renders (the root's keys, the
related rows). On an offline key, even `delete(show_query = :dict)` then raises
`InvalidConfigurationError` (#1453). Cover those `delete()` shapes in the integration suite.

**Refusals are pinned by type.** When the application relies on PormG refusing something, pin it
with the error type, never with the message text:

```julia
@testset "An offline key renders SQL but never runs it" begin
    @test_throws InvalidConfigurationError M.Driver.objects.filter("surname" => "Senna").list()
end
```

The error types are listed on the [Error Handling](errors.md) page.

## What it catches, and what it cannot

| The offline suite catches | It cannot catch |
| :--- | :--- |
| A change in the rendered SQL: joins, aliases, grouping, ordering, the clauses a function compiles to | The Julia type a read returns (`Float64` vs `Decimal`, a `Vector`, a `DateTime` vs a `ZonedDateTime`) |
| A change in the bound parameters, their order or their values | The rows a query returns |
| A query that now raises at build time, or no longer raises | Anything the engine decides: a collation, an index, a constraint, a server-version difference |

The right column needs a database. Cover it with **one integration test per shape**, not per
query, against the application's test database:

```julia
using Test, PormG, SQLite

PormG.Configuration.load("db"; env = "test")
PormG.@import_models "db/models.jl" models
import .models as M

@testset "Senna's 1991 season: 16 rows, points read as Float64" begin
    rows = M.Result.objects.
        filter("driverid__surname" => "Senna", "raceid__year" => 1991).
        values("raceid__round", "points").
        list()
    @test length(rows) == 16
    @test first(rows).points isa Float64
    @test sum(r -> r.points, rows) == 96.0
end
```

Keep that file in its own process, apart from the offline suite. A key is either offline or loaded:
a `load` of a key the offline suite registered raises `InvalidConfigurationError` (#1451).

## Why not a hand-written mock backend

Before `register_offline` existed (#1229), applications built this fixture by hand:

```julia
# ✗ a type-only backend written into PormG's internal dictionary
struct DummyPostgres <: PormG.PormGPostgres end
PormG.config["db"] = PormG.Configuration.Settings(connections = DummyPostgres(), …)
```

That writes `PormG.config` and calls the `Settings` constructor, both internal. Their fields
(`db_def_folder` has to match the models folder, for one) can change in any release with no
upgrade entry. It also subtypes an abstract backend with a struct that is not a pool, so a query
that reaches a pool method or a server-version check fails with an error about the backend, not
about the query. Replace it with `register_offline`. To ask which keys are registered, call
`Configuration.loaded_keys()`, not the dictionary.

## The upgrade loop

With both suites green on the PormG version the application pins today:

1. **Bump the pin** in the application's `Project.toml` `[compat]`, then `Pkg.update("PormG")`.
2. **Read what changed.** `PormG.upgrade_guide(from = v"0.9")`, with the version the application
   was pinned to, lists every entry since. It reads the change log shipped with the PormG that is
   now installed, so it comes after the update. See [Upgrading PormG](upgrading.md).
3. **Run the offline suite.** Each failing pin is a diff between the SQL the application issued and
   the SQL it will issue now.
4. **Read each diff against the entries.** If an entry explains it and its `before → after` applies
   to the call, edit the call. If the entry says the new SQL is the fix, re-pin the new SQL. A diff
   that **no entry explains** is a behavior change that shipped without warning: report it at
   [PormG's issues](https://github.com/PingoLee/PormG.jl/issues). Whitespace never shows up as a
   diff, because the pins are squashed.
5. **Run the integration shapes**, for what the SQL text cannot show.

Pin each SQL string by running the query, never by writing it from memory. After step 4, the pins
record what the new version builds, and the next upgrade starts from them.
