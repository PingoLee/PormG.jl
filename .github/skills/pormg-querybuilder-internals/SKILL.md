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
- Fixing `.with`, `.cjoin`, `.on`, `having`, alias promotion, and join planning internals
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

**A nested render does not pick a bucket (#432).** An `Exists(...)`, a projected `Subquery(...)` or an `__@in` subquery renders inside the PARENT's clause, so its values are marked, lifted and re-emitted as one clause-ordered run at the parent's marker position (`nested_parameter_mark` / `detach_nested_run!`), with `own_contexts=true` so the inner build files its values under its own clauses first. Binding order is not text order: a build binds joins last and renders them first, which is what the buckets exist to reconcile.

**The cross-backend differential is the oracle for parameter order.** Do not eyeball it. PostgreSQL
numbers placeholders as it binds, so `$N` travels with the text and is authoritative: walk the `$N`
markers left to right, map each through PostgreSQL's parameter vector, and you have the true text
order. SQLite's flattened vector must equal it.

```julia
pg  = inspect_query(build_it(); connection = a_postgres_mock)
sl  = inspect_query(build_it(); connection = a_sqlite_mock)
idx = [parse(Int, m.match[2:end]) for m in eachmatch(r"\$\d+", pg[:sql_text])]
text_order = [pg[:parameters][i] for i in idx]     # authoritative
@assert sl[:parameters] == text_order              # SQLite must match it
```

This turns "is this order right?" from a judgment call into a measurement, and it scales: the #432
fix was validated by sweeping 29 shapes through it (20 misaligned before, 0 after) rather than by
reasoning about buckets. Every bug in the #421 / #432 / #441 family is findable in one pass with it.
Two caveats: `__@in` binds as ONE array parameter on PostgreSQL and expands to N `?` on SQLite — a
dialect split, not a misalignment; and a value legitimately reused twice on PostgreSQL renders the
same `$N` twice, so compare distinct indices when counting.

Parameter collector model:

- `AbstractPormGParam`: base abstraction for all collectors
- `PormGPostgresParam`: linear collector for `$1`, `$2`, ... placeholders
- `PormGSQLiteParam`: bucketed collector for positional `?` placeholders (concrete type `SQLiteParameterizedQuery`)

When changing parameter behavior, verify:

- context switching through `set_context!`
- marker and parameter count alignment
- parent and subquery inheritance behavior
- HAVING alias promotion placement
- custom join parameter routing into the join bucket
- flattening through `get_final_parameters(::PormGSQLiteParam)` in SQL-clause order

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

`sanitization.jl` has **two rules, one per axis** (#394). Neither ever strips characters silently.

| Kind of name | Function | Behavior |
| --- | --- | --- |
| Physical **table** — `model_table_name`, `relation.through_table`, a catalog row | `safe_table_identifier(name, conn)` | escape-only: `"` → `""`, then wrap |
| Physical **column** — `field_db_column`, `model_column`, a `row_join` `key_a`/`key_b`\* | `safe_column_identifier(name, conn)` | the same |

\* `key_b` is the one dual-natured slot: on a CTE join it holds the CTE's **projection alias**, not a physical column. `_with` validates that name fail-closed at declaration (`join_field.second`), which is why the render site can stay escape-only.
| **Alias** / query-time name — `instruc.alias`, a `cjoin_on` alias, a `.with(...)` CTE name, a SELECT `_as`/`custom_as` | `quote_identifier(name, conn)` | fail-closed: `_validate_identifier` then wrap |

- `_validate_identifier(id)` validates against `SAFE_IDENTIFIER_PATTERN` (`^[\p{L}_][\p{L}\p{M}\p{N}_]*$`) and throws **`InvalidValueError`** on invalid input; it never silently removes characters.
- `_escape_identifier(name)` is the shared escape. `_quote_ident_raw` is the same thing without a `conn`, for a name interpolated into a SQL string literal that PostgreSQL re-parses as an identifier (`setval`'s `regclass`, `to_regclass`) — see `_table_ident_literal` in `execution.jl`.
- `SAFE_JSON_KEY_PATTERN` is a **separate constant** with the same body, used only by `_validate_json_key_segments` (`build_joins.jl`). A JSON path segment is interpolated *unquoted* into a path literal, so the charset check is its entire guard; keeping the constants apart is what stops a relaxation of the identifier rules from widening it.

**Do not unify these — the split is the fix.** A physical name is pinned by the model author via `db_table`/`db_column` (deliberately unvalidated, #59/#50) or read from the database catalog; validating it meant PormG refused to query a table its own DDL had just created. An alias is chosen at query-build time and names nothing that exists, so it stays strict. When adding a new identifier-quoting path, pick by which of the three it is — never strip-and-quote.

### Error message construction

Error messages may colorize the offending token with ANSI for the REPL, but they **must** degrade off-TTY. Throw a taxonomy subtype directly — its constructor applies `_emsg` — or wrap a raw `throw`/`error` string with `_emsg(...)`:

- `_emsg(msg; color = Base.have_color === true)` is the single shared helper, defined in `src/Kernel.jl` (layer 1 — it moved out of `src/tools.jl` in #254, because the error-taxonomy constructors call it and the taxonomy has to be reachable from every submodule). It keeps ANSI when color is on and strips every `\e[..m` code otherwise (CI, file logs, structured logging) — `Base.have_color` is the same flag Julia uses to colorize its own error displays, so it honors `--color` and `NO_COLOR`. The `color` keyword exists for deterministic testing.
- **`throw(QueryBuildError("…"))` is the common case** — the long-tail bucket for query-shape misuse. Name the subtype at the call site; the constructor applies `_emsg`, so don't wrap twice. There is deliberately no alias for this: #262 deleted `_argerr(msg) = QueryBuildError(msg)` because it only hid which type was thrown, and `test/unit/test_docs_error_type_drift.jl` fails if it returns.
- The taxonomy **types** live in `src/exceptions.jl` (included by `Kernel`). What lives in `querybuilder/error_funnels.jl` is only the funnels that **compose a message** from parameters — `_unsupported_conn`, `_write_not_allowed`. A helper that merely maps a message to a type is an alias, not an abstraction; write the type instead.
- **The funnel convention: a helper RETURNS the exception, the call site THROWS it** — `throw(_write_not_allowed(op, key))`. Uniform with direct construction, so there is nothing to remember per helper. A funnel that threw internally would invite the mirror-image mistake at a returning one, where a forgotten `throw(` silently constructs an exception, discards it, and lets execution continue past the guard. `test/unit/test_typed_exceptions.jl` pins it.
- Never write `throw(ArgumentError("...\e[31m..."))` directly — raw escape codes leak as noise into non-TTY sinks.
- `_emsg(io, msg)` is the IO-aware overload for `show` / `print(io, …)` methods: it keys off the destination stream's `:color` IOContext property (`get(io, :color, false)`) rather than the global flag, so a non-color buffer (`sprint`, `repr`, a file) stays clean even on a color terminal.
- *Logging* macros (`@info` / `@warn` / `@error`) and interactive `print`/`println` also route their colored messages through `_emsg(…)` — this keeps log files and captured output ANSI-free when redirected (Julia clears `Base.have_color` for non-TTY stdout). Don't add a new `@info("…\e[31m…")` without the `_emsg` wrapper.

Scope: `_emsg` is shared (`src/Kernel.jl`, `PormG` namespace, both string and `IO`-aware methods); `QueryBuilder`, `Models`, and `Migrations` all `import PormG: _emsg`. Any submodule that needs colored errors/logs should import `_emsg` from `PormG` rather than re-embedding raw ANSI. Regression coverage: `test/unit/test_error_message_ansi.jl`.

### Fluent surface: `ChainCaller` vs closure

`Base.getproperty(::ObjectHandler, sym)` in `object_manager.jl` builds each fluent method one of two
ways, and the choice is forced by whether the method takes keywords:

- **`ChainCaller(mutator!, q)`** — positional only. The functor packs the call's varargs into **one
  tuple** and calls `mutator!(q.object, args)`, so the mutator's signature is
  `f(::SQLObject, ::Tuple{…})` and **arity is dispatch**. Every accepted arity needs its own
  `Tuple{…}` method *and* the family needs an `::Any` fallback throwing a taxonomy subtype —
  otherwise a wrong shape escapes as a `MethodError` naming an internal `f!` and a tuple the caller
  never wrote (#272). The functor rejects keywords with a `QueryBuildError` for the same reason.
- **A closure** — e.g. `(args...; kwargs...) -> (f(q, args...; kwargs...); q)`, or `(; kwargs...)`
  when there are no positional arguments — the only way to forward keywords (#26). `.with`,
  `.cjoin`, `.cjoin_on`, `.on` and `.select_for_update` use this form.

So adding a keyword to a `ChainCaller`-backed method means **converting it to a closure**; leaving it
as a `ChainCaller` makes the keyword throw. Coverage: `test/unit/test_fluent_parity_208.jl`.

**Naming the helpers behind the chain (#281).** The rule:

> Of the helpers **PormG itself owns**, one is `_`-prefixed unless the name is API in its own
> right — i.e. unless `Base.ispublic(QueryBuilder, name)`.

The 29 branches route to 29 targets, and since #305 there is **no exception list**: **20**
`_`-prefixed (`_filter!`, `_db!`, `_values!`, `_order_by!`, `_limit!`, `_offset!`, `_page!`,
`_distinct!`, `_select_for_update!`, `_create!`, `_update!`, `_update_or_create!`,
`_get_or_create!`, `_count`, `_aggregate`, `_exists`, `_with`, `_cjoin`, `_cjoin_on`, `_on` —
matching the `_` marker the rest of `src/` already uses for an internal, `_query_select`,
`_validate_identifier`, …), **5** bare and public (`list`, `delete`, `earliest`, `latest`,
`inspect_query`), and **4** Base-owned and out of scope (`first`, `last`, `get`, `deepcopy`).

**The ownership clause is load-bearing, not a hedge** — read it as *"a name PormG can rename"*. The
chain routes to `first`, `last`, `get` and `deepcopy`, whose bindings resolve to `Base`; an unscoped
rule would demand renaming `Base.deepcopy`. And it is *not* "Base's names are exempt": `first`/`last`
pass `ispublic` only because `src/QueryBuilder.jl:135` declares `public first, last` and `get`
because `:105` exports it, while `deepcopy` and `copy` are equally Base's and are `ispublic == false`.
Ownership sets the scope; `ispublic` decides what is in it. It is rooted at **PormG**, not
QueryBuilder, so a helper defined in a sibling module and imported here stays covered — it is
renameable, and just as able to leak through `_fluent_name`.

**The join/CTE family used to be the exception (#305).** `With` was exported and `cjoin` was
`public` because each had a documented free-function form, which left their siblings `on`/`cjoin_on`
as two hard-coded exceptions — prefixing only those two would have split one family's spelling.
#305 removed the split at its source by withdrawing the free-function form entirely: the fluent
`.with` / `.cjoin` / `.cjoin_on` / `.on` are the only public surface, so all four are internals and
the rule covers them like any other helper. `_with` is lowercase for consistency with every
other helper — the capital `W` only existed because the name was user-facing. Not a `_fluent_name`
argument: all four are closure-backed, so they never reach `ChainCaller`.

The rule is enforced, not just documented: that testset extracts every PormG-owned function named in
the `getproperty` body and asserts the non-`_`, non-public set is **empty**. If a name ever shows up
there, make the code satisfy the rule — rename it, or declare it `public` if it is genuinely API.
**Do not re-add names to that list**; it becomes an allowlist and stops guarding anything.

The rule is about the **name**, not about call sites. `_count`/`_exists` (`deletion.jl`) and
`_values!`/`_filter!` (`execution.jl`) are all called from elsewhere inside `src/querybuilder/`;
internal reuse does not make a helper API, being declared API does.

This is diagnostic, not cosmetic: these names are what a user sees when a chain misfires (#272 surfaced
as `no method matching page!(::SQLObjectQuery, ::Tuple{Int64})`), and the prefix is the signal that the
spelling is one they could not have typed. `_fluent_name` in `object_manager.jl` is the exact inverse
of this rule — it strips `^_` and `!$` to recover the method the caller wrote — so **adding a helper
that does not follow the rule silently degrades the kwarg-rejection message.**

**A `ChainCaller`-backed helper carries no docstring.** Not because it would be published — since
#289 `api.md` sets `Private = false`, so an un-`public` name stays off the site either way — but
because there is no **user-facing** binding to attach docs to — the fluent `.values(...)` a reader
would `?` is synthesized by `getproperty` and has none, and nobody reaches `_values!` by name — so
the text would only ever be seen by someone already in the file. Three had drifted in — under their
pre-#281 spellings `up_filter!`, `up_values!` and `order_by!`; `page` had it until #280. Put the contract on the `object` docstring's `.method(...)` bullet
and use a `#` comment on the helper. `test_docstring_coverage.jl` enforces it, scoped to the
`ChainCaller(helper, q)` branches —
widening it to every `sym === :name` branch is not possible, because the closure branches route to
`first`/`last`/`get`/`deepcopy`, whose bindings resolve to `Base` and are documented there.

**What reaches the published API page (#289).** `docs/src/api.md`'s `@autodocs` sets
`Private = false`, so a docstring is published only if its name is `export`ed **or** declared
`public` (Julia 1.11+). Adding a docstring to an internal is therefore safe — it stays in the source
and off the site.

The trap is which module Documenter asks. It calls `Base.ispublic(mod, name)` against the module the
docstring was **written in**, never `PormG`'s re-export list, because `Docs.meta` is per-module and
`import`/`export` do not copy entries. So a user-facing name defined here needs its `public`
declaration **here** — `inspect_query` and `show_query` are exported from `PormG` and would still
have vanished from the page without the declaration in `src/QueryBuilder.jl`.

Making something user-facing? Declare it `public` next to the exports **and** add it to the frozen
set in `test/unit/test_docstring_coverage.jl` ("the `public`-but-unexported surface"). That test
exists because over-declaring silently republishes an internal and no docs build will tell you.

New fluent method? `test/unit/test_docstring_coverage.jl` scans the `sym === :name` branches and
requires each one documented in **both** the `object` docstring and `docs/src/api.md`.

### Query generation

Focus on:

- `build_helpers.jl`
- `build_joins.jl`
- `build_query.jl`
- `ctes.jl`
- `execution.jl`
- `deletion.jl`

Gotcha — `_count` (`execution.jl`): it clears `.values`/`.order` before rendering, so `count()` cannot reuse a `.values()` select. `COUNT(DISTINCT *)` is **invalid SQL on both PostgreSQL and SQLite**, so the count forms diverge:

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
- `_BUCKET_ORDER` in `parameters.jl` — the single list both `get_final_parameters` and
  `detach_nested_run!` (#432) read; there is no second copy to keep in sync
- unit coverage in the canonical alignment tests
- integration coverage if the behavior is user-visible

## Test Placement Rules

### Unit tests

Prefer unit tests when the question is:

- Did the SQL text render correctly?
- Did parameters land in the right bucket and order?
- Did alias promotion happen in the right clause?
- Did `.cjoin`, `.with`, or custom join wiring produce the intended internal metadata?

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
- Do not revert to silent identifier stripping (e.g. `replace(id, r"[^a-zA-Z0-9_]" => "")`) — an alias is fail-closed (`quote_identifier`), a physical table or column is escape-only (`safe_table_identifier` / `safe_column_identifier`), and neither ever silently rewrites an identifier
- Do not route a physical table or column through `quote_identifier`, or an alias through `safe_*_identifier` — the partition above **is** the contract, and collapsing it re-opens #394
- Do not embed raw ANSI (`\e[...`) in a `throw`/`error`/`@info`/`@warn`/`@error`/`print` message — throw a taxonomy subtype (its constructor applies `_emsg`) or wrap with `_emsg` / `_emsg(io, …)` inside `show` methods, so color degrades off-TTY
- Do not reintroduce a funnel that only maps a message to a type (the deleted `_argerr`); name the subtype at the call site
