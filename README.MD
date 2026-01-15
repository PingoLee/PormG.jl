# PormG.jl

**PormG.jl** is a Julia ORM inspired by Django ORM, aiming to provide a familiar, expressive, and productive interface for database operations in Julia. 

> **Note:** This project is in a very early stage of development and is a personal hobby — I am not a professional programmer. The package is not yet available for general use. I am looking for people interested in contributing and helping to improve the system!

## 📚 Documentation

For comprehensive documentation, tutorials, and API reference, visit:
**[https://pingolee.github.io/PormG.jl/dev/](https://pingolee.github.io/PormG.jl/dev/)**


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
Base.include(your_module, "db/models.jl")
import your_module.automatic_models as M
query = M.User.objects.filter("name"=>"Alice").order_by("-age").values("name", "age");
result = query |> list
println(query)
```

## Contributing

Contributions and feedback are welcome! Please open issues or pull requests on GitHub.

---

## License

MIT License

---
