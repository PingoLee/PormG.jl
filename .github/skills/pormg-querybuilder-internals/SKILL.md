---
name: pormg-querybuilder-internals
description: Work on QueryBuilder internals in src/QueryBuilder.jl, src/querybuilder/, and src/Dialect.jl: SQL generation, parameter buckets, joins, CTEs, functions, deletion planning, and inspection paths, with deterministic unit coverage.
---

# PormG QueryBuilder Internals

## Purpose

Use this skill when the task is inside the SQL builder itself: parameter collection, SQL rendering, join generation, CTE behavior, function translation, deletion planning, or internal inspection behavior.

This skill is for implementation and regression analysis inside `src/querybuilder/`.

## Use This Skill For

- Editing `src/QueryBuilder.jl`
- Editing files under `src/querybuilder/`
- Editing `src/Dialect.jl` when the change affects SQL clause or function rendering
- Fixing SQL rendering regressions
- Fixing parameter ordering and bucket routing
- Fixing `With`, `cjoin`, `on`, `having`, alias promotion, and join planning internals
- Working with `inspect_query`, `show_query`, and builder metadata

## Core entry points

- `src/QueryBuilder.jl` is the builder entry point and includes the specialized querybuilder modules
- `build_helpers.jl`, `build_joins.jl`, `build_query.jl`, `ctes.jl`, `deletion.jl`, `execution.jl`, and `functions.jl` are the main internal coordination surfaces
- Keep user-facing behavior expressed through `M.Model.objects`; reach into builder internals only for implementation work or deterministic unit coverage

## Boundary With Public API Work

- If the bug is user-visible, add one integration regression through the fluent public API
- Then add a narrow internal unit test if the root cause is builder-specific
- Do not replace behavior tests with internals-only tests

## Internal Focus Areas

### Parameter routing

For positional backends, preserve bucket semantics and flatten order. The buckets below are the **single authoritative list** — `set_context!` sites and the `get_final_parameters` flatten order must agree with it; do not restate the list elsewhere:

`:cte → :select → :update → :join → :where → :having`

Parameter collector model:

- `AbstractPormGParam`: base abstraction for all collectors
- `PormGPostgresParam`: linear collector for `$1`, `$2`, ... placeholders
- `PormGPositionalParam`: bucketed collector for positional `?` placeholders

When changing parameter behavior, verify:

- context switching through `set_context!`
- marker and parameter count alignment
- parent and subquery inheritance behavior
- HAVING alias promotion placement
- custom join parameter routing into the join bucket
- flattening through `get_final_parameters(::PormGPositionalParam)` in SQL-clause order

Query-building context rules:

- context changes belong in query-build modules, not in execution code
- HAVING alias promotion must switch context to `:having` before `add_parameter!`
- join `on` conditions from `cjoin` must run with `:join` context
- subqueries and CTEs must inherit the parent collector and context when required

Canonical unit files:

- `test/unit/test_alignment_sqlite.jl`
- `test/unit/test_parameters.jl`

Integration touchpoints:

- `test/integration/test_having.jl`
- `test/integration/test_cjoin.jl`
- `test/integration/test_cte.jl`

For the unit-vs-integration split, see *Boundary With Public API Work* above and *Test Placement Rules* below.

### Identifier sanitization contract

`sanitization.jl` uses a **fail-closed** model — never a silent-stripping one:

- `_validate_identifier(id)` validates against `SAFE_IDENTIFIER_PATTERN` (`^[\p{L}_][\p{L}\p{M}\p{N}_]*$`) and throws `ArgumentError` on invalid input; it never silently removes characters.
- `quote_identifier(id, conn)` calls `_validate_identifier` then wraps in double-quotes, preserving exact case and Unicode letters.
- `sanitize_identifier(id, valid_ids)` checks the raw identifier against the whitelist (no pre-stripping), then delegates quoting to `quote_identifier`.
- `safe_table_identifier(name, conn)` delegates directly to `quote_identifier` — no silent sanitize-and-warn fallback.
- All SELECT aliases (`custom_as` and `_as`) are quoted via `quote_identifier` in `_query_select`, preserving mixed case and Unicode characters verbatim.

When adding any new identifier-quoting path, go through `quote_identifier` — never strip-and-quote.

### Error message construction

Error messages may colorize the offending token with ANSI for the REPL, but they **must** degrade off-TTY. Route query-builder errors through `_argerr(msg)` (defined in `querybuilder/exceptions.jl`), or wrap a raw `throw`/`error` string with `_emsg(...)`:

