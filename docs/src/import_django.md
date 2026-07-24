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

The importer reads one `class Meta:` option:

| Django `Meta` option | PormG equivalent | Notes |
|----------------------|------------------|-------|
| `unique_together = ('a', 'b')` | `constraints=[Models.UniqueConstraint(fields=("a", "b"))]` | Composite uniqueness. A tuple-of-tuples (multiple composite keys) becomes one `UniqueConstraint` per group. |

Because foreign-key fields are imported with an `_id` suffix (`item` → `item_id`), the importer
resolves each `unique_together` member to its imported field name automatically:

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
constraint is materialized. Django's newer `Meta.constraints = [UniqueConstraint(...)]` form is
not parsed yet — declare it directly in PormG.

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
- **Tuple format**: Use parentheses `()` for choices, not square brackets `[]`
- **Tuple structure**: Each choice must be a tuple `(value, display_name)`
- **Nested tuples**: The entire choices parameter must be a tuple of tuples
- **Parameter order**: Place `default` before `choices` for better parsing reliability

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

### Current Limitations

1. **Field Types**: Not all Django field types are supported
2. **Complex Relationships**: ManyToManyField is not yet supported
3. **Custom Fields**: Custom Django fields require manual conversion
4. **Metaclass Options**: Model Meta options are not converted
5. **Methods**: Model methods are not converted (only fields)

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
