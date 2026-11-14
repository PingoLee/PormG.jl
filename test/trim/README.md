# The `juliac --trim` fixture app

A minimal F1 application built with `juliac --trim`, the measuring stick for #1599 (a PormG app
built as a trimmed binary). It is #1616's first checkbox.

What it does (`main.jl`): boot with the connection built in code (`register_connection` and
`Models.set_models(models; key)`, #1606 — no `connection.yml` is read), one `Race.objects.create`,
and one `Race.objects.filter("circuitid__country" => "Monaco").list(RaceRow)`, where `RaceRow` is the
struct `list(show_query = :struct)` writes (#1632). Each step prints one line. The read-only entry,
`read.jl`, runs the same boot and read without the write; the steps both entries share are in
`steps.jl`.

Not a test the unit suite runs: it needs Julia 1.13 and JuliaC. The full entry's binary stops at
the write (layer 7, the walls left are in #1599's tables); the read-only entry's binary returns its
row (#1788), and the `Trim (juliac)` workflow checks that it still does (see "The read-only entry and
its CI job" below).

## Drivers

The fixture runs on SQLite; a MySQL variant is in `mysql/` (see "The MySQL variant" below). For
PostgreSQL in a `juliac --trim` build, use Postgres.jl
(`register_connection(…; adapter = "PostgreSQL", postgres_driver = "Postgres")`). A copy of this
fixture switched to it (not committed) builds, and has not been run. A binary built with LibPQ 1.18
aborts before `main` with `InitError(:Infinity, MethodError(!, (false,)))`: the `__init__` of
Infinity.jl, a LibPQ dependency, calls Requires' `@require`, which makes a dynamic call the trimmed
image has no compiled code for. The cause is upstream, not in PormG. Memento, LibPQ's logging
dependency, calls `@require` in its `__init__` as well, so it would likely abort next (read from its
source, not observed, since Infinity aborts first). Until LibPQ's dependency chain stops using
Requires, a PostgreSQL variant of the fixture uses Postgres.jl. Measurements are in
[#1614](https://github.com/PingoLee/PormG.jl/issues/1614).

## Build and run

Julia 1.13.3 and JuliaC 0.3.12 (`pkg> app add JuliaC`, which installs `~/.julia/bin/juliac`). From
the repository root:

```
julia --project=test/trim -e 'using Pkg; Pkg.instantiate()'
julia --project=test/trim test/trim/prep.jl run          # seeds run/f1.sqlite under the JIT
julia --project=test/trim test/trim/main.jl run          # the JIT control: boot, write, 2 rows

mkdir -p build && cd build
JULIA_CPU_TARGET=native juliac --project ../test/trim --output-exe main \
  --trim=unsafe-warn --experimental ../test/trim/main.jl 2>&1 | tee build.log
cd .. && julia --project=test/trim test/trim/prep.jl run && build/main run
```

`--output-exe` takes a bare name, not a path. Pipe the build through `tee`: a redirect to a file lost
the end of the verifier report, which a spinner line overwrote (#1599 round 1). Under
`--trim=unsafe-warn` the verifier lists every dynamic call it cannot resolve ("Error #N"), and the
binary still links; a call with no compiled target then raises a catchable `MethodError` at run
time, which `main` prints with the function it missed.

## The read-only entry and its CI job

`read.jl` is `main.jl` without the write: boot, then the typed read. Since #1788 its trimmed binary
prints the row its JIT control prints, and exits 0:

```
step	main	entered
step	ext	true
step	boot	ok
step	query	1 rows
step	row	1 2008 Monaco Grand Prix 2008-05-25
step	elapsed_ms	1
```

Build and run it like the full entry, from the repository root:

```
julia --project=test/trim test/trim/prep.jl run
julia --project=test/trim test/trim/read.jl run          # the JIT control: boot, 1 row

mkdir -p build && cd build
JULIA_CPU_TARGET=native juliac --project ../test/trim --output-exe read \
  --trim=unsafe-warn --experimental ../test/trim/read.jl 2>&1 | tee build.log
cd .. && julia --project=test/trim test/trim/prep.jl run && build/read run
```

The two entries `include` the same `steps.jl`, so a step prints the same line in both binaries and
fails with the same exit code (1 boot, 2 write, 3 read).

**The `tasks` run** (`build/read <run dir> tasks`) adds two steps after the read, for the pool's
long-lived tasks: a task body a trimmed image never compiled dies silently, so only running it shows
it works (#1599 layer 2).

- `reap`: the binary boots with `idle_timeout = 1`, leases two connections so the pool
  (`pool_size = 1`) opens an overflow slot, gives both back, and waits for the background reaper to
  close the idle one. The reaper sweeps every 15 s, so the step takes about that long. Exit 4 if no
  sweep closes it within 40 s.
- `close`: a slow statement started with `fetch_async` is still on the SQLite worker when
  `close_pool!(pool; drain_seconds = 0)` runs, so the pool defers the handle's close until the
  statement ends (#327). Exit 5 if the close was not deferred or the handle is still open after 60 s.

```
julia --project=test/trim test/trim/prep.jl run-tasks && build/read run-tasks tasks
...
step	reap	closed 1 idle overflow connection after 15079 ms
step	close	deferred, the handle closed 707 ms after the pool
```

It is a separate run, not part of the default one, because it adds about 20 s.

**The workflow** (`.github/workflows/trim.yml`, named `Trim (juliac)`) builds this entry with the
Julia and JuliaC versions above, runs the binary under a 300 s timeout, and fails unless it exits 0
and prints the `row` line above. It then makes the `tasks` run, which fails unless it exits 0 with
both its lines. The timeout is there because a task body the image never compiled
dies silently, so a broken binary hangs rather than crashes (#1788). The verifier's rows are
reported, never checked: the step lines of both runs, `rows.py` and `classify.py --layers` go to the
job summary, and the build log, both tables and the step lines are uploaded as the `trim-read-only`
artifact. It runs nightly, by hand
(`workflow_dispatch`), and on a pull request that changes `test/trim/` or the workflow file. It does
not run on every pull request: a trimmed build takes several minutes. A change in `src/` that could
break the trimmed read is checked by running it by hand on the branch, or by the next nightly run.
The fixture's `Manifest.toml` is not committed, so each run resolves the latest SQLite.jl and its
dependencies: a red nightly with no PormG change between it and the last green one may be an upstream
release, and the job's `Instantiate the fixture` step prints the versions it resolved.

## The MySQL variant

`mysql/` builds the same app with MySQL.jl in place of SQLite, to measure the MySQL extension
(`ext/PormGMySQLExt.jl`), which no SQLite build compiles. Its entry, `mysql/main.jl`, boots through
`register_connection("f1", "mysql://…"; adapter = "MySQL")` (#1769), so no YAML is read, and then
runs the typed read only, with no write. The server comes from environment variables (`tools/server.jl`),
read at run time. With none of them set it is `127.0.0.1:1`, where nothing listens, so no database is
needed: under the JIT the read raises `PoolConnectError`, and the binary stops wherever the trimmed
read stops first. The write is left out for two reasons: it would fail at the same connect, and the
binary's write stops at layer 7 before it reaches any driver code.

The boot is in the entry, not in a package, because `juliac` builds a package from a copy of its own
directory, where `../db/models.jl` is not found. From the repository root:

```
julia --project=test/trim/mysql -e 'using Pkg; Pkg.instantiate()'
julia --project=test/trim/mysql test/trim/mysql/main.jl  # the JIT control: boot ok, PoolConnectError

mkdir -p build-mysql && cd build-mysql
JULIA_CPU_TARGET=native juliac --project ../test/trim/mysql --output-exe main \
  --trim=unsafe-warn --experimental ../test/trim/mysql/main.jl 2>&1 | tee build.log
./main
```

The scripts below read its `build.log` the same way.

### Against a MySQL server

| variable | default |
|---|---|
| `PORMG_TRIM_HOST` | `127.0.0.1` |
| `PORMG_TRIM_PORT` | `1` |
| `PORMG_TRIM_USER` | `f1` |
| `PORMG_TRIM_DATABASE` | `f1` |
| `PORMG_TRIM_PASSWORD` | `f1` |

The password is read from its variable only; the binary prints `host:port/database` and never the
user or the password. Give the fixture a database of its own (`pormg_trim`, say), never the
integration suite's F1 database: `mysql/prep.jl` empties the `circuit` and `race` tables before it
seeds them, and refuses a database whose name does not contain `trim`. The host goes into the URL as it
is, so an IPv6 address is not supported; use a name or an IPv4 address. With the variables exported, from
the repository root:

```
julia --project=test/trim/mysql test/trim/mysql/prep.jl  # PormG's DDL, two circuits, one Monaco race
julia --project=test/trim/mysql test/trim/mysql/main.jl  # the JIT control: boot ok, 1 row
build-mysql/main
```

Against a server the trimmed binary connects, binds the parameters and runs the statement. It stops when
the pool hands the result to the typed read: `ConnectionPool._decoded` is called on the untyped value
`await_result` returns, and the image has no code for that call, so it raises `MethodError`. With no
variables set it stops at the connect, as the JIT does.

## Reading the build log

Two scripts in `tools/` count the verifier's rows in a `build.log` saved through `tee`. They need only
Python 3; run them with `-I`, as in the commands below. They are what the round comments on #1599
report:

```
python3 -I test/trim/tools/rows.py build/build.log          # totals, checked against the summary line
python3 -I test/trim/tools/classify.py build/build.log --layers
```

- **`rows.py`** splits the log into rows and prints the totals. The verifier prints its warnings as
  `Error #N` too, on their own counter, so the script tells them apart by counter and checks the
  result against the `Trim verify finished` line. It also counts the rows whose innermost PormG frame is
  in the query builder, the rows naming an abstract node type, and the scope-helper rows.
- **`classify.py`** puts each row into one class, A to I, first match wins: the remaining-work map of
  #1599 rounds 9 and 10. With `--layers` it also prints the rows by the track's layers (the table in
  #1599's body), in two views:
  - *where the row sits*: the innermost PormG file;
  - *by cause*: the layer that owns the class's fix.

  The two views disagree on purpose: a read of an abstract layer-4 slot sits in layer-5 code. The rules
  and the file → layer table are in the script's docstring. Change them in a PR of their own, so that
  one round's counts stay comparable with the next.
