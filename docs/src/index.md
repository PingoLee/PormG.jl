# PormG.jl Documentation

**PormG.jl** is a Django-inspired ORM for Julia, built with an async-first architecture for high-concurrency web frameworks. It brings the expressive power of Django's query builder to Julia while leveraging Julia's performance and type system.

---

## Why PormG?

| Feature | Description |
| :--- | :--- |
| **Django-Style Query Builder** | Familiar syntax using `filter`, `values`, `order_by`, and chainable methods. Join traversal with `__` notation. |
| **Async-First Execution** | Non-blocking I/O via `LibPQ.async_execute`. Synchronous helpers are thin wrappers — the event loop is never blocked. |
| **Cross-Database Support** | PostgreSQL (LibPQ.jl) and SQLite (SQLite.jl) with automatic connection pooling and dialect adaptation. |
| **Multi-Database & Multi-Tenancy** | Switch databases at runtime with `.db("tenant_id")`. Lazy connection resolution via resolver functions. |
| **F-Expressions & Aggregations** | Column arithmetic, field-to-field comparisons, `Count`, `Sum`, `Avg`, `Max`, `Min` with automatic `GROUP BY` / `HAVING`. |
| **Migrations** | State-based schema reconciliation with `makemigrations` / `migrate`, destructive-operation guards, and a history table. |
| **Transactions** | `run_in_transaction` with async context propagation, savepoint support, and automatic rollback on error. |
| **Advisory Locks** | Distributed coordination via `with_advisory_lock` for safe concurrent processes. |

---

## Installation

PormG is currently in early development and is not yet registered in the Julia General Registry. Install the development version using the Julia package manager:

```julia
using Pkg
Pkg.add(url="https://github.com/PingoLee/PormG.jl")
```

Or develop locally:

```julia
using Pkg
Pkg.develop(url="https://github.com/PingoLee/PormG.jl")
```

