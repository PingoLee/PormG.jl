## A positional model name must be lowercase (#300)

- **Version**: 0.4.0
- **PormG ref**: #300; `src/Models.jl`, `docs/src/schema_conventions.md`, `docs/src/models.md`
- **Recorded**: 2026-08-04
- **Severity**: **breaking (definition time, SQLite-only apps in practice)** — a declaration that
  loaded now raises. Part of the `0.3.x` pre-publish wave.

### What changed

`Models.Model("Driver_Profile", …)` stored the name **verbatim**, and the two groups of consumers
disagreed about its case: `makemigrations` lowercased it into the DDL, while the query builder quoted
it as declared. So the model migrated a table named `driver_profile` and then addressed
`"Driver_Profile"` in every `SELECT`/`INSERT`/`UPDATE` — **one declaration, two tables**. The
generated `DELETE` contained both spellings at once.

On PostgreSQL a quoted identifier is case-sensitive, so every read and write failed with
`relation "Driver_Profile" does not exist` *after a migration that succeeded*. SQLite's identifiers
compare case-insensitively, so it masked the split completely: a green SQLite suite and a broken
PostgreSQL deployment — the same wrong-way-round shape as #276.

A positional name containing any uppercase character is now rejected at declaration:

```
ModelDefinitionError: The model name 'Driver_Profile' must be lowercase; PormG lowercases table
names when generating DDL but quotes them as declared in queries, so this model would migrate the
table 'driver_profile' and then query 'Driver_Profile'. Declare it as 'driver_profile'.
```

It rejects rather than silently lowercasing because folding the name would discard a stated intent
with no signal it happened. At the time there was also no way to *express* that intent; #59 has since
added model-level `db_table`, which is where it goes: `Model("driver_profile", db_table =
"Driver_Profile", …)`.

**Only the positional form is affected.** A name derived from the Julia binding
(`Race = Models.Model(…)`) was already lowercased when `set_models` filled it in, and is unchanged.
`inspectdb` introspection and the Django importer also still accept a mixed-case name — they read it
from a live database or a Python class, and `Model_to_str` lowercases it when writing the generated
model file, so `import` → `makemigrations` → reload keeps working.
grep -rnE '(^|[^A-Za-z_])Model\(\s*"[^"]*[A-Z]' --include=*.jl .
```

The leading `(^|[^A-Za-z_])` keeps `PormGModel(` and `convertSQLToModel(` out of the results. Any hit
is a model that was already broken on PostgreSQL and silently working on SQLite.

!!! warning "A clean result is not proof — this grep is line-based"
    It only matches when the name is on the **same line** as `Model(`. A declaration written across
    lines, which is house-normal, is missed entirely:

    ```julia
    Driver_Profile = Models.Model(
      "Driver_Profile",          # ← the grep above does not see this
      driverid = Models.IDField(),
    )
    ```

    Use the multi-line form to be sure. Ripgrep is the reliable option here; `grep -Pzo` is not, as
    many builds accept `-P` only in unibyte/UTF-8 locales:

    ```bash
    rg -nU --multiline-dotall -g '*.jl' '(^|[^A-Za-z_])Model\(\s*"[^"]*[A-Z]'
    ```

An app that follows the documented lowercase house style has nothing to find either way.

### Before → after

```julia
# before — loaded fine, migrated `driver_profile`, queried `"Driver_Profile"`
Driver_Profile = Models.Model("Driver_Profile",
  driverid = Models.IDField(),
  surname  = Models.CharField(),
)

# after — the positional name is lowercase; the Julia binding keeps its capitalization
Driver_Profile = Models.Model("driver_profile",
  driverid = Models.IDField(),
  surname  = Models.CharField(),
)
```

**If the physical table really is mixed-case**, there is no mapping for it yet — that is
[#59](https://github.com/PingoLee/PormG.jl/issues/59). On SQLite the rename above is a no-op because
identifiers compare case-insensitively. On PostgreSQL, check what `makemigrations` actually created:
it emitted the **lowercased** name, so `driver_profile` is almost certainly the table you already
have, and the corrected declaration now points at it instead of at a table that never existed.

### How to find the calls to migrate

```bash
