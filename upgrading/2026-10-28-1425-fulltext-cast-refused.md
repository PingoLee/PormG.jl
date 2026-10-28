## A cast to `tsvector` or `tsquery` is refused on SQLite (#1425)

- **Version**: Unreleased
- **PormG ref**: #1425 ; `src/Dialect.jl` (`_check_fts_cast`, called by `cast_type_sql` on SQLite and MySQL)
- **Recorded**: 2026-10-28
- **Severity**: behavior change. On SQLite, `Cast(x, "tsvector")` and `Cast(x, "tsquery")` used to build and return a value the cast never meant. Both now raise `BackendCapabilityError` when the query is built. PostgreSQL is unchanged.

### What changed

`tsvector` and `tsquery` are full-text search, a feature SQLite lacks (`full_text_search` in the
backend capability table). The `@search` lookup and the `Search*` functions already raised
`BackendCapabilityError` there, but a cast to either type did not:

- `Cast(x, "tsvector")` rendered `CAST(x AS TEXT)`, so it returned the text unchanged. PostgreSQL
  parses the text into a document instead: `'Grand Prix Grand'::tsvector` is `'Grand' 'Prix'`.
- `Cast(x, "tsquery")` rendered `CAST(x AS TSQUERY)`, a type name SQLite reads with NUMERIC affinity,
  so `'senna'` came back as `0`.

Both now raise `BackendCapabilityError` naming full-text search and PostgreSQL, as the lookup and the
functions do. The same holds for the field-object spelling (`Cast(x, SearchVectorField())`) and for a
declared `output_field = "tsvector"`, `"tsquery"` or `SearchVectorField()` on
`Coalesce`/`Greatest`/`Least`/`Case`. MySQL, which is in no release yet, raises the same error, where
before it raised `UnsupportedConnectionError`.

| expression | before (SQLite) | now (SQLite) | PostgreSQL |
|---|---|---|---|
| `Cast("surname", "tsvector")` | the text, unchanged | `BackendCapabilityError` (#1425) | `(surname)::tsvector`, unchanged |
| `Cast("surname", "tsquery")` | `0` | `BackendCapabilityError` (#1425) | `(surname)::tsquery`, unchanged |
| `Cast("surname", "text")` | the text | the text, unchanged | the text, unchanged |

### Who this affects

Code that casts to `tsvector` or `tsquery` on SQLite. That is typically a query written for
PostgreSQL and run against SQLite in tests.

### How to find the calls to migrate

```bash
grep -rn -i -E '"ts(vector|query)"|SearchVectorField\(\)' --include=*.jl src/ test/
```

A `SearchVectorField()` match in a model definition is a column, not a cast, and is unaffected.

### Migrate your app

```julia
# ✗ before — the text on SQLite, a parsed document on PostgreSQL; now raises on SQLite (#1425)
q = M.Driver.objects
q.values("doc" => Cast("surname", "tsvector"))

# ✓ after — full-text search on PostgreSQL, written with its own functions
q = M.Driver.objects
q.filter("surname__@search" => SearchQuery("senna"))

# ✓ after — when the text is what you want, on every engine
q = M.Driver.objects
q.values("doc" => Cast("surname", "text"))
```
