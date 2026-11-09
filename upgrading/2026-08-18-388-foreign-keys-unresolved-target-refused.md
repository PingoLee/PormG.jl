## Foreign keys — an unresolved `to` target is refused, not lowercased into a table name (#388)

- **Version**: 0.5.0
- **PormG ref**: #388; `src/Models.jl` (`fk_target_table`), `src/querybuilder/build_joins.jl`,
  `docs/src/schema_conventions.md`
- **Recorded**: 2026-08-18
- **Severity**: **behavior change (narrow)** — a `ForeignKey`/`OneToOneField` whose `to` names a model
  that is **not in the models module** now raises instead of referencing/joining a fabricated table.
  Runtime, not load time: the models file still loads, and the failure happens when the key is
  rendered. A key whose target *does* resolve is unaffected. Part of the `0.5.x` wave.

### What changed

`to` holds the target's **Julia binding**, not its table name (#360/#386). Three call sites recovered
a table from an unresolved `to` by **lowercasing it** — which is only the correct inverse while the
binding happens to be `uppercasefirst(<table>)`. It silently produced a table that does not exist for
every other shape, and it ignored the target's `db_table` outright:

| live parent table | `to` | old render | now |
|---|---|---|---|
| `2fast` | `"Col_2fast"` | `REFERENCES "col_2fast"` | raises |
| `driver profile` | `"Driver_profile"` | `JOIN "driver_profile"` | raises |
| `driver` pinned to `db_table = "Legacy_Driver"` | `"Driver"` | `JOIN "driver"` | `JOIN "Legacy_Driver"` |

The rule now is:

> **A foreign key's target must be a model PormG can see. If it is, the table comes off that model
> (honoring `db_table`). If it is not, PormG raises rather than inventing a table name.**

The runtime path already worked this way — `set_models` raises `ModelDefinitionError` for an
unresolvable target. This closes the two paths that did not: the migration prelude (which resolves
best-effort and left a string behind) and the query builder's forward-FK join arms.

Third row of the table is a **fix**, not a break: a `db_table`-pinned parent reached through an
unresolved `to` used to join the wrong table.

### How to find the calls to migrate

Nothing to grep in *call* sites — the exposure is in **generated models files**. For each one, diff its
declared bindings against its foreign-key targets; a non-empty difference is a file that will now
raise:

```julia
txt   = read("db/automatic_models.jl", String)
binds = Set(m.captures[1] for m in eachmatch(r"^[ \t]*(\w+)[ \t]*=[ \t]*Models\.Model\("m, txt))
tgts  = Set(m.captures[2] for m in eachmatch(r"(ForeignKey|OneToOneField)\(\"([^\"]+)\"", txt))
setdiff(tgts, binds)      # empty == unaffected
```

The ordinary cause of a non-empty result is an `include_table` / `ignore_table` filter that left an FK
parent out of the import — not a typo.

### Before → after

```julia
# before — the parent was filtered out of the import, and the key still "worked" by coincidence
#          (lowercase("Race_status") happens to be the real table `race_status`)
PormG.Migrations.import_models_from_postgres("db_legacy",
  include_table = ["race_entry", "race_entry_config"])      # race_status omitted
# -> Race_entry = Models.Model("race_entry",
#      statusid = Models.ForeignKey("Race_status", pk_field="statusid"))
#    makemigrations emitted REFERENCES "race_status"

# after — add the parent's table to the filter so the key has a model to point at
PormG.Migrations.import_models_from_postgres("db_legacy",
  include_table = ["race_entry", "race_entry_config", "race_status"])
```

If the parent genuinely lives outside the file, declare a stub for it instead — with `db_table` when
its table name differs from the model name:

```julia
Race_status = Models.Model("race_status", statusid = Models.IDField())
```
