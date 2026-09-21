## Schema introspection reads two column shapes differently — spaced identifiers, and multi-column foreign keys (#414, #415)

- **Version**: 0.5.0
- **PormG ref**: #414, #415; `src/migrations/introspection.jl`, `docs/src/schema_conventions.md`
- **Recorded**: 2026-08-26
- **Severity**: **behavior change (narrow — only apps whose live schema has one of these two shapes)**.
  Nothing changes for a schema without a spaced identifier or a composite foreign key. Where one
  exists there are **two** ways it reaches you, and the second needs no action on your part to fire:
  a **regenerated** model file names different fields than before, **and** `makemigrations` — which
  runs introspection on every invocation — can now start proposing a change on every run against a
  model file you have not touched. Part of the `0.5.x` pre-publish wave.

### What changed

Both are corrections to what PormG **reads back** from a live database. Neither changes anything you
declare, and neither alters your schema.

**1. A column name containing a space is no longer torn in half (#414).** The PostgreSQL reader split
its `columns` aggregate on the space between the name and the type, so an identifier that *contained*
a space was destroyed before anything else saw it. A column named `driver ref` came back as the
phantom `"driver` — leading quote and all — and `Parent Id` came back as `"Parent`, typed
`TextField`, **with its foreign key dropped**, because the FK lookup keyed on the real name and no
longer matched. `makemigrations` then proposed adding the phantom and dropping the real column on
every run, forever. SQLite was never affected, so one schema introspected correctly on one engine and
corruptly on the other.

**2. A multi-column foreign key is now skipped rather than guessed at (#415).** PormG has no
composite-`ForeignKey` field type. PostgreSQL used to derive the referenced column from the parent's
*primary key index* instead of the constraint's own `confkey`, binding a composite FK to an arbitrary
column; SQLite split it into one independent single-column relation per member. Both now import the
member columns as **ordinary fields with no relation** and leave the constraint alone in the
database — the same reject-rather-than-reinterpret rule that keeps a non-default index out of an
imported model. Re-emitting either previous reading produced a *different* schema than the live one.

Two more single-column cases now read **correctly** where they used to read wrong — but "correct"
is still a *change*, so your declared model is the stale side and both need action, in the opposite
direction from change 2:

- **An FK referencing a non-primary-key `UNIQUE` column** (`REFERENCES driver_registry(licence_no)`)
  now reports that column. The old importer wrote its wrong answer explicitly into your model file —
  `Model_to_str` emits `pk_field=` on every introspected FK — so a model still declaring
  `pk_field="id"` disagrees with a live read of `licence_no`, and the planner proposes `:pk_field` on
  every run. Update the declaration to the column the constraint really names.
- **An FK whose parent table has no primary key at all** was previously *invisible* to PostgreSQL
  introspection (the referenced column only needs a `UNIQUE` constraint, but the old query reached it
  through the parent's primary-key index with an inner join). Your model therefore has a plain column
  where the live read now reports a relation. Declare the `ForeignKey`.

### How to find the calls to migrate

**Do not assume you are safe because you have not re-run the importer.** `makemigrations` calls the
same introspection (`convert_schema_to_models`, `src/migrations/planner.jl`), so change 2 can bite a
model file you never regenerate: if your model still declares `ForeignKey` on a composite-FK member
column, the live read now says "plain integer", the declared side still says "relation",
`describes_same_column` refuses to equate them, and the planner proposes a change **on every
`makemigrations`** — on SQLite, a full table rebuild each time.

```bash
# 1. Which of the FOUR shapes does your schema actually have? (PostgreSQL)
#    a. multi-column foreign keys — change 2
psql -c "SELECT conrelid::regclass, conname FROM pg_constraint
         WHERE contype = 'f' AND array_length(conkey, 1) > 1;"
#    b. identifiers containing a space — change 1
psql -c "SELECT table_name, column_name FROM information_schema.columns
         WHERE column_name LIKE '% %';"
#    c. foreign keys NOT pointing at the parent's primary key
psql -c "SELECT c.conrelid::regclass, c.conname FROM pg_constraint c
         JOIN pg_index i ON i.indrelid = c.confrelid AND i.indisprimary
         WHERE c.contype = 'f' AND c.confkey::int[] <> i.indkey::int[];"
#    d. foreign keys into a parent with no primary key at all
psql -c "SELECT c.conrelid::regclass, c.conname FROM pg_constraint c
         WHERE c.contype = 'f' AND NOT EXISTS (
           SELECT 1 FROM pg_index i WHERE i.indrelid = c.confrelid AND i.indisprimary);"

# 2. For anything those returned, grep your models for the affected columns.
grep -n "ForeignKey" <your db_def_folder>/*.jl

# 3. Then run makemigrations and read the plan BEFORE applying it. A proposal against a table you
#    did not change is this entry — and step 3 catches all four shapes even if you skipped step 1.
```

### Migrate your app

```julia
# ── change 2: a composite-FK member column must stop declaring a relation ──
# ✗ before — ONE constraint, `FOREIGN KEY (raceid, driverid) REFERENCES result(raceid, driverid)`,
#   imported as two single-column relations. Note both name the SAME parent: a composite FK has one
#   referenced table, so this is the shape to look for. Two relations pointing at DIFFERENT parents
#   are two ordinary foreign keys, which this change does not touch — do not delete those.
#   (The `pk_field` values below are what the old SQLite reader wrote. The old PostgreSQL reader
#   named the parent's primary-key column on both members instead; either way, both lines go.)
Lap_time = Models.Model("lap_time",
  raceid   = Models.ForeignKey("result", pk_field="raceid"),
  driverid = Models.ForeignKey("result", pk_field="driverid"),
)

# ✓ after — plain columns; the constraint stays in the database, PormG just stops modelling it.
#   REGENERATE if you can: hand-declaring means matching the column exactly, and two attributes
#   drift if you get them wrong. Type — introspection maps `bigint` to BigIntegerField and `integer`
#   to IntegerField (src/constants.jl), so IntegerField() over a BIGINT column drifts on `:type`
#   forever. And nullability — `:null` has no exemption in `_NON_SCHEMA_FIELD_ATTRS`, so a bare
#   field declared over a NULLable column drifts on `:null` the same way.
Lap_time = Models.Model("lap_time",
  raceid   = Models.BigIntegerField(),
  driverid = Models.BigIntegerField(),
)

# ── change 1: a spaced column's regenerated FIELD NAME is sanitized, and gains a db_column ──
# ✗ before — the phantom name, truncated at the space
M.Driver.objects.filter("driver" => "senna")

# ✓ after — `Model_to_str` emits `driver_ref = CharField(db_column="driver ref", …)`,
#           so the field is `driver_ref` and the physical column keeps its space
M.Driver.objects.filter("driver_ref" => "senna")
```
