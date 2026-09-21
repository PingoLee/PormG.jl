## An expression column DEFAULT no longer aborts introspection (#472)

- **Version**: 0.5.0
- **PormG ref**: #472, #292, #455; `src/migrations/introspection.jl`, `src/Models.jl`,
  `src/models/fields.jl`, `docs/src/schema_conventions.md`
- **Recorded**: 2026-09-02
- **Severity**: **behavior change on SQLite only**, and only for a schema that previously could not
  be read at all. Everything else here fixes something already broken. Part of the `0.5.x`
  pre-publish wave.

### What changed

An expression `DEFAULT` the field type cannot represent — `now()`, `CURRENT_DATE`,
`gen_random_uuid()` — used to abort the **entire** schema read, so `inspectdb` produced no models
for any table. Such a column is now imported without the default, and the warning names it.

**Superseded in part by #475 (above).** This entry also described a carve-out — a textual column
kept a non-quoted default as a literal string, on both engines — and gave a migration recipe for it.
That carve-out no longer exists: an expression default is dropped on every column type. If you are
upgrading past #475, follow **that** entry's recipe instead; the paragraphs that stood here
described behaviour that shipped in `0.5.0` only.
