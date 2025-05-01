# PormG.jl

**PormG.jl** is a Julia ORM inspired by Django ORM, aiming to provide a familiar, expressive, and productive interface for database operations in Julia. 

> **Note:** This project is in a very early stage of development and is a personal hobby — I am not a professional programmer. The package is not yet available for general use. I am looking for people interested in contributing and helping to improve the system!


---

## Example: Model Definition

**Django ORM (Python):**
```python
from django.db import models

class User(models.Model):
    name = models.CharField(max_length=100)
    age = models.IntegerField()
```

**PormG.jl (Julia):**
```julia
module models
import PormG.Models

User = Models.Model(
  id = Models.IDField(),
  name = Models.CharField(max_length=100),
  age = Models.IntegerField()
)
Models.set_models(@__MODULE__, @__DIR__)
end
```

---

## Example: Querying

**Django ORM:**
```python
from .models import *
query = User.objects.filter(name="Alice").order_by("-age").values("name", "age")
result = list(query)
print(query)
```

**PormG.jl:**
```julia
Base.include(esus_back, "db/automatic_models.jl")
import esus_back.automatic_models as M
query = M.User |> object;
query.filter("name"=>"Alice")
query.order_by("-age")
query.values("name", "age")
result = list(query)
println(query)
```

---

## For more examples

For hands-on examples of PormG in action, navigate to the `test\pg` directory and execute the following scripts in this order:

1. **connecting.jl** - Set up database connections
2. **makemigrations.jl** - Create and apply database migrations
3. **insertions.jl** - Add records to your database
4. **selection.jl** - Query and retrieve data
5. **deletion.jl** - Remove records from your database

This tutorial sequence demonstrates a complete workflow from database setup to data manipulation, allowing you to explore PormG's features step by step.


## Contributing

Contributions and feedback are welcome! Please open issues or pull requests on GitHub.

---

## License

MIT License

---
