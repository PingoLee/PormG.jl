## `status()` reports a failed live-table read as a drift signal (#1076)

- **Version**: Unreleased
- **PormG ref**: #1076 ; `src/migrations/runner.jl` (`status`)
- **Recorded**: 2026-10-12
- **Severity**: behavior. When `status()` cannot read the live table list, its `drift_signals` now hold a `Drift detection failed` entry, where they were empty.

### What changed

`status()` checks one thing against the live database: whether migrations are recorded over a
database with no user tables (a sign of an external drop). It reads the table list for that. When the
read failed, `status()` logged the error at `@debug` and returned no signal, so a database it could
not look at reported the same as a database with no drift.

A failed read of the table list still does not make `status()` throw. It is now a drift signal that
names the error type. The server's message is left out of it. (A failed read of the migration
history itself raises, as before.)

| call | before | after |
|---|---|---|
| `Migrations.status("db")` when the live-table read raises | `drift_signals` empty; the error logged at `@debug` | `drift_signals` holds `"Drift detection failed: could not read the live tables (<ErrorType>), so an external drop would not show here."` and `show` prints it with the other warnings |

A database whose table list reads normally gets no new signal.

### Who this affects

Code that reads `status(…).drift_signals` and treats a non-empty list as a problem, for example a
deploy or health-check script that fails on any signal. Such a script now also fails when `status()`
could not read the live tables, which is the point: before, that case passed as clean.

### How to find the calls to migrate

```bash
grep -rn 'drift_signals' --include=*.jl .
```

### Migrate your app

Nothing to change if a failed read should count as a problem. To tell it apart from the other
signals:

```julia
st = PormG.Migrations.status("db")
read_failed = any(s -> startswith(s, "Drift detection failed"), st.drift_signals)
```
