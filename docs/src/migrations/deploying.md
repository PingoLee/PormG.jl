# [Deploying migrations](@id deploying-migrations)

In development you run `makemigrations`, review the plan, and `migrate` it by hand. In production
the usual shape is different: the reviewed plan ships with the release, and every instance of the
application calls `migrate()` when it boots. The first instance applies the plan, and the rest find
it already applied. This page covers what makes that safe, and what `migrate()` tells a boot script.

## Running `migrate()` at boot

```julia
using PormG

PormG.Configuration.load("db")
result = PormG.Migrations.migrate("db"; interactive = false)
@info "Schema migration" outcome = result.outcome version = result.version
```

`migrate()` returns a [`MigrationResult`](@ref PormG.Migrations.MigrationResult). Its `outcome` says
what happened, and none of the five is an error:

| `outcome` | What happened | At boot |
| :--- | :--- | :--- |
| `:applied` | This instance ran the plan in one transaction and recorded it in `pormg_migrations`. | Continue. |
| `:already_applied` | The plan is already the latest applied migration: another instance got there first, or an earlier run committed it and then failed to archive the file. Nothing ran. | Continue. |
| `:nothing_pending` | There is no `pending_migrations.jl`, or it holds no statements. The history table and any configured [extensions](../configuration/connection_yml.md) were still ensured. | Continue. |
| `:disabled` | The connection is `change_db: false`. Nothing was read or written. | Continue if this environment is meant to be read-only; otherwise fix the configuration. |
| `:declined` | At a terminal, someone answered "no" at the confirmation prompt, a destructive plan was refused for lack of `destructive = true`, or a column change would fail on existing rows. A boot script never sees this: with `interactive = false`, or with no terminal attached, there is no prompt, and each of those refusals throws instead. | — |

`version` is the `pormg_migrations.version` of the row involved, and `n_statements` is how many plan
statements this call executed.

A **failure** is an exception, and at boot the right response is usually to let it stop the process:

