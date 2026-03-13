## Plan: Migration System Publish Readiness

Build the migration improvements in dependency order so later features reuse a stable history/status foundation instead of extending the current filesystem-only workflow. The recommended path is: bootstrap/history/status first, then safety and locking, then targeted execution and repair flows, and only then reversible migrations and broader schema coverage.

**Steps**
1. Phase 0: lock the release contract for the first migration upgrade.
Include `init_migrations()`, history persistence, `status()`, dry-run, destructive guard, PostgreSQL advisory locking, targeted execution, repair operations, and docs alignment. Treat full rollback for destructive SQLite paths as a later phase with explicit limitations.

2. Phase 1: add persistent migration metadata.
Create `pormg_migrations` as the canonical runtime source of truth with migration id, version/order key, checksum, applied timestamp, status, and enough artifact references for reconciliation. Filesystem archives remain secondary.

3. Phase 2: refactor the runner around one execution lifecycle.
Centralize prepare → validate → lock → execute → commit/rollback → record status → archive inside `src/migrations/runner.jl`. This is the dependency base for almost every later feature.

4. Phase 3: add bootstrap and inspection APIs.
Implement `init_migrations()` plus `status()` and dry-run / plan review. `status()` should report pending, applied, failed, and drift signals. Dry-run should validate ordering, checksums, destructive actions, and SQL generation without changing DB or files.

5. Phase 4: add safety controls.
Implement destructive-action detection and require `destructive=true` or equivalent for DROP-like operations. Surface these operations in dry-run and status output.

6. Phase 5: integrate deployment locking.
Use `src/AdvisoryLock.jl` in PostgreSQL migrations with a deterministic lock key per database/environment. For SQLite, keep the contract explicit: single-instance migration safety only until a real external/filesystem lock exists.

7. Phase 6: add targeted execution and repair flows.
Implement `up(version)` / `migrate_to(version)` plus repair helpers such as `mark_applied`, `mark_failed`, or reconciliation after interrupted/manual intervention. This should use the history table instead of filesystem heuristics.

8. Phase 7: resolve the data-migration API mismatch.
Either implement a first-class migration action model that supports custom SQL/Julia actions in the same lifecycle, or remove the unsupported claim from `docs/src/migrations.md`. Do not leave docs ahead of code.

9. Phase 8: add reversible migrations cautiously.
Start with reversible, mechanically derivable operations and explicitly mark irreversible ones. Do not promise identical rollback guarantees across PostgreSQL and SQLite.

10. Phase 9: replace prompt-only rename handling and add drift detection.
Introduce declarative rename hints usable in CI, then compare applied history plus live introspection to detect out-of-band schema changes.

11. Phase 10: expand schema-object coverage.
After the lifecycle is stable, add first-class handling for views, triggers, and composite constraints/indexes.

12. Phase 11: keep tests and docs in lockstep throughout.
Do not defer verification to the end; each phase should land with matching unit/integration coverage and documentation updates.

**Relevant files**
- `src/Migrations.jl`: export surface for new migration APIs
- `src/migrations/runner.jl`: main execution lifecycle, history, status, locking, repair, targeted execution
- `src/migrations/planner.jl`: diff generation, rename handling, future reversible metadata
- `src/migrations/introspection.jl`: drift detection inputs and schema-object introspection
- `src/Dialect.jl`: DDL for `pormg_migrations`, reverse ops where supported
- `src/Generator.jl`: pending migration artifact format and metadata
- `src/AdvisoryLock.jl`: PostgreSQL migration lock integration
- `src/ConnectionPool.jl`: transaction helper constraints and future savepoint implications
- `docs/src/migrations.md`: docs alignment
- `README.MD`: publish-facing migration claims
- `test/unit/test_migration_planner.jl`: planner/order/checksum coverage
- `test/integration/test_migrations_sqlite.jl`: SQLite behavior and limitation coverage
- `test/unit/test_migrations_runner.jl`: likely new file for runner lifecycle tests
- `test/integration/test_migrations_postgresql.jl`: likely new file for PostgreSQL migration and advisory lock coverage

**Verification**
1. Add unit tests for migration id/checksum generation, ordering, destructive detection, and rename-hint parsing.
2. Add mocked runner tests for pending → applied, pending → failed, dry-run no-write behavior, and repair flows.
3. Extend SQLite integration tests for bootstrap, status, destructive guard, targeted execution where supported, and explicit unsupported multi-instance behavior.
4. Add PostgreSQL integration tests for advisory-lock serialization, history writes, status, targeted execution, and reversible rollback cases.
5. Ensure every public migration API documented in `docs/src/migrations.md` exists in `src/Migrations.jl` and has at least one automated test.

**Decisions**
- First release scope should include history persistence, status, dry-run, destructive guard, PostgreSQL locking, targeted execution, repair operations, docs alignment, and drift detection.
- Full rollback for destructive SQLite recreation paths should be treated as high-risk and later-phase unless you deliberately narrow the rollback contract.
- The history table should become the canonical runtime source of truth; archives remain useful but secondary.

Natural next steps:
1. Split this into “must-have before publish” and “post-publish”.
2. Reorder the phases into smaller PR-sized milestones.
3. Convert Phase 1 into a file-by-file implementation checklist for the coding pass.
