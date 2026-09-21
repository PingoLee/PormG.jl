## SQLite now enforces foreign keys (#276)

- **Version**: 0.4.0
- **PormG ref**: #276; `ext/PormGSQLiteExt.jl`, `src/ConnectionPool.jl`, `src/migrations/runner.jl`,
  `src/querybuilder/deletion.jl`, `docs/src/write/create.md`, `docs/src/write/delete.md`
- **Recorded**: 2026-08-02
- **Severity**: **breaking (runtime behavior, SQLite only)** — statements that silently succeeded now
  raise. Part of the `0.3.x` pre-publish wave.

### What changed

SQLite ships with `PRAGMA foreign_keys` **off** and PormG never turned it on, so the `REFERENCES`
clauses `makemigrations` emits were declared and never enforced. A dangling foreign key inserted
cleanly on SQLite and raised `IntegrityError` on PostgreSQL.

That is the wrong way round for a project that recommends SQLite for local/test and PostgreSQL for
production: **a referential-integrity bug passed a green SQLite suite and only surfaced in
production.** PormG now issues `PRAGMA foreign_keys = ON` on every SQLite connection, so both
backends enforce the same contract.

Two consequences for existing code:

- Inserting or updating a row whose foreign key has no parent now raises `IntegrityError` on SQLite,
  as it always has on PostgreSQL.
- Deleting a parent that still has children raises, unless the relation says otherwise
  (`on_delete = "CASCADE"`/`SET_NULL` behave as declared). Notably `DO_NOTHING` now defers to a
  database that actually checks.

**Enforcement is not retroactive.** Rows that are already dangling stay where they are; only new
statements are constrained. So an existing database does not start failing on read — it fails the
next time something writes a bad reference, which is the point.

Migrations are unaffected: the SQLite table-rebuild suspends enforcement for the duration of the
migration transaction (SQLite's own documented ALTER procedure), and the connection is renewed
afterwards so enforcement is never left off.

### How to find the calls to migrate

```bash
grep -rn "on_delete" --include=*.jl .
grep -rn "bulk_insert\|bulk_update" --include=*.jl .
```

Look for anything that writes related rows **children-first**, or that relied on SQLite tolerating a
reference to a row that does not exist — fixture loaders and data-repair scripts are the usual
places. A load whose order is genuinely parent-last needs the escape hatch below.

### Before → after

```julia
# before — succeeded on SQLite, raised on PostgreSQL
M.Race.objects.create("year" => 2025, "circuitid" => 999_999, …)

# after — raises IntegrityError on both. Either insert the parent first…
M.Circuit.objects.create("circuitid" => 999_999, …)
M.Race.objects.create("year" => 2025, "circuitid" => 999_999, …)
```

```julia
# …or, if the order genuinely cannot be parent-first, wrap it in a transaction. Checks are deferred
# to COMMIT on BOTH backends, so a transiently inconsistent block commits fine. Usually all you need.
atomic(pool) do
    bulk_insert(M.Result, results_df)   # children
    bulk_insert(M.Race,   races_df)     # parents
end
```

```julia
# Only when a transaction is not enough — a load too big to hold in one, a repair that must leave a
# violation standing — suspend enforcement outright. A PRAGMA foreign_key_check runs before COMMIT,
# so the result is still verified. Pass check_on_exit = false when the violation is deliberate, or
# when the database already contains orphans (the check is whole-database, not scoped to the block).
without_foreign_keys(pool) do
    …
end
```

### Two timing details worth knowing

**Inside a transaction, an FK error now surfaces at `COMMIT`, not at the statement.** PormG's
PostgreSQL foreign keys have always been `DEFERRABLE INITIALLY DEFERRED`, and SQLite now matches
(`PRAGMA defer_foreign_keys`). If you wrapped a single `create()` in its own `try`/`catch` expecting
the `IntegrityError` there, it will now arrive when the surrounding transaction commits. Outside a
transaction — an autocommit `create()` — nothing changes: the error still comes from the statement.

**`on_delete = "PROTECT"` (`ON DELETE RESTRICT`) differs slightly.** PostgreSQL never defers
`RESTRICT`, so it raises at the `DELETE`; SQLite defers it with everything else and raises at
`COMMIT`. The error type is the same (`IntegrityError`) and PormG's own collector raises
`ProtectedError` before any SQL in the usual path, so this only shows up if you reach the database
directly.
