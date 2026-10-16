# PormG Usage — Inspecting Queries & Diagnosing Problems

Supporting file for [`SKILL.md`](SKILL.md). Read it when a query returns the wrong thing, you need
the generated SQL, or the connection pool misbehaves. Full detail:
[API reference](https://pingolee.github.io/PormG.jl/stable/api/),
[Advanced Configuration](https://pingolee.github.io/PormG.jl/stable/configuration/advanced/).

## See the SQL without running it

Every terminal accepts `show_query`:

| `show_query =` | Returns |
| :--- | :--- |
| `:execute` | the result (default) |
| `:sql` | the SQL `String` |
| `:pretty` | the same SQL reflowed one clause per line — for a log line; only whitespace changes |
| `:dict` | a `Dict` with `:sql_text`, `:parameters`, `:parameter_count`, `:parameter_buckets`, `:dialect`, `:bucketing`, `:model`, `:operation` — the same keys for every operation |
| `:params` | the bound parameters only |
| `:none` | `nothing` — builds the query and skips the round-trip, for benchmarking |

```julia
q = M.Result.objects.filter("driverid__surname" => "Senna").values("raceid__year", "points")

q.list(show_query = :sql)                                  # the SELECT
q.update("points" => 0, show_query = :dict)[:parameters]   # a mutation, inspected — never runs
q.delete(show_query = :sql)

info = inspect_query(q)            # or q.inspect(), or q |> inspect_query()
info[:sql_text]; info[:parameters]; info[:dialect]
```

Placeholders differ by backend: `$1, $2, …` on PostgreSQL, `?` on SQLite. Values are always
parameters. If a value appears inline in the SQL text, that is a bug worth reporting.

### Testing SQL without a database

A golden-SQL test needs a configuration to bind the models to, but no server. Register the key
**offline** — it renders the dialect's SQL and refuses to run anything:

```julia
using Test, PormG
PormG.Configuration.register_offline("db"; adapter = :postgres)   # or :sqlite
PormG.@import_models "db/models.jl" models

q = models.Driver.objects.filter("surname" => "Senna")
@test inspect_query(q)[:sql_text] ==
      "SELECT\n    *\nFROM \"drivers\" as \"Tb\"\nWHERE \"Tb\".\"surname\" = \$1\n"
@test PormG.Models.connection_key(models.Driver) == "db"

PormG.Configuration.unregister_connection("db")
```

Do not write a mock backend type into `PormG.config` by hand: `register_offline` is the public
form of that, and `Configuration.loaded_keys()` answers "what is loaded?".

### A test double that refuses what a write refuses

A test double that stands in for `M.Model.objects` is only useful if it refuses what PormG would
refuse. Do not copy PormG's rules into it. Call `validate_value(model, field, value)` for each
value: it runs exactly the checks `create` runs on a field (an unknown name, NULL, type and range,
`max_length`, a decimal's width, a malformed date or UUID, a collection, a NUL character, a value
the model's engine cannot bind). It throws the same error, and returns the value as PormG formats
it for binding. It sends nothing, so an offline key is enough. A rule added in a
later release reaches the double with no edit:

```julia
struct FakeDrivers
    rows::Vector{Dict{String, Any}}
end

function create(fake::FakeDrivers, pairs::Pair...)
    row = Dict{String, Any}(String(k) => validate_value(M.Driver, String(k), v) for (k, v) in pairs)
    push!(fake.rows, row)
    return row
end

fake = FakeDrivers([])
@test_throws InvalidValueError create(fake, "surname" => "Se\0nna")   # the NUL PormG refuses
```

Give the double's `update` the same loop, but pass an `F` expression or a SQL function through
without calling `validate_value`: a real `update` writes it as SQL, and `validate_value`, like
`create`, does not accept it. The double then does not check the names inside the expression,
which a real `update` resolves when it builds the statement. A real `update` also refuses a primary key, which `validate_value` allows, as
`create` does. It checks one field at a time and sends nothing, so it
cannot see what only the database or the whole row decides: uniqueness, foreign keys, `CHECK`
constraints, or a required field left out.

## See the plan the database chooses

`show_query` shows what PormG sends; `.explain()` asks the database how it would run the `SELECT`:

```julia
plan = q.explain()                 # or explain_query(q)
plan[:indexes_used]                # the indexes the plan uses
plan[:seq_scans]                   # the tables it reads in full
q.explain(analyze = true)          # PostgreSQL only: EXECUTES the query, adds :execution_time_ms
```

It is read-only — it explains the `SELECT`, never a write. On SQLite only `EXPLAIN QUERY PLAN`
exists: `analyze`/`buffers`/`verbose = true` raise `BackendCapabilityError`, and tables are named by
the query's alias (`Tb_1`). The result reports what the plan states; PormG does not guess at a
"missing" index.

## When a query returns the wrong thing

- **No rows where you expected some:** check the case of every field path — lookups are
  case-sensitive, and a mistyped path raises `UnknownFieldError`, but a wrong *value* case simply
  matches nothing (text comparison is case-sensitive on PostgreSQL and SQLite). Use `__@iexact` for
  a whole value, or `__@icontains`/`__@istartswith` for part of one, when case should not matter.
- **`QueryBuildError` naming the fan-out guard (PingoLee/PormG.jl#74):** an aggregate over a to-many join would be
  silently inflated, so PormG refuses it. Aggregate the related table's own column, pass
  `distinct = true`, or use one correlated `Subquery` per relation ([`advanced.md`](advanced.md)).
- **A `GROUP BY` you did not expect:** every non-aggregate column in `values()` is a grouping key.
  Remove a column, or move it into an aggregate.
- **`row.driverid` is an `Int`, or reading it raises `LazyTraversalError`:** a `ForeignKey` on a
  row is only the key, and only when projected. PormG never lazy-loads. Project the related columns
  — `values("driverid__surname")` — then read `row.driverid__surname`.
- **Results differ between PostgreSQL and SQLite:** check the
  [PostgreSQL guide](https://pingolee.github.io/PormG.jl/stable/postgres/) divergence list.

## Connection pool health

```julia
pool_stats("db")
# (pool_size = 5, size = 7, in_use = 7, available = 0, ceiling = 50, waiting = 3)
```

- `in_use` near `ceiling` with `waiting > 0` → the app is saturating the pool. The next symptom is
  a `PoolTimeoutError`. Raise `pool_size`/`pool_timeout` in `connection.yml`, or find the leak.
- `in_use` that never comes down → an un-awaited `FetchTask` ([`async.md`](async.md)), or a manual
  `acquire_connection` with no `release_connection` in a `finally`.
- `pool_stats` of a key whose pool was never built raises (a zeroed snapshot would look healthy).

## `@pormg_debug`

`@pormg_debug` is a **contributor** breakpoint hook scattered through PormG's own source. It
expands to `nothing` and costs an application nothing. Ignore it in app code. Wiring it up is for
debugging PormG itself (see the Contributing page of the PormG docs).
