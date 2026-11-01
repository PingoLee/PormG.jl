# Contributing to PormG

PormG is an async-first Julia ORM, Django-shaped, PostgreSQL-first for production and
SQLite-friendly for local development and tests. This page holds what a contributor needs to find
their way around the source and to verify a change. The debugging guide and the pull-request
workflow are on the [Contributing & Debugging](https://pingolee.github.io/PormG.jl/dev/contributing/)
docs page; writing code that *uses* PormG is covered by the
[`pormg-usage`](.github/skills/pormg-usage/SKILL.md) skill, which `install_ai_skills()` copies into
consuming projects.

## Architecture

**Layering (enforced by include order in `src/PormG.jl`).** `Kernel` is layer 1 and imports nothing
from `PormG`; `Backend.jl` is layer 2 (behavior `PormG` must own — see below); the submodules are
layer 3; `tools.jl` is layer 4. Shared vocabulary — an abstract type, a constant, an exception type —
belongs in `Kernel`, **not** part-way down the chain, or the submodules included before it cannot
name it. That is not hypothetical: the #231 error taxonomy was defined at include step 11, which is
why `Models`/`Configuration`/`Dialect` could not use a single one of its types (#239).

`Backend.jl` stays in `PormG` on purpose. The weakdep extensions define
`PormG.backend_execute(…) = …`, and Julia only accepts a qualified method definition on the module
that *owns* the binding — moving those generics into `Kernel` breaks every extension method, and it
fails at `using LibPQ` / `using SQLite`, not at `using PormG`, so precompiling the package does not
catch it. **Kernel holds the nouns; `PormG` keeps the verbs.**

The table below is also the review **architecture checkpoint**: when a new subsystem file appears
in `src/` **or `ext/`** that is not listed here, add it. `ext/` is in scope deliberately — the
checkpoint was `src/`-only until `ext/PormGReviseExt.jl` sat unlisted while other documents
referenced it.

| Path | Role |
|------|------|
| `src/PormG.jl` | Package root — include chain and the public `export` surface |
| `src/Kernel.jl`, `src/constants.jl`, `src/exceptions.jl` | Layer 1: shared vocabulary — abstract types, constants, `PormGError` root, `_emsg`, `config`. Imports nothing from `PormG`. `exceptions.jl` (included by `Kernel`) holds the error taxonomy (#231, #239), here so every submodule can name it |
| `src/column_ir.jl` | Layer 1 (included from `Kernel`): the canonical column IR's **nouns** — `ColumnSpec`, `ColumnDelta`, `CanonicalType`, `ForeignKeyRef`, `COLUMN_DELTA_SLOTS` and the diff over them. Here rather than beside its compiler because `Dialect.alter_field` renders an ALTER from a `ColumnDelta` (#507 phase 2) and `Dialect` is include step 10 while `Migrations` is step 11 — the #239 shape exactly. **Kernel holds the nouns; the submodules keep the verbs**, so the compiler stays at layer 3 |
| `src/capabilities.jl` | Layer 1 (included from `Kernel`): the **backend capability table** (#1129) — which optional features each backend has (`_supports(conn, :feature)`, rows on the abstract backend types, never in a driver extension) and the one refusal for a feature a backend lacks (`_capability_error`), which names the feature, the backend at hand and the backends that have it. PormG refuses a missing feature; it never emulates one. A row can carry the server version a backend has the feature from (`_feature_since`, #1163), and every server-version gate reads it, a refusal or an exact fallback alike; `test_capability_table.jl` also fails on a version comparison written outside the table. Also `_engine_key` (#1129 item 2), an engine fact here because Dialect and Migrations both use it; the query builder's facts are in `src/querybuilder/engine_facts.jl`. `docs/src/backends.md` is the table's page, and `test/unit/test_capability_table.jl` fails when the two disagree or when a `BackendCapabilityError` is built by hand outside its reviewed list. `test/unit/test_engine_branches.jl` holds the reviewed count of `isa PormGPostgres`/`isa PormGSQLite` branches, each a default a third backend (#1130) would inherit |
| `src/Backend.jl`, `ext/PormGLibPQExt.jl`, `ext/PormGPostgresExt.jl`, `ext/PormGSQLiteExt.jl` | Layer 2: backend interface: `backend_*` generics + friendly fallbacks; driver bodies live in the weakdep extensions (`LibPQ`/`Postgres`/`SQLite`). Core never names a concrete driver type; a PostgreSQL pool names its driver (`PostgresConnectionPool{D}`, #785), so the two PostgreSQL extensions coexist |
| `ext/PormGMySQLExt.jl` | Layer 2: the MySQL driver extension (MySQL.jl 2.0; #1130) for `MySQLConnectionPool`: connect (the 8.4 floor, a UTC session under 8.4's `sql_mode`), statements, error classification by MySQL's error number, `KILL QUERY` cancellation. The pool carries a conninfo built by `Configuration._mysql_conninfo`, so `redact_secret` masks it like a PostgreSQL DSN. Rendering is core's, as for the other engines: MySQL's engine facts are methods in the two `engine_facts.jl` files, which `test/unit/test_engine_facts.jl` checks |
| `src/Generator.jl` | Model file generation (`generate_models_from_db`): module envelope, `import` lines, and sentinel imports for every generated model file |
| `src/Configuration.jl` | Config, `DB_PATH`, `PORMG_ENV`, transactions |
| `src/ConnectionPool.jl` | `fetch`, pool lock, transaction context (driver-agnostic; untyped connection storage) |
| `src/Models.jl`, `src/models/` | Models and fields |
| `src/Utils.jl`, `ext/PormGReviseExt.jl` | Model loader macros (`@import_models`, `@models_module`) and the world-age loading machinery behind the Julia floor (#211); the Revise weakdep extension wires hot reload back into `Utils.reload_module_contents!` / `Models.set_models` |
| `src/Dialect.jl` | Backend SQL rendering |
| `src/value_repr.jl` | Layer 2.5: the **value-representation** table (#564) — `(CanonicalType, backend)` → the Julia formatter, the SQL canonicalizer, the read parser. Between `Dialect` and `QueryBuilder` because it names `Models` and `Dialect` at definition time and both the render and read paths consult it. A `PormG`-level file rather than a submodule for `Backend.jl`'s reason: its three inputs live in three submodules, so `PormG` is the only module that sees all of them. Multiple dispatch **is** the table — there is no `ValueRepr` noun beside `CanonicalType` to keep aligned |
| `src/AdvisoryLock.jl` | `with_advisory_lock` — cross-process advisory locking (migrations serialize on it) |
| `src/QueryBuilder.jl`, `src/querybuilder/` | Query builder (incl. `many_to_many.jl`) |
| `src/querybuilder/memos.jl` | The sole accessor for the three per-build memos — `memo_key` plus the typed verbs. Build a key with `memo_key`, never inline: restating the keying rule at a call site is the #474 defect, and it type-checks. `test/unit/test_memo_interface.jl` scans `src/`/`ext/` for both (a direct field access and an inline `(:base, …)` tuple), and a bare-`String` lookup is a `MethodError` by dispatch (#478) |
| `src/querybuilder/expression_kind.jl` | The one walk for "what type does this expression have?" (#1034), asked under two policies: `_AllKinds` is `_expression_kind`, every type PormG can name on this engine, and `_MeaningKinds` is `_AllKinds` except that a computed number is what its call means (`_output_kind`, Django's `output_field`) rather than what one engine computes. Its reader is the read view `_read_kind` (#1034 step 3), the one answer to what the read path records for a projection: the kinds a read parser undoes, with a computed number recorded as the float or width-less decimal it means (#1121), so it reads back as one Julia type on every engine. The render's side typing reads `_AllKinds` through one temporal narrowing (`_temporal_side_kind`, #882); the #564 read-kind policy `_ReadKinds` and its readers `_operand_kind`/`_function_projection_kind` were deleted by #1459. A function's contribution is the `_result_rule` stated beside its constructor in `functions.jl`, not a name list kept elsewhere; `test/unit/test_expression_kind_rules.jl` fails when a built function name has no rule. The expression-kind matrix records `_expression_kind` as its `kind` channel, so moving a reader onto it is a reviewed fixture diff; its first reader is `_integer_operand_kind`, which decides the `Abs`/`Floor`/`Ceil`/`Round` render over an integer and the #1111 division check (#1147, #1196) |
| `src/querybuilder/json_key_refusal.jl` | The **one refusal point** for an uncast JSON key's value (#1531): the two probes, `_json_key_lookup_operand` (the value IS a key's value, the walk's `CJSONValue`) and `_json_number_side` (the value CARRIES one: arithmetic over it, `Coalesce(key, 0)`, a CTE column or a `Subquery` over it, which no kind can say), the positions where a value needs a type as types (`_JSONKeyPosition`), one refusal per position (`_json_key_refusal`) and the entry point every consumer calls (`_refuse_uncast_json_key`). It used to be six helpers called from thirteen sites, and each new position was one more bug. `test/unit/test_json_key_refusal_point.jl` fails on a `_json_number_side` call (the record writers excepted), a `CJSONValue` test or a refusal text written outside it (the walk excepted), and on a position with no refusal |
| `src/querybuilder/engine_facts.jl` | The query builder's **engine facts** (#1129 item 2): each thing a branch used to decide for two engines at once (`conn isa PormGPostgres ? A : B`) — whether an interval is computed as milliseconds, whether an INSERT returns its row, whether a bulk statement binds column arrays, … — as a function with one method per engine and **no `::PormGBackend` fallback**, so a third backend (#1130) gets a `MethodError` naming the fact it must decide instead of another engine's arm. The file is that backend's to-do list. Features stay in the capability table, value spelling in `value_repr.jl`. `test/unit/test_engine_facts.jl` reads the file and fails on a fact with a fallback or a missing engine; `test_engine_branches.jl` fails on a new engine ternary |
| `src/querybuilder/engine_departures.jl` | The **meaning departures** (#1147): where one engine computes a different value from the one a cast or a `Concat` operand means, as data — `_MEANING_DEPARTURES`, one row per (target, operand kind) that lists every backend in `_BACKENDS` under `departs` or `keeps` (#1170), read by `_departure(conn, target, kind)`. The engine that departs refuses on itself and the others build; `test/unit/test_meaning_departures.jl` fails on a backend a row leaves undecided, so a new backend (#1130) gets the rows it must decide. A divergence that is only each engine's text (a float, a timestamp) has no row and builds everywhere, and a `Concat` over a non-text operand is refused on every engine as explicit intent, not here. Messages name the engine at hand, never a pair. An integer quotient over a `Sum` the type walk cannot name is no row: which engine departs there is an engine fact, `_untyped_sum_departs` (#1034 phase 3 step 2a). The cast rows stay rows (step 2b): each already decides every backend, and the scale classifier reads a column's or a nested declaration's scale from the type walk |
| `src/Migrations.jl`, `src/migrations/` | State-based schema reconciliation |
| `src/migrations/engine_facts.jl` | The migration code's **engine facts** (#1129 item 2), the twin of `src/querybuilder/engine_facts.jl`: whether a schema change rebuilds the table (`_rebuilds_table` — SQLite's twelve-step procedure) or alters it in place, whether an index can be renamed or adopted, the retype cast rules, `inspectdb`'s engine choices and the lossy pre-check predicates — one method per engine, **no fallback**, so a third backend (#1130) gets a `MethodError` naming each decision instead of SQLite's rebuild or PostgreSQL's `ALTER`. `test/unit/test_engine_facts.jl` reads it as part of its registry |
| `src/migrations/column_spec.jl` | The **compiler** into that IR (#507). One function, `column_spec(field, conn)`, applied to **both** sides — declared and introspected — so a lossy reader choice stops mattering: every struct that renders the same compiles the same, by construction, because it renders through `Dialect._get_column_type`. Engine equivalence (SQLite `BIGINT ≡ INTEGER`, `UUID`/`JSON` ≡ `TEXT`) is decided in `parse_canonical_type`, **once**. Holds the single attribute classification, `NON_DB_ATTRS` / `SCHEMA_ATTRS`, named after Django's `Field.non_db_attrs`; `test/unit/test_column_spec.jl` fails when a `PormGField` gains a slot it neither reads nor classifies. `column_delta(new_field, old_field, conn)` is the planner's one entry point and carries the #69 fail-safe |
| `src/tools.jl` | Layer 4: user-facing lifecycle helpers (`setup`, `install_ai_skills`, `upgrade_guide`) |
| `src/display.jl` | Layer 4: every `Base.show` for a model-bearing type (#534). One file because the three rules are shared and break one method at a time: a display never throws, never reaches `get_settings`, and reads slots with `getfield` (`Model_Type`/`ObjectHandler`/`PormGRow` all overload `getproperty`). Julia's `show_default` walks slots with the **2-arg** `show`, and the model graph is cyclic (`fields` → `sForeignKey.to` → `Model_Type` → `related_objects` → …), so before this every handle serialized the whole schema — 1.6 MB for one `PormGRow`. That is also why it is cheap: a 2-arg method on `Model_Type` and on `PormGField` bounds every container holding one. `test/unit/test_repl_display.jl` asserts a **size ceiling**, not an appearance — the defect is quantitative |
| `src/json_lower.jl` | Layer 4: every `StructUtils.lower` for a model-bearing type (#643) — `display.jl`'s problem one hop over, serialization instead of display, and one file for the same reason: the rules are shared and break one method at a time. Every lowered value is a **leaf** (no PormG type inside it), which is what removes the *edge* the path explosion needs rather than shrinking the output; and the content is model/field-type/relation names only — never a `default=`, never rendered SQL, never the `connection`. Deliberately **not** `sprint(show, x)`: `show(::PormGField)` renders the constructor call the user typed, so it would put `repr`-escaped, 40-column-truncated user data into a wire format. The `InstructionObject` arm is a **credential** fix, not a size one — that type holds a live `connection`, and the reflected document contained `password`. `PormGRow`'s hook stays in `src/querybuilder/execution_read.jl` beside `_json_row`: it shapes data, this bounds the schema. `test/unit/test_json_serialization.jl` asserts **exact marker documents** plus a ceiling — the small cases (an unfixed `sCharField` is 244 chars) are invisible to a ceiling alone |
| `src/precompile.jl` | Last in the include chain: the `PrecompileTools` workload, built on mock connections so it needs no database. Not a lever for test-suite speed (#819) |
| `test/integration/` | DB integration tests (`db_2` = PostgreSQL, `db_sl` = SQLite, `db_my` = MySQL via `PORMG_DB`). `runtests.jl` runs on all three; MySQL's own files (`test_mysql_*.jl`) run beside it, each on its own. A testset an engine cannot run yet is marked `not_yet_on(:mysql, "#N")` (`common_setup.jl`), and the run lists them at the end |
| `docs/src/` | User documentation |
| `upgrading/` | The change log `upgrade_guide` reads — **one file per breaking/behavior entry**, `YYYY-MM-DD-<slug>.md`. Every `.md` here is an entry; nothing else belongs in it, and `UPGRADING.md` beside it is the authoring contract, not a log |

## Verification

Run the narrowest relevant test slice first; broaden only after green.

**Full unit suite** — what CI runs. `-O0` is optional but worth it: the suite is mostly JIT
compilation of code that runs once, and skipping LLVM optimization took it from 1664 s to 978 s with
the same result (#819). `Pkg.test()` hands the flag to its child process, so it goes on the outer
`julia`:

```
julia -O0 --project=. -e 'using Pkg; Pkg.test()'
```

**One file, unit or integration** — always through the integration environment, which carries
the SQL drivers (`LibPQ`, `Postgres`, `SQLite`). They are `[weakdeps]` of the package, so the
package environment never installs them, and `Manifest.toml` is gitignored, so nothing local
re-resolves on its own (#624):

```
julia --project=test/integration test/unit/test_order_by_nulls.jl
julia -t auto --project=test/integration test/integration/test_reverse_joins.jl
```

Handing a test file to the package environment (`--project=.`) cannot load the drivers. An
integration file still *runs* that way, because `common_setup.jl` redirects the environment, but
that is a rescue for a wrong invocation, not a spelling to use or document —
`test/unit/test_documented_commands.jl` fails on any committed command that does.

**Fresh clone** — instantiate the integration environment once:

```
julia --project=test/integration -e 'using Pkg; Pkg.instantiate()'
```

**Threads per engine.** `db_2` (PostgreSQL) and `db_my` (MySQL) under `-t auto`; `db_sl` (SQLite)
**always `-t 1`** — SQLite does not tolerate `-t auto` (see `test/integration/common_setup.jl`).
Julia's one-thread default hides an omitted `-t 1` until `JULIA_NUM_THREADS` is set, so write it
explicitly every time:

```
PORMG_DB=db_sl julia -t 1 --project=test/integration test/integration/runtests.jl
```

**Two PostgreSQL drivers.** `db_2` runs through LibPQ (the default) or Postgres.jl, and both are
in use, so the release gate runs the `db_2` suite once per driver (#1433). A
regression in one driver's extension, or in a path the two handle differently (`Decimal` and
timestamp decoding, `bulk_insert`, cancellation, a statement's bind-parameter limit), is invisible
to a run on the other. `PORMG_POSTGRES_DRIVER=Postgres` switches every pool built from the
configuration that does not name its driver. Run `test/integration/runtests.jl` directly: the unit
entry point `test/runtests.jl` deletes the variable. The two runs reseed the same fixture, so run
them one after the other:

```
julia -t auto --project=test/integration test/integration/runtests.jl
PORMG_POSTGRES_DRIVER=Postgres julia -t auto --project=test/integration test/integration/runtests.jl
```

**MySQL.** `db_my` points at a local MySQL 8.4 — a Docker `mysql:8.4` container
is enough — through its own gitignored `test/integration/db_my/connection.yml` (`adapter: MySQL`;
see `docs/src/configuration/connection_yml.md`). The full suite runs there as on the other engines, and
MySQL's own files — the driver layer, the reads, the single-row writes and upserts, the bulk writes, the
migrations, the alters and `inspectdb` — run on their own, after it (the reads file empties the database
before making its own tables; the next full run rebuilds the F1 schema and reseeds it):

```
PORMG_DB=db_my julia -t auto --project=test/integration test/integration/runtests.jl
PORMG_DB=db_my julia -t auto --project=test/integration test/integration/test_mysql_backend.jl
PORMG_DB=db_my julia -t auto --project=test/integration test/integration/test_mysql_reads.jl
PORMG_DB=db_my julia -t auto --project=test/integration test/integration/test_mysql_writes.jl
PORMG_DB=db_my julia -t auto --project=test/integration test/integration/test_mysql_bulk.jl
PORMG_DB=db_my julia -t auto --project=test/integration test/integration/test_mysql_migrations.jl
PORMG_DB=db_my julia -t auto --project=test/integration test/integration/test_mysql_alters.jl
PORMG_DB=db_my julia -t auto --project=test/integration test/integration/test_mysql_inspectdb.jl
```

One testset needs the account to create a trigger, which MySQL refuses while binary logging is on
(error 1419) unless the server runs with `--log-bin-trust-function-creators=1`; without it the run
records that testset as skipped.

**A single integration file is a valid target.** Most `test/integration/test_*.jl` open with
`if !isdefined(Main, :PormG) include("common_setup.jl") end`, so naming one file runs it against the
already-seeded database and skips the DDL bootstrap and fixture reseed `runtests.jl` repeats every
time. Concurrent runs against `db_2` queue on a PostgreSQL advisory lock taken in `common_setup.jl`,
and runs against `db_my` on a MySQL `GET_LOCK` taken there too (`PORMG_TEST_LOCK_WAIT=<secs>` bounds
the wait, default 900; `PORMG_TEST_LOCK=0` opts out); SQLite is exempt because `f1.sqlite` is per
checkout.

**Compat floors.** CI's `floor-resolve` job resolves every `[compat]` range at its minimum (#574).
`test/unit/test_compat_guards.jl` records why some floors are load-bearing and must not be raised;
read a red run against that file before moving a bound.

**Docs build** — the package environment has no Documenter:

```
julia --project=docs -e 'using Pkg; Pkg.develop(PackageSpec(path=pwd())); Pkg.instantiate(); include("docs/make.jl")'
```

## Conventions the suite enforces

- Multi-line method chains use **trailing-dot** syntax (`.` at the end of the line that continues) or
  stay inline — a leading-dot line is a Julia `ParseError`.
- Parameterized queries only; never interpolate user input into SQL strings.
- Docs and examples use the Formula 1 dataset, not generic `User`/`Post` placeholders.
- Every `@testset` says what it tests, the expected SQL, and why it matters
  (`docs/src/contributing.md` → *Testing conventions*).
- **Concrete types and fewer allocations (#1346).** Code that is added or refactored moves toward
  concrete types and never away from them. Untyped code costs a dynamic dispatch and an allocation on
  every call, and it is what a static compiler (`juliac --trim`) cannot follow. This is a ratchet,
  not a target: nothing gets worse, and what is touched gets better.
  - A struct field has a concrete type, never `Any` or an abstract type left open. A mutable box is
    `Base.RefValue{T}`, not `Ref{T}` (which is abstract).
  - A new function takes typed arguments or a `NamedTuple`/struct, not a new `Dict{String,Any}`.
  - A choice between behaviors dispatches on a type, not on a name looked up at run time
    (`getfield(Dialect, Symbol(name))`).
  - No `repr`/`string`/`sprint(show, …)` of a value whose type is not inferred, on a path a query
    takes (error messages included): it is the costliest single pattern for a static compiler.
  - Where an untyped value cannot be avoided, a function barrier keeps it at the edge.
  - A hot path (the query build, row parsing) does not allocate per row what it can allocate once.
  - A change made for typing that slows the JIT path more than noise needs a measurement that
    justifies it.

  `test/unit/test_type_ratchet.jl` holds the reviewed count, per file, of the three patterns that
  remain: struct fields typed `Any` or left abstract, `getfield(<x>, Symbol(…))` lookups and
  `format::Dict{String,Any}` parameters. A rise fails. A fall fails too, until the count is lowered
  in the same change, so each improvement is recorded. A change to the query build or row read
  compares against `test/performance/alloc_baseline.jl` (allocations and warm build time; not a CI
  gate, since the numbers move between Julia versions).
