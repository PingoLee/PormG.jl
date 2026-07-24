# Upgrading PormG — consumer-app rollout log

Tracks **breaking / behavior changes in PormG** that require source-code changes in the internal apps that depend on it. PormG is pre-publish (single maintainer, ~4 internal apps, no external users), so breaking changes are intentional and cheap on the *PormG* side — but each one still has to be rolled out by hand in every consuming app. This file is that rollout checklist.

> ⚠️ **Not database migrations.** This file is about migrating **app source code** to keep up with the PormG API. It is unrelated to the `makemigrations` / `migrate` schema engine that manages your database tables.

## How to use

- One `##` entry per breaking change, **newest first**.
- Each entry records: the PormG **version** it shipped in, what changed, why, the concrete **before → after** code edit, and a **per-app rollout** table.
- An app is done when its code is updated **and** its tests pass against the new PormG.
- Rename the placeholder app rows (`app-1` … `app-4`) to your real app names once, then reuse them in every entry.

### Status legend

| Mark | Meaning |
|------|---------|
| ✅ | migrated — app updated and green |
| ⏳ | pending — not yet migrated |
| — | n/a — app does not use the affected API |

## Versioning (`0.y.z`)

PormG follows `0.y.z` pre-publish: **`y` bumps on any breaking/behavior change**, `z` on
everything else. Julia's Pkg treats the `y` slot as the major version pre-1.0, so a
consumer's `compat = "0.y"` accepts `0.y.*` and rejects the next breaking release. Each
breaking change therefore bumps `version` in `Project.toml` **and** adds one entry here,
stamped with the version it shipped in.

**Scoping an upgrade by version.** To roll a consuming app from PormG `0.a` to `0.b`, read
the entries **newest-first from the top and stop when you reach an entry whose `Version` is
≤ `0.a`** — everything above that line is what changed since your pinned version. Entries
are version-stamped from **`0.2.0`** onward; entries below the `pre-0.2 history` marker
predate the versioning policy and are unstamped (treat them as "already shipped before
`0.2.0`").

## Applying these in a consuming app

This file is the **source of truth, kept in the PormG repo**. To fix a dependent app after a
PormG bump, point an agent (or yourself) at this file — read it from the dev'd source
(e.g. `~/.julia/dev/PormG/UPGRADING.md`) or from GitHub — and work the entries
**newest first**:

1. **Scope to this app — and to your version.** Read newest-first and stop at the first entry
   whose **Version** is ≤ the PormG you are upgrading *from* (see the Versioning section above);
   everything above that line is what changed. Within each in-range entry's rollout table, skip
   rows already marked ✅ or —, and work only the ⏳ rows for this app.
2. **Find the call sites.** Run the entry's *"How to find the calls to migrate"* grep/error
   inside the app.
3. **Apply the `before → after`.** Edit each call site to the ✓ form shown in the entry.
4. **Verify.** Run the app's own test/integration suite against the upgraded PormG. An entry
   is done for this app only when its code is updated **and** its tests pass.
5. **Record it.** Flip this app's cell in that entry's rollout table to ✅ (or — if the app
   never used the affected API), and commit the table update back to PormG so the next app
   sees accurate state.

> **Tip — make it discoverable.** Add one line to each app's `AGENTS.md`/`CLAUDE.md`:
> *"Before bumping the PormG dependency, apply any ⏳ rows in `PormG/UPGRADING.md` for this app."*
> Then an agent working in that repo will pick up the rollout automatically.

---

## `first()` / `get()` no longer mutate the handler (#199)

- **Version**: 0.2.3
- **PormG ref**: issue #199 ; `src/querybuilder/execution.jl` (`first`, `get`),
  `docs/src/read/index.md` (new *Handler Mutation Model* section)
- **Recorded**: 2026-07-24
- **Severity**: footgun fix — **no action expected**. Classified non-breaking: the only affected
  code exploits `first()`'s documented limit-leak workaround or `get()`'s *undocumented*
  filter-persistence side effect.

### What changed

All read terminals now share one contract: they execute on an internal copy and never mutate the
handler. Previously `first()` permanently set `limit(1)` on the handler and `get(q, filters...)`
permanently appended its inline filters to it — `count`/`exists`/`list` already copied. Re-call
semantics of chain methods are unchanged (and now documented): `filter` accumulates,
`values`/`order_by` replace their previous call.

```julia
# ✗ before — handler reuse after first()/get() silently carried leaked state:
q = M.Driver.objects.filter("nationality" => "British")
q.first()                                # left limit=1 on q
q.list()                                 # returned 1 row (leaked limit)
q.update("nationality" => "English")     # threw: UPDATE with LIMIT is not supported

r = M.Result.objects
r.get("resultid" => 1)                   # appended the inline filter to r
r.count()                                # counted WHERE resultid = 1 (leaked filter)

# ✓ after — the handler is untouched; same calls, no leaked state:
q.first()                                # q unchanged (limit stays 0)
q.list()                                 # all matching rows
q.update("nationality" => "English")     # valid on the same handler

r.get("resultid" => 1)                   # r unchanged
r.count()                                # counts ALL results
```

### How to find the calls to migrate

Nothing to migrate unless an app **reuses a handler after** `.first()`/`.get()` *and relies on the
leaked state* (a limit-1 `list()`, or inline `get` filters narrowing later calls). Grep each app for
a handler variable used again after one of these terminals:

```
rg -n '\.(first|get)\(' <app>/src        # then eyeball: is that handler variable used again below?
```

One-handler-per-query code (the documented style) is unaffected.

### Per-app rollout

| App | Status | Notes |
|-----|--------|-------|
| app-1 | ⏳ | grep to confirm no handler reuse relies on leaked state, then mark ✅/— |
| app-2 | ⏳ | same check |
| app-3 | ⏳ | same check |
| app-4 | ⏳ | same check |

---

## Raw-SQL manual params: `fetch` / `fetch_async` accept a values array (#218)

- **Version**: 0.2.2
- **PormG ref**: issue #218 (follow-up to #198) ; `src/ConnectionPool.jl` (`fetch` / `fetch_async`),
  `docs/src/async.md`
- **Recorded**: 2026-07-23
- **Severity**: new feature — **additive, non-breaking**. Existing collector / `nothing` / no-param
  calls are unchanged; a plain array that previously raised `MethodError` now binds.

### What changed

The low-level raw-SQL escape hatch (`fetch` / `fetch_async(settings, sql; params=…)`) now accepts a
plain values **array or tuple** — the previously internal-only `params` slot was typed
`Union{Nothing, AbstractPormGParam}` (an ORM collector a user could not construct), so raw SQL had no
public value-binding path. You write the placeholder your backend uses — `$1, $2, …` on PostgreSQL,
`?` on SQLite — and PormG performs **no** placeholder translation (the Go `database/sql` / Python
DB-API / Julia `DBInterface` convention: raw means native). A NULL is `missing`; a bare `nothing` is
normalized to it. The array bypasses the ORM field formatters (datetime/float/bool coercion), which is
expected for a raw hatch. Portable queries still belong on the ORM surface.

```julia
# ✗ before — a user value in raw SQL could only be string-interpolated (a SQL-injection hole)…
fetch(settings, "SELECT count(*) FROM driver WHERE nationality = '$(nat)'")
# …or expressed through the ORM surface:
M.Driver.objects.filter("nationality" => nat).count()

# ✓ after — bind it, with the backend-native placeholder:
fetch(settings, "SELECT count(*) FROM driver WHERE nationality = \$1", [nat])   # PostgreSQL
fetch(settings, "SELECT count(*) FROM driver WHERE nationality = ?",  [nat])    # SQLite
```

### How to find the calls to migrate

Nothing to migrate — additive. **Optional adoption:** grep each app for a raw `fetch` / `fetch_async`
whose SQL string interpolates a value (a SQL-injection risk) and move the value into the array:

```
rg -n 'fetch(_async)?\(' <app>/src | rg '\$\('     # raw fetch with $(...) interpolation
```

### Per-app rollout

| App | Status | Notes |
|-----|--------|-------|
| app-1 | ⏳ | optional — replace interpolated raw `fetch`/`fetch_async` SQL with the values array |
| app-2 | ⏳ | optional |
| app-3 | ⏳ | optional |
| app-4 | ⏳ | optional |

---

## Typed exceptions across the query surface — raw-`String` throws are now `ArgumentError`/`ErrorException` (#197)

- **Version**: 0.2.0
- **PormG ref**: issue #197 ; `src/querybuilder/` (`build_helpers.jl`, `build_joins.jl`, `build_query.jl`,
  `ctes.jl`, `deletion.jl`, …), `src/Configuration.jl`, `src/migrations/planner.jl`