- `DestructiveMigrationError`: the plan drops something and `destructive = true` was not passed. See
  [Destructive Operations Safety](workflow.md#Destructive-Operations-Safety). This check runs
  **before** the already-applied check. So while a release ships a destructive plan, **every**
  instance's boot call needs `destructive = true`. Without it, any instance that still sees the plan
  throws, although the plan is already applied. That means its own copy, or a shared folder read
  before the first instance archived the plan.
- `MigrationPrecheckError`: a column or constraint change in the plan would fail on existing rows — a
  `NULL` under a new `NOT NULL`, a value longer than a new `max_length`, duplicates under a new
  `unique = true` — so nothing was applied. The rows were
  counted first; `destructive = true` does not bypass it. See
  [Lossy Column Changes](workflow.md#Lossy-Column-Changes).
- `PlanPreconditionError`: the database no longer holds the schema the plan was generated against,
  so nothing was applied and no `failed` row was recorded. See
  [Shipping a plan with a release](#Shipping-a-plan-with-a-release).
- `InvalidMigrationError`: the plan file does not parse.
- a `DatabaseError`: a statement failed. The whole plan is rolled back and recorded as `failed` in
  `pormg_migrations`. A failure does not block the next `migrate()`: the plan wrote nothing, so it
  can simply be retried. Once a later run applies the same plan, `status()` lists the failed attempt
  under *superseded* instead of as a failure, and its warning clears.
- `OperationalError`: another instance held the migration lock for longer than `lock_wait` (below).

!!! note "Before `MigrationResult`"
    `migrate()` used to return `nothing` in every case, and raised `InvalidMigrationError` when
    nothing was pending — the same error a corrupt plan raises. A boot script that caught that error
    to mean "up to date" should compare `result.outcome` instead; see `upgrade_guide()`.

## Several instances at once (PostgreSQL)

Everything `migrate()` writes happens while it holds one PostgreSQL advisory lock,
`pormg::migrations`. That covers creating the `pormg_migrations` history table, installing the
configured extensions, and applying the plan. Instances that boot together therefore queue on the
lock instead of racing each other's DDL. The lock is per database; see
[Advisory Locking](index.md#PostgreSQL:-Advisory-Locking) for how the key is scoped.

The plan is read, and a destructive plan refused, **before** the lock is requested, so an instance
never holds the lock while it validates or waits on a prompt. The
[schema precondition](#Shipping-a-plan-with-a-release) is checked there too, so a stale plan fails
before any prompt or row count; it is checked **again** inside the lock, which is the check that
decides, because another instance may change the schema in between.

### `lock_wait`: how long to queue

A queued instance waits up to `lock_wait` seconds (default `30`) for the one ahead of it to finish.
Set it above the longest migration you expect, such as building an index on a large table:

```julia
PormG.Migrations.migrate("db"; interactive = false, lock_wait = 600)
```

When the wait runs out, `migrate()` throws an `OperationalError` naming the process that holds the
lock:

```
Failed to acquire advisory lock for 'pormg::migrations' within 30000 ms — held by pid 48213 (api-worker-2)
```

The name in parentheses is the holder's `application_name`. Set one per instance to make it
readable. In a `url:` DSN that is `?application_name=api-worker-2`. Without one, look the pid up in
`pg_stat_activity`.

### `lock_timeout` and `statement_timeout`: bounding what a migration blocks

An `ALTER TABLE` needs an exclusive lock on its table. If a long-running query holds the table, the
`ALTER` waits for it, and while it waits it blocks **every** later query on that table: reads
included. The whole plan is one transaction, so this lasts as long as the slowest query ahead of it.

Two opt-in keywords bound that. Both are in seconds, and both apply only inside the migration
transaction (`SET LOCAL`), so the connection returns to the pool with its own settings:

```julia
PormG.Migrations.migrate("db"; interactive = false,
                         lock_timeout = 5,          # a statement may wait 5 s for a table lock
                         statement_timeout = 300)   # and run for 5 minutes
```

When either is exceeded the statement fails, the plan rolls back and is recorded as `failed`, and
`migrate()` rethrows the error. Retry at a quieter moment. `pormg_migrations` then holds a `failed`
row for that attempt, which [`status()`](workflow.md) reports; the next successful run records its
own `applied` row, and from then on `status()` lists the failed attempt as superseded.

### Permissions: `migrate()` needs a role that may run DDL

Even with nothing pending, `migrate()` runs:

- `CREATE TABLE IF NOT EXISTS pormg_migrations`;
- with extensions configured, `CREATE EXTENSION IF NOT EXISTS` and
  `CREATE OR REPLACE FUNCTION public.immutable_unaccent`. Only the function's owner may replace it.

Call it with a role that is allowed to do this. If your instances connect with a role that may not
issue DDL, give them `change_db: false`. `migrate()` then returns `:disabled` without touching the
database. Leave migrating to one privileged instance, or to a release step.

### Connections: `migrate()` holds two

The advisory lock lives on one connection for the whole run, and the migration transaction runs on
a second. The pool opens connections on demand up to ten times `pool_size`, so this works even with
`pool_size: 1`. Budget for it against `max_connections` or a connection-pooler limit: each instance
uses two server connections while it migrates.

!!! warning "Point `migrate()` at a direct connection, not a transaction-pooling proxy"
    The advisory lock is **session-level**. Behind PgBouncer in `transaction` mode, the lock can be
    released or observed on the wrong server connection, and instances would no longer exclude each
    other. Give `migrate()` a connection that bypasses the pooler, or use `session` pooling. See
    [Advisory Locking](index.md#PostgreSQL:-Advisory-Locking).

## SQLite

SQLite has no advisory lock. What it has is a database-wide write lock, and `migrate()` applies the
plan inside `BEGIN IMMEDIATE`, which takes that lock first. Two processes that migrate one SQLite
file at the same time are therefore serialized. The second waits for the first to commit, and then
finds the plan recorded and reports `:already_applied`. The already-applied check runs inside that
transaction, so a plan is applied **at most once** however the two interleave.

What that does not give you:

- **The wait is SQLite's busy timeout, 30 seconds, not `lock_wait`.** A migration that runs longer
  makes the waiting process fail with a "database is locked" `OperationalError`. `lock_wait`,
  `lock_timeout` and `statement_timeout` are accepted and ignored on SQLite, so one deploy script
  can run on both engines.
- **Application writes wait too.** While the plan runs, every other writer to the file queues on
  the same lock, within the same 30 seconds.
- **Not over a network filesystem.** SQLite's locking is unreliable on NFS and similar, and the
  guarantee above depends on it.

## Gating a release on drift

Before an instance boots against a database, you may want to know whether that database matches
the models the release declares: a read replica refreshed from production, or a schema another
team migrates on its own schedule. `check` answers it read-only, under `change_db: false`, and exits
non-zero on any difference:

```julia
using PormG

PormG.Configuration.load("db"; env = "prod")
r = PormG.Migrations.check("db"; kinds = [:schema_drift])
isempty(r) || println(r)
exit(isempty(r) ? 0 : 1)
```

Each finding is a step the next `makemigrations` would plan. Details:
[Checking the Database Against the Models](workflow.md#Checking-the-Database-Against-the-Models).

## Shipping a plan with a release

The pending plan is a diff: the SQL that takes the schema the plan was **generated against** to
the schema the models declare. So the plan records that starting point. `makemigrations` writes one
header line per table its diff compared — every table the managed models declare (many-to-many join
tables included), and every table it read from the database:

```
# pormg-schema-table: 3f9a1c0e7b2d4a51	circuits
# pormg-schema-table: absent	driver_standings
```

Each value is a fingerprint of the table as the database held it — its columns, indexes and
constraints, **names included** — or `absent` for a table that did not exist yet. The names count
because the plan's statements name those objects (`DROP INDEX "<name>"`): a database whose index is
called something else is not one the plan was written for. So "a schema that matches production's"
means one built the same way, not one that merely holds the same columns. Before it applies anything,
`migrate()` reads the same tables again and compares. On any difference it throws
`PlanPreconditionError`, naming each table that changed, appeared or disappeared, and runs none of
the plan's statements — nor records a `failed` row for it.

That is the release workflow:

1. Generate the plan against a database whose schema matches production's.
2. Review it, and ship that file with the release.
3. `migrate()` at boot applies it only while production still holds the schema it was reviewed
   against. The SQL that runs is the SQL that was reviewed; nothing is re-planned at boot.

It also stops an old plan from replaying. Say release N shipped plan P1 and release N+1 shipped P2.
An instance still on release N that restarts after P2 was applied finds P1 pending again, and the
tables P1 compared are now in their N+1 state, so P1 is refused instead of re-run. The plan applied
*last* is the exception: it is recognised by its checksum first and archived as `:already_applied`,
although its own changes moved its tables.

A table the plan never compared does not count, so a table created in production outside the models
does not block a plan.

When a refusal is expected — production was changed by hand, on purpose, and you have checked that
the plan still applies — either regenerate the plan against that database with `makemigrations()`,
or delete its `# pormg-schema-table:` lines. A plan without them is applied without the check, as
every plan generated before the check existed is.
