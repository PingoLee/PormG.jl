## A Ctrl+C during a MySQL statement now raises and kills the statement; MySQL.jl 2.2.2 or newer is required (#1520, #1648)

- **Version**: 0.10.0
- **PormG ref**: #1520, #1648 ; `Project.toml`, `docs/src/mysql.md`
- **Recorded**: 2026-11-05
- **Severity**: behavior change. On MySQL, a `Ctrl+C` during a query used to be lost; the query ran to its end and returned its rows. It now raises, and the statement is stopped on the server. An environment that holds MySQL.jl at 2.2.0 or 2.2.1 no longer resolves with this PormG.

### What changed

PormG has always sent `KILL QUERY` for a MySQL statement whose await an interrupt cut short. A real
`Ctrl+C` never got that far. Julia throws a SIGINT into the task that last parked on its main
thread. Below 2.2.2, that was usually MySQL.jl's background reaper task, which caught the interrupt
around its timer and dropped it. The query ran to its end, returned normally, and nothing was sent
to the server.

MySQL.jl 2.2.2 (JuliaDatabases/MySQL.jl#255) lets the interrupt leave the reaper and runs the reaper
on the default threadpool. With an interactive thread, the interrupt now reaches the awaiting query.
Checked on MySQL 8.4 under `-t 2,1`: the query raised about 1.3 s after `Ctrl+C`, the statement left
the server at once, and the next query ran (4 of 4 rounds). The interrupt arrives the way it does on
PostgreSQL and SQLite: a `StatementError` whose `cause` is the `InterruptException`. The same applies
inside `migrate()` and `ensure_table!` on MySQL (#1642), which send `KILL QUERY` before they record
the failure.

The `[compat]` bound for MySQL.jl rises from `"2.2"` to `"2.2.2"`.

Two cases stay as they were, and neither PormG nor MySQL.jl can change them:

- With no interactive thread (`julia -t 1`, `-t N,0`), the first `Ctrl+C` can still end a background
  task instead of reaching the query.
- On macOS, about 1 in 3 interrupts is dropped inside Julia's runtime.

Plain `julia`, `-t N`, `-t N,1` and `-t auto` all have an interactive thread.

| call | before | now |
|---|---|---|
| MySQL: `Ctrl+C` in the REPL (or a script with `Base.exit_on_sigint(false)`) during `M.Result.objects.filter(…).list()`, Julia started with an interactive thread | lost: the query runs to its end and returns its rows | raises `StatementError` (cause `InterruptException`); `KILL QUERY` stops the statement; the next query runs |
| MySQL: the same under `julia -t 1` | lost | usually still lost (first `Ctrl+C`) |
| MySQL: `Ctrl+C` during `migrate()` or `ensure_table!` | lost: the DDL runs to its end and `migrate` records `applied` | raises; the DDL is killed; `migrate` records `failed`, `ensure_table!` drops the table it had begun |
| an environment that holds MySQL.jl at 2.2.0 or 2.2.1 (`Pkg.pin`, `"~2.2.1"`, `"=2.2.0"`), plus this PormG | resolves | `Pkg` cannot resolve it |
| an environment with a caret bound, `MySQL = "2"` or `"2.2"`, plus this PormG | resolves | resolves, on MySQL.jl 2.2.2 or newer |

### Who this affects

- Anyone who runs MySQL queries interactively (the REPL, a notebook, a script with
  `Base.exit_on_sigint(false)`) and presses `Ctrl+C`: the query now stops instead of finishing.
- Code that catches the interrupt around a query (`catch e` with `e.cause isa InterruptException`).
  On MySQL that branch never ran before; now it does, as on the other engines.
- An environment that holds MySQL.jl below 2.2.2 with a pin, a tilde or an equality bound.

### How to find the calls to migrate

```bash
# a compat bound that may hold MySQL.jl below 2.2.2 (tilde, equality, inequality or a range)
grep -rnE '^MySQL *= *"' --include=Project.toml . | grep -E '[~=<]| - |,'
# the version the Manifest resolved, and whether it is pinned
grep -nA4 '^\[\[deps.MySQL\]\]' Manifest.toml
# code that handles an interrupt around a query
grep -rnE 'InterruptException' --include='*.jl' .
```

### Migrate your app

```julia
# ✗ before: MySQL.jl held below 2.2.2
#   Project.toml [compat]: MySQL = "~2.2.1"     (or a `Pkg.pin("MySQL")` at 2.2.0 / 2.2.1)
# ✓ after: a caret bound, then update
#   Project.toml [compat]: MySQL = "2.2"
using Pkg
Pkg.free("MySQL")      # only after a Pkg.pin("MySQL")
Pkg.update("MySQL")

# Nothing to change in code. A Ctrl+C during this query now stops it on the server:
rows = M.Result.objects.filter("driverid__surname" => "Senna").values("points").list()
# Start Julia with an interactive thread (plain `julia`, `-t N`, `-t N,1` or `-t auto`), not `-t 1`.
```
