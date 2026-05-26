# Many-to-Many Relationships

Many-to-many relationships are common in relational databases: a driver can have multiple sponsors, and a sponsor can endorse multiple drivers. 

PormG provides the `ManyToManyField` to manage these relationships, heavily inspired by Django. It automatically handles the intermediary "join" table behind the scenes, or lets you define it explicitly when you need to store extra data about the relationship.

---

## Implicit Through Tables (Auto-generated)

If you only need to link two models together without storing extra metadata about the link itself, PormG can synthesize the join table for you automatically.

Consider a Formula 1 scenario where drivers have personal sponsors:

```julia
using PormG.Models

M2m_sponsor_scratch = Models.Model("m2m_sponsor_scratch",
  id = Models.IDField(),
  name = Models.CharField(unique=true)
)

M2m_driver_endorsement_scratch = Models.Model("m2m_driver_endorsement_scratch",
  id = Models.IDField(),
  driverRef = Models.CharField(unique=true),
  
  # PormG will automatically create a join table for this relationship
  sponsors = Models.ManyToManyField(M2m_sponsor_scratch, related_name="drivers")
)
```

When you run migrations, PormG will generate a third table (e.g., `m2m_driver_endorsement_scratch_sponsors`) containing two foreign keys (`m2m_driver_endorsement_scratch_id` and `m2m_sponsor_scratch_id`) and a composite unique constraint.

### The Power of `related_name`

Notice the `related_name="drivers"` parameter in the field definition above. This is a very powerful feature that defines the name of the **reverse relationship** on the target model. 

It tells PormG to create a link in **both** directions:
1. **Forward Access**: From a fetched driver row, use the field name `sponsors` to get their sponsors (`driver.sponsors.all()`).
2. **Reverse Access**: From a fetched sponsor row, use the `related_name` to get the drivers they sponsor (`sponsor.drivers.all()`).

This is essential for multi-hop joins and reverse-lookups. Without it, PormG defaults to a less readable name (like `m2m_driver_endorsement_scratch_set`).

---

## Explicit Through Tables

Sometimes you need to store extra data *on the relationship itself*. For example, you might want to know not just *which* team a driver races for, but *what year* they joined.

To do this, you define a regular model with two `ForeignKey` fields, and then tell the `ManyToManyField` to use it via the `through` keyword argument.

> [!TIP]
> **Django Style**: You can pass the `through` model as a **string**. This allows you to define the `ManyToManyField` inline before the through model is actually defined, avoiding circular reference errors in Julia.

```julia
using PormG.Models

M2m_team_scratch = Models.Model("m2m_team_scratch",
  id = Models.IDField(),
  name = Models.CharField(unique=true)
)

M2m_driver_explicit_scratch = Models.Model("m2m_driver_explicit_scratch",
  id = Models.IDField(),
  driverRef = Models.CharField(unique=true),
  
  # Note that we use a string "M2m_membership_scratch" to refer to a model 
  # that hasn't been evaluated yet.
  teams = Models.ManyToManyField(M2m_team_scratch, through="M2m_membership_scratch", related_name="drivers")
)

# The explicit through model
M2m_membership_scratch = Models.Model("m2m_membership_scratch",
  id = Models.IDField(),
  driver = Models.ForeignKey(M2m_driver_explicit_scratch, on_delete=Models.CASCADE),
  team = Models.ForeignKey(M2m_team_scratch, on_delete=Models.CASCADE),
  
  # Our extra data!
  joined_year = Models.IntegerField()
)
```

This pattern matches Django exactly and keeps your model definitions clean and readable.

### Relationship Mutator Limitations on Custom Through Tables

> [!WARNING]
> **Django-Style Strict Mutators**: If your custom intermediate `through` model contains *any extra fields* beyond the two relationship foreign keys (like the `joined_year` field in `M2m_membership_scratch` above), all direct manager mutators (`add!`, `remove!`, `clear!`, and `set!`) are disabled and will raise an `ArgumentError`.

This constraint prevents silent failures or incomplete rows, as PormG cannot determine appropriate values to insert for your custom fields. 

To link or unlink rows when using custom through models with extra fields, interact with the intermediate through model **directly** using its own object manager:

```julia
# Link a driver to a team with extra metadata:
M2m_membership_scratch.objects.create(
    "driver" => driver[:id], 
    "team" => team[:id], 
    "joined_year" => 2005
)

# Unlink a relationship:
M2m_membership_scratch.objects.filter(
    "driver" => driver[:id], 
    "team" => team[:id]
).delete()
```

