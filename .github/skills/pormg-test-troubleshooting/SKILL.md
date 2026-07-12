---
name: pormg-test-troubleshooting
description: Diagnose and mitigate failing, flaky, or environment-dependent PormG tests (unit + integration, PostgreSQL + SQLite) — pool exhaustion, backend divergence, fixture isolation, aliasing bugs. Read when a test is red and the cause isn't an obvious code regression.
---

# PormG Test Troubleshooting

## Purpose

Use this skill when a test fails and it isn't immediately clear whether that's a real regression
in the change you're making, or an environment/infrastructure issue the repo has hit before.
It captures recurring failure classes and how they were diagnosed and fixed previously, so you
don't have to rediscover them from a cold start.

This skill is about **diagnosing failures**, not writing new tests — see
[`test-writing.md`](../../instructions/test-writing.md) for `@testset` conventions. Once you've
root-caused a failure to a specific subsystem, hand off to the matching subsystem skill
(`pormg-querybuilder-internals`, `pormg-migrations-development`, `pormg-public-api-development`)
for the fix itself.

## Use This Skill For

- A test that fails locally but the change looks unrelated to what it's testing
- A test that only fails under `-t auto`, only against PostgreSQL, or only against SQLite
- A test that fails intermittently (passes on rerun) rather than deterministically
- Deciding whether a failure is a real regression before spending time on a fix

## Test layout & how to run a narrow slice

- `test/runtests.jl` — unit suite (`julia --project=. test/runtests.jl`). No live DB required;
  SQLite `:memory:` only. This is what CI (`.github/workflows/CI.yml`) runs — integration tests are
  **not** part of CI, they're local/dev-only.
- `test/integration/runtests.jl` — phased integration suite against a live DB (migration bootstrap
  → fixture seeding → behavioral tests → advanced features → internals/security). Run via
  `test/runtests.jl` with `PORMG_INTEGRATION_TESTS=true`, or directly.
- Always run the **narrowest relevant file** first (e.g.
  `julia --project=. test/unit/test_order_by_nulls.jl`), and only broaden to the full suite once
  it's green — this repo's other skills all specify this same narrow-first order.

Environment variables that change test behavior:

| Var | Effect |
|-----|--------|
| `PORMG_DB` | Selects the integration DB folder: `db_2` (PostgreSQL, default) or `db_sl` (SQLite) |
| `PORMG_INTEGRATION_TESTS` | `true` makes `test/runtests.jl` also run the integration suite |
| `PORMG_TEST_POOL_SIZE` | Pre-sizes the PostgreSQL pool for the run (default `20`); see #37 below |
| `PORMG_INFILTRATOR` | Rewires `@pormg_debug` to a live `Infiltrator.@infiltrate` breakpoint (non-interactive runs ignore this) |

Threading: PostgreSQL integration tests are meant to run under `julia -t auto`. **SQLite does not
tolerate `-t auto` well** — run `db_sl` integration tests with `-t 1`
(`test/integration/common_setup.jl` documents this directly above the connection setup).

```powershell
# Unit suite (CI-equivalent)
julia --project=. test/runtests.jl

# Unit suite against SQLite instead of the default backend assumptions
$env:PORMG_DB="db_sl"; julia --project=. test/runtests.jl

# Full integration suite, PostgreSQL
julia -t auto --project=. test/integration/runtests.jl

# Full integration suite, SQLite (single-threaded)
$env:PORMG_DB="db_sl"; julia -t 1 --project=. test/integration/runtests.jl

# Everything, via the unit entrypoint's opt-in integration block
$env:PORMG_INTEGRATION_TESTS="true"; julia -t auto --project=. test/runtests.jl
```

## Known recurring failure classes

### PostgreSQL connection pool exhaustion (#37)

**Symptom:** integration run against PostgreSQL hangs or throws under concurrency (`-t auto`),
especially against a remote/higher-latency DB; historically a busy-retry loop logging heavily,
now a typed `PoolTimeoutError` (`src/ConnectionPool.jl`).

**Cause:** default pool size is small; the pool lazily expands up to
`pool_size * POOL_EXPANSION_FACTOR` (`POOL_EXPANSION_FACTOR = 10`) before acquisition gives up.
Under high fan-out this ceiling can still be reached.

**Mitigation:** `test/integration/common_setup.jl` pre-sizes the pool from
`PORMG_TEST_POOL_SIZE` (default `20`) — raise it for a heavier run. If you hit a genuine
`PoolTimeoutError`, that's a sizing/contention symptom, not a connection leak (every
`fetch_async` in `src/` is awaited/released). Regression coverage:
`test/unit/test_connection_pool_timeout.jl`.

