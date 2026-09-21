## Row-level writes no longer auto-resync PostgreSQL sequences (#358)

- **Version**: 0.5.0
- **PormG ref**: #358; `src/querybuilder/execution.jl`, `src/querybuilder/execution_bulk.jl`,
  `src/QueryBuilder.jl`, `src/PormG.jl`, `docs/src/schema_conventions.md`, `docs/src/postgres.md`
- **Recorded**: 2026-08-13
- **Severity**: **breaking (behavioral, PostgreSQL-only)** — an app relying on `create`/
  `update_or_create`/`get_or_create` to auto-repair a drifted sequence after an explicit-primary-key
  write silently loses that protection. **No database migration.** Part of the `0.5.x` pre-publish
  wave.

### What changed

`create`/`insert`, `update_or_create`, and `get_or_create` no longer resynchronize the PostgreSQL
sequence after a write that supplies an explicit primary key. Automatic resync now runs only where
drift is actually produced in bulk — `bulk_insert` (including its own duplicate-key self-heal) and
`bulk_copy` — matching every comparable ORM checked when this was decided (Django, Rails, SQLAlchemy,
Ecto, Prisma: none resyncs on a row-level write; Django's `sqlsequencereset`/Rails'
`reset_pk_sequence!` are the closest precedent, both explicit operations, never automatic).

A new `resync_sequences(model)` / `resync_sequences(models)` closes the gap this leaves: there was
previously no way to repair a sequence without an accompanying insert — after a `pg_restore`, a
manual `COPY`, or any load that happened outside PormG entirely, or simply after a row-level write
that needs one. See [Sequence synchronisation](https://pingolee.github.io/PormG.jl/dev/schema_conventions/#Sequence-synchronisation)
in the docs.

### How to find the calls to migrate

A row-level write supplying its own primary key used to auto-resync; it no longer does. The primary
key field is not necessarily named `*id` — `db_column`/natural-key models can call it anything — so
this matches any row-level write with an explicit first argument, not just an `id`-suffixed one:

```bash
rg -n --pcre2 '\.(create|get_or_create|update_or_create)\(\s*"[a-zA-Z_]+"\s*=>' -g '*.jl'
```

This over-matches on purpose — it also flags a `create()` whose first explicit argument is not the
primary key — because a silent miss on a differently-named pk field is worse than a few hits you
discard by hand. For each hit, check two things: (1) is the argument actually the model's primary
key, and (2) does a **later** write to the same table rely on an auto-generated key not colliding
with the explicit one just inserted. Only when both hold does it need a `resync_sequences()` call.
`bulk_insert`/`bulk_copy` call sites are unaffected; skip them.

### Before → after

```julia
# before — a later auto-pk create() was protected automatically
M.Driver.objects.create("driverid" => 999, "forename" => "Max")
# ...
next = M.Driver.objects.create("forename" => "Auto")   # never collided

# after — call resync_sequences() yourself after the explicit-pk row-level write
M.Driver.objects.create("driverid" => 999, "forename" => "Max")
resync_sequences(M.Driver)
next = M.Driver.objects.create("forename" => "Auto")   # protected again
```

A data migration that creates many rows with explicit ids pays this **once**, after the batch —
not per row, which is the whole point of moving the repair off the write path.
