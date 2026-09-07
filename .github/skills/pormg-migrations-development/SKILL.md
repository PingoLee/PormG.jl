---
name: pormg-migrations-development
description: Implement or refactor migration planning and execution in src/Migrations.jl and src/migrations/: schema reconciliation, migration history, dry-run/status, destructive guards, migration docs, and CI workflows.
---

# PormG Migrations Development

## Purpose

Use this skill for work on schema reconciliation, migration planning, runtime history, dry-run output, destructive guards, repair flows, and migration-related documentation.

This skill is for the migration subsystem itself, not for ordinary ORM query behavior.

## Use This Skill For

- Editing `src/Migrations.jl`
- Editing `src/Generator.jl` when the work affects migration/bootstrap setup
- Editing `src/migrations/introspection.jl`
- Editing `src/migrations/planner.jl`
- Editing `src/migrations/runner.jl`
- Updating migration docs and migration-focused tests
- Investigating `init_migrations()`, `status()`, `dry_run()`, `makemigrations()`, `migrate()`, `mark_applied()`, `mark_failed()`, and `remove_migration_record()`

## Bootstrap and system model

- Treat `Generator.create_db_folder_and_yml()` as the expected bootstrap path for creating `db/connection.yml` before migration workflows touch project config
- PormG uses a state-based migration engine that reconciles current Julia model state against the live database schema via introspection
- **State-based, not Django-graph — do not port Django assumptions.** `makemigrations` computes `diff(live-DB introspection, models file)` and **never reads previous migration files**; there is no dependency graph or replay. `pending_migrations.jl` and `applied_migrations/` are **inert audit artifacts**, not a source of truth — editing an applied file changes nothing downstream. "Drift" that matters is live-schema-vs-models (surfaced by the next `makemigrations` and `status()`), not migration-file checksum divergence. Concept doc: `docs/src/migrations/index.md` → *What this means in practice*.
- Keep docs, tests, and CLI guidance explicit about unsupported or partial behavior (the rule and its `migrate_to` case live under *Unsupported behavior* below)

## Core Rules

### Runtime source of truth

- Treat `pormg_migrations` as the canonical runtime history table
- Files in `applied_migrations/` are useful artifacts, but not the primary state source

### Recommended operator flow

Keep docs, tests, and implementation aligned with this sequence:

1. `init_migrations()`
2. `status()`
3. `makemigrations()`
4. `dry_run()`
5. `migrate()`

`status()` and `dry_run()` are part of the normal operator flow, not optional extras.

### Destructive actions

- If `dry_run()` reports destructive SQL, require explicit `destructive=true`
- Tests and docs must reflect that guard
- Never normalize destructive behavior as implicit or safe by default

### Unsupported behavior

- Do not document or test `migrate_to(version)` as supported unless implementation is completed
- If a feature is partial, keep the contract explicit instead of implying Django-like completeness

### CI and automation

- Use `interactive=false` to bypass rename confirmation prompts in non-interactive environments
- If the generated plan contains destructive SQL, CI must opt in explicitly with `destructive=true`

## Test Strategy

### Integration scope

Use integration tests when validating:

- migration status behavior
- dry-run output semantics
- destructive guard behavior
- real schema reconciliation against PostgreSQL or SQLite
- end-to-end migration lifecycle behavior

Likely files:

- `test/integration/test_migration_bootstrap.jl`
- `test/integration/common_migration_setup.jl`

### Unit scope

Use unit tests when validating:

- diff planning
- rename detection hints
- destructive classification
- checksum generation
- dry-run result shaping
- internal ordering logic

### Isolation discipline

- Use isolated migration environments for destructive tests
- Prefer `db_test_migration_pg/` or equivalent dedicated fixtures for PostgreSQL migration cycling

### Test Writing Standard

Follow the canonical [PormG Test Writing Standard](../../instructions/test-writing.md): standardized `@testset` header comments and heavily commented test logic.

## Documentation Rules