- **Recorded**: 2026-07-23
- **Severity**: **breaking (error type)** — ~46 raw-string `throw("...")` sites now raise typed
  exceptions. No new exported types (existing `ArgumentError`/`ErrorException` +
  `DoesNotExist`/`MultipleObjectsReturned`/pool errors cover the surface).

### What changed

Every `throw("...")` in the query builder — a bare `String`, which is **not** an `Exception` — plus
stragglers in `Configuration.jl` and `migrations/planner.jl` now throws a typed exception:

- `ArgumentError` for user misuse (bad args, unsupported `values()` pairs, malformed lookups, …);
- `ErrorException` (via the internal `_unsupported_conn` helper) for internal dispatch fallbacks;
- `bulk_insert`'s catch blocks now `@error` + `rethrow()`, so the original driver exception survives
  instead of being reduced to a string.

A raw `String` throw escaped every `catch e; e isa Exception` a package user could write — so any
error handling that expected a real exception silently failed to match. Now `e isa Exception` (and
`e isa ArgumentError`) behave as expected.

### How to find the calls to migrate

Grep each app for `catch` blocks that **string-match** a PormG error rather than catching a type:

```
rg -n "catch" <app>/src | rg -iE "isa String|occursin\("
```

Only handlers that string-matched a PormG throw are affected. A `catch e … rethrow()`, or a handler
already keyed on `ArgumentError`/`ErrorException`/`DoesNotExist`/`PoolTimeoutError`, needs no change.

### Migrate your app

```julia
# ✗ before — the throw was a bare String; `e isa String` was the only way to match, and
#            `e isa Exception` never fired
catch e
    e isa String && occursin("<PormG error text>", e) && handle()

# ✓ after — catch the typed exception; read the text off `.msg`
catch e
    e isa ArgumentError && occursin("<PormG error text>", e.msg) && handle()
```

If a handler only needs "PormG rejected this call", `e isa Exception` (or the narrower
`e isa ArgumentError`) now suffices — no string matching required.

### Per-app rollout

| App | Status | Notes |
|-----|--------|-------|
| app-1 | ⏳ | check for `catch` blocks string-matching PormG throws; most apps have none |
| app-2 | ⏳ | as above |
| app-3 | ⏳ | as above |
| app-4 | ⏳ | as above |

---

<!-- ───────────────────────── pre-0.2 history (unstamped) ───────────────────────── -->

## Scalar correlated subqueries: `Subquery(...)` in `values()`; unsupported `values()` pairs now throw (#92)

- **PormG ref**: issue #92 (the supported fix for the #74 fan-out guard) ; `src/querybuilder/types.jl`,
  `src/querybuilder/object_manager.jl`, `src/querybuilder/build_query.jl`, `src/querybuilder/build_helpers.jl`,
  `src/QueryBuilder.jl`, `src/PormG.jl`
- **Recorded**: 2026-07-22
- **Severity**: **additive feature + one latent-bug fix to check.** New top-level export `Subquery`;
  `Exists(...)` is now also projectable in `values()`. The check: `values()` used to **silently drop** an
  unsupported `"alias" => <value>` pair — that column just vanished from the result. It now throws an
  `ArgumentError`. Only code that was already getting a wrong/missing column is affected.

### What changed

- **New:** `"alias" => Subquery(inner)` inside `values()` projects a scalar correlated subquery as a
  column. The inner query correlates via `OuterRef(...)` and must project exactly **one** column; an
  aggregate (`Count`, `Sum`, …) or a plain column with `order_by` + `limit(1)` both work. This is the
  fan-out-safe way to attach related-set aggregates — the construct the #74 guard's error message points
  to. Multiple independent `Subquery` columns compose in one query with no fan-out interaction.
- **New:** `"alias" => Exists(inner)` inside `values()` projects a per-row boolean column (SQLite `0`/`1`,
  PostgreSQL booleans). Previously `Exists` was filter-only.
