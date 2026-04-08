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
| **Terminal Dashboard** | Optional Tachikoma-based TUI for reviewing migrations and inspecting queries. |

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

> **Note:** Since this is a development package, features may change and stability is not guaranteed. Please report any issues on the [GitHub repository](https://github.com/PingoLee/PormG.jl).

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
```

### 3. Define Your Models

Create `db/models.jl` with your model definitions:

```julia
module models
import PormG.Models

Driver = Models.Model("drivers",
    driverId    = Models.IDField(),
    forename    = Models.CharField(max_length=50),
    surname     = Models.CharField(max_length=50),
    nationality = Models.CharField(max_length=50),
    dob         = Models.DateField(null=true),
)

Result = Models.Model("results",
    resultId       = Models.IDField(),
    raceId         = Models.ForeignKey(Race, pk_field="raceId", on_delete="CASCADE"),
    driverId       = Models.ForeignKey(Driver, pk_field="driverId", on_delete="RESTRICT"),
    positionOrder  = Models.IntegerField(),
    points         = Models.FloatField(),
)

Models.set_models(@__MODULE__, @__DIR__)  # Required at end of file
end
```

### 4. Load Configuration and Import Models

```julia
using PormG, DataFrames

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
bulk_insert(M.Driver, bulk_data)
```

### 7. Query Your Data

```julia
# Simple filter and list
drivers = M.Driver.objects.filter("nationality" => "Brazilian").order_by("surname").list()

# Chainable methods with DataFrame output
df = M.Result.objects.filter(
        "driverId__nationality" => "Brazilian",
        "positionOrder"         => 1
    ).values(
        "driverId__forename",
        "driverId__surname",
        "raceId__year",
    ).order_by("-raceId__year") |> DataFrame

# Aggregations
df = M.Result.objects.filter(
        "positionOrder" => 1
    ).values(
        "constructorId__name",
        "wins" => Count("resultId")
    ).order_by("-wins") |> DataFrame
```

### 8. Update and Delete

```julia
# Update matching records
M.Driver.objects.filter("nationality" => "Brazilian").update("nationality" => "Brazil")

# Atomic update with F-expression (no read-modify-write race)
M.Result.objects.filter("resultId" => 1).update("points" => F("points") + 10)

# Delete matching records
M.Driver.objects.filter("surname" => "TestDriver").delete()
```

---

## Architecture Overview

```
┌─────────────────────────────────────────────────────┐
│                    Your Application                  │
│  M.Driver.objects.filter(...).values(...).list()     │
├─────────────────────────────────────────────────────┤
│                  Query Builder (Functor API)         │
│  filter · values · order_by · limit · cjoin · on    │
├─────────────────────────────────────────────────────┤
│                 Dialect Layer                         │
│          PostgreSQL ←→ SQL Generation ←→ SQLite      │
├─────────────────────────────────────────────────────┤
│              Connection Pool (Async-First)            │
│    LibPQ.async_execute  ·  SQLite.execute            │
├─────────────────────────────────────────────────────┤
│               Configuration & Multi-Tenancy          │
│  load · load_many · register_connection · resolver   │
└─────────────────────────────────────────────────────┘
```

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
| &nbsp;&nbsp;[Overview](write/index.md) | Async-first write philosophy and performance comparison. |
| &nbsp;&nbsp;[Creating Records](write/create.md) | Single-record `create()` patterns. |
| &nbsp;&nbsp;[Updating Records](write/update.md) | `update()` with filters and F-expressions. |
| &nbsp;&nbsp;[Deleting Records](write/delete.md) | Safe record deletion with cascading. |
| &nbsp;&nbsp;[Bulk Operations](write/bulk.md) | `bulk_insert`, `bulk_copy`, and `bulk_update`. |
| &nbsp;&nbsp;[Transactions](write/transaction.md) | `run_in_transaction`, async context propagation, savepoints. |
| **Reading** | |
| &nbsp;&nbsp;[Overview](read/index.md) | Query execution, output formats, and query styles. |
| &nbsp;&nbsp;[Values and Joins](read/values_and_joins.md) | Column selection, `__` join traversal, aliases. |
| &nbsp;&nbsp;[Filters and Aggregates](read/filters_and_aggregates.md) | Lookup operators, grouping, and `HAVING`. |
| &nbsp;&nbsp;[Functions and Dates](read/functions_and_dates.md) | SQL functions and date-oriented querying. |
| &nbsp;&nbsp;[Subqueries and CTEs](read/subqueries_and_ctes.md) | `IN` subqueries and `With(...)` CTEs. |
| &nbsp;&nbsp;[Field Expressions](read/field_expressions.md) | `F()` expressions, column arithmetic, aggregate ratios. |
| &nbsp;&nbsp;[Q Objects](read/q_objects.md) | Complex boolean logic with `Q`, `Qor`, and `NOT`. |
| [Import from Django](import_django.md) | Migrating models and data from Django projects. |
| [Custom Joins](custom_joins.md) | `cjoin()` for runtime join conditions and `on()` for ON-clause predicates. |
| [Advisory Locks](advisory_lock.md) | Distributed locking with `with_advisory_lock`. |
| [Contributing](contributing.md) | Development workflow, `@pormg_debug` breakpoints, and testing conventions. |
| [API Reference](api.md) | Full auto-generated API reference and exported function catalog. |

---

## Database Example: Formula 1

The examples throughout this documentation use the **Formula 1 World Championship** dataset ([Kaggle](https://www.kaggle.com/datasets/rohanrao/formula-1-world-championship-1950-2020)). This provides a real-world schema with multiple related tables (`Driver`, `Race`, `Circuit`, `Constructor`, `Result`, `Status`), making it ideal for demonstrating joins, aggregations, and complex queries.

```julia
# Example: Find all Brazilian race winners with circuit information
df = M.Result.objects.filter(
        "driverId__nationality" => "Brazilian",
        "positionOrder"         => 1,
    ).values(
        "driverId__forename",
        "driverId__surname",
        "raceId__name",
        "raceId__circuitId__name",
        "raceId__year",
    ).order_by("-raceId__year") |> DataFrame
```

---

## Contributing

Contributions to PormG are welcome! Please see the [Contributing & Debugging](contributing.md) page for the development workflow, testing conventions, and how to use `@pormg_debug` breakpoints.

## License

PormG is licensed under the MIT License. See the [LICENSE](https://github.com/PingoLee/PormG.jl/blob/main/LICENSE) file for details.