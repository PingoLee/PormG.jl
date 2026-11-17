# Static Compilation (experimental)

!!! warning "Experimental"
    Building a PormG application into a standalone executable with `juliac --trim` is **experimental**.
    One kind of read and the single-row write are known to work, on three drivers, and on SQLite
    `bulk_insert`. Other writes have not run in a trimmed binary yet, and what this page describes may change between
    releases without an upgrade note. Work in progress is tracked in
    [#1599](https://github.com/PingoLee/PormG.jl/issues/1599) (the trimmed application) and
    [#1614](https://github.com/PingoLee/PormG.jl/issues/1614) (the drivers).

`juliac --trim` compiles a Julia program ahead of time into a standalone executable. It keeps only the
code the compiler can follow from the program's entry point. A call the compiler cannot resolve has no
code in the binary, and raises a `MethodError` when the program reaches it. Under the ordinary JIT none
of this applies: every PormG feature works as the rest of this manual describes.

## What works today

This section lists what a trimmed binary has actually run, not what is expected to work. Everything
else is untested in a trimmed binary, even where it compiles.

- **`list(T)`**, the typed read ([Typed reads in a trimmed build](read/index.md#Typed-reads-in-a-trimmed-build)),
  filtered across a foreign key, into a struct of non-null `Int64`, `String` and `Date` fields. It runs
  on three drivers:
  - SQLite, through SQLite.jl;
  - MySQL 8.4, through MySQL.jl;
  - PostgreSQL 18, through Postgres.jl (see [PostgreSQL](#PostgreSQL-through-Postgres.jl) below).

  The same read with a comparison filter on a date or an integer (`filter("date__@gte" => Date(2008, 6, 1))`,
  `filter("round__@lt" => 10)`), and with `order_by("date")` or `order_by("-date")`, has run on the three
  drivers too (#1599). The other comparison lookups (`__@gt`, `__@lte`, `__@range`) take the same render and
  have not run.

  The other typed terminals (`first(T)`, `last(T)`, `get(T, …)`, `earliest(T, …)`, `latest(T, …)`),
  nullable fields (`Union{Nothing, X}`) and the other column types (`DateTime`, `Time`, `Decimal`, …)
  are built to run trimmed, but no trimmed binary has run them yet.
- **The single-row write**, on SQLite through SQLite.jl, on MySQL 8.4 through MySQL.jl and on
  PostgreSQL 18 through Postgres.jl (#1694, #1614):
  - `create` with name–value pairs (`M.Race.objects.create("year" => 2009, …)`), including the fields
    the write fills itself: a `DateTimeField(auto_now_add = true)`, a `DateField(auto_now = true)` and a
    `UUIDField(auto_add = true)`. The timestamp is written in PormG's own text and read back from it;
  - `update` of the rows a filter matches (`filter(…).update("round" => 7)`), which returns the row count;
  - `delete` of the rows a filter matches (`filter(…).delete()`), which returns the count and the rows
    per table. The delete that has run removes rows nothing else references: no cascade, no `SET NULL`.
    On MySQL and PostgreSQL it takes their row lock (`SELECT … FOR UPDATE`) first, as under the JIT;
  - the refusals PormG raises before any SQL: an `InvalidValueError` for a date string that is not a
    calendar date, and for a `Bool` given to a text column (run on SQLite; the check is the same on every
    driver).
- **`bulk_insert` on SQLite** (#1694), from a `Vector` of `NamedTuple`s whose element type is concrete
  (`[(year = 2010, round = 6, …), …]`), with the fields the write fills itself left out (the same
  `auto_now_add`, `auto_now` and `auto_add` fields as above) and no `columns=`, `on_conflict` or
  `returning`. It returns `(count = 2, rows = nothing)` and a typed read sees the rows. No trimmed
  binary has run any other input: not a `DataFrame`, a `NamedTuple` of vectors or the other keyword
  options, nor a row that fails validation (see below). Two of them are known not to work yet:
  `returning=` and a primary-key column in the table still take calls a trimmed binary cannot make.
- **A statement the server refuses** reaches your code as the `StatementError` it raises under the JIT,
  with the server's SQLSTATE (MySQL and PostgreSQL; SQLite has none), its message, and the driver's
  error as the cause ([Error Handling](errors.md)). `IntegrityError` and `OperationalError` take the
  same path, but no trimmed binary has raised one yet.
- **The pool's background tasks** on SQLite: the idle reaper, and the deferred close of a connection a
  statement is still running on.

PormG checks these with a fixture application, `test/trim/` in the repository. Its `Trim (juliac)`
workflow builds and runs it every night: the SQLite read (its comparison filters and `order_by` included) and
the pool's tasks, the SQLite write
(refusals, create, read, update, delete, `bulk_insert`), and the MySQL and Postgres.jl reads, single-row
writes and refused statements,
against a MySQL 8.4 and a PostgreSQL 18 server. The SQLite refused statement is checked by hand.

## What does not work yet

- **Writes beyond the single-row write** (#1694) have not run in a trimmed binary. Use the JIT for
  them, or a separate process:
  - `bulk_insert` on MySQL or through Postgres.jl;
  - `bulk_update`, `bulk_copy` and the other bulk writers, and `bulk_insert` beyond the input above;
  - a `bulk_insert` row that fails validation or formatting: the pass that names the failing cell
    reads the column and calls the field's formatter untyped, which a trimmed binary cannot run, so
    the caller gets that pass's `MethodError` rather than the refusal;
  - a delete that cascades or sets a foreign key to NULL;
  - the other write terminals (`get_or_create`, `update_or_create`, an upsert, deleting one row
    through `delete(row)`).
- **Timestamp text PormG did not write.** A timestamp PormG validates or reads back as text is parsed
  by hand when it carries a `Z` or a `±hh:mm` offset, after its milliseconds are brought to three
  digits: PormG's own text, `2009-05-24T14:00:00.000+00:00`, is that shape, and it has run trimmed on
  SQLite. Text with no offset goes through Dates' `DateTime` parser instead; on SQLite's read path,
  text with any other offset spelling (`+hhmm`, a zone name) goes through TimeZones.jl's parser, which
  a trimmed binary cannot run. Neither has run trimmed, and neither has a non-UTC offset, though the
  hand parser reads it.
- **LibPQ.** A binary built with LibPQ aborts before `main` runs, with
  `InitError(:Infinity, MethodError(...))`. LibPQ depends on Infinity.jl, whose `__init__` uses
  Requires' `@require`, which a trimmed binary cannot run. The cause is upstream. Use Postgres.jl
  (`postgres_driver = "Postgres"`) for PostgreSQL.
- **Untyped reads.** `.list()`, `.first()` and `.get()` without a type, `list(:dict)`, `list(:json)`,
  a raw `fetch` or `execute`, and `DataFrame(query)` hold their values as `Any`, and are JIT-only.
- **`connection.yml`.** A trimmed binary cannot parse YAML. Register the connection in code, at run time
  (below).
- **Migrations.** The binary does not run `migrate`. Migrate the database from a JIT process.
- **Log records.** A trimmed binary prints no `@error` records, so do not rely on PormG's log messages
  (its warnings included) reaching your output. Print what you need yourself, to `Core.stdout`, as the
  examples below do: in a trimmed binary, `Base.stdout` is not the process's standard output.

## Versions

The versions PormG builds with are **Julia 1.13.3** and **JuliaC 0.3.12**. Other versions may work, but
these are the ones the workflow runs. Install JuliaC as a Julia app, which puts `juliac` in
`~/.julia/bin`:

```
julia -e 'using Pkg; Pkg.Apps.add(name = "JuliaC", version = "0.3.12")'
```

## Building

The application is a project of its own. Its `Project.toml` lists PormG, the driver (`SQLite`, `MySQL`
or `Postgres`) and `Dates`, plus `Base64` for a Postgres.jl program (see below). From the project's
directory:

```
mkdir -p build && cd build
JULIA_CPU_TARGET=native juliac --project .. --output-exe f1app \
  --trim=unsafe-warn --experimental ../f1app.jl 2>&1 | tee build.log
```

- `--output-exe` takes a bare name, not a path.
- `--trim=unsafe-warn` lists each call the compiler cannot resolve (as `Error #N` lines) and still
  links the binary. Such a call raises a `MethodError` naming the function if the program reaches it.
- Pipe the build through `tee` rather than redirecting it: a redirect has lost the end of the report.
- Run the program under the JIT first (`julia --project f1app.jl …`). The binary should print the same.

## A trimmed application

The entry point is a `@main` function. The connection is registered and the models bound inside it,
at run time. PormG refuses to register a connection while the image is being written
([Built images read their configuration at run time](configuration/setup.md#Built-images-read-their-configuration-at-run-time)),
and anything the program's code holds as a literal, a password included, is compiled into the binary.
So read the connection's details from the environment or from the arguments, inside a function: a read
at the top level of the entry file would be frozen into the image. The models are bound with
`set_models(models.MODEL_SET; key)`, since a trimmed image cannot look `MODEL_SET` up by name
([Binding models to a dynamic connection](configuration/dynamic.md#Binding-models-to-a-dynamic-connection)).

```julia
# f1app.jl: run as `f1app <directory holding f1.sqlite>`
using PormG, SQLite, Dates

include(joinpath(@__DIR__, "db", "models.jl"))   # the F1 models; the file ends with `Models.@models …`
import .models as M

# Six of the fields `M.Race.objects.list(show_query = :struct)` prints (#1632). The typed read projects
# the struct's fields, so a field you do not need can be left out.
struct RaceRow
    raceid::Int64
    year::Int64
    round::Int64
    circuitid::Int64
    name::String
    date::Date
end

function (@main)(args::Vector{String})::Cint
    # A path relative to the working directory at run time, not to the binary: pass it in.
    db = joinpath(abspath(args[1]), "f1.sqlite")
    PormG.register_connection("f1", db; adapter = "SQLite", env = "prod")
    PormG.Models.set_models(models.MODEL_SET; key = "f1")
    try
        for r in M.Race.objects.filter("circuitid__country" => "Monaco").list(RaceRow)
            println(Core.stdout, r.year, " ", r.name, " ", r.date)
        end
    finally
        close_all!()   # a trimmed binary runs no atexit hook (see below)
    end
    return Cint(0)
end
```

`list(show_query = :struct)` prints the struct for a query
([Writing `T`](read/index.md#Writing-T:-show_query-:struct)). PormG returns it as text and never
evaluates it in your module: paste it and review it. In a trimmed binary, keep to the field types listed
under [What works today](#What-works-today) until the others have run trimmed.

## MySQL

Register a `mysql://` URL with `adapter = "MySQL"`
([Runtime Registration](configuration/dynamic.md#Runtime-Registration)), built at run time. Percent-encode
the user name and the password when they hold a reserved character:

```julia
function (@main)(args::Vector{String})::Cint
    url = string("mysql://", ENV["F1_DB_USER"], ":", ENV["F1_DB_PASSWORD"], "@", ENV["F1_DB_HOST"], "/f1")
    PormG.register_connection("f1", url; adapter = "MySQL", env = "prod")
    # … set_models, the read, close_all!, as above
end
```

The workflow's binary logs in through MySQL 8.4's full `caching_sha2_password` authentication. MySQL.jl
prefers TLS by default (`ssl_mode = preferred`), and MySQL 8.4 offers it; the workflow does not check
that the connection used it.

## PostgreSQL through Postgres.jl

Register a `postgresql://` URL with `postgres_driver = "Postgres"`, built at run time as for MySQL:

```julia
url = string("postgresql://", ENV["F1_DB_USER"], ":", ENV["F1_DB_PASSWORD"], "@", ENV["F1_DB_HOST"], "/f1")
PormG.register_connection("f1", url; adapter = "PostgreSQL", postgres_driver = "Postgres", env = "prod")
```

**Connection parameters.** A trimmed binary connects through four connection shapes: a host, port,
user and database, with a password or none, and with an `sslmode` or none. PormG sets `options` itself.
All four are compiled into a trimmed binary. The workflow runs one of them:

| | no `sslmode` | an `sslmode` |
|---|---|---|
| **a password** | run (CI) | compiled, not yet run |
| **no password** | compiled, not yet run | compiled, not yet run |

Any other parameter (`connect_timeout`, `application_name`, `sslrootcert`, `sslcert`, `sslkey`,
`statement_timeout`, …) takes Postgres.jl's own connect, which a trimmed binary has no code for. The
connect then fails with `PoolConnectError`, whose cause is a `MethodError`.

**SCRAM authentication.** SCRAM-SHA-256, PostgreSQL's default password authentication, runs in SASLAuth
through Base64's encode and decode pipes, which keep their stream in a field typed `IO`. A trimmed image
has no code for the `IOBuffer` methods those calls reach, and authentication fails with a
`MissingCodeError`. Root them in your entry file, at the top level, with `Base.Experimental.entrypoint`.
It keeps a method in a trimmed image and does nothing under the JIT (a `precompile` statement does not
keep code in a trimmed image):

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

- `close_all!()`, exported by PormG, closes every registered pool: the call the exit hook makes
  ([API](api.md));
- `PormG.Configuration.close_pool!("f1")` closes one.

A connection left open is dropped when the process ends: the server sees the client vanish rather than
close, and SQLite's handle is never closed. `close_all!()` has been run in a trimmed binary on SQLite;
on the MySQL and Postgres.jl pools it takes the same path but has not been run trimmed yet.

## Errors in a trimmed binary

Catch PormG's errors as usual (`catch e; e isa PormG.StatementError || rethrow()`). To report one, read
its typed fields, `e.sqlstate` (`nothing` on SQLite) and `e.message`, rather than printing the exception.
`e.cause` is the driver's error with no declared type: print `nameof(typeof(e.cause))`, never the cause
itself. Printing a value whose type the compiler cannot see calls code the image may not have. The
fixture's `test/trim/tools/failing.jl` shows the pattern.
