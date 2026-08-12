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

```julia
import_models_from_django(
    model_py_string::String;
    db::String = DB_PATH,
    force_replace::Bool = false,
    ignore_table::Vector{String} = postgres_ignore_table,
    file::String = "automatic_models.jl",
    autofields_ignore::Vector{String} = ["Manager"],
    parameters_ignore::Vector{String} = ["help_text"]
)
```

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

- **`ignore_table::Vector{String}`**: Tables to skip during import
  ```julia
  import_models_from_django(content, ignore_table=["auth_user", "django_migrations"])
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
- `AutoField` → `AutoField`
- `ImageField` → `ImageField`


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
| `choices=[]` | `choices=()` | List to tuple conversion |

### Meta Options

| Django `Meta` option | Outcome | Notes |
|----------------------|---------|-------|
| `db_table = "x"` | **imported** as `db_table = "x"` | The physical table. Absolute, as in Django: it overrides the derived name *and* a configured `django_prefix`. The positional slot keeps the derived logical name (`"matricula"`, or `"dash_matricula"` under a prefix). |
| `unique_together = ('a', 'b')` | **imported** as `constraints = [Models.UniqueConstraint(fields = ("a", "b"))]` | A tuple-of-tuples (several composite keys) becomes one `UniqueConstraint` per group. |
| `constraints = [UniqueConstraint(fields=…, name=…)]` | **imported** | The modern spelling. See the acceptance rule below — it is narrower than Django's. |
| `constraints = [CheckConstraint(…)]` | **rejected**, reported | No PormG equivalent. |
| `abstract = True` | **no table** | The class becomes a base: its fields merge into every child. See [Model inheritance](#Model-inheritance). |
| `proxy = True` | **no table** | A proxy shares its parent's table; emitting one would declare that table twice. |
| `indexes`, `index_together` | **dropped**, reported | PormG has no composite-index primitive — only per-field `db_index`. |
| `ordering`, `get_latest_by` | **dropped**, reported | PormG orders per query, not per model. |
| `managed`, `verbose_name*`, `permissions`, `default_related_name`, `app_label`, … | **dropped**, reported | No PormG equivalent. |
| anything unrecognised | **dropped**, reported | A typo or a Django option this importer has not met. Neither is safe to pass over quietly. |

"Reported" means two things at once: a `@warn` at import time **and** a `# PormG:` comment on the
line above the model in the generated file. The console warning scrolls away; the comment is still
there when someone reads the file six months later.

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

Because foreign-key fields are imported with an `_id` suffix (`item` → `item_id`), the importer
resolves each declared member — in both `unique_together` and `constraints` — to its imported field
name automatically:

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
#   declared there are MISSING below. Add them by hand, or import the app that defines them
#   together with this one.
Relatorio = Models.Model("relatorio",
  id = Models.IDField(),
  titulo = Models.CharField(max_length=80))
```

Dropping the model instead would be the worse trade: a table that silently disappears is harder to
notice than one that is present and annotated.

### ⚠️ Important: CharField with Choices Syntax

When using `CharField` with choices, PormG requires the choices to be defined **inline** for proper parsing. External variables are not supported.

```python
# ✅ CORRECT - Use this pattern:
user_type = models.CharField(
    default=3,
    choices=((1,"Type 1"),(2,"Type 2"),(3,"Type 3"),(4,"Type 4"),(5,"Type 5")),
    max_length=10
)

# ❌ INCORRECT - Don't use this pattern:
user_type_data=((1,"Type 1"),(2,"Type 2"),(3,"Type 3"),(4,"Type 4"),(5,"Type 5"))
user_type = models.CharField(
    max_length=10,
    choices=user_type_data
)
```

**Key Requirements:**
- **Inline definition**: Define choices directly in the field, not as external variables
- **Either outer bracket**: The choices *container* may be a list `[...]` or a tuple `(...)`. Before
  the importer read Python source with a bracket-aware scanner, a list silently kept only its
  *first* choice — the argument splitter counted parentheses only, so it split at the comma between
  two bracketed pairs.
- **Parenthesized pairs**: Each choice must be a `(value, display_name)` tuple. The *inner* bracket
  is **not** free: `choices=[["A", "Alpha"]]` is valid Django but imports as an empty `choices=()`,
  with no warning. Write `choices=[("A", "Alpha")]`.
- **Parameter order**: Place `default` before `choices` for better parsing reliability

The field itself may be wrapped across several lines — that is what `black` produces, and it is read
correctly. Note that a field whose declaration the importer cannot read is reported with a warning
naming the field and its source line; it is never dropped silently.

### Automatic Additions

- **Primary Key**: If no primary key is defined, `id = Models.IDField()` is automatically added
- **AbstractUser**: For models inheriting from `AbstractUser`, additional fields like `date_joined` are added

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
| **Imported** | Fields (including definitions wrapped across lines), `ForeignKey` / `OneToOneField` / `ManyToManyField`, `Meta.db_table`, `Meta.unique_together`, `Meta.constraints` (see the whitelist above), abstract-base inheritance, `AbstractUser` auth columns |
| **Imported, but degraded and annotated** | A model whose base lives in another file — its own fields only. A `Meta.db_table` that is computed rather than a plain string literal — ignored, name derived from the class. A `db_table` on an abstract base — not inherited by its children. A `unique_together` that is a name rather than a literal, or names a field that did not import |
| **Reported and skipped** | `Meta.indexes` and every other option with no PormG equivalent; a `UniqueConstraint` PormG cannot express; multi-table inheritance; proxy models; a field-shaped call the importer cannot read (`tags = ArrayField(...)`) |
| **Not supported** | Field types PormG does not implement — these raise, naming the field and class, rather than importing something wrong. Model methods, managers, signals and validators are Python and have no PormG counterpart |

Nothing in the middle two rows is dropped in silence: each one produces a `@warn` at import time and
a `# PormG:` comment in the generated file. That is the contract this importer holds itself to — if
something did not survive, the artifact says so.

!!! note "`choices` as a list of lists"
    `choices=[["A", "Alpha"]]` is valid Django but imports as an empty `choices=()`, with no warning.
    Write the inner pair as a tuple: `choices=[("A", "Alpha")]`.

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
