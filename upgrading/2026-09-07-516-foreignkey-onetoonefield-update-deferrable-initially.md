## `ForeignKey` / `OneToOneField` — `on_update`, `deferrable` and `initially_deferred` are removed (#516)

- **Version**: 0.6.0
- **PormG ref**: #516 ; `src/models/fields.jl`, `src/migrations/introspection.jl`, `src/migrations/column_spec.jl`
- **Recorded**: 2026-09-07
- **Severity**: breaking

### What changed

The two relational constructors accepted three keyword arguments that **no renderer ever emitted**:

| kwarg | what the DDL actually said |
|---|---|
| `on_update` | nothing — no `ON UPDATE` clause is rendered on either backend |
| `deferrable` | PostgreSQL hardcodes `DEFERRABLE`; SQLite renders no deferrability clause |
| `initially_deferred` | PostgreSQL hardcodes `INITIALLY DEFERRED`; SQLite renders none |

The declared value and the emitted DDL were unrelated in *both* directions: writing `deferrable = true`
got you `DEFERRABLE` because it is hardcoded, not because you asked, and leaving the default got you
`DEFERRABLE` anyway. Neither schema reader read any of the three back. Passing one now throws
`FieldValidationError`, the way #408 retired `AutoField`.

**The emitted DDL is unchanged.** PostgreSQL still writes `DEFERRABLE INITIALLY DEFERRED` on every
foreign-key constraint and SQLite still writes no deferrability clause. Removing the keyword changes
no schema and forces no migration — `makemigrations` proposes nothing as a result of this upgrade.

### How to find the calls to migrate

```bash
grep -rnE '(on_update|deferrable|initially_deferred)[[:space:]]*=' --include='*.jl' .
```

**Check your generated model files first.** Until #516 the SQLite reader parsed `ON UPDATE` and
`DEFERRABLE INITIALLY` out of the stored DDL and threaded both into the reconstructed field, and
`Model_to_str` emits any non-default slot — so a database whose foreign keys carry either clause made
**PormG itself write these keywords into `automatic_models.jl`**. The likeliest hits are therefore in
files nobody typed by hand. Re-running `generate_models_from_db` regenerates them clean.

### Migrate your app

```julia
# ✗ before
race_id = Models.ForeignKey("Race", pk_field = "id", on_delete = "CASCADE",
                            on_update = "CASCADE", deferrable = true)

# ✓ after — delete the three keywords; the constraint PormG emits is byte-identical
race_id = Models.ForeignKey("Race", pk_field = "id", on_delete = "CASCADE")
```

If you genuinely need per-constraint `ON UPDATE` or deferrability control, say so on #516 — it was
removed because nothing implemented it, not because the semantics were rejected.
