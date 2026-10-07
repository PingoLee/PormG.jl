---
name: pormg-querybuilder-internals
description: "Work on QueryBuilder internals in src/QueryBuilder.jl, src/querybuilder/, and src/Dialect.jl: SQL generation, parameter buckets, joins, CTEs, functions, deletion planning, and inspection paths, with deterministic unit coverage."
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
- `build_helpers.jl`, `build_joins.jl`, `build_query.jl`, `ctes.jl`, `deletion.jl`, `execution_read.jl`, `execution_write.jl`, `expression_render.jl`, and `functions.jl` are the main internal coordination surfaces
- `join_conditions.jl` owns what a condition in `on(path, …)` / `cjoin(filters = …)` / `cjoin_on(on = …)` refers to: the one relation resolver, the build-time binding passes (#977, #982), the render-time column recorder (#985), and — since #130 — the `on` / `cjoin` / `cjoin_on` entry points themselves, with the handle guards and #962's right-side check. See *Join conditions: bound at build* below before touching any join-condition code
- Keep user-facing behavior expressed through `M.Model.objects`; reach into builder internals only for implementation work or deterministic unit coverage

## Boundary With Public API Work

- If the bug is user-visible, add one integration regression through the fluent public API
- Then add a narrow internal unit test if the root cause is builder-specific
- Do not replace behavior tests with internals-only tests

## Internal Focus Areas

### Parameter routing

For positional backends, preserve bucket semantics and flatten order. The buckets below are the **single authoritative list** — the clauses `with_bucket` / `set_context!` name and the `get_final_parameters` flatten order must agree with it; do not restate the list elsewhere:

`:cte → :select → :update → :join → :where → :group → :having → :order`

**The bucket changes only through `with_bucket` on a build path — restore, never reset (#936, #939).** `with_bucket(f, instruc_or_params, clause)` sets the active bucket and restores the one it found, on return and on throw; `build()` wraps each clause in one, so a build hands its caller back the bucket it was entered with. A `finally set_context!(x, :where)` is a *reset*: right only while nothing nests, and once a render inside a render returns it files every later value in the wrong bucket — silently, SQLite only. The bucket lives on the shared collector, not in `RenderScope`, because outer and nested builds share one collector while a scope belongs to one instruction. `set_context!` is for **statement entry points** starting a fresh collector (`query()`/`count()`/`exists()` at top level, insert/upsert rows, update's SET list, bulk, many-to-many, the deletion collector, a fence re-emitting its lifted run). `test/unit/test_render_scope.jl` pins those by file, expression and count, and fails on any other `set_context!` call or any `.current_context` access outside `parameters.jl`; a new entry point goes on that list with its reason.

**A nested render does not pick a bucket (#432).** An `Exists(...)`, a projected `Subquery(...)` or an `__@in` subquery renders inside the PARENT's clause, so its values are marked, lifted and re-emitted as one clause-ordered run at the parent's marker position (`nested_parameter_mark` / `detach_nested_run!`). The inner build files its values under its own clauses first — every build does since #936 retired the `set_contexts=false` / `own_contexts` inherit-the-parent's-bucket mode — and restores the parent's bucket itself. Binding order is not text order: a build binds joins last and renders them first, which is what the buckets exist to reconcile.

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

In a unit test, use `_pg_text_order` from `test/unit/helper_marker_alignment.jl` rather than
restating that walk; it also splats the one `__@in` array PostgreSQL binds.

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

- bucket switching through `with_bucket` (restore-only); `set_context!` only at a statement entry point
- marker and parameter count alignment
- parent and subquery inheritance behavior
- HAVING alias promotion placement
- custom join parameter routing into the join bucket
- flattening through `get_final_parameters(::PormGSQLiteParam)` in SQL-clause order

Query-building context rules:

- context changes belong in query-build modules, not in execution code
- HAVING alias promotion must switch context to `:having` before `add_parameter!`
- join `on` conditions from `cjoin` must run with `:join` context. That context is set where the ON clause renders (`build_query.jl`). Binding (`_bind_join_conditions!`) only resolves and checks the conditions earlier in the build and adds no parameters
- subqueries and CTEs must inherit the parent collector and context when required

Canonical unit files:

- `test/unit/test_alignment_sqlite.jl`
- `test/unit/test_parameters.jl`
- `test/unit/test_cte_reference.jl` — the `CTE(name, path)` namespace (#444); the CTE surface's entry point

Integration touchpoints:

- `test/integration/test_having.jl`
- `test/integration/test_cjoin.jl`
- `test/integration/test_cte.jl`

For the unit-vs-integration split, see *Boundary With Public API Work* above and *Test Placement Rules* below.

### Design note: the buckets are a two-pass artifact

Recorded so whoever patches this family next knows what they are patching.

**The buckets exist because SQL text and its parameters are produced by two separate passes.** A
build binds joins last and renders them first, so a reconciliation step has to put the two back in
agreement — that is what `with_bucket`, `_BUCKET_ORDER` and `detach_nested_run!` are for.

SQLAlchemy Core has no such step: its dialect compiler walks the expression tree emitting text
**and** binding parameters in the same pass, so positional order is correct by construction — no
bucket to route to, no flatten order to keep in sync, nothing to reconcile. The cross-backend
differential above is, in effect, a test that reconstructs by hand what a one-pass compiler gives
for free.

So **#421 / #432 / #441 are not three independent bugs** — they are one reconciliation failure
surfacing in three clauses, which is why fixing a fourth will not shrink the surface for a fifth.

**This is not a call to rewrite.** The bucket system works, is well covered, and a rewrite would be
a large breaking change for no user-visible gain. It is a marker: if this layer is ever redesigned,
the buckets are the thing that goes away, and the prior art for what replaces them is SQLAlchemy
Core — consistent with *Design stance* in
[`general.instructions.md`](../../instructions/general.instructions.md), since a bucket is implicit
reconciliation and a one-pass compile is not.

### Expression nodes: construct, never mutate

An operator or a build step takes an expression node and **returns a new one**; it never writes into
the node it was handed. `F("points") > 10`, `Sum("points")`, `Value("x")`, `CTE("ev", "sku")` and
`Joined("d", "col")` are values a user may bind to a name and reuse across queries, and the `F`
docstring promises exactly that.

**Since #508 phase 2 the type system holds the contract, not convention.** Seven node types are
declared `struct` — `SQLText`, `OperObject`, `FExpression`, `OuterRefObject`, `CTEReference`,
`FObject`, `WindowFunction` — joining `JoinedReference`, which was immutable from #481, and
`SQLOrder`, frozen in #540. Writing to a slot on any of them is a `setfield!` error at the call
site rather than a silent rewrite.

It took two defects to get there, and both are now unrepresentable rather than guarded:

- **#457 / #493** — the six `F` comparisons wrote `operation` / `operand` onto their left operand:
  `f == f` built a self-cycle that overflowed the stack, and `f > "a"; f < "z"` rendered
  `(("note" > ?) < ?)`. Fixed by making comparisons construct, as arithmetic always had.
- **#508** — `_values!`'s `Value` arm wrote `custom_as` onto the user's node, so a `Value` handle
  shared by two queries rewrote the first query's alias when the second was built. Phase 1 fixed the
  seam; phase 2 removed the ability.

The rules now:

- **Operators and walkers construct.** `_compare` (`operators.jl`) is the template: read every slot,
  set the new one, return a fresh node. `_check_function` / `_retag_cte_column` /
  `_retag_joined_column` (`build_helpers.jl`) and `_retag_cte_string` (`ctes.jl`) all follow it.
  `_retag_cte_string(::WindowFunction)` builds a fresh `WindowSpec` too — a spec reused across two
  window functions is documented as supported, so rewriting one in place reached a node the caller
  still held.
- **`SQLField` is the exception, and it is a build product.** The `_retag_*_field!` helpers still
  write into it, because it is what a String-path parse produced, never what a caller handed in.
  `SQLOrder` is no longer an exception (#540): it is a `struct`, `last()` inverts an ordering term
  by constructing a new one (`_invert_order`), and the render-time orientation re-validation that
  existed only because it was mutable is gone — the inner constructor's #77 whitelist is the only
  writer.
- **Containers are the other exception, and they are named.** `QObject` / `QorObject` support `push!`
  as documented API (`docs/src/read/q_objects.md`), and `WindowSpec` documents in-place assembly.
  They are containers, not nodes; do not extend that affordance to the node types. Containers are
  also where the remaining user-buildable cycles live, which is why `_guard_no_handle`'s depth cap
  (`join_conditions.jl`) stays: `push!(q, q)` on a `Q` is one, and a `WindowSpec` is another —
  `spec = WindowOver(partition_by = "c"); push!(spec.partition_by, Rank(over = spec))` type-checks,
  because `WindowFunction <: SQLTypeFunction <: WindowPartitionPart`.
- **A hand-written `deepcopy` is a symptom.** The seven that existed only to satisfy the #112 copy
  discipline (*a copy must share no MUTABLE state*) are deleted, and #540 deleted an eighth — the
  `SQLTypeOrder` one re-ran the #77 whitelist that Base bypasses, which a frozen struct makes moot.
  Three remain, none of them about mutability — `SQLTypeField` (deliberately shallow on `.field`),
  `SQLTypeOper` (shares an `SQLObjectHandler` rather than cloning a subquery) and `WindowSpec`
  (still a container). **Do not add another**: a node that needs a copy method to be safe is a node
  that should not be mutable.

### A declared type must not admit what no consumer handles (#533)

The sibling rule, and the one that is easiest to break by accident, because the breakage is
*inherited* rather than written. `SQLTypeOrder` used to be `<: SQLTypeField`, and ~26 unions name
`SQLTypeField` — so one subtype relation put `SQLOrder` into `WindowPartitionPart`, `ColumnPart`,
`FExpression.column`, `SQLObjectQuery.values` and all 18 scalar-function signatures at once. Each
accepted it and died at render with a raw `MethodError`. #529 reported one; there were ~25 behind it.

- **Prefer the concrete type in a union.** `CTEReference` is deliberately not `<: SQLTypeF` and
  `JoinedReference` not `<: SQLTypeCTE`, both so "every admission is a named seam" (`types.jl`).
  `FExpression.operand` names `FExpression`, not the abstract `SQLTypeF` — naming the abstract one
  silently admitted `OuterRefObject`, which bound RAW as a parameter. The other unions that name
  `SQLTypeF` — the `functions.jl` signatures and `WindowColumnPart` — keep admitting `OuterRefObject`
  on purpose: since #535 every one of them has a consumer (`_check_function(::OuterRefObject)` on the
  build side; the render side always resolved it against `instruc.outer`). The rule is "a consumer
  per admitted member", not "never the abstract type".
- **Widening a union is half a change.** The other half is a consumer arm. A member that binds raw is
  not "supported": on PostgreSQL the driver often adapts it and the bug hides; on SQLite it compares
  against a different representation and returns wrong rows silently.
- **`test/unit/test_node_admission.jl` is the backstop.** It probes each slot's real entry point —
  `hasmethod` cannot answer this, because `_resolve_window_expression` takes its argument untyped and
  branches on `isa` — and reports offenders grouped by admitted TYPE, so one inherited admission
  reads as one cause rather than 26 failures.

### Identifier sanitization contract

`sanitization.jl` has **two rules, one per axis** (#394). Neither ever strips characters silently.

| Kind of name | Function | Behavior |
| --- | --- | --- |
| Physical **table** — `model_table_name`, `relation.through_table`, a catalog row | `safe_table_identifier(name, conn)` | escape-only: `"` → `""`, then wrap |
| Physical **column** — `field_db_column`, `model_column`, a `row_join` `key_a`/`key_b`\* | `safe_column_identifier(name, conn)` | the same |

\* `key_b` is the one dual-natured slot: on a CTE join it holds the CTE's **projection alias**, not a physical column. `_with` validates that name fail-closed at declaration (`join_field.second`), which is why the render site can stay escape-only.
| **Alias** / query-time name — `instruc.alias`, a `cjoin_on` alias, a `.with(...)` CTE name, a SELECT `_as`/`custom_as` | `quote_identifier(name, conn)` | fail-closed: `_validate_identifier` then wrap |

- `_validate_identifier(id)` validates against `SAFE_IDENTIFIER_PATTERN` (`\A[\p{L}_][\p{L}\p{M}\p{N}_]*\z` — `\A…\z`, not `^…$`: PCRE's `$` matches before a final newline, #794) and throws **`InvalidValueError`** on invalid input; it never silently removes characters.
- `_escape_identifier(name)` is the shared escape. `_quote_ident_raw` is the same thing without a `conn`, for a name interpolated into a SQL string literal that PostgreSQL re-parses as an identifier (`setval`'s `regclass`, `to_regclass`) — see `_table_ident_literal` in `execution_write.jl`.
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

Since #305 there is **no exception list**. Every `getproperty` target falls into exactly three
groups: `_`-prefixed internals (matching the `_` marker the rest of `src/` already uses —
`_query_select`, `_validate_identifier`, …), a small bare-and-`public` set (`list`, `delete`,
`earliest`, `latest`, `inspect_query`), and Base-owned names out of scope (`first`, `last`, `get`,
`deepcopy`).

**The internals are deliberately not enumerated here.** That set grows with every fluent method
added, and a prose copy goes stale silently: the guard asserts `length(owned) >= 20` — a floor, not
an exact count — so a wrong number in this file would never fail a test.
`test/unit/test_docstring_coverage.jl` extracts the live set from the `getproperty` body; read the
names there. Maintaining a second copy here is the same mistake as the allowlist the rule below
warns against.

**"Owns" means "a name PormG can rename"** — that scoping is load-bearing, not a hedge. The chain
routes to `first`, `last`, `get`, `deepcopy`, whose bindings resolve to `Base`; unscoped, the rule
would demand renaming `Base.deepcopy`. But it is *not* "Base's names are exempt": `first`/`last`
pass `ispublic` only because `src/QueryBuilder.jl:135` declares `public first, last`, and `get`
because `:105` exports it — `deepcopy` and `copy` are equally Base's and are `ispublic == false`.
**Ownership sets the scope; `ispublic` decides what is in it.** Rooted at *PormG*, not QueryBuilder,
so a helper defined in a sibling module and imported here stays covered — still renameable, still
able to leak through `_fluent_name`.

**It is about the name, not call sites.** `_count`/`_exists` (`deletion.jl`) and `_values!`/`_filter!`
(`object_manager.jl`) are called from elsewhere in `src/querybuilder/`; internal reuse does not make a
helper API — being declared API does.

**Why the join/CTE family stopped being an exception (#305).** `With` was exported and `cjoin`
`public`, each having a documented free-function form, which stranded siblings `on`/`cjoin_on` as
two hard-coded exceptions — prefixing only those two would have split one family's spelling. #305
withdrew the free-function form instead, making the fluent `.with`/`.cjoin`/`.cjoin_on`/`.on` the
only public surface: all four are internals and the rule covers them like anything else. `_with` is
lowercase because the capital `W` only existed while the name was user-facing. Not a `_fluent_name`
argument — all four are closure-backed and never reach `ChainCaller`.

**Enforced, not just documented.** `test_docstring_coverage.jl` extracts every PormG-owned function
named in the `getproperty` body and asserts the non-`_`, non-public set is **empty**. If a name
appears, fix the code — rename it, or declare it `public` if it is genuinely API. **Never re-add
names to an exception list**; it becomes an allowlist and stops guarding anything.

This is diagnostic, not cosmetic. These names are what a user sees when a chain misfires (#272:
`no method matching page!(::SQLObjectQuery, ::Tuple{Int64})`), and the prefix signals a spelling
they could not have typed. `_fluent_name` (`object_manager.jl`) is the exact inverse — it strips
`^_` and `!$` to recover the method the caller wrote — so **a helper that breaks the rule silently
degrades the kwarg-rejection message.**

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
- `join_conditions.jl`
- `execution_read.jl`
- `execution_write.jl`
- `expression_render.jl`
- `deletion.jl`

### Join conditions: bound at build (#977)

Join conditions produced about 20 issues, each fixed correctly at its own call site. They kept
coming because a condition was resolved by proxies: string-prefixed at the call, checked against
whatever had been declared so far, and resolved with side effects that could add a join. #977
replaced the proxies with these rules, and #982/#985 (PR #991) extended them to `cjoin_on` and to
the "wrong row, no join" class. They are invariants, not style. The one open design question, whether
a typed column IR (I1) is still worth its cost, is #990.

- **One relation resolver.** "Which model does segment `s` reach from model `m`?" has exactly one
  answer: `_relation_step`, whose precedence is the renderer's first hop (JSON/array value lookup,
  ManyToMany, a `cjoin(field = …)` link on the first segment, the model field after the FK short
  form, a reverse relation). `_segment_field` is the **only** reader of a `cjoin` link
  (`_get_join_field`). Three resolvers disagreeing was #974. `test/unit/test_join_resolver_single.jl`
  scans the source and fails if a second resolver or link reader appears, so ask `_relation_step` or
  `_relation_prefix`; do not write a local walk.
- **Store as written, bind at build.** `.on()` and `.cjoin()` store the conditions exactly as the
  caller wrote them (`PathJoin.filters::Vector{JoinCondition}`), after only the checks that need no
  model (`_join_conditions_as_written`). Lowering each left side onto its hop, resolving it, and
  every refusal happen once per build in `_bind_join_conditions!`, against the final query. A `cjoin`
  link declared after the `on()` that needs it is therefore seen. The result goes into
  `instruct.join_conditions` / `instruct.join_type_overrides`, keyed by the **canonical** path
  (`_canonical_join_path`), and the pass never mutates the query object, so a nested or repeated
  build binds the same way. Never resolve, prefix, or validate at the call: the answer depends on
  calls that have not happened yet.
- **Resolving a condition adds no join.** A left side whose relation part reaches past its hop is
  refused (`_refuse_lhs_past_hop`, #973), not joined. `_assert_condition_added_no_join` is the
  render-time backstop and **raises** when a row appears while an ON clause renders. Never relax it
  into a warning: an unwritten INNER JOIN carrying the predicate in its ON clause is #973 itself.
- **`on(path)` declares its own join.** An `on()` entry nothing else reaches is materialized by
  `build()` (`_join_path_columns`). A ManyToMany path is refused (`_refuse_many_to_many_join_path`)
  until it is supported, rather than silently dropped.
- **`cjoin_on` is bound at build too, and nothing is relocated (#982).** `_bind_cjoin_on_conditions!`
  walks each alias's conditions with `_each_condition_column`, the one leaf visitor, and records three
  facts:
  - every relation path a condition names (`instruct.cjoin_on_paths`), which `build()` joins **before**
    the alias rows;
  - every other alias it names, a dependency edge;
  - whether it names its own alias. If it does not, the join is unconstrained, and
    `_refuse_unconstrained_cjoin_on` refuses it (#448).

  The alias rows are emitted in dependency order (`instruct.cjoin_on_order`, `_cjoin_on_emission_order`:
  Kahn's algorithm, declaration order breaking ties, #449), and a cycle is refused naming only the
  cycle. Each row's ON clause renders once, in place, so a predicate stays in the ON clause the caller
  wrote it in, and SQLite binds in text order by construction (#421).

  The SQL-text relocation is gone: Phase 1b/1c, `OnExtra`, `detach_parameters!`, #435's diagnosis and
  #448's `occursin`. Never bring back a pass that scans rendered SQL for `"alias".` to decide where a
  predicate goes. It moved a LEFT `cjoin_on`'s predicate into a path's INNER join and dropped base rows.
- **Which row each column names is checked where it renders (#985).** `_column_sql` is the one place a
  model column becomes `"alias"."col"`, and `test/unit/test_join_column_recorder.jl` scans the source
  for any site that builds the text itself. While an ON clause renders, `_join_scope` sets
  `RenderScope`'s `join_hop`, `join_side`, `join_left` and `join_right`, and `_record_join_column`
  refuses an alias outside the side's set:
  - for a path join, the left side may name only the hop, and the right side the base row, the path's
    ancestors and the hop;
  - for a `cjoin_on` row, both sides may name every row emitted before it, and itself.

  A comparison marks its column `:left` (`_join_side_change`) and its values `:right` (`_on_join_right`).
  Inside a right side, everything stays right (#975). A comparison nested in a left side splits again.
  **A column on no side (`:none`) is checked against the narrow left set (#993):** the marks are opt-in
  at each comparison site and nothing scans for them, so the default is what makes a forgotten mark
  fail. With the left set, a forgotten `:left` is a loud refusal instead of #961's silent wrong row,
  and only an explicit `_on_join_right` widens the set. Never flip the default back to the right
  set. When you add a comparison arm, mark both sides, and give it a mutation proof in
  `test/unit/test_join_column_recorder.jl`.
  A memoized column is rendered afresh inside an ON clause, so it passes the check. The walkers
  (`_prefix_join_column`, `_refuse_lhs_past_hop`, the `_off_path_*` family) stay on purpose: they
  refuse at binding, with the spelling the caller wrote. The recorder is the net under them, so a
  gap in a walker becomes a loud refusal instead of a wrong row.
- **A path a `cjoin_on` condition names is to-one, or it is refused (#992).**
  `_refuse_to_many_cjoin_on_path` walks it with `_relation_step` at binding. The first hop that is not
  `:forward` raises, and the message points to `Exists(… OuterRef …)`. That covers a reverse or
  ManyToMany hop, and a reverse OneToOne, which can drop the base row when there is no match. Built
  first onto the base row, such a hop repeats the base row once per related row, and no ON placement
  undoes it.
- **Known gaps** (open issues; new work in this area goes there, not into a standalone fix,
  [`pormg-issue-management`](../pormg-issue-management/SKILL.md) → *Design (umbrella) issues*):
  - Conditions are lowered to canonical base-rooted path strings, not typed column references (I1, #990).
    Since #993 a gap in that lowering is a loud refusal, not a wrong row, so I1 now buys message
    quality and fewer walker arms, not correctness.
  - **Cardinality is not one invariant yet (#1002).** Reference is settled. "Does this join repeat a
    base row?" is answered by six local guards: #74, #973, the M2M `on()` refusal, #992, open #174,
    and none for a `cjoin(field = …)` link to a non-unique column, which `_relation_step` classifies
    `:forward`. Do not add a seventh local guard for a to-many shape: put the case in #1002, which
    also holds the open decision on `filter()` / `order_by` across a to-many path (Django-shaped
    repeats, refuse, or rewrite to `EXISTS`).

Coverage: `test/unit/test_join_condition_matrix.jl` records the SQL of every path × condition shape
as data, in `test/unit/fixtures/join_condition_matrix_expected.jl`. A behavior change shows up as a
fixture diff. Regenerate it with `PORMG_JCM_RECORD=1` (the command is in the test file's header) and
review the diff row by row, because regenerating to make the test pass is exactly the anti-pattern
below.

Gotcha — `_count` (`execution_read.jl`): it clears `.values`/`.order` before rendering, so `count()` cannot reuse a `.values()` select. `COUNT(DISTINCT *)` is **invalid SQL on both PostgreSQL and SQLite**, so the count forms diverge:

- `count()` → `COUNT(*)`.
- query-level distinct (`.distinct().count()` / `count(distinct=true)`) → wrap `SELECT DISTINCT *` in an **outer `COUNT(*)` subquery** (so `count() == length(distinct list())`).
- `count("col", distinct=true)` → flat, valid `COUNT(DISTINCT col)` by reusing the `Count()` aggregate (single column is legal; `*` is not).

When changing count rendering, verify both dialects execute (not just that the SQL string looks right) — the bug this guards against was a syntax error that only surfaced at execution.

### Inspection tools

**Reproduce with the smallest query that fails, then read its built state before editing code.** A
parameter or clause bug is visible in the builder's own metadata; reasoning about it from the source
is how the wrong module gets changed.

Useful internal tools:

- `show_query=:sql` on terminal methods (returns just the query string)
- `show_query=:dict` on terminal methods (returns comprehensive metadata; e.g. `query.delete(show_query=:dict)`)
- `inspect_query(q)` (used internally before execution; prefer `show_query` in integration/public API testing)
- direct builder inspection when debugging parameter state

### Maintenance checklist

When introducing a new parameterized SQL clause or changing clause order, update all of the following together:

- bucket struct fields in `parameters.jl`
- `with_bucket` scopes in builder modules (and, for a new statement entry point, its `set_context!` plus
  its entry in `test/unit/test_render_scope.jl`'s allowlist)
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

## Verification Commands

Narrowest first. The three integration files are **slices**, and a slice runs without asking — the
suite lock in `common_setup.jl` queues it behind any other `db_2` run. Query-rendering diffs are covered by unit
coverage plus the naming slice; do **not** escalate to `test/integration/runtests.jl` unless the
diff is in the rung-5 table in [`pormg-issue-workflow`](../pormg-issue-workflow/SKILL.md) →
*Verify*, which is also the run that needs the user's permission first. The full suite on both
engines is a release gate, not a per-issue step.

```powershell
julia --project=test/integration test/unit/test_alignment_sqlite.jl       # no permission needed
julia --project=test/integration test/unit/test_inspect_query.jl          # no permission needed
julia -t auto --project=test/integration test/integration/test_having.jl  # rung 4 slice — no ask
julia -t auto --project=test/integration test/integration/test_cjoin.jl   # rung 4 slice — no ask
julia -t auto --project=test/integration test/integration/test_cte.jl     # rung 4 slice — no ask
```

## Anti-Patterns

- Do not duplicate the full parameter bucket matrix in integration tests
- Do not fix SQL shape bugs only by changing test expectations without validating semantics
- Do not resolve, prefix, or validate a join condition at the `.on()` / `.cjoin()` / `.cjoin_on()` call, and do not write a second relation walk next to `_relation_step`. Conditions are stored as written and bound once per build (#977, #982)
- Do not build `"alias"."col"` outside `_column_sql`, and do not decide where a join predicate goes by scanning rendered SQL (#982, #985)
- Do not bypass public API regressions when the failure is visible to package users
- Do not mix unrelated SQL formatting changes into a targeted regression fix
- Do not revert to silent identifier stripping (e.g. `replace(id, r"[^a-zA-Z0-9_]" => "")`) — an alias is fail-closed (`quote_identifier`), a physical table or column is escape-only (`safe_table_identifier` / `safe_column_identifier`), and neither ever silently rewrites an identifier
- Do not route a physical table or column through `quote_identifier`, or an alias through `safe_*_identifier` — the partition above **is** the contract, and collapsing it re-opens #394
- Do not embed raw ANSI (`\e[...`) in a `throw`/`error`/`@info`/`@warn`/`@error`/`print` message — throw a taxonomy subtype (its constructor applies `_emsg`) or wrap with `_emsg` / `_emsg(io, …)` inside `show` methods, so color degrades off-TTY
- Do not reintroduce a funnel that only maps a message to a type (the deleted `_argerr`); name the subtype at the call site
