---
name: pormg-public-api-development
description: Implement or refactor user-visible PormG ORM behavior through M.Model.objects, model definitions and loading, field validation contracts, docs/examples, README content, and integration tests.
---

# PormG Public API Development

## Purpose

Use this skill when changing PormG behavior, adding regression coverage, or writing examples that should reflect how a real package user interacts with the ORM.

The core discipline is simple: prefer the public fluent API in user-facing code and integration tests, and only drop into internal helpers when the test is explicitly about internals.

Use `pormg-migrations-development` instead when the task centers on `src/Migrations.jl` or `src/migrations/`.

Use `pormg-querybuilder-internals` instead when the task centers on `src/QueryBuilder.jl`, files under `src/querybuilder/`, SQL rendering, or parameter bucket routing.

## Use This Skill For

- Implementing feature work in `src/` when the change is expressed through the public ORM surface rather than the migration subsystem or low-level QueryBuilder internals
- Editing `src/Models.jl`, `src/models/fields.jl`, `ext/PormGReviseExt.jl`, or other public-facing model/loading code
- Fixing ORM regressions discovered in integration tests
- Writing or refactoring tests in `test/integration/`
- Writing examples and docs in `README.MD`, `src/*.md`, and `docs/` that should mirror package usage
- Deciding whether a regression belongs in unit tests, integration tests, or both

## Public API First

### Preferred query style

Use the fluent surface exposed by `ObjectHandler` and `model.objects`.

**Accumulate steps on a named variable** (preferred for multi-step queries and test setup):

```julia
query = M.Result.objects
query.filter("driverid__surname" => "Senna", "positionorder" => 1)
query.values("raceid__year", "raceid__name", "constructorid__name")

rows = query.list()
exists = query.exists()
count = query.count()
```

**Inline chain with multi-line argument style** (preferred for one-off reads where a named query variable adds no clarity):

Place each argument list on its own indented line inside the call parentheses. The closing `)` sits at the same column as the start of the call, immediately followed by the next `.method(` with no line break in between:

```julia
row = M.Result.objects.filter(
    "driverid__surname" => "Senna",
    "positionorder" => 1
).values(
    "raceid__year", "raceid__name"
).list() |> first
```

Do **not** break the chain by starting a new line with a leading `.`:

```julia
# ✗ avoid — Julia requires a trailing operator to continue across lines
row = M.Result.objects
          .filter("driverid__surname" => "Senna")  # leading dot — parse error risk
          .list() |> first
```

### For terminal operations, prefer fluent methods

- Use `query.list()` instead of piping to a free `list` helper
- Use `query.list(:json)` for JSON output
- Use `query.delete()` instead of a free `delete(query, ...)` call
- Use `query.count()` and `query.exists()` for behavior-focused tests

### When direct helper calls are acceptable

Use internal or function-style helpers only when the test is explicitly about internals or when no fluent equivalent exists:

- `inspect_query(q)` for query inspection of SELECT queries (its heuristic automatically detects SELECT, but requires explicit hints for DELETEs).
- `show_query=:dict` on terminal methods (e.g. `query.delete(show_query=:dict)`, `query.update(show_query=:dict)`) for inspecting mutation and bulk operations.
- `bulk_insert`, `bulk_update`, `bulk_copy` for bulk APIs
- direct `PormG.QueryBuilder` imports in unit tests targeting builders, buckets, or planner behavior

## Query, model, and field contracts

### Query construction contracts

- Prefer the pipe operator `|>` when it makes multi-step query construction easier to read
- Use `String` keys for dynamic filter field names
- Use double underscore `__` for joins and lookups
- Use `__@operator` for modifier lookups
- Use `Qor` for OR logic; do not rely on bitwise `|` or `&` for query composition
- Prefer `F("fieldname")` for database-side field references in updates, arithmetic projections, and field-to-field comparisons
- Avoid `query.filter(F("points") > 20)` when the scalar predicate is clearer as `query.filter("points__@gt" => 20)`
- `DataFrame` is the primary output format for analytical queries, while `list()` returns `Vector{PormGRow}` and `list(:dict)` returns `Vector{Dict{Symbol, Any}}`

### Model loading and naming contracts

- Define models with `Models.Model` and call `Models.set_models(@__MODULE__, @__DIR__)` after the module when using the classic model-loading path
- Keep Julia model bindings capitalized even when SQL tables are snake_case
- Prefer `PormG.@import_models "path/to/models.jl" my_models` for hot-reload-friendly model loading
- If defining models inline rather than in a separate file, use `PormG.@models_module ... begin ... end`

### Field validation contracts

- Validation happens at the ORM layer before SQL generation
- `FloatField` accepts finite numeric values or strictly valid numeric strings, including scientific notation
- `FloatField` rejects `Inf`, `-Inf`, `NaN`, and garbage numeric strings
- `DecimalField` validates `max_digits` and `decimal_places` in Julia before the query reaches the database
- `DateTimeField.default` stores `Union{ZonedDateTime, DateTime, Nothing}`
- A naive Julia `DateTime` currently serializes as UTC through the default formatter path
- Prefer `ZonedDateTime` when the source value has a real civil timezone
- `auto_now` and `auto_now_add` attach `settings.time_zone` to generated values
- `DateField` accepts `Date`, `DateTime`, `ZonedDateTime`, and `YYYY-MM-DD` strings, coercing temporal values to their calendar date

## Documentation and example rules

