## `managed` becomes a model-level option, so a field of that name needs `db_column` (#741)

- **Version**: 0.7.0
- **PormG ref**: #741; `src/constants.jl`, `src/Models.jl`, `src/Kernel.jl`, `src/migrations/planner.jl`,
  `src/migrations/importers.jl`, `docs/src/models.md`, `docs/src/import_django.md`
- **Recorded**: 2026-09-26
- **Severity**: **breaking (very narrow)** — exactly one case, and it fails loudly at model load.
  Everything else in #741 is additive: `managed = false` itself, the planner leaving an unmanaged
  model's table alone, and the Django importer carrying `Meta.managed = False`. Part of the `0.7.x`
  pre-publish wave.

`Model(...)` gained a fourth model-level option, `managed = false`, for a model PormG queries but
never migrates — a view, or a table another system owns (Django's `Meta.managed`). Model-level
options are peeled off **before** the `fields...` slurp, so — exactly as with `indexes` since #347 —
a **column literally named `managed`** can no longer be declared as a keyword argument. It must be
pinned with `db_column` instead.

`var"managed" = BooleanField()` does **not** help: it parses to the keyword name `:managed`, and the
peel keys on that name however it was spelled. A *table* named `managed` needs nothing special.

*How to find the calls to migrate:*

```bash
rg -n '\bmanaged\s*=\s*(Models\.)?(\w+Field|ForeignKey)\(' --glob '*.jl'
```

It matches the keyword on a line of its own and inside a one-line `Models.Model(…)`, qualified or not.
If it comes back empty, this entry does not apply to your app. None of the consuming apps measured for
#741 declares such a column.

*Before → after:*

```julia
# BEFORE — declares a column called `managed`
Contract = Models.Model("contract",
  id      = Models.IDField(),
  managed = Models.BooleanField(),
)

# AFTER — the column is unchanged in the database; only its Julia identity moves
Contract = Models.Model("contract",
  id         = Models.IDField(),
  is_managed = Models.BooleanField(db_column = "managed"),
)
```

The failure is a `ModelDefinitionError` naming the option and the fix, raised the first time the
models file loads — not a silent misread. Query paths that referenced the old field name
(`"managed"`, `values("managed")`) must move to the new one; the physical column, and therefore every
schema, is untouched, so no migration is generated.

*The Django importer, for the record.* `import_models_from_django` now carries `Meta.managed = False`
instead of dropping it, so re-importing such a project writes `managed = false` models, which
`makemigrations` no longer creates or alters — and a managed model's `ForeignKey` into one is written
with `db_constraint = false` and a `# PormG:` marker. Nothing to edit by hand, and the two Django
sources the consuming apps import set `Meta.managed` nowhere (measured for #741).
