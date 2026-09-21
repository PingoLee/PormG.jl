## Table columns are created in declaration order, not field-name hash order (#544)

- **Version**: 0.6.0
- **PormG ref**: #544 ; `src/Models.jl`, `src/migrations/planner.jl`, `src/migrations/introspection.jl`, `src/querybuilder/ctes.jl`
- **Recorded**: 2026-09-11
- **Severity**: behavior change

### What changed

`Model_Type.fields` was a plain `Dict{String, PormGField}`, so a model's field order was the order
Julia happened to hash the **field names** in. Six render sites read it directly — `create_table` and
the SQLite table rebuild's `CREATE TABLE …_new`, its FK clause and its `INSERT … SELECT` column
lists — which made that hash order the **physical column order of every table PormG creates**.

It is now declaration order:

```julia
Models.Model("child_t"; id = Models.IDField(),
                        note = Models.CharField(max_length = 40),
                        col  = Models.CharField(max_length = 80))
```

| | resulting column order |
|---|---|
| before, Julia 1.12.7 | `note, id, col` |
| before, Julia 1.13.0 | `col, note, id` |
| after, both | `id, note, col` |

Nothing about the models changed between those two rows — Julia 1.13 changed string hashing, so
identical code emitted different DDL on different Julia versions. Introspected models follow the
same rule from the other direction: both readers already fetch columns in physical order (the
PostgreSQL reader aggregates `ORDER BY a.attnum`, the SQLite one reads `PRAGMA table_info` in `cid`
order) and that order is now kept instead of discarded.

### Two consequences worth knowing

**Interactive `makemigrations` rename prompts are now deterministic.** The order fields were offered
in for rename-matching came from the same hashing, so the *same* schema change asked its questions in
a different order on a different Julia version. Answering positionally — a recorded answer file, a
script, anything not reading each prompt — therefore mapped columns differently per version, and the
data landed accordingly. A person reading each prompt was never at risk; an automated answer sequence
was.

**Nothing is proposed against an existing database.** Column position is not one of the facets the
schema diff compares (`type`, `nullable`, `primary_key`, `unique`, `default`, `reference`, `checks`,
`identity`), so an already-migrated database does **not** see a spurious rebuild. The new order
applies to tables created from here on.

### How to find the calls to migrate

Nothing to migrate. The only way to notice is a test that compares generated DDL **as a string**, or
a snapshot of `collect(keys(model.fields))`:

```bash
git grep -n "keys(.*\.fields)" -- '*.jl'
```

Such a golden needs re-recording **once**, after which it is stable across Julia versions instead of
tracking the hash of your field names. PormG's own corpus, `test/unit/test_plan_actions_golden.jl`,
was re-recorded in this change: 32 of its 76 entries moved, and the regenerated block is now
byte-identical when produced on 1.12.7 and on 1.13.0.

### Migrate your app

No source edit. If you pin generated DDL in your own tests, re-record it once:

```julia
# ✗ before — this string was the hash order of your field names, and differed per Julia version
# ✓ after  — it is the order your model declares its fields in
```
