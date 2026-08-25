# Importing Django Models to PormG

This tutorial provides a guide on how to migrate Django models to PormG using the `import_models_from_django` function.

## Overview

The `import_models_from_django` function allows you to seamlessly convert Django model definitions from Python `models.py` files into PormG-compatible Julia models. This is particularly useful when:

- Migrating existing Django projects to Julia
- Maintaining consistency between Django and Julia models
- Quickly prototyping Julia models based on existing Django schemas
- Converting legacy Django models for use in Julia applications
- Creating an ETL pipeline for data processing in Julia from an existing Django application

## Function Signature

Two arities: one `models.py`, or a whole multi-app project.

```julia
# one app
import_models_from_django(
    model_py_string::String;
    db::String = DB_PATH,
    force_replace::Bool = false,
    file::String = "automatic_models.jl",
    output_path::Union{Nothing, String} = nothing,
    django_prefix::Union{Nothing, String, Missing} = missing,
    auth_user_model::Union{Nothing, String} = nothing,
    strict_relations::Bool = false,
    binding_overrides::AbstractDict = Dict{String, String}(),
    autofields_ignore::Vector{String} = ["Manager"],
    parameters_ignore::Vector{String} = ["help_text"]
)

# a project — "<app_label>" => "<models.py path or source>" pairs
import_models_from_django(
    apps::AbstractVector{<:Pair};
    db::String = DB_PATH,
    force_replace::Bool = false,
    file::String = "automatic_models.jl",
    output_path::Union{Nothing, String} = nothing,
    auth_user_model::Union{Nothing, String} = nothing,
    strict_relations::Bool = false,
    binding_overrides::AbstractDict = Dict{String, String}(),
    autofields_ignore::Vector{String} = ["Manager"],
    parameters_ignore::Vector{String} = ["help_text"]
)
```

See [Importing a multi-app project](@ref) for the second form.

## Basic Usage

### Step 1: Prepare Your Django Models File

Ensure your Django `models.py` file follows standard Django conventions:

```python
# models.py
from django.db import models
from django.contrib.auth.models import AbstractUser

class Category(models.Model):
    name = models.CharField(max_length=100, unique=True)
    description = models.TextField(blank=True)
    created_at = models.DateTimeField(auto_now_add=True)

class User(AbstractUser):
    email = models.EmailField(unique=True)
    bio = models.TextField(max_length=500, blank=True)
    birth_date = models.DateField(null=True, blank=True)

class Product(models.Model):
    name = models.CharField(max_length=200)
    category = models.ForeignKey(Category, on_delete=models.CASCADE)
    price = models.DecimalField(max_digits=10, decimal_places=2)
    is_active = models.BooleanField(default=True)
    created_by = models.ForeignKey(User, on_delete=models.SET_NULL, null=True)
```

### Step 2: Import Using File Path

```julia
using PormG.Migrations

import_models_from_django("/path/to/your/models.py")

```
## Parameters Explained

### Required Parameters

- **`model_py_string::String`**: The content of your Django `models.py` file. Can be:
  - File path to your `models.py` file
  - String content of the models file
  - Output from `django_to_string(path)`

### Optional Parameters

- **`db::String`**: Database configuration key (default: `DB_PATH`)
  ```julia
  import_models_from_django(content, db="production")
  ```

- **`force_replace::Bool`**: Overwrite existing model files (default: `false`)
  ```julia
  import_models_from_django(content, force_replace=true)
  ```

- **`file::String`**: Output filename (default: `"automatic_models.jl"`)
  ```julia
  import_models_from_django(content, file="my_models.jl")
  ```

- **`autofields_ignore::Vector{String}`**: Field types to ignore (default: `["Manager"]`)
  ```julia
  import_models_from_django(content, autofields_ignore=["Manager", "CustomManager"])
  ```

- **`parameters_ignore::Vector{String}`**: Field parameters to ignore (default: `["help_text"]`)
  ```julia
  import_models_from_django(content, parameters_ignore=["help_text", "verbose_name"])
  ```

- **`output_path::Union{Nothing, String}`**: Directory to write the generated file into, overriding the
  resolved config's `db_def_folder` (default: `nothing`). Use it to stage a *foreign* Django app's
  `models.py` next to its own copy while still resolving `db` for the connection Settings.

