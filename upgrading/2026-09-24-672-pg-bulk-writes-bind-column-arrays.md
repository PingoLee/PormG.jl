## `bulk_insert` / `bulk_update` on PostgreSQL bind one typed array per column (#672)

- **Version**: Unreleased
- **Recorded**: 2026-09-24
- **PormG ref**: #672; `src/querybuilder/execution_bulk.jl` (`bulk_insert`, `_bulk_update`, `_pg_unnest_source!`, `_bulk_cell`, `_bulk_chunk_rows`)
- **Severity**: behavior change — on PostgreSQL, a `bulk_insert` into a column with no assignment cast from its field's type now fails, a `Vector` in a text-like bulk cell now raises, and tests pinning bulk `show_query` output need re-baselining

### What changed

On PostgreSQL, `bulk_insert` and `bulk_update` used to send each chunk as `VALUES ($1, $2), ($3, $4), …`: one **untyped** parameter per cell, which the server parsed straight into the target column. They now bind one **typed** array per column and expand it server-side:

```sql
INSERT INTO "status" ("statusid", "status") SELECT * FROM unnest($1::bigint[], $2::varchar[])
UPDATE "result" AS "Tb" SET "points" = source."points"
FROM unnest($1::float[], $2::bigint[]) AS source ("points","resultid") WHERE …
```

