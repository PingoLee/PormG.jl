# Static Compilation (experimental)

!!! warning "Experimental"
    Building a PormG application into a standalone executable with `juliac --trim` is **experimental**.
    The reads and writes listed under [What works today](#What-works-today) are known to work, on the
    drivers each item names. Anything else has not run in a trimmed binary yet, and what this page describes may change
    between releases without an upgrade note. Work in progress is tracked in
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
  - PostgreSQL 19, through Postgres.jl (see [PostgreSQL](#PostgreSQL-through-Postgres.jl) below).

  The same read with a comparison filter on a date or an integer (`filter("date__@gte" => Date(2008, 6, 1))`,
  `filter("round__@lt" => 10)`), and with `order_by("date")` or `order_by("-date")`, has run on the three
  drivers too (#1599), and so have the other common lookups: `__@gt`, `__@lte`, a range of dates
  (`"date__@range" => [Date(2008, 5, 1), Date(2008, 6, 30)]`), a membership list of integers or of text
  (`"round__@in" => [6, 7]`, `"name__@in" => ["Brazilian Grand Prix"]`), `__@isnull` each way, and a text match
  (`"name__@icontains" => "brazil"`, `"name__@contains" => "Monaco"`). A list of another element type than
  `String`, `Int64`, `Float64`, `Date` or `DateTime` takes the same path through one call a trimmed binary may
  have no code for; so does a pattern lookup over a column of a kind other than text, an integer, a date, a
  timestamp or a UUID.

  A comparison against an expression has run on the three drivers too: an `F` with arithmetic on either side
  (`"year__@gt" => F("round") + 2000`, `filter(F("round") + 1 == 19)`), a date part (`Extract("date", "month") ==
  11`, `"date__@year" => 2008`) and a `Case`/`When` on either side (`"round__@gte" => Case(When("name" => …, then = 6),
  default = 100)`, `filter(Case(When("round__@lt" => 10, then = 1), default = 0) == 1)`). Inside them, the shapes
  those spellings build run at their types; a nested function, a `Case` with an `output_field`, a number function
  (`Sum`, `Round`, …), an `OuterRef`, and an expression on the right of a comparison inside a join's `on(...)` keep a
  call a trimmed binary may have no code for.

  Functions, subqueries, joins, CTEs and windows have run on the three drivers as well (#1826–#1828): `Abs`
  and `Round` over a column, `Count` and `Sum` grouped by a column, `Upper(Lower(…))`, a `Case` whose `then`
  is an `F`; `__@in` a queryset, `Exists` correlated with `OuterRef`, a correlated scalar `Subquery` as a
  column or on the right of a filter; `values()` and `order_by()` across a join; a CTE read as a column and
  in a filter, over a body projecting a `Subquery`, an `Exists`, a window, a `Case`, a `Cast` or `F` arithmetic; `RowNumber` over a partition and `Rank` over an order.

  So have the read shapes applications use most (#1599 layer 5): `values()` two and three relations away
  (`"raceid__circuitid__country"`, and `"parentid__parentid__home_circuitid__country"` through a self-referential
  key twice) and across a reverse relation
  (`"race__year"`); `__@yyyy_mm`, `__@ne` and `__@nin`; `Qor` over a lookup and a nested `Q`; `order_by("-date")`
  with `page(n)`, `page(n, offset)` and `limit(n).offset(m)`; `Count(…; distinct = true)`, `Max`, `Avg` and `Min`
  grouped; `Sum(Case(When(…), default = 0))`; `distinct()`; `ToChar(…, "YYYY-MM")` ordered by its alias; a CTE
  joined with `join_type = "INNER"`; and a filter on an aggregate alias, which renders in `HAVING`
  (`values("year", "n" => Count("raceid")).filter("n__@gt" => 1)`, a `Sum` alias with `__@gte`, and a value of the
  wrong type refused with the JIT's `InvalidValueError`, #1846). A membership or range list on an alias
  (`"n__@in" => […]`) takes the old per-element path through one call a trimmed binary may have no code for. `__@regex` and `__@iregex` have run on PostgreSQL, and `Extract("date",
  "EPOCH")` on MySQL and PostgreSQL. An engine without one of them (`__@regex`, `__@iregex` and
  `__@iunaccent_contains` on SQLite and MySQL, `EPOCH` on SQLite) refuses it with the `BackendCapabilityError`
  the JIT raises. `__@iunaccent_contains` has run on PostgreSQL, in a database where `unaccent` is
  installed (`migrate` installs it when `connection.yml` names it under `extensions:`). The JSON (`__@jcontains`, `__@has_key`, `__@has_any_keys`, `__@has_keys`) and network
  (`__@net_contained`, …, `__@family`, `__@prefixlen`) lookups have run on PostgreSQL, and SQLite and MySQL refuse
  each with the `BackendCapabilityError` the JIT raises, and so have the array lookups (`__@acontains`,
  `__@contained_by`, `__@overlap`) over an `ArrayField(IntegerField())`. A filter value PormG refuses before any SQL
  (one a field's formatter refuses, or a `__@year` bound) raises the `InvalidValueError` the JIT raises, located with
  its field and type.
  `Q` and `Qor` with 32 arguments or more have run too, built literally or by `push!` over a `Vector` of concrete
  pairs (`q = Qor(); for p in pairs; push!(q, p); end`). Not `Qor(pairs...)` over a `Vector`: a splat whose length is
  known only at run time is a call `juliac --trim` refuses, whatever the vector's element type, and a `Vector` whose
  pairs' values are typed `Any` (`Pair{String,Any}`) leaves each pair's lookup to be chosen at run time.

  The untyped read (`.list()` and `list(:dict)`, #1823) has run on the three drivers too.

  The other typed terminals (`first(T)`, `last(T)`, `get(T, …)`, `earliest(T, …)`, `latest(T, …)`) and the other
  column types (`DateTime`, `Time`, …) are built to run trimmed, but no trimmed binary has run them yet. Nullable
  fields (`Union{Nothing, X}` of a `String`, an `Int64` or a `Float64`) have run, and a `Decimal` on MySQL and
  PostgreSQL.
- **The single-row write**, on SQLite through SQLite.jl, on MySQL 8.4 through MySQL.jl and on
  PostgreSQL 19 through Postgres.jl (#1694, #1614):
  - `create` with name–value pairs (`M.Race.objects.create("year" => 2009, …)`), including the fields
    the write fills itself: a `DateTimeField(auto_now_add = true)`, a `DateField(auto_now = true)` and a
    `UUIDField(auto_add = true)`. The timestamp is written in PormG's own text and read back from it;
  - `update` of the rows a filter matches (`filter(…).update("round" => 7)`), which returns the row count;
  - `delete` of the rows a filter matches (`filter(…).delete()`), which returns the count and the rows
    per table. A delete that cascades has run too (#1829): a race whose pit stops go with it (`CASCADE`)
    and whose debuting driver keeps a `NULL` debut (`SET_NULL`). On MySQL and PostgreSQL it takes their
    row lock (`SELECT … FOR UPDATE`) first, as under the JIT;
  - the refusals PormG raises before any SQL: an `InvalidValueError` for a date string that is not a
    calendar date, and for a `Bool` given to a text column (run on SQLite; the check is the same on every
    driver).
- **`bulk_insert`** (#1694, #1614), on SQLite, on MySQL 8.4 and on PostgreSQL 19 through Postgres.jl
  (whose bulk write binds each column as an array, `unnest`), from a `Vector` of `NamedTuple`s whose element type is concrete
  (`[(year = 2010, round = 6, …), …]`), with the fields the write fills itself left out (the same
  `auto_now_add`, `auto_now` and `auto_add` fields as above) and no `columns=`, `on_conflict` or
  `returning`. It returns `(count = 2, rows = nothing)` and a typed read sees the rows. A row that
  fails validation is refused as under the JIT: an `InvalidValueError` naming its row and field (a
  date that is not a calendar date has run, on SQLite), with no row written (#1694).

  An **upsert** has run on the three drivers too: rows that carry their primary key, with
  `on_conflict = (action = :update, target = ["raceid"], set = ["round"])` (an existing row updated, a new one
  inserted, count 2) and with `on_conflict = (action = :nothing, target = ["raceid"])` (the existing row skipped,
  count 1). A write with explicit keys then brings the table's sequence up to date, as under the JIT (SQLite's
  `sqlite_sequence`, PostgreSQL's `setval`). On MySQL the target must be the one unique key the rows can conflict
  on, as under the JIT (#1267).

  No trimmed binary has run any other input: not a `DataFrame`, a `NamedTuple` of vectors or the other keyword
  options. **`returning=` does not work yet:** its rows are a table whose type follows the field names you pass,
  the values read and your table's kind, and a trimmed binary has no code for a type it cannot know when it is
  built. On MySQL, a `returning=` that needs keys drawn before the INSERT is refused before any SQL, with the
  `BackendCapabilityError` the JIT raises, and that refusal has run trimmed.
- **A user transaction** (#1599 layer 2), on the three drivers: a `run_in_transaction(key) do … end`
  block that commits, and an `atomic(key) do … end` block that rolls back when the block raises its own
  error, which reaches the caller unchanged. A typed read after each shows the outcome.
- **A transaction inside a transaction** (#1599 layer 2), on the three drivers: a function that opens its own
  `run_in_transaction(key)` block, called from inside another block on the same key, becomes a savepoint. When it
  raises, only its savepoint rolls back, and the outer block, catching the error, commits.
- **A read on a spawned task** (#1599 layer 2), on the three drivers: a typed read on a task `Threads.@spawn`
  starts and on one `@async` starts. The workflow runs each binary with one thread. A trimmed binary takes its thread
  count from `JULIA_NUM_THREADS`, and run by hand with two threads, the three binaries read the same rows, `@spawn`
  running the read on another thread. The task's closure must capture a value (an argument, not a literal), or the
  build folds it and compiles no body for the task.
- **Two connection keys on one database** (#1599 layer 1), on the three drivers: the second registered with writes
  off, read through with `.db("f1_ro")`, and a create through it refused with `WritesDisabledError`, as under the JIT.
- **Models loaded with `@import_models` in a package's module body** (#1599 layer 3), on SQLite. See
  [Migrating an application boot](#Migrating-an-application-boot).
- **`bulk_update`** from a `Vector` of `NamedTuple`s with `columns=` and one `match_on=` key, with a
  constant `filters=` predicate (`filters = ["year" => 2010]`) and with two `match_on=` keys, and
  **`update_or_create`** and **`get_or_create`**, on the three drivers (#1694).
- **Bulk writes from a column table** (#1694), on the three drivers: `bulk_insert` from a `NamedTuple` of vectors (the
  shape a `DataFrame` hands a bulk writer) whose columns are named otherwise than the fields, through `columns =
  ["yr" => "year", …]`, and `bulk_update` from one, matched on a field under two `filters=` pairs whose values have
  different types (`filters = ["circuitid" => 1, "name" => "Monaco Grand Prix"]`).
- **A delete through `SET_DEFAULT`** (the child's key set back to its `default`), a **self-referential
  `CASCADE`** (a chain of rows of one table deleted level by level, #1377) and a **self-referential `SET_NULL`**, on the
  three drivers (#1694).
- **A delete refused by `PROTECT` or `RESTRICT`** (#1694), on the three drivers: `ProtectedError` naming the referencing
  model and field, before any row is deleted.
- **`create` on PostgreSQL whose `INSERT … RETURNING` returns no row** (a trigger or rule skipped it), through
  Postgres.jl: the `StatementError` the JIT raises (#1694).
- **The bulk writers' refusals** before any SQL, each the error type and text the JIT raises: a query or a
  value that is no table, ragged or empty columns, a `columns=` of the wrong type or mapping a field twice, a
  column in another case, a primary key set, a `match_on=` pair or unknown field, a per-row key or a
  non-predicate in `filters=`, a key given twice, a joined path, an ordered handler or one with a CTE, and the
  `returning=` and `on_conflict=` misuses (#1694).
- **The terminals applications use most** (#1599 layer 6), on the three drivers: `count()` over a filter, across a
  join and over no row; `exists()`; `select_for_update(of = ("self",))` as a read inside `run_in_transaction`; the
  raw `fetch` hatch with values bound by the backend's own markers (`fetch(settings, "UPDATE … WHERE year = ?",
  [2008])`), outside and inside a transaction. `count()` returns the driver's value untyped, so state the type where
  you use it, `count()::Int`, as you declare a typed read's row type: a call on an untyped value has no code in a
  trimmed binary unless that exact call was compiled. `exists()` answers a `Bool` PormG computes, inferred as such, so
  it needs no annotation.
- **Typed rows into a table sink** (#1599 layer 6), on the three drivers: `Tables.columntable(rows)` over the rows
  `list(T)` returns, a `NamedTuple` of typed vectors. `Tables` is a dependency of your application, as it is of a
  `DataFrame`.
- **A statement the server refuses** reaches your code as the `StatementError` it raises under the JIT,
  with the server's SQLSTATE (MySQL and PostgreSQL; SQLite has none), its message, and the driver's
  error as the cause ([Error Handling](errors.md)). `IntegrityError` and `OperationalError` take the
  same path, but no trimmed binary has raised one yet.
- **The pool's background tasks** on SQLite: the idle reaper, and the deferred close of a connection a
  statement is still running on.

PormG checks these with a fixture application, `test/trim/` in the repository. Its `Trim (juliac)`
workflow builds and runs it every night, on SQLite and against a MySQL 8.4 and a PostgreSQL 19 server:
the reads above (lookups, expressions, functions, subqueries, joins, CTEs, windows, the untyped read),
the writes above (create, update, delete, the cascading, `SET_DEFAULT` and self-referential deletes,
`bulk_insert`, `bulk_update`, `update_or_create`, `get_or_create`), the refusals and the refused statements, and on SQLite the pool's
tasks. The SQLite refused statement is checked by hand.

## What does not work yet

- **Writes beyond those listed above** (#1694) have not run in a trimmed binary. Use the JIT for
  them, or a separate process:
  - `bulk_copy`, `bulk_insert` beyond the input above, and `bulk_update` beyond the input above
    (a `filters=` value of a type other than an integer, text, a `Bool`, a float, a date, a timestamp or a
    list of integers or text; three or more `match_on=` keys, or keys of other types);
  - a `bulk_insert` row refused for any reason other than the one that has run: a collection
    in a column, an SQL expression for a value, a formatter that raises something other than an
    `InvalidValueError`, or a value PormG fills itself. The pass that names the cell is built to run
    trimmed in each case, but no trimmed binary has refused one;
  - `bulk_insert(…; returning = …)` (see above), an upsert without a `target` (`on_conflict = :nothing`), and
    deleting one row through `delete(row)`.
- **A join target named by a string**: `cjoin("circuitid" => "Circuit")` and `cjoin_on("Circuit", …)` look the model up by
  its name in the models module when the query is built, and have not run trimmed. Pass the model itself
  (`cjoin_on(M.Circuit, …)`, `cjoin(…; field = Models.ForeignKey(M.Circuit, …))`). A relation declared on a model,
  forward or reverse, many-to-many included, reads the model registration recorded (#1689).
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
- **A query as a table** (`Tables.columns(query)`, `Tables.columntable(query)`, `query |> DataFrame`). The table's
  type is the result's, decided when the statement runs: its column names and element types come from the data, and
  each driver builds it at that type (SQLite's materialized rows, MySQL's `NamedTuple` of its columns, Postgres.jl's
  `Tables.buildcolumns`). A trimmed binary has no code for a type it did not know when it was built, so the call fails.
  Read typed rows instead and hand them to the sink: `Tables.columntable(M.Race.objects.values(…).list(T))`.
- **`DataFrame`, even from typed rows.** DataFrames holds a frame's columns as a `Vector{AbstractVector}`, so building
  one (`DataFrame(rows)`) and every operation on its columns dispatch at run time; a trimmed binary stops in
  DataFrames' own constructor (`DataFrame(columns::Vector{AbstractVector}, colindex)`, measured with DataFrames 1.8.3).
  The cause is upstream. A `NamedTuple` of vectors (`Tables.columntable`) is the column table a trimmed binary can use.
- **The result of a raw `fetch`.** The hatch returns the driver's own result (a vector of rows on SQLite, a
  `MySQLResult`, a `Postgres.Result`), untyped and of a different type on each engine, and reading it as a table is the
  run-time-typed case above. Read what a raw statement changed through the ORM, as the fixture does.
- **Other untyped reads**: `list(:json)` and `execute` have not run in a trimmed binary.
- **`connection.yml`.** A trimmed binary cannot parse YAML. Register each connection in code, at run time
  ([Migrating an application boot](#Migrating-an-application-boot)).
- **Migrations.** The binary does not run `migrate`. Migrate the database from a JIT process.
- **Log records.** A trimmed binary prints no `@error` records, so do not rely on PormG's log messages
  (its warnings included) reaching your output. Print what you need yourself, to `Core.stdout`, as the
  examples below do: in a trimmed binary, `Base.stdout` is not the process's standard output.

## JIT-only tools

These parts of PormG are tools for a JIT process (the REPL, a script, a deploy step), not for a trimmed binary. Each
either runs code it reads or generates while the program runs, or depends on a package a trimmed binary cannot run.
Use them from a JIT process beside the binary:

- **Migrations:** `makemigrations`, `migrate`, `get_migration_plan`, `run_once`, `init_migrations` and the migration
  planner. The planner `include`s the models file it compares with the database at run time, so the binary does not run
  `migrate` (#1603). Migrate the database from a JIT process before the binary starts.
- **Generating and importing models:** `generate_models_from_db` / `inspectdb`, the importers
  (`import_models_from_postgres`, `import_models_from_sqlite`, `import_models_from_mysql`, `import_models_from_django`)
  and `convertSQLToModel`. They write model source for you to compile in.
- **Loading models at run time:** `import_models(path)`, which `include`s a models file while the program runs, and hot
  reload: Revise, and `@models_module`'s reloading. A trimmed binary compiles its models in: `include` the models file at
  the top level of the entry, as [A trimmed application](#A-trimmed-application) does.
- **Changing the schema at run time:** `add_field!`, which registers a field on a model that is already bound. It has
  not run in a trimmed binary: declare the field in the models file instead.
- **Reading `connection.yml`:** `load`, `load_many` and `setup`. YAML.jl's parser cannot run in a trimmed binary
  (JuliaData/YAML.jl#260). Register each connection in code ([Migrating an application boot](#Migrating-an-application-boot)).
- **LibPQ:** a binary built with it aborts before `main` (see [What does not work yet](#What-does-not-work-yet)). Use
  Postgres.jl.
- **Writing code for you:** `list(show_query = :struct)`, which prints the struct a typed read takes, and the helpers
  in `src/tools.jl` (`install_ai_skills`, `upgrade_guide`). Run them while you write the program; the binary uses what
  they printed.

## Versions

The versions PormG builds with are **Julia 1.13.4** and **JuliaC 0.3.12**. Other versions may work, but
these are the ones the workflow runs. Install JuliaC as a Julia app, which puts `juliac` in
`~/.julia/bin`:

```
julia -e 'using Pkg; Pkg.Apps.add(name = "JuliaC", version = "0.3.12")'
```

## Building

The application is a project of its own. Its `Project.toml` lists PormG, the driver (`SQLite`, `MySQL`
or `Postgres`) and `Dates`. From the project's
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

**Root PormG's run-time calls.** Some calls PormG makes are run-time calls by design: the query render
re-enters itself for a nested node (a function's operand, a subquery, a CTE body, a window), and a
static call there would close a recursion the compiler limits, leaving no code at all. A trimmed image
keeps code for such a call only where the build rooted its target. `trim_entrypoints` roots every one,
for the pool types you pass, together with the methods a driver's own dependencies need (SCRAM
authentication's for Postgres.jl) and the upstream methods a JLL built with LazyJLLWrappers needs at
start (Libiconv_jll, which PormG loads through YAML). Call it once, at the **top level** of the entry
file, after `using` the driver; a trimmed build keeps what the entry's top level roots, not what a
package's body does. **Under the JIT it does nothing**, so the same file runs with `julia`:

```julia
PormG.trim_entrypoints(PormG.ConnectionPool.SQLiteConnectionPool)
# an app on two engines passes both:
# PormG.trim_entrypoints(PormG.ConnectionPool.MySQLConnectionPool, PormG.ConnectionPool.PostgresConnectionPool{:postgres})
```

Without it, the binary stops before `main` (`InitError(:Libiconv_jll, MissingCodeError(…))`) or at the
first nested read (`Core.MissingCodeError`).

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
PormG.trim_entrypoints(PormG.ConnectionPool.SQLiteConnectionPool)   # a no-op under the JIT (above)

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

## Migrating an application boot

Most PormG applications read their connections from `connection.yml` and load their models with `@import_models`.
For a trimmed binary, the first has to change; the second can stay, in a package.

**`connection.yml` cannot be read.** YAML.jl keeps the input's encoding in a field of an abstract type, so the
first token of every parse is a call a trimmed image has no code for
([JuliaData/YAML.jl#260](https://github.com/JuliaData/YAML.jl/issues/260)), and the parser makes more such calls
after it. A trimmed binary that parses YAML, whatever the file holds, gets a `Core.MissingCodeError`, after the
runtime prints an `Internal error` about the call. PormG cannot tell that it runs in a trimmed binary
(`Base.JLOptions().trim` reads `0` there), so it does not refuse `load` before the parse. Register each connection
in code instead, from `main`, with its values from the environment or the arguments:

```julia
# One call per key the application's `connection.yml` folders held. The environment you passed to
# `load(…; env)` becomes `env`, and each `config:` flag a keyword.
function boot!(env::String)
    PormG.register_connection("f1", ENV["F1_DB_URL"]; adapter = "PostgreSQL", postgres_driver = "Postgres",
                              env = env, change_data = true)
    # A read-only connection: writes stay off, since `change_data` is `false` unless you pass it.
    PormG.register_connection("f1_ro", ENV["F1_DB_RO_URL"]; adapter = "PostgreSQL", postgres_driver = "Postgres",
                              env = env)
end
```

A query picks a key with `.db("f1_ro")`, and a create through a key with writes off is refused with
`WritesDisabledError`, as under the JIT. `register_connection` refuses a key that names a folder in the working
directory, which is reserved for `load`: an application whose keys were the names of its `connection.yml` folders
(`db`, …) and that runs from its own root registers other keys and binds its models to them (below), or runs from
another directory.

**`@import_models` in a package's module body works.** The body runs when the package is precompiled, under the
JIT, so the `load` before `@import_models` reads `connection.yml` then, and each model is bound to the key its
folder had. The package image keeps the models and that binding, and none of the configuration. At run time,
either register that key in code before the first query, and the models use it, or bind them to a key of your
choice, which also works when that key would be a folder name:

```julia
module F1App
using PormG, Postgres
# Runs when the package is precompiled, under the JIT: reads db/connection.yml and binds the models to "db".
PormG.Configuration.load_many(["db"]; root = normpath(joinpath(@__DIR__, "..")), env = "dev")
PormG.@import_models "../db/models.jl" models
end
```

```julia
function (@main)(args::Vector{String})::Cint
    url = ENV["F1_DB_URL"]
    # Either the key the models were bound to …
    PormG.register_connection("db", url; adapter = "PostgreSQL", postgres_driver = "Postgres", env = "prod")
    # … or a key of your own, and the models bound to it:
    # PormG.register_connection("f1", url; adapter = "PostgreSQL", postgres_driver = "Postgres", env = "prod")
    # PormG.Models.set_models(F1App.models.MODEL_SET; key = "f1")
    # … the reads, then close_all!(), as above
end
```

The fixture runs the first form (`TrimF1.Imported` and its `imported` step); `set_models(…; key)` is the boot of
every fixture entry. Four habits of a JIT application do not carry over:

- **A path computed in a package** from `@__DIR__` names the folder `juliac` copied the package to while it built,
  which is gone when the binary runs. Pass paths in at run time, from the arguments or the environment.
- **An `__init__` that loads `connection.yml`** fails in a trimmed binary, on that path or on the YAML parse.
  Move the connection setup into a function that `main` calls, and call the same function from the JIT entry.
- **The entry file's top level is not a module body:** there, `load` is refused while the image is written
  (above), so `@import_models` and the `load` before it belong in a package. A trimmed binary cannot define a
  module at run time, so models are never loaded from `main`.
- **`Base.invokelatest` around a read** is not needed: the models exist when the binary starts, so a plain call
  reads the same. It has run trimmed, and reads the same rows.

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

The entry's top level calls `PormG.trim_entrypoints(PormG.ConnectionPool.MySQLConnectionPool)`.

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
All four have run in a trimmed binary (#1599 layer 2): the workflow connects through each, the two without a
password as a role the server trusts on the fixture's database. The `sslmode` the workflow sets is `disable`, and
its server has no TLS, so no TLS handshake has run in a trimmed binary yet (`require`, `verify-full`):

| | no `sslmode` | an `sslmode` |
|---|---|---|
| **a password** | run (CI) | run (CI), `sslmode=disable` only |
| **no password** | run (CI) | run (CI), `sslmode=disable` only |

Postgres.jl fills a missing password and `sslmode` from the `PGPASSWORD` and `PGSSLMODE` environment variables,
so with either set the connection takes another of the four shapes. It fills the other parameters from their own
variables too (`PGAPPNAME`, `PGCONNECT_TIMEOUT`, `PGSSLROOTCERT`, `PGSSLCERT`, `PGSSLKEY`, `PGSSLCAPATH`,
`PGGSSENCMODE`, `PGKRBSRVNAME`): with any of them set, the connection is outside the four shapes and a trimmed
binary fails at the connect.

Any other parameter (`connect_timeout`, `application_name`, `sslrootcert`, `sslcert`, `sslkey`,
`statement_timeout`, …) takes Postgres.jl's own connect, which a trimmed binary has no code for. The
connect then fails with `PoolConnectError`, whose cause is a `MethodError`.

**SCRAM authentication.** SCRAM-SHA-256, PostgreSQL's default password authentication, runs in SASLAuth
through Base64's encode and decode pipes, which keep their stream in a field typed `IO`. A trimmed image
has no code for the `IOBuffer` methods those calls reach unless they are rooted, and authentication then
fails with a `MissingCodeError`. `trim_entrypoints` roots them for the Postgres.jl pool, through the
Postgres.jl extension, so the entry needs nothing more than:

```julia
using PormG, Postgres, Dates
PormG.trim_entrypoints(PormG.ConnectionPool.PostgresConnectionPool{:postgres})
```

These roots are needed until Base64's pipes are typed upstream.

## Closing the pools before `main` returns

Under the JIT, PormG closes every pool when the process exits, through an `atexit` hook. **A trimmed
binary runs no `atexit` hook**, PormG's included: a program built with `juliac --trim` that registers
one returns from `main` without running it, where its JIT control runs it. So close the pools yourself
before `main` returns, in a `finally` so an error path closes them too:

- `close_all!()`, exported by PormG, closes every registered pool: the call the exit hook makes
  ([API](api.md));
- `PormG.Configuration.close_pool!("f1")` closes one.

A connection left open is dropped when the process ends: the server sees the client vanish rather than
close, and SQLite's handle is never closed. `close_all!()` has run last in a trimmed binary on SQLite,
MySQL and Postgres.jl (#1599 layer 2): the pool held a connection before it and none after, and that
connection's driver handle was closed.

## Errors in a trimmed binary

Catch PormG's errors as usual (`catch e; e isa PormG.StatementError || rethrow()`). To report one, read
its typed fields, `e.sqlstate` (`nothing` on SQLite) and `e.message`, rather than printing the exception.
`e.cause` is the driver's error with no declared type: print `nameof(typeof(e.cause))`, never the cause
itself. Printing a value whose type the compiler cannot see calls code the image may not have. The
fixture's `test/trim/tools/failing.jl` shows the pattern.
