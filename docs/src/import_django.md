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


## Limitations and Considerations

### Current Limitations

1. **Field Types**: Not all Django field types are supported
2. **Complex Relationships**: ManyToManyField is not yet supported
3. **Custom Fields**: Custom Django fields require manual conversion
4. **Metaclass Options**: Model Meta options are not converted
5. **Methods**: Model methods are not converted (only fields)

## Datetime Interoperability Contract

When PormG writes into tables that are also managed by Django, timezone semantics need to be explicit.

- `DateTimeField` defaults are stored as `Union{ZonedDateTime, DateTime, Nothing}`.
- A user-supplied naive Julia `DateTime` is currently serialized as `UTC` through the default formatter path.
- A `ZonedDateTime` preserves the intended instant and is the recommended type when the source system has a real business timezone.
- Internal `auto_now` and `auto_now_add` behavior attaches `settings.time_zone` when generating timestamps inside PormG.
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
