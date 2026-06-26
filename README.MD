# PormG.jl

**PormG.jl** is a Django-inspired ORM for Julia with async-first execution, designed for use with high-concurrency web frameworks like [Genie.jl](https://genieframework.com/). It provides an expressive query builder, automatic migrations, and cross-database support for PostgreSQL and SQLite.

## 📚 Documentation

Full documentation, tutorials, and API reference:
**[https://pingolee.github.io/PormG.jl/dev/](https://pingolee.github.io/PormG.jl/dev/)**

---

## Installation

```julia
using Pkg
Pkg.add(url="https://github.com/PingoLee/PormG.jl")
```

Once registered in the Julia General Registry:

```julia
using Pkg
Pkg.add("PormG")
```

PormG does **not** pull in a SQL driver automatically — `LibPQ` (PostgreSQL) and `SQLite` are
weak dependencies. Install and load the one your app uses:

```julia
Pkg.add("LibPQ")     # PostgreSQL
Pkg.add("SQLite")    # SQLite
```

A bare `using PormG` loads the ORM but no backend; the first query then raises a clear error
telling you to `using LibPQ` (or `using SQLite`).

---

## Quick Start

### Define models

```julia
# db/models.jl
module models
import PormG.Models

Driver = Models.Model("drivers",
    id          = Models.IDField(),
    forename    = Models.CharField(max_length=50),
    surname     = Models.CharField(max_length=50),
    nationality = Models.CharField(max_length=50),
    dob         = Models.DateField(null=true),
)

Result = Models.Model("results",
    id             = Models.IDField(),
    raceid         = Models.ForeignKeyField(Race, on_delete="CASCADE"),
    driverid       = Models.ForeignKeyField(Driver, on_delete="CASCADE"),
    constructorid  = Models.ForeignKeyField(Constructor, on_delete="CASCADE"),
    positionorder  = Models.IntegerField(),
    points         = Models.FloatField(),
)
end
```

### Load configuration and models

```julia
using PormG, LibPQ, DataFrames          # LibPQ → PostgreSQL; use SQLite for the SQLite backend
using PormG.Functions                   # SQL functions (Count, Sum, Max, …) — namespaced

PormG.Configuration.load("db")          # loads db/settings.yml
PormG.@import_models "db/models.jl" models
import .models as M
```

### Query the database

```julia
# All Brazilian drivers who won a race — INNER JOINs resolved automatically
df = M.Result.objects.filter(
      "driverid__nationality" => "Brazilian",
      "positionorder"         => 1
    ).values(
      "driverid__forename", 
      "driverid__surname",
      "raceid__year",
      "raceid__name"
    ).order_by("-raceid__year") |> DataFrame
```

```julia
# Wins per constructor using aggregation
df = M.Result.objects.filter(
      "positionorder" => 1
    ).values(
      "constructorid__name", "wins" => Count("id")
    ).order_by("-wins") |> DataFrame
```

### Create and update records

```julia
# bulk_insert returns the inserted rows as a DataFrame
df = DataFrame([
    Dict("forename" => "Ayrton", "surname" => "Senna", "nationality" => "Brazilian"),
    Dict("forename" => "Alain",  "surname" => "Prost",  "nationality" => "French"),
])    
result = bulk_insert(M.Driver, df)

# Update in-place
M.Driver.objects.filter("nationality" => "Brazilian").update("nationality" => "Brazil")
```

---

## Key Features

- **Async-first** — non-blocking I/O via `LibPQ.async_execute`; synchronous helpers are thin wrappers
- **Django-style filter syntax** — `__` for joins, `__@gt` / `__@in` / `__@contains` for operators
- **F-expressions** — column arithmetic and field-to-field comparisons: `F("points") > F("grid")`
- **Aggregation & annotation** — `Count`, `Sum`, `Avg`, `Max`, `Min` with `GROUP BY` handled automatically
- **Migrations** — state-based schema reconciliation with `makemigrations` / `migrate`
- **Multi-database** — switch connections at runtime with `.db("tenant_id")`
- **Advisory locks** — distributed coordination via `with_advisory_lock`
- **Transactions** — `run_in_transaction` with savepoint support

---

## Contributing

Contributions are welcome. Please open an issue or pull request on GitHub.
See the [Contributing & Debugging](https://pingolee.github.io/PormG.jl/dev/contributing/) page
for the development workflow, debugging guide, and testing conventions.

---

## License

MIT License