- `_emsg(msg; color = Base.have_color === true)` is the single shared helper, defined in `src/Kernel.jl` (layer 1 — it moved out of `src/tools.jl` in #254, because the error-taxonomy constructors call it and the taxonomy has to be reachable from every submodule). It keeps ANSI when color is on and strips every `\e[..m` code otherwise (CI, file logs, structured logging) — `Base.have_color` is the same flag Julia uses to colorize its own error displays, so it honors `--color` and `NO_COLOR`. The `color` keyword exists for deterministic testing.
- `_argerr(msg) = QueryBuildError(msg)` is the common case: a call site changes only `ArgumentError(` → `_argerr(` (paren structure unchanged). It has **not** returned an `ArgumentError` since #231 — the name is historical. The subtype's own constructor applies `_emsg`, so don't wrap twice.
- The taxonomy **types** live in `src/exceptions.jl` (included by `Kernel`); only the throw funnels (`_argerr`, `_unsupported_conn`, `_write_not_allowed`) live in `querybuilder/exceptions.jl`, next to their call sites. Sibling subsystems have their own funnels — see `general.instructions.md`.
- Never write `throw(ArgumentError("...\e[31m..."))` directly — raw escape codes leak as noise into non-TTY sinks.
- `_emsg(io, msg)` is the IO-aware overload for `show` / `print(io, …)` methods: it keys off the destination stream's `:color` IOContext property (`get(io, :color, false)`) rather than the global flag, so a non-color buffer (`sprint`, `repr`, a file) stays clean even on a color terminal.
- *Logging* macros (`@info` / `@warn` / `@error`) and interactive `print`/`println` also route their colored messages through `_emsg(…)` — this keeps log files and captured output ANSI-free when redirected (Julia clears `Base.have_color` for non-TTY stdout). Don't add a new `@info("…\e[31m…")` without the `_emsg` wrapper.

Scope: `_emsg` is shared (`src/tools.jl`, `PormG` namespace, both string and `IO`-aware methods); `QueryBuilder`, `Models`, and `Migrations` all `import PormG: _emsg`. `_argerr` is the QueryBuilder-internal convenience wrapper. Any submodule that needs colored errors/logs should import `_emsg` from `PormG` rather than re-embedding raw ANSI. Regression coverage: `test/unit/test_error_message_ansi.jl`.

### Query generation

Focus on:

- `build_helpers.jl`
- `build_joins.jl`
- `build_query.jl`
- `ctes.jl`
- `execution.jl`
- `deletion.jl`

Gotcha — `do_count` (`execution.jl`): it clears `.values`/`.order` before rendering, so `count()` cannot reuse a `.values()` select. `COUNT(DISTINCT *)` is **invalid SQL on both PostgreSQL and SQLite**, so the count forms diverge:

- `count()` → `COUNT(*)`.
- query-level distinct (`.distinct().count()` / `count(distinct=true)`) → wrap `SELECT DISTINCT *` in an **outer `COUNT(*)` subquery** (so `count() == length(distinct list())`).
- `count("col", distinct=true)` → flat, valid `COUNT(DISTINCT col)` by reusing the `Count()` aggregate (single column is legal; `*` is not).

When changing count rendering, verify both dialects execute (not just that the SQL string looks right) — the bug this guards against was a syntax error that only surfaced at execution.

### Inspection tools

Useful internal tools:

- `show_query=:sql` on terminal methods (returns just the query string)
- `show_query=:dict` on terminal methods (returns comprehensive metadata; e.g. `query.delete(show_query=:dict)`)
- `inspect_query(q)` (used internally before execution; prefer `show_query` in integration/public API testing)
- direct builder inspection when debugging parameter state

### Maintenance checklist

When introducing a new parameterized SQL clause or changing clause order, update all of the following together:

- bucket struct fields in `parameters.jl`
- `set_context!` call sites in builder modules
- `get_final_parameters` flatten order
- unit coverage in the canonical alignment tests
- integration coverage if the behavior is user-visible

## Test Placement Rules

### Unit tests

Prefer unit tests when the question is:

- Did the SQL text render correctly?
- Did parameters land in the right bucket and order?
- Did alias promotion happen in the right clause?
- Did `cjoin`, `With`, or custom join wiring produce the intended internal metadata?

### Integration tests

Use integration tests when the question is:

- Did the query return the right rows?
- Did update/delete/join semantics behave correctly end to end?

Integration regressions should still use the public fluent API unless the bug only reproduces through a lower-level path.

## Test Writing Standard

Follow the canonical [PormG Test Writing Standard](../../instructions/test-writing.md): standardized `@testset` header comments and heavily commented test logic.

## Workflow

1. Reproduce the failure with the smallest relevant query
2. Inspect the built query or parameters before editing code
3. Fix the root cause in the smallest internal module possible
4. Add deterministic unit coverage
5. Add a public-API integration regression if user-visible behavior changed
6. Re-run the narrow test slice before broader suites

## Verification Commands

```powershell
julia --project=. test/unit/test_alignment_sqlite.jl
julia --project=. test/unit/test_inspect_query.jl
julia -t auto --project=. test/integration/test_having.jl
julia -t auto --project=. test/integration/test_cjoin.jl
julia -t auto --project=. test/integration/test_cte.jl
```

## Anti-Patterns

- Do not duplicate the full parameter bucket matrix in integration tests
- Do not fix SQL shape bugs only by changing test expectations without validating semantics
- Do not bypass public API regressions when the failure is visible to package users
- Do not mix unrelated SQL formatting changes into a targeted regression fix
- Do not revert to silent identifier stripping (e.g. `replace(id, r"[^a-zA-Z0-9_]" => "")`) — the contract is fail-closed: validate via `_validate_identifier`, then quote; never silently rewrite an identifier
- Do not embed raw ANSI (`\e[...`) in a `throw`/`error`/`@info`/`@warn`/`@error`/`print` message — route through `_argerr`/`_emsg` (or `_emsg(io, …)` inside `show` methods) so color degrades off-TTY
