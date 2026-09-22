# Advanced Configuration

PormG is designed for Julia's asynchronous task scheduling. This section covers connection pooling, advisory locks, and the performance implications of the async-first design.

## Connection Pooling & Async-First Design

- **Async-First API:** The synchronous `fetch()` API is a wrapper around the asynchronous `fetch_async()` core. This wrapper yields to the Julia scheduler while waiting for the database, ensuring compatibility with async frameworks. See the [Async & Concurrency guide](../async.md) for usage patterns.
- **Pooling Strategy:** The default strategy is `:poll`, which retries at configured intervals. Use `:block` for PostgreSQL to let the server-side manage the wait, often combined with a `statement_timeout`.
- **Sizing & capacity:** A pool starts at `pool_size` connections (default `3`) and grows **lazily, on demand,** up to `pool_size × 10` under concurrent load — so the idle footprint stays small while async fan-out still gets headroom. If every connection is busy and none frees within the retry/timeout budget, `acquire_connection` raises a catchable `PoolTimeoutError` (exported by PormG). Raise `pool_size` in your `connection.yml` to add capacity for genuinely high-concurrency workloads:

```yaml
dev:
  adapter: PostgreSQL
  database: 'formula1'
  # ...
  pool_size: 10   # base 10 → grows to 100 under burst
```

  A misspelled pool key (`pool:`, `poolsize:`, `pool_timout:`) is reported on load with a suggestion instead of silently leaving the default in place — see [Unrecognised keys](connection_yml.md#Unrecognised-keys).
- **Acquire timeout (`pool_timeout`):** How long `acquire_connection` waits for a free connection before raising `PoolTimeoutError` — default **30 s**. Set `pool_timeout:` in `connection.yml` (seconds; fractional allowed) to *fail fast* instead of blocking a request while the pool is saturated:

  ```yaml
  dev:
    adapter: PostgreSQL
    database: 'formula1'
    pool_size: 10
    pool_timeout: 5   # give up after 5s waiting for a connection, then raise PoolTimeoutError
  ```

  An explicit per-call `acquire_connection(pool; timeout_seconds=…)` still overrides it, and `Configuration.register_connection` accepts the same `pool_timeout` kwarg. A value `≤ 0` falls back to the 30 s default (a "never wait" setting is ambiguous and a footgun). Absent means the historical 30 s — zero behavior change.
- **Connect failures (`PoolConnectError`, `fail_fast_on_connect`):** `pool_timeout` covers a *saturated healthy* pool. A pool that can never open a connection — a wrong password, a missing role/database, an unopenable SQLite path — is a different failure: waiting `pool_timeout` for it to "free up" is pointless, and blaming `pool_size` is misleading. `acquire_connection` therefore classifies the driver error: a **permanent** one (PostgreSQL auth / missing role or database; SQLite `unable to open database file`) **fails fast** with a catchable `PoolConnectError` (exported) that carries the underlying driver cause and a **redacted** connection string — remedy: fix credentials/host/database, not `pool_size`. Ambiguous errors (host/DNS/network — possibly a transient blip) are *not* fast-failed; they wait to the deadline as before and then also surface `PoolConnectError` (with the cause) rather than `PoolTimeoutError`. A PostgreSQL connection string that cannot even be *parsed* — typically a hand-written `url:` or `register_connection` string with an unquoted space inside a value, a malformed `%`-escape, or a NUL byte — is permanent too: it fails fast with a `PoolConnectError` whose `cause` is an `InvalidConfigurationError`. PormG checks the string before handing it to the driver, so the part of libpq's message that would quote your password is masked and nothing is logged by the driver itself; quote a value containing spaces (`password='two words'`) or percent-encode it in a URL. A URL password holding an unencoded `@` is refused the same way (libpq would end the password at the first `@` and try the rest as a host name or port) — write it as `%40`, and a `:` as `%3A`. An unencoded `/` is refused too — libpq ends the credentials at the first `/` and reads the rest of the password as the database name — so write it as `%2F`. The check behind that refusal is "the URL's database name contains an `@`", so a database whose name really contains an `@` cannot be reached through a URL (not even as `%40`, which libpq decodes first); give that one in the keyword form, `dbname='…'`. Set `fail_fast_on_connect: false` to opt out of the fast-fail and keep waiting the full `pool_timeout`:

  ```yaml
  dev:
    adapter: PostgreSQL
    database: 'formula1'
    pool_size: 10
    fail_fast_on_connect: false   # default true; false = wait pool_timeout even on a bad password
  ```

  Default is `true` (zero-config: a misconfigured deploy fails immediately instead of hanging every request for 30 s). `register_connection` accepts the same `fail_fast_on_connect` kwarg. Transient recovery is *not* retried inside the pool — retry the whole operation at the application layer (the same rule as lost connections inside a transaction).
- **Idle reaping & max-lifetime (opt-in):** By default the pool never shrinks after a burst and reuses connections indefinitely (a dropped connection is caught by the liveness check on the next checkout — see *Dropped connections* below). For long-lived services — or databases/proxies that drop idle connections — you can enable a background reaper via `connection.yml` (both in **seconds**, `0`/absent = off):

  ```yaml
  dev:
    adapter: PostgreSQL
    database: 'formula1'
    pool_size: 10
    idle_timeout: 60      # close *overflow* connections idle > 60s, trimming back toward pool_size
    max_lifetime: 1800    # retire connections older than 30 min (on return, and by the sweeper)
  ```

  Reaping is **overflow-only** and never drops below the base `pool_size` (those stay warm), and never closes an in-use connection. It closes the connection and clears its slot in place — the pool's slot layout is unchanged, so a reaped slot simply opens a fresh connection on next use. Disabled by default: unset means zero behavior change. Programmatic pools accept the same `idle_timeout` / `max_lifetime` kwargs via `Configuration.register_connection`.
- **Dropped connections:** Every checkout probes the connection before handing it out, and PostgreSQL's probe consumes any pending socket input before trusting the driver's status. That matters because `PQstatus` reports libpq's *cached* state: it only turns bad after an I/O attempt fails, and an idle pooled connection attempts none — so before this, a backend the server had terminated (a restart, a failover, an admin `pg_terminate_backend`) kept reporting a healthy connection while its `FATAL: terminating connection due to administrator command` sat unread in the socket buffer, and the pool went on serving it. A rejected connection is closed and its slot reopened. SQLite's probe already round-trips, so it never had the blind spot.

  Whatever kills one pooled connection has usually killed all of them, so recovery is not per-slot either: when a failure is classified as a lost connection, `fetch` renews the connection that failed, retires every other **idle** one, and retries once. In-use connections are left alone — their borrower still holds the handle, and will recover the same way.

  The remaining case is a connection dropped with no bytes delivered at all — a silently broken network path rather than a server that announced itself. Nothing can see that without a round trip, so it surfaces on first use and is retried as above; bound how long a connection can sit in that state with the `max_lifetime` reaper.
- **Health snapshot (`pool_stats`):** `pool_stats` (exported) returns a `NamedTuple` for debugging saturation — pass a pool object or a connection key/path:

  ```julia
  using PormG
  pool_stats("db")   # => (; pool_size, size, in_use, available, ceiling, waiting)
  ```

  `pool_size` is the configured floor, `size` the slots allocated so far (`== in_use + available`), `ceiling` the maximum (`pool_size × 10`), and `waiting` the callers currently parked for a connection — a non-zero `waiting` with `in_use == ceiling` is the signature of saturation (see `PoolTimeoutError`). Counts are read under the pool lock for a coherent snapshot.
- **Leak detection (`leak_detection_threshold`, opt-in):** A connection acquired but never released (e.g. a `fetch_async` that's never awaited) is silently lost until the pool starves. Set `leak_detection_threshold` (**seconds**, `0`/absent = off) to have `acquire_connection` emit a single `@warn` — naming the slot and hold time — when a connection has been held past the threshold:

  ```yaml
  dev:
    adapter: PostgreSQL
    database: 'formula1'
    pool_size: 10
    leak_detection_threshold: 30   # warn when a connection is held > 30s without release
  ```

  The scan runs on the next `acquire_connection` (no background task), so a leak is flagged as the pool comes under pressure — pointing at the offending slot just before a `PoolTimeoutError`. Off by default; `register_connection` accepts the same `leak_detection_threshold` kwarg.
- **Thread Safety:** PormG uses `ReentrantLock` for pool management.
- **Failed-rollback self-healing:** If a transaction's `ROLLBACK` itself fails (e.g. the connection died mid-transaction), the pool never returns that connection as-is. It is renewed in its slot (PostgreSQL: `LibPQ.reset!`; SQLite: a fresh handle, with the old one closed so it releases the database file write-lock) or — if renewal also fails — closed and its slot cleared so the next borrower opens a fresh connection.

---

## Credentials never leave through `show` or `JSON.json`

A connection pool holds the connection string it was built from, and for PostgreSQL that string *is*
the credential. `Configuration.Settings` holds the pool, and `PormG.config` holds the settings — so
any of the three is one `JSON.json` or one REPL `show` away from a password, in exactly the places
application state gets serialized without much thought: a debug endpoint, a health check that dumps
config, an error reporter attaching context.

PormG bounds all three. The two routes deliberately promise different things:

| | what it emits |
|---|---|
| `JSON.json(pool)` | `{"pormg_connection":"PostgreSQL"}` — no connection string, in any form |
| `JSON.json(settings)` | a `pormg_settings` object: `app_env`, `db_def_folder`, `model_file`, `time_zone`, `django_prefix`, `change_db`, `change_data`, `implicit`, and the backend name. Never the pool's DSN, never `db_config_settings` |
| `JSON.json(PormG.config)` | the same, once per configured key |
| `show(pool)` — nested, e.g. inside a `Vector` | `Pool(PostgreSQL, 10 slots)` — no connection string |
| the REPL card, when you type the value | the above **plus** the connection string, redacted |

```julia
julia> pool = PormG.config["db"].connections
Pool(PostgreSQL, 10 slots)
  dsn: host='127.0.0.1' port='5432' password=**** dbname='formula1' user=****
```

**Why JSON is stricter than the display.** A card is read by a human who asked for it, at a
terminal, and "which database is this pointed at?" is the only reason to type a pool — so the card
answers it, redacted. A JSON document *travels*: to a debug endpoint, a log aggregator, an error
reporter, a third party. Redaction is a denylist, and a denylist is one unfamiliar DSN dialect away
from emitting a password, which is an acceptable risk at a terminal and not on a wire.

If you do want the connection string in a document, ask for it explicitly:

```julia
PormG.Configuration.redact_secret(pool.connection_string)
```

`redact_secret` is the single owner of the redaction rule and the same one every log line and
exception uses. It covers both dialects PormG accepts — the libpq keyword form
(`password=…`, `user=…`, quoted values included) and the URL form
(`postgres://user:password@host/db` → `postgres://****:****@host/db`).

**`db_config_settings` is never emitted at all**, by either route. It is the raw parsed YAML block
for your environment, so it can hold a `password:` key, a `url:` carrying an entire DSN, or paths
to TLS private keys — and being an arbitrary user-supplied dictionary, there is nothing to redact
it *with*. Read it directly if you need it; PormG will not put it in a document for you.

---

## Advisory Locks

Use advisory locks to ensure long-running tasks (migrations, seeds, imports) do not run in parallel across processes.

```julia
using PormG, LibPQ   # advisory locks are PostgreSQL-only

# Wrap multiple operations in an advisory lock
PormG.run_in_transaction("db") do
    with_advisory_lock(settings, "my_job_name") do
        # Long-running task
        M.Result.objects.create("year" => 2025, "name" => "New Race")
        bulk_insert(M.Result.objects, results_df)
    end
end
```

### Key Technical Details
- **Hashing:** Keys are hashed using MD5 to provide a 64-bit bigint identifier.
- **Cleanup:** PostgreSQL releases the lock automatically if the session drops.
- **SQLite Limitation:** SQLite does not support advisory locks; the helper is a **no-op** on that backend — the body runs unprotected and the wait/timeout keyword arguments are ignored. It warns once per lock key; pass `on_missing_lock = :ignore` to accept the no-op silently, or `on_missing_lock = :error` to raise `BackendCapabilityError` instead of running unprotected. See [Advisory Locks](../advisory_lock.md).

---

## The Boot-Time Hazard

`@import_models` eventually calls `Models.set_models(...)`, which binds every model to a
`connect_key` by matching its models folder against the configurations already loaded. Everything
below is about that match: what it does when it finds nothing, and what it does when it finds more
than one thing.

### When nothing matches, PormG guesses twice

`set_models` loads the folder itself — and that implicit load decides two things you did not state.

**It guesses the environment.** `Configuration.load(path)` is called with no `env`, so
`ENV["PORMG_ENV"]` decides when it is set and the file's `default_env:` otherwise — neither of them
chosen by your application. In a server that has not selected its environment yet, that is usually
`dev`, which in a great many deployments points at production.

**It guesses the key.** The entry is registered under `path`, which is the *absolute* path of the
folder — not a name your application chose. A later `Configuration.load("db"; env = "prod")` no
longer adds a second entry for that folder: it migrates the implicit one to the key you asked for
and warns. So you end up with one entry under the right key, but with a window beforehand in which
models bound to the absolute key and its environment came from `PORMG_ENV`/`default_env:`. The
implicit entry
is also *marked* as such — `PormG.Configuration.status(key).implicit` reads it back — and that mark,
not the shape of the key, is what the rules below go by.

PormG emits a `@warn` when this implicit load fires. It does not raise: `@import_models` injects an
`__init__` that swallows every exception, so a throw would be invisible and the module would
silently keep whatever key was baked in at precompile.

### When several configurations match, the explicit key wins

Applications normally load configuration by short key (`Configuration.load("db")`) and import
models by relative path (`@import_models "../db/models.jl"`). Those two agree on the resolved
absolute path only when the working directory lines up, so PormG also matches on the folder's final
component.

Matches are **ranked** — an exact path beats a folder-name match. Within a rank, a key you loaded
explicitly beats one `set_models` minted implicitly, because the implicit entry is the one whose
environment came from `PORMG_ENV`/`default_env:` rather than from your application. PormG records
that on the
entry rather than inferring it from the key's spelling, so a relative implicit key
(`set_models(mod, "db")`) still loses to an absolute key you loaded yourself.

Only when that still leaves several candidates is the binding genuinely ambiguous — two configured
folders that end in the same name (`db` and `vendor_app/db`), say. PormG then warns, lists every
candidate, and picks the lexicographically first so that at least the same configuration resolves
the same way on every boot. Give the folders distinct final components and the ambiguity
disappears.

### Loading before `@import_models` is not enough for a package

!!! warning "Module-body configuration does not survive precompilation"
    The obvious fix — call `Configuration.load(path; env = ...)` above `@import_models` — is
    correct but **incomplete for a precompiled package**. Module-body code runs at precompile
    time, and PormG's `config` is a global inside PormG, so those entries do not survive into the
    session. At runtime `config` starts empty again and the first `Model.objects` access
    re-derives the key through the implicit-load path described above.

    Load the configuration in **both** places: in the module body, so the right `connect_key` is
    baked into the image, and again from your module's `__init__`, so it is right in the running
    session. Route both through one helper so they cannot drift apart.

```julia
module RaceControl

using PormG

const DB_DIRS  = ["db", "db_telemetry"]
const APP_ROOT = normpath(joinpath(@__DIR__, ".."))

# `cd` matters: PormG stores the string you pass as the configuration key, without normalising it,
# so short names resolved from a known root are what keep one predictable key per folder.
_load_configs() = cd(APP_ROOT) do
    PormG.Configuration.load_many(DB_DIRS; env = get(ENV, "RACECONTROL_ENV", "dev"))
end

_load_configs()                       # precompile: bakes the right connect_key into the image
PormG.@import_models "../db/models.jl" models

__init__() = _load_configs()          # runtime: the image's configuration did not survive

end
```

Each half does a different job, which is why dropping either one breaks something. The first
`Model.objects` access runs the self-heal (`ensure_model_initialized`), so the state right after
`using` and the state your queries actually run against are two different columns:

| Where the configuration is loaded | After `using`, before any `.objects` | After the first `.objects` access |
|---|---|---|
| Module body **and** `__init__` | short key, `config` populated ✔ | unchanged ✔ |
| Module body only | short key, `config` **empty** | the self-heal re-registers the module and **implicit-loads** it: absolute key, environment from `PORMG_ENV`/`default_env:`, one `@warn` — queries run, against a database you did not choose |
| `__init__` only | **absolute path**, `config` populated | remapped to the short key with a `@warn`; queries then reach the environment `__init__` selected |
| Neither | absolute path, `config` empty | as "module body only" |

The module body runs at precompile time, so it is what bakes the right `connect_key` into the
image; `__init__` runs in the session, so it is what puts the connection in `config` where a query
can find it. Neither substitutes for the other — and the row to fear is "module body only", the
one that looks right after `using` and fails quietly on the first query.

### Verify the binding instead of assuming it

`connect_key` is the field that decides which database a model's queries reach, so read it back
rather than inferring it from the configuration you *meant* to load:

```julia
julia> using RaceControl
julia> RaceControl.models.Driver.objects       # the access that re-derives the key
julia> RaceControl.models.Driver.connect_key   # want the short key, not an absolute path
"db"
```

An absolute path is the usual sign that the implicit load ran, but the fact is recorded rather than
inferred: `PormG.Configuration.status(RaceControl.models.Driver.connect_key).implicit` is `true`
exactly when it did — and then the environment came from `PORMG_ENV`/`default_env:`, not from whatever
your
application selected.
