# Defining Models in PormG

PormG models describe the structure of your database tables using Julia code, inspired by Django ORM but tailored for Julia's syntax and performance.

## What is a Model?
A model is a Julia object that defines the fields (columns) and their types for a database table. Each model maps directly to a table in your PostgreSQL or SQLite database.

## Creating a Model

1. **Edit Your Models File**
   - By default, models are defined in `db/models.jl`.
   - Each model is a Julia struct using PormG field types.

2. **Example Model Definition**

```julia
Driver = Models.Model(
    id = Models.IDField(),
    name = Models.CharField(max_length=100),
    birthdate = Models.DateField(),
    nationality = Models.CharField(max_length=50)
)
```

3. **Example of module contruction in `db/models.jl`**

```julia
module models
import PormG.Models
import PormG.Models: RESTRICT, CASCADE, SET_NULL, SET_DEFAULT, DO_NOTHING


Status = Models.Model(
  statusId = Models.IDField(),
  status = Models.CharField()
)

Circuit = Models.Model( # You can create a model like a Django model for each table so that you can define a huge number of tables at once in just one file. Please capitalize the names of models.
  circuitId = Models.IDField(), # the PormG automatically do a lowercase for the name of the field, so you can use a capital letter in the name of the field, Hoewver you need to use a lowercase in the query operations.
  circuitRef = Models.CharField(),
  name = Models.CharField(),
  location = Models.CharField(),
  country = Models.CharField(),
  lat = Models.FloatField(),
  lng = Models.FloatField(),
  alt = Models.IntegerField(),
  url = Models.CharField()
)

Race = Models.Model(
  raceId = Models.IDField(),
  year = Models.IntegerField(),
  round = Models.IntegerField(),
  circuitId = Models.ForeignKey(Circuit, pk_field="circuitId", on_delete="CASCADE"),
  name = Models.CharField(),
  date = Models.DateField(),
  time = Models.TimeField(null=true),
  url = Models.CharField(),
  fp1_date = Models.DateField(null=true),
  fp1_time = Models.TimeField(null=true),
  fp2_date = Models.DateField(null=true),
  fp2_time = Models.TimeField(null=true),
  fp3_date = Models.DateField(null=true),
  fp3_time = Models.TimeField(null=true),
  quali_date = Models.DateField(null=true),
  quali_time = Models.TimeField(null=true),
  sprint_date = Models.DateField(null=true),
  sprint_time = Models.TimeField(null=true),
)

Driver = Models.Model(
  driverId = Models.IDField(),
  driverRef = Models.CharField(),
  number = Models.IntegerField(null=true),
  code = Models.CharField(),
  forename = Models.CharField(),
  surname = Models.CharField(),
  dob = Models.DateField(),
  nationality = Models.CharField(),
  url = Models.CharField()
)

Constructor = Models.Model(
  constructorId = Models.IDField(),
  constructorRef = Models.CharField(),
  name = Models.CharField(),
  nationality = Models.CharField(),
  url = Models.CharField()
)

Result = Models.Model(
  resultId = Models.IDField(),
  raceId = Models.ForeignKey(Race, pk_field="raceId", on_delete="CASCADE"),
  driverId = Models.ForeignKey(Driver, pk_field="driverId", on_delete="RESTRICT"),
  constructorId = Models.ForeignKey(Constructor, pk_field="constructorId", on_delete="RESTRICT"),
  number = Models.IntegerField(null=true),
  grid = Models.IntegerField(),
  position = Models.IntegerField(null=true),
  positionText = Models.CharField(),
  positionOrder = Models.IntegerField(),
  points = Models.FloatField(),
  laps = Models.IntegerField(),
  time = Models.CharField(null=true),
  milliseconds = Models.IntegerField(null=true),
  fastestLap = Models.IntegerField(null=true),
  rank = Models.IntegerField(null=true),
  fastestLapTime = Models.TimeField(null=true),
  fastestLapSpeed = Models.FloatField(null=true),
  statusId = Models.ForeignKey(Status, pk_field="statusId", on_delete="CASCADE")
)

Just_a_test_deletion = Models.Model(
  id = Models.IDField(),
  name = Models.CharField(),
  test_result = Models.ForeignKey(Result, pk_field="resultId", on_delete="CASCADE", null=true, related_name="test_deletion"),
  test_result2 = Models.ForeignKey(Result, pk_field="resultId", on_delete="CASCADE", null=true, related_name="test_deletion2")
)

end
```

