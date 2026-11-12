# The `juliac --trim` fixture app

A minimal F1 application built with `juliac --trim`, the measuring stick for #1599 (a PormG app
built as a trimmed binary). It is #1616's first checkbox: the app is committed here; the CI job that
builds it on every PR is a workflow change, the maintainer's.

What it does (`main.jl`): boot with the connection built in code (`register_connection` and
`Models.set_models(models; key)`, #1606 — no `connection.yml` is read), one `Race.objects.create`,
and one `Race.objects.filter("circuitid__country" => "Monaco").list(RaceRow)`, where `RaceRow` is the
struct `list(show_query = :struct)` writes (#1632). Each step prints one line.

Not a test the suite runs: it needs Julia 1.13 and JuliaC, and today the binary stops before the
query (the walls left are in #1599's tables).

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

## The MySQL variant

`mysql/` builds the same app with MySQL.jl in place of SQLite, to measure the MySQL extension
(`ext/PormGMySQLExt.jl`), which no SQLite build compiles. Its entry, `mysql/main.jl`, boots through
`register_connection("f1", "mysql://…@127.0.0.1:1/f1"; adapter = "MySQL")` (#1769), so no YAML is
read, and then runs the typed read only, with no write. Nothing listens on port 1, so no database is
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
