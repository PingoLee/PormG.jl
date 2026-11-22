# The `juliac --trim` fixture app

A minimal F1 application built with `juliac --trim`, the measuring stick for #1599 (a PormG app
built as a trimmed binary). It is #1616's first checkbox.

What it does (`main.jl`): boot with the connection built in code (`register_connection` and
`Models.set_models(models; key)`, #1606 — no `connection.yml` is read), two creates PormG refuses
before any SQL (a date string that is not a calendar date, and a `Bool` for a text column; each prints
the refusal's type and message), the read steps of `tools/reads.jl` (a comparison filter on a date and on an
integer, `date__@gte` and `round__@lt`, an `order_by` each way, and the other common lookups: `__@gt`, `__@lte`,
`__@range`, `__@in` over integers and over text, `__@isnull` each way, `__@icontains` and `__@contains`, and the
comparisons against an expression: an `F` with arithmetic on each side, `Extract`, the `@year` transform and a
`Case`/`When` on each side, over the two races `prep.jl` seeds; #1599 layer 5, then the untyped read: `first()` and
`list()` with no type and a `values(...)` projection, each line naming every cell's type; #1599 layer 6, then the function shapes: a number function in a projection and
in a filter, `Count`/`Sum` grouped by a column, `Upper(Lower(...))` and a `Case` whose `then` is an `F`, each read into
a typed row; #1599 layer 5, then the subqueries: `__@in` a queryset, an `Exists` correlated with `OuterRef`, a correlated
`Subquery` as a column and a `Subquery` on the right of a filter, uncorrelated and correlated, each read into a typed
row; #1599 layer 5), one `Race.objects.create` that leaves the three auto-filled fields
(`created_at`, `updated_on`, `token`) to the write's default fill, and one
`Race.objects.filter("circuitid__country" => "Monaco").list(RaceRow)`, where `RaceRow` is the struct
`list(show_query = :struct)` writes (#1632), then an `update` of the row it wrote and a `delete` of it,
each checked by a typed read after it, then a `bulk_insert` of two races from a `Vector` of
`NamedTuple`s, read back typed, and last a `bulk_insert` whose second row validation refuses (a date that is
not a calendar date), which prints the refusal's type and message and checks that no row was written, then a
`bulk_update` of two bulk-inserted races matched on `raceid` and an `update_or_create` that inserts one explicit id
and then updates it, each read back typed and undone (#1694), and a `get_or_create` that inserts one explicit id
and then finds it through the untyped `first()` (#1599 layer 6), then deletes it, and last a cascading delete: a
race of its own with two pit stops (`CASCADE`) and a driver who debuted in it (`SET_NULL`), deleted and checked by
typed reads, with the pit stop and driver `prep.jl` seeds on the Monaco race left as they were (#1694, #1599 layer
7). Each step prints one line. The read-only entry, `read.jl`, runs
the same boot, read and read steps without the writes; the steps both entries share are in `steps.jl`, and the
ones the server variants share too are in `tools/reads.jl` and `tools/writes.jl`.

Not a test the unit suite runs: it needs Julia 1.13 and JuliaC. The full entry's binary completes
(#1694): it prints both refusals, fills the three automatic values, runs its `INSERT` and reads the row
back on the SQLite worker, and its typed read then returns both rows, the one it wrote included; its
`update` sets that row's `round` and its `delete` removes it, each shown by the read after it; its
`bulk_insert` writes two rows, the three auto-filled fields included, and the typed read sees both; its
`bulk_update` sets both rows' `round` and its `update_or_create` reports an insert and then an update. It
prints the JIT control's lines and exits 0. The read-only entry's binary returns its row (#1788), and the
rows its comparison filters, its `order_by`, its other lookups and its expression comparisons pick out, in order. The
`Trim (juliac)` workflow checks that both binaries still do (see "The read-only entry and its CI job"
and "The full entry's CI job" below).

## Drivers

The fixture runs on SQLite; a MySQL variant is in `mysql/` and a PostgreSQL one in `postgres/` (see
their sections below). For PostgreSQL in a `juliac --trim` build, use Postgres.jl
(`register_connection(…; adapter = "PostgreSQL", postgres_driver = "Postgres")`), as `postgres/`
does. A binary built with LibPQ 1.18
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
julia --project=test/trim test/trim/main.jl run          # the JIT control: refusals, read steps, write, read, update, delete, bulk

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

**Roots.** Every entry calls `PormG.trim_entrypoints(<its pool type>)` at its top level, the one public
call a trimmed app makes (`docs/src/static_compilation.md`, "A trimmed application"): the query render's
run-time re-entries (`QueryBuilder._trim_render_roots`), the driver's own roots (the Postgres.jl
extension's SCRAM methods) and the LazyJLLWrappers roots Libiconv_jll needs at start. Nothing else in the
fixture roots by hand; `test/unit/test_trim_shape_pins.jl` fails on an entry that does.

## The read-only entry and its CI job

`read.jl` is `main.jl` without the write: boot, the typed read, then the read steps. Since #1788 its trimmed
binary prints the row its JIT control prints, and since #1599's layer-5 slices the rows of its comparison filters,
its `order_by`, its other lookups and its expression comparisons; it exits 0:

```
step	main	entered
step	ext	true
step	boot	ok
step	query	1 rows
step	row	1 2008 Monaco Grand Prix 2008-05-25
step	compare	date__@gte 1 rows: Brazilian Grand Prix
step	compare	round__@lt 1 rows: Monaco Grand Prix
step	order	date: Monaco Grand Prix, Brazilian Grand Prix
step	order	-date: Brazilian Grand Prix, Monaco Grand Prix
step	lookup	round__@gt 1 rows: Brazilian Grand Prix
step	lookup	round__@lte 1 rows: Monaco Grand Prix
step	lookup	date__@range 1 rows: Monaco Grand Prix
step	lookup	round__@in 1 rows: Monaco Grand Prix
step	lookup	name__@in 1 rows: Brazilian Grand Prix
step	lookup	date__@isnull false 2 rows: Monaco Grand Prix, Brazilian Grand Prix
step	lookup	date__@isnull true 0 rows: none
step	lookup	name__@icontains 1 rows: Brazilian Grand Prix
step	lookup	name__@contains 1 rows: Monaco Grand Prix
step	expr	year__@gt F(round) + 2000 1 rows: Monaco Grand Prix
step	expr	F(round) + 1 == 19 1 rows: Brazilian Grand Prix
step	expr	Extract(date, month) == 11 1 rows: Brazilian Grand Prix
step	expr	date__@year 2 rows: Monaco Grand Prix, Brazilian Grand Prix
step	expr	round__@gte Case 1 rows: Monaco Grand Prix
step	expr	Case == 1 1 rows: Monaco Grand Prix
step	untyped	first Monaco Grand Prix round 6 date 2008-05-25
step	untyped	first types year::Int64, round::Int64, circuitid::Int64, token::String, name::String, created_at::ZonedDateTime, raceid::Int64, updated_on::Date, date::Date
step	untyped	list 2 rows: Monaco Grand Prix, Brazilian Grand Prix
step	untyped	values 1 rows: round::Int64, name::String; Monaco Grand Prix 6
step	func	Abs/Round 2 rows: Monaco Grand Prix 4 6, Brazilian Grand Prix 8 18
step	func	Abs == 4 1 rows: Monaco Grand Prix
step	func	Count/Sum 1 rows: 2008 2 24
step	func	Upper(Lower) 2 rows: MONACO GRAND PRIX, BRAZILIAN GRAND PRIX
step	func	Case then F 2 rows: Monaco Grand Prix 6, Brazilian Grand Prix 0
step	subquery	circuitid__@in query 1 rows: Monaco Grand Prix
step	subquery	Exists OuterRef 1 rows: Brazilian Grand Prix
step	subquery	Subquery OuterRef column 2 rows: Monaco Grand Prix at Circuit de Monaco, Brazilian Grand Prix at Autódromo José Carlos Pace
step	subquery	circuitid == Subquery 1 rows: Brazilian Grand Prix
step	subquery	round == Subquery OuterRef 2 rows: Monaco Grand Prix, Brazilian Grand Prix
step	join	order_by path 2 rows: Brazilian Grand Prix at Autódromo José Carlos Pace, Monaco Grand Prix at Circuit de Monaco
step	join	order_by -alias 2 rows: Monaco Grand Prix at Circuit de Monaco, Brazilian Grand Prix at Autódromo José Carlos Pace
step	join	CTE column 2 rows: Monaco Grand Prix 1, Brazilian Grand Prix 1
step	join	CTE filter 1 rows: Brazilian Grand Prix 1
step	join	RowNumber partition 2 rows: Monaco Grand Prix 1, Brazilian Grand Prix 2
step	join	Rank order 2 rows: Brazilian Grand Prix 1, Monaco Grand Prix 2
step	cte	Subquery 2 rows: Monaco Grand Prix 2008, Brazilian Grand Prix 2008
step	cte	Exists 2 rows: Monaco Grand Prix false, Brazilian Grand Prix true
step	cte	RowNumber 2 rows: Monaco Grand Prix 1, Brazilian Grand Prix 2
step	cte	Case 2 rows: Monaco Grand Prix 0, Brazilian Grand Prix 1
step	cte	Cast 2 rows: Monaco Grand Prix 6, Brazilian Grand Prix 18
step	cte	F arithmetic 2 rows: Monaco Grand Prix 7, Brazilian Grand Prix 19
step	cte	Case over a list 2 rows: Monaco Grand Prix 0, Brazilian Grand Prix 1
step	elapsed_ms	1
```

Build and run it like the full entry, from the repository root:

```
julia --project=test/trim test/trim/prep.jl run
julia --project=test/trim test/trim/read.jl run          # the JIT control: boot, 1 row, the read steps

mkdir -p build && cd build
JULIA_CPU_TARGET=native juliac --project ../test/trim --output-exe read \
  --trim=unsafe-warn --experimental ../test/trim/read.jl 2>&1 | tee build.log
cd .. && julia --project=test/trim test/trim/prep.jl run && build/read run
```

The two entries `include` the same `steps.jl`, so a step prints the same line in both binaries and
fails with the same exit code (1 boot, 2 write, 3 read, 10 a comparison filter, 11 an `order_by`, 13 one of the
other lookups, 14 an expression comparison, each when it raises or does not return the rows it picks out; `main.jl` exits 6 when a create it expects
PormG to refuse is not refused with an `InvalidValueError`, 7 when its update and 8 when its delete
raises or the read after it does not show the change, and 9 when its `bulk_insert` raises, counts other
than 2 rows, or the read after it does not return them, and 12 when its `bulk_insert` with an invalid row is not
refused with an `InvalidValueError` or writes a row, 15 when its `bulk_update` and 16 when its `update_or_create`
raises, the read after it does not show the change, or the delete that undoes it does not remove its rows). 17 when an untyped read raises or returns other rows, 18 when
`get_or_create` raises, does not insert and then find its row, or the delete after it does not remove it. 19 when a
function read (a number function, an aggregate, a nested function or a `Case` whose `then` is an `F`) raises or returns
other rows, 20 when a subquery read (`__@in` a queryset, `Exists`, a `Subquery` with or without `OuterRef`) does, 21 when a
join, CTE or window read (`values`/`order_by` across a join, a `.with(...)` column in a projection and a filter, `RowNumber`/`Rank`
over a partition and an order) does, 26 when a CTE read over a body the typed copy and the CTE typing take (a
`Subquery`, `Exists`, `RowNumber`, `Case`, `Cast` or `F` column, and a `Case` over a list) does. 22 when the cascading delete raises, leaves a pit stop of the deleted race,
does not clear the driver's debut race, reports other counts, or changes the rows `prep.jl` seeded. 24 when the
user transactions do not commit or roll back as their typed reads expect, and 25 when `close_all!()` leaves a
connection held or its driver handle open (`main.jl` and the server variants; see "Transactions and closing the
pools"). 27 to 30 are the write residue's steps (see "The write residue"). The Postgres.jl variant also exits
23 when one of its connection shapes fails.

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
and prints the `row` line and the read-step lines above (`TRIM_READ_LINES` in the workflow). The untyped read's
lines name each cell's type, which is each engine's own, so every job checks them, and `get_or_create`'s, against
the lines its own JIT control printed (`tools/same_lines.sh`). It then makes the `tasks` run, which fails unless it exits 0 with
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

## The write residue (#1694)

Every write entry runs five more steps after the cascading delete (`tools/writes.jl`), six on MySQL, each deleting
what it wrote (`bulk_conflict` also moves the race table's sequence past its explicit ids):

- `bulk_update_more` (exit code 27): two bulk-inserted races updated through `filters = ["year" => 2010]`
  (only the 2010 row matches) and then through two `match_on=` keys, `year` and `round`, read back typed and
  deleted.
- `set_default` (exit code 28): a circuit of the step's own and a constructor whose home it is; deleting the
  circuit sets the constructor's `home_circuitid` back to `DEFAULT_CIRCUIT_ID` (`db/models.jl`, seeded by each
  `prep.jl` with that fixed id), and the constructor is deleted.
- `self_cascade` (exit code 29): a chain of four constructors (each `parentid` the one before); deleting the
  first deletes the other three through the collector's walk of the table's own key (#1377), and the chain
  `prep.jl` seeds (Toleman, Benetton, Renault) is left as it was.
- `bulk_refusal` (exit code 30): twenty-two inputs the bulk writers refuse before any SQL, one line each with
  the refusal's type and text. The job compares these lines with its JIT control's (`tools/same_lines.sh`),
  since a refusal's text can name engine-specific details.
- `bulk_conflict` (exit code 31): `bulk_insert` with `on_conflict=`, over races with explicit ids far above any id
  a sequence gives in the fixture. One race is written first. An upsert over it and a new race (`action =
  :update`, target `raceid`, `set` `round`) updates the first and inserts the second (`update 2 rows; rounds 7, 6`).
  A skip over the second and a third (`action = :nothing`, target `raceid`) leaves the second as it was and
  inserts the third (`nothing 1 rows; rounds 7, 6, 6`). Each is read back typed, and the three races are
  deleted. A write with explicit keys resyncs the table's sequence, so this step also runs SQLite's
  `sqlite_sequence` reads and PostgreSQL's catalog reads and `setval`.
- `preallocated_keys_refusal_step` (exit code 32, the MySQL entry only; its line is tagged `bulk_refusal`): a
  `bulk_insert` with `returning = ["raceid"]` and no id,
  whose key MySQL cannot draw before the INSERT, refused with the `BackendCapabilityError` the JIT raises. A
  `returning=` that executes does not run trimmed on any engine yet (`docs/src/static_compilation.md`).

## Transactions and closing the pools

Every write entry (`main.jl` and the two server variants) runs `transaction` (exit code 24,
`tools/connections.jl`) after the cascading delete: a `run_in_transaction(KEY) do … end` block creates the 2016
race and reads it inside; an `atomic(KEY) do … end` block creates the 2017 race and raises the app's own
`TrimRollback`, which must reach the caller. Typed reads then see the 2016 race and no 2017 race, and the step
deletes the 2016 race again. `close_all` (exit code 25) is the last step: `close_all!()`, as PormG's exit hook
calls it, since a trimmed binary runs no `atexit` hook, checked by the key's pool holding a connection before
and none after. The read-only entry writes nothing, so it runs neither; its `tasks` run closes its pool through
`close_pool!` (`close` step).

## The full entry's CI job

The workflow's `Trimmed write (SQLite)` job builds `main.jl` the same way, seeds a fresh run directory
with `prep.jl`, and runs the binary under the same 300 s timeout. It fails unless the binary exits 0
and prints each of these lines, as its JIT control prints them:

```
step	refused	InvalidValueError: …        (twice: the invalid date, then the Bool name)
step	compare	date__@gte 1 rows: Brazilian Grand Prix
step	compare	round__@lt 1 rows: Monaco Grand Prix
step	order	date: Monaco Grand Prix, Brazilian Grand Prix
step	order	-date: Brazilian Grand Prix, Monaco Grand Prix
step	lookup	round__@gt 1 rows: Brazilian Grand Prix
step	lookup	round__@lte 1 rows: Monaco Grand Prix
step	lookup	date__@range 1 rows: Monaco Grand Prix
step	lookup	round__@in 1 rows: Monaco Grand Prix
step	lookup	name__@in 1 rows: Brazilian Grand Prix
step	lookup	date__@isnull false 2 rows: Monaco Grand Prix, Brazilian Grand Prix
step	lookup	date__@isnull true 0 rows: none
step	lookup	name__@icontains 1 rows: Brazilian Grand Prix
step	lookup	name__@contains 1 rows: Monaco Grand Prix
step	expr	year__@gt F(round) + 2000 1 rows: Monaco Grand Prix
step	expr	F(round) + 1 == 19 1 rows: Brazilian Grand Prix
step	expr	Extract(date, month) == 11 1 rows: Brazilian Grand Prix
step	expr	date__@year 2 rows: Monaco Grand Prix, Brazilian Grand Prix
step	expr	round__@gte Case 1 rows: Monaco Grand Prix
step	expr	Case == 1 1 rows: Monaco Grand Prix
step	func	Abs/Round 2 rows: Monaco Grand Prix 4 6, Brazilian Grand Prix 8 18
step	func	Abs == 4 1 rows: Monaco Grand Prix
step	func	Count/Sum 1 rows: 2008 2 24
step	func	Upper(Lower) 2 rows: MONACO GRAND PRIX, BRAZILIAN GRAND PRIX
step	func	Case then F 2 rows: Monaco Grand Prix 6, Brazilian Grand Prix 0
step	subquery	circuitid__@in query 1 rows: Monaco Grand Prix
step	subquery	Exists OuterRef 1 rows: Brazilian Grand Prix
step	subquery	Subquery OuterRef column 2 rows: Monaco Grand Prix at Circuit de Monaco, Brazilian Grand Prix at Autódromo José Carlos Pace
step	subquery	circuitid == Subquery 1 rows: Brazilian Grand Prix
step	subquery	round == Subquery OuterRef 2 rows: Monaco Grand Prix, Brazilian Grand Prix
step	join	order_by path 2 rows: Brazilian Grand Prix at Autódromo José Carlos Pace, Monaco Grand Prix at Circuit de Monaco
step	join	order_by -alias 2 rows: Monaco Grand Prix at Circuit de Monaco, Brazilian Grand Prix at Autódromo José Carlos Pace
step	join	CTE column 2 rows: Monaco Grand Prix 1, Brazilian Grand Prix 1
step	join	CTE filter 1 rows: Brazilian Grand Prix 1
step	join	RowNumber partition 2 rows: Monaco Grand Prix 1, Brazilian Grand Prix 2
step	join	Rank order 2 rows: Brazilian Grand Prix 1, Monaco Grand Prix 2
step	cte	Subquery 2 rows: Monaco Grand Prix 2008, Brazilian Grand Prix 2008
step	cte	Exists 2 rows: Monaco Grand Prix false, Brazilian Grand Prix true
step	cte	RowNumber 2 rows: Monaco Grand Prix 1, Brazilian Grand Prix 2
step	cte	Case 2 rows: Monaco Grand Prix 0, Brazilian Grand Prix 1
step	cte	Cast 2 rows: Monaco Grand Prix 6, Brazilian Grand Prix 18
step	cte	F arithmetic 2 rows: Monaco Grand Prix 7, Brazilian Grand Prix 19
step	cte	Case over a list 2 rows: Monaco Grand Prix 0, Brazilian Grand Prix 1
step	write	ok
step	query	2 rows
step	row	1 2008 Monaco Grand Prix 2008-05-25
step	row	3 2009 Monaco Grand Prix 2009-05-24
step	update	1 rows; round 7
step	delete	1 rows; 1 left
step	bulk	2 rows; 2 read back
step	bulk_refused	InvalidValueError: Error in bulk_insert, row 2 for model race, field `date`: The date is invalid: it is not a calendar date in the format YYYY-MM-DD (from column date).
step	bulk_refused	0 rows written; 1 Monaco races
step	bulk_update	2 rows; rounds 7, 8
step	update_or_create	first created true; second created false; round 7
step	get_or_create	first created true; second created false; round 6; year::Int64, round::Int64, circuitid::Int64, token::String, name::String, created_at::ZonedDateTime, raceid::Int64, updated_on::Date, date::Date
step	cascade	3 rows; pitstop 2, race 1
step	cascade	0 pit stops left; 1 driver, debut none
step	cascade	seeded 1 pit stop, 1 driver; kept
step	transaction	committed 1 seen inside, 1 after; rolled back on TrimRollback, 0 left; removed 1
step	close_all	1 open before, 0 after; the handle closed
```

The `func` lines follow the `expr` lines, the `subquery` lines the `func` lines, and the `join` lines the `subquery` lines; the `untyped` lines, between them, are checked against the JIT control's. On a non-zero exit, the job's error names what each exit code means (1 boot, 2 write, 3 read, 6 a
create was not refused with an `InvalidValueError`, 7 update, 8 delete, 9 `bulk_insert`, 10 a comparison
filter, 11 an `order_by`, 12 a `bulk_insert` row not refused with an `InvalidValueError`, or a row written, 13 one of the other lookups, 14 an expression comparison, 15
`bulk_update`, 16 `update_or_create`, 17 an untyped read, 18 `get_or_create`, 19 a function read, 20 a subquery read, 21 a join, CTE or window read, 22 a cascading delete, 24 a user transaction, 25 `close_all!`, 124 timed out). The written row is raceid 3: `prep.jl` seeds the Monaco race (1) and the
Brazilian one (2) first. The rows are reported as in the read-only job, in the
job summary and the `trim-full` artifact, never checked. It is a job of its own so the two SQLite
builds run side by side. Its triggers are the workflow's, which include `ext/PormGSQLiteExt.jl`, the
extension both SQLite jobs build. A change under `src/` that could break the trimmed write is checked
by running the workflow by hand on the branch, or by the next nightly run.

## The MySQL variant

`mysql/` builds the same app with MySQL.jl in place of SQLite, to measure the MySQL extension
(`ext/PormGMySQLExt.jl`), which no SQLite build compiles. Its entry, `mysql/main.jl`, boots through
`register_connection("f1", "mysql://…"; adapter = "MySQL")` (#1769), so no YAML is read, and then
runs the typed read, the read steps of `tools/reads.jl`, then the single-row write of `tools/writes.jl` (#1614): Monaco's id by a typed
read, a create, the read back (2 rows), an update, a delete and a `bulk_insert` of two rows, each step the line the SQLite entry
prints. The server comes from environment variables (`tools/server.jl`), read at run time. With none of
them set it is `127.0.0.1:1`, where nothing listens, so no database is needed: under the JIT the read
raises `PoolConnectError`, and the binary stops there too.

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
| `PORMG_TRIM_TRUST_USER` | unset: the Postgres.jl variant's two connection shapes without a password are skipped (see that variant) |

The password is read from its variable only; the binary prints `host:port/database` and never the
user or the password. Give the fixture a database of its own (`pormg_trim`, say), never the
integration suite's F1 database: `mysql/prep.jl` empties the `circuit` and `race` tables before it
seeds them, and refuses a database whose name does not contain `trim`. The host goes into the URL as it
is, so an IPv6 address is not supported; use a name or an IPv4 address. With the variables exported, from
the repository root:

```
julia --project=test/trim/mysql test/trim/mysql/prep.jl  # PormG's DDL, two circuits, a Monaco and a Brazilian race
julia --project=test/trim/mysql test/trim/mysql/main.jl  # the JIT control: boot ok, the row, the write
build-mysql/main
```

Against a server the trimmed binary connects, binds the parameters, runs the statement and returns the
row its JIT control prints (#1599), then runs the write and `bulk_insert` (#1614):

```
step	main	entered
step	ext	true
step	server	127.0.0.1:3306/pormg_trim
step	boot	ok
step	query	1 rows
step	row	1 2008 Monaco Grand Prix 2008-05-25
step	compare	date__@gte 1 rows: Brazilian Grand Prix
step	compare	round__@lt 1 rows: Monaco Grand Prix
step	order	date: Monaco Grand Prix, Brazilian Grand Prix
step	order	-date: Brazilian Grand Prix, Monaco Grand Prix
step	lookup	round__@gt 1 rows: Brazilian Grand Prix
step	lookup	round__@lte 1 rows: Monaco Grand Prix
step	lookup	date__@range 1 rows: Monaco Grand Prix
step	lookup	round__@in 1 rows: Monaco Grand Prix
step	lookup	name__@in 1 rows: Brazilian Grand Prix
step	lookup	date__@isnull false 2 rows: Monaco Grand Prix, Brazilian Grand Prix
step	lookup	date__@isnull true 0 rows: none
step	lookup	name__@icontains 1 rows: Brazilian Grand Prix
step	lookup	name__@contains 1 rows: Monaco Grand Prix
step	expr	year__@gt F(round) + 2000 1 rows: Monaco Grand Prix
step	expr	F(round) + 1 == 19 1 rows: Brazilian Grand Prix
step	expr	Extract(date, month) == 11 1 rows: Brazilian Grand Prix
step	expr	date__@year 2 rows: Monaco Grand Prix, Brazilian Grand Prix
step	expr	round__@gte Case 1 rows: Monaco Grand Prix
step	expr	Case == 1 1 rows: Monaco Grand Prix
step	untyped	first Monaco Grand Prix round 6 date 2008-05-25
step	untyped	first types year::Int32, round::Int32, circuitid::Int64, token::String, name::String, created_at::ZonedDateTime, raceid::Int64, updated_on::Date, date::Date
step	untyped	list 2 rows: Monaco Grand Prix, Brazilian Grand Prix
step	untyped	values 1 rows: round::Int32, name::String; Monaco Grand Prix 6
step	func	Abs/Round 2 rows: Monaco Grand Prix 4 6, Brazilian Grand Prix 8 18
step	func	Abs == 4 1 rows: Monaco Grand Prix
step	func	Count/Sum 1 rows: 2008 2 24
step	func	Upper(Lower) 2 rows: MONACO GRAND PRIX, BRAZILIAN GRAND PRIX
step	func	Case then F 2 rows: Monaco Grand Prix 6, Brazilian Grand Prix 0
step	subquery	circuitid__@in query 1 rows: Monaco Grand Prix
step	subquery	Exists OuterRef 1 rows: Brazilian Grand Prix
step	subquery	Subquery OuterRef column 2 rows: Monaco Grand Prix at Circuit de Monaco, Brazilian Grand Prix at Autódromo José Carlos Pace
step	subquery	circuitid == Subquery 1 rows: Brazilian Grand Prix
step	subquery	round == Subquery OuterRef 2 rows: Monaco Grand Prix, Brazilian Grand Prix
step	join	order_by path 2 rows: Brazilian Grand Prix at Autódromo José Carlos Pace, Monaco Grand Prix at Circuit de Monaco
step	join	order_by -alias 2 rows: Monaco Grand Prix at Circuit de Monaco, Brazilian Grand Prix at Autódromo José Carlos Pace
step	join	CTE column 2 rows: Monaco Grand Prix 1, Brazilian Grand Prix 1
step	join	CTE filter 1 rows: Brazilian Grand Prix 1
step	join	RowNumber partition 2 rows: Monaco Grand Prix 1, Brazilian Grand Prix 2
step	join	Rank order 2 rows: Brazilian Grand Prix 1, Monaco Grand Prix 2
step	cte	Subquery 2 rows: Monaco Grand Prix 2008, Brazilian Grand Prix 2008
step	cte	Exists 2 rows: Monaco Grand Prix false, Brazilian Grand Prix true
step	cte	RowNumber 2 rows: Monaco Grand Prix 1, Brazilian Grand Prix 2
step	cte	Case 2 rows: Monaco Grand Prix 0, Brazilian Grand Prix 1
step	cte	Cast 2 rows: Monaco Grand Prix 6, Brazilian Grand Prix 18
step	cte	F arithmetic 2 rows: Monaco Grand Prix 7, Brazilian Grand Prix 19
step	cte	Case over a list 2 rows: Monaco Grand Prix 0, Brazilian Grand Prix 1
step	write	ok
step	query	2 rows
step	row	1 2008 Monaco Grand Prix 2008-05-25
step	row	3 2009 Monaco Grand Prix 2009-05-24
step	update	1 rows; round 7
step	delete	1 rows; 1 left
step	bulk	2 rows; 2 read back
step	bulk_update	2 rows; rounds 7, 8
step	update_or_create	first created true; second created false; round 7
step	get_or_create	first created true; second created false; round 6; year::Int32, round::Int32, circuitid::Int64, token::String, name::String, created_at::ZonedDateTime, raceid::Int64, updated_on::Date, date::Date
step	cascade	3 rows; pitstop 2, race 1
step	cascade	0 pit stops left; 1 driver, debut none
step	cascade	seeded 1 pit stop, 1 driver; kept
step	transaction	committed 1 seen inside, 1 after; rolled back on TrimRollback, 0 left; removed 1
step	fail	threw StatementError                  (the refused statement, `tools/failing.jl`)
step	close_all	1 open before, 0 after; the handle closed
```

The Postgres.jl variant prints its `shape` lines (`password, sslmode: 1 rows`, `no password: 1 rows`,
`no password, sslmode: 1 rows`) after `transaction`.

The untyped lines name each cell's type, which is the engine's own: MySQL and PostgreSQL read `year` and
`round` as `Int32` where SQLite reads `Int64`. The ids are a fresh database's with the binary run straight after `prep.jl`. `prep.jl` empties the tables
without resetting the server's sequence, and the JIT control's own write uses an id, so a binary run after the
JIT control (as the CI jobs run it) or a later run prints higher ones; the write reads Monaco's id first for the
same reason.

The pool hands the result to the typed read at the type the extension registers
(`backend_result_type`), and the read decodes it cell by cell over the cell types MySQL.jl delivers. With
no variables set it stops at the connect, as the JIT does.

## The Postgres.jl variant

`postgres/` is the MySQL variant's app on PostgreSQL through Postgres.jl, to measure the Postgres.jl
extension (`ext/PormGPostgresExt.jl`). Its entry, `postgres/main.jl`, boots through
`register_connection("f1", "postgresql://…"; adapter = "PostgreSQL", postgres_driver = "Postgres")`
and runs the typed read and the same single-row write. It reads the same `PORMG_TRIM_*` variables as the MySQL variant (the
table above), with the same port-1 default, where the read raises `PoolConnectError`. Its
`postgres/prep.jl` seeds the same way and refuses the same databases. From the repository root:

```
julia --project=test/trim/postgres -e 'using Pkg; Pkg.instantiate()'
julia --project=test/trim/postgres test/trim/postgres/main.jl  # the JIT control

mkdir -p build-postgres && cd build-postgres
JULIA_CPU_TARGET=native juliac --project ../test/trim/postgres --output-exe main \
  --trim=unsafe-warn --experimental ../test/trim/postgres/main.jl 2>&1 | tee build.log
./main
```

Against a server, with the variables exported, from the repository root:

```
julia --project=test/trim/postgres test/trim/postgres/prep.jl
julia --project=test/trim/postgres test/trim/postgres/main.jl  # boot ok, the row, the write
build-postgres/main
```

Against a server the trimmed binary connects, authenticates, registers its result types, binds the
parameters, runs the statement and returns the row its JIT control prints, as the MySQL variant does (with
`server	127.0.0.1:5432/pormg_trim`).

**Connection shapes (#1599 layer 2).** The fixture's own connection has a password and no `sslmode`. The
`shape` step (`postgres/main.jl`) opens the other three of `_dial`'s typed arms, each as a pool of its own
under its own key, reads the Monaco race through it (`db(key)`) and closes it: a password with
`sslmode=disable`, and no password with `sslmode=disable` or none. The two without a password log in as the
role `PORMG_TRIM_TRUST_USER` names, which the server must trust on the fixture's database and which needs
`SELECT` on its tables; the CI job creates `trim_trust`, adds its `trust` line to `pg_hba.conf` and grants it
after `prep.jl`. With the variable unset the step prints `no password: skipped` and the job fails on it, so a
skipped shape never reads as run. Locally, as the database's superuser:

```
CREATE ROLE trim_trust LOGIN;                                    -- once
GRANT SELECT ON ALL TABLES IN SCHEMA public TO trim_trust;       -- in pormg_trim, after prep.jl made them
-- pg_hba.conf, before the other host lines, then reload:
-- host  pormg_trim  trim_trust  127.0.0.1/32  trust
```

then pass `PORMG_TRIM_TRUST_USER=trim_trust` through the runner's environment. With `PGPASSWORD` or `PGSSLMODE`
exported (even empty), the `shape` step refuses to run and the binary exits 23: Postgres.jl would fill the
missing password or `sslmode` from it, and the shapes would not be the ones named. With no variables set it stops at the connect, as the JIT does. The trimmed connect covers a connection string with a host, port, user, database, a password or
none and an `sslmode` or none (PormG adds `options` itself). Any other connection parameter
(`connect_timeout`, `application_name`, `sslrootcert`, `sslcert`, `sslkey`, `statement_timeout`, …) takes
Postgres.jl's own connect, which a trimmed binary has no code for: it fails at the connect with
`PoolConnectError`, its cause a `MethodError`.

**Authentication roots.** SCRAM-SHA-256, PostgreSQL's default password authentication, runs in SASLAuth
through Base64's encode and decode pipes, which keep their stream in a field typed `IO`. A trimmed image
had no code for the `IOBuffer` methods those calls reach and failed with `MissingCodeError` while
authenticating. The Postgres.jl extension names them (`PormG.backend_trim_roots`), and
`PormG.trim_entrypoints(PostgresConnectionPool{:postgres})` at `postgres/main.jl`'s top level roots them
with `Base.Experimental.entrypoint`, which does nothing under the JIT (a `precompile` statement does not
keep code in a trimmed image). The cause is upstream: the roots stay until Base64's pipes are typed.

## The error path

A statement that fails on the server must reach the caller as its own error. In a trimmed image the error
path itself used to fail first: a cause walk's `hasproperty` or a lock check's `string` on an untyped
exception has no compiled code there, and the `MethodError` it raised replaced the server's error (#1599).
`tools/failing.jl` runs `SELECT raceid FROM pormg_trim_missing`, against a table no fixture creates, and
prints what the caller catches: the error's type, and for a `DatabaseError` its SQLSTATE, message and
cause type. The server variants run it after their read, their write and the timing, as the `fail` step (exit code 6
unless it raises the server's error: a `DatabaseError` whose cause is not a `MethodError`); on SQLite it is an entry of its own, `fail.jl`, so the read-only binary the workflow
checks is unchanged. Each binary prints what its JIT control prints:

```
step	fail	threw StatementError        # SQLite: build/fail <run dir>
  sqlstate: -
  message: no such table: pormg_trim_missing
  cause: SQLiteException
step	fail	threw StatementError        # MySQL 8.4
  sqlstate: 42S02
  message: Table 'pormg_trim.pormg_trim_missing' doesn't exist
  cause: StmtError
step	fail	threw StatementError        # PostgreSQL through Postgres.jl
  sqlstate: 42P01
  message: relation "pormg_trim_missing" does not exist
  cause: Error
```

Build `fail.jl` like `read.jl` (`--output-exe fail … ../test/trim/fail.jl`) and run it with a run directory;
it needs no seeding. The server variants print the step against a server; at the port-1 default they stop
at the read's connect first.

## The server variants' CI jobs

The `Trim (juliac)` workflow has two more jobs, one per server variant, each against a service container
it starts for the run (#1614):

- **`Trimmed read (MySQL 8.4)`** builds `mysql/main.jl` and runs it against `mysql:8.4`.
- **`Trimmed read (PostgreSQL 18, Postgres.jl)`** builds `postgres/main.jl` and runs it against
  `postgres:18`, whose default authentication over TCP is SCRAM-SHA-256: the job checks first that its
  own connection authenticated that way (`system_user`) and that the role's password is stored as a
  SCRAM verifier, so the Base64 roots `trim_entrypoints` adds for Postgres.jl are exercised.

Each job sets the `PORMG_TRIM_*` variables to its container, seeds `pormg_trim` with the variant's
`prep.jl`, runs the JIT control, builds the binary with the pinned Julia and JuliaC, and runs it under
`timeout -k 10 300`. Before the MySQL run the job flushes the server's privileges, which empties
`caching_sha2_password`'s cache: `prep.jl` and the JIT control logged in already, and without the flush the
binary would take the fast path and never run the full authentication a fresh server asks for. It fails unless the binary exits 0, prints the `row` line and the read-step lines, prints the write's
`write ok`, `query 2 rows`, `update 1 rows; round 7`, `delete 1 rows; 1 left` and `bulk 2 rows; 2 read back` lines (the written row's id is
not checked: the JIT control used one), and its `fail` step prints
`threw StatementError` with the server's own SQLSTATE (`42S02` on MySQL, `42P01` on PostgreSQL), the
server's message and a cause that is not a `MethodError`. The rows are reported as in the SQLite job, in
the job summary and the `trim-mysql` and `trim-postgres` artifacts, never checked. The passwords in the
workflow are throwaway values for those containers, which the run discards; they belong to no other server.

Besides the fixture and the workflow file, a pull request that changes `ext/PormGMySQLExt.jl`,
`ext/PormGPostgresExt.jl` or `ext/PormGSQLiteExt.jl` runs the workflow, since only its jobs compile
them in a trimmed build. A change under `src/` does
not, as for the SQLite job. Neither variant commits a `Manifest.toml`, so each run resolves the newest
MySQL.jl or Postgres.jl that PormG's `[compat]` admits: as for SQLite, a red nightly with no PormG change
may be a driver release, and the `Instantiate the fixture` step prints the versions.

## Running the server variants locally

`tools/runner.jl` runs a command with the `PORMG_TRIM_*` variables pointed at a local server, taking the
server's host, port, user and password from an integration configuration folder: `test/integration/db_my`
for MySQL, `test/integration/db_2` for PostgreSQL. It loads the folder in place with
`PormG.Configuration.load` (environment `dev`, as the integration suite does; `--env=` picks another), so
the folder's `connection.yml` is read by PormG and never copied, and it sets the variables in the child
process's environment only. The database is `pormg_trim` (`--database=` names another; it must contain
`trim`), which the integration account must be able to use: the fixture's database, never the suite's. It
prints `runner	<host>:<port>/<database>` and the child's exit code, never the user or the password, and
exits with the child's code. It runs in the integration environment, which carries both drivers:

```
julia --project=test/integration test/trim/tools/runner.jl db_my -- <command...>
```

`db_my` and `db_2` name this checkout's folders. The `connection.yml` files are gitignored, so in a git
worktree pass the main checkout's folder as a path instead
(`…/PormG.jl/test/integration/db_my`).

The folder must set `host:` (a name or an IPv4 address: the runner connects over TCP, as the fixture's URL
does) and `password:`, or the runner refuses it. It exits with the child's code, `128 + n` when signal `n`
killed the child, and 127 when the command could not be started.

The MySQL variant, from the repository root, after building `build-mysql/main` as above:

```
trim_my() { julia --project=test/integration test/trim/tools/runner.jl db_my -- "$@"; }
trim_my julia --project=test/trim/mysql test/trim/mysql/prep.jl   # PormG's DDL and the two races
trim_my julia --project=test/trim/mysql test/trim/mysql/main.jl   # the JIT control
trim_my julia --project=test/trim/mysql test/trim/mysql/prep.jl   # the two races again
sudo mysql -e "FLUSH PRIVILEGES"                                 # empty caching_sha2_password's cache, as CI does
trim_my build-mysql/main                                         # the trimmed binary
```

`prep.jl` and the JIT control log in, which fills `caching_sha2_password`'s cache, so without the flush the
binary takes the cached fast path and never runs the full authentication CI's job checks. The flush needs the
`RELOAD` privilege; an account without it still runs every step, on the fast path.

The PostgreSQL variant, after building `build-postgres/main`:

```
trim_pg() { julia --project=test/integration test/trim/tools/runner.jl db_2 -- "$@"; }
trim_pg julia --project=test/trim/postgres test/trim/postgres/prep.jl
trim_pg julia --project=test/trim/postgres test/trim/postgres/main.jl
trim_pg julia --project=test/trim/postgres test/trim/postgres/prep.jl
trim_pg build-postgres/main
```

Each binary run starts from `prep.jl`'s two races, as the JIT control does, so the binary prints the JIT
control's lines. Only the written rows' ids differ: `prep.jl` does not reset the server's sequences (see the
MySQL variant).

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
