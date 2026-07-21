# PormG.jl

[![Docs (dev)](https://img.shields.io/badge/docs-dev-blue.svg)](https://pingolee.github.io/PormG.jl/dev/)
[![CI](https://github.com/PingoLee/PormG.jl/actions/workflows/CI.yml/badge.svg)](https://github.com/PingoLee/PormG.jl/actions/workflows/CI.yml)
[![Julia](https://img.shields.io/badge/julia-%E2%89%A5%201.12-9558B2.svg)](https://julialang.org)
[![License: MIT](https://img.shields.io/badge/license-MIT-green.svg)](LICENSE)

**PormG.jl** is a Django-inspired ORM for Julia with async-first execution, designed for
high-concurrency web frameworks like [Genie.jl](https://genieframework.com/). It provides an
expressive query builder, automatic migrations, and cross-database support for PostgreSQL and
SQLite.

## 📚 Documentation

Full documentation, tutorials, and API reference:
**[https://pingolee.github.io/PormG.jl/dev/](https://pingolee.github.io/PormG.jl/dev/)**

## Key Features

- **Async-first** — non-blocking I/O via `LibPQ.async_execute`; synchronous helpers are thin wrappers that never block the event loop
- **Django-style filter syntax** — `__` for join traversal, `__@gt` / `__@in` / `__@contains` for operators
- **F-expressions** — column arithmetic and field-to-field comparisons: `F("points") > F("grid")`
- **Aggregation & annotation** — `Count`, `Sum`, `Avg`, `Max`, `Min` with `GROUP BY` / `HAVING` handled automatically
- **Migrations** — state-based schema reconciliation with `makemigrations` / `migrate`, destructive-operation guards, and a history table
- **Multi-database & multi-tenancy** — switch connections at runtime with `.db("tenant_id")`
- **Advisory locks** — distributed coordination via `with_advisory_lock`
- **Transactions** — `run_in_transaction` with savepoint support and async context propagation

---

## Requirements

- Julia **1.12** or newer
- A SQL driver for your backend — [`LibPQ`](https://github.com/iuliancioarca/LibPQ.jl) (PostgreSQL) or [`SQLite`](https://github.com/JuliaDatabases/SQLite.jl)

## Installation

PormG is not yet registered in the Julia General Registry. Install the development version:

```julia
using Pkg
Pkg.add(url="https://github.com/PingoLee/PormG.jl")
```

Once registered, this becomes:

```julia
using Pkg
Pkg.add("PormG")
```

PormG does **not** pull in a SQL driver automatically — `LibPQ` (PostgreSQL) and `SQLite` are
weak dependencies. Install and load the one your app uses as a direct dependency:

```julia
Pkg.add("LibPQ")     # PostgreSQL
Pkg.add("SQLite")    # SQLite
```

A bare `using PormG` loads the ORM but no backend; the first query then raises a clear error
telling you to `using LibPQ` (or `using SQLite`).

---

## Quick Start

### 1. Scaffold a project (optional)

```julia
using PormG
PormG.setup()   # interactive: writes db/connection.yml and a db/models.jl skeleton
```

Prefer to wire it up by hand? The next steps show the files `setup()` would create.

### 2. Configure the connection

`db/connection.yml`:

```yaml
env: dev

dev:
  adapter: PostgreSQL       # or SQLite
  database: your_database
  host: 'localhost'
  username: your_username
  password: your_password
  port: 5432
  config:
    change_db: true         # allow schema migrations
    change_data: true       # allow data mutations
    time_zone: 'America/Sao_Paulo'
```

> **Note:** If `config:` is omitted, PormG applies safety-first defaults — `change_db` and
> `change_data` are `false` (migrations and writes disabled). Set them to `true` explicitly to
> enable schema changes and data mutations.

### 3. Define models

```julia
# db/models.jl
module models
import PormG.Models

Driver = Models.Model("drivers",
    driverid    = Models.IDField(),
    forename    = Models.CharField(max_length=50),
    surname     = Models.CharField(max_length=50),
    nationality = Models.CharField(max_length=50),
    dob         = Models.DateField(null=true),
)

Constructor = Models.Model("constructors",
    constructorid = Models.IDField(),
    name          = Models.CharField(max_length=50),
    nationality   = Models.CharField(max_length=50),
)

Race = Models.Model("races",
    raceid = Models.IDField(),
    name   = Models.CharField(max_length=255),
    year   = Models.IntegerField(),
    date   = Models.DateField(),
)

Result = Models.Model("results",
    resultid      = Models.IDField(),
    raceid        = Models.ForeignKey(Race, pk_field="raceid", on_delete="CASCADE"),
    driverid      = Models.ForeignKey(Driver, pk_field="driverid", on_delete="RESTRICT"),
    constructorid = Models.ForeignKey(Constructor, pk_field="constructorid", on_delete="RESTRICT"),
    positionorder = Models.IntegerField(),
    points        = Models.FloatField(),
)
end
```

> **Note:** PormG preserves the case you declare field names with, and field lookups are
> case-sensitive. The recommended house style is lowercase `snake_case`; reserve mixed-case
> declarations for mapping existing columns you don't control.

### 4. Load configuration and models

```julia
using PormG, LibPQ, DataFrames          # LibPQ → PostgreSQL; swap in SQLite for the SQLite backend
using PormG.Functions: Count            # SQL functions (Count, Sum, Max, …) — namespaced

PormG.Configuration.load("db")          # loads db/connection.yml (must precede @import_models)
PormG.@import_models "db/models.jl" models
import .models as M
```

### 5. Run migrations

```julia
PormG.Migrations.makemigrations("db")   # analyze models, generate a migration
PormG.Migrations.migrate("db")          # apply it to the database
```

### 6. Query the database

```julia
# All Brazilian race winners — INNER JOINs resolved automatically from the __ paths
df = M.Result.objects.filter(
        "driverid__nationality" => "Brazilian",
        "positionorder"         => 1,
    ).values(
        "driverid__forename",
        "driverid__surname",
        "raceid__year",
        "raceid__name",
    ).order_by("-raceid__year") |> DataFrame
```

```julia
# Wins per constructor, using aggregation (GROUP BY handled automatically)
df = M.Result.objects.filter(
        "positionorder" => 1
    ).values(
        "constructorid__name",
        "wins" => Count("resultid"),
    ).order_by("-wins") |> DataFrame
```

> **Julia method-chain gotcha:** multi-line chains must use **trailing-dot** syntax (the `.` at
> the *end* of the line) or stay inline. A leading dot on the next line is a Julia `ParseError`.
>
> ```julia
> # ✓ trailing dot
> df = M.Driver.objects.
>     filter("nationality" => "Brazilian").
>     list()
>
> # ✗ leading dot → ParseError
> df = M.Driver.objects
>     .filter("nationality" => "Brazilian")
>     .list()
> ```

### 7. Create and update records

```julia
# Single insert
M.Driver.objects.create(
    "forename"    => "Ayrton",
    "surname"     => "Senna",
    "nationality" => "Brazilian",
)

# Bulk insert from a DataFrame — call on the .objects handler to respect the ORM boundary
df = DataFrame([
    Dict("forename" => "Alain",  "surname" => "Prost",  "nationality" => "French"),
    Dict("forename" => "Nelson", "surname" => "Piquet", "nationality" => "Brazilian"),
])
bulk_insert(M.Driver.objects, df)

# Update matching rows in place
M.Driver.objects.filter("nationality" => "Brazilian").update("nationality" => "Brazil")

# Atomic F-expression update (no read-modify-write race)
M.Result.objects.filter("resultid" => 1).update("points" => F("points") + 10)
```

---

## Django Compatibility

PormG is wire-format compatible with tables managed by Django, with identical column
serialization and mutation semantics across PostgreSQL and SQLite — `TIMESTAMPTZ` handling,
`DateField` truncation, `DecimalField` precision (`NUMERIC`-backed), and `auto_now` /
`auto_now_add` temporal fields. See
[Import from Django](https://pingolee.github.io/PormG.jl/dev/import_django/) for details.

---

## Contributing

Contributions are welcome — please open an issue or pull request on GitHub. See the
[Contributing & Debugging](https://pingolee.github.io/PormG.jl/dev/contributing/) page for the
development workflow, debugging guide, and testing conventions.

## License

MIT License — see [LICENSE](LICENSE).