- Do not use generic examples such as `User`, `Post`, `Foo`, or `Bar`
- User-facing docs and examples must use the Formula 1 dataset from `test/integration/db_sl/models.jl` and `test/integration/db_2/`
- Prefer scenario-based examples that mirror realistic questions such as race wins, standings, or constructor comparisons
- Explicitly demonstrate join behavior through double-underscore relations when relevant
- Refer to the integration tests as the canonical example source for public behavior
- When documenting complex queries, briefly explain the generated SQL shape
- Keep limitations explicit instead of implying unsupported features are complete

### Verifying doc examples against the live database

Every query example added or changed in `docs/`, `README.MD`, or `src/*.md` should be confirmed **two ways** before commit: the **generated SQL shape** (no DB needed) and the **actual result** against the preloaded F1 data. `test/integration/db_sl/f1.sqlite` ships with the full dataset, so this needs no setup.

Run a scratch script placed under `test/integration/` (so `@import_models` resolves) or use absolute paths:

```julia
ENV["PORMG_ENV"] = "dev"            # never "test" — it breaks Generator scratch configs
import Pkg; Pkg.activate(".")
using PormG, DataFrames
import PormG.QueryBuilder: Sum, Count, Max, Min, inspect_query
cd("test/integration")
PormG.Configuration.load("db_sl")               # local SQLite, F1 data preloaded
PormG.@import_models "db_sl/models.jl" models
import .models as M

q = M.Result.objects.filter("constructorid" => 131).
    values("max_points" => Max("points"), "n" => Count("resultid"))

println(inspect_query(q)[:sql_text])            # 1. confirm SQL shape (returns before any DB call)
df = q |> DataFrame                             # 2. execute against live data
# 3. cross-check the value, not just that it ran:
raw = (M.Result.objects.filter("constructorid" => 131).values("points") |> DataFrame).points
@assert df[1, :max_points] == maximum(raw) && df[1, :n] == length(raw)
```

Rules and gotchas:

- **Verify the value, not just execution.** For aggregates/computed columns, recompute the answer independently (raw row scan, plain `Sum`, etc.) and assert equality — a query that runs can still be wrong.
- **Query field paths must be lowercase** (`constructorid__name`), even though models declare camelCase fields. CamelCase join paths throw at build time.
- **`@import_models` resolves its path relative to the script file's directory** — keep the script in `test/integration/` or pass an absolute path.
- **Dialect placeholders differ:** db_sl (SQLite) renders `?`, db_2 (PostgreSQL) renders `$1`. Doc SQL blocks conventionally show the PostgreSQL form; note the SQLite difference when it matters.
- `inspect_query(q)[:sql_text]` (or `show_query=:sql`) renders before any DB round-trip, so the SQL-shape check works even without a live connection.

### Auxiliary mechanics-only models

- `M.Just_a_test_deletion`: CRUD and deletion safety tests
- `M.Just_a_nested_roll_back`: transaction rollback and savepoint tests
- `M.New_join_position`: specialized join-mechanics tests

## Test Placement Rules

### Integration tests

Put behavior tests in `test/integration/` when the real question is:

- Did the ORM return the correct rows?
- Did joins, filters, updates, deletes, and transactions behave correctly?
- Did the public API remain stable for package users?

Integration tests should use:

- `M.Model.objects`
- fluent query methods
- real Formula 1 models unless the test is about auxiliary mechanics

### Unit tests

Put tests in `test/unit/` when the real question is:

- Did SQL text render correctly?
- Did parameter ordering or bucket routing stay correct?
- Did a low-level validator or planner behave deterministically?

For positional parameter regressions, the canonical unit target is `test/unit/test_alignment_sqlite.jl`.

### If a bug spans both layers

Add both:

1. one narrow integration regression proving the user-visible failure
2. one deterministic unit test proving the internal root cause

## Test Writing Standard

- **Use standardized block headers for all `@testset` blocks**:
  ```julia
  # ─────────────────────────────────────────────────────────────────────────────
  # [Feature/Area]: [Specific scenario being tested]
  # [1-2 sentences explaining what the test verifies, the expected SQL shape, 
  # and why the behavior matters to users or future maintainers]
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "..." begin
  ```
- Heavily comment test logic within the block
- Prefer isolated setup and explicit cleanup over hidden shared state
- Do not weaken model contracts just to accommodate dirty fixtures; normalize fixtures in the import layer instead

## Domain Rules

- Use Formula 1 dataset examples for user-facing docs and examples
- Keep Julia model bindings capitalized even when SQL tables are snake_case
- Prefer expressive ORM filters and joins over raw SQL
- Preserve async-first assumptions and transaction safety
- When importing Formula 1 fixtures, normalize bad source values in the import or test layer rather than weakening field contracts

## Workflow

1. Read the relevant source and failing tests first
2. Fix the root cause, not just the symptom
3. Add or adjust tests through the public API when behavior changed
4. Add unit coverage when the bug lives in builder/rendering/validation internals
5. Run the smallest relevant test slice first
6. Run the broader suite only after targeted failures are green

## Verification Commands

```powershell
julia --project=. test/runtests.jl
julia -t auto --project=. test/integration/runtests.jl
julia -t auto --project=. test/integration/test_bulk_copy.jl
$env:PORMG_DB="db_sl"; julia -t 1 --project=. test/integration/runtests.jl
julia --project=. docs/make.jl
```

## Anti-Patterns

- Do not write integration tests against internal helper functions when the public API can express the same behavior
- Do not document unsupported APIs as if they were stable
- Do not use generic `User` or `Post` examples in docs
- Do not duplicate SQLite parameter bucket coverage in integration tests unless reproducing a known production regression
