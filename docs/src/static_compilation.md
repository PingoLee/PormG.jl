# Static Compilation (experimental)

!!! warning "Experimental"
    Building a PormG application into a standalone executable with `juliac --trim` is **experimental**.
    Reads work on three drivers today. Writes do not work yet, and what this page describes may change
    between releases without an upgrade note. Work in progress is tracked in
    [#1599](https://github.com/PingoLee/PormG.jl/issues/1599) (the trimmed application) and
    [#1614](https://github.com/PingoLee/PormG.jl/issues/1614) (the drivers).

`juliac --trim` compiles a Julia program ahead of time into a standalone executable. It keeps only the
code the compiler can follow from the program's entry point. A call the compiler cannot resolve has no
code in the binary, and raises a `MethodError` when the program reaches it. Under the ordinary JIT none
of this applies: every PormG feature works as the rest of this manual describes.

## What works today

- **Typed reads**: `list(T)`, `first(T)`, `last(T)`, `get(T, …)`, `earliest(T, …)` and `latest(T, …)`,
  which build each row into a struct you declare ([Typed reads in a trimmed build](read/index.md#Typed-reads-in-a-trimmed-build)).
  They work on three drivers:
  - SQLite, through SQLite.jl;
  - MySQL 8.4, through MySQL.jl;
  - PostgreSQL, through Postgres.jl (see [PostgreSQL](#PostgreSQL-through-Postgres.jl) below).
- **Server errors.** A statement the server refuses reaches your code as the error it raises under the
  JIT: a `StatementError` (or `IntegrityError`, `OperationalError`) with the server's SQLSTATE, its
  message and the driver's error as the cause ([Error Handling](errors.md)).
- **The pool's background tasks** on SQLite: the idle reaper and the deferred close of a connection a
  statement is still running on.

PormG checks these with a fixture application, `test/trim/` in the repository, which its `Trim (juliac)`
workflow builds and runs every night: the SQLite read on its own, and the MySQL and Postgres.jl reads
against a MySQL 8.4 and a PostgreSQL 18 server.

## What does not work yet

- **Writes.** `create`, `update`, `delete`, `bulk_insert` and the other write terminals do not complete
  in a trimmed binary yet (#1694). Use the JIT for writes, or a separate process.
- **LibPQ.** A binary built with LibPQ aborts before `main` runs, with
  `InitError(:Infinity, MethodError(...))`: LibPQ depends on Infinity.jl, whose `__init__` uses
  Requires' `@require`, which a trimmed binary cannot run. The cause is upstream. Use Postgres.jl
  (`postgres_driver = "Postgres"`) for PostgreSQL.
- **Untyped reads.** `.list()`, `.first()` and `.get()` without a type, `list(:dict)`, `list(:json)`,
  a raw `fetch` or `execute`, and `DataFrame(query)` hold their values as `Any`, and are JIT-only.
- **`connection.yml`.** A trimmed binary cannot parse YAML. Register the connection in code, at run time
  (below).
- **Migrations.** The binary does not run `migrate`; migrate the database from a JIT process.

## Versions

The versions PormG builds with are **Julia 1.13.3** and **JuliaC 0.3.12**. Other versions may work, but
these are the ones the workflow runs. Install JuliaC as a Julia app, which puts `juliac` in
`~/.julia/bin`:

```
julia -e 'using Pkg; Pkg.Apps.add(name = "JuliaC", version = "0.3.12")'
```

## Building

From the directory that holds your application's project:

```
mkdir -p build && cd build
JULIA_CPU_TARGET=native juliac --project .. --output-exe f1app \
  --trim=unsafe-warn --experimental ../f1app.jl 2>&1 | tee build.log
```

- `--output-exe` takes a bare name, not a path.
- `--trim=unsafe-warn` lists each call the compiler cannot resolve (as `Error #N` lines) and still
  links the binary. Such a call raises a `MethodError` naming the function when the program reaches
  it.
- Pipe the build through `tee` rather than redirecting it: a redirect has lost the end of the report.
- Run the program under the JIT first (`julia --project f1app.jl`): it should print the same output as
  the binary.

## A trimmed application

The entry point is a `@main` function. The connection is registered and the models bound inside it, at
run time: PormG refuses to register a connection while the image is being written, so a password never
travels in the binary ([Built images read their configuration at run time](configuration/setup.md#Built-images-read-their-configuration-at-run-time)).
The models are bound with `set_models(models.MODEL_SET; key)`, since a trimmed image cannot look
`MODEL_SET` up by name ([Binding models to a dynamic connection](configuration/dynamic.md#Binding-models-to-a-dynamic-connection)).

```julia
# f1app.jl
using PormG, SQLite, Dates

include(joinpath(@__DIR__, "db", "models.jl"))   # the F1 models; the file ends with `Models.@models …`
import .models as M

# Written by `list(show_query = :struct)` on the same query, then pasted here (#1632).
struct RaceRow
    raceid::Int64
    year::Int64
    round::Int64
    circuitid::Int64
    name::String
    date::Date
end

function (@main)(args::Vector{String})::Cint
    PormG.register_connection("f1", "db/f1.sqlite"; adapter = "SQLite", env = "prod")
    PormG.Models.set_models(models.MODEL_SET; key = "f1")
    try
        for r in M.Race.objects.filter("circuitid__country" => "Monaco").list(RaceRow)
            println(Core.stdout, r.year, " ", r.name, " ", r.date)
        end
    finally
        PormG.Configuration.close_all!()   # a trimmed binary runs no atexit hook (see below)
    end
    return Cint(0)
end
```

The struct is the one `list(show_query = :struct)` prints for the query
([Writing `T`](read/index.md#Writing-T:-show_query-:struct)). PormG returns it as text and never
evaluates it in your module: paste it and review it.

## MySQL

Register a `mysql://` URL with `adapter = "MySQL"`
([Runtime Registration](configuration/dynamic.md#Runtime-Registration)):

```julia
PormG.register_connection("f1", "mysql://f1:s3cr%40t@db.internal:3306/f1"; adapter = "MySQL", env = "prod")
```

The workflow runs the binary's first login through MySQL 8.4's full `caching_sha2_password`
authentication, over the TLS connection MySQL.jl prefers by default.

## PostgreSQL through Postgres.jl

Register a `postgresql://` URL with `postgres_driver = "Postgres"`:

```julia
PormG.register_connection("f1", "postgresql://f1:s3cr%40t@db.internal:5432/f1";
                          adapter = "PostgreSQL", postgres_driver = "Postgres", env = "prod")
```

**Connection parameters.** A trimmed binary connects through four connection shapes: a host, port, user
and database, with

| | no `sslmode` | an `sslmode` |
|---|---|---|
| **a password** | works | works |
| **no password** | works | works |

PormG sets `options` itself. Any other parameter (`connect_timeout`, `application_name`, `sslrootcert`,
`sslcert`, `sslkey`, `statement_timeout`, …) takes Postgres.jl's own connect, which a trimmed binary
has no code for: the connect fails with `PoolConnectError`, whose cause is a `MethodError`.

**SCRAM authentication.** SCRAM-SHA-256, PostgreSQL's default password authentication, runs in SASLAuth
through Base64's encode and decode pipes, which keep their stream in a field typed `IO`. A trimmed image
has no code for the `IOBuffer` methods those calls reach, and authentication fails with a
`MissingCodeError`. Root them in your entry file, at the top level, with `Base.Experimental.entrypoint`,
which keeps a method in a trimmed image and does nothing under the JIT (a `precompile` statement does
not keep code in a trimmed image):

```julia
using PormG, Postgres, Dates, Base64

Base.Experimental.entrypoint(Base.unsafe_write, (IOBuffer, Ptr{UInt8}, Int))
Base.Experimental.entrypoint(Base.write, (IOBuffer, UInt8, UInt8, UInt8, UInt8))
Base.Experimental.entrypoint(Base.eof, (IOBuffer,))
Base.Experimental.entrypoint(Base64.read_to_buffer, (IOBuffer, Base64.Buffer))
Base.Experimental.entrypoint(Base64.decode_slow,
    (UInt8, UInt8, UInt8, UInt8, Base64.Buffer, Int, IOBuffer, Ptr{UInt8}, UInt64, Vector{UInt8}))
```

`Base64` must be a dependency of your project for the last two lines. These roots are needed until
Base64's pipes are typed upstream; they are not PormG's to fix.

## Closing the pools before `main` returns

Under the JIT, PormG closes every pool when the process exits, through an `atexit` hook. **A trimmed
binary runs no `atexit` hook**, PormG's included: a program built with `juliac --trim` that registers
one returns from `main` without running it, where its JIT control runs it. So close the pools yourself
before `main` returns, in a `finally` so an error path closes them too:

- `PormG.Configuration.close_all!()` closes every registered pool, the call the exit hook makes
  ([API](api.md));
- `PormG.Configuration.close_pool!("f1")` closes one.

A connection left open is dropped when the process ends: the server sees the client vanish rather than
close, and SQLite's handle is never closed. `close_all!()` has been run in a trimmed binary on SQLite;
on the MySQL and Postgres.jl pools it takes the same path but has not been run trimmed yet.

## Errors in a trimmed binary

Catch PormG's errors as usual (`catch e; e isa PormG.StatementError || rethrow()`). To report one, read
its fields (`e.sqlstate`, `e.message`, `e.cause`) rather than printing the exception: printing an
exception whose type the compiler cannot see calls code the image may not have. The fixture's
`test/trim/tools/failing.jl` shows the pattern.