- **Fail-loud fix:** an unsupported right side in a `values()` pair (e.g. `"x" => 42`, or any type the
  projection doesn't handle) now raises `ArgumentError` at `values()` time instead of being silently
  dropped from the SELECT list. Likewise, a **function pair that fails validation** (e.g.
  `"x" => Concat("surname", 42)` — constructs, but `_check_function` rejects the `Int`) used to be
  logged and silently dropped; it now propagates the original error (typically a `MethodError`) after
  logging the failing alias.
- Guard rails: the inner query must project exactly one column (else `ArgumentError`); the alias is
  mandatory (bare `Subquery(...)` throws); a `Subquery`/`Exists` projected *inside another subquery*
  throws (`OuterRef` resolves one level only); a non-aggregate inner with no `LIMIT` emits a build-time
  `@warn` (possible multi-row scalar).

### How to find the calls to migrate

Nothing to migrate for the new feature (additive). For the silent-drop fix, look for `values()` pairs whose
right side is not a field name, SQL function, `Value(x)`, `Subquery(...)`, or `Exists(...)`:

```
rg -n 'values\(' <app> | rg '=>'      # then eyeball non-standard right-hand sides
```

An affected call site was already broken (the column silently missing from results) — the throw makes it
visible.

### Migrate your app

- Nothing required. Optionally adopt `Subquery` where an app worked around the #74 guard with a
  CTE-aggregate join that only needed one scalar per row.

### Per-app rollout

| App | Status | Notes |
|-----|--------|-------|
| app-1 | ⏳ | additive; check for `values()` pairs relying on the old silent drop (unlikely) |
| app-2 | ⏳ | as above |
| app-3 | ⏳ | as above |
| app-4 | ⏳ | as above |

---

## `migrate()` is non-interactive-safe — throws `DestructiveMigrationError` in CI instead of hanging (#87)

- **PormG ref**: issue #87 ; `src/migrations/runner.jl`, `src/Migrations.jl`
- **Recorded**: 2026-07-21
- **Severity**: **behavior change (automation only)** — new exported `DestructiveMigrationError`. Affects
  only code that calls `migrate()` in a **non-interactive** context (CI, `Pkg.test`, deploy/cron script,
  piped stdin). Interactive `migrate()` at a real terminal is unchanged.

### What changed

`migrate()` defaulted `interactive=true` and called a bare `readline()` to confirm — with **no TTY
detection**. In a non-interactive process that either **hung** on stdin or read EOF and **silently applied
nothing** ("Migrations were not applied"). The safe-looking workaround `migrate(...; interactive=false,
destructive=true)` disabled *both* guardrails at once.

Now:

- The confirmation prompt shows **only when stdin is a real terminal** (`interactive && stdin isa
  Base.TTY`). `migrate()` never blocks on `readline()` in CI / `Pkg.test` / a deploy script.
- A **non-destructive** plan applies directly in a non-interactive context (previously a silent no-op).
- A **destructive** plan in a non-interactive context now **throws `DestructiveMigrationError`** (exported)
  unless `destructive=true` is passed — instead of silently returning `nothing`. Automation fails loudly
  with an actionable message.
- **Piped stdin** (`echo yes | julia … migrate("db")`) counts as non-interactive — it no longer bypasses
  the destructive gate; pass `destructive=true`.

Interactive terminal behavior is unchanged: you still get the yes/no prompt, and a destructive plan without
`destructive=true` still prints a red `@error` and aborts.

### How to find the calls to migrate

Grep each app for `migrate(` in automated contexts — CI steps, deploy/bootstrap scripts, anything run
without a TTY:

```
rg -n "migrate\(" <app>                 # focus on CI / deploy / cron entry points
rg -n "interactive\s*=\s*false" <app>
```

Two things to check at each non-interactive call site:

1. A `catch` / return-value check that assumed a destructive plan **silently returns `nothing`** — it now
   throws `DestructiveMigrationError`.
2. A call that passed `interactive=false` only to avoid a hang — that is now optional (auto-detected), but
   harmless to keep.

### Migrate your app

- Automated apply of a plan that *may* be destructive: pass the explicit opt-in —
  `migrate("db"; destructive=true)`. CI no longer hangs, and a missing opt-in is now a loud error, not a
  silent skip.
- If a script must tolerate "destructive plan present → skip, don't fail", catch it:
  ```julia
  try
      migrate("db")
  catch e
      e isa PormG.Migrations.DestructiveMigrationError || rethrow()
      @warn "Destructive migration skipped; apply manually with destructive=true" exception=e
  end
  ```
- Non-destructive automated migrations need no change — `migrate("db")` now applies them instead of
  silently no-op'ing.

### Per-app rollout

| App | Status | Notes |
|-----|--------|-------|
| app-1 | ⏳ | check CI/deploy scripts calling `migrate()`; destructive plans now throw `DestructiveMigrationError` |
| app-2 | ⏳ | as above |
| app-3 | ⏳ | as above |
| app-4 | ⏳ | as above |

---

## Connect fast-fail (`PoolConnectError`, `fail_fast_on_connect`)

- **PormG ref**: issue #72 (AC2; follow-up to #37/#124) ; `src/ConnectionPool.jl`, `src/Configuration.jl`,
  `src/Backend.jl`, `ext/PormGLibPQExt.jl`, `ext/PormGSQLiteExt.jl`, `src/PormG.jl`
- **Recorded**: 2026-07-18
- **Severity**: **mostly additive** (new exported `PoolConnectError`, opt-in `fail_fast_on_connect`, default
  on). **One behavior change to check:** an unopenable pool now raises `PoolConnectError`, not
  `PoolTimeoutError`. Only apps that *catch `PoolTimeoutError` specifically* around a connection failure
  need a look.

### What changed

`acquire_connection` used to treat "can't open a connection" (bad password, missing role/database,
unopenable SQLite path) the same as "healthy pool saturated": it waited the full `pool_timeout` (~30 s),
then threw `PoolTimeoutError` ("raise pool_size"). It now:

- **classifies** the driver error via a new backend hook (`backend_is_permanent_connect_error`): permanent
  = PostgreSQL auth / missing role|database, SQLite `unable to open database file`;
- **fast-fails** a permanent error immediately with a new catchable **`PoolConnectError`** (exported)
  carrying the driver `cause` + a redacted connection string (remedy: fix credentials, not `pool_size`);
- surfaces `PoolConnectError` (not `PoolTimeoutError`) for *any* connect failure that reaches the deadline,
  including ambiguous host/DNS errors (which are still waited out, not fast-failed);
- adds a `fail_fast_on_connect` config key (`connection.yml` + `register_connection` kwarg; default `true`)
  to opt out;
- (fix) redacts the connection string in SQLite pool logs, matching the PostgreSQL path.

A healthy-but-saturated pool still raises `PoolTimeoutError` — unchanged.

### How to find the calls to migrate

Grep each app for a `catch` that special-cases pool saturation on a connection acquire/fetch:

```
rg -n "PoolTimeoutError" <app>/src
```

If a handler means "the database is unreachable / misconfigured", widen it to also catch
`PoolConnectError` (or catch both). If it only means "pool is saturated, back off and retry", leave it —
`PoolConnectError` is intentionally a *different*, non-retryable signal.

### Per-app rollout

| App | Status | Notes |
|-----|--------|-------|
| app-1 | — | check for `catch PoolTimeoutError` around acquire/fetch; else additive |
| app-2 | — | — |
| app-3 | — | — |
| app-4 | — | — |

---

## Pool metrics (`pool_stats`) + leak detection (`leak_detection_threshold`)

- **PormG ref**: issue #127 (follow-up to #37) ; `src/ConnectionPool.jl`, `src/Configuration.jl`, `src/PormG.jl`
- **Recorded**: 2026-07-16
- **Severity**: new feature — **additive, opt-in**. **No action needed**; `pool_stats` is a new exported
  name, and leak detection is off unless configured.

### What changed

Two observability additions to the connection pool:

- **`pool_stats`** (newly exported) — a health snapshot `(; pool_size, size, in_use, available, ceiling, waiting)`.
  Call it with a pool object or a connection key: `pool_stats("db")`.
- **`leak_detection_threshold`** in `connection.yml` (seconds; `0`/absent = off) — warns once when a
  connection is held past the threshold without release (a likely un-awaited `fetch_async`):

  ```yaml
  dev:
    adapter: PostgreSQL
    database: 'formula1'
    pool_size: 10
    leak_detection_threshold: 30
  ```

  `Configuration.register_connection` accepts the same `leak_detection_threshold` kwarg. Internally, #125's
  reaping state was generalized into a shared `PoolMonitorState` (leak detection reuses the existing
  per-slot checkout timestamps) — no behavior change to reaping.

### How to find the calls to migrate

Nothing to grep — purely additive. `pool_stats` is a *new* name; it can only collide if a downstream app
already defined its own top-level `pool_stats` (unlikely). **Optional adoption:** set
`leak_detection_threshold` in long-lived services to catch un-released connections early.

### Per-app rollout

| App | Status | Notes |
|-----|--------|-------|
| app-1 | — | optional — set leak_detection_threshold; use pool_stats when debugging saturation |
| app-2 | — | — |
| app-3 | — | — |
| app-4 | — | — |

---

## Configurable pool acquire timeout (`pool_timeout`)

- **PormG ref**: issue #126 (follow-up to #37) ; `src/ConnectionPool.jl`, `src/Configuration.jl`
- **Recorded**: 2026-07-16
- **Severity**: new feature — **additive, opt-in**. **No action needed**; zero behavior change unless
  `pool_timeout` is set.

### What changed

The connection-pool acquire timeout was only reachable as a per-call kwarg
(`acquire_connection(pool; timeout_seconds=…)`), which normal ORM users never touch. You can now set a
default per pool in `connection.yml` (seconds; fractional allowed; absent = the historical 30 s):

```yaml
dev:
  adapter: PostgreSQL
  database: 'formula1'
  pool_size: 10
  pool_timeout: 5      # give up after 5s waiting for a connection → PoolTimeoutError
```

Stored on the pool struct and used as the default in `acquire_connection`; an explicit per-call
`timeout_seconds` still wins. `Configuration.register_connection` accepts the same `pool_timeout` kwarg.
A value `≤ 0` falls back to the 30 s default. See [Advanced Configuration](docs/src/configuration/advanced.md).

### How to find the calls to migrate

Nothing to grep — purely additive, off by default. **Optional adoption:** set `pool_timeout` in
`connection.yml` for services that should fail fast rather than block a request when the pool is saturated.

### Per-app rollout

| App | Status | Notes |
|-----|--------|-------|
| app-1 | — | optional — set pool_timeout to fail fast under saturation |
| app-2 | — | — |
| app-3 | — | — |
| app-4 | — | — |

---

## Idle-connection reaping + max-lifetime (opt-in)

- **PormG ref**: issue #125 (follow-up to #37) ; `src/ConnectionPool.jl`, `src/Configuration.jl`
- **Recorded**: 2026-07-16
- **Severity**: new feature — **additive, opt-in**. **No action needed**; zero behavior change unless
  `idle_timeout`/`max_lifetime` are set.

### What changed

The pool grows lazily under load (#37) but previously **never shrank** and reused connections
indefinitely. You can now opt a connection into reaping via `connection.yml` (seconds; `0`/absent = off):

```yaml
dev:
  adapter: PostgreSQL
  database: 'formula1'
  pool_size: 10
  idle_timeout: 60      # close overflow conns idle > 60s, back toward pool_size
  max_lifetime: 1800    # retire conns older than 30 min
```

A single background sweeper closes **overflow** connections (never the base `pool_size`, never an
in-use one) that sat idle past `idle_timeout` or exceeded `max_lifetime`; over-age overflow conns are
also retired on return. Reaping closes + clears the slot in place (append-only — #124's handoff and
#37's ceiling reasoning are unaffected). `Configuration.register_connection` accepts the same
`idle_timeout`/`max_lifetime` kwargs. See [Advanced Configuration](docs/src/configuration/advanced.md).

### How to find the calls to migrate

Nothing to grep — purely additive, off by default. **Optional adoption:** for long-lived services or
DBs/proxies that drop idle connections, set `idle_timeout`/`max_lifetime` in `connection.yml`.

### Per-app rollout

| App | Status | Notes |
|-----|--------|-------|
| app-1 | — | optional — set idle_timeout/max_lifetime for long-lived services |
| app-2 | — | — |
| app-3 | — | — |
| app-4 | — | — |

---

## Connection-pool wait is now direct-handoff (event-driven), not a busy-poll

- **PormG ref**: issue #124 (follow-up to #37) ; `src/ConnectionPool.jl`
- **Recorded**: 2026-07-16
- **Severity**: internal mechanism — **no action needed**. `acquire_connection`'s signature
  (`timeout_seconds`, `max_retries`, SQLite `mode`) and the `PoolTimeoutError` fields are unchanged.

### What changed

When the pool is saturated, `acquire_connection` used to `sleep(0.1)` and rescan (up to the
timeout/retry budget). It now **parks** the caller and is woken the instant a connection is
released — the returner hands the freed slot *directly* to the oldest compatible waiter (FIFO, no
barging; HikariCP / Go `database/sql` style). Handoff latency drops from up to ~100 ms to
sub-millisecond, waiters are served fairly, and there is no more per-100 ms rescan spam. A genuine
saturation still throws the same catchable `PoolTimeoutError`.

### Nothing to grep

No API changed. One **diagnostic** nuance: `PoolTimeoutError.attempts` now counts scan iterations
(typically `1` on a clean saturated timeout) rather than the old ~`timeout/0.1s` poll count. If you
log or assert on `attempts`, expect a much smaller number; it remains `>= 1`.

### Per-app rollout

| App | Status | Notes |
|-----|--------|-------|
| app-1 | — | internal pool change; no code edit |
| app-2 | — | — |
| app-3 | — | — |
| app-4 | — | — |

---

## Full-control custom joins via `cjoin_on` (#45)

- **PormG ref**: issue #45 ; `src/querybuilder/` (`ctes.jl`, `build_joins.jl`, `build_query.jl`, `build_helpers.jl`, `object_manager.jl`)
- **Recorded**: 2026-07-16
- **Severity**: new feature — **additive, non-breaking**. `cjoin`/`on` are unchanged.

### What changed

A new fluent method `cjoin_on` expresses a JOIN whose ON clause is entirely user-defined — arbitrary
boolean (top-level `OR`), field-to-field comparisons across **both** sides (self-joins), and SQL
functions in the ON — without raw SQL. `cjoin`/`on` still emit the equi-anchor and only allow
joined-model-side filters; `cjoin_on` emits **no** anchor.

```julia
query.cjoin_on("Lap"; alias="b2", join_type="INNER", on=[
  Qor(
    F("b2.raceid") == F("raceid"),                # F("b2.col") = joined copy; bare F = base
    Q(F("b2.driverid") == F("driverid"), F("b2.lap") == F("lap")),
    F("b2.dt__@year") == F("dt__@year"),          # year() in ON, dialect-aware
  ),
])
```

Renders `INNER JOIN "laps" AS "b2" ON ( … OR … OR … )` with no `main = joined` anchor. See
[Custom Joins](docs/src/read/custom_joins.md).

### How to find the calls to migrate

Nothing to grep — additive. **Optional adoption:** anywhere you previously reached for raw SQL to
express a self-join or a multi-condition ON, replace it with `cjoin_on`.

### Per-app rollout

| App | Status | Notes |
|-----|--------|-------|
| app-1 | ⏳ | optional — replace raw-SQL self-joins with `cjoin_on` |
| app-2 | ⏳ | optional |
| app-3 | ⏳ | optional |
| app-4 | ⏳ | optional |

---

## `create()` / `insert()` return a `PormGRow` (was `Dict`)

- **PormG ref**: issue #166 ; `src/querybuilder/execution.jl`
- **Recorded**: 2026-07-16
- **Severity**: **breaking (return type)** / behavior improvement — the row surface is now uniform.

### What changed

`create()` / `insert()` now return a **`PormGRow`** on the execute path — the same row object
`get()`, `first()`, `list()`, and `update_or_create()` already return — instead of a bare
`Dict{Symbol,Any}`. This makes the row surface consistent and lets a created row be mutated and
`.save()`d:

```julia
row = M.Driver.objects.create("forename" => "Ayrton", "surname" => "Senna")
row[:driverid]        # unchanged — PormGRow delegates indexing/haskey/keys/get/pairs/iterate
row.surname           # now also works (dot-access)
row.surname = "SENNA"; row.save()   # and it round-trips
```

`show_query=:sql/:dict/:params` still return their inspection shapes (String/Dict/Vector) — only the
`:execute` return changed. `list(:dict)` and `values()` still return plain dicts. `update()` still
returns a matched-row count.

### How to find the calls to migrate

Because `PormGRow` delegates `getindex`/`haskey`/`get`/`keys`/`values`/`pairs`/`iterate`, the common
patterns (`row[:id]`, `haskey(row, :x)`, iterating pairs) keep working unchanged. Only these break:

```
# 1. Type checks that assumed a Dict:
grep -rn "create(" src/ | grep -i "isa Dict"
grep -rn "= .*\.create(" src/            # then check for `isa Dict`, `merge(`, `delete!(`

# 2. Dict-only MUTATION of a create() result (PormGRow has no setindex!):
grep -rn "\.create(" src/ | ...          # then look for `result[:x] = ...` on that result
```

### Migrate your app

- `@assert result isa Dict` → `@assert result isa PormG.QueryBuilder.PormGRow` (or drop the type
  check — field access is unchanged).
- Adding/overwriting a key on the result: `result[:x] = v` → `result.x = v` (dot-assign), and
  `result.save()` if you want it persisted. (Read access `result[:x]` is unchanged.)
- Passing the result somewhere typed `::Dict`, or `merge(result, …)` / `collect(result)` /
  `length(result)` / `result == Dict(…)`: convert first with `Dict(pairs(result))`.

### Per-app rollout

| App | Status | Notes |
|-----|--------|-------|
| app-1 | ⏳ | check for `isa Dict` / Dict-mutation on `create()` results; field access unaffected |
| app-2 | ⏳ | as above |
| app-3 | ⏳ | as above |
| app-4 | ⏳ | as above |

---

## Row-level `update_or_create` (Django-style upsert)

- **PormG ref**: issue #30 ; `src/querybuilder/execution.jl`, `src/querybuilder/object_manager.jl`
- **Recorded**: 2026-07-15
- **Severity**: new feature — **additive, non-breaking**. No existing API changed; no forced code edit.

### What changed

`M.Model.objects.update_or_create(lookup...; defaults=[...])` performs a single-row upsert built on
the `ON CONFLICT` renderer from #123. The lookup pair(s) are the conflict target; `defaults` are set
on conflict and merged into the insert. It returns `(row, created::Bool)`, where `row` is a `PormGRow`
(dot-access + `.save()`, like `get()`) and `created` distinguishes insert from update (PostgreSQL via
`RETURNING (xmax = 0)`; SQLite via a pre-check in its serialized write lock).

```julia
row, created = M.Status.objects.update_or_create(
    "statusid" => 3; defaults = ["status" => "Accident"])
```

Requires the lookup columns to be backed by a UNIQUE/PRIMARY KEY constraint in the database.
`auto_now` fields refresh on the update arm. See [Update or Create](docs/src/write/create.md#update-or-create).

### How to find the calls to migrate

Nothing breaks — purely additive. **Optional adoption:** replace hand-rolled get-then-create/update
blocks (a `filter(...).exists()` followed by `create()` or `update()`) with a single
`update_or_create`, which is atomic and race-free.

```
grep -rn "exists()" src/ | grep -iE "create|update"
```

### Per-app rollout

| App | Status | Notes |
|-----|--------|-------|
| app-1 | ⏳ | optional — replace get-then-create/update blocks with `update_or_create` |
| app-2 | ⏳ | optional |
| app-3 | ⏳ | optional |
| app-4 | ⏳ | optional |

> **Resolved:** the `create()`/`insert()` → `Dict` vs `PormGRow` inconsistency this note tracked is
> settled by the entry above (#166) — both now return `PormGRow`.

---

## `bulk_insert` conflict handling via `on_conflict=` (ON CONFLICT)

- **PormG ref**: issue #123 ; `src/querybuilder/execution_bulk.jl`, `src/Dialect.jl`
- **Recorded**: 2026-07-15
- **Severity**: new feature — **additive, non-breaking**. Default behavior unchanged; no forced code edit.

### What changed

`bulk_insert` accepts an `on_conflict=` keyword that renders an `ON CONFLICT` clause (PostgreSQL
and SQLite ≥ 3.24, identical syntax), so overlapping batches skip or merge duplicates instead of
erroring:

```julia
bulk_insert(M.Status.objects, df, on_conflict = :nothing)                       # ON CONFLICT DO NOTHING
bulk_insert(M.Status.objects, df,
    on_conflict = (action = :nothing, target = ["statusid"]))                   # targeted skip
bulk_insert(M.Status.objects, df,
    on_conflict = (action = :update, target = ["statusid"], set = ["status"]))  # upsert
```

With `on_conflict` set, the duplicate-key → sequence-resync retry is skipped (a conflict is
expected there, not a desync). See [Conflict Handling](docs/src/write/bulk.md).

This exists to delete the raw-SQL workaround: seeding a shared dimension from concurrent workers
previously required hand-written `LibPQ.execute("INSERT … ON CONFLICT … DO NOTHING")` with manual
value escaping, bypassing PormG's parameterization and connection routing.

### How to find the calls to migrate

Nothing breaks — purely additive. **Optional adoption:** grep each app for raw conflict-handling
inserts and replace them with the ORM call:

```
grep -rn "ON CONFLICT" src/ | grep -i "execute"
```

Concrete known call site (esus_back `src/auxiliar.jl`, `at_dim_cbo` — seeds the global
`dash_dim_cbo` dimension from concurrent municípios):

```julia
# ✗ before — raw LibPQ with hand-built VALUES and manual '' escaping
valores = join(map(eachrow(df)) do r
  nome = ismissing(r.no_cbo) ? "null" : "'" * replace(string(r.no_cbo), "'" => "''") * "'"
  "($(r.id), 0, '$(r.co_cbo)', $nome)"
end, ", ")
LibPQ.execute(db, """
  INSERT INTO dash_dim_cbo (id, cat_cbo_id, co_cbo, no_cbo)
  VALUES $valores
  ON CONFLICT (id) DO NOTHING
""")

# ✓ after — dash_dim_cbo modeled as biM.Dim_CBO; parameterized, pooled, chunked
df.cat_cbo_id = fill(0, nrow(df))   # was a literal in the raw INSERT
bulk_insert(biM.Dim_CBO, df, on_conflict = (action = :nothing, target = ["id"]))
```

(The issue #123 comment sketched `(:nothing, target = ["id"])` — that tuple form is not valid
Julia; the shipped API is the NamedTuple shown above.)

### Per-app rollout

| App | Status | Notes |
|-----|--------|-------|
| esus_back | ⏳ | `src/auxiliar.jl` `at_dim_cbo` — apply the before → after above (needs `dash_dim_cbo` modeled) |
| app-2 | — | no raw ON CONFLICT inserts known |
| app-3 | — | no raw ON CONFLICT inserts known |
| app-4 | — | no raw ON CONFLICT inserts known |

---

## Composite uniqueness (`unique_together`) via `Models.UniqueConstraint`

- **PormG ref**: issue #19 ; `src/Models.jl`, `src/migrations/planner.jl`, `src/migrations/importers.jl`
- **Recorded**: 2026-07-14
- **Severity**: new feature — **additive, non-breaking**. No existing API changed; no forced code edit.

### What changed

Models can now declare multi-column uniqueness (Django's `Meta.unique_together`) with a
model-level `constraints=` list of named `Models.UniqueConstraint` objects:

```julia
Constructor_engine = Models.Model("constructor_engines",
  id = Models.IDField(),
  constructorid = Models.ForeignKey(Constructor, pk_field="constructorid", on_delete="CASCADE"),
  year = Models.IntegerField(),
  engine_manufacturer = Models.CharField(max_length=50),
  constraints = [
    Models.UniqueConstraint(fields=("constructorid", "year"), name="uniq_constructor_year"),
  ],
)
```

At migration time each constraint becomes a `CREATE UNIQUE INDEX` (identical on PostgreSQL and
SQLite). The Django importer now maps `Meta.unique_together` to this form automatically (resolving
the FK `_id` suffix). See [Composite Uniqueness](docs/src/models.md).

**Limitation (this release):** a constraint is materialized when its table is first created (same
lifecycle as the automatic many-to-many index). Adding/removing a constraint on an
already-migrated table is not yet diffed by `makemigrations` — deferred to a follow-up.

### How to find the calls to migrate

Nothing to grep — no API changed. This is purely additive. **Optional adoption:** if an app has a
natural composite key currently enforced only in application code (or a Django model with
`unique_together` that was imported before this feature), declare it with `UniqueConstraint` and
create the table (or add the unique index by hand on the existing table).

### Per-app rollout

| App | Status | Notes |
|-----|--------|-------|
| app-1 | ⏳ | optional — review models for composite keys to enforce |
| app-2 | ⏳ | optional |
| app-3 | ⏳ | optional |
| app-4 | ⏳ | optional |

---

## Connection errors inside `run_in_transaction` now propagate (no silent statement retry)

- **PormG ref**: issue #138 ; `src/ConnectionPool.jl`
- **Recorded**: 2026-07-13
- **Severity**: behavior change (error now surfaces instead of a silent, broken retry)

### What changed

`fetch()`'s lost-connection recovery (renew the pooled connection, re-run the statement once)
no longer fires **inside a transaction context** or on a caller-pinned `conn`. Previously a
connection drop during e.g. `q.create(...)` inside `run_in_transaction` silently re-ran the
statement on a **fresh autocommit session** — committing a write that should have died with the
transaction — and released the transaction's pooled connection to the pool mid-transaction. Now
the connection error propagates out of the transaction block like any other failure; the wrapper
rolls back and renews/discards the pooled connection (#71). Plain `fetch()` outside transactions
keeps the transparent one-shot retry. This matches Django / SQLAlchemy / Rails 7.1 /
Go `database/sql`: never retry a statement inside a transaction — the application retries the
whole transaction.

### How to find the calls to migrate

Nothing to grep — no API changed. Only code that (unknowingly) relied on the mid-transaction
retry is affected: if a transaction block now fails with a driver connection error where it
previously appeared to succeed (with silently corrupted transactional semantics), wrap the
**whole** `run_in_transaction` call in an application-level retry.

### Migrate your app

```julia
# ✗ before: a connection drop mid-block silently committed the create OUTSIDE the transaction
# ✓ after: the block raises; retry the whole transaction if the work must survive reconnects
for attempt in 1:3
  try
    PormG.run_in_transaction("db_2") do
      (M.Pit_stops.objects).create(
        "raceid" => 841, "driverid" => 153, "stop" => 3, "lap" => 42,
        "time" => "17:05:23", "duration" => "22.500", "milliseconds" => 22500,
      )
    end
    break   # committed
  catch e
    attempt == 3 && rethrow()
  end
end
```

### Per-app rollout

| App | Status | Notes |
|-----|--------|-------|
| app-1 | ⏳ | action needed only if the app saw mid-transaction reconnects |
| app-2 | ⏳ | |
| app-3 | ⏳ | |
| app-4 | ⏳ | |

---

## `DateTimeField` values are canonicalized to UTC — existing **SQLite** rows must be re-normalized once

- **PormG ref**: issue #79 ; `src/Models.jl` (`format_timezone_sql` / `validate_timezone`)
- **Recorded**: 2026-07-13
- **Severity**: breaking (SQLite stored-data format) / behavior fix
- **This is a data change, not a code change** — the PormG API is unchanged; there are no call
  sites to edit. The rollout is a one-time SQLite data re-normalization.

### What changed

`DateTimeField` values are now canonicalized to a single UTC ISO-8601 string
(`yyyy-mm-ddTHH:MM:SS.sss+00:00`) on **both** the write/bind path and the filter path — the
convention Django (`USE_TZ=True`), Rails, and SQLAlchemy already use. Previously PormG stored
offset-bearing strings verbatim (e.g. `auto_now` under `America/Sao_Paulo` was written as
`…-03:00`, and a `Z` / `.0` filter value was passed through unchanged).

- **PostgreSQL** is transparent: `TIMESTAMPTZ` compares by instant, so filters were already
  correct and stored data is unaffected — nothing to do.
- **SQLite** stores datetimes as TEXT and compares them lexicographically, so the old
  non-canonical strings made equality/range filters **diverge from PostgreSQL** whenever the
  filter value's spelling differed from the stored spelling (issue #79). Going forward both the
  stored value and the filter value are canonical UTC, so the comparison is correct — **but
  rows written by the old code are still in their old spelling** and must be re-normalized once.

### Who is affected

- PostgreSQL-only apps → mark `—`.
- SQLite apps whose `DateTimeField` columns are empty or freshly created after this bump → mark `—`.
- SQLite apps with **pre-existing** `DateTimeField` data → run the one-time re-normalization below.

### Re-normalize existing SQLite data (one time)

The read path already reconstructs the correct instant from any offset spelling, so a
read-modify-write through PormG reuses PormG's own parser/formatter and is the safest recipe.
For each SQLite model + `DateTimeField` column:

```julia
# `col` is any DateTimeField column on `M.Thing` (SQLite backend).
for row in M.Thing.objects.values("id", "col").list()
    (ismissing(row[:col]) || row[:col] === nothing) && continue   # skip SQL NULL (surfaces as missing)
    q = M.Thing.objects
    q.filter("id" => row[:id])
    q.update("col" => row[:col])                # re-writing stores the canonical UTC form
end
```

(An equivalent single SQL `UPDATE` that converts each value to canonical UTC works too, but the
read-modify-write above avoids hand-rolling the offset math.) Verify with a `Z`-spelled value
that previously missed on SQLite:

```julia
@assert M.Thing.objects.filter("col" => "2020-01-01T10:00:00Z").exists()  # a known stored instant
```

### Per-app rollout

| App | Status | Notes |
|-----|--------|-------|
| app-1 | ⏳ | |
| app-2 | ⏳ | |
| app-3 | ⏳ | |
| app-4 | ⏳ | |

---

## `distinct().order_by()` — the sort key must be in the projection (raises otherwise)

- **PormG ref**: issue #76 ; `src/querybuilder/build_query.jl`
- **Recorded**: 2026-07-13
- **Severity**: behavior change (new `ArgumentError`)

### What changed

A `DISTINCT` query that orders by a column outside its projection —
`.values("a").distinct().order_by("b")` with `b` not in `values(...)` — now raises a clear
`ArgumentError` on **both** backends. Previously PostgreSQL rejected it with a raw DB error while
SQLite silently ran it, returning rows in a nondeterministic `DISTINCT`/order interaction. Ordering a
`DISTINCT` result by an unprojected column is rejected by PostgreSQL and the SQL standard (SQL Server,
Oracle, DB2, and default-mode MySQL all reject it); PormG now makes SQLite conform too. The guard
matches the resolved SQL *expression*, so ordering by a *function of* a projected column
(`order_by("created_at__@date")` while only `created_at` is selected) is likewise rejected — that too
is a PostgreSQL error.

### How to find the calls to migrate

Run the app or its tests: the new error reads
`DISTINCT query cannot ORDER BY <col>: it is not in the SELECT DISTINCT projection`. Grep for
`.distinct()` and check each one's `order_by(...)` — every ordered column (or the exact ordering
expression) must also appear in `values(...)`. **Postgres-backed apps already errored on these; only
SQLite-tested queries could have been running silently.**

### Migrate your app

```julia
# ✗ raises: surname is ordered but not projected
M.Driver.objects.values("nationality").distinct().order_by("surname").list()

# ✓ include the sort key in values() (distinct is now over both columns) …
M.Driver.objects.values("nationality", "surname").distinct().order_by("surname").list()

# ✓ … or drop distinct() if you meant "one row per nationality, ordered by an aggregate"
M.Driver.objects.values("nationality", "n" => Count("driverid")).order_by("n").list()
```

### Per-app rollout

| App | Status | Notes |
|-----|--------|-------|
| app-1 | ⏳ | |
| app-2 | ⏳ | |
| app-3 | ⏳ | |
| app-4 | ⏳ | |

---

## bulk ops `copy=` kwarg removed — the pipeline never mutates (and never copies) your DataFrame

- **PormG ref**: issue #132 / PR #137 ; `src/querybuilder/execution_bulk.jl`
- **Recorded**: 2026-07-12
- **Severity**: breaking (kwarg removed) / behavior improvement

### What changed

`bulk_insert`, `bulk_copy`, and `bulk_update` no longer accept `copy::Bool`. The old
default (`copy=true`) deep-copied the entire DataFrame on every call; `copy=false` let
ORM-side normalization (default fills, `auto_now` columns) leak into the caller's frame.
The pipeline now works on a **zero-copy wrapper** (shared column vectors): the caller's
DataFrame is **never mutated and never copied**, unconditionally — strictly better than
both old modes. `allocate_primary_keys` is unchanged: `clone=true` still returns an
independent copy (that frame is *returned* to the caller, so it must not alias your
data), and `clone=false` still writes the pk column in place.

### How to find the calls to migrate

Grep each app for `copy=` / `copy =` on `bulk_insert`/`bulk_copy`/`bulk_update` calls
(or just run the app: passing the removed kwarg raises
`MethodError: ... got unsupported keyword argument "copy"`).

### Migrate your app

```julia
# ✗ before
bulk_insert(query, df, copy=true)    # paid a full deepcopy
bulk_update(query, df, columns=["points"], match_on=["id"], copy=false)  # mutated df

# ✓ after — just drop the kwarg; no-mutation is now the unconditional contract
bulk_insert(query, df)
bulk_update(query, df, columns=["points"], match_on=["id"])
```

If an app relied on `copy=false` to *receive* the injected columns (e.g. reading
`df.updated_at` after the call), that back-channel is gone — read the values back
through a query instead.

One subtle semantics shift: the old `copy=true` gave the bulk op a private *snapshot*
of your data; the zero-copy wrapper reads your live column vectors **during** the call.
Don't mutate the DataFrame from another task while a bulk op is executing on it (this
was never supported — it just happened to be masked by the default deepcopy).

### Per-app rollout

| App | Status | Notes |
|-----|--------|-------|
| app-1 | ⏳ | |
| app-2 | ⏳ | |
| app-3 | ⏳ | |
| app-4 | ⏳ | |

---

## `bulk_update(match_on=)` — pairs removed; `columns=` is the single df→field mapping point

- **PormG ref**: issue #107 / PR #135 ; `src/querybuilder/execution_bulk.jl`
- **Recorded**: 2026-07-12
- **Severity**: breaking

### What changed

`match_on=` no longer accepts `"df_col" => "model_field"` pairs. It takes **bare model
field names** only; `columns=` is now the **single place** a DataFrame column is mapped
to a model field ("one border crossing"). A field listed in both `columns=` and
`match_on=` is used for **matching only — it is never SET** (this was already true).
A bare `match_on` name resolves its source column **mapping-first**: the `columns=`
mapping when declared (authoritative — a same-named DataFrame column is ignored with a
warning), otherwise a DataFrame column with the field's own name.

### How to find the calls to migrate

Run the app or its tests: every old pair raises
`bulk_update: match_on= no longer accepts "df_col" => "model_field" pairs (DEPRECATED API)`
with the exact rewrite. Or grep for `match_on` and inspect any entry containing `=>`.

### Migrate your app

```julia
# ✗ before
bulk_update(query, df,
    columns  = ["new_score" => "points"],
    match_on = ["record_id" => "id"])

# ✓ after — the pair moves to columns=; match_on keeps the bare field name
bulk_update(query, df,
    columns  = ["new_score" => "points", "record_id" => "id"],
    match_on = ["id"])
```

Bare-name calls (`match_on = ["id"]` with an `id` DataFrame column, or relying on the
primary-key fallback) need no change.

### Per-app rollout

| App | Status | Notes |
|-----|--------|-------|
| app-1 | ⏳ | |
| app-2 | ⏳ | |
| app-3 | ⏳ | |
| app-4 | ⏳ | |

---

## `SQLOrder` orientation is now whitelisted — only `"ASC"`/`"DESC"` (case-insensitive) construct and render

- **PormG ref**: issue #77 / PR #133 ; `src/querybuilder/types.jl`, `src/querybuilder/build_query.jl`
- **Recorded**: 2026-07-12
- **Severity**: behavior change (new `ArgumentError`; closes an injection seam)

### What changed

A directly constructed `SQLOrder` used to accept **any** string as `orientation` and interpolate
it verbatim into the rendered `ORDER BY` — a SQL-injection seam for apps forwarding a
user-controlled sort direction. Every construction path (and render, guarding post-construction
mutation) now normalizes (`uppercase` + `strip`) and whitelists against `"ASC"`/`"DESC"`, raising
`ArgumentError` for anything else. The documented string API — `.order_by("field")` /
`.order_by("-field")` — was always safe and is unchanged.

### How to find the calls to migrate

Grep the app for direct `SQLOrder(` construction. Only call sites passing a *dynamic*
(user- or data-derived) `orientation` need action; literal `"ASC"`/`"DESC"` in any case keep
working.

### Migrate your app

```julia
# ✗ before — a user-controlled direction string reached the SQL verbatim
dir = params["dir"]   # e.g. "ASC; DROP TABLE results" used to render as-is
query.order_by(SQLOrder(SQLField("points", "points"); orientation = dir))

# ✓ after — map untrusted input onto the whitelist yourself (or handle the ArgumentError)
query.order_by(SQLOrder(SQLField("points", "points");
    orientation = lowercase(dir) == "desc" ? "DESC" : "ASC"))
```

### Per-app rollout

| App | Status | Notes |
|-----|--------|-------|
| app-1 | ⏳ | |
| app-2 | ⏳ | |
| app-3 | ⏳ | |
| app-4 | ⏳ | |

---

## Pool exhaustion now raises typed `PoolTimeoutError`; expansion ceiling raised to `pool_size × 10`

- **PormG ref**: issue #37 / PR #129 ; `src/ConnectionPool.jl`
- **Recorded**: 2026-07-12
- **Severity**: behavior change (error type changed; pool sizing change)

### What changed

Exhausting the connection pool used to throw a **bare `String`** after a noisy busy-retry loop.
Both the PostgreSQL and SQLite acquire paths now throw `PormG.PoolTimeoutError` (exported; fields
`adapter` / `pool_size` / `max_size` / `attempts` / `elapsed`, with a "raise pool_size" remedy in
`showerror`). The lazy expansion ceiling grew from `pool_size × 5` to `pool_size × 10` (default
pool: 3 base → up to 30 on demand; idle footprint unchanged), and per-retry logging dropped to
`@debug` — a single actionable `@warn` fires only when the pool hits its ceiling.

### How to find the calls to migrate

Grep the app for `catch` blocks that match the old exhaustion message as a string
(e.g. `occursin("No available"` …). Most apps have none — then there is nothing to change; the
new error type and quieter logs just apply.

### Migrate your app

```julia
# ✗ before — the only way to detect exhaustion was string-matching a bare String throw
catch e
    e isa String && occursin("No available", e) && back_off()

# ✓ after — catch the typed error; consider raising pool_size in connection.yml if it fires
catch e
    e isa PormG.PoolTimeoutError || rethrow()
    back_off()
```

### Per-app rollout

| App | Status | Notes |
|-----|--------|-------|
| app-1 | ⏳ | |
| app-2 | ⏳ | |
| app-3 | ⏳ | |
| app-4 | ⏳ | |

---

## `order_by` on nullable columns — NULL placement normalized to PostgreSQL's convention on both backends

- **PormG ref**: issue #75 / PR #120 ; `src/querybuilder/build_query.jl`
- **Recorded**: 2026-07-12
- **Severity**: behavior change (result order can change on SQLite)

### What changed

Top-level `ORDER BY` used to render a bare `expr ASC|DESC`, and PostgreSQL and SQLite default
NULLs to **opposite ends** — so ordering a nullable column returned different rows per backend,
and with `.first()` / `.page()` that changed *which* rows you got. PormG now emits an explicit
NULLS clause matching PostgreSQL's default on **both** backends: ASC → `NULLS LAST`,
DESC → `NULLS FIRST` (SQLite < 3.30.0 gets an equivalent portable `(expr IS NULL)` prefix).
Per-term override: `SQLOrder(field; nulls = :first | :last)`. Window `OVER(...)` ordering is
**not** yet normalized (follow-up pending).

**PostgreSQL-backed apps see no change.** SQLite-backed apps: any `order_by` on a nullable key
may now sort NULL rows to the other end.

### How to find the calls to migrate

No API change and nothing errors. In SQLite-backed apps, review `order_by` calls on **nullable**
columns whose consumers depend on row order — `.first()`, pagination, "top N" reports.

### Migrate your app

```julia
# Only if the app depended on SQLite's old NULLS-first-on-ASC ordering — pin it explicitly:
using PormG.QueryBuilder: SQLOrder, SQLField

M.Driver.objects.values("surname", "nationality").order_by(
    SQLOrder(SQLField("nationality", "nationality"); orientation = "ASC", nulls = :first)
).list()
```

### Per-app rollout

| App | Status | Notes |
|-----|--------|-------|
| app-1 | ⏳ | |
| app-2 | ⏳ | |
| app-3 | ⏳ | |
| app-4 | ⏳ | |

---

## `bulk_copy` — field formatters now applied; `""` and `missing` no longer collapse to NULL

- **PormG ref**: issue #86 / PR #115 ; `src/querybuilder/execution_bulk.jl`
- **Recorded**: 2026-07-12
- **Severity**: behavior change (persisted values can differ)

### What changed

`bulk_copy` wrote **raw** DataFrame values (each field's formatter result was validated, then
discarded), so datetime/bool/float values could silently diverge from what `bulk_insert` /
`create()` store; and the COPY payload carried no NULL marker, collapsing `""` and `missing`
into the same NULL. It now formats every cell exactly like `bulk_insert` and serializes with a
`\N` NULL sentinel: `missing` → SQL `NULL`, `""` → empty string, and the two round-trip
distinctly.

### How to find the calls to migrate

No API change. Review `bulk_copy` call sites that (a) pre-formatted datetimes/bools/floats to
compensate for the old raw write — the workaround is now redundant (but harmless), or
(b) relied on empty strings being stored as NULL.

### Migrate your app

```julia
# The old behavior stored NULL for BOTH of these; they now persist differently:
df = DataFrames.DataFrame(surname = ["Senna", "Prost"], code = ["", missing])
bulk_copy(M.Driver.objects, df)   # row 1 code → '' (empty string), row 2 code → NULL

# Keep the NULL semantics only where you actually want it — coerce before the call:
df[!, :code] = map(x -> !ismissing(x) && x == "" ? missing : x, df[!, :code])
```

### Per-app rollout

| App | Status | Notes |
|-----|--------|-------|
| app-1 | ⏳ | |
| app-2 | ⏳ | |
| app-3 | ⏳ | |
| app-4 | ⏳ | |

---

## Template for new entries

<!--
Copy the block below to the top of the log (under the legend) for each new breaking change.

## `<api>` — <one-line summary of the change>

- **Version**: <0.y.0 — the release this shipped in; bump `Project.toml` in the same change>
- **PormG ref**: <issue / PR / commit> ; <src file>
- **Recorded**: <YYYY-MM-DD>
- **Severity**: breaking | behavior change | deprecation

### What changed
<what the old API did vs. the new contract>

### How to find the calls to migrate
<error message to grep for, or the call pattern>

### Migrate your app
```julia
# ✗ before
...
# ✓ after
...
```

### Per-app rollout

| App | Status | Notes |
|-----|--------|-------|
| app-1 | ⏳ | |
| app-2 | ⏳ | |
| app-3 | ⏳ | |
| app-4 | ⏳ | |
-->
