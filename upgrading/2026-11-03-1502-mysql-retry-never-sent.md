## MySQL retries a statement that was never sent (error 2006); MySQL.jl 2.2 or newer is required (#1502)

- **Version**: Unreleased
- **PormG ref**: #1502 ; `ext/PormGMySQLExt.jl`, `Project.toml`
- **Recorded**: 2026-11-03
- **Severity**: behavior. On MySQL a statement that raised `OperationalError` with error 2006 now runs again on a renewed connection and returns. An environment that holds MySQL.jl below 2.2 (a `Pkg.pin`, or a `~2.1` / `=2.1.0` bound) no longer resolves with this PormG.

### What changed

When a pooled MySQL connection is lost, PormG renews it. Until now it never ran the failed statement
again, because MySQL.jl 2.0 and 2.1 raised the same error, 2006 "MySQL server has gone away", for a
command that never left and for one the server may have committed before its reply was lost.

MySQL.jl 2.2.0 separates the two (JuliaDatabases/MySQL.jl#248). **2006** now means the command was
never sent: its write failed, or the connection was already known dead. **2013** "Lost connection to
MySQL server during query" means it was written and may have run. PormG now runs a statement that
failed with 2006 once more, on a renewed connection, as it already does on PostgreSQL for a statement
the driver refused to send (#1042). A 2013 is still raised, never retried. No retry happens inside a
transaction or on a connection you pinned.

The `[compat]` bound for MySQL.jl rises from `"2"` to `"2.2"`, since below 2.2.0 a 2006 can be a
statement that ran. A caret bound in your own `Project.toml` (`MySQL = "2"`, `"2.1"`) already admits
2.2, so it needs no change; only something that holds MySQL.jl below 2.2 does.

| call | before | now |
|---|---|---|
| MySQL over TLS: a query on a pooled connection the server killed while it sat idle | `OperationalError` (2006), then the slot is renewed | the slot is renewed, and the query runs again and returns its rows |
| MySQL: an `INSERT` whose connection is killed while it runs | `OperationalError` (2013), not retried | unchanged |
| MySQL: a statement inside `atomic` / `run_in_transaction` when the connection is lost | `OperationalError` | unchanged: never retried |
| an environment that holds MySQL.jl at 2.0.x or 2.1.x (`Pkg.pin`, `MySQL = "~2.1"`, `"=2.1.0"`), plus this PormG | resolves | `Pkg` cannot resolve it |
| an environment with a caret bound, `MySQL = "2"` or `"2.1"`, plus this PormG | resolves | resolves, on MySQL.jl 2.2 or newer |

### Who this affects

- A MySQL application that catches `OperationalError` around a query to run it again after a lost
  connection: for a 2006 the query now succeeds the first time, so the catch is harmless.
- A MySQL application that counts statements or log lines: a retried statement logs the warning
  "Lost connection to database. Retrying the statement on a renewed or freshly acquired connection...".
- An environment that holds MySQL.jl at 2.0 or 2.1 with a pin, a tilde or an equality bound.

### How to find the calls to migrate

```bash
# a compat bound that may hold MySQL.jl below 2.2 (tilde, equality, inequality or a range); a caret
# bound such as "2" or "2.1" does not, and a list stops below 2.2 only if every arm does
grep -rnE '^MySQL *= *"' --include=Project.toml . | grep -E '[~=<]| - |,'
# the version the Manifest resolved, and whether it is pinned
grep -nA4 '^\[\[deps.MySQL\]\]' Manifest.toml
```

### Migrate your app

```julia
# ✗ before: MySQL.jl held below 2.2
#   Project.toml [compat]: MySQL = "~2.1"     (or a `Pkg.pin("MySQL")` at 2.1.x)
# ✓ after: a caret bound, then update
#   Project.toml [compat]: MySQL = "2.2"
using Pkg
Pkg.free("MySQL")      # only after a Pkg.pin("MySQL")
Pkg.update("MySQL")

# Nothing to change in code. A retry loop around a read keeps working; for a 2006 it no longer runs.
rows = M.Result.objects.filter("driverid__surname" => "Senna").values("points").list()
```
