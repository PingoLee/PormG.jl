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
- Keep docs, tests, and CLI guidance explicit about unsupported or partial behavior rather than implying Django-style completeness

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

## Workflow

1. Read the planner, runner, and current migration tests first
2. Identify whether the issue is planning, execution, introspection, or history tracking
3. Fix the root cause in the migration subsystem
4. Add or update a regression test at the correct layer
5. Update docs if public behavior changed
6. Run the narrowest migration-focused test slice first

## Verification Commands

```powershell
julia --project=. test/runtests.jl
julia -t auto --project=. test/integration/test_migration_bootstrap.jl
julia -t auto --project=. test/integration/runtests.jl
julia --project=. docs/make.jl
```

## Anti-Patterns

- Do not treat filesystem archives as the only migration truth
- Do not silently allow destructive SQL
- Do not broaden docs ahead of implementation
- Do not test unsupported migration targeting as if it were complete
