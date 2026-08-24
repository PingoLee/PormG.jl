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
  driverref = Models.CharField(unique=true),
  
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

This is essential for multi-hop joins and reverse-lookups. Without it, PormG derives one for you:

- the **lowercase name of the declaring model** when it is that model's only relation to the target —
  `m2m_driver_endorsement_scratch`;
- **`<model>_<field>`** when the model declares two or more relations to the same target. Add a
  `title_sponsor` foreign key alongside `sponsors`, both pointing at `M2m_sponsor_scratch`, and the
  two reverse accessors become `m2m_driver_endorsement_scratch_title_sponsor` and
  `m2m_driver_endorsement_scratch_sponsors`. Every member of such a group is suffixed, and PormG logs
  each derived name at `@info` when it registers the models.

There is no `_set` suffix; PormG is not Django here.

---

## Self-Referential Relationships

A `ManyToManyField` may point at the model that declares it — drivers who were teammates, circuits
that succeed one another, constructors that share an engine supplier. Reference the model **by
string**, since its own binding does not exist yet at the point the field is written:

```julia
M2m_teammate_scratch = Models.Model("m2m_teammate_scratch",
  id = Models.IDField(),
  driverref = Models.CharField(unique=true),
  teammates = Models.ManyToManyField("M2m_teammate_scratch", related_name="teammate_of")
)
```

Both ends of this relation are the same model, so the usual `<model>_<pk>` column rule would name
them identically — and one table cannot carry the same column twice. PormG therefore prefixes the
two ends, exactly as Django does:

| | Normal relation | Self-referential relation |
|---|---|---|
| Owner end | `<owner model>_<pk>` | `from_<model>_<pk>` |
| Target end | `<target model>_<pk>` | `to_<model>_<pk>` |

So `m2m_teammate_scratch_teammates` is created with `from_m2m_teammate_scratch_id` and
`to_m2m_teammate_scratch_id`. With the conventional `id` primary key this is byte-identical to
Django's `from_<model>_id` / `to_<model>_id`; a model keyed on something else keeps that key's name
in the stem, matching the column PormG's own migrations create.

Everything else behaves exactly like any other many-to-many — the manager, the `__` traversal, and
the reverse accessor:

```julia
senna = M.M2m_teammate_scratch.objects.get("driverref" => "senna")

M.M2m_teammate_scratch.teammates(senna[:id]).add(prost_id, berger_id)

# Forward: which drivers list prost as a teammate?
teammates_of_prost = M.M2m_teammate_scratch.objects.filter(
    "teammates__driverref" => "prost"
).values("driverref").list()

# Reverse, through related_name: which drivers is senna listed as a teammate of?
listed_with_senna = M.M2m_teammate_scratch.objects.filter(
    "teammate_of__driverref" => "senna"
).values("driverref").list()
```

The forward query joins out on `from_…` and back on `to_…`; the reverse swaps them. Both traverse
the same base table twice, which PormG resolves with distinct aliases:

```sql
SELECT "Tb"."driverref" as "driverref"
FROM "m2m_teammate_scratch" as "Tb"
  INNER JOIN "m2m_teammate_scratch_teammates" AS "Tb_1" ON "Tb"."id" = "Tb_1"."from_m2m_teammate_scratch_id"
  INNER JOIN "m2m_teammate_scratch" AS "Tb_2" ON "Tb_1"."to_m2m_teammate_scratch_id" = "Tb_2"."id"
WHERE "Tb_2"."driverref" = $1
```

!!! warning "The relation is directional — there is no `symmetrical=`"
    Django's `ManyToManyField('self')` defaults to `symmetrical=True`, which makes `add` write the
    link both ways and suppresses the reverse accessor. **PormG has no equivalent**: a link is
    stored in one direction only, so `senna.teammates.add(prost)` does *not* make senna appear in
    prost's `teammates`. If you want a symmetric relationship, add both directions yourself.

    That is also why `related_name` is worth setting here. The forward and reverse accessors land on
    the *same* model, so the default reverse name — the bare model name — reads like a foreign key
    rather than the other end of the link.

    **A reverse accessor must differ from every field name on the model it lands on**, the relation's
    own field included. `teammates = ManyToManyField("…", related_name="teammates")` is the tempting
    spelling for a link you think of as symmetric, and it would leave the reverse end permanently
    shadowed by the forward one. PormG rejects it with a `ModelDefinitionError` rather than letting
    the two collapse into one accessor.

    That rule is not special to self-relations: the join builder resolves a *field* before a reverse
    accessor at every hop, so any accessor equal to a field name on the target would register cleanly
    and then be unreachable. PormG checks it on every relation, foreign key and many-to-many alike.

