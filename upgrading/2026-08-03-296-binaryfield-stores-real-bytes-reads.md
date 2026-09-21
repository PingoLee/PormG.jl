## `BinaryField` stores real bytes — reads return `Vector{UInt8}`, not `String` (#296)

- **Version**: 0.4.0
- **PormG ref**: #296; `src/Kernel.jl`, `src/Models.jl`, `src/constants.jl`, `src/Dialect.jl`,
  `src/models/fields.jl`, `src/querybuilder/parameters.jl`, `src/querybuilder/sanitization.jl`,
  `src/migrations/introspection.jl`, `docs/src/fields.md`
- **Recorded**: 2026-08-03
- **Severity**: **breaking (runtime behavior + column type, both backends)** — narrow: it affects
  only apps that declare a `BinaryField`. Part of the `0.3.x` pre-publish wave.

### What changed

`BinaryField` never stored binary data. `_get_column_type` had no branch for it, so it fell through
to the `TEXT` fallthrough on **both** backends; `default=` raised for every non-`nothing` value; and
`max_length` was enforced as a *character* count on strings only, never reaching the schema. It now
renders `BYTEA` on PostgreSQL and `BLOB` on SQLite.

Three consequences for an app:

1. **Reads return `Vector{UInt8}`.** A column that handed back a `String` now hands back bytes, so
   any `occursin` / `parse` / string concatenation on that value stops compiling or silently changes
   meaning. This is the change most likely to need a source edit.
2. **Writes accept bytes or a `String`.** A `String` is stored as its UTF-8 code units, so existing
   write sites keep working unchanged. Anything else (an `Int`, a `Dict`) now raises
   `InvalidValueError` instead of being coerced.
3. **`default=` takes `Vector{UInt8}` only.** It used to raise for everything, so nothing that
   worked before breaks — but a `String` still raises, now with a message naming the two decodings.

Separately, and worth knowing even if you never touch the API: on PostgreSQL a binary value used to
be handed to LibPQ as a raw vector, which LibPQ renders as a PG *array literal* in text format.
`UInt8[0x00, 0xFF]` reached the server as the five characters `{0,255}` and `bytea` stored those
ASCII bytes. It raised no error. Any bytes written through the old path are already corrupt in the
database and cannot be recovered by this migration.

**The schema change needs review before you apply it.** This file is normally not about database
migrations, but this one is not mechanical. The next `makemigrations` proposes:

- PostgreSQL — `ALTER TABLE … ALTER COLUMN … TYPE bytea USING convert_to("col", 'UTF8')`
- SQLite — a table rebuild whose copy step is `CAST("col" AS BLOB)`

Both **reinterpret** the existing text as its UTF-8 bytes; neither decodes it. That is correct for a
column that held plain text, and wrong for one that held hex or Base64 — PormG cannot tell which.
If yours held an encoding, edit `pending_migrations.jl` to use `decode(col, 'hex')` /
`decode(col, 'base64')` before running `migrate()`. If the column was really text all along, the
honest fix is to retype the field as `TextField` and skip the conversion entirely.

### How to find the calls to migrate

```bash
# 1. Which models declare one at all — if this is empty, nothing below applies.
grep -rn "BinaryField" --include=*.jl .

# 2. Read sites for those columns: the value is now Vector{UInt8}, not String.
#    Substitute your own field names from step 1.
grep -rn "file_data\|encrypted_content" --include=*.jl .
```

### Before → after

```julia
# before — the column was TEXT, so reads came back as a String
row = M.Technical_document.objects.filter("id" => 1).values("file_data").list() |> first
occursin("PDF", row[:file_data])
write("out.pdf", row[:file_data])

# after — reads are raw bytes
row = M.Technical_document.objects.filter("id" => 1).values("file_data").list() |> first
occursin("PDF", String(copy(row[:file_data])))   # decode explicitly when you want text
write("out.pdf", row[:file_data])                # already the right type for binary I/O

# writes are unchanged for String values, and now also take bytes directly
M.Technical_document.objects.create("file_data" => "still works, stored as UTF-8 bytes")
M.Technical_document.objects.create("file_data" => read("aero.pdf"))
```
