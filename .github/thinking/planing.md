# Phase C — Migration Engine Edge Cases: Review & Improvement Plan

## Current Status

Phase C lives in `test/integration/test_migration_bootstrap.jl` under the
`if adapter_name == "SQLite"` guard. It runs against an isolated throwaway
SQLite database (`db_test_migration/`), cycling through 13 ordered phases that
cover schema evolution (phases 1–8) and migration machinery (phases 9–13).

---

## Strengths

- Comprehensive lifecycle: schema evolution (add field, drop field, FK, types,
  indexes, nullability, rename) + migration machinery (history bootstrap,
  status reporting, dry_run, destructive guard, repair) all in one isolated DB.
- The `write_test_models` + temp-DB reset pattern is the right approach for
  ordered schema evolution tests — mutations don't bleed into the main
  integration database.
- Phase 12 (destructive guard) tests both the refusal path (`destructive=false`
  returns `nothing` and leaves the pending file) and the success path
  (`destructive=true` applies the drop). That dual assertion is good discipline.

---

## Issues to Fix

### 1. Phase 7 (Rename) — incomplete assertion
`@test "fullname" in columns.name` passes even if the engine did ADD instead
of RENAME. The old column name must also be absent.

**Fix:**
```julia
@test "fullname" in columns.name
@test !("name" in columns.name)   # ADD-instead-of-RENAME would fail here
```

---

### 2. Phase 5 (Indexes) — assertion too weak
`@test !isempty(indices)` passes for any index, including the implicit PK.
Should assert the index created by `db_index=true, unique=true` is present.

**Fix:**
```julia
@test any(occursin("name", idx) for idx in indices[!, :name])
# or assert count:
@test nrow(indices) >= 2   # at least one user-defined index beyond the PK
```

---

### 3. Phase 11 (dry_run) — shallow SQL assertions
`total_statements > 0` is trivially true after any model addition. The test
should verify the SQL plan actually references the new table.

`DryRunResult` is the structured preview returned by `dry_run(...)`.
It does not execute SQL or modify files. It summarizes exactly what the
pending migration would do if `migrate(...)` were called.

Fields:
- `version::String`: generated migration version identifier for this preview
- `name::String`: migration name label used for the preview
- `checksum::String`: SHA-256 checksum of the ordered SQL payload
- `statements::Vector{String}`: full ordered SQL statements that would be executed
- `destructive_statements::Vector{String}`: subset of `statements` classified as destructive
- `is_destructive::Bool`: whether any destructive statement was detected
- `total_statements::Int`: total number of ordered SQL statements

Testing implication:
- Assert on `result.statements` when validating that a specific table or action
  appears in the generated plan.
- Assert on `result.destructive_statements` and `result.is_destructive` when
  validating the destructive guard.
- Assert on `result.checksum` and `result.total_statements` only as secondary
  integrity checks, not as proof that the correct schema change was generated.

**Fix:**
```julia
@test any(occursin("dryruntable", lowercase(s)) for s in result.statements)
```

---

### 4. Connection leaks on test failure
`acquire_connection` / `release_connection` pairs have no `try/finally`
protection. An `@test` failure that throws leaves the connection unreleased,
poisoning subsequent phases (and potentially locking the SQLite file).

**Fix pattern:**
```julia
conn = PormG.ConnectionPool.acquire_connection(edge_settings.connections)
try
  columns = SQLite.columns(conn, "migrationtest") |> DataFrame
  @test "fullname" in columns.name
  @test !("name" in columns.name)
finally
  PormG.ConnectionPool.release_connection(edge_settings.connections, conn)
end
```

Apply this pattern to phases 1–10 (any phase that calls `acquire_connection`).

---

### 5. Accumulated state fragility across phases
Phases 4 → 5 → 6 → 7 build on each other without intermediate resets. A
failure in phase 5 leaves the DB with an unknown schema for phases 6 and 7,
making failure diagnosis hard and failure messages misleading.

**Fix:** At the start of phases that depend on a specific prior schema state,
assert the assumed baseline explicitly:
```julia
# Phase 6 depends on phase 4's schema: assert secondtable still exists
conn = PormG.ConnectionPool.acquire_connection(edge_settings.connections)
try
  tables = SQLite.tables(conn) |> DataFrame
  @assert "secondtable" in tables.name "Phase 6 requires secondtable from phase 4"
finally
  PormG.ConnectionPool.release_connection(edge_settings.connections, conn)
end
```
If the assert fires, the failure message points at the broken phase, not the
current one. This replaces silent cascade failures with an explicit triage
message.

---

### 7. `write_test_models` will overwrite `db_2/models.jl` if naively ported
The current `write_test_models` helper writes to `db_test_migration/models.jl`.
If PostgreSQL Phase C were wired directly to `db_2/`, calling
`makemigrations("db_2", ...)` would destroy the real F1 integration models.

**Decision:** Create a dedicated folder `test/integration/db_test_migration_pg/`
containing only a `connection.yml` that points at the same server/database as
`db_2` (`pormg_teste`). The test writes and overwrites `models.jl` inside that
folder freely. `db_2/models.jl` is never touched.

