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

The planner has no representation of "a column". `makemigrations` diffs two `PormGField` structs —
one from the models file, one *reconstructed* from the live schema by the readers through
`postgres_type_map` / `sqlite_type_map` — and decides *changed / unchanged* by comparing the structs.
Know this before touching `_alter_table_fields`, because every recent convergence bug lives in it.

**Three comparators, in order, each with its own reconciliations** (`src/migrations/planner.jl`):

1. **Fast path** — `Models.are_model_fields_equal` → `_compare_model_field` (`src/Models.jl`):
   attribute-wise; skips `:to` (via `_compare_field_foreign_key`), `:on_delete`, `:to_table`;
   fails *closed* on an exception (#69).
2. **Attribute-wise** — `_diffs_attribute_wise`: same struct type, or the FK/O2O pair (#437);
   reconciles `:to` and `:pk_field` (#50), skips `_NON_SCHEMA_FIELD_ATTRS`.
3. **Physical signature** — `Dialect.describes_same_column` (#325): different struct types, same
   `_column_signature` (rendered type + the two CHECK bounds); refuses any relational or PK field.
4. **Else** — the #408 `db_constraint=false` escape, otherwise `push!(:type)` — on SQLite, a full
   table rebuild.

The reader side is lossy by construction: a type map returns *one* struct per rendered type, so
`CharField` / `URLField` / `SlugField` come back as one struct and SQLite `BIGINT` comes back as
`IntegerField` (#503). Comparator 3 exists to paper over exactly that.

**The churn class, and where it goes.** "`makemigrations` plans DDL forever" / "plans nothing" for
a column nobody changed is one bug shape, seen as #325 → #408 → #409 → #417 → #437 → #498 → #503.
Each fix was a new `isa` escape, a new `_NON_SCHEMA_FIELD_ATTRS` entry or a new reconciliation
branch, and the planner's own comment block (`planner.jl:44-72`) records why the next one moves the
churn rather than ending it. **The agreed direction is #507** — both sides compile to a canonical
column IR and the diff runs on that. A new issue in this class is routed to #507 and batched under
it, not fixed with another escape ([`pormg-session-planning`](../pormg-session-planning/SKILL.md)
→ *Third strike*). This section describes the code as it stands until #507 lands; #507's
acceptance list is what replaces it.

**The missing-subtype shape.** `sForeignKey` and `sOneToOneField` are sibling structs, not a
subtype pair. Four subsystems have each missed the second one behind an `isa sForeignKey` gate —
the DDL renderer (#408), the schema readers (#409), the query builder (#418), the planner (#437).
Spell the pair once: `Models.sRelationalColumn` (`src/models/fields.jl`). A new bare
`isa sForeignKey` gate is a review flag.

## Triage

Identify which stage the issue lives in — **planning, execution, introspection, history tracking,
or convergence** — before editing. That choice picks both the file and the test layer, and they fail
in different ways: a planner bug produces wrong SQL, an introspection bug produces a wrong *diff*
from correct SQL, a history bug leaves the DB right and `pormg_migrations` wrong — and a
convergence bug leaves the DB right *and* the SQL right, yet the next `makemigrations` plans it
again. Convergence is the class described above: route it to #507 rather than patching a comparator.

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