### PostgreSQL vs SQLite backend divergence

**Symptom:** a test passes on one backend and fails on the other with no logic change.

**Cause:** SQL rendering differences the two dialects don't (yet) normalize — e.g. `ORDER BY` NULL
placement diverges without explicit `NULLS FIRST/LAST` handling (#75, see
`test/unit/test_order_by_nulls.jl`), and datetime/sequence handling differ by backend
(`test/integration/test_sqlite_datetime_normalize.jl`, `test/unit/test_sequence_sync.jl`).

**Mitigation:** before assuming a logic regression, check `src/Dialect.jl` for backend-specific
rendering of the clause involved, and run the same test against **both** `db_2` and `db_sl` to
confirm the divergence is backend-specific rather than a general bug.

### Migration fixture isolation / credential leakage (#36)

**Symptom:** migration-related tests behave differently depending on who runs them, or touch a
shared database unexpectedly.

**Cause:** a migration test fixture pointed at the shared `pormg_teste` database, or a
`connection.yml` carried real credentials.

**Mitigation:** the committed fixture `test/integration/db_test_migration_pg/connection.yml` is
credential-free (hydrated in-memory at runtime) and points at a dedicated, disposable database —
never the shared one. `test/unit/test_migration_pg_fixture.jl` is a deterministic, DB-free guard
that fails the build if this regresses; if you're adding a new migration fixture, follow the same
pattern.

### Intermittent failures after `.copy()` / chained query mutation (#43, #112)

**Symptom:** a test fails only sometimes, or only after a preceding test in the same file mutated
a query object — classic shared-mutable-state symptom, not a real race.

**Cause:** `QueryBuilder` objects have previously leaked shared references across `.copy()` (e.g.
custom-join state aliasing the original — #112) instead of deep-copying per-instance state.

**Mitigation:** when a failure looks intermittent or order-dependent rather than deterministic,
suspect aliasing in the object being mutated before suspecting a race. See
`test/unit/test_shared_state_readpath.jl` and `test/unit/test_custom_join_copy.jl` for the shape
of this failure class and how it was isolated.

### False regression from two sessions/worktrees sharing one live database

**Symptom:** an integration test fails with data that doesn't match what the test just seeded, or
a `DELETE`/schema-migration step trips over rows another process put there — while working in a
git worktree alongside another Claude Code session (or any other process) also running the
PostgreSQL integration suite.

**Cause:** both processes point at the same live `db_2` database at the same time; the suite isn't
designed to be safe under concurrent external writers.

**Mitigation:** rule this out first — rerun the failing test alone with nothing else touching the
same database — before treating it as a real bug. If you're routinely running parallel sessions,
point one at a separate database/schema instead of debugging phantom failures.

## Diagnostic workflow

1. Reproduce with the narrowest failing test file, run alone (not the full suite).
2. Confirm whether it fails on both backends (`PORMG_DB=db_2` and `PORMG_DB=db_sl`) or only one —
   a single-backend failure points at `Dialect.jl`, not general logic.
3. Check thread count and pool size if it's a PostgreSQL integration failure — rerun with
   `-t 1` and a larger `PORMG_TEST_POOL_SIZE` to see if it's contention-shaped.
4. Check whether anything else (another session, another worktree) is running integration tests
   against the same live database right now.
5. Rerun the same narrow test 2-3 times — deterministic failure vs. intermittent failure points to
   different classes above.
6. Only once the failure survives all of the above in isolation, treat it as a real regression and
   move to the relevant subsystem skill for the fix.

## Anti-Patterns

- Do not weaken an assertion or a model/field contract just to make a flaky test pass — normalize
  the fixture/setup instead (already the rule in `test-writing.md`; it applies doubly here since a
  weakened assertion hides the next real regression).
- Do not add blind retries or `sleep`-based waits to paper over a suspected race — root-cause it
  via the workflow above first; a retry that "fixes" a test without understanding why is usually
  masking a real shared-state bug (see #43/#112 above).
- Do not silently bump timeouts or pool sizes without noting why in a comment — future runs need
  to know whether that number reflects real capacity planning or a guess.
- Do not conclude "flaky test, ignore it" — every flakiness class found in this repo so far has
  had a deterministic root cause and a regression test once actually investigated.

## Verification Commands

```powershell
julia --project=. test/runtests.jl
$env:PORMG_DB="db_sl"; julia --project=. test/runtests.jl
julia -t auto --project=. test/integration/runtests.jl
$env:PORMG_DB="db_sl"; julia -t 1 --project=. test/integration/runtests.jl
```