At the end of the suite:
- Delete `db_test_migration_pg/models.jl` (test-generated, not committed)
- Delete `db_test_migration_pg/migrations/` (test-generated, not committed)
- Keep `db_test_migration_pg/connection.yml` (committed, permanent)
- Add `test/integration/db_test_migration_pg/models.jl` and
  `test/integration/db_test_migration_pg/migrations/` to `.gitignore`

This mirrors the SQLite approach exactly. The only difference is that the
SQLite Phase C can delete and recreate the folder itself (temp file); the
PostgreSQL Phase C keeps the folder but resets the DB schema between phases
with `DROP SCHEMA public CASCADE; CREATE SCHEMA public;`.

---

### 8. `DryRunResult` struct design — redundant fields encourage shallow testing
The current struct in `src/migrations/runner.jl` has two fields that are pure
derivations of others:
- `is_destructive::Bool` is always `!isempty(destructive_statements)` — it adds
  no information, and having it as a separate field makes it easy to write
  `@test result.is_destructive == true` without ever checking what the actual
  destructive SQL is.
- `total_statements::Int` is always `length(statements)` — this is exactly why
  `@test result.total_statements > 0` is a weak assertion: the redundant field
  actively encourages proving nothing.

Two additional fields have no testable semantics in a dry-run context:
- `version::String` is generated at call time. Calling `dry_run` twice on the
  same pending file produces two different versions. Since `dry_run` never
  commits anything, this version means nothing here — it belongs only on the
  applied migration record in `pormg_migrations`.
- `name::String` always defaults to `"pending_migration"` and is not informative.

**Proposed minimal struct:**
```julia
struct DryRunResult
  checksum::String
  statements::Vector{String}
  destructive_statements::Vector{String}
end
```
`is_destructive` and `total_statements` become trivial computed properties:
```julia
is_destructive(r::DryRunResult) = !isempty(r.destructive_statements)
total_statements(r::DryRunResult) = length(r.statements)
```
`version` and `name` are dropped from the preview entirely and remain only
on the history record written by `migrate()`.

**Impact on tests:** Phase 11 and Phase 12 assertions become more precise by
default because the only available fields are the substantive ones.

**Files to change:**
- `src/migrations/runner.jl` — update struct, update `DryRunResult(...)` constructors
  at lines ~437, ~619, ~697, update `Base.show`
- `src/Migrations.jl` — no export change needed if the type name is kept
- `test/integration/test_migration_bootstrap.jl` — update Phase 11/12 assertions

---

### 6. PostgreSQL gap — zero migration edge-case coverage
All 13 phases are SQLite-only. This means every schema evolution scenario
(add/drop field, FK, types, rename, destructive guard) is untested against
PostgreSQL in CI.

**Path to PostgreSQL Phase C:**

Blockers:
- `SQLite.tables`, `SQLite.columns`, `PRAGMA index_list` are SQLite-specific.
- `Generator.create_db_folder_and_yml` generates PostgreSQL YAML but does NOT
  create the database — a scratch DB must exist first.
- Migration introspection is hardcoded to `table_schema = 'public'` in
  `src/migrations/runner.jl`, so non-public schemas are not an isolation option.

Required work:
1. Add adapter-neutral introspection helpers to `common_migration_setup.jl`:
   - `table_exists(settings, table_name) → Bool`
   - `column_names(settings, table_name) → Vector{String}`
   - `column_nullable(settings, table_name, col_name) → Bool`
   - `index_names(settings, table_name) → Vector{String}`
2. PostgreSQL provisioning: for the current project stage, it is acceptable
  to reuse `test/integration/db_2/connection.yml` and the disposable
  `pormg_teste` database for destructive migration cycling, because the DB is
  already reserved for tests only and there is no concurrent usage.
  Reset it with `DROP SCHEMA public CASCADE; CREATE SCHEMA public;` between
  phases.
  Future direction: split this into a dedicated PostgreSQL scratch config
  (for example `test/integration/db_test_migration_pg/`) once CI, parallel
  execution, or multiple contributors make environment isolation necessary.
3. Remove the `if adapter_name == "SQLite"` outer guard and replace SQLite-API
   calls with the adapter-neutral helpers.
4. Document clearly that PostgreSQL Phase C owns the whole `public` schema of
  `pormg_teste` during execution and is expected to destroy and recreate it
  repeatedly. This is acceptable now, but must be revisited if the database
  starts being shared.

---

## Recommended Implementation Order

1. Refactor `DryRunResult` struct (issue 8) — do this first so the test
   assertion fixes in step 2 are written against the clean struct.
2. Fix assertions in phases 5, 7, 11 (quick wins, no structural change).
3. Wrap all `acquire_connection` calls in `try/finally` (safety, phases 1–10).
4. Add baseline `@assert` guards to phases that depend on prior phase state (issue 5).
5. Create `test/integration/db_test_migration_pg/connection.yml` pointing at
   `pormg_teste`; add generated files to `.gitignore`.
6. Implement adapter-neutral introspection helpers in `common_migration_setup.jl`.
7. Implement `write_test_models_pg` that writes to `db_test_migration_pg/models.jl`.
8. Expand Phase C to run against both adapters, sharing the same phase structure
   but dispatching introspection calls through the adapter-neutral helpers.