- Keep migration docs synchronized with implementation in the same change when practical
- If docs claim a public API, verify it exists in `src/Migrations.jl` and is exercised by at least one test
- Keep limitations explicit, especially for destructive rollback and unsupported targeted execution paths
- Build docs when migration-facing public behavior or examples change

## Planner internals: column identity

`makemigrations` decides *changed / unchanged* by compiling **both** sides of the diff to a canonical
column IR and comparing that — never by comparing `PormGField` structs. The IR is
`Migrations.ColumnSpec` (`src/migrations/column_spec.jl`); the compiler is
`column_spec(field, conn)`; the planner's whole field diff is one call to `column_attrs_changed`
inside `_alter_table_fields`.

**Why an IR at all.** Introspection reconstructs a `PormGField` from the live schema through a type
map that returns *one* struct per rendered type, so the declared struct can never be recovered:
`CharField` / `URLField` / `SlugField` all come back as one struct, and on SQLite a `BIGINT` column
comes back as `sIntegerField`. Struct identity is therefore not column identity. The IR closes the
gap by construction rather than by reconciliation — `column_spec` renders through
`Dialect._get_column_type`, the same function the DDL path uses, so **every struct that renders the
same column compiles to the same spec**.

**Three rules worth knowing before editing it:**

1. **Engine equivalence is decided in `parse_canonical_type`, once** — Atlas's per-driver normalizer,
   run on both sides before the diff. A collapse belongs there only when it is *forced*: two
   spellings become one `CanonicalType` when PormG renders both as the same string, so the database
   cannot tell them apart. SQLite `BIGINT ≡ INTEGER` qualifies (`sqlite_type_map_reverse` maps both
   to `INTEGER`); SQLite `SMALLINT` vs `INTEGER UNSIGNED` does **not**, because PormG writes both
   verbatim and a change between them is observable. Collapsing what the engine merely *stores*
   alike would silently stop planning a real change.
