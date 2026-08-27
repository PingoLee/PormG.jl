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

## Triage

Identify which stage the issue lives in — **planning, execution, introspection, or history
tracking** — before editing. That choice picks both the file and the test layer, and the four fail
in different ways: a planner bug produces wrong SQL, an introspection bug produces a wrong *diff*
from correct SQL, and a history bug leaves the DB right and `pormg_migrations` wrong.

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