!!! note
    Since this is a development package, features may change and stability is not guaranteed. Please report any issues on the [GitHub repository](https://github.com/PingoLee/PormG.jl).

### Install a database driver

PormG does **not** pull in a SQL driver automatically — `LibPQ` (PostgreSQL) and `SQLite` are
weak dependencies, so each app installs and loads the one it uses as a direct dependency:

```julia
using Pkg
Pkg.add("LibPQ")     # PostgreSQL backend
Pkg.add("SQLite")    # SQLite backend
```

Load the driver alongside PormG (`using PormG, LibPQ` or `using PormG, SQLite`). A bare
`using PormG` loads the ORM but no backend, so the first query raises a clear error telling you
which driver to load:

```text
PormG: the PostgreSQL backend requires LibPQ. Run `using LibPQ` (or `using PormG, LibPQ`) so the PostgreSQL extension loads.
```

---

## Quick Start

### 1. Initialize Your Project

```julia
using PormG
PormG.setup() # Interactive setup for database and models
```

This creates a `db/` folder with a `connection.yml` template and a `models.jl` skeleton.

### 2. Configure the Database Connection

Open `db/connection.yml` and configure your database:

```yaml
env: dev

dev:
  adapter: PostgreSQL
  database: your_database_name
  host: 'localhost'
  username: your_username
  password: your_password
  port: 5432
  config:
    change_db: true      # create the database if it doesn't exist
    change_data: true    # allow data modifications
    time_zone: 'America/Sao_Paulo'
```

For SQLite, use:

```yaml
env: dev

dev:
  adapter: SQLite
  database: 'my_app.db'
  config:
    change_db: true      # allow schema migrations
    change_data: true    # allow data mutations
```

!!! warning
    **Implicit Defaults & The Omitted `config:` Gotcha:**
    If the `config:` block is omitted or left empty under an environment, PormG applies strict safety-first defaults:
    * **`change_db` defaults to `false`**: Database migrations and schema modifications (`makemigrations` / `migrate`) are disabled.
    * **`change_data` defaults to `false`**: All data modifications (creates, updates, deletes) are disabled at the query layer.
    * **`time_zone` defaults to `"UTC"`**: Default database timezone.

    To perform migrations or modify data, you **must** explicitly define `config:` and set these settings to `true` in your active environment.

### 3. Define Your Models

Create `db/models.jl` with your model definitions. 

!!! note
    PormG **preserves the case** you declare field names with: `driverid` stays `driverid` (column `"driverid"`), and field lookups are **case-sensitive** — query a field by the exact case you declared it. The recommended house style is **lowercase snake_case** (PormG's own models use it), so define new fields that way; reserve mixed-case declarations for faithfully mapping existing mixed-case/uppercase columns you don't control.

```julia
module models
import PormG.Models

Driver = Models.Model("drivers",
    driverid    = Models.IDField(),
    forename    = Models.CharField(max_length=50),
    surname     = Models.CharField(max_length=50),
    nationality = Models.CharField(max_length=50),
    dob         = Models.DateField(null=true),
)

Circuit = Models.Model("circuits",
    circuitid   = Models.IDField(),
    name        = Models.CharField(max_length=100),
    location    = Models.CharField(max_length=100),
    country     = Models.CharField(max_length=100),
)

Race = Models.Model("races",
    raceid      = Models.IDField(),
    name        = Models.CharField(max_length=255),
    year        = Models.IntegerField(),
    date        = Models.DateField(),
    circuitid   = Models.ForeignKey(Circuit, pk_field="circuitid", on_delete="CASCADE"),
)

Constructor = Models.Model("constructors",
    constructorid = Models.IDField(),
    name          = Models.CharField(max_length=50),
    nationality   = Models.CharField(max_length=50),
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

### 4. Load Configuration and Import Models

```julia
using PormG, LibPQ, DataFrames   # LibPQ → PostgreSQL; use SQLite instead if your adapter is SQLite

# Load configuration — must happen BEFORE importing models
PormG.Configuration.load("db")

# Import models with hot-reload support (Revise.jl)
PormG.@import_models "db/models.jl" models
import .models as M
```

### 5. Create and Apply Migrations

```julia
PormG.Migrations.makemigrations("db")   # Analyze models and generate migration
PormG.Migrations.migrate("db")          # Apply migration to database
```

### 6. Create Records

```julia
# Single record creation
M.Driver.objects.create(
    "forename" => "Ayrton",
    "surname"  => "Senna",
    "nationality" => "Brazilian"
)

# Bulk insert for multiple records
bulk_data = DataFrame([
    Dict("forename" => "Alain",  "surname" => "Prost",    "nationality" => "French"),
    Dict("forename" => "Nelson", "surname" => "Piquet",   "nationality" => "Brazilian"),
])
# We call bulk_insert on the .objects handler to respect the ORM boundary
bulk_insert(M.Driver.objects, bulk_data)
```

### 7. Query Your Data

```julia
using PormG: F
using PormG.Functions: Count

# Simple filter and list
drivers = M.Driver.objects.filter("nationality" => "Brazilian").order_by("surname").list()

# Chainable methods with DataFrame output (query fields in the case they were declared;
# the F1 models use lowercase, so the paths below are lowercase)
df = M.Result.objects.filter(
        "driverid__nationality" => "Brazilian",
        "positionorder"         => 1
    ).values(
        "driverid__forename",
        "driverid__surname",
        "raceid__year",
    ).order_by("-raceid__year") |> DataFrame

# Aggregations
df = M.Result.objects.filter(
        "positionorder" => 1
    ).values(
        "constructorid__name",
        "wins" => Count("resultid")
    ).order_by("-wins") |> DataFrame
```

!!! info "Important"
    **Julia Method Chain Syntax Gotcha:** Multi-line method chains must use **trailing-dot** syntax (the `.` must be at the end of the line) or stay completely inline. Placing the dot at the start of the next line (leading-dot syntax) will cause a Julia `ParseError`.

    ```julia
    # ✓ CORRECT: Trailing dot or inline
    df = M.Driver.objects.
        filter("nationality" => "Brazilian").
        list()

    # ✗ INCORRECT (ParseError): Leading dot
    df = M.Driver.objects
        .filter("nationality" => "Brazilian")
        .list()
    ```

### 8. Update and Delete

```julia
# Update matching records
M.Driver.objects.filter("nationality" => "Brazilian").update("nationality" => "Brazil")

# Atomic update with F-expression (no read-modify-write race)
M.Result.objects.filter("resultid" => 1).update("points" => F("points") + 10)

# Delete matching records
M.Driver.objects.filter("surname" => "TestDriver").delete()
```

---

## Django Data-Type & Compatibility Contract

PormG is designed to be fully wire-format compatible with tables managed by Django. It guarantees identical column serialization and mutation semantics across both **PostgreSQL** and **SQLite** backends:

*   **TIMESTAMPTZ Contract**: Naive `DateTime` values are treated as UTC, while timezone-aware `ZonedDateTime` values preserve the exact UTC instant across backends. (SQLite stores ISO 8601 strings and normalizes on read).
*   **DateField Truncation**: Temporal inputs like `DateTime` or `ZonedDateTime` are automatically truncated to their calendar date portion when saved into a `DateField`, matching Django's silent truncation behavior instead of throwing errors.
*   **DecimalField Precision**: Underpinned by `NUMERIC` types, `DecimalField(max_digits, decimal_places)` prevents float drift in round-trips (e.g. `99.99` is retrieved precisely as `99.99` in `Decimals.Decimal` format).
*   **Auto Temporal Fields**: 
    *   `auto_now_add=true`: Automatically populated with the transaction's timezone-aware timestamp upon `INSERT`, then frozen during subsequent updates.
    *   `auto_now=true`: Automatically populated upon `INSERT` and refreshed with the system timestamp on every `UPDATE`.

---

## Architecture Overview

PormG is structured into five distinct, decoupled layers, ensuring a clean separation of concerns, high-performance execution, and cross-database dialect compatibility:

| Layer | Responsibility | Key Components & Files |
| :--- | :--- | :--- |
| **1. Application** | High-level user interface. Developers define models and write fluent queries. | `M.Driver.objects.filter(...)`<br>• [Models.jl](https://github.com/PingoLee/PormG.jl/blob/main/src/Models.jl) |
| **2. Query Builder** | Fluent chaining API. Resolves chaining, table joins (`__` notation), and subqueries into an abstract AST. | `filter`, `values`, `order_by`, `cjoin`<br>• [QueryBuilder.jl](https://github.com/PingoLee/PormG.jl/blob/main/src/QueryBuilder.jl) |
| **3. Dialect Adapter** | Compiles the abstract query builder AST into vendor-specific, parameterized SQL strings. | PostgreSQL vs. SQLite translation<br>• [Dialect.jl](https://github.com/PingoLee/PormG.jl/blob/main/src/Dialect.jl) |
| **4. Connection Pool** | Async-first execution layer. Manages active connections and non-blocking I/O without blocking the Julia event loop. | `LibPQ.async_execute`, `SQLite.execute`<br>• [ConnectionPool.jl](https://github.com/PingoLee/PormG.jl/blob/main/src/ConnectionPool.jl) |
| **5. Config & Tenants** | Multi-database and multi-tenancy registry. Loads configurations and maps active tenant resolvers. | `load`, `load_many`, `resolver`<br>• [Configuration.jl](https://github.com/PingoLee/PormG.jl/blob/main/src/Configuration.jl) |

---

## Documentation Guide

This documentation is organized into the following sections:

| Section | Description |
| :--- | :--- |
| [Configuration](configuration/index.md) | Database connections, environments, multi-tenancy, and health checks. |
| [Models](models.md) | Defining models, `@import_models`, hot-reloading, and naming conventions. |
| [Fields](fields.md) | Comprehensive field type reference: text, numeric, date, boolean, relationships. |
| [Migrations](migrations/index.md) | `makemigrations`, `migrate`, `dry_run`, history table, destructive guards. |
| **Writing** | |
|  [Overview](write/index.md) | Async-first write philosophy and performance comparison. |
|  [Creating Records](write/create.md) | Single-record `create()` patterns. |
|  [Updating Records](write/update.md) | `update()` with filters and F-expressions. |
|  [Deleting Records](write/delete.md) | Safe record deletion with cascading. |
|  [Bulk Operations](write/bulk.md) | `bulk_insert`, `bulk_copy`, and `bulk_update`. |
|  [Transactions](write/transaction.md) | `run_in_transaction`, async context propagation, savepoints. |
| **Reading** | |
|  [Overview](read/index.md) | Query execution, output formats, and query styles. |
|  [Values and Joins](read/values_and_joins.md) | Column selection, `__` join traversal, aliases. |
|  [Custom Joins](read/custom_joins.md) | `cjoin()` for runtime join conditions and `on()` for ON-clause predicates. |
|  [Filters and Aggregates](read/filters_and_aggregates.md) | Lookup operators, grouping, and `HAVING`. |
|  [Functions and Dates](read/functions_and_dates.md) | SQL functions and date-oriented querying. |
|  [Subqueries and CTEs](read/subqueries_and_ctes.md) | `IN` subqueries and `With(...)` CTEs. |
|  [Field Expressions](read/field_expressions.md) | `F()` expressions, column arithmetic, aggregate ratios. |
|  [Q Objects](read/q_objects.md) | Complex boolean logic with `Q`, `Qor`, and `NOT`. |
| [Import from Django](import_django.md) | Migrating models and data from Django projects. |
| [Async & Concurrency](async.md) | Task-based concurrent queries, fan-out patterns, `fetch_async`, pool interplay. |
| [Advisory Locks](advisory_lock.md) | Distributed locking with `with_advisory_lock`. |
| [Contributing](contributing.md) | Development workflow, `@pormg_debug` breakpoints, and testing conventions. |
| [API Reference](api.md) | Full auto-generated API reference and exported function catalog. |

---

## Database Example: Formula 1

The examples throughout this documentation use the **Formula 1 World Championship** dataset ([Kaggle](https://www.kaggle.com/datasets/rohanrao/formula-1-world-championship-1950-2020)). This provides a real-world schema with multiple related tables (`Driver`, `Race`, `Circuit`, `Constructor`, `Result`, `Status`), making it ideal for demonstrating joins, aggregations, and complex queries.

```julia
# Example: Find all Brazilian race winners with circuit information
df = M.Result.objects.filter(
        "driverid__nationality" => "Brazilian",
        "positionorder"         => 1,
    ).values(
        "driverid__forename",
        "driverid__surname",
        "raceid__name",
        "raceid__circuitid__name",
        "raceid__year",
    ).order_by("-raceid__year") |> DataFrame
```

---

## Contributing

Contributions to PormG are welcome! Please see the [Contributing & Debugging](contributing.md) page for the development workflow, testing conventions, and how to use `@pormg_debug` breakpoints.

## License

PormG is licensed under the MIT License. See the [LICENSE](https://github.com/PingoLee/PormG.jl/blob/main/LICENSE) file for details.