2. **`on_delete` is a schema fact**, carried in `ForeignKeyRef(table, binding, column, on_delete)`.
   A change there is a **constraint delta, never a column ALTER** — it reaches the plan as DROP +
   ADD CONSTRAINT. This used to be answered three different ways (`_compare_model_field` skipped it,
   `_NON_SCHEMA_FIELD_ATTRS` skipped it, `_fk_constraint_action` diffed it); the compiler answers it
   once. It matches Django: `on_delete` is not in `Field.non_db_attrs`, and on Django `main`
   `ForeignObject` skips it only when the action is *not* a `DatabaseOnDelete` variant — *"Database-
   level on_delete options are part of the column definition."* PormG renders `ON DELETE` into every
   constraint (#292), so it only ever has that flavour.
3. **`db_index` is not in the IR at all.** `index_actions` owns it, and on SQLite a non-empty column
   delta means a full table rebuild that re-emits every secondary index — so an index-only
   difference must leave the delta empty or the rebuild would duplicate the `CREATE INDEX` beside it
   (#82/#325).

**One classification, one place.** `NON_DB_ATTRS` (no DDL expresses it) and `SCHEMA_ATTRS` (the
compiler reads it) replace `_NON_SCHEMA_FIELD_ATTRS` and the two other lists that disagreed with it.
Named after Django's `Field.non_db_attrs`. `test/unit/test_column_spec.jl` fails when a `PormGField`
gains a slot in neither — the same guarantee `field_kwargs_snapshot.txt` gives `Model_to_str`, with
no snapshot to regenerate.

**The seam to the action code.** Phase 1 changed how the answer is *decided*, not what is emitted
once it is "changed". `column_delta` returns the typed facets (`:type`, `:nullable`, `:reference`,
`:checks`, `:identity`, …); `alter_attrs` adapts those back to the `colect_not_equal::Vector{Symbol}`
that `Dialect.alter_field`, the FK helpers and `_FK_IDENTITY_ATTRS` already consume. **#507 phase 2
deletes that adapter** and derives plan actions from `column_delta` directly, which is what makes
#504 unrepresentable.

**Two review flags, both sharper than what they replace:**

- **A new `isa` on a field struct inside the planner's field diff.** There is now none: the planner
  does no field-type dispatch at all. A new one is a regression against the IR, not a fix —
  `column_spec` is where a field type is interpreted. (Its predecessor rule was "route it to #507";
  #507 phase 1 has landed, so the routing is into the compiler.)
- **A new entry in `NON_DB_ATTRS` that hides a real fact.** The list is legitimate for things no DDL
  path emits. It is *not* a place to park an inconvenient difference — check that no renderer writes
  it before adding one, and say so in the comment, as the `on_update` / `deferrable` /
  `initially_deferred` entry does.

**The churn class this closed.** "`makemigrations` plans DDL forever" / "plans nothing" for a column
nobody changed was one bug shape seen seven times — #325 → #408 → #409 → #417 → #437 → #498 → #503 —
each fixed with a new `isa` escape, a new skip-list entry or a new reconciliation branch. A new issue
in this class is now a **defect in the compiler or in `parse_canonical_type`**, and it is fixed
there. If you find yourself adding a fifth comparator, that is the signal the IR is missing a fact,
not that it needs an exception.

**The missing-subtype shape.** `sForeignKey` and `sOneToOneField` are sibling structs, not a subtype
pair. Four subsystems each missed the second one behind an `isa sForeignKey` gate — the DDL renderer
(#408), the schema readers (#409), the query builder (#418), the planner (#437). Spell the pair once:
`Models.sRelationalColumn` (`src/models/fields.jl`). A new bare `isa sForeignKey` gate is a review
flag. (In the planner's diff the shape is now unrepresentable: the FK/O2O pair over one parent simply
compiles to one `ColumnSpec`.)

## Triage

Identify which stage the issue lives in — **planning, execution, introspection, history tracking,
or convergence** — before editing. That choice picks both the file and the test layer, and they fail
in different ways: a planner bug produces wrong SQL, an introspection bug produces a wrong *diff*
from correct SQL, a history bug leaves the DB right and `pormg_migrations` wrong — and a
convergence bug leaves the DB right *and* the SQL right, yet the next `makemigrations` plans it
again. Convergence is the class described above, and since #507 it has a single home: fix it in
`column_spec` / `parse_canonical_type`, never by adding a comparator or an escape to the planner.

## Verification Commands

Narrowest first. **Every integration run needs the user's explicit permission, every time** — `db_2`
is one shared PostgreSQL server. Migration diffs are one of the cases that genuinely owe the **full**
suite rather than a slice (the DDL path only executes in `test_migration_bootstrap.jl`) — see the
rung-5 table in [`pormg-issue-workflow`](../pormg-issue-workflow/SKILL.md) → *Verify*.

```powershell
julia --project=. test/runtests.jl                                                              # unit — no permission needed
julia -t auto --project=test/integration test/integration/runtests.jl                           # rung 5 — ask first
$env:PORMG_DB="db_sl"; julia -t 1 --project=test/integration test/integration/runtests.jl       # rung 5, SQLite (-t 1 required)
julia --project=docs -e 'using Pkg; Pkg.develop(PackageSpec(path=pwd())); Pkg.instantiate(); include("docs/make.jl")'
```

Two traps in this block specifically:

- **`test_migration_bootstrap.jl` cannot be run standalone.** It guards on `:reset_database!`, not
  `:PormG`, so `common_setup.jl` never loads — its own header says it is included from `runtests.jl`
  *after* setup. Reach it through the suite, not by naming the file.
- **The docs build needs `--project=docs`** — the package env carries no Documenter, so
  `--project=. docs/make.jl` fails. Same rule as
  [`general.instructions.md`](../../instructions/general.instructions.md) → *Verification*.

## Anti-Patterns

- Do not treat filesystem archives as the only migration truth
- Do not assume a Django-style migration graph: no ordered dependencies, no file replay, and migration files are audit artifacts (see *Bootstrap and system model*)
- Do not silently allow destructive SQL
- Do not broaden docs ahead of implementation
- Do not test unsupported migration targeting as if it were complete
