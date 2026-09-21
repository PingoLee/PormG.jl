## Contradictory `on_delete` declarations now raise, and the `SET` sentinel is gone (#287)

- **Version**: 0.4.0
- **PormG ref**: #287; `src/constants.jl`, `src/Kernel.jl`, `src/Models.jl`, `src/QueryBuilder.jl`,
  `src/models/fields.jl`, `src/querybuilder/deletion.jl`
- **Recorded**: 2026-08-01
- **Severity**: **breaking (raises where it previously warned or silently continued)** — narrow: it
  affects only models whose `on_delete` declaration was already self-contradictory or used the
  unimplemented `SET`. Part of the `0.3.x` pre-publish wave.

### What changed

Three `on_delete` states that used to be accepted, and then misbehaved later, are now rejected at the
earliest point they can be detected.

**1. `SET` is removed.** It was exported and accepted but no branch of the deletion collector
implemented it, and the DDL renderer emitted the syntactically invalid `ON DELETE SET`. It could not
be implemented coherently: Django's `SET(value)` carries a value or callable, and PormG's `on_delete`
is a bare sentinel with nowhere to put one.

Removing it also removes the `contains(on_delete, "SET")` fallback that produced it, which had been
swallowing near-miss typos — `"SET-NULL"`, `"SETNULL"` and Django's `models.SET(fn)` all became `SET`
silently. Those now raise `FieldValidationError` at field construction, with `models.SET(...)` getting
a message that names it specifically.

**2. `SET_NULL` on a `null=false` field** and **3. `SET_DEFAULT` with no `default`** now raise
`ModelDefinitionError` from `set_models` at registration. Both checks already existed there as
`@error` logs: they printed the problem and let the model through, so the contradiction resurfaced
later as a database constraint violation, or — for `SET_DEFAULT` — as a silent `UPDATE … SET col =
NULL`, i.e. `SET_DEFAULT` quietly behaving as `SET_NULL`. The deletion collector keeps its own copy of
both guards for models that never pass through `set_models`.

The throw is only reachable from `set_models`, and the migration planner deliberately does not call it
(`src/migrations/planner.jl` loads models into a throwaway module), so `makemigrations` / `migrate` are
unaffected.

**Generated model files are affected, though.** Django's `on_delete=models.SET_DEFAULT, default=None`
on a nullable FK used to import verbatim as `SET_DEFAULT` with no default — a shape that now fails at
registration, so the generated file would not load and regenerating produced the identical broken file.
The importer translates it to `SET_NULL` (which is what Django's combination denotes) and warns.

Importing from a **database** needed a hand edit for a while: the introspector rendered
`on_delete=SET_DEFAULT` without carrying the column default through, so the generated module failed
to register and regenerating reproduced the same broken file. #292 fixed that — introspection now
carries the default (and, on PostgreSQL, the referential action it never used to query), so no hand
edit is required.

### How to find the calls to migrate

```bash
# 1. the removed sentinel, and any string that used to fall through to it.
# Over-matches slightly: it also lists the still-valid "SET NULL" / "SET DEFAULT" spellings, so
# read the hits rather than assuming every one needs an edit.
rg -n 'on_delete\s*=\s*("?SET"?[,)\s]|"[^"]*SET\()' --glob '!*.md'

# 2. SET_NULL fields that are not nullable
rg -n -U 'ForeignKey\([^)]*SET_NULL[^)]*null\s*=\s*false' --glob '*.jl'

# 3. SET_DEFAULT fields — check each one actually declares a default=
rg -n 'on_delete\s*=\s*"?SET_DEFAULT' --glob '*.jl'
```

### Before → after

```julia
# before — all three were accepted and then misbehaved later
parent = Models.ForeignKey(Team,   pk_field = "id",       on_delete = "SET",         null = true)
driver = Models.ForeignKey(Driver, pk_field = "driverid", on_delete = "SET_NULL",    null = false)
status = Models.ForeignKey(Status, pk_field = "statusid", on_delete = "SET_DEFAULT", null = true)

# after — SET has no replacement, so pick the action you actually meant;
#         SET_NULL needs a nullable column; SET_DEFAULT needs something to set
parent = Models.ForeignKey(Team,   pk_field = "id",       on_delete = "SET_NULL",    null = true)
driver = Models.ForeignKey(Driver, pk_field = "driverid", on_delete = "SET_NULL",    null = true)
status = Models.ForeignKey(Status, pk_field = "statusid", on_delete = "SET_DEFAULT", null = true, default = 1)
```

If a model trips check 2 or 3 at `set_models`, the message names the model and field.
