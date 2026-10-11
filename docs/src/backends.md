# Backend Capabilities

PormG runs on PostgreSQL and SQLite. Most of what it does means the same on both. Some features exist on one backend only, and PormG does not emulate a feature a backend lacks. It raises `BackendCapabilityError` instead, and the message names the feature, the backend you are on, and the backends that support it:

```text
The @jcontains lookup (JSONB @>) needs JSONB containment and key operators (`@>`, `?`, `?|`, `?&`),
which SQLite does not support (supported on PostgreSQL).
```

The table below is the list PormG checks. A unit test fails when this page and the code disagree.

| Feature | Used by | PostgreSQL | SQLite |
|---|---|---|---|
| `jsonb_operators` | `@jcontains`, `@has_key`, `@has_any_keys`, `@has_keys` | yes | no |
| `arrays` | `ArrayField`, its lookups (`@acontains`, `@contained_by`, `@overlap`), `@len`, an index or slice, a cast to an array type | yes | no |
| `network_types` | `GenericIPAddressField`, `CIDRField`, the `@net_*`, `@family` and `@prefixlen` lookups | yes | no |
| `full_text_search` | `SearchVectorField`, the `@search` lookup, `SearchVector`, `SearchQuery`, `SearchRank`, `SearchHeadline` | yes | no |
| `regex` | `@regex`, `@iregex` and their negations | yes | no |
| `unaccent` | `@iunaccent_contains`, `@iunaccent_exact` and their negations | yes | no |
| `index_methods` | an `Index` with `method` other than `"btree"`, `opclasses`, or `include` | yes | no |
| `explain_options` | `explain(analyze = true)`, `buffers`, `verbose` | yes | no |
| `copy` | `bulk_copy` | yes | no |
| `advisory_locks` | `with_advisory_lock(…; on_missing_lock = :error)` | yes | no |

`with_advisory_lock` on SQLite without `on_missing_lock = :error` runs the body with no lock, and warns unless you pass `on_missing_lock = :ignore` ([Advisory Locks](advisory_lock.md)).

## What is not in this table

- **A version.** Window functions need an SQLite library of 3.25 or later, checked against the one PormG loads ([Window Functions](read/window_functions.md)). PormG's schema management needs a PostgreSQL server of 13 or later, checked against the server you connect to ([PostgreSQL Guide](postgres.md)).
- **A feature one backend supports only in part.** For example, `ToChar` formats or `Extract` parts that SQLite cannot spell, or a cast to a time type. Each raises `BackendCapabilityError` where it is used, and its page says which forms work.
- **A gap in PormG, not in an engine.** SQLite has explicit window frames, but PormG does not render `WindowOver(frame = …)` there yet, and raises `BackendCapabilityError` saying so ([Window Functions](read/window_functions.md)).
- **A difference in what a query returns.** When two backends would compute different values or rows for the same query, PormG refuses it on the backend that departs, or documents the difference. That is not a missing feature ([Functions and Dates](read/functions_and_dates.md)).