If the custom intermediate model *only* contains the two foreign keys (and no extra columns), mutator methods like `add!` and `remove!` are fully supported.

---

## The ManyToMany Manager API

When you access a `ManyToManyField` on a fetched `PormGRow`, PormG returns a **ManyToManyManager**. This manager provides methods to query, add, remove, and sync relationships.

### Model-level vs instance-level access

Model-level access starts from `.objects` and builds queries across all rows:

```julia
drivers = M.M2m_driver_endorsement_scratch.objects
drivers.filter("sponsors__name" => "Petrolux")
drivers.values("driverref")
rows = drivers.list()
```

Instance-level access starts by fetching one `PormGRow`, then uses the row's relationship accessor:

```julia
driver = M.M2m_driver_endorsement_scratch.objects.get("driverref" => "senna")
sponsors = driver.sponsors.all().list()
```

Let's assume we have fetched a driver instance:
```julia
driver = M.M2m_driver_endorsement_scratch.objects.get("driverref" => "senna")
```

### `.all()` — Querying related objects

To get all sponsors for this driver, call `.all()` on the relationship manager. It returns an `ObjectHandler` that you can further filter or fetch.

```julia
# Fetch all sponsors for Senna
sponsors_df = driver.sponsors.all() |> DataFrame

# You can chain filters on the relation!
brazilian_sponsors = driver.sponsors.all().filter("country__name" => "Brazil") |> DataFrame
```

### `.add!(targets...)` — Adding relationships

You can link new items to the relationship using `.add!`. It accepts integers (primary keys), dictionaries, named tuples, or actual model instances.

```julia
# By primary key
driver.sponsors.add!(1)

# Multiple at once
driver.sponsors.add!(2, 3)

# By dictionary (must contain the primary key)
driver.sponsors.add!(Dict(:id => 4))
```

### `.remove!(targets...)` — Removing relationships

Unlink specific items from the relationship. It takes the exact same arguments as `.add!`.

```julia
# Remove sponsor with ID 2
driver.sponsors.remove!(2)
```

### `.set!(targets...)` — Syncing relationships

`.set!` compares the IDs you provide with the IDs currently in the database. It will automatically `add!` any missing ones and `remove!` any extra ones, all wrapped in a **transaction**.

```julia
# Ensure the driver is linked ONLY to sponsors 1, 4, and 5.
# If they were linked to 2, it will be removed.
# If they weren't linked to 4, it will be added.
changes = driver.sponsors.set!(1, 4, 5)

println("Added: $(changes.added), Removed: $(changes.removed)")
```

### `.clear!()` — Removing all relationships

Unlinks everything.

```julia
driver.sponsors.clear!()
```

---

## Querying Across Many-To-Many Relations (Multi-hop Joins)

Because PormG understands your relationships, you can use the standard double-underscore `__` syntax to filter across Many-to-Many fields exactly like you would with Foreign Keys. PormG will automatically handle the `INNER JOIN` through the intermediary table.

For example, to find all drivers who are endorsed by a sponsor located in Italy:

```julia
query = M.M2m_driver_multi_hop_scratch.objects

# driver -> sponsors -> country -> name
query.filter("sponsors__country__name" => "Italy")

# Select the driver's ref and the sponsor's name
query.values("driverref", "sponsors__name")

df = query |> DataFrame
```

Generated SQL (PostgreSQL):
```sql
SELECT
    "Tb"."driverRef" as driverRef,
    "Tb_2"."name" as sponsors__name
FROM "m2m_driver_multi_hop_scratch" as "Tb"
  INNER JOIN "m2m_driver_multi_hop_scratch_sponsors" AS "Tb_1" ON "Tb"."id" = "Tb_1"."m2m_driver_multi_hop_scratch_id"
  INNER JOIN "m2m_sponsor_with_country_scratch" AS "Tb_2" ON "Tb_1"."m2m_sponsor_with_country_scratch_id" = "Tb_2"."id"
  INNER JOIN "m2m_country_scratch" AS "Tb_3" ON "Tb_2"."country_id" = "Tb_3"."id"
WHERE "Tb_3"."name" = $1
```

> [!NOTE]
> The transparent joining works equally well whether you are using an implicit or an explicit through table!
