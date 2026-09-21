## `indexes` becomes a model-level option, so a field of that name needs `db_column` (#347)

- **Version**: 0.5.0
- **PormG ref**: #347; `src/constants.jl`, `src/Models.jl`, `src/migrations/planner.jl`,
  `src/migrations/introspection.jl`, `src/migrations/importers.jl`, `docs/src/models.md`,
  `docs/src/import_django.md`
- **Recorded**: 2026-08-14
- **Severity**: **breaking (very narrow)** — exactly one case, and it fails loudly at model load.
  Everything else in #347 is additive: the new `Models.Index` type, the `indexes =` keyword, the
  composite-index introspection on both backends, and the Django `Meta.indexes` /
  `Meta.index_together` import. Part of the pre-publish wave.

`Model(...)` gained a third model-level option, `indexes =`, for multi-column non-unique indexes
(Django's `Meta.indexes`). Model-level options are peeled off **before** the `fields...` slurp, so —
exactly as with `constraints` and `db_table` since #19 and #59 — a **column literally named
`indexes`** can no longer be declared as a keyword argument. It must be pinned with `db_column`
instead.

`var"indexes" = CharField()` does **not** help: it parses to the keyword name `:indexes`, and the
peel keys on that name however it was spelled. A *table* named `indexes` needs nothing special.

*How to find the calls to migrate:*

```bash
rg -n '^\s*indexes\s*=\s*Models\.' --glob '*.jl'
```

If that comes back empty, this entry does not apply to your app.

*Before → after:*

```julia
# BEFORE — declares a column called `indexes`
Report = Models.Model("report",
  id      = Models.IDField(),
  indexes = Models.CharField(max_length = 40),
)

# AFTER — the column is unchanged in the database; only its Julia identity moves
Report = Models.Model("report",
  id         = Models.IDField(),
  index_spec = Models.CharField(max_length = 40, db_column = "indexes"),
)
```

The failure is a `ModelDefinitionError` naming the option and the fix, raised the first time the
models file loads — not a silent misread. Query paths that referenced the old field name
(`"indexes"`, `"indexes__@gt"`, `values("indexes")`) must move to the new one; the physical column,
and therefore every schema, is untouched, so no migration is generated.
