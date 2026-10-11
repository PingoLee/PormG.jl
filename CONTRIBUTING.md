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
| `src/Backend.jl`, `ext/PormGLibPQExt.jl`, `ext/PormGPostgresExt.jl`, `ext/PormGSQLiteExt.jl` | Layer 2: backend interface: `backend_*` generics + friendly fallbacks; driver bodies live in the weakdep extensions (`LibPQ`/`Postgres`/`SQLite`). Core never names a concrete driver type; a PostgreSQL pool names its driver (`PostgresConnectionPool{D}`, #785), so the two PostgreSQL extensions coexist |
| `src/Generator.jl` | Model file generation (`generate_models_from_db`): module envelope, `import` lines, and sentinel imports for every generated model file |
| `src/Configuration.jl` | Config, `DB_PATH`, `PORMG_ENV`, transactions |
| `src/ConnectionPool.jl` | `fetch`, pool lock, transaction context (driver-agnostic; untyped connection storage) |
| `src/Models.jl`, `src/models/` | Models and fields |
| `src/Utils.jl`, `ext/PormGReviseExt.jl` | Model loader macros (`@import_models`, `@models_module`) and the world-age loading machinery the Julia 1.12 floor exists for (#211); the Revise weakdep extension wires hot reload back into `Utils.reload_module_contents!` / `Models.set_models` |
| `src/Dialect.jl` | Backend SQL rendering |
| `src/value_repr.jl` | Layer 2.5: the **value-representation** table (#564) — `(CanonicalType, backend)` → the Julia formatter, the SQL canonicalizer, the read parser. Between `Dialect` and `QueryBuilder` because it names `Models` and `Dialect` at definition time and both the render and read paths consult it. A `PormG`-level file rather than a submodule for `Backend.jl`'s reason: its three inputs live in three submodules, so `PormG` is the only module that sees all of them. Multiple dispatch **is** the table — there is no `ValueRepr` noun beside `CanonicalType` to keep aligned |
| `src/AdvisoryLock.jl` | `with_advisory_lock` — cross-process advisory locking (migrations serialize on it) |
| `src/QueryBuilder.jl`, `src/querybuilder/` | Query builder (incl. `many_to_many.jl`) |
| `src/querybuilder/memos.jl` | The sole accessor for the three per-build memos — `memo_key` plus the typed verbs. Build a key with `memo_key`, never inline: restating the keying rule at a call site is the #474 defect, and it type-checks. `test/unit/test_memo_interface.jl` scans `src/`/`ext/` for both (a direct field access and an inline `(:base, …)` tuple), and a bare-`String` lookup is a `MethodError` by dispatch (#478) |
| `src/querybuilder/expression_kind.jl` | The one walk for "what type does this expression have?" (#1034), asked under two policies: `_ReadKinds` is the #564 read kind (`_operand_kind`/`_function_projection_kind` are thin wrappers over it), `_AllKinds` is `_expression_kind`, every type PormG can name. A function's contribution is the `_result_rule` stated beside its constructor in `functions.jl`, not a name list kept elsewhere; `test/unit/test_expression_kind_rules.jl` fails when a built function name has no rule. The expression-kind matrix records `_expression_kind` as its `kind` channel, so moving a reader onto it is a reviewed fixture diff; its first reader is `_integer_operand_kind`, which decides the `Abs`/`Floor`/`Ceil` render over an integer and the #1111 division check (#1147) |
| `src/Migrations.jl`, `src/migrations/` | State-based schema reconciliation |
| `src/migrations/column_spec.jl` | The **compiler** into that IR (#507). One function, `column_spec(field, conn)`, applied to **both** sides — declared and introspected — so a lossy reader choice stops mattering: every struct that renders the same compiles the same, by construction, because it renders through `Dialect._get_column_type`. Engine equivalence (SQLite `BIGINT ≡ INTEGER`, `UUID`/`JSON` ≡ `TEXT`) is decided in `parse_canonical_type`, **once**. Holds the single attribute classification, `NON_DB_ATTRS` / `SCHEMA_ATTRS`, named after Django's `Field.non_db_attrs`; `test/unit/test_column_spec.jl` fails when a `PormGField` gains a slot it neither reads nor classifies. `column_delta(new_field, old_field, conn)` is the planner's one entry point and carries the #69 fail-safe |
| `src/tools.jl` | Layer 4: user-facing lifecycle helpers (`setup`, `install_ai_skills`, `upgrade_guide`) |
| `src/display.jl` | Layer 4: every `Base.show` for a model-bearing type (#534). One file because the three rules are shared and break one method at a time: a display never throws, never reaches `get_settings`, and reads slots with `getfield` (`Model_Type`/`ObjectHandler`/`PormGRow` all overload `getproperty`). Julia's `show_default` walks slots with the **2-arg** `show`, and the model graph is cyclic (`fields` → `sForeignKey.to` → `Model_Type` → `related_objects` → …), so before this every handle serialized the whole schema — 1.6 MB for one `PormGRow`. That is also why it is cheap: a 2-arg method on `Model_Type` and on `PormGField` bounds every container holding one. `test/unit/test_repl_display.jl` asserts a **size ceiling**, not an appearance — the defect is quantitative |
| `src/json_lower.jl` | Layer 4: every `StructUtils.lower` for a model-bearing type (#643) — `display.jl`'s problem one hop over, serialization instead of display, and one file for the same reason: the rules are shared and break one method at a time. Every lowered value is a **leaf** (no PormG type inside it), which is what removes the *edge* the path explosion needs rather than shrinking the output; and the content is model/field-type/relation names only — never a `default=`, never rendered SQL, never the `connection`. Deliberately **not** `sprint(show, x)`: `show(::PormGField)` renders the constructor call the user typed, so it would put `repr`-escaped, 40-column-truncated user data into a wire format. The `InstructionObject` arm is a **credential** fix, not a size one — that type holds a live `connection`, and the reflected document contained `password`. `PormGRow`'s hook stays in `src/querybuilder/execution_read.jl` beside `_json_row`: it shapes data, this bounds the schema. `test/unit/test_json_serialization.jl` asserts **exact marker documents** plus a ceiling — the small cases (an unfixed `sCharField` is 244 chars) are invisible to a ceiling alone |
| `src/precompile.jl` | Last in the include chain: the `PrecompileTools` workload, built on mock connections so it needs no database. Not a lever for test-suite speed (#819) |
| `test/integration/` | DB integration tests (`db_2` = PostgreSQL, `db_sl` = SQLite via `PORMG_DB`) |
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

**Threads per engine.** `db_2` (PostgreSQL) under `-t auto`; `db_sl` (SQLite) **always `-t 1`** —
SQLite does not tolerate `-t auto` (see `test/integration/common_setup.jl`). Julia's one-thread
default hides an omitted `-t 1` until `JULIA_NUM_THREADS` is set, so write it explicitly every time:

```
PORMG_DB=db_sl julia -t 1 --project=test/integration test/integration/runtests.jl
```

**A single integration file is a valid target.** Most `test/integration/test_*.jl` open with
`if !isdefined(Main, :PormG) include("common_setup.jl") end`, so naming one file runs it against the
already-seeded database and skips the DDL bootstrap and fixture reseed `runtests.jl` repeats every
time. Concurrent runs against `db_2` queue on a PostgreSQL advisory lock taken in `common_setup.jl`
(`PORMG_TEST_LOCK_WAIT=<secs>` bounds the wait, default 900; `PORMG_TEST_LOCK=0` opts out); SQLite is
exempt because `f1.sqlite` is per checkout.

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