**Why:** the parameter count is now the column count, not rows × columns. That removes the 65,535-parameter cap on `chunk_size`, and the statement text is the same for every chunk. A 100,000-row `bulk_update` measured about 25% faster (numbers on #672). SQLite is unchanged.

Each array is cast to the column type its **field** renders, the same cast `bulk_update` already applied to every `source."col"` reference. What an app can observe:

1. **`bulk_insert` into a column that differs from its field can now fail.** It fails when PostgreSQL has no *assignment cast* from the field's type to the column's real type. The typical case is a column adopted from an existing database with a type PormG does not model: an enum, `inet`/`cidr`, `xml`, `tsvector`, an array, a range or a geometric type. The importer declares such a column as a `TextField`/`CharField`. The untyped `VALUES` parameter let PostgreSQL parse the text into that type; a `text[]` array cannot be assigned to it:

   ```
   column "compound" is of type tyre_compound but expression is of type text
   ```

   Differences that do have an assignment cast still work: `varchar` into `text`, `integer` into `bigint`, text into `citext`. `bulk_update` already failed on the failing columns. `create()`, `update()`, `get_or_create()`, `update_or_create()` and `bulk_copy()` still work.
2. **A legacy `json` column (not `jsonb`) under a `JSONField` is stored normalized.** The array is `jsonb[]`, so key order, whitespace and duplicate keys are normalized on the way in: `{"b":1, "a":2}` is stored as `{"a": 2, "b": 1}`. `bulk_update` already did this. `create()` stores the text as given.
3. **A `Vector` in a text-like cell (`CharField`, `TextField`, …) raises `InvalidValueError`**, naming the field, on both backends. It used to be stored on PostgreSQL as its array-literal text (`{"Senna","Prost"}`), and on SQLite it expanded into extra `?` placeholders. This does not touch `JSONField` values (a `Dict`, `Vector` or `NamedTuple` is serialized to one JSON string first) or `BinaryField` bytes. A `Tuple`, `Dict` or `NamedTuple` in a text cell already raised before this change.
4. **`show_query` output differs on PostgreSQL.** It shows the SQL above, and `:params` returns one vector per column after any filter values. `chunk_size` is used as given (a non-positive one keeps the old cap), so a wide table or a large `chunk_size` now runs as fewer statements.

Measured in the consuming apps on 2026-09-24:
- `bi_server_nitro` has 30 `bulk_insert(` and 24 `bulk_update(` call sites. `bi_server` and `biESUS` have none.
- `bi_server_nitro`'s golden SQL suite, `test/pormg_golden/sql/mutations.jl`, pins the old PostgreSQL SQL **and** parameter vectors for one `bulk_insert` and one `bulk_update`. Those two tests need re-baselining (see below). Its Model-direct-vs-`.objects` equality test keeps passing.
- Whether any `bulk_insert` target has a column that fails case 1 depends on the **database**, not the source. The query below answers it per database.

### How to find the calls to migrate

Cases 1 and 2 depend on the **database**, not on the call. List every column whose type is not one PormG fields render, which is a more reliable check than listing known-bad types:

```sql
SELECT table_name, column_name, data_type, udt_name
FROM information_schema.columns
WHERE table_schema = 'public'
  AND data_type NOT IN ('bigint', 'integer', 'smallint', 'double precision', 'real', 'numeric',
                        'boolean', 'character varying', 'character', 'text', 'date',
                        'timestamp with time zone', 'timestamp without time zone',
                        'time without time zone', 'interval', 'uuid', 'jsonb', 'bytea');
```

Then check whether any `bulk_insert(` call writes one of those tables:

```bash
grep -rn 'bulk_insert(' --include=*.jl .
```

Case 4 shows up in tests that pin bulk SQL or parameters:

```bash
grep -rn 'show_query' --include=*.jl . | grep -E 'bulk_(insert|update)'
```

At runtime, case 1 surfaces as the driver error above (`… is of type … but expression is of type text`), and case 3 as:

```
A bulk value for field `driver` is a Vector{String}: each cell must hold a single value, not a collection.
```

### Migrate your app

```julia
# Before: a legacy `stint.compound` enum column, imported as a TextField, bulk-inserted fine
bulk_insert(M.Stint.objects, stints_df)

# After: that raises on PostgreSQL. A plain insert can use COPY, which parses text into the
# column's real type:
bulk_copy(M.Stint.objects, stints_df)

# An insert that relied on on_conflict goes row by row through the upsert helpers, which bind
# each value untyped: get_or_create for DO NOTHING, update_or_create for DO UPDATE.
for row in eachrow(stints_df)
    M.Stint.objects.update_or_create("stintid" => row.stintid;
        defaults = ["driver" => row.driver, "compound" => row.compound])
end

# Or retype the column in the database to the type the field renders (`text`).
```

```julia
# Before: a legacy `json` column kept its exact text through bulk_insert
bulk_insert(M.Telemetry.objects, df)

# After: stored jsonb-normalized. If the exact text matters, write it with create();
# otherwise migrate the column to jsonb, which is what a JSONField declares.
```

```julia
# Before: a golden test pinned the per-cell shape of a PostgreSQL bulk_insert
@test norm(insp[:sql_text]) == norm(raw"""
  INSERT INTO "dash_tab_vig_hanseniase" ("ibge_id", "hash", …)
  VALUES ($1, $2, …), ($9, $10, …)""")
@test insp[:parameters] == Any[IBGE, "a", …, IBGE, "b", …]

# After: one typed array per column, in the INSERT's column order (bulk_update likewise:
# `FROM unnest($2::varchar[], …) AS source (…)`, no `source."col"::type` casts, and
# parameters = [filter values…, one vector per source column])
@test norm(insp[:sql_text]) == norm(raw"""
  INSERT INTO "dash_tab_vig_hanseniase" ("ibge_id", "hash", …)
  SELECT * FROM unnest($1::bigint[], $2::varchar[], …)""")
@test insp[:parameters] == Any[[IBGE, IBGE], ["a", "b"], …]
```

```julia
# Before: a Vector in a text column was stored as '{"Senna","Prost"}' on PostgreSQL
df = DataFrame(driver = [["Senna", "Prost"]])
bulk_insert(M.Pairing.objects, df)

# After: raises InvalidValueError. Store the text you meant explicitly:
df.driver = join.(df.driver, ", ")
bulk_insert(M.Pairing.objects, df)
```