!!! note "A self-`ForeignKey` and a self-`ManyToManyField` on one model get distinct accessors"
    Both would derive the same bare model name, so PormG counts them as one group of two relations to
    that target and suffixes each with its field name
    ([#396](https://github.com/PingoLee/PormG.jl/issues/396)):

    ```julia
    M2m_teammate_scratch = Models.Model("m2m_teammate_scratch",
      id = Models.IDField(),
      driverref = Models.CharField(unique=true),
      mentor = Models.ForeignKey("M2m_teammate_scratch", null=true),
      teammates = Models.ManyToManyField("M2m_teammate_scratch")
    )

    # Reverse accessors on M2m_teammate_scratch:
    #   m2m_teammate_scratch_mentor      → the foreign key, in reverse
    #   m2m_teammate_scratch_teammates   → the many-to-many, in reverse
    ```

    Naming them yourself still reads better, and it is what a Django-imported model carries anyway
    (Django's `fields.E304` requires it):

    ```julia
    mentor    = Models.ForeignKey("M2m_teammate_scratch", null=true, related_name="mentees"),
    teammates = Models.ManyToManyField("M2m_teammate_scratch", related_name="teammate_of")
    ```

!!! note "An explicit `through=` needs its ends named"
    On a self-relation PormG cannot infer which of the through model's two foreign keys is the
    source and which is the target — both point at the same model. It refuses rather than guessing;
    pin `source_field` and `target_field` to the through model's own field names, the same way
    Django requires `through_fields`:

    ```julia
    rivals = Models.ManyToManyField("M2m_racer_scratch", through="M2m_rivalry_scratch",
                                    source_field="challenger", target_field="defender")
    ```

    With an explicit `through=`, each is a **field name** on that model, never a column: PormG
    resolves it to the field's `db_column` on its way into the SQL, exactly as it does for an
    inferred end. A pin that names no field of the through model — or names one that is not a
    foreign key to the side it stands for — raises `ModelDefinitionError` and lists the foreign keys
    it could have named ([#377](https://github.com/PingoLee/PormG.jl/issues/377)). Same two checks
    Django runs on `through_fields`.

    (On the *auto-generated* join table these two options name the join **columns** directly — there
    is no through model to hold a field. See
    [Foreign-key columns](schema_conventions.md#Foreign-key-columns).)

---

## Explicit Through Tables

Sometimes you need to store extra data *on the relationship itself*. For example, you might want to know not just *which* team a driver races for, but *what year* they joined.

To do this, you define a regular model with two `ForeignKey` fields, and then tell the `ManyToManyField` to use it via the `through` keyword argument.

!!! tip
    **Django Style**: You can pass the `through` model as a **string**. This allows you to define the `ManyToManyField` inline before the through model is actually defined, avoiding circular reference errors in Julia.

```julia
using PormG.Models

M2m_team_scratch = Models.Model("m2m_team_scratch",
  id = Models.IDField(),
  name = Models.CharField(unique=true)
)

M2m_driver_explicit_scratch = Models.Model("m2m_driver_explicit_scratch",
  id = Models.IDField(),
  driverref = Models.CharField(unique=true),
  
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

!!! note "The through model's `db_table` is the join table"
    A through model is an ordinary model, so it may pin its physical table with
    [`db_table`](schema_conventions.md#Pinning-an-explicit-table-name-with-db_table) like any other.
    Keeping the model above and adding the pin:

    ```julia
    M2m_membership_scratch = Models.Model("m2m_membership_scratch",
      db_table = "racing_membership",      # the real table, whatever the logical name is
      id = Models.IDField(),
      driver = Models.ForeignKey(M2m_driver_explicit_scratch, on_delete=Models.CASCADE),
      team = Models.ForeignKey(M2m_team_scratch, on_delete=Models.CASCADE),
      joined_year = Models.IntegerField()
    )
    ```

    The join table PormG addresses is then `racing_membership` — in the joins behind `teams__name`
    and `drivers__driverref`, and in the manager mutators for a through model that permits them.
    The `db_table` option on the `ManyToManyField` itself names the *auto-generated* join table only;
    with an explicit `through=` there is no generated table to name, so that option is ignored.

!!! note "The through model's `db_column`s are the join columns"
    The column-axis half of the same rule. A through model's two foreign keys are ordinary fields, so
    each may map to a differently-named column with
    [`db_column`](fields.md#Database-Column-Mapping), and PormG addresses the column —
    not the field name — in every join and every mutator
    ([#377](https://github.com/PingoLee/PormG.jl/issues/377)):

    ```julia
    M2m_membership_scratch = Models.Model("m2m_membership_scratch",
      db_table = "racing_membership",
      id = Models.IDField(),
      driver_id = Models.ForeignKey(M2m_driver_explicit_scratch, db_column="drv", on_delete=Models.CASCADE),
      team_id = Models.ForeignKey(M2m_team_scratch, db_column="tm", on_delete=Models.CASCADE),
      joined_year = Models.IntegerField()
    )
    ```

    ```sql
    INNER JOIN "racing_membership" AS "Tb_1" ON "Tb"."id" = "Tb_1"."drv"
    INNER JOIN "m2m_team_scratch" AS "Tb_2" ON "Tb_1"."tm" = "Tb_2"."id"
    ```

    The fields are spelled `driver_id` / `team_id` here only to match an existing schema that names
    its columns that way — the same interop choice described under
    [Foreign-key columns](schema_conventions.md#Foreign-key-columns), and what the Django importer
    emits. `db_column` works exactly the same on the `driver` / `team` spelling used above.
    Either way you keep querying by the **field** name —
    `driver_id`, not `drv` — as everywhere else; only the rendered column changes. This matches
    Django, which reads the through foreign key's `column` (`db_column` when set) for the join and
    its `name` for `through_fields`.

### Relationship Mutator Limitations on Custom Through Tables

!!! warning
    **Django-Style Strict Mutators**: If your custom intermediate `through` model contains *any extra fields* beyond the two relationship foreign keys (like the `joined_year` field in `M2m_membership_scratch` above), all direct manager mutators (`add`, `remove`, `clear`, and `set`) are disabled and will raise a `QueryBuildError`.

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

If the custom intermediate model *only* contains the two foreign keys (and no extra columns), mutator methods like `add` and `remove` are fully supported.

---

## The ManyToMany Manager API

When you access a `ManyToManyField` on a fetched `PormGRow`, PormG returns a **ManyToManyManager**. This manager provides methods to query, add, remove, and sync relationships.

!!! note "Why `add`/`remove`/`clear`/`set` carry no `!`"
    Julia's `!` suffix conventionally marks a function that mutates a **Julia argument**.
    The manager mutators mutate the database through-table instead — and they are only ever
    reached as manager methods (`driver.sponsors.add(...)`), never as free functions in your
    namespace. That makes them the same kind of surface as the bang-free fluent terminals
    (`q.update(...)`, `q.delete()`), and matches Django's `add`/`remove`/`clear`/`set`.
    (Renamed from `add!`/`remove!`/`clear!`/`set!` in 0.3.0 — see `UPGRADING.md`.)

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

### `.add(targets...)` — Adding relationships

You can link new items to the relationship using `.add`. It accepts integers (primary keys), dictionaries, named tuples, or actual model instances.

```julia
# By primary key
driver.sponsors.add(1)

# Multiple at once
driver.sponsors.add(2, 3)

# By dictionary (must contain the primary key)
driver.sponsors.add(Dict(:id => 4))
```

### `.remove(targets...)` — Removing relationships

Unlink specific items from the relationship. It takes the exact same arguments as `.add`.

```julia
# Remove sponsor with ID 2
driver.sponsors.remove(2)
```

### `.set(targets...)` — Syncing relationships

`.set` compares the IDs you provide with the IDs currently in the database. It will automatically `add` any missing ones and `remove` any extra ones, all wrapped in a **transaction**.

```julia
# Ensure the driver is linked ONLY to sponsors 1, 4, and 5.
# If they were linked to 2, it will be removed.
# If they weren't linked to 4, it will be added.
changes = driver.sponsors.set(1, 4, 5)

println("Added: $(changes.added), Removed: $(changes.removed)")
```

### `.clear()` — Removing all relationships

Unlinks everything.

```julia
driver.sponsors.clear()
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
    "Tb"."driverref" as driverref,
    "Tb_2"."name" as sponsors__name
FROM "m2m_driver_multi_hop_scratch" as "Tb"
  INNER JOIN "m2m_driver_multi_hop_scratch_sponsors" AS "Tb_1" ON "Tb"."id" = "Tb_1"."m2m_driver_multi_hop_scratch_id"
  INNER JOIN "m2m_sponsor_with_country_scratch" AS "Tb_2" ON "Tb_1"."m2m_sponsor_with_country_scratch_id" = "Tb_2"."id"
  INNER JOIN "m2m_country_scratch" AS "Tb_3" ON "Tb_2"."country_id" = "Tb_3"."id"
WHERE "Tb_3"."name" = $1
```

!!! note
    The transparent joining works equally well whether you are using an implicit or an explicit through table!
