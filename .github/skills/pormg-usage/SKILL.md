---
name: pormg-usage
description: Answer PormG usage questions and write consumer-style code — model definitions, @import_models, migrations, fluent queries, joins, F/Q/Qor, aggregations, SQL functions, subqueries/CTEs, window functions, writes and bulk operations, transactions, async, and PormGError handling.
---

# PormG.jl — AI Usage Guide

**Audience: you are a PormG consumer** — writing application code in a project that *depends on*
PormG.jl, a Django-inspired, async-first ORM for Julia. (Changing PormG's own `src/`, `docs/` or
tests is a different job, with its own rules in the PormG repository.)

This file is the **router**. It holds the rules that apply to every task, one end-to-end example,
and a table saying which sibling file to read for the task in front of you. Read only the files the
task needs.

## Rules that always apply

1. **Go through the ORM surface.** Query with `M.Model.objects` and its chainable methods — never
   raw SQL. Values are always bound as parameters; never interpolate user input into a string.
2. **Multi-line chains use a trailing dot.** A dot at the *start* of a line is a Julia `ParseError`:
   ```julia
   rows = M.Result.objects.
       filter("driverid__surname" => "Senna").
       values("raceid__year", "points").
       list()
   ```
   A handler is mutable, so the statement form is equivalent and common in the docs:
   `q = M.Result.objects; q.filter(...); q.values(...)`.
3. **Load the configuration before importing models.** `PormG.Configuration.load("db")` first,
   then `PormG.@import_models "db/models.jl" models`.
4. **Load a driver package.** `LibPQ` (PostgreSQL) and `SQLite` are weak dependencies:
   `using PormG, LibPQ`. Without one the first query raises *"the PostgreSQL backend requires
   LibPQ"*.
5. **Field lookups are case-sensitive.** Query a field in the case it was declared
   (`"constructorid__name"`, not `"constructorId__name"`).
6. **Traverse relations with `__`, filter with `__@op`.** `"driverid__nationality" => "British"`,
   `"points__@gte" => 10`. Never use `__` inside a field or table name.
7. **Catch `PormGError`, never `ArgumentError`.** Every failure PormG raises about your query, data,
   models, configuration or database is a `PormGError` subtype, and none of them is
   `<: ArgumentError`, so `catch ArgumentError` silently stops matching. Read the message with
   `error_message(e)`, not `e.msg`. See [`errors.md`](errors.md).
8. **SQL functions live in `PormG.Functions`.** `using PormG.Functions: Count, Sum, Rank, …`.
   `Q`, `Qor`, `F`, `Subquery`, `OuterRef`, `Exists`, `CTE`, `Joined`, `Interval` and the bulk
   writers are top-level.
9. **PostgreSQL and SQLite behave the same, except where a feature is PostgreSQL-only** — that
   raises `BackendCapabilityError` on SQLite instead of degrading silently. The list is in the
   [PostgreSQL guide](https://pingolee.github.io/PormG.jl/stable/postgres/).

## One end-to-end example

```julia
using PormG, LibPQ, DataFrames
using PormG.Functions: Count, Sum

PormG.Configuration.load("db")                  # 1. configuration first
PormG.@import_models "db/models.jl" models      # 2. then the models
import .models as M

# Points and wins per constructor in the 1991 season, best first
df = M.Result.objects.
    filter("raceid__year" => 1991).
    values("constructorid__name",
           "points" => Sum("points"),
           "wins"   => Count("resultid")).
    order_by("-points") |> DataFrame

# A write, with the error handled by type
try
    M.Result.objects.filter("raceid" => 1).update("points" => F("points") + 1)
catch e
    e isa PormGError || rethrow()
    @error "PormG rejected the update" msg=error_message(e) type=typeof(e)
end
```

`values(...)` with a mix of plain columns and aggregates emits the `GROUP BY` for you, from the
non-aggregate columns. Never write it yourself.

## Which file to read

| Task | Read |
|---|---|
| Set up a project, define or change models, pick a field type, run migrations | [`models.md`](models.md) |
| Query: filters, lookups, joins, `Q`/`F`, aggregates, SQL functions, dates | [`reading.md`](reading.md) |
| Create, update, delete, bulk load, many-to-many, transactions, primary-key allocation | [`writing.md`](writing.md) |
| Correlated subqueries, CTEs, custom joins, window functions, multiple databases, advisory locks | [`advanced.md`](advanced.md) |
| Concurrency, `fetch_async`, what spawned tasks see inside a transaction | [`async.md`](async.md) |
| Catching and reporting errors, which call raises what | [`errors.md`](errors.md) |
| Inspecting generated SQL, pool health, a query that returns the wrong thing | [`debugging.md`](debugging.md) |

The exhaustive reference is the PormG documentation, <https://pingolee.github.io/PormG.jl/stable/>.
These files are the working patterns and the gotchas. Each links to the page with the full detail.

## Upgrading PormG in this project

Your project's PormG version pin is its upgrade state. Before bumping it, list what changed since
the pinned version and apply each entry:

```julia
PormG.upgrade_guide(from = v"0.5")   # the version this project is pinned to today
```

Each entry carries a grep for the old call pattern and a concrete `before → after`. After bumping,
refresh this bundle so it matches the new version:

```julia
PormG.install_ai_skills()   # overwrites .github/skills/pormg-usage/, reports stale files
```

## Anti-patterns

| Anti-pattern | Instead |
| :--- | :--- |
| Raw SQL strings | `filter()`, `values()`, `update()` on `M.Model.objects` |
| A leading `.` on a continuation line | A trailing `.` on the previous line |
| `catch e; e isa ArgumentError` around a PormG call | `e isa PormGError` (or a specific subtype) |
| `e.msg` on a caught PormG error | `error_message(e)` |
| `query \|> list`, `delete(query)` (free functions) | `query.list()`, `query.delete()` |
| Loops of `create()` for a batch | `bulk_insert()` (or `bulk_copy()` on PostgreSQL) — see [`writing.md`](writing.md) |
| Django `annotate(Count(...))` across two relations | One correlated `Subquery` per relation — see [`advanced.md`](advanced.md) |
| `F("points") > 20` in a filter | `"points__@gt" => 20` |
| `Max(F("points")) - 5` | `Max("points") - 5` |
| Writing a `GROUP BY` | Mix plain and aggregate columns in `values()`; PormG groups |
| Expecting `row.driverid` to be the related driver (`row.driverid.surname`) | Project it: `values("driverid__surname")`, read `row.driverid__surname` — PormG never lazy-loads |
| Skipping `dry_run()` before `migrate()` | Always review the plan first — see [`models.md`](models.md) |
