## Regenerated models files differ: `import_models_from_django`, `inspectdb` and `convertSQLToModel` emit what they used to skip or get wrong (#1095, #1041, #948, #1043, #943, #768, #28, #29, #934, #1021, #837, #1172, #1171, #1180, #1181, #1174)

- **Version**: Unreleased
- **PormG ref**: #1095, #1041, #948, #1043, #943, #768, #28, #29, #934, #1021, #837, #1172, #1171, #1180, #1181, #1174 ; `src/migrations/importers.jl`, `src/migrations/introspection.jl`, `src/migrations/column_spec.jl`, `src/Models.jl` (`Model_to_str`)
- **Recorded**: 2026-10-11
- **Severity**: behavior change. The functions that write a models file now write a different file
  for the same Django project or the same live schema. Nothing changes until the file is
  regenerated; after that, `git diff` on it shows the lines below, and the next `makemigrations`
  plans for what the file now declares.

### What changed

Each row is a shape the generator used to drop, misread or spell differently. All of them are
fixes or new readings; none removes a declaration the old output had, except where noted.

| Source shape | before | after |
|---|---|---|
| Django: an unlabelled class whose name starts with `_` (`class _Pit_window`), no `Meta.db_table` (#1095) | `_Pit_window = Models.Model("_pit_window", …)` — a file that does not load (a model name cannot start with `_`) | `_Pit_window = Models.Model("pit_window", db_table = "_pit_window", …)` |
| Django: an unlabelled `_Internal` beside an `Internal` (#1095) | `_Internal = Models.Model("_internal", …)`, the same unloadable spelling | `Internal` keeps it; `_Internal` becomes `_Internal2` with `db_table = "_internal"` and a `# PormG:` marker |
| Django: an auto ManyToMany at a class whose name starts with `_`, labelled or not (#1095) | join column addressed as `foo_id` | pinned to Django's `_foo_id` |
| Django: `rivals = ManyToManyField("DriverProxy")` on `Driver`, a proxy of the owner (#1171, #1172) | `source_field="from_driver_id", target_field="to_driver_id"` — columns Django never created; the file loads and every query through `rivals` fails at the server | `source_field="driver_id", target_field="driverproxy_id"`, Django's columns |
| Django: `reserves = ManyToManyField("imports.Driver")` on `racing.Driver`, another app's class with the owner's name (#1172) | `source_field="driver_id", target_field="driver_id"` — `set_models` raises `ModelDefinitionError` | `source_field="from_driver_id", target_field="to_driver_id"`, Django's columns |
| Django: `class Pilot(RacingDriver)` with `Meta.proxy = True`, after `from racing.models import Driver as RacingDriver` (#1180) | every relation to `Pilot` degraded: `pilot_id = Models.BigIntegerField(db_index=true)`, a `ManyToManyField` to it dropped, each with a marker saying the target is not in the import | `pilot_id = Models.ForeignKey("Driver", …)`, `Models.ManyToManyField("Driver", …, target_field="pilot_id")`, as for an un-aliased base. The multi-table-inheritance marker names Django's `driver_ptr_id` for an aliased parent (was `racingdriver_ptr_id`) and for a proxy parent `Racer` of `Driver` (was `racer_ptr_id`). A dotted base (`racing_models.Driver`) still degrades |
| Django: an app whose only classes are proxies of another app's models, in a multi-app import (#1181) | `# PormG: app 'legacy' contributed no model to this file — … Any relation pointing into it is degraded below.`, and a `@warn` saying the app declares no importable model, although its relations resolve | `# PormG: app 'legacy' contributed no table to this file — its proxies share their parents' tables, and a relation to one resolves to its parent: 'legacy.Pilot' → 'racing.Driver'.`, and no such `@warn`. An app with nothing resolvable keeps the old line |
| Django: a `ForeignKey` / `OneToOneField` with no `related_name` on a class whose name ends with `_` or contains `__` (`class Driver_`, `class Pit__stop`) (#1174) | `circuit_id = Models.ForeignKey("Circuit", …)` — `set_models` raises `ModelDefinitionError` on the derived reverse accessor `driver_`, and the whole file fails to load | `circuit_id = Models.ForeignKey("Circuit", …, related_name="driver")` with a `# PormG:` marker (`pit_stop` for `Pit__stop`, `driver_<field>` in a group, a digit when the target already holds the name). The reverse side is queried by that name |
| `binding_overrides = Dict("Foo" => "_Bar")` beside a `class Bar` (#1095) | `Bar` silently renamed `bar2` | raises the documented override-collision error |
| Django: a field whose class subclasses a Django field (`class LapTimeField(models.IntegerField)`) (#1041) | left out, with a marker saying the next `makemigrations` would drop the column | imported as its Django base (`Models.IntegerField(…)`), with a `# PormG:` note naming the class. A chain that overrides `db_type` and its kin keeps the old marker |
| Django: an option written as a module constant (`max_length = REF_LEN`) (#948) | the whole import aborted with `FieldValidationError` | the constant's literal value is used when the same `models.py` binds it to a literal above the field |
| Django: any other bare name as an option (`db_column = COL`, `default = uuid4`) (#948) | kept as text: a column literally named `"COL"`, a default `"uuid4"` | dropped, with a `@warn` and a `# PormG:` marker |
| Django: `choices = STATUS_CHOICES` bound to a tuple literal in the same file (#948) | dropped as "a name rather than a literal" | imported as those choices |
| Django: a model with `Meta.db_table` (#1043) | `Race = Models.Model("race", db_table = "f1_race", …)` | `Race = Models.Model(db_table = "f1_race", …)`. The loaded models are identical; only the file text changes |
| Django: `ArrayField(models.X(…))` (#943) | reported and skipped (`strict_fields = true` raised) | `Models.ArrayField(Models.X(…), …)` |
| Django: `CheckConstraint(check = Q(…))` (#768) | always a `# PormG:` stub | a real `Models.CheckConstraint(…)` for the shapes that mean the same on both engines; others keep the stub, now with the reason |
| Django: `GinIndex`, `opclasses=`, `"-field"`, `Index(condition = …)`, functional `Index`/`UniqueConstraint`, `Index(include = …)` (#29, #934) | dropped | translated to `Models.Index(method = …, opclasses = …, expressions = …, condition = …, include = …)` / `UniqueConstraint(condition = …, expressions = …)` |
| Django: `GenericIPAddressField`, `SearchVectorField` (#28, #1021) | skipped as not imported | `Models.GenericIPAddressField(…)` / `Models.SearchVectorField(…)` |
| `inspectdb` / `import_models_from_postgres`: an array column (`integer[]`), an `inet` / `cidr` column, a `tsvector` column (#28, #1021) | a warned `TextField` (or unsupported) | `Models.ArrayField(…)`, `Models.GenericIPAddressField()` / `Models.CIDRField()`, `Models.SearchVectorField()` |
| `inspectdb`: a hand-made DESC / non-btree / opclass / partial / expression / collated / INCLUDE index, a unique partial or functional index (#29, #934) | not read, so not in the file | written as the `Models.Index` / `UniqueConstraint` declaration that matches it |
| `convertSQLToModel("CREATE TABLE \"Pit\"\"stops\" …")` (#837) | a model for the table `Pit`, with no fields | the model for `Pit"stops`; a statement that does not create the named table raises `InvalidMigrationError` |

Every `# PormG:` marker the Django importer writes is now one line (#29).

### Who this affects

Code that regenerates its models file from a Django project (`import_models_from_django`) or from
a live database (`inspectdb`, `import_models_from_postgres`) and commits or diffs the result, or
that calls `convertSQLToModel` directly. An app whose models file is written by hand is not
affected.

### How to find the calls to migrate

```bash
grep -rnE 'import_models_from_django|import_models_from_postgres|inspectdb|convertSQLToModel' --include=*.jl .
```

### Migrate your app

Regenerate the file, review the diff, then run `makemigrations` before deploying. An index, CHECK or
ArrayField the file now declares is one the database already has, so the plan adopts it (a `COMMENT
ON INDEX` / `COMMENT ON CONSTRAINT` marker on PostgreSQL) rather than creating it — read the plan
before applying.

```julia
# ✗ before — a constant option aborted the whole import
PormG.Migrations.import_models_from_django("f1/models.py"; force_replace = true)   # FieldValidationError

# ✓ after — the same call writes the file; review it, then plan
PormG.Migrations.import_models_from_django("f1/models.py"; force_replace = true)
PormG.Migrations.makemigrations("db")
```
