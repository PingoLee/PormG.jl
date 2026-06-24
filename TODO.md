# TODO List

This document tracks missing features and planned improvements for PormG.jl, with a focus on reaching parity with Django-style ORM capabilities and leveraging PostgreSQL-specific power features.

## 🚀 High Priority: Core ORM Parity

- [x] **Make bulk DataFrame→field matching case-sensitive (abandon case-insensitive matching)** — All three matching spots in `src/querybuilder/execution_bulk.jl` now match **exactly (case-sensitive)** and **fail loudly** when a name differs only in case, via shared helpers `_case_fold_candidates` + `_bulk_case_mismatch_msg` (the error names the candidate and suggests `rename!(df, lowercase.(names(df)))` or an explicit `"DF_COL" => "field"` mapping):
  - `_prepare_bulk_df!` auto-detect (`columns=nothing`): a DataFrame column differing only in case from a model field raises instead of folding/overwriting.
  - `_prepare_bulk_df!` explicit-`columns=` string fallback: a case-only mismatch raises; a truly-absent name still passes through as an auto-populated field.
  - `_prepare_bulk_df!` explicit-`columns=` **Pair** (`"df_col" => "field"`): a missing source column now **throws** (previously `@error`-logged and bound a bad mapping that crashed downstream), with the same case hint when the near-miss differs only in case.
  - `_resolve_match_column!` (`match_on=`): reordered to exact → reuse an explicit `columns=` mapping (`allow_reuse`) → case-mismatch error → not-found. An explicit `columns=` mapping still wins over a case error.
  - **Migration applied**: the F1 test DB setup (`test_database_setup.jl`) and the docs F1 load examples (`docs/src/write/bulk.md`) now `rename!(df, lowercase.(names(df)))` for the camelCase `circuits`/`drivers`/`constructors` CSVs. Docs (`bulk.md`, `api.md`) updated to state case-sensitive matching plus the symmetric missing-`columns=`-column error.
  - **Test coverage**: unit (`test/unit/test_bulk_update_column_scope.jl`) flips the old case-insensitive test and adds Site A/B/C, the explicit-Pair path, and allow_reuse-precedence cases. Integration tests that asserted the old fold were rewritten: in `test/integration/test_updates.jl`, one to the exact-column PK-fallback path, one into a case-sensitivity **migration** test (upper-case raises + DB untouched, then `rename!` succeeds), and the "Auto-lowercase mapping" Adaptor test flipped to assert auto-detect now rejects a case-only mismatch; in `test/integration/test_internals.jl`, the show_query bulk_insert load of `constructors.csv` now `rename!`s the camelCase headers. Verified against PostgreSQL (`db_2`): the F1 seed loads (91/91 "Inserts and Schema") and the migration + PK-fallback rewrites pass; the two follow-up fixes match the exact errors that same run surfaced (one reuses the seed's proven `rename!`, one asserts the observed case error). The only non-code failure was an environmental remote-DB connection timeout in the Phase-0 temp-DB migration test, unrelated to this change.

- [/] **Advanced Query Expressions**
  - [x] Support for **Subqueries** (using `OuterRef`). — Correlated `Exists(subquery)`, `OuterRef("field")`, and `__@in` subquery membership tests are fully implemented and tested. Gaps: no scalar subqueries, no UNION/set operations.
  - [x] **Window Functions** (`OVER`, `RANK`, `ROW_NUMBER`). — Implemented inline `OVER` support with `WindowOver`, `Rank`, `DenseRank`, `RowNumber`, `Lag`, `Lead`, `FirstValue`, `LastValue`, and `NthValue`. Remaining gaps: aggregate-over-window helpers, named `WINDOW` clauses, and SQLite explicit frame support.
  - [x] **Conditional Expressions** (`Case`, `When`). — Fully implemented. Works in `values()`, `filter()`, and `update()` SET clauses; nests correctly inside aggregates like `Sum(Case([...]))`.
  - [/] **F-Expression** expansion.
    - [x] Arithmetic (`+`, `-`, `*`, `/`) and comparison operators (`==`, `>`, `<=`, etc.) — fully implemented, including field-to-field arithmetic and chaining.
    - [x] **Bitwise operations** (`&`, `|`, `⊻`/`xor`, `<<`, `>>`) — fully implemented and verified on SQLite & PostgreSQL.
    - [x] **Date/Time extraction**: `Extract()`, `@date`, `@year`, `@month`, `@day`, `@quarter` lookups — implemented and dialect-aware.
    - [/] **Date arithmetic with duration types**: Integer-offset `F("date") + 30` works. Explicit Julia duration types like `Day(30)` / `Interval()` are not recognized — arithmetic relies on bare integers interpreted as days by the dialect.
    - [ ] **Extend test coverage** for date/time functions to ensure cross-database compatibility and correct SQL generation.


- [x] **Refactor QueryBuilder Parameter Handling (Contextual Buckets Strategy)**
  - **Context:** Currently, the query builder generates PostgreSQL parameters (`$1`, `$2`...) sequentially. MySQL/MariaDB and SQLite use positional parameters (`?`), which require a "Bucket" strategy because code execution order (e.g., Processing `WHERE` before `JOIN` to determine needs) doesn't match SQL string order.
  - **Goal:** Implement this in [src/querybuilder/parameters.jl](src/querybuilder/parameters.jl) using Multiple Dispatch.
  - **Implementation Details:**
    1. **Abstract Base Type**: `AbstractPormGParam`.
    2. **PostgreSQL**: `PormGPostgresParam <: AbstractPormGParam` (concrete `PgParameterizedQuery`; single vector/counter).
    3. **Positional (SQLite)**: `PormGSQLiteParam <: AbstractPormGParam` (concrete `SQLiteParameterizedQuery`) with distinct buckets for `cte_params`, `select_params`, `update_params`, `join_params`, `where_params`, `having_params`. *(`update_params` added beyond the original plan for UPDATE `SET` clauses. MySQL/MariaDB would reuse this positional strategy when a backend is added.)*
    4. **Context Control**: `set_context!(params, context::Symbol)` to direct parameters to the correct bucket.
    5. **Finalization**: `get_final_parameters` returns `vcat` of buckets in standard SQL order.
    - [x] **show_query**: Update to support new parameter structure and ensure correct SQL string generation for each dialect. Finishing the concept of Symbol-based `show_query` modes for flexible inspection.
    - [x] **Testing & Alignment Verification**:
      - [x] **Positional Cross-Check**: Create tests that count the number of `?` in each SQL block (SELECT, JOIN, WHERE) and compare them against the length of the corresponding parameter bucket.
      - [x] **Execution Order Stress Test**: Specifically test queries where JOINs are calculated dynamically based on filters to ensure parameter positions don't drift.
      - [x] **Subquery Isolation**: Verify that nested subqueries correctly restore the parent's `current_context` after execution.
      - [x] **Unit Tests**: Storage-layer tests (buckets/ordering) live in `test/unit/test_parameters.jl`; the `inspect_query` + mocked-connection (`MockSQLite`) alignment tests live in `test/unit/test_alignment_sqlite.jl`. Both are wired into `test/runtests.jl` (388 assertions across the two files, green).

- [ ] **Full Transaction Control**
  - [ ] **Savepoints**: Support for nested transactions/atomic blocks.
  - [ ] **Row-Level Locking**: `select_for_update()` with `SKIP LOCKED` and `OF` support.

- [x] **Query Inspection & Developer Tooling**
  - [x] **Intent Detection**: Improve the `:operation` heuristic in `inspect_query` to distinguish between `:select` and `:delete` without explicit overrides.
  - [ ] **Finalize `show_query` with `:inspection` mode**: Ensure it returns a comprehensive metadata dictionary with consistent keys across all operations (select, insert, update, delete) for use in debugging and potential future tooling (e.g., query logging middleware).
  - [ ] **Metadata Enrichment**: Include additional context in the inspection dict, such as estimated execution time (using EXPLAIN), potential indexes used, and warnings about missing indexes or inefficient queries.
  - [ ] **SQL Formatting**: Add a `:pretty` mode to `show_query` to return formatted/indented SQL for better readability in logs.
  - [ ] **Explain Support**: Add an `explain_query()` API to return the database's `EXPLAIN (ANALYZE, BUFFERS)` output directly as metadata.


## 🐘 PostgreSQL Specific Enhancements

- [ ] **JSONB Support**
  - [x] Implement `JSONField`.
  - [ ] Support for JSON lookups (`data__key`, `data__0__key`).
  - [ ] JSON containment and overlap operators (`@>`, `?`, `?|`, `?&`).

- [ ] **Specialized Data Types**
  - [x] `UUIDField` (using native `uuid` type).
  - [ ] `ArrayField` (PostgreSQL native arrays).
  - [x] `IntervalField` (PostgreSQL `interval`). — implemented as `DurationField` (renders to `INTERVAL`).
  - [ ] `INET`/`CIDR` Fields for network addresses.

- [ ] **Advanced Indexing**
  - [ ] Support for `GIN`, `GIST`, and `BRIN` indexes in migrations.
  - [ ] Functional indexes (indexing the result of a function).
  - [ ] Partial indexes (indexing a subset of rows via `WHERE`).

- [ ] **Performance Bulk Operations**
  - [x] **COPY command**: Implement high-speed bulk inserts using PostgreSQL's `COPY` protocol.
  - [x] **Dataframes Type Normalization**: Create integration tests for bulk operation type normalization in `execution_bulk.jl`.
    - Validate edge cases for `bulk_insert`, `bulk_update`, and `bulk_copy`:
      - Float to Integer coercion (e.g., `14.0` in `Vector{Float64}` to `Int64`).
      - Mixed types in column (Strings that are numeric).
      - Null/Missing handling in required vs optional fields.
      - Foreign key violation reporting in bulk contexts.
      - Duplicate key handling.
  - [ ] **Upsert (`ON CONFLICT`)**: Support for `update_or_create` using `INSERT ... ON CONFLICT DO UPDATE`.

- [ ] **Full-Text Search (FTS)**
  - [ ] Integration with `tsvector` and `tsquery`.
  - [ ] ORM lookups for `search`, `rank`, and `headline`.

## 🛠 Project Infrastructure & Quality

> ⚠️ **Pre-publish window** — the items marked *do BEFORE the first General-registry publish* lock in contracts that are cheap to settle now (zero published users) but become breaking/irreversible afterward. Tier 1 (migration format, schema conventions) touches **user data / live databases** — a version bump cannot fix an already-migrated production DB. Tier 2 (loading contract, export surface) is code-fixable in a 0.x bump but breaks every user's `using` at once. The adapter decoupling and export curation are coupled — do them together.
>
> **Sequence (do in this order):** (1) freeze the migration file + tracking-table contract → (2) freeze the generated DB schema conventions → (3) decouple SQL adapters into weakdeps + extensions → (4) curate the public export surface. Items 1–2 are **Tier 1** (irreversible user-data — settle first); items 3–4 are the coupled **Tier 2** pair shipped together, with adapter-decoupling first because export-curation depends on it (a core-exported `libpq_execute` cannot survive `LibPQ` moving to an extension). The two unmarked items below (PG migration fixture, PG pool exhaustion) are not publish-gating and follow afterward.

- [ ] **Freeze & document the migration file + tracking-table contract** ⚠️ *do BEFORE the first General-registry publish* — **Tier 1 (user data, irreversible)**
  - **Why now**: Once a user generates migration files with 0.1.0, commits them, and applies them to a production DB (recorded in the migrations bookkeeping table), that history is frozen **on disk and in their database**. If a later release changes the migration file structure, the checksum/`compute_checksum` scheme, or the tracking-table schema, the existing applied history breaks — and no version pin can repair an already-migrated prod DB.
  - **Goal (decide & lock, not necessarily rewrite)**: Pin and document, as a stability contract: (1) the on-disk migration file format/layout, (2) the checksum algorithm (`compute_checksum`), (3) the migrations tracking-table name + columns, (4) the recorded state representation. Add a documented format/version marker so future changes can be migrated forward instead of silently breaking.
  - **Deliverable**: a "Migration format stability" section in the docs + a format-version field; a test that reads a committed 0.1.0-era migration fixture and asserts it still applies/validates.

- [ ] **Freeze & document the generated DB schema conventions** ⚠️ *do BEFORE the first General-registry publish* — **Tier 1 (user data, irreversible)**
  - **Why now**: The moment a user runs `migrate`, these naming choices are **physically in their database**. Changing them later means the ORM no longer matches the user's existing schema, with no version-pin escape.
  - **Conventions to pin & document**: table pluralization (Inflector), FK column spelling (README/examples use `driverid`, not `driver_id` — confirm this is the intended, final convention), implicit PK / `id` field, auto timestamp/`created`/`modified` fields, default `on_delete`, identifier quoting/case rules.
  - **Goal**: settle each convention now and document it as stable; where a convention is genuinely undecided, decide it before publish rather than after. (Django froze these on day one and never moved them.)

- [ ] **Decouple SQL adapters into weakdeps + extensions** ⚠️ *do BEFORE the first General-registry publish* — **Tier 2 (loading contract); coupled with export curation — do BEFORE it**
  - **Why now**: Moving `LibPQ`/`SQLite` from `[deps]` to `[weakdeps]` changes the user-facing loading contract (`using PormG` → `using PormG, LibPQ`). With zero published users the migration cost is zero; after the first release it becomes a breaking change forced on every adopter. The 0.1.0 publish window is the right (and cheapest) time.
  - **Chosen model**: Weakdeps + extensions in this repo (single package). `LibPQ` and `SQLite` become `[weakdeps]`; driver code moves into `ext/PormGLibPQExt.jl` and `ext/PormGSQLiteExt.jl` (machinery already exists — see `PormGReviseExt`, `PormGTachikomaExt`). User opts in with `using PormG, LibPQ` / `using PormG, SQLite`. (Rejected: separate backend packages, asymmetric SQLite-bundled.)
  - **Key insight — the real driver surface is small**: Of the ~27 files referencing `SQLite`, most are **SQL-string generation (dialect)** that never touch the driver package and can stay in core. The code that genuinely needs the driver package is concentrated in ~4 places: `src/ConnectionPool.jl`, `src/querybuilder/execution*.jl`, and the one version probe `SQLite.C.sqlite3_libversion_number()` in `src/Dialect.jl`. Split "dialect" (pure SQL, stays in core) from "driver" (open/execute/release, moves to extension).
  - **Hard blocker to clear first — core structs name concrete driver types**: extensions can add methods to core generics but core cannot reference names defined in an extension. These must stop naming `LibPQ.Connection` / `SQLite.DB`:
    - `PostgresConnectionPool.connections::Vector{Union{Nothing, LibPQ.Connection}}` ([ConnectionPool.jl:88-89](src/ConnectionPool.jl#L88-L89))
    - `SQLiteConnectionPool.connections::Vector{Union{Nothing, SQLite.DB}}` ([ConnectionPool.jl:96-97](src/ConnectionPool.jl#L96-L97))
    - Driver-typed method signatures: `release_connection`, `is_connection_alive`, `reconnect_db`, `libpq_execute`/`sqlite_execute`, `libpq_execute_async`/`sqlite_execute_async`, `_create_sqlite_connection`, `close_pool!` (all in `ConnectionPool.jl`).
  - **Ordered plan**:
    1. Define backend interface as empty generics in core: connection open, `execute`, `execute_async`, `release`, `is_alive`, `reconnect`, plus the SQLite version probe. Keep dispatch keyed on the existing `PormGPostgres`/`PormGSQLite` abstract types.
    2. Erase concrete driver types from core: make the pool generic (`Pool{C}`) or store connections behind an abstract `AbstractDBConnection` wrapper so core never writes `SQLite.DB` / `LibPQ.Connection`.
    3. Move all `LibPQ.*` / `SQLite.*` method bodies into `ext/PormGLibPQExt.jl` / `ext/PormGSQLiteExt.jl`; add the two `[extensions]` entries and move both packages to `[weakdeps]` in `Project.toml`.
    4. Keep dialect/SQL-string code in core untouched (no driver dependency there).
    5. Update docs + README install/quick-start to show `using PormG, LibPQ` (and SQLite equivalent); document the backend interface as the official path for a future 3rd backend (MySQL/DuckDB).
    6. Add a CI job (or test) that loads PormG **without** each driver to prove core has no hard driver reference, and one per backend that loads the driver and runs the existing suite.

- [ ] **Curate the public export surface** ⚠️ *do BEFORE the first General-registry publish* — **Tier 2 (breaks every user's `using` at once); coupled with adapter decoupling — do AFTER it**
  - **Why now**: Un-exporting a name after publish breaks all `using PormG`-based user code. The current surface was never curated — decide the public/internal boundary before anyone depends on it.
  - **Problems in the current surface**:
    - **Collision-prone generic names** dumped into `Main`: `Sum, Avg, Count, Max, Min, F, Q, Value, Case, When, Rank, Extract, Lag, Lead, Round, Floor, Ceil, Sqrt, Exp, Ln, Mod, Abs, Length, Power, Replace, Trim, With, OP`. Consider namespacing (`PormG.Sum`) or a submodule (`using PormG.Functions`) instead of flooding the user namespace.
    - **`fetch` is exported but does not extend `Base.fetch`** (only `first, get` are imported from Base at [src/QueryBuilder.jl:17](src/QueryBuilder.jl#L17)) — so `using PormG` shadows `Base.fetch` and forces qualification. Audit every export that collides with Base; either `import Base: x` to extend, or rename/un-export.
    - **Driver internals are exported**: `libpq_execute`, `libpq_execute_async`, `is_connection_alive`, `reconnect_db`. This is incoherent with the adapter-decoupling item — a core-exported `libpq_execute` cannot survive `LibPQ` moving to an extension. **Curate exports and decouple adapters in the same pass.**
    - **Duplicate exports** to clean up: `close_pool!`, `with_advisory_lock`, `with_savepoint`, `fetch_async`/`await_result`/`FetchTask` are each exported more than once.
  - **Goal**: produce an explicit, documented list of public symbols; move everything else to internal (unexported). Add an Aqua/test check that the public export list matches the documented API.
  - **Related**: settle the `list()` default return shape (`Vector{PormGRow}`) as a documented contract — see *Strongly Typed Model Returns* under Performance & Type Stability.

- [ ] **Isolated PostgreSQL migration fixture (`db_test_migration_pg/`)**
  - **Context**: The migration edge-case suite in `test/integration/test_migration_bootstrap.jl` (Phase C) needs a throwaway database. When `test/integration/db_test_migration_pg/connection.yml` is absent, it falls back to hydrating from the *selected* integration DB and runs `_reset_postgres!`, which **drops every table in `public`** ([test_migration_bootstrap.jl:180](test/integration/test_migration_bootstrap.jl#L180)). Running the Postgres edge-case suite against the shared `db_2` (`pormg_teste`) would therefore wipe it.
  - **Goal**: Commit a `db_test_migration_pg/connection.yml` pointing at a dedicated, disposable PostgreSQL database (separate from `db_2`) so the full Postgres edge-case suite — including the `PositiveSmallIntegerField` CHECK lifecycle (Phase 8a2) — runs in isolation without risking the shared integration DB.
  - **Status**: The CHECK lifecycle is already verified — through the real `makemigrations`/`migrate` engine on SQLite (Phase 8a2 passes), and via the live `get_constraints_check` / `alter_field` introspection paths on PostgreSQL. This item only tracks wiring the isolated fixture so Phase 8a2 also runs end-to-end on Postgres in CI.


- [ ] **Investigate PG pool exhaustion under remote-latency integration runs**
  - **Symptom**: Running `test/integration/runtests.jl` against the remote `db_2` (`pormg_teste` @ 187.121.224.221) logs `PG pool expanded beyond initial size (current_size=15, initial_size=3)` followed by repeated `No available PG connections, retrying (N/300)`.
  - **Root cause (current understanding)**: The `dev` section of [test/integration/db_2/connection.yml](test/integration/db_2/connection.yml) sets no `pool_size`, so it defaults to **3** ([Configuration.jl:221](src/Configuration.jl#L221)); the hard expansion cap is `pool_size * 5` = **15** ([ConnectionPool.jl:244](src/ConnectionPool.jl#L244)). The async-first suite saturates the small pool against a high-latency remote DB and parks callers in the 100ms retry loop. All release paths (`await_result`/`run_in_transaction` `finally`, `fetch_async` error path) appear correct — this looks like sizing/contention, not a leak.
  - **To verify**: Confirm whether the suite ever reaches `300/300` and throws (genuine starvation) vs. recovering after a few retries (transient backpressure). If it only recovers, the warnings are cosmetic; if it throws/hangs, sizing is mandatory.
  - **Likely fix**: a larger initial pool so it never expands. ⚠️ **Not via `db_2/connection.yml`** — `*connection.yml` is git-ignored (`.gitignore:3`), so a `pool_size:` there only fixes the local machine and a fresh checkout reverts to default 3. A durable fix must be committed: set the test pool size in `test/integration/common_setup.jl` (after `Configuration.load`) or raise the in-code default, and/or root-cause the contention/leak. Consider lowering the `@warn`/retry noise or making expansion silent up to the cap.
  - **Also audit**: whether any code path calls `fetch_async` without an `await_result` (would leak a connection), and whether `bulk_*`/`inspect_query`/COPY paths always release.

## 🏗 Phase 2: Operational Maturity

- [ ] **Advanced Migration Support**
  - [ ] **Rename Operations**: Better detection and handling of renamed models/fields.
  - [ ] **Non-Interactive Renames**: Allow explicit rename hints or declarative rename operations so CI does not depend on prompts.
  - [ ] **Targeted Execution**: Support `migrate_to(version)` / `up(version)` instead of only applying the latest pending diff.
  - [ ] **Rollback / Reversible Migrations**: Support `rollback()`, `down`, `last_down`, and rollback-to-version flows for operational recovery.
  - [ ] **Deployment Safety**: Define startup-safe locking and clear failure semantics for multi-instance deploys.
  - [ ] **Data Migration Support**: Support manual SQL or Julia functions in migrations for complex transformations (e.g., splitting columns).
  - [ ] **Schema Object Coverage**: Add first-class migration support for views, triggers, composite constraints/indexes, and other non-table schema objects.

- [ ] **SQLite Parity**: Carry over PostgreSQL improvements to the SQLite adapter where possible.
- [ ] **Documentation Expansion**:
  - [ ] Expand the Formula 1 dataset examples in the docs.
  - [ ] Add a "PostgreSQL Power User" guide.

- [ ] **Performance & Type Stability**
  - **Context**: `list()` now returns `Vector{PormGRow}` by default, while `list(:dict)` preserves the dynamic dictionary path for integrations that require real `Dict` values. Fully concrete application structs would still be faster for high-throughput Nitro.jl applications.
  - **Goal**: Allow queries to return concrete Julia `struct` types instead of dynamically typed Dictionaries.
  - [ ] **Strongly Typed Model Returns (Nitro compatibility)**: Implement `list_as(query, MyModel)` or similar to map DB results directly to typed structs.
  - [ ] **Fast JSON Serialization**: Optimize serialization path (e.g., via `JSON3.jl`) to leverage type-stable structs for lightning-fast JSON output.
  - [ ] **Review `OperObject.values` Type Design**: Evaluate whether the large Union in `OperObject.values` should stay as-is, be grouped behind type aliases, or move to a parametric/tagged representation. Only pursue a runtime change if profiling shows it is a real bottleneck.
  - [ ] **Allocation Reduction with IO Strategy**:
    - **Context**: String concatenation (`*=` and interpolation) in the query builder triggers significant GC overhead.
    - [ ] Expand the `IOBuffer` approach used in `query()` to `insert()`, `update()`, `delete()`, `do_count()`, and `do_exists()`.
    - [ ] Refactor internal helper functions (`_query_select`, `build_cte_clause`, etc.) to optionally take an `IO` object.
  - [ ] **Performance Benchmarking**: Establish a baseline for query generation and execution overhead.
  - [ ] **Thread Safety**: Audit connection pool for concurrent `Async` safety.

## 🔍 Review possible issues

Issues identified during the code review of recent main changes

- [ ] **`Base.getproperty(q::ObjectHandler)` — accumulated issues** (`src/querybuilder/object_manager.jl`)
  Several unrelated problems were noticed while working on the `list(format)` / `PormGRow` feature. None are blockers today but should be addressed before a public release.

  - [ ] **`:inspect_query` alias** — `sym === :inspect_query || sym === :inspect` has the same problem as `:all` had for `:list`: two names for one terminal, only the shorter `:inspect` should survive. The alias won't forward new positional args if `:inspect` ever gains them.

  - [ ] **`:count` and `:exists` silently ignore `show_query`** — both are bound as `return () -> do_count(q)` with no kwargs. There is no way to inspect the generated SQL. Should become `return (; show_query=:execute) -> do_count(q; show_query=show_query)` (and same for `:exists`).

  - [ ] **`args...` is widespread and type-unstable** — `:with`, `:cjoin`, `:on`, `:create`, `:update` all use `(args...; kwargs...)`. The compiler cannot infer return types for these closures. For chainable methods this is tolerable (return type is always `ObjectHandler`), but for `:create` and `:update` the return type is unknown. Consider typed signatures where the argument shape is fixed.

  - [ ] **Category 2/3 comment is mis-indented** — the `# === CATEGORY 2: Terminal methods ===` comment sits inside the `elseif sym === :copy` block due to indentation, making the structure misleading when reading the file. Cosmetic but confusing.

- [ ] **Centralize ANSI color in error/log messages behind a TTY check**
  - **Context**: Error and log strings hardcode raw ANSI escape codes (`\e[4m\e[31m…\e[0m`) to emphasize values — ~28 occurrences across 9 files (`src/querybuilder/execution_bulk.jl`, `execution.jl`, `deletion.jl`, `ctes.jl`, `many_to_many.jl`, `build_*.jl`, `migrations/planner.jl`). There is no TTY guard anywhere, so the codes are emitted unconditionally.
  - **Problem**: The codes only render as color on a real terminal. In any non-TTY sink — log files, CI logs, the IDE output panel, `sprint(showerror, e)`, serialized error reports — they appear as literal garbage (`^[[4m^[[31mpoints^[[0m`). Thrown `ArgumentError`/`ErrorException` messages are the worst offenders, since `showerror` re-displays them in many non-TTY contexts (test-failure dumps, captured strings).
  - **Goal**: Add one helper (e.g. `emph(x; color=:red, underline=true)`) that colors only when `get(stderr, :color, false)` is true and returns plain text otherwise; route all call sites through it. Honors Julia's `--color` flag and `NO_COLOR`.
  - **Scope**: prioritize the exception call sites over `@warn`/`@error` logs. Add a regression test asserting no `\e[` leaks into a message when color is disabled.

- [ ] **`deepcopy(ctes)` → `copy(ctes)` shared-state risk**
  - **Location**: `src/querybuilder/types.jl`, `Base.deepcopy(::SQLObjectQuery)`.
  - **Issue**: Two query objects created via `deepcopy(query)` now share CTE sub-query internal state (filters, values). Mutating a CTE after the copy affects both queries.
  - **Fix**: Document the limitation, or implement a custom deep-copy that clones CTE dict values without traversing Module references.

- [ ] **Think in this aproach** With new aproach:
   # Main query joining CTE
    q = M.Result.objects.with("r91" => races_91).filter(
        "raceid" => F("r91__raceid"),
        "positionorder" => 1
    )


- [/] **SQLite `INSERT ... RETURNING *` hang + worker/pool stability** (`src/querybuilder/execution.jl`, `src/ConnectionPool.jl`)
  Surfaced running the SQLite integration suite (`PORMG_DB=db_sl julia -t 1 --project=. test/integration/runtests.jl`) on Windows + SQLite.jl 3.51.
  - [x] **`create()` RETURNING hang** — `INSERT ... RETURNING *` spun indefinitely inside libsqlite3 for tables whose AUTOINCREMENT primary key migrations left in a non-first column position (e.g. `django_contract_scratch`, pk `id` at column 3). The old broad `catch` masked it by re-running a plain INSERT, which then tripped a spurious UNIQUE violation because the first INSERT had already written the row. **Fixed** (branch `fix/sqlite-insert-returning-hang`): plain INSERT + `SELECT * WHERE rowid = last_insert_rowid()` read-back on the same connection (pinned via `run_in_transaction`); broad catch removed; the returned Dict still carries all columns (matches the Postgres `RETURNING *` contract, incl. unset nullables).
  - [ ] **Native segfault in the SQLite async worker** — intermittent `EXCEPTION_ACCESS_VIOLATION` in `sqlite3_bind_int64` during F1 fixture seeding (`test_database_setup.jl`); nondeterministic (GC-timed, did not recur on re-run). Suspect: the single global `Threads.@spawn` worker + GC finalizers racing on `SQLite.Stmt`/`SQLite.DB` objects.
  - [x] **SQLite connection-pool timeout in transactions** — "Timeout after 30s waiting for available SQLite connection" in `test_transactions.jl`. **Root-caused & fixed 2026-06-24** (branch `feat/bulk-case-sensitive-matching`). It was **not** a pool leak or accounting bug (the pool returns to `in_use=0` after every other testset — verified by instrumenting `available[]` across the whole suite). It was a **writer-serialization deadlock**: the trigger is the *"Multithreaded inserts"* subtest (5 concurrent `create()` calls, no explicit tx). Each `create()` wraps its INSERT in `run_in_transaction` → `BEGIN IMMEDIATE`. SQLite allows one writer per file, and every statement funnels through the **single global async worker** ([ConnectionPool.jl](src/ConnectionPool.jl) `_ensure_sqlite_async_worker!`). A *losing* `BEGIN IMMEDIATE` blocks **inside libsqlite3** for `busy_timeout=30000ms` (a native call) — while it blocks, the worker can't run the *winning* tx's INSERT/COMMIT, so the winner never releases the lock → deadlock until 30s elapse. Under `-t 1` the native call also freezes every Julia task, so `acquire_connection`'s 30s timer expires → the timeout. This is why **a bigger pool never helped** (it's writer serialization, not slot contention) and why PostgreSQL is immune (real MVCC). **Fix:** a per-pool `write_lock` on `SQLiteConnectionPool` held for the whole `BEGIN..COMMIT/ROLLBACK` via `ConnectionPool.with_sqlite_write_lock` (no-op on PG), applied in `run_in_transaction` (covers `create`/`update`/`bulk_*`/`save`/m2m), in the `delete()` manual-transaction path ([deletion.jl](src/querybuilder/deletion.jl)), and in the SQLite migration lifecycle ([runner.jl](src/migrations/runner.jl) `_execute_migration_lifecycle`). Now only one `BEGIN IMMEDIATE` is ever outstanding across *every* SQLite write path; reads (WAL) are unaffected. **Verified:** full SQLite suite **1380/1380 pass** (was stopping dead at Transactions); `test_transactions.jl` 37/37 incl. a new regression testset *"Concurrent writers exceed pool size without deadlock"* (8 writers + a concurrent delete vs. default pool 3). No `pool_size` override needed — the committed default 3 works.
  - **Note**: PostgreSQL (`db_2`) is the validated integration path (re-run 2026-06-23: **1355/1356 pass**; the lone error is `Migration Engine Edge Cases (PostgreSQL temp DB)`, whose `_reset_postgres!` needs fresh connections and errored during a transient remote-host TCP timeout — `Connection timed out (10060)` to `187.121.224.221` — a network/infra blip, not a code bug; the same run's bulk case-sensitivity testsets all passed: Inserts 91/91, Updates 201/201, Internals 63/63, Bulk copy 55/55). Treat the two open SQLite items as a worker/pool-stability effort (async-worker/pool redesign or a SQLite.jl bump), not a quick patch.

## 🔗 Custom Join (`cjoin`) Gaps

Features needed to express complex join patterns (e.g., self-joins with multi-OR ON clauses, field-to-field comparisons, SQL functions in ON) without falling back to raw SQL.

### Motivation: Target Raw SQL
The following self-join query is currently impossible to represent natively in PormG due to the complex `OR` logic, cross-table comparisons, and string/date formatting functions directly in the `ON` clause:

```sql
SELECT
    b1."index" as id1,
    b2."index" as id2,
    b1.nome as nome1,
    b2.nome as nome2,
    b1.nome_mae as nm_m1,
    b2.nome_mae as nm_m2,
    b1.dn as dn1,
    b2.dn as dn2
FROM b1_proc as b1            
INNER JOIN b2_proc as b2 ON b2.dn = b1.dn OR 
    (b2.sxpn = b1.sxpn AND b2.sxun = b1.sxun AND b2.sxpnm = b1.sxpnm AND NOT b2.sxpnm IS NULL) OR
    (b2.sxpn = b1.sxpn AND b2.sxsn = b1.sxsn AND b2.sexo = b1.sexo) OR
    (b2.sxun = b1.sxun AND strftime('%Y', b2.dn) = strftime('%Y', b1.dn))
WHERE
    b1."index" >= $inicio AND b1."index" <= $fim AND
    NOT b1."index" IS NULL AND NOT b2."index" IS NULL
ORDER BY id1, id2
```

- [ ] **Arbitrary ON clauses in `cjoin`**
  - **Context**: `cjoin` always establishes a single equi-join anchor (`main.field = target.pk_field`) and appends user filters with AND. Queries where the entire ON clause is a custom disjunction (e.g., 4 independent OR branches comparing different column pairs) cannot be expressed.
  - **Goal**: Allow `Qor()` / `Q()` / `F()` expressions to **fully replace** the default equi-join condition, not just append to it. Possibly via a `on_replace=true` flag or a new `cjoin` overload that accepts only filter expressions as the join condition.
  - **Example that should work**:
    ```julia
    # Self-join b1_proc ↔ b2_proc with pure OR logic in ON
    query = M.B1_proc.objects
    query.cjoin("index" => "B2_proc",
        on=[Qor(
            F("b2.dn") == F("b1.dn"),
            Q(F("b2.sxpn") == F("b1.sxpn"), F("b2.sxun") == F("b1.sxun"), ...),
            ...
        )],
        join_type="INNER"
    )
    ```

- [ ] **Cross-table F-expressions in ON clauses**
  - **Context**: `F()` expressions currently work in `filter()` (WHERE) and `values()` (SELECT), but `cjoin` filters do not support `F()` for field-to-field comparisons across both sides of the join (e.g., `F("b2.sxpn") == F("b1.sxpn")`). The filter normalization in `_prefix_join_filter` only handles the joined model's fields.
  - **Goal**: Support `F()` references that resolve to columns on **either** side of the join inside ON-clause predicates. Requires the SQL renderer to alias-qualify both left and right sides correctly.
  - **Touches**: `src/querybuilder/ctes.jl` (`_prefix_join_filter`, `cjoin`), `src/querybuilder/build_joins.jl` (ON clause rendering), `src/Dialect.jl` (alias resolution).

- [ ] **SQL functions in join conditions (e.g., `strftime`, `EXTRACT`)**
  - **Context**: Date transforms like `__@year` exist for WHERE/SELECT, but they are not recognized inside ON clauses. Queries that join on `strftime('%Y', b2.dn) = strftime('%Y', b1.dn)` or `EXTRACT(YEAR FROM ...)` cannot be expressed in `cjoin` filters.
  - **Goal**: Allow date transforms (`__@year`, `__@month`, etc.) and possibly arbitrary SQL functions to work inside `cjoin` filter expressions, generating the correct dialect-aware SQL in the ON clause.
  - **Dialect note**: SQLite uses `strftime('%Y', col)`, PostgreSQL uses `EXTRACT(YEAR FROM col)` — the existing `__@year` transform already handles this divergence in WHERE; the same logic needs to be reachable from ON-clause rendering.

## Future Considerations
- [ ] **Parameterize LIMIT/OFFSET (Future)**
  - **Context**: Currently, `LIMIT` and `OFFSET` are rendered as literal integers in the SQL string. This is safe (Julia enforces `Int` types), but parameterizing them would enable prepared statement caching across different page sizes and improve consistency with the bucket strategy.
  - **Task**: Add a `:limit` bucket to `PormGPositionalParam`, render `LIMIT ?` / `OFFSET ?`, and append values at the tail of `get_final_parameters` (after `:having`).