- Each field uses a PormG field constructor (e.g., `IDField`, `CharField`, `DateField`).
- You can use keyword arguments to customize field options (e.g., `max_length`, `unique`, `null`).

## Naming Conventions and Considerations

### Model Naming Rules
- **Use snake_case with capitalized first letter**: `User`, `Product`, `Order_item`
- **Use singular nouns**: `User` not `Users`, `Product` not `Products`
- **Be descriptive and clear**: `User_profile`, `Product_category`, `Order_history`

### Model Organization
- **Keep models in `db/models.jl`** or similar organized structure
- **Group related models together** in logical sections
- **Use meaningful comments** to explain complex relationships

## Development Workflow

PormG supports two primary workflows for model creation:

### 1. Model-First (Recommended for New Projects)
1. Define your models in a `models.jl` file.
2. Use `PormG.Migrations.makemigrations()` to detect changes.
3. Use `PormG.Migrations.migrate()` to apply them to your database.

### 2. DB-First (Legacy or Existing Databases)
If you already have a database, you can use the **`PormG.setup()`** utility to generate your model code automatically:

```julia
using PormG
# This will introspect the DB and create a basic models.jl for you
PormG.setup("path/to/my/db") 
```

---

## Loading Models in Your Application

### Using `@import_models` (Recommended)
The `@import_models` macro is the recommended way to load models in your application:

```julia
# In your main module (e.g., mypkg.jl):
module MyApp
    using PormG
    
    # Load models from external file with hot-reload support
    PormG.@import_models "db/models.jl" my_models
    import .my_models as M
    
    # Now use M.Driver, M.Race, M.Result, etc.
    # Models automatically update when you edit db/models.jl and save
end
```

#### What `@import_models` Does
1. **Resolves the model file path** relative to your source file
2. **Tracks the file with Revise** (if available) for hot-reloading in interactive sessions
3. **Registers models** with PormG so fields and metadata are indexed
4. **Injects `__init__()`** to re-register models after package precompilation
5. **Enables hot-reloading**: Edit your `models.jl`, save, and model changes appear instantly in the REPL

### Inline Models (without a separate file)
If you define models directly in code rather than a separate file, use the `@models_module` macro:

```julia
PormG.@models_module my_models "db" begin
    import PormG.Models as M

    Driver = M.Model("drivers",
        driverId = M.IDField(),
        forename = M.CharField()
    )
end
import .my_models as M
```

`@models_module` handles registration automatically — no manual `set_models()` call is needed.


## Hot-Reloading Model Definitions

When using `@import_models` with `Revise.jl`, model changes are automatically detected and applied:

```julia
# Your REPL session (with Revise.jl loaded):
julia> using MyApp
julia> M.Driver.fields  # Shows current fields: id, name

# Edit db/models.jl to add a field, save the file...

julia> M.Driver.fields  # Automatically updated with new field!
```

This enables rapid development and testing without restarting Julia. When you modify models:
- Add new fields
- Remove fields
- Change field types
- Adjust field parameters

All changes are automatically reloaded and available in the next REPL command.

## Supported Field Types

PormG provides comprehensive field types for all common database scenarios:

- **Primary Key Fields**: `IDField`, `AutoField`
- **Text Fields**: `CharField`, `TextField`, `EmailField`
- **Numeric Fields**: `IntegerField`, `BigIntegerField`, `FloatField`, `DecimalField`
- **Date/Time Fields**: `DateField`, `DateTimeField`, `TimeField`, `DurationField`
- **Other Types**: `BooleanField`, `ImageField`, `BinaryField`
- **Relationship Fields**: `ForeignKey`, `OneToOneField`

For detailed documentation on each field type, including parameters, examples, and best practices, see [Field Types Reference](fields.md).




## Post-Precompilation Behavior

When your package is precompiled (e.g., after `import MyPkg`), the `@import_models` macro ensures models are **automatically re-registered** via injected `__init__()` functions. This means:

- Models are available in package code without manual registration
- Hot-reloading continues to work in interactive sessions
- No additional setup is required for REPL users

---
For more details, see the [PormG Documentation](index.md) or the example scripts in the `test/integration/` folder.
