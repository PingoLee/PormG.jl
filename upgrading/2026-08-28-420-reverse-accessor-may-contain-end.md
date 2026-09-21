## A reverse accessor may not contain `__` or `@`, or end with `_` (#420)

- **Version**: 0.5.0
- **PormG ref**: #420; `src/Models.jl`, `src/models/fields.jl`, `src/migrations/importers.jl`,
  `docs/src/read/values_and_joins.md`, `docs/src/fields.md`
- **Recorded**: 2026-08-28
- **Severity**: **breaking** — a new refusal. A model that loads today can stop loading. It is
  narrow: the name it now rejects was never addressable in the first place. Part of the `0.5.x`
  pre-publish wave.

### What changed

An accessor is only ever looked up as **one segment** of a `__`-split path. Two shapes break that,
with one consequence — the name registers cleanly and can never be written as a path segment, so a
query naming it fails with an `UnknownFieldError` about a **truncated fragment** that appears nowhere
in the user's source:

- **containing `__` or `@`** — every resolver splits a path on `__` before looking any piece up, and
  `@` opens an operator suffix (`__@gt`);
- **ending with `_`** — traversing an accessor *appends* the separator, so `incidents_` reached as
  `incidents___lap` splits into `incidents` and `_lap`.

PormG now refuses all three in a reverse accessor, on every route that can produce one:

| Route | Before | Now |
| --- | --- | --- |
| An explicit `related_name` on `ForeignKey` / `OneToOneField` / `ManyToManyField` | accepted, unusable | `FieldValidationError` at the field constructor |
| A **derived** name — the model name for a lone relation, `<model>_<field>` for a group of two or more to one target | accepted, unusable | `ModelDefinitionError` at `set_models`, naming which name carries the fault |
| A Django `related_name='a__b'` read by `import_models_from_django` | accepted, unusable | `InvalidMigrationError` naming the Python class and attribute |

Django refuses both shapes too — system checks `fields.E309` (must not contain `__`) and
`fields.E308` (must not end with `_`) — so a Django project that passes `manage.py check` cannot
produce the importer case at all. (Django's `fields.E002` additionally forbids a `__` in a *field*
name; PormG deliberately does not, which is the divergence the next paragraph describes.)

**What did NOT change:** a *column* named `caused__by_id` still loads. The guard is on the accessor,
never on the column — a model carrying such a column is refused only if its derived **accessor**
would itself be illegal, by either mechanism.

Several shapes derive one, and the **first** row is the one most likely to surprise: **a
single relation is enough**, because a lone relation's derived accessor *is* the model name.

| Where the fault sits | Reached by | Derived accessor |
| --- | --- | --- |
| `__` in the model name | any model named `…__…`, with **one** relation or more | `incident__log` |
| `__` in a field name | a `__` column in a group of two or more relations to one target | `incident_caused__by_id` |
| `__` at the boundary | a field named `_id` (or a model name ending in `_`) in such a group | `incident__id` |
| a trailing `_` on the model name | any model named `…_`, with **one** relation or more | `incident_` |
| a trailing `_` on a field name | a column named `lap_` in such a group | `incident_lap_` |
| a trailing `_` **the generator added** | a relation column named after a Julia keyword — `end`, `local`, `do`, `for`, `if` — in such a group | `incident_end_` |

### How to find the calls to migrate

```bash
# 1. explicit names — contains __ or @, or ends with _
grep -rnE 'related_name[[:space:]]*=[[:space:]]*"([^"]*(__|@)[^"]*|[^"]*_)"' <your app>/

# 2. MODEL names — the derived route, and the one a single relation is enough to trigger
grep -rnE '(^|[^A-Za-z0-9_])(PormG\.)?(Models\.)?Model(_Type)?\([[:space:]]*(name[[:space:]]*=[[:space:]]*)?"([^"]*(__|@)[^"]*|[^"]*_)"' <your app>/

# 3. field names — contains __, or ends with _ (no `@`: a Julia identifier cannot hold one)
grep -rnE '(^|[[:space:],(])[A-Za-z0-9_]*(__[A-Za-z0-9_]*|_)[[:space:]]*=[[:space:]]*Models\.(ForeignKey|OneToOneField|ManyToManyField)' <your app>/
```

Recipe #2 is line-based, so it misses a declaration that puts the model name on its own line.
`Model_to_str` never does that, so this only affects hand-written models. A `__` in **`db_table`** is
exempt and needs no search: the accessor derives from the logical name only, so
`Models.Model("internal", db_table = "dash__internal")` — the shape the Django importer emits under
an app prefix — is unaffected.

**Run recipe #3 on generated files too — the two halves of the rule behave oppositely there.**

- For `__`, a generated file is safe by construction: `Model_to_str` renames an illegal column to
  a legal Julia identifier and pins the real name with `db_column`, so `caused__by_id` is emitted
  as `caused_by_id = Models.ForeignKey(…, db_column="caused__by_id", …)`. It *cannot* contain a
  `__` field identifier, so that row is only reachable from a hand-written
  `Model_Type(; fields = Dict(...))`.
- For a trailing `_`, the same function is the **source**: it escapes a column whose name is a
  Julia keyword or a model-option kwarg by *appending* `_`. A column named `end` is emitted as
  `end_ = Models.ForeignKey(…, db_column="end", …)`, and in a group of two or more relations to
  one target that derives `<model>_end_` — so the generated file no longer loads.

The escaped set is PormG's `reserved_words` list — 29 entries, most of them Julia keywords, plus
`constraints` / `db_table` / `indexes`. `end`, `local`, `do`, `for` and `if` are all on it and
all plausible legacy column names. Give such a field an explicit `related_name` in the generated
file, or rename the column.

All three returned nothing for `esus_back`. Run them against your own checkout rather than trusting
a number recorded here — a count is only true of the tree it was measured on, and this file outlives
any given snapshot.

### Migrate your app

```julia
# ✗ before — both registered, and then unreachable
driverid = Models.ForeignKey(Driver, pk_field="id", related_name="incident__driver")
driverid = Models.ForeignKey(Driver, pk_field="id", related_name="incidents_")

# ✓ after — an underscore INSIDE the name is fine, and so is a leading one
driverid = Models.ForeignKey(Driver, pk_field="id", related_name="incident_driver")
driverid = Models.ForeignKey(Driver, pk_field="id", related_name="_incidents")
```

For a derived name you cannot rename — a legacy column such as `caused__by_id` on a model with two
foreign keys to `Driver` — name the accessor yourself instead of letting PormG derive it:

```julia
# ✗ before — the derived accessor was `incident_caused__by_id`
caused__by_id  = Models.ForeignKey(Driver, pk_field="id"),
affected_by_id = Models.ForeignKey(Driver, pk_field="id"),

# ✓ after — the column keeps its name; only the accessor changes
caused__by_id  = Models.ForeignKey(Driver, pk_field="id", related_name="incident_caused_by"),
affected_by_id = Models.ForeignKey(Driver, pk_field="id"),
```

Then update any query that traversed the old accessor — though by definition none can exist, because
the old name was never addressable.