- **`django_prefix::Union{Nothing, String, Missing}`**: The Django **app label** whose tables are being
  imported (default: `missing`). `missing` inherits the resolved config's `django_prefix`; `nothing`
  imports unprefixed; a `String` forces that label. See [The app prefix](#The-app-prefix) below.

  ```julia
  # A foreign app staged in db_gal/, written to its own folder with its own label:
  import_models_from_django("db_gal/models.py"; db="db", file="gal_models.jl",
                            output_path="db_gal", django_prefix="estoque", force_replace=true)
  ```

- **`auth_user_model::Union{Nothing, String}`**: which model `settings.AUTH_USER_MODEL` refers to,
  spelled the way Django spells it in `settings.py` (default: `nothing`, which auto-detects the single
  class inheriting `AbstractUser`).
  ```julia
  import_models_from_django(pairs; auth_user_model="access.User")
  ```

- **`strict_relations::Bool`**: `false` (the default) imports a relation whose target is not in this
  import as a plain column, with a `# PormG:` marker. `true` raises `InvalidMigrationError` instead.
  See [Relation targets](@ref).

- **`binding_overrides::AbstractDict`**: spell a generated Julia binding differently from the derived
  one. See [Choosing your own binding](@ref).

Neither `output_path` nor `django_prefix` mutates the shared `db` config: when either is set, a
throwaway render-only `Settings` (no database connection) carries them.

## Relation targets

Every `ForeignKey` / `OneToOneField` / `ManyToManyField` target is resolved to the **Julia binding** of
the model it names, because that is the only thing PormG can resolve at load time — `set_models` looks
a target up as a binding in the generated module and nothing else. Four spellings work:

| Django source | resolves to |
|---|---|
| `ForeignKey(Circuit, …)` or `ForeignKey("Circuit", …)` | the class named, in this app first, then a project-unique one |
| `ForeignKey("self", …)` | the declaring class |
| `ForeignKey("racing.Circuit", …)` | that app's class. Both halves match case-insensitively — Django lowercases the model name and app labels are lowercase by convention, so the extra tolerance on the label can only help |
| `ForeignKey(settings.AUTH_USER_MODEL, …)` | the project's user model — see `auth_user_model` |

An unqualified name that **two apps** declare is an error naming both; qualify it as Django does.

### Targets outside the import

A project that touches `django.contrib` references models it did not hand you. Those **degrade rather
than fail**: the column is real — Django created it — so it is imported as a plain
`BigIntegerField` and the artifact says what was lost.

```julia
# PormG: field 'created_by_id' on 'imports.ImportBatch' — ForeignKey target
#   'contenttypes.ContentType' is not in the imported app set; imported as a plain column,
#   the relation is lost.
created_by_id = Models.BigIntegerField(blank=true, null=true)
```

A `ManyToManyField` has no column of its own, so an unresolvable one — target or `through=` model — is
dropped and marked instead.

Pass `strict_relations = true` to raise `InvalidMigrationError` on the first such target instead. That
is the right setting once you believe every app is in the import; it is not the default, because it
would make the importer unusable on any project that references `django.contrib`.

The one target that is **always** a hard error is `settings.AUTH_USER_MODEL` when the importer cannot
tell which model it is (no `AbstractUser` subclass, or more than one, and no `auth_user_model`). Nearly
every model in a real project points at the user model, so one omitted keyword would quietly turn the
whole user graph into integer columns.

## Importing a multi-app project

A real Django project splits its models across apps. Pass one `"<app_label>" => "<models.py>"` pair per
app:

```julia
import_models_from_django(
  ["racing"  => "server/racing/models.py",
   "access"  => "server/access/models.py",
   "imports" => "server/imports/models.py"];
  db = "f1", file = "models.jl", force_replace = true)
```

Everything lands in **one** generated module, and each model's table carries its own app label:

```julia
Circuit     = Models.Model("circuit",     db_table = "racing_circuit",     …)
User        = Models.Model("user",        db_table = "access_user",        …)
ImportBatch = Models.Model("importbatch", db_table = "imports_importbatch",
  circuit_id = Models.ForeignKey("Circuit", pk_field="id", on_delete=CASCADE),
  steward_id = Models.ForeignKey("User", pk_field="id", on_delete=PROTECT))
```

!!! note "One module per *database*, not per app"
    PormG is structurally one models file per connection: `makemigrations` and `migrate` resolve a
    single `<db>/<model_file>` and load it into a single module. A module per app would not merely be
    unsupported — the migration engine would never see it. Emitting the whole project into one module
    is also what makes a cross-app `ForeignKey("racing.Circuit")` resolvable at all, since resolution
    is a binding lookup in that one module.

    Definition order inside the file does not matter: a `ForeignKey` holds its target as a `String` and
    only resolves after the whole module body has run.

Importing the apps together also merges an **abstract base declared in another app** — the shared
`core.models.TimeStampedModel` shape — and resolves a `TextChoices` enumeration the same way.

**A class from another app has to be imported, exactly as Python requires.** Each app's own classes
win, so a name two apps both declare resolves locally, as it does in Django; anything else is looked
up through that `models.py`'s own `from … import …` lines:

```python
# imports/models.py
from core.models import TimeStampedModel        # <- this line is what makes the merge happen

class ImportBatch(TimeStampedModel):
    note = models.CharField(max_length=40)
```

Without the import the base is reported as unresolved and the model keeps only its own columns —
which is also what Python would do, since the name would not be defined. The lookup accepts the
spellings a real project uses: an alias (`import TimeStampedModel as TSM`), a star import, a
re-export through another app, and a nested package (`from apps.core.models import …`).

A module path names an app when the app's own name is followed by its **models module** —
`core.models`, `core.models.base` — or by nothing at all, the package re-exporting through its
`__init__.py` (`from core import …`). The name matched is the app's label **or** its package
directory, because Django's `AppConfig.label` is frequently not the directory name:
`"crm" => "server/customers/models.py"` resolves `from customers.models import …` as well as
`from crm.models import …`.

Anything written **in front** of that name has to be where the app actually lives. A project laid
out as `apps/core/` resolves `from apps.core.models import …`; the same import against an app at
`server/core/` does not, and neither does `from wagtail.core.models import Page` — Wagtail is not
your `core` app, however much the path looks alike. `from core.forms import Pedido` is refused too:
a sibling module is not the models module.

A **single** leading dot is this app's own package and never names another app, so `from .core.models
import …` stays local; **two or more** ascend, so `apps/{core,shop}/` can write
`from ..core.models import …` and have it resolve.

!!! note "Pass a path, spelled from your Python import root"
    The package directory can only be read from a **path**, and only as deeply as you spell it. An
    app handed over as source text (`"crm" => read("customers/models.py", String)`) is known by its
    label alone, so neither `from customers.models import …` nor any qualified spelling reaches it.
    Equally, an app passed as `"core/models.py"` cannot match `from apps.core.models import …` even
    when Python roots it under `apps/` — pass `"apps/core/models.py"`. Either way the failure is an
    unresolved base with a marker, never a wrong match.

!!! note "Why the import line matters — a table used to disappear ([#370](https://github.com/PingoLee/PormG.jl/issues/370))"
    Matching bases by **name** alone meant a base one app inherited from a third-party library
    resolved against an unrelated app's class of the same name. If that class was concrete, the
    child was read as multi-table inheritance and **not imported** — so adding an app to the list
    removed a table belonging to another app, which Python's per-module namespaces make impossible.
    Resolution now follows the `import` statements, so a name imported from outside the app set can
    no longer collide with an app's class. When a base is left unresolved and another app *does*
    declare that name, the marker says so and names the app — and says whether the module failed to
    import it or imported it from somewhere else entirely, because those want different fixes.

A `django_prefix` on the connection is **rejected** here rather than ignored. It is one value for the
whole connection, and relationship accessor names strip it — so `racing_circuit` would become
`circuit` while `access_user` survived intact, and half the project's reverse lookups would point at
names that do not exist. Remove it from the connection's config; a single-app import that still wants
it can pass `django_prefix=` to that call.

### When two apps use the same class name

Both sides are app-qualified — never just the second one:

```python
# server/racing/models.py          # server/access/models.py
class Driver(models.Model): ...    class Driver(models.Model): ...
```

```julia
Racing_driver = Models.Model("racing_driver", db_table = "racing_driver", …)
Access_driver = Models.Model("access_driver", db_table = "access_driver", …)
```

Renaming only the loser would make the output depend on the order you listed the apps, and PormG keys
a model's reverse accessor on its logical name — so one `Driver` would answer to `driver` and the other
to `driver2`, decided by list order. The rename is lossless because `db_table` still names the real
table. A class name only one app declares is left alone.

Names that differ only in **case** collide too — `Pessoa` and `PESSOA` derive different Julia bindings
but the same logical name — so both are qualified on the same rule.

One residue is left, and it is reported rather than hidden: when two app-qualified names *still*
collide (an app literally called `racing_pit` alongside `racing`'s `Pit`), the second gets a digit
suffix, and which one is second depends on the order you listed the apps. The generated file carries a
`# PormG:` line naming what it collided with; `binding_overrides` picks the spelling if you care which
is which.

### Choosing your own binding

`binding_overrides` replaces the derived name for any model, collision or not:

```julia
import_models_from_django(pairs; binding_overrides = Dict("access.Driver" => "DriverLicence"))
# DriverLicence = Models.Model("driverlicence", db_table = "access_driver", …)
```

The value becomes the model's name, so the binding, the logical name and the reverse accessor all
follow it, while `db_table` keeps naming the real table. It must be a legal, capitalized Julia
identifier that no other model claims — every violation raises `InvalidMigrationError` rather than
falling back to something else, because an override is an explicit instruction and one that silently
does something different is worse than none.

## The app prefix

Django names a model's table `<app_label>_<lowercased class name>`. PormG carries that prefix as the
model's **`db_table`**, leaving the positional slot as the logical handle:

```python
# server/dash/models.py
class Dim_uf(models.Model):
    nome = models.CharField(max_length=50)

class DimIbge(models.Model):
    cidade = models.CharField(max_length=10)
    ufs = models.ManyToManyField(Dim_uf)
```

imported with `django_prefix = "dash"` becomes:

```julia
Dim_uf = Models.Model("dim_uf", db_table = "dash_dim_uf",
  id = Models.IDField(),
  nome = Models.CharField(max_length=50))

DimIbge = Models.Model("dimibge", db_table = "dash_dimibge",
  id = Models.IDField(),
  cidade = Models.CharField(max_length=10),
  ufs = Models.ManyToManyField("Dim_uf", db_table="dash_dimibge_ufs"))
```

Three things to read off that output, and a fourth that shows up only when something is reported:

- **The positional name is `class.__name__.lower()`** — Django's own derivation. `DimIbge` becomes
  `"dimibge"`, with no underscore inserted, because that is what Django's table is called. Whichever
  class-naming convention the project uses, the derived name matches.
- **The Julia binding is the class name, unchanged.** It never carried the prefix, so `M.Dim_uf` in a
  consuming app is unaffected.
- **An auto-derived `ManyToManyField` gets its join table pinned** to Django's spelling, which is
  `<the owning model's table>_<field>` — so `dash_dimibge_ufs` here, but
  `rh_matricula_legado_setores` for a class declaring `Meta.db_table = "rh_matricula_legado"`.
  PormG's own derivation is `<logical model>_<field>`, which addresses a table Django never created.
  A `db_table=` written on the field is left alone, and a field with `through=` is skipped entirely —
  Django ignores `db_table` there, because the join table *is* the through model's table.
- **Anything the importer reports names the class `'dash.DimIbge'`**, not `'DimIbge'` — a
  `django_prefix` *is* the Django app label, so there is a label to qualify with. See
  [Meta Options](#Meta-Options).

Without a `django_prefix` nothing is pinned: no app label is known, so the models import unprefixed
and no `db_table` is emitted.

!!! note "Why `db_table` rather than the model name"
    `django_prefix` is one value per *connection*, so it can only ever express one app label. A real
    Django project splits models across `core_`, `access_` and `imports_` at once — and PormG is
    structurally one models file per **database**, not per app. Carrying the prefix per model is what
    lets a single generated file hold every app in the project, which is what
    [Importing a multi-app project](@ref) does. `django_prefix` is the single-app spelling of the same
    thing; the multi-app arity takes the label from each pair instead and rejects a configured prefix.

!!! note "Keep `django_prefix` set even though the names no longer need it"
    Two things still read it: relationship accessor names strip it, and it is the fallback that spells
    the physical table of a reverse-join target declaring no `db_table`. Both become no-ops once every
    model in the file carries a `db_table`, but a hand-written model on the same connection still
    relies on the fallback, so there is no reason to unset it. It does **not** gate Django-style
    short-form join paths (`"driver__forename"`) — those work on every connection.

!!! note "Existing generated files keep working"
    The older spelling, `Models.Model("dash_dim_uf", …)`, still addresses the table `dash_dim_uf`.
    The new form only appears when you regenerate — see `UPGRADING.md` for the one case that forces
    an edit.

## Supported Django Fields

The function supports conversion of the following Django field types:

### Text Fields
- `CharField` → `CharField`
- `TextField` → `TextField`
- `EmailField` → `EmailField`

### Numeric Fields
- `IntegerField` → `IntegerField`
- `BigIntegerField` → `BigIntegerField`
- `FloatField` → `FloatField`
- `DecimalField` → `DecimalField`

### Date/Time Fields
- `DateField` → `DateField`
- `DateTimeField` → `DateTimeField`
- `TimeField` → `TimeField`

### Boolean Fields
- `BooleanField` → `BooleanField`

### Relationship Fields
- `ForeignKey` → `ForeignKey`
- `OneToOneField` → `OneToOneField`

### Special Fields
- `AutoField` → `IDField` (reported — see below)
- `BigAutoField` → `IDField`
- `SmallAutoField` → `IDField` (reported — see below)
  (PormG has no `AutoField` of its own — it was retired; see [Field Types](fields.md).)
- `ImageField` → `ImageField`

!!! note "Every Django auto key imports as `IDField`"
    `BigAutoField` is Django 3.2+'s `DEFAULT_AUTO_FIELD`. It is BIGINT auto-increment, which is
    exactly what `IDField` is, so it imports silently.

    `AutoField` (INTEGER) and `SmallAutoField` (SMALLINT) map to `IDField` too, because **`IDField`
    is PormG's only integer key type**. PormG used to ship an `AutoField` of its own; it was retired
    because it emitted a `TEXT` column and could never converge. Django's `AutoField` and PormG's
    were never the same thing, and now only one of the two names exists.

    Both are annotated in the generated file, so the substitution is visible. Your existing column
    is **not** re-typed — but a table PormG *creates* from these models gets BIGINT rather than
    INTEGER or SMALLINT.


## Field Mapping

### Parameter Conversion

Django parameters are automatically converted to PormG equivalents:

| Django Parameter | PormG Parameter | Notes |
|------------------|-----------------|-------|
| `max_length` | `max_length` | Direct mapping |
| `null=True` | `null=true` | Boolean conversion |
| `blank=True` | `blank=true` | Boolean conversion |
| `unique=True` | `unique=true` | Boolean conversion |
| `default=value` | `default=value` | Value conversion |
| `on_delete=CASCADE` | `on_delete=CASCADE` | Direct mapping |
| `choices=[…]` | `choices=(…)` | List to tuple; also resolves `TextChoices`/`IntegerChoices` — see [Choices](#Choices) |

### Meta Options

| Django `Meta` option | Outcome | Notes |
|----------------------|---------|-------|
| `db_table = "x"` | **imported** as `db_table = "x"` | The physical table. Absolute, as in Django: it overrides the derived name *and* a configured `django_prefix`. The positional slot keeps the derived logical name (`"matricula"`) either way — see [The app prefix](#The-app-prefix). |
| `unique_together = ('a', 'b')` | **imported** as `constraints = [Models.UniqueConstraint(fields = ("a", "b"))]` | A tuple-of-tuples (several composite keys) becomes one `UniqueConstraint` per group. |
| `constraints = [UniqueConstraint(fields=…, name=…)]` | **imported** | The modern spelling. See the acceptance rule below — it is narrower than Django's. |
| `constraints = [CheckConstraint(…)]` | **rejected**, reported | No PormG equivalent. |
| `abstract = True` | **no table** | The class becomes a base: its fields merge into every child. See [Model inheritance](#Model-inheritance). |
| `proxy = True` | **no table** | A proxy shares its parent's table; emitting one would declare that table twice. |
| `indexes = [Index(fields=['a','b'])]` | **imported** as `indexes = [Models.Index(fields = ("a", "b"))]` | See the acceptance rule below — narrower than Django's. |
| `indexes = [Index(fields=['a'])]` | **imported** as `a = …(db_index=true)` | A one-column index *is* `db_index`, and is the only spelling that round-trips, so nothing is reported. Two exceptions: on the **primary key** it is redundant (already indexed) and skipped, and on a field type with no `db_index` option (`PasswordField`) it is dropped **and** reported. |
| `index_together = (('a','b'), …)` | **imported** as one `Models.Index` per group | The legacy spelling; the non-unique twin of `unique_together`. |
| `ordering`, `get_latest_by` | **dropped**, reported | PormG orders per query, not per model. |
| `managed`, `verbose_name*`, `permissions`, `default_related_name`, `app_label`, … | **dropped**, reported | No PormG equivalent. |
| anything unrecognised | **dropped**, reported | A typo or a Django option this importer has not met. Neither is safe to pass over quietly. |

"Reported" means two things at once: a `@warn` at import time **and** a `# PormG:` comment on the
line above the model in the generated file. The console warning scrolls away; the comment is still
there when someone reads the file six months later.

Both halves name the class **app-qualified** whenever an app label is known — `'imports.ImportBatch'`,
the same `"<app_label>.<Class>"` spelling Django uses in a `Meta` reference. That is what lets a
report be traced back to one model in a project where two apps declare a `Pessoa`: the generated file
holds `Core_pessoa` and `Access_pessoa`, and nothing called `Pessoa`. An unlabelled single-app import
— no `django_prefix` — has no label and nothing to disambiguate against, so it uses the bare class
name.

Two things that qualification does *not* touch. The report names the **Python class**, never the
Julia binding, so a model renamed by a collision or by `binding_overrides` is still reported under
the name its `models.py` actually uses. And a name quoted because the source *wrote* it — a base
class, an enum, a field — stays verbatim: only the class a report is *about* is qualified.

!!! warning "`Meta.constraints` acceptance is a whitelist"
    A `UniqueConstraint` is imported only when its arguments are within
    `fields`, `name`, `violation_error_message`, `violation_error_code`. Anything else — `condition`,
    `expressions`, `nulls_distinct`, `deferrable`, or a positional expression such as
    `UniqueConstraint(Lower("name"), …)` — causes **that one constraint** to be dropped and reported;
    its siblings on the same model are unaffected.

    The direction is deliberate. `Models.UniqueConstraint` is exactly `(fields, name)`, so a Django
    *partial* index (`condition=Q(active=True)`) imported as an unconditional one would start
    silently rejecting rows the live database accepts. Refusing an option is recoverable;
    reinterpreting one is not.

!!! warning "`Meta.indexes` acceptance is a whitelist too"
    An entry is imported only when it is a `models.Index` whose arguments are within `fields` and
    `name`. Everything else causes **that one index** to be dropped and reported, leaving its
    siblings alone:

    - `condition=`, `include=`, `opclasses=`, `expressions=`, `db_tablespace=` — each changes *what*
      is indexed or where it lives;
    - a positional expression, `models.Index(Lower("name"), …)` — a functional index; PormG would
      index the column itself, which is a different index;
    - a **descending** column, `fields=["-year"]` — PormG indexes carry no per-column order, so
      importing it ascending would build a different index under the developer's name;
    - a PostgreSQL-specific class such as `GinIndex` / `BrinIndex` — PormG emits only a default
      b-tree.

    Advanced index shapes (GIN/GiST/BRIN, functional, partial, ordered) are tracked separately.

!!! note "An index name reused across models loses the name, not the index"
    An index name is unique per database, and PormG emits `CREATE INDEX IF NOT EXISTS` — so two
    models declaring the same name would leave the *second* table quietly without its index. An
    abstract base makes that easy to write without noticing: Django installs the base's whole `Meta`
    on every child that declares none of its own, so one
    `indexes = [Index(fields=…, name="base_x")]` reaches every child. Django rejects it at
    system-check time (`models.E030`); this importer keeps the index on every child and drops the
    duplicated **name**, deriving `<table>_<cols>_idx` per table instead, and reports which name was
    surrendered. The same rule applies to a reused `UniqueConstraint` name.

Because foreign-key fields are imported with an `_id` suffix (`item` → `item_id`), the importer
resolves each declared member — in `unique_together`, `constraints`, `indexes` and `index_together`
alike — to its imported field name automatically:

```python
class Dim_item_fabricante(models.Model):
    item = models.ForeignKey(Dim_item, on_delete=models.CASCADE)
    fabricante = models.ForeignKey(Dim_fabricante, on_delete=models.CASCADE)

    class Meta:
        unique_together = ('item', 'fabricante')
```

imports as:

```julia
Dim_item_fabricante = Models.Model("dim_item_fabricante",
  id = Models.IDField(),
  item_id = Models.ForeignKey("Dim_item", pk_field="id", on_delete=CASCADE),
  fabricante_id = Models.ForeignKey("Dim_fabricante", pk_field="id", on_delete=CASCADE),
  constraints = [Models.UniqueConstraint(fields = ("item_id", "fabricante_id",))],
)
```

See [Composite Uniqueness](models.md#Composite-Uniqueness-(unique_together)) for how the
constraint is materialized.

### Model inheritance

A class becomes a table when its base list **resolves** to one — not when it matches a fixed
spelling. `class Pedido(TimeStampedModel):` is imported; so is `class User(AbstractUser, SomeMixin)`.

| Shape | Outcome |
|---|---|
| `class Base(models.Model)` with `Meta.abstract = True` | No table. Its fields merge into every child, and a child that **redeclares** a field wins. |
| `class Child(Base)` where `Base` is abstract | One table carrying `Base`'s fields plus its own. |
| `class Child(Base)` where `Base` is **concrete** | **Not imported.** See below. |
| `class Child(models.Model, PlainMixin)` | One table. Django collects fields only from bases that are themselves models, so a plain mixin contributes none — and PormG matches that. |
| `class Child(Base)` where `Base` is in another file | Imported **with its own fields only**, plus a marker naming the missing base — provided the body declares at least one field (see the row below). |
| `class X(models.QuerySet / models.Manager / models.TextChoices / object)` | Skipped, silently — these are not tables. A class **this file defines** always wins over that list, so your own model named `Manager` is imported normally. |
| any class declaring `Meta.model = X` | Skipped, silently. That is the signature of a `ModelForm`, serializer or `FilterSet`; Django's own `ModelBase` rejects the attribute on a real model. |
| any other unrecognised base | Imported only if the body declares at least one **database** field — see the namespace rule below. A class with only methods and a `Meta` declares none, so it stays out. |

A field counts toward that last rule when it is called through a *model* namespace: `models.CharField(...)`, `db.models.CharField(...)`, the fully qualified `django.db.models.CharField(...)`, or a directly-imported bare `CharField(...)`. A `forms.CharField(...)` or `serializers.CharField(...)` does not.

That distinction is the whole guard for a plain `forms.Form` or DRF `serializers.Serializer` — neither declares `Meta.model`, and their members are field-shaped, so without it both import as `id`-only tables that reach `makemigrations` as real `CREATE TABLE`s. Silent junk in the schema is the mirror of silent loss, and the worse of the two. One consequence worth knowing: an **aliased** import (`from django.db import models as db_models`) is not recognised, so `db_models.CharField(...)` does not count as a field for this rule — it only matters for a class that *also* has an unresolvable base and no plainly-spelled field.

**Meta inheritance follows Django's rule, minus one footgun.** A child that declares no `Meta` block
at all inherits its abstract base's whole `Meta`. Two keys are withheld: `abstract` (Django resets it
too), and `db_table` — Django *does* inherit that one, and the result is every child of the base
pointing at a single table, so PormG refuses it and says so on each affected child.

**Multi-table inheritance is refused, not approximated.** For `class Pedido(Venda)` with a concrete
`Venda`, Django creates a child table whose primary key is a `venda_ptr_id` one-to-one to the parent.
PormG cannot express that. Merging the parent's fields would duplicate its columns; omitting them
would lose the primary key. Both put a schema on disk that contradicts the live database, so the
child is skipped and the generated file records why (markers are one line each; wrapped here to fit):

```julia
# PormG: model 'Pedido' inherits the concrete model 'Venda' (Django multi-table inheritance) —
#   not imported. Django keys the child table on a 'venda_ptr_id' one-to-one to the parent, which
#   PormG cannot express.
```

**A base in another app degrades, it does not delete.** One `models.py` cannot see
`from core.models import TimeStampedModel`, so the child is imported without that base's columns and
says so. The walk covers abstract ancestors too — a base that is itself missing a base loses columns
the same way, and it emits nothing of its own to carry the marker:

```julia
# PormG: model 'Relatorio' inherits 'TimeStampedModel', not defined in this file — any fields
#   declared there are MISSING below. Add them by hand, or pass every app of the project as
#   "<app_label>" => "<models.py>" pairs so a base in another app is merged.
Relatorio = Models.Model("relatorio",
  id = Models.IDField(),
  titulo = Models.CharField(max_length=80))
```

That is the **unlabelled** wording. Once the import carries an app label — a multi-app call, or a
single-app one with a `django_prefix` — the same gap is reported as:

```julia
# PormG: model 'imports.Relatorio' inherits 'TimeStampedModel', not defined in any app of this
#   import — any fields declared there are MISSING below. Add them by hand, or add the app that
#   defines them to the pair list.
```

Two changes, and only the first is general: the class is app-qualified, and this particular marker
also switches "this file" for "any app of this import", because with a label the advice is
different. `'TimeStampedModel'` stays as written either way — it is quoted from the source, not the
class being reported on.

Importing the defining app alongside this one resolves it — provided this `models.py` really does
`from core.models import TimeStampedModel`, which is what the lookup follows. See
[Importing a multi-app project](@ref).

**A class with no resolvable base and no column of its own is reported, not skipped quietly.** Every
field it might have lives in a base the importer cannot see, so there is no evidence either way and
it produces no table — but saying nothing is how a real model disappears without a trace. The marker
names the module the base was imported from, which is usually all it takes to tell the two apart:

```julia
# PormG: class 'MeuManager' inherits 'InheritanceManager', imported from 'model_utils.managers',
#   which nothing in this import defines, and declares no field of its own — not imported. …
# PormG: class 'Pedido' inherits 'TimeStampedModel', imported from 'core.models', which nothing in
#   this import defines, and declares no field of its own — not imported. …
```

The first is a library and nothing is missing; the second says which app to add to the call. A base
with no `import` line at all says that instead. A **dotted** base (`forms.Form`,
`serializers.Serializer`) stays silent: it names a module, so it is a helper by construction, and
the namespace is the same discriminator that keeps a `ModelForm` out of the schema.

Dropping the model instead would be the worse trade: a table that silently disappears is harder to
notice than one that is present and annotated.

### Choices

Both Django spellings are imported: an inline literal, and a `TextChoices` / `IntegerChoices`
enumeration.

```python
class ImportBatch(models.Model):
    class Status(models.TextChoices):
        DRAFT = "DRAFT", "Em processamento"
        APPLIED = "APPLIED", "Aplicado"
        IN_PROGRESS = "IN_PROGRESS"          # label derived: "In Progress"

    status = models.CharField(max_length=20, choices=Status.choices, default=Status.DRAFT)
    canal  = models.CharField(max_length=2, choices=(("UP", "Upload"), ("GS", "Sheets")))
```

imports as (fields are emitted in sorted order, so `canal` precedes `status`):

```julia
ImportBatch = Models.Model("importbatch",
  id = Models.IDField(),
  canal = Models.CharField(max_length=2, choices=(("UP", "Upload"), ("GS", "Sheets"))),
  status = Models.CharField(max_length=20, default="DRAFT", choices=(("DRAFT", "Em processamento"), ("APPLIED", "Aplicado"), ("IN_PROGRESS", "In Progress"))))
```

**Enumerations.** An enum is found whether it is nested inside the model, declared at module level,
or declared on an **abstract base** the model inherits. Lookup is scoped in that order, so two models
may each nest a `Status` with different members and each resolves to its own. A nested enum can also
be addressed through its owner (`ImportBatch.Status.choices`), as Django allows.

Scoping is **per statement, in the module the statement was written in** — the rule Python itself
uses. This matters once an abstract base lives in a different app from the model inheriting it,
because such a model's fields come from two `models.py` files at once:

```python
# core/models.py
class Status(models.TextChoices):
    DRAFT = "d", "Draft"

class Base(models.Model):
    situacao = models.CharField(max_length=1, choices=Status.choices)
    class Meta:
        abstract = True

# shop/models.py
from core.models import Base

class Status(models.TextChoices):      # a DIFFERENT Status
    OPEN = "o", "Open"

class Pedido(Base):                    # inherits `situacao`
    total = models.IntegerField()
```

`Pedido.situacao` imports as `choices=(("d", "Draft"),)` — **core's** enumeration, because that is
the module the statement was written in. `shop`'s `Status` is a different name in a different
namespace and never applies to it (#402).

The rule runs the other way too: a field `shop` declares **itself** cannot reach into `core`'s module
just because it inherits a base from there. Python would raise `NameError` — `shop` never imported
the name — so the importer drops the option and marks it, rather than borrowing an enumeration the
source never referenced.

Within one module the same ordering applies: a **module-level** enum outranks one nested on an
abstract base, because a class body resolves a bare name against the module and never against a base
class. Reach a base's enum deliberately with the qualified `Base.Status.choices`, which is attribute
access and valid Python — addressed by the base's **own class name**, not by an `as` alias it was
imported under, which is dropped and reported. (A bare name matching *only* a base's nested enum is
still resolved, as a convenience — Python would raise `NameError` there.)

A module-level enum in **another app** follows the same rule as a base: it resolves only when the
`models.py` that *uses* it imports it — alias, star import and re-export included, exactly as for a
base. That gate is applied per app, so an abstract base whose own module imports its enum resolves
normally when its statements are merged into a child elsewhere. Matching by name alone handed a
model another app's enumeration with no marker anywhere — the wrong `choices` and `default` in the
schema and nothing in the file to show it (#370).

A **nested** enum belongs to its owning class in its own app, so two apps may each declare a `Base`
with its own nested `Status` and a child of either resolves to the right one.

| Reference | Result |
|---|---|
| `Status.choices` | the full `(value, label)` set |
| `Status.MEMBER` | that member's value — typically what `default=` uses |
| `Status.values` / `.labels` / `.names` | dropped and reported: a flat list, not `(value, label)` pairs |
| a member the enum does not declare | dropped and reported |
| an enum whose members are not literals (`CARRO = auto()`) | dropped and reported — the importer cannot know the value, and keeping `"auto()"` would give every member the same one |
| a numeric member (`ALTO = 1_000`, `MEIO = 0x1F`) | imported as the value it **denotes** — `1000`, `31` — not as the source spelling, which would declare an enumeration no row can match |
| a name this file does not define (`from .enums import Status`) | the option naming it is dropped and reported |

That last row is per option, not per field: if `choices=Status.choices` resolves and only
`default=Externo.ATIVO` does not, the field keeps its enumeration and loses just the default.
Dropping the resolvable half as well would throw away what the source did give you. The reason
neither is ever passed through as a literal is that `default="Externo.ATIVO"` against an empty
`choices` is exactly what used to make `CharField` reject the field and abort the **entire** import.

A member's own attributes work too: `Status.NOVO.value` resolves to the stored value, while
`.label` and `.name` are display text and the member name rather than a value, so they are dropped
and reported.

The same rule catches a dotted name that is not an enum at all — a module constant such as
`default=constants.MAX_QTD` — so the diagnostic says "this file does not define" rather than naming
an enumeration it cannot verify. The test is the attribute's *shape*: `.choices`, `.values`,
`.labels`, `.names`, `.value`, `.label`, `.name`, or a `SHOUTY_CASE` member. Any other dotted
`default` (`uuid.uuid4`, `timezone.now`, an unconventionally-spelled `Externo.ativo`) is **kept
verbatim as text**, exactly as before — and reported, because an expression landing in the schema as
a literal default is not something to discover later.

A `choices` naming a module-level constant (`choices=STATUS_CHOICES`) has nothing to read: the
option is dropped and reported rather than becoming an empty enumeration.

**`choices` needs a `CharField`.** It is the only PormG field type with a `choices` slot, so a Django
`TextField(choices=…)` imports as a plain `TextField` with the option dropped and reported. The column
is unaffected.

!!! note "Values carry no quote characters"
    An inline `("UP", "Upload")` imports as the value `UP`. Before this, it was stored as the
    four-character string `"UP"` — the quote marks kept as part of the value. `choices` is Julia-side
    metadata that never reaches DDL, so nothing downstream misbehaved, but regenerating an existing
    import now produces the clean form.

**Both containers, both pair styles.** `choices` may be a tuple or a list, and so may each pair —
`[["A", "Alpha"]]` imports correctly. A comma inside a *label* (`("APPLIED", "Aplicado, com
ressalvas")`) is content, not a separator. An entry that is not a `(value, label)` pair at all is
dropped and reported, and the well-formed entries beside it survive.

The field itself may be wrapped across several lines — that is what `black` produces, and it is read
correctly. A field whose declaration the importer cannot read is reported with a warning naming the
field and its source line; it is never dropped silently.

### Automatic Additions

- **Primary Key**: If no primary key is defined, `id = Models.IDField()` is automatically added.
  Declaring any field `primary_key=True` **suppresses** it, as in Django — including a field named
  `id` itself, which then keeps its declared type
- **AbstractUser**: For models inheriting from `AbstractUser`, additional fields like `date_joined` are added.
  `id` is **not** one of them: `AbstractUser` inherits Django's implicit `id` from `models.Model`
  rather than owning it, so a user model keyed on its own field — `matricula = CharField(primary_key=True)`
  on a legacy table — has that one key and no `id`, like any other model

!!! warning "Not every field type can be a primary key in PormG"
    `primary_key=True` is honoured on exactly five types: `IDField`, `CharField`, `UUIDField`,
    `ForeignKey` and `OneToOneField`.

    `DecimalField` and `FloatField` reject it deliberately (precision-comparison risk) and **raise**,
    which stops the import — re-declare that column as a `CharField` key in Django, or exclude it.

    On every other type it is silently **dropped** at construction, so
    `codigo = models.IntegerField(primary_key=True)` imports as a plain `IntegerField` and the model
    ends up with **no** primary key at all.

    The importer does **not** paper over that with a synthetic `id`: the Django table has no such
    column, and naming one would break every query that expands the field list. It emits a `# PormG:`
    marker above the model and a warning naming the field, so the gap is visible in the artifact.

    **Fix it — do not ship it.** A model with no primary key is not merely limited:

    - a `ManyToManyField` pointing at it makes the **whole generated file fail to load**
      (`ModelDefinitionError: … requires the target model to define a single primary key`), taking
      every other model in the file with it;
    - a `ForeignKey` pointing at it **loads and is silently wrong** — the key is rendered as
      `pk_field="id"`, naming a column the table does not have;
    - `save()` and the migration planner have nothing to key on.

    Re-declare the key by hand as `Models.CharField(primary_key=true, …)` or
    `Models.UUIDField(primary_key=true)`, matching the real column.

!!! note "Django-import conventions differ from native PormG"
    The importer deliberately matches **Django's** schema conventions, not PormG's: it auto-adds an
    implicit `id` primary key and appends `_id` to foreign-key columns (`category` → `category_id`).
    Native PormG models do neither — you declare the `IDField` and FK columns are verbatim. The
    importer matches Django because Django owns that schema and PormG reads it (ETL); it does not run
    migrations for imported models. See [Schema Conventions](schema_conventions.md) for the full
    native contract and this asymmetry.


## Limitations and Considerations

### What survives the import

| | |
|---|---|
| **Imported** | Fields (including definitions wrapped across lines; Django's `BigAutoField` maps to `IDField`, an exact match), `ForeignKey` / `OneToOneField` / `ManyToManyField` — including `"self"`, `"<app_label>.<Class>"` and `settings.AUTH_USER_MODEL` targets, `Meta.db_table`, `Meta.unique_together`, `Meta.constraints`, `Meta.indexes`, `Meta.index_together` (the last three: see the whitelists above), abstract-base inheritance, `AbstractUser` auth columns, `TextChoices` / `IntegerChoices` enumerations |
| **Imported, but degraded and annotated** | An `AutoField` or `SmallAutoField` — imported as `IDField`, because `IDField` is PormG's only integer key type (see the note under *Supported Django Fields*); the key is faithful, the declared width is not. A model whose base lives in another file — its own fields only. A relation whose target is not in this import — the column survives as a `BigIntegerField`, the relation does not (a `ManyToManyField` has no column, so it is dropped); `strict_relations = true` raises instead. A `Meta.db_table` that is computed rather than a plain string literal — ignored, name derived from the class. A `db_table` on an abstract base — not inherited by its children. A `unique_together` that is a name rather than a literal, or names a field that did not import. A field whose enum this file cannot see — the column survives, the enumeration does not. A field whose `choices` and/or `default` the field type rejects at construction — including a lone `default` on a field with no choices at all, such as one longer than `max_length` — the column survives without them. A `primary_key=True` on a field type PormG cannot key on — the column survives, the key does not, and no `id` is substituted; the model is then unusable by relations until you re-declare the key (see the warning above) |
| **Reported and skipped** | `Meta.ordering` and every other option with no PormG equivalent; a `UniqueConstraint` or an `Index` PormG cannot express; multi-table inheritance; proxy models; a field-shaped call the importer cannot read (`tags = ArrayField(...)`) |
| **Not supported** | Field types PormG does not implement — these raise, naming the field and class, rather than importing something wrong. Model methods, managers, signals and validators are Python and have no PormG counterpart |

Nothing in the middle two rows is dropped in silence: each one produces a `@warn` at import time and
a `# PormG:` comment in the generated file, naming the class app-qualified when a label is known
(see [Meta Options](#Meta-Options)). That is the contract this importer holds itself to — if
something did not survive, the artifact says so.


## API Naming Differences from Django

PormG is **inspired by** Django, not a port — where an API is genuinely different, it also gets its own name rather than borrowing Django's. The one you will notice first when migrating:

| Django | PormG | Why it's not just a rename |
| :--- | :--- | :--- |
| `Model.objects.bulk_create(objs, batch_size=…, ignore_conflicts=…)` | `bulk_insert(query, df; chunk_size=…, on_conflict=…)` | PormG's bulk API is **DataFrame-first**: it inserts rows from a `DataFrame` (with optional `"df_col" => "model_field"` mapping) instead of a list of model instances, and it does not materialize/return created instances. Conflict handling is the explicit `on_conflict=` kwarg (`:nothing`, or `(action = :update, target = […], set = […])` for upserts) rather than Django's `ignore_conflicts`/`update_conflicts` booleans. |

`bulk_insert` sits beside its siblings `bulk_update` and `bulk_copy` — see [Bulk Operations](write/bulk.md) for the full API.

## Datetime Interoperability Contract

When PormG writes into tables that are also managed by Django, timezone semantics need to be explicit.

- `DateTimeField` defaults are stored as `Union{ZonedDateTime, DateTime, Nothing}`.
- **Every `DateTimeField` value is canonicalized to one UTC ISO-8601 string** (`yyyy-mm-ddTHH:MM:SS.sss+00:00`) on write, bind, and filter (issue #79) — the same convention as Django `USE_TZ=True`. Equality/range filters return the same rows on PostgreSQL and SQLite regardless of the input's spelling.
- A user-supplied naive Julia `DateTime` is serialized as `UTC` through the formatter path.
- A `ZonedDateTime` preserves the intended instant (converted to UTC for storage) and is the recommended type when the source system has a real business timezone.
- Internal `auto_now` and `auto_now_add` timestamps are generated in `settings.time_zone` and then canonicalized to UTC on serialization — the same instant, stored in the UTC spelling.
- If your Django app uses `USE_TZ=True` and `TIME_ZONE = "America/Sao_Paulo"`, passing a plain `DateTime(2026, 3, 13, 9, 0)` from Julia does not mean "09:00 Sao Paulo"; it means "09:00 UTC". Use `ZonedDateTime(DateTime(2026, 3, 13, 9, 0), tz"America/Sao_Paulo")` when the civil timezone matters.


This will generate Julia models compatible with PormG that maintain the same structure and relationships as your original Django models.

## Using Converted Models with `@import_models`

After converting your Django models to PormG format, you can load them in your application using the `@import_models` macro for automatic registration and hot-reloading support:

```julia
# In your main Julia package:
module MyApp
    using PormG
    
    # Load the converted models
    PormG.@import_models "db/models.jl" models
    import .models as M
    
    # Now you can use queries like:
    # M.Product.objects.filter("price__@gt" => 100) |> DataFrame
end
```

This approach provides:
- **Automatic registration** of all converted models
- **Hot-reloading** during interactive development (with Revise.jl)
- **Post-precompilation support** so models work in packaged code
- **No manual `set_models()` calls** required

For more details on using models in your application, see [Defining Models in PormG](models.md